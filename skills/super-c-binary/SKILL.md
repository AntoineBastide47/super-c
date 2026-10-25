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

Super-C is a self-hosting compiler that transpiles `.spc` source to readable C11,
then invokes a gcc-style C driver (cc/clang/gcc; mingw on Windows; MSVC's cl.exe is out
of contract) to produce a native binary. On macOS arm64, Linux x86-64, Linux arm64, Windows x86-64 and
wasm32, a linking build with unoptimized C flags (the debug profile, a script build) and no sanitizer
compiles each module to a Mach-O, ELF, COFF or wasm object itself and uses C only for the modules it cannot compile; the build prints `native: N of M modules through C`
when N is not 0 (`SC_NATIVE` overrides the choice). A Windows x86-64 build whose assembler takes
`-Wa,-muse-unaligned-vector-move` (GNU as 2.38+; the `unaligned-vector-move` probe) passes it
to every compile and the link: mingw GCC moves 32- and 64-byte stack vectors with aligned
instructions on a 16-byte-aligned stack (GCC PR54412), and AVX code faults without it. The single binary `super-c` drives every stage
of the workflow.

## Subcommands

### Compile

```sh
super-c app.spc              # compile only: emit the build/ C tree (script mode)
super-c build app.spc -o app # compile + link only, name the binary (default: a.out)
```

A bare `.spc` argument compiles the file (and its transitive imports) and emits a `build/`
tree of `.h`/`.c` files. It links and runs nothing.
Use `super-c build <file.spc> -o <name>` to link a named binary, then run it yourself. A single-file build
takes every option of its built-in profile (`--profile=release` or `super-c release file.spc` strips the
binary, as a manifest build does); a profile with other options needs a `build.toml`. Single-file programs
emit plain C names (a name that a prelude item also has gains `_`: `format` becomes `format_`);
multi-module programs mangle symbols by module path.

The binary finds `std/` in its own directory or in one of its two parent directories
(`exe_std_dir` in `src/main.spc`: the real executable path, else argv[0]), or where a non-empty
`SC_STD_DIR` names it; `ffi/` resolves beside that `std/`. A copy of the binary with no `std/`
near it loses the prelude ("cannot find type 'Vector'"): run test binaries from the repository
root, set `SC_STD_DIR`, or put `std/` and `ffi/` beside the copy. There is no prebuilt `libstd.a`: std compiles from
source into each binary, because monomorphization needs its generic source.

On macOS, a `cp` over a running Mach-O gets the binary killed (SIGKILL) by code signing:
`rm` the target before `cp`, or re-sign it (`codesign -f -s -`). The engine installs the
manifest binary by rename, so `super-c build` is not affected. For a symbolized crash
trace of the debug build, run it under `lldb -b -o run -k "bt 30" -k quit -- <cmd>` (`-b`: batch mode).
A fixed-array value parameter shows as `__sc_ap<N>` there (`super-c-compiler-internals`).

### Build system (manifest-driven)

```sh
super-c build                # build from build.toml (debug profile, incremental)
super-c build --sanitizers   # the same with AddressSanitizer and UndefinedBehaviorSanitizer
super-c build -o out         # override output binary name
super-c build app -o out-app # build the project of directory app (its build.toml); -o stays the caller's path
super-c build --bin=tool -o t # link the [bin.tool] target at t (an unknown name is an error; --lib with -o is one too)
super-c release              # optimized build (release profile; alias for --profile=release)
super-c run                  # build + execute the manifest binary
super-c clean                # run the project's sweeps now and delete every unused object (see the object cache below)
super-c clean --full         # remove the out-dir, every <root dir>/build/<profile> tree and the project's cache root; never a user directory
```

The build system reads `build.toml` in the working directory. An emit stamp skips the
entire transpile when no input changed (~25 ms no-op); it records the content hash of the compiler
that emitted the tree (a different compiler at the same path with the same mtime transpiles again,
as does the per-TU cache, keyed on the same hash; a WASI guest hashes the module file its absolute
argv[0] names, as `wasmtime run --dir=/ --argv0 <abs path>` gives it, and keeps neither stamp nor
cache when argv[0] is relative), the std directory (a build under another std tree transpiles
again, `stamp_opt_line`), the loaded module files and
the `.spc` listing of every directory the loader searched, so a new file that would shadow an
import also makes the stamp stale. A module and `build.toml` are recorded as the build read them (the
content hash of the text read, the mtime of the stat before the read), so an edit made during the
build makes the next one transpile again; a directory whose listing changed during the build writes
no stamp. The stamp lives in the target's profile directory, so it
is per profile. A build that transpiles deletes the stamp first; the emission writes its record to
`.emit_stamp.new`, and the engine moves it into place only after the whole tree is written, so a
build that stops part way leaves no stamp for a mixed tree. Parallel C compilation uses
content-fingerprinted stale detection with longest-job-first scheduling.

### External transpiler

```sh
super-c build --target=wasm --profile=release -o gen2.wasm \
    --transpiler="wasmtime run --dir=/ --argv0 /abs/gen1.wasm -- /abs/gen1.wasm"
```

`--transpiler=CMD` (`build` and `release` from build.toml only) runs CMD as the transpile step in
place of the engine's own frontend; the engine then compiles and links that tree with all its own
target and profile flags, object cache and link record. CMD is split on whitespace like every
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
record under that identity. It also writes `<out-dir>/SUB/.emit_rewritten`, the tree-relative paths of
the files it rewrote, one per line: the engine counts them as newer than their objects whatever their
mtimes say (`obj_stale`), and counts every file as rewritten when a transpiler leaves no such record. The directory is absolute because a WASI guest starts in `/`. The stamp
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
super-c test --test-shard=1/2 --test-durations=tests/durations/<lane>.tsv --test-record-durations=s1.tsv  # CI lane: its weights, this shard's times alone
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
run time. The generated `main` calls each benchmark directly, never through a fn value
(`std::testing::bench::Run`). The coroutine and cancellation reachability is package-wide:
a benchmark that cancels tasks puts cancellation ticks and probes into the code of every
other benchmark of the binary, so build a profiling or measuring binary with `--filter`. `tests/` and `bench/` sit beside `src/` at the project
root. A bench file that imports the program's root module links a second `main`
(duplicate `__sc_user_main`): put the code under benchmark in a module other than the
root. In this repository a build that includes `simd_baseline` (an unfiltered one too)
links its prebuilt C kernels: run `sh bench/simd_baseline/kernels.sh` first, see
`super-c-compiler-optimization`. The generated runner carries the checkout's identity
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
one cold build of the compiler through the real build engine (debug profile, every core,
object cache and emit stamp off) and reports the engine's phase record, sync,
compile and link included. A C compiler or linker failure there fails the run and keeps
the scratch tree. `SC_BENCH_OUT=<file>` writes the whole record as JSON (schema `"v":2`).

### Gates

```sh
super-c command gate         # ci/gate.sh: the full correctness gate (settings in ci/contract.sh)
```

`ci/contract.sh` holds the gate's settings: the profiles, the worker count and task-delay
seeds, the strict C flags, the readability rules and the files excluded from byte
comparison. Before the fixpoint the gate builds and runs `tools/std_packages` over
`std/packages.toml` (both modes): every std package declared with its tier, no upward tier edge,
no import cycle across packages, and platform FFI only in `std::platform` and the exempt substrate
modules.

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
super-c lint --target=linux --arch=x86_64 --target-cpu=x86-64-v3   # another target's items and features
```

`lint` applies build.toml's `target-cpu` and `target-features` when the file exists, then the
command line's, as a build does. In a project with `src/`, a subdirectory with its own
`build.toml` is a nested project: `lint` checks it as `lint` run in that subdirectory does
(its manifest, its imports; `lint_project` in `src/main.spc`). A batch that holds a file of the
manifest's test directory lints with `TEST` set, as `super-c test` builds it.

Lints: unused imports/members/labels, unnecessary `mut`/`unsafe`/cast, unreachable
statements/arms/branches (after a `return`, an `if` whose two branches both leave, a
`switch` whose arms all leave, a `loop` no `break` leaves; the dead branch of a constant
condition), constant conditions
(a closed `if`/`while` condition the engine folds: `--fix` folds an `if` statement into
its live branch, drops `while false`, spells `while true` as `loop`; `do { } while
false` is the run-once idiom and is left alone; a condition over a build constant such as
`PLATFORM` or `PROFILE` is a deliberate switch and never reported), dead stores, discarded
pure results, redundant casts, owning unions without `Free`. A module whose code the
platform filter removed (a build-constant `if` or `switch`) skips the lints that count
uses or reachability, as a module with `@platform` or `@arch` items skips the unused-import
and unused-member lints.
An `unsafe` whose only reason is a call or pointer of a `@target_feature` function is
unnecessary where the caller's features hold the callee's; a build reports it with its other
lints.

`print`, `println`, `eprint` and `eprintln` are prelude functions (`std/string.spc`) the
compiler lowers itself, so an `import stdio;` used only for printing is unused. The
unused-`pub` lint runs only where no external caller can exist: `super-c lint` with no path of a
project with `src/` whose `build.toml` declares no `[lib]` (listed files load without the modules
that import them, so their `pub` items stay live), and a script build with no `build.toml`
in the working directory (`src/main.spc`); it never applies to std or ffi
modules (`lint_pub_applies` in `src/driver/emit.spc`). A `[lib]` build lints its closure
once: in the static pass when `type` holds `static`, else in the shared pass. `--const` never suggests a
`@no_const` function: a `const fn` whose call always panics turns the call into an error in every
program that makes it, so a function such as std's `panic` takes the tag (`cs_check_fn` in
`src/driver/emit.spc`). It lints std modules only when a listed file names one.

### Language server

```sh
super-c lsp                  # stdio JSON-RPC language server
```

Advertised capabilities (`src/lsp/server.spc:capabilities_with`): push diagnostics,
hover, go-to-definition, type definition, implementation, references, document
highlight, rename (with prepare), document formatting, code actions (quick fixes),
completion, signature help, document and workspace symbols, folding ranges, selection
ranges, inlay hints, and semantic tokens (full + range). Definition, hover and implementation on an
operator (`+`, a unary `-`, `+=`, the brackets of `v[i]`) name the method the checker chose for it
(`op_method`: `index_mut` for a written element); rename and references do not, since an operator
site does not spell the method's name. Hover documents the reflection
constructs no declaration documents (`reflect_hover`): the intrinsics and the members of an
`inline for` binder, by binder kind. Hover on an interface in a bound or a conformance shows the interface
instance with its defaulted arguments (`Mul<V<T, N>>`); a type's signature shows its generic
parameters. Signature help (also on `<`) covers a type argument list (`Mul<`, `f::<`), read from the
text so a list still being typed is found (`type_args_help`). Completion offers the generic
parameters of every declaration around the cursor; where no parsed item spans the cursor (a header
that does not parse yet), it completes from a probe that splices `__lsp_c`, `__lsp_c;` or `__lsp_c>`. The VS Code extension is in
`editors/vscode/`. Between analysis
rounds the server keeps only the open documents' function bodies, the bodies the constant engine
demanded and the bodies of modules that owe a borrow check; a closed module's bodies parse back
on demand (`syntax-ownership.md` in the compiler-internals skill). The workspace sweep analyzes every file with the import roots `super-c lint` gives it
(`Server::roots_of`), and so does the root of an open document outside every package
(`Server::file_roots`): a directory with its own `build.toml` is a nested project, with its own
roots, manifest settings and out-dir. The server handles one message
at a time over a reader on its descriptor: a `didChange` folds every `didChange` already
waiting into its round, so a superseded buffer is never analyzed; every `publishDiagnostics`
for an open document carries the `version` it analyzed.

An analysis round reports what `super-c build` reports up to the borrow check: parse, resolve
and type errors, the feature errors, the always-panics check (an error, with or without lints),
the deferred static_asserts and constants, the lints and the package-wide unused-item lint (only
for a package without an analysis error), with the profile names, the constant engine budgets
(`const-eval-steps`, `const-eval-memory`) and the CPU level and features (`target-cpu`,
`target-features`, at the `debug` profile, as `super-c build` takes them) of the nearest
`build.toml`; without one, the target's baseline features (`lsp_build_settings`).
It publishes, then the borrow round (`Server::borrowck_round`) runs the borrow checks the round
owes, module by module, with the `@tail_recurse` errors (it elaborates and converts only a
tagged function's bodies), and publishes again when records changed. The round lowers with the
build's cancellation checks only a module with a `@tail_recurse` function (one of its reasons is
a check after the self call, `it can accept a task cancellation`): every analysis of a module
records its reachability scan (`Package.reach_scans`, `Package::co_scan`, kept while its bodies
are released), and after an analysis round that changed a scan, the scans are solved
(`Package::reach_solve`) when such a module exists; when the answer changed, every such module
owes its borrow check again, so an edit of the module that launches a task reaches the error. A
round that finishes
runs the unbounded-recursion check over the function summaries each module's last borrow
check recorded (`Package.recur`), so a cycle through modules is reported and cleared as
either module changes. A `didChange` that arrives
during the round stops it at the next item, and nothing it found is published before the
edit's analysis round; a request stops it after the check in progress (a request waits for one
module's check at most), and the next round resumes, so every round that no edit stops finishes
a check. A module whose own analysis failed owes no borrow check; a module whose import closure
has an error waits for it.

To measure the server, run `super-c bench --filter=lsp_` from the repository root (POSIX only):
`lsp_session` runs a scripted session on this repository in-process and reports latency, cycles,
allocations and peak memory per step; `lsp_reuse` reports the modules each edit analyzes again and
the bytes the manifest root retains by kind. `SC_LSP_STATS` shows what each round retains.

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
target-cpu = "x86-64-v2"     # x86_64 level before the feature lists (skipped on another instruction set)
simd-width = 256             # vector width the planner prefers on AVX-512: 256 or 512
simd-dispatch = "x86-64-v3"  # x86_64: levels of the run-time copies of vector code, or "off"
cache-size = "2GiB"          # bytes the project's cache root keeps: a byte count, or B/KiB/MiB/GiB (default 2GiB)
std_internals = true         # the project names std's unstable `pub(package)` items (std::platform); the compiler sets it

[lib]                        # library target (optional; root defaults to src/lib.spc,
type = ["static", "shared"]  # type defaults to static; a shared library records its own file name
                             # (`@rpath/lib<name>.dylib`, `-soname lib<name>.so`) as its install name)

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
    "./super-c bench --no-run --filter=self_transpile",
    "samply record --rate 1000 build/bench-bin --in-process",
]

[profile.fast]               # a profile: optimization level, flags, linker arguments, strip, LTO mode
opt-level = 2                # 0 | 1 | 2 | 3 | "s" | "z": -O<level> on every compile and the link
cflags = ["-DNDEBUG"]        # after the manifest-level cflags and the -O flag
ldflags = ["-static"]        # after the manifest-level ldflags and the -O flag
link-args = ["-dead_strip"]  # each entry reaches the linker as -Wl,<entry>, after ldflags
strip = true                 # strip at link time (`-Wl,--strip-all`); a macOS or iOS binary (ld64 has no
                             # full strip) runs the host `strip` on the linked temp before it is installed,
                             # and a failed strip fails the build
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
| `debug` | `opt-level = 0`, `-g`, frame pointers | Development (**default** of a manifest build) |
| `release` | `opt-level = 3`, `-DNDEBUG -fPIE`, `link-args = ["-O2"]`, strip, `lto = "auto"`; no section GC: LTO drops unreferenced code (`-dead_strip` takes 256 more bytes off the compiler on macOS) | Shipping |
| `bench` | `opt-level = 3`, `-DNDEBUG -g -fno-omit-frame-pointer`, `lto = "auto"` | Benchmarking/profiling |
| `race` | `opt-level = 1`, `-g -fsanitize=thread -DSC_LOCKDEP` | TSan + lock-order checking |
| `test` | `opt-level = 1`, no sanitizers | The `super-c test` runner, and the compiler under test when `test` has no `--profile` (`<out-dir>/test-bin`) |

The exact cc flag strings live in `src/build_system/manifest.spc`; the table shows the
character of each profile, not the verbatim flags. `--sanitizers` adds the full ASan/UBSan set
(`SANITIZER_CFLAGS`, `SANITIZER_LDFLAGS`) after the flags of every profile of the build, a script
build without `--profile` included; targets without the runtimes (Windows, iOS, Android, wasm) drop
them. **Never profile a `--sanitizers` build**: sanitizer frames dominate the samples. An ASan
program's runtime (`std/rt/base.spc`,
`__asan_default_options`) turns ASan's use-after-return fake stack off: GCC 13.3 to 15 put an
object aligned above 32 bytes 32 bytes off in its frames, and AVX-512 code faults there.
`ASAN_OPTIONS=detect_stack_use_after_return=1` turns it back on.

Integer overflow (signed and unsigned) traps under `debug`, `test` and `race` and wraps under
`release` and `bench` (language skill, `operations.md`). The
emitted C is the same under every profile: it calls the arithmetic helpers of `super_rt.h`
(std's `Int<N>` and `UInt<N>` operators call the runtime's `sc_int_overflow`), and the engine adds `-DSC_ARITH_WRAP` to every compile of a profile without overflow checks
(`Profile::arith_wraps`: the `overflow-checks` key, else `opt-level` 2, 3, `"s"` or `"z"`;
`push_profile_side` in `src/build_system/build.spc`). A build with no profile (`super-c build
foo.spc`) checks. Every C compile of the generated tree, under every profile and target, also
gets `-funsigned-char`: the language's `char` is unsigned, and `super_rt.h` fails to compile
without the flag. It also gets `-ffp-contract=off`, so the C compiler never fuses a float
multiply and add (only an explicit `fma` fuses) and run-time float results equal the constant
evaluator's on every target, and `-Werror=incompatible-pointer-types`, so clang rejects the
incompatible pointer arguments gcc 14 already rejects. It also gets
`-fno-builtin-<f>` for the `f64` and `f32` names of the transcendental libm functions
(`LIBM_AS_WRITTEN` in `src/build_system/build.spc`: `sin` to `hypot`), so the C compiler calls
them as written instead of folding, merging or rewriting them, and their results do not depend on
the optimization level; the exact functions (`sqrt`, `fabs`, `floor`, `fma`, ..) stay builtins.
The `cstd` key and `--cstd` replace only the standard and feature-macro flags, never these.

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

The linker cache lives under the project's cache root (below) at `lto/<namespace>`, one
namespace per hash of the compiler version,
path and mtime, the target, the compile and link flags, the schema and the linker line;
`SC_NO_LTO_CACHE=1` links
without it. The linker owns the entries and prunes them itself (entries unused for a
week, the cache under a tenth of the disk and, with lld or gold, under 1 GiB; checked at
most hourly); the engine creates the directory. The cache sweep (below) removes a
namespace with no entry written or used for a week, such as the one a toolchain upgrade
leaves behind.

The build cache base is `$SC_CACHE_DIR`, else `~/.super-c/cache`. Each project caches in its own
root below it, `<base>/<project>` (`cache_root`: the manifest's `bin`, else its `[lib]` name, a byte
outside `[A-Za-z0-9._-]` or a leading `.` made `_`, and `_` added to `o`, `lto`, `prelude` and
`ccver`, the shared folders of older compilers, which still use them); script builds cache in
`<base>/.scripts`. Projects of one name share a root (the worktrees and copies of a project), and no
sweep reads or deletes outside the root of the build that runs it: not the base, not another
project's root. Only `super-c clean --full` deletes a root, its project's.

The object cache lives under the project's root at `o/<namespace>`, one namespace per local
object tree (hash of the real path of the profile directory, such as `build/debug`); a
unit's key hashes the compiler version line, the whole compile command, and the text of
the unit and of every quoted include. The emitted tree names an extern-block header or an
external C source by a path relative to the including file when both lie below the working
directory (a project's own files, and std in a checkout or a copy of the repository), else by its
absolute real path (an installed std). So a tree that moves with its project, such as a copy, a
worktree or the gate's tree, keeps its keys, and under debug information (the working directory
maps to `.`) its objects are the same bytes. The version line comes from `<cc> --version` once per compiler: an entry of the script builds'
`script` namespace (`.scripts`, which every project's builds read) keeps it per compiler identity (`cc_identity` in `src/build_system/objcache.spc`: the
command, the program's path and mtime, and on macOS for an xcrun stub in `/usr/bin` the
`DEVELOPER_DIR`, xcode-select link and `TOOLCHAINS` settings with each candidate clang's mtime),
so a toolchain upgrade probes again and an unchanged compiler starts no probe process; the entry
follows the namespace's rules (below). Each unit's `.cmd` records its key. An object is stored once: the tree's
object and its cache entries are hard links to one file (`link_or_copy`; a copy where the file system
refuses a link, such as a cache root on another volume), so a compile removes the old object before
it writes, and an object's time for the staleness check and the relink decision is the mtime of its
`.cmd` record, which another tree's use of the shared file does not move. The engine runs the
compiler named by the manifest, `$CC` or the default as it is: no ccache wrapper. The compiles, the link
and the version probe start the program the command's first word names in PATH by its path, found once
(`cc_stream`): macOS `posix_spawnp` makes a whole spawn attempt per PATH entry, 0.4 to 0.9 ms per spawn.
argv[0] keeps the word, so no fingerprint or key depends on the lookup; a match that does not start
falls back to the search, and Windows keeps CreateProcess's own search. One exception, for a
macOS target on a macOS host: a command that starts with the xcrun stub `/usr/bin/cc`, `clang` or `gcc`
runs the compiler the stub runs, with `-isysroot` naming the SDK the stub passes (`direct_cc`): the stub
costs about 4 ms per compile and link. `xcrun -f` and `xcrun --show-sdk-path` run at once, once per
compiler identity and `SDKROOT`, recorded as an entry of the script builds' `script` namespace; with the object cache
off, once per build (about 5 ms); for a path with a space the stub runs. Under `-g` the compile maps the
working directory to `.` (`-fdebug-prefix-map`, outside the key), so debug information names
sources relative to the project directory: a debugger started elsewhere needs a source map.
Without coverage or profile instrumentation, each compiled object whose bytes do not name the
working directory also goes to the root's `script` namespace, and a miss in the tree's
namespace reads it there: the project's trees that emit a unit identically compile it once.
After a successful build, the engine writes the key set of all units as generation file
`g<seq>` when the set changed, keeps the newest four generations (the current build and
three older), and deletes each object and dependency list that no kept generation names
and that is older than the start of the build. A version inside that window rebuilds
with no compile; an older one compiles again. An unchanged build reads one directory
and one file. The namespace's `owner` file records its object tree (the profile directory).
An object is unused when no build tree links it: every name of its file is a cache entry. The
sweeps (`sweep`) run after a successful build, at most once every 30 minutes each, in the root of the
build's project (or `.scripts`). The cache sweep (`<root>/o/.sweep`) removes the namespaces whose
owner object tree is gone, whose `owner` names another directory (an older compiler recorded the
source directory), that have no `owner` and did not change for an hour (a build that stopped before
its first commit), or that did not change for 30 days (the `script` namespace only by this rule);
the prelude images (below); and the idle linker caches. Then it trims the objects (`trim_objects`):
in a project's root, while its files (each counted once) hold more than `cache-size` bytes, the least
recently used unused file goes under all its names; in `.scripts`, once it holds more than 16384
objects, the least recently used unused ones go down to 12288 (a suite run uses about 4.8k). A file
a tree links counts but stays. Each deleted object takes its dependency list; a list whose object is
gone goes too, as do the packed `<key>.z` entries of older compilers and temp files older than an
hour. The project sweep (`<out-dir>/.sweep`, `sweep_project`): every out-dir entry with nothing
written for 30 days (a build tree, a link record, a binary) goes unless a build holds the lock of a
tree in it, as do the emitted trees below the root directory idle as long and the per-suite cache
older compilers kept in `<out-dir>/test/fixture-cache`. `super-c clean` runs the same sweeps at once
and deletes every unused object whatever the limits; `super-c clean --full` removes the out-dir, the
emitted trees and the project's cache root.

The checked std prelude is cached as a file of the root's `prelude/` directory,
`<key><compiler>.img` (`src/driver/prelude_image.spc`). A build first loads the std prelude alone, resolves it and type
checks it up to the prelude gate (`prelude_stage`), with imports looked up under the std root only,
so the result does not depend on the project; the user's modules load after it (`load_user`). The
entry's name hashes the std directory as given, the target, arch, CPU features, vector settings,
memory checker, `--test`, profile and profile names, `--bootstrap-tags`, the constant-evaluation
budgets and `SC_TYPE_COLLIDE`, then the compiler identity (`compiler_id`). The image records the
real path of the compiler that wrote it, the content hash of every prelude file as the check read it and the listing of every directory the std
imports were looked up in, as the load listed it (the std directory's from before the load), so an
edit made during the check makes the next build check again; a build that finds both unchanged loads the image in place of parsing and checking std, and
checks the prelude again on any difference. A build that checks the prelude writes the image (not
when the prelude logged a warning) and loads it back, so both paths continue from the same state. The
read records a use (its mtime), and `SC_NO_CACHE` turns the cache off. Each compiler build writes new
images (about 7 MB each), so the cache sweep (`prelude_image::sweep`) deletes an image of another
format or name, one whose recorded compiler path no longer holds a file of its identity, and one
whose std files or directories changed; then those unused for 24 hours beyond the 5 most recently
used, and temp files older than an hour. It reads only each image's header and dependencies (about
2 KiB) and hashes each std file and compiler once per sweep. An image of a compiler that moved after
writing it goes too; that compiler checks the prelude once more. A project
file or a root file whose module path names a module the prelude loaded from another file is an
error.

A program whose own C (module, instance and registry units) stays under 2 MiB is compiled as one
unit: the emitted `__sc_unity.c` includes those units, and both the engine and a script build compile
it in place of them. The runtime and the external C sources still compile on their own, so programs
share their objects. A larger program, such as the compiler itself, compiles its units of one shard
and less than 64 KiB of C in packs of about 256 KiB, `__sc_pack<k>.c`, each including its members
(at least two such units; a header the members share is parsed once per pack). The pack count is a
shard count of those units' bytes (`shard_policy`), which `__sc_shards` records (`packs<TAB>n`) and the
next build keeps while every pack stays within half and one and a half times the target; a unit's pack
is the hash of its file stem modulo the count, so an edit, or a unit that crosses the limit, compiles
its own pack again and no other. The cost is the incremental build: on the compiler, an edit of
`build_system::toml` compiles its pack in 171 ms of serial CPU, where its unit alone took 46 ms, while
the packs take about 13 points off the cold compile's serial CPU (the packs and the precompiled header
below together 35%; with each unit declaring only what it uses, `output-layout.md`, 42%).

A program of separate units, from four units that include `__sc_fwd.h` on (each shard that compiles
alone, each pack; `pch<TAB>1` in `__sc_shards`), compiles that header once, precompiled: the system
headers, the runtime and the std C headers then cost one compile instead of one per unit (about 210 M
compiler instructions per unit with clang). The engine starts the compile when the header lands,
before any unit; the stub `obj/__sc_fwd.h` includes the header and compiles to `obj/__sc_fwd.h.gch`.
Every unit but the runtime, wasm's C library and the test runner waits for it and compiles with
`-include obj/__sc_fwd.h`: gcc loads the `.gch` beside the stub (or reads the stub when it rejects the
file), the clang driver turns the option into `-include-pch`. The header's `.cmd` record holds its
command, the working directory (the file records its inputs' paths) and the content hash of the header
and its quoted includes (` | pch <hash>`), which also ends every unit's fingerprint: a changed header
text compiles the header and every unit again, whatever the mtimes (gcc checks no input, and its
dependency list of a unit names none of the header's includes). Under clang the header takes `-Xclang
-fno-pch-timestamp` (the `pch-no-timestamp` probe), so clang checks only the inputs' sizes and an input
touched with unchanged content, an older mtime included, fails no compile; the header's dependency
list compiles it again after a touch. A failed compile is recorded under its fingerprint, the units
parse the header text, and a build tries again only once the fingerprint changed. A clang unit's
dependency list names the header's inputs by the absolute paths the header recorded; the object cache
stores them through `@/` like the emitted tree (`dep_portable`), so another tree that restores the object
names its own files. `compile_commands.json` omits the `-include` pair (a tool of another compiler
version cannot load the file; the unit includes the header first itself). Where the
`integrated-cc1` probe accepts it (Apple clang), these units and the header compile with
`-fintegrated-cc1`: the driver runs the compiler proper in its own process, one process less per unit
(4% of the compile CPU). Both probes run when the first such tree of a profile directory needs them.

Script builds (`super-c build foo.spc -o out`, `super-c --test foo.spc`) share one
namespace, `<base>/.scripts/o/script` (each entry in the subdirectory of its key's first two hex digits,
`script_entry`, so no directory holds more than about a 256th of it), keyed per unit by the compiler version line, the compile flags, the
unit's path relative to its tree and the text of the unit and its quoted includes (the
tree's path joins the key only under `-g`, coverage or profile instrumentation), so the
runtime and std units that programs emit identically compile once. A hit links the object
into `<tree>/../obj`, which the link reads. The units to compile run as few `cc -c`
commands as the process tree's free worker slots allow, all at once, each from a scratch
directory whose objects then move into place; a unit whose file name another one shares, or
every unit when a compiler or flag word names a relative path, compiles alone with `-o`.
The version probe runs beside the compiles when the namespace is new. An install writes a
temp file and renames it, so concurrent builds never read a torn object. The sweep (not the build
that installs objects, which never lists the namespace) bounds it (above). `SC_NO_CACHE` restores the single
compile-and-link command.

Gates set before the implementation for enabling ThinLTO by default: a body-edit relink
under a quarter of the full-LTO relink, a clean build under 1.1x, the compiler's own
runtime (`super-c bench`, self-transpile) within 3%, link memory no higher, the stripped
binary within 5%. Measured on the compiler's own release build (Apple clang 21, 206 units, a cold
object cache, ccache off, `--jobs=2` on a loaded 14-core machine, so the wall times are upper bounds);
the rows marked (151) are from the 151-unit build the gates were first checked on:

| Case | full LTO (`-flto=auto`) | ThinLTO, no cache | ThinLTO, cache |
|------|------------------------:|------------------:|---------------:|
| clean build, wall / CPU | 68.5 s / 71.3 s | | 34.6 s / 95.3 s (cold cache) |
| link of one body edit | 36.6 to 53.9 s | 14.4 s | 1.9 s (new state), 0.33 s (state linked before) |
| linker peak RSS | 1,690 MiB | 584 MiB | 114 MiB (warm) |
| link CPU | 38.6 s | 71.2 s | 0.4 s (warm) |
| public signature edit (40 units), total (151) | | | 2.0 s |
| by-value layout edit (92 units), total (151) | | | 5.0 s (cold), 2.4 s |
| stripped binary | 5,794,648 B | | 7,186,296 B (+24.0%) |

| compiler runtime (151; Mcyc: parse / typecheck / borrowck / codegen) | 118 / 191 / 423 / 892 | | 124 / 192 / 446 / 923 (+4.7 / +0.5 / +5.4 / +3.5%); end to end −3.1% |

Relink, clean build and memory pass by a wide margin; runtime and size do not (a higher
ThinLTO import limit, `-import-instr-limit=300` and `1000`, changes neither by more
than 0.5%), so the built-in profiles keep `auto` and ThinLTO is the validated opt-in:
`SC_LTO=thin` for a session, or `lto = "thin"` under `[profile.release]` in a project
whose binary is not the shipped compiler. The `bench` profile follows `release` so the benchmark measures
the compiler users run. Script mode
(`super-c release foo.spc`) links once with no link record to relink against, so a `thin`
profile keeps `auto` there.

### Wasm C library

A wasm build links no C library of the toolchain: the loader adds `std::rt::libc` and
`std::rt::libm` (`std/rt/libc.spc`, `std/rt/libm.spc`, `Package::rt_libc`, `rt_libm`) to every
`--target=wasm` program, and the link is `-nostdlib` plus compiler-rt's builtins (the `rtlib`
probe), without `-lm` or the `wasi-emulated` libraries. The modules call WASI preview 1 directly and
compute what wasi-libc computes, bit for bit (`tests/codegen/wasm_libc_test.spc` checks the math functions,
printf, strtod, strtol, qsort, the scanf family, locales, the time functions, signals, `sbrk` and more
against wasi-libc). The C compile still reads wasi-libc's headers
from the sysroot. The units of the two modules compile alone (in no pack, without the precompiled
header) and with `-fno-builtin`, as a C library compiles (`loader::libc_unit`): the C compiler must
not turn the copy loop of `memcpy` or the `malloc` and `memset` of `calloc` into calls of those
functions. The modules define every C function and object that std, the ffi bindings and the
compiler bind for wasm, signals as wasi-libc's `wasi-emulated-signal` emulates them included; a test
(`every_c_symbol_a_wasm_build_binds_is_defined`) checks it from the sources, on every host. Absent:
long double conversions (`%Lf` fails), and `fork`, `execvp`, `pipe`, `dup`, `pthread_create` and
the other functions WASI has no call for; a program that calls one fails to link.

### Toolchain probes

The probe table (`src/build_system/probe.spc`) records what the C compiler and linker
accept under a build's target and flags. Each probe has an id, a C snippet or a flag, a
step (`compile` with `-c`, `link` with the build's link flags, `asm` with `-S`, `print` with
no source, or the engine's `lto` procedure) and a result kind: `accepted`/`rejected`, a path
(the first line the step prints, when a file exists there), the first accepted
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
| `x86-features` | x86_64 | `<immintrin.h>` compiles under the build's flags, which carry the features beyond the baseline |
| `march-x86-64-v2`, `-v3`, `-v4` | x86_64 | `-march=x86-64-vN` accepted |
| `wasm-simd128`, `wasm-relaxed-simd` | wasm32 | `-msimd128` (`-mrelaxed-simd`) with `<wasm_simd128.h>` accepted |
| `cas16` | all | the 16-byte `__atomic_compare_exchange_n` form |
| `thread-local` | all | `_Thread_local` accepted |
| `cpuid-count` | x86_64 | `<cpuid.h>` `__get_cpuid_count` accepted |
| `getauxval`, `at-hwcap2`, `at-hwcap3` | Linux and Android aarch64 | `getauxval` links; each `AT_HWCAP*` constant compiles |
| `aarch64-features` | aarch64 | `<arm_neon.h>` compiles under the build's flags, whose one `-march`/`-mcpu` carries the optional features |
| `thin-lto` | all | the ThinLTO verdict (Link-time optimization above) |
| `unaligned-vector-move` | Windows x86_64 | `-Wa,-muse-unaligned-vector-move` accepted (GNU as 2.38+; clang rejects it) |
| `no-prelink-vectorize` | all | `-fno-vectorize -fno-slp-vectorize` accepted (clang; gcc rejects them, its LTO compile does not vectorize) |
| `integrated-cc1` | all | `-fintegrated-cc1` accepted (clang; gcc rejects it) |
| `pch-no-timestamp` | all | `-Xclang -fno-pch-timestamp` accepted (clang; gcc rejects it) |
| `rtlib` | wasm32 | the path of the compiler's builtins library (`-print-libgcc-file-name`: compiler-rt's `libclang_rt.builtins-wasm32.a`) |

The results of one profile directory live in one record, `<out-dir>/<profile>/.probes`:
its first line holds the schema, a hash of the compiler path and mtime, the whole compiler
command (`--cc="clang -arch x86_64"`: its arguments select a target too), the target, the
instruction set and the compile and link flags, then the compiler version line; each
other line is `<id>\t<result>` (the `thin-lto` line adds the linker path and mtime). A
record of another key holds nothing; one of another compiler version loses its results
once the version probe answers. A probe runs only when a build needs its result and the
record does not hold it: the needed probes start beside the compiler version probe,
before the transpile, one child per spelling, all at once; `integrated-cc1` and
`pch-no-timestamp` run when the precompiled header is planned, and the build waits for them. A build that measured nothing
leaves the record unchanged. The results a build used end every object and link
fingerprint (` | probes <id>=<result>;`). A build uses the `thin-lto` verdict under `lto =
"thin"`, on Windows x86_64 `unaligned-vector-move` (accepted: every compile and the link take
the flag), under full LTO (`lto = "full"` or `"auto"`, a ThinLTO request that falls back to `auto`
included) `no-prelink-vectorize` (accepted: every compile takes the flags after the profile's `-O`
flag, so clang vectorizes at the link, after it inlines across units: a function vectorized alone in
its unit no longer vectorizes in the loop it is inlined into), on wasm `rtlib` (every link takes
`-nostdlib <path>`: wasm links its own C library, Wasm C library below), for a tree compiled through the precompiled
header `integrated-cc1` and `pch-no-timestamp` (accepted: the flags join those commands, which the
fingerprints hold, not ` | probes`), and the probe of each CPU feature it enables that has one (`wasm-simd128`,
`wasm-relaxed-simd`, `aarch64-features`, `x86-features`); a rejected feature probe fails the build before any
compile, once per probe with the features it checks ("build: the C compiler 'cc' rejects
'-msimd128': target feature 'simd128' needs a compiler that supports it"). The emitted C uses no probe result, so the emit stamp holds none.

```sh
super-c build --print-probes                    # the table for the debug profile and the host target
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
| `sse3` | x86_64 | `sse2` | `-msse3` | `x86-features` | macOS, iOS, Android |
| `ssse3` | x86_64 | `sse3` | `-mssse3` | `x86-features` | macOS, iOS, Android |
| `sse4.1` | x86_64 | `ssse3` | `-msse4.1` | `x86-features` | Android |
| `sse4.2` | x86_64 | `sse4.1`, `popcnt` | `-msse4.2` | `x86-features` | Android |
| `popcnt` | x86_64 | | `-mpopcnt` | `x86-features` | Android |
| `cx16` | x86_64 | | `-mcx16` | `x86-features` | macOS, iOS, Android |
| `lahf-sahf` | x86_64 | | `-msahf` | `x86-features` | macOS, iOS |
| `avx` | x86_64 | `sse4.2` | `-mavx` | `x86-features` | off |
| `avx2` | x86_64 | `avx` | `-mavx2` | `x86-features` | off |
| `fma` | x86_64 | `avx` | `-mfma` | `x86-features` | off |
| `bmi1` | x86_64 | | `-mbmi` | `x86-features` | off |
| `bmi2` | x86_64 | | `-mbmi2` | `x86-features` | off |
| `f16c` | x86_64 | `avx` | `-mf16c` | `x86-features` | off |
| `lzcnt` | x86_64 | | `-mlzcnt` | `x86-features` | off |
| `movbe` | x86_64 | | `-mmovbe` | `x86-features` | off |
| `avx512f` | x86_64 | `avx2`, `fma`, `f16c` | `-mavx512f` | `x86-features` | off |
| `avx512bw`, `avx512cd`, `avx512dq`, `avx512vl` | x86_64 | `avx512f` | `-m<name>` | `x86-features` | off |
| `avx512vbmi`, `avx512vbmi2`, `avx512bitalg`, `avx512fp16` | x86_64 | `avx512bw` | `-m<name>` | `x86-features` | off |
| `avx512vpopcntdq`, `avx512vnni` | x86_64 | `avx512f` | `-m<name>` | `x86-features` | off |
| `gfni` | x86_64 | `sse2` | `-mgfni` | `x86-features` | off |
| `vaes` | x86_64 | `avx2`, `aes` | `-mvaes` | `x86-features` | off |
| `vpclmulqdq` | x86_64 | `avx`, `pclmulqdq` | `-mvpclmulqdq` | `x86-features` | off |
| `aes` | x86_64 | `sse2` | `-maes` | `x86-features` | off |
| `pclmulqdq` | x86_64 | `sse2` | `-mpclmul` | `x86-features` | off |
| `avx10.1` | x86_64 | `x86-64-v4`, `avx512vbmi` to `avx512fp16` | `-mavx10.1` | `x86-features` | off |
| `avx10.2` | x86_64 | `avx10.1` | `-mavx10.2` | `x86-features` | off |
| `neon` | aarch64 | | | | always on |
| `fp16` | aarch64 | `neon`, `rdm` | `+fp16` | `aarch64-features` | macOS |
| `dotprod` | aarch64 | `neon`, `rdm` | `+dotprod` | `aarch64-features` | macOS |
| `rdm` | aarch64 | `neon`, `crc`, `lse` | (Armv8.1-A) | `aarch64-features` | macOS |
| `i8mm` | aarch64 | `neon`, `rdm` | `+i8mm` | `aarch64-features` | off |
| `bf16` | aarch64 | `neon`, `rdm` | `+bf16` | `aarch64-features` | off |
| `aes` | aarch64 | `neon` | `+aes` | `aarch64-features` | macOS, iOS |
| `sha2` | aarch64 | `neon` | `+sha2` | `aarch64-features` | macOS, iOS |
| `sha3` | aarch64 | `neon`, `rdm`, `sha2` | `+sha3` | `aarch64-features` | macOS |
| `crc` | aarch64 | | `+crc` | `aarch64-features` | macOS |
| `lse` | aarch64 | | `+lse` | `aarch64-features` | macOS |
| `sve` | aarch64 | `fp16`, `rdm` | `+sve` | `aarch64-features` | off |
| `sve2` | aarch64 | `sve` | `+sve2` | `aarch64-features` | off |
| `sme` | aarch64 | `neon`, `rdm` | `+sme` | `aarch64-features` | off |
| `sme2` | aarch64 | `sme` | `+sme2` | `aarch64-features` | off |
| `sme-f64f64` | aarch64 | `sme` | `+sme-f64f64` | `aarch64-features` | off |

The x86_64 baseline is `sse2` and, by platform, what the table's last column names (macOS and
the iOS simulator: `core2`, which every C compiler for them assumes; Android: its ABI). The x86-64 psABI levels
name sets: `x86-64` the baseline, `x86-64-v2` adds `sse3` to `lahf-sahf`, `x86-64-v3` adds `avx`
to `movbe`, `x86-64-v4` adds `avx512f`, `avx512bw`, `avx512cd`, `avx512dq` and `avx512vl`. A
feature list item may be a level name (x86_64 only; a build.toml list skips it on another
instruction set), and `--target-cpu=L` or the build.toml key `target-cpu = "L"` puts a level before
every feature list (the flag replaces the key, and the last flag wins; another name is an error, and
so is the flag on another instruction set, which the key skips). An x86_64 build always names its
level, never the C compiler's default (Ubuntu 26.04's GCC defaults to `x86-64-v3`): the C flags are
`-march=x86-64-vN` for the highest level the set holds, else `-march=x86-64`, and then the `-m` flag
of each feature beyond that level, the platform baseline's included (macOS: `-msse3 -mssse3 -mcx16
-msahf`), in table order; the `x86-features` probe compiles `<immintrin.h>` under them.

The aarch64 baseline depends on the platform: macOS has every feature of Apple clang's default
CPU (`apple-m1`, the oldest Apple silicon Mac); iOS those of its default CPU (`apple-a7`, which
the iOS 13 floor still allows); Linux, Android and Windows `neon` alone. `sve` and `sve2` are
detected only: no vector operation uses them, and no macOS or iOS build takes them (no Apple core
has them). `sme`, `sme2` and `sme-f64f64` are detected (Apple M4 and later, Armv9.2 cores) and
select C kernels that enter streaming mode themselves; no vector operation uses them, and outside
streaming mode an SME core may lack SVE (Apple M4 and M5), so a build that enables them must not
let the C compiler use SVE (GCC's `+sme` implies `+sve2`). A feature whose flag raises the architecture implies the Armv8.1-A features that
architecture brings (`rdm`, `crc`, `lse`), so the set names what the C compiler enables. The
features beyond the baseline make one C flag:
on macOS `-mcpu=apple-m1+<f>...`; elsewhere `-march=` the lowest architecture whose assembler
and intrinsics take them all (`armv8.2-a` for `fp16`, `dotprod`, `i8mm`, `bf16`, `sha3`,
`sve`, which only Armv8.2 cores have; `armv8.1-a` for `rdm`, whose intrinsics Clang guards
with Armv8.1; else `armv8-a`), then each enabled extension that architecture lacks (Armv8.1-A
has `rdm`, `lse` and `crc`). GCC 13 with binutils 2.40 rejects `+dotprod`, `+i8mm` and `+sha3`
on `armv8-a`, and `+rdm` (it spells `+rdma`). The `aarch64-features` probe runs only for a
build with features beyond the baseline, and its error names that flag.

A build starts from its instruction set's baseline (the rows that are always on), applies
the build.toml `target-features` list (a profile's list replaces the build-level one), then
the `--target-feature=L` list (repeated flags join in order). Each list item is `+name` or
`name` (enable) or `-name` (disable), applied in order; the implications close the set
after the last item. An unknown name is an error before anything builds ("unknown target
feature 'avx2' for wasm32; the wasm32 features are: simd128, relaxed-simd"), and so is a
baseline feature disabled ("target feature 'sse2' is part of every x86_64 build"; "target
feature 'dotprod' is part of every aarch64 build for macos"). A
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
super-c build --target-feature=+i8mm,+bf16                   # on macOS: -mcpu=apple-m1+i8mm+bf16
super-c build --target-cpu=x86-64-v3                         # on Linux x86_64: -march=x86-64-v3
super-c build --target-feature=x86-64-v2,+avx2               # -march=x86-64-v2 -mavx -mavx2
```

On AVX-512 the vector planner prefers 256-bit entries: `--simd-width=512` or the build.toml key
`simd-width = 512` lets it use 512-bit ones (the width is part of the emit stamp). A function's
`@target_feature` adds its features to the build's set for that function and the functions with
vector code it calls: its C definition carries `__attribute__((target("...")))` of the features
beyond the build's (aarch64: clang's `+ext` form, GCC's `arch=armv8.N-a+ext` form; with SME features
`SC_TGT_A64_SME` adds `+sve2` for GCC 15, which compiles SME only with it, and drops them for GCC 13,
which has none), the planner
serves its vector operations from the entries that set holds, and, when the set holds entries the
build's does not, a call of a function with vector code that states no features runs a copy of it
compiled with the same set (`<symbol>__fs<hex>`,
in the callee module's instance file), whose calls do the same.

On x86_64 each function with vector code and no features of its own also gets a copy per level of
`--simd-dispatch=L` (build.toml `simd-dispatch`; a comma list of `x86-64-v2` .. `x86-64-v4`, default
`x86-64-v3` in a profile at opt-level 2 or more, `off` at 0 or 1 (`debug`, `test`: the copies make
the C compile of vector code 1.4 to 1.7 times longer) and in a script build without `--profile`;
levels the build's set holds skipped; `off` for none), and opens with a check: when the CPU has a
level's features, it calls that level's copy, the highest first (`__sc_simd_lvl()`: the
detector's answer, read once per TU). A copy calls copies, so one check runs where code without the
features enters vector code; a build at a level above the list makes none. The level list is part
of the emit stamp. `SC_SIMD_LEVEL=<k>` (a test switch) sets the level the checks read.

`std::cpu::detect` reads the features of the machine a program runs on (`ffi/sc_cpu.spc`), with
the build's set included: a program can choose code at run time, never a result.

### Common flags

| Flag | Effect |
|------|--------|
| `--profile=NAME` | Select build profile (also the value of `PROFILE`). A bare `build <file.spc>` without it applies no profile flags while `PROFILE` still reads `debug`: pass `--profile=debug` for `-O0 -g` and frame pointers |
| `--sanitizers` | Add AddressSanitizer and UndefinedBehaviorSanitizer to every C build of the command, after the profile's flags (`super-c test --sanitizers`: the compiler under test and the runner) |
| `-h`, `--help` | Print the usage on stdout and exit 0 |
| `--jobs=N` | Worker count for parallel stages + cc, and the jobserver slots that nested `super-c` processes share (default: build.toml `jobs`, else one per CPU) |
| `--out-dir=DIR` | Override output directory (a bare `build file.spc` emits under `DIR/<profile>/raw`) |
| `--cc=CMD` | Override C compiler (manifest and bare builds alike) |
| `--cstd=STD` | Replace the base C flags string (build.toml `cstd`; also for a bare `build file.spc`), passed verbatim (e.g. `-std=gnu11 -D_POSIX_C_SOURCE=200809L`) |
| `-o NAME` | Output binary name (`build`/`release`/`bindgen` only, not script mode) |
| `--bin=NAME` | Build/run only that `[bin.NAME]` target; with `-o PATH`, link it at PATH. An error without build.toml |
| `--transpiler=CMD` | `build`/`release` from build.toml: run CMD as the transpile step (see External transpiler above). An error without build.toml |
| `--print-probes` | `build`/`release` from build.toml: print the toolchain probe table for the target and profile (see Toolchain probes above). An error without build.toml |
| `--target=T` | Cross-compile OS: `windows`/`macos`/`linux`/`ios`/`android`/`wasm` (the value of `PLATFORM`). `wasm` builds with `$WASI_SDK_PATH`'s clang and sysroot (else `$WASI_SYSROOT`; the sysroot gives the headers only), links an 8 MiB stack placed first with std's C library and no toolchain library but compiler-rt's builtins (Wasm C library below), and strips at link time; `windows` links with `-Wl,--stack,8388608`, so every target's main thread has the 8 MiB stack of Linux and macOS (`push_sdk_libs`) |
| `--arch=A` | Cross-compile arch: `x86_64`/`aarch64`/`wasm32` (the value of `ARCH`). On macOS the host `cc` builds the other instruction set (`-arch`); another platform's needs its toolchain (`--cc`) |
| `--target-feature=L` | CPU features, a comma list of `+name`/`-name` applied after build.toml's `target-features` (see CPU features above) |
| `--target-cpu=L` | x86_64 level (`x86-64`, `x86-64-v2`, `x86-64-v3`, `x86-64-v4`) applied before every feature list; replaces build.toml's `target-cpu` |
| `--simd-width=W` | Vector width the planner prefers on AVX-512: `256` (default) or `512` |
| `--simd-dispatch=L` | x86_64: the levels of the run-time copies of vector code (comma list of `x86-64-v2` .. `x86-64-v4`, default `x86-64-v3` at opt-level 2 or more, `off` below and for a script without `--profile`), or `off`; replaces build.toml's `simd-dispatch` |
| `--bootstrap-tags` | Enable `@platform` bootstrap tag gating; accept unknown attributes, and a std `@intrinsic` this compiler does not know (its declaration and the std bodies that call it go unchecked; emitting such a body fails); a manifest build also skips build.toml sections and keys this compiler does not know (a previous release building newer source) |
| `--no-lint` | Disable lint pass |
| `--const-eval-steps=N` | Cap compile-time evaluation steps (~2M default) |
| `--const-eval-memory=SIZE` | Cap compile-time evaluation memory (~96 MiB default) |
| `--lib` | Build as library instead of binary (an error without build.toml). A static library is archived with `ar`, for another platform's objects with the cross compiler's archiver (`llvm-ar` beside a clang, as in the wasi-sdk and the NDK; `<triple>-ar` beside a `<triple>-gcc`; `archiver` in `src/build_system/build.spc`) |

## Environment Variables

### Build and caches

| Variable | Effect |
|----------|--------|
| `SC_TIMINGS` | Print a one-line per-phase timing summary |
| `SC_BUILD_STATS` | Append one JSON record per engine build to the named file (`-` = stderr): every phase of the partition in ms, the streamed C compile span apart from it, cache switches, the instance re-lowering counts by reason (`"relower"`), peak RSS at five boundaries (`src/driver/stats.spc`) |
| `SC_BUILD_MEM` | With `SC_BUILD_STATS`: turn the runtime allocation tracker on for the build, so the record carries allocation calls, requested bytes, live bytes and per-phase survivors (slower; never for timing runs). `"mem":{"on":false` = the runtime this compiler links predates the counters (a bootstrap build) |
| `SC_STD_DIR` | The std directory, in place of the `std/` found beside the compiler binary (`exe_std_dir` in `src/main.spc`). `super-c test` sets it for the compiler under test, which `--out-dir` may place outside the project, when the project holds `std/core.spc` and the variable is unset (`src/build_system/build.spc`) |
| `SC_CACHE_DIR` | Override the build cache base (each project's root below it: objects under `o/`, the linker's ThinLTO caches under `lto/`, prelude images under `prelude/`) |
| `SC_NO_CACHE` | Disable the object cache (the linker cache keeps its root) |
| `SC_TEST_CACHE_DIR` | The cache base `super-c test` gives the compilers its tests start, kept across runs (CI sets `~/.super-c/cache/.tests`); unset, `<out-dir>/test/cache`, deleted at the run's start and end |
| `SC_JOBSERVER` | The process-tree jobserver the first compiler of a tree makes, or a test runner started without one (`--jobs` slots), and every process it starts joins: `<slots>,<fd>` on POSIX (the inherited descriptor of an unlinked slot file), `<slots>,<path>` on Windows (a temporary file deleted with its last handle). A process holds a slot as a byte-range lock on one byte (`fcntl` record lock, `LockFileEx`), which the system drops when the process ends by any exit, abort or kill, so a killed process never takes slots with it. One more slot is implicit to each process |
| `SC_UNITY_MAX` | Bytes of C up to which a program compiles as one unit (`__sc_unity.c`; default 2 MiB); a larger program compiles its small units in packs (`1`: a small program does too); `0` compiles every unit alone, with no pack (tests of per-unit objects and staleness set it). The emit stamp records it |
| `SC_LTO` | Override the profile's `lto` mode: `none`, `full`, `auto`, `thin` |
| `SC_NO_LTO_CACHE` | Link ThinLTO without the linker cache |
| `SC_NO_EMIT_CACHE` | Disable the emit stamp |
| `SC_NATIVE` | The native backend's module choice (super-c-compiler-internals, "Native backend"): `0` C only, `1` every module, else a comma-separated list of module paths. Unset, a linking build with unoptimized C flags and no sanitizer takes every module where the target has a native backend (macOS arm64, Linux x86-64, Linux arm64, Windows x86-64, wasm32-wasip1). It is part of the emit stamp's compiler identity and of the native record's key |
| `SC_NATIVE_STATS` | Print, per module, `native` or `through C: <reason>`, then the native and C module counts and the native phase's ms |
| `SC_NO_TU_CACHE` | Disable per-TU journal/replay cache |
| `SC_BUILD_MEM_BUDGET` | Cap the estimated bytes in flight across the parallel jobs of the type check, the borrow check and the emission (`64M`, `2G`); a job above the whole budget runs alone; a value that is not digits plus one optional K/M/G suffix, or that overflows, is a fatal error |
| `SC_TYPE_STATS` | Print the type identity counters per phase and at the end of emission: interning hits and probe steps, foreign lowerings, instance-graph interns, layout cache traffic, the bytes the package type table and the module pools retain, the publication census, and per publication the kept bodies remapped and the time it took (`type-identity.md` in the internals skill) |
| `SC_SYNTAX_STATS` | Print one syntax accounting line per phase (parse, resolve, typecheck, borrowck, emit): node and child counts with the share inside bodies, the retained bytes of nodes, children, resolutions, types, module pools and the other side tables, the source text, and the module that retains the most (`syntax-ownership.md` in the internals skill) |

### Verification (validation switches, each runs only when set)

| Variable | Effect |
|----------|--------|
| `SC_FACTS_CHECK` | Snapshot semantic tables after typecheck; report mutations |
| `SC_CORE_IR` | Re-verify inlined bodies and re-prove bounds-check eliminations |
| `SC_LAYOUT` | Validate pool types against C layout invariants |
| `SC_BORROW_STATS` | Borrow-check probe table (`src/borrowck/flow_ir.spc`): ms, calls and (with `SC_BUILD_STATS` + `SC_BUILD_MEM`) allocations per region (lower, replay, forest, facts, cfg, liveness, moves, solver, rules, emit, setup, decl, reach, drops, publish, keep, tail: their total is the build record's `borrowck` phase less a few ms of loop overhead; `reach` is the stage's per-module prologue, the module reference rows, body counts and reachability scans, and the solve), skip and elaboration tallies, sizes, the lowered product (Core IR KiB, type slots, replay-tape entries per event kind), the slowest bodies and the retained scratch. Needs `SC_BUILD_STATS`; parallel allocation columns are global counters and mean nothing |
| `SC_BC_VALIDATE` | Validation build: every borrow-check stage the feature predicate skipped runs anyway and must find nothing (zero loans, zero move events, no diagnostic); every loan issues at a borrow operation, every move path has a valid parent, the init rows match the path count, the liveness queue stays within its tight bound; every elaborated body passes the structural verifier and the ownership verifier (`ir::drops::verify_drops`: each value released once per path, guarded where paths disagree, nothing held at a return). A failure prints the body and its events, then aborts. Output is unchanged. The gate runs its fixpoint and worker-identity builds under it |
| `SC_TYPE_VALIDATE` | After every type publication checkpoint, exit 1 if any module table still names a provisional type id. The gate runs its fixpoint and worker-identity builds under it |
| `SC_TYPE_COLLIDE` | Every type and instance hashes to one bucket: the type tables run on full comparisons alone, so a hash-order dependence shows as different output |
| `SC_TASK_DELAY` | A seed: a deterministic per-job delay (100 to 400 us, a hash of the job and the seed) at the start of every parallel item job (type check, borrow check, always-panics), so the worker-identity gates run under schedules the machine would not produce by itself, a different one per seed |
| `SC_TYPE_TABLE` | Path: write the package type table at the end of emission, one line per final id (`id class kind qualifier module payload`, children as final ids); the gate compares the dumps of one worker and every core under each delay seed |
| `SC_CEMIT_STATS` | Per-phase wall times (the unused-item lint as its own phase), the interpreter body-reuse counters (kept hits, fresh lowerings, retained boxes; printed after borrow checking and after the always-panics check), the instance graph's collect line (records by kind, bodies walked, rounds, a budget stop) and its per-instance `static_assert` line (`cemit-stage inst-asserts`: ms, instances checked), the re-lowering census (one line per template: instances, re-lowerings, identical re-lowerings, retained KiB) and the emission probe table (`src/emit/probe.spc`: ms and calls per region, the instance discovery total, re-lowering templates and instances by reason, bodies taken from the keep or lowered, rendered bodies and bytes; with `SC_BUILD_STATS` + `SC_BUILD_MEM` also allocation calls and MiB) |
| `SC_INLINE_STATS` | Per-body inliner decision counters |
| `SC_BCE_STATS` | Per-body bounds-check elimination counters (`BceStats`): checks and range checks seen and removed, coalesced, folded, signature crossings in the walked blocks, and the kept checks per reason (six reason columns, `BR_WIDENED` the last) |
| `SC_BCE` | `0` turns bounds-check elimination off: every check stays (the generator's BCE differential oracle) |
| `SC_BCE_DISABLE` | A list of BCE rules to turn off, matched by substring: `fold` (folded panic guards, and their widening), `widen` (guard widening alone), `sig` (signature facts), `int` (the interval facts of `ir/facts.spc`) |
| `SC_SIMD_LEVEL` | Test switch: the run-time copy level `k` (0 the bodies without the copies' features) the dispatch checks of an x86_64 program read instead of the CPU's (an emulator that hides features it runs) |
| `SC_SIMD_SCALAR` | `1`: the vector planner uses no `@simd_impl` entry; every vector operation keeps its lane loop (the entry differential oracle) |
| `SC_SIMD_TRACE` | Print each vector operation for which `simd_plan` finds no single entry (`simd: no native entry for <Op> on <T>xN: chunks` or `the lane loop`) |
| `SC_LIR` | The LIR check (super-c-compiler-internals, "LIR"): `1` lowers every module's bodies to LIR beside the C, a comma-separated list of module paths (`lir::lower,std::string`) only those modules'. At the end of the emission the build fails when a body it rendered fails the verifier. The emitted C is the same. The value is part of the emit stamp and of the per-TU cache keys, so a replayed module passed the check when its record was written. `super-c test` unsets it for the test binary. `check.sh` runs the suite under `SC_LIR=1` |
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
| `SC_LOCK_ORDER` | Lock-order inversion checking (`ffi/sc_runtime.spc`) in a build with `-DSC_LOCKDEP` (the `race` profile; the build constant `LOCKDEP`): non-`0` reports; `f`/`F` prefix aborts |
| `SC_TEST_SUPERC` | Path of compiler under test (wasm lane) |
| `SC_CTARGET_CLANG` | Clang of the pinned major release that `tests/codegen/ctarget_test.spc` compares bindgen's C environment tables with |
| `SC_CTARGET_REQUIRE` | Non-empty: a missing oracle clang fails those tests instead of passing them without checking |

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
(`build/debug/raw/` without `--profile`): `PROFILE` makes the emitted C depend on the profile,
so every profile has its own tree, per-TU cache, manifest and orphan pruning, and switching
profiles never mixes trees. A program that does not read `PROFILE` emits the same C under
every profile.

```
build/
  debug/raw/
    super_rt.h        # C backend header: libc includes, arithmetic helpers, runtime prototypes
    std/
      rt/base.c       # the runtime: traps, leak/double-free tracker, overflow report (std/rt/base.spc)
    __sc_fwd.h        # runtime and extern-block includes, dyn/extern declarations shared by every TU
    __sc_registry.c   # runtime helper definitions, ZST sentinels and the reflection registry
    __sc_manifest     # output paths, content hashes, header dependencies, shard counts
    __sc_shards       # the shard counts this build used (read back by the next build)
    __ldflags         # linker flags collected from @link (one per line)
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
per-TU cache and `__sc_manifest` with it), and the C compiler reads that one tree: the
emitter compares each file with what it holds and writes only the files whose content
changed, so an unchanged file keeps its mtime (`publish_file`). A build whose emission
fails writes no unit or header, so the tree stays as the last successful emission left
it. Objects compile into `obj/` with `-MMD` dep tracking,
and `compile_commands.json` (written only when its text changes, so C tooling does not reload it) and
the emit stamp `.emit_stamp` land beside them, with the
toolchain probe record `.probes` once a build or `--print-probes` measured a probe. The link record
`<out-dir>/__link-<hash of the binary's path>.cmd` holds the compiler's version line, the link command
and the probe results it used.
On Windows, a link or archive line longer than 8192 characters passes its objects through the response
file `@<record>.rsp` (CreateProcess takes 32,767 characters, and the gcc driver's own lines add to
ours); the script lane's link does the same with `<tree>/__link.rsp`. `super-c test`
runs the same engine on the generated test root under the `test` profile in
`<out-dir>/test/` (`raw/`, `obj/`, the runner `__tests`), with the emit
stamp and object cache making an unchanged suite a link check; `super-c bench` uses
`<out-dir>/bench/<profile>/`. Engine code takes every manifest output path from out-dir
(the `out-dir` key or `--out-dir`, default `build`) and never spells `build/`. The bare
`super-c <root.spc>` tree under `<root dir>/build/<profile>/raw` is the one exception.

One process builds a profile directory at a time: a build holds the lock file `.lock` in it
(`bsys::tree_lock`: a POSIX record lock, `LockFileEx` on Windows, none under WASI) from the emit to
the link, and the bare `super-c <root.spc>` holds its `build/<profile>` the same way. A second build of
the directory prints "build: waiting for another build of '<dir>'" and waits at most 30 minutes. Without
the lock it would rewrite the units the first one compiles: a torn unit compiles, and its object enters
the object cache under the key of the text the first build hashed. The OS releases the lock when the
process ends, also by a crash; a transpiler child (`--emit-sub`) runs under its engine's lock.

Parallel analysis (the resolve frontier, the type check, borrow check and always-panics
item jobs, the emission frontier) is used only when the package holds at least 256 KiB of
non-prelude source (`Package::analysis_jobs`,
`loader::PAR_MIN_USER_BYTES`); below that the worker pool costs about as much CPU as the
serial compile and gains a few milliseconds at most, so small compiles run serially and
hand their jobserver slots back. The parallel C compile is unaffected.

Includes are relative: `cc -std=c11 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700 -funsigned-char -ffp-contract=off $(find build/debug/raw -name '*.c' ! -name '__sc_unity.c' ! -name '__sc_pack*.c') $(cat build/debug/raw/__ldflags)`
builds the whole tree with no `-I` flags (`__sc_unity.c` and `__sc_pack<k>.c` include other units, so a
build compiles them or their members, never both; without the feature macros of the default `cstd`,
Darwin's `struct stat` lacks the fields std binds) (verified: the tree compiles and runs with `clang`;
add `-DSC_ARITH_WRAP` for wrapping integer overflow, and the `LIBM_AS_WRITTEN` flags for the
engine's libm results).
