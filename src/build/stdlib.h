#ifndef SUPER_STDLIB_H
#define SUPER_STDLIB_H

#include "super_rt.h"
typedef struct Global Global;
typedef struct String__Global String__Global;
typedef struct Option__String__Global Option__String__Global;
typedef struct Option Option;
typedef struct str str;
typedef struct Bytes Bytes;
typedef struct Chars Chars;
typedef struct Split Split;
typedef struct Lines Lines;
typedef struct Slice__u8 Slice__u8;
typedef struct Range__usize Range__usize;
typedef struct Option__ptr_u8 Option__ptr_u8;



Option__String__Global stdlib__get_env(String__Global *const name);
const char *stdlib__getenv(str const name);
int32_t stdlib__system(str const command);
int64_t stdlib__parse_int(String__Global *const s);
double stdlib__parse_float(String__Global *const s);


#endif
