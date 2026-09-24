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
/* A cheap monotone cycle-ish counter for the scheduler's compile-gated statistics: the CPU's own counter
   on x86_64 and aarch64 (rdtsc / cntvct), the monotone clock otherwise. Not comparable across
   cores or machines; only differences on one thread mean anything. */
uint64_t sc_rt_cycles(void);
/* Logical CPU count (>= 1). */
size_t sc_rt_ncpu(void);
/* The page size: what a stack mapping and a reclaim are measured in. */
size_t sc_rt_page_size(void);

/* Per-OS-thread slot holding the running coroutine pointer (the current-coroutine TLS the scheduler needs).
   The language has no thread-locals; this is that one slot. */
void sc_rt_tls_set(void *p);
void *sc_rt_tls_get(void);

/* Address-based parking on a 32-bit word, futex-style. `sc_rt_park` blocks while `*word == expected`, until
   an `sc_rt_unpark_*` on the same address or (for timeout_ns >= 0) the deadline; timeout_ns < 0 waits
   forever. Wakeups may be spurious -- re-check your own condition in a loop. The unparker must publish the
   new state to `*word` before unparking, and an unpark reads nothing through the address: the word may be
   in a frame the waiter has already left. An unpark wakes only threads parked on that address (one, or all
   of them), never a thread parked on another word; on POSIX each parked thread is a record in a static
   bucket naming a per-thread parker retained for the thread's lifetime. */
void sc_rt_park(int32_t *word, int32_t expected, int64_t timeout_ns);
void sc_rt_unpark_one(int32_t *word);
void sc_rt_unpark_all(int32_t *word);

/* Per-thread scheduler slot: the index of the worker thread running on this thread, or -1 off the pool.
   Separate from the coroutine slot above so a worker can find its own run deque while a coroutine is
   switched onto it. */
void sc_rt_widx_set(int32_t i);
int32_t sc_rt_widx_get(void);

/* One iteration's worth of spin hint: what a worker executes between look-again attempts before it gives up
   and parks. Not a scheduler yield -- it stays runnable, which is the point. */
void sc_rt_cpu_relax(void);

/* Hand the core to whatever else is runnable. The backstop inside a spin loop, for the case where the thread
   being waited on has been descheduled and no amount of spinning will help. */
void sc_rt_thread_yield(void);

/* A spinlock over a plain int32 (0 free, 1 held), for critical sections short enough that going to the
   kernel costs more than waiting. Not recursive, and not for anything that can block while holding it. */
void sc_rt_spin_lock(int32_t *word);
void sc_rt_spin_unlock(int32_t *word);

/* One 64-byte bucket of the static mutex parking lot, keyed by the lock's address: {int32 spinlock, int32
   pad, void *head, void *tail, padding}. STATIC storage on purpose -- a waker may touch a bucket after the
   mutex whose waiters it queues has been freed, so the queues must live somewhere that outlives every lock.
   The queue layout and discipline belong to std/parallel/sync.spc; this only hands out the slot. */
void *sc_rt_lot_bucket(void *addr);

/* How many threads are parked in the POSIX parking lot: each has a record queued, so an unpark of its word
   finds it. For a test that must wait until its threads are asleep (pool workers sleep elsewhere). Zero on a
   backend that keeps no records (Windows WaitOnAddress, wasm). */
size_t sc_rt_parked(void);

/* Lock-order tracking, off unless SC_LOCK_ORDER is set (=fatal aborts on the first inversion). `acquire`
   after a lock is taken, `release` before it is given up, `forget` when it is destroyed. `id` is the lock's
   own zero-initialized identity word, which moves with the lock. See sc_rt.c. */
void sc_rt_lockdep_acquire(uint32_t *id);
void sc_rt_lockdep_release(uint32_t *id);
void sc_rt_lockdep_forget(uint32_t *id);

/* Sleep the calling OS thread for `ns` nanoseconds (the off-worker path for `parallel::sleep`; a coroutine
   parks on the scheduler's timer heap instead). Negative/zero returns immediately. */
void sc_rt_sleep_ns(int64_t ns);

/* A guard-paged stack: an inaccessible page sits just below the returned usable low end, so an overflow
   faults instead of corrupting memory. Returns the usable low end (the stack grows down from low+size), or
   NULL on failure: a `size` that is zero, not a whole number of pages or too large to add a guard page to
   is rejected before anything is mapped, and a mapping whose guard cannot be installed is unmapped again,
   so a returned stack is always guarded (wasm has no mprotect: its stacks have no guard page). Free with
   the same `size`; a release the OS refuses is fatal (the runtime cannot account for a mapping it no
   longer owns). POSIX commits the whole stack and pages fault in as it is used; Windows x86-64 commits only
   the top 32 KiB and grows the commit on demand; other Windows builds commit it whole. */
void *sc_rt_stack_alloc(size_t size);
void sc_rt_stack_free(void *usable, size_t size);
/* Bytes currently mapped for task stacks, guard pages included: what `sc_rt_stack_alloc` handed out and
   `sc_rt_stack_free` has not taken back. Stacks are mmap'd, so neither the allocator counters nor the
   resident set (untouched pages) show them; this is the one place that does. */
size_t sc_rt_stack_bytes(void);

/* Turn a coroutine stack overflow into a message instead of a bare SIGSEGV/SIGBUS. `install` arms the
   calling thread: on POSIX a signal stack of its own (the faulting stack is by definition exhausted, so the
   handler cannot run on it, and the thread's exit releases it) and, once per process, the handler itself;
   on Windows x86-64 a vectored exception handler that also grows coroutine stacks. The handler decides
   from the faulting stack pointer, so nothing is tracked per switch; `note_size` only supplies the number
   quoted in the message. Anything not near the stack is left to the default handler -- a wild pointer must
   still look like the crash it is. `install` is a no-op on other Windows builds and on wasm. */
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
/* Give up the right to join: the thread runs on and the OS releases it when it exits; the handle is
   consumed either way. 0 on success; nonzero means the handle did not name a joinable thread, which is
   a programmer error the caller must treat as fatal. */
int sc_rt_thread_detach(void *handle);

/* Failure injection for the substrate's tests: the `nth` call (1-based) of the operation `kind` names
   fails the way the OS would (a null handle, a nonzero code), then the hook disarms itself; `nth` 0
   disarms. One relaxed load on each operation's slow path, nothing on any switch or park path. */
#define SC_RT_FAIL_NONE 0
#define SC_RT_FAIL_THREAD_CREATE 1
#define SC_RT_FAIL_THREAD_JOIN 2
#define SC_RT_FAIL_THREAD_DETACH 3
#define SC_RT_FAIL_STACK_MAP 4
#define SC_RT_FAIL_STACK_GUARD 5
#define SC_RT_FAIL_ALLOC 6 /* the substrate's own allocations: thread handles, locks, condvars, contexts */
#define SC_RT_FAIL_STACK_RELEASE 7
void sc_rt_fail_arm(int kind, unsigned nth);

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

/* Stackful context switch (hand-written assembly on x86-64 and aarch64, including Windows x86-64; fibers on
   other Windows builds; ucontext on other POSIX ABIs). `sc_rt_ctx_alloc` makes an empty context for the
   current thread's root (its state is captured on the first switch away). `sc_rt_ctx_init` arms a context
   to run `entry(arg)` on `stack` (size bytes; with fibers `stack` is ignored and `size` sizes the fiber's
   own stack). `sc_rt_ctx_switch` saves the running context into `from` and resumes `to`. An `entry` that
   returns is a bug the switch traps on -- a coroutine hands control back with a switch, never a return. */
void *sc_rt_ctx_alloc(void);
void sc_rt_ctx_init(void *ctx, void *stack, size_t size, void (*entry)(void *), void *arg);
void sc_rt_ctx_switch(void *from, void *to);
/* A context's body has just started through the entry trampoline, not through a returning switch: consume
   what its switcher published (see sc_rt_ctx_switch). A no-op except under the race profile. */
void sc_rt_ctx_entered(void *ctx);
void sc_rt_ctx_free(void *ctx);
/* A context small enough to live INSIDE the task record: `inline_size` is its byte size (8-aligned) on the
   assembly-switch platforms and 0 where the platform fallback (ucontext, fibers) needs a heap block from
   `sc_rt_ctx_alloc`. Inline storage must be zeroed before its first `init`; `drop` releases what an inline
   context holds besides its bytes (a sanitizer fiber) without freeing anything. */
size_t sc_rt_ctx_inline_size(void);
void sc_rt_ctx_drop(void *ctx);

/* Give the pages of an IDLE cached stack back to the OS without unmapping it: the mapping and its guard
   stay, the resident pages go, and the next use faults zero pages back in. 0 on success; nonzero where the
   platform has no such call, in which case the pages simply stay resident. Never for a live stack. */
int sc_rt_stack_reclaim(void *usable, size_t size);
/* The pages of a reclaimed stack are about to be used again: where the reclaim changed how the OS counts
   them (macOS MADV_FREE_REUSABLE takes them out of the footprint until told otherwise), tell it. A no-op
   elsewhere: a touch is all the other platforms need. */
void sc_rt_stack_reuse(void *usable, size_t size);

/* Combined-safepoint cancellation hook: the cold half of a compiled combined safepoint calls it
   through `__sc_cancel_tick` (super_rt.h); 1 means an unmasked pending cancellation was accepted.
   Installed by the scheduler before it starts any worker; inert (null) until then. */
extern int32_t (*__sc_cancel_hook)(void);
void __sc_set_cancel_hook(int32_t (*f)(void));

#endif
