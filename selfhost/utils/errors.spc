import stdio;
import stdlib;
import string;
import unistd;

pub const ERRORS_MAX: usize = 256;
pub const STDERR_FILENO: i32 = 2;

extern "C" {
    fn vsnprintf(buf: *mut char, n: usize, fmt: *const char, ap: va_list) i32;
    fn va_copy(dst: va_list, src: va_list) void;
}

pub struct Errors {
    pub errors: Vector<*mut char>,
    pub notes: Vector<*mut char>,
    pub starts: Vector<u32>,
    pub lens: Vector<u32>,
}

pub fn oom() void {
    unsafe stdio::fputs("fatal: out of memory\n".ptr() as *const char, stdio::stderr());
    unsafe stdlib::abort();
}

fn dup_empty() *mut char {
    let p = unsafe stdlib::malloc(1) as *mut char;
    if p == null { oom(); }
    unsafe p[0] = 0 as char;
    return p;
}

extend Errors {
    pub fn new() Errors {
        return Errors {
            errors: Vector::<*mut char>::new(),
            notes: Vector::<*mut char>::new(),
            starts: Vector::<u32>::new(),
            lens: Vector::<u32>::new(),
        };
    }

    pub fn has_errors(self: &Self) bool {
        return self.errors.len() != 0;
    }

    pub fn vemitf(self: &mut Self, at: u32, len: u32, fmt: *const char, mut args: va_list) void {
        if self.errors.len() >= ERRORS_MAX { return; }
        let mut copy = args;
        unsafe va_copy(copy, args);
        let msg_len = unsafe vsnprintf(null, 0, fmt, copy);
        va_end(copy);
        let result = unsafe stdlib::malloc((msg_len as usize) + 1) as *mut char;
        if result == null { oom(); }
        unsafe vsnprintf(result, (msg_len as usize) + 1, fmt, args);
        self.errors.push(result);
        self.notes.push(dup_empty());
        self.starts.push(at);
        self.lens.push(len);
    }

    pub fn emitf(self: &mut Self, at: u32, len: u32, fmt: *const char, ...) void {
        let mut args: va_list;
        va_start(args, fmt);
        self.vemitf(at, len, fmt, args);
        va_end(args);
    }

    pub fn vnotef(self: &mut Self, fmt: *const char, mut args: va_list) void {
        let n = self.errors.len();
        if n == 0 || self.notes.len() < n { return; }
        let mut copy = args;
        unsafe va_copy(copy, args);
        let msg_len = unsafe vsnprintf(null, 0, fmt, copy);
        va_end(copy);
        let msg = unsafe stdlib::malloc((msg_len as usize) + 1) as *mut char;
        if msg == null { oom(); }
        unsafe vsnprintf(msg, (msg_len as usize) + 1, fmt, args);
        let old = (*self.notes.at(n - 1)) as *mut char;
        let mut old_len: usize = 0;
        if old != null { old_len = unsafe string::strlen(old as *const char); }
        let add = unsafe string::strlen(msg as *const char) + "\n  = note: ".len() + 1;
        let next = unsafe stdlib::malloc(old_len + add + 1) as *mut char;
        if next == null { oom(); }
        if old_len != 0 { unsafe string::memcpy(next as *mut void, old, old_len); }
        unsafe stdio::snprintf(next + old_len, add + 1, "\n  = note: %s".ptr() as *const char, msg);
        unsafe stdlib::free(old as *mut void);
        unsafe stdlib::free(msg as *mut void);
        self.notes.set(n - 1, next);
    }

    pub fn notef(self: &mut Self, fmt: *const char, ...) void {
        let mut args: va_list;
        va_start(args, fmt);
        self.vnotef(fmt, args);
        va_end(args);
    }

    pub fn finalize(self: &mut Self, source: *const u8, len: usize, file: *const char) void {
        if self.errors.len() == 0 { return; }
        let mut line_starts = Vector::<u32>::new();
        line_starts.reserve(len / 16);
        line_starts.push(0);
        let mut i: usize = 0;
        while i < len {
            let b = unsafe source[i];
            if b == 10 {
                i = i + 1;
                line_starts.push(i as u32);
            } else if b == 13 {
                i = i + 1;
                if i < len && unsafe source[i] == 10 { i = i + 1; }
                line_starts.push(i as u32);
            } else {
                i = i + 1;
            }
        }
        for k in 0..self.errors.len() {
            let mut notes = "".ptr() as *const char;
            if k < self.notes.len() { notes = (*self.notes.at(k)) as *const char; }
            let block = render((*self.errors.at(k)) as *const char, source, &line_starts, len, *self.starts.at(k), *self.lens.at(k), file, notes);
            unsafe stdlib::free((*self.errors.at(k)) as *mut void);
            self.errors.set(k, block);
        }
        let mut w: usize = 0;
        for k in 0..self.errors.len() {
            let mut dup = false;
            let mut j: usize = 0;
            while j < w && !dup {
                dup = unsafe string::strcmp((*self.errors.at(j)) as *const char, (*self.errors.at(k)) as *const char) == 0;
                j = j + 1;
            }
            if dup {
                unsafe stdlib::free((*self.errors.at(k)) as *mut void);
            } else {
                if w != k { self.errors.set(w, (*self.errors.at(k)) as *mut char); }
                w = w + 1;
            }
        }
        self.errors.truncate(w);
        line_starts.free();
    }

    pub fn log(self: &Self) void {
        for i in 0..self.errors.len() {
            unsafe stdio::fprintf(stdio::stderr(), "%s\n".ptr() as *const char, *self.errors.at(i));
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
        if *line_starts.at(mid) <= off { lo = mid + 1; }
        else { hi = mid; }
    }
    if lo == 0 { return 0; }
    return lo - 1;
}

fn render(
    msg: *const char,
    source: *const u8,
    line_starts: &Vector<u32>,
    src_len: usize,
    mut off: u32,
    span: u32,
    file: *const char,
    notes: *const char,
) *mut char {
    if off as usize > src_len { off = src_len as u32; }
    let li = line_index(&*line_starts, off);
    let lstart = *line_starts.at(li);
    let mut lend = lstart as usize;
    while lend < src_len && unsafe source[lend] != 10 && unsafe source[lend] != 13 { lend = lend + 1; }
    let line_no = li + 1;
    let real_col = (off - lstart) as usize;
    let max_w: usize = 120;
    let mut disp_start = lstart as usize;
    let mut disp_end = lend;
    if lend - (lstart as usize) > max_w {
        if off as usize > (lstart as usize) + max_w / 2 { disp_start = (off as usize) - max_w / 2; }
        if disp_start + max_w < lend { disp_end = disp_start + max_w; }
        else { disp_end = lend; }
    }
    let line_len = disp_end - disp_start;
    let line_ptr = unsafe (source + disp_start);
    let caret_col = (off as usize) - disp_start;
    let mut carets: usize = 1;
    if span >= 1 { carets = span as usize; }
    if (off as usize) + carets > disp_end {
        if disp_end > off as usize { carets = disp_end - off as usize; }
        else { carets = 1; }
    }
    let bar = unsafe stdlib::malloc(carets + 1) as *mut char;
    if bar == null { oom(); }
    unsafe string::memset(bar as *mut void, '^' as i32, carets);
    unsafe bar[carets] = 0 as char;
    let mut fpfx = "".ptr() as *const char;
    let mut fsep = "".ptr() as *const char;
    if file != null && unsafe file[0] != 0 as char {
        fpfx = file;
        fsep = ":".ptr() as *const char;
    }
    let cap = unsafe string::strlen(msg) + unsafe string::strlen(notes) + line_len + real_col + carets + unsafe string::strlen(fpfx) + 160;
    let out = unsafe stdlib::malloc(cap) as *mut char;
    if out == null { oom(); }
    unsafe stdio::snprintf(
        out,
        cap,
        "error: %s\n--> %s%s%zu:%zu\n |\n%zu | %.*s\n | %*s%s%s".ptr() as *const char,
        msg,
        fpfx,
        fsep,
        line_no,
        real_col + 1,
        line_no,
        line_len as i32,
        line_ptr,
        caret_col as i32,
        "".ptr() as *const char,
        bar,
        notes,
    );
    unsafe stdlib::free(bar as *mut void);
    return out;
}
