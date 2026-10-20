/* Process CPU time on Windows (see sc_time.h). */
#include "sc_time.h"

#include <windows.h>

long long sc_time_cpu_ns(void) {
  FILETIME c, e, k, u;
  if (!GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u)) return -1;
  ULARGE_INTEGER kt, ut;
  kt.LowPart = k.dwLowDateTime;
  kt.HighPart = k.dwHighDateTime;
  ut.LowPart = u.dwLowDateTime;
  ut.HighPart = u.dwHighDateTime;
  return (long long)((kt.QuadPart + ut.QuadPart) * 100ull); /* FILETIME counts 100 ns units */
}
