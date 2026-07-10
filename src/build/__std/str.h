#ifndef SUPER___STD__STR_H
#define SUPER___STD__STR_H

#include "../super_rt.h"
typedef struct Global Global;
typedef struct String__Global String__Global;
typedef struct Range__usize Range__usize;
typedef struct Option__u64 Option__u64;
typedef struct Option__i64 Option__i64;
typedef struct Option Option;
typedef struct Option__usize Option__usize;
typedef struct Option__isize Option__isize;
typedef struct Option__u32 Option__u32;
typedef struct Option__u16 Option__u16;
typedef struct Option__u8 Option__u8;
typedef struct Option__i32 Option__i32;
typedef struct Option__i16 Option__i16;
typedef struct Option__i8 Option__i8;
typedef struct Option__f64 Option__f64;
typedef struct Option__f32 Option__f32;
typedef struct Option__str Option__str;
typedef struct Slice__u8 Slice__u8;
typedef struct Option__ptr_u8 Option__ptr_u8;

typedef struct str str;
typedef struct Bytes Bytes;
typedef struct Chars Chars;
typedef struct Split Split;
typedef struct Lines Lines;

struct str {
  const uint8_t *ptr;
  size_t len;
};
struct Bytes {
  str s;
  size_t i;
};
struct Chars {
  str s;
  size_t i;
};
struct Split {
  str s;
  size_t i;
  str sep;
};
struct Lines {
  str s;
  size_t i;
};

str str__from_raw(const uint8_t *const ptr, size_t const len);
str str__from_cstr(const char *const s);
size_t str__len(const str *const self);
bool str__is_empty(const str *const self);
const uint8_t *str__ptr(const str *const self);
uint8_t str__byte_at(const str *const self, size_t const index);
str str__slice(const str *const self, size_t const start, size_t const end);
bool str__starts_with(const str *const self, str const prefix);
bool str__ends_with(const str *const self, str const suffix);
intptr_t str__find_byte(const str *const self, uint8_t const byte);
intptr_t str__find(const str *const self, str const needle);
bool str__contains(const str *const self, str const needle);
str str__trim_start(const str *const self);
str str__trim_end(const str *const self);
str str__trim(const str *const self);
size_t str__char_count(const str *const self);
bool str__is_valid_utf8(const str *const self);
String__Global str__to_string(const str *const self);
bool str__eq(const str *const self, const str *const other);
int32_t str__cmp(const str *const self, const str *const other);
uint64_t str__hash(const str *const self);
str str__default_(void);
const uint8_t *str__index(const str *const self, size_t const i);
str str__index_range(const str *const self, Range__usize const r);
Bytes str__bytes(const str *const self);
Chars str__chars(const str *const self);
Split str__split(const str *const self, str const sep);
Lines str__lines(const str *const self);
Option__u64 str__parse_u64_radix(const str *const self, uint32_t const radix);
Option__i64 str__parse_i64_radix(const str *const self, uint32_t const radix);
Option__u64 str__parse_u64(const str *const self);
Option__i64 str__parse_i64(const str *const self);
Option__usize str__parse_usize(const str *const self);
Option__isize str__parse_isize(const str *const self);
Option__u32 str__parse_u32(const str *const self);
Option__u16 str__parse_u16(const str *const self);
Option__u8 str__parse_u8(const str *const self);
Option__i32 str__parse_i32(const str *const self);
Option__i16 str__parse_i16(const str *const self);
Option__i8 str__parse_i8(const str *const self);
Option__f64 str__parse_f64(const str *const self);
Option__f32 str__parse_f32(const str *const self);
Option__u8 Bytes__next(Bytes *const self);
Option__u32 Chars__next(Chars *const self);
Option__str Split__next(Split *const self);
Option__str Lines__next(Lines *const self);


#endif
