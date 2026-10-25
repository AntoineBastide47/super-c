// std::collections::mdspan: every view maps an index tuple to the element at the sum of index times stride,
// and the oracle is that sum computed here from the extents and strides the test chose. Data slices hold
// their own offsets (`data[k] == k`), so an element's value is the offset the view computed. Sub-views,
// transposes and iteration are checked against the same arithmetic; a seeded Pcg32 drives the randomized
// shapes.

import std::collections::mdspan as md;
import std::math::random as rnd;

// `0, 1, .., n - 1`: each element is its own offset.
fn offsets(n: usize) Vector<usize> {
    let mut v = Vector::<usize>::with_capacity(n);
    for k in 0..n {
        v.push(k);
    }
    return v;
}

const fn same<const N: usize>(a: [usize; N], b: [usize; N]) bool {
    for k in 0..N {
        if unsafe a[k] != unsafe b[k] {
            return false;
        }
    }
    return true;
}

const fn dot(idx: []usize, strides: []usize) usize {
    let mut o: usize = 0;
    for k in 0..idx.len {
        o += idx[k] * strides[k];
    }
    return o;
}

// The index tuple number `flat` in row-major order (the last index fastest).
const fn index_of<const R: usize>(extents: [usize; R], flat: usize) [usize; R] {
    let mut idx: [usize; R] = [0; R];
    let mut rest = flat;
    let mut d = R;
    while d > 0 {
        d -= 1;
        unsafe {
            idx[d] = rest % extents[d];
            rest /= extents[d];
        }
    }
    return idx;
}

// The required span size of a shape: 0 without elements, else the largest offset plus one.
const fn span_of(extents: []usize, strides: []usize) usize {
    let mut last: usize = 0;
    for k in 0..extents.len {
        if extents[k] == 0 {
            return 0;
        }
        last += (extents[k] - 1) * strides[k];
    }
    return last + 1;
}

// The iterator reports exactly `n` elements left.
const fn exact<const R: usize>(it: &md::MdIter<usize, R>, n: usize) bool {
    let (lo, hi) = it.size_hint();
    return lo == n && hi == Option::<usize>::Some(n);
}

// Every element of `v` against `base + dot(idx, strides)`, through `get`, `get_checked`, `get_unchecked`
// and both iteration directions.
fn check_view<const R: usize>(v: md::MdSpan<usize, R>, base: usize, strides: [usize; R]) {
    let extents = v.extents();
    let n = v.size();
    assert(same(v.strides(), strides));
    let mut it = v.iter();
    for flat in 0..n {
        let idx = index_of(extents, flat);
        let want = base + dot(idx, strides);
        assert_eq(*v.get(idx), want);
        assert_eq(*v.get_checked(idx).unwrap(), want);
        assert_eq(*unsafe v.get_unchecked(idx), want);
        assert(exact(&it, n - flat));
        assert_eq(*it.next().unwrap(), want);
    }
    assert(it.next().is_none());
    let mut back = v.iter();
    for k in 0..n {
        let want = base + dot(index_of(extents, n - 1 - k), strides);
        assert_eq(*back.next_back().unwrap(), want);
    }
    assert(back.next_back().is_none());
    assert(back.next().is_none());
}

// Front and back alternate and meet: every element comes out once.
fn check_meet<const R: usize>(v: md::MdSpan<usize, R>, base: usize, strides: [usize; R]) {
    let extents = v.extents();
    let n = v.size();
    let mut it = v.iter();
    let mut lo: usize = 0;
    let mut hi = n;
    let mut turn: usize = 0;
    while lo < hi {
        if turn % 3 == 2 {
            hi -= 1;
            assert_eq(*it.next_back().unwrap(), base + dot(index_of(extents, hi), strides));
        } else {
            assert_eq(*it.next().unwrap(), base + dot(index_of(extents, lo), strides));
            lo += 1;
        }
        turn += 1;
    }
    assert(it.next().is_none());
    assert(it.next_back().is_none());
}

const fn row_strides<const R: usize>(extents: [usize; R]) [usize; R] {
    let mut s: [usize; R] = [0; R];
    let mut step: usize = 1;
    let mut d = R;
    while d > 0 {
        d -= 1;
        unsafe {
            s[d] = step;
            step *= extents[d];
        }
    }
    return s;
}

const fn col_strides<const R: usize>(extents: [usize; R]) [usize; R] {
    let mut s: [usize; R] = [0; R];
    let mut step: usize = 1;
    for d in 0..R {
        unsafe {
            s[d] = step;
            step *= extents[d];
        }
    }
    return s;
}

fn check_dense<const R: usize>(extents: [usize; R]) {
    let mut n: usize = 1;
    for k in 0..R {
        n *= unsafe extents[k];
    }
    let data = offsets(n);
    let r = md::MdSpan::<usize, R>::row_major(data[0..], extents).unwrap();
    let c = md::MdSpan::<usize, R>::col_major(data[0..], extents).unwrap();
    assert_eq(r.rank(), R);
    assert_eq(r.size(), n);
    assert_eq(c.size(), n);
    check_view(r, 0, row_strides(extents));
    check_view(c, 0, col_strides(extents));
    check_meet(r, 0, row_strides(extents));
    check_meet(c, 0, col_strides(extents));
    for v in [r, c] {
        assert(v.is_unique());
        assert(v.is_exhaustive());
        assert(v.is_strided());
        assert(v.is_contiguous());
        assert(!v.is_empty());
        let s = v.as_slice().unwrap();
        assert_eq(s.len, n);
        assert_eq(s.ptr, data.as_ptr());
    }
}

const fn need_send<T: Send>(_x: &T) {}

const fn need_sync<T: Sync>(_x: &T) {}

@test
fn dense_layouts_of_ranks_1_to_4() {
    check_dense::<1>([5]);
    check_dense::<2>([3, 4]);
    check_dense::<3>([2, 3, 4]);
    check_dense::<4>([2, 3, 2, 3]);
    check_dense::<4>([1, 3, 1, 2]);
    check_dense::<2>([1, 1]);
}

@test
fn column_major_iterates_in_index_order() {
    let data = offsets(6);
    let c = md::MdSpan::<usize, 2>::col_major(data[0..], [2, 3]).unwrap();
    assert(same(c.strides(), [1, 2]));
    let mut seen = Vector::<usize>::new();
    for x in c.iter() {
        seen.push(*x);
    }
    assert_eq(seen.fmt().as_str(), "[0, 2, 4, 1, 3, 5]");
    // Memory order differs from index order for this layout.
    assert_eq(c.as_slice().unwrap().len, 6);
    assert_eq(c.fmt().as_str(), "[[0, 2, 4], [1, 3, 5]]");
}

@test
fn rank_0_views_one_element() {
    let data = offsets(3);
    let v = md::MdSpan::<usize, 0>::row_major(data[1..], []).unwrap();
    assert_eq(v.rank(), 0);
    assert_eq(v.size(), 1);
    assert(!v.is_empty());
    assert_eq(*v.get([]), 1);
    assert(v.is_contiguous());
    assert_eq(v.as_slice().unwrap().len, 1);
    assert_eq(v.fmt().as_str(), "1");
    let mut it = v.iter();
    assert(exact(&it, 1));
    assert_eq(*it.next().unwrap(), 1);
    assert(it.next().is_none());
    let none = md::MdSpan::<usize, 0>::row_major(data[0..0], []);
    assert_eq(none.unwrap_err(), md::MdSpanError::TooShort { required: 1, len: 0 });
}

@test
fn strided_layouts() {
    let data = offsets(30);
    // Padded rows: 10 elements per row, every second one used.
    let v = md::MdSpan::<usize, 2>::strided(data[0..], [3, 4], [10, 2]).unwrap();
    check_view(v, 0, [10, 2]);
    check_meet(v, 0, [10, 2]);
    assert(v.is_unique());
    assert(!v.is_exhaustive());
    assert(!v.is_contiguous());
    assert(v.as_slice().is_none());
    assert_eq(v.stride(0), 10);
    assert_eq(v.stride(1), 2);
    // The last offset is 2 * 10 + 3 * 2 = 26: 27 elements are enough.
    assert(md::MdSpan::<usize, 2>::strided(data[0..27], [3, 4], [10, 2]).is_ok());
    // A permuted dense layout is contiguous though neither row- nor column-major.
    let p = md::MdSpan::<usize, 3>::strided(data[0..24], [2, 3, 4], [4, 8, 1]).unwrap();
    check_view(p, 0, [4, 8, 1]);
    assert(p.is_unique());
    assert(p.is_exhaustive());
    assert_eq(p.as_slice().unwrap().len, 24);
    // Unique with interleaved strides (offsets 0, 2, 4, 3, 5, 7): the C++ condition does not prove it.
    let q = md::MdSpan::<usize, 2>::strided(data[0..8], [3, 2], [2, 3]).unwrap();
    check_view(q, 0, [2, 3]);
    assert(!q.is_unique());
    // Overlapping and covering (offsets 0, 1, 1, 2): reported not exhaustive, which C++ permits.
    let o = md::MdSpan::<usize, 2>::strided(data[0..3], [2, 2], [1, 1]).unwrap();
    check_view(o, 0, [1, 1]);
    assert(!o.is_unique());
    assert(!o.is_exhaustive());
}

@test
fn zero_strides_broadcast() {
    let data = offsets(4);
    let rows = md::MdSpan::<usize, 2>::strided(data[0..], [3, 4], [0, 1]).unwrap();
    check_view(rows, 0, [0, 1]);
    check_meet(rows, 0, [0, 1]);
    assert(!rows.is_unique());
    assert(rows.is_exhaustive());
    assert(!rows.is_contiguous());
    assert(rows.as_slice().is_none());
    let cols = md::MdSpan::<usize, 2>::strided(data[0..], [4, 3], [1, 0]).unwrap();
    check_view(cols, 0, [1, 0]);
    check_meet(cols, 0, [1, 0]);
    let scalar = md::MdSpan::<usize, 3>::strided(data[2..3], [2, 3, 5], [0, 0, 0]).unwrap();
    check_view(scalar, 2, [0, 0, 0]);
    assert_eq(scalar.size(), 30);
    assert(!scalar.is_unique());
    // A zero stride over an extent of 1 repeats nothing.
    let one = md::MdSpan::<usize, 2>::strided(data[0..], [1, 4], [0, 1]).unwrap();
    assert(one.is_unique());
    assert(one.is_contiguous());
}

@test
fn zero_extents_have_no_elements() {
    let data = offsets(4);
    let e = md::MdSpan::<usize, 3>::row_major(data[0..0], [3, 0, 2]).unwrap();
    assert_eq(e.size(), 0);
    assert(e.is_empty());
    assert(same(e.extents(), [3, 0, 2]));
    assert(e.get_checked([0, 0, 0]).is_none());
    assert(e.iter().next().is_none());
    assert(e.iter().next_back().is_none());
    let ei = e.iter();
    assert(exact(&ei, 0));
    assert_eq(e.fmt().as_str(), "[[], [], []]");
    assert(e.is_unique());
    assert(e.is_exhaustive());
    assert_eq(e.as_slice().unwrap().len, 0);
    // A strided view without elements accepts any strides and any slice.
    let s = md::MdSpan::<usize, 2>::strided(data[0..0], [0, 5], [usize::MAX, usize::MAX]).unwrap();
    assert_eq(s.size(), 0);
    assert_eq(s.fmt().as_str(), "[]");
    let t = md::MdSpan::<usize, 2>::strided(data[0..0], [5, 0], [usize::MAX, 7]).unwrap();
    assert_eq(t.fmt().as_str(), "[[], [], [], [], []]");
    let sub = t.slice_dim(0, 1, 4);
    assert(same(sub.extents(), [3, 0]));
    assert(sub.is_empty());
    let row = t.fix(0, 4);
    assert(same(row.extents(), [0]));
    assert(row.is_empty());
    // A zero extent after large ones keeps the count at 0 without an overflow.
    let big = md::MdSpan::<usize, 3>::row_major(data[0..0], [usize::MAX / 2, 3, 0]).unwrap();
    assert_eq(big.size(), 0);
    let m = md::MdSpan::<usize, 1>::col_major(data[0..], [0]).unwrap();
    assert(m.is_empty());
}

@test
fn validation_failures() {
    let data = offsets(12);
    let short = md::MdSpan::<usize, 2>::row_major(data[0..11], [3, 4]);
    assert_eq(short.unwrap_err(), md::MdSpanError::TooShort { required: 12, len: 11 });
    let col = md::MdSpan::<usize, 3>::col_major(data[0..], [2, 2, 4]);
    assert_eq(col.unwrap_err(), md::MdSpanError::TooShort { required: 16, len: 12 });
    // Out-of-range strides: the last offset 2 * 5 + 1 * 2 = 12 is not below 12.
    let far = md::MdSpan::<usize, 2>::strided(data[0..], [3, 2], [5, 2]);
    assert_eq(far.unwrap_err(), md::MdSpanError::TooShort { required: 13, len: 12 });
    let over = md::MdSpanError::Overflow;
    // The extent product overflows.
    assert_eq(md::MdSpan::<usize, 2>::row_major(data[0..], [usize::MAX / 2, 3]).unwrap_err(), over);
    assert_eq(md::MdSpan::<usize, 2>::col_major(data[0..], [usize::MAX, 2]).unwrap_err(), over);
    assert_eq(md::MdSpan::<usize, 2>::strided(data[0..], [usize::MAX / 3, 4], [0, 0]).unwrap_err(), over);
    // A stride product overflows although another extent is 0.
    assert_eq(md::MdSpan::<usize, 3>::row_major(data[0..0], [0, usize::MAX / 2, 3]).unwrap_err(), over);
    // The largest offset overflows, or the required span size does not fit.
    assert_eq(md::MdSpan::<usize, 2>::strided(data[0..], [2, 2], [usize::MAX, 1]).unwrap_err(), over);
    assert_eq(md::MdSpan::<usize, 2>::strided(data[0..], [3, 1], [usize::MAX, 1]).unwrap_err(), over);
    assert_eq(md::MdSpan::<usize, 2>::strided(data[0..], [2, 1], [usize::MAX, 1]).unwrap_err(), over);
    let mut buf = offsets(4);
    let bad = md::MdSpanMut::<usize, 2>::row_major(buf.index_range_mut(0..4), [2, 3]);
    assert(bad.is_err());
    assert_eq(md::MdSpanError::TooShort { required: 6, len: 4 }.fmt().as_str(), "TooShort(6, 4)");
}

@test
fn sub_views_match_index_arithmetic() {
    let data = offsets(60);
    let v = md::MdSpan::<usize, 3>::row_major(data[0..], [3, 4, 5]).unwrap();
    let s = row_strides::<3>([3, 4, 5]);
    // Narrow each dimension.
    let a = v.slice_dim(0, 1, 3);
    assert(same(a.extents(), [2, 4, 5]));
    check_view(a, 1 * 20, s);
    let b = v.slice_dim(1, 2, 3);
    assert(same(b.extents(), [3, 1, 5]));
    check_view(b, 2 * 5, s);
    let c = v.slice_dim(2, 1, 4);
    check_view(c, 1, s);
    check_meet(c, 1, s);
    assert(!c.is_contiguous());
    let empty = v.slice_dim(2, 5, 5);
    assert(empty.is_empty());
    assert(empty.iter().next().is_none());
    assert(same(v.slice_dim(0, 0, 3).extents(), [3, 4, 5]));
    // Fix each dimension.
    let f0 = v.fix(0, 2);
    check_view(f0, 40, [5, 1]);
    assert(f0.is_contiguous());
    let f1 = v.fix(1, 3);
    check_view(f1, 15, [20, 1]);
    assert(!f1.is_contiguous());
    let f2 = v.fix(2, 4);
    check_view(f2, 4, [20, 5]);
    // Down to rank 0.
    let one = v.fix(0, 1).fix(0, 2).fix(0, 3);
    assert_eq(*one.get([]), 1 * 20 + 2 * 5 + 3);
    // A sub-view of a sub-view.
    let g = v.slice_dim(1, 1, 4).fix(2, 2).slice_dim(0, 1, 2);
    check_view(g, 20 + 5 + 2, [20, 5]);
    // Rank 4.
    let data4 = offsets(120);
    let w = md::MdSpan::<usize, 4>::col_major(data4[0..], [2, 3, 4, 5]).unwrap();
    check_view(w.fix(2, 3), 3 * 6, [1, 2, 24]);
    check_view(w.fix(0, 1).fix(0, 2), 1 + 2 * 2, [6, 24]);
}

@test
fn transpose_swaps_extents_and_strides() {
    let data = offsets(12);
    let v = md::MdSpan::<usize, 2>::row_major(data[0..], [3, 4]).unwrap();
    let t = v.transpose();
    assert(same(t.extents(), [4, 3]));
    assert(same(t.strides(), [1, 4]));
    for i in 0usize..3 {
        for j in 0usize..4 {
            assert_eq(*t.get([j, i]), *v.get([i, j]));
        }
    }
    check_view(t, 0, [1, 4]);
    check_meet(t, 0, [1, 4]);
    assert_eq(t.fmt().as_str(), "[[0, 4, 8], [1, 5, 9], [2, 6, 10], [3, 7, 11]]");
    assert(t.is_contiguous());
    // A column of `v` is a row of `t`.
    check_view(t.fix(0, 2), 2, [4]);
    let tt = t.transpose();
    check_view(tt, 0, [4, 1]);
    let s = md::MdSpan::<usize, 2>::strided(data[0..], [2, 3], [6, 2]).unwrap();
    check_view(s.transpose(), 0, [2, 6]);
}

@test
fn randomized_offsets_against_reference() {
    let mut rng = rnd::Pcg32::new(0x6d64_7370, 7);
    for _round in 0..200 {
        let mut extents: [usize; 3] = [0; 3];
        let mut strides: [usize; 3] = [0; 3];
        for k in 0..3 {
            unsafe {
                extents[k] = (rng.next_u32() % 6) as usize;
                strides[k] = (rng.next_u32() % 9) as usize;
            }
        }
        let span = span_of(extents, strides);
        let slack = (rng.next_u32() % 3) as usize;
        let data = offsets(span + slack);
        let v = md::MdSpan::<usize, 3>::strided(data[0..], extents, strides).unwrap();
        assert_eq(v.is_empty(), span == 0);
        check_view(v, 0, strides);
        check_meet(v, 0, strides);
        if span > 0 {
            let short = md::MdSpan::<usize, 3>::strided(data[0..span - 1], extents, strides);
            assert_eq(short.unwrap_err(), md::MdSpanError::TooShort { required: span, len: span - 1 });
        }
        // A random sub-view, checked against the same arithmetic.
        let d = (rng.next_u32() % 3) as usize;
        let e = unsafe extents[d];
        if e > 0 {
            let i = rng.next_u32() as usize % e;
            let lo = rng.next_u32() as usize % (e + 1);
            let hi = lo + rng.next_u32() as usize % (e - lo + 1);
            let sub = v.slice_dim(d, lo, hi);
            let base = if sub.is_empty() {
                0;
            } else {
                lo * unsafe strides[d];
            };
            check_view(sub, base, strides);
            let f = v.fix(d, i);
            let mut fs: [usize; 2] = [0; 2];
            let mut j: usize = 0;
            for k in 0usize..3 {
                if k != d {
                    unsafe {
                        fs[j] = strides[k];
                    }
                    j += 1;
                }
            }
            let fbase = if f.is_empty() {
                0;
            } else {
                i * unsafe strides[d];
            };
            check_view(f, fbase, fs);
        }
    }
}

@test
fn randomized_rank_4_iteration() {
    let mut rng = rnd::Pcg32::new(42, 54);
    for _round in 0..100 {
        let mut extents: [usize; 4] = [0; 4];
        let mut strides: [usize; 4] = [0; 4];
        for k in 0..4 {
            unsafe {
                extents[k] = 1 + (rng.next_u32() % 4) as usize;
                strides[k] = (rng.next_u32() % 30) as usize;
            }
        }
        // Mix in dense layouts, which fuse into longer runs.
        if rng.next_u32() % 2 == 0 {
            strides = if rng.next_u32() % 2 == 0 {
                row_strides(extents);
            } else {
                col_strides(extents);
            };
        }
        let data = offsets(span_of(extents, strides));
        let v = md::MdSpan::<usize, 4>::strided(data[0..], extents, strides).unwrap();
        check_view(v, 0, strides);
        check_meet(v, 0, strides);
    }
}

@test
fn writes_reach_the_source_vector() {
    let mut v = offsets(12);
    {
        let mut m = md::MdSpanMut::<usize, 2>::row_major(v.index_range_mut(0..12), [3, 4]).unwrap();
        assert_eq(m.rank(), 2);
        assert(same(m.extents(), [3, 4]));
        assert(same(m.strides(), [4, 1]));
        assert_eq(m.extent(1), 4);
        assert_eq(m.stride(0), 4);
        assert_eq(m.size(), 12);
        assert(!m.is_empty());
        m.set([0, 1], 100);
        *m.get_mut([2, 3]) += 1000;
        assert(m.get_checked_mut([3, 0]).is_none());
        *m.get_checked_mut([1, 1]).unwrap() = 200;
        *unsafe m.get_unchecked_mut([1, 2]) = 300;
        assert_eq(*m.get([0, 1]), 100);
        {
            let mut row = m.fix(0, 2);
            row.set([0], 400);
        }
        {
            let mut col = m.fix(1, 0);
            col.set([1], 500);
        }
        {
            let mut t = m.transpose();
            assert(same(t.extents(), [4, 3]));
            t.set([3, 0], 600);
        }
        {
            let mut part = m.slice_dim(1, 2, 4);
            part.set([0, 0], 700);
        }
        let view = m.as_view();
        assert(view.is_contiguous());
        assert_eq(*view.get([1, 1]), 200);
        assert_eq(m.fmt().as_str(), "[[0, 100, 700, 600], [500, 200, 300, 7], [400, 9, 10, 1011]]");
        let s = m.as_mut_slice().unwrap();
        s[5] = 800;
    }
    assert_eq(v.fmt().as_str(), "[0, 100, 700, 600, 500, 800, 300, 7, 400, 9, 10, 1011]");
}

@test
fn broadcast_writes_share_one_element() {
    let mut v = offsets(3);
    {
        let mut m = md::MdSpanMut::<usize, 2>::strided(v.index_range_mut(0..3), [4, 3], [0, 1]).unwrap();
        m.set([3, 1], 50);
        assert_eq(*m.get([0, 1]), 50);
        assert(m.as_mut_slice().is_none());
        assert(!m.as_view().is_unique());
    }
    assert_eq(v.fmt().as_str(), "[0, 50, 2]");
    let mut w = offsets(6);
    {
        let mut c = md::MdSpanMut::<usize, 2>::col_major(w.index_range_mut(0..6), [2, 3]).unwrap();
        c.set([1, 2], 9);
        assert_eq(c.as_mut_slice().unwrap().len, 6);
    }
    assert_eq(*w.at(5), 9);
}

@test
fn set_frees_the_replaced_string() {
    let mut v = Vector::<String>::new();
    for k in 0..6 {
        let mut s = String::from_str("element ");
        s.push_str(k.fmt().as_str());
        s.push_str(" with a heap buffer");
        v.push(s);
    }
    {
        let mut m = md::MdSpanMut::<String, 2>::row_major(v.index_range_mut(0..6), [2, 3]).unwrap();
        m.set([1, 2], String::from_str("replaced with another heap buffer"));
        m.get_mut([0, 0]).push_str(", grown past its first capacity");
        let mut col = m.fix(1, 1);
        col.set([0], String::from_str("column write"));
    }
    assert_eq(v.at(5).as_str(), "replaced with another heap buffer");
    assert_eq(v.at(0).as_str(), "element 0 with a heap buffer, grown past its first capacity");
    assert_eq(v.at(1).as_str(), "column write");
    let r = md::MdSpan::<String, 2>::row_major(v[0..], [3, 2]).unwrap();
    assert_eq(r.get([2, 1]).as_str(), "replaced with another heap buffer");
}

@test
fn views_are_copy_send_and_sync() {
    let data = offsets(6);
    let v = md::MdSpan::<usize, 2>::row_major(data[0..], [2, 3]).unwrap();
    let w = v;
    assert_eq(*v.get([1, 2]), *w.get([1, 2]));
    need_send(&v);
    need_sync(&v);
    let it = v.iter();
    need_send(&it);
    need_sync(&it);
    let mut buf = offsets(6);
    let m = md::MdSpanMut::<usize, 2>::row_major(buf.index_range_mut(0..6), [2, 3]).unwrap();
    need_send(&m);
    need_sync(&m);
}

@test
fn format_nests_one_level_per_dimension() {
    let data = offsets(24);
    let a = md::MdSpan::<usize, 1>::row_major(data[0..], [3]).unwrap();
    assert_eq(a.fmt().as_str(), "[0, 1, 2]");
    let b = md::MdSpan::<usize, 3>::row_major(data[0..], [2, 2, 3]).unwrap();
    assert_eq(b.fmt().as_str(), "[[[0, 1, 2], [3, 4, 5]], [[6, 7, 8], [9, 10, 11]]]");
    let c = md::MdSpan::<usize, 2>::strided(data[0..], [2, 2], [10, 0]).unwrap();
    assert_eq(c.fmt().as_str(), "[[0, 0], [10, 10]]");
}

@test
fn zero_sized_elements() {
    let s = unsafe Slice::<Unit> { ptr: dangling::<Unit>(), len: 6 };
    let v = md::MdSpan::<Unit, 2>::row_major(s, [2, 3]).unwrap();
    let mut n: usize = 0;
    for _u in v.iter() {
        n += 1;
    }
    assert_eq(n, 6);
    assert_eq(v.fix(1, 2).size(), 2);
    let _u = v.get([1, 2]);
    assert(md::MdSpan::<Unit, 2>::row_major(s, [3, 3]).is_err());
}

@test(should_panic)
fn get_panics_out_of_bounds() {
    let data = offsets(6);
    let v = md::MdSpan::<usize, 2>::row_major(data[0..], [2, 3]).unwrap();
    let _x = v.get([0, 3]);
}

@test(should_panic)
fn extent_panics_past_the_rank() {
    let data = offsets(6);
    let v = md::MdSpan::<usize, 2>::row_major(data[0..], [2, 3]).unwrap();
    let _x = v.extent(2);
}

@test(should_panic)
fn slice_dim_panics_on_a_reversed_range() {
    let data = offsets(6);
    let v = md::MdSpan::<usize, 2>::row_major(data[0..], [2, 3]).unwrap();
    let _x = v.slice_dim(1, 2, 1);
}

@test(should_panic)
fn slice_dim_panics_past_the_extent() {
    let data = offsets(6);
    let v = md::MdSpan::<usize, 2>::row_major(data[0..], [2, 3]).unwrap();
    let _x = v.slice_dim(1, 0, 4);
}

@test(should_panic)
fn fix_panics_out_of_bounds() {
    let data = offsets(6);
    let v = md::MdSpan::<usize, 2>::row_major(data[0..], [2, 3]).unwrap();
    let _x = v.fix(0, 2);
}

@test(should_panic)
fn set_panics_out_of_bounds() {
    let mut buf = offsets(6);
    let mut m = md::MdSpanMut::<usize, 2>::row_major(buf.index_range_mut(0..6), [2, 3]).unwrap();
    m.set([2, 0], 1);
}
