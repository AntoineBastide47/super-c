// Standard interfaces (the layer that references NO other prelude type, so the value types -- String,
// Vector, Option, ... -- can import it and conform without forming a header include cycle). The
// type-coupled interfaces (Format, Writer, Iterator, TryFrom, TryInto -- which mention String / Option /
// Result / slices) live in the sibling `traits` prelude module. Part of the auto-imported prelude, so all
// these names resolve unqualified everywhere.

// A type that owns resources and must run cleanup when it goes out of scope. `free` is run automatically
// at scope exit (move/defer RAII, spec 7.7) for a value that was not moved out; it may also be called
// explicitly, which consumes the value (a later use is a use-after-free).
pub interface Free {
    fn free(self: &mut Self);
}

// Arithmetic operator overloading: `a + b` dispatches to `a.add(&b)`, and likewise `-`/`*`/`/`/`%` to
// sub/mul/div/rem. The result is whatever the method returns (typically Self). A type need not name these
// interfaces -- a bare method of the right name is enough -- but conforming documents the intent.
pub interface Add { fn add(self: &Self, other: &Self) Self; }
pub interface Sub { fn sub(self: &Self, other: &Self) Self; }
pub interface Mul { fn mul(self: &Self, other: &Self) Self; }
pub interface Div { fn div(self: &Self, other: &Self) Self; }
pub interface Rem { fn rem(self: &Self, other: &Self) Self; }

// Index operator overloading: `obj[i]` dispatches to `obj.index(i)`, yielding a `T`.
pub interface Index<T> { fn index(self: &Self, i: usize) T; }

// A canonical "zero" / empty value, constructible without arguments.
pub interface Default {
    fn default() Self;
}

// An explicit deep copy. (Plain assignment is a shallow, bitwise copy; `clone` is for types that own a
// heap allocation and need a fresh one.)
pub interface Clone {
    fn clone(self: &Self) Self;
}

// A marker interface: the value is safe to duplicate with a plain bitwise copy (no owned heap, so no
// aliasing hazard). The move checker treats a `Copy` binding as still usable after it is passed or
// assigned. It carries no methods -- implementing it is purely a promise about the type's representation.
pub interface Copy {}

// Infallible value conversion. `From` is the one a type implements; `Into` is its compiler-provided mirror
// (`x.into()` -> `Target::from(x)`), so implementing `From` gives `.into()` for free. (The fallible pair
// `TryFrom`/`TryInto` lives in `traits` -- it mentions `Result`.)
pub interface From<T> {
    fn from(value: T) Self;
}
pub interface Into<T> {
    fn into(self: Self) T;
}

// Equality. `eq` must be reflexive, symmetric and transitive.
pub interface Eq {
    fn eq(self: &Self, other: &Self) bool;
}

// Total ordering. `cmp` returns a negative value when `self < other`, zero when equal, positive when
// `self > other`. Requires `Eq` for consistency between `==` and ordering.
pub interface Ord: Eq {
    fn cmp(self: &Self, other: &Self) i32;
}

// A stable hash of the value, for hash maps and sets. Equal values (per `Eq`) must hash equally.
pub interface Hash {
    fn hash(self: &Self) u64;
}

extern "C" {
    fn malloc(size: usize) *mut void;
    fn realloc(ptr: *mut void, size: usize) *mut void;
    fn free(ptr: *mut void) void;
    fn abort() void;
}

// The memory source a heap container allocates through. Carried as a type parameter (`Box<T, A = Global>`,
// `Vector<T, A = Global>`, ...) so allocator identity is part of the type -- a Global-allocated value cannot
// be released through a different allocator. The allocator is a VALUE stored inside the container (by `&mut
// self` so a stateful arena/pool can mutate its bump cursor); a zero-sized allocator (`Global`) costs no
// space, so `Box<T>` is still just `{ ptr }`. Every operation is layout-aware -- it is told the block's
// `size` and `align` (and `realloc` the `old_size`) -- which a bump/arena allocator needs and which a
// `malloc`-backed one may ignore. `alloc`/`realloc` return a usable, suitably-aligned block (never null --
// they handle OOM themselves). Allocators own nothing themselves (the memory they hand out is owned by the
// container), so they are not `Free` and are freely copied when a container is cloned.
pub interface Allocator {
    fn alloc(self: &mut Self, size: usize, align: usize) *mut void;
    fn realloc(self: &mut Self, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void;
    fn dealloc(self: &mut Self, ptr: *mut void, size: usize, align: usize) void;
}

// The default allocator: the C heap (`malloc`/`realloc`/`free`), aborting on out-of-memory. A zero-sized
// tag -- it stores nothing, so `Box<T>` is just `{ ptr }` with no space overhead. `malloc` already returns
// memory aligned for any fundamental type, so `Global` ignores `align` (and the bookkeeping `size`s).
pub struct Global {}

extend Global as Allocator {
    pub fn alloc(self: &mut Global, size: usize, align: usize) *mut void {
        let p = malloc(size);
        if p == null { abort(); }
        return p;
    }
    pub fn realloc(self: &mut Global, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        let p = realloc(ptr, new_size);
        if p == null { abort(); }
        return p;
    }
    pub fn dealloc(self: &mut Global, ptr: *mut void, size: usize, align: usize) void {
        free(ptr);
    }
}

// `Global` is constructible from nothing, so containers' no-argument constructors (`Vector::new()`, ...)
// can synthesize one. A stored `Global` is zero bytes.
extend Global as Default {
    pub fn default() Global { return Global {}; }
}

