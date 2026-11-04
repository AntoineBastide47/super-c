# Porting-Bug Patterns

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
