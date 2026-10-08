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

`@test_init` returns a fixture **value**, built fresh for each test that declares a
matching parameter. Constraints: the `@test_init` function takes no parameters and must
return a plain non-generic struct or enum; a suite `@test_init` (inside an `extend`) must
return the extended type itself. Fixtures are values because a `static mut` cannot hold a
`Free` type. A test that reads a process-lifetime counter (such as the runtime's cancel
count) records its baseline in a `@test_init` fixture (`Base` in `tests/cancel_test.spc`)
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
signal). The runner counts any nonzero exit as the panic, so under `SC_LEAK_CHECK=fatal` a
leak (exit 23) alone can make it pass. Run it once without that variable to confirm the
intended panic.

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
event). A library chains its own dump the same way with `sc_rt_diag_chain` (`ffi/sc_rt.h`). A
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

## Running Tests

Always run with `--quiet`: the failure replay and the tally carry all the signal, and
agents and CI logs stay readable. Drop it only when a PASSING test's output is needed
(pair with `--test-no-fork`, which is the only mode that shows it).

```sh
super-c test --quiet                   # the standard form: only the failures and the tally
super-c test --quiet --filter=parse    # substring match on test name
super-c test --quiet --test-shard=1/4  # one-based CI sharding, balanced by tests/durations.tsv
super-c test --quiet --test-record-durations  # refresh tests/durations.tsv from this run
super-c test --quiet --test-jobs=8     # bound the fork pool (default: one per CPU)
super-c test --quiet --test-timeout=120 # fail a test that runs past 120 s (default 90, 0: none)
super-c test --test-no-fork            # in-process (for debuggers; shows passing output)
```

### How the suite is built

`super-c test` first builds the compiler under test with the selected profile (`dev` by
default: `-O1` + ASan/UBSan) and exports it as `$SUPERC` for the CLI tests. The test
runner itself is a separate engine build of the generated test root under the built-in
`test` profile (`-O1`, no sanitizers): parallel per-TU compiles with the object cache and
emit stamp, linked to `build/test/__tests`, emitted C under `build/test/raw/`. An
unchanged suite skips straight to the cached link. `--filter=S` acts at build time too: the
generated root imports only the test files with a test whose name (`<module>::<fn>`, or
`<module>::<Type>::<fn>` for a suite method) contains S, after a parse-only scan of the
suite, and a filter no test matches is an error. The runner then runs only the matching
tests of those files. Override the runner's flags with a
`[profile.test]` section in `build.toml`. Run directly, the runner takes `--filter=S`,
`--shard=K/N`, `--jobs=N`, `--timeout=S`, `--weights=F`, `--record=F`, `--quiet` and `--no-fork` (not the driver's `--test-*` spellings)
and exits 2 on any other argument. Every compiler the CLI harnesses
(`tests/cli_harness.spc`, `tests/harness.spc`) run gets `SC_CACHE_DIR=<scratch dir>/.sccache`
unless the test sets its own (`cli::cache_env`), so a test never writes into the user's
global build cache. The fixture builds of `compile_and_run` (and `expect_exit`) instead share
the suite's object cache, `build/test/fixture-cache`, which `super-c test` names in
`SC_TEST_CACHE_DIR` (`cli::fixture_cache_env`): the runtime and std units every fixture emits
compile once per cache, not once per fixture.

### Fork isolation

Each test runs in a **forked child process**. A panic, failed assertion, or crash fails
only that test. The other tests continue. The parent collects exit status and reports.

`--test-no-fork` disables forking for debugger attachment. `should_panic` tests are
skipped in this mode.

Windows has no `fork`: the parent runs the global `@test_init`/`@test_free` pair once, and
each test runs in its own child process that rebuilds a private global env. CRT
differences that affect the runner and tests: `_dup2` returns 0 on success; `_spawnv`
joins its arguments with spaces and quotes nothing; `abort()` is fail-fast (exit code
0xC0000409) and flushes nothing, so atexit handlers and the leak report do not run;
`freopen` resets to full buffering and `_IOLBF` acts as `_IOFBF`, so a capture child sets
`_IONBF` on both streams. Diagnose a Windows-only failure on the real `windows-latest`
runner: edit the `windows` job in `.github/workflows/debug.yml`, which runs on dispatch only.
In both workflows, each platform builds its compiler once (`compile`, `windows-compile`,
`wasm-compile`: an artifact) and runs the two test shards in parallel on it; in the release
workflow (macOS, Linux and Windows in one matrix) the macOS and Linux correctness gates run beside
the shards and the release binary is built after all of them pass. The toolchain and bootstrap steps live in `.github/actions/`. An
emit-only probe does not help there: emission without `--test` drops `@test` bodies, so
instrument the test file and rebuild the suite.

### Output capture and the failure report

Each child's stdout and stderr go to a capture file owned by the runner. A passing
test's output is discarded. After the run, a `failures:` section replays each failed
test's output under a `---- name ----` header, followed by how the process ended
(the signal or exit code, or "did not panic as expected"), then lists the failed names
again. A test that aborts (a failed `assert`, a panic, a trap) also reports `last errno: N (message)`
when the aborting thread's `errno` is not zero, on every OS: the runner resets `errno` when the test
starts, so the code is one the test's own calls set, though maybe before the failing line. `--quiet` drops the per-test `ok` and `skipped` lines; the header, the `FAILED`
lines, the failure section, and the tally stay. `--test-no-fork` captures nothing, so
use it to see a passing test's output.

### Sharding for CI

`--test-shard=K/N` splits the test list into N shards and runs shard K. `super-c test` balances
the shards by the suite's recorded durations, `tests/durations.tsv` (one `<seconds>\t<name>` line
per test, sorted by name): the filter-matched tests, the longest first, each go to the shard with
the least time so far, ties to the lowest shard, and a test the file does not name counts as the
median recorded duration. Every shard computes the same assignment from the same file, test list
and filter, so the shards are disjoint and cover the list. Without the file (and in the script form
`super-c --test app.spc`) tests are dealt round-robin. `super-c test --test-record-durations` merges
the run's times into the file: a test that ran gets its new time, one that did not (another shard)
keeps its old one, and a name the suite no longer has is dropped. Refresh it with an unsharded run
after adding or removing slow tests; a stale file only makes the split less even.

## Leak Detection

Every compiled binary carries a built-in leak tracker, controlled by environment
variables:

```sh
SC_LEAK_CHECK=1 ./app           # report leaks at exit with their allocation site
SC_LEAK_CHECK=fatal ./app       # report + exit 23 on leaks (CI gate)
```

The tracker interposes `malloc`/`calloc`/`realloc`/`free` at the emitted-C level, and
tracks over-aligned blocks from `std/alloc.h` through `sc_lk_aligned_alloc` /
`sc_lk_aligned_free`. It:
- Reports every allocation that survives to exit
- Detects **double frees** with both allocation and free stacks (freed blocks stay allocated
  in a bounded history, so an address in it is always a real double free, never a reused block)
- Detects **use-after-free** on `realloc` of a freed pointer
- Works everywhere, including Apple Silicon (where LeakSanitizer does not exist)

### CI integration

The CI suite runs all tests under `SC_LEAK_CHECK=fatal`. Leak-freedom is enforced by
construction, not by audit.

```sh
SC_LEAK_CHECK=fatal super-c test --quiet
```

A test's verdict never depends on that variable: a test that checks leak behaviour sets
`SC_LEAK_CHECK` on the child it runs (`run_bin_env`, `compile_flags_env`, `compile_and_run_env`),
so an unarmed `super-c test --quiet` gives the same result as the gate.

The wasm lane runs the same suite with `SC_TEST_SUPERC=ci/wasm-superc.sh`: the wrapper runs
every transpile-class command (a script, `fmt`, `lint`, the transpile form an engine's
`--transpiler` runs) inside wasmtime and sends the commands that spawn processes (`build`,
`test`, `bindgen` and the rest) to the native binary. A CLI test that needs the working
directory of a guest command or runs a shell line returns early under `cli::on_wasm()`.

The guest has no stable working directory (wasmtime ignores the test's `chdir`) and no
subprocesses, so guest command lines use absolute paths. The wrapper passes
`--argv0` with the module's absolute path, and the compiler finds `std/` and `ffi/` beside
argv0: the module must sit beside them (the repo root by default, else `SC_WASM_MODULE`),
or every compile fails with "cannot find type 'str'". The wrapper forwards every `SC_*`
variable into the guest except its own plumbing (`SC_WASM_MODULE`, `SC_WASM_NATIVE`,
`SC_TEST_SUPERC`); a new plumbing variable for the wrapper must join that exclusion. Run
one test locally with `SC_TEST_SUPERC=$PWD/ci/wasm-superc.sh ./super-c test --quiet
--filter=NAME`. To find a wasm-only miscompile, bisect at object level: compile every
TU with both toolchains, link mixed sets, and binary-search the TU set.
`-fsanitize=undefined -fsanitize-trap=undefined` needs no runtime on wasm, and
`WASMTIME_BACKTRACE_DETAILS=1` gives file and line in traps. A single-flag fix
(`-fwrapv`, `-fno-strict-aliasing`) that makes a failure go away is usually a heap-layout
change; do not trust it.

## Lint-Based Leak Detection

```sh
super-c lint                    # statically detect missing frees (error-level by default)
```

The `missing-free` lint is an error. It flags only a non-generic union with an owning
field (pointer, reference and bare type-parameter fields excepted) and no `Free`
conformance: structs and enums derive `Free`, but a union cannot, since only its author
knows the active member (`tc_lint_missing_free` in `src/typechecker/typechecker.spc`). It
does not track owning values in general; the runtime leak tracker covers those. A test
that leaks on purpose uses `forget(..)`.

A lint test that imports a sibling fixture file must run the lint from the fixture root
(`cli::superc_env_in(root, ..)`, as `lint_reports_cross_module_duplicate_conformance` in
`tests/lint_test.spc` does); otherwise use a prelude-loaded ffi module such as `stdio`.

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
| `expect_same_output(label, src, opts_a, opts_b)` | Build `src` with each option list, run both, require equal exit code, stdout and trap text |
| `expect_const_runtime_parity(label, decls, expr, ty)` | Require `expr` to give the same value or trap as a `const` and at run time |
| `expect_run(label, src, arg, msg)` | Build `src` (dev profile), run it with `arg`; require exit 0, or a trap whose stderr holds `msg`, and no sanitizer report either way |
| `expect_build_err(label, src, needle)` | Require the build to fail with `needle`, before any C compile and with no internal error |
| `expect_asm(label, src, opts, function, contains, absent)` | Check instruction names in the assembly of C function `function` (an `absent` entry `=name` matches that mnemonic exactly: `=bl` is a call, not `tbl`) |

These are backed by `loader::package_from_source`, which applies `@platform`/`@arch`
filtering for the host like a real build, except the three differential oracles, which build
through the compiler under test (below).

### Differential oracles

`tests/harness.spc` builds each program as `main.spc` of a scratch manifest project
(`diff_build`, `diff_run`). An option is a build flag (`--profile=release`, `--target=wasm`,
`--cc=cc -target x86_64-apple-macos11`, one argument even with spaces) or, as `NAME=VALUE`, an
environment variable of the build (`SC_BCE=0` keeps every bounds check). The project defines
`--profile=ubsan`, unoptimized with UndefinedBehaviorSanitizer only, for a large program run many
times: it compiles in about half the dev profile's time, and ASan's start-up makes each run several
times slower. On the wasm lane each build
passes `--transpiler=$SUPERC`, so the transpile step and its constant evaluation run in the wasm
compiler under wasmtime; the C compile and the program stay native.

- `same_output(src, opts_a, opts_b, runs)` runs both builds once per entry of `runs` (the
  command-line arguments of one run) and returns the first difference, empty when none. The trap
  text is the stderr lines starting `super-c: ` (runtime helpers) or `panic: ` (std); a sanitizer
  report on either side or a build failure is a difference.
- `const_runtime_parity(decls, exprs, tys, opts)` puts every case in one program: `const
  PARITY_C<k>` and `fn parity_r<k>`, selected by `prog <k>`. Write inputs as `opq::<T>(v)`: the
  constant calls the identity `const fn opq`; the run-time copy calls `opr`, a `@c.noinline`
  identity that writes a static, so the compiler cannot fold it (a call of a plain or `const fn`
  identity with constant arguments is folded, and a certain trap becomes the compile error "this
  statement is undefined behavior when executed"). A trapping constant is a compile error; the
  helper maps it to its case by line, drops it, rebuilds, and requires the run time to trap with a
  message of the same class (`const_trap_class`, `runtime_trap_class`: "arithmetic overflow" for
  `attempt to add/subtract/multiply/negate/divide with overflow` and the remainder form, "division
  by zero" for `attempt to divide by zero` and `... a divisor of zero`, "shift out of range" for
  `attempt to shift left/right with overflow`, "index out of bounds" for any message holding
  it; a vector lane trap keeps its text from `lane <digit>`, so the lane must match too). Floats
  compare by bits, any NaN as `nan`. It runs
  under `dev` (overflow checks on); `decls` must not trap. `parity_program` prints the program.
- `asm_check(src, opts, function, contains, absent)` builds, reads
  `build/<profile>/compile_commands.json`, finds the unit that defines `function`, reruns its
  command with `-S` (without `-c`, `-MMD` and `-flto*`, which would print IR), and matches
  substrings of instruction mnemonics only (`asm_mnemonics`: the first word of each body line,
  without labels, directives and comments; Mach-O `_name:` labels too), so `x0` or `rax` never
  match. x86_64 and aarch64 work on the host and, on macOS, for the other architecture through
  `--arch=` plus `--cc=cc -target <triple>`; wasm32 needs `--target=wasm` and `WASI_SDK_PATH`,
  which the wasm lane sets (`asm_wasm32` in `tests/differential_test.spc` returns early without it).

### The vector conformance lane

`SC_SIMD_LANE=wasm` (a wasi-sdk in `WASI_SDK_PATH`, wasmtime on the PATH; `h::simd_lane()`) makes
every differential build of a test a wasm32 build with `--target-feature=+simd128`, run under
`wasmtime run -W relaxed-simd-deterministic=y`; `expect_run` also builds without the feature and
requires the same output. The lane's `ubsan` profile is `opt-level = 1` without sanitizers (wasm32
has no UBSan runtime, and an unoptimized large function can pass the engine's limit of locals). A
host instruction check returns early in the lane. The masked-memory tests run there too: the
guard page is the end of linear memory (`sbrk`), the trap-before-write check reads the C order
(WASI has no signal handler), and the disjoint stores run one half after the other (no
threads). The release workflow's wasm job runs
`SC_SIMD_LANE=wasm SC_LEAK_CHECK=fatal ./super-c test --quiet --test-timeout=900 --filter=simd_`,
then the same with `--filter=gen_vector_seeds`.

On an aarch64 host every build calls the Neon entries (`neon` is the baseline), so without the
lane `expect_run` builds again with `SC_SIMD_SCALAR=1` and requires the same output, the entry
model runs over `std/simd/backend/aarch64.spc`, and the `ubsan` profile is `opt-level = 1` with
UBSan (an entry must survive the C compiler's folds). `SC_SIMD_FEATURES=+dotprod,+i8mm,+rdm`
adds features to every differential build: the conformance run on Linux aarch64 (the `gcc:13`
arm64 Docker image, the compiler bootstrapped from its emitted C) uses the default set and that
one. An entry whose key another entry holds with other features is called in one of the two
sets only (`dot` with and without `dotprod`): the model accepts it uncalled when its sibling is
called.

- `tests/simd_entry_test.spc` (the entry model, `tests/gen/simd_entry.spc`): every `@simd_impl`
  entry of `std/simd/backend/wasm.spc` (in the lane) or `aarch64.spc` (on an aarch64 host), through four vector model cases of each operation that
  reaches it at its lane count and at the most lanes (a `less_than` entry also through `count` and a
  `choose` of narrower lanes), and a choice, compress, expand or masked access over at most four
  lanes under every mask, built planned and with `SC_SIMD_SCALAR=1`; each case's value or
  trap must be equal, and the C of the first build must call every entry. Loads, stores and the `any`/`all`
  forms go through one extra program. Elsewhere the tests return at once.
- `tests/simd_wasm_test.spc`: the C of a program without vectors is byte-identical with and without
  the features; `expect_asm` checks that kernels use their SIMD128 instructions (`f32x4.add`,
  `i8x16.eq`, `v128.bitselect`, `i8x16.bitmask`, `v128.any_true`, `v128.load32_lane`) with no
  `call`, that a constant shuffle is `i8x16.shuffle` (no swizzle, no lane loads), that a
comparison feeding `choose`, `any` or `all` uses no `bitmask`, and that a
  checked `+` or shift keeps no lane loop (`--profile=test`; needs `WASI_SDK_PATH`); the
  `std::simd::wasm` operations against a scalar model over NaNs, both zeros and out-of-range
  lanes, and split loads and stores through overlapping pointers (in the lane).

### The program generator

`tests/gen/` generates small seeded programs. `driver.spc` holds `Rng` (splitmix64), the `Model`
interface (`name`, `generate`, `oracles`, `check(k)`, `render(k)`, `candidates`, `reduce(i)`) and
`run_seed`: generate, run each oracle, and on a failure reduce the program by delta steps (take the
first candidate that still fails the same oracle and still builds, at most `REDUCE_CHECKS_MAX` oracle
runs), then report the model, seed, failure, reduced program and a replay line. A new model is a
`Clone` struct conforming to `Model`, called through `run_seed`; the driver does not change.

- `scalar.spc`: integer and float expressions over every builtin width with boundary-biased inputs,
  shift counts from -1 to the width + 1, and casts. Oracle 0 is `const_runtime_parity`; oracle 1
  compares `dev` and `release` on a program that evaluates the plain operators under `release` and
  the `wrapping_*` methods otherwise (`if PROFILE == "release"`), so both follow their profile's
  overflow rule and must agree. Inputs are typed by the turbofish (`opq::<f64>(0.1)`), never by a
  float suffix or a hex float: a constant that uses one does not fold ("the initializer does not
  fold to a constant"). isize/usize literals stay in the 32-bit range.
- `loops.spc`: loops with affine and strided indexes, guards and sub-slices over a Vector and a
  slice of it; one oracle, `same_output` with BCE on against `SC_BCE=0`.
- `vector.spc`: one lane operation of `std/simd.spc` per case (`VOPS` and the rearrangements) over
  every lane type and 2, 4 or the most lanes, boundary-biased inputs (a float lane as its bits, so
  signaling NaNs reach every side), and half the cases with small values so arithmetic seldom
  traps. One oracle in one program (`check_cases`): each case as a constant against its run time
  (the value, or the constant's error detail equal to the run-time trap, lane included), and the run
  time against a scalar lane loop (`rk<k>`; a trap must have the same text without its lane). A run
  executes every case from a start and prints to stderr, so a trap costs one more run from the next
  case, not a process per case; the program is built with `--profile=ubsan`, and a trap exits with
  status 134 through a SIGABRT handler, as a crash report or core dump costs more than the run.
  `tests/simd_ops_test.spc` sweeps every operation, lane type, lane count and conversion target
  through the same functions, in programs of at most 256 cases.

`tests/gen_test.spc` runs seeds 1 to 3 of each model in the normal suite and the planted defect
(`-DSC_ARITH_WRAP` through `--cstd` under `dev`: the runtime wraps, the constant traps), which the
scalar model must find at seed 7 and reduce to one case. The long run is `super-c command gen`
(200 seeds from the clock); replay or extend with
`SC_GEN_SEED=<seed> SC_GEN_RUNS=<n> [SC_GEN_MODEL=scalar|loops|vector] ./super-c test --quiet
--filter=gen_random_run`, which does nothing without `SC_GEN_RUNS`. Each seed builds four
programs (scalar), two (loops) or one or two (vector: a rebuild without the trapping constants).

## Test Design Rules

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
  Put the report in a `defer` at the top of the body; `tests/cancel_test.spc` and the
  cancellation benchmark lanes follow this rule.
- **A concurrency test never depends on the scheduler's order.** It asserts only what
  holds for every legal interleaving, and it waits for the STATE it needs, never for a
  duration that usually suffices. `time::sleep(short())` before a cancel, a fixed hold
  while callers are meant to queue, a latency bound on a wake, or an assertion right
  after a signal: each passed for months on an idle machine and then failed on a loaded
  runner, where a preemption landed inside the window. A test's sleep is legitimate
  only as a cancellation point inside a task, as a widening of the window for a DEFECT
  to show in a negative test, or as a bounded poll interval.
- **Wait on state through `tests/parallel_harness.spc`** (`import tests::parallel_harness
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
  `tests/blocking_test.spc`, `hold_until` in `tests/mutex_test.spc`), and the test
  opens it once the queueing it wanted is a fact. A hold measured in milliseconds loses
  to a slow launch.
- **A signal lands before the signaller's cleanup.** A `defer w.done()` fires before
  the task's locals drop, a holder that signals in its last statement still owns its
  guard, and a blocking-pool caller is woken before the thread that ran its call counts
  itself out. Drop the guard in an inner block before signalling, and a waiter that
  asserts on a destruction count or on pool statistics polls for that state with a bound
  (`wait_frees`, `wait_quiet` in `tests/blocking_test.spc`) instead of asserting right
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
  `tests/cli_test.spc` gives the blocking calls a C wait that returns only once another
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
  fails the `n`th allocation of the C substrate in construction order (`tests/thread_test.spc`
  comments name each one). Edit one call by its unique context; a search-and-replace on
  `FAIL_ALLOC, n` changes every test with that `n`.
- **Allocation-count tests divide over many runs** (64). Under `SC_LEAK_CHECK` the tracker
  itself allocates irregularly for the first few measurements of a shape, and a warm-up
  alone does not fix that.
- **Unset, do not empty.** `sc_unsetenv` removes a variable; a variable set to `""` still
  passes a `getenv(..) != NULL` check. On Windows `sc_unsetenv` is `_putenv_s(name, "")`,
  which removes it.
- **No shell on Windows.** `sc_run` and `sc_exec` call `CreateProcessA` directly. A harness
  command line never uses `cd X && K=V cmd`: pass the variable through `sc_run`'s env
  parameter and change directory with `shim::sc_chdir` (`cli::superc_env_in`), resolving
  `cli::superc_path()` before the change. A test that runs a shell line returns early under
  `if cli::on_wasm() || cli::on_windows() { return; }`.
- **No parallel `system()`.** macOS `system()` serializes across threads; `popen` or a
  spawn scales (about seven times). Run parallel subprocess work through those.
- **Pin our own rules, not libc's.** C leaves the zero sign of `fmin`/`fmax` unspecified
  (glibc returns the second operand for `(+0, -0)`), so a differential test asserts our
  sign rule on both-zero pairs (`tests/float_test.spc`).
- **Drive the driver through subprocess tests.** Prune and macro-paste defects that do
  not change emitted C pass the self-hosting fixpoint; only a test that runs the built
  driver catches them.
