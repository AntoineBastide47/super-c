// Random distributions over an explicit generator: each function takes `rng: &mut R` with `R: Rng`, so a
// seed reproduces the same values on every platform. `Pcg32` is a small deterministic `Rng`. Each
// rejection loop stops after `MAX_TRIES` rejections with a panic.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::geometric as *;

/// A source of uniform random `u32` values.
pub interface Rng {
    fn next_u32(self: &mut Self) u32;
}

/// PCG32 (O'Neill's pcg32, XSH-RR output): 64-bit state, period 2^64, one of 2^63 streams.
pub struct Pcg32 {
    state: u64,
    inc: u64,
}

extend Pcg32 {
    /// The generator of `seed` on stream `stream` (`pcg32_srandom_r`): seed 42, stream 54 gives
    /// 0xa15c02b7, 0x7b47f409, 0xba1d3330, .. as the reference implementation.
    pub const fn new(seed: u64, stream: u64) Pcg32 {
        let mut r = Pcg32 { state: 0, inc: stream << 1 | 1 };
        r.next_u32();
        r.state = r.state.wrapping_add(seed);
        r.next_u32();
        return r;
    }
}

extend Pcg32 as Rng {
    pub fn next_u32(self: &mut Pcg32) u32 {
        let old = self.state;
        self.state = old.wrapping_mul(6364136223846793005).wrapping_add(self.inc);
        let xorshifted = ((old >> 18 ^ old) >> 27) as u32;
        let rot = (old >> 59) as u32;
        return xorshifted >> rot | xorshifted << (rot.wrapping_neg() & 31);
    }
}

/// The rejections `gauss_rand`, `disk_rand` and `ball_rand` allow before they panic. A rejection has
/// probability 1 - pi/4 (gauss, disk) or 1 - pi/6 (ball) with a uniform generator, so the panic has
/// probability below 3e-86 or 7e-42 per call.
pub const MAX_TRIES: i32 = 128;

/// A component type of `linear_rand`: every `Int` and `Float`.
pub interface LinearRand: Scalar {
    /// A uniform value in [lo, hi].
    fn linear_rand_of<R: Rng>(rng: &mut R, lo: Self, hi: Self) Self;
}

// An integer is `rand % (hi + 1 - lo) + lo` at the width of `T`, with the remainder taken unsigned. A
// width up to 32 bits takes the low bits of one `next_u32`; 64 bits take two, as `(first << 32) | second`.
extend<T: Int> T as LinearRand {
    pub fn linear_rand_of<R: Rng>(rng: &mut R, lo: T, hi: T) T {
        let bits = T::bits();
        let mask = if bits == 64 {
            u64::MAX;
        } else {
            (1u64 << bits as u64) - 1;
        };
        let first = rng.next_u32() as u64;
        let word = if bits == 64 {
            first << 32 | rng.next_u32() as u64;
        } else {
            first & mask;
        };
        let range = (hi + T::one() - lo).to_u64() & mask;
        return T::from_u64(word % range) + lo;
    }
}

// An f32 is `f32(rand_u32) / f32(u32::MAX) * (hi - lo) + lo`, with `next_u32` as
// the random `u32`.
extend f32 as LinearRand {
    pub fn linear_rand_of<R: Rng>(rng: &mut R, lo: f32, hi: f32) f32 {
        return rng.next_u32() as f32 / u32::MAX as f32 * (hi - lo) + lo;
    }
}

// An f64 is `f64(rand_u64) / f64(u64::MAX) * (hi - lo) + lo`, the random `u64`
// built as `(first << 32) | second` from two `next_u32`.
extend f64 as LinearRand {
    pub fn linear_rand_of<R: Rng>(rng: &mut R, lo: f64, hi: f64) f64 {
        let first = rng.next_u32() as u64;
        let word = first << 32 | rng.next_u32() as u64;
        return word as f64 / u64::MAX as f64 * (hi - lo) + lo;
    }
}

/// Each component uniform in [min, max], drawn in component order. A float is `next_u32() / u32::MAX`
/// (f32) or a 64-bit word over `u64::MAX` (f64) scaled into the range; an integer is a random word modulo
/// `max + 1 - min` (wrapped to the width), plus `min`. Panics: an integer range that covers its whole type
/// (division by zero), and in a profile with overflow checks an `i32` or `i64` `max + 1 - min` that
/// overflows.
pub fn linear_rand<T: LinearRand, G: Gen<T>, R: Rng>(rng: &mut R, min: G, max: G) G {
    let mut r = min;
    for i in 0..G::len() {
        r.put(i, T::linear_rand_of(rng, min.at(i), max.at(i)));
    }
    return r;
}

/// Each component from the polar Box-Muller method: `x2 * deviation * deviation * sqrt(-2 ln(w) / w) +
/// mean`. The scale is the deviation squared, so the standard deviation is `deviation * deviation`.
/// Panics: `MAX_TRIES` rejected pairs in a row.
pub fn gauss_rand<T: Float + LinearRand, G: Gen<T>, R: Rng>(rng: &mut R, mean: G, deviation: G) G {
    let mut r = mean;
    for i in 0..G::len() {
        r.put(i, gauss_of(rng, mean.at(i), deviation.at(i)));
    }
    return r;
}

// One component of `gauss_rand`.
fn gauss_of<T: Float + LinearRand, R: Rng>(rng: &mut R, mean: T, deviation: T) T {
    for _ in 0..MAX_TRIES {
        let x1 = T::linear_rand_of(rng, -T::one(), T::one());
        let x2 = T::linear_rand_of(rng, -T::one(), T::one());
        let w = x1 * x1 + x2 * x2;
        if !w.greater(T::one()) {
            return x2 * deviation * deviation * (T::from_i64(-2) * w.ln() / w).sqrt() + mean;
        }
    }
    panic("gauss_rand: the generator gave MAX_TRIES rejected samples in a row");
}

/// A uniform point on the circle of `radius`, `(cos a, sin a) * radius` with `a` uniform in [0, 2 pi].
/// Panics: `radius <= 0` or NaN.
pub fn circular_rand<T: Float + LinearRand, R: Rng>(rng: &mut R, radius: T) Vec<T, 2> {
    check_radius(radius);
    let a = T::linear_rand_of(rng, T::zero(), T::from_f64(6.283185307179586476925286766559));
    return Vec::<T, 2>::new(a.cos(), a.sin()) * radius;
}

/// A uniform point on the sphere of `radius`, from `theta` uniform in [0, 2 pi] and `phi = acos(u)` with
/// `u` uniform in [-1, 1]. Panics: `radius <= 0` or NaN.
pub fn spherical_rand<T: Float + LinearRand, R: Rng>(rng: &mut R, radius: T) Vec<T, 3> {
    check_radius(radius);
    let theta = T::linear_rand_of(rng, T::zero(), T::from_f32(6.283185307179586476925286766559));
    let phi = T::linear_rand_of(rng, T::from_f32(-1.0), T::from_f32(1.0)).acos();
    let x = phi.sin() * theta.cos();
    let y = phi.sin() * theta.sin();
    let z = phi.cos();
    return Vec::<T, 3>::new(x, y, z) * radius;
}

/// A uniform point in the disk of `radius`, drawn in the square [-radius, radius]^2 until
/// `length <= radius`. Panics: `radius <= 0` or NaN, or `MAX_TRIES` rejections in a row.
pub fn disk_rand<T: Float + LinearRand, R: Rng>(rng: &mut R, radius: T) Vec<T, 2> {
    check_radius(radius);
    for _ in 0..MAX_TRIES {
        let r = linear_rand(rng, Vec::<T, 2>::splat(-radius), Vec::<T, 2>::splat(radius));
        if !length(r).greater(radius) {
            return r;
        }
    }
    panic("disk_rand: the generator gave MAX_TRIES rejected samples in a row");
}

/// A uniform point in the ball of `radius`, drawn in the cube [-radius, radius]^3 until
/// `length <= radius`. Panics: `radius <= 0` or NaN, or `MAX_TRIES` rejections in a row.
pub fn ball_rand<T: Float + LinearRand, R: Rng>(rng: &mut R, radius: T) Vec<T, 3> {
    check_radius(radius);
    for _ in 0..MAX_TRIES {
        let r = linear_rand(rng, Vec::<T, 3>::splat(-radius), Vec::<T, 3>::splat(radius));
        if !length(r).greater(radius) {
            return r;
        }
    }
    panic("ball_rand: the generator gave MAX_TRIES rejected samples in a row");
}

fn check_radius<T: Float>(radius: T) {
    if !radius.greater(T::zero()) {
        panic("std::math::random: the radius must be greater than 0");
    }
}
