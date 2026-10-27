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

/// Marker: all-zero bytes are a valid, empty value of the type whatever its private fields hold, so a
/// struct literal that omits a field of the type zero-fills it (each field's own type must still be
/// valid as zero). Nothing verifies the claim: it is asserted with `unsafe extend T as Zeroable {}`.
/// std's containers assert it (`str`, `String`, `Vector`, `Array`, `Map`, `Set`); `Slice` and
/// `SliceMut` need no assertion, their fields are public.
pub interface Zeroable {}

/// Marker: a `Copy` value is duplicated by a plain bitwise copy, so a use of it never moves it. Conformance
/// is STRUCTURAL and automatic: scalars, `str`, raw pointers, shared references, `fn` pointers, and arrays,
/// slices, tuples and non-`Free` aggregates whose members are all `Copy`. An owning value (`Free`, an
/// owning closure, `Box<dyn I>`), a `&mut T` and a `[]mut T` are never `Copy`. Inside a generic body a type parameter
/// is `Copy` only when its bounds say so (`T: Copy`, or a bound whose superinterfaces include `Copy`);
/// otherwise its values move and drop like any owning value. An explicit `extend T as Copy {}` is accepted
/// only where the structural rule already holds.
pub interface Copy {}

/// Marker: a function pointer type (`fn(A) R`). Conformance is STRUCTURAL: a closure or any other type
/// never is. A value of a type parameter `F: FnPtr` casts to `usize` (its address), and `unsafe` back
/// from one (`u as F`), as a `fn(A) R` value does.
pub interface FnPtr: Copy {}

/// A SIMD lane type (`Simd<T, N>`): `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `f32` or
/// `f64`. Only `std` implements it.
pub interface SimdElement: Copy {}

/// An integer lane type: `i8` to `i64` and `u8` to `u64`. Only `std` implements it.
pub interface SimdInt: SimdElement {
    /// The unsigned lane type of the same width.
    type Unsigned;
}

/// A lane type with a sign: `i8` to `i64`, `f32` and `f64`. Only `std` implements it.
pub interface SimdSigned: SimdElement {}

/// A float lane type: `f32` or `f64`. Only `std` implements it.
pub interface SimdFloat: SimdSigned {
    /// The unsigned integer lane type of the same width: the type of the bits.
    type Bits;
}

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
/// `-a` dispatches to `a.neg()`.
pub interface Neg {
    type Output;
    fn neg(self: &Self) Self::Output;
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

/// A sink that reduces a byte stream to a 64-bit digest: what a keyed hash builder feeds a key into
/// (`Hash::hash_into`). `write_u8` and `write_u64` are `write` of the value's little-endian bytes; a
/// hasher may override them with a faster path that keeps that meaning.
pub interface Hasher {
    fn write(self: &mut Self, bytes: []u8);
    fn finish(self: &Self) u64;

    fn write_u8(self: &mut Self, v: u8) {
        let b: [u8; 1] = [v];
        self.write(b);
    }

    fn write_u64(self: &mut Self, v: u64) {
        let b: [u8; 8] = [
            v as u8,
            (v >> 8) as u8,
            (v >> 16) as u8,
            (v >> 24) as u8,
            (v >> 32) as u8,
            (v >> 40) as u8,
            (v >> 48) as u8,
            (v >> 56) as u8,
        ];
        self.write(b);
    }
}

/// How a hash table turns a key into the 64-bit hash it indexes by: `Map` and `Set` take one as their
/// last type parameter. `Copy`, as an allocator is: a table's clone copies it. The prelude's
/// `DefaultHash` is unkeyed and deterministic; `std::hash::keyed` has a keyed one for keys that come from
/// untrusted input.
pub interface BuildHasher: Copy {
    fn hash_one<K: Hash>(self: &Self, key: &K) u64;
}

/// A value a hash table can key by: `hash_into` feeds it into a `Hasher`, so the hasher sees the input
/// itself (a keyed hasher keeps its protection). Equal values (per `Eq`) must feed equal streams.
/// `hash_into` DEFAULTS to the fields' (or the active variant's tag and payloads') own `hash_into`, in
/// declaration order, so a bare `extend T as Hash {}` derives it (see `@derive`). The default is
/// consistent only with the default (field-wise) `Eq`: a type that writes its own `eq` must write
/// `hash_into` too, and a build that hashes such a type through the default stops with a static
/// assertion. A conformance is a deliberate choice: types with interior mutability (`Cell`, `RefCell`,
/// atomics, locks) are not `Hash`, because a key that changes in place loses its slot. `hash(&v)` is the
/// prelude's 64-bit hash of a value.
pub interface Hash {
    fn hash_into<H: Hasher>(self: &Self, h: &mut H) {
        static_assert(type_info::<Self>().method("eq").is_none(), "a type that defines its own 'eq' must define 'hash_into'");
        reflect_any_hash_into(self, h);
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

// Over-aligned blocks: the runtime's leak tracker allocates them with the target's call (`aligned_alloc`,
// or `_aligned_malloc` on Windows), records them, and releases them with the matching call.
extern "C" {
    fn sc_lk_aligned_alloc(size: usize, align: usize) *mut void;
    fn sc_lk_aligned_free(ptr: *mut void) void;
}

// The alignment every `malloc` result has on the supported targets: 16 bytes on 64-bit ones. On wasm32 it
// is 8, below wasi-libc's 16, so a 16-aligned type there takes the over-aligned path, which is also correct.
const MALLOC_ALIGN: usize = 2 * sizeof(usize);

// `@derive(Copy)` restates the derivation for the bootstrap compiler, which checks a `Copy` bound against
// written conformances only.
/// The default allocator: the C heap, aborting on out-of-memory. A zero-sized tag: it stores nothing, so
/// `Box<T>` is `{ ptr }` with no space overhead. An `align` up to what `malloc` guarantees takes
/// `malloc`/`realloc`/`free`; a larger one takes the platform's aligned allocation (`aligned_alloc`, or
/// `_aligned_malloc` on Windows), and the same `align` must be passed back to `realloc` and `dealloc`.
/// The bookkeeping `size`s matter only for moving an over-aligned block.
@derive(Copy)
pub struct Global {}

// Each method inlines into its caller, so the leak tracker records the allocation at the container code
// that asked for the block, in every profile.
extend Global as Allocator {
    @always_inline
    pub unsafe const fn alloc(self: &mut Global, size: usize, align: usize) *mut void {
        let p = if align > MALLOC_ALIGN {
            unsafe sc_lk_aligned_alloc(size, align);
        } else {
            unsafe malloc(size);
        };
        if p == null {
            unsafe abort();
        }
        return p;
    }
    @always_inline
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
                unsafe sc_lk_aligned_free(ptr);
            }
            return p;
        }
        let p = unsafe realloc(ptr, new_size);
        if p == null {
            unsafe abort();
        }
        return p;
    }
    @always_inline
    pub unsafe const fn dealloc(self: &mut Global, ptr: *mut void, size: usize, align: usize) {
        if align > MALLOC_ALIGN {
            unsafe sc_lk_aligned_free(ptr);
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

/// A sink of bytes (files, buffers, sockets). A call that accepts at least one byte returns `Ok(n)`; a fault
/// after a partial transfer appears on the next call. An interrupted call is retried, never returned.
pub interface Writer {
    fn write(self: &mut Self, bytes: []u8) Result<usize, IoError>;
}

/// A source of bytes. A call that moves at least one byte returns `Ok(n)`; a fault after a partial transfer
/// appears on the next call. `Ok(0)` means the end of the stream, or an empty `buf`.
pub interface Reader {
    fn read(self: &mut Self, buf: []mut u8) Result<usize, IoError>;
}

/// A source of values produced one at a time; `next` yields `None` when exhausted.
pub interface Iterator<T> {
    fn next(self: &mut Self) Option<T>;

    /// Bounds on the number of values left: at least the first, at most the second (`None` when
    /// unknown). Equal bounds are an exact size. A wrong hint is a defect of the iterator, never a
    /// memory error: consumers use it only to reserve.
    fn size_hint(self: &Self) (usize, Option<usize>) {
        return 0, Option::<usize>::None;
    }
}

/// An iterator that also yields from its far end. `next` and `next_back` take values from one
/// sequence and meet in the middle: after the last value either side returns `None`.
pub interface DoubleEndedIterator<T>: Iterator<T> {
    fn next_back(self: &mut Self) Option<T>;
}

/// Fallible value conversion. `TryFrom` is the one a type implements; `TryInto` is its compiler-provided
/// mirror (`x.try_into()` -> `U::try_from(x)`), so implementing `TryFrom` gives `.try_into()` for free.
pub interface TryFrom<T> {
    /// What a failed conversion returns.
    type Error;
    fn try_from(value: T) Result<Self, Self::Error>;
}
/// Fallible conversion by value; blanket-provided from `TryFrom`, with the target's `Error`.
pub interface TryInto<T> {
    type Error;
    fn try_into(self: Self) Result<T, Self::Error>;
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
/// replaced value first, like a binding reassignment). `S` is the writable sub-view (`[]mut T`):
/// `&mut obj[lo..hi]` takes `index_range_mut`'s view (a `&mut S`), every other `obj[lo..hi]` the
/// read-only `index_range`.
pub interface IndexMut<T, S> {
    fn index_mut(self: &mut Self, i: usize) &mut T;
    fn index_range_mut(self: &mut Self, r: Range<usize>) S;
}

/// A value with every field defaulted through its own `Default`, written into an empty `Uninit` like
/// `reflect_clone`. Enums and unions refuse for the same reasons. Lives HERE rather than in
/// `reflect`: `Default`'s default body must name it in `::<Self>` position, which resolves only
/// same-module (the prelude still exposes it unqualified everywhere).
pub fn reflect_default<T>() T {
    if type_info::<T>().kind == TypeTag::Enum || type_info::<T>().kind == TypeTag::Union {
        panic("a derived 'default' covers structs and tuples; write it by hand for an enum or union");
    }
    let mut out = Uninit::<T> { none: 0 };
    inline for f in fields(&mut unsafe out.value) {
        reflect_default_field(&mut f.value);
    }
    return unsafe out.value;
}

// Write the default into field `dst`, which holds no value yet: a raw store frees nothing.
fn reflect_default_field<V: Default>(dst: &mut V) {
    let p = dst as *mut V;
    unsafe *p = V::default();
}
