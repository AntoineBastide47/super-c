#ifndef SUPER___STD__SLICE_H
#define SUPER___STD__SLICE_H

#include "../super_rt.h"
typedef struct Option Option;
typedef struct Range__usize Range__usize;
typedef struct Option__ptr_u8 Option__ptr_u8;
typedef struct Option__ptr_u32 Option__ptr_u32;
typedef struct Option__ptr_bool Option__ptr_bool;
typedef struct Option__ptr_u64 Option__ptr_u64;
typedef struct Option__ptr_u16 Option__ptr_u16;
typedef struct Option__ptr_usize Option__ptr_usize;

typedef struct Slice__u8 Slice__u8;
typedef struct Slice__u32 Slice__u32;
typedef struct SliceMut__u32 SliceMut__u32;
typedef struct Slice__bool Slice__bool;
typedef struct SliceMut__bool SliceMut__bool;
typedef struct SliceMut__u8 SliceMut__u8;
typedef struct Slice__u64 Slice__u64;
typedef struct SliceMut__u64 SliceMut__u64;
typedef struct Slice__u16 Slice__u16;
typedef struct SliceMut__u16 SliceMut__u16;
typedef struct Slice__usize Slice__usize;
typedef struct SliceMut__usize SliceMut__usize;

struct Slice__u8 {
  const uint8_t *ptr;
  size_t len;
};
struct Slice__u32 {
  const uint32_t *ptr;
  size_t len;
};
struct SliceMut__u32 {
  uint32_t *ptr;
  size_t len;
};
struct Slice__bool {
  const bool *ptr;
  size_t len;
};
struct SliceMut__bool {
  bool *ptr;
  size_t len;
};
struct SliceMut__u8 {
  uint8_t *ptr;
  size_t len;
};
struct Slice__u64 {
  const uint64_t *ptr;
  size_t len;
};
struct SliceMut__u64 {
  uint64_t *ptr;
  size_t len;
};
struct Slice__u16 {
  const uint16_t *ptr;
  size_t len;
};
struct SliceMut__u16 {
  uint16_t *ptr;
  size_t len;
};
struct Slice__usize {
  const size_t *ptr;
  size_t len;
};
struct SliceMut__usize {
  size_t *ptr;
  size_t len;
};

size_t Slice__u8__len(const Slice__u8 *const self);
const uint8_t *Slice__u8__as_ptr(const Slice__u8 *const self);
const uint8_t *Slice__u8__index(const Slice__u8 *const self, size_t const i);
Slice__u8 Slice__u8__index_range(const Slice__u8 *const self, Range__usize const r);
size_t Slice__u32__len(const Slice__u32 *const self);
const uint32_t *Slice__u32__as_ptr(const Slice__u32 *const self);
const uint32_t *Slice__u32__index(const Slice__u32 *const self, size_t const i);
Slice__u32 Slice__u32__index_range(const Slice__u32 *const self, Range__usize const r);
size_t SliceMut__u32__len(const SliceMut__u32 *const self);
uint32_t *SliceMut__u32__as_mut_ptr(const SliceMut__u32 *const self);
const uint32_t *SliceMut__u32__index(const SliceMut__u32 *const self, size_t const i);
Slice__u32 SliceMut__u32__index_range(const SliceMut__u32 *const self, Range__usize const r);
uint32_t *SliceMut__u32__index_mut(SliceMut__u32 *const self, size_t const i);
SliceMut__u32 SliceMut__u32__index_range_mut(SliceMut__u32 *const self, Range__usize const r);
size_t Slice__bool__len(const Slice__bool *const self);
const bool *Slice__bool__as_ptr(const Slice__bool *const self);
const bool *Slice__bool__index(const Slice__bool *const self, size_t const i);
Slice__bool Slice__bool__index_range(const Slice__bool *const self, Range__usize const r);
size_t SliceMut__bool__len(const SliceMut__bool *const self);
bool *SliceMut__bool__as_mut_ptr(const SliceMut__bool *const self);
const bool *SliceMut__bool__index(const SliceMut__bool *const self, size_t const i);
Slice__bool SliceMut__bool__index_range(const SliceMut__bool *const self, Range__usize const r);
bool *SliceMut__bool__index_mut(SliceMut__bool *const self, size_t const i);
SliceMut__bool SliceMut__bool__index_range_mut(SliceMut__bool *const self, Range__usize const r);
size_t SliceMut__u8__len(const SliceMut__u8 *const self);
uint8_t *SliceMut__u8__as_mut_ptr(const SliceMut__u8 *const self);
const uint8_t *SliceMut__u8__index(const SliceMut__u8 *const self, size_t const i);
Slice__u8 SliceMut__u8__index_range(const SliceMut__u8 *const self, Range__usize const r);
uint8_t *SliceMut__u8__index_mut(SliceMut__u8 *const self, size_t const i);
SliceMut__u8 SliceMut__u8__index_range_mut(SliceMut__u8 *const self, Range__usize const r);
size_t Slice__u64__len(const Slice__u64 *const self);
const uint64_t *Slice__u64__as_ptr(const Slice__u64 *const self);
const uint64_t *Slice__u64__index(const Slice__u64 *const self, size_t const i);
Slice__u64 Slice__u64__index_range(const Slice__u64 *const self, Range__usize const r);
size_t SliceMut__u64__len(const SliceMut__u64 *const self);
uint64_t *SliceMut__u64__as_mut_ptr(const SliceMut__u64 *const self);
const uint64_t *SliceMut__u64__index(const SliceMut__u64 *const self, size_t const i);
Slice__u64 SliceMut__u64__index_range(const SliceMut__u64 *const self, Range__usize const r);
uint64_t *SliceMut__u64__index_mut(SliceMut__u64 *const self, size_t const i);
SliceMut__u64 SliceMut__u64__index_range_mut(SliceMut__u64 *const self, Range__usize const r);
size_t Slice__u16__len(const Slice__u16 *const self);
const uint16_t *Slice__u16__as_ptr(const Slice__u16 *const self);
const uint16_t *Slice__u16__index(const Slice__u16 *const self, size_t const i);
Slice__u16 Slice__u16__index_range(const Slice__u16 *const self, Range__usize const r);
size_t SliceMut__u16__len(const SliceMut__u16 *const self);
uint16_t *SliceMut__u16__as_mut_ptr(const SliceMut__u16 *const self);
const uint16_t *SliceMut__u16__index(const SliceMut__u16 *const self, size_t const i);
Slice__u16 SliceMut__u16__index_range(const SliceMut__u16 *const self, Range__usize const r);
uint16_t *SliceMut__u16__index_mut(SliceMut__u16 *const self, size_t const i);
SliceMut__u16 SliceMut__u16__index_range_mut(SliceMut__u16 *const self, Range__usize const r);
size_t Slice__usize__len(const Slice__usize *const self);
const size_t *Slice__usize__as_ptr(const Slice__usize *const self);
const size_t *Slice__usize__index(const Slice__usize *const self, size_t const i);
Slice__usize Slice__usize__index_range(const Slice__usize *const self, Range__usize const r);
size_t SliceMut__usize__len(const SliceMut__usize *const self);
size_t *SliceMut__usize__as_mut_ptr(const SliceMut__usize *const self);
const size_t *SliceMut__usize__index(const SliceMut__usize *const self, size_t const i);
Slice__usize SliceMut__usize__index_range(const SliceMut__usize *const self, Range__usize const r);
size_t *SliceMut__usize__index_mut(SliceMut__usize *const self, size_t const i);
SliceMut__usize SliceMut__usize__index_range_mut(SliceMut__usize *const self, Range__usize const r);


#endif
