#ifndef SUPER_STRING_H
#define SUPER_STRING_H

#include "super_rt.h"
typedef struct SliceMut__u8 SliceMut__u8;
typedef struct Slice__u8 Slice__u8;
typedef struct Option__ptr_u8 Option__ptr_u8;
typedef struct Range__usize Range__usize;
typedef struct str str;
typedef struct Global Global;
typedef struct String__Global String__Global;
typedef struct Bytes Bytes;
typedef struct Chars Chars;
typedef struct Split Split;
typedef struct Lines Lines;



size_t string__copy(SliceMut__u8 const dst, Slice__u8 const src);
size_t string__move_bytes(SliceMut__u8 const dst, Slice__u8 const src);
void string__fill(SliceMut__u8 const dst, uint8_t const value);
bool string__equal(Slice__u8 const a, Slice__u8 const b);


#endif
