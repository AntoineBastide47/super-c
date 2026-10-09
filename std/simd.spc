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

    /// Lane-wise `==`; a float lane holding a NaN is unequal.
    @intrinsic("simd.eq")
    pub fn equal(self: Self, other: Self) Mask<N>;

    /// Lane-wise `!=`; a float lane holding a NaN is unequal.
    @intrinsic("simd.ne")
    pub fn not_equal(self: Self, other: Self) Mask<N>;

    /// Lane-wise `<`; false on a float lane holding a NaN.
    @intrinsic("simd.lt")
    pub fn less_than(self: Self, other: Self) Mask<N>;

    /// Lane-wise `<=`; false on a float lane holding a NaN.
    @intrinsic("simd.le")
    pub fn less_equal(self: Self, other: Self) Mask<N>;

    /// Lane-wise `>`; false on a float lane holding a NaN.
    @intrinsic("simd.gt")
    pub fn greater_than(self: Self, other: Self) Mask<N>;

    /// Lane-wise `>=`; false on a float lane holding a NaN.
    @intrinsic("simd.ge")
    pub fn greater_equal(self: Self, other: Self) Mask<N>;

    /// Each lane limited to `[lo, hi]`: `max(lo, min(self, hi))`, with `min_num` and `max_num` on float
    /// lanes. Panics: a lane where `lo <= hi` is false (a NaN bound included).
    pub fn clamp(self: Self, lo: Self, hi: Self) Self {
        if lo.less_equal(hi) as u64 != ~0u64 >> (64 - N) as u64 {
            panic("Simd::clamp: a lane has lo > hi or a NaN bound");
        }
        return lo.lane_max(self.lane_min(hi));
    }

    @intrinsic("simd.min")
    fn lane_min(self: Self, other: Self) Self;

    @intrinsic("simd.max")
    fn lane_max(self: Self, other: Self) Self;

    /// Each lane converted to `U` by `as` (operations.md): an integer wraps, a float truncates toward
    /// zero and saturates (NaN is 0) into an integer, a conversion to a float rounds to nearest.
    @intrinsic("simd.cast")
    pub fn cast<U: SimdElement>(self: Self) Simd<U, N>;

    /// `cast::<U>()` and the mask of the lanes whose value the conversion changed or that held a NaN.
    pub fn cast_checked<U: SimdElement>(self: Self) (Simd<U, N>, Mask<N>) {
        let r = self.cast::<U>();
        return r, self.cast_changed::<U>(r);
    }

    @intrinsic("simd.cast_changed")
    fn cast_changed<U: SimdElement>(self: Self, r: Simd<U, N>) Mask<N>;

    /// Each lane as `U`, a wider lane type of the same kind (signed, unsigned or float): exact.
    pub fn widen<U: SimdElement>(self: Self) Simd<U, N> {
        static_assert(sizeof(U) > sizeof(T) && type_info::<U>().kind == type_info::<T>().kind, "widen: U must be a wider lane type of the same kind as T");
        return self.cast::<U>();
    }

    /// The bytes of the vector as `M` lanes of `U`; `sizeof(T) * N == sizeof(U) * M`. The only
    /// conversion that reinterprets bits.
    pub fn bitcast<U: SimdElement, const M: usize>(self: Self) Simd<U, M> {
        static_assert(sizeof(T) * N == sizeof(U) * M, "bitcast: the two vectors must have the same size");
        return self.bitcast_bytes::<U, M>();
    }

    @intrinsic("simd.bitcast")
    fn bitcast_bytes<U: SimdElement, const M: usize>(self: Self) Simd<U, M>;

    /// Lanes `0` to `N / 2 - 1`; `N >= 4`.
    pub fn low_half(self: Self) Simd<T, {N / 2}> {
        static_assert(N >= 4, "low_half: the vector needs at least 4 lanes");
        return self.low_lanes();
    }

    @intrinsic("simd.low_half")
    fn low_lanes(self: Self) Simd<T, {N / 2}>;

    /// Lanes `N / 2` to `N - 1`; `N >= 4`.
    pub fn high_half(self: Self) Simd<T, {N / 2}> {
        static_assert(N >= 4, "high_half: the vector needs at least 4 lanes");
        return self.high_lanes();
    }

    @intrinsic("simd.high_half")
    fn high_lanes(self: Self) Simd<T, {N / 2}>;
}

extend<T: SimdInt, const N: usize> Simd<T, N> {
    /// `self + other` modulo 2^W in each lane, W the lane width.
    @intrinsic("simd.wrapping_add")
    pub fn wrapping_add(self: Self, other: Self) Self;

    /// `self - other` modulo 2^W in each lane.
    @intrinsic("simd.wrapping_sub")
    pub fn wrapping_sub(self: Self, other: Self) Self;

    /// `self * other` modulo 2^W in each lane.
    @intrinsic("simd.wrapping_mul")
    pub fn wrapping_mul(self: Self, other: Self) Self;

    /// `-self` modulo 2^W in each lane (MIN stays MIN).
    @intrinsic("simd.wrapping_neg")
    pub fn wrapping_neg(self: Self) Self;

    /// `self << (n % W)` in each lane: the count wraps at the width.
    @intrinsic("simd.wrapping_shl")
    pub fn wrapping_shl(self: Self, n: Self) Self;

    /// `self >> (n % W)` in each lane, arithmetic on signed lanes: the count wraps at the width.
    @intrinsic("simd.wrapping_shr")
    pub fn wrapping_shr(self: Self, n: Self) Self;

    /// `wrapping_add` and the mask of the lanes where `self + other` overflowed.
    pub fn checked_add(self: Self, other: Self) (Self, Mask<N>) {
        return self.wrapping_add(other), self.overflow_add(other);
    }

    /// `wrapping_sub` and the mask of the lanes where `self - other` overflowed.
    pub fn checked_sub(self: Self, other: Self) (Self, Mask<N>) {
        return self.wrapping_sub(other), self.overflow_sub(other);
    }

    /// `wrapping_mul` and the mask of the lanes where `self * other` overflowed.
    pub fn checked_mul(self: Self, other: Self) (Self, Mask<N>) {
        return self.wrapping_mul(other), self.overflow_mul(other);
    }

    @intrinsic("simd.overflow_add")
    fn overflow_add(self: Self, other: Self) Mask<N>;

    @intrinsic("simd.overflow_sub")
    fn overflow_sub(self: Self, other: Self) Mask<N>;

    @intrinsic("simd.overflow_mul")
    fn overflow_mul(self: Self, other: Self) Mask<N>;

    /// `self + other` in each lane, clamped to `[MIN, MAX]`.
    @intrinsic("simd.saturating_add")
    pub fn saturating_add(self: Self, other: Self) Self;

    /// `self - other` in each lane, clamped to `[MIN, MAX]`.
    @intrinsic("simd.saturating_sub")
    pub fn saturating_sub(self: Self, other: Self) Self;

    /// The smaller lane of each pair.
    @intrinsic("simd.min")
    pub fn min(self: Self, other: Self) Self;

    /// The larger lane of each pair.
    @intrinsic("simd.max")
    pub fn max(self: Self, other: Self) Self;

    /// Zero bits above the highest set bit of each lane (W for zero).
    @intrinsic("simd.leading_zeros")
    pub fn leading_zeros(self: Self) Self;

    /// Zero bits below the lowest set bit of each lane (W for zero).
    @intrinsic("simd.trailing_zeros")
    pub fn trailing_zeros(self: Self) Self;

    /// Set bits in each lane.
    @intrinsic("simd.count_ones")
    pub fn count_ones(self: Self) Self;

    /// Each lane rotated left by `n % W` bits.
    @intrinsic("simd.rotate_left")
    pub fn rotate_left(self: Self, n: Self) Self;

    /// Each lane rotated right by `n % W` bits.
    @intrinsic("simd.rotate_right")
    pub fn rotate_right(self: Self, n: Self) Self;

    /// The bits of each lane in reverse order.
    @intrinsic("simd.reverse_bits")
    pub fn reverse_bits(self: Self) Self;

    /// The bytes of each lane in reverse order.
    @intrinsic("simd.swap_bytes")
    pub fn swap_bytes(self: Self) Self;

    /// `|self - other|` in each lane, exact as the unsigned lane type of the width.
    @intrinsic("simd.abs_diff")
    pub fn abs_diff(self: Self, other: Self) Simd<T::Unsigned, N>;

    /// Each lane as `U`, a narrower integer type. Panics: a lane whose value `U` cannot hold.
    pub fn narrow<U: SimdInt>(self: Self) Simd<U, N> {
        static_assert(sizeof(U) < sizeof(T), "narrow: U must be a narrower integer type than T");
        return self.narrow_checked::<U>();
    }

    @intrinsic("simd.narrow")
    fn narrow_checked<U: SimdInt>(self: Self) Simd<U, N>;

    /// Each lane as `U`, a narrower integer type, clamped to the range of `U`.
    pub fn narrow_saturating<U: SimdInt>(self: Self) Simd<U, N> {
        static_assert(sizeof(U) < sizeof(T), "narrow_saturating: U must be a narrower integer type than T");
        return self.narrow_clamped::<U>();
    }

    @intrinsic("simd.narrow_saturating")
    fn narrow_clamped<U: SimdInt>(self: Self) Simd<U, N>;

    /// The low bits of each lane as `U`, a narrower integer type.
    pub fn narrow_wrapping<U: SimdInt>(self: Self) Simd<U, N> {
        static_assert(sizeof(U) < sizeof(T), "narrow_wrapping: U must be a narrower integer type than T");
        return self.cast::<U>();
    }
}

extend<T: SimdSigned, const N: usize> Simd<T, N> {
    /// The absolute value of each lane. Panics on an integer lane holding MIN (as `-MIN` does); a float
    /// lane loses its sign bit.
    @intrinsic("simd.abs")
    pub fn abs(self: Self) Self;
}

extend<T: SimdInt + SimdSigned, const N: usize> Simd<T, N> {
    /// The absolute value of each lane modulo 2^W (MIN stays MIN).
    @intrinsic("simd.wrapping_abs")
    pub fn wrapping_abs(self: Self) Self;
}

extend<T: SimdFloat, const N: usize> Simd<T, N> {
    /// Each lane with the magnitude of `self` and the sign bit of `sign`.
    @intrinsic("simd.copysign")
    pub fn copysign(self: Self, sign: Self) Self;

    /// IEEE 754-2019 minimumNumber of each pair: a NaN lane gives the other lane, and `-0.0` is below
    /// `+0.0`.
    @intrinsic("simd.min")
    pub fn min_num(self: Self, other: Self) Self;

    /// IEEE 754-2019 maximumNumber of each pair: a NaN lane gives the other lane, and `+0.0` is above
    /// `-0.0`.
    @intrinsic("simd.max")
    pub fn max_num(self: Self, other: Self) Self;

    /// IEEE 754-2019 minimum of each pair: a NaN lane gives NaN, and `-0.0` is below `+0.0`.
    @intrinsic("simd.minimum")
    pub fn minimum(self: Self, other: Self) Self;

    /// IEEE 754-2019 maximum of each pair: a NaN lane gives NaN, and `+0.0` is above `-0.0`.
    @intrinsic("simd.maximum")
    pub fn maximum(self: Self, other: Self) Self;

    /// The square root of each lane, correctly rounded.
    @intrinsic("simd.sqrt")
    pub fn sqrt(self: Self) Self;

    /// Each lane rounded up to an integer.
    @intrinsic("simd.ceil")
    pub fn ceil(self: Self) Self;

    /// Each lane rounded down to an integer.
    @intrinsic("simd.floor")
    pub fn floor(self: Self) Self;

    /// Each lane rounded toward zero to an integer.
    @intrinsic("simd.trunc")
    pub fn trunc(self: Self) Self;

    /// Each lane rounded to the nearest integer, ties to even.
    @intrinsic("simd.round_even")
    pub fn round_even(self: Self) Self;

    /// `self * b + c` in each lane with one rounding.
    @intrinsic("simd.fma")
    pub fn fma(self: Self, b: Self, c: Self) Self;

    /// The lanes holding a NaN.
    @intrinsic("simd.is_nan")
    pub fn is_nan(self: Self) Mask<N>;

    /// The lanes holding an infinity.
    @intrinsic("simd.is_infinite")
    pub fn is_infinite(self: Self) Mask<N>;

    /// The lanes holding neither an infinity nor a NaN.
    @intrinsic("simd.is_finite")
    pub fn is_finite(self: Self) Mask<N>;

    /// The lanes holding a normal number (not zero, subnormal, infinite or NaN).
    @intrinsic("simd.is_normal")
    pub fn is_normal(self: Self) Mask<N>;

    /// The lanes holding a subnormal number.
    @intrinsic("simd.is_subnormal")
    pub fn is_subnormal(self: Self) Mask<N>;

    /// The lanes whose sign bit is set (`-0.0` and a negative NaN included).
    @intrinsic("simd.is_sign_negative")
    pub fn is_sign_negative(self: Self) Mask<N>;
}

extend<T: SimdFloat, const N: usize> Simd<T, N> {
    /// The bits of each lane.
    @intrinsic("simd.bitcast")
    pub fn to_bits(self: Self) Simd<T::Bits, N>;

    /// The lanes whose bits are the lanes of `bits`.
    @intrinsic("simd.bitcast")
    pub fn from_bits(bits: Simd<T::Bits, N>) Self;
}

// The lane-wise operators: the scalar rule of the lane type in each lane (operations.md). Unary `-`
// needs `SimdSigned` lanes; the checker types it like a scalar's.

extend<T: SimdElement, const N: usize> Simd<T, N> as Add {
    type Output = Self;
    /// Lane-wise `+`.
    @intrinsic("simd.add")
    pub fn add(self: &Self, other: &Self) Self;
}

extend<T: SimdElement, const N: usize> Simd<T, N> as Sub {
    type Output = Self;
    /// Lane-wise `-`.
    @intrinsic("simd.sub")
    pub fn sub(self: &Self, other: &Self) Self;
}

extend<T: SimdElement, const N: usize> Simd<T, N> as Mul {
    type Output = Self;
    /// Lane-wise `*`.
    @intrinsic("simd.mul")
    pub fn mul(self: &Self, other: &Self) Self;
}

extend<T: SimdElement, const N: usize> Simd<T, N> as Div {
    type Output = Self;
    /// Lane-wise `/`.
    @intrinsic("simd.div")
    pub fn div(self: &Self, other: &Self) Self;
}

extend<T: SimdInt, const N: usize> Simd<T, N> as Rem {
    type Output = Self;
    /// Lane-wise `%`.
    @intrinsic("simd.rem")
    pub fn rem(self: &Self, other: &Self) Self;
}

extend<T: SimdInt, const N: usize> Simd<T, N> as BitAnd {
    type Output = Self;
    /// Lane-wise `&`.
    @intrinsic("simd.and")
    pub fn bit_and(self: &Self, other: &Self) Self;
}

extend<T: SimdInt, const N: usize> Simd<T, N> as BitOr {
    type Output = Self;
    /// Lane-wise `|`.
    @intrinsic("simd.or")
    pub fn bit_or(self: &Self, other: &Self) Self;
}

extend<T: SimdInt, const N: usize> Simd<T, N> as BitXor {
    type Output = Self;
    /// Lane-wise `^`.
    @intrinsic("simd.xor")
    pub fn bit_xor(self: &Self, other: &Self) Self;
}

extend<T: SimdInt, const N: usize> Simd<T, N> as BitNot {
    type Output = Self;
    /// Lane-wise `~`.
    @intrinsic("simd.not")
    pub fn bit_not(self: &Self) Self;
}

extend<T: SimdInt, const N: usize> Simd<T, N> as Shl<Simd<T, N>> {
    type Output = Self;
    /// Each lane shifted left by the count in the same lane. Panics: a count below 0 or of W or more.
    @intrinsic("simd.shl")
    pub fn shl(self: &Self, amount: Self) Self;
}

extend<T: SimdInt, const N: usize> Simd<T, N> as Shl<T> {
    type Output = Self;
    /// Every lane shifted left by `amount`. Panics: a count below 0 or of W or more.
    @intrinsic("simd.shl")
    pub fn shl(self: &Self, amount: T) Self;
}

extend<T: SimdInt, const N: usize> Simd<T, N> as Shr<Simd<T, N>> {
    type Output = Self;
    /// Each lane shifted right (arithmetic on signed lanes) by the count in the same lane. Panics: a
    /// count below 0 or of W or more.
    @intrinsic("simd.shr")
    pub fn shr(self: &Self, amount: Self) Self;
}

extend<T: SimdInt, const N: usize> Simd<T, N> as Shr<T> {
    type Output = Self;
    /// Every lane shifted right (arithmetic on signed lanes) by `amount`. Panics: a count below 0 or of
    /// W or more.
    @intrinsic("simd.shr")
    pub fn shr(self: &Self, amount: T) Self;
}

// A lane scalar right of an operator: `v op s` is `v op Simd::splat(s)` (the lowering splats `s`).

extend<T: SimdElement, const N: usize> Simd<T, N> as Add<T> {
    type Output = Self;
    /// Lane-wise `+` by `other` in every lane.
    @intrinsic("simd.add")
    pub fn add(self: &Self, other: &T) Self;
}

extend<T: SimdElement, const N: usize> Simd<T, N> as Sub<T> {
    type Output = Self;
    /// Lane-wise `-` by `other` in every lane.
    @intrinsic("simd.sub")
    pub fn sub(self: &Self, other: &T) Self;
}

extend<T: SimdElement, const N: usize> Simd<T, N> as Mul<T> {
    type Output = Self;
    /// Lane-wise `*` by `other` in every lane.
    @intrinsic("simd.mul")
    pub fn mul(self: &Self, other: &T) Self;
}

extend<T: SimdElement, const N: usize> Simd<T, N> as Div<T> {
    type Output = Self;
    /// Lane-wise `/` by `other` in every lane.
    @intrinsic("simd.div")
    pub fn div(self: &Self, other: &T) Self;
}

extend<T: SimdInt, const N: usize> Simd<T, N> as Rem<T> {
    type Output = Self;
    /// Lane-wise `%` by `other` in every lane.
    @intrinsic("simd.rem")
    pub fn rem(self: &Self, other: &T) Self;
}

extend<T: SimdInt, const N: usize> Simd<T, N> as BitAnd<T> {
    type Output = Self;
    /// Lane-wise `&` by `other` in every lane.
    @intrinsic("simd.and")
    pub fn bit_and(self: &Self, other: &T) Self;
}

extend<T: SimdInt, const N: usize> Simd<T, N> as BitOr<T> {
    type Output = Self;
    /// Lane-wise `|` by `other` in every lane.
    @intrinsic("simd.or")
    pub fn bit_or(self: &Self, other: &T) Self;
}

extend<T: SimdInt, const N: usize> Simd<T, N> as BitXor<T> {
    type Output = Self;
    /// Lane-wise `^` by `other` in every lane.
    @intrinsic("simd.xor")
    pub fn bit_xor(self: &Self, other: &T) Self;
}

// A lane scalar left of an operator: `s op v` is `Simd::splat(s) op v` (the lowering splats `s`).

extend<T: SimdElement, const N: usize> T as Add<Simd<T, N>> {
    type Output = Simd<T, N>;
    /// `self` in every lane, then lane-wise `+`.
    @intrinsic("simd.add")
    pub fn add(self: &Self, other: &Simd<T, N>) Simd<T, N>;
}

extend<T: SimdElement, const N: usize> T as Sub<Simd<T, N>> {
    type Output = Simd<T, N>;
    /// `self` in every lane, then lane-wise `-`.
    @intrinsic("simd.sub")
    pub fn sub(self: &Self, other: &Simd<T, N>) Simd<T, N>;
}

extend<T: SimdElement, const N: usize> T as Mul<Simd<T, N>> {
    type Output = Simd<T, N>;
    /// `self` in every lane, then lane-wise `*`.
    @intrinsic("simd.mul")
    pub fn mul(self: &Self, other: &Simd<T, N>) Simd<T, N>;
}

extend<T: SimdElement, const N: usize> T as Div<Simd<T, N>> {
    type Output = Simd<T, N>;
    /// `self` in every lane, then lane-wise `/`.
    @intrinsic("simd.div")
    pub fn div(self: &Self, other: &Simd<T, N>) Simd<T, N>;
}

extend<T: SimdInt, const N: usize> T as Rem<Simd<T, N>> {
    type Output = Simd<T, N>;
    /// `self` in every lane, then lane-wise `%`.
    @intrinsic("simd.rem")
    pub fn rem(self: &Self, other: &Simd<T, N>) Simd<T, N>;
}

extend<T: SimdInt, const N: usize> T as BitAnd<Simd<T, N>> {
    type Output = Simd<T, N>;
    /// `self` in every lane, then lane-wise `&`.
    @intrinsic("simd.and")
    pub fn bit_and(self: &Self, other: &Simd<T, N>) Simd<T, N>;
}

extend<T: SimdInt, const N: usize> T as BitOr<Simd<T, N>> {
    type Output = Simd<T, N>;
    /// `self` in every lane, then lane-wise `|`.
    @intrinsic("simd.or")
    pub fn bit_or(self: &Self, other: &Simd<T, N>) Simd<T, N>;
}

extend<T: SimdInt, const N: usize> T as BitXor<Simd<T, N>> {
    type Output = Simd<T, N>;
    /// `self` in every lane, then lane-wise `^`.
    @intrinsic("simd.xor")
    pub fn bit_xor(self: &Self, other: &Simd<T, N>) Simd<T, N>;
}

extend<T: SimdInt, const N: usize> T as Shl<Simd<T, N>> {
    type Output = Simd<T, N>;
    /// `self` in every lane, then lane-wise `<<`.
    @intrinsic("simd.shl")
    pub fn shl(self: &Self, amount: Simd<T, N>) Simd<T, N>;
}

extend<T: SimdInt, const N: usize> T as Shr<Simd<T, N>> {
    type Output = Simd<T, N>;
    /// `self` in every lane, then lane-wise `>>`.
    @intrinsic("simd.shr")
    pub fn shr(self: &Self, amount: Simd<T, N>) Simd<T, N>;
}

// The free forms of the named operations: `simd::f(a, ..)` is `a.f(..)`.

/// `a.equal(b)`.
@intrinsic("simd.eq")
pub fn equal<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Mask<N>;

/// `a.not_equal(b)`.
@intrinsic("simd.ne")
pub fn not_equal<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Mask<N>;

/// `a.less_than(b)`.
@intrinsic("simd.lt")
pub fn less_than<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Mask<N>;

/// `a.less_equal(b)`.
@intrinsic("simd.le")
pub fn less_equal<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Mask<N>;

/// `a.greater_than(b)`.
@intrinsic("simd.gt")
pub fn greater_than<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Mask<N>;

/// `a.greater_equal(b)`.
@intrinsic("simd.ge")
pub fn greater_equal<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Mask<N>;

/// `v.clamp(lo, hi)`.
pub fn clamp<T: SimdElement, const N: usize>(v: Simd<T, N>, lo: Simd<T, N>, hi: Simd<T, N>) Simd<T, N> {
    if lo.less_equal(hi) as u64 != ~0u64 >> (64 - N) as u64 {
        panic("Simd::clamp: a lane has lo > hi or a NaN bound");
    }
    return lo.lane_max(v.lane_min(hi));
}

/// `a.wrapping_add(b)`.
@intrinsic("simd.wrapping_add")
pub fn wrapping_add<T: SimdInt, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N>;

/// `a.wrapping_sub(b)`.
@intrinsic("simd.wrapping_sub")
pub fn wrapping_sub<T: SimdInt, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N>;

/// `a.wrapping_mul(b)`.
@intrinsic("simd.wrapping_mul")
pub fn wrapping_mul<T: SimdInt, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N>;

/// `a.saturating_add(b)`.
@intrinsic("simd.saturating_add")
pub fn saturating_add<T: SimdInt, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N>;

/// `a.saturating_sub(b)`.
@intrinsic("simd.saturating_sub")
pub fn saturating_sub<T: SimdInt, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N>;

/// `a.min(b)`.
@intrinsic("simd.min")
pub fn min<T: SimdInt, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N>;

/// `a.max(b)`.
@intrinsic("simd.max")
pub fn max<T: SimdInt, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N>;

/// `a.wrapping_shl(n)`.
@intrinsic("simd.wrapping_shl")
pub fn wrapping_shl<T: SimdInt, const N: usize>(a: Simd<T, N>, n: Simd<T, N>) Simd<T, N>;

/// `a.wrapping_shr(n)`.
@intrinsic("simd.wrapping_shr")
pub fn wrapping_shr<T: SimdInt, const N: usize>(a: Simd<T, N>, n: Simd<T, N>) Simd<T, N>;

/// `a.rotate_left(n)`.
@intrinsic("simd.rotate_left")
pub fn rotate_left<T: SimdInt, const N: usize>(a: Simd<T, N>, n: Simd<T, N>) Simd<T, N>;

/// `a.rotate_right(n)`.
@intrinsic("simd.rotate_right")
pub fn rotate_right<T: SimdInt, const N: usize>(a: Simd<T, N>, n: Simd<T, N>) Simd<T, N>;

/// `a.wrapping_neg()`.
@intrinsic("simd.wrapping_neg")
pub fn wrapping_neg<T: SimdInt, const N: usize>(a: Simd<T, N>) Simd<T, N>;

/// `a.leading_zeros()`.
@intrinsic("simd.leading_zeros")
pub fn leading_zeros<T: SimdInt, const N: usize>(a: Simd<T, N>) Simd<T, N>;

/// `a.trailing_zeros()`.
@intrinsic("simd.trailing_zeros")
pub fn trailing_zeros<T: SimdInt, const N: usize>(a: Simd<T, N>) Simd<T, N>;

/// `a.count_ones()`.
@intrinsic("simd.count_ones")
pub fn count_ones<T: SimdInt, const N: usize>(a: Simd<T, N>) Simd<T, N>;

/// `a.reverse_bits()`.
@intrinsic("simd.reverse_bits")
pub fn reverse_bits<T: SimdInt, const N: usize>(a: Simd<T, N>) Simd<T, N>;

/// `a.swap_bytes()`.
@intrinsic("simd.swap_bytes")
pub fn swap_bytes<T: SimdInt, const N: usize>(a: Simd<T, N>) Simd<T, N>;

/// `a.checked_add(b)`.
pub fn checked_add<T: SimdInt, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) (Simd<T, N>, Mask<N>) {
    return a.wrapping_add(b), a.overflow_add(b);
}

/// `a.checked_sub(b)`.
pub fn checked_sub<T: SimdInt, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) (Simd<T, N>, Mask<N>) {
    return a.wrapping_sub(b), a.overflow_sub(b);
}

/// `a.checked_mul(b)`.
pub fn checked_mul<T: SimdInt, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) (Simd<T, N>, Mask<N>) {
    return a.wrapping_mul(b), a.overflow_mul(b);
}

/// `a.abs_diff(b)`.
@intrinsic("simd.abs_diff")
pub fn abs_diff<T: SimdInt, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T::Unsigned, N>;

/// `a.abs()`.
@intrinsic("simd.abs")
pub fn abs<T: SimdSigned, const N: usize>(a: Simd<T, N>) Simd<T, N>;

/// `a.wrapping_abs()`.
@intrinsic("simd.wrapping_abs")
pub fn wrapping_abs<T: SimdInt + SimdSigned, const N: usize>(a: Simd<T, N>) Simd<T, N>;

/// `a.copysign(sign)`.
@intrinsic("simd.copysign")
pub fn copysign<T: SimdFloat, const N: usize>(a: Simd<T, N>, sign: Simd<T, N>) Simd<T, N>;

/// `a.min_num(b)`.
@intrinsic("simd.min")
pub fn min_num<T: SimdFloat, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N>;

/// `a.max_num(b)`.
@intrinsic("simd.max")
pub fn max_num<T: SimdFloat, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N>;

/// `a.minimum(b)`.
@intrinsic("simd.minimum")
pub fn minimum<T: SimdFloat, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N>;

/// `a.maximum(b)`.
@intrinsic("simd.maximum")
pub fn maximum<T: SimdFloat, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N>;

/// `a.sqrt()`.
@intrinsic("simd.sqrt")
pub fn sqrt<T: SimdFloat, const N: usize>(a: Simd<T, N>) Simd<T, N>;

/// `a.ceil()`.
@intrinsic("simd.ceil")
pub fn ceil<T: SimdFloat, const N: usize>(a: Simd<T, N>) Simd<T, N>;

/// `a.floor()`.
@intrinsic("simd.floor")
pub fn floor<T: SimdFloat, const N: usize>(a: Simd<T, N>) Simd<T, N>;

/// `a.trunc()`.
@intrinsic("simd.trunc")
pub fn trunc<T: SimdFloat, const N: usize>(a: Simd<T, N>) Simd<T, N>;

/// `a.round_even()`.
@intrinsic("simd.round_even")
pub fn round_even<T: SimdFloat, const N: usize>(a: Simd<T, N>) Simd<T, N>;

/// `a.fma(b, c)`.
@intrinsic("simd.fma")
pub fn fma<T: SimdFloat, const N: usize>(a: Simd<T, N>, b: Simd<T, N>, c: Simd<T, N>) Simd<T, N>;

/// `a.is_nan()`.
@intrinsic("simd.is_nan")
pub fn is_nan<T: SimdFloat, const N: usize>(a: Simd<T, N>) Mask<N>;

/// `a.is_infinite()`.
@intrinsic("simd.is_infinite")
pub fn is_infinite<T: SimdFloat, const N: usize>(a: Simd<T, N>) Mask<N>;

/// `a.is_finite()`.
@intrinsic("simd.is_finite")
pub fn is_finite<T: SimdFloat, const N: usize>(a: Simd<T, N>) Mask<N>;

/// `a.is_normal()`.
@intrinsic("simd.is_normal")
pub fn is_normal<T: SimdFloat, const N: usize>(a: Simd<T, N>) Mask<N>;

/// `a.is_subnormal()`.
@intrinsic("simd.is_subnormal")
pub fn is_subnormal<T: SimdFloat, const N: usize>(a: Simd<T, N>) Mask<N>;

/// `a.is_sign_negative()`.
@intrinsic("simd.is_sign_negative")
pub fn is_sign_negative<T: SimdFloat, const N: usize>(a: Simd<T, N>) Mask<N>;

/// `a.to_bits()`.
@intrinsic("simd.bitcast")
pub fn to_bits<T: SimdFloat, const N: usize>(a: Simd<T, N>) Simd<T::Bits, N>;

/// `Simd::<T, N>::from_bits(bits)`.
@intrinsic("simd.bitcast")
pub fn from_bits<T: SimdFloat, const N: usize>(bits: Simd<T::Bits, N>) Simd<T, N>;

/// The lanes `0, 1, ..., N - 1` (every lane type holds `N - 1`).
@intrinsic("simd.iota")
pub fn iota<T: SimdElement, const N: usize>() Simd<T, N>;

/// `m.choose(when_true, when_false)`.
@intrinsic("simd.choose")
pub fn choose<T: SimdElement, const N: usize>(m: Mask<N>, when_true: Simd<T, N>, when_false: Simd<T, N>) Simd<T, N>;

/// The lanes of `a`, then the lanes of `b`; `Simd<T, {2 * N}>` must be a valid vector.
@intrinsic("simd.concat")
pub fn concat<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, {2 * N}>;

/// The `N` elements of `s` from `start`. Panics unless `start <= s.len()` and `N <= s.len() - start`.
@intrinsic("simd.load")
pub fn load<T: SimdElement, const N: usize>(s: []T, start: usize) Simd<T, N>;

/// Store the lanes of `v` into the `N` elements of `s` from `start`. Panics unless `start <= s.len()`
/// and `N <= s.len() - start`.
@intrinsic("simd.store")
pub fn store<T: SimdElement, const N: usize>(s: []mut T, start: usize, v: Simd<T, N>);

/// The `N` elements at `p`, which need not be aligned. The caller guarantees `N` valid elements.
@intrinsic("simd.load_raw")
pub unsafe fn load_unaligned<T: SimdElement, const N: usize>(p: *const T) Simd<T, N>;

/// Store the lanes of `v` into the `N` elements at `p`, which need not be aligned. The caller
/// guarantees `N` valid elements.
@intrinsic("simd.store_raw")
pub unsafe fn store_unaligned<T: SimdElement, const N: usize>(p: *mut T, v: Simd<T, N>);

/// The `N` elements at `p`, which the caller guarantees `A`-byte aligned; `A` is a power of two of at
/// least `alignof(T)`. The caller guarantees `N` valid elements.
pub unsafe fn load_aligned<T: SimdElement, const N: usize, const A: usize>(p: *const T) Simd<T, N> {
    static_assert(A >= alignof(T) && (A & A - 1) == 0, "load_aligned: A must be a power of two of at least alignof(T)");
    return load_unaligned::<T, N>(p);
}

/// Store the lanes of `v` into the `N` elements at `p`, which the caller guarantees `A`-byte aligned;
/// `A` is a power of two of at least `alignof(T)`. The caller guarantees `N` valid elements.
pub unsafe fn store_aligned<T: SimdElement, const N: usize, const A: usize>(p: *mut T, v: Simd<T, N>) {
    static_assert(A >= alignof(T) && (A & A - 1) == 0, "store_aligned: A must be a power of two of at least alignof(T)");
    store_unaligned::<T, N>(p, v);
}

// Rearrangement (the language skill's references/simd.md). An index list is a `[usize; M]` constant
// expression; `M` is the result's lane count, and `Simd<T, M>` must be a valid vector.

/// Lane `i` is `v[idx[i]]`; every index is below `N`.
@intrinsic("simd.swizzle")
pub fn swizzle<T: SimdElement, const N: usize, const M: usize>(v: Simd<T, N>, idx: [usize; M]) Simd<T, M>;

/// Lane `i` is `a[idx[i]]` for an index below `N`, else `b[idx[i] - N]`; every index is below `2 * N`.
@intrinsic("simd.shuffle")
pub fn shuffle<T: SimdElement, const N: usize, const M: usize>(a: Simd<T, N>, b: Simd<T, N>, idx: [usize; M]) Simd<T, M>;

/// Lane `i` is `v[idx[i]]` for an index below `N`, else 0; `U` is an unsigned integer type.
pub fn swizzle_or_zero<T: SimdElement, U: SimdInt, const N: usize, const M: usize>(v: Simd<T, N>, idx: Simd<U, M>) Simd<
    T,
    M
> {
    static_assert(type_info::<U>().kind == type_info::<u8>().kind, "swizzle_or_zero: the indexes must be unsigned");
    return swizzle_zero(v, idx);
}

/// `swizzle_or_zero(v, idx)` and the mask of the lanes whose index is `N` or more.
pub fn swizzle_checked<T: SimdElement, U: SimdInt, const N: usize, const M: usize>(v: Simd<T, N>, idx: Simd<U, M>) (
    Simd<T, M>,
    Mask<M>
) {
    static_assert(type_info::<U>().kind == type_info::<u8>().kind, "swizzle_checked: the indexes must be unsigned");
    return swizzle_zero(v, idx), swizzle_oob(v, idx);
}

@intrinsic("simd.swizzle_or_zero")
fn swizzle_zero<T: SimdElement, U: SimdInt, const N: usize, const M: usize>(v: Simd<T, N>, idx: Simd<U, M>) Simd<T, M>;

@intrinsic("simd.swizzle_oob")
fn swizzle_oob<T: SimdElement, U: SimdInt, const N: usize, const M: usize>(v: Simd<T, N>, idx: Simd<U, M>) Mask<M>;

/// Lane `i` is `v[N - 1 - i]`.
pub fn reverse<T: SimdElement, const N: usize>(v: Simd<T, N>) Simd<T, N> {
    return swizzle(v, lane_list::<N>(N - 1, 0, 1, 0));
}

/// Lane `i` is `v[(i + K) % N]`.
pub fn rotate_lanes_left<const K: usize, T: SimdElement, const N: usize>(v: Simd<T, N>) Simd<T, N> {
    return swizzle(v, lane_list::<N>(K % N, 1, 0, 1));
}

/// Lane `i` is `v[(i + N - K % N) % N]`.
pub fn rotate_lanes_right<const K: usize, T: SimdElement, const N: usize>(v: Simd<T, N>) Simd<T, N> {
    return swizzle(v, lane_list::<N>(N - K % N, 1, 0, 1));
}

/// Lane `i` is `a[i / 2]` for an even `i`, else `b[i / 2]`.
pub fn interleave_low<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N> {
    return shuffle(a, b, lane_list::<N>(0, 2, 0, 0));
}

/// Lane `i` is `a[N / 2 + i / 2]` for an even `i`, else `b[N / 2 + i / 2]`.
pub fn interleave_high<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N> {
    return shuffle(a, b, lane_list::<N>(N / 2, 2, 0, 0));
}

/// The even lanes of `a`, then those of `b`: lane `i` is `a[2 * i]` below `N / 2`, else `b[2 * i - N]`.
pub fn deinterleave_even<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N> {
    return shuffle(a, b, lane_list::<N>(0, 3, 0, 0));
}

/// The odd lanes of `a`, then those of `b`: lane `i` is `a[2 * i + 1]` below `N / 2`, else
/// `b[2 * i + 1 - N]`.
pub fn deinterleave_odd<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T, N> {
    return shuffle(a, b, lane_list::<N>(1, 3, 0, 0));
}

/// `(interleave_low(a, b), interleave_high(a, b))`.
pub fn zip<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) (Simd<T, N>, Simd<T, N>) {
    return shuffle(a, b, lane_list::<N>(0, 2, 0, 0)), shuffle(a, b, lane_list::<N>(N / 2, 2, 0, 0));
}

/// `(deinterleave_even(a, b), deinterleave_odd(a, b))`.
pub fn unzip<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) (Simd<T, N>, Simd<T, N>) {
    return shuffle(a, b, lane_list::<N>(0, 3, 0, 0)), shuffle(a, b, lane_list::<N>(1, 3, 0, 0));
}

// The index list of `N` lanes from `base`: kind 0 counts down by `down` per lane (`reverse`), 1 counts
// up modulo `N` (the rotations), 2 interleaves (lane `i` from `base + i / 2` of `a`, or of `b` for an
// odd `i`), 3 deinterleaves (`base + 2 * i` of `a ++ b`).
const fn lane_list<const N: usize>(base: usize, kind: u8, down: usize, up: usize) [usize; N] {
    let mut a = [0usize; N];
    for i in 0..N {
        unsafe a[i] = if kind == 0 {
            base - i * down;
        } else if kind == 1 {
            (base + i * up) % N;
        } else if kind == 2 {
            base + i / 2 + i % 2 * N;
        } else {
            base + 2 * i;
        };
    }
    return a;
}

/// The active lanes of `v` in lane order at positions `0` to `count - 1`, and `fill[i]` at the
/// positions from `count`.
@intrinsic("simd.compress")
pub fn compress<T: SimdElement, const N: usize>(m: Mask<N>, v: Simd<T, N>, fill: Simd<T, N>) Simd<T, N>;

/// Active lane `i` is `packed[k]`, `k` the number of active lanes below `i`; inactive lane `i` is
/// `fill[i]`.
@intrinsic("simd.expand")
pub fn expand<T: SimdElement, const N: usize>(m: Mask<N>, packed: Simd<T, N>, fill: Simd<T, N>) Simd<T, N>;

// Reductions. An integer reduction wraps, so its result is independent of order; a float reduction
// names its order (`ordered` left to right, `tree` by halves), which fixes the result.

/// The lanes' sum modulo 2^W.
@intrinsic("simd.reduce_add")
pub fn reduce_add<T: SimdInt, const N: usize>(v: Simd<T, N>) T;

/// The lanes' product modulo 2^W.
@intrinsic("simd.reduce_mul")
pub fn reduce_mul<T: SimdInt, const N: usize>(v: Simd<T, N>) T;

/// The lanes' sum, or None when the exact sum does not fit `T`.
pub fn reduce_add_checked<T: SimdInt, const N: usize>(v: Simd<T, N>) Option<T> {
    if reduce_add_overflows(v) {
        return Option::<T>::None;
    }
    return Option::<T>::Some(reduce_add(v));
}

/// The lanes' product, or None when the exact product does not fit `T`.
pub fn reduce_mul_checked<T: SimdInt, const N: usize>(v: Simd<T, N>) Option<T> {
    if reduce_mul_overflows(v) {
        return Option::<T>::None;
    }
    return Option::<T>::Some(reduce_mul(v));
}

@intrinsic("simd.reduce_add_overflows")
fn reduce_add_overflows<T: SimdInt, const N: usize>(v: Simd<T, N>) bool;

@intrinsic("simd.reduce_mul_overflows")
fn reduce_mul_overflows<T: SimdInt, const N: usize>(v: Simd<T, N>) bool;

/// `((-0.0 + v[0]) + v[1]) + ... + v[N - 1]`, each sum rounded.
@intrinsic("simd.reduce_add_ordered")
pub fn reduce_add_ordered<T: SimdFloat, const N: usize>(v: Simd<T, N>) T;

/// `((1.0 * v[0]) * v[1]) * ... * v[N - 1]`, each product rounded.
@intrinsic("simd.reduce_mul_ordered")
pub fn reduce_mul_ordered<T: SimdFloat, const N: usize>(v: Simd<T, N>) T;

/// The sum by halves: `r[i] = v[i] + v[i + N / 2]` for the lower half, repeated until one lane.
@intrinsic("simd.reduce_add_tree")
pub fn reduce_add_tree<T: SimdFloat, const N: usize>(v: Simd<T, N>) T;

/// The product by halves, as `reduce_add_tree`.
@intrinsic("simd.reduce_mul_tree")
pub fn reduce_mul_tree<T: SimdFloat, const N: usize>(v: Simd<T, N>) T;

/// The smallest lane.
@intrinsic("simd.reduce_min")
pub fn reduce_min<T: SimdInt, const N: usize>(v: Simd<T, N>) T;

/// The largest lane.
@intrinsic("simd.reduce_max")
pub fn reduce_max<T: SimdInt, const N: usize>(v: Simd<T, N>) T;

/// The lanes reduced by `min_num`: NaN only when every lane is NaN.
@intrinsic("simd.reduce_min_num")
pub fn reduce_min_num<T: SimdFloat, const N: usize>(v: Simd<T, N>) T;

/// The lanes reduced by `max_num`: NaN only when every lane is NaN.
@intrinsic("simd.reduce_max_num")
pub fn reduce_max_num<T: SimdFloat, const N: usize>(v: Simd<T, N>) T;

/// The lanes reduced by `minimum`: NaN when a lane is NaN.
@intrinsic("simd.reduce_minimum")
pub fn reduce_minimum<T: SimdFloat, const N: usize>(v: Simd<T, N>) T;

/// The lanes reduced by `maximum`: NaN when a lane is NaN.
@intrinsic("simd.reduce_maximum")
pub fn reduce_maximum<T: SimdFloat, const N: usize>(v: Simd<T, N>) T;

/// The lanes' bitwise and.
@intrinsic("simd.reduce_and")
pub fn reduce_and<T: SimdInt, const N: usize>(v: Simd<T, N>) T;

/// The lanes' bitwise or.
@intrinsic("simd.reduce_or")
pub fn reduce_or<T: SimdInt, const N: usize>(v: Simd<T, N>) T;

/// The lanes' bitwise exclusive or.
@intrinsic("simd.reduce_xor")
pub fn reduce_xor<T: SimdInt, const N: usize>(v: Simd<T, N>) T;

/// The lowest lane holding the smallest value.
@intrinsic("simd.arg_min")
pub fn arg_min<T: SimdInt, const N: usize>(v: Simd<T, N>) usize;

/// The lowest lane holding the largest value.
@intrinsic("simd.arg_max")
pub fn arg_max<T: SimdInt, const N: usize>(v: Simd<T, N>) usize;

/// The lowest lane holding the smallest non-NaN value (`-0.0` below `+0.0`), or None when every lane
/// is NaN.
pub fn arg_min_num<T: SimdFloat, const N: usize>(v: Simd<T, N>) Option<usize> {
    let i = arg_min_lane(v);
    if i == N {
        return Option::<usize>::None;
    }
    return Option::<usize>::Some(i);
}

/// The lowest lane holding the largest non-NaN value (`+0.0` above `-0.0`), or None when every lane
/// is NaN.
pub fn arg_max_num<T: SimdFloat, const N: usize>(v: Simd<T, N>) Option<usize> {
    let i = arg_max_lane(v);
    if i == N {
        return Option::<usize>::None;
    }
    return Option::<usize>::Some(i);
}

@intrinsic("simd.arg_min_num")
fn arg_min_lane<T: SimdFloat, const N: usize>(v: Simd<T, N>) usize;

@intrinsic("simd.arg_max_num")
fn arg_max_lane<T: SimdFloat, const N: usize>(v: Simd<T, N>) usize;

/// The sum of `(a[i] as A) * (b[i] as A)`: modulo 2^W for an integer `A` at least as wide as `T`, and
/// as `reduce_add_ordered` of the products, each rounded to `A`, for a float `A` at least as wide.
pub fn dot<A: SimdElement, T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) A {
    static_assert(sizeof(A) >= sizeof(T) && type_info::<A>().kind == type_info::<f64>().kind == (type_info::<T>().kind == type_info::<
        f64
    >().kind), "dot: A must be a type of the same kind as T, at least as wide");
    return dot_lanes::<A>(a, b);
}

@intrinsic("simd.dot")
fn dot_lanes<A: SimdElement, T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) A;

// Masked and partial memory. An inactive lane never touches its element; every active lane is checked
// before the first access, and a failing one traps at the lowest. `I` is `u32` or `u64`.

/// Lane `i` is `s[start + i]` where that element exists, else `fallback[i]`. Never panics.
@intrinsic("simd.load_or")
pub fn load_or<T: SimdElement, const N: usize>(s: []T, start: usize, fallback: Simd<T, N>) Simd<T, N>;

/// Active lane `i` is `s[start + i]`; an inactive one is `fallback[i]`. Panics: an active lane past
/// `s`.
@intrinsic("simd.load_masked")
pub fn load_masked<T: SimdElement, const N: usize>(s: []T, start: usize, m: Mask<N>, fallback: Simd<T, N>) Simd<T, N>;

/// Store active lane `i` of `v` to `s[start + i]`. Panics before any write: an active lane past `s`.
@intrinsic("simd.store_masked")
pub fn store_masked<T: SimdElement, const N: usize>(s: []mut T, start: usize, m: Mask<N>, v: Simd<T, N>);

/// Active lane `i` is `s[idx[i]]`; an inactive one is `fallback[i]`. Panics: an active index past `s`.
pub fn gather<T: SimdElement, I: SimdInt, const N: usize>(s: []T, idx: Simd<I, N>, m: Mask<N>, fallback: Simd<T, N>) Simd<
    T,
    N
> {
    static_assert(sizeof(I) >= 4 && type_info::<I>().kind == type_info::<u8>().kind, "gather: the indexes must be u32 or u64");
    return gather_lanes(s, idx, m, fallback);
}

/// `gather` without the index check: the caller guarantees every active index below `s.len()`.
pub unsafe fn gather_unchecked<T: SimdElement, I: SimdInt, const N: usize>(
    s: []T,
    idx: Simd<I, N>,
    m: Mask<N>,
    fallback: Simd<T, N>,
) Simd<T, N> {
    static_assert(sizeof(I) >= 4 && type_info::<I>().kind == type_info::<u8>().kind, "gather_unchecked: the indexes must be u32 or u64");
    let bits = m.to_bits();
    let mut p: [*const T; N] = [s.as_ptr(); N];
    for i in 0..N {
        // An inactive lane's pointer stays at the start: its index may be past the end.
        if (bits >> i as u64 & 1) != 0 {
            p[i] = s.as_ptr() + idx[i] as usize;
        }
    }
    return gather_ptr(p, m, fallback);
}

/// Store active lane `i` of `v` to `s[idx[i]]`, in lane order: of active lanes with one index, the
/// highest is written last. Panics before any write: an active index past `s`.
pub fn scatter<T: SimdElement, I: SimdInt, const N: usize>(s: []mut T, idx: Simd<I, N>, m: Mask<N>, v: Simd<T, N>) {
    static_assert(sizeof(I) >= 4 && type_info::<I>().kind == type_info::<u8>().kind, "scatter: the indexes must be u32 or u64");
    scatter_lanes(s, idx, m, v);
}

@intrinsic("simd.gather")
fn gather_lanes<T: SimdElement, I: SimdInt, const N: usize>(s: []T, idx: Simd<I, N>, m: Mask<N>, fallback: Simd<T, N>) Simd<
    T,
    N
>;

@intrinsic("simd.scatter")
fn scatter_lanes<T: SimdElement, I: SimdInt, const N: usize>(s: []mut T, idx: Simd<I, N>, m: Mask<N>, v: Simd<T, N>);

/// Store the active lanes of `v` in lane order to `s[start..start + count]` and return `count`, the
/// active lane count; nothing past them changes (at most 8 elements after them may be rewritten with
/// their own values). Panics before any write: `start + count` past `s`.
@intrinsic("simd.compress_store")
pub fn compress_store<T: SimdElement, const N: usize>(s: []mut T, start: usize, m: Mask<N>, v: Simd<T, N>) usize;

/// Active lane `i` is `*p[i]`; an inactive one is `fallback[i]`. The caller guarantees every active
/// lane's pointer valid.
@intrinsic("simd.gather_ptr")
pub unsafe fn gather_ptr<T: SimdElement, const N: usize>(p: [*const T; N], m: Mask<N>, fallback: Simd<T, N>) Simd<T, N>;

/// Store active lane `i` of `v` to `*p[i]`, in lane order. The caller guarantees every active lane's
/// pointer valid.
@intrinsic("simd.scatter_ptr")
pub unsafe fn scatter_ptr<T: SimdElement, const N: usize>(p: [*mut T; N], m: Mask<N>, v: Simd<T, N>);

/// Active lane `i` is `p[i]`; an inactive one is `fallback[i]`. The caller guarantees every active
/// lane's element valid.
@intrinsic("simd.load_masked_ptr")
pub unsafe fn load_masked_ptr<T: SimdElement, const N: usize>(p: *const T, m: Mask<N>, fallback: Simd<T, N>) Simd<T, N>;

/// Store active lane `i` of `v` to `p[i]`. The caller guarantees every active lane's element valid.
@intrinsic("simd.store_masked_ptr")
pub unsafe fn store_masked_ptr<T: SimdElement, const N: usize>(p: *mut T, m: Mask<N>, v: Simd<T, N>);

extend<const N: usize> Mask<N> {
    /// `b` in every lane.
    pub fn splat(b: bool) Self {
        if b {
            return (~0u64 >> (64 - N) as u64) as Self;
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
        return self as u64 == ~0u64 >> (64 - N) as u64;
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
        return (b & ~0u64 >> (64 - N) as u64) as Self;
    }

    /// Lane `i` of `when_true` where lane `i` is set, else lane `i` of `when_false`.
    @intrinsic("simd.choose")
    pub fn choose<T: SimdElement>(self: Self, when_true: Simd<T, N>, when_false: Simd<T, N>) Simd<T, N>;

    /// The mask whose lane `i` is bit `i` of `b`, or None when a bit from `N` up is set.
    pub fn from_bits(b: u64) Option<Mask<N>> {
        if (b & ~(~0u64 >> (64 - N) as u64)) != 0 {
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
        return (~((*self) as u64) & ~0u64 >> (64 - N) as u64) as Self;
    }
}

/// The portable vector operations, for `@simd_impl` (std only): one variant per operator, cast and
/// named operation, then the lane-mask forms and in-range scalar shifts the lowering planner composes
/// (`CmpEqLanes` to `ShrScalar`; a lane mask has a lane of all ones where the condition holds). The
/// compiler's operation table is the source of truth: the order and names follow it.
pub enum Op {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    And,
    Or,
    Xor,
    Shl,
    Shr,
    Neg,
    Not,
    Cast,
    Iota,
    CmpEq,
    CmpNe,
    CmpLt,
    CmpLe,
    CmpGt,
    CmpGe,
    Choose,
    WrappingAdd,
    WrappingSub,
    WrappingMul,
    WrappingNeg,
    WrappingShl,
    WrappingShr,
    OverflowAdd,
    OverflowSub,
    OverflowMul,
    SaturatingAdd,
    SaturatingSub,
    Min,
    Max,
    Abs,
    WrappingAbs,
    AbsDiff,
    LeadingZeros,
    TrailingZeros,
    CountOnes,
    RotateLeft,
    RotateRight,
    ReverseBits,
    SwapBytes,
    Copysign,
    Minimum,
    Maximum,
    Sqrt,
    Ceil,
    Floor,
    Trunc,
    RoundEven,
    Fma,
    IsNan,
    IsInfinite,
    IsFinite,
    IsNormal,
    IsSubnormal,
    IsSignNegative,
    CastChanged,
    Narrow,
    NarrowSaturating,
    Bitcast,
    LowHalf,
    HighHalf,
    Concat,
    Load,
    Store,
    LoadRaw,
    StoreRaw,
    Swizzle,
    Shuffle,
    SwizzleOrZero,
    SwizzleOob,
    Compress,
    Expand,
    ReduceAdd,
    ReduceMul,
    ReduceAddOrdered,
    ReduceMulOrdered,
    ReduceAddTree,
    ReduceMulTree,
    ReduceAddOverflows,
    ReduceMulOverflows,
    ReduceMin,
    ReduceMax,
    ReduceMinNum,
    ReduceMaxNum,
    ReduceMinimum,
    ReduceMaximum,
    ReduceAnd,
    ReduceOr,
    ReduceXor,
    ArgMin,
    ArgMax,
    ArgMinNum,
    ArgMaxNum,
    Dot,
    LoadOr,
    LoadMasked,
    StoreMasked,
    Gather,
    Scatter,
    CompressStore,
    GatherPtr,
    ScatterPtr,
    LoadMaskedPtr,
    StoreMaskedPtr,
    CmpEqLanes,
    CmpNeLanes,
    CmpLtLanes,
    CmpLeLanes,
    CmpGtLanes,
    CmpGeLanes,
    ChooseLanes,
    LanesToMask,
    MaskToLanes,
    AnyLanes,
    AllLanes,
    ShlScalar,
    ShrScalar,
}
