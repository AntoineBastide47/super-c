#ifndef SUPER___STD__STRING_H
#define SUPER___STD__STRING_H

#include "../super_rt.h"
typedef struct str str;
typedef struct Bytes Bytes;
typedef struct Chars Chars;
typedef struct Split Split;
typedef struct Lines Lines;
typedef struct Global Global;
typedef struct Slice__u8 Slice__u8;
typedef struct Range__usize Range__usize;
typedef struct Option__ptr_u8 Option__ptr_u8;
typedef struct Slice__String__Global Slice__String__Global;
typedef struct SliceMut__String__Global SliceMut__String__Global;
typedef struct Option__ptr_String__Global Option__ptr_String__Global;
#include "../__std/interfaces.h"
#include "../__std/slice.h"

typedef struct StringLarge StringLarge;
typedef struct StringSmall StringSmall;
typedef union StringRepr StringRepr;
typedef struct String__Global String__Global;
typedef struct Slice__String__Global Slice__String__Global;
typedef struct SliceMut__String__Global SliceMut__String__Global;

struct StringLarge {
  uint8_t *ptr;
  size_t len;
  size_t cap;
};
struct StringSmall {
  uint8_t data[23];
  uint8_t len;
};
union StringRepr {
  StringLarge large;
  StringSmall small;
};
struct String__Global {
  StringRepr repr;
  Global alloc;
};
struct Slice__String__Global {
  const String__Global *ptr;
  size_t len;
};
struct SliceMut__String__Global {
  String__Global *ptr;
  size_t len;
};

String__Global String__Global__new_in(Global const alloc);
String__Global String__Global__with_capacity_in(Global alloc, size_t const cap);
String__Global String__Global__from_str_in(Global const alloc, str const text);
size_t String__Global__len(const String__Global *const self);
size_t String__Global__capacity(const String__Global *const self);
bool String__Global__is_empty(const String__Global *const self);
void String__Global__reserve(String__Global *const self, size_t const additional);
void String__Global__reserve_exact(String__Global *const self, size_t const additional);
void String__Global__pad_nul(String__Global *const self, size_t const n);
uint8_t *String__Global__spare_mut(String__Global *const self, size_t const additional);
void String__Global__advance_len(String__Global *const self, size_t const n);
void String__Global__clear(String__Global *const self);
void String__Global__truncate(String__Global *const self, size_t const new_len);
void String__Global__push_bytes(String__Global *const self, const uint8_t *const src, size_t const n);
void String__Global__push_byte(String__Global *const self, uint8_t const b);
void String__Global__push_str(String__Global *const self, str const text);
void String__Global__push_string(String__Global *const self, const String__Global *const other);
void String__Global__push_u64(String__Global *const self, uint64_t const value);
void String__Global__push_i64(String__Global *const self, int64_t const value);
void String__Global__push_hex(String__Global *const self, uint64_t const value, bool const upper);
void String__Global__push_hex_i64(String__Global *const self, int64_t const value, bool const upper);
void String__Global__push_bin(String__Global *const self, uint64_t const value);
void String__Global__push_f64_prec(String__Global *const self, double const value, uint32_t const prec);
void String__Global__push_padded(String__Global *const self, str const s, size_t const width, uint8_t const fill, uint8_t const align);
void String__Global__push_f64(String__Global *const self, double const value);
const uint8_t *String__Global__as_ptr(const String__Global *const self);
str String__Global__as_str(const String__Global *const self);
const char *String__Global__cstr(String__Global *const self);
String__Global String__Global__substring(const String__Global *const self, size_t const start, size_t const end);
bool String__Global__equals(const String__Global *const self, const String__Global *const other);
bool String__Global__ends_with(const String__Global *const self, str const suffix);
size_t String__Global__index_of_byte(const String__Global *const self, uint8_t const b);
size_t String__Global__find(const String__Global *const self, str const needle);
size_t String__Global__rfind(const String__Global *const self, str const needle);
void String__Global__trim_start(String__Global *const self);
void String__Global__trim_end(String__Global *const self);
void String__Global__print(const String__Global *const self);
void String__Global__eprint(const String__Global *const self);
void String__Global__eprintln(const String__Global *const self);
String__Global String__Global__new(void);
String__Global String__Global__with_capacity(size_t const cap);
String__Global String__Global__from_str(str const text);
String__Global String__Global__from_cstr(const char *const s);
void String__Global__free(String__Global *const self);
bool String__Global__eq(const String__Global *const self, const String__Global *const other);
uint64_t String__Global__hash(const String__Global *const self);
int32_t String__Global__cmp(const String__Global *const self, const String__Global *const other);
String__Global String__Global__default_(void);
String__Global String__Global__from(str const value);
String__Global String__Global__clone(const String__Global *const self);
String__Global String__Global__fmt(const String__Global *const self);
size_t String__Global__write(String__Global *const self, Slice__u8 const bytes);
const uint8_t *String__Global__index(const String__Global *const self, size_t const i);
str String__Global__index_range(const String__Global *const self, Range__usize const r);
void String__Global__format_into(String__Global *const self, str const fmt, ...);
size_t Slice__String__Global__len(const Slice__String__Global *const self);
const String__Global *Slice__String__Global__as_ptr(const Slice__String__Global *const self);
const String__Global *Slice__String__Global__index(const Slice__String__Global *const self, size_t const i);
Slice__String__Global Slice__String__Global__index_range(const Slice__String__Global *const self, Range__usize const r);
size_t SliceMut__String__Global__len(const SliceMut__String__Global *const self);
String__Global *SliceMut__String__Global__as_mut_ptr(const SliceMut__String__Global *const self);
const String__Global *SliceMut__String__Global__index(const SliceMut__String__Global *const self, size_t const i);
Slice__String__Global SliceMut__String__Global__index_range(const SliceMut__String__Global *const self, Range__usize const r);
String__Global *SliceMut__String__Global__index_mut(SliceMut__String__Global *const self, size_t const i);
SliceMut__String__Global SliceMut__String__Global__index_range_mut(SliceMut__String__Global *const self, Range__usize const r);


#endif
