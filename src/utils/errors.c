#define _POSIX_C_SOURCE 200809L

#include "errors.h"

#include <string.h>
#include <unistd.h>

COLD_EXPORT void errors_vemitf(
    String_Vec *errors, U32_Vec *errors_start, U32_Vec *errors_len, const uint32_t at, const uint32_t len,
    const char *fmt, va_list args) {
  va_list copy;
  va_copy(copy, args);
  const int msg_len = vsnprintf(NULL, 0, fmt, copy);
  va_end(copy);

  char *const result = malloc((size_t)msg_len + 1);
  if (result == NULL) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }
  vsnprintf(result, msg_len + 1, fmt, args);

  String_Vec_push(errors, result);
  U32_Vec_push(errors_start, at);
  U32_Vec_push(errors_len, len);
}

static bool at_or_before(const uint32_t line_start, void *const off) {
  return line_start <= *(const uint32_t *)off;
}

// One rendered diagnostic, e.g.
//   error: expected ')'
//    --> 3:8
//     |
//   3 |   foo(a b
//     |        ^
// The block is plain text (no color); colors are added at print time by
// errors_log so the stored message is presentation-agnostic. Returns a freshly
// malloc'd block; the caller frees the original message.
COLD char *render(
    const char *msg, const uint8_t *source, const U32_Vec *line_starts, const size_t src_len, uint32_t off,
    const uint32_t span, const char *file) {
  if (off > src_len)
    off = (uint32_t)src_len;
  const size_t li = U32_Vec_partition_point(line_starts, at_or_before, &off) - 1;
  const uint32_t lstart = line_starts->data[li];

  size_t lend = lstart; // first line terminator (or EOF) after the line start
  while (lend < src_len && source[lend] != '\n' && source[lend] != '\r')
    lend++;

  const size_t line_no = li + 1;
  const size_t real_col = off - lstart; // 0-based byte column within the line

  // Window long (e.g. minified) lines so the caret stays on screen.
  const size_t MAX_W = 120;
  size_t disp_start = lstart, disp_end = lend;
  if (lend - lstart > MAX_W) {
    disp_start = off > lstart + MAX_W / 2 ? off - MAX_W / 2 : lstart;
    disp_end = disp_start + MAX_W < lend ? disp_start + MAX_W : lend;
  }
  const int line_len = (int)(disp_end - disp_start);
  const char *const line_ptr = (const char *)source + disp_start;
  const size_t caret_col = off - disp_start; // caret indent within the shown text

  size_t carets = span < 1 ? 1 : span;
  if (off + carets > disp_end)
    carets = disp_end > off ? disp_end - off : 1;
  char *const bar = malloc(carets + 1);
  if (bar == NULL) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }
  memset(bar, '^', carets);
  bar[carets] = '\0';

  char numbuf[24];
  const int gw = snprintf(numbuf, sizeof numbuf, "%zu", line_no); // gutter width

  // The location line shows `--> file:L:C` when a path is known, else `--> L:C`.
  const char *const fpfx = (file && file[0]) ? file : "";
  const char *const fsep = (file && file[0]) ? ":" : "";

  // Single generously-sized buffer; snprintf truncates safely if over-estimated.
  const size_t cap = strlen(msg) + (size_t)line_len + real_col + carets + (size_t)gw * 4 + strlen(fpfx) + 128;
  char *const out = malloc(cap);
  if (out == NULL) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }

  snprintf(
      out, cap,
      "error: %s\n" // error: <message>
      "%*s--> %s%s%zu:%zu\n" //  --> file:L:C
      "%*s |\n" //    |
      "%*zu | %.*s\n" //  N | <source line>
      "%*s | %*s%s", //    |    ^^^
      msg, gw, "", fpfx, fsep, line_no, real_col + 1, gw, "", gw, line_no, line_len, line_ptr, gw, "", (int)caret_col, "",
      bar);

  free(bar);
  return out;
}

COLD_EXPORT void errors_finalize(
    String_Vec *errors, const U32_Vec *errors_start, const U32_Vec *errors_len, const uint8_t *source,
    const size_t len, const char *file) {
  if (errors->len == 0)
    return;

  // Show the path relative to the working directory when it sits underneath it (e.g.
  // `/abs/proj/examples/main.spc` -> `examples/main.spc`); otherwise leave it as given.
  char cwd[4096];
  if (file && file[0] == '/' && getcwd(cwd, sizeof cwd)) {
    const size_t cl = strlen(cwd);
    if (strncmp(file, cwd, cl) == 0 && file[cl] == '/')
      file += cl + 1;
  }

  // Build the line-start table once (only ever reached on the error path).
  U32_Vec line_starts = U32_Vec_init();
  U32_Vec_reserve(&line_starts, len / 16);
  U32_Vec_push(&line_starts, 0);
  for (size_t i = 0; i < len;) {
    const uint8_t b = source[i];
    if (b == '\n') {
      U32_Vec_push(&line_starts, (uint32_t)++i);
    } else if (b == '\r') {
      i++;
      if (i < len && source[i] == '\n')
        i++;
      U32_Vec_push(&line_starts, (uint32_t)i);
    } else {
      i++;
    }
  }

  for (size_t e = 0; e < errors->len; e++) {
    char *const block =
        render(errors->data[e], source, &line_starts, len, errors_start->data[e], errors_len->data[e], file);
    free(errors->data[e]);
    errors->data[e] = block;
  }

  VEC_DEINIT(line_starts);
}

#define C_RED "\x1b[1;31m"
#define C_BLUE "\x1b[1;34m"
#define C_RST "\x1b[0m"

// Print one rendered block to a terminal, colorizing by line structure: the
// `error` keyword red, the `-->` arrow and gutter blue, the caret run red. The
// rules key off the machine-generated layout, so source code (which may contain
// `|` or `^`) on the "N | ..." lines is never miscolored.
COLD void print_colored(FILE *out, const char *block) {
  for (const char *p = block; *p;) {
    const char *const eol = strchr(p, '\n');
    const size_t n = eol ? (size_t)(eol - p) : strlen(p);

    if (n >= 5 && memcmp(p, "error", 5) == 0) {
      fputs(C_RED "error" C_RST, out);
      fwrite(p + 5, 1, n - 5, out);
    } else {
      // gutter: the first '|' whose prefix is only spaces/digits (line number).
      size_t bar = n;
      bool has_digit = false, gutter = true;
      for (size_t i = 0; i < n; i++) {
        if (p[i] == '|') {
          bar = i;
          break;
        }
        if (p[i] == ' ')
          continue;
        if (p[i] >= '0' && p[i] <= '9') {
          has_digit = true;
          continue;
        }
        gutter = false;
        break;
      }
      // location line: leading spaces then "-->".
      const char *arrow = NULL;
      for (size_t i = 0; i + 2 < n; i++) {
        if (p[i] != ' ') {
          if (p[i] == '-' && p[i + 1] == '-' && p[i + 2] == '>')
            arrow = p + i;
          break;
        }
      }
      if (arrow) {
        fwrite(p, 1, (size_t)(arrow - p), out);
        fputs(C_BLUE "-->" C_RST, out);
        fwrite(arrow + 3, 1, n - (size_t)(arrow + 3 - p), out);
      } else if (gutter && bar < n) {
        fputs(C_BLUE, out);
        fwrite(p, 1, bar + 1, out); // line number + gutter pipe
        fputs(C_RST, out);
        const char *const rest = p + bar + 1;
        const size_t rn = n - bar - 1;
        if (has_digit) {
          fwrite(rest, 1, rn, out); // source line — leave code untouched
        } else {
          for (size_t i = 0; i < rn;) { // caret line — color the '^' runs red
            if (rest[i] == '^') {
              size_t j = i;
              while (j < rn && rest[j] == '^')
                j++;
              fputs(C_RED, out);
              fwrite(rest + i, 1, j - i, out);
              fputs(C_RST, out);
              i = j;
            } else {
              fputc(rest[i], out);
              i++;
            }
          }
        }
      } else {
        fwrite(p, 1, n, out);
      }
    }

    fputc('\n', out);
    if (!eol)
      break;
    p = eol + 1;
  }
}

COLD_EXPORT void errors_log(const String_Vec *errors) {
  const bool color = isatty(STDERR_FILENO);
  for (size_t i = 0; i < errors->len; i++) {
    if (color)
      print_colored(stderr, errors->data[i]);
    else
      fprintf(stderr, "%s\n", errors->data[i]);
  }
}
