---
name: super-c-documentation
description: "Defines the rules for writing comments and documentation in Super-C code: the delete-test, the three documentation tiers, valid and invalid comment reasons, formatting rules, and banned filler. Use when writing, reviewing, or cleaning up comments and doc comments in .spc files."
allowed-tools: Bash Read
---

# Super-C Comments and Documentation

## Agent checklist

- Apply the delete-test to every changed comment.
- Put caller contracts on public items and invariants in internal notes.
- Remove history, filler, and comments that restate visible code.
- Run the canonical formatter for changed `.spc` files.

The default is **silence**. Add a comment only when it communicates information the code
or signature cannot. Every comment must pass the delete-test.

## The Delete-Test

Delete the comment. Read the code without it. If the reader lost nothing, the comment was
filler and stays deleted. Silence is the default.

## Three Documentation Tiers

### Tier 1 — Module Header

A `//` comment block before imports. States the module's contract in the pipeline:
what it consumes, what it produces, and 1–2 invariants callers rely on.

2–6 lines. Present tense. Information-first (the first three words carry the payload).

```superc
// Byte-driven scanner: a NUL-padded source String in (see SOURCE_PAD), a Vector<Token>
// out. Tokens carry only (kind, start, len) spans indexing the source -- no text is
// copied. Every error is recovered from, so the scan always completes; keep_trivia
// additionally emits comment tokens for the formatter path (the parser never sees trivia).
import string as cstring;
```

### Tier 2 — API Documentation (`///`)

On `pub` items only. First sentence = the contract ("what you get and what it costs").
Never start with "This function...", "This struct...", or "This method...".

Use terse capitalized lead-ins instead of markdown sections:

```superc
/// Resolve a call expression's argument list against the callee's parameter types.
/// Panics: callee has no parameter list (assert).
/// Ownership: each argument is consumed; the caller must not reuse the AST nodes.
pub fn resolve_call_args(self: &mut Resolver, call: NodeId) { .. }
```

Audience: the **caller**. Describe external behavior, not internal implementation.

### Tier 3 — Internal Notes (`//`)

For maintainers. Cover invariants, constraints, and non-obvious reasons.

```superc
// The lexer relies on trailing NUL to terminate scan loops — every module source is
// padded by String::pad_nul so per-byte bounds checks are eliminated.
pub const SOURCE_PAD: usize = 8;
```

## Valid Comment Reasons

A comment earns its place when it documents one of these:

| Reason | Example |
|--------|---------|
| **Ownership transfer** | "Consumes the token vector; caller must not reuse." |
| **Safety precondition** | "Caller must hold the lock. Raw pointer must be non-null and aligned." |
| **Sentinel convention** | "Returns UINT32_MAX on miss." |
| **Panic / abort behavior** | "Panics if the index is out of bounds." |
| **Cross-pass protocol** | "The resolver fills this field; the typechecker reads it." |
| **Deliberate performance shape** | "Bucketed by length then first byte — a miss costs 1–2 comparisons." |
| **Invariant** | "The token vector is never empty after a successful scan." |
| **Why-not** | "Linear scan, not hash: N < 8 in all measured cases." |
| **Bootstrap / fixpoint constraint** | "This ordering preserves the gen-1 == gen-2 invariant." |
| **Recovery semantics** | "On error, the partial result is valid up to the last complete item." |

## What Must Never Appear in a Comment

| Category | Example of What to Delete |
|----------|--------------------------|
| **Restating name / signature** | "Parses a token" on `fn parse_token()` |
| **Narrating control flow** | "Loop through each element and check..." |
| **History / process notes** | "Added in Phase 3", "Fixed in PR #42", "New approach" |
| **Hedging filler** | "simply", "just", "basically", "helper for", "used to" |
| **Echoing diagnostic strings** | Repeating the error message next to the `panic()` call |
| **Commented-out code** | Dead code belongs in git history, not in the file |
| **Unowned TODOs** | A TODO without a decision or owner is noise |
| **Plan / phase references** | "Phase 2 will handle this" |
| **Obvious mechanism** | "Increment the counter" next to `count += 1` |

## Body Comments

Body comments have the **highest bar** — the mechanism is visible in the code, so only
intent hides. Before writing a body comment, consider whether a rename or a named
predicate would make the comment unnecessary.

Five things that earn a body comment:

1. **Load-bearing invariant** — a property the code relies on that is not obvious from
   the surrounding lines.
2. **State-variable contract at declaration** — what the variable means, not what type it
   is.
3. **Phase landmark in a long function** — a topic sentence marking a logical boundary
   (not a blow-by-blow narration).
4. **Why-not** — a rejected obvious alternative, in one line.
5. **Recovery semantics on an error path** — what state is valid after the error.

Density: 0–3 body comments per function is healthy. More signals the function should be
split or the code should be clearer.

## Formatting Rules

### Full-line comments

Sentences. Space after `//`. Initial capital. Terminal punctuation.

```superc
// The token vector is sorted by source position after the scan completes.
```

### Trailing end-of-line comments

Short phrases. No terminal punctuation. Use only on declarations (fields, constants).

```superc
pub const SOURCE_PAD: usize = 8;  // trailing NUL lookahead for the scan loops
let mut mul: u64 = 1;             // scale factor
```

### Doc comments (`///`)

On `pub` items only. Present tense. Information-first. Complete but compressed. One line
preferred; multi-line when the contract has multiple dimensions (panics, ownership,
safety).

```superc
/// Intern a string and return its stable ID. Idempotent: the same string always
/// returns the same ID.
pub fn intern(self: &mut Interner, s: str) InternId { .. }
```

Do not use `///` on private items. Use `//` for internal notes.

## Style Rules

- **Present tense.** "Returns the length" not "Will return the length."
- **Information-first.** The first three words carry the payload. "Panics if null" not
  "In the case where the pointer is null, this function will panic."
- **Complete but compressed.** One line is better than a paragraph.
- **Caller's view for `///`.** Describe what the caller sees, not how the function works
  internally.
- **Maintainer's view for `//`.** Describe what the maintainer needs to know — invariants,
  constraints, non-obvious reasons.

## Reviewing Comments

When reviewing code, apply the delete-test to every comment. If a comment survives the
delete-test, check:

1. Is the information accurate? (Stale comments are worse than no comments.)
2. Is the information in the right tier? (A caller-facing fact belongs in `///`, not `//`.)
3. Does it use banned filler? (Delete the filler, see if the rest survives.)
4. Could a rename eliminate it? (If yes, rename instead.)
