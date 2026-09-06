---
name: super-c-binary
description: "Documents the super-c compiler binary: subcommands, flags, build.toml manifest, environment variables, and the two-stage bootstrap. Use when invoking the compiler, configuring a build, running tests or benchmarks, or setting up a project."
allowed-tools: Bash Read
---

# Super-C Binary

## Agent checklist

- Read `skills/README.md` for precedence and the verification tag.
- Check `src/main.spc` before trusting a CLI flag claim.
- Check `src/build_system/` before trusting manifest or profile behavior.
- Report undocumented flags or environment variables as stale documentation.

Super-C is a self-hosting compiler that transpiles `.spc` source to readable C99/C11,
then invokes a gcc-style C driver (cc/clang/gcc; mingw on Windows — MSVC's cl.exe is out
of contract) to produce a native binary. The single binary `super-c` drives every stage
of the workflow.

## Subcommands

### Compile

```sh
super-c app.spc              # compile only: emit the build/ C tree (script mode)
super-c build app.spc -o app # compile + link only, name the binary (default: a.out)
```

A bare `.spc` argument compiles the file (and its transitive imports) and emits a `build/`
tree of `.h`/`.c` files. It links and runs nothing —
use `super-c build <file.spc> -o <name>` to link a named binary, then run it yourself. Single-file programs
emit plain C names; multi-module programs mangle symbols by module path.

### Build system (manifest-driven)

```sh
super-c build                # build from build.toml (dev profile, incremental)
super-c build -o out         # override output binary name
super-c release              # optimized build (release profile; alias for --profile=release)
super-c run                  # build + execute the manifest binary
super-c clean                # remove build outputs (--cache also drops the build-record cache)
```

The build system reads `build.toml` in the working directory. An emit stamp skips the
entire transpile when no input changed (~25 ms no-op). Parallel C compilation uses
content-fingerprinted stale detection with longest-job-first scheduling.

### Testing

Always pass `--quiet` (only the failures and the tally print; failed tests replay
their captured output regardless). Drop it only to watch a passing test's output
under `--test-no-fork`.

```sh
super-c test --quiet                   # the standard form: discover tests/**/*.spc, build, run
super-c test --quiet --test-filter=parse  # substring match on test name
super-c test --quiet --test-shard=1/4  # stable one-based CI sharding
super-c test --quiet --test-jobs=8     # bound the fork pool (default: one per core)
super-c test --test-no-fork            # in-process (for debuggers; should_panic skipped)
super-c --test --quiet app.spc         # single-file form (same --test-* flags apply)
```

Each `@test` function runs in a forked child. `@test_init` provides fixtures;
`@test(should_panic)` passes only when the body aborts. Each child's output is captured
and replayed only for failed tests, in a `failures:` section after the run (one header per
failed test, its output, how the process ended, then the list of failed names).
`--test-no-fork` captures nothing.

### Benchmarking

```sh
super-c bench                # generate a runner over bench/'s @bench fns, build, run
super-c bench --no-run       # build only (for profiler attachment; binary: build/bench-bin)
super-c bench --bench-filter=S  # run only benchmarks whose name contains S
super-c command profile      # build then run under samply (if [command.profile] defined)
```

`super-c bench` writes an import-only root covering every `.spc` under `bench/` and
collects `pub @bench` functions. The generated runner carries the checkout's identity
(the short commit, `-dirty` when tracked files differ, `unknown` without version
control) and prints it as `running benchmarks (build <id>)`. The filter is forwarded to the
bench binary as a run-time argument, so a filtered run never relinks; a filter that
selects no benchmark exits nonzero, and so does any benchmark that calls
`bench::fail`. The compiler's own transpile bench (`self_transpile`) runs 100 serial
self-transpile rounds and prints per-phase averages (CPU ms, Mcyc, Kalloc, MiB),
throughput, the min/median/p95/sd of CPU ms, Mcyc and wall ms over the rounds, heap
requested per round and peak RSS; then it runs one cold build of the compiler through
the real build engine (dev profile, every core, object cache, emit stamp and ccache off)
and reports the engine's phase record. A C compiler or linker failure there fails the
run and keeps the scratch tree. `SC_BENCH_OUT=<file>` writes the whole record as JSON.

### Gates

```sh
super-c command gate         # ci/gate.sh: the full correctness gate (contract ci/contract.sh)
super-c command perf         # ci/perf_gate.sh: the 100-round performance gate against ci/baseline.env
super-c command matrix       # ci/bench_matrix.sh: the whole-build benchmark matrix (tens of minutes)
```

`ci/contract.sh` is the versioned compatibility contract: every input file, option and
command the gates use. `ci/baseline.env` holds the accepted baseline constants
(`SC_PERF_RECORD=1 sh ci/perf_gate.sh` rewrites it; `SC_PERF_TOL` is the allowed
regression in percent).

### Formatting

```sh
super-c fmt                  # format all .spc files in-place (the default; Wadler, width 120)
super-c fmt --check          # exit non-zero if any file would change (CI gate)
super-c fmt path/file.spc    # format specific paths; `fmt -` reads stdin
```

`@fmt.skip` on an item exempts it from formatting.

### Linting

```sh
super-c lint                 # default-on lints (errors on missing-free)
super-c lint --fix           # apply machine fixes, re-lint to fixpoint
super-c lint --const         # flag functions provably const-evaluable
super-c lint --fix --const   # make those functions const, save compile time
```

Lints: unused imports/members/labels, unnecessary `mut`/`unsafe`/cast, unreachable
statements/arms, dead stores, discarded pure results, redundant casts, owning unions
without `Free`.

### Language server

```sh
super-c lsp                  # stdio JSON-RPC language server
```

Advertised capabilities (`src/lsp/server.spc:capabilities_json`): push diagnostics,
hover, go-to-definition, type definition, implementation, references, document
highlight, rename (with prepare), document formatting, code actions (quick fixes),
completion, signature help, document and workspace symbols, folding ranges, selection
ranges, inlay hints, and semantic tokens (full + range). The VS Code extension is in
`editors/vscode/`.

### Project scaffolding

```sh
super-c new hello            # create a new project directory
super-c init                 # initialize in the current directory
```

### Custom commands

```sh
super-c command bootstrap    # run [command.bootstrap] from build.toml
super-c command profile      # run [command.profile] from build.toml
```

Built-in subcommand names are reserved and cannot be shadowed.

### Bindings and vendoring

```sh
super-c bindgen header.h -o out.spc    # generate .spc bindings from a C header
                                       # (--link=, --header=, -I, --from=, --cflag=, --cc=)
super-c vendor <source>                # vendor a dependency (--dir=, --ref=, --force)
```

## build.toml

The manifest file configures any Super-C project, not just the compiler.

```toml
bin = "super-c"              # output binary name
root = "src/main.spc"        # entry point

[lib]                        # library target (optional; root defaults to src/lib.spc,
type = ["static", "shared"]  # type defaults to static)

[bin.tool]                   # extra binary (optional)
root = "tools/tool.spc"

[command.bootstrap]          # custom command
run = [
    "./super-c build --bootstrap-tags -o stage1-super-c",
    "./stage1-super-c build",
    "rm -rf stage1-super-c",
]

[command.profile]
run = [
    "./super-c bench --no-run",
    "samply record --rate 1000 build/bench-bin",
]
```

### Built-in profiles

| Profile | Character | Use |
|---------|-----------|-----|
| `dev` | `-g -O1` + full ASan/UBSan set, frame pointers | Development (**default**) |
| `debug` | `-g -O0` + sanitizers | Unoptimized debugging |
| `release` | `-O3 -DNDEBUG -flto=auto -fPIE` + section GC, strip | Shipping |
| `bench` | `-O3 -DNDEBUG -g -flto=auto -fno-omit-frame-pointer` (+ PGO ingest when present) | Benchmarking/profiling |
| `pgogen` | `-O2 -fprofile-generate -flto=auto` | PGO profile generation |
| `race` | `-O1 -g -fsanitize=thread -DSC_LOCKDEP` | TSan + lock-order checking |
| `test` | `-O1`, no sanitizers | The `super-c test` runner binary only (the compiler under test keeps the selected profile) |

The exact cc flag strings live in `src/build_system/manifest.spc`; the table shows the
character of each profile, not the verbatim flags. **Never profile the `dev` build** —
sanitizer frames dominate the samples.

### Common flags

| Flag | Effect |
|------|--------|
| `--profile=NAME` | Select build profile |
| `--jobs=N` | Worker count for parallel stages + cc (default: one per CPU) |
| `--out-dir=DIR` | Override output directory |
| `--cc=CMD` | Override C compiler |
| `--cstd=STD` | Replace the manifest's base C flags string, passed verbatim (e.g. `gnu11`) |
| `-o NAME` | Output binary name (`build`/`release`/`bindgen` only, not script mode) |
| `--bin=NAME` | Build/run only that `[bin.NAME]` target |
| `--target=T` | Cross-compile OS: `windows`/`macos`/`linux`/`ios`/`android`/`wasm` |
| `--arch=A` | Cross-compile arch: `x86_64`/`aarch64`/`wasm32` |
| `--bootstrap-tags` | Enable `@platform` bootstrap tag gating |
| `--no-lint` | Disable lint pass |
| `--const-eval-steps=N` | Cap compile-time evaluation steps (~2M default) |
| `--const-eval-memory=SIZE` | Cap compile-time evaluation memory (~96 MiB default) |
| `--lib` | Build as library instead of binary |

## Environment Variables

### Build and caches

| Variable | Effect |
|----------|--------|
| `SC_TIMINGS` | Print a one-line per-phase timing summary |
| `SC_BUILD_STATS` | Append one JSON record per engine build to the named file (`-` = stderr): every phase of the partition in ms, the streamed C compile span apart from it, cache switches, peak RSS at five boundaries (`src/driver/stats.spc`) |
| `SC_BUILD_MEM` | With `SC_BUILD_STATS`: turn the runtime allocation tracker on for the build, so the record carries allocation calls, requested bytes, live bytes and per-phase survivors (slower; never for timing runs). `"mem":{"on":false` = the runtime this compiler links predates the counters (a bootstrap build) |
| `SC_CACHE_DIR` | Override build-record cache directory |
| `SC_NO_CACHE` | Disable the build-record cache |
| `SC_NO_EMIT_CACHE` | Disable the emit stamp |
| `SC_NO_TU_CACHE` | Disable per-TU journal/replay cache |
| `SC_BUILD_MEM_BUDGET` | Cap parallel emission bytes in flight (`64M`, `2G`) |

### Verification (dev gates, each runs only when set)

| Variable | Effect |
|----------|--------|
| `SC_FACTS_CHECK` | Snapshot semantic tables after typecheck; report mutations |
| `SC_CORE_IR` | Re-verify inlined bodies and re-prove bounds-check eliminations |
| `SC_LAYOUT` | Validate pool types against C layout invariants |
| `SC_CEMIT_STATS` | Per-phase wall times, the interpreter body-reuse counters (kept hits, fresh lowerings, retained boxes) and the emission probe table (`src/emit/probe.spc`: ms and calls per region; with `SC_BUILD_STATS` + `SC_BUILD_MEM` also allocation calls and MiB) |
| `SC_INLINE_STATS` | Per-body inliner decision counters |
| `SC_BCE_STATS` | Per-body bounds-check elimination counters |

### LSP

| Variable | Effect |
|----------|--------|
| `SC_LSP_NO_INCR` | Disable incremental per-edit recompilation (full rebuild, parity mode) |
| `SC_LSP_BUDGET_MB` | Bound retained packages (closed-file roots evict first; open docs pinned) |

### Runtime (read by compiled programs)

| Variable | Effect |
|----------|--------|
| `SC_LEAK_CHECK` | Leak/double-free/UAF tracker: any non-`0` value reports at exit; a value starting `f`/`F` (e.g. `fatal`) exits 23 on findings |
| `SC_TASK_TRACE` | Coroutine/task tracing for the life of the process |
| `SC_SCHED_SEED` | Scheduler seed, read only when the program set none itself (deterministic replay) |
| `SC_LOCK_ORDER` | Lock-order inversion checking (`ffi/sc_rt.c`): non-`0` reports; `f`/`F` prefix aborts |
| `SC_TEST_SUPERC` | Path of compiler under test (wasm lane) |

## Two-Stage Bootstrap

The self-hosting contract requires a byte-identical two-generation fixpoint:

```sh
super-c command bootstrap
# 1. Current compiler builds stage1 (with bootstrap tags)
# 2. Stage1 builds stage2 (the new compiler)
# 3. Stage1 is removed
# Any diff between stage1's output and stage2's output is a semantic regression.
```

## Generated Output

`super-c app.spc` (and `super-c build app.spc`) emits the C into `build/raw/`:

```
build/
  raw/
    super_rt.h        # shared runtime (includes + allocation interposition)
    super_rt.c        # leak/double-free tracker (inert unless SC_LEAK_CHECK set)
    __sc_types.h      # shared type definitions for every TU
    __sc_protos.h     # shared extern prototypes
    __sc_inst.c       # shared globals/instances TU
    __ldflags         # linker flags collected from @c.link (one per line)
    .tu_cache         # per-TU journal/replay cache
    app.h  app.c      # one .h/.c per module
    __std/            # demanded prelude modules only
      core.h core.c
      interfaces.h interfaces.c
      str.h str.c
      string.h string.c
```

A manifest build (`super-c build` with `build.toml`) adds per-profile directories next
to `raw/`: emitted C is content-synced into `<out-dir>/<profile>/gen` (unchanged files
keep their mtime), objects compile into `<out-dir>/<profile>/obj` with `-MMD` dep
tracking, and `compile_commands.json` lands beside them. `super-c test` runs the same
engine on the generated test root under the `test` profile: emitted C in `raw-test/`,
objects and the runner in `<out-dir>/test/` (`build/test/__tests`), with the emit stamp
and object cache making an unchanged suite a link check.

Parallel analysis (resolve, typecheck, borrowck, emit frontiers) is used only when the
package holds at least 256 KiB of non-prelude source (`Package::analysis_jobs`,
`loader::PAR_MIN_USER_BYTES`); below that the worker pool costs about as much CPU as the
serial compile and gains a few milliseconds at most, so small compiles run serially and
hand their jobserver slots back. The parallel C compile is unaffected.

Includes are relative — `cc build/**/*.c $(cat build/raw/__ldflags)` builds the whole
tree with no `-I` flags (verified: the tree compiles and runs with bare `clang`).
