# build.toml

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
| `vectorize` | 2, 3, s | Counted loops over slices, and loops that step pointers beside a counter, run 16-byte vectors, 4 interleaved (1 at s); what an interleaved loop leaves runs one vector at a time (an epilogue); isomorphic straight-line values, a loop's carried ones too, pack into vectors (`src/lir/slp.spc`); arm64 and x86-64 only |
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
budgets and `SC_TYPE_COLLIDE`, then the compiler identity (`compiler_id`, `exe_id`: the content hash
the compiler's linker recorded, else the file's). The image records the
real path of the compiler that wrote it, the content hash and modification time of every prelude file
as the check read it, the clock before the load, and the listing of every directory the std
imports were looked up in, as the load listed it (the std directory's from before the load), so an
edit made during the check makes the next build check again; a build that finds both unchanged loads the image in place of parsing and checking std, and
checks the prelude again on any difference. A file whose modification time is the recorded one and
lay two seconds or more before the load keeps its hash unread, as the emit stamp's inputs do. A build that checks the prelude writes the image (not
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
detector's answer, read once per TU of the C tree; in a native build a byte a constructor sets before
`main`, 0 (no copy) until then). A copy calls copies, so one check runs where code without the
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
| `--transpiler=CMD` | `build`/`release` from build.toml: run CMD as the transpile step (see External transpiler in [commands.md](commands.md)). An error without build.toml |
| `--target=T` | Cross-compile OS: `windows`/`macos`/`linux`/`ios`/`android`/`wasm` (the value of `PLATFORM`). `wasm` reads its headers from `$WASI_SDK_PATH`'s sysroot (else `$WASI_SYSROOT`), links an 8 MiB stack placed first with std's C library (Wasm C library below), and strips at link time; `windows` links with an 8 MiB main-thread stack, so every target's main thread has the stack of Linux and macOS. A cross build needs the target's sysroot for its headers and libraries (`--sysroot=DIR`, else discovered) |
| `--arch=A` | Cross-compile arch: `x86_64`/`aarch64`/`wasm32` (the value of `ARCH`) |
| `--sysroot=DIR` | The target's C library tree, its headers and libraries (`src/bindgen/ctarget.spc`). Default: the SDK `SDKROOT`, `DEVELOPER_DIR` or xcrun names on Apple targets; on Linux the running system's `/usr/include`, for another instruction set only through its multiarch directory; the NDK of `ANDROID_NDK_HOME`; mingw-w64's tree beside a mingw `gcc` or `clang` in PATH; the WASI sysroot on wasm. Without one a build stops with "no sysroot found for <triple>" |
| `--emit-c` | `build`/`release`: write the program's C tree (`__units`, `__cflags`, `__ldflags`; Generated Output in [generated-output.md](generated-output.md)) and compile or link nothing |
| `--target-feature=L` | CPU features, a comma list of `+name`/`-name` applied after build.toml's `target-features` (see CPU features above) |
| `--target-cpu=L` | x86_64 level (`x86-64`, `x86-64-v2`, `x86-64-v3`, `x86-64-v4`) applied before every feature list; replaces build.toml's `target-cpu` |
| `--simd-width=W` | Vector width the planner prefers on AVX-512: `256` (default) or `512` |
| `--simd-dispatch=L` | x86_64: the levels of the run-time copies of vector code (comma list of `x86-64-v2` .. `x86-64-v4`, default `x86-64-v3` at opt-level 2 or more, `off` below and for a script without `--profile`), or `off`; replaces build.toml's `simd-dispatch` |
| `--bootstrap-tags` | Enable `@platform` bootstrap tag gating; accept unknown attributes, and a std `@intrinsic` this compiler does not know (its declaration and the std bodies that call it go unchecked; emitting such a body fails); a manifest build also skips build.toml sections and keys this compiler does not know (a previous release building newer source) |
| `--no-lint` | Disable lint pass |
| `--const-eval-steps=N` | Cap compile-time evaluation steps (~2M default) |
| `--const-eval-memory=SIZE` | Cap compile-time evaluation memory (~96 MiB default) |
| `--lib` | Build as library instead of binary (an error without build.toml). The own archiver writes a static library for every target (`link::ar`) |
