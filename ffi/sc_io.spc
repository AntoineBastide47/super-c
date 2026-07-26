// FFI bindings for the readiness poller and socket calls in ffi/sc_io.c (auto-discovered from "sc_io.h").
// POSIX only -- kqueue on macOS/BSD, epoll on Linux -- so the whole module is `@platform`-gated and no
// Windows build ever compiles it. These are the raw pieces `std/parallel/io.spc` (the reactor) and
// `std/parallel/net.spc` (TCP) are built from; prefer those. Import with `import sc_io;`.

@platform(macos | linux)
extern "C" "sc_io.h" {
    // A poller with its own wake pipe, or null. `wait` fills `out` with the cookies of ready registrations
    // and returns how many; `arm` is ONE-SHOT, so a registration that fires is already gone.
    pub fn sc_io_new() *mut void;
    pub fn sc_io_free(p: *mut void) void;
    pub fn sc_io_arm(p: *mut void, fd: i32, write: i32, udata: *mut void) i32;
    pub fn sc_io_disarm(p: *mut void, fd: i32, write: i32) i32;
    pub fn sc_io_wait(p: *mut void, out: *mut *mut void, max: i32, timeout_ms: i32) i32;
    pub fn sc_io_wake(p: *mut void) void;

    pub fn sc_io_set_nonblocking(fd: i32) i32;
    pub fn sc_io_close(fd: i32) i32;
    // Did the last call fail only for want of readiness? Check it immediately after a -1 return.
    pub fn sc_io_would_block() i32;
    pub fn sc_io_read(fd: i32, buf: *mut void, n: usize) isize;
    pub fn sc_io_write(fd: i32, buf: *const void, n: usize) isize;

    pub fn sc_tcp_listen(host: *const char, port: i32, backlog: i32) i32;
    pub fn sc_tcp_port(fd: i32) i32;
    pub fn sc_tcp_accept(lfd: i32) i32;
    pub fn sc_tcp_connect(host: *const char, port: i32) i32;
    pub fn sc_tcp_connect_result(fd: i32) i32;
}
