#ifndef SUPER___STD__MAP_H
#define SUPER___STD__MAP_H

#include "../super_rt.h"
typedef struct Option Option;
typedef struct Option__ptr_u32 Option__ptr_u32;
typedef struct Option__ptr_u64 Option__ptr_u64;
typedef struct Global Global;
typedef struct Option__u32 Option__u32;
typedef struct ast__ast__DefId ast__ast__DefId;
#include "../__std/interfaces.h"

typedef struct MapValues__u32 MapValues__u32;
typedef struct MapKeys__u64 MapKeys__u64;
typedef struct Map__u64__u32__Global Map__u64__u32__Global;
typedef struct Map__u32__u32__Global Map__u32__u32__Global;
typedef struct MapKeys__u32 MapKeys__u32;

struct MapValues__u32 {
  const uint32_t *vals;
  const uint8_t *used;
  size_t idx;
  size_t cap;
};
struct MapKeys__u64 {
  const uint64_t *keys;
  const uint8_t *used;
  size_t idx;
  size_t cap;
};
struct Map__u64__u32__Global {
  uint64_t *keys;
  uint32_t *vals;
  uint8_t *used;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Map__u32__u32__Global {
  uint32_t *keys;
  uint32_t *vals;
  uint8_t *used;
  size_t len;
  size_t cap;
  Global alloc;
};
struct MapKeys__u32 {
  const uint32_t *keys;
  const uint8_t *used;
  size_t idx;
  size_t cap;
};

Option__ptr_u32 MapValues__u32__next(MapValues__u32 *const self);
Option__ptr_u64 MapKeys__u64__next(MapKeys__u64 *const self);
Map__u64__u32__Global Map__u64__u32__Global__new_in(Global const alloc);
size_t Map__u64__u32__Global__len(const Map__u64__u32__Global *const self);
bool Map__u64__u32__Global__is_empty(const Map__u64__u32__Global *const self);
void Map__u64__u32__Global__insert(Map__u64__u32__Global *const self, uint64_t const key, uint32_t const value);
Option__ptr_u32 Map__u64__u32__Global__get(const Map__u64__u32__Global *const self, const uint64_t *const key);
bool Map__u64__u32__Global__contains_key(const Map__u64__u32__Global *const self, const uint64_t *const key);
Option__u32 Map__u64__u32__Global__remove(Map__u64__u32__Global *const self, const uint64_t *const key);
Map__u64__u32__Global Map__u64__u32__Global__new(void);
void Map__u64__u32__Global__free(Map__u64__u32__Global *const self);
Map__u64__u32__Global Map__u64__u32__Global__default_(void);
MapKeys__u64 Map__u64__u32__Global__keys(const Map__u64__u32__Global *const self);
Map__u32__u32__Global Map__u32__u32__Global__new_in(Global const alloc);
size_t Map__u32__u32__Global__len(const Map__u32__u32__Global *const self);
bool Map__u32__u32__Global__is_empty(const Map__u32__u32__Global *const self);
void Map__u32__u32__Global__insert(Map__u32__u32__Global *const self, uint32_t const key, uint32_t const value);
Option__ptr_u32 Map__u32__u32__Global__get(const Map__u32__u32__Global *const self, const uint32_t *const key);
bool Map__u32__u32__Global__contains_key(const Map__u32__u32__Global *const self, const uint32_t *const key);
Option__u32 Map__u32__u32__Global__remove(Map__u32__u32__Global *const self, const uint32_t *const key);
Map__u32__u32__Global Map__u32__u32__Global__new(void);
void Map__u32__u32__Global__free(Map__u32__u32__Global *const self);
Map__u32__u32__Global Map__u32__u32__Global__default_(void);
MapKeys__u32 Map__u32__u32__Global__keys(const Map__u32__u32__Global *const self);
Option__ptr_u32 MapKeys__u32__next(MapKeys__u32 *const self);


#endif
