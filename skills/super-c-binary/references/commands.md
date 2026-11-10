# Subcommands

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
super-c clean                # run the project's sweeps now (see Build cache in build-toml.md)
super-c clean --full         # remove the out-dir, every <root dir>/build/<profile> tree and the project's cache root; never a user directory
```

The build system reads `build.toml` in the working directory. An emit stamp skips the
entire transpile when no input changed (~25 ms no-op); it records the identity of the compiler
that emitted the tree (`exe_id`: the content hash its linker recorded, a Mach-O `LC_UUID` or an ELF
GNU build-id note, read from the file's head; else the content hash of the whole file. A different
compiler at the same path with the same mtime transpiles again,
as does the per-TU cache, keyed on the same identity; a WASI guest hashes the module file its absolute
argv[0] names, as `wasmtime run --dir=/ --argv0 <abs path>` gives it, and keeps neither stamp nor
cache when argv[0] is relative), the std directory (a build under another std tree transpiles
again, `stamp_opt_line`), the profile's `opt-level` and code-generation flags with the command line's
`-O` and `-f` flags over them (`profile_codegen`), the loaded module files and
the `.spc` listing of every directory the loader searched, so a new file that would shadow an
import also makes the stamp stale. A module and `build.toml` are recorded as the build read them (the
content hash of the text read, the mtime of the stat before the read), so an edit made during the
build makes the next one transpile again; a directory whose listing changed during the build writes
no stamp. The stamp lives in the target's profile directory, so it
is per profile. A build that transpiles deletes the stamp first; the emission writes its record to
`.emit_stamp.new`, and the engine moves it into place only after the whole tree is written, so a
build that stops part way leaves no stamp for a mixed tree. The native backend compiles the modules in
parallel, largest first, a large module as several objects of about 60000 LIR instructions each, and a
module whose key matches the native record (`__sc_native`) keeps its objects.

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
GHz and cores in use, the min/median/p95/sd of wall ms, CPU ms and Mcyc, heap requested per
round, and the peak memory of one more cold build in a process of its own (the compiler the rounds
linked builds the compiler; `fresh_peak_mib`): the physical footprint on Apple (`time -l`'s peak
memory footprint), the resident set's high-water mark on Linux (from the child's `SC_BUILD_STATS`
record), the peak working set on Windows. Then the bench process's peak RSS over every round, which
also holds what the allocator kept from earlier rounds. `SC_BENCH_OUT=<file>` writes the whole record
as JSON (schema `"v":3`: the lane in `lane`, one entry per job count in `modes`).

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
super-c fmt -s               # first remove what bodies do not need (`--simplify`, below)
```

`@fmt.skip` on an item exempts it from formatting. fmt keeps a block's last `;` as written: it
decides whether the block is a value (`{ x }`) or a statement block (`{ x; }`). It keeps
`return a, b;` and `return (a, b);` as written.

`fmt -s` (`--simplify`) removes the turbofish lists (`Vector::<u8>::new()`, `id::<u8>(x)`,
`x.f::<T>()`) and `let` annotations (`let n: usize = v.len();`) that function bodies do not need,
then formats. It loads the paths as `lint` does and checks them once: after a body checks, the
checker takes its candidates out of the syntax and checks that body again (`tc_simplify`); a group
that changes a node's type or reports an error goes back and splits in two. A check of the edited
batch from its text then confirms the removals: a function whose nodes type otherwise or that
reports an error keeps all its candidates, and the batch is checked again. The cost is about two
`lint` runs. An annotation that gives an unsuffixed literal another type than its default
(`let x: u8 = 3;`) is not a candidate. The program must check before ("'-s' needs a program without
errors"); `--check` does not combine with `-s`. A removed turbofish can leave a qualified variant
(`Option::None`), which the default lint then shortens.

### Linting

```sh
super-c lint                 # default-on lints (errors on missing-free)
super-c lint --fix           # apply machine fixes, re-lint to fixpoint
super-c lint --const         # flag functions provably const-evaluable
super-c lint --fix --const   # make those functions const, save compile time
super-c lint --target=linux --arch=x86_64 --target-cpu=x86-64-v3   # another target's items and features
```

Two default lints write the shorter forms, with fixes: a qualified variant value that resolves bare
(`Option::Some(x)` to `Some(x)` through the expected type or as a prelude variant; a qualifier with
type arguments only where the expected type gives them; none where another binding in scope takes
the bare name), and a call argument `x.as_str()` (`as_slice`, `as_mut_slice`) on a place that
converts as `&x` (`&mut x`).

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
`src/driver/emit.spc`). It lints std modules only when a listed file names one. A listed file of
the std tree in use (`std/` or `ffi/` beside the `SC_STD_DIR` directory, such as a copy inside the
workspace) loads as the std module its imports name, wherever the project roots, and so does a
swept file in the language server (`loader::batch_module`).

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
