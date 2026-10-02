---
name: super-c-concurrency
description: "Covers concurrent programming in Super-C: the launch keyword, stackful coroutines, work-stealing scheduler, Arc/Mutex/RwLock/Channel, Send/Sync enforcement, data parallelism, async I/O, select, and task diagnostics. Use when writing concurrent Super-C programs, debugging races, or understanding the runtime model."
allowed-tools: Bash Read
---

# Super-C Concurrency

## Agent checklist

- Identify task, thread, and blocking-pool boundaries.
- Check `Send` and `Sync` requirements at every cross-thread boundary.
- Use task-aware primitives for coroutine code.
- Define shutdown ownership for every runtime pool started by the program.

Super-C provides structured concurrency through stackful coroutines on an M:N scheduler,
with compile-time safety enforced by `Send`/`Sync` marker interfaces.

## launch

```superc
launch || {
    println("hello from a coroutine");
};
```

`launch` spawns a stackful coroutine on a lazily-started work-stealing pool (one pthread
per CPU by default, or `runtime::set_worker_count(n)`). Both closure spellings work:
`launch || { .. };` and `launch fn() { .. };`. Call `runtime::shutdown()` before main
returns (`import std::parallel::runtime as runtime;`).

**Bound:** `fn move() + Send + 'static`. `Send` prevents un-sendable values from crossing
thread boundaries. `'static` prevents borrowing the launcher's stack frame. `fn move`
ensures the closure owns its captures.

`launch` is a **sugar keyword**: the parser emits a `NODE_LAUNCH` marker, and a desugar
pass lowers it to `runtime::submit(...)` before typecheck. No later pass ever sees the
marker. The runtime module is loaded conditionally: programs without `launch` pay nothing.

## Coroutine Model

Each task is a stackful coroutine on its own guard-paged stack (256 KiB via
`mmap`+`mprotect` / `VirtualAlloc`). Context switching uses `ucontext` (POSIX) or fibers
(Windows).

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
iterator do). Loops in `std::parallel` never tick.

The tick is a function-local countdown (`__sc_spc`, budget 2048): every iteration takes one,
and the iteration that takes the last one calls the hook and resets it. A counted loop is an
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

Reachability (`Package::co_compute`) starts at the entry argument of every spawn API
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
reproducible under the `race` profile. The scheduler's point is `HOOK_STEAL_READ`
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
| Scalars, `str` | yes | yes |
| Raw pointers (`*const T`, `*mut T`) | no | no |
| `&T` | if `T: Sync` | if `T: Sync` |
| Closures | if all captures are `Send` | if all captures are `Sync` |
| Aggregates | if all fields are `Send`/`Sync` | (same) |
| `String`, `Vector<T>`, `Box<T>`, `Map<K,V>` | if `T: Send` | if `T: Send` |
| `Arc<T>` | if `T: Send + Sync` | if `T: Send + Sync` |
| `UnsafeCell<T>` | if `T: Send` | no |

Share through `Arc`. Mutate through `Mutex`, `RwLock`, or atomics. Raw pointers cannot
cross thread boundaries. A type with an `UnsafeCell` field is not `Sync`, so `Arc` of it
is neither `Send` nor `Sync` and every `launch` that captures it fails. Assert both with
`unsafe extend T as Send {}` and `unsafe extend T as Sync {}`, and write the lock argument
beside them, as `sync::Mutex` does.

## Synchronization Primitives

All primitives are **task-aware**: a coroutine that cannot proceed parks (yielding its
worker) instead of blocking the OS thread.

| Primitive | Description |
|-----------|-------------|
| `Mutex<T>` | Exclusive lock with RAII guard; the lock word lives in the value |
| `RwLock<T>` | Reader-writer lock with RAII guards |
| `Condvar` | Condition variable (both kinds of waiter queue a node in their own frame) |
| `Once` | One-time initialization |
| `WaitGroup` | Counter-based barrier |
| `Barrier` | Fixed-count synchronization point |
| `Semaphore` | Counting semaphore |

Timed forms: `acquire_timeout`, `wait_timeout`, `Condvar::wait_until`. `time::sleep`
parks on the scheduler's timer heap (`import std::parallel::time as time;`,
`time::Duration::from_secs`/`from_millis`).

**Waiting costs no allocation, and neither does a primitive.** A `Mutex<T>` holds its lock
word inline and a `Condvar` holds its wait queue inline, so constructing either allocates
nothing. Beside the lock word sits a 4-byte identity that the `race` profile's lock-order
checker assigns and keys its history by, so a lock that moves keeps its history. A value
must not move while a waiter is queued against it, which nothing can do, since a waiter
only exists once a second thread shares the value through a pointer.
Every wait is a node in the waiter's own frame, queued under the paired mutex and unlinked
by its owner before that frame ends. A coroutine's node carries its park token; a plain
thread's node carries the address of a wake word in the same frame. A notify claims one
node under the mutex and wakes it, and passes the wake to the next node when it finds a
wait already over (a deadline or a cancellation got there first), so a wake is never
spent on a waiter that cannot use it. A wait (condvar or `select`) that consumed a notify
returns as notified even when a cancellation is pending: the consumed wake is never lost,
and the cancellation is taken at the next cancellation point. `sync_stats()` returns lock, wait and wake counters
when `SYNC_STATS` in `std/parallel/sync.spc` is true, and zeros otherwise.

**What a lock costs.** An uncontended acquisition and release are one atomic
read-modify-write each, and on a build with cross-module inlining (the release and bench
profiles) that is all they are: four instructions and one `cas` per side on arm64, with
no call, no barrier and no diagnostic left in the path. A contender spins with the
platform's spin hint for a bounded number of attempts and then queues. Every kind of
attempt is bounded: observations of a held lock by `MUTEX_SPIN`, the same observations
once another waiter is already queued by the shorter `MUTEX_SPIN_QUEUED`, and
acquisitions lost to another contender by `MUTEX_LOSSES`, after which the contender stops
spinning and takes the queue at its first opportunity. Bounding lost attempts is what
keeps a stream of hot re-acquirers from overtaking a waiter indefinitely: it cuts the
waiters' wait tail by about three quarters and levels their share of the lock. Spinning
less once someone is queued is worth another tenth to a half wherever waits reach the
queue at all, because a spinner there is waiting out a whole release it cannot shorten.
`try_lock` retries a bounded number of times too, so a `false` means "not taken" rather
than "was held": under contention it may refuse a lock that was free for an instant,
which is what lets it promise never to wait. Acquisition is otherwise
unfair by design, in that a woken waiter re-contends rather than being handed the lock,
because a hand-off would serialise every acquisition behind a wake. That wake is the
unlock's one release, spent on the waiter whose park it claimed: a `lock_c` waiter woken
that way re-contends even when a cancellation landed after the claim (the request is
taken at its next cancellation point, this loop's next park included). Giving the wait
up there left every waiter queued behind it parked for good; the test
`a_cancel_after_the_wake_claim_passes_the_release_on` pins the window with one busy
worker.

Measured lock decisions (`std/parallel/sync.spc`):

- Lost acquisitions count against `MUTEX_LOSSES`, not `MUTEX_SPIN`: charged to the spin
  budget, they made contended channels park too early.
- `MUTEX_SPIN_QUEUED` at 32 instead of 128 cost channel_mpmc 9.5% and channel_cap64 7.6%.
- `MUTEX_SPIN` at 32 instead of 256 cost mpmc 92% and section_64 75%; at 0, mpmc 129%.
- The arm64 spin hint is `isb` (`sc_rt_cpu_relax`). `yield` at the same spin time cost
  section_0 31% and mixed_callers 36%: it is a no-op on Apple cores, so the loop polls
  the line many times more.
- The lock word is inline in `Mutex<T>`: one allocation fewer per lock for +0.4 ns on
  mutex_uncontended (not false sharing: padding changed nothing).
- The channel_mpmc residual (39% in `raw_mutex_lock_slow` on one state lock) is accepted:
  `select` needs one lock per channel, and a shorter spin only buys parks (0.724
  contended locks against 0.011 parks per message).

Parking an OS thread retains a little: on POSIX, one parker (a mutex, a condvar and a
flag) per thread that has parked at least once, held for that thread's life so a waker
can always reach it, plus a fixed bucket table. Windows parks through `WaitOnAddress`
and retains nothing. Wait records themselves live in the parking frame and are not
retained; `sc_rt_parked()` counts them, so a test can wait until its plain threads are
asleep (zero on Windows, which keeps no records; pool workers sleep elsewhere). The bucket
table (`sc_rt_lot_bucket` in `ffi/sc_rt.c`) is a fixed power of two, each bucket aligned.
Bucket count did not matter (one bucket against sixteen for sixteen locks measured the
same), and padding each mutex to a line is the wrong trade: `Mutex<i64>` is 16 bytes.

Method calls auto-deref through the guard (`guard.push(42)`); deref-assignment goes
through `.get_mut()` (`*guard.get_mut() = v`; plain `*guard = v` is rejected), and any
mutation needs a `mut` guard binding:

```superc
let data = Arc::<Mutex<Vector<i32>>>::new(Mutex::<Vector<i32>>::new(Vector::<i32>::new()));

launch || {
    let mut guard = data.get().lock();   // Arc exposes its value via .get() (no deref)
    guard.push(42);                      // auto-derefs to &mut Vector<i32>
};   // guard drops -> mutex released
```

(Imports: `std::parallel::arc`, `std::parallel::sync`, `std::parallel::runtime`;
aliased or glob, e.g. `import std::parallel::sync as *;`.)

## Channels

```superc
let ch = Channel::<i32>::bounded(16);      // backpressure at 16; unbounded() = none
let tx = ch.sender();                       // cloneable Sender<i32>
let rx = ch.receiver();                     // cloneable Receiver<i32>

launch || {
    let _ = tx.send(42);                    // returns SendResult<i32>
};

while let Some(val) = rx.recv() {           // Option<T>: None once closed and drained
    process(val);
}
```

- `bounded(n)` / `unbounded()` return a `Channel<T>` value; handles come from
  `.sender()` / `.receiver()` and are cloneable.
- `send` and `try_send` return `SendResult<T>` (the value comes back on a closed or full
  channel); `recv` returns `Option<T>`, `try_recv` and the timed forms likewise.
- Timed/batch forms: `send_timeout`, `send_deadline`, `recv_timeout`, `recv_deadline`,
  `send_batch`, `recv_batch`. `Sender::close` closes explicitly; the channel also closes
  when the last handle of either side drops.
- Import: `import std::parallel::channel as chan;` (or `as *` for unqualified names).

**A channel is one allocation.** The handle count, the state lock, the ring state, both
wait queues and the ring itself live in one block that the last handle out releases;
handles are counted atomically like an `Arc`. An unbounded channel starts on that inline
ring and moves to a heap ring when it outgrows it (doubling); a heap ring halves again when
fewer than a quarter of its slots are in use and it holds more than 16, so a drained burst
gives its memory back. A zero-sized payload has no ring at all. Waits allocate nothing; only
an unbounded channel's ring growth or shrink allocates.

**Batches wake what they can use.** `send_batch` and `recv_batch` take the lock once per
run and then wake at most as many waiters as the run delivered items or freed slots,
rather than broadcasting: each item admits one waiter, and any further wake would only
queue again. A batch that hits a closed channel, loses its last peer or is cancelled
leaves its remainder in the caller's vector, in the original order.

## select

Arms are separated by newlines (no commas). An arm operation is `ch.recv()`,
`ch.send(v)`, `timeout(d)`, or `default`; the optional binding gets exactly what the
operation returns (`Option<T>` for recv, `SendResult<T>` for send):

```superc
select {
    v = rx1.recv() => {                       // v: Option<i32>
        println("got {}", v.unwrap_or(-1));
    }
    rx2.recv() => {                           // binding is optional
        println("got from rx2");
    }
    tx.send(42) => {                          // bind `r =` for the SendResult
        println("sent");
    }
    timeout(time::Duration::from_secs(1)) => {
        println("timed out");
    }
}
```

`select` is a sugar keyword lowered in the desugar pass. Backed by
`std::parallel::selector`. Random fairness among ready arms; first-notifier-wins when
parked. A `default` arm fires immediately when nothing is ready. A `select` cannot have
both a `timeout` and a `default` arm. A closed channel makes its recv arm ready
(yielding `None`).

A wait registers one node per arm under every arm's lock (taken in address order, so two
selectors sharing channels cannot deadlock and one channel armed twice is locked once),
then waits ONCE: a coroutine parks under a single wake token, and a plain thread sleeps on
a single wake word in the same frame that every one of its nodes names. Neither polls. The
notify that wins names its arm, and that arm is retried first; the losing nodes are
unlinked in the same lock order before the frame ends.

## Data Parallelism

```superc
// Parallel for loop
parallel for i in 0..1000 {
    process(i);
}

// Parallel iteration over a slice (range-index a Vector to get one)
parallel::each(v[0..n], fn(x: &i64) { process(x); });
parallel::each_mut(v.index_range_mut(0..n), fn(x: &mut i64) { *x += 1; });

// Reduce: identity is a CLOSURE (a copied init value would double-free owning
// accumulators); per-worker results merge through a separate combine closure.
let total = parallel::reduce(v[0..n], fn() i64 { return 0; },
    fn(a: i64, x: &i64) i64 { return a + *x; },
    fn(a: i64, b: i64) i64 { return a + b; });
```

`parallel for` is a sugar keyword lowered to `std::parallel::data::range(...)`; the
index binder is `usize`. The parser wraps the body in a closure node so the resolver
fills captures. The body's `fn(..) + Send + Sync` bound prevents data races: the plain `fn(..)`
bound makes the body borrow its `Free` captures, a mutated capture is a `&mut` borrow, and a
closure that holds one is not `Sync`, so the classic parallel data race does not compile. The functions come from `import std::parallel::data as parallel;`.

Also available: `parallel::chunks_mut`, `parallel::sections` (fork-join via a builder
closure that calls `Sections::add`), and `*_with` variants (`range_with`, `each_with`,
`reduce_with`, ...) taking an `Options` for schedule and grain.

### inline for

```superc
inline for i in 0..4 {
    process(i);   // unrolled at compile time to 4 copies
}
```

Requires a const-foldable closed range. `break`/`continue` targeting it are rejected.
Each iteration emits `{ const T i = k; <block> }`.

## Async I/O

A reactor (`kqueue` / `epoll`) turns descriptor readiness into coroutine wakes.

```superc
let listener = net::TcpListener::bind("127.0.0.1", 0).unwrap();  // (host, port); 0 = ephemeral
launch || {
    // One acceptor task; every connection gets its own task, parked on the reactor.
    loop {
        switch listener.accept() {               // parks the coroutine
            Ok(stream) => {
                launch || {
                    handle_connection(&stream);  // owned capture: use it, never move it out
                };
            },
            Err(_) => {
                break;
            },
        };
    }
};
```

`bind` takes host and port as separate arguments; `accept` returns
`Result<TcpStream, IoError>` (no peer-address tuple; the stream carries it). Consume
these Results with `switch` or `.unwrap()`: the `?` operator cannot move a `Free` payload
(like a `TcpStream`) out of the Result. A closure that owns a captured stream may call
its methods but not move it out. Pass `&stream` to helpers.

`net::TcpStream` accept/read/write/connect park the coroutine. A hundred connections are
a hundred parked tasks and one poller thread, not a hundred threads. `UdpSocket` too,
IPv4 or IPv6, with every failure a `Result<T, IoError>`.

Every platform: kqueue on macOS, epoll on Linux, select() on Windows (sockets only there,
at most FD_SETSIZE parked at once).

**Reactor contract** (`std/parallel/io.spc`). The reactor thread alone touches the
per-descriptor records (a table indexed by descriptor number, never freed while the
reactor runs) and the waiter lists; tasks reach it through a lock-free command list. A
wait is a node in the waiting task's frame, published by the park hand-off, linked and
unlinked by the reactor, and carrying the park token the reactor claims exactly like a
timer or a cancellation does. The one-shot operating-system registration is idempotent
and thread-safe, so the publishing worker registers the interest itself just before it
publishes: the readiness event is what wakes the reactor, an arm costs no wake of its
own, and an event that finds no waiter marks the record so the next arm in that
direction registers again. That event can also be delivered and consumed BEFORE the
arm's push lands (the reactor drains commands, then events, then sleeps), and the
one-shot it consumed may have been the arm's own even when it woke other waiters: the
reactor counts every event it delivers (`Reactor.events`, atomic) and stamps the
descriptor's record with the count; the worker reads the count before registering and
keeps it in the node, wakes a sleeping reactor when the count moved between its
registration and its push (the sleep protocol's sequentially consistent order makes the
two checks cover each other), and `do_arm` registers the direction again when the
record's stamp is newer than the node's snapshot. Without this a lost arm sits until an
unrelated wake: a 30 s timer in a test, never in a program with no timers, which is how
the reactor echo programs hung on CI. Interests are never removed one by one. A wait that ends by
any other reason (deadline, cancel, shutdown) parks once more until the reactor
acknowledges the node's removal, so no reference to a frame outlives it and the
operating system never holds a pointer. Read and write waits on one descriptor are two
lists; where a backend keeps one registration per descriptor (epoll) the reactor
registers both directions again when the second one gains a waiter. Several waiters in
one direction are all woken by its event and each retries. Every `net` handle closes through
`io::close`, which first excludes the close from every registration in flight (on macOS
a `close` overlapping a `kevent` registration of the same socket wedges both threads in
the kernel for good, and the process stays unkillable in state `?E` until a reboot, so do
not run wedge experiments casually; registering threads count themselves into per-slot counters and
back off while a close is pending), then reports the close to the reactor: the record's
generation moves on, every wait on the number settles as not ready at once, and an arm
whose registration raced the close registers again and fails. The exclusion also holds
while the reactor is stopping; once it has left, a close is a plain close. The leaving
mark (a closer count of -1) is cleared by compare-and-swap in `shutdown` and in the next
reactor's builder, never by a store: a closer counted in while no reactor runs keeps its
count, where a store once let its count out leave -1 under a running reactor, whose stop
then waited for good (`closes_racing_the_reactor_start_keep_their_count`). A descriptor closed with
a raw `close(2)` instead gets none of this: its waiters run to their deadlines, and on
macOS the close itself may wedge. Its next file is registered afresh by the next arm.
`wait_until` reports `false` when the deadline passed, the wait was cancelled, the
reactor is shutting down or the descriptor cannot be watched (a closed number, a number
the reactor's own poller or wake pipe now holds, the Windows set limit); a descriptor the poller cannot watch at all (a regular file under
epoll) reports ready.
`io::shutdown()` settles every pending wait as not ready, keeps acknowledging until no
admitted wait remains, then joins the thread; a later wait starts a fresh reactor.
`io::pending_waits()` counts wait records, which exist before a wait is admitted and
registered (zero when every task has left its wait), so a test must not treat a count
as proof that the reactor registered the wait;
`io_stats()` returns arm, disarm, registration, poll, event, wake and batch counters when
`IO_STATS` in `io.spc` is true, and zeros otherwise.

Measured reactor decisions: registration by the reactor per arm (a pipe wake per arm) cost
6% of all-thread cycles on the echo lanes, so the worker registers. A global live-wait
counter put cross-core line traffic on every wait and, kept in the reactor record, a
use-after-free window, so the stopping reactor scans the task registry's wait records
instead (`admit`). Plain echo lanes stay 1.4% to 2.2% above the earlier reactor in cycles
at flat wall time; accepted.

## Blocking Calls

```superc
extern "C" "unistd.h" {
    @blocking
    fn sleep(seconds: u32) u32;   // every call runs on the blocking pool; caller parks
}

// Or inline (import std::parallel::blocking as blocking):
let got = blocking::call(fn() i64 {
    return heavy_compute();       // runs on a separate blocking-pool thread
});
```

`@blocking` sits on the extern **function declaration** (inside the block, one per
function) and is rejected on variadics. `blocking::call<F: fn move() T + Send, T>` runs
the closure on a **separate blocking pool** while the calling coroutine parks. Use for C
library calls that block their OS thread.

**Blocking-pool contract** (`std/parallel/blocking.spc`). A `call` and a `@blocking`
call are not cancellable: their whole record (queue link, closure, result) lives in the
caller's frame and costs no allocation, and the pool thread's wake of the caller is its
last touch of that frame. `call_c` is a cancellation point: its record is heap-owned and
reference-counted (recycled within `CACHE_BUDGET` bytes), a cancellation abandons the
task's side without stopping the body, and whichever side ends with the value destroys
it exactly once; the task unwinds from the call as from any cancelled wait. From a plain
thread every form blocks for the value; from a pool thread (a body that calls again) the
body runs in place, so a saturated pool never waits on itself. Bounds: at most
`MAX_THREADS` threads exist, creation reservations included (reserve under the lock,
create outside it, publish the handle before the thread takes work); at most
`MAX_PENDING` accepted calls wait for a thread, past which a coroutine parks for
admission on a node in its own frame and a plain thread blocks. Ordering across workers
is not FIFO. Idle threads exit after `set_idle_ns` (ten seconds by default; negative: never), announce
their handle first, and are joined at the next creation or at shutdown. The queue is a
spinlock, idle threads park on their own word, and one thread spins for the next job
with an adaptive budget: a stream of short calls costs no thread wake. A thread counts
itself out of a call and, with no spinner, becomes it BEFORE the caller is woken, so a
caller that calls again at once is covered instead of reserving a creation. `stats()`
reads the counters under the lock.

**Shutdown.** `try_shutdown(grace_ns)` closes the pool (a call made while it closes,
and every admission waiter, runs on its caller's own thread), drains accepted work and
joins announced exits until the deadline, and reports `{queued, running, threads,
released}`. What remains keeps its records, handles and the pool; an expired deadline
never means a foreign call stopped; a late completion still settles its caller; a later
attempt finishes the drain. `shutdown()` is `try_shutdown(SHUTDOWN_GRACE_NS)` and aborts
when the pool is not released. The first pool build registers an `atexit` handler that runs
`try_shutdown(SHUTDOWN_GRACE_NS)` (never from a pool thread): a program that returns from
`main` without calling `shutdown` releases an idle pool and stays leak-clean; outstanding
work keeps the pool, and the leak gate reports it. Call it before `runtime::shutdown()`: a task parked in a
call keeps its stack until the call returns, which the scheduler's own bounded shutdown
reports rather than frees, and pool threads left running are reported as leaked under
`SC_LEAK_CHECK`. Two rules keep a closing pool from releasing under a submitter still
inside its park hand-off tail (the caller's task is then reported unresponsive at the
scheduler's shutdown with its body already returned: `state 1 phase 0 done true handoff
1`, fields the report prints for this reason). A creation reservation (`starting`) stays
counted until the thread is on the live list: `spawn_thread` joins announced exits first
and those joins release the lock, so a reservation dropped before them left a shutdown
with nothing to wait for; it released and freed the pool, and the creator then took the
freed lock for good, its new thread parked on a publication that never came. A thread
popped from the idle stack is signalled only after the pool lock is released, by a worker
the scheduler may hold off for as long as it likes, and may meanwhile take the job on its
own timed wake, serve it, retire and be joined: `pop_idle` counts the wake owed
(`PThread.wakes`), `wake_thread` pays it off after releasing the thread's lock, and the
reap frees no record with a wake still owed.

**In-place execution was measured and rejected.** Moving the scheduling role off the
calling worker's OS thread (a replacement worker per blocking call, a permit to take
back before returning to compute) costs at least one thread wake in each direction, the
same floor as the hand-off it would replace, plus queue ownership transfer, TLS
restoration, sanitizer fiber state and cancellation masking per call. The hand-off's
own cost is the thread wake, not the records: with zero allocations per call the
round trip is bounded by the wake, and a spinning pool thread already removes that wake
for a stream of calls. Keep the pool. The measured residue is on the scheduler side:
pool threads' wakes reach workers through the injection queue one at a time, so under a
mixed compute-and-call load workers take one task per injection lock instead of a
share; that is the queue's take policy, not the pool.

Other measured pool decisions: an OS mutex for the queue spent fan-out in
`__psynch_mutexwait`, so the queue keeps its spinlock. Shared parking-lot buckets per
thread wake cost 7% of cycles on io_short; each thread keeps its own mutex and condvar.
The spinner's ceiling (`SPIN_MAX`): 8192 cost the mixed lane 12%, 128 made fan-out worse,
no spinner made the round trip ten times slower, and an early yield of the pool lock cost
the mixed lane 13%. The spinner covers one queued job: covering every job starved a burst
behind one thread. A 16-thread pool measured worse (284 against 267 Mcycles).

## Task Diagnostics

| Tool | Purpose |
|------|---------|
| `SC_TASK_TRACE=1` | Trace scheduler decisions for the life of the process |
| Panic messages | Include task id: `panic: [task 7] message` |
| `runtime::live_tasks()` | Return count of tasks still alive |
| Shutdown report | Account for tasks that never finished |
| `race` profile (`--profile=race`) | ThreadSanitizer with the coroutine fiber annotations; the only build that reports a runtime race |

The shutdown report prints each unfinished task's `state`, `phase`, `done` and `handoff`:
`done true handoff 1` is a worker stuck in that task's park hand-off tail, and the cure is
that worker's backtrace, not a guess. Every `Coroutine` field another thread may read or
compare after the task's own worker last wrote it is accessed atomically, `done` (the
report reads it) and `park_state` on block reuse (a waker that lost the last claim may
still be finishing its compare) included: `check.sh` runs `ci/*_hunt.spc` under the race
profile and fails on any report or nonzero exit.

Checking profiles trap on integer overflow, so runtime arithmetic on values that other
threads write must hold for every order of the reads. A clock value published by another
worker can be LATER than this thread's own earlier clock read: compare `now < last + interval`,
never `now - last` (`pool_trim`). A difference of two summed counters reads the one that
must be smaller FIRST, with a Release store on its side: `live_tasks` reads completions
before spawns, so while tasks run it can be high but never below the truth. A trap without
`[task N]` came from a worker's scheduler loop or a plain thread; on macOS the crash report
in `~/Library/Logs/DiagnosticReports` names the function and line.

### Hunting races and hangs

- Get the stuck thread's backtrace before any fix; a guessed fix hides the cause. Probe
  with a program that parks instead of aborting on the bad state, then attach `gdb -p`
  (in a Linux container started with `--cap-add=SYS_PTRACE`) or run macOS `sample` on the
  child. lldb cannot unwind coroutine stacks; gdb in a Linux container can.
- Rare races show only under load: run about eight processes at once in a Linux container
  limited to two to four CPUs.
- Prove a hunt shape reaches its window: flip `RT_HOOKS`, rebuild, and count the hook hits.
  A passing hunt proves nothing about its shape.
- In `ci/mutex_hunt.spc`, create the `Sender` before the holder (a `recv` with no live
  sender returns at once). A "cancel after selection" shape must release first and cancel
  inside the held-open pop window.
- In a hunt's `fail`, print `rt::task_snapshot` (state, phase, wait kind, wait object).
  `rt::try_shutdown` reports nothing there: its own cancellation releases the parked tasks.
- After a counter change in runtime or sync code, run race_hunt, cancel_hunt and
  queue_hunt under the `race` profile twice each; expect zero reports.
- Linux TSan in Docker needs `--security-opt seccomp=unconfined`. gcc libtsan reports
  fd-table races on close-under-wait; these are not memory races. macOS clang TSan does
  not intercept `kevent`.
- `Condvar::unlink` walks the wait queue, so thousands of timed waiters on one condvar cost
  O(n^2). A timed-wait benchmark spreads its waiters over many condvars.

### Measuring the runtime

- Keep construction, spawn and join out of the timed round: `bench/mutex_bench.spc`
  builds a `Crew` once and parks it on a `Barrier` between rounds. A crew that spins
  between rounds takes the workers the lock needs.
- mutex_section_0, mutex_section_64 and mutex_handoff are bimodal (all spin, or waiters
  park). Judge a contention policy on mutex_starvation's distribution, not on a throughput
  median. A per-round minimum is useless for contended lanes.
- To show caller-class bias, give all callers one shared budget; a fixed quota per caller
  cannot show it.
- Socket echo lanes leave thousands of sockets in TIME_WAIT (30 s on macOS). Back-to-back
  runs exhaust ephemeral ports and look like a reactor hang: let TIME_WAIT drain between
  passes.
- Faster spawn raises resident memory in bursts (more tasks live at once). That is not a
  leak.
- A lane stalled at 0% CPU is a runtime deadlock: sample it and fix it before measuring.
- A scheduler A/B base build also needs `RT_STATS` on; drop calls to entry points the base
  lacks.
- A tail-recursive deep-stack helper becomes a loop under optimization. Escape the frame
  address with `bench::black_box` (`deep` in `bench/micro_bench.spc`).

## Cancellation Sources and Groups

`std::parallel::task` owns cooperative cancellation. Only a `CancelSource` requests it;
a `CancelToken` observes it; a `TaskGroup` bundles a source with the children it spawns.
Dropping a `TaskGroup` joins its children with cancellation masked, so a group never ends
before its children even when its owner has a cancellation pending.

```superc
let (src, tok) = task::CancelSource::new();
launch || {
    tok.bind_current();                   // this task is now a member of `src`
    time::sleep(long);                    // a cancellable wait unwinds on the request
};
src.cancel(runtime::CR_USER);            // request every member; first reason wins

let mut g = task::TaskGroup::new();
g.spawn(|| { work(); });                  // children bind the group's token themselves
g.cancel();
let report = g.join();                    // completed / cancelled / unresponsive counts
```

Registration contract (`CancelToken::bind_current`, documented at the top of
`std/parallel/task.spc`):

- Membership is per (task, source). Binding one source twice from a task is one
  membership; binding several sources is one membership each.
- The record belongs to the task: the first lives inline in the task block, further ones
  are small heap records. The source links records into a list of its LIVE members and
  keeps nothing of its history.
- A membership ends when the task completes, by return or by cancellation cleanup: the
  runtime unlinks every record before the task's identity can be recycled. The record
  holds a reference to the shared state, so a source and all its tokens may be dropped
  while members live.
- Binding after `cancel` delivers the request at once with the first request's reason.
- `cancel` raises the flag under the source lock, then drains members in registration
  order in bounded batches and requests each by generation-checked key outside the lock,
  so a member that completes meanwhile is rejected, never touched.
- `CancelSource::members()` is the diagnostic live count; it is zero after `cancel`.

Lock order: a source lock is taken alone and never held across a request or a task's
cleanup. A key-based request takes only the registry slot lock.

**Compiled cancellation edges.** After a call whose callee can reach the runtime's
acceptance, a task-reachable body outside `std::parallel::runtime` probes for an accepted
cancellation and, on one, runs its cleanup ladder and returns a poison value its caller
never reads. A call carries the edge when it is evaluated with nothing unregistered
pending: the root of a statement or of a `let` initializer, a lone return value, an `if`
or `while` condition, a switch scrutinee (the task unwinds before any arm runs) and the arm
values of a switch or `if` in such a position, the first call of a receiver chain
(`rx.recv().unwrap_or(0)` unwinds after `recv`), both sides of `&&` and `||`, the right
side of an assignment to a call-free place, and a `for` loop's `next`. Implicit calls follow
the same rule: an operator method at such a node (a compound assignment checks once the place
holds its result) and a user `Deref` hop. A call after an
evaluated argument or a left operand carries none; the next edge delivers the request. An
edge after a call that returned a real value frees it first (a `Some(guard)` unlocks). A
call to a fn value carries the edge when some fn value of the package can accept (a closure
written as a spawn entry is not one); a bound or `dyn` call, when some conformance method of
its name can. In `std::parallel` only the root call of an expression statement or a plain
`let` carries one: its primitives report a cancelled wait through their results and release
raw resources after it (`TcpStream::connect` closes its socket). `runtime::cancel_after_wait`
never carries an edge. That function is how a primitive's wait cleanup accepts the request;
it reports through its result so the primitive finishes removing its registrations and hands
back the value it waited with, and the edge fires after the primitive, at its caller. A probe
placed right after it unwound the primitive mid-cleanup and leaked a channel's unsent payload.
Whether a body is task-reachable comes from the whole-package analysis above; targets differ
here, so a probe that is absent on one target may be present on another.

Known gap: in a generic body an unbounded `T` is not an owning type, so a `T` value a
path does not consume is never dropped in an instance with an owning argument (a
never-moved `T` parameter, `Option::unwrap_or`'s unused default). Bound it with `Free`
where a drop is required.

Timed waits live in one indexed binary min-heap under the scheduler lock, ordered by
(deadline, arm sequence): arming and disarming are logarithmic, the earliest deadline is
read in constant time, equal deadlines come due in arm order, and a sweep may reach its
members in any order. Exactly one idle worker times its park to the earliest deadline;
the others sleep untimed, and only a new earliest deadline wakes that worker. Due timers
are made runnable in bounded batches per lock hold, as one chain on the injection queue,
and the promoting worker wakes one idle worker for each promoted task past the first. A deadline that would wrap the clock
saturates (`runtime::deadline_after`, used by `time::deadline_in`).

## Shutdown

```superc
runtime::shutdown();   // drain the pool, join all workers
```

The program is responsible for calling `shutdown()` before exit. The shutdown report
names any tasks that were still running.

See [primitives.md](references/primitives.md) for the full API reference.
