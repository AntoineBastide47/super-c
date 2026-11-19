// AMX matrix kernels for std::simd::matrix: byte products into 32-bit sums on the tile registers
// (AMX-INT8), a 32 x 32 block of the result per step of 64 of the inner dimension. The entry point packs
// the operands, runs the kernel and copies the result out. The caller
// has the tile state (`std::cpu::detect::request`). A kernel runs only where the CPU has AMX-INT8 (`cpu::Feature::AmxInt8`). Every
// result equals the portable kernel's: element (i, j) is the sum over p of the products modulo 2^32
// (`tdpbssd` and `tdpbusd` wrap). Prefer `std::simd::matrix`, which checks the shapes and chooses a
// kernel by the CPU.
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
    // The extents padded: rows to the block's 32, columns to 32, the inner dimension to a tile row's 64.
    let mp = m + 31 & ~31usize;
    let np = n + 31 & ~31usize;
    let kp = k + 63 & ~63usize;
    if m == 0 || n == 0 || k == 0 || mp < m || np < n || kp < k {
        return -1;
    }
    // `a` and `c` serve in place when no extent pads; else a copy of their rows, the padding zero.
    let a_in = mp == m && kp == k;
    let c_in = mp == m && np == n;
    let (sa0, o1) = mp.overflowing_mul(kp);
    let (sb, o2) = kp.overflowing_mul(np);
    let (sc0, o3) = mp.overflowing_mul(np);
    let (sc1, o4) = sc0.overflowing_mul(4);
    let sa = if a_in {
        0usize
    } else {
        sa0
    };
    let sc = if c_in {
        0usize
    } else {
        sc1
    };
    // One allocation: `b` in groups of four rows (each column's four bytes one word, np words a group),
    // then `a` and the result when they do not serve in place.
    let (s1, o5) = sb.overflowing_add(sa);
    let (total, o6) = s1.overflowing_add(sc);
    if o1 || o2 || o3 || o4 || o5 || o6 {
        return -1;
    }
    let buf = stdlib::calloc(total, 1) as *mut u8;
    if buf == null {
        return -1;
    }
    let pb = buf as *mut u32;
    let pw = buf + sb;
    let pa = if a_in {
        a
    } else {
        pw as *const u8
    };
    let pc = if c_in {
        c
    } else {
        (buf + sb + sa) as *mut i32
    };
    if !a_in {
        for i in 0..m {
            cstring::memcpy(pw + i * kp, a + i * k, k);
        }
    }
    // Group g: rows 4g to 4g + 3 of `b` (0 past row k - 1), column j's four bytes in word g * np + j;
    // the full groups' columns in sixteens by `pack_b`, the rest here.
    let full = k / 4;
    let n16 = n & ~15usize;
    pack_b(pb, b, full, n, np);
    for g in 0..(k + 3) / 4 {
        let r = 4 * g;
        let b0 = b + r * n;
        let j0 = if g < full {
            n16
        } else {
            0usize
        };
        for j in j0..n {
            let mut w = b0[j] as u32;
            if r + 1 < k {
                w |= b0[n + j] as u32 << 8;
            }
            if r + 2 < k {
                w |= b0[2 * n + j] as u32 << 16;
            }
            if r + 3 < k {
                w |= b0[3 * n + j] as u32 << 24;
            }
            pb[g * np + j] = w;
        }
    }
    // Palette 1; tiles 0 to 7 of 16 rows of 64 bytes (bytes 16 to 31: each tile's row bytes, two each;
    // bytes 48 to 55: its rows).
    let mut cfg: [u8; 64] = [0; 64];
    cfg[0] = 1;
    for t in 0..8usize {
        cfg[16 + 2 * t] = 64;
        cfg[48 + t] = 16;
    }
    tiles(pc, pa, pb, mp, np, kp, ua, &cfg);
    if !c_in {
        for i in 0..m {
            cstring::memcpy(c + i * n, pc + i * np, n * 4);
        }
    }
    stdlib::free(buf);
    return 0;
}

@platform(!linux)
@arch(x86_64)
@target_feature([cpu::Feature::AmxInt8])
pub unsafe fn sc_amx_mul_i8(_c: *mut i32, _a: *const u8, _b: *const u8, _m: usize, _k: usize, _n: usize, _ua: bool) i32 {
    return -1;
}

// Groups 0 to `groups - 1` of `b` (four rows of n bytes each), columns 0 to a multiple of 16, into words
// g * np + j: per 16 columns, the four rows' bytes interleaved by pairs, then the pairs by twos.
@platform(linux)
@arch(x86_64)
unsafe fn pack_b(dst: *mut u32, b: *const u8, groups: usize, n: usize, np: usize) {
    let n16 = n & ~15usize;
    for g in 0..groups {
        let r0 = b + 4 * g * n;
        let o = dst + g * np;
        let mut j: usize = 0;
        while j < n16 {
            let x0 = simd::load_unaligned::<u8, 16>(r0 + j);
            let x1 = simd::load_unaligned::<u8, 16>(r0 + n + j);
            let x2 = simd::load_unaligned::<u8, 16>(r0 + 2 * n + j);
            let x3 = simd::load_unaligned::<u8, 16>(r0 + 3 * n + j);
            let lo01 = simd::interleave_low(x0, x1).bitcast::<u16, 8>();
            let hi01 = simd::interleave_high(x0, x1).bitcast::<u16, 8>();
            let lo23 = simd::interleave_low(x2, x3).bitcast::<u16, 8>();
            let hi23 = simd::interleave_high(x2, x3).bitcast::<u16, 8>();
            simd::store_unaligned(o + j, simd::interleave_low(lo01, lo23).bitcast::<u32, 4>());
            simd::store_unaligned(o + j + 4, simd::interleave_high(lo01, lo23).bitcast::<u32, 4>());
            simd::store_unaligned(o + j + 8, simd::interleave_low(hi01, hi23).bitcast::<u32, 4>());
            simd::store_unaligned(o + j + 12, simd::interleave_high(hi01, hi23).bitcast::<u32, 4>());
            j += 16;
        }
    }
}

// For each 32 x 32 block of the padded result `c` (mp x np, i32): tiles 0 to 3 hold its four 16 x 16
// quarters, zeroed; each step of 64 bytes of the inner dimension loads rows i0 and i0 + 16 of `a` (tiles 4
// and 5: 64 bytes of each of 16 rows, kp apart) and the groups of `b` (tiles 6 and 7: 16 groups of four
// rows, columns j0 and j0 + 16, np words apart), and adds the four products, signed bytes of `a` or for
// `ua` unsigned. The tile configuration `cfg` (64 bytes) gives every tile 16 rows of 64 bytes.
@platform(linux)
@arch(x86_64)
@target_feature([cpu::Feature::AmxTile, cpu::Feature::AmxInt8])
unsafe fn tiles(c: *mut i32, a: *const u8, b: *const u32, mp: usize, np: usize, kp: usize, ua: bool, cfg: &[u8; 64]) {
    immintrin::_tile_loadconfig(cfg as *const [u8; 64]);
    let row = np * 4;
    let mut i0: usize = 0;
    while i0 < mp {
        let mut j0: usize = 0;
        while j0 < np {
            immintrin::_tile_zero(0);
            immintrin::_tile_zero(1);
            immintrin::_tile_zero(2);
            immintrin::_tile_zero(3);
            let a0 = a + i0 * kp;
            let a1 = a0 + 16 * kp;
            let mut p: usize = 0;
            while p < kp {
                let bg = b + p / 4 * np + j0;
                immintrin::_tile_loadd(4, a0 + p, kp);
                immintrin::_tile_loadd(5, a1 + p, kp);
                immintrin::_tile_loadd(6, bg, row);
                immintrin::_tile_loadd(7, bg + 16, row);
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
                p += 64;
            }
            let c0 = c + i0 * np + j0;
            let c1 = c0 + 16 * np;
            immintrin::_tile_stored(0, c0, row);
            immintrin::_tile_stored(1, c0 + 16, row);
            immintrin::_tile_stored(2, c1, row);
            immintrin::_tile_stored(3, c1 + 16, row);
            j0 += 32;
        }
        i0 += 32;
    }
    immintrin::_tile_release();
}
