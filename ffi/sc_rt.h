/* Platform substrate for the Super-C concurrency runtime (see parallel.md M2). One portable C file
   (`sc_rt.c`, auto-discovered from this header) backs it, branching on the OS internally: POSIX uses
   pthread + mmap + a hand-written context switch (ucontext remains the fallback on any ABI other than
   x86-64 and AArch64); Windows uses CONDITION_VARIABLE + fibers + VirtualAlloc. Everything here is the raw,
   unsafe layer the Super-C scheduler is built on -- not a user-facing API. */
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

/* Per-thread scheduler slot: the index of the worker thread running on this thread, or -1 off the pool.
   Separate from the coroutine slot above so a worker can find its own run deque while a coroutine is
   switched onto it. */
void sc_rt_widx_set(int32_t i);
int32_t sc_rt_widx_get(void);

/* Sleep the calling OS thread for `ns` nanoseconds (the off-worker path for `parallel::sleep`; a coroutine
   parks on the scheduler's timer list instead). Negative/zero returns immediately. */
void sc_rt_sleep_ns(int64_t ns);

/* A guard-paged stack: an inaccessible page sits just below the returned usable low end, so an overflow
   faults instead of corrupting memory. Returns the usable low end (the stack grows down from low+size), or
   NULL on failure. Free with the same `size`. Committed on every platform -- coroutines run on this memory
   -- but pages are only faulted in as the stack is used, so a task that never goes deep never pays. */
void *sc_rt_stack_alloc(size_t size);
void sc_rt_stack_free(void *usable, size_t size);

/* Turn a coroutine stack overflow into a message instead of a bare SIGSEGV/SIGBUS. `install` arms the
   calling thread: a signal stack of its own (the faulting stack is by definition exhausted, so the handler
   cannot run on it) and, once per process, the handler itself. `bounds_set` tells that handler which stack
   cannot run on it) and, once per process, the handler itself. The handler decides from the faulting stack
   pointer, so nothing is tracked per switch; `note_size` only supplies the number quoted in the message.
   Anything not near the stack is left to the default handler -- a wild pointer must still look like the
   crash it is. Both are no-ops where the mechanism does not exist (Windows, for now). */
void sc_rt_stack_guard_install(void);
void sc_rt_stack_note_size(size_t bytes);

/* OS threads and the two locks the scheduler builds on. The Super-C side never names a `pthread_t` or a
   Windows HANDLE: every handle here is an opaque `void *` this layer allocates and releases, so one set of
   call sites serves both platforms. POSIX maps to pthreads; Windows to `_beginthreadex`, SRWLOCK and
   CONDITION_VARIABLE (no pthread emulation is linked in).

   `sc_rt_thread_create` returns 0 on success and fills `*out` with the handle `sc_rt_thread_join` consumes
   (joining releases it; a handle that is never joined leaks the OS thread's bookkeeping). The mutex is NOT
   recursive and must be released by the thread that took it. */
int sc_rt_thread_create(void **out, void *(*entry)(void *), void *arg);
int sc_rt_thread_join(void *handle);

void *sc_rt_mutex_new(void);
void sc_rt_mutex_free(void *m);
void sc_rt_mutex_lock(void *m);
void sc_rt_mutex_unlock(void *m);

/* Condition variable paired with an `sc_rt_mutex_*` lock the caller holds. `wait` releases it, blocks, and
   re-takes it before returning; `timedwait_ns` does the same but also returns once `rel_ns` nanoseconds have
   passed (negative waits forever), reporting nonzero exactly when the deadline is what woke it. Wakeups may
   be spurious -- re-check the condition in a loop. */
void *sc_rt_cond_new(void);
void sc_rt_cond_free(void *c);
void sc_rt_cond_wait(void *c, void *m);
int sc_rt_cond_timedwait_ns(void *c, void *m, int64_t rel_ns);
void sc_rt_cond_signal(void *c);
void sc_rt_cond_broadcast(void *c);

/* Stackful context switch (hand-written assembly on POSIX, fibers on Windows). `sc_rt_ctx_alloc` makes an
   empty context for the current thread's root (its state is captured on the first switch away).
   `sc_rt_ctx_init` arms a context to run `entry(arg)` on `stack` (size bytes; ignored on Windows, which owns
   fiber stacks). `sc_rt_ctx_switch` saves the running context into `from` and resumes `to`. An `entry` that
   returns is a bug the switch traps on -- a coroutine hands control back with a switch, never a return. */
void *sc_rt_ctx_alloc(void);
void sc_rt_ctx_init(void *ctx, void *stack, size_t size, void (*entry)(void *), void *arg);
void sc_rt_ctx_switch(void *from, void *to);
void sc_rt_ctx_free(void *ctx);

#endif
