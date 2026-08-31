# Concurrency Primitives Reference

## Atomics

`Atomic<T>` over integer builtins. Every operation takes an explicit `MemoryOrder`.

```superc
let counter = Atomic::<u64>::new(0);
counter.fetch_add(1, MemoryOrder::Relaxed);
let val = counter.load(MemoryOrder::Acquire);
counter.store(42, MemoryOrder::Release);

let swapped = counter.compare_exchange(42, 100, MemoryOrder::SeqCst, MemoryOrder::Relaxed);
```

| Operation | Description |
|-----------|-------------|
| `load(order)` | Atomic read |
| `store(val, order)` | Atomic write |
| `swap(val, order)` | Atomic exchange, returns old value |
| `fetch_add(val, order)` | Add and return old value |
| `fetch_sub(val, order)` | Subtract and return old value |
| `fetch_and(val, order)` | Bitwise AND and return old |
| `fetch_or(val, order)` | Bitwise OR and return old |
| `fetch_xor(val, order)` | Bitwise XOR and return old |
| `compare_exchange(expected, desired, success_order, fail_order)` | Strong CAS, returns `bool` |
| `compare_exchange_weak(expected, desired, success_order, fail_order)` | Weak CAS, returns `bool` |
| `fence(order)` | Standalone memory fence |

### Memory Orders

| Order | Guarantee |
|-------|-----------|
| `Relaxed` | Atomicity only, no ordering |
| `Acquire` | Reads after this see writes before a paired Release |
| `Release` | Writes before this are visible after a paired Acquire |
| `AcqRel` | Both Acquire and Release |
| `SeqCst` | Total order across all SeqCst operations |

## Threads

```superc
let handle = thread::spawn(fn() i32 {
    return heavy_work();
});
let result: i32 = handle.join();
```

`thread::spawn<F: fn move() T + Send + 'static, T>(f)` returns a `JoinHandle<T>`.
(Anonymous functions spell the return type after the parameter list — there is no
Rust-style `->`.)

## Arc

```superc
struct Data { pub n: i64 }

let shared = Arc::<Data>::new(Data { n: 7 });
let clone = shared.clone();    // atomic increment

launch || {
    let val = clone.get();     // &Data — Arc has no deref
    println("n = {}", val.n);
};
```

Atomically reference-counted shared ownership. `T: Send + Sync` required. Drops the
inner value when the last `Arc` is freed.

## Mutex and RwLock

```superc
// Mutex — the guard exposes the value via get()/get_mut(); *guard = v is rejected
let m = Mutex::<i32>::new(0);
{
    let mut guard = m.lock();  // RAII guard, auto-release on scope exit
    *guard.get_mut() = 42;     // get_mut needs a `mut` guard binding
}

// RwLock
let rw = RwLock::<Vector<i32>>::new(Vector::<i32>::new());
{
    let r = rw.read();         // shared read access
    println("{}", r.len());    // method calls auto-deref through the guard
}
{
    let mut w = rw.write();    // exclusive write access
    w.push(1);
}
```

Both are task-aware: a coroutine that contends parks instead of blocking its worker.
Method calls auto-deref through a guard; deref-assignment does not — write through
`.get_mut()` (`*guard.get_mut() = v`, never `*guard = v`).

## Channel

```superc
// bounded(n) / unbounded() return a Channel<T>; handles come from sender()/receiver()
let ch = Channel::<Message>::bounded(64);
let tx = ch.sender();           // cloneable Sender<Message>
let rx = ch.receiver();         // cloneable Receiver<Message>

// Send (parks if full for bounded); returns SendResult<Message>
let r = tx.send(Message { v: 1 });

// Receive (parks if empty); Option<Message>, None once closed and drained
let maybe = rx.recv();

// Non-blocking
let maybe2 = rx.try_recv();                 // Option<Message>
let r2 = tx.try_send(Message { v: 2 });     // SendResult<Message>

// Timed / deadline / batch
let maybe3 = rx.recv_timeout(time::Duration::from_millis(1));
// send_timeout, send_deadline, recv_deadline, send_batch, recv_batch also exist
```

Handles are cloneable. `Sender::close` closes explicitly; the channel also closes when
all handles of either side are dropped.

## WaitGroup

```superc
let wg = WaitGroup::new();
for i in 0..10 {
    wg.add(1);
    let w = wg.clone();        // owning handle for the task to consume
    launch || {
        defer w.done();
        process(i);
    };
}
wg.wait();   // parks until counter reaches 0
```

A `WaitGroup` is a `Free` value: capturing `wg` itself in a launched closure would
**move** it (a compile error on the next loop iteration and the final `wait`). Clone a
handle per task.

## Condvar

```superc
struct State {
    pub ready: Mutex<bool>,
    pub cv: Condvar,
}

let pair = Arc::<State>::new(State { ready: Mutex::<bool>::new(false), cv: Condvar::new() });
let p2 = pair.clone();

launch || {
    let st = p2.get();              // Arc has no deref; use .get() for &T
    {
        let mut guard = st.ready.lock();
        *guard.get_mut() = true;
    }
    st.cv.notify_one();
};

let st = pair.get();
let guard = st.ready.lock();
while !*guard.get() {
    st.cv.wait(&guard);             // borrows the guard, parks the coroutine
}
```

`Condvar::wait(&guard)` **borrows** the guard and returns nothing — the guard stays
usable after the wake (no Rust-style consume-and-return). `wait_until` takes an absolute
deadline.

## Data Parallelism Functions

| Function | Description |
|----------|-------------|
| `parallel::range(range, body)` | Execute body for each index in range |
| `parallel::each(slice, body)` | Execute body for each element (shared) |
| `parallel::each_mut(slice, body)` | Execute body for each element (exclusive) |
| `parallel::chunks_mut(slice, chunk_size, body)` | Process in chunks |
| `parallel::reduce(slice, make, fold, combine)` | Reduction: `make` is an identity **closure** (a copied init would double-free owning accumulators); `combine` merges per-worker results |
| `parallel::sections(build)` | Fork-join: one builder closure receiving `&mut Sections`; add work via `Sections::add(f)` |

Each has a `*_with` variant (`range_with`, `each_with`, `each_mut_with`,
`chunks_mut_with`, `reduce_with`) taking an `Options` for schedule and grain size.
All require `Send + Sync` on the closure. Slices come from range-indexing a Vector
(`v[0..n]`, `v.index_range_mut(0..n)`).
