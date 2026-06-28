// Small numeric and ordering helpers shared by user code without importing C headers.

pub fn min<T: Ord>(a: T, b: T) T {
    if a.cmp(&b) <= 0 {
        return a;
    }
    return b;
}

pub fn max<T: Ord>(a: T, b: T) T {
    if a.cmp(&b) >= 0 {
        return a;
    }
    return b;
}

pub fn clamp<T: Ord>(value: T, lo: T, hi: T) T {
    if value.cmp(&lo) < 0 {
        return lo;
    }
    if value.cmp(&hi) > 0 {
        return hi;
    }
    return value;
}

pub fn abs_i32(n: i32) i32 {
    if n < 0 {
        return 0 - n;
    }
    return n;
}

pub fn abs_i64(n: i64) i64 {
    if n < 0 {
        return 0 - n;
    }
    return n;
}
