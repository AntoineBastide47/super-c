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

In a build that plans backend entries, a vector of 2 to 16 bytes whose alignment is its size holds
`T l __attribute__((vector_size(S)))` instead, with the same size and alignment: the C ABI passes it
in one vector register, not lane by lane; a wider one of 16-byte chunks also names them in a union
with `l`.

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
I but the length is N", in a constant and at run time alike. A vector has no fields and no `==` or
ordering ("does not implement `Eq`; compare lanes"): `equal` and the other comparisons give a mask.

## Lane operations

Every lane operation applies the scalar rule of its lane type (operations.md) to each lane, as a
constant and at run time alike. Without a usable backend entry (Target features below) the
emitted C is a lane loop with a constant trip count over the storage arrays (one loop for a load or
lane operation and the loop that alone reads it), or `memmove` for a bitcast and a raw pointer;
it never depends on the C compiler vectorizing it, and a build without entries uses no target
intrinsic and no C vector extension.

The lane interfaces bound the operations: `SimdInt` (`i8` to `u64`), `SimdSigned` (`i8` to `i64`,
`f32`, `f64`) and `SimdFloat` (`f32`, `f64`). Only `std` implements them; a call on other lanes is
"cannot call ..: unsatisfied interface bounds".

| Operators | Lanes | Rule |
|-----------|-------|------|
| `+ - *` | all | integers: checked trap (overflow traps where the build checks overflow, else wraps); floats: IEEE |
| `/` | all | integers: traps on a zero divisor and on signed `MIN / -1` |
| `%` | integers | traps as `/` |
| unary `-` | `SimdSigned` | integers: checked trap at `MIN` |
| `& \| ^ ~` | integers | bitwise |
| `<< >>` | integers | the count is the same vector type, or a scalar of the lane type for every lane; traps when a count is below 0 or at least the width; `>>` is arithmetic on signed lanes |

The right operand of a binary operator is the left's vector type, or a scalar of its lane type that
stands for that scalar in every lane (`v * 3.0`, `v * a`, `v ^ (3 | 4)`: an unsuffixed literal or
literal-only arithmetic takes the lane type), and the compound forms (`+=`, `<<= 2`) follow the same
rules. A right operand of another type is "mismatched types" with the note "the right operand is
the vector type or its lane type". A scalar left operand does not convert: `1.0 + v` is "operator
requires numeric operands" with the note "a scalar does not convert to a vector: use
`Simd::splat`". The operators are the conformances `Add`, `Sub`, `Mul`, `Div`, `Rem`, `BitAnd`,
`BitOr`, `BitXor`, `BitNot`, `Shl` and `Shr`, each also as `<T>` for a lane scalar, so a generic
bound reaches them.

```text
// SimdInt lanes
v.wrapping_add(w) v.wrapping_sub(w) v.wrapping_mul(w) v.wrapping_neg()
v.wrapping_shl(n) v.wrapping_shr(n)     // n: Self, the count modulo the width
v.checked_add(w) (Simd<T, N>, Mask<N>)  // the wrapped value, the lanes that overflowed (sub, mul too)
v.saturating_add(w) v.saturating_sub(w) // clamped to [MIN, MAX]
v.min(w) v.max(w)
v.leading_zeros() v.trailing_zeros() v.count_ones()   // per lane, as T; a zero lane gives the width
v.rotate_left(n) v.rotate_right(n)      // n: Self, modulo the width
v.reverse_bits() v.swap_bytes()
v.abs_diff(w) Simd<T::Unsigned, N>      // |v - w| exact, in the unsigned lane type of the width
// SimdSigned lanes
v.abs()                                 // an integer MIN lane traps (as -MIN); a float lane drops its sign bit
// signed integer lanes
v.wrapping_abs()                        // MIN stays MIN
// SimdFloat lanes
v.copysign(sign) v.sqrt() v.ceil() v.floor() v.trunc() v.round_even()
v.fma(b, c)                             // v * b + c, one rounding
v.min_num(w) v.max_num(w) v.minimum(w) v.maximum(w)
v.is_nan() v.is_infinite() v.is_finite() v.is_normal() v.is_subnormal() v.is_sign_negative()  // Mask<N>
v.to_bits() Simd<T::Bits, N>            Simd::<T, N>::from_bits(b)   // T::Bits: u32 for f32, u64 for f64
// every lane type
v.equal(w) v.not_equal(w) v.less_than(w) v.less_equal(w) v.greater_than(w) v.greater_equal(w)  // Mask<N>
v.clamp(lo, hi)                         // max(lo, min(v, hi)), min_num/max_num on floats
m.choose(when_true, when_false)         simd::choose(m, when_true, when_false)
simd::iota::<T, N>()                    // lanes 0, 1, .., N - 1
```

| Operation | A NaN operand | Zeros of both signs |
|-----------|---------------|---------------------|
| `min_num(a, b)` | the other operand; `a` with its quiet bit set when both are NaN | `-0.0` |
| `max_num(a, b)` | the other operand; `a` with its quiet bit set when both are NaN | `+0.0` |
| `minimum(a, b)` | NaN | `-0.0` |
| `maximum(a, b)` | NaN | `+0.0` |

The four are IEEE 754-2019 minimumNumber, maximumNumber, minimum and maximum; the C spells them as
compare sequences, never `fmin`/`fmax`, whose zero rule C leaves open. A comparison with a NaN lane
is false, except `not_equal`. A signaling NaN is treated as quiet. The NaN payload of an arithmetic
result is not specified; `-`, `abs`, `copysign`, `to_bits`, `from_bits`, `bitcast`, `choose`, the
halves, `concat`, and the loads and stores keep every bit, at compile time too. `round_even` rounds
to nearest, ties to even (`nearbyint`: no program changes the rounding mode). `clamp` panics with
"Simd::clamp: a lane has lo > hi or a NaN bound" when `lo <= hi` is false in a lane.

```text
v.cast::<U>()               // each lane by `as` (operations.md)
v.cast_checked::<U>()       // (Simd<U, N>, Mask<N>): the lanes whose value changed or held a NaN
v.widen::<U>()              // U wider, the same kind (signed, unsigned or float): exact
v.narrow::<U>()             // U a narrower integer: a lane U cannot hold traps
v.narrow_saturating::<U>()  // clamped to U's range
v.narrow_wrapping::<U>()    // the low bits
v.bitcast::<U, M>()         // sizeof(T) * N == sizeof(U) * M: the only conversion that reinterprets bits
v.low_half() v.high_half()  // Simd<T, N / 2>, N >= 4
simd::concat(a, b)          // Simd<T, 2 * N>, which must be a valid vector
```

`widen`, `narrow*`, `bitcast` and the halves check their types per instance with a `static_assert`
that names the operation ("widen: U must be a wider lane type of the same kind as T"). `iota`
needs no check: every lane count fits every lane type.

```text
simd::load::<T, N>(s: []T, start: usize) Simd<T, N>
simd::store(s: []mut T, start: usize, v: Simd<T, N>)
unsafe simd::load_unaligned::<T, N>(p: *const T)       unsafe simd::store_unaligned(p: *mut T, v)
unsafe simd::load_aligned::<T, N, A>(p: *const T)      unsafe simd::store_aligned::<T, N, A>(p: *mut T, v)
```

A slice access checks its lanes once, overflow-free: it traps unless `start <= len` and
`N <= len - start`, with "index out of bounds: N lanes from START but the length is LEN". In a loop
over `len - len % N` that steps by `N`, bounds-check elimination proves the check and removes it
when `N` is a constant (not in a body generic over `N`); `len` may be the slice's length or the
value a `Slice { ptr, len }` literal stored.
The raw forms need `unsafe`; the caller guarantees `N` valid elements and, for the aligned forms, an
`A`-byte alignment (`A` a power of two of at least `alignof(T)`). A load borrows its slice shared and
a store mutably, as a call taking the view does: a store while a reference into the slice or its
array is live is a borrow error. A `[]mut T` is a `[]T` for a load (`simd::load(y, i)` then
`simd::store(y, i, ..)` updates in place).

A trapping lane operation traps once, at its lowest failing lane, with `lane <i>: <the scalar
message>` ("lane 2: attempt to add with overflow", "lane 0: attempt to narrow a lane that does not
fit"), as a constant and at run time.

The named operations are signatures with `@intrinsic("simd.<name>")` and no body, in `std` only
(else "'@intrinsic' is reserved for the standard library"; an unknown name is "unknown intrinsic").
A call lowers to the operation itself; a bound call or a function value runs a body the compiler
builds from the same operation.

Every named operation above has a free form: `simd::f(a, ..)` is `a.f(..)` (`simd::min(a, b)`,
`simd::checked_add(a, b)`, `simd::to_bits(v)`, `simd::from_bits::<f32, 4>(b)`). The conversions are
methods only; `choose`, `iota`, `concat` and the loads and stores are free functions. A free form
is visible unqualified too (std's `simd` is a prelude module); a module's own function of the same
name hides it. `SimdInt::Unsigned` and `SimdFloat::Bits` are the lane interfaces' associated types.

The std compositions (`widen`, `narrow*`, `bitcast`, the halves, `clamp`, `checked_*`,
`cast_checked`, `splat`) inline at their calls: no call remains in a loop, in every profile.

## Rearrangement

```text
simd::swizzle(v, idx: [usize; M]) Simd<T, M>            // lane i: v[idx[i]]
simd::shuffle(a, b, idx: [usize; M]) Simd<T, M>         // lane i: idx[i] < N ? a[idx[i]] : b[idx[i] - N]
simd::swizzle_or_zero(v, idx: Simd<U, M>) Simd<T, M>    // U unsigned; lane i: idx[i] < N ? v[idx[i]] : 0
simd::swizzle_checked(v, idx) (Simd<T, M>, Mask<M>)     // and the lanes whose index is N or more
simd::reverse(v)                                        // lane i: v[N - 1 - i]
simd::rotate_lanes_left::<K>(v)                         // lane i: v[(i + K) % N]
simd::rotate_lanes_right::<K>(v)                        // lane i: v[(i + N - K % N) % N]
simd::interleave_low(a, b)      simd::interleave_high(a, b)    // a[N/2*h + i/2] for an even i, else b[..]
simd::deinterleave_even(a, b)   simd::deinterleave_odd(a, b)   // lane i: (a ++ b)[2i] or [2i + 1]
simd::zip(a, b)    // (interleave_low, interleave_high)
simd::unzip(a, b)  // (deinterleave_even, deinterleave_odd)
simd::compress(m, v, fill)    // active lanes of v at 0..count-1 in lane order, fill[i] from count
simd::expand(m, packed, fill) // active lane i: packed[k], k the active lanes below i; inactive: fill[i]
```

An index list is a constant `[usize; M]` expression; `M` is the result's lane count, and
`Simd<T, M>` must be a valid vector. The checker evaluates it at the call: "the index list of
`swizzle` must be a compile-time constant", and an index past the operands' lanes names its value
and position ("names lane 4 at position 1, past the 4 lanes of its operands"). A list or lane count
over the enclosing generic's parameters is checked per instance, where the error names the
bindings as a failed per-instance `static_assert` does. `swizzle` and `shuffle` have no function
value. The other rearrangements are std functions over `swizzle` and `shuffle` with lists from a
`const fn`: their body re-lowers per instance, and the inliner re-lowers it under each call's
bindings, so they inline at their calls like the other compositions.

## Reductions

| Operation | Lanes | Rule |
|-----------|-------|------|
| `reduce_add`, `reduce_mul` | integer | modulo 2^W: the result does not depend on the order |
| `reduce_add_checked`, `reduce_mul_checked` | integer | `Option<T>`: None when the exact sum or product does not fit `T` |
| `reduce_add_ordered` | float | `((-0.0 + v[0]) + v[1]) + ... + v[N - 1]` |
| `reduce_mul_ordered` | float | `((1.0 * v[0]) * v[1]) * ... * v[N - 1]` |
| `reduce_add_tree`, `reduce_mul_tree` | float | `r[i] = v[i] op v[i + N/2]` over the lower half, repeated until one lane |
| `reduce_min`, `reduce_max` | integer | the extreme lane |
| `reduce_min_num`, `reduce_max_num`, `reduce_minimum`, `reduce_maximum` | float | the lane operation of the name: `_num` ignores NaN lanes, `minimum`/`maximum` return NaN for one |
| `reduce_and`, `reduce_or`, `reduce_xor` | integer | bitwise |
| `arg_min`, `arg_max` | integer | `usize`: the lowest lane of the extreme value |
| `arg_min_num`, `arg_max_num` | float | `Option<usize>`: the lowest lane of the extreme non-NaN value (`-0.0` below `+0.0`); None when every lane is NaN |
| `simd::dot::<A>(a, b)` | any | integer `A`: the sum of `(a[i] as A) * (b[i] as A)` modulo 2^W; float `A`: `reduce_add_ordered` of the products, each rounded to `A` |

The float sum starts at `-0.0`, so lanes of `-0.0` sum to `-0.0`. A float reduction names its order
and no lowering reorders it; none is named `sum`. `A` has the kind of `T` (integer or float) and at
least its width ("dot: A must be a type of the same kind as T, at least as wide").

## Masked and partial memory

```text
simd::load_or(s: []T, start, fallback) Simd<T, N>
simd::load_masked(s: []T, start, m: Mask<N>, fallback) Simd<T, N>
simd::store_masked(s: []mut T, start, m, v)
simd::gather(s: []T, idx: Simd<I, N>, m, fallback) Simd<T, N>     // I is u32 or u64
simd::scatter(s: []mut T, idx: Simd<I, N>, m, v)
simd::compress_store(s: []mut T, start, m, v) usize
unsafe simd::gather_unchecked(s: []T, idx: Simd<I, N>, m, fallback) Simd<T, N>
unsafe simd::gather_ptr(p: [*const T; N], m, fallback)    unsafe simd::scatter_ptr(p: [*mut T; N], m, v)
unsafe simd::load_masked_ptr(p: *const T, m, fallback)    unsafe simd::store_masked_ptr(p: *mut T, m, v)
```

| Operation | Active lane `i` | Inactive lane `i` | Trap |
|-----------|-----------------|-------------------|------|
| `load_or` | `s[start + i]` where it exists | `fallback[i]` | never |
| `load_masked` | `s[start + i]` | `fallback[i]`, no access | an active lane past `s` |
| `store_masked` | writes `s[start + i]` | no access | an active lane past `s`, before any write |
| `gather` | `s[idx[i]]` | `fallback[i]`, no access | an active index past `s` |
| `scatter` | writes `s[idx[i]]` in lane order | no access | an active index past `s`, before any write |
| `compress_store` | writes the active lanes at `start..start + count`, returns `count` | no access | `start + count` past `s`, before any write |

An inactive lane never reads, writes or checks its element; every active lane is checked before the
first access, and the lowest failing one traps: "lane 3: index out of bounds: the index is 9 + 3
but the length is 12" (from a start), "lane 1: index out of bounds: the index is 6 but the length
is 6" (an index), and for `compress_store` the slice access text ("3 lanes from 10 but the length is
12"). `start + i` never overflows: the check is `start <= len` and then `i < len - start`. Of
active scatter lanes with one index, the highest writes last and wins (Rust's `scatter` and AVX-512
order). `compress_store` changes exactly `count` elements; it may rewrite at most 8 elements after
them with their own values, since the slice is borrowed alone. No masked store reads and writes
back the whole vector: another thread may own an inactive element. A store borrows its slice
mutably, a load shared; the raw forms and `gather_unchecked` are `unsafe` and check nothing: the
caller guarantees each active lane's element (every active index below `s.len()`), for input it
trusts or after its own check.

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
- One lane rule per operation, chosen by the lane type, like the scalar operators: `abs` and
  `min`/`max` have one Core IR code each, so a generic body lowers once for every lane type.
- Lane interfaces instead of per-instance checks for the lane kind: a misuse is a type error at the
  call, in generic code too.

## Casts and evaluation

`as` between `[T; N]` and `Simd<T, N>`, and between `Mask<N>` and `u64`, is legal only in
`std`. The compile-time evaluator holds a vector as its array of lanes and a mask as an
integer; a vector constant is static data. `type_info` reports `TypeTag::Simd` (element and
length as for an array) and `TypeTag::Mask` (element `Bool`, length `N`).

## Target features and backends

A CPU feature (`--target-feature`, build.toml `target-features`, see super-c-binary) only
selects instructions: every vector operation gives the same lanes and the same traps with and
without it. Three attributes, each with constant-expression arguments checked by type, connect
the features to code:

| Attribute | Where | Meaning |
|-----------|-------|---------|
| `@target_feature([cpu::Feature::X, ..])` | a function whose `@arch` gate (or its extend's) holds every feature's instruction set (checked at the parse for a list of `cpu::Feature` variants, so on every target alike); not a method of a conformance, which a bound or `dyn` calls unnamed | the function needs the features: a call or a function value of it is an error unless the build, or the calling function with what its features imply, holds them ("`f` needs `+relaxed-simd` (`--target-feature=+relaxed-simd`)"); `main`, `@c.export`, `@test` and `@bench` functions need them in the build ("..; it is called from outside the program"); a function the build cannot call emits nothing; the compile-time evaluator has no value for it ("`f` has no compile-time value") |
| `@simd_impl(simd::Op::X, [cpu::Feature::Y, ..])` | a function of `std` (else "'@simd_impl' is reserved for the standard library") | a backend entry: an implementation of operation `X` for the lane type and count of its signature, under the features. Never `RelaxedSimd` |
| `@c.value(size, align)` | an opaque type (`type T;`) of an `extern "C"` block | a C register type (`v128_t`) with that layout, which a `_Static_assert` beside the header include checks: `Copy`, `sizeof`/`alignof` read it; a local, a parameter or a result only, never a field, variant payload, element, static, pointer or reference target, capture or generic argument, written or inferred (`[x, x]`, `(x, 1)`, `&x`, `\|\| x`, `id(x)`): "`v128_t` is a register type; store it through `Simd<T, N>`" |

A misspelled variant is an error at the argument ("no variant, method, or constant 'Neonn'"),
a value of another enum a type error. `std::cpu::Feature` follows the compiler's feature table
and `std::simd::Op` its operation table, name and discriminant (`tests/target_feature_test.spc`
asserts both at compile time).

### Backend files

`std/simd/backend/<x86|aarch64|wasm>.spc`, the file of the build's instruction set, loads with
the prelude when it exists, the build has a feature, and a module of the program names a vector
(`Simd<`, `Mask<`, `simd::`, a lane or mask alias; std's `simd.spc` aside) (today: `wasm.spc`, header
`<wasm_simd128.h>`, bindings in `ffi/wasm_simd128.spc`; `aarch64.spc`, header `<arm_neon.h>`,
bindings in `ffi/arm_neon.spc`, which every aarch64 build may load since `neon` is its baseline);
an entry's definition header is written only when a unit calls it, and the file emits no unit
of its own, so a program without vectors emits the same C with and without the features. Each entry is a plain
function with `@arch` and `@simd_impl`; the file's helpers `reg` and `vec` move a vector into a
register and back (`wasm_v128_load`, `wasm_v128_store`), and the compiler splices them into
every entry:

```superc
@arch(wasm32)
@simd_impl(simd::Op::Add, [cpu::Feature::Simd128])
fn add_f32x4(a: f32x4, b: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_add(reg(a), reg(b)));
}
```

The signature must have the operation's shape ("a '@simd_impl(simd::Op::Add, ..)' entry has
the signature `fn(Simd<T, N>, Simd<T, N>) Simd<T, N>`"). The lane-mask forms take and give
`Simd<U, N>`, `U` the unsigned type of the lane width, all ones for a true lane: `CmpEqLanes`
to `CmpGeLanes`, `ChooseLanes`, `LanesToMask`, `MaskToLanes`, `AnyLanes`, `AllLanes`; a
constant index list (`swizzle`, `shuffle`) has no entry: under the planner it is the C
compiler's shuffle of the lanes (`__builtin_shufflevector`), one `i8x16.shuffle` per 16 result
bytes; `LoadMasked` and
`StoreMasked` take the elements' address, the mask and the fallback or stored vector, and touch
an inactive lane's element never. A trapping operator has no entry of its own: its
`OverflowAdd`, `OverflowSub` or `OverflowMul` entry names the failing lanes (a shift by a scalar
count checks the count once), then its wrapping twin's entry computes the lanes. One entry per
operation, lane type, lane count and feature count: two are an error naming both. An entry may
call bindings, and functions of its file that inline (one that does not fails the build); it
must give the operation's exact result for
every input, NaN payloads aside (`tests/simd_entry_test.spc` compares every entry with the lane
loop on boundary inputs, in the wasm conformance lane and on an aarch64 host).

The aarch64 file, the second worked example, has one register type per lane type and width
(`int8x16_t` .. `float64x2_t`, `@c.value(16, 16)`; `int8x8_t` .. `float32x2_t`, `@c.value(8,
8)`), so its helpers are one pair per type: `q_s8` loads a 128-bit vector with `vld1q_s8`, `v_s8`
stores a register back with `vst1q_s8`, and `d_s8`/`w_s8` do the same for a 64-bit vector
(`Simd<i8, 8>`) with `vld1_s8`/`vst1_s8`. A 64-bit vector has the lane-wise entries in `d` form
and the conversions to and from 128 bits (`vmovl`, `vmovn`, `vqmovn`, `vcvt`). Its entries cover
the 128-bit lane-wise arithmetic (signed wrapping `+ - *` and negation on the
unsigned forms: GCC spells the signed ones as C arithmetic, whose overflow is undefined),
saturating, min, max, bits (`count_ones`, `leading_zeros`, `trailing_zeros`, `reverse_bits`,
`swap_bytes`, rotations), shifts (a scalar count after its check, a vector count wrapped),
float rounding, `fma`, `min_num`/`max_num` (`bsl(y == y, fminnm(fmax(x, x), y), fmax(x, x))`: `fmax`
quiets a signaling NaN, for which `fminnm` gives NaN, and the C compilers fold `x * 1.0` away; a NaN
`y` selects `x` quieted, since the C compilers may swap `fminnm`'s operands), the lane-mask
forms (`LanesToMask` sums each lane's power of two: `addv`, or three `addp` for byte lanes),
overflow masks, conversions, saturating narrowing, loads, stores, masked accesses, run-time
byte indexes (`tbl`, 16 to 64 bytes) and reductions. A float tree reduction adds the upper half
onto the lower half (`vadd_f32` of the halves): never adjacent pairs (`faddp` over four lanes,
`vaddvq_f32`), whose order differs. `dot::<i32>` of byte lanes has two entries: `sdot`/`udot`
under `[Neon, Dotprod]`, and the widened products added pairwise under `[Neon]`; the planner
takes the one with more features the build holds.

To add a backend: write the file with entries for the operations whose instructions match
the lane rule exactly, and a binding module for the header; an operation without an entry
keeps its lane loop.

### Lowering planner

`src/emit/simd_plan.spc` decides each vector statement from the backend table and the build's
features alone: `Native` (an entry for the lanes), `Split` (the widest entry for a power-of-two
fraction of the lanes, applied to each chunk in lane order; a reduction combines its chunks
with the lane-wise entry its definition names), or `Scalar` (the lane loop). Among usable
entries the one with the most features wins. A comparison read only by one `choose` keeps its
lanes in lane-mask temporaries; one read only by `any`, `none`, `all` or `!all` (through copies
and a cast to `u64`) reduces its lane masks with `AnyLanes` or `AllLanes`; otherwise it packs
its lanes into the mask with `LanesToMask`. A choice of a stored mask unpacks it with
`MaskToLanes`. A split reads every operand before it writes a chunk, so a pointer may alias a
vector operand or the result. Entries render as `static inline` C functions, always inlined. A
build under a memory checker never plans an entry that calls a `@c.lane_access` binding.

### CPU detection

`std::cpu::CpuFeatures { bits: [u64; 2] }` is a set of features (bit `i`: the variant of
discriminant `i`) with `has(f)` and `contains(other)`. `std::cpu::detect` (a separate module, so
a program that does not ask links no detector) reads the machine: `features()`, `has(f)`,
`static_features()`, the set the C compiler enables for the build (its `__ARM_FEATURE_*`
macros: the build's features and what the flag's architecture brings), which `features()`
always contains, and `detected()`, a new OS query without the build's set. Detection runs
once, before `main` (a C constructor) or at the first query, allocates nothing and takes no
lock: `sysctlbyname` of `hw.optional.arm.FEAT_*` on macOS and iOS, `getauxval(AT_HWCAP)` and
`AT_HWCAP2` on Linux and Android, `IsProcessorFeaturePresent` on Windows; a failing query means
absent. On wasm32 `features()` equals `static_features()`: an engine rejects a module whose
features it lacks. Detection selects code only: no result of the language depends on it, and
the compile-time evaluator never reads it.

### The aarch64 module

`std::simd::aarch64` holds the Arm operations with no portable meaning, over the portable
types, each needing its feature: `vdot_i32`, `vdot_u32` (`Dotprod`); `vmmla_i32`, `vmmla_u32`,
`vusmmla_i32` (`I8mm`: the 2x2 product of 2x8 byte matrices); `vqrdmlah_*`, `vqrdmlsh_*` for
`i16`, `i32` (`Rdm`); `aese`, `aesd`, `aesmc`, `aesimc` (`Aes`); `sha256h`, `sha256h2`,
`sha256su0`, `sha256su1` (`Sha2`); `eor3`, `rax1`, `xar::<N>`, `bcax` (`Sha3`); `crc32b` ..
`crc32x` and `crc32cb` .. `crc32cx` (`Crc`, from `<arm_acle.h>`); `table_lookup` over 16, 32,
48 (`[u8; 48]`) and 64 bytes (`Neon`). They have no memory effect; each calls a C intrinsic,
so the compile-time evaluator has no value for them.

### The wasm32 module

`std::simd::wasm` holds the WebAssembly operations with no portable meaning, over the portable
types: `relaxed_madd`, `relaxed_nmadd`, `relaxed_min`, `relaxed_max` (`_f32x4`, `_f64x2`),
`relaxed_swizzle`, `relaxed_trunc`, `relaxed_dot_i8x16_i7x16_add` (each needs `RelaxedSimd`:
the result can differ between engines), and `pmin`/`pmax` (`_f32x4`, `_f64x2`), `q15mulr_sat`,
`dot_i16x8` (`Simd128`). A relaxed instruction appears only there: no portable operation
uses one.
