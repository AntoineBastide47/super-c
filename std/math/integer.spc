// Integer functions on integer scalars and `Vec`s, component by component: extended arithmetic, bit
// fields, bit counts, powers of two, multiples, masks and bit interleaving. The integer `log2` is
// `log2_int` because `log2` is the float function. On 8- and 16-bit components, `is_power_of_two`,
// `prev_power_of_two`, `round_power_of_two`, `next_multiple` and `ceil_multiple` compute some steps in
// `i64` and return their results. Signed 32- and 64-bit overflow traps in a profile with overflow checks;
// a shift count out of range traps (8- and 16-bit components shift in `i32`).
import std::math::scalar as *;
import std::math::vec as *;

/// The result shape with `U` components, for `U` = `i32` or `bool`: a scalar `T` becomes `U` and
/// `Vec<T, N>` becomes `Vec<U, N>`.
pub interface GenAs<U: Elem, O>: Copy {
    /// Every component `v`.
    fn out_of(v: U) O;
    /// Set component `i` of `o` to `v`.
    fn out_put(o: &mut O, i: usize, v: U);
    /// False for a scalar, true for a vector: the scalar and vector forms of `is_power_of_two` differ on
    /// an 8- or 16-bit minimum.
    fn is_vec() bool;
}

extend<T: Scalar> T as GenAs<i32, i32> {
    pub fn out_of(v: i32) i32 {
        return v;
    }
    pub fn out_put(o: &mut i32, i: usize, v: i32) {
        *o = v;
    }
    pub fn is_vec() bool {
        return false;
    }
}

extend<T: Scalar> T as GenAs<bool, bool> {
    pub fn out_of(v: bool) bool {
        return v;
    }
    pub fn out_put(o: &mut bool, i: usize, v: bool) {
        *o = v;
    }
    pub fn is_vec() bool {
        return false;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as GenAs<i32, Vec<i32, N>> {
    pub fn out_of(v: i32) Vec<i32, N> {
        return Vec::<i32, N> { e: [v; N] };
    }
    pub fn out_put(o: &mut Vec<i32, N>, i: usize, v: i32) {
        unsafe {
            o.e[i] = v;
        }
    }
    pub fn is_vec() bool {
        return true;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as GenAs<bool, Vec<bool, N>> {
    pub fn out_of(v: bool) Vec<bool, N> {
        return Vec::<bool, N> { e: [v; N] };
    }
    pub fn out_put(o: &mut Vec<bool, N>, i: usize, v: bool) {
        unsafe {
            o.e[i] = v;
        }
    }
    pub fn is_vec() bool {
        return true;
    }
}

/// `(x + y mod 2^32, carry)`, carry 1 when the sum exceeds 2^32 - 1.
pub fn uadd_carry<G: Gen<u32>>(x: G, y: G) (G, G) {
    let mut sum = x;
    let mut carry = x;
    for i in 0..G::len() {
        let v = x.at(i) as u64 + y.at(i) as u64;
        sum.put(i, v as u32);
        carry.put(i, (v >> 32) as u32);
    }
    return sum, carry;
}

/// `(x - y mod 2^32, borrow)`, borrow 1 when `x < y`.
pub fn usub_borrow<G: Gen<u32>>(x: G, y: G) (G, G) {
    let mut diff = x;
    let mut borrow = x;
    for i in 0..G::len() {
        diff.put(i, x.at(i).wrapping_sub(y.at(i)));
        borrow.put(
            i,
            if x.at(i) >= y.at(i) {
                0u32;
            } else {
                1u32;
            },
        );
    }
    return diff, borrow;
}

/// The 64-bit product of `x` and `y` as `(msb, lsb)`.
pub fn umul_extended<G: Gen<u32>>(x: G, y: G) (G, G) {
    let mut msb = x;
    let mut lsb = x;
    for i in 0..G::len() {
        let v = x.at(i) as u64 * y.at(i) as u64;
        msb.put(i, (v >> 32) as u32);
        lsb.put(i, v as u32);
    }
    return msb, lsb;
}

/// The 64-bit signed product of `x` and `y` as `(msb, lsb)`.
pub fn imul_extended<G: Gen<i32>>(x: G, y: G) (G, G) {
    let mut msb = x;
    let mut lsb = x;
    for i in 0..G::len() {
        let v = x.at(i) as i64 * y.at(i) as i64;
        msb.put(i, (v >> 32) as i32);
        lsb.put(i, v as i32);
    }
    return msb, lsb;
}

/// `(value >> offset) & mask`, the mask built in `i32`: all ones for `bits` >= 32, so a 64-bit
/// `value` keeps every bit above `offset`.
pub fn bitfield_extract<T: Int, G: Gen<T>>(value: G, offset: i32, bits: i32) G {
    let mask = T::from_i64(int_mask(bits));
    let mut r = value;
    for i in 0..G::len() {
        r.put(i, value.at(i) >> T::from_i64(offset) & mask);
    }
    return r;
}

/// `base` with its `bits` bits from `offset` replaced by the low bits of `insert`.
pub fn bitfield_insert<T: Int, G: Gen<T>>(base: G, insert: G, offset: i32, bits: i32) G {
    let mask = type_mask(T::from_i64(bits)) << T::from_i64(offset);
    let mut r = base;
    for i in 0..G::len() {
        r.put(i, base.at(i) & ~mask | insert.at(i) << T::from_i64(offset) & mask);
    }
    return r;
}

/// The bits of each component in reverse order, by swaps of 1, 2, 4, .. bit groups. A signed
/// component shifts right arithmetically, so a negative one does not reverse exactly.
pub fn bitfield_reverse<T: Int, G: Gen<T>>(v: G) G {
    let mut r = v;
    for i in 0..G::len() {
        let mut x = v.at(i);
        x = reverse_step(x, T::from_u64(0x5555555555555555), 1);
        x = reverse_step(x, T::from_u64(0x3333333333333333), 2);
        x = reverse_step(x, T::from_u64(0x0F0F0F0F0F0F0F0F), 4);
        if T::bits() >= 16 {
            x = reverse_step(x, T::from_u64(0x00FF00FF00FF00FF), 8);
        }
        if T::bits() >= 32 {
            x = reverse_step(x, T::from_u64(0x0000FFFF0000FFFF), 16);
        }
        if T::bits() >= 64 {
            x = reverse_step(x, T::from_u64(0x00000000FFFFFFFF), 32);
        }
        r.put(i, x);
    }
    return r;
}

/// The number of one bits of each component's two's complement pattern.
pub fn bit_count<T: Int, G: Gen<T> + GenAs<i32, O>, O>(v: G) O {
    let mut r = G::out_of(0);
    for i in 0..G::len() {
        G::out_put(&mut r, i, v.at(i).count_ones());
    }
    return r;
}

/// The index of the lowest one bit, -1 for zero.
pub fn find_lsb<T: Int, G: Gen<T> + GenAs<i32, O>, O>(v: G) O {
    let mut r = G::out_of(0);
    for i in 0..G::len() {
        G::out_put(&mut r, i, lsb(v.at(i)));
    }
    return r;
}

/// The index of the highest one bit, -1 for zero; the bit width minus one for a negative component.
pub fn find_msb<T: Int, G: Gen<T> + GenAs<i32, O>, O>(v: G) O {
    let mut r = G::out_of(0);
    for i in 0..G::len() {
        G::out_put(&mut r, i, msb(v.at(i)));
    }
    return r;
}

/// Whether `abs(v)` has at most one bit set, so 0 is true. On an `i8` or `i16` minimum the scalar
/// form is false (it tests `abs(v)` in `i64`) and the vector form true (`abs(v)` wraps to the minimum).
pub fn is_power_of_two<T: Int, G: Gen<T> + GenAs<bool, O>, O>(v: G) O {
    let mut r = G::out_of(false);
    for i in 0..G::len() {
        let x = v.at(i);
        let p = if G::is_vec() {
            let a = int_abs(x);
            (a & a - T::one()).equal(T::zero());
        } else {
            is_pow2(x);
        };
        G::out_put(&mut r, i, p);
    }
    return r;
}

/// The smallest power of two not below `abs(v)`, with the sign of `v`; 0 gives 0.
pub fn next_power_of_two<T: Int, G: Gen<T>>(v: G) G {
    let mut r = v;
    for i in 0..G::len() {
        r.put(i, ceil_pow2(v.at(i)));
    }
    return r;
}

/// `v` when it is a power of two (`is_power_of_two`), else the power of two of its highest bit.
pub fn prev_power_of_two<T: Int, G: Gen<T>>(v: G) G {
    let mut r = v;
    for i in 0..G::len() {
        r.put(i, floor_pow2(v.at(i)));
    }
    return r;
}

/// `v % multiple == 0`. A zero `multiple` traps.
pub fn is_multiple<T: Int, G: Gen<T> + GenAs<bool, O>, O, B: Arg<G>>(v: G, multiple: B) O {
    let m = multiple.to_gen();
    let mut r = G::out_of(false);
    for i in 0..G::len() {
        G::out_put(&mut r, i, (v.at(i) % m.at(i)).equal(T::zero()));
    }
    return r;
}

/// The smallest multiple of `multiple` not below `source`. A signed `multiple` that is not positive
/// panics.
pub fn next_multiple<T: Int, G: Gen<T>, B: Arg<G>>(source: G, multiple: B) G {
    let m = multiple.to_gen();
    let mut r = source;
    for i in 0..G::len() {
        r.put(i, int_ceil_multiple(source.at(i), m.at(i)));
    }
    return r;
}

/// The largest multiple of `multiple` not above `source`.
pub fn prev_multiple<T: Int, G: Gen<T>, B: Arg<G>>(source: G, multiple: B) G {
    let m = multiple.to_gen();
    let mut r = source;
    for i in 0..G::len() {
        r.put(i, int_floor_multiple(source.at(i), m.at(i)));
    }
    return r;
}

/// The index of the `significant_bit_count`-th one bit from the lowest, -1 when the component has
/// fewer one bits.
pub fn find_nsb<T: Int, G: Gen<T> + GenAs<i32, O>, O: Gen<i32>>(x: G, significant_bit_count: O) O {
    let mut r = significant_bit_count;
    for i in 0..G::len() {
        r.put(i, nsb(x.at(i), significant_bit_count.at(i)));
    }
    return r;
}

/// The integer base-2 logarithm: `find_msb` as `T`, so 0 gives -1 (all ones when unsigned).
pub fn log2_int<T: Int, G: Gen<T>>(v: G) G {
    let mut r = v;
    for i in 0..G::len() {
        r.put(i, T::from_i64(msb(v.at(i))));
    }
    return r;
}

/// The same as `next_power_of_two`.
pub fn ceil_power_of_two<T: Int, G: Gen<T>>(v: G) G {
    return next_power_of_two(v);
}

/// The same as `prev_power_of_two`.
pub fn floor_power_of_two<T: Int, G: Gen<T>>(v: G) G {
    return prev_power_of_two(v);
}

/// `v` when it is a power of two, else the nearer of the powers of two around its highest bit (the
/// lower one on a tie).
pub fn round_power_of_two<T: Int, G: Gen<T>>(v: G) G {
    let mut r = v;
    for i in 0..G::len() {
        r.put(i, round_pow2(v.at(i)));
    }
    return r;
}

/// The component types `ceil_multiple`, `floor_multiple` and `round_multiple` take: integers and
/// floats, each with its own formula.
pub interface RoundMultiple: Scalar {
    fn ceil_multiple(self: Self, multiple: Self) Self;
    fn floor_multiple(self: Self, multiple: Self) Self;
    fn round_multiple(self: Self, multiple: Self) Self;
}

/// The smallest multiple of `multiple` not below `source`. A signed integer `multiple` that is not
/// positive panics. Floats use `source + (multiple - fmod(source, multiple))` for a positive `source`,
/// else `source + fmod(-source, multiple)`.
pub fn ceil_multiple<T: RoundMultiple, G: Gen<T>>(source: G, multiple: G) G {
    let mut r = source;
    for i in 0..G::len() {
        r.put(i, source.at(i).ceil_multiple(multiple.at(i)));
    }
    return r;
}

/// The largest multiple of `multiple` not above `source`.
pub fn floor_multiple<T: RoundMultiple, G: Gen<T>>(source: G, multiple: G) G {
    let mut r = source;
    for i in 0..G::len() {
        r.put(i, source.at(i).floor_multiple(multiple.at(i)));
    }
    return r;
}

/// A floor, not a rounding: integers as `floor_multiple`, a negative float from `source + 1`.
pub fn round_multiple<T: RoundMultiple, G: Gen<T>>(source: G, multiple: G) G {
    let mut r = source;
    for i in 0..G::len() {
        r.put(i, source.at(i).round_multiple(multiple.at(i)));
    }
    return r;
}

extend<T: Int> T as RoundMultiple {
    pub fn ceil_multiple(self: T, multiple: T) T {
        return int_ceil_multiple(self, multiple);
    }
    pub fn floor_multiple(self: T, multiple: T) T {
        return int_floor_multiple(self, multiple);
    }
    pub fn round_multiple(self: T, multiple: T) T {
        return int_floor_multiple(self, multiple);
    }
}

extend f32 as RoundMultiple {
    pub fn ceil_multiple(self: f32, multiple: f32) f32 {
        return float_ceil_multiple(self, multiple);
    }
    pub fn floor_multiple(self: f32, multiple: f32) f32 {
        return float_floor_multiple(self, multiple);
    }
    pub fn round_multiple(self: f32, multiple: f32) f32 {
        return float_round_multiple(self, multiple);
    }
}

extend f64 as RoundMultiple {
    pub fn ceil_multiple(self: f64, multiple: f64) f64 {
        return float_ceil_multiple(self, multiple);
    }
    pub fn floor_multiple(self: f64, multiple: f64) f64 {
        return float_floor_multiple(self, multiple);
    }
    pub fn round_multiple(self: f64, multiple: f64) f64 {
        return float_round_multiple(self, multiple);
    }
}

/// The low `bits` bits set; all bits for `bits` >= the bit width.
pub fn mask<T: Int, G: Gen<T>>(bits: G) G {
    let mut r = bits;
    for i in 0..G::len() {
        r.put(i, type_mask(bits.at(i)));
    }
    return r;
}

/// `(v << shift) | (v >> (width - shift))`: a rotation to the left for an unsigned component.
pub fn bitfield_rotate_right<T: Int, G: Gen<T>>(v: G, shift: i32) G {
    let mut r = v;
    for i in 0..G::len() {
        let x = v.at(i);
        r.put(i, x << T::from_i64(shift) | x >> T::from_i64(T::bits() - shift));
    }
    return r;
}

/// `(v >> shift) | (v << (width - shift))`: a rotation to the right for an unsigned component.
pub fn bitfield_rotate_left<T: Int, G: Gen<T>>(v: G, shift: i32) G {
    let mut r = v;
    for i in 0..G::len() {
        let x = v.at(i);
        r.put(i, x >> T::from_i64(shift) | x << T::from_i64(T::bits() - shift));
    }
    return r;
}

/// `v` with `bit_count` bits from `first_bit` set. The mask is built in `i32`, so for a 64-bit `v` it
/// sign-extends.
pub fn bitfield_fill_one<T: Int, G: Gen<T>>(v: G, first_bit: i32, bit_count: i32) G {
    let fill = T::from_i64(int_mask(bit_count) << first_bit);
    let mut r = v;
    for i in 0..G::len() {
        r.put(i, v.at(i) | fill);
    }
    return r;
}

/// `v` with `bit_count` bits from `first_bit` cleared (mask built as in `bitfield_fill_one`).
pub fn bitfield_fill_zero<T: Int, G: Gen<T>>(v: G, first_bit: i32, bit_count: i32) G {
    let fill = T::from_i64(~(int_mask(bit_count) << first_bit));
    let mut r = v;
    for i in 0..G::len() {
        r.put(i, v.at(i) & fill);
    }
    return r;
}

/// The bits of `x` and `y` alternated, `x` in the even bits.
pub const fn bitfield_interleave_i8x2(x: i8, y: i8) i16 {
    return bitfield_interleave_u8x2(x as u8, y as u8) as i16;
}

/// The bits of `x` and `y` alternated, `x` in the even bits.
pub const fn bitfield_interleave_u8x2(x: u8, y: u8) u16 {
    let mut r1 = x as u16;
    let mut r2 = y as u16;
    r1 = (r1 << 4 | r1) & 0x0F0F;
    r2 = (r2 << 4 | r2) & 0x0F0F;
    r1 = (r1 << 2 | r1) & 0x3333;
    r2 = (r2 << 2 | r2) & 0x3333;
    r1 = (r1 << 1 | r1) & 0x5555;
    r2 = (r2 << 1 | r2) & 0x5555;
    return r1 | r2 << 1;
}

/// `bitfield_interleave_u8x2` of the components of `v`.
pub const fn bitfield_interleave_u8vec2(v: Vec<u8, 2>) u16 {
    return bitfield_interleave_u8x2(v.e[0], v.e[1]);
}

/// The bits of `x` and `y` alternated, `x` in the even bits.
pub const fn bitfield_interleave_i16x2(x: i16, y: i16) i32 {
    return bitfield_interleave_u16x2(x as u16, y as u16) as i32;
}

/// The bits of `x` and `y` alternated, `x` in the even bits.
pub const fn bitfield_interleave_u16x2(x: u16, y: u16) u32 {
    let mut r1 = x as u32;
    let mut r2 = y as u32;
    r1 = (r1 << 8 | r1) & 0x00FF00FF;
    r2 = (r2 << 8 | r2) & 0x00FF00FF;
    r1 = (r1 << 4 | r1) & 0x0F0F0F0F;
    r2 = (r2 << 4 | r2) & 0x0F0F0F0F;
    r1 = (r1 << 2 | r1) & 0x33333333;
    r2 = (r2 << 2 | r2) & 0x33333333;
    r1 = (r1 << 1 | r1) & 0x55555555;
    r2 = (r2 << 1 | r2) & 0x55555555;
    return r1 | r2 << 1;
}

/// `bitfield_interleave_u16x2` of the components of `v`.
pub const fn bitfield_interleave_u16vec2(v: Vec<u16, 2>) u32 {
    return bitfield_interleave_u16x2(v.e[0], v.e[1]);
}

/// The bits of `x` and `y` alternated, `x` in the even bits.
pub const fn bitfield_interleave_i32x2(x: i32, y: i32) i64 {
    return bitfield_interleave_u32x2(x as u32, y as u32) as i64;
}

/// The bits of `x` and `y` alternated, `x` in the even bits.
pub const fn bitfield_interleave_u32x2(x: u32, y: u32) u64 {
    let mut r1 = x as u64;
    let mut r2 = y as u64;
    r1 = (r1 << 16 | r1) & 0x0000FFFF0000FFFF;
    r2 = (r2 << 16 | r2) & 0x0000FFFF0000FFFF;
    r1 = (r1 << 8 | r1) & 0x00FF00FF00FF00FF;
    r2 = (r2 << 8 | r2) & 0x00FF00FF00FF00FF;
    r1 = (r1 << 4 | r1) & 0x0F0F0F0F0F0F0F0F;
    r2 = (r2 << 4 | r2) & 0x0F0F0F0F0F0F0F0F;
    r1 = (r1 << 2 | r1) & 0x3333333333333333;
    r2 = (r2 << 2 | r2) & 0x3333333333333333;
    r1 = (r1 << 1 | r1) & 0x5555555555555555;
    r2 = (r2 << 1 | r2) & 0x5555555555555555;
    return r1 | r2 << 1;
}

/// `bitfield_interleave_u32x2` of the components of `v`.
pub const fn bitfield_interleave_u32vec2(v: Vec<u32, 2>) u64 {
    return bitfield_interleave_u32x2(v.e[0], v.e[1]);
}

/// `x`, `y`, `z` in bits 3k, 3k + 1, 3k + 2.
pub const fn bitfield_interleave_i8x3(x: i8, y: i8, z: i8) i32 {
    return bitfield_interleave_u8x3(x as u8, y as u8, z as u8) as i32;
}

/// `x`, `y`, `z` in bits 3k, 3k + 1, 3k + 2.
pub const fn bitfield_interleave_u8x3(x: u8, y: u8, z: u8) u32 {
    let mut r1 = x as u32;
    let mut r2 = y as u32;
    let mut r3 = z as u32;
    r1 = (r1 << 16 | r1) & 0xFF0000FF;
    r2 = (r2 << 16 | r2) & 0xFF0000FF;
    r3 = (r3 << 16 | r3) & 0xFF0000FF;
    r1 = (r1 << 8 | r1) & 0x0F00F00F;
    r2 = (r2 << 8 | r2) & 0x0F00F00F;
    r3 = (r3 << 8 | r3) & 0x0F00F00F;
    r1 = (r1 << 4 | r1) & 0xC30C30C3;
    r2 = (r2 << 4 | r2) & 0xC30C30C3;
    r3 = (r3 << 4 | r3) & 0xC30C30C3;
    r1 = (r1 << 2 | r1) & 0x49249249;
    r2 = (r2 << 2 | r2) & 0x49249249;
    r3 = (r3 << 2 | r3) & 0x49249249;
    return r1 | r2 << 1 | r3 << 2;
}

/// `bitfield_interleave_u8x3` of the components of `v`.
pub const fn bitfield_interleave_u8vec3(v: Vec<u8, 3>) u32 {
    return bitfield_interleave_u8x3(v.e[0], v.e[1], v.e[2]);
}

/// `x`, `y`, `z` in bits 3k, 3k + 1, 3k + 2.
pub const fn bitfield_interleave_i16x3(x: i16, y: i16, z: i16) i64 {
    return bitfield_interleave_u16x3(x as u16, y as u16, z as u16) as i64;
}

/// `x`, `y`, `z` in bits 3k, 3k + 1, 3k + 2.
pub const fn bitfield_interleave_u16x3(x: u16, y: u16, z: u16) u64 {
    return bitfield_interleave_u32x3(x, y, z);
}

/// `bitfield_interleave_u16x3` of the components of `v`.
pub const fn bitfield_interleave_u16vec3(v: Vec<u16, 3>) u64 {
    return bitfield_interleave_u32x3(v.e[0], v.e[1], v.e[2]);
}

/// `x`, `y`, `z` in bits 3k, 3k + 1, 3k + 2: only the low 21 bits of each input reach the result.
pub const fn bitfield_interleave_i32x3(x: i32, y: i32, z: i32) i64 {
    return bitfield_interleave_u32x3(x as u32, y as u32, z as u32) as i64;
}

/// `x`, `y`, `z` in bits 3k, 3k + 1, 3k + 2: only the low 21 bits of each input reach the result.
pub const fn bitfield_interleave_u32x3(x: u32, y: u32, z: u32) u64 {
    let mut r1 = x as u64;
    let mut r2 = y as u64;
    let mut r3 = z as u64;
    r1 = (r1 << 32 | r1) & 0xFFFF00000000FFFF;
    r2 = (r2 << 32 | r2) & 0xFFFF00000000FFFF;
    r3 = (r3 << 32 | r3) & 0xFFFF00000000FFFF;
    r1 = (r1 << 16 | r1) & 0x00FF0000FF0000FF;
    r2 = (r2 << 16 | r2) & 0x00FF0000FF0000FF;
    r3 = (r3 << 16 | r3) & 0x00FF0000FF0000FF;
    r1 = (r1 << 8 | r1) & 0xF00F00F00F00F00F;
    r2 = (r2 << 8 | r2) & 0xF00F00F00F00F00F;
    r3 = (r3 << 8 | r3) & 0xF00F00F00F00F00F;
    r1 = (r1 << 4 | r1) & 0x30C30C30C30C30C3;
    r2 = (r2 << 4 | r2) & 0x30C30C30C30C30C3;
    r3 = (r3 << 4 | r3) & 0x30C30C30C30C30C3;
    r1 = (r1 << 2 | r1) & 0x9249249249249249;
    r2 = (r2 << 2 | r2) & 0x9249249249249249;
    r3 = (r3 << 2 | r3) & 0x9249249249249249;
    return r1 | r2 << 1 | r3 << 2;
}

/// `bitfield_interleave_u32x3` of the components of `v`.
pub const fn bitfield_interleave_u32vec3(v: Vec<u32, 3>) u64 {
    return bitfield_interleave_u32x3(v.e[0], v.e[1], v.e[2]);
}

/// `x`, `y`, `z`, `w` in bits 4k .. 4k + 3.
pub const fn bitfield_interleave_i8x4(x: i8, y: i8, z: i8, w: i8) i32 {
    return bitfield_interleave_u8x4(x as u8, y as u8, z as u8, w as u8) as i32;
}

/// `x`, `y`, `z`, `w` in bits 4k .. 4k + 3.
pub const fn bitfield_interleave_u8x4(x: u8, y: u8, z: u8, w: u8) u32 {
    let mut r1 = x as u32;
    let mut r2 = y as u32;
    let mut r3 = z as u32;
    let mut r4 = w as u32;
    r1 = (r1 << 12 | r1) & 0x000F000F;
    r2 = (r2 << 12 | r2) & 0x000F000F;
    r3 = (r3 << 12 | r3) & 0x000F000F;
    r4 = (r4 << 12 | r4) & 0x000F000F;
    r1 = (r1 << 6 | r1) & 0x03030303;
    r2 = (r2 << 6 | r2) & 0x03030303;
    r3 = (r3 << 6 | r3) & 0x03030303;
    r4 = (r4 << 6 | r4) & 0x03030303;
    r1 = (r1 << 3 | r1) & 0x11111111;
    r2 = (r2 << 3 | r2) & 0x11111111;
    r3 = (r3 << 3 | r3) & 0x11111111;
    r4 = (r4 << 3 | r4) & 0x11111111;
    return r1 | r2 << 1 | r3 << 2 | r4 << 3;
}

/// `bitfield_interleave_u8x4` of the components of `v`.
pub const fn bitfield_interleave_u8vec4(v: Vec<u8, 4>) u32 {
    return bitfield_interleave_u8x4(v.e[0], v.e[1], v.e[2], v.e[3]);
}

/// `x`, `y`, `z`, `w` in bits 4k .. 4k + 3.
pub const fn bitfield_interleave_i16x4(x: i16, y: i16, z: i16, w: i16) i64 {
    return bitfield_interleave_u16x4(x as u16, y as u16, z as u16, w as u16) as i64;
}

/// `x`, `y`, `z`, `w` in bits 4k .. 4k + 3.
pub const fn bitfield_interleave_u16x4(x: u16, y: u16, z: u16, w: u16) u64 {
    let mut r1 = x as u64;
    let mut r2 = y as u64;
    let mut r3 = z as u64;
    let mut r4 = w as u64;
    r1 = (r1 << 24 | r1) & 0x000000FF000000FF;
    r2 = (r2 << 24 | r2) & 0x000000FF000000FF;
    r3 = (r3 << 24 | r3) & 0x000000FF000000FF;
    r4 = (r4 << 24 | r4) & 0x000000FF000000FF;
    r1 = (r1 << 12 | r1) & 0x000F000F000F000F;
    r2 = (r2 << 12 | r2) & 0x000F000F000F000F;
    r3 = (r3 << 12 | r3) & 0x000F000F000F000F;
    r4 = (r4 << 12 | r4) & 0x000F000F000F000F;
    r1 = (r1 << 6 | r1) & 0x0303030303030303;
    r2 = (r2 << 6 | r2) & 0x0303030303030303;
    r3 = (r3 << 6 | r3) & 0x0303030303030303;
    r4 = (r4 << 6 | r4) & 0x0303030303030303;
    r1 = (r1 << 3 | r1) & 0x1111111111111111;
    r2 = (r2 << 3 | r2) & 0x1111111111111111;
    r3 = (r3 << 3 | r3) & 0x1111111111111111;
    r4 = (r4 << 3 | r4) & 0x1111111111111111;
    return r1 | r2 << 1 | r3 << 2 | r4 << 3;
}

/// `bitfield_interleave_u16x4` of the components of `v`.
pub const fn bitfield_interleave_u16vec4(v: Vec<u16, 4>) u64 {
    return bitfield_interleave_u16x4(v.e[0], v.e[1], v.e[2], v.e[3]);
}

/// The inverse of `bitfield_interleave_u8x2`.
pub const fn bitfield_deinterleave_u16(x: u16) Vec<u8, 2> {
    let mut r1 = x;
    let mut r2 = x >> 1;
    r1 = r1 & 0x5555;
    r2 = r2 & 0x5555;
    r1 = (r1 >> 1 | r1) & 0x3333;
    r2 = (r2 >> 1 | r2) & 0x3333;
    r1 = (r1 >> 2 | r1) & 0x0F0F;
    r2 = (r2 >> 2 | r2) & 0x0F0F;
    r1 = (r1 >> 4 | r1) & 0x00FF;
    r2 = (r2 >> 4 | r2) & 0x00FF;
    return Vec::<u8, 2> { e: [r1 as u8, r2 as u8] };
}

/// The inverse of `bitfield_interleave_u16x2`.
pub const fn bitfield_deinterleave_u32(x: u32) Vec<u16, 2> {
    let mut r1 = x;
    let mut r2 = x >> 1;
    r1 = r1 & 0x55555555;
    r2 = r2 & 0x55555555;
    r1 = (r1 >> 1 | r1) & 0x33333333;
    r2 = (r2 >> 1 | r2) & 0x33333333;
    r1 = (r1 >> 2 | r1) & 0x0F0F0F0F;
    r2 = (r2 >> 2 | r2) & 0x0F0F0F0F;
    r1 = (r1 >> 4 | r1) & 0x00FF00FF;
    r2 = (r2 >> 4 | r2) & 0x00FF00FF;
    r1 = (r1 >> 8 | r1) & 0x0000FFFF;
    r2 = (r2 >> 8 | r2) & 0x0000FFFF;
    return Vec::<u16, 2> { e: [r1 as u16, r2 as u16] };
}

/// The inverse of `bitfield_interleave_u32x2`.
pub const fn bitfield_deinterleave_u64(x: u64) Vec<u32, 2> {
    let mut r1 = x;
    let mut r2 = x >> 1;
    r1 = r1 & 0x5555555555555555;
    r2 = r2 & 0x5555555555555555;
    r1 = (r1 >> 1 | r1) & 0x3333333333333333;
    r2 = (r2 >> 1 | r2) & 0x3333333333333333;
    r1 = (r1 >> 2 | r1) & 0x0F0F0F0F0F0F0F0F;
    r2 = (r2 >> 2 | r2) & 0x0F0F0F0F0F0F0F0F;
    r1 = (r1 >> 4 | r1) & 0x00FF00FF00FF00FF;
    r2 = (r2 >> 4 | r2) & 0x00FF00FF00FF00FF;
    r1 = (r1 >> 8 | r1) & 0x0000FFFF0000FFFF;
    r2 = (r2 >> 8 | r2) & 0x0000FFFF0000FFFF;
    r1 = (r1 >> 16 | r1) & 0x00000000FFFFFFFF;
    r2 = (r2 >> 16 | r2) & 0x00000000FFFFFFFF;
    return Vec::<u32, 2> { e: [r1 as u32, r2 as u32] };
}

// The low `bits` bits set, computed in `i32`: `bits` >= 32 gives all ones and `bits` = 31 gives
// 0x7FFFFFFF, with no overflow trap.
const fn int_mask(bits: i32) i32 {
    if bits >= 32 {
        return -1;
    }
    return (1i32 << bits).wrapping_sub(1);
}

// The low `bits` bits set; all ones from the bit width on. Built in u64, so the mask of all but the
// sign bit, `(1 << (width - 1)) - 1`, does not overflow.
fn type_mask<T: Int>(bits: T) T {
    if bits.greater_equal(T::from_i64(T::bits())) {
        return ~T::zero();
    }
    return T::from_u64((1u64 << bits.to_u64()) - 1);
}

fn reverse_step<T: Int>(v: T, mask: T, shift: i64) T {
    let s = T::from_i64(shift);
    return (v & mask) << s | (v & ~mask) >> s;
}

// The trailing and leading zero counts give the indexes of the lowest and highest one bit for every
// input, negative ones included, and compile to single instructions.
fn lsb<T: Int>(x: T) i32 {
    if x.equal(T::zero()) {
        return -1;
    }
    return x.trailing_zeros();
}

fn msb<T: Int>(x: T) i32 {
    return T::bits() - 1 - x.leading_zeros();
}

// A signed minimum stays the minimum for 8 and 16 bits (the negation wraps) and traps for 32 and 64
// bits in a profile with overflow checks.
fn int_abs<T: Int>(x: T) T {
    if x.greater_equal(T::zero()) {
        return x;
    }
    return -x;
}

// The scalar form of `is_power_of_two`: `abs(v) & (abs(v) - 1)` in i64 for 8- and 16-bit types.
fn is_pow2<T: Int>(v: T) bool {
    let a = int_abs(v);
    if T::bits() < 32 {
        let w = a.to_i64();
        return (w & w - 1) == 0;
    }
    return (a & a - T::one()).equal(T::zero());
}

// The bits below the highest one of `abs(v) - 1` filled, plus one, times `sign(v)` for a signed type.
fn ceil_pow2<T: Int>(x: T) T {
    let mut v = x;
    if T::is_signed() {
        v = int_abs(x);
    }
    v = v - T::one();
    v = v | v >> T::one();
    v = v | v >> T::from_i64(2);
    v = v | v >> T::from_i64(4);
    if T::bits() >= 16 {
        v = v | v >> T::from_i64(8);
    }
    if T::bits() >= 32 {
        v = v | v >> T::from_i64(16);
    }
    if T::bits() >= 64 {
        v = v | v >> T::from_i64(32);
    }
    if T::is_signed() {
        let sign = T::from_i64(T::zero().less(x) as i64 - x.less(T::zero()) as i64);
        return (v + T::one()) * sign;
    }
    return v + T::one();
}

fn floor_pow2<T: Int>(v: T) T {
    if is_pow2(v) {
        return v;
    }
    return T::one() << T::from_i64(msb(v));
}

fn round_pow2<T: Int>(v: T) T {
    if is_pow2(v) {
        return v;
    }
    let prev = T::one() << T::from_i64(msb(v));
    let next = prev << T::one();
    let nearer_next = if T::bits() < 32 {
        next.to_i64() - v.to_i64() < v.to_i64() - prev.to_i64();
    } else {
        (next - v).less(v - prev);
    };
    if nearer_next {
        return next;
    }
    return prev;
}

// `-source % multiple` is computed in i64 for 8- and 16-bit types, so the negation of a minimum does
// not wrap.
fn int_ceil_multiple<T: Int>(source: T, multiple: T) T {
    if T::is_signed() {
        if !multiple.greater(T::zero()) {
            panic("next_multiple, ceil_multiple: a signed multiple must be positive");
        }
        if !source.greater(T::zero()) {
            if T::bits() < 32 {
                return T::from_i64(source.to_i64() + -source.to_i64() % multiple.to_i64());
            }
            return source + -source % multiple;
        }
    }
    let tmp = source - T::one();
    return tmp + (multiple - tmp % multiple);
}

fn int_floor_multiple<T: Int>(source: T, multiple: T) T {
    if source.greater_equal(T::zero()) {
        return source - source % multiple;
    }
    let tmp = source + T::one();
    return tmp - tmp % multiple - multiple;
}

fn float_ceil_multiple<T: Float>(source: T, multiple: T) T {
    if source.greater(T::zero()) {
        return source + (multiple - source.fmod(multiple));
    }
    return source + (-source).fmod(multiple);
}

fn float_floor_multiple<T: Float>(source: T, multiple: T) T {
    if source.greater_equal(T::zero()) {
        return source - source.fmod(multiple);
    }
    return source - source.fmod(multiple) - multiple;
}

fn float_round_multiple<T: Float>(source: T, multiple: T) T {
    if source.greater_equal(T::zero()) {
        return source - source.fmod(multiple);
    }
    let tmp = source + T::one();
    return tmp - tmp.fmod(multiple) - multiple;
}

// The loop ends: `key` < 2^(2 * step) holds at each test and `step` halves.
fn nsb<T: Int>(x: T, significant_bit_count: i32) i32 {
    if x.count_ones() < significant_bit_count {
        return -1;
    }
    let one = T::one();
    let mut bit_pos = 0;
    let mut key = x;
    let mut n = significant_bit_count;
    let mut step = T::bits() / 2;
    while key.greater(one) {
        let mask = (one << T::from_i64(step)) - one;
        let current = key & mask;
        let current_count = current.count_ones();
        if n > current_count {
            n -= current_count;
            bit_pos += step;
            key = key >> T::from_i64(step);
        } else {
            key = key & mask;
        }
        step = step >> 1;
    }
    return bit_pos;
}
