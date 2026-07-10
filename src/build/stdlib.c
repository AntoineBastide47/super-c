#include "stdlib.h"
#include "__std/core.h"
#include "__std/interfaces.h"
#include "__std/option.h"
#include "__std/range.h"
#include "__std/slice.h"
#include "__std/str.h"
#include "__std/string.h"


Option__String__Global stdlib__get_env(String__Global *const name) {
  const char *const p = getenv(String__Global__cstr(name));
  if (p == NULL) {
    return (Option__String__Global){ .tag = Option_None };
  }
  return (Option__String__Global){ .tag = Option_Some, .payload.Some = { String__Global__from_cstr(p) } };
}

const char *stdlib__getenv(str const name) {
  String__Global n = String__Global__from_str(name);
  {
    __auto_type __sc0 = getenv(String__Global__cstr(&n));
    String__Global__free(&n);
    return __sc0;
  }
}

int32_t stdlib__system(str const command) {
  String__Global c = String__Global__from_str(command);
  {
    __auto_type __sc1 = system(String__Global__cstr(&c));
    String__Global__free(&c);
    return __sc1;
  }
}

int64_t stdlib__parse_int(String__Global *const s) {
  return atol(String__Global__cstr(s));
}

double stdlib__parse_float(String__Global *const s) {
  return atof(String__Global__cstr(s));
}

