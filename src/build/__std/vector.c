#include "../__std/vector.h"
#include "../ast/ast.h"
#include "../__std/core.h"
#include "../__std/interfaces.h"
#include "../__std/option.h"
#include "../__std/range.h"
#include "../__std/result.h"
#include "../__std/slice.h"
#include "../__std/str.h"
#include "../__std/string.h"

_Static_assert(sizeof(Vector__String__Global__Global) == 24 && _Alignof(Vector__String__Global__Global) == 8, "super-c layout model mismatch: Vector__String__Global__Global");
_Static_assert(sizeof(VecIter__String__Global) == 24 && _Alignof(VecIter__String__Global) == 8, "super-c layout model mismatch: VecIter__String__Global");
_Static_assert(sizeof(Vector__u32__Global) == 24 && _Alignof(Vector__u32__Global) == 8, "super-c layout model mismatch: Vector__u32__Global");
_Static_assert(sizeof(VecIter__u32) == 24 && _Alignof(VecIter__u32) == 8, "super-c layout model mismatch: VecIter__u32");
_Static_assert(sizeof(Vector__bool__Global) == 24 && _Alignof(Vector__bool__Global) == 8, "super-c layout model mismatch: Vector__bool__Global");
_Static_assert(sizeof(VecIter__bool) == 24 && _Alignof(VecIter__bool) == 8, "super-c layout model mismatch: VecIter__bool");
_Static_assert(sizeof(Vector__Vector__bool__Global__Global) == 24 && _Alignof(Vector__Vector__bool__Global__Global) == 8, "super-c layout model mismatch: Vector__Vector__bool__Global__Global");
_Static_assert(sizeof(VecIter__Vector__bool__Global) == 24 && _Alignof(VecIter__Vector__bool__Global) == 8, "super-c layout model mismatch: VecIter__Vector__bool__Global");
_Static_assert(sizeof(Vector__u64__Global) == 24 && _Alignof(Vector__u64__Global) == 8, "super-c layout model mismatch: Vector__u64__Global");
_Static_assert(sizeof(VecIter__u64) == 24 && _Alignof(VecIter__u64) == 8, "super-c layout model mismatch: VecIter__u64");
_Static_assert(sizeof(Vector__Vector__String__Global__Global__Global) == 24 && _Alignof(Vector__Vector__String__Global__Global__Global) == 8, "super-c layout model mismatch: Vector__Vector__String__Global__Global__Global");
_Static_assert(sizeof(VecIter__Vector__String__Global__Global) == 24 && _Alignof(VecIter__Vector__String__Global__Global) == 8, "super-c layout model mismatch: VecIter__Vector__String__Global__Global");
_Static_assert(sizeof(Vector__u16__Global) == 24 && _Alignof(Vector__u16__Global) == 8, "super-c layout model mismatch: Vector__u16__Global");
_Static_assert(sizeof(VecIter__u16) == 24 && _Alignof(VecIter__u16) == 8, "super-c layout model mismatch: VecIter__u16");
_Static_assert(sizeof(Vector__usize__Global) == 24 && _Alignof(Vector__usize__Global) == 8, "super-c layout model mismatch: Vector__usize__Global");
_Static_assert(sizeof(VecIter__usize) == 24 && _Alignof(VecIter__usize) == 8, "super-c layout model mismatch: VecIter__usize");
_Static_assert(sizeof(Vector__Vector__u32__Global__Global) == 24 && _Alignof(Vector__Vector__u32__Global__Global) == 8, "super-c layout model mismatch: Vector__Vector__u32__Global__Global");
_Static_assert(sizeof(VecIter__Vector__u32__Global) == 24 && _Alignof(VecIter__Vector__u32__Global) == 8, "super-c layout model mismatch: VecIter__Vector__u32__Global");

static __attribute__((unused)) void Vector__String__Global__Global__sift_down(Vector__String__Global__Global *const self, size_t const root, size_t const end);
static __attribute__((unused)) void Vector__u32__Global__sift_down(Vector__u32__Global *const self, size_t const root, size_t const end);
static __attribute__((unused)) void Vector__bool__Global__sift_down(Vector__bool__Global *const self, size_t const root, size_t const end);
static __attribute__((unused)) void Vector__u64__Global__sift_down(Vector__u64__Global *const self, size_t const root, size_t const end);
static __attribute__((unused)) void Vector__u16__Global__sift_down(Vector__u16__Global *const self, size_t const root, size_t const end);
static __attribute__((unused)) void Vector__usize__Global__sift_down(Vector__usize__Global *const self, size_t const root, size_t const end);

Vector__String__Global__Global Vector__String__Global__Global__new_in(Global const alloc) {
  return (Vector__String__Global__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__String__Global__Global Vector__String__Global__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__String__Global__Global v = (Vector__String__Global__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((String__Global *)Global__alloc(&v.alloc, (cap * sizeof(String__Global)), _Alignof(String__Global))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__String__Global__Global__len(const Vector__String__Global__Global *const self) {
  return self->len;
}

void Vector__String__Global__Global__reserve(Vector__String__Global__Global *const self, size_t const additional) {
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
  String__Global *const p = ((String__Global *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(String__Global)), (new_cap * sizeof(String__Global)), _Alignof(String__Global)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__String__Global__Global__push(Vector__String__Global__Global *const self, String__Global value) {
  Vector__String__Global__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const String__Global *Vector__String__Global__Global__at(const Vector__String__Global__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_String__Global Vector__String__Global__Global__get(const Vector__String__Global__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_String__Global){ .tag = Option_None };
  }
  return (Option__ptr_String__Global){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__String__Global__Global__set(Vector__String__Global__Global *const self, size_t const index, String__Global value) {
  String__Global__free(&self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__String__Global__Global__clear(Vector__String__Global__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    String__Global__free(&self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__String__Global__Global__truncate(Vector__String__Global__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      String__Global__free(&self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const String__Global *Vector__String__Global__Global__as_ptr(const Vector__String__Global__Global *const self) {
  return self->ptr;
}

void Vector__String__Global__Global__swap(Vector__String__Global__Global *const self, size_t const i, size_t const j) {
  __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__String__Global__Global Vector__String__Global__Global__new(void) {
  return Vector__String__Global__Global__new_in(Global__default_());
}

void Vector__String__Global__Global__free(Vector__String__Global__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    String__Global__free(&self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(String__Global)), _Alignof(String__Global));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__String__Global__Global Vector__String__Global__Global__default_(void) {
  return Vector__String__Global__Global__new();
}

static __attribute__((unused)) void Vector__String__Global__Global__sift_down(Vector__String__Global__Global *const self, size_t const root, size_t const end) {
  size_t r = root;
  size_t child = ((2ULL * r) + 1ULL);
  while (child < end) {
    if (((child + 1ULL) < end) && (String__Global__cmp(&self->ptr[child], (&self->ptr[(child + 1ULL)])) < 0)) {
      (child = (child + 1ULL));
    }
    if (String__Global__cmp(&self->ptr[r], (&self->ptr[child])) >= 0) {
      return;
    }
    Vector__String__Global__Global__swap(self, r, child);
    (r = child);
    (child = ((2ULL * r) + 1ULL));
  }
}

const String__Global *Vector__String__Global__Global__index(const Vector__String__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__String__Global Vector__String__Global__Global__index_range(const Vector__String__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc0;
    if (r.inclusive) {
      __sc0 = (r.end + 1ULL);
    } else {
      __sc0 = r.end;
    }
    __sc0;
  });
  return (Slice__String__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

String__Global *Vector__String__Global__Global__index_mut(Vector__String__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__String__Global Vector__String__Global__Global__index_range_mut(Vector__String__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc1;
    if (r.inclusive) {
      __sc1 = (r.end + 1ULL);
    } else {
      __sc1 = r.end;
    }
    __sc1;
  });
  return (SliceMut__String__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__String__Global__Global Vector__String__Global__Global__clone(const Vector__String__Global__Global *const self) {
  Vector__String__Global__Global out = Vector__String__Global__Global__with_capacity_in(self->alloc, Vector__String__Global__Global__len(self));
  for (size_t i = 0ULL; i < Vector__String__Global__Global__len(self); i++) {
    const String__Global *const e = Vector__String__Global__Global__at(self, i);
    Vector__String__Global__Global__push(&out, String__Global__clone(e));
  }
  return out;
}

bool Vector__String__Global__Global__eq(const Vector__String__Global__Global *const self, const Vector__String__Global__Global *const other) {
  if (Vector__String__Global__Global__len(self) != Vector__String__Global__Global__len(other)) {
    return false;
  }
  for (size_t i = 0ULL; i < Vector__String__Global__Global__len(self); i++) {
    const String__Global *const a = Vector__String__Global__Global__at(self, i);
    const String__Global *const b = Vector__String__Global__Global__at(other, i);
    if (!String__Global__eq(a, b)) {
      return false;
    }
  }
  return true;
}

uint64_t Vector__String__Global__Global__hash(const Vector__String__Global__Global *const self) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < Vector__String__Global__Global__len(self); i++) {
    const String__Global *const e = Vector__String__Global__Global__at(self, i);
    (h = ((h ^ String__Global__hash(e)) * 0x100000001b3ULL));
  }
  return h;
}

String__Global Vector__String__Global__Global__fmt(const Vector__String__Global__Global *const self) {
  String__Global s = String__Global__from_str((str){ (const uint8_t *)"[", sizeof("[") - 1 });
  for (size_t i = 0ULL; i < Vector__String__Global__Global__len(self); i++) {
    if (i > 0ULL) {
      String__Global__push_str(&s, (str){ (const uint8_t *)", ", sizeof(", ") - 1 });
    }
    const String__Global *const e = Vector__String__Global__Global__at(self, i);
    String__Global es = String__Global__fmt(e);
    String__Global__push_string(&s, (&es));
    String__Global__free(&es);
  }
  String__Global__push_str(&s, (str){ (const uint8_t *)"]", sizeof("]") - 1 });
  return s;
}

Option__ptr_String__Global VecIter__String__Global__next(VecIter__String__Global *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_String__Global__none();
  }
  const String__Global *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_String__Global__some(r);
}

Vector__u32__Global Vector__u32__Global__new_in(Global const alloc) {
  return (Vector__u32__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__u32__Global Vector__u32__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__u32__Global v = (Vector__u32__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((uint32_t *)Global__alloc(&v.alloc, (cap * sizeof(uint32_t)), _Alignof(uint32_t))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__u32__Global__len(const Vector__u32__Global *const self) {
  return self->len;
}

void Vector__u32__Global__reserve(Vector__u32__Global *const self, size_t const additional) {
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
  uint32_t *const p = ((uint32_t *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(uint32_t)), (new_cap * sizeof(uint32_t)), _Alignof(uint32_t)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__u32__Global__push(Vector__u32__Global *const self, uint32_t const value) {
  Vector__u32__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const uint32_t *Vector__u32__Global__at(const Vector__u32__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_u32 Vector__u32__Global__get(const Vector__u32__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_u32){ .tag = Option_None };
  }
  return (Option__ptr_u32){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__u32__Global__set(Vector__u32__Global *const self, size_t const index, uint32_t const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__u32__Global__clear(Vector__u32__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__u32__Global__truncate(Vector__u32__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const uint32_t *Vector__u32__Global__as_ptr(const Vector__u32__Global *const self) {
  return self->ptr;
}

void Vector__u32__Global__swap(Vector__u32__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__u32__Global Vector__u32__Global__new(void) {
  return Vector__u32__Global__new_in(Global__default_());
}

void Vector__u32__Global__free(Vector__u32__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(uint32_t)), _Alignof(uint32_t));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__u32__Global Vector__u32__Global__default_(void) {
  return Vector__u32__Global__new();
}

static __attribute__((unused)) void Vector__u32__Global__sift_down(Vector__u32__Global *const self, size_t const root, size_t const end) {
  size_t r = root;
  size_t child = ((2ULL * r) + 1ULL);
  while (child < end) {
    if (((child + 1ULL) < end) && (u32__cmp(&self->ptr[child], (&self->ptr[(child + 1ULL)])) < 0)) {
      (child = (child + 1ULL));
    }
    if (u32__cmp(&self->ptr[r], (&self->ptr[child])) >= 0) {
      return;
    }
    Vector__u32__Global__swap(self, r, child);
    (r = child);
    (child = ((2ULL * r) + 1ULL));
  }
}

const uint32_t *Vector__u32__Global__index(const Vector__u32__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__u32 Vector__u32__Global__index_range(const Vector__u32__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc2;
    if (r.inclusive) {
      __sc2 = (r.end + 1ULL);
    } else {
      __sc2 = r.end;
    }
    __sc2;
  });
  return (Slice__u32){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

uint32_t *Vector__u32__Global__index_mut(Vector__u32__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__u32 Vector__u32__Global__index_range_mut(Vector__u32__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc3;
    if (r.inclusive) {
      __sc3 = (r.end + 1ULL);
    } else {
      __sc3 = r.end;
    }
    __sc3;
  });
  return (SliceMut__u32){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__u32__Global Vector__u32__Global__clone(const Vector__u32__Global *const self) {
  Vector__u32__Global out = Vector__u32__Global__with_capacity_in(self->alloc, Vector__u32__Global__len(self));
  for (size_t i = 0ULL; i < Vector__u32__Global__len(self); i++) {
    const uint32_t *const e = Vector__u32__Global__at(self, i);
    Vector__u32__Global__push(&out, u32__clone(e));
  }
  return out;
}

bool Vector__u32__Global__eq(const Vector__u32__Global *const self, const Vector__u32__Global *const other) {
  if (Vector__u32__Global__len(self) != Vector__u32__Global__len(other)) {
    return false;
  }
  for (size_t i = 0ULL; i < Vector__u32__Global__len(self); i++) {
    const uint32_t *const a = Vector__u32__Global__at(self, i);
    const uint32_t *const b = Vector__u32__Global__at(other, i);
    if (!u32__eq(a, b)) {
      return false;
    }
  }
  return true;
}

uint64_t Vector__u32__Global__hash(const Vector__u32__Global *const self) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < Vector__u32__Global__len(self); i++) {
    const uint32_t *const e = Vector__u32__Global__at(self, i);
    (h = ((h ^ u32__hash(e)) * 0x100000001b3ULL));
  }
  return h;
}

Option__ptr_u32 VecIter__u32__next(VecIter__u32 *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_u32__none();
  }
  const uint32_t *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_u32__some(r);
}

Vector__bool__Global Vector__bool__Global__new_in(Global const alloc) {
  return (Vector__bool__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__bool__Global Vector__bool__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__bool__Global v = (Vector__bool__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((bool *)Global__alloc(&v.alloc, (cap * sizeof(bool)), _Alignof(bool))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__bool__Global__len(const Vector__bool__Global *const self) {
  return self->len;
}

void Vector__bool__Global__reserve(Vector__bool__Global *const self, size_t const additional) {
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
  bool *const p = ((bool *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(bool)), (new_cap * sizeof(bool)), _Alignof(bool)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__bool__Global__push(Vector__bool__Global *const self, bool const value) {
  Vector__bool__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const bool *Vector__bool__Global__at(const Vector__bool__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_bool Vector__bool__Global__get(const Vector__bool__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_bool){ .tag = Option_None };
  }
  return (Option__ptr_bool){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__bool__Global__set(Vector__bool__Global *const self, size_t const index, bool const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__bool__Global__clear(Vector__bool__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__bool__Global__truncate(Vector__bool__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const bool *Vector__bool__Global__as_ptr(const Vector__bool__Global *const self) {
  return self->ptr;
}

void Vector__bool__Global__swap(Vector__bool__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__bool__Global Vector__bool__Global__new(void) {
  return Vector__bool__Global__new_in(Global__default_());
}

void Vector__bool__Global__free(Vector__bool__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(bool)), _Alignof(bool));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__bool__Global Vector__bool__Global__default_(void) {
  return Vector__bool__Global__new();
}

static __attribute__((unused)) void Vector__bool__Global__sift_down(Vector__bool__Global *const self, size_t const root, size_t const end) {
  size_t r = root;
  size_t child = ((2ULL * r) + 1ULL);
  while (child < end) {
    if (((child + 1ULL) < end) && (bool__cmp(&self->ptr[child], (&self->ptr[(child + 1ULL)])) < 0)) {
      (child = (child + 1ULL));
    }
    if (bool__cmp(&self->ptr[r], (&self->ptr[child])) >= 0) {
      return;
    }
    Vector__bool__Global__swap(self, r, child);
    (r = child);
    (child = ((2ULL * r) + 1ULL));
  }
}

const bool *Vector__bool__Global__index(const Vector__bool__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__bool Vector__bool__Global__index_range(const Vector__bool__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc4;
    if (r.inclusive) {
      __sc4 = (r.end + 1ULL);
    } else {
      __sc4 = r.end;
    }
    __sc4;
  });
  return (Slice__bool){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

bool *Vector__bool__Global__index_mut(Vector__bool__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__bool Vector__bool__Global__index_range_mut(Vector__bool__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc5;
    if (r.inclusive) {
      __sc5 = (r.end + 1ULL);
    } else {
      __sc5 = r.end;
    }
    __sc5;
  });
  return (SliceMut__bool){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__bool__Global Vector__bool__Global__clone(const Vector__bool__Global *const self) {
  Vector__bool__Global out = Vector__bool__Global__with_capacity_in(self->alloc, Vector__bool__Global__len(self));
  for (size_t i = 0ULL; i < Vector__bool__Global__len(self); i++) {
    const bool *const e = Vector__bool__Global__at(self, i);
    Vector__bool__Global__push(&out, bool__clone(e));
  }
  return out;
}

bool Vector__bool__Global__eq(const Vector__bool__Global *const self, const Vector__bool__Global *const other) {
  if (Vector__bool__Global__len(self) != Vector__bool__Global__len(other)) {
    return false;
  }
  for (size_t i = 0ULL; i < Vector__bool__Global__len(self); i++) {
    const bool *const a = Vector__bool__Global__at(self, i);
    const bool *const b = Vector__bool__Global__at(other, i);
    if (!bool__eq(a, b)) {
      return false;
    }
  }
  return true;
}

uint64_t Vector__bool__Global__hash(const Vector__bool__Global *const self) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < Vector__bool__Global__len(self); i++) {
    const bool *const e = Vector__bool__Global__at(self, i);
    (h = ((h ^ bool__hash(e)) * 0x100000001b3ULL));
  }
  return h;
}

Option__ptr_bool VecIter__bool__next(VecIter__bool *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_bool__none();
  }
  const bool *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_bool__some(r);
}

Vector__Vector__bool__Global__Global Vector__Vector__bool__Global__Global__new_in(Global const alloc) {
  return (Vector__Vector__bool__Global__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__Vector__bool__Global__Global Vector__Vector__bool__Global__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__Vector__bool__Global__Global v = (Vector__Vector__bool__Global__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((Vector__bool__Global *)Global__alloc(&v.alloc, (cap * sizeof(Vector__bool__Global)), _Alignof(Vector__bool__Global))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__Vector__bool__Global__Global__len(const Vector__Vector__bool__Global__Global *const self) {
  return self->len;
}

void Vector__Vector__bool__Global__Global__reserve(Vector__Vector__bool__Global__Global *const self, size_t const additional) {
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
  Vector__bool__Global *const p = ((Vector__bool__Global *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(Vector__bool__Global)), (new_cap * sizeof(Vector__bool__Global)), _Alignof(Vector__bool__Global)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__Vector__bool__Global__Global__push(Vector__Vector__bool__Global__Global *const self, Vector__bool__Global value) {
  Vector__Vector__bool__Global__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const Vector__bool__Global *Vector__Vector__bool__Global__Global__at(const Vector__Vector__bool__Global__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_Vector__bool__Global Vector__Vector__bool__Global__Global__get(const Vector__Vector__bool__Global__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_Vector__bool__Global){ .tag = Option_None };
  }
  return (Option__ptr_Vector__bool__Global){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__Vector__bool__Global__Global__set(Vector__Vector__bool__Global__Global *const self, size_t const index, Vector__bool__Global value) {
  Vector__bool__Global__free(&self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__Vector__bool__Global__Global__clear(Vector__Vector__bool__Global__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    Vector__bool__Global__free(&self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__Vector__bool__Global__Global__truncate(Vector__Vector__bool__Global__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      Vector__bool__Global__free(&self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const Vector__bool__Global *Vector__Vector__bool__Global__Global__as_ptr(const Vector__Vector__bool__Global__Global *const self) {
  return self->ptr;
}

void Vector__Vector__bool__Global__Global__swap(Vector__Vector__bool__Global__Global *const self, size_t const i, size_t const j) {
  __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__Vector__bool__Global__Global Vector__Vector__bool__Global__Global__new(void) {
  return Vector__Vector__bool__Global__Global__new_in(Global__default_());
}

void Vector__Vector__bool__Global__Global__free(Vector__Vector__bool__Global__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    Vector__bool__Global__free(&self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(Vector__bool__Global)), _Alignof(Vector__bool__Global));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__Vector__bool__Global__Global Vector__Vector__bool__Global__Global__default_(void) {
  return Vector__Vector__bool__Global__Global__new();
}

const Vector__bool__Global *Vector__Vector__bool__Global__Global__index(const Vector__Vector__bool__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Vector__bool__Global Vector__Vector__bool__Global__Global__index_range(const Vector__Vector__bool__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc6;
    if (r.inclusive) {
      __sc6 = (r.end + 1ULL);
    } else {
      __sc6 = r.end;
    }
    __sc6;
  });
  return (Slice__Vector__bool__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__bool__Global *Vector__Vector__bool__Global__Global__index_mut(Vector__Vector__bool__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__Vector__bool__Global Vector__Vector__bool__Global__Global__index_range_mut(Vector__Vector__bool__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc7;
    if (r.inclusive) {
      __sc7 = (r.end + 1ULL);
    } else {
      __sc7 = r.end;
    }
    __sc7;
  });
  return (SliceMut__Vector__bool__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__Vector__bool__Global__Global Vector__Vector__bool__Global__Global__clone(const Vector__Vector__bool__Global__Global *const self) {
  Vector__Vector__bool__Global__Global out = Vector__Vector__bool__Global__Global__with_capacity_in(self->alloc, Vector__Vector__bool__Global__Global__len(self));
  for (size_t i = 0ULL; i < Vector__Vector__bool__Global__Global__len(self); i++) {
    const Vector__bool__Global *const e = Vector__Vector__bool__Global__Global__at(self, i);
    Vector__Vector__bool__Global__Global__push(&out, Vector__bool__Global__clone(e));
  }
  return out;
}

bool Vector__Vector__bool__Global__Global__eq(const Vector__Vector__bool__Global__Global *const self, const Vector__Vector__bool__Global__Global *const other) {
  if (Vector__Vector__bool__Global__Global__len(self) != Vector__Vector__bool__Global__Global__len(other)) {
    return false;
  }
  for (size_t i = 0ULL; i < Vector__Vector__bool__Global__Global__len(self); i++) {
    const Vector__bool__Global *const a = Vector__Vector__bool__Global__Global__at(self, i);
    const Vector__bool__Global *const b = Vector__Vector__bool__Global__Global__at(other, i);
    if (!Vector__bool__Global__eq(a, b)) {
      return false;
    }
  }
  return true;
}

uint64_t Vector__Vector__bool__Global__Global__hash(const Vector__Vector__bool__Global__Global *const self) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < Vector__Vector__bool__Global__Global__len(self); i++) {
    const Vector__bool__Global *const e = Vector__Vector__bool__Global__Global__at(self, i);
    (h = ((h ^ Vector__bool__Global__hash(e)) * 0x100000001b3ULL));
  }
  return h;
}

Option__ptr_Vector__bool__Global VecIter__Vector__bool__Global__next(VecIter__Vector__bool__Global *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_Vector__bool__Global__none();
  }
  const Vector__bool__Global *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_Vector__bool__Global__some(r);
}

Vector__u64__Global Vector__u64__Global__new_in(Global const alloc) {
  return (Vector__u64__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__u64__Global Vector__u64__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__u64__Global v = (Vector__u64__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((uint64_t *)Global__alloc(&v.alloc, (cap * sizeof(uint64_t)), _Alignof(uint64_t))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__u64__Global__len(const Vector__u64__Global *const self) {
  return self->len;
}

void Vector__u64__Global__reserve(Vector__u64__Global *const self, size_t const additional) {
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
  uint64_t *const p = ((uint64_t *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(uint64_t)), (new_cap * sizeof(uint64_t)), _Alignof(uint64_t)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__u64__Global__push(Vector__u64__Global *const self, uint64_t const value) {
  Vector__u64__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const uint64_t *Vector__u64__Global__at(const Vector__u64__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_u64 Vector__u64__Global__get(const Vector__u64__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_u64){ .tag = Option_None };
  }
  return (Option__ptr_u64){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__u64__Global__set(Vector__u64__Global *const self, size_t const index, uint64_t const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__u64__Global__clear(Vector__u64__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__u64__Global__truncate(Vector__u64__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const uint64_t *Vector__u64__Global__as_ptr(const Vector__u64__Global *const self) {
  return self->ptr;
}

void Vector__u64__Global__swap(Vector__u64__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__u64__Global Vector__u64__Global__new(void) {
  return Vector__u64__Global__new_in(Global__default_());
}

void Vector__u64__Global__free(Vector__u64__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(uint64_t)), _Alignof(uint64_t));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__u64__Global Vector__u64__Global__default_(void) {
  return Vector__u64__Global__new();
}

static __attribute__((unused)) void Vector__u64__Global__sift_down(Vector__u64__Global *const self, size_t const root, size_t const end) {
  size_t r = root;
  size_t child = ((2ULL * r) + 1ULL);
  while (child < end) {
    if (((child + 1ULL) < end) && (u64__cmp(&self->ptr[child], (&self->ptr[(child + 1ULL)])) < 0)) {
      (child = (child + 1ULL));
    }
    if (u64__cmp(&self->ptr[r], (&self->ptr[child])) >= 0) {
      return;
    }
    Vector__u64__Global__swap(self, r, child);
    (r = child);
    (child = ((2ULL * r) + 1ULL));
  }
}

const uint64_t *Vector__u64__Global__index(const Vector__u64__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__u64 Vector__u64__Global__index_range(const Vector__u64__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc8;
    if (r.inclusive) {
      __sc8 = (r.end + 1ULL);
    } else {
      __sc8 = r.end;
    }
    __sc8;
  });
  return (Slice__u64){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

uint64_t *Vector__u64__Global__index_mut(Vector__u64__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__u64 Vector__u64__Global__index_range_mut(Vector__u64__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc9;
    if (r.inclusive) {
      __sc9 = (r.end + 1ULL);
    } else {
      __sc9 = r.end;
    }
    __sc9;
  });
  return (SliceMut__u64){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__u64__Global Vector__u64__Global__clone(const Vector__u64__Global *const self) {
  Vector__u64__Global out = Vector__u64__Global__with_capacity_in(self->alloc, Vector__u64__Global__len(self));
  for (size_t i = 0ULL; i < Vector__u64__Global__len(self); i++) {
    const uint64_t *const e = Vector__u64__Global__at(self, i);
    Vector__u64__Global__push(&out, u64__clone(e));
  }
  return out;
}

bool Vector__u64__Global__eq(const Vector__u64__Global *const self, const Vector__u64__Global *const other) {
  if (Vector__u64__Global__len(self) != Vector__u64__Global__len(other)) {
    return false;
  }
  for (size_t i = 0ULL; i < Vector__u64__Global__len(self); i++) {
    const uint64_t *const a = Vector__u64__Global__at(self, i);
    const uint64_t *const b = Vector__u64__Global__at(other, i);
    if (!u64__eq(a, b)) {
      return false;
    }
  }
  return true;
}

uint64_t Vector__u64__Global__hash(const Vector__u64__Global *const self) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < Vector__u64__Global__len(self); i++) {
    const uint64_t *const e = Vector__u64__Global__at(self, i);
    (h = ((h ^ u64__hash(e)) * 0x100000001b3ULL));
  }
  return h;
}

Option__ptr_u64 VecIter__u64__next(VecIter__u64 *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_u64__none();
  }
  const uint64_t *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_u64__some(r);
}

Vector__Vector__String__Global__Global__Global Vector__Vector__String__Global__Global__Global__new_in(Global const alloc) {
  return (Vector__Vector__String__Global__Global__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__Vector__String__Global__Global__Global Vector__Vector__String__Global__Global__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__Vector__String__Global__Global__Global v = (Vector__Vector__String__Global__Global__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((Vector__String__Global__Global *)Global__alloc(&v.alloc, (cap * sizeof(Vector__String__Global__Global)), _Alignof(Vector__String__Global__Global))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__Vector__String__Global__Global__Global__len(const Vector__Vector__String__Global__Global__Global *const self) {
  return self->len;
}

void Vector__Vector__String__Global__Global__Global__reserve(Vector__Vector__String__Global__Global__Global *const self, size_t const additional) {
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
  Vector__String__Global__Global *const p = ((Vector__String__Global__Global *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(Vector__String__Global__Global)), (new_cap * sizeof(Vector__String__Global__Global)), _Alignof(Vector__String__Global__Global)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__Vector__String__Global__Global__Global__push(Vector__Vector__String__Global__Global__Global *const self, Vector__String__Global__Global value) {
  Vector__Vector__String__Global__Global__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const Vector__String__Global__Global *Vector__Vector__String__Global__Global__Global__at(const Vector__Vector__String__Global__Global__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_Vector__String__Global__Global Vector__Vector__String__Global__Global__Global__get(const Vector__Vector__String__Global__Global__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_Vector__String__Global__Global){ .tag = Option_None };
  }
  return (Option__ptr_Vector__String__Global__Global){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__Vector__String__Global__Global__Global__set(Vector__Vector__String__Global__Global__Global *const self, size_t const index, Vector__String__Global__Global value) {
  Vector__String__Global__Global__free(&self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__Vector__String__Global__Global__Global__clear(Vector__Vector__String__Global__Global__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    Vector__String__Global__Global__free(&self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__Vector__String__Global__Global__Global__truncate(Vector__Vector__String__Global__Global__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      Vector__String__Global__Global__free(&self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const Vector__String__Global__Global *Vector__Vector__String__Global__Global__Global__as_ptr(const Vector__Vector__String__Global__Global__Global *const self) {
  return self->ptr;
}

void Vector__Vector__String__Global__Global__Global__swap(Vector__Vector__String__Global__Global__Global *const self, size_t const i, size_t const j) {
  __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__Vector__String__Global__Global__Global Vector__Vector__String__Global__Global__Global__new(void) {
  return Vector__Vector__String__Global__Global__Global__new_in(Global__default_());
}

void Vector__Vector__String__Global__Global__Global__free(Vector__Vector__String__Global__Global__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    Vector__String__Global__Global__free(&self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(Vector__String__Global__Global)), _Alignof(Vector__String__Global__Global));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__Vector__String__Global__Global__Global Vector__Vector__String__Global__Global__Global__default_(void) {
  return Vector__Vector__String__Global__Global__Global__new();
}

const Vector__String__Global__Global *Vector__Vector__String__Global__Global__Global__index(const Vector__Vector__String__Global__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Vector__String__Global__Global Vector__Vector__String__Global__Global__Global__index_range(const Vector__Vector__String__Global__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc10;
    if (r.inclusive) {
      __sc10 = (r.end + 1ULL);
    } else {
      __sc10 = r.end;
    }
    __sc10;
  });
  return (Slice__Vector__String__Global__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__String__Global__Global *Vector__Vector__String__Global__Global__Global__index_mut(Vector__Vector__String__Global__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__Vector__String__Global__Global Vector__Vector__String__Global__Global__Global__index_range_mut(Vector__Vector__String__Global__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc11;
    if (r.inclusive) {
      __sc11 = (r.end + 1ULL);
    } else {
      __sc11 = r.end;
    }
    __sc11;
  });
  return (SliceMut__Vector__String__Global__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__Vector__String__Global__Global__Global Vector__Vector__String__Global__Global__Global__clone(const Vector__Vector__String__Global__Global__Global *const self) {
  Vector__Vector__String__Global__Global__Global out = Vector__Vector__String__Global__Global__Global__with_capacity_in(self->alloc, Vector__Vector__String__Global__Global__Global__len(self));
  for (size_t i = 0ULL; i < Vector__Vector__String__Global__Global__Global__len(self); i++) {
    const Vector__String__Global__Global *const e = Vector__Vector__String__Global__Global__Global__at(self, i);
    Vector__Vector__String__Global__Global__Global__push(&out, Vector__String__Global__Global__clone(e));
  }
  return out;
}

bool Vector__Vector__String__Global__Global__Global__eq(const Vector__Vector__String__Global__Global__Global *const self, const Vector__Vector__String__Global__Global__Global *const other) {
  if (Vector__Vector__String__Global__Global__Global__len(self) != Vector__Vector__String__Global__Global__Global__len(other)) {
    return false;
  }
  for (size_t i = 0ULL; i < Vector__Vector__String__Global__Global__Global__len(self); i++) {
    const Vector__String__Global__Global *const a = Vector__Vector__String__Global__Global__Global__at(self, i);
    const Vector__String__Global__Global *const b = Vector__Vector__String__Global__Global__Global__at(other, i);
    if (!Vector__String__Global__Global__eq(a, b)) {
      return false;
    }
  }
  return true;
}

uint64_t Vector__Vector__String__Global__Global__Global__hash(const Vector__Vector__String__Global__Global__Global *const self) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < Vector__Vector__String__Global__Global__Global__len(self); i++) {
    const Vector__String__Global__Global *const e = Vector__Vector__String__Global__Global__Global__at(self, i);
    (h = ((h ^ Vector__String__Global__Global__hash(e)) * 0x100000001b3ULL));
  }
  return h;
}

String__Global Vector__Vector__String__Global__Global__Global__fmt(const Vector__Vector__String__Global__Global__Global *const self) {
  String__Global s = String__Global__from_str((str){ (const uint8_t *)"[", sizeof("[") - 1 });
  for (size_t i = 0ULL; i < Vector__Vector__String__Global__Global__Global__len(self); i++) {
    if (i > 0ULL) {
      String__Global__push_str(&s, (str){ (const uint8_t *)", ", sizeof(", ") - 1 });
    }
    const Vector__String__Global__Global *const e = Vector__Vector__String__Global__Global__Global__at(self, i);
    String__Global es = Vector__String__Global__Global__fmt(e);
    String__Global__push_string(&s, (&es));
    String__Global__free(&es);
  }
  String__Global__push_str(&s, (str){ (const uint8_t *)"]", sizeof("]") - 1 });
  return s;
}

Option__ptr_Vector__String__Global__Global VecIter__Vector__String__Global__Global__next(VecIter__Vector__String__Global__Global *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_Vector__String__Global__Global__none();
  }
  const Vector__String__Global__Global *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_Vector__String__Global__Global__some(r);
}

Vector__u16__Global Vector__u16__Global__new_in(Global const alloc) {
  return (Vector__u16__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__u16__Global Vector__u16__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__u16__Global v = (Vector__u16__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((uint16_t *)Global__alloc(&v.alloc, (cap * sizeof(uint16_t)), _Alignof(uint16_t))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__u16__Global__len(const Vector__u16__Global *const self) {
  return self->len;
}

void Vector__u16__Global__reserve(Vector__u16__Global *const self, size_t const additional) {
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
  uint16_t *const p = ((uint16_t *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(uint16_t)), (new_cap * sizeof(uint16_t)), _Alignof(uint16_t)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__u16__Global__push(Vector__u16__Global *const self, uint16_t const value) {
  Vector__u16__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const uint16_t *Vector__u16__Global__at(const Vector__u16__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_u16 Vector__u16__Global__get(const Vector__u16__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_u16){ .tag = Option_None };
  }
  return (Option__ptr_u16){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__u16__Global__set(Vector__u16__Global *const self, size_t const index, uint16_t const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__u16__Global__clear(Vector__u16__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__u16__Global__truncate(Vector__u16__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const uint16_t *Vector__u16__Global__as_ptr(const Vector__u16__Global *const self) {
  return self->ptr;
}

void Vector__u16__Global__swap(Vector__u16__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__u16__Global Vector__u16__Global__new(void) {
  return Vector__u16__Global__new_in(Global__default_());
}

void Vector__u16__Global__free(Vector__u16__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(uint16_t)), _Alignof(uint16_t));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__u16__Global Vector__u16__Global__default_(void) {
  return Vector__u16__Global__new();
}

static __attribute__((unused)) void Vector__u16__Global__sift_down(Vector__u16__Global *const self, size_t const root, size_t const end) {
  size_t r = root;
  size_t child = ((2ULL * r) + 1ULL);
  while (child < end) {
    if (((child + 1ULL) < end) && (u16__cmp(&self->ptr[child], (&self->ptr[(child + 1ULL)])) < 0)) {
      (child = (child + 1ULL));
    }
    if (u16__cmp(&self->ptr[r], (&self->ptr[child])) >= 0) {
      return;
    }
    Vector__u16__Global__swap(self, r, child);
    (r = child);
    (child = ((2ULL * r) + 1ULL));
  }
}

const uint16_t *Vector__u16__Global__index(const Vector__u16__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__u16 Vector__u16__Global__index_range(const Vector__u16__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc12;
    if (r.inclusive) {
      __sc12 = (r.end + 1ULL);
    } else {
      __sc12 = r.end;
    }
    __sc12;
  });
  return (Slice__u16){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

uint16_t *Vector__u16__Global__index_mut(Vector__u16__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__u16 Vector__u16__Global__index_range_mut(Vector__u16__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc13;
    if (r.inclusive) {
      __sc13 = (r.end + 1ULL);
    } else {
      __sc13 = r.end;
    }
    __sc13;
  });
  return (SliceMut__u16){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__u16__Global Vector__u16__Global__clone(const Vector__u16__Global *const self) {
  Vector__u16__Global out = Vector__u16__Global__with_capacity_in(self->alloc, Vector__u16__Global__len(self));
  for (size_t i = 0ULL; i < Vector__u16__Global__len(self); i++) {
    const uint16_t *const e = Vector__u16__Global__at(self, i);
    Vector__u16__Global__push(&out, u16__clone(e));
  }
  return out;
}

bool Vector__u16__Global__eq(const Vector__u16__Global *const self, const Vector__u16__Global *const other) {
  if (Vector__u16__Global__len(self) != Vector__u16__Global__len(other)) {
    return false;
  }
  for (size_t i = 0ULL; i < Vector__u16__Global__len(self); i++) {
    const uint16_t *const a = Vector__u16__Global__at(self, i);
    const uint16_t *const b = Vector__u16__Global__at(other, i);
    if (!u16__eq(a, b)) {
      return false;
    }
  }
  return true;
}

uint64_t Vector__u16__Global__hash(const Vector__u16__Global *const self) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < Vector__u16__Global__len(self); i++) {
    const uint16_t *const e = Vector__u16__Global__at(self, i);
    (h = ((h ^ u16__hash(e)) * 0x100000001b3ULL));
  }
  return h;
}

Option__ptr_u16 VecIter__u16__next(VecIter__u16 *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_u16__none();
  }
  const uint16_t *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_u16__some(r);
}

Vector__usize__Global Vector__usize__Global__new_in(Global const alloc) {
  return (Vector__usize__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__usize__Global Vector__usize__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__usize__Global v = (Vector__usize__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((size_t *)Global__alloc(&v.alloc, (cap * sizeof(size_t)), _Alignof(size_t))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__usize__Global__len(const Vector__usize__Global *const self) {
  return self->len;
}

void Vector__usize__Global__reserve(Vector__usize__Global *const self, size_t const additional) {
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
  size_t *const p = ((size_t *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(size_t)), (new_cap * sizeof(size_t)), _Alignof(size_t)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__usize__Global__push(Vector__usize__Global *const self, size_t const value) {
  Vector__usize__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const size_t *Vector__usize__Global__at(const Vector__usize__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_usize Vector__usize__Global__get(const Vector__usize__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_usize){ .tag = Option_None };
  }
  return (Option__ptr_usize){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__usize__Global__set(Vector__usize__Global *const self, size_t const index, size_t const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__usize__Global__clear(Vector__usize__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__usize__Global__truncate(Vector__usize__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const size_t *Vector__usize__Global__as_ptr(const Vector__usize__Global *const self) {
  return self->ptr;
}

void Vector__usize__Global__swap(Vector__usize__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__usize__Global Vector__usize__Global__new(void) {
  return Vector__usize__Global__new_in(Global__default_());
}

void Vector__usize__Global__free(Vector__usize__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(size_t)), _Alignof(size_t));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__usize__Global Vector__usize__Global__default_(void) {
  return Vector__usize__Global__new();
}

static __attribute__((unused)) void Vector__usize__Global__sift_down(Vector__usize__Global *const self, size_t const root, size_t const end) {
  size_t r = root;
  size_t child = ((2ULL * r) + 1ULL);
  while (child < end) {
    if (((child + 1ULL) < end) && (usize__cmp(&self->ptr[child], (&self->ptr[(child + 1ULL)])) < 0)) {
      (child = (child + 1ULL));
    }
    if (usize__cmp(&self->ptr[r], (&self->ptr[child])) >= 0) {
      return;
    }
    Vector__usize__Global__swap(self, r, child);
    (r = child);
    (child = ((2ULL * r) + 1ULL));
  }
}

const size_t *Vector__usize__Global__index(const Vector__usize__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__usize Vector__usize__Global__index_range(const Vector__usize__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc14;
    if (r.inclusive) {
      __sc14 = (r.end + 1ULL);
    } else {
      __sc14 = r.end;
    }
    __sc14;
  });
  return (Slice__usize){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t *Vector__usize__Global__index_mut(Vector__usize__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__usize Vector__usize__Global__index_range_mut(Vector__usize__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc15;
    if (r.inclusive) {
      __sc15 = (r.end + 1ULL);
    } else {
      __sc15 = r.end;
    }
    __sc15;
  });
  return (SliceMut__usize){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__usize__Global Vector__usize__Global__clone(const Vector__usize__Global *const self) {
  Vector__usize__Global out = Vector__usize__Global__with_capacity_in(self->alloc, Vector__usize__Global__len(self));
  for (size_t i = 0ULL; i < Vector__usize__Global__len(self); i++) {
    const size_t *const e = Vector__usize__Global__at(self, i);
    Vector__usize__Global__push(&out, usize__clone(e));
  }
  return out;
}

bool Vector__usize__Global__eq(const Vector__usize__Global *const self, const Vector__usize__Global *const other) {
  if (Vector__usize__Global__len(self) != Vector__usize__Global__len(other)) {
    return false;
  }
  for (size_t i = 0ULL; i < Vector__usize__Global__len(self); i++) {
    const size_t *const a = Vector__usize__Global__at(self, i);
    const size_t *const b = Vector__usize__Global__at(other, i);
    if (!usize__eq(a, b)) {
      return false;
    }
  }
  return true;
}

uint64_t Vector__usize__Global__hash(const Vector__usize__Global *const self) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < Vector__usize__Global__len(self); i++) {
    const size_t *const e = Vector__usize__Global__at(self, i);
    (h = ((h ^ usize__hash(e)) * 0x100000001b3ULL));
  }
  return h;
}

Option__ptr_usize VecIter__usize__next(VecIter__usize *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_usize__none();
  }
  const size_t *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_usize__some(r);
}

Vector__Vector__u32__Global__Global Vector__Vector__u32__Global__Global__new_in(Global const alloc) {
  return (Vector__Vector__u32__Global__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__Vector__u32__Global__Global Vector__Vector__u32__Global__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__Vector__u32__Global__Global v = (Vector__Vector__u32__Global__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((Vector__u32__Global *)Global__alloc(&v.alloc, (cap * sizeof(Vector__u32__Global)), _Alignof(Vector__u32__Global))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__Vector__u32__Global__Global__len(const Vector__Vector__u32__Global__Global *const self) {
  return self->len;
}

void Vector__Vector__u32__Global__Global__reserve(Vector__Vector__u32__Global__Global *const self, size_t const additional) {
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
  Vector__u32__Global *const p = ((Vector__u32__Global *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(Vector__u32__Global)), (new_cap * sizeof(Vector__u32__Global)), _Alignof(Vector__u32__Global)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__Vector__u32__Global__Global__push(Vector__Vector__u32__Global__Global *const self, Vector__u32__Global value) {
  Vector__Vector__u32__Global__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const Vector__u32__Global *Vector__Vector__u32__Global__Global__at(const Vector__Vector__u32__Global__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_Vector__u32__Global Vector__Vector__u32__Global__Global__get(const Vector__Vector__u32__Global__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_Vector__u32__Global){ .tag = Option_None };
  }
  return (Option__ptr_Vector__u32__Global){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__Vector__u32__Global__Global__set(Vector__Vector__u32__Global__Global *const self, size_t const index, Vector__u32__Global value) {
  Vector__u32__Global__free(&self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__Vector__u32__Global__Global__clear(Vector__Vector__u32__Global__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    Vector__u32__Global__free(&self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__Vector__u32__Global__Global__truncate(Vector__Vector__u32__Global__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      Vector__u32__Global__free(&self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const Vector__u32__Global *Vector__Vector__u32__Global__Global__as_ptr(const Vector__Vector__u32__Global__Global *const self) {
  return self->ptr;
}

void Vector__Vector__u32__Global__Global__swap(Vector__Vector__u32__Global__Global *const self, size_t const i, size_t const j) {
  __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__Vector__u32__Global__Global Vector__Vector__u32__Global__Global__new(void) {
  return Vector__Vector__u32__Global__Global__new_in(Global__default_());
}

void Vector__Vector__u32__Global__Global__free(Vector__Vector__u32__Global__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    Vector__u32__Global__free(&self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(Vector__u32__Global)), _Alignof(Vector__u32__Global));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__Vector__u32__Global__Global Vector__Vector__u32__Global__Global__default_(void) {
  return Vector__Vector__u32__Global__Global__new();
}

const Vector__u32__Global *Vector__Vector__u32__Global__Global__index(const Vector__Vector__u32__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Vector__u32__Global Vector__Vector__u32__Global__Global__index_range(const Vector__Vector__u32__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc16;
    if (r.inclusive) {
      __sc16 = (r.end + 1ULL);
    } else {
      __sc16 = r.end;
    }
    __sc16;
  });
  return (Slice__Vector__u32__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__u32__Global *Vector__Vector__u32__Global__Global__index_mut(Vector__Vector__u32__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__Vector__u32__Global Vector__Vector__u32__Global__Global__index_range_mut(Vector__Vector__u32__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc17;
    if (r.inclusive) {
      __sc17 = (r.end + 1ULL);
    } else {
      __sc17 = r.end;
    }
    __sc17;
  });
  return (SliceMut__Vector__u32__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__Vector__u32__Global__Global Vector__Vector__u32__Global__Global__clone(const Vector__Vector__u32__Global__Global *const self) {
  Vector__Vector__u32__Global__Global out = Vector__Vector__u32__Global__Global__with_capacity_in(self->alloc, Vector__Vector__u32__Global__Global__len(self));
  for (size_t i = 0ULL; i < Vector__Vector__u32__Global__Global__len(self); i++) {
    const Vector__u32__Global *const e = Vector__Vector__u32__Global__Global__at(self, i);
    Vector__Vector__u32__Global__Global__push(&out, Vector__u32__Global__clone(e));
  }
  return out;
}

bool Vector__Vector__u32__Global__Global__eq(const Vector__Vector__u32__Global__Global *const self, const Vector__Vector__u32__Global__Global *const other) {
  if (Vector__Vector__u32__Global__Global__len(self) != Vector__Vector__u32__Global__Global__len(other)) {
    return false;
  }
  for (size_t i = 0ULL; i < Vector__Vector__u32__Global__Global__len(self); i++) {
    const Vector__u32__Global *const a = Vector__Vector__u32__Global__Global__at(self, i);
    const Vector__u32__Global *const b = Vector__Vector__u32__Global__Global__at(other, i);
    if (!Vector__u32__Global__eq(a, b)) {
      return false;
    }
  }
  return true;
}

uint64_t Vector__Vector__u32__Global__Global__hash(const Vector__Vector__u32__Global__Global *const self) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t i = 0ULL; i < Vector__Vector__u32__Global__Global__len(self); i++) {
    const Vector__u32__Global *const e = Vector__Vector__u32__Global__Global__at(self, i);
    (h = ((h ^ Vector__u32__Global__hash(e)) * 0x100000001b3ULL));
  }
  return h;
}

Option__ptr_Vector__u32__Global VecIter__Vector__u32__Global__next(VecIter__Vector__u32__Global *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_Vector__u32__Global__none();
  }
  const Vector__u32__Global *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_Vector__u32__Global__some(r);
}

Option__Vector__bool__Global Option__Vector__bool__Global__some(Vector__bool__Global value) {
  return (Option__Vector__bool__Global){ .tag = Option_Some, .payload.Some = { value } };
}

Option__Vector__bool__Global Option__Vector__bool__Global__none(void) {
  return (Option__Vector__bool__Global){ .tag = Option_None };
}

bool Option__Vector__bool__Global__is_some(const Option__Vector__bool__Global *const self) {
  {
    const Option__Vector__bool__Global *const __sc18 = self;
    if ((*__sc18).tag == Option_Some) {
      return true;
    }
    else if ((*__sc18).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__Vector__bool__Global__is_none(const Option__Vector__bool__Global *const self) {
  {
    const Option__Vector__bool__Global *const __sc19 = self;
    if ((*__sc19).tag == Option_Some) {
      return false;
    }
    else if ((*__sc19).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__Vector__bool__Global Option__Vector__bool__Global__default_(void) {
  return Option__Vector__bool__Global__none();
}

void Option__Vector__bool__Global__free(Option__Vector__bool__Global *const self) {
  {
    Option__Vector__bool__Global *const __sc20 = self;
    if ((*__sc20).tag == Option_Some) {
      const __auto_type v = &((*__sc20).payload.Some._0);
      Vector__bool__Global__free(v);
    }
    else if ((*__sc20).tag == Option_None) {
      {
      }
    }
  }
}

Option__Vector__bool__Global Option__Vector__bool__Global__clone(const Option__Vector__bool__Global *const self) {
  {
    const Option__Vector__bool__Global *const __sc21 = self;
    if ((*__sc21).tag == Option_Some) {
      const __auto_type v = &((*__sc21).payload.Some._0);
      return (Option__Vector__bool__Global){ .tag = Option_Some, .payload.Some = { Vector__bool__Global__clone(v) } };
    }
    else if ((*__sc21).tag == Option_None) {
      return (Option__Vector__bool__Global){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__Vector__bool__Global__eq(const Option__Vector__bool__Global *const self, const Option__Vector__bool__Global *const other) {
  {
    const Option__Vector__bool__Global *const __sc22 = self;
    if ((*__sc22).tag == Option_Some) {
      const __auto_type a = &((*__sc22).payload.Some._0);
      return ({
        bool __sc23;
        const Option__Vector__bool__Global *const __sc24 = other;
        if ((*__sc24).tag == Option_Some) {
          const __auto_type b = &((*__sc24).payload.Some._0);
          __sc23 = Vector__bool__Global__eq(a, b);
        }
        else if ((*__sc24).tag == Option_None) {
          __sc23 = false;
        }
        else { __builtin_unreachable(); }
        __sc23;
      });
    }
    else if ((*__sc22).tag == Option_None) {
      return Option__Vector__bool__Global__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__Vector__bool__Global__hash(const Option__Vector__bool__Global *const self) {
  {
    const Option__Vector__bool__Global *const __sc25 = self;
    if ((*__sc25).tag == Option_Some) {
      const __auto_type v = &((*__sc25).payload.Some._0);
      return ((Vector__bool__Global__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc25).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_Vector__bool__Global Option__ptr_Vector__bool__Global__some(const Vector__bool__Global *const value) {
  return (Option__ptr_Vector__bool__Global){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_Vector__bool__Global Option__ptr_Vector__bool__Global__none(void) {
  return (Option__ptr_Vector__bool__Global){ .tag = Option_None };
}

bool Option__ptr_Vector__bool__Global__is_some(const Option__ptr_Vector__bool__Global *const self) {
  {
    const Option__ptr_Vector__bool__Global *const __sc26 = self;
    if ((*__sc26).tag == Option_Some) {
      return true;
    }
    else if ((*__sc26).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_Vector__bool__Global__is_none(const Option__ptr_Vector__bool__Global *const self) {
  {
    const Option__ptr_Vector__bool__Global *const __sc27 = self;
    if ((*__sc27).tag == Option_Some) {
      return false;
    }
    else if ((*__sc27).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_Vector__bool__Global Option__ptr_Vector__bool__Global__default_(void) {
  return Option__ptr_Vector__bool__Global__none();
}

size_t Slice__Vector__bool__Global__len(const Slice__Vector__bool__Global *const self) {
  return self->len;
}

const Vector__bool__Global *Slice__Vector__bool__Global__as_ptr(const Slice__Vector__bool__Global *const self) {
  return self->ptr;
}

const Vector__bool__Global *Slice__Vector__bool__Global__index(const Slice__Vector__bool__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Vector__bool__Global Slice__Vector__bool__Global__index_range(const Slice__Vector__bool__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc28;
    if (r.inclusive) {
      __sc28 = (r.end + 1ULL);
    } else {
      __sc28 = r.end;
    }
    __sc28;
  });
  return (Slice__Vector__bool__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__Vector__bool__Global__len(const SliceMut__Vector__bool__Global *const self) {
  return self->len;
}

Vector__bool__Global *SliceMut__Vector__bool__Global__as_mut_ptr(const SliceMut__Vector__bool__Global *const self) {
  return self->ptr;
}

const Vector__bool__Global *SliceMut__Vector__bool__Global__index(const SliceMut__Vector__bool__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Vector__bool__Global SliceMut__Vector__bool__Global__index_range(const SliceMut__Vector__bool__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc29;
    if (r.inclusive) {
      __sc29 = (r.end + 1ULL);
    } else {
      __sc29 = r.end;
    }
    __sc29;
  });
  return (Slice__Vector__bool__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__bool__Global *SliceMut__Vector__bool__Global__index_mut(SliceMut__Vector__bool__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__Vector__bool__Global SliceMut__Vector__bool__Global__index_range_mut(SliceMut__Vector__bool__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc30;
    if (r.inclusive) {
      __sc30 = (r.end + 1ULL);
    } else {
      __sc30 = r.end;
    }
    __sc30;
  });
  return (SliceMut__Vector__bool__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__Vector__String__Global__Global Option__Vector__String__Global__Global__some(Vector__String__Global__Global value) {
  return (Option__Vector__String__Global__Global){ .tag = Option_Some, .payload.Some = { value } };
}

Option__Vector__String__Global__Global Option__Vector__String__Global__Global__none(void) {
  return (Option__Vector__String__Global__Global){ .tag = Option_None };
}

bool Option__Vector__String__Global__Global__is_some(const Option__Vector__String__Global__Global *const self) {
  {
    const Option__Vector__String__Global__Global *const __sc31 = self;
    if ((*__sc31).tag == Option_Some) {
      return true;
    }
    else if ((*__sc31).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__Vector__String__Global__Global__is_none(const Option__Vector__String__Global__Global *const self) {
  {
    const Option__Vector__String__Global__Global *const __sc32 = self;
    if ((*__sc32).tag == Option_Some) {
      return false;
    }
    else if ((*__sc32).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__Vector__String__Global__Global Option__Vector__String__Global__Global__default_(void) {
  return Option__Vector__String__Global__Global__none();
}

void Option__Vector__String__Global__Global__free(Option__Vector__String__Global__Global *const self) {
  {
    Option__Vector__String__Global__Global *const __sc33 = self;
    if ((*__sc33).tag == Option_Some) {
      const __auto_type v = &((*__sc33).payload.Some._0);
      Vector__String__Global__Global__free(v);
    }
    else if ((*__sc33).tag == Option_None) {
      {
      }
    }
  }
}

Option__Vector__String__Global__Global Option__Vector__String__Global__Global__clone(const Option__Vector__String__Global__Global *const self) {
  {
    const Option__Vector__String__Global__Global *const __sc34 = self;
    if ((*__sc34).tag == Option_Some) {
      const __auto_type v = &((*__sc34).payload.Some._0);
      return (Option__Vector__String__Global__Global){ .tag = Option_Some, .payload.Some = { Vector__String__Global__Global__clone(v) } };
    }
    else if ((*__sc34).tag == Option_None) {
      return (Option__Vector__String__Global__Global){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__Vector__String__Global__Global__eq(const Option__Vector__String__Global__Global *const self, const Option__Vector__String__Global__Global *const other) {
  {
    const Option__Vector__String__Global__Global *const __sc35 = self;
    if ((*__sc35).tag == Option_Some) {
      const __auto_type a = &((*__sc35).payload.Some._0);
      return ({
        bool __sc36;
        const Option__Vector__String__Global__Global *const __sc37 = other;
        if ((*__sc37).tag == Option_Some) {
          const __auto_type b = &((*__sc37).payload.Some._0);
          __sc36 = Vector__String__Global__Global__eq(a, b);
        }
        else if ((*__sc37).tag == Option_None) {
          __sc36 = false;
        }
        else { __builtin_unreachable(); }
        __sc36;
      });
    }
    else if ((*__sc35).tag == Option_None) {
      return Option__Vector__String__Global__Global__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__Vector__String__Global__Global__hash(const Option__Vector__String__Global__Global *const self) {
  {
    const Option__Vector__String__Global__Global *const __sc38 = self;
    if ((*__sc38).tag == Option_Some) {
      const __auto_type v = &((*__sc38).payload.Some._0);
      return ((Vector__String__Global__Global__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc38).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

String__Global Option__Vector__String__Global__Global__fmt(const Option__Vector__String__Global__Global *const self) {
  if (Option__Vector__String__Global__Global__is_none(self)) {
    return String__Global__from_str((str){ (const uint8_t *)"None", sizeof("None") - 1 });
  }
  String__Global inner = ({
    String__Global __sc39;
    const Option__Vector__String__Global__Global *const __sc40 = self;
    if ((*__sc40).tag == Option_Some) {
      const __auto_type v = &((*__sc40).payload.Some._0);
      __sc39 = Vector__String__Global__Global__fmt(v);
    }
    else if ((*__sc40).tag == Option_None) {
      __sc39 = String__Global__new();
    }
    else { __builtin_unreachable(); }
    __sc39;
  });
  String__Global s = String__Global__from_str((str){ (const uint8_t *)"Some(", sizeof("Some(") - 1 });
  String__Global__push_string(&s, (&inner));
  String__Global__free(&inner);
  String__Global__push_str(&s, (str){ (const uint8_t *)")", sizeof(")") - 1 });
  return s;
}

Option__ptr_Vector__String__Global__Global Option__ptr_Vector__String__Global__Global__some(const Vector__String__Global__Global *const value) {
  return (Option__ptr_Vector__String__Global__Global){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_Vector__String__Global__Global Option__ptr_Vector__String__Global__Global__none(void) {
  return (Option__ptr_Vector__String__Global__Global){ .tag = Option_None };
}

bool Option__ptr_Vector__String__Global__Global__is_some(const Option__ptr_Vector__String__Global__Global *const self) {
  {
    const Option__ptr_Vector__String__Global__Global *const __sc41 = self;
    if ((*__sc41).tag == Option_Some) {
      return true;
    }
    else if ((*__sc41).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_Vector__String__Global__Global__is_none(const Option__ptr_Vector__String__Global__Global *const self) {
  {
    const Option__ptr_Vector__String__Global__Global *const __sc42 = self;
    if ((*__sc42).tag == Option_Some) {
      return false;
    }
    else if ((*__sc42).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_Vector__String__Global__Global Option__ptr_Vector__String__Global__Global__default_(void) {
  return Option__ptr_Vector__String__Global__Global__none();
}

size_t Slice__Vector__String__Global__Global__len(const Slice__Vector__String__Global__Global *const self) {
  return self->len;
}

const Vector__String__Global__Global *Slice__Vector__String__Global__Global__as_ptr(const Slice__Vector__String__Global__Global *const self) {
  return self->ptr;
}

const Vector__String__Global__Global *Slice__Vector__String__Global__Global__index(const Slice__Vector__String__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Vector__String__Global__Global Slice__Vector__String__Global__Global__index_range(const Slice__Vector__String__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc43;
    if (r.inclusive) {
      __sc43 = (r.end + 1ULL);
    } else {
      __sc43 = r.end;
    }
    __sc43;
  });
  return (Slice__Vector__String__Global__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__Vector__String__Global__Global__len(const SliceMut__Vector__String__Global__Global *const self) {
  return self->len;
}

Vector__String__Global__Global *SliceMut__Vector__String__Global__Global__as_mut_ptr(const SliceMut__Vector__String__Global__Global *const self) {
  return self->ptr;
}

const Vector__String__Global__Global *SliceMut__Vector__String__Global__Global__index(const SliceMut__Vector__String__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Vector__String__Global__Global SliceMut__Vector__String__Global__Global__index_range(const SliceMut__Vector__String__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc44;
    if (r.inclusive) {
      __sc44 = (r.end + 1ULL);
    } else {
      __sc44 = r.end;
    }
    __sc44;
  });
  return (Slice__Vector__String__Global__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__String__Global__Global *SliceMut__Vector__String__Global__Global__index_mut(SliceMut__Vector__String__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__Vector__String__Global__Global SliceMut__Vector__String__Global__Global__index_range_mut(SliceMut__Vector__String__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc45;
    if (r.inclusive) {
      __sc45 = (r.end + 1ULL);
    } else {
      __sc45 = r.end;
    }
    __sc45;
  });
  return (SliceMut__Vector__String__Global__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__Vector__u32__Global Option__Vector__u32__Global__some(Vector__u32__Global value) {
  return (Option__Vector__u32__Global){ .tag = Option_Some, .payload.Some = { value } };
}

Option__Vector__u32__Global Option__Vector__u32__Global__none(void) {
  return (Option__Vector__u32__Global){ .tag = Option_None };
}

bool Option__Vector__u32__Global__is_some(const Option__Vector__u32__Global *const self) {
  {
    const Option__Vector__u32__Global *const __sc46 = self;
    if ((*__sc46).tag == Option_Some) {
      return true;
    }
    else if ((*__sc46).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__Vector__u32__Global__is_none(const Option__Vector__u32__Global *const self) {
  {
    const Option__Vector__u32__Global *const __sc47 = self;
    if ((*__sc47).tag == Option_Some) {
      return false;
    }
    else if ((*__sc47).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__Vector__u32__Global Option__Vector__u32__Global__default_(void) {
  return Option__Vector__u32__Global__none();
}

void Option__Vector__u32__Global__free(Option__Vector__u32__Global *const self) {
  {
    Option__Vector__u32__Global *const __sc48 = self;
    if ((*__sc48).tag == Option_Some) {
      const __auto_type v = &((*__sc48).payload.Some._0);
      Vector__u32__Global__free(v);
    }
    else if ((*__sc48).tag == Option_None) {
      {
      }
    }
  }
}

Option__Vector__u32__Global Option__Vector__u32__Global__clone(const Option__Vector__u32__Global *const self) {
  {
    const Option__Vector__u32__Global *const __sc49 = self;
    if ((*__sc49).tag == Option_Some) {
      const __auto_type v = &((*__sc49).payload.Some._0);
      return (Option__Vector__u32__Global){ .tag = Option_Some, .payload.Some = { Vector__u32__Global__clone(v) } };
    }
    else if ((*__sc49).tag == Option_None) {
      return (Option__Vector__u32__Global){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__Vector__u32__Global__eq(const Option__Vector__u32__Global *const self, const Option__Vector__u32__Global *const other) {
  {
    const Option__Vector__u32__Global *const __sc50 = self;
    if ((*__sc50).tag == Option_Some) {
      const __auto_type a = &((*__sc50).payload.Some._0);
      return ({
        bool __sc51;
        const Option__Vector__u32__Global *const __sc52 = other;
        if ((*__sc52).tag == Option_Some) {
          const __auto_type b = &((*__sc52).payload.Some._0);
          __sc51 = Vector__u32__Global__eq(a, b);
        }
        else if ((*__sc52).tag == Option_None) {
          __sc51 = false;
        }
        else { __builtin_unreachable(); }
        __sc51;
      });
    }
    else if ((*__sc50).tag == Option_None) {
      return Option__Vector__u32__Global__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__Vector__u32__Global__hash(const Option__Vector__u32__Global *const self) {
  {
    const Option__Vector__u32__Global *const __sc53 = self;
    if ((*__sc53).tag == Option_Some) {
      const __auto_type v = &((*__sc53).payload.Some._0);
      return ((Vector__u32__Global__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc53).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_Vector__u32__Global Option__ptr_Vector__u32__Global__some(const Vector__u32__Global *const value) {
  return (Option__ptr_Vector__u32__Global){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_Vector__u32__Global Option__ptr_Vector__u32__Global__none(void) {
  return (Option__ptr_Vector__u32__Global){ .tag = Option_None };
}

bool Option__ptr_Vector__u32__Global__is_some(const Option__ptr_Vector__u32__Global *const self) {
  {
    const Option__ptr_Vector__u32__Global *const __sc54 = self;
    if ((*__sc54).tag == Option_Some) {
      return true;
    }
    else if ((*__sc54).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_Vector__u32__Global__is_none(const Option__ptr_Vector__u32__Global *const self) {
  {
    const Option__ptr_Vector__u32__Global *const __sc55 = self;
    if ((*__sc55).tag == Option_Some) {
      return false;
    }
    else if ((*__sc55).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_Vector__u32__Global Option__ptr_Vector__u32__Global__default_(void) {
  return Option__ptr_Vector__u32__Global__none();
}

size_t Slice__Vector__u32__Global__len(const Slice__Vector__u32__Global *const self) {
  return self->len;
}

const Vector__u32__Global *Slice__Vector__u32__Global__as_ptr(const Slice__Vector__u32__Global *const self) {
  return self->ptr;
}

const Vector__u32__Global *Slice__Vector__u32__Global__index(const Slice__Vector__u32__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Vector__u32__Global Slice__Vector__u32__Global__index_range(const Slice__Vector__u32__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc56;
    if (r.inclusive) {
      __sc56 = (r.end + 1ULL);
    } else {
      __sc56 = r.end;
    }
    __sc56;
  });
  return (Slice__Vector__u32__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__Vector__u32__Global__len(const SliceMut__Vector__u32__Global *const self) {
  return self->len;
}

Vector__u32__Global *SliceMut__Vector__u32__Global__as_mut_ptr(const SliceMut__Vector__u32__Global *const self) {
  return self->ptr;
}

const Vector__u32__Global *SliceMut__Vector__u32__Global__index(const SliceMut__Vector__u32__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Vector__u32__Global SliceMut__Vector__u32__Global__index_range(const SliceMut__Vector__u32__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc57;
    if (r.inclusive) {
      __sc57 = (r.end + 1ULL);
    } else {
      __sc57 = r.end;
    }
    __sc57;
  });
  return (Slice__Vector__u32__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__u32__Global *SliceMut__Vector__u32__Global__index_mut(SliceMut__Vector__u32__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__Vector__u32__Global SliceMut__Vector__u32__Global__index_range_mut(SliceMut__Vector__u32__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc58;
    if (r.inclusive) {
      __sc58 = (r.end + 1ULL);
    } else {
      __sc58 = r.end;
    }
    __sc58;
  });
  return (SliceMut__Vector__u32__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

