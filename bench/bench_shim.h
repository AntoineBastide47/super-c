#ifndef SC_BENCH_SHIM_H
#define SC_BENCH_SHIM_H

#include <stddef.h>

/* Platform glue for the transpile benchmark: CPU cycles and identification, allocation counting.
   All platform splits live in bench_shim.c. */

long long sc_cpu_cycles(void);                     /* cumulative process CPU cycles; 0 if unavailable */
long long sc_alloc_count(void);                    /* cumulative malloc/calloc/realloc calls by this binary's code */
long long sc_alloc_bytes(void);                    /* cumulative bytes requested by those calls */
int sc_cpu_model(char *buf, size_t cap);           /* nul-terminated CPU brand string; 0 ok, -1 unknown */

#endif
