#ifndef SUPER_STDIO_H
#define SUPER_STDIO_H

#include "super_rt.h"
typedef struct Global Global;
typedef struct String__Global String__Global;
typedef struct Option__stdio__File Option__stdio__File;
typedef struct Option Option;
typedef struct Slice__u8 Slice__u8;
typedef struct str str;
typedef struct Bytes Bytes;
typedef struct Chars Chars;
typedef struct Split Split;
typedef struct Lines Lines;
typedef struct Range__usize Range__usize;
typedef struct Option__ptr_u8 Option__ptr_u8;
#include "__std/option.h"

typedef struct stdio__File stdio__File;
typedef struct Option__stdio__File Option__stdio__File;

struct stdio__File {
  FILE *handle;
};
struct Option__stdio__File {
  OptionTag tag;
  union {
    struct { stdio__File _0; } Some;
  } payload;
};

Option__stdio__File stdio__File__open(String__Global *const path, String__Global *const mode);
size_t stdio__File__write_str(stdio__File *const self, const String__Global *const text);
String__Global stdio__File__read_all(stdio__File *const self);
int32_t stdio__File__flush(stdio__File *const self);
void stdio__File__close(stdio__File *const self);
FILE *stdio__fopen(str const path, str const mode);
FILE *stdio__stdin(void);
FILE *stdio__stdout(void);
FILE *stdio__stderr(void);
Option__stdio__File Option__stdio__File__some(stdio__File value);
Option__stdio__File Option__stdio__File__none(void);
bool Option__stdio__File__is_some(const Option__stdio__File *const self);
bool Option__stdio__File__is_none(const Option__stdio__File *const self);
Option__stdio__File Option__stdio__File__default_(void);
void Option__stdio__File__free(Option__stdio__File *const self);

__attribute__((unused)) static const int32_t stdio__SEEK_SET = 0;
__attribute__((unused)) static const int32_t stdio__SEEK_CUR = 1;
__attribute__((unused)) static const int32_t stdio__SEEK_END = 2;

#endif
