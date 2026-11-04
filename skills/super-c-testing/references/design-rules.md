# Test Design Rules

## Test Design Rules

Choosing an oracle, batching cases and keeping a test's CPU and energy cost low: `super-c-test-design`.

- **One assertion per concept.** Split independent checks into separate `assert` calls:
  a combined boolean hides which condition failed.
- **No global mutable state.** The fork model means tests run in separate processes.
  Shared state must go through the global fixture mechanism.
- **Test the contract, not the implementation.** Assert on observable behavior (return
  values, side effects, error messages), not on internal data structure shapes.
- **Fixture values, not fixture effects.** `@test_init` returns a value. Side effects
  that need cleanup go in `@test_free`.
- **A cancelled task reports through `defer`.** Code after a cancelled wait never runs,
  so a `WaitGroup::done` or counter written after the wait is lost and the waiter hangs.
  Put the report in a `defer` at the top of the body; `tests/concurrency/cancel_test.spc` and the
  cancellation benchmark lanes follow this rule.
- **A concurrency test never depends on the scheduler's order.** It asserts only what
  holds for every legal interleaving, and it waits for the STATE it needs, never for a
  duration that usually suffices. `time::sleep(short())` before a cancel, a fixed hold
  while callers are meant to queue, a latency bound on a wake, or an assertion right
  after a signal: each passed for months on an idle machine and then failed on a loaded
  runner, where a preemption landed inside the window. A test's sleep is legitimate
  only as a cancellation point inside a task, as a widening of the window for a DEFECT
  to show in a negative test, or as a bounded poll interval.
- **Wait on state through `tests/concurrency/parallel_harness.spc`** (`import tests::concurrency::parallel_harness
  as ph;`): `wait_parked(key)` until a task is at its wait (the snapshot shows its wait
  kind, so a cancellation requested next is claimed by that park), `wait_waiting(kind, n)`
  until `n` tasks wait on a `WK_*` kind, `wait_gone(key)` and `wait_quiescent()` until a
  task or every task has completed (a signal fires before completion, and completion
  before the block retires), `wait_count(&counter, n)`, `wait_os_parked(n)` until `n`
  plain threads sleep in the parking lot (true at once on Windows, whose
  `WaitOnAddress` keeps no records to count), and `wait_pool_within(bytes)` until
  the idle block pool has settled under a budget (worker stashes are sized so the pool
  stays within its budget at all times). Every
  wait is bounded at five seconds and returns whether the state was reached, so the
  caller asserts on it and a hang fails with a name. The io tests wait for their I/O wait
  records through `wait_waiting(rt::WK_IO, n)` (what `io::pending_waits()` counts; a record
  precedes registration), the blocking tests on `blocking::stats()` (running, queued,
  `admit_waits`).
- **Hold with a gate, not a clock.** A pool thread or a lock holder that must stay busy
  while other callers queue holds until a shared counter opens (`hold_open` in
  `tests/concurrency/blocking_test.spc`, `hold_until` in `tests/concurrency/mutex_test.spc`), and the test
  opens it once the queueing it wanted is a fact. A hold measured in milliseconds loses
  to a slow launch.
- **A signal lands before the signaller's cleanup.** A `defer w.done()` fires before
  the task's locals drop, a holder that signals in its last statement still owns its
  guard, and a blocking-pool caller is woken before the thread that ran its call counts
  itself out. Drop the guard in an inner block before signalling, and a waiter that
  asserts on a destruction count or on pool statistics polls for that state with a bound
  (`wait_frees`, `wait_quiet` in `tests/concurrency/blocking_test.spc`) instead of asserting right
  after the wait.
- **A wake's latency belongs to a benchmark.** A test asserts that a wake happened and
  followed its cause, not that it arrived within some milliseconds or before a deadline:
  that number measures the runner. A wait that only its cause may end has no deadline
  (`io::wait_until(fd, w, 0)`), so a missed wake shows as a bounded state wait that fails.
  The task reports what ended its wait (a counter the test reads with `wait_count`), and
  a call that must return without waiting is covered by the hang guard alone. A lower
  bound (a deadline was waited out, a sleep never ends early) is kept: load only makes
  it hold more easily.
- **Prove a blocking call leaves its worker with a gate.** `blocking_attribute` in
  `tests/cli/cli_test.spc` gives the blocking calls a C wait that returns only once another
  task on the same single worker opens it, so the calls return the open gate only if
  they parked; a duration they overlap in measures the runner.
- **Grep every new or reviewed concurrency test** for `time::sleep(` and `now_ns() - `;
  justify each hit by the rules above or replace it with a state wait.
- **Equal deadlines come from one absolute value.** A test that needs equal deadlines
  computes one `base` and passes it to every wait (`cv.wait_until(&g, base)`), never
  `sleep_ns(base - now)` per waiter.
- **Probe markers go to stderr.** `SC_LEAK_CHECK=fatal` ends a leaking process with
  `_Exit(23)`, which drops buffered stdout. Detect a stuck run by process age, not by a
  missing marker line.
- **Failure injection counts every substrate allocation.** `sc_rt_fail_arm(FAIL_ALLOC, n)`
  fails the `n`th allocation of the C substrate in construction order (`tests/concurrency/thread_test.spc`
  comments name each one). Edit one call by its unique context; a search-and-replace on
  `FAIL_ALLOC, n` changes every test with that `n`.
- **Allocation-count tests divide over many runs** (64). Under `SC_LEAK_CHECK` the tracker
  itself allocates irregularly for the first few measurements of a shape, and a warm-up
  alone does not fix that.
- **Restore what a test sets.** A test changes its own process environment through
  `cli::set_env(name, value)`, whose guard puts the old value back (or removes the variable) when
  it drops: under `--test-no-fork` every test shares one process.
- **Unset, do not empty.** `std::platform::env::unset` removes a variable; a variable set to `""`
  still passes a `getenv(..) != NULL` check. On Windows an empty value removes it, as `_putenv_s` does.
- **No shell on Windows.** `cli::run_with` and a custom `[command]` line (`bsys::run_line`) run
  `/bin/sh -c` on POSIX and pass the line as written to `CreateProcessW` on Windows. A harness
  command line never uses `cd X && K=V cmd`: pass the variable through `run_with`'s env
  parameter (the child's whole environment) and change directory with
  `std::platform::process::set_current_dir` (`cli::superc_env_in`), resolving
  `cli::superc_path()` before the change. A test that runs a shell line returns early under
  `if cli::on_wasm() || cli::on_windows() { return; }`.
- **No parallel `system()`.** macOS `system()` serializes across threads; `popen` or a
  spawn scales (about seven times). Run parallel subprocess work through those.
- **Pin our own rules, not libc's.** C leaves the zero sign of `fmin`/`fmax` unspecified
  (glibc returns the second operand for `(+0, -0)`), so a differential test asserts our
  sign rule on both-zero pairs (`tests/stdlib/float_test.spc`).
- **Drive the driver through subprocess tests.** Prune and macro-paste defects that do
  not change emitted C pass the self-hosting fixpoint; only a test that runs the built
  driver catches them.
