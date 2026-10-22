// `Vec<T, N>`: N components of an `Elem`, stored as `[T; N]` with the layout of the array. Arithmetic,
// bitwise and comparison operators work component by component in component order; `==` is true when
// every component is IEEE-equal. The aliases (`vec3`, `dvec2`, `ivec4`, `bvec3`, `u8vec2`, ..) name the
// instances.
import std::math::scalar as *;

/// N components of type `T`, `e[0]` first (x, then y, z, w).
pub struct Vec<T: Elem, const N: usize> {
    pub e: [T; N],
}

pub type vec1 = Vec<f32, 1>;
pub type vec2 = Vec<f32, 2>;
pub type vec3 = Vec<f32, 3>;
pub type vec4 = Vec<f32, 4>;
pub type fvec1 = Vec<f32, 1>;
pub type fvec2 = Vec<f32, 2>;
pub type fvec3 = Vec<f32, 3>;
pub type fvec4 = Vec<f32, 4>;
pub type f32vec1 = Vec<f32, 1>;
pub type f32vec2 = Vec<f32, 2>;
pub type f32vec3 = Vec<f32, 3>;
pub type f32vec4 = Vec<f32, 4>;
pub type dvec1 = Vec<f64, 1>;
pub type dvec2 = Vec<f64, 2>;
pub type dvec3 = Vec<f64, 3>;
pub type dvec4 = Vec<f64, 4>;
pub type f64vec1 = Vec<f64, 1>;
pub type f64vec2 = Vec<f64, 2>;
pub type f64vec3 = Vec<f64, 3>;
pub type f64vec4 = Vec<f64, 4>;
pub type bvec1 = Vec<bool, 1>;
pub type bvec2 = Vec<bool, 2>;
pub type bvec3 = Vec<bool, 3>;
pub type bvec4 = Vec<bool, 4>;
pub type ivec1 = Vec<i32, 1>;
pub type ivec2 = Vec<i32, 2>;
pub type ivec3 = Vec<i32, 3>;
pub type ivec4 = Vec<i32, 4>;
pub type uvec1 = Vec<u32, 1>;
pub type uvec2 = Vec<u32, 2>;
pub type uvec3 = Vec<u32, 3>;
pub type uvec4 = Vec<u32, 4>;
pub type i8vec1 = Vec<i8, 1>;
pub type i8vec2 = Vec<i8, 2>;
pub type i8vec3 = Vec<i8, 3>;
pub type i8vec4 = Vec<i8, 4>;
pub type i16vec1 = Vec<i16, 1>;
pub type i16vec2 = Vec<i16, 2>;
pub type i16vec3 = Vec<i16, 3>;
pub type i16vec4 = Vec<i16, 4>;
pub type i32vec1 = Vec<i32, 1>;
pub type i32vec2 = Vec<i32, 2>;
pub type i32vec3 = Vec<i32, 3>;
pub type i32vec4 = Vec<i32, 4>;
pub type i64vec1 = Vec<i64, 1>;
pub type i64vec2 = Vec<i64, 2>;
pub type i64vec3 = Vec<i64, 3>;
pub type i64vec4 = Vec<i64, 4>;
pub type u8vec1 = Vec<u8, 1>;
pub type u8vec2 = Vec<u8, 2>;
pub type u8vec3 = Vec<u8, 3>;
pub type u8vec4 = Vec<u8, 4>;
pub type u16vec1 = Vec<u16, 1>;
pub type u16vec2 = Vec<u16, 2>;
pub type u16vec3 = Vec<u16, 3>;
pub type u16vec4 = Vec<u16, 4>;
pub type u32vec1 = Vec<u32, 1>;
pub type u32vec2 = Vec<u32, 2>;
pub type u32vec3 = Vec<u32, 3>;
pub type u32vec4 = Vec<u32, 4>;
pub type u64vec1 = Vec<u64, 1>;
pub type u64vec2 = Vec<u64, 2>;
pub type u64vec3 = Vec<u64, 3>;
pub type u64vec4 = Vec<u64, 4>;

extend<T: Elem, const N: usize> Vec<T, N> {
    /// The number of components.
    pub const LEN: usize = N;

    /// The number of components, N; an open-ended range (`v[1..]`) ends there.
    pub const fn len(self: &Vec<T, N>) usize {
        return N;
    }

    /// Every component `s`.
    pub const fn splat(s: T) Vec<T, N> {
        return Vec::<T, N> { e: [s; N] };
    }
    pub const fn from_array(a: [T; N]) Vec<T, N> {
        return Vec::<T, N> { e: a };
    }
    pub const fn to_array(self: Vec<T, N>) [T; N] {
        return self.e;
    }
    /// The components `I`, `J`: `v.swizzle2::<1, 0>()` is y, then x. An index of N or more is a compile
    /// error.
    pub const fn swizzle2<const I: usize, const J: usize>(self: Vec<T, N>) Vec<T, 2> {
        static_assert(I < N && J < N, "swizzle index out of range");
        return Vec::<T, 2> { e: [unsafe self.e[I], unsafe self.e[J]] };
    }
    /// The components `I`, `J`, `K`.
    pub const fn swizzle3<const I: usize, const J: usize, const K: usize>(self: Vec<T, N>) Vec<T, 3> {
        static_assert(I < N && J < N && K < N, "swizzle index out of range");
        return Vec::<T, 3> { e: [unsafe self.e[I], unsafe self.e[J], unsafe self.e[K]] };
    }
    /// The components `I`, `J`, `K`, `L`.
    pub const fn swizzle4<const I: usize, const J: usize, const K: usize, const L: usize>(self: Vec<T, N>) Vec<T, 4> {
        static_assert(I < N && J < N && K < N && L < N, "swizzle index out of range");
        return Vec::<T, 4> { e: [unsafe self.e[I], unsafe self.e[J], unsafe self.e[K], unsafe self.e[L]] };
    }
    /// The first M components, M <= N. A longer M is a compile error.
    pub fn truncate<const M: usize>(self: Vec<T, N>) Vec<T, M> {
        static_assert(M <= N, "truncate to more components than the vector has");
        let mut r = Vec::<T, M> { e: [unsafe self.e[0]; M] };
        for i in 0..M {
            unsafe {
                r.e[i] = self.e[i];
            }
        }
        return r;
    }
    /// `self` followed by `s`: N + 1 components.
    pub fn append(self: Vec<T, N>, s: T) Vec<T, {N + 1}> {
        let mut r = Vec::<T, {N + 1}> { e: [s; N + 1] };
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i];
            }
        }
        return r;
    }
    /// `self` followed by `b`: N + M components.
    pub fn concat<const M: usize>(self: Vec<T, N>, b: Vec<T, M>) Vec<T, {N + M}> {
        let mut r = Vec::<T, {N + M}> { e: [unsafe b.e[0]; N + M] };
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i];
            }
        }
        for i in 0..M {
            unsafe {
                r.e[N + i] = b.e[i];
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> {
    /// Every component zero.
    pub fn zero() Vec<T, N> {
        return Vec::<T, N> { e: [T::zero(); N] };
    }
    /// Each component converted to `U` with `as`, once from the exact value.
    pub fn cast<U: Scalar>(self: Vec<T, N>) Vec<U, N> {
        let mut r = Vec::<U, N> { e: [U::zero(); N] };
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].cast::<U>();
            }
        }
        return r;
    }
}

/// A scalar or vector of `T`: `T` itself or a `Vec<T, N>`. A function generic over it works component
/// by component, so it serves scalars and vectors alike.
pub interface Gen<T: Scalar>: Copy {
    /// 1 for a scalar, N for a vector.
    fn len() usize;
    /// Component `i`.
    fn at(self: &Self, i: usize) T;
    /// Set component `i` to `v`.
    fn put(self: &mut Self, i: usize, v: T);
    /// Every component `v`.
    fn of(v: T) Self;
}

extend<T: Scalar> T as Gen<T> {
    pub fn len() usize {
        return 1;
    }
    pub fn at(self: &T, i: usize) T {
        return *self;
    }
    pub fn put(self: &mut T, i: usize, v: T) {
        *self = v;
    }
    pub fn of(v: T) T {
        return v;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Gen<T> {
    pub fn len() usize {
        return N;
    }
    pub fn at(self: &Vec<T, N>, i: usize) T {
        return unsafe self.e[i];
    }
    pub fn put(self: &mut Vec<T, N>, i: usize, v: T) {
        unsafe {
            self.e[i] = v;
        }
    }
    pub fn of(v: T) Vec<T, N> {
        return Vec::<T, N> { e: [v; N] };
    }
}

/// An argument that takes `G` or its component: `G` itself, or `T` broadcast to every component
/// (`clamp(v, 0.0, 1.0)`).
pub interface Arg<G>: Copy {
    fn to_gen(self: Self) G;
}

extend<T: Scalar> T as Arg<T> {
    pub fn to_gen(self: T) T {
        return self;
    }
}

extend<T: Scalar, const N: usize> T as Arg<Vec<T, N>> {
    pub fn to_gen(self: T) Vec<T, N> {
        return Vec::<T, N> { e: [self; N] };
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Arg<Vec<T, N>> {
    pub fn to_gen(self: Vec<T, N>) Vec<T, N> {
        return self;
    }
}

extend<T: Elem> Vec<T, 1> {
    pub const fn new(x: T) Vec<T, 1> {
        return Vec::<T, 1> { e: [x] };
    }
    pub const fn x(self: Vec<T, 1>) T {
        return self.e[0];
    }
    pub const fn r(self: Vec<T, 1>) T {
        return self.e[0];
    }
}

extend<T: Elem> Vec<T, 2> {
    pub const fn new(x: T, y: T) Vec<T, 2> {
        return Vec::<T, 2> { e: [x, y] };
    }
    pub const fn x(self: Vec<T, 2>) T {
        return self.e[0];
    }
    pub const fn y(self: Vec<T, 2>) T {
        return self.e[1];
    }
    pub const fn r(self: Vec<T, 2>) T {
        return self.e[0];
    }
    pub const fn g(self: Vec<T, 2>) T {
        return self.e[1];
    }
}

extend<T: Elem> Vec<T, 3> {
    pub const fn new(x: T, y: T, z: T) Vec<T, 3> {
        return Vec::<T, 3> { e: [x, y, z] };
    }
    pub const fn x(self: Vec<T, 3>) T {
        return self.e[0];
    }
    pub const fn y(self: Vec<T, 3>) T {
        return self.e[1];
    }
    pub const fn z(self: Vec<T, 3>) T {
        return self.e[2];
    }
    pub const fn r(self: Vec<T, 3>) T {
        return self.e[0];
    }
    pub const fn g(self: Vec<T, 3>) T {
        return self.e[1];
    }
    pub const fn b(self: Vec<T, 3>) T {
        return self.e[2];
    }
    /// The x and y components.
    pub const fn xy(self: Vec<T, 3>) Vec<T, 2> {
        return Vec::<T, 2> { e: [self.e[0], self.e[1]] };
    }
}

extend<T: Elem> Vec<T, 4> {
    pub const fn new(x: T, y: T, z: T, w: T) Vec<T, 4> {
        return Vec::<T, 4> { e: [x, y, z, w] };
    }
    pub const fn x(self: Vec<T, 4>) T {
        return self.e[0];
    }
    pub const fn y(self: Vec<T, 4>) T {
        return self.e[1];
    }
    pub const fn z(self: Vec<T, 4>) T {
        return self.e[2];
    }
    pub const fn w(self: Vec<T, 4>) T {
        return self.e[3];
    }
    pub const fn r(self: Vec<T, 4>) T {
        return self.e[0];
    }
    pub const fn g(self: Vec<T, 4>) T {
        return self.e[1];
    }
    pub const fn b(self: Vec<T, 4>) T {
        return self.e[2];
    }
    pub const fn a(self: Vec<T, 4>) T {
        return self.e[3];
    }
    /// The x and y components.
    pub const fn xy(self: Vec<T, 4>) Vec<T, 2> {
        return Vec::<T, 2> { e: [self.e[0], self.e[1]] };
    }
    /// The x, y and z components.
    pub const fn xyz(self: Vec<T, 4>) Vec<T, 3> {
        return Vec::<T, 3> { e: [self.e[0], self.e[1], self.e[2]] };
    }
}

// `v[i]` is component `i`; an index of N or more traps.
extend<T: Elem, const N: usize> Vec<T, N> as Index<T, []T> {
    pub fn index(self: &Vec<T, N>, i: usize) &T {
        if i >= N {
            panic("Vec<T, N>[i]: index out of bounds");
        }
        return &unsafe self.e[i];
    }
    pub fn index_range(self: &Vec<T, N>, r: Range<usize>) []T {
        let (lo, hi) = range_bounds(r, N);
        return unsafe Slice::<T> { ptr: (&self.e[0]) as *const T + lo, len: hi - lo };
    }
}

// The half-open bounds of `r` within `[0, n)`; a range outside traps.
const fn range_bounds(r: Range<usize>, n: usize) (usize, usize) {
    let hi = if r.inclusive {
        r.end + 1;
    } else {
        r.end;
    };
    if r.start > hi || hi > n {
        panic("Vec<T, N>[a..b]: range out of bounds");
    }
    return r.start, hi;
}

extend<T: Elem, const N: usize> Vec<T, N> as IndexMut<T, []mut T> {
    pub fn index_mut(self: &mut Vec<T, N>, i: usize) &mut T {
        if i >= N {
            panic("Vec<T, N>[i]: index out of bounds");
        }
        return &mut unsafe self.e[i];
    }
    pub fn index_range_mut(self: &mut Vec<T, N>, r: Range<usize>) []mut T {
        let (lo, hi) = range_bounds(r, N);
        return unsafe SliceMut::<T> { ptr: (&mut self.e[0]) as *mut T + lo, len: hi - lo };
    }
}

// `&` of two bool vectors: logical and, component by component (`&&` takes only `bool`).
extend<const N: usize> Vec<bool, N> as BitAnd {
    type Output = Vec<bool, N>;
    pub fn bit_and(self: &Vec<bool, N>, other: &Vec<bool, N>) Vec<bool, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] && other.e[i];
            }
        }
        return r;
    }
}

// `|` of two bool vectors: logical or, component by component.
extend<const N: usize> Vec<bool, N> as BitOr {
    type Output = Vec<bool, N>;
    pub fn bit_or(self: &Vec<bool, N>, other: &Vec<bool, N>) Vec<bool, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] || other.e[i];
            }
        }
        return r;
    }
}

// `==`: every component equal, IEEE for floats; `!=` is its negation.
extend<T: Elem, const N: usize> Vec<T, N> as Eq {
    pub fn eq(self: &Vec<T, N>, other: &Vec<T, N>) bool {
        for i in 0..N {
            if !unsafe self.e[i].equal(other.e[i]) {
                return false;
            }
        }
        return true;
    }
}

// Negation of a vec1 or vec2 negates each component; negation of a vec3 or vec4 computes `0 - v`. The
// two differ on a zero: -(+0) is -0, 0 - (+0) is +0.
extend<T: Scalar, const N: usize> Vec<T, N> as Neg {
    type Output = Vec<T, N>;
    pub fn neg(self: &Vec<T, N>) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = if N >= 3 {
                    T::zero() - self.e[i];
                } else {
                    -self.e[i];
                };
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Add {
    type Output = Vec<T, N>;
    pub fn add(self: &Vec<T, N>, other: &Vec<T, N>) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] + other.e[i];
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Sub {
    type Output = Vec<T, N>;
    pub fn sub(self: &Vec<T, N>, other: &Vec<T, N>) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] - other.e[i];
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Mul {
    type Output = Vec<T, N>;
    pub fn mul(self: &Vec<T, N>, other: &Vec<T, N>) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] * other.e[i];
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Div {
    type Output = Vec<T, N>;
    pub fn div(self: &Vec<T, N>, other: &Vec<T, N>) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] / other.e[i];
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Add<T> {
    type Output = Vec<T, N>;
    pub fn add(self: &Vec<T, N>, s: &T) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] + *s;
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Sub<T> {
    type Output = Vec<T, N>;
    pub fn sub(self: &Vec<T, N>, s: &T) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] - *s;
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Mul<T> {
    type Output = Vec<T, N>;
    pub fn mul(self: &Vec<T, N>, s: &T) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] * *s;
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Div<T> {
    type Output = Vec<T, N>;
    pub fn div(self: &Vec<T, N>, s: &T) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] / *s;
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> T as Add<Vec<T, N>> {
    type Output = Vec<T, N>;
    pub fn add(self: &T, v: &Vec<T, N>) Vec<T, N> {
        let mut r = *v;
        for i in 0..N {
            unsafe {
                r.e[i] = *self + v.e[i];
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> T as Sub<Vec<T, N>> {
    type Output = Vec<T, N>;
    pub fn sub(self: &T, v: &Vec<T, N>) Vec<T, N> {
        let mut r = *v;
        for i in 0..N {
            unsafe {
                r.e[i] = *self - v.e[i];
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> T as Mul<Vec<T, N>> {
    type Output = Vec<T, N>;
    pub fn mul(self: &T, v: &Vec<T, N>) Vec<T, N> {
        let mut r = *v;
        for i in 0..N {
            unsafe {
                r.e[i] = *self * v.e[i];
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> T as Div<Vec<T, N>> {
    type Output = Vec<T, N>;
    pub fn div(self: &T, v: &Vec<T, N>) Vec<T, N> {
        let mut r = *v;
        for i in 0..N {
            unsafe {
                r.e[i] = *self / v.e[i];
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> Vec<T, N> as Rem {
    type Output = Vec<T, N>;
    pub fn rem(self: &Vec<T, N>, other: &Vec<T, N>) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] % other.e[i];
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> Vec<T, N> as Rem<T> {
    type Output = Vec<T, N>;
    pub fn rem(self: &Vec<T, N>, s: &T) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] % *s;
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> T as Rem<Vec<T, N>> {
    type Output = Vec<T, N>;
    pub fn rem(self: &T, v: &Vec<T, N>) Vec<T, N> {
        let mut r = *v;
        for i in 0..N {
            unsafe {
                r.e[i] = *self % v.e[i];
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> Vec<T, N> as BitAnd {
    type Output = Vec<T, N>;
    pub fn bit_and(self: &Vec<T, N>, other: &Vec<T, N>) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] & other.e[i];
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> Vec<T, N> as BitAnd<T> {
    type Output = Vec<T, N>;
    pub fn bit_and(self: &Vec<T, N>, s: &T) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] & *s;
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> T as BitAnd<Vec<T, N>> {
    type Output = Vec<T, N>;
    pub fn bit_and(self: &T, v: &Vec<T, N>) Vec<T, N> {
        let mut r = *v;
        for i in 0..N {
            unsafe {
                r.e[i] = *self & v.e[i];
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> Vec<T, N> as BitOr {
    type Output = Vec<T, N>;
    pub fn bit_or(self: &Vec<T, N>, other: &Vec<T, N>) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] | other.e[i];
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> Vec<T, N> as BitOr<T> {
    type Output = Vec<T, N>;
    pub fn bit_or(self: &Vec<T, N>, s: &T) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] | *s;
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> T as BitOr<Vec<T, N>> {
    type Output = Vec<T, N>;
    pub fn bit_or(self: &T, v: &Vec<T, N>) Vec<T, N> {
        let mut r = *v;
        for i in 0..N {
            unsafe {
                r.e[i] = *self | v.e[i];
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> Vec<T, N> as BitXor {
    type Output = Vec<T, N>;
    pub fn bit_xor(self: &Vec<T, N>, other: &Vec<T, N>) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] ^ other.e[i];
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> Vec<T, N> as BitXor<T> {
    type Output = Vec<T, N>;
    pub fn bit_xor(self: &Vec<T, N>, s: &T) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] ^ *s;
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> T as BitXor<Vec<T, N>> {
    type Output = Vec<T, N>;
    pub fn bit_xor(self: &T, v: &Vec<T, N>) Vec<T, N> {
        let mut r = *v;
        for i in 0..N {
            unsafe {
                r.e[i] = *self ^ v.e[i];
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> Vec<T, N> as BitNot {
    type Output = Vec<T, N>;
    pub fn bit_not(self: &Vec<T, N>) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = ~self.e[i];
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> Vec<T, N> as Shl<Vec<T, N>> {
    type Output = Vec<T, N>;
    pub fn shl(self: &Vec<T, N>, n: Vec<T, N>) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] << n.e[i];
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> Vec<T, N> as Shl<T> {
    type Output = Vec<T, N>;
    pub fn shl(self: &Vec<T, N>, n: T) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] << n;
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> T as Shl<Vec<T, N>> {
    type Output = Vec<T, N>;
    pub fn shl(self: &T, n: Vec<T, N>) Vec<T, N> {
        let mut r = n;
        for i in 0..N {
            unsafe {
                r.e[i] = *self << n.e[i];
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> Vec<T, N> as Shr<Vec<T, N>> {
    type Output = Vec<T, N>;
    pub fn shr(self: &Vec<T, N>, n: Vec<T, N>) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] >> n.e[i];
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> Vec<T, N> as Shr<T> {
    type Output = Vec<T, N>;
    pub fn shr(self: &Vec<T, N>, n: T) Vec<T, N> {
        let mut r = *self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i] >> n;
            }
        }
        return r;
    }
}

extend<T: Int, const N: usize> T as Shr<Vec<T, N>> {
    type Output = Vec<T, N>;
    pub fn shr(self: &T, n: Vec<T, N>) Vec<T, N> {
        let mut r = n;
        for i in 0..N {
            unsafe {
                r.e[i] = *self >> n.e[i];
            }
        }
        return r;
    }
}

/// A value `value_ptr` takes: a vector, a matrix or a quaternion, its components contiguous from the
/// returned address.
pub interface ValuePtr<T> {
    fn value_ptr(self: &Self) *const T;
    fn value_ptr_mut(self: &mut Self) *mut T;
}

/// The address of the first component (x; a matrix's first column first). It stays valid while `x`
/// lives in place.
pub fn value_ptr<T, G: ValuePtr<T>>(x: &G) *const T {
    return x.value_ptr();
}

/// The address of the first component of a mutable value: writes through it change `x`.
pub fn value_ptr_mut<T, G: ValuePtr<T>>(x: &mut G) *mut T {
    return x.value_ptr_mut();
}

extend<T: Elem, const N: usize> Vec<T, N> as ValuePtr<T> {
    pub fn value_ptr(self: &Vec<T, N>) *const T {
        return &self.e[0];
    }
    pub fn value_ptr_mut(self: &mut Vec<T, N>) *mut T {
        return &mut self.e[0];
    }
}

/// The x component of `v`.
pub const fn make_vec1<T: Elem, const M: usize>(v: Vec<T, M>) Vec<T, 1> {
    return Vec::<T, 1> { e: [v.e[0]] };
}

/// The first 2 components of `v`, y = 0 when `v` has one.
pub fn make_vec2_from_vec<T: Scalar, const M: usize>(v: Vec<T, M>) Vec<T, 2> {
    return resize(v, Vec::<T, 2> { e: [T::zero(); 2] });
}

/// The first 3 components of `v`, the missing ones 0.
pub fn make_vec3_from_vec<T: Scalar, const M: usize>(v: Vec<T, M>) Vec<T, 3> {
    return resize(v, Vec::<T, 3> { e: [T::zero(); 3] });
}

/// The first 4 components of `v`, the missing ones 0 and w = 1.
pub fn make_vec4_from_vec<T: Scalar, const M: usize>(v: Vec<T, M>) Vec<T, 4> {
    return resize(v, Vec::<T, 4> { e: [T::zero(), T::zero(), T::zero(), T::one()] });
}

// The components both lengths have from `v`, the others from `fill`.
fn resize<T: Elem, const M: usize, const K: usize>(v: Vec<T, M>, fill: Vec<T, K>) Vec<T, K> {
    let mut r = fill;
    for i in 0..K {
        if i < M {
            unsafe {
                r.e[i] = v.e[i];
            }
        }
    }
    return r;
}

/// The 2 components at `ptr`. Safety: `ptr` addresses 2 valid `T`s.
pub unsafe const fn make_vec2<T: Elem>(ptr: *const T) Vec<T, 2> {
    return Vec::<T, 2> { e: [ptr[0], ptr[1]] };
}

/// The 3 components at `ptr`. Safety: `ptr` addresses 3 valid `T`s.
pub unsafe const fn make_vec3<T: Elem>(ptr: *const T) Vec<T, 3> {
    return Vec::<T, 3> { e: [ptr[0], ptr[1], ptr[2]] };
}

/// The 4 components at `ptr`. Safety: `ptr` addresses 4 valid `T`s.
pub unsafe const fn make_vec4<T: Elem>(ptr: *const T) Vec<T, 4> {
    return Vec::<T, 4> { e: [ptr[0], ptr[1], ptr[2], ptr[3]] };
}
