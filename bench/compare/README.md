# Blocking-I/O fan-out: Super-C against Go, Rust threads and tokio

One workload, five runtimes, same machine. This is the benchmark M7 is built around, because it is the shape
where runtimes actually differ: **many concurrent tasks, each doing a blocking syscall**.

## The workload, and why it is specified rather than described

`ITERS` iterations. Each iteration spawns `TASKS` concurrent units of work, waits for all of them, and the
timer covers spawn-to-last-completion. Each unit creates `/tmp/sc-compare/f<id>`, writes 4 KiB, **fsyncs it
to the device**, and closes it.

The fsync is the entire point. This benchmark started as the gists' workload -- read 10 bytes from
`/dev/urandom`, write them to `/dev/null` -- and that turned out to measure nothing useful here:

```text
/dev/urandom : tokio-spawn-blocking 24.3 ms   tokio-block-in-place 24.2 ms   (indistinguishable)
fsync        : tokio-spawn-blocking 2222 ms   tokio-block-in-place 2210 ms
```

A syscall that returns in a microsecond gives a runtime nothing to schedule around, so every strategy looks
the same and the comparison is worthless. Measured on this machine: `/dev/urandom` ~1us, `fsync` 138us,
`F_FULLFSYNC` **4.1ms**. Durability is what makes a blocking call actually block.

**All lanes must use the same durability.** On macOS plain `fsync` only reaches the device cache; Go's
`File.Sync` and Rust's `sync_all` both issue `F_FULLFSYNC` instead, so the Super-C lane does too. Using
`fsync` there would have made it look fast by doing less work.

Nothing is allocated inside the timed loop beyond what the runtime itself needs, and no unit communicates
with another. Every implementation must do exactly this and nothing else -- a benchmark whose lanes disagree
about the work measures the disagreement.

Defaults: `ITERS=5`, `TASKS=1000`. Each iteration is seconds, not milliseconds, because the device is now
genuinely in the loop.

## The lanes, and what each one is actually testing

| lane | what it does about the blocking call |
|---|---|
| `go` | goroutine does the syscall itself; the runtime hands the P to another M |
| `rust-threads` | one OS thread per task; the kernel scheduler does everything |
| `tokio-spawn-blocking` | the closure is MOVED to a separate blocking pool |
| `tokio-block-in-place` | the other tasks are moved OFF this worker; the syscall runs in place |
| `super-c-blocking` | `blocking::call` -- our equivalent of `spawn_blocking` |
| `super-c-direct` | the coroutine makes the syscall on its worker, blocking it |

The last four are the interesting comparison. `spawn_blocking` and `block_in_place` are two answers to the
same question, and Go picks the second: do not move the work, move everything else. `super-c-blocking` is
where we are; `super-c-direct` shows what blocking a worker costs, which is the penalty a handoff strategy
would avoid. If `block_in_place` and `go` beat `spawn_blocking` by a wide margin here, that is the argument
for changing our blocking path -- measured, rather than assumed.

## Running it

```sh
bench/compare/run.sh            # defaults
ITERS=1000 bench/compare/run.sh # the gists' full size
```

Go and Rust lanes are skipped with a note if their toolchain is missing, so the script is useful with
whatever is installed. Every lane is built optimised (`go build`, `cargo build --release`, and Super-C's
`release` profile -- the script refuses the script-mode build, which compiles the emitted C with no `-O`
flag at all and would measure nothing).
