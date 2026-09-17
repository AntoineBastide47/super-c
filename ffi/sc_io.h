/* Readiness poller and the socket calls whose structs are platform-specific, for std/parallel/io and
   std/parallel/net. Three backends behind one interface: kqueue on macOS/BSD, epoll on Linux, select() on
   Windows (sockets only there: a SOCKET is not a CRT descriptor).

   The poller is READINESS-based and one-shot: an interest says "tell me once when this descriptor can be
   read (or written)", and the reactor thread turns the event back into a wake. Everything that would
   otherwise need `struct sockaddr`, `fd_set` or errno spelling lives here, so the Super-C side never
   encodes a platform layout. */
#ifndef SC_IO_H
#define SC_IO_H

#include <stddef.h>
#include <stdint.h>

/* ---- readiness poller ------------------------------------------------------------------------------ */

/* Interest and readiness bits. */
#define SC_IO_RD 1
#define SC_IO_WR 2
/* Most events one sc_io_wait returns (three ints each in `out`). */
#define SC_IO_EV_MAX 64

/* A poller plus its own wake channel. NULL on failure. Only the reactor thread calls wait and free. */
void *sc_io_new(void);
void sc_io_free(void *p);

/* Add the one-shot `want` bits (SC_IO_RD / SC_IO_WR) to the interest in `fd`. `known` says whether the
   caller believes the backend still holds a registration for `fd` (epoll keeps a fired one-shot
   registration, disabled, until the descriptor closes); a wrong guess costs one failed call, never the
   registration. 0 on success; 1 when the descriptor cannot be polled and is therefore always ready (a
   regular file under epoll); -1 with errno on failure. Callable from any thread. */
int sc_io_set(void *p, int fd, int want, int known);

/* Wait for readiness and fill `out` with up to `max` events of three ints each: the descriptor, its
   ready bits (an error or hang-up sets both), and the interest bits the backend dropped by reporting it.
   Returns the event count, or -1 on error. `timeout_ms` < 0 waits forever. Wake events are consumed here
   and never appear in `out`. */
int sc_io_wait(void *p, int *out, int max, int timeout_ms);

/* Make a blocked sc_io_wait return promptly. Callable from any thread. */
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
