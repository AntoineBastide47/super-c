# Blocking-I/O fan-out: Super-C against Go, Rust threads and tokio

One workload, six lanes, same machine. This is the shape where runtimes actually differ: **many concurrent
tasks, each doing a blocking syscall**.

## The workload, and why it is specified rather than described

`ITERS` iterations. Each iteration spawns `TASKS` concurrent units of work and waits for all of them; the
timer covers spawn-to-last-completion. Each unit creates `$SC_COMPARE_DIR/f<id>`, writes 4 KiB of zeros,
**syncs it to the device**, and closes it.

The sync is the entire point. This benchmark started as the gists' workload, read 10 bytes from
`/dev/urandom` and write them to `/dev/null`, and that measured nothing useful here:

```text
/dev/urandom : tokio-spawn-blocking 24.3 ms   tokio-block-in-place 24.2 ms   (indistinguishable)
fsync        : tokio-spawn-blocking 2222 ms   tokio-block-in-place 2210 ms
```

A syscall that returns in a microsecond gives a runtime nothing to schedule around, so every strategy looks
the same. Durability is what makes a blocking call actually block. The short-syscall shape is kept as its
own test (`concurrency_bench::io_short` under `super-c bench`) because it measures the hand-off itself.

**All lanes must do the same work and check it.** On macOS plain `fsync` only reaches the device cache;
Go's `File.Sync` and Rust's `sync_all` both issue `F_FULLFSYNC`, so the Super-C lane does too. Every unit
checks the open, the full write, the durability call and the close; a unit that fails any of them counts as
not done, and a lane whose count falls short exits nonzero and is reported as FAILED.

**All lanes block on the same number of units at once.** A counting semaphore of `LIMIT` permits
(default 64, the Super-C blocking pool's thread limit) surrounds the unit in every lane; the tokio lanes
also size their pool to it. The `super-c-direct` lane is bounded by its worker count as well, and prints the
smaller of the two as its limit.

**Setup and teardown are identical.** Every lane reads its directory from `$SC_COMPARE_DIR` (the script
creates one per lane and removes only those), spawns nothing before the first iteration, and shuts its
runtime down explicitly before reporting where the runtime has a shutdown (Super-C's blocking pool and
scheduler, tokio's runtime; Go has none). Nothing is allocated inside the timed loop beyond what the
runtime itself needs, and no unit communicates with another.

## What a lane reports

```text
cold_ms median_ms p95_ms ns_per_op ok total limit
```

The first iteration is the **cold** one: it pays for the runtime's start, the pool's threads and the first
stacks, and is never mixed into the rest. The other iterations are a distribution (median and p95 of the
per-iteration milliseconds; `ns/op` is the median per unit). `ok/total` is the validated work.

Defaults: `ITERS=5`, `TASKS=1000`, `LIMIT=64`. Each iteration is hundreds of milliseconds to seconds,
because the device is genuinely in the loop; `ITERS=20` gives a p95 worth reading.

## The lanes, and what each one is actually testing

| lane | what it does about the blocking call |
|---|---|
| `go-goroutines` | goroutine does the syscall itself; the runtime hands the P to another M |
| `rust-threads` | one OS thread per task; the kernel scheduler does everything |
| `tokio-spawn-blocking` | the closure is MOVED to a separate blocking pool |
| `tokio-block-in-place` | the other tasks are moved OFF this worker; the syscall runs in place |
| `super-c-blocking` | `blocking::call`: our equivalent of `spawn_blocking` |
| `super-c-direct` | the coroutine makes the syscall on its worker, blocking it |

The last four are the interesting comparison. `spawn_blocking` and `block_in_place` are two answers to the
same question, and Go picks the second: do not move the work, move everything else. `super-c-blocking` is
where we are; `super-c-direct` shows what blocking a worker costs, which is the penalty a handoff strategy
would avoid.

## Running it

```sh
bench/compare/run.sh             # defaults
ITERS=20 bench/compare/run.sh    # enough iterations for the p95
```

A lane whose toolchain is missing is reported as skipped; a lane whose build fails, exits nonzero or
validates fewer units than it ran is reported as FAILED and the script exits nonzero, keeping the build
logs. Every lane is built optimised (`go build`, `cargo build --release`, and Super-C's `release` profile;
the script refuses the script-mode build, which compiles the emitted C with no `-O` flag at all).
