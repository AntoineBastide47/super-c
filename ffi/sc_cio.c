/* The completion engines behind sc_cio.h: io_uring on Linux, IOCP on Windows, nothing anywhere else.
   Both are written against the raw kernel interface -- no liburing, which would be a dependency for a few
   hundred lines of ring arithmetic we can read ourselves. */
#if defined(__linux__)
#define _GNU_SOURCE 1
#endif

#include "sc_cio.h"

#include <stdlib.h>
#include <string.h>

#if defined(__linux__)
/* ============================== io_uring ============================================================ */
#include <errno.h>
#include <linux/io_uring.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

/* The kernel publishes ring state through shared memory, so every hand-off needs the matching barrier: the
   tail we publish must be visible only AFTER the entry it points at (release), and entries we read must be
   read only after the tail that announced them (acquire). Getting these wrong is invisible on x86 and
   corrupts on arm64, which is exactly the machine this was written on. */
#define SC_LOAD_ACQ(p) __atomic_load_n((p), __ATOMIC_ACQUIRE)
#define SC_STORE_REL(p, v) __atomic_store_n((p), (v), __ATOMIC_RELEASE)

typedef struct {
  int fd;
  unsigned *sq_head, *sq_tail, *sq_mask, *sq_array;
  unsigned *cq_head, *cq_tail, *cq_mask;
  struct io_uring_cqe *cqes;
  struct io_uring_sqe *sqes;
  void *sq_ring;
  size_t sq_ring_sz;
  void *cq_ring;
  size_t cq_ring_sz;
  size_t sqes_sz;
  unsigned entries;
  pthread_mutex_t lock; /* the submission queue has ONE producer by design; this is what makes it one */
} sc_uring;

/* Sentinels returned to us, never to the caller: a timeout expiring, and a nudge from sc_cq_wake. They sit
   at the very top of the u64 range because they share a namespace with the caller's cookies and anything
   plausible collides -- these started as 1 and 2, and the stress test promptly submitted cookies 1 and 2,
   whose completions were then filtered away as internal. Real cookies are heap pointers and can never be
   these, which is exactly why the reserved pair must be somewhere a pointer cannot reach. */
#define SC_UD_TIMEOUT (~(__u64)0)
#define SC_UD_WAKE (~(__u64)0 - 1)

static int sc_uring_setup(unsigned entries, struct io_uring_params *p) {
  return (int)syscall(__NR_io_uring_setup, entries, p);
}
static int sc_uring_enter(int fd, unsigned to_submit, unsigned min_complete, unsigned flags) {
  return (int)syscall(__NR_io_uring_enter, fd, to_submit, min_complete, flags, (void *)0, (size_t)0);
}

void *sc_cq_new(unsigned entries) {
  struct io_uring_params p;
  memset(&p, 0, sizeof p);
  if (entries < 8) entries = 8;
  const int fd = sc_uring_setup(entries, &p);
  if (fd < 0) return 0; /* no io_uring here: an old kernel, or a sandbox that blocks the syscall */

  sc_uring *u = (sc_uring *)calloc(1, sizeof *u);
  if (!u) {
    close(fd);
    return 0;
  }
  u->fd = fd;
  u->entries = p.sq_entries;
  u->sq_ring_sz = p.sq_off.array + p.sq_entries * sizeof(unsigned);
  u->cq_ring_sz = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
  /* Newer kernels put both rings in one mapping; older ones want two. */
  const int single = (p.features & IORING_FEAT_SINGLE_MMAP) != 0;
  if (single) {
    if (u->cq_ring_sz > u->sq_ring_sz) u->sq_ring_sz = u->cq_ring_sz;
    u->cq_ring_sz = u->sq_ring_sz;
  }
  u->sq_ring = mmap(0, u->sq_ring_sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQ_RING);
  if (u->sq_ring == MAP_FAILED) goto fail;
  u->cq_ring = single ? u->sq_ring
                      : mmap(0, u->cq_ring_sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd,
                             IORING_OFF_CQ_RING);
  if (u->cq_ring == MAP_FAILED) goto fail;
  u->sqes_sz = p.sq_entries * sizeof(struct io_uring_sqe);
  u->sqes = (struct io_uring_sqe *)mmap(0, u->sqes_sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd,
                                        IORING_OFF_SQES);
  if (u->sqes == MAP_FAILED) goto fail;

  char *sr = (char *)u->sq_ring, *cr = (char *)u->cq_ring;
  u->sq_head = (unsigned *)(sr + p.sq_off.head);
  u->sq_tail = (unsigned *)(sr + p.sq_off.tail);
  u->sq_mask = (unsigned *)(sr + p.sq_off.ring_mask);
  u->sq_array = (unsigned *)(sr + p.sq_off.array);
  u->cq_head = (unsigned *)(cr + p.cq_off.head);
  u->cq_tail = (unsigned *)(cr + p.cq_off.tail);
  u->cq_mask = (unsigned *)(cr + p.cq_off.ring_mask);
  u->cqes = (struct io_uring_cqe *)(cr + p.cq_off.cqes);
  pthread_mutex_init(&u->lock, 0);
  return u;

fail:
  if (u->sq_ring && u->sq_ring != MAP_FAILED) munmap(u->sq_ring, u->sq_ring_sz);
  if (!single && u->cq_ring && u->cq_ring != MAP_FAILED) munmap(u->cq_ring, u->cq_ring_sz);
  close(fd);
  free(u);
  return 0;
}

void sc_cq_free(void *q) {
  sc_uring *u = (sc_uring *)q;
  if (!u) return;
  if (u->sqes) munmap(u->sqes, u->sqes_sz);
  if (u->cq_ring && u->cq_ring != u->sq_ring) munmap(u->cq_ring, u->cq_ring_sz);
  if (u->sq_ring) munmap(u->sq_ring, u->sq_ring_sz);
  pthread_mutex_destroy(&u->lock);
  close(u->fd);
  free(u);
}

/* Claim an SQE and publish it. Caller holds the lock. Returns 0, or -1 when the ring is full -- the caller
   turns that into "fall back to doing it yourself", never into a lost operation. */
static int sc_uring_push(sc_uring *u, __u8 op, int fd, const void *addr, unsigned len, __u64 off, __u64 ud) {
  const unsigned tail = *u->sq_tail;
  const unsigned head = SC_LOAD_ACQ(u->sq_head);
  if (tail - head >= u->entries) return -1; /* full */
  const unsigned idx = tail & *u->sq_mask;
  struct io_uring_sqe *s = &u->sqes[idx];
  memset(s, 0, sizeof *s);
  s->opcode = op;
  s->fd = fd;
  s->off = off;
  s->addr = (unsigned long long)(uintptr_t)addr;
  s->len = len;
  s->user_data = ud;
  u->sq_array[idx] = idx;
  SC_STORE_REL(u->sq_tail, tail + 1); /* the entry must be visible before the tail that points at it */
  return 0;
}

/* Hand the kernel EVERYTHING the ring has queued, not the one entry just pushed. io_uring_enter reports how
   many SQEs it actually consumed and is free to take fewer; asking for exactly one leaves any surplus behind
   and the shortfall compounds, which loses submissions silently -- caught by the multi-producer stress test
   at 3998 of 4000, with nothing corrupted, just two operations that never happened. */
static int sc_uring_flush(sc_uring *u) {
  const unsigned pending = *u->sq_tail - SC_LOAD_ACQ(u->sq_head);
  if (pending == 0) return 0;
  return sc_uring_enter(u->fd, pending, 0, 0) < 0 ? -1 : 0;
}

static int sc_uring_submit_one(void *q, __u8 op, int fd, const void *buf, size_t n, void *udata) {
  sc_uring *u = (sc_uring *)q;
  if (!u) return -1;
  pthread_mutex_lock(&u->lock);
  int rc = sc_uring_push(u, op, fd, buf, (unsigned)n, 0, (__u64)(uintptr_t)udata);
  if (rc == 0) rc = sc_uring_flush(u);
  pthread_mutex_unlock(&u->lock);
  return rc;
}

int sc_cq_read(void *q, int fd, void *buf, size_t n, void *udata) {
  return sc_uring_submit_one(q, IORING_OP_READ, fd, buf, n, udata);
}
int sc_cq_write(void *q, int fd, const void *buf, size_t n, void *udata) {
  return sc_uring_submit_one(q, IORING_OP_WRITE, fd, buf, n, udata);
}
int sc_cq_accept(void *q, int lfd, void *udata) {
  return sc_uring_submit_one(q, IORING_OP_ACCEPT, lfd, 0, 0, udata);
}

void sc_cq_wake(void *q) {
  sc_uring *u = (sc_uring *)q;
  if (!u) return;
  pthread_mutex_lock(&u->lock);
  /* A no-op completes immediately, which is all a blocked reaper needs to come back. */
  if (sc_uring_push(u, IORING_OP_NOP, -1, 0, 0, 0, SC_UD_WAKE) == 0) sc_uring_flush(u);
  pthread_mutex_unlock(&u->lock);
}

int sc_cq_wait(void *q, void **udata, long *res, int max, int timeout_ms) {
  sc_uring *u = (sc_uring *)q;
  if (!u || max <= 0) return -1;
  if (timeout_ms >= 0) {
    /* The ring has no timeout argument in the portable enter(); a TIMEOUT operation is how you get one. */
    struct __kernel_timespec ts;
    ts.tv_sec = timeout_ms / 1000;
    ts.tv_nsec = (long long)(timeout_ms % 1000) * 1000000LL;
    pthread_mutex_lock(&u->lock);
    if (sc_uring_push(u, IORING_OP_TIMEOUT, -1, &ts, 1, 1, SC_UD_TIMEOUT) == 0) sc_uring_flush(u);
    pthread_mutex_unlock(&u->lock);
  }
  /* Block until at least one completion is there, flushing anything still queued on the way in.
     EINTR/EAGAIN are not failures, just an empty round. */
  pthread_mutex_lock(&u->lock);
  const unsigned pending = *u->sq_tail - SC_LOAD_ACQ(u->sq_head);
  pthread_mutex_unlock(&u->lock);
  if (sc_uring_enter(u->fd, pending, 1, IORING_ENTER_GETEVENTS) < 0 && errno != EINTR && errno != EAGAIN &&
      errno != ETIME)
    return -1;

  int k = 0;
  unsigned head = *u->cq_head;
  const unsigned tail = SC_LOAD_ACQ(u->cq_tail); /* read the tail before the entries it announces */
  while (head != tail && k < max) {
    const struct io_uring_cqe *c = &u->cqes[head & *u->cq_mask];
    const __u64 ud = c->user_data;
    const int r = c->res;
    head++;
    if (ud == SC_UD_TIMEOUT || ud == SC_UD_WAKE) continue; /* ours, not the caller's */
    udata[k] = (void *)(uintptr_t)ud;
    res[k] = (long)r;
    k++;
  }
  SC_STORE_REL(u->cq_head, head); /* release the entries back to the kernel only once we have read them */
  return k;
}

#elif defined(_WIN32)
/* ============================== IOCP ================================================================= */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mswsock.h>
#include <windows.h>

/* One OVERLAPPED per in-flight operation, plus what the completion needs to make sense of it. It is heap
   allocated and outlives the submitting call by construction: the kernel writes through this pointer after
   the call returns, so it cannot live in the caller's frame. */
typedef struct {
  OVERLAPPED ov; /* must be first: the completion hands back exactly this address */
  void *udata;
  SOCKET accepted;   /* accept only: the socket created up front, as AcceptEx demands */
  char addr[64 * 2]; /* accept only: AcceptEx insists on writing both addresses somewhere */
} sc_iocp_op;

typedef struct {
  HANDLE port;
  LPFN_ACCEPTEX acceptex; /* not exported by name: it has to be fetched through WSAIoctl */
} sc_iocp;

void *sc_cq_new(unsigned entries) {
  (void)entries;
  sc_iocp *q = (sc_iocp *)calloc(1, sizeof *q);
  if (!q) return 0;
  q->port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, 0, 0, 0);
  if (!q->port) {
    free(q);
    return 0;
  }
  /* AcceptEx lives behind WSAIoctl, so a throwaway socket is the only way to ask for it. */
  SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s != INVALID_SOCKET) {
    GUID gid = WSAID_ACCEPTEX;
    DWORD got = 0;
    WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, &gid, sizeof gid, &q->acceptex, sizeof q->acceptex, &got,
             0, 0);
    closesocket(s);
  }
  return q;
}

void sc_cq_free(void *q) {
  sc_iocp *p = (sc_iocp *)q;
  if (!p) return;
  if (p->port) CloseHandle(p->port);
  free(p);
}

/* A descriptor must be attached to the port once before any operation on it completes there. Associating
   twice is harmless (it fails with ERROR_INVALID_PARAMETER), which is why this is not tracked. */
static void sc_iocp_attach(sc_iocp *p, int fd) {
  CreateIoCompletionPort((HANDLE)(uintptr_t)fd, p->port, 0, 0);
}

static sc_iocp_op *sc_iocp_op_new(void *udata) {
  sc_iocp_op *o = (sc_iocp_op *)calloc(1, sizeof *o);
  if (o) o->udata = udata;
  return o;
}

/* WSA_IO_PENDING is the ordinary answer: the operation is running and its completion will arrive. Anything
   else that is not success is a real failure, and the op is freed here because no completion will come. */
static int sc_iocp_started(sc_iocp_op *o, int rc) {
  if (rc == 0 || WSAGetLastError() == WSA_IO_PENDING) return 0;
  free(o);
  return -1;
}

int sc_cq_read(void *q, int fd, void *buf, size_t n, void *udata) {
  sc_iocp *p = (sc_iocp *)q;
  if (!p) return -1;
  sc_iocp_attach(p, fd);
  sc_iocp_op *o = sc_iocp_op_new(udata);
  if (!o) return -1;
  WSABUF b;
  b.buf = (char *)buf;
  b.len = (ULONG)n;
  DWORD flags = 0, got = 0;
  return sc_iocp_started(o, WSARecv((SOCKET)(uintptr_t)fd, &b, 1, &got, &flags, &o->ov, 0));
}

int sc_cq_write(void *q, int fd, const void *buf, size_t n, void *udata) {
  sc_iocp *p = (sc_iocp *)q;
  if (!p) return -1;
  sc_iocp_attach(p, fd);
  sc_iocp_op *o = sc_iocp_op_new(udata);
  if (!o) return -1;
  WSABUF b;
  b.buf = (char *)(void *)buf;
  b.len = (ULONG)n;
  DWORD sent = 0;
  return sc_iocp_started(o, WSASend((SOCKET)(uintptr_t)fd, &b, 1, &sent, 0, &o->ov, 0));
}

int sc_cq_accept(void *q, int lfd, void *udata) {
  sc_iocp *p = (sc_iocp *)q;
  if (!p || !p->acceptex) return -1;
  sc_iocp_attach(p, lfd);
  sc_iocp_op *o = sc_iocp_op_new(udata);
  if (!o) return -1;
  /* AcceptEx needs the new socket to exist BEFORE the accept: the completion fills it in rather than
     returning one, which is the whole reason an accept can be started ahead of a connection arriving. */
  o->accepted = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (o->accepted == INVALID_SOCKET) {
    free(o);
    return -1;
  }
  DWORD got = 0;
  const BOOL ok = p->acceptex((SOCKET)(uintptr_t)lfd, o->accepted, o->addr, 0, sizeof o->addr / 2,
                              sizeof o->addr / 2, &got, &o->ov);
  if (!ok && WSAGetLastError() != WSA_IO_PENDING) {
    closesocket(o->accepted);
    free(o);
    return -1;
  }
  return 0;
}

void sc_cq_wake(void *q) {
  sc_iocp *p = (sc_iocp *)q;
  if (p && p->port) PostQueuedCompletionStatus(p->port, 0, 0, 0); /* a null OVERLAPPED: recognised below */
}

int sc_cq_wait(void *q, void **udata, long *res, int max, int timeout_ms) {
  sc_iocp *p = (sc_iocp *)q;
  if (!p || max <= 0) return -1;
  OVERLAPPED_ENTRY ev[64];
  if (max > 64) max = 64;
  ULONG n = 0;
  const DWORD ms = timeout_ms < 0 ? INFINITE : (DWORD)timeout_ms;
  if (!GetQueuedCompletionStatusEx(p->port, ev, (ULONG)max, &n, ms, FALSE))
    return GetLastError() == WAIT_TIMEOUT ? 0 : -1;

  int k = 0;
  for (ULONG i = 0; i < n; i++) {
    sc_iocp_op *o = (sc_iocp_op *)ev[i].lpOverlapped;
    if (!o) continue; /* the wake-up posted above */
    long r = (long)ev[i].dwNumberOfBytesTransferred;
    /* An accept reports the socket it created; everything else reports bytes. A failed operation reports a
       negative value, matching io_uring, so the Super-C side sees one convention. */
    if (o->accepted) r = (long)(intptr_t)o->accepted;
    if (o->ov.Internal != 0 && r == 0) r = -1;
    udata[k] = o->udata;
    res[k] = r;
    k++;
    free(o);
  }
  return k;
}

#else
/* ============================== no completion engine ================================================= */
void *sc_cq_new(unsigned entries) {
  (void)entries;
  return 0; /* macOS and friends: the caller uses the readiness poller in sc_io.h */
}
void sc_cq_free(void *q) { (void)q; }
int sc_cq_read(void *q, int fd, void *buf, size_t n, void *udata) {
  (void)q;
  (void)fd;
  (void)buf;
  (void)n;
  (void)udata;
  return -1;
}
int sc_cq_write(void *q, int fd, const void *buf, size_t n, void *udata) {
  (void)q;
  (void)fd;
  (void)buf;
  (void)n;
  (void)udata;
  return -1;
}
int sc_cq_accept(void *q, int lfd, void *udata) {
  (void)q;
  (void)lfd;
  (void)udata;
  return -1;
}
int sc_cq_wait(void *q, void **udata, long *res, int max, int timeout_ms) {
  (void)q;
  (void)udata;
  (void)res;
  (void)max;
  (void)timeout_ms;
  return -1;
}
void sc_cq_wake(void *q) { (void)q; }
#endif
