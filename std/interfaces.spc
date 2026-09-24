// Every standard interface: RAII (`Free`), the thread markers, the operator overloads, conversion, and the
// type-coupled ones further down (Format, Writer, Iterator, TryFrom/TryInto, Index/IndexMut) whose method
// shapes mention String / Option / Result / Range / slices. Part of the auto-imported prelude, so all these
// names resolve unqualified everywhere.
//
// An interface has no C representation, so this module emits no struct body and no call that needs
// another module's DEFINITIONS: only its names, which arrive as forward declarations. The emitted
// header includes `super_rt.h` and nothing else, whatever a signature here mentions.

/// A type that owns resources and must run cleanup when it goes out of scope. `free` is run automatically
/// at scope exit (move/defer RAII, spec 7.7) for a value that was not moved out; it may also be called
/// explicitly, which consumes the value (a later use is a use-after-free).
pub interface Free {
    fn free(self: &mut Self);
}

/// Marker: a `Send` type may have its OWNERSHIP moved to another thread. Conformance is STRUCTURAL and
/// automatic: a type is `Send` when every part of it is (scalars and `str` are; a raw pointer is not, so
/// nothing transitively holding one is either). Write an explicit `extend T as Send {}` only to override
/// that for a type whose raw pointer is in fact safe to transfer (e.g. `Arc`): an unchecked assertion.
pub interface Send {}

/// Marker: a `Sync` type may be SHARED between threads by reference (`&T` crosses thread boundaries).
/// Structural and automatic on the same rules as `Send`; override with an explicit `extend T as Sync {}`.
pub interface Sync {}

/// Marker: a `Copy` value is duplicated by a plain bitwise copy, so a use of it never moves it. Conformance
/// is STRUCTURAL and automatic: scalars, `str`, raw pointers, shared references, `fn` pointers, and arrays,
/// slices, tuples and non-`Free` aggregates whose members are all `Copy`. An owning value (`Free`, an
/// owning closure, `Box<dyn I>`) and a `&mut T` are never `Copy`. Inside a generic body a type parameter
/// is `Copy` only when its bounds say so (`T: Copy`, or a bound whose superinterfaces include `Copy`);
/// otherwise its values move and drop like any owning value. An explicit `extend T as Copy {}` is accepted
/// only where the structural rule already holds.
pub interface Copy {}

/// Arithmetic operator overloading: `a + b` dispatches to `a.add(&b)`, and likewise `-`/`*`/`/`/`%` to
/// sub/mul/div/rem. A type need not name these interfaces: a bare method of the right name is enough;
/// but conforming documents the intent and is what a generic bound can require.
///
/// Neither side is pinned to Self. `Rhs` defaults to Self, which is the common case, so `as Add` means
/// `as Add<Self>`. `Output` is ASSOCIATED rather than a second parameter, because a type has one result
/// for a given right operand: that is what makes `a * b` unambiguous. So a matrix multiplies a vector
/// into a vector, and says so: `extend Mat as Mul<Vec3> { type Output = Vec3; .. }`.
pub interface Add<Rhs = Self> {
    type Output;
    fn add(self: &Self, other: &Rhs) Self::Output;
}
/// `a - b`.
pub interface Sub<Rhs = Self> {
    type Output;
    fn sub(self: &Self, other: &Rhs) Self::Output;
}
/// `a * b`.
pub interface Mul<Rhs = Self> {
    type Output;
    fn mul(self: &Self, other: &Rhs) Self::Output;
}
/// `a / b`.
pub interface Div<Rhs = Self> {
    type Output;
    fn div(self: &Self, other: &Rhs) Self::Output;
}
/// `a % b`.
pub interface Rem<Rhs = Self> {
    type Output;
    fn rem(self: &Self, other: &Rhs) Self::Output;
}

/// Bitwise operator overloading, on the same rule as the arithmetic ones: `a & b` dispatches to
/// `a.bit_and(&b)`, `|`/`^` to bit_or/bit_xor, and unary `~a` to `a.bit_not()`.
pub interface BitAnd<Rhs = Self> {
    type Output;
    fn bit_and(self: &Self, other: &Rhs) Self::Output;
}
/// `a | b`.
pub interface BitOr<Rhs = Self> {
    type Output;
    fn bit_or(self: &Self, other: &Rhs) Self::Output;
}
/// `a ^ b`.
pub interface BitXor<Rhs = Self> {
    type Output;
    fn bit_xor(self: &Self, other: &Rhs) Self::Output;
}
/// `~a`.
pub interface BitNot {
    type Output;
    fn bit_not(self: &Self) Self::Output;
}

/// Shifts: `a << n` dispatches to `a.shl(n)` and `a >> n` to `a.shr(n)`. `Rhs` defaults to a COUNT rather
/// than to Self: shifting by a value of the shifted type is meaningless once the type is wider than a
/// machine word, and the built-in integers take a count too. It is still a parameter, so a type that
/// wants to be shifted by something else may say so.
pub interface Shl<Rhs = usize> {
    type Output;
    fn shl(self: &Self, amount: Rhs) Self::Output;
}
/// `a >> amount`.
pub interface Shr<Rhs = usize> {
    type Output;
    fn shr(self: &Self, amount: Rhs) Self::Output;
}

/// A canonical "zero" / empty value, constructible without arguments. `default` DEFAULTS to a value
/// with every field defaulted through its own `Default`, so a bare `extend T as Default {}` derives
/// it for a struct or tuple (an enum or union must implement it by hand); implement to override.
pub interface Default {
    fn default() Self {
        return reflect_default::<Self>();
    }
}

/// An explicit deep copy. (Plain assignment is a shallow, bitwise copy; `clone` is for types that own a
/// heap allocation and need a fresh one.) `clone` DEFAULTS to a field-by-field deep copy through each
/// field's own `Clone`, so a bare `extend T as Clone {}` derives it for a struct or tuple (an enum or
/// union must implement it by hand); implement to override.
pub interface Clone {
    fn clone(self: &Self) Self {
        return reflect_clone(self);
    }
}

/// Smart-pointer dereference: a wrapper that transparently exposes its pointee. A method not found on the
/// wrapper itself is looked up through `deref` (up to 8 hops, cycle-checked; the wrapper's own methods
/// always win); calling a `&mut self` method through the chain instead goes through `deref_mut` at every
/// hop, which also requires the original binding to be `mut`. Field access never derefs: go through the
/// wrapper's accessors explicitly.
pub interface Deref<Target> {
    fn deref(self: &Self) &Target;
}
/// Mutable auto-deref: `*x` and `x.field` on a `&mut` smart pointer.
pub interface DerefMut<Target> {
    fn deref_mut(self: &mut Self) &mut Target;
}

/// Infallible value conversion. `From` is the one a type implements; `Into` is its compiler-provided mirror
/// (`x.into()` -> `Target::from(x)`), so implementing `From` gives `.into()` for free. (The fallible pair is
/// `TryFrom`/`TryInto`, further down.)
pub interface From<T> {
    fn from(value: T) Self;
}
/// Infallible conversion by value; blanket-provided from `From`.
pub interface Into<T> {
    fn into(self: Self) T;
}

/// Equality. `eq` must be reflexive, symmetric and transitive. It DEFAULTS to field-wise (or
/// active-variant) reflected equality, so a bare `extend T as Eq {}` derives it; implement to
/// override.
pub interface Eq {
    fn eq(self: &Self, other: &Self) bool {
        return reflect_any_eq(self, other);
    }

    fn ne(self: &Self, other: &Self) bool {
        return !self.eq(other);
    }
}

/// Total ordering. `cmp` returns a negative value when `self < other`, zero when equal, positive when
/// `self > other`. Requires `Eq` for consistency between `==` and ordering. It DEFAULTS to
/// lexicographic field order (or discriminant-then-payload order for an enum), so a bare
/// `extend T as Ord {}` derives it; implement to override.
pub interface Ord: Eq {
    fn cmp(self: &Self, other: &Self) i32 {
        return reflect_any_cmp(self, other);
    }
}

/// A stable hash of the value, for hash maps and sets. Equal values (per `Eq`) must hash equally.
/// `hash` DEFAULTS to the reflected FNV-1a over the fields' (or the active variant's) own hashes,
/// so a bare `extend T as Hash {}` derives it (see `@derive`); implement `hash` to override.
pub interface Hash {
    fn hash(self: &Self) u64 {
        return reflect_any_hash(self);
    }
}

extern "C" {
    fn malloc(size: usize) *mut void;
    fn realloc(ptr: *mut void, size: usize) *mut void;
    fn free(ptr: *mut void) void;
    fn abort() void;
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
}

/// The memory source a heap container allocates through. Carried as a type parameter (`Box<T, A = Global>`,
/// `Vector<T, A = Global>`, ...) so allocator identity is part of the type: a Global-allocated value cannot
/// be released through a different allocator. The allocator is a VALUE stored inside the container (by `&mut
/// self` so a stateful arena/pool can mutate its bump cursor); a zero-sized allocator (`Global`) costs no
/// space, so `Box<T>` is still `{ ptr }`. Every operation is layout-aware: it is told the block's
/// `size` and `align` (and `realloc` the `old_size`), which a bump/arena allocator needs and which a
/// `malloc`-backed one may ignore. `alloc`/`realloc` return a usable, suitably-aligned block (never null:
/// they handle OOM themselves). Allocators own nothing themselves (the memory they hand out is owned by the
/// container), so an allocator is `Copy`: a container's clone or `map` copies its handle.
/// Every method is `unsafe`, and the bookkeeping arguments are why. `dealloc` and `realloc` are TOLD the
/// block's `size` and `align`, and an allocator that trusts them (a bump or arena one must) corrupts its
/// own free list when they are wrong. Nothing checks that the numbers describe the block `ptr` came from, or
/// that `ptr` came from this allocator at all, so the caller says so.
pub interface Allocator: Copy {
    unsafe fn alloc(self: &mut Self, size: usize, align: usize) *mut void;
    unsafe fn realloc(self: &mut Self, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void;
    unsafe fn dealloc(self: &mut Self, ptr: *mut void, size: usize, align: usize) void;
}

// Over-aligned blocks: the platform call is chosen in the header, where the C compiler knows the target.
extern "C" "alloc.h" {
    fn sc_alloc_aligned(size: usize, align: usize) *mut void;
    fn sc_free_aligned(ptr: *mut void) void;
}

// The alignment every `malloc` result has on the supported targets: 16 bytes on 64-bit ones. On wasm32 it
// is 8, below wasi-libc's 16, so a 16-aligned type there takes the over-aligned path, which is also correct.
const MALLOC_ALIGN: usize = 2 * sizeof(usize);

/// The default allocator: the C heap, aborting on out-of-memory. A zero-sized tag: it stores nothing, so
/// `Box<T>` is `{ ptr }` with no space overhead. An `align` up to what `malloc` guarantees takes
/// `malloc`/`realloc`/`free`; a larger one takes the platform's aligned allocation (`posix_memalign`, or
/// `_aligned_malloc` on Windows), and the same `align` must be passed back to `realloc` and `dealloc`.
/// The bookkeeping `size`s matter only for moving an over-aligned block.
pub struct Global {}

// Restates the derived conformance: the bootstrap compiler predates the derivation and checks
// `Allocator`'s superinterface against written conformances only.
extend Global as Copy {}

extend Global as Allocator {
    pub unsafe const fn alloc(self: &mut Global, size: usize, align: usize) *mut void {
        let p = if align > MALLOC_ALIGN {
            unsafe sc_alloc_aligned(size, align);
        } else {
            unsafe malloc(size);
        };
        if p == null {
            unsafe abort();
        }
        return p;
    }
    pub unsafe const fn realloc(self: &mut Global, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        if align > MALLOC_ALIGN {
            // `realloc` keeps only malloc's alignment, so the block moves to a fresh aligned one.
            let p = unsafe self.alloc(new_size, align);
            if ptr != null {
                let n = if old_size < new_size {
                    old_size;
                } else {
                    new_size;
                };
                unsafe memcpy(p, ptr, n);
                unsafe sc_free_aligned(ptr);
            }
            return p;
        }
        let p = unsafe realloc(ptr, new_size);
        if p == null {
            unsafe abort();
        }
        return p;
    }
    pub unsafe const fn dealloc(self: &mut Global, ptr: *mut void, size: usize, align: usize) {
        if align > MALLOC_ALIGN {
            unsafe sc_free_aligned(ptr);
            return;
        }
        unsafe free(ptr);
    }
}

// `Global` is constructible from nothing, so containers' no-argument constructors (`Vector::new()`, ...)
// can synthesize one. A stored `Global` is zero bytes.
extend Global as Default {
    pub const fn default() Global {
        return Global {};
    }
}

/// A human-readable rendering of the value. `fmt` DEFAULTS to the reflected form: `"Name { a: 1 }"`
/// for a struct/union whose fields are all `Format`, `"Case(payload, ..)"` for an enum, so a bare
/// `extend T as Format {}` derives it (see `@derive`); implement `fmt` to override.
pub interface Format {
    fn fmt(self: &Self) String {
        return reflect_any_string(self);
    }
}

/// A sink of bytes (files, buffers, sockets). `write` returns the number of bytes accepted.
pub interface Writer {
    fn write(self: &mut Self, bytes: []u8) usize;
}

/// A source of values produced one at a time; `next` yields `None` when exhausted.
pub interface Iterator<T> {
    fn next(self: &mut Self) Option<T>;
}

/// Fallible value conversion. `TryFrom` is the one a type implements; `TryInto` is its compiler-provided
/// mirror (`x.try_into()` -> `U::try_from(x)`), so implementing `TryFrom` gives `.try_into()` for free.
pub interface TryFrom<T> {
    fn try_from(value: T) Result<Self, i32>;
}
/// Fallible conversion by value; blanket-provided from `TryFrom`.
pub interface TryInto<T> {
    fn try_into(self: Self) Result<T, i32>;
}

/// Index operator overloading. `T` is the element yielded by `obj[i]`; `S` is the sub-view yielded by
/// `obj[lo..hi]` (`[]T` for containers, `str` for string types). `obj[i]` dispatches to `index`, and a
/// reference-returning `index` makes `obj[i]` the element PLACE itself (the compiler inserts the deref),
/// so containers hand out borrowed elements, never copies. `obj[lo..hi]`: any range form: `lo..hi`,
/// `lo..=hi`, `lo..`, `..hi`, `..=hi`: dispatches to `index_range` with the written bounds packed into
/// a `Range<usize>` exactly as spelled (an inclusive `..=` arrives with `r.inclusive` set); a missing
/// start is 0, and a missing end is the value's `len()`, so open-ended forms additionally require a
/// `len` method on the type.
pub interface Index<T, S> {
    fn index(self: &Self, i: usize) &T;
    fn index_range(self: &Self, r: Range<usize>) S;
}

/// The writable counterpart. `obj[i] = v` stores through the `&mut T` that `index_mut` returns (a
/// compound `obj[i] += v` reads and writes through it; a plain `=` over a `Free` element frees the
/// replaced value first, like a binding reassignment). `S` is the writable sub-view (`[]mut T`);
/// `index_range_mut` is called explicitly: `obj[lo..hi]` always takes the read-only `index_range`.
pub interface IndexMut<T, S> {
    fn index_mut(self: &mut Self, i: usize) &mut T;
    fn index_range_mut(self: &mut Self, r: Range<usize>) S;
}

/// A value with every field defaulted through its own `Default`, built over a `zeroed` seed like
/// `reflect_clone`. Enums and unions refuse for the same reasons. Lives HERE rather than in
/// `reflect`: `Default`'s default body must name it in `::<Self>` position, which resolves only
/// same-module (the prelude still exposes it unqualified everywhere).
pub fn reflect_default<T>() T {
    if type_info::<T>().kind == TypeTag::Enum || type_info::<T>().kind == TypeTag::Union {
        panic("a derived 'default' covers structs and tuples; write it by hand for an enum or union");
    }
    let mut out = unsafe zeroed::<T>();
    inline for f in fields(&mut out) {
        reflect_default_field(&mut f.value);
    }
    return out;
}

fn reflect_default_field<V: Default>(dst: &mut V) {
    *dst = V::default();
}
