// tokio + spawn_blocking: the closure is MOVED to a separate pool of blocking threads while the task
// awaits it. This is the strategy Super-C's `blocking::call` uses today. The pool is sized to LIMIT and a
// semaphore holds the effective concurrency there too, so every lane blocks on the same number of units at
// once; the runtime is built explicitly and dropped explicitly.
#[path = "../common.rs"]
mod common;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

fn main() {
    let (iters, tasks, limit) = (common::env("ITERS", 5), common::env("TASKS", 1000), common::env("LIMIT", 64));
    let dir = Arc::new(common::dir());
    let rt = tokio::runtime::Builder::new_multi_thread().max_blocking_threads(limit).enable_all().build().unwrap();
    let sem = Arc::new(tokio::sync::Semaphore::new(limit));
    let ok = Arc::new(AtomicU64::new(0));
    let mut samples = Vec::with_capacity(iters);
    rt.block_on(async {
        for _ in 0..iters {
            let t0 = Instant::now();
            let hs: Vec<_> = (0..tasks)
                .map(|i| {
                    let (dir, sem, ok) = (dir.clone(), sem.clone(), ok.clone());
                    tokio::spawn(async move {
                        let _permit = sem.acquire().await.unwrap();
                        let r = tokio::task::spawn_blocking(move || common::unit(&dir, i)).await.unwrap();
                        if r {
                            ok.fetch_add(1, Ordering::Relaxed);
                        }
                    })
                })
                .collect();
            for h in hs {
                let _ = h.await;
            }
            samples.push(t0.elapsed().as_secs_f64() * 1000.0);
        }
    });
    drop(rt);
    common::report(&samples, tasks, ok.load(Ordering::Relaxed), (iters * tasks) as u64, limit);
}
