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
parks on the scheduler's timer list (`import std::parallel::time as time;`,
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

POSIX only.

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
library calls that block their OS thread. The blocking pool has its own
`blocking::shutdown()` — call it before `runtime::shutdown()` or its threads' state is
reported as leaked under `SC_LEAK_CHECK`.

## Task Diagnostics

| Tool | Purpose |
|------|---------|
| `SC_TASK_TRACE=1` | Trace scheduler decisions for the life of the process |
| Panic messages | Include task id: `panic: [task 7] message` |
| `runtime::live_tasks()` | Return count of tasks still alive |
| Shutdown report | Account for tasks that never finished |

## Shutdown

```superc
runtime::shutdown();   // drain the pool, join all workers
```

The program is responsible for calling `shutdown()` before exit. The shutdown report
names any tasks that were still running.

See [primitives.md](references/primitives.md) for the full API reference.
