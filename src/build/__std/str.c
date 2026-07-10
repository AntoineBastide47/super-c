#include "../__std/str.h"
#include "../__std/core.h"
#include "../__std/interfaces.h"
#include "../__std/option.h"
#include "../__std/range.h"
#include "../__std/slice.h"
#include "../__std/string.h"

_Static_assert(sizeof(str) == 16 && _Alignof(str) == 8, "super-c layout model mismatch: str");
_Static_assert(sizeof(Bytes) == 24 && _Alignof(Bytes) == 8, "super-c layout model mismatch: Bytes");
_Static_assert(sizeof(Chars) == 24 && _Alignof(Chars) == 8, "super-c layout model mismatch: Chars");
_Static_assert(sizeof(Split) == 40 && _Alignof(Split) == 8, "super-c layout model mismatch: Split");
_Static_assert(sizeof(Lines) == 24 && _Alignof(Lines) == 8, "super-c layout model mismatch: Lines");

static __attribute__((unused)) Option__u64 __str_digits_u64(const str *const s, uint32_t const radix, size_t const start);

str str__from_raw(const uint8_t *const ptr, size_t const len) {
  return (str){ .ptr = ptr, .len = len };
}

str str__from_cstr(const char *const s) {
  size_t n = 0ULL;
  while (s[n] != 0) {
    (n += 1ULL);
  }
  return str__from_raw(((const uint8_t *)s), n);
}

size_t str__len(const str *const self) {
  return self->len;
}

bool str__is_empty(const str *const self) {
  return (self->len == 0ULL);
}

const uint8_t *str__ptr(const str *const self) {
  return self->ptr;
}

uint8_t str__byte_at(const str *const self, size_t const index) {
  return self->ptr[index];
}

str str__slice(const str *const self, size_t const start, size_t const end) {
  return (str){ .ptr = (self->ptr + start), .len = (end - start) };
}

bool str__starts_with(const str *const self, str const prefix) {
  if (prefix.len > self->len) {
    return false;
  }
  if (prefix.len == 0ULL) {
    return true;
  }
  return (memcmp(((const void *)self->ptr), ((const void *)prefix.ptr), prefix.len) == 0);
}

bool str__ends_with(const str *const self, str const suffix) {
  if (suffix.len > self->len) {
    return false;
  }
  if (suffix.len == 0ULL) {
    return true;
  }
  return (memcmp(((const void *)(self->ptr + (self->len - suffix.len))), ((const void *)suffix.ptr), suffix.len) == 0);
}

intptr_t str__find_byte(const str *const self, uint8_t const byte) {
  for (size_t i = 0ULL; i < self->len; i++) {
    if (self->ptr[i] == byte) {
      return ((intptr_t)i);
    }
  }
  return -1;
}

intptr_t str__find(const str *const self, str const needle) {
  if (needle.len == 0ULL) {
    return 0LL;
  }
  if (needle.len > self->len) {
    return -1;
  }
  const size_t last = (self->len - needle.len);
  for (size_t i = 0ULL; i <= last; i++) {
    if (memcmp(((const void *)(self->ptr + i)), ((const void *)needle.ptr), needle.len) == 0) {
      return ((intptr_t)i);
    }
  }
  return -1;
}

bool str__contains(const str *const self, str const needle) {
  return (str__find(self, needle) >= 0LL);
}

str str__trim_start(const str *const self) {
  size_t start = 0ULL;
  while (start < self->len) {
    const uint8_t b = self->ptr[start];
    if ((((b != 32U) && (b != 9U)) && (b != 10U)) && (b != 13U)) {
      break;
    }
    (start = (start + 1ULL));
  }
  return (str){ .ptr = (self->ptr + start), .len = (self->len - start) };
}

str str__trim_end(const str *const self) {
  size_t end = self->len;
  while (end > 0ULL) {
    const uint8_t b = self->ptr[(end - 1ULL)];
    if ((((b != 32U) && (b != 9U)) && (b != 10U)) && (b != 13U)) {
      break;
    }
    (end = (end - 1ULL));
  }
  return (str){ .ptr = self->ptr, .len = end };
}

str str__trim(const str *const self) {
  const str t = str__trim_start(self);
  return str__trim_end(&t);
}

size_t str__char_count(const str *const self) {
  size_t count = 0ULL;
  for (size_t i = 0ULL; i < self->len; i++) {
    if ((self->ptr[i] & 0xC0U) != 0x80U) {
      (count = (count + 1ULL));
    }
  }
  return count;
}

bool str__is_valid_utf8(const str *const self) {
  size_t i = 0ULL;
  while (i < self->len) {
    const uint8_t b = self->ptr[i];
    size_t n = 0ULL;
    if (b < 0x80U) {
      (n = 1ULL);
    } else if ((b & 0xE0U) == 0xC0U) {
      (n = 2ULL);
    } else if ((b & 0xF0U) == 0xE0U) {
      (n = 3ULL);
    } else if ((b & 0xF8U) == 0xF0U) {
      (n = 4ULL);
    } else {
      return false;
    }
    if ((i + n) > self->len) {
      return false;
    }
    for (size_t k = 1ULL; k < n; k++) {
      if ((self->ptr[(i + k)] & 0xC0U) != 0x80U) {
        return false;
      }
    }
    (i = (i + n));
  }
  return true;
}

String__Global str__to_string(const str *const self) {
  String__Global out = String__Global__with_capacity(self->len);
  String__Global__push_bytes(&out, self->ptr, self->len);
  return out;
}

bool str__eq(const str *const self, const str *const other) {
  if (self->len != other->len) {
    return false;
  }
  if (self->len == 0ULL) {
    return true;
  }
  return (memcmp(((const void *)self->ptr), ((const void *)other->ptr), self->len) == 0);
}

int32_t str__cmp(const str *const self, const str *const other) {
  size_t n = self->len;
  if (other->len < n) {
    (n = other->len);
  }
  if (n > 0ULL) {
    const int32_t c = memcmp(((const void *)self->ptr), ((const void *)other->ptr), n);
    if (c != 0) {
      return c;
    }
  }
  if (self->len < other->len) {
    return -1;
  }
  if (self->len > other->len) {
    return 1;
  }
  return 0;
}

uint64_t str__hash(const str *const self) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < self->len; i++) {
    (h = ((h ^ ((uint64_t)self->ptr[i])) * 0x100000001b3ULL));
  }
  return h;
}

str str__default_(void) {
  return (str){ .ptr = NULL, .len = 0ULL };
}

const uint8_t *str__index(const str *const self, size_t const i) {
  return (&self->ptr[i]);
}

str str__index_range(const str *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc0;
    if (r.inclusive) {
      __sc0 = (r.end + 1ULL);
    } else {
      __sc0 = r.end;
    }
    __sc0;
  });
  return str__slice(self, r.start, hi);
}

Bytes str__bytes(const str *const self) {
  return (Bytes){ .s = str__slice(self, 0ULL, self->len), .i = 0ULL };
}

Chars str__chars(const str *const self) {
  return (Chars){ .s = str__slice(self, 0ULL, self->len), .i = 0ULL };
}

Split str__split(const str *const self, str const sep) {
  return (Split){ .s = str__slice(self, 0ULL, self->len), .i = 0ULL, .sep = sep };
}

Lines str__lines(const str *const self) {
  return (Lines){ .s = str__slice(self, 0ULL, self->len), .i = 0ULL };
}

Option__u64 str__parse_u64_radix(const str *const self, uint32_t const radix) {
  size_t start = 0ULL;
  if ((self->len > 0ULL) && (str__byte_at(self, 0ULL) == (uint8_t)'+')) {
    (start = 1ULL);
  }
  return __str_digits_u64(self, radix, start);
}

Option__i64 str__parse_i64_radix(const str *const self, uint32_t const radix) {
  if (self->len == 0ULL) {
    return (Option__i64){ .tag = Option_None };
  }
  const uint8_t b0 = str__byte_at(self, 0ULL);
  const bool neg = (b0 == (uint8_t)'-');
  size_t start = 0ULL;
  if (neg || (b0 == (uint8_t)'+')) {
    (start = 1ULL);
  }
  {
    const Option__u64 __sc1 = __str_digits_u64(self, radix, start);
    if (__sc1.tag == Option_Some) {
      const uint64_t v = __sc1.payload.Some._0;
      return ({
        Option__i64 __sc2;
        const bool __sc3 = neg;
        if (__sc3 == true) {
          __sc2 = ({
            Option__i64 __sc4;
            const bool __sc5 = (v <= 0x8000000000000000ULL);
            if (__sc5 == true) {
              __sc4 = (Option__i64){ .tag = Option_Some, .payload.Some = { ((int64_t)(0ULL - v)) } };
            }
            else if (__sc5 == false) {
              __sc4 = (Option__i64){ .tag = Option_None };
            }
            else { __builtin_unreachable(); }
            __sc4;
          });
        }
        else if (__sc3 == false) {
          __sc2 = ({
            Option__i64 __sc6;
            const bool __sc7 = (v <= 0x7FFFFFFFFFFFFFFFULL);
            if (__sc7 == true) {
              __sc6 = (Option__i64){ .tag = Option_Some, .payload.Some = { ((int64_t)v) } };
            }
            else if (__sc7 == false) {
              __sc6 = (Option__i64){ .tag = Option_None };
            }
            else { __builtin_unreachable(); }
            __sc6;
          });
        }
        else { __builtin_unreachable(); }
        __sc2;
      });
    }
    else if (__sc1.tag == Option_None) {
      return (Option__i64){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

Option__u64 str__parse_u64(const str *const self) {
  return str__parse_u64_radix(self, 10U);
}

Option__i64 str__parse_i64(const str *const self) {
  return str__parse_i64_radix(self, 10U);
}

Option__usize str__parse_usize(const str *const self) {
  {
    const Option__u64 __sc8 = str__parse_u64(self);
    if (__sc8.tag == Option_Some) {
      const uint64_t v = __sc8.payload.Some._0;
      return (Option__usize){ .tag = Option_Some, .payload.Some = { ((size_t)v) } };
    }
    else if (__sc8.tag == Option_None) {
      return (Option__usize){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

Option__isize str__parse_isize(const str *const self) {
  {
    const Option__i64 __sc9 = str__parse_i64(self);
    if (__sc9.tag == Option_Some) {
      const int64_t v = __sc9.payload.Some._0;
      return (Option__isize){ .tag = Option_Some, .payload.Some = { ((intptr_t)v) } };
    }
    else if (__sc9.tag == Option_None) {
      return (Option__isize){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

Option__u32 str__parse_u32(const str *const self) {
  {
    const Option__u64 __sc10 = str__parse_u64(self);
    if (__sc10.tag == Option_Some) {
      const uint64_t v = __sc10.payload.Some._0;
      return ({
        Option__u32 __sc11;
        const bool __sc12 = (v <= 0xFFFFFFFFULL);
        if (__sc12 == true) {
          __sc11 = (Option__u32){ .tag = Option_Some, .payload.Some = { ((uint32_t)v) } };
        }
        else if (__sc12 == false) {
          __sc11 = (Option__u32){ .tag = Option_None };
        }
        else { __builtin_unreachable(); }
        __sc11;
      });
    }
    else if (__sc10.tag == Option_None) {
      return (Option__u32){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

Option__u16 str__parse_u16(const str *const self) {
  {
    const Option__u64 __sc13 = str__parse_u64(self);
    if (__sc13.tag == Option_Some) {
      const uint64_t v = __sc13.payload.Some._0;
      return ({
        Option__u16 __sc14;
        const bool __sc15 = (v <= 65535ULL);
        if (__sc15 == true) {
          __sc14 = (Option__u16){ .tag = Option_Some, .payload.Some = { ((uint16_t)v) } };
        }
        else if (__sc15 == false) {
          __sc14 = (Option__u16){ .tag = Option_None };
        }
        else { __builtin_unreachable(); }
        __sc14;
      });
    }
    else if (__sc13.tag == Option_None) {
      return (Option__u16){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

Option__u8 str__parse_u8(const str *const self) {
  {
    const Option__u64 __sc16 = str__parse_u64(self);
    if (__sc16.tag == Option_Some) {
      const uint64_t v = __sc16.payload.Some._0;
      return ({
        Option__u8 __sc17;
        const bool __sc18 = (v <= 255ULL);
        if (__sc18 == true) {
          __sc17 = (Option__u8){ .tag = Option_Some, .payload.Some = { ((uint8_t)v) } };
        }
        else if (__sc18 == false) {
          __sc17 = (Option__u8){ .tag = Option_None };
        }
        else { __builtin_unreachable(); }
        __sc17;
      });
    }
    else if (__sc16.tag == Option_None) {
      return (Option__u8){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

Option__i32 str__parse_i32(const str *const self) {
  {
    const Option__i64 __sc19 = str__parse_i64(self);
    if (__sc19.tag == Option_Some) {
      const int64_t v = __sc19.payload.Some._0;
      return ({
        Option__i32 __sc20;
        const bool __sc21 = ((v >= (-2147483648)) && (v <= 2147483647));
        if (__sc21 == true) {
          __sc20 = (Option__i32){ .tag = Option_Some, .payload.Some = { ((int32_t)v) } };
        }
        else if (__sc21 == false) {
          __sc20 = (Option__i32){ .tag = Option_None };
        }
        else { __builtin_unreachable(); }
        __sc20;
      });
    }
    else if (__sc19.tag == Option_None) {
      return (Option__i32){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

Option__i16 str__parse_i16(const str *const self) {
  {
    const Option__i64 __sc22 = str__parse_i64(self);
    if (__sc22.tag == Option_Some) {
      const int64_t v = __sc22.payload.Some._0;
      return ({
        Option__i16 __sc23;
        const bool __sc24 = ((v >= -32768) && (v <= 32767));
        if (__sc24 == true) {
          __sc23 = (Option__i16){ .tag = Option_Some, .payload.Some = { ((int16_t)v) } };
        }
        else if (__sc24 == false) {
          __sc23 = (Option__i16){ .tag = Option_None };
        }
        else { __builtin_unreachable(); }
        __sc23;
      });
    }
    else if (__sc22.tag == Option_None) {
      return (Option__i16){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

Option__i8 str__parse_i8(const str *const self) {
  {
    const Option__i64 __sc25 = str__parse_i64(self);
    if (__sc25.tag == Option_Some) {
      const int64_t v = __sc25.payload.Some._0;
      return ({
        Option__i8 __sc26;
        const bool __sc27 = ((v >= -128) && (v <= 127));
        if (__sc27 == true) {
          __sc26 = (Option__i8){ .tag = Option_Some, .payload.Some = { ((int8_t)v) } };
        }
        else if (__sc27 == false) {
          __sc26 = (Option__i8){ .tag = Option_None };
        }
        else { __builtin_unreachable(); }
        __sc26;
      });
    }
    else if (__sc25.tag == Option_None) {
      return (Option__i8){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

Option__f64 str__parse_f64(const str *const self) {
  const size_t n = self->len;
  if (n == 0ULL) {
    return (Option__f64){ .tag = Option_None };
  }
  size_t i = 0ULL;
  const uint8_t b0 = str__byte_at(self, 0ULL);
  const bool neg = (b0 == (uint8_t)'-');
  if (neg || (b0 == (uint8_t)'+')) {
    (i = 1ULL);
  }
  uint64_t mant = 0ULL;
  int64_t exp10 = 0;
  bool any = false;
  while (i < n) {
    const uint8_t b = str__byte_at(self, i);
    if ((b < (uint8_t)'0') || (b > (uint8_t)'9')) {
      break;
    }
    (any = true);
    if (mant <= 1844674407370955160ULL) {
      (mant = ((mant * 10ULL) + ((uint64_t)((uint8_t)((uint32_t)b - (uint32_t)(uint8_t)'0')))));
    } else {
      (exp10 += 1);
    }
    (i += 1ULL);
  }
  if ((i < n) && (str__byte_at(self, i) == (uint8_t)'.')) {
    (i += 1ULL);
    while (i < n) {
      const uint8_t b = str__byte_at(self, i);
      if ((b < (uint8_t)'0') || (b > (uint8_t)'9')) {
        break;
      }
      (any = true);
      if (mant <= 1844674407370955160ULL) {
        (mant = ((mant * 10ULL) + ((uint64_t)((uint8_t)((uint32_t)b - (uint32_t)(uint8_t)'0')))));
        (exp10 -= 1);
      }
      (i += 1ULL);
    }
  }
  if (!any) {
    return (Option__f64){ .tag = Option_None };
  }
  if ((i < n) && ((str__byte_at(self, i) == (uint8_t)'e') || (str__byte_at(self, i) == (uint8_t)'E'))) {
    (i += 1ULL);
    bool eneg = false;
    if ((i < n) && ((str__byte_at(self, i) == (uint8_t)'+') || (str__byte_at(self, i) == (uint8_t)'-'))) {
      (eneg = (str__byte_at(self, i) == (uint8_t)'-'));
      (i += 1ULL);
    }
    int64_t e = 0;
    bool eany = false;
    while (i < n) {
      const uint8_t b = str__byte_at(self, i);
      if ((b < (uint8_t)'0') || (b > (uint8_t)'9')) {
        break;
      }
      (eany = true);
      if (e < 10000) {
        (e = ({ int64_t __sc_r; if (__builtin_add_overflow(({ int64_t __sc_r; if (__builtin_mul_overflow(e, 10LL, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }), ((int64_t)((uint8_t)((uint32_t)b - (uint32_t)(uint8_t)'0'))), &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      }
      (i += 1ULL);
    }
    if (!eany) {
      return (Option__f64){ .tag = Option_None };
    }
    (exp10 += ({
      int64_t __sc28;
      const bool __sc29 = eneg;
      if (__sc29 == true) {
        __sc28 = ({ int64_t __sc_r; if (__builtin_sub_overflow(0LL, e, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; });
      }
      else if (__sc29 == false) {
        __sc28 = e;
      }
      else { __builtin_unreachable(); }
      __sc28;
    }));
  }
  if (i != n) {
    return (Option__f64){ .tag = Option_None };
  }
  double v = ((double)mant);
  int64_t e = exp10;
  while (e > 0) {
    (v = (v * 10.0));
    (e -= 1);
  }
  while (e < 0) {
    (v = (v / 10.0));
    (e += 1);
  }
  if (neg) {
    (v = (0.0 - v));
  }
  return (Option__f64){ .tag = Option_Some, .payload.Some = { v } };
}

Option__f32 str__parse_f32(const str *const self) {
  {
    const Option__f64 __sc30 = str__parse_f64(self);
    if (__sc30.tag == Option_Some) {
      const double v = __sc30.payload.Some._0;
      return (Option__f32){ .tag = Option_Some, .payload.Some = { ((float)v) } };
    }
    else if (__sc30.tag == Option_None) {
      return (Option__f32){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

static __attribute__((unused)) Option__u64 __str_digits_u64(const str *const s, uint32_t const radix, size_t const start) {
  if (((radix < 2U) || (radix > 36U)) || (start >= str__len(s))) {
    return (Option__u64){ .tag = Option_None };
  }
  const uint64_t r = ((uint64_t)radix);
  uint64_t acc = 0ULL;
  size_t i = start;
  while (i < str__len(s)) {
    const uint8_t b = str__byte_at(s, i);
    uint32_t d = 99U;
    if ((b >= (uint8_t)'0') && (b <= (uint8_t)'9')) {
      (d = ((uint32_t)((uint8_t)((uint32_t)b - (uint32_t)(uint8_t)'0'))));
    } else if ((b >= (uint8_t)'a') && (b <= (uint8_t)'z')) {
      (d = (((uint32_t)((uint8_t)((uint32_t)b - (uint32_t)(uint8_t)'a'))) + 10U));
    } else if ((b >= (uint8_t)'A') && (b <= (uint8_t)'Z')) {
      (d = (((uint32_t)((uint8_t)((uint32_t)b - (uint32_t)(uint8_t)'A'))) + 10U));
    }
    if (d >= radix) {
      return (Option__u64){ .tag = Option_None };
    }
    const uint64_t dv = ((uint64_t)d);
    if (acc > ({ uint64_t __sc31 = (0xFFFFFFFFFFFFFFFFULL - dv); uint64_t __sc32 = r; if (__sc32 == 0) { __sc_panic("divide by zero"); } (__sc31 / __sc32); })) {
      return (Option__u64){ .tag = Option_None };
    }
    (acc = ((acc * r) + dv));
    (i += 1ULL);
  }
  return (Option__u64){ .tag = Option_Some, .payload.Some = { acc } };
}

Option__u8 Bytes__next(Bytes *const self) {
  if (self->i >= str__len(&self->s)) {
    return (Option__u8){ .tag = Option_None };
  }
  const uint8_t b = str__byte_at(&self->s, self->i);
  (self->i = (self->i + 1ULL));
  return (Option__u8){ .tag = Option_Some, .payload.Some = { b } };
}

Option__u32 Chars__next(Chars *const self) {
  if (self->i >= str__len(&self->s)) {
    return (Option__u32){ .tag = Option_None };
  }
  const uint8_t b0 = str__byte_at(&self->s, self->i);
  uint32_t cp = 0U;
  size_t n = 1ULL;
  if (b0 < 0x80U) {
    (cp = ((uint32_t)b0));
    (n = 1ULL);
  } else if ((b0 & 0xE0U) == 0xC0U) {
    (cp = ((uint32_t)(b0 & 0x1FU)));
    (n = 2ULL);
  } else if ((b0 & 0xF0U) == 0xE0U) {
    (cp = ((uint32_t)(b0 & 0x0FU)));
    (n = 3ULL);
  } else if ((b0 & 0xF8U) == 0xF0U) {
    (cp = ((uint32_t)(b0 & 0x07U)));
    (n = 4ULL);
  } else {
    (self->i = (self->i + 1ULL));
    return (Option__u32){ .tag = Option_Some, .payload.Some = { 0xFFFDU } };
  }
  if ((self->i + n) > str__len(&self->s)) {
    (self->i = (self->i + 1ULL));
    return (Option__u32){ .tag = Option_Some, .payload.Some = { 0xFFFDU } };
  }
  size_t k = 1ULL;
  while (k < n) {
    const uint8_t cb = str__byte_at(&self->s, (self->i + k));
    if ((cb & 0xC0U) != 0x80U) {
      (self->i = (self->i + 1ULL));
      return (Option__u32){ .tag = Option_Some, .payload.Some = { 0xFFFDU } };
    }
    (cp = (({ uint32_t __sc33 = cp; int64_t __sc34 = (int64_t)(6U); if ((uint64_t)__sc34 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc33 << __sc34)); }) | ((uint32_t)(cb & 0x3FU))));
    (k = (k + 1ULL));
  }
  (self->i = (self->i + n));
  return (Option__u32){ .tag = Option_Some, .payload.Some = { cp } };
}

Option__str Split__next(Split *const self) {
  if (self->i > str__len(&self->s)) {
    return (Option__str){ .tag = Option_None };
  }
  if (str__len(&self->sep) == 0ULL) {
    const str whole = str__slice(&self->s, self->i, str__len(&self->s));
    (self->i = (str__len(&self->s) + 1ULL));
    return (Option__str){ .tag = Option_Some, .payload.Some = { whole } };
  }
  const str rest = str__slice(&self->s, self->i, str__len(&self->s));
  const intptr_t pos = str__find(&rest, self->sep);
  if (pos < 0LL) {
    const str tail = str__slice(&self->s, self->i, str__len(&self->s));
    (self->i = (str__len(&self->s) + 1ULL));
    return (Option__str){ .tag = Option_Some, .payload.Some = { tail } };
  }
  const size_t j = (self->i + ((size_t)pos));
  const str piece = str__slice(&self->s, self->i, j);
  (self->i = (j + str__len(&self->sep)));
  return (Option__str){ .tag = Option_Some, .payload.Some = { piece } };
}

Option__str Lines__next(Lines *const self) {
  if (self->i >= str__len(&self->s)) {
    return (Option__str){ .tag = Option_None };
  }
  const size_t start = self->i;
  size_t j = self->i;
  while ((j < str__len(&self->s)) && (str__byte_at(&self->s, j) != 10U)) {
    (j = (j + 1ULL));
  }
  size_t end = j;
  if ((end > start) && (str__byte_at(&self->s, (end - 1ULL)) == 13U)) {
    (end = (end - 1ULL));
  }
  const str piece = str__slice(&self->s, start, end);
  (self->i = (j + 1ULL));
  return (Option__str){ .tag = Option_Some, .payload.Some = { piece } };
}

