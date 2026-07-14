// Small numeric and ordering helpers shared by user code without importing C headers.

pub const fn min<T: Ord>(a: T, b: T) T {
    if a <= b {
        return a;
    }
    return b;
}

pub const fn max<T: Ord>(a: T, b: T) T {
    if a >= b {
        return a;
    }
    return b;
}

pub const fn clamp<T: Ord>(value: T, lo: T, hi: T) T {
    if value < lo {
        return lo;
    }
    if value > hi {
        return hi;
    }
    return value;
}

pub const fn abs_i32(n: i32) i32 {
    if n < 0 {
        return (0 - n as u32) as i32; // unsigned negate avoids signed overflow at i32::MIN (UB)
    }
    return n;
}

pub const fn abs_i64(n: i64) i64 {
    if n < 0 {
        return (0 - n as u64) as i64; // unsigned negate avoids signed overflow at i64::MIN (UB)
    }
    return n;
}
