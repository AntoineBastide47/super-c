#ifndef SUPER___STD__OPTION_H
#define SUPER___STD__OPTION_H

#include "../super_rt.h"
typedef struct str str;
typedef struct Global Global;
typedef struct String__Global String__Global;
typedef struct Bytes Bytes;
typedef struct Chars Chars;
typedef struct Split Split;
typedef struct Lines Lines;
typedef struct Slice__u8 Slice__u8;
typedef struct Range__usize Range__usize;
#include "../__std/str.h"
#include "../__std/string.h"

#ifndef SUPER_ENUMTAG_Option
#define SUPER_ENUMTAG_Option
typedef enum { Option_Some, Option_None } OptionTag;
#endif
typedef struct Option__ptr_u8 Option__ptr_u8;
typedef struct Option__usize Option__usize;
typedef struct Option__String__Global Option__String__Global;
typedef struct Option__ptr_String__Global Option__ptr_String__Global;
typedef struct Option__u32 Option__u32;
typedef struct Option__ptr_u32 Option__ptr_u32;
typedef struct Option__bool Option__bool;
typedef struct Option__ptr_bool Option__ptr_bool;
typedef struct Option__str Option__str;
typedef struct Option__ptr_str Option__ptr_str;
typedef struct Option__u64 Option__u64;
typedef struct Option__ptr_u64 Option__ptr_u64;
typedef struct Option__u16 Option__u16;
typedef struct Option__ptr_u16 Option__ptr_u16;
typedef struct Option__ptr_usize Option__ptr_usize;
typedef struct Option__i64 Option__i64;
typedef struct Option__isize Option__isize;
typedef struct Option__u8 Option__u8;
typedef struct Option__i32 Option__i32;
typedef struct Option__i16 Option__i16;
typedef struct Option__i8 Option__i8;
typedef struct Option__f64 Option__f64;
typedef struct Option__f32 Option__f32;

struct Option__ptr_u8 {
  OptionTag tag;
  union {
    struct { const uint8_t *_0; } Some;
  } payload;
};
struct Option__usize {
  OptionTag tag;
  union {
    struct { size_t _0; } Some;
  } payload;
};
struct Option__String__Global {
  OptionTag tag;
  union {
    struct { String__Global _0; } Some;
  } payload;
};
struct Option__ptr_String__Global {
  OptionTag tag;
  union {
    struct { const String__Global *_0; } Some;
  } payload;
};
struct Option__u32 {
  OptionTag tag;
  union {
    struct { uint32_t _0; } Some;
  } payload;
};
struct Option__ptr_u32 {
  OptionTag tag;
  union {
    struct { const uint32_t *_0; } Some;
  } payload;
};
struct Option__bool {
  OptionTag tag;
  union {
    struct { bool _0; } Some;
  } payload;
};
struct Option__ptr_bool {
  OptionTag tag;
  union {
    struct { const bool *_0; } Some;
  } payload;
};
struct Option__str {
  OptionTag tag;
  union {
    struct { str _0; } Some;
  } payload;
};
struct Option__ptr_str {
  OptionTag tag;
  union {
    struct { const str *_0; } Some;
  } payload;
};
struct Option__u64 {
  OptionTag tag;
  union {
    struct { uint64_t _0; } Some;
  } payload;
};
struct Option__ptr_u64 {
  OptionTag tag;
  union {
    struct { const uint64_t *_0; } Some;
  } payload;
};
struct Option__u16 {
  OptionTag tag;
  union {
    struct { uint16_t _0; } Some;
  } payload;
};
struct Option__ptr_u16 {
  OptionTag tag;
  union {
    struct { const uint16_t *_0; } Some;
  } payload;
};
struct Option__ptr_usize {
  OptionTag tag;
  union {
    struct { const size_t *_0; } Some;
  } payload;
};
struct Option__i64 {
  OptionTag tag;
  union {
    struct { int64_t _0; } Some;
  } payload;
};
struct Option__isize {
  OptionTag tag;
  union {
    struct { intptr_t _0; } Some;
  } payload;
};
struct Option__u8 {
  OptionTag tag;
  union {
    struct { uint8_t _0; } Some;
  } payload;
};
struct Option__i32 {
  OptionTag tag;
  union {
    struct { int32_t _0; } Some;
  } payload;
};
struct Option__i16 {
  OptionTag tag;
  union {
    struct { int16_t _0; } Some;
  } payload;
};
struct Option__i8 {
  OptionTag tag;
  union {
    struct { int8_t _0; } Some;
  } payload;
};
struct Option__f64 {
  OptionTag tag;
  union {
    struct { double _0; } Some;
  } payload;
};
struct Option__f32 {
  OptionTag tag;
  union {
    struct { float _0; } Some;
  } payload;
};

Option__ptr_u8 Option__ptr_u8__some(const uint8_t *const value);
Option__ptr_u8 Option__ptr_u8__none(void);
bool Option__ptr_u8__is_some(const Option__ptr_u8 *const self);
bool Option__ptr_u8__is_none(const Option__ptr_u8 *const self);
Option__ptr_u8 Option__ptr_u8__default_(void);
Option__usize Option__usize__some(size_t const value);
Option__usize Option__usize__none(void);
bool Option__usize__is_some(const Option__usize *const self);
bool Option__usize__is_none(const Option__usize *const self);
Option__usize Option__usize__default_(void);
void Option__usize__free(Option__usize *const self);
Option__usize Option__usize__clone(const Option__usize *const self);
bool Option__usize__eq(const Option__usize *const self, const Option__usize *const other);
uint64_t Option__usize__hash(const Option__usize *const self);
Option__String__Global Option__String__Global__some(String__Global value);
Option__String__Global Option__String__Global__none(void);
bool Option__String__Global__is_some(const Option__String__Global *const self);
bool Option__String__Global__is_none(const Option__String__Global *const self);
Option__String__Global Option__String__Global__default_(void);
void Option__String__Global__free(Option__String__Global *const self);
Option__String__Global Option__String__Global__clone(const Option__String__Global *const self);
bool Option__String__Global__eq(const Option__String__Global *const self, const Option__String__Global *const other);
uint64_t Option__String__Global__hash(const Option__String__Global *const self);
String__Global Option__String__Global__fmt(const Option__String__Global *const self);
Option__ptr_String__Global Option__ptr_String__Global__some(const String__Global *const value);
Option__ptr_String__Global Option__ptr_String__Global__none(void);
bool Option__ptr_String__Global__is_some(const Option__ptr_String__Global *const self);
bool Option__ptr_String__Global__is_none(const Option__ptr_String__Global *const self);
Option__ptr_String__Global Option__ptr_String__Global__default_(void);
Option__u32 Option__u32__some(uint32_t const value);
Option__u32 Option__u32__none(void);
bool Option__u32__is_some(const Option__u32 *const self);
bool Option__u32__is_none(const Option__u32 *const self);
Option__u32 Option__u32__default_(void);
void Option__u32__free(Option__u32 *const self);
Option__u32 Option__u32__clone(const Option__u32 *const self);
bool Option__u32__eq(const Option__u32 *const self, const Option__u32 *const other);
uint64_t Option__u32__hash(const Option__u32 *const self);
Option__ptr_u32 Option__ptr_u32__some(const uint32_t *const value);
Option__ptr_u32 Option__ptr_u32__none(void);
bool Option__ptr_u32__is_some(const Option__ptr_u32 *const self);
bool Option__ptr_u32__is_none(const Option__ptr_u32 *const self);
Option__ptr_u32 Option__ptr_u32__default_(void);
Option__bool Option__bool__some(bool const value);
Option__bool Option__bool__none(void);
bool Option__bool__is_some(const Option__bool *const self);
bool Option__bool__is_none(const Option__bool *const self);
Option__bool Option__bool__default_(void);
void Option__bool__free(Option__bool *const self);
Option__bool Option__bool__clone(const Option__bool *const self);
bool Option__bool__eq(const Option__bool *const self, const Option__bool *const other);
uint64_t Option__bool__hash(const Option__bool *const self);
Option__ptr_bool Option__ptr_bool__some(const bool *const value);
Option__ptr_bool Option__ptr_bool__none(void);
bool Option__ptr_bool__is_some(const Option__ptr_bool *const self);
bool Option__ptr_bool__is_none(const Option__ptr_bool *const self);
Option__ptr_bool Option__ptr_bool__default_(void);
Option__str Option__str__some(str const value);
Option__str Option__str__none(void);
bool Option__str__is_some(const Option__str *const self);
bool Option__str__is_none(const Option__str *const self);
Option__str Option__str__default_(void);
bool Option__str__eq(const Option__str *const self, const Option__str *const other);
uint64_t Option__str__hash(const Option__str *const self);
Option__ptr_str Option__ptr_str__some(const str *const value);
Option__ptr_str Option__ptr_str__none(void);
bool Option__ptr_str__is_some(const Option__ptr_str *const self);
bool Option__ptr_str__is_none(const Option__ptr_str *const self);
Option__ptr_str Option__ptr_str__default_(void);
Option__u64 Option__u64__some(uint64_t const value);
Option__u64 Option__u64__none(void);
bool Option__u64__is_some(const Option__u64 *const self);
bool Option__u64__is_none(const Option__u64 *const self);
Option__u64 Option__u64__default_(void);
void Option__u64__free(Option__u64 *const self);
Option__u64 Option__u64__clone(const Option__u64 *const self);
bool Option__u64__eq(const Option__u64 *const self, const Option__u64 *const other);
uint64_t Option__u64__hash(const Option__u64 *const self);
Option__ptr_u64 Option__ptr_u64__some(const uint64_t *const value);
Option__ptr_u64 Option__ptr_u64__none(void);
bool Option__ptr_u64__is_some(const Option__ptr_u64 *const self);
bool Option__ptr_u64__is_none(const Option__ptr_u64 *const self);
Option__ptr_u64 Option__ptr_u64__default_(void);
Option__u16 Option__u16__some(uint16_t const value);
Option__u16 Option__u16__none(void);
bool Option__u16__is_some(const Option__u16 *const self);
bool Option__u16__is_none(const Option__u16 *const self);
Option__u16 Option__u16__default_(void);
void Option__u16__free(Option__u16 *const self);
Option__u16 Option__u16__clone(const Option__u16 *const self);
bool Option__u16__eq(const Option__u16 *const self, const Option__u16 *const other);
uint64_t Option__u16__hash(const Option__u16 *const self);
Option__ptr_u16 Option__ptr_u16__some(const uint16_t *const value);
Option__ptr_u16 Option__ptr_u16__none(void);
bool Option__ptr_u16__is_some(const Option__ptr_u16 *const self);
bool Option__ptr_u16__is_none(const Option__ptr_u16 *const self);
Option__ptr_u16 Option__ptr_u16__default_(void);
Option__ptr_usize Option__ptr_usize__some(const size_t *const value);
Option__ptr_usize Option__ptr_usize__none(void);
bool Option__ptr_usize__is_some(const Option__ptr_usize *const self);
bool Option__ptr_usize__is_none(const Option__ptr_usize *const self);
Option__ptr_usize Option__ptr_usize__default_(void);
Option__i64 Option__i64__some(int64_t const value);
Option__i64 Option__i64__none(void);
bool Option__i64__is_some(const Option__i64 *const self);
bool Option__i64__is_none(const Option__i64 *const self);
Option__i64 Option__i64__default_(void);
void Option__i64__free(Option__i64 *const self);
Option__i64 Option__i64__clone(const Option__i64 *const self);
bool Option__i64__eq(const Option__i64 *const self, const Option__i64 *const other);
uint64_t Option__i64__hash(const Option__i64 *const self);
Option__isize Option__isize__some(intptr_t const value);
Option__isize Option__isize__none(void);
bool Option__isize__is_some(const Option__isize *const self);
bool Option__isize__is_none(const Option__isize *const self);
Option__isize Option__isize__default_(void);
void Option__isize__free(Option__isize *const self);
Option__isize Option__isize__clone(const Option__isize *const self);
bool Option__isize__eq(const Option__isize *const self, const Option__isize *const other);
uint64_t Option__isize__hash(const Option__isize *const self);
Option__u8 Option__u8__some(uint8_t const value);
Option__u8 Option__u8__none(void);
bool Option__u8__is_some(const Option__u8 *const self);
bool Option__u8__is_none(const Option__u8 *const self);
Option__u8 Option__u8__default_(void);
void Option__u8__free(Option__u8 *const self);
Option__u8 Option__u8__clone(const Option__u8 *const self);
bool Option__u8__eq(const Option__u8 *const self, const Option__u8 *const other);
uint64_t Option__u8__hash(const Option__u8 *const self);
Option__i32 Option__i32__some(int32_t const value);
Option__i32 Option__i32__none(void);
bool Option__i32__is_some(const Option__i32 *const self);
bool Option__i32__is_none(const Option__i32 *const self);
Option__i32 Option__i32__default_(void);
void Option__i32__free(Option__i32 *const self);
Option__i32 Option__i32__clone(const Option__i32 *const self);
bool Option__i32__eq(const Option__i32 *const self, const Option__i32 *const other);
uint64_t Option__i32__hash(const Option__i32 *const self);
Option__i16 Option__i16__some(int16_t const value);
Option__i16 Option__i16__none(void);
bool Option__i16__is_some(const Option__i16 *const self);
bool Option__i16__is_none(const Option__i16 *const self);
Option__i16 Option__i16__default_(void);
void Option__i16__free(Option__i16 *const self);
Option__i16 Option__i16__clone(const Option__i16 *const self);
bool Option__i16__eq(const Option__i16 *const self, const Option__i16 *const other);
uint64_t Option__i16__hash(const Option__i16 *const self);
Option__i8 Option__i8__some(int8_t const value);
Option__i8 Option__i8__none(void);
bool Option__i8__is_some(const Option__i8 *const self);
bool Option__i8__is_none(const Option__i8 *const self);
Option__i8 Option__i8__default_(void);
void Option__i8__free(Option__i8 *const self);
Option__i8 Option__i8__clone(const Option__i8 *const self);
bool Option__i8__eq(const Option__i8 *const self, const Option__i8 *const other);
uint64_t Option__i8__hash(const Option__i8 *const self);
Option__f64 Option__f64__some(double const value);
Option__f64 Option__f64__none(void);
bool Option__f64__is_some(const Option__f64 *const self);
bool Option__f64__is_none(const Option__f64 *const self);
Option__f64 Option__f64__default_(void);
void Option__f64__free(Option__f64 *const self);
Option__f64 Option__f64__clone(const Option__f64 *const self);
bool Option__f64__eq(const Option__f64 *const self, const Option__f64 *const other);
uint64_t Option__f64__hash(const Option__f64 *const self);
Option__f32 Option__f32__some(float const value);
Option__f32 Option__f32__none(void);
bool Option__f32__is_some(const Option__f32 *const self);
bool Option__f32__is_none(const Option__f32 *const self);
Option__f32 Option__f32__default_(void);
void Option__f32__free(Option__f32 *const self);
Option__f32 Option__f32__clone(const Option__f32 *const self);
bool Option__f32__eq(const Option__f32 *const self, const Option__f32 *const other);
uint64_t Option__f32__hash(const Option__f32 *const self);


#endif
