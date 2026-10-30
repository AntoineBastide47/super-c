// Fused forms of the vector functions whose arithmetic is a sum of squares: each square after the first is
// added with one rounding (`fma`), in index order. No square can cancel another, so these keep every exact
// property of the unfused functions, are at least as accurate, and run faster where the CPU has a fused
// multiply-add. Their results differ in the last bits from `length`, `distance` and `normalize`.
// Products whose terms can cancel (`dot`, the matrix products, `cross`, the quaternion product,
// `determinant`) have no fused form on `Vec` and `Mat`: fusing them breaks exact results such as
// `cross(a, a) == 0`, `dot(v, perp(v)) == 0` or a zero determinant for two equal columns.
//
// `LargeVec` and `LargeMat` (below) are heap-backed and of run-time size, for sizes where `Vec` and `Mat`
// stop scaling, of every element type. A float's products are fused by definition (f32 and f64 run on SME
// tiles where the CPU has them); `mul_fused` gives a float `Mat` product the same definition.
import std::float as sf;
import std::int as si;
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
// - a float's element (i, j) of `a * b` and element i of `a * x` are the fused chain over the inner index p,
//   in order, from +0.0, as `std::simd::matrix` defines its products (f32 and f64 run on SME tiles where the
//   CPU has them); an integer's are `c + a * b` over p in order from 0, in the type's arithmetic;
// - a float's `dot` is 16 partial sums, lane j holding elements j, j + 16, j + 32, .. added by fused
//   multiply-add from +0.0, then summed by halves (`reduce_add_tree`); an integer's is the sum in index order.
// Element-wise operations (`+`, `-`, scaling) are the element type's, as on `Vec`.

/// An element type of `LargeVec` and `LargeMat`: every `Scalar`. f32 and f64 run the SIMD and matrix kernels,
/// the other types scalar loops of the same definitions.
pub interface LargeElem: Scalar {
    /// The dot product of equal-length slices.
    fn dot_of(a: []Self, b: []Self) Self;
    /// `c = a * b` for column-major a (m x k), b (k x n) and c (m x n).
    fn product_of(c: []mut Self, a: []Self, b: []Self, m: usize, k: usize, n: usize);
    /// `y[i] = a * x[i] + y[i]` for every i of equal-length slices, rounded once for a float.
    fn axpy_of(y: []mut Self, a: Self, x: []Self);
}

// f32 and f64: the matrix kernel of `std::simd::matrix`, row-major `c = a * b`.
interface MatKernel: Float + SimdFloat {
    fn mat_mul(c: []mut Self, a: []Self, b: []Self, m: usize, k: usize, n: usize);
}

extend f32 as MatKernel {
    pub fn mat_mul(c: []mut f32, a: []f32, b: []f32, m: usize, k: usize, n: usize) {
        matrix::mul_f32(c, a, b, m, k, n);
    }
}

extend f64 as MatKernel {
    pub fn mat_mul(c: []mut f64, a: []f64, b: []f64, m: usize, k: usize, n: usize) {
        matrix::mul_f64(c, a, b, m, k, n);
    }
}

// The 16-lane strided fused dot product of equal-length slices, as two 8-lane halves (lanes 0-7, 8-15):
// adding the halves is the first step of the 16-lane sum by halves.
fn dot_lanes<T: MatKernel>(a: []T, b: []T) T {
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

// The product by the matrix kernel or by lanes, the same bits. The lanes are faster for a product of at
// most 1024 multiply-adds, and for a matrix times a vector below 64 rows or from 2^20 matrix elements on
// (measured on an M3 Max and on an M5 Pro); the kernel otherwise.
fn product_lanes<T: MatKernel>(c: []mut T, a: []T, b: []T, m: usize, k: usize, n: usize) {
    let lanes = if n == 1 {
        m < 64 || m * k > 1048576
    } else {
        m * k * n <= 1024
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

fn axpy_lanes<T: MatKernel>(y: []mut T, a: T, x: []T) {
    let n = y.len();
    let nv = n - n % 8;
    let av = Simd::<T, 8>::splat(a);
    let mut i: usize = 0;
    while i < nv {
        simd::store(y, i, av.fma(simd::load::<T, 8>(x, i), simd::load::<T, 8>(y, i)));
        i += 8;
    }
    while i < n {
        y[i] = a.fma(x[i], y[i]);
        i += 1;
    }
}

extend f32 as LargeElem {
    pub fn dot_of(a: []f32, b: []f32) f32 {
        return dot_lanes(a, b);
    }
    pub fn product_of(c: []mut f32, a: []f32, b: []f32, m: usize, k: usize, n: usize) {
        product_lanes(c, a, b, m, k, n);
    }
    pub fn axpy_of(y: []mut f32, a: f32, x: []f32) {
        axpy_lanes(y, a, x);
    }
}

extend f64 as LargeElem {
    pub fn dot_of(a: []f64, b: []f64) f64 {
        return dot_lanes(a, b);
    }
    pub fn product_of(c: []mut f64, a: []f64, b: []f64, m: usize, k: usize, n: usize) {
        product_lanes(c, a, b, m, k, n);
    }
    pub fn axpy_of(y: []mut f64, a: f64, x: []f64) {
        axpy_lanes(y, a, x);
    }
}

// The float formats: the definitions as scalar loops.
fn dot_fused<T: Float>(a: []T, b: []T) T {
    let mut acc: [T; 16] = [T::zero(); 16];
    for i in 0..a.len() {
        unsafe {
            acc[i % 16] = a[i].fma(b[i], acc[i % 16]);
        }
    }
    let mut w: usize = 8;
    while w >= 1 {
        for j in 0..w {
            unsafe {
                acc[j] = acc[j] + acc[j + w];
            }
        }
        w /= 2;
    }
    return acc[0];
}

fn product_fused<T: Float>(c: []mut T, a: []T, b: []T, m: usize, k: usize, n: usize) {
    for j in 0..n {
        for i in 0..m {
            let mut s = T::zero();
            for p in 0..k {
                s = a[p * m + i].fma(b[j * k + p], s);
            }
            c[j * m + i] = s;
        }
    }
}

fn axpy_fused<T: Float>(y: []mut T, a: T, x: []T) {
    for i in 0..y.len() {
        y[i] = a.fma(x[i], y[i]);
    }
}

extend<const E: usize, const F: usize, const FAM: sf::FloatFamily> sf::Float<E, F, FAM> as LargeElem {
    pub fn dot_of(a: []sf::Float<E, F, FAM>, b: []sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return dot_fused(a, b);
    }
    pub fn product_of(
        c: []mut sf::Float<E, F, FAM>,
        a: []sf::Float<E, F, FAM>,
        b: []sf::Float<E, F, FAM>,
        m: usize,
        k: usize,
        n: usize,
    ) {
        product_fused(c, a, b, m, k, n);
    }
    pub fn axpy_of(y: []mut sf::Float<E, F, FAM>, a: sf::Float<E, F, FAM>, x: []sf::Float<E, F, FAM>) {
        axpy_fused(y, a, x);
    }
}

// The integers: the sums in order, in the type's arithmetic.
fn dot_int<T: Scalar>(a: []T, b: []T) T {
    let mut s = T::zero();
    for i in 0..a.len() {
        s = s + a[i] * b[i];
    }
    return s;
}

fn product_int<T: Scalar>(c: []mut T, a: []T, b: []T, m: usize, k: usize, n: usize) {
    for j in 0..n {
        for i in 0..m {
            let mut s = T::zero();
            for p in 0..k {
                s = s + a[p * m + i] * b[j * k + p];
            }
            c[j * m + i] = s;
        }
    }
}

const fn axpy_int<T: Scalar>(y: []mut T, a: T, x: []T) {
    for i in 0..y.len() {
        y[i] = a * x[i] + y[i];
    }
}

extend i8 as LargeElem {
    pub fn dot_of(a: []i8, b: []i8) i8 {
        return dot_int(a, b);
    }
    pub fn product_of(c: []mut i8, a: []i8, b: []i8, m: usize, k: usize, n: usize) {
        product_int(c, a, b, m, k, n);
    }
    pub fn axpy_of(y: []mut i8, a: i8, x: []i8) {
        axpy_int(y, a, x);
    }
}

extend i16 as LargeElem {
    pub fn dot_of(a: []i16, b: []i16) i16 {
        return dot_int(a, b);
    }
    pub fn product_of(c: []mut i16, a: []i16, b: []i16, m: usize, k: usize, n: usize) {
        product_int(c, a, b, m, k, n);
    }
    pub fn axpy_of(y: []mut i16, a: i16, x: []i16) {
        axpy_int(y, a, x);
    }
}

extend i32 as LargeElem {
    pub fn dot_of(a: []i32, b: []i32) i32 {
        return dot_int(a, b);
    }
    pub fn product_of(c: []mut i32, a: []i32, b: []i32, m: usize, k: usize, n: usize) {
        product_int(c, a, b, m, k, n);
    }
    pub fn axpy_of(y: []mut i32, a: i32, x: []i32) {
        axpy_int(y, a, x);
    }
}

extend i64 as LargeElem {
    pub fn dot_of(a: []i64, b: []i64) i64 {
        return dot_int(a, b);
    }
    pub fn product_of(c: []mut i64, a: []i64, b: []i64, m: usize, k: usize, n: usize) {
        product_int(c, a, b, m, k, n);
    }
    pub fn axpy_of(y: []mut i64, a: i64, x: []i64) {
        axpy_int(y, a, x);
    }
}

extend u8 as LargeElem {
    pub fn dot_of(a: []u8, b: []u8) u8 {
        return dot_int(a, b);
    }
    pub fn product_of(c: []mut u8, a: []u8, b: []u8, m: usize, k: usize, n: usize) {
        product_int(c, a, b, m, k, n);
    }
    pub fn axpy_of(y: []mut u8, a: u8, x: []u8) {
        axpy_int(y, a, x);
    }
}

extend u16 as LargeElem {
    pub fn dot_of(a: []u16, b: []u16) u16 {
        return dot_int(a, b);
    }
    pub fn product_of(c: []mut u16, a: []u16, b: []u16, m: usize, k: usize, n: usize) {
        product_int(c, a, b, m, k, n);
    }
    pub fn axpy_of(y: []mut u16, a: u16, x: []u16) {
        axpy_int(y, a, x);
    }
}

extend u32 as LargeElem {
    pub fn dot_of(a: []u32, b: []u32) u32 {
        return dot_int(a, b);
    }
    pub fn product_of(c: []mut u32, a: []u32, b: []u32, m: usize, k: usize, n: usize) {
        product_int(c, a, b, m, k, n);
    }
    pub fn axpy_of(y: []mut u32, a: u32, x: []u32) {
        axpy_int(y, a, x);
    }
}

extend u64 as LargeElem {
    pub fn dot_of(a: []u64, b: []u64) u64 {
        return dot_int(a, b);
    }
    pub fn product_of(c: []mut u64, a: []u64, b: []u64, m: usize, k: usize, n: usize) {
        product_int(c, a, b, m, k, n);
    }
    pub fn axpy_of(y: []mut u64, a: u64, x: []u64) {
        axpy_int(y, a, x);
    }
}

extend<const B: usize> si::Int<B> as LargeElem {
    pub fn dot_of(a: []si::Int<B>, b: []si::Int<B>) si::Int<B> {
        return dot_int(a, b);
    }
    pub fn product_of(c: []mut si::Int<B>, a: []si::Int<B>, b: []si::Int<B>, m: usize, k: usize, n: usize) {
        product_int(c, a, b, m, k, n);
    }
    pub fn axpy_of(y: []mut si::Int<B>, a: si::Int<B>, x: []si::Int<B>) {
        axpy_int(y, a, x);
    }
}

extend<const B: usize> si::UInt<B> as LargeElem {
    pub fn dot_of(a: []si::UInt<B>, b: []si::UInt<B>) si::UInt<B> {
        return dot_int(a, b);
    }
    pub fn product_of(c: []mut si::UInt<B>, a: []si::UInt<B>, b: []si::UInt<B>, m: usize, k: usize, n: usize) {
        product_int(c, a, b, m, k, n);
    }
    pub fn axpy_of(y: []mut si::UInt<B>, a: si::UInt<B>, x: []si::UInt<B>) {
        axpy_int(y, a, x);
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
    pub const fn len(self: &LargeVec<T>) usize {
        return self.e.len();
    }

    /// The elements.
    pub const fn as_slice(self: &LargeVec<T>) []T {
        return self.e[0..self.e.len()];
    }

    /// The elements, writable.
    pub const fn as_mut_slice(self: &mut LargeVec<T>) []mut T {
        let n = self.e.len();
        return self.e.index_range_mut(0..n);
    }

    /// The dot product (a float's: 16 strided fused partial sums, then summed by halves). Panics: lengths
    /// differ.
    pub fn dot(self: &LargeVec<T>, b: &LargeVec<T>) T {
        if self.len() != b.len() {
            panic("LargeVec::dot: the lengths differ");
        }
        return T::dot_of(self.as_slice(), b.as_slice());
    }

    /// `self.dot(self)`.
    pub fn length2(self: &LargeVec<T>) T {
        return T::dot_of(self.as_slice(), self.as_slice());
    }

    /// `self[i] = a * x[i] + self[i]` for every i, rounded once for a float. Panics: lengths differ.
    pub fn axpy(self: &mut LargeVec<T>, a: T, x: &LargeVec<T>) {
        if self.len() != x.len() {
            panic("LargeVec::axpy: the lengths differ");
        }
        T::axpy_of(self.as_mut_slice(), a, x.as_slice());
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
                    self.e[i] - b.e[i]
                } else {
                    self.e[i] + b.e[i]
                },
            );
        }
        return LargeVec::<T> { e: e };
    }
}

extend<T: LargeElem + Float> LargeVec<T> {
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
    pub const fn rows(self: &LargeMat<T>) usize {
        return self.r;
    }

    /// The column count.
    pub const fn cols(self: &LargeMat<T>) usize {
        return self.c;
    }

    /// Element (i, j). Panics: out of bounds.
    pub const fn get(self: &LargeMat<T>, i: usize, j: usize) T {
        if i >= self.r || j >= self.c {
            panic("LargeMat::get: index out of bounds");
        }
        return self.e[j * self.r + i];
    }

    /// Set element (i, j) to `v`. Panics: out of bounds.
    pub const fn set(self: &mut LargeMat<T>, i: usize, j: usize, v: T) {
        if i >= self.r || j >= self.c {
            panic("LargeMat::set: index out of bounds");
        }
        let k = j * self.r + i;
        self.e[k] = v;
    }

    /// Column `j`. Panics: out of bounds.
    pub const fn column(self: &LargeMat<T>, j: usize) []T {
        if j >= self.c {
            panic("LargeMat::column: index out of bounds");
        }
        return self.e[j * self.r..(j + 1) * self.r];
    }

    /// The column-major elements.
    pub const fn as_slice(self: &LargeMat<T>) []T {
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
        T::product_of(out.e.index_range_mut(0..n), self.as_slice(), b.as_slice(), self.r, self.c, b.c);
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
        T::product_of(y.as_mut_slice(), self.as_slice(), x.as_slice(), self.r, self.c, 1);
        return y;
    }
}

/// `a * b` with element (i, j) the fused chain over p in order from +0.0, as `LargeMat` defines it. Its
/// bits differ from `a * b`, which rounds each product and sum. Below 32 x 32 x 32 multiply-adds it runs
/// in registers, about as fast as `a * b`; from there on it runs the matrix kernel. Measured against
/// `a * b`: with SME (M5 Pro) 1.4 times as fast at 32 x 32 and 34 times at 64 x 64; without (M3 Max)
/// half as fast at 32 x 32 and 4.3 times as fast at 64 x 64.
pub fn mul_fused<T: LargeElem + Float, const C: usize, const R: usize, const K: usize>(a: Mat<T, C, R>, b: Mat<T, K, C>) Mat<
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
    T::product_of(ov, av, bv, R, C, K);
    return out;
}
