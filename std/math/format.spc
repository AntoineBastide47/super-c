// Text and hash of vectors, matrices, quaternions and dual quaternions. `to_string` and the `Format`
// conformances give the type prefix (`d` for f64, `i` for i32, `u8`, `f128`, ..: `Scalar::push_name`), each
// built-in float as C's `%f` of the value as an f64, each built-in integer as C's `%d` of its low 32 bits as
// a signed int (a `u32` above `i32::MAX` or a large 64-bit value prints as that int), an `Int<N>` or
// `UInt<N>` as its decimal value, a float format wider than f64 as its own `to_string`
// (`Scalar::push_value`), and cut the text at 4095 bytes. There are no precision, width, delimiter or
// order options. The `Hash` conformances combine
// the component hashes (an integer's low 64 bits, an f32's or f64's bits, a float format's nearest f64's
// bits, 0 for both zeros), so values equal under `==` hash equally.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::quat as *;
import std::math::dual_quat as *;

const TEXT_BYTES_MAX: usize = 4095;

/// The text of a vector, a matrix, a quaternion or a dual quaternion, as its `fmt`
/// gives it (`vec3(1.000000, 2.000000, 3.000000)`, `imat2x2((1, 2), (3, 4))`, `dquat(1.000000, {0.000000,
/// ..})`).
pub fn to_string<G: Format + Copy>(x: G) String {
    return x.fmt();
}

// The components of `v` separated by ", ".
fn push_components<T: Scalar, const N: usize>(s: &mut String, v: &Vec<T, N>) {
    for i in 0..N {
        if i > 0 {
            s.push_str(", ");
        }
        T::push_value(s, unsafe v.e[i]);
    }
}

// A quaternion as `to_string` writes it inside the parentheses: `w, {x, y, z}`.
fn push_quat_parts<T: Float>(s: &mut String, q: &Quat<T>) {
    T::push_value(s, q.w);
    s.push_str(", {");
    T::push_value(s, q.x);
    s.push_str(", ");
    T::push_value(s, q.y);
    s.push_str(", ");
    T::push_value(s, q.z);
    s.push_str("}");
}

// `seed ^ (h + (0x9e3779b9 + (seed << 6) + (seed >> 2)))`, wrapping.
fn hash_combine(seed: u64, h: u64) u64 {
    return seed ^ h.wrapping_add(0x9e3779b9u64.wrapping_add(seed << 6).wrapping_add(seed >> 2));
}

// An integer's value (sign-extended), a float's bits (zero-extended for f32), 0 for +0.0 and -0.0, which
// compare equal.
fn component_hash<T: Scalar>(v: T) u64 {
    if T::is_float() {
        if sizeof(T) == 4 {
            // Selected as a u32, then widened: the C compiler vectorizes this form 4 lanes wide, a u64
            // select 2 lanes wide.
            let x = v.cast::<f32>();
            let bits = if x == 0.0 {
                0u32;
            } else {
                f32_bits(x);
            };
            return bits;
        }
        let x = v.cast::<f64>();
        if x == 0.0 {
            return 0;
        }
        return f64_bits(x);
    }
    return v.cast::<i64>() as u64;
}

extend<T: Scalar, const N: usize> Vec<T, N> as Format {
    /// `<prefix>vecN(x, y, ..)`.
    pub fn fmt(self: &Vec<T, N>) String {
        let mut s = String::new();
        T::push_name(&mut s);
        s.push_str("vec");
        s.push_u64(N as u64);
        s.push_str("(");
        push_components(&mut s, self);
        s.push_str(")");
        return s;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Hash {
    /// A vec1 hashes as its component, a longer vector combines its components x first. Equal vectors
    /// (`==`, IEEE) hash equally: +0.0 and -0.0 hash as 0.
    pub fn hash(self: &Vec<T, N>) u64 {
        if N == 1 {
            return component_hash(self.e[0]);
        }
        let mut seed: u64 = 0;
        for i in 0..N {
            seed = hash_combine(seed, component_hash(unsafe self.e[i]));
        }
        return seed;
    }
}

extend<const N: usize> Vec<bool, N> as Format {
    /// `bvecN(true, false, ..)`.
    pub fn fmt(self: &Vec<bool, N>) String {
        let mut s = String::new();
        s.push_str("bvec");
        s.push_u64(N as u64);
        s.push_str("(");
        for i in 0..N {
            if i > 0 {
                s.push_str(", ");
            }
            s.push_str(
                if unsafe self.e[i] {
                    "true";
                } else {
                    "false";
                },
            );
        }
        s.push_str(")");
        return s;
    }
}

extend<const N: usize> Vec<bool, N> as Hash {
    /// A vec1 hashes as its component (0 or 1), a longer vector combines its components x first.
    pub fn hash(self: &Vec<bool, N>) u64 {
        if N == 1 {
            return self.e[0] as u64;
        }
        let mut seed: u64 = 0;
        for i in 0..N {
            seed = hash_combine(seed, (unsafe self.e[i]) as u64);
        }
        return seed;
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Format {
    /// `<prefix>matCxR((c0r0, c0r1, ..), (c1r0, ..), ..)`, column by column, square matrices included
    /// (`mat2x2`, not `mat2`).
    pub fn fmt(self: &Mat<T, C, R>) String {
        let mut s = String::new();
        T::push_name(&mut s);
        s.push_str("mat");
        s.push_u64(C as u64);
        s.push_str("x");
        s.push_u64(R as u64);
        s.push_str("(");
        for i in 0..C {
            if i > 0 {
                s.push_str(", ");
            }
            s.push_str("(");
            push_components(&mut s, unsafe &self.c[i]);
            s.push_str(")");
        }
        s.push_str(")");
        // Only a `dmat4x4` of huge values reaches the cut.
        s.truncate(TEXT_BYTES_MAX);
        return s;
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Hash {
    /// The column hashes combined, column 0 first.
    pub fn hash(self: &Mat<T, C, R>) u64 {
        let mut seed: u64 = 0;
        for i in 0..C {
            seed = hash_combine(seed, unsafe self.c[i].hash());
        }
        return seed;
    }
}

extend<T: Float> Quat<T> as Format {
    /// `<prefix>quat(w, {x, y, z})`.
    pub fn fmt(self: &Quat<T>) String {
        let mut s = String::new();
        T::push_name(&mut s);
        s.push_str("quat(");
        push_quat_parts(&mut s, self);
        s.push_str(")");
        return s;
    }
}

extend<T: Float> Quat<T> as Hash {
    /// The component hashes combined x, y, z, then w.
    pub fn hash(self: &Quat<T>) u64 {
        let mut seed = hash_combine(0, component_hash(self.x));
        seed = hash_combine(seed, component_hash(self.y));
        seed = hash_combine(seed, component_hash(self.z));
        return hash_combine(seed, component_hash(self.w));
    }
}

extend<T: Float> DualQuat<T> as Format {
    /// `<prefix>dualquat((w, {x, y, z}), (w, {x, y, z}))`, the real part first.
    pub fn fmt(self: &DualQuat<T>) String {
        let mut s = String::new();
        T::push_name(&mut s);
        s.push_str("dualquat((");
        push_quat_parts(&mut s, &self.real);
        s.push_str("), (");
        push_quat_parts(&mut s, &self.dual);
        s.push_str("))");
        return s;
    }
}

extend<T: Float> DualQuat<T> as Hash {
    /// The hashes of the real and the dual quaternion combined.
    pub fn hash(self: &DualQuat<T>) u64 {
        return hash_combine(hash_combine(0, self.real.hash()), self.dual.hash());
    }
}
