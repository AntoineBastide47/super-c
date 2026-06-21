#ifndef VECTORS_H
#define VECTORS_H

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#include "utils/attributes.h"

#define VEC_INIT {0}
#define VEC_DEINIT(v)                                                                                                  \
  free(v.data);                                                                                                        \
  v.data = NULL;                                                                                                       \
  v.len = 0;                                                                                                           \
  v.cap = 0;

#define VEC_DEINIT_REF(v)                                                                                              \
  do {                                                                                                                 \
    free((v)->data);                                                                                                   \
    (v)->data = NULL;                                                                                                  \
    (v)->len = 0;                                                                                                      \
    (v)->cap = 0;                                                                                                      \
  } while (0)

#define VEC_DECLARE(T, Name)                                                                                           \
  typedef struct {                                                                                                     \
      T *data;                                                                                                         \
      size_t len;                                                                                                      \
      size_t cap;                                                                                                      \
  } Name;                                                                                                              \
                                                                                                                       \
  bool Name##_reserve(Name *v, const size_t needed);                                                                   \
                                                                                                                       \
  ALWAYS_INLINE Name Name##_init() {                                                                                   \
    return (Name)VEC_INIT;                                                                                             \
  }                                                                                                                    \
                                                                                                                       \
  ALWAYS_INLINE bool Name##_push(Name *v, T value) {                                                                   \
    if (UNLIKELY(!Name##_reserve(v, v->len + 1)))                                                                      \
      return false;                                                                                                    \
    v->data[v->len++] = value;                                                                                         \
    return true;                                                                                                       \
  }                                                                                                                    \
                                                                                                                       \
  ALWAYS_INLINE bool Name##_pop(Name *v, T *out) {                                                                     \
    if (v->len == 0)                                                                                                   \
      return false;                                                                                                    \
    *out = v->data[--v->len];                                                                                          \
    return true;                                                                                                       \
  }                                                                                                                    \
                                                                                                                       \
  ALWAYS_INLINE size_t Name##_partition_point(const Name *v, bool (*pred)(T item, void *ctx), void *ctx) {             \
    size_t left = 0;                                                                                                   \
    size_t right = v->len;                                                                                             \
                                                                                                                       \
    while (left < right) {                                                                                             \
      size_t mid = left + (right - left) / 2;                                                                          \
                                                                                                                       \
      if (pred(v->data[mid], ctx))                                                                                     \
        left = mid + 1;                                                                                                \
      else                                                                                                             \
        right = mid;                                                                                                   \
    }                                                                                                                  \
                                                                                                                       \
    return left;                                                                                                       \
  }

#define VEC_DEFINE(T, Name)                                                                                            \
  bool Name##_reserve(Name *v, const size_t needed) {                                                                  \
    if (needed <= v->cap)                                                                                              \
      return true;                                                                                                     \
    size_t new_cap = v->cap ? v->cap * 2 : 8;                                                                          \
    while (new_cap < needed)                                                                                           \
      new_cap *= 2;                                                                                                    \
    T *new_data = realloc(v->data, new_cap * sizeof *v->data);                                                         \
    if (!new_data)                                                                                                     \
      return false;                                                                                                    \
    v->data = new_data;                                                                                                \
    v->cap = new_cap;                                                                                                  \
    return true;                                                                                                       \
  }


VEC_DECLARE(uint32_t, U32_Vec)
VEC_DECLARE(char *, String_Vec)
VEC_DECLARE(bool, Bool_Vec)

#endif // VECTORS_H