// The readiness poller and the socket calls that `std/parallel/io.spc` (the reactor) and
// `std/parallel/net.spc` (TCP and UDP) are built from; prefer those. Import with `import sc_io;`. Every
// call requires `unsafe` except `sc_io_errno` and `sc_io_would_block`. Three poller backends behind one
// interface: kqueue on macOS and iOS, epoll on Linux and Android, select() on Windows.
//
// On Windows the poller watches SOCKETS ONLY: a socket is not a CRT file descriptor there, so `sc_io_read`
// and `sc_io_write` are recv/send and no file or pipe can be parked on. POSIX takes any descriptor.
// WASI preview 1 has no poller and no sockets: there `sc_io_new` returns null and every socket call fails
// with ENOTSUP; `sc_io_wait_fd` and the descriptor calls work.
import atomic;
import errno;
import fcntl;
import sc_runtime;
import stdlib;
import unistd;

/// Interest and readiness bits of the poller.
pub const RD: i32 = 1;
pub const WR: i32 = 2;
/// Most events one `sc_io_wait` returns; each is three `i32` values in the output buffer.
pub const EV_MAX: i32 = 64;

// Descriptor numbers the epoll interest table covers: the reactor's record bound (`REC_MAX` in
// std/parallel/io.spc).
@platform(linux | android)
const FD_CAP: usize = 4194304;

// ---- C bindings ------------------------------------------------------------------------------------------

@platform(!windows)
extern "C" "errno.h" {
    @platform(macos | ios)
    const EAGAIN: i32 = 35;
    @platform(macos | ios)
    const EWOULDBLOCK: i32 = 35;
    @platform(macos | ios)
    const EINPROGRESS: i32 = 36;
    @platform(macos | ios)
    const EINTR: i32 = 4;
    @platform(macos | ios)
    const EHOSTUNREACH: i32 = 65;

    @platform(linux | android)
    const EAGAIN: i32 = 11;
    @platform(linux | android)
    const EWOULDBLOCK: i32 = 11;
    @platform(linux | android)
    const EINPROGRESS: i32 = 115;
    @platform(linux | android)
    const EINTR: i32 = 4;
    @platform(linux | android)
    const EHOSTUNREACH: i32 = 113;
    @platform(linux | android)
    const EPERM: i32 = 1;
    @platform(linux | android)
    const ENOENT: i32 = 2;
    @platform(linux | android)
    const EEXIST: i32 = 17;
    @platform(linux | android)
    const EMFILE: i32 = 24;

    @platform(wasm)
    const EAGAIN: i32 = 6;
    @platform(wasm)
    const EWOULDBLOCK: i32 = 6;
    @platform(wasm)
    const EINPROGRESS: i32 = 26;
    @platform(wasm)
    const EINTR: i32 = 27;
    @platform(wasm)
    const ENOTSUP: i32 = 58;
}

@platform(!windows)
extern "C" "fcntl.h" {
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    @platform(macos | ios)
    const O_NONBLOCK: i32 = 4;
    @platform(linux | android)
    const O_NONBLOCK: i32 = 0x800;
    @platform(wasm)
    const O_NONBLOCK: i32 = 4;
    @platform(macos | ios)
    const F_SETFD: i32 = 2;
    @platform(macos | ios)
    const FD_CLOEXEC: i32 = 1;
}

@platform(macos | ios)
type nfds_t = u32;
@platform(linux | android | wasm)
type nfds_t = stdlib::c_ulong;

@platform(!windows)
extern "C" "poll.h" {
    struct pollfd {
        pub fd: i32,
        pub events: i16,
        pub revents: i16,
    }
    fn poll(fds: *mut pollfd, n: nfds_t, timeout_ms: i32) i32;
    const POLLIN: i16 = 1;
    @platform(macos | ios | linux | android)
    const POLLOUT: i16 = 4;
    @platform(wasm)
    const POLLOUT: i16 = 2;
}

// A socket as the system names it: a descriptor on POSIX, a handle-sized SOCKET on Windows.
@platform(macos | ios | linux | android)
type Sock = i32;
@platform(windows)
type Sock = usize;
@platform(macos | ios | linux | android)
type socklen_t = u32;
@platform(windows)
type socklen_t = i32;
// The width of a buffer length in recv/send/sendto/recvfrom.
@platform(macos | ios | linux | android)
type BufLen = usize;
@platform(windows)
type BufLen = i32;

@platform(macos | ios | linux | android)
extern "C" "sys/socket.h" {
    @platform(macos | ios)
    struct sockaddr {
        pub sa_len: u8,
        pub sa_family: u8,
        pub sa_data: [char; 14],
    }
    @platform(linux | android)
    struct sockaddr {
        pub sa_family: u16,
        pub sa_data: [char; 14],
    }
    @import("struct sockaddr_storage")
    @layout(128, 8)
    type sockaddr_storage;

    fn socket(domain: i32, kind: i32, protocol: i32) i32;
    fn accept(fd: i32, addr: *mut sockaddr, len: *mut socklen_t) i32;
    fn bind(fd: i32, addr: *const sockaddr, len: socklen_t) i32;
    fn listen(fd: i32, backlog: i32) i32;
    fn connect(fd: i32, addr: *const sockaddr, len: socklen_t) i32;
    fn getsockname(fd: i32, addr: *mut sockaddr, len: *mut socklen_t) i32;
    fn getsockopt(fd: i32, level: i32, name: i32, val: *mut void, len: *mut socklen_t) i32;
    fn setsockopt(fd: i32, level: i32, name: i32, val: *const void, len: socklen_t) i32;
    fn sendto(fd: i32, buf: *const void, n: usize, flags: i32, addr: *const sockaddr, len: socklen_t) isize;
    fn recvfrom(fd: i32, buf: *mut void, n: usize, flags: i32, addr: *mut sockaddr, len: *mut socklen_t) isize;

    const AF_UNSPEC: i32 = 0;
    const AF_INET: i32 = 2;
    const SOCK_STREAM: i32 = 1;
    const SOCK_DGRAM: i32 = 2;
    @platform(macos | ios)
    const AF_INET6: i32 = 30;
    @platform(macos | ios)
    const SOL_SOCKET: i32 = 0xFFFF;
    @platform(macos | ios)
    const SO_REUSEADDR: i32 = 4;
    @platform(macos | ios)
    const SO_ERROR: i32 = 0x1007;
    @platform(linux | android)
    const AF_INET6: i32 = 10;
    @platform(linux | android)
    const SOL_SOCKET: i32 = 1;
    @platform(linux | android)
    const SO_REUSEADDR: i32 = 2;
    @platform(linux | android)
    const SO_ERROR: i32 = 4;
    @platform(linux | android)
    const SOCK_CLOEXEC: i32 = 0x80000;
}

// sys/socket.h declares accept4 only under _GNU_SOURCE, which the build does not define: a block without
// a header gives it a prototype from this declaration.
@platform(linux | android)
extern "C" {
    fn accept4(fd: i32, addr: *mut sockaddr, len: *mut socklen_t, flags: i32) i32;
}

@platform(macos | ios | linux | android)
extern "C" "netinet/in.h" {
    struct in_addr {
        pub s_addr: u32,
    }
    @import("struct in6_addr")
    @layout(16, 4)
    type in6_addr;
    @platform(macos | ios)
    struct sockaddr_in {
        pub sin_len: u8,
        pub sin_family: u8,
        pub sin_port: u16,
        pub sin_addr: in_addr,
        pub sin_zero: [char; 8],
    }
    @platform(linux | android)
    struct sockaddr_in {
        pub sin_family: u16,
        pub sin_port: u16,
        pub sin_addr: in_addr,
        pub sin_zero: [u8; 8],
    }
    @platform(macos | ios)
    struct sockaddr_in6 {
        pub sin6_len: u8,
        pub sin6_family: u8,
        pub sin6_port: u16,
        pub sin6_flowinfo: u32,
        pub sin6_addr: in6_addr,
        pub sin6_scope_id: u32,
    }
    @platform(linux | android)
    struct sockaddr_in6 {
        pub sin6_family: u16,
        pub sin6_port: u16,
        pub sin6_flowinfo: u32,
        pub sin6_addr: in6_addr,
        pub sin6_scope_id: u32,
    }
    const IPPROTO_TCP: i32 = 6;
}

@platform(macos | ios | linux | android)
extern "C" "netinet/tcp.h" {
    const TCP_NODELAY: i32 = 1;
}

@platform(macos | ios | linux | android)
extern "C" "netdb.h" {
    // BSD order (Darwin, Bionic): the canonical name before the address.
    @platform(macos | ios | android)
    struct addrinfo {
        pub ai_flags: i32,
        pub ai_family: i32,
        pub ai_socktype: i32,
        pub ai_protocol: i32,
        pub ai_addrlen: socklen_t,
        pub ai_canonname: *mut char,
        pub ai_addr: *mut sockaddr,
        pub ai_next: *mut addrinfo,
    }
    @platform(linux)
    struct addrinfo {
        pub ai_flags: i32,
        pub ai_family: i32,
        pub ai_socktype: i32,
        pub ai_protocol: i32,
        pub ai_addrlen: socklen_t,
        pub ai_addr: *mut sockaddr,
        pub ai_canonname: *mut char,
        pub ai_next: *mut addrinfo,
    }
    fn getaddrinfo(node: *const char, service: *const char, hints: *const addrinfo, res: *mut *mut addrinfo) i32;
    fn freeaddrinfo(ai: *mut addrinfo);
    const AI_PASSIVE: i32 = 1;
    @platform(macos | ios | android)
    const EAI_SYSTEM: i32 = 11;
    @platform(linux)
    const EAI_SYSTEM: i32 = -11;
}

@platform(macos | ios)
extern "C" "time.h" {
    struct timespec {
        pub tv_sec: i64,
        pub tv_nsec: i64,
    }
}

// `struct kevent` is `#pragma pack(4)` in the header: no padding, aligned to 4.
@platform(macos | ios)
extern "C" "sys/event.h" {
    @packed
    @align(4)
    struct kevent {
        pub ident: usize,
        pub filter: i16,
        pub flags: u16,
        pub fflags: u32,
        pub data: isize,
        pub udata: *mut void,
    }
    fn kqueue() i32;
    @import("kevent")
    fn kevent_call(
        kq: i32,
        changes: *const kevent,
        nchanges: i32,
        events: *mut kevent,
        nevents: i32,
        timeout: *const timespec,
    ) i32;
    const EVFILT_READ: i16 = -1;
    const EVFILT_WRITE: i16 = -2;
    const EV_ADD: u16 = 0x1;
    const EV_ONESHOT: u16 = 0x10;
    const EV_ERROR: u16 = 0x4000;
    const EV_EOF: u16 = 0x8000;
}

// `struct epoll_event` is packed on x86-64 only (12 bytes there, 16 on aarch64).
@platform(linux | android)
extern "C" "sys/epoll.h" {
    union epoll_data {
        pub ptr: *mut void,
        pub fd: i32,
        @import("u32")
        pub v32: u32,
        @import("u64")
        pub v64: u64,
    }
    @arch(x86_64)
    @packed
    struct epoll_event {
        pub events: u32,
        pub data: epoll_data,
    }
    @arch(aarch64)
    struct epoll_event {
        pub events: u32,
        pub data: epoll_data,
    }
    fn epoll_create1(flags: i32) i32;
    fn epoll_ctl(epfd: i32, op: i32, fd: i32, ev: *mut epoll_event) i32;
    fn epoll_wait(epfd: i32, evs: *mut epoll_event, max: i32, timeout_ms: i32) i32;
    const EPOLLIN: u32 = 0x1;
    const EPOLLOUT: u32 = 0x4;
    const EPOLLERR: u32 = 0x8;
    const EPOLLHUP: u32 = 0x10;
    const EPOLLRDHUP: u32 = 0x2000;
    const EPOLLONESHOT: u32 = 0x40000000;
    const EPOLL_CTL_ADD: i32 = 1;
    const EPOLL_CTL_MOD: i32 = 3;
    const EPOLL_CLOEXEC: i32 = 0x80000;
}

@platform(linux | android)
extern "C" "sys/eventfd.h" {
    fn eventfd(count: u32, flags: i32) i32;
    const EFD_CLOEXEC: i32 = 0x80000;
    const EFD_NONBLOCK: i32 = 0x800;
}

// Winsock, in ws2_32. The header's FD_SETSIZE is 64; `SockSet` below is the same record with room for
// FD_SETSIZE sockets, which select() accepts because it reads `fd_count` entries.
@platform(windows)
@link("ws2_32")
extern "C" "ws2tcpip.h" {
    @import("WSADATA")
    @layout(408, 8)
    type WSADATA;
    struct sockaddr {
        pub sa_family: u16,
        pub sa_data: [char; 14],
    }
    @import("struct sockaddr_storage")
    @layout(128, 8)
    type sockaddr_storage;
    // `s_addr` is the header's macro for the union member `S_un.S_addr`.
    struct in_addr {
        pub s_addr: u32,
    }
    @import("struct in6_addr")
    @layout(16, 2)
    type in6_addr;
    struct sockaddr_in {
        pub sin_family: i16,
        pub sin_port: u16,
        pub sin_addr: in_addr,
        pub sin_zero: [char; 8],
    }
    // `sin6_scope_id` is a member of an unnamed union, the last member of the record.
    struct sockaddr_in6 {
        pub sin6_family: i16,
        pub sin6_port: u16,
        pub sin6_flowinfo: u32,
        pub sin6_addr: in6_addr,
        pub sin6_scope_id: u32,
    }
    struct addrinfo {
        pub ai_flags: i32,
        pub ai_family: i32,
        pub ai_socktype: i32,
        pub ai_protocol: i32,
        pub ai_addrlen: usize,
        pub ai_canonname: *mut char,
        pub ai_addr: *mut sockaddr,
        pub ai_next: *mut addrinfo,
    }
    struct timeval {
        pub tv_sec: i32,
        pub tv_usec: i32,
    }
    struct fd_set {
        pub fd_count: u32,
        pub fd_array: [usize; 64],
    }

    fn WSAStartup(version: u16, data: *mut WSADATA) i32;
    fn WSAGetLastError() i32;
    fn WSASetLastError(e: i32);
    fn WSASocketW(af: i32, kind: i32, protocol: i32, info: *mut void, group: u32, flags: u32) usize;
    fn closesocket(s: usize) i32;
    // `arg` is a `u_long *`: a 4-byte unsigned long, which no Super-C type spells.
    fn ioctlsocket(s: usize, cmd: i32, arg: *mut void) i32;
    fn accept(s: usize, addr: *mut sockaddr, len: *mut socklen_t) usize;
    fn bind(s: usize, addr: *const sockaddr, len: socklen_t) i32;
    fn listen(s: usize, backlog: i32) i32;
    fn connect(s: usize, addr: *const sockaddr, len: socklen_t) i32;
    fn getsockname(s: usize, addr: *mut sockaddr, len: *mut socklen_t) i32;
    fn getsockopt(s: usize, level: i32, name: i32, val: *mut void, len: *mut socklen_t) i32;
    fn setsockopt(s: usize, level: i32, name: i32, val: *const void, len: socklen_t) i32;
    fn recv(s: usize, buf: *mut void, n: i32, flags: i32) i32;
    fn send(s: usize, buf: *const void, n: i32, flags: i32) i32;
    fn sendto(s: usize, buf: *const void, n: i32, flags: i32, addr: *const sockaddr, len: socklen_t) i32;
    fn recvfrom(s: usize, buf: *mut void, n: i32, flags: i32, addr: *mut sockaddr, len: *mut socklen_t) i32;
    @import("select")
    fn select_sockets(nfds: i32, rd: *mut fd_set, wr: *mut fd_set, ex: *mut fd_set, timeout: *const timeval) i32;
    fn getaddrinfo(node: *const char, service: *const char, hints: *const addrinfo, res: *mut *mut addrinfo) i32;
    fn freeaddrinfo(ai: *mut addrinfo);

    const WSAEINTR: i32 = 10004;
    const WSAEMFILE: i32 = 10024;
    const WSAEWOULDBLOCK: i32 = 10035;
    const WSAEINPROGRESS: i32 = 10036;
    const WSAENOTSOCK: i32 = 10038;
    const WSAEHOSTUNREACH: i32 = 10065;
    const AF_UNSPEC: i32 = 0;
    const AF_INET: i32 = 2;
    const AF_INET6: i32 = 23;
    const SOCK_STREAM: i32 = 1;
    const SOCK_DGRAM: i32 = 2;
    const IPPROTO_TCP: i32 = 6;
    const TCP_NODELAY: i32 = 1;
    const SOL_SOCKET: i32 = 0xFFFF;
    const SO_EXCLUSIVEADDRUSE: i32 = -5;
    const SO_ERROR: i32 = 0x1007;
    const SO_TYPE: i32 = 0x1008;
    const AI_PASSIVE: i32 = 1;
    const FIONBIO: u32 = 0x8004667E;
    const WSA_FLAG_OVERLAPPED: u32 = 0x1;
    const WSA_FLAG_NO_HANDLE_INHERIT: u32 = 0x80;
    const INADDR_LOOPBACK: u32 = 0x7F000001;
    const INVALID_SOCKET: usize = 0xFFFFFFFFFFFFFFFF;
    const SOCKET_ERROR: i32 = -1;
}

@platform(windows)
extern "C" "windows.h" {
    @import("CRITICAL_SECTION")
    @layout(40, 8)
    type CRITICAL_SECTION;
    fn InitializeCriticalSection(cs: *mut CRITICAL_SECTION);
    fn DeleteCriticalSection(cs: *mut CRITICAL_SECTION);
    fn EnterCriticalSection(cs: *mut CRITICAL_SECTION);
    fn LeaveCriticalSection(cs: *mut CRITICAL_SECTION);
    fn SetHandleInformation(h: *mut void, mask: u32, flags: u32) i32;
    fn Sleep(ms: u32);
    const HANDLE_FLAG_INHERIT: u32 = 0x1;
}

// ---- errors ----------------------------------------------------------------------------------------------

@platform(windows)
fn last_err() i32 {
    return unsafe WSAGetLastError();
}

@platform(!windows)
fn last_err() i32 {
    return errno::errno();
}

// Put a captured error back after cleanup. Winsock resets the last error on any SUCCESSFUL call, so a
// closesocket() or freeaddrinfo() between a failure and the caller reading sc_io_errno() erases it, which
// turns "address in use" into "code 0, kind Other". Every failure path therefore captures the error before
// it tidies up and restores it just before it returns.
@platform(windows)
fn set_err(e: i32) {
    unsafe WSASetLastError(e);
}

@platform(macos | ios | linux | android)
fn set_err(e: i32) {
    errno::set_errno(e);
}

/// The raw errno (the WSA error code on Windows) of the last failing call, so a failure can say which one
/// it was.
pub fn sc_io_errno() i32 {
    return last_err();
}

/// Did the last call fail only for want of readiness (or a signal)? Check it immediately after a -1 return.
@platform(windows)
pub fn sc_io_would_block() i32 {
    let e = last_err();
    return (e == WSAEWOULDBLOCK || e == WSAEINPROGRESS || e == WSAEINTR) as i32;
}

/// Did the last call fail only for want of readiness (or a signal)? Check it immediately after a -1 return.
@platform(!windows)
pub fn sc_io_would_block() i32 {
    let e = last_err();
    return (e == EAGAIN || e == EWOULDBLOCK || e == EINPROGRESS || e == EINTR) as i32;
}

// ---- descriptors -----------------------------------------------------------------------------------------

/// Put `fd` in non-blocking mode; 0 or -1.
@platform(windows)
pub unsafe fn sc_io_set_nonblocking(fd: i32) i32 {
    let mut on: u32 = 1;
    return if unsafe ioctlsocket(sock_of(fd), FIONBIO as i32, &mut on) == 0 {
        0;
    } else {
        -1;
    };
}

/// Put `fd` in non-blocking mode; 0 or -1.
@platform(!windows)
pub unsafe fn sc_io_set_nonblocking(fd: i32) i32 {
    let fl = unsafe fcntl::fcntl(fd, F_GETFL, 0);
    if fl < 0 {
        return -1;
    }
    return unsafe fcntl::fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/// Close a socket; 0 or -1.
@platform(windows)
pub unsafe fn sc_io_close(fd: i32) i32 {
    return unsafe closesocket(sock_of(fd));
}

/// close(2); 0 or -1.
@platform(!windows)
pub unsafe fn sc_io_close(fd: i32) i32 {
    return unsafe unistd::close(fd);
}

/// recv on a socket: bytes read, 0 at EOF, -1 and the error (see sc_io_would_block).
@platform(windows)
pub unsafe fn sc_io_read(fd: i32, buf: *mut void, n: usize) isize {
    return (unsafe recv(sock_of(fd), buf, n as i32, 0)) as isize;
}

/// read(2): bytes read, 0 at EOF, -1 and errno (see sc_io_would_block).
@platform(!windows)
pub unsafe fn sc_io_read(fd: i32, buf: *mut void, n: usize) isize {
    return unsafe unistd::read(fd, buf, n);
}

/// send on a socket: bytes written, -1 and the error.
@platform(windows)
pub unsafe fn sc_io_write(fd: i32, buf: *const void, n: usize) isize {
    return (unsafe send(sock_of(fd), buf, n as i32, 0)) as isize;
}

/// write(2): bytes written, -1 and errno.
@platform(!windows)
pub unsafe fn sc_io_write(fd: i32, buf: *const void, n: usize) isize {
    return unsafe unistd::write(fd, buf, n);
}

// ---- readiness poller ------------------------------------------------------------------------------------
//
// The interface is one-shot and mask-based. `sc_io_set` adds the `want` bits (RD / WR) to the OS interest
// in `fd`; a bit that fires is consumed (the backend disarms it) and reported once through `sc_io_wait` as
// a (fd, ready, dropped) triple. `dropped` names the interest bits the backend no longer holds after that
// event: on epoll a one-shot registration disables the whole descriptor, so both bits are dropped by
// either; kqueue and select drop only the one that fired. The reactor owns the per-descriptor state and
// arms again what it still needs. The descriptor number is the identity: no cookie crosses this boundary.
//
// Registration may come from any thread; only the reactor calls `sc_io_wait` and `sc_io_free`;
// `sc_io_wake` may come from any thread. Interests are never removed one by one: a one-shot that fires is
// gone, a descriptor closed is gone, and the poller's release drops the rest.

// kqueue or epoll plus a wake channel whose read end stays registered: a write to it makes sc_io_wait
// return. The channel is a pipe on macOS and one eventfd (both ends) on Linux.
@platform(macos | ios | linux | android)
struct Poller {
    pub q: i32,
    pub wake: [i32; 2],
    // Linux: per descriptor, the bits registered since its last delivered event. epoll keeps one mask per
    // descriptor and a modification replaces it, so each registration carries the union. Zero pages until
    // touched. Null on macOS.
    pub want: *mut u8,
}

// No socket or poller descriptor leaks into a spawned child: a child that holds a listening socket keeps
// the port bound after the parent closes it. Linux and Windows set this at creation; macOS has no creation
// flag, so it sets it right after, which leaves a window only against a spawn on another thread.
@platform(macos | ios)
fn cloexec(fd: i32) {
    if fd >= 0 {
        let _ = unsafe fcntl::fcntl(fd, F_SETFD, FD_CLOEXEC);
    }
}

/// A poller with its own wake channel, or null. Only the reactor thread may call `wait` and `free`; `set`
/// and `wake` may come from any thread.
@platform(macos | ios)
pub unsafe fn sc_io_new() *mut void {
    unsafe {
        let p = stdlib::calloc(1, sizeof(Poller)) as *mut Poller;
        if p == null {
            return null;
        }
        let q = kqueue();
        if q < 0 {
            stdlib::free(p);
            return null;
        }
        cloexec(q);
        let mut w: [i32; 2] = [-1, -1];
        if unistd::pipe(&mut w[0]) != 0 {
            unistd::close(q);
            stdlib::free(p);
            return null;
        }
        cloexec(w[0]);
        cloexec(w[1]);
        sc_io_set_nonblocking(w[0]);
        sc_io_set_nonblocking(w[1]);
        (*p).q = q;
        (*p).wake = w;
        // The wake pipe stays registered level-triggered; the wait loop recognizes it by descriptor.
        let kev = kevent { ident: w[0] as usize, filter: EVFILT_READ, flags: EV_ADD };
        if kevent_call(q, &kev, 1, null, 0, null) != 0 {
            sc_io_free(p);
            return null;
        }
        return p;
    }
}

/// A poller with its own wake channel, or null. Only the reactor thread may call `wait` and `free`; `set`
/// and `wake` may come from any thread.
@platform(linux | android)
pub unsafe fn sc_io_new() *mut void {
    unsafe {
        let p = stdlib::calloc(1, sizeof(Poller)) as *mut Poller;
        if p == null {
            return null;
        }
        let want = stdlib::calloc(FD_CAP, 1) as *mut u8;
        if want == null {
            stdlib::free(p);
            return null;
        }
        let q = epoll_create1(EPOLL_CLOEXEC);
        if q < 0 {
            stdlib::free(want);
            stdlib::free(p);
            return null;
        }
        let w = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
        if w < 0 {
            unistd::close(q);
            stdlib::free(want);
            stdlib::free(p);
            return null;
        }
        (*p).q = q;
        (*p).wake = [w, w];
        (*p).want = want;
        // The wake eventfd stays registered level-triggered; the wait loop recognizes it by descriptor.
        let mut ev = epoll_event { events: EPOLLIN, data: epoll_data { fd: w } };
        if epoll_ctl(q, EPOLL_CTL_ADD, w, &mut ev) != 0 {
            sc_io_free(p);
            return null;
        }
        return p;
    }
}

/// Destroy a poller from sc_io_new; null is ignored.
@platform(macos | ios | linux | android)
pub unsafe fn sc_io_free(ptr: *mut void) {
    let p = ptr as *mut Poller;
    if p == null {
        return;
    }
    unsafe {
        unistd::close((*p).wake[0]);
        if (*p).wake[1] != (*p).wake[0] {
            unistd::close((*p).wake[1]);
        }
        unistd::close((*p).q);
        stdlib::free((*p).want);
        stdlib::free(p);
    }
}

/// Add the ONE-SHOT `want` bits to the interest in `fd`; `known` says the backend still holds a
/// registration for `fd` (epoll keeps a fired one, disabled). 0 on success, 1 when the descriptor cannot
/// be polled and is always ready, -1 with errno on failure. Callable from any thread.
@platform(macos | ios)
pub unsafe fn sc_io_set(ptr: *mut void, fd: i32, want: i32, _known: i32) i32 {
    let p = unsafe *(ptr as *const Poller);
    // A number that names the poller's own descriptors is a closed file's, taken by a poller created after
    // the close. Registered, the wake pipe's read end would become one-shot and every later wake would be
    // lost: refused, so the wait settles as not ready, the answer a closed descriptor gets.
    if fd == p.q || fd == p.wake[0] || fd == p.wake[1] {
        return -1;
    }
    // Read and write are separate knotes: add what is wanted (EV_ADD on an existing knote refreshes it, so
    // a descriptor reused under the reactor is registered afresh). With no event list, a change that fails
    // makes the call fail with its errno, and nothing pending is drained.
    let mut ch = unsafe zeroed::<[kevent; 2]>();
    let mut n: usize = 0;
    if (want & RD) != 0 {
        ch[0] = kevent { ident: fd as usize, filter: EVFILT_READ, flags: EV_ADD | EV_ONESHOT };
        n = 1;
    }
    if (want & WR) != 0 {
        unsafe ch[n] = kevent { ident: fd as usize, filter: EVFILT_WRITE, flags: EV_ADD | EV_ONESHOT };
        n = n + 1;
    }
    if n == 0 {
        return 0;
    }
    return if unsafe kevent_call(p.q, &ch[0], n as i32, null, 0, null) < 0 {
        -1;
    } else {
        0;
    };
}

/// Add the ONE-SHOT `want` bits to the interest in `fd`; `known` says the backend still holds a
/// registration for `fd` (epoll keeps a fired one, disabled). 0 on success, 1 when the descriptor cannot
/// be polled and is always ready, -1 with errno on failure. Callable from any thread.
@platform(linux | android)
pub unsafe fn sc_io_set(ptr: *mut void, fd: i32, want: i32, known: i32) i32 {
    let p = unsafe *(ptr as *const Poller);
    // A number that names the poller's own descriptors is a closed file's (see the macOS backend).
    if fd == p.q || fd == p.wake[0] {
        return -1;
    }
    // One registration per descriptor carries both directions, and a modification replaces its mask: a
    // registration that left out the other direction would drop that direction's interest, and its event
    // if still queued, with nothing to tell the reactor. So each call registers the union of the bits
    // registered since the descriptor's last event (`want`, cleared when sc_io_wait reports it), and
    // registers again while another thread added bits after it read the union: the last registration then
    // holds every bit, and the loop ends within one pass per bit. A one-shot registration that fired is
    // disabled, not gone, so it is modified rather than added; a descriptor closed and reused under the
    // reactor has no registration any more (ENOENT), and the fresh add takes over. EPERM is a descriptor
    // epoll cannot watch (a regular file): it is always ready, which is what 1 tells the reactor.
    if fd < 0 || fd as usize >= FD_CAP {
        errno::set_errno(EMFILE);
        return -1;
    }
    let u = unsafe (p.want + fd as usize);
    let mut m = (unsafe atomic::or_u8(u, want as u8, 4) | want as u8) as i32;
    let mut kn = known != 0;
    loop {
        let mut events = EPOLLONESHOT;
        if (m & RD) != 0 {
            events = events | EPOLLIN;
        }
        if (m & WR) != 0 {
            events = events | EPOLLOUT;
        }
        let mut ev = epoll_event { events: events, data: epoll_data { fd: fd } };
        let mut rc = 0;
        if kn && unsafe epoll_ctl(p.q, EPOLL_CTL_MOD, fd, &mut ev) == 0 {
            rc = 0;
        } else if kn && errno::errno() != ENOENT {
            rc = unwatchable_or_failed();
        } else if unsafe epoll_ctl(p.q, EPOLL_CTL_ADD, fd, &mut ev) == 0 {
            rc = 0;
        } else if errno::errno() == EEXIST {
            rc = if unsafe epoll_ctl(p.q, EPOLL_CTL_MOD, fd, &mut ev) == 0 {
                0;
            } else {
                -1;
            };
        } else {
            rc = unwatchable_or_failed();
        }
        let now = (unsafe atomic::load_u8(u, 4)) as i32;
        if rc != 0 || (now & ~m) == 0 {
            return rc;
        }
        m = m | now;
        kn = true;
    }
}

// The answer to a failed epoll_ctl: 1 for a descriptor epoll cannot watch (always ready), else -1.
@platform(linux | android)
fn unwatchable_or_failed() i32 {
    return if errno::errno() == EPERM {
        1;
    } else {
        -1;
    };
}

/// Interrupt a concurrent sc_io_wait; null is ignored. Callable from any thread.
@platform(macos | ios | linux | android)
pub unsafe fn sc_io_wake(ptr: *mut void) {
    let p = ptr as *const Poller;
    if p == null {
        return;
    }
    // Eight bytes: an eventfd takes exactly a u64 counter increment, and a pipe takes any length. A failed
    // write is a full pipe, so a wake is already pending.
    let one: u64 = 1;
    let _ = unsafe unistd::write((*p).wake[1], &one, 8);
}

/// Block up to `timeout_ms` (-1 = forever) and collect up to `max` events into `out`, three `i32` each:
/// the descriptor, its ready bits (an error or hang-up sets both), and the interest bits the backend
/// dropped by reporting it. The count, 0 on timeout, -1 on error. Wake events never appear in `out`.
@platform(macos | ios)
pub unsafe fn sc_io_wait(ptr: *mut void, out: *mut i32, max: i32, timeout_ms: i32) i32 {
    let p = unsafe *(ptr as *const Poller);
    let lim = if max > EV_MAX {
        EV_MAX;
    } else {
        max;
    };
    let mut evs = unsafe zeroed::<[kevent; EV_MAX as usize]>();
    let ts = timespec { tv_sec: timeout_ms / 1000, tv_nsec: (timeout_ms % 1000) as i64 * 1000000 };
    let tp: *const timespec = if timeout_ms >= 0 {
        &ts;
    } else {
        null;
    };
    let n = unsafe kevent_call(p.q, null, 0, &mut evs[0], lim, tp);
    if n < 0 {
        return if errno::errno() == EINTR {
            0;
        } else {
            -1;
        };
    }
    let mut k: usize = 0;
    for i in 0..n as usize {
        let e = unsafe evs[i];
        let fd = e.ident as i32;
        if fd == p.wake[0] {
            drain(fd);
            continue;
        }
        let mut ready = if e.filter == EVFILT_WRITE {
            WR;
        } else {
            RD;
        };
        let dropped = ready;
        if (e.flags & (EV_EOF | EV_ERROR)) != 0 {
            ready = RD | WR;
        }
        unsafe {
            out[3 * k] = fd;
            out[3 * k + 1] = ready;
            out[3 * k + 2] = dropped;
        }
        k = k + 1;
    }
    return k as i32;
}

/// Block up to `timeout_ms` (-1 = forever) and collect up to `max` events into `out`, three `i32` each:
/// the descriptor, its ready bits (an error or hang-up sets both), and the interest bits the backend
/// dropped by reporting it. The count, 0 on timeout, -1 on error. Wake events never appear in `out`.
@platform(linux | android)
pub unsafe fn sc_io_wait(ptr: *mut void, out: *mut i32, max: i32, timeout_ms: i32) i32 {
    let p = unsafe *(ptr as *const Poller);
    let lim = if max > EV_MAX {
        EV_MAX;
    } else {
        max;
    };
    let mut evs = unsafe zeroed::<[epoll_event; EV_MAX as usize]>();
    let n = unsafe epoll_wait(p.q, &mut evs[0], lim, timeout_ms);
    if n < 0 {
        return if errno::errno() == EINTR {
            0;
        } else {
            -1;
        };
    }
    let mut k: usize = 0;
    for i in 0..n as usize {
        let e = unsafe evs[i];
        let fd = e.data.fd;
        if fd == p.wake[0] {
            drain(fd);
            continue;
        }
        // The one-shot fired and holds nothing now: the next registration starts a new union.
        unsafe atomic::store_u8(unsafe (p.want + fd as usize), 0, 4);
        let mut ready = 0;
        if (e.events & (EPOLLIN | EPOLLRDHUP)) != 0 {
            ready = ready | RD;
        }
        if (e.events & EPOLLOUT) != 0 {
            ready = ready | WR;
        }
        if (e.events & (EPOLLERR | EPOLLHUP)) != 0 {
            ready = RD | WR;
        }
        unsafe {
            out[3 * k] = fd;
            out[3 * k + 1] = ready;
            // One-shot disables the whole registration.
            out[3 * k + 2] = RD | WR;
        }
        k = k + 1;
    }
    return k as i32;
}

// Empty the non-blocking wake channel.
@platform(macos | ios | linux | android)
fn drain(fd: i32) {
    let mut buf: [u8; 64] = [0u8; 64];
    while unsafe unistd::read(fd, &mut buf[0], 64) > 0 {}
}

/// One descriptor, no poller object: what a plain thread waits on. >0 ready, 0 timed out, -1 error;
/// `timeout_ms` < 0 waits forever.
@platform(!windows)
pub unsafe fn sc_io_wait_fd(fd: i32, write: i32, timeout_ms: i32) i32 {
    let mut p = pollfd {
        fd: fd,
        events: if write != 0 {
            POLLOUT;
        } else {
            POLLIN;
        },
        revents: 0,
    };
    // A signal interrupts poll: wait again for what remains, so an interruption never reads as a timeout.
    let t0 = sc_runtime::sc_rt_now_ns();
    let mut left = timeout_ms;
    loop {
        let r = unsafe poll(&mut p, 1, left);
        if r >= 0 || errno::errno() != EINTR {
            return r;
        }
        if timeout_ms > 0 {
            let ms = (sc_runtime::sc_rt_now_ns() - t0) / 1000000;
            left = if ms >= timeout_ms as u64 {
                0;
            } else {
                timeout_ms - ms as i32;
            };
        }
    }
}

// ---- WASI: no poller object ------------------------------------------------------------------------------

// WASI preview 1 has no socket(), bind(), connect() or name resolution, and no descriptor that could wake a
// poller (no pipe, no socketpair): the socket calls and the poller object report ENOTSUP there, and only
// the single-descriptor wait (sc_io_wait_fd, over poll) works.
@platform(wasm)
fn unsupported() i32 {
    errno::set_errno(ENOTSUP);
    return -1;
}

/// Null with errno ENOTSUP: WASI has no poller.
@platform(wasm)
pub unsafe fn sc_io_new() *mut void {
    errno::set_errno(ENOTSUP);
    return null;
}

/// Nothing to destroy on WASI.
@platform(wasm)
pub unsafe fn sc_io_free(_ptr: *mut void) {}

/// -1 with errno ENOTSUP.
@platform(wasm)
pub unsafe fn sc_io_set(_ptr: *mut void, _fd: i32, _want: i32, _known: i32) i32 {
    return unsupported();
}

/// Nothing to wake on WASI.
@platform(wasm)
pub unsafe fn sc_io_wake(_ptr: *mut void) {}

/// -1 with errno ENOTSUP.
@platform(wasm)
pub unsafe fn sc_io_wait(_ptr: *mut void, _out: *mut i32, _max: i32, _timeout_ms: i32) i32 {
    return unsupported();
}

/// -1 with errno ENOTSUP.
@platform(wasm)
pub unsafe fn sc_tcp_listen(_host: *const char, _port: i32, _backlog: i32) i32 {
    return unsupported();
}

/// -1 with errno ENOTSUP.
@platform(wasm)
pub unsafe fn sc_tcp_port(_fd: i32) i32 {
    return unsupported();
}

/// -1 with errno ENOTSUP.
@platform(wasm)
pub unsafe fn sc_tcp_accept(_lfd: i32) i32 {
    return unsupported();
}

/// -1 with errno ENOTSUP.
@platform(wasm)
pub unsafe fn sc_tcp_connect(_host: *const char, _port: i32) i32 {
    return unsupported();
}

/// -1 with errno ENOTSUP.
@platform(wasm)
pub unsafe fn sc_tcp_connect_result(_fd: i32) i32 {
    return unsupported();
}

/// -1 with errno ENOTSUP.
@platform(wasm)
pub unsafe fn sc_udp_bind(_host: *const char, _port: i32) i32 {
    return unsupported();
}

/// -1 with errno ENOTSUP.
@platform(wasm)
pub unsafe fn sc_udp_send_to(_fd: i32, _buf: *const void, _n: usize, _host: *const char, _port: i32) isize {
    return unsupported() as isize;
}

/// -1 with errno ENOTSUP.
@platform(wasm)
pub unsafe fn sc_udp_recv(_fd: i32, _buf: *mut void, _n: usize) isize {
    return unsupported() as isize;
}

// ---- Windows: select() over sockets ----------------------------------------------------------------------
//
// Windows uses select(), not WSAPoll(): WSAPoll does not report a FAILED connection attempt, so a connect to
// a closed port would never become ready and the caller would hang until its deadline instead of learning
// it was refused. select() reports that through the exception set, which is why a connecting socket is
// registered there as well as in the write set. The cost is a ceiling of FD_SETSIZE sockets per set.

// The reactor's hard ceiling on simultaneously parked sockets; sc_io_set reports it rather than overflow a
// set.
@platform(windows)
const FD_SETSIZE: usize = 1024;

// An fd_set with room for FD_SETSIZE sockets: the header's record with a longer array.
@platform(windows)
struct SockSet {
    pub count: u32,
    pub socks: [usize; FD_SETSIZE],
}

// An fd_set of one socket.
@platform(windows)
struct OneSock {
    pub count: u32,
    pub sock: usize,
}

// One registration: the table is rebuilt into the sets on every wait, which is select()'s cost model.
@platform(windows)
struct Reg {
    pub s: usize,
    pub dir: i32,
}

// The sets live in the poller: only the reactor thread waits, so they need no lock and no stack.
@platform(windows)
struct WinPoller {
    pub lock: CRITICAL_SECTION, // workers register, the reactor rebuilds the sets
    pub regs: [Reg; FD_SETSIZE],
    pub n: usize,
    pub wake_r: usize, // a loopback pair: Windows has no socketpair, and select cannot watch a pipe
    pub wake_w: usize,
    pub rd: SockSet,
    pub wr: SockSet,
    pub ex: SockSet,
}

// FD_SET: add `s` unless the set holds it.
@platform(windows)
unsafe fn set_add(set: *mut SockSet, s: usize) {
    unsafe {
        let n = (*set).count as usize;
        for i in 0..n {
            if (*set).socks[i] == s {
                return;
            }
        }
        (*set).socks[n] = s;
        (*set).count = (n + 1) as u32;
    }
}

// FD_ISSET.
@platform(windows)
unsafe fn set_has(set: *const SockSet, s: usize) bool {
    unsafe {
        for i in 0..(*set).count as usize {
            if (*set).socks[i] == s {
                return true;
            }
        }
    }
    return false;
}

// The wake channel: connect a socket to a listener of our own on the loopback, keep both ends. The writer
// sends one byte per wake and nothing ever flows back, so under Nagle a second wake within Windows' 200 ms
// delayed-ACK window would sit in the send buffer until that ACK arrived: a reactor wake 200 ms late, on
// every wake after the first. TCP_NODELAY sends each byte at once. The read end and the write end, or
// false.
@platform(windows)
fn wake_pair() (bool, usize, usize) {
    unsafe {
        let l = open_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if l == INVALID_SOCKET {
            return false, 0, 0;
        }
        let mut a = sockaddr_in { sin_family: AF_INET as i16, sin_addr: in_addr { s_addr: htonl(INADDR_LOOPBACK) } };
        let ap = ((&mut a) as *mut sockaddr_in) as *mut sockaddr;
        let mut alen = sizeof(sockaddr_in) as socklen_t;
        if bind(l, ap, alen) != 0 || listen(l, 1) != 0 || getsockname(l, ap, &mut alen) != 0 {
            closesocket(l);
            return false, 0, 0;
        }
        let c = open_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if c == INVALID_SOCKET {
            closesocket(l);
            return false, 0, 0;
        }
        if connect(c, ap, alen) != 0 {
            closesocket(l);
            closesocket(c);
            return false, 0, 0;
        }
        let s = accept_socket(l);
        closesocket(l);
        if s == INVALID_SOCKET {
            closesocket(c);
            return false, 0, 0;
        }
        sc_io_set_nonblocking(fd_of(s));
        sc_io_set_nonblocking(fd_of(c));
        no_delay(c);
        return true, s, c;
    }
}

// Whether the handle still names a socket. closesocket() may overlap a select() on the same socket (the
// reactor blocks in one while a closer runs), which Winsock leaves unspecified: in practice select() either
// fails with WSAENOTSOCK or returns with the dead socket flagged. Both paths probe before they report.
@platform(windows)
fn sock_alive(s: usize) bool {
    let mut kind: i32 = 0;
    let mut len = sizeof(i32) as socklen_t;
    return unsafe getsockopt(s, SOL_SOCKET, SO_TYPE, &mut kind, &mut len) == 0;
}

@platform(windows)
unsafe fn reg_add(p: *mut WinPoller, s: usize, dir: i32) i32 {
    unsafe {
        let n = (*p).n;
        for i in 0..n {
            if (*p).regs[i].s == s && (*p).regs[i].dir == dir {
                return 0;
            }
        }
        // +1 for the wake socket, which is in every read set.
        if n + 1 >= FD_SETSIZE {
            WSASetLastError(WSAEMFILE);
            return -1;
        }
        (*p).regs[n] = Reg { s: s, dir: dir };
        (*p).n = n + 1;
    }
    return 0;
}

/// A poller with its own wake channel, or null. Only the reactor thread may call `wait` and `free`; `set`
/// and `wake` may come from any thread.
@platform(windows)
pub unsafe fn sc_io_new() *mut void {
    startup();
    unsafe {
        let p = stdlib::calloc(1, sizeof(WinPoller)) as *mut WinPoller;
        if p == null {
            return null;
        }
        let (ok, r, w) = wake_pair();
        if !ok {
            stdlib::free(p);
            return null;
        }
        (*p).wake_r = r;
        (*p).wake_w = w;
        InitializeCriticalSection(&mut (*p).lock);
        return p;
    }
}

/// Destroy a poller from sc_io_new; null is ignored.
@platform(windows)
pub unsafe fn sc_io_free(ptr: *mut void) {
    let p = ptr as *mut WinPoller;
    if p == null {
        return;
    }
    unsafe {
        closesocket((*p).wake_r);
        closesocket((*p).wake_w);
        DeleteCriticalSection(&mut (*p).lock);
        stdlib::free(p);
    }
}

/// Interrupt a concurrent sc_io_wait; null is ignored. Callable from any thread.
@platform(windows)
pub unsafe fn sc_io_wake(ptr: *mut void) {
    let p = ptr as *const WinPoller;
    if p == null {
        return;
    }
    // A failed send is safe to drop: it fails only on a full buffer, which is unread wake bytes, so a wake
    // is already pending.
    let b: u8 = 1;
    let _ = unsafe send((*p).wake_w, &b, 1, 0);
}

/// Add the ONE-SHOT `want` bits to the interest in `fd`. 0 on success, -1 with the error on failure (a
/// socket closed, or FD_SETSIZE sockets registered). Callable from any thread.
@platform(windows)
pub unsafe fn sc_io_set(ptr: *mut void, fd: i32, want: i32, _known: i32) i32 {
    let p = ptr as *mut WinPoller;
    let s = sock_of(fd);
    // select() has no registration step of its own, so a closed number is refused here, as kqueue and epoll
    // refuse it: the wait settles as not ready at once instead of parking, and a dead socket dropped by
    // sc_io_wait is never registered again. A number that names the wake pair is a closed socket's, taken by
    // a poller created after the close: refused the same way.
    if !sock_alive(s) || s == unsafe (*p).wake_r || s == unsafe (*p).wake_w {
        return -1;
    }
    let mut rc = 0;
    unsafe {
        EnterCriticalSection(&mut (*p).lock);
        if (want & RD) != 0 && reg_add(p, s, RD) != 0 {
            rc = -1;
        }
        if rc == 0 && (want & WR) != 0 && reg_add(p, s, WR) != 0 {
            rc = -1;
        }
        LeaveCriticalSection(&mut (*p).lock);
        // A select() already blocked on the old sets would not see this one: make it rebuild.
        if rc == 0 {
            sc_io_wake(ptr);
        }
    }
    return rc;
}

// select() fails the WHOLE call if any member of a set is not a socket, which happens when a socket is
// closed while someone is parked on it. Rather than let that stop the reactor thread, find the dead
// registrations and drop them, reported as dropped but NOT ready: the reactor registers the direction again
// for the waiters it still holds, that registration fails, and the waits settle as not ready, the same
// answer a close gives on the other two backends.
@platform(windows)
unsafe fn reap_dead(p: *mut WinPoller, out: *mut i32, max: i32) i32 {
    let mut k: usize = 0;
    unsafe {
        EnterCriticalSection(&mut (*p).lock);
        let mut i: usize = 0;
        while i < (*p).n && k < max as usize {
            let g = (*p).regs[i];
            if sock_alive(g.s) {
                i = i + 1;
                continue;
            }
            out[3 * k] = fd_of(g.s);
            out[3 * k + 1] = 0;
            out[3 * k + 2] = g.dir;
            k = k + 1;
            (*p).n = (*p).n - 1;
            (*p).regs[i] = (*p).regs[(*p).n];
        }
        LeaveCriticalSection(&mut (*p).lock);
    }
    return k as i32;
}

/// Block up to `timeout_ms` (-1 = forever) and collect up to `max` events into `out`, three `i32` each:
/// the socket, its ready bits, and the interest bits the backend dropped by reporting it. The count, 0 on
/// timeout. Wake events never appear in `out`.
@platform(windows)
pub unsafe fn sc_io_wait(ptr: *mut void, out: *mut i32, max: i32, timeout_ms: i32) i32 {
    let p = ptr as *mut WinPoller;
    unsafe {
        let rd = (&mut (*p).rd) as *mut SockSet;
        let wr = (&mut (*p).wr) as *mut SockSet;
        let ex = (&mut (*p).ex) as *mut SockSet;
        (*rd).count = 0;
        (*wr).count = 0;
        (*ex).count = 0;
        EnterCriticalSection(&mut (*p).lock);
        set_add(rd, (*p).wake_r);
        for i in 0..(*p).n {
            let g = (*p).regs[i];
            if g.dir == WR {
                set_add(wr, g.s);
                set_add(ex, g.s); // a refused connect surfaces HERE and nowhere else
            } else {
                set_add(rd, g.s);
            }
        }
        LeaveCriticalSection(&mut (*p).lock);
        let tv = timeval { tv_sec: timeout_ms / 1000, tv_usec: timeout_ms % 1000 * 1000 };
        let tp: *const timeval = if timeout_ms >= 0 {
            &tv;
        } else {
            null;
        };
        // The first argument is ignored on Windows.
        let r = select_sockets(0, rd as *mut fd_set, wr as *mut fd_set, ex as *mut fd_set, tp);
        if r == SOCKET_ERROR {
            // 0 keeps the reactor looping: either dead registrations were reaped, or this was transient.
            return if WSAGetLastError() == WSAENOTSOCK {
                reap_dead(p, out, max);
            } else {
                0;
            };
        }
        if r == 0 {
            return 0;
        }
        if set_has(rd, (*p).wake_r) {
            let mut buf: [u8; 64] = [0u8; 64];
            while recv((*p).wake_r, &mut buf[0], 64, 0) > 0 {}
        }
        let mut k: usize = 0;
        EnterCriticalSection(&mut (*p).lock);
        // Registrations are matched by socket, not by index: a worker may have registered while select() was
        // blocked. A socket armed in that window can only be missing from the sets, never wrongly present.
        let mut i: usize = 0;
        while i < (*p).n && k < max as usize {
            let g = (*p).regs[i];
            let ready = if g.dir == WR {
                set_has(wr, g.s) || set_has(ex, g.s);
            } else {
                set_has(rd, g.s);
            };
            if !ready {
                i = i + 1;
                continue;
            }
            out[3 * k] = fd_of(g.s);
            // A socket closed while select() was blocked comes back flagged: report it dropped, not ready,
            // so the reactor's next registration fails and its waits settle as not ready (see reap_dead).
            out[3 * k + 1] = if sock_alive(g.s) {
                g.dir;
            } else {
                0;
            };
            out[3 * k + 2] = g.dir;
            k = k + 1;
            // One-shot, like the other two backends: firing consumes it.
            (*p).n = (*p).n - 1;
            (*p).regs[i] = (*p).regs[(*p).n];
        }
        LeaveCriticalSection(&mut (*p).lock);
        return k as i32;
    }
}

/// One socket, no poller object: what a plain thread waits on. >0 ready, 0 timed out, -1 error;
/// `timeout_ms` < 0 waits forever.
@platform(windows)
pub unsafe fn sc_io_wait_fd(fd: i32, write: i32, timeout_ms: i32) i32 {
    startup();
    let s = sock_of(fd);
    let mut one = OneSock { count: 1, sock: s };
    let mut ex = OneSock { count: 1, sock: s }; // a connect that was refused shows up only here
    let tv = timeval { tv_sec: timeout_ms / 1000, tv_usec: timeout_ms % 1000 * 1000 };
    let tp: *const timeval = if timeout_ms >= 0 {
        &tv;
    } else {
        null;
    };
    let op = ((&mut one) as *mut OneSock) as *mut fd_set;
    let ep = ((&mut ex) as *mut OneSock) as *mut fd_set;
    let r = if write != 0 {
        unsafe select_sockets(0, null, op, ep, tp);
    } else {
        unsafe select_sockets(0, op, null, ep, tp);
    };
    return if r == SOCKET_ERROR {
        -1;
    } else {
        r;
    };
}

// ---- sockets ---------------------------------------------------------------------------------------------
//
// One implementation over both socket APIs: Winsock is Berkeley sockets with other spellings (closesocket,
// ioctlsocket, an int length, char* option values) plus two real semantic differences, both marked where
// they occur: SO_REUSEADDR means "steal the port" rather than "reuse a dead one", and a non-blocking
// connect reports WSAEWOULDBLOCK where POSIX says EINPROGRESS.

// A descriptor crosses into Super-C as an i32. On Windows a SOCKET is a handle-sized value, but Microsoft
// guarantees it fits in 32 bits for exactly this reason, and INVALID_SOCKET narrows to -1, so the "< 0 means
// failure" test the callers use keeps working.
@platform(windows)
fn fd_of(s: usize) i32 {
    return s as i32;
}

@platform(windows)
fn sock_of(fd: i32) usize {
    return (fd as isize) as usize;
}

@platform(macos | ios | linux | android)
fn fd_of(s: i32) i32 {
    return s;
}

@platform(macos | ios | linux | android)
fn sock_of(fd: i32) i32 {
    return fd;
}

@platform(windows)
fn close_sock(s: usize) {
    let _ = unsafe closesocket(s);
}

@platform(macos | ios | linux | android)
fn close_sock(s: i32) {
    let _ = unsafe unistd::close(s);
}

// Network byte order is big-endian.
@platform(!wasm)
fn ntohs(x: u16) u16 {
    if ENDIAN == Endian::Little {
        return (x & 0xFF) << 8 | x >> 8;
    }
    return x;
}

@platform(windows)
fn htonl(x: u32) u32 {
    if ENDIAN == Endian::Little {
        return (x & 0xFF) << 24 | (x & 0xFF00) << 8 | x >> 8 & 0xFF00 | x >> 24;
    }
    return x;
}

// Winsock needs a process-wide startup before any socket call; POSIX needs nothing. Idempotent and safe from
// several threads, because a listener can be bound before the reactor ever starts. 0 not started, 1
// starting, 2 started.
@platform(windows)
static mut WS_STATE: i32 = 0;

@platform(windows)
fn startup() {
    let st = (&mut unsafe WS_STATE) as *mut i32;
    if unsafe atomic::cas_i32(st, 0, 1, false, 4, 4) {
        let mut d = unsafe zeroed::<WSADATA>();
        let _ = unsafe WSAStartup(0x0202, &mut d);
        unsafe atomic::store_i32(st, 2, 4);
        return;
    }
    while unsafe atomic::load_i32(st, 4) != 2 {
        unsafe Sleep(0);
    }
}

@platform(macos | ios | linux | android)
fn startup() {}

@platform(windows)
unsafe fn open_socket(family: i32, kind: i32, proto: i32) usize {
    // WSA_FLAG_OVERLAPPED is what socket() sets; NO_HANDLE_INHERIT keeps the handle out of children.
    return unsafe WSASocketW(family, kind, proto, null, 0, WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
}

@platform(linux | android)
unsafe fn open_socket(family: i32, kind: i32, proto: i32) i32 {
    return unsafe socket(family, kind | SOCK_CLOEXEC, proto);
}

@platform(macos | ios)
unsafe fn open_socket(family: i32, kind: i32, proto: i32) i32 {
    let s = unsafe socket(family, kind, proto);
    cloexec(s);
    return s;
}

@platform(windows)
unsafe fn accept_socket(l: usize) usize {
    let s = unsafe accept(l, null, null);
    if s != INVALID_SOCKET {
        let _ = unsafe SetHandleInformation(s as *mut void, HANDLE_FLAG_INHERIT, 0);
    }
    return s;
}

@platform(linux | android)
unsafe fn accept_socket(l: i32) i32 {
    return unsafe accept4(l, null, null, SOCK_CLOEXEC);
}

@platform(macos | ios)
unsafe fn accept_socket(l: i32) i32 {
    let s = unsafe accept(l, null, null);
    cloexec(s);
    return s;
}

// getaddrinfo reports through its result, not errno: a name that does not resolve fails as "host
// unreachable", which the callers classify as Unreachable. EAI_SYSTEM already left its errno. The list, or
// null.
@platform(windows)
unsafe fn resolve(host: *const char, svc: *const char, hints: &addrinfo) *mut addrinfo {
    let mut out: *mut addrinfo = null;
    if unsafe getaddrinfo(host, svc, hints, &mut out) == 0 {
        return out;
    }
    set_err(WSAEHOSTUNREACH);
    return null;
}

@platform(macos | ios | linux | android)
unsafe fn resolve(host: *const char, svc: *const char, hints: &addrinfo) *mut addrinfo {
    let mut out: *mut addrinfo = null;
    let r = unsafe getaddrinfo(host, svc, hints, &mut out);
    if r == 0 {
        return out;
    }
    if r != EAI_SYSTEM {
        set_err(EHOSTUNREACH);
    }
    return null;
}

// `port` as decimal text with its NUL, as snprintf's "%d" writes it: the service name for getaddrinfo,
// built with no allocation between a failing call and the caller reading its error.
@platform(!wasm)
fn port_text(port: i32) [char; 12] {
    let mut digits: [u8; 10] = [0u8; 10];
    let mut n: usize = 0;
    let mut v: u32 = if port < 0 {
        (0 - port as i64) as u32;
    } else {
        port as u32;
    };
    loop {
        unsafe digits[n] = b'0' + (v % 10) as u8;
        n = n + 1;
        v = v / 10;
        if v == 0 {
            break;
        }
    }
    let mut out: [char; 12] = [0 as char; 12];
    let mut at: usize = 0;
    if port < 0 {
        out[0] = b'-' as char;
        at = 1;
    }
    while n > 0 {
        n = n - 1;
        unsafe {
            out[at] = digits[n] as char;
        }
        at = at + 1;
    }
    return out;
}

// Resolve host:port for a local socket of `kind` and hand back the list. `host` null or empty means "any".
@platform(!wasm)
unsafe fn resolve_local(host: *const char, port: i32, kind: i32) *mut addrinfo {
    let any = host == null || (unsafe host[0]) as u8 == 0;
    let svc = port_text(port);
    let hints = addrinfo {
        ai_flags: if any {
            AI_PASSIVE;
        } else {
            0;
        },
        ai_family: AF_UNSPEC, // IPv4 or IPv6, whichever the name resolves to
        ai_socktype: kind,
    };
    let node: *const char = if any {
        null;
    } else {
        host;
    };
    return unsafe resolve(node, &svc[0], &hints);
}

// "Let me have this port if nobody is really using it." The two systems spell that differently, and the
// POSIX spelling on Windows would be wrong: there SO_REUSEADDR means "bind even though someone is LISTENING
// here", so two listeners could share a port and this layer would never report AddressInUse. Windows already
// allows binding a TIME_WAIT port again, and SO_EXCLUSIVEADDRUSE is what a server wants instead: it keeps
// anyone else from taking the port.
@platform(windows)
fn reuse_addr(s: usize) {
    let one: i32 = 1;
    let _ = unsafe setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, &one, 4);
}

@platform(macos | ios | linux | android)
fn reuse_addr(s: i32) {
    let one: i32 = 1;
    let _ = unsafe setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, 4);
}

@platform(!wasm)
fn no_delay(s: Sock) {
    let one: i32 = 1;
    let _ = unsafe setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, 4);
}

// Close `s` after a failure, keep the failure's error, and return -1.
@platform(!wasm)
fn fail_close(s: Sock) i32 {
    let e = last_err();
    close_sock(s);
    set_err(e);
    return -1;
}

// The address length of a resolved address, as the socket calls take it.
@platform(windows)
unsafe fn addr_len(ai: *const addrinfo) socklen_t {
    return (unsafe (*ai).ai_addrlen) as socklen_t;
}

@platform(macos | ios | linux | android)
unsafe fn addr_len(ai: *const addrinfo) socklen_t {
    return unsafe (*ai).ai_addrlen;
}

// A buffer length as recv, send, sendto and recvfrom take it: an int on Windows.
@platform(windows)
fn buf_len(n: usize) BufLen {
    return n as BufLen;
}

@platform(macos | ios | linux | android)
fn buf_len(n: usize) BufLen {
    return n;
}

// A transfer's result as the callers take it: Winsock returns an int.
@platform(windows)
fn ssize(r: i32) isize {
    return r as isize;
}

@platform(macos | ios | linux | android)
fn ssize(r: isize) isize {
    return r;
}

// "Not finished yet" for a non-blocking connect: the same state on both systems, and the caller waits for
// writability either way before it asks sc_tcp_connect_result what happened.
@platform(windows)
const CONNECT_PENDING: i32 = WSAEWOULDBLOCK;
@platform(macos | ios | linux | android)
const CONNECT_PENDING: i32 = EINPROGRESS;

/// A non-blocking listening TCP socket on `host:port` (port 0 = let the OS choose); the descriptor, or -1.
@platform(!wasm)
pub unsafe fn sc_tcp_listen(host: *const char, port: i32, backlog: i32) i32 {
    startup();
    let ai = unsafe resolve_local(host, port, SOCK_STREAM);
    if ai == null {
        return -1;
    }
    unsafe {
        let s = open_socket((*ai).ai_family, (*ai).ai_socktype, (*ai).ai_protocol);
        if fd_of(s) < 0 {
            let e = last_err();
            freeaddrinfo(ai);
            set_err(e);
            return -1;
        }
        reuse_addr(s);
        if bind(s, (*ai).ai_addr, addr_len(ai)) != 0 || listen(s, backlog) != 0 {
            let e = last_err(); // before the cleanup below can reset it: this is AddressInUse
            freeaddrinfo(ai);
            close_sock(s);
            set_err(e);
            return -1;
        }
        freeaddrinfo(ai);
        if sc_io_set_nonblocking(fd_of(s)) != 0 {
            return fail_close(s);
        }
        return fd_of(s);
    }
}

/// The local port a socket is bound to, or -1: how a caller learns the port after binding to 0.
@platform(!wasm)
pub unsafe fn sc_tcp_port(fd: i32) i32 {
    let mut ss = unsafe zeroed::<sockaddr_storage>();
    let sa = ((&mut ss) as *mut sockaddr_storage) as *mut sockaddr;
    let mut len = sizeof(sockaddr_storage) as socklen_t;
    if unsafe getsockname(sock_of(fd), sa, &mut len) != 0 {
        return -1;
    }
    let family = (unsafe (*sa).sa_family) as i32;
    if family == AF_INET {
        return ntohs(unsafe (*(sa as *const sockaddr_in)).sin_port);
    }
    if family == AF_INET6 {
        return ntohs(unsafe (*(sa as *const sockaddr_in6)).sin6_port);
    }
    return -1;
}

/// Accept one connection on a listening socket; the new non-blocking descriptor, or -1 (with
/// sc_io_would_block() meaning "not yet").
@platform(!wasm)
pub unsafe fn sc_tcp_accept(lfd: i32) i32 {
    let s = unsafe accept_socket(sock_of(lfd));
    if fd_of(s) < 0 {
        return -1; // nothing ran since the failure, so the error is still the caller's
    }
    if unsafe sc_io_set_nonblocking(fd_of(s)) != 0 {
        return fail_close(s);
    }
    no_delay(s);
    return fd_of(s);
}

/// Start a non-blocking connect to `host:port`; the descriptor, or -1 on immediate failure. The socket is
/// writable once the connect resolves; sc_tcp_connect_result then reports it.
@platform(!wasm)
pub unsafe fn sc_tcp_connect(host: *const char, port: i32) i32 {
    startup();
    let ai = unsafe resolve_local(host, port, SOCK_STREAM);
    if ai == null {
        return -1;
    }
    unsafe {
        let s = open_socket((*ai).ai_family, (*ai).ai_socktype, (*ai).ai_protocol);
        if fd_of(s) < 0 {
            let e = last_err();
            freeaddrinfo(ai);
            set_err(e);
            return -1;
        }
        if sc_io_set_nonblocking(fd_of(s)) != 0 {
            let e = last_err();
            freeaddrinfo(ai);
            close_sock(s);
            set_err(e);
            return -1;
        }
        let r = connect(s, (*ai).ai_addr, addr_len(ai));
        let cerr = last_err(); // freeaddrinfo below would reset it
        freeaddrinfo(ai);
        set_err(cerr);
        if r == 0 || cerr == CONNECT_PENDING {
            no_delay(s);
            return fd_of(s);
        }
        close_sock(s);
        set_err(cerr);
        return -1;
    }
}

/// 0 once a pending connect succeeded, else the failure's error code; -1 when the socket cannot be asked.
@platform(!wasm)
pub unsafe fn sc_tcp_connect_result(fd: i32) i32 {
    let mut err: i32 = 0;
    let mut len = sizeof(i32) as socklen_t;
    if unsafe getsockopt(sock_of(fd), SOL_SOCKET, SO_ERROR, &mut err, &mut len) != 0 {
        return -1;
    }
    return err;
}

/// A non-blocking UDP socket bound to `host:port` (port 0 = let the OS choose; ask sc_tcp_port); the
/// descriptor, or -1.
@platform(!wasm)
pub unsafe fn sc_udp_bind(host: *const char, port: i32) i32 {
    startup();
    let ai = unsafe resolve_local(host, port, SOCK_DGRAM);
    if ai == null {
        return -1;
    }
    unsafe {
        let s = open_socket((*ai).ai_family, (*ai).ai_socktype, (*ai).ai_protocol);
        if fd_of(s) < 0 {
            let e = last_err();
            freeaddrinfo(ai);
            set_err(e);
            return -1;
        }
        reuse_addr(s);
        if bind(s, (*ai).ai_addr, addr_len(ai)) != 0 {
            let e = last_err();
            freeaddrinfo(ai);
            close_sock(s);
            set_err(e);
            return -1;
        }
        freeaddrinfo(ai);
        if sc_io_set_nonblocking(fd_of(s)) != 0 {
            return fail_close(s);
        }
        return fd_of(s);
    }
}

/// Send one datagram to `host:port`, non-blocking; bytes sent, or -1. The address is resolved per call,
/// which keeps the callers free of any sockaddr; a sender in a tight loop should hold a connected socket
/// instead.
@platform(!wasm)
pub unsafe fn sc_udp_send_to(fd: i32, buf: *const void, n: usize, host: *const char, port: i32) isize {
    let svc = port_text(port);
    let hints = addrinfo { ai_family: AF_UNSPEC, ai_socktype: SOCK_DGRAM };
    let ai = unsafe resolve(host, &svc[0], &hints);
    if ai == null {
        return -1;
    }
    unsafe {
        let r = ssize(sendto(sock_of(fd), buf, buf_len(n), 0, (*ai).ai_addr, addr_len(ai)));
        let e = last_err(); // freeaddrinfo below would reset it
        freeaddrinfo(ai);
        set_err(e);
        return r;
    }
}

/// Receive one datagram, non-blocking; bytes received, or -1 (with sc_io_would_block() meaning "nothing
/// waiting"). The sender's address is discarded.
@platform(!wasm)
pub unsafe fn sc_udp_recv(fd: i32, buf: *mut void, n: usize) isize {
    return ssize(unsafe recvfrom(sock_of(fd), buf, buf_len(n), 0, null, null));
}
