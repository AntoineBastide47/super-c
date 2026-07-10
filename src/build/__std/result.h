#ifndef SUPER___STD__RESULT_H
#define SUPER___STD__RESULT_H

#include "../super_rt.h"
typedef struct str str;
typedef struct Option Option;
typedef struct Global Global;
typedef struct String__Global String__Global;
typedef struct Bytes Bytes;
typedef struct Chars Chars;
typedef struct Split Split;
typedef struct Lines Lines;
typedef struct Slice__u8 Slice__u8;
typedef struct Range__usize Range__usize;
typedef struct Option__ptr_u8 Option__ptr_u8;
typedef struct Option__usize Option__usize;

#ifndef SUPER_ENUMTAG_Result
#define SUPER_ENUMTAG_Result
typedef enum { Result_Ok, Result_Err } ResultTag;
#endif
typedef struct Result__usize__usize Result__usize__usize;

struct Result__usize__usize {
  ResultTag tag;
  union {
    struct { size_t _0; } Ok;
    struct { size_t _0; } Err;
  } payload;
};

bool Result__usize__usize__is_ok(const Result__usize__usize *const self);
void Result__usize__usize__free(Result__usize__usize *const self);
Result__usize__usize Result__usize__usize__clone(const Result__usize__usize *const self);
bool Result__usize__usize__eq(const Result__usize__usize *const self, const Result__usize__usize *const other);


#endif
