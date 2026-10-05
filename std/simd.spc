// Portable fixed-width vectors and lane masks. `Simd<T, N>` and `Mask<N>` are compiler types: the two
// declarations below give them their names, documentation and methods, and the compiler checks, lays
// out and spells them (the language skill's references/simd.md). Every operation here is written over
// lane indexing and the two casts that only `std` may write: `[T; N]` to `Simd<T, N>` and back, and
// `Mask<N>` to `u64` and back. A mask's bits above lane `N - 1` are always zero. The lane types'
// interface, `SimdElement`, is in interfaces.spc and its conformances in core.spc, where every module
// sees them.

/// `N` lanes of `T`: `N` is a power of two from 2 to 64, and the vector is at most 512 bits wide. A
/// vector is `Copy`. It aligns to `max(alignof(T), min(sizeof(T) * N, 16))` and has no C ABI: an
/// `extern "C"` or `@c.export` signature passes `[T; N]` instead.
pub struct Simd<T: SimdElement, const N: usize> {
    lanes: [T; N],
}

/// `N` boolean lanes, `N` a power of two from 2 to 64: lane `i` is bit `i` of `to_bits`. A mask is
/// `Copy`; `==` compares the lanes, and `&`, `|`, `^` and `!` work lane by lane.
pub struct Mask<const N: usize> {
    bits: u64,
}

pub type f32x4 = Simd<f32, 4>;
pub type f32x8 = Simd<f32, 8>;
pub type f32x16 = Simd<f32, 16>;
pub type f64x2 = Simd<f64, 2>;
pub type f64x4 = Simd<f64, 4>;
pub type f64x8 = Simd<f64, 8>;
pub type i8x16 = Simd<i8, 16>;
pub type i8x32 = Simd<i8, 32>;
pub type i8x64 = Simd<i8, 64>;
pub type u8x16 = Simd<u8, 16>;
pub type u8x32 = Simd<u8, 32>;
pub type u8x64 = Simd<u8, 64>;
pub type i16x8 = Simd<i16, 8>;
pub type i16x16 = Simd<i16, 16>;
pub type i16x32 = Simd<i16, 32>;
pub type u16x8 = Simd<u16, 8>;
pub type u16x16 = Simd<u16, 16>;
pub type u16x32 = Simd<u16, 32>;
pub type i32x4 = Simd<i32, 4>;
pub type i32x8 = Simd<i32, 8>;
pub type i32x16 = Simd<i32, 16>;
pub type u32x4 = Simd<u32, 4>;
pub type u32x8 = Simd<u32, 8>;
pub type u32x16 = Simd<u32, 16>;
pub type i64x2 = Simd<i64, 2>;
pub type i64x4 = Simd<i64, 4>;
pub type i64x8 = Simd<i64, 8>;
pub type u64x2 = Simd<u64, 2>;
pub type u64x4 = Simd<u64, 4>;
pub type u64x8 = Simd<u64, 8>;
pub type mask2 = Mask<2>;
pub type mask4 = Mask<4>;
pub type mask8 = Mask<8>;
pub type mask16 = Mask<16>;
pub type mask32 = Mask<32>;
pub type mask64 = Mask<64>;

// The bits of every lane of an `n`-lane mask.
const fn lane_bits(n: usize) u64 {
    return ~0u64 >> (64 - n) as u64;
}

extend<T: SimdElement, const N: usize> Simd<T, N> {
    /// The lane count.
    pub const LANES: usize = N;

    /// `value` in every lane.
    pub fn splat(value: T) Self {
        return [value; N];
    }

    /// The vector of the lanes `a`.
    pub fn from_array(a: [T; N]) Self {
        return a as Self;
    }

    /// The lanes as an array.
    pub fn to_array(self: Self) [T; N] {
        return self as [T; N];
    }

    /// Lane `i`. Panics: `i >= N`.
    pub fn get(self: &Self, i: usize) T {
        return self[i];
    }

    /// Set lane `i` to `value`. Panics: `i >= N`.
    pub fn set(self: &mut Self, i: usize, value: T) {
        self[i] = value;
    }

    /// Lane `I`; `I < N` is checked at compile time.
    pub fn extract<const I: usize>(self: &Self) T {
        static_assert(I < N, "extract: the lane index I must be below the lane count N");
        return self[I];
    }

    /// The vector with lane `I` set to `value`; `I < N` is checked at compile time.
    pub fn replace<const I: usize>(self: Self, value: T) Self {
        static_assert(I < N, "replace: the lane index I must be below the lane count N");
        let mut v = self;
        v[I] = value;
        return v;
    }
}

extend<const N: usize> Mask<N> {
    /// `b` in every lane.
    pub fn splat(b: bool) Self {
        if b {
            return lane_bits(N) as Self;
        }
        return 0u64 as Self;
    }

    /// The mask of the lanes `a`.
    pub fn from_array(a: [bool; N]) Self {
        let mut bits: u64 = 0;
        let mut i: u64 = 0;
        for x in a {
            if x {
                bits |= 1u64 << i;
            }
            i += 1;
        }
        return bits as Self;
    }

    /// The lanes as an array.
    pub fn to_array(self: Self) [bool; N] {
        let mut a = [false; N];
        let bits = self as u64;
        for i in 0..N {
            unsafe a[i] = (bits >> i as u64 & 1) != 0;
        }
        return a;
    }

    /// Lane `i`. Panics: `i >= N`.
    pub fn get(self: &Self, i: usize) bool {
        if i >= N {
            panic("Mask::get: index out of bounds");
        }
        return ((*self) as u64 >> i as u64 & 1) != 0;
    }

    /// Set lane `i` to `b`. Panics: `i >= N`.
    pub fn set(self: &mut Self, i: usize, b: bool) {
        if i >= N {
            panic("Mask::set: index out of bounds");
        }
        let bit = 1u64 << i as u64;
        let bits = (*self) as u64;
        let nb = if b {
            bits | bit;
        } else {
            bits & ~bit;
        };
        *self = nb as Self;
    }

    /// Whether a lane is set.
    pub fn any(self: Self) bool {
        return self as u64 != 0;
    }

    /// Whether every lane is set.
    pub fn all(self: Self) bool {
        return self as u64 == lane_bits(N);
    }

    /// Whether no lane is set.
    pub fn none(self: Self) bool {
        return self as u64 == 0;
    }

    /// The number of set lanes.
    pub fn count(self: Self) usize {
        return (self as u64).count_ones();
    }

    /// The lowest set lane, or None when no lane is set.
    pub fn first_set(self: Self) Option<usize> {
        let bits = self as u64;
        if bits == 0 {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(bits.trailing_zeros());
    }

    /// The highest set lane, or None when no lane is set.
    pub fn last_set(self: Self) Option<usize> {
        let bits = self as u64;
        if bits == 0 {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(63 - bits.leading_zeros());
    }

    /// The lanes as bits: lane `i` is bit `i`, and the bits from `N` up are zero.
    pub fn to_bits(self: Self) u64 {
        return self as u64;
    }

    /// The mask whose lane `i` is bit `i` of `b`; the bits from `N` up are dropped.
    pub fn from_bits_truncate(b: u64) Self {
        return (b & lane_bits(N)) as Self;
    }

    /// The mask whose lane `i` is bit `i` of `b`, or None when a bit from `N` up is set.
    pub fn from_bits(b: u64) Option<Mask<N>> {
        if (b & ~lane_bits(N)) != 0 {
            return Option::<Mask<N>>::None;
        }
        return Option::<Mask<N>>::Some(b as Self);
    }
}

extend<const N: usize> Mask<N> as Eq {
    pub fn eq(self: &Self, other: &Self) bool {
        return (*self) as u64 == (*other) as u64;
    }
}

extend<const N: usize> Mask<N> as BitAnd {
    type Output = Mask<N>;
    pub fn bit_and(self: &Self, other: &Self) Mask<N> {
        return ((*self) as u64 & (*other) as u64) as Self;
    }
}

extend<const N: usize> Mask<N> as BitOr {
    type Output = Mask<N>;
    pub fn bit_or(self: &Self, other: &Self) Mask<N> {
        return ((*self) as u64 | (*other) as u64) as Self;
    }
}

extend<const N: usize> Mask<N> as BitXor {
    type Output = Mask<N>;
    pub fn bit_xor(self: &Self, other: &Self) Mask<N> {
        return ((*self) as u64 ^ (*other) as u64) as Self;
    }
}

extend<const N: usize> Mask<N> as BitNot {
    type Output = Mask<N>;
    pub fn bit_not(self: &Self) Mask<N> {
        return (~((*self) as u64) & lane_bits(N)) as Self;
    }
}
