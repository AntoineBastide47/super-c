#include "../__std/string.h"
#include "../__std/core.h"
#include "../__std/interfaces.h"
#include "../__std/option.h"
#include "../__std/range.h"
#include "../__std/slice.h"
#include "../__std/str.h"

_Static_assert(sizeof(StringLarge) == 24 && _Alignof(StringLarge) == 8, "super-c layout model mismatch: StringLarge");
_Static_assert(sizeof(StringSmall) == 24 && _Alignof(StringSmall) == 1, "super-c layout model mismatch: StringSmall");
_Static_assert(sizeof(StringRepr) == 24 && _Alignof(StringRepr) == 8, "super-c layout model mismatch: StringRepr");
_Static_assert(sizeof(String__Global) == 24 && _Alignof(String__Global) == 8, "super-c layout model mismatch: String__Global");

static __attribute__((unused)) bool String__Global__is_large(const String__Global *const self);
static __attribute__((unused)) uint8_t *String__Global__data_ptr(String__Global *const self);
static __attribute__((unused)) void String__Global__set_len(String__Global *const self, size_t const n);
static __attribute__((unused)) void String__Global__grow_to(String__Global *const self, size_t const new_cap);

static __attribute__((unused)) bool String__Global__is_large(const String__Global *const self) {
  return ((self->repr.small.len & 0x80U) != 0U);
}

static __attribute__((unused)) uint8_t *String__Global__data_ptr(String__Global *const self) {
  if (String__Global__is_large(self)) {
    return self->repr.large.ptr;
  }
  return ((uint8_t *)(&self->repr.small.data[0]));
}

static __attribute__((unused)) void String__Global__set_len(String__Global *const self, size_t const n) {
  if (String__Global__is_large(self)) {
    (self->repr.large.len = n);
  } else {
    (self->repr.small.len = ((uint8_t)n));
  }
}

static __attribute__((unused)) void String__Global__grow_to(String__Global *const self, size_t const new_cap) {
  if (String__Global__is_large(self)) {
    uint8_t *const p = ((uint8_t *)Global__realloc(&self->alloc, ((void *)self->repr.large.ptr), String__Global__capacity(self), new_cap, 1ULL));
    (self->repr.large.ptr = p);
    (self->repr.large.cap = (new_cap | 9223372036854775808ULL));
    return;
  }
  const size_t cur = ((size_t)self->repr.small.len);
  uint8_t *const p = ((uint8_t *)Global__alloc(&self->alloc, new_cap, 1ULL));
  if (cur > 0ULL) {
    memcpy(((void *)p), ((const void *)(&self->repr.small.data[0])), cur);
  }
  (self->repr.large.ptr = p);
  (self->repr.large.len = cur);
  (self->repr.large.cap = (new_cap | 9223372036854775808ULL));
}

String__Global String__Global__new_in(Global const alloc) {
  return (String__Global){ .repr = (StringRepr){ .small = (StringSmall){ .len = 0U } }, .alloc = alloc };
}

String__Global String__Global__with_capacity_in(Global alloc, size_t const cap) {
  if (cap <= 23ULL) {
    return (String__Global){ .repr = (StringRepr){ .small = (StringSmall){ .len = 0U } }, .alloc = alloc };
  }
  uint8_t *const p = ((uint8_t *)Global__alloc(&alloc, cap, 1ULL));
  return (String__Global){ .repr = (StringRepr){ .large = (StringLarge){ .ptr = p, .len = 0ULL, .cap = (cap | 9223372036854775808ULL) } }, .alloc = alloc };
}

String__Global String__Global__from_str_in(Global const alloc, str const text) {
  String__Global s = String__Global__with_capacity_in(alloc, str__len(&text));
  String__Global__push_str(&s, text);
  return s;
}

size_t String__Global__len(const String__Global *const self) {
  if (String__Global__is_large(self)) {
    return self->repr.large.len;
  }
  return ((size_t)self->repr.small.len);
}

size_t String__Global__capacity(const String__Global *const self) {
  if (String__Global__is_large(self)) {
    return ({ size_t __sc0 = ({ size_t __sc2 = self->repr.large.cap; int64_t __sc3 = (int64_t)(1ULL); if ((uint64_t)__sc3 >= 64) { __sc_panic("shift out of range"); } (size_t)((uint64_t)((uint64_t)__sc2 << __sc3)); }); int64_t __sc1 = (int64_t)(1ULL); if ((uint64_t)__sc1 >= 64) { __sc_panic("shift out of range"); } (size_t)(__sc0 >> __sc1); });
  }
  return 23ULL;
}

bool String__Global__is_empty(const String__Global *const self) {
  return (String__Global__len(self) == 0ULL);
}

void String__Global__reserve(String__Global *const self, size_t const additional) {
  const size_t needed = (String__Global__len(self) + additional);
  if (needed <= String__Global__capacity(self)) {
    return;
  }
  size_t new_cap = (String__Global__capacity(self) * 2ULL);
  if (new_cap < needed) {
    (new_cap = needed);
  }
  String__Global__grow_to(self, new_cap);
}

void String__Global__reserve_exact(String__Global *const self, size_t const additional) {
  const size_t needed = (String__Global__len(self) + additional);
  if (needed > String__Global__capacity(self)) {
    String__Global__grow_to(self, needed);
  }
}

void String__Global__pad_nul(String__Global *const self, size_t const n) {
  String__Global__reserve_exact(self, n);
  const size_t l = String__Global__len(self);
  uint8_t *const p = String__Global__data_ptr(self);
  size_t i = 0ULL;
  while (i < n) {
    (p[(l + i)] = 0U);
    (i = (i + 1ULL));
  }
}

uint8_t *String__Global__spare_mut(String__Global *const self, size_t const additional) {
  String__Global__reserve(self, additional);
  return (String__Global__data_ptr(self) + String__Global__len(self));
}

void String__Global__advance_len(String__Global *const self, size_t const n) {
  String__Global__set_len(self, (String__Global__len(self) + n));
}

void String__Global__clear(String__Global *const self) {
  String__Global__set_len(self, 0ULL);
}

void String__Global__truncate(String__Global *const self, size_t const new_len) {
  if (new_len < String__Global__len(self)) {
    String__Global__set_len(self, new_len);
  }
}

void String__Global__push_bytes(String__Global *const self, const uint8_t *const src, size_t const n) {
  if (n == 0ULL) {
    return;
  }
  String__Global__reserve(self, n);
  const size_t len = String__Global__len(self);
  uint8_t *const p = String__Global__data_ptr(self);
  memcpy(((void *)(p + len)), ((const void *)src), n);
  String__Global__set_len(self, (len + n));
}

void String__Global__push_byte(String__Global *const self, uint8_t const b) {
  String__Global__reserve(self, 1ULL);
  const size_t len = String__Global__len(self);
  uint8_t *const p = String__Global__data_ptr(self);
  (p[len] = b);
  String__Global__set_len(self, (len + 1ULL));
}

void String__Global__push_str(String__Global *const self, str const text) {
  String__Global__push_bytes(self, str__ptr(&text), str__len(&text));
}

void String__Global__push_string(String__Global *const self, const String__Global *const other) {
  String__Global__push_bytes(self, String__Global__as_ptr(other), String__Global__len(other));
}

void String__Global__push_u64(String__Global *const self, uint64_t const value) {
  if (value >= 10ULL) {
    String__Global__push_u64(self, ({ uint64_t __sc4 = value; uint64_t __sc5 = 10ULL; if (__sc5 == 0) { __sc_panic("divide by zero"); } (__sc4 / __sc5); }));
  }
  String__Global__push_byte(self, ((uint8_t)(48ULL + ({ uint64_t __sc6 = value; uint64_t __sc7 = 10ULL; if (__sc7 == 0) { __sc_panic("divide by zero"); } (__sc6 % __sc7); }))));
}

void String__Global__push_i64(String__Global *const self, int64_t const value) {
  if (value < 0) {
    String__Global__push_byte(self, 45U);
    String__Global__push_u64(self, (0ULL - ((uint64_t)value)));
  } else {
    String__Global__push_u64(self, ((uint64_t)value));
  }
}

void String__Global__push_hex(String__Global *const self, uint64_t const value, bool const upper) {
  if (value >= 16ULL) {
    String__Global__push_hex(self, ({ uint64_t __sc8 = value; uint64_t __sc9 = 16ULL; if (__sc9 == 0) { __sc_panic("divide by zero"); } (__sc8 / __sc9); }), upper);
  }
  const uint64_t d = ({ uint64_t __sc10 = value; uint64_t __sc11 = 16ULL; if (__sc11 == 0) { __sc_panic("divide by zero"); } (__sc10 % __sc11); });
  if (d < 10ULL) {
    String__Global__push_byte(self, ((uint8_t)(48ULL + d)));
  } else {
    uint64_t base = 87ULL;
    if (upper) {
      (base = 55ULL);
    }
    String__Global__push_byte(self, ((uint8_t)(base + d)));
  }
}

void String__Global__push_hex_i64(String__Global *const self, int64_t const value, bool const upper) {
  if (value < 0) {
    String__Global__push_byte(self, 45U);
    String__Global__push_hex(self, (0ULL - ((uint64_t)value)), upper);
  } else {
    String__Global__push_hex(self, ((uint64_t)value), upper);
  }
}

void String__Global__push_bin(String__Global *const self, uint64_t const value) {
  if (value >= 2ULL) {
    String__Global__push_bin(self, ({ uint64_t __sc12 = value; uint64_t __sc13 = 2ULL; if (__sc13 == 0) { __sc_panic("divide by zero"); } (__sc12 / __sc13); }));
  }
  String__Global__push_byte(self, ((uint8_t)(48ULL + ({ uint64_t __sc14 = value; uint64_t __sc15 = 2ULL; if (__sc15 == 0) { __sc_panic("divide by zero"); } (__sc14 % __sc15); }))));
}

void String__Global__push_f64_prec(String__Global *const self, double const value, uint32_t const prec) {
  char *const buf = ((char *)Global__alloc(&self->alloc, 64ULL, 1ULL));
  const int32_t n = snprintf(buf, 64ULL, "%.*f", ((int32_t)prec), value);
  if (n > 0) {
    size_t m = ((size_t)n);
    if (m > 63ULL) {
      (m = 63ULL);
    }
    String__Global__push_bytes(self, ((const uint8_t *)buf), m);
  }
  Global__dealloc(&self->alloc, ((void *)buf), 64ULL, 1ULL);
}

void String__Global__push_padded(String__Global *const self, str const s, size_t const width, uint8_t const fill, uint8_t const align) {
  const size_t n = str__len(&s);
  if (width <= n) {
    String__Global__push_str(self, s);
    return;
  }
  const size_t pad = (width - n);
  if ((((align == 1U) && (fill == 48U)) && (n > 0ULL)) && (str__byte_at(&s, 0ULL) == 45U)) {
    String__Global__push_byte(self, 45U);
    for (size_t k = 0ULL; k < pad; k++) {
      String__Global__push_byte(self, 48U);
    }
    String__Global__push_str(self, str__slice(&s, 1ULL, n));
    return;
  }
  size_t lead = 0ULL;
  if (align == 1U) {
    (lead = pad);
  } else if (align == 2U) {
    (lead = ({ size_t __sc16 = pad; size_t __sc17 = 2ULL; if (__sc17 == 0) { __sc_panic("divide by zero"); } (__sc16 / __sc17); }));
  }
  size_t i = 0ULL;
  while (i < lead) {
    String__Global__push_byte(self, fill);
    (i += 1ULL);
  }
  String__Global__push_str(self, s);
  while (i < pad) {
    String__Global__push_byte(self, fill);
    (i += 1ULL);
  }
}

void String__Global__push_f64(String__Global *const self, double const value) {
  char *const buf = ((char *)Global__alloc(&self->alloc, 32ULL, 1ULL));
  const int32_t n = snprintf(buf, 32ULL, "%g", value);
  if (n > 0) {
    String__Global__push_bytes(self, ((const uint8_t *)buf), ((size_t)n));
  }
  Global__dealloc(&self->alloc, ((void *)buf), 32ULL, 1ULL);
}

const uint8_t *String__Global__as_ptr(const String__Global *const self) {
  if (String__Global__is_large(self)) {
    return ((const uint8_t *)self->repr.large.ptr);
  }
  return ((const uint8_t *)(&self->repr.small.data[0]));
}

str String__Global__as_str(const String__Global *const self) {
  return str__from_raw(String__Global__as_ptr(self), String__Global__len(self));
}

const char *String__Global__cstr(String__Global *const self) {
  String__Global__reserve(self, 1ULL);
  const size_t len = String__Global__len(self);
  uint8_t *const p = String__Global__data_ptr(self);
  (p[len] = 0U);
  return ((const char *)String__Global__as_ptr(self));
}

String__Global String__Global__substring(const String__Global *const self, size_t const start, size_t const end) {
  const size_t n = (end - start);
  String__Global s = String__Global__with_capacity_in(self->alloc, n);
  if (n > 0ULL) {
    memcpy(((void *)String__Global__data_ptr(&s)), ((const void *)(String__Global__as_ptr(self) + start)), n);
    String__Global__set_len(&s, n);
  }
  return s;
}

bool String__Global__equals(const String__Global *const self, const String__Global *const other) {
  const size_t n = String__Global__len(self);
  if (n != String__Global__len(other)) {
    return false;
  }
  if (n == 0ULL) {
    return true;
  }
  return (memcmp(((const void *)String__Global__as_ptr(self)), ((const void *)String__Global__as_ptr(other)), n) == 0);
}

bool String__Global__ends_with(const String__Global *const self, str const suffix) {
  const size_t n = String__Global__len(self);
  if (str__len(&suffix) > n) {
    return false;
  }
  if (str__len(&suffix) == 0ULL) {
    return true;
  }
  return (memcmp(((const void *)(String__Global__as_ptr(self) + (n - str__len(&suffix)))), ((const void *)str__ptr(&suffix)), str__len(&suffix)) == 0);
}

size_t String__Global__index_of_byte(const String__Global *const self, uint8_t const b) {
  const size_t n = String__Global__len(self);
  const uint8_t *const p = String__Global__as_ptr(self);
  for (size_t i = 0ULL; i < n; i++) {
    if (p[i] == b) {
      return i;
    }
  }
  return n;
}

size_t String__Global__find(const String__Global *const self, str const needle) {
  const size_t n = String__Global__len(self);
  if (str__len(&needle) == 0ULL) {
    return 0ULL;
  }
  if (str__len(&needle) > n) {
    return n;
  }
  const uint8_t *const p = String__Global__as_ptr(self);
  const size_t last = (n - str__len(&needle));
  for (size_t i = 0ULL; i <= last; i++) {
    if (memcmp(((const void *)(p + i)), ((const void *)str__ptr(&needle)), str__len(&needle)) == 0) {
      return i;
    }
  }
  return n;
}

size_t String__Global__rfind(const String__Global *const self, str const needle) {
  const size_t n = String__Global__len(self);
  if (str__len(&needle) == 0ULL) {
    return n;
  }
  if (str__len(&needle) > n) {
    return n;
  }
  const uint8_t *const p = String__Global__as_ptr(self);
  size_t i = ((n - str__len(&needle)) + 1ULL);
  while (i > 0ULL) {
    (i = (i - 1ULL));
    if (memcmp(((const void *)(p + i)), ((const void *)str__ptr(&needle)), str__len(&needle)) == 0) {
      return i;
    }
  }
  return n;
}

void String__Global__trim_start(String__Global *const self) {
  const size_t len = String__Global__len(self);
  uint8_t *const p = String__Global__data_ptr(self);
  size_t start = 0ULL;
  while (start < len) {
    const uint8_t b = p[start];
    if ((((b != 32U) && (b != 9U)) && (b != 10U)) && (b != 13U)) {
      break;
    }
    (start = (start + 1ULL));
  }
  if (start > 0ULL) {
    memmove(((void *)p), ((const void *)(p + start)), (len - start));
    String__Global__set_len(self, (len - start));
  }
}

void String__Global__trim_end(String__Global *const self) {
  uint8_t *const p = String__Global__data_ptr(self);
  size_t len = String__Global__len(self);
  while (len > 0ULL) {
    const uint8_t b = p[(len - 1ULL)];
    if ((((b != 32U) && (b != 9U)) && (b != 10U)) && (b != 13U)) {
      break;
    }
    (len = (len - 1ULL));
  }
  String__Global__set_len(self, len);
}

void String__Global__print(const String__Global *const self) {
  const size_t n = String__Global__len(self);
  const uint8_t *const p = String__Global__as_ptr(self);
  for (size_t i = 0ULL; i < n; i++) {
    putchar(((int32_t)p[i]));
  }
}

void String__Global__eprint(const String__Global *const self) {
  const size_t n = String__Global__len(self);
  const uint8_t *const p = String__Global__as_ptr(self);
  FILE *const err = __sc_stderr();
  for (size_t i = 0ULL; i < n; i++) {
    fputc(((int32_t)p[i]), err);
  }
}

void String__Global__eprintln(const String__Global *const self) {
  String__Global__eprint(self);
  fputc(10, __sc_stderr());
}

String__Global String__Global__new(void) {
  return String__Global__new_in(Global__default_());
}

String__Global String__Global__with_capacity(size_t const cap) {
  return String__Global__with_capacity_in(Global__default_(), cap);
}

String__Global String__Global__from_str(str const text) {
  return String__Global__from_str_in(Global__default_(), text);
}

String__Global String__Global__from_cstr(const char *const s) {
  const size_t n = strlen(s);
  String__Global out = String__Global__with_capacity(n);
  String__Global__push_bytes(&out, ((const uint8_t *)s), n);
  return out;
}

void String__Global__free(String__Global *const self) {
  if (String__Global__is_large(self)) {
    Global__dealloc(&self->alloc, ((void *)self->repr.large.ptr), String__Global__capacity(self), 1ULL);
  }
  (self->repr.small.len = 0U);
}

bool String__Global__eq(const String__Global *const self, const String__Global *const other) {
  return String__Global__equals(self, other);
}

uint64_t String__Global__hash(const String__Global *const self) {
  const size_t n = String__Global__len(self);
  const uint8_t *const p = String__Global__as_ptr(self);
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < n; i++) {
    (h = ((h ^ ((uint64_t)p[i])) * 0x100000001b3ULL));
  }
  return h;
}

int32_t String__Global__cmp(const String__Global *const self, const String__Global *const other) {
  const size_t la = String__Global__len(self);
  const size_t lb = String__Global__len(other);
  size_t n = la;
  if (lb < la) {
    (n = lb);
  }
  const int32_t c = memcmp(((const void *)String__Global__as_ptr(self)), ((const void *)String__Global__as_ptr(other)), n);
  if (c != 0) {
    return c;
  }
  if (la < lb) {
    return -1;
  }
  if (la > lb) {
    return 1;
  }
  return 0;
}

String__Global String__Global__default_(void) {
  return String__Global__new();
}

String__Global String__Global__from(str const value) {
  return String__Global__from_str(value);
}

String__Global String__Global__clone(const String__Global *const self) {
  const size_t n = String__Global__len(self);
  String__Global s = String__Global__with_capacity_in(self->alloc, n);
  if (n > 0ULL) {
    memcpy(((void *)String__Global__data_ptr(&s)), ((const void *)String__Global__as_ptr(self)), n);
    String__Global__set_len(&s, n);
  }
  return s;
}

String__Global String__Global__fmt(const String__Global *const self) {
  return String__Global__from_str(String__Global__as_str(self));
}

size_t String__Global__write(String__Global *const self, Slice__u8 const bytes) {
  const size_t n = Slice__u8__len(&bytes);
  String__Global__push_bytes(self, Slice__u8__as_ptr(&bytes), n);
  return n;
}

const uint8_t *String__Global__index(const String__Global *const self, size_t const i) {
  return (&({ __auto_type __sc18 = String__Global__as_str(self); str__ptr(&__sc18); })[i]);
}

str String__Global__index_range(const String__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc19;
    if (r.inclusive) {
      __sc19 = (r.end + 1ULL);
    } else {
      __sc19 = r.end;
    }
    __sc19;
  });
  return ({ __auto_type __sc20 = String__Global__as_str(self); str__slice(&__sc20, r.start, hi); });
}

void String__Global__format_into(String__Global *const self, str const fmt, ...) {
  (void)self;
  (void)fmt;
}

size_t Slice__String__Global__len(const Slice__String__Global *const self) {
  return self->len;
}

const String__Global *Slice__String__Global__as_ptr(const Slice__String__Global *const self) {
  return self->ptr;
}

const String__Global *Slice__String__Global__index(const Slice__String__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__String__Global Slice__String__Global__index_range(const Slice__String__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc21;
    if (r.inclusive) {
      __sc21 = (r.end + 1ULL);
    } else {
      __sc21 = r.end;
    }
    __sc21;
  });
  return (Slice__String__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__String__Global__len(const SliceMut__String__Global *const self) {
  return self->len;
}

String__Global *SliceMut__String__Global__as_mut_ptr(const SliceMut__String__Global *const self) {
  return self->ptr;
}

const String__Global *SliceMut__String__Global__index(const SliceMut__String__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__String__Global SliceMut__String__Global__index_range(const SliceMut__String__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc22;
    if (r.inclusive) {
      __sc22 = (r.end + 1ULL);
    } else {
      __sc22 = r.end;
    }
    __sc22;
  });
  return (Slice__String__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

String__Global *SliceMut__String__Global__index_mut(SliceMut__String__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__String__Global SliceMut__String__Global__index_range_mut(SliceMut__String__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc23;
    if (r.inclusive) {
      __sc23 = (r.end + 1ULL);
    } else {
      __sc23 = r.end;
    }
    __sc23;
  });
  return (SliceMut__String__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

