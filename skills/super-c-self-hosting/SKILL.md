---
name: super-c-self-hosting
description: "Documents the Super-C self-hosting contract: the byte-identical two-generation fixpoint, the bootstrap workflow, @platform tags, recurring porting-bug patterns, and the natural-code principle. Use when modifying the compiler, porting a pass to Super-C, or debugging fixpoint failures."
allowed-tools: Bash Read
---

# Super-C Self-Hosting

## Agent checklist

- Treat any gen-1 versus gen-2 diff as a correctness failure.
- Use the clean-room fixpoint reference at the same filesystem path.
- Fix compiler defects instead of adding source workarounds.
- Check bootstrap-tag ordering when parser or attribute syntax changes.

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

`@platform(windows|macos|linux)` gates items via a 3-bit mask. When adding `@platform`
support itself (or any feature that changes the parser), a **mandatory two-generation
bootstrap** is required:

1. The pre-feature compiler cannot parse the new attribute.
2. Build Gen-A: the old compiler builds the new source (the feature code does not use
   itself yet).
3. Build Gen-B: Gen-A builds the source that uses the new feature.
4. Wrong order = "unknown attribute namespace" at parse time.

## Single Compilation Path

Only the multi-file `build/` tree emitter exists. The single-TU emitter and REPL were
deleted. One path eliminates divergence bugs — every output path that exists must be
correct, and maintaining two doubles the surface area.

## Porting-Bug Patterns

These patterns recurred across the typechecker and codegen ports. They are the bugs most
likely to appear when porting a new compiler pass to Super-C.

### Moving an owning field out of a reference

An owning (`Free`) field cannot be moved out through a reference — the owner would later
free a hollowed-out value. The error is
`cannot move a field out of a reference; use 'replace' to swap ownership out`.

```superc
// WRONG: moves self.m out through &mut self — compile error
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

Borrows are non-lexical, so a *temporary* `&mut` in a call argument ends at the call —
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
*not* an error — the immutable borrow ends when the field read completes, before the
`&mut self` call begins.

### Bare char as C string

A single `char` passed via `&sent` to a `strlen`-based API reads past the byte. Always
provide a NUL-terminated buffer.

## Cosmetic Deltas

The self-hosted output is semantically identical to the C reference compiler's output
but has two harmless cosmetic differences:
- East vs west `const` on value parameters
- 8 extra redundant forward declarations

These do not affect the fixpoint (gen-1 == gen-2) or the compiled binary.
