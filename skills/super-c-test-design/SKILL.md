---
name: super-c-test-design
description: "How to design Super-C tests that are correct and cheap: the oracle ladder from in-process checks to CLI scenarios, batching exit-code cases, cache rules, program size, and how to measure a test's CPU and energy before adding it. Use when writing, reviewing, or restructuring tests, and when the suite's time or energy grows."
allowed-tools: Bash Read
---

# Super-C Test Design

The suite runs thousands of compiles on every local run and on every CI shard. A test that
picks a costly oracle, turns a cache off, or builds one program per case multiplies that cost.
This skill holds the design rules; `super-c-testing` holds the mechanics (attributes,
fixtures, helpers, runner flags).

## Agent checklist

- Pick the cheapest oracle that observes the behavior (the ladder below). Go up a rung only
  when the lower one cannot see the behavior.
- Put exit-code and trap cases in `h::ExitBatch`, never one `expect_exit` or `expect_trap` test
  per case.
- Leave the caches on. Use `cli::superc_in`; use `SC_NO_CACHE=1` only in a test that
  checks the prelude images.
- Measure a new or changed test file before handoff (Measuring) and report its CPU time.
- For each assertion, name one wrong implementation it rejects (Oracles that can fail).

## Correct tests

- Test the contract: exit codes, diagnostics, emitted C needles, files a command writes. Not
  internal data structure shapes.
- One assertion per concept, each with a label that names the case.
- Deterministic: no dependence on the scheduler's order, the clock, the host's core count,
  or another test. Wait for a state, never for a duration (`super-c-testing`, Test Design Rules).
- A host-specific output difference is a defect where the bytes are produced. Never normalize
  it in the test.
- Every test is isolated by fork; shared state goes through `@test_init(global)`, and the
  suite's global fixture belongs to `tests/harness.spc` (the prelude snapshot).
- A failing case must name itself: `ExitBatch`, `cli::Batch` and the differential oracles report
  the label.
- Before you add a test, search `tests/` for the function or feature name: a case another test
  already asserts on the same code path is not added again.

## Oracles that can fail

A test must fail for the defect it names. Before handoff, take each assertion and name one wrong
implementation it rejects; when you cannot name one, the assertion is not an oracle.

- A needle the input already holds proves nothing. A transform test asserts a fact the input does
  not have: a count that changes, an instruction that disappears, an order that is new. Check the
  needle against the input LIR, the source, and the unoptimized output.
- A needle is unique to the fact. `"call m"` matches every call; `"mismatched types"` matches every
  pair of types. Name the callee, the types, the value.
- A rejection test names its message, never only `!c.ok()` or a nonzero exit: an unrelated error, or
  a crash that the feature should have prevented, passes too.
- A check that a pass ran shows that it ran. A gate or an analysis that prints nothing on success
  needs a positive mark (a count, `0 violations`) or a run counter the test reads.
- Inputs separate the right result from the wrong ones. A `<` case has an equal lane that must be
  false; a predicate has a true case and a false case; `min` and `max` get different arguments;
  `normalize` gets a non-unit input; `row` and `column` get a non-symmetric matrix; a cast changes
  the type; a rotation moves its input; vector lanes differ (no `splat`).
- A round trip compares the result with the original input, not with a second round trip of it:
  `unpack(pack(unpack(pack(x))))` equal to `unpack(pack(x))` holds for a packer that writes 0.
- "Differs from X", "is not zero" and "is later than t0" are not oracles. Assert the value, or the
  bound the claim states.
- A `should_panic` body holds no assertion that fails on the result of the unchecked code: that
  panic passes the test. Call the function and discard its result.
- A scenario program (rungs 4 and 5) obeys the concurrency rules of `super-c-testing` (Test Design
  Rules) too: it waits for a state (`rt::tasks_waiting(rt::WK_MUTEX)`, a counter), never for a sleep
  to let another task arrive, and takes a start time before it starts what it measures. A test of
  file times sets the time it needs (`touch -t`), never two builds within one second.
- A fixed size that must fit a host limit (recursion depth in a stack, a buffer in a page) depends
  on the frame size of each ABI and profile. Derive it from the limit, or keep a margin of several
  times the largest frame the lanes show.

## The oracle ladder

Cheapest first.

| Rung | Helpers | What it can observe |
|------|---------|---------------------|
| 1. Parse | `h::parse_ast`, `h::parse_has_error` | Syntax, AST shape |
| 2. Check in process | `h::compile`, `h::expect_ok`, `h::expect_err_msg`, `h::compile_std` | Resolve, type check and borrow check diagnostics. Forks from the prelude snapshot: std is not checked again |
| 3. Emit in process | `h::compile_c`, `h::expect_c`, `h::expect_c_absent` | The emitted C text |
| 4. Build and run | `h::ExitBatch`, `h::expect_exit`, `h::compile_and_run` | Run-time behavior. One `super-c` process, C compiles and a link per program |
| 5. CLI scenario | `cli::proj_new`, `cli::superc_in`, `p.compile` | Build-system behavior: manifests, caches, staleness, subcommands |
| 6. Differential and generators | `h::diff_build`, `h::same_output`, `h::const_runtime_parity`, `tests/gen/` | Equivalence of two lowerings on large programs |

Rules for the costly rungs:

- Rung 2 sees the first diagnostic of the resolve, type check and borrow check. It does not see
  a program that imports `std::parallel` or an ffi module such as `stdlib` (the in-process
  prelude does not load them), a later error of the same program, or an error the build reports
  after the borrow check (an instance's lowering, the constant flush before emission). Check those
  with `h::expect_build_err` or `cli::Batch`.
- Rung 4: group the exit-code cases of a file into provider functions
  `fn name(b: &mut h::ExitBatch)` and run them from `exit_cases_NN` tests of about 20 cases.
  One build serves every case; `add_trap` adds a case that must fail with a message. A case whose
  `main` is neither `fn main()` nor `fn main(NAME: Vector<str>)`, a case that needs a build flag,
  and a case about a root module's bare C names stay alone. A CLI scenario whose only check is the
  exit code of one file is a rung 4 case: it goes into a provider, not a project of its own. Every
  run already sets `SC_LEAK_CHECK=fatal` (`cli::run_with`), so a case does not pass it again. A
  panic that a std function raises before any build-dependent code runs is a rung 2 `should_panic`
  test in process, not a build.
- `h::expect_run` builds twice on aarch64 and in the wasm lane (the vector and the scalar entries).
  Put a file's run cases into one program that selects its case by argument and run it with one
  `h::expect_runs`.
- Rung 5: one project per test, reused across its steps. A test that runs its program builds it
  natively (`p.native_build(flags, "main.spc")`: from the root, its outputs under `native/`, so the
  C tree of an earlier `p.compile` stays for `gen_has`), and so runs on every lane. A strict
  whole-tree compile (`p.cc_build`) compiles the `--emit-c` tree with the C compiler, only with
  `SC_TEST_CC`, so use it only when the C is the behavior. The build compiles no C file of a
  project's tree: a test whose program binds C code links it prebuilt, through `p.c_lib(name,
  "x.c")` and `@link("-L. -l<name>")` (`native_build`), or `p.cc_build_with(flags, "x.c")` (a test
  of the emitted C); a header whose `static inline` function holds the code needs neither.
- Rung 6: put many cases in one program that selects a case by its argument (`prog <k>`), as
  `const_runtime_parity` does. Size a generated program by the cases it must hold.

## Caches

- The suite shares one cache base (`SC_CACHE_DIR`, set by `super-c test` to `SC_TEST_CACHE_DIR`, else
  to `<out-dir>/test/cache`, deleted when the run ends). Give a fixture project a fixed name: a kept
  base holds one root per project name. A new project of a name another test already built (`app`) compiles
  only its own units; script builds share `.scripts`.
- The C tree of a small program is one unit (`__sc_unity.c`). A test that checks the C units of
  `--emit-c` one by one sets `SC_UNITY_MAX=0` (`cli::set_env`), and a test of packs
  `SC_UNITY_MAX=1`.
- `SC_NO_CACHE=1` makes every build of that test check the std prelude again. Use it only where the
  assertion is about the prelude images. The same holds for `SC_NO_EMIT_CACHE`, `SC_NO_TU_CACHE`
  and every other cache switch: a test turns a cache off only when its assertion is about that
  cache, and then names the reason. A cache left on also tests the cache key: a flag missing from
  the key gives a stale result.
- A test that checks cache behavior sets its own `SC_CACHE_DIR` under its scratch directory.
- The checked std prelude is cached in the cache root too (`<root>/prelude/`): a build
  type-checks only the program, and lowers and borrow-checks only the std bodies it reaches
  (`Package::bc_lazy`). A test that must see the prelude checked (a std edit, a std tree of its own) sets
  its own `SC_CACHE_DIR`, as `tests/cli/prelude_image_test.spc` does; the first build in a new cache
  root checks the prelude once.

## Profiles

- No build has a sanitizer: the native backend links none. The leak and double-free tracker
  (`SC_LEAK_CHECK=fatal`) and the validation switches (`SC_BC_VALIDATE`, `SC_TYPE_VALIDATE`) are
  the checks a suite run takes.
- Build with `--profile=release` only when the result depends on it: the LIR optimizer and the
  inliner make a release build slower than a debug one.
- A test that starts one worker per CPU passes `--jobs=1`: the suite already runs one test
  per core.
- A test that compares one worker with several runs the parallel path only on a program of at
  least 256 KiB of sources (`Package::analysis_jobs`), with the workers it asks for: pad the
  program with `cli::par_sized`, build with `--jobs=N` and `cli::NO_JOBSERVER` (the suite's
  jobserver may give fewer), and assert the worker count where the build prints it.

## Measuring

Measure the CPU time of one test file (`<mod>` is the file stem) with the runner the last
`super-c test` built:

```sh
./super-c test --quiet --filter=<mod>
SUPERC=$PWD/build/test-bin/super-c SC_STD_DIR=$PWD/std SC_CACHE_DIR=$PWD/build/test/cache \
  /usr/bin/time -p build/test/__tests --quiet --filter="tests::<mod>::"
rm -rf build/test/cache
```

The sum of `user` and `sys` is the file's CPU time. The whole suite's energy, by process, on
macOS:

```sh
SC_LEAK_CHECK=fatal python3 scripts/measure_energy_macos.py ./super-c test --quiet
```

Run it twice and report the second run: the first one rebuilds the compiler under test and
the runner after a source change. A new test file that costs more than its share of the
suite's CPU (more than a few seconds for a unit-level file) needs a lower rung, a batch, or a
smaller program.
