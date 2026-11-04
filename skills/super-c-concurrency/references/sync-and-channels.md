# Synchronization, Channels and select

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
parks on the scheduler's timer heap (`import std::time;`, `time::Duration::from_secs`/`from_millis`).

**Waiting costs no allocation, and neither does a primitive.** A `Mutex<T>` holds its lock
word inline and a `Condvar` holds its wait queue inline, so constructing either allocates
nothing. Beside the lock word sits a 4-byte identity that the lock-order checker (a profile with
`lockdep = true`) assigns and keys its history by, so a lock that moves keeps its history. A value
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
table (`sc_rt_lot_bucket` in `ffi/sc_runtime.spc`) is a fixed power of two, each bucket aligned.
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
- A borrow sent into a channel is stored in it: the channel, its senders and its receivers hold
  it, so a `Channel<&i32>` and its handles cannot outlive what was sent. A `Mutex<&T>` and its
  guards hold what is stored through them the same way.
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
