#include "../module/loader.h"
#include "../stdio.h"
#include "../stdlib.h"
#include "../string.h"
#include "../lexer/token.h"
#include "../ast/ast.h"
#include "../driver_shim.h"
#include "../lexer/lexer.h"
#include "../ast/parser.h"
#include "../__std/core.h"
#include "../__std/interfaces.h"
#include "../__std/map.h"
#include "../__std/option.h"
#include "../__std/range.h"
#include "../__std/result.h"
#include "../__std/slice.h"
#include "../__std/str.h"
#include "../__std/string.h"
#include "../__std/vector.h"

_Static_assert(sizeof(module__loader__Module) == 568 && _Alignof(module__loader__Module) == 8, "super-c layout model mismatch: module__loader__Module");
_Static_assert(sizeof(module__loader__Package) == 360 && _Alignof(module__loader__Package) == 8, "super-c layout model mismatch: module__loader__Package");
_Static_assert(sizeof(module__loader__DirCache) == 72 && _Alignof(module__loader__DirCache) == 8, "super-c layout model mismatch: module__loader__DirCache");
_Static_assert(sizeof(module__loader__ParseResult) == 496 && _Alignof(module__loader__ParseResult) == 8, "super-c layout model mismatch: module__loader__ParseResult");
_Static_assert(sizeof(module__loader__LookupHit) == 8 && _Alignof(module__loader__LookupHit) == 4, "super-c layout model mismatch: module__loader__LookupHit");
_Static_assert(sizeof(module__loader__LkEnt) == 12 && _Alignof(module__loader__LkEnt) == 4, "super-c layout model mismatch: module__loader__LkEnt");
_Static_assert(sizeof(module__loader__RealBuf) == 4096 && _Alignof(module__loader__RealBuf) == 1, "super-c layout model mismatch: module__loader__RealBuf");

static __attribute__((unused)) uint64_t module__loader__fnv_name(str const name);
static __attribute__((unused)) bool module__loader__path_exists(str const path);
static __attribute__((unused)) Option__String__Global module__loader__read_file(str const path);
static __attribute__((unused)) String__Global module__loader__dir_of(str const path);
static __attribute__((unused)) String__Global module__loader__stem_of(str const path);
static __attribute__((unused)) String__Global module__loader__join_parts(const ast__ast__Ast *const ast, str const src, ast__ast__NodeList const parts, str const sep);
static __attribute__((unused)) String__Global module__loader__module_file_path(str const root_dir, const ast__ast__Ast *const ast, str const src, ast__ast__NodeList const parts);
static __attribute__((unused)) String__Global module__loader__join2(str const a, str const b);
static __attribute__((unused)) size_t module__loader__DirCache__index_of(module__loader__DirCache *const self, str const dir);
static __attribute__((unused)) String__Global module__loader__resolve_import_file(size_t const dca, str const root_dir, str const std_root, const ast__ast__Ast *const ast, str const src, ast__ast__NodeList const parts);
static __attribute__((unused)) module__loader__ParseResult module__loader__parse_source(String__Global *const source, const char *const file, bool const bootstrap_tags);
static __attribute__((unused)) const ast__ast__Ast *module__loader__Package__module_ast_ptr(const module__loader__Package *const self, uint16_t const mid);
static __attribute__((unused)) int32_t module__loader__Package__add_module(module__loader__Package *const self, String__Global path, String__Global file, String__Global source, ast__ast__Ast ast, bool const has_ast);
static __attribute__((unused)) int32_t module__loader__Package__load_module(module__loader__Package *const self, str const mod_path, str const file_path, bool const bootstrap_tags);
static __attribute__((unused)) void module__loader__Package__lk_emit(module__loader__Package *const self, size_t const m, const char *const srcp, uint32_t const start, uint32_t const end, bool const is_type, uint32_t const node);
static __attribute__((unused)) uint32_t module__loader__Package__lookup_linear(const module__loader__Package *const self, uint16_t const mid, str const name, bool const want_type);
static __attribute__((unused)) bool module__loader__Package__module_is_user(const module__loader__Package *const self, uint16_t const m);
static __attribute__((unused)) bool module__loader__Package__module_imports(const module__loader__Package *const self, uint16_t const from, uint16_t const to);
static __attribute__((unused)) uint16_t module__loader__Package__type_user_home(const module__loader__Package *const self, uint16_t const am, uint32_t const t);
static __attribute__((unused)) uint16_t module__loader__Package__instance_home_in(const module__loader__Package *const self, uint16_t const am, const ast__ast__TyInstance *const it);
static __attribute__((unused)) ast__ast__Ast *module__loader__pkg_ast_m(module__loader__Package *const p, uint16_t const m);
static __attribute__((unused)) const ast__ast__Ast *module__loader__pkg_ast_c(const module__loader__Package *const p, uint16_t const m);
static __attribute__((unused)) bool module__loader__type_mentions_fnval(const module__loader__Package *const p, uint16_t const mid, uint32_t const t);
static __attribute__((unused)) uint32_t module__loader__subst_reintern_type(module__loader__Package *const p, uint16_t const dm, uint16_t const om, uint32_t const t, uint16_t const gmod, const uint32_t *const gids, const uint32_t *const args, uint8_t const nargs);
static __attribute__((unused)) void module__loader__reintern_nested_type(module__loader__Package *const p, uint16_t const dm, uint16_t const om, uint32_t const t, uint16_t const gmod, const uint32_t *const gids, const uint32_t *const args, uint8_t const nargs, bool *const changed);
static __attribute__((unused)) void module__loader__reintern_nested_instance_deps(module__loader__Package *const p, uint16_t const dm, const ast__ast__TyInstance *const it, const uint32_t *const args, uint8_t const nargs, bool *const changed);
static __attribute__((unused)) void module__loader__reintern_method_signature_deps(module__loader__Package *const p, uint16_t const dm, const ast__ast__TyInstance *const it, const uint32_t *const args, uint8_t const nargs, bool *const changed);
static __attribute__((unused)) bool module__loader__reintern_cross_module(module__loader__Package *const p, uint16_t const sm, size_t const start);
static __attribute__((unused)) bool module__loader__reintern_method_insts(module__loader__Package *const p, uint16_t const sm);
static __attribute__((unused)) str module__loader__basename_of(str const path);
static __attribute__((unused)) int32_t module__loader__name_cmp(const String__Global *const a, const String__Global *const b);
static __attribute__((unused)) void module__loader__load_prelude(module__loader__Package *const p, const char *const std_dir);
static __attribute__((unused)) int32_t module__loader__closure_10270(const String__Global *const a, const String__Global *const b);
static __attribute__((unused)) size_t Map__u64__module__loader__LkEnt__Global__slot(const Map__u64__module__loader__LkEnt__Global *const self, const uint64_t *const key);
static __attribute__((unused)) void Map__u64__module__loader__LkEnt__Global__grow(Map__u64__module__loader__LkEnt__Global *const self);
static __attribute__((unused)) void Vector__String__Global__Global__sort_by__module__loader__closure_10270(Vector__String__Global__Global *const self, int32_t (*const cmp)(const String__Global *, const String__Global *));

Vector__module__loader__Module__Global Vector__module__loader__Module__Global__new_in(Global const alloc) {
  return (Vector__module__loader__Module__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__module__loader__Module__Global Vector__module__loader__Module__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__module__loader__Module__Global v = (Vector__module__loader__Module__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((module__loader__Module *)Global__alloc(&v.alloc, (cap * sizeof(module__loader__Module)), _Alignof(module__loader__Module))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__module__loader__Module__Global__len(const Vector__module__loader__Module__Global *const self) {
  return self->len;
}

void Vector__module__loader__Module__Global__reserve(Vector__module__loader__Module__Global *const self, size_t const additional) {
  const size_t needed = (self->len + additional);
  if (needed <= self->cap) {
    return;
  }
  size_t new_cap = (self->cap * 2ULL);
  if (new_cap == 0ULL) {
    (new_cap = 8ULL);
  }
  if (new_cap < needed) {
    (new_cap = needed);
  }
  module__loader__Module *const p = ((module__loader__Module *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(module__loader__Module)), (new_cap * sizeof(module__loader__Module)), _Alignof(module__loader__Module)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__module__loader__Module__Global__push(Vector__module__loader__Module__Global *const self, module__loader__Module value) {
  Vector__module__loader__Module__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const module__loader__Module *Vector__module__loader__Module__Global__at(const Vector__module__loader__Module__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_module__loader__Module Vector__module__loader__Module__Global__get(const Vector__module__loader__Module__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_module__loader__Module){ .tag = Option_None };
  }
  return (Option__ptr_module__loader__Module){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__module__loader__Module__Global__set(Vector__module__loader__Module__Global *const self, size_t const index, module__loader__Module value) {
  module__loader__Module__free(&self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__module__loader__Module__Global__clear(Vector__module__loader__Module__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    module__loader__Module__free(&self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__module__loader__Module__Global__truncate(Vector__module__loader__Module__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      module__loader__Module__free(&self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const module__loader__Module *Vector__module__loader__Module__Global__as_ptr(const Vector__module__loader__Module__Global *const self) {
  return self->ptr;
}

void Vector__module__loader__Module__Global__swap(Vector__module__loader__Module__Global *const self, size_t const i, size_t const j) {
  __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__module__loader__Module__Global Vector__module__loader__Module__Global__new(void) {
  return Vector__module__loader__Module__Global__new_in(Global__default_());
}

void Vector__module__loader__Module__Global__free(Vector__module__loader__Module__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    module__loader__Module__free(&self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(module__loader__Module)), _Alignof(module__loader__Module));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__module__loader__Module__Global Vector__module__loader__Module__Global__default_(void) {
  return Vector__module__loader__Module__Global__new();
}

const module__loader__Module *Vector__module__loader__Module__Global__index(const Vector__module__loader__Module__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__module__loader__Module Vector__module__loader__Module__Global__index_range(const Vector__module__loader__Module__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc0;
    if (r.inclusive) {
      __sc0 = (r.end + 1ULL);
    } else {
      __sc0 = r.end;
    }
    __sc0;
  });
  return (Slice__module__loader__Module){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

module__loader__Module *Vector__module__loader__Module__Global__index_mut(Vector__module__loader__Module__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__module__loader__Module Vector__module__loader__Module__Global__index_range_mut(Vector__module__loader__Module__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc1;
    if (r.inclusive) {
      __sc1 = (r.end + 1ULL);
    } else {
      __sc1 = r.end;
    }
    __sc1;
  });
  return (SliceMut__module__loader__Module){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Map__u64__module__loader__LkEnt__Global Map__u64__module__loader__LkEnt__Global__new_in(Global const alloc) {
  return (Map__u64__module__loader__LkEnt__Global){ .keys = NULL, .vals = NULL, .used = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

size_t Map__u64__module__loader__LkEnt__Global__len(const Map__u64__module__loader__LkEnt__Global *const self) {
  return self->len;
}

bool Map__u64__module__loader__LkEnt__Global__is_empty(const Map__u64__module__loader__LkEnt__Global *const self) {
  return (self->len == 0ULL);
}

static __attribute__((unused)) size_t Map__u64__module__loader__LkEnt__Global__slot(const Map__u64__module__loader__LkEnt__Global *const self, const uint64_t *const key) {
  size_t i = ({ size_t __sc2 = ((size_t)u64__hash(key)); size_t __sc3 = self->cap; if (__sc3 == 0) { __sc_panic("divide by zero"); } (__sc2 % __sc3); });
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

static __attribute__((unused)) void Map__u64__module__loader__LkEnt__Global__grow(Map__u64__module__loader__LkEnt__Global *const self) {
  size_t newcap = (self->cap * 2ULL);
  if (newcap < 8ULL) {
    (newcap = 8ULL);
  }
  uint64_t *const oldkeys = self->keys;
  module__loader__LkEnt *const oldvals = self->vals;
  uint8_t *const oldused = self->used;
  const size_t oldcap = self->cap;
  (self->keys = ((uint64_t *)Global__alloc(&self->alloc, (newcap * sizeof(uint64_t)), _Alignof(uint64_t))));
  (self->vals = ((module__loader__LkEnt *)Global__alloc(&self->alloc, (newcap * sizeof(module__loader__LkEnt)), _Alignof(module__loader__LkEnt))));
  (self->used = ((uint8_t *)Global__alloc(&self->alloc, newcap, 1ULL)));
  memset(((void *)self->used), 0, newcap);
  (self->cap = newcap);
  (self->len = 0ULL);
  for (size_t i = 0ULL; i < oldcap; i++) {
    if (oldused[i] == 1U) {
      const size_t j = Map__u64__module__loader__LkEnt__Global__slot(self, (&oldkeys[i]));
      (self->keys[j] = oldkeys[i]);
      (self->vals[j] = oldvals[i]);
      (self->used[j] = 1U);
      (self->len = (self->len + 1ULL));
    }
  }
  if (oldcap > 0ULL) {
    Global__dealloc(&self->alloc, ((void *)oldkeys), (oldcap * sizeof(uint64_t)), _Alignof(uint64_t));
    Global__dealloc(&self->alloc, ((void *)oldvals), (oldcap * sizeof(module__loader__LkEnt)), _Alignof(module__loader__LkEnt));
    Global__dealloc(&self->alloc, ((void *)oldused), oldcap, 1ULL);
  }
}

void Map__u64__module__loader__LkEnt__Global__insert(Map__u64__module__loader__LkEnt__Global *const self, uint64_t const key, module__loader__LkEnt const value) {
  if ((self->cap == 0ULL) || (((self->len + 1ULL) * 4ULL) >= (self->cap * 3ULL))) {
    Map__u64__module__loader__LkEnt__Global__grow(self);
  }
  const size_t i = Map__u64__module__loader__LkEnt__Global__slot(self, (&key));
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

Option__ptr_module__loader__LkEnt Map__u64__module__loader__LkEnt__Global__get(const Map__u64__module__loader__LkEnt__Global *const self, const uint64_t *const key) {
  if (self->cap == 0ULL) {
    return (Option__ptr_module__loader__LkEnt){ .tag = Option_None };
  }
  const size_t i = Map__u64__module__loader__LkEnt__Global__slot(self, key);
  if (self->used[i] == 0U) {
    return (Option__ptr_module__loader__LkEnt){ .tag = Option_None };
  }
  return (Option__ptr_module__loader__LkEnt){ .tag = Option_Some, .payload.Some = { (&self->vals[i]) } };
}

bool Map__u64__module__loader__LkEnt__Global__contains_key(const Map__u64__module__loader__LkEnt__Global *const self, const uint64_t *const key) {
  return ({ __auto_type __sc4 = Map__u64__module__loader__LkEnt__Global__get(self, key); Option__ptr_module__loader__LkEnt__is_some(&__sc4); });
}

Option__module__loader__LkEnt Map__u64__module__loader__LkEnt__Global__remove(Map__u64__module__loader__LkEnt__Global *const self, const uint64_t *const key) {
  if (self->cap == 0ULL) {
    return (Option__module__loader__LkEnt){ .tag = Option_None };
  }
  const size_t i = Map__u64__module__loader__LkEnt__Global__slot(self, key);
  if (self->used[i] == 0U) {
    return (Option__module__loader__LkEnt){ .tag = Option_None };
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
    Map__u64__module__loader__LkEnt__Global__insert(self, k, v);
    (j = (j + 1ULL));
    if (j >= self->cap) {
      (j = 0ULL);
    }
  }
  return (Option__module__loader__LkEnt){ .tag = Option_Some, .payload.Some = { removed } };
}

Map__u64__module__loader__LkEnt__Global Map__u64__module__loader__LkEnt__Global__new(void) {
  return Map__u64__module__loader__LkEnt__Global__new_in(Global__default_());
}

void Map__u64__module__loader__LkEnt__Global__free(Map__u64__module__loader__LkEnt__Global *const self) {
  for (size_t i = 0ULL; i < self->cap; i++) {
    if (self->used[i] != 0U) {
      (void)(self->keys[i]);
      (void)(self->vals[i]);
    }
  }
  Global__dealloc(&self->alloc, ((void *)self->keys), (self->cap * sizeof(uint64_t)), _Alignof(uint64_t));
  Global__dealloc(&self->alloc, ((void *)self->vals), (self->cap * sizeof(module__loader__LkEnt)), _Alignof(module__loader__LkEnt));
  Global__dealloc(&self->alloc, ((void *)self->used), self->cap, 1ULL);
  (self->keys = NULL);
  (self->vals = NULL);
  (self->used = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

MapKeys__u64 Map__u64__module__loader__LkEnt__Global__keys(const Map__u64__module__loader__LkEnt__Global *const self) {
  return (MapKeys__u64){ .keys = ((const uint64_t *)self->keys), .used = ((const uint8_t *)self->used), .idx = 0ULL, .cap = self->cap };
}

Vector__Map__u64__module__loader__LkEnt__Global__Global Vector__Map__u64__module__loader__LkEnt__Global__Global__new_in(Global const alloc) {
  return (Vector__Map__u64__module__loader__LkEnt__Global__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__Map__u64__module__loader__LkEnt__Global__Global Vector__Map__u64__module__loader__LkEnt__Global__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__Map__u64__module__loader__LkEnt__Global__Global v = (Vector__Map__u64__module__loader__LkEnt__Global__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((Map__u64__module__loader__LkEnt__Global *)Global__alloc(&v.alloc, (cap * sizeof(Map__u64__module__loader__LkEnt__Global)), _Alignof(Map__u64__module__loader__LkEnt__Global))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__Map__u64__module__loader__LkEnt__Global__Global__len(const Vector__Map__u64__module__loader__LkEnt__Global__Global *const self) {
  return self->len;
}

void Vector__Map__u64__module__loader__LkEnt__Global__Global__reserve(Vector__Map__u64__module__loader__LkEnt__Global__Global *const self, size_t const additional) {
  const size_t needed = (self->len + additional);
  if (needed <= self->cap) {
    return;
  }
  size_t new_cap = (self->cap * 2ULL);
  if (new_cap == 0ULL) {
    (new_cap = 8ULL);
  }
  if (new_cap < needed) {
    (new_cap = needed);
  }
  Map__u64__module__loader__LkEnt__Global *const p = ((Map__u64__module__loader__LkEnt__Global *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(Map__u64__module__loader__LkEnt__Global)), (new_cap * sizeof(Map__u64__module__loader__LkEnt__Global)), _Alignof(Map__u64__module__loader__LkEnt__Global)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__Map__u64__module__loader__LkEnt__Global__Global__push(Vector__Map__u64__module__loader__LkEnt__Global__Global *const self, Map__u64__module__loader__LkEnt__Global value) {
  Vector__Map__u64__module__loader__LkEnt__Global__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const Map__u64__module__loader__LkEnt__Global *Vector__Map__u64__module__loader__LkEnt__Global__Global__at(const Vector__Map__u64__module__loader__LkEnt__Global__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_Map__u64__module__loader__LkEnt__Global Vector__Map__u64__module__loader__LkEnt__Global__Global__get(const Vector__Map__u64__module__loader__LkEnt__Global__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_Map__u64__module__loader__LkEnt__Global){ .tag = Option_None };
  }
  return (Option__ptr_Map__u64__module__loader__LkEnt__Global){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__Map__u64__module__loader__LkEnt__Global__Global__set(Vector__Map__u64__module__loader__LkEnt__Global__Global *const self, size_t const index, Map__u64__module__loader__LkEnt__Global value) {
  Map__u64__module__loader__LkEnt__Global__free(&self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__Map__u64__module__loader__LkEnt__Global__Global__clear(Vector__Map__u64__module__loader__LkEnt__Global__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    Map__u64__module__loader__LkEnt__Global__free(&self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__Map__u64__module__loader__LkEnt__Global__Global__truncate(Vector__Map__u64__module__loader__LkEnt__Global__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      Map__u64__module__loader__LkEnt__Global__free(&self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const Map__u64__module__loader__LkEnt__Global *Vector__Map__u64__module__loader__LkEnt__Global__Global__as_ptr(const Vector__Map__u64__module__loader__LkEnt__Global__Global *const self) {
  return self->ptr;
}

void Vector__Map__u64__module__loader__LkEnt__Global__Global__swap(Vector__Map__u64__module__loader__LkEnt__Global__Global *const self, size_t const i, size_t const j) {
  __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__Map__u64__module__loader__LkEnt__Global__Global Vector__Map__u64__module__loader__LkEnt__Global__Global__new(void) {
  return Vector__Map__u64__module__loader__LkEnt__Global__Global__new_in(Global__default_());
}

void Vector__Map__u64__module__loader__LkEnt__Global__Global__free(Vector__Map__u64__module__loader__LkEnt__Global__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    Map__u64__module__loader__LkEnt__Global__free(&self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(Map__u64__module__loader__LkEnt__Global)), _Alignof(Map__u64__module__loader__LkEnt__Global));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__Map__u64__module__loader__LkEnt__Global__Global Vector__Map__u64__module__loader__LkEnt__Global__Global__default_(void) {
  return Vector__Map__u64__module__loader__LkEnt__Global__Global__new();
}

const Map__u64__module__loader__LkEnt__Global *Vector__Map__u64__module__loader__LkEnt__Global__Global__index(const Vector__Map__u64__module__loader__LkEnt__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Map__u64__module__loader__LkEnt__Global Vector__Map__u64__module__loader__LkEnt__Global__Global__index_range(const Vector__Map__u64__module__loader__LkEnt__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc5;
    if (r.inclusive) {
      __sc5 = (r.end + 1ULL);
    } else {
      __sc5 = r.end;
    }
    __sc5;
  });
  return (Slice__Map__u64__module__loader__LkEnt__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Map__u64__module__loader__LkEnt__Global *Vector__Map__u64__module__loader__LkEnt__Global__Global__index_mut(Vector__Map__u64__module__loader__LkEnt__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__Map__u64__module__loader__LkEnt__Global Vector__Map__u64__module__loader__LkEnt__Global__Global__index_range_mut(Vector__Map__u64__module__loader__LkEnt__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc6;
    if (r.inclusive) {
      __sc6 = (r.end + 1ULL);
    } else {
      __sc6 = r.end;
    }
    __sc6;
  });
  return (SliceMut__Map__u64__module__loader__LkEnt__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__ptr_module__loader__LkEnt Option__ptr_module__loader__LkEnt__some(const module__loader__LkEnt *const value) {
  return (Option__ptr_module__loader__LkEnt){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_module__loader__LkEnt Option__ptr_module__loader__LkEnt__none(void) {
  return (Option__ptr_module__loader__LkEnt){ .tag = Option_None };
}

bool Option__ptr_module__loader__LkEnt__is_some(const Option__ptr_module__loader__LkEnt *const self) {
  {
    const Option__ptr_module__loader__LkEnt *const __sc7 = self;
    if ((*__sc7).tag == Option_Some) {
      return true;
    }
    else if ((*__sc7).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_module__loader__LkEnt__is_none(const Option__ptr_module__loader__LkEnt *const self) {
  {
    const Option__ptr_module__loader__LkEnt *const __sc8 = self;
    if ((*__sc8).tag == Option_Some) {
      return false;
    }
    else if ((*__sc8).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_module__loader__LkEnt Option__ptr_module__loader__LkEnt__default_(void) {
  return Option__ptr_module__loader__LkEnt__none();
}

Option__module__loader__Module Option__module__loader__Module__some(module__loader__Module value) {
  return (Option__module__loader__Module){ .tag = Option_Some, .payload.Some = { value } };
}

Option__module__loader__Module Option__module__loader__Module__none(void) {
  return (Option__module__loader__Module){ .tag = Option_None };
}

bool Option__module__loader__Module__is_some(const Option__module__loader__Module *const self) {
  {
    const Option__module__loader__Module *const __sc9 = self;
    if ((*__sc9).tag == Option_Some) {
      return true;
    }
    else if ((*__sc9).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__module__loader__Module__is_none(const Option__module__loader__Module *const self) {
  {
    const Option__module__loader__Module *const __sc10 = self;
    if ((*__sc10).tag == Option_Some) {
      return false;
    }
    else if ((*__sc10).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__module__loader__Module Option__module__loader__Module__default_(void) {
  return Option__module__loader__Module__none();
}

void Option__module__loader__Module__free(Option__module__loader__Module *const self) {
  {
    Option__module__loader__Module *const __sc11 = self;
    if ((*__sc11).tag == Option_Some) {
      const __auto_type v = &((*__sc11).payload.Some._0);
      module__loader__Module__free(v);
    }
    else if ((*__sc11).tag == Option_None) {
      {
      }
    }
  }
}

Option__ptr_module__loader__Module Option__ptr_module__loader__Module__some(const module__loader__Module *const value) {
  return (Option__ptr_module__loader__Module){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_module__loader__Module Option__ptr_module__loader__Module__none(void) {
  return (Option__ptr_module__loader__Module){ .tag = Option_None };
}

bool Option__ptr_module__loader__Module__is_some(const Option__ptr_module__loader__Module *const self) {
  {
    const Option__ptr_module__loader__Module *const __sc12 = self;
    if ((*__sc12).tag == Option_Some) {
      return true;
    }
    else if ((*__sc12).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_module__loader__Module__is_none(const Option__ptr_module__loader__Module *const self) {
  {
    const Option__ptr_module__loader__Module *const __sc13 = self;
    if ((*__sc13).tag == Option_Some) {
      return false;
    }
    else if ((*__sc13).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_module__loader__Module Option__ptr_module__loader__Module__default_(void) {
  return Option__ptr_module__loader__Module__none();
}

Option__ptr_module__loader__Module VecIter__module__loader__Module__next(VecIter__module__loader__Module *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_module__loader__Module__none();
  }
  const module__loader__Module *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_module__loader__Module__some(r);
}

size_t Slice__module__loader__Module__len(const Slice__module__loader__Module *const self) {
  return self->len;
}

const module__loader__Module *Slice__module__loader__Module__as_ptr(const Slice__module__loader__Module *const self) {
  return self->ptr;
}

const module__loader__Module *Slice__module__loader__Module__index(const Slice__module__loader__Module *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__module__loader__Module Slice__module__loader__Module__index_range(const Slice__module__loader__Module *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc14;
    if (r.inclusive) {
      __sc14 = (r.end + 1ULL);
    } else {
      __sc14 = r.end;
    }
    __sc14;
  });
  return (Slice__module__loader__Module){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__module__loader__Module__len(const SliceMut__module__loader__Module *const self) {
  return self->len;
}

module__loader__Module *SliceMut__module__loader__Module__as_mut_ptr(const SliceMut__module__loader__Module *const self) {
  return self->ptr;
}

const module__loader__Module *SliceMut__module__loader__Module__index(const SliceMut__module__loader__Module *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__module__loader__Module SliceMut__module__loader__Module__index_range(const SliceMut__module__loader__Module *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc15;
    if (r.inclusive) {
      __sc15 = (r.end + 1ULL);
    } else {
      __sc15 = r.end;
    }
    __sc15;
  });
  return (Slice__module__loader__Module){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

module__loader__Module *SliceMut__module__loader__Module__index_mut(SliceMut__module__loader__Module *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__module__loader__Module SliceMut__module__loader__Module__index_range_mut(SliceMut__module__loader__Module *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc16;
    if (r.inclusive) {
      __sc16 = (r.end + 1ULL);
    } else {
      __sc16 = r.end;
    }
    __sc16;
  });
  return (SliceMut__module__loader__Module){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__module__loader__LkEnt Option__module__loader__LkEnt__some(module__loader__LkEnt const value) {
  return (Option__module__loader__LkEnt){ .tag = Option_Some, .payload.Some = { value } };
}

Option__module__loader__LkEnt Option__module__loader__LkEnt__none(void) {
  return (Option__module__loader__LkEnt){ .tag = Option_None };
}

bool Option__module__loader__LkEnt__is_some(const Option__module__loader__LkEnt *const self) {
  {
    const Option__module__loader__LkEnt *const __sc17 = self;
    if ((*__sc17).tag == Option_Some) {
      return true;
    }
    else if ((*__sc17).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__module__loader__LkEnt__is_none(const Option__module__loader__LkEnt *const self) {
  {
    const Option__module__loader__LkEnt *const __sc18 = self;
    if ((*__sc18).tag == Option_Some) {
      return false;
    }
    else if ((*__sc18).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__module__loader__LkEnt Option__module__loader__LkEnt__default_(void) {
  return Option__module__loader__LkEnt__none();
}

Option__ptr_module__loader__LkEnt MapValues__module__loader__LkEnt__next(MapValues__module__loader__LkEnt *const self) {
  while (self->idx < self->cap) {
    const size_t i = self->idx;
    (self->idx = (self->idx + 1ULL));
    if (self->used[i] != 0U) {
      return (Option__ptr_module__loader__LkEnt){ .tag = Option_Some, .payload.Some = { (&self->vals[i]) } };
    }
  }
  return (Option__ptr_module__loader__LkEnt){ .tag = Option_None };
}

Option__Map__u64__module__loader__LkEnt__Global Option__Map__u64__module__loader__LkEnt__Global__some(Map__u64__module__loader__LkEnt__Global value) {
  return (Option__Map__u64__module__loader__LkEnt__Global){ .tag = Option_Some, .payload.Some = { value } };
}

Option__Map__u64__module__loader__LkEnt__Global Option__Map__u64__module__loader__LkEnt__Global__none(void) {
  return (Option__Map__u64__module__loader__LkEnt__Global){ .tag = Option_None };
}

bool Option__Map__u64__module__loader__LkEnt__Global__is_some(const Option__Map__u64__module__loader__LkEnt__Global *const self) {
  {
    const Option__Map__u64__module__loader__LkEnt__Global *const __sc19 = self;
    if ((*__sc19).tag == Option_Some) {
      return true;
    }
    else if ((*__sc19).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__Map__u64__module__loader__LkEnt__Global__is_none(const Option__Map__u64__module__loader__LkEnt__Global *const self) {
  {
    const Option__Map__u64__module__loader__LkEnt__Global *const __sc20 = self;
    if ((*__sc20).tag == Option_Some) {
      return false;
    }
    else if ((*__sc20).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__Map__u64__module__loader__LkEnt__Global Option__Map__u64__module__loader__LkEnt__Global__default_(void) {
  return Option__Map__u64__module__loader__LkEnt__Global__none();
}

void Option__Map__u64__module__loader__LkEnt__Global__free(Option__Map__u64__module__loader__LkEnt__Global *const self) {
  {
    Option__Map__u64__module__loader__LkEnt__Global *const __sc21 = self;
    if ((*__sc21).tag == Option_Some) {
      const __auto_type v = &((*__sc21).payload.Some._0);
      Map__u64__module__loader__LkEnt__Global__free(v);
    }
    else if ((*__sc21).tag == Option_None) {
      {
      }
    }
  }
}

Option__ptr_Map__u64__module__loader__LkEnt__Global Option__ptr_Map__u64__module__loader__LkEnt__Global__some(const Map__u64__module__loader__LkEnt__Global *const value) {
  return (Option__ptr_Map__u64__module__loader__LkEnt__Global){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_Map__u64__module__loader__LkEnt__Global Option__ptr_Map__u64__module__loader__LkEnt__Global__none(void) {
  return (Option__ptr_Map__u64__module__loader__LkEnt__Global){ .tag = Option_None };
}

bool Option__ptr_Map__u64__module__loader__LkEnt__Global__is_some(const Option__ptr_Map__u64__module__loader__LkEnt__Global *const self) {
  {
    const Option__ptr_Map__u64__module__loader__LkEnt__Global *const __sc22 = self;
    if ((*__sc22).tag == Option_Some) {
      return true;
    }
    else if ((*__sc22).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_Map__u64__module__loader__LkEnt__Global__is_none(const Option__ptr_Map__u64__module__loader__LkEnt__Global *const self) {
  {
    const Option__ptr_Map__u64__module__loader__LkEnt__Global *const __sc23 = self;
    if ((*__sc23).tag == Option_Some) {
      return false;
    }
    else if ((*__sc23).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_Map__u64__module__loader__LkEnt__Global Option__ptr_Map__u64__module__loader__LkEnt__Global__default_(void) {
  return Option__ptr_Map__u64__module__loader__LkEnt__Global__none();
}

Option__ptr_Map__u64__module__loader__LkEnt__Global VecIter__Map__u64__module__loader__LkEnt__Global__next(VecIter__Map__u64__module__loader__LkEnt__Global *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_Map__u64__module__loader__LkEnt__Global__none();
  }
  const Map__u64__module__loader__LkEnt__Global *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_Map__u64__module__loader__LkEnt__Global__some(r);
}

size_t Slice__Map__u64__module__loader__LkEnt__Global__len(const Slice__Map__u64__module__loader__LkEnt__Global *const self) {
  return self->len;
}

const Map__u64__module__loader__LkEnt__Global *Slice__Map__u64__module__loader__LkEnt__Global__as_ptr(const Slice__Map__u64__module__loader__LkEnt__Global *const self) {
  return self->ptr;
}

const Map__u64__module__loader__LkEnt__Global *Slice__Map__u64__module__loader__LkEnt__Global__index(const Slice__Map__u64__module__loader__LkEnt__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Map__u64__module__loader__LkEnt__Global Slice__Map__u64__module__loader__LkEnt__Global__index_range(const Slice__Map__u64__module__loader__LkEnt__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc24;
    if (r.inclusive) {
      __sc24 = (r.end + 1ULL);
    } else {
      __sc24 = r.end;
    }
    __sc24;
  });
  return (Slice__Map__u64__module__loader__LkEnt__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__Map__u64__module__loader__LkEnt__Global__len(const SliceMut__Map__u64__module__loader__LkEnt__Global *const self) {
  return self->len;
}

Map__u64__module__loader__LkEnt__Global *SliceMut__Map__u64__module__loader__LkEnt__Global__as_mut_ptr(const SliceMut__Map__u64__module__loader__LkEnt__Global *const self) {
  return self->ptr;
}

const Map__u64__module__loader__LkEnt__Global *SliceMut__Map__u64__module__loader__LkEnt__Global__index(const SliceMut__Map__u64__module__loader__LkEnt__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Map__u64__module__loader__LkEnt__Global SliceMut__Map__u64__module__loader__LkEnt__Global__index_range(const SliceMut__Map__u64__module__loader__LkEnt__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc25;
    if (r.inclusive) {
      __sc25 = (r.end + 1ULL);
    } else {
      __sc25 = r.end;
    }
    __sc25;
  });
  return (Slice__Map__u64__module__loader__LkEnt__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Map__u64__module__loader__LkEnt__Global *SliceMut__Map__u64__module__loader__LkEnt__Global__index_mut(SliceMut__Map__u64__module__loader__LkEnt__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__Map__u64__module__loader__LkEnt__Global SliceMut__Map__u64__module__loader__LkEnt__Global__index_range_mut(SliceMut__Map__u64__module__loader__LkEnt__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc26;
    if (r.inclusive) {
      __sc26 = (r.end + 1ULL);
    } else {
      __sc26 = r.end;
    }
    __sc26;
  });
  return (SliceMut__Map__u64__module__loader__LkEnt__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

static __attribute__((unused)) void Vector__String__Global__Global__sort_by__module__loader__closure_10270(Vector__String__Global__Global *const self, int32_t (*const cmp)(const String__Global *, const String__Global *)) {
  const size_t n = self->len;
  if (n < 2ULL) {
    return;
  }
  size_t phase = 0ULL;
  size_t start = ({ size_t __sc27 = n; size_t __sc28 = 2ULL; if (__sc28 == 0) { __sc_panic("divide by zero"); } (__sc27 / __sc28); });
  size_t end = n;
  for (;;) {
    size_t r = 0ULL;
    if (phase == 0ULL) {
      if (start == 0ULL) {
        (phase = 1ULL);
        continue;
      }
      (start = (start - 1ULL));
      (r = start);
    } else {
      if (end <= 1ULL) {
        break;
      }
      (end = (end - 1ULL));
      Vector__String__Global__Global__swap(self, 0ULL, end);
    }
    size_t lim = n;
    if (phase == 1ULL) {
      (lim = end);
    }
    size_t child = ((2ULL * r) + 1ULL);
    while (child < lim) {
      if (((child + 1ULL) < lim) && (cmp((&self->ptr[child]), (&self->ptr[(child + 1ULL)])) < 0)) {
        (child = (child + 1ULL));
      }
      if (cmp((&self->ptr[r]), (&self->ptr[child])) >= 0) {
        break;
      }
      Vector__String__Global__Global__swap(self, r, child);
      (r = child);
      (child = ((2ULL * r) + 1ULL));
    }
  }
}

static __attribute__((unused)) int32_t module__loader__closure_10270(const String__Global *const a, const String__Global *const b) {
  return module__loader__name_cmp(a, b);
}

void module__loader__Module__free(module__loader__Module *const self) {
  String__Global__free(&self->path);
  String__Global__free(&self->file);
  String__Global__free(&self->source);
  ast__ast__Ast__free(&self->ast);
}

static __attribute__((unused)) uint64_t module__loader__fnv_name(str const name) {
  const uint8_t *const p = str__ptr(&name);
  uint64_t h = 1469598103934665603ULL;
  for (size_t i = 0ULL; i < str__len(&name); i++) {
    (h = (h ^ ((uint64_t)p[((size_t)i)])));
    (h = (h * 1099511628211ULL));
  }
  return h;
}

static __attribute__((unused)) bool module__loader__path_exists(str const path) {
  FILE *const f = stdio__fopen(path, (str){ (const uint8_t *)"rb", sizeof("rb") - 1 });
  if (f == NULL) {
    return false;
  }
  fclose(f);
  return true;
}

static __attribute__((unused)) Option__String__Global module__loader__read_file(str const path) {
  FILE *const f = stdio__fopen(path, (str){ (const uint8_t *)"rb", sizeof("rb") - 1 });
  if (f == NULL) {
    return (Option__String__Global){ .tag = Option_None };
  }
  if (fseek(f, 0, module__loader__SEEK_END) != 0) {
    fclose(f);
    return (Option__String__Global){ .tag = Option_None };
  }
  const int64_t s = ftell(f);
  rewind(f);
  if (s < 0) {
    fclose(f);
    return (Option__String__Global){ .tag = Option_None };
  }
  const size_t sz = ((size_t)s);
  char *const buf = ((char *)malloc((sz + 1ULL)));
  if (buf == NULL) {
    fclose(f);
    return (Option__String__Global){ .tag = Option_None };
  }
  const size_t n = fread(((void *)buf), 1ULL, sz, f);
  if ((n != sz) && (ferror(f) != 0)) {
    free(((void *)buf));
    fclose(f);
    return (Option__String__Global){ .tag = Option_None };
  }
  fclose(f);
  String__Global out = String__Global__with_capacity((n + lexer__lexer__SOURCE_PAD));
  String__Global__push_str(&out, str__from_raw(((const uint8_t *)buf), n));
  free(((void *)buf));
  String__Global__pad_nul(&out, lexer__lexer__SOURCE_PAD);
  return (Option__String__Global){ .tag = Option_Some, .payload.Some = { out } };
}

static __attribute__((unused)) String__Global module__loader__dir_of(str const path) {
  const size_t n = str__len(&path);
  int64_t slash = -1;
  size_t i = 0ULL;
  while (i < n) {
    if (str__byte_at(&path, i) == 47U) {
      (slash = ((int64_t)i));
    }
    (i = (i + 1ULL));
  }
  if (slash < 0) {
    return String__Global__from_str((str){ (const uint8_t *)".", sizeof(".") - 1 });
  }
  return String__Global__from_str(str__slice(&path, 0ULL, ((size_t)slash)));
}

static __attribute__((unused)) String__Global module__loader__stem_of(str const path) {
  const size_t n = str__len(&path);
  size_t bstart = 0ULL;
  size_t i = 0ULL;
  while (i < n) {
    if (str__byte_at(&path, i) == 47U) {
      (bstart = (i + 1ULL));
    }
    (i = (i + 1ULL));
  }
  int64_t dot = -1;
  (i = bstart);
  while (i < n) {
    if (str__byte_at(&path, i) == 46U) {
      (dot = ((int64_t)i));
    }
    (i = (i + 1ULL));
  }
  const size_t end = ({
    size_t __sc29;
    if (dot >= 0) {
      __sc29 = ((size_t)dot);
    } else {
      __sc29 = n;
    }
    __sc29;
  });
  return String__Global__from_str(str__slice(&path, bstart, end));
}

static __attribute__((unused)) String__Global module__loader__join_parts(const ast__ast__Ast *const ast, str const src, ast__ast__NodeList const parts, str const sep) {
  const uint32_t *const ids = ast__ast__Ast__list(ast, parts);
  String__Global out = String__Global__new();
  uint32_t i = 0U;
  while (i < parts.len) {
    if (i != 0U) {
      String__Global__push_str(&out, sep);
    }
    const lexer__token__Span sp = ast__ast__Ast__at_const(ast, ids[((size_t)i)])->as_data.name.text;
    String__Global__push_str(&out, str__slice(&src, ((size_t)sp.start), ((size_t)sp.end)));
    (i = (i + 1U));
  }
  return out;
}

static __attribute__((unused)) String__Global module__loader__module_file_path(str const root_dir, const ast__ast__Ast *const ast, str const src, ast__ast__NodeList const parts) {
  String__Global rel = module__loader__join_parts((&(*ast)), src, parts, (str){ (const uint8_t *)"/", sizeof("/") - 1 });
  String__Global out = String__Global__from_str(root_dir);
  String__Global__push_str(&out, (str){ (const uint8_t *)"/", sizeof("/") - 1 });
  String__Global__push_str(&out, String__Global__as_str(&rel));
  String__Global__push_str(&out, (str){ (const uint8_t *)".spc", sizeof(".spc") - 1 });
  {
    __auto_type __sc30 = out;
    String__Global__free(&rel);
    return __sc30;
  }
}

static __attribute__((unused)) String__Global module__loader__join2(str const a, str const b) {
  String__Global out = String__Global__from_str(a);
  String__Global__push_str(&out, (str){ (const uint8_t *)"/", sizeof("/") - 1 });
  String__Global__push_str(&out, b);
  return out;
}

module__loader__DirCache module__loader__DirCache__new(void) {
  return (module__loader__DirCache){ .dirs = Vector__String__Global__Global__new(), .entries = Vector__Vector__String__Global__Global__Global__new(), .ok = Vector__bool__Global__new() };
}

static __attribute__((unused)) size_t module__loader__DirCache__index_of(module__loader__DirCache *const self, str const dir) {
  for (size_t i = 0ULL; i < Vector__String__Global__Global__len(&self->dirs); i++) {
    if (({ __auto_type __sc31 = String__Global__as_str(&(*({ __auto_type __sc33 = &self->dirs; Vector__String__Global__Global__index(__sc33, i); }))); __auto_type __sc32 = dir; str__eq(&__sc31, &__sc32); })) {
      return i;
    }
  }
  Vector__String__Global__Global names = Vector__String__Global__Global__new();
  bool dok = false;
  module__loader__RealBuf db = (module__loader__RealBuf){0};
  const size_t dl = str__len(&dir);
  if (dl < 4096ULL) {
    memcpy(((void *)(&db.b[0])), ((const void *)str__ptr(&dir)), dl);
    (db.b[dl] = 0);
    void *const d = sc_opendir(((const char *)(&db.b[0])));
    if (d != NULL) {
      (dok = true);
      for (;;) {
        void *const e = sc_readdir(d);
        if (e == NULL) {
          break;
        }
        Vector__String__Global__Global__push(&names, String__Global__from_cstr(sc_dirent_name(e)));
      }
      (void)(sc_closedir(d));
    }
  }
  Vector__String__Global__Global__push(&self->dirs, String__Global__from_str(dir));
  Vector__Vector__String__Global__Global__Global__push(&self->entries, names);
  Vector__bool__Global__push(&self->ok, dok);
  return (Vector__String__Global__Global__len(&self->dirs) - 1ULL);
}

bool module__loader__DirCache__exists(module__loader__DirCache *const self, str const path) {
  const size_t n = str__len(&path);
  int64_t slash = -1;
  size_t i = 0ULL;
  while (i < n) {
    if (str__byte_at(&path, i) == 47U) {
      (slash = ((int64_t)i));
    }
    (i = (i + 1ULL));
  }
  if (slash < 0) {
    return module__loader__path_exists(path);
  }
  const str dir = str__slice(&path, 0ULL, ((size_t)slash));
  const str file = str__slice(&path, (((size_t)slash) + 1ULL), n);
  const size_t idx = module__loader__DirCache__index_of(self, dir);
  if (!(*({ __auto_type __sc34 = &self->ok; Vector__bool__Global__index(__sc34, idx); }))) {
    return false;
  }
  const Vector__String__Global__Global *const ents = Vector__Vector__String__Global__Global__Global__at(&self->entries, idx);
  for (size_t k = 0ULL; k < Vector__String__Global__Global__len(ents); k++) {
    if (({ __auto_type __sc35 = String__Global__as_str(&(*({ __auto_type __sc37 = ents; Vector__String__Global__Global__index(__sc37, k); }))); __auto_type __sc36 = file; str__eq(&__sc35, &__sc36); })) {
      return true;
    }
  }
  return module__loader__path_exists(path);
}

void module__loader__DirCache__free(module__loader__DirCache *const self) {
  Vector__String__Global__Global__free(&self->dirs);
  Vector__Vector__String__Global__Global__Global__free(&self->entries);
  Vector__bool__Global__free(&self->ok);
}

static __attribute__((unused)) String__Global module__loader__resolve_import_file(size_t const dca, str const root_dir, str const std_root, const ast__ast__Ast *const ast, str const src, ast__ast__NodeList const parts) {
  module__loader__DirCache *const dc = ((module__loader__DirCache *)dca);
  String__Global root_rel = module__loader__module_file_path(root_dir, (&(*ast)), src, parts);
  if (module__loader__DirCache__exists(&((*dc)), String__Global__as_str(&root_rel)) || str__is_empty(&std_root)) {
    return root_rel;
  }
  String__Global std_rel = module__loader__module_file_path(std_root, (&(*ast)), src, parts);
  bool __mv1488 = false;
  if (module__loader__DirCache__exists(&((*dc)), String__Global__as_str(&std_rel))) {
    {
      __auto_type __sc38 = (__mv1488 = true, std_rel);
      if (!__mv1488) String__Global__free(&std_rel);
      return __sc38;
    }
  }
  String__Global ffi_base = module__loader__join2(std_root, (str){ (const uint8_t *)"ffi", sizeof("ffi") - 1 });
  String__Global ffi_rel = module__loader__module_file_path(String__Global__as_str(&ffi_base), (&(*ast)), src, parts);
  bool __mv1521 = false;
  if (module__loader__DirCache__exists(&((*dc)), String__Global__as_str(&ffi_rel))) {
    {
      __auto_type __sc39 = (__mv1521 = true, ffi_rel);
      if (!__mv1521) String__Global__free(&ffi_rel);
      String__Global__free(&ffi_base);
      if (!__mv1488) String__Global__free(&std_rel);
      return __sc39;
    }
  }
  {
    __auto_type __sc40 = root_rel;
    if (!__mv1521) String__Global__free(&ffi_rel);
    String__Global__free(&ffi_base);
    if (!__mv1488) String__Global__free(&std_rel);
    return __sc40;
  }
}

static __attribute__((unused)) module__loader__ParseResult module__loader__parse_source(String__Global *const source, const char *const file, bool const bootstrap_tags) {
  lexer__lexer__Lexer lx = lexer__lexer__Lexer__new((&(*source)));
  lexer__lexer__Lexer__set_file(&lx, file);
  lexer__lexer__Lexer__scan_tokens(&lx);
  if (lexer__lexer__Lexer__has_errors(&lx)) {
    lexer__lexer__Lexer__log_errors(&lx);
    lexer__lexer__Lexer__free(&lx);
    return (module__loader__ParseResult){ .ast = ast__ast__Ast__new(0ULL), .ok = false };
  }
  Vector__u64__Global toks = lexer__lexer__Lexer__take_tokens(&lx);
  lexer__lexer__Lexer__free(&lx);
  const str src = String__Global__as_str(source);
  ast__parser__Parser ps = ast__parser__Parser__new(toks, src);
  ast__parser__Parser__set_file(&ps, file);
  ast__parser__Parser__set_bootstrap_tags(&ps, bootstrap_tags);
  ast__parser__Parser__build_ast(&ps);
  if (ast__parser__Parser__has_errors(&ps)) {
    ast__parser__Parser__log_errors(&ps);
    ast__parser__Parser__free(&ps);
    return (module__loader__ParseResult){ .ast = ast__ast__Ast__new(0ULL), .ok = false };
  }
  ast__ast__Ast out = ast__parser__Parser__take_ast(&ps);
  ast__parser__Parser__free(&ps);
  return (module__loader__ParseResult){ .ast = out, .ok = true };
}

module__loader__Package module__loader__Package__new(void) {
  return (module__loader__Package){ .modules = Vector__module__loader__Module__Global__new(), .root_dir = String__Global__new(), .std_root = String__Global__new(), .ok = true, .core_module = 0U, .core_seeded = false, .method_used = Vector__Vector__bool__Global__Global__new(), .ceval = NULL, .override_mod = 65535U, .override_ast = NULL, .mod_refs = Vector__u64__Global__new(), .mod_refs_w = 0ULL, .mod_refs_ready = false, .lk_index = Vector__Map__u64__module__loader__LkEnt__Global__Global__new(), .lk_built = Vector__bool__Global__new(), .dir_cache = module__loader__DirCache__new() };
}

static __attribute__((unused)) const ast__ast__Ast *module__loader__Package__module_ast_ptr(const module__loader__Package *const self, uint16_t const mid) {
  if ((mid == self->override_mod) && (self->override_ast != NULL)) {
    return ((const ast__ast__Ast *)self->override_ast);
  }
  return ((const ast__ast__Ast *)(&(*({ __auto_type __sc41 = &self->modules; Vector__module__loader__Module__Global__index(__sc41, ((size_t)mid)); })).ast));
}

int32_t module__loader__Package__find(const module__loader__Package *const self, str const path) {
  for (size_t i = 0ULL; i < Vector__module__loader__Module__Global__len(&self->modules); i++) {
    if (({ __auto_type __sc42 = String__Global__as_str(&(*({ __auto_type __sc44 = &self->modules; Vector__module__loader__Module__Global__index(__sc44, i); })).path); __auto_type __sc43 = path; str__eq(&__sc42, &__sc43); })) {
      return ((int32_t)i);
    }
  }
  return -1;
}

static __attribute__((unused)) int32_t module__loader__Package__add_module(module__loader__Package *const self, String__Global path, String__Global file, String__Global source, ast__ast__Ast ast, bool const has_ast) {
  const int32_t id = ((int32_t)Vector__module__loader__Module__Global__len(&self->modules));
  Vector__module__loader__Module__Global__push(&self->modules, (module__loader__Module){ .path = path, .file = file, .source = source, .ast = ast, .has_ast = has_ast, .prelude = false });
  return id;
}

static __attribute__((unused)) int32_t module__loader__Package__load_module(module__loader__Package *const self, str const mod_path, str const file_path, bool const bootstrap_tags) {
  const int32_t existing = module__loader__Package__find(self, mod_path);
  if (existing >= 0) {
    return existing;
  }
  String__Global source = String__Global__new();
  {
    const Option__String__Global __sc45 = module__loader__read_file(file_path);
    if (__sc45.tag == Option_Some) {
      String__Global s = __sc45.payload.Some._0;
      {
        (source = s);
      }
    }
    else if (__sc45.tag == Option_None) {
      {
        fprintf(stdio__stderr(), ((const char *)({ __auto_type __sc46 = (str){ (const uint8_t *)"error: cannot open module '%.*s' (%.*s)\n", sizeof("error: cannot open module '%.*s' (%.*s)\n") - 1 }; str__ptr(&__sc46); })), ((int32_t)str__len(&mod_path)), str__ptr(&mod_path), ((int32_t)str__len(&file_path)), str__ptr(&file_path));
        (self->ok = false);
        return -1;
      }
    }
  }
  module__loader__RealBuf fb = (module__loader__RealBuf){0};
  const size_t fl = str__len(&file_path);
  if (fl < 4096ULL) {
    memcpy(((void *)(&fb.b[0])), ((const void *)str__ptr(&file_path)), fl);
    (fb.b[fl] = 0);
  } else {
    (fb.b[0] = 0);
  }
  const module__loader__ParseResult parsed = module__loader__parse_source((&source), ((const char *)(&fb.b[0])), bootstrap_tags);
  const bool ok = parsed.ok;
  const int32_t id = module__loader__Package__add_module(self, String__Global__from_str(mod_path), String__Global__from_str(file_path), source, parsed.ast, ok);
  if (!ok) {
    (self->ok = false);
    return id;
  }
  ((*({ __auto_type __sc47 = &self->modules; Vector__module__loader__Module__Global__index_mut(__sc47, ((size_t)id)); })).ast.module = ((uint16_t)id));
  const str root_dir = String__Global__as_str(&self->root_dir);
  const str std_root = String__Global__as_str(&self->std_root);
  const size_t dca = ((size_t)((module__loader__DirCache *)(&self->dir_cache)));
  Vector__String__Global__Global child_paths = Vector__String__Global__Global__new();
  Vector__String__Global__Global child_files = Vector__String__Global__Global__new();
  {
    const module__loader__Module *const m = Vector__module__loader__Module__Global__at(&self->modules, ((size_t)id));
    const ast__ast__NodeList items = ast__ast__Ast__at_const(&m->ast, m->ast.root)->as_data.program.items;
    const uint32_t *const ids = ast__ast__Ast__list(&m->ast, items);
    const str src = String__Global__as_str(&m->source);
    for (uint32_t i = 0U; i < items.len; i++) {
      const ast__ast__Node *const n = ast__ast__Ast__at_const(&m->ast, ids[((size_t)i)]);
      if (n->kind == ast__ast__NodeKind_NODE_IMPORT) {
        const ast__ast__NodeList parts = n->as_data.import_decl.path;
        String__Global cp = module__loader__join_parts((&m->ast), src, parts, (str){ (const uint8_t *)"::", sizeof("::") - 1 });
        bool __mv2366 = false;
        if (module__loader__Package__find(self, String__Global__as_str(&cp)) < 0) {
          Vector__String__Global__Global__push(&child_paths, (__mv2366 = true, cp));
          Vector__String__Global__Global__push(&child_files, module__loader__resolve_import_file(dca, root_dir, std_root, (&m->ast), src, parts));
        }
        if (!__mv2366) String__Global__free(&cp);
      }
    }
  }
  for (size_t k = 0ULL; k < Vector__String__Global__Global__len(&child_paths); k++) {
    module__loader__Package__load_module(self, String__Global__as_str(&(*({ __auto_type __sc48 = &child_paths; Vector__String__Global__Global__index(__sc48, k); }))), String__Global__as_str(&(*({ __auto_type __sc49 = &child_files; Vector__String__Global__Global__index(__sc49, k); }))), bootstrap_tags);
  }
  {
    __auto_type __sc50 = id;
    Vector__String__Global__Global__free(&child_files);
    Vector__String__Global__Global__free(&child_paths);
    return __sc50;
  }
}

void module__loader__Package__seed_core(module__loader__Package *const self) {
  (self->core_seeded = false);
  for (size_t i = 0ULL; i < Vector__module__loader__Module__Global__len(&self->modules); i++) {
    const bool is_core = ((*({ __auto_type __sc51 = &self->modules; Vector__module__loader__Module__Global__index(__sc51, i); })).has_ast && (({ __auto_type __sc52 = String__Global__as_str(&(*({ __auto_type __sc54 = &self->modules; Vector__module__loader__Module__Global__index(__sc54, i); })).path); __auto_type __sc53 = (str){ (const uint8_t *)"__std::core", sizeof("__std::core") - 1 }; str__eq(&__sc52, &__sc53); })));
    if (is_core) {
      for (size_t b = 0ULL; b < module__loader__BT_COUNT_N; b++) {
        const uint32_t id = ast__ast__Ast__add(&(*({ __auto_type __sc55 = &self->modules; Vector__module__loader__Module__Global__index_mut(__sc55, i); })).ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_STRUCT, .as_data = (ast__ast__NodeAs){ .aggregate = (ast__ast__AggregateData){ .name = ast__ast__NODE_NONE, .is_public = true } } });
        (self->builtin_decls[b] = id);
      }
      (self->core_module = ((uint16_t)i));
      (self->core_seeded = true);
      return;
    }
  }
}

uint32_t module__loader__Package__builtin_decl(const module__loader__Package *const self, ast__ast__BuiltinType const b) {
  if (self->core_seeded && (((size_t)b) < module__loader__BT_COUNT_N)) {
    return self->builtin_decls[((size_t)b)];
  }
  return ast__ast__NODE_NONE;
}

int32_t module__loader__Package__builtin_of_decl(const module__loader__Package *const self, uint16_t const module, uint32_t const node) {
  if (((!self->core_seeded) || (module != self->core_module)) || (node == ast__ast__NODE_NONE)) {
    return -1;
  }
  for (size_t b = 0ULL; b < module__loader__BT_COUNT_N; b++) {
    if (self->builtin_decls[b] == node) {
      return ((int32_t)b);
    }
  }
  return -1;
}

void module__loader__Package__mark_method_used(module__loader__Package *const self, ast__ast__DefId const d) {
  if (d.node == ast__ast__NODE_NONE) {
    return;
  }
  const size_t m = ((size_t)d.module);
  while (Vector__Vector__bool__Global__Global__len(&self->method_used) <= m) {
    Vector__Vector__bool__Global__Global__push(&self->method_used, Vector__bool__Global__new());
  }
  Vector__bool__Global *const inner = (&(*({ __auto_type __sc56 = &self->method_used; Vector__Vector__bool__Global__Global__index_mut(__sc56, m); })));
  while (Vector__bool__Global__len(inner) <= ((size_t)d.node)) {
    Vector__bool__Global__push(inner, false);
  }
  Vector__bool__Global__set(inner, ((size_t)d.node), true);
}

bool module__loader__Package__method_used_get(const module__loader__Package *const self, ast__ast__DefId const d) {
  if (d.node == ast__ast__NODE_NONE) {
    return false;
  }
  const size_t m = ((size_t)d.module);
  if (m >= Vector__Vector__bool__Global__Global__len(&self->method_used)) {
    return false;
  }
  const Vector__bool__Global *const inner = Vector__Vector__bool__Global__Global__at(&self->method_used, m);
  if (((size_t)d.node) >= Vector__bool__Global__len(inner)) {
    return false;
  }
  return (*({ __auto_type __sc57 = inner; Vector__bool__Global__index(__sc57, ((size_t)d.node)); }));
}

void module__loader__Package__ensure_lk_index(module__loader__Package *const self, uint16_t const mid) {
  const size_t m = ((size_t)mid);
  while (Vector__Map__u64__module__loader__LkEnt__Global__Global__len(&self->lk_index) <= m) {
    Vector__Map__u64__module__loader__LkEnt__Global__Global__push(&self->lk_index, Map__u64__module__loader__LkEnt__Global__new());
  }
  while (Vector__bool__Global__len(&self->lk_built) <= m) {
    Vector__bool__Global__push(&self->lk_built, false);
  }
  if ((*({ __auto_type __sc58 = &self->lk_built; Vector__bool__Global__index(__sc58, m); }))) {
    return;
  }
  (*Vector__bool__Global__index_mut(&self->lk_built, m) = true);
  if (!(*({ __auto_type __sc59 = &self->modules; Vector__module__loader__Module__Global__index(__sc59, m); })).has_ast) {
    return;
  }
  const char *const srcp = ((const char *)({ __auto_type __sc60 = String__Global__as_str(&(*({ __auto_type __sc61 = &self->modules; Vector__module__loader__Module__Global__index(__sc61, m); })).source); str__ptr(&__sc60); }));
  const ast__ast__Ast *const ast = (&(*module__loader__Package__module_ast_ptr(self, mid)));
  const ast__ast__NodeList items = ast__ast__Ast__at_const(ast, ast->root)->as_data.program.items;
  const uint32_t *const ids = ast__ast__Ast__list(ast, items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = ids[((size_t)i)];
    const ast__ast__Node *const n = ast__ast__Ast__at_const(ast, nid);
    if (n->kind == ast__ast__NodeKind_NODE_EXTERN_BLOCK) {
      const ast__ast__NodeList inner = n->as_data.extern_block.items;
      const uint32_t *const iids = ast__ast__Ast__list(ast, inner);
      for (uint32_t j = 0U; j < inner.len; j++) {
        const uint32_t iid = iids[((size_t)j)];
        const ast__ast__Node *const it = ast__ast__Ast__at_const(ast, iid);
        uint32_t nn = ast__ast__NODE_NONE;
        bool ip = false;
        bool it_type = false;
        bool ok = true;
        if (it->kind == ast__ast__NodeKind_NODE_FUNCTION) {
          (nn = it->as_data.function.name);
          (ip = it->as_data.function.is_public);
          (it_type = false);
        } else if (it->kind == ast__ast__NodeKind_NODE_TYPE_ALIAS) {
          (nn = it->as_data.type_alias.name);
          (ip = it->as_data.type_alias.is_public);
          (it_type = true);
        } else if (it->kind == ast__ast__NodeKind_NODE_CONST) {
          (nn = it->as_data.const_def.name);
          (ip = it->as_data.const_def.is_public);
          (it_type = false);
        } else {
          (ok = false);
        }
        if (ok && ip) {
          const lexer__token__Span sp = ast__ast__Ast__at_const(ast, nn)->as_data.name.text;
          module__loader__Package__lk_emit(self, m, srcp, ((uint32_t)sp.start), ((uint32_t)sp.end), it_type, iid);
        }
      }
    } else {
      uint32_t name_node = ast__ast__NODE_NONE;
      bool is_pub = false;
      bool is_type = false;
      bool consider = true;
      if ((n->kind == ast__ast__NodeKind_NODE_STRUCT) || (n->kind == ast__ast__NodeKind_NODE_ENUM)) {
        (name_node = n->as_data.aggregate.name);
        (is_pub = n->as_data.aggregate.is_public);
        (is_type = true);
      } else if (n->kind == ast__ast__NodeKind_NODE_TYPE_ALIAS) {
        (name_node = n->as_data.type_alias.name);
        (is_pub = n->as_data.type_alias.is_public);
        (is_type = true);
      } else if (n->kind == ast__ast__NodeKind_NODE_INTERFACE) {
        (name_node = n->as_data.interface_def.name);
        (is_pub = n->as_data.interface_def.is_public);
        (is_type = true);
      } else if (n->kind == ast__ast__NodeKind_NODE_FUNCTION) {
        (name_node = n->as_data.function.name);
        (is_pub = n->as_data.function.is_public);
        (is_type = false);
      } else if (n->kind == ast__ast__NodeKind_NODE_CONST) {
        (name_node = n->as_data.const_def.name);
        (is_pub = n->as_data.const_def.is_public);
        (is_type = false);
      } else {
        (consider = false);
      }
      if (consider && is_pub) {
        const lexer__token__Span sp = ast__ast__Ast__at_const(ast, name_node)->as_data.name.text;
        module__loader__Package__lk_emit(self, m, srcp, ((uint32_t)sp.start), ((uint32_t)sp.end), is_type, nid);
      }
    }
  }
}

static __attribute__((unused)) void module__loader__Package__lk_emit(module__loader__Package *const self, size_t const m, const char *const srcp, uint32_t const start, uint32_t const end, bool const is_type, uint32_t const node) {
  const uint32_t len = (end - start);
  const uint8_t *const np = ((const uint8_t *)(srcp + ((size_t)start)));
  const str nm = str__from_raw(np, ((size_t)len));
  const uint64_t key = ((module__loader__fnv_name(nm) * 2ULL) + ({
    uint64_t __sc62;
    if (is_type) {
      __sc62 = 1ULL;
    } else {
      __sc62 = 0ULL;
    }
    __sc62;
  }));
  const module__loader__LkEnt ent = (module__loader__LkEnt){ .node = node, .start = start, .len = len };
  Map__u64__module__loader__LkEnt__Global *const mp = (&(*({ __auto_type __sc63 = &self->lk_index; Vector__Map__u64__module__loader__LkEnt__Global__Global__index_mut(__sc63, m); })));
  if (({ __auto_type __sc64 = Map__u64__module__loader__LkEnt__Global__get(mp, (&key)); Option__ptr_module__loader__LkEnt__is_none(&__sc64); })) {
    Map__u64__module__loader__LkEnt__Global__insert(mp, key, ent);
  }
}

uint32_t module__loader__Package__lookup(const module__loader__Package *const self, uint16_t const mid, str const name, bool const want_type) {
  if (!(*({ __auto_type __sc65 = &self->modules; Vector__module__loader__Module__Global__index(__sc65, ((size_t)mid)); })).has_ast) {
    return ast__ast__NODE_NONE;
  }
  module__loader__Package *const mp = ((module__loader__Package *)((const module__loader__Package *)self));
  {
    module__loader__Package__ensure_lk_index(&((*mp)), mid);
  }
  const char *const src = ((const char *)({ __auto_type __sc66 = String__Global__as_str(&(*({ __auto_type __sc67 = &self->modules; Vector__module__loader__Module__Global__index(__sc67, ((size_t)mid)); })).source); str__ptr(&__sc66); }));
  const uint64_t key = ((module__loader__fnv_name(name) * 2ULL) + ({
    uint64_t __sc68;
    if (want_type) {
      __sc68 = 1ULL;
    } else {
      __sc68 = 0ULL;
    }
    __sc68;
  }));
  {
    const Option__ptr_module__loader__LkEnt __sc69 = Map__u64__module__loader__LkEnt__Global__get(&(*({ __auto_type __sc70 = &self->lk_index; Vector__Map__u64__module__loader__LkEnt__Global__Global__index(__sc70, ((size_t)mid)); })), (&key));
    if (__sc69.tag == Option_Some) {
      const module__loader__LkEnt *const e = __sc69.payload.Some._0;
      return ({
        uint32_t r = ast__ast__NODE_NONE;
        if ((((size_t)e->len) == str__len(&name)) && (memcmp((src + ((size_t)e->start)), str__ptr(&name), str__len(&name)) == 0)) {
          (r = e->node);
        } else {
          (r = module__loader__Package__lookup_linear(self, mid, name, want_type));
        }
        r;
      });
    }
    else if (__sc69.tag == Option_None) {
      return ast__ast__NODE_NONE;
    }
    else { __builtin_unreachable(); }
  }
}

static __attribute__((unused)) uint32_t module__loader__Package__lookup_linear(const module__loader__Package *const self, uint16_t const mid, str const name, bool const want_type) {
  if (!(*({ __auto_type __sc71 = &self->modules; Vector__module__loader__Module__Global__index(__sc71, ((size_t)mid)); })).has_ast) {
    return ast__ast__NODE_NONE;
  }
  const ast__ast__Ast *const ast = (&(*module__loader__Package__module_ast_ptr(self, mid)));
  const char *const src = ((const char *)({ __auto_type __sc72 = String__Global__as_str(&(*({ __auto_type __sc73 = &self->modules; Vector__module__loader__Module__Global__index(__sc73, ((size_t)mid)); })).source); str__ptr(&__sc72); }));
  const ast__ast__NodeList items = ast__ast__Ast__at_const(ast, ast->root)->as_data.program.items;
  const uint32_t *const ids = ast__ast__Ast__list(ast, items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = ids[((size_t)i)];
    const ast__ast__Node *const n = ast__ast__Ast__at_const(ast, nid);
    uint32_t name_node = ast__ast__NODE_NONE;
    bool is_pub = false;
    bool is_type = false;
    bool consider = true;
    if ((n->kind == ast__ast__NodeKind_NODE_STRUCT) || (n->kind == ast__ast__NodeKind_NODE_ENUM)) {
      (name_node = n->as_data.aggregate.name);
      (is_pub = n->as_data.aggregate.is_public);
      (is_type = true);
    } else if (n->kind == ast__ast__NodeKind_NODE_TYPE_ALIAS) {
      (name_node = n->as_data.type_alias.name);
      (is_pub = n->as_data.type_alias.is_public);
      (is_type = true);
    } else if (n->kind == ast__ast__NodeKind_NODE_INTERFACE) {
      (name_node = n->as_data.interface_def.name);
      (is_pub = n->as_data.interface_def.is_public);
      (is_type = true);
    } else if (n->kind == ast__ast__NodeKind_NODE_FUNCTION) {
      (name_node = n->as_data.function.name);
      (is_pub = n->as_data.function.is_public);
      (is_type = false);
    } else if (n->kind == ast__ast__NodeKind_NODE_CONST) {
      (name_node = n->as_data.const_def.name);
      (is_pub = n->as_data.const_def.is_public);
      (is_type = false);
    } else if (n->kind == ast__ast__NodeKind_NODE_EXTERN_BLOCK) {
      const ast__ast__NodeList inner = n->as_data.extern_block.items;
      const uint32_t *const iids = ast__ast__Ast__list(ast, inner);
      for (uint32_t j = 0U; j < inner.len; j++) {
        const uint32_t iid = iids[((size_t)j)];
        const ast__ast__Node *const it = ast__ast__Ast__at_const(ast, iid);
        uint32_t nn = ast__ast__NODE_NONE;
        bool ip = false;
        bool it_type = false;
        bool ok = true;
        if (it->kind == ast__ast__NodeKind_NODE_FUNCTION) {
          (nn = it->as_data.function.name);
          (ip = it->as_data.function.is_public);
          (it_type = false);
        } else if (it->kind == ast__ast__NodeKind_NODE_TYPE_ALIAS) {
          (nn = it->as_data.type_alias.name);
          (ip = it->as_data.type_alias.is_public);
          (it_type = true);
        } else if (it->kind == ast__ast__NodeKind_NODE_CONST) {
          (nn = it->as_data.const_def.name);
          (ip = it->as_data.const_def.is_public);
          (it_type = false);
        } else {
          (ok = false);
        }
        if ((ok && ip) && (it_type == want_type)) {
          const lexer__token__Span sp = ast__ast__Ast__at_const(ast, nn)->as_data.name.text;
          const size_t l = ((size_t)(sp.end - sp.start));
          if ((l == str__len(&name)) && (memcmp((src + ((size_t)sp.start)), str__ptr(&name), str__len(&name)) == 0)) {
            return iid;
          }
        }
      }
      (consider = false);
    } else {
      (consider = false);
    }
    if ((consider && is_pub) && (is_type == want_type)) {
      const lexer__token__Span sp = ast__ast__Ast__at_const(ast, name_node)->as_data.name.text;
      const size_t l = ((size_t)(sp.end - sp.start));
      if ((l == str__len(&name)) && (memcmp((src + ((size_t)sp.start)), str__ptr(&name), str__len(&name)) == 0)) {
        return nid;
      }
    }
  }
  return ast__ast__NODE_NONE;
}

module__loader__LookupHit module__loader__Package__prelude_lookup(const module__loader__Package *const self, str const name, bool const want_type) {
  for (size_t i = 0ULL; i < Vector__module__loader__Module__Global__len(&self->modules); i++) {
    if ((*({ __auto_type __sc74 = &self->modules; Vector__module__loader__Module__Global__index(__sc74, i); })).prelude) {
      const uint32_t d = module__loader__Package__lookup(self, ((uint16_t)i), name, want_type);
      if (d != ast__ast__NODE_NONE) {
        return (module__loader__LookupHit){ .node = d, .mid = ((uint16_t)i) };
      }
    }
  }
  return (module__loader__LookupHit){ .node = ast__ast__NODE_NONE, .mid = 0U };
}

module__loader__LookupHit module__loader__Package__glob_lookup(const module__loader__Package *const self, uint16_t const mid, str const name, bool const want_type) {
  const size_t n = Vector__module__loader__Module__Global__len(&self->modules);
  module__loader__LookupHit result = (module__loader__LookupHit){ .node = ast__ast__NODE_NONE, .mid = 0U };
  if (((size_t)mid) >= n) {
    return result;
  }
  Vector__bool__Global seen = Vector__bool__Global__new();
  for (size_t s = 0ULL; s < n; s++) {
    Vector__bool__Global__push(&seen, false);
  }
  Vector__u16__Global queue = Vector__u16__Global__new();
  Vector__u16__Global__push(&queue, mid);
  Vector__bool__Global__set(&seen, ((size_t)mid), true);
  size_t head = 0ULL;
  while (head < Vector__u16__Global__len(&queue)) {
    const uint16_t mo = (*({ __auto_type __sc75 = &queue; Vector__u16__Global__index(__sc75, head); }));
    (head = (head + 1ULL));
    const uint32_t d = module__loader__Package__lookup(self, mo, name, want_type);
    if (d != ast__ast__NODE_NONE) {
      (result = (module__loader__LookupHit){ .node = d, .mid = mo });
      break;
    }
    if ((*({ __auto_type __sc76 = &self->modules; Vector__module__loader__Module__Global__index(__sc76, ((size_t)mo)); })).has_ast) {
      const module__loader__Module *const md = Vector__module__loader__Module__Global__at(&self->modules, ((size_t)mo));
      const ast__ast__NodeList items = ast__ast__Ast__at_const(&md->ast, md->ast.root)->as_data.program.items;
      const uint32_t *const ids = ast__ast__Ast__list(&md->ast, items);
      const str src = String__Global__as_str(&md->source);
      for (uint32_t i = 0U; i < items.len; i++) {
        const ast__ast__Node *const it = ast__ast__Ast__at_const(&md->ast, ids[((size_t)i)]);
        if (it->kind == ast__ast__NodeKind_NODE_IMPORT) {
          String__Global path = module__loader__join_parts((&md->ast), src, it->as_data.import_decl.path, (str){ (const uint8_t *)"::", sizeof("::") - 1 });
          const int32_t c = module__loader__Package__find(self, String__Global__as_str(&path));
          if ((c >= 0) && (!(*({ __auto_type __sc77 = &seen; Vector__bool__Global__index(__sc77, ((size_t)c)); })))) {
            Vector__bool__Global__set(&seen, ((size_t)c), true);
            Vector__u16__Global__push(&queue, ((uint16_t)c));
          }
          String__Global__free(&path);
        }
      }
    }
  }
  {
    __auto_type __sc78 = result;
    Vector__u16__Global__free(&queue);
    Vector__bool__Global__free(&seen);
    return __sc78;
  }
}

Vector__u16__Global module__loader__Package__import_closure(const module__loader__Package *const self, uint16_t const mid) {
  const size_t n = Vector__module__loader__Module__Global__len(&self->modules);
  Vector__u16__Global out = Vector__u16__Global__new();
  if (((size_t)mid) > n) {
    return out;
  }
  Vector__bool__Global seen = Vector__bool__Global__new();
  for (size_t s = 0ULL; s < (n + 1ULL); s++) {
    Vector__bool__Global__push(&seen, false);
  }
  Vector__bool__Global__set(&seen, ((size_t)mid), true);
  size_t head = 0ULL;
  uint16_t cur = mid;
  bool go = true;
  while (go) {
    if ((((size_t)cur) < n) && (*({ __auto_type __sc79 = &self->modules; Vector__module__loader__Module__Global__index(__sc79, ((size_t)cur)); })).has_ast) {
      const ast__ast__Ast *const ast = (&(*module__loader__Package__module_ast_ptr(self, cur)));
      const ast__ast__NodeList items = ast__ast__Ast__at_const(ast, ast->root)->as_data.program.items;
      const uint32_t *const ids = ast__ast__Ast__list(ast, items);
      const str src = String__Global__as_str(&(*({ __auto_type __sc80 = &self->modules; Vector__module__loader__Module__Global__index(__sc80, ((size_t)cur)); })).source);
      for (uint32_t i = 0U; i < items.len; i++) {
        const ast__ast__Node *const it = ast__ast__Ast__at_const(ast, ids[((size_t)i)]);
        if (it->kind == ast__ast__NodeKind_NODE_IMPORT) {
          String__Global path = module__loader__join_parts((&(*ast)), src, it->as_data.import_decl.path, (str){ (const uint8_t *)"::", sizeof("::") - 1 });
          const int32_t c = module__loader__Package__find(self, String__Global__as_str(&path));
          if ((c >= 0) && (!(*({ __auto_type __sc81 = &seen; Vector__bool__Global__index(__sc81, ((size_t)c)); })))) {
            Vector__bool__Global__set(&seen, ((size_t)c), true);
            Vector__u16__Global__push(&out, ((uint16_t)c));
          }
          String__Global__free(&path);
        }
      }
    }
    if (head >= Vector__u16__Global__len(&out)) {
      (go = false);
    } else {
      (cur = (*({ __auto_type __sc82 = &out; Vector__u16__Global__index(__sc82, head); })));
      (head = (head + 1ULL));
    }
  }
  {
    __auto_type __sc83 = out;
    Vector__bool__Global__free(&seen);
    return __sc83;
  }
}

static __attribute__((unused)) bool module__loader__Package__module_is_user(const module__loader__Package *const self, uint16_t const m) {
  return ((((size_t)m) >= Vector__module__loader__Module__Global__len(&self->modules)) || (!(*({ __auto_type __sc84 = &self->modules; Vector__module__loader__Module__Global__index(__sc84, ((size_t)m)); })).prelude));
}

static __attribute__((unused)) bool module__loader__Package__module_imports(const module__loader__Package *const self, uint16_t const from, uint16_t const to) {
  const size_t n = Vector__module__loader__Module__Global__len(&self->modules);
  if ((((size_t)from) >= n) || (!(*({ __auto_type __sc85 = &self->modules; Vector__module__loader__Module__Global__index(__sc85, ((size_t)from)); })).has_ast)) {
    return false;
  }
  if (self->mod_refs_ready && (((size_t)to) < n)) {
    const uint64_t word = (*({ __auto_type __sc86 = &self->mod_refs; Vector__u64__Global__index(__sc86, ((((size_t)from) * self->mod_refs_w) + ({ size_t __sc87 = ((size_t)to); size_t __sc88 = 64ULL; if (__sc88 == 0) { __sc_panic("divide by zero"); } (__sc87 / __sc88); }))); }));
    return ((word & ({ uint64_t __sc89 = 1ULL; int64_t __sc90 = (int64_t)(((uint64_t)({ size_t __sc91 = ((size_t)to); size_t __sc92 = 64ULL; if (__sc92 == 0) { __sc_panic("divide by zero"); } (__sc91 % __sc92); }))); if ((uint64_t)__sc90 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc89 << __sc90)); })) != 0ULL);
  }
  const Vector__ast__ast__DefId__Global *const r = (&(*({ __auto_type __sc93 = &self->modules; Vector__module__loader__Module__Global__index(__sc93, ((size_t)from)); })).ast.resolutions);
  for (size_t i = 0ULL; i < Vector__ast__ast__DefId__Global__len(r); i++) {
    const ast__ast__DefId d = (*({ __auto_type __sc94 = r; Vector__ast__ast__DefId__Global__index(__sc94, i); }));
    if ((d.node != ast__ast__NODE_NONE) && (d.module == to)) {
      return true;
    }
  }
  return false;
}

void module__loader__Package__build_mod_refs(module__loader__Package *const self) {
  const size_t n = Vector__module__loader__Module__Global__len(&self->modules);
  const size_t w = ({ size_t __sc95 = (n + 63ULL); size_t __sc96 = 64ULL; if (__sc96 == 0) { __sc_panic("divide by zero"); } (__sc95 / __sc96); });
  (self->mod_refs_w = w);
  Vector__u64__Global__clear(&self->mod_refs);
  const size_t total = (n * w);
  for (size_t _z = 0ULL; _z < total; _z++) {
    Vector__u64__Global__push(&self->mod_refs, 0ULL);
  }
  for (size_t from = 0ULL; from < n; from++) {
    if (!(*({ __auto_type __sc97 = &self->modules; Vector__module__loader__Module__Global__index(__sc97, from); })).has_ast) {
      continue;
    }
    const size_t base = (from * w);
    const Vector__ast__ast__DefId__Global *const r = (&(*({ __auto_type __sc98 = &self->modules; Vector__module__loader__Module__Global__index(__sc98, from); })).ast.resolutions);
    for (size_t k = 0ULL; k < Vector__ast__ast__DefId__Global__len(r); k++) {
      const ast__ast__DefId d = (*({ __auto_type __sc99 = r; Vector__ast__ast__DefId__Global__index(__sc99, k); }));
      const size_t to = ((size_t)d.module);
      if ((d.node != ast__ast__NODE_NONE) && (to < n)) {
        const size_t idx = (base + ({ size_t __sc100 = to; size_t __sc101 = 64ULL; if (__sc101 == 0) { __sc_panic("divide by zero"); } (__sc100 / __sc101); }));
        const uint64_t cur = (*({ __auto_type __sc102 = &self->mod_refs; Vector__u64__Global__index(__sc102, idx); }));
        (*Vector__u64__Global__index_mut(&self->mod_refs, idx) = (cur | ({ uint64_t __sc103 = 1ULL; int64_t __sc104 = (int64_t)(((uint64_t)({ size_t __sc105 = to; size_t __sc106 = 64ULL; if (__sc106 == 0) { __sc_panic("divide by zero"); } (__sc105 % __sc106); }))); if ((uint64_t)__sc104 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc103 << __sc104)); })));
      }
    }
  }
  (self->mod_refs_ready = true);
}

static __attribute__((unused)) uint16_t module__loader__Package__type_user_home(const module__loader__Package *const self, uint16_t const am, uint32_t const t) {
  const ast__ast__Ty y = (*ast__ast__Ast__type_at(&(*({ __auto_type __sc107 = &self->modules; Vector__module__loader__Module__Global__index(__sc107, ((size_t)am)); })).ast, t));
  if (((y.kind == ast__ast__TypeKind_TYPE_POINTER) || (y.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (y.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    return module__loader__Package__type_user_home(self, am, y.as_data.elem);
  }
  if (y.kind == ast__ast__TypeKind_TYPE_SLICE) {
    return 65535U;
  }
  if (((y.kind == ast__ast__TypeKind_TYPE_STRUCT) || (y.kind == ast__ast__TypeKind_TYPE_ENUM)) || (y.kind == ast__ast__TypeKind_TYPE_FUNCTION)) {
    if (module__loader__Package__module_is_user(self, y.module)) {
      return y.module;
    }
    return 65535U;
  }
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&(*({ __auto_type __sc108 = &self->modules; Vector__module__loader__Module__Global__index(__sc108, ((size_t)am)); })).ast, y.as_data.inst));
    return module__loader__Package__instance_home_in(self, am, (&it));
  }
  return 65535U;
}

static __attribute__((unused)) uint16_t module__loader__Package__instance_home_in(const module__loader__Package *const self, uint16_t const am, const ast__ast__TyInstance *const it) {
  for (uint8_t i = 0U; i < it->n; i++) {
    const uint16_t h = module__loader__Package__type_user_home(self, am, it->args[((size_t)i)]);
    if ((h != 65535U) && (module__loader__Package__module_is_user(self, h) || module__loader__Package__module_imports(self, h, it->module))) {
      return h;
    }
  }
  return it->module;
}

uint16_t module__loader__Package__instance_home(const module__loader__Package *const self, const ast__ast__Ast *const a, const ast__ast__TyInstance *const it) {
  return module__loader__Package__instance_home_in(self, a->module, it);
}

uint16_t module__loader__Package__instance_home_mid(const module__loader__Package *const self, uint16_t const am, const ast__ast__TyInstance *const it) {
  return module__loader__Package__instance_home_in(self, am, it);
}

void module__loader__Package__free(module__loader__Package *const self) {
  Vector__module__loader__Module__Global__free(&self->modules);
  String__Global__free(&self->root_dir);
  String__Global__free(&self->std_root);
  Vector__Vector__bool__Global__Global__free(&self->method_used);
  Vector__u64__Global__free(&self->mod_refs);
  Vector__Map__u64__module__loader__LkEnt__Global__Global__free(&self->lk_index);
  Vector__bool__Global__free(&self->lk_built);
  module__loader__DirCache__free(&self->dir_cache);
}

static __attribute__((unused)) ast__ast__Ast *module__loader__pkg_ast_m(module__loader__Package *const p, uint16_t const m) {
  return ((ast__ast__Ast *)(&(*({ __auto_type __sc109 = &p->modules; Vector__module__loader__Module__Global__index_mut(__sc109, ((size_t)m)); })).ast));
}

static __attribute__((unused)) const ast__ast__Ast *module__loader__pkg_ast_c(const module__loader__Package *const p, uint16_t const m) {
  return ((const ast__ast__Ast *)(&(*({ __auto_type __sc110 = &p->modules; Vector__module__loader__Module__Global__index(__sc110, ((size_t)m)); })).ast));
}

static __attribute__((unused)) bool module__loader__type_mentions_fnval(const module__loader__Package *const p, uint16_t const mid, uint32_t const t) {
  const ast__ast__Ty y = (*ast__ast__Ast__type_at(module__loader__pkg_ast_c((&(*p)), mid), t));
  if (y.kind == ast__ast__TypeKind_TYPE_FUNCTION) {
    return true;
  }
  if ((((y.kind == ast__ast__TypeKind_TYPE_POINTER) || (y.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (y.kind == ast__ast__TypeKind_TYPE_SLICE)) || (y.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    return module__loader__type_mentions_fnval((&(*p)), mid, y.as_data.elem);
  }
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(module__loader__pkg_ast_c((&(*p)), mid), y.as_data.inst));
    for (uint8_t i = 0U; i < it.n; i++) {
      if (module__loader__type_mentions_fnval((&(*p)), mid, it.args[((size_t)i)])) {
        return true;
      }
    }
    return false;
  }
  return false;
}

static __attribute__((unused)) uint32_t module__loader__subst_reintern_type(module__loader__Package *const p, uint16_t const dm, uint16_t const om, uint32_t const t, uint16_t const gmod, const uint32_t *const gids, const uint32_t *const args, uint8_t const nargs) {
  if (t == ast__ast__TYPE_NONE) {
    return ast__ast__TYPE_NONE;
  }
  const ast__ast__Ty ty = (*ast__ast__Ast__type_at(module__loader__pkg_ast_c((&(*p)), om), t));
  if (ty.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    for (uint8_t i = 0U; i < nargs; i++) {
      if ((ty.module == gmod) && (ty.as_data.decl == gids[((size_t)i)])) {
        return args[((size_t)i)];
      }
    }
    ast__ast__Ast *const d = module__loader__pkg_ast_m((&(*p)), dm);
    const ast__ast__Ast *const o = module__loader__pkg_ast_c((&(*p)), om);
    return ast__ast__Ast__reintern(&((*d)), (&(*o)), t);
  }
  if ((((ty.kind == ast__ast__TypeKind_TYPE_POINTER) || (ty.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (ty.kind == ast__ast__TypeKind_TYPE_SLICE)) || (ty.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    ast__ast__Ty nt = ty;
    (nt.as_data.elem = module__loader__subst_reintern_type((&(*p)), dm, om, ty.as_data.elem, gmod, gids, args, nargs));
    ast__ast__Ast *const d = module__loader__pkg_ast_m((&(*p)), dm);
    return ast__ast__Ast__intern_type(&((*d)), nt);
  }
  if (ty.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance inst = (*ast__ast__Ast__instance(module__loader__pkg_ast_c((&(*p)), om), ty.as_data.inst));
    uint32_t na[4] = { 0U, 0U, 0U, 0U };
    const uint8_t m = ({
      uint8_t __sc111;
      if (inst.n < 4U) {
        __sc111 = inst.n;
      } else {
        __sc111 = 4U;
      }
      __sc111;
    });
    for (uint8_t i = 0U; i < m; i++) {
      (na[__sc_bounds(((size_t)i), 4)] = module__loader__subst_reintern_type((&(*p)), dm, om, inst.args[((size_t)i)], gmod, gids, args, nargs));
    }
    ast__ast__Ast *const d = module__loader__pkg_ast_m((&(*p)), dm);
    return ast__ast__Ast__intern_instance(&((*d)), inst.module, inst.decl, (&na[0]), m);
  }
  ast__ast__Ast *const d = module__loader__pkg_ast_m((&(*p)), dm);
  const ast__ast__Ast *const o = module__loader__pkg_ast_c((&(*p)), om);
  return ast__ast__Ast__reintern(&((*d)), (&(*o)), t);
}

static __attribute__((unused)) void module__loader__reintern_nested_type(module__loader__Package *const p, uint16_t const dm, uint16_t const om, uint32_t const t, uint16_t const gmod, const uint32_t *const gids, const uint32_t *const args, uint8_t const nargs, bool *const changed) {
  if (t == ast__ast__TYPE_NONE) {
    return;
  }
  const size_t before = Vector__ast__ast__TyInstance__Global__len(&(*module__loader__pkg_ast_c((&(*p)), dm)).instances);
  uint32_t st = module__loader__subst_reintern_type((&(*p)), dm, om, t, gmod, gids, args, nargs);
  ast__ast__Ty y = (*ast__ast__Ast__type_at(module__loader__pkg_ast_c((&(*p)), dm), st));
  while (y.kind == ast__ast__TypeKind_TYPE_ARRAY) {
    (st = y.as_data.elem);
    (y = (*ast__ast__Ast__type_at(module__loader__pkg_ast_c((&(*p)), dm), st)));
  }
  if (y.kind != ast__ast__TypeKind_TYPE_INSTANCE) {
    return;
  }
  const ast__ast__TyInstance it = (*ast__ast__Ast__instance(module__loader__pkg_ast_c((&(*p)), dm), y.as_data.inst));
  bool concrete = true;
  for (uint8_t i = 0U; i < it.n; i++) {
    if (!ast__ast__Ast__type_concrete(&((*module__loader__pkg_ast_c((&(*p)), dm))), it.args[((size_t)i)])) {
      (concrete = false);
    }
  }
  if (!concrete) {
    return;
  }
  const size_t np = Vector__module__loader__Module__Global__len(&p->modules);
  const uint16_t home = module__loader__Package__instance_home_mid(p, dm, (&it));
  bool has_h = false;
  uint16_t hm = 0U;
  if (((size_t)home) < np) {
    (has_h = true);
    (hm = home);
  } else if (dm == home) {
    (has_h = true);
    (hm = dm);
  }
  if (has_h && (hm != dm)) {
    const uint8_t m = ({
      uint8_t __sc112;
      if (it.n < 4U) {
        __sc112 = it.n;
      } else {
        __sc112 = 4U;
      }
      __sc112;
    });
    uint32_t na[4] = { 0U, 0U, 0U, 0U };
    const size_t hbefore = Vector__ast__ast__TyInstance__Global__len(&(*module__loader__pkg_ast_c((&(*p)), hm)).instances);
    for (uint8_t k = 0U; k < m; k++) {
      ast__ast__Ast *const h = module__loader__pkg_ast_m((&(*p)), hm);
      const ast__ast__Ast *const d = module__loader__pkg_ast_c((&(*p)), dm);
      (na[__sc_bounds(((size_t)k), 4)] = ast__ast__Ast__reintern(&((*h)), (&(*d)), it.args[((size_t)k)]));
    }
    ast__ast__Ast *const h = module__loader__pkg_ast_m((&(*p)), hm);
    (void)(ast__ast__Ast__intern_instance(&((*h)), it.module, it.decl, (&na[0]), m));
    const size_t hafter = Vector__ast__ast__TyInstance__Global__len(&(*module__loader__pkg_ast_c((&(*p)), hm)).instances);
    if (hafter != hbefore) {
      ((*changed) = true);
    }
  }
  const size_t after = Vector__ast__ast__TyInstance__Global__len(&(*module__loader__pkg_ast_c((&(*p)), dm)).instances);
  if (after != before) {
    ((*changed) = true);
  }
}

static __attribute__((unused)) void module__loader__reintern_nested_instance_deps(module__loader__Package *const p, uint16_t const dm, const ast__ast__TyInstance *const it, const uint32_t *const args, uint8_t const nargs, bool *const changed) {
  const size_t np = Vector__module__loader__Module__Global__len(&p->modules);
  const uint16_t itmod = it->module;
  if ((((size_t)itmod) >= np) || (!(*({ __auto_type __sc113 = &p->modules; Vector__module__loader__Module__Global__index(__sc113, ((size_t)itmod)); })).has_ast)) {
    return;
  }
  const uint32_t decl = it->decl;
  const ast__ast__NodeKind dn_kind = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), decl)->kind;
  const ast__ast__NodeList generics = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), decl)->as_data.aggregate.generics;
  if (((dn_kind != ast__ast__NodeKind_NODE_STRUCT) && (dn_kind != ast__ast__NodeKind_NODE_ENUM)) || (generics.len == 0U)) {
    return;
  }
  const ast__ast__NodeList members = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), decl)->as_data.aggregate.members;
  const uint32_t *const gids = ast__ast__Ast__list(&((*module__loader__pkg_ast_c((&(*p)), itmod))), generics);
  const uint32_t *const mids = ast__ast__Ast__list(&((*module__loader__pkg_ast_c((&(*p)), itmod))), members);
  for (uint32_t m = 0U; m < members.len; m++) {
    const uint32_t mid = mids[((size_t)m)];
    const ast__ast__NodeKind mnk = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), mid)->kind;
    if ((dn_kind == ast__ast__NodeKind_NODE_STRUCT) && (mnk == ast__ast__NodeKind_NODE_FIELD)) {
      const uint32_t fty = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), mid)->as_data.field.ty;
      const uint32_t tt = ast__ast__Ast__type_of(&((*module__loader__pkg_ast_c((&(*p)), itmod))), fty);
      module__loader__reintern_nested_type((&(*p)), dm, itmod, tt, itmod, gids, args, nargs, changed);
    } else if ((dn_kind == ast__ast__NodeKind_NODE_ENUM) && (mnk == ast__ast__NodeKind_NODE_VARIANT)) {
      const ast__ast__NodeList payload = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), mid)->as_data.variant.payload;
      const uint32_t *const pids = ast__ast__Ast__list(&((*module__loader__pkg_ast_c((&(*p)), itmod))), payload);
      for (uint32_t k = 0U; k < payload.len; k++) {
        const uint32_t pfid = pids[((size_t)k)];
        const ast__ast__NodeKind pfk = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), pfid)->kind;
        const uint32_t tn = ({
          uint32_t __sc114;
          if (pfk == ast__ast__NodeKind_NODE_FIELD) {
            __sc114 = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), pfid)->as_data.field.ty;
          } else {
            __sc114 = pfid;
          }
          __sc114;
        });
        const uint32_t tt = ast__ast__Ast__type_of(&((*module__loader__pkg_ast_c((&(*p)), itmod))), tn);
        module__loader__reintern_nested_type((&(*p)), dm, itmod, tt, itmod, gids, args, nargs, changed);
      }
    }
  }
}

static __attribute__((unused)) void module__loader__reintern_method_signature_deps(module__loader__Package *const p, uint16_t const dm, const ast__ast__TyInstance *const it, const uint32_t *const args, uint8_t const nargs, bool *const changed) {
  const size_t np = Vector__module__loader__Module__Global__len(&p->modules);
  const uint16_t itmod = it->module;
  if ((((size_t)itmod) >= np) || (!(*({ __auto_type __sc115 = &p->modules; Vector__module__loader__Module__Global__index(__sc115, ((size_t)itmod)); })).has_ast)) {
    return;
  }
  const uint32_t itdecl = it->decl;
  const uint32_t root = (*module__loader__pkg_ast_c((&(*p)), itmod)).root;
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), root)->as_data.program.items;
  const uint32_t *const ids = ast__ast__Ast__list(&((*module__loader__pkg_ast_c((&(*p)), itmod))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t eid = ids[((size_t)i)];
    const ast__ast__NodeKind ek = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), eid)->kind;
    if (ek != ast__ast__NodeKind_NODE_EXTEND) {
      continue;
    }
    const ast__ast__NodeList egen = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), eid)->as_data.extend_def.generics;
    if (egen.len == 0U) {
      continue;
    }
    const uint32_t etgt = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), eid)->as_data.extend_def.target_type;
    if (ast__ast__Ast__resolution(&((*module__loader__pkg_ast_c((&(*p)), itmod))), etgt) != itdecl) {
      continue;
    }
    const uint32_t *const gids = ast__ast__Ast__list(&((*module__loader__pkg_ast_c((&(*p)), itmod))), egen);
    const ast__ast__NodeList eitems = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), eid)->as_data.extend_def.items;
    const uint32_t *const emids = ast__ast__Ast__list(&((*module__loader__pkg_ast_c((&(*p)), itmod))), eitems);
    for (uint32_t mm = 0U; mm < eitems.len; mm++) {
      const uint32_t fnid = emids[((size_t)mm)];
      const ast__ast__NodeKind fnk = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), fnid)->kind;
      if (fnk != ast__ast__NodeKind_NODE_FUNCTION) {
        continue;
      }
      const ast__ast__NodeList fgen = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), fnid)->as_data.function.generics;
      const ast__ast__NodeList frets = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), fnid)->as_data.function.returns;
      if ((fgen.len != 0U) || (frets.len > 1U)) {
        continue;
      }
      const ast__ast__NodeList fparams = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), fnid)->as_data.function.params;
      const uint32_t *const pids = ast__ast__Ast__list(&((*module__loader__pkg_ast_c((&(*p)), itmod))), fparams);
      uint32_t k = 0U;
      while (k < fparams.len) {
        const uint32_t pid = pids[((size_t)k)];
        const uint32_t pty = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), pid)->as_data.parameter.ty;
        const uint32_t tt = ast__ast__Ast__type_of(&((*module__loader__pkg_ast_c((&(*p)), itmod))), pty);
        module__loader__reintern_nested_type((&(*p)), dm, itmod, tt, itmod, gids, args, nargs, changed);
        (k = (k + 1U));
      }
      const uint32_t *const rids = ast__ast__Ast__list(&((*module__loader__pkg_ast_c((&(*p)), itmod))), frets);
      (k = 0U);
      while (k < frets.len) {
        const uint32_t rid = rids[((size_t)k)];
        const ast__ast__NodeKind rk = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), rid)->kind;
        const uint32_t tn = ({
          uint32_t __sc116;
          if (rk == ast__ast__NodeKind_NODE_PARAMETER) {
            __sc116 = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), itmod))), rid)->as_data.parameter.ty;
          } else {
            __sc116 = rid;
          }
          __sc116;
        });
        const uint32_t tt = ast__ast__Ast__type_of(&((*module__loader__pkg_ast_c((&(*p)), itmod))), tn);
        module__loader__reintern_nested_type((&(*p)), dm, itmod, tt, itmod, gids, args, nargs, changed);
        (k = (k + 1U));
      }
    }
  }
}

static __attribute__((unused)) bool module__loader__reintern_cross_module(module__loader__Package *const p, uint16_t const sm, size_t const start) {
  bool changed = false;
  const ast__ast__Ast *const s = module__loader__pkg_ast_c((&(*p)), sm);
  const size_t n = Vector__ast__ast__TyInstance__Global__len(&(*s).instances);
  const size_t np = Vector__module__loader__Module__Global__len(&p->modules);
  for (size_t i = start; i < n; i++) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(s, ((uint32_t)i)));
    bool concrete = true;
    for (uint8_t k = 0U; k < it.n; k++) {
      if (!ast__ast__Ast__type_concrete(&((*s)), it.args[((size_t)k)])) {
        (concrete = false);
      }
    }
    if (!concrete) {
      continue;
    }
    const uint16_t home = module__loader__Package__instance_home_mid(p, sm, (&it));
    if (((size_t)home) >= np) {
      continue;
    }
    const uint16_t dm = home;
    const uint8_t m = ({
      uint8_t __sc117;
      if (it.n < 4U) {
        __sc117 = it.n;
      } else {
        __sc117 = 4U;
      }
      __sc117;
    });
    uint32_t na[4] = { 0U, 0U, 0U, 0U };
    for (uint8_t k2 = 0U; k2 < m; k2++) {
      if (dm == sm) {
        (na[__sc_bounds(((size_t)k2), 4)] = it.args[((size_t)k2)]);
      } else {
        ast__ast__Ast *const d = module__loader__pkg_ast_m((&(*p)), dm);
        (na[__sc_bounds(((size_t)k2), 4)] = ast__ast__Ast__reintern(&((*d)), (&(*s)), it.args[((size_t)k2)]));
      }
    }
    if (dm != sm) {
      const size_t before = Vector__ast__ast__TyInstance__Global__len(&(*module__loader__pkg_ast_c((&(*p)), dm)).instances);
      ast__ast__Ast *const d = module__loader__pkg_ast_m((&(*p)), dm);
      (void)(ast__ast__Ast__intern_instance(&((*d)), it.module, it.decl, (&na[0]), m));
      const size_t after = Vector__ast__ast__TyInstance__Global__len(&(*module__loader__pkg_ast_c((&(*p)), dm)).instances);
      if (after != before) {
        (changed = true);
      }
    }
    bool *const cp = ((bool *)(&changed));
    module__loader__reintern_nested_instance_deps((&(*p)), dm, (&it), (&na[0]), m, cp);
    module__loader__reintern_method_signature_deps((&(*p)), dm, (&it), (&na[0]), m, cp);
  }
  return changed;
}

static __attribute__((unused)) bool module__loader__reintern_method_insts(module__loader__Package *const p, uint16_t const sm) {
  bool changed = false;
  const ast__ast__Ast *const s = module__loader__pkg_ast_c((&(*p)), sm);
  const size_t n = Vector__ast__ast__Node__Global__len(&(*s).nodes);
  const size_t np = Vector__module__loader__Module__Global__len(&p->modules);
  uint32_t i = 0U;
  while (((size_t)i) < n) {
    const ast__ast__NodeKind ck = ast__ast__Ast__at_const(&((*s)), i)->kind;
    if (ck != ast__ast__NodeKind_NODE_CALL) {
      (i = (i + 1U));
      continue;
    }
    const uint32_t callee_id = ast__ast__Ast__at_const(&((*s)), i)->as_data.call.callee;
    const ast__ast__NodeKind cek = ast__ast__Ast__at_const(&((*s)), callee_id)->kind;
    if (cek != ast__ast__NodeKind_NODE_MEMBER) {
      (i = (i + 1U));
      continue;
    }
    const uint32_t member_id = ast__ast__Ast__at_const(&((*s)), callee_id)->as_data.member.member;
    const ast__ast__DefId md = ast__ast__Ast__resolution_def(&((*s)), member_id);
    if (md.node == ast__ast__NODE_NONE) {
      (i = (i + 1U));
      continue;
    }
    if ((((size_t)md.module) >= np) || (!(*({ __auto_type __sc118 = &p->modules; Vector__module__loader__Module__Global__index(__sc118, ((size_t)md.module)); })).has_ast)) {
      (i = (i + 1U));
      continue;
    }
    const uint16_t om = md.module;
    const ast__ast__NodeKind mnk = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), om))), md.node)->kind;
    const ast__ast__NodeList mgen = ast__ast__Ast__at_const(&((*module__loader__pkg_ast_c((&(*p)), om))), md.node)->as_data.function.generics;
    if ((mnk != ast__ast__NodeKind_NODE_FUNCTION) || (mgen.len == 0U)) {
      (i = (i + 1U));
      continue;
    }
    const ast__ast__MonoUse *const mu = ast__ast__Ast__type_args(&((*s)), i);
    if ((mu == NULL) || ((*mu).n == 0U)) {
      (i = (i + 1U));
      continue;
    }
    const uint32_t object_id = ast__ast__Ast__at_const(&((*s)), callee_id)->as_data.member.object;
    uint32_t rty = ast__ast__Ast__type_of(&((*s)), object_id);
    const ast__ast__DerefUse *const du = ast__ast__Ast__deref_use_at(&((*s)), member_id);
    if (du != NULL) {
      (rty = (*du).target);
    }
    ast__ast__TypeKind yk = ast__ast__Ast__type_at(&((*s)), rty)->kind;
    while ((yk == ast__ast__TypeKind_TYPE_POINTER) || (yk == ast__ast__TypeKind_TYPE_REFERENCE)) {
      (rty = ast__ast__Ast__type_at(&((*s)), rty)->as_data.elem);
      (yk = ast__ast__Ast__type_at(&((*s)), rty)->kind);
    }
    if ((ast__ast__Ast__type_at(&((*s)), rty)->kind != ast__ast__TypeKind_TYPE_INSTANCE) || (!ast__ast__Ast__type_concrete(&((*s)), rty))) {
      (i = (i + 1U));
      continue;
    }
    const uint8_t mtn = ({
      uint8_t __sc119;
      if ((*mu).n < 4U) {
        __sc119 = (*mu).n;
      } else {
        __sc119 = 4U;
      }
      __sc119;
    });
    bool concrete = true;
    for (uint8_t k = 0U; k < mtn; k++) {
      if (!ast__ast__Ast__type_concrete(&((*s)), (*mu).args[((size_t)k)])) {
        (concrete = false);
      }
    }
    if (!concrete) {
      (i = (i + 1U));
      continue;
    }
    const uint32_t recv_inst = ast__ast__Ast__type_at(&((*s)), rty)->as_data.inst;
    const ast__ast__TyInstance recv = (*ast__ast__Ast__instance(s, recv_inst));
    const uint16_t home = module__loader__Package__instance_home_mid(p, sm, (&recv));
    uint16_t dm = om;
    if (((size_t)home) < np) {
      (dm = home);
    }
    for (uint8_t kk = 0U; kk < mtn; kk++) {
      if (module__loader__type_mentions_fnval((&(*p)), sm, (*mu).args[((size_t)kk)])) {
        (dm = sm);
        break;
      }
    }
    const uint32_t rinst = ({
      uint32_t __sc120;
      if (dm == sm) {
        __sc120 = rty;
      } else {
        ast__ast__Ast *const d = module__loader__pkg_ast_m((&(*p)), dm);
        __sc120 = ast__ast__Ast__reintern(&((*d)), (&(*s)), rty);
      }
      __sc120;
    });
    uint32_t targs[4] = { 0U, 0U, 0U, 0U };
    for (uint8_t t = 0U; t < mtn; t++) {
      if (dm == sm) {
        (targs[__sc_bounds(((size_t)t), 4)] = (*mu).args[((size_t)t)]);
      } else {
        ast__ast__Ast *const d = module__loader__pkg_ast_m((&(*p)), dm);
        (targs[__sc_bounds(((size_t)t), 4)] = ast__ast__Ast__reintern(&((*d)), (&(*s)), (*mu).args[((size_t)t)]));
      }
    }
    ast__ast__Ast *const d = module__loader__pkg_ast_m((&(*p)), dm);
    if (ast__ast__Ast__add_method_inst(&((*d)), rinst, md.node, (&targs[0]), mtn)) {
      (changed = true);
    }
    (i = (i + 1U));
  }
  return changed;
}

void module__loader__package_propagate_instances(module__loader__Package *const p) {
  const size_t n = Vector__module__loader__Module__Global__len(&p->modules);
  module__loader__Package__build_mod_refs(p);
  Vector__usize__Global proc_inst = Vector__usize__Global__new();
  for (size_t u = 0ULL; u < n; u++) {
    Vector__usize__Global__push(&proc_inst, 0ULL);
  }
  bool changed = true;
  while (changed) {
    (changed = false);
    for (size_t u = 0ULL; u < n; u++) {
      if ((*({ __auto_type __sc121 = &p->modules; Vector__module__loader__Module__Global__index(__sc121, u); })).has_ast) {
        const size_t start = (*({ __auto_type __sc122 = &proc_inst; Vector__usize__Global__index(__sc122, u); }));
        const size_t ni = Vector__ast__ast__TyInstance__Global__len(&(*module__loader__pkg_ast_c((&(*p)), ((uint16_t)u))).instances);
        if (start < ni) {
          if (module__loader__reintern_cross_module((&(*p)), ((uint16_t)u), start)) {
            (changed = true);
          }
          (*Vector__usize__Global__index_mut(&proc_inst, u) = ni);
        }
        if (module__loader__reintern_method_insts((&(*p)), ((uint16_t)u))) {
          (changed = true);
        }
      }
    }
  }
  Vector__usize__Global__free(&proc_inst);
}

void module__loader__package_emit_order(const module__loader__Package *const p, uint16_t *const order) {
  const size_t n = Vector__module__loader__Module__Global__len(&p->modules);
  if (n == 0ULL) {
    return;
  }
  bool *const done = ((bool *)calloc(n, 1ULL));
  bool *const dep = ((bool *)calloc((n * n), 1ULL));
  uint32_t *const indeg = ((uint32_t *)calloc(n, 4ULL));
  if (((done == NULL) || (dep == NULL)) || (indeg == NULL)) {
    for (size_t i = 0ULL; i < n; i++) {
      (order[i] = ((uint16_t)i));
    }
    free(((void *)done));
    free(((void *)dep));
    free(((void *)indeg));
    return;
  }
  for (size_t a = 0ULL; a < n; a++) {
    if (!(*({ __auto_type __sc123 = &p->modules; Vector__module__loader__Module__Global__index(__sc123, a); })).has_ast) {
      continue;
    }
    const ast__ast__Ast *const aa = module__loader__pkg_ast_c((&(*p)), ((uint16_t)a));
    size_t i = 0ULL;
    while (i < Vector__ast__ast__TyInstance__Global__len(&(*aa).instances)) {
      const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*aa)), ((uint32_t)i)));
      const size_t bi = ((size_t)it.module);
      if (((bi >= n) || (bi == a)) || dep[((a * n) + bi)]) {
        (i = (i + 1ULL));
        continue;
      }
      bool concrete = true;
      for (uint8_t k = 0U; k < it.n; k++) {
        if (!ast__ast__Ast__type_concrete(&((*aa)), it.args[((size_t)k)])) {
          (concrete = false);
        }
      }
      if (concrete && (module__loader__Package__instance_home_mid(p, ((uint16_t)a), (&it)) == ((uint16_t)a))) {
        (dep[((a * n) + bi)] = true);
        {
          (indeg[a] = (indeg[a] + 1U));
        }
      }
      (i = (i + 1ULL));
    }
    (i = 0ULL);
    while (i < Vector__ast__ast__MethodInst__Global__len(&(*aa).method_insts)) {
      const uint32_t miinst = (*({ __auto_type __sc124 = &(*aa).method_insts; Vector__ast__ast__MethodInst__Global__index(__sc124, i); })).instance;
      const ast__ast__Ty y = (*ast__ast__Ast__type_at(&((*aa)), miinst));
      if (y.kind != ast__ast__TypeKind_TYPE_INSTANCE) {
        (i = (i + 1ULL));
        continue;
      }
      const size_t bi = ((size_t)ast__ast__Ast__instance(&((*aa)), y.as_data.inst)->module);
      if (((bi >= n) || (bi == a)) || dep[((a * n) + bi)]) {
        (i = (i + 1ULL));
        continue;
      }
      (dep[((a * n) + bi)] = true);
      {
        (indeg[a] = (indeg[a] + 1U));
      }
      (i = (i + 1ULL));
    }
    (i = 0ULL);
    while (i < Vector__ast__ast__MonoUse__Global__len(&(*aa).mono)) {
      const uint32_t mnode = (*({ __auto_type __sc125 = &(*aa).mono; Vector__ast__ast__MonoUse__Global__index(__sc125, i); })).node;
      if (ast__ast__Ast__at_const(&((*aa)), mnode)->kind != ast__ast__NodeKind_NODE_CALL) {
        (i = (i + 1ULL));
        continue;
      }
      const uint32_t callee_id = ast__ast__Ast__at_const(&((*aa)), mnode)->as_data.call.callee;
      const ast__ast__NodeKind ck = ast__ast__Ast__at_const(&((*aa)), callee_id)->kind;
      const ast__ast__DefId fd = ({
        ast__ast__DefId __sc126;
        if (ck == ast__ast__NodeKind_NODE_GENERIC_SPECIALIZATION) {
          const uint32_t e = ast__ast__Ast__at_const(&((*aa)), callee_id)->as_data.specialization.expression;
          __sc126 = ast__ast__Ast__resolution_def(&((*aa)), e);
        } else {
          __sc126 = ast__ast__Ast__resolution_def(&((*aa)), callee_id);
        }
        __sc126;
      });
      const size_t bi = ((size_t)fd.module);
      if ((((fd.node == ast__ast__NODE_NONE) || (bi >= n)) || (bi == a)) || dep[((a * n) + bi)]) {
        (i = (i + 1ULL));
        continue;
      }
      if (!(*({ __auto_type __sc127 = &p->modules; Vector__module__loader__Module__Global__index(__sc127, bi); })).has_ast) {
        (i = (i + 1ULL));
        continue;
      }
      const ast__ast__Ast *const bast = module__loader__pkg_ast_c((&(*p)), fd.module);
      if (ast__ast__Ast__at_const(&((*bast)), fd.node)->kind != ast__ast__NodeKind_NODE_FUNCTION) {
        (i = (i + 1ULL));
        continue;
      }
      (dep[((a * n) + bi)] = true);
      {
        (indeg[a] = (indeg[a] + 1U));
      }
      (i = (i + 1ULL));
    }
  }
  for (size_t kk = 0ULL; kk < n; kk++) {
    size_t pick = n;
    size_t i = 0ULL;
    while (i < n) {
      if ((!done[i]) && (indeg[i] == 0U)) {
        (pick = i);
        break;
      }
      (i = (i + 1ULL));
    }
    if (pick == n) {
      (i = 0ULL);
      while (i < n) {
        if (!done[i]) {
          (pick = i);
          break;
        }
        (i = (i + 1ULL));
      }
    }
    (order[kk] = ((uint16_t)pick));
    (done[pick] = true);
    for (size_t x = 0ULL; x < n; x++) {
      if (((!done[x]) && dep[((x * n) + pick)]) && (indeg[x] > 0U)) {
        {
          (indeg[x] = (indeg[x] - 1U));
        }
      }
    }
  }
  free(((void *)done));
  free(((void *)dep));
  free(((void *)indeg));
}

module__loader__Package module__loader__package_load(const char *const root_file, const char *const std_dir, bool const bootstrap_tags) {
  module__loader__Package p = module__loader__Package__new();
  (p.ok = true);
  (p.root_dir = module__loader__dir_of(str__from_cstr(root_file)));
  if (std_dir != NULL) {
    (p.std_root = module__loader__dir_of(str__from_cstr(std_dir)));
  }
  String__Global rp = module__loader__stem_of(str__from_cstr(root_file));
  String__Global rf = String__Global__from_cstr(root_file);
  module__loader__Package__load_module(&p, String__Global__as_str(&rp), String__Global__as_str(&rf), bootstrap_tags);
  module__loader__load_prelude((&p), std_dir);
  module__loader__Package__seed_core(&p);
  {
    __auto_type __sc128 = p;
    String__Global__free(&rf);
    String__Global__free(&rp);
    return __sc128;
  }
}

module__loader__Package module__loader__package_from_source(const char *const src, size_t const len, const char *const std_dir) {
  module__loader__Package p = module__loader__Package__new();
  (p.ok = true);
  (p.root_dir = String__Global__from_str((str){ (const uint8_t *)".", sizeof(".") - 1 }));
  if (std_dir != NULL) {
    (p.std_root = module__loader__dir_of(str__from_cstr(std_dir)));
  }
  module__loader__load_prelude((&p), std_dir);
  String__Global source = String__Global__from_str(str__from_raw(((const uint8_t *)src), len));
  const module__loader__ParseResult parsed = module__loader__parse_source((&source), ((const char *)({ __auto_type __sc129 = (str){ (const uint8_t *)"<harness>", sizeof("<harness>") - 1 }; str__ptr(&__sc129); })), false);
  const bool ok = parsed.ok;
  const int32_t id = module__loader__Package__add_module(&p, String__Global__from_str((str){ (const uint8_t *)"main", sizeof("main") - 1 }), String__Global__from_str((str){ (const uint8_t *)"<harness>", sizeof("<harness>") - 1 }), source, parsed.ast, ok);
  if (ok) {
    ((*({ __auto_type __sc130 = &p.modules; Vector__module__loader__Module__Global__index_mut(__sc130, ((size_t)id)); })).ast.module = ((uint16_t)id));
  } else {
    (p.ok = false);
  }
  module__loader__Package__seed_core(&p);
  return p;
}

static __attribute__((unused)) str module__loader__basename_of(str const path) {
  const size_t n = str__len(&path);
  size_t b = 0ULL;
  size_t i = 0ULL;
  while (i < n) {
    if (str__byte_at(&path, i) == 47U) {
      (b = (i + 1ULL));
    }
    (i = (i + 1ULL));
  }
  return str__slice(&path, b, n);
}

static __attribute__((unused)) int32_t module__loader__name_cmp(const String__Global *const a, const String__Global *const b) {
  const size_t la = String__Global__len(a);
  const size_t lb = String__Global__len(b);
  const size_t m = ({
    size_t __sc131;
    if (la < lb) {
      __sc131 = la;
    } else {
      __sc131 = lb;
    }
    __sc131;
  });
  const int32_t c = memcmp(((const void *)({ __auto_type __sc132 = String__Global__as_str(a); str__ptr(&__sc132); })), ((const void *)({ __auto_type __sc133 = String__Global__as_str(b); str__ptr(&__sc133); })), m);
  if (c != 0) {
    return c;
  }
  return ({ int32_t __sc_r; if (__builtin_sub_overflow(((int32_t)la), ((int32_t)lb), &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; });
}

static __attribute__((unused)) void module__loader__load_prelude(module__loader__Package *const p, const char *const std_dir) {
  if (std_dir == NULL) {
    return;
  }
  void *const dir = sc_opendir(std_dir);
  if (dir == NULL) {
    return;
  }
  Vector__String__Global__Global names = Vector__String__Global__Global__new();
  for (;;) {
    void *const e = sc_readdir(dir);
    if (e == NULL) {
      break;
    }
    const char *const nm = sc_dirent_name(e);
    const size_t l = strlen(nm);
    if (l < 5ULL) {
      continue;
    }
    if (strcmp(((const char *)(nm + (l - 4ULL))), ((const char *)({ __auto_type __sc134 = (str){ (const uint8_t *)".spc", sizeof(".spc") - 1 }; str__ptr(&__sc134); }))) != 0) {
      continue;
    }
    const int32_t dt = sc_dirent_isdir(e);
    if (dt == 1) {
      continue;
    }
    if (dt < 0) {
      String__Global probe = module__loader__join2(str__from_cstr(std_dir), str__from_cstr(nm));
      if (sc_stat_isdir(String__Global__cstr(&probe)) == 1) {
        {
          String__Global__free(&probe);
          continue;
        }
      }
      String__Global__free(&probe);
    }
    Vector__String__Global__Global__push(&names, String__Global__from_cstr(nm));
  }
  (void)(sc_closedir(dir));
  Vector__String__Global__Global__sort_by__module__loader__closure_10270(&names, module__loader__closure_10270);
  const size_t m0 = Vector__module__loader__Module__Global__len(&p->modules);
  for (size_t k = 0ULL; k < Vector__String__Global__Global__len(&names); k++) {
    String__Global file = module__loader__join2(str__from_cstr(std_dir), String__Global__as_str(&(*({ __auto_type __sc135 = &names; Vector__String__Global__Global__index(__sc135, k); }))));
    bool dup = false;
    for (size_t i2 = 0ULL; i2 < m0; i2++) {
      if ((({ __auto_type __sc136 = module__loader__basename_of(String__Global__as_str(&(*({ __auto_type __sc138 = &p->modules; Vector__module__loader__Module__Global__index(__sc138, i2); })).file)); __auto_type __sc137 = String__Global__as_str(&(*({ __auto_type __sc139 = &names; Vector__String__Global__Global__index(__sc139, k); }))); str__eq(&__sc136, &__sc137); })) && (sc_same_file(String__Global__cstr(&file), String__Global__cstr(&(*({ __auto_type __sc140 = &p->modules; Vector__module__loader__Module__Global__index_mut(__sc140, i2); })).file)) == 1)) {
        ((*({ __auto_type __sc141 = &p->modules; Vector__module__loader__Module__Global__index_mut(__sc141, i2); })).prelude = true);
        (dup = true);
        break;
      }
    }
    if (!dup) {
      String__Global stem = module__loader__stem_of(String__Global__as_str(&(*({ __auto_type __sc142 = &names; Vector__String__Global__Global__index(__sc142, k); }))));
      String__Global modpath = String__Global__from_str((str){ (const uint8_t *)"__std::", sizeof("__std::") - 1 });
      String__Global__push_str(&modpath, String__Global__as_str(&stem));
      const int32_t id = module__loader__Package__load_module(p, String__Global__as_str(&modpath), String__Global__as_str(&file), false);
      if (id >= 0) {
        ((*({ __auto_type __sc143 = &p->modules; Vector__module__loader__Module__Global__index_mut(__sc143, ((size_t)id)); })).prelude = true);
      }
      String__Global__free(&modpath);
      String__Global__free(&stem);
    }
    String__Global__free(&file);
  }
  Vector__String__Global__Global__free(&names);
}

