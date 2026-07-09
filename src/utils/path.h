#ifndef UTILS_PATH_H
#define UTILS_PATH_H

#include <stddef.h>
#include <stdlib.h>

#if defined(_WIN32)
#  include <io.h>
#endif

static inline char *sc_realpath(const char *const path, char *const out, const size_t cap) {
#if defined(_WIN32)
  if (_access(path, 0) != 0)
    return NULL;
  char *const r = _fullpath(out, path, cap);
  if (r)
    for (char *p = out; *p; p++)
      if (*p == '\\')
        *p = '/';
  return r;
#else
  (void)cap;
  return realpath(path, out);
#endif
}

#endif // UTILS_PATH_H
