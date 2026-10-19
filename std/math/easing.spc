// Easing functions on an `f32` or `f64` in [0, 1], after Warren Moore's AHEasing. Each doc comment gives
// the formula in its operation order (`sin`, `cos`, `sqrt` and `pow` are the C library's). An input
// outside [0, 1], or a NaN, panics. The `_overshoot` forms take an explicit overshoot `o`; the back
// easings without the suffix use 1.70158.
import std::math::scalar as *;

fn assert_unit<T: Float>(a: T) {
    assert(a.greater_equal(T::zero()), "easing: the input must not be below 0");
    assert(a.less_equal(T::one()), "easing: the input must not be above 1");
}

/// `a` itself.
pub fn linear_interpolation<T: Float>(a: T) T {
    assert_unit(a);
    return a;
}

/// `a * a`.
pub fn quadratic_ease_in<T: Float>(a: T) T {
    assert_unit(a);
    return a * a;
}

/// `-(a * (a - 2))`.
pub fn quadratic_ease_out<T: Float>(a: T) T {
    assert_unit(a);
    return -(a * (a - T::from_i64(2)));
}

/// `2 a a` below 0.5, else `-2 a a + 4 a - 1`.
pub fn quadratic_ease_in_out<T: Float>(a: T) T {
    assert_unit(a);
    let twice_square = T::from_i64(2) * a * a;
    if a.less(T::from_f64(0.5)) {
        return twice_square;
    }
    // `-2 a a` is `-(2 a a)` bit for bit: the negation is exact.
    return -twice_square + T::from_i64(4) * a - T::one();
}

/// `a * a * a`.
pub fn cubic_ease_in<T: Float>(a: T) T {
    assert_unit(a);
    return a * a * a;
}

/// `f * f * f + 1` with `f = a - 1`.
pub fn cubic_ease_out<T: Float>(a: T) T {
    assert_unit(a);
    let f = a - T::one();
    return f * f * f + T::one();
}

/// `4 a a a` below 0.5, else `0.5 f f f + 1` with `f = 2 a - 2`.
pub fn cubic_ease_in_out<T: Float>(a: T) T {
    assert_unit(a);
    if a.less(T::from_f64(0.5)) {
        return T::from_i64(4) * a * a * a;
    }
    let f = T::from_i64(2) * a - T::from_i64(2);
    return T::from_f64(0.5) * f * f * f + T::one();
}

/// `a * a * a * a`.
pub fn quartic_ease_in<T: Float>(a: T) T {
    assert_unit(a);
    return a * a * a * a;
}

/// `f * f * f * (1 - a) + 1` with `f = a - 1`.
pub fn quartic_ease_out<T: Float>(a: T) T {
    assert_unit(a);
    let f = a - T::one();
    return f * f * f * (T::one() - a) + T::one();
}

/// `8 a a a a` below 0.5, else `-8 f f f f + 1` with `f = a - 1`.
pub fn quartic_ease_in_out<T: Float>(a: T) T {
    assert_unit(a);
    if a.less(T::from_f64(0.5)) {
        return T::from_i64(8) * a * a * a * a;
    }
    let f = a - T::one();
    return -T::from_i64(8) * f * f * f * f + T::one();
}

/// `a * a * a * a * a`.
pub fn quintic_ease_in<T: Float>(a: T) T {
    assert_unit(a);
    return a * a * a * a * a;
}

/// `f * f * f * f * f + 1` with `f = a - 1`.
pub fn quintic_ease_out<T: Float>(a: T) T {
    assert_unit(a);
    let f = a - T::one();
    return f * f * f * f * f + T::one();
}

/// `16 a a a a a` below 0.5, else `0.5 f f f f f + 1` with `f = 2 a - 2`.
pub fn quintic_ease_in_out<T: Float>(a: T) T {
    assert_unit(a);
    if a.less(T::from_f64(0.5)) {
        return T::from_i64(16) * a * a * a * a * a;
    }
    let f = T::from_i64(2) * a - T::from_i64(2);
    return T::from_f64(0.5) * f * f * f * f * f + T::one();
}

/// `sin((a - 1) * pi / 2) + 1`.
pub fn sine_ease_in<T: Float>(a: T) T {
    assert_unit(a);
    return ((a - T::one()) * half_pi::<T>()).sin() + T::one();
}

/// `sin(a * pi / 2)`.
pub fn sine_ease_out<T: Float>(a: T) T {
    assert_unit(a);
    return (a * half_pi::<T>()).sin();
}

/// `0.5 * (1 - cos(a * pi))`.
pub fn sine_ease_in_out<T: Float>(a: T) T {
    assert_unit(a);
    return T::from_f64(0.5) * (T::one() - (a * pi::<T>()).cos());
}

/// `1 - sqrt(1 - a * a)`.
pub fn circular_ease_in<T: Float>(a: T) T {
    assert_unit(a);
    return T::one() - (T::one() - a * a).sqrt();
}

/// `sqrt((2 - a) * a)`.
pub fn circular_ease_out<T: Float>(a: T) T {
    assert_unit(a);
    return ((T::from_i64(2) - a) * a).sqrt();
}

/// `0.5 * (1 - sqrt(1 - 4 a a))` below 0.5, else `0.5 * (sqrt(-(2 a - 3) * (2 a - 1)) + 1)`.
pub fn circular_ease_in_out<T: Float>(a: T) T {
    assert_unit(a);
    let two = T::from_i64(2);
    if a.less(T::from_f64(0.5)) {
        return T::from_f64(0.5) * (T::one() - (T::one() - T::from_i64(4) * (a * a)).sqrt());
    }
    return T::from_f64(0.5) * ((-(two * a - T::from_i64(3)) * (two * a - T::one())).sqrt() + T::one());
}

/// `a` at 0, else `pow(2, 10 (a - 1))`.
pub fn exponential_ease_in<T: Float>(a: T) T {
    assert_unit(a);
    if a.less_equal(T::zero()) {
        return a;
    }
    let complementary = a - T::one();
    return T::from_i64(2).pow(complementary * T::from_i64(10));
}

/// `a` at 1, else `1 - pow(2, -10 a)`.
pub fn exponential_ease_out<T: Float>(a: T) T {
    assert_unit(a);
    if a.greater_equal(T::one()) {
        return a;
    }
    return T::one() - T::from_i64(2).pow(-T::from_i64(10) * a);
}

/// `0.5 pow(2, 20 a - 10)` below 0.5, else `-0.5 pow(2, -20 a + 10) + 1`.
pub fn exponential_ease_in_out<T: Float>(a: T) T {
    assert_unit(a);
    let two = T::from_i64(2);
    if a.less(T::from_f64(0.5)) {
        return T::from_f64(0.5) * two.pow(T::from_i64(20) * a - T::from_i64(10));
    }
    return -T::from_f64(0.5) * two.pow(-T::from_i64(20) * a + T::from_i64(10)) + T::one();
}

/// `sin(13 pi / 2 a) * pow(2, 10 (a - 1))`.
pub fn elastic_ease_in<T: Float>(a: T) T {
    assert_unit(a);
    let wave = (T::from_i64(13) * half_pi::<T>() * a).sin();
    return wave * T::from_i64(2).pow(T::from_i64(10) * (a - T::one()));
}

/// `sin(-13 pi / 2 (a + 1)) * pow(2, -10 a) + 1`.
pub fn elastic_ease_out<T: Float>(a: T) T {
    assert_unit(a);
    let wave = (-T::from_i64(13) * half_pi::<T>() * (a + T::one())).sin();
    return wave * T::from_i64(2).pow(-T::from_i64(10) * a) + T::one();
}

/// `elastic_ease_in` and `elastic_ease_out` on each half, scaled to [0, 1].
pub fn elastic_ease_in_out<T: Float>(a: T) T {
    assert_unit(a);
    let half = T::from_f64(0.5);
    let two = T::from_i64(2);
    let thirteen_half_pi = T::from_i64(13) * half_pi::<T>();
    if a.less(half) {
        let wave = (thirteen_half_pi * (two * a)).sin();
        return half * wave * two.pow(T::from_i64(10) * (two * a - T::one()));
    }
    let wave = (-T::from_i64(13) * half_pi::<T>() * (two * a - T::one() + T::one())).sin();
    return half * (wave * two.pow(-T::from_i64(10) * (two * a - T::one())) + two);
}

/// `a * a * ((o + 1) a - o)`, which overshoots below 0 by an amount that grows with `o`.
pub fn back_ease_in_overshoot<T: Float>(a: T, o: T) T {
    assert_unit(a);
    let z = (o + T::one()) * a - o;
    return a * a * z;
}

/// `n * n * ((o + 1) n + o) + 1` with `n = a - 1`, which overshoots above 1.
pub fn back_ease_out_overshoot<T: Float>(a: T, o: T) T {
    assert_unit(a);
    let n = a - T::one();
    let z = (o + T::one()) * n + o;
    return n * n * z + T::one();
}

/// `back_ease_in_overshoot` and `back_ease_out_overshoot` on each half with the overshoot `o * 1.525`,
/// scaled to [0, 1].
pub fn back_ease_in_out_overshoot<T: Float>(a: T, o: T) T {
    assert_unit(a);
    let s = o * T::from_f64(1.525);
    let x = T::from_f64(0.5);
    let mut n = a / T::from_f64(0.5);
    if n.less(T::one()) {
        let z = (s + T::one()) * n - s;
        let m = n * n * z;
        return x * m;
    }
    n = n - T::from_i64(2);
    let z = (s + T::one()) * n + s;
    let m = n * n * z + T::from_i64(2);
    return x * m;
}

/// `back_ease_in_overshoot(a, 1.70158)`.
pub fn back_ease_in<T: Float>(a: T) T {
    return back_ease_in_overshoot(a, T::from_f64(1.70158));
}

/// `back_ease_out_overshoot(a, 1.70158)`.
pub fn back_ease_out<T: Float>(a: T) T {
    return back_ease_out_overshoot(a, T::from_f64(1.70158));
}

/// `back_ease_in_out_overshoot(a, 1.70158)`.
pub fn back_ease_in_out<T: Float>(a: T) T {
    return back_ease_in_out_overshoot(a, T::from_f64(1.70158));
}

/// Four parabolic bounces of decreasing height, the last ending at 1.
pub fn bounce_ease_out<T: Float>(a: T) T {
    assert_unit(a);
    if a.less(
        T::from_decimal(
            4.0 / 11.0,
            "0.36363636363636363636363636363636363636363636363636363636363636363636363636363636",
        ),
    ) {
        return T::from_i64(121) * a * a / T::from_i64(16);
    }
    if a.less(
        T::from_decimal(
            8.0 / 11.0,
            "0.72727272727272727272727272727272727272727272727272727272727272727272727272727273",
        ),
    ) {
        return T::from_decimal(363.0 / 40.0, "9.075") * a * a - T::from_decimal(99.0 / 10.0, "9.9") * a + T::from_decimal(
            17.0 / 5.0,
            "3.4",
        );
    }
    if a.less(T::from_decimal(9.0 / 10.0, "0.9")) {
        let quadratic = T::from_decimal(
            4356.0 / 361.0,
            "12.066481994459833795013850415512465373961218836565096952908587257617728531855956",
        ) * a * a;
        return quadratic - T::from_decimal(
            35442.0 / 1805.0,
            "19.635457063711911357340720221606648199445983379501385041551246537396121883656510",
        ) * a + T::from_decimal(
            16061.0 / 1805.0,
            "8.8980609418282548476454293628808864265927977839335180055401662049861495844875346",
        );
    }
    return T::from_decimal(54.0 / 5.0, "10.8") * a * a - T::from_decimal(513.0 / 25.0, "20.52") * a + T::from_decimal(
        268.0 / 25.0,
        "10.72",
    );
}

/// `1 - bounce_ease_out(1 - a)`.
pub fn bounce_ease_in<T: Float>(a: T) T {
    assert_unit(a);
    return T::one() - bounce_ease_out(T::one() - a);
}

/// `bounce_ease_in` and `bounce_ease_out` on each half, scaled to [0, 1].
pub fn bounce_ease_in_out<T: Float>(a: T) T {
    assert_unit(a);
    let half = T::from_f64(0.5);
    if a.less(half) {
        return half * (T::one() - bounce_ease_out(T::one() - a * T::from_i64(2)));
    }
    return half * bounce_ease_out(a * T::from_i64(2) - T::one()) + half;
}
