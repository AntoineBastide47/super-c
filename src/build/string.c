#include "string.h"
#include "__std/core.h"
#include "__std/interfaces.h"
#include "__std/option.h"
#include "__std/range.h"
#include "__std/slice.h"
#include "__std/str.h"
#include "__std/string.h"


size_t string__copy(SliceMut__u8 const dst, Slice__u8 const src) {
  size_t n = SliceMut__u8__len(&dst);
  if (Slice__u8__len(&src) < n) {
    (n = Slice__u8__len(&src));
  }
  if (n > 0ULL) {
    memcpy(((void *)SliceMut__u8__as_mut_ptr(&dst)), ((const void *)Slice__u8__as_ptr(&src)), n);
  }
  return n;
}

size_t string__move_bytes(SliceMut__u8 const dst, Slice__u8 const src) {
  size_t n = SliceMut__u8__len(&dst);
  if (Slice__u8__len(&src) < n) {
    (n = Slice__u8__len(&src));
  }
  if (n > 0ULL) {
    memmove(((void *)SliceMut__u8__as_mut_ptr(&dst)), ((const void *)Slice__u8__as_ptr(&src)), n);
  }
  return n;
}

void string__fill(SliceMut__u8 const dst, uint8_t const value) {
  if (SliceMut__u8__len(&dst) > 0ULL) {
    memset(((void *)SliceMut__u8__as_mut_ptr(&dst)), ((int32_t)value), SliceMut__u8__len(&dst));
  }
}

bool string__equal(Slice__u8 const a, Slice__u8 const b) {
  if (Slice__u8__len(&a) != Slice__u8__len(&b)) {
    return false;
  }
  if (Slice__u8__len(&a) == 0ULL) {
    return true;
  }
  return (memcmp(((const void *)Slice__u8__as_ptr(&a)), ((const void *)Slice__u8__as_ptr(&b)), Slice__u8__len(&a)) == 0);
}

