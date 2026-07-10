#ifndef SUPER_UTILS__ERRORS_H
#define SUPER_UTILS__ERRORS_H

#include "../super_rt.h"
typedef struct Global Global;
typedef struct String__Global String__Global;
typedef struct Vector__String__Global__Global Vector__String__Global__Global;
typedef struct Vector__u32__Global Vector__u32__Global;
typedef struct str str;
typedef struct Bytes Bytes;
typedef struct Chars Chars;
typedef struct Split Split;
typedef struct Lines Lines;
typedef struct Slice__u8 Slice__u8;
typedef struct Range__usize Range__usize;
typedef struct Option__String__Global Option__String__Global;
typedef struct Option__ptr_String__Global Option__ptr_String__Global;
typedef struct Option__usize Option__usize;
typedef struct Result__usize__usize Result__usize__usize;
typedef struct VecIter__String__Global VecIter__String__Global;
typedef struct Slice__String__Global Slice__String__Global;
typedef struct SliceMut__String__Global SliceMut__String__Global;
typedef struct Option__u32 Option__u32;
typedef struct Option__ptr_u32 Option__ptr_u32;
typedef struct VecIter__u32 VecIter__u32;
typedef struct Slice__u32 Slice__u32;
typedef struct SliceMut__u32 SliceMut__u32;
typedef struct Option__ptr_u8 Option__ptr_u8;
#include "../__std/vector.h"

typedef struct utils__errors__Errors utils__errors__Errors;

struct utils__errors__Errors {
  Vector__String__Global__Global errors;
  Vector__String__Global__Global notes;
  Vector__u32__Global starts;
  Vector__u32__Global lens;
};

void utils__errors__oom(void);
str utils__errors__cstr(const char *const p);
str utils__errors__span_str(const uint8_t *const src, uint32_t const start, uint32_t const end);
utils__errors__Errors utils__errors__Errors__new(void);
bool utils__errors__Errors__has_errors(const utils__errors__Errors *const self);
__attribute__((cold, noinline)) void utils__errors__Errors__emit(utils__errors__Errors *const self, uint32_t const at, uint32_t const len, String__Global msg);
__attribute__((cold, noinline)) void utils__errors__Errors__note(utils__errors__Errors *const self, String__Global msg);
__attribute__((cold, noinline)) void utils__errors__Errors__finalize(utils__errors__Errors *const self, const uint8_t *const source, size_t const len, const char *const file);
__attribute__((cold, noinline)) void utils__errors__Errors__log(const utils__errors__Errors *const self);
void utils__errors__Errors__free(utils__errors__Errors *const self);

__attribute__((unused)) static const size_t utils__errors__ERRORS_MAX = 256ULL;

#endif
