// tokio + block_in_place: the closure is NOT moved. The runtime moves every OTHER task off this worker and
// lets the syscall run here. That is the strategy Go uses for blocking syscalls, and the one worth measuring
// against `spawn_blocking` before deciding whether Super-C should adopt it. The worker pool is sized to
// LIMIT (a blocked worker is what bounds this strategy) and the semaphore holds the effective concurrency
// there as in every lane; the runtime is built and dropped explicitly.
#[path = "../common.rs"]
mod common;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

fn main() {
    let (iters, tasks, limit) = (common::env("ITERS", 5), common::env("TASKS", 1000), common::env("LIMIT", 64));
    let dir = Arc::new(common::dir());
    let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(limit).enable_all().build().unwrap();
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
                        let r = tokio::task::block_in_place(|| common::unit(&dir, i));
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
