#include "../ast/ast.h"
#include "../string.h"
#include "../lexer/token.h"
#include "../lexer/token_type.h"
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

_Static_assert(sizeof(ast__ast__NodeList) == 8 && _Alignof(ast__ast__NodeList) == 4, "super-c layout model mismatch: ast__ast__NodeList");
_Static_assert(sizeof(ast__ast__DefId) == 8 && _Alignof(ast__ast__DefId) == 4, "super-c layout model mismatch: ast__ast__DefId");
_Static_assert(sizeof(ast__ast__Attr) == 20 && _Alignof(ast__ast__Attr) == 4, "super-c layout model mismatch: ast__ast__Attr");
_Static_assert(sizeof(ast__ast__ProgramData) == 8 && _Alignof(ast__ast__ProgramData) == 4, "super-c layout model mismatch: ast__ast__ProgramData");
_Static_assert(sizeof(ast__ast__NameData) == 12 && _Alignof(ast__ast__NameData) == 4, "super-c layout model mismatch: ast__ast__NameData");
_Static_assert(sizeof(ast__ast__LiteralData) == 12 && _Alignof(ast__ast__LiteralData) == 4, "super-c layout model mismatch: ast__ast__LiteralData");
_Static_assert(sizeof(ast__ast__FunctionData) == 44 && _Alignof(ast__ast__FunctionData) == 4, "super-c layout model mismatch: ast__ast__FunctionData");
_Static_assert(sizeof(ast__ast__ParameterData) == 12 && _Alignof(ast__ast__ParameterData) == 4, "super-c layout model mismatch: ast__ast__ParameterData");
_Static_assert(sizeof(ast__ast__AggregateData) == 24 && _Alignof(ast__ast__AggregateData) == 4, "super-c layout model mismatch: ast__ast__AggregateData");
_Static_assert(sizeof(ast__ast__FieldData) == 16 && _Alignof(ast__ast__FieldData) == 4, "super-c layout model mismatch: ast__ast__FieldData");
_Static_assert(sizeof(ast__ast__VariantData) == 20 && _Alignof(ast__ast__VariantData) == 4, "super-c layout model mismatch: ast__ast__VariantData");
_Static_assert(sizeof(ast__ast__InterfaceData) == 32 && _Alignof(ast__ast__InterfaceData) == 4, "super-c layout model mismatch: ast__ast__InterfaceData");
_Static_assert(sizeof(ast__ast__ExtendData) == 24 && _Alignof(ast__ast__ExtendData) == 4, "super-c layout model mismatch: ast__ast__ExtendData");
_Static_assert(sizeof(ast__ast__TypeAliasData) == 20 && _Alignof(ast__ast__TypeAliasData) == 4, "super-c layout model mismatch: ast__ast__TypeAliasData");
_Static_assert(sizeof(ast__ast__ConstData) == 16 && _Alignof(ast__ast__ConstData) == 4, "super-c layout model mismatch: ast__ast__ConstData");
_Static_assert(sizeof(ast__ast__ExternBlockData) == 16 && _Alignof(ast__ast__ExternBlockData) == 4, "super-c layout model mismatch: ast__ast__ExternBlockData");
_Static_assert(sizeof(ast__ast__ImportData) == 16 && _Alignof(ast__ast__ImportData) == 4, "super-c layout model mismatch: ast__ast__ImportData");
_Static_assert(sizeof(ast__ast__GenericParamData) == 24 && _Alignof(ast__ast__GenericParamData) == 4, "super-c layout model mismatch: ast__ast__GenericParamData");
_Static_assert(sizeof(ast__ast__WherePredicateData) == 12 && _Alignof(ast__ast__WherePredicateData) == 4, "super-c layout model mismatch: ast__ast__WherePredicateData");
_Static_assert(sizeof(ast__ast__TypePathData) == 16 && _Alignof(ast__ast__TypePathData) == 4, "super-c layout model mismatch: ast__ast__TypePathData");
_Static_assert(sizeof(ast__ast__IndirectTypeData) == 8 && _Alignof(ast__ast__IndirectTypeData) == 4, "super-c layout model mismatch: ast__ast__IndirectTypeData");
_Static_assert(sizeof(ast__ast__ArrayTypeData) == 8 && _Alignof(ast__ast__ArrayTypeData) == 4, "super-c layout model mismatch: ast__ast__ArrayTypeData");
_Static_assert(sizeof(ast__ast__FunctionTypeData) == 20 && _Alignof(ast__ast__FunctionTypeData) == 4, "super-c layout model mismatch: ast__ast__FunctionTypeData");
_Static_assert(sizeof(ast__ast__BlockData) == 8 && _Alignof(ast__ast__BlockData) == 4, "super-c layout model mismatch: ast__ast__BlockData");
_Static_assert(sizeof(ast__ast__LetData) == 16 && _Alignof(ast__ast__LetData) == 4, "super-c layout model mismatch: ast__ast__LetData");
_Static_assert(sizeof(ast__ast__SingleData) == 4 && _Alignof(ast__ast__SingleData) == 4, "super-c layout model mismatch: ast__ast__SingleData");
_Static_assert(sizeof(ast__ast__VaOpData) == 12 && _Alignof(ast__ast__VaOpData) == 4, "super-c layout model mismatch: ast__ast__VaOpData");
_Static_assert(sizeof(ast__ast__ReturnData) == 8 && _Alignof(ast__ast__ReturnData) == 4, "super-c layout model mismatch: ast__ast__ReturnData");
_Static_assert(sizeof(ast__ast__IfData) == 12 && _Alignof(ast__ast__IfData) == 4, "super-c layout model mismatch: ast__ast__IfData");
_Static_assert(sizeof(ast__ast__WhileData) == 20 && _Alignof(ast__ast__WhileData) == 4, "super-c layout model mismatch: ast__ast__WhileData");
_Static_assert(sizeof(ast__ast__ForData) == 20 && _Alignof(ast__ast__ForData) == 4, "super-c layout model mismatch: ast__ast__ForData");
_Static_assert(sizeof(ast__ast__FlowData) == 12 && _Alignof(ast__ast__FlowData) == 4, "super-c layout model mismatch: ast__ast__FlowData");
_Static_assert(sizeof(ast__ast__UnaryData) == 12 && _Alignof(ast__ast__UnaryData) == 4, "super-c layout model mismatch: ast__ast__UnaryData");
_Static_assert(sizeof(ast__ast__BinaryData) == 12 && _Alignof(ast__ast__BinaryData) == 4, "super-c layout model mismatch: ast__ast__BinaryData");
_Static_assert(sizeof(ast__ast__CallData) == 12 && _Alignof(ast__ast__CallData) == 4, "super-c layout model mismatch: ast__ast__CallData");
_Static_assert(sizeof(ast__ast__ClosureData) == 36 && _Alignof(ast__ast__ClosureData) == 4, "super-c layout model mismatch: ast__ast__ClosureData");
_Static_assert(sizeof(ast__ast__IndexData) == 8 && _Alignof(ast__ast__IndexData) == 4, "super-c layout model mismatch: ast__ast__IndexData");
_Static_assert(sizeof(ast__ast__MemberData) == 12 && _Alignof(ast__ast__MemberData) == 4, "super-c layout model mismatch: ast__ast__MemberData");
_Static_assert(sizeof(ast__ast__CastData) == 8 && _Alignof(ast__ast__CastData) == 4, "super-c layout model mismatch: ast__ast__CastData");
_Static_assert(sizeof(ast__ast__SpecializationData) == 12 && _Alignof(ast__ast__SpecializationData) == 4, "super-c layout model mismatch: ast__ast__SpecializationData");
_Static_assert(sizeof(ast__ast__MatchData) == 12 && _Alignof(ast__ast__MatchData) == 4, "super-c layout model mismatch: ast__ast__MatchData");
_Static_assert(sizeof(ast__ast__MatchArmData) == 12 && _Alignof(ast__ast__MatchArmData) == 4, "super-c layout model mismatch: ast__ast__MatchArmData");
_Static_assert(sizeof(ast__ast__NewData) == 8 && _Alignof(ast__ast__NewData) == 4, "super-c layout model mismatch: ast__ast__NewData");
_Static_assert(sizeof(ast__ast__ArrayLiteralData) == 8 && _Alignof(ast__ast__ArrayLiteralData) == 4, "super-c layout model mismatch: ast__ast__ArrayLiteralData");
_Static_assert(sizeof(ast__ast__StructInitializerData) == 12 && _Alignof(ast__ast__StructInitializerData) == 4, "super-c layout model mismatch: ast__ast__StructInitializerData");
_Static_assert(sizeof(ast__ast__FieldInitializerData) == 8 && _Alignof(ast__ast__FieldInitializerData) == 4, "super-c layout model mismatch: ast__ast__FieldInitializerData");
_Static_assert(sizeof(ast__ast__PatternData) == 12 && _Alignof(ast__ast__PatternData) == 4, "super-c layout model mismatch: ast__ast__PatternData");
_Static_assert(sizeof(ast__ast__PatternRangeData) == 12 && _Alignof(ast__ast__PatternRangeData) == 4, "super-c layout model mismatch: ast__ast__PatternRangeData");
_Static_assert(sizeof(ast__ast__NodeAs) == 44 && _Alignof(ast__ast__NodeAs) == 4, "super-c layout model mismatch: ast__ast__NodeAs");
_Static_assert(sizeof(ast__ast__Node) == 56 && _Alignof(ast__ast__Node) == 4, "super-c layout model mismatch: ast__ast__Node");
_Static_assert(sizeof(ast__ast__TyArr) == 8 && _Alignof(ast__ast__TyArr) == 4, "super-c layout model mismatch: ast__ast__TyArr");
_Static_assert(sizeof(ast__ast__TyAs) == 8 && _Alignof(ast__ast__TyAs) == 8, "super-c layout model mismatch: ast__ast__TyAs");
_Static_assert(sizeof(ast__ast__Ty) == 16 && _Alignof(ast__ast__Ty) == 8, "super-c layout model mismatch: ast__ast__Ty");
_Static_assert(sizeof(ast__ast__TyInstance) == 28 && _Alignof(ast__ast__TyInstance) == 4, "super-c layout model mismatch: ast__ast__TyInstance");
_Static_assert(sizeof(ast__ast__MonoUse) == 24 && _Alignof(ast__ast__MonoUse) == 4, "super-c layout model mismatch: ast__ast__MonoUse");
_Static_assert(sizeof(ast__ast__DynUse) == 12 && _Alignof(ast__ast__DynUse) == 4, "super-c layout model mismatch: ast__ast__DynUse");
_Static_assert(sizeof(ast__ast__DerefUse) == 108 && _Alignof(ast__ast__DerefUse) == 4, "super-c layout model mismatch: ast__ast__DerefUse");
_Static_assert(sizeof(ast__ast__MethodInst) == 28 && _Alignof(ast__ast__MethodInst) == 4, "super-c layout model mismatch: ast__ast__MethodInst");
_Static_assert(sizeof(ast__ast__Ast) == 488 && _Alignof(ast__ast__Ast) == 8, "super-c layout model mismatch: ast__ast__Ast");

static __attribute__((unused)) void ast__ast__ensure_u32_len(Vector__u32__Global *const v, size_t const nodes_len, size_t const need);
static __attribute__((unused)) size_t Map__ast__ast__Ty__u32__Global__slot(const Map__ast__ast__Ty__u32__Global *const self, const ast__ast__Ty *const key);
static __attribute__((unused)) void Map__ast__ast__Ty__u32__Global__grow(Map__ast__ast__Ty__u32__Global *const self);
static __attribute__((unused)) size_t Map__ast__ast__TyInstance__u32__Global__slot(const Map__ast__ast__TyInstance__u32__Global *const self, const ast__ast__TyInstance *const key);
static __attribute__((unused)) void Map__ast__ast__TyInstance__u32__Global__grow(Map__ast__ast__TyInstance__u32__Global *const self);
static __attribute__((unused)) size_t Map__ast__ast__MethodInst__u32__Global__slot(const Map__ast__ast__MethodInst__u32__Global *const self, const ast__ast__MethodInst *const key);
static __attribute__((unused)) void Map__ast__ast__MethodInst__u32__Global__grow(Map__ast__ast__MethodInst__u32__Global *const self);
static __attribute__((unused)) size_t Map__u64__ast__ast__DefId__Global__slot(const Map__u64__ast__ast__DefId__Global *const self, const uint64_t *const key);
static __attribute__((unused)) void Map__u64__ast__ast__DefId__Global__grow(Map__u64__ast__ast__DefId__Global *const self);

Vector__ast__ast__Node__Global Vector__ast__ast__Node__Global__new_in(Global const alloc) {
  return (Vector__ast__ast__Node__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__ast__ast__Node__Global Vector__ast__ast__Node__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__ast__ast__Node__Global v = (Vector__ast__ast__Node__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((ast__ast__Node *)Global__alloc(&v.alloc, (cap * sizeof(ast__ast__Node)), _Alignof(ast__ast__Node))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__ast__ast__Node__Global__len(const Vector__ast__ast__Node__Global *const self) {
  return self->len;
}

void Vector__ast__ast__Node__Global__reserve(Vector__ast__ast__Node__Global *const self, size_t const additional) {
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
  ast__ast__Node *const p = ((ast__ast__Node *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__Node)), (new_cap * sizeof(ast__ast__Node)), _Alignof(ast__ast__Node)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__ast__ast__Node__Global__push(Vector__ast__ast__Node__Global *const self, ast__ast__Node const value) {
  Vector__ast__ast__Node__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const ast__ast__Node *Vector__ast__ast__Node__Global__at(const Vector__ast__ast__Node__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_ast__ast__Node Vector__ast__ast__Node__Global__get(const Vector__ast__ast__Node__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_ast__ast__Node){ .tag = Option_None };
  }
  return (Option__ptr_ast__ast__Node){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__ast__ast__Node__Global__set(Vector__ast__ast__Node__Global *const self, size_t const index, ast__ast__Node const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__ast__ast__Node__Global__clear(Vector__ast__ast__Node__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__ast__ast__Node__Global__truncate(Vector__ast__ast__Node__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const ast__ast__Node *Vector__ast__ast__Node__Global__as_ptr(const Vector__ast__ast__Node__Global *const self) {
  return self->ptr;
}

void Vector__ast__ast__Node__Global__swap(Vector__ast__ast__Node__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__ast__ast__Node__Global Vector__ast__ast__Node__Global__new(void) {
  return Vector__ast__ast__Node__Global__new_in(Global__default_());
}

void Vector__ast__ast__Node__Global__free(Vector__ast__ast__Node__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__Node)), _Alignof(ast__ast__Node));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__ast__ast__Node__Global Vector__ast__ast__Node__Global__default_(void) {
  return Vector__ast__ast__Node__Global__new();
}

const ast__ast__Node *Vector__ast__ast__Node__Global__index(const Vector__ast__ast__Node__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__Node Vector__ast__ast__Node__Global__index_range(const Vector__ast__ast__Node__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc0;
    if (r.inclusive) {
      __sc0 = (r.end + 1ULL);
    } else {
      __sc0 = r.end;
    }
    __sc0;
  });
  return (Slice__ast__ast__Node){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__Node *Vector__ast__ast__Node__Global__index_mut(Vector__ast__ast__Node__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__Node Vector__ast__ast__Node__Global__index_range_mut(Vector__ast__ast__Node__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc1;
    if (r.inclusive) {
      __sc1 = (r.end + 1ULL);
    } else {
      __sc1 = r.end;
    }
    __sc1;
  });
  return (SliceMut__ast__ast__Node){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__ast__ast__DefId__Global Vector__ast__ast__DefId__Global__new_in(Global const alloc) {
  return (Vector__ast__ast__DefId__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__ast__ast__DefId__Global Vector__ast__ast__DefId__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__ast__ast__DefId__Global v = (Vector__ast__ast__DefId__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((ast__ast__DefId *)Global__alloc(&v.alloc, (cap * sizeof(ast__ast__DefId)), _Alignof(ast__ast__DefId))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__ast__ast__DefId__Global__len(const Vector__ast__ast__DefId__Global *const self) {
  return self->len;
}

void Vector__ast__ast__DefId__Global__reserve(Vector__ast__ast__DefId__Global *const self, size_t const additional) {
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
  ast__ast__DefId *const p = ((ast__ast__DefId *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__DefId)), (new_cap * sizeof(ast__ast__DefId)), _Alignof(ast__ast__DefId)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__ast__ast__DefId__Global__push(Vector__ast__ast__DefId__Global *const self, ast__ast__DefId const value) {
  Vector__ast__ast__DefId__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const ast__ast__DefId *Vector__ast__ast__DefId__Global__at(const Vector__ast__ast__DefId__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_ast__ast__DefId Vector__ast__ast__DefId__Global__get(const Vector__ast__ast__DefId__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_ast__ast__DefId){ .tag = Option_None };
  }
  return (Option__ptr_ast__ast__DefId){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__ast__ast__DefId__Global__set(Vector__ast__ast__DefId__Global *const self, size_t const index, ast__ast__DefId const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__ast__ast__DefId__Global__clear(Vector__ast__ast__DefId__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__ast__ast__DefId__Global__truncate(Vector__ast__ast__DefId__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const ast__ast__DefId *Vector__ast__ast__DefId__Global__as_ptr(const Vector__ast__ast__DefId__Global *const self) {
  return self->ptr;
}

void Vector__ast__ast__DefId__Global__swap(Vector__ast__ast__DefId__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__ast__ast__DefId__Global Vector__ast__ast__DefId__Global__new(void) {
  return Vector__ast__ast__DefId__Global__new_in(Global__default_());
}

void Vector__ast__ast__DefId__Global__free(Vector__ast__ast__DefId__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__DefId)), _Alignof(ast__ast__DefId));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__ast__ast__DefId__Global Vector__ast__ast__DefId__Global__default_(void) {
  return Vector__ast__ast__DefId__Global__new();
}

const ast__ast__DefId *Vector__ast__ast__DefId__Global__index(const Vector__ast__ast__DefId__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__DefId Vector__ast__ast__DefId__Global__index_range(const Vector__ast__ast__DefId__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc2;
    if (r.inclusive) {
      __sc2 = (r.end + 1ULL);
    } else {
      __sc2 = r.end;
    }
    __sc2;
  });
  return (Slice__ast__ast__DefId){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__DefId *Vector__ast__ast__DefId__Global__index_mut(Vector__ast__ast__DefId__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__DefId Vector__ast__ast__DefId__Global__index_range_mut(Vector__ast__ast__DefId__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc3;
    if (r.inclusive) {
      __sc3 = (r.end + 1ULL);
    } else {
      __sc3 = r.end;
    }
    __sc3;
  });
  return (SliceMut__ast__ast__DefId){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__ast__ast__Ty__Global Vector__ast__ast__Ty__Global__new_in(Global const alloc) {
  return (Vector__ast__ast__Ty__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__ast__ast__Ty__Global Vector__ast__ast__Ty__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__ast__ast__Ty__Global v = (Vector__ast__ast__Ty__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((ast__ast__Ty *)Global__alloc(&v.alloc, (cap * sizeof(ast__ast__Ty)), _Alignof(ast__ast__Ty))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__ast__ast__Ty__Global__len(const Vector__ast__ast__Ty__Global *const self) {
  return self->len;
}

void Vector__ast__ast__Ty__Global__reserve(Vector__ast__ast__Ty__Global *const self, size_t const additional) {
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
  ast__ast__Ty *const p = ((ast__ast__Ty *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__Ty)), (new_cap * sizeof(ast__ast__Ty)), _Alignof(ast__ast__Ty)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__ast__ast__Ty__Global__push(Vector__ast__ast__Ty__Global *const self, ast__ast__Ty const value) {
  Vector__ast__ast__Ty__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const ast__ast__Ty *Vector__ast__ast__Ty__Global__at(const Vector__ast__ast__Ty__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_ast__ast__Ty Vector__ast__ast__Ty__Global__get(const Vector__ast__ast__Ty__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_ast__ast__Ty){ .tag = Option_None };
  }
  return (Option__ptr_ast__ast__Ty){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__ast__ast__Ty__Global__set(Vector__ast__ast__Ty__Global *const self, size_t const index, ast__ast__Ty const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__ast__ast__Ty__Global__clear(Vector__ast__ast__Ty__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__ast__ast__Ty__Global__truncate(Vector__ast__ast__Ty__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const ast__ast__Ty *Vector__ast__ast__Ty__Global__as_ptr(const Vector__ast__ast__Ty__Global *const self) {
  return self->ptr;
}

void Vector__ast__ast__Ty__Global__swap(Vector__ast__ast__Ty__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__ast__ast__Ty__Global Vector__ast__ast__Ty__Global__new(void) {
  return Vector__ast__ast__Ty__Global__new_in(Global__default_());
}

void Vector__ast__ast__Ty__Global__free(Vector__ast__ast__Ty__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__Ty)), _Alignof(ast__ast__Ty));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__ast__ast__Ty__Global Vector__ast__ast__Ty__Global__default_(void) {
  return Vector__ast__ast__Ty__Global__new();
}

const ast__ast__Ty *Vector__ast__ast__Ty__Global__index(const Vector__ast__ast__Ty__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__Ty Vector__ast__ast__Ty__Global__index_range(const Vector__ast__ast__Ty__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc4;
    if (r.inclusive) {
      __sc4 = (r.end + 1ULL);
    } else {
      __sc4 = r.end;
    }
    __sc4;
  });
  return (Slice__ast__ast__Ty){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__Ty *Vector__ast__ast__Ty__Global__index_mut(Vector__ast__ast__Ty__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__Ty Vector__ast__ast__Ty__Global__index_range_mut(Vector__ast__ast__Ty__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc5;
    if (r.inclusive) {
      __sc5 = (r.end + 1ULL);
    } else {
      __sc5 = r.end;
    }
    __sc5;
  });
  return (SliceMut__ast__ast__Ty){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

bool Vector__ast__ast__Ty__Global__eq(const Vector__ast__ast__Ty__Global *const self, const Vector__ast__ast__Ty__Global *const other) {
  if (Vector__ast__ast__Ty__Global__len(self) != Vector__ast__ast__Ty__Global__len(other)) {
    return false;
  }
  for (size_t i = 0ULL; i < Vector__ast__ast__Ty__Global__len(self); i++) {
    const ast__ast__Ty *const a = Vector__ast__ast__Ty__Global__at(self, i);
    const ast__ast__Ty *const b = Vector__ast__ast__Ty__Global__at(other, i);
    if (!ast__ast__Ty__eq(a, b)) {
      return false;
    }
  }
  return true;
}

uint64_t Vector__ast__ast__Ty__Global__hash(const Vector__ast__ast__Ty__Global *const self) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < Vector__ast__ast__Ty__Global__len(self); i++) {
    const ast__ast__Ty *const e = Vector__ast__ast__Ty__Global__at(self, i);
    (h = ((h ^ ast__ast__Ty__hash(e)) * 0x100000001b3ULL));
  }
  return h;
}

Map__ast__ast__Ty__u32__Global Map__ast__ast__Ty__u32__Global__new_in(Global const alloc) {
  return (Map__ast__ast__Ty__u32__Global){ .keys = NULL, .vals = NULL, .used = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

size_t Map__ast__ast__Ty__u32__Global__len(const Map__ast__ast__Ty__u32__Global *const self) {
  return self->len;
}

bool Map__ast__ast__Ty__u32__Global__is_empty(const Map__ast__ast__Ty__u32__Global *const self) {
  return (self->len == 0ULL);
}

static __attribute__((unused)) size_t Map__ast__ast__Ty__u32__Global__slot(const Map__ast__ast__Ty__u32__Global *const self, const ast__ast__Ty *const key) {
  size_t i = ({ size_t __sc6 = ((size_t)ast__ast__Ty__hash(key)); size_t __sc7 = self->cap; if (__sc7 == 0) { __sc_panic("divide by zero"); } (__sc6 % __sc7); });
  while (self->used[i] != 0U) {
    if (ast__ast__Ty__eq(&self->keys[i], key)) {
      return i;
    }
    (i = (i + 1ULL));
    if (i >= self->cap) {
      (i = 0ULL);
    }
  }
  return i;
}

static __attribute__((unused)) void Map__ast__ast__Ty__u32__Global__grow(Map__ast__ast__Ty__u32__Global *const self) {
  size_t newcap = (self->cap * 2ULL);
  if (newcap < 8ULL) {
    (newcap = 8ULL);
  }
  ast__ast__Ty *const oldkeys = self->keys;
  uint32_t *const oldvals = self->vals;
  uint8_t *const oldused = self->used;
  const size_t oldcap = self->cap;
  (self->keys = ((ast__ast__Ty *)Global__alloc(&self->alloc, (newcap * sizeof(ast__ast__Ty)), _Alignof(ast__ast__Ty))));
  (self->vals = ((uint32_t *)Global__alloc(&self->alloc, (newcap * sizeof(uint32_t)), _Alignof(uint32_t))));
  (self->used = ((uint8_t *)Global__alloc(&self->alloc, newcap, 1ULL)));
  memset(((void *)self->used), 0, newcap);
  (self->cap = newcap);
  (self->len = 0ULL);
  for (size_t i = 0ULL; i < oldcap; i++) {
    if (oldused[i] == 1U) {
      const size_t j = Map__ast__ast__Ty__u32__Global__slot(self, (&oldkeys[i]));
      (self->keys[j] = oldkeys[i]);
      (self->vals[j] = oldvals[i]);
      (self->used[j] = 1U);
      (self->len = (self->len + 1ULL));
    }
  }
  if (oldcap > 0ULL) {
    Global__dealloc(&self->alloc, ((void *)oldkeys), (oldcap * sizeof(ast__ast__Ty)), _Alignof(ast__ast__Ty));
    Global__dealloc(&self->alloc, ((void *)oldvals), (oldcap * sizeof(uint32_t)), _Alignof(uint32_t));
    Global__dealloc(&self->alloc, ((void *)oldused), oldcap, 1ULL);
  }
}

void Map__ast__ast__Ty__u32__Global__insert(Map__ast__ast__Ty__u32__Global *const self, ast__ast__Ty const key, uint32_t const value) {
  if ((self->cap == 0ULL) || (((self->len + 1ULL) * 4ULL) >= (self->cap * 3ULL))) {
    Map__ast__ast__Ty__u32__Global__grow(self);
  }
  const size_t i = Map__ast__ast__Ty__u32__Global__slot(self, (&key));
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

Option__ptr_u32 Map__ast__ast__Ty__u32__Global__get(const Map__ast__ast__Ty__u32__Global *const self, const ast__ast__Ty *const key) {
  if (self->cap == 0ULL) {
    return (Option__ptr_u32){ .tag = Option_None };
  }
  const size_t i = Map__ast__ast__Ty__u32__Global__slot(self, key);
  if (self->used[i] == 0U) {
    return (Option__ptr_u32){ .tag = Option_None };
  }
  return (Option__ptr_u32){ .tag = Option_Some, .payload.Some = { (&self->vals[i]) } };
}

bool Map__ast__ast__Ty__u32__Global__contains_key(const Map__ast__ast__Ty__u32__Global *const self, const ast__ast__Ty *const key) {
  return ({ __auto_type __sc8 = Map__ast__ast__Ty__u32__Global__get(self, key); Option__ptr_u32__is_some(&__sc8); });
}

Option__u32 Map__ast__ast__Ty__u32__Global__remove(Map__ast__ast__Ty__u32__Global *const self, const ast__ast__Ty *const key) {
  if (self->cap == 0ULL) {
    return (Option__u32){ .tag = Option_None };
  }
  const size_t i = Map__ast__ast__Ty__u32__Global__slot(self, key);
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
    Map__ast__ast__Ty__u32__Global__insert(self, k, v);
    (j = (j + 1ULL));
    if (j >= self->cap) {
      (j = 0ULL);
    }
  }
  return (Option__u32){ .tag = Option_Some, .payload.Some = { removed } };
}

Map__ast__ast__Ty__u32__Global Map__ast__ast__Ty__u32__Global__new(void) {
  return Map__ast__ast__Ty__u32__Global__new_in(Global__default_());
}

void Map__ast__ast__Ty__u32__Global__free(Map__ast__ast__Ty__u32__Global *const self) {
  for (size_t i = 0ULL; i < self->cap; i++) {
    if (self->used[i] != 0U) {
      (void)(self->keys[i]);
      (void)(self->vals[i]);
    }
  }
  Global__dealloc(&self->alloc, ((void *)self->keys), (self->cap * sizeof(ast__ast__Ty)), _Alignof(ast__ast__Ty));
  Global__dealloc(&self->alloc, ((void *)self->vals), (self->cap * sizeof(uint32_t)), _Alignof(uint32_t));
  Global__dealloc(&self->alloc, ((void *)self->used), self->cap, 1ULL);
  (self->keys = NULL);
  (self->vals = NULL);
  (self->used = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

MapKeys__ast__ast__Ty Map__ast__ast__Ty__u32__Global__keys(const Map__ast__ast__Ty__u32__Global *const self) {
  return (MapKeys__ast__ast__Ty){ .keys = ((const ast__ast__Ty *)self->keys), .used = ((const uint8_t *)self->used), .idx = 0ULL, .cap = self->cap };
}

Vector__ast__ast__MonoUse__Global Vector__ast__ast__MonoUse__Global__new_in(Global const alloc) {
  return (Vector__ast__ast__MonoUse__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__ast__ast__MonoUse__Global Vector__ast__ast__MonoUse__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__ast__ast__MonoUse__Global v = (Vector__ast__ast__MonoUse__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((ast__ast__MonoUse *)Global__alloc(&v.alloc, (cap * sizeof(ast__ast__MonoUse)), _Alignof(ast__ast__MonoUse))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__ast__ast__MonoUse__Global__len(const Vector__ast__ast__MonoUse__Global *const self) {
  return self->len;
}

void Vector__ast__ast__MonoUse__Global__reserve(Vector__ast__ast__MonoUse__Global *const self, size_t const additional) {
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
  ast__ast__MonoUse *const p = ((ast__ast__MonoUse *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__MonoUse)), (new_cap * sizeof(ast__ast__MonoUse)), _Alignof(ast__ast__MonoUse)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__ast__ast__MonoUse__Global__push(Vector__ast__ast__MonoUse__Global *const self, ast__ast__MonoUse const value) {
  Vector__ast__ast__MonoUse__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const ast__ast__MonoUse *Vector__ast__ast__MonoUse__Global__at(const Vector__ast__ast__MonoUse__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_ast__ast__MonoUse Vector__ast__ast__MonoUse__Global__get(const Vector__ast__ast__MonoUse__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_ast__ast__MonoUse){ .tag = Option_None };
  }
  return (Option__ptr_ast__ast__MonoUse){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__ast__ast__MonoUse__Global__set(Vector__ast__ast__MonoUse__Global *const self, size_t const index, ast__ast__MonoUse const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__ast__ast__MonoUse__Global__clear(Vector__ast__ast__MonoUse__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__ast__ast__MonoUse__Global__truncate(Vector__ast__ast__MonoUse__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const ast__ast__MonoUse *Vector__ast__ast__MonoUse__Global__as_ptr(const Vector__ast__ast__MonoUse__Global *const self) {
  return self->ptr;
}

void Vector__ast__ast__MonoUse__Global__swap(Vector__ast__ast__MonoUse__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__ast__ast__MonoUse__Global Vector__ast__ast__MonoUse__Global__new(void) {
  return Vector__ast__ast__MonoUse__Global__new_in(Global__default_());
}

void Vector__ast__ast__MonoUse__Global__free(Vector__ast__ast__MonoUse__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__MonoUse)), _Alignof(ast__ast__MonoUse));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__ast__ast__MonoUse__Global Vector__ast__ast__MonoUse__Global__default_(void) {
  return Vector__ast__ast__MonoUse__Global__new();
}

const ast__ast__MonoUse *Vector__ast__ast__MonoUse__Global__index(const Vector__ast__ast__MonoUse__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__MonoUse Vector__ast__ast__MonoUse__Global__index_range(const Vector__ast__ast__MonoUse__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc9;
    if (r.inclusive) {
      __sc9 = (r.end + 1ULL);
    } else {
      __sc9 = r.end;
    }
    __sc9;
  });
  return (Slice__ast__ast__MonoUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__MonoUse *Vector__ast__ast__MonoUse__Global__index_mut(Vector__ast__ast__MonoUse__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__MonoUse Vector__ast__ast__MonoUse__Global__index_range_mut(Vector__ast__ast__MonoUse__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc10;
    if (r.inclusive) {
      __sc10 = (r.end + 1ULL);
    } else {
      __sc10 = r.end;
    }
    __sc10;
  });
  return (SliceMut__ast__ast__MonoUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__ast__ast__TyInstance__Global Vector__ast__ast__TyInstance__Global__new_in(Global const alloc) {
  return (Vector__ast__ast__TyInstance__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__ast__ast__TyInstance__Global Vector__ast__ast__TyInstance__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__ast__ast__TyInstance__Global v = (Vector__ast__ast__TyInstance__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((ast__ast__TyInstance *)Global__alloc(&v.alloc, (cap * sizeof(ast__ast__TyInstance)), _Alignof(ast__ast__TyInstance))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__ast__ast__TyInstance__Global__len(const Vector__ast__ast__TyInstance__Global *const self) {
  return self->len;
}

void Vector__ast__ast__TyInstance__Global__reserve(Vector__ast__ast__TyInstance__Global *const self, size_t const additional) {
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
  ast__ast__TyInstance *const p = ((ast__ast__TyInstance *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__TyInstance)), (new_cap * sizeof(ast__ast__TyInstance)), _Alignof(ast__ast__TyInstance)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__ast__ast__TyInstance__Global__push(Vector__ast__ast__TyInstance__Global *const self, ast__ast__TyInstance const value) {
  Vector__ast__ast__TyInstance__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const ast__ast__TyInstance *Vector__ast__ast__TyInstance__Global__at(const Vector__ast__ast__TyInstance__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_ast__ast__TyInstance Vector__ast__ast__TyInstance__Global__get(const Vector__ast__ast__TyInstance__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_ast__ast__TyInstance){ .tag = Option_None };
  }
  return (Option__ptr_ast__ast__TyInstance){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__ast__ast__TyInstance__Global__set(Vector__ast__ast__TyInstance__Global *const self, size_t const index, ast__ast__TyInstance const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__ast__ast__TyInstance__Global__clear(Vector__ast__ast__TyInstance__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__ast__ast__TyInstance__Global__truncate(Vector__ast__ast__TyInstance__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const ast__ast__TyInstance *Vector__ast__ast__TyInstance__Global__as_ptr(const Vector__ast__ast__TyInstance__Global *const self) {
  return self->ptr;
}

void Vector__ast__ast__TyInstance__Global__swap(Vector__ast__ast__TyInstance__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__ast__ast__TyInstance__Global Vector__ast__ast__TyInstance__Global__new(void) {
  return Vector__ast__ast__TyInstance__Global__new_in(Global__default_());
}

void Vector__ast__ast__TyInstance__Global__free(Vector__ast__ast__TyInstance__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__TyInstance)), _Alignof(ast__ast__TyInstance));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__ast__ast__TyInstance__Global Vector__ast__ast__TyInstance__Global__default_(void) {
  return Vector__ast__ast__TyInstance__Global__new();
}

const ast__ast__TyInstance *Vector__ast__ast__TyInstance__Global__index(const Vector__ast__ast__TyInstance__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__TyInstance Vector__ast__ast__TyInstance__Global__index_range(const Vector__ast__ast__TyInstance__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc11;
    if (r.inclusive) {
      __sc11 = (r.end + 1ULL);
    } else {
      __sc11 = r.end;
    }
    __sc11;
  });
  return (Slice__ast__ast__TyInstance){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__TyInstance *Vector__ast__ast__TyInstance__Global__index_mut(Vector__ast__ast__TyInstance__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__TyInstance Vector__ast__ast__TyInstance__Global__index_range_mut(Vector__ast__ast__TyInstance__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc12;
    if (r.inclusive) {
      __sc12 = (r.end + 1ULL);
    } else {
      __sc12 = r.end;
    }
    __sc12;
  });
  return (SliceMut__ast__ast__TyInstance){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

bool Vector__ast__ast__TyInstance__Global__eq(const Vector__ast__ast__TyInstance__Global *const self, const Vector__ast__ast__TyInstance__Global *const other) {
  if (Vector__ast__ast__TyInstance__Global__len(self) != Vector__ast__ast__TyInstance__Global__len(other)) {
    return false;
  }
  for (size_t i = 0ULL; i < Vector__ast__ast__TyInstance__Global__len(self); i++) {
    const ast__ast__TyInstance *const a = Vector__ast__ast__TyInstance__Global__at(self, i);
    const ast__ast__TyInstance *const b = Vector__ast__ast__TyInstance__Global__at(other, i);
    if (!ast__ast__TyInstance__eq(a, b)) {
      return false;
    }
  }
  return true;
}

uint64_t Vector__ast__ast__TyInstance__Global__hash(const Vector__ast__ast__TyInstance__Global *const self) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < Vector__ast__ast__TyInstance__Global__len(self); i++) {
    const ast__ast__TyInstance *const e = Vector__ast__ast__TyInstance__Global__at(self, i);
    (h = ((h ^ ast__ast__TyInstance__hash(e)) * 0x100000001b3ULL));
  }
  return h;
}

Vector__ast__ast__MethodInst__Global Vector__ast__ast__MethodInst__Global__new_in(Global const alloc) {
  return (Vector__ast__ast__MethodInst__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__ast__ast__MethodInst__Global Vector__ast__ast__MethodInst__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__ast__ast__MethodInst__Global v = (Vector__ast__ast__MethodInst__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((ast__ast__MethodInst *)Global__alloc(&v.alloc, (cap * sizeof(ast__ast__MethodInst)), _Alignof(ast__ast__MethodInst))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__ast__ast__MethodInst__Global__len(const Vector__ast__ast__MethodInst__Global *const self) {
  return self->len;
}

void Vector__ast__ast__MethodInst__Global__reserve(Vector__ast__ast__MethodInst__Global *const self, size_t const additional) {
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
  ast__ast__MethodInst *const p = ((ast__ast__MethodInst *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__MethodInst)), (new_cap * sizeof(ast__ast__MethodInst)), _Alignof(ast__ast__MethodInst)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__ast__ast__MethodInst__Global__push(Vector__ast__ast__MethodInst__Global *const self, ast__ast__MethodInst const value) {
  Vector__ast__ast__MethodInst__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const ast__ast__MethodInst *Vector__ast__ast__MethodInst__Global__at(const Vector__ast__ast__MethodInst__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_ast__ast__MethodInst Vector__ast__ast__MethodInst__Global__get(const Vector__ast__ast__MethodInst__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_ast__ast__MethodInst){ .tag = Option_None };
  }
  return (Option__ptr_ast__ast__MethodInst){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__ast__ast__MethodInst__Global__set(Vector__ast__ast__MethodInst__Global *const self, size_t const index, ast__ast__MethodInst const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__ast__ast__MethodInst__Global__clear(Vector__ast__ast__MethodInst__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__ast__ast__MethodInst__Global__truncate(Vector__ast__ast__MethodInst__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const ast__ast__MethodInst *Vector__ast__ast__MethodInst__Global__as_ptr(const Vector__ast__ast__MethodInst__Global *const self) {
  return self->ptr;
}

void Vector__ast__ast__MethodInst__Global__swap(Vector__ast__ast__MethodInst__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__ast__ast__MethodInst__Global Vector__ast__ast__MethodInst__Global__new(void) {
  return Vector__ast__ast__MethodInst__Global__new_in(Global__default_());
}

void Vector__ast__ast__MethodInst__Global__free(Vector__ast__ast__MethodInst__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__MethodInst)), _Alignof(ast__ast__MethodInst));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__ast__ast__MethodInst__Global Vector__ast__ast__MethodInst__Global__default_(void) {
  return Vector__ast__ast__MethodInst__Global__new();
}

const ast__ast__MethodInst *Vector__ast__ast__MethodInst__Global__index(const Vector__ast__ast__MethodInst__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__MethodInst Vector__ast__ast__MethodInst__Global__index_range(const Vector__ast__ast__MethodInst__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc13;
    if (r.inclusive) {
      __sc13 = (r.end + 1ULL);
    } else {
      __sc13 = r.end;
    }
    __sc13;
  });
  return (Slice__ast__ast__MethodInst){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__MethodInst *Vector__ast__ast__MethodInst__Global__index_mut(Vector__ast__ast__MethodInst__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__MethodInst Vector__ast__ast__MethodInst__Global__index_range_mut(Vector__ast__ast__MethodInst__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc14;
    if (r.inclusive) {
      __sc14 = (r.end + 1ULL);
    } else {
      __sc14 = r.end;
    }
    __sc14;
  });
  return (SliceMut__ast__ast__MethodInst){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

bool Vector__ast__ast__MethodInst__Global__eq(const Vector__ast__ast__MethodInst__Global *const self, const Vector__ast__ast__MethodInst__Global *const other) {
  if (Vector__ast__ast__MethodInst__Global__len(self) != Vector__ast__ast__MethodInst__Global__len(other)) {
    return false;
  }
  for (size_t i = 0ULL; i < Vector__ast__ast__MethodInst__Global__len(self); i++) {
    const ast__ast__MethodInst *const a = Vector__ast__ast__MethodInst__Global__at(self, i);
    const ast__ast__MethodInst *const b = Vector__ast__ast__MethodInst__Global__at(other, i);
    if (!ast__ast__MethodInst__eq(a, b)) {
      return false;
    }
  }
  return true;
}

uint64_t Vector__ast__ast__MethodInst__Global__hash(const Vector__ast__ast__MethodInst__Global *const self) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < Vector__ast__ast__MethodInst__Global__len(self); i++) {
    const ast__ast__MethodInst *const e = Vector__ast__ast__MethodInst__Global__at(self, i);
    (h = ((h ^ ast__ast__MethodInst__hash(e)) * 0x100000001b3ULL));
  }
  return h;
}

Map__ast__ast__TyInstance__u32__Global Map__ast__ast__TyInstance__u32__Global__new_in(Global const alloc) {
  return (Map__ast__ast__TyInstance__u32__Global){ .keys = NULL, .vals = NULL, .used = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

size_t Map__ast__ast__TyInstance__u32__Global__len(const Map__ast__ast__TyInstance__u32__Global *const self) {
  return self->len;
}

bool Map__ast__ast__TyInstance__u32__Global__is_empty(const Map__ast__ast__TyInstance__u32__Global *const self) {
  return (self->len == 0ULL);
}

static __attribute__((unused)) size_t Map__ast__ast__TyInstance__u32__Global__slot(const Map__ast__ast__TyInstance__u32__Global *const self, const ast__ast__TyInstance *const key) {
  size_t i = ({ size_t __sc15 = ((size_t)ast__ast__TyInstance__hash(key)); size_t __sc16 = self->cap; if (__sc16 == 0) { __sc_panic("divide by zero"); } (__sc15 % __sc16); });
  while (self->used[i] != 0U) {
    if (ast__ast__TyInstance__eq(&self->keys[i], key)) {
      return i;
    }
    (i = (i + 1ULL));
    if (i >= self->cap) {
      (i = 0ULL);
    }
  }
  return i;
}

static __attribute__((unused)) void Map__ast__ast__TyInstance__u32__Global__grow(Map__ast__ast__TyInstance__u32__Global *const self) {
  size_t newcap = (self->cap * 2ULL);
  if (newcap < 8ULL) {
    (newcap = 8ULL);
  }
  ast__ast__TyInstance *const oldkeys = self->keys;
  uint32_t *const oldvals = self->vals;
  uint8_t *const oldused = self->used;
  const size_t oldcap = self->cap;
  (self->keys = ((ast__ast__TyInstance *)Global__alloc(&self->alloc, (newcap * sizeof(ast__ast__TyInstance)), _Alignof(ast__ast__TyInstance))));
  (self->vals = ((uint32_t *)Global__alloc(&self->alloc, (newcap * sizeof(uint32_t)), _Alignof(uint32_t))));
  (self->used = ((uint8_t *)Global__alloc(&self->alloc, newcap, 1ULL)));
  memset(((void *)self->used), 0, newcap);
  (self->cap = newcap);
  (self->len = 0ULL);
  for (size_t i = 0ULL; i < oldcap; i++) {
    if (oldused[i] == 1U) {
      const size_t j = Map__ast__ast__TyInstance__u32__Global__slot(self, (&oldkeys[i]));
      (self->keys[j] = oldkeys[i]);
      (self->vals[j] = oldvals[i]);
      (self->used[j] = 1U);
      (self->len = (self->len + 1ULL));
    }
  }
  if (oldcap > 0ULL) {
    Global__dealloc(&self->alloc, ((void *)oldkeys), (oldcap * sizeof(ast__ast__TyInstance)), _Alignof(ast__ast__TyInstance));
    Global__dealloc(&self->alloc, ((void *)oldvals), (oldcap * sizeof(uint32_t)), _Alignof(uint32_t));
    Global__dealloc(&self->alloc, ((void *)oldused), oldcap, 1ULL);
  }
}

void Map__ast__ast__TyInstance__u32__Global__insert(Map__ast__ast__TyInstance__u32__Global *const self, ast__ast__TyInstance const key, uint32_t const value) {
  if ((self->cap == 0ULL) || (((self->len + 1ULL) * 4ULL) >= (self->cap * 3ULL))) {
    Map__ast__ast__TyInstance__u32__Global__grow(self);
  }
  const size_t i = Map__ast__ast__TyInstance__u32__Global__slot(self, (&key));
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

Option__ptr_u32 Map__ast__ast__TyInstance__u32__Global__get(const Map__ast__ast__TyInstance__u32__Global *const self, const ast__ast__TyInstance *const key) {
  if (self->cap == 0ULL) {
    return (Option__ptr_u32){ .tag = Option_None };
  }
  const size_t i = Map__ast__ast__TyInstance__u32__Global__slot(self, key);
  if (self->used[i] == 0U) {
    return (Option__ptr_u32){ .tag = Option_None };
  }
  return (Option__ptr_u32){ .tag = Option_Some, .payload.Some = { (&self->vals[i]) } };
}

bool Map__ast__ast__TyInstance__u32__Global__contains_key(const Map__ast__ast__TyInstance__u32__Global *const self, const ast__ast__TyInstance *const key) {
  return ({ __auto_type __sc17 = Map__ast__ast__TyInstance__u32__Global__get(self, key); Option__ptr_u32__is_some(&__sc17); });
}

Option__u32 Map__ast__ast__TyInstance__u32__Global__remove(Map__ast__ast__TyInstance__u32__Global *const self, const ast__ast__TyInstance *const key) {
  if (self->cap == 0ULL) {
    return (Option__u32){ .tag = Option_None };
  }
  const size_t i = Map__ast__ast__TyInstance__u32__Global__slot(self, key);
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
    Map__ast__ast__TyInstance__u32__Global__insert(self, k, v);
    (j = (j + 1ULL));
    if (j >= self->cap) {
      (j = 0ULL);
    }
  }
  return (Option__u32){ .tag = Option_Some, .payload.Some = { removed } };
}

Map__ast__ast__TyInstance__u32__Global Map__ast__ast__TyInstance__u32__Global__new(void) {
  return Map__ast__ast__TyInstance__u32__Global__new_in(Global__default_());
}

void Map__ast__ast__TyInstance__u32__Global__free(Map__ast__ast__TyInstance__u32__Global *const self) {
  for (size_t i = 0ULL; i < self->cap; i++) {
    if (self->used[i] != 0U) {
      (void)(self->keys[i]);
      (void)(self->vals[i]);
    }
  }
  Global__dealloc(&self->alloc, ((void *)self->keys), (self->cap * sizeof(ast__ast__TyInstance)), _Alignof(ast__ast__TyInstance));
  Global__dealloc(&self->alloc, ((void *)self->vals), (self->cap * sizeof(uint32_t)), _Alignof(uint32_t));
  Global__dealloc(&self->alloc, ((void *)self->used), self->cap, 1ULL);
  (self->keys = NULL);
  (self->vals = NULL);
  (self->used = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

MapKeys__ast__ast__TyInstance Map__ast__ast__TyInstance__u32__Global__keys(const Map__ast__ast__TyInstance__u32__Global *const self) {
  return (MapKeys__ast__ast__TyInstance){ .keys = ((const ast__ast__TyInstance *)self->keys), .used = ((const uint8_t *)self->used), .idx = 0ULL, .cap = self->cap };
}

Map__ast__ast__MethodInst__u32__Global Map__ast__ast__MethodInst__u32__Global__new_in(Global const alloc) {
  return (Map__ast__ast__MethodInst__u32__Global){ .keys = NULL, .vals = NULL, .used = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

size_t Map__ast__ast__MethodInst__u32__Global__len(const Map__ast__ast__MethodInst__u32__Global *const self) {
  return self->len;
}

bool Map__ast__ast__MethodInst__u32__Global__is_empty(const Map__ast__ast__MethodInst__u32__Global *const self) {
  return (self->len == 0ULL);
}

static __attribute__((unused)) size_t Map__ast__ast__MethodInst__u32__Global__slot(const Map__ast__ast__MethodInst__u32__Global *const self, const ast__ast__MethodInst *const key) {
  size_t i = ({ size_t __sc18 = ((size_t)ast__ast__MethodInst__hash(key)); size_t __sc19 = self->cap; if (__sc19 == 0) { __sc_panic("divide by zero"); } (__sc18 % __sc19); });
  while (self->used[i] != 0U) {
    if (ast__ast__MethodInst__eq(&self->keys[i], key)) {
      return i;
    }
    (i = (i + 1ULL));
    if (i >= self->cap) {
      (i = 0ULL);
    }
  }
  return i;
}

static __attribute__((unused)) void Map__ast__ast__MethodInst__u32__Global__grow(Map__ast__ast__MethodInst__u32__Global *const self) {
  size_t newcap = (self->cap * 2ULL);
  if (newcap < 8ULL) {
    (newcap = 8ULL);
  }
  ast__ast__MethodInst *const oldkeys = self->keys;
  uint32_t *const oldvals = self->vals;
  uint8_t *const oldused = self->used;
  const size_t oldcap = self->cap;
  (self->keys = ((ast__ast__MethodInst *)Global__alloc(&self->alloc, (newcap * sizeof(ast__ast__MethodInst)), _Alignof(ast__ast__MethodInst))));
  (self->vals = ((uint32_t *)Global__alloc(&self->alloc, (newcap * sizeof(uint32_t)), _Alignof(uint32_t))));
  (self->used = ((uint8_t *)Global__alloc(&self->alloc, newcap, 1ULL)));
  memset(((void *)self->used), 0, newcap);
  (self->cap = newcap);
  (self->len = 0ULL);
  for (size_t i = 0ULL; i < oldcap; i++) {
    if (oldused[i] == 1U) {
      const size_t j = Map__ast__ast__MethodInst__u32__Global__slot(self, (&oldkeys[i]));
      (self->keys[j] = oldkeys[i]);
      (self->vals[j] = oldvals[i]);
      (self->used[j] = 1U);
      (self->len = (self->len + 1ULL));
    }
  }
  if (oldcap > 0ULL) {
    Global__dealloc(&self->alloc, ((void *)oldkeys), (oldcap * sizeof(ast__ast__MethodInst)), _Alignof(ast__ast__MethodInst));
    Global__dealloc(&self->alloc, ((void *)oldvals), (oldcap * sizeof(uint32_t)), _Alignof(uint32_t));
    Global__dealloc(&self->alloc, ((void *)oldused), oldcap, 1ULL);
  }
}

void Map__ast__ast__MethodInst__u32__Global__insert(Map__ast__ast__MethodInst__u32__Global *const self, ast__ast__MethodInst const key, uint32_t const value) {
  if ((self->cap == 0ULL) || (((self->len + 1ULL) * 4ULL) >= (self->cap * 3ULL))) {
    Map__ast__ast__MethodInst__u32__Global__grow(self);
  }
  const size_t i = Map__ast__ast__MethodInst__u32__Global__slot(self, (&key));
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

Option__ptr_u32 Map__ast__ast__MethodInst__u32__Global__get(const Map__ast__ast__MethodInst__u32__Global *const self, const ast__ast__MethodInst *const key) {
  if (self->cap == 0ULL) {
    return (Option__ptr_u32){ .tag = Option_None };
  }
  const size_t i = Map__ast__ast__MethodInst__u32__Global__slot(self, key);
  if (self->used[i] == 0U) {
    return (Option__ptr_u32){ .tag = Option_None };
  }
  return (Option__ptr_u32){ .tag = Option_Some, .payload.Some = { (&self->vals[i]) } };
}

bool Map__ast__ast__MethodInst__u32__Global__contains_key(const Map__ast__ast__MethodInst__u32__Global *const self, const ast__ast__MethodInst *const key) {
  return ({ __auto_type __sc20 = Map__ast__ast__MethodInst__u32__Global__get(self, key); Option__ptr_u32__is_some(&__sc20); });
}

Option__u32 Map__ast__ast__MethodInst__u32__Global__remove(Map__ast__ast__MethodInst__u32__Global *const self, const ast__ast__MethodInst *const key) {
  if (self->cap == 0ULL) {
    return (Option__u32){ .tag = Option_None };
  }
  const size_t i = Map__ast__ast__MethodInst__u32__Global__slot(self, key);
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
    Map__ast__ast__MethodInst__u32__Global__insert(self, k, v);
    (j = (j + 1ULL));
    if (j >= self->cap) {
      (j = 0ULL);
    }
  }
  return (Option__u32){ .tag = Option_Some, .payload.Some = { removed } };
}

Map__ast__ast__MethodInst__u32__Global Map__ast__ast__MethodInst__u32__Global__new(void) {
  return Map__ast__ast__MethodInst__u32__Global__new_in(Global__default_());
}

void Map__ast__ast__MethodInst__u32__Global__free(Map__ast__ast__MethodInst__u32__Global *const self) {
  for (size_t i = 0ULL; i < self->cap; i++) {
    if (self->used[i] != 0U) {
      (void)(self->keys[i]);
      (void)(self->vals[i]);
    }
  }
  Global__dealloc(&self->alloc, ((void *)self->keys), (self->cap * sizeof(ast__ast__MethodInst)), _Alignof(ast__ast__MethodInst));
  Global__dealloc(&self->alloc, ((void *)self->vals), (self->cap * sizeof(uint32_t)), _Alignof(uint32_t));
  Global__dealloc(&self->alloc, ((void *)self->used), self->cap, 1ULL);
  (self->keys = NULL);
  (self->vals = NULL);
  (self->used = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

MapKeys__ast__ast__MethodInst Map__ast__ast__MethodInst__u32__Global__keys(const Map__ast__ast__MethodInst__u32__Global *const self) {
  return (MapKeys__ast__ast__MethodInst){ .keys = ((const ast__ast__MethodInst *)self->keys), .used = ((const uint8_t *)self->used), .idx = 0ULL, .cap = self->cap };
}

Vector__ast__ast__DynUse__Global Vector__ast__ast__DynUse__Global__new_in(Global const alloc) {
  return (Vector__ast__ast__DynUse__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__ast__ast__DynUse__Global Vector__ast__ast__DynUse__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__ast__ast__DynUse__Global v = (Vector__ast__ast__DynUse__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((ast__ast__DynUse *)Global__alloc(&v.alloc, (cap * sizeof(ast__ast__DynUse)), _Alignof(ast__ast__DynUse))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__ast__ast__DynUse__Global__len(const Vector__ast__ast__DynUse__Global *const self) {
  return self->len;
}

void Vector__ast__ast__DynUse__Global__reserve(Vector__ast__ast__DynUse__Global *const self, size_t const additional) {
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
  ast__ast__DynUse *const p = ((ast__ast__DynUse *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__DynUse)), (new_cap * sizeof(ast__ast__DynUse)), _Alignof(ast__ast__DynUse)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__ast__ast__DynUse__Global__push(Vector__ast__ast__DynUse__Global *const self, ast__ast__DynUse const value) {
  Vector__ast__ast__DynUse__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const ast__ast__DynUse *Vector__ast__ast__DynUse__Global__at(const Vector__ast__ast__DynUse__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_ast__ast__DynUse Vector__ast__ast__DynUse__Global__get(const Vector__ast__ast__DynUse__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_ast__ast__DynUse){ .tag = Option_None };
  }
  return (Option__ptr_ast__ast__DynUse){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__ast__ast__DynUse__Global__set(Vector__ast__ast__DynUse__Global *const self, size_t const index, ast__ast__DynUse const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__ast__ast__DynUse__Global__clear(Vector__ast__ast__DynUse__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__ast__ast__DynUse__Global__truncate(Vector__ast__ast__DynUse__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const ast__ast__DynUse *Vector__ast__ast__DynUse__Global__as_ptr(const Vector__ast__ast__DynUse__Global *const self) {
  return self->ptr;
}

void Vector__ast__ast__DynUse__Global__swap(Vector__ast__ast__DynUse__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__ast__ast__DynUse__Global Vector__ast__ast__DynUse__Global__new(void) {
  return Vector__ast__ast__DynUse__Global__new_in(Global__default_());
}

void Vector__ast__ast__DynUse__Global__free(Vector__ast__ast__DynUse__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__DynUse)), _Alignof(ast__ast__DynUse));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__ast__ast__DynUse__Global Vector__ast__ast__DynUse__Global__default_(void) {
  return Vector__ast__ast__DynUse__Global__new();
}

const ast__ast__DynUse *Vector__ast__ast__DynUse__Global__index(const Vector__ast__ast__DynUse__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__DynUse Vector__ast__ast__DynUse__Global__index_range(const Vector__ast__ast__DynUse__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc21;
    if (r.inclusive) {
      __sc21 = (r.end + 1ULL);
    } else {
      __sc21 = r.end;
    }
    __sc21;
  });
  return (Slice__ast__ast__DynUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__DynUse *Vector__ast__ast__DynUse__Global__index_mut(Vector__ast__ast__DynUse__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__DynUse Vector__ast__ast__DynUse__Global__index_range_mut(Vector__ast__ast__DynUse__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc22;
    if (r.inclusive) {
      __sc22 = (r.end + 1ULL);
    } else {
      __sc22 = r.end;
    }
    __sc22;
  });
  return (SliceMut__ast__ast__DynUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__ast__ast__DerefUse__Global Vector__ast__ast__DerefUse__Global__new_in(Global const alloc) {
  return (Vector__ast__ast__DerefUse__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__ast__ast__DerefUse__Global Vector__ast__ast__DerefUse__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__ast__ast__DerefUse__Global v = (Vector__ast__ast__DerefUse__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((ast__ast__DerefUse *)Global__alloc(&v.alloc, (cap * sizeof(ast__ast__DerefUse)), _Alignof(ast__ast__DerefUse))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__ast__ast__DerefUse__Global__len(const Vector__ast__ast__DerefUse__Global *const self) {
  return self->len;
}

void Vector__ast__ast__DerefUse__Global__reserve(Vector__ast__ast__DerefUse__Global *const self, size_t const additional) {
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
  ast__ast__DerefUse *const p = ((ast__ast__DerefUse *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__DerefUse)), (new_cap * sizeof(ast__ast__DerefUse)), _Alignof(ast__ast__DerefUse)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__ast__ast__DerefUse__Global__push(Vector__ast__ast__DerefUse__Global *const self, ast__ast__DerefUse const value) {
  Vector__ast__ast__DerefUse__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const ast__ast__DerefUse *Vector__ast__ast__DerefUse__Global__at(const Vector__ast__ast__DerefUse__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_ast__ast__DerefUse Vector__ast__ast__DerefUse__Global__get(const Vector__ast__ast__DerefUse__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_ast__ast__DerefUse){ .tag = Option_None };
  }
  return (Option__ptr_ast__ast__DerefUse){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__ast__ast__DerefUse__Global__set(Vector__ast__ast__DerefUse__Global *const self, size_t const index, ast__ast__DerefUse const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__ast__ast__DerefUse__Global__clear(Vector__ast__ast__DerefUse__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__ast__ast__DerefUse__Global__truncate(Vector__ast__ast__DerefUse__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const ast__ast__DerefUse *Vector__ast__ast__DerefUse__Global__as_ptr(const Vector__ast__ast__DerefUse__Global *const self) {
  return self->ptr;
}

void Vector__ast__ast__DerefUse__Global__swap(Vector__ast__ast__DerefUse__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__ast__ast__DerefUse__Global Vector__ast__ast__DerefUse__Global__new(void) {
  return Vector__ast__ast__DerefUse__Global__new_in(Global__default_());
}

void Vector__ast__ast__DerefUse__Global__free(Vector__ast__ast__DerefUse__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__DerefUse)), _Alignof(ast__ast__DerefUse));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__ast__ast__DerefUse__Global Vector__ast__ast__DerefUse__Global__default_(void) {
  return Vector__ast__ast__DerefUse__Global__new();
}

const ast__ast__DerefUse *Vector__ast__ast__DerefUse__Global__index(const Vector__ast__ast__DerefUse__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__DerefUse Vector__ast__ast__DerefUse__Global__index_range(const Vector__ast__ast__DerefUse__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc23;
    if (r.inclusive) {
      __sc23 = (r.end + 1ULL);
    } else {
      __sc23 = r.end;
    }
    __sc23;
  });
  return (Slice__ast__ast__DerefUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__DerefUse *Vector__ast__ast__DerefUse__Global__index_mut(Vector__ast__ast__DerefUse__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__DerefUse Vector__ast__ast__DerefUse__Global__index_range_mut(Vector__ast__ast__DerefUse__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc24;
    if (r.inclusive) {
      __sc24 = (r.end + 1ULL);
    } else {
      __sc24 = r.end;
    }
    __sc24;
  });
  return (SliceMut__ast__ast__DerefUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__ast__ast__Attr__Global Vector__ast__ast__Attr__Global__new_in(Global const alloc) {
  return (Vector__ast__ast__Attr__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__ast__ast__Attr__Global Vector__ast__ast__Attr__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__ast__ast__Attr__Global v = (Vector__ast__ast__Attr__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((ast__ast__Attr *)Global__alloc(&v.alloc, (cap * sizeof(ast__ast__Attr)), _Alignof(ast__ast__Attr))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__ast__ast__Attr__Global__len(const Vector__ast__ast__Attr__Global *const self) {
  return self->len;
}

void Vector__ast__ast__Attr__Global__reserve(Vector__ast__ast__Attr__Global *const self, size_t const additional) {
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
  ast__ast__Attr *const p = ((ast__ast__Attr *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__Attr)), (new_cap * sizeof(ast__ast__Attr)), _Alignof(ast__ast__Attr)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__ast__ast__Attr__Global__push(Vector__ast__ast__Attr__Global *const self, ast__ast__Attr const value) {
  Vector__ast__ast__Attr__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const ast__ast__Attr *Vector__ast__ast__Attr__Global__at(const Vector__ast__ast__Attr__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_ast__ast__Attr Vector__ast__ast__Attr__Global__get(const Vector__ast__ast__Attr__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_ast__ast__Attr){ .tag = Option_None };
  }
  return (Option__ptr_ast__ast__Attr){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__ast__ast__Attr__Global__set(Vector__ast__ast__Attr__Global *const self, size_t const index, ast__ast__Attr const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__ast__ast__Attr__Global__clear(Vector__ast__ast__Attr__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__ast__ast__Attr__Global__truncate(Vector__ast__ast__Attr__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const ast__ast__Attr *Vector__ast__ast__Attr__Global__as_ptr(const Vector__ast__ast__Attr__Global *const self) {
  return self->ptr;
}

void Vector__ast__ast__Attr__Global__swap(Vector__ast__ast__Attr__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__ast__ast__Attr__Global Vector__ast__ast__Attr__Global__new(void) {
  return Vector__ast__ast__Attr__Global__new_in(Global__default_());
}

void Vector__ast__ast__Attr__Global__free(Vector__ast__ast__Attr__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(ast__ast__Attr)), _Alignof(ast__ast__Attr));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__ast__ast__Attr__Global Vector__ast__ast__Attr__Global__default_(void) {
  return Vector__ast__ast__Attr__Global__new();
}

const ast__ast__Attr *Vector__ast__ast__Attr__Global__index(const Vector__ast__ast__Attr__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__Attr Vector__ast__ast__Attr__Global__index_range(const Vector__ast__ast__Attr__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc25;
    if (r.inclusive) {
      __sc25 = (r.end + 1ULL);
    } else {
      __sc25 = r.end;
    }
    __sc25;
  });
  return (Slice__ast__ast__Attr){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__Attr *Vector__ast__ast__Attr__Global__index_mut(Vector__ast__ast__Attr__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__Attr Vector__ast__ast__Attr__Global__index_range_mut(Vector__ast__ast__Attr__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc26;
    if (r.inclusive) {
      __sc26 = (r.end + 1ULL);
    } else {
      __sc26 = r.end;
    }
    __sc26;
  });
  return (SliceMut__ast__ast__Attr){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__ast__ast__Node Option__ast__ast__Node__some(ast__ast__Node const value) {
  return (Option__ast__ast__Node){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ast__ast__Node Option__ast__ast__Node__none(void) {
  return (Option__ast__ast__Node){ .tag = Option_None };
}

bool Option__ast__ast__Node__is_some(const Option__ast__ast__Node *const self) {
  {
    const Option__ast__ast__Node *const __sc27 = self;
    if ((*__sc27).tag == Option_Some) {
      return true;
    }
    else if ((*__sc27).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ast__ast__Node__is_none(const Option__ast__ast__Node *const self) {
  {
    const Option__ast__ast__Node *const __sc28 = self;
    if ((*__sc28).tag == Option_Some) {
      return false;
    }
    else if ((*__sc28).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ast__ast__Node Option__ast__ast__Node__default_(void) {
  return Option__ast__ast__Node__none();
}

Option__ptr_ast__ast__Node Option__ptr_ast__ast__Node__some(const ast__ast__Node *const value) {
  return (Option__ptr_ast__ast__Node){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_ast__ast__Node Option__ptr_ast__ast__Node__none(void) {
  return (Option__ptr_ast__ast__Node){ .tag = Option_None };
}

bool Option__ptr_ast__ast__Node__is_some(const Option__ptr_ast__ast__Node *const self) {
  {
    const Option__ptr_ast__ast__Node *const __sc29 = self;
    if ((*__sc29).tag == Option_Some) {
      return true;
    }
    else if ((*__sc29).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_ast__ast__Node__is_none(const Option__ptr_ast__ast__Node *const self) {
  {
    const Option__ptr_ast__ast__Node *const __sc30 = self;
    if ((*__sc30).tag == Option_Some) {
      return false;
    }
    else if ((*__sc30).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_ast__ast__Node Option__ptr_ast__ast__Node__default_(void) {
  return Option__ptr_ast__ast__Node__none();
}

Option__ptr_ast__ast__Node VecIter__ast__ast__Node__next(VecIter__ast__ast__Node *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_ast__ast__Node__none();
  }
  const ast__ast__Node *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_ast__ast__Node__some(r);
}

size_t Slice__ast__ast__Node__len(const Slice__ast__ast__Node *const self) {
  return self->len;
}

const ast__ast__Node *Slice__ast__ast__Node__as_ptr(const Slice__ast__ast__Node *const self) {
  return self->ptr;
}

const ast__ast__Node *Slice__ast__ast__Node__index(const Slice__ast__ast__Node *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__Node Slice__ast__ast__Node__index_range(const Slice__ast__ast__Node *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc31;
    if (r.inclusive) {
      __sc31 = (r.end + 1ULL);
    } else {
      __sc31 = r.end;
    }
    __sc31;
  });
  return (Slice__ast__ast__Node){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__ast__ast__Node__len(const SliceMut__ast__ast__Node *const self) {
  return self->len;
}

ast__ast__Node *SliceMut__ast__ast__Node__as_mut_ptr(const SliceMut__ast__ast__Node *const self) {
  return self->ptr;
}

const ast__ast__Node *SliceMut__ast__ast__Node__index(const SliceMut__ast__ast__Node *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__Node SliceMut__ast__ast__Node__index_range(const SliceMut__ast__ast__Node *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc32;
    if (r.inclusive) {
      __sc32 = (r.end + 1ULL);
    } else {
      __sc32 = r.end;
    }
    __sc32;
  });
  return (Slice__ast__ast__Node){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__Node *SliceMut__ast__ast__Node__index_mut(SliceMut__ast__ast__Node *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__Node SliceMut__ast__ast__Node__index_range_mut(SliceMut__ast__ast__Node *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc33;
    if (r.inclusive) {
      __sc33 = (r.end + 1ULL);
    } else {
      __sc33 = r.end;
    }
    __sc33;
  });
  return (SliceMut__ast__ast__Node){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__ast__ast__DefId Option__ast__ast__DefId__some(ast__ast__DefId const value) {
  return (Option__ast__ast__DefId){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ast__ast__DefId Option__ast__ast__DefId__none(void) {
  return (Option__ast__ast__DefId){ .tag = Option_None };
}

bool Option__ast__ast__DefId__is_some(const Option__ast__ast__DefId *const self) {
  {
    const Option__ast__ast__DefId *const __sc34 = self;
    if ((*__sc34).tag == Option_Some) {
      return true;
    }
    else if ((*__sc34).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ast__ast__DefId__is_none(const Option__ast__ast__DefId *const self) {
  {
    const Option__ast__ast__DefId *const __sc35 = self;
    if ((*__sc35).tag == Option_Some) {
      return false;
    }
    else if ((*__sc35).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ast__ast__DefId Option__ast__ast__DefId__default_(void) {
  return Option__ast__ast__DefId__none();
}

Option__ptr_ast__ast__DefId Option__ptr_ast__ast__DefId__some(const ast__ast__DefId *const value) {
  return (Option__ptr_ast__ast__DefId){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_ast__ast__DefId Option__ptr_ast__ast__DefId__none(void) {
  return (Option__ptr_ast__ast__DefId){ .tag = Option_None };
}

bool Option__ptr_ast__ast__DefId__is_some(const Option__ptr_ast__ast__DefId *const self) {
  {
    const Option__ptr_ast__ast__DefId *const __sc36 = self;
    if ((*__sc36).tag == Option_Some) {
      return true;
    }
    else if ((*__sc36).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_ast__ast__DefId__is_none(const Option__ptr_ast__ast__DefId *const self) {
  {
    const Option__ptr_ast__ast__DefId *const __sc37 = self;
    if ((*__sc37).tag == Option_Some) {
      return false;
    }
    else if ((*__sc37).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_ast__ast__DefId Option__ptr_ast__ast__DefId__default_(void) {
  return Option__ptr_ast__ast__DefId__none();
}

Option__ptr_ast__ast__DefId VecIter__ast__ast__DefId__next(VecIter__ast__ast__DefId *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_ast__ast__DefId__none();
  }
  const ast__ast__DefId *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_ast__ast__DefId__some(r);
}

size_t Slice__ast__ast__DefId__len(const Slice__ast__ast__DefId *const self) {
  return self->len;
}

const ast__ast__DefId *Slice__ast__ast__DefId__as_ptr(const Slice__ast__ast__DefId *const self) {
  return self->ptr;
}

const ast__ast__DefId *Slice__ast__ast__DefId__index(const Slice__ast__ast__DefId *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__DefId Slice__ast__ast__DefId__index_range(const Slice__ast__ast__DefId *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc38;
    if (r.inclusive) {
      __sc38 = (r.end + 1ULL);
    } else {
      __sc38 = r.end;
    }
    __sc38;
  });
  return (Slice__ast__ast__DefId){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__ast__ast__DefId__len(const SliceMut__ast__ast__DefId *const self) {
  return self->len;
}

ast__ast__DefId *SliceMut__ast__ast__DefId__as_mut_ptr(const SliceMut__ast__ast__DefId *const self) {
  return self->ptr;
}

const ast__ast__DefId *SliceMut__ast__ast__DefId__index(const SliceMut__ast__ast__DefId *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__DefId SliceMut__ast__ast__DefId__index_range(const SliceMut__ast__ast__DefId *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc39;
    if (r.inclusive) {
      __sc39 = (r.end + 1ULL);
    } else {
      __sc39 = r.end;
    }
    __sc39;
  });
  return (Slice__ast__ast__DefId){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__DefId *SliceMut__ast__ast__DefId__index_mut(SliceMut__ast__ast__DefId *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__DefId SliceMut__ast__ast__DefId__index_range_mut(SliceMut__ast__ast__DefId *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc40;
    if (r.inclusive) {
      __sc40 = (r.end + 1ULL);
    } else {
      __sc40 = r.end;
    }
    __sc40;
  });
  return (SliceMut__ast__ast__DefId){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__ast__ast__Ty Option__ast__ast__Ty__some(ast__ast__Ty const value) {
  return (Option__ast__ast__Ty){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ast__ast__Ty Option__ast__ast__Ty__none(void) {
  return (Option__ast__ast__Ty){ .tag = Option_None };
}

bool Option__ast__ast__Ty__is_some(const Option__ast__ast__Ty *const self) {
  {
    const Option__ast__ast__Ty *const __sc41 = self;
    if ((*__sc41).tag == Option_Some) {
      return true;
    }
    else if ((*__sc41).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ast__ast__Ty__is_none(const Option__ast__ast__Ty *const self) {
  {
    const Option__ast__ast__Ty *const __sc42 = self;
    if ((*__sc42).tag == Option_Some) {
      return false;
    }
    else if ((*__sc42).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ast__ast__Ty Option__ast__ast__Ty__default_(void) {
  return Option__ast__ast__Ty__none();
}

bool Option__ast__ast__Ty__eq(const Option__ast__ast__Ty *const self, const Option__ast__ast__Ty *const other) {
  {
    const Option__ast__ast__Ty *const __sc43 = self;
    if ((*__sc43).tag == Option_Some) {
      const __auto_type a = &((*__sc43).payload.Some._0);
      return ({
        bool __sc44;
        const Option__ast__ast__Ty *const __sc45 = other;
        if ((*__sc45).tag == Option_Some) {
          const __auto_type b = &((*__sc45).payload.Some._0);
          __sc44 = ast__ast__Ty__eq(a, b);
        }
        else if ((*__sc45).tag == Option_None) {
          __sc44 = false;
        }
        else { __builtin_unreachable(); }
        __sc44;
      });
    }
    else if ((*__sc43).tag == Option_None) {
      return Option__ast__ast__Ty__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__ast__ast__Ty__hash(const Option__ast__ast__Ty *const self) {
  {
    const Option__ast__ast__Ty *const __sc46 = self;
    if ((*__sc46).tag == Option_Some) {
      const __auto_type v = &((*__sc46).payload.Some._0);
      return ((ast__ast__Ty__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc46).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_ast__ast__Ty Option__ptr_ast__ast__Ty__some(const ast__ast__Ty *const value) {
  return (Option__ptr_ast__ast__Ty){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_ast__ast__Ty Option__ptr_ast__ast__Ty__none(void) {
  return (Option__ptr_ast__ast__Ty){ .tag = Option_None };
}

bool Option__ptr_ast__ast__Ty__is_some(const Option__ptr_ast__ast__Ty *const self) {
  {
    const Option__ptr_ast__ast__Ty *const __sc47 = self;
    if ((*__sc47).tag == Option_Some) {
      return true;
    }
    else if ((*__sc47).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_ast__ast__Ty__is_none(const Option__ptr_ast__ast__Ty *const self) {
  {
    const Option__ptr_ast__ast__Ty *const __sc48 = self;
    if ((*__sc48).tag == Option_Some) {
      return false;
    }
    else if ((*__sc48).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_ast__ast__Ty Option__ptr_ast__ast__Ty__default_(void) {
  return Option__ptr_ast__ast__Ty__none();
}

Option__ptr_ast__ast__Ty VecIter__ast__ast__Ty__next(VecIter__ast__ast__Ty *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_ast__ast__Ty__none();
  }
  const ast__ast__Ty *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_ast__ast__Ty__some(r);
}

size_t Slice__ast__ast__Ty__len(const Slice__ast__ast__Ty *const self) {
  return self->len;
}

const ast__ast__Ty *Slice__ast__ast__Ty__as_ptr(const Slice__ast__ast__Ty *const self) {
  return self->ptr;
}

const ast__ast__Ty *Slice__ast__ast__Ty__index(const Slice__ast__ast__Ty *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__Ty Slice__ast__ast__Ty__index_range(const Slice__ast__ast__Ty *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc49;
    if (r.inclusive) {
      __sc49 = (r.end + 1ULL);
    } else {
      __sc49 = r.end;
    }
    __sc49;
  });
  return (Slice__ast__ast__Ty){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__ast__ast__Ty__len(const SliceMut__ast__ast__Ty *const self) {
  return self->len;
}

ast__ast__Ty *SliceMut__ast__ast__Ty__as_mut_ptr(const SliceMut__ast__ast__Ty *const self) {
  return self->ptr;
}

const ast__ast__Ty *SliceMut__ast__ast__Ty__index(const SliceMut__ast__ast__Ty *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__Ty SliceMut__ast__ast__Ty__index_range(const SliceMut__ast__ast__Ty *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc50;
    if (r.inclusive) {
      __sc50 = (r.end + 1ULL);
    } else {
      __sc50 = r.end;
    }
    __sc50;
  });
  return (Slice__ast__ast__Ty){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__Ty *SliceMut__ast__ast__Ty__index_mut(SliceMut__ast__ast__Ty *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__Ty SliceMut__ast__ast__Ty__index_range_mut(SliceMut__ast__ast__Ty *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc51;
    if (r.inclusive) {
      __sc51 = (r.end + 1ULL);
    } else {
      __sc51 = r.end;
    }
    __sc51;
  });
  return (SliceMut__ast__ast__Ty){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__ptr_ast__ast__Ty MapKeys__ast__ast__Ty__next(MapKeys__ast__ast__Ty *const self) {
  while (self->idx < self->cap) {
    const size_t i = self->idx;
    (self->idx = (self->idx + 1ULL));
    if (self->used[i] != 0U) {
      return (Option__ptr_ast__ast__Ty){ .tag = Option_Some, .payload.Some = { (&self->keys[i]) } };
    }
  }
  return (Option__ptr_ast__ast__Ty){ .tag = Option_None };
}

Option__ast__ast__MonoUse Option__ast__ast__MonoUse__some(ast__ast__MonoUse const value) {
  return (Option__ast__ast__MonoUse){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ast__ast__MonoUse Option__ast__ast__MonoUse__none(void) {
  return (Option__ast__ast__MonoUse){ .tag = Option_None };
}

bool Option__ast__ast__MonoUse__is_some(const Option__ast__ast__MonoUse *const self) {
  {
    const Option__ast__ast__MonoUse *const __sc52 = self;
    if ((*__sc52).tag == Option_Some) {
      return true;
    }
    else if ((*__sc52).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ast__ast__MonoUse__is_none(const Option__ast__ast__MonoUse *const self) {
  {
    const Option__ast__ast__MonoUse *const __sc53 = self;
    if ((*__sc53).tag == Option_Some) {
      return false;
    }
    else if ((*__sc53).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ast__ast__MonoUse Option__ast__ast__MonoUse__default_(void) {
  return Option__ast__ast__MonoUse__none();
}

Option__ptr_ast__ast__MonoUse Option__ptr_ast__ast__MonoUse__some(const ast__ast__MonoUse *const value) {
  return (Option__ptr_ast__ast__MonoUse){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_ast__ast__MonoUse Option__ptr_ast__ast__MonoUse__none(void) {
  return (Option__ptr_ast__ast__MonoUse){ .tag = Option_None };
}

bool Option__ptr_ast__ast__MonoUse__is_some(const Option__ptr_ast__ast__MonoUse *const self) {
  {
    const Option__ptr_ast__ast__MonoUse *const __sc54 = self;
    if ((*__sc54).tag == Option_Some) {
      return true;
    }
    else if ((*__sc54).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_ast__ast__MonoUse__is_none(const Option__ptr_ast__ast__MonoUse *const self) {
  {
    const Option__ptr_ast__ast__MonoUse *const __sc55 = self;
    if ((*__sc55).tag == Option_Some) {
      return false;
    }
    else if ((*__sc55).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_ast__ast__MonoUse Option__ptr_ast__ast__MonoUse__default_(void) {
  return Option__ptr_ast__ast__MonoUse__none();
}

Option__ptr_ast__ast__MonoUse VecIter__ast__ast__MonoUse__next(VecIter__ast__ast__MonoUse *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_ast__ast__MonoUse__none();
  }
  const ast__ast__MonoUse *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_ast__ast__MonoUse__some(r);
}

size_t Slice__ast__ast__MonoUse__len(const Slice__ast__ast__MonoUse *const self) {
  return self->len;
}

const ast__ast__MonoUse *Slice__ast__ast__MonoUse__as_ptr(const Slice__ast__ast__MonoUse *const self) {
  return self->ptr;
}

const ast__ast__MonoUse *Slice__ast__ast__MonoUse__index(const Slice__ast__ast__MonoUse *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__MonoUse Slice__ast__ast__MonoUse__index_range(const Slice__ast__ast__MonoUse *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc56;
    if (r.inclusive) {
      __sc56 = (r.end + 1ULL);
    } else {
      __sc56 = r.end;
    }
    __sc56;
  });
  return (Slice__ast__ast__MonoUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__ast__ast__MonoUse__len(const SliceMut__ast__ast__MonoUse *const self) {
  return self->len;
}

ast__ast__MonoUse *SliceMut__ast__ast__MonoUse__as_mut_ptr(const SliceMut__ast__ast__MonoUse *const self) {
  return self->ptr;
}

const ast__ast__MonoUse *SliceMut__ast__ast__MonoUse__index(const SliceMut__ast__ast__MonoUse *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__MonoUse SliceMut__ast__ast__MonoUse__index_range(const SliceMut__ast__ast__MonoUse *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc57;
    if (r.inclusive) {
      __sc57 = (r.end + 1ULL);
    } else {
      __sc57 = r.end;
    }
    __sc57;
  });
  return (Slice__ast__ast__MonoUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__MonoUse *SliceMut__ast__ast__MonoUse__index_mut(SliceMut__ast__ast__MonoUse *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__MonoUse SliceMut__ast__ast__MonoUse__index_range_mut(SliceMut__ast__ast__MonoUse *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc58;
    if (r.inclusive) {
      __sc58 = (r.end + 1ULL);
    } else {
      __sc58 = r.end;
    }
    __sc58;
  });
  return (SliceMut__ast__ast__MonoUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__ast__ast__TyInstance Option__ast__ast__TyInstance__some(ast__ast__TyInstance const value) {
  return (Option__ast__ast__TyInstance){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ast__ast__TyInstance Option__ast__ast__TyInstance__none(void) {
  return (Option__ast__ast__TyInstance){ .tag = Option_None };
}

bool Option__ast__ast__TyInstance__is_some(const Option__ast__ast__TyInstance *const self) {
  {
    const Option__ast__ast__TyInstance *const __sc59 = self;
    if ((*__sc59).tag == Option_Some) {
      return true;
    }
    else if ((*__sc59).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ast__ast__TyInstance__is_none(const Option__ast__ast__TyInstance *const self) {
  {
    const Option__ast__ast__TyInstance *const __sc60 = self;
    if ((*__sc60).tag == Option_Some) {
      return false;
    }
    else if ((*__sc60).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ast__ast__TyInstance Option__ast__ast__TyInstance__default_(void) {
  return Option__ast__ast__TyInstance__none();
}

bool Option__ast__ast__TyInstance__eq(const Option__ast__ast__TyInstance *const self, const Option__ast__ast__TyInstance *const other) {
  {
    const Option__ast__ast__TyInstance *const __sc61 = self;
    if ((*__sc61).tag == Option_Some) {
      const __auto_type a = &((*__sc61).payload.Some._0);
      return ({
        bool __sc62;
        const Option__ast__ast__TyInstance *const __sc63 = other;
        if ((*__sc63).tag == Option_Some) {
          const __auto_type b = &((*__sc63).payload.Some._0);
          __sc62 = ast__ast__TyInstance__eq(a, b);
        }
        else if ((*__sc63).tag == Option_None) {
          __sc62 = false;
        }
        else { __builtin_unreachable(); }
        __sc62;
      });
    }
    else if ((*__sc61).tag == Option_None) {
      return Option__ast__ast__TyInstance__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__ast__ast__TyInstance__hash(const Option__ast__ast__TyInstance *const self) {
  {
    const Option__ast__ast__TyInstance *const __sc64 = self;
    if ((*__sc64).tag == Option_Some) {
      const __auto_type v = &((*__sc64).payload.Some._0);
      return ((ast__ast__TyInstance__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc64).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_ast__ast__TyInstance Option__ptr_ast__ast__TyInstance__some(const ast__ast__TyInstance *const value) {
  return (Option__ptr_ast__ast__TyInstance){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_ast__ast__TyInstance Option__ptr_ast__ast__TyInstance__none(void) {
  return (Option__ptr_ast__ast__TyInstance){ .tag = Option_None };
}

bool Option__ptr_ast__ast__TyInstance__is_some(const Option__ptr_ast__ast__TyInstance *const self) {
  {
    const Option__ptr_ast__ast__TyInstance *const __sc65 = self;
    if ((*__sc65).tag == Option_Some) {
      return true;
    }
    else if ((*__sc65).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_ast__ast__TyInstance__is_none(const Option__ptr_ast__ast__TyInstance *const self) {
  {
    const Option__ptr_ast__ast__TyInstance *const __sc66 = self;
    if ((*__sc66).tag == Option_Some) {
      return false;
    }
    else if ((*__sc66).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_ast__ast__TyInstance Option__ptr_ast__ast__TyInstance__default_(void) {
  return Option__ptr_ast__ast__TyInstance__none();
}

Option__ptr_ast__ast__TyInstance VecIter__ast__ast__TyInstance__next(VecIter__ast__ast__TyInstance *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_ast__ast__TyInstance__none();
  }
  const ast__ast__TyInstance *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_ast__ast__TyInstance__some(r);
}

size_t Slice__ast__ast__TyInstance__len(const Slice__ast__ast__TyInstance *const self) {
  return self->len;
}

const ast__ast__TyInstance *Slice__ast__ast__TyInstance__as_ptr(const Slice__ast__ast__TyInstance *const self) {
  return self->ptr;
}

const ast__ast__TyInstance *Slice__ast__ast__TyInstance__index(const Slice__ast__ast__TyInstance *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__TyInstance Slice__ast__ast__TyInstance__index_range(const Slice__ast__ast__TyInstance *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc67;
    if (r.inclusive) {
      __sc67 = (r.end + 1ULL);
    } else {
      __sc67 = r.end;
    }
    __sc67;
  });
  return (Slice__ast__ast__TyInstance){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__ast__ast__TyInstance__len(const SliceMut__ast__ast__TyInstance *const self) {
  return self->len;
}

ast__ast__TyInstance *SliceMut__ast__ast__TyInstance__as_mut_ptr(const SliceMut__ast__ast__TyInstance *const self) {
  return self->ptr;
}

const ast__ast__TyInstance *SliceMut__ast__ast__TyInstance__index(const SliceMut__ast__ast__TyInstance *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__TyInstance SliceMut__ast__ast__TyInstance__index_range(const SliceMut__ast__ast__TyInstance *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc68;
    if (r.inclusive) {
      __sc68 = (r.end + 1ULL);
    } else {
      __sc68 = r.end;
    }
    __sc68;
  });
  return (Slice__ast__ast__TyInstance){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__TyInstance *SliceMut__ast__ast__TyInstance__index_mut(SliceMut__ast__ast__TyInstance *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__TyInstance SliceMut__ast__ast__TyInstance__index_range_mut(SliceMut__ast__ast__TyInstance *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc69;
    if (r.inclusive) {
      __sc69 = (r.end + 1ULL);
    } else {
      __sc69 = r.end;
    }
    __sc69;
  });
  return (SliceMut__ast__ast__TyInstance){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__ast__ast__MethodInst Option__ast__ast__MethodInst__some(ast__ast__MethodInst const value) {
  return (Option__ast__ast__MethodInst){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ast__ast__MethodInst Option__ast__ast__MethodInst__none(void) {
  return (Option__ast__ast__MethodInst){ .tag = Option_None };
}

bool Option__ast__ast__MethodInst__is_some(const Option__ast__ast__MethodInst *const self) {
  {
    const Option__ast__ast__MethodInst *const __sc70 = self;
    if ((*__sc70).tag == Option_Some) {
      return true;
    }
    else if ((*__sc70).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ast__ast__MethodInst__is_none(const Option__ast__ast__MethodInst *const self) {
  {
    const Option__ast__ast__MethodInst *const __sc71 = self;
    if ((*__sc71).tag == Option_Some) {
      return false;
    }
    else if ((*__sc71).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ast__ast__MethodInst Option__ast__ast__MethodInst__default_(void) {
  return Option__ast__ast__MethodInst__none();
}

bool Option__ast__ast__MethodInst__eq(const Option__ast__ast__MethodInst *const self, const Option__ast__ast__MethodInst *const other) {
  {
    const Option__ast__ast__MethodInst *const __sc72 = self;
    if ((*__sc72).tag == Option_Some) {
      const __auto_type a = &((*__sc72).payload.Some._0);
      return ({
        bool __sc73;
        const Option__ast__ast__MethodInst *const __sc74 = other;
        if ((*__sc74).tag == Option_Some) {
          const __auto_type b = &((*__sc74).payload.Some._0);
          __sc73 = ast__ast__MethodInst__eq(a, b);
        }
        else if ((*__sc74).tag == Option_None) {
          __sc73 = false;
        }
        else { __builtin_unreachable(); }
        __sc73;
      });
    }
    else if ((*__sc72).tag == Option_None) {
      return Option__ast__ast__MethodInst__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__ast__ast__MethodInst__hash(const Option__ast__ast__MethodInst *const self) {
  {
    const Option__ast__ast__MethodInst *const __sc75 = self;
    if ((*__sc75).tag == Option_Some) {
      const __auto_type v = &((*__sc75).payload.Some._0);
      return ((ast__ast__MethodInst__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc75).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_ast__ast__MethodInst Option__ptr_ast__ast__MethodInst__some(const ast__ast__MethodInst *const value) {
  return (Option__ptr_ast__ast__MethodInst){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_ast__ast__MethodInst Option__ptr_ast__ast__MethodInst__none(void) {
  return (Option__ptr_ast__ast__MethodInst){ .tag = Option_None };
}

bool Option__ptr_ast__ast__MethodInst__is_some(const Option__ptr_ast__ast__MethodInst *const self) {
  {
    const Option__ptr_ast__ast__MethodInst *const __sc76 = self;
    if ((*__sc76).tag == Option_Some) {
      return true;
    }
    else if ((*__sc76).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_ast__ast__MethodInst__is_none(const Option__ptr_ast__ast__MethodInst *const self) {
  {
    const Option__ptr_ast__ast__MethodInst *const __sc77 = self;
    if ((*__sc77).tag == Option_Some) {
      return false;
    }
    else if ((*__sc77).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_ast__ast__MethodInst Option__ptr_ast__ast__MethodInst__default_(void) {
  return Option__ptr_ast__ast__MethodInst__none();
}

Option__ptr_ast__ast__MethodInst VecIter__ast__ast__MethodInst__next(VecIter__ast__ast__MethodInst *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_ast__ast__MethodInst__none();
  }
  const ast__ast__MethodInst *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_ast__ast__MethodInst__some(r);
}

size_t Slice__ast__ast__MethodInst__len(const Slice__ast__ast__MethodInst *const self) {
  return self->len;
}

const ast__ast__MethodInst *Slice__ast__ast__MethodInst__as_ptr(const Slice__ast__ast__MethodInst *const self) {
  return self->ptr;
}

const ast__ast__MethodInst *Slice__ast__ast__MethodInst__index(const Slice__ast__ast__MethodInst *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__MethodInst Slice__ast__ast__MethodInst__index_range(const Slice__ast__ast__MethodInst *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc78;
    if (r.inclusive) {
      __sc78 = (r.end + 1ULL);
    } else {
      __sc78 = r.end;
    }
    __sc78;
  });
  return (Slice__ast__ast__MethodInst){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__ast__ast__MethodInst__len(const SliceMut__ast__ast__MethodInst *const self) {
  return self->len;
}

ast__ast__MethodInst *SliceMut__ast__ast__MethodInst__as_mut_ptr(const SliceMut__ast__ast__MethodInst *const self) {
  return self->ptr;
}

const ast__ast__MethodInst *SliceMut__ast__ast__MethodInst__index(const SliceMut__ast__ast__MethodInst *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__MethodInst SliceMut__ast__ast__MethodInst__index_range(const SliceMut__ast__ast__MethodInst *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc79;
    if (r.inclusive) {
      __sc79 = (r.end + 1ULL);
    } else {
      __sc79 = r.end;
    }
    __sc79;
  });
  return (Slice__ast__ast__MethodInst){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__MethodInst *SliceMut__ast__ast__MethodInst__index_mut(SliceMut__ast__ast__MethodInst *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__MethodInst SliceMut__ast__ast__MethodInst__index_range_mut(SliceMut__ast__ast__MethodInst *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc80;
    if (r.inclusive) {
      __sc80 = (r.end + 1ULL);
    } else {
      __sc80 = r.end;
    }
    __sc80;
  });
  return (SliceMut__ast__ast__MethodInst){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__ptr_ast__ast__TyInstance MapKeys__ast__ast__TyInstance__next(MapKeys__ast__ast__TyInstance *const self) {
  while (self->idx < self->cap) {
    const size_t i = self->idx;
    (self->idx = (self->idx + 1ULL));
    if (self->used[i] != 0U) {
      return (Option__ptr_ast__ast__TyInstance){ .tag = Option_Some, .payload.Some = { (&self->keys[i]) } };
    }
  }
  return (Option__ptr_ast__ast__TyInstance){ .tag = Option_None };
}

Option__ptr_ast__ast__MethodInst MapKeys__ast__ast__MethodInst__next(MapKeys__ast__ast__MethodInst *const self) {
  while (self->idx < self->cap) {
    const size_t i = self->idx;
    (self->idx = (self->idx + 1ULL));
    if (self->used[i] != 0U) {
      return (Option__ptr_ast__ast__MethodInst){ .tag = Option_Some, .payload.Some = { (&self->keys[i]) } };
    }
  }
  return (Option__ptr_ast__ast__MethodInst){ .tag = Option_None };
}

Option__ast__ast__DynUse Option__ast__ast__DynUse__some(ast__ast__DynUse const value) {
  return (Option__ast__ast__DynUse){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ast__ast__DynUse Option__ast__ast__DynUse__none(void) {
  return (Option__ast__ast__DynUse){ .tag = Option_None };
}

bool Option__ast__ast__DynUse__is_some(const Option__ast__ast__DynUse *const self) {
  {
    const Option__ast__ast__DynUse *const __sc81 = self;
    if ((*__sc81).tag == Option_Some) {
      return true;
    }
    else if ((*__sc81).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ast__ast__DynUse__is_none(const Option__ast__ast__DynUse *const self) {
  {
    const Option__ast__ast__DynUse *const __sc82 = self;
    if ((*__sc82).tag == Option_Some) {
      return false;
    }
    else if ((*__sc82).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ast__ast__DynUse Option__ast__ast__DynUse__default_(void) {
  return Option__ast__ast__DynUse__none();
}

Option__ptr_ast__ast__DynUse Option__ptr_ast__ast__DynUse__some(const ast__ast__DynUse *const value) {
  return (Option__ptr_ast__ast__DynUse){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_ast__ast__DynUse Option__ptr_ast__ast__DynUse__none(void) {
  return (Option__ptr_ast__ast__DynUse){ .tag = Option_None };
}

bool Option__ptr_ast__ast__DynUse__is_some(const Option__ptr_ast__ast__DynUse *const self) {
  {
    const Option__ptr_ast__ast__DynUse *const __sc83 = self;
    if ((*__sc83).tag == Option_Some) {
      return true;
    }
    else if ((*__sc83).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_ast__ast__DynUse__is_none(const Option__ptr_ast__ast__DynUse *const self) {
  {
    const Option__ptr_ast__ast__DynUse *const __sc84 = self;
    if ((*__sc84).tag == Option_Some) {
      return false;
    }
    else if ((*__sc84).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_ast__ast__DynUse Option__ptr_ast__ast__DynUse__default_(void) {
  return Option__ptr_ast__ast__DynUse__none();
}

Option__ptr_ast__ast__DynUse VecIter__ast__ast__DynUse__next(VecIter__ast__ast__DynUse *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_ast__ast__DynUse__none();
  }
  const ast__ast__DynUse *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_ast__ast__DynUse__some(r);
}

size_t Slice__ast__ast__DynUse__len(const Slice__ast__ast__DynUse *const self) {
  return self->len;
}

const ast__ast__DynUse *Slice__ast__ast__DynUse__as_ptr(const Slice__ast__ast__DynUse *const self) {
  return self->ptr;
}

const ast__ast__DynUse *Slice__ast__ast__DynUse__index(const Slice__ast__ast__DynUse *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__DynUse Slice__ast__ast__DynUse__index_range(const Slice__ast__ast__DynUse *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc85;
    if (r.inclusive) {
      __sc85 = (r.end + 1ULL);
    } else {
      __sc85 = r.end;
    }
    __sc85;
  });
  return (Slice__ast__ast__DynUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__ast__ast__DynUse__len(const SliceMut__ast__ast__DynUse *const self) {
  return self->len;
}

ast__ast__DynUse *SliceMut__ast__ast__DynUse__as_mut_ptr(const SliceMut__ast__ast__DynUse *const self) {
  return self->ptr;
}

const ast__ast__DynUse *SliceMut__ast__ast__DynUse__index(const SliceMut__ast__ast__DynUse *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__DynUse SliceMut__ast__ast__DynUse__index_range(const SliceMut__ast__ast__DynUse *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc86;
    if (r.inclusive) {
      __sc86 = (r.end + 1ULL);
    } else {
      __sc86 = r.end;
    }
    __sc86;
  });
  return (Slice__ast__ast__DynUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__DynUse *SliceMut__ast__ast__DynUse__index_mut(SliceMut__ast__ast__DynUse *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__DynUse SliceMut__ast__ast__DynUse__index_range_mut(SliceMut__ast__ast__DynUse *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc87;
    if (r.inclusive) {
      __sc87 = (r.end + 1ULL);
    } else {
      __sc87 = r.end;
    }
    __sc87;
  });
  return (SliceMut__ast__ast__DynUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__ast__ast__DerefUse Option__ast__ast__DerefUse__some(ast__ast__DerefUse const value) {
  return (Option__ast__ast__DerefUse){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ast__ast__DerefUse Option__ast__ast__DerefUse__none(void) {
  return (Option__ast__ast__DerefUse){ .tag = Option_None };
}

bool Option__ast__ast__DerefUse__is_some(const Option__ast__ast__DerefUse *const self) {
  {
    const Option__ast__ast__DerefUse *const __sc88 = self;
    if ((*__sc88).tag == Option_Some) {
      return true;
    }
    else if ((*__sc88).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ast__ast__DerefUse__is_none(const Option__ast__ast__DerefUse *const self) {
  {
    const Option__ast__ast__DerefUse *const __sc89 = self;
    if ((*__sc89).tag == Option_Some) {
      return false;
    }
    else if ((*__sc89).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ast__ast__DerefUse Option__ast__ast__DerefUse__default_(void) {
  return Option__ast__ast__DerefUse__none();
}

Option__ptr_ast__ast__DerefUse Option__ptr_ast__ast__DerefUse__some(const ast__ast__DerefUse *const value) {
  return (Option__ptr_ast__ast__DerefUse){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_ast__ast__DerefUse Option__ptr_ast__ast__DerefUse__none(void) {
  return (Option__ptr_ast__ast__DerefUse){ .tag = Option_None };
}

bool Option__ptr_ast__ast__DerefUse__is_some(const Option__ptr_ast__ast__DerefUse *const self) {
  {
    const Option__ptr_ast__ast__DerefUse *const __sc90 = self;
    if ((*__sc90).tag == Option_Some) {
      return true;
    }
    else if ((*__sc90).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_ast__ast__DerefUse__is_none(const Option__ptr_ast__ast__DerefUse *const self) {
  {
    const Option__ptr_ast__ast__DerefUse *const __sc91 = self;
    if ((*__sc91).tag == Option_Some) {
      return false;
    }
    else if ((*__sc91).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_ast__ast__DerefUse Option__ptr_ast__ast__DerefUse__default_(void) {
  return Option__ptr_ast__ast__DerefUse__none();
}

Option__ptr_ast__ast__DerefUse VecIter__ast__ast__DerefUse__next(VecIter__ast__ast__DerefUse *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_ast__ast__DerefUse__none();
  }
  const ast__ast__DerefUse *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_ast__ast__DerefUse__some(r);
}

size_t Slice__ast__ast__DerefUse__len(const Slice__ast__ast__DerefUse *const self) {
  return self->len;
}

const ast__ast__DerefUse *Slice__ast__ast__DerefUse__as_ptr(const Slice__ast__ast__DerefUse *const self) {
  return self->ptr;
}

const ast__ast__DerefUse *Slice__ast__ast__DerefUse__index(const Slice__ast__ast__DerefUse *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__DerefUse Slice__ast__ast__DerefUse__index_range(const Slice__ast__ast__DerefUse *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc92;
    if (r.inclusive) {
      __sc92 = (r.end + 1ULL);
    } else {
      __sc92 = r.end;
    }
    __sc92;
  });
  return (Slice__ast__ast__DerefUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__ast__ast__DerefUse__len(const SliceMut__ast__ast__DerefUse *const self) {
  return self->len;
}

ast__ast__DerefUse *SliceMut__ast__ast__DerefUse__as_mut_ptr(const SliceMut__ast__ast__DerefUse *const self) {
  return self->ptr;
}

const ast__ast__DerefUse *SliceMut__ast__ast__DerefUse__index(const SliceMut__ast__ast__DerefUse *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__DerefUse SliceMut__ast__ast__DerefUse__index_range(const SliceMut__ast__ast__DerefUse *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc93;
    if (r.inclusive) {
      __sc93 = (r.end + 1ULL);
    } else {
      __sc93 = r.end;
    }
    __sc93;
  });
  return (Slice__ast__ast__DerefUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__DerefUse *SliceMut__ast__ast__DerefUse__index_mut(SliceMut__ast__ast__DerefUse *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__DerefUse SliceMut__ast__ast__DerefUse__index_range_mut(SliceMut__ast__ast__DerefUse *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc94;
    if (r.inclusive) {
      __sc94 = (r.end + 1ULL);
    } else {
      __sc94 = r.end;
    }
    __sc94;
  });
  return (SliceMut__ast__ast__DerefUse){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__ast__ast__Attr Option__ast__ast__Attr__some(ast__ast__Attr const value) {
  return (Option__ast__ast__Attr){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ast__ast__Attr Option__ast__ast__Attr__none(void) {
  return (Option__ast__ast__Attr){ .tag = Option_None };
}

bool Option__ast__ast__Attr__is_some(const Option__ast__ast__Attr *const self) {
  {
    const Option__ast__ast__Attr *const __sc95 = self;
    if ((*__sc95).tag == Option_Some) {
      return true;
    }
    else if ((*__sc95).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ast__ast__Attr__is_none(const Option__ast__ast__Attr *const self) {
  {
    const Option__ast__ast__Attr *const __sc96 = self;
    if ((*__sc96).tag == Option_Some) {
      return false;
    }
    else if ((*__sc96).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ast__ast__Attr Option__ast__ast__Attr__default_(void) {
  return Option__ast__ast__Attr__none();
}

Option__ptr_ast__ast__Attr Option__ptr_ast__ast__Attr__some(const ast__ast__Attr *const value) {
  return (Option__ptr_ast__ast__Attr){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_ast__ast__Attr Option__ptr_ast__ast__Attr__none(void) {
  return (Option__ptr_ast__ast__Attr){ .tag = Option_None };
}

bool Option__ptr_ast__ast__Attr__is_some(const Option__ptr_ast__ast__Attr *const self) {
  {
    const Option__ptr_ast__ast__Attr *const __sc97 = self;
    if ((*__sc97).tag == Option_Some) {
      return true;
    }
    else if ((*__sc97).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_ast__ast__Attr__is_none(const Option__ptr_ast__ast__Attr *const self) {
  {
    const Option__ptr_ast__ast__Attr *const __sc98 = self;
    if ((*__sc98).tag == Option_Some) {
      return false;
    }
    else if ((*__sc98).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_ast__ast__Attr Option__ptr_ast__ast__Attr__default_(void) {
  return Option__ptr_ast__ast__Attr__none();
}

Option__ptr_ast__ast__Attr VecIter__ast__ast__Attr__next(VecIter__ast__ast__Attr *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_ast__ast__Attr__none();
  }
  const ast__ast__Attr *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_ast__ast__Attr__some(r);
}

size_t Slice__ast__ast__Attr__len(const Slice__ast__ast__Attr *const self) {
  return self->len;
}

const ast__ast__Attr *Slice__ast__ast__Attr__as_ptr(const Slice__ast__ast__Attr *const self) {
  return self->ptr;
}

const ast__ast__Attr *Slice__ast__ast__Attr__index(const Slice__ast__ast__Attr *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__Attr Slice__ast__ast__Attr__index_range(const Slice__ast__ast__Attr *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc99;
    if (r.inclusive) {
      __sc99 = (r.end + 1ULL);
    } else {
      __sc99 = r.end;
    }
    __sc99;
  });
  return (Slice__ast__ast__Attr){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__ast__ast__Attr__len(const SliceMut__ast__ast__Attr *const self) {
  return self->len;
}

ast__ast__Attr *SliceMut__ast__ast__Attr__as_mut_ptr(const SliceMut__ast__ast__Attr *const self) {
  return self->ptr;
}

const ast__ast__Attr *SliceMut__ast__ast__Attr__index(const SliceMut__ast__ast__Attr *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__ast__ast__Attr SliceMut__ast__ast__Attr__index_range(const SliceMut__ast__ast__Attr *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc100;
    if (r.inclusive) {
      __sc100 = (r.end + 1ULL);
    } else {
      __sc100 = r.end;
    }
    __sc100;
  });
  return (Slice__ast__ast__Attr){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

ast__ast__Attr *SliceMut__ast__ast__Attr__index_mut(SliceMut__ast__ast__Attr *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__ast__ast__Attr SliceMut__ast__ast__Attr__index_range_mut(SliceMut__ast__ast__Attr *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc101;
    if (r.inclusive) {
      __sc101 = (r.end + 1ULL);
    } else {
      __sc101 = r.end;
    }
    __sc101;
  });
  return (SliceMut__ast__ast__Attr){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Map__u64__ast__ast__DefId__Global Map__u64__ast__ast__DefId__Global__new_in(Global const alloc) {
  return (Map__u64__ast__ast__DefId__Global){ .keys = NULL, .vals = NULL, .used = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

size_t Map__u64__ast__ast__DefId__Global__len(const Map__u64__ast__ast__DefId__Global *const self) {
  return self->len;
}

bool Map__u64__ast__ast__DefId__Global__is_empty(const Map__u64__ast__ast__DefId__Global *const self) {
  return (self->len == 0ULL);
}

static __attribute__((unused)) size_t Map__u64__ast__ast__DefId__Global__slot(const Map__u64__ast__ast__DefId__Global *const self, const uint64_t *const key) {
  size_t i = ({ size_t __sc102 = ((size_t)u64__hash(key)); size_t __sc103 = self->cap; if (__sc103 == 0) { __sc_panic("divide by zero"); } (__sc102 % __sc103); });
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

static __attribute__((unused)) void Map__u64__ast__ast__DefId__Global__grow(Map__u64__ast__ast__DefId__Global *const self) {
  size_t newcap = (self->cap * 2ULL);
  if (newcap < 8ULL) {
    (newcap = 8ULL);
  }
  uint64_t *const oldkeys = self->keys;
  ast__ast__DefId *const oldvals = self->vals;
  uint8_t *const oldused = self->used;
  const size_t oldcap = self->cap;
  (self->keys = ((uint64_t *)Global__alloc(&self->alloc, (newcap * sizeof(uint64_t)), _Alignof(uint64_t))));
  (self->vals = ((ast__ast__DefId *)Global__alloc(&self->alloc, (newcap * sizeof(ast__ast__DefId)), _Alignof(ast__ast__DefId))));
  (self->used = ((uint8_t *)Global__alloc(&self->alloc, newcap, 1ULL)));
  memset(((void *)self->used), 0, newcap);
  (self->cap = newcap);
  (self->len = 0ULL);
  for (size_t i = 0ULL; i < oldcap; i++) {
    if (oldused[i] == 1U) {
      const size_t j = Map__u64__ast__ast__DefId__Global__slot(self, (&oldkeys[i]));
      (self->keys[j] = oldkeys[i]);
      (self->vals[j] = oldvals[i]);
      (self->used[j] = 1U);
      (self->len = (self->len + 1ULL));
    }
  }
  if (oldcap > 0ULL) {
    Global__dealloc(&self->alloc, ((void *)oldkeys), (oldcap * sizeof(uint64_t)), _Alignof(uint64_t));
    Global__dealloc(&self->alloc, ((void *)oldvals), (oldcap * sizeof(ast__ast__DefId)), _Alignof(ast__ast__DefId));
    Global__dealloc(&self->alloc, ((void *)oldused), oldcap, 1ULL);
  }
}

void Map__u64__ast__ast__DefId__Global__insert(Map__u64__ast__ast__DefId__Global *const self, uint64_t const key, ast__ast__DefId const value) {
  if ((self->cap == 0ULL) || (((self->len + 1ULL) * 4ULL) >= (self->cap * 3ULL))) {
    Map__u64__ast__ast__DefId__Global__grow(self);
  }
  const size_t i = Map__u64__ast__ast__DefId__Global__slot(self, (&key));
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

Option__ptr_ast__ast__DefId Map__u64__ast__ast__DefId__Global__get(const Map__u64__ast__ast__DefId__Global *const self, const uint64_t *const key) {
  if (self->cap == 0ULL) {
    return (Option__ptr_ast__ast__DefId){ .tag = Option_None };
  }
  const size_t i = Map__u64__ast__ast__DefId__Global__slot(self, key);
  if (self->used[i] == 0U) {
    return (Option__ptr_ast__ast__DefId){ .tag = Option_None };
  }
  return (Option__ptr_ast__ast__DefId){ .tag = Option_Some, .payload.Some = { (&self->vals[i]) } };
}

bool Map__u64__ast__ast__DefId__Global__contains_key(const Map__u64__ast__ast__DefId__Global *const self, const uint64_t *const key) {
  return ({ __auto_type __sc104 = Map__u64__ast__ast__DefId__Global__get(self, key); Option__ptr_ast__ast__DefId__is_some(&__sc104); });
}

Option__ast__ast__DefId Map__u64__ast__ast__DefId__Global__remove(Map__u64__ast__ast__DefId__Global *const self, const uint64_t *const key) {
  if (self->cap == 0ULL) {
    return (Option__ast__ast__DefId){ .tag = Option_None };
  }
  const size_t i = Map__u64__ast__ast__DefId__Global__slot(self, key);
  if (self->used[i] == 0U) {
    return (Option__ast__ast__DefId){ .tag = Option_None };
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
    Map__u64__ast__ast__DefId__Global__insert(self, k, v);
    (j = (j + 1ULL));
    if (j >= self->cap) {
      (j = 0ULL);
    }
  }
  return (Option__ast__ast__DefId){ .tag = Option_Some, .payload.Some = { removed } };
}

Map__u64__ast__ast__DefId__Global Map__u64__ast__ast__DefId__Global__new(void) {
  return Map__u64__ast__ast__DefId__Global__new_in(Global__default_());
}

void Map__u64__ast__ast__DefId__Global__free(Map__u64__ast__ast__DefId__Global *const self) {
  for (size_t i = 0ULL; i < self->cap; i++) {
    if (self->used[i] != 0U) {
      (void)(self->keys[i]);
      (void)(self->vals[i]);
    }
  }
  Global__dealloc(&self->alloc, ((void *)self->keys), (self->cap * sizeof(uint64_t)), _Alignof(uint64_t));
  Global__dealloc(&self->alloc, ((void *)self->vals), (self->cap * sizeof(ast__ast__DefId)), _Alignof(ast__ast__DefId));
  Global__dealloc(&self->alloc, ((void *)self->used), self->cap, 1ULL);
  (self->keys = NULL);
  (self->vals = NULL);
  (self->used = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

MapKeys__u64 Map__u64__ast__ast__DefId__Global__keys(const Map__u64__ast__ast__DefId__Global *const self) {
  return (MapKeys__u64){ .keys = ((const uint64_t *)self->keys), .used = ((const uint8_t *)self->used), .idx = 0ULL, .cap = self->cap };
}

Option__ptr_ast__ast__DefId MapValues__ast__ast__DefId__next(MapValues__ast__ast__DefId *const self) {
  while (self->idx < self->cap) {
    const size_t i = self->idx;
    (self->idx = (self->idx + 1ULL));
    if (self->used[i] != 0U) {
      return (Option__ptr_ast__ast__DefId){ .tag = Option_Some, .payload.Some = { (&self->vals[i]) } };
    }
  }
  return (Option__ptr_ast__ast__DefId){ .tag = Option_None };
}

uint64_t ast__ast__Ty__hash(const ast__ast__Ty *const self) {
  const uint64_t *const p = ((const uint64_t *)((const ast__ast__Ty *)self));
  uint64_t h = 1469598103934665603ULL;
  for (size_t i = 0ULL; i < 2ULL; i++) {
    (h = (h ^ p[i]));
    (h = (h * 1099511628211ULL));
  }
  return h;
}

bool ast__ast__Ty__eq(const ast__ast__Ty *const self, const ast__ast__Ty *const other) {
  return (memcmp(((const ast__ast__Ty *)self), ((const ast__ast__Ty *)other), 16ULL) == 0);
}

uint64_t ast__ast__TyInstance__hash(const ast__ast__TyInstance *const self) {
  uint64_t h = 1469598103934665603ULL;
  (h = ((h ^ ((uint64_t)self->module)) * 1099511628211ULL));
  (h = ((h ^ ((uint64_t)self->decl)) * 1099511628211ULL));
  (h = ((h ^ ((uint64_t)self->n)) * 1099511628211ULL));
  for (uint8_t i = 0U; i < self->n; i++) {
    (h = ((h ^ ((uint64_t)self->args[i])) * 1099511628211ULL));
  }
  return h;
}

bool ast__ast__TyInstance__eq(const ast__ast__TyInstance *const self, const ast__ast__TyInstance *const other) {
  if (((self->module != other->module) || (self->decl != other->decl)) || (self->n != other->n)) {
    return false;
  }
  for (uint8_t i = 0U; i < self->n; i++) {
    if (self->args[i] != other->args[i]) {
      return false;
    }
  }
  return true;
}

uint64_t ast__ast__MethodInst__hash(const ast__ast__MethodInst *const self) {
  uint64_t h = 1469598103934665603ULL;
  (h = ((h ^ ((uint64_t)self->instance)) * 1099511628211ULL));
  (h = ((h ^ ((uint64_t)self->method)) * 1099511628211ULL));
  (h = ((h ^ ((uint64_t)self->n)) * 1099511628211ULL));
  for (uint8_t i = 0U; i < self->n; i++) {
    (h = ((h ^ ((uint64_t)self->targs[i])) * 1099511628211ULL));
  }
  return h;
}

bool ast__ast__MethodInst__eq(const ast__ast__MethodInst *const self, const ast__ast__MethodInst *const other) {
  if (((self->instance != other->instance) || (self->method != other->method)) || (self->n != other->n)) {
    return false;
  }
  for (uint8_t i = 0U; i < self->n; i++) {
    if (self->targs[i] != other->targs[i]) {
      return false;
    }
  }
  return true;
}

ast__ast__Ast ast__ast__Ast__new(size_t const token_count) {
  ast__ast__Ast a = (ast__ast__Ast){ .nodes = Vector__ast__ast__Node__Global__new(), .children = Vector__u32__Global__new(), .scratch = Vector__u32__Global__new(), .resolutions = Vector__ast__ast__DefId__Global__new(), .type_pool = Vector__ast__ast__Ty__Global__new(), .type_index = Map__ast__ast__Ty__u32__Global__new(), .types = Vector__u32__Global__new(), .mono = Vector__ast__ast__MonoUse__Global__new(), .mono_at = Vector__u32__Global__new(), .instances = Vector__ast__ast__TyInstance__Global__new(), .method_insts = Vector__ast__ast__MethodInst__Global__new(), .instance_index = Map__ast__ast__TyInstance__u32__Global__new(), .method_inst_index = Map__ast__ast__MethodInst__u32__Global__new(), .dyn_uses = Vector__ast__ast__DynUse__Global__new(), .dyn_at = Vector__u32__Global__new(), .deref_uses = Vector__ast__ast__DerefUse__Global__new(), .deref_at = Vector__u32__Global__new(), .attrs = Vector__ast__ast__Attr__Global__new(), .root = ast__ast__NODE_NONE, .module = 0U };
  Vector__ast__ast__Node__Global__reserve(&a.nodes, token_count);
  Vector__u32__Global__reserve(&a.children, ({ size_t __sc105 = token_count; size_t __sc106 = 2ULL; if (__sc106 == 0) { __sc_panic("divide by zero"); } (__sc105 / __sc106); }));
  Vector__ast__ast__Node__Global__push(&a.nodes, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_NONE_KIND });
  return a;
}

uint32_t ast__ast__Ast__add(ast__ast__Ast *const self, ast__ast__Node const node) {
  const uint32_t id = ((uint32_t)Vector__ast__ast__Node__Global__len(&self->nodes));
  Vector__ast__ast__Node__Global__push(&self->nodes, node);
  return id;
}

uint32_t ast__ast__Ast__mark(const ast__ast__Ast *const self) {
  return ((uint32_t)Vector__u32__Global__len(&self->scratch));
}

void ast__ast__Ast__push(ast__ast__Ast *const self, uint32_t const id) {
  Vector__u32__Global__push(&self->scratch, id);
}

ast__ast__NodeList ast__ast__Ast__commit(ast__ast__Ast *const self, uint32_t const mark) {
  const ast__ast__NodeList list = (ast__ast__NodeList){ .start = ((uint32_t)Vector__u32__Global__len(&self->children)), .len = (((uint32_t)Vector__u32__Global__len(&self->scratch)) - mark) };
  for (size_t i = ((size_t)mark); i < Vector__u32__Global__len(&self->scratch); i++) {
    Vector__u32__Global__push(&self->children, (*({ __auto_type __sc107 = &self->scratch; Vector__u32__Global__index(__sc107, i); })));
  }
  Vector__u32__Global__truncate(&self->scratch, ((size_t)mark));
  return list;
}

void ast__ast__Ast__init_resolutions(ast__ast__Ast *const self) {
  Vector__ast__ast__DefId__Global__clear(&self->resolutions);
  Vector__ast__ast__DefId__Global__reserve(&self->resolutions, Vector__ast__ast__Node__Global__len(&self->nodes));
  for (size_t _ = 0ULL; _ < Vector__ast__ast__Node__Global__len(&self->nodes); _++) {
    Vector__ast__ast__DefId__Global__push(&self->resolutions, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE });
  }
}

void ast__ast__Ast__init_types(ast__ast__Ast *const self) {
  Vector__u32__Global__clear(&self->types);
  Vector__u32__Global__reserve(&self->types, Vector__ast__ast__Node__Global__len(&self->nodes));
  for (size_t _ = 0ULL; _ < Vector__ast__ast__Node__Global__len(&self->nodes); _++) {
    Vector__u32__Global__push(&self->types, ast__ast__TYPE_NONE);
  }
  Vector__ast__ast__Ty__Global__clear(&self->type_pool);
  (self->type_index = Map__ast__ast__Ty__u32__Global__new());
  const ast__ast__Ty err = (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_ERROR };
  Vector__ast__ast__Ty__Global__push(&self->type_pool, err);
  Map__ast__ast__Ty__u32__Global__insert(&self->type_index, err, 0U);
  for (uint8_t b = 0U; b < 18U; b++) {
    const ast__ast__Ty t = (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_BUILTIN, .as_data = (ast__ast__TyAs){ .builtin = ((ast__ast__BuiltinType)b) } };
    Vector__ast__ast__Ty__Global__push(&self->type_pool, t);
    Map__ast__ast__Ty__u32__Global__insert(&self->type_index, t, (((uint32_t)b) + 1U));
  }
}

uint32_t ast__ast__Ast__intern_type(ast__ast__Ast *const self, ast__ast__Ty const t) {
  {
    const Option__ptr_u32 __sc108 = Map__ast__ast__Ty__u32__Global__get(&self->type_index, (&t));
    if (__sc108.tag == Option_Some) {
      const uint32_t *const id = __sc108.payload.Some._0;
      return (*id);
    }
    else if (__sc108.tag == Option_None) {
      return ({
        const uint32_t id = ((uint32_t)Vector__ast__ast__Ty__Global__len(&self->type_pool));
        Vector__ast__ast__Ty__Global__push(&self->type_pool, t);
        Map__ast__ast__Ty__u32__Global__insert(&self->type_index, t, id);
        id;
      });
    }
    else { __builtin_unreachable(); }
  }
}

uint32_t ast__ast__Ast__intern_instance(ast__ast__Ast *const self, uint16_t const module, uint32_t const decl, const uint32_t *const args, uint8_t const n) {
  uint8_t m = n;
  if (m > 4U) {
    (m = 4U);
  }
  ast__ast__TyInstance it = (ast__ast__TyInstance){ .module = module, .decl = decl, .n = m };
  for (uint8_t j = 0U; j < m; j++) {
    (it.args[j] = args[j]);
  }
  const uint32_t hinted = ({
    uint32_t __sc109;
    const Option__ptr_u32 __sc110 = Map__ast__ast__TyInstance__u32__Global__get(&self->instance_index, (&it));
    if (__sc110.tag == Option_Some) {
      const uint32_t *const id = __sc110.payload.Some._0;
      __sc109 = (*id);
    }
    else if (__sc110.tag == Option_None) {
      __sc109 = 0xFFFFFFFFU;
    }
    else { __builtin_unreachable(); }
    __sc109;
  });
  const size_t cur = Vector__ast__ast__TyInstance__Global__len(&self->instances);
  uint32_t idx = ((uint32_t)cur);
  bool valid = false;
  if ((hinted != 0xFFFFFFFFU) && (((size_t)hinted) < cur)) {
    (valid = ast__ast__TyInstance__eq(Vector__ast__ast__TyInstance__Global__at(&self->instances, ((size_t)hinted)), (&it)));
  }
  if (valid) {
    (idx = hinted);
  } else {
    Vector__ast__ast__TyInstance__Global__push(&self->instances, it);
    Map__ast__ast__TyInstance__u32__Global__insert(&self->instance_index, it, idx);
  }
  return ast__ast__Ast__intern_type(self, (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_INSTANCE, .module = module, .as_data = (ast__ast__TyAs){ .inst = idx } });
}

const ast__ast__TyInstance *ast__ast__Ast__instance(const ast__ast__Ast *const self, uint32_t const index) {
  return Vector__ast__ast__TyInstance__Global__at(&self->instances, ((size_t)index));
}

uint32_t ast__ast__Ast__const_value(ast__ast__Ast *const self, int64_t const v) {
  return ast__ast__Ast__intern_type(self, (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_CONST, .module = 0U, .as_data = (ast__ast__TyAs){ .value = v } });
}

bool ast__ast__Ast__add_method_inst(ast__ast__Ast *const self, uint32_t const instance, uint32_t const method, const uint32_t *const targs, uint8_t const n) {
  uint8_t m = n;
  if (m > 4U) {
    (m = 4U);
  }
  ast__ast__MethodInst mi = (ast__ast__MethodInst){ .instance = instance, .method = method, .n = m };
  for (uint8_t j = 0U; j < m; j++) {
    (mi.targs[j] = targs[j]);
  }
  const uint32_t hinted = ({
    uint32_t __sc111;
    const Option__ptr_u32 __sc112 = Map__ast__ast__MethodInst__u32__Global__get(&self->method_inst_index, (&mi));
    if (__sc112.tag == Option_Some) {
      const uint32_t *const id = __sc112.payload.Some._0;
      __sc111 = (*id);
    }
    else if (__sc112.tag == Option_None) {
      __sc111 = 0xFFFFFFFFU;
    }
    else { __builtin_unreachable(); }
    __sc111;
  });
  if (((hinted != 0xFFFFFFFFU) && (((size_t)hinted) < Vector__ast__ast__MethodInst__Global__len(&self->method_insts))) && ast__ast__MethodInst__eq(Vector__ast__ast__MethodInst__Global__at(&self->method_insts, ((size_t)hinted)), (&mi))) {
    return false;
  }
  const uint32_t idx = ((uint32_t)Vector__ast__ast__MethodInst__Global__len(&self->method_insts));
  Vector__ast__ast__MethodInst__Global__push(&self->method_insts, mi);
  Map__ast__ast__MethodInst__u32__Global__insert(&self->method_inst_index, mi, idx);
  return true;
}

void ast__ast__Ast__add_attr(ast__ast__Ast *const self, ast__ast__Attr const attr) {
  Vector__ast__ast__Attr__Global__push(&self->attrs, attr);
}

bool ast__ast__Ast__type_concrete(const ast__ast__Ast *const self, uint32_t const t) {
  const ast__ast__Ty *const ty = ast__ast__Ast__type_at(self, t);
  {
    const ast__ast__TypeKind __sc113 = ty->kind;
    if (__sc113 == ast__ast__TypeKind_TYPE_GENERIC) {
      return false;
    }
    else if ((__sc113 == ast__ast__TypeKind_TYPE_POINTER) || (__sc113 == ast__ast__TypeKind_TYPE_REFERENCE) || (__sc113 == ast__ast__TypeKind_TYPE_SLICE) || (__sc113 == ast__ast__TypeKind_TYPE_ARRAY)) {
      return ast__ast__Ast__type_concrete(self, ty->as_data.elem);
    }
    else if (__sc113 == ast__ast__TypeKind_TYPE_INSTANCE) {
      return ({
        const ast__ast__TyInstance *const it = ast__ast__Ast__instance(self, ty->as_data.inst);
        for (uint8_t i = 0U; i < it->n; i++) {
          if (!ast__ast__Ast__type_concrete(self, it->args[i])) {
            return false;
          }
        }
        true;
      });
    }
    else if (1) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

uint32_t ast__ast__Ast__reintern(ast__ast__Ast *const self, const ast__ast__Ast *const src, uint32_t const t) {
  if (t == ast__ast__TYPE_NONE) {
    return t;
  }
  const ast__ast__Ty ty = (*ast__ast__Ast__type_at(src, t));
  {
    const ast__ast__TypeKind __sc114 = ty.kind;
    if ((__sc114 == ast__ast__TypeKind_TYPE_POINTER) || (__sc114 == ast__ast__TypeKind_TYPE_REFERENCE) || (__sc114 == ast__ast__TypeKind_TYPE_SLICE) || (__sc114 == ast__ast__TypeKind_TYPE_ARRAY)) {
      return ({
        ast__ast__Ty nt = ty;
        (nt.as_data.elem = ast__ast__Ast__reintern(self, src, ty.as_data.elem));
        ast__ast__Ast__intern_type(self, nt);
      });
    }
    else if (__sc114 == ast__ast__TypeKind_TYPE_INSTANCE) {
      return ({
        const ast__ast__TyInstance inst = (*ast__ast__Ast__instance(src, ty.as_data.inst));
        uint32_t na[4] = { 0U, 0U, 0U, 0U };
        for (uint8_t i = 0U; i < inst.n; i++) {
          (na[__sc_bounds(i, 4)] = ast__ast__Ast__reintern(self, (&(*src)), inst.args[i]));
        }
        ast__ast__Ast__intern_instance(self, inst.module, inst.decl, (&na[0]), inst.n);
      });
    }
    else if (1) {
      return ast__ast__Ast__intern_type(self, ty);
    }
    else { __builtin_unreachable(); }
  }
}

void ast__ast__Ast__set_type_args(ast__ast__Ast *const self, uint32_t const node, const uint32_t *const args, uint8_t const n) {
  uint8_t m = n;
  if (m > 4U) {
    (m = 4U);
  }
  ast__ast__MonoUse u = (ast__ast__MonoUse){ .node = node, .n = m };
  for (uint8_t i = 0U; i < m; i++) {
    (u.args[i] = args[i]);
  }
  Vector__ast__ast__MonoUse__Global__push(&self->mono, u);
  ast__ast__ensure_u32_len((&self->mono_at), Vector__ast__ast__Node__Global__len(&self->nodes), (((size_t)node) + 1ULL));
  (*Vector__u32__Global__index_mut(&self->mono_at, ((size_t)node)) = ((uint32_t)Vector__ast__ast__MonoUse__Global__len(&self->mono)));
}

const ast__ast__MonoUse *ast__ast__Ast__type_args(const ast__ast__Ast *const self, uint32_t const node) {
  if (((size_t)node) >= Vector__u32__Global__len(&self->mono_at)) {
    return NULL;
  }
  const uint32_t idx = (*({ __auto_type __sc115 = &self->mono_at; Vector__u32__Global__index(__sc115, ((size_t)node)); }));
  if (idx == 0U) {
    return NULL;
  }
  return ((const ast__ast__MonoUse *)Vector__ast__ast__MonoUse__Global__at(&self->mono, ((size_t)(idx - 1U))));
}

void ast__ast__Ast__add_dyn_use(ast__ast__Ast *const self, uint32_t const node, uint32_t const src, uint32_t const dyn_ty) {
  Vector__ast__ast__DynUse__Global__push(&self->dyn_uses, (ast__ast__DynUse){ .node = node, .src = src, .dyn_ty = dyn_ty });
  ast__ast__ensure_u32_len((&self->dyn_at), Vector__ast__ast__Node__Global__len(&self->nodes), (((size_t)node) + 1ULL));
  (*Vector__u32__Global__index_mut(&self->dyn_at, ((size_t)node)) = ((uint32_t)Vector__ast__ast__DynUse__Global__len(&self->dyn_uses)));
}

const ast__ast__DynUse *ast__ast__Ast__dyn_use_at(const ast__ast__Ast *const self, uint32_t const node) {
  if (((size_t)node) >= Vector__u32__Global__len(&self->dyn_at)) {
    return NULL;
  }
  const uint32_t idx = (*({ __auto_type __sc116 = &self->dyn_at; Vector__u32__Global__index(__sc116, ((size_t)node)); }));
  if (idx == 0U) {
    return NULL;
  }
  return ((const ast__ast__DynUse *)Vector__ast__ast__DynUse__Global__at(&self->dyn_uses, ((size_t)(idx - 1U))));
}

void ast__ast__Ast__add_deref_use(ast__ast__Ast *const self, const ast__ast__DerefUse *const du) {
  Vector__ast__ast__DerefUse__Global__push(&self->deref_uses, (*du));
  ast__ast__ensure_u32_len((&self->deref_at), Vector__ast__ast__Node__Global__len(&self->nodes), (((size_t)du->node) + 1ULL));
  (*Vector__u32__Global__index_mut(&self->deref_at, ((size_t)du->node)) = ((uint32_t)Vector__ast__ast__DerefUse__Global__len(&self->deref_uses)));
}

const ast__ast__DerefUse *ast__ast__Ast__deref_use_at(const ast__ast__Ast *const self, uint32_t const node) {
  if (((size_t)node) >= Vector__u32__Global__len(&self->deref_at)) {
    return NULL;
  }
  const uint32_t idx = (*({ __auto_type __sc117 = &self->deref_at; Vector__u32__Global__index(__sc117, ((size_t)node)); }));
  if (idx == 0U) {
    return NULL;
  }
  return ((const ast__ast__DerefUse *)Vector__ast__ast__DerefUse__Global__at(&self->deref_uses, ((size_t)(idx - 1U))));
}

ast__ast__Node *ast__ast__Ast__at(ast__ast__Ast *const self, uint32_t const id) {
  return (&(*({ __auto_type __sc118 = &self->nodes; Vector__ast__ast__Node__Global__index_mut(__sc118, ((size_t)id)); })));
}

const ast__ast__Node *ast__ast__Ast__at_const(const ast__ast__Ast *const self, uint32_t const id) {
  return Vector__ast__ast__Node__Global__at(&self->nodes, ((size_t)id));
}

const uint32_t *ast__ast__Ast__list(const ast__ast__Ast *const self, ast__ast__NodeList const list) {
  return (Vector__u32__Global__as_ptr(&self->children) + ((size_t)list.start));
}

void ast__ast__Ast__set_resolution(ast__ast__Ast *const self, uint32_t const ref_id, uint32_t const decl) {
  (*Vector__ast__ast__DefId__Global__index_mut(&self->resolutions, ((size_t)ref_id)) = (ast__ast__DefId){ .module = self->module, .node = decl });
}

uint32_t ast__ast__Ast__resolution(const ast__ast__Ast *const self, uint32_t const ref_id) {
  return (*({ __auto_type __sc119 = &self->resolutions; Vector__ast__ast__DefId__Global__index(__sc119, ((size_t)ref_id)); })).node;
}

ast__ast__DefId ast__ast__Ast__resolution_def(const ast__ast__Ast *const self, uint32_t const ref_id) {
  return (*({ __auto_type __sc120 = &self->resolutions; Vector__ast__ast__DefId__Global__index(__sc120, ((size_t)ref_id)); }));
}

void ast__ast__Ast__set_resolution_def(ast__ast__Ast *const self, uint32_t const ref_id, ast__ast__DefId const decl) {
  (*Vector__ast__ast__DefId__Global__index_mut(&self->resolutions, ((size_t)ref_id)) = decl);
}

uint32_t ast__ast__Ast__builtin(ast__ast__BuiltinType const b) {
  return (((uint32_t)b) + 1U);
}

void ast__ast__Ast__set_type(ast__ast__Ast *const self, uint32_t const n, uint32_t const t) {
  (*Vector__u32__Global__index_mut(&self->types, ((size_t)n)) = t);
}

uint32_t ast__ast__Ast__type_of(const ast__ast__Ast *const self, uint32_t const n) {
  return (*({ __auto_type __sc121 = &self->types; Vector__u32__Global__index(__sc121, ((size_t)n)); }));
}

const ast__ast__Ty *ast__ast__Ast__type_at(const ast__ast__Ast *const self, uint32_t const t) {
  return Vector__ast__ast__Ty__Global__at(&self->type_pool, ((size_t)t));
}

static __attribute__((unused)) void ast__ast__ensure_u32_len(Vector__u32__Global *const v, size_t const nodes_len, size_t const need) {
  size_t want = need;
  if (nodes_len > want) {
    (want = nodes_len);
  }
  Vector__u32__Global__reserve(v, want);
  while (Vector__u32__Global__len(v) < want) {
    Vector__u32__Global__push(v, 0U);
  }
}

void ast__ast__Ast__free(ast__ast__Ast *const self) {
  Vector__ast__ast__Node__Global__free(&self->nodes);
  Vector__u32__Global__free(&self->children);
  Vector__u32__Global__free(&self->scratch);
  Vector__ast__ast__DefId__Global__free(&self->resolutions);
  Vector__ast__ast__Ty__Global__free(&self->type_pool);
  Map__ast__ast__Ty__u32__Global__free(&self->type_index);
  Vector__u32__Global__free(&self->types);
  Vector__ast__ast__MonoUse__Global__free(&self->mono);
  Vector__u32__Global__free(&self->mono_at);
  Vector__ast__ast__TyInstance__Global__free(&self->instances);
  Vector__ast__ast__MethodInst__Global__free(&self->method_insts);
  Map__ast__ast__TyInstance__u32__Global__free(&self->instance_index);
  Map__ast__ast__MethodInst__u32__Global__free(&self->method_inst_index);
  Vector__ast__ast__DynUse__Global__free(&self->dyn_uses);
  Vector__u32__Global__free(&self->dyn_at);
  Vector__ast__ast__DerefUse__Global__free(&self->deref_uses);
  Vector__u32__Global__free(&self->deref_at);
  Vector__ast__ast__Attr__Global__free(&self->attrs);
}

ast__ast__BuiltinType ast__ast__ast_numeric_suffix(const uint8_t *const src, uint32_t const start, uint32_t const end, uint32_t *const sfx_start) {
  const bool hex = ((((end - start) > 2U) && (src[start] == 48U)) && ((src[(start + 1U)] | 0x20U) == 120U));
  bool hexf = false;
  uint32_t i = (start + 2U);
  while ((hex && (i < end)) && (!hexf)) {
    (hexf = ((src[i] | 0x20U) == 112U));
    (i = (i + 1U));
  }
  if (((end - start) > 5U) && (memcmp(((src + end) - 5), ({ __auto_type __sc122 = (str){ (const uint8_t *)"isize", sizeof("isize") - 1 }; str__ptr(&__sc122); }), 5ULL) == 0)) {
    if (sfx_start != NULL) {
      ((*sfx_start) = (end - 5U));
    }
    return ast__ast__BuiltinType_BT_ISIZE;
  }
  if (((end - start) > 5U) && (memcmp(((src + end) - 5), ({ __auto_type __sc123 = (str){ (const uint8_t *)"usize", sizeof("usize") - 1 }; str__ptr(&__sc123); }), 5ULL) == 0)) {
    if (sfx_start != NULL) {
      ((*sfx_start) = (end - 5U));
    }
    return ast__ast__BuiltinType_BT_USIZE;
  }
  uint32_t n = 3U;
  if ((end - start) > n) {
    const uint8_t *const p = (src + ((size_t)(end - n)));
    if (memcmp(p, ({ __auto_type __sc124 = (str){ (const uint8_t *)"i16", sizeof("i16") - 1 }; str__ptr(&__sc124); }), ((size_t)n)) == 0) {
      if (sfx_start != NULL) {
        ((*sfx_start) = (end - n));
      }
      return ast__ast__BuiltinType_BT_I16;
    }
    if (memcmp(p, ({ __auto_type __sc125 = (str){ (const uint8_t *)"i32", sizeof("i32") - 1 }; str__ptr(&__sc125); }), ((size_t)n)) == 0) {
      if (sfx_start != NULL) {
        ((*sfx_start) = (end - n));
      }
      return ast__ast__BuiltinType_BT_I32;
    }
    if (memcmp(p, ({ __auto_type __sc126 = (str){ (const uint8_t *)"i64", sizeof("i64") - 1 }; str__ptr(&__sc126); }), ((size_t)n)) == 0) {
      if (sfx_start != NULL) {
        ((*sfx_start) = (end - n));
      }
      return ast__ast__BuiltinType_BT_I64;
    }
    if (memcmp(p, ({ __auto_type __sc127 = (str){ (const uint8_t *)"u16", sizeof("u16") - 1 }; str__ptr(&__sc127); }), ((size_t)n)) == 0) {
      if (sfx_start != NULL) {
        ((*sfx_start) = (end - n));
      }
      return ast__ast__BuiltinType_BT_U16;
    }
    if (memcmp(p, ({ __auto_type __sc128 = (str){ (const uint8_t *)"u32", sizeof("u32") - 1 }; str__ptr(&__sc128); }), ((size_t)n)) == 0) {
      if (sfx_start != NULL) {
        ((*sfx_start) = (end - n));
      }
      return ast__ast__BuiltinType_BT_U32;
    }
    if (memcmp(p, ({ __auto_type __sc129 = (str){ (const uint8_t *)"u64", sizeof("u64") - 1 }; str__ptr(&__sc129); }), ((size_t)n)) == 0) {
      if (sfx_start != NULL) {
        ((*sfx_start) = (end - n));
      }
      return ast__ast__BuiltinType_BT_U64;
    }
    if (((!hex) || hexf) && (memcmp(p, ({ __auto_type __sc130 = (str){ (const uint8_t *)"f32", sizeof("f32") - 1 }; str__ptr(&__sc130); }), ((size_t)n)) == 0)) {
      if (sfx_start != NULL) {
        ((*sfx_start) = (end - n));
      }
      return ast__ast__BuiltinType_BT_F32;
    }
    if (((!hex) || hexf) && (memcmp(p, ({ __auto_type __sc131 = (str){ (const uint8_t *)"f64", sizeof("f64") - 1 }; str__ptr(&__sc131); }), ((size_t)n)) == 0)) {
      if (sfx_start != NULL) {
        ((*sfx_start) = (end - n));
      }
      return ast__ast__BuiltinType_BT_F64;
    }
  }
  (n = 2U);
  if ((end - start) > n) {
    const uint8_t *const p = (src + ((size_t)(end - n)));
    if (memcmp(p, ({ __auto_type __sc132 = (str){ (const uint8_t *)"i8", sizeof("i8") - 1 }; str__ptr(&__sc132); }), ((size_t)n)) == 0) {
      if (sfx_start != NULL) {
        ((*sfx_start) = (end - n));
      }
      return ast__ast__BuiltinType_BT_I8;
    }
    if (memcmp(p, ({ __auto_type __sc133 = (str){ (const uint8_t *)"u8", sizeof("u8") - 1 }; str__ptr(&__sc133); }), ((size_t)n)) == 0) {
      if (sfx_start != NULL) {
        ((*sfx_start) = (end - n));
      }
      return ast__ast__BuiltinType_BT_U8;
    }
  }
  return ast__ast__BuiltinType_BT_COUNT;
}

