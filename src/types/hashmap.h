#ifndef HASHMAP_H
#define HASHMAP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "utils/attributes.h"

/* Slot states. calloc gives all-zero memory, so every slot starts EMPTY. */
enum hm_slot { HM_EMPTY = 0, HM_OCCUPIED = 1, HM_DELETED = 2 };

/* HM_DECLARE emits only the struct type (for use in headers / aggregate members). The functions
 * need HASH/EQ, so they live in HM_DEFINE; every map in this codebase is defined and used in one
 * TU, so they are `static inline` there. Hot path (`_get`/`_insert`) is ALWAYS_INLINE like
 * vector.h's `_push`; the costly resize (`_grow`) stays out-of-line, exactly as `_reserve` does. */
#define HM_DECLARE(K, V, Name)                                                                                         \
  typedef struct {                                                                                                     \
      K *keys;                                                                                                         \
      V *vals;                                                                                                         \
      uint8_t *state;                                                                                                  \
      size_t len; /* live entries                       */                                                             \
      size_t used; /* live entries + tombstones          */                                                            \
      size_t cap; /* slot count, always a power of two  */                                                             \
  } Name;

#define HM_DEFINE(K, V, Name, HASH, EQ)                                                                                \
  ALWAYS_INLINE MAYBE_UNUSED Name Name##_init(void) {                                                                  \
    return (Name){0};                                                                                                  \
  }                                                                                                                    \
                                                                                                                       \
  static inline MAYBE_UNUSED void Name##_deinit(Name *m) {                                                             \
    free(m->keys);                                                                                                     \
    free(m->vals);                                                                                                     \
    free(m->state);                                                                                                    \
    *m = (Name){0};                                                                                                    \
  }                                                                                                                    \
                                                                                                                       \
  static MAYBE_UNUSED bool Name##_grow(Name *m, size_t new_cap) {                                                      \
    K *keys = calloc(new_cap, sizeof *keys);                                                                           \
    V *vals = malloc(new_cap * sizeof *vals);                                                                          \
    uint8_t *state = calloc(new_cap, sizeof *state);                                                                   \
    if (!keys || !vals || !state) {                                                                                    \
      free(keys);                                                                                                      \
      free(vals);                                                                                                      \
      free(state);                                                                                                     \
      return false;                                                                                                    \
    }                                                                                                                  \
    const size_t mask = new_cap - 1;                                                                                   \
    for (size_t i = 0; i < m->cap; i++) {                                                                              \
      if (m->state[i] != HM_OCCUPIED)                                                                                  \
        continue;                                                                                                      \
      size_t idx = HASH(m->keys[i]) & mask;                                                                            \
      while (state[idx] == HM_OCCUPIED)                                                                                \
        idx = (idx + 1) & mask;                                                                                        \
      keys[idx] = m->keys[i];                                                                                          \
      vals[idx] = m->vals[i];                                                                                          \
      state[idx] = HM_OCCUPIED;                                                                                        \
    }                                                                                                                  \
    free(m->keys);                                                                                                     \
    free(m->vals);                                                                                                     \
    free(m->state);                                                                                                    \
    m->keys = keys;                                                                                                    \
    m->vals = vals;                                                                                                    \
    m->state = state;                                                                                                  \
    m->cap = new_cap;                                                                                                  \
    m->used = m->len;                                                                                                  \
    return true;                                                                                                       \
  }                                                                                                                    \
                                                                                                                       \
  ALWAYS_INLINE MAYBE_UNUSED bool Name##_insert(Name *m, K key, V val) {                                               \
    if (m->cap == 0 && !Name##_grow(m, 8))                                                                             \
      return false;                                                                                                    \
    /* keep load factor under 0.75 of `used` so an EMPTY slot always exists */                                         \
    if (4 * (m->used + 1) >= 3 * m->cap && !Name##_grow(m, m->cap * 2))                                                \
      return false;                                                                                                    \
    const size_t mask = m->cap - 1;                                                                                    \
    size_t idx = HASH(key) & mask;                                                                                     \
    size_t tomb = m->cap; /* sentinel: no tombstone seen yet */                                                        \
    while (m->state[idx] != HM_EMPTY) {                                                                                \
      if (m->state[idx] == HM_OCCUPIED && EQ(m->keys[idx], key)) {                                                     \
        m->vals[idx] = val; /* key exists -> overwrite value */                                                        \
        return true;                                                                                                   \
      }                                                                                                                \
      if (m->state[idx] == HM_DELETED && tomb == m->cap)                                                               \
        tomb = idx;                                                                                                    \
      idx = (idx + 1) & mask;                                                                                          \
    }                                                                                                                  \
    if (tomb != m->cap)                                                                                                \
      idx = tomb; /* reuse a tombstone; `used` already counted it */                                                   \
    else                                                                                                               \
      m->used++; /* consuming a fresh EMPTY slot */                                                                    \
    m->keys[idx] = key;                                                                                                \
    m->vals[idx] = val;                                                                                                \
    m->state[idx] = HM_OCCUPIED;                                                                                       \
    m->len++;                                                                                                          \
    return true;                                                                                                       \
  }                                                                                                                    \
                                                                                                                       \
  ALWAYS_INLINE MAYBE_UNUSED bool Name##_get(const Name *m, K key, V *out) {                                           \
    if (m->cap == 0)                                                                                                   \
      return false;                                                                                                    \
    const size_t mask = m->cap - 1;                                                                                    \
    size_t idx = HASH(key) & mask;                                                                                     \
    while (m->state[idx] != HM_EMPTY) {                                                                                \
      if (m->state[idx] == HM_OCCUPIED && EQ(m->keys[idx], key)) {                                                     \
        if (out)                                                                                                       \
          *out = m->vals[idx];                                                                                         \
        return true;                                                                                                   \
      }                                                                                                                \
      idx = (idx + 1) & mask;                                                                                          \
    }                                                                                                                  \
    return false;                                                                                                      \
  }                                                                                                                    \
                                                                                                                       \
  static inline MAYBE_UNUSED bool Name##_remove(Name *m, K key) {                                                      \
    if (m->cap == 0)                                                                                                   \
      return false;                                                                                                    \
    const size_t mask = m->cap - 1;                                                                                    \
    size_t idx = HASH(key) & mask;                                                                                     \
    while (m->state[idx] != HM_EMPTY) {                                                                                \
      if (m->state[idx] == HM_OCCUPIED && EQ(m->keys[idx], key)) {                                                     \
        m->state[idx] = HM_DELETED;                                                                                    \
        m->len--;                                                                                                      \
        return true;                                                                                                   \
      }                                                                                                                \
      idx = (idx + 1) & mask;                                                                                          \
    }                                                                                                                  \
    return false;                                                                                                      \
  }

#endif // HASHMAP_H
