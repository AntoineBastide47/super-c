// The native lowerings of portable vector operations in the test binary itself (opt-level 1), each against
// a scalar lane loop: an entry of fewer lanes per chunk (`min_num` of 16 lanes as four of 4), a choice, a
// count and the bits of a comparison's mask between lane widths (`lir::opt` `mask_choose`, `mask_count`,
// `mask_sum`), `compress_store` by chunks with and without room after the packed lanes
// (`lir::lower` `compress_chunks`), and an unchecked gather of a constant mask lane by lane
// (`gather_lanes`, `lane_load`).
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

@noinline
const fn filter16(x: []f32, t: f32, out: []mut f32) usize {
    let tv = Simd::<f32, 16>::splat(t);
    let mut k: usize = 0;
    let mut i: usize = 0;
    while i + 16 <= x.len() {
        let v = simd::load::<f32, 16>(x, i);
        k += simd::compress_store(out, k, v.greater_than(tv), v);
        i += 16;
    }
    return k;
}

@noinline
const fn filter_u8(x: []u8, t: u8, out: []mut u8) usize {
    let tv = Simd::<u8, 32>::splat(t);
    let mut k: usize = 0;
    let mut i: usize = 0;
    while i + 32 <= x.len() {
        let v = simd::load::<u8, 32>(x, i);
        k += simd::compress_store(out, k, v.greater_than(tv), v);
        i += 32;
    }
    return k;
}

@noinline
const fn filter_i64(x: []i64, t: i64, out: []mut i64) usize {
    let tv = Simd::<i64, 8>::splat(t);
    let mut k: usize = 0;
    let mut i: usize = 0;
    while i + 8 <= x.len() {
        let v = simd::load::<i64, 8>(x, i);
        k += simd::compress_store(out, k, v.less_than(tv), v);
        i += 8;
    }
    return k;
}

// `compress_store` writes the active lanes in order and nothing past them, with room after the packed
// lanes (the chunks) and without it (the output exactly as long: the last stores run the lane loop).
@test
fn compress_store_by_chunks_writes_exactly_its_count() {
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
        assert(filter16(x[0..256], 50.0, o[0..nx]) == fx.len(), "the f32 count");
        assert(filter_u8(b[0..256], 100, ob[0..nb]) == fb.len(), "the u8 count");
        assert(filter_i64(w[0..256], 0, ow[0..nw]) == fw.len(), "the i64 count");
        for k in 0..300usize {
            assert(
                o[k] == if k < fx.len() {
                    fx[k]
                } else {
                    -1.0
                },
                "the f32 lanes and nothing past them",
            );
            assert(
                ob[k] == if k < fb.len() {
                    fb[k]
                } else {
                    7
                },
                "the u8 lanes and nothing past them",
            );
            assert(
                ow[k] == if k < fw.len() {
                    fw[k]
                } else {
                    9999
                },
                "the i64 lanes and nothing past them",
            );
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
