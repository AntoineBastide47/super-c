---
name: super-c-self-hosting
description: "Documents the Super-C self-hosting contract: the byte-identical two-generation fixpoint, the bootstrap workflow, @platform tags, recurring porting-bug patterns, and the natural-code principle. Use when modifying the compiler, porting a pass to Super-C, or debugging fixpoint failures."
allowed-tools: Bash Read
---

# Super-C Self-Hosting

## Agent checklist

- Treat any gen-1 versus gen-2 diff as a correctness failure.
- Follow the clean-room fixpoint reference: identical source and library paths, caches disabled.
- Fix compiler defects instead of adding source workarounds.
- Follow the new-syntax cadence when parser, attribute, or manifest syntax changes.

The Super-C compiler is self-hosting: it compiles itself. This is a hard correctness
contract, not a development convenience.

## The Fixpoint Contract

Gen-1 (the compiler built by itself) compiles its own source to produce gen-2. The
emitted C from gen-1 and gen-2 must be **byte-identical**. Any non-empty diff is a
semantic regression.

The current documentation baseline is recorded in `skills/README.md` as a git tag.

## The Bootstrap Workflow

```sh
super-c command bootstrap
```

This runs three steps:
1. Current compiler builds stage-1 with bootstrap tags (`--bootstrap-tags`)
2. Stage-1 builds stage-2
3. Stage-1 is removed

The verified binary is stage-2.

See [fixpoint-verification.md](references/fixpoint-verification.md) for the clean-room
diff protocol.

## The Bootstrap Sequence and the Rollback Boundary

`sh ci/gate.sh` runs the production sequence: the latest release binary (the last
verified bootstrap compiler) builds the current sources (`check.sh`), that result
builds generation one, generation one emits generation two at the same path with the
same options, the two trees are compared byte for byte, and generation two is compiled
and run: it is the compiler that runs every later step of the gate (the one-worker and
every-core builds under each task-delay seed, the targets, the profiles). Its
one-worker tree must equal generation one's every-core tree, so the fixpoint holds
across generations and worker counts at once. `check.sh` (the commit hook) ends with
`sh ci/gate.sh --core` over the compiler its bootstrap step rebuilt: the input lists, the
fixpoint, the worker-count identity under every seed, and the strict C warnings (about 30 s on
a warm object cache). The targets, profiles and benchmark steps (about 130 s) run in the
release workflow (`sh ci/gate.sh --no-check`, macOS and Linux).

The wasm leg of the release and debug workflows checks the fixpoint for the wasm compiler with
the CLI only: in one project copy, the native engine builds gen2 with gen1 (the `super-c.wasm`
artifact, under wasmtime) as its `--transpiler`, then gen3 with gen2 as its transpiler, and the
two emitted trees at the same path (`build/release/raw`) must be byte-identical. No diff against
the native tree: instance homing follows hash orders that differ between 32- and 64-bit hosts.

The rollback boundary is the latest GitHub release: its binary and its tag are the
named verified compiler and source revision, outside every build directory that
`super-c clean` removes. A rollback downloads that binary (`check.sh` does, for the
bootstrap) and checks out the tag. No persistent semantic cache exists: the per-TU
cache is keyed by the compiler binary and the emitted bytes, and the object cache by the
C compiler version, the flags and the C text, so a rollback converts nothing.

## The Natural-Code Principle

A workaround for natural Super-C code **is** a compiler bug. The correct response is:

1. Fix the compiler.
2. Write the natural code.

If the root-cause fix is unclear, unsafe, or too large, **stop and ask** before adding a
workaround. Do not ship a workaround and move on.

This principle is what makes self-hosting a correctness tool: every language feature the
compiler uses must work correctly, because the compiler is the most exercised user of its
own language.

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

The same order binds new std surface that the release cannot parse or fold. The formatter
ships in the same commit as the parser: an old `fmt` deletes syntax it does not know. Until
step 4, tests embed the new syntax only inside string literals.

## Runtime Helpers Called by std

A C helper that std calls goes in a header beside std (for example `std/int128.h`), never in
the compiler-embedded `super_rt.h` (`src/driver/rt_c.spc`): the release binary emits its own
older runtime header, so a helper added there is missing when the release builds the tree.

## Recovery from a Broken Compiler

A compiler that over-rejects valid source cannot rebuild itself, and reverting the source does
not help. Download the release binary as `check.sh` does
(`gh release download --pattern super-c-macos-arm64.tar.gz`), build the source with it as
`check.sh` does (`build --bootstrap-tags`), then continue with the rebuilt compiler.

## Platform Lanes

### Windows (mingw)

A Windows-only failure often comes from mingw emulating POSIX:

- `stat().st_ino` is 0, so file identity uses `GetFileInformationByHandle`
  (`sc_same_file` in `src/driver_shim.c`).
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

Stack traces: `sc_trace_install()` (`src/driver_shim.c`, called from `src/main.spc`) prints,
on `SIGABRT`, the PE base (`trace: base %p`) and each return address as `trace: +0x<off>`.
It is in the compiler source, so gen-1 carries it. Symbolize against the same binary:
`x86_64-w64-mingw32-addr2line -f -e super-c.exe <0x140000000 + off>`.

### wasm32

A single C flag that makes a wasm failure disappear (`-fwrapv`, `-fno-strict-aliasing`)
usually changes the heap layout, not the defect: do not accept it as the fix. Bisect at the
object level: compile every TU with both toolchains, link mixed sets, and binary-search for
the TU that changes the result.

## Single Compilation Path

Only the multi-file `build/` tree emitter exists. The single-TU emitter and REPL were
deleted. One path eliminates divergence bugs: every output path that exists must be
correct, and maintaining two doubles the surface area.

## Porting-Bug Patterns

These patterns recurred across the typechecker and codegen ports. They are the bugs most
likely to appear when porting a new compiler pass to Super-C.

### Moving an owning field out of a reference

An owning (`Free`) field cannot be moved out through a reference: the owner would later
free a hollowed-out value. The error is
`cannot move a field out of a reference; use 'replace' to swap ownership out`.

```superc
// WRONG: moves self.m out through &mut self (compile error)
extend Loader {
    fn run(self: &mut Loader) usize {
        let a = self.m;              // error: cannot move a field out of a reference
        return use_module(a);
    }
}

// RIGHT: borrow it, or replace() to swap ownership out atomically
extend Loader {
    fn run(self: &mut Loader) usize {
        let a = &self.m;
        return use_module(a);
    }
}
```

This is the rule behind the keystone bug of the self-hosting effort: a pass that took the
module's `Ast` value out of the package left an empty placeholder behind. The compiler
re-derives access per use (`self.mod_ast(module_id)`) instead of holding the value.

### Enum-shift gotcha

Casts on enum values combined with shift operators need explicit parentheses. The
precedence differs from C.

### Stored `&mut` live across `&&` / `||`

Borrows are non-lexical, so a *temporary* `&mut` in a call argument ends at the call:
`if check(&mut state) && state.ready` is legal. The conflict needs a **stored** borrow
still live across the expression:

```superc
let r = &mut v;
// WRONG: v is read while r is still mutably borrowing it (r used on the right)
if v.len() > 0 && r.len() > 0 { .. }
// error: cannot use this value while it is mutably borrowed

// RIGHT: finish with the borrow first, or hoist its result to a let
let has = r.len() > 0;
if v.len() > 0 && has { .. }
```

### Container borrow held across mutation

A reference obtained from a container conflicts with mutating that container while the
reference is still used afterward:

```superc
let t = v.at(0);
v.push(6);          // error: cannot borrow as mutable while already borrowed as immutable
return *t;

// RIGHT: copy the element out first (ends the borrow at the read)
let t = *v.at(0);
v.push(6);
return t;
```

Extracting a Copy field in a call argument (`self.process(self.type_at(x).name)`) is
*not* an error: the immutable borrow ends when the field read completes, before the
`&mut self` call begins.

### Result tied to `&mut self` held across another `&mut self` call

A method result whose lifetime elides to `self` keeps `*self` borrowed, also when `self`
is a `&mut` parameter:

```superc
// WRONG: v borrows self.items; the &mut self call conflicts while v is live
let v = self.item_at(i);
self.note(v.span);   // note(self: &mut Self, ..)
use(v);

// RIGHT: copy what you need first, or end the borrow before the call
let sp = self.item_at(i).span;
self.note(sp);
```

An accessor returning data behind a raw-pointer field names an unbounded lifetime
(`fn p<'a>(self: &Self) &'a Package`), so its result does not hold `self`.

### Bare char as C string

A single `char` passed via `&sent` to a `strlen`-based API reads past the byte. Always
provide a NUL-terminated buffer.

## Cosmetic Deltas

The self-hosted output is semantically identical to the C reference compiler's output
but has two harmless cosmetic differences:
- East vs west `const` on value parameters
- 8 extra redundant forward declarations

These do not affect the fixpoint (gen-1 == gen-2) or the compiled binary.
