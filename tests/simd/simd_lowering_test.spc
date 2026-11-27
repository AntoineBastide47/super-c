// The native lowerings of portable vector operations in the test binary itself (opt-level 1), each against
// a scalar lane loop: an entry of fewer lanes per chunk (`min_num` of 16 lanes as four of 4), a choice, a
// count and the bits of a comparison's mask between lane widths (`lir::opt` `mask_choose`, `mask_count`,
// `mask_sum`), `compress_store` by whole steps with room for the vector after the start and by the lane
// loop without it, every element outside the vector's from the start unchanged (`lir::lower`
// `compress_chunks`), an unchecked gather of a constant mask lane by lane (`gather_lanes`, `lane_load`), a
// checked gather with one range test (`gather_checked`), and a float sum by halves in registers (`a64gen`
// `reduce_reg`).
import std::simd;

// A deterministic sequence: the next value of a 64-bit linear congruential generator.
const fn next(s: &mut u64) u64 {
    *s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    return *s >> 33;
}

@noinline
const fn min_max16(x: []f32) (f32, f32) {
    let mut lo = Simd::<f32, 16>::splat(1.0 / 0.0);
    let mut hi = Simd::<f32, 16>::splat(-1.0 / 0.0);
    let mut i: usize = 0;
    while i + 16 <= x.len() {
        let v = simd::load::<f32, 16>(x, i);
        lo = lo.min_num(v);
        hi = hi.max_num(v);
        i += 16;
    }
    let mut a: f32 = 1.0 / 0.0;
    let mut b: f32 = -1.0 / 0.0;
    for k in 0..16usize {
        a = a.min(lo[k]);
        b = b.max(hi[k]);
    }
    return (a, b);
}

@test
fn split_entries_skip_nan_lanes() {
    let mut x = Vector::<f32>::new();
    for k in 0..64usize {
        x.push(
            if k % 5 == 0 {
                0.0 / 0.0
            } else {
                k as f32 * 1.5 - 20.0
            },
        );
    }
    let (a, b) = min_max16(x[0..64]);
    assert(a == -18.5 && b == 74.5, "min_num and max_num by chunks");
}

// The bits, the count and a choice of bytes by a comparison of 16 floats, and the bits of 32 bytes and of 8
// halves, folded into one value.
@noinline
const fn mask_mix(f: []f32, u: []u8, h: []i16, p: []u8, q: []u8, out: []mut u8) u64 {
    let mut acc: u64 = 0;
    let mut i: usize = 0;
    while i + 32 <= u.len() {
        let m = simd::load::<f32, 16>(f, i).greater_than(Simd::<f32, 16>::splat(50.0));
        simd::store(out, i, m.choose(simd::load::<u8, 16>(p, i), simd::load::<u8, 16>(q, i)));
        let mb = simd::load::<u8, 32>(u, i).less_than(Simd::<u8, 32>::splat(120));
        let mh = simd::load::<i16, 8>(h, i).greater_equal(Simd::<i16, 8>::splat(3));
        acc = acc.wrapping_mul(31).wrapping_add(
            m.to_bits() + m.count() as u64 * 65537 + mb.to_bits() * 3 + mh.to_bits() * 5,
        );
        i += 32;
    }
    return acc;
}

@test
fn mask_bits_counts_and_choices_match_the_lanes() {
    let mut s: u64 = 7;
    let (mut f, mut u, mut h, mut p, mut q, mut o) = (
        Vector::<f32>::new(),
        Vector::<u8>::new(),
        Vector::<i16>::new(),
        Vector::<u8>::new(),
        Vector::<u8>::new(),
        Vector::<u8>::new()
    );
    for _ in 0..256usize {
        f.push((next(&mut s) % 101) as f32);
        u.push((next(&mut s) % 251) as u8);
        h.push((next(&mut s) % 199) as i16 - 100);
        p.push((next(&mut s) % 256) as u8);
        q.push((next(&mut s) % 256) as u8);
        o.push(0);
    }
    let got = mask_mix(f[0..256], u[0..256], h[0..256], p[0..256], q[0..256], o[0..256]);
    let mut want: u64 = 0;
    let mut i: usize = 0;
    while i + 32 <= 256 {
        let (mut bf, mut cf, mut bu, mut bh) = (0u64, 0u64, 0u64, 0u64);
        for k in 0..32usize {
            if k < 16 && f[i + k] > 50.0 {
                bf |= 1u64 << k as u64;
                cf += 1;
            }
            if k < 16 {
                let w = if f[i + k] > 50.0 {
                    p[i + k]
                } else {
                    q[i + k]
                };
                assert(o[i + k] == w, "a choice of bytes by a float comparison");
            }
            if u[i + k] < 120 {
                bu |= 1u64 << k as u64;
            }
            if k < 8 && h[i + k] >= 3 {
                bh |= 1u64 << k as u64;
            }
        }
        want = want.wrapping_mul(31).wrapping_add(bf + cf * 65537 + bu * 3 + bh * 5);
        i += 32;
    }
    assert(got == want, "mask bits and counts");
}

// The packed count and one past the last element a `compress_store` of the loop may write: the greatest
// start plus the vector's lanes.
@noinline
const fn filter16(x: []f32, t: f32, out: []mut f32) (usize, usize) {
    let tv = Simd::<f32, 16>::splat(t);
    let mut k: usize = 0;
    let mut hi: usize = 0;
    let mut i: usize = 0;
    while i + 16 <= x.len() {
        let v = simd::load::<f32, 16>(x, i);
        hi = k + 16;
        k += simd::compress_store(out, k, v.greater_than(tv), v);
        i += 16;
    }
    return (k, hi);
}

@noinline
const fn filter_u8(x: []u8, t: u8, out: []mut u8) (usize, usize) {
    let tv = Simd::<u8, 32>::splat(t);
    let mut k: usize = 0;
    let mut hi: usize = 0;
    let mut i: usize = 0;
    while i + 32 <= x.len() {
        let v = simd::load::<u8, 32>(x, i);
        hi = k + 32;
        k += simd::compress_store(out, k, v.greater_than(tv), v);
        i += 32;
    }
    return (k, hi);
}

@noinline
const fn filter_i64(x: []i64, t: i64, out: []mut i64) (usize, usize) {
    let tv = Simd::<i64, 8>::splat(t);
    let mut k: usize = 0;
    let mut hi: usize = 0;
    let mut i: usize = 0;
    while i + 8 <= x.len() {
        let v = simd::load::<i64, 8>(x, i);
        hi = k + 8;
        k += simd::compress_store(out, k, v.less_than(tv), v);
        i += 8;
    }
    return (k, hi);
}

// A loop of `compress_store` writes the active lanes in order, with room for whole vectors after the
// packed lanes (the steps) and without it (the output exactly as long: the last stores run the lane
// loop). The elements after the packed ones may hold any value up to the last store's vector from its
// start; those past it, and all those past the output, keep theirs.
@test
fn compress_store_by_chunks_writes_its_count_inside_its_window() {
    let mut s: u64 = 11;
    let mut x = Vector::<f32>::new();
    let mut b = Vector::<u8>::new();
    let mut w = Vector::<i64>::new();
    for _ in 0..256usize {
        x.push((next(&mut s) % 101) as f32);
        b.push((next(&mut s) % 256) as u8);
        w.push((next(&mut s) % 1000) as i64 - 500);
    }
    let mut fx = Vector::<f32>::new();
    let mut fb = Vector::<u8>::new();
    let mut fw = Vector::<i64>::new();
    for k in 0..256usize {
        if x[k] > 50.0 {
            fx.push(x[k]);
        }
        if b[k] > 100 {
            fb.push(b[k]);
        }
        if w[k] < 0 {
            fw.push(w[k]);
        }
    }
    for exact in [false, true] {
        let mut o = Vector::<f32>::new();
        let mut ob = Vector::<u8>::new();
        let mut ow = Vector::<i64>::new();
        for _ in 0..300usize {
            o.push(-1.0);
            ob.push(7);
            ow.push(9999);
        }
        let (nx, nb, nw) = if exact {
            (fx.len(), fb.len(), fw.len())
        } else {
            (300usize, 300usize, 300usize)
        };
        let (cx, hx) = filter16(x[0..256], 50.0, o[0..nx]);
        let (cb, hb) = filter_u8(b[0..256], 100, ob[0..nb]);
        let (cw, hw) = filter_i64(w[0..256], 0, ow[0..nw]);
        assert(cx == fx.len(), "the f32 count");
        assert(cb == fb.len(), "the u8 count");
        assert(cw == fw.len(), "the i64 count");
        for k in 0..300usize {
            if k < fx.len() {
                assert(o[k] == fx[k], "the f32 lanes in order");
            } else if k >= hx.min(nx) {
                assert(o[k] == -1.0, "no f32 element past the last vector or the output changes");
            }
            if k < fb.len() {
                assert(ob[k] == fb[k], "the u8 lanes in order");
            } else if k >= hb.min(nb) {
                assert(ob[k] == 7, "no u8 element past the last vector or the output changes");
            }
            if k < fw.len() {
                assert(ow[k] == fw[k], "the i64 lanes in order");
            } else if k >= hw.min(nw) {
                assert(ow[k] == 9999, "no i64 element past the last vector or the output changes");
            }
        }
    }
}

// One `compress_store` of lanes 1 to `N` under mask bits `m` at `start` into the first `len` of 24 elements
// that hold 50 and up: whether it returns the active lane count, the active lanes follow `start` in order,
// and every element before `start`, from `start + N` on or from `len` on keeps its value (the others after
// the stored ones may hold any).
@noinline
fn stored<T: SimdElement, const N: usize>(m: u64, start: usize, len: usize) bool {
    let v = (simd::iota::<i32, N>() + Simd::<i32, N>::splat(1)).cast::<T>();
    let mut o = [v[0]; 24];
    for c in 0..3usize {
        simd::store(o, 8 * c, (simd::iota::<i32, 8>() + Simd::<i32, 8>::splat(50 + 8 * c as i32)).cast::<T>());
    }
    let n = simd::compress_store(o[0..len], start, Mask::<N>::from_bits_truncate(m), v);
    let mut got = [0i32; 24];
    for c in 0..3usize {
        let a = simd::load::<T, 8>(o, 8 * c).cast::<i32>().to_array();
        for j in 0..8usize {
            got[8 * c + j] = a[j];
        }
    }
    let mut k: usize = 0;
    for i in 0..N {
        if (m >> i as u64 & 1) != 0 {
            if got[start + k] != i as i32 + 1 {
                return false;
            }
            k += 1;
        }
    }
    if n != k {
        return false;
    }
    for i in 0..24usize {
        if (i < start || i >= start + N || i >= len) && got[i] != 50 + i as i32 {
            return false;
        }
    }
    return true;
}

// `stored` of `N` lanes of 1, 2 and 4 bytes at `start`, into a slice that ends at the stored lanes (the lane
// loop stores exactly), one element before the vector's lanes from the start, at them (whole steps), and
// after them.
fn stored_all<const N: usize>(m: u64, start: usize) {
    let count = (m & (1u64 << N as u64) - 1).count_ones() as usize;
    for len in [start + count, start + N - 1, start + N, 24usize] {
        if len < start + count {
            continue;
        }
        assert(stored::<u8, N>(m, start, len), "lanes of 1 byte");
        assert(stored::<u16, N>(m, start, len), "lanes of 2 bytes");
        assert(stored::<i32, N>(m, start, len), "lanes of 4 bytes");
        assert(stored::<f32, N>(m, start, len), "float lanes of 4 bytes");
    }
}

// `stored_all` for lanes of 8 bytes, of at most 8 lanes.
fn stored_wide<const N: usize>(m: u64, start: usize) {
    let count = (m & (1u64 << N as u64) - 1).count_ones() as usize;
    for len in [start + count, start + N - 1, start + N, 24usize] {
        if len < start + count {
            continue;
        }
        assert(stored::<i64, N>(m, start, len), "lanes of 8 bytes");
        assert(stored::<f64, N>(m, start, len), "float lanes of 8 bytes");
    }
}

// Every mask of 2, 4 and 8 lanes and 256 masks of 16, from the slice's start and inside it.
@test
fn compress_store_of_every_mask_changes_nothing_outside_its_window() {
    for m in 0..256u64 {
        for start in [0usize, 1, 5] {
            if m < 4 {
                stored_all::<2>(m, start);
                stored_wide::<2>(m, start);
            }
            if m < 16 {
                stored_all::<4>(m, start);
                stored_wide::<4>(m, start);
            }
            stored_all::<8>(m, start);
            stored_wide::<8>(m, start);
            stored_all::<16>(m | (m * 73 & 255 ^ 0xA5) << 8, start);
        }
    }
}

@noinline
const fn gather_mix(x: []f32, idx: []u32) f32 {
    let all = Mask::<16>::splat(true);
    let some = Mask::<16>::from_bits(0x0F0F).unwrap();
    let mut acc = Simd::<f32, 16>::splat(0.0);
    let mut i: usize = 0;
    while i + 16 <= idx.len() {
        let ix = simd::load::<u32, 16>(idx, i);
        acc = acc + unsafe simd::gather_unchecked(x, ix, all, Simd::<f32, 16>::splat(0.0));
        acc = acc + unsafe simd::gather_unchecked(x, ix, some, Simd::<f32, 16>::splat(1000.0));
        i += 16;
    }
    let mut r: f32 = 0.0;
    for k in 0..16usize {
        r += acc[k];
    }
    return r;
}

@test
fn unchecked_gathers_load_each_active_lane() {
    let mut x = Vector::<f32>::new();
    let mut ix = Vector::<u32>::new();
    for k in 0..256usize {
        x.push((k % 13) as f32);
        ix.push((k * 97 % 256) as u32);
    }
    let mut want: f32 = 0.0;
    for k in 0..256usize {
        let e = x[ix[k] as usize];
        want += e + if (0x0F0Fu32 >> (k % 16) as u32 & 1) != 0 {
            e
        } else {
            1000.0
        };
    }
    assert(gather_mix(x[0..256], ix[0..256]) == want, "the gathered lanes");
}

// Whether lane `j` of `g` is element `(7j + 3) % 32` of the gathered slice (3 times its place plus 1) where
// `m` has it, else the fallback's `100 + j`.
fn lanes_are<T: SimdElement, const N: usize>(g: Simd<T, N>, m: u64) bool {
    let a = g.cast::<i32>().to_array();
    for j in 0..N {
        let want = if (m >> j as u64 & 1) != 0 {
            3 * (j as i32 * 7 + 3 & 31) + 1
        } else {
            100 + j as i32
        };
        if a[j] != want {
            return false;
        }
    }
    return true;
}

// Gathers of `N` lanes of `T` from 32 elements by 4-byte indices: unchecked under the masks of every lane
// and of some lanes (constants: the lanes load, `lir::opt` `gather_lanes`) and under the run-time mask `rt`
// (lanes and indices of different widths split into different numbers of registers: `lir::wide` keeps
// that gather whole), checked under the mask of every lane and under `rt` (one range test, `lir::lower`
// `gather_checked`).
@noinline
fn gathered<T: SimdElement, const N: usize>(rt: u64) bool {
    let mut x = [simd::iota::<T, 2>()[0]; 32];
    for c in 0..4usize {
        simd::store(
            x,
            8 * c,
            (simd::iota::<i32, 8>() * Simd::<i32, 8>::splat(3) + Simd::<i32, 8>::splat(24 * c as i32 + 1)).cast::<T>(),
        );
    }
    let ix = simd::iota::<u32, N>() * Simd::<u32, N>::splat(7) + Simd::<u32, N>::splat(3) & Simd::<u32, N>::splat(31);
    let fb = (simd::iota::<i32, N>() + Simd::<i32, N>::splat(100)).cast::<T>();
    let some: u64 = 0xA5A5A5A5A5A5A5A5 & (1u64 << N as u64) - 1;
    let all = (1u64 << N as u64) - 1;
    let ga = unsafe simd::gather_unchecked(x, ix, Mask::<N>::splat(true), fb);
    let gs = unsafe simd::gather_unchecked(x, ix, Mask::<N>::from_bits_truncate(0xA5A5A5A5A5A5A5A5), fb);
    let gc = simd::gather(x, ix, Mask::<N>::splat(true), fb);
    let gr = simd::gather(x, ix, Mask::<N>::from_bits_truncate(rt), fb);
    let gu = unsafe simd::gather_unchecked(x, ix, Mask::<N>::from_bits_truncate(rt), fb);
    let consts = lanes_are(ga, all) && lanes_are(gs, some) && lanes_are(gc, all);
    return consts && lanes_are(gr, rt & all) && lanes_are(gu, rt & all);
}

// `gathered` through 8-byte indices, of at most 8 lanes.
@noinline
fn gathered_wide<T: SimdElement, const N: usize>(rt: u64) bool {
    let mut x = [simd::iota::<T, 2>()[0]; 32];
    for c in 0..4usize {
        simd::store(
            x,
            8 * c,
            (simd::iota::<i32, 8>() * Simd::<i32, 8>::splat(3) + Simd::<i32, 8>::splat(24 * c as i32 + 1)).cast::<T>(),
        );
    }
    let ix = (simd::iota::<u32, N>() * Simd::<u32, N>::splat(7) + Simd::<u32, N>::splat(3) & Simd::<u32, N>::splat(31)).cast::<
        u64
    >();
    let fb = (simd::iota::<i32, N>() + Simd::<i32, N>::splat(100)).cast::<T>();
    let all = (1u64 << N as u64) - 1;
    let ga = unsafe simd::gather_unchecked(x, ix, Mask::<N>::splat(true), fb);
    let gr = simd::gather(x, ix, Mask::<N>::from_bits_truncate(rt), fb);
    return lanes_are(ga, all) && lanes_are(gr, rt & all);
}

// Every lane size, integer and float, from 2 to 16 lanes: one to four chunks of 16 bytes, and a chunk of
// fewer.
@test
fn gathers_of_every_lane_size_give_their_lanes() {
    for rt in [0u64, 0xFFFF, 0x1234, 0x8421] {
        assert(gathered::<u8, 16>(rt) && gathered::<u8, 4>(rt), "lanes of 1 byte");
        assert(gathered::<u16, 8>(rt) && gathered::<u16, 16>(rt) && gathered::<u16, 2>(rt), "lanes of 2 bytes");
        assert(gathered::<i32, 4>(rt) && gathered::<i32, 16>(rt) && gathered::<i32, 2>(rt), "lanes of 4 bytes");
        assert(gathered::<f32, 4>(rt) && gathered::<f32, 8>(rt) && gathered::<f32, 16>(rt), "float lanes of 4 bytes");
        assert(gathered::<i64, 2>(rt) && gathered::<i64, 8>(rt), "lanes of 8 bytes");
        assert(gathered::<f64, 2>(rt) && gathered::<f64, 4>(rt), "float lanes of 8 bytes");
        assert(
            gathered_wide::<f32, 4>(rt) && gathered_wide::<i64, 8>(rt) && gathered_wide::<u16, 8>(rt),
            "8-byte indices",
        );
    }
}

@noinline
const fn tree16(x: []f32) f32 {
    return simd::reduce_add_tree(simd::load::<f32, 16>(x, 0));
}

@noinline
const fn tree2(x: []f64) f64 {
    return simd::reduce_add_tree(simd::load::<f64, 2>(x, 0));
}

// A float sum by halves in registers (arm64 EXT, FADD and FADDP): the lanes pair as the halving defines,
// which a sum in lane order would not give for these values.
@test
fn a_tree_sum_adds_by_halves() {
    let mut x = Vector::<f32>::new();
    for k in 0..16usize {
        x.push(
            if k % 2 == 0 {
                1.0e8
            } else {
                -1.0e8
            } + k as f32 * 0.25,
        );
    }
    let mut w: [f32; 16] = [0.0; 16];
    for k in 0..16usize {
        w[k] = x[k];
    }
    let mut h: usize = 8;
    while h >= 1 {
        for k in 0..h {
            w[k] = w[k] + w[k + h];
        }
        h /= 2;
    }
    assert(tree16(x[0..16]).to_bits() == w[0].to_bits(), "16 f32 lanes by halves");
    let d: [f64; 2] = [0.1, 0.2];
    assert(tree2(d[0..2]).to_bits() == (0.1f64 + 0.2f64).to_bits(), "2 f64 lanes");
}
