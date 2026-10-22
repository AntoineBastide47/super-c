// Task-aware TCP and UDP. Import with `import std::net;`.
//
//     let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
//     let port = l.port();
//     launch fn() {
//         switch l.accept() {
//             Ok(s) => { let n = s.read(buf); },     // parks; the worker serves other tasks
//             Err(e) => { report(e.kind()); },
//         };
//     };
//
// Every operation that would block parks the calling coroutine on the reactor instead: `accept` waits for
// the listener to be readable, `read`/`write` for the connection. From a plain thread the same calls block
// that thread, so the API reads the same either way.
//
// Sockets are non-blocking underneath and reach the operating system through `std::platform::socket`, so
// nothing here encodes a platform layout. Addresses resolve to IPv4 or IPv6, whichever the name gives.
//
// Anything that can fail returns `Result<T, IoError>`, so `?` propagates it and the caller can say WHICH
// failure it was rather than only that there was one.
//
// Every platform, like the reactor: on Windows over its select() backend.

import std::platform::socket;
import std::parallel::io as io;

// A wait that ended without readiness: its deadline passed, it was cancelled, the reactor is stopping, or the
// descriptor cannot be watched. None of these is an error number, so the code is 0.
const fn wait_failed(op: IoOp) IoError {
    return IoError::new(IoErrorKind::Other, op);
}

/// A listening socket. Dropping it closes the descriptor.
@no_const
pub struct TcpListener {
    pub fd: i32,
}

/// One connection. Dropping it closes the descriptor.
@no_const
pub struct TcpStream {
    pub fd: i32,
}

// Both are a bare descriptor, so they move between tasks freely.
unsafe extend TcpListener as Send {}

unsafe extend TcpStream as Send {}

extend TcpListener {
    /// Bind and listen on `host:port`; `port` 0 lets the OS choose one (ask `port()` which it picked).
    /// An error if the address cannot be bound.
    pub fn bind(host: str, port: i32) Result<TcpListener, IoError> {
        let fd = socket::tcp_listen(host, port, 128)?;
        return Result::<TcpListener, IoError>::Ok(TcpListener { fd: fd });
    }
    /// The port bound: the one to connect to after binding port 0.
    pub fn port(self: &TcpListener) i32 {
        return socket::local_port(self.fd).unwrap_or(-1);
    }
    /// Accept one connection, parking until there is one. An error when the accept fails or the wait ends
    /// without a connection (the task was cancelled, or the reactor is stopping).
    pub fn accept(self: &TcpListener) Result<TcpStream, IoError> {
        loop {
            let r = socket::tcp_accept(self.fd);
            if r.is_ok() {
                return Result::<TcpStream, IoError>::Ok(TcpStream { fd: r.unwrap() });
            }
            let e = r.unwrap_err();
            if e.kind != IoErrorKind::WouldBlock {
                return Result::<TcpStream, IoError>::Err(e);
            }
            if !io::wait_readable(self.fd) {
                return Result::<TcpStream, IoError>::Err(wait_failed(IoOp::Accept));
            }
        }
    }
    /// Accept one connection, giving up after `deadline` (a `time::deadline_in` value). An error on
    /// timeout or failure; a timeout carries code 0.
    pub fn accept_until(self: &TcpListener, deadline: u64) Result<TcpStream, IoError> {
        loop {
            let r = socket::tcp_accept(self.fd);
            if r.is_ok() {
                return Result::<TcpStream, IoError>::Ok(TcpStream { fd: r.unwrap() });
            }
            let e = r.unwrap_err();
            if e.kind != IoErrorKind::WouldBlock {
                return Result::<TcpStream, IoError>::Err(e);
            }
            if !io::wait_until(self.fd, false, deadline) {
                return Result::<TcpStream, IoError>::Err(wait_failed(IoOp::Accept));
            }
        }
    }
}

extend TcpListener as Free {
    pub fn free(self: &mut TcpListener) {
        if self.fd >= 0 {
            let _ = io::close(self.fd);
            self.fd = -1;
        }
    }
}

extend TcpStream {
    /// Connect to `host:port`, parking until the connection resolves. An error if it fails.
    pub fn connect(host: str, port: i32) Result<TcpStream, IoError> {
        let fd = socket::tcp_connect(host, port)?;
        // A non-blocking connect finishes asynchronously: the socket becomes writable, and only then does
        // it say whether it connected, and the failure is in SO_ERROR, not errno. A wait that ends without
        // writability leaves the connect unresolved, so it is a failure, never a connection.
        if !io::wait_writable(fd) {
            let _ = io::close(fd);
            return Result::<TcpStream, IoError>::Err(wait_failed(IoOp::Connect));
        }
        if let Err(e) = socket::connect_result(fd) {
            let _ = io::close(fd);
            return Result::<TcpStream, IoError>::Err(e);
        }
        return Result::<TcpStream, IoError>::Ok(TcpStream { fd: fd });
    }
    /// Read into `buf`, parking until there is something to read. `0` means the peer closed; negative is a
    /// real error.
    pub fn read(self: &TcpStream, buf: []mut u8) isize {
        return io::read(self.fd, buf);
    }
    /// Write all of `buf`, parking whenever the socket is full. Returns the bytes written, negative on a
    /// real error.
    pub fn write(self: &TcpStream, buf: []u8) isize {
        return io::write(self.fd, buf);
    }
    /// Close the connection early. Dropping the stream does the same.
    pub fn close(self: &mut TcpStream) {
        if self.fd >= 0 {
            let _ = io::close(self.fd);
            self.fd = -1;
        }
    }
}

extend TcpStream as Free {
    pub fn free(self: &mut TcpStream) {
        self.close();
    }
}

/// A UDP socket. Datagrams, so there is no connection to accept or close, only a bound port that sends
/// and receives. Dropping it closes the descriptor.
@no_const
pub struct UdpSocket {
    pub fd: i32,
}

unsafe extend UdpSocket as Send {}

extend UdpSocket {
    /// Bind to `host:port`; port 0 lets the OS choose (ask `port()` which).
    pub fn bind(host: str, port: i32) Result<UdpSocket, IoError> {
        let fd = socket::udp_bind(host, port)?;
        return Result::<UdpSocket, IoError>::Ok(UdpSocket { fd: fd });
    }
    /// The port bound.
    pub fn port(self: &UdpSocket) i32 {
        return socket::local_port(self.fd).unwrap_or(-1);
    }
    /// Send one datagram, parking if the send buffer is full. The destination is resolved per call.
    pub fn send_to(self: &UdpSocket, buf: []u8, host: str, port: i32) Result<usize, IoError> {
        loop {
            let r = socket::udp_send_to(self.fd, buf, host, port);
            if r.is_ok() {
                return r;
            }
            let e = r.unwrap_err();
            if e.kind != IoErrorKind::WouldBlock {
                return Result::<usize, IoError>::Err(e);
            }
            if !io::wait_writable(self.fd) {
                return Result::<usize, IoError>::Err(wait_failed(IoOp::Send));
            }
        }
    }
    /// Receive one datagram into `buf`, parking until one arrives. Returns how many bytes it held; anything
    /// past `buf` is dropped, as datagrams are.
    pub fn recv(self: &UdpSocket, buf: []mut u8) Result<usize, IoError> {
        loop {
            let r = socket::udp_recv(self.fd, buf);
            if r.is_ok() {
                return r;
            }
            let e = r.unwrap_err();
            if e.kind != IoErrorKind::WouldBlock {
                return Result::<usize, IoError>::Err(e);
            }
            if !io::wait_readable(self.fd) {
                return Result::<usize, IoError>::Err(wait_failed(IoOp::Recv));
            }
        }
    }
}

extend UdpSocket as Free {
    pub fn free(self: &mut UdpSocket) {
        if self.fd >= 0 {
            let _ = io::close(self.fd);
            self.fd = -1;
        }
    }
}
