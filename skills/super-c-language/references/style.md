# Super-C Style Guide

## Naming

| Element | Convention | Example |
|---------|-----------|---------|
| Functions, variables, files | `snake_case` | `parse_size`, `token_count` |
| Types, enum variants | `PascalCase` | `Counter`, `Shape::Circle` |
| Constants | `UPPER_SNAKE_CASE` | `SOURCE_PAD`, `ERRORS_MAX` |

- Choose precise nouns and verbs that describe the domain.
- Units and qualifiers go **last**, most significant to least: `latency_ms_max`.
- Do not abbreviate unless the name is a primitive loop index or a well-known domain term.
- Prefix a helper with its parent operation: `resolve_call_args()` for `resolve_call()`.
- Do not reuse one name for different concepts when a qualifier removes ambiguity.
- Prefer related names that make related code visually symmetric when clarity is equal.
- Prefer names that also read well in diagnostics and documentation.
- The concurrency feature is "coroutines", spawned with `launch`. Never write "goroutines" or
  `go`, in code, docs or commit messages.

## File Organization

Top-down order within each file:

1. Module-level comment (if needed)
2. Imports
3. Constants
4. Types (structs, enums, unions, type aliases)
5. Main entry point or constructor
6. Methods and helpers
7. One `extend` block per type at file end
8. Interface conformance blocks (`extend T as I { .. }`) separate

Module-level constants must be declared **above** their first use. Keep important
definitions near the top when dependencies allow it.

## Methods

- A free function whose first parameter is `&T` or `&mut T` of a type defined in the same file
  is a method in that type's `extend` block. Some older code keeps free-function receivers; do
  not copy it.
- Exceptions stay free: helpers on std or foreign receivers (`String`, `Vector`, a type of
  another module) and comparators or sort keys passed as function pointers.
- On conversion, drop a prefix that repeats the type (`lexer_error` becomes `error`); keep a
  prefix with other meaning (`b_*` build, `ex_*` expression).
- Never move a module-level constant into an `extend` block: it becomes an associated
  constant and bare references to it break.
- `super-c fmt` only parses, so a bad rename shows only at `super-c build`.

## Formatting

- `super-c fmt` is canonical. Treat its output as authoritative.
- Wadler-style layout, width 120.
- 4-space indentation.
- `@fmt.skip` on an item exempts it from the formatter.
- Fully canonical: blocks always expand, and the renderer owns every line break.
- A parameter group (`a, b: T`) prints as written; separately written parameters never merge.
  A comment in the parameter list prints each parameter on its own.
- `fmt` refuses to write a file when its output's comment count differs from the lexer's
  comment-token count.

## Comments

Add a comment only when it communicates information the code or signature cannot.

**Valid reasons:**
- Ownership transfer
- Safety preconditions
- Invariants
- Panic or trap behavior
- Sentinel conventions
- Deliberate performance constraints
- Bootstrap or fixpoint constraints

**Do not add comments that:**
- Restate a name or signature
- Narrate control flow
- Describe obvious code
- Contain development history or process notes
- Use filler ("simply", "just", "helper for")

**Delete-test:** if removing the comment does not remove important information, remove the
comment.

Full-line comments: sentences with a space after `//`, initial capital, terminal
punctuation.

```superc
// Keyword lookup bucketed by identifier length, then filtered on the first byte.
```

Trailing end-of-line comments: short phrase, no terminal punctuation.

```superc
let mut mul: u64 = 1;  // scale factor
```

## Functions and State

- Declare variables at the smallest useful scope.
- Initialize variables at declaration (split init is the exception, not the rule).
- Create values close to their use.
- Keep checks close to the operations that depend on them.
- Minimize live variables.
- Prefer simple function signatures and return types.
- Keep functions small enough for full control-flow inspection.
- When splitting a large function, keep branching control flow in the parent.
- Move non-branching computation into focused helpers.
- Keep state mutation centralized.
- Prefer pure leaf helpers over state-mutating ones.

## Assertions

- Assert function inputs, outputs, preconditions, postconditions, and invariants.
- Assert important properties on at least two independent paths when practical.
- Assert both valid and invalid boundary cases when data crosses a correctness boundary.
- Split independent assertions (do not combine into one boolean).
- Assert compile-time constant relationships with `static_assert`.
- Prefer positive invariant forms: `index < count`.
- Use explicit nested branches when compound booleans obscure case coverage.
- Consider an explicit `else` when both sides of a condition must be handled or asserted.

## Resource Management

- RAII is the default resource model.
- Never call `.free()` on a local binding that RAII owns.
- Use `defer` only for resources RAII does not manage.
- Keep one canonical owner for each mutable piece of state.
- Avoid aliases or duplicate state that can become inconsistent.

## Unsafe Discipline

- Mark the exact boundary where guarantees stop.
- Prefer safe abstractions: `.at()` over pointer indexing, references over raw pointers.
- An `unsafe` block on a multi-statement sequence is acceptable when every statement in it
  touches the same raw resource.

## Imports

- Import what you use. `super-c lint` flags unused imports.
- Glob imports (`as *`) are fine for prelude-style modules.
- Qualified access (`mod::name`) is preferred for clarity when names overlap.

## Arithmetic

- Treat indices, counts, and sizes as distinct concepts.
- Use names with units when they prevent ambiguity.
- Convert between index/count/size deliberately.
- Use explicit division with stated rounding rule (exact, floor, ceiling).

## Platform Code

- Use `@platform(windows|macos|linux)` on items.
- Never use `#ifdef` in Super-C source.
- Keep platform decisions visible in the AST.
