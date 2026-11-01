// Range<T>: the value a `lo..hi` (or inclusive `lo..=hi`) expression lowers to when used as a value
// rather than a `for` iterable, `switch` pattern, or `a[lo..hi]` slice (those are handled structurally
// and never build a Range). Plain data: bind it, pass it around, and `for x in r` counts start..end.
//
// Over a builtin integer type a Range is also a double-ended iterator with an exact `size_hint`, so it
// feeds the adapters of `std/iter.spc` (`rev(0..n)`, `step_by(0..n, 3)`, `zip(0..n, v.iter())`). Each step
// is O(1) and never overflows: an inclusive range up to `T::MAX` ends by clearing `inclusive` when it
// yields its last value, so `start` never steps past `end`. Iterating mutates the Range itself (`start`,
// `end`, `inclusive`); copy it first to keep the bounds. A range with `start > end` is empty.

/// The value of `a..b` / `a..=b`.
pub struct Range<T> {
    pub start: T, // first value (inclusive)
    pub end: T, // last value: excluded for `..`, included for `..=`
    pub inclusive: bool,
}

// The integer steps a Range iterates by. Private to this file, so only the builtin integers below
// implement it. `up` and `down` run only strictly between the bounds, so they never overflow.
interface Step: Copy + Ord {
    fn up(self: Self) Self;
    fn down(self: Self) Self;
    fn bits(self: Self) u64; // sign-extended, so `hi - lo` wraps to the exact distance
    fn plus(self: Self, n: usize) Self; // `n` steps up, at most to the range's end
}

// The number of steps from `lo` to `hi` (`lo <= hi`), or None when it does not fit `usize`.
fn step_count<T: Step>(lo: T, hi: T) Option<usize> {
    let d = hi.bits().wrapping_sub(lo.bits());
    if d > usize::MAX as u64 {
        return None;
    }
    return Some(d as usize);
}

extend<T: Step> Range<T> as Iterator<T> {
    pub fn next(self: &mut Range<T>) Option<T> {
        let v = self.start;
        if v < self.end {
            self.start = v.up();
            return Some(v);
        }
        if self.inclusive && v == self.end {
            self.inclusive = false;
            return Some(v);
        }
        return None;
    }

    /// Exact, except `(usize::MAX, None)` when the count exceeds `usize::MAX`.
    pub fn size_hint(self: &Range<T>) (usize, Option<usize>) {
        if self.start < self.end {
            if let Some(n) = step_count(self.start, self.end) {
                if !self.inclusive {
                    return (n, Option::<usize>::Some(n));
                }
                if n < usize::MAX {
                    return (n + 1, Option::<usize>::Some(n + 1));
                }
            }
            return (usize::MAX, Option::<usize>::None);
        }
        if self.inclusive && self.start == self.end {
            return (1, Option::<usize>::Some(1));
        }
        return (0, Option::<usize>::Some(0));
    }

    /// The start moves `n` steps at once.
    pub fn advance_by(self: &mut Range<T>, n: usize) bool {
        if self.start < self.end {
            // The values before the end, and the end itself for `..=`.
            let d = self.end.bits().wrapping_sub(self.start.bits());
            if n as u64 <= d {
                self.start = self.start.plus(n);
                return true;
            }
            let all = self.inclusive && n as u64 == d + 1;
            self.start = self.end;
            self.inclusive = false;
            return all;
        }
        if n == 0 {
            return true;
        }
        let one = self.inclusive && self.start == self.end && n == 1;
        self.inclusive = false;
        return one;
    }
}

extend<T: Step> Range<T> as DoubleEndedIterator<T> {
    pub fn next_back(self: &mut Range<T>) Option<T> {
        let v = self.end;
        if self.start < v {
            let w = v.down();
            self.end = w;
            if self.inclusive {
                return Some(v);
            }
            return Some(w);
        }
        if self.inclusive && self.start == v {
            self.inclusive = false;
            return Some(v);
        }
        return None;
    }
}

extend i8 as Step {
    @always_inline
    fn up(self: i8) i8 {
        return self + 1;
    }
    @always_inline
    fn down(self: i8) i8 {
        return self - 1;
    }
    @always_inline
    fn bits(self: i8) u64 {
        return self as u64;
    }
    @always_inline
    fn plus(self: i8, n: usize) i8 {
        return self.bits().wrapping_add(n as u64) as i8;
    }
}

extend i16 as Step {
    @always_inline
    fn up(self: i16) i16 {
        return self + 1;
    }
    @always_inline
    fn down(self: i16) i16 {
        return self - 1;
    }
    @always_inline
    fn bits(self: i16) u64 {
        return self as u64;
    }
    @always_inline
    fn plus(self: i16, n: usize) i16 {
        return self.bits().wrapping_add(n as u64) as i16;
    }
}

extend i32 as Step {
    @always_inline
    fn up(self: i32) i32 {
        return self + 1;
    }
    @always_inline
    fn down(self: i32) i32 {
        return self - 1;
    }
    @always_inline
    fn bits(self: i32) u64 {
        return self as u64;
    }
    @always_inline
    fn plus(self: i32, n: usize) i32 {
        return self.bits().wrapping_add(n as u64) as i32;
    }
}

extend i64 as Step {
    @always_inline
    fn up(self: i64) i64 {
        return self + 1;
    }
    @always_inline
    fn down(self: i64) i64 {
        return self - 1;
    }
    @always_inline
    fn bits(self: i64) u64 {
        return self as u64;
    }
    @always_inline
    fn plus(self: i64, n: usize) i64 {
        return self.bits().wrapping_add(n as u64) as i64;
    }
}

extend isize as Step {
    @always_inline
    fn up(self: isize) isize {
        return self + 1;
    }
    @always_inline
    fn down(self: isize) isize {
        return self - 1;
    }
    @always_inline
    fn bits(self: isize) u64 {
        return self as u64;
    }
    @always_inline
    fn plus(self: isize, n: usize) isize {
        return self.bits().wrapping_add(n as u64) as isize;
    }
}

extend u8 as Step {
    @always_inline
    fn up(self: u8) u8 {
        return self + 1;
    }
    @always_inline
    fn down(self: u8) u8 {
        return self - 1;
    }
    @always_inline
    fn bits(self: u8) u64 {
        return self;
    }
    @always_inline
    fn plus(self: u8, n: usize) u8 {
        return self.bits().wrapping_add(n as u64) as u8;
    }
}

extend u16 as Step {
    @always_inline
    fn up(self: u16) u16 {
        return self + 1;
    }
    @always_inline
    fn down(self: u16) u16 {
        return self - 1;
    }
    @always_inline
    fn bits(self: u16) u64 {
        return self;
    }
    @always_inline
    fn plus(self: u16, n: usize) u16 {
        return self.bits().wrapping_add(n as u64) as u16;
    }
}

extend u32 as Step {
    @always_inline
    fn up(self: u32) u32 {
        return self + 1;
    }
    @always_inline
    fn down(self: u32) u32 {
        return self - 1;
    }
    @always_inline
    fn bits(self: u32) u64 {
        return self;
    }
    @always_inline
    fn plus(self: u32, n: usize) u32 {
        return self.bits().wrapping_add(n as u64) as u32;
    }
}

extend u64 as Step {
    @always_inline
    fn up(self: u64) u64 {
        return self + 1;
    }
    @always_inline
    fn down(self: u64) u64 {
        return self - 1;
    }
    @always_inline
    fn bits(self: u64) u64 {
        return self;
    }
    @always_inline
    fn plus(self: u64, n: usize) u64 {
        return self.wrapping_add(n as u64);
    }
}

extend usize as Step {
    @always_inline
    fn up(self: usize) usize {
        return self + 1;
    }
    @always_inline
    fn down(self: usize) usize {
        return self - 1;
    }
    @always_inline
    fn bits(self: usize) u64 {
        return self as u64;
    }
    @always_inline
    fn plus(self: usize, n: usize) usize {
        return self.bits().wrapping_add(n as u64) as usize;
    }
}
