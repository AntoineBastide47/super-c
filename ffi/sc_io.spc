// FFI bindings for the readiness poller and socket calls in ffi/sc_io.c (auto-discovered from "sc_io.h").
// One interface over three backends (kqueue on macOS/BSD, epoll on Linux, select() on Windows) so
// nothing here is platform-gated. These are the raw pieces `std/parallel/io.spc` (the reactor) and
// `std/parallel/net.spc` (TCP) are built from; prefer those. Import with `import sc_io;`.
//
// On Windows the poller watches SOCKETS ONLY: a socket is not a CRT file descriptor there, so `sc_io_read`
// and `sc_io_write` are recv/send and no file or pipe can be parked on. POSIX takes any descriptor.

extern "C" "sc_io.h" {
    /// A poller with its own wake channel, or null. `wait` fills `out` with the cookies of ready
    /// registrations and returns how many; `arm` is ONE-SHOT, so a registration that fires is already gone.
    pub fn sc_io_new() *mut void;
    /// Destroy a poller from sc_io_new.
    pub fn sc_io_free(p: *mut void) void;
    /// Watch `fd` for readability (or writability) once, reporting `udata` when ready; 0 or -1.
    pub fn sc_io_arm(p: *mut void, fd: i32, write: i32, udata: *mut void) i32;
    /// Stop watching `fd` for the given direction; 0 or -1.
    pub fn sc_io_disarm(p: *mut void, fd: i32, write: i32) i32;
    /// Block up to `timeout_ms` (-1 = forever) and collect up to `max` ready `udata` pointers into `out`;
    /// the count, 0 on timeout, -1 on error.
    pub fn sc_io_wait(p: *mut void, out: *mut *mut void, max: i32, timeout_ms: i32) i32;
    /// Interrupt a concurrent sc_io_wait.
    pub fn sc_io_wake(p: *mut void) void;
    /// One descriptor, no poller object: what a plain thread waits on. >0 ready, 0 timed out, -1 error.
    pub fn sc_io_wait_fd(fd: i32, write: i32, timeout_ms: i32) i32;

    /// Put `fd` in non-blocking mode; 0 or -1.
    pub fn sc_io_set_nonblocking(fd: i32) i32;
    /// close(2); 0 or -1.
    pub fn sc_io_close(fd: i32) i32;
    /// Did the last call fail only for want of readiness? Check it immediately after a -1 return.
    pub fn sc_io_would_block() i32;
    /// The raw errno (the WSA error code on Windows) of the last failing call, so a failure can say
    /// which one it was.
    pub fn sc_io_errno() i32;
    /// read(2): bytes read, 0 at EOF, -1 and errno (see sc_io_would_block).
    pub fn sc_io_read(fd: i32, buf: *mut void, n: usize) isize;
    /// write(2): bytes written, -1 and errno.
    pub fn sc_io_write(fd: i32, buf: *const void, n: usize) isize;

    /// The local port a socket is bound to, or -1.
    pub fn sc_tcp_port(fd: i32) i32;
    /// Accept one connection on a listening socket; the new non-blocking descriptor, or -1.
    pub fn sc_tcp_accept(lfd: i32) i32;
    /// Start a non-blocking connect to `host:port`; the descriptor, or -1. Completion is reported by
    /// sc_tcp_connect_result once writable.
    pub fn sc_tcp_connect(host: *const char, port: i32) i32;
    /// 0 once a pending connect succeeded, else the failure's errno value.
    pub fn sc_tcp_connect_result(fd: i32) i32;

    /// A UDP socket bound to `host:port` (port 0 = any); the descriptor, or -1.
    pub fn sc_udp_bind(host: *const char, port: i32) i32;
    /// Send one datagram to `host:port`; bytes sent, or -1.
    pub fn sc_udp_send_to(fd: i32, buf: *const void, n: usize, host: *const char, port: i32) isize;
    /// Receive one datagram; bytes received, or -1.
    pub fn sc_udp_recv(fd: i32, buf: *mut void, n: usize) isize;
}

// Every socket entry point above is in ws2_32 on Windows and in libc everywhere else. `@c.link` may only
// sit on an extern block, and an empty gated block carries no flag, so ONE declaration, no more special
// than its neighbours, is split by platform to give the flag a block of its own to ride on.
@platform(!windows)
extern "C" "sc_io.h" {
    /// A listening TCP socket on `host:port` (port 0 = any); the descriptor, or -1.
    pub fn sc_tcp_listen(host: *const char, port: i32, backlog: i32) i32;
}

@platform(windows)
@c.link("ws2_32")
extern "C" "sc_io.h" {
    /// A listening TCP socket on `host:port` (port 0 = any); the descriptor, or -1.
    pub fn sc_tcp_listen(host: *const char, port: i32, backlog: i32) i32;
}
