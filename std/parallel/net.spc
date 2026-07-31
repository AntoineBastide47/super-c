// Task-aware TCP. Import with `import std::parallel::net;`.
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
// Sockets are non-blocking underneath and the `sockaddr` handling lives in C (`ffi/sc_io.c`), so nothing
// here encodes a platform layout. Addresses resolve to IPv4 or IPv6, whichever the name gives.
//
// Anything that can fail returns `Result<T, IoError>`, so `?` propagates it and the caller can say WHICH
// failure it was rather than just that there was one.
//
// Every platform, like the reactor -- on Windows over its select() backend.

import sc_io;
import std::parallel::io as io;

/// Why an operation failed. `code` is the platform errno, kept so a caller can report or match on the exact
/// failure; the kind is what most code actually branches on.
pub struct IoError {
    pub kind: IoErrorKind,
    pub code: i32,
}

/// The failure kinds worth telling apart without reading an errno.
pub enum IoErrorKind {
    Refused, // nothing is listening
    Unreachable, // no route, or the name does not resolve
    Reset, // the peer dropped the connection
    AddressInUse, // something already holds that port
    Closed, // the peer closed cleanly, mid-operation
    Other,
}

extend IoError {
    /// Classify the current errno. `pub` for linkage.
    pub fn last() IoError {
        let e = unsafe sc_io::sc_io_errno();
        // The numbers differ between platforms, so they are read from the C side rather than written here;
        // these are the ones POSIX pins down well enough to branch on.
        let k = if e == 61 || e == 111 || e == 10061 {
            IoErrorKind::Refused; // ECONNREFUSED: macOS 61, Linux 111, WSAECONNREFUSED 10061
        } else if e == 54 || e == 104 || e == 10054 {
            IoErrorKind::Reset; // ECONNRESET
        } else if e == 48 || e == 98 || e == 10048 {
            IoErrorKind::AddressInUse; // EADDRINUSE
        } else if e == 51 || e == 65 || e == 101 || e == 113 || e == 10051 || e == 10065 {
            IoErrorKind::Unreachable; // ENETUNREACH / EHOSTUNREACH
        } else if e == 32 || e == 141 || e == 10053 || e == 10058 {
            IoErrorKind::Closed; // EPIPE, and its two Winsock spellings (CONNABORTED / SHUTDOWN)
        } else {
            IoErrorKind::Other;
        };
        return IoError { kind: k, code: e };
    }
    /// The kind, for a caller that does not care about the number.
    pub const fn kind(self: &IoError) IoErrorKind {
        return self.kind;
    }
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

// Both are just a descriptor, so they move between tasks freely.
unsafe extend TcpListener as Send {}

unsafe extend TcpStream as Send {}

extend TcpListener {
    /// Bind and listen on `host:port`; `port` 0 lets the OS choose one (ask `port()` which it picked).
    /// `None` if the address cannot be bound.
    pub fn bind(host: str, port: i32) Result<TcpListener, IoError> {
        let mut h = String::from_str(host);
        let fd = unsafe sc_io::sc_tcp_listen(h.cstr(), port, 128);
        if fd < 0 {
            return Result::<TcpListener, IoError>::Err(IoError::last());
        }
        return Result::<TcpListener, IoError>::Ok(TcpListener { fd: fd });
    }
    /// The port actually bound -- the one to connect to after binding port 0.
    pub fn port(self: &TcpListener) i32 {
        return unsafe sc_io::sc_tcp_port(self.fd);
    }
    /// Accept one connection, parking until there is one. `None` only on a real error.
    pub fn accept(self: &TcpListener) Result<TcpStream, IoError> {
        loop {
            let fd = unsafe sc_io::sc_tcp_accept(self.fd);
            if fd >= 0 {
                return Result::<TcpStream, IoError>::Ok(TcpStream { fd: fd });
            }
            if unsafe sc_io::sc_io_would_block() == 0 {
                return Result::<TcpStream, IoError>::Err(IoError::last());
            }
            io::wait_readable(self.fd);
        }
    }
    /// Accept one connection, giving up after `deadline` (a `time::deadline_in` value). `None` on timeout
    /// or error.
    pub fn accept_until(self: &TcpListener, deadline: u64) Result<TcpStream, IoError> {
        loop {
            let fd = unsafe sc_io::sc_tcp_accept(self.fd);
            if fd >= 0 {
                return Result::<TcpStream, IoError>::Ok(TcpStream { fd: fd });
            }
            if unsafe sc_io::sc_io_would_block() == 0 {
                return Result::<TcpStream, IoError>::Err(IoError::last());
            }
            if !io::wait_until(self.fd, false, deadline) {
                // The deadline, not the socket: a timeout is not an errno, so it is reported as one of ours.
                return Result::<TcpStream, IoError>::Err(IoError { kind: IoErrorKind::Other, code: 0 });
            }
        }
    }
}

extend TcpListener as Free {
    pub fn free(self: &mut TcpListener) {
        if self.fd >= 0 {
            let _ = unsafe sc_io::sc_io_close(self.fd);
            self.fd = -1;
        }
    }
}

extend TcpStream {
    /// Connect to `host:port`, parking until the connection resolves. `None` if it fails.
    pub fn connect(host: str, port: i32) Result<TcpStream, IoError> {
        let mut h = String::from_str(host);
        let fd = unsafe sc_io::sc_tcp_connect(h.cstr(), port);
        if fd < 0 {
            return Result::<TcpStream, IoError>::Err(IoError::last());
        }
        // A non-blocking connect finishes asynchronously: the socket becomes writable, and only then does
        // it say whether it actually connected -- and the failure is in SO_ERROR, not errno.
        io::wait_writable(fd);
        let err = unsafe sc_io::sc_tcp_connect_result(fd);
        if err != 0 {
            let _ = unsafe sc_io::sc_io_close(fd);
            let kind = if err == 61 || err == 111 || err == 10061 {
                IoErrorKind::Refused;
            } else if err == 51 || err == 65 || err == 101 || err == 113 || err == 10051 || err == 10065 {
                IoErrorKind::Unreachable;
            } else {
                IoErrorKind::Other;
            };
            return Result::<TcpStream, IoError>::Err(IoError { kind: kind, code: err });
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
            let _ = unsafe sc_io::sc_io_close(self.fd);
            self.fd = -1;
        }
    }
}

extend TcpStream as Free {
    pub fn free(self: &mut TcpStream) {
        self.close();
    }
}

/// A UDP socket. Datagrams, so there is no connection to accept or close -- just a bound port that sends
/// and receives. Dropping it closes the descriptor.
@no_const
pub struct UdpSocket {
    pub fd: i32,
}

unsafe extend UdpSocket as Send {}

extend UdpSocket {
    /// Bind to `host:port`; port 0 lets the OS choose (ask `port()` which).
    pub fn bind(host: str, port: i32) Result<UdpSocket, IoError> {
        let mut h = String::from_str(host);
        let fd = unsafe sc_io::sc_udp_bind(h.cstr(), port);
        if fd < 0 {
            return Result::<UdpSocket, IoError>::Err(IoError::last());
        }
        return Result::<UdpSocket, IoError>::Ok(UdpSocket { fd: fd });
    }
    /// The port actually bound.
    pub fn port(self: &UdpSocket) i32 {
        return unsafe sc_io::sc_tcp_port(self.fd);
    }
    /// Send one datagram, parking if the send buffer is full. The destination is resolved per call.
    pub fn send_to(self: &UdpSocket, buf: []u8, host: str, port: i32) Result<usize, IoError> {
        let mut h = String::from_str(host);
        loop {
            let n = unsafe sc_io::sc_udp_send_to(self.fd, buf.ptr, buf.len(), h.cstr(), port);
            if n >= 0 {
                return Result::<usize, IoError>::Ok(n as usize);
            }
            if unsafe sc_io::sc_io_would_block() == 0 {
                let e = IoError::last();
                return Result::<usize, IoError>::Err(e);
            }
            io::wait_writable(self.fd);
        }
    }
    /// Receive one datagram into `buf`, parking until one arrives. Returns how many bytes it held; anything
    /// past `buf` is dropped, as datagrams are.
    pub fn recv(self: &UdpSocket, buf: []mut u8) Result<usize, IoError> {
        loop {
            let n = unsafe sc_io::sc_udp_recv(self.fd, buf.ptr, buf.len());
            if n >= 0 {
                return Result::<usize, IoError>::Ok(n as usize);
            }
            if unsafe sc_io::sc_io_would_block() == 0 {
                return Result::<usize, IoError>::Err(IoError::last());
            }
            io::wait_readable(self.fd);
        }
    }
}

extend UdpSocket as Free {
    pub fn free(self: &mut UdpSocket) {
        if self.fd >= 0 {
            let _ = unsafe sc_io::sc_io_close(self.fd);
            self.fd = -1;
        }
    }
}
