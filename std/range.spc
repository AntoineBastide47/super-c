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
}

// The number of steps from `lo` to `hi` (`lo <= hi`), or None when it does not fit `usize`.
fn step_count<T: Step>(lo: T, hi: T) Option<usize> {
    let d = hi.bits().wrapping_sub(lo.bits());
    if d > usize::MAX as u64 {
        return Option::<usize>::None;
    }
    return Option::<usize>::Some(d as usize);
}

extend<T: Step> Range<T> as Iterator<T> {
    pub fn next(self: &mut Range<T>) Option<T> {
        let v = self.start;
        if v < self.end {
            self.start = v.up();
            return Option::<T>::Some(v);
        }
        if self.inclusive && v == self.end {
            self.inclusive = false;
            return Option::<T>::Some(v);
        }
        return Option::<T>::None;
    }

    /// Exact, except `(usize::MAX, None)` when the count exceeds `usize::MAX`.
    pub fn size_hint(self: &Range<T>) (usize, Option<usize>) {
        if self.start < self.end {
            if let Some(n) = step_count(self.start, self.end) {
                if !self.inclusive {
                    return n, Option::<usize>::Some(n);
                }
                if n < usize::MAX {
                    return n + 1, Option::<usize>::Some(n + 1);
                }
            }
            return usize::MAX, Option::<usize>::None;
        }
        if self.inclusive && self.start == self.end {
            return 1, Option::<usize>::Some(1);
        }
        return 0, Option::<usize>::Some(0);
    }
}

extend<T: Step> Range<T> as DoubleEndedIterator<T> {
    pub fn next_back(self: &mut Range<T>) Option<T> {
        let v = self.end;
        if self.start < v {
            let w = v.down();
            self.end = w;
            if self.inclusive {
                return Option::<T>::Some(v);
            }
            return Option::<T>::Some(w);
        }
        if self.inclusive && self.start == v {
            self.inclusive = false;
            return Option::<T>::Some(v);
        }
        return Option::<T>::None;
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
}
