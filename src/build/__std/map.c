#include "../__std/map.h"
#include "../ast/ast.h"
#include "../__std/core.h"
#include "../__std/interfaces.h"
#include "../__std/option.h"

_Static_assert(sizeof(MapValues__u32) == 32 && _Alignof(MapValues__u32) == 8, "super-c layout model mismatch: MapValues__u32");
_Static_assert(sizeof(MapKeys__u64) == 32 && _Alignof(MapKeys__u64) == 8, "super-c layout model mismatch: MapKeys__u64");
_Static_assert(sizeof(Map__u64__u32__Global) == 40 && _Alignof(Map__u64__u32__Global) == 8, "super-c layout model mismatch: Map__u64__u32__Global");
_Static_assert(sizeof(Map__u32__u32__Global) == 40 && _Alignof(Map__u32__u32__Global) == 8, "super-c layout model mismatch: Map__u32__u32__Global");
_Static_assert(sizeof(MapKeys__u32) == 32 && _Alignof(MapKeys__u32) == 8, "super-c layout model mismatch: MapKeys__u32");

static __attribute__((unused)) size_t Map__u64__u32__Global__slot(const Map__u64__u32__Global *const self, const uint64_t *const key);
static __attribute__((unused)) void Map__u64__u32__Global__grow(Map__u64__u32__Global *const self);
static __attribute__((unused)) size_t Map__u32__u32__Global__slot(const Map__u32__u32__Global *const self, const uint32_t *const key);
static __attribute__((unused)) void Map__u32__u32__Global__grow(Map__u32__u32__Global *const self);

Option__ptr_u32 MapValues__u32__next(MapValues__u32 *const self) {
  while (self->idx < self->cap) {
    const size_t i = self->idx;
    (self->idx = (self->idx + 1ULL));
    if (self->used[i] != 0U) {
      return (Option__ptr_u32){ .tag = Option_Some, .payload.Some = { (&self->vals[i]) } };
    }
  }
  return (Option__ptr_u32){ .tag = Option_None };
}

Option__ptr_u64 MapKeys__u64__next(MapKeys__u64 *const self) {
  while (self->idx < self->cap) {
    const size_t i = self->idx;
    (self->idx = (self->idx + 1ULL));
    if (self->used[i] != 0U) {
      return (Option__ptr_u64){ .tag = Option_Some, .payload.Some = { (&self->keys[i]) } };
    }
  }
  return (Option__ptr_u64){ .tag = Option_None };
}

Map__u64__u32__Global Map__u64__u32__Global__new_in(Global const alloc) {
  return (Map__u64__u32__Global){ .keys = NULL, .vals = NULL, .used = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

size_t Map__u64__u32__Global__len(const Map__u64__u32__Global *const self) {
  return self->len;
}

bool Map__u64__u32__Global__is_empty(const Map__u64__u32__Global *const self) {
  return (self->len == 0ULL);
}

static __attribute__((unused)) size_t Map__u64__u32__Global__slot(const Map__u64__u32__Global *const self, const uint64_t *const key) {
  size_t i = ({ size_t __sc0 = ((size_t)u64__hash(key)); size_t __sc1 = self->cap; if (__sc1 == 0) { __sc_panic("divide by zero"); } (__sc0 % __sc1); });
  while (self->used[i] != 0U) {
    if (u64__eq(&self->keys[i], key)) {
      return i;
    }
    (i = (i + 1ULL));
    if (i >= self->cap) {
      (i = 0ULL);
    }
  }
  return i;
}

static __attribute__((unused)) void Map__u64__u32__Global__grow(Map__u64__u32__Global *const self) {
  size_t newcap = (self->cap * 2ULL);
  if (newcap < 8ULL) {
    (newcap = 8ULL);
  }
  uint64_t *const oldkeys = self->keys;
  uint32_t *const oldvals = self->vals;
  uint8_t *const oldused = self->used;
  const size_t oldcap = self->cap;
  (self->keys = ((uint64_t *)Global__alloc(&self->alloc, (newcap * sizeof(uint64_t)), _Alignof(uint64_t))));
  (self->vals = ((uint32_t *)Global__alloc(&self->alloc, (newcap * sizeof(uint32_t)), _Alignof(uint32_t))));
  (self->used = ((uint8_t *)Global__alloc(&self->alloc, newcap, 1ULL)));
  memset(((void *)self->used), 0, newcap);
  (self->cap = newcap);
  (self->len = 0ULL);
  for (size_t i = 0ULL; i < oldcap; i++) {
    if (oldused[i] == 1U) {
      const size_t j = Map__u64__u32__Global__slot(self, (&oldkeys[i]));
      (self->keys[j] = oldkeys[i]);
      (self->vals[j] = oldvals[i]);
      (self->used[j] = 1U);
      (self->len = (self->len + 1ULL));
    }
  }
  if (oldcap > 0ULL) {
    Global__dealloc(&self->alloc, ((void *)oldkeys), (oldcap * sizeof(uint64_t)), _Alignof(uint64_t));
    Global__dealloc(&self->alloc, ((void *)oldvals), (oldcap * sizeof(uint32_t)), _Alignof(uint32_t));
    Global__dealloc(&self->alloc, ((void *)oldused), oldcap, 1ULL);
  }
}

void Map__u64__u32__Global__insert(Map__u64__u32__Global *const self, uint64_t const key, uint32_t const value) {
  if ((self->cap == 0ULL) || (((self->len + 1ULL) * 4ULL) >= (self->cap * 3ULL))) {
    Map__u64__u32__Global__grow(self);
  }
  const size_t i = Map__u64__u32__Global__slot(self, (&key));
  if (self->used[i] != 0U) {
    __auto_type dup = key;
    (void)(dup);
    (void)(self->vals[i]);
    (self->vals[i] = value);
    return;
  }
  (self->keys[i] = key);
  (self->vals[i] = value);
  (self->used[i] = 1U);
  (self->len = (self->len + 1ULL));
}

Option__ptr_u32 Map__u64__u32__Global__get(const Map__u64__u32__Global *const self, const uint64_t *const key) {
  if (self->cap == 0ULL) {
    return (Option__ptr_u32){ .tag = Option_None };
  }
  const size_t i = Map__u64__u32__Global__slot(self, key);
  if (self->used[i] == 0U) {
    return (Option__ptr_u32){ .tag = Option_None };
  }
  return (Option__ptr_u32){ .tag = Option_Some, .payload.Some = { (&self->vals[i]) } };
}

bool Map__u64__u32__Global__contains_key(const Map__u64__u32__Global *const self, const uint64_t *const key) {
  return ({ __auto_type __sc2 = Map__u64__u32__Global__get(self, key); Option__ptr_u32__is_some(&__sc2); });
}

Option__u32 Map__u64__u32__Global__remove(Map__u64__u32__Global *const self, const uint64_t *const key) {
  if (self->cap == 0ULL) {
    return (Option__u32){ .tag = Option_None };
  }
  const size_t i = Map__u64__u32__Global__slot(self, key);
  if (self->used[i] == 0U) {
    return (Option__u32){ .tag = Option_None };
  }
  const __auto_type removed = self->vals[i];
  (void)(self->keys[i]);
  (self->used[i] = 0U);
  (self->len = (self->len - 1ULL));
  size_t j = (i + 1ULL);
  if (j >= self->cap) {
    (j = 0ULL);
  }
  while (self->used[j] == 1U) {
    const __auto_type k = self->keys[j];
    const __auto_type v = self->vals[j];
    (self->used[j] = 0U);
    (self->len = (self->len - 1ULL));
    Map__u64__u32__Global__insert(self, k, v);
    (j = (j + 1ULL));
    if (j >= self->cap) {
      (j = 0ULL);
    }
  }
  return (Option__u32){ .tag = Option_Some, .payload.Some = { removed } };
}

Map__u64__u32__Global Map__u64__u32__Global__new(void) {
  return Map__u64__u32__Global__new_in(Global__default_());
}

void Map__u64__u32__Global__free(Map__u64__u32__Global *const self) {
  for (size_t i = 0ULL; i < self->cap; i++) {
    if (self->used[i] != 0U) {
      (void)(self->keys[i]);
      (void)(self->vals[i]);
    }
  }
  Global__dealloc(&self->alloc, ((void *)self->keys), (self->cap * sizeof(uint64_t)), _Alignof(uint64_t));
  Global__dealloc(&self->alloc, ((void *)self->vals), (self->cap * sizeof(uint32_t)), _Alignof(uint32_t));
  Global__dealloc(&self->alloc, ((void *)self->used), self->cap, 1ULL);
  (self->keys = NULL);
  (self->vals = NULL);
  (self->used = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Map__u64__u32__Global Map__u64__u32__Global__default_(void) {
  return Map__u64__u32__Global__new();
}

MapKeys__u64 Map__u64__u32__Global__keys(const Map__u64__u32__Global *const self) {
  return (MapKeys__u64){ .keys = ((const uint64_t *)self->keys), .used = ((const uint8_t *)self->used), .idx = 0ULL, .cap = self->cap };
}

Map__u32__u32__Global Map__u32__u32__Global__new_in(Global const alloc) {
  return (Map__u32__u32__Global){ .keys = NULL, .vals = NULL, .used = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

size_t Map__u32__u32__Global__len(const Map__u32__u32__Global *const self) {
  return self->len;
}

bool Map__u32__u32__Global__is_empty(const Map__u32__u32__Global *const self) {
  return (self->len == 0ULL);
}

static __attribute__((unused)) size_t Map__u32__u32__Global__slot(const Map__u32__u32__Global *const self, const uint32_t *const key) {
  size_t i = ({ size_t __sc3 = ((size_t)u32__hash(key)); size_t __sc4 = self->cap; if (__sc4 == 0) { __sc_panic("divide by zero"); } (__sc3 % __sc4); });
  while (self->used[i] != 0U) {
    if (u32__eq(&self->keys[i], key)) {
      return i;
    }
    (i = (i + 1ULL));
    if (i >= self->cap) {
      (i = 0ULL);
    }
  }
  return i;
}

static __attribute__((unused)) void Map__u32__u32__Global__grow(Map__u32__u32__Global *const self) {
  size_t newcap = (self->cap * 2ULL);
  if (newcap < 8ULL) {
    (newcap = 8ULL);
  }
  uint32_t *const oldkeys = self->keys;
  uint32_t *const oldvals = self->vals;
  uint8_t *const oldused = self->used;
  const size_t oldcap = self->cap;
  (self->keys = ((uint32_t *)Global__alloc(&self->alloc, (newcap * sizeof(uint32_t)), _Alignof(uint32_t))));
  (self->vals = ((uint32_t *)Global__alloc(&self->alloc, (newcap * sizeof(uint32_t)), _Alignof(uint32_t))));
  (self->used = ((uint8_t *)Global__alloc(&self->alloc, newcap, 1ULL)));
  memset(((void *)self->used), 0, newcap);
  (self->cap = newcap);
  (self->len = 0ULL);
  for (size_t i = 0ULL; i < oldcap; i++) {
    if (oldused[i] == 1U) {
      const size_t j = Map__u32__u32__Global__slot(self, (&oldkeys[i]));
      (self->keys[j] = oldkeys[i]);
      (self->vals[j] = oldvals[i]);
      (self->used[j] = 1U);
      (self->len = (self->len + 1ULL));
    }
  }
  if (oldcap > 0ULL) {
    Global__dealloc(&self->alloc, ((void *)oldkeys), (oldcap * sizeof(uint32_t)), _Alignof(uint32_t));
    Global__dealloc(&self->alloc, ((void *)oldvals), (oldcap * sizeof(uint32_t)), _Alignof(uint32_t));
    Global__dealloc(&self->alloc, ((void *)oldused), oldcap, 1ULL);
  }
}

void Map__u32__u32__Global__insert(Map__u32__u32__Global *const self, uint32_t const key, uint32_t const value) {
  if ((self->cap == 0ULL) || (((self->len + 1ULL) * 4ULL) >= (self->cap * 3ULL))) {
    Map__u32__u32__Global__grow(self);
  }
  const size_t i = Map__u32__u32__Global__slot(self, (&key));
  if (self->used[i] != 0U) {
    __auto_type dup = key;
    (void)(dup);
    (void)(self->vals[i]);
    (self->vals[i] = value);
    return;
  }
  (self->keys[i] = key);
  (self->vals[i] = value);
  (self->used[i] = 1U);
  (self->len = (self->len + 1ULL));
}

Option__ptr_u32 Map__u32__u32__Global__get(const Map__u32__u32__Global *const self, const uint32_t *const key) {
  if (self->cap == 0ULL) {
    return (Option__ptr_u32){ .tag = Option_None };
  }
  const size_t i = Map__u32__u32__Global__slot(self, key);
  if (self->used[i] == 0U) {
    return (Option__ptr_u32){ .tag = Option_None };
  }
  return (Option__ptr_u32){ .tag = Option_Some, .payload.Some = { (&self->vals[i]) } };
}

bool Map__u32__u32__Global__contains_key(const Map__u32__u32__Global *const self, const uint32_t *const key) {
  return ({ __auto_type __sc5 = Map__u32__u32__Global__get(self, key); Option__ptr_u32__is_some(&__sc5); });
}

Option__u32 Map__u32__u32__Global__remove(Map__u32__u32__Global *const self, const uint32_t *const key) {
  if (self->cap == 0ULL) {
    return (Option__u32){ .tag = Option_None };
  }
  const size_t i = Map__u32__u32__Global__slot(self, key);
  if (self->used[i] == 0U) {
    return (Option__u32){ .tag = Option_None };
  }
  const __auto_type removed = self->vals[i];
  (void)(self->keys[i]);
  (self->used[i] = 0U);
  (self->len = (self->len - 1ULL));
  size_t j = (i + 1ULL);
  if (j >= self->cap) {
    (j = 0ULL);
  }
  while (self->used[j] == 1U) {
    const __auto_type k = self->keys[j];
    const __auto_type v = self->vals[j];
    (self->used[j] = 0U);
    (self->len = (self->len - 1ULL));
    Map__u32__u32__Global__insert(self, k, v);
    (j = (j + 1ULL));
    if (j >= self->cap) {
      (j = 0ULL);
    }
  }
  return (Option__u32){ .tag = Option_Some, .payload.Some = { removed } };
}

Map__u32__u32__Global Map__u32__u32__Global__new(void) {
  return Map__u32__u32__Global__new_in(Global__default_());
}

void Map__u32__u32__Global__free(Map__u32__u32__Global *const self) {
  for (size_t i = 0ULL; i < self->cap; i++) {
    if (self->used[i] != 0U) {
      (void)(self->keys[i]);
      (void)(self->vals[i]);
    }
  }
  Global__dealloc(&self->alloc, ((void *)self->keys), (self->cap * sizeof(uint32_t)), _Alignof(uint32_t));
  Global__dealloc(&self->alloc, ((void *)self->vals), (self->cap * sizeof(uint32_t)), _Alignof(uint32_t));
  Global__dealloc(&self->alloc, ((void *)self->used), self->cap, 1ULL);
  (self->keys = NULL);
  (self->vals = NULL);
  (self->used = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Map__u32__u32__Global Map__u32__u32__Global__default_(void) {
  return Map__u32__u32__Global__new();
}

MapKeys__u32 Map__u32__u32__Global__keys(const Map__u32__u32__Global *const self) {
  return (MapKeys__u32){ .keys = ((const uint32_t *)self->keys), .used = ((const uint8_t *)self->used), .idx = 0ULL, .cap = self->cap };
}

Option__ptr_u32 MapKeys__u32__next(MapKeys__u32 *const self) {
  while (self->idx < self->cap) {
    const size_t i = self->idx;
    (self->idx = (self->idx + 1ULL));
    if (self->used[i] != 0U) {
      return (Option__ptr_u32){ .tag = Option_Some, .payload.Some = { (&self->keys[i]) } };
    }
  }
  return (Option__ptr_u32){ .tag = Option_None };
}

