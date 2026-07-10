#include "../resolver/resolver.h"
#include "../stdlib.h"
#include "../string.h"
#include "../lexer/token.h"
#include "../ast/ast.h"
#include "../module/loader.h"
#include "../utils/errors.h"
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

_Static_assert(sizeof(resolver__resolver__FileScratch) == 4096 && _Alignof(resolver__resolver__FileScratch) == 1, "super-c layout model mismatch: resolver__resolver__FileScratch");
_Static_assert(sizeof(resolver__resolver__Symbol) == 16 && _Alignof(resolver__resolver__Symbol) == 4, "super-c layout model mismatch: resolver__resolver__Symbol");
_Static_assert(sizeof(resolver__resolver__ClosureScope) == 32 && _Alignof(resolver__resolver__ClosureScope) == 8, "super-c layout model mismatch: resolver__resolver__ClosureScope");
_Static_assert(sizeof(resolver__resolver__Resolver) == 760 && _Alignof(resolver__resolver__Resolver) == 8, "super-c layout model mismatch: resolver__resolver__Resolver");
_Static_assert(sizeof(resolver__resolver__SymLookup) == 8 && _Alignof(resolver__resolver__SymLookup) == 4, "super-c layout model mismatch: resolver__resolver__SymLookup");
_Static_assert(sizeof(resolver__resolver__ModQual) == 8 && _Alignof(resolver__resolver__ModQual) == 4, "super-c layout model mismatch: resolver__resolver__ModQual");
_Static_assert(sizeof(resolver__resolver__ModName) == 4 && _Alignof(resolver__resolver__ModName) == 2, "super-c layout model mismatch: resolver__resolver__ModName");

static __attribute__((unused)) uint32_t resolver__resolver__name_hash(const uint8_t *const src, lexer__token__Span const s);
static __attribute__((unused)) bool resolver__resolver__span_eq(const uint8_t *const src, lexer__token__Span const a, lexer__token__Span const b);
static __attribute__((unused)) bool resolver__resolver__span_is(const uint8_t *const src, lexer__token__Span const s, str const lit);
static __attribute__((unused)) int32_t resolver__resolver__builtin_index(const uint8_t *const src, lexer__token__Span const s);
static __attribute__((unused)) bool resolver__resolver__is_builtin_type(const uint8_t *const src, lexer__token__Span const s);
static __attribute__((unused)) uint64_t resolver__resolver__symbol_key(uint32_t const hash, uint8_t const ns);
static __attribute__((unused)) uint32_t resolver__resolver__Resolver__child(const resolver__resolver__Resolver *const self, ast__ast__NodeList const list, uint32_t const i);
static __attribute__((unused)) lexer__token__Span resolver__resolver__Resolver__name_span(const resolver__resolver__Resolver *const self, uint32_t const name_node);
static __attribute__((unused)) void resolver__resolver__Resolver__scope_enter(resolver__resolver__Resolver *const self);
static __attribute__((unused)) void resolver__resolver__Resolver__scope_exit(resolver__resolver__Resolver *const self);
static __attribute__((unused)) void resolver__resolver__Resolver__declare(resolver__resolver__Resolver *const self, uint32_t const name_node, uint32_t const decl, resolver__resolver__Namespace const ns);
static __attribute__((unused)) resolver__resolver__SymLookup resolver__resolver__Resolver__sym_lookup(const resolver__resolver__Resolver *const self, lexer__token__Span const name, resolver__resolver__Namespace const ns);
static __attribute__((unused)) char *resolver__resolver__Resolver__join_segs(const resolver__resolver__Resolver *const self, const uint32_t *const seg_ids, uint32_t const count);
static __attribute__((unused)) int32_t resolver__resolver__Resolver__import_target(const resolver__resolver__Resolver *const self, ast__ast__NodeList const parts);
static __attribute__((unused)) resolver__resolver__ModName resolver__resolver__Resolver__name_is_module(const resolver__resolver__Resolver *const self, lexer__token__Span const name);
static __attribute__((unused)) resolver__resolver__ModQual resolver__resolver__Resolver__module_qualified_type(const resolver__resolver__Resolver *const self, ast__ast__NodeList const parts);
static __attribute__((unused)) module__loader__LookupHit resolver__resolver__Resolver__glob_lookup(const resolver__resolver__Resolver *const self, lexer__token__Span const name, bool const want_type);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_module_decl(resolver__resolver__Resolver *const self, uint32_t const refn, uint16_t const mid, lexer__token__Span const name, bool const want_type, str const kind);
static __attribute__((unused)) bool resolver__resolver__Resolver__resolve_qualified_member(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_ref(resolver__resolver__Resolver *const self, uint32_t const refn, uint32_t const name_node, resolver__resolver__Namespace const ns, str const kind);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_bounds(resolver__resolver__Resolver *const self, ast__ast__NodeList const bounds);
static __attribute__((unused)) void resolver__resolver__Resolver__declare_generics(resolver__resolver__Resolver *const self, ast__ast__NodeList const generics);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_where(resolver__resolver__Resolver *const self, ast__ast__NodeList const where_clause);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_type(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_type_name(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_function(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_type_alias(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_members(resolver__resolver__Resolver *const self, ast__ast__NodeList const members);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_associated_items(resolver__resolver__Resolver *const self, ast__ast__NodeList const items);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_item(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_if(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_block(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_stmt(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_expr(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_member(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_sizeof(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_closure(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__resolve_pattern(resolver__resolver__Resolver *const self, uint32_t const id);
static __attribute__((unused)) void resolver__resolver__Resolver__collect_items(resolver__resolver__Resolver *const self, ast__ast__NodeList const items);
static __attribute__((unused)) str resolver__resolver__Resolver__package_file(const resolver__resolver__Resolver *const self);

Vector__resolver__resolver__Symbol__Global Vector__resolver__resolver__Symbol__Global__new_in(Global const alloc) {
  return (Vector__resolver__resolver__Symbol__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__resolver__resolver__Symbol__Global Vector__resolver__resolver__Symbol__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__resolver__resolver__Symbol__Global v = (Vector__resolver__resolver__Symbol__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((resolver__resolver__Symbol *)Global__alloc(&v.alloc, (cap * sizeof(resolver__resolver__Symbol)), _Alignof(resolver__resolver__Symbol))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__resolver__resolver__Symbol__Global__len(const Vector__resolver__resolver__Symbol__Global *const self) {
  return self->len;
}

void Vector__resolver__resolver__Symbol__Global__reserve(Vector__resolver__resolver__Symbol__Global *const self, size_t const additional) {
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
  resolver__resolver__Symbol *const p = ((resolver__resolver__Symbol *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(resolver__resolver__Symbol)), (new_cap * sizeof(resolver__resolver__Symbol)), _Alignof(resolver__resolver__Symbol)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__resolver__resolver__Symbol__Global__push(Vector__resolver__resolver__Symbol__Global *const self, resolver__resolver__Symbol const value) {
  Vector__resolver__resolver__Symbol__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const resolver__resolver__Symbol *Vector__resolver__resolver__Symbol__Global__at(const Vector__resolver__resolver__Symbol__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_resolver__resolver__Symbol Vector__resolver__resolver__Symbol__Global__get(const Vector__resolver__resolver__Symbol__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_resolver__resolver__Symbol){ .tag = Option_None };
  }
  return (Option__ptr_resolver__resolver__Symbol){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__resolver__resolver__Symbol__Global__set(Vector__resolver__resolver__Symbol__Global *const self, size_t const index, resolver__resolver__Symbol const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__resolver__resolver__Symbol__Global__clear(Vector__resolver__resolver__Symbol__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__resolver__resolver__Symbol__Global__truncate(Vector__resolver__resolver__Symbol__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const resolver__resolver__Symbol *Vector__resolver__resolver__Symbol__Global__as_ptr(const Vector__resolver__resolver__Symbol__Global *const self) {
  return self->ptr;
}

void Vector__resolver__resolver__Symbol__Global__swap(Vector__resolver__resolver__Symbol__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__resolver__resolver__Symbol__Global Vector__resolver__resolver__Symbol__Global__new(void) {
  return Vector__resolver__resolver__Symbol__Global__new_in(Global__default_());
}

void Vector__resolver__resolver__Symbol__Global__free(Vector__resolver__resolver__Symbol__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(resolver__resolver__Symbol)), _Alignof(resolver__resolver__Symbol));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__resolver__resolver__Symbol__Global Vector__resolver__resolver__Symbol__Global__default_(void) {
  return Vector__resolver__resolver__Symbol__Global__new();
}

const resolver__resolver__Symbol *Vector__resolver__resolver__Symbol__Global__index(const Vector__resolver__resolver__Symbol__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__resolver__resolver__Symbol Vector__resolver__resolver__Symbol__Global__index_range(const Vector__resolver__resolver__Symbol__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc0;
    if (r.inclusive) {
      __sc0 = (r.end + 1ULL);
    } else {
      __sc0 = r.end;
    }
    __sc0;
  });
  return (Slice__resolver__resolver__Symbol){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

resolver__resolver__Symbol *Vector__resolver__resolver__Symbol__Global__index_mut(Vector__resolver__resolver__Symbol__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__resolver__resolver__Symbol Vector__resolver__resolver__Symbol__Global__index_range_mut(Vector__resolver__resolver__Symbol__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc1;
    if (r.inclusive) {
      __sc1 = (r.end + 1ULL);
    } else {
      __sc1 = r.end;
    }
    __sc1;
  });
  return (SliceMut__resolver__resolver__Symbol){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__resolver__resolver__ClosureScope__Global Vector__resolver__resolver__ClosureScope__Global__new_in(Global const alloc) {
  return (Vector__resolver__resolver__ClosureScope__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__resolver__resolver__ClosureScope__Global Vector__resolver__resolver__ClosureScope__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__resolver__resolver__ClosureScope__Global v = (Vector__resolver__resolver__ClosureScope__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((resolver__resolver__ClosureScope *)Global__alloc(&v.alloc, (cap * sizeof(resolver__resolver__ClosureScope)), _Alignof(resolver__resolver__ClosureScope))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__resolver__resolver__ClosureScope__Global__len(const Vector__resolver__resolver__ClosureScope__Global *const self) {
  return self->len;
}

void Vector__resolver__resolver__ClosureScope__Global__reserve(Vector__resolver__resolver__ClosureScope__Global *const self, size_t const additional) {
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
  resolver__resolver__ClosureScope *const p = ((resolver__resolver__ClosureScope *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(resolver__resolver__ClosureScope)), (new_cap * sizeof(resolver__resolver__ClosureScope)), _Alignof(resolver__resolver__ClosureScope)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__resolver__resolver__ClosureScope__Global__push(Vector__resolver__resolver__ClosureScope__Global *const self, resolver__resolver__ClosureScope value) {
  Vector__resolver__resolver__ClosureScope__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const resolver__resolver__ClosureScope *Vector__resolver__resolver__ClosureScope__Global__at(const Vector__resolver__resolver__ClosureScope__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_resolver__resolver__ClosureScope Vector__resolver__resolver__ClosureScope__Global__get(const Vector__resolver__resolver__ClosureScope__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_resolver__resolver__ClosureScope){ .tag = Option_None };
  }
  return (Option__ptr_resolver__resolver__ClosureScope){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__resolver__resolver__ClosureScope__Global__set(Vector__resolver__resolver__ClosureScope__Global *const self, size_t const index, resolver__resolver__ClosureScope value) {
  resolver__resolver__ClosureScope__free(&self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__resolver__resolver__ClosureScope__Global__clear(Vector__resolver__resolver__ClosureScope__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    resolver__resolver__ClosureScope__free(&self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__resolver__resolver__ClosureScope__Global__truncate(Vector__resolver__resolver__ClosureScope__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      resolver__resolver__ClosureScope__free(&self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const resolver__resolver__ClosureScope *Vector__resolver__resolver__ClosureScope__Global__as_ptr(const Vector__resolver__resolver__ClosureScope__Global *const self) {
  return self->ptr;
}

void Vector__resolver__resolver__ClosureScope__Global__swap(Vector__resolver__resolver__ClosureScope__Global *const self, size_t const i, size_t const j) {
  __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__resolver__resolver__ClosureScope__Global Vector__resolver__resolver__ClosureScope__Global__new(void) {
  return Vector__resolver__resolver__ClosureScope__Global__new_in(Global__default_());
}

void Vector__resolver__resolver__ClosureScope__Global__free(Vector__resolver__resolver__ClosureScope__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    resolver__resolver__ClosureScope__free(&self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(resolver__resolver__ClosureScope)), _Alignof(resolver__resolver__ClosureScope));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__resolver__resolver__ClosureScope__Global Vector__resolver__resolver__ClosureScope__Global__default_(void) {
  return Vector__resolver__resolver__ClosureScope__Global__new();
}

const resolver__resolver__ClosureScope *Vector__resolver__resolver__ClosureScope__Global__index(const Vector__resolver__resolver__ClosureScope__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__resolver__resolver__ClosureScope Vector__resolver__resolver__ClosureScope__Global__index_range(const Vector__resolver__resolver__ClosureScope__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc2;
    if (r.inclusive) {
      __sc2 = (r.end + 1ULL);
    } else {
      __sc2 = r.end;
    }
    __sc2;
  });
  return (Slice__resolver__resolver__ClosureScope){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

resolver__resolver__ClosureScope *Vector__resolver__resolver__ClosureScope__Global__index_mut(Vector__resolver__resolver__ClosureScope__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__resolver__resolver__ClosureScope Vector__resolver__resolver__ClosureScope__Global__index_range_mut(Vector__resolver__resolver__ClosureScope__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc3;
    if (r.inclusive) {
      __sc3 = (r.end + 1ULL);
    } else {
      __sc3 = r.end;
    }
    __sc3;
  });
  return (SliceMut__resolver__resolver__ClosureScope){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__resolver__resolver__Symbol Option__resolver__resolver__Symbol__some(resolver__resolver__Symbol const value) {
  return (Option__resolver__resolver__Symbol){ .tag = Option_Some, .payload.Some = { value } };
}

Option__resolver__resolver__Symbol Option__resolver__resolver__Symbol__none(void) {
  return (Option__resolver__resolver__Symbol){ .tag = Option_None };
}

bool Option__resolver__resolver__Symbol__is_some(const Option__resolver__resolver__Symbol *const self) {
  {
    const Option__resolver__resolver__Symbol *const __sc4 = self;
    if ((*__sc4).tag == Option_Some) {
      return true;
    }
    else if ((*__sc4).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__resolver__resolver__Symbol__is_none(const Option__resolver__resolver__Symbol *const self) {
  {
    const Option__resolver__resolver__Symbol *const __sc5 = self;
    if ((*__sc5).tag == Option_Some) {
      return false;
    }
    else if ((*__sc5).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__resolver__resolver__Symbol Option__resolver__resolver__Symbol__default_(void) {
  return Option__resolver__resolver__Symbol__none();
}

Option__ptr_resolver__resolver__Symbol Option__ptr_resolver__resolver__Symbol__some(const resolver__resolver__Symbol *const value) {
  return (Option__ptr_resolver__resolver__Symbol){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_resolver__resolver__Symbol Option__ptr_resolver__resolver__Symbol__none(void) {
  return (Option__ptr_resolver__resolver__Symbol){ .tag = Option_None };
}

bool Option__ptr_resolver__resolver__Symbol__is_some(const Option__ptr_resolver__resolver__Symbol *const self) {
  {
    const Option__ptr_resolver__resolver__Symbol *const __sc6 = self;
    if ((*__sc6).tag == Option_Some) {
      return true;
    }
    else if ((*__sc6).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_resolver__resolver__Symbol__is_none(const Option__ptr_resolver__resolver__Symbol *const self) {
  {
    const Option__ptr_resolver__resolver__Symbol *const __sc7 = self;
    if ((*__sc7).tag == Option_Some) {
      return false;
    }
    else if ((*__sc7).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_resolver__resolver__Symbol Option__ptr_resolver__resolver__Symbol__default_(void) {
  return Option__ptr_resolver__resolver__Symbol__none();
}

Option__ptr_resolver__resolver__Symbol VecIter__resolver__resolver__Symbol__next(VecIter__resolver__resolver__Symbol *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_resolver__resolver__Symbol__none();
  }
  const resolver__resolver__Symbol *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_resolver__resolver__Symbol__some(r);
}

size_t Slice__resolver__resolver__Symbol__len(const Slice__resolver__resolver__Symbol *const self) {
  return self->len;
}

const resolver__resolver__Symbol *Slice__resolver__resolver__Symbol__as_ptr(const Slice__resolver__resolver__Symbol *const self) {
  return self->ptr;
}

const resolver__resolver__Symbol *Slice__resolver__resolver__Symbol__index(const Slice__resolver__resolver__Symbol *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__resolver__resolver__Symbol Slice__resolver__resolver__Symbol__index_range(const Slice__resolver__resolver__Symbol *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc8;
    if (r.inclusive) {
      __sc8 = (r.end + 1ULL);
    } else {
      __sc8 = r.end;
    }
    __sc8;
  });
  return (Slice__resolver__resolver__Symbol){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__resolver__resolver__Symbol__len(const SliceMut__resolver__resolver__Symbol *const self) {
  return self->len;
}

resolver__resolver__Symbol *SliceMut__resolver__resolver__Symbol__as_mut_ptr(const SliceMut__resolver__resolver__Symbol *const self) {
  return self->ptr;
}

const resolver__resolver__Symbol *SliceMut__resolver__resolver__Symbol__index(const SliceMut__resolver__resolver__Symbol *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__resolver__resolver__Symbol SliceMut__resolver__resolver__Symbol__index_range(const SliceMut__resolver__resolver__Symbol *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc9;
    if (r.inclusive) {
      __sc9 = (r.end + 1ULL);
    } else {
      __sc9 = r.end;
    }
    __sc9;
  });
  return (Slice__resolver__resolver__Symbol){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

resolver__resolver__Symbol *SliceMut__resolver__resolver__Symbol__index_mut(SliceMut__resolver__resolver__Symbol *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__resolver__resolver__Symbol SliceMut__resolver__resolver__Symbol__index_range_mut(SliceMut__resolver__resolver__Symbol *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc10;
    if (r.inclusive) {
      __sc10 = (r.end + 1ULL);
    } else {
      __sc10 = r.end;
    }
    __sc10;
  });
  return (SliceMut__resolver__resolver__Symbol){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__resolver__resolver__ClosureScope Option__resolver__resolver__ClosureScope__some(resolver__resolver__ClosureScope value) {
  return (Option__resolver__resolver__ClosureScope){ .tag = Option_Some, .payload.Some = { value } };
}

Option__resolver__resolver__ClosureScope Option__resolver__resolver__ClosureScope__none(void) {
  return (Option__resolver__resolver__ClosureScope){ .tag = Option_None };
}

bool Option__resolver__resolver__ClosureScope__is_some(const Option__resolver__resolver__ClosureScope *const self) {
  {
    const Option__resolver__resolver__ClosureScope *const __sc11 = self;
    if ((*__sc11).tag == Option_Some) {
      return true;
    }
    else if ((*__sc11).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__resolver__resolver__ClosureScope__is_none(const Option__resolver__resolver__ClosureScope *const self) {
  {
    const Option__resolver__resolver__ClosureScope *const __sc12 = self;
    if ((*__sc12).tag == Option_Some) {
      return false;
    }
    else if ((*__sc12).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__resolver__resolver__ClosureScope Option__resolver__resolver__ClosureScope__default_(void) {
  return Option__resolver__resolver__ClosureScope__none();
}

void Option__resolver__resolver__ClosureScope__free(Option__resolver__resolver__ClosureScope *const self) {
  {
    Option__resolver__resolver__ClosureScope *const __sc13 = self;
    if ((*__sc13).tag == Option_Some) {
      const __auto_type v = &((*__sc13).payload.Some._0);
      resolver__resolver__ClosureScope__free(v);
    }
    else if ((*__sc13).tag == Option_None) {
      {
      }
    }
  }
}

Option__ptr_resolver__resolver__ClosureScope Option__ptr_resolver__resolver__ClosureScope__some(const resolver__resolver__ClosureScope *const value) {
  return (Option__ptr_resolver__resolver__ClosureScope){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_resolver__resolver__ClosureScope Option__ptr_resolver__resolver__ClosureScope__none(void) {
  return (Option__ptr_resolver__resolver__ClosureScope){ .tag = Option_None };
}

bool Option__ptr_resolver__resolver__ClosureScope__is_some(const Option__ptr_resolver__resolver__ClosureScope *const self) {
  {
    const Option__ptr_resolver__resolver__ClosureScope *const __sc14 = self;
    if ((*__sc14).tag == Option_Some) {
      return true;
    }
    else if ((*__sc14).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_resolver__resolver__ClosureScope__is_none(const Option__ptr_resolver__resolver__ClosureScope *const self) {
  {
    const Option__ptr_resolver__resolver__ClosureScope *const __sc15 = self;
    if ((*__sc15).tag == Option_Some) {
      return false;
    }
    else if ((*__sc15).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_resolver__resolver__ClosureScope Option__ptr_resolver__resolver__ClosureScope__default_(void) {
  return Option__ptr_resolver__resolver__ClosureScope__none();
}

Option__ptr_resolver__resolver__ClosureScope VecIter__resolver__resolver__ClosureScope__next(VecIter__resolver__resolver__ClosureScope *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_resolver__resolver__ClosureScope__none();
  }
  const resolver__resolver__ClosureScope *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_resolver__resolver__ClosureScope__some(r);
}

size_t Slice__resolver__resolver__ClosureScope__len(const Slice__resolver__resolver__ClosureScope *const self) {
  return self->len;
}

const resolver__resolver__ClosureScope *Slice__resolver__resolver__ClosureScope__as_ptr(const Slice__resolver__resolver__ClosureScope *const self) {
  return self->ptr;
}

const resolver__resolver__ClosureScope *Slice__resolver__resolver__ClosureScope__index(const Slice__resolver__resolver__ClosureScope *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__resolver__resolver__ClosureScope Slice__resolver__resolver__ClosureScope__index_range(const Slice__resolver__resolver__ClosureScope *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc16;
    if (r.inclusive) {
      __sc16 = (r.end + 1ULL);
    } else {
      __sc16 = r.end;
    }
    __sc16;
  });
  return (Slice__resolver__resolver__ClosureScope){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__resolver__resolver__ClosureScope__len(const SliceMut__resolver__resolver__ClosureScope *const self) {
  return self->len;
}

resolver__resolver__ClosureScope *SliceMut__resolver__resolver__ClosureScope__as_mut_ptr(const SliceMut__resolver__resolver__ClosureScope *const self) {
  return self->ptr;
}

const resolver__resolver__ClosureScope *SliceMut__resolver__resolver__ClosureScope__index(const SliceMut__resolver__resolver__ClosureScope *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__resolver__resolver__ClosureScope SliceMut__resolver__resolver__ClosureScope__index_range(const SliceMut__resolver__resolver__ClosureScope *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc17;
    if (r.inclusive) {
      __sc17 = (r.end + 1ULL);
    } else {
      __sc17 = r.end;
    }
    __sc17;
  });
  return (Slice__resolver__resolver__ClosureScope){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

resolver__resolver__ClosureScope *SliceMut__resolver__resolver__ClosureScope__index_mut(SliceMut__resolver__resolver__ClosureScope *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__resolver__resolver__ClosureScope SliceMut__resolver__resolver__ClosureScope__index_range_mut(SliceMut__resolver__resolver__ClosureScope *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc18;
    if (r.inclusive) {
      __sc18 = (r.end + 1ULL);
    } else {
      __sc18 = r.end;
    }
    __sc18;
  });
  return (SliceMut__resolver__resolver__ClosureScope){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

void resolver__resolver__ClosureScope__free(resolver__resolver__ClosureScope *const self) {
  Vector__u32__Global__free(&self->caps);
}

static __attribute__((unused)) uint32_t resolver__resolver__name_hash(const uint8_t *const src, lexer__token__Span const s) {
  uint32_t h = 2166136261U;
  uint32_t i = s.start;
  while (i < s.end) {
    (h = (h ^ ((uint32_t)src[((size_t)i)])));
    (h = (h * 16777619U));
    (i = (i + 1U));
  }
  return h;
}

static __attribute__((unused)) bool resolver__resolver__span_eq(const uint8_t *const src, lexer__token__Span const a, lexer__token__Span const b) {
  const uint32_t la = (a.end - a.start);
  if (la != (b.end - b.start)) {
    return false;
  }
  return (memcmp((src + ((size_t)a.start)), (src + ((size_t)b.start)), ((size_t)la)) == 0);
}

static __attribute__((unused)) bool resolver__resolver__span_is(const uint8_t *const src, lexer__token__Span const s, str const lit) {
  const size_t n = str__len(&lit);
  if (((size_t)(s.end - s.start)) != n) {
    return false;
  }
  return (memcmp((src + ((size_t)s.start)), str__ptr(&lit), n) == 0);
}

static __attribute__((unused)) int32_t resolver__resolver__builtin_index(const uint8_t *const src, lexer__token__Span const s) {
  str const names[18] = { (str){ (const uint8_t *)"bool", sizeof("bool") - 1 }, (str){ (const uint8_t *)"char", sizeof("char") - 1 }, (str){ (const uint8_t *)"i8", sizeof("i8") - 1 }, (str){ (const uint8_t *)"i16", sizeof("i16") - 1 }, (str){ (const uint8_t *)"i32", sizeof("i32") - 1 }, (str){ (const uint8_t *)"i64", sizeof("i64") - 1 }, (str){ (const uint8_t *)"isize", sizeof("isize") - 1 }, (str){ (const uint8_t *)"u8", sizeof("u8") - 1 }, (str){ (const uint8_t *)"u16", sizeof("u16") - 1 }, (str){ (const uint8_t *)"u32", sizeof("u32") - 1 }, (str){ (const uint8_t *)"u64", sizeof("u64") - 1 }, (str){ (const uint8_t *)"usize", sizeof("usize") - 1 }, (str){ (const uint8_t *)"f32", sizeof("f32") - 1 }, (str){ (const uint8_t *)"f64", sizeof("f64") - 1 }, (str){ (const uint8_t *)"c32", sizeof("c32") - 1 }, (str){ (const uint8_t *)"c64", sizeof("c64") - 1 }, (str){ (const uint8_t *)"va_list", sizeof("va_list") - 1 }, (str){ (const uint8_t *)"void", sizeof("void") - 1 } };
  for (int32_t i = 0; i < 18; i++) {
    if (resolver__resolver__span_is(src, s, names[__sc_bounds(i, 18)])) {
      return ((int32_t)i);
    }
  }
  return -1;
}

static __attribute__((unused)) bool resolver__resolver__is_builtin_type(const uint8_t *const src, lexer__token__Span const s) {
  return (resolver__resolver__builtin_index(src, s) >= 0);
}

static __attribute__((unused)) uint64_t resolver__resolver__symbol_key(uint32_t const hash, uint8_t const ns) {
  return (({ uint64_t __sc19 = ((uint64_t)ns); int64_t __sc20 = (int64_t)(32ULL); if ((uint64_t)__sc20 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc19 << __sc20)); }) | ((uint64_t)hash));
}

resolver__resolver__Resolver resolver__resolver__Resolver__new(ast__ast__Ast ast, str const source, const module__loader__Package *const package) {
  return (resolver__resolver__Resolver){ .ast = ast, .source = str__ptr(&source), .len = str__len(&source), .symbols = Vector__resolver__resolver__Symbol__Global__new(), .symbol_previous = Vector__u32__Global__new(), .scope_starts = Vector__u32__Global__new(), .symbol_index = Map__u64__u32__Global__new(), .current_self = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE }, .in_generic = false, .closures = Vector__resolver__resolver__ClosureScope__Global__new(), .package = package, .errors = utils__errors__Errors__new() };
}

ast__ast__Ast resolver__resolver__Resolver__take_ast(resolver__resolver__Resolver *const self) {
  ast__ast__Ast out = self->ast;
  (self->ast = ast__ast__Ast__new(0ULL));
  return out;
}

static __attribute__((unused)) uint32_t resolver__resolver__Resolver__child(const resolver__resolver__Resolver *const self, ast__ast__NodeList const list, uint32_t const i) {
  return ast__ast__Ast__list(&self->ast, list)[((size_t)i)];
}

static __attribute__((unused)) lexer__token__Span resolver__resolver__Resolver__name_span(const resolver__resolver__Resolver *const self, uint32_t const name_node) {
  return ast__ast__Ast__at_const(&self->ast, name_node)->as_data.name.text;
}

static __attribute__((unused)) void resolver__resolver__Resolver__scope_enter(resolver__resolver__Resolver *const self) {
  Vector__u32__Global__push(&self->scope_starts, ((uint32_t)Vector__resolver__resolver__Symbol__Global__len(&self->symbols)));
}

static __attribute__((unused)) void resolver__resolver__Resolver__scope_exit(resolver__resolver__Resolver *const self) {
  const size_t sn = Vector__u32__Global__len(&self->scope_starts);
  const uint32_t start = (*({ __auto_type __sc21 = &self->scope_starts; Vector__u32__Global__index(__sc21, (sn - 1ULL)); }));
  Vector__u32__Global__truncate(&self->scope_starts, (sn - 1ULL));
  while (((uint32_t)Vector__resolver__resolver__Symbol__Global__len(&self->symbols)) > start) {
    const size_t index = (Vector__resolver__resolver__Symbol__Global__len(&self->symbols) - 1ULL);
    const uint32_t hash = (*({ __auto_type __sc22 = &self->symbols; Vector__resolver__resolver__Symbol__Global__index(__sc22, index); })).hash;
    const uint8_t ns = ((uint8_t)({ uint32_t __sc23 = (*({ __auto_type __sc25 = &self->symbols; Vector__resolver__resolver__Symbol__Global__index(__sc25, index); })).decl; int64_t __sc24 = (int64_t)(31U); if ((uint64_t)__sc24 >= 32) { __sc_panic("shift out of range"); } (uint32_t)(__sc23 >> __sc24); }));
    const uint32_t previous = (*({ __auto_type __sc26 = &self->symbol_previous; Vector__u32__Global__index(__sc26, index); }));
    Vector__resolver__resolver__Symbol__Global__truncate(&self->symbols, index);
    const uint64_t key = resolver__resolver__symbol_key(hash, ns);
    if (previous != 0U) {
      Map__u64__u32__Global__insert(&self->symbol_index, key, previous);
    } else {
      Map__u64__u32__Global__remove(&self->symbol_index, (&key));
    }
  }
  Vector__u32__Global__truncate(&self->symbol_previous, ((size_t)start));
}

static __attribute__((unused)) void resolver__resolver__Resolver__declare(resolver__resolver__Resolver *const self, uint32_t const name_node, uint32_t const decl, resolver__resolver__Namespace const ns) {
  if (name_node == ast__ast__NODE_NONE) {
    return;
  }
  const lexer__token__Span name = resolver__resolver__Resolver__name_span(self, name_node);
  if ((ns == resolver__resolver__Namespace_NS_VALUE) && resolver__resolver__span_is(self->source, name, (str){ (const uint8_t *)"_", sizeof("_") - 1 })) {
    return;
  }
  const uint32_t hash = resolver__resolver__name_hash(self->source, name);
  const uint64_t key = resolver__resolver__symbol_key(hash, ((uint8_t)ns));
  uint32_t head = 0U;
  {
    const Option__ptr_u32 __sc27 = Map__u64__u32__Global__get(&self->symbol_index, (&key));
    if (__sc27.tag == Option_Some) {
      const uint32_t *const v = __sc27.payload.Some._0;
      {
        (head = (*v));
      }
    }
    else if (1) {
      {
      }
    }
  }
  const uint32_t scope_start = (*({ __auto_type __sc28 = &self->scope_starts; Vector__u32__Global__index(__sc28, (Vector__u32__Global__len(&self->scope_starts) - 1ULL)); }));
  uint32_t current = head;
  while (current != 0U) {
    const size_t i = ((size_t)(current - 1U));
    if (i < ((size_t)scope_start)) {
      break;
    }
    const lexer__token__Span sname = (*({ __auto_type __sc29 = &self->symbols; Vector__resolver__resolver__Symbol__Global__index(__sc29, i); })).name;
    if (resolver__resolver__span_eq(self->source, sname, name)) {
      utils__errors__Errors__emit(&self->errors, name.start, (name.end - name.start), ({ String__Global __sc30 = String__Global__new();
String__Global__push_str(&__sc30, (str){ .ptr = (const uint8_t*)"duplicate definition of '", .len = sizeof("duplicate definition of '") - 1 });
String__Global__push_str(&__sc30, utils__errors__span_str(self->source, name.start, name.end));
String__Global__push_str(&__sc30, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc30; }));
      return;
    }
    (current = (*({ __auto_type __sc31 = &self->symbol_previous; Vector__u32__Global__index(__sc31, i); })));
  }
  Vector__resolver__resolver__Symbol__Global__push(&self->symbols, (resolver__resolver__Symbol){ .hash = hash, .decl = (decl | ({ uint32_t __sc32 = ((uint32_t)ns); int64_t __sc33 = (int64_t)(31U); if ((uint64_t)__sc33 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc32 << __sc33)); })), .name = name });
  Vector__u32__Global__push(&self->symbol_previous, head);
  Map__u64__u32__Global__insert(&self->symbol_index, key, ((uint32_t)Vector__resolver__resolver__Symbol__Global__len(&self->symbols)));
}

static __attribute__((unused)) resolver__resolver__SymLookup resolver__resolver__Resolver__sym_lookup(const resolver__resolver__Resolver *const self, lexer__token__Span const name, resolver__resolver__Namespace const ns) {
  const uint32_t hash = resolver__resolver__name_hash(self->source, name);
  const uint64_t key = resolver__resolver__symbol_key(hash, ((uint8_t)ns));
  uint32_t current = 0U;
  {
    const Option__ptr_u32 __sc34 = Map__u64__u32__Global__get(&self->symbol_index, (&key));
    if (__sc34.tag == Option_Some) {
      const uint32_t *const v = __sc34.payload.Some._0;
      {
        (current = (*v));
      }
    }
    else if (1) {
      {
      }
    }
  }
  while (current != 0U) {
    const size_t i = ((size_t)(current - 1U));
    const lexer__token__Span sname = (*({ __auto_type __sc35 = &self->symbols; Vector__resolver__resolver__Symbol__Global__index(__sc35, i); })).name;
    const uint32_t sdecl = ((*({ __auto_type __sc36 = &self->symbols; Vector__resolver__resolver__Symbol__Global__index(__sc36, i); })).decl & 0x7FFFFFFFU);
    if (resolver__resolver__span_eq(self->source, sname, name)) {
      return (resolver__resolver__SymLookup){ .decl = sdecl, .idx = current };
    }
    (current = (*({ __auto_type __sc37 = &self->symbol_previous; Vector__u32__Global__index(__sc37, i); })));
  }
  return (resolver__resolver__SymLookup){ .decl = ast__ast__NODE_NONE, .idx = 0U };
}

static __attribute__((unused)) char *resolver__resolver__Resolver__join_segs(const resolver__resolver__Resolver *const self, const uint32_t *const seg_ids, uint32_t const count) {
  size_t total = 0ULL;
  uint32_t i = 0U;
  while (i < count) {
    const lexer__token__Span s = resolver__resolver__Resolver__name_span(self, seg_ids[((size_t)i)]);
    (total = (total + ((size_t)(s.end - s.start))));
    if (i != 0U) {
      (total = (total + 2ULL));
    }
    (i = (i + 1U));
  }
  char *const out = ((char *)malloc((total + 1ULL)));
  size_t at = 0ULL;
  (i = 0U);
  while (i < count) {
    if (i != 0U) {
      (out[at] = 58);
      (out[(at + 1ULL)] = 58);
      (at = (at + 2ULL));
    }
    const lexer__token__Span s = resolver__resolver__Resolver__name_span(self, seg_ids[((size_t)i)]);
    const size_t l = ((size_t)(s.end - s.start));
    memcpy(((void *)(out + at)), (self->source + ((size_t)s.start)), l);
    (at = (at + l));
    (i = (i + 1U));
  }
  (out[at] = 0);
  return out;
}

static __attribute__((unused)) int32_t resolver__resolver__Resolver__import_target(const resolver__resolver__Resolver *const self, ast__ast__NodeList const parts) {
  if (self->package == NULL) {
    return -1;
  }
  const module__loader__Package *const pkg = (&(*self->package));
  const uint32_t *const ids = ast__ast__Ast__list(&self->ast, parts);
  char *const buf = resolver__resolver__Resolver__join_segs(self, ids, parts.len);
  const int32_t m = module__loader__Package__find(pkg, str__from_raw(((const uint8_t *)buf), strlen(buf)));
  free(((void *)buf));
  return m;
}

static __attribute__((unused)) resolver__resolver__ModName resolver__resolver__Resolver__name_is_module(const resolver__resolver__Resolver *const self, lexer__token__Span const name) {
  if (self->package == NULL) {
    return (resolver__resolver__ModName){ .found = false, .mid = 0U };
  }
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&self->ast, self->ast.root)->as_data.program.items;
  const uint32_t *const ids = ast__ast__Ast__list(&self->ast, items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const ast__ast__Node *const n = ast__ast__Ast__at_const(&self->ast, ids[((size_t)i)]);
    if (n->kind == ast__ast__NodeKind_NODE_IMPORT) {
      const uint32_t alias = n->as_data.import_decl.alias;
      const ast__ast__NodeList parts = n->as_data.import_decl.path;
      bool hit = false;
      if (alias != ast__ast__NODE_NONE) {
        (hit = resolver__resolver__span_eq(self->source, resolver__resolver__Resolver__name_span(self, alias), name));
      } else if (parts.len == 1U) {
        (hit = resolver__resolver__span_eq(self->source, resolver__resolver__Resolver__name_span(self, ast__ast__Ast__list(&self->ast, parts)[0]), name));
      }
      if (hit) {
        const int32_t m = resolver__resolver__Resolver__import_target(self, parts);
        if (m >= 0) {
          return (resolver__resolver__ModName){ .found = true, .mid = ((uint16_t)m) };
        }
      }
    }
  }
  return (resolver__resolver__ModName){ .found = false, .mid = 0U };
}

static __attribute__((unused)) resolver__resolver__ModQual resolver__resolver__Resolver__module_qualified_type(const resolver__resolver__Resolver *const self, ast__ast__NodeList const parts) {
  if ((self->package == NULL) || (parts.len < 2U)) {
    return (resolver__resolver__ModQual){ .mid = -1, .type_node = ast__ast__NODE_NONE };
  }
  const module__loader__Package *const pkg = (&(*self->package));
  const uint32_t *const ids = ast__ast__Ast__list(&self->ast, parts);
  char *const buf = resolver__resolver__Resolver__join_segs(self, ids, (parts.len - 1U));
  const int32_t m = module__loader__Package__find(pkg, str__from_raw(((const uint8_t *)buf), strlen(buf)));
  free(((void *)buf));
  if (m >= 0) {
    return (resolver__resolver__ModQual){ .mid = m, .type_node = ids[((size_t)(parts.len - 1U))] };
  }
  if (parts.len == 2U) {
    const resolver__resolver__ModName nm = resolver__resolver__Resolver__name_is_module(self, resolver__resolver__Resolver__name_span(self, ids[0]));
    if (nm.found) {
      return (resolver__resolver__ModQual){ .mid = ((int32_t)nm.mid), .type_node = ids[1] };
    }
  }
  return (resolver__resolver__ModQual){ .mid = -1, .type_node = ast__ast__NODE_NONE };
}

static __attribute__((unused)) module__loader__LookupHit resolver__resolver__Resolver__glob_lookup(const resolver__resolver__Resolver *const self, lexer__token__Span const name, bool const want_type) {
  const module__loader__LookupHit miss = (module__loader__LookupHit){ .node = ast__ast__NODE_NONE, .mid = 0U };
  if (self->package == NULL) {
    return miss;
  }
  const module__loader__Package *const pkg = (&(*self->package));
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&self->ast, self->ast.root)->as_data.program.items;
  const uint32_t *const ids = ast__ast__Ast__list(&self->ast, items);
  const char *const nm = ((const char *)(self->source + ((size_t)name.start)));
  const size_t nl = ((size_t)(name.end - name.start));
  for (uint32_t i = 0U; i < items.len; i++) {
    const ast__ast__Node *const n = ast__ast__Ast__at_const(&self->ast, ids[((size_t)i)]);
    if ((n->kind == ast__ast__NodeKind_NODE_IMPORT) && n->as_data.import_decl.glob) {
      const int32_t m = resolver__resolver__Resolver__import_target(self, n->as_data.import_decl.path);
      if (m >= 0) {
        const module__loader__LookupHit hit = module__loader__Package__glob_lookup(pkg, ((uint16_t)m), str__from_raw(((const uint8_t *)nm), nl), want_type);
        if (hit.node != ast__ast__NODE_NONE) {
          return hit;
        }
      }
    }
  }
  return miss;
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_module_decl(resolver__resolver__Resolver *const self, uint32_t const refn, uint16_t const mid, lexer__token__Span const name, bool const want_type, str const kind) {
  const module__loader__Package *const pkg = (&(*self->package));
  const char *const nm = ((const char *)(self->source + ((size_t)name.start)));
  const size_t nl = ((size_t)(name.end - name.start));
  const uint32_t decl = module__loader__Package__lookup(pkg, mid, str__from_raw(((const uint8_t *)nm), nl), want_type);
  if (decl != ast__ast__NODE_NONE) {
    ast__ast__Ast__set_resolution_def(&self->ast, refn, (ast__ast__DefId){ .module = mid, .node = decl });
  } else {
    utils__errors__Errors__emit(&self->errors, name.start, (name.end - name.start), ({ String__Global __sc38 = String__Global__new();
String__Global__push_str(&__sc38, (str){ .ptr = (const uint8_t*)"no public ", .len = sizeof("no public ") - 1 });
String__Global__push_str(&__sc38, kind);
String__Global__push_str(&__sc38, (str){ .ptr = (const uint8_t*)" '", .len = sizeof(" '") - 1 });
String__Global__push_str(&__sc38, utils__errors__span_str(self->source, name.start, name.end));
String__Global__push_str(&__sc38, (str){ .ptr = (const uint8_t*)"' in the imported module", .len = sizeof("' in the imported module") - 1 });
__sc38; }));
    utils__errors__Errors__note(&self->errors, ({ String__Global __sc39 = String__Global__new();
String__Global__push_str(&__sc39, (str){ .ptr = (const uint8_t*)"only 'pub' top-level items are visible across module boundaries", .len = sizeof("only 'pub' top-level items are visible across module boundaries") - 1 });
__sc39; }));
  }
}

static __attribute__((unused)) bool resolver__resolver__Resolver__resolve_qualified_member(resolver__resolver__Resolver *const self, uint32_t const id) {
  if (self->package == NULL) {
    return false;
  }
  Vector__u32__Global chain = Vector__u32__Global__new();
  uint32_t base = ast__ast__NODE_NONE;
  uint32_t curid = id;
  bool bail = false;
  bool go = true;
  while (go) {
    const ast__ast__Node *const cn = ast__ast__Ast__at_const(&self->ast, curid);
    if (((cn->kind != ast__ast__NodeKind_NODE_MEMBER) || (!cn->as_data.member.path)) || (Vector__u32__Global__len(&chain) >= 32ULL)) {
      (bail = true);
      (go = false);
    } else {
      Vector__u32__Global__push(&chain, curid);
      const uint32_t o = cn->as_data.member.object;
      const ast__ast__Node *const on = ast__ast__Ast__at_const(&self->ast, o);
      if (on->kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
        (base = o);
        (go = false);
      } else if ((on->kind != ast__ast__NodeKind_NODE_MEMBER) || (!on->as_data.member.path)) {
        (bail = true);
        (go = false);
      } else {
        (curid = o);
      }
    }
  }
  if (bail) {
    {
      __auto_type __sc40 = false;
      Vector__u32__Global__free(&chain);
      return __sc40;
    }
  }
  const uint32_t cc = ((uint32_t)Vector__u32__Global__len(&chain));
  const uint32_t nn = (cc + 1U);
  Vector__u32__Global seg = Vector__u32__Global__new();
  Vector__u32__Global__push(&seg, base);
  uint32_t i = 1U;
  while (i < nn) {
    const uint32_t link = (*({ __auto_type __sc41 = &chain; Vector__u32__Global__index(__sc41, ((size_t)((nn - 1U) - i))); }));
    const uint32_t mem = ast__ast__Ast__at_const(&self->ast, link)->as_data.member.member;
    Vector__u32__Global__push(&seg, mem);
    (i = (i + 1U));
  }
  const module__loader__Package *const pkg = (&(*self->package));
  bool handled = false;
  bool done = false;
  uint32_t m = (nn - 1U);
  while ((m >= 1U) && (!done)) {
    char *const buf = resolver__resolver__Resolver__join_segs(self, Vector__u32__Global__as_ptr(&seg), m);
    const size_t len = strlen(buf);
    const int32_t found = module__loader__Package__find(pkg, str__from_raw(((const uint8_t *)buf), len));
    if (found >= 0) {
      const uint16_t mid = ((uint16_t)found);
      if ((nn - m) == 1U) {
        const lexer__token__Span dn = resolver__resolver__Resolver__name_span(self, (*({ __auto_type __sc42 = &seg; Vector__u32__Global__index(__sc42, ((size_t)m)); })));
        const char *const dnm = ((const char *)(self->source + ((size_t)dn.start)));
        const size_t dl = ((size_t)(dn.end - dn.start));
        uint32_t decl = module__loader__Package__lookup(pkg, mid, str__from_raw(((const uint8_t *)dnm), dl), false);
        if (decl == ast__ast__NODE_NONE) {
          (decl = module__loader__Package__lookup(pkg, mid, str__from_raw(((const uint8_t *)dnm), dl), true));
        }
        if (decl != ast__ast__NODE_NONE) {
          ast__ast__Ast__set_resolution_def(&self->ast, id, (ast__ast__DefId){ .module = mid, .node = decl });
        } else {
          utils__errors__Errors__emit(&self->errors, dn.start, (dn.end - dn.start), ({ String__Global __sc43 = String__Global__new();
String__Global__push_str(&__sc43, (str){ .ptr = (const uint8_t*)"no public item '", .len = sizeof("no public item '") - 1 });
String__Global__push_str(&__sc43, utils__errors__span_str(self->source, dn.start, dn.end));
String__Global__push_str(&__sc43, (str){ .ptr = (const uint8_t*)"' in module '", .len = sizeof("' in module '") - 1 });
String__Global__push_str(&__sc43, utils__errors__cstr(buf));
String__Global__push_str(&__sc43, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc43; }));
          utils__errors__Errors__note(&self->errors, ({ String__Global __sc44 = String__Global__new();
String__Global__push_str(&__sc44, (str){ .ptr = (const uint8_t*)"the module was found, but this item is missing or not public", .len = sizeof("the module was found, but this item is missing or not public") - 1 });
__sc44; }));
        }
        (handled = true);
      } else if ((nn - m) == 2U) {
        const uint32_t chain1 = (*({ __auto_type __sc45 = &chain; Vector__u32__Global__index(__sc45, 1ULL); }));
        const lexer__token__Span tspan = resolver__resolver__Resolver__name_span(self, (*({ __auto_type __sc46 = &seg; Vector__u32__Global__index(__sc46, ((size_t)m)); })));
        resolver__resolver__Resolver__resolve_module_decl(self, chain1, mid, tspan, true, (str){ (const uint8_t *)"type", sizeof("type") - 1 });
        (handled = true);
      }
      (done = true);
    }
    free(((void *)buf));
    if (!done) {
      (m = (m - 1U));
    }
  }
  {
    __auto_type __sc47 = handled;
    Vector__u32__Global__free(&seg);
    Vector__u32__Global__free(&chain);
    return __sc47;
  }
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_ref(resolver__resolver__Resolver *const self, uint32_t const refn, uint32_t const name_node, resolver__resolver__Namespace const ns, str const kind) {
  if (name_node == ast__ast__NODE_NONE) {
    return;
  }
  const lexer__token__Span name = resolver__resolver__Resolver__name_span(self, name_node);
  const resolver__resolver__SymLookup look = resolver__resolver__Resolver__sym_lookup(self, name, ns);
  const uint32_t decl = look.decl;
  const uint32_t idx = look.idx;
  if (decl != ast__ast__NODE_NONE) {
    if ((((ns == resolver__resolver__Namespace_NS_VALUE) && (Vector__resolver__resolver__ClosureScope__Global__len(&self->closures) != 0ULL)) && (idx != 0U)) && ((idx - 1U) < (*({ __auto_type __sc48 = &self->closures; Vector__resolver__resolver__ClosureScope__Global__index(__sc48, (Vector__resolver__resolver__ClosureScope__Global__len(&self->closures) - 1ULL)); })).floor)) {
      const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&self->ast, decl)->kind;
      if (((((dk == ast__ast__NodeKind_NODE_LET) || (dk == ast__ast__NodeKind_NODE_PARAMETER)) || (dk == ast__ast__NodeKind_NODE_FOR)) || (dk == ast__ast__NodeKind_NODE_IDENTIFIER)) || (dk == ast__ast__NodeKind_NODE_PATTERN_NAME)) {
        size_t f = Vector__resolver__resolver__ClosureScope__Global__len(&self->closures);
        while (f > 0ULL) {
          (f = (f - 1ULL));
          if ((idx - 1U) >= (*({ __auto_type __sc49 = &self->closures; Vector__resolver__resolver__ClosureScope__Global__index(__sc49, f); })).floor) {
            break;
          }
          bool seen = false;
          const size_t nc = Vector__u32__Global__len(&(*({ __auto_type __sc50 = &self->closures; Vector__resolver__resolver__ClosureScope__Global__index(__sc50, f); })).caps);
          for (size_t k = 0ULL; k < nc; k++) {
            if ((*({ __auto_type __sc51 = &(*({ __auto_type __sc52 = &self->closures; Vector__resolver__resolver__ClosureScope__Global__index(__sc52, f); })).caps; Vector__u32__Global__index(__sc51, k); })) == decl) {
              (seen = true);
              break;
            }
          }
          if (!seen) {
            Vector__u32__Global__push(&(*({ __auto_type __sc53 = &self->closures; Vector__resolver__resolver__ClosureScope__Global__index_mut(__sc53, f); })).caps, decl);
          }
        }
      }
    }
    ast__ast__Ast__set_resolution(&self->ast, refn, decl);
    return;
  }
  if ((ns == resolver__resolver__Namespace_NS_TYPE) && resolver__resolver__is_builtin_type(self->source, name)) {
    return;
  }
  if (self->package != NULL) {
    const module__loader__Package *const pkg = (&(*self->package));
    const char *const nm = ((const char *)(self->source + ((size_t)name.start)));
    const size_t nl = ((size_t)(name.end - name.start));
    const bool want_type = (ns == resolver__resolver__Namespace_NS_TYPE);
    module__loader__LookupHit hit = module__loader__Package__prelude_lookup(pkg, str__from_raw(((const uint8_t *)nm), nl), want_type);
    if (hit.node == ast__ast__NODE_NONE) {
      (hit = resolver__resolver__Resolver__glob_lookup(self, name, want_type));
    }
    if (hit.node != ast__ast__NODE_NONE) {
      ast__ast__Ast__set_resolution_def(&self->ast, refn, (ast__ast__DefId){ .module = hit.mid, .node = hit.node });
      return;
    }
  }
  utils__errors__Errors__emit(&self->errors, name.start, (name.end - name.start), ({ String__Global __sc54 = String__Global__new();
String__Global__push_str(&__sc54, (str){ .ptr = (const uint8_t*)"cannot find ", .len = sizeof("cannot find ") - 1 });
String__Global__push_str(&__sc54, kind);
String__Global__push_str(&__sc54, (str){ .ptr = (const uint8_t*)" '", .len = sizeof(" '") - 1 });
String__Global__push_str(&__sc54, utils__errors__span_str(self->source, name.start, name.end));
String__Global__push_str(&__sc54, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc54; }));
  utils__errors__Errors__note(&self->errors, ({ String__Global __sc55 = String__Global__new();
String__Global__push_str(&__sc55, (str){ .ptr = (const uint8_t*)"check spelling, imports, and whether the item is declared before this use", .len = sizeof("check spelling, imports, and whether the item is declared before this use") - 1 });
__sc55; }));
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_bounds(resolver__resolver__Resolver *const self, ast__ast__NodeList const bounds) {
  for (uint32_t i = 0U; i < bounds.len; i++) {
    const uint32_t cid = resolver__resolver__Resolver__child(self, bounds, i);
    resolver__resolver__Resolver__resolve_type(self, cid);
  }
}

static __attribute__((unused)) void resolver__resolver__Resolver__declare_generics(resolver__resolver__Resolver *const self, ast__ast__NodeList const generics) {
  uint32_t i = 0U;
  while (i < generics.len) {
    const uint32_t gid = resolver__resolver__Resolver__child(self, generics, i);
    const ast__ast__GenericParamData gp = ast__ast__Ast__at_const(&self->ast, gid)->as_data.generic_param;
    resolver__resolver__Resolver__declare(self, gp.name, gid, resolver__resolver__Namespace_NS_TYPE);
    if (gp.is_const) {
      resolver__resolver__Resolver__declare(self, gp.name, gid, resolver__resolver__Namespace_NS_VALUE);
    }
    (i = (i + 1U));
  }
  (i = 0U);
  while (i < generics.len) {
    const uint32_t gid = resolver__resolver__Resolver__child(self, generics, i);
    const ast__ast__GenericParamData gp = ast__ast__Ast__at_const(&self->ast, gid)->as_data.generic_param;
    resolver__resolver__Resolver__resolve_bounds(self, gp.bounds);
    if (gp.default_type != ast__ast__NODE_NONE) {
      resolver__resolver__Resolver__resolve_type(self, gp.default_type);
    }
    if (gp.const_type != ast__ast__NODE_NONE) {
      resolver__resolver__Resolver__resolve_type(self, gp.const_type);
    }
    (i = (i + 1U));
  }
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_where(resolver__resolver__Resolver *const self, ast__ast__NodeList const where_clause) {
  for (uint32_t i = 0U; i < where_clause.len; i++) {
    const uint32_t wid = resolver__resolver__Resolver__child(self, where_clause, i);
    const ast__ast__WherePredicateData w = ast__ast__Ast__at_const(&self->ast, wid)->as_data.where_predicate;
    resolver__resolver__Resolver__resolve_type(self, w.ty);
    resolver__resolver__Resolver__resolve_bounds(self, w.bounds);
  }
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_type(resolver__resolver__Resolver *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return;
  }
  const ast__ast__NodeKind kind = ast__ast__Ast__at_const(&self->ast, id)->kind;
  if (kind == ast__ast__NodeKind_NODE_TYPE_PATH) {
    const ast__ast__TypePathData tp = ast__ast__Ast__at_const(&self->ast, id)->as_data.type_path;
    const resolver__resolver__ModQual mq = resolver__resolver__Resolver__module_qualified_type(self, tp.parts);
    if (mq.mid >= 0) {
      const lexer__token__Span tspan = resolver__resolver__Resolver__name_span(self, mq.type_node);
      resolver__resolver__Resolver__resolve_module_decl(self, id, ((uint16_t)mq.mid), tspan, true, (str){ (const uint8_t *)"type", sizeof("type") - 1 });
      for (uint32_t i = 0U; i < tp.args.len; i++) {
        const uint32_t a = resolver__resolver__Resolver__child(self, tp.args, i);
        resolver__resolver__Resolver__resolve_type(self, a);
      }
      return;
    }
    if (tp.parts.len > 0U) {
      const uint32_t first = resolver__resolver__Resolver__child(self, tp.parts, 0U);
      const lexer__token__Span name = resolver__resolver__Resolver__name_span(self, first);
      if (resolver__resolver__span_is(self->source, name, (str){ (const uint8_t *)"Self", sizeof("Self") - 1 })) {
        if (self->current_self.node != ast__ast__NODE_NONE) {
          const ast__ast__DefId cs = self->current_self;
          ast__ast__Ast__set_resolution_def(&self->ast, id, cs);
        } else {
          utils__errors__Errors__emit(&self->errors, name.start, (name.end - name.start), ({ String__Global __sc56 = String__Global__new();
String__Global__push_str(&__sc56, (str){ .ptr = (const uint8_t*)"'Self' is only valid inside an interface or extension", .len = sizeof("'Self' is only valid inside an interface or extension") - 1 });
__sc56; }));
        }
      } else {
        resolver__resolver__Resolver__resolve_ref(self, id, first, resolver__resolver__Namespace_NS_TYPE, (str){ (const uint8_t *)"type", sizeof("type") - 1 });
      }
    }
    for (uint32_t i = 0U; i < tp.args.len; i++) {
      const uint32_t a = resolver__resolver__Resolver__child(self, tp.args, i);
      resolver__resolver__Resolver__resolve_type(self, a);
    }
    return;
  }
  if ((((kind == ast__ast__NodeKind_NODE_POINTER_TYPE) || (kind == ast__ast__NodeKind_NODE_REFERENCE_TYPE)) || (kind == ast__ast__NodeKind_NODE_SLICE_TYPE)) || (kind == ast__ast__NodeKind_NODE_DYN_TYPE)) {
    const uint32_t t = ast__ast__Ast__at_const(&self->ast, id)->as_data.indirect_type.ty;
    resolver__resolver__Resolver__resolve_type(self, t);
    return;
  }
  if (kind == ast__ast__NodeKind_NODE_TUPLE_TYPE) {
    const ast__ast__NodeList elems = ast__ast__Ast__at_const(&self->ast, id)->as_data.array_literal.elements;
    for (uint32_t i = 0U; i < elems.len; i++) {
      const uint32_t e = resolver__resolver__Resolver__child(self, elems, i);
      resolver__resolver__Resolver__resolve_type(self, e);
    }
    return;
  }
  if (kind == ast__ast__NodeKind_NODE_ARRAY_TYPE) {
    const ast__ast__ArrayTypeData at = ast__ast__Ast__at_const(&self->ast, id)->as_data.array_type;
    resolver__resolver__Resolver__resolve_type(self, at.element);
    resolver__resolver__Resolver__resolve_expr(self, at.length);
    return;
  }
  if (kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
    const ast__ast__FunctionTypeData ft = ast__ast__Ast__at_const(&self->ast, id)->as_data.function_type;
    uint32_t i = 0U;
    while (i < ft.params.len) {
      const uint32_t p = resolver__resolver__Resolver__child(self, ft.params, i);
      resolver__resolver__Resolver__resolve_type(self, p);
      (i = (i + 1U));
    }
    (i = 0U);
    while (i < ft.returns.len) {
      const uint32_t rr = resolver__resolver__Resolver__child(self, ft.returns, i);
      resolver__resolver__Resolver__resolve_type(self, rr);
      (i = (i + 1U));
    }
    return;
  }
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_type_name(resolver__resolver__Resolver *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return;
  }
  if (ast__ast__Ast__at_const(&self->ast, id)->kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
    resolver__resolver__Resolver__resolve_ref(self, id, id, resolver__resolver__Namespace_NS_TYPE, (str){ (const uint8_t *)"type", sizeof("type") - 1 });
  } else {
    resolver__resolver__Resolver__resolve_type(self, id);
  }
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_function(resolver__resolver__Resolver *const self, uint32_t const id) {
  const ast__ast__FunctionData fd = ast__ast__Ast__at_const(&self->ast, id)->as_data.function;
  const bool saved_generic = self->in_generic;
  (self->in_generic = (saved_generic || (fd.generics.len > 0U)));
  resolver__resolver__Resolver__scope_enter(self);
  resolver__resolver__Resolver__declare_generics(self, fd.generics);
  uint32_t i = 0U;
  while (i < fd.params.len) {
    const uint32_t pid = resolver__resolver__Resolver__child(self, fd.params, i);
    const ast__ast__ParameterData param = ast__ast__Ast__at_const(&self->ast, pid)->as_data.parameter;
    resolver__resolver__Resolver__declare(self, param.name, pid, resolver__resolver__Namespace_NS_VALUE);
    resolver__resolver__Resolver__resolve_type(self, param.ty);
    (i = (i + 1U));
  }
  (i = 0U);
  while (i < fd.returns.len) {
    const uint32_t rid = resolver__resolver__Resolver__child(self, fd.returns, i);
    const ast__ast__NodeKind rk = ast__ast__Ast__at_const(&self->ast, rid)->kind;
    if (rk == ast__ast__NodeKind_NODE_PARAMETER) {
      const uint32_t rt = ast__ast__Ast__at_const(&self->ast, rid)->as_data.parameter.ty;
      resolver__resolver__Resolver__resolve_type(self, rt);
    } else {
      resolver__resolver__Resolver__resolve_type(self, rid);
    }
    (i = (i + 1U));
  }
  resolver__resolver__Resolver__resolve_where(self, fd.where_clause);
  if (fd.body != ast__ast__NODE_NONE) {
    resolver__resolver__Resolver__resolve_block(self, fd.body);
  }
  resolver__resolver__Resolver__scope_exit(self);
  (self->in_generic = saved_generic);
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_type_alias(resolver__resolver__Resolver *const self, uint32_t const id) {
  const ast__ast__TypeAliasData ta = ast__ast__Ast__at_const(&self->ast, id)->as_data.type_alias;
  resolver__resolver__Resolver__scope_enter(self);
  resolver__resolver__Resolver__declare_generics(self, ta.generics);
  resolver__resolver__Resolver__resolve_type(self, ta.ty);
  resolver__resolver__Resolver__scope_exit(self);
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_members(resolver__resolver__Resolver *const self, ast__ast__NodeList const members) {
  for (uint32_t i = 0U; i < members.len; i++) {
    const uint32_t mid = resolver__resolver__Resolver__child(self, members, i);
    const ast__ast__NodeKind mk = ast__ast__Ast__at_const(&self->ast, mid)->kind;
    if (mk == ast__ast__NodeKind_NODE_FIELD) {
      const ast__ast__FieldData fld = ast__ast__Ast__at_const(&self->ast, mid)->as_data.field;
      resolver__resolver__Resolver__declare(self, fld.name, mid, resolver__resolver__Namespace_NS_VALUE);
      resolver__resolver__Resolver__resolve_type(self, fld.ty);
    } else {
      const ast__ast__VariantData vr = ast__ast__Ast__at_const(&self->ast, mid)->as_data.variant;
      resolver__resolver__Resolver__declare(self, vr.name, mid, resolver__resolver__Namespace_NS_VALUE);
      resolver__resolver__Resolver__resolve_expr(self, vr.value);
      for (uint32_t j = 0U; j < vr.payload.len; j++) {
        const uint32_t pid = resolver__resolver__Resolver__child(self, vr.payload, j);
        const ast__ast__NodeKind pk = ast__ast__Ast__at_const(&self->ast, pid)->kind;
        if (pk == ast__ast__NodeKind_NODE_FIELD) {
          const uint32_t pt = ast__ast__Ast__at_const(&self->ast, pid)->as_data.field.ty;
          resolver__resolver__Resolver__resolve_type(self, pt);
        } else {
          resolver__resolver__Resolver__resolve_type(self, pid);
        }
      }
    }
  }
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_associated_items(resolver__resolver__Resolver *const self, ast__ast__NodeList const items) {
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t iid = resolver__resolver__Resolver__child(self, items, i);
    {
      const ast__ast__NodeKind __sc57 = ast__ast__Ast__at_const(&self->ast, iid)->kind;
      if (__sc57 == ast__ast__NodeKind_NODE_FUNCTION) {
        {
          resolver__resolver__Resolver__resolve_function(self, iid);
        }
      }
      else if (__sc57 == ast__ast__NodeKind_NODE_TYPE_ALIAS) {
        {
          resolver__resolver__Resolver__resolve_type_alias(self, iid);
        }
      }
      else if (__sc57 == ast__ast__NodeKind_NODE_CONST) {
        {
          const ast__ast__ConstData cd = ast__ast__Ast__at_const(&self->ast, iid)->as_data.const_def;
          resolver__resolver__Resolver__resolve_type(self, cd.ty);
          resolver__resolver__Resolver__resolve_expr(self, cd.value);
        }
      }
      else if (1) {
        {
        }
      }
    }
  }
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_item(resolver__resolver__Resolver *const self, uint32_t const id) {
  const ast__ast__NodeKind kind = ast__ast__Ast__at_const(&self->ast, id)->kind;
  {
    const ast__ast__NodeKind __sc58 = kind;
    if (__sc58 == ast__ast__NodeKind_NODE_FUNCTION) {
      {
        resolver__resolver__Resolver__resolve_function(self, id);
      }
    }
    else if ((__sc58 == ast__ast__NodeKind_NODE_STRUCT) || (__sc58 == ast__ast__NodeKind_NODE_ENUM)) {
      {
        const ast__ast__AggregateData ag = ast__ast__Ast__at_const(&self->ast, id)->as_data.aggregate;
        resolver__resolver__Resolver__scope_enter(self);
        resolver__resolver__Resolver__declare_generics(self, ag.generics);
        if (ag.is_tuple) {
          for (uint32_t i = 0U; i < ag.members.len; i++) {
            const uint32_t mid = resolver__resolver__Resolver__child(self, ag.members, i);
            resolver__resolver__Resolver__resolve_type(self, mid);
          }
        } else {
          resolver__resolver__Resolver__resolve_members(self, ag.members);
        }
        resolver__resolver__Resolver__scope_exit(self);
      }
    }
    else if (__sc58 == ast__ast__NodeKind_NODE_INTERFACE) {
      {
        const ast__ast__InterfaceData it = ast__ast__Ast__at_const(&self->ast, id)->as_data.interface_def;
        resolver__resolver__Resolver__scope_enter(self);
        resolver__resolver__Resolver__declare_generics(self, it.generics);
        resolver__resolver__Resolver__resolve_bounds(self, it.bounds);
        const ast__ast__DefId old_self = self->current_self;
        (self->current_self = (ast__ast__DefId){ .module = self->ast.module, .node = id });
        resolver__resolver__Resolver__resolve_associated_items(self, it.items);
        (self->current_self = old_self);
        resolver__resolver__Resolver__scope_exit(self);
      }
    }
    else if (__sc58 == ast__ast__NodeKind_NODE_EXTEND) {
      {
        const ast__ast__ExtendData ex = ast__ast__Ast__at_const(&self->ast, id)->as_data.extend_def;
        resolver__resolver__Resolver__scope_enter(self);
        resolver__resolver__Resolver__declare_generics(self, ex.generics);
        resolver__resolver__Resolver__resolve_type(self, ex.target_type);
        resolver__resolver__Resolver__resolve_type(self, ex.interface_type);
        if (((ex.target_type != ast__ast__NODE_NONE) && (self->package != NULL)) && (ast__ast__Ast__resolution(&self->ast, ex.target_type) == ast__ast__NODE_NONE)) {
          const ast__ast__NodeKind tk = ast__ast__Ast__at_const(&self->ast, ex.target_type)->kind;
          if (tk == ast__ast__NodeKind_NODE_TYPE_PATH) {
            const ast__ast__NodeList tparts = ast__ast__Ast__at_const(&self->ast, ex.target_type)->as_data.type_path.parts;
            if (tparts.len == 1U) {
              const uint32_t seg0 = resolver__resolver__Resolver__child(self, tparts, 0U);
              const int32_t b = resolver__resolver__builtin_index(self->source, resolver__resolver__Resolver__name_span(self, seg0));
              const module__loader__Package *const pkg = (&(*self->package));
              uint32_t bd = ast__ast__NODE_NONE;
              if (b >= 0) {
                (bd = module__loader__Package__builtin_decl(pkg, ((ast__ast__BuiltinType)b)));
              }
              if (bd != ast__ast__NODE_NONE) {
                ast__ast__Ast__set_resolution_def(&self->ast, ex.target_type, (ast__ast__DefId){ .module = pkg->core_module, .node = bd });
              }
            }
          }
        }
        const ast__ast__DefId old_self = self->current_self;
        ast__ast__DefId resolved = (ast__ast__DefId){ .module = self->ast.module, .node = ast__ast__NODE_NONE };
        if (ex.target_type != ast__ast__NODE_NONE) {
          (resolved = ast__ast__Ast__resolution_def(&self->ast, ex.target_type));
        }
        if (resolved.node != ast__ast__NODE_NONE) {
          (self->current_self = resolved);
        } else {
          (self->current_self = (ast__ast__DefId){ .module = self->ast.module, .node = id });
        }
        const bool saved_generic = self->in_generic;
        (self->in_generic = (saved_generic || (ex.generics.len > 0U)));
        resolver__resolver__Resolver__resolve_associated_items(self, ex.items);
        (self->in_generic = saved_generic);
        (self->current_self = old_self);
        resolver__resolver__Resolver__scope_exit(self);
      }
    }
    else if (__sc58 == ast__ast__NodeKind_NODE_TYPE_ALIAS) {
      {
        resolver__resolver__Resolver__resolve_type_alias(self, id);
      }
    }
    else if (__sc58 == ast__ast__NodeKind_NODE_CONST) {
      {
        const ast__ast__ConstData cd = ast__ast__Ast__at_const(&self->ast, id)->as_data.const_def;
        resolver__resolver__Resolver__resolve_type(self, cd.ty);
        resolver__resolver__Resolver__resolve_expr(self, cd.value);
      }
    }
    else if (__sc58 == ast__ast__NodeKind_NODE_EXTERN_BLOCK) {
      {
        const ast__ast__NodeList inner = ast__ast__Ast__at_const(&self->ast, id)->as_data.extern_block.items;
        resolver__resolver__Resolver__resolve_associated_items(self, inner);
      }
    }
    else if (__sc58 == ast__ast__NodeKind_NODE_STATIC_ASSERT) {
      {
        const uint32_t left = ast__ast__Ast__at_const(&self->ast, id)->as_data.binary.left;
        resolver__resolver__Resolver__resolve_expr(self, left);
      }
    }
    else if (1) {
      {
      }
    }
  }
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_if(resolver__resolver__Resolver *const self, uint32_t const id) {
  const ast__ast__IfData ifd = ast__ast__Ast__at_const(&self->ast, id)->as_data.if_stmt;
  resolver__resolver__Resolver__resolve_expr(self, ifd.condition);
  resolver__resolver__Resolver__resolve_stmt(self, ifd.then_branch);
  resolver__resolver__Resolver__resolve_stmt(self, ifd.else_branch);
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_block(resolver__resolver__Resolver *const self, uint32_t const id) {
  const ast__ast__NodeList stmts = ast__ast__Ast__at_const(&self->ast, id)->as_data.block.statements;
  resolver__resolver__Resolver__scope_enter(self);
  for (uint32_t i = 0U; i < stmts.len; i++) {
    const uint32_t cid = resolver__resolver__Resolver__child(self, stmts, i);
    resolver__resolver__Resolver__resolve_stmt(self, cid);
  }
  resolver__resolver__Resolver__scope_exit(self);
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_stmt(resolver__resolver__Resolver *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return;
  }
  const ast__ast__NodeKind kind = ast__ast__Ast__at_const(&self->ast, id)->kind;
  {
    const ast__ast__NodeKind __sc59 = kind;
    if (__sc59 == ast__ast__NodeKind_NODE_BLOCK) {
      {
        resolver__resolver__Resolver__resolve_block(self, id);
      }
    }
    else if (__sc59 == ast__ast__NodeKind_NODE_LET) {
      {
        const ast__ast__LetData ld = ast__ast__Ast__at_const(&self->ast, id)->as_data.let_stmt;
        resolver__resolver__Resolver__resolve_type(self, ld.ty);
        resolver__resolver__Resolver__resolve_expr(self, ld.value);
        const ast__ast__NodeKind nmkind = ast__ast__Ast__at_const(&self->ast, ld.name)->kind;
        if (nmkind == ast__ast__NodeKind_NODE_PATTERN_TUPLE) {
          const ast__ast__NodeList children = ast__ast__Ast__at_const(&self->ast, ld.name)->as_data.pattern.children;
          for (uint32_t i = 0U; i < children.len; i++) {
            const uint32_t cid = resolver__resolver__Resolver__child(self, children, i);
            resolver__resolver__Resolver__declare(self, cid, cid, resolver__resolver__Namespace_NS_VALUE);
            ast__ast__Ast__set_resolution(&self->ast, cid, id);
          }
        } else {
          resolver__resolver__Resolver__declare(self, ld.name, id, resolver__resolver__Namespace_NS_VALUE);
        }
      }
    }
    else if (__sc59 == ast__ast__NodeKind_NODE_CONST) {
      {
        const ast__ast__ConstData cd = ast__ast__Ast__at_const(&self->ast, id)->as_data.const_def;
        resolver__resolver__Resolver__resolve_type(self, cd.ty);
        resolver__resolver__Resolver__resolve_expr(self, cd.value);
        resolver__resolver__Resolver__declare(self, cd.name, id, resolver__resolver__Namespace_NS_VALUE);
      }
    }
    else if (__sc59 == ast__ast__NodeKind_NODE_RETURN) {
      {
        const ast__ast__NodeList values = ast__ast__Ast__at_const(&self->ast, id)->as_data.return_stmt.values;
        for (uint32_t i = 0U; i < values.len; i++) {
          const uint32_t v = resolver__resolver__Resolver__child(self, values, i);
          resolver__resolver__Resolver__resolve_expr(self, v);
        }
      }
    }
    else if (__sc59 == ast__ast__NodeKind_NODE_DEFER) {
      {
        const uint32_t v = ast__ast__Ast__at_const(&self->ast, id)->as_data.single.value;
        resolver__resolver__Resolver__resolve_expr(self, v);
      }
    }
    else if (__sc59 == ast__ast__NodeKind_NODE_IF) {
      {
        resolver__resolver__Resolver__resolve_if(self, id);
      }
    }
    else if (__sc59 == ast__ast__NodeKind_NODE_WHILE) {
      {
        const ast__ast__WhileData wd = ast__ast__Ast__at_const(&self->ast, id)->as_data.while_stmt;
        resolver__resolver__Resolver__resolve_expr(self, wd.condition);
        resolver__resolver__Resolver__resolve_block(self, wd.body);
      }
    }
    else if (__sc59 == ast__ast__NodeKind_NODE_FOR) {
      {
        const ast__ast__ForData fr = ast__ast__Ast__at_const(&self->ast, id)->as_data.for_stmt;
        resolver__resolver__Resolver__resolve_expr(self, fr.iterable);
        resolver__resolver__Resolver__scope_enter(self);
        resolver__resolver__Resolver__declare(self, fr.binding, id, resolver__resolver__Namespace_NS_VALUE);
        resolver__resolver__Resolver__resolve_block(self, fr.body);
        resolver__resolver__Resolver__scope_exit(self);
      }
    }
    else if (__sc59 == ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT) {
      {
        const uint32_t v = ast__ast__Ast__at_const(&self->ast, id)->as_data.single.value;
        resolver__resolver__Resolver__resolve_expr(self, v);
      }
    }
    else if (__sc59 == ast__ast__NodeKind_NODE_STATIC_ASSERT) {
      {
        const uint32_t left = ast__ast__Ast__at_const(&self->ast, id)->as_data.binary.left;
        resolver__resolver__Resolver__resolve_expr(self, left);
      }
    }
    else if (__sc59 == ast__ast__NodeKind_NODE_BREAK) {
      {
        const uint32_t v = ast__ast__Ast__at_const(&self->ast, id)->as_data.flow.value;
        resolver__resolver__Resolver__resolve_expr(self, v);
      }
    }
    else if (1) {
      {
      }
    }
  }
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_expr(resolver__resolver__Resolver *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return;
  }
  const ast__ast__NodeKind kind = ast__ast__Ast__at_const(&self->ast, id)->kind;
  {
    const ast__ast__NodeKind __sc60 = kind;
    if (__sc60 == ast__ast__NodeKind_NODE_IDENTIFIER) {
      {
        resolver__resolver__Resolver__resolve_ref(self, id, id, resolver__resolver__Namespace_NS_VALUE, (str){ (const uint8_t *)"value", sizeof("value") - 1 });
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_UNARY) {
      {
        const uint32_t op = ast__ast__Ast__at_const(&self->ast, id)->as_data.unary.operand;
        resolver__resolver__Resolver__resolve_expr(self, op);
      }
    }
    else if ((__sc60 == ast__ast__NodeKind_NODE_BINARY) || (__sc60 == ast__ast__NodeKind_NODE_ASSIGNMENT)) {
      {
        const ast__ast__BinaryData bd = ast__ast__Ast__at_const(&self->ast, id)->as_data.binary;
        resolver__resolver__Resolver__resolve_expr(self, bd.left);
        resolver__resolver__Resolver__resolve_expr(self, bd.right);
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_CALL) {
      {
        const ast__ast__CallData cd = ast__ast__Ast__at_const(&self->ast, id)->as_data.call;
        const ast__ast__NodeKind callee_kind = ast__ast__Ast__at_const(&self->ast, cd.callee)->kind;
        bool as_type = false;
        if (callee_kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
          const lexer__token__Span cname = resolver__resolver__Resolver__name_span(self, cd.callee);
          if ((resolver__resolver__Resolver__sym_lookup(self, cname, resolver__resolver__Namespace_NS_VALUE).decl == ast__ast__NODE_NONE) && (resolver__resolver__Resolver__sym_lookup(self, cname, resolver__resolver__Namespace_NS_TYPE).decl != ast__ast__NODE_NONE)) {
            (as_type = true);
          }
        }
        if (as_type) {
          resolver__resolver__Resolver__resolve_ref(self, cd.callee, cd.callee, resolver__resolver__Namespace_NS_TYPE, (str){ (const uint8_t *)"type", sizeof("type") - 1 });
        } else {
          resolver__resolver__Resolver__resolve_expr(self, cd.callee);
        }
        for (uint32_t i = 0U; i < cd.args.len; i++) {
          const uint32_t a = resolver__resolver__Resolver__child(self, cd.args, i);
          resolver__resolver__Resolver__resolve_expr(self, a);
        }
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_INDEX) {
      {
        const ast__ast__IndexData ix = ast__ast__Ast__at_const(&self->ast, id)->as_data.index;
        resolver__resolver__Resolver__resolve_expr(self, ix.object);
        resolver__resolver__Resolver__resolve_expr(self, ix.index);
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_MEMBER) {
      {
        resolver__resolver__Resolver__resolve_member(self, id);
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_CAST) {
      {
        const ast__ast__CastData ct = ast__ast__Ast__at_const(&self->ast, id)->as_data.cast;
        resolver__resolver__Resolver__resolve_expr(self, ct.expression);
        resolver__resolver__Resolver__resolve_type(self, ct.ty);
      }
    }
    else if ((__sc60 == ast__ast__NodeKind_NODE_SIZEOF) || (__sc60 == ast__ast__NodeKind_NODE_ALIGNOF)) {
      {
        resolver__resolver__Resolver__resolve_sizeof(self, id);
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_VA_EXPR) {
      {
        const ast__ast__VaOpData vo = ast__ast__Ast__at_const(&self->ast, id)->as_data.va_op;
        resolver__resolver__Resolver__resolve_expr(self, vo.ap);
        if (vo.op == ast__ast__VA_ARG) {
          resolver__resolver__Resolver__resolve_type(self, vo.extra);
        } else if (vo.op == ast__ast__VA_START) {
          resolver__resolver__Resolver__resolve_expr(self, vo.extra);
        }
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_GENERIC_SPECIALIZATION) {
      {
        const ast__ast__SpecializationData sp = ast__ast__Ast__at_const(&self->ast, id)->as_data.specialization;
        const ast__ast__NodeKind inner_kind = ast__ast__Ast__at_const(&self->ast, sp.expression)->kind;
        bool as_type = false;
        if (inner_kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
          const lexer__token__Span iname = resolver__resolver__Resolver__name_span(self, sp.expression);
          if (resolver__resolver__Resolver__sym_lookup(self, iname, resolver__resolver__Namespace_NS_VALUE).decl == ast__ast__NODE_NONE) {
            (as_type = true);
          }
        }
        if (as_type) {
          resolver__resolver__Resolver__resolve_ref(self, sp.expression, sp.expression, resolver__resolver__Namespace_NS_TYPE, (str){ (const uint8_t *)"type", sizeof("type") - 1 });
        } else {
          resolver__resolver__Resolver__resolve_expr(self, sp.expression);
        }
        for (uint32_t i = 0U; i < sp.types.len; i++) {
          const uint32_t t = resolver__resolver__Resolver__child(self, sp.types, i);
          resolver__resolver__Resolver__resolve_type(self, t);
        }
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_MATCH) {
      {
        const ast__ast__MatchData md = ast__ast__Ast__at_const(&self->ast, id)->as_data.match_expr;
        resolver__resolver__Resolver__resolve_expr(self, md.value);
        for (uint32_t i = 0U; i < md.arms.len; i++) {
          const uint32_t aid = resolver__resolver__Resolver__child(self, md.arms, i);
          const ast__ast__MatchArmData arm = ast__ast__Ast__at_const(&self->ast, aid)->as_data.match_arm;
          resolver__resolver__Resolver__scope_enter(self);
          resolver__resolver__Resolver__resolve_pattern(self, arm.pattern);
          resolver__resolver__Resolver__resolve_expr(self, arm.guard);
          resolver__resolver__Resolver__resolve_expr(self, arm.body);
          resolver__resolver__Resolver__scope_exit(self);
        }
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_NEW) {
      {
        const ast__ast__NewData ne = ast__ast__Ast__at_const(&self->ast, id)->as_data.new_expr;
        if (ne.initializer != ast__ast__NODE_NONE) {
          resolver__resolver__Resolver__resolve_expr(self, ne.initializer);
        } else {
          resolver__resolver__Resolver__resolve_type(self, ne.ty);
        }
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_WHILE) {
      {
        const uint32_t body = ast__ast__Ast__at_const(&self->ast, id)->as_data.while_stmt.body;
        resolver__resolver__Resolver__resolve_block(self, body);
      }
    }
    else if ((__sc60 == ast__ast__NodeKind_NODE_ARRAY_LITERAL) || (__sc60 == ast__ast__NodeKind_NODE_TUPLE)) {
      {
        const ast__ast__NodeList elements = ast__ast__Ast__at_const(&self->ast, id)->as_data.array_literal.elements;
        for (uint32_t i = 0U; i < elements.len; i++) {
          const uint32_t eid = resolver__resolver__Resolver__child(self, elements, i);
          const ast__ast__NodeKind ek = ast__ast__Ast__at_const(&self->ast, eid)->kind;
          if (ek == ast__ast__NodeKind_NODE_FIELD_INITIALIZER) {
            const ast__ast__FieldInitializerData fi = ast__ast__Ast__at_const(&self->ast, eid)->as_data.field_initializer;
            resolver__resolver__Resolver__resolve_expr(self, fi.name);
            resolver__resolver__Resolver__resolve_expr(self, fi.value);
          } else {
            resolver__resolver__Resolver__resolve_expr(self, eid);
          }
        }
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_STRUCT_INITIALIZER) {
      {
        const ast__ast__StructInitializerData si = ast__ast__Ast__at_const(&self->ast, id)->as_data.struct_initializer;
        resolver__resolver__Resolver__resolve_type_name(self, si.ty);
        for (uint32_t i = 0U; i < si.fields.len; i++) {
          const uint32_t fid = resolver__resolver__Resolver__child(self, si.fields, i);
          const uint32_t val = ast__ast__Ast__at_const(&self->ast, fid)->as_data.field_initializer.value;
          resolver__resolver__Resolver__resolve_expr(self, val);
        }
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_BLOCK) {
      {
        resolver__resolver__Resolver__resolve_block(self, id);
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_CLOSURE) {
      {
        resolver__resolver__Resolver__resolve_closure(self, id);
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_IF) {
      {
        resolver__resolver__Resolver__resolve_if(self, id);
      }
    }
    else if (__sc60 == ast__ast__NodeKind_NODE_RANGE) {
      {
        const ast__ast__PatternRangeData pr = ast__ast__Ast__at_const(&self->ast, id)->as_data.pattern_range;
        resolver__resolver__Resolver__resolve_expr(self, pr.start);
        resolver__resolver__Resolver__resolve_expr(self, pr.end);
      }
    }
    else if (1) {
      {
      }
    }
  }
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_member(resolver__resolver__Resolver *const self, uint32_t const id) {
  const ast__ast__MemberData mb = ast__ast__Ast__at_const(&self->ast, id)->as_data.member;
  if (mb.path && resolver__resolver__Resolver__resolve_qualified_member(self, id)) {
    return;
  }
  const ast__ast__NodeKind obj_kind = ast__ast__Ast__at_const(&self->ast, mb.object)->kind;
  if (mb.path && (obj_kind == ast__ast__NodeKind_NODE_IDENTIFIER)) {
    const resolver__resolver__ModName nm = resolver__resolver__Resolver__name_is_module(self, resolver__resolver__Resolver__name_span(self, mb.object));
    if (nm.found) {
      const lexer__token__Span mn = resolver__resolver__Resolver__name_span(self, mb.member);
      const module__loader__Package *const pkg = (&(*self->package));
      const char *const nmp = ((const char *)(self->source + ((size_t)mn.start)));
      const size_t nl = ((size_t)(mn.end - mn.start));
      const uint32_t decl = module__loader__Package__lookup(pkg, nm.mid, str__from_raw(((const uint8_t *)nmp), nl), false);
      if (decl != ast__ast__NODE_NONE) {
        ast__ast__Ast__set_resolution_def(&self->ast, id, (ast__ast__DefId){ .module = nm.mid, .node = decl });
      } else {
        resolver__resolver__Resolver__resolve_module_decl(self, id, nm.mid, mn, true, (str){ (const uint8_t *)"item", sizeof("item") - 1 });
      }
    } else {
      resolver__resolver__Resolver__resolve_ref(self, mb.object, mb.object, resolver__resolver__Namespace_NS_TYPE, (str){ (const uint8_t *)"type", sizeof("type") - 1 });
    }
  } else {
    resolver__resolver__Resolver__resolve_expr(self, mb.object);
  }
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_sizeof(resolver__resolver__Resolver *const self, uint32_t const id) {
  const uint32_t v = ast__ast__Ast__at_const(&self->ast, id)->as_data.single.value;
  const ast__ast__NodeKind vk = ast__ast__Ast__at_const(&self->ast, v)->kind;
  if (vk == ast__ast__NodeKind_NODE_TYPE_PATH) {
    const ast__ast__TypePathData tp = ast__ast__Ast__at_const(&self->ast, v)->as_data.type_path;
    if ((tp.parts.len == 1U) && (tp.args.len == 0U)) {
      const uint32_t first = resolver__resolver__Resolver__child(self, tp.parts, 0U);
      const lexer__token__Span name = resolver__resolver__Resolver__name_span(self, first);
      bool is_type = ((resolver__resolver__is_builtin_type(self->source, name) || resolver__resolver__span_is(self->source, name, (str){ (const uint8_t *)"Self", sizeof("Self") - 1 })) || (resolver__resolver__Resolver__sym_lookup(self, name, resolver__resolver__Namespace_NS_TYPE).decl != ast__ast__NODE_NONE));
      if ((!is_type) && (self->package != NULL)) {
        const module__loader__Package *const pkg = (&(*self->package));
        const char *const nm = ((const char *)(self->source + ((size_t)name.start)));
        const size_t nl = ((size_t)(name.end - name.start));
        (is_type = ((module__loader__Package__prelude_lookup(pkg, str__from_raw(((const uint8_t *)nm), nl), true).node != ast__ast__NODE_NONE) || (resolver__resolver__Resolver__glob_lookup(self, name, true).node != ast__ast__NODE_NONE)));
      }
      if (!is_type) {
        resolver__resolver__Resolver__resolve_ref(self, v, first, resolver__resolver__Namespace_NS_VALUE, (str){ (const uint8_t *)"type or value", sizeof("type or value") - 1 });
        return;
      }
    }
  }
  resolver__resolver__Resolver__resolve_type(self, v);
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_closure(resolver__resolver__Resolver *const self, uint32_t const id) {
  if (self->in_generic) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&self->ast, id)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc61 = String__Global__new();
String__Global__push_str(&__sc61, (str){ .ptr = (const uint8_t*)"closures inside generic functions are not yet supported", .len = sizeof("closures inside generic functions are not yet supported") - 1 });
__sc61; }));
  }
  if (Vector__resolver__resolver__ClosureScope__Global__len(&self->closures) >= 8ULL) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&self->ast, id)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc62 = String__Global__new();
String__Global__push_str(&__sc62, (str){ .ptr = (const uint8_t*)"closures nested too deeply (max 8)", .len = sizeof("closures nested too deeply (max 8)") - 1 });
__sc62; }));
    return;
  }
  const ast__ast__ClosureData cl = ast__ast__Ast__at_const(&self->ast, id)->as_data.closure;
  resolver__resolver__Resolver__scope_enter(self);
  Vector__resolver__resolver__ClosureScope__Global__push(&self->closures, (resolver__resolver__ClosureScope){ .node = id, .floor = ((uint32_t)Vector__resolver__resolver__Symbol__Global__len(&self->symbols)), .caps = Vector__u32__Global__new() });
  for (uint32_t i = 0U; i < cl.params.len; i++) {
    const uint32_t pid = resolver__resolver__Resolver__child(self, cl.params, i);
    const ast__ast__ParameterData param = ast__ast__Ast__at_const(&self->ast, pid)->as_data.parameter;
    resolver__resolver__Resolver__declare(self, param.name, pid, resolver__resolver__Namespace_NS_VALUE);
    resolver__resolver__Resolver__resolve_type(self, param.ty);
  }
  if (cl.expr_body) {
    resolver__resolver__Resolver__resolve_expr(self, cl.body);
  } else {
    resolver__resolver__Resolver__resolve_block(self, cl.body);
  }
  const size_t top = (Vector__resolver__resolver__ClosureScope__Global__len(&self->closures) - 1ULL);
  const size_t ncaps = Vector__u32__Global__len(&(*({ __auto_type __sc63 = &self->closures; Vector__resolver__resolver__ClosureScope__Global__index(__sc63, top); })).caps);
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  for (size_t k = 0ULL; k < ncaps; k++) {
    const uint32_t cap = (*({ __auto_type __sc64 = &(*({ __auto_type __sc65 = &self->closures; Vector__resolver__resolver__ClosureScope__Global__index(__sc65, top); })).caps; Vector__u32__Global__index(__sc64, k); }));
    ast__ast__Ast__push(&self->ast, cap);
  }
  const ast__ast__NodeList list = ast__ast__Ast__commit(&self->ast, mark);
  (ast__ast__Ast__at(&self->ast, id)->as_data.closure.captures = list);
  Vector__resolver__resolver__ClosureScope__Global__truncate(&self->closures, top);
  resolver__resolver__Resolver__scope_exit(self);
}

static __attribute__((unused)) void resolver__resolver__Resolver__resolve_pattern(resolver__resolver__Resolver *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return;
  }
  const ast__ast__NodeKind kind = ast__ast__Ast__at_const(&self->ast, id)->kind;
  {
    const ast__ast__NodeKind __sc66 = kind;
    if (__sc66 == ast__ast__NodeKind_NODE_IDENTIFIER) {
      {
        resolver__resolver__Resolver__declare(self, id, id, resolver__resolver__Namespace_NS_VALUE);
      }
    }
    else if (__sc66 == ast__ast__NodeKind_NODE_PATTERN_NAME) {
      {
        const ast__ast__PatternData pd = ast__ast__Ast__at_const(&self->ast, id)->as_data.pattern;
        resolver__resolver__Resolver__declare(self, pd.name, id, resolver__resolver__Namespace_NS_VALUE);
        for (uint32_t i = 0U; i < pd.children.len; i++) {
          const uint32_t s = resolver__resolver__Resolver__child(self, pd.children, i);
          resolver__resolver__Resolver__resolve_pattern(self, s);
        }
      }
    }
    else if ((__sc66 == ast__ast__NodeKind_NODE_PATTERN_TUPLE) || (__sc66 == ast__ast__NodeKind_NODE_PATTERN_STRUCT) || (__sc66 == ast__ast__NodeKind_NODE_PATTERN_FIELD)) {
      {
        const ast__ast__NodeList children = ast__ast__Ast__at_const(&self->ast, id)->as_data.pattern.children;
        for (uint32_t i = 0U; i < children.len; i++) {
          const uint32_t c = resolver__resolver__Resolver__child(self, children, i);
          resolver__resolver__Resolver__resolve_pattern(self, c);
        }
      }
    }
    else if (__sc66 == ast__ast__NodeKind_NODE_PATTERN_OR) {
      {
        const ast__ast__NodeList children = ast__ast__Ast__at_const(&self->ast, id)->as_data.pattern.children;
        if (children.len != 0U) {
          const uint32_t c0 = resolver__resolver__Resolver__child(self, children, 0U);
          resolver__resolver__Resolver__resolve_pattern(self, c0);
        }
      }
    }
    else if (1) {
      {
      }
    }
  }
}

static __attribute__((unused)) void resolver__resolver__Resolver__collect_items(resolver__resolver__Resolver *const self, ast__ast__NodeList const items) {
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t id = resolver__resolver__Resolver__child(self, items, i);
    {
      const ast__ast__NodeKind __sc67 = ast__ast__Ast__at_const(&self->ast, id)->kind;
      if (__sc67 == ast__ast__NodeKind_NODE_FUNCTION) {
        {
          const uint32_t nm = ast__ast__Ast__at_const(&self->ast, id)->as_data.function.name;
          resolver__resolver__Resolver__declare(self, nm, id, resolver__resolver__Namespace_NS_VALUE);
        }
      }
      else if (__sc67 == ast__ast__NodeKind_NODE_CONST) {
        {
          const uint32_t nm = ast__ast__Ast__at_const(&self->ast, id)->as_data.const_def.name;
          resolver__resolver__Resolver__declare(self, nm, id, resolver__resolver__Namespace_NS_VALUE);
        }
      }
      else if ((__sc67 == ast__ast__NodeKind_NODE_STRUCT) || (__sc67 == ast__ast__NodeKind_NODE_ENUM)) {
        {
          const uint32_t nm = ast__ast__Ast__at_const(&self->ast, id)->as_data.aggregate.name;
          resolver__resolver__Resolver__declare(self, nm, id, resolver__resolver__Namespace_NS_TYPE);
        }
      }
      else if (__sc67 == ast__ast__NodeKind_NODE_INTERFACE) {
        {
          const uint32_t nm = ast__ast__Ast__at_const(&self->ast, id)->as_data.interface_def.name;
          resolver__resolver__Resolver__declare(self, nm, id, resolver__resolver__Namespace_NS_TYPE);
        }
      }
      else if (__sc67 == ast__ast__NodeKind_NODE_TYPE_ALIAS) {
        {
          const uint32_t nm = ast__ast__Ast__at_const(&self->ast, id)->as_data.type_alias.name;
          resolver__resolver__Resolver__declare(self, nm, id, resolver__resolver__Namespace_NS_TYPE);
        }
      }
      else if (__sc67 == ast__ast__NodeKind_NODE_EXTERN_BLOCK) {
        {
          const ast__ast__NodeList inner = ast__ast__Ast__at_const(&self->ast, id)->as_data.extern_block.items;
          for (uint32_t j = 0U; j < inner.len; j++) {
            const uint32_t iid = resolver__resolver__Resolver__child(self, inner, j);
            {
              const ast__ast__NodeKind __sc68 = ast__ast__Ast__at_const(&self->ast, iid)->kind;
              if (__sc68 == ast__ast__NodeKind_NODE_FUNCTION) {
                {
                  const uint32_t nm = ast__ast__Ast__at_const(&self->ast, iid)->as_data.function.name;
                  resolver__resolver__Resolver__declare(self, nm, iid, resolver__resolver__Namespace_NS_VALUE);
                }
              }
              else if (__sc68 == ast__ast__NodeKind_NODE_TYPE_ALIAS) {
                {
                  const uint32_t nm = ast__ast__Ast__at_const(&self->ast, iid)->as_data.type_alias.name;
                  resolver__resolver__Resolver__declare(self, nm, iid, resolver__resolver__Namespace_NS_TYPE);
                }
              }
              else if (__sc68 == ast__ast__NodeKind_NODE_CONST) {
                {
                  const uint32_t nm = ast__ast__Ast__at_const(&self->ast, iid)->as_data.const_def.name;
                  resolver__resolver__Resolver__declare(self, nm, iid, resolver__resolver__Namespace_NS_VALUE);
                }
              }
              else if (1) {
                {
                }
              }
            }
          }
        }
      }
      else if (1) {
        {
        }
      }
    }
  }
}

static __attribute__((unused)) str resolver__resolver__Resolver__package_file(const resolver__resolver__Resolver *const self) {
  if (self->package == NULL) {
    return (str){ (const uint8_t *)"", sizeof("") - 1 };
  }
  const module__loader__Package *const pkg = (&(*self->package));
  const uint16_t m = self->ast.module;
  if (((size_t)m) < Vector__module__loader__Module__Global__len(&pkg->modules)) {
    return String__Global__as_str(&(*({ __auto_type __sc69 = &pkg->modules; Vector__module__loader__Module__Global__index(__sc69, ((size_t)m)); })).file);
  }
  return (str){ (const uint8_t *)"", sizeof("") - 1 };
}

void resolver__resolver__Resolver__resolve(resolver__resolver__Resolver *const self) {
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&self->ast, self->ast.root)->as_data.program.items;
  ast__ast__Ast__init_resolutions(&self->ast);
  resolver__resolver__Resolver__scope_enter(self);
  resolver__resolver__Resolver__collect_items(self, items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t cid = resolver__resolver__Resolver__child(self, items, i);
    resolver__resolver__Resolver__resolve_item(self, cid);
  }
  resolver__resolver__Resolver__scope_exit(self);
  const str fstr = resolver__resolver__Resolver__package_file(self);
  resolver__resolver__FileScratch fb = (resolver__resolver__FileScratch){0};
  const char *file = NULL;
  const size_t fl = str__len(&fstr);
  if ((fl != 0ULL) && (fl < 4096ULL)) {
    memcpy(((void *)(&fb.b[0])), ((const void *)str__ptr(&fstr)), fl);
    (fb.b[fl] = 0);
    (file = ((const char *)(&fb.b[0])));
  }
  utils__errors__Errors__finalize(&self->errors, self->source, self->len, file);
}

bool resolver__resolver__Resolver__has_errors(const resolver__resolver__Resolver *const self) {
  return utils__errors__Errors__has_errors(&self->errors);
}

void resolver__resolver__Resolver__log_errors(const resolver__resolver__Resolver *const self) {
  utils__errors__Errors__log(&self->errors);
}

void resolver__resolver__Resolver__free(resolver__resolver__Resolver *const self) {
  ast__ast__Ast__free(&self->ast);
  Vector__resolver__resolver__Symbol__Global__free(&self->symbols);
  Vector__u32__Global__free(&self->symbol_previous);
  Vector__u32__Global__free(&self->scope_starts);
  Map__u64__u32__Global__free(&self->symbol_index);
  Vector__resolver__resolver__ClosureScope__Global__free(&self->closures);
  utils__errors__Errors__free(&self->errors);
}

