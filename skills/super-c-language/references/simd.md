# Vectors and Masks

`std/simd.spc` declares the portable vector type `Simd<T, N>` and the lane mask `Mask<N>`. They
are compiler types: the declarations give them names, documentation and methods, and the
compiler checks, lays out and spells them. Both are in the prelude.

## Types

| Type | Rule |
|------|------|
| `Simd<T, N>` | `T: SimdElement` (`i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `f32`, `f64`); `N` a power of two from 2 to 64; `sizeof(T) * N <= 64` bytes (512 bits) |
| `Mask<N>` | `N` a power of two from 2 to 64; lane `i` is bit `i` |

The rules apply when the type is concrete: in a signature, or per instance of a generic item
that names `Simd<T, N>` over its own parameters. An invalid type reports in user code, not again
in the std instances it reaches. `N` must be a constant: a run-time value is "const generic
argument must be a constant integer". Only `std` implements `SimdElement` (declared in
`std/interfaces.spc`, its conformances in `std/core.spc`, so every module sees them).

Diagnostics:

```text
error: `Simd<f64, 16>` is 1024 bits wide; the limit is 512 bits
  = note: use `Simd<f64, 8>`
error: `Simd<f32, 3>` needs a power-of-two lane count (2, 4, 8, 16, 32, or 64)
error: `usize` cannot be a SIMD lane type; use `u32` or `u64`
error: `bool` cannot be a SIMD lane type; use `Mask<N>`
```

Aliases name the same types: `f32x4 f32x8 f32x16 f64x2 f64x4 f64x8 i8x16 i8x32 i8x64 u8x16
u8x32 u8x64 i16x8 i16x16 i16x32 u16x8 u16x16 u16x32 i32x4 i32x8 i32x16 u32x4 u32x8 u32x16
i64x2 i64x4 i64x8 u64x2 u64x4 u64x8`, and `mask2` to `mask64`.

## Layout

| Type | Size | Alignment | C storage |
|------|------|-----------|-----------|
| `Simd<T, N>` | `sizeof(T) * N` | `max(alignof(T), min(size, 16))` | `struct __sc_v<N>_<lane> { _Alignas(A) T l[N]; }` |
| `Mask<N>` | `max(1, N / 8)` | its size | `uint8_t` to `uint64_t` |

A vector or mask is `Copy`, `Send` and `Sync`. Neither has a C ABI: an `extern "C"` or
`@c.export` signature that names one is an error; pass `[T; N]` (`from_array`/`to_array`) or
`u64` (`from_bits`/`to_bits`).

## Vector operations

```text
let v: f32x4 = [1.0, 2.0, 3.0, 4.0];   // an array literal or [x; N] with an expected vector type
Simd::<T, N>::splat(value) Simd<T, N>   // or `f32x4::splat`; `T` and `N` also infer
Simd::from_array(a: [T; N]) Simd<T, N>
v.to_array() [T; N]
v[i]                                  // a place: read, write, borrow
v.get(i) T        v.set(i, value)
v.extract::<I>() T                    // I < N checked per instance by static_assert
v.replace::<I>(value) Simd<T, N>
Simd::<T, N>::LANES                   // N
```

A literal's length must equal `N` ("array literal has 3 elements but the vector has 4 lanes").
A constant index past the lanes is a compile error ("index 4 is out of bounds for a vector of 4
lanes"); any other index is checked at run time and traps with "index out of bounds: the index is
I but the length is N", in a constant and at run time alike. A vector has no fields, no `==` or
ordering ("does not implement `Eq`; compare lanes") and no arithmetic.

## Mask operations

```text
Mask::<N>::splat(b)   Mask::<N>::from_array(a: [bool; N])   m.to_array() [bool; N]
m.get(i) bool         m.set(i, b)                           // panic past the lanes
m & n   m | n   m ^ n   !m   ~m   m == n   m != n
m.any() m.all() m.none() m.count() usize
m.first_set() Option<usize>   m.last_set() Option<usize>
m.to_bits() u64
Mask::<N>::from_bits_truncate(b: u64)          // drops bits >= N
Mask::<N>::from_bits(b: u64) Option<Mask<N>>   // None when a bit >= N is set
```

The bits from `N` up are always zero; `!m` and `~m` (both `BitNot`) keep them zero. `get` and
`set` past the lanes panic with "Mask::get: index out of bounds" (`set` alike). `m[i]` is no
place ("use `get` or `set`"), and a mask is no condition ("use `.any()` or `.all()`").

## Reasons

- Power-of-two lane counts: every hardware vector width and every split of a wide vector is a
  power of two, and any other count needs masked tail lanes in every operation. Rust accepts any
  `N` from 1 to 64; this is a deliberate difference.
- The 16-byte alignment cap keeps aggregate layout equal on every target and feature set: a
  32-byte `vector_size` type aligns to 32 in GCC and Clang, so register types never appear in
  storage.
- A mask keeps lane `i` in bit `i` of the smallest unsigned integer that holds `N` bits, so `any`,
  `all`, `count`, `first_set` and `to_bits` are single integer operations. The storage is not
  part of the contract; `to_bits` is.
- No `Eq` for vectors: float lanes are not reflexive, and a lane comparison gives a mask, not a
  `bool`.
- No C ABI: native vector calling conventions differ by platform, compiler, feature set and
  width.

## Casts and evaluation

`as` between `[T; N]` and `Simd<T, N>`, and between `Mask<N>` and `u64`, is legal
only in `std`. The compile-time evaluator holds a vector as its array of lanes and a mask as an
integer; a vector constant is static data. `type_info` reports `TypeTag::Simd` (element and
length as for an array) and `TypeTag::Mask` (element `Bool`, length `N`).
