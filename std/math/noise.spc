// Gradient noise after Stefan Gustavson's and Ashima Arts' webgl-noise: classic Perlin noise, its
// periodic variant and simplex noise on f32 and f64 positions of 2, 3 or 4 components. Keep the operation
// order and constants: the tests check exact result bits. The three functions dispatch on the vector size
// through `Noise`.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::common as *;
import std::math::geometric as *;

/// A position `perlin`, `perlin_periodic` and `simplex` take: an f32 or f64 `Vec<T, 2>`, `Vec<T, 3>` or
/// `Vec<T, 4>`.
pub interface Noise<T: Float>: Copy {
    fn perlin(self: Self) T;
    fn perlin_periodic(self: Self, rep: Self) T;
    fn simplex(self: Self) T;
}

/// Classic Perlin noise at `position`, about in [-1, 1], 0 at integer positions.
pub fn perlin<T: Float, V: Noise<T>>(position: V) T {
    return position.perlin();
}

/// Classic Perlin noise of period `rep` in each component (an integer period gives a tiling noise).
pub fn perlin_periodic<T: Float, V: Noise<T>>(position: V, rep: V) T {
    return position.perlin_periodic(rep);
}

/// Simplex noise at `position`, about in [-1, 1]. The f64 3D form reaches about 3.3 in magnitude near
/// some positions: its 1/7 constant `0.142857142857` is low in f64.
pub fn simplex<T: Float, V: Noise<T>>(position: V) T {
    return position.simplex();
}

extend<T: Float> Vec<T, 2> as Noise<T> {
    pub fn perlin(self: Vec<T, 2>) T {
        let p = self.swizzle4::<0, 1, 0, 1>();
        let pi = floor(p) + Vec::<T, 4>::new(T::zero(), T::zero(), T::one(), T::one());
        let pf = fract(p) - Vec::<T, 4>::new(T::zero(), T::zero(), T::one(), T::one());
        return perlin2(mod(pi, Vec::<T, 4>::splat(T::from_i64(289))), pf);
    }
    pub fn perlin_periodic(self: Vec<T, 2>, rep: Vec<T, 2>) T {
        let p = self.swizzle4::<0, 1, 0, 1>();
        let mut pi = floor(p) + Vec::<T, 4>::new(T::zero(), T::zero(), T::one(), T::one());
        let pf = fract(p) - Vec::<T, 4>::new(T::zero(), T::zero(), T::one(), T::one());
        pi = mod(pi, rep.swizzle4::<0, 1, 0, 1>());
        return perlin2(mod(pi, Vec::<T, 4>::splat(T::from_i64(289))), pf);
    }
    pub fn simplex(self: Vec<T, 2>) T {
        return simplex2(self);
    }
}

extend<T: Float> Vec<T, 3> as Noise<T> {
    pub fn perlin(self: Vec<T, 3>) T {
        let pi0 = floor(self);
        let pi1 = pi0 + T::one();
        let pf0 = fract(self);
        return perlin3(mod289(pi0), mod289(pi1), pf0, false);
    }
    pub fn perlin_periodic(self: Vec<T, 3>, rep: Vec<T, 3>) T {
        let pi0 = mod(floor(self), rep);
        let pi1 = mod(pi0 + Vec::<T, 3>::splat(T::one()), rep);
        let m = Vec::<T, 3>::splat(T::from_i64(289));
        return perlin3(mod(pi0, m), mod(pi1, m), fract(self), true);
    }
    pub fn simplex(self: Vec<T, 3>) T {
        return simplex3(self);
    }
}

extend<T: Float> Vec<T, 4> as Noise<T> {
    pub fn perlin(self: Vec<T, 4>) T {
        let pi0 = floor(self);
        let pi1 = pi0 + T::one();
        let m = Vec::<T, 4>::splat(T::from_i64(289));
        return perlin4(mod(pi0, m), mod(pi1, m), fract(self));
    }
    pub fn perlin_periodic(self: Vec<T, 4>, rep: Vec<T, 4>) T {
        let pi0 = mod(floor(self), rep);
        let pi1 = mod(pi0 + T::one(), rep);
        return perlin4(pi0, pi1, fract(self));
    }
    pub fn simplex(self: Vec<T, 4>) T {
        return simplex4(self);
    }
}

// x modulo 289, computed as `x - floor(x * (1 / 289)) * 289`.
fn mod289_of<T: Float>(x: T) T {
    return x - (x * (T::one() / T::from_f64(289.0))).floor() * T::from_f64(289.0);
}

// The permutation polynomial `(34 x^2 + x) mod 289`, computed as `mod289((x * 34 + 1) * x)`.
fn permute_of<T: Float>(x: T) T {
    return mod289_of((x * T::from_i64(34) + T::one()) * x);
}

// The first-order Taylor approximation of `1 / sqrt(r)` at r = 0.7:
// `1.79284291400159 - 0.85373472095314 * r`.
fn taylor_inv_sqrt_of<T: Float>(r: T) T {
    return T::from_f64(1.79284291400159) - T::from_f64(0.85373472095314) * r;
}

// `mod289_of` of each component.
fn mod289<T: Float, const N: usize>(x: Vec<T, N>) Vec<T, N> {
    let mut r = x;
    for i in 0..N {
        unsafe {
            r.e[i] = mod289_of(x.e[i]);
        }
    }
    return r;
}

// `permute_of` of each component.
fn permute<T: Float, const N: usize>(x: Vec<T, N>) Vec<T, N> {
    let mut r = x;
    for i in 0..N {
        unsafe {
            r.e[i] = permute_of(x.e[i]);
        }
    }
    return r;
}

// `taylor_inv_sqrt_of` of each component.
fn taylor_inv_sqrt<T: Float, const N: usize>(r: Vec<T, N>) Vec<T, N> {
    let mut o = r;
    for i in 0..N {
        unsafe {
            o.e[i] = taylor_inv_sqrt_of(r.e[i]);
        }
    }
    return o;
}

// The fade curve `6 t^5 - 15 t^4 + 10 t^3` of each component, computed as
// `(t * t * t) * (t * (t * 6 - 15) + 10)`.
fn fade<T: Float, const N: usize>(t: Vec<T, N>) Vec<T, N> {
    return t * t * t * (t * (t * T::from_i64(6) - T::from_i64(15)) + T::from_i64(10));
}

// `x * (1 - a) + y * a` for each component, with a scalar float `a`.
fn lerp<T: Float, G: Gen<T>>(x: G, y: G, a: T) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i) * (T::one() - a) + y.at(i) * a);
    }
    return r;
}

// The 2D Perlin noise after the lattice corners `pi` (x0, y0, x1, y1, reduced modulo 289) and the
// offsets `pf` to them are known.
fn perlin2<T: Float>(pi: Vec<T, 4>, pf: Vec<T, 4>) T {
    let ix = pi.swizzle4::<0, 2, 0, 2>();
    let iy = pi.swizzle4::<1, 1, 3, 3>();
    let fx = pf.swizzle4::<0, 2, 0, 2>();
    let fy = pf.swizzle4::<1, 1, 3, 3>();

    let i = permute(permute(ix) + iy);

    let mut gx = T::from_i64(2) * fract(i / T::from_i64(41)) - T::one();
    let gy = abs(gx) - T::from_f64(0.5);
    let tx = floor(gx + T::from_f64(0.5));
    gx = gx - tx;

    let mut g00 = Vec::<T, 2>::new(gx.e[0], gy.e[0]);
    let mut g10 = Vec::<T, 2>::new(gx.e[1], gy.e[1]);
    let mut g01 = Vec::<T, 2>::new(gx.e[2], gy.e[2]);
    let mut g11 = Vec::<T, 2>::new(gx.e[3], gy.e[3]);

    let norm = taylor_inv_sqrt(Vec::<T, 4>::new(dot(g00, g00), dot(g01, g01), dot(g10, g10), dot(g11, g11)));
    g00 = g00 * norm.e[0];
    g01 = g01 * norm.e[1];
    g10 = g10 * norm.e[2];
    g11 = g11 * norm.e[3];

    let n00 = dot(g00, Vec::<T, 2>::new(fx.e[0], fy.e[0]));
    let n10 = dot(g10, Vec::<T, 2>::new(fx.e[1], fy.e[1]));
    let n01 = dot(g01, Vec::<T, 2>::new(fx.e[2], fy.e[2]));
    let n11 = dot(g11, Vec::<T, 2>::new(fx.e[3], fy.e[3]));

    let fade_xy = fade(Vec::<T, 2>::new(pf.e[0], pf.e[1]));
    let n_x = lerp(Vec::<T, 2>::new(n00, n01), Vec::<T, 2>::new(n10, n11), fade_xy.e[0]);
    let n_xy = lerp(n_x.e[0], n_x.e[1], fade_xy.e[1]);
    return T::from_f64(2.3) * n_xy;
}

// The gradients of one z layer of the 3D Perlin noise. The plain noise multiplies by `T(1.0 / 7.0)`, the
// periodic one divides by `T(7)`; keep both forms, as they can differ in the last bit.
fn grad3_layer<T: Float>(ixy: Vec<T, 4>, periodic: bool) (Vec<T, 4>, Vec<T, 4>, Vec<T, 4>) {
    let mut gx = if periodic {
        ixy / T::from_i64(7);
    } else {
        ixy * T::from_f64(1.0 / 7.0);
    };
    let mut gy = if periodic {
        fract(floor(gx) / T::from_i64(7)) - T::from_f64(0.5);
    } else {
        fract(floor(gx) * T::from_f64(1.0 / 7.0)) - T::from_f64(0.5);
    };
    gx = fract(gx);
    let gz = Vec::<T, 4>::splat(T::from_f64(0.5)) - abs(gx) - abs(gy);
    let sz = step(gz, Vec::<T, 4>::zero());
    gx = gx - sz * (step(T::zero(), gx) - T::from_f64(0.5));
    gy = gy - sz * (step(T::zero(), gy) - T::from_f64(0.5));
    return gx, gy, gz;
}

// The 3D Perlin noise after the lattice corners `pi0`, `pi1` (reduced modulo 289) and the offset `pf0`
// to `pi0` are known.
fn perlin3<T: Float>(pi0: Vec<T, 3>, pi1: Vec<T, 3>, pf0: Vec<T, 3>, periodic: bool) T {
    let pf1 = pf0 - T::one();
    let ix = Vec::<T, 4>::new(pi0.e[0], pi1.e[0], pi0.e[0], pi1.e[0]);
    let iy = Vec::<T, 4>::new(pi0.e[1], pi0.e[1], pi1.e[1], pi1.e[1]);
    let iz0 = Vec::<T, 4>::splat(pi0.e[2]);
    let iz1 = Vec::<T, 4>::splat(pi1.e[2]);

    let ixy = permute(permute(ix) + iy);
    let ixy0 = permute(ixy + iz0);
    let ixy1 = permute(ixy + iz1);

    let (gx0, gy0, gz0) = grad3_layer(ixy0, periodic);
    let (gx1, gy1, gz1) = grad3_layer(ixy1, periodic);

    let mut g000 = Vec::<T, 3>::new(gx0.e[0], gy0.e[0], gz0.e[0]);
    let mut g100 = Vec::<T, 3>::new(gx0.e[1], gy0.e[1], gz0.e[1]);
    let mut g010 = Vec::<T, 3>::new(gx0.e[2], gy0.e[2], gz0.e[2]);
    let mut g110 = Vec::<T, 3>::new(gx0.e[3], gy0.e[3], gz0.e[3]);
    let mut g001 = Vec::<T, 3>::new(gx1.e[0], gy1.e[0], gz1.e[0]);
    let mut g101 = Vec::<T, 3>::new(gx1.e[1], gy1.e[1], gz1.e[1]);
    let mut g011 = Vec::<T, 3>::new(gx1.e[2], gy1.e[2], gz1.e[2]);
    let mut g111 = Vec::<T, 3>::new(gx1.e[3], gy1.e[3], gz1.e[3]);

    let norm0 = taylor_inv_sqrt(Vec::<T, 4>::new(dot(g000, g000), dot(g010, g010), dot(g100, g100), dot(g110, g110)));
    g000 = g000 * norm0.e[0];
    g010 = g010 * norm0.e[1];
    g100 = g100 * norm0.e[2];
    g110 = g110 * norm0.e[3];
    let norm1 = taylor_inv_sqrt(Vec::<T, 4>::new(dot(g001, g001), dot(g011, g011), dot(g101, g101), dot(g111, g111)));
    g001 = g001 * norm1.e[0];
    g011 = g011 * norm1.e[1];
    g101 = g101 * norm1.e[2];
    g111 = g111 * norm1.e[3];

    let n000 = dot(g000, pf0);
    let n100 = dot(g100, Vec::<T, 3>::new(pf1.e[0], pf0.e[1], pf0.e[2]));
    let n010 = dot(g010, Vec::<T, 3>::new(pf0.e[0], pf1.e[1], pf0.e[2]));
    let n110 = dot(g110, Vec::<T, 3>::new(pf1.e[0], pf1.e[1], pf0.e[2]));
    let n001 = dot(g001, Vec::<T, 3>::new(pf0.e[0], pf0.e[1], pf1.e[2]));
    let n101 = dot(g101, Vec::<T, 3>::new(pf1.e[0], pf0.e[1], pf1.e[2]));
    let n011 = dot(g011, Vec::<T, 3>::new(pf0.e[0], pf1.e[1], pf1.e[2]));
    let n111 = dot(g111, pf1);

    let fade_xyz = fade(pf0);
    let n_z = lerp(Vec::<T, 4>::new(n000, n100, n010, n110), Vec::<T, 4>::new(n001, n101, n011, n111), fade_xyz.e[2]);
    let n_yz = lerp(Vec::<T, 2>::new(n_z.e[0], n_z.e[1]), Vec::<T, 2>::new(n_z.e[2], n_z.e[3]), fade_xyz.e[1]);
    let n_xyz = lerp(n_yz.e[0], n_yz.e[1], fade_xyz.e[0]);
    return T::from_f64(2.2) * n_xyz;
}

// The gradients of one (z, w) layer of the 4D Perlin noise.
fn grad4_layer<T: Float>(ixy: Vec<T, 4>) (Vec<T, 4>, Vec<T, 4>, Vec<T, 4>, Vec<T, 4>) {
    let mut gx = ixy / T::from_i64(7);
    let mut gy = floor(gx) / T::from_i64(7);
    let mut gz = floor(gy) / T::from_i64(6);
    gx = fract(gx) - T::from_f64(0.5);
    gy = fract(gy) - T::from_f64(0.5);
    gz = fract(gz) - T::from_f64(0.5);
    let gw = Vec::<T, 4>::splat(T::from_f64(0.75)) - abs(gx) - abs(gy) - abs(gz);
    let sw = step(gw, Vec::<T, 4>::zero());
    gx = gx - sw * (step(T::zero(), gx) - T::from_f64(0.5));
    gy = gy - sw * (step(T::zero(), gy) - T::from_f64(0.5));
    return gx, gy, gz, gw;
}

// The 4D Perlin noise after the lattice corners `pi0`, `pi1` and the offset `pf0` to `pi0` are known.
fn perlin4<T: Float>(pi0: Vec<T, 4>, pi1: Vec<T, 4>, pf0: Vec<T, 4>) T {
    let pf1 = pf0 - T::one();
    let ix = Vec::<T, 4>::new(pi0.e[0], pi1.e[0], pi0.e[0], pi1.e[0]);
    let iy = Vec::<T, 4>::new(pi0.e[1], pi0.e[1], pi1.e[1], pi1.e[1]);
    let iz0 = Vec::<T, 4>::splat(pi0.e[2]);
    let iz1 = Vec::<T, 4>::splat(pi1.e[2]);
    let iw0 = Vec::<T, 4>::splat(pi0.e[3]);
    let iw1 = Vec::<T, 4>::splat(pi1.e[3]);

    let ixy = permute(permute(ix) + iy);
    let ixy0 = permute(ixy + iz0);
    let ixy1 = permute(ixy + iz1);
    let ixy00 = permute(ixy0 + iw0);
    let ixy01 = permute(ixy0 + iw1);
    let ixy10 = permute(ixy1 + iw0);
    let ixy11 = permute(ixy1 + iw1);

    let (gx00, gy00, gz00, gw00) = grad4_layer(ixy00);
    let (gx01, gy01, gz01, gw01) = grad4_layer(ixy01);
    let (gx10, gy10, gz10, gw10) = grad4_layer(ixy10);
    let (gx11, gy11, gz11, gw11) = grad4_layer(ixy11);

    let mut g0000 = Vec::<T, 4>::new(gx00.e[0], gy00.e[0], gz00.e[0], gw00.e[0]);
    let mut g1000 = Vec::<T, 4>::new(gx00.e[1], gy00.e[1], gz00.e[1], gw00.e[1]);
    let mut g0100 = Vec::<T, 4>::new(gx00.e[2], gy00.e[2], gz00.e[2], gw00.e[2]);
    let mut g1100 = Vec::<T, 4>::new(gx00.e[3], gy00.e[3], gz00.e[3], gw00.e[3]);
    let mut g0010 = Vec::<T, 4>::new(gx10.e[0], gy10.e[0], gz10.e[0], gw10.e[0]);
    let mut g1010 = Vec::<T, 4>::new(gx10.e[1], gy10.e[1], gz10.e[1], gw10.e[1]);
    let mut g0110 = Vec::<T, 4>::new(gx10.e[2], gy10.e[2], gz10.e[2], gw10.e[2]);
    let mut g1110 = Vec::<T, 4>::new(gx10.e[3], gy10.e[3], gz10.e[3], gw10.e[3]);
    let mut g0001 = Vec::<T, 4>::new(gx01.e[0], gy01.e[0], gz01.e[0], gw01.e[0]);
    let mut g1001 = Vec::<T, 4>::new(gx01.e[1], gy01.e[1], gz01.e[1], gw01.e[1]);
    let mut g0101 = Vec::<T, 4>::new(gx01.e[2], gy01.e[2], gz01.e[2], gw01.e[2]);
    let mut g1101 = Vec::<T, 4>::new(gx01.e[3], gy01.e[3], gz01.e[3], gw01.e[3]);
    let mut g0011 = Vec::<T, 4>::new(gx11.e[0], gy11.e[0], gz11.e[0], gw11.e[0]);
    let mut g1011 = Vec::<T, 4>::new(gx11.e[1], gy11.e[1], gz11.e[1], gw11.e[1]);
    let mut g0111 = Vec::<T, 4>::new(gx11.e[2], gy11.e[2], gz11.e[2], gw11.e[2]);
    let mut g1111 = Vec::<T, 4>::new(gx11.e[3], gy11.e[3], gz11.e[3], gw11.e[3]);

    let norm00 = taylor_inv_sqrt(
        Vec::<T, 4>::new(dot(g0000, g0000), dot(g0100, g0100), dot(g1000, g1000), dot(g1100, g1100)),
    );
    g0000 = g0000 * norm00.e[0];
    g0100 = g0100 * norm00.e[1];
    g1000 = g1000 * norm00.e[2];
    g1100 = g1100 * norm00.e[3];

    let norm01 = taylor_inv_sqrt(
        Vec::<T, 4>::new(dot(g0001, g0001), dot(g0101, g0101), dot(g1001, g1001), dot(g1101, g1101)),
    );
    g0001 = g0001 * norm01.e[0];
    g0101 = g0101 * norm01.e[1];
    g1001 = g1001 * norm01.e[2];
    g1101 = g1101 * norm01.e[3];

    let norm10 = taylor_inv_sqrt(
        Vec::<T, 4>::new(dot(g0010, g0010), dot(g0110, g0110), dot(g1010, g1010), dot(g1110, g1110)),
    );
    g0010 = g0010 * norm10.e[0];
    g0110 = g0110 * norm10.e[1];
    g1010 = g1010 * norm10.e[2];
    g1110 = g1110 * norm10.e[3];

    let norm11 = taylor_inv_sqrt(
        Vec::<T, 4>::new(dot(g0011, g0011), dot(g0111, g0111), dot(g1011, g1011), dot(g1111, g1111)),
    );
    g0011 = g0011 * norm11.e[0];
    g0111 = g0111 * norm11.e[1];
    g1011 = g1011 * norm11.e[2];
    g1111 = g1111 * norm11.e[3];

    let n0000 = dot(g0000, pf0);
    let n1000 = dot(g1000, Vec::<T, 4>::new(pf1.e[0], pf0.e[1], pf0.e[2], pf0.e[3]));
    let n0100 = dot(g0100, Vec::<T, 4>::new(pf0.e[0], pf1.e[1], pf0.e[2], pf0.e[3]));
    let n1100 = dot(g1100, Vec::<T, 4>::new(pf1.e[0], pf1.e[1], pf0.e[2], pf0.e[3]));
    let n0010 = dot(g0010, Vec::<T, 4>::new(pf0.e[0], pf0.e[1], pf1.e[2], pf0.e[3]));
    let n1010 = dot(g1010, Vec::<T, 4>::new(pf1.e[0], pf0.e[1], pf1.e[2], pf0.e[3]));
    let n0110 = dot(g0110, Vec::<T, 4>::new(pf0.e[0], pf1.e[1], pf1.e[2], pf0.e[3]));
    let n1110 = dot(g1110, Vec::<T, 4>::new(pf1.e[0], pf1.e[1], pf1.e[2], pf0.e[3]));
    let n0001 = dot(g0001, Vec::<T, 4>::new(pf0.e[0], pf0.e[1], pf0.e[2], pf1.e[3]));
    let n1001 = dot(g1001, Vec::<T, 4>::new(pf1.e[0], pf0.e[1], pf0.e[2], pf1.e[3]));
    let n0101 = dot(g0101, Vec::<T, 4>::new(pf0.e[0], pf1.e[1], pf0.e[2], pf1.e[3]));
    let n1101 = dot(g1101, Vec::<T, 4>::new(pf1.e[0], pf1.e[1], pf0.e[2], pf1.e[3]));
    let n0011 = dot(g0011, Vec::<T, 4>::new(pf0.e[0], pf0.e[1], pf1.e[2], pf1.e[3]));
    let n1011 = dot(g1011, Vec::<T, 4>::new(pf1.e[0], pf0.e[1], pf1.e[2], pf1.e[3]));
    let n0111 = dot(g0111, Vec::<T, 4>::new(pf0.e[0], pf1.e[1], pf1.e[2], pf1.e[3]));
    let n1111 = dot(g1111, pf1);

    let fade_xyzw = fade(pf0);
    let n_0w = lerp(
        Vec::<T, 4>::new(n0000, n1000, n0100, n1100),
        Vec::<T, 4>::new(n0001, n1001, n0101, n1101),
        fade_xyzw.e[3],
    );
    let n_1w = lerp(
        Vec::<T, 4>::new(n0010, n1010, n0110, n1110),
        Vec::<T, 4>::new(n0011, n1011, n0111, n1111),
        fade_xyzw.e[3],
    );
    let n_zw = lerp(n_0w, n_1w, fade_xyzw.e[2]);
    let n_yzw = lerp(Vec::<T, 2>::new(n_zw.e[0], n_zw.e[1]), Vec::<T, 2>::new(n_zw.e[2], n_zw.e[3]), fade_xyzw.e[1]);
    let n_xyzw = lerp(n_yzw.e[0], n_yzw.e[1], fade_xyzw.e[0]);
    return T::from_f64(2.2) * n_xyzw;
}

fn simplex2<T: Float>(v: Vec<T, 2>) T {
    let c = Vec::<T, 4>::new(
        T::from_f64(0.211324865405187),
        T::from_f64(0.366025403784439),
        T::from_f64(-0.577350269189626),
        T::from_f64(0.024390243902439),
    );

    let mut i = floor(v + dot(v, Vec::<T, 2>::splat(c.e[1])));
    let x0 = v - i + dot(i, Vec::<T, 2>::splat(c.e[0]));

    let i1 = if x0.e[0].greater(x0.e[1]) {
        Vec::<T, 2>::new(T::one(), T::zero());
    } else {
        Vec::<T, 2>::new(T::zero(), T::one());
    };
    let mut x12 = Vec::<T, 4>::new(x0.e[0], x0.e[1], x0.e[0], x0.e[1]) + Vec::<T, 4>::new(
        c.e[0],
        c.e[0],
        c.e[2],
        c.e[2],
    );
    x12 = (Vec::<T, 2>::new(x12.e[0], x12.e[1]) - i1).concat(Vec::<T, 2>::new(x12.e[2], x12.e[3]));

    i = mod(i, Vec::<T, 2>::splat(T::from_i64(289)));
    let p = permute(
        permute(i.e[1] + Vec::<T, 3>::new(T::zero(), i1.e[1], T::one())) + i.e[0] + Vec::<T, 3>::new(
            T::zero(),
            i1.e[0],
            T::one(),
        ),
    );

    let x12a = Vec::<T, 2>::new(x12.e[0], x12.e[1]);
    let x12b = Vec::<T, 2>::new(x12.e[2], x12.e[3]);
    let mut m = max(
        Vec::<T, 3>::splat(T::from_f64(0.5)) - Vec::<T, 3>::new(dot(x0, x0), dot(x12a, x12a), dot(x12b, x12b)),
        Vec::<T, 3>::zero(),
    );
    m = m * m;
    m = m * m;

    let x = T::from_i64(2) * fract(p * c.e[3]) - T::one();
    let h = abs(x) - T::from_f64(0.5);
    let ox = floor(x + T::from_f64(0.5));
    let a0 = x - ox;

    m = m * (T::from_f64(1.79284291400159) - T::from_f64(0.85373472095314) * (a0 * a0 + h * h));

    let g = Vec::<T, 3>::new(
        a0.e[0] * x0.e[0] + h.e[0] * x0.e[1],
        a0.e[1] * x12.e[0] + h.e[1] * x12.e[1],
        a0.e[2] * x12.e[2] + h.e[2] * x12.e[3],
    );
    return T::from_i64(130) * dot(m, g);
}

fn simplex3<T: Float>(v: Vec<T, 3>) T {
    let c = Vec::<T, 2>::new(T::from_f64(1.0 / 6.0), T::from_f64(1.0 / 3.0));
    let d = Vec::<T, 4>::new(T::from_f64(0.0), T::from_f64(0.5), T::from_f64(1.0), T::from_f64(2.0));

    let mut i = floor(v + dot(v, Vec::<T, 3>::splat(c.e[1])));
    let x0 = v - i + dot(i, Vec::<T, 3>::splat(c.e[0]));

    let g = step(x0.swizzle3::<1, 2, 0>(), x0);
    let l = T::one() - g;
    let i1 = min(g, l.swizzle3::<2, 0, 1>());
    let i2 = max(g, l.swizzle3::<2, 0, 1>());

    let x1 = x0 - i1 + c.e[0];
    let x2 = x0 - i2 + c.e[1];
    let x3 = x0 - d.e[1];

    i = mod289(i);
    let p = permute(
        permute(
            permute(i.e[2] + Vec::<T, 4>::new(T::zero(), i1.e[2], i2.e[2], T::one())) + i.e[1] + Vec::<T, 4>::new(
                T::zero(),
                i1.e[1],
                i2.e[1],
                T::one(),
            ),
        ) + i.e[0] + Vec::<T, 4>::new(T::zero(), i1.e[0], i2.e[0], T::one()),
    );

    let n_ = T::from_f64(0.142857142857);
    let ns = n_ * Vec::<T, 3>::new(d.e[3], d.e[1], d.e[2]) - Vec::<T, 3>::new(d.e[0], d.e[2], d.e[0]);

    let j = p - T::from_i64(49) * floor(p * ns.e[2] * ns.e[2]);

    let x_ = floor(j * ns.e[2]);
    let y_ = floor(j - T::from_i64(7) * x_);

    let x = x_ * ns.e[0] + ns.e[1];
    let y = y_ * ns.e[0] + ns.e[1];
    let h = T::one() - abs(x) - abs(y);

    let b0 = Vec::<T, 4>::new(x.e[0], x.e[1], y.e[0], y.e[1]);
    let b1 = Vec::<T, 4>::new(x.e[2], x.e[3], y.e[2], y.e[3]);

    let s0 = floor(b0) * T::from_i64(2) + T::one();
    let s1 = floor(b1) * T::from_i64(2) + T::one();
    let sh = -step(h, Vec::<T, 4>::zero());

    let a0 = b0.swizzle4::<0, 2, 1, 3>() + s0.swizzle4::<0, 2, 1, 3>() * sh.swizzle4::<0, 0, 1, 1>();
    let a1 = b1.swizzle4::<0, 2, 1, 3>() + s1.swizzle4::<0, 2, 1, 3>() * sh.swizzle4::<2, 2, 3, 3>();

    let mut p0 = Vec::<T, 3>::new(a0.e[0], a0.e[1], h.e[0]);
    let mut p1 = Vec::<T, 3>::new(a0.e[2], a0.e[3], h.e[1]);
    let mut p2 = Vec::<T, 3>::new(a1.e[0], a1.e[1], h.e[2]);
    let mut p3 = Vec::<T, 3>::new(a1.e[2], a1.e[3], h.e[3]);

    let norm = taylor_inv_sqrt(Vec::<T, 4>::new(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 = p0 * norm.e[0];
    p1 = p1 * norm.e[1];
    p2 = p2 * norm.e[2];
    p3 = p3 * norm.e[3];

    let mut m = max(
        T::from_f64(0.6) - Vec::<T, 4>::new(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)),
        Vec::<T, 4>::zero(),
    );
    m = m * m;
    return T::from_i64(42) * dot(m * m, Vec::<T, 4>::new(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

// The 4D simplex gradient for the permutation value `j` with the scales `ip`.
fn grad4<T: Float>(j: T, ip: Vec<T, 4>) Vec<T, 4> {
    let mut p_xyz = floor(fract(Vec::<T, 3>::splat(j) * ip.truncate::<3>()) * T::from_i64(7)) * ip.e[2] - T::one();
    let p_w = T::from_f64(1.5) - dot(abs(p_xyz), Vec::<T, 3>::splat(T::one()));
    let mut s = p_xyz.append(p_w);
    for k in 0..4 {
        unsafe {
            s.e[k] = if s.e[k].less(T::zero()) {
                T::one();
            } else {
                T::zero();
            };
        }
    }
    p_xyz = p_xyz + (s.truncate::<3>() * T::from_i64(2) - T::one()) * s.e[3];
    return p_xyz.append(p_w);
}

fn simplex4<T: Float>(v: Vec<T, 4>) T {
    let c = Vec::<T, 4>::new(
        T::from_f64(0.138196601125011),
        T::from_f64(0.276393202250021),
        T::from_f64(0.414589803375032),
        T::from_f64(-0.447213595499958),
    );
    let f4 = T::from_f64(0.309016994374947451);

    let mut i = floor(v + dot(v, Vec::<T, 4>::splat(f4)));
    let x0 = v - i + dot(i, Vec::<T, 4>::splat(c.e[0]));

    let is_x = step(x0.swizzle3::<1, 2, 3>(), Vec::<T, 3>::splat(x0.e[0]));
    let is_yz = step(x0.swizzle3::<2, 3, 3>(), x0.swizzle3::<1, 1, 2>());
    let mut i0 = Vec::<T, 4>::new(is_x.e[0] + is_x.e[1] + is_x.e[2], T::zero(), T::zero(), T::zero());
    let rest = T::one() - is_x;
    i0.e[1] = rest.e[0];
    i0.e[2] = rest.e[1];
    i0.e[3] = rest.e[2];
    i0.e[1] = i0.e[1] + (is_yz.e[0] + is_yz.e[1]);
    i0.e[2] = i0.e[2] + (T::one() - is_yz.e[0]);
    i0.e[3] = i0.e[3] + (T::one() - is_yz.e[1]);
    i0.e[2] = i0.e[2] + is_yz.e[2];
    i0.e[3] = i0.e[3] + (T::one() - is_yz.e[2]);

    let i3 = clamp(i0, T::zero(), T::one());
    let i2 = clamp(i0 - T::one(), T::zero(), T::one());
    let i1 = clamp(i0 - T::from_i64(2), T::zero(), T::one());

    let x1 = x0 - i1 + c.e[0];
    let x2 = x0 - i2 + c.e[1];
    let x3 = x0 - i3 + c.e[2];
    let x4 = x0 + c.e[3];

    i = mod(i, Vec::<T, 4>::splat(T::from_i64(289)));
    let j0 = permute_of(permute_of(permute_of(permute_of(i.e[3]) + i.e[2]) + i.e[1]) + i.e[0]);
    let j1 = permute(
        permute(
            permute(
                permute(i.e[3] + Vec::<T, 4>::new(i1.e[3], i2.e[3], i3.e[3], T::one())) + i.e[2] + Vec::<T, 4>::new(
                    i1.e[2],
                    i2.e[2],
                    i3.e[2],
                    T::one(),
                ),
            ) + i.e[1] + Vec::<T, 4>::new(i1.e[1], i2.e[1], i3.e[1], T::one()),
        ) + i.e[0] + Vec::<T, 4>::new(i1.e[0], i2.e[0], i3.e[0], T::one()),
    );

    let ip = Vec::<T, 4>::new(
        T::one() / T::from_i64(294),
        T::one() / T::from_i64(49),
        T::one() / T::from_i64(7),
        T::zero(),
    );

    let mut p0 = grad4(j0, ip);
    let mut p1 = grad4(j1.e[0], ip);
    let mut p2 = grad4(j1.e[1], ip);
    let mut p3 = grad4(j1.e[2], ip);
    let mut p4 = grad4(j1.e[3], ip);

    let norm = taylor_inv_sqrt(Vec::<T, 4>::new(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 = p0 * norm.e[0];
    p1 = p1 * norm.e[1];
    p2 = p2 * norm.e[2];
    p3 = p3 * norm.e[3];
    p4 = p4 * taylor_inv_sqrt_of(dot(p4, p4));

    let mut m0 = max(T::from_f64(0.6) - Vec::<T, 3>::new(dot(x0, x0), dot(x1, x1), dot(x2, x2)), Vec::<T, 3>::zero());
    let mut m1 = max(T::from_f64(0.6) - Vec::<T, 2>::new(dot(x3, x3), dot(x4, x4)), Vec::<T, 2>::zero());
    m0 = m0 * m0;
    m1 = m1 * m1;
    return T::from_i64(49) * (dot(m0 * m0, Vec::<T, 3>::new(dot(p0, x0), dot(p1, x1), dot(p2, x2))) + dot(
        m1 * m1,
        Vec::<T, 2>::new(dot(p3, x3), dot(p4, x4)),
    ));
}
