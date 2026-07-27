// FFI bindings for the readiness poller and socket calls in ffi/sc_io.c (auto-discovered from "sc_io.h").
// One interface over three backends -- kqueue on macOS/BSD, epoll on Linux, select() on Windows -- so
// nothing here is platform-gated. These are the raw pieces `std/parallel/io.spc` (the reactor) and
// `std/parallel/net.spc` (TCP) are built from; prefer those. Import with `import sc_io;`.
//
// On Windows the poller watches SOCKETS ONLY: a socket is not a CRT file descriptor there, so `sc_io_read`
// and `sc_io_write` are recv/send and no file or pipe can be parked on. POSIX takes any descriptor.

extern "C" "sc_io.h" {
    // A poller with its own wake channel, or null. `wait` fills `out` with the cookies of ready
    // registrations and returns how many; `arm` is ONE-SHOT, so a registration that fires is already gone.
    pub fn sc_io_new() *mut void;
    pub fn sc_io_free(p: *mut void) void;
    pub fn sc_io_arm(p: *mut void, fd: i32, write: i32, udata: *mut void) i32;
    pub fn sc_io_disarm(p: *mut void, fd: i32, write: i32) i32;
    pub fn sc_io_wait(p: *mut void, out: *mut *mut void, max: i32, timeout_ms: i32) i32;
    pub fn sc_io_wake(p: *mut void) void;
    // One descriptor, no poller object: what a plain thread waits on. >0 ready, 0 timed out, -1 error.
    pub fn sc_io_wait_fd(fd: i32, write: i32, timeout_ms: i32) i32;

    pub fn sc_io_set_nonblocking(fd: i32) i32;
    pub fn sc_io_close(fd: i32) i32;
    // Did the last call fail only for want of readiness? Check it immediately after a -1 return.
    pub fn sc_io_would_block() i32;
    // The raw errno -- the WSA error code on Windows -- of the last failing call, so a failure can say
    // which one it was.
    pub fn sc_io_errno() i32;
    pub fn sc_io_read(fd: i32, buf: *mut void, n: usize) isize;
    pub fn sc_io_write(fd: i32, buf: *const void, n: usize) isize;

    pub fn sc_tcp_port(fd: i32) i32;
    pub fn sc_tcp_accept(lfd: i32) i32;
    pub fn sc_tcp_connect(host: *const char, port: i32) i32;
    pub fn sc_tcp_connect_result(fd: i32) i32;

    pub fn sc_udp_bind(host: *const char, port: i32) i32;
    pub fn sc_udp_send_to(fd: i32, buf: *const void, n: usize, host: *const char, port: i32) isize;
    pub fn sc_udp_recv(fd: i32, buf: *mut void, n: usize) isize;
}

// Every socket entry point above is in ws2_32 on Windows and in libc everywhere else. `@c.link` may only
// sit on an extern block, and an empty gated block carries no flag -- so ONE declaration, no more special
// than its neighbours, is split by platform to give the flag a block of its own to ride on.
@platform(!windows)
extern "C" "sc_io.h" {
    pub fn sc_tcp_listen(host: *const char, port: i32, backlog: i32) i32;
}

@platform(windows)
@c.link("ws2_32")
extern "C" "sc_io.h" {
    pub fn sc_tcp_listen(host: *const char, port: i32, backlog: i32) i32;
}
