# The Compiler's Own Test Corpus

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
compiles natively and writes no C. `tests/codegen/lir_opt_test.spc` and
`lir_loops_test.spc` optimize LIR text and check each transform's place and the evaluator's results
before and after; `tests/cli/codegen_flags_test.spc` builds one program at each level and with each
`-f` flag: each changes the binary and keeps what it prints;
`lir_eval_test` runs the math tests' optimized LIR against CTFE (`SC_LIR_OPT=1`). `ci/gate.sh` checks that one
worker and every core build byte-identical native objects.
`tests/codegen/asm_test.spc` compares encodings with clang's only (`llvm_cc`: the C compiler when it is
clang, else `clang` on the path, else the comparison skips): GNU as picks other valid encodings. A
failing `wasm_libc_test` comparison names its first differing line.

No build runs a C compiler, and the suite runs with no C compiler and no linker (the `*-nocc` jobs
of `debug.yml`: Linux in an image with only the C library's headers, macOS and Windows leaving their C
tools unused, wasm with only a WASI sysroot). A test that compiles C itself (`cc_build`, `c_lib`, a C
oracle, a C driver, the emitted C) starts with `if !cli::has_cc() { return; // <what needs the C
compiler> }`: `cli::has_cc` is whether `SC_TEST_CC` names a C compiler, which only the comparison job
sets, and the test calls it through `cli::cc_name()`, never as a literal `cc`. A part of a test that
needs it takes the same condition. `tests/codegen/link_test.spc`
`a_c_static_library_links_with_the_own_linker` builds a C library with that compiler and its archiver
(and, with `WASI_SDK_PATH`, for wasm32) and links it with the own linker, also with section garbage
collection; `section_garbage_collection_drops_what_nothing_reaches` checks what the collected link
keeps on the host and, with `WASI_SDK_PATH`, on wasm32.
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
(`diff_build`, `diff_run`). An option is a build flag (`--profile=release`, `--target=wasm`, `-O2`,
`--emit-c`: the build writes the C tree only, which `c_link` builds), one argument even with spaces,
or, as `NAME=VALUE`, an environment variable of the build (`SC_BCE=0` keeps every bounds check). On
the wasm lane each build passes `--transpiler=$SUPERC`, so the transpile step and its constant
evaluation run in the wasm compiler under wasmtime; the program stays native, except under
`const_runtime_parity`: there the program builds `--target=wasm` (wasi-sdk) and runs under wasmtime,
so the folded constants and their run-time twins call one C library, `std::rt::libm` (a wasm build's
libm call folds through that module's body on any host). `parity_f32_libm_on_wasm` checks it from a
native compiler when `WASI_SDK_PATH` is set.

- `same_output(src, opts_a, opts_b, runs)` runs both builds once per entry of `runs` (the
  command-line arguments of one run) and returns the first difference, empty when none. The trap
  text is the stderr lines starting `super-c: ` (runtime helpers) or `panic: ` (std); a build
  failure on either side is a difference.
- `const_runtime_parity(decls, exprs, tys, opts)` puts every case in one program: `const
  PARITY_C<k>` and `fn parity_r<k>`, selected by `prog <k>`; `prog -1` runs them all in order, each
  after a line `= k`, and the helper runs that once, then alone each case after a trap or a crash.
  Write inputs as `opq::<T>(v)`: the
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
model runs over `std/simd/backend/aarch64.spc`. `SC_SIMD_FEATURES=+dotprod,+i8mm,+rdm`
adds features to every differential build: the conformance run on Linux aarch64 (the arm64
runner, with the cross-built compiler) uses the default set and that one. An entry whose key another entry holds with other features is called in one of the two
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
