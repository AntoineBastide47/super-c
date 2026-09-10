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
statements/arms/branches (after a `return`, an `if` whose two branches both leave, a
`loop` no `break` leaves; the dead branch of a constant condition), constant conditions
(a closed `if`/`while` condition the engine folds: `--fix` folds an `if` statement into
its live branch, drops `while false`, spells `while true` as `loop`; `do { } while
false` is the run-once idiom and is left alone), dead stores, discarded pure results,
redundant casts, owning unions without `Free`.

### Language server

```sh
super-c lsp                  # stdio JSON-RPC language server
```

Advertised capabilities (`src/lsp/server.spc:capabilities_json`): push diagnostics,
hover, go-to-definition, type definition, implementation, references, document
highlight, rename (with prepare), document formatting, code actions (quick fixes),
completion, signature help, document and workspace symbols, folding ranges, selection
ranges, inlay hints, and semantic tokens (full + range). The VS Code extension is in
`editors/vscode/`. Between analysis rounds the server keeps only the open documents' function
bodies (and the bodies the constant engine demanded); a closed module's bodies parse back on
demand (`syntax-ownership.md` in the compiler-internals skill).

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

[profile.fast]               # a profile: optimization level, flags, linker arguments, strip, LTO mode
opt-level = 2                # 0 | 1 | 2 | 3 | "s" | "z": -O<level> on every compile and the link
cflags = ["-DNDEBUG"]        # after the manifest-level cflags and the -O flag
ldflags = ["-static"]        # after the manifest-level ldflags and the -O flag
link-args = ["-dead_strip"]  # each entry reaches the linker as -Wl,<entry>, after ldflags
strip = true
lto = "thin"                 # none | full | auto | thin (see Link-time optimization below)

[profile.release]            # a section naming a built-in profile starts from its values and
opt-level = 2                # overrides only the keys it sets (an array replaces the whole array)
lto = "thin"

[shards]                     # output shard override: module TU count for a module
"driver::emit" = 3           # a chunk lands in shard (stable symbol hash mod count)

[instance-shards]            # instance shard count override per owner module
"__std::vector" = 2
```

The compiler decides shard counts itself from the emitted size, about one shard per
256 KiB of C, and records them in `<gen>/__sc_shards` (`module<TAB>tus<TAB>insts`, one
line per module with more than one shard); the next build reads that file and keeps a
count while every shard stays between half and one and a half times the target, so a
module near a boundary does not flip (a fresh tree splits at the target). A `[shards]` or `[instance-shards]` entry
overrides the count for that module. A shard count is an output schema: changing it
rewrites every shard of that module (the build names the migration); an ordinary source
edit never moves a chunk between shards.

### Built-in profiles

| Profile | Character | Use |
|---------|-----------|-----|
| `dev` | `opt-level = 1`, `-g` + full ASan/UBSan set, frame pointers | Development (**default**) |
| `debug` | `opt-level = 0`, `-g` + sanitizers | Unoptimized debugging |
| `release` | `opt-level = 3`, `-DNDEBUG -fPIE` + section GC, `link-args = ["-O2"]`, strip, `lto = "auto"` | Shipping |
| `bench` | `opt-level = 3`, `-DNDEBUG -g -fno-omit-frame-pointer`, `lto = "auto"` (+ PGO ingest when present) | Benchmarking/profiling |
| `pgogen` | `opt-level = 2`, `-fprofile-generate`, `lto = "auto"` | PGO profile generation |
| `race` | `opt-level = 1`, `-g -fsanitize=thread -DSC_LOCKDEP` | TSan + lock-order checking |
| `test` | `opt-level = 1`, no sanitizers | The `super-c test` runner binary only (the compiler under test keeps the selected profile) |

The exact cc flag strings live in `src/build_system/manifest.spc`; the table shows the
character of each profile, not the verbatim flags. **Never profile the `dev` build** —
sanitizer frames dominate the samples.

### Link-time optimization

A profile's `lto` key selects the mode the engine adds to every compile and to the link:
`none`, `full` (`-flto`), `auto` (`-flto=auto`, what the built-in optimized profiles
use) or `thin` (`-flto=thin`). A profile without the key adds nothing: a `-flto*` in its
flag arrays passes through verbatim. `[profile.release]` with `lto = "thin"` keeps the
built-in flags and switches the mode; `SC_LTO=<mode>` overrides the profile for one
build: `SC_LTO=thin ./super-c build --profile=release` is the incremental release loop.
The mode and the linker cache options are part of every object and link fingerprint, so
changing either relinks; the transpiler never sees them, so the emitted C is identical
under every mode.

`thin` is a request. The engine settles it once per profile directory with a toolchain
probe (`<out-dir>/<profile>/.lto`): the record's key line holds the compiler version,
path and mtime, the target, the compile tail and the link flags; its second line the
linker the `-v` link log named and that executable's mtime; its third the verdict. A
build whose record matches every input runs no probe, so only the first build under a
toolchain and flag set pays for it (about 0.2 s here). The probe compiles and links a one-function program in the argv
form real builds use (`.ltoprobe`, removed afterwards): `-flto=thin` must compile and
link (exit code and output file, never version text), then the link is retried with each
linker cache form (Apple ld's cache path with its prune options, lld's ThinLTO cache
directory with its cache policy, the LLVM gold plugin's cache directory under gold or
bfd; `lto_cache_args` in `src/build_system/build.spc`) until one writes a cache entry.
A rejected request keeps `-flto=auto`, the mode the profiles used before, and the
record and the build statistics (`"lto":"auto","lto_reason":...`) name the reason. GCC
rejects `-flto=thin` at the compile step and so keeps `auto`; a linker that accepts
ThinLTO but no cache directory with a pruning policy links with `-flto=thin` and no
cache (`"lto":"thin"`).

The linker cache lives under the build cache root (`$SC_CACHE_DIR`, else
`~/.super-c/cache`) at `lto/<namespace>`, one namespace per hash of the record's key and
linker lines (compiler, linker, target, flags, schema); `SC_NO_LTO_CACHE=1` links
without it. The linker owns the entries and prunes them itself (entries unused for a
week, the cache under a tenth of the disk, checked at most hourly); the engine only
creates the directory. A namespace a toolchain upgrade leaves behind keeps its last
entries until removed by hand, the same policy as the object cache beside it.

Gates set before the implementation for enabling ThinLTO by default: a body-edit relink
under a quarter of the full-LTO relink, a clean build under 1.1x, the compiler's own
runtime (`super-c bench`, self-transpile) within 3%, link memory no higher, the stripped
binary within 5%. Measured on the compiler's own release build (Apple clang 21, 14
cores, 151 units; `ci/bench_matrix.sh` protocol, object cache and ccache off):

| Case | full LTO (`-flto=auto`) | ThinLTO, no cache | ThinLTO, cache |
|------|------------------------:|------------------:|---------------:|
| clean build, wall / CPU | 22.2 s / 34.7 s | | 5.9 s / 49.7 s (cold cache) |
| link of one private body edit | 18.5 to 19.0 s | 2.9 s | 1.3 s (new state; 100 edits: median 1.31 s, p95 1.37 s), 0.14 s (state linked before) |
| linker peak RSS | 993 MiB | 420 MiB | 79 MiB (warm) |
| link CPU | 18.5 s | 33.6 s | 0.2 s (warm) |
| public signature edit (40 units), total | | | 2.0 s |
| by-value layout edit (92 units), total | | | 5.0 s (cold), 2.4 s |
| stripped binary | 3,163,592 B | | 3,371,912 B (+6.6%) |

| compiler runtime (Mcyc: parse / typecheck / borrowck / codegen) | 118 / 191 / 423 / 892 | | 124 / 192 / 446 / 923 (+4.7 / +0.5 / +5.4 / +3.5%); end to end −3.1% |

Relink, clean build and memory pass by a wide margin; runtime and size do not (a higher
ThinLTO import limit, `-import-instr-limit=300` and `1000`, changes neither by more
than 0.5%), so the built-in profiles keep `auto` and ThinLTO is the validated opt-in:
`SC_LTO=thin` for a session, or `lto = "thin"` under `[profile.release]` in a project
whose binary is not the shipped compiler. The `bench` profile follows `release` so the benchmark measures
the compiler users run, and `ci/perf_gate.sh` holds its runtime within 3%. Script mode
(`super-c release foo.spc`) compiles and links in one command with nothing to relink, so
a `thin` profile keeps `auto` there.

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
| `--bootstrap-tags` | Enable `@platform` bootstrap tag gating; a manifest build also skips build.toml sections and keys this compiler does not know (a previous release building newer source) |
| `--no-lint` | Disable lint pass |
| `--const-eval-steps=N` | Cap compile-time evaluation steps (~2M default) |
| `--const-eval-memory=SIZE` | Cap compile-time evaluation memory (~96 MiB default) |
| `--lib` | Build as library instead of binary |

## Environment Variables

### Build and caches

| Variable | Effect |
|----------|--------|
| `SC_TIMINGS` | Print a one-line per-phase timing summary |
| `SC_BUILD_STATS` | Append one JSON record per engine build to the named file (`-` = stderr): every phase of the partition in ms, the streamed C compile span apart from it, cache switches, the instance re-lowering counts by reason (`"relower"`), peak RSS at five boundaries (`src/driver/stats.spc`) |
| `SC_BUILD_MEM` | With `SC_BUILD_STATS`: turn the runtime allocation tracker on for the build, so the record carries allocation calls, requested bytes, live bytes and per-phase survivors (slower; never for timing runs). `"mem":{"on":false` = the runtime this compiler links predates the counters (a bootstrap build) |
| `SC_CACHE_DIR` | Override the build cache root (objects, and the linker's ThinLTO caches under `lto/`) |
| `SC_NO_CACHE` | Disable the object cache (the linker cache keeps its root) |
| `SC_LTO` | Override the profile's `lto` mode: `none`, `full`, `auto`, `thin` |
| `SC_NO_LTO_CACHE` | Link ThinLTO without the linker cache |
| `SC_NO_EMIT_CACHE` | Disable the emit stamp |
| `SC_NO_TU_CACHE` | Disable per-TU journal/replay cache |
| `SC_BUILD_MEM_BUDGET` | Cap the estimated bytes in flight across the parallel jobs of the type check, the borrow check and the emission (`64M`, `2G`); a job above the whole budget runs alone |
| `SC_TYPE_STATS` | Print the type identity counters per phase and at the end of emission: interning hits and probe steps, foreign lowerings, instance-graph interns, layout cache traffic, the bytes the package type table and the module pools retain, the publication census, and per publication the kept bodies remapped and the time it took (`type-identity.md` in the internals skill) |
| `SC_SYNTAX_STATS` | Print one syntax accounting line per phase (parse, resolve, typecheck, borrowck, emit): node and child counts with the share inside bodies, the retained bytes of nodes, children, resolutions, types, module pools and the other side tables, the source text, and the module that retains the most (`syntax-ownership.md` in the internals skill) |

### Verification (dev gates, each runs only when set)

| Variable | Effect |
|----------|--------|
| `SC_FACTS_CHECK` | Snapshot semantic tables after typecheck; report mutations |
| `SC_CORE_IR` | Re-verify inlined bodies and re-prove bounds-check eliminations |
| `SC_LAYOUT` | Validate pool types against C layout invariants |
| `SC_BORROW_STATS` | Borrow-check probe table (`src/borrowck/flow_ir.spc`): ms, calls and (with `SC_BUILD_STATS` + `SC_BUILD_MEM`) allocations per region (lower, replay, forest, facts, cfg, liveness, moves, solver, rules, emit, setup, decl, reach, drops), skip and elaboration tallies, sizes, the lowered product (Core IR KiB, type slots, replay-tape entries per event kind), the slowest bodies and the retained scratch. Needs `SC_BUILD_STATS`; parallel allocation columns are global counters and mean nothing |
| `SC_BC_VALIDATE` | Validation build: every borrow-check stage the feature predicate skipped runs anyway and must find nothing (zero loans, zero move events, no diagnostic); every loan issues at a borrow operation, every move path has a valid parent, the init rows match the path count, every fixpoint queue stays within its monotone bound; every elaborated body passes the structural verifier and the ownership verifier (`ir::drops::verify_drops`: each value released once per path, guarded where paths disagree, nothing held at a return). A failure prints the body and its events, then aborts. Output is unchanged. The gate runs its fixpoint and worker-identity builds under it |
| `SC_TYPE_VALIDATE` | After every type publication checkpoint, exit 1 if any module table still names a provisional type id. The gate runs its fixpoint and worker-identity builds under it |
| `SC_TYPE_COLLIDE` | Every type and instance hashes to one bucket: the type tables run on full comparisons alone, so a hash-order dependence shows as different output |
| `SC_TASK_DELAY` | A deterministic per-job delay at the start of every parallel item job (type check, borrow check, always-panics), so the worker-identity gates run under a schedule the machine would not produce by itself |
| `SC_TYPE_TABLE` | Path: write the package type table at the end of emission, one line per final id (`id class kind qualifier module payload`, children as final ids); the gate compares the dumps of one worker and every core |
| `SC_CEMIT_STATS` | Per-phase wall times (the unused-item lint as its own phase), the interpreter body-reuse counters (kept hits, fresh lowerings, retained boxes; printed after borrow checking and after the always-panics check) and the instance graph's collect line (records by kind, bodies walked, rounds, a budget stop), the re-lowering census (one line per template: instances, re-lowerings, identical re-lowerings, retained KiB) and the emission probe table (`src/emit/probe.spc`: ms and calls per region, the instance discovery total, re-lowering templates and instances by reason, bodies taken from the keep or lowered, rendered bodies and bytes; with `SC_BUILD_STATS` + `SC_BUILD_MEM` also allocation calls and MiB) |
| `SC_INLINE_STATS` | Per-body inliner decision counters |
| `SC_BCE_STATS` | Per-body bounds-check elimination counters |
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
    __sc_fwd.h        # forward typedefs, enums and declarations shared by every TU
    __sc_registry.c   # ZST sentinels and the reflection registry
    __sc_manifest     # output paths, content hashes, header dependencies, shard counts
    __sc_shards       # the shard counts this build used (read back by the next build)
    __ldflags         # linker flags collected from @c.link (one per line)
    .tu_cache         # per-TU journal/replay cache
    app.h  app.c      # one .h/.c per module (.h: prototypes; app__types.h: its by-value types)
    app__inst.c       # generic instances, glue and constants owned by app
    __std/            # demanded prelude modules only
      core.h core.c
      interfaces.h interfaces.c
      str.h str.c
      string.h string.c
```

A manifest build (`super-c build` with `build.toml`) adds per-profile directories next
to `raw/`: emitted C is content-synced into `<out-dir>/<profile>/gen` (unchanged files
keep their mtime), objects compile into `<out-dir>/<profile>/obj` with `-MMD` dep
tracking, and `compile_commands.json` lands beside them, with the ThinLTO probe record
`.lto` for a profile that requests `lto = "thin"`. `super-c test` runs the same
engine on the generated test root under the `test` profile: emitted C in `raw-test/`,
objects and the runner in `<out-dir>/test/` (`build/test/__tests`), with the emit stamp
and object cache making an unchanged suite a link check.

Parallel analysis (the resolve frontier, the type check, borrow check and always-panics
item jobs, the emission frontier) is used only when the package holds at least 256 KiB of
non-prelude source (`Package::analysis_jobs`,
`loader::PAR_MIN_USER_BYTES`); below that the worker pool costs about as much CPU as the
serial compile and gains a few milliseconds at most, so small compiles run serially and
hand their jobserver slots back. The parallel C compile is unaffected.

Includes are relative — `cc build/**/*.c $(cat build/raw/__ldflags)` builds the whole
tree with no `-I` flags (verified: the tree compiles and runs with bare `clang`).
