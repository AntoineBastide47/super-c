// Element-wise expressions over equal-length views, computed when assigned: `ex(a)` wraps a view, `+`,
// `-` and `*` of two expressions and `*` by a scalar build a larger one without computing or allocating
// anything, and `assign(dst, e)` writes element i of `e` to `dst[i]` for every i in one loop, `sum(e)`
// adds them. `assign(y, k * ex(a) + ex(b) * ex(c))` is one pass over the four views, with no temporary
// array, as a Fortran array assignment or a C++ expression template (Blaze, Eigen) is. `dst` is a `[]mut T`:
// the language makes it reach no storage the expression's views reach, so the loop needs no overlap test
// and vectorizes. The lengths are checked where an expression is built and where it is assigned (a
// mismatch panics); the elements are read unchecked.
import std::math::scalar as *;

/// The elements of an element-wise expression: `at(i)` for each `i < len()`, computed when read.
pub interface Elems<T> {
    fn len(self: &Self) usize;
    fn at(self: &Self, i: usize) T;
}

/// An element-wise expression of element type `T`: the operators build on it, `assign` and `sum` run it.
pub struct Ex<T, E> {
    pub e: E,
}

/// The elements of a view.
pub struct Leaf<'a, T> {
    s: Slice<'a, T>,
}

/// An operation `O` on the elements of `A` and `B`, element by element.
pub struct Zip<A, B, O> {
    a: A,
    b: B,
}

/// The elements of `A`, each multiplied by `k` (`k * a[i]`).
pub struct Scaled<T, A> {
    a: A,
    k: T,
}

/// An element operation of `Zip`.
pub interface ZipOp<T> {
    fn apply(a: T, b: T) T;
}

/// `a + b`.
pub struct AddOp {}
/// `a - b`.
pub struct SubOp {}
/// `a * b`.
pub struct MulOp {}

extend<T: Scalar> AddOp as ZipOp<T> {
    pub fn apply(a: T, b: T) T {
        return a + b;
    }
}

extend<T: Scalar> SubOp as ZipOp<T> {
    pub fn apply(a: T, b: T) T {
        return a - b;
    }
}

extend<T: Scalar> MulOp as ZipOp<T> {
    pub fn apply(a: T, b: T) T {
        return a * b;
    }
}

extend<'a, T> Leaf<'a, T> as Copy {}
extend<A: Copy, B: Copy, O> Zip<A, B, O> as Copy {}
extend<T: Copy, A: Copy> Scaled<T, A> as Copy {}
extend<T, E: Copy> Ex<T, E> as Copy {}

extend<'a, T: Scalar> Leaf<'a, T> as Elems<T> {
    pub fn len(self: &Leaf<'a, T>) usize {
        return self.s.len();
    }
    pub fn at(self: &Leaf<'a, T>, i: usize) T {
        return unsafe *self.s.get_unsafe(i);
    }
}

extend<T: Scalar, A: Elems<T>, B: Elems<T>, O: ZipOp<T>> Zip<A, B, O> as Elems<T> {
    pub fn len(self: &Zip<A, B, O>) usize {
        return self.a.len();
    }
    pub fn at(self: &Zip<A, B, O>, i: usize) T {
        return O::apply(self.a.at(i), self.b.at(i));
    }
}

extend<T: Scalar, A: Elems<T>> Scaled<T, A> as Elems<T> {
    pub fn len(self: &Scaled<T, A>) usize {
        return self.a.len();
    }
    pub fn at(self: &Scaled<T, A>, i: usize) T {
        return self.k * self.a.at(i);
    }
}

/// The expression of view `s`'s elements.
pub fn ex<'a, T: Scalar>(s: Slice<'a, T>) Ex<T, Leaf<'a, T>> {
    return Ex::<T, Leaf<'a, T>> { e: Leaf::<'a, T> { s: s } };
}

// The expression `o` of `a` and `b`, element by element. Panics: the lengths differ.
fn zip<T: Scalar, A: Elems<T> + Copy, B: Elems<T> + Copy, O: ZipOp<T>>(a: &Ex<T, A>, b: &Ex<T, B>) Ex<T, Zip<A, B, O>> {
    if a.e.len() != b.e.len() {
        panic("expr: the lengths differ");
    }
    return Ex::<T, Zip<A, B, O>> { e: Zip::<A, B, O> { a: a.e, b: b.e } };
}

extend<T: Scalar, A: Elems<T> + Copy, B: Elems<T> + Copy> Ex<T, A> as Add<Ex<T, B>> {
    type Output = Ex<T, Zip<A, B, AddOp>>;
    pub fn add(self: &Ex<T, A>, b: &Ex<T, B>) Ex<T, Zip<A, B, AddOp>> {
        return zip::<T, A, B, AddOp>(self, b);
    }
}

extend<T: Scalar, A: Elems<T> + Copy, B: Elems<T> + Copy> Ex<T, A> as Sub<Ex<T, B>> {
    type Output = Ex<T, Zip<A, B, SubOp>>;
    pub fn sub(self: &Ex<T, A>, b: &Ex<T, B>) Ex<T, Zip<A, B, SubOp>> {
        return zip::<T, A, B, SubOp>(self, b);
    }
}

extend<T: Scalar, A: Elems<T> + Copy, B: Elems<T> + Copy> Ex<T, A> as Mul<Ex<T, B>> {
    type Output = Ex<T, Zip<A, B, MulOp>>;
    pub fn mul(self: &Ex<T, A>, b: &Ex<T, B>) Ex<T, Zip<A, B, MulOp>> {
        return zip::<T, A, B, MulOp>(self, b);
    }
}

extend<T: Scalar, A: Elems<T> + Copy> T as Mul<Ex<T, A>> {
    type Output = Ex<T, Scaled<T, A>>;
    pub fn mul(self: &T, b: &Ex<T, A>) Ex<T, Scaled<T, A>> {
        return Ex::<T, Scaled<T, A>> { e: Scaled::<T, A> { a: b.e, k: *self } };
    }
}

extend<T: Scalar, A: Elems<T> + Copy> Ex<T, A> as Mul<T> {
    type Output = Ex<T, Scaled<T, A>>;
    pub fn mul(self: &Ex<T, A>, k: &T) Ex<T, Scaled<T, A>> {
        return Ex::<T, Scaled<T, A>> { e: Scaled::<T, A> { a: self.e, k: *k } };
    }
}

/// `dst[i] = e[i]` for every i, in one loop. Panics: the lengths differ.
pub fn assign<T: Scalar, E: Elems<T>>(dst: []mut T, e: Ex<T, E>) {
    let n = dst.len();
    if e.e.len() != n {
        panic("expr::assign: the lengths differ");
    }
    let p = dst.as_mut_ptr();
    for i in 0..n {
        unsafe {
            p[i] = e.e.at(i);
        }
    }
}

/// `e[0] + e[1] + ..`, added left to right from zero.
pub fn sum<T: Scalar, E: Elems<T>>(e: Ex<T, E>) T {
    let mut s = T::zero();
    for i in 0..e.e.len() {
        s = s + e.e.at(i);
    }
    return s;
}
