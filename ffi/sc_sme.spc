// SME matrix kernels for std::simd::matrix: row-major products on the ZA tiles, one outer product per
// tile per step of the inner dimension. Each kernel is module-level SME assembly that enters and
// leaves streaming mode itself; the Super-C entry points allocate the scratch and pack what needs no
// streaming mode. A kernel runs only where the CPU has its features (`cpu::Feature::Sme2`,
// `SmeF64f64`). Every result equals the portable kernel's bit for bit (NaN payloads aside): element
// (i, j) is the fused multiply-add chain over p in order, from +0.0. Prefer `std::simd::matrix`, which
// checks the shapes and chooses a kernel by the CPU.
import std::cpu;
import stdlib;
import string as cstring;

/// 1 where this module has the kernels (macOS, iOS, Linux and Android on aarch64), else 0.
pub const fn sc_sme_built() i32 {
    if PLATFORM != Platform::Windows && PLATFORM != Platform::Wasm && ARCH == Arch::AArch64 {
        return 1;
    }
    return 0;
}

/// `c` (m x n) = `a` (m x k) * `b` (k x n), row-major `f32`: 0, or -1 (`c` untouched) when the kernels
/// are not built or their scratch cannot be allocated. The caller guarantees the three extents.
@platform(macos | ios | linux | android)
@arch(aarch64)
@target_feature([cpu::Feature::Sme2])
pub unsafe fn sc_sme_mul_f32(c: *mut f32, a: *const f32, b: *const f32, m: usize, k: usize, n: usize) i32 {
    let l = (sc_sme_svl() / 4) as usize;
    let panels = m / l + (m % l != 0) as usize;
    // One allocation: the panels of `a` (panels * L * k floats), then the panel of `b` (4L * k floats).
    let pa = panel(k, panels * l + 4 * l, 4) as *mut f32;
    if pa == null {
        return -1;
    }
    sc_sme_f32_za(c, a, b, m, k, n, pa, pa + panels * l * k);
    stdlib::free(pa);
    return 0;
}

/// The same for `f64`.
@platform(macos | ios | linux | android)
@arch(aarch64)
@target_feature([cpu::Feature::SmeF64f64])
pub unsafe fn sc_sme_mul_f64(c: *mut f64, a: *const f64, b: *const f64, m: usize, k: usize, n: usize) i32 {
    let l = (sc_sme_svl() / 8) as usize;
    let panels = m / (2 * l) + (m % (2 * l) != 0) as usize;
    let pa = panel(k, panels * 2 * l + 4 * l, 8) as *mut f64;
    if pa == null {
        return -1;
    }
    sc_sme_f64_za(c, a, b, m, k, n, pa, pa + panels * 2 * l * k);
    stdlib::free(pa);
    return 0;
}

/// `c` (m x n, i32) = `a` (m x k) * `b` (k x n), i8: each element the sum of the products modulo 2^32.
@platform(macos | ios | linux | android)
@arch(aarch64)
@target_feature([cpu::Feature::Sme2])
pub unsafe fn sc_sme_mul_i8(c: *mut i32, a: *const i8, b: *const i8, m: usize, k: usize, n: usize) i32 {
    let l = (sc_sme_svl() / 4) as usize;
    let g = k / 4 + (k % 4 != 0) as usize;
    let pm = (m / l + (m % l != 0) as usize) * l;
    let pn = (n / (4 * l) + (n % (4 * l) != 0) as usize) * 4 * l;
    // pa: pm rows of 4g bytes; pb: pn columns of 4g bytes.
    let pa = panel(g, 4 * (pm + pn), 1) as *mut i8;
    if pa == null {
        return -1;
    }
    let pb = pa + pm * 4 * g;
    // pa: each row's groups of four bytes, one word per group (zeros past m and k).
    cstring::memset(pa, 0, pm * 4 * g);
    let whole = k / 4;
    for i in 0..m {
        let dst = pa + i / l * 4 * l * g + i % l * 4;
        let src = a + i * k;
        for q in 0..whole {
            cstring::memcpy(dst + q * 4 * l, src + 4 * q, 4);
        }
        for p in 4 * whole..k {
            dst[whole * 4 * l + p - 4 * whole] = src[p];
        }
    }
    // pb: per group, the four rows interleaved byte by byte over each panel's 4L columns (zeros past n
    // and k); a whole group of a whole panel has no condition, which the C compiler vectorizes.
    cstring::memset(pb, 0, pn * 4 * g);
    let mut j: usize = 0;
    while j < pn {
        for q in 0..g {
            let dst = pb + j * 4 * g + q * 16 * l;
            if j + 4 * l <= n && 4 * q + 4 <= k {
                let r0 = b + 4 * q * n + j;
                let r1 = r0 + n;
                let r2 = r1 + n;
                let r3 = r2 + n;
                for col in 0..4 * l {
                    dst[col * 4] = r0[col];
                    dst[col * 4 + 1] = r1[col];
                    dst[col * 4 + 2] = r2[col];
                    dst[col * 4 + 3] = r3[col];
                }
            } else {
                let mut col: usize = 0;
                while col < 4 * l && j + col < n {
                    let mut t: usize = 0;
                    while t < 4 && 4 * q + t < k {
                        dst[col * 4 + t] = b[(4 * q + t) * n + j + col];
                        t += 1;
                    }
                    col += 1;
                }
            }
        }
        j += 4 * l;
    }
    sc_sme_i8_za(c, pa, pb, m, g, n);
    stdlib::free(pa);
    return 0;
}

/// `c` (m x n, f32) = `a` (m x k) * `b` (k x n), `f16` encodings (`a.as_ptr() as *const u64`: a
/// `Float<5, 10>` holds its encoding in the low 16 bits of one u64), widened exactly: as `sc_sme_mul_f32`.
@platform(macos | ios | linux | android)
@arch(aarch64)
@target_feature([cpu::Feature::Sme2])
pub unsafe fn sc_sme_mul_f16(c: *mut f32, a: *const u64, b: *const u64, m: usize, k: usize, n: usize) i32 {
    return mul_wide(c, a, b, m, k, n, false);
}

/// The same for `bf16` (`Float<8, 7>`).
@platform(macos | ios | linux | android)
@arch(aarch64)
@target_feature([cpu::Feature::Sme2])
pub unsafe fn sc_sme_mul_bf16(c: *mut f32, a: *const u64, b: *const u64, m: usize, k: usize, n: usize) i32 {
    return mul_wide(c, a, b, m, k, n, true);
}

// The aarch64 targets without the kernels: every product reports -1.
@platform(windows)
@arch(aarch64)
@target_feature([cpu::Feature::Sme2])
pub unsafe fn sc_sme_mul_f32(_c: *mut f32, _a: *const f32, _b: *const f32, _m: usize, _k: usize, _n: usize) i32 {
    return -1;
}

@platform(windows)
@arch(aarch64)
@target_feature([cpu::Feature::SmeF64f64])
pub unsafe fn sc_sme_mul_f64(_c: *mut f64, _a: *const f64, _b: *const f64, _m: usize, _k: usize, _n: usize) i32 {
    return -1;
}

@platform(windows)
@arch(aarch64)
@target_feature([cpu::Feature::Sme2])
pub unsafe fn sc_sme_mul_i8(_c: *mut i32, _a: *const i8, _b: *const i8, _m: usize, _k: usize, _n: usize) i32 {
    return -1;
}

@platform(windows)
@arch(aarch64)
@target_feature([cpu::Feature::Sme2])
pub unsafe fn sc_sme_mul_f16(_c: *mut f32, _a: *const u64, _b: *const u64, _m: usize, _k: usize, _n: usize) i32 {
    return -1;
}

@platform(windows)
@arch(aarch64)
@target_feature([cpu::Feature::Sme2])
pub unsafe fn sc_sme_mul_bf16(_c: *mut f32, _a: *const u64, _b: *const u64, _m: usize, _k: usize, _n: usize) i32 {
    return -1;
}

// `k` rows of `lanes` elements of `esz` bytes from `malloc`: null when the size overflows or cannot be
// allocated.
@platform(macos | ios | linux | android)
@arch(aarch64)
const fn panel(k: usize, lanes: usize, esz: usize) *mut void {
    let (row, o1) = lanes.overflowing_mul(esz);
    let (size, o2) = k.overflowing_mul(row);
    if o1 || o2 {
        return null;
    }
    if size == 0 {
        return unsafe stdlib::malloc(1);
    }
    return unsafe stdlib::malloc(size);
}

// The f32 product of the widened matrices. The words of `a` and `b` exist in memory, so m*k + k*n floats
// do not overflow a size.
@platform(macos | ios | linux | android)
@arch(aarch64)
@target_feature([cpu::Feature::Sme2])
unsafe fn mul_wide(c: *mut f32, a: *const u64, b: *const u64, m: usize, k: usize, n: usize, bf: bool) i32 {
    let w = panel(m * k + k * n, 1, 4) as *mut f32;
    if w == null {
        return -1;
    }
    widen(w, a, m * k, bf);
    widen(w + m * k, b, k * n, bf);
    let r = sc_sme_mul_f32(c, w, w + m * k, m, k, n);
    stdlib::free(w);
    return r;
}

// `len` f16 (`bf` false) or bf16 encodings, each in the low 16 bits of a u64, widened exactly to f32.
@platform(macos | ios | linux | android)
@arch(aarch64)
unsafe const fn widen(d: *mut f32, s: *const u64, len: usize, bf: bool) {
    if bf {
        for i in 0..len {
            d[i] = (*((s + i) as *const bf16)).to_f32();
        }
    } else {
        for i in 0..len {
            d[i] = (*((s + i) as *const f16)).to_f32();
        }
    }
}

// RDSVL (`lir::ir::SYS_SVL`).
@platform(macos | ios | linux | android)
@arch(aarch64)
extern "C" {
    fn sc_sys_svl() u64;
}

// The streaming vector length in bytes (RDSVL), which the kernels' panels are sized by.
@platform(macos | ios | linux | android)
@arch(aarch64)
fn sc_sme_svl() u64 {
    return unsafe sc_sys_svl();
}

// The kernels below share one entry and one exit. Entry: save x19 to x28 and d8 to d15 (SMSTART and
// SMSTOP zero the vector registers); commit a caller's dormant ZA state, as a function with a new ZA
// state must (the lazy-save scheme of the SME ABI, `__arm_tpidr2_save`: TPIDR2_EL0 addresses a block of
// the save buffer's address and reserved bytes 10 to 15, which must be zero; every ZA row goes to the
// buffer, then TPIDR2_EL0 is cleared); then enter streaming mode with ZA on. Exit: leave streaming mode
// with ZA off, restore, return. The slice index of a ZA access is w12.

// c = a * b (f32), arguments in x0 to x7: c, a, b, m, k, n, pa, pb. L = SVL / 32. The whole of `a` is
// packed first into panels of L rows, column-major (`pa`, ceil(m / L) * L * k floats, zero rows past m),
// through tile 0 (rows in horizontally, columns out vertically). Then each block of 4L columns of `b`
// is read in place when whole and a row is at most 1 KiB (the copy costs more than the strided reads
// save: 10 to 20% at n = 64 to 128 on an M5 Pro), else copied into `pb` (k * 4L floats, zeros past n)
// with four-vector loads; each L x 4L block of `c` takes one A vector and one four-vector load of B per
// p, one FMOPA per tile. The outer products run on whole tiles over the zero padding; the stores cover
// the rows and columns of `c` only (p4 to p7 hold the block's columns below n). This is the 1 VL x 4 VL
// shape of MpGEMM (arXiv 2512.21473): about 1.8 to 2.0 TFLOP/s on one Apple M5 Pro core from n = 512 to
// 1024, the unit's peak; a 2 VL x 2 VL block without the B panel reached 0.7 TFLOP/s at n = 2048 (B rows
// a page apart).
@platform(macos | ios | linux | android)
@arch(aarch64)
asm(M"(.text
.arch_extension sme2
.arch_extension sme-f64f64
.p2align 4
_sc_sme_f32_za:
sc_sme_f32_za:
stp d8, d9, [sp, #-144]!
stp d10, d11, [sp, #16]
stp d12, d13, [sp, #32]
stp d14, d15, [sp, #48]
stp x19, x20, [sp, #64]
stp x21, x22, [sp, #80]
stp x23, x24, [sp, #96]
stp x25, x26, [sp, #112]
stp x27, x28, [sp, #128]
mrs x8, TPIDR2_EL0
cbz x8, 23f
ldrh w9, [x8, #10]
ldr w10, [x8, #12]
orr w9, w9, w10
cbz w9, 20f
udf #0
20:
ldr x9, [x8]
cbz x9, 22f
rdsvl x10, #1
mov w12, #0
21:
str za[w12, 0], [x9]
addsvl x9, x9, #1
add w12, w12, #1
cmp x12, x10
b.lo 21b
22:
msr TPIDR2_EL0, xzr
23:
smstart
cntw x8
cntb x9
ptrue p0.s
ptrue pn8.s
lsl x17, x4, #2
mul x22, x8, x9
mul x23, x4, x9
lsl x24, x5, #2
lsl x25, x9, #2
cbz x3, 9f
cbz x5, 9f
cbz x4, 7f
mov x10, #0
mov x11, x6
1:
sub x13, x3, x10
cmp x13, x8
csel x13, x13, x8, lo
mov x14, #0
mov x19, x1
mov x20, x11
2:
whilelo p1.s, x14, x4
zero {za0.s}
mov w12, #0
mov x15, x19
3:
ld1w {za0h.s[w12, 0]}, p1/z, [x15]
add x15, x15, x17
add w12, w12, #1
cmp x12, x13
b.lo 3b
sub x21, x4, x14
cmp x21, x8
csel x21, x21, x8, lo
mov w12, #0
mov x16, x20
4:
st1w {za0v.s[w12, 0]}, p0, [x16]
add x16, x16, x9
add w12, w12, #1
cmp x12, x21
b.lo 4b
add x14, x14, x8
add x19, x19, x9
add x20, x20, x22
cmp x14, x4
b.lo 2b
add x1, x1, x23
add x11, x11, x23
add x10, x10, x8
cmp x10, x3
b.lo 1b
7:
mov x10, #0
lsl x26, x8, #2
lsl x27, x8, #1
add x28, x8, x27
mul x17, x9, x5
8:
whilelo p4.s, x10, x5
add x13, x10, x8
whilelo p5.s, x13, x5
add x13, x10, x27
whilelo p6.s, x13, x5
add x13, x10, x28
whilelo p7.s, x13, x5
add x19, x2, x10, lsl #2
mov x20, x19
mov x21, x24
sub x13, x5, x10
cmp x13, x26
b.lo 10f
cmp x24, #1024
b.ls 12f
10:
whilelo pn9.s, x10, x5, vlx4
mov x20, x7
mov x21, x25
cbz x4, 12f
mov x14, x4
mov x15, x19
mov x16, x7
11:
ld1w {z0.s-z3.s}, pn9/z, [x15]
st1w {z0.s-z3.s}, pn8, [x16]
add x15, x15, x24
add x16, x16, x25
subs x14, x14, #1
b.ne 11b
12:
mov x11, #0
mov x22, x6
add x1, x0, x10, lsl #2
13:
sub x13, x3, x11
cmp x13, x8
csel x13, x13, x8, lo
zero {za}
cbz x4, 15f
mov x14, x4
mov x15, x22
mov x16, x20
14:
ld1w {z0.s}, p0/z, [x15]
ld1w {z4.s-z7.s}, pn8/z, [x16]
fmopa za0.s, p0/m, p0/m, z0.s, z4.s
fmopa za1.s, p0/m, p0/m, z0.s, z5.s
fmopa za2.s, p0/m, p0/m, z0.s, z6.s
fmopa za3.s, p0/m, p0/m, z0.s, z7.s
add x15, x15, x9
add x16, x16, x21
subs x14, x14, #1
b.ne 14b
15:
mov w12, #0
mov x15, x1
16:
st1w {za0h.s[w12, 0]}, p4, [x15]
st1w {za1h.s[w12, 0]}, p5, [x15, x8, lsl #2]
st1w {za2h.s[w12, 0]}, p6, [x15, x27, lsl #2]
st1w {za3h.s[w12, 0]}, p7, [x15, x28, lsl #2]
add x15, x15, x24
add w12, w12, #1
cmp x12, x13
b.lo 16b
add x22, x22, x23
add x1, x1, x17
add x11, x11, x8
cmp x11, x3
b.lo 13b
add x10, x10, x26
cmp x10, x5
b.lo 8b
9:
smstop
ldp x27, x28, [sp, #128]
ldp x25, x26, [sp, #112]
ldp x23, x24, [sp, #96]
ldp x21, x22, [sp, #80]
ldp x19, x20, [sp, #64]
ldp d14, d15, [sp, #48]
ldp d12, d13, [sp, #32]
ldp d10, d11, [sp, #16]
ldp d8, d9, [sp], #144
ret)");

// c = a * b (f64), arguments as the f32 kernel's. L = SVL / 64. As the f32 kernel, with blocks of
// 2L x 4L: `a` packed into panels of 2L rows (`pa`, ceil(m / 2L) * 2L * k doubles) through 64-bit tiles 0
// and 1, each block of 4L columns of `b` copied into `pb` (k * 4L doubles, zeros past n), and the eight
// 64-bit tiles: 0 to 3 the first L rows over the four column vectors, 4 to 7 the next L rows. SME and
// its f64 outer products only: no SME2 instruction. Without the B panel, the M5 Pro fell from 0.5 to
// 0.2 TFLOP/s at n = 2048.
@platform(macos | ios | linux | android)
@arch(aarch64)
asm(M"(.text
.arch_extension sme2
.arch_extension sme-f64f64
.p2align 4
_sc_sme_f64_za:
sc_sme_f64_za:
stp d8, d9, [sp, #-144]!
stp d10, d11, [sp, #16]
stp d12, d13, [sp, #32]
stp d14, d15, [sp, #48]
stp x19, x20, [sp, #64]
stp x21, x22, [sp, #80]
stp x23, x24, [sp, #96]
stp x25, x26, [sp, #112]
stp x27, x28, [sp, #128]
mrs x8, TPIDR2_EL0
cbz x8, 23f
ldrh w9, [x8, #10]
ldr w10, [x8, #12]
orr w9, w9, w10
cbz w9, 20f
udf #0
20:
ldr x9, [x8]
cbz x9, 22f
rdsvl x10, #1
mov w12, #0
21:
str za[w12, 0], [x9]
addsvl x9, x9, #1
add w12, w12, #1
cmp x12, x10
b.lo 21b
22:
msr TPIDR2_EL0, xzr
23:
smstart
cntd x8
cntb x9
ptrue p0.d
lsl x17, x4, #3
mul x22, x8, x9
lsl x22, x22, #1
mul x23, x4, x9
lsl x23, x23, #1
lsl x24, x5, #3
lsl x25, x9, #2
lsl x26, x8, #1
cbz x3, 9f
cbz x5, 9f
cbz x4, 7f
mov x10, #0
mov x11, x6
1:
sub x13, x3, x10
cmp x13, x26
csel x13, x13, x26, lo
cmp x13, x8
csel x27, x13, x8, lo
sub x28, x13, x27
mov x14, #0
mov x19, x1
mov x20, x11
2:
whilelo p1.d, x14, x4
zero {za0.d, za1.d}
mov w12, #0
mov x15, x19
3:
ld1d {za0h.d[w12, 0]}, p1/z, [x15]
add x15, x15, x17
add w12, w12, #1
cmp x12, x27
b.lo 3b
cbz x28, 5f
mov w12, #0
4:
ld1d {za1h.d[w12, 0]}, p1/z, [x15]
add x15, x15, x17
add w12, w12, #1
cmp x12, x28
b.lo 4b
5:
sub x21, x4, x14
cmp x21, x8
csel x21, x21, x8, lo
mov w12, #0
mov x16, x20
6:
st1d {za0v.d[w12, 0]}, p0, [x16]
st1d {za1v.d[w12, 0]}, p0, [x16, x8, lsl #3]
add x16, x16, x9, lsl #1
add w12, w12, #1
cmp x12, x21
b.lo 6b
add x14, x14, x8
add x19, x19, x9
add x20, x20, x22
cmp x14, x4
b.lo 2b
add x1, x1, x23
add x11, x11, x23
add x10, x10, x26
cmp x10, x3
b.lo 1b
7:
mov x10, #0
lsl x26, x8, #2
lsl x27, x8, #1
add x28, x8, x27
mul x17, x9, x5
lsl x17, x17, #1
mul x21, x9, x5
8:
whilelo p4.d, x10, x5
add x13, x10, x8
whilelo p5.d, x13, x5
add x13, x10, x27
whilelo p6.d, x13, x5
add x13, x10, x28
whilelo p7.d, x13, x5
cbz x4, 12f
add x15, x2, x10, lsl #3
mov x14, x4
mov x16, x7
11:
ld1d {z0.d}, p4/z, [x15]
ld1d {z1.d}, p5/z, [x15, x8, lsl #3]
ld1d {z2.d}, p6/z, [x15, x27, lsl #3]
ld1d {z3.d}, p7/z, [x15, x28, lsl #3]
st1d {z0.d}, p0, [x16]
st1d {z1.d}, p0, [x16, #1, mul vl]
st1d {z2.d}, p0, [x16, #2, mul vl]
st1d {z3.d}, p0, [x16, #3, mul vl]
add x15, x15, x24
add x16, x16, x25
subs x14, x14, #1
b.ne 11b
12:
mov x11, #0
mov x22, x6
add x1, x0, x10, lsl #3
13:
sub x13, x3, x11
cmp x13, x27
csel x13, x13, x27, lo
zero {za}
cbz x4, 15f
mov x14, x4
mov x15, x22
mov x16, x7
14:
ld1d {z0.d}, p0/z, [x15]
ld1d {z1.d}, p0/z, [x15, #1, mul vl]
ld1d {z4.d}, p0/z, [x16]
ld1d {z5.d}, p0/z, [x16, #1, mul vl]
ld1d {z6.d}, p0/z, [x16, #2, mul vl]
ld1d {z7.d}, p0/z, [x16, #3, mul vl]
fmopa za0.d, p0/m, p0/m, z0.d, z4.d
fmopa za1.d, p0/m, p0/m, z0.d, z5.d
fmopa za2.d, p0/m, p0/m, z0.d, z6.d
fmopa za3.d, p0/m, p0/m, z0.d, z7.d
fmopa za4.d, p0/m, p0/m, z1.d, z4.d
fmopa za5.d, p0/m, p0/m, z1.d, z5.d
fmopa za6.d, p0/m, p0/m, z1.d, z6.d
fmopa za7.d, p0/m, p0/m, z1.d, z7.d
add x15, x15, x9, lsl #1
add x16, x16, x25
subs x14, x14, #1
b.ne 14b
15:
cmp x13, x8
csel x19, x13, x8, lo
sub x20, x13, x19
mov w12, #0
mov x15, x1
16:
st1d {za0h.d[w12, 0]}, p4, [x15]
st1d {za1h.d[w12, 0]}, p5, [x15, x8, lsl #3]
st1d {za2h.d[w12, 0]}, p6, [x15, x27, lsl #3]
st1d {za3h.d[w12, 0]}, p7, [x15, x28, lsl #3]
add x15, x15, x24
add w12, w12, #1
cmp x12, x19
b.lo 16b
cbz x20, 18f
mov w12, #0
add x15, x1, x21
17:
st1d {za4h.d[w12, 0]}, p4, [x15]
st1d {za5h.d[w12, 0]}, p5, [x15, x8, lsl #3]
st1d {za6h.d[w12, 0]}, p6, [x15, x27, lsl #3]
st1d {za7h.d[w12, 0]}, p7, [x15, x28, lsl #3]
add x15, x15, x24
add w12, w12, #1
cmp x12, x20
b.lo 17b
18:
add x22, x22, x23
add x1, x1, x17
add x11, x11, x27
cmp x11, x3
b.lo 13b
add x10, x10, x26
cmp x10, x5
b.lo 8b
9:
smstop
ldp x27, x28, [sp, #128]
ldp x25, x26, [sp, #112]
ldp x23, x24, [sp, #96]
ldp x21, x22, [sp, #80]
ldp x19, x20, [sp, #64]
ldp d14, d15, [sp, #48]
ldp d12, d13, [sp, #32]
ldp d10, d11, [sp, #16]
ldp d8, d9, [sp], #144
ret)");

// c = a * b (i8 to i32), arguments in x0 to x5: c, pa, pb, m, g, n. L = SVL / 32. SMOPA adds to each
// 32-bit element the sum of four products of consecutive p, so `a` and `b` arrive packed in groups of
// four (`sc_sme_mul_i8`): pa holds, per panel of L rows and per group, each row's four bytes; pb, per
// panel of 4L columns and per group, each column's four bytes. Zeros pad the rows, columns and the last
// group. Each L x 4L block takes one A vector and one four-vector load of B per group, one SMOPA per
// tile. Integer sums wrap modulo 2^32 in any order: the portable kernel's results.
@platform(macos | ios | linux | android)
@arch(aarch64)
asm(M"(.text
.arch_extension sme2
.arch_extension sme-f64f64
.p2align 4
_sc_sme_i8_za:
sc_sme_i8_za:
stp d8, d9, [sp, #-144]!
stp d10, d11, [sp, #16]
stp d12, d13, [sp, #32]
stp d14, d15, [sp, #48]
stp x19, x20, [sp, #64]
stp x21, x22, [sp, #80]
stp x23, x24, [sp, #96]
stp x25, x26, [sp, #112]
stp x27, x28, [sp, #128]
mrs x8, TPIDR2_EL0
cbz x8, 23f
ldrh w9, [x8, #10]
ldr w10, [x8, #12]
orr w9, w9, w10
cbz w9, 20f
udf #0
20:
ldr x9, [x8]
cbz x9, 22f
rdsvl x10, #1
mov w12, #0
21:
str za[w12, 0], [x9]
addsvl x9, x9, #1
add w12, w12, #1
cmp x12, x10
b.lo 21b
22:
msr TPIDR2_EL0, xzr
23:
smstart
cntw x8
cntb x9
ptrue p0.b
ptrue pn8.b
cbz x3, 9f
cbz x5, 9f
lsl x24, x5, #2
mul x23, x4, x9
lsl x25, x9, #2
mul x22, x4, x25
lsl x26, x8, #2
lsl x27, x8, #1
add x28, x8, x27
mul x17, x9, x5
mov x10, #0
mov x20, x2
8:
whilelo p4.s, x10, x5
add x13, x10, x8
whilelo p5.s, x13, x5
add x13, x10, x27
whilelo p6.s, x13, x5
add x13, x10, x28
whilelo p7.s, x13, x5
mov x11, #0
mov x21, x1
add x19, x0, x10, lsl #2
13:
sub x13, x3, x11
cmp x13, x8
csel x13, x13, x8, lo
zero {za}
cbz x4, 15f
mov x14, x4
mov x15, x21
mov x16, x20
14:
ld1b {z0.b}, p0/z, [x15]
ld1b {z4.b-z7.b}, pn8/z, [x16]
smopa za0.s, p0/m, p0/m, z0.b, z4.b
smopa za1.s, p0/m, p0/m, z0.b, z5.b
smopa za2.s, p0/m, p0/m, z0.b, z6.b
smopa za3.s, p0/m, p0/m, z0.b, z7.b
add x15, x15, x9
add x16, x16, x25
subs x14, x14, #1
b.ne 14b
15:
mov w12, #0
mov x15, x19
16:
st1w {za0h.s[w12, 0]}, p4, [x15]
st1w {za1h.s[w12, 0]}, p5, [x15, x8, lsl #2]
st1w {za2h.s[w12, 0]}, p6, [x15, x27, lsl #2]
st1w {za3h.s[w12, 0]}, p7, [x15, x28, lsl #2]
add x15, x15, x24
add w12, w12, #1
cmp x12, x13
b.lo 16b
add x21, x21, x23
add x19, x19, x17
add x11, x11, x8
cmp x11, x3
b.lo 13b
add x20, x20, x22
add x10, x10, x26
cmp x10, x5
b.lo 8b
9:
smstop
ldp x27, x28, [sp, #128]
ldp x25, x26, [sp, #112]
ldp x23, x24, [sp, #96]
ldp x21, x22, [sp, #80]
ldp x19, x20, [sp, #64]
ldp d14, d15, [sp, #48]
ldp d12, d13, [sp, #32]
ldp d10, d11, [sp, #16]
ldp d8, d9, [sp], #144
ret)");

// The kernels' symbols: Mach-O spells a C name with a leading `_`, ELF without, so each kernel above
// carries both labels and the object format's directives below make its own one global and hidden.
@platform(macos | ios)
@arch(aarch64)
asm(M"(.globl _sc_sme_f32_za
.private_extern _sc_sme_f32_za
.globl _sc_sme_f64_za
.private_extern _sc_sme_f64_za
.globl _sc_sme_i8_za
.private_extern _sc_sme_i8_za
)");

@platform(linux | android)
@arch(aarch64)
asm(M"(.globl sc_sme_f32_za
.hidden sc_sme_f32_za
.type sc_sme_f32_za, %function
.globl sc_sme_f64_za
.hidden sc_sme_f64_za
.type sc_sme_f64_za, %function
.globl sc_sme_i8_za
.hidden sc_sme_i8_za
.type sc_sme_i8_za, %function
)");

@platform(macos | ios | linux | android)
@arch(aarch64)
extern "C" {
    fn sc_sme_f32_za(
        c: *mut f32,
        a: *const f32,
        b: *const f32,
        m: usize,
        k: usize,
        n: usize,
        pa: *mut f32,
        pb: *mut f32,
    );
    fn sc_sme_f64_za(
        c: *mut f64,
        a: *const f64,
        b: *const f64,
        m: usize,
        k: usize,
        n: usize,
        pa: *mut f64,
        pb: *mut f64,
    );
    fn sc_sme_i8_za(c: *mut i32, pa: *const i8, pb: *const i8, m: usize, g: usize, n: usize);
}
