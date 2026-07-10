#include "main.h"
#include "stdio.h"
#include "stdlib.h"
#include "string.h"
#include "lexer/token.h"
#include "ast/ast.h"
#include "driver_shim.h"
#include "module/loader.h"
#include "utils/errors.h"
#include "resolver/resolver.h"
#include "typechecker/typechecker.h"
#include "consteval/consteval.h"
#include "codegen/codegen.h"
#include "__std/core.h"
#include "__std/interfaces.h"
#include "__std/option.h"
#include "__std/range.h"
#include "__std/result.h"
#include "__std/slice.h"
#include "__std/str.h"
#include "__std/string.h"
#include "__std/vector.h"

_Static_assert(sizeof(main__TestOpts) == 24 && _Alignof(main__TestOpts) == 8, "super-c layout model mismatch: main__TestOpts");
_Static_assert(sizeof(main__PathBuf) == 4096 && _Alignof(main__PathBuf) == 1, "super-c layout model mismatch: main__PathBuf");
_Static_assert(sizeof(main__Buf64) == 64 && _Alignof(main__Buf64) == 1, "super-c layout model mismatch: main__Buf64");
_Static_assert(sizeof(main__Buf128) == 128 && _Alignof(main__Buf128) == 1, "super-c layout model mismatch: main__Buf128");
_Static_assert(sizeof(main__TestCase) == 32 && _Alignof(main__TestCase) == 4, "super-c layout model mismatch: main__TestCase");
_Static_assert(sizeof(main__TestSuite) == 24 && _Alignof(main__TestSuite) == 4, "super-c layout model mismatch: main__TestSuite");
_Static_assert(sizeof(main__TestPlan) == 168 && _Alignof(main__TestPlan) == 8, "super-c layout model mismatch: main__TestPlan");
_Static_assert(sizeof(main__TCases) == 14336 && _Alignof(main__TCases) == 4, "super-c layout model mismatch: main__TCases");

static __attribute__((unused)) const ast__ast__Ast *main__mod_ast_c(const module__loader__Package *const p, uint16_t const m);
static __attribute__((unused)) ast__ast__Ast *main__mod_ast_m(module__loader__Package *const p, uint16_t const m);
static __attribute__((unused)) String__Global main__build_out_path(str const root_dir, str const mod_path, str const ext);
static __attribute__((unused)) void main__mkdir_p(str const path);
static __attribute__((unused)) FILE *main__open_out(str const path);
static __attribute__((unused)) void main__prune_orphans(const char *const dir, const Vector__String__Global__Global *const keep);
static __attribute__((unused)) void main__write_super_rt(str const root_dir);
static __attribute__((unused)) bool main__mark_live(bool *const live, size_t const n, uint16_t const m);
static __attribute__((unused)) bool main__ast_type_mentions_builtin(const module__loader__Package *const p, uint16_t const am, uint32_t const t);
static __attribute__((unused)) bool main__mark_type_modules(const module__loader__Package *const p, uint16_t const am, uint32_t const t, bool *const live);
static __attribute__((unused)) bool *main__compute_emit_live(const module__loader__Package *const p);
static __attribute__((unused)) bool main__resolve_module(module__loader__Package *const p, size_t const i);
static __attribute__((unused)) bool main__typecheck_module(module__loader__Package *const p, size_t const i);
static __attribute__((unused)) void main__flush_assert_err(void *const ctx, uint16_t const m, uint32_t const cond, const char *const msg);
static __attribute__((unused)) void main__ext_rel(const char *const file, const char *const v, int32_t const vl, char *const out);
static __attribute__((unused)) void main__ext_c_wrap(str const root, Vector__String__Global__Global *const keep, Vector__String__Global__Global *const seen, uint32_t *const nsrc, const char *const rsl, bool *const err);
static __attribute__((unused)) void main__ext_c_collect(module__loader__Package *const p, Vector__String__Global__Global *const keep, bool *const err);
static __attribute__((unused)) main__TestPlan main__TestPlan__new(size_t const count);
static __attribute__((unused)) void main__test_err(module__loader__Package *const p, uint16_t const m, lexer__token__Span const sp, const char *const msg);
static __attribute__((unused)) ast__ast__DefId main__test_type_decl(const module__loader__Package *const p, uint16_t const am, uint32_t const tnode, bool *const is_enum);
static __attribute__((unused)) uint32_t main__test_fn_ret_node(const module__loader__Package *const p, uint16_t const am, uint32_t const fnode);
static __attribute__((unused)) bool main__test_fn_returns_nothing(const module__loader__Package *const p, uint16_t const am, const char *const src, uint32_t const fnode);
static __attribute__((unused)) uint8_t main__test_param_bit(module__loader__Package *const p, uint16_t const m, uint32_t const pnode, ast__ast__DefId const fx, ast__ast__DefId const genv);
static __attribute__((unused)) uint32_t main__test_owner_extend(const module__loader__Package *const p, uint16_t const am, uint32_t const fnode, bool *const bad);
static __attribute__((unused)) int32_t main__plan_suite_of(main__TestPlan *const plan, uint16_t const m, ast__ast__DefId const ty, bool const is_enum, bool const create);
static __attribute__((unused)) void main__test_plan_build(module__loader__Package *const p, main__TestPlan *const plan);
static __attribute__((unused)) const char *main__test_runner_includes(void);
static __attribute__((unused)) const char *main__test_runner_main(void);
static __attribute__((unused)) Option__String__Global main__write_test_main(module__loader__Package *const p, const main__TestPlan *const plan);
static __attribute__((unused)) int32_t main__test_build_and_run(const module__loader__Package *const p, const main__TestOpts *const topts, const Vector__String__Global__Global *const keep, const char *const out_bin);
static __attribute__((unused)) void main__platform_filter(module__loader__Package *const p, int32_t const target);
static __attribute__((unused)) int32_t main__run_package(module__loader__Package *const p, const main__TestOpts *const topts, const char *const out_bin, int32_t const target);
static __attribute__((unused)) int32_t main__run_file(const char *const path, const char *const std_dir, uint32_t const ce_steps, uint64_t const ce_mem, const main__TestOpts *const topts, const char *const out_bin, int32_t const target, bool const bootstrap_tags);
static __attribute__((unused)) uint64_t main__parse_size(const char *const s);
static __attribute__((unused)) char *main__exe_std_dir(const char *const argv0);
int main(void);

Vector__main__TestCase__Global Vector__main__TestCase__Global__new_in(Global const alloc) {
  return (Vector__main__TestCase__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__main__TestCase__Global Vector__main__TestCase__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__main__TestCase__Global v = (Vector__main__TestCase__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((main__TestCase *)Global__alloc(&v.alloc, (cap * sizeof(main__TestCase)), _Alignof(main__TestCase))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__main__TestCase__Global__len(const Vector__main__TestCase__Global *const self) {
  return self->len;
}

void Vector__main__TestCase__Global__reserve(Vector__main__TestCase__Global *const self, size_t const additional) {
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
  main__TestCase *const p = ((main__TestCase *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(main__TestCase)), (new_cap * sizeof(main__TestCase)), _Alignof(main__TestCase)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__main__TestCase__Global__push(Vector__main__TestCase__Global *const self, main__TestCase const value) {
  Vector__main__TestCase__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const main__TestCase *Vector__main__TestCase__Global__at(const Vector__main__TestCase__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_main__TestCase Vector__main__TestCase__Global__get(const Vector__main__TestCase__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_main__TestCase){ .tag = Option_None };
  }
  return (Option__ptr_main__TestCase){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__main__TestCase__Global__set(Vector__main__TestCase__Global *const self, size_t const index, main__TestCase const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__main__TestCase__Global__clear(Vector__main__TestCase__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__main__TestCase__Global__truncate(Vector__main__TestCase__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const main__TestCase *Vector__main__TestCase__Global__as_ptr(const Vector__main__TestCase__Global *const self) {
  return self->ptr;
}

void Vector__main__TestCase__Global__swap(Vector__main__TestCase__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__main__TestCase__Global Vector__main__TestCase__Global__new(void) {
  return Vector__main__TestCase__Global__new_in(Global__default_());
}

void Vector__main__TestCase__Global__free(Vector__main__TestCase__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(main__TestCase)), _Alignof(main__TestCase));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__main__TestCase__Global Vector__main__TestCase__Global__default_(void) {
  return Vector__main__TestCase__Global__new();
}

const main__TestCase *Vector__main__TestCase__Global__index(const Vector__main__TestCase__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__main__TestCase Vector__main__TestCase__Global__index_range(const Vector__main__TestCase__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc0;
    if (r.inclusive) {
      __sc0 = (r.end + 1ULL);
    } else {
      __sc0 = r.end;
    }
    __sc0;
  });
  return (Slice__main__TestCase){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

main__TestCase *Vector__main__TestCase__Global__index_mut(Vector__main__TestCase__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__main__TestCase Vector__main__TestCase__Global__index_range_mut(Vector__main__TestCase__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc1;
    if (r.inclusive) {
      __sc1 = (r.end + 1ULL);
    } else {
      __sc1 = r.end;
    }
    __sc1;
  });
  return (SliceMut__main__TestCase){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__main__TestSuite__Global Vector__main__TestSuite__Global__new_in(Global const alloc) {
  return (Vector__main__TestSuite__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__main__TestSuite__Global Vector__main__TestSuite__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__main__TestSuite__Global v = (Vector__main__TestSuite__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((main__TestSuite *)Global__alloc(&v.alloc, (cap * sizeof(main__TestSuite)), _Alignof(main__TestSuite))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__main__TestSuite__Global__len(const Vector__main__TestSuite__Global *const self) {
  return self->len;
}

void Vector__main__TestSuite__Global__reserve(Vector__main__TestSuite__Global *const self, size_t const additional) {
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
  main__TestSuite *const p = ((main__TestSuite *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(main__TestSuite)), (new_cap * sizeof(main__TestSuite)), _Alignof(main__TestSuite)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__main__TestSuite__Global__push(Vector__main__TestSuite__Global *const self, main__TestSuite const value) {
  Vector__main__TestSuite__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const main__TestSuite *Vector__main__TestSuite__Global__at(const Vector__main__TestSuite__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_main__TestSuite Vector__main__TestSuite__Global__get(const Vector__main__TestSuite__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_main__TestSuite){ .tag = Option_None };
  }
  return (Option__ptr_main__TestSuite){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__main__TestSuite__Global__set(Vector__main__TestSuite__Global *const self, size_t const index, main__TestSuite const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__main__TestSuite__Global__clear(Vector__main__TestSuite__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__main__TestSuite__Global__truncate(Vector__main__TestSuite__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const main__TestSuite *Vector__main__TestSuite__Global__as_ptr(const Vector__main__TestSuite__Global *const self) {
  return self->ptr;
}

void Vector__main__TestSuite__Global__swap(Vector__main__TestSuite__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__main__TestSuite__Global Vector__main__TestSuite__Global__new(void) {
  return Vector__main__TestSuite__Global__new_in(Global__default_());
}

void Vector__main__TestSuite__Global__free(Vector__main__TestSuite__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(main__TestSuite)), _Alignof(main__TestSuite));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__main__TestSuite__Global Vector__main__TestSuite__Global__default_(void) {
  return Vector__main__TestSuite__Global__new();
}

const main__TestSuite *Vector__main__TestSuite__Global__index(const Vector__main__TestSuite__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__main__TestSuite Vector__main__TestSuite__Global__index_range(const Vector__main__TestSuite__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc2;
    if (r.inclusive) {
      __sc2 = (r.end + 1ULL);
    } else {
      __sc2 = r.end;
    }
    __sc2;
  });
  return (Slice__main__TestSuite){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

main__TestSuite *Vector__main__TestSuite__Global__index_mut(Vector__main__TestSuite__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__main__TestSuite Vector__main__TestSuite__Global__index_range_mut(Vector__main__TestSuite__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc3;
    if (r.inclusive) {
      __sc3 = (r.end + 1ULL);
    } else {
      __sc3 = r.end;
    }
    __sc3;
  });
  return (SliceMut__main__TestSuite){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__main__TestCase Option__main__TestCase__some(main__TestCase const value) {
  return (Option__main__TestCase){ .tag = Option_Some, .payload.Some = { value } };
}

Option__main__TestCase Option__main__TestCase__none(void) {
  return (Option__main__TestCase){ .tag = Option_None };
}

bool Option__main__TestCase__is_some(const Option__main__TestCase *const self) {
  {
    const Option__main__TestCase *const __sc4 = self;
    if ((*__sc4).tag == Option_Some) {
      return true;
    }
    else if ((*__sc4).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__main__TestCase__is_none(const Option__main__TestCase *const self) {
  {
    const Option__main__TestCase *const __sc5 = self;
    if ((*__sc5).tag == Option_Some) {
      return false;
    }
    else if ((*__sc5).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__main__TestCase Option__main__TestCase__default_(void) {
  return Option__main__TestCase__none();
}

Option__ptr_main__TestCase Option__ptr_main__TestCase__some(const main__TestCase *const value) {
  return (Option__ptr_main__TestCase){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_main__TestCase Option__ptr_main__TestCase__none(void) {
  return (Option__ptr_main__TestCase){ .tag = Option_None };
}

bool Option__ptr_main__TestCase__is_some(const Option__ptr_main__TestCase *const self) {
  {
    const Option__ptr_main__TestCase *const __sc6 = self;
    if ((*__sc6).tag == Option_Some) {
      return true;
    }
    else if ((*__sc6).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_main__TestCase__is_none(const Option__ptr_main__TestCase *const self) {
  {
    const Option__ptr_main__TestCase *const __sc7 = self;
    if ((*__sc7).tag == Option_Some) {
      return false;
    }
    else if ((*__sc7).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_main__TestCase Option__ptr_main__TestCase__default_(void) {
  return Option__ptr_main__TestCase__none();
}

Option__ptr_main__TestCase VecIter__main__TestCase__next(VecIter__main__TestCase *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_main__TestCase__none();
  }
  const main__TestCase *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_main__TestCase__some(r);
}

size_t Slice__main__TestCase__len(const Slice__main__TestCase *const self) {
  return self->len;
}

const main__TestCase *Slice__main__TestCase__as_ptr(const Slice__main__TestCase *const self) {
  return self->ptr;
}

const main__TestCase *Slice__main__TestCase__index(const Slice__main__TestCase *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__main__TestCase Slice__main__TestCase__index_range(const Slice__main__TestCase *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc8;
    if (r.inclusive) {
      __sc8 = (r.end + 1ULL);
    } else {
      __sc8 = r.end;
    }
    __sc8;
  });
  return (Slice__main__TestCase){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__main__TestCase__len(const SliceMut__main__TestCase *const self) {
  return self->len;
}

main__TestCase *SliceMut__main__TestCase__as_mut_ptr(const SliceMut__main__TestCase *const self) {
  return self->ptr;
}

const main__TestCase *SliceMut__main__TestCase__index(const SliceMut__main__TestCase *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__main__TestCase SliceMut__main__TestCase__index_range(const SliceMut__main__TestCase *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc9;
    if (r.inclusive) {
      __sc9 = (r.end + 1ULL);
    } else {
      __sc9 = r.end;
    }
    __sc9;
  });
  return (Slice__main__TestCase){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

main__TestCase *SliceMut__main__TestCase__index_mut(SliceMut__main__TestCase *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__main__TestCase SliceMut__main__TestCase__index_range_mut(SliceMut__main__TestCase *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc10;
    if (r.inclusive) {
      __sc10 = (r.end + 1ULL);
    } else {
      __sc10 = r.end;
    }
    __sc10;
  });
  return (SliceMut__main__TestCase){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__main__TestSuite Option__main__TestSuite__some(main__TestSuite const value) {
  return (Option__main__TestSuite){ .tag = Option_Some, .payload.Some = { value } };
}

Option__main__TestSuite Option__main__TestSuite__none(void) {
  return (Option__main__TestSuite){ .tag = Option_None };
}

bool Option__main__TestSuite__is_some(const Option__main__TestSuite *const self) {
  {
    const Option__main__TestSuite *const __sc11 = self;
    if ((*__sc11).tag == Option_Some) {
      return true;
    }
    else if ((*__sc11).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__main__TestSuite__is_none(const Option__main__TestSuite *const self) {
  {
    const Option__main__TestSuite *const __sc12 = self;
    if ((*__sc12).tag == Option_Some) {
      return false;
    }
    else if ((*__sc12).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__main__TestSuite Option__main__TestSuite__default_(void) {
  return Option__main__TestSuite__none();
}

Option__ptr_main__TestSuite Option__ptr_main__TestSuite__some(const main__TestSuite *const value) {
  return (Option__ptr_main__TestSuite){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_main__TestSuite Option__ptr_main__TestSuite__none(void) {
  return (Option__ptr_main__TestSuite){ .tag = Option_None };
}

bool Option__ptr_main__TestSuite__is_some(const Option__ptr_main__TestSuite *const self) {
  {
    const Option__ptr_main__TestSuite *const __sc13 = self;
    if ((*__sc13).tag == Option_Some) {
      return true;
    }
    else if ((*__sc13).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_main__TestSuite__is_none(const Option__ptr_main__TestSuite *const self) {
  {
    const Option__ptr_main__TestSuite *const __sc14 = self;
    if ((*__sc14).tag == Option_Some) {
      return false;
    }
    else if ((*__sc14).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_main__TestSuite Option__ptr_main__TestSuite__default_(void) {
  return Option__ptr_main__TestSuite__none();
}

Option__ptr_main__TestSuite VecIter__main__TestSuite__next(VecIter__main__TestSuite *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_main__TestSuite__none();
  }
  const main__TestSuite *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_main__TestSuite__some(r);
}

size_t Slice__main__TestSuite__len(const Slice__main__TestSuite *const self) {
  return self->len;
}

const main__TestSuite *Slice__main__TestSuite__as_ptr(const Slice__main__TestSuite *const self) {
  return self->ptr;
}

const main__TestSuite *Slice__main__TestSuite__index(const Slice__main__TestSuite *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__main__TestSuite Slice__main__TestSuite__index_range(const Slice__main__TestSuite *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc15;
    if (r.inclusive) {
      __sc15 = (r.end + 1ULL);
    } else {
      __sc15 = r.end;
    }
    __sc15;
  });
  return (Slice__main__TestSuite){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__main__TestSuite__len(const SliceMut__main__TestSuite *const self) {
  return self->len;
}

main__TestSuite *SliceMut__main__TestSuite__as_mut_ptr(const SliceMut__main__TestSuite *const self) {
  return self->ptr;
}

const main__TestSuite *SliceMut__main__TestSuite__index(const SliceMut__main__TestSuite *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__main__TestSuite SliceMut__main__TestSuite__index_range(const SliceMut__main__TestSuite *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc16;
    if (r.inclusive) {
      __sc16 = (r.end + 1ULL);
    } else {
      __sc16 = r.end;
    }
    __sc16;
  });
  return (Slice__main__TestSuite){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

main__TestSuite *SliceMut__main__TestSuite__index_mut(SliceMut__main__TestSuite *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__main__TestSuite SliceMut__main__TestSuite__index_range_mut(SliceMut__main__TestSuite *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc17;
    if (r.inclusive) {
      __sc17 = (r.end + 1ULL);
    } else {
      __sc17 = r.end;
    }
    __sc17;
  });
  return (SliceMut__main__TestSuite){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

static __attribute__((unused)) const ast__ast__Ast *main__mod_ast_c(const module__loader__Package *const p, uint16_t const m) {
  return ((const ast__ast__Ast *)(&(*({ __auto_type __sc18 = &p->modules; Vector__module__loader__Module__Global__index(__sc18, ((size_t)m)); })).ast));
}

static __attribute__((unused)) ast__ast__Ast *main__mod_ast_m(module__loader__Package *const p, uint16_t const m) {
  return ((ast__ast__Ast *)(&(*({ __auto_type __sc19 = &p->modules; Vector__module__loader__Module__Global__index_mut(__sc19, ((size_t)m)); })).ast));
}

static __attribute__((unused)) String__Global main__build_out_path(str const root_dir, str const mod_path, str const ext) {
  String__Global out = String__Global__from_str(root_dir);
  String__Global__push_str(&out, (str){ (const uint8_t *)"/build/", sizeof("/build/") - 1 });
  const size_t n = str__len(&mod_path);
  size_t i = 0ULL;
  while (i < n) {
    if (((str__byte_at(&mod_path, i) == 58U) && ((i + 1ULL) < n)) && (str__byte_at(&mod_path, (i + 1ULL)) == 58U)) {
      String__Global__push_byte(&out, 47U);
      (i = (i + 2ULL));
    } else {
      String__Global__push_byte(&out, ((uint8_t)str__byte_at(&mod_path, i)));
      (i = (i + 1ULL));
    }
  }
  String__Global__push_str(&out, ext);
  return out;
}

static __attribute__((unused)) void main__mkdir_p(str const path) {
  const size_t n = str__len(&path);
  if ((n == 0ULL) || (n >= 4096ULL)) {
    return;
  }
  main__PathBuf buf = (main__PathBuf){0};
  memcpy(((void *)(&buf.b[0])), ((const void *)str__ptr(&path)), n);
  (buf.b[n] = 0);
  char *const base = ((char *)(&buf.b[0]));
  size_t i = 1ULL;
  while (i < n) {
    if (base[i] == 47) {
      (base[i] = 0);
      (void)(sc_mkdir(base));
      (base[i] = 47);
    }
    (i = (i + 1ULL));
  }
  (void)(sc_mkdir(base));
}

static __attribute__((unused)) FILE *main__open_out(str const path) {
  const uint8_t *const p = str__ptr(&path);
  const size_t n = str__len(&path);
  size_t slash = n;
  size_t i = 0ULL;
  while (i < n) {
    if (p[i] == 47U) {
      (slash = i);
    }
    (i = (i + 1ULL));
  }
  if (slash < n) {
    main__mkdir_p(str__from_raw(p, slash));
  }
  return stdio__fopen(path, (str){ (const uint8_t *)"w", sizeof("w") - 1 });
}

static __attribute__((unused)) void main__prune_orphans(const char *const dir, const Vector__String__Global__Global *const keep) {
  void *const d = sc_opendir(dir);
  if (d == NULL) {
    return;
  }
  for (;;) {
    void *const e = sc_readdir(d);
    if (e == NULL) {
      break;
    }
    const char *const name = sc_dirent_name(e);
    if ((strcmp(name, ((const char *)({ __auto_type __sc20 = (str){ (const uint8_t *)".", sizeof(".") - 1 }; str__ptr(&__sc20); }))) == 0) || (strcmp(name, ((const char *)({ __auto_type __sc21 = (str){ (const uint8_t *)"..", sizeof("..") - 1 }; str__ptr(&__sc21); }))) == 0)) {
      continue;
    }
    main__PathBuf pb = (main__PathBuf){0};
    const int32_t np = snprintf(((char *)(&pb.b[0])), 4096ULL, ((const char *)({ __auto_type __sc22 = (str){ (const uint8_t *)"%s/%s", sizeof("%s/%s") - 1 }; str__ptr(&__sc22); })), dir, name);
    if ((np < 0) || (((size_t)np) >= 4096ULL)) {
      continue;
    }
    const char *const path = ((const char *)(&pb.b[0]));
    if (sc_stat_isdir(path) != 0) {
      main__prune_orphans(path, (&(*keep)));
      (void)(sc_rmdir(path));
      continue;
    }
    const size_t l = strlen(name);
    if (!(((l >= 2ULL) && (name[(l - 2ULL)] == 46)) && ((name[(l - 1ULL)] == 99) || (name[(l - 1ULL)] == 104)))) {
      continue;
    }
    bool kept = false;
    size_t i = 0ULL;
    while ((i < Vector__String__Global__Global__len(keep)) && (!kept)) {
      if (({ __auto_type __sc23 = String__Global__as_str(&(*({ __auto_type __sc25 = keep; Vector__String__Global__Global__index(__sc25, i); }))); __auto_type __sc24 = str__from_cstr(path); str__eq(&__sc23, &__sc24); })) {
        (kept = true);
      }
      (i = (i + 1ULL));
    }
    if (!kept) {
      (void)(sc_unlink(path));
    }
  }
  (void)(sc_closedir(d));
}

static __attribute__((unused)) void main__write_super_rt(str const root_dir) {
  String__Global path = main__build_out_path(root_dir, (str){ (const uint8_t *)"super_rt", sizeof("super_rt") - 1 }, (str){ (const uint8_t *)".h", sizeof(".h") - 1 });
  FILE *const f = main__open_out(String__Global__as_str(&path));
  if (f != NULL) {
    fputs(((const char *)({ __auto_type __sc26 = (str){ (const uint8_t *)"#ifndef SUPER_RT_H\n#define SUPER_RT_H\n", sizeof("#ifndef SUPER_RT_H\n#define SUPER_RT_H\n") - 1 }; str__ptr(&__sc26); })), f);
    fputs(codegen__codegen__super_rt_includes(), f);
    fputs(((const char *)({ __auto_type __sc27 = (str){ (const uint8_t *)"#endif\n", sizeof("#endif\n") - 1 }; str__ptr(&__sc27); })), f);
    fclose(f);
  }
  String__Global__free(&path);
}

static __attribute__((unused)) bool main__mark_live(bool *const live, size_t const n, uint16_t const m) {
  if ((((size_t)m) >= n) || live[((size_t)m)]) {
    return false;
  }
  (live[((size_t)m)] = true);
  return true;
}

static __attribute__((unused)) bool main__ast_type_mentions_builtin(const module__loader__Package *const p, uint16_t const am, uint32_t const t) {
  if (t == ast__ast__TYPE_NONE) {
    return false;
  }
  const ast__ast__Ty y = (*ast__ast__Ast__type_at(main__mod_ast_c((&(*p)), am), t));
  if (y.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    return true;
  }
  if ((((y.kind == ast__ast__TypeKind_TYPE_POINTER) || (y.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (y.kind == ast__ast__TypeKind_TYPE_SLICE)) || (y.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    return main__ast_type_mentions_builtin((&(*p)), am, y.as_data.elem);
  }
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(main__mod_ast_c((&(*p)), am), y.as_data.inst));
    for (uint8_t i = 0U; i < it.n; i++) {
      if (main__ast_type_mentions_builtin((&(*p)), am, it.args[((size_t)i)])) {
        return true;
      }
    }
    return false;
  }
  return false;
}

static __attribute__((unused)) bool main__mark_type_modules(const module__loader__Package *const p, uint16_t const am, uint32_t const t, bool *const live) {
  if (t == ast__ast__TYPE_NONE) {
    return false;
  }
  const ast__ast__Ty y = (*ast__ast__Ast__type_at(main__mod_ast_c((&(*p)), am), t));
  bool changed = false;
  if ((((y.kind == ast__ast__TypeKind_TYPE_POINTER) || (y.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (y.kind == ast__ast__TypeKind_TYPE_SLICE)) || (y.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    if (main__mark_type_modules((&(*p)), am, y.as_data.elem, live)) {
      (changed = true);
    }
  } else if (((y.kind == ast__ast__TypeKind_TYPE_STRUCT) || (y.kind == ast__ast__TypeKind_TYPE_ENUM)) || (y.kind == ast__ast__TypeKind_TYPE_FUNCTION)) {
    if (module__loader__Package__builtin_of_decl(p, y.module, y.as_data.decl) < 0) {
      if (main__mark_live(live, Vector__module__loader__Module__Global__len(&p->modules), y.module)) {
        (changed = true);
      }
    }
  } else if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(main__mod_ast_c((&(*p)), am), y.as_data.inst));
    const size_t np = Vector__module__loader__Module__Global__len(&p->modules);
    if (((size_t)it.module) < np) {
      if (main__mark_live(live, np, it.module)) {
        (changed = true);
      }
    }
    const uint16_t home = module__loader__Package__instance_home_mid(p, am, (&it));
    if (((size_t)home) < np) {
      if (main__mark_live(live, np, home)) {
        (changed = true);
      }
    }
    for (uint8_t i = 0U; i < it.n; i++) {
      if (main__mark_type_modules((&(*p)), am, it.args[((size_t)i)], live)) {
        (changed = true);
      }
      if (p->core_seeded && main__ast_type_mentions_builtin((&(*p)), am, it.args[((size_t)i)])) {
        if (main__mark_live(live, np, p->core_module)) {
          (changed = true);
        }
      }
    }
  }
  return changed;
}

static __attribute__((unused)) bool *main__compute_emit_live(const module__loader__Package *const p) {
  const size_t n = Vector__module__loader__Module__Global__len(&p->modules);
  const size_t sz = ({
    size_t __sc28;
    if (n != 0ULL) {
      __sc28 = n;
    } else {
      __sc28 = 1ULL;
    }
    __sc28;
  });
  bool *const live = ((bool *)calloc(sz, 1ULL));
  if (live == NULL) {
    return NULL;
  }
  for (size_t i = 0ULL; i < n; i++) {
    if (!(*({ __auto_type __sc29 = &p->modules; Vector__module__loader__Module__Global__index(__sc29, i); })).prelude) {
      (live[i] = true);
    }
  }
  bool changed = true;
  while (changed) {
    (changed = false);
    for (size_t m = 0ULL; m < n; m++) {
      if ((!live[m]) || (!(*({ __auto_type __sc30 = &p->modules; Vector__module__loader__Module__Global__index(__sc30, m); })).has_ast)) {
        continue;
      }
      const ast__ast__Ast *const a = main__mod_ast_c((&(*p)), ((uint16_t)m));
      const size_t nr = Vector__ast__ast__DefId__Global__len(&(*a).resolutions);
      for (size_t r = 0ULL; r < nr; r++) {
        const ast__ast__DefId d = (*({ __auto_type __sc31 = &(*a).resolutions; Vector__ast__ast__DefId__Global__index(__sc31, r); }));
        if ((((d.node != ast__ast__NODE_NONE) && (((size_t)d.module) < n)) && (((size_t)d.module) != m)) && (module__loader__Package__builtin_of_decl(p, d.module, d.node) < 0)) {
          if (main__mark_live(live, n, d.module)) {
            (changed = true);
          }
        }
      }
      const size_t nt = Vector__ast__ast__Ty__Global__len(&(*a).type_pool);
      for (size_t ti = 0ULL; ti < nt; ti++) {
        if (main__mark_type_modules((&(*p)), ((uint16_t)m), ((uint32_t)ti), live)) {
          (changed = true);
        }
      }
      const size_t ni = Vector__ast__ast__TyInstance__Global__len(&(*a).instances);
      for (size_t ii = 0ULL; ii < ni; ii++) {
        const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*a)), ((uint32_t)ii)));
        if (((size_t)it.module) < n) {
          if (main__mark_live(live, n, it.module)) {
            (changed = true);
          }
        }
        const uint16_t home = module__loader__Package__instance_home_mid(p, ((uint16_t)m), (&it));
        if (((size_t)home) < n) {
          if (main__mark_live(live, n, home)) {
            (changed = true);
          }
        }
        for (uint8_t k = 0U; k < it.n; k++) {
          if (main__mark_type_modules((&(*p)), ((uint16_t)m), it.args[((size_t)k)], live)) {
            (changed = true);
          }
          if (p->core_seeded && main__ast_type_mentions_builtin((&(*p)), ((uint16_t)m), it.args[((size_t)k)])) {
            if (main__mark_live(live, n, p->core_module)) {
              (changed = true);
            }
          }
        }
      }
      const size_t nmo = Vector__ast__ast__MonoUse__Global__len(&(*a).mono);
      for (size_t moi = 0ULL; moi < nmo; moi++) {
        const ast__ast__MonoUse mu = (*({ __auto_type __sc32 = &(*a).mono; Vector__ast__ast__MonoUse__Global__index(__sc32, moi); }));
        for (uint8_t k = 0U; k < mu.n; k++) {
          if (main__mark_type_modules((&(*p)), ((uint16_t)m), mu.args[((size_t)k)], live)) {
            (changed = true);
          }
          if (p->core_seeded && main__ast_type_mentions_builtin((&(*p)), ((uint16_t)m), mu.args[((size_t)k)])) {
            if (main__mark_live(live, n, p->core_module)) {
              (changed = true);
            }
          }
        }
      }
      const size_t nmi = Vector__ast__ast__MethodInst__Global__len(&(*a).method_insts);
      for (size_t xi = 0ULL; xi < nmi; xi++) {
        const ast__ast__MethodInst miu = (*({ __auto_type __sc33 = &(*a).method_insts; Vector__ast__ast__MethodInst__Global__index(__sc33, xi); }));
        if (main__mark_type_modules((&(*p)), ((uint16_t)m), miu.instance, live)) {
          (changed = true);
        }
        for (uint8_t k = 0U; k < miu.n; k++) {
          if (main__mark_type_modules((&(*p)), ((uint16_t)m), miu.targs[((size_t)k)], live)) {
            (changed = true);
          }
          if (p->core_seeded && main__ast_type_mentions_builtin((&(*p)), ((uint16_t)m), miu.targs[((size_t)k)])) {
            if (main__mark_live(live, n, p->core_module)) {
              (changed = true);
            }
          }
        }
      }
    }
  }
  return live;
}

static __attribute__((unused)) bool main__resolve_module(module__loader__Package *const p, size_t const i) {
  const module__loader__Package *const pkg = ((const module__loader__Package *)(&(*p)));
  module__loader__Module *const m = (&(*({ __auto_type __sc34 = &p->modules; Vector__module__loader__Module__Global__index_mut(__sc34, i); })));
  const char *const src = ((const char *)({ __auto_type __sc35 = String__Global__as_str(&m->source); str__ptr(&__sc35); }));
  const size_t len = String__Global__len(&m->source);
  ast__ast__Ast a = m->ast;
  (m->ast = ast__ast__Ast__new(0ULL));
  resolver__resolver__Resolver r = resolver__resolver__Resolver__new(a, str__from_raw(((const uint8_t *)src), len), pkg);
  (p->override_mod = ((uint16_t)i));
  (p->override_ast = ((ast__ast__Ast *)(&r.ast)));
  resolver__resolver__Resolver__resolve(&r);
  (p->override_mod = 65535U);
  (p->override_ast = NULL);
  const bool had = resolver__resolver__Resolver__has_errors(&r);
  if (had) {
    resolver__resolver__Resolver__log_errors(&r);
  }
  ast__ast__Ast back = resolver__resolver__Resolver__take_ast(&r);
  resolver__resolver__Resolver__free(&r);
  ((*({ __auto_type __sc36 = &p->modules; Vector__module__loader__Module__Global__index_mut(__sc36, i); })).ast = back);
  return (!had);
}

static __attribute__((unused)) bool main__typecheck_module(module__loader__Package *const p, size_t const i) {
  module__loader__Package *const pkg = ((module__loader__Package *)(&(*p)));
  module__loader__Module *const m = (&(*({ __auto_type __sc37 = &p->modules; Vector__module__loader__Module__Global__index_mut(__sc37, i); })));
  const char *const src = ((const char *)({ __auto_type __sc38 = String__Global__as_str(&m->source); str__ptr(&__sc38); }));
  const size_t len = String__Global__len(&m->source);
  ast__ast__Ast a = m->ast;
  (m->ast = ast__ast__Ast__new(0ULL));
  typechecker__typechecker__TypeChecker t = typechecker__typechecker__TypeChecker__new(a, str__from_raw(((const uint8_t *)src), len), pkg);
  (p->override_mod = ((uint16_t)i));
  (p->override_ast = ((ast__ast__Ast *)(&t.ast)));
  typechecker__typechecker__TypeChecker__check(&t);
  (p->override_mod = 65535U);
  (p->override_ast = NULL);
  const bool had = typechecker__typechecker__TypeChecker__has_errors(&t);
  if (had) {
    typechecker__typechecker__TypeChecker__log_errors(&t);
  }
  ast__ast__Ast back = typechecker__typechecker__TypeChecker__take_ast(&t);
  ((*({ __auto_type __sc39 = &p->modules; Vector__module__loader__Module__Global__index_mut(__sc39, i); })).ast = back);
  {
    __auto_type __sc40 = (!had);
    typechecker__typechecker__TypeChecker__free(&t);
    return __sc40;
  }
}

static __attribute__((unused)) void main__flush_assert_err(void *const ctx, uint16_t const m, uint32_t const cond, const char *const msg) {
  module__loader__Package *const p = ((module__loader__Package *)ctx);
  const lexer__token__Span sp = ast__ast__Ast__at_const(&(*({ __auto_type __sc41 = &(*p).modules; Vector__module__loader__Module__Global__index(__sc41, ((size_t)m)); })).ast, cond)->span;
  const uint8_t *const src = ({ __auto_type __sc42 = String__Global__as_str(&(*({ __auto_type __sc43 = &(*p).modules; Vector__module__loader__Module__Global__index(__sc43, ((size_t)m)); })).source); str__ptr(&__sc42); });
  const size_t len = String__Global__len(&(*({ __auto_type __sc44 = &(*p).modules; Vector__module__loader__Module__Global__index(__sc44, ((size_t)m)); })).source);
  const char *const file = String__Global__cstr(&(*({ __auto_type __sc45 = &(*p).modules; Vector__module__loader__Module__Global__index_mut(__sc45, ((size_t)m)); })).file);
  utils__errors__Errors errs = utils__errors__Errors__new();
  if (msg != NULL) {
    utils__errors__Errors__emit(&errs, sp.start, (sp.end - sp.start), ({ String__Global __sc46 = String__Global__new();
String__Global__push_str(&__sc46, (str){ .ptr = (const uint8_t*)"static assertion cannot be evaluated: ", .len = sizeof("static assertion cannot be evaluated: ") - 1 });
String__Global__push_str(&__sc46, utils__errors__cstr(msg));
__sc46; }));
  } else {
    utils__errors__Errors__emit(&errs, sp.start, (sp.end - sp.start), ({ String__Global __sc47 = String__Global__new();
String__Global__push_str(&__sc47, (str){ .ptr = (const uint8_t*)"static assertion failed", .len = sizeof("static assertion failed") - 1 });
__sc47; }));
  }
  utils__errors__Errors__finalize(&errs, src, len, file);
  utils__errors__Errors__log(&errs);
  utils__errors__Errors__free(&errs);
  ((*p).ok = false);
}

static __attribute__((unused)) void main__ext_rel(const char *const file, const char *const v, int32_t const vl, char *const out) {
  char *slash = NULL;
  if (file != NULL) {
    (slash = strrchr(file, 47));
  }
  if (slash != NULL) {
    const int32_t dlen = ((int32_t)(((size_t)slash) - ((size_t)file)));
    snprintf(out, 4096ULL, ((const char *)({ __auto_type __sc48 = (str){ (const uint8_t *)"%.*s/%.*s", sizeof("%.*s/%.*s") - 1 }; str__ptr(&__sc48); })), dlen, file, vl, v);
  } else {
    snprintf(out, 4096ULL, ((const char *)({ __auto_type __sc49 = (str){ (const uint8_t *)"%.*s", sizeof("%.*s") - 1 }; str__ptr(&__sc49); })), vl, v);
  }
}

static __attribute__((unused)) void main__ext_c_wrap(str const root, Vector__String__Global__Global *const keep, Vector__String__Global__Global *const seen, uint32_t *const nsrc, const char *const rsl, bool *const err) {
  for (size_t k = 0ULL; k < Vector__String__Global__Global__len(seen); k++) {
    if (({ __auto_type __sc50 = String__Global__as_str(&(*({ __auto_type __sc52 = seen; Vector__String__Global__Global__index(__sc52, k); }))); __auto_type __sc51 = str__from_cstr(rsl); str__eq(&__sc50, &__sc51); })) {
      return;
    }
  }
  Vector__String__Global__Global__push(seen, String__Global__from_cstr(rsl));
  const char *basep = ((const char *)strrchr(rsl, 47));
  if (basep != NULL) {
    (basep = (basep + 1));
  } else {
    (basep = rsl);
  }
  main__Buf64 stem = (main__Buf64){0};
  size_t sl = 0ULL;
  const char *sp = basep;
  while ((((*sp) != 0) && ((*sp) != 46)) && (sl < 63ULL)) {
    const char c = (*sp);
    const bool good = ((((c >= 97) && (c <= 122)) || ((c >= 65) && (c <= 90))) || ((c >= 48) && (c <= 57)));
    (stem.b[sl] = ({
      char __sc53;
      if (good) {
        __sc53 = c;
      } else {
        __sc53 = 95;
      }
      __sc53;
    }));
    (sl = (sl + 1ULL));
    (sp = (sp + 1));
  }
  (stem.b[sl] = 0);
  main__Buf128 nm = (main__Buf128){0};
  const uint32_t idx = (*nsrc);
  ((*nsrc) = (idx + 1U));
  snprintf(((char *)(&nm.b[0])), 128ULL, ((const char *)({ __auto_type __sc54 = (str){ (const uint8_t *)"__ext%u_%s", sizeof("__ext%u_%s") - 1 }; str__ptr(&__sc54); })), idx, ((const char *)(&stem.b[0])));
  String__Global path = main__build_out_path(root, str__from_cstr(((const char *)(&nm.b[0]))), (str){ (const uint8_t *)".c", sizeof(".c") - 1 });
  FILE *const f = main__open_out(String__Global__as_str(&path));
  if (f == NULL) {
    perror(String__Global__cstr(&path));
    ((*err) = true);
    return;
  }
  fprintf(f, ((const char *)({ __auto_type __sc55 = (str){ (const uint8_t *)"/* external C source pulled into the build -- generated, do not edit */\n#include \"%s\"\n", sizeof("/* external C source pulled into the build -- generated, do not edit */\n#include \"%s\"\n") - 1 }; str__ptr(&__sc55); })), rsl);
  fclose(f);
  Vector__String__Global__Global__push(keep, path);
}

static __attribute__((unused)) void main__ext_c_collect(module__loader__Package *const p, Vector__String__Global__Global *const keep, bool *const err) {
  const str root = String__Global__as_str(&p->root_dir);
  Vector__String__Global__Global ld = Vector__String__Global__Global__new();
  Vector__String__Global__Global seen = Vector__String__Global__Global__new();
  uint32_t nsrc = 0U;
  const size_t n = Vector__module__loader__Module__Global__len(&p->modules);
  for (size_t m = 0ULL; m < n; m++) {
    if (!(*({ __auto_type __sc56 = &p->modules; Vector__module__loader__Module__Global__index(__sc56, m); })).has_ast) {
      continue;
    }
    const char *const file = String__Global__cstr(&(*({ __auto_type __sc57 = &p->modules; Vector__module__loader__Module__Global__index_mut(__sc57, m); })).file);
    const char *const src = ((const char *)({ __auto_type __sc58 = String__Global__as_str(&(*({ __auto_type __sc59 = &p->modules; Vector__module__loader__Module__Global__index(__sc59, m); })).source); str__ptr(&__sc58); }));
    const ast__ast__Ast *const ap = main__mod_ast_c((&(*p)), ((uint16_t)m));
    for (size_t ai = 0ULL; ai < Vector__ast__ast__Attr__Global__len(&(*ap).attrs); ai++) {
      const ast__ast__Attr at = (*({ __auto_type __sc60 = &(*ap).attrs; Vector__ast__ast__Attr__Global__index(__sc60, ai); }));
      const bool is_src = (at.kind == 15U);
      const bool is_link = (at.kind == 16U);
      if (((!is_src) && (!is_link)) || (at.str_span.end <= at.str_span.start)) {
        continue;
      }
      const int32_t vl = ((int32_t)(at.str_span.end - at.str_span.start));
      const char *const v = ((const char *)(src + ((size_t)at.str_span.start)));
      if (is_link) {
        main__Buf128 flag = (main__Buf128){0};
        if ((*v) == 45) {
          snprintf(((char *)(&flag.b[0])), 128ULL, ((const char *)({ __auto_type __sc61 = (str){ (const uint8_t *)"%.*s", sizeof("%.*s") - 1 }; str__ptr(&__sc61); })), vl, v);
        } else {
          snprintf(((char *)(&flag.b[0])), 128ULL, ((const char *)({ __auto_type __sc62 = (str){ (const uint8_t *)"-l%.*s", sizeof("-l%.*s") - 1 }; str__ptr(&__sc62); })), vl, v);
        }
        bool dup = false;
        for (size_t k = 0ULL; k < Vector__String__Global__Global__len(&ld); k++) {
          if (({ __auto_type __sc63 = String__Global__as_str(&(*({ __auto_type __sc65 = &ld; Vector__String__Global__Global__index(__sc65, k); }))); __auto_type __sc64 = str__from_cstr(((const char *)(&flag.b[0]))); str__eq(&__sc63, &__sc64); })) {
            (dup = true);
            break;
          }
        }
        if (!dup) {
          Vector__String__Global__Global__push(&ld, String__Global__from_cstr(((const char *)(&flag.b[0]))));
        }
        continue;
      }
      main__PathBuf rel = (main__PathBuf){0};
      main__PathBuf rsl = (main__PathBuf){0};
      main__ext_rel(file, v, vl, ((char *)(&rel.b[0])));
      if (sc_realpath(((const char *)(&rel.b[0])), ((char *)(&rsl.b[0]))) == NULL) {
        snprintf(((char *)(&rel.b[0])), 4096ULL, ((const char *)({ __auto_type __sc66 = (str){ (const uint8_t *)"%.*s", sizeof("%.*s") - 1 }; str__ptr(&__sc66); })), vl, v);
        if (sc_realpath(((const char *)(&rel.b[0])), ((char *)(&rsl.b[0]))) == NULL) {
          fprintf(stdio__stderr(), ((const char *)({ __auto_type __sc67 = (str){ (const uint8_t *)"error: cannot find C source '%.*s'\n", sizeof("error: cannot find C source '%.*s'\n") - 1 }; str__ptr(&__sc67); })), vl, v);
          ((*err) = true);
          continue;
        }
      }
      main__ext_c_wrap(root, (&(*keep)), (&seen), ((uint32_t *)(&nsrc)), ((const char *)(&rsl.b[0])), err);
    }
    const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*ap)), (*ap).root)->as_data.program.items;
    const uint32_t *const ids = ast__ast__Ast__list(&((*ap)), items);
    for (uint32_t i = 0U; i < items.len; i++) {
      const uint32_t nid = ids[((size_t)i)];
      const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*ap)), nid)->kind;
      const uint32_t hdr = ({
        uint32_t __sc68;
        if (nk == ast__ast__NodeKind_NODE_EXTERN_BLOCK) {
          __sc68 = ast__ast__Ast__at_const(&((*ap)), nid)->as_data.extern_block.header;
        } else {
          __sc68 = ast__ast__NODE_NONE;
        }
        __sc68;
      });
      if (hdr == ast__ast__NODE_NONE) {
        continue;
      }
      const lexer__token__Span hs = ast__ast__Ast__at_const(&((*ap)), hdr)->span;
      const int32_t hl = ({ int32_t __sc_r; if (__builtin_sub_overflow(((int32_t)(hs.end - hs.start)), 2, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; });
      if (hl <= 2) {
        continue;
      }
      const char *const hv = ((const char *)(src + ((size_t)(hs.start + 1U))));
      main__PathBuf rel = (main__PathBuf){0};
      main__PathBuf habs = (main__PathBuf){0};
      main__ext_rel(file, hv, hl, ((char *)(&rel.b[0])));
      if (sc_realpath(((const char *)(&rel.b[0])), ((char *)(&habs.b[0]))) == NULL) {
        continue;
      }
      char *const dot = strrchr(((const char *)(&rel.b[0])), 46);
      if (dot == NULL) {
        continue;
      }
      const size_t dotoff = (((size_t)dot) - ((size_t)((const char *)(&rel.b[0]))));
      if ((dotoff + 2ULL) >= 4096ULL) {
        continue;
      }
      {
        (rel.b[dotoff] = 46);
        (rel.b[(dotoff + 1ULL)] = 99);
        (rel.b[(dotoff + 2ULL)] = 0);
      }
      main__PathBuf cabs = (main__PathBuf){0};
      if (sc_realpath(((const char *)(&rel.b[0])), ((char *)(&cabs.b[0]))) != NULL) {
        main__ext_c_wrap(root, (&(*keep)), (&seen), ((uint32_t *)(&nsrc)), ((const char *)(&cabs.b[0])), err);
      }
    }
  }
  String__Global ldpath = main__build_out_path(root, (str){ (const uint8_t *)"__ldflags", sizeof("__ldflags") - 1 }, (str){ (const uint8_t *)"", sizeof("") - 1 });
  if (Vector__String__Global__Global__len(&ld) != 0ULL) {
    FILE *const f = stdio__fopen(String__Global__as_str(&ldpath), (str){ (const uint8_t *)"w", sizeof("w") - 1 });
    if (f != NULL) {
      for (size_t k = 0ULL; k < Vector__String__Global__Global__len(&ld); k++) {
        fprintf(f, ((const char *)({ __auto_type __sc69 = (str){ (const uint8_t *)"%s\n", sizeof("%s\n") - 1 }; str__ptr(&__sc69); })), String__Global__cstr(&(*({ __auto_type __sc70 = &ld; Vector__String__Global__Global__index_mut(__sc70, k); }))));
      }
      fclose(f);
    }
  } else {
    (void)(sc_unlink(String__Global__cstr(&ldpath)));
  }
  String__Global__free(&ldpath);
  Vector__String__Global__Global__free(&seen);
  Vector__String__Global__Global__free(&ld);
}

static __attribute__((unused)) main__TestPlan main__TestPlan__new(size_t const count) {
  main__TestPlan pl = (main__TestPlan){ .cases = Vector__main__TestCase__Global__new(), .fx_init = Vector__u32__Global__new(), .fx_free = Vector__u32__Global__new(), .fx_type = Vector__ast__ast__DefId__Global__new(), .fx_is_enum = Vector__bool__Global__new(), .suites = Vector__main__TestSuite__Global__new(), .genv_mod = 0U, .genv_init = ast__ast__NODE_NONE, .genv_free = ast__ast__NODE_NONE, .genv_type = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE }, .genv_is_enum = false, .ok = true };
  const size_t m = ({
    size_t __sc71;
    if (count != 0ULL) {
      __sc71 = count;
    } else {
      __sc71 = 1ULL;
    }
    __sc71;
  });
  for (size_t i = 0ULL; i < m; i++) {
    Vector__u32__Global__push(&pl.fx_init, ast__ast__NODE_NONE);
    Vector__u32__Global__push(&pl.fx_free, ast__ast__NODE_NONE);
    Vector__ast__ast__DefId__Global__push(&pl.fx_type, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE });
    Vector__bool__Global__push(&pl.fx_is_enum, false);
  }
  return pl;
}

void main__TestPlan__free(main__TestPlan *const self) {
  Vector__main__TestCase__Global__free(&self->cases);
  Vector__u32__Global__free(&self->fx_init);
  Vector__u32__Global__free(&self->fx_free);
  Vector__ast__ast__DefId__Global__free(&self->fx_type);
  Vector__bool__Global__free(&self->fx_is_enum);
  Vector__main__TestSuite__Global__free(&self->suites);
}

static __attribute__((unused)) void main__test_err(module__loader__Package *const p, uint16_t const m, lexer__token__Span const sp, const char *const msg) {
  const uint8_t *const src = ({ __auto_type __sc72 = String__Global__as_str(&(*({ __auto_type __sc73 = &p->modules; Vector__module__loader__Module__Global__index(__sc73, ((size_t)m)); })).source); str__ptr(&__sc72); });
  const size_t len = String__Global__len(&(*({ __auto_type __sc74 = &p->modules; Vector__module__loader__Module__Global__index(__sc74, ((size_t)m)); })).source);
  const char *const file = String__Global__cstr(&(*({ __auto_type __sc75 = &p->modules; Vector__module__loader__Module__Global__index_mut(__sc75, ((size_t)m)); })).file);
  utils__errors__Errors errs = utils__errors__Errors__new();
  utils__errors__Errors__emit(&errs, sp.start, (sp.end - sp.start), String__Global__from_cstr(msg));
  utils__errors__Errors__finalize(&errs, src, len, file);
  utils__errors__Errors__log(&errs);
  utils__errors__Errors__free(&errs);
  (p->ok = false);
}

static __attribute__((unused)) ast__ast__DefId main__test_type_decl(const module__loader__Package *const p, uint16_t const am, uint32_t const tnode, bool *const is_enum) {
  const ast__ast__DefId none = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  if (tnode == ast__ast__NODE_NONE) {
    return none;
  }
  const ast__ast__Ast *const a = main__mod_ast_c((&(*p)), am);
  const ast__ast__NodeKind tk = ast__ast__Ast__at_const(&((*a)), tnode)->kind;
  if ((tk != ast__ast__NodeKind_NODE_TYPE_PATH) && (tk != ast__ast__NodeKind_NODE_IDENTIFIER)) {
    return none;
  }
  const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), tnode);
  if ((d.node == ast__ast__NODE_NONE) || (((size_t)d.module) >= Vector__module__loader__Module__Global__len(&p->modules))) {
    return none;
  }
  const ast__ast__Ast *const da = main__mod_ast_c((&(*p)), d.module);
  const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*da)), d.node)->kind;
  const ast__ast__NodeList gen = ast__ast__Ast__at_const(&((*da)), d.node)->as_data.aggregate.generics;
  if (((dk != ast__ast__NodeKind_NODE_STRUCT) && (dk != ast__ast__NodeKind_NODE_ENUM)) || (gen.len != 0U)) {
    return none;
  }
  ((*is_enum) = (dk == ast__ast__NodeKind_NODE_ENUM));
  return d;
}

static __attribute__((unused)) uint32_t main__test_fn_ret_node(const module__loader__Package *const p, uint16_t const am, uint32_t const fnode) {
  const ast__ast__Ast *const a = main__mod_ast_c((&(*p)), am);
  const ast__ast__NodeList rets = ast__ast__Ast__at_const(&((*a)), fnode)->as_data.function.returns;
  if (rets.len != 1U) {
    return ast__ast__NODE_NONE;
  }
  const uint32_t r0 = ast__ast__Ast__list(&((*a)), rets)[0];
  const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*a)), r0);
  if (rn->kind == ast__ast__NodeKind_NODE_PARAMETER) {
    return rn->as_data.parameter.ty;
  }
  return r0;
}

static __attribute__((unused)) bool main__test_fn_returns_nothing(const module__loader__Package *const p, uint16_t const am, const char *const src, uint32_t const fnode) {
  const ast__ast__Ast *const a = main__mod_ast_c((&(*p)), am);
  const ast__ast__NodeList rets = ast__ast__Ast__at_const(&((*a)), fnode)->as_data.function.returns;
  if (rets.len == 0U) {
    return true;
  }
  const uint32_t rn = main__test_fn_ret_node((&(*p)), am, fnode);
  if (rn == ast__ast__NODE_NONE) {
    return false;
  }
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*a)), rn);
  if (n->kind != ast__ast__NodeKind_NODE_IDENTIFIER) {
    return false;
  }
  const lexer__token__Span t = n->as_data.name.text;
  if ((t.end - t.start) != 4U) {
    return false;
  }
  return (memcmp((src + ((size_t)t.start)), ({ __auto_type __sc76 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc76); }), 4ULL) == 0);
}

static __attribute__((unused)) uint8_t main__test_param_bit(module__loader__Package *const p, uint16_t const m, uint32_t const pnode, ast__ast__DefId const fx, ast__ast__DefId const genv) {
  const ast__ast__Ast *const a = main__mod_ast_c((&(*p)), m);
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), pnode)->span;
  const uint32_t tnode = ast__ast__Ast__at_const(&((*a)), pnode)->as_data.parameter.ty;
  const ast__ast__NodeKind tk = ({
    ast__ast__NodeKind __sc77;
    if (tnode != ast__ast__NODE_NONE) {
      __sc77 = ast__ast__Ast__at_const(&((*a)), tnode)->kind;
    } else {
      __sc77 = ast__ast__NodeKind_NODE_NONE_KIND;
    }
    __sc77;
  });
  if ((tnode == ast__ast__NODE_NONE) || (tk != ast__ast__NodeKind_NODE_REFERENCE_TYPE)) {
    main__test_err((&(*p)), m, sp, ((const char *)({ __auto_type __sc78 = (str){ (const uint8_t *)"a '@test' parameter must be a reference to the module fixture or the global env", sizeof("a '@test' parameter must be a reference to the module fixture or the global env") - 1 }; str__ptr(&__sc78); })));
    return 0U;
  }
  const ast__ast__IndirectTypeData it = ast__ast__Ast__at_const(&((*a)), tnode)->as_data.indirect_type;
  bool is_enum = false;
  const ast__ast__DefId d = main__test_type_decl((&(*p)), m, it.ty, ((bool *)(&is_enum)));
  if (((fx.node != ast__ast__NODE_NONE) && (d.module == fx.module)) && (d.node == fx.node)) {
    return 1U;
  }
  if (((genv.node != ast__ast__NODE_NONE) && (d.module == genv.module)) && (d.node == genv.node)) {
    if (it.qualifier == ast__ast__TypeQualifier_TYPE_QUAL_MUT) {
      main__test_err((&(*p)), m, sp, ((const char *)({ __auto_type __sc79 = (str){ (const uint8_t *)"the global test env is shared: take it as '&', not '&mut'", sizeof("the global test env is shared: take it as '&', not '&mut'") - 1 }; str__ptr(&__sc79); })));
      return 0U;
    }
    return 2U;
  }
  main__test_err((&(*p)), m, sp, ((const char *)({ __auto_type __sc80 = (str){ (const uint8_t *)"this parameter matches neither the module's '@test_init' fixture nor the global env", sizeof("this parameter matches neither the module's '@test_init' fixture nor the global env") - 1 }; str__ptr(&__sc80); })));
  return 0U;
}

static __attribute__((unused)) uint32_t main__test_owner_extend(const module__loader__Package *const p, uint16_t const am, uint32_t const fnode, bool *const bad) {
  const ast__ast__Ast *const a = main__mod_ast_c((&(*p)), am);
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
  const uint32_t *const ids = ast__ast__Ast__list(&((*a)), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t iid = ids[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), iid)->kind == ast__ast__NodeKind_NODE_EXTEND) {
      const ast__ast__ExtendData ed = ast__ast__Ast__at_const(&((*a)), iid)->as_data.extend_def;
      const uint32_t *const mids = ast__ast__Ast__list(&((*a)), ed.items);
      for (uint32_t j = 0U; j < ed.items.len; j++) {
        if (mids[((size_t)j)] == fnode) {
          ((*bad) = ((ed.interface_type != ast__ast__NODE_NONE) || (ed.generics.len != 0U)));
          return iid;
        }
      }
    }
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) int32_t main__plan_suite_of(main__TestPlan *const plan, uint16_t const m, ast__ast__DefId const ty, bool const is_enum, bool const create) {
  for (size_t i = 0ULL; i < Vector__main__TestSuite__Global__len(&plan->suites); i++) {
    const main__TestSuite *const s = Vector__main__TestSuite__Global__at(&plan->suites, i);
    if (((s->mod == m) && (s->ty.module == ty.module)) && (s->ty.node == ty.node)) {
      return ((int32_t)i);
    }
  }
  if (!create) {
    return -1;
  }
  Vector__main__TestSuite__Global__push(&plan->suites, (main__TestSuite){ .mod = m, .ty = ty, .is_enum = is_enum, .init = ast__ast__NODE_NONE, .fre = ast__ast__NODE_NONE });
  return ((int32_t)(Vector__main__TestSuite__Global__len(&plan->suites) - 1ULL));
}

static __attribute__((unused)) void main__test_plan_build(module__loader__Package *const p, main__TestPlan *const plan) {
  const size_t n = Vector__module__loader__Module__Global__len(&p->modules);
  for (size_t m = 0ULL; m < n; m++) {
    if ((!(*({ __auto_type __sc81 = &p->modules; Vector__module__loader__Module__Global__index(__sc81, m); })).has_ast) || (*({ __auto_type __sc82 = &p->modules; Vector__module__loader__Module__Global__index(__sc82, m); })).prelude) {
      continue;
    }
    const char *const src = ((const char *)({ __auto_type __sc83 = String__Global__as_str(&(*({ __auto_type __sc84 = &p->modules; Vector__module__loader__Module__Global__index(__sc84, m); })).source); str__ptr(&__sc83); }));
    const size_t nattr = Vector__ast__ast__Attr__Global__len(&(*main__mod_ast_c((&(*p)), ((uint16_t)m))).attrs);
    for (size_t ai = 0ULL; ai < nattr; ai++) {
      const ast__ast__Attr at = (*({ __auto_type __sc85 = &(*main__mod_ast_c((&(*p)), ((uint16_t)m))).attrs; Vector__ast__ast__Attr__Global__index(__sc85, ai); }));
      if ((at.kind != 13U) && (at.kind != 14U)) {
        continue;
      }
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), at.owner)->span;
      bool bad_ext = false;
      const uint32_t ext = main__test_owner_extend((&(*p)), ((uint16_t)m), at.owner, ((bool *)(&bad_ext)));
      if ((ext != ast__ast__NODE_NONE) && bad_ext) {
        main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc86 = (str){ (const uint8_t *)"test attributes are only allowed on methods of a non-generic inherent 'extend'", sizeof("test attributes are only allowed on methods of a non-generic inherent 'extend'") - 1 }; str__ptr(&__sc86); })));
        continue;
      }
      ast__ast__DefId target = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
      bool target_is_enum = false;
      if (ext != ast__ast__NODE_NONE) {
        if (at.arg != 0U) {
          main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc87 = (str){ (const uint8_t *)"'(global)' is not allowed on a method; declare the global pair at top level", sizeof("'(global)' is not allowed on a method; declare the global pair at top level") - 1 }; str__ptr(&__sc87); })));
          continue;
        }
        const uint32_t tt = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), ext)->as_data.extend_def.target_type;
        (target = main__test_type_decl((&(*p)), ((uint16_t)m), tt, ((bool *)(&target_is_enum))));
        if (target.node == ast__ast__NODE_NONE) {
          main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc88 = (str){ (const uint8_t *)"a test suite's extend target must be a plain (non-generic) struct or enum", sizeof("a test suite's extend target must be a plain (non-generic) struct or enum") - 1 }; str__ptr(&__sc88); })));
          continue;
        }
      }
      if (at.kind == 13U) {
        const uint32_t plen = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), at.owner)->as_data.function.params.len;
        if (plen != 0U) {
          main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc89 = (str){ (const uint8_t *)"'@test_init' takes no parameters", sizeof("'@test_init' takes no parameters") - 1 }; str__ptr(&__sc89); })));
          continue;
        }
        bool is_enum = false;
        const uint32_t ret = main__test_fn_ret_node((&(*p)), ((uint16_t)m), at.owner);
        const ast__ast__DefId d = main__test_type_decl((&(*p)), ((uint16_t)m), ret, ((bool *)(&is_enum)));
        if (d.node == ast__ast__NODE_NONE) {
          main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc90 = (str){ (const uint8_t *)"'@test_init' must return a plain (non-generic) struct or enum fixture", sizeof("'@test_init' must return a plain (non-generic) struct or enum fixture") - 1 }; str__ptr(&__sc90); })));
          continue;
        }
        if (ext != ast__ast__NODE_NONE) {
          if ((d.module != target.module) || (d.node != target.node)) {
            main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc91 = (str){ (const uint8_t *)"a suite '@test_init' method must return the extended type itself", sizeof("a suite '@test_init' method must return the extended type itself") - 1 }; str__ptr(&__sc91); })));
            continue;
          }
          const int32_t si = main__plan_suite_of((&(*plan)), ((uint16_t)m), target, target_is_enum, true);
          if ((*({ __auto_type __sc92 = &plan->suites; Vector__main__TestSuite__Global__index(__sc92, ((size_t)si)); })).init != ast__ast__NODE_NONE) {
            main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc93 = (str){ (const uint8_t *)"duplicate suite '@test_init' (one per type per module)", sizeof("duplicate suite '@test_init' (one per type per module)") - 1 }; str__ptr(&__sc93); })));
            continue;
          }
          ((*({ __auto_type __sc94 = &plan->suites; Vector__main__TestSuite__Global__index_mut(__sc94, ((size_t)si)); })).init = at.owner);
        } else if (at.arg != 0U) {
          if (plan->genv_init != ast__ast__NODE_NONE) {
            main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc95 = (str){ (const uint8_t *)"duplicate '@test_init(global)' (one per test tree)", sizeof("duplicate '@test_init(global)' (one per test tree)") - 1 }; str__ptr(&__sc95); })));
            continue;
          }
          (plan->genv_mod = ((uint16_t)m));
          (plan->genv_init = at.owner);
          (plan->genv_type = d);
          (plan->genv_is_enum = is_enum);
        } else {
          if ((*({ __auto_type __sc96 = &plan->fx_init; Vector__u32__Global__index(__sc96, m); })) != ast__ast__NODE_NONE) {
            main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc97 = (str){ (const uint8_t *)"duplicate '@test_init' (one per module)", sizeof("duplicate '@test_init' (one per module)") - 1 }; str__ptr(&__sc97); })));
            continue;
          }
          (*Vector__u32__Global__index_mut(&plan->fx_init, m) = at.owner);
          (*Vector__ast__ast__DefId__Global__index_mut(&plan->fx_type, m) = d);
          (*Vector__bool__Global__index_mut(&plan->fx_is_enum, m) = is_enum);
        }
      } else {
        if (ext == ast__ast__NODE_NONE) {
          continue;
        }
        bool ok = false;
        const ast__ast__NodeList params = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), at.owner)->as_data.function.params;
        if ((params.len == 1U) && main__test_fn_returns_nothing((&(*p)), ((uint16_t)m), src, at.owner)) {
          const uint32_t p0 = ast__ast__Ast__list(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), params)[0];
          const uint32_t pty = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), p0)->as_data.parameter.ty;
          const ast__ast__NodeKind ptk = ({
            ast__ast__NodeKind __sc98;
            if (pty != ast__ast__NODE_NONE) {
              __sc98 = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), pty)->kind;
            } else {
              __sc98 = ast__ast__NodeKind_NODE_NONE_KIND;
            }
            __sc98;
          });
          if ((pty != ast__ast__NODE_NONE) && (ptk == ast__ast__NodeKind_NODE_REFERENCE_TYPE)) {
            const ast__ast__IndirectTypeData it = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), pty)->as_data.indirect_type;
            bool ie = false;
            const ast__ast__DefId d = main__test_type_decl((&(*p)), ((uint16_t)m), it.ty, ((bool *)(&ie)));
            (ok = (((it.qualifier == ast__ast__TypeQualifier_TYPE_QUAL_MUT) && (d.module == target.module)) && (d.node == target.node)));
          }
        }
        if (!ok) {
          main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc99 = (str){ (const uint8_t *)"a suite '@test_free' must be 'fn(self: &mut <the extended type>)' returning nothing", sizeof("a suite '@test_free' must be 'fn(self: &mut <the extended type>)' returning nothing") - 1 }; str__ptr(&__sc99); })));
          continue;
        }
        const int32_t si = main__plan_suite_of((&(*plan)), ((uint16_t)m), target, target_is_enum, true);
        if ((*({ __auto_type __sc100 = &plan->suites; Vector__main__TestSuite__Global__index(__sc100, ((size_t)si)); })).fre != ast__ast__NODE_NONE) {
          main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc101 = (str){ (const uint8_t *)"duplicate suite '@test_free'", sizeof("duplicate suite '@test_free'") - 1 }; str__ptr(&__sc101); })));
          continue;
        }
        ((*({ __auto_type __sc102 = &plan->suites; Vector__main__TestSuite__Global__index_mut(__sc102, ((size_t)si)); })).fre = at.owner);
      }
    }
  }
  for (size_t m = 0ULL; m < n; m++) {
    if ((!(*({ __auto_type __sc103 = &p->modules; Vector__module__loader__Module__Global__index(__sc103, m); })).has_ast) || (*({ __auto_type __sc104 = &p->modules; Vector__module__loader__Module__Global__index(__sc104, m); })).prelude) {
      continue;
    }
    const char *const src = ((const char *)({ __auto_type __sc105 = String__Global__as_str(&(*({ __auto_type __sc106 = &p->modules; Vector__module__loader__Module__Global__index(__sc106, m); })).source); str__ptr(&__sc105); }));
    const size_t nattr = Vector__ast__ast__Attr__Global__len(&(*main__mod_ast_c((&(*p)), ((uint16_t)m))).attrs);
    for (size_t ai = 0ULL; ai < nattr; ai++) {
      const ast__ast__Attr at = (*({ __auto_type __sc107 = &(*main__mod_ast_c((&(*p)), ((uint16_t)m))).attrs; Vector__ast__ast__Attr__Global__index(__sc107, ai); }));
      if (at.kind != 14U) {
        continue;
      }
      bool be = false;
      if (main__test_owner_extend((&(*p)), ((uint16_t)m), at.owner, ((bool *)(&be))) != ast__ast__NODE_NONE) {
        continue;
      }
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), at.owner)->span;
      const bool global = (at.arg != 0U);
      const ast__ast__DefId want = ({
        ast__ast__DefId __sc108;
        if (global) {
          __sc108 = plan->genv_type;
        } else {
          __sc108 = (*({ __auto_type __sc109 = &plan->fx_type; Vector__ast__ast__DefId__Global__index(__sc109, m); }));
        }
        __sc108;
      });
      const uint32_t has_init = ({
        uint32_t __sc110;
        if (global) {
          __sc110 = plan->genv_init;
        } else {
          __sc110 = (*({ __auto_type __sc111 = &plan->fx_init; Vector__u32__Global__index(__sc111, m); }));
        }
        __sc110;
      });
      if ((has_init == ast__ast__NODE_NONE) || (global && (plan->genv_mod != ((uint16_t)m)))) {
        main__test_err((&(*p)), ((uint16_t)m), sp, ({
          const char *__sc112;
          if (global) {
            __sc112 = ((const char *)({ __auto_type __sc113 = (str){ (const uint8_t *)"'@test_free(global)' has no matching '@test_init(global)' in this module", sizeof("'@test_free(global)' has no matching '@test_init(global)' in this module") - 1 }; str__ptr(&__sc113); }));
          } else {
            __sc112 = ((const char *)({ __auto_type __sc114 = (str){ (const uint8_t *)"'@test_free' has no matching '@test_init' in this module", sizeof("'@test_free' has no matching '@test_init' in this module") - 1 }; str__ptr(&__sc114); }));
          }
          __sc112;
        }));
        continue;
      }
      bool ok = false;
      const ast__ast__NodeList params = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), at.owner)->as_data.function.params;
      if ((params.len == 1U) && main__test_fn_returns_nothing((&(*p)), ((uint16_t)m), src, at.owner)) {
        const uint32_t p0 = ast__ast__Ast__list(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), params)[0];
        const uint32_t pty = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), p0)->as_data.parameter.ty;
        const ast__ast__NodeKind ptk = ({
          ast__ast__NodeKind __sc115;
          if (pty != ast__ast__NODE_NONE) {
            __sc115 = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), pty)->kind;
          } else {
            __sc115 = ast__ast__NodeKind_NODE_NONE_KIND;
          }
          __sc115;
        });
        if ((pty != ast__ast__NODE_NONE) && (ptk == ast__ast__NodeKind_NODE_REFERENCE_TYPE)) {
          const ast__ast__IndirectTypeData it = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), pty)->as_data.indirect_type;
          bool ie = false;
          const ast__ast__DefId d = main__test_type_decl((&(*p)), ((uint16_t)m), it.ty, ((bool *)(&ie)));
          (ok = (((it.qualifier == ast__ast__TypeQualifier_TYPE_QUAL_MUT) && (d.module == want.module)) && (d.node == want.node)));
        }
      }
      if (!ok) {
        main__test_err((&(*p)), ((uint16_t)m), sp, ({
          const char *__sc116;
          if (global) {
            __sc116 = ((const char *)({ __auto_type __sc117 = (str){ (const uint8_t *)"'@test_free(global)' must be 'fn(&mut <fixture>)' returning nothing", sizeof("'@test_free(global)' must be 'fn(&mut <fixture>)' returning nothing") - 1 }; str__ptr(&__sc117); }));
          } else {
            __sc116 = ((const char *)({ __auto_type __sc118 = (str){ (const uint8_t *)"'@test_free' must be 'fn(&mut <fixture>)' returning nothing", sizeof("'@test_free' must be 'fn(&mut <fixture>)' returning nothing") - 1 }; str__ptr(&__sc118); }));
          }
          __sc116;
        }));
        continue;
      }
      if (global) {
        if (plan->genv_free != ast__ast__NODE_NONE) {
          main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc119 = (str){ (const uint8_t *)"duplicate '@test_free(global)'", sizeof("duplicate '@test_free(global)'") - 1 }; str__ptr(&__sc119); })));
          continue;
        }
        (plan->genv_free = at.owner);
      } else {
        if ((*({ __auto_type __sc120 = &plan->fx_free; Vector__u32__Global__index(__sc120, m); })) != ast__ast__NODE_NONE) {
          main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc121 = (str){ (const uint8_t *)"duplicate '@test_free' (one per module)", sizeof("duplicate '@test_free' (one per module)") - 1 }; str__ptr(&__sc121); })));
          continue;
        }
        (*Vector__u32__Global__index_mut(&plan->fx_free, m) = at.owner);
      }
    }
  }
  for (size_t si = 0ULL; si < Vector__main__TestSuite__Global__len(&plan->suites); si++) {
    const main__TestSuite s = (*({ __auto_type __sc122 = &plan->suites; Vector__main__TestSuite__Global__index(__sc122, si); }));
    if ((s.init == ast__ast__NODE_NONE) && (s.fre != ast__ast__NODE_NONE)) {
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), s.mod))), s.fre)->span;
      main__test_err((&(*p)), s.mod, sp, ((const char *)({ __auto_type __sc123 = (str){ (const uint8_t *)"a suite '@test_free' has no matching '@test_init' method on this type in this module", sizeof("a suite '@test_free' has no matching '@test_init' method on this type in this module") - 1 }; str__ptr(&__sc123); })));
    }
  }
  for (size_t m = 0ULL; m < n; m++) {
    if ((!(*({ __auto_type __sc124 = &p->modules; Vector__module__loader__Module__Global__index(__sc124, m); })).has_ast) || (*({ __auto_type __sc125 = &p->modules; Vector__module__loader__Module__Global__index(__sc125, m); })).prelude) {
      continue;
    }
    const char *const src = ((const char *)({ __auto_type __sc126 = String__Global__as_str(&(*({ __auto_type __sc127 = &p->modules; Vector__module__loader__Module__Global__index(__sc127, m); })).source); str__ptr(&__sc126); }));
    const size_t nattr = Vector__ast__ast__Attr__Global__len(&(*main__mod_ast_c((&(*p)), ((uint16_t)m))).attrs);
    for (size_t ai = 0ULL; ai < nattr; ai++) {
      const ast__ast__Attr at = (*({ __auto_type __sc128 = &(*main__mod_ast_c((&(*p)), ((uint16_t)m))).attrs; Vector__ast__ast__Attr__Global__index(__sc128, ai); }));
      if (at.kind != 12U) {
        continue;
      }
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), at.owner)->span;
      bool bad_ext = false;
      const uint32_t ext = main__test_owner_extend((&(*p)), ((uint16_t)m), at.owner, ((bool *)(&bad_ext)));
      if ((ext != ast__ast__NODE_NONE) && bad_ext) {
        main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc129 = (str){ (const uint8_t *)"test attributes are only allowed on methods of a non-generic inherent 'extend'", sizeof("test attributes are only allowed on methods of a non-generic inherent 'extend'") - 1 }; str__ptr(&__sc129); })));
        continue;
      }
      ast__ast__DefId suite = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
      bool suite_is_enum = false;
      if (ext != ast__ast__NODE_NONE) {
        const uint32_t tt = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), ext)->as_data.extend_def.target_type;
        (suite = main__test_type_decl((&(*p)), ((uint16_t)m), tt, ((bool *)(&suite_is_enum))));
        if (suite.node == ast__ast__NODE_NONE) {
          main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc130 = (str){ (const uint8_t *)"a test suite's extend target must be a plain (non-generic) struct or enum", sizeof("a test suite's extend target must be a plain (non-generic) struct or enum") - 1 }; str__ptr(&__sc130); })));
          continue;
        }
      }
      if (!main__test_fn_returns_nothing((&(*p)), ((uint16_t)m), src, at.owner)) {
        main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc131 = (str){ (const uint8_t *)"a '@test' function returns nothing", sizeof("a '@test' function returns nothing") - 1 }; str__ptr(&__sc131); })));
        continue;
      }
      const uint32_t nmnode = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), at.owner)->as_data.function.name;
      const lexer__token__Span nmsp = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), nmnode)->as_data.name.text;
      if (((ext == ast__ast__NODE_NONE) && ((nmsp.end - nmsp.start) == 4U)) && (memcmp((src + ((size_t)nmsp.start)), ({ __auto_type __sc132 = (str){ (const uint8_t *)"main", sizeof("main") - 1 }; str__ptr(&__sc132); }), 4ULL) == 0)) {
        main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc133 = (str){ (const uint8_t *)"'main' cannot be a '@test' (it is replaced by the test runner)", sizeof("'main' cannot be a '@test' (it is replaced by the test runner)") - 1 }; str__ptr(&__sc133); })));
        continue;
      }
      const ast__ast__NodeList params = ast__ast__Ast__at_const(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), at.owner)->as_data.function.params;
      if (params.len > 2U) {
        main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc134 = (str){ (const uint8_t *)"a '@test' function takes at most the fixture (or 'self') and the global env", sizeof("a '@test' function takes at most the fixture (or 'self') and the global env") - 1 }; str__ptr(&__sc134); })));
        continue;
      }
      const ast__ast__DefId fx = ({
        ast__ast__DefId __sc135;
        if (ext != ast__ast__NODE_NONE) {
          __sc135 = suite;
        } else {
          __sc135 = (*({ __auto_type __sc136 = &plan->fx_type; Vector__ast__ast__DefId__Global__index(__sc136, m); }));
        }
        __sc135;
      });
      const ast__ast__DefId genv_ty = ({
        ast__ast__DefId __sc137;
        if (plan->genv_init != ast__ast__NODE_NONE) {
          __sc137 = plan->genv_type;
        } else {
          __sc137 = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
        }
        __sc137;
      });
      uint8_t wants = 0U;
      bool bad = false;
      uint32_t k = 0U;
      while ((k < params.len) && (!bad)) {
        const uint32_t pid = ast__ast__Ast__list(&((*main__mod_ast_c((&(*p)), ((uint16_t)m)))), params)[((size_t)k)];
        const uint8_t bit = main__test_param_bit((&(*p)), ((uint16_t)m), pid, fx, genv_ty);
        if (bit == 0U) {
          (bad = true);
        } else if ((wants & bit) != 0U) {
          main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc138 = (str){ (const uint8_t *)"duplicate '@test' parameter kind", sizeof("duplicate '@test' parameter kind") - 1 }; str__ptr(&__sc138); })));
          (bad = true);
        } else if ((bit == 1U) && ((wants & 2U) != 0U)) {
          main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc139 = (str){ (const uint8_t *)"the fixture ('self') parameter must come before the global env", sizeof("the fixture ('self') parameter must come before the global env") - 1 }; str__ptr(&__sc139); })));
          (bad = true);
        }
        (wants = (wants | bit));
        (k = (k + 1U));
      }
      if (bad) {
        continue;
      }
      uint32_t suite_init = ast__ast__NODE_NONE;
      uint32_t suite_free = ast__ast__NODE_NONE;
      if ((ext != ast__ast__NODE_NONE) && ((wants & 1U) != 0U)) {
        const int32_t si2 = main__plan_suite_of((&(*plan)), ((uint16_t)m), suite, suite_is_enum, false);
        if ((si2 < 0) || ((*({ __auto_type __sc140 = &plan->suites; Vector__main__TestSuite__Global__index(__sc140, ((size_t)si2)); })).init == ast__ast__NODE_NONE)) {
          main__test_err((&(*p)), ((uint16_t)m), sp, ((const char *)({ __auto_type __sc141 = (str){ (const uint8_t *)"no '@test_init' method on this type in this module produces the receiver", sizeof("no '@test_init' method on this type in this module produces the receiver") - 1 }; str__ptr(&__sc141); })));
          continue;
        }
        (suite_init = (*({ __auto_type __sc142 = &plan->suites; Vector__main__TestSuite__Global__index(__sc142, ((size_t)si2)); })).init);
        (suite_free = (*({ __auto_type __sc143 = &plan->suites; Vector__main__TestSuite__Global__index(__sc143, ((size_t)si2)); })).fre);
      }
      const ast__ast__DefId case_suite = ({
        ast__ast__DefId __sc144;
        if ((ext != ast__ast__NODE_NONE) && ((wants & 1U) != 0U)) {
          __sc144 = suite;
        } else {
          __sc144 = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
        }
        __sc144;
      });
      Vector__main__TestCase__Global__push(&plan->cases, (main__TestCase){ .mod = ((uint16_t)m), .func = at.owner, .should_panic = (at.arg != 0U), .wants = wants, .suite = case_suite, .suite_is_enum = suite_is_enum, .suite_init = suite_init, .suite_free = suite_free });
    }
  }
  const bool pok = p->ok;
  (plan->ok = (plan->ok && pok));
}

static __attribute__((unused)) const char *main__test_runner_includes(void) {
  return ((const char *)({ __auto_type __sc145 = (str){ (const uint8_t *)"#include <unistd.h>\n#include <sys/wait.h>\n\n", sizeof("#include <unistd.h>\n#include <sys/wait.h>\n\n") - 1 }; str__ptr(&__sc145); }));
}

static __attribute__((unused)) const char *main__test_runner_main(void) {
  return ((const char *)({ __auto_type __sc146 = (str){ (const uint8_t *)"static int sc_match(const char *name, const char *filter) {\n  return !filter || strstr(name, filter) != NULL;\n}\nint main(int argc, char **argv) {\n  setvbuf(stdout, NULL, _IOLBF, 0); /* forked children must not inherit (and re-flush) buffered lines */\n  int jobs = 0, no_fork = 0;\n  const char *filter = NULL;\n  for (int i = 1; i < argc; i++) {\n    if (!strncmp(argv[i], \"--jobs=\", 7)) jobs = atoi(argv[i] + 7);\n    else if (!strcmp(argv[i], \"--no-fork\")) no_fork = 1;\n    else if (!strncmp(argv[i], \"--filter=\", 9)) filter = argv[i] + 9;\n  }\n  if (jobs < 1) { long n = sysconf(_SC_NPROCESSORS_ONLN); jobs = n > 0 ? (int)n : 1; }\n  int sel[SC_NTESTS > 0 ? SC_NTESTS : 1];\n  int nsel = 0;\n  for (int i = 0; i < SC_NTESTS; i++)\n    if (sc_match(SC_TESTS[i].name, filter)) sel[nsel++] = i;\n  printf(\"running %d test%s\\n\", nsel, nsel == 1 ? \"\" : \"s\");\n  void *genv = NULL;\n  if (nsel > 0) genv = sc_genv_init();\n  int passed = 0, failed = 0, skipped = 0;\n  if (no_fork) {\n    for (int k = 0; k < nsel; k++) {\n      const int i = sel[k];\n      if (SC_TESTS[i].should_panic) {\n        printf(\"test %s ... skipped (should_panic needs fork)\\n\", SC_TESTS[i].name);\n        skipped++;\n        continue;\n      }\n      SC_TESTS[i].fn(genv);\n      printf(\"test %s ... ok\\n\", SC_TESTS[i].name);\n      passed++;\n    }\n  } else {\n    pid_t pid_of[SC_NTESTS > 0 ? SC_NTESTS : 1];\n    int active = 0, next = 0;\n    while (next < nsel || active > 0) {\n      while (active < jobs && next < nsel) {\n        const pid_t pid = fork();\n        if (pid == 0) { SC_TESTS[sel[next]].fn(genv); _exit(0); }\n        if (pid < 0) { perror(\"fork\"); return 101; }\n        pid_of[next++] = pid;\n        active++;\n      }\n      int st = 0;\n      const pid_t done = wait(&st);\n      if (done < 0) break;\n      active--;\n      int ti = -1;\n      for (int k = 0; k < next; k++)\n        if (pid_of[k] == done) { ti = sel[k]; pid_of[k] = -1; break; }\n      if (ti < 0) continue;\n      const int crashed = !(WIFEXITED(st) && WEXITSTATUS(st) == 0);\n      if (crashed == SC_TESTS[ti].should_panic) {\n        printf(\"test %s ... ok%s\\n\", SC_TESTS[ti].name, SC_TESTS[ti].should_panic ? \" (panicked as expected)\" : \"\");\n        passed++;\n      } else {\n        printf(\"test %s ... FAILED%s\\n\", SC_TESTS[ti].name, SC_TESTS[ti].should_panic ? \" (expected a panic)\" : \"\");\n        failed++;\n      }\n      fflush(stdout);\n    }\n  }\n  if (genv) sc_genv_free(genv);\n  if (skipped)\n    printf(\"\\n%d passed, %d failed, %d skipped\\n\", passed, failed, skipped);\n  else\n    printf(\"\\n%d passed, %d failed\\n\", passed, failed);\n  return failed > 100 ? 100 : failed;\n}\n", 2608 }; str__ptr(&__sc146); }));
}

static __attribute__((unused)) Option__String__Global main__write_test_main(module__loader__Package *const p, const main__TestPlan *const plan) {
  String__Global path = main__build_out_path(String__Global__as_str(&p->root_dir), (str){ (const uint8_t *)"__test_main", sizeof("__test_main") - 1 }, (str){ (const uint8_t *)".c", sizeof(".c") - 1 });
  FILE *const f = main__open_out(String__Global__as_str(&path));
  if (f == NULL) {
    perror(String__Global__cstr(&path));
    return (Option__String__Global){ .tag = Option_None };
  }
  fputs(((const char *)({ __auto_type __sc147 = (str){ (const uint8_t *)"/* generated by super-c --test */\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n", sizeof("/* generated by super-c --test */\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n") - 1 }; str__ptr(&__sc147); })), f);
  fputs(main__test_runner_includes(), f);
  for (size_t ci = 0ULL; ci < Vector__main__TestCase__Global__len(&plan->cases); ci++) {
    const main__TestCase tc = (*({ __auto_type __sc148 = &plan->cases; Vector__main__TestCase__Global__index(__sc148, ci); }));
    fprintf(f, ((const char *)({ __auto_type __sc149 = (str){ (const uint8_t *)"extern void __sc_test_w_%u_%u(void *);\n", sizeof("extern void __sc_test_w_%u_%u(void *);\n") - 1 }; str__ptr(&__sc149); })), ((uint32_t)tc.mod), tc.func);
  }
  fputs(((const char *)({ __auto_type __sc150 = (str){ (const uint8_t *)"\ntypedef void (*sc_test_fn)(void *);\nstatic const struct { const char *name; sc_test_fn fn; int should_panic; } SC_TESTS[] = {\n", sizeof("\ntypedef void (*sc_test_fn)(void *);\nstatic const struct { const char *name; sc_test_fn fn; int should_panic; } SC_TESTS[] = {\n") - 1 }; str__ptr(&__sc150); })), f);
  for (size_t ci = 0ULL; ci < Vector__main__TestCase__Global__len(&plan->cases); ci++) {
    const main__TestCase tc = (*({ __auto_type __sc151 = &plan->cases; Vector__main__TestCase__Global__index(__sc151, ci); }));
    const ast__ast__Ast *const a = main__mod_ast_c((&(*p)), tc.mod);
    const uint32_t nmnode = ast__ast__Ast__at_const(&((*a)), tc.func)->as_data.function.name;
    const lexer__token__Span nm = ast__ast__Ast__at_const(&((*a)), nmnode)->as_data.name.text;
    const str modpath = String__Global__as_str(&(*({ __auto_type __sc152 = &p->modules; Vector__module__loader__Module__Global__index(__sc152, ((size_t)tc.mod)); })).path);
    const char *const msrc = ((const char *)({ __auto_type __sc153 = String__Global__as_str(&(*({ __auto_type __sc154 = &p->modules; Vector__module__loader__Module__Global__index(__sc154, ((size_t)tc.mod)); })).source); str__ptr(&__sc153); }));
    fprintf(f, ((const char *)({ __auto_type __sc155 = (str){ (const uint8_t *)"  { \"%.*s::", sizeof("  { \"%.*s::") - 1 }; str__ptr(&__sc155); })), ((int32_t)str__len(&modpath)), str__ptr(&modpath));
    if (tc.suite.node != ast__ast__NODE_NONE) {
      const ast__ast__Ast *const sa = main__mod_ast_c((&(*p)), tc.suite.module);
      const uint32_t snmn = ast__ast__Ast__at_const(&((*sa)), tc.suite.node)->as_data.aggregate.name;
      const lexer__token__Span snm = ast__ast__Ast__at_const(&((*sa)), snmn)->as_data.name.text;
      const char *const ssrc = ((const char *)({ __auto_type __sc156 = String__Global__as_str(&(*({ __auto_type __sc157 = &p->modules; Vector__module__loader__Module__Global__index(__sc157, ((size_t)tc.suite.module)); })).source); str__ptr(&__sc156); }));
      fprintf(f, ((const char *)({ __auto_type __sc158 = (str){ (const uint8_t *)"%.*s::", sizeof("%.*s::") - 1 }; str__ptr(&__sc158); })), ((int32_t)(snm.end - snm.start)), (ssrc + ((size_t)snm.start)));
    }
    const int32_t spflag = ({
      int32_t __sc159;
      if (tc.should_panic) {
        __sc159 = 1;
      } else {
        __sc159 = 0;
      }
      __sc159;
    });
    fprintf(f, ((const char *)({ __auto_type __sc160 = (str){ (const uint8_t *)"%.*s\", __sc_test_w_%u_%u, %d },\n", sizeof("%.*s\", __sc_test_w_%u_%u, %d },\n") - 1 }; str__ptr(&__sc160); })), ((int32_t)(nm.end - nm.start)), (msrc + ((size_t)nm.start)), ((uint32_t)tc.mod), tc.func, spflag);
  }
  fprintf(f, ((const char *)({ __auto_type __sc161 = (str){ (const uint8_t *)"};\nenum { SC_NTESTS = %zu };\n\n", sizeof("};\nenum { SC_NTESTS = %zu };\n\n") - 1 }; str__ptr(&__sc161); })), Vector__main__TestCase__Global__len(&plan->cases));
  if (plan->genv_init != ast__ast__NODE_NONE) {
    fputs(((const char *)({ __auto_type __sc162 = (str){ (const uint8_t *)"extern void *__sc_test_genv_init(void);\nextern void __sc_test_genv_free(void *);\nstatic void *sc_genv_init(void) { return __sc_test_genv_init(); }\nstatic void sc_genv_free(void *p) { __sc_test_genv_free(p); }\n\n", sizeof("extern void *__sc_test_genv_init(void);\nextern void __sc_test_genv_free(void *);\nstatic void *sc_genv_init(void) { return __sc_test_genv_init(); }\nstatic void sc_genv_free(void *p) { __sc_test_genv_free(p); }\n\n") - 1 }; str__ptr(&__sc162); })), f);
  } else {
    fputs(((const char *)({ __auto_type __sc163 = (str){ (const uint8_t *)"static void *sc_genv_init(void) { return NULL; }\nstatic void sc_genv_free(void *p) { (void)p; }\n\n", sizeof("static void *sc_genv_init(void) { return NULL; }\nstatic void sc_genv_free(void *p) { (void)p; }\n\n") - 1 }; str__ptr(&__sc163); })), f);
  }
  fputs(main__test_runner_main(), f);
  fclose(f);
  return (Option__String__Global){ .tag = Option_Some, .payload.Some = { path } };
}

static __attribute__((unused)) int32_t main__test_build_and_run(const module__loader__Package *const p, const main__TestOpts *const topts, const Vector__String__Global__Global *const keep, const char *const out_bin) {
  const char *cc = stdlib__getenv((str){ (const uint8_t *)"CC", sizeof("CC") - 1 });
  if ((cc == NULL) || ((*cc) == 0)) {
    (cc = ((const char *)({ __auto_type __sc164 = (str){ (const uint8_t *)"cc", sizeof("cc") - 1 }; str__ptr(&__sc164); })));
  }
  const str root = String__Global__as_str(&p->root_dir);
  String__Global cmd = String__Global__new();
  String__Global__push_str(&cmd, str__from_cstr(cc));
  if (out_bin != NULL) {
    String__Global__push_str(&cmd, (str){ (const uint8_t *)" -std=c11 -o '", sizeof(" -std=c11 -o '") - 1 });
    String__Global__push_str(&cmd, str__from_cstr(out_bin));
    String__Global__push_str(&cmd, (str){ (const uint8_t *)"'", sizeof("'") - 1 });
  } else {
    String__Global__push_str(&cmd, (str){ (const uint8_t *)" -std=c11 -o '", sizeof(" -std=c11 -o '") - 1 });
    String__Global__push_str(&cmd, root);
    String__Global__push_str(&cmd, (str){ (const uint8_t *)"/build/__tests'", sizeof("/build/__tests'") - 1 });
  }
  for (size_t i = 0ULL; i < Vector__String__Global__Global__len(keep); i++) {
    const str cf = String__Global__as_str(&(*({ __auto_type __sc165 = keep; Vector__String__Global__Global__index(__sc165, i); })));
    if ((str__len(&cf) > 2ULL) && str__ends_with(&cf, (str){ (const uint8_t *)".c", sizeof(".c") - 1 })) {
      String__Global__push_str(&cmd, (str){ (const uint8_t *)" '", sizeof(" '") - 1 });
      String__Global__push_str(&cmd, cf);
      String__Global__push_str(&cmd, (str){ (const uint8_t *)"'", sizeof("'") - 1 });
    }
  }
  String__Global ldpath = main__build_out_path(root, (str){ (const uint8_t *)"__ldflags", sizeof("__ldflags") - 1 }, (str){ (const uint8_t *)"", sizeof("") - 1 });
  FILE *const lf = stdio__fopen(String__Global__as_str(&ldpath), (str){ (const uint8_t *)"rb", sizeof("rb") - 1 });
  if (lf != NULL) {
    main__PathBuf line = (main__PathBuf){0};
    while (fgets(((char *)(&line.b[0])), 4096, lf) != NULL) {
      const size_t ll = strlen(((const char *)(&line.b[0])));
      if ((ll > 0ULL) && (line.b[(ll - 1ULL)] == 10)) {
        (line.b[(ll - 1ULL)] = 0);
      }
      if (line.b[0] != 0) {
        String__Global__push_str(&cmd, (str){ (const uint8_t *)" ", sizeof(" ") - 1 });
        String__Global__push_str(&cmd, str__from_cstr(((const char *)(&line.b[0]))));
      }
    }
    fclose(lf);
  }
  const int32_t brc = stdlib__system(String__Global__as_str(&cmd));
  if (brc != 0) {
    const char *what = ((const char *)({ __auto_type __sc166 = (str){ (const uint8_t *)"test build", sizeof("test build") - 1 }; str__ptr(&__sc166); }));
    if (out_bin != NULL) {
      (what = ((const char *)({ __auto_type __sc167 = (str){ (const uint8_t *)"build", sizeof("build") - 1 }; str__ptr(&__sc167); })));
    }
    fprintf(stdio__stderr(), ((const char *)({ __auto_type __sc168 = (str){ (const uint8_t *)"super-c: %s failed (%s)\n", sizeof("super-c: %s failed (%s)\n") - 1 }; str__ptr(&__sc168); })), what, cc);
    {
      __auto_type __sc169 = 1;
      String__Global__free(&ldpath);
      String__Global__free(&cmd);
      return __sc169;
    }
  }
  if (out_bin != NULL) {
    {
      __auto_type __sc170 = 0;
      String__Global__free(&ldpath);
      String__Global__free(&cmd);
      return __sc170;
    }
  }
  String__Global run = String__Global__new();
  String__Global__push_str(&run, (str){ (const uint8_t *)"'", sizeof("'") - 1 });
  String__Global__push_str(&run, root);
  String__Global__push_str(&run, (str){ (const uint8_t *)"/build/__tests'", sizeof("/build/__tests'") - 1 });
  if ((*topts).jobs > 0) {
    main__Buf64 jb = (main__Buf64){0};
    snprintf(((char *)(&jb.b[0])), 64ULL, ((const char *)({ __auto_type __sc171 = (str){ (const uint8_t *)" --jobs=%d", sizeof(" --jobs=%d") - 1 }; str__ptr(&__sc171); })), (*topts).jobs);
    String__Global__push_str(&run, str__from_cstr(((const char *)(&jb.b[0]))));
  }
  if ((*topts).no_fork) {
    String__Global__push_str(&run, (str){ (const uint8_t *)" --no-fork", sizeof(" --no-fork") - 1 });
  }
  if ((*topts).filter != NULL) {
    String__Global__push_str(&run, (str){ (const uint8_t *)" '--filter=", sizeof(" '--filter=") - 1 });
    String__Global__push_str(&run, str__from_cstr((*topts).filter));
    String__Global__push_str(&run, (str){ (const uint8_t *)"'", sizeof("'") - 1 });
  }
  const int32_t rrc = stdlib__system(String__Global__as_str(&run));
  if (rrc < 0) {
    {
      __auto_type __sc172 = 1;
      String__Global__free(&run);
      String__Global__free(&ldpath);
      String__Global__free(&cmd);
      return __sc172;
    }
  }
  if (sc_wifexited(rrc) != 0) {
    {
      __auto_type __sc173 = sc_wexitstatus(rrc);
      String__Global__free(&run);
      String__Global__free(&ldpath);
      String__Global__free(&cmd);
      return __sc173;
    }
  }
  {
    __auto_type __sc174 = 1;
    String__Global__free(&run);
    String__Global__free(&ldpath);
    String__Global__free(&cmd);
    return __sc174;
  }
}

static __attribute__((unused)) void main__platform_filter(module__loader__Package *const p, int32_t const target) {
  const size_t n = Vector__module__loader__Module__Global__len(&p->modules);
  for (size_t mi = 0ULL; mi < n; mi++) {
    module__loader__Module *const m = (&(*({ __auto_type __sc175 = &p->modules; Vector__module__loader__Module__Global__index_mut(__sc175, mi); })));
    const uint32_t root = m->ast.root;
    if (ast__ast__Ast__at_const(&m->ast, root)->kind != ast__ast__NodeKind_NODE_PROGRAM) {
      continue;
    }
    const ast__ast__NodeList items = ast__ast__Ast__at_const(&m->ast, root)->as_data.program.items;
    uint32_t w = 0U;
    for (uint32_t j = 0U; j < items.len; j++) {
      const uint32_t id = (*({ __auto_type __sc176 = &m->ast.children; Vector__u32__Global__index(__sc176, ((size_t)(items.start + j))); }));
      bool keep = true;
      if (ast__ast__Ast__at_const(&m->ast, id)->kind != ast__ast__NodeKind_NODE_IMPORT) {
        for (size_t k = 0ULL; k < Vector__ast__ast__Attr__Global__len(&m->ast.attrs); k++) {
          const ast__ast__Attr *const at = Vector__ast__ast__Attr__Global__at(&m->ast.attrs, k);
          if ((at->owner == id) && (at->kind == 18U)) {
            if ((({ uint32_t __sc177 = at->arg; int64_t __sc178 = (int64_t)(((uint32_t)target)); if ((uint64_t)__sc178 >= 32) { __sc_panic("shift out of range"); } (uint32_t)(__sc177 >> __sc178); }) & 1U) == 0U) {
              (keep = false);
            }
            break;
          }
        }
      }
      if (keep) {
        (*Vector__u32__Global__index_mut(&m->ast.children, ((size_t)(items.start + w))) = id);
        (w = (w + 1U));
      }
    }
    (ast__ast__Ast__at(&m->ast, root)->as_data.program.items.len = w);
  }
}

static __attribute__((unused)) int32_t main__run_package(module__loader__Package *const p, const main__TestOpts *const topts, const char *const out_bin, int32_t const target) {
  main__platform_filter((&(*p)), target);
  const size_t n = Vector__module__loader__Module__Global__len(&p->modules);
  for (size_t i = 0ULL; i < n; i++) {
    const bool ok = main__resolve_module((&(*p)), i);
    (p->ok = (ok && p->ok));
  }
  if (!p->ok) {
    return 1;
  }
  for (size_t i = 0ULL; i < n; i++) {
    const bool ok = main__typecheck_module((&(*p)), i);
    (p->ok = (ok && p->ok));
  }
  if (!p->ok) {
    return 1;
  }
  consteval__consteval__ConstEval *const ceptr = ((consteval__consteval__ConstEval *)p->ceval);
  if (ceptr != NULL) {
    module__loader__Package *const pv = ((module__loader__Package *)(&(*p)));
    consteval__consteval__ConstEval__flush_asserts(&((*ceptr)), main__flush_assert_err, ((void *)pv));
  }
  if (!p->ok) {
    return 1;
  }
  module__loader__package_propagate_instances((&(*p)));
  const bool testing = ((topts != NULL) && (*topts).enabled);
  main__TestPlan plan = main__TestPlan__new(n);
  if (testing) {
    main__test_plan_build((&(*p)), (&plan));
    if (!plan.ok) {
      {
        __auto_type __sc179 = 1;
        main__TestPlan__free(&plan);
        return __sc179;
      }
    }
  }
  main__write_super_rt(String__Global__as_str(&p->root_dir));
  const str root = String__Global__as_str(&p->root_dir);
  Vector__String__Global__Global keep = Vector__String__Global__Global__new();
  Vector__String__Global__Global__push(&keep, main__build_out_path(root, (str){ (const uint8_t *)"super_rt", sizeof("super_rt") - 1 }, (str){ (const uint8_t *)".h", sizeof(".h") - 1 }));
  bool err = false;
  main__ext_c_collect((&(*p)), (&keep), ((bool *)(&err)));
  bool *const live = main__compute_emit_live((&(*p)));
  const size_t osz = ({
    size_t __sc180;
    if (n != 0ULL) {
      __sc180 = n;
    } else {
      __sc180 = 1ULL;
    }
    __sc180;
  });
  uint16_t *const order = ((uint16_t *)malloc((osz * 2ULL)));
  if (order == NULL) {
    if (live != NULL) {
      free(((void *)live));
    }
    {
      __auto_type __sc181 = 1;
      Vector__String__Global__Global__free(&keep);
      main__TestPlan__free(&plan);
      return __sc181;
    }
  }
  module__loader__package_emit_order((&(*p)), order);
  for (size_t oi = 0ULL; oi < n; oi++) {
    const uint16_t mi = order[oi];
    if ((live != NULL) && (!live[((size_t)mi)])) {
      continue;
    }
    ast__ast__Ast *const m_ast = main__mod_ast_m((&(*p)), mi);
    const char *const src = ((const char *)({ __auto_type __sc182 = String__Global__as_str(&(*({ __auto_type __sc183 = &p->modules; Vector__module__loader__Module__Global__index(__sc183, ((size_t)mi)); })).source); str__ptr(&__sc182); }));
    const size_t slen = String__Global__len(&(*({ __auto_type __sc184 = &p->modules; Vector__module__loader__Module__Global__index(__sc184, ((size_t)mi)); })).source);
    const str mpath = String__Global__as_str(&(*({ __auto_type __sc185 = &p->modules; Vector__module__loader__Module__Global__index(__sc185, ((size_t)mi)); })).path);
    module__loader__Package *const pkg = ((module__loader__Package *)(&(*p)));
    codegen__codegen__Codegen c = codegen__codegen__Codegen__new(m_ast, str__from_raw(((const uint8_t *)src), slen), pkg);
    codegen__codegen__Codegen__set_multifile(&c, true);
    main__TCases tcases = (main__TCases){0};
    if (testing) {
      uint32_t nt = 0U;
      size_t tk = 0ULL;
      while ((tk < Vector__main__TestCase__Global__len(&plan.cases)) && (nt < 512U)) {
        const main__TestCase tc = (*({ __auto_type __sc186 = &plan.cases; Vector__main__TestCase__Global__index(__sc186, tk); }));
        if (tc.mod == mi) {
          (tcases.c[((size_t)nt)] = (codegen__codegen__CgTestCase){ .func = tc.func, .wants = tc.wants, .suite = tc.suite, .suite_is_enum = tc.suite_is_enum, .suite_init = tc.suite_init, .suite_free = tc.suite_free });
          (nt = (nt + 1U));
        }
        (tk = (tk + 1ULL));
      }
      const uint32_t gi = ({
        uint32_t __sc187;
        if (plan.genv_mod == mi) {
          __sc187 = plan.genv_init;
        } else {
          __sc187 = ast__ast__NODE_NONE;
        }
        __sc187;
      });
      const uint32_t gf = ({
        uint32_t __sc188;
        if (plan.genv_mod == mi) {
          __sc188 = plan.genv_free;
        } else {
          __sc188 = ast__ast__NODE_NONE;
        }
        __sc188;
      });
      const codegen__codegen__CgTestInfo ti = (codegen__codegen__CgTestInfo){ .enabled = true, .cases = ((const codegen__codegen__CgTestCase *)(&tcases.c[0])), .ncases = nt, .fx_init = (*({ __auto_type __sc189 = &plan.fx_init; Vector__u32__Global__index(__sc189, ((size_t)mi)); })), .fx_free = (*({ __auto_type __sc190 = &plan.fx_free; Vector__u32__Global__index(__sc190, ((size_t)mi)); })), .fx_type = (*({ __auto_type __sc191 = &plan.fx_type; Vector__ast__ast__DefId__Global__index(__sc191, ((size_t)mi)); })), .fx_is_enum = (*({ __auto_type __sc192 = &plan.fx_is_enum; Vector__bool__Global__index(__sc192, ((size_t)mi)); })), .genv_init = gi, .genv_free = gf, .genv_type = plan.genv_type, .genv_is_enum = plan.genv_is_enum };
      codegen__codegen__Codegen__set_test_info(&c, ((const codegen__codegen__CgTestInfo *)(&ti)));
    }
    String__Global hpath = main__build_out_path(root, mpath, (str){ (const uint8_t *)".h", sizeof(".h") - 1 });
    bool __mv9724 = false;
    FILE *const hout = main__open_out(String__Global__as_str(&hpath));
    if (hout != NULL) {
      codegen__codegen__Codegen__codegen_emit_header(&c, hout);
      fclose(hout);
    }
    Vector__String__Global__Global__push(&keep, (__mv9724 = true, hpath));
    String__Global opath = main__build_out_path(root, mpath, (str){ (const uint8_t *)".c", sizeof(".c") - 1 });
    bool __mv9763 = false;
    FILE *const out = main__open_out(String__Global__as_str(&opath));
    if (out == NULL) {
      perror(String__Global__cstr(&opath));
      (err = true);
    } else {
      codegen__codegen__Codegen__codegen_emit(&c, out);
      fclose(out);
      if (codegen__codegen__Codegen__has_errors(&c)) {
        codegen__codegen__Codegen__log_errors(&c);
        (err = true);
      }
    }
    Vector__String__Global__Global__push(&keep, (__mv9763 = true, opath));
    if (!__mv9763) String__Global__free(&opath);
    if (!__mv9724) String__Global__free(&hpath);
    codegen__codegen__Codegen__free(&c);
  }
  free(((void *)order));
  if (live != NULL) {
    free(((void *)live));
  }
  main__PathBuf broot = (main__PathBuf){0};
  const int32_t bn = snprintf(((char *)(&broot.b[0])), 4096ULL, ((const char *)({ __auto_type __sc193 = (str){ (const uint8_t *)"%.*s/build", sizeof("%.*s/build") - 1 }; str__ptr(&__sc193); })), ((int32_t)str__len(&root)), ((const char *)str__ptr(&root)));
  if ((bn > 0) && (((size_t)bn) < 4096ULL)) {
    main__prune_orphans(((const char *)(&broot.b[0])), (&keep));
  }
  int32_t rc = ({
    int32_t __sc194;
    if (err) {
      __sc194 = 1;
    } else {
      __sc194 = 0;
    }
    __sc194;
  });
  if (out_bin != NULL) {
    if (!err) {
      (rc = main__test_build_and_run((&(*p)), ((const main__TestOpts *)NULL), (&keep), out_bin));
    }
  } else if (testing && (!err)) {
    if (Vector__main__TestCase__Global__len(&plan.cases) == 0ULL) {
      fputs(((const char *)({ __auto_type __sc195 = (str){ (const uint8_t *)"super-c: no '@test' functions found\n", sizeof("super-c: no '@test' functions found\n") - 1 }; str__ptr(&__sc195); })), stdio__stderr());
      (rc = 1);
    } else {
      {
        const Option__String__Global __sc196 = main__write_test_main((&(*p)), (&plan));
        if (__sc196.tag == Option_Some) {
          String__Global runner = __sc196.payload.Some._0;
          {
            Vector__String__Global__Global__push(&keep, runner);
            (rc = main__test_build_and_run((&(*p)), topts, (&keep), ((const char *)NULL)));
          }
        }
        else if (__sc196.tag == Option_None) {
          {
            (rc = 1);
          }
        }
      }
    }
  }
  {
    __auto_type __sc197 = rc;
    Vector__String__Global__Global__free(&keep);
    main__TestPlan__free(&plan);
    return __sc197;
  }
}

static __attribute__((unused)) int32_t main__run_file(const char *const path, const char *const std_dir, uint32_t const ce_steps, uint64_t const ce_mem, const main__TestOpts *const topts, const char *const out_bin, int32_t const target, bool const bootstrap_tags) {
  module__loader__Package p = module__loader__package_load(path, std_dir, bootstrap_tags);
  int32_t rc = 1;
  if (p.ok) {
    module__loader__Package *const pkg = ((module__loader__Package *)(&p));
    consteval__consteval__ConstEval ceval = consteval__consteval__ConstEval__new(pkg, ce_steps, ce_mem);
    bool __mv10130 = false;
    (p.ceval = ((void *)(&ceval)));
    (rc = main__run_package((&p), topts, out_bin, target));
    (__mv10130 = true, consteval__consteval__ConstEval__free(&ceval));
    if (!__mv10130) consteval__consteval__ConstEval__free(&ceval);
  }
  module__loader__Package__free(&p);
  return rc;
}

static __attribute__((unused)) uint64_t main__parse_size(const char *const s) {
  char *endp = NULL;
  const uint64_t v = strtoul(s, ((void *)(&endp)), 10);
  if ((((size_t)endp) == ((size_t)s)) || (v == 0ULL)) {
    return 0ULL;
  }
  uint64_t mul = 1ULL;
  char *e = endp;
  const char c = (*endp);
  if ((c == 75) || (c == 107)) {
    (mul = 1024ULL);
    (e = (endp + 1));
  } else if ((c == 77) || (c == 109)) {
    (mul = 1048576ULL);
    (e = (endp + 1));
  } else if ((c == 71) || (c == 103)) {
    (mul = 1073741824ULL);
    (e = (endp + 1));
  }
  if ((*e) == 0) {
    return (v * mul);
  }
  return 0ULL;
}

static __attribute__((unused)) char *main__exe_std_dir(const char *const argv0) {
  main__PathBuf buf = (main__PathBuf){0};
  const char *path = argv0;
  if (sc_exe_path(((char *)(&buf.b[0])), 4096U) == 0) {
    (path = ((const char *)(&buf.b[0])));
  }
  char *const s1 = strrchr(path, 47);
  char *const s2 = strrchr(path, 92);
  char *const slash = ({
    char *__sc198;
    if (((size_t)s2) > ((size_t)s1)) {
      __sc198 = s2;
    } else {
      __sc198 = s1;
    }
    __sc198;
  });
  const size_t dirlen = ({
    size_t __sc199;
    if (slash != NULL) {
      __sc199 = (((size_t)slash) - ((size_t)path));
    } else {
      __sc199 = 1ULL;
    }
    __sc199;
  });
  char *const out = ((char *)malloc((dirlen + 5ULL)));
  if (out == NULL) {
    return NULL;
  }
  if (slash != NULL) {
    memcpy(((void *)out), path, dirlen);
  } else {
    (out[0] = 46);
  }
  memcpy(((void *)(out + dirlen)), ({ __auto_type __sc200 = (str){ (const uint8_t *)"/std", sizeof("/std") - 1 }; str__ptr(&__sc200); }), 4ULL);
  (out[(dirlen + 4ULL)] = 0);
  return out;
}

int main(void) {
  const int32_t argc = sc_argc();
  char **const argv = sc_argv();
  uint32_t ce_steps = 0U;
  uint64_t ce_mem = 0ULL;
  const char *file = NULL;
  const char *out_bin = NULL;
  bool build_mode = false;
  main__TestOpts topts = (main__TestOpts){ .enabled = false, .jobs = 0, .no_fork = false, .filter = NULL };
  bool bad = false;
  int32_t target = sc_host_platform();
  bool bootstrap_tags = false;
  int32_t i = 1;
  while (i < argc) {
    const char *const arg = ((const char *)argv[((size_t)i)]);
    if (((!build_mode) && (file == NULL)) && (strcmp(arg, ((const char *)({ __auto_type __sc201 = (str){ (const uint8_t *)"build", sizeof("build") - 1 }; str__ptr(&__sc201); }))) == 0)) {
      (build_mode = true);
    } else if (strcmp(arg, ((const char *)({ __auto_type __sc202 = (str){ (const uint8_t *)"-o", sizeof("-o") - 1 }; str__ptr(&__sc202); }))) == 0) {
      if (({ int32_t __sc_r; if (__builtin_add_overflow(i, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }) < argc) {
        (i = ({ int32_t __sc_r; if (__builtin_add_overflow(i, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
        (out_bin = ((const char *)argv[((size_t)i)]));
      } else {
        (bad = true);
      }
    } else if (strncmp(arg, ((const char *)({ __auto_type __sc203 = (str){ (const uint8_t *)"--const-eval-steps=", sizeof("--const-eval-steps=") - 1 }; str__ptr(&__sc203); })), 19ULL) == 0) {
      const uint64_t v = main__parse_size((arg + 19));
      if ((v == 0ULL) || (v > 4294967295ULL)) {
        (bad = true);
      } else {
        (ce_steps = ((uint32_t)v));
      }
    } else if (strncmp(arg, ((const char *)({ __auto_type __sc204 = (str){ (const uint8_t *)"--const-eval-memory=", sizeof("--const-eval-memory=") - 1 }; str__ptr(&__sc204); })), 20ULL) == 0) {
      (ce_mem = main__parse_size((arg + 20)));
      if (ce_mem == 0ULL) {
        (bad = true);
      }
    } else if (strcmp(arg, ((const char *)({ __auto_type __sc205 = (str){ (const uint8_t *)"--test", sizeof("--test") - 1 }; str__ptr(&__sc205); }))) == 0) {
      (topts.enabled = true);
    } else if (strncmp(arg, ((const char *)({ __auto_type __sc206 = (str){ (const uint8_t *)"--test-jobs=", sizeof("--test-jobs=") - 1 }; str__ptr(&__sc206); })), 12ULL) == 0) {
      (topts.jobs = atoi((arg + 12)));
      if (topts.jobs < 1) {
        (bad = true);
      }
    } else if (strcmp(arg, ((const char *)({ __auto_type __sc207 = (str){ (const uint8_t *)"--test-no-fork", sizeof("--test-no-fork") - 1 }; str__ptr(&__sc207); }))) == 0) {
      (topts.no_fork = true);
    } else if (strncmp(arg, ((const char *)({ __auto_type __sc208 = (str){ (const uint8_t *)"--test-filter=", sizeof("--test-filter=") - 1 }; str__ptr(&__sc208); })), 14ULL) == 0) {
      (topts.filter = (arg + 14));
    } else if (strncmp(arg, ((const char *)({ __auto_type __sc209 = (str){ (const uint8_t *)"--target=", sizeof("--target=") - 1 }; str__ptr(&__sc209); })), 9ULL) == 0) {
      const char *const t = (arg + 9);
      if (strcmp(t, ((const char *)({ __auto_type __sc210 = (str){ (const uint8_t *)"windows", sizeof("windows") - 1 }; str__ptr(&__sc210); }))) == 0) {
        (target = 0);
      } else if (strcmp(t, ((const char *)({ __auto_type __sc211 = (str){ (const uint8_t *)"macos", sizeof("macos") - 1 }; str__ptr(&__sc211); }))) == 0) {
        (target = 1);
      } else if (strcmp(t, ((const char *)({ __auto_type __sc212 = (str){ (const uint8_t *)"linux", sizeof("linux") - 1 }; str__ptr(&__sc212); }))) == 0) {
        (target = 2);
      } else {
        (bad = true);
      }
    } else if (strcmp(arg, ((const char *)({ __auto_type __sc213 = (str){ (const uint8_t *)"--bootstrap-tags", sizeof("--bootstrap-tags") - 1 }; str__ptr(&__sc213); }))) == 0) {
      (bootstrap_tags = true);
    } else if ((arg[0] == 45) && (arg[1] == 45)) {
      (bad = true);
    } else if (file == NULL) {
      (file = arg);
    } else {
      (file = ((const char *)({ __auto_type __sc214 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc214); })));
    }
    (i = ({ int32_t __sc_r; if (__builtin_add_overflow(i, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  if ((!topts.enabled) && (((topts.jobs != 0) || topts.no_fork) || (topts.filter != NULL))) {
    (bad = true);
  }
  if ((out_bin != NULL) && (!build_mode)) {
    (bad = true);
  }
  if (build_mode && topts.enabled) {
    (bad = true);
  }
  if (build_mode && (out_bin == NULL)) {
    (out_bin = ((const char *)({ __auto_type __sc215 = (str){ (const uint8_t *)"a.out", sizeof("a.out") - 1 }; str__ptr(&__sc215); })));
  }
  if ((bad || (file == NULL)) || ((*file) == 0)) {
    fputs(((const char *)({ __auto_type __sc216 = (str){ (const uint8_t *)"Usage: super-c [--const-eval-steps=N] [--const-eval-memory=BYTES[K|M|G]] [--target=windows|macos|linux] [--bootstrap-tags]\n       [--test [--test-jobs=N] [--test-no-fork] [--test-filter=S]] <path/to/script>\n       super-c build [-o <out>] <path/to/script>\n", sizeof("Usage: super-c [--const-eval-steps=N] [--const-eval-memory=BYTES[K|M|G]] [--target=windows|macos|linux] [--bootstrap-tags]\n       [--test [--test-jobs=N] [--test-no-fork] [--test-filter=S]] <path/to/script>\n       super-c build [-o <out>] <path/to/script>\n") - 1 }; str__ptr(&__sc216); })), stdio__stderr());
    return 1;
  }
  const char *const arg0 = ({
    const char *__sc217;
    if (argc > 0) {
      __sc217 = ((const char *)argv[0]);
    } else {
      __sc217 = ((const char *)({ __auto_type __sc218 = (str){ (const uint8_t *)"super-c", sizeof("super-c") - 1 }; str__ptr(&__sc218); }));
    }
    __sc217;
  });
  char *const std_dir = main__exe_std_dir(arg0);
  const int32_t rc = main__run_file(file, ((const char *)std_dir), ce_steps, ce_mem, ((const main__TestOpts *)(&topts)), out_bin, target, bootstrap_tags);
  if (std_dir != NULL) {
    free(((void *)std_dir));
  }
  return rc;
}

