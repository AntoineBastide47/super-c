/* Readiness poller + socket helpers declared in sc_io.h. kqueue on macOS/BSD, epoll on Linux; the two are
   the same model (tell me when this descriptor is ready) so one interface covers both. Not built for
   Windows -- IOCP is completion-based and needs a different interface, so the Super-C side gates this file
   out rather than pretending. */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include "sc_io.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/epoll.h>
#else
#include <sys/event.h>
#endif

typedef struct {
  int q;        /* kqueue / epoll descriptor */
  int wake[2];  /* self-pipe: read end stays registered, a write makes sc_io_wait return */
} sc_io_poller;

int sc_io_set_nonblocking(int fd) {
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl < 0) return -1;
  return fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

int sc_io_close(int fd) { return close(fd); }

int sc_io_would_block(void) {
  return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINPROGRESS || errno == EINTR;
}

long sc_io_read(int fd, void *buf, size_t n) { return (long)read(fd, buf, n); }
long sc_io_write(int fd, const void *buf, size_t n) { return (long)write(fd, buf, n); }

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
  /* The wake pipe stays registered level-triggered, with a NULL cookie the wait loop filters out. */
#if defined(__linux__)
  struct epoll_event ev;
  memset(&ev, 0, sizeof ev);
  ev.events = EPOLLIN;
  ev.data.ptr = 0;
  epoll_ctl(p->q, EPOLL_CTL_ADD, p->wake[0], &ev);
#else
  struct kevent kev;
  EV_SET(&kev, p->wake[0], EVFILT_READ, EV_ADD, 0, 0, 0);
  kevent(p->q, &kev, 1, 0, 0, 0);
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

int sc_io_arm(void *ptr, int fd, int write, void *udata) {
  sc_io_poller *p = (sc_io_poller *)ptr;
#if defined(__linux__)
  struct epoll_event ev;
  memset(&ev, 0, sizeof ev);
  ev.events = (write ? EPOLLOUT : EPOLLIN) | EPOLLONESHOT;
  ev.data.ptr = udata;
  if (epoll_ctl(p->q, EPOLL_CTL_ADD, fd, &ev) == 0) return 0;
  /* Already known to this epoll (a previous wait on the other direction): rearm it instead. */
  if (errno == EEXIST) return epoll_ctl(p->q, EPOLL_CTL_MOD, fd, &ev);
  return -1;
#else
  struct kevent kev;
  EV_SET(&kev, fd, write ? EVFILT_WRITE : EVFILT_READ, EV_ADD | EV_ONESHOT, 0, 0, udata);
  return kevent(p->q, &kev, 1, 0, 0, 0);
#endif
}

int sc_io_disarm(void *ptr, int fd, int write) {
  sc_io_poller *p = (sc_io_poller *)ptr;
#if defined(__linux__)
  (void)write;
  if (epoll_ctl(p->q, EPOLL_CTL_DEL, fd, 0) == 0) return 1;
  return errno == ENOENT ? 0 : -1;
#else
  struct kevent kev;
  EV_SET(&kev, fd, write ? EVFILT_WRITE : EVFILT_READ, EV_DELETE, 0, 0, 0);
  if (kevent(p->q, &kev, 1, 0, 0, 0) == 0) return 1;
  return errno == ENOENT ? 0 : -1;
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

int sc_io_wait(void *ptr, void **out, int max, int timeout_ms) {
  sc_io_poller *p = (sc_io_poller *)ptr;
  if (max > 64) max = 64;
  int n = 0;
#if defined(__linux__)
  struct epoll_event evs[64];
  n = epoll_wait(p->q, evs, max, timeout_ms);
#else
  struct kevent evs[64];
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
    void *u = evs[i].data.ptr;
#else
    void *u = evs[i].udata;
#endif
    if (!u) { /* the wake pipe: drain it and report nothing */
      char buf[64];
      while (read(p->wake[0], buf, sizeof buf) > 0) {
      }
      continue;
    }
    out[k++] = u;
  }
  return k;
}

/* ---- sockets --------------------------------------------------------------------------------------- */

/* Resolve host:port and hand back the first usable address. `host` NULL/empty means "any". */
static int sc_tcp_addr(const char *host, int port, struct addrinfo **out) {
  struct addrinfo hints;
  char svc[16];
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_INET; /* IPv4 only: enough for the API's promise, and one code path */
  hints.ai_socktype = SOCK_STREAM;
  if (!host || !*host) hints.ai_flags = AI_PASSIVE;
  snprintf(svc, sizeof svc, "%d", port);
  return getaddrinfo((host && *host) ? host : 0, svc, &hints, out);
}

int sc_tcp_listen(const char *host, int port, int backlog) {
  struct addrinfo *ai = 0;
  if (sc_tcp_addr(host, port, &ai) != 0 || !ai) return -1;
  int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
  if (fd < 0) { freeaddrinfo(ai); return -1; }
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  if (bind(fd, ai->ai_addr, ai->ai_addrlen) != 0 || listen(fd, backlog) != 0) {
    freeaddrinfo(ai);
    close(fd);
    return -1;
  }
  freeaddrinfo(ai);
  if (sc_io_set_nonblocking(fd) != 0) { close(fd); return -1; }
  return fd;
}

int sc_tcp_port(int fd) {
  struct sockaddr_storage ss;
  socklen_t len = sizeof ss;
  if (getsockname(fd, (struct sockaddr *)&ss, &len) != 0) return -1;
  if (ss.ss_family == AF_INET) return ntohs(((struct sockaddr_in *)&ss)->sin_port);
  if (ss.ss_family == AF_INET6) return ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
  return -1;
}

int sc_tcp_accept(int lfd) {
  int fd = accept(lfd, 0, 0);
  if (fd < 0) return -1;
  if (sc_io_set_nonblocking(fd) != 0) { close(fd); return -1; }
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  return fd;
}

int sc_tcp_connect(const char *host, int port) {
  struct addrinfo *ai = 0;
  if (sc_tcp_addr(host, port, &ai) != 0 || !ai) return -1;
  int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
  if (fd < 0) { freeaddrinfo(ai); return -1; }
  if (sc_io_set_nonblocking(fd) != 0) { freeaddrinfo(ai); close(fd); return -1; }
  int r = connect(fd, ai->ai_addr, ai->ai_addrlen);
  freeaddrinfo(ai);
  if (r == 0 || errno == EINPROGRESS) {
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    return fd; /* in progress: the caller waits for writability, then checks the result */
  }
  close(fd);
  return -1;
}

int sc_tcp_connect_result(int fd) {
  int err = 0;
  socklen_t len = sizeof err;
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0) return -1;
  return err;
}
