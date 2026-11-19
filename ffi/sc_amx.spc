// AMX matrix kernels for std::simd::matrix: byte products into 32-bit sums on the tile registers
// (AMX-INT8), a 32 x 32 block of the result per step of 64 of the inner dimension. `a` and `c` stay where
// they are; `b` goes in groups of four rows. The caller has the tile state (`std::cpu::detect::request`).
// A kernel runs only where the CPU has AMX-INT8 (`cpu::Feature::AmxInt8`). Every result equals the
// portable kernel's: element (i, j) is the sum over p of the products modulo 2^32 (`tdpbssd` and
// `tdpbusd` wrap). Prefer `std::simd::matrix`, which checks the shapes and chooses a kernel by the CPU.
import std::cpu;
import std::simd;
import immintrin;
import stdlib;
import string as cstring;

/// 1 where this module has the kernels (Linux on x86_64), else 0.
pub const fn sc_amx_built() i32 {
    if PLATFORM == Platform::Linux && ARCH == Arch::X86_64 {
        return 1;
    }
    return 0;
}

/// `c` (m x n, i32) = `a` (m x k) * `b` (k x n), the bytes of `a` signed, or unsigned when `ua`, those
/// of `b` signed: each element the sum of the products modulo 2^32. 0, or -1 (`c` untouched) when the
/// kernels are not built or the scratch cannot be allocated. The caller guarantees the three extents and
/// the tile state (`std::cpu::detect::request(cpu::Feature::AmxInt8)`).
@platform(linux)
@arch(x86_64)
@target_feature([cpu::Feature::AmxTile, cpu::Feature::AmxInt8])
pub unsafe fn sc_amx_mul_i8(c: *mut i32, a: *const u8, b: *const u8, m: usize, k: usize, n: usize, ua: bool) i32 {
    // The inner dimension padded to a tile row's 64 bytes.
    let kp = k + 63 & ~63usize;
    if m == 0 || n == 0 || k == 0 || kp < k {
        return -1;
    }
    // `b` in kp / 4 groups of n words: group q holds rows 4q to 4q + 3 (zero past row k - 1), column j's
    // four bytes in word q * n + j; the groups past the rows are zero.
    let g = (k + 3) / 4;
    // After them, 2048 bytes for the last step's rows of `a` (`tiles`).
    let (words, o1) = (kp / 4).overflowing_mul(n);
    let (bytes, o2) = words.overflowing_mul(4);
    let (total, o3) = bytes.overflowing_add(2048);
    if o1 || o2 || o3 {
        return -1;
    }
    let pb = stdlib::malloc(total) as *mut u32;
    if pb == null {
        return -1;
    }
    for q in 0..g {
        simd::interleave_rows4(pb + q * n, b + 4 * q * n, n, (k - 4 * q).min(4), n);
    }
    cstring::memset(pb + g * n, 0, bytes - g * n * 4);
    tiles(c, a, pb, pb as *mut u8 + bytes, m, k, n, ua);
    stdlib::free(pb);
    return 0;
}

@platform(!linux)
@arch(x86_64)
@target_feature([cpu::Feature::AmxInt8])
pub unsafe fn sc_amx_mul_i8(_c: *mut i32, _a: *const u8, _b: *const u8, _m: usize, _k: usize, _n: usize, _ua: bool) i32 {
    return -1;
}

// For each 32 x 32 block of `c` (m x n, i32; at its edges what remains): tiles 0 to 3 hold its 16 x 16
// quarters, zeroed; each step of 64 bytes of the inner dimension loads rows i0 and i0 + 16 of `a` (tiles
// 4 and 5: 64 bytes of each of 16 rows, k apart) and 16 groups of `b` (tiles 6 and 7: columns j0 and j0 +
// 16, n words apart), and adds the four products, signed bytes of `a` or for `ua` unsigned. The
// configuration gives each tile its block's rows and columns; a quarter past the edges gets one row or
// column, reads the rows or columns of the quarter before it again and goes to `spare`. The step past the
// last whole one reads bytes of `a` past k, which meet the zero groups of `b`: in place while they stay
// inside `a`, else from a copy of the rows' last bytes in `last` (32 rows of 64 bytes, zero past k).
@platform(linux)
@arch(x86_64)
@target_feature([cpu::Feature::AmxTile, cpu::Feature::AmxInt8])
unsafe fn tiles(c: *mut i32, a: *const u8, b: *const u32, last: *mut u8, m: usize, k: usize, n: usize, ua: bool) {
    let kw = k & ~63usize;
    let row = n * 4;
    let mut cfg: [u8; 64] = [0; 64];
    cfg[0] = 1;
    // The loaded configuration's quarter extents, 0 before the first.
    let mut cur: usize = 0;
    let mut spare: [i32; 16] = [0; 16];
    let sp = ((&mut spare) as *mut [i32; 16]) as *mut i32;
    let mut zeroed = false;
    let mut i0: usize = 0;
    while i0 < m {
        let r0 = (m - i0).min(16);
        let r1 = (m - i0 - r0).min(16);
        let a0 = a + i0 * k;
        let d1 = if r1 != 0 {
            16 * k
        } else {
            0
        };
        let mut ta = a0 + kw;
        let mut td = d1;
        let mut ts = k;
        if kw < k && (i0 + r0 + r1 - 1) * k + kw + 64 > m * k {
            if !zeroed {
                cstring::memset(last, 0, 2048);
                zeroed = true;
            }
            for r in 0..r0 + r1 {
                cstring::memcpy(last + r * 64, a0 + r * k + kw, k - kw);
            }
            ta = last;
            td = if r1 != 0 {
                1024
            } else {
                0
            };
            ts = 64;
        }
        let mut j0: usize = 0;
        while j0 < n {
            let c0 = (n - j0).min(16);
            let c1 = (n - j0 - c0).min(16);
            let key = r0 | r1 << 8 | c0 << 16 | c1 << 24;
            if key != cur {
                let r1t = r1.max(1);
                let c1t = c1.max(1);
                for (t, rows, bytes) in [
                    (0usize, r0, 4 * c0),
                    (1, r0, 4 * c1t),
                    (2, r1t, 4 * c0),
                    (3, r1t, 4 * c1t),
                    (4, r0, 64),
                    (5, r1t, 64),
                    (6, 16, 4 * c0),
                    (7, 16, 4 * c1t),
                ] {
                    cfg[16 + 2 * t] = bytes as u8;
                    cfg[48 + t] = rows as u8;
                }
                immintrin::_tile_loadconfig((&cfg) as *const [u8; 64]);
                cur = key;
            }
            let d7 = if c1 != 0 {
                16usize
            } else {
                0
            };
            immintrin::_tile_zero(0);
            immintrin::_tile_zero(1);
            immintrin::_tile_zero(2);
            immintrin::_tile_zero(3);
            // Per step, 64 bytes of each row of `a` and 16 groups of `b`.
            let mut pa = a0;
            let mut pg = b + j0;
            while pa < a0 + kw {
                products(pa, pa + d1, k, pg, pg + d7, row, ua);
                pa = pa + 64;
                pg = pg + 16 * n;
            }
            if kw < k {
                products(ta, ta + td, ts, pg, pg + d7, row, ua);
            }
            let c0p = c + i0 * n + j0;
            immintrin::_tile_stored(0, c0p, row);
            if c1 != 0 {
                immintrin::_tile_stored(1, c0p + 16, row);
            } else {
                immintrin::_tile_stored(1, sp, 4);
            }
            if r1 != 0 {
                immintrin::_tile_stored(2, c0p + 16 * n, row);
            } else {
                immintrin::_tile_stored(2, sp, 4);
            }
            if r1 != 0 && c1 != 0 {
                immintrin::_tile_stored(3, c0p + 16 * n + 16, row);
            } else {
                immintrin::_tile_stored(3, sp, 4);
            }
            j0 += 32;
        }
        i0 += 32;
    }
    immintrin::_tile_release();
}

// One step: rows `a0` and `a1` of `a` (`sa` apart) into tiles 4 and 5, 16 groups of `b` from `b0` and `b1`
// (`row` bytes apart) into tiles 6 and 7, the four products added to tiles 0 to 3.
@platform(linux)
@arch(x86_64)
@target_feature([cpu::Feature::AmxTile, cpu::Feature::AmxInt8])
unsafe fn products(a0: *const u8, a1: *const u8, sa: usize, b0: *const u32, b1: *const u32, row: usize, ua: bool) {
    immintrin::_tile_loadd(4, a0, sa);
    immintrin::_tile_loadd(5, a1, sa);
    immintrin::_tile_loadd(6, b0, row);
    immintrin::_tile_loadd(7, b1, row);
    if ua {
        immintrin::_tile_dpbusd(0, 4, 6);
        immintrin::_tile_dpbusd(1, 4, 7);
        immintrin::_tile_dpbusd(2, 5, 6);
        immintrin::_tile_dpbusd(3, 5, 7);
    } else {
        immintrin::_tile_dpbssd(0, 4, 6);
        immintrin::_tile_dpbssd(1, 4, 7);
        immintrin::_tile_dpbssd(2, 5, 6);
        immintrin::_tile_dpbssd(3, 5, 7);
    }
}
