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
  and a case about a root module's bare C names stay alone.
- Rung 5: one project per test, reused across its steps. A strict whole-tree compile
  (`p.cc_build`) compiles the `--emit-c` tree with the C compiler, so use it only when the C is
  the behavior. The build compiles no C file of a project's tree: a test
  whose program binds C code links it prebuilt, through `p.cc_build_with(flags, "x.c")` (the
  harness compile) or `p.c_lib(name, "x.c")` and `@link("-L<root> -l<name>")` (an engine
  build); a header whose `static inline` function holds the code needs neither.
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
  assertion is about the prelude images.
- A test that checks cache behavior sets its own `SC_CACHE_DIR` under its scratch directory.
- The checked std prelude is cached in the cache root too (`<root>/prelude/`): a build
  checks only the program. A test that must see the prelude checked (a std edit, a std tree of its own) sets
  its own `SC_CACHE_DIR`, as `tests/cli/prelude_image_test.spc` does; the first build in a new cache
  root checks the prelude once.

## Profiles

- Build with `--profile=release` only when the result depends on it: the LIR optimizer and the
  inliner make a release build slower than a debug one.
- A test that starts one worker per CPU passes `--jobs=1`: the suite already runs one test
  per core.

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
