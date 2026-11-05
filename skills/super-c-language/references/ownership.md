# Ownership, References and Unsafe

## Ownership and RAII

The destructor interface is `Free` with method `.free()`. Ownership is **derived**: a
struct whose members own memory auto-synthesizes `free`. Owning values move, not copy. A
conditional `extend<T: Free> X<T> as Free` covers only the instances whose `Free`-bounded
arguments own memory (`X<String>`); any other instance (`X<i32>`) still derives its `free` from
its owning members, and an explicit `.free()` on it runs that derived destructor.

```superc
let a = String::from_str("owned");
let b = a;            // ownership moves to b
// a.len()            // error: use of moved value
```

**Never call `.free()` on a local binding.** RAII auto-drops at scope exit. Use `defer`
only for resources RAII does not manage (file descriptors, C allocations). Use `forget(x)`
for deliberate leaks. At a scope exit the defers run (LIFO) before the scope's locals drop,
also locals declared after the `defer` (a `let _ = f()` result is one): a deferred signal
(`defer wg.done()`) fires before them, so put locals that must drop first in an inner block.

A `Box` is never null, as in Rust. `zeroed` cannot build a value that holds one by value ("'zeroed'
cannot build a value that holds a Box"; in generic code the instance panics), and a struct literal
cannot omit a field that holds one. An explicit `.free()` (the `Free` destructor) of a value that
may hold a Box, which includes any type parameter, is an error through a reference outside a
`free` method ("cannot free a value that holds a Box through a reference: its owner frees it
again"). Free an owned value (`fn release<T>(x: T) {}` frees `x` on return), assign a new value
(`*r = fresh;` frees the old one), or free through a raw pointer in `unsafe` code. Build a value part by part in an
`Uninit<T>` (raw stores into `u.value`, then `unsafe u.value`), as the derived `Clone` and
`Default` do.

Assignment frees the old value first: `s.name = fresh;` never leaks. A store through a raw
pointer (`unsafe *p = v`, also into an element `p[i]`) frees nothing: it may write into fresh,
uninitialized storage. To replace an initialized value there, store through a reference
(`*unsafe &mut *p = v`).

A by-value pattern cannot move an owning part out of a value whose type has a user `free`
(`switch v { W { s } => .. }` for `extend W as Free`): "cannot move a part out of a value whose
type implements Free: its 'free' would not run; bind by reference or move the whole value". A
`free` that can accept a task cancellation runs with cancellation masked, so it completes.

`Copy` (a marker interface) names the values a use copies instead of moving. It is derived from
the type's shape: scalars, `str`, raw pointers, `&T`, `&dyn I`, `fn` pointers and closures that own
nothing, arrays of Copy, and aggregates that are not `Free` whose members are all Copy. `&mut T`,
`Box<dyn I>` and every owning value are not Copy. A written `extend X as Copy {}` is accepted only
where the derivation holds (`extend String as Copy {}` is rejected). A type parameter is Copy
when its bounds reach `Copy`. A method's `where T: Copy` on its extend's `T` holds in that
method only, closures included.

## References and Borrowing

`&T` (shared) and `&mut T` (exclusive) are borrow-checked statically. Non-lexical
lifetimes: a borrow ends at its last use. Field-precise overlap: `p.a` and `p.b` do not
conflict, and a method call may pass `&mut self.field` next to its `&mut self` receiver
(`self.mg.ctype(m, t, decl, &mut self.out)`); the callee must then not reach that field
through the receiver. Borrowing one value twice in one call (`s.push_str(s.as_str())`)
is rejected.

```superc
fn longer<'a>(a: &'a String, b: &'a String) &'a String {
    if a.len() > b.len() { return a; }
    return b;
}
```

Lifetime annotations are Rust-style and almost always elided. Lifetime parameters come first
in a generic list (`<'a, T>`; `<T, 'a>` is "lifetime parameters must come before type
parameters"). A result whose lifetime
the signature ties to an input (a named lifetime, or elision to `self` or to the single
borrowing input) keeps that input borrowed while the result is live, through a `&mut`
parameter and for receivers whose type holds borrows too: `let r = a.get(0); a.put(5);
use(r)` is rejected. An accessor that returns data reached through a raw-pointer field is
not tied to `self`; it names an unbounded lifetime:

```superc
fn p<'a>(self: &Self) &'a Package { return unsafe &*self.pkg; }
```

The `str` sub-view methods (`slice`, `trim`, `split`, `lines`, ...) return `str<'a>` of
the viewed text, not of the `&str` receiver.

A returned slice (`[]T`, `str`, any lifetime-generic aggregate) elides like `&T`: with no
`self` receiver and not exactly one input lifetime position, the result must name its
lifetime (`fn pick<'a>(a: []'a u8, b: []u8) []'a u8`, `fn names() []'static str<'static>`).
Positions inside tuples and type arguments count (`Option<(i32, &i32)>`); `Self` names its
extend's lifetimes and is never elided, in the method's own body and at every call: in
`extend<'a> W<'a>`, `fn new(r: &'a i32) Self` keeps `r`'s referent borrowed by the result,
and `fn put(self: &mut Self, x: &'a i32)` stores `x` into the receiver. An elided input
lifetime is its own region: returning `b: &u8` as `&'a u8`, or as a `self` method's elided
result, is rejected.

A parameter's regions flow through the body like Rust's region constraints, flow-insensitively:
a local of a struct or tuple type keeps one region set per member, so `let t = (a, b); return
t.0;` returns `a`'s region, and a struct built or copied member by member is checked member by
member against a struct result or a struct stored through a parameter (`P { x: b, y: a }` as
`P<'a, 'b>` is rejected). A member written twice holds both values' regions, as a Rust local's
type does. A `&'static` parameter keeps its argument borrowed for the whole program, an
implicit autoref for a `self: &'static Self` receiver included: `s.k()` on a local is rejected,
on a constant it is accepted.

A field names a lifetime its type declares (or `'static`) at every lifetime position: `&'a T`,
`[]'a T`, `str<'a>`, `Slice<'a, T>`, inside tuples and type arguments too.

`&mut x` needs `x` initialized and not moved: it is a use of `x` ("use of possibly uninitialized
value", "use of moved value"). There are no out-parameters through `&mut`: initialize first.

A `dyn` value holds borrows its type does not show. `&'a dyn I` (and `&'a mut dyn I`) is a
reference for every lifetime rule: elision, `'static`, named ties, variance (covariant in `'a`,
invariant in the interface's arguments), and a field of that type names its lifetime. An owned
`dyn I` (`Box<dyn I>`) in a signature holds only `'static` borrows, Rust's default object
lifetime: a returned or stored `Box<dyn fn()>` cannot capture a borrow of a local.

A store through any reference to a container records the stored borrow in the container: a
`&mut` held in a local, a reborrow of it (`let r2 = &mut *r;`), or a copy of either. After
`let r = &mut v; put(r, &a);`, `a` stays borrowed while `v` is live. A borrow of a local
stored into storage a `&mut` parameter reaches is rejected: it outlives the call. A call that
stores one parameter into another's data follows the callee's signature: the stored parameter's
lifetime must be declared to outlive the storage's (`fn fill<'x>(w: &mut Vector<&'x i32>, a: &'x i32)
{ put(w, a); }`; with `a: &i32` it is rejected).

## Unsafe

`unsafe` is **required** for:
- Raw-pointer dereference, indexing, arithmetic
- An unchecked index of a fixed array `[T; N]`: outside `unsafe` a run-time index is checked and
  panics when out of bounds ("index out of bounds", as `[]T` indexing), and under `unsafe` it is
  unchecked, as a raw pointer's. A constant index is checked at compile time at every nesting
  level; against a symbolic length every instance checks it: `a[2]` for `a: [i32; N]` is "index 2
  is out of bounds for an array of length 2 for N = 2" where `N = 2` is instantiated. Slicing an
  array (`a[lo..hi]`) checks its bounds at run time ("range out of bounds") and needs no `unsafe`.
  A field of a concrete instance has the instance's length (`Buf<i32, 4>.d` is `[i32; 4]`)
- Every call to an `extern "C"` function
- A read, write or borrow of a `static mut` (data races below)
- A `Slice`/`SliceMut` literal (`unsafe SliceMut::<T> { ptr: p, len: n }`, Rust's
  `from_raw_parts`), and a write or `&mut` of a view's `ptr` or `len` field ("writing a field of a
  slice view")
- Naming an `unsafe fn`, or an `extern "C"` function without `@unsafe(safe)`, as a value
  outside a call: a `fn` pointer is called without `unsafe`
- Casting `&T` to `*mut T` (except through `UnsafeCell::get`)
- Reading a variadic argument with `va_arg`

A `&mut` reference is exclusive also for unsafe code: reaching its referent through any
other path while it is live is undefined behavior (its C parameter is `restrict`, see
`types.md`). A `[]mut T` view is exclusive the same way (Rust's `&mut [T]`). A `&T`, a `[]T` and a
`str` are read-only the same way: while one is live, changing its referent's or elements' bytes
outside an `UnsafeCell` is undefined behavior, also through `&T as *const T as *mut T` (the
optimizer keeps their loads across every write). Lazy state a `&self` method fills goes in a cell
(`std::mem::cell::Cell`, `UnsafeCell`). A `&mut` or a
`[]mut T` copied into a local of its own kind moves (`let t = s;`); passed to a call it is
reborrowed for the call, and for as long as the result lives when the signature ties them
(`let d = r.index_mut(0); let n = r.len(); *d = 1` is "cannot use this value while it is
mutably borrowed"); stored into a field, a struct, tuple or variant literal, or a closure, it
is reborrowed for as long as that holder lives, so the source is unusable until then
(`let w = S { a: r }; h(r, w.a)` is "cannot use this value while it is mutably borrowed"). Two
arguments of one call cannot reach the same storage when one of them hands it over mutably (a `&mut`, a `[]mut T`, or a `&mut` autoref): `h(r, r)`, `h2(r, r)` with
`h2(a: &mut i32, b: &i32)`, `f(s, s)` for one `[]mut` view and `(*r).m(r)` are "cannot borrow this
value as mutable while it is already borrowed as ..." errors. A reference erased to a raw pointer
in the same call (`h4(r, r as *mut i32)`) is not checked. A reference going into a raw-pointer slot
(an argument, a struct field, an array or tuple element) becomes the pointer there: the borrow is
checked where it is made (it reads the place, so the place must be initialized) and ends at once, so
`f(&mut a[0], &mut a[1])` with `*mut` parameters is accepted.

A data race is undefined behavior (the C and Rust rule): two accesses to one non-atomic object from
two threads, at least one of them a write, with no happens-before order between them. An atomic
store with release order read by an atomic load with acquire order, a `Mutex` or `RwLock` release
and the next acquisition, a thread's or task's start and join, and a channel's send and the receive
of that value give that order. A relaxed atomic access is never a data race but orders no other
access. The rule covers a `static mut`, a `@thread_local` one whose address reached another thread,
and any memory a raw pointer reaches. So the optimizer may keep a `static mut` in a register through
code with no synchronizing operation, no coroutine suspension point and no call that may access it:
a loop loads it once and stores it once on each exit (a panic exit too), and no other thread sees
the values in between.

A reference casts only to a pointer to its own referent type (`&x as *const T` for `x: T`).
Viewing the memory as another type is a second cast, from that pointer:
`(&mut x as *mut i32) as *mut usize`, `(&a as *const [u8; 4]) as *const u8`, or the element's own
address `&a[0] as *const u8`. A single cast that changes the type is "a reference to 'i32' casts only
to a pointer to 'i32': cast to '*mut i32' first, then to '*mut usize'": a reinterpretation, and the
undefined behavior a wrong one causes, is always written out.

There is no auto-dereference through a raw pointer (the Rust rule): for `p: *mut T`,
`p.f` and `p.m()` are errors; write `unsafe (*p).f` and `unsafe (*p).m()`. A method whose
`self` is the raw pointer type itself applies to `p` directly. The explicit form keeps the
receiver a place: `(unsafe (*p)).m()` calls a `&mut self` method on the pointee, never on a
copy. Auto-deref through references, `Box` and `Deref` is unchanged.

Prefix form (`unsafe expr`) or block form (`unsafe { .. }`); the prefix covers the whole
postfix chain after it, so `unsafe (*p).a.b()` needs one `unsafe`, and its operand takes the
expected type of the whole (`let t: (i32, i32) = unsafe (a[i], a[j]);`). Use `.at()` for safe
bounds-checked container access.
