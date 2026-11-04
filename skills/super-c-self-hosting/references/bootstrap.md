# Bootstrap Details

## The Bootstrap Sequence and the Rollback Boundary

`sh ci/gate.sh` runs the production sequence: the latest release binary (the last verified bootstrap
compiler) builds the current sources (`check.sh`), that result builds generation one in a clean tree
under the test profile (optimized, overflow checks kept), generation one builds generation two at the
same path with the same options, and the two binaries must be byte-identical (`cmp`). Generation two
runs every later step of the gate: the one-worker and every-core C emissions under each task-delay
seed (`--emit-c`), which must give byte-identical trees, type tables and item indexes; the one-worker
and every-core debug builds, whose native objects must be byte-identical; the readability rules of
the emitted C; and, when `SC_TEST_CC` names a C compiler, the strict C warnings over every unit of the
tree (its `__cflags` plus `CONTRACT_STRICT_CFLAGS`, `-fsyntax-only`). `check.sh` (the commit hook) ends
with `sh ci/gate.sh --core` over the compiler its bootstrap step rebuilt: every step but check.sh
itself. The release workflow runs `sh ci/gate.sh --core` on macOS, Linux and Windows.

The wasm leg of the release workflow (its `wasm-checks` job) checks the fixpoint for the wasm compiler with
the CLI only: in one project copy, the native engine builds gen2 with gen1 (the `super-c.wasm`
artifact, under wasmtime) as its `--transpiler`, then gen3 with gen2 as its transpiler, and the
two trees of objects at the same path (`build/release/raw`) must be byte-identical. No diff against
the native tree: instance homing follows hash orders that differ between 32- and 64-bit hosts.

The rollback boundary is the latest GitHub release: its binary and its tag are the
named verified compiler and source revision, outside every build directory that
`super-c clean --full` removes. A rollback downloads that binary (`check.sh` does, for the
bootstrap) and checks out the tag. No persistent semantic cache exists: the per-TU cache and the
native record are keyed by the compiler binary and the emitted bytes, and the prelude images by the
compiler identity, so a rollback converts nothing.

## @platform Bootstrap Tags

```superc
@platform(macos)
fn platform_init() { /* macOS-specific */ }
```

`@platform(windows|macos|linux|wasm|ios|android)` gates items via a 6-bit mask. When adding `@platform`
support itself (or any feature that changes the parser), a **mandatory two-generation
bootstrap** is required:

1. The pre-feature compiler cannot parse the new attribute.
2. Build Gen-A: the old compiler builds the new source (the feature code does not use
   itself yet).
3. Build Gen-B: Gen-A builds the source that uses the new feature.
4. Wrong order = "unknown attribute namespace" at parse time.

The same rule binds build.toml: the bootstrap release reads the manifest, so a new section or
key lands in the source only after a release whose `--bootstrap-tags` build skips what it
does not know (sections and keys, not new TOML syntax). Until then keep the addition
commented out.

A conformance the new compiler DERIVES is an ordinary interface to a release that predates the
derivation: the release checks a bound or a superinterface against written conformances only. So
where the compiler's own sources (and the std they use) instantiate such a bound, restate the
conformance explicitly (`extend u32 as Copy {}`, `extend Global as Copy {}`, the AST pool element
types); the new compiler accepts a restatement only where its derivation agrees.

## New Syntax Cadence

CI bootstraps from the previous release, so new syntax reaches `src/`, `std/` and `ffi/` in
four ordered steps:

1. Commit the parser and formatter change; the source keeps the old syntax.
2. Cut a release.
3. Validate the release: download its binary and build the tree with it.
4. Write source in the new syntax.

The same order binds new std surface that the release cannot parse or fold, except a new
`@intrinsic`: a release whose `--bootstrap-tags` accepts unknown intrinsics builds a std that declares
and calls one, as long as the compiler's own build emits no body that calls it, so the intrinsic,
its lowering and its std use land in one commit. A new `TypeInfo` field is such surface: a release
fills only the fields it knows and builds no descriptor otherwise (`SC_CEMIT_STATS=1` shows
`cemit-reflect: N skipped`, then "the backend refused N emissions"), and std's derive helpers
(`reflect_string`) build descriptors in the compiler's own build. std code the release's checkers
reject is too: until the release that accepts it, std writes a form both accept. The formatter
ships in the same commit as the parser: an old `fmt` deletes syntax it does not know. Until
step 4, tests embed the new syntax only inside string literals.

The visibility levels `pub(module)` and `pub(package)` and the implicit directory imports are such new syntax: until
a release parses them, `std/` and `src/` write `pub` and import each file of a directory (`std::platform` items
are `pub`, documented as unstable), and tests use the new forms only inside string literals. The release after
that turns every `std::platform` item into `pub(package)`; the compiler's `build.toml` already sets
`std_internals = true`.

## Runtime Helpers Called by std

No hand-written C sits beside std or ffi. The runtime every program links is Super-C,
`std/rt/base.spc` (traps, hooks, the leak tracker, the overflow report): the loader adds it to every
package (`Package::rt_module`), and nothing imports it. std, ffi and the compiler's own modules bind
its entry points by C symbol with a header-less `extern "C"` block (`__sc_stack_arm`,
`__sc_set_cancel_hook`, `sc_lk_stats`), so a release that predates the module builds the same
source against its own runtime: it never loads `std/rt/base.spc`, which may then use what only
the new compiler knows (`@intrinsic("frame.return_address")`). An import of the module from code
the release builds would define every runtime symbol twice. A new entry point keeps that rule: its
callers bind it by C symbol, after a release whose runtime defines it.
A backend primitive std calls (the bit counts, the 128-bit fast paths, `sc_int_overflow`) lives in
the C backend's runtime header (`super_rt.h`, `src/emit/rt_h.spc`). The release binary emits its
own older header, so the two land in order: the primitive in one commit, std's use of it only
after a release that carries it (the same cadence as new syntax).

## Platform Lanes

### Windows (mingw)

A Windows-only failure often comes from mingw emulating POSIX:

- `stat().st_ino` is 0, so file identity uses `GetFileInformationByHandle`
  (`std::platform::fs::stat` on Windows, read by `util::same_file`).
- Files and stdio open in text mode: write with `"wb"` and use binary stdio, else CRLF
  breaks `\`-continued macros and LSP framing.
- `_dup2` returns 0 on success. `_spawnv` joins arguments with spaces and quotes nothing.
- `abort()` is fail-fast (exit code 0xC0000409): no flush, no `atexit`, no leak report.
- `freopen` resets a stream to full buffering and `_IOLBF` acts as `_IOFBF`: a capture
  stream needs `_IONBF` (`src/driver/test.spc`).
- `tmpfile()` writes to the drive root: use `GetTempPathA` plus `fopen("wb")`. No
  `open_memstream`.
- No `fork`: the test parent runs the global `@test_init`/`@test_free` pair once and each
  child rebuilds a private env.

Stack traces: `sc_trace_install()` (`src/driver_shim.spc`, called from `src/main.spc`) prints,
on `SIGABRT`, the PE base (`trace: base %p`) and each return address as `trace: +0x<off>`.
It is in the compiler source, so gen-1 carries it. Symbolize against the same binary:
`x86_64-w64-mingw32-addr2line -f -e super-c.exe <0x140000000 + off>`.

### wasm32

A flag that makes a wasm failure disappear (`-fno-strict-aliasing`, `-fno-vectorize`, `-O0`)
names the pass to bisect, not the fix. Bisect at the object level: build the modules with both
settings, link mixed sets, and binary-search for the module that changes the result.
