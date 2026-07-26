/* Platform substrate for the Super-C concurrency runtime (see parallel.md M2). One portable C file
   (`sc_rt.c`, auto-discovered from this header) backs it, branching on the OS internally: POSIX uses
   pthread + ucontext + mmap; Windows uses CONDITION_VARIABLE + fibers + VirtualAlloc. Everything here is
   the raw, unsafe layer the Super-C scheduler is built on -- not a user-facing API. */
#ifndef SC_RT_H
#define SC_RT_H
#include <stdint.h>
#include <stddef.h>

/* Monotonic clock, nanoseconds since an unspecified epoch. */
uint64_t sc_rt_now_ns(void);
/* Logical CPU count (>= 1). */
size_t sc_rt_ncpu(void);

/* Per-OS-thread slot holding the running coroutine pointer (the current-coroutine TLS the scheduler needs).
   The language has no thread-locals; this is that one slot. */
void sc_rt_tls_set(void *p);
void *sc_rt_tls_get(void);

/* Address-based parking on a 32-bit word, futex-style. `sc_rt_park` blocks while `*word == expected`, until
   an `sc_rt_unpark_*` on the same address or (for timeout_ns >= 0) the deadline; timeout_ns < 0 waits
   forever. Wakeups may be spurious -- re-check your own condition in a loop. The unparker must publish the
   new state to `*word` before unparking. */
void sc_rt_park(int32_t *word, int32_t expected, int64_t timeout_ns);
void sc_rt_unpark_one(int32_t *word);
void sc_rt_unpark_all(int32_t *word);

/* Sleep the calling OS thread for `ns` nanoseconds (the off-worker path for `parallel::sleep`; a coroutine
   parks on the scheduler's timer list instead). Negative/zero returns immediately. */
void sc_rt_sleep_ns(int64_t ns);

/* A guard-paged stack: an inaccessible page sits just below the returned usable low end, so an overflow
   faults instead of corrupting memory. Returns the usable low end (the stack grows down from low+size), or
   NULL on failure. Free with the same `size`. */
void *sc_rt_stack_alloc(size_t size);
void sc_rt_stack_free(void *usable, size_t size);

/* Stackful context switch (ucontext on POSIX, fibers on Windows). `sc_rt_ctx_alloc` makes an empty context
   for the current thread's root (its state is captured on the first switch away). `sc_rt_ctx_init` arms a
   context to run `entry(arg)` on `stack` (size bytes; ignored on Windows, which owns fiber stacks).
   `sc_rt_ctx_switch` saves the running context into `from` and resumes `to`. */
void *sc_rt_ctx_alloc(void);
void sc_rt_ctx_init(void *ctx, void *stack, size_t size, void (*entry)(void *), void *arg);
void sc_rt_ctx_switch(void *from, void *to);
void sc_rt_ctx_free(void *ctx);

#endif
