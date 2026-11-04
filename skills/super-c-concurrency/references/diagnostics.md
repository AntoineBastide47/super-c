# Task Diagnostics

## Task Diagnostics

| Tool | Purpose |
|------|---------|
| `SC_TASK_TRACE=1` | Trace scheduler decisions for the life of the process |
| Panic messages | Include task id: `panic: [task 7] message` |
| Stack overflow report | Names the stack that ran out, exits 134 (see below) |
| Illegal instruction report | POSIX: `super-c: illegal instruction at 0x<pc>` (a jump through a corrupt code address, or code for a CPU feature the machine lacks), then the previous handler or the default action (the status stays SIGILL) |
| `runtime::live_tasks()` | Return count of tasks still alive |
| Shutdown report | Account for tasks that never finished |
| A profile with `lockdep = true`, `SC_LOCK_ORDER=1` | Lock-order inversion reports (`ffi/sc_runtime.spc`); `f`/`F` aborts on the first |

**Stack overflow report.** The program's runtime (`std/rt/base.spc`) arms the
main thread before `main`; every thread std starts (pool workers, blocking-pool threads, the
reactor, `thread::spawn`) calls `sc_rt_stack_guard_install` first. On POSIX an armed thread has a
signal stack whose base records its own stack's bounds; a SIGSEGV (SIGBUS on macOS) is an
overflow at the guard of the thread's own stack or, on a coroutine stack, within 128 KiB of the
stack pointer, so nothing is tracked per switch. Any other fault goes to the handler installed
before, or to the default action. Windows reports `EXCEPTION_STACK_OVERFLOW` from a vectored
handler, each armed thread keeping a 16 KiB stack guarantee. The report is one line on stderr,
then exit 134 (the test runner counts it as a panic):

```
super-c: stack overflow in the main thread (8388608 byte stack)
super-c: stack overflow in a thread (8388608 byte stack)
super-c: [task 3] stack overflow (262144 byte task stack exhausted; raise it with runtime::set_stack_size)
```

A job on a worker's own stack prints `[task N]` with the thread form. The handler is
async-signal-safe, so it flushes nothing: output still buffered in stdout is
lost. Signal stacks of ended threads wait in a 64-slot lock-free cache: arming costs about 0.2 us
per thread from it (macOS; 0.4 us on Linux) against 2 us for a fresh mapping, and about 2 us once
at startup.

The shutdown report prints each unfinished task's `state`, `phase`, `done` and `handoff`:
`done true handoff 1` is a worker stuck in that task's park hand-off tail, and the cure is
that worker's backtrace, not a guess. Every `Coroutine` field another thread may read or
compare after the task's own worker last wrote it is accessed atomically, `done` (the
report reads it) and `park_state` on block reuse (a waker that lost the last claim may
still be finishing its compare) included: `check.sh` runs `ci/*_hunt.spc`, which check their
counts and bound their waits, and fails on any nonzero exit.

Checking profiles trap on integer overflow, so runtime arithmetic on values that other
threads write must hold for every order of the reads. A clock value published by another
worker can be LATER than this thread's own earlier clock read: compare `now < last + interval`,
never `now - last` (`pool_trim`). A difference of two summed counters reads the one that
must be smaller FIRST, with a Release store on its side: `live_tasks` reads completions
before spawns, so while tasks run it can be high but never below the truth. A trap without
`[task N]` came from a worker's scheduler loop or a plain thread; on macOS the crash report
in `~/Library/Logs/DiagnosticReports` names the function and line.

### Hunting races and hangs

- Get the stuck thread's backtrace before any fix; a guessed fix hides the cause. Probe
  with a program that parks instead of aborting on the bad state, then attach `gdb -p`
  (in a Linux container started with `--cap-add=SYS_PTRACE`) or run macOS `sample` on the
  child. lldb cannot unwind coroutine stacks; gdb in a Linux container can.
- Rare races show only under load: run about eight processes at once in a Linux container
  limited to two to four CPUs.
- Prove a hunt shape reaches its window: flip `RT_HOOKS`, rebuild, and count the hook hits.
  A passing hunt proves nothing about its shape.
- In `ci/mutex_hunt.spc`, create the `Sender` before the holder (a `recv` with no live
  sender returns at once). A "cancel after selection" shape must release first and cancel
  inside the held-open pop window.
- In a hunt's `fail`, print `rt::task_snapshot` (state, phase, wait kind, wait object).
  `rt::try_shutdown` reports nothing there: its own cancellation releases the parked tasks.
- After a counter change in runtime or sync code, run race_hunt, cancel_hunt and
  queue_hunt twice each under a profile with `lockdep = true` and `SC_LOCK_ORDER=fatal`; expect
  zero failures. No build has ThreadSanitizer: a hunt finds a race by its checks and the leak
  tracker.
- `Condvar::unlink` walks the wait queue, so thousands of timed waiters on one condvar cost
  O(n^2). A timed-wait benchmark spreads its waiters over many condvars.

### Measuring the runtime

- Keep construction, spawn and join out of the timed round: `bench/mutex_bench.spc`
  builds a `Crew` once and parks it on a `Barrier` between rounds. A crew that spins
  between rounds takes the workers the lock needs.
- mutex_section_0, mutex_section_64 and mutex_handoff are bimodal (all spin, or waiters
  park). Judge a contention policy on mutex_starvation's distribution, not on a throughput
  median. A per-round minimum is useless for contended lanes.
- To show caller-class bias, give all callers one shared budget; a fixed quota per caller
  cannot show it.
- Socket echo lanes leave thousands of sockets in TIME_WAIT (30 s on macOS). Back-to-back
  runs exhaust ephemeral ports and look like a reactor hang: let TIME_WAIT drain between
  passes.
- Faster spawn raises resident memory in bursts (more tasks live at once). That is not a
  leak.
- A lane stalled at 0% CPU is a runtime deadlock: sample it and fix it before measuring.
- A scheduler A/B base build also needs `RT_STATS` on; drop calls to entry points the base
  lacks.
- A tail-recursive deep-stack helper becomes a loop under optimization. Escape the frame
  address with `bench::black_box` (`deep` in `bench/micro_bench.spc`).
