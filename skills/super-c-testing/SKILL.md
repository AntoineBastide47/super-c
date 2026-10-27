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

`super-c test` imports every `.spc` file under `tests/`, subdirectories included; a file's path is its
module path, so `tests/simd/simd_x86_test.spc` holds the tests `tests::simd::simd_x86_test::*`. The suite
groups its files by area: `frontend/` (lexer to type checker), `borrowck/`, `ir/`, `codegen/`, `simd/`,
`math/`, `stdlib/`, `concurrency/`, `platform/`, `cli/`, `lsp/`, `tooling/` (fmt, lint, doc IR, the C
preprocessor) and `gen/` (the program generators and their test). The shared helpers stay at the top
(`tests/harness.spc`, `tests/cli_harness.spc`); an area's own helper lives in its folder
(`tests/concurrency/parallel_harness.spc`, `tests/platform/platform_harness.spc`). A file keeps its area
prefix (`simd_`, `math_`, `cli_`, `lsp_`, `platform_`) so a `--filter` on it still selects the area.

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

## Running Tests

Always run with `--quiet`: the failure replay and the tally carry all the signal, and
agents and CI logs stay readable. Drop it only when a PASSING test's output is needed
(pair with `--test-no-fork`, which is the only mode that shows it).

```sh
super-c test --quiet                   # the standard form: only the failures and the tally
super-c test --quiet --filter=parse    # substring match on test name
super-c test --quiet --test-shard=1/4  # one-based CI sharding, balanced by tests/durations.tsv
super-c test --quiet --test-record-durations  # refresh tests/durations.tsv from this run
super-c test --test-shard=1/2 --test-durations=tests/durations/<lane>.tsv --test-record-durations=s1.tsv  # CI lane: its weights, this shard's times alone
super-c test --quiet --test-jobs=8     # bound the fork pool (default: one per CPU)
super-c test --quiet --test-timeout=120 # fail a test that runs past 120 s (default 90, 0: none)
super-c test --test-no-fork            # in-process (for debuggers; shows passing output)
```

### How the suite is built

`super-c test` first builds the compiler under test with the `test` profile (`opt-level` 1) into
`<out-dir>/test-bin`, or with `--profile=P` into `<out-dir>/P`. It exports it as `$SUPERC` for the
CLI tests; when the project
holds `std/core.spc` and `SC_STD_DIR` is unset, it also sets `SC_STD_DIR` to the project's
`std/`, because `--out-dir` may place that compiler away from the tree it must load. The test
runner itself is a separate engine build of the generated test root under the built-in
`test` profile (`opt-level` 1): the per-TU cache, the native record and the emit stamp, linked to
`build/test/__tests`, its objects under `build/test/raw/`. An unchanged suite skips straight to the
link check. `--filter=S` acts at build time too: the
generated root imports only the test files with a test whose name (`<module>::<fn>`, or
`<module>::<Type>::<fn>` for a suite method) contains S, after a parse-only scan of the
suite, and a filter no test matches is an error. The runner then runs only the matching
tests of those files. Override the runner's flags with a
`[profile.test]` section in `build.toml`. The runner is Super-C (`std/rt/test.spc`, which the loader adds
to test builds); the generated test entry (`__test_main.o`, from LIR text) holds only the test table and
the `main` that passes it to `sc_test_main`. Run directly, the runner takes `--filter=S`,
`--shard=K/N`, `--jobs=N`, `--timeout=S`, `--weights=F`, `--record=F`, `--quiet` and `--no-fork` (not the driver's `--test-*` spellings)
and exits 2 on any other argument. A runner started without an inherited `SC_JOBSERVER` makes its own
of `--jobs` slots, as `super-c test` does, so its tests and the compilers they start share one budget. Every compiler the CLI harnesses
(`tests/cli_harness.spc`, `tests/harness.spc`) run shares one cache base: `super-c test` exports
`SC_TEST_CACHE_DIR` (kept across runs; CI sets `~/.super-c/cache/.tests`, inside the cache it saves),
else `<out-dir>/test/cache`, as `SC_CACHE_DIR`, so a unit an earlier build compiled is not compiled
again; the second it deletes when the run ends (and at its start, what an interrupted run left). The
runner itself builds in the project's own cache root. A fixture project takes a fixed name (`app`,
`initapp`), so a kept base holds one root per name, not one per run. A test that checks cache behavior sets its
own `SC_CACHE_DIR` under its scratch directory, and so does every test that runs `clean --full`,
which removes the project's cache root.

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
`wasm-compile`: an artifact) and runs its test shards in parallel on it (three on Windows, the
slowest runner, two elsewhere). The build has two stages: the latest release builds stage 1, and
stage 1 builds the tested compiler at the default profile, both natively; `wasm-compile` builds
`super-c.wasm` the same way (the native wasm backend), and `wasm-package` ships a release build of
it, as `package` ships a release build of the native binary. The Linux arm64 compiler (target
`linux_arm64` in the release matrices, `linux-arm64-compile` in the debug workflow) is cross-built
natively on the x86-64 runner by the x86-64 one against the arm64 C library
(`libc6-dev-arm64-cross`: headers and libraries, no compiler); the arm64 runner (`ubuntu-26.04-arm`)
runs its test shards, gate and package, which rebuild the compiler there. No transpile count runs
for it: no earlier release has a Linux arm64 compiler to count against.
In the release workflow (macOS, Linux, Linux arm64 and Windows in one matrix)
the correctness gate (`ci/gate.sh --core`), the x86-64 levels and the `compare` job (Linux, clang 22:
the tests that compile C, the C environment tables, the strict C warnings) run beside the shards, and the release binary is
built after all of them pass. Only the release workflow on main saves caches (the toolchain action's
`save: true`), so no other workflow or branch evicts its entries. Each platform keeps one object
cache, `objcache-<target>-<sha>` (the cache base `~/.super-c/cache`, the tests' `.tests` included):
the compile, test and package jobs upload the files they added or changed and the list of those they
deleted (`.github/actions/cache-save/delta.py`), and the `caches` job merges them over the platform's
newest cache at the end of the run. Gate, counts, compare and the wasm checks save only their
own delta (`objdelta-<target>-<role>-<sha>`), which the toolchain action restores over the platform
cache. The installation caches are restored every run, so GitHub's eviction past its limit takes the
superseded caches of older commits first. The toolchain and bootstrap steps live in `.github/actions/`. An
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
`super-c --test app.spc`) tests are dealt round-robin. The script form's `--test-record-durations`
needs `=F` or `--test-durations=F`: a script has no suite folder for a default file. `super-c test --test-record-durations` merges
the run's times into the file: a test that ran gets its new time, one that did not (another shard)
keeps its old one, and a name the suite no longer has is dropped. A filtered run builds only the
files with a match, so it keeps every line it has no test for (a removed test's line stays until an
unfiltered run). Refresh it after adding or removing slow tests (`--filter` for the new ones); a stale
file only makes the split less even.

`--test-durations=F` names the weights file instead (and the file a plain `--test-record-durations`
writes); `--test-record-durations=F` merges the run's times into F instead, so a shard recording into
a fresh F lists only the tests it ran. CI runners are several times slower than a laptop, and not
uniformly, so each CI lane splits by its own file, `tests/durations/<lane>.tsv` (`macos`, `linux`,
`windows`, `wasm`). The files are not committed: they are the repository's one `test-durations`
artifact, which every Release and Debug shard downloads first (`.github/actions/test-durations`; a
lane without one uses `tests/durations.tsv`). Every Release run refreshes it: each shard records
the times of the tests it ran (`--test-record-durations=<file>`), and the `durations` job
(`.github/actions/test-durations-save`) merges each lane's shards (a lane no shard measured keeps
its old file), replaces the artifact, deletes every other durations artifact, and summarizes the
measured and planned shard times. The `Test durations` workflow
(`.github/workflows/test-durations.yml`) runs the same shards and job on demand, without a release.

## Leak Detection

Every compiled binary carries a built-in leak tracker, controlled by environment
variables:

```sh
SC_LEAK_CHECK=1 ./app           # report leaks at exit with their allocation site
SC_LEAK_CHECK=fatal ./app       # report + exit 23 on leaks (CI gate)
```

The tracker is part of the runtime every program links (`std/rt/base.spc`). The emitter spells
every extern C `malloc`/`calloc`/`realloc`/`free` call (std's, ffi's or the program's own binding) as
the tracker's `sc_lk_*` entry (`Mangler::tracked_alloc`), and std's `Global` allocator calls
`sc_lk_aligned_alloc` / `sc_lk_aligned_free` for over-aligned blocks. It:
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

Every process a harness helper starts (`cli::run_with`, under each run, build and compile helper)
gets `SC_LEAK_CHECK=fatal` unless the test sets `SC_LEAK_CHECK` on it itself (`run_bin_env`,
`compile_flags_env`, `compile_and_run_env`), so a leak in a program or compiler a test runs fails
the test with or without the gate. Only a leak in the test process itself needs the gate.

The platform layer's tests (`tests/platform/platform_*_test.spc`, helper `tests/platform/platform_harness.spc`) run each
`std::platform` module on the host; `platform_wasi_test` builds one program with `--target=wasm`, runs it under
wasmtime and checks every WASI `Unsupported` path, and returns early without `WASI_SDK_PATH`. Windows-only paths
compile there and run on the Windows runner. `tests/cli/std_packages_test.spc` builds `tools/std_packages` and runs
it on fixture trees (an upward import, a forbidden `extern "C"` function, a cross-package cycle, the text of a
matchertext literal). `tests/codegen/wasm_libc_test.spc` checks wasm's C library against the one it replaces: a program
on `std::rt::libc` and `std::rt::libm` and the same program in C on wasi-libc (the wasi-sdk's clang) print the
same 27,100 lines under wasmtime (the bits of every math function at 300 arguments, printf, strtod, strtol,
qsort), and the program's name section holds no wasi-libc function; a second pair prints the same 873 lines
(the scanf family over strings, files and stdin, setlocale with UTF-8, the time functions, signals, `sbrk`
beside malloc, creat, setvbuf, environ, pthread_self and pthread_exit). Both return early without
`WASI_SDK_PATH`. `every_c_symbol_a_wasm_build_binds_is_defined` needs no SDK: every C function and static
that ffi, std and src bind for wasm (`tools/std_packages/scan.spc` reads the gates) is defined by the C
library, the runtime or the intrinsics header, or is on its list of functions WASI has no call for. The
local `check.sh` does not run the `SC_SIMD_LANE=wasm` lane; a change to wasm linking needs it run
(the `wasm checks` job's commands).

The wasm lane runs the same suite with `SC_TEST_SUPERC=ci/wasm-superc.sh`: the wrapper runs
every transpile-class command (a script, `fmt`, `lint`, the transpile form an engine's
`--transpiler` runs) inside wasmtime and sends the commands that spawn processes (`build`,
`test`, `bindgen` and the rest) to the native binary. A CLI test that needs the working
directory of a guest command or runs a shell line returns early under `cli::on_wasm()`.

The guest has no stable working directory (wasmtime ignores the test's `chdir`) and no
subprocesses, so guest command lines use absolute paths. The wrapper passes
`--argv0` with the module's absolute path, and the compiler finds `std/` and `ffi/` beside
argv0, or where the forwarded `SC_STD_DIR` names `std/`: the module must sit beside them (the
repo root by default, else `SC_WASM_MODULE`) when that variable is unset, or every compile fails
with "cannot find type 'str'". The wrapper forwards every `SC_*`
variable into the guest except its own plumbing (`SC_WASM_MODULE`, `SC_WASM_NATIVE`,
`SC_TEST_SUPERC`); a new plumbing variable for the wrapper must join that exclusion. Run
one test locally with `SC_TEST_SUPERC=$PWD/ci/wasm-superc.sh ./super-c test --quiet
--filter=NAME`. To find a wasm-only miscompile, bisect at object level: compile every
TU with both toolchains, link mixed sets, and binary-search the TU set.
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
`tests/tooling/lint_test.spc` does); otherwise use a prelude-loaded ffi module such as `stdio`.

## The Compiler's Own Test Corpus

The compiler's tests live in `tests/` at the repo root. Count test files with
`find tests -name '*_test.spc' -type f | wc -l` and test functions with
`rg -n '^\s*@test' tests`. An in-process harness (`tests/harness.spc`) provides test helpers:

| Helper | Purpose |
|--------|---------|
| `compile(src, stop)` | Compile source string up to the given stop stage (`STAGE_TYPECHECK` includes the borrow check; a failure only the borrow check reports has stage `STAGE_BORROWCK`) |
| `compile_ast(src, stop)` | Parse + resolve up to the stop stage, return AST |
| `parse_ast(src)` | Parse only, return AST |
| `parse_ast_for_fmt(src)` | Parse with trivia for formatter tests |
| `compile_c(src)` | Compile to C through the production backend; the returned text is the shared headers, the snippet's own TU (part heads, buffer and tail) and the instance TU, without the prelude's TUs, so a needle cannot match a prelude function body |
| `compile_c_user(src)` | `compile_c` with the snippet's own TU only |
| `c_fn(code, def)` | The text of the C function whose definition opens with `def` (pass the full signature and ` {\n`: a prototype also starts with the signature), to its closing brace |
| `compile_c_arch(src, arch)` | `compile_c` for instruction set `arch` (0 x86_64, 1 aarch64) with its baseline, on any host |
| `compile_and_run(src)` | Compile, link, execute, return exit code |
| `compile_and_run_env(src, env)` | Same, with environment variables set |
| `expect_trap(label, src, msg)` | Build and run `src`; require a failing exit and `msg` in its stdout and stderr |
| `ExitBatch` (`new`, `add(label, src, code)`, `add_trap(label, src, msg)`, `run`) | Exit-code and trap cases built as one program: each case becomes module `c<k>` with its `fn main()` or `fn main(NAME: Vector<str>)` renamed `case_main` and public, the program builds once and runs once per case (`prog <k>`); a `main` that takes the arguments gets them without `<k>`, as a run of its own program does. A case with another `main`, and every case of a batch that does not build, builds alone through `expect_exit` or `expect_trap`. A case module's items take its module prefix in C (`c3__Node`): a case about a root module's bare C names builds alone. A test file turns its exit-code tests into provider functions `fn name(b: &mut h::ExitBatch)` that tests `exit_cases_NN` run in groups of about 20 cases |
| `expect_same_output(label, src, opts_a, opts_b)` | Build `src` with each option list, run both, require equal exit code, stdout and trap text |
| `expect_run(label, src, arg, msg)` | Build `src` (debug profile), run it with `arg`; require exit 0, or a trap whose stderr holds `msg` |
| `expect_runs(label, src, args, msgs)` | `expect_run` for each argument `args[i]` with message `msgs[i]`, from one build per option set |
| `expect_build_err(label, src, needle)` | Require the build to fail with `needle`, before any C compile and with no internal error |
| `expect_asm(label, src, opts, function, contains, absent)` | Check instruction names in the assembly of C function `function` (a `contains` entry `a|b` is met by either, for equivalent instructions C compilers pick between (`uminv|umaxv`); an `absent` entry `=name` matches that mnemonic exactly: `=bl` is a call, not `tbl`; `%reg` matches an operand in AT&T syntax: `%ymm`) |

A program with `main` emits only the functions it reaches, and a function the inliner splices at
every call has no definition. A test that inspects a function's C keeps it emitted: `@noinline` on
it, `@used` on one `main` does not call, or a use as a function value when an attribute on the
definition line would change the checked text.

These are backed by `loader::package_from_source`, which applies `@platform`/`@arch`
filtering for the host and loads the vector backend for a snippet that names a vector, like a
real build, except the three differential oracles, which build
through the compiler under test (below).

`tests/codegen/ctarget_test.spc` checks bindgen's C environment tables (`src/bindgen/ctarget_data.spc`)
against clang of the pinned major release (`ctarget_data::PINNED_VERSION`). The oracle is the first of
`$SC_CTARGET_CLANG`, `$CC`, `clang` and `cc` with that major. Without one, the macro and `__has_*`
tests pass without checking anything (the runner discards a passing test's output); with
`SC_CTARGET_REQUIRE=1` they fail instead. The `ctarget` job of the release workflow installs clang 22
and sets both variables. The built-in header tests run with any clang. `scripts/gen_ctarget.py`
regenerates the tables and `tests/codegen/ctarget_universe.spc`. The generator and the tests ask clang with
`--no-default-config --rtlib=platform`, so a vendor's configuration file or `CLANG_DEFAULT_RTLIB`
does not change the answers. A Debian or Ubuntu clang is not asked about `strlcpy` and `strlcat`:
Debian's packages remove those two library builtins (`DEBIAN_DROPS`).

`tests/tooling/cpp_test.spc` checks bindgen's preprocessor (`src/bindgen/cpp.spc`) against the host C
compiler's `cc -E` and `cc -E -dM` under the host's own search list (`-nostdinc` with `-isystem` and
`-iframework`): tokens, origins, line numbers and the macro set must be equal, over synthetic
sources and the system and framework headers the host has.

### The LIR check

`check.sh` runs the suite under `SC_LIR=1`, and the release workflow's first test shard of each
target sets it: the compiler under test and the test bundle lower every body they render to LIR and
fail the build on a verifier error (super-c-compiler-internals, "LIR"). The per-TU cache keys on it,
so a warm run checks only the modules it renders. The test binary runs without it, so the compiles
inside tests are plain. `tests/codegen/lir_test.spc` covers the tool calls, the verifier, the parser,
the evaluator on a tool-built body and on vector operations, and the text form: a package with every
opcode, condition, read-modify-write operation and machine type reads back to the same bytes.
`tests/codegen/lir_eval_test.spc` runs `super-c test` under `SC_LIR_EVAL` over the math and std
tests: the evaluator must agree with CTFE, and at least three quarters of the tests must run under
it; the math build's LIR text must read back to the same bytes and verify. To find a disagreement,
rebuild one test file under `SC_LIR=1 SC_LIR_EVAL=1 SC_LIR_STATS=1 super-c test --quiet
--filter=<file>`, then use `SC_LIR_RUN=<test symbol>` and `SC_LIR_TRACE=1`.

### The native backend

`tests/codegen/native_test.spc` compiles LIR text to an object, links it with a C driver and runs it
(`run_native`; `SC_NATIVE_KEEP=1` keeps the files), and with `WASI_SDK_PATH` set does the same for
wasm32 (`run_wasm`: `ptr 8` becomes `ptr 4`, the wasi-sdk's clang links, wasmtime runs), passes
values across the C ABI to header functions and C drivers, and checks that two builds give
byte-identical objects. A CLI test that reads the program's C passes `--emit-c`: a linking build
compiles natively and writes no C. `tests/codegen/lir_opt_test.spc`
optimizes LIR text and checks each transform's place and the evaluator's results before and after;
`lir_eval_test` runs the math tests' optimized LIR against CTFE (`SC_LIR_OPT=1`). `ci/gate.sh` checks that one
worker and every core build byte-identical native objects.
`tests/codegen/asm_test.spc` compares encodings with clang's only (`llvm_cc`: the C compiler when it is
clang, else `clang` on the path, else the comparison skips): GNU as picks other valid encodings. A
failing `wasm_libc_test` comparison names its first differing line.

The suite also runs with no C compiler and no linker (the `*-nocc` jobs of `debug.yml`: Linux in an
image with only the C library's headers, macOS and Windows with `CC` naming no file, wasm with only a
WASI sysroot). There every build compiles natively and links with the own linker. A test that compiles
C itself (`cc_build`, `c_lib`, a C driver, a C compiler wrapper), or compiles the C of `--emit-c`
(the C compiler's assembly of it included), starts with
`if !cli::has_cc() { return; // <what needs the C compiler> }`; `cli::has_cc` looks `cli::cc_name()`
up, so the test calls the C compiler through `cli::cc_name()`, never as a literal `cc`. A part of a
test that needs it takes the same condition. Run a lane locally with `CC=/nonexistent/cc ./super-c
test`; only an image without a C compiler finds a literal `cc`.
`tests/codegen/link_test.spc` `a_c_static_library_links_with_the_own_linker` builds a C library with
the C compiler and its archiver (and, with `WASI_SDK_PATH`, for wasm32) and links it with the own
linker: the one place the C compiler makes an input of the own linker.
`tests/codegen/debug_info_test.spc` builds a program with and without debug information for every native
target: the code and data sections match, an llvm-dwarfdump (on the path, beside clang, the wasi-sdk's or
Xcode's) verifies the line tables; gdb (Linux) or lldb (macOS, where it may run a program) stops in a
native function and backtraces its callers, else the test says it skipped; a C driver unwinds from a
native frame to its own and reads back the callee-saved registers it set (libunwind's cursor on macOS,
`_Unwind_Backtrace` elsewhere).

### Families of cases in few compiler runs

Each run of the compiler under test loads and checks std again, so a test with many small programs
puts them in one build. A batch never lets one case's result satisfy another's check, and every case
it does not pass runs alone with its original check, which names the case by its label.

- `cli::Batch::new(head, tail)` holds negative cases: `add(label, src, want)` and `add_at(label, src,
  want, at)` (`at` is `L:C` in the case's program `head + src + tail`); `one` requires exactly one error per
  case; `flags` and `file` (default `main.spc`) set the compile. A round compiles every unverified
  case as module `case_k` of one root, so the cases share no names, and verifies a case only by a
  diagnostic whose primary location is in `case_k.spc` (and at `at`). An error of an earlier stage
  stops the compiler before later stages, so each round verifies one more stage. After a round
  that verifies none, each remaining case compiles alone. Run it with `p.expect_batch(b)` (the
  script compile of `cli::Proj`) or `h::expect_build_errs(b)` (the `expect_build_err` check through
  `diff_build`). A case whose error is located outside its file (a `static_assert` in std) cannot
  be verified in a round: check it alone (`expect_build_err`).
- `h::ExitBatch` holds `expect_exit` and `expect_trap` cases (see the table above).
- `h::expect_runs(label, src, args, msgs)` checks several runs of one build.
- `h::same_runs(a, b, runs)` compares two `DiffBuild`s the caller made, so a test that also needs
  one of the builds (its assembly, its C) builds each once; `diff_proj()` and `diff_build_in(p,
  opts)` build a project with more files than `main.spc`.

`compile`, `compile_std` and the `compile_c` family do not load the prelude themselves on macOS
and Linux. The suite's global fixture (`@test_init(global)` in `tests/harness.spc`, so no test
file can declare another) loads, resolves and type-checks the host prelude once in the runner's
parent, with and without the vector backend (`loader::prelude_package_arch`). Each compile forks
from that snapshot, appends the snippet (`Package::add_source_module`), opens the item index
again over every module, and runs the rest: the snippet's resolve and type check, then the
type publication, the borrow check of every module and the emission. One publication keeps
every type id what the full pipeline gives; a suite run that compared both paths on every
compile found no difference. The result returns through a pipe. The forked compile reports its
own leaks, and a panic, a signal or an exit code ends the test the same way. Another instruction
set, `compile_std_bootstrap` and Windows run the full pipeline.

### Differential oracles

`tests/harness.spc` builds each program as `main.spc` of a scratch manifest project
(`diff_build`, `diff_run`). An option is a build flag (`--profile=release`, `--target=wasm`,
`--emit-c`, one argument even with spaces) or, as `NAME=VALUE`, an environment variable of the build
(`SC_BCE=0` keeps every bounds check). On the wasm lane each build
passes `--transpiler=$SUPERC`, so the transpile step and its constant evaluation run in the wasm
compiler under wasmtime; the C compile and the program stay native, except under
`const_runtime_parity`: there the program builds `--target=wasm` (wasi-sdk) and runs under wasmtime,
so the folded constants and their run-time twins call one C library, `std::rt::libm` (a wasm build's
libm call folds through that module's body on any host). `parity_f32_libm_on_wasm` checks it from a
native compiler when `WASI_SDK_PATH` is set.

- `same_output(src, opts_a, opts_b, runs)` runs both builds once per entry of `runs` (the
  command-line arguments of one run) and returns the first difference, empty when none. The trap
  text is the stderr lines starting `super-c: ` (runtime helpers) or `panic: ` (std); a build failure
  is a difference.
- `const_runtime_parity(decls, exprs, tys, opts)` puts every case in one program: `const
  PARITY_C<k>` and `fn parity_r<k>`, selected by `prog <k>`; `prog -1` runs them all in order, each
  after a line `= k`, and the helper runs that once, then alone each case after a trap or a crash. Write inputs as `opq::<T>(v)`: the
  constant calls the identity `const fn opq`; the run-time copy calls `opr`, a `@noinline`
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
  under `debug` (overflow checks on); `decls` must not trap. `parity_program` prints the program.
- `asm_check(src, opts, function, contains, absent)` builds, reads
  `build/<profile>/compile_commands.json`, finds the unit that defines `function`, reruns its
  command with `-S` (without `-c`, `-MMD` and `-flto*`, which would print IR), and matches
  substrings of instruction mnemonics (`asm_mnemonics`: the first word of each body line,
  without labels, directives and comments; Mach-O `_name:` labels too), so `x0` or `rax` never
  match; an entry that starts with `%` matches the whole instruction (`asm_instructions`), its
  register operands included. The assembly is the C compiler's of the `--emit-c` tree (`cli::cc_name()
  -S`), so these tests need a C compiler (`cli::has_cc`). x86_64 and aarch64 work on the host; wasm32
  needs `--target=wasm` and `WASI_SDK_PATH`,
  which the wasm lane sets (`asm_wasm32` in `tests/ir/differential_test.spc` returns early without it).
  Its two halves serve many functions from one build: `asm_text(b, opts, function, out)` compiles
  the unit of build `b` that defines `function` to assembly once, and `asm_match(text, function,
  contains, absent)` checks any function of it (`tests/simd/simd_aarch64_test.spc` builds all its
  kernels as one program).

### The vector conformance lane

`SC_SIMD_LANE=wasm` (a wasi-sdk in `WASI_SDK_PATH`, wasmtime on the PATH; `h::simd_lane()`) makes
every differential build of a test a wasm32 build with `--target-feature=+simd128`, run under
`wasmtime run -W relaxed-simd-deterministic=y`; `expect_run` also builds without the feature and
requires the same output. A host instruction check returns early in the lane. The masked-memory tests run there too: the
guard page is the end of linear memory (`sbrk`), the trap-before-write check reads the C order
(WASI has no signal handler), and the disjoint stores run one half after the other (no
threads). The release workflow's `wasm-checks` job (beside the wasm test shards) runs
`SC_SIMD_LANE=wasm SC_LEAK_CHECK=fatal ./super-c test --quiet --test-timeout=900 --filter=simd_`,
then the same with `--filter=gen_vector_seeds`.

`SC_TEST_TARGET=wasm` (`h::target_lane()`) is the vector lane over the whole suite: `simd_lane()` is
true under it, and `compile_and_run` (with `expect_exit`, `expect_trap` and `ExitBatch`) also builds a
wasm32 module, run with `wasmtime run -S inherit-env`. At the default profile every such program goes
through the native wasm backend. A case that needs what WASI lacks (threads, a host instruction
set) returns early under `h::target_lane()` (a `@blocking` call runs inline on wasm, so it needs none); an exit status must
stay below 126 (wasmtime rejects larger ones), and a program that ends with `exit` while it holds a
`String` longer than 11 bytes leaks on wasm32 (its inline capacity) where it does not on a 64-bit host.
The release workflow's `wasm-target` job runs it in two shards.

On an aarch64 host every build calls the Neon entries (`neon` is the baseline), so without the
lane `expect_run` builds again with `SC_SIMD_SCALAR=1` and requires the same output, the entry
model runs over `std/simd/backend/aarch64.spc`. `SC_SIMD_FEATURES=+dotprod,+i8mm,+rdm` adds
features to every differential build: the conformance run on Linux aarch64 uses the default set and
that one. An entry whose key another entry holds with other features is called in one of the two
sets only (`dot` with and without `dotprod`): the model accepts it uncalled when its sibling is
called.

On an x86_64 host the entry model runs over `std/simd/backend/x86_64.spc` and requires the
entries the run's features reach (the baseline, then `SC_SIMD_FEATURES`, which may name a level:
`x86-64-v2`); `SC_SIMD_WIDTH=512` passes `--simd-width=512` to every differential build, and
without it an AVX-512 entry wider than 256 bits is not required. A run checks only the entries no
run with fewer features checks: with `SC_SIMD_FEATURES` it skips those the baseline reaches, and
at 512 bits those the 256-bit run reaches. The release workflow's `levels` jobs (Linux, Windows,
one runner per level, beside the test shards) run `--filter=simd_` at `x86-64-v2` and
`x86-64-v3` only: a hosted runner's CPU is not selectable, so no CI job runs `x86-64-v4`. A machine
without AVX-512 checks those entries in the assembly only.

- `tests/simd/simd_entry_test.spc` (the entry model, `tests/gen/simd_entry.spc`): every `@simd_impl`
  entry of `std/simd/backend/wasm.spc` (in the lane), `aarch64.spc` or `x86_64.spc` (on such a host), through four vector model cases of each operation that
  reaches it at its lane count and at the most lanes (a `less_than` entry also through `count` and a
  `choose` of narrower lanes), and a choice, compress, expand or masked access over at most four
  lanes under every mask, built planned and with `SC_SIMD_SCALAR=1`; each case's value or
  trap must be equal, and the C of the first build must call every entry, except a lane-mask form
  (`Cmp*Lanes`, `ChooseLanes`, `LanesToMask`, `MaskToLanes`, `AnyLanes`, `AllLanes`) whose lanes the
  C handles through a called mask-register entry (AVX-512). Loads, stores and the `any`/`all`
  forms go through one extra program. Elsewhere the tests return at once.
- `tests/simd/simd_wasm_test.spc`: the C of a program without vectors is byte-identical with and without
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
  compares `debug` and `release` on a program that evaluates the plain operators under `release` and
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
  case, not a process per case; the program is built with the debug profile, and a trap exits with
  status 134 through a SIGABRT handler, as a crash report or core dump costs more than the run.
  `tests/simd/simd_ops_test.spc` sweeps every operation, lane type, lane count and conversion target
  through the same functions, in programs of at most 256 cases.

- `math.spc`: calls of the vector math classes (`std::simd::math`, `balanced`, `fast`) on lanes drawn
  near special points (zeros, infinities, NaN, subnormal and normal extremes, exp's thresholds, the
  `Konsts` thresholds, multiples of pi/2 of either sign and the double nearest one). Oracle 0 is `const_runtime_parity` per result lane; oracle 1 compares the
  planned build with `SC_SIMD_SCALAR=1` and checks that each lane equals the same call on that lane's
  input alone.

`tests/gen/gen_test.spc` runs seeds 1 to 3 of each model in the normal suite and the planted defect
(`--profile=release`: the run time wraps, the constant traps), which the scalar model must find at seed
14 and reduce to one case. The long run is `super-c command gen`
(200 seeds from the clock); replay or extend with
`SC_GEN_SEED=<seed> SC_GEN_RUNS=<n> [SC_GEN_MODEL=scalar|loops|vector|math] ./super-c test --quiet
--filter=gen_random_run`, which does nothing without `SC_GEN_RUNS`. Each seed builds four
programs (scalar), two (loops) or one or two (vector: a rebuild without the trapping constants).

## The vector math tools

`tools/simd_math` is one project with three binaries (one root: imports cannot cross project
roots): `simd-math-gen` (`gen.spc`), `simd-math-check` (`check.spc`) and `simd-math-bench`
(`bench.spc`), over `real.spc` (double words, `f128`, `f256`), `ref.spc` (the reference functions)
and `remez.spc` (minimax fits). Build each in release and run it from the repository root:

```sh
./super-c release tools/simd_math                          # simd-math-gen
tools/simd_math/build/release/simd-math-gen                # rewrites std/simd/math/coeffs_f32.spc and coeffs_f64.spc
./super-c release tools/simd_math --bin=simd-math-check
tools/simd_math/build/release-bin-simd-math-check/simd-math-check --write   # the full check
./super-c release tools/simd_math --bin=simd-math-bench
tools/simd_math/build/release-bin-simd-math-bench/simd-math-bench [--only=NAME]
```

- The generator is deterministic (its fits run in parallel, each independent, on grids built once
  for both lane types): rerun it after a change to a polynomial spec or a constant, then rerun the
  full check. A fit that misses its target, or a Remez exchange that does not converge, stops it.
- The full check: every f32 input of a one-argument function (2^32, minutes per class in parallel)
  against the f64 C library; `--n` f64 inputs per function (default 10^9: about an hour for all; a
  quarter random bits, a quarter within 2^40 ULP of 0, 1, the domain ends and every `Konsts`
  threshold, the rest uniform per binade, or near multiples of pi/2 for the trigonometric functions)
  against the double-word reference; pairs of two-argument functions shaped per function, and in f32
  every pair of binades; a result within 0.01 ULP of the bound, or a subnormal one, again against
  f128; a zero result must have the reference's sign. The special-value tables: a zero, infinite or
  NaN argument gives the C library's result exactly, any other the class bound against f128. `--write`
  replaces the measured table (each function's largest error and its input) at the top of each class
  module; it needs every function and both lane types. `--only=NAME`, `--part=K/N` (the functions
  whose index is K modulo N), `--f32`, `--f64`, `--n=N` and `--sample32=N` (random f32 inputs instead
  of all) narrow a run; `--jobs=N` (both tools) sets the worker threads. Exit status 1: a result over its
  bound or a wrong special value, printed per function and class.
- The bench prints ns per element for each class and the scalar C library loop at the native lane
  count (wide ranges log-uniform per binade), the ratios, and a `gate:` line per failed class gate
  (precise not slower than the library; balanced 20% faster than precise and fast 20% faster than
  balanced for exp, log, sin and cos, faster for the rest); exit status 1 when one fails.

`tests/simd/simd_math_test.spc` runs in the normal suite: the special values of every function, class
and lane type at compile time against run time (`const_runtime_parity`, Annex F domain edges and
pow's special pairs included; each function through a `@noinline` wrapper, so its kernel is in the
C once), a hash of 10^5 results per function and kind (the planned build
against `SC_SIMD_SCALAR=1`; for every function, two-argument ones, `powi` and `sincos` included, each
lane of a call at the other lane count against the call on that lane's inputs alone; and a fixed
combined hash per class and lane type every target must give, one test each (`ALL_PRECISE_32` ..
`ALL_FAST_64`): after a kernel or coefficient change, set it to the `all` line the failing test
prints). Its builds and the math model's (`tests/gen/math.spc`) run one compile job (`--jobs=1`): a
test of the parallel suite takes one CPU, so its large programs do not starve the tests beside it;
its tests take `@test(timeout = 300)`. `tests/cli/vector_math_tools_test.spc` runs the generator against the committed coefficients
and the reduced check (10^6 inputs per function: `--n=500000 --sample32=500000`, a third of the
functions per test), each tool built with the release profile (their f128 arithmetic needs
inlining across units) in a scratch copy. Their results do not depend on the lowering, so that
file's path names no `simd_`: CI's per-level `--filter=simd_` jobs skip it. In the suite the tools
run with `--jobs=1`: a test that starts a worker per CPU slows every test beside it past its
timeout. These tests take `@test(timeout = 300)`.

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
