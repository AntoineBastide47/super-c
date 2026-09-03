// LSP base-protocol framing over C stdio streams: each message is "Content-Length: N\r\n" (+ other
// headers, ignored) then a blank line, then exactly N body bytes. Writes flush per message: the client
// blocks on responses.
import stdio;

type HdrBuf = Array<char, 512>;
type ChunkBuf = Array<char, 4096>;

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

/// Read one framed message body from `f`. None on EOF or malformed framing: missing, duplicate, or
/// bad Content-Length, an overlong or over-count header line, a non-UTF-8 charset, or a declared
/// length over the 128 MiB cap.
pub fn read_message(f: *mut stdio::FILE) Option<String> {
    let mut clen: i64 = -1;
    let mut headers: u32 = 0;
    loop {
        let mut line = HdrBuf {};
        if unsafe stdio::fgets(&mut line[0], 512, f) == null {
            return Option::<String>::None;
        }
        let raw = str::from_cstr(&line[0]);
        // A header line that fills the buffer without its newline is over the limit.
        if raw.len() == 511 && raw[510] != b'\n' {
            return Option::<String>::None;
        }
        let l = raw.trim();
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
    let n = clen as usize;
    let mut body = String::with_capacity(n);
    let mut chunk = ChunkBuf {};
    let mut got: usize = 0;
    while got < n {
        let mut want = n - got;
        if want > 4096 {
            want = 4096;
        }
        let r = unsafe stdio::fread((&mut chunk[0]) as *mut char, 1, want, f);
        if r == 0 {
            return Option::<String>::None;
        }
        body.push_bytes(((&chunk[0]) as *const char) as *const u8, r);
        got += r;
    }
    return Option::<String>::Some(body);
}

/// Frame and send `body`, then flush.
pub fn write_message(f: *mut stdio::FILE, body: str) {
    let mut hdr = String::with_capacity(40);
    hdr.format_into("Content-Length: {}\r\n\r\n", body.len());
    unsafe stdio::fwrite(hdr.as_ptr(), 1, hdr.len(), f);
    unsafe stdio::fwrite(body.ptr(), 1, body.len(), f);
    unsafe stdio::fflush(f);
}
