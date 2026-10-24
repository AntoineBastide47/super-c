// std::mem::layout, std::mem::ptr and std::mem::endian: layout arithmetic against the C layout of real
// structs and at the overflow edges, allocator calls through a counting allocator, unaligned access and
// bulk copies at every offset, bit casts, and byte-order round trips of every scalar at both orders and
// every offset, with the short-buffer paths and a randomized comparison against shift-built references.

import std::mem::endian as endian;
import std::mem::layout as layout;
import std::mem::ptr as ptr;
import std::math::random as random;

const ISIZE_MAX: usize = isize::MAX as usize;
const BUF: usize = 24;

struct Counts {
    pub allocs: usize,
    pub frees: usize,
    pub live: usize,
}

// Forwards to `Global` and counts the calls and the live bytes through a pointer, so every copy of the
// handle counts into one place.
@derive(Copy)
struct Counting {
    pub c: *mut Counts,
}

extend Counting as Allocator {
    pub unsafe fn alloc(self: &mut Counting, size: usize, align: usize) *mut void {
        unsafe {
            (*self.c).allocs += 1;
            (*self.c).live += size;
        }
        let mut g = Global {};
        return unsafe g.alloc(size, align);
    }
    pub unsafe fn realloc(self: &mut Counting, p: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        unsafe {
            if p == null {
                (*self.c).allocs += 1;
            }
            (*self.c).live = (*self.c).live - old_size + new_size;
        }
        let mut g = Global {};
        return unsafe g.realloc(p, old_size, new_size, align);
    }
    pub unsafe fn dealloc(self: &mut Counting, p: *mut void, size: usize, align: usize) {
        unsafe {
            (*self.c).frees += 1;
            (*self.c).live -= size;
        }
        let mut g = Global {};
        unsafe g.dealloc(p, size, align);
    }
}

struct Mixed {
    pub a: u8,
    pub b: u32,
    pub c: u16,
    pub d: u64,
    pub e: u8,
}

@align(32)
struct Wide {
    pub x: u8,
}

// Element by element, through slice views (bounds-checked indexing).
fn expect_same<T: Eq>(got: []T, want: []T) {
    assert_eq(got.len(), want.len());
    for i in 0..got.len() {
        assert(got[i] == want[i], "element differs");
    }
}

// --- Layout ---------------------------------------------------------------------------------------

@test
fn layout_new_matches_sizeof_and_alignof() {
    let l = layout::Layout::new::<u64>();
    assert_eq(l.size(), 8);
    assert_eq(l.align(), 8);
    let m = layout::Layout::new::<Mixed>();
    assert_eq(m.size(), sizeof(Mixed));
    assert_eq(m.align(), alignof(Mixed));
    let w = layout::Layout::new::<Wide>();
    assert_eq(w.align(), 32);
    assert_eq(w.size(), 32);
    let z = layout::Layout::new::<Unit>();
    assert_eq(z.size(), 0);
    assert_eq(z.align(), 1);
}

@test
fn layout_from_size_align_checks_the_invariant() {
    assert(layout::Layout::from_size_align(0, 1).is_some(), "empty layout");
    assert(layout::Layout::from_size_align(5, 0).is_none(), "zero alignment");
    assert(layout::Layout::from_size_align(5, 3).is_none(), "alignment not a power of two");
    assert(layout::Layout::from_size_align(5, 6).is_none(), "alignment 6");
    let top = layout::Layout::from_size_align(ISIZE_MAX - 7, 8);
    assert(top.is_some(), "largest size for align 8");
    assert_eq(top.unwrap().size(), ISIZE_MAX - 7);
    assert(layout::Layout::from_size_align(ISIZE_MAX - 6, 8).is_none(), "rounds up past isize::MAX");
    assert(layout::Layout::from_size_align(ISIZE_MAX, 1).is_some(), "isize::MAX bytes at align 1");
    assert(layout::Layout::from_size_align(ISIZE_MAX + 1, 1).is_none(), "past isize::MAX");
    let huge_align = ISIZE_MAX + 1;
    assert(layout::Layout::from_size_align(0, huge_align).is_some(), "alignment 2^(N-1) with size 0");
    assert(layout::Layout::from_size_align(1, huge_align).is_none(), "alignment 2^(N-1) with size 1");
}

@test
fn layout_array_checks_overflow() {
    let a = layout::Layout::array::<u64>(3).unwrap();
    assert_eq(a.size(), 24);
    assert_eq(a.align(), 8);
    assert_eq(layout::Layout::array::<u64>(0).unwrap().size(), 0);
    let max_n = (ISIZE_MAX - 7) / 8;
    assert_eq(layout::Layout::array::<u64>(max_n).unwrap().size(), max_n * 8);
    assert(layout::Layout::array::<u64>(max_n + 1).is_none(), "one element past the limit");
    assert(layout::Layout::array::<u64>(~(0 as usize)).is_none(), "usize::MAX elements");
    assert(layout::Layout::array::<u8>(ISIZE_MAX).is_some(), "isize::MAX bytes");
    assert(layout::Layout::array::<u8>(ISIZE_MAX + 1).is_none(), "isize::MAX + 1 bytes");
    let z = layout::Layout::array::<Unit>(~(0 as usize)).unwrap();
    assert_eq(z.size(), 0);
}

@test
fn layout_followed_by_reproduces_the_c_struct_layout() {
    let info = type_info::<Mixed>();
    let (l1, ob) = layout::Layout::new::<u8>().followed_by(layout::Layout::new::<u32>()).unwrap();
    let (l2, oc) = l1.followed_by(layout::Layout::new::<u16>()).unwrap();
    let (l3, od) = l2.followed_by(layout::Layout::new::<u64>()).unwrap();
    let (l4, oe) = l3.followed_by(layout::Layout::new::<u8>()).unwrap();
    assert_eq(ob, info.field("b").unwrap().offset);
    assert_eq(oc, info.field("c").unwrap().offset);
    assert_eq(od, info.field("d").unwrap().offset);
    assert_eq(oe, info.field("e").unwrap().offset);
    assert_eq(l4.size(), oe + 1);
    let whole = l4.pad_to_align();
    assert_eq(whole.size(), sizeof(Mixed));
    assert_eq(whole.align(), alignof(Mixed));
}

@test
fn layout_followed_by_overflows_to_none() {
    let big = layout::Layout::from_size_align(ISIZE_MAX - 3, 1).unwrap();
    assert(big.followed_by(layout::Layout::new::<u8>()).is_some(), "one byte still fits");
    assert(big.followed_by(layout::Layout::new::<u64>()).is_none(), "the padding to 8 does not fit");
    let aligned = layout::Layout::from_size_align(ISIZE_MAX - 3, 4).unwrap();
    assert(aligned.followed_by(layout::Layout::new::<u8>()).is_none(), "the size no longer rounds up to 4");
    let full = layout::Layout::from_size_align(ISIZE_MAX, 1).unwrap();
    assert(full.followed_by(layout::Layout::new::<u8>()).is_none(), "one byte past isize::MAX");
    let empty = layout::Layout::new::<Unit>();
    let (l, off) = full.followed_by(empty).unwrap();
    assert_eq(off, ISIZE_MAX);
    assert_eq(l.size(), ISIZE_MAX);
}

@test
fn layout_padding_and_alignment() {
    let l = layout::Layout::from_size_align(5, 1).unwrap();
    assert_eq(l.padding_needed_for(8), 3);
    assert_eq(l.padding_needed_for(1), 0);
    assert_eq(layout::Layout::from_size_align(8, 8).unwrap().padding_needed_for(8), 0);
    let a = l.align_to(8).unwrap();
    assert_eq(a.align(), 8);
    assert_eq(a.size(), 5);
    assert_eq(a.pad_to_align().size(), 8);
    assert_eq(a.align_to(2).unwrap().align(), 8);
    assert(a.align_to(3).is_none(), "align_to a non-power of two");
    let top = layout::Layout::from_size_align(ISIZE_MAX - 1, 2).unwrap();
    assert(top.align_to(4).is_none(), "align_to past isize::MAX");
    assert_eq(layout::Layout::new::<Unit>().pad_to_align().size(), 0);
    let at_limit = layout::Layout::from_size_align(ISIZE_MAX - 7, 8).unwrap();
    assert_eq(at_limit.pad_to_align().size(), ISIZE_MAX - 7);
}

@test(should_panic)
fn layout_padding_rejects_a_non_power_of_two() {
    let _ = layout::Layout::new::<u32>().padding_needed_for(6);
}

@test
fn layout_eq_and_format() {
    let a = layout::Layout::new::<u32>();
    let b = layout::Layout::from_size_align(4, 4).unwrap();
    assert(a == b, "equal layouts");
    assert(a != layout::Layout::new::<u64>(), "different layouts");
    let s = a.fmt();
    assert(s.as_str() == "Layout { size: 4, align: 4 }", "derived format");
}

@test
fn align_helpers() {
    assert_eq(layout::align_up(0, 8), 0);
    assert_eq(layout::align_up(1, 8), 8);
    assert_eq(layout::align_up(8, 8), 8);
    assert_eq(layout::align_up(9, 8), 16);
    assert_eq(layout::align_up(~(0 as usize) - 7, 8), ~(0 as usize) - 7);
    assert_eq(layout::align_down(15, 8), 8);
    assert_eq(layout::align_down(16, 8), 16);
    assert_eq(layout::align_down(7, 1), 7);
    let words: [u64; 2] = [0, 0];
    let p = (&words[0]) as *const u64;
    assert(layout::is_aligned(p, 8), "a u64 is 8-aligned");
    let bp = unsafe (p as *const u8 + 1);
    assert(!layout::is_aligned(bp, 2), "odd address");
    assert(layout::is_aligned(bp, 1), "every address is 1-aligned");
}

@test(should_panic)
fn align_up_rejects_overflow() {
    let _ = layout::align_up(~(0 as usize) - 6, 8);
}

@test(should_panic)
fn align_up_rejects_a_non_power_of_two() {
    let _ = layout::align_up(5, 12);
}

@test(should_panic)
fn align_down_rejects_zero() {
    let _ = layout::align_down(5, 0);
}

@test
fn alloc_layout_uses_the_allocator_and_skips_zero_sizes() {
    let mut counts = Counts { allocs: 0, frees: 0, live: 0 };
    let mut a = Counting { c: &mut counts };
    let l = layout::Layout::new::<Wide>();
    let p = layout::alloc_layout(&mut a, l);
    assert(layout::is_aligned(p, 32), "over-aligned block");
    assert_eq(counts.allocs, 1);
    assert_eq(counts.live, 32);
    unsafe layout::dealloc_layout(&mut a, p, l);
    assert_eq(counts.frees, 1);
    assert_eq(counts.live, 0);
    let z = layout::Layout::from_size_align(0, 16).unwrap();
    let q = layout::alloc_layout(&mut a, z);
    assert_eq(q as usize, 16);
    unsafe layout::dealloc_layout(&mut a, q, z);
    assert_eq(counts.allocs, 1);
    assert_eq(counts.frees, 1);
}

// --- ptr ------------------------------------------------------------------------------------------

@test
fn unaligned_reads_and_writes_at_every_offset() {
    for off in 0..9 as usize {
        let mut buf: [u8; BUF] = [0xAA; BUF];
        let base = (&mut buf[0]) as *mut u8;
        unsafe ptr::write_unaligned::<u64>(base + off, 0x0102030405060708);
        unsafe ptr::write_unaligned::<u16>(base + off + 8, 0xBEEF);
        unsafe ptr::write_unaligned::<f32>(base + off + 10, -1.5);
        assert_eq(unsafe ptr::read_unaligned::<u64>(base + off), 0x0102030405060708u64);
        assert_eq(unsafe ptr::read_unaligned::<u16>(base + off + 8), 0xBEEFu16);
        assert_eq(unsafe ptr::read_unaligned::<f32>(base + off + 10), -1.5);
        assert_eq(unsafe ptr::read_unaligned::<u32>(base + off), 0x05060708u32);
        let view: []u8 = buf;
        for i in 0..off {
            assert_eq(view[i], 0xAAu8);
        }
        for i in off + 14..BUF {
            assert_eq(view[i], 0xAAu8);
        }
    }
}

@test
fn unaligned_write_and_read_move_an_owned_value() {
    let mut buf: [u8; 40] = [0; 40];
    let p = unsafe ((&mut buf[0]) as *mut u8 + 3);
    let s = String::from_str("a heap string longer than twenty-three bytes");
    unsafe ptr::write_unaligned::<String>(p, s);
    let back = unsafe ptr::read_unaligned::<String>(p);
    assert(back.as_str() == "a heap string longer than twenty-three bytes", "moved through the bytes");
}

@test
fn copy_handles_overlap_in_both_directions() {
    let mut a: [u32; 8] = [0, 1, 2, 3, 4, 5, 6, 7];
    let p = (&mut a[0]) as *mut u32;
    unsafe ptr::copy::<u32>(p, p + 2, 5);
    let fwd: [u32; 8] = [0, 1, 0, 1, 2, 3, 4, 7];
    expect_same::<u32>(a, fwd);
    let mut b: [u32; 8] = [0, 1, 2, 3, 4, 5, 6, 7];
    let q = (&mut b[0]) as *mut u32;
    unsafe ptr::copy::<u32>(q + 2, q, 5);
    let back: [u32; 8] = [2, 3, 4, 5, 6, 5, 6, 7];
    expect_same::<u32>(b, back);
}

@test
fn copy_nonoverlapping_and_write_bytes() {
    let src: [u16; 4] = [1, 2, 3, 0xFFFF];
    let mut dst: [u16; 6] = [9; 6];
    let d = (&mut dst[0]) as *mut u16;
    unsafe ptr::copy_nonoverlapping::<u16>(&src[0], d + 1, 4);
    let want: [u16; 6] = [9, 1, 2, 3, 0xFFFF, 9];
    expect_same::<u16>(dst, want);
    unsafe ptr::write_bytes::<u16>(d + 2, 0x01, 3);
    let filled: [u16; 6] = [9, 1, 0x0101, 0x0101, 0x0101, 9];
    expect_same::<u16>(dst, filled);
    unsafe ptr::copy_nonoverlapping::<u16>(&src[0], d, 0);
    assert_eq(dst[0], 9u16);
}

@test
fn swap_exchanges_and_handles_overlap() {
    let mut a = String::from_str("left side string, longer than the inline bytes");
    let mut b = String::from_str("right");
    unsafe ptr::swap::<String>(&mut a, &mut b);
    assert(a.as_str() == "right", "a holds b's value");
    assert(b.as_str() == "left side string, longer than the inline bytes", "b holds a's value");
    // Overlapping u32 views one byte apart: the overlap ends with the bytes that were at `x`.
    let mut buf: [u8; 5] = [1, 2, 3, 4, 5];
    let base = (&mut buf[0]) as *mut u8;
    unsafe ptr::swap::<[u8; 4]>(base as *mut [u8; 4], (base + 1) as *mut [u8; 4]);
    let want: [u8; 5] = [2, 1, 2, 3, 4];
    expect_same::<u8>(buf, want);
}

@test
fn swap_nonoverlapping_moves_owned_elements() {
    let mut x: [String; 3] = [String::from_str("a"), String::from_str("b"), String::from_str("c")];
    let mut y: [String; 3] = [
        String::from_str("one heap string past the inline size"),
        String::from_str("2"),
        String::from_str("3"),
    ];
    unsafe ptr::swap_nonoverlapping::<String>(&mut x[0], &mut y[0], 3);
    assert(x[0].as_str() == "one heap string past the inline size", "x[0]");
    assert(x[2].as_str() == "3", "x[2]");
    assert(y[0].as_str() == "a", "y[0]");
    assert(y[1].as_str() == "b", "y[1]");
    unsafe ptr::swap_nonoverlapping::<String>(&mut x[0], &mut y[0], 0);
    assert(x[1].as_str() == "2", "a zero count swaps nothing");
}

@test
fn offset_from_counts_elements() {
    let a: [u64; 6] = [0; 6];
    let p = (&a[0]) as *const u64;
    let q = unsafe (p + 5);
    assert_eq(unsafe ptr::offset_from::<u64>(q, p), 5);
    assert_eq(unsafe ptr::offset_from::<u64>(p, q), -5);
    assert_eq(unsafe ptr::offset_from::<u64>(p, p), 0);
}

const ONE_BITS: u32 = ptr::bit_cast::<u32, f32>(1.0);

@test
fn bit_cast_reinterprets_the_bits() {
    assert_eq(ONE_BITS, 0x3F800000u32);
    assert_eq(ptr::bit_cast::<u64, f64>(-2.0), 0xC000000000000000u64);
    assert_eq(ptr::bit_cast::<f32, u32>(0x40490FDB), 3.1415927);
    let bytes = ptr::bit_cast::<[u8; 4], u32>(0x0A0B0C0D);
    assert_eq(bytes[0], 0x0Du8);
    assert_eq(bytes[3], 0x0Au8);
    assert_eq(ptr::bit_cast::<u32, [u8; 4]>(bytes), 0x0A0B0C0Du32);
    assert_eq(ptr::bit_cast::<i32, u32>(0xFFFFFFFF), -1);
    // A signaling NaN keeps its payload in both directions.
    let snan = ptr::bit_cast::<f64, u64>(0x7FF0000000000123);
    assert_eq(ptr::bit_cast::<u64, f64>(snan), 0x7FF0000000000123u64);
}

// --- endian ---------------------------------------------------------------------------------------

// Write `v` at every offset of a 24-byte buffer in both orders, check the bytes against `bytes_le` (the
// little-endian bytes, computed by shifts), check that nothing outside the value changed, and read it
// back with every reader.
fn round_trip<T: endian::EndianScalar + Eq + Format>(v: T, bytes_le: []u8) {
    let n = sizeof(T);
    assert_eq(bytes_le.len(), n);
    for off in 0..BUF - n + 1 {
        let mut le: [u8; BUF] = [0x5A; BUF];
        let mut be: [u8; BUF] = [0x5A; BUF];
        endian::write_le::<T>(le, off, v);
        endian::write_be::<T>(be, off, v);
        let lv: []u8 = le;
        let bv: []u8 = be;
        for i in 0..BUF {
            if i < off || i >= off + n {
                assert_eq(lv[i], 0x5Au8);
                assert_eq(bv[i], 0x5Au8);
            } else {
                assert_eq(lv[i], bytes_le[i - off]);
                assert_eq(bv[i], bytes_le[n - 1 - (i - off)]);
            }
        }
        // `eq`, not `==`: a float's `Eq` compares bits, so a NaN equals itself.
        assert(endian::read_le::<T>(le, off).eq(&v), "read_le after write_le");
        assert(endian::read_be::<T>(be, off).eq(&v), "read_be after write_be");
        assert(endian::try_read_le::<T>(le, off).unwrap().eq(&v), "try_read_le after write_le");
        assert(endian::try_read_be::<T>(be, off).unwrap().eq(&v), "try_read_be after write_be");
    }
    let mut v_le = Vector::<u8>::new();
    let mut v_be = Vector::<u8>::new();
    v_le.push(7);
    v_be.push(7);
    endian::append_le::<T, Global>(&mut v_le, v);
    endian::append_be::<T, Global>(&mut v_be, v);
    assert_eq(v_le.len(), n + 1);
    assert_eq(v_be.len(), n + 1);
    for i in 0..n {
        assert_eq(*v_le.at(i + 1), bytes_le[i]);
        assert_eq(*v_be.at(i + 1), bytes_le[n - 1 - i]);
    }
    assert(endian::read_le::<T>(v_le[0..v_le.len()], 1).eq(&v), "read_le of append_le");
    assert(endian::read_be::<T>(v_be[0..v_be.len()], 1).eq(&v), "read_be of append_be");
}

// The `n` little-endian bytes of `bits`.
fn le_bytes(bits: u64, n: usize) Vector<u8> {
    let mut out = Vector::<u8>::new();
    for i in 0..n {
        out.push((bits >> (8 * i) as u64) as u8);
    }
    return out;
}

@test
fn endian_round_trips_every_unsigned_type() {
    round_trip::<u8>(0xA5, le_bytes(0xA5, 1)[0..1]);
    round_trip::<u16>(0xA1B2, le_bytes(0xA1B2, 2)[0..2]);
    round_trip::<u32>(0xA1B2C3D4, le_bytes(0xA1B2C3D4, 4)[0..4]);
    round_trip::<u64>(0xA1B2C3D4E5F60718, le_bytes(0xA1B2C3D4E5F60718, 8)[0..8]);
    let w = POINTER_WIDTH as usize / 8;
    let u = 0xA1B2C3D4 as usize;
    round_trip::<usize>(u, le_bytes(u as u64, w)[0..w]);
}

@test
fn endian_round_trips_every_signed_type() {
    round_trip::<i8>(-91, le_bytes(0xA5, 1)[0..1]);
    round_trip::<i16>(-24142, le_bytes(0xA1B2, 2)[0..2]);
    round_trip::<i32>(-1, le_bytes(0xFFFFFFFF, 4)[0..4]);
    round_trip::<i64>(-6795153568590067944, le_bytes(0xA1B2C3D4E5F60718, 8)[0..8]);
    let w = POINTER_WIDTH as usize / 8;
    round_trip::<isize>(-2, le_bytes(~(1 as u64), w)[0..w]);
}

@test
fn endian_round_trips_floats_with_their_bits() {
    round_trip::<f32>(-1.5, le_bytes(0xBFC00000, 4)[0..4]);
    round_trip::<f64>(6.02214076e23, le_bytes(ptr::bit_cast::<u64, f64>(6.02214076e23), 8)[0..8]);
    // A NaN keeps its payload; `Eq` compares floats by bits.
    let qnan = ptr::bit_cast::<f32, u32>(0x7FC00001);
    round_trip::<f32>(qnan, le_bytes(0x7FC00001, 4)[0..4]);
    let snan = ptr::bit_cast::<f64, u64>(0x7FF0000000000001);
    round_trip::<f64>(snan, le_bytes(0x7FF0000000000001, 8)[0..8]);
    // The foreign-order bytes of this value load as the signaling NaN 0x7FF0000000000001 before the swap.
    let swaps_to_snan = ptr::bit_cast::<f64, u64>(0x010000000000F07F);
    round_trip::<f64>(swaps_to_snan, le_bytes(0x010000000000F07F, 8)[0..8]);
    let b: [u8; 4] = [0x01, 0x00, 0x80, 0x7F];
    assert_eq(ptr::bit_cast::<u32, f32>(endian::read_le::<f32>(b, 0)), 0x7F800001u32);
    assert_eq(ptr::bit_cast::<u32, f32>(endian::read_be::<f32>(b, 0)), 0x0100807Fu32);
}

@test
fn endian_checked_reads_reject_short_input() {
    let b: [u8; 5] = [1, 2, 3, 4, 5];
    assert(endian::try_read_le::<u32>(b, 1).is_some(), "the last full u32");
    assert(endian::try_read_le::<u32>(b, 2).is_none(), "one byte short");
    assert(endian::try_read_be::<u64>(b, 0).is_none(), "u64 in five bytes");
    assert(endian::try_read_be::<u8>(b, 5).is_none(), "offset at the end");
    assert(endian::try_read_le::<u16>(b, ~(0 as usize)).is_none(), "usize::MAX offset");
    assert(endian::try_read_le::<u16>(b, ~(0 as usize) - 1).is_none(), "offset that wraps with the size");
    let empty: [u8; 0] = [];
    assert(endian::try_read_le::<u8>(empty, 0).is_none(), "empty slice");
    assert_eq(endian::try_read_be::<u16>(b, 3).unwrap(), 0x0405u16);
}

@test(should_panic)
fn endian_read_le_panics_past_the_end() {
    let b: [u8; 3] = [1, 2, 3];
    let _ = endian::read_le::<u32>(b, 0);
}

@test(should_panic)
fn endian_read_be_panics_at_a_wrapping_offset() {
    let b: [u8; 8] = [0; 8];
    let _ = endian::read_be::<u16>(b, ~(0 as usize));
}

@test(should_panic)
fn endian_write_le_panics_past_the_end() {
    let mut b: [u8; 4] = [0; 4];
    endian::write_le::<u32>(b, 1, 7);
}

@test(should_panic)
fn endian_write_be_panics_past_the_end() {
    let mut b: [u8; 8] = [0; 8];
    endian::write_be::<f64>(b, 1, 1.0);
}

@test
fn endian_append_grows_through_the_vector_allocator() {
    let mut counts = Counts { allocs: 0, frees: 0, live: 0 };
    {
        let mut v = Vector::<u8, Counting>::new_in(Counting { c: &mut counts });
        for i in 0..100u32 {
            endian::append_be::<u32, Counting>(&mut v, i);
            endian::append_le::<u16, Counting>(&mut v, i as u16);
        }
        assert_eq(v.len(), 600);
        assert_eq(endian::read_be::<u32>(v[0..600], 594), 99u32);
        assert_eq(endian::read_le::<u16>(v[0..600], 598), 99u16);
    }
    assert(counts.allocs >= 1, "the vector allocated through its allocator");
    assert_eq(counts.live, 0);
}

// Random buffers, offsets and widths: each reader against a value assembled byte by byte with shifts.
@test
fn endian_reads_match_shift_references() {
    let mut rng = random::Pcg32::new(20261023, 11);
    let mut buf = Vector::<u8>::new();
    buf.resize_default(64);
    for _ in 0..2000 {
        for i in 0..64 as usize {
            buf[i] = rng.next_u32() as u8;
        }
        let width = 1 as usize << (rng.next_u32() % 4) as usize;
        let off = rng.next_u32() as usize % (64 - width + 1);
        let mut want_le: u64 = 0;
        let mut want_be: u64 = 0;
        for i in 0..width {
            want_le = want_le | buf[off + i] as u64 << (8 * i) as u64;
            want_be = want_be << 8 | buf[off + i] as u64;
        }
        let b = buf[0..64];
        let (got_le, got_be) = switch width {
            1 => (endian::read_le::<u8>(b, off) as u64, endian::read_be::<u8>(b, off) as u64),
            2 => (endian::read_le::<u16>(b, off) as u64, endian::read_be::<u16>(b, off) as u64),
            4 => (endian::read_le::<u32>(b, off) as u64, endian::read_be::<u32>(b, off) as u64),
            _ => (endian::read_le::<u64>(b, off), endian::read_be::<u64>(b, off)),
        };
        assert_eq(got_le, want_le);
        assert_eq(got_be, want_be);
    }
}
