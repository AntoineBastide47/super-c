// Task-aware TCP. Import with `import std::parallel::net;`.
//
//     let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
//     let port = l.port();
//     launch fn() {
//         switch l.accept() {
//             Some(s) => { let n = s.read(buf); },   // parks; the worker serves other tasks
//             None => {},
//         };
//     };
//
// Every operation that would block parks the calling coroutine on the reactor instead: `accept` waits for
// the listener to be readable, `read`/`write` for the connection. From a plain thread the same calls block
// that thread, so the API reads the same either way.
//
// Sockets are non-blocking underneath and the `sockaddr` handling lives in C (`ffi/sc_io.c`), so nothing
// here encodes a platform layout. IPv4 and TCP only for now, and failures are reported as `None` rather
// than a typed error -- both are the shallow end of this API, not limits of the reactor beneath it.
//
// POSIX only, like the reactor.

import sc_io;
import std::parallel::io as io;

/// A listening socket. Dropping it closes the descriptor.
@platform(macos | linux)
pub struct TcpListener {
    pub fd: i32,
}

/// One connection. Dropping it closes the descriptor.
@platform(macos | linux)
pub struct TcpStream {
    pub fd: i32,
}

// Both are just a descriptor, so they move between tasks freely.
@platform(macos | linux)
extend TcpListener as Send {}

@platform(macos | linux)
extend TcpStream as Send {}

@platform(macos | linux)
extend TcpListener {
    /// Bind and listen on `host:port`; `port` 0 lets the OS choose one (ask `port()` which it picked).
    /// `None` if the address cannot be bound.
    pub fn bind(host: str, port: i32) Option<TcpListener> {
        let mut h = String::from_str(host);
        let fd = unsafe sc_io::sc_tcp_listen(h.cstr(), port, 128);
        h.free();
        if fd < 0 {
            return Option::<TcpListener>::None;
        }
        return Option::<TcpListener>::Some(TcpListener { fd: fd });
    }
    /// The port actually bound -- the one to connect to after binding port 0.
    pub fn port(self: &TcpListener) i32 {
        return unsafe sc_io::sc_tcp_port(self.fd);
    }
    /// Accept one connection, parking until there is one. `None` only on a real error.
    pub fn accept(self: &TcpListener) Option<TcpStream> {
        loop {
            let fd = unsafe sc_io::sc_tcp_accept(self.fd);
            if fd >= 0 {
                return Option::<TcpStream>::Some(TcpStream { fd: fd });
            }
            if unsafe sc_io::sc_io_would_block() == 0 {
                return Option::<TcpStream>::None;
            }
            io::wait_readable(self.fd);
        }
    }
    /// Accept one connection, giving up after `deadline` (a `time::deadline_in` value). `None` on timeout
    /// or error.
    pub fn accept_until(self: &TcpListener, deadline: u64) Option<TcpStream> {
        loop {
            let fd = unsafe sc_io::sc_tcp_accept(self.fd);
            if fd >= 0 {
                return Option::<TcpStream>::Some(TcpStream { fd: fd });
            }
            if unsafe sc_io::sc_io_would_block() == 0 {
                return Option::<TcpStream>::None;
            }
            if !io::wait_until(self.fd, false, deadline) {
                return Option::<TcpStream>::None;
            }
        }
    }
}

@platform(macos | linux)
extend TcpListener as Free {
    pub fn free(self: &mut TcpListener) {
        if self.fd >= 0 {
            let _ = unsafe sc_io::sc_io_close(self.fd);
            self.fd = -1;
        }
    }
}

@platform(macos | linux)
extend TcpStream {
    /// Connect to `host:port`, parking until the connection resolves. `None` if it fails.
    pub fn connect(host: str, port: i32) Option<TcpStream> {
        let mut h = String::from_str(host);
        let fd = unsafe sc_io::sc_tcp_connect(h.cstr(), port);
        h.free();
        if fd < 0 {
            return Option::<TcpStream>::None;
        }
        // A non-blocking connect finishes asynchronously: the socket becomes writable, and only then does
        // it say whether it actually connected.
        io::wait_writable(fd);
        if unsafe sc_io::sc_tcp_connect_result(fd) != 0 {
            let _ = unsafe sc_io::sc_io_close(fd);
            return Option::<TcpStream>::None;
        }
        return Option::<TcpStream>::Some(TcpStream { fd: fd });
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

@platform(macos | linux)
extend TcpStream as Free {
    pub fn free(self: &mut TcpStream) {
        self.close();
    }
}
