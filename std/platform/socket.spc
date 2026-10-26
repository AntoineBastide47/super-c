// Sockets of std::platform over the substrate's socket and poller calls (`ffi/sc_io.spc`): TCP listen,
// accept and connect, UDP bind, send and receive, descriptor reads and writes, readiness waits, and the
// poller (kqueue, epoll, or select on Windows). Names resolve inside listen, connect and send_to
// (`getaddrinfo`, IPv4 or IPv6). Sockets are non-blocking: a call that would wait returns WouldBlock, and
// the caller waits for readiness (`wait_fd`, a `Poller`, or the task reactor `std::parallel::io`). An
// interrupted call runs again. WASI preview 1 has no sockets and no poller: those calls are Unsupported
// there; `wait_fd`, `read`, `write` and `close` work on its descriptors. Unstable, internal to std and the
// compiler.
import sc_io;
import std::platform::error;

/// Interest and readiness bits of `Poller::set` and its events.
pub const READABLE: i32 = sc_io::RD;
pub const WRITABLE: i32 = sc_io::WR;
/// Most events one `Poller::wait` returns.
pub const EVENTS_MAX: i32 = sc_io::EV_MAX;

/// A readiness poller. Only one thread waits on it; `set` and `wake` may come from any thread. Closed
/// when dropped.
@no_const
pub struct Poller {
    p: *mut void,
}

/// A non-blocking TCP socket listening on `host:port` (port 0: the system chooses; `local_port` says
/// which), with `backlog` pending connections at most.
pub fn tcp_listen(host: str, port: i32, backlog: i32) Result<i32, IoError> {
    let mut h = c_host(host, IoOp::Bind)?;
    return fd_result(unsafe sc_io::sc_tcp_listen(h.cstr(), port, backlog), IoOp::Bind);
}

/// The local port socket `fd` is bound to.
pub fn local_port(fd: i32) Result<i32, IoError> {
    let p = unsafe sc_io::sc_tcp_port(fd);
    if p < 0 {
        return Result::<i32, IoError>::Err(last(IoOp::Bind));
    }
    return Result::<i32, IoError>::Ok(p);
}

/// One pending connection of listening socket `fd`, non-blocking: WouldBlock when none waits.
pub fn tcp_accept(fd: i32) Result<i32, IoError> {
    // Bounded by the signals that interrupt the call.
    loop {
        let c = unsafe sc_io::sc_tcp_accept(fd);
        if c >= 0 {
            return Result::<i32, IoError>::Ok(c);
        }
        let e = last(IoOp::Accept);
        if e.kind != IoErrorKind::Interrupted {
            return Result::<i32, IoError>::Err(e);
        }
    }
}

/// A non-blocking TCP socket connecting to `host:port`. The connection resolves later: wait until the
/// socket is writable, then ask `connect_result`.
pub fn tcp_connect(host: str, port: i32) Result<i32, IoError> {
    let mut h = c_host(host, IoOp::Connect)?;
    return fd_result(unsafe sc_io::sc_tcp_connect(h.cstr(), port), IoOp::Connect);
}

/// A blocking Unix-domain stream socket listening at file `path`, `backlog` pending connections at most.
/// The socket file takes the process's file-creation mask: create it in an owner-only directory.
@platform(macos | ios | linux | android)
pub fn unix_listen(path: str, backlog: i32) Result<i32, IoError> {
    return fd_result(unsafe sc_io::sc_unix_listen(path.ptr(), path.len(), backlog), IoOp::Bind);
}

/// One connection of blocking Unix-domain socket `fd`, waiting for it; the connection is blocking.
@platform(macos | ios | linux | android)
pub fn unix_accept(fd: i32) Result<i32, IoError> {
    // Bounded by the signals that interrupt the call.
    loop {
        let c = unsafe sc_io::sc_unix_accept(fd);
        if c >= 0 {
            return Result::<i32, IoError>::Ok(c);
        }
        let e = last(IoOp::Accept);
        if e.kind != IoErrorKind::Interrupted {
            return Result::<i32, IoError>::Err(e);
        }
    }
}

/// A blocking Unix-domain stream socket connected to file `path`.
@platform(macos | ios | linux | android)
pub fn unix_connect(path: str) Result<i32, IoError> {
    return fd_result(unsafe sc_io::sc_unix_connect(path.ptr(), path.len()), IoOp::Connect);
}

/// The user ID of the process at the other end of connected Unix-domain socket `fd`.
@platform(macos | ios | linux | android)
pub fn peer_uid(fd: i32) Result<u32, IoError> {
    let mut u: u32 = 0;
    if unsafe sc_io::sc_peer_uid(fd, &mut u) != 0 {
        return Result::<u32, IoError>::Err(last(IoOp::Other));
    }
    return Result::<u32, IoError>::Ok(u);
}

/// The real user ID of this process.
@platform(macos | ios | linux | android)
pub fn uid() u32 {
    return sc_io::sc_uid();
}

/// How the connect of socket `fd` ended, once it is writable: Ok when it connected.
pub fn connect_result(fd: i32) Result<Unit, IoError> {
    let r = unsafe sc_io::sc_tcp_connect_result(fd);
    if r == 0 {
        return Result::<Unit, IoError>::Ok(Unit {});
    }
    if r < 0 {
        return Result::<Unit, IoError>::Err(last(IoOp::Connect));
    }
    return Result::<Unit, IoError>::Err(error::code_error(r, IoOp::Connect));
}

/// A non-blocking UDP socket bound to `host:port` (port 0: the system chooses).
pub fn udp_bind(host: str, port: i32) Result<i32, IoError> {
    let mut h = c_host(host, IoOp::Bind)?;
    return fd_result(unsafe sc_io::sc_udp_bind(h.cstr(), port), IoOp::Bind);
}

/// Send `buf` as one datagram from socket `fd` to `host:port`, resolved on each call: the count sent.
/// WouldBlock when the send buffer is full.
pub fn udp_send_to(fd: i32, buf: []u8, host: str, port: i32) Result<usize, IoError> {
    let mut h = c_host(host, IoOp::Send)?;
    let hp = h.cstr();
    // Bounded by the signals that interrupt the call.
    loop {
        let n = unsafe sc_io::sc_udp_send_to(fd, buf.ptr, buf.len(), hp, port);
        if n >= 0 {
            return Result::<usize, IoError>::Ok(n as usize);
        }
        let e = last(IoOp::Send);
        if e.kind != IoErrorKind::Interrupted {
            return Result::<usize, IoError>::Err(e);
        }
    }
}

/// Receive one datagram of socket `fd` into `buf`: its size; the part past `buf` is dropped. WouldBlock
/// when none waits.
pub fn udp_recv(fd: i32, buf: []mut u8) Result<usize, IoError> {
    // Bounded by the signals that interrupt the call.
    loop {
        let n = unsafe sc_io::sc_udp_recv(fd, buf.as_mut_ptr(), buf.len());
        if n >= 0 {
            return Result::<usize, IoError>::Ok(n as usize);
        }
        let e = last(IoOp::Recv);
        if e.kind != IoErrorKind::Interrupted {
            return Result::<usize, IoError>::Err(e);
        }
    }
}

/// One read of socket `fd` (any descriptor on POSIX and WASI): the count, 0 when the peer closed.
/// WouldBlock when nothing waits.
pub fn read(fd: i32, buf: []mut u8) Result<usize, IoError> {
    // Bounded by the signals that interrupt the call.
    loop {
        let n = unsafe sc_io::sc_io_read(fd, buf.as_mut_ptr(), buf.len());
        if n >= 0 {
            return Result::<usize, IoError>::Ok(n as usize);
        }
        let e = last(IoOp::Recv);
        if e.kind != IoErrorKind::Interrupted {
            return Result::<usize, IoError>::Err(e);
        }
    }
}

/// One write to socket `fd` (any descriptor on POSIX and WASI): the count accepted, which may be fewer
/// than `buf.len()`. WouldBlock when the send buffer is full.
pub fn write(fd: i32, buf: []u8) Result<usize, IoError> {
    // Bounded by the signals that interrupt the call.
    loop {
        let n = unsafe sc_io::sc_io_write(fd, buf.ptr, buf.len());
        if n >= 0 {
            return Result::<usize, IoError>::Ok(n as usize);
        }
        let e = last(IoOp::Send);
        if e.kind != IoErrorKind::Interrupted {
            return Result::<usize, IoError>::Err(e);
        }
    }
}

/// Close socket `fd`. The number is free again even when an error is reported.
pub fn close(fd: i32) Result<Unit, IoError> {
    if unsafe sc_io::sc_io_close(fd) != 0 {
        return Result::<Unit, IoError>::Err(last(IoOp::Close));
    }
    return Result::<Unit, IoError>::Ok(Unit {});
}

/// Make descriptor `fd` non-blocking.
pub fn set_nonblocking(fd: i32) Result<Unit, IoError> {
    if unsafe sc_io::sc_io_set_nonblocking(fd) != 0 {
        return Result::<Unit, IoError>::Err(last(IoOp::Other));
    }
    return Result::<Unit, IoError>::Ok(Unit {});
}

/// Block until `fd` is readable (writable when `write`), or `timeout_ms` passes (< 0: no limit): true
/// when it is ready, false on timeout. Windows waits on sockets only.
pub fn wait_fd(fd: i32, write: bool, timeout_ms: i32) Result<bool, IoError> {
    let r = unsafe sc_io::sc_io_wait_fd(fd, write as i32, timeout_ms);
    if r < 0 {
        return Result::<bool, IoError>::Err(last(IoOp::Poll));
    }
    return Result::<bool, IoError>::Ok(r > 0);
}

// `host` as the C string the resolver takes (bytes on every target): InvalidInput when it holds a NUL.
fn c_host(host: str, op: IoOp) Result<String, IoError> {
    if host.find_byte(0) >= 0 {
        return Result::<String, IoError>::Err(IoError::new(IoErrorKind::InvalidInput, op));
    }
    return Result::<String, IoError>::Ok(String::from_str(host));
}

fn fd_result(fd: i32, op: IoOp) Result<i32, IoError> {
    if fd < 0 {
        return Result::<i32, IoError>::Err(last(op));
    }
    return Result::<i32, IoError>::Ok(fd);
}

// The error of the last failed socket call: errno, or the Winsock code.
fn last(op: IoOp) IoError {
    return error::code_error(sc_io::sc_io_errno(), op);
}

extend Poller {
    /// A new poller with its own wake channel.
    pub fn new() Result<Poller, IoError> {
        let p = unsafe sc_io::sc_io_new();
        if p == null {
            return Result::<Poller, IoError>::Err(last(IoOp::Poll));
        }
        return Result::<Poller, IoError>::Ok(Poller { p: p });
    }
    /// Add the one-shot interest `want` (READABLE, WRITABLE) in `fd`: a bit that fires is reported once and
    /// dropped. `known` tells the backend it still holds a registration for `fd`. True when `fd` cannot be
    /// polled and counts as always ready.
    pub fn set(self: &Poller, fd: i32, want: i32, known: bool) Result<bool, IoError> {
        let r = unsafe sc_io::sc_io_set(self.p, fd, want, known as i32);
        if r < 0 {
            return Result::<bool, IoError>::Err(last(IoOp::Poll));
        }
        return Result::<bool, IoError>::Ok(r == 1);
    }
    /// Make a concurrent `wait` return.
    pub fn wake(self: &Poller) {
        unsafe sc_io::sc_io_wake(self.p);
    }
    /// Block up to `timeout_ms` (< 0: no limit) and write up to `out.len() / 3` events (at most
    /// EVENTS_MAX) into `out`, three values each: the descriptor, its ready bits, and the interest bits
    /// the backend dropped. The count; 0 on timeout or a wake.
    pub fn wait(self: &mut Poller, out: []mut i32, timeout_ms: i32) Result<usize, IoError> {
        let max = (out.len() / 3).min(EVENTS_MAX as usize) as i32;
        // Bounded by the signals that interrupt the call.
        loop {
            let n = unsafe sc_io::sc_io_wait(self.p, out.as_mut_ptr(), max, timeout_ms);
            if n >= 0 {
                return Result::<usize, IoError>::Ok(n as usize);
            }
            let e = last(IoOp::Poll);
            if e.kind != IoErrorKind::Interrupted {
                return Result::<usize, IoError>::Err(e);
            }
        }
    }
}

extend Poller as Free {
    pub fn free(self: &mut Poller) {
        unsafe sc_io::sc_io_free(self.p);
    }
}
