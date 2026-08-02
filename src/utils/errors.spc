// Diagnostics for every pass: fatal `errors` and non-fatal lint `warns` accumulate as (message, span)
// rows against one source buffer; `finalize` renders each row IN PLACE into a caret-annotated block
// (then dedups identical blocks, compacting spans alongside) and `log` prints warnings then errors.
// LintFix rows record machine-applicable repairs for `lint --fix` (kind 3 carries generated text via
// `fix_texts`); `fixable_errs` counts errors carrying one, so --fix may apply despite errors only
// when EVERY error is fixable.
import stdlib;
import string;

/// Per-category cap on recorded diagnostics; emit/warn silently drop rows past it.
pub const ERRORS_MAX: usize = 256;

/// A machine-applicable fix for a lint diagnostic: kind 0 deletes [start, end); kind 1 inserts '_'
/// before `start` (unused-binding rename); kind 2 inserts 'const ' before `start` (const-fn
/// suggestion); kind 3 inserts `fix_texts[text]` before `start` (generated code, e.g. a Free impl);
/// kind 4 replaces [start, end) with `fix_texts[text]` (an edit no delete/insert pair expresses, e.g.
/// unwrapping `(*e)` to `e`). Collected alongside `warn` and applied by `lint --fix`; `warn` indexes
/// the warning it repairs (the LSP turns those into quick fixes; error-attached kind-3 fixes stay CLI-only).
pub struct LintFix {
    pub start: u32,
    pub end: u32,
    pub kind: u8,
    pub warn: u32, // index into `warns`; 0xFFFFFFFF = unattached
    pub text: u32, // index into `fix_texts` (kind 3); 0xFFFFFFFF = none
    pub module: u32, // owning ModuleId, stamped when fixes drain into the driver's shared vector (0 inside Errors)
}

/// Diagnostic accumulator for one source buffer. Messages are raw until `finalize` rewrites them into
/// rendered blocks; `starts`/`lens` are parallel span vectors that survive finalize (the LSP reads them).
pub struct Errors {
    pub errors: Vector<String>,
    pub notes: Vector<String>,
    pub starts: Vector<u32>,
    pub lens: Vector<u32>,
    pub warns: Vector<String>, // non-fatal lint diagnostics (rendered like errors, never fail the build)
    pub warn_starts: Vector<u32>,
    pub warn_lens: Vector<u32>,
    pub fixes: Vector<LintFix>,
    pub fix_texts: Vector<String>, // generated insertion payloads for kind-3 fixes
    pub fixable_errs: u32, // errors carrying a machine fix -- `lint --fix` may proceed when EVERY error is fixable
}

/// Aborts the process with an out-of-memory message; never returns.
pub fn oom() {
    eprint("fatal: out of memory\n");
    unsafe stdlib::abort();
}

/// A borrowed `str` view of a NUL-terminated C string (for routing a raw C string through `format(...)`).
/// Safety: `p` must be non-null and NUL-terminated; the view is only valid while the bytes live.
pub fn cstr<'a>(p: *const char) str<'a> {
    return str::from_raw(p as *const u8, unsafe string::strlen(p));
}

/// A borrowed `str` view of the source bytes in the span [start, end) -- the idiomatic replacement for the
/// old `%.*s` (width, source+start) diagnostic argument pair.
pub const fn span_str(src: str, start: u32, end: u32) str {
    return src[start as usize..end as usize];
}

extend Errors {
    pub fn new() Errors {
        return Errors {
            errors: Vector::<String>::new(),
            notes: Vector::<String>::new(),
            starts: Vector::<u32>::new(),
            lens: Vector::<u32>::new(),
            warns: Vector::<String>::new(),
            warn_starts: Vector::<u32>::new(),
            warn_lens: Vector::<u32>::new(),
            fixes: Vector::<LintFix>::new(),
            fix_texts: Vector::<String>::new(),
            fixable_errs: 0,
        };
    }

    pub const fn has_errors(self: &Self) bool {
        return self.errors.len() != 0;
    }

    pub const fn has_warnings(self: &Self) bool {
        return self.warns.len() != 0;
    }

    /// Record a non-fatal warning at [at, at+len). Takes ownership of `msg`; drops it past ERRORS_MAX.
    @c.cold
    pub fn warn(self: &mut Self, at: u32, len: u32, msg: String) {
        if self.warns.len() >= ERRORS_MAX {
            return;
        }
        self.warns.push(msg);
        self.warn_starts.push(at);
        self.warn_lens.push(len);
    }

    /// Attach a machine-applicable fix to the warning being emitted (fix() always follows its warn();
    /// past the ERRORS_MAX cap the index degrades to the last kept warning).
    @c.cold
    pub fn fix(self: &mut Self, start: u32, end: u32, kind: u8) {
        let mut w: u32 = 0xFFFFFFFF;
        if self.warns.len() != 0 {
            w = (self.warns.len() - 1) as u32;
        }
        self.fixes.push(LintFix { start: start, end: end, kind: kind, warn: w, text: 0xFFFFFFFF });
    }

    /// Attach a replace fix to the WARNING just emitted (kind 4): `lint --fix` deletes [start, end) and
    /// inserts `text` in its place. A single fix expresses an edit that no delete/insert pair can (e.g.
    /// unwrapping `(*e)` to `e`, where the kept text sits between the two deletions). Takes ownership of
    /// `text` (fix() always follows its warn(); past the cap the index degrades to the last kept warning).
    @c.cold
    pub fn fix_replace(self: &mut Self, start: u32, end: u32, text: String) {
        let t = self.fix_texts.len() as u32;
        self.fix_texts.push(text);
        let mut w: u32 = 0xFFFFFFFF;
        if self.warns.len() != 0 {
            w = (self.warns.len() - 1) as u32;
        }
        self.fixes.push(LintFix { start: start, end: end, kind: 4, warn: w, text: t });
    }

    /// Record a diagnostic (an already-formatted message, built with `format(...)`) at the source span
    /// [at, at+len). Takes ownership of `msg` (freed here if the message cap is hit).
    @c.cold
    pub fn emit(self: &mut Self, at: u32, len: u32, msg: String) {
        if self.errors.len() >= ERRORS_MAX {
            return;
        }
        self.errors.push(msg);
        self.notes.push(String::new());
        self.starts.push(at);
        self.lens.push(len);
    }

    /// Record a diagnostic that was produced OUT of source order -- a region/lifetime error the solver
    /// only discovers after the whole function body has been walked. `from` is the index the enclosing
    /// function's diagnostics start at; the message is inserted at the first position in [from, len)
    /// whose span starts after `at`, so it lands where a reader expects it instead of after every other
    /// diagnostic in the function. Diagnostics already recorded keep their relative order. Returns the
    /// index it landed at, for `note_at`.
    @c.cold
    pub fn emit_ordered(self: &mut Self, from: usize, at: u32, len: u32, msg: String) usize {
        if self.errors.len() >= ERRORS_MAX {
            return ERRORS_MAX;
        }
        let n = self.errors.len();
        let mut k = if from < n {
            from;
        } else {
            n;
        };
        while k < n && self.starts[k] <= at {
            k = k + 1;
        }
        self.errors.insert(k, msg);
        self.notes.insert(k, String::new());
        self.starts.insert(k, at);
        self.lens.insert(k, len);
        return k;
    }

    /// Attach a note line to the most recent diagnostic. Takes ownership of `msg`.
    @c.cold
    pub fn note(self: &mut Self, msg: String) {
        let n = self.errors.len();
        if n == 0 || self.notes.len() < n {
            return;
        }
        self.notes[n - 1].push_str("\n  = note: ");
        self.notes[n - 1].push_string(&msg);
    }

    /// Attach a note to a SPECIFIC diagnostic (the index `emit_ordered` returned) -- `note` always
    /// targets the last one, which is wrong once a diagnostic has been inserted out of order.
    @c.cold
    pub fn note_at(self: &mut Self, index: usize, msg: String) {
        if index >= self.notes.len() {
            return;
        }
        self.notes[index].push_str("\n  = note: ");
        self.notes[index].push_string(&msg);
    }

    /// Render every recorded message in place into a caret-annotated block against `source`/`file`,
    /// then dedup identical error blocks (spans compacted alongside). Call once, before `log`.
    @c.cold
    pub fn finalize(self: &mut Self, source: str, file: str) {
        if self.errors.len() == 0 && self.warns.len() == 0 {
            return;
        }
        let len = source.len();
        let mut line_starts = Vector::<u32>::new();
        line_starts.reserve(len / 16);
        line_starts.push(0);
        let mut i: usize = 0;
        while i < len {
            let b = source[i];
            if b == b'\n' {
                i = i + 1;
                line_starts.push(i as u32);
            } else if b == b'\r' {
                i = i + 1;
                if i < len && source[i] == b'\n' {
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
                self.starts[k],
                self.lens[k],
                file,
                self.notes.at(k),
                "error",
            );
            self.errors.set(k, block);
        }
        let empty_note = String::new();
        for k in 0..self.warns.len() {
            let block = render(
                self.warns.at(k),
                source,
                &line_starts,
                self.warn_starts[k],
                self.warn_lens[k],
                file,
                &empty_note,
                "warning",
            );
            self.warns.set(k, block);
        }

        // Order-preserving dedup of identical rendered blocks (the same error can be emitted from more
        // than one pass). Cold path: clone survivors into a fresh vector, drop the rest. starts/lens are
        // compacted in parallel so each surviving block keeps its span (the LSP reads them post-finalize).
        let mut uniq = Vector::<String>::new();
        let mut ustarts = Vector::<u32>::new();
        let mut ulens = Vector::<u32>::new();
        for k in 0..self.errors.len() {
            let mut seen = false;
            for j in 0..uniq.len() {
                if uniq[j].equals(self.errors.at(k)) {
                    seen = true;
                }
            }
            if !seen {
                uniq.push(self.errors[k].clone());
                ustarts.push(self.starts[k]);
                ulens.push(self.lens[k]);
            }
        }
        self.errors = uniq;
        self.starts = ustarts;
        self.lens = ulens;
    }

    /// Print the finalized blocks to stderr, warnings before errors.
    @c.cold
    pub fn log(self: &Self) {
        for i in 0..self.warns.len() {
            self.warns[i].eprintln();
        }
        for i in 0..self.errors.len() {
            self.errors[i].eprintln();
        }
    }
}

extend Errors as Free {
    pub fn free(self: &mut Self) {
        self.errors.free();
        self.notes.free();
        self.starts.free();
        self.lens.free();
        self.warns.free();
        self.warn_starts.free();
        self.warn_lens.free();
        self.fixes.free();
        self.fix_texts.free();
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
    source: str,
    line_starts: &Vector<u32>,
    mut off: u32,
    span: u32,
    file: str,
    notes: &String,
    kind: str,
) String {
    let src_len = source.len();
    if off as usize > src_len {
        off = src_len as u32;
    }
    let li = line_index(line_starts, off);
    let lstart = line_starts[li];
    let mut lend = lstart as usize;
    while lend < src_len && source[lend] != 10 && source[lend] != 13 {
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
    out.push_str(kind);
    out.push_str(": ");
    out.push_string(msg);
    out.push_str("\n--> ");
    if file.len() != 0 {
        out.push_str(file);
        out.push_byte(58); // ':'
    }
    out.push_u64(line_no as u64);
    out.push_byte(58);
    out.push_u64((real_col + 1) as u64);
    // The gutter width is the line number's digit count: the numbered source line reads "<line_no> | ",
    // so the blank and caret lines must pad that many spaces before " | " or the caret run lands one
    // column left of its span for every digit in the line number.
    let mut nd: usize = 1;
    let mut t = line_no;
    while t >= 10 {
        t = t / 10;
        nd = nd + 1;
    }
    out.push_byte(10); // '\n'
    for _ in 0..nd {
        out.push_byte(32);
    }
    out.push_str(" |\n");
    out.push_u64(line_no as u64);
    out.push_str(" | ");
    out.push_str(source[disp_start..disp_end]);
    out.push_byte(10); // '\n'
    for _ in 0..nd {
        out.push_byte(32);
    }
    out.push_str(" | ");
    for _ in 0..caret_col {
        out.push_byte(32);
    } // ' '
    for _ in 0..carets {
        out.push_byte(94);
    } // '^'
    out.push_string(notes);
    return out;
}
