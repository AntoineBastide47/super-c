// std::math::random: the PCG32 reference output and streams, ranges, extremes and sums of the draws over
// a seeded `Pcg32`, the exact linear_rand formulas, gauss_rand's moments, the per-sample bounds of the
// circle, sphere, disk and ball draws, and the panics (full integer range, bad radius, endless rejection).
import std::math::scalar as *;
import std::math::vec as *;
import std::math::common as *;
import std::math::compare as *;
import std::math::geometric as *;
import std::math::random as *;

const SAMPLES: i32 = 10000;

// A generator that repeats the words it was given.
struct Words {
    pub w: [u32; 4],
    pub n: usize,
}

extend Words as Rng {
    pub fn next_u32(self: &mut Words) u32 {
        let v = unsafe self.w[self.n % 4];
        self.n += 1;
        return v;
    }
}

@test
fn pcg32_reference_output() {
    let mut g = Pcg32::new(42, 54);
    let want: [u32; 6] = [0xa15c02b7, 0x7b47f409, 0xba1d3330, 0x83d2f293, 0xbfa4784b, 0xcbed606e];
    for w in want {
        assert_eq(g.next_u32(), w);
    }
}

@test
fn pcg32_streams() {
    let mut a = Pcg32::new(7, 1);
    let mut b = Pcg32::new(7, 1);
    let mut c = Pcg32::new(7, 2);
    let mut same = 0;
    for _ in 0..64 {
        let x = a.next_u32();
        assert_eq(x, b.next_u32());
        if x == c.next_u32() {
            same += 1;
        }
    }
    assert(same < 2);
}

// Every sample in [16, 32], and both ends reached.
fn check_int_range<T: LinearRand + Int>(g: &mut Pcg32) {
    let lo = Vec::<T, 2>::splat(T::from_i64(16));
    let hi = Vec::<T, 2>::splat(T::from_i64(32));
    let mut amin = Vec::<T, 2>::splat(T::max_value());
    let mut amax = Vec::<T, 2>::splat(T::min_value());
    for _ in 0..SAMPLES {
        let a = linear_rand(g, lo, hi);
        amin = min(amin, a);
        amax = max(amax, a);
        assert(all(less_than_equal(a, hi)));
        assert(all(greater_than_equal(a, lo)));
    }
    assert(amin == lo);
    assert(amax == hi);
}

@test
fn linear_rand_int() {
    let mut g = Pcg32::new(1, 1);
    check_int_range::<u8>(&mut g);
    check_int_range::<u16>(&mut g);
    check_int_range::<u32>(&mut g);
    check_int_range::<u64>(&mut g);
    check_int_range::<i8>(&mut g);
    check_int_range::<i16>(&mut g);
    check_int_range::<i32>(&mut g);
    check_int_range::<i64>(&mut g);
}

@test
fn linear_rand_float() {
    let mut g = Pcg32::new(2, 1);
    for _ in 0..SAMPLES {
        let a = linear_rand(&mut g, f32vec2::splat(16.0), f32vec2::splat(32.0));
        assert(all(less_than_equal(a, f32vec2::splat(32.0))));
        assert(all(greater_than_equal(a, f32vec2::splat(16.0))));
        let b = linear_rand(&mut g, f64vec2::splat(16.0), f64vec2::splat(32.0));
        assert(all(less_than_equal(b, f64vec2::splat(32.0))));
        assert(all(greater_than_equal(b, f64vec2::splat(16.0))));
    }
    let mut sum_f = 0.0f32;
    let mut sum_d = 0.0f64;
    for _ in 0..SAMPLES {
        sum_f += linear_rand(&mut g, -1.0f32, 1.0f32);
        sum_d += linear_rand(&mut g, -1.0f64, 1.0f64);
    }
    // A sum within 0.0001 of 0 is an error, and so is a mean far from 0 (5 sigma).
    assert(!epsilon_equal(sum_f, 0.0f32, 0.0001f32));
    assert(!epsilon_equal(sum_d, 0.0f64, 0.0001f64));
    assert((sum_f / SAMPLES as f32).abs() < 0.03);
    assert((sum_d / SAMPLES as f64).abs() < 0.03);
}

@test
fn circular_rand_lengths() {
    let mut g = Pcg32::new(3, 1);
    let mut sum_f = 0.0f32;
    let mut sum_d = 0.0f64;
    for _ in 0..SAMPLES {
        sum_f += length(circular_rand(&mut g, 1.0f32));
        sum_d += length(circular_rand(&mut g, 2.0f64));
    }
    assert(epsilon_equal(sum_f, SAMPLES as f32, 0.01f32));
    assert(epsilon_equal(sum_d, SAMPLES as f64 * 2.0, 0.01f64));
}

@test
fn spherical_rand_lengths() {
    let mut g = Pcg32::new(4, 1);
    let mut fa = 0.0f32;
    let mut fb = 0.0f32;
    let mut fc = 0.0f32;
    let mut da = 0.0f64;
    let mut db = 0.0f64;
    let mut dc = 0.0f64;
    for _ in 0..SAMPLES {
        fa += length(spherical_rand(&mut g, 1.0f32));
        da += length(spherical_rand(&mut g, 1.0f64));
        fb += length(spherical_rand(&mut g, 2.0f32));
        db += length(spherical_rand(&mut g, 2.0f64));
        fc += length(spherical_rand(&mut g, 3.0f32));
        dc += length(spherical_rand(&mut g, 3.0f64));
    }
    let n = SAMPLES as f64;
    assert(epsilon_equal(fa, n as f32, 0.01f32));
    assert(epsilon_equal(da, n, 0.0001f64));
    assert(epsilon_equal(fb, (n * 2.0) as f32, 0.01f32));
    assert(epsilon_equal(db, n * 2.0, 0.0001f64));
    assert(epsilon_equal(fc, (n * 3.0) as f32, 0.01f32));
    assert(epsilon_equal(dc, n * 3.0, 0.01f64));
}

@test
fn disk_and_ball_rand() {
    let mut g = Pcg32::new(5, 1);
    let mut disk_f = 0.0f32;
    let mut disk_d = 0.0f64;
    let mut ball_f = 0.0f32;
    let mut ball_d = 0.0f64;
    for _ in 0..SAMPLES {
        let a = length(disk_rand(&mut g, 2.0f32));
        let b = length(disk_rand(&mut g, 2.0f64));
        let c = length(ball_rand(&mut g, 2.0f32));
        let d = length(ball_rand(&mut g, 2.0f64));
        assert(a <= 2.0 && b <= 2.0 && c <= 2.0 && d <= 2.0);
        disk_f += a;
        disk_d += b;
        ball_f += c;
        ball_d += d;
    }
    assert(disk_f < SAMPLES as f32 * 2.0);
    assert(disk_d < SAMPLES as f64 * 2.0);
    assert(ball_f < SAMPLES as f32 * 2.0);
    assert(ball_d < SAMPLES as f64 * 2.0);
    // The mean distance from the center is 2/3 of the radius in a disk and 3/4 in a ball.
    assert((disk_d / SAMPLES as f64 - 4.0 / 3.0).abs() < 0.02);
    assert((ball_d / SAMPLES as f64 - 1.5).abs() < 0.02);
}

@test
fn gauss_rand_moments() {
    let mut g = Pcg32::new(6, 1);
    let mut sum = 0.0f64;
    let mut sq = 0.0f64;
    for _ in 0..SAMPLES {
        let v = gauss_rand(&mut g, dvec2::new(5.0, -1.0), dvec2::new(2.0, 0.5));
        sum += v.x();
        sq += v.x() * v.x();
        assert(v.y().abs() < 3.0);
    }
    let n = SAMPLES as f64;
    let mean = sum / n;
    // The scale is the deviation squared: a deviation of 2 gives a standard deviation of 4.
    let sd = (sq / n - mean * mean).sqrt();
    assert((mean - 5.0).abs() < 0.2);
    assert((sd - 4.0).abs() < 0.2);
    let s = gauss_rand(&mut g, 1.0f32, 1.0f32);
    assert(s.abs() < 10.0);
}

@test
fn linear_rand_formulas() {
    let mut w = Words { w: [0x80000000, 0x00000001, 0xFFFFFFFF, 0x12345678], n: 0 };
    assert_eq(linear_rand(&mut w, -1.0f32, 1.0f32), 0.0f32);
    assert_eq(linear_rand(&mut w, 0.0f32, 1.0f32), 1.0f32 / 4294967296.0f32);
    assert_eq(linear_rand(&mut w, 3.0f32, 5.0f32), 5.0f32);
    assert_eq(linear_rand(&mut w, 0.0f32, 1.0f32), 0x12345678u32 as f32 / 4294967296.0f32);
    w.n = 0;
    let d = linear_rand(&mut w, 0.0f64, 1.0f64);
    assert_eq(d, 0x8000000000000001u64 as f64 / 18446744073709551615u64 as f64);
    w.n = 0;
    assert_eq(linear_rand(&mut w, 0u64, 1000000u64), 0x8000000000000001u64 % 1000001);
    w.n = 3;
    assert_eq(linear_rand(&mut w, -100i8, 100i8), (0x78u64 % 201) as i8 - 100);
    assert_eq(linear_rand(&mut w, -128i8, 0i8), i8::MIN + (0x00u64 % 129) as i8);
    assert_eq(linear_rand(&mut w, 10u16, 20u16), 0x0001u16 % 11 + 10);
    let v = linear_rand(&mut w, ivec3::splat(-5), ivec3::new(5, 6, 7));
    assert(
        v == ivec3::new(
            -5 + (0xFFFFFFFFu32 % 11) as i32,
            -5 + (0x12345678u32 % 12) as i32,
            -5 + (0x80000000u32 % 13) as i32,
        ),
    );
}

@test
fn full_unsigned_range_minus_one() {
    let mut g = Pcg32::new(8, 1);
    let mut top = false;
    for _ in 0..4096 {
        let v = linear_rand(&mut g, 0u8, 254u8);
        if v == 254 {
            top = true;
        }
    }
    assert(top);
}

@test(should_panic)
fn full_integer_range_panics() {
    let mut g = Pcg32::new(9, 1);
    linear_rand(&mut g, 0u8, 255u8);
}

@test(should_panic)
fn zero_radius_panics() {
    let mut g = Pcg32::new(10, 1);
    disk_rand(&mut g, 0.0f32);
}

@test(should_panic)
fn nan_radius_panics() {
    let mut g = Pcg32::new(11, 1);
    spherical_rand(&mut g, f64::nan());
}

@test(should_panic)
fn endless_rejection_panics() {
    let mut w = Words { w: [0xFFFFFFFF; 4], n: 0 };
    gauss_rand(&mut w, 0.0f32, 1.0f32);
}

@test(should_panic)
fn endless_ball_rejection_panics() {
    let mut w = Words { w: [0xFFFFFFFF; 4], n: 0 };
    ball_rand(&mut w, 1.0f64);
}

const SEEDED: Pcg32 = Pcg32::new(42, 54);

@test
fn constant_initializer() {
    let mut g = SEEDED;
    assert_eq(g.next_u32(), 0xa15c02b7u32);
    assert_eq(g.next_u32(), 0x7b47f409u32);
}
