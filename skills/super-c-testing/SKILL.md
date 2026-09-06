---
name: super-c-testing
description: "Covers writing and running tests in Super-C: the @test/@test_init/@test_free lifecycle, fixtures, method suites, should_panic, fork isolation, sharding, assert builtins, SC_LEAK_CHECK as a CI gate, and the self-host test corpus. Use when writing tests, debugging test failures, or setting up CI for a Super-C project."
allowed-tools: Bash Read
---

# Super-C Testing

## Agent checklist

- Read the test lifecycle rules before changing fixtures or test attributes.
- Always pass `--quiet` when running tests: only the failures (with their replayed
  output) and the tally matter, and the per-test `ok` lines drown them out.
- Use the narrowest relevant test command and preserve fork isolation.
- Keep leak checking enabled when validating ownership behavior.
- Report stale test documentation after harness or fixture changes.

Super-C has a built-in test framework. Tests are declared with attributes, discovered
automatically, and run in forked child processes for isolation.

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

`@test_init` returns a fixture **value** — built fresh for each test that declares a
matching parameter. Constraints: the `@test_init` function takes no parameters and must
return a plain non-generic struct or enum; a suite `@test_init` (inside an `extend`) must
return the extended type itself.

### Teardown with `@test_free`

```superc
@test_free
fn teardown(fx: &mut Fx) {
    // clean up out-of-band effects (temp files, connections)
}
```

Optional. Runs after the test body. The fixture's owned memory is RAII-freed
automatically after `@test_free` — you only need `@test_free` for effects RAII does not
cover.

### Expected panics

```superc
@test(should_panic)
fn rejects_bad_input() {
    panic("boom");
}
```

Passes only when the body aborts. Skipped under `--test-no-fork` (no fork to catch the
signal).

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
Tests receive it as `&` (shared reference) — and the per-test fixture parameter must
come **before** the global env (the compiler rejects the reverse order). Fork's
copy-on-write makes cross-test mutation impossible by construction.

## Method Suites

Tests can be grouped as methods on a type — the receiver **is** the fixture:

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

Arguments are only **read** (not moved) — asserting on an owned `String` leaves it
usable. The source text of the expression is captured at compile time.

## Running Tests

Always run with `--quiet`: the failure replay and the tally carry all the signal, and
agents and CI logs stay readable. Drop it only when a PASSING test's output is needed
(pair with `--test-no-fork`, which is the only mode that shows it).

```sh
super-c test --quiet                   # the standard form: only the failures and the tally
super-c test --quiet --test-filter=parse  # substring match on test name
super-c test --quiet --test-shard=1/4  # stable one-based CI sharding
super-c test --quiet --test-jobs=8     # bound the fork pool (default: one per CPU)
super-c test --test-no-fork            # in-process (for debuggers; shows passing output)
```

### How the suite is built

`super-c test` first builds the compiler under test with the selected profile (`dev` by
default: `-O1` + ASan/UBSan) and exports it as `$SUPERC` for the CLI tests. The test
runner itself is a separate engine build of the generated test root under the built-in
`test` profile (`-O1`, no sanitizers): parallel per-TU compiles with the object cache and
emit stamp, linked to `build/test/__tests`, emitted C under `build/raw-test/`. An
unchanged suite skips straight to the cached link. Override the runner's flags with a
`[profile.test]` section in `build.toml`.

### Fork isolation

Each test runs in a **forked child process**. A panic, failed assertion, or crash fails
only that test — the other tests continue. The parent collects exit status and reports.

`--test-no-fork` disables forking for debugger attachment. `should_panic` tests are
skipped in this mode.

### Output capture and the failure report

Each child's stdout and stderr go to a capture file owned by the runner. A passing
test's output is discarded. After the run, a `failures:` section replays each failed
test's output under a `---- name ----` header, followed by how the process ended
(the signal or exit code, or "did not panic as expected"), then lists the failed names
again. `--quiet` drops the per-test `ok` and `skipped` lines; the header, the `FAILED`
lines, the failure section, and the tally stay. `--test-no-fork` captures nothing, so
use it to see a passing test's output.

### Sharding for CI

`--test-shard=K/N` splits the test list into N stable shards and runs shard K. Shard
assignment is deterministic — the same shard always runs the same tests, regardless of
test ordering.

## Leak Detection

Every compiled binary carries a built-in leak tracker, controlled by environment
variables:

```sh
SC_LEAK_CHECK=1 ./app           # report leaks at exit with call stacks
SC_LEAK_CHECK=fatal ./app       # report + exit 23 on leaks (CI gate)
```

The tracker interposes `malloc`/`calloc`/`realloc`/`free` at the emitted-C level. It:
- Reports every allocation that survives to exit
- Detects **double frees** with both allocation and free stacks
- Detects **use-after-free** on `realloc` of a freed pointer
- Works everywhere, including Apple Silicon (where LeakSanitizer does not exist)

### CI integration

The CI suite runs all tests under `SC_LEAK_CHECK=fatal`. Leak-freedom is enforced by
construction, not by audit.

```sh
SC_LEAK_CHECK=fatal super-c test --quiet
```

## Lint-Based Leak Detection

```sh
super-c lint                    # statically detect missing frees (error-level by default)
```

The `missing-free` lint fires at compile time for owning values that escape without being
freed. Combined with the runtime leak tracker, this provides two independent paths to
leak-freedom.

## The Compiler's Own Test Corpus

The compiler's tests live in `tests/` at the repo root. Count test files with
`find tests -name '*_test.spc' -type f | wc -l` and test functions with
`rg -n '^\s*@test' tests`. An in-process harness (`tests/harness.spc`) provides test helpers:

| Helper | Purpose |
|--------|---------|
| `compile(src, stop)` | Compile source string up to the given stop stage |
| `compile_ast(src, stop)` | Parse + resolve up to the stop stage, return AST |
| `parse_ast(src)` | Parse only, return AST |
| `parse_ast_for_fmt(src)` | Parse with trivia for formatter tests |
| `compile_c(src)` | Compile to C through the production backend; the returned text is every TU's part heads, buffer and tail plus the shared headers and instance TU, so a needle search sees every byte |
| `compile_and_run(src)` | Compile, link, execute, return exit code |
| `compile_and_run_env(src, env)` | Same, with environment variables set |

These are backed by `loader::package_from_source`.

## Test Design Rules

- **One assertion per concept.** Split independent checks into separate `assert` calls —
  a combined boolean hides which condition failed.
- **No global mutable state.** The fork model means tests run in separate processes.
  Shared state must go through the global fixture mechanism.
- **Test the contract, not the implementation.** Assert on observable behavior (return
  values, side effects, error messages), not on internal data structure shapes.
- **Fixture values, not fixture effects.** `@test_init` returns a value. Side effects
  that need cleanup go in `@test_free`.
