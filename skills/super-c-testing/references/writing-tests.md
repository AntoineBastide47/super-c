# Writing Tests

## Writing Tests

### Basic test

```superc
@test
fn adds_correctly() {
    assert_eq(2 + 2, 4);
}
```

`@test` marks a function as a test. In a non-`--test` build, test functions are not
emitted at all.

### Fixtures with `@test_init`

```superc
struct Fx { pub v: Vector<i32> }

@test_init
fn setup() Fx {
    let mut v = Vector::<i32>::new();
    v.push(1); v.push(2);
    return Fx { v: v };
}

@test
fn drains(fx: &mut Fx) {
    let mut s = 0;
    while let Some(x) = fx.v.pop() { s += x; }
    assert_eq(s, 3);
}
```

`@test_init` returns a fixture **value**, built fresh for each test that declares a
matching parameter. Constraints: the `@test_init` function takes no parameters and must
return a plain non-generic struct or enum; a suite `@test_init` (inside an `extend`) must
return the extended type itself. Fixtures are values because a `static mut` cannot hold a
`Free` type. A test that reads a process-lifetime counter (such as the runtime's cancel
count) records its baseline in a `@test_init` fixture (`Base` in `tests/concurrency/cancel_test.spc`)
and never assumes a fresh process.

### Teardown with `@test_free`

```superc
@test_free
fn teardown(fx: &mut Fx) {
    // clean up out-of-band effects (temp files, connections)
}
```

Optional. Runs after the test body. The fixture's owned memory is RAII-freed
automatically after `@test_free`. You only need `@test_free` for effects RAII does not
cover.

### Expected panics

```superc
@test(should_panic)
fn rejects_bad_input() {
    panic("boom");
}
```

Passes only when the body aborts. Skipped under `--test-no-fork` (no fork to catch the
signal). A panic is SIGABRT, or exit code 134 from the stack-overflow report (Windows: exit code
3 or 0xC0000409 from `abort()`, or 134). Any other end fails the test: a SIGSEGV, or a leak
report's exit 23 under `SC_LEAK_CHECK=fatal`.

### Timeouts

```superc
@test(timeout = 600)
fn builds_the_whole_corpus() { /* ... */ }

@test(should_panic, timeout = 5)
fn rejects_quickly() { panic("boom"); }
```

A test that runs longer than its timeout fails as `FAILED (timed out)`, "timed out after N
s". The run's timeout is `--test-timeout=S` (default 90 s, `0` turns it off); a test's own
`@test(timeout = N)` (seconds, at least 1) overrides it in either direction. The arguments of
`@test` are a list: `should_panic` and `timeout = N`, in any order, each at most once.
`--test-no-fork` applies no timeout. A forked run ends with its five slowest tests and their wall
times (`slowest tests:`), so a CI log shows the margin a timeout leaves. Until a release parses the list form, the repository's
own tests use it only inside string literals (super-c-self-hosting, "New Syntax Cadence").

On POSIX the runner then dumps the state of the test's whole process tree into the test's
replayed output, and kills the tree 3 s later. Each test's capture file is a named file, and
the test's process carries its path in `SC_TEST_DIAG`, which every process it starts inherits.
The runner walks the tree (`proc_listchildpids` on macOS, `/proc` on Linux) and sends each
process SIGURG, one at a time. Every Super-C program answers from its compiler-emitted runtime
(`__sc_diag_install`): a `--- process <pid> <name>` header, then every thread's stack
(`backtrace`; threads found with `task_threads` on macOS and `/proc/self/task` on Linux), the
thread blocked in a syscall included; std's reactor then adds its state when the process started
it (state, queued commands, and per descriptor the read and write waiters, stale bits and last
event). A library chains its own dump the same way with `sc_rt_diag_chain` (`ffi/sc_runtime.spc`). A
process that is not a Super-C program (`cc`, `ld`, a shell) ignores SIGURG, its default action. On
Linux the runner adds the kernel's view of every process: each thread's state and wait channel.
Windows terminates the child with no dump.

### Global fixtures

```superc
@test_init(global)
fn global_setup() GlobalEnv {
    return GlobalEnv { db: connect() };
}

@test_free(global)
fn global_teardown(env: &mut GlobalEnv) {
    env.db.close();
}

@test
fn reads_data(fx: &mut Fx, env: &GlobalEnv) {
    // fx is per-test; env is shared read-only (fork's COW prevents cross-test mutation)
}
```

`@test_init(global)` builds a suite-wide environment **once** in the parent process.
Tests receive it as `&` (shared reference), and the per-test fixture parameter must
come **before** the global env (the compiler rejects the reverse order). Fork's
copy-on-write makes cross-test mutation impossible by construction.

## Method Suites

Tests can be grouped as methods on a type. The receiver **is** the fixture:

```superc
extend Counter {
    @test_init
    fn setup() Counter { return Counter { n: 0 }; }

    @test
    fn starts_at_zero(self: &Counter) { assert_eq(self.n, 0); }

    @test
    fn bump_increments(self: &mut Counter) { self.bump(); assert_eq(self.n, 1); }
}
```

Requirements:
- Non-generic inherent `extend` blocks only (conformance and generic extends are rejected)
- Display name: `module::Counter::starts_at_zero`
- A module may host several suites (one per type)
- A local extension of an imported type can define its own suite
- A method suite test may also take the global env as a second parameter

## Assert Builtins

| Builtin | Behavior |
|---------|----------|
| `assert(cond)` | Fails with source text and file:line |
| `assert(cond, "msg")` | Fails with message, source text, and file:line |
| `assert_eq(a, b)` | Fails with left/right values, source text, and file:line |
| `assert_ne(a, b)` | Fails when values are equal |

Arguments are only **read** (not moved): asserting on an owned `String` leaves it
usable. The source text of the expression is captured at compile time; a message spells at
most 1000 bytes of each expression and ends a longer one with `...`. The
`std/test.spc` bodies are fallbacks that `abort()`, so a constant-evaluated caller bails to
runtime instead of folding an assertion away.
