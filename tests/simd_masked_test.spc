// Masked and partial memory (std/simd.spc): an inactive lane never touches its element (a guard page
// past the slice shows it), every active lane is checked before the first access and the lowest
// failing one traps, repeated scatter indexes keep lane order, `compress_store` writes exactly its
// count, a store borrows its slice mutably, and two threads storing to disjoint lanes of one slice do
// not race. Each runs as a constant too, the trap text included.
import tests::harness as h;
import tests::cli_harness as cli;

// The page-mapping calls of the host, as a program prelude: `guarded(n)` gives `n` elements of `i32`
// whose last ends at a page closed to every access.
fn guard_prelude() str<'static> {
    if cli::on_windows() {
        return M"(extern "C" "windows.h" {
    fn VirtualAlloc(addr: *mut void, size: usize, kind: u32, prot: u32) *mut void;
    fn VirtualProtect(addr: *mut void, size: usize, prot: u32, old: *mut void) i32;
    const MEM_COMMIT: u32;
    const MEM_RESERVE: u32;
    const PAGE_READWRITE: u32;
    const PAGE_NOACCESS: u32;
}
fn guarded(n: usize) SliceMut<'static, i32> {
    let base = unsafe VirtualAlloc(null, 131072, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) as *mut u8;
    let mut old: u64 = 0; // a DWORD, written through `void *`
    if base == null || unsafe VirtualProtect(base + 65536, 65536, PAGE_NOACCESS, (&mut old) as *mut u64 as *mut void) == 0 {
        return guarded(0);
    }
    return SliceMut::<i32> { ptr: unsafe (base + 65536 - n * 4) as *mut i32, len: n };
}
)";
    }
    // Two pages from the runtime's stack mapper, the upper one then closed (mprotect is POSIX; an
    // anonymous mmap is not).
    return M"(import sc_runtime;
extern "C" "sys/mman.h" {
    fn mprotect(addr: *mut void, len: usize, prot: i32) i32;
    const PROT_NONE: i32;
}
fn guarded(n: usize) SliceMut<'static, i32> {
    let pg = unsafe sc_runtime::sc_rt_page_size();
    let base = unsafe sc_runtime::sc_rt_stack_alloc(2 * pg) as *mut u8;
    if base == null || unsafe mprotect(base + pg, pg, PROT_NONE) != 0 {
        return guarded(0);
    }
    return SliceMut::<i32> { ptr: unsafe (base + pg - n * 4) as *mut i32, len: n };
}
)";
}

// Thirteen elements end at a page with no access: every form whose inactive lanes cover that page
// runs without a fault, and the active lanes read and write their elements. No lane skips it: the
// wasm lane builds the program natively (only its transpile step runs in the wasm compiler).
@test
fn inactive_lanes_never_touch_a_guard_page() {
    let mut src = String::from_str("import std::simd;\n");
    src.push_str(guard_prelude());
    src.push_str(
        M"(fn main() i32 {
    let s = guarded(13);
    for i in 0..13usize {
        s[i] = i as i32;
    }
    let fb = Simd::<i32, 8>::splat(-1);
    let lo = Mask::<8>::from_bits_truncate(0x0F);
    let a = simd::load_or(s, 9, fb);
    let b = simd::load_masked(s, 9, lo, fb);
    simd::store_masked(s, 9, lo, b + b);
    let ix = Simd::<u64, 8>::from_array([12, 0, 3, 1, 16384, 16385, 20000, 13]);
    let g = simd::gather(s, ix, lo, fb);
    simd::scatter(s, ix, lo, g + Simd::<i32, 8>::splat(100));
    let n = simd::compress_store(s, 10, Mask::<8>::from_bits_truncate(0x83), fb);
    let p = unsafe simd::load_masked_ptr(&s[9], lo, fb);
    unsafe simd::store_masked_ptr(&mut s[9], lo, p);
    let e = &s[12] as *const i32;
    let ptrs: [*const i32; 4] = [e, &s[11], unsafe (e + 1), unsafe (e + 4)];
    let q = unsafe simd::gather_ptr(ptrs, Mask::<4>::from_bits_truncate(3), Simd::<i32, 4>::splat(-2));
    let f = &mut s[12] as *mut i32;
    let w: [*mut i32; 4] = [&mut s[0], unsafe (f + 1), &mut s[1], unsafe (f + 9)];
    unsafe simd::scatter_ptr(w, Mask::<4>::from_bits_truncate(5), q);
    if a[3] != 12 || a[4] != -1 || b[0] != 9 || b[7] != -1 || g[0] != 24 || g[4] != -1 || n != 3 || p[0] != 18 || q[2] != -2 {
        return 1;
    }
    if s[0] != -1 || s[1] != -2 || s[3] != 103 || s[10] != -1 || s[12] != -1 {
        return 2;
    }
    return 0;
}
)",
    );
    h::expect_run("guard page", src.as_str(), "", "");
}

// A store whose active lanes include one out of bounds traps before any write: the SIGABRT handler
// finds the slice unchanged. Repeated scatter indexes write in lane order, so the highest active lane
// wins, and `compress_store` writes its count and nothing past it.
@test
fn stores_check_every_lane_first_and_keep_lane_order() {
    let src = M"(import std::simd;
import signal;
import stdlib;
static mut A: [i32; 6] = [1, 2, 3, 4, 5, 6];
fn unchanged(_sig: i32) {
    for i in 0..6usize {
        if unsafe A[i] != i as i32 + 1 {
            unsafe stdlib::exit_now(1);
        }
    }
    unsafe stdlib::exit_now(0);
}
fn main(args: Vector<str>) i32 {
    let mode = args.at(1).parse_u64().unwrap();
    let s = SliceMut::<i32> { ptr: &mut unsafe A[0], len: 6 };
    let v = simd::iota::<i32, 4>() + Simd::<i32, 4>::splat(10);
    if mode == 2 {
        // Every lane at index 3: the last active lane's value lands.
        simd::scatter(s, Simd::<u32, 4>::splat(3), Mask::<4>::splat(true), v);
        simd::scatter(s, Simd::<u32, 4>::splat(4), Mask::<4>::from_bits_truncate(0b0111), v);
        let mut b = [7, 7, 7, 7, 7, 7];
        let n = simd::compress_store(b, 1, Mask::<4>::from_bits_truncate(0b1010), v);
        return pick3(s[3] == 13 && s[4] == 12 && n == 2 && b[0] == 7 && b[1] == 11 && b[2] == 13 && b[3] == 7);
    }
    let _ = unsafe signal::signal(signal::SIGABRT, unchanged);
    if mode == 0 {
        simd::store_masked(s, 3, Mask::<4>::from_bits_truncate(0b1001), v);
    } else {
        simd::scatter(s, Simd::<u64, 4>::from_array([0, 1, 6, 2]), Mask::<4>::splat(true), v);
    }
    return 3;
}
fn pick3(ok: bool) i32 {
    if ok {
        return 0;
    }
    return 4;
}
)";
    let b = h::diff_build(src, []);
    assert(b.built, b.diag.as_str());
    for mode in ["0", "1", "2"] {
        let r = h::diff_run(&b, mode);
        if r.exit != 0 {
            eprintln("mode {}: exit {}: {}", mode, r.exit, r.err.as_str());
        }
        assert(r.exit == 0, "unchanged before the trap, lane order, and the exact count");
    }
}

// The trap names the lowest failing active lane and its index, at run time and as a constant; an
// inactive lane past the slice and a start past it with no active lane do not trap.
@test
fn masked_traps_name_the_lowest_active_lane() {
    let decls = M"(import std::simd;
const fn ld(start: usize, m: u64) i32 {
    let a = [1, 2, 3, 4, 5, 6];
    let v = simd::load_masked(a, start, Mask::<4>::from_bits_truncate(m), Simd::<i32, 4>::splat(0));
    return v[0] + v[3];
}
const fn st(start: usize, m: u64) i32 {
    let mut a = [1, 2, 3, 4, 5, 6];
    simd::store_masked(a, start, Mask::<4>::from_bits_truncate(m), Simd::<i32, 4>::splat(9));
    return a[5];
}
const fn ga(i: u32, m: u64) i32 {
    let a = [1, 2, 3, 4, 5, 6];
    let v = simd::gather(a, Simd::<u32, 4>::from_array([5, i, 0, i + 1]), Mask::<4>::from_bits_truncate(m), Simd::<i32, 4>::splat(0));
    return v[1];
}
const fn sc(i: u64, m: u64) i32 {
    let mut a = [1, 2, 3, 4, 5, 6];
    simd::scatter(a, Simd::<u64, 4>::from_array([5, i, 0, i]), Mask::<4>::from_bits_truncate(m), Simd::<i32, 4>::splat(9));
    return a[0];
}
const fn cs(start: usize, m: u64) usize {
    let mut a = [1, 2, 3, 4, 5, 6];
    return simd::compress_store(a, start, Mask::<4>::from_bits_truncate(m), Simd::<i32, 4>::splat(9));
}
const fn raw(m: u64) i32 {
    let mut a = [1, 2, 3, 4, 5, 6];
    let k = Mask::<4>::from_bits_truncate(m);
    let v = unsafe simd::load_masked_ptr(&a[1], k, Simd::<i32, 4>::splat(-1));
    unsafe simd::store_masked_ptr(&mut a[2], k, v + v);
    let p: [*const i32; 4] = [&a[5], &a[0], &a[3], &a[0]];
    let g = unsafe simd::gather_ptr(p, k, v);
    let q: [*mut i32; 4] = [&mut a[1], &mut a[1], &mut a[0], &mut a[4]];
    unsafe simd::scatter_ptr(q, k, g);
    return a[0] * 100000 + a[1] * 10000 + a[2] * 1000 + a[4] * 10 + a[5];
}
)";
    let exprs: [str; 16] = [
        "raw(opq::<u64>(0xF))",
        "raw(opq::<u64>(0x6))",
        "ld(opq::<usize>(2), opq::<u64>(0xF))",
        "ld(opq::<usize>(3), opq::<u64>(0xF))",
        "ld(opq::<usize>(3), opq::<u64>(0x7))",
        "ld(opq::<usize>(18446744073709551615), opq::<u64>(0x4))",
        "ld(opq::<usize>(18446744073709551615), opq::<u64>(0))",
        "st(opq::<usize>(5), opq::<u64>(0x3))",
        "st(opq::<usize>(5), opq::<u64>(0x1))",
        "ga(opq::<u32>(4), opq::<u64>(0xF))",
        "ga(opq::<u32>(5), opq::<u64>(0xF))",
        "ga(opq::<u32>(4294967295), opq::<u64>(0x5))",
        "sc(opq::<u64>(6), opq::<u64>(0xA))",
        "sc(opq::<u64>(18446744073709551615), opq::<u64>(0x5))",
        "cs(opq::<usize>(4), opq::<u64>(0x3))",
        "cs(opq::<usize>(4), opq::<u64>(0xB))",
    ];
    let mut tys: [str; 16] = ["i32"; 16];
    tys[14] = "usize";
    tys[15] = "usize";
    let d = h::const_runtime_parity(decls, exprs, tys, ["--profile=ubsan"]);
    if d.len() != 0 {
        eprintln("{}", d.as_str());
    }
    assert(d.len() == 0, "masked memory as constants");
    let src = M"(import std::simd;
fn main(args: Vector<str>) i32 {
    let a = [1, 2, 3, 4, 5, 6];
    let k = args.at(1).parse_u64().unwrap();
    let ix = Simd::<u64, 4>::from_array([5, k, 0, k + 1]);
    let v = simd::gather(a, ix, Mask::<4>::splat(true), Simd::<i32, 4>::splat(0));
    let w = simd::load_masked(a, k as usize, Mask::<4>::from_bits_truncate(0b1110), v);
    return w[1] - w[1];
}
)";
    h::expect_run(
        "an index past the slice",
        src,
        "6",
        "lane 1: index out of bounds: the index is 6 but the length is 6",
    );
    h::expect_run("the lowest of two", src, "5", "lane 3: index out of bounds: the index is 6 but the length is 6");
    h::expect_run("a start past", src, "3", "lane 3: index out of bounds: the index is 3 + 3 but the length is 6");
}

// A masked store needs its slice mutably borrowed: a live shared borrow conflicts, as for `store`.
@test
fn masked_stores_borrow_their_slice() {
    let pre = "import std::simd;\nfn main() i32 {\n    let mut a = [1, 2, 3, 4];\n    let r = &a[0];\n    ";
    let calls: [str; 3] = [
        "simd::store_masked(a, 0, Mask::<4>::splat(true), Simd::<i32, 4>::splat(0));",
        "simd::scatter(a, Simd::<u32, 4>::splat(0), Mask::<4>::splat(true), Simd::<i32, 4>::splat(0));",
        "let _ = simd::compress_store(a, 0, Mask::<4>::splat(true), Simd::<i32, 4>::splat(0));",
    ];
    for c in calls {
        let mut src = String::from_str(pre);
        src.format_into("{}\n    return *r;\n}}\n", c);
        h::expect_build_err(c, src.as_str(), "borrow");
    }
}

// Two threads store to the two halves of one slice through masked stores and scatters whose inactive
// lanes cover the other half: no lane outside its mask is written, so the race profile reports nothing.
@test
fn disjoint_masked_stores_do_not_race() {
    let src = M"(import std::simd;
import std::parallel::thread as thread;
static mut A: [i32; 8] = [0; 8];
fn half(hi: bool) {
    let s = SliceMut::<i32> { ptr: &mut unsafe A[0], len: 8 };
    let m = Mask::<8>::from_bits_truncate(if hi {
        0xF0u64;
    } else {
        0x0Fu64;
    });
    for r in 0..200 {
        let v = Simd::<i32, 8>::splat(r);
        simd::store_masked(s, 0, m, v);
        simd::scatter(s, simd::iota::<u32, 8>(), m, v + v);
    }
}
fn main() i32 {
    let t = thread::spawn(fn() {
        half(true);
    });
    half(false);
    t.join();
    return unsafe A[0] + unsafe A[7] - 796;
}
)";
    let b = h::diff_build(src, ["--profile=race"]);
    assert(b.built, b.diag.as_str());
    let r = h::diff_run(&b, "");
    if r.exit != 0 || r.err.contains("ThreadSanitizer") {
        eprintln("exit {}: {}", r.exit, r.err.as_str());
    }
    assert(r.exit == 0 && !r.err.contains("ThreadSanitizer"), "no race between disjoint masked stores");
}

// Every rearranging, reducing and memory form over integer and float lanes, emitted and compiled with
// -Wall -Wextra -Werror, then run.
@test
fn every_form_compiles_under_strict_warnings() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::simd;
fn ints<T: SimdInt, const N: usize>(v: Simd<T, N>) u64 {
    let ix = simd::iota::<u32, N>();
    let (z, o) = simd::swizzle_checked(v, ix + ix);
    let (a, b) = simd::zip(v, simd::reverse(v));
    let (c, d) = simd::unzip(a, b);
    let m = v.greater_than(z);
    let e = simd::compress(m, c, d) + simd::expand(m, simd::rotate_lanes_left::<1>(v), simd::rotate_lanes_right::<1>(v));
    let mut h = simd::reduce_add(e) as u64 ^ simd::reduce_mul(e) as u64 ^ simd::reduce_min(e) as u64 ^ simd::reduce_max(e) as u64;
    h = h ^ simd::reduce_and(e) as u64 ^ simd::reduce_or(e) as u64 ^ simd::reduce_xor(e) as u64 ^ simd::arg_min(e) as u64 ^ simd::arg_max(e) as u64;
    h = h ^ simd::reduce_add_checked(e).is_some() as u64 ^ simd::reduce_mul_checked(e).is_some() as u64 ^ o.to_bits();
    return h ^ simd::dot::<i64>(e, v) as u64 ^ simd::swizzle(e, [1, 0])[0] as u64 ^ simd::shuffle(e, v, [0, N, 1, N + 1])[3] as u64;
}
fn flts<T: SimdFloat, const N: usize>(v: Simd<T, N>) f64 {
    let a = simd::reduce_add_ordered(v) as f64 + simd::reduce_mul_ordered(v) as f64 + simd::reduce_add_tree(v) as f64;
    let b = simd::reduce_mul_tree(v) as f64 + simd::reduce_min_num(v) as f64 + simd::reduce_max_num(v) as f64;
    let c = simd::reduce_minimum(v) as f64 + simd::reduce_maximum(v) as f64 + simd::dot::<f64>(v, v);
    return a + b + c + simd::arg_min_num(v).unwrap_or(9) as f64 + simd::arg_max_num(v).unwrap_or(9) as f64;
}
fn mem<T: SimdElement, const N: usize>(s: []mut T, fb: Simd<T, N>) usize {
    let m = Mask::<N>::from_bits_truncate(0x5555555555555555);
    let x = simd::load_or(s, 1, fb);
    let y = simd::load_masked(s, 0, m, x);
    simd::store_masked(s, 0, m, y);
    let ix = simd::iota::<u32, N>();
    simd::scatter(s, ix, m, simd::gather(s, ix, m, fb));
    let p = unsafe simd::load_masked_ptr(&s[0], m, fb);
    unsafe simd::store_masked_ptr(&mut s[0], m, p);
    let r = &s[1] as *const T;
    let w = &mut s[2] as *mut T;
    let q = unsafe simd::gather_ptr([r; N], m, p);
    unsafe simd::scatter_ptr([w; N], m, q);
    return simd::compress_store(s, 1, m, q);
}
fn main(args: Vector<str>) i32 {
    let k = args.len() as i32;
    let h = ints(Simd::<i8, 16>::splat(k as i8) + simd::iota::<i8, 16>()) ^ ints(Simd::<u64, 4>::splat(k as u64));
    let f = flts(Simd::<f32, 8>::splat(k as f32 / 3.0)) + flts(simd::iota::<f64, 2>());
    let mut a = [1i32, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17];
    let mut b = [1.5f64, 2.5, 3.5, 4.5, 5.5];
    let n = mem(a, Simd::<i32, 16>::splat(-1)) + mem(b, Simd::<f64, 4>::splat(-1.0));
    println("{} {} {}", h != 0, f > 0.0, n);
    return 0;
}
)",
    );
    assert(p.compile("main.spc").ok(), "transpiles");
    assert(p.cc_build("").ok(), "the C compiles with -Wall -Wextra -Werror");
    let r = p.run_bin_env("");
    assert(r.exit == 0 && r.out_shows("true true 10\n"), "runs");
}
