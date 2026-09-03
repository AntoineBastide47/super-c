// Self-hosted port of tests/errors_test.c: direct coverage of utils::errors; emit (message + span
// collection), finalize (1-based line:col, caret count/clamping, \r/\n/\r\n line starts, long-line
// windowing, file prefix, notes, offset-past-EOF). The two log-capture cases (plain vs pty-colored
// stderr) test terminal I/O plumbing, not rendering logic, and are covered by the C suite.
import utils::errors as diag;
import string as cstring;

// Array-field wrappers: `{}` init zero-fills the omitted array (Super-C has no `[v; N]` repeat literal).
struct Buf202 {
    pub b: [char; 202],
}
struct Buf151 {
    pub b: [char; 151],
}

fn contains(hay: &String, needle: str) bool {
    return hay.contains(needle);
}
fn offset_of(src: str, needle: str) u32 {
    let p = unsafe cstring::strstr(src.ptr() as *const char, needle.ptr() as *const char);
    if p == null {
        return 0;
    }
    return (p as usize - src.ptr() as usize) as u32;
}

// Emit one message at (off, span) over `src`, finalize with `file`, and return an owned copy of the
// rendered block 0 (owned so the caller can free `e` before inspecting it).
fn render_into(e: &mut diag::Errors, src: str, msg: str, off: u32, span: u32, file: str) String {
    e.emit(off, span, format("{}", msg));
    e.finalize(src, file);
    return e.rendered_errors.at(0).clone();
}

@test
fn emit_collects() {
    let mut e = diag::Errors::new();
    e.emit(12, 3, format("count is {} for {}", 7, "x"));
    assert(e.errors.len() == 1, "one record collected");
    let d = e.errors.at(0);
    // Records stay raw.
    assert(d.msg.eq_str("count is 7 for x"), "format() rendering");
    assert(d.start == 12 && d.len == 3, "span recorded verbatim");
    assert(d.severity == diag::SEV_ERROR && d.note_head == diag::NOTE_NONE, "record fields");
}

@test
fn line_col_and_carets() {
    let src = "ab\ncd\n  foo bar\n"; // "bar" on line 3
    let mut e = diag::Errors::new();
    let b = render_into(&mut e, src, "boom", offset_of(src, "bar"), 3, "");
    assert(contains(&b, "error: boom"), "message");
    assert(contains(&b, "--> 3:7"), "1-based line:col");
    assert(contains(&b, "3 | "), "gutter");
    assert(contains(&b, "  foo bar"), "offending source line");
    assert(contains(&b, "^^^"), "span == 3 carets");
    assert(!contains(&b, "^^^^"), "...and no more than 3");
}

@test
fn file_in_location() {
    let src = "ab\ncd\n  foo bar\n";
    let mut e = diag::Errors::new();
    let b = render_into(&mut e, src, "boom", offset_of(src, "bar"), 3, "src/foo.spc");
    assert(contains(&b, "--> src/foo.spc:3:7"), "file:line:col");
}

@test
fn notes() {
    let src = "let x = y;\n";
    let mut e = diag::Errors::new();
    e.emit(offset_of(src, "y"), 1, format("{}", "unknown name"));
    e.note(format("did you mean '{}'?", "x"));
    e.finalize(src, "");
    assert(e.errors.at(0).msg.eq_str("unknown name"), "record not rewritten by finalize");
    let b = e.rendered_errors.at(0).clone();
    assert(contains(&b, "error: unknown name"), "error line");
    assert(contains(&b, "= note: did you mean 'x'?"), "note line");
}

@test
fn caret_clamping() {
    let src = "ab\ncd\n  foo bar\n";
    let off = offset_of(src, "bar");
    let mut e0 = diag::Errors::new();
    let zero = render_into(&mut e0, src, "m", off, 0, ""); // span < 1 -> a single caret
    assert(contains(&zero, "^") && !contains(&zero, "^^"), "zero span -> one caret");

    // A span overrunning the line end is clamped to what remains ("bc" of "abc" -> 2 carets).
    let mut e1 = diag::Errors::new();
    let over = render_into(&mut e1, "abc\n", "m", 1, 100, "");
    assert(contains(&over, "^^") && !contains(&over, "^^^"), "overrun clamped");
}

@test
fn line_starts_crlf() {
    // '\r' alone, '\n' alone, and '\r\n' together each start a new line; 'd' is line 4 col 1.
    let src = "a\rb\nc\r\nd";
    let mut e = diag::Errors::new();
    let b = render_into(&mut e, src, "m", offset_of(src, "d"), 1, "");
    assert(contains(&b, "--> 4:1"), "mixed terminators");
}

@test
fn long_line_windowing() {
    let mut buf = Buf202 {};
    for i in 0..200 {
        unsafe buf.b[i] = 'x' as char;
    }
    buf.b[200] = '\n' as char;
    let mut e = diag::Errors::new();
    e.emit(180, 3, format("{}", "m"));
    e.finalize(str::from_raw((&buf.b[0]) as *const u8, 201), "");
    let b = e.rendered_errors.at(0).clone();
    assert(contains(&b, "--> 1:181"), "column past the window");
    assert(contains(&b, "^"), "a caret");
    // 150 x's in a row would mean no windowing; the 200-char line must be trimmed below that.
    let mut needle = Buf151 {};
    for k in 0..150 {
        unsafe needle.b[k] = 'x' as char;
    }
    assert(!contains(&b, str::from_raw((&needle.b[0]) as *const u8, 150)), "long line windowed below 150 chars");
}

@test
fn offset_past_eof() {
    let src = "abc\n";
    let mut e = diag::Errors::new();
    let b = render_into(&mut e, src, "eof", src.len() as u32 + 50, 1, ""); // clamped to src_len, no OOB
    assert(contains(&b, "error: eof"), "renders without overrun");
}
