// Fixed chunks of a pass on worker threads: `chunks` runs one task per chunk and waits for them.
import std::parallel::sync as psync;

// One chunk of a `chunks` call.
struct ChunkTask {
    f: fn(*mut void, usize) void,
    ctx: *mut void,
    c: usize,
}

// The context is the caller's, which outlives the call; each chunk writes its own outputs alone.
unsafe extend ChunkTask as Send {}

/// `f(ctx, c)` for each chunk `c` in `0..n`: on worker threads, or in order on this thread when `jobs` is 1.
pub(package) fn chunks(n: usize, jobs: u32, f: fn(*mut void, usize) void, ctx: *mut void) {
    if jobs == 1 || n < 2 {
        for c in 0..n {
            f(ctx, c);
        }
        return;
    }
    let wg = psync::WaitGroup::new();
    for c in 0..n {
        let t = ChunkTask { f: f, ctx: ctx, c: c };
        wg.add(1);
        let wgc = wg.clone();
        launch || {
            let g = t.f;
            g(t.ctx, t.c);
            wgc.done();
        };
    }
    wg.wait_masked();
}
