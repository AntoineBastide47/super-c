// LSP base-protocol framing over C stdio streams: each message is "Content-Length: N\r\n" (+ other
// headers, ignored) then a blank line, then exactly N body bytes. Reads go through a `Reader`
// over the stream's descriptor, so the server can ask whether another message has arrived
// without blocking. Writes flush per message: the client blocks on responses.
import stdio;
import driver_shim as shim;

const FILL: usize = 65536; // bytes asked of the descriptor per read
const HDR_MAX: usize = 511; // a header line longer than this (without its newline) is malformed

/// Buffered reads over a stream's descriptor, past the stdio buffer: the bytes not yet parsed
/// wait in `buf` from `pos`; `pending` answers whether a read would return at once.
pub struct Reader {
    pub f: *mut stdio::FILE,
    buf: Vector<u8>,
    pos: usize,
    eof: bool, // the descriptor reported end of stream or an error: every later read is None
}

extend Reader {
    pub fn new(f: *mut stdio::FILE) Reader {
        return Reader { f: f, buf: Vector::<u8>::new(), pos: 0, eof: false };
    }

    /// True when an unread byte is buffered or the descriptor would hand one over now.
    pub fn pending(self: &Self) bool {
        return self.pos < self.buf.len() || !self.eof && unsafe shim::sc_file_pending(self.f) == 1;
    }

    // Move the unread bytes to the front, then append what the descriptor has: false at the end
    // of the stream.
    fn fill(self: &mut Self) bool {
        if self.eof {
            return false;
        }
        if self.pos > 0 {
            let rest = self.buf.len() - self.pos;
            for k in 0..rest {
                self.buf.set(k, self.buf[self.pos + k]);
            }
            self.buf.truncate(rest);
            self.pos = 0;
        }
        let old = self.buf.len();
        self.buf.resize_default(old + FILL);
        let r = unsafe shim::sc_file_read(self.f, (self.buf.as_ptr() + old) as *mut void, FILL);
        if r <= 0 {
            self.buf.truncate(old);
            self.eof = true;
            return false;
        }
        self.buf.truncate(old + r as usize);
        return true;
    }

    // The next header line without its newline, or None at the end of the stream or past the
    // length limit.
    fn line(self: &mut Self) Option<str> {
        let mut e = self.pos;
        loop {
            while e < self.buf.len() && e - self.pos <= HDR_MAX && self.buf[e] != b'\n' {
                e += 1;
            }
            if e - self.pos > HDR_MAX {
                return Option::<str>::None;
            }
            if e < self.buf.len() {
                break;
            }
            let d = e - self.pos;
            if !self.fill() {
                return Option::<str>::None;
            }
            e = self.pos + d;
        }
        let l = str::from_raw(unsafe (self.buf.as_ptr() + self.pos), e - self.pos);
        self.pos = e + 1;
        return Option::<str>::Some(l);
    }

    // The next `n` bytes as a body, or None at the end of the stream.
    fn body(self: &mut Self, n: usize) Option<String> {
        while self.buf.len() - self.pos < n {
            if !self.fill() {
                return Option::<String>::None;
            }
        }
        let mut body = String::with_capacity(n);
        body.push_bytes(unsafe (self.buf.as_ptr() + self.pos), n);
        self.pos += n;
        return Option::<String>::Some(body);
    }
}

const fn ascii_lower(b: u8) u8 {
    if b >= b'A' && b <= b'Z' {
        return b + 32;
    }
    return b;
}

// Case-insensitive header-name prefix test (`name` is the lowercase spelling with its colon).
fn header_is(line: str, name: str) bool {
    if line.len() < name.len() {
        return false;
    }
    for i in 0..name.len() {
        if ascii_lower(line[i]) != name[i] {
            return false;
        }
    }
    return true;
}

// True when a Content-Type value names an acceptable charset: none stated, or utf-8/utf8.
fn charset_ok(v: str) bool {
    let key = "charset=";
    let mut i: usize = 0;
    while i + key.len() <= v.len() {
        let mut hit = true;
        for k in 0..key.len() {
            if ascii_lower(v[i + k]) != key[k] {
                hit = false;
            }
        }
        if hit {
            let mut e = i + key.len();
            while e < v.len() && v[e] != b';' && v[e] != b' ' {
                e += 1;
            }
            let cs = v.slice(i + key.len(), e);
            let mut low = String::with_capacity(cs.len());
            for k in 0..cs.len() {
                if cs[k] != b'"' {
                    low.push_byte(ascii_lower(cs[k]));
                }
            }
            return low.as_str() == "utf-8" || low.as_str() == "utf8";
        }
        i += 1;
    }
    return true;
}

/// Read one framed message body from `rd`. None on EOF or malformed framing: missing, duplicate, or
/// bad Content-Length, an overlong or over-count header line, a non-UTF-8 charset, or a declared
/// length over the 128 MiB cap.
pub fn read_message(rd: &mut Reader) Option<String> {
    let mut clen: i64 = -1;
    let mut headers: u32 = 0;
    loop {
        let lo = rd.line();
        if lo.is_none() {
            return Option::<String>::None;
        }
        let l = lo.unwrap().trim();
        if l.len() == 0 {
            break;
        }
        headers += 1;
        if headers > 32 {
            return Option::<String>::None;
        }
        if header_is(l, "content-length:") {
            if clen >= 0 {
                return Option::<String>::None;
            }
            clen = (switch l.slice(15, l.len()).trim().parse_i64() {
                Some(n) => n,
                None => -1,
            });
            if clen < 0 {
                return Option::<String>::None;
            }
        } else if header_is(l, "content-type:") {
            if !charset_ok(l.slice(13, l.len())) {
                return Option::<String>::None;
            }
        }
    }
    if clen < 0 || clen > 128 * 1024 * 1024 {
        return Option::<String>::None;
    }
    return rd.body(clen as usize);
}

/// Frame and send `body`, then flush.
pub fn write_message(f: *mut stdio::FILE, body: str) {
    let mut hdr = String::with_capacity(40);
    hdr.format_into("Content-Length: {}\r\n\r\n", body.len());
    unsafe stdio::fwrite(hdr.as_ptr(), 1, hdr.len(), f);
    unsafe stdio::fwrite(body.ptr(), 1, body.len(), f);
    unsafe stdio::fflush(f);
}
