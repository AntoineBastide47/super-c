// Shared by the three Rust lanes: the unit of work, the environment, and the report line.
use std::io::Write;

pub const PAYLOAD: [u8; 4096] = [0u8; 4096]; // the identical payload of every lane: 4 KiB of zeros

/// Create a file, write 4 KiB, sync it to the device (F_FULLFSYNC on macOS, as Go's Sync does), close.
/// True only when every call succeeded with the full count.
pub fn unit(dir: &str, id: usize) -> bool {
    let p = format!("{}/f{}", dir, id);
    let mut f = match std::fs::File::create(&p) {
        Ok(f) => f,
        Err(_) => return false,
    };
    let mut ok = f.write_all(&PAYLOAD).is_ok();
    if f.sync_all().is_err() {
        ok = false;
    }
    drop(f); // close; std reports nothing here, so the flush and sync above carry the validation
    ok
}

pub fn env(name: &str, def: usize) -> usize {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).filter(|&n| n > 0).unwrap_or(def)
}

pub fn dir() -> String {
    match std::env::var("SC_COMPARE_DIR") {
        Ok(d) if !d.is_empty() => d,
        _ => {
            eprintln!("rust: SC_COMPARE_DIR is not set");
            std::process::exit(2);
        }
    }
}

/// cold_ms median_ms p95_ms ns_per_op ok total limit: the first iteration apart, the distribution of the
/// rest, and the validated work. Exits nonzero when the work fell short.
pub fn report(samples: &[f64], tasks: usize, ok: u64, total: u64, limit: usize) {
    let cold = samples[0];
    let mut rest: Vec<f64> = if samples.len() > 1 { samples[1..].to_vec() } else { samples.to_vec() };
    rest.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = rest.len();
    let median = if n % 2 == 0 { (rest[n / 2 - 1] + rest[n / 2]) / 2.0 } else { rest[n / 2] };
    let p95 = rest[(n * 95 + 99) / 100 - 1];
    println!("{:.1} {:.1} {:.1} {:.0} {} {} {}", cold, median, p95, median * 1e6 / tasks as f64, ok, total, limit);
    if ok != total {
        std::process::exit(1);
    }
}
