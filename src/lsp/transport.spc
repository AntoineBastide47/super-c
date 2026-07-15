// LSP base-protocol framing over C stdio streams: each message is "Content-Length: N\r\n" (+ other
// headers, ignored) then a blank line, then exactly N body bytes. Writes flush per message -- the client
// blocks on responses.
import stdio;
import string as cstring;

type HdrBuf = Array<char, 512>;
type ChunkBuf = Array<char, 4096>;

fn ascii_lower(b: u8) u8 {
    if b >= b'A' && b <= b'Z' {
        return b + 32;
    }
    return b;
}

// Case-insensitive "content-length:" prefix test (header names are case-insensitive).
fn is_content_length(line: str) bool {
    let name = "content-length:";
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

// Read one framed message body from `f`. None on EOF or malformed framing (missing/bad Content-Length).
pub fn read_message(f: *mut stdio::FILE) Option<String> {
    let mut clen: i64 = -1;
    loop {
        let mut line = HdrBuf {};
        if unsafe stdio::fgets(&mut line[0], 512, f) == null {
            return Option::<String>::None; // EOF
        }
        let l = str::from_cstr(&line[0]).trim();
        if l.len() == 0 {
            break; // blank line: end of headers
        }
        if is_content_length(l) {
            clen = (switch l.slice(15, l.len()).trim().parse_i64() {
                Some(n) => n,
                None => -1,
            });
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
            return Option::<String>::None; // EOF mid-body
        }
        body.push_bytes(((&chunk[0]) as *const char) as *const u8, r);
        got += r;
    }
    return Option::<String>::Some(body);
}

// Frame and send `body`, then flush.
pub fn write_message(f: *mut stdio::FILE, body: str) {
    let mut hdr = String::with_capacity(40);
    hdr.format_into("Content-Length: {}\r\n\r\n", body.len());
    unsafe stdio::fwrite(hdr.as_ptr(), 1, hdr.len(), f);
    unsafe stdio::fwrite(body.ptr(), 1, body.len(), f);
    unsafe stdio::fflush(f);
}
