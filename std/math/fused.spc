// Fused forms of the vector functions whose arithmetic is a sum of squares: each square after the first is
// added with one rounding (`fma`), in index order. No square can cancel another, so these keep every exact
// property of the unfused functions, are at least as accurate, and run faster where the CPU has a fused
// multiply-add. Their results differ in the last bits from `length`, `distance` and `normalize`.
// Products whose terms can cancel (`dot`, the matrix products, `cross`, the quaternion product,
// `determinant`) have no fused form on `Vec` and `Mat`: fusing them breaks exact results such as
// `cross(a, a) == 0`, `dot(v, perp(v)) == 0` or a zero determinant for two equal columns.
//
// `LargeVec` and `LargeMat` (below) are heap-backed and of run-time size, for sizes where `Vec` and `Mat`
// stop scaling. Their products are fused by definition and run on SME tiles where the CPU has them;
// `mul_fused` gives a `Mat` product the same definition.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::simd;
import std::simd::matrix;

/// The squared length of `v`: `fma(v[N-1], v[N-1], .. fma(v[1], v[1], v[0] * v[0]))`.
pub fn length2_fused<T: Float, const N: usize>(v: Vec<T, N>) T {
    static_assert(N >= 1, "length2_fused of an empty vector");
    let mut s = unsafe v.e[0] * v.e[0];
    for i in 1..N {
        unsafe {
            s = v.e[i].fma(v.e[i], s);
        }
    }
    return s;
}

/// The length of `v`: `sqrt(length2_fused(v))`.
pub fn length_fused<T: Float, const N: usize>(v: Vec<T, N>) T {
    return length2_fused(v).sqrt();
}

/// The squared distance between `p0` and `p1`: `length2_fused(p1 - p0)`.
pub fn distance2_fused<T: Float, const N: usize>(p0: Vec<T, N>, p1: Vec<T, N>) T {
    return length2_fused(p1 - p0);
}

/// The distance between `p0` and `p1`: `length_fused(p1 - p0)`.
pub fn distance_fused<T: Float, const N: usize>(p0: Vec<T, N>, p1: Vec<T, N>) T {
    return length_fused(p1 - p0);
}

/// `v` scaled to length 1: `v * (1 / length_fused(v))`. A zero vector gives NaN components, as
/// `normalize` does.
pub fn normalize_fused<T: Float, const N: usize>(v: Vec<T, N>) Vec<T, N> {
    return v * (T::one() / length_fused(v));
}

// ---- Large vectors and matrices ---------------------------------------------------------------------
// Every product has one defined result on every machine and kernel:
// - element (i, j) of `a * b` and element i of `a * x` are the fused chain over the inner index p, in order,
//   from +0.0, as `std::simd::matrix` defines its products; they run on SME tiles where the CPU has them;
// - `dot` is 16 partial sums, lane j holding elements j, j + 16, j + 32, .. added by fused multiply-add from
//   +0.0, then summed by halves (`reduce_add_tree`).
// Element-wise operations (`+`, `-`, scaling) round once per element, as on `Vec`.

/// An element type of `LargeVec` and `LargeMat`: `f32` or `f64`.
pub interface LargeElem: Float + SimdFloat {
    /// `c = a * b` for row-major `a` (m x k), `b` (k x n), `c` (m x n), as `std::simd::matrix` computes it.
    fn mat_mul(c: []mut Self, a: []Self, b: []Self, m: usize, k: usize, n: usize);
}

extend f32 as LargeElem {
    pub fn mat_mul(c: []mut f32, a: []f32, b: []f32, m: usize, k: usize, n: usize) {
        matrix::mul_f32(c, a, b, m, k, n);
    }
}

extend f64 as LargeElem {
    pub fn mat_mul(c: []mut f64, a: []f64, b: []f64, m: usize, k: usize, n: usize) {
        matrix::mul_f64(c, a, b, m, k, n);
    }
}

// The 16-lane strided fused dot product of equal-length slices, as two 8-lane halves (lanes 0-7, 8-15):
// adding the halves is the first step of the 16-lane sum by halves.
fn dot_lanes<T: LargeElem>(a: []T, b: []T) T {
    let n = a.len();
    let nv = n - n % 16;
    let zero = Simd::<T, 8>::splat(T::zero());
    let mut lo = zero;
    let mut hi = zero;
    let mut i: usize = 0;
    while i < nv {
        lo = simd::load::<T, 8>(a, i).fma(simd::load::<T, 8>(b, i), lo);
        hi = simd::load::<T, 8>(a, i + 8).fma(simd::load::<T, 8>(b, i + 8), hi);
        i += 16;
    }
    if nv < n {
        // Padding lanes add 0 * 0 to +0.0 partial sums: no lane changes.
        lo = simd::load_or::<T, 8>(a, nv, zero).fma(simd::load_or::<T, 8>(b, nv, zero), lo);
        hi = simd::load_or::<T, 8>(a, nv + 8, zero).fma(simd::load_or::<T, 8>(b, nv + 8, zero), hi);
    }
    return simd::reduce_add_tree(lo + hi);
}

// c = a * b for column-major a (m x k), b (k x n) and c (m x n): element (i, j) is the fused chain over p
// in order from +0.0. The matrix kernel and the lanes compute the same bits. The lanes are faster for a
// product of at most 1024 multiply-adds, and for a matrix times a vector below 64 rows or from 2^20
// matrix elements on (measured on an M3 Max and on an M5 Pro); the kernel otherwise.
fn product<T: LargeElem>(c: []mut T, a: []T, b: []T, m: usize, k: usize, n: usize) {
    let lanes = if n == 1 {
        m < 64 || m * k > 1048576;
    } else {
        m * k * n <= 1024;
    };
    if !lanes {
        // Column-major storage read row-major is the transpose: c^T = b^T * a^T.
        T::mat_mul(c, b, a, n, k, m);
        return;
    }
    let mv = m - m % 8;
    for j in 0..n {
        let cj = j * m;
        for i in 0..m {
            c[cj + i] = T::zero();
        }
        for p in 0..k {
            let bp = b[j * k + p];
            let bv = Simd::<T, 8>::splat(bp);
            let ap = p * m;
            let mut i: usize = 0;
            while i < mv {
                simd::store(c, cj + i, simd::load::<T, 8>(a, ap + i).fma(bv, simd::load::<T, 8>(c, cj + i)));
                i += 8;
            }
            while i < m {
                c[cj + i] = a[ap + i].fma(bp, c[cj + i]);
                i += 1;
            }
        }
    }
}

/// A vector of `len()` elements on the heap.
pub struct LargeVec<T: LargeElem> {
    e: Vector<T>,
}

extend<T: LargeElem> LargeVec<T> {
    /// `n` zeros.
    pub fn zeros(n: usize) LargeVec<T> {
        return LargeVec::<T>::splat(n, T::zero());
    }

    /// `n` copies of `v`.
    pub fn splat(n: usize, v: T) LargeVec<T> {
        let mut e = Vector::<T>::with_capacity(n);
        for _ in 0..n {
            e.push(v);
        }
        return LargeVec::<T> { e: e };
    }

    /// A copy of `s`.
    pub fn from_slice(s: []T) LargeVec<T> {
        let mut e = Vector::<T>::with_capacity(s.len());
        for i in 0..s.len() {
            e.push(s[i]);
        }
        return LargeVec::<T> { e: e };
    }

    /// The components of `v`.
    pub fn from_vec<const N: usize>(v: Vec<T, N>) LargeVec<T> {
        return LargeVec::<T>::from_slice(v.e);
    }

    /// The element count.
    pub fn len(self: &LargeVec<T>) usize {
        return self.e.len();
    }

    /// The elements.
    pub fn as_slice(self: &LargeVec<T>) []T {
        return self.e[0..self.e.len()];
    }

    /// The elements, writable.
    pub fn as_mut_slice(self: &mut LargeVec<T>) []mut T {
        let n = self.e.len();
        return self.e.index_range_mut(0..n);
    }

    /// The fused dot product (16 strided partial sums, then summed by halves). Panics: lengths differ.
    pub fn dot(self: &LargeVec<T>, b: &LargeVec<T>) T {
        if self.len() != b.len() {
            panic("LargeVec::dot: the lengths differ");
        }
        return dot_lanes(self.as_slice(), b.as_slice());
    }

    /// `self.dot(self)`.
    pub fn length2(self: &LargeVec<T>) T {
        return dot_lanes(self.as_slice(), self.as_slice());
    }

    /// `sqrt(self.length2())`.
    pub fn length(self: &LargeVec<T>) T {
        return self.length2().sqrt();
    }

    /// `(b - self).length()`. Panics: lengths differ.
    pub fn distance(self: &LargeVec<T>, b: &LargeVec<T>) T {
        return (b - self).length();
    }

    /// `self` scaled to length 1 (a zero vector gives NaNs).
    pub fn normalized(self: &LargeVec<T>) LargeVec<T> {
        return self * (T::one() / self.length());
    }

    /// `self[i] = fma(a, x[i], self[i])` for every i. Panics: lengths differ.
    pub fn axpy(self: &mut LargeVec<T>, a: T, x: &LargeVec<T>) {
        if self.len() != x.len() {
            panic("LargeVec::axpy: the lengths differ");
        }
        let n = self.len();
        let nv = n - n % 8;
        let av = Simd::<T, 8>::splat(a);
        let xs = x.as_slice();
        let ys = self.as_mut_slice();
        let mut i: usize = 0;
        while i < nv {
            simd::store(ys, i, av.fma(simd::load::<T, 8>(xs, i), simd::load::<T, 8>(ys, i)));
            i += 8;
        }
        while i < n {
            ys[i] = a.fma(xs[i], ys[i]);
            i += 1;
        }
    }

    // Element-wise `self op b` (`b` subtracted when `sub`) of equal-length vectors; panics with `what`.
    fn zip(self: &LargeVec<T>, b: &LargeVec<T>, sub: bool, what: str) LargeVec<T> {
        if self.len() != b.len() {
            panic(what);
        }
        let mut e = Vector::<T>::with_capacity(self.len());
        for i in 0..self.len() {
            e.push(
                if sub {
                    self.e[i] - b.e[i];
                } else {
                    self.e[i] + b.e[i];
                },
            );
        }
        return LargeVec::<T> { e: e };
    }
}

extend<T: LargeElem> LargeVec<T> as Free {
    pub fn free(self: &mut LargeVec<T>) {
        self.e.free();
    }
}

extend<T: LargeElem> LargeVec<T> as Clone {
    pub fn clone(self: &LargeVec<T>) LargeVec<T> {
        return LargeVec::<T>::from_slice(self.as_slice());
    }
}

extend<T: LargeElem> LargeVec<T> as Index<T, []T> {
    pub fn index(self: &LargeVec<T>, i: usize) &T {
        return &self.e[i];
    }
    pub fn index_range(self: &LargeVec<T>, r: Range<usize>) []T {
        return self.e.index_range(r);
    }
}

extend<T: LargeElem> LargeVec<T> as IndexMut<T, []mut T> {
    pub fn index_mut(self: &mut LargeVec<T>, i: usize) &mut T {
        return self.e.index_mut(i);
    }
    pub fn index_range_mut(self: &mut LargeVec<T>, r: Range<usize>) []mut T {
        return self.e.index_range_mut(r);
    }
}

extend<T: LargeElem> LargeVec<T> as Add {
    type Output = LargeVec<T>;
    pub fn add(self: &LargeVec<T>, b: &LargeVec<T>) LargeVec<T> {
        return self.zip(b, false, "LargeVec + LargeVec: the lengths differ");
    }
}

extend<T: LargeElem> LargeVec<T> as Sub {
    type Output = LargeVec<T>;
    pub fn sub(self: &LargeVec<T>, b: &LargeVec<T>) LargeVec<T> {
        return self.zip(b, true, "LargeVec - LargeVec: the lengths differ");
    }
}

extend<T: LargeElem> LargeVec<T> as Mul<T> {
    type Output = LargeVec<T>;
    pub fn mul(self: &LargeVec<T>, s: &T) LargeVec<T> {
        let mut e = Vector::<T>::with_capacity(self.len());
        for i in 0..self.len() {
            e.push(self.e[i] * *s);
        }
        return LargeVec::<T> { e: e };
    }
}

/// A column-major matrix of `rows()` x `cols()` elements on the heap: element (i, j) is at `j * rows + i`.
pub struct LargeMat<T: LargeElem> {
    r: usize,
    c: usize,
    e: Vector<T>,
}

extend<T: LargeElem> LargeMat<T> {
    /// A `rows` x `cols` matrix of zeros.
    pub fn zeros(rows: usize, cols: usize) LargeMat<T> {
        let n = rows * cols;
        let mut e = Vector::<T>::with_capacity(n);
        for _ in 0..n {
            e.push(T::zero());
        }
        return LargeMat::<T> { r: rows, c: cols, e: e };
    }

    /// The `n` x `n` identity.
    pub fn identity(n: usize) LargeMat<T> {
        let mut m = LargeMat::<T>::zeros(n, n);
        for i in 0..n {
            m.e[i * n + i] = T::one();
        }
        return m;
    }

    /// A `rows` x `cols` matrix of the column-major elements `s`. Panics: `s.len() != rows * cols`.
    pub fn from_slice(rows: usize, cols: usize, s: []T) LargeMat<T> {
        if s.len() != rows * cols {
            panic("LargeMat::from_slice: the slice length is not rows * cols");
        }
        let mut e = Vector::<T>::with_capacity(s.len());
        for i in 0..s.len() {
            e.push(s[i]);
        }
        return LargeMat::<T> { r: rows, c: cols, e: e };
    }

    /// The elements of `m`.
    pub fn from_mat<const C: usize, const R: usize>(m: Mat<T, C, R>) LargeMat<T> {
        let mut e = Vector::<T>::with_capacity(C * R);
        for j in 0..C {
            for i in 0..R {
                e.push(m[j][i]);
            }
        }
        return LargeMat::<T> { r: R, c: C, e: e };
    }

    /// The row count.
    pub fn rows(self: &LargeMat<T>) usize {
        return self.r;
    }

    /// The column count.
    pub fn cols(self: &LargeMat<T>) usize {
        return self.c;
    }

    /// Element (i, j). Panics: out of bounds.
    pub fn get(self: &LargeMat<T>, i: usize, j: usize) T {
        if i >= self.r || j >= self.c {
            panic("LargeMat::get: index out of bounds");
        }
        return self.e[j * self.r + i];
    }

    /// Set element (i, j) to `v`. Panics: out of bounds.
    pub fn set(self: &mut LargeMat<T>, i: usize, j: usize, v: T) {
        if i >= self.r || j >= self.c {
            panic("LargeMat::set: index out of bounds");
        }
        let k = j * self.r + i;
        self.e[k] = v;
    }

    /// Column `j`. Panics: out of bounds.
    pub fn column(self: &LargeMat<T>, j: usize) []T {
        if j >= self.c {
            panic("LargeMat::column: index out of bounds");
        }
        return self.e[j * self.r..(j + 1) * self.r];
    }

    /// The column-major elements.
    pub fn as_slice(self: &LargeMat<T>) []T {
        return self.e[0..self.e.len()];
    }

    /// The transpose.
    pub fn transpose(self: &LargeMat<T>) LargeMat<T> {
        let mut t = LargeMat::<T>::zeros(self.c, self.r);
        for j in 0..self.c {
            for i in 0..self.r {
                t.e[i * self.c + j] = self.e[j * self.r + i];
            }
        }
        return t;
    }
}

extend<T: LargeElem> LargeMat<T> as Free {
    pub fn free(self: &mut LargeMat<T>) {
        self.e.free();
    }
}

extend<T: LargeElem> LargeMat<T> as Clone {
    pub fn clone(self: &LargeMat<T>) LargeMat<T> {
        return LargeMat::<T>::from_slice(self.r, self.c, self.as_slice());
    }
}

// `a * b`: element (i, j) the fused chain over p in order from +0.0.
extend<T: LargeElem> LargeMat<T> as Mul<LargeMat<T>> {
    type Output = LargeMat<T>;
    pub fn mul(self: &LargeMat<T>, b: &LargeMat<T>) LargeMat<T> {
        if self.c != b.r {
            panic("LargeMat * LargeMat: the left column count is not the right row count");
        }
        let mut out = LargeMat::<T>::zeros(self.r, b.c);
        let n = out.e.len();
        product(out.e.index_range_mut(0..n), self.as_slice(), b.as_slice(), self.r, self.c, b.c);
        return out;
    }
}

// `a * x`: element i the fused chain over p in order from +0.0.
extend<T: LargeElem> LargeMat<T> as Mul<LargeVec<T>> {
    type Output = LargeVec<T>;
    pub fn mul(self: &LargeMat<T>, x: &LargeVec<T>) LargeVec<T> {
        if self.c != x.len() {
            panic("LargeMat * LargeVec: the column count is not the vector length");
        }
        let mut y = LargeVec::<T>::zeros(self.r);
        product(y.as_mut_slice(), self.as_slice(), x.as_slice(), self.r, self.c, 1);
        return y;
    }
}

/// `a * b` with element (i, j) the fused chain over p in order from +0.0, as `LargeMat` defines it. Its
/// bits differ from `a * b`, which rounds each product and sum. Below 32 x 32 x 32 multiply-adds it runs
/// in registers, about as fast as `a * b`; from there on it runs the matrix kernel. Measured against
/// `a * b`: with SME (M5 Pro) 1.4 times as fast at 32 x 32 and 34 times at 64 x 64; without (M3 Max)
/// half as fast at 32 x 32 and 4.3 times as fast at 64 x 64.
pub fn mul_fused<T: LargeElem, const C: usize, const R: usize, const K: usize>(a: Mat<T, C, R>, b: Mat<T, K, C>) Mat<
    T,
    K,
    R
> {
    let mut out = Mat::<T, K, R>::zero();
    if C * R * K < 32768 {
        for j in 0..K {
            for p in 0..C {
                unsafe {
                    let s = b.c[j].e[p];
                    for i in 0..R {
                        out.c[j].e[i] = a.c[p].e[i].fma(s, out.c[j].e[i]);
                    }
                }
            }
        }
        return out;
    }
    let av = unsafe Slice::<T> { ptr: &a.c[0].e[0], len: C * R };
    let bv = unsafe Slice::<T> { ptr: &b.c[0].e[0], len: K * C };
    let ov = unsafe SliceMut::<T> { ptr: &mut out.c[0].e[0], len: K * R };
    product(ov, av, bv, R, C, K);
    return out;
}
