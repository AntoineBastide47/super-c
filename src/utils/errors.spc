// Diagnostics for every pass: structured records accumulate as (severity, span, message, note chain)
// rows against one source buffer; `finalize` dedups the records, then renders each one into a
// caret-annotated terminal block held in a parallel `rendered_*` store -- it never rewrites a stored
// record -- and `log` prints warnings then errors. The LSP and the build system read the records
// directly; nothing parses rendered text back into data.
// LintFix rows are the structured suggestion store: machine-applicable repairs for `lint --fix`
// (kind 3 carries generated text via `fix_texts`); `fixable_errs` counts errors carrying one, so
// --fix may apply despite errors only when EVERY error is fixable.
import stdlib;
import string;

/// Per-category cap on recorded diagnostics; emit/warn silently drop rows past it.
pub const ERRORS_MAX: usize = 256;

/// Severity values match the LSP's DiagnosticSeverity, so consumers forward them unchanged.
pub const SEV_ERROR: u8 = 1;
pub const SEV_WARNING: u8 = 2;

/// Empty note-chain link (note indexes are dense u32s into Errors.note_pool).
pub const NOTE_NONE: u32 = 0xFFFFFFFF;

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

/// One structured diagnostic. The span is bytes into the owning source buffer; `code` is a reserved
/// stable diagnostic code (0 = none); `sequence` records emission order across both severities, so a
/// later consumer can merge diagnostics from several producers in a stable order.
pub struct Diagnostic {
    pub severity: u8, // SEV_ERROR / SEV_WARNING
    pub code: u16, // reserved diagnostic code; 0 = none
    pub start: u32,
    pub len: u32,
    pub msg: String,
    pub note_head: u32, // first attached note in Errors.note_pool; NOTE_NONE = none
    pub note_tail: u32,
    pub sequence: u32,
}

/// One note line, chained per diagnostic through the shared pool (no vector per diagnostic).
pub struct Note {
    pub text: String,
    pub next: u32, // next note of the same diagnostic; NOTE_NONE at the end
}

/// Diagnostic accumulator for one source buffer. Records stay raw for the whole pipeline; `finalize`
/// fills the parallel `rendered_*` vectors the terminal `log` prints.
pub struct Errors {
    pub errors: Vector<Diagnostic>,
    pub warns: Vector<Diagnostic>, // non-fatal lint diagnostics (rendered like errors, never fail the build)
    pub note_pool: Vector<Note>, // shared note storage; per-diagnostic chains via note_head/next
    pub rendered_errors: Vector<String>, // finalize's terminal blocks, parallel to the (deduped) records
    pub rendered_warns: Vector<String>,
    pub fixes: Vector<LintFix>,
    pub fix_texts: Vector<String>, // generated insertion payloads for kind-3 fixes
    pub fixable_errs: u32, // errors carrying a machine fix -- `lint --fix` may proceed when EVERY error is fixable
    pub seq: u32, // next emission sequence
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
            errors: Vector::<Diagnostic>::new(),
            warns: Vector::<Diagnostic>::new(),
            note_pool: Vector::<Note>::new(),
            rendered_errors: Vector::<String>::new(),
            rendered_warns: Vector::<String>::new(),
            fixes: Vector::<LintFix>::new(),
            fix_texts: Vector::<String>::new(),
            fixable_errs: 0,
            seq: 0,
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
        let s = self.seq;
        self.seq = s + 1;
        self.warns.push(
            Diagnostic {
                severity: SEV_WARNING,
                code: 0,
                start: at,
                len: len,
                msg: msg,
                note_head: NOTE_NONE,
                note_tail: NOTE_NONE,
                sequence: s,
            },
        );
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
        let s = self.seq;
        self.seq = s + 1;
        self.errors.push(
            Diagnostic {
                severity: SEV_ERROR,
                code: 0,
                start: at,
                len: len,
                msg: msg,
                note_head: NOTE_NONE,
                note_tail: NOTE_NONE,
                sequence: s,
            },
        );
    }

    /// Record a diagnostic that was produced OUT of source order -- a region/lifetime error the solver
    /// only discovers after the whole function body has been walked. `from` is the index the enclosing
    /// function's diagnostics start at; the record is inserted at the first position in [from, len)
    /// whose span starts after `at`, so it lands where a reader expects it instead of after every other
    /// diagnostic in the function. Diagnostics already recorded keep their relative order (and their
    /// emission `sequence`). Returns the index it landed at, for `note_at`.
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
        while k < n && self.errors[k].start <= at {
            k = k + 1;
        }
        let s = self.seq;
        self.seq = s + 1;
        self.errors.insert(
            k,
            Diagnostic {
                severity: SEV_ERROR,
                code: 0,
                start: at,
                len: len,
                msg: msg,
                note_head: NOTE_NONE,
                note_tail: NOTE_NONE,
                sequence: s,
            },
        );
        return k;
    }

    // Append `msg` to error `index`'s note chain (shared pool; insertion order preserved).
    @c.cold
    fn attach_note(self: &mut Self, index: usize, msg: String) {
        if index >= self.errors.len() {
            return;
        }
        let id = self.note_pool.len() as u32;
        self.note_pool.push(Note { text: msg, next: NOTE_NONE });
        if self.errors[index].note_head == NOTE_NONE {
            self.errors[index].note_head = id;
        } else {
            let t = self.errors[index].note_tail;
            self.note_pool[t as usize].next = id;
        }
        self.errors[index].note_tail = id;
    }

    /// Attach a note line to the most recent diagnostic. Takes ownership of `msg`.
    @c.cold
    pub fn note(self: &mut Self, msg: String) {
        let n = self.errors.len();
        if n == 0 {
            return;
        }
        self.attach_note(n - 1, msg);
    }

    /// Attach a note to a SPECIFIC diagnostic (the index `emit_ordered` returned) -- `note` always
    /// targets the last one, which is wrong once a diagnostic has been inserted out of order.
    @c.cold
    pub fn note_at(self: &mut Self, index: usize, msg: String) {
        self.attach_note(index, msg);
    }

    // Structural equality for dedup: span, code, message bytes, and the note chains. Severity is
    // implied (dedup runs within one record vector).
    @c.cold
    fn same_diag(self: &Self, a: &Diagnostic, b: &Diagnostic) bool {
        if a.start != b.start || a.len != b.len || a.code != b.code || !a.msg.equals(&b.msg) {
            return false;
        }
        let mut x = a.note_head;
        let mut y = b.note_head;
        while x != NOTE_NONE && y != NOTE_NONE {
            if !self.note_pool[x as usize].text.equals(&self.note_pool[y as usize].text) {
                return false;
            }
            x = self.note_pool[x as usize].next;
            y = self.note_pool[y as usize].next;
        }
        return x == NOTE_NONE && y == NOTE_NONE;
    }

    /// Dedup identical records (order-preserving; the same error can be emitted from more than one
    /// pass), then render every survivor into a caret-annotated terminal block against `source`/`file`.
    /// The records themselves are never rewritten. Call once, before `log`.
    @c.cold
    pub fn finalize(self: &mut Self, source: str, file: str) {
        if self.errors.len() == 0 && self.warns.len() == 0 {
            return;
        }
        // Cold path: clone survivors into a fresh vector, drop the rest (note chains stay valid: the
        // pool is append-only and chains are copied by index).
        let mut uniq = Vector::<Diagnostic>::new();
        for k in 0..self.errors.len() {
            let mut seen = false;
            for j in 0..uniq.len() {
                if self.same_diag(uniq.at(j), self.errors.at(k)) {
                    seen = true;
                }
            }
            if !seen {
                let d = self.errors.at(k);
                uniq.push(
                    Diagnostic {
                        severity: d.severity,
                        code: d.code,
                        start: d.start,
                        len: d.len,
                        msg: d.msg.clone(),
                        note_head: d.note_head,
                        note_tail: d.note_tail,
                        sequence: d.sequence,
                    },
                );
            }
        }
        self.errors = uniq;
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
        let mut re = Vector::<String>::new();
        for k in 0..self.errors.len() {
            re.push(render(self.errors.at(k), source, &line_starts, file, &self.note_pool, "error"));
        }
        self.rendered_errors = re;
        let mut rw = Vector::<String>::new();
        for k in 0..self.warns.len() {
            rw.push(render(self.warns.at(k), source, &line_starts, file, &self.note_pool, "warning"));
        }
        self.rendered_warns = rw;
    }

    /// Print the finalized blocks to stderr, warnings before errors. Falls back to the raw messages
    /// when `finalize` has not run.
    @c.cold
    pub fn log(self: &Self) {
        if self.rendered_warns.len() == self.warns.len() && self.rendered_errors.len() == self.errors.len() {
            for i in 0..self.rendered_warns.len() {
                self.rendered_warns[i].eprintln();
            }
            for i in 0..self.rendered_errors.len() {
                self.rendered_errors[i].eprintln();
            }
        } else {
            for i in 0..self.warns.len() {
                self.warns[i].msg.eprintln();
            }
            for i in 0..self.errors.len() {
                self.errors[i].msg.eprintln();
            }
        }
    }
}

extend Errors as Free {
    pub fn free(self: &mut Self) {
        self.errors.free();
        self.warns.free();
        self.note_pool.free();
        self.rendered_errors.free();
        self.rendered_warns.free();
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

// The `--> file:line:col` location, the offending source line (windowed to 120 cols), and the
// caret run under the span -- the block every rendered diagnostic shares.
@c.cold
fn push_loc_block(out: &mut String, source: str, line_starts: &Vector<u32>, mut off: u32, span: u32, file: str) {
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
    out.push_str("--> ");
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
}

// Render one record into a pretty source-annotated block: the message, the location block, and the
// note chain ("\n  = note: <text>" per note, continuation lines unprefixed).
@c.cold
fn render(d: &Diagnostic, source: str, line_starts: &Vector<u32>, file: str, pool: &Vector<Note>, kind: str) String {
    let mut out = String::new();
    out.push_str(kind);
    out.push_str(": ");
    out.push_string(&d.msg);
    out.push_byte(10); // '\n'
    push_loc_block(&mut out, source, line_starts, d.start, d.len, file);
    let mut n = d.note_head;
    while n != NOTE_NONE {
        out.push_str("\n  = note: ");
        out.push_string(&pool[n as usize].text);
        n = pool[n as usize].next;
    }
    return out;
}

/// A bare location block for a SECONDARY site -- rendered into a note, where the primary rendering
/// pass cannot reach another file's source. Builds its own line index (cold path).
@c.cold
pub fn render_site(source: str, file: str, off: u32, span: u32) String {
    let mut line_starts = Vector::<u32>::new();
    line_starts.push(0);
    let len = source.len();
    let mut i: usize = 0;
    while i < len {
        let b = source[i];
        if b == 10 {
            i = i + 1;
            line_starts.push(i as u32);
        } else if b == 13 {
            i = i + 1;
            if i < len && source[i] == 10 {
                i = i + 1;
            }
            line_starts.push(i as u32);
        } else {
            i = i + 1;
        }
    }
    let mut out = String::new();
    push_loc_block(&mut out, source, &line_starts, off, span, file);
    line_starts.free();
    return out;
}
