// One OS thread per task: no runtime in the middle, the kernel scheduler does all of it. A counting
// semaphore holds the effective concurrency of the blocking unit to LIMIT, as every lane does.
#[path = "../common.rs"]
mod common;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;

struct Sem {
    free: Mutex<usize>,
    cv: Condvar,
}

impl Sem {
    fn acquire(&self) {
        let mut g = self.free.lock().unwrap();
        while *g == 0 {
            g = self.cv.wait(g).unwrap();
        }
        *g -= 1;
    }
    fn release(&self) {
        *self.free.lock().unwrap() += 1;
        self.cv.notify_one();
    }
}

fn main() {
    let (iters, tasks, limit) = (common::env("ITERS", 5), common::env("TASKS", 1000), common::env("LIMIT", 64));
    let dir = Arc::new(common::dir());
    let sem = Arc::new(Sem { free: Mutex::new(limit), cv: Condvar::new() });
    let ok = Arc::new(AtomicU64::new(0));
    let mut samples = Vec::with_capacity(iters);
    for _ in 0..iters {
        let t0 = Instant::now();
        let hs: Vec<_> = (0..tasks)
            .map(|i| {
                let (dir, sem, ok) = (dir.clone(), sem.clone(), ok.clone());
                std::thread::spawn(move || {
                    sem.acquire();
                    let r = common::unit(&dir, i);
                    sem.release();
                    if r {
                        ok.fetch_add(1, Ordering::Relaxed);
                    }
                })
            })
            .collect();
        for h in hs {
            let _ = h.join();
        }
        samples.push(t0.elapsed().as_secs_f64() * 1000.0);
    }
    common::report(&samples, tasks, ok.load(Ordering::Relaxed), (iters * tasks) as u64, limit);
}
