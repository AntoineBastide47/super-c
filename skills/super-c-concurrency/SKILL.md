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
marker. The runtime module is loaded conditionally — programs without `launch` pay nothing.

## Coroutine Model

Each task is a stackful coroutine on its own guard-paged stack (256 KiB via
`mmap`+`mprotect` / `VirtualAlloc`). Context switching uses `ucontext` (POSIX) or fibers
(Windows).

Blocking **parks** the coroutine (saves context, returns worker to scheduler) instead of
blocking the OS thread. A worker and its coroutine share an OS thread — the switch only
swaps stacks — so per-coroutine fields need no atomics.

**Preemption:** the compiler emits a safepoint at every loop backedge (only in programs
that use `launch`). The scheduler yields there when other work is waiting, so a
compute-bound task cannot starve the pool.

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
which delays every worker at a named point (`HOOK_STEAL_READ`: between a thief's slot
reads and its head claim) so a race window of nanoseconds becomes reproducible under the
`race` profile.

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

Share through `Arc`. Mutate through `Mutex`, `RwLock`, or atomics. Raw pointers cannot
cross thread boundaries.

## Synchronization Primitives

All primitives are **task-aware**: a coroutine that cannot proceed parks (yielding its
worker) instead of blocking the OS thread.

| Primitive | Description |
|-----------|-------------|
| `Mutex<T>` | Exclusive lock with RAII guard |
| `RwLock<T>` | Reader-writer lock with RAII guards |
| `Condvar` | Condition variable (coroutines park, plain threads `pthread_cond_wait`) |
| `Once` | One-time initialization |
| `WaitGroup` | Counter-based barrier |
| `Barrier` | Fixed-count synchronization point |
| `Semaphore` | Counting semaphore |

Timed forms: `acquire_timeout`, `wait_timeout`, `Condvar::wait_until`. `time::sleep`
parks on the scheduler's timer heap (`import std::parallel::time as time;`,
`time::Duration::from_secs`/`from_millis`).

Method calls auto-deref through the guard (`guard.push(42)`); deref-assignment goes
through `.get_mut()` (`*guard.get_mut() = v` — plain `*guard = v` is rejected), and any
mutation needs a `mut` guard binding:

```superc
let data = Arc::<Mutex<Vector<i32>>>::new(Mutex::<Vector<i32>>::new(Vector::<i32>::new()));

launch || {
    let mut guard = data.get().lock();   // Arc exposes its value via .get() (no deref)
    guard.push(42);                      // auto-derefs to &mut Vector<i32>
};   // guard drops -> mutex released
```

(Imports: `std::parallel::arc`, `std::parallel::sync`, `std::parallel::runtime` —
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
parked. A `default` arm fires immediately when nothing is ready — a `select` cannot have
both a `timeout` and a `default` arm. A closed channel makes its recv arm ready
(yielding `None`).

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
fills captures. The body's `fn(..) + Send + Sync` bound prevents data races: a closure
that owns or mutates a capture is `fn move`, and the classic parallel data race does not
compile. The functions come from `import std::parallel::data as parallel;`.

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
`Result<TcpStream, IoError>` (no peer-address tuple — the stream carries it). Consume
these Results with `switch` or `.unwrap()`: the `?` operator cannot move a `Free` payload
(like a `TcpStream`) out of the Result. A closure that owns a captured stream may call
its methods but not move it out — pass `&stream` to helpers.

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
direction registers again. Interests are never removed one by one. A wait that ends by
any other reason (deadline, cancel, shutdown) parks once more until the reactor
acknowledges the node's removal, so no reference to a frame outlives it and the
operating system never holds a pointer. Read and write waits on one descriptor are two
lists; where a backend keeps one registration per descriptor (epoll) the reactor
registers both directions again when the second one gains a waiter. Several waiters in
one direction are all woken by its event and each retries. Every `net` handle closes through
`io::close`, which first excludes the close from every registration in flight (on macOS
a `close` overlapping a `kevent` registration of the same socket wedges both threads in
the kernel for good; registering threads count themselves into per-slot counters and
back off while a close is pending), then reports the close to the reactor: the record's
generation moves on, every wait on the number settles as not ready at once, and an arm
whose registration raced the close registers again and fails. A descriptor closed with
a raw `close(2)` instead gets none of this: its waiters run to their deadlines, and on
macOS the close itself may wedge. Its next file is registered afresh by the next arm.
`wait_until` reports `false` when the deadline passed, the wait was cancelled, the
reactor is shutting down or the descriptor cannot be watched (a closed number, the
Windows set limit); a descriptor the poller cannot watch at all (a regular file under
epoll) reports ready.
`io::shutdown()` settles every pending wait as not ready, keeps acknowledging until no
admitted wait remains, then joins the thread; a later wait starts a fresh reactor.
`io::pending_waits()` counts admitted waits (zero when every task has left its wait);
`io_stats()` returns arm, disarm, registration, poll, event, wake and batch counters when
`IO_STATS` in `io.spc` is true, and zeros otherwise.

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
is not FIFO. Idle threads exit after `set_idle_ns` (ten seconds by default), announce
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
when the pool is not released. Call it before `runtime::shutdown()`: a task parked in a
call keeps its stack until the call returns, which the scheduler's own bounded shutdown
reports rather than frees, and pool threads left running are reported as leaked under
`SC_LEAK_CHECK`.

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

## Task Diagnostics

| Tool | Purpose |
|------|---------|
| `SC_TASK_TRACE=1` | Trace scheduler decisions for the life of the process |
| Panic messages | Include task id: `panic: [task 7] message` |
| `runtime::live_tasks()` | Return count of tasks still alive |
| Shutdown report | Account for tasks that never finished |
| `race` profile (`--profile=race`) | ThreadSanitizer with the coroutine fiber annotations; the only build that reports a runtime race |

## Cancellation Sources and Groups

`std::parallel::task` owns cooperative cancellation. Only a `CancelSource` requests it;
a `CancelToken` observes it; a `TaskGroup` bundles a source with the children it spawns.

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

**Compiled cancellation edges.** After a statement-root call whose callee can reach the
runtime's acceptance, a task-reachable body outside `std::parallel::runtime` probes for an
accepted cancellation and, on one, runs its cleanup ladder and returns a poison value its
caller never reads. Two calls never carry an edge of their own: an unpinned fn-value or
`dyn` callee (cancellation is masked across it), and `runtime::cancel_after_wait` itself.
That function is how a primitive's wait cleanup accepts the request; it reports through
its result so the primitive finishes removing its registrations and hands back the value
it waited with, and the edge fires after the primitive, at its caller. A probe placed
right after it unwound the primitive mid-cleanup and leaked a channel's unsent payload.
Whether a body is task-reachable comes from a whole-package analysis that turns
conservative (every body probes) when it meets a callee it cannot pin; targets differ
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
are made runnable in bounded batches per lock hold. A deadline that would wrap the clock
saturates (`runtime::deadline_after`, used by `time::deadline_in`).

## Shutdown

```superc
runtime::shutdown();   // drain the pool, join all workers
```

The program is responsible for calling `shutdown()` before exit. The shutdown report
names any tasks that were still running.

See [primitives.md](references/primitives.md) for the full API reference.
