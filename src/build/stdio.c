#include "stdio.h"
#include "__std/core.h"
#include "__std/interfaces.h"
#include "__std/option.h"
#include "__std/range.h"
#include "__std/slice.h"
#include "__std/str.h"
#include "__std/string.h"

_Static_assert(sizeof(stdio__File) == 8 && _Alignof(stdio__File) == 8, "super-c layout model mismatch: stdio__File");

static __attribute__((unused)) void stdio__File__free(stdio__File *const self);
static __attribute__((unused)) size_t stdio__File__write(stdio__File *const self, Slice__u8 const bytes);

Option__stdio__File Option__stdio__File__some(stdio__File value) {
  return (Option__stdio__File){ .tag = Option_Some, .payload.Some = { value } };
}

Option__stdio__File Option__stdio__File__none(void) {
  return (Option__stdio__File){ .tag = Option_None };
}

bool Option__stdio__File__is_some(const Option__stdio__File *const self) {
  {
    const Option__stdio__File *const __sc0 = self;
    if ((*__sc0).tag == Option_Some) {
      return true;
    }
    else if ((*__sc0).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__stdio__File__is_none(const Option__stdio__File *const self) {
  {
    const Option__stdio__File *const __sc1 = self;
    if ((*__sc1).tag == Option_Some) {
      return false;
    }
    else if ((*__sc1).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__stdio__File Option__stdio__File__default_(void) {
  return Option__stdio__File__none();
}

void Option__stdio__File__free(Option__stdio__File *const self) {
  {
    Option__stdio__File *const __sc2 = self;
    if ((*__sc2).tag == Option_Some) {
      const __auto_type v = &((*__sc2).payload.Some._0);
      stdio__File__free(v);
    }
    else if ((*__sc2).tag == Option_None) {
      {
      }
    }
  }
}

Option__stdio__File stdio__File__open(String__Global *const path, String__Global *const mode) {
  FILE *const h = fopen(String__Global__cstr(path), String__Global__cstr(mode));
  if (h == NULL) {
    return (Option__stdio__File){ .tag = Option_None };
  }
  return (Option__stdio__File){ .tag = Option_Some, .payload.Some = { (stdio__File){ .handle = h } } };
}

size_t stdio__File__write_str(stdio__File *const self, const String__Global *const text) {
  return fwrite(((const void *)String__Global__as_ptr(text)), 1ULL, String__Global__len(text), self->handle);
}

String__Global stdio__File__read_all(stdio__File *const self) {
  String__Global out = String__Global__new();
  int32_t c = fgetc(self->handle);
  while (c >= 0) {
    String__Global__push_byte(&out, ((uint8_t)c));
    (c = fgetc(self->handle));
  }
  return out;
}

int32_t stdio__File__flush(stdio__File *const self) {
  return fflush(self->handle);
}

void stdio__File__close(stdio__File *const self) {
  if (self->handle != NULL) {
    fclose(self->handle);
    (self->handle = NULL);
  }
}

static __attribute__((unused)) void stdio__File__free(stdio__File *const self) {
  stdio__File__close(self);
}

static __attribute__((unused)) size_t stdio__File__write(stdio__File *const self, Slice__u8 const bytes) {
  return fwrite(((const void *)Slice__u8__as_ptr(&bytes)), 1ULL, Slice__u8__len(&bytes), self->handle);
}

FILE *stdio__fopen(str const path, str const mode) {
  String__Global p = String__Global__from_str(path);
  String__Global m = String__Global__from_str(mode);
  {
    __auto_type __sc3 = fopen(String__Global__cstr(&p), String__Global__cstr(&m));
    String__Global__free(&m);
    String__Global__free(&p);
    return __sc3;
  }
}

FILE *stdio__stdin(void) {
  return __sc_stdin();
}

FILE *stdio__stdout(void) {
  return __sc_stdout();
}

FILE *stdio__stderr(void) {
  return __sc_stderr();
}

