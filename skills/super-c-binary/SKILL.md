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
then invokes a gcc-style C driver (cc/clang/gcc; mingw on Windows; MSVC's cl.exe is out
of contract) to produce a native binary. The single binary `super-c` drives every stage
of the workflow.

## Subcommands

### Compile

```sh
super-c app.spc              # compile only: emit the build/ C tree (script mode)
super-c build app.spc -o app # compile + link only, name the binary (default: a.out)
```

A bare `.spc` argument compiles the file (and its transitive imports) and emits a `build/`
tree of `.h`/`.c` files. It links and runs nothing.
Use `super-c build <file.spc> -o <name>` to link a named binary, then run it yourself. Single-file programs
emit plain C names; multi-module programs mangle symbols by module path.

The binary finds `std/` in its own directory or in one of its two parent directories
(`exe_std_dir` in `src/main.spc`: the real executable path, else argv[0]); `ffi/` resolves
beside that `std/`. A copy of the binary with no `std/` near it loses the prelude ("cannot
find type 'Vector'"): run test binaries from the repository root, or put `std/` and `ffi/`
beside the copy. There is no prebuilt `libstd.a`: std compiles from
source into each binary, because monomorphization needs its generic source.

On macOS, a `cp` over a running Mach-O gets the binary killed (SIGKILL) by code signing:
`rm` the target before `cp`, or re-sign it (`codesign -f -s -`). The engine installs the
manifest binary by rename, so `super-c build` is not affected. For a symbolized crash
trace of the dev build, run it under `lldb -b -o run -k "bt 30" -k quit -- <cmd>` (`-b`: batch mode).

### Build system (manifest-driven)

```sh
super-c build                # build from build.toml (dev profile, incremental)
super-c build -o out         # override output binary name
super-c release              # optimized build (release profile; alias for --profile=release)
super-c run                  # build + execute the manifest binary
super-c clean                # remove the out-dir and every <root dir>/build/<profile>/raw (--cache also removes the global build cache); never a user directory
```

The build system reads `build.toml` in the working directory. An emit stamp skips the
entire transpile when no input changed (~25 ms no-op); it records the content hash of the compiler
that emitted the tree (a different compiler at the same path with the same mtime transpiles again,
as does the per-TU cache, keyed on the same hash; a WASI guest hashes the module file its absolute
argv[0] names, as `wasmtime run --dir=/ --argv0 <abs path>` gives it, and keeps neither stamp nor
cache when argv[0] is relative), the loaded module files and
the `.spc` listing of every directory the loader searched, so a new file that would shadow an
import also makes the stamp stale. The stamp lives in the target's profile directory, so it
is per profile. A build that transpiles deletes the stamp first; the emission writes its record to
`.emit_stamp.new`, and the engine moves it into place only after the whole tree is synced into
`gen/`, so a build that stops part way leaves no stamp for a mixed tree. Parallel C compilation uses
content-fingerprinted stale detection with longest-job-first scheduling.

### External transpiler

```sh
super-c build --target=wasm --profile=release -o gen2.wasm \
    --transpiler="wasmtime run --dir=/ --argv0 /abs/gen1.wasm -- /abs/gen1.wasm"
```

`--transpiler=CMD` (`build` and `release` from build.toml only) runs CMD as the transpile step in
place of the engine's own frontend; the engine then syncs, compiles and links that tree with all its
own target and profile flags, object cache and link record. CMD is split on whitespace like every
command string of the engine and runs with no shell, so its words hold no space. The engine appends the
transpile form, each argument one argv entry:

```sh
CMD <root> --emit-sub=<sub> --manifest-dir=<abs project dir> --out-dir=<out-dir> --profile=<p> \
    --target=<t> --arch=<a> [--target-feature=<list>] [--bootstrap-tags] [--no-lint] \
    [--const-eval-steps=N] [--const-eval-memory=N] [--emit-id=<id>]
```

`super-c <root> --emit-sub=SUB ...` (`bsys::manifest_emit`) enters the project directory, reads its
build.toml (shards, profiles, the root's directory), and writes `<out-dir>/SUB/raw` exactly as the
engine's own frontend does, the same bytes for the same compiler; with `--emit-id` it writes the stamp
record under that identity. The directory is absolute because a WASI guest starts in `/`. The stamp
identity of an external transpiler (`transpiler_id`) hashes the words of CMD and the content of each
word that names a file, the program found through PATH: a different transpiler, or new content at the
same path (a rebuilt `.wasm`), transpiles again, and so does a switch back to the engine's own frontend.
A transpiler that exits nonzero fails the build: its own diagnostics print on the inherited stderr,
then `build: transpiler failed (exit N): <argv>`. The wasm self-host fixpoint in the release and debug
workflows uses this: WASI has no processes, so the wasm compiler cannot run the C compiler itself.

### Testing

Always pass `--quiet` (only the failures and the tally print; failed tests replay
their captured output regardless). Drop it only to watch a passing test's output
under `--test-no-fork`.

```sh
super-c test --quiet                   # the standard form: discover tests/**/*.spc, build, run
super-c test --quiet --filter=parse  # substring match on test name; builds only the matching files
super-c test --quiet --test-shard=1/4  # one-based CI sharding, balanced by tests/durations.tsv
super-c test --quiet --test-record-durations  # refresh tests/durations.tsv from this run
super-c test --quiet --test-jobs=8     # bound the fork pool (default: one per core)
super-c test --quiet --test-timeout=120 # fail a test that runs past 120 s (default 90, 0: none)
super-c test --test-no-fork            # in-process (for debuggers; should_panic skipped)
super-c --test --quiet app.spc         # single-file form (same --test-* and --filter flags apply)
```

Each `@test` function runs in a forked child. `@test_init` provides fixtures;
`@test(should_panic)` passes only when the body aborts; `@test(timeout = N)` overrides the
run's `--test-timeout` for one test (the two combine: `@test(should_panic, timeout = 5)`), and a
test past its timeout fails as timed out with a dump of every thread's stack (super-c-testing,
"Timeouts"). Each child's output is captured
and replayed only for failed tests, in a `failures:` section after the run (one header per
failed test, its output, how the process ended, then the list of failed names).
`--test-no-fork` captures nothing.

### Benchmarking

```sh
super-c bench                # generate a runner over bench/'s @bench fns, build, run
super-c bench --no-run       # build only (for profiler attachment; binary: build/bench-bin)
super-c bench --filter=S     # build and run only benchmarks whose name contains S
super-c command profile      # build then run under samply (if [command.profile] defined)
```

`super-c bench` writes an import-only root covering every `.spc` under `bench/` and
collects the `pub @bench` functions that `@platform` and `@arch` keep for the target
(`@bench` applies to top-level functions only). `--filter=S` keeps in the generated runner
only the benchmarks whose name (`<module>::<fn>` without the `bench::` prefix) contains S,
so only their files build; `build/bench-bin --filter=S` selects among the built ones at
run time. `tests/` and `bench/` sit beside `src/` at the project
root. A bench file that imports the program's root module links a second `main`
(duplicate `__sc_user_main`): put the code under benchmark in a module other than the
root. The generated runner carries the checkout's identity
(the short commit, `-dirty` when tracked files differ, `unknown` without version
control) and prints it as `running benchmarks (build <id>)`. The filter is forwarded to the
bench binary as a run-time argument, so a filtered run never relinks; a filter that
selects no benchmark exits nonzero, and so does any benchmark that calls
`bench::fail`. The compiler's own transpile bench (`self_transpile`) runs 100 serial
rounds of the transpile step a `super-c build` runs (`build_system::build::root_transpile`,
one worker, into a fresh scratch tree) and samples CPU time, cycles and allocations at the
build's own phase boundaries (`driver::stats::set_hook`), so its phases are the build's:
stamp, parse (load, lex and parse), resolve, typecheck, borrowck, checks, prepare, plan,
render and publish, plus a lexer-only pass reported as a share of parse. It prints
per-phase averages (CPU ms, Mcyc, Kalloc, MiB), throughput, the min/median/p95/sd of CPU
ms, Mcyc and wall ms over the rounds, heap requested per round and peak RSS; then it runs
one cold build of the compiler through the real build engine (dev profile, every core,
object cache, emit stamp and ccache off) and reports the engine's phase record, sync,
compile and link included. A C compiler or linker failure there fails the run and keeps
the scratch tree. `SC_BENCH_OUT=<file>` writes the whole record as JSON (schema `"v":2`,
`CONTRACT_BENCH_V` in `ci/contract.sh`).

### Gates

```sh
super-c command gate         # ci/gate.sh: the full correctness gate (contract ci/contract.sh)
super-c command perf         # ci/perf_gate.sh: the 100-round performance gate against the resolved limits
super-c command matrix       # ci/bench_matrix.sh: the whole-build benchmark matrix (tens of minutes)
sh ci/ledger.sh <base> <c>.. # the accepted-work ledger: one protocol over a chain of commits
```

`ci/contract.sh` is the versioned compatibility contract: every input file, option and
command the gates use. `ci/baseline.env` holds the accepted baseline constants
(`SC_PERF_RECORD=1 sh ci/perf_gate.sh` rewrites it). `ci/ledger.tsv` is the
accepted-work ledger: every accepted change measured against its parent under one
protocol (`ci/ledger.sh`: the released bootstrap compiler builds each commit's benchmark
binary, which runs the 100-round lane), one row per metric with the improvement and the
regression the change was accepted with. The perf gate resolves each constant's limit
from them (the baseline less the accepted improvements plus the accepted regressions,
applied to the constant as a ratio), holds the frontend cycles within 105 percent of the
baseline, and allows `SC_PERF_TOL` percent of noise over a limit. `ci/cutover_report.md`
records the resolved numbers of the last cutover.

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
false` is the run-once idiom and is left alone; a condition over a build constant such as
`PLATFORM` or `PROFILE` is a deliberate switch and never reported), dead stores, discarded
pure results, redundant casts, owning unions without `Free`. A module whose code the
platform filter removed (a build-constant `if` or `switch`) skips the lints that count
uses or reachability, as a module with `@platform` or `@arch` items skips the unused-import
and unused-member lints.

`print`, `println`, `eprint` and `eprintln` are prelude functions (`std/string.spc`) the
compiler lowers itself, so an `import stdio;` used only for printing is unused. The
unused-`pub` lint runs only where no external caller can exist: `super-c lint` of a project
with `src/` whose `build.toml` declares no `[lib]`, and a script build with no `build.toml`
in the working directory (`src/main.spc`); it never applies to std or ffi
modules (`lint_pub_applies` in `src/driver/emit.spc`). `--const` never suggests prelude
functions: a const prelude function turns a failed fold into an error in every downstream
program (`cs_check_fn` in `src/driver/emit.spc`).

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
demand (`syntax-ownership.md` in the compiler-internals skill). The server handles one message
at a time over a reader on its descriptor: a `didChange` folds every `didChange` already
waiting into its round, so a superseded buffer is never analyzed; every `publishDiagnostics`
for an open document carries the `version` it analyzed.

To measure server memory, drive a scripted session (`initialize`, `didOpen`, a loop of
`didChange`) and sample `ps -o rss= -p <pid>`; `SC_LSP_STATS` shows what each round retains.

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

`vendor` copies a dependency into `<root>/vendor/<name>` (`vendor_dep` in
`src/build_system/build.spc`). A git source (a scheme, `git@`, or a `.git` suffix) gets a
full clone that includes its submodules; `--ref` checks out a branch, tag or commit, and the
submodules follow it; then every `.git` entry is removed, at every level. A local directory is
copied without any `.git` entry.
`vendor/<name>/.vendor` records the source and, for git, the commit. The manifest records
nothing: `import vendor::<name>::<module>;` resolves by path.

## build.toml

The manifest file configures any Super-C project, not just the compiler.

```toml
bin = "super-c"              # output binary name
root = "src/main.spc"        # entry point
target-features = []         # CPU features (see CPU features below)

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

[command.profile]           # a command's `env` entries are set in the process environment, never as a shell prefix
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
overflow-checks = false      # integer overflow wraps instead of trapping (default: checks at opt-level 0/1)
target-features = ["+simd128"] # replaces the build-level list for this profile

[profile.release]            # a section naming a built-in profile starts from its values and
opt-level = 2                # overrides only the keys it sets (an array replaces the whole array)
lto = "thin"

[shards]                     # output shard override: module TU count for a module
"driver::emit" = 3           # a chunk lands in shard (stable symbol hash mod count)

[instance-shards]            # instance shard count override per owner module
"__std::vector" = 2
```

The compiler decides shard counts itself from the emitted size, about one shard per
256 KiB of C, and records them in `raw/__sc_shards` (`module<TAB>tus<TAB>insts`, one
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
| `bench` | `opt-level = 3`, `-DNDEBUG -g -fno-omit-frame-pointer`, `lto = "auto"` (+ PGO ingest of `<out-dir>/pgo.profdata` when that file exists) | Benchmarking/profiling |
| `pgogen` | `opt-level = 2`, `-fprofile-generate`, `lto = "auto"` | PGO profile generation |
| `race` | `opt-level = 1`, `-g -fsanitize=thread -DSC_LOCKDEP` | TSan + lock-order checking |
| `test` | `opt-level = 1`, no sanitizers | The `super-c test` runner binary only (the compiler under test keeps the selected profile) |

The exact cc flag strings live in `src/build_system/manifest.spc`; the table shows the
character of each profile, not the verbatim flags. **Never profile the `dev` build**:
sanitizer frames dominate the samples.

Integer overflow (signed and unsigned) traps under `dev`, `debug`, `test` and `race` and wraps under
`release`, `bench` and `pgogen` (language skill, `operations.md`). The
emitted C is the same under every profile: it calls the arithmetic helpers of `super_rt.h`
(std's `Int<N>` and `UInt<N>` operators call `sc_int_overflow` from std's `int128.h`), and the engine adds `-DSC_ARITH_WRAP` to every compile of a profile without overflow checks
(`Profile::arith_wraps`: the `overflow-checks` key, else `opt-level` 2, 3, `"s"` or `"z"`;
`push_profile_side` in `src/build_system/build.spc`). A build with no profile (`super-c build
foo.spc`) checks. Every C compile of the generated tree, under every profile and target, also
gets `-funsigned-char`: the language's `char` is unsigned, and `super_rt.c` fails to compile
without the flag. It also gets `-ffp-contract=off`, so the C compiler never fuses a float
multiply and add (only an explicit `fma` fuses) and run-time float results equal the constant
evaluator's on every target, and `-Werror=incompatible-pointer-types`, so clang rejects the
incompatible pointer arguments gcc 14 already rejects (`@c.source` files included). The `cstd`
key and `--cstd` replace only the standard and feature-macro flags, never these three.

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

`thin` is a request. The engine settles it once per profile directory with the `thin-lto`
probe of the toolchain probe table (below): its line in `<out-dir>/<profile>/.probes`
holds the verdict (`thin <cache form>` or `auto: <reason>`), then the linker the `-v` link
log named and that executable's mtime. A build whose record matches every input runs no
probe, so only the first build under a toolchain and flag set pays for it (about 0.2 s
here). The probe compiles and links a one-function program in the argv
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
`~/.super-c/cache`) at `lto/<namespace>`, one namespace per hash of the compiler version,
path and mtime, the target, the compile and link flags, the schema and the linker line;
`SC_NO_LTO_CACHE=1` links
without it. The linker owns the entries and prunes them itself (entries unused for a
week, the cache under a tenth of the disk and, with lld or gold, under 1 GiB; checked at
most hourly); the engine creates the directory. The cache sweep (below) removes a
namespace with no entry written or used for a week, such as the one a toolchain upgrade
leaves behind.

The object cache lives under the same root at `o/<namespace>`, one namespace per local
object tree (hash of the real path of the profile directory, such as `build/dev`); a
unit's key hashes the compiler version line, the whole compile command, and the text of
the unit and of every quoted include (the emitted headers name the runtime and extern-block
headers by absolute path, so a unit that includes a tree's own header gets other keys in a
tree at another path). Each unit's `.cmd` records its key. Under `-g` the compile maps the
working directory to `.` (`-fdebug-prefix-map`, outside the key), so debug information names
sources relative to the project directory: a debugger started elsewhere needs a source map.
Without coverage or profile instrumentation, each compiled object whose bytes do not name the
working directory also goes to the shared `script` namespace, and a miss in the tree's
namespace reads it there: trees that emit a unit identically (the runtime of every test
fixture) compile it once.
After a successful build, the engine writes the key set of all units as generation file
`g<seq>` when the set changed, keeps the newest four generations (the current build and
three older), and deletes each object and dependency list that no kept generation names
and that is older than the start of the build. A version inside that window rebuilds
with no compile; an older one compiles again. An unchanged build reads one directory
and one file. The namespace's `owner` file records its object tree (the profile directory).
At most once every two hours (`o/.sweep`), a successful build also removes the namespaces
whose owner object tree is gone, whose `owner` names another directory (an older compiler
recorded the source directory), that have no `owner` and did not change for an hour (a build
that stopped before its first commit), or that did not change for 30 days (the shared `script`
namespace only by this rule); the idle linker caches; and the flat `<key>.o`/`<key>.d` files
that compilers before namespaces installed in the root. `super-c clean --cache` removes the whole root.

Script builds (`super-c build foo.spc -o out`, `super-c --test foo.spc`) share one
namespace, `o/script`, keyed per unit by the compiler version line, the compile flags, the
unit's path relative to its tree and the text of the unit and its quoted includes (the
tree's path joins the key only under `-g`, coverage or profile instrumentation), so the
runtime and std units that programs emit identically compile once. A hit copies the object
into `<tree>/../obj`, which the link reads. The units to compile run as few `cc -c`
commands as the process tree's free worker slots allow, all at once, each from a scratch
directory whose objects then move into place; a unit whose file name another one shares, or
every unit when a compiler or flag word names a relative path, compiles alone with `-o`.
The version probe runs beside the compiles when the namespace is new. An install writes a
temp file and renames it, so concurrent builds never read a torn object. A build that installed an object trims the namespace to 3072 objects, least
recently used first, once it holds more than 4096. `SC_NO_CACHE` restores the single
compile-and-link command.

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
(`super-c release foo.spc`) links once with no link record to relink against, so a `thin`
profile keeps `auto` there.

### Toolchain probes

The probe table (`src/build_system/probe.spc`) records what the C compiler and linker
accept under a build's target and flags. Each probe has an id, a C snippet or a flag, a
step (`compile` with `-c`, `link` with the build's link flags, `asm` with `-S`, or the
engine's `lto` procedure) and a result kind: `accepted`/`rejected`, the first accepted
spelling of a list, the form of a 16-byte compare-exchange (`inline` when the assembly
holds `cmpxchg16b`, `casp*` or an `ldxp`/`stxp` loop; `outline call` for libgcc's
`__aarch64_cas16_*`; `library call` for libatomic's `__atomic_compare_exchange_16`), or the
ThinLTO verdict. A probe the target or instruction set does not take reports `not
applicable` and never runs. Each step is an argv child of the compiler driver with the
build's compile flags (no shell); exit codes, output files and assembly text decide,
never version text.

| Id | Applies to | Result |
|----|------------|--------|
| `add-overflow` | all | `__builtin_add/sub/mul_overflow` accepted |
| `fp-contract-off` | all | `-ffp-contract=off` accepted |
| `target-attr-x86_64` | x86_64 | the `target("...")` spelling that enables AVX2: `avx2` or `arch=haswell` |
| `target-attr-aarch64` | aarch64 | the spelling that enables i8mm: `+i8mm`, `arch=armv8.6-a` or `i8mm` |
| `march-x86-64-v2`, `-v3`, `-v4` | x86_64 | `-march=x86-64-vN` accepted |
| `wasm-simd128`, `wasm-relaxed-simd` | wasm32 | `-msimd128` (`-mrelaxed-simd`) with `<wasm_simd128.h>` accepted |
| `cas16` | all | the 16-byte `__atomic_compare_exchange_n` form |
| `thread-local` | all | `_Thread_local` accepted |
| `cpuid-count` | x86_64 | `<cpuid.h>` `__get_cpuid_count` accepted |
| `getauxval`, `at-hwcap2`, `at-hwcap3` | Linux and Android aarch64 | `getauxval` links; each `AT_HWCAP*` constant compiles |
| `thin-lto` | all | the ThinLTO verdict (Link-time optimization above) |

The results of one profile directory live in one record, `<out-dir>/<profile>/.probes`:
its first line holds the schema, a hash of the compiler path and mtime, the target, the
instruction set and the compile and link flags, then the compiler version line; each
other line is `<id>\t<result>` (the `thin-lto` line adds the linker path and mtime). A
record of another key holds nothing; one of another compiler version loses its results
once the version probe answers. A probe runs only when a build needs its result and the
record does not hold it: the needed probes start beside the compiler version probe,
before the transpile, one child per spelling, all at once. A build that measured nothing
leaves the record unchanged. The results a build used end every object and link
fingerprint (` | probes <id>=<result>;`). A build uses the `thin-lto` verdict under `lto =
"thin"`, and the probe of each CPU feature it enables that has one (`wasm-simd128`,
`wasm-relaxed-simd`); a rejected feature probe fails the build before any compile ("build:
the C compiler 'cc' rejects '-msimd128': target feature 'simd128' needs a compiler that
supports it"). The emitted C uses no probe result, so the emit stamp holds none.

```sh
super-c build --print-probes                    # the table for the dev profile and the host target
super-c build --print-probes --profile=release  # under the release flags
```

`--print-probes` (`build` and `release` from build.toml) prints `compiler: <version line>`,
`target: <platform> <arch>`, then one `<id> <result>` row per probe in table order, with the
ids padded to 24 columns. It runs every applicable probe the record does not hold, the
ThinLTO procedure included, adds the results to the record, and builds nothing.

### CPU features

A CPU feature lets the compiler select instructions of an instruction-set extension. It
never changes a program's results: a vector operation gives the same lanes and the same
traps with and without it. The table is `src/ir/cpu_features.spc` (`CPU_FEATURES`), mirrored
by `std::cpu::Feature`:

| Name | Instruction set | Implies | C flag | Probe | Default |
|------|-----------------|---------|--------|-------|---------|
| `simd128` | wasm32 | | `-msimd128` | `wasm-simd128` | off |
| `relaxed-simd` | wasm32 | `simd128` | `-mrelaxed-simd` | `wasm-relaxed-simd` | off |
| `sse2` | x86_64 | | | | always on |
| `neon` | aarch64 | | | | always on |

A build starts from its instruction set's baseline (the rows that are always on), applies
the build.toml `target-features` list (a profile's list replaces the build-level one), then
the `--target-feature=L` list (repeated flags join in order). Each list item is `+name` or
`name` (enable) or `-name` (disable), applied in order; the implications close the set
after the last item. An unknown name is an error before anything builds ("unknown target
feature 'avx2' for wasm32; the wasm32 features are: simd128, relaxed-simd"), and so is a
baseline feature disabled ("target feature 'sse2' is part of every x86_64 build"). A
build.toml list may name features of several instruction sets: a build skips the others';
on the command line another instruction set's feature is an error ("no target feature
'neon' for wasm32; .."). The set adds each enabled feature's C flag to every compile, after
its probe accepted it (a build without a manifest probes too), is part of every object
fingerprint, of the emit stamp and of the per-unit cache key (a changed set emits and
compiles every unit again), and selects the `@simd_impl` entries the vector planner may
use; a build with no feature loads no backend file. A function with `@target_feature` is callable only from a build, or a function, that
holds its features.

```sh
super-c build --target=wasm --target-feature=+simd128
super-c build --target=wasm --target-feature=+relaxed-simd   # simd128 too
```

### Common flags

| Flag | Effect |
|------|--------|
| `--profile=NAME` | Select build profile (also the value of `PROFILE`; a bare build without it reports `dev`) |
| `--jobs=N` | Worker count for parallel stages + cc (default: one per CPU) |
| `--out-dir=DIR` | Override output directory (a bare `build file.spc` emits under `DIR/<profile>/raw`) |
| `--cc=CMD` | Override C compiler (manifest and bare builds alike) |
| `--cstd=STD` | Replace the manifest's base C flags string, passed verbatim (e.g. `gnu11`) |
| `-o NAME` | Output binary name (`build`/`release`/`bindgen` only, not script mode) |
| `--bin=NAME` | Build/run only that `[bin.NAME]` target |
| `--transpiler=CMD` | `build`/`release` from build.toml: run CMD as the transpile step (see External transpiler above) |
| `--print-probes` | `build`/`release` from build.toml: print the toolchain probe table for the target and profile (see Toolchain probes above) |
| `--target=T` | Cross-compile OS: `windows`/`macos`/`linux`/`ios`/`android`/`wasm` (the value of `PLATFORM`). `wasm` builds with `$WASI_SDK_PATH`'s clang and sysroot (else `$WASI_SYSROOT`), links an 8 MiB stack placed first, and strips at link time |
| `--arch=A` | Cross-compile arch: `x86_64`/`aarch64`/`wasm32` (the value of `ARCH`) |
| `--target-feature=L` | CPU features, a comma list of `+name`/`-name` applied after build.toml's `target-features` (see CPU features above) |
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
| `SC_CACHE_DIR` | Override the build cache root (objects under `o/`, the linker's ThinLTO caches under `lto/`) |
| `SC_NO_CACHE` | Disable the object cache (the linker cache keeps its root) |
| `SC_LTO` | Override the profile's `lto` mode: `none`, `full`, `auto`, `thin` |
| `SC_NO_LTO_CACHE` | Link ThinLTO without the linker cache |
| `SC_NO_EMIT_CACHE` | Disable the emit stamp |
| `SC_NO_TU_CACHE` | Disable per-TU journal/replay cache |
| `SC_BUILD_MEM_BUDGET` | Cap the estimated bytes in flight across the parallel jobs of the type check, the borrow check and the emission (`64M`, `2G`); a job above the whole budget runs alone; a value that is not digits plus one optional K/M/G suffix, or that overflows, is a fatal error |
| `SC_TYPE_STATS` | Print the type identity counters per phase and at the end of emission: interning hits and probe steps, foreign lowerings, instance-graph interns, layout cache traffic, the bytes the package type table and the module pools retain, the publication census, and per publication the kept bodies remapped and the time it took (`type-identity.md` in the internals skill) |
| `SC_SYNTAX_STATS` | Print one syntax accounting line per phase (parse, resolve, typecheck, borrowck, emit): node and child counts with the share inside bodies, the retained bytes of nodes, children, resolutions, types, module pools and the other side tables, the source text, and the module that retains the most (`syntax-ownership.md` in the internals skill) |

### Verification (dev gates, each runs only when set)

| Variable | Effect |
|----------|--------|
| `SC_FACTS_CHECK` | Snapshot semantic tables after typecheck; report mutations |
| `SC_CORE_IR` | Re-verify inlined bodies and re-prove bounds-check eliminations |
| `SC_LAYOUT` | Validate pool types against C layout invariants |
| `SC_BORROW_STATS` | Borrow-check probe table (`src/borrowck/flow_ir.spc`): ms, calls and (with `SC_BUILD_STATS` + `SC_BUILD_MEM`) allocations per region (lower, replay, forest, facts, cfg, liveness, moves, solver, rules, emit, setup, decl, reach, drops), skip and elaboration tallies, sizes, the lowered product (Core IR KiB, type slots, replay-tape entries per event kind), the slowest bodies and the retained scratch. Needs `SC_BUILD_STATS`; parallel allocation columns are global counters and mean nothing |
| `SC_BC_VALIDATE` | Validation build: every borrow-check stage the feature predicate skipped runs anyway and must find nothing (zero loans, zero move events, no diagnostic); every loan issues at a borrow operation, every move path has a valid parent, the init rows match the path count, the liveness queue stays within its tight bound; every elaborated body passes the structural verifier and the ownership verifier (`ir::drops::verify_drops`: each value released once per path, guarded where paths disagree, nothing held at a return). A failure prints the body and its events, then aborts. Output is unchanged. The gate runs its fixpoint and worker-identity builds under it |
| `SC_TYPE_VALIDATE` | After every type publication checkpoint, exit 1 if any module table still names a provisional type id. The gate runs its fixpoint and worker-identity builds under it |
| `SC_TYPE_COLLIDE` | Every type and instance hashes to one bucket: the type tables run on full comparisons alone, so a hash-order dependence shows as different output |
| `SC_TASK_DELAY` | A seed: a deterministic per-job delay (100 to 400 us, a hash of the job and the seed) at the start of every parallel item job (type check, borrow check, always-panics), so the worker-identity gates run under schedules the machine would not produce by itself, a different one per seed |
| `SC_TYPE_TABLE` | Path: write the package type table at the end of emission, one line per final id (`id class kind qualifier module payload`, children as final ids); the gate compares the dumps of one worker and every core under each delay seed |
| `SC_CEMIT_STATS` | Per-phase wall times (the unused-item lint as its own phase), the interpreter body-reuse counters (kept hits, fresh lowerings, retained boxes; printed after borrow checking and after the always-panics check) and the instance graph's collect line (records by kind, bodies walked, rounds, a budget stop), the re-lowering census (one line per template: instances, re-lowerings, identical re-lowerings, retained KiB) and the emission probe table (`src/emit/probe.spc`: ms and calls per region, the instance discovery total, re-lowering templates and instances by reason, bodies taken from the keep or lowered, rendered bodies and bytes; with `SC_BUILD_STATS` + `SC_BUILD_MEM` also allocation calls and MiB) |
| `SC_INLINE_STATS` | Per-body inliner decision counters |
| `SC_BCE_STATS` | Per-body bounds-check elimination counters (`BceStats`): checks and range checks seen and removed, coalesced, folded, signature crossings, and the kept checks per reason (six reason columns, `BR_WIDENED` the last) |
| `SC_BCE` | `0` turns bounds-check elimination off: every check stays (the generator's BCE differential oracle) |
| `SC_BCE_DISABLE` | A list of BCE rules to turn off, matched by substring: `fold` (folded panic guards), `sig` (signature facts), `int` (the interval facts of `ir/facts.spc`) |
| `SC_SIMD_SCALAR` | `1`: the vector planner uses no `@simd_impl` entry; every vector operation keeps its lane loop (the entry differential oracle) |
| `SC_SIMD_TRACE` | Print each vector operation for which `simd_plan` finds no single entry (`simd: no native entry for <Op> on <T>xN: chunks` or `the lane loop`) |
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

`super-c app.spc` (and `super-c build app.spc`) emits the C into `build/<profile>/raw/`
(`build/dev/raw/` without `--profile`): `PROFILE` makes the emitted C depend on the profile,
so every profile has its own tree, per-TU cache, manifest and orphan pruning, and switching
profiles never mixes trees. A program that does not read `PROFILE` emits the same C under
every profile.

```
build/
  dev/raw/
    super_rt.h        # shared runtime (includes, arithmetic helpers, allocation interposition)
    super_rt.c        # leak/double-free tracker (inert unless SC_LEAK_CHECK set)
    __sc_fwd.h        # runtime and extern-block includes, dyn/extern declarations shared by every TU
    __sc_registry.c   # ZST sentinels and the reflection registry
    __sc_manifest     # output paths, content hashes, header dependencies, shard counts
    __sc_shards       # the shard counts this build used (read back by the next build)
    __ldflags         # linker flags collected from @c.link (one per line)
    .tu_cache         # per-TU journal/replay cache
    app.h  app.c      # one .h/.c per module (.h: prototypes)
    __sc_t/           # one definition header per type (app__Point.h: typedef, definition, layout check)
    app__inst.c       # generic instances, glue and constants owned by app
    __std/            # demanded prelude modules only
      core.h core.c
      interfaces.h interfaces.c
      str.h str.c
      string.h string.c
```

A manifest build (`super-c build` with `build.toml`) works in one directory per target and
profile: `<out-dir>/<profile>` for the main binary, `<out-dir>/<profile>-bin-NAME` and
`<out-dir>/<profile>-lib` for the other targets. The emitter writes `raw/` there (the
per-TU cache and `__sc_manifest` with it), the emitted C is content-synced into `gen/`
(unchanged files keep their mtime), objects compile into `obj/` with `-MMD` dep tracking,
and `compile_commands.json` and the emit stamp `.emit_stamp` land beside them, with the
toolchain probe record `.probes` once a build or `--print-probes` measured a probe. `super-c test`
runs the same engine on the generated test root under the `test` profile in
`<out-dir>/test/` (`raw/`, `gen/`, `obj/`, the runner `__tests`), with the emit
stamp and object cache making an unchanged suite a link check; `super-c bench` uses
`<out-dir>/bench/<profile>/`. Engine code takes every manifest output path from out-dir
(the `out-dir` key or `--out-dir`, default `build`) and never spells `build/`. The bare
`super-c <root.spc>` tree under `<root dir>/build/<profile>/raw` is the one exception.

Parallel analysis (the resolve frontier, the type check, borrow check and always-panics
item jobs, the emission frontier) is used only when the package holds at least 256 KiB of
non-prelude source (`Package::analysis_jobs`,
`loader::PAR_MIN_USER_BYTES`); below that the worker pool costs about as much CPU as the
serial compile and gains a few milliseconds at most, so small compiles run serially and
hand their jobserver slots back. The parallel C compile is unaffected.

Includes are relative: `cc -funsigned-char -ffp-contract=off build/dev/raw/**/*.c $(cat build/dev/raw/__ldflags)`
builds the whole tree with no `-I` flags (verified: the tree compiles and runs with bare `clang`;
add `-DSC_ARITH_WRAP` for wrapping integer overflow).
