// One OS thread per task: no runtime in the middle, the kernel scheduler does all of it.
use std::io::{Read, Write};
use std::time::Instant;

fn unit(id: usize) {
    let p = format!("/tmp/sc-compare/f{}", id);
    if let Ok(mut f) = std::fs::File::create(&p) {
        let _ = f.write_all(&[0u8; 4096]);
        let _ = f.sync_all(); // F_FULLFSYNC on macOS: the real device barrier, as Go's Sync does
    }
}

fn env(name: &str, def: usize) -> usize {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(def)
}

fn main() {
    let (iters, tasks) = (env("ITERS", 5), env("TASKS", 1000));
    let start = Instant::now();
    for _ in 0..iters {
        let hs: Vec<_> = (0..tasks).map(|i| std::thread::spawn(move || unit(i))).collect();
        for h in hs {
            let _ = h.join();
        }
    }
    let el = start.elapsed();
    println!("{:.1} {:.0}", el.as_secs_f64() * 1000.0 / iters as f64,
             el.as_nanos() as f64 / (iters * tasks) as f64);
}
