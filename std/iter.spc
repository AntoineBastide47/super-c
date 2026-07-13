// Lazy iterator adapters over any `Iterator<T>` conformance: build a pipeline with `map` / `filter` /
// `enumerate` / `zip`, then drain it with `for x in ..`, `fold`, `for_each`, `count`, or `collect`.
// The closure's signature (or the source's conformance) pins the element types, so calls need no
// turbofish:
//
//     let s = fold(map(v.iter(), |x: &i32| *x * 2), 0, |a: i32, x: i32| a + x);
//     for p in enumerate(v.iter()) { .. }   // p.0 = index, p.1 = element
//
// Elements flow BY VALUE through the pipeline (a borrowing source like `v.iter()` yields `&T`
// references, which are values themselves). Adapters store the source iterator and the closure by
// value; a `Free`-owning (`fn move`) closure is not accepted, and `filter` cannot pass owned `Free`
// elements through (the predicate call would consume them) -- iterate those by reference instead.

// Yields `f(x)` for every `x` the source yields.
pub struct MapIter<I, T, U, F> {
    pub it: I,
    pub f: F,
}

pub fn map<I: Iterator<T>, T, U, F: fn(T) U>(it: I, f: F) MapIter<I, T, U, F> {
    return MapIter::<I, T, U, F> { it: it, f: f };
}

extend<I: Iterator<T>, T, U, F: fn(T) U> MapIter<I, T, U, F> as Iterator<U> {
    pub fn next(self: &mut MapIter<I, T, U, F>) Option<U> {
        return switch self.it.next() {
            Some(x) => Option::<U>::Some(self.f(x)),
            None => Option::<U>::None,
        };
    }
}

// Yields only the elements the predicate accepts.
pub struct FilterIter<I, T, P> {
    pub it: I,
    pub p: P,
}

pub fn filter<I: Iterator<T>, T, P: fn(T) bool>(it: I, p: P) FilterIter<I, T, P> {
    return FilterIter::<I, T, P> { it: it, p: p };
}

extend<I: Iterator<T>, T, P: fn(T) bool> FilterIter<I, T, P> as Iterator<T> {
    pub fn next(self: &mut FilterIter<I, T, P>) Option<T> {
        loop {
            switch self.it.next() {
                Some(x) => {
                    if self.p(x) {
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

// Yields `(index, element)` pairs, counting from 0.
pub struct EnumerateIter<I, T> {
    pub it: I,
    pub idx: usize,
}

pub fn enumerate<I: Iterator<T>, T>(it: I) EnumerateIter<I, T> {
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
}

// Yields pairs from two sources, stopping at the shorter one.
pub struct ZipIter<A, B, TA, TB> {
    pub a: A,
    pub b: B,
}

pub fn zip<A: Iterator<TA>, B: Iterator<TB>, TA, TB>(a: A, b: B) ZipIter<A, B, TA, TB> {
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
}

// Drains: consume the (rest of the) pipeline.

// Left fold: `acc = f(acc, x)` over every element, starting from `init`.
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

// Runs `f` on every element, for its effects.
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

// The number of elements the iterator yields.
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

// Everything the iterator yields, in order, as a Vector.
pub fn collect<I: Iterator<T>, T>(it: I) Vector<T> {
    let mut i = it;
    let mut v = Vector::<T>::new();
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
