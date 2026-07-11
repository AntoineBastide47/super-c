import stdlib;
import string;

pub const ERRORS_MAX: usize = 256;

pub struct Errors {
    pub errors: Vector<String>,
    pub notes: Vector<String>,
    pub starts: Vector<u32>,
    pub lens: Vector<u32>,
}

pub fn oom() void {
    eprint("fatal: out of memory\n");
    unsafe stdlib::abort();
}

// A borrowed `str` view of a NUL-terminated C string (for routing a raw C string through `format(...)`).
pub fn cstr(p: *const char) str {
    return str::from_raw(p as *const u8, unsafe string::strlen(p));
}

// A borrowed `str` view of the source bytes in the span [start, end) -- the idiomatic replacement for the
// old `%.*s` (width, source+start) diagnostic argument pair.
pub fn span_str(src: *const u8, start: u32, end: u32) str {
    return str::from_raw(unsafe (src + start as usize), (end - start) as usize);
}

extend Errors {
    pub fn new() Errors {
        return Errors {
            errors: Vector::<String>::new(),
            notes: Vector::<String>::new(),
            starts: Vector::<u32>::new(),
            lens: Vector::<u32>::new(),
        };
    }

    pub fn has_errors(self: &Self) bool {
        return self.errors.len() != 0;
    }

    // Record a diagnostic (an already-formatted message, built with `format(...)`) at the source span
    // [at, at+len). Takes ownership of `msg` (freed here if the message cap is hit).
    @c.cold
    pub fn emit(self: &mut Self, at: u32, len: u32, msg: String) void {
        if self.errors.len() >= ERRORS_MAX {
            return;
        }
        self.errors.push(msg);
        self.notes.push(String::new());
        self.starts.push(at);
        self.lens.push(len);
    }

    // Attach a note line to the most recent diagnostic. Takes ownership of `msg`.
    @c.cold
    pub fn note(self: &mut Self, msg: String) void {
        let n = self.errors.len();
        if n == 0 || self.notes.len() < n {
            return;
        }
        self.notes[n - 1].push_str("\n  = note: ");
        self.notes[n - 1].push_string(&msg);
    }

    @c.cold
    pub fn finalize(self: &mut Self, source: *const u8, len: usize, file: str) void {
        if self.errors.len() == 0 {
            return;
        }
        let mut line_starts = Vector::<u32>::new();
        line_starts.reserve(len / 16);
        line_starts.push(0);
        let mut i: usize = 0;
        while i < len {
            let b = unsafe source[i];
            if b == b'\n' {
                i = i + 1;
                line_starts.push(i as u32);
            } else if b == b'\r' {
                i = i + 1;
                if i < len && unsafe source[i] == b'\n' {
                    i = i + 1;
                }
                line_starts.push(i as u32);
            } else {
                i = i + 1;
            }
        }
        for k in 0..self.errors.len() {
            let block = render(
                self.errors.at(k),
                source,
                &line_starts,
                len,
                self.starts[k],
                self.lens[k],
                file,
                self.notes.at(k),
            );
            self.errors.set(k, block);
        }
        // Order-preserving dedup of identical rendered blocks (the same error can be emitted from more
        // than one pass). Cold path: clone survivors into a fresh vector, drop the rest.
        let mut uniq = Vector::<String>::new();
        for k in 0..self.errors.len() {
            let mut seen = false;
            for j in 0..uniq.len() {
                if uniq[j].equals(self.errors.at(k)) {
                    seen = true;
                }
            }
            if !seen {
                uniq.push(self.errors[k].clone());
            }
        }
        self.errors.free();
        self.errors = uniq;
    }

    @c.cold
    pub fn log(self: &Self) void {
        for i in 0..self.errors.len() {
            self.errors[i].eprintln();
        }
    }
}

extend Errors as Free {
    pub fn free(self: &mut Self) void {
        self.errors.free();
        self.notes.free();
        self.starts.free();
        self.lens.free();
    }
}

fn line_index(line_starts: &Vector<u32>, off: u32) usize {
    let mut lo: usize = 0;
    let mut hi = line_starts.len();
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if line_starts[mid] <= off {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if lo == 0 {
        return 0;
    }
    return lo - 1;
}

// Render one diagnostic into a pretty source-annotated block: the message, a `--> file:line:col`
// location, the offending source line (windowed to 120 cols), a caret run under the span, and notes.
@c.cold
fn render(
    msg: &String,
    source: *const u8,
    line_starts: &Vector<u32>,
    src_len: usize,
    mut off: u32,
    span: u32,
    file: str,
    notes: &String,
) String {
    if off as usize > src_len {
        off = src_len as u32;
    }
    let li = line_index(line_starts, off);
    let lstart = line_starts[li];
    let mut lend = lstart as usize;
    while lend < src_len && unsafe source[lend] != 10 && unsafe source[lend] != 13 {
        lend = lend + 1;
    }
    let line_no = li + 1;
    let real_col = (off - lstart) as usize;
    let max_w: usize = 120;
    let mut disp_start = lstart as usize;
    let mut disp_end = lend;
    if lend - lstart as usize > max_w {
        if off as usize > lstart as usize + max_w / 2 {
            disp_start = off as usize - max_w / 2;
        }
        if disp_start + max_w < lend {
            disp_end = disp_start + max_w;
        } else {
            disp_end = lend;
        }
    }
    let line_len = disp_end - disp_start;
    let line_ptr = unsafe (source + disp_start);
    let caret_col = off as usize - disp_start;
    let mut carets: usize = 1;
    if span >= 1 {
        carets = span as usize;
    }
    if off as usize + carets > disp_end {
        if disp_end > off as usize {
            carets = disp_end - off as usize;
        } else {
            carets = 1;
        }
    }
    let mut out = String::new();
    out.push_str("error: ");
    out.push_string(msg);
    out.push_str("\n--> ");
    if file.len() != 0 {
        out.push_str(file);
        out.push_byte(58); // ':'
    }
    out.push_u64(line_no as u64);
    out.push_byte(58);
    out.push_u64((real_col + 1) as u64);
    out.push_str("\n |\n");
    out.push_u64(line_no as u64);
    out.push_str(" | ");
    out.push_bytes(line_ptr, line_len);
    out.push_str("\n | ");
    for _ in 0..caret_col {
        out.push_byte(32);
    } // ' '
    for _ in 0..carets {
        out.push_byte(94);
    } // '^'
    out.push_string(notes);
    return out;
}
