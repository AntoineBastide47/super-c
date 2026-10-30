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

Super-C is a self-hosting compiler for macOS arm64, Linux x86-64, Linux arm64, Windows x86-64 and
wasm32. A build compiles each module to a Mach-O, ELF, COFF or wasm object itself and links the objects
with its own linker (`src/link/`): Mach-O executables and dylibs on arm64 (chained fixups, ad-hoc
signature), ELF executables and shared libraries on x86-64 and arm64 (glibc 2.34 or later), PE
executables and DLLs on x86-64 (the UCRT), and wasm32 modules; the own archiver writes every static
library. Each own linker also links static libraries (`.a`, `.lib`, positional or `-l<name>` from a `-L`
directory) a C compiler built: it takes a member for each symbol still undefined, as LLD does. No C
compiler takes part. A module the native backend refuses (a header's `static` function, an intrinsic it
has no template for) and a target without a native backend are build errors; `--emit-c` writes the
program's readable C11 instead (Generated output below). A build at an `opt-level` above 0 (the
`release`, `bench` and `test` profiles) runs the LIR optimizer first: inlining, value numbering, load and
store forwarding, loop transforms, constant and branch folding (`SC_LIR_OPT` overrides the
choice; Optimization levels and code-generation flags below). The objects carry DWARF line tables when the profile's `debug` key is set (`debug`, `bench`),
and unwind data always. The extern blocks read the target's C headers (`native_header_facts`): the C
library's development package on Linux, the macOS SDK, mingw-w64's tree on Windows (found beside a
mingw `gcc` or `clang` in PATH), a WASI sysroot (`WASI_SDK_PATH`, else `WASI_SYSROOT`) for wasm, or the
tree `--sysroot=DIR` names. The single binary `super-c` drives every stage of the workflow.

## Subcommands

### Compile

```sh
super-c build --emit-c app.spc # write the build/ C tree, link nothing
super-c build app.spc -o app   # compile + link only, name the binary (default: a.out)
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
super-c build -o out         # override output binary name
super-c build app -o out-app # build the project of directory app (its build.toml); -o stays the caller's path
super-c build --bin=tool -o t # link the [bin.tool] target at t (an unknown name is an error; --lib with -o is one too)
super-c release              # optimized build (release profile; alias for --profile=release)
super-c run                  # build + execute the manifest binary
super-c clean                # run the project's sweeps now (see the build cache below)
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
build that stops part way leaves no stamp for a mixed tree. The native backend compiles the modules in
parallel, largest first, and a module whose key matches the native record (`__sc_native`) keeps its
object.

### External transpiler

```sh
super-c build --target=wasm --profile=release -o gen2.wasm \
    --transpiler="wasmtime run --dir=/ --argv0 /abs/gen1.wasm -- /abs/gen1.wasm"
```

`--transpiler=CMD` (`build` and `release` from build.toml only) runs CMD as the transpile step in
place of the engine's own frontend; the engine then links that tree's objects with its own target and
profile settings and link record. CMD is split on whitespace like every
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
the files it rewrote, one per line: the engine counts them as changed whatever their mtimes say, and
counts every file as rewritten when a transpiler leaves no such record. The directory is absolute because a WASI guest starts in `/`. The stamp
identity of an external transpiler (`transpiler_id`) hashes the words of CMD and the content of each
word that names a file, the program found through PATH: a different transpiler, or new content at the
same path (a rebuilt `.wasm`), transpiles again, and so does a switch back to the engine's own frontend.
A transpiler that exits nonzero fails the build: its own diagnostics print on the inherited stderr,
then `build: transpiler failed (exit N): <argv>`. The wasm self-host fixpoint in the release and debug
workflows uses this: WASI has no processes, so the native engine runs the wasm compiler under wasmtime
as its transpile step and links with its own wasm linker.

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
super-c test --quiet app.spc           # one file's @test functions (same --test-* and --filter flags apply)
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
`bench::fail`. The compiler's own benchmarks (`bench/transpile_bench.spc`, release profile)
sample wall time, CPU time of every thread, cycles and allocations at the build's own phase boundaries
(`driver::stats::set_hook`, the backend's sub-boundaries through `mark_sub`), so their phases
are the build's, plus a lexer-only pass reported as a share of parse. `self_transpile` runs
100 serial rounds of the transpile step of an emission (`build_system::build::root_transpile`
with no link: the program's C, as `--emit-c` writes it; one worker, a fresh scratch tree):
stamp, parse (load, lex and parse), resolve, typecheck, borrowck, checks, prepare, plan,
render and publish, then one cold build of the compiler through the real build engine (every
core, caches and emit stamp off) with the engine's phase record; a build or link failure there
fails the run and keeps the scratch tree. `self_compile` runs 25 rounds of a whole cold native
build (`build_system::build::manifest_build`, every cache off, a fresh scratch tree) with one
job, then 25 with one job per core: setup, the same front end, then lower (the declarations and
the LIR), optimize (the LIR optimizer), codegen (the native objects), publish, sync and link
(the own linker). Each job count gets its own table: per-phase averages (wall ms, CPU ms, Mcyc,
Kalloc, MiB, throughput of wall time with a dash under 1 ms, share of wall time), the effective
GHz and cores in use, the min/median/p95/sd of wall ms, CPU ms and Mcyc, and heap requested per
round; then peak RSS. `SC_BENCH_OUT=<file>` writes the whole record as JSON (schema `"v":3`: the
lane in `lane`, one entry per job count in `modes`).

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
super-c fmt --migrate        # also write the newer syntax (below)
```

`@fmt.skip` on an item exempts it from formatting. fmt keeps the `;` after a statement `switch` and
after a value block's last expression, and `return a, b;`, as written. `--migrate` writes the newer
forms instead: `switch x { .. }` with no `;`, a value block's last expression with no `;` (`if c {
1 } else { 2 }`; value position is read from the syntax, so it needs no types), and
`return (a, b);`. The compiler's own sources keep the older forms until a release reads the newer
ones.

### Linting

```sh
super-c lint                 # default-on lints (errors on missing-free)
super-c lint --fix           # apply machine fixes, re-lint to fixpoint
super-c lint --const         # flag functions provably const-evaluable
super-c lint --fix --const   # make those functions const, save compile time
super-c lint --migrate       # also the uses the newer forms write shorter (below)
super-c lint --target=linux --arch=x86_64 --target-cpu=x86-64-v3   # another target's items and features
```

`lint --migrate` warns, with fixes, where a qualified variant value resolves bare (`Option::Some(x)`
to `Some(x)` through the expected type or as a prelude variant; a qualifier with type arguments only
where the expected type gives them) and where a call argument `x.as_str()` (`as_slice`,
`as_mut_slice`) converts as `&x` (`&mut x`). `lint --migrate --fix` applies them.

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
parameters. Hover adds the layout, as C++ language servers do (`layout_line`), one item per line in a
code block: a struct, union or enum's size and alignment, a variable's, a field's offset, size and
alignment. A use takes the instance it names (`S<i32>`, `g.t`); a declaration lays out its default
instance (each defaulted parameter bound to its default, `Svc.defaults`); none where a parameter without
a default decides it. Signature help (also on `<`) covers a type argument list (`Mul<`, `f::<`), read from the
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
                                       # (--link=, --header=, -I, --from=, --cflag=, --sysroot=)
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

[profile.fast]               # a profile: optimization level, code-generation flags, debug information,
                             # link inputs, strip
opt-level = 2                # 0 | 1 | 2 | 3 | "s" | "z": the LIR optimizer runs above 0
vectorize = false            # a code-generation flag over the level's default (each -f<flag> has its key)
fp-contract = "fast"         # "fast" | "off" (-ffp-contract=)
debug = true                 # DWARF line tables in the objects
ldflags = ["-lz"]            # link inputs in the C driver's syntax (-l, -L), after the manifest-level ones
link-args = ["-z,stack-size=16777216"] # -Wl,<entry> to the own linker, after ldflags (here ELF's stack);
                             # an option it does not take fails the link
strip = true                 # the own linker leaves out the symbol table and the debug sections
overflow-checks = false      # integer overflow wraps instead of trapping (default: checks at opt-level 0/1)
lockdep = true               # the runtime's lock-order checks (the build constant LOCKDEP; SC_LOCK_ORDER reports)
target-features = ["+simd128"] # replaces the build-level list for this profile

[profile.release]            # a section naming a built-in profile starts from its values and
opt-level = 2                # overrides only the keys it sets (an array replaces the whole array)

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
| `debug` | `opt-level = 0`, `debug` | Development (**default** of a manifest build) |
| `release` | `opt-level = 3`, `strip` | Shipping |
| `bench` | `opt-level = 3`, `debug` | Benchmarking/profiling |
| `test` | `opt-level = 1` | The `super-c test` runner, and the compiler under test when `test` has no `--profile` (`<out-dir>/test-bin`) |

The profiles live in `src/build_system/manifest.spc` (`add_builtin_profiles`). Integer overflow (signed
and unsigned) traps under `debug` and `test` and wraps under `release` and `bench` (language skill,
`operations.md`): `Profile::arith_wraps`, the `overflow-checks` key, else `opt-level` 2, 3, `"s"` or
`"z"`. A build with no profile (`super-c build foo.spc`) checks. `lockdep = true` compiles in the
runtime's lock-order checks (the build constant `LOCKDEP`); `SC_LOCK_ORDER` switches their reports on.

### Optimization levels and code-generation flags

`-O0` .. `-O3`, `-Os` and `-Oz` replace the profile's `opt-level`; `-f<flag>` and `-fno-<flag>` turn a
flag on or off over the level's defaults and the profile's keys, the last one winning; a profile key
`<flag> = true|false` does the same (`cg_effective`, `cg_flag` and `cg_key` in
`src/build_system/manifest.spc`). The level and the flags are part of the emit stamp and of each
native object's key.

| Flag | On at | Effect |
|------|-------|--------|
| `omit-frame-pointer` | 1, 2, 3, s, z | Functions address their frames through the stack pointer (arm64: leaf functions only, as Apple's ABI allows) |
| `inline` | 1, 2, 3, s, z | The LIR inliner runs (`-fno-inline`: no call inlines) |
| `inline-functions` | 2, 3, s | Calls inline past the ones that shrink the code (budgets per level: `inline_budget` in `src/driver/emit.spc`) |
| `unroll-loops` | 2, 3 | Loops whose trip count is known unroll fully (copies of up to 300 instructions at 3, 150 at 2) |
| `unswitch-loops` | 3 | A loop copies itself for each side of a branch on a value it does not change (up to 50 instructions) |
| `version-loops-for-bounds` | 3 | A loop copies itself without its bounds checks, entered when one test before it proves them all |
| `vectorize` | 2, 3, s | Counted loops over slices run 16-byte vectors, 4 interleaved (1 at s); isomorphic straight-line values, a loop's carried ones too, pack into vectors (`src/lir/slp.spc`); arm64 and x86-64 only |
| `strict-aliasing` | 2, 3, s, z | A typed access touches no object of another scalar type (language skill, `operations.md`) |
| `fast-math` | | `associative-math`, `reciprocal-math`, `finite-math-only`, `-fno-signed-zeros` and `fp-contract=fast` (`-ffp-contract=off` clears it), each its own flag too |
| `stack-protector`, `-strong`, `-all` | | A canary between a function's stack memory and its saved registers, checked before it returns: functions with a slot of 8 bytes or more, with any slot, or all; one at a time (`-fno-stack-protector` clears them). The native build counts a slot only when a block that may return reads its address: a slot only failure paths use (a panic's message) adds no canary (`lir::verify::protected`) |
| `function-sections`, `data-sections` | 1, 2, 3, s, z | A section per function or variable, and the link drops what nothing reaches from the entry, the exports and the kept symbols (the build adds `-Wl,-dead_strip` on Mach-O, `-Wl,--gc-sections` elsewhere) |
| `plt` | 0 to z | `-fno-plt`, ELF: a call of an extern declaration's function loads its address from its GOT slot; the x86-64 link turns one whose target the output defines into a direct call |

At 1, 2 and 3 a loop whose header test has at most 8 instructions also rotates (the test copied to its
end); `loop_budgets` in `src/driver/emit.spc` holds the budgets. `-march=C` is `--target-cpu=C`.

### Build cache

The build cache base is `$SC_CACHE_DIR`, else `~/.super-c/cache`. Each project caches in its own
root below it, `<base>/<project>` (`cache_root`: the manifest's `bin`, else its `[lib]` name, a byte
outside `[A-Za-z0-9._-]` or a leading `.` made `_`); script builds cache in
`<base>/.scripts`. Projects of one name share a root (the worktrees and copies of a project), and no
sweep reads or deletes outside the root of the build that runs it: not the base, not another
project's root. Only `super-c clean --full` deletes a root, its project's.

The sweeps (`sweep`) run after a successful build, at most once every 30 minutes each, in the root of
the build's project (or `.scripts`). The cache sweep (`<root>/.sweep`, `sweep_cache`) deletes the stale
prelude images (below). The project sweep (`<out-dir>/.sweep`, `sweep_project`): every out-dir entry
with nothing written for 30 days (a build tree, a link record, a binary) goes unless a build holds the
lock of a tree in it, as do the emitted trees below the root directory idle as long. `super-c clean`
runs the same sweeps at once; `super-c clean --full` removes the out-dir, the emitted trees and the
project's cache root.

The checked std prelude is cached as a file of the root's `prelude/` directory,
`<key><compiler>.img` (`src/driver/prelude_image.spc`). A build first loads the std prelude alone, resolves it and type
checks it up to the prelude gate (`prelude_stage`), with imports looked up under the std root only,
so the result does not depend on the project; the user's modules load after it (`load_user`). The
entry's name hashes the std directory as given, the target, arch, CPU features, vector settings,
`--test`, profile and profile names, `--bootstrap-tags`, the constant-evaluation
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

The C tree `--emit-c` writes compiles as few units as it can. A program whose own C (module, instance
and registry units) stays under 2 MiB is one unit: `__sc_unity.c` includes those units, and `__units`
lists it in their place. A larger program, such as the compiler itself, groups its units of one shard
and less than 64 KiB of C in packs of about 256 KiB, `__sc_pack<k>.c`, each including its members. The
pack count is a shard count of those units' bytes (`shard_policy`), which `__sc_shards` records
(`packs<TAB>n`) and the next emission keeps while every pack stays within half and one and a half times
the target; a unit's pack is the hash of its file stem modulo the count, so an edit changes its own pack
and no other.

### Wasm C library

A wasm build links no C library of the toolchain: the loader adds `std::rt::libc` and
`std::rt::libm` (`std/rt/libc.spc`, `std/rt/libm.spc`, `Package::rt_libc`, `rt_libm`) to every
`--target=wasm` program, and `std::rt::builtins` gives the compiler-rt routines the backends call. The
modules call WASI preview 1 directly and compute what wasi-libc computes, bit for bit
(`tests/codegen/wasm_libc_test.spc` checks the math functions, printf, strtod, strtol, qsort, the scanf
family, locales, the time functions, signals, `sbrk` and more against wasi-libc). The header facts still
read wasi-libc's headers from the sysroot. The modules define every C function and object that std, the
ffi bindings and the compiler bind for wasm, signals as wasi-libc's `wasi-emulated-signal` emulates them
included; a test (`every_c_symbol_a_wasm_build_binds_is_defined`) checks it from the sources, on every
host. Absent: long double conversions (`%Lf` fails), and `fork`, `execvp`, `pipe`, `dup`,
`pthread_create` and the other functions WASI has no call for; a program that calls one fails to link.

### CPU features

A CPU feature lets the compiler select instructions of an instruction-set extension. It
never changes a program's results: a vector operation gives the same lanes and the same
traps with and without it. The table is `src/ir/cpu_features.spc` (`CPU_FEATURES`), mirrored
by `std::cpu::Feature`; the C flag column is what the C tree of `--emit-c` compiles with:

| Name | Instruction set | Implies | C flag | Default |
|------|-----------------|---------|--------|---------|
| `simd128` | wasm32 | | `-msimd128` | off |
| `relaxed-simd` | wasm32 | `simd128` | `-mrelaxed-simd` | off |
| `sse2` | x86_64 | | | always on |
| `sse3` | x86_64 | `sse2` | `-msse3` | macOS, iOS, Android |
| `ssse3` | x86_64 | `sse3` | `-mssse3` | macOS, iOS, Android |
| `sse4.1` | x86_64 | `ssse3` | `-msse4.1` | Android |
| `sse4.2` | x86_64 | `sse4.1`, `popcnt` | `-msse4.2` | Android |
| `popcnt` | x86_64 | | `-mpopcnt` | Android |
| `cx16` | x86_64 | | `-mcx16` | macOS, iOS, Android |
| `lahf-sahf` | x86_64 | | `-msahf` | macOS, iOS |
| `avx` | x86_64 | `sse4.2` | `-mavx` | off |
| `avx2` | x86_64 | `avx` | `-mavx2` | off |
| `fma` | x86_64 | `avx` | `-mfma` | off |
| `bmi1` | x86_64 | | `-mbmi` | off |
| `bmi2` | x86_64 | | `-mbmi2` | off |
| `f16c` | x86_64 | `avx` | `-mf16c` | off |
| `lzcnt` | x86_64 | | `-mlzcnt` | off |
| `movbe` | x86_64 | | `-mmovbe` | off |
| `avx512f` | x86_64 | `avx2`, `fma`, `f16c` | `-mavx512f` | off |
| `avx512bw`, `avx512cd`, `avx512dq`, `avx512vl` | x86_64 | `avx512f` | `-m<name>` | off |
| `avx512vbmi`, `avx512vbmi2`, `avx512bitalg`, `avx512fp16` | x86_64 | `avx512bw` | `-m<name>` | off |
| `avx512vpopcntdq`, `avx512vnni` | x86_64 | `avx512f` | `-m<name>` | off |
| `gfni` | x86_64 | `sse2` | `-mgfni` | off |
| `vaes` | x86_64 | `avx2`, `aes` | `-mvaes` | off |
| `vpclmulqdq` | x86_64 | `avx`, `pclmulqdq` | `-mvpclmulqdq` | off |
| `aes` | x86_64 | `sse2` | `-maes` | off |
| `pclmulqdq` | x86_64 | `sse2` | `-mpclmul` | off |
| `avx10.1` | x86_64 | `x86-64-v4`, `avx512vbmi` to `avx512fp16` | `-mavx10.1` | off |
| `avx10.2` | x86_64 | `avx10.1` | `-mavx10.2` | off |
| `neon` | aarch64 | | | always on |
| `fp16` | aarch64 | `neon`, `rdm` | `+fp16` | macOS |
| `dotprod` | aarch64 | `neon`, `rdm` | `+dotprod` | macOS |
| `rdm` | aarch64 | `neon`, `crc`, `lse` | (Armv8.1-A) | macOS |
| `i8mm` | aarch64 | `neon`, `rdm` | `+i8mm` | off |
| `bf16` | aarch64 | `neon`, `rdm` | `+bf16` | off |
| `aes` | aarch64 | `neon` | `+aes` | macOS, iOS |
| `sha2` | aarch64 | `neon` | `+sha2` | macOS, iOS |
| `sha3` | aarch64 | `neon`, `rdm`, `sha2` | `+sha3` | macOS |
| `crc` | aarch64 | | `+crc` | macOS |
| `lse` | aarch64 | | `+lse` | macOS |
| `sve` | aarch64 | `fp16`, `rdm` | `+sve` | off |
| `sve2` | aarch64 | `sve` | `+sve2` | off |
| `sme` | aarch64 | `neon`, `rdm` | `+sme` | off |
| `sme2` | aarch64 | `sme` | `+sme2` | off |
| `sme-f64f64` | aarch64 | `sme` | `+sme-f64f64` | off |

The x86_64 baseline is `sse2` and, by platform, what the table's last column names (macOS and
the iOS simulator: `core2`, which every C compiler for them assumes; Android: its ABI). The x86-64 psABI levels
name sets: `x86-64` the baseline, `x86-64-v2` adds `sse3` to `lahf-sahf`, `x86-64-v3` adds `avx`
to `movbe`, `x86-64-v4` adds `avx512f`, `avx512bw`, `avx512cd`, `avx512dq` and `avx512vl`. A
feature list item may be a level name (x86_64 only; a build.toml list skips it on another
instruction set), and `--target-cpu=L` (`-march=L`) or the build.toml key `target-cpu = "L"` puts a level before
every feature list (the flag replaces the key, and the last flag wins; another name is an error, and
so is the flag on another instruction set, which the key skips). The C tree of an x86_64 build always
names its level, never the C compiler's default (Ubuntu 26.04's GCC defaults to `x86-64-v3`): its C
flags are `-march=x86-64-vN` for the highest level the set holds, else `-march=x86-64`, and then the
`-m` flag of each feature beyond that level, the platform baseline's included (macOS: `-msse3 -mssse3
-mcx16 -msahf`), in table order.

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
on `armv8-a`, and `+rdm` (it spells `+rdma`).

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
'neon' for wasm32; .."). The set is part of the emit stamp, of the per-unit cache key and of the
native record's key (a changed set emits and compiles every module again), puts each enabled feature's
C flag in the C tree's `__cflags`, and selects the instructions the native generators may use and the
`@simd_impl` entries the vector planner may use; a
build with no feature loads no backend file. A function with `@target_feature` is callable only from a build, or a function, that
holds its features.

```sh
super-c build --target=wasm --target-feature=+simd128
super-c build --target=wasm --target-feature=+relaxed-simd   # simd128 too
super-c build --target-feature=+i8mm,+bf16
super-c build --target-cpu=x86-64-v3
super-c build --target-feature=x86-64-v2,+avx2               # x86-64-v2, avx and avx2
```

On AVX-512 the vector planner prefers 256-bit entries: `--simd-width=512` or the build.toml key
`simd-width = 512` lets it use 512-bit ones (the width is part of the emit stamp). A function's
`@target_feature` adds its features to the build's set for that function and the functions with
vector code it calls: its code may use them, the planner
serves its vector operations from the entries that set holds, and, when the set holds entries the
build's does not, a call of a function with vector code that states no features runs a copy of it
compiled with the same set (`<symbol>__fs<hex>`,
in the callee module's instance file), whose calls do the same.

On x86_64 each function with vector code and no features of its own also gets a copy per level of
`--simd-dispatch=L` (build.toml `simd-dispatch`; a comma list of `x86-64-v2` .. `x86-64-v4`, default
`x86-64-v3` in a profile at opt-level 2 or more, `off` at 0 or 1 (`debug`, `test`: the copies make
the compile of vector code longer) and in a script build without `--profile`;
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
| `--profile=NAME` | Select build profile (also the value of `PROFILE`). A bare `build <file.spc>` without it applies no profile while `PROFILE` still reads `debug`: pass `--profile=debug` for its debug information |
| `-O0` .. `-O3`, `-Os`, `-Oz` | The optimization level, over the profile's `opt-level` (Optimization levels above) |
| `-f<flag>`, `-fno-<flag>` | A code-generation flag, over the level's defaults and the profile's keys (Optimization levels above) |
| `-h`, `--help` | Print the usage on stdout and exit 0 |
| `--jobs=N` | Worker count for the parallel stages and the native compile, and the jobserver slots that nested `super-c` processes share (default: build.toml `jobs`, else one per CPU) |
| `--out-dir=DIR` | Override output directory (a bare `build file.spc` emits under `DIR/<profile>/raw`) |
| `-o NAME` | Output binary name (`build`/`release`/`bindgen` only, not with `--emit-c`) |
| `--bin=NAME` | Build/run only that `[bin.NAME]` target; with `-o PATH`, link it at PATH. An error without build.toml |
| `--transpiler=CMD` | `build`/`release` from build.toml: run CMD as the transpile step (see External transpiler above). An error without build.toml |
| `--target=T` | Cross-compile OS: `windows`/`macos`/`linux`/`ios`/`android`/`wasm` (the value of `PLATFORM`). `wasm` reads its headers from `$WASI_SDK_PATH`'s sysroot (else `$WASI_SYSROOT`), links an 8 MiB stack placed first with std's C library (Wasm C library below), and strips at link time; `windows` links with an 8 MiB main-thread stack, so every target's main thread has the stack of Linux and macOS. A cross build needs the target's sysroot for its headers and libraries (`--sysroot=DIR`, else discovered) |
| `--arch=A` | Cross-compile arch: `x86_64`/`aarch64`/`wasm32` (the value of `ARCH`) |
| `--sysroot=DIR` | The target's C library tree, its headers and libraries (`src/bindgen/ctarget.spc`). Default: the SDK `SDKROOT`, `DEVELOPER_DIR` or xcrun names on Apple targets; on Linux the running system's `/usr/include`, for another instruction set only through its multiarch directory; the NDK of `ANDROID_NDK_HOME`; mingw-w64's tree beside a mingw `gcc` or `clang` in PATH; the WASI sysroot on wasm. Without one a build stops with "no sysroot found for <triple>" |
| `--emit-c` | `build`/`release`: write the program's C tree (`__units`, `__cflags`, `__ldflags`; Generated output below) and compile or link nothing |
| `--target-feature=L` | CPU features, a comma list of `+name`/`-name` applied after build.toml's `target-features` (see CPU features above) |
| `--target-cpu=L` | x86_64 level (`x86-64`, `x86-64-v2`, `x86-64-v3`, `x86-64-v4`) applied before every feature list; replaces build.toml's `target-cpu` |
| `--simd-width=W` | Vector width the planner prefers on AVX-512: `256` (default) or `512` |
| `--simd-dispatch=L` | x86_64: the levels of the run-time copies of vector code (comma list of `x86-64-v2` .. `x86-64-v4`, default `x86-64-v3` at opt-level 2 or more, `off` below and for a script without `--profile`), or `off`; replaces build.toml's `simd-dispatch` |
| `--bootstrap-tags` | Enable `@platform` bootstrap tag gating; accept unknown attributes, and a std `@intrinsic` this compiler does not know (its declaration and the std bodies that call it go unchecked; emitting such a body fails); a manifest build also skips build.toml sections and keys this compiler does not know (a previous release building newer source) |
| `--no-lint` | Disable lint pass |
| `--const-eval-steps=N` | Cap compile-time evaluation steps (~2M default) |
| `--const-eval-memory=SIZE` | Cap compile-time evaluation memory (~96 MiB default) |
| `--lib` | Build as library instead of binary (an error without build.toml). The own archiver writes a static library for every target (`link::ar`) |

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

`super-c build app.spc` writes its tree into `build/<profile>/raw/` (`build/debug/raw/` without
`--profile`): `PROFILE` makes the emission depend on the profile, so every profile has its own tree,
per-TU cache, manifest and orphan pruning, and switching profiles never mixes trees. A linking build
writes the native objects there; `--emit-c` writes the program's C instead.

```
build/
  debug/raw/
    super_rt.h        # the runtime header the C units include: libc includes, arithmetic helpers, prototypes
    __sc_fwd.h        # runtime and extern-block includes, dyn/extern declarations shared by every TU
    __sc_registry.c   # runtime helper definitions, ZST sentinels and the reflection registry, as C
    __sc_registry_n.o # the same, native (a linking build)
    __sc_manifest     # output paths, content hashes, header dependencies, shard counts
    __sc_shards       # the shard counts this build used (read back by the next build)
    __sc_native       # the native record: per module, the key its objects were compiled under
    __sc_hfacts       # the record of the header scan (`native_header_facts`)
    __ldflags         # linker flags collected from @link (one per line)
    .tu_cache         # per-TU journal/replay cache
    app.h             # one header per module (prototypes)
    app.o app__inst.o # a linking build: the module's object and its instances' object
    app.c app__inst.c # --emit-c: the module's C and its generic instances, glue and constants
    __units __cflags  # --emit-c: the units to compile and the flags of every compile
    __sc_t/           # one definition header per type (app__Point.h: typedef, definition, layout check)
    __std/            # demanded prelude modules only
```

`--emit-c` writes the readable C tree in its place: `super_rt.h` (libc includes, arithmetic helpers,
runtime prototypes), `__sc_fwd.h` (the runtime and extern-block includes shared by every unit), one
`.h`/`.c` per module, one definition header per type in `__sc_t/`, `<module>__inst.c`, and
`__units`, `__cflags`, `__ldflags`.

A manifest build (`super-c build` with `build.toml`) works in one directory per target and
profile: `<out-dir>/<profile>` for the main binary, `<out-dir>/<profile>-bin-NAME` and
`<out-dir>/<profile>-lib` for the other targets. The emitter writes `raw/` there (the per-TU cache
and `__sc_manifest` with it), and the link reads that one tree: the emitter compares each file with
what it holds and writes only the files whose content changed, so an unchanged file keeps its mtime
(`publish_file`). A build whose emission fails writes no unit or header, so the tree stays as the
last successful emission left it. The emit stamp `.emit_stamp` lands beside `raw/`. The link record
`<out-dir>/__link-<hash of the binary's path>.cmd` holds the own linker's command line (` +archive` for
a static library, ` +strip` for a stripped link): another command, a missing binary or a newer object
links again. `super-c test` runs the same engine on the generated test root under the `test` profile
in `<out-dir>/test/` (`raw/`, the runner `__tests`), with the emit stamp, the per-TU cache and the
native record making an unchanged suite a link check; `super-c bench` uses `<out-dir>/bench/<profile>/`.
Engine code takes every manifest output path from out-dir (the `out-dir` key or `--out-dir`, default
`build`) and never spells `build/`. The tree of a file build (`super-c build <root.spc>`) under
`<root dir>/build/<profile>/raw` is the one exception.

One process builds a profile directory at a time: a build holds the lock file `.lock` in it
(`bsys::tree_lock`: a POSIX record lock, `LockFileEx` on Windows, none under WASI) from the emit to
the link, and a file build holds its `build/<profile>` the same way. A second build of
the directory prints "build: waiting for another build of '<dir>'" and waits at most 30 minutes. Without
the lock it would rewrite the files the first one reads, which could compile or link a torn file. The
OS releases the lock when the
process ends, also by a crash; a transpiler child (`--emit-sub`) runs under its engine's lock.

Parallel analysis (the resolve frontier, the type check, borrow check and always-panics
item jobs, the emission frontier) is used only when the package holds at least 256 KiB of
non-prelude source (`Package::analysis_jobs`,
`loader::PAR_MIN_USER_BYTES`); below that the worker pool costs about as much CPU as the
serial compile and gains a few milliseconds at most, so small compiles run serially and
hand their jobserver slots back. The native compile of the modules is parallel either way.

The C tree of `--emit-c` builds with any C compiler and no `-I` flag: compile each unit `__units`
lists with the flags of `__cflags`, then link the objects with the flags of `__ldflags`, one per line
(`ci/cc_tree.sh` does it: `sh ci/cc_tree.sh build/debug/raw app`). `__sc_unity.c` and
`__sc_pack<k>.c` include other units, and `__units` names them in place of their members. `__cflags`
holds the dialect and the feature macros of `push_c_env` (without them Darwin's
`struct stat` lacks the fields std binds), `-funsigned-char` (the language's `char` is unsigned, and
`super_rt.h` fails to compile without it), `-ffp-contract=off` (only an explicit `fma` fuses, so float
results equal the constant evaluator's), `-Werror=incompatible-pointer-types`, `-fno-builtin-<f>` for
the transcendental libm functions (`LIBM_AS_WRITTEN` in `src/driver/emit.spc`), the target and CPU
feature flags, the profile's `-O` level and `-g`, and `-DSC_ARITH_WRAP` when the profile wraps
integer overflow.
