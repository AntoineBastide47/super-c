/* Readiness poller + socket helpers declared in sc_io.h. Three backends behind one interface: kqueue on
   macOS/BSD, epoll on Linux, select() on Windows. All three answer the same question -- tell me when this
   descriptor can be read (or written) -- so the Super-C reactor above is one piece of code.

   Windows uses select(), not WSAPoll(), for one reason: WSAPoll does not report a FAILED connection
   attempt, so a connect to a closed port would never become ready and the caller would hang until its
   deadline instead of learning it was refused. select() reports that through the exception set, which is
   why a connecting socket is registered there as well as in the write set. The cost is select()'s ceiling
   of FD_SETSIZE sockets per set -- raised below, and the reason IOCP is the eventual Windows backend.

   The socket calls themselves are ONE implementation: Winsock is Berkeley sockets with different spellings
   (closesocket, ioctlsocket, an int socklen, char* option values) plus two real semantic differences, both
   marked where they occur -- SO_REUSEADDR means "steal the port" rather than "reuse a dead one", and a
   non-blocking connect reports WSAEWOULDBLOCK where POSIX says EINPROGRESS. */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#if defined(_WIN32)
/* Sizes fd_set's socket array, so it must precede winsock2.h: this is the reactor's hard ceiling on
   simultaneously parked descriptors, and sc_io_set reports it rather than overflowing the set. */
#define FD_SETSIZE 1024
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/epoll.h>
#else
#include <sys/event.h>
#endif
#endif

#include "sc_io.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- one spelling for the two socket APIs ---------------------------------------------------------- */

#if defined(_WIN32)
typedef SOCKET sc_sock;
typedef int sc_socklen;
#define sc_closesock closesocket
#define SC_OPTVAL(p) ((const char *)(p))
#define SC_OPTOUT(p) ((char *)(p))
#else
typedef int sc_sock;
typedef socklen_t sc_socklen;
#define sc_closesock close
#define SC_OPTVAL(p) (p)
#define SC_OPTOUT(p) (p)
#endif

/* A descriptor crosses into Super-C as an int. On Windows a SOCKET is a handle-sized value, but Microsoft
   guarantees it fits in 32 bits for exactly this reason, and INVALID_SOCKET narrows to -1 -- so the "< 0
   means failure" test the callers already use keeps working. */
#define SC_FD(s) ((int)(intptr_t)(s))
#define SC_SOCK(fd) ((sc_sock)(intptr_t)(fd))

static int sc_last_err(void) {
#if defined(_WIN32)
  return WSAGetLastError();
#else
  return errno;
#endif
}

/* Put a captured error back after cleanup. Winsock resets the last error on any SUCCESSFUL call, so a
   closesocket()/freeaddrinfo() between a failure and the caller reading sc_io_errno() erases it -- which
   turns "address in use" into "code 0, kind Other". Every failure path below therefore captures the error
   before it tidies up and restores it just before returning. */
static void sc_set_err(int e) {
#if defined(_WIN32)
  WSASetLastError(e);
#else
  errno = e;
#endif
}

/* Winsock needs a process-wide startup before any socket call; POSIX needs nothing. Idempotent and safe
   from several threads, because a listener can be bound before the reactor ever starts. */
#if defined(_WIN32)
static volatile LONG sc_ws_state = 0;
static void sc_startup(void) {
  if (InterlockedCompareExchange(&sc_ws_state, 1, 0) == 0) {
    WSADATA d;
    WSAStartup(MAKEWORD(2, 2), &d);
    InterlockedExchange(&sc_ws_state, 2);
    return;
  }
  while (InterlockedCompareExchange(&sc_ws_state, 2, 2) != 2)
    Sleep(0);
}
#else
static void sc_startup(void) {}
#endif

int sc_io_set_nonblocking(int fd) {
#if defined(_WIN32)
  u_long on = 1;
  return ioctlsocket(SC_SOCK(fd), FIONBIO, &on) == 0 ? 0 : -1;
#else
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl < 0) return -1;
  return fcntl(fd, F_SETFL, fl | O_NONBLOCK);
#endif
}

int sc_io_close(int fd) { return sc_closesock(SC_SOCK(fd)); }

int sc_io_errno(void) { return sc_last_err(); }

int sc_io_would_block(void) {
  const int e = sc_last_err();
#if defined(_WIN32)
  return e == WSAEWOULDBLOCK || e == WSAEINPROGRESS || e == WSAEINTR;
#else
  return e == EAGAIN || e == EWOULDBLOCK || e == EINPROGRESS || e == EINTR;
#endif
}

/* Sockets only on Windows -- a SOCKET is not a CRT file descriptor, so read()/write() cannot serve both.
   That is the one thing this reactor does that its POSIX siblings do not: it polls sockets, not files. */
long sc_io_read(int fd, void *buf, size_t n) {
#if defined(_WIN32)
  return (long)recv(SC_SOCK(fd), (char *)buf, (int)n, 0);
#else
  return (long)read(fd, buf, n);
#endif
}

long sc_io_write(int fd, const void *buf, size_t n) {
#if defined(_WIN32)
  return (long)send(SC_SOCK(fd), (const char *)buf, (int)n, 0);
#else
  return (long)write(fd, buf, n);
#endif
}

/* ---- readiness poller ------------------------------------------------------------------------------ */

/* The interface is one-shot and mask-based. `sc_io_set` adds the `want` bits (SC_IO_RD / SC_IO_WR) to the
   OS interest in `fd`; a bit that fires is consumed (the backend disarms it) and reported once through
   `sc_io_wait` as a (fd, ready, dropped) triple. `dropped` names the
   interest bits the backend no longer holds after that event: on epoll a one-shot registration disables
   the whole descriptor, so both bits are dropped by either; kqueue and select drop only the one that
   fired. The reactor owns the per-descriptor state and re-arms what it still needs. No cookie crosses this
   boundary: the descriptor number is the identity, and every table the events index lives on the
   reactor's side.

   Registration (`sc_io_set`) may come from any thread: the backends are thread-safe for it, and the
   reactor re-registers itself whenever it has to combine directions. Only the reactor calls `sc_io_wait`;
   `sc_io_wake` may come from any thread. Interests are never removed one by one: a one-shot that fires
   is gone, a descriptor closed is gone, and the poller's release drops the rest. */

#if defined(_WIN32)

/* One registration: the table is rebuilt into fd_sets on every wait, which is select()'s cost model. */
typedef struct {
  sc_sock s;
  int dir;
} sc_reg;

typedef struct {
  CRITICAL_SECTION lock; /* workers register, the reactor rebuilds the sets */
  sc_reg *regs;
  int n, cap;
  sc_sock wake_r, wake_w; /* a loopback pair: Windows has no socketpair, and select cannot watch a pipe */
} sc_io_poller;

static void sc_no_delay(sc_sock s);

/* The wake channel: connect a socket to a listener of our own on the loopback, keep both ends. The writer
   sends one byte per wake and nothing ever flows back, so under Nagle a second wake within Windows' 200 ms
   delayed-ACK window would sit in the send buffer until that ACK arrived: a reactor wake 200 ms late, on
   every wake after the first. TCP_NODELAY sends each byte at once. */
static int sc_wake_pair(sc_sock *rd, sc_sock *wr) {
  struct sockaddr_in a;
  sc_socklen alen = (sc_socklen)sizeof a;
  sc_sock l = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (l == INVALID_SOCKET) return -1;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  a.sin_port = 0;
  if (bind(l, (struct sockaddr *)&a, (sc_socklen)sizeof a) != 0 || listen(l, 1) != 0 ||
      getsockname(l, (struct sockaddr *)&a, &alen) != 0) {
    sc_closesock(l);
    return -1;
  }
  sc_sock c = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (c == INVALID_SOCKET) {
    sc_closesock(l);
    return -1;
  }
  if (connect(c, (struct sockaddr *)&a, alen) != 0) {
    sc_closesock(l);
    sc_closesock(c);
    return -1;
  }
  sc_sock s = accept(l, 0, 0);
  sc_closesock(l);
  if (s == INVALID_SOCKET) {
    sc_closesock(c);
    return -1;
  }
  sc_io_set_nonblocking(SC_FD(s));
  sc_io_set_nonblocking(SC_FD(c));
  sc_no_delay(c);
  *rd = s;
  *wr = c;
  return 0;
}

/* Whether the handle still names a socket. closesocket() may overlap a select() on the same socket (the
   reactor blocks in one while a closer runs), which Winsock leaves unspecified: in practice select() either
   fails with WSAENOTSOCK or returns with the dead socket flagged. Both paths probe before they report. */
static int sc_sock_alive(sc_sock s) {
  int type = 0;
  sc_socklen len = (sc_socklen)sizeof type;
  return getsockopt(s, SOL_SOCKET, SO_TYPE, SC_OPTOUT(&type), &len) == 0;
}

static int sc_reg_find(sc_io_poller *p, sc_sock s, int dir) {
  for (int i = 0; i < p->n; i++)
    if (p->regs[i].s == s && p->regs[i].dir == dir) return i;
  return -1;
}

void *sc_io_new(void) {
  sc_startup();
  sc_io_poller *p = (sc_io_poller *)calloc(1, sizeof *p);
  if (!p) return 0;
  if (sc_wake_pair(&p->wake_r, &p->wake_w) != 0) {
    free(p);
    return 0;
  }
  InitializeCriticalSection(&p->lock);
  return p;
}

void sc_io_free(void *ptr) {
  sc_io_poller *p = (sc_io_poller *)ptr;
  if (!p) return;
  sc_closesock(p->wake_r);
  sc_closesock(p->wake_w);
  DeleteCriticalSection(&p->lock);
  free(p->regs);
  free(p);
}

static int sc_reg_add(sc_io_poller *p, sc_sock s, int dir) {
  if (sc_reg_find(p, s, dir) >= 0) return 0;
  /* +1 for the wake socket, which is in every read set */
  if (p->n + 1 >= FD_SETSIZE) {
    WSASetLastError(WSAEMFILE);
    return -1;
  }
  if (p->n == p->cap) {
    const int cap = p->cap ? p->cap * 2 : 16;
    sc_reg *g = (sc_reg *)realloc(p->regs, (size_t)cap * sizeof *g);
    if (!g) {
      WSASetLastError(WSA_NOT_ENOUGH_MEMORY);
      return -1;
    }
    p->regs = g;
    p->cap = cap;
  }
  p->regs[p->n].s = s;
  p->regs[p->n].dir = dir;
  p->n++;
  return 0;
}

void sc_io_wake(void *ptr) {
  sc_io_poller *p = (sc_io_poller *)ptr;
  if (!p) return;
  const char b = 1;
  /* A failed send here is safe to drop: the only way it fails is a full buffer, and a full buffer is
     unread wake bytes -- so a wake is already pending and the reactor is about to run anyway. */
  (void)send(p->wake_w, &b, 1, 0);
}

int sc_io_set(void *ptr, int fd, int want, int known) {
  sc_io_poller *p = (sc_io_poller *)ptr;
  const sc_sock s = SC_SOCK(fd);
  int rc = 0;
  (void)known;
  /* select() has no registration step of its own, so a closed number is refused here, as kqueue and epoll
     refuse it: the wait settles as not ready at once instead of parking, and a dead socket dropped by
     sc_io_wait is never registered again. */
  if (!sc_sock_alive(s)) return -1;
  EnterCriticalSection(&p->lock);
  if ((want & SC_IO_RD) && sc_reg_add(p, s, SC_IO_RD) != 0) rc = -1;
  if (rc == 0 && (want & SC_IO_WR) && sc_reg_add(p, s, SC_IO_WR) != 0) rc = -1;
  LeaveCriticalSection(&p->lock);
  /* A select() already blocked on the old set would not see this one: make it rebuild. */
  if (rc == 0) sc_io_wake(p);
  return rc;
}

/* select() fails the WHOLE call if any member of a set is not a socket, which happens when a descriptor is
   closed while someone is parked on it. Rather than let that kill the reactor thread, find the dead
   registrations and drop them, reported as dropped but NOT ready: the reactor registers the direction
   again for the waiters it still holds, that registration fails, and the waits settle as not ready, the
   same answer a close gives on the other two backends. */
static int sc_io_reap_dead(sc_io_poller *p, int *out, int max) {
  int k = 0;
  EnterCriticalSection(&p->lock);
  for (int i = 0; i < p->n && k < max;) {
    if (sc_sock_alive(p->regs[i].s)) {
      i++;
      continue;
    }
    out[3 * k] = SC_FD(p->regs[i].s);
    out[3 * k + 1] = 0;
    out[3 * k + 2] = p->regs[i].dir;
    k++;
    p->regs[i] = p->regs[--p->n];
  }
  LeaveCriticalSection(&p->lock);
  return k;
}

int sc_io_wait(void *ptr, int *out, int max, int timeout_ms) {
  sc_io_poller *p = (sc_io_poller *)ptr;
  fd_set rd, wr, ex;
  struct timeval tv;
  struct timeval *tp = 0;

  FD_ZERO(&rd);
  FD_ZERO(&wr);
  FD_ZERO(&ex);
  EnterCriticalSection(&p->lock);
  FD_SET(p->wake_r, &rd);
  for (int i = 0; i < p->n; i++) {
    if (p->regs[i].dir == SC_IO_WR) {
      FD_SET(p->regs[i].s, &wr);
      FD_SET(p->regs[i].s, &ex); /* a refused connect surfaces HERE and nowhere else */
    } else {
      FD_SET(p->regs[i].s, &rd);
    }
  }
  LeaveCriticalSection(&p->lock);
  if (timeout_ms >= 0) {
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (long)(timeout_ms % 1000) * 1000;
    tp = &tv;
  }
  const int r = select(0, &rd, &wr, &ex, tp); /* the first argument is ignored on Windows */
  if (r == SOCKET_ERROR) {
    /* 0 keeps the reactor looping: either dead registrations were reaped, or this was transient. */
    return WSAGetLastError() == WSAENOTSOCK ? sc_io_reap_dead(p, out, max) : 0;
  }
  if (r == 0) return 0;
  if (FD_ISSET(p->wake_r, &rd)) {
    char drain[64];
    while (recv(p->wake_r, drain, (int)sizeof drain, 0) > 0) {
    }
  }
  int k = 0;
  EnterCriticalSection(&p->lock);
  /* Registrations are matched by socket, not by index: a worker may have registered while select() was
     blocked. A socket armed in that window can only be missing from the sets, never wrongly present. */
  for (int i = 0; i < p->n && k < max;) {
    const sc_reg *g = &p->regs[i];
    const int ready = g->dir == SC_IO_WR ? (FD_ISSET(g->s, &wr) || FD_ISSET(g->s, &ex)) : FD_ISSET(g->s, &rd);
    if (!ready) {
      i++;
      continue;
    }
    out[3 * k] = SC_FD(g->s);
    /* A socket closed while select() was blocked comes back flagged: report it dropped, not ready, so the
       reactor's next registration fails and its waits settle as not ready (see sc_io_reap_dead). */
    out[3 * k + 1] = sc_sock_alive(g->s) ? g->dir : 0;
    out[3 * k + 2] = g->dir;
    k++;
    p->regs[i] = p->regs[--p->n]; /* one-shot, like the other two backends: firing consumes it */
  }
  LeaveCriticalSection(&p->lock);
  return k;
}

int sc_io_wait_fd(int fd, int write, int timeout_ms) {
  sc_startup();
  const sc_sock s = SC_SOCK(fd);
  fd_set one, ex;
  struct timeval tv;
  struct timeval *tp = 0;
  FD_ZERO(&one);
  FD_ZERO(&ex);
  FD_SET(s, &one);
  FD_SET(s, &ex); /* a connect that was refused shows up only here */
  if (timeout_ms >= 0) {
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (long)(timeout_ms % 1000) * 1000;
    tp = &tv;
  }
  const int r = write ? select(0, 0, &one, &ex, tp) : select(0, &one, 0, &ex, tp);
  return r == SOCKET_ERROR ? -1 : r;
}

#else /* ---- POSIX: kqueue / epoll ------------------------------------------------------------------- */

typedef struct {
  int q;       /* kqueue / epoll descriptor */
  int wake[2]; /* self-pipe: read end stays registered, a write makes sc_io_wait return */
} sc_io_poller;

void *sc_io_new(void) {
  sc_io_poller *p = (sc_io_poller *)calloc(1, sizeof *p);
  if (!p) return 0;
#if defined(__linux__)
  p->q = epoll_create1(0);
#else
  p->q = kqueue();
#endif
  if (p->q < 0) { free(p); return 0; }
  if (pipe(p->wake) != 0) { close(p->q); free(p); return 0; }
  sc_io_set_nonblocking(p->wake[0]);
  sc_io_set_nonblocking(p->wake[1]);
  /* The wake pipe stays registered level-triggered; the wait loop recognises it by descriptor. */
#if defined(__linux__)
  struct epoll_event ev;
  memset(&ev, 0, sizeof ev);
  ev.events = EPOLLIN;
  ev.data.fd = p->wake[0];
  if (epoll_ctl(p->q, EPOLL_CTL_ADD, p->wake[0], &ev) != 0) { sc_io_free(p); return 0; }
#else
  struct kevent kev;
  EV_SET(&kev, p->wake[0], EVFILT_READ, EV_ADD, 0, 0, 0);
  if (kevent(p->q, &kev, 1, 0, 0, 0) != 0) { sc_io_free(p); return 0; }
#endif
  return p;
}

void sc_io_free(void *ptr) {
  sc_io_poller *p = (sc_io_poller *)ptr;
  if (!p) return;
  close(p->wake[0]);
  close(p->wake[1]);
  close(p->q);
  free(p);
}

int sc_io_set(void *ptr, int fd, int want, int known) {
  sc_io_poller *p = (sc_io_poller *)ptr;
#if defined(__linux__)
  /* One registration per descriptor carries both directions. A one-shot registration that fired is
     disabled, not gone, so it is modified rather than added; a descriptor closed and reused under the
     reactor has no registration any more (ENOENT), and the fresh add takes over. EPERM is a descriptor
     epoll cannot watch (a regular file): it is always ready, which is what 1 tells the reactor. */
  struct epoll_event ev;
  memset(&ev, 0, sizeof ev);
  ev.events = ((want & SC_IO_RD) ? EPOLLIN : 0) | ((want & SC_IO_WR) ? EPOLLOUT : 0) | EPOLLONESHOT;
  ev.data.fd = fd;
  if (known) {
    if (epoll_ctl(p->q, EPOLL_CTL_MOD, fd, &ev) == 0) return 0;
    if (errno != ENOENT) return errno == EPERM ? 1 : -1;
  }
  if (epoll_ctl(p->q, EPOLL_CTL_ADD, fd, &ev) == 0) return 0;
  if (errno == EEXIST) return epoll_ctl(p->q, EPOLL_CTL_MOD, fd, &ev) == 0 ? 0 : -1;
  return errno == EPERM ? 1 : -1;
#else
  /* Read and write are separate knotes: add what is wanted (EV_ADD on an existing knote refreshes it, so a
     descriptor reused under the reactor is registered afresh). With no event list, a change that fails
     makes the call fail with its errno, and nothing pending is drained. */
  (void)known;
  struct kevent ch[2];
  int n = 0;
  if (want & SC_IO_RD) EV_SET(&ch[n++], fd, EVFILT_READ, EV_ADD | EV_ONESHOT, 0, 0, 0);
  if (want & SC_IO_WR) EV_SET(&ch[n++], fd, EVFILT_WRITE, EV_ADD | EV_ONESHOT, 0, 0, 0);
  if (n == 0) return 0;
  return kevent(p->q, ch, n, 0, 0, 0) < 0 ? -1 : 0;
#endif
}

void sc_io_wake(void *ptr) {
  sc_io_poller *p = (sc_io_poller *)ptr;
  if (!p) return;
  char b = 1;
  ssize_t r = write(p->wake[1], &b, 1);
  (void)r;
}

int sc_io_wait_fd(int fd, int write, int timeout_ms) {
  struct pollfd p;
  p.fd = fd;
  p.events = (short)(write ? POLLOUT : POLLIN);
  p.revents = 0;
  int r = poll(&p, 1, timeout_ms);
  if (r < 0 && errno == EINTR) return 0;
  return r;
}

int sc_io_wait(void *ptr, int *out, int max, int timeout_ms) {
  sc_io_poller *p = (sc_io_poller *)ptr;
  if (max > SC_IO_EV_MAX) max = SC_IO_EV_MAX;
  int n = 0;
#if defined(__linux__)
  struct epoll_event evs[SC_IO_EV_MAX];
  n = epoll_wait(p->q, evs, max, timeout_ms);
#else
  struct kevent evs[SC_IO_EV_MAX];
  struct timespec ts;
  struct timespec *tp = 0;
  if (timeout_ms >= 0) {
    ts.tv_sec = timeout_ms / 1000;
    ts.tv_nsec = (long)(timeout_ms % 1000) * 1000000L;
    tp = &ts;
  }
  n = kevent(p->q, 0, 0, evs, max, tp);
#endif
  if (n < 0) return errno == EINTR ? 0 : -1;
  int k = 0;
  for (int i = 0; i < n; i++) {
#if defined(__linux__)
    const int fd = evs[i].data.fd;
    int ready = 0;
    if (evs[i].events & (EPOLLIN | EPOLLRDHUP)) ready |= SC_IO_RD;
    if (evs[i].events & EPOLLOUT) ready |= SC_IO_WR;
    if (evs[i].events & (EPOLLERR | EPOLLHUP)) ready |= SC_IO_RD | SC_IO_WR;
    const int dropped = SC_IO_RD | SC_IO_WR; /* one-shot disables the whole registration */
#else
    const int fd = (int)evs[i].ident;
    int ready = evs[i].filter == EVFILT_WRITE ? SC_IO_WR : SC_IO_RD;
    const int dropped = ready;
    if (evs[i].flags & (EV_EOF | EV_ERROR)) ready |= SC_IO_RD | SC_IO_WR;
#endif
    if (fd == p->wake[0]) { /* the wake pipe: drain it and report nothing */
      char buf[64];
      while (read(p->wake[0], buf, sizeof buf) > 0) {
      }
      continue;
    }
    out[3 * k] = fd;
    out[3 * k + 1] = ready;
    out[3 * k + 2] = dropped;
    k++;
  }
  return k;
}

#endif /* poller backends */

/* ---- sockets --------------------------------------------------------------------------------------- */

/* Resolve host:port and hand back the first usable address. `host` NULL/empty means "any". */
static int sc_tcp_addr(const char *host, int port, struct addrinfo **out) {
  struct addrinfo hints;
  char svc[16];
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_UNSPEC; /* IPv4 or IPv6, whichever the name resolves to */
  hints.ai_socktype = SOCK_STREAM;
  if (!host || !*host) hints.ai_flags = AI_PASSIVE;
  snprintf(svc, sizeof svc, "%d", port);
  return getaddrinfo((host && *host) ? host : 0, svc, &hints, out);
}

/* "Let me have this port if nobody is really using it." The two systems spell that differently, and using
   the POSIX spelling on Windows would be actively wrong: there SO_REUSEADDR means "bind even though someone
   is LISTENING here", so two listeners could share a port and this layer would never report AddressInUse.
   Windows already allows rebinding a TIME_WAIT port, and SO_EXCLUSIVEADDRUSE is what a server wants instead
   -- it keeps anyone else from stealing the port out from under it. */
static void sc_reuse_addr(sc_sock s) {
  int one = 1;
#if defined(_WIN32)
  setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, SC_OPTVAL(&one), (sc_socklen)sizeof one);
#else
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, SC_OPTVAL(&one), (sc_socklen)sizeof one);
#endif
}

static void sc_no_delay(sc_sock s) {
  int one = 1;
  setsockopt(s, IPPROTO_TCP, TCP_NODELAY, SC_OPTVAL(&one), (sc_socklen)sizeof one);
}

int sc_tcp_listen(const char *host, int port, int backlog) {
  sc_startup();
  struct addrinfo *ai = 0;
  if (sc_tcp_addr(host, port, &ai) != 0 || !ai) return -1;
  sc_sock s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
  if (SC_FD(s) < 0) { const int e = sc_last_err(); freeaddrinfo(ai); sc_set_err(e); return -1; }
  sc_reuse_addr(s);
  if (bind(s, ai->ai_addr, (sc_socklen)ai->ai_addrlen) != 0 || listen(s, backlog) != 0) {
    const int e = sc_last_err(); /* before the cleanup below can reset it -- this is AddressInUse */
    freeaddrinfo(ai);
    sc_closesock(s);
    sc_set_err(e);
    return -1;
  }
  freeaddrinfo(ai);
  if (sc_io_set_nonblocking(SC_FD(s)) != 0) { const int e = sc_last_err(); sc_closesock(s); sc_set_err(e); return -1; }
  return SC_FD(s);
}

int sc_tcp_port(int fd) {
  struct sockaddr_storage ss;
  sc_socklen len = (sc_socklen)sizeof ss;
  if (getsockname(SC_SOCK(fd), (struct sockaddr *)&ss, &len) != 0) return -1;
  if (ss.ss_family == AF_INET) return ntohs(((struct sockaddr_in *)&ss)->sin_port);
  if (ss.ss_family == AF_INET6) return ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
  return -1;
}

int sc_tcp_accept(int lfd) {
  sc_sock s = accept(SC_SOCK(lfd), 0, 0);
  if (SC_FD(s) < 0) return -1; /* nothing ran since the failure, so the error is still the caller's */
  if (sc_io_set_nonblocking(SC_FD(s)) != 0) { const int e = sc_last_err(); sc_closesock(s); sc_set_err(e); return -1; }
  sc_no_delay(s);
  return SC_FD(s);
}

int sc_tcp_connect(const char *host, int port) {
  sc_startup();
  struct addrinfo *ai = 0;
  if (sc_tcp_addr(host, port, &ai) != 0 || !ai) return -1;
  sc_sock s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
  if (SC_FD(s) < 0) { const int e = sc_last_err(); freeaddrinfo(ai); sc_set_err(e); return -1; }
  if (sc_io_set_nonblocking(SC_FD(s)) != 0) {
    const int e = sc_last_err();
    freeaddrinfo(ai);
    sc_closesock(s);
    sc_set_err(e);
    return -1;
  }
  const int r = connect(s, ai->ai_addr, (sc_socklen)ai->ai_addrlen);
  const int cerr = sc_last_err(); /* freeaddrinfo below would reset it */
  freeaddrinfo(ai);
  sc_set_err(cerr);
  /* "not finished yet" is EINPROGRESS on POSIX and WSAEWOULDBLOCK on Windows -- the same state, and the
     caller waits for writability either way before asking sc_tcp_connect_result what happened. */
#if defined(_WIN32)
  const int pending = cerr == WSAEWOULDBLOCK;
#else
  const int pending = cerr == EINPROGRESS;
#endif
  if (r == 0 || pending) {
    sc_no_delay(s);
    return SC_FD(s);
  }
  sc_closesock(s);
  sc_set_err(cerr);
  return -1;
}

int sc_tcp_connect_result(int fd) {
  int err = 0;
  sc_socklen len = (sc_socklen)sizeof err;
  if (getsockopt(SC_SOCK(fd), SOL_SOCKET, SO_ERROR, SC_OPTOUT(&err), &len) != 0) return -1;
  return err;
}

/* ---- UDP ------------------------------------------------------------------------------------------- */

int sc_udp_bind(const char *host, int port) {
  sc_startup();
  struct addrinfo *ai = 0, hints;
  char svc[16];
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_DGRAM;
  if (!host || !*host) hints.ai_flags = AI_PASSIVE;
  snprintf(svc, sizeof svc, "%d", port);
  if (getaddrinfo((host && *host) ? host : 0, svc, &hints, &ai) != 0 || !ai) return -1;
  sc_sock s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
  if (SC_FD(s) < 0) { const int e = sc_last_err(); freeaddrinfo(ai); sc_set_err(e); return -1; }
  sc_reuse_addr(s);
  if (bind(s, ai->ai_addr, (sc_socklen)ai->ai_addrlen) != 0) {
    const int e = sc_last_err();
    freeaddrinfo(ai);
    sc_closesock(s);
    sc_set_err(e);
    return -1;
  }
  freeaddrinfo(ai);
  if (sc_io_set_nonblocking(SC_FD(s)) != 0) { const int e = sc_last_err(); sc_closesock(s); sc_set_err(e); return -1; }
  return SC_FD(s);
}

/* Send one datagram to host:port. The address is resolved per call, which keeps the Super-C side free of
   any sockaddr; a sender in a tight loop should hold a connected socket instead. */
long sc_udp_send_to(int fd, const void *buf, size_t n, const char *host, int port) {
  struct addrinfo *ai = 0, hints;
  char svc[16];
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_DGRAM;
  snprintf(svc, sizeof svc, "%d", port);
  if (getaddrinfo(host, svc, &hints, &ai) != 0 || !ai) return -1;
  const long r = (long)sendto(SC_SOCK(fd), (const char *)buf, (int)n, 0, ai->ai_addr, (sc_socklen)ai->ai_addrlen);
  freeaddrinfo(ai);
  return r;
}

/* Receive one datagram; the sender's address is discarded (there is nowhere platform-independent to put
   it yet). -1 with sc_io_would_block() means "nothing waiting". */
long sc_udp_recv(int fd, void *buf, size_t n) {
  return (long)recvfrom(SC_SOCK(fd), (char *)buf, (int)n, 0, 0, 0);
}
