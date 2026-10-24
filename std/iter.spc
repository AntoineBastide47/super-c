// Lazy iterator adapters and eager consumers over any `Iterator<T>` conformance, as free functions: build a
// pipeline with the adapters (`map`, `filter`, `take`, `chain`, `rev`, `flat_map`, ..), then drain it with
// `for x in ..` or a consumer (`fold`, `collect`, `any`, `find`, `max`, ..). The closure's signature (or the
// source's conformance) pins the element types, so calls need no turbofish:
//
//     let s = fold(map(v.iter(), |x: &i32| *x * 2), 0, |a: i32, x: i32| a + x);
//     for p in enumerate(rev(0..n)) { .. }   // p.0 = index, p.1 = element
//
// Laziness: an adapter does no work when built; each `next` pulls from the source only what that value
// needs, so `take(it, k)` pulls at most `k` values. Cost: as C++ [range.adaptors], every adapter step is
// O(1) amortized: `filter`, `skip_while` and `skip` may pull several source values for one result, each
// source value at most once over the whole iteration; `flat_map` and `flatten` steps are amortized over the
// inner lengths; `step_by(it, s)` pulls `s` source values per result. Consumers are one pass, O(n) in the
// values they pull, and the early-stopping ones (`any`, `all`, `find`, `find_map`, `position`, `nth`, `eq`,
// `cmp`, `is_sorted`, `try_collect`) stop at their answer.
//
// Ownership: values flow BY VALUE through the pipeline (a borrowing source like `v.iter()` yields `&T`
// references, values themselves). Adapters and consumers take the source and the closures by value; a
// `Free`-owning (`fn move`) closure is not accepted. A closure that only reads a value borrows it (`&T`:
// `filter`, `take_while`, `any`, `position`, `inspect`, ..), so owned values pass through it; one that
// consumes takes `T` (`map`, `fold`, `find_map`, ..). Dropping an adapter or returning from a consumer drops
// the source with it, and with it the values the source still owns; a value an adapter rejects (`filter`,
// `take_while`, `skip`, ..) is dropped where it is rejected.
//
// Size hints: every adapter forwards `size_hint`, exact when the source is exact and the adapter's count
// is known (`map`, `enumerate`, `zip`, `take`, `skip`, `chain`, `rev`, `step_by`, `peekable`, `fuse`, ..),
// a bound otherwise (`filter`: `(0, hi)`). `collect` and its relatives reserve the lower bound once.
// Double-ended: an adapter is a `DoubleEndedIterator` when its sources are and both ends are O(1)
// reachable: `map`, `filter`, `inspect`, `fuse`, `copied`, `cloned`, `rev`, `chain`, `flat_map`, `flatten`,
// `peekable`; and `enumerate`, `zip`, `take`, `skip`, `step_by`, which also need the exact count of the
// rest: their `next_back` panics when the source's `size_hint` is not exact (Rust's `ExactSizeIterator`
// bound, checked when called). `take_while`, `skip_while`, `map_while`, `scan` and `cycle` are forward only.
// There is no `sum` or `product`: the builtin integers have no `Add` or `Mul` conformance, so `fold`
// covers them (`fold(it, 0, |a: i32, x: i32| a + x)`).

/// Yields `f(x)` for every `x` the source yields; from the back too, in reverse call order.
pub struct MapIter<I, T, U, F> {
    pub it: I,
    pub f: F,
}

/// An iterator applying `f` to each item of `it`.
pub const fn map<I: Iterator<T>, T, U, F: fn(T) U>(it: I, f: F) MapIter<I, T, U, F> {
    return MapIter::<I, T, U, F> { it: it, f: f };
}

extend<I: Iterator<T>, T, U, F: fn(T) U> MapIter<I, T, U, F> as Iterator<U> {
    pub fn next(self: &mut MapIter<I, T, U, F>) Option<U> {
        return switch self.it.next() {
            Some(x) => Option::<U>::Some(self.f(x)),
            None => Option::<U>::None,
        };
    }

    pub fn size_hint(self: &MapIter<I, T, U, F>) (usize, Option<usize>) {
        return self.it.size_hint();
    }
}

extend<I: DoubleEndedIterator<T>, T, U, F: fn(T) U> MapIter<I, T, U, F> as DoubleEndedIterator<U> {
    pub fn next_back(self: &mut MapIter<I, T, U, F>) Option<U> {
        return switch self.it.next_back() {
            Some(x) => Option::<U>::Some(self.f(x)),
            None => Option::<U>::None,
        };
    }
}

/// Yields only the elements the predicate accepts.
pub struct FilterIter<I, T, P> {
    pub it: I,
    pub p: P,
}

/// An iterator yielding only the items of `it` for which `p` holds.
pub const fn filter<I: Iterator<T>, T, P: fn(&T) bool>(it: I, p: P) FilterIter<I, T, P> {
    return FilterIter::<I, T, P> { it: it, p: p };
}

extend<I: Iterator<T>, T, P: fn(&T) bool> FilterIter<I, T, P> as Iterator<T> {
    pub fn next(self: &mut FilterIter<I, T, P>) Option<T> {
        loop {
            switch self.it.next() {
                Some(x) => {
                    if self.p(&x) {
                        return Option::<T>::Some(x);
                    }
                },
                None => {
                    return Option::<T>::None;
                },
            };
        }
    }

    /// `(0, hi)` of the source.
    pub fn size_hint(self: &FilterIter<I, T, P>) (usize, Option<usize>) {
        let (_, hi) = self.it.size_hint();
        return 0, hi;
    }
}

extend<I: DoubleEndedIterator<T>, T, P: fn(&T) bool> FilterIter<I, T, P> as DoubleEndedIterator<T> {
    pub fn next_back(self: &mut FilterIter<I, T, P>) Option<T> {
        loop {
            switch self.it.next_back() {
                Some(x) => {
                    if self.p(&x) {
                        return Option::<T>::Some(x);
                    }
                },
                None => {
                    return Option::<T>::None;
                },
            };
        }
    }
}

/// Yields `(index, element)` pairs, counting from 0.
pub struct EnumerateIter<I, T> {
    pub it: I,
    pub idx: usize,
}

/// An iterator pairing each item of `it` with its zero-based index.
pub const fn enumerate<I: Iterator<T>, T>(it: I) EnumerateIter<I, T> {
    return EnumerateIter::<I, T> { it: it, idx: 0 };
}

extend<I: Iterator<T>, T> EnumerateIter<I, T> as Iterator<(usize, T)> {
    pub fn next(self: &mut EnumerateIter<I, T>) Option<(usize, T)> {
        switch self.it.next() {
            Some(x) => {
                let i = self.idx;
                self.idx = self.idx + 1;
                return Option::<(usize, T)>::Some((i, x));
            },
            None => {},
        };
        return Option::<(usize, T)>::None;
    }

    pub fn size_hint(self: &EnumerateIter<I, T>) (usize, Option<usize>) {
        return self.it.size_hint();
    }
}

extend<I: DoubleEndedIterator<T>, T> EnumerateIter<I, T> as DoubleEndedIterator<(usize, T)> {
    /// The last pair; its index comes from the exact count of the rest. Panics when the source's
    /// `size_hint` is not exact.
    pub fn next_back(self: &mut EnumerateIter<I, T>) Option<(usize, T)> {
        let n = exact_len(&self.it, "enumerate: next_back needs an exact size_hint");
        switch self.it.next_back() {
            Some(x) => {
                return Option::<(usize, T)>::Some((self.idx + n - 1, x));
            },
            None => {},
        };
        return Option::<(usize, T)>::None;
    }
}

/// Yields pairs from two sources, stopping at the shorter one.
pub struct ZipIter<A, B, TA, TB> {
    pub a: A,
    pub b: B,
}

/// An iterator of pairs, ending when either input ends. A value of the longer input is dropped when the
/// shorter one ends.
pub const fn zip<A: Iterator<TA>, B: Iterator<TB>, TA, TB>(a: A, b: B) ZipIter<A, B, TA, TB> {
    return ZipIter::<A, B, TA, TB> { a: a, b: b };
}

extend<A: Iterator<TA>, B: Iterator<TB>, TA, TB> ZipIter<A, B, TA, TB> as Iterator<(TA, TB)> {
    pub fn next(self: &mut ZipIter<A, B, TA, TB>) Option<(TA, TB)> {
        switch self.a.next() {
            Some(x) => {
                switch self.b.next() {
                    Some(y) => {
                        return Option::<(TA, TB)>::Some((x, y));
                    },
                    None => {},
                };
            },
            None => {},
        };
        return Option::<(TA, TB)>::None;
    }

    /// The smaller of the two hints.
    pub fn size_hint(self: &ZipIter<A, B, TA, TB>) (usize, Option<usize>) {
        let (alo, ahi) = self.a.size_hint();
        let (blo, bhi) = self.b.size_hint();
        let hi = switch ahi {
            Some(x) => switch bhi {
                Some(y) => Option::<usize>::Some(x.min(y)),
                None => Option::<usize>::Some(x),
            },
            None => bhi,
        };
        return alo.min(blo), hi;
    }
}

extend<A: DoubleEndedIterator<TA>, B: DoubleEndedIterator<TB>, TA, TB> ZipIter<A, B, TA, TB> as DoubleEndedIterator<
    (TA, TB)
> {
    /// The last pair: first drops the values of the longer input that have no partner. Panics when either
    /// `size_hint` is not exact.
    pub fn next_back(self: &mut ZipIter<A, B, TA, TB>) Option<(TA, TB)> {
        let na = exact_len(&self.a, "zip: next_back needs exact size_hints");
        let nb = exact_len(&self.b, "zip: next_back needs exact size_hints");
        if na > nb {
            advance_back(&mut self.a, na - nb);
        } else if nb > na {
            advance_back(&mut self.b, nb - na);
        }
        switch self.a.next_back() {
            Some(x) => {
                switch self.b.next_back() {
                    Some(y) => {
                        return Option::<(TA, TB)>::Some((x, y));
                    },
                    None => {},
                };
            },
            None => {},
        };
        return Option::<(TA, TB)>::None;
    }
}

/// Yields at most `n` values of the source.
pub struct TakeIter<I, T> {
    pub(file) it: I,
    pub(file) n: usize, // values still allowed
}

/// An iterator over the first `n` items of `it`; it stops pulling `it` after the `n`th.
pub const fn take<I: Iterator<T>, T>(it: I, n: usize) TakeIter<I, T> {
    return TakeIter::<I, T> { it: it, n: n };
}

extend<I: Iterator<T>, T> TakeIter<I, T> as Iterator<T> {
    pub fn next(self: &mut TakeIter<I, T>) Option<T> {
        if self.n == 0 {
            return Option::<T>::None;
        }
        self.n = self.n - 1;
        return self.it.next();
    }

    pub fn size_hint(self: &TakeIter<I, T>) (usize, Option<usize>) {
        if self.n == 0 {
            return 0, Option::<usize>::Some(0);
        }
        let (lo, hi) = self.it.size_hint();
        let top = switch hi {
            Some(h) => h.min(self.n),
            None => self.n,
        };
        return lo.min(self.n), Option::<usize>::Some(top);
    }
}

extend<I: DoubleEndedIterator<T>, T> TakeIter<I, T> as DoubleEndedIterator<T> {
    /// The last of the taken values: first drops the source values past them. Panics when the source's
    /// `size_hint` is not exact.
    pub fn next_back(self: &mut TakeIter<I, T>) Option<T> {
        if self.n == 0 {
            return Option::<T>::None;
        }
        let len = exact_len(&self.it, "take: next_back needs an exact size_hint");
        if len > self.n {
            advance_back(&mut self.it, len - self.n);
        }
        self.n = self.n - 1;
        return self.it.next_back();
    }
}

/// Yields the source's values after the first `n`.
pub struct SkipIter<I, T> {
    pub(file) it: I,
    pub(file) n: usize, // values still to drop before the first `next`
}

/// An iterator over the items of `it` after the first `n`, which the first `next` drops.
pub const fn skip<I: Iterator<T>, T>(it: I, n: usize) SkipIter<I, T> {
    return SkipIter::<I, T> { it: it, n: n };
}

extend<I: Iterator<T>, T> SkipIter<I, T> as Iterator<T> {
    pub fn next(self: &mut SkipIter<I, T>) Option<T> {
        if self.n > 0 {
            let k = self.n;
            self.n = 0;
            if !advance(&mut self.it, k) {
                return Option::<T>::None;
            }
        }
        return self.it.next();
    }

    pub fn size_hint(self: &SkipIter<I, T>) (usize, Option<usize>) {
        let (lo, hi) = self.it.size_hint();
        let top = switch hi {
            Some(h) => Option::<usize>::Some(h.saturating_sub(self.n)),
            None => Option::<usize>::None,
        };
        return lo.saturating_sub(self.n), top;
    }
}

extend<I: DoubleEndedIterator<T>, T> SkipIter<I, T> as DoubleEndedIterator<T> {
    /// The source's last value, while more than `n` remain. Panics when the source's `size_hint` is not
    /// exact.
    pub fn next_back(self: &mut SkipIter<I, T>) Option<T> {
        if exact_len(&self.it, "skip: next_back needs an exact size_hint") > self.n {
            return self.it.next_back();
        }
        return Option::<T>::None;
    }
}

/// Yields every value of `a`, then every value of `b`.
pub struct ChainIter<A, B, T> {
    pub(file) a: A,
    pub(file) b: B,
    pub(file) a_done: bool, // `a` has ended: never pulled again
    pub(file) b_done: bool,
}

/// An iterator over the items of `a` followed by the items of `b`. Each input is pulled again after it ends
/// in neither direction.
pub const fn chain<A: Iterator<T>, B: Iterator<T>, T>(a: A, b: B) ChainIter<A, B, T> {
    return ChainIter::<A, B, T> { a: a, b: b, a_done: false, b_done: false };
}

extend<A: Iterator<T>, B: Iterator<T>, T> ChainIter<A, B, T> as Iterator<T> {
    pub fn next(self: &mut ChainIter<A, B, T>) Option<T> {
        if !self.a_done {
            let x = self.a.next();
            if x.is_some() {
                return x;
            }
            self.a_done = true;
        }
        if !self.b_done {
            let x = self.b.next();
            if x.is_some() {
                return x;
            }
            self.b_done = true;
        }
        return Option::<T>::None;
    }

    /// The sum of the hints of the inputs that have not ended.
    pub fn size_hint(self: &ChainIter<A, B, T>) (usize, Option<usize>) {
        let (alo, ahi) = hint_unless(&self.a, self.a_done);
        let (blo, bhi) = hint_unless(&self.b, self.b_done);
        return hint_sum(alo, ahi, blo, bhi);
    }
}

extend<A: DoubleEndedIterator<T>, B: DoubleEndedIterator<T>, T> ChainIter<A, B, T> as DoubleEndedIterator<T> {
    pub fn next_back(self: &mut ChainIter<A, B, T>) Option<T> {
        if !self.b_done {
            let x = self.b.next_back();
            if x.is_some() {
                return x;
            }
            self.b_done = true;
        }
        if !self.a_done {
            let x = self.a.next_back();
            if x.is_some() {
                return x;
            }
            self.a_done = true;
        }
        return Option::<T>::None;
    }
}

/// Yields the source's values from its far end.
pub struct RevIter<I, T> {
    pub(file) it: I,
}

/// An iterator over the items of `it` in reverse order (its `next_back`).
pub const fn rev<I: DoubleEndedIterator<T>, T>(it: I) RevIter<I, T> {
    return RevIter::<I, T> { it: it };
}

extend<I: DoubleEndedIterator<T>, T> RevIter<I, T> as Iterator<T> {
    pub fn next(self: &mut RevIter<I, T>) Option<T> {
        return self.it.next_back();
    }

    pub fn size_hint(self: &RevIter<I, T>) (usize, Option<usize>) {
        return self.it.size_hint();
    }
}

extend<I: DoubleEndedIterator<T>, T> RevIter<I, T> as DoubleEndedIterator<T> {
    pub fn next_back(self: &mut RevIter<I, T>) Option<T> {
        return self.it.next();
    }
}

/// Yields every value of every inner iterator `f(x)` makes from the source's values, in order.
pub struct FlatMapIter<I, T, J, U, F> {
    pub(file) it: I,
    pub(file) f: F,
    pub(file) front: Option<J>, // the inner iterator `next` drains; None when it ended
    pub(file) back: Option<J>, // the inner iterator `next_back` drains
    pub(file) done: bool, // the source has ended: never pulled again
}

/// The iterator of `flatten`: a `FlatMapIter` whose map is the identity.
pub type FlattenIter<I, J, U> = FlatMapIter<I, J, J, U, fn(J) J>;

/// An iterator over the items of each iterator `f(x)`, for each item `x` of `it`. An inner iterator is
/// made when the previous one ends, and dropped when it ends.
pub const fn flat_map<I: Iterator<T>, T, J: Iterator<U>, U, F: fn(T) J>(it: I, f: F) FlatMapIter<I, T, J, U, F> {
    return FlatMapIter::<I, T, J, U, F> { it: it, f: f, front: Option::<J>::None, back: Option::<J>::None, done: false };
}

/// An iterator over the items of each iterator `it` yields, in order.
pub const fn flatten<I: Iterator<J>, J: Iterator<U>, U>(it: I) FlattenIter<I, J, U> {
    return FlatMapIter::<I, J, J, U, fn(J) J> {
        it: it,
        f: flatten_identity::<J>,
        front: Option::<J>::None,
        back: Option::<J>::None,
        done: false,
    };
}

extend<I: Iterator<T>, T, J: Iterator<U>, U, F: fn(T) J> FlatMapIter<I, T, J, U, F> as Iterator<U> {
    pub fn next(self: &mut FlatMapIter<I, T, J, U, F>) Option<U> {
        loop {
            let x = inner_next(&mut self.front);
            if x.is_some() {
                return x;
            }
            if self.done {
                return inner_next(&mut self.back);
            }
            switch self.it.next() {
                Some(t) => {
                    self.front = Option::<J>::Some(self.f(t));
                },
                None => {
                    self.done = true;
                },
            };
        }
    }

    /// The sum of the inner hints; the upper bound is known only once the source is empty.
    pub fn size_hint(self: &FlatMapIter<I, T, J, U, F>) (usize, Option<usize>) {
        let (flo, fhi) = inner_hint(&self.front);
        let (blo, bhi) = inner_hint(&self.back);
        let (lo, hi) = hint_sum(flo, fhi, blo, bhi);
        if self.done {
            return lo, hi;
        }
        let (slo, shi) = self.it.size_hint();
        if slo == 0 && shi == Option::<usize>::Some(0) {
            return lo, hi;
        }
        return lo, Option::<usize>::None;
    }
}

extend<I: DoubleEndedIterator<T>, T, J: DoubleEndedIterator<U>, U, F: fn(T) J> FlatMapIter<I, T, J, U, F> as DoubleEndedIterator<
    U
> {
    pub fn next_back(self: &mut FlatMapIter<I, T, J, U, F>) Option<U> {
        loop {
            let x = inner_next_back(&mut self.back);
            if x.is_some() {
                return x;
            }
            if self.done {
                return inner_next_back(&mut self.front);
            }
            switch self.it.next_back() {
                Some(t) => {
                    self.back = Option::<J>::Some(self.f(t));
                },
                None => {
                    self.done = true;
                },
            };
        }
    }
}

/// Yields the source's values while the predicate holds.
pub struct TakeWhileIter<I, T, P> {
    pub(file) it: I,
    pub(file) p: P,
    pub(file) done: bool, // a value failed `p`: never pulled again
}

/// An iterator over the leading items of `it` for which `p` holds. The first item that fails `p` is
/// dropped, and `it` is not pulled after it.
pub const fn take_while<I: Iterator<T>, T, P: fn(&T) bool>(it: I, p: P) TakeWhileIter<I, T, P> {
    return TakeWhileIter::<I, T, P> { it: it, p: p, done: false };
}

extend<I: Iterator<T>, T, P: fn(&T) bool> TakeWhileIter<I, T, P> as Iterator<T> {
    pub fn next(self: &mut TakeWhileIter<I, T, P>) Option<T> {
        if self.done {
            return Option::<T>::None;
        }
        switch self.it.next() {
            Some(x) => {
                if self.p(&x) {
                    return Option::<T>::Some(x);
                }
                self.done = true;
            },
            None => {},
        };
        return Option::<T>::None;
    }

    pub fn size_hint(self: &TakeWhileIter<I, T, P>) (usize, Option<usize>) {
        if self.done {
            return 0, Option::<usize>::Some(0);
        }
        let (_, hi) = self.it.size_hint();
        return 0, hi;
    }
}

/// Yields the source's values from the first one the predicate rejects.
pub struct SkipWhileIter<I, T, P> {
    pub(file) it: I,
    pub(file) p: P,
    pub(file) done: bool, // the leading run has been dropped
}

/// An iterator over the items of `it` after its leading run of items for which `p` holds, which the first
/// `next` drops.
pub const fn skip_while<I: Iterator<T>, T, P: fn(&T) bool>(it: I, p: P) SkipWhileIter<I, T, P> {
    return SkipWhileIter::<I, T, P> { it: it, p: p, done: false };
}

extend<I: Iterator<T>, T, P: fn(&T) bool> SkipWhileIter<I, T, P> as Iterator<T> {
    pub fn next(self: &mut SkipWhileIter<I, T, P>) Option<T> {
        if self.done {
            return self.it.next();
        }
        loop {
            switch self.it.next() {
                Some(x) => {
                    if !self.p(&x) {
                        self.done = true;
                        return Option::<T>::Some(x);
                    }
                },
                None => {
                    return Option::<T>::None;
                },
            };
        }
    }

    pub fn size_hint(self: &SkipWhileIter<I, T, P>) (usize, Option<usize>) {
        if self.done {
            return self.it.size_hint();
        }
        let (_, hi) = self.it.size_hint();
        return 0, hi;
    }
}

/// Yields `v` for each `Some(v)` that `f` makes from the source's values, until the first `None`.
pub struct MapWhileIter<I, T, U, F> {
    pub(file) it: I,
    pub(file) f: F,
}

/// An iterator over `f(x)`'s payloads for the leading items `x` of `it`, ending at the first `None`. Not
/// fused: a later `next` pulls `it` again (wrap it in `fuse` to stop).
pub const fn map_while<I: Iterator<T>, T, U, F: fn(T) Option<U>>(it: I, f: F) MapWhileIter<I, T, U, F> {
    return MapWhileIter::<I, T, U, F> { it: it, f: f };
}

extend<I: Iterator<T>, T, U, F: fn(T) Option<U>> MapWhileIter<I, T, U, F> as Iterator<U> {
    pub fn next(self: &mut MapWhileIter<I, T, U, F>) Option<U> {
        return switch self.it.next() {
            Some(x) => self.f(x),
            None => Option::<U>::None,
        };
    }

    pub fn size_hint(self: &MapWhileIter<I, T, U, F>) (usize, Option<usize>) {
        let (_, hi) = self.it.size_hint();
        return 0, hi;
    }
}

/// Yields the source's first value, then every `step`th one after it.
pub struct StepByIter<I, T> {
    pub(file) it: I,
    pub(file) gap: usize, // `step - 1`: the values dropped between two results
    pub(file) first: bool, // the first value is still to come
}

/// An iterator over the items of `it` at positions 0, `step`, `2 * step`, ... Panics when `step` is 0.
pub const fn step_by<I: Iterator<T>, T>(it: I, step: usize) StepByIter<I, T> {
    if step == 0 {
        panic("step_by: step is 0");
    }
    return StepByIter::<I, T> { it: it, gap: step - 1, first: true };
}

extend<I: Iterator<T>, T> StepByIter<I, T> {
    // The number of results `n` more source values give.
    const fn results(self: &StepByIter<I, T>, n: usize) usize {
        if !self.first {
            return n / (self.gap + 1);
        }
        if n == 0 {
            return 0;
        }
        return 1 + (n - 1) / (self.gap + 1);
    }
}

extend<I: Iterator<T>, T> StepByIter<I, T> as Iterator<T> {
    pub fn next(self: &mut StepByIter<I, T>) Option<T> {
        if self.first {
            self.first = false;
            return self.it.next();
        }
        if !advance(&mut self.it, self.gap) {
            return Option::<T>::None;
        }
        return self.it.next();
    }

    pub fn size_hint(self: &StepByIter<I, T>) (usize, Option<usize>) {
        let (lo, hi) = self.it.size_hint();
        let top = switch hi {
            Some(h) => Option::<usize>::Some(self.results(h)),
            None => Option::<usize>::None,
        };
        return self.results(lo), top;
    }
}

extend<I: DoubleEndedIterator<T>, T> StepByIter<I, T> as DoubleEndedIterator<T> {
    /// The last value on the step grid: first drops the source values past it. Panics when the source's
    /// `size_hint` is not exact.
    pub fn next_back(self: &mut StepByIter<I, T>) Option<T> {
        let n = exact_len(&self.it, "step_by: next_back needs an exact size_hint");
        let rem = n % (self.gap + 1);
        let mut past = rem;
        if self.first {
            past = if rem == 0 {
                self.gap;
            } else {
                rem - 1;
            };
        }
        if !advance_back(&mut self.it, past) {
            return Option::<T>::None;
        }
        return self.it.next_back();
    }
}

/// Yields the source's values and can show the next one without consuming it.
pub struct PeekableIter<I, T> {
    pub(file) it: I,
    pub(file) peeked: Option<Option<T>>, // Some: the source's next result, already pulled
}

/// An iterator over the items of `it` with `peek` and `next_if`.
pub const fn peekable<I: Iterator<T>, T>(it: I) PeekableIter<I, T> {
    return PeekableIter::<I, T> { it: it, peeked: Option::<Option<T>>::None };
}

extend<I: Iterator<T>, T> PeekableIter<I, T> {
    /// A borrow of the next value, pulled from the source at most once; `None` at the end.
    pub fn peek(self: &mut PeekableIter<I, T>) Option<&T> {
        if self.peeked.is_none() {
            self.peeked = Option::<Option<T>>::Some(self.it.next());
        }
        return switch &self.peeked {
            Some(Some(v)) => Option::<&T>::Some(v),
            _ => Option::<&T>::None,
        };
    }

    /// The next value when `p` holds for it; else `None`, and the value stays next. `p` borrows it.
    pub fn next_if<P: fn(&T) bool>(self: &mut PeekableIter<I, T>, p: P) Option<T> {
        let hit = switch self.peek() {
            Some(v) => p(v),
            None => false,
        };
        if hit {
            return self.next();
        }
        return Option::<T>::None;
    }
}

extend<I: Iterator<T>, T> PeekableIter<I, T> as Iterator<T> {
    pub fn next(self: &mut PeekableIter<I, T>) Option<T> {
        return switch self.peeked.take() {
            Some(v) => v,
            None => self.it.next(),
        };
    }

    pub fn size_hint(self: &PeekableIter<I, T>) (usize, Option<usize>) {
        let held: usize = switch &self.peeked {
            Some(Some(_)) => 1,
            Some(None) => {
                return 0, Option::<usize>::Some(0);
            },
            None => 0,
        };
        let (lo, hi) = self.it.size_hint();
        let top = switch hi {
            Some(h) => h.checked_add(held),
            None => Option::<usize>::None,
        };
        return lo.saturating_add(held), top;
    }
}

extend<I: DoubleEndedIterator<T>, T> PeekableIter<I, T> as DoubleEndedIterator<T> {
    /// The source's last value; the peeked value comes last.
    pub fn next_back(self: &mut PeekableIter<I, T>) Option<T> {
        switch &self.peeked {
            Some(Some(_)) => {},
            Some(None) => {
                return Option::<T>::None;
            },
            None => {
                return self.it.next_back();
            },
        };
        let x = self.it.next_back();
        if x.is_some() {
            return x;
        }
        return switch self.peeked.replace(Option::<T>::None) {
            Some(v) => v,
            None => Option::<T>::None,
        };
    }
}

/// Yields the source's values and calls `f` on each as it passes.
pub struct InspectIter<I, T, F> {
    pub(file) it: I,
    pub(file) f: F,
}

/// An iterator over the items of `it` that runs `f` on each one first. `f` borrows the item.
pub const fn inspect<I: Iterator<T>, T, F: fn(&T) void>(it: I, f: F) InspectIter<I, T, F> {
    return InspectIter::<I, T, F> { it: it, f: f };
}

extend<I: Iterator<T>, T, F: fn(&T) void> InspectIter<I, T, F> as Iterator<T> {
    pub fn next(self: &mut InspectIter<I, T, F>) Option<T> {
        let x = self.it.next();
        switch &x {
            Some(v) => self.f(v),
            None => {},
        };
        return x;
    }

    pub fn size_hint(self: &InspectIter<I, T, F>) (usize, Option<usize>) {
        return self.it.size_hint();
    }
}

extend<I: DoubleEndedIterator<T>, T, F: fn(&T) void> InspectIter<I, T, F> as DoubleEndedIterator<T> {
    pub fn next_back(self: &mut InspectIter<I, T, F>) Option<T> {
        let x = self.it.next_back();
        switch &x {
            Some(v) => self.f(v),
            None => {},
        };
        return x;
    }
}

/// Yields the source's values until its first `None`, then only `None`.
pub struct FuseIter<I, T> {
    pub(file) it: I,
    pub(file) done: bool, // the source returned None: never pulled again
}

/// An iterator over the items of `it` that never pulls `it` again after it ends.
pub const fn fuse<I: Iterator<T>, T>(it: I) FuseIter<I, T> {
    return FuseIter::<I, T> { it: it, done: false };
}

extend<I: Iterator<T>, T> FuseIter<I, T> as Iterator<T> {
    pub fn next(self: &mut FuseIter<I, T>) Option<T> {
        if self.done {
            return Option::<T>::None;
        }
        let x = self.it.next();
        if x.is_none() {
            self.done = true;
        }
        return x;
    }

    pub fn size_hint(self: &FuseIter<I, T>) (usize, Option<usize>) {
        return hint_unless(&self.it, self.done);
    }
}

extend<I: DoubleEndedIterator<T>, T> FuseIter<I, T> as DoubleEndedIterator<T> {
    pub fn next_back(self: &mut FuseIter<I, T>) Option<T> {
        if self.done {
            return Option::<T>::None;
        }
        let x = self.it.next_back();
        if x.is_none() {
            self.done = true;
        }
        return x;
    }
}

/// Yields the source's values over and over.
pub struct CycleIter<I, T> {
    pub(file) orig: I, // the source as it was built
    pub(file) cur: I, // the pass in progress
}

/// An iterator that restarts a copy of `it` each time the copy ends; empty when `it` is. `it` must be
/// `Copy` (every borrowing pipeline of non-owning closures is): a copy restarts in O(1), and `Copy` needs
/// no conformance per adapter, which `Clone` would.
pub const fn cycle<I: Iterator<T> + Copy, T>(it: I) CycleIter<I, T> {
    return CycleIter::<I, T> { orig: it, cur: it };
}

extend<I: Iterator<T> + Copy, T> CycleIter<I, T> as Iterator<T> {
    pub fn next(self: &mut CycleIter<I, T>) Option<T> {
        let x = self.cur.next();
        if x.is_some() {
            return x;
        }
        self.cur = self.orig;
        return self.cur.next();
    }

    /// `(0, Some(0))` for an empty source, else unbounded.
    pub fn size_hint(self: &CycleIter<I, T>) (usize, Option<usize>) {
        let (lo, hi) = self.orig.size_hint();
        if lo > 0 {
            return usize::MAX, Option::<usize>::None;
        }
        if hi == Option::<usize>::Some(0) {
            return 0, hi;
        }
        return 0, Option::<usize>::None;
    }
}

/// Yields what `f` makes from a running state and each source value, until `f` returns `None`.
pub struct ScanIter<I, T, S, U, F> {
    pub(file) it: I,
    pub(file) state: S,
    pub(file) f: F,
}

/// An iterator over the payloads of `f(&mut state, x)` for the items `x` of `it`, starting from `init`,
/// ending at the first `None`. Not fused, as `map_while`. The state is dropped with the iterator.
pub const fn scan<I: Iterator<T>, T, S, U, F: fn(&mut S, T) Option<U>>(it: I, init: S, f: F) ScanIter<I, T, S, U, F> {
    return ScanIter::<I, T, S, U, F> { it: it, state: init, f: f };
}

extend<I: Iterator<T>, T, S, U, F: fn(&mut S, T) Option<U>> ScanIter<I, T, S, U, F> as Iterator<U> {
    pub fn next(self: &mut ScanIter<I, T, S, U, F>) Option<U> {
        return switch self.it.next() {
            Some(x) => self.f(&mut self.state, x),
            None => Option::<U>::None,
        };
    }

    pub fn size_hint(self: &ScanIter<I, T, S, U, F>) (usize, Option<usize>) {
        let (_, hi) = self.it.size_hint();
        return 0, hi;
    }
}

/// Yields a copy of each value a borrowing source points at.
pub struct CopiedIter<I, T> {
    pub(file) it: I,
}

/// An iterator over `*r` for the references `r` of `it` (`copied(v.iter())` yields `T`, so `T: Ord`
/// consumers such as `max` apply).
pub const fn copied<'a, I: Iterator<&'a T>, T: Copy>(it: I) CopiedIter<I, T> {
    return CopiedIter::<I, T> { it: it };
}

extend<'a, I: Iterator<&'a T>, T: Copy> CopiedIter<I, T> as Iterator<T> {
    pub fn next(self: &mut CopiedIter<I, T>) Option<T> {
        return switch self.it.next() {
            Some(r) => Option::<T>::Some(*r),
            None => Option::<T>::None,
        };
    }

    pub fn size_hint(self: &CopiedIter<I, T>) (usize, Option<usize>) {
        return self.it.size_hint();
    }
}

extend<'a, I: DoubleEndedIterator<&'a T>, T: Copy> CopiedIter<I, T> as DoubleEndedIterator<T> {
    pub fn next_back(self: &mut CopiedIter<I, T>) Option<T> {
        return switch self.it.next_back() {
            Some(r) => Option::<T>::Some(*r),
            None => Option::<T>::None,
        };
    }
}

/// Yields a clone of each value a borrowing source points at.
pub struct ClonedIter<I, T> {
    pub(file) it: I,
}

/// An iterator over `r.clone()` for the references `r` of `it`: one deep copy per item.
pub const fn cloned<'a, I: Iterator<&'a T>, T: Clone>(it: I) ClonedIter<I, T> {
    return ClonedIter::<I, T> { it: it };
}

extend<'a, I: Iterator<&'a T>, T: Clone> ClonedIter<I, T> as Iterator<T> {
    pub fn next(self: &mut ClonedIter<I, T>) Option<T> {
        return switch self.it.next() {
            Some(r) => Option::<T>::Some(r.clone()),
            None => Option::<T>::None,
        };
    }

    pub fn size_hint(self: &ClonedIter<I, T>) (usize, Option<usize>) {
        return self.it.size_hint();
    }
}

extend<'a, I: DoubleEndedIterator<&'a T>, T: Clone> ClonedIter<I, T> as DoubleEndedIterator<T> {
    pub fn next_back(self: &mut ClonedIter<I, T>) Option<T> {
        return switch self.it.next_back() {
            Some(r) => Option::<T>::Some(r.clone()),
            None => Option::<T>::None,
        };
    }
}

// Consumers: drain the (rest of the) pipeline.

/// Left fold: `acc = f(acc, x)` over every element, starting from `init`.
pub fn fold<I: Iterator<T>, T, A, F: fn(A, T) A>(it: I, init: A, f: F) A {
    let mut i = it;
    let mut acc = init;
    loop {
        switch i.next() {
            Some(x) => {
                acc = f(acc, x);
            },
            _ => {
                break;
            },
        };
    }
    return acc;
}

/// Left fold seeded with the first element: `f(f(x0, x1), x2)..`; `None` when empty.
pub fn reduce<I: Iterator<T>, T, F: fn(T, T) T>(it: I, f: F) Option<T> {
    let mut i = it;
    let first = i.next();
    if first.is_none() {
        return first;
    }
    let mut acc = first.unwrap();
    loop {
        switch i.next() {
            Some(x) => {
                acc = f(acc, x);
            },
            None => {
                break;
            },
        };
    }
    return Option::<T>::Some(acc);
}

/// Runs `f` on every element, for its effects.
pub fn for_each<I: Iterator<T>, T, F: fn(T) void>(it: I, f: F) {
    let mut i = it;
    loop {
        switch i.next() {
            Some(x) => {
                f(x);
            },
            _ => {
                break;
            },
        };
    }
}

/// The number of elements the iterator yields.
pub fn count<I: Iterator<T>, T>(it: I) usize {
    let mut i = it;
    let mut n: usize = 0;
    loop {
        switch i.next() {
            Some(_) => {
                n = n + 1;
            },
            _ => {
                break;
            },
        };
    }
    return n;
}

/// Everything the iterator yields, in order, as a Vector. Reserves the lower size hint once.
pub fn collect<I: Iterator<T>, T>(it: I) Vector<T> {
    let mut i = it;
    let (lo, _) = i.size_hint();
    let mut v = Vector::<T>::with_capacity(lo);
    loop {
        switch i.next() {
            Some(x) => {
                v.push(x);
            },
            _ => {
                break;
            },
        };
    }
    return v;
}

/// Everything the iterator yields, in order, as a Vector that allocates through `alloc`. Reserves the
/// lower size hint once.
pub fn collect_in<I: Iterator<T>, T, A: Allocator>(it: I, alloc: A) Vector<T, A> {
    let mut i = it;
    let (lo, _) = i.size_hint();
    let mut v = Vector::<T, A>::with_capacity_in(alloc, lo);
    loop {
        switch i.next() {
            Some(x) => {
                v.push(x);
            },
            None => {
                break;
            },
        };
    }
    return v;
}

/// The `Ok` payloads in order, or the first error: it stops there, and frees what it collected.
pub fn try_collect<I: Iterator<Result<T, E>>, T, E>(it: I) Result<Vector<T>, E> {
    let mut i = it;
    let (lo, _) = i.size_hint();
    let mut v = Vector::<T>::with_capacity(lo);
    loop {
        switch i.next() {
            Some(Ok(x)) => {
                v.push(x);
            },
            Some(Err(e)) => {
                return Result::<Vector<T>, E>::Err(e);
            },
            None => {
                break;
            },
        };
    }
    return Result::<Vector<T>, E>::Ok(v);
}

/// The `Some` payloads in order, or `None` at the first `None`: it stops there, and frees what it
/// collected.
pub fn try_collect_option<I: Iterator<Option<T>>, T>(it: I) Option<Vector<T>> {
    let mut i = it;
    let (lo, _) = i.size_hint();
    let mut v = Vector::<T>::with_capacity(lo);
    loop {
        switch i.next() {
            Some(Some(x)) => {
                v.push(x);
            },
            Some(None) => {
                return Option::<Vector<T>>::None;
            },
            None => {
                break;
            },
        };
    }
    return Option::<Vector<T>>::Some(v);
}

/// The elements for which `p` holds, then the others, each in order. `p` borrows each element.
pub fn partition<I: Iterator<T>, T, P: fn(&T) bool>(it: I, p: P) (Vector<T>, Vector<T>) {
    let mut i = it;
    let mut yes = Vector::<T>::new();
    let mut no = Vector::<T>::new();
    loop {
        switch i.next() {
            Some(x) => {
                if p(&x) {
                    yes.push(x);
                } else {
                    no.push(x);
                }
            },
            None => {
                break;
            },
        };
    }
    return yes, no;
}

/// The first and the second elements of every pair, each in order. Reserves the lower size hint once.
pub fn unzip<I: Iterator<(A, B)>, A, B>(it: I) (Vector<A>, Vector<B>) {
    let mut i = it;
    let (lo, _) = i.size_hint();
    let mut va = Vector::<A>::with_capacity(lo);
    let mut vb = Vector::<B>::with_capacity(lo);
    loop {
        switch i.next() {
            Some((a, b)) => {
                va.push(a);
                vb.push(b);
            },
            None => {
                break;
            },
        };
    }
    return va, vb;
}

/// True when `p` holds for some element; stops at the first one. `p` borrows each element.
pub fn any<I: Iterator<T>, T, P: fn(&T) bool>(it: I, p: P) bool {
    let mut i = it;
    loop {
        switch i.next() {
            Some(x) => {
                if p(&x) {
                    return true;
                }
            },
            None => {
                return false;
            },
        };
    }
}

/// True when `p` holds for every element (also when there is none); stops at the first failure. `p`
/// borrows each element.
pub fn all<I: Iterator<T>, T, P: fn(&T) bool>(it: I, p: P) bool {
    let mut i = it;
    loop {
        switch i.next() {
            Some(x) => {
                if !p(&x) {
                    return false;
                }
            },
            None => {
                return true;
            },
        };
    }
}

/// The first element for which `p` holds; stops there. `p` borrows each element.
pub fn find<I: Iterator<T>, T, P: fn(&T) bool>(it: I, p: P) Option<T> {
    let mut i = it;
    loop {
        switch i.next() {
            Some(x) => {
                if p(&x) {
                    return Option::<T>::Some(x);
                }
            },
            None => {
                return Option::<T>::None;
            },
        };
    }
}

/// The first `Some` that `f` makes from an element; stops there. `f` consumes each element.
pub fn find_map<I: Iterator<T>, T, U, F: fn(T) Option<U>>(it: I, f: F) Option<U> {
    let mut i = it;
    loop {
        switch i.next() {
            Some(x) => {
                let r = f(x);
                if r.is_some() {
                    return r;
                }
            },
            None => {
                return Option::<U>::None;
            },
        };
    }
}

/// The zero-based index of the first element for which `p` holds; stops there. `p` borrows each element.
pub fn position<I: Iterator<T>, T, P: fn(&T) bool>(it: I, p: P) Option<usize> {
    let mut i = it;
    let mut k: usize = 0;
    loop {
        switch i.next() {
            Some(x) => {
                if p(&x) {
                    return Option::<usize>::Some(k);
                }
            },
            None => {
                return Option::<usize>::None;
            },
        };
        k = k + 1;
    }
}

/// The element at zero-based position `n`, after dropping the `n` before it; `None` when there are fewer.
pub fn nth<I: Iterator<T>, T>(it: I, n: usize) Option<T> {
    let mut i = it;
    if !advance(&mut i, n) {
        return Option::<T>::None;
    }
    return i.next();
}

/// The last element; drops every one before it.
pub fn last<I: Iterator<T>, T>(it: I) Option<T> {
    let mut i = it;
    let mut l = Option::<T>::None;
    loop {
        switch i.next() {
            Some(x) => {
                l = Option::<T>::Some(x);
            },
            None => {
                return l;
            },
        };
    }
}

/// The first of the smallest elements; `None` when empty. `n - 1` comparisons.
pub fn min<I: Iterator<T>, T: Ord>(it: I) Option<T> {
    let mut i = it;
    let first = i.next();
    if first.is_none() {
        return first;
    }
    let mut best = first.unwrap();
    loop {
        switch i.next() {
            Some(x) => {
                if x < best {
                    best = x;
                }
            },
            None => {
                return Option::<T>::Some(best);
            },
        };
    }
}

/// The last of the largest elements; `None` when empty. `n - 1` comparisons.
pub fn max<I: Iterator<T>, T: Ord>(it: I) Option<T> {
    let mut i = it;
    let first = i.next();
    if first.is_none() {
        return first;
    }
    let mut best = first.unwrap();
    loop {
        switch i.next() {
            Some(x) => {
                if x >= best {
                    best = x;
                }
            },
            None => {
                return Option::<T>::Some(best);
            },
        };
    }
}

/// The first of the smallest elements under `cmp` (negative: less, as `Ord::cmp`); `None` when empty.
pub fn min_by<I: Iterator<T>, T, C: fn(&T, &T) i32>(it: I, cmp: C) Option<T> {
    let mut i = it;
    let first = i.next();
    if first.is_none() {
        return first;
    }
    let mut best = first.unwrap();
    loop {
        switch i.next() {
            Some(x) => {
                if cmp(&x, &best) < 0 {
                    best = x;
                }
            },
            None => {
                return Option::<T>::Some(best);
            },
        };
    }
}

/// The last of the largest elements under `cmp` (negative: less, as `Ord::cmp`); `None` when empty.
pub fn max_by<I: Iterator<T>, T, C: fn(&T, &T) i32>(it: I, cmp: C) Option<T> {
    let mut i = it;
    let first = i.next();
    if first.is_none() {
        return first;
    }
    let mut best = first.unwrap();
    loop {
        switch i.next() {
            Some(x) => {
                if cmp(&x, &best) >= 0 {
                    best = x;
                }
            },
            None => {
                return Option::<T>::Some(best);
            },
        };
    }
}

/// The first element with the smallest `key`; `None` when empty. `key` runs once per element.
pub fn min_by_key<I: Iterator<T>, T, K: Ord, F: fn(&T) K>(it: I, key: F) Option<T> {
    let mut i = it;
    let first = i.next();
    if first.is_none() {
        return first;
    }
    let mut best = first.unwrap();
    let mut best_key = key(&best);
    loop {
        switch i.next() {
            Some(x) => {
                let k = key(&x);
                if k < best_key {
                    best_key = k;
                    best = x;
                }
            },
            None => {
                return Option::<T>::Some(best);
            },
        };
    }
}

/// The last element with the largest `key`; `None` when empty. `key` runs once per element.
pub fn max_by_key<I: Iterator<T>, T, K: Ord, F: fn(&T) K>(it: I, key: F) Option<T> {
    let mut i = it;
    let first = i.next();
    if first.is_none() {
        return first;
    }
    let mut best = first.unwrap();
    let mut best_key = key(&best);
    loop {
        switch i.next() {
            Some(x) => {
                let k = key(&x);
                if k >= best_key {
                    best_key = k;
                    best = x;
                }
            },
            None => {
                return Option::<T>::Some(best);
            },
        };
    }
}

/// True when both iterators yield equal elements in order and end together; stops at the first
/// difference.
pub fn eq<A: Iterator<T>, B: Iterator<T>, T: Eq>(a: A, b: B) bool {
    let mut x = a;
    let mut y = b;
    loop {
        switch x.next() {
            Some(p) => {
                switch y.next() {
                    Some(q) => {
                        if p != q {
                            return false;
                        }
                    },
                    None => {
                        return false;
                    },
                };
            },
            None => {
                return y.next().is_none();
            },
        };
    }
}

/// Lexicographic order of the two sequences, as `Ord::cmp`: the first unequal pair decides, else the
/// shorter one is less. Stops at the decision.
pub fn cmp<A: Iterator<T>, B: Iterator<T>, T: Ord>(a: A, b: B) i32 {
    let mut x = a;
    let mut y = b;
    loop {
        switch x.next() {
            Some(p) => {
                switch y.next() {
                    Some(q) => {
                        let c = p.cmp(&q);
                        if c != 0 {
                            return c;
                        }
                    },
                    None => {
                        return 1;
                    },
                };
            },
            None => {
                if y.next().is_none() {
                    return 0;
                }
                return -1;
            },
        };
    }
}

/// True when every element is at least the one before it; stops at the first descent.
pub fn is_sorted<I: Iterator<T>, T: Ord>(it: I) bool {
    let mut i = it;
    let first = i.next();
    if first.is_none() {
        return true;
    }
    let mut prev = first.unwrap();
    loop {
        switch i.next() {
            Some(x) => {
                if x < prev {
                    return false;
                }
                prev = x;
            },
            None => {
                return true;
            },
        };
    }
}

// The exact number of values `it` has left; panics with `msg` when its size hint is not exact.
fn exact_len<I: Iterator<T>, T>(it: &I, msg: str) usize {
    let (lo, hi) = it.size_hint();
    if hi != Option::<usize>::Some(lo) {
        panic(msg);
    }
    return lo;
}

// Drops the next `n` values of `it`; false when it ends first.
fn advance<I: Iterator<T>, T>(it: &mut I, n: usize) bool {
    let mut k: usize = 0;
    while k < n {
        if it.next().is_none() {
            return false;
        }
        k = k + 1;
    }
    return true;
}

// Drops the last `n` values of `it`; false when it ends first.
fn advance_back<I: DoubleEndedIterator<T>, T>(it: &mut I, n: usize) bool {
    let mut k: usize = 0;
    while k < n {
        if it.next_back().is_none() {
            return false;
        }
        k = k + 1;
    }
    return true;
}

// The hint of `it`, or an empty one when it has ended.
fn hint_unless<I: Iterator<T>, T>(it: &I, done: bool) (usize, Option<usize>) {
    if done {
        return 0, Option::<usize>::Some(0);
    }
    return it.size_hint();
}

// The hint of two sequences one after the other.
const fn hint_sum(alo: usize, ahi: Option<usize>, blo: usize, bhi: Option<usize>) (usize, Option<usize>) {
    let hi = switch ahi {
        Some(x) => switch bhi {
            Some(y) => x.checked_add(y),
            None => Option::<usize>::None,
        },
        None => Option::<usize>::None,
    };
    return alo.saturating_add(blo), hi;
}

// The next value of the inner iterator in `slot`; empties the slot when that iterator ends.
fn inner_next<J: Iterator<U>, U>(slot: &mut Option<J>) Option<U> {
    let x = switch slot {
        Some(inner) => inner.next(),
        None => Option::<U>::None,
    };
    if x.is_none() {
        *slot = Option::<J>::None;
    }
    return x;
}

// The last value of the inner iterator in `slot`; empties the slot when that iterator ends.
fn inner_next_back<J: DoubleEndedIterator<U>, U>(slot: &mut Option<J>) Option<U> {
    let x = switch slot {
        Some(inner) => inner.next_back(),
        None => Option::<U>::None,
    };
    if x.is_none() {
        *slot = Option::<J>::None;
    }
    return x;
}

// The hint of the inner iterator in `slot`; empty without one.
fn inner_hint<J: Iterator<U>, U>(slot: &Option<J>) (usize, Option<usize>) {
    switch slot {
        Some(inner) => {
            return inner.size_hint();
        },
        None => {
            return 0, Option::<usize>::Some(0);
        },
    };
}

const fn flatten_identity<J>(x: J) J {
    return x;
}
