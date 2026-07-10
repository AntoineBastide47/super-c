#include "../__std/interfaces.h"
#include "../lexer/lexer.h"
#include "../utils/errors.h"
#include "../ast/parser.h"
#include "../typechecker/typechecker.h"
#include "../codegen/codegen.h"

_Static_assert(sizeof(Global) == 0 && _Alignof(Global) == 1, "super-c layout model mismatch: Global");


void *Global__alloc(Global *const self, size_t const size, size_t const align) {
  (void)self;
  (void)align;
  void *const p = malloc(size);
  if (p == NULL) {
    abort();
  }
  return p;
}

void *Global__realloc(Global *const self, void *const ptr, size_t const old_size, size_t const new_size, size_t const align) {
  (void)self;
  (void)old_size;
  (void)align;
  void *const p = realloc(ptr, new_size);
  if (p == NULL) {
    abort();
  }
  return p;
}

void Global__dealloc(Global *const self, void *const ptr, size_t const size, size_t const align) {
  (void)self;
  (void)size;
  (void)align;
  free(ptr);
}

Global Global__default_(void) {
  return (Global){};
}

