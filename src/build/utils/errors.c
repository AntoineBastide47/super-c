#include "../utils/errors.h"
#include "../stdlib.h"
#include "../string.h"
#include "../__std/core.h"
#include "../__std/interfaces.h"
#include "../__std/option.h"
#include "../__std/range.h"
#include "../__std/result.h"
#include "../__std/slice.h"
#include "../__std/str.h"
#include "../__std/string.h"
#include "../__std/vector.h"

_Static_assert(sizeof(utils__errors__Errors) == 96 && _Alignof(utils__errors__Errors) == 8, "super-c layout model mismatch: utils__errors__Errors");

static __attribute__((unused)) size_t utils__errors__line_index(const Vector__u32__Global *const line_starts, uint32_t const off);
static __attribute__((cold, noinline, unused)) String__Global utils__errors__render(const String__Global *const msg, const uint8_t *const source, const Vector__u32__Global *const line_starts, size_t const src_len, uint32_t off, uint32_t const span, const char *const file, const String__Global *const notes);

void utils__errors__oom(void) {
  ({ String__Global __sc0 = String__Global__new();
String__Global__push_str(&__sc0, (str){ .ptr = (const uint8_t*)"fatal: out of memory\n", .len = sizeof("fatal: out of memory\n") - 1 });
String__Global__eprint(&__sc0); String__Global__free(&__sc0); });
  abort();
}

str utils__errors__cstr(const char *const p) {
  return str__from_raw(((const uint8_t *)p), strlen(p));
}

str utils__errors__span_str(const uint8_t *const src, uint32_t const start, uint32_t const end) {
  return str__from_raw((src + ((size_t)start)), ((size_t)(end - start)));
}

utils__errors__Errors utils__errors__Errors__new(void) {
  return (utils__errors__Errors){ .errors = Vector__String__Global__Global__new(), .notes = Vector__String__Global__Global__new(), .starts = Vector__u32__Global__new(), .lens = Vector__u32__Global__new() };
}

bool utils__errors__Errors__has_errors(const utils__errors__Errors *const self) {
  return (Vector__String__Global__Global__len(&self->errors) != 0ULL);
}

__attribute__((cold, noinline)) void utils__errors__Errors__emit(utils__errors__Errors *const self, uint32_t const at, uint32_t const len, String__Global msg) {
  if (Vector__String__Global__Global__len(&self->errors) >= utils__errors__ERRORS_MAX) {
    return;
  }
  Vector__String__Global__Global__push(&self->errors, msg);
  Vector__String__Global__Global__push(&self->notes, String__Global__new());
  Vector__u32__Global__push(&self->starts, at);
  Vector__u32__Global__push(&self->lens, len);
}

__attribute__((cold, noinline)) void utils__errors__Errors__note(utils__errors__Errors *const self, String__Global msg) {
  const size_t n = Vector__String__Global__Global__len(&self->errors);
  if ((n == 0ULL) || (Vector__String__Global__Global__len(&self->notes) < n)) {
    {
      String__Global__free(&msg);
      return;
    }
  }
  String__Global__push_str(&(*({ __auto_type __sc1 = &self->notes; Vector__String__Global__Global__index_mut(__sc1, (n - 1ULL)); })), (str){ (const uint8_t *)"\n  = note: ", sizeof("\n  = note: ") - 1 });
  String__Global__push_string(&(*({ __auto_type __sc2 = &self->notes; Vector__String__Global__Global__index_mut(__sc2, (n - 1ULL)); })), (&msg));
  String__Global__free(&msg);
}

__attribute__((cold, noinline)) void utils__errors__Errors__finalize(utils__errors__Errors *const self, const uint8_t *const source, size_t const len, const char *const file) {
  if (Vector__String__Global__Global__len(&self->errors) == 0ULL) {
    return;
  }
  Vector__u32__Global line_starts = Vector__u32__Global__new();
  Vector__u32__Global__reserve(&line_starts, ({ size_t __sc3 = len; size_t __sc4 = 16ULL; if (__sc4 == 0) { __sc_panic("divide by zero"); } (__sc3 / __sc4); }));
  Vector__u32__Global__push(&line_starts, 0U);
  size_t i = 0ULL;
  while (i < len) {
    const uint8_t b = source[i];
    if (b == (uint8_t)'\n') {
      (i = (i + 1ULL));
      Vector__u32__Global__push(&line_starts, ((uint32_t)i));
    } else if (b == (uint8_t)'\r') {
      (i = (i + 1ULL));
      if ((i < len) && (source[i] == (uint8_t)'\n')) {
        (i = (i + 1ULL));
      }
      Vector__u32__Global__push(&line_starts, ((uint32_t)i));
    } else {
      (i = (i + 1ULL));
    }
  }
  for (size_t k = 0ULL; k < Vector__String__Global__Global__len(&self->errors); k++) {
    String__Global block = utils__errors__render(Vector__String__Global__Global__at(&self->errors, k), source, (&line_starts), len, (*({ __auto_type __sc5 = &self->starts; Vector__u32__Global__index(__sc5, k); })), (*({ __auto_type __sc6 = &self->lens; Vector__u32__Global__index(__sc6, k); })), file, Vector__String__Global__Global__at(&self->notes, k));
    bool __mv486 = false;
    Vector__String__Global__Global__set(&self->errors, k, (__mv486 = true, block));
    if (!__mv486) String__Global__free(&block);
  }
  Vector__String__Global__Global uniq = Vector__String__Global__Global__new();
  for (size_t k = 0ULL; k < Vector__String__Global__Global__len(&self->errors); k++) {
    bool seen = false;
    for (size_t j = 0ULL; j < Vector__String__Global__Global__len(&uniq); j++) {
      if (String__Global__equals(&(*({ __auto_type __sc7 = &uniq; Vector__String__Global__Global__index(__sc7, j); })), Vector__String__Global__Global__at(&self->errors, k))) {
        (seen = true);
      }
    }
    if (!seen) {
      Vector__String__Global__Global__push(&uniq, String__Global__clone(&(*({ __auto_type __sc8 = &self->errors; Vector__String__Global__Global__index(__sc8, k); }))));
    }
  }
  Vector__String__Global__Global__free(&self->errors);
  (self->errors = uniq);
  Vector__u32__Global__free(&line_starts);
}

__attribute__((cold, noinline)) void utils__errors__Errors__log(const utils__errors__Errors *const self) {
  for (size_t i = 0ULL; i < Vector__String__Global__Global__len(&self->errors); i++) {
    String__Global__eprintln(&(*({ __auto_type __sc9 = &self->errors; Vector__String__Global__Global__index(__sc9, i); })));
  }
}

void utils__errors__Errors__free(utils__errors__Errors *const self) {
  Vector__String__Global__Global__free(&self->errors);
  Vector__String__Global__Global__free(&self->notes);
  Vector__u32__Global__free(&self->starts);
  Vector__u32__Global__free(&self->lens);
}

static __attribute__((unused)) size_t utils__errors__line_index(const Vector__u32__Global *const line_starts, uint32_t const off) {
  size_t lo = 0ULL;
  size_t hi = Vector__u32__Global__len(line_starts);
  while (lo < hi) {
    const size_t mid = (lo + ({ size_t __sc10 = (hi - lo); size_t __sc11 = 2ULL; if (__sc11 == 0) { __sc_panic("divide by zero"); } (__sc10 / __sc11); }));
    if ((*({ __auto_type __sc12 = line_starts; Vector__u32__Global__index(__sc12, mid); })) <= off) {
      (lo = (mid + 1ULL));
    } else {
      (hi = mid);
    }
  }
  if (lo == 0ULL) {
    return 0ULL;
  }
  return (lo - 1ULL);
}

static __attribute__((cold, noinline, unused)) String__Global utils__errors__render(const String__Global *const msg, const uint8_t *const source, const Vector__u32__Global *const line_starts, size_t const src_len, uint32_t off, uint32_t const span, const char *const file, const String__Global *const notes) {
  if (((size_t)off) > src_len) {
    (off = ((uint32_t)src_len));
  }
  const size_t li = utils__errors__line_index((&(*line_starts)), off);
  const uint32_t lstart = (*({ __auto_type __sc13 = line_starts; Vector__u32__Global__index(__sc13, li); }));
  size_t lend = ((size_t)lstart);
  while (((lend < src_len) && (source[lend] != 10U)) && (source[lend] != 13U)) {
    (lend = (lend + 1ULL));
  }
  const size_t line_no = (li + 1ULL);
  const size_t real_col = ((size_t)(off - lstart));
  size_t const max_w = 120ULL;
  size_t disp_start = ((size_t)lstart);
  size_t disp_end = lend;
  if ((lend - ((size_t)lstart)) > max_w) {
    if (((size_t)off) > (((size_t)lstart) + ({ size_t __sc14 = max_w; size_t __sc15 = 2ULL; if (__sc15 == 0) { __sc_panic("divide by zero"); } (__sc14 / __sc15); }))) {
      (disp_start = (((size_t)off) - ({ size_t __sc16 = max_w; size_t __sc17 = 2ULL; if (__sc17 == 0) { __sc_panic("divide by zero"); } (__sc16 / __sc17); })));
    }
    if ((disp_start + max_w) < lend) {
      (disp_end = (disp_start + max_w));
    } else {
      (disp_end = lend);
    }
  }
  const size_t line_len = (disp_end - disp_start);
  const uint8_t *const line_ptr = (source + disp_start);
  const size_t caret_col = (((size_t)off) - disp_start);
  size_t carets = 1ULL;
  if (span >= 1U) {
    (carets = ((size_t)span));
  }
  if ((((size_t)off) + carets) > disp_end) {
    if (disp_end > ((size_t)off)) {
      (carets = (disp_end - ((size_t)off)));
    } else {
      (carets = 1ULL);
    }
  }
  String__Global out = String__Global__new();
  String__Global__push_str(&out, (str){ (const uint8_t *)"error: ", sizeof("error: ") - 1 });
  String__Global__push_string(&out, msg);
  String__Global__push_str(&out, (str){ (const uint8_t *)"\n--> ", sizeof("\n--> ") - 1 });
  if ((file != NULL) && (file[0] != 0)) {
    String__Global__push_bytes(&out, ((const uint8_t *)file), strlen(file));
    String__Global__push_byte(&out, 58U);
  }
  String__Global__push_u64(&out, ((uint64_t)line_no));
  String__Global__push_byte(&out, 58U);
  String__Global__push_u64(&out, ((uint64_t)(real_col + 1ULL)));
  String__Global__push_str(&out, (str){ (const uint8_t *)"\n |\n", sizeof("\n |\n") - 1 });
  String__Global__push_u64(&out, ((uint64_t)line_no));
  String__Global__push_str(&out, (str){ (const uint8_t *)" | ", sizeof(" | ") - 1 });
  String__Global__push_bytes(&out, line_ptr, line_len);
  String__Global__push_str(&out, (str){ (const uint8_t *)"\n | ", sizeof("\n | ") - 1 });
  for (size_t _ = 0ULL; _ < caret_col; _++) {
    String__Global__push_byte(&out, 32U);
  }
  for (size_t _ = 0ULL; _ < carets; _++) {
    String__Global__push_byte(&out, 94U);
  }
  String__Global__push_string(&out, notes);
  return out;
}

