// Direct coverage of utils/errors.c: errors_vemitf (message + span collection), errors_finalize
// (the `render` block: 1-based line:col, caret count/clamping, line-start table across \n/\r/\r\n,
// long-line windowing) and errors_log (the static `print_colored`, reached via a pty so isatty()
// is true). render/print_colored are file-static, so they are exercised through the public API.

#include "test_harness.h"

#include <termios.h>
#include <unistd.h>
#if defined(__APPLE__)
#  include <util.h>
#else
#  include <pty.h>
#endif

static void emitf(String_Vec *e, U32_Vec *s, U32_Vec *l, const uint32_t at, const uint32_t len, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  errors_vemitf(e, s, l, at, len, fmt, ap);
  va_end(ap);
}

// Build, finalize and return the rendered diagnostics vector (caller: free_errors).
static String_Vec make_blocks(const char *src, const char *msg, const uint32_t off, const uint32_t span) {
  String_Vec e = String_Vec_init();
  U32_Vec s = U32_Vec_init(), l = U32_Vec_init();
  emitf(&e, &s, &l, off, span, "%s", msg);
  errors_finalize(&e, &s, &l, (const uint8_t *)src, strlen(src), NULL);
  VEC_DEINIT(s);
  VEC_DEINIT(l);
  return e;
}

// One rendered block as a fresh string (caller frees).
static char *render_one(const char *src, const char *msg, const uint32_t off, const uint32_t span) {
  String_Vec e = make_blocks(src, msg, off, span);
  char *out = strdup(e.data[0]);
  free_errors(&e);
  return out;
}

static uint32_t offset_of(const char *src, const char *needle) {
  const char *p = strstr(src, needle);
  return p ? (uint32_t)(p - src) : 0;
}

static void test_emit_collects(void) {
  String_Vec e = String_Vec_init();
  U32_Vec s = U32_Vec_init(), l = U32_Vec_init();
  emitf(&e, &s, &l, 12, 3, "count is %d for %s", 7, "x");
  CHECK(e.len == 1 && s.len == 1 && l.len == 1, "one message + span recorded");
  CHECK_STR_EQ(e.data[0], "count is 7 for x"); // varargs formatting
  CHECK(s.data[0] == 12 && l.data[0] == 3, "span recorded verbatim");
  free_errors(&e);
  VEC_DEINIT(s);
  VEC_DEINIT(l);
}

static void test_line_col_and_carets(void) {
  static const char src[] = "ab\ncd\n  foo bar\n"; // "bar" on line 3
  const uint32_t off = offset_of(src, "bar");
  char *b = render_one(src, "boom", off, 3);
  CHECK_STR_CONTAINS(b, "error: boom");
  CHECK_STR_CONTAINS(b, "--> 3:7"); // 1-based line:col
  CHECK_STR_CONTAINS(b, "3 | ");
  CHECK_STR_CONTAINS(b, "  foo bar"); // the offending source line
  CHECK_STR_CONTAINS(b, "^^^"); // span == 3 carets
  CHECK_STR_ABSENT(b, "^^^^"); // ...and no more than 3
  free(b);
}

// The location line gains a `file:` prefix when a path is supplied; a relative path is shown verbatim.
static void test_file_in_location(void) {
  static const char src[] = "ab\ncd\n  foo bar\n";
  const uint32_t off = offset_of(src, "bar");
  String_Vec e = String_Vec_init();
  U32_Vec s = U32_Vec_init(), l = U32_Vec_init();
  emitf(&e, &s, &l, off, 3, "%s", "boom");
  errors_finalize(&e, &s, &l, (const uint8_t *)src, strlen(src), "src/foo.spc");
  CHECK_STR_CONTAINS(e.data[0], "--> src/foo.spc:3:7"); // file:line:col
  free_errors(&e);
  VEC_DEINIT(s);
  VEC_DEINIT(l);
}

static void test_caret_clamping(void) {
  static const char src[] = "ab\ncd\n  foo bar\n";
  const uint32_t off = offset_of(src, "bar");

  char *zero = render_one(src, "m", off, 0); // span < 1 -> a single caret
  CHECK_STR_CONTAINS(zero, "^");
  CHECK_STR_ABSENT(zero, "^^");
  free(zero);

  // span that overruns the line end is clamped to what remains ("b" of "bar" -> 2 carets max here)
  static const char tiny[] = "abc\n";
  char *over = render_one(tiny, "m", 1, 100);
  CHECK_STR_CONTAINS(over, "^^");
  CHECK_STR_ABSENT(over, "^^^");
  free(over);
}

static void test_line_starts_crlf(void) {
  // '\r' alone, '\n' alone, and '\r\n' together each start a new line.
  static const char src[] = "a\rb\nc\r\nd";
  char *b = render_one(src, "m", offset_of(src, "d"), 1);
  CHECK_STR_CONTAINS(b, "--> 4:1"); // 'd' is line 4 col 1 across the mixed terminators
  free(b);
}

static void test_long_line_windowing(void) {
  char *src = malloc(202);
  memset(src, 'x', 200);
  src[200] = '\n';
  src[201] = '\0';
  char *b = render_one(src, "m", 180, 3);
  CHECK_STR_CONTAINS(b, "--> 1:181");
  CHECK_STR_CONTAINS(b, "^");
  char needle[151];
  memset(needle, 'x', 150);
  needle[150] = '\0';
  CHECK_STR_ABSENT(b, needle); // the 200-char line was windowed below 150 shown chars
  free(b);
  free(src);
}

static void test_offset_past_eof(void) {
  static const char src[] = "abc\n";
  char *b = render_one(src, "eof", (uint32_t)strlen(src) + 50, 1); // off clamped to src_len, no OOB
  CHECK_STR_CONTAINS(b, "error: eof");
  free(b);
}

// Redirect fd 2 to a regular file, run errors_log (isatty false -> plain), read it back.
static void capture_plain(const String_Vec *errs, char *out, const size_t cap) {
  fflush(stderr);
  const int save = dup(STDERR_FILENO);
  char tmpl[] = "/tmp/scerrXXXXXX";
  const int fd = mkstemp(tmpl);
  dup2(fd, STDERR_FILENO);
  errors_log(errs);
  fflush(stderr);
  dup2(save, STDERR_FILENO);
  close(save);
  lseek(fd, 0, SEEK_SET);
  const ssize_t n = read(fd, out, cap - 1);
  out[n > 0 ? n : 0] = '\0';
  close(fd);
  unlink(tmpl);
}

// Point fd 2 at a pty slave (isatty true -> colored), run errors_log, read the master end.
static void capture_color(const String_Vec *errs, char *out, const size_t cap) {
  out[0] = '\0';
  int m = -1, s = -1;
  if (openpty(&m, &s, NULL, NULL, NULL) != 0)
    return;
  struct termios t;
  tcgetattr(s, &t);
  cfmakeraw(&t); // disable \n -> \r\n translation
  tcsetattr(s, TCSANOW, &t);

  fflush(stderr);
  const int save = dup(STDERR_FILENO);
  dup2(s, STDERR_FILENO);
  errors_log(errs);
  fflush(stderr);
  dup2(save, STDERR_FILENO);
  close(save);
  close(s); // close the slave so the master read sees EOF after the data

  const ssize_t n = read(m, out, cap - 1);
  out[n > 0 ? n : 0] = '\0';
  close(m);
}

static void test_log_plain(void) {
  static const char src[] = "ab\ncd\n  foo bar\n";
  String_Vec e = make_blocks(src, "plainmsg", offset_of(src, "bar"), 3);
  char out[2048];
  capture_plain(&e, out, sizeof out);
  CHECK_STR_CONTAINS(out, "plainmsg");
  CHECK_STR_CONTAINS(out, "--> 3:7");
  CHECK_STR_ABSENT(out, "\x1b["); // no ANSI when stderr is not a tty
  free_errors(&e);
}

static void test_log_color(void) {
  static const char src[] = "ab\ncd\n  foo bar\n";
  String_Vec e = make_blocks(src, "colormsg", offset_of(src, "bar"), 3);
  char out[2048];
  capture_color(&e, out, sizeof out);
  if (out[0] == '\0') {
    CHECK(true, "openpty unavailable: color path skipped");
  } else {
    CHECK_STR_CONTAINS(out, "colormsg");
    CHECK_STR_CONTAINS(out, "\x1b[1;31m"); // red wraps `error` and the caret run
    CHECK_STR_CONTAINS(out, "\x1b[1;34m"); // blue wraps `-->` and the gutter
    CHECK_STR_CONTAINS(out, "\x1b[0m"); // reset
  }
  free_errors(&e);
}

int main(void) {
  test_emit_collects();
  test_line_col_and_carets();
  test_file_in_location();
  test_caret_clamping();
  test_line_starts_crlf();
  test_long_line_windowing();
  test_offset_past_eof();
  test_log_plain();
  test_log_color();
  if (failures) {
    fprintf(stderr, "%d errors test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("errors tests passed");
  return 0;
}
