// Self-hosted port of tests/errors_test.c: direct coverage of utils::errors -- emitf (message + span
// collection with varargs formatting), finalize (1-based line:col, caret count/clamping, \r/\n/\r\n line
// starts, long-line windowing, file prefix, notes, offset-past-EOF). The two log-capture cases (plain vs
// pty-colored stderr) test terminal I/O plumbing, not rendering logic, and are covered by the C suite.
import utils::errors as diag;
import string as cstring;

// Array-field wrappers: `{}` init zero-fills the omitted array (Super-C has no `[v; N]` repeat literal).
struct Buf202 { pub b: [char; 202] }
struct Buf151 { pub b: [char; 151] }

fn contains(hay: *const char, needle: str) bool {
    return unsafe cstring::strstr(hay, needle.ptr as *const char) != null;
}
fn streq(a: *const char, b: str) bool {
    return unsafe cstring::strcmp(a, b.ptr as *const char) == 0;
}
fn offset_of(src: str, needle: str) u32 {
    let p = unsafe cstring::strstr(src.ptr as *const char, needle.ptr as *const char);
    if p == null { return 0; }
    return ((p as usize) - (src.ptr as usize)) as u32;
}

// Emit one message at (off, span) over `src`, finalize with `file`, and hand back the rendered block 0.
// The Errors value is returned so the caller can free it after inspecting the (borrowed) block pointer.
fn render_into(e: &mut diag::Errors, src: str, msg: str, off: u32, span: u32, file: *const char) *const char {
    e.emitf(off, span, "%s".ptr as *const char, msg.ptr as *const char);
    e.finalize(src.ptr as *const u8, src.len, file);
    return (*e.errors.at(0)) as *const char;
}

@test
fn emit_collects() {
    let mut e = diag::Errors::new();
    e.emitf(12, 3, "count is %d for %s".ptr as *const char, 7, "x".ptr as *const char);
    assert(e.errors.len() == 1 && e.starts.len() == 1 && e.lens.len() == 1, "one message + span recorded");
    assert(streq((*e.errors.at(0)) as *const char, "count is 7 for x"), "varargs formatting"); // pre-finalize
    assert(*e.starts.at(0) == 12 && *e.lens.at(0) == 3, "span recorded verbatim");
    e.free();
}

@test
fn line_col_and_carets() {
    let src = "ab\ncd\n  foo bar\n"; // "bar" on line 3
    let mut e = diag::Errors::new();
    let b = render_into(&mut e, src, "boom", offset_of(src, "bar"), 3, null);
    assert(contains(b, "error: boom"), "message");
    assert(contains(b, "--> 3:7"), "1-based line:col");
    assert(contains(b, "3 | "), "gutter");
    assert(contains(b, "  foo bar"), "offending source line");
    assert(contains(b, "^^^"), "span == 3 carets");
    assert(!contains(b, "^^^^"), "...and no more than 3");
    e.free();
}

@test
fn file_in_location() {
    let src = "ab\ncd\n  foo bar\n";
    let mut e = diag::Errors::new();
    let b = render_into(&mut e, src, "boom", offset_of(src, "bar"), 3, "src/foo.spc".ptr as *const char);
    assert(contains(b, "--> src/foo.spc:3:7"), "file:line:col");
    e.free();
}

@test
fn notes() {
    let src = "let x = y;\n";
    let mut e = diag::Errors::new();
    e.emitf(offset_of(src, "y"), 1, "%s".ptr as *const char, "unknown name".ptr as *const char);
    e.notef("did you mean '%s'?".ptr as *const char, "x".ptr as *const char);
    e.finalize(src.ptr as *const u8, src.len, null);
    let b = (*e.errors.at(0)) as *const char;
    assert(contains(b, "error: unknown name"), "error line");
    assert(contains(b, "= note: did you mean 'x'?"), "note line");
    e.free();
}

@test
fn caret_clamping() {
    let src = "ab\ncd\n  foo bar\n";
    let off = offset_of(src, "bar");
    let mut e0 = diag::Errors::new();
    let zero = render_into(&mut e0, src, "m", off, 0, null); // span < 1 -> a single caret
    assert(contains(zero, "^") && !contains(zero, "^^"), "zero span -> one caret");
    e0.free();
    // A span overrunning the line end is clamped to what remains ("bc" of "abc" -> 2 carets).
    let mut e1 = diag::Errors::new();
    let over = render_into(&mut e1, "abc\n", "m", 1, 100, null);
    assert(contains(over, "^^") && !contains(over, "^^^"), "overrun clamped");
    e1.free();
}

@test
fn line_starts_crlf() {
    // '\r' alone, '\n' alone, and '\r\n' together each start a new line; 'd' is line 4 col 1.
    let src = "a\rb\nc\r\nd";
    let mut e = diag::Errors::new();
    let b = render_into(&mut e, src, "m", offset_of(src, "d"), 1, null);
    assert(contains(b, "--> 4:1"), "mixed terminators");
    e.free();
}

@test
fn long_line_windowing() {
    let mut buf = Buf202 {};
    let mut i: usize = 0;
    while i < 200 { buf.b[i] = 'x' as char; i = i + 1; }
    buf.b[200] = '\n' as char;
    let mut e = diag::Errors::new();
    e.emitf(180, 3, "%s".ptr as *const char, "m".ptr as *const char);
    e.finalize((&buf.b[0]) as *const u8, 201, null);
    let b = (*e.errors.at(0)) as *const char;
    assert(contains(b, "--> 1:181"), "column past the window");
    assert(contains(b, "^"), "a caret");
    // 150 x's in a row would mean no windowing; the 200-char line must be trimmed below that.
    let mut needle = Buf151 {};
    let mut k: usize = 0;
    while k < 150 { needle.b[k] = 'x' as char; k = k + 1; }
    assert(unsafe cstring::strstr(b, (&needle.b[0]) as *const char) == null, "long line windowed below 150 chars");
    e.free();
}

@test
fn offset_past_eof() {
    let src = "abc\n";
    let mut e = diag::Errors::new();
    let b = render_into(&mut e, src, "eof", (src.len as u32) + 50, 1, null); // clamped to src_len, no OOB
    assert(contains(b, "error: eof"), "renders without overrun");
    e.free();
}
