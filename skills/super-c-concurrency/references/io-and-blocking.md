# Async I/O and Blocking Calls

## Async I/O

A reactor (`kqueue` / `epoll`) turns descriptor readiness into coroutine wakes. The task-aware sockets are
`std::net` (`import std::net;`; `IoError` and `IoErrorKind` are prelude types).

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
lists. A registration adds its direction on every backend: epoll keeps one mask per
descriptor and a modification replaces it, so the poller registers the union of the bits
registered since the descriptor's last event, and a registration never drops the other
direction or its queued event. Several waiters in
one direction are all woken by its event and each retries. Every `net` handle closes through
`io::close`, which first excludes the close from every registration in flight (on macOS
a `close` overlapping a `kevent` registration of the same socket wedges both threads in
the kernel for good, and the process stays unkillable in state `?E` until a reboot, so do
not run wedge experiments casually; registering threads count themselves into per-slot counters and
back off while a close is pending), then reports the close to the reactor before the
exclusion ends, so the first arm on a file that reuses the number follows the report (a
report pushed after the exclusion once settled that arm as not ready): the record's
generation moves on, every wait on the number settles as not ready at once, and an arm
whose registration raced the close registers again and fails. The exclusion also holds
while the reactor is stopping; once it has left, a close is a plain close. The leaving
mark (`G_USERS`, a count of close calls and park hand-offs, at -1) is cleared by compare-and-swap in `shutdown` and in the next
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
admitted wait remains and every counted user has finished, then joins the thread; a later
wait starts a fresh reactor. `commit_arm` and `commit_disarm` count in before publishing
and count out after their last wake-pipe access. A resumed task can clear its wait before
that publishing worker finishes, so wait records alone do not protect the poller.
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
body runs in place, so a saturated pool never waits on itself. wasm has no pool (one thread):
every form runs in place there. Bounds: at most
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
restoration and cancellation masking per call. The hand-off's
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
