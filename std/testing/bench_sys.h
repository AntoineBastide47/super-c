#ifndef SC_BENCH_SYS_H
#define SC_BENCH_SYS_H

#include <stddef.h>

/* Platform glue for std/testing/bench.spc: CPU cycles, CPU time, allocation accounting, resident memory,
   machine identity and an optimisation barrier. Every platform split lives in bench_sys.c, compiled as the
   same-stem sibling of this header; the .spc surface is platform-neutral. Nothing here is reported as zero
   work when it is unavailable: every counter has an availability query beside it. */

/* ---- CPU cycles -------------------------------------------------------------------------------------
   `sc_bs_cycles` is cumulative; `sc_bs_cycles_scope` says what it covers, as bits (0 = unavailable, and
   then `sc_bs_cycles` returns 0 and means nothing):
     SC_BS_CYC_ALL      every thread of the process, not only the caller
     SC_BS_CYC_KERNEL   cycles spent in kernel mode are included
     SC_BS_CYC_EXISTING threads that existed before the first call are counted (Linux opens one perf event
                        per thread alive at that moment, inherited by every thread created later; the
                        first call belongs in `main` before any pool starts) */
#define SC_BS_CYC_ALL 1
#define SC_BS_CYC_KERNEL 2
#define SC_BS_CYC_EXISTING 4
long long sc_bs_cycles(void);
int sc_bs_cycles_scope(void);

/* User plus system CPU time of every thread of the process, in nanoseconds; -1 when unavailable. */
long long sc_bs_cpu_ns(void);

/* ---- allocation accounting ---------------------------------------------------------------------------
   Counted: every `malloc`, `calloc` and `realloc` call made by this binary's own object code (the program,
   std, the runtime, the ffi shims) while accounting is enabled; `realloc` counts its new size. Not
   counted: `free`, aligned allocation calls (std's Global makes them only for types aligned above what
   malloc guarantees), and on macOS the allocations libc makes internally (two-level namespace: libc binds
   its own malloc); glibc binds ours, so on Linux those count too. Windows (no real allocator to forward to
   across CRTs), wasm and libcs other than glibc count nothing: `supported` is 0.

   Accounting is per thread (a cache line per thread, handed out on the thread's first counted call, never
   reclaimed, at most SC_BS_ACCT_THREADS; later threads share one atomic line) so counting costs the owning
   thread two relaxed stores and no other thread anything. A snapshot sums every line: it is exact for
   every allocation that happens-before it (a joined thread, a waited task) and may miss or split the call
   another thread is making at that instant. Disabled, a call costs one relaxed load and a branch. */
#define SC_BS_ACCT_THREADS 1024
int sc_bs_alloc_supported(void);
void sc_bs_alloc_enable(int on);
int sc_bs_alloc_enabled(void);
/* out[0] calls, out[1] bytes requested, out[2] threads that allocated, out[3] 1 when more than
   SC_BS_ACCT_THREADS threads allocated (the excess shared one contended line). */
void sc_bs_alloc_snapshot(long long out[4]);
long long sc_bs_alloc_calls(void);
long long sc_bs_alloc_bytes(void);

/* ---- resident memory: bytes, -1 when unavailable -------------------------------------------------- */
long long sc_bs_rss_peak(void);
long long sc_bs_rss_now(void);

/* ---- identity ---------------------------------------------------------------------------------------- */
int sc_bs_cpu_model(char *buf, size_t cap); /* nul-terminated brand string; 0 ok, -1 unknown */
const char *sc_bs_os(void);                 /* "macos", "linux", "windows", "wasm", "posix" */
const char *sc_bs_arch(void);               /* "aarch64", "x86_64", "wasm32", "unknown" */

/* ---- fresh processes -------------------------------------------------------------------------------
   `sc_bs_fork` forks (0 in the child, the pid in the parent, -1 where there is no fork: Windows, wasm); on
   Linux the child drops the parent's cycle events and opens its own on its first `sc_bs_cycles` call;
   `sc_bs_wait` waits for that child and returns its exit code, 128 plus the signal that killed it, or -1
   when the wait itself failed. `sc_bs_flush` flushes every stdio stream (before a fork, so the child does
   not carry the parent's unwritten output). */
long long sc_bs_fork(void);
int sc_bs_wait(long long pid);
void sc_bs_flush(void);

/* ---- optimisation barrier ---------------------------------------------------------------------------
   Stores `v` to a volatile location: the computation producing `v` cannot be deleted or folded across it,
   however hard LTO tries. `sc_bs_sunk` reads that location back, which is how a test proves the store
   happened. */
void sc_bs_sink(unsigned long long v);
unsigned long long sc_bs_sunk(void);

#endif
