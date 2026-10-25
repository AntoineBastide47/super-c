// `Mat<T, C, R>`: C columns of R components, column-major with the layout of `[[T; R]; C]` (what a
// graphics API takes as is). The operators and the matrix functions (`transpose`, `determinant`,
// `inverse`, `outer_product`, `matrix_comp_mult`, `diagonal2x2` .. `diagonal4x4` and `adjugate`) use a
// fixed operation order, documented where it changes the bits of the result. The aliases (`mat4`,
// `dmat3x2`, `imat2`, `u8mat4x3`, ..) name the instances.
import std::math::scalar as *;
import std::math::vec as *;

/// C columns of R components; `c[i]` is column i.
pub struct Mat<T: Scalar, const C: usize, const R: usize> {
    pub c: [Vec<T, R>; C],
}

pub type mat2 = Mat<f32, 2, 2>;
pub type mat3 = Mat<f32, 3, 3>;
pub type mat4 = Mat<f32, 4, 4>;
pub type mat2x2 = Mat<f32, 2, 2>;
pub type mat2x3 = Mat<f32, 2, 3>;
pub type mat2x4 = Mat<f32, 2, 4>;
pub type mat3x2 = Mat<f32, 3, 2>;
pub type mat3x3 = Mat<f32, 3, 3>;
pub type mat3x4 = Mat<f32, 3, 4>;
pub type mat4x2 = Mat<f32, 4, 2>;
pub type mat4x3 = Mat<f32, 4, 3>;
pub type mat4x4 = Mat<f32, 4, 4>;
pub type fmat2 = Mat<f32, 2, 2>;
pub type fmat3 = Mat<f32, 3, 3>;
pub type fmat4 = Mat<f32, 4, 4>;
pub type fmat2x2 = Mat<f32, 2, 2>;
pub type fmat2x3 = Mat<f32, 2, 3>;
pub type fmat2x4 = Mat<f32, 2, 4>;
pub type fmat3x2 = Mat<f32, 3, 2>;
pub type fmat3x3 = Mat<f32, 3, 3>;
pub type fmat3x4 = Mat<f32, 3, 4>;
pub type fmat4x2 = Mat<f32, 4, 2>;
pub type fmat4x3 = Mat<f32, 4, 3>;
pub type fmat4x4 = Mat<f32, 4, 4>;
pub type f32mat2 = Mat<f32, 2, 2>;
pub type f32mat3 = Mat<f32, 3, 3>;
pub type f32mat4 = Mat<f32, 4, 4>;
pub type f32mat2x2 = Mat<f32, 2, 2>;
pub type f32mat2x3 = Mat<f32, 2, 3>;
pub type f32mat2x4 = Mat<f32, 2, 4>;
pub type f32mat3x2 = Mat<f32, 3, 2>;
pub type f32mat3x3 = Mat<f32, 3, 3>;
pub type f32mat3x4 = Mat<f32, 3, 4>;
pub type f32mat4x2 = Mat<f32, 4, 2>;
pub type f32mat4x3 = Mat<f32, 4, 3>;
pub type f32mat4x4 = Mat<f32, 4, 4>;
pub type dmat2 = Mat<f64, 2, 2>;
pub type dmat3 = Mat<f64, 3, 3>;
pub type dmat4 = Mat<f64, 4, 4>;
pub type dmat2x2 = Mat<f64, 2, 2>;
pub type dmat2x3 = Mat<f64, 2, 3>;
pub type dmat2x4 = Mat<f64, 2, 4>;
pub type dmat3x2 = Mat<f64, 3, 2>;
pub type dmat3x3 = Mat<f64, 3, 3>;
pub type dmat3x4 = Mat<f64, 3, 4>;
pub type dmat4x2 = Mat<f64, 4, 2>;
pub type dmat4x3 = Mat<f64, 4, 3>;
pub type dmat4x4 = Mat<f64, 4, 4>;
pub type f64mat2 = Mat<f64, 2, 2>;
pub type f64mat3 = Mat<f64, 3, 3>;
pub type f64mat4 = Mat<f64, 4, 4>;
pub type f64mat2x2 = Mat<f64, 2, 2>;
pub type f64mat2x3 = Mat<f64, 2, 3>;
pub type f64mat2x4 = Mat<f64, 2, 4>;
pub type f64mat3x2 = Mat<f64, 3, 2>;
pub type f64mat3x3 = Mat<f64, 3, 3>;
pub type f64mat3x4 = Mat<f64, 3, 4>;
pub type f64mat4x2 = Mat<f64, 4, 2>;
pub type f64mat4x3 = Mat<f64, 4, 3>;
pub type f64mat4x4 = Mat<f64, 4, 4>;
pub type imat2 = Mat<i32, 2, 2>;
pub type imat3 = Mat<i32, 3, 3>;
pub type imat4 = Mat<i32, 4, 4>;
pub type imat2x2 = Mat<i32, 2, 2>;
pub type imat2x3 = Mat<i32, 2, 3>;
pub type imat2x4 = Mat<i32, 2, 4>;
pub type imat3x2 = Mat<i32, 3, 2>;
pub type imat3x3 = Mat<i32, 3, 3>;
pub type imat3x4 = Mat<i32, 3, 4>;
pub type imat4x2 = Mat<i32, 4, 2>;
pub type imat4x3 = Mat<i32, 4, 3>;
pub type imat4x4 = Mat<i32, 4, 4>;
pub type i8mat2 = Mat<i8, 2, 2>;
pub type i8mat3 = Mat<i8, 3, 3>;
pub type i8mat4 = Mat<i8, 4, 4>;
pub type i8mat2x2 = Mat<i8, 2, 2>;
pub type i8mat2x3 = Mat<i8, 2, 3>;
pub type i8mat2x4 = Mat<i8, 2, 4>;
pub type i8mat3x2 = Mat<i8, 3, 2>;
pub type i8mat3x3 = Mat<i8, 3, 3>;
pub type i8mat3x4 = Mat<i8, 3, 4>;
pub type i8mat4x2 = Mat<i8, 4, 2>;
pub type i8mat4x3 = Mat<i8, 4, 3>;
pub type i8mat4x4 = Mat<i8, 4, 4>;
pub type i16mat2 = Mat<i16, 2, 2>;
pub type i16mat3 = Mat<i16, 3, 3>;
pub type i16mat4 = Mat<i16, 4, 4>;
pub type i16mat2x2 = Mat<i16, 2, 2>;
pub type i16mat2x3 = Mat<i16, 2, 3>;
pub type i16mat2x4 = Mat<i16, 2, 4>;
pub type i16mat3x2 = Mat<i16, 3, 2>;
pub type i16mat3x3 = Mat<i16, 3, 3>;
pub type i16mat3x4 = Mat<i16, 3, 4>;
pub type i16mat4x2 = Mat<i16, 4, 2>;
pub type i16mat4x3 = Mat<i16, 4, 3>;
pub type i16mat4x4 = Mat<i16, 4, 4>;
pub type i32mat2 = Mat<i32, 2, 2>;
pub type i32mat3 = Mat<i32, 3, 3>;
pub type i32mat4 = Mat<i32, 4, 4>;
pub type i32mat2x2 = Mat<i32, 2, 2>;
pub type i32mat2x3 = Mat<i32, 2, 3>;
pub type i32mat2x4 = Mat<i32, 2, 4>;
pub type i32mat3x2 = Mat<i32, 3, 2>;
pub type i32mat3x3 = Mat<i32, 3, 3>;
pub type i32mat3x4 = Mat<i32, 3, 4>;
pub type i32mat4x2 = Mat<i32, 4, 2>;
pub type i32mat4x3 = Mat<i32, 4, 3>;
pub type i32mat4x4 = Mat<i32, 4, 4>;
pub type i64mat2 = Mat<i64, 2, 2>;
pub type i64mat3 = Mat<i64, 3, 3>;
pub type i64mat4 = Mat<i64, 4, 4>;
pub type i64mat2x2 = Mat<i64, 2, 2>;
pub type i64mat2x3 = Mat<i64, 2, 3>;
pub type i64mat2x4 = Mat<i64, 2, 4>;
pub type i64mat3x2 = Mat<i64, 3, 2>;
pub type i64mat3x3 = Mat<i64, 3, 3>;
pub type i64mat3x4 = Mat<i64, 3, 4>;
pub type i64mat4x2 = Mat<i64, 4, 2>;
pub type i64mat4x3 = Mat<i64, 4, 3>;
pub type i64mat4x4 = Mat<i64, 4, 4>;
pub type umat2 = Mat<u32, 2, 2>;
pub type umat3 = Mat<u32, 3, 3>;
pub type umat4 = Mat<u32, 4, 4>;
pub type umat2x2 = Mat<u32, 2, 2>;
pub type umat2x3 = Mat<u32, 2, 3>;
pub type umat2x4 = Mat<u32, 2, 4>;
pub type umat3x2 = Mat<u32, 3, 2>;
pub type umat3x3 = Mat<u32, 3, 3>;
pub type umat3x4 = Mat<u32, 3, 4>;
pub type umat4x2 = Mat<u32, 4, 2>;
pub type umat4x3 = Mat<u32, 4, 3>;
pub type umat4x4 = Mat<u32, 4, 4>;
pub type u8mat2 = Mat<u8, 2, 2>;
pub type u8mat3 = Mat<u8, 3, 3>;
pub type u8mat4 = Mat<u8, 4, 4>;
pub type u8mat2x2 = Mat<u8, 2, 2>;
pub type u8mat2x3 = Mat<u8, 2, 3>;
pub type u8mat2x4 = Mat<u8, 2, 4>;
pub type u8mat3x2 = Mat<u8, 3, 2>;
pub type u8mat3x3 = Mat<u8, 3, 3>;
pub type u8mat3x4 = Mat<u8, 3, 4>;
pub type u8mat4x2 = Mat<u8, 4, 2>;
pub type u8mat4x3 = Mat<u8, 4, 3>;
pub type u8mat4x4 = Mat<u8, 4, 4>;
pub type u16mat2 = Mat<u16, 2, 2>;
pub type u16mat3 = Mat<u16, 3, 3>;
pub type u16mat4 = Mat<u16, 4, 4>;
pub type u16mat2x2 = Mat<u16, 2, 2>;
pub type u16mat2x3 = Mat<u16, 2, 3>;
pub type u16mat2x4 = Mat<u16, 2, 4>;
pub type u16mat3x2 = Mat<u16, 3, 2>;
pub type u16mat3x3 = Mat<u16, 3, 3>;
pub type u16mat3x4 = Mat<u16, 3, 4>;
pub type u16mat4x2 = Mat<u16, 4, 2>;
pub type u16mat4x3 = Mat<u16, 4, 3>;
pub type u16mat4x4 = Mat<u16, 4, 4>;
pub type u32mat2 = Mat<u32, 2, 2>;
pub type u32mat3 = Mat<u32, 3, 3>;
pub type u32mat4 = Mat<u32, 4, 4>;
pub type u32mat2x2 = Mat<u32, 2, 2>;
pub type u32mat2x3 = Mat<u32, 2, 3>;
pub type u32mat2x4 = Mat<u32, 2, 4>;
pub type u32mat3x2 = Mat<u32, 3, 2>;
pub type u32mat3x3 = Mat<u32, 3, 3>;
pub type u32mat3x4 = Mat<u32, 3, 4>;
pub type u32mat4x2 = Mat<u32, 4, 2>;
pub type u32mat4x3 = Mat<u32, 4, 3>;
pub type u32mat4x4 = Mat<u32, 4, 4>;
pub type u64mat2 = Mat<u64, 2, 2>;
pub type u64mat3 = Mat<u64, 3, 3>;
pub type u64mat4 = Mat<u64, 4, 4>;
pub type u64mat2x2 = Mat<u64, 2, 2>;
pub type u64mat2x3 = Mat<u64, 2, 3>;
pub type u64mat2x4 = Mat<u64, 2, 4>;
pub type u64mat3x2 = Mat<u64, 3, 2>;
pub type u64mat3x3 = Mat<u64, 3, 3>;
pub type u64mat3x4 = Mat<u64, 3, 4>;
pub type u64mat4x2 = Mat<u64, 4, 2>;
pub type u64mat4x3 = Mat<u64, 4, 3>;
pub type u64mat4x4 = Mat<u64, 4, 4>;

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> {
    /// The number of columns.
    pub const LEN: usize = C;

    /// The number of columns, C; an open-ended range (`m[1..]`) ends there.
    pub const fn len(self: &Mat<T, C, R>) usize {
        return C;
    }

    pub const fn from_cols(c: [Vec<T, R>; C]) Mat<T, C, R> {
        return Mat::<T, C, R> { c: c };
    }
    /// Every element zero.
    pub fn zero() Mat<T, C, R> {
        return Mat::<T, C, R> { c: [Vec::<T, R>::zero(); C] };
    }
    /// `s` on the main diagonal, zero elsewhere.
    pub fn diagonal(s: T) Mat<T, C, R> {
        let mut m = Mat::<T, C, R>::zero();
        for i in 0..C {
            if i < R {
                unsafe {
                    m.c[i].e[i] = s;
                }
            }
        }
        return m;
    }
    /// One on the main diagonal, zero elsewhere.
    pub fn identity() Mat<T, C, R> {
        return Mat::<T, C, R>::diagonal(T::one());
    }
    /// The elements both shapes have from `m`, the others from the identity. Exception: a 4x4 from a
    /// 4x2 takes only the first two columns of `m`; columns 2 and 3 stay those of the identity.
    pub fn from_mat<const C2: usize, const R2: usize>(m: Mat<T, C2, R2>) Mat<T, C, R> {
        let mut r = Mat::<T, C, R>::identity();
        let cols = if C == 4 && R == 4 && C2 == 4 && R2 == 2 {
            2;
        } else {
            C;
        };
        for i in 0..cols {
            for j in 0..R {
                if i < C2 && j < R2 {
                    unsafe {
                        r.c[i].e[j] = m.c[i].e[j];
                    }
                }
            }
        }
        return r;
    }
    /// Each element converted to `U` with `as`, once from the exact value.
    pub fn cast<U: Scalar>(self: Mat<T, C, R>) Mat<U, C, R> {
        let mut r = Mat::<U, C, R>::zero();
        for i in 0..C {
            unsafe {
                r.c[i] = self.c[i].cast::<U>();
            }
        }
        return r;
    }
}

extend<T: Scalar, const R: usize> Mat<T, 2, R> {
    pub const fn cols(c0: Vec<T, R>, c1: Vec<T, R>) Mat<T, 2, R> {
        return Mat::<T, 2, R> { c: [c0, c1] };
    }
}

extend<T: Scalar, const R: usize> Mat<T, 3, R> {
    pub const fn cols(c0: Vec<T, R>, c1: Vec<T, R>, c2: Vec<T, R>) Mat<T, 3, R> {
        return Mat::<T, 3, R> { c: [c0, c1, c2] };
    }
}

extend<T: Scalar, const R: usize> Mat<T, 4, R> {
    pub const fn cols(c0: Vec<T, R>, c1: Vec<T, R>, c2: Vec<T, R>, c3: Vec<T, R>) Mat<T, 4, R> {
        return Mat::<T, 4, R> { c: [c0, c1, c2, c3] };
    }
}

extend<T: Scalar> Mat<T, 2, 2> {
    /// Column by column: `x0, y0` is column 0.
    pub const fn new(x0: T, y0: T, x1: T, y1: T) Mat<T, 2, 2> {
        return Mat::<T, 2, 2> { c: [Vec::<T, 2> { e: [x0, y0] }, Vec::<T, 2> { e: [x1, y1] }] };
    }
}

extend<T: Scalar> Mat<T, 2, 3> {
    /// Column by column.
    pub const fn new(x0: T, y0: T, z0: T, x1: T, y1: T, z1: T) Mat<T, 2, 3> {
        return Mat::<T, 2, 3> { c: [Vec::<T, 3> { e: [x0, y0, z0] }, Vec::<T, 3> { e: [x1, y1, z1] }] };
    }
}

extend<T: Scalar> Mat<T, 2, 4> {
    /// Column by column.
    pub const fn new(x0: T, y0: T, z0: T, w0: T, x1: T, y1: T, z1: T, w1: T) Mat<T, 2, 4> {
        return Mat::<T, 2, 4> { c: [Vec::<T, 4> { e: [x0, y0, z0, w0] }, Vec::<T, 4> { e: [x1, y1, z1, w1] }] };
    }
}

extend<T: Scalar> Mat<T, 3, 2> {
    /// Column by column.
    pub const fn new(x0: T, y0: T, x1: T, y1: T, x2: T, y2: T) Mat<T, 3, 2> {
        return Mat::<T, 3, 2> {
            c: [Vec::<T, 2> { e: [x0, y0] }, Vec::<T, 2> { e: [x1, y1] }, Vec::<T, 2> { e: [x2, y2] }],
        };
    }
}

extend<T: Scalar> Mat<T, 3, 3> {
    /// Column by column.
    pub const fn new(x0: T, y0: T, z0: T, x1: T, y1: T, z1: T, x2: T, y2: T, z2: T) Mat<T, 3, 3> {
        return Mat::<T, 3, 3> {
            c: [Vec::<T, 3> { e: [x0, y0, z0] }, Vec::<T, 3> { e: [x1, y1, z1] }, Vec::<T, 3> { e: [x2, y2, z2] }],
        };
    }
}

extend<T: Scalar> Mat<T, 3, 4> {
    /// Column by column.
    pub const fn new(x0: T, y0: T, z0: T, w0: T, x1: T, y1: T, z1: T, w1: T, x2: T, y2: T, z2: T, w2: T) Mat<T, 3, 4> {
        return Mat::<T, 3, 4> {
            c: [
                Vec::<T, 4> { e: [x0, y0, z0, w0] },
                Vec::<T, 4> { e: [x1, y1, z1, w1] },
                Vec::<T, 4> { e: [x2, y2, z2, w2] },
            ],
        };
    }
}

extend<T: Scalar> Mat<T, 4, 2> {
    /// Column by column.
    pub const fn new(x0: T, y0: T, x1: T, y1: T, x2: T, y2: T, x3: T, y3: T) Mat<T, 4, 2> {
        return Mat::<T, 4, 2> {
            c: [
                Vec::<T, 2> { e: [x0, y0] },
                Vec::<T, 2> { e: [x1, y1] },
                Vec::<T, 2> { e: [x2, y2] },
                Vec::<T, 2> { e: [x3, y3] },
            ],
        };
    }
}

extend<T: Scalar> Mat<T, 4, 3> {
    /// Column by column.
    pub const fn new(x0: T, y0: T, z0: T, x1: T, y1: T, z1: T, x2: T, y2: T, z2: T, x3: T, y3: T, z3: T) Mat<T, 4, 3> {
        return Mat::<T, 4, 3> {
            c: [
                Vec::<T, 3> { e: [x0, y0, z0] },
                Vec::<T, 3> { e: [x1, y1, z1] },
                Vec::<T, 3> { e: [x2, y2, z2] },
                Vec::<T, 3> { e: [x3, y3, z3] },
            ],
        };
    }
}

extend<T: Scalar> Mat<T, 4, 4> {
    /// Column by column.
    pub const fn new(
        x0: T,
        y0: T,
        z0: T,
        w0: T,
        x1: T,
        y1: T,
        z1: T,
        w1: T,
        x2: T,
        y2: T,
        z2: T,
        w2: T,
        x3: T,
        y3: T,
        z3: T,
        w3: T,
    ) Mat<T, 4, 4> {
        return Mat::<T, 4, 4> {
            c: [
                Vec::<T, 4> { e: [x0, y0, z0, w0] },
                Vec::<T, 4> { e: [x1, y1, z1, w1] },
                Vec::<T, 4> { e: [x2, y2, z2, w2] },
                Vec::<T, 4> { e: [x3, y3, z3, w3] },
            ],
        };
    }
}

// `m[i]` is column `i`; an index of C or more traps.
extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Index<Vec<T, R>, []Vec<T, R>> {
    pub fn index(self: &Mat<T, C, R>, i: usize) &Vec<T, R> {
        if i >= C {
            panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds");
        }
        return &unsafe self.c[i];
    }
    pub fn index_range(self: &Mat<T, C, R>, r: Range<usize>) []Vec<T, R> {
        let (lo, hi) = col_range(r, C, "Mat<T, C, R>");
        return unsafe Slice::<Vec<T, R>> { ptr: (&self.c[0]) as *const Vec<T, R> + lo, len: hi - lo };
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as IndexMut<Vec<T, R>, []mut Vec<T, R>> {
    pub fn index_mut(self: &mut Mat<T, C, R>, i: usize) &mut Vec<T, R> {
        if i >= C {
            panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds");
        }
        return &mut unsafe self.c[i];
    }
    pub fn index_range_mut(self: &mut Mat<T, C, R>, r: Range<usize>) []mut Vec<T, R> {
        let (lo, hi) = col_range(r, C, "Mat<T, C, R>");
        return unsafe SliceMut::<Vec<T, R>> { ptr: (&mut self.c[0]) as *mut Vec<T, R> + lo, len: hi - lo };
    }
}

// The half-open bounds of `r` within `[0, n)` of a value of type `name`; a range outside traps.
const fn col_range(r: Range<usize>, n: usize, name: str) (usize, usize) {
    let hi = if r.inclusive {
        r.end + 1;
    } else {
        r.end;
    };
    if r.start > hi || hi > n {
        panic_parts(name, "[a..b]: range out of bounds");
    }
    return r.start, hi;
}

// `==`: every column equal.
extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Eq {
    pub fn eq(self: &Mat<T, C, R>, other: &Mat<T, C, R>) bool {
        for i in 0..C {
            if unsafe {
                self.c[i] != other.c[i];
            } {
                return false;
            }
        }
        return true;
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Neg {
    type Output = Mat<T, C, R>;
    pub fn neg(self: &Mat<T, C, R>) Mat<T, C, R> {
        let mut m = *self;
        for i in 0..C {
            unsafe {
                m.c[i] = -self.c[i];
            }
        }
        return m;
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Add {
    type Output = Mat<T, C, R>;
    pub fn add(self: &Mat<T, C, R>, other: &Mat<T, C, R>) Mat<T, C, R> {
        let mut m = *self;
        for i in 0..C {
            unsafe {
                m.c[i] = self.c[i] + other.c[i];
            }
        }
        return m;
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Sub {
    type Output = Mat<T, C, R>;
    pub fn sub(self: &Mat<T, C, R>, other: &Mat<T, C, R>) Mat<T, C, R> {
        let mut m = *self;
        for i in 0..C {
            unsafe {
                m.c[i] = self.c[i] - other.c[i];
            }
        }
        return m;
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Add<T> {
    type Output = Mat<T, C, R>;
    pub fn add(self: &Mat<T, C, R>, s: &T) Mat<T, C, R> {
        let mut m = *self;
        for i in 0..C {
            unsafe {
                m.c[i] = self.c[i] + *s;
            }
        }
        return m;
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Sub<T> {
    type Output = Mat<T, C, R>;
    pub fn sub(self: &Mat<T, C, R>, s: &T) Mat<T, C, R> {
        let mut m = *self;
        for i in 0..C {
            unsafe {
                m.c[i] = self.c[i] - *s;
            }
        }
        return m;
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Mul<T> {
    type Output = Mat<T, C, R>;
    pub fn mul(self: &Mat<T, C, R>, s: &T) Mat<T, C, R> {
        let mut m = *self;
        for i in 0..C {
            unsafe {
                m.c[i] = self.c[i] * *s;
            }
        }
        return m;
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Div<T> {
    type Output = Mat<T, C, R>;
    pub fn div(self: &Mat<T, C, R>, s: &T) Mat<T, C, R> {
        let mut m = *self;
        for i in 0..C {
            unsafe {
                m.c[i] = self.c[i] / *s;
            }
        }
        return m;
    }
}

extend<T: Scalar, const C: usize, const R: usize> T as Add<Mat<T, C, R>> {
    type Output = Mat<T, C, R>;
    pub fn add(self: &T, m: &Mat<T, C, R>) Mat<T, C, R> {
        let mut r = *m;
        for i in 0..C {
            unsafe {
                r.c[i] = m.c[i] + *self;
            }
        }
        return r;
    }
}

extend<T: Scalar, const C: usize, const R: usize> T as Sub<Mat<T, C, R>> {
    type Output = Mat<T, C, R>;
    pub fn sub(self: &T, m: &Mat<T, C, R>) Mat<T, C, R> {
        let mut r = *m;
        for i in 0..C {
            unsafe {
                r.c[i] = *self - m.c[i];
            }
        }
        return r;
    }
}

extend<T: Scalar, const C: usize, const R: usize> T as Mul<Mat<T, C, R>> {
    type Output = Mat<T, C, R>;
    pub fn mul(self: &T, m: &Mat<T, C, R>) Mat<T, C, R> {
        let mut r = *m;
        for i in 0..C {
            unsafe {
                r.c[i] = m.c[i] * *self;
            }
        }
        return r;
    }
}

extend<T: Scalar, const C: usize, const R: usize> T as Div<Mat<T, C, R>> {
    type Output = Mat<T, C, R>;
    pub fn div(self: &T, m: &Mat<T, C, R>) Mat<T, C, R> {
        let mut r = *m;
        for i in 0..C {
            unsafe {
                r.c[i] = *self / m.c[i];
            }
        }
        return r;
    }
}

// `a * b`: element (k, r) is a[0][r] * b[k][0] + a[1][r] * b[k][1] + .., summed left to right. Always
// inlined: a caller that keeps the product out of line passes both matrices through memory, stored element
// by element and loaded by column, which stalls (`interpolate` and `recompose` took 2.5 times longer).
extend<T: Scalar, const C: usize, const R: usize, const K: usize> Mat<T, C, R> as Mul<Mat<T, K, C>> {
    type Output = Mat<T, K, R>;
    @always_inline
    pub fn mul(self: &Mat<T, C, R>, b: &Mat<T, K, C>) Mat<T, K, R> {
        let mut m = Mat::<T, K, R>::zero();
        for k in 0..K {
            for r in 0..R {
                unsafe {
                    let mut s = self.c[0].e[r] * b.c[k].e[0];
                    for i in 1..C {
                        s = s + self.c[i].e[r] * b.c[k].e[i];
                    }
                    m.c[k].e[r] = s;
                }
            }
        }
        return m;
    }
}

// `m * v`: the column products summed left to right, except mat4 * vec4, which adds them in pairs:
// (m0 v0 + m1 v1) + (m2 v2 + m3 v3).
extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Mul<Vec<T, C>> {
    type Output = Vec<T, R>;
    pub fn mul(self: &Mat<T, C, R>, v: &Vec<T, C>) Vec<T, R> {
        let mut r = Vec::<T, R>::zero();
        if C == 4 && R == 4 {
            for j in 0..R {
                unsafe {
                    r.e[j] = self.c[0].e[j] * v.e[0] + self.c[1].e[j] * v.e[1] + (self.c[2].e[j] * v.e[2] + self.c[3].e[j] * v.e[3]);
                }
            }
            return r;
        }
        for j in 0..R {
            unsafe {
                let mut s = self.c[0].e[j] * v.e[0];
                for i in 1..C {
                    s = s + self.c[i].e[j] * v.e[i];
                }
                r.e[j] = s;
            }
        }
        return r;
    }
}

// `v * m`: component k is v.x m[k][0] + v.y m[k][1] + .., summed left to right, except vec4 * mat4,
// which adds in pairs: (v0 m[k][0] + v1 m[k][1]) + (v2 m[k][2] + v3 m[k][3]).
extend<T: Scalar, const C: usize, const R: usize> Vec<T, R> as Mul<Mat<T, C, R>> {
    type Output = Vec<T, C>;
    pub fn mul(self: &Vec<T, R>, m: &Mat<T, C, R>) Vec<T, C> {
        let mut r = Vec::<T, C>::zero();
        if C == 4 && R == 4 {
            for k in 0..C {
                unsafe {
                    r.e[k] = m.c[k].e[0] * self.e[0] + m.c[k].e[1] * self.e[1] + (m.c[k].e[2] * self.e[2] + m.c[k].e[3] * self.e[3]);
                }
            }
            return r;
        }
        for k in 0..C {
            unsafe {
                let mut s = self.e[0] * m.c[k].e[0];
                for i in 1..R {
                    s = s + self.e[i] * m.c[k].e[i];
                }
                r.e[k] = s;
            }
        }
        return r;
    }
}

// `m1 / m2`: m1 * inverse(m2).
extend<T: Float> Mat<T, 2, 2> as Div {
    type Output = Mat<T, 2, 2>;
    pub fn div(self: &Mat<T, 2, 2>, other: &Mat<T, 2, 2>) Mat<T, 2, 2> {
        return *self * mat_inverse(*other);
    }
}

// `m / v`: inverse(m) * v.
extend<T: Float> Mat<T, 2, 2> as Div<Vec<T, 2>> {
    type Output = Vec<T, 2>;
    pub fn div(self: &Mat<T, 2, 2>, v: &Vec<T, 2>) Vec<T, 2> {
        return mat_inverse(*self) * *v;
    }
}

// `v / m`: v * inverse(m).
extend<T: Float> Vec<T, 2> as Div<Mat<T, 2, 2>> {
    type Output = Vec<T, 2>;
    pub fn div(self: &Vec<T, 2>, m: &Mat<T, 2, 2>) Vec<T, 2> {
        return *self * mat_inverse(*m);
    }
}

// `m1 / m2`: m1 * inverse(m2).
extend<T: Float> Mat<T, 3, 3> as Div {
    type Output = Mat<T, 3, 3>;
    pub fn div(self: &Mat<T, 3, 3>, other: &Mat<T, 3, 3>) Mat<T, 3, 3> {
        return *self * mat_inverse(*other);
    }
}

// `m / v`: inverse(m) * v.
extend<T: Float> Mat<T, 3, 3> as Div<Vec<T, 3>> {
    type Output = Vec<T, 3>;
    pub fn div(self: &Mat<T, 3, 3>, v: &Vec<T, 3>) Vec<T, 3> {
        return mat_inverse(*self) * *v;
    }
}

// `v / m`: v * inverse(m).
extend<T: Float> Vec<T, 3> as Div<Mat<T, 3, 3>> {
    type Output = Vec<T, 3>;
    pub fn div(self: &Vec<T, 3>, m: &Mat<T, 3, 3>) Vec<T, 3> {
        return *self * mat_inverse(*m);
    }
}

// `m1 / m2`: m1 * inverse(m2).
extend<T: Float> Mat<T, 4, 4> as Div {
    type Output = Mat<T, 4, 4>;
    pub fn div(self: &Mat<T, 4, 4>, other: &Mat<T, 4, 4>) Mat<T, 4, 4> {
        return *self * mat_inverse(*other);
    }
}

// `m / v`: inverse(m) * v.
extend<T: Float> Mat<T, 4, 4> as Div<Vec<T, 4>> {
    type Output = Vec<T, 4>;
    pub fn div(self: &Mat<T, 4, 4>, v: &Vec<T, 4>) Vec<T, 4> {
        return mat_inverse(*self) * *v;
    }
}

// `v / m`: v * inverse(m).
extend<T: Float> Vec<T, 4> as Div<Mat<T, 4, 4>> {
    type Output = Vec<T, 4>;
    pub fn div(self: &Vec<T, 4>, m: &Mat<T, 4, 4>) Vec<T, 4> {
        return *self * mat_inverse(*m);
    }
}

/// The transposed matrix.
pub fn transpose<T: Scalar, const C: usize, const R: usize>(m: Mat<T, C, R>) Mat<T, R, C> {
    let mut t = Mat::<T, R, C>::zero();
    for i in 0..C {
        for j in 0..R {
            unsafe {
                t.c[j].e[i] = m.c[i].e[j];
            }
        }
    }
    return t;
}

/// The element-wise product.
pub const fn matrix_comp_mult<T: Scalar, const C: usize, const R: usize>(x: Mat<T, C, R>, y: Mat<T, C, R>) Mat<T, C, R> {
    let mut m = x;
    for i in 0..C {
        unsafe {
            m.c[i] = x.c[i] * y.c[i];
        }
    }
    return m;
}

/// The column vector `c` times the row vector `r`: column i is `c * r[i]`.
pub fn outer_product<T: Scalar, const R: usize, const C: usize>(c: Vec<T, R>, r: Vec<T, C>) Mat<T, C, R> {
    let mut m = Mat::<T, C, R>::zero();
    for i in 0..C {
        unsafe {
            m.c[i] = c * r.e[i];
        }
    }
    return m;
}

/// The determinant of a 2x2, 3x3 or 4x4 matrix (another size is a compile error), by cofactor
/// expansion.
pub const fn determinant<T: Scalar, const N: usize>(m: Mat<T, N, N>) T {
    static_assert(N >= 2 && N <= 4, "determinant of a 2x2, 3x3 or 4x4 matrix");
    if N == 2 {
        return unsafe m.c[0].e[0] * m.c[1].e[1] - m.c[1].e[0] * m.c[0].e[1];
    }
    if N == 3 {
        return unsafe {
            m.c[0].e[0] * (m.c[1].e[1] * m.c[2].e[2] - m.c[2].e[1] * m.c[1].e[2]) - m.c[1].e[0] * (m.c[0].e[1] * m.c[2].e[2] - m.c[2].e[1] * m.c[0].e[2]) + m.c[2].e[0] * (m.c[0].e[1] * m.c[1].e[2] - m.c[1].e[1] * m.c[0].e[2]);
        };
    }
    unsafe {
        let s00 = m.c[2].e[2] * m.c[3].e[3] - m.c[3].e[2] * m.c[2].e[3];
        let s01 = m.c[2].e[1] * m.c[3].e[3] - m.c[3].e[1] * m.c[2].e[3];
        let s02 = m.c[2].e[1] * m.c[3].e[2] - m.c[3].e[1] * m.c[2].e[2];
        let s03 = m.c[2].e[0] * m.c[3].e[3] - m.c[3].e[0] * m.c[2].e[3];
        let s04 = m.c[2].e[0] * m.c[3].e[2] - m.c[3].e[0] * m.c[2].e[2];
        let s05 = m.c[2].e[0] * m.c[3].e[1] - m.c[3].e[0] * m.c[2].e[1];
        let d0 = m.c[1].e[1] * s00 - m.c[1].e[2] * s01 + m.c[1].e[3] * s02;
        let d1 = -(m.c[1].e[0] * s00 - m.c[1].e[2] * s03 + m.c[1].e[3] * s04);
        let d2 = m.c[1].e[0] * s01 - m.c[1].e[1] * s03 + m.c[1].e[3] * s05;
        let d3 = -(m.c[1].e[0] * s02 - m.c[1].e[1] * s04 + m.c[1].e[2] * s05);
        return m.c[0].e[0] * d0 + m.c[0].e[1] * d1 + m.c[0].e[2] * d2 + m.c[0].e[3] * d3;
    }
}

/// A value `inverse` takes: a 2x2, 3x3 or 4x4 matrix of floats, or a quaternion.
pub interface Invertible: Copy {
    fn inverse(self: Self) Self;
}

/// The inverse of a matrix by cofactors (a singular matrix gives infinities or NaNs), or of a
/// quaternion.
pub fn inverse<G: Invertible>(x: G) G {
    return x.inverse();
}

extend<T: Float> Mat<T, 2, 2> as Invertible {
    pub fn inverse(self: Mat<T, 2, 2>) Mat<T, 2, 2> {
        return mat_inverse(self);
    }
}

extend<T: Float> Mat<T, 3, 3> as Invertible {
    pub fn inverse(self: Mat<T, 3, 3>) Mat<T, 3, 3> {
        return mat_inverse(self);
    }
}

extend<T: Float> Mat<T, 4, 4> as Invertible {
    pub fn inverse(self: Mat<T, 4, 4>) Mat<T, 4, 4> {
        return mat_inverse(self);
    }
}

// The matrix inverse for N = 2, 3 or 4: each adjugate element times 1 / determinant.
fn mat_inverse<T: Float, const N: usize>(m: Mat<T, N, N>) Mat<T, N, N> {
    static_assert(N >= 2 && N <= 4, "inverse of a 2x2, 3x3 or 4x4 matrix");
    let mut r = m;
    if N == 2 {
        unsafe {
            let od = T::one() / (m.c[0].e[0] * m.c[1].e[1] - m.c[1].e[0] * m.c[0].e[1]);
            r.c[0].e[0] = m.c[1].e[1] * od;
            r.c[0].e[1] = -m.c[0].e[1] * od;
            r.c[1].e[0] = -m.c[1].e[0] * od;
            r.c[1].e[1] = m.c[0].e[0] * od;
        }
        return r;
    }
    if N == 3 {
        unsafe {
            let od = T::one() / (m.c[0].e[0] * (m.c[1].e[1] * m.c[2].e[2] - m.c[2].e[1] * m.c[1].e[2]) - m.c[1].e[0] * (m.c[0].e[1] * m.c[2].e[2] - m.c[2].e[1] * m.c[0].e[2]) + m.c[2].e[0] * (m.c[0].e[1] * m.c[1].e[2] - m.c[1].e[1] * m.c[0].e[2]));
            r.c[0].e[0] = (m.c[1].e[1] * m.c[2].e[2] - m.c[2].e[1] * m.c[1].e[2]) * od;
            r.c[1].e[0] = -(m.c[1].e[0] * m.c[2].e[2] - m.c[2].e[0] * m.c[1].e[2]) * od;
            r.c[2].e[0] = (m.c[1].e[0] * m.c[2].e[1] - m.c[2].e[0] * m.c[1].e[1]) * od;
            r.c[0].e[1] = -(m.c[0].e[1] * m.c[2].e[2] - m.c[2].e[1] * m.c[0].e[2]) * od;
            r.c[1].e[1] = (m.c[0].e[0] * m.c[2].e[2] - m.c[2].e[0] * m.c[0].e[2]) * od;
            r.c[2].e[1] = -(m.c[0].e[0] * m.c[2].e[1] - m.c[2].e[0] * m.c[0].e[1]) * od;
            r.c[0].e[2] = (m.c[0].e[1] * m.c[1].e[2] - m.c[1].e[1] * m.c[0].e[2]) * od;
            r.c[1].e[2] = -(m.c[0].e[0] * m.c[1].e[2] - m.c[1].e[0] * m.c[0].e[2]) * od;
            r.c[2].e[2] = (m.c[0].e[0] * m.c[1].e[1] - m.c[1].e[0] * m.c[0].e[1]) * od;
        }
        return r;
    }
    unsafe {
        let c00 = m.c[2].e[2] * m.c[3].e[3] - m.c[3].e[2] * m.c[2].e[3];
        let c02 = m.c[1].e[2] * m.c[3].e[3] - m.c[3].e[2] * m.c[1].e[3];
        let c03 = m.c[1].e[2] * m.c[2].e[3] - m.c[2].e[2] * m.c[1].e[3];
        let c04 = m.c[2].e[1] * m.c[3].e[3] - m.c[3].e[1] * m.c[2].e[3];
        let c06 = m.c[1].e[1] * m.c[3].e[3] - m.c[3].e[1] * m.c[1].e[3];
        let c07 = m.c[1].e[1] * m.c[2].e[3] - m.c[2].e[1] * m.c[1].e[3];
        let c08 = m.c[2].e[1] * m.c[3].e[2] - m.c[3].e[1] * m.c[2].e[2];
        let c10 = m.c[1].e[1] * m.c[3].e[2] - m.c[3].e[1] * m.c[1].e[2];
        let c11 = m.c[1].e[1] * m.c[2].e[2] - m.c[2].e[1] * m.c[1].e[2];
        let c12 = m.c[2].e[0] * m.c[3].e[3] - m.c[3].e[0] * m.c[2].e[3];
        let c14 = m.c[1].e[0] * m.c[3].e[3] - m.c[3].e[0] * m.c[1].e[3];
        let c15 = m.c[1].e[0] * m.c[2].e[3] - m.c[2].e[0] * m.c[1].e[3];
        let c16 = m.c[2].e[0] * m.c[3].e[2] - m.c[3].e[0] * m.c[2].e[2];
        let c18 = m.c[1].e[0] * m.c[3].e[2] - m.c[3].e[0] * m.c[1].e[2];
        let c19 = m.c[1].e[0] * m.c[2].e[2] - m.c[2].e[0] * m.c[1].e[2];
        let c20 = m.c[2].e[0] * m.c[3].e[1] - m.c[3].e[0] * m.c[2].e[1];
        let c22 = m.c[1].e[0] * m.c[3].e[1] - m.c[3].e[0] * m.c[1].e[1];
        let c23 = m.c[1].e[0] * m.c[2].e[1] - m.c[2].e[0] * m.c[1].e[1];
        let f0 = Vec::<T, 4> { e: [c00, c00, c02, c03] };
        let f1 = Vec::<T, 4> { e: [c04, c04, c06, c07] };
        let f2 = Vec::<T, 4> { e: [c08, c08, c10, c11] };
        let f3 = Vec::<T, 4> { e: [c12, c12, c14, c15] };
        let f4 = Vec::<T, 4> { e: [c16, c16, c18, c19] };
        let f5 = Vec::<T, 4> { e: [c20, c20, c22, c23] };
        let v0 = Vec::<T, 4> { e: [m.c[1].e[0], m.c[0].e[0], m.c[0].e[0], m.c[0].e[0]] };
        let v1 = Vec::<T, 4> { e: [m.c[1].e[1], m.c[0].e[1], m.c[0].e[1], m.c[0].e[1]] };
        let v2 = Vec::<T, 4> { e: [m.c[1].e[2], m.c[0].e[2], m.c[0].e[2], m.c[0].e[2]] };
        let v3 = Vec::<T, 4> { e: [m.c[1].e[3], m.c[0].e[3], m.c[0].e[3], m.c[0].e[3]] };
        let i0 = v1 * f0 - v2 * f1 + v3 * f2;
        let i1 = v0 * f0 - v2 * f3 + v3 * f4;
        let i2 = v0 * f1 - v1 * f3 + v3 * f5;
        let i3 = v0 * f2 - v1 * f4 + v2 * f5;
        let p = T::one();
        let n = -T::one();
        let sa = Vec::<T, 4> { e: [p, n, p, n] };
        let sb = Vec::<T, 4> { e: [n, p, n, p] };
        let c0 = i0 * sa;
        let c1 = i1 * sb;
        let c2 = i2 * sa;
        let c3 = i3 * sb;
        let row0 = Vec::<T, 4> { e: [c0.e[0], c1.e[0], c2.e[0], c3.e[0]] };
        let d = m.c[0].e[0] * row0.e[0];
        let e1 = m.c[0].e[1] * row0.e[1];
        let e2 = m.c[0].e[2] * row0.e[2];
        let e3 = m.c[0].e[3] * row0.e[3];
        let od = T::one() / (d + e1 + (e2 + e3));
        let cs = [c0, c1, c2, c3];
        for k in 0..4 {
            for j in 0..4 {
                r.c[k].e[j] = cs[k].e[j] * od;
            }
        }
    }
    return r;
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as ValuePtr<T> {
    pub fn value_ptr(self: &Mat<T, C, R>) *const T {
        return &self.c[0].e[0];
    }
    pub fn value_ptr_mut(self: &mut Mat<T, C, R>) *mut T {
        return &mut self.c[0].e[0];
    }
}

// The C columns of R components at `ptr`, column by column.
unsafe fn mat_from_ptr<T: Scalar, const C: usize, const R: usize>(ptr: *const T) Mat<T, C, R> {
    let mut m = Mat::<T, C, R>::zero();
    for i in 0..C {
        for j in 0..R {
            m.c[i].e[j] = ptr[i * R + j];
        }
    }
    return m;
}

/// The 4 `T`s at `ptr`, column by column. Safety: `ptr` addresses 4 valid `T`s; the other `make_mat`
/// functions take C * R.
pub unsafe fn make_mat2x2<T: Scalar>(ptr: *const T) Mat<T, 2, 2> {
    return mat_from_ptr::<T, 2, 2>(ptr);
}

/// 2 columns of 3 at `ptr`.
pub unsafe fn make_mat2x3<T: Scalar>(ptr: *const T) Mat<T, 2, 3> {
    return mat_from_ptr::<T, 2, 3>(ptr);
}

/// 2 columns of 4 at `ptr`.
pub unsafe fn make_mat2x4<T: Scalar>(ptr: *const T) Mat<T, 2, 4> {
    return mat_from_ptr::<T, 2, 4>(ptr);
}

/// 3 columns of 2 at `ptr`.
pub unsafe fn make_mat3x2<T: Scalar>(ptr: *const T) Mat<T, 3, 2> {
    return mat_from_ptr::<T, 3, 2>(ptr);
}

/// 3 columns of 3 at `ptr`.
pub unsafe fn make_mat3x3<T: Scalar>(ptr: *const T) Mat<T, 3, 3> {
    return mat_from_ptr::<T, 3, 3>(ptr);
}

/// 3 columns of 4 at `ptr`.
pub unsafe fn make_mat3x4<T: Scalar>(ptr: *const T) Mat<T, 3, 4> {
    return mat_from_ptr::<T, 3, 4>(ptr);
}

/// 4 columns of 2 at `ptr`.
pub unsafe fn make_mat4x2<T: Scalar>(ptr: *const T) Mat<T, 4, 2> {
    return mat_from_ptr::<T, 4, 2>(ptr);
}

/// 4 columns of 3 at `ptr`.
pub unsafe fn make_mat4x3<T: Scalar>(ptr: *const T) Mat<T, 4, 3> {
    return mat_from_ptr::<T, 4, 3>(ptr);
}

/// 4 columns of 4 at `ptr`.
pub unsafe fn make_mat4x4<T: Scalar>(ptr: *const T) Mat<T, 4, 4> {
    return mat_from_ptr::<T, 4, 4>(ptr);
}

/// The same as `make_mat2x2`.
pub unsafe fn make_mat2<T: Scalar>(ptr: *const T) Mat<T, 2, 2> {
    return mat_from_ptr::<T, 2, 2>(ptr);
}

/// The same as `make_mat3x3`.
pub unsafe fn make_mat3<T: Scalar>(ptr: *const T) Mat<T, 3, 3> {
    return mat_from_ptr::<T, 3, 3>(ptr);
}

/// The same as `make_mat4x4`.
pub unsafe fn make_mat4<T: Scalar>(ptr: *const T) Mat<T, 4, 4> {
    return mat_from_ptr::<T, 4, 4>(ptr);
}

/// Row `index` of `m`, one component per column. Panics: `index >= R`.
pub fn row<T: Scalar, const C: usize, const R: usize>(m: Mat<T, C, R>, index: usize) Vec<T, C> {
    assert(index < R, "row: index out of bounds");
    let mut r = Vec::<T, C>::zero();
    for i in 0..C {
        unsafe {
            r.e[i] = m.c[i].e[index];
        }
    }
    return r;
}

/// `m` with row `index` replaced by `x`. Panics: `index >= R`.
pub fn set_row<T: Scalar, const C: usize, const R: usize>(m: Mat<T, C, R>, index: usize, x: Vec<T, C>) Mat<T, C, R> {
    assert(index < R, "set_row: index out of bounds");
    let mut r = m;
    for i in 0..C {
        unsafe {
            r.c[i].e[index] = x.e[i];
        }
    }
    return r;
}

/// Column `index` of `m`. Panics: `index >= C`.
pub const fn column<T: Scalar, const C: usize, const R: usize>(m: Mat<T, C, R>, index: usize) Vec<T, R> {
    return m[index];
}

/// `m` with column `index` replaced by `x`. Panics: `index >= C`.
pub const fn set_column<T: Scalar, const C: usize, const R: usize>(m: Mat<T, C, R>, index: usize, x: Vec<T, R>) Mat<
    T,
    C,
    R
> {
    let mut r = m;
    r[index] = x;
    return r;
}

/// A matrix `affine_inverse` takes: a 3x3 or 4x4 matrix of floats.
pub interface AffineInverse: Copy {
    fn affine_inverse(self: Self) Self;
}

/// The inverse of an affine transform `m` (last row 0, .., 0, 1), from the inverse of its linear part:
/// faster than `inverse`, and rounded differently.
pub fn affine_inverse<G: AffineInverse>(m: G) G {
    return m.affine_inverse();
}

extend<T: Float> Mat<T, 3, 3> as AffineInverse {
    pub fn affine_inverse(self: Mat<T, 3, 3>) Mat<T, 3, 3> {
        let inv = mat_inverse(Mat::<T, 2, 2>::from_mat(self));
        let t = -inv * self.c[2].truncate::<2>();
        return Mat::<T, 3, 3>::cols(inv.c[0].append(T::zero()), inv.c[1].append(T::zero()), t.append(T::one()));
    }
}

extend<T: Float> Mat<T, 4, 4> as AffineInverse {
    pub fn affine_inverse(self: Mat<T, 4, 4>) Mat<T, 4, 4> {
        let inv = mat_inverse(Mat::<T, 3, 3>::from_mat(self));
        let t = -inv * self.c[3].truncate::<3>();
        return Mat::<T, 4, 4>::cols(
            inv.c[0].append(T::zero()),
            inv.c[1].append(T::zero()),
            inv.c[2].append(T::zero()),
            t.append(T::one()),
        );
    }
}

/// The transposed inverse of a 2x2, 3x3 or 4x4 matrix (another size is a compile error), by
/// cofactors. Exception: the 2x2 result is the inverse, not transposed.
pub const fn inverse_transpose<T: Float, const N: usize>(m: Mat<T, N, N>) Mat<T, N, N> {
    static_assert(N >= 2 && N <= 4, "inverse_transpose of a 2x2, 3x3 or 4x4 matrix");
    let mut r = m;
    if N == 2 {
        unsafe {
            let d = m.c[0].e[0] * m.c[1].e[1] - m.c[1].e[0] * m.c[0].e[1];
            r.c[0].e[0] = m.c[1].e[1] / d;
            r.c[0].e[1] = -m.c[0].e[1] / d;
            r.c[1].e[0] = -m.c[1].e[0] / d;
            r.c[1].e[1] = m.c[0].e[0] / d;
        }
        return r;
    }
    if N == 3 {
        unsafe {
            let d = m.c[0].e[0] * (m.c[1].e[1] * m.c[2].e[2] - m.c[1].e[2] * m.c[2].e[1]) - m.c[0].e[1] * (m.c[1].e[0] * m.c[2].e[2] - m.c[1].e[2] * m.c[2].e[0]) + m.c[0].e[2] * (m.c[1].e[0] * m.c[2].e[1] - m.c[1].e[1] * m.c[2].e[0]);
            r.c[0].e[0] = m.c[1].e[1] * m.c[2].e[2] - m.c[2].e[1] * m.c[1].e[2];
            r.c[0].e[1] = -(m.c[1].e[0] * m.c[2].e[2] - m.c[2].e[0] * m.c[1].e[2]);
            r.c[0].e[2] = m.c[1].e[0] * m.c[2].e[1] - m.c[2].e[0] * m.c[1].e[1];
            r.c[1].e[0] = -(m.c[0].e[1] * m.c[2].e[2] - m.c[2].e[1] * m.c[0].e[2]);
            r.c[1].e[1] = m.c[0].e[0] * m.c[2].e[2] - m.c[2].e[0] * m.c[0].e[2];
            r.c[1].e[2] = -(m.c[0].e[0] * m.c[2].e[1] - m.c[2].e[0] * m.c[0].e[1]);
            r.c[2].e[0] = m.c[0].e[1] * m.c[1].e[2] - m.c[1].e[1] * m.c[0].e[2];
            r.c[2].e[1] = -(m.c[0].e[0] * m.c[1].e[2] - m.c[1].e[0] * m.c[0].e[2]);
            r.c[2].e[2] = m.c[0].e[0] * m.c[1].e[1] - m.c[1].e[0] * m.c[0].e[1];
            for k in 0..3 {
                for j in 0..3 {
                    r.c[k].e[j] = r.c[k].e[j] / d;
                }
            }
        }
        return r;
    }
    unsafe {
        let s00 = m.c[2].e[2] * m.c[3].e[3] - m.c[3].e[2] * m.c[2].e[3];
        let s01 = m.c[2].e[1] * m.c[3].e[3] - m.c[3].e[1] * m.c[2].e[3];
        let s02 = m.c[2].e[1] * m.c[3].e[2] - m.c[3].e[1] * m.c[2].e[2];
        let s03 = m.c[2].e[0] * m.c[3].e[3] - m.c[3].e[0] * m.c[2].e[3];
        let s04 = m.c[2].e[0] * m.c[3].e[2] - m.c[3].e[0] * m.c[2].e[2];
        let s05 = m.c[2].e[0] * m.c[3].e[1] - m.c[3].e[0] * m.c[2].e[1];
        let s06 = m.c[1].e[2] * m.c[3].e[3] - m.c[3].e[2] * m.c[1].e[3];
        let s07 = m.c[1].e[1] * m.c[3].e[3] - m.c[3].e[1] * m.c[1].e[3];
        let s08 = m.c[1].e[1] * m.c[3].e[2] - m.c[3].e[1] * m.c[1].e[2];
        let s09 = m.c[1].e[0] * m.c[3].e[3] - m.c[3].e[0] * m.c[1].e[3];
        let s10 = m.c[1].e[0] * m.c[3].e[2] - m.c[3].e[0] * m.c[1].e[2];
        let s11 = m.c[1].e[0] * m.c[3].e[1] - m.c[3].e[0] * m.c[1].e[1];
        let s12 = m.c[1].e[2] * m.c[2].e[3] - m.c[2].e[2] * m.c[1].e[3];
        let s13 = m.c[1].e[1] * m.c[2].e[3] - m.c[2].e[1] * m.c[1].e[3];
        let s14 = m.c[1].e[1] * m.c[2].e[2] - m.c[2].e[1] * m.c[1].e[2];
        let s15 = m.c[1].e[0] * m.c[2].e[3] - m.c[2].e[0] * m.c[1].e[3];
        let s16 = m.c[1].e[0] * m.c[2].e[2] - m.c[2].e[0] * m.c[1].e[2];
        let s17 = m.c[1].e[0] * m.c[2].e[1] - m.c[2].e[0] * m.c[1].e[1];
        let a = m.c[0].e;
        let b = m.c[1].e;
        r.c[0].e[0] = b[1] * s00 - b[2] * s01 + b[3] * s02;
        r.c[0].e[1] = -(b[0] * s00 - b[2] * s03 + b[3] * s04);
        r.c[0].e[2] = b[0] * s01 - b[1] * s03 + b[3] * s05;
        r.c[0].e[3] = -(b[0] * s02 - b[1] * s04 + b[2] * s05);
        r.c[1].e[0] = -(a[1] * s00 - a[2] * s01 + a[3] * s02);
        r.c[1].e[1] = a[0] * s00 - a[2] * s03 + a[3] * s04;
        r.c[1].e[2] = -(a[0] * s01 - a[1] * s03 + a[3] * s05);
        r.c[1].e[3] = a[0] * s02 - a[1] * s04 + a[2] * s05;
        r.c[2].e[0] = a[1] * s06 - a[2] * s07 + a[3] * s08;
        r.c[2].e[1] = -(a[0] * s06 - a[2] * s09 + a[3] * s10);
        r.c[2].e[2] = a[0] * s07 - a[1] * s09 + a[3] * s11;
        r.c[2].e[3] = -(a[0] * s08 - a[1] * s10 + a[2] * s11);
        r.c[3].e[0] = -(a[1] * s12 - a[2] * s13 + a[3] * s14);
        r.c[3].e[1] = a[0] * s12 - a[2] * s15 + a[3] * s16;
        r.c[3].e[2] = -(a[0] * s13 - a[1] * s15 + a[3] * s17);
        r.c[3].e[3] = a[0] * s14 - a[1] * s16 + a[2] * s17;
        let d = a[0] * r.c[0].e[0] + a[1] * r.c[0].e[1] + a[2] * r.c[0].e[2] + a[3] * r.c[0].e[3];
        for k in 0..4 {
            for j in 0..4 {
                r.c[k].e[j] = r.c[k].e[j] / d;
            }
        }
    }
    return r;
}

/// The identity with `v` on the main diagonal.
pub fn diagonal2x2<T: Scalar>(v: Vec<T, 2>) Mat<T, 2, 2> {
    return diagonal_of(v);
}

/// The 2x3 identity with `v` on the main diagonal.
pub fn diagonal2x3<T: Scalar>(v: Vec<T, 2>) Mat<T, 2, 3> {
    return diagonal_of(v);
}

/// The 2x4 identity with `v` on the main diagonal.
pub fn diagonal2x4<T: Scalar>(v: Vec<T, 2>) Mat<T, 2, 4> {
    return diagonal_of(v);
}

/// The 3x2 identity with `v` on the main diagonal.
pub fn diagonal3x2<T: Scalar>(v: Vec<T, 2>) Mat<T, 3, 2> {
    return diagonal_of(v);
}

/// The identity with `v` on the main diagonal.
pub fn diagonal3x3<T: Scalar>(v: Vec<T, 3>) Mat<T, 3, 3> {
    return diagonal_of(v);
}

/// The 3x4 identity with `v` on the main diagonal.
pub fn diagonal3x4<T: Scalar>(v: Vec<T, 3>) Mat<T, 3, 4> {
    return diagonal_of(v);
}

/// The 4x2 identity with `v` on the main diagonal.
pub fn diagonal4x2<T: Scalar>(v: Vec<T, 2>) Mat<T, 4, 2> {
    return diagonal_of(v);
}

/// The 4x3 identity with `v` on the main diagonal.
pub fn diagonal4x3<T: Scalar>(v: Vec<T, 3>) Mat<T, 4, 3> {
    return diagonal_of(v);
}

/// The identity with `v` on the main diagonal.
pub fn diagonal4x4<T: Scalar>(v: Vec<T, 4>) Mat<T, 4, 4> {
    return diagonal_of(v);
}

// The C x R identity with the N <= min(C, R) components of `v` on the main diagonal.
fn diagonal_of<T: Scalar, const C: usize, const R: usize, const N: usize>(v: Vec<T, N>) Mat<T, C, R> {
    static_assert(N <= C && N <= R, "diagonal longer than the matrix");
    let mut r = Mat::<T, C, R>::identity();
    for i in 0..N {
        unsafe {
            r.c[i].e[i] = v.e[i];
        }
    }
    return r;
}

/// A matrix `adjugate` takes: a 2x2, 3x3 or 4x4 matrix.
pub interface Adjugate: Copy {
    fn adjugate(self: Self) Self;
}

/// The transposed cofactor matrix, each cofactor the `determinant` of the minor (so
/// `adjugate(m) = determinant(m) * inverse(m)` up to rounding). Integers negate and multiply as in the
/// other matrix operations.
pub fn adjugate<G: Adjugate>(m: G) G {
    return m.adjugate();
}

extend<T: Scalar> Mat<T, 2, 2> as Adjugate {
    pub fn adjugate(self: Mat<T, 2, 2>) Mat<T, 2, 2> {
        let m = self.c;
        return Mat::<T, 2, 2>::new(m[1].e[1], -m[0].e[1], -m[1].e[0], m[0].e[0]);
    }
}

extend<T: Scalar> Mat<T, 3, 3> as Adjugate {
    pub fn adjugate(self: Mat<T, 3, 3>) Mat<T, 3, 3> {
        let m = self.c;
        let m00 = determinant(Mat::<T, 2, 2>::new(m[1].e[1], m[2].e[1], m[1].e[2], m[2].e[2]));
        let m01 = determinant(Mat::<T, 2, 2>::new(m[0].e[1], m[2].e[1], m[0].e[2], m[2].e[2]));
        let m02 = determinant(Mat::<T, 2, 2>::new(m[0].e[1], m[1].e[1], m[0].e[2], m[1].e[2]));
        let m10 = determinant(Mat::<T, 2, 2>::new(m[1].e[0], m[2].e[0], m[1].e[2], m[2].e[2]));
        let m11 = determinant(Mat::<T, 2, 2>::new(m[0].e[0], m[2].e[0], m[0].e[2], m[2].e[2]));
        let m12 = determinant(Mat::<T, 2, 2>::new(m[0].e[0], m[1].e[0], m[0].e[2], m[1].e[2]));
        let m20 = determinant(Mat::<T, 2, 2>::new(m[1].e[0], m[2].e[0], m[1].e[1], m[2].e[1]));
        let m21 = determinant(Mat::<T, 2, 2>::new(m[0].e[0], m[2].e[0], m[0].e[1], m[2].e[1]));
        let m22 = determinant(Mat::<T, 2, 2>::new(m[0].e[0], m[1].e[0], m[0].e[1], m[1].e[1]));
        return Mat::<T, 3, 3>::new(m00, -m01, m02, -m10, m11, -m12, m20, -m21, m22);
    }
}

extend<T: Scalar> Mat<T, 4, 4> as Adjugate {
    pub fn adjugate(self: Mat<T, 4, 4>) Mat<T, 4, 4> {
        let (a, b, c, d) = (self.c[0].e, self.c[1].e, self.c[2].e, self.c[3].e);
        let m00 = determinant(Mat::<T, 3, 3>::new(b[1], b[2], b[3], c[1], c[2], c[3], d[1], d[2], d[3]));
        let m01 = determinant(Mat::<T, 3, 3>::new(b[0], b[2], b[3], c[0], c[2], c[3], d[0], d[2], d[3]));
        let m02 = determinant(Mat::<T, 3, 3>::new(b[0], b[1], b[3], c[0], c[1], c[3], d[0], d[1], d[3]));
        let m03 = determinant(Mat::<T, 3, 3>::new(b[0], b[1], b[2], c[0], c[1], c[2], d[0], d[1], d[2]));
        let m10 = determinant(Mat::<T, 3, 3>::new(a[1], a[2], a[3], c[1], c[2], c[3], d[1], d[2], d[3]));
        let m11 = determinant(Mat::<T, 3, 3>::new(a[0], a[2], a[3], c[0], c[2], c[3], d[0], d[2], d[3]));
        let m12 = determinant(Mat::<T, 3, 3>::new(a[0], a[1], a[3], c[0], c[1], c[3], d[0], d[1], d[3]));
        let m13 = determinant(Mat::<T, 3, 3>::new(a[0], a[1], a[2], c[0], c[1], c[2], d[0], d[1], d[2]));
        let m20 = determinant(Mat::<T, 3, 3>::new(a[1], a[2], a[3], b[1], b[2], b[3], d[1], d[2], d[3]));
        let m21 = determinant(Mat::<T, 3, 3>::new(a[0], a[2], a[3], b[0], b[2], b[3], d[0], d[2], d[3]));
        let m22 = determinant(Mat::<T, 3, 3>::new(a[0], a[1], a[3], b[0], b[1], b[3], d[0], d[1], d[3]));
        let m23 = determinant(Mat::<T, 3, 3>::new(a[0], a[1], a[2], b[0], b[1], b[2], d[0], d[1], d[2]));
        let m30 = determinant(Mat::<T, 3, 3>::new(a[1], a[2], a[3], b[1], b[2], b[3], c[1], c[2], c[3]));
        let m31 = determinant(Mat::<T, 3, 3>::new(a[0], a[2], a[3], b[0], b[2], b[3], c[0], c[2], c[3]));
        let m32 = determinant(Mat::<T, 3, 3>::new(a[0], a[1], a[3], b[0], b[1], b[3], c[0], c[1], c[3]));
        let m33 = determinant(Mat::<T, 3, 3>::new(a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2]));
        return Mat::<T, 4, 4>::new(
            m00,
            -m10,
            m20,
            -m30,
            -m01,
            m11,
            -m21,
            m31,
            m02,
            -m12,
            m22,
            -m32,
            -m03,
            m13,
            -m23,
            m33,
        );
    }
}
