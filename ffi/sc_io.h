/* Readiness poller and the socket calls whose structs are platform-specific, for std/parallel/io and
   std/parallel/net. POSIX only (kqueue on macOS/BSD, epoll on Linux); the Super-C side is @platform-gated,
   so nothing here is compiled for a Windows target.

   The poller is READINESS-based: a registration is one-shot and says "tell me when this descriptor can be
   read (or written)". That is what lets a coroutine park on a descriptor -- the reactor thread turns the
   event back into a wake. Everything that would otherwise need `struct sockaddr`, `fd_set` or errno
   spelling lives here, so the Super-C side never encodes a platform layout. */
#ifndef SC_IO_H
#define SC_IO_H

#include <stddef.h>
#include <stdint.h>

/* ---- readiness poller ------------------------------------------------------------------------------ */

/* A poller plus its own wake pipe. NULL on failure. */
void *sc_io_new(void);
void sc_io_free(void *p);

/* Register one-shot interest in `fd` becoming readable (write == 0) or writable (write != 0). `udata` comes
   back from sc_io_wait when it fires. 0 on success. */
int sc_io_arm(void *p, int fd, int write, void *udata);

/* Drop a registration. 1 if one was actually removed, 0 if there was none, -1 on error. */
int sc_io_disarm(void *p, int fd, int write);

/* Wait for readiness and fill `out` with up to `max` udata pointers; returns how many, or -1 on error.
   `timeout_ms` < 0 waits forever. Wake-pipe events are consumed here and never appear in `out`. */
int sc_io_wait(void *p, void **out, int max, int timeout_ms);

/* Make a blocked sc_io_wait return promptly (shutdown). */
void sc_io_wake(void *p);

/* Wait on ONE descriptor without a poller object -- what a plain thread (no coroutine to park) needs.
   >0 ready, 0 timed out, -1 error; `timeout_ms` < 0 waits forever. */
int sc_io_wait_fd(int fd, int write, int timeout_ms);

/* ---- descriptors and sockets ------------------------------------------------------------------------ */

int sc_io_set_nonblocking(int fd);
int sc_io_close(int fd);
/* Did the last call fail only because it would have blocked (EAGAIN/EWOULDBLOCK/EINPROGRESS)? */
int sc_io_would_block(void);
/* The raw errno of the last failing call, for reporting WHICH failure it was. */
int sc_io_errno(void);
long sc_io_read(int fd, void *buf, size_t n);
long sc_io_write(int fd, const void *buf, size_t n);

/* A non-blocking listening socket bound to host:port (port 0 = let the OS choose). -1 on failure. */
int sc_tcp_listen(const char *host, int port, int backlog);
/* The port a socket is actually bound to -- how a caller learns the port after binding to 0. */
int sc_tcp_port(int fd);
/* Accept one connection, non-blocking. -1 with sc_io_would_block() means "not yet". */
int sc_tcp_accept(int lfd);
/* Start a non-blocking connect; the socket is writable once it resolves. -1 on immediate failure. */
int sc_tcp_connect(const char *host, int port);
/* 0 if a connect that was in progress succeeded, else its error code. */
int sc_tcp_connect_result(int fd);

/* UDP. `bind` with port 0 lets the OS choose (ask sc_tcp_port). Both transfers are non-blocking. */
int sc_udp_bind(const char *host, int port);
long sc_udp_send_to(int fd, const void *buf, size_t n, const char *host, int port);
long sc_udp_recv(int fd, void *buf, size_t n);

#endif
