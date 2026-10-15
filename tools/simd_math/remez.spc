// Minimax polynomials by the Remez exchange algorithm in a `Real` format: p(z) = sum c_k z^(b + k),
// k < n, minimizing max |w(z) (p(z) - g(z))| over a grid of points in [lo, hi]. The grid points are
// f64 values, so a target may evaluate its reference at the exact abscissa; dense grids near both
// ends (Chebyshev-Lobatto) resolve the extrema there. Every step is deterministic.
import real as *;

/// Points of one fit: the abscissas `z`, the target values `g` and the weights `w`.
pub struct Grid<R> {
    pub z: Vector<R>,
    pub g: Vector<R>,
    pub w: Vector<R>,
}

/// A fit's result: the coefficients (lowest power first), the largest weighted error on the grid, and
/// whether the exchange converged (the reference levels agree), else the last iteration's.
pub struct Fit<R> {
    pub c: Vector<R>,
    pub err: R,
    pub converged: bool,
}

const ITERATIONS_MAX: usize = 40;

extend<R: Real + Add<Output = R> + Sub<Output = R> + Mul<Output = R> + Div<Output = R>> Grid<R> {
    /// `m` Chebyshev-Lobatto abscissas of [lo, hi], each rounded to f64 (`cosv(i)` gives cos(i pi /
    /// (m - 1)) rounded to f64, from the reference library, so the grid is the same on every host).
    pub fn lobatto(lo: f64, hi: f64, m: usize, cosv: fn(usize, usize) f64) Vector<f64> {
        let mut v = Vector::<f64>::with_capacity(m);
        for i in 0..m {
            let t = cosv(m - 1 - i, m); // ascending
            v.push(lo + (hi - lo) * (t + 1.0) * 0.5);
        }
        return v;
    }

    /// Weighted error of `c` (powers from `b`) at grid point `i`.
    pub fn error_at(self: &Grid<R>, c: &Vector<R>, b: usize, i: usize) R {
        return self.w[i] * (eval(c, b, self.z[i]) - self.g[i]);
    }

    /// The minimax fit of `n` coefficients over powers b .. b + n - 1, from the grid.
    pub fn remez(self: &Grid<R>, n: usize, b: usize) Fit<R> {
        let m = self.z.len();
        assert(m > 4 * (n + 2));
        // Initial reference: n + 1 points spread evenly over the grid indices (Chebyshev-like, as the
        // grid itself is), avoiding points of weight 0.
        let mut refs = Vector::<usize>::new();
        for k in 0..n + 1 {
            refs.push(1 + k * (m - 3) / n);
        }
        let mut best = Fit::<R> { c: Vector::<R>::new(), err: R::of(0.0), converged: false };
        for _ in 0..ITERATIONS_MAX {
            let c = self.solve(&refs, n, b);
            // Extrema of the error, one per run of equal sign, the largest |e| of each run.
            let mut ext = Vector::<usize>::new();
            let mut i: usize = 0;
            while i < m && !R::of(0.0).lt(abs(self.w[i])) {
                i += 1; // a point of weight 0 has no error to level
            }
            while i < m {
                let e0 = self.error_at(&c, b, i);
                let pos = !e0.lt(R::of(0.0));
                let mut bi = i;
                let mut be = abs(e0);
                let mut j = i + 1;
                while j < m {
                    let e = self.error_at(&c, b, j);
                    if !e.lt(R::of(0.0)) != pos {
                        break;
                    }
                    if be.lt(abs(e)) {
                        be = abs(e);
                        bi = j;
                    }
                    j += 1;
                }
                ext.push(bi);
                i = j;
            }
            // Keep n + 1 consecutive alternating extrema containing the largest.
            let mut gmax: usize = 0;
            for k in 0..ext.len() {
                if abs(self.error_at(&c, b, ext[gmax])).lt(abs(self.error_at(&c, b, ext[k]))) {
                    gmax = k;
                }
            }
            let emax = abs(self.error_at(&c, b, ext[gmax]));
            if ext.len() < n + 1 {
                // Fewer alternations than coefficients: the error is level below the grid's resolution.
                return Fit::<R> { c: c, err: emax, converged: true };
            }
            // Drop the smaller end until n + 1 remain, never the largest.
            let mut lo_k: usize = 0;
            let mut hi_k = ext.len() - 1;
            while hi_k - lo_k > n {
                if hi_k == gmax || lo_k != gmax && abs(self.error_at(&c, b, ext[lo_k])).lt(
                    abs(self.error_at(&c, b, ext[hi_k])),
                ) {
                    lo_k += 1;
                } else {
                    hi_k -= 1;
                }
            }
            let mut emin = emax;
            let mut nrefs = Vector::<usize>::new();
            for k in lo_k..hi_k + 1 {
                nrefs.push(ext[k]);
                let e = abs(self.error_at(&c, b, ext[k]));
                if e.lt(emin) {
                    emin = e;
                }
            }
            // Converged when the reference levels agree to 1e-5.
            best = Fit::<R> { c: c, err: emax, converged: (emax - emin).lt(emax * R::of(1e-5)) };
            if best.converged {
                return best;
            }
            refs = nrefs;
        }
        return best;
    }

    // Solve sum_k c_k z_i^(b + k) + (-1)^i E / w_i = g_i at the n + 1 reference points.
    fn solve(self: &Grid<R>, refs: &Vector<usize>, n: usize, b: usize) Vector<R> {
        let d = n + 1;
        let mut a = Vector::<R>::with_capacity(d * (d + 1));
        for i in 0..d {
            let z = self.z[refs[i]];
            let mut p = R::of(1.0);
            for _ in 0..b {
                p = p * z;
            }
            for _ in 0..n {
                a.push(p);
                p = p * z;
            }
            let s = if i % 2 == 0 {
                R::of(1.0);
            } else {
                R::of(-1.0);
            };
            a.push(s / self.w[refs[i]]);
            a.push(self.g[refs[i]]);
        }
        let x = gauss(&mut a, d);
        let mut c = Vector::<R>::with_capacity(n);
        for k in 0..n {
            c.push(x[k]);
        }
        return c;
    }
}

/// p(z) = sum c_k z^(b + k), Horner from the highest power.
pub fn eval<R: Real + Add<Output = R> + Sub<Output = R> + Mul<Output = R> + Div<Output = R>>(
    c: &Vector<R>,
    b: usize,
    z: R,
) R {
    let mut p = R::of(0.0);
    let mut k = c.len();
    while k > 0 {
        k -= 1;
        p = p * z + c[k];
    }
    for _ in 0..b {
        p = p * z;
    }
    return p;
}

pub fn abs<R: Real + Sub<Output = R>>(x: R) R {
    if x.lt(R::of(0.0)) {
        return R::of(0.0) - x;
    }
    return x;
}

// Gaussian elimination with partial pivoting on the d x (d + 1) augmented matrix `a` (row major).
fn gauss<R: Real + Add<Output = R> + Sub<Output = R> + Mul<Output = R> + Div<Output = R>>(a: &mut Vector<R>, d: usize) Vector<
    R
> {
    let w = d + 1;
    for col in 0..d {
        let mut piv = col;
        for r in col + 1..d {
            if abs(a[piv * w + col]).lt(abs(a[r * w + col])) {
                piv = r;
            }
        }
        if piv != col {
            for k in 0..w {
                a.swap(piv * w + k, col * w + k);
            }
        }
        let pv = a[col * w + col];
        for r in col + 1..d {
            let f = a[r * w + col] / pv;
            for k in col..w {
                a[r * w + k] = a[r * w + k] - f * a[col * w + k];
            }
        }
    }
    let mut x = Vector::<R>::with_capacity(d);
    for _ in 0..d {
        x.push(R::of(0.0));
    }
    let mut r = d;
    while r > 0 {
        r -= 1;
        let mut s = a[r * w + d];
        for k in r + 1..d {
            s = s - a[r * w + k] * x[k];
        }
        x[r] = s / a[r * w + r];
    }
    return x;
}
