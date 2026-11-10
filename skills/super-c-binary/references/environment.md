# Environment Variables

## Environment Variables

### Build and caches

| Variable | Effect |
|----------|--------|
| `SC_TIMINGS` | Print a one-line per-phase timing summary |
| `SC_BUILD_STATS` | Append one JSON record per engine build to the named file (`-` = stderr): every phase of the partition in ms, cache switches, the instance re-lowering counts by reason (`"relower"`), peak RSS at five boundaries (`src/driver/stats.spc`) |
| `SC_BUILD_MEM` | With `SC_BUILD_STATS`: turn the runtime allocation tracker on for the build, so the record carries allocation calls, requested bytes, live bytes and per-phase survivors (slower; never for timing runs). `"mem":{"on":false` = the runtime this compiler links predates the counters (a bootstrap build) |
| `SC_STD_DIR` | The std directory, in place of the `std/` found beside the compiler binary (`exe_std_dir` in `src/main.spc`). `super-c test` sets it for the compiler under test, which `--out-dir` may place outside the project, when the project holds `std/core.spc` and the variable is unset (`src/build_system/build.spc`) |
| `SC_CACHE_DIR` | Override the build cache base (each project's root below it: prelude images under `prelude/`) |
| `SC_NO_CACHE` | Disable the build cache (the prelude images) |
| `SC_TEST_CACHE_DIR` | The cache base `super-c test` gives the compilers its tests start, kept across runs (CI sets `~/.super-c/cache/.tests`); unset, `<out-dir>/test/cache`, deleted at the run's start and end |
| `SC_JOBSERVER` | The process-tree jobserver the first compiler of a tree makes, or a test runner started without one (`--jobs` slots), and every process it starts joins: `<slots>,<fd>` on POSIX (the inherited descriptor of an unlinked slot file), `<slots>,<path>` on Windows (a temporary file deleted with its last handle). A process holds a slot as a byte-range lock on one byte (`fcntl` record lock, `LockFileEx`), which the system drops when the process ends by any exit, abort or kill, so a killed process never takes slots with it. One more slot is implicit to each process |
| `SC_UNITY_MAX` | Bytes of C up to which the C tree of `--emit-c` is one unit (`__sc_unity.c`; default 2 MiB); a larger program puts its small units in packs (`1`: a small program does too); `0` keeps every unit alone, with no pack. The emit stamp records it |
| `SC_NO_EMIT_CACHE` | Disable the emit stamp |
| `SC_NATIVE_STATS` | Print `native: <module> native` per module, then the compiled and refused module counts and the native phase's ms (a refused module is a build error, printed with its reason in every build) |
| `SC_NO_TU_CACHE` | Disable per-TU journal/replay cache |
| `SC_BUILD_MEM_BUDGET` | Cap the estimated bytes in flight across the parallel jobs of the type check, the borrow check and the emission (`64M`, `2G`); a job above the whole budget runs alone; a value that is not digits plus one optional K/M/G suffix, or that overflows, is a fatal error |
| `SC_TYPE_STATS` | Print the type identity counters per phase and at the end of emission: interning hits and probe steps, foreign lowerings, instance-graph interns, layout cache traffic, the bytes the package type table and the module pools retain, the publication census, and per publication the kept bodies remapped and the time it took (`type-identity.md` in the internals skill) |
| `SC_SYNTAX_STATS` | Print one syntax accounting line per phase (parse, resolve, typecheck, borrowck, emit): node and child counts with the share inside bodies, the retained bytes of nodes, children, resolutions, types, module pools and the other side tables, the source text, and the module that retains the most (`syntax-ownership.md` in the internals skill) |

### Verification (validation switches, each runs only when set)

| Variable | Effect |
|----------|--------|
| `SC_FACTS_CHECK` | Snapshot semantic tables after typecheck; report mutations. A clean build prints `facts-check: N modules, no table changed` |
| `SC_CORE_IR` | Re-verify inlined bodies and re-prove bounds-check eliminations. The build ends with `core-ir check: N bodies re-verified` |
| `SC_LAYOUT` | Validate pool types against C layout invariants |
| `SC_BORROW_STATS` | Borrow-check probe table (`src/borrowck/flow_ir.spc`): ms, calls and (with `SC_BUILD_STATS` + `SC_BUILD_MEM`) allocations per region (lower, replay, forest, facts, cfg, liveness, moves, solver, rules, emit, setup, decl, reach, drops, publish, keep, tail: their total is the build record's `borrowck` phase less a few ms of loop overhead; `reach` is the stage's per-module prologue, the module reference rows, body counts and reachability scans, and the solve), skip and elaboration tallies, sizes, the lowered product (Core IR KiB, type slots, replay-tape entries per event kind), the slowest bodies and the retained scratch. Needs `SC_BUILD_STATS`; parallel allocation columns are global counters and mean nothing |
| `SC_BC_VALIDATE` | Validation build: every borrow-check stage the feature predicate skipped runs anyway and must find nothing (zero loans, zero move events, no diagnostic); every loan issues at a borrow operation, every move path has a valid parent, the init rows match the path count, the liveness queue stays within its tight bound; every elaborated body passes the structural verifier and the ownership verifier (`ir::drops::verify_drops`: each value released once per path, guarded where paths disagree, nothing held at a return). A failure prints the body and its events, then aborts. Output is unchanged. The gate runs its fixpoint and worker-identity builds under it |
| `SC_TYPE_VALIDATE` | After every type publication checkpoint, exit 1 if any module table still names a provisional type id. The gate runs its fixpoint and worker-identity builds under it |
| `SC_TYPE_COLLIDE` | Every type and instance hashes to one bucket: the type tables run on full comparisons alone, so a hash-order dependence shows as different output |
| `SC_TASK_DELAY` | A seed: a deterministic per-job delay (100 to 400 us, a hash of the job and the seed) at the start of every parallel item job (type check, borrow check, always-panics), so the worker-identity gates run under schedules the machine would not produce by itself, a different one per seed |
| `SC_TYPE_TABLE` | Path: write the package type table at the end of emission, one line per final id (`id class kind qualifier module payload`, children as final ids); the gate compares the dumps of one worker and every core under each delay seed |
| `SC_CEMIT_STATS` | Per-phase wall times (the unused-item lint as its own phase), the interpreter body-reuse counters (kept hits, fresh lowerings, retained boxes; printed after borrow checking and after the always-panics check), the proof line (`prove: <n> to prove, <k> from the proof record`), the instance graph's collect line (records by kind, bodies walked, rounds, a budget stop) and its per-instance `static_assert` line (`cemit-stage inst-asserts`: ms, instances checked), the re-lowering census (one line per template: instances, re-lowerings, identical re-lowerings, retained KiB) and the emission probe table (`src/emit/probe.spc`: ms and calls per region, the instance discovery total, re-lowering templates and instances by reason, bodies taken from the keep or lowered, rendered bodies and bytes; with `SC_BUILD_STATS` + `SC_BUILD_MEM` also allocation calls and MiB) |
| `SC_INLINE_STATS` | Per-body inliner decision counters |
| `SC_BCE_STATS` | Per-body bounds-check elimination counters (`BceStats`): checks and range checks seen and removed, coalesced, folded, signature crossings in the walked blocks, and the kept checks per reason (six reason columns, `BR_WIDENED` the last) |
| `SC_BCE` | `0` turns bounds-check elimination off: every check stays (the generator's BCE differential oracle) |
| `SC_BCE_DISABLE` | A list of BCE rules to turn off, matched by substring: `fold` (folded panic guards, and their widening), `widen` (guard widening alone), `sig` (signature facts), `int` (the interval facts of `ir/facts.spc`) |
| `SC_SIMD_LEVEL` | Test switch: the run-time copy level `k` (0 the bodies without the copies' features) the dispatch checks of an x86_64 program read instead of the CPU's (an emulator that hides features it runs) |
| `SC_SIMD_SCALAR` | `1`: the vector planner uses no `@simd_impl` entry; every vector operation keeps its lane loop (the entry differential oracle) |
| `SC_SIMD_TRACE` | Print each vector operation for which `simd_plan` finds no single entry (`simd: no native entry for <Op> on <T>xN: chunks` or `the lane loop`) |
| `SC_VEC_REPORT` | `1`: the LIR optimizer prints each loop the vectorizer left scalar, its location and the reason (`<file>:<line>:<col>: not vectorized: <why>`, a debugging aid) |
| `SC_LIR_PRINT` | A name: the LIR optimizer prints to stderr each optimized body whose function name holds it (a debugging aid) |
| `SC_LIR` | The LIR check (super-c-compiler-internals, "LIR"): `1` lowers every module's bodies to LIR beside the C, a comma-separated list of module paths (`lir::lower,std::string`) only those modules'. At the end of the emission the build fails when a body it rendered fails the verifier. The emitted C is the same. The value is part of the emit stamp and of the per-TU cache keys, so a replayed module passed the check when its record was written. `super-c test` unsets it for the test binary. `check.sh` runs the suite under `SC_LIR=1` |
| `SC_LIR_OPT` | `1` runs the LIR optimizer (`lir::opt`, super-c-compiler-internals, "LIR") on a native build's bodies, `0` does not; unset, a build whose C flags optimize runs it. Part of the emit stamp and of the native record's key |
| `SC_LIR_INLINE` | `0`: the LIR optimizer inlines no call (a debugging aid). Part of the emit stamp and of the native record's key |
| `SC_LIR_PROMOTE` | `0`: the LIR optimizer promotes no slot to values and merges no slot copy (`lir::promote`, a debugging aid). Part of the emit stamp and of the native record's key |
| `SC_LIR_EVAL` | With `SC_LIR` in `super-c test`: run each test under CTFE (`lw::probe_tests`) and in the LIR evaluator, and fail when they end differently. The command ends after the suite's emission: it builds no project binary, compiles and links nothing, and runs no test. The emit stamp and the per-TU cache are off: every test body lowers. `tests/codegen/lir_eval_test.spc` runs it over the math and std tests |
| `SC_LIR_STATS` | With `SC_LIR`: print the body counts, and under `SC_LIR_EVAL` the CTFE comparison tally (compared, checked against the test's expectation, FFI, past a budget), even when the check passes |
| `SC_LIR_TEXT` | With `SC_LIR`: path; write the LIR text form of the bodies the build rendered |
| `SC_LIR_DUMP` | With `SC_LIR`: a symbol or a refusal reason; print the Core IR of that refused body, and of each body that fails the verifier |
| `SC_LIR_RUN` | With `SC_LIR`: a symbol; run it in the LIR evaluator with no arguments and print the outcome |
| `SC_LIR_TRACE` | With `SC_LIR`: the evaluator prints each call with its argument words and each return with its result words (`lir-trace <depth> ...`) |
| `SC_ITEM_STATS` | The item schedule index measurement (`src/graph/items.spc`): per-item typecheck costs, the graph and its components, the predicted item-schedule makespans against the module-level schedule the type check ran before, per-body borrow and per-module panics and emission costs, the index digest (serial builds; `--jobs=1` for the costs). Keeps every body arena until emission planning (its final graph reads the bodies) |

### LSP

| Variable | Effect |
|----------|--------|
| `SC_LSP_NO_INCR` | Disable incremental per-edit recompilation (full rebuild, parity mode) |
| `SC_LSP_BUDGET_MB` | Bound retained packages (closed-file roots evict first; open docs pinned) |
| `SC_LSP_STATS` | One line per analysis round: modules, released, held, KiB retained, ms, bodies parsed back, extra passes |

### Runtime (read by compiled programs)

| Variable | Effect |
|----------|--------|
| `SC_LEAK_CHECK` | Leak and double-free tracker (also reports a `realloc` of a freed pointer; no other use-after-free check): any non-`0` value reports at exit; a value starting `f`/`F` (e.g. `fatal`) exits 23 on findings |
| `SC_TASK_TRACE` | Coroutine/task tracing for the life of the process (empty or `0`: off) |
| `SC_SCHED_SEED` | Scheduler seed, read only when the program set none itself (deterministic replay) |
| `SC_LOCK_ORDER` | Lock-order inversion checking (`ffi/sc_runtime.spc`) in a build of a profile with `lockdep = true` (the build constant `LOCKDEP`): non-`0` reports; `f`/`F` prefix aborts |
| `SC_TEST_SUPERC` | Path of compiler under test (wasm lane) |
| `SC_CTARGET_CLANG` | Clang of the pinned major release that `tests/codegen/ctarget_test.spc` compares bindgen's C environment tables with |
| `SC_CTARGET_REQUIRE` | Non-empty: a missing oracle clang fails those tests instead of passing them without checking |
