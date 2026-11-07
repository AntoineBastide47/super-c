# Coroutine Model and Send / Sync

## Coroutine Model

Each task is a stackful coroutine on its own guard-paged stack (256 KiB via
`mmap`+`mprotect` / `VirtualAlloc`; `runtime::set_stack_size` changes it before the pool starts,
`runtime::stack_size` reads it). Context switching is hand-written assembly: module-level `asm` items of
`ffi/sc_runtime.spc` per object format (Mach-O, ELF and COFF) on x86-64 and aarch64, which save the
callee-saved registers, the FP control state and, on Windows, the TEB stack fields. Windows on
arm64 runs each context on an OS fiber instead (`FiberCtx`, a heap context).

Each coroutine also owns its `std::alloc::Stack` region (`Coroutine.stk`): the worker makes it current
around the switch (`sc_rt_stk_enter`, `sc_rt_stk_leave`) and releases it when the body returns. Off a
coroutine (a plain thread, a job) the thread's region is current, released at thread exit.

Blocking **parks** the coroutine (saves context, returns worker to scheduler) instead of
blocking the OS thread. A worker and its coroutine share an OS thread (the switch only
swaps stacks), so per-coroutine fields need no atomics.

**Preemption:** in a program that loads the coroutine runtime, the compiler emits a
safepoint at every loop backedge (statement and value loops) of every user function and
closure a coroutine can execute. The scheduler yields there when other work is waiting, so
a compute-bound task cannot starve the pool. A std loop is bounded by its inputs unless its
body can run user code, so a reachable std body ticks only then: always when it calls a fn
value or a `dyn` method (or a std body that does), and, when it runs user code only through
bound dispatch, only in the instances binding a type whose methods can be user code
(`Map<u64, u64>` probes never tick; `Map<UserKey, V>` probes and `iter::for_each` over a user
iterator do). Loops in `std::parallel`, in the substrate `ffi/sc_runtime.spc` and in the runtime
`std::rt` never tick (`loader::runtime_path`): a tick inside a spinlock, a parked wait or a signal
handler is a fault.

The tick is a function-local countdown (`__sc_spc`): every iteration takes one, and the hook
runs each time its low 11 bits (`TICK_MASK`) reach 0, once in 2048 ticks. The counter is never
reset, so no path merges two counts. A counted loop is an
exclusive range over a builtin integer whose binding the body cannot assign, or a
non-consuming `for` over an array, slice or sequence value (index against the length read at
entry). Its safepoint sits at the top of each iteration, before a slice element's load. When
its lowered body runs no call, drop or safepoint, it is strip-mined: the safepoint sits at each
chunk top only, then `IN_CHUNK` (`__sc_chunk_end`) computes the chunk's end, at most the budget
left, charged up front, so the chunk loop runs with no tick and no call (a tight loop in a task
then optimizes like one outside: a slice sum ran 4.5x faster), and a tick still comes at most
every 2048 iterations. A body with a call keeps the tick per iteration: a chunk spares little
there and costs its end per loop entry (measured: +1% self-transpile cycles when every
counted loop was strip-mined). The test for calls runs on the lowered generic body, so an
operator a type argument dispatches at emission can still call inside a chunk; the bound
holds regardless. A `break` or `return` out of a chunk leaves its charge spent (the next tick
comes earlier); `continue` and labeled `continue` go to the step, which stays in the chunk. In
a body that can carry a cancellation edge the chunk top holds the combined safepoint, so an
accepted cancellation runs the ladder at the top of an iteration, as the per-iteration
safepoint does. `while`, `loop`, iterator loops, inclusive ranges, `Range` values, `for mut`
ranges and consuming `for` loops tick per iteration. Where the body prints no tick (a std
instance binding no user type), the chunk end is the loop's end. BCE reads `IN_CHUNK`
(`lim <= end`), so `i < lim` in the chunk proves `i < end`.

**Masked regions.** `runtime::preempt_mask_enter()` and `preempt_mask_exit()` bracket a region in
which the safepoints never yield (a re-entrant per-coroutine depth, `Coroutine.pmask`); the task's
own waits (a lock, a semaphore, a channel) still park it. A task that holds pooled memory for the
whole region (the compiler's optimizer scratch, borrow slot or emission context) masks it, so a
worker holds one such task's memory at a time, not one per task preempted mid-region. A task
that parks while it holds the memory still lets its worker start another: the compiler's pools
of that kind also cap their items at the worker count (`BcPool.cap`, `G_DSEM`), and a task that
finds none waits before it takes anything.

Reachability (`Package::reach_solve`, over one scan per module, `Package::co_scan`) starts at
the entry argument of every spawn API
(`runtime::submit`, which `launch` lowers to, `TaskGroup::spawn`,
`runtime::spawn_coroutine[_env]`) and continues through std. From a reached body it reaches
every decl declared inside it, every pinned callee, every conformance method named like a
called interface method (bound and `dyn` dispatch), the implicit callees (a `for` loop's
`next`, operator methods, `Deref` hops, every conformance `free`, since a drop runs
anywhere, and for an operator on an aggregate or type parameter that emission dispatches,
every conformance method named `eq`, `cmp` or the operator's method), and every function named
as a value. A fn value the body calls through its own
parameter is checked at the function's call sites, which must pass a closure, a named
function, or a parameter of their own; any other call of a fn value (a field, a local, a call
result) reaches every closure and every function named as a value. `std::parallel` runs fn
values only through its own dispatch, so its own fn-value calls add nothing; instead each
call into `std::parallel` from outside it must pass every argument that can hold a fn value
(a function type, or a type parameter with a fn bound) as a closure, a named function or a
parameter of its own function, else every fn value is reached. A closure built outside
every task and handed to `data::range` from one is therefore reached.

**Run queues.** Each worker owns a fixed ring (256 slots) that it appends to; the owner
and thieves alike take from its head with a CAS, FIFO for everyone, and a thief takes half
the ring in one claim. Every slot access is a relaxed atomic: a taker reads slots before
its head CAS, a failed CAS discards them, and the atomic access is what keeps a delayed
read of a refilled slot defined. Head-claim retries are bounded, after which the worker
looks elsewhere. A full ring spills to the shared injection queue (a spinlock); yields go
to a private per-worker queue. Every sixteenth dequeue serves the yield queue first and
every sixty-first the injection queue, so a ring that never runs dry (a recursive producer)
cannot starve either. One worker spins looking for work with a budget that doubles while
spinning finds work and halves when it ends in a park (64 to 2048 iterations); the others
give up after 512. A parked task's block carries a COUNT of park hand-off tails in flight,
so a task that parks twice in a row (a wait, then a contended re-lock) is never recycled
under the first tail. Completion, cancellation and spawn counts live per worker and fold
into process-lifetime totals when a pool is destroyed. Scheduler counters (steals, failed
probes, spills, wakes, parks, spin iterations, search cycles) compile in when `RT_STATS`
in `std/parallel/runtime.spc` is true and read back through `runtime::sched_stats()`;
they cost nothing otherwise. `RT_HOOKS` likewise compiles in `runtime::sched_hook_arm`,
which delays whoever reaches a named point so a race window of nanoseconds becomes
reproducible in a hunt (`ci/*_hunt.spc`). The scheduler's point is `HOOK_STEAL_READ`
(between a thief's slot reads and its head claim); the lock's are `sync::HOOK_BEFORE_ENQUEUE`,
`sync::HOOK_AFTER_POP` and `sync::HOOK_AFTER_RELEASE`, driven by `ci/mutex_hunt.spc`.
A per-worker counter must fold into the process-lifetime total in `destroy_pool`; one that
does not makes every runtime program abort at shutdown, the installed compiler included
(recover with an older `super-c` binary).

**Measured scheduler decisions.** Before a tuning change, read the constant's comment and
the lists in this skill; measure again only with a new argument. Interleaved A/B results
that set the current design:

- Injection take (`take_injection`): a share proportional to the queue length over the
  worker count, at most `BATCH_MAX`. A floor of three per lock cost 10% on
  spawn_to_completion: the taker ran the extra tasks while other workers idled.
- `Worker` keeps the ring, `head` and `tail` on its first line. `head` and `tail` on a line
  of their own cost 12% (a push touches two lines); per-task counters on the ring's line
  cost 10%. New counters go on the later lines.
- `Scheduler` and task records are line-aligned (`CO_ALIGN`, `sched_alloc`, `co_alloc`).
  New `Scheduler` fields go last: a field inserted in the middle moved the hot atomics and
  cost 37% on the spawn lane. Malloc-placed task records cost 5% to 40%.
- `STASH_MAX` is both the stash cap and the per-lock batch: a larger value halves pool
  lock traffic and doubles each worker's idle retention. Left at its value.
- Idle-stack trim is rate-limited (`TRIM_INTERVAL_NS`): a trim on every park cost 22% on
  bursty lanes.
- `POOL_BUDGET_DEFAULT` (256 MiB) is below the earlier effective cap of about 323 MiB.
  Accepted at +10% on live_above_pool and +5% on parked_task_memory.

## Send / Sync

Marker interfaces in `std/interfaces.spc`. Structural auto-conformance:

| Type | Send | Sync |
|------|------|------|
| Scalars, `str`, function pointers (`fn(..)`) | yes | yes |
| Raw pointers (`*const T`, `*mut T`) | no | no |
| `&T` | if `T: Sync` | if `T: Sync` |
| Closures | if all captures are `Send` | if all captures are `Sync` |
| Aggregates | if all fields are `Send`/`Sync` | (same) |
| `String`, `Vector<T>`, `Box<T>`, `Map<K,V>` | if `T: Send` | if `T: Send` |
| `Arc<T>`, `arc::Weak<T>` | if `T: Send + Sync` | if `T: Send + Sync` |
| `UnsafeCell<T>`, and `std::mem::cell`'s `Cell`, `RefCell`, `OnceCell` | if `T: Send` | no |
| `std::mem::rc::Rc<T>`, `rc::Weak<T>` | no | no |
| `std::parallel::pool::SyncPoolAlloc` | if the upstream allocator is `Send` | if the upstream allocator is `Send` |

A `const` is shared by every task: one holding an `UnsafeCell` must be `Sync`. Share through
`Arc`. Mutate through `Mutex`, `RwLock`, or atomics. Raw pointers cannot
cross thread boundaries. A type with an `UnsafeCell` field is not `Sync`, so `Arc` of it
is neither `Send` nor `Sync` and every `launch` that captures it fails. Assert both with
`unsafe extend T as Send {}` and `unsafe extend T as Sync {}`, and write the lock argument
beside them, as `sync::Mutex` does.
