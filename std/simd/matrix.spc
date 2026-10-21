// Matrix products over row-major slices: on the SME tiles where the CPU has them (ffi/sc_sme.spc, one outer
// product per tile per step of the inner dimension), over `Simd` lanes elsewhere (on x86_64, the build's
// run-time copies of the lanes kernels: `--simd-dispatch`). Every kernel gives the
// same bits: element (i, j) is the fused multiply-add chain over p in order from +0.0, NaN payloads
// aside; `f16` and `bf16` inputs widen exactly to `f32` first.
import std::cpu;
import std::cpu::detect as detect;
import std::simd;
import sc_sme;

/// `c = a * b` for row-major `f32` matrices: `a` is `m x k`, `b` is `k x n` and `c` is `m x n`. Element
/// (i, j) of `c` is `fma(a[i][k-1], b[k-1][j], .. fma(a[i][0], b[0][j], +0.0))`, one rounding per step,
/// the same bits on every machine and kernel. Panics: a slice whose length is not its matrix's element
/// count.
pub fn mul_f32(c: []mut f32, a: []f32, b: []f32, m: usize, k: usize, n: usize) {
    if !fits(c.len(), m, n) || !fits(a.len(), m, k) || !fits(b.len(), k, n) {
        panic("matrix::mul_f32: a slice's length is not its matrix's element count");
    }
    mul_f32_on(c, a, b, m, k, n);
}

/// `c = a * b` for row-major `i8` matrices into `i32`: element (i, j) of `c` is the sum over p of
/// `(a[i][p] as i32) * (b[p][j] as i32)` modulo 2^32, the same on every machine and kernel (SME outer
/// products where the CPU has them). Panics as `mul_f32`.
pub fn mul_i8(c: []mut i32, a: []i8, b: []i8, m: usize, k: usize, n: usize) {
    if !fits(c.len(), m, n) || !fits(a.len(), m, k) || !fits(b.len(), k, n) {
        panic("matrix::mul_i8: a slice's length is not its matrix's element count");
    }
    mul_i8_on(c, a, b, m, k, n);
}

/// `c = a * b` for row-major `f16` matrices into `f32`: each element of `a` and `b` widened to `f32`
/// (exact), then `mul_f32`: the same bits on every machine and kernel. Panics as `mul_f32`.
pub fn mul_f16(c: []mut f32, a: []f16, b: []f16, m: usize, k: usize, n: usize) {
    if !fits(c.len(), m, n) || !fits(a.len(), m, k) || !fits(b.len(), k, n) {
        panic("matrix::mul_f16: a slice's length is not its matrix's element count");
    }
    mul_f16_on(c, a, b, m, k, n);
}

/// `mul_f16` for `bf16` matrices.
pub fn mul_bf16(c: []mut f32, a: []bf16, b: []bf16, m: usize, k: usize, n: usize) {
    if !fits(c.len(), m, n) || !fits(a.len(), m, k) || !fits(b.len(), k, n) {
        panic("matrix::mul_bf16: a slice's length is not its matrix's element count");
    }
    mul_bf16_on(c, a, b, m, k, n);
}

/// `mul_f32` for `f64` matrices.
pub fn mul_f64(c: []mut f64, a: []f64, b: []f64, m: usize, k: usize, n: usize) {
    if !fits(c.len(), m, n) || !fits(a.len(), m, k) || !fits(b.len(), k, n) {
        panic("matrix::mul_f64: a slice's length is not its matrix's element count");
    }
    mul_f64_on(c, a, b, m, k, n);
}

// Whether `len` is the element count of an `r x s` matrix (no overflow).
fn fits(len: usize, r: usize, s: usize) bool {
    return switch r.checked_mul(s) {
        Some(e) => e == len,
        None => false,
    };
}

static mut MUL_F32: detect::Dispatch = detect::Dispatch::new();
static mut MUL_F64: detect::Dispatch = detect::Dispatch::new();
static mut MUL_I8: detect::Dispatch = detect::Dispatch::new();
static mut MUL_F16: detect::Dispatch = detect::Dispatch::new();
static mut MUL_BF16: detect::Dispatch = detect::Dispatch::new();

@arch(aarch64)
fn mul_f32_on(c: []mut f32, a: []f32, b: []f32, m: usize, k: usize, n: usize) {
    let f = unsafe detect::dispatch::<fn([]mut f32, []f32, []f32, usize, usize, usize), 1>(
        &mut unsafe MUL_F32,
        [(cpu::Feature::Sme2, mul_f32_sme)],
        mul_f32_lanes,
    );
    f(c, a, b, m, k, n);
}

@arch(!aarch64)
fn mul_f32_on(c: []mut f32, a: []f32, b: []f32, m: usize, k: usize, n: usize) {
    mul_f32_lanes(c, a, b, m, k, n);
}

@arch(aarch64)
fn mul_f64_on(c: []mut f64, a: []f64, b: []f64, m: usize, k: usize, n: usize) {
    let f = unsafe detect::dispatch::<fn([]mut f64, []f64, []f64, usize, usize, usize), 1>(
        &mut unsafe MUL_F64,
        [(cpu::Feature::SmeF64f64, mul_f64_sme)],
        mul_f64_lanes,
    );
    f(c, a, b, m, k, n);
}

@arch(!aarch64)
fn mul_f64_on(c: []mut f64, a: []f64, b: []f64, m: usize, k: usize, n: usize) {
    mul_f64_lanes(c, a, b, m, k, n);
}

@arch(aarch64)
fn mul_i8_on(c: []mut i32, a: []i8, b: []i8, m: usize, k: usize, n: usize) {
    let f = unsafe detect::dispatch::<fn([]mut i32, []i8, []i8, usize, usize, usize), 1>(
        &mut unsafe MUL_I8,
        [(cpu::Feature::Sme2, mul_i8_sme)],
        mul_i8_lanes,
    );
    f(c, a, b, m, k, n);
}

@arch(!aarch64)
fn mul_i8_on(c: []mut i32, a: []i8, b: []i8, m: usize, k: usize, n: usize) {
    mul_i8_lanes(c, a, b, m, k, n);
}

@arch(aarch64)
fn mul_f16_on(c: []mut f32, a: []f16, b: []f16, m: usize, k: usize, n: usize) {
    let f = unsafe detect::dispatch::<fn([]mut f32, []f16, []f16, usize, usize, usize), 1>(
        &mut unsafe MUL_F16,
        [(cpu::Feature::Sme2, mul_f16_sme)],
        mul_widened::<5, 10>,
    );
    f(c, a, b, m, k, n);
}

@arch(!aarch64)
fn mul_f16_on(c: []mut f32, a: []f16, b: []f16, m: usize, k: usize, n: usize) {
    mul_widened::<5, 10>(c, a, b, m, k, n);
}

@arch(aarch64)
fn mul_bf16_on(c: []mut f32, a: []bf16, b: []bf16, m: usize, k: usize, n: usize) {
    let f = unsafe detect::dispatch::<fn([]mut f32, []bf16, []bf16, usize, usize, usize), 1>(
        &mut unsafe MUL_BF16,
        [(cpu::Feature::Sme2, mul_bf16_sme)],
        mul_widened::<8, 7>,
    );
    f(c, a, b, m, k, n);
}

@arch(!aarch64)
fn mul_bf16_on(c: []mut f32, a: []bf16, b: []bf16, m: usize, k: usize, n: usize) {
    mul_widened::<8, 7>(c, a, b, m, k, n);
}

// The SME kernel, or the lanes when the target has no kernels or their scratch cannot be allocated.
@arch(aarch64)
@target_feature([cpu::Feature::Sme2])
fn mul_f32_sme(c: []mut f32, a: []f32, b: []f32, m: usize, k: usize, n: usize) {
    if sc_sme::sc_sme_built() == 0 || unsafe sc_sme::sc_sme_mul_f32(c.as_mut_ptr(), a.as_ptr(), b.as_ptr(), m, k, n) != 0 {
        mul_f32_lanes(c, a, b, m, k, n);
    }
}

@arch(aarch64)
@target_feature([cpu::Feature::SmeF64f64])
fn mul_f64_sme(c: []mut f64, a: []f64, b: []f64, m: usize, k: usize, n: usize) {
    if sc_sme::sc_sme_built() == 0 || unsafe sc_sme::sc_sme_mul_f64(c.as_mut_ptr(), a.as_ptr(), b.as_ptr(), m, k, n) != 0 {
        mul_f64_lanes(c, a, b, m, k, n);
    }
}

@arch(aarch64)
@target_feature([cpu::Feature::Sme2])
fn mul_i8_sme(c: []mut i32, a: []i8, b: []i8, m: usize, k: usize, n: usize) {
    if sc_sme::sc_sme_built() == 0 || unsafe sc_sme::sc_sme_mul_i8(c.as_mut_ptr(), a.as_ptr(), b.as_ptr(), m, k, n) != 0 {
        mul_i8_lanes(c, a, b, m, k, n);
    }
}

// The kernel module widens the encodings itself: a 16-bit `Float` holds its encoding in the low 16 bits
// of one u64 (`IntBits`), which it reads.
@arch(aarch64)
@target_feature([cpu::Feature::Sme2])
fn mul_f16_sme(c: []mut f32, a: []f16, b: []f16, m: usize, k: usize, n: usize) {
    if sc_sme::sc_sme_built() == 0 || unsafe sc_sme::sc_sme_mul_f16(
        c.as_mut_ptr(),
        a.as_ptr() as *const u64,
        b.as_ptr() as *const u64,
        m,
        k,
        n,
    ) != 0 {
        mul_widened::<5, 10>(c, a, b, m, k, n);
    }
}

@arch(aarch64)
@target_feature([cpu::Feature::Sme2])
fn mul_bf16_sme(c: []mut f32, a: []bf16, b: []bf16, m: usize, k: usize, n: usize) {
    if sc_sme::sc_sme_built() == 0 || unsafe sc_sme::sc_sme_mul_bf16(
        c.as_mut_ptr(),
        a.as_ptr() as *const u64,
        b.as_ptr() as *const u64,
        m,
        k,
        n,
    ) != 0 {
        mul_widened::<8, 7>(c, a, b, m, k, n);
    }
}

// The portable 16-bit product: both matrices widened to f32 (exact), then the f32 product (its kernel
// by the machine).
fn mul_widened<const E: usize, const F: usize>(
    c: []mut f32,
    a: []Float<E, F>,
    b: []Float<E, F>,
    m: usize,
    k: usize,
    n: usize,
) {
    let mut w = Vector::<f32>::with_capacity(a.len() + b.len());
    for x in a {
        w.push(x.to_f32());
    }
    for x in b {
        w.push(x.to_f32());
    }
    mul_f32_on(c, w[0..m * k], w[m * k..m * k + k * n], m, k, n);
}

// The portable kernel: each row of `c` from +0.0, then for each p the row of `b` times `a[i][p]` added
// with one rounding, 16 lanes at a time, `mul_add` past them.
fn mul_f32_lanes(c: []mut f32, a: []f32, b: []f32, m: usize, k: usize, n: usize) {
    let nv = n - n % 16;
    for i in 0..m {
        let row = i * n;
        for j in 0..n {
            c[row + j] = 0.0;
        }
        for p in 0..k {
            let x = a[i * k + p];
            let xv = Simd::<f32, 16>::splat(x);
            let brow = p * n;
            let mut j: usize = 0;
            while j < nv {
                simd::store(c, row + j, xv.fma(simd::load::<f32, 16>(b, brow + j), simd::load::<f32, 16>(c, row + j)));
                j += 16;
            }
            while j < n {
                c[row + j] = x.mul_add(b[brow + j], c[row + j]);
                j += 1;
            }
        }
    }
}

fn mul_f64_lanes(c: []mut f64, a: []f64, b: []f64, m: usize, k: usize, n: usize) {
    let nv = n - n % 8;
    for i in 0..m {
        let row = i * n;
        for j in 0..n {
            c[row + j] = 0.0;
        }
        for p in 0..k {
            let x = a[i * k + p];
            let xv = Simd::<f64, 8>::splat(x);
            let brow = p * n;
            let mut j: usize = 0;
            while j < nv {
                simd::store(c, row + j, xv.fma(simd::load::<f64, 8>(b, brow + j), simd::load::<f64, 8>(c, row + j)));
                j += 8;
            }
            while j < n {
                c[row + j] = x.mul_add(b[brow + j], c[row + j]);
                j += 1;
            }
        }
    }
}

// Each row of `c` from 0, then for each p the row of `b` widened to i32 times `a[i][p]`, added modulo 2^32.
fn mul_i8_lanes(c: []mut i32, a: []i8, b: []i8, m: usize, k: usize, n: usize) {
    let nv = n - n % 16;
    for i in 0..m {
        let row = i * n;
        for j in 0..n {
            c[row + j] = 0;
        }
        for p in 0..k {
            let x = a[i * k + p] as i32;
            let xv = Simd::<i32, 16>::splat(x);
            let brow = p * n;
            let mut j: usize = 0;
            while j < nv {
                let bv = simd::load::<i8, 16>(b, brow + j).widen::<i32>();
                simd::store(c, row + j, xv.wrapping_mul(bv).wrapping_add(simd::load::<i32, 16>(c, row + j)));
                j += 16;
            }
            while j < n {
                c[row + j] = c[row + j].wrapping_add(x.wrapping_mul(b[brow + j]));
                j += 1;
            }
        }
    }
}
