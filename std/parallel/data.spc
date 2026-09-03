// Data parallelism over the coroutine pool: split a loop, a slice or a set of independent sections across
// the worker threads and wait for all of it. Import with `import std::parallel::data as parallel;`.
//
//     let n = values.len();
//     parallel::range(0..n, |i| { work(i); });
//     parallel::each(values[0..n], |v| { read(v); });
//     parallel::each_mut(values.index_range_mut(0..n), |v| { *v = *v + 1; });
//     parallel::chunks_mut(values.index_range_mut(0..n), 64, |c| { process(c); });
//     let total = parallel::reduce(values[0..n], || 0i64, |a, v| { a + *v; }, |a, b| { a + b; });
//     parallel::sections(|s| { s.add(|| load()); s.add(|| compile()); });
//
// Work is CHUNKED, never one task per iteration: a million-index loop becomes a few tasks per worker. Each
// chunk runs as a stackless JOB (`runtime::spawn_job`); no per-chunk stack, no context switch, and the
// calling *coroutine* parks until every chunk is done, so its worker keeps serving other tasks meanwhile;
// a plain thread blocks instead. Because the call does not return until every chunk has finished, a body may
// safely borrow the caller's locals, which is how it reaches shared state:
//
//     let counter = Atomic::<i64>::new(0);
//     let c = &counter;                                  // captures are by COPY, so share by reference:
//     parallel::range(0..n, |i| { c.fetch_add(1, ..); }); // every copy of `c` points at one atomic
//
// The body is `fn(..) + Send + Sync`, and that bound is the safety story. A closure that owns a capture or
// mutates one is `fn move`, not `fn`, so it does not satisfy the bound: the body is copied to every worker,
// which would double-free an owned capture, and a mutated capture is an implicit `&mut` into the caller's
// frame: shared across workers, a data race. So this is rejected, exactly as it should be:
//
//     parallel::range(0..n, |i| { values.set(i, 1); });   // error: not `fn(usize)`
//
// Mutation in parallel goes through a partition (`each_mut`, `chunks_mut`) whose disjointness this module
// establishes with one audited `unsafe` split, or through an `Atomic`/`Mutex`.
//
// One wart: a range of two literals defaults to `Range<i32>`, so `0..1000` needs a `usize` bound;
// `0..1000usize`, or the far more common `0..values.len()`.

import std::parallel::runtime as runtime;
import std::parallel::sync as sync;
import std::parallel::atomics as atomics;

// Chunks per worker. More than one lets a worker that finishes early pick up another chunk, which is most of
// what dynamic scheduling buys, at no extra cost; many more would only add per-chunk overhead.
const CHUNKS_PER_WORKER: usize = 4;

/// How a parallel loop divides its index space.
pub enum Schedule {
    Static, // equal contiguous chunks, decided up front: lowest overhead, for uniform per-index cost
    Dynamic, // workers claim `grain_size` indices at a time: absorbs wildly uneven per-index cost
    Guided, // claims start large and shrink towards `grain_size`: Dynamic's balance, fewer claims
}

/// Tuning for the `*_with` forms.
pub struct Options {
    pub schedule: Schedule,
    pub grain_size: usize, // Dynamic: indices per claim. Guided: the floor. 0 picks a default from the size
}

extend Options {
    /// Static scheduling with an automatic grain: what the plain `range`/`each`/... forms use.
    pub const fn default() Options {
        return Options { schedule: Schedule::Static, grain_size: 0 };
    }
}

// Chunk plumbing. Non-generic on purpose: it is compiled once, and each API entry point adds only a small
// typed trampoline. `pub` on these types and functions is for linkage: those trampolines are
// monomorphized in the caller's module. None of it is user-facing.

/// The outstanding-chunk counter the caller waits on. Task-aware through `Condvar`: a calling coroutine
/// parks, any other thread blocks. It lives in the caller's frame, which is sound because the caller does
/// not return until the count reaches zero.
@no_const
pub struct Latch {
    pub left: sync::Mutex<i64>,
    pub cv: sync::Condvar,
}

/// One parallel call: where the work is, how it is claimed, and who to tell when a chunk ends.
@no_const
pub struct Batch {
    pub latch: *mut Latch, // null: running inline on the calling thread, nothing to notify
    pub shared: *mut void, // the call's typed payload (the body closure)
    pub cursor: atomics::Atomic<usize>, // Dynamic: next unclaimed index
    pub end: usize,
    pub grain: usize,
    pub mode: i32, // 0 Static / 1 Dynamic / 2 Guided
    pub nw: usize, // workers, which is what Guided divides the remaining work by
}

/// A single chunk: its pre-assigned range (Static) and its ordinal, which `reduce` uses to pick a slot.
@no_const
pub struct ChunkEnv {
    pub batch: *mut Batch,
    pub lo: usize,
    pub hi: usize,
    pub idx: usize,
}

/// The next index range for this chunk, `[lo, hi)`; `false` once it has no more work. Static hands over the
/// chunk's own range once; Dynamic claims `grain` indices at a time from the shared cursor, so a chunk that
/// draws cheap indices comes back for more; Guided claims a share of what remains, shrinking to `grain`.
pub fn next_range(ce: *mut ChunkEnv, lo: &mut usize, hi: &mut usize) bool {
    let b = unsafe ce.batch;
    if unsafe b.mode == 0 {
        if unsafe ce.lo >= unsafe ce.hi {
            return false;
        }
        *lo = unsafe ce.lo;
        *hi = unsafe ce.hi;
        // One-shot.
        unsafe ce.lo = unsafe ce.hi;
        return true;
    }
    let cur = &unsafe b.cursor;
    let grain = unsafe b.grain;
    let end = unsafe b.end;
    if unsafe b.mode == 1 {
        let start = cur.fetch_add(grain, atomics::MemoryOrder::Relaxed);
        if start >= end {
            return false;
        }
        let mut stop = start + grain;
        if stop > end {
            stop = end;
        }
        *lo = start;
        *hi = stop;
        return true;
    }
    // Guided: take a share of what is LEFT rather than a fixed slice, so early claims are big (few trips to
    // the cursor) and late ones are small (nobody is left holding a long tail). `grain_size` is the floor.
    // A CAS loop, not fetch_add: the size depends on the cursor value we are claiming from.
    loop {
        let start = cur.load(atomics::MemoryOrder::Relaxed);
        if start >= end {
            return false;
        }
        let left = end - start;
        let mut take = left / (unsafe b.nw * 2);
        if take < grain {
            take = grain;
        }
        if take > left {
            take = left;
        }
        if cur.compare_exchange(start, start + take, atomics::MemoryOrder::Relaxed, atomics::MemoryOrder::Relaxed) {
            *lo = start;
            *hi = start + take;
            return true;
        }
    }
}

/// Report this chunk finished; the last one out wakes the caller.
pub fn finish(ce: *mut ChunkEnv) {
    let l = unsafe ce.batch.latch;
    if l == null {
        // Ran inline: the caller is this thread.
        return;
    }
    let lref = &unsafe l.left;
    let mut g = lref.lock();
    let mut zero = false;
    {
        let n = g.get_mut();
        *n = *n - 1;
        zero = *n == 0;
    }
    if zero {
        // Under the paired lock: it guards the condvar's wait queue.
        let cvref = &unsafe l.cv;
        cvref.notify_all();
    }
}

/// How many chunks a call over `total` units will use: one is "run it inline on this thread". `reduce`
/// needs this up front to size its per-chunk accumulators, so the answer must be exactly what `dispatch`
/// goes on to do.
pub fn chunk_count(total: usize) usize {
    if total == 0 {
        return 0;
    }
    // A job cannot park, so a parallel call nested inside one must not submit-and-wait; run it inline.
    if runtime::in_job() {
        return 1;
    }
    let mut n = runtime::worker_count() * CHUNKS_PER_WORKER;
    if n > total {
        n = total;
    }
    if n == 0 {
        n = 1;
    }
    return n;
}

/// Split `[0, total)` into chunks, run `entry` on each (inline when there is only one), and return once every
/// chunk has finished. `shared` is the call's typed payload, handed to `entry` through the batch. `pub` for
/// linkage: every entry point below is monomorphized in the caller's module and calls this.
pub fn dispatch(total: usize, opts: Options, entry: fn(*mut void) void, shared: *mut void) {
    let nchunks = chunk_count(total);
    if nchunks == 0 {
        return;
    }
    let mode = switch opts.schedule {
        Static => {
            0;
        },
        Dynamic => {
            1;
        },
        Guided => {
            2;
        },
    };
    if nchunks == 1 {
        let mut b = Batch {
            latch: null,
            shared: shared,
            cursor: atomics::Atomic::<usize>::new(0),
            end: total,
            grain: total,
            mode: 0,
            nw: 1,
        };
        let mut ce = ChunkEnv { batch: &mut b, lo: 0, hi: total, idx: 0 };
        entry(&mut ce);
        return;
    }
    let mut grain = opts.grain_size;
    if grain == 0 {
        // A few claims per chunk: responsive without thrashing the cursor.
        grain = total / (nchunks * 2);
    }
    if grain == 0 {
        grain = 1;
    }
    let mut latch = Latch { left: sync::Mutex::<i64>::new(nchunks as i64), cv: sync::Condvar::new() };
    let mut b = Batch {
        latch: &mut latch,
        shared: shared,
        cursor: atomics::Atomic::<usize>::new(0),
        end: total,
        grain: grain,
        mode: mode,
        nw: runtime::worker_count(),
    };
    let bp = (&mut b) as *mut Batch;
    // One allocation for every chunk slot; each job holds a pointer into it, and the caller outlives them.
    let mut g = Global {};
    let envs = (unsafe g.alloc(nchunks * sizeof(ChunkEnv), alignof(ChunkEnv))) as *mut ChunkEnv;
    let base = total / nchunks;
    let extra = total % nchunks;
    let mut at: usize = 0;
    for i in 0..nchunks {
        let mut n = base;
        if i < extra {
            // Spread the remainder over the first chunks.
            n = n + 1;
        }
        unsafe envs[i] = ChunkEnv { batch: bp, lo: at, hi: at + n, idx: i };
        at = at + n;
        runtime::spawn_job(entry, &mut unsafe envs[i]);
    }
    {
        let g2 = latch.left.lock();
        while *g2.get() > 0 {
            // Masked: the chunks write through pointers into this frame, so the join must never unwind
            // early. A pending cancellation is observed after the last chunk lands.
            latch.cv.wait_masked(&g2);
        }
    }
    unsafe g.dealloc(envs, nchunks * sizeof(ChunkEnv), alignof(ChunkEnv));
    // `latch` is auto-freed at scope exit (its mutex and condvar with it), which is safe only because no
    // chunk touches it after the count reached zero, and once `raw_mutex_unlock` publishes the release it
    // touches only memory that outlives the mutex (see `RawMutex`), so the last chunk's unlock cannot race
    // this free.
}

// Index-parallel loop.

/// The body, held once and copied per chunk. `pub` for linkage.
@no_const
pub struct RangeShared<F> {
    pub body: F,
    pub start: usize,
}

/// The `range` chunk trampoline. `pub` for linkage.
pub fn range_chunk<F: fn(usize) + Send + Sync>(e: *mut void) {
    let ce = e as *mut ChunkEnv;
    let sh = (unsafe ce.batch.shared) as *mut RangeShared<F>;
    let b = unsafe sh.body; // shallow copy: a `fn(..)` body owns nothing, so copies cost and free nothing
    let base = unsafe sh.start;
    let mut lo: usize = 0;
    let mut hi: usize = 0;
    while next_range(ce, &mut lo, &mut hi) {
        for i in lo..hi {
            b(base + i);
        }
    }
    finish(ce);
}

/// Run `body(i)` for every `i` in `r`, in parallel, and return once all of them have run. Replaces a `for`
/// loop whose iterations are independent.
pub fn range<F: fn(usize) + Send + Sync>(r: Range<usize>, body: F) {
    range_with(r, Options::default(), body);
}

/// `range` with an explicit schedule and grain.
pub fn range_with<F: fn(usize) + Send + Sync>(r: Range<usize>, opts: Options, body: F) {
    let end = if r.inclusive {
        r.end + 1;
    } else {
        r.end;
    };
    if end <= r.start {
        return;
    }
    let mut sh = RangeShared::<F> { body: body, start: r.start };
    dispatch(end - r.start, opts, range_chunk::<F>, &mut sh);
}

// Per-element, read-only.

/// `pub` for linkage.
@no_const
pub struct EachShared<T, F> {
    pub body: F,
    pub items: *const T,
    pub len: usize, // carried so a chunk can CHECK its range instead of trusting it: see `each_chunk`
}

/// The `each` chunk trampoline. `pub` for linkage.
pub fn each_chunk<T, F: fn(&T) + Send + Sync>(e: *mut void) {
    let ce = e as *mut ChunkEnv;
    let sh = (unsafe ce.batch.shared) as *mut EachShared<T, F>;
    let b = unsafe sh.body;
    let items = unsafe sh.items;
    let len = unsafe sh.len;
    let mut lo: usize = 0;
    let mut hi: usize = 0;
    while next_range(ce, &mut lo, &mut hi) {
        // ONE check per range, not per element: the index below is a raw offset, so a `next_range` that ever
        // handed back a range past the end would read off the array with nothing to stop it. The distributor
        // is supposed to make that impossible; this is what turns "supposed to" into a trap.
        assert(hi <= len, "parallel::each: chunk range past the end of the slice");
        for i in lo..hi {
            b(&unsafe items[i]);
        }
    }
    finish(ce);
}

/// Run `body(&element)` for every element, in parallel.
pub fn each<T, F: fn(&T) + Send + Sync>(items: []T, body: F) {
    each_with(items, Options::default(), body);
}

/// `each` with an explicit schedule and grain.
pub fn each_with<T, F: fn(&T) + Send + Sync>(items: []T, opts: Options, body: F) {
    let n = items.len();
    if n == 0 {
        return;
    }
    let mut sh = EachShared::<T, F> { body: body, items: items.as_ptr(), len: n };
    dispatch(n, opts, each_chunk::<T, F>, &mut sh);
}

// Per-element, mutable: disjoint by construction.

/// `pub` for linkage.
@no_const
pub struct EachMutShared<T, F> {
    pub body: F,
    pub items: *mut T,
    pub len: usize, // carried so a chunk can CHECK its range instead of trusting it: see `each_mut_chunk`
}

/// The `each_mut` chunk trampoline. `pub` for linkage.
pub fn each_mut_chunk<T, F: fn(&mut T) + Send + Sync>(e: *mut void) {
    let ce = e as *mut ChunkEnv;
    let sh = (unsafe ce.batch.shared) as *mut EachMutShared<T, F>;
    let b = unsafe sh.body;
    let items = unsafe sh.items;
    let len = unsafe sh.len;
    let mut lo: usize = 0;
    let mut hi: usize = 0;
    while next_range(ce, &mut lo, &mut hi) {
        // ONE check per range, not per element: see `each_chunk`.
        assert(hi <= len, "parallel::each_mut: chunk range past the end of the slice");
        for i in lo..hi {
            // Sound because index ranges never overlap: every element is handed to exactly one chunk.
            b(&mut unsafe items[i]);
        }
    }
    finish(ce);
}

/// Run `body(&mut element)` for every element, in parallel. Each element goes to exactly one worker, so the
/// mutations cannot race: that partition is this module's one unsafe step, audited here instead of being
/// a hole in the type system.
pub fn each_mut<T, F: fn(&mut T) + Send + Sync>(items: []mut T, body: F) {
    each_mut_with(items, Options::default(), body);
}

/// `each_mut` with an explicit schedule and grain.
pub fn each_mut_with<T, F: fn(&mut T) + Send + Sync>(items: []mut T, opts: Options, body: F) {
    let n = items.len();
    if n == 0 {
        return;
    }
    let mut sh = EachMutShared::<T, F> { body: body, items: items.ptr, len: n };
    dispatch(n, opts, each_mut_chunk::<T, F>, &mut sh);
}

// Per-chunk, mutable: the body sees a whole `[]mut T` slice.

/// `pub` for linkage.
@no_const
pub struct ChunksShared<T, F> {
    pub body: F,
    pub items: *mut T,
    pub total: usize,
    pub size: usize,
}

/// The `chunks_mut` trampoline: the dispatched unit is a chunk index, not an element. `pub` for linkage.
pub fn chunks_mut_chunk<T, F: fn([]mut T) + Send + Sync>(e: *mut void) {
    let ce = e as *mut ChunkEnv;
    let sh = (unsafe ce.batch.shared) as *mut ChunksShared<T, F>;
    let b = unsafe sh.body;
    let items = unsafe sh.items;
    let total = unsafe sh.total;
    let size = unsafe sh.size;
    let mut lo: usize = 0;
    let mut hi: usize = 0;
    while next_range(ce, &mut lo, &mut hi) {
        for k in lo..hi {
            let at = k * size;
            let mut n = size;
            if at + n > total {
                // The last chunk is short.
                n = total - at;
            }
            // Disjoint by construction: chunk `k` owns exactly `[k*size, k*size + n)`.
            b(SliceMut::<T> { ptr: unsafe (items + at), len: n });
        }
    }
    finish(ce);
}

/// Hand each worker a whole `[]mut T` window of `size` elements (the last one may be shorter), in parallel.
/// Use it when the work is per-window rather than per-element: a blocked matrix pass, a batched encode.
pub fn chunks_mut<T, F: fn([]mut T) + Send + Sync>(items: []mut T, size: usize, body: F) {
    chunks_mut_with(items, size, Options::default(), body);
}

/// `chunks_mut` with an explicit schedule and grain.
pub fn chunks_mut_with<T, F: fn([]mut T) + Send + Sync>(items: []mut T, size: usize, opts: Options, body: F) {
    let n = items.len();
    let step = if size == 0 {
        1usize;
    } else {
        size;
    };
    if n == 0 {
        return;
    }
    let nchunks = (n + step - 1) / step;
    let mut sh = ChunksShared::<T, F> { body: body, items: items.ptr, total: n, size: step };
    dispatch(nchunks, opts, chunks_mut_chunk::<T, F>, &mut sh);
}

// Parallel reduction.

/// `pub` for linkage.
@no_const
pub struct ReduceShared<T, A, MK, FOLD> {
    pub make: MK,
    pub fold: FOLD,
    pub items: *const T,
    pub out: *mut A, // one accumulator per chunk, indexed by `ChunkEnv.idx`
}

/// The `reduce` chunk trampoline: fold this chunk's elements into its own accumulator. `pub` for linkage.
pub fn reduce_chunk<T, A, MK: fn() A + Send + Sync, FOLD: fn(A, &T) A + Send + Sync>(e: *mut void) {
    let ce = e as *mut ChunkEnv;
    let sh = (unsafe ce.batch.shared) as *mut ReduceShared<T, A, MK, FOLD>;
    let mk = unsafe sh.make;
    let fd = unsafe sh.fold;
    let items = unsafe sh.items;
    let mut acc = mk();
    let mut lo: usize = 0;
    let mut hi: usize = 0;
    while next_range(ce, &mut lo, &mut hi) {
        for i in lo..hi {
            acc = fd(acc, &unsafe items[i]);
        }
    }
    // This chunk's slot, written once.
    unsafe sh.out[unsafe ce.idx] = acc;
    finish(ce);
}

/// Fold `items` in parallel: every chunk starts from `make()`, folds its elements with `fold`, and the
/// per-chunk results are `combine`d into one. `fold` and `combine` must be associative for the result to be
/// deterministic: chunk boundaries and combine order are up to the scheduler.
///
/// The identity is a closure, not a value, because each chunk needs its own: a single `init` value would
/// have to be copied per chunk, which double-frees an accumulator that owns anything (a `String`, a
/// `Vector`).
pub fn reduce<T, A, MK: fn() A + Send + Sync, FOLD: fn(A, &T) A + Send + Sync, COMB: fn(A, A) A>(
    items: []T,
    make: MK,
    fold: FOLD,
    combine: COMB,
) A {
    return reduce_with::<T, A, MK, FOLD, COMB>(items, Options::default(), make, fold, combine);
}

/// `reduce` with an explicit schedule and grain.
pub fn reduce_with<T, A, MK: fn() A + Send + Sync, FOLD: fn(A, &T) A + Send + Sync, COMB: fn(A, A) A>(
    items: []T,
    opts: Options,
    make: MK,
    fold: FOLD,
    combine: COMB,
) A {
    let n = items.len();
    let nslots = chunk_count(n);
    if nslots == 0 {
        // Nothing to fold.
        return make();
    }
    let mut g = Global {};
    let out = (unsafe g.alloc(nslots * sizeof(A), alignof(A))) as *mut A;
    let mut sh = ReduceShared::<T, A, MK, FOLD> { make: make, fold: fold, items: items.as_ptr(), out: out };
    dispatch(n, opts, reduce_chunk::<T, A, MK, FOLD>, &mut sh);
    // Every chunk wrote its slot (a chunk that drew no work wrote the identity), so all `nslots` are live.
    let mut acc = unsafe {
        out[0];
    };
    for k in 1..nslots {
        let part = unsafe {
            out[k];
        };
        acc = combine(acc, part);
    }
    unsafe g.dealloc(out, nslots * sizeof(A), alignof(A));
    return acc;
}

// Independent one-shot sections.

/// One registered section: a type-erased closure box and the trampoline that runs it. `pub` for linkage.
@no_const
pub struct SectionJob {
    pub entry: fn(*mut void) void,
    pub env: *mut void,
}

/// The builder `sections` hands to its closure: call `add` once per independent piece of work.
@no_const
pub struct Sections {
    pub entries: Vector<SectionJob>, // `pub` for linkage: `add` and `sections` monomorphize at the call site
}

/// Runs one section: take the closure out of its box, release the box, call it. `pub` for linkage.
pub fn section_entry<F: fn() + Send + Sync>(env: *mut void) {
    let pp = env as *mut F;
    let f = unsafe {
        pp[0];
    };
    let mut g = Global {};
    unsafe g.dealloc(env, sizeof(F), alignof(F));
    f();
}

extend Sections {
    /// Register a section. Each `add` may take a different closure type: they are boxed and type-erased,
    /// so the sections need not be uniform.
    pub fn add<F: fn() + Send + Sync>(self: &mut Sections, f: F) {
        let mut g = Global {};
        let slot = (unsafe g.alloc(sizeof(F), alignof(F))) as *mut F;
        unsafe slot[0] = f;
        self.entries.push(SectionJob { entry: section_entry::<F>, env: slot });
    }
    /// How many sections are registered.
    pub fn len(self: &Sections) usize {
        return self.entries.len();
    }
}

/// `pub` for linkage.
@no_const
pub struct SectionsShared {
    pub jobs: *const SectionJob, // read-only: a section's closure box is reached through its own pointer
}

/// The `sections` chunk trampoline: non-generic, since the sections are already type-erased.
pub fn sections_chunk(e: *mut void) {
    let ce = e as *mut ChunkEnv;
    let sh = (unsafe ce.batch.shared) as *mut SectionsShared;
    let jobs = unsafe sh.jobs;
    let mut lo: usize = 0;
    let mut hi: usize = 0;
    while next_range(ce, &mut lo, &mut hi) {
        for k in lo..hi {
            let j = unsafe jobs[k];
            let run = j.entry;
            run(j.env);
        }
    }
    finish(ce);
}

/// Run a set of unrelated one-shot tasks together and return once all of them are done:
///
///     parallel::sections(|s| {
///         s.add(|| load_assets());
///         s.add(|| compile_shaders());
///     });
///
/// One section per claim, so a slow section never holds up the others.
pub fn sections<F: fn(&mut Sections)>(build: F) {
    let mut s = Sections { entries: Vector::<SectionJob>::new() };
    build(&mut s);
    let n = s.entries.len();
    if n > 0 {
        let view = s.entries[0..n];
        let mut sh = SectionsShared { jobs: view.ptr };
        dispatch(n, Options { schedule: Schedule::Dynamic, grain_size: 1 }, sections_chunk, &mut sh);
    }
    // `s` (and its entry vector) is auto-freed at scope exit; each section's closure box was released by the
    // trampoline that ran it.
}
