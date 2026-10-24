// The native backend: LIR text compiles to an object, which links with a C driver and runs.
import lir::ir as *;
import lir::parse as lparse;
import target::native as nat;
import target::table as tgt;
import tests::cli_harness as cli;
import std::platform::fs;
import std::platform::process;
import stdio;
import stdlib;

// Compile LIR `text` natively, link it with C `driver` and run it; the exit code, or -1 when a step
// failed (the failure on stderr). 0 on a host without a native backend.
fn run_native(text: str, driver: str) i32 {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return 0;
    }
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    if q.is_none() {
        eprint("parse: {}\n", err.as_str());
        return -1;
    }
    let p = q.unwrap();
    let mut fs_ = Vector::<u32>::new();
    let mut ds = Vector::<u32>::new();
    for i in 0..p.syms.len() {
        let s = p.syms[i];
        if s.def != NONE {
            if s.kind == SK_FUNC {
                fs_.push(i as u32);
            } else {
                ds.push(i as u32);
            }
        }
    }
    let mut obj = Vector::<u8>::new();
    if !nat::object(&p, tgt::host_os(), tgt::host_isa(), fs_[0..fs_.len()], ds[0..ds.len()], &mut obj, &mut err) {
        eprint("native: {}\n", err.as_str());
        return -1;
    }
    let dir = format("{}/native_{}", cli::tmp_dir().as_str(), process::pid().unwrap_or(1));
    let _ = fs::mkdir_all(dir.as_str());
    let op = format("{}/lir.o", dir.as_str());
    let cp = format("{}/main.c", dir.as_str());
    let bp = format("{}/prog", dir.as_str());
    let f = stdio::fopen(op.as_str(), "wb");
    unsafe stdio::fwrite(obj.as_ptr(), 1, obj.len(), f);
    unsafe stdio::fclose(f);
    let g = stdio::fopen(cp.as_str(), "wb");
    unsafe stdio::fwrite(driver.ptr(), 1, driver.len(), g);
    unsafe stdio::fclose(g);
    let mut cmd = format("cc -o \"{}\" \"{}\" \"{}\"", bp.as_str(), cp.as_str(), op.as_str());
    if cli::run_with(cmd.cstr(), null, null, null, "") != 0 {
        return -1;
    }
    let mut run = format("\"{}\"", bp.as_str());
    let rc = cli::run_with(run.cstr(), null, null, null, "");
    // SC_NATIVE_KEEP keeps the object and the program for a look.
    if stdlib::getenv("SC_NATIVE_KEEP") == null {
        let _ = fs::remove_all(dir.as_str());
    } else {
        eprint("native: kept {}\n", dir.as_str());
    }
    return rc;
}

@test
fn arithmetic_and_a_loop_run() {
    let lir = "lir ptr 8\nsym @sum_to fn global\nsym @mid fn global\nfn @sum_to\n  sig (i32) -> i64\nb0(v0: i32):\n  v1 = iconst.i64 0\n  v2 = iconst.i32 0\n  v3 = iconst.i32 1\n  jmp b1(v2, v1)\nb1(v4: i32, v5: i64):\n  v6 = icmp.ult v4, v0\n  br v6, b3, b2\nb2:\n  ret v5\nb3:\n  v7 = zext.i64 v4\n  v8 = add.i64 v5, v7\n  v9 = add.i32 v4, v3\n  jmp b1(v9, v8)\nfn @mid\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2, v3 = addo.s.i64 v0, v1\n  br v3, b2, b1\nb1:\n  v4 = iconst.i64 2\n  v5 = sdiv.i64 v2, v4\n  ret v5\nb2:\n  v6 = iconst.i64 -1\n  ret v6\n";
    let drv = "#include <stdint.h>\nint64_t sum_to(int32_t);\nint64_t mid(int64_t, int64_t);\nint main(void) {\n  if (sum_to(10) != 45) return 1;\n  if (mid(10, 31) != 20) return 2;\n  if (mid(INT64_MAX, 1) != -1) return 3;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

@test
fn wide_integers_run() {
    let lir = "lir ptr 8\nsym @div fn global\nsym @mul fn global\nsym @shr fn global\nfn @div\n  sig (i64, i64, i64, ptr) -> i64\nb0(v0: i64, v1: i64, v2: i64, v3: ptr):\n  v4 = zext.i128 v0\n  v5 = wconst.i128 0x40, 0x0\n  v6 = shl.i128 v4, v5\n  v7 = zext.i128 v1\n  v8 = or.i128 v6, v7\n  v9 = zext.i128 v2\n  v10 = urem.i128 v8, v9\n  v11 = trunc.i64 v10\n  store v11, v3 align 3\n  v12 = udiv.i128 v8, v9\n  v13 = trunc.i64 v12\n  ret v13\nfn @mul\n  sig (i64, i64, ptr) -> i64\nb0(v0: i64, v1: i64, v2: ptr):\n  v3 = zext.i128 v0\n  v4 = zext.i128 v1\n  v5 = mul.i128 v3, v4\n  v6 = wconst.i128 0x40, 0x0\n  v7 = lshr.i128 v5, v6\n  v8 = trunc.i64 v7\n  store v8, v2 align 3\n  v9 = trunc.i64 v5\n  ret v9\nfn @shr\n  sig (i64, i64, i32) -> i64\nb0(v0: i64, v1: i64, v2: i32):\n  v3 = sext.i128 v1\n  v4 = wconst.i128 0x40, 0x0\n  v5 = shl.i128 v3, v4\n  v6 = zext.i128 v0\n  v7 = or.i128 v5, v6\n  v8 = zext.i128 v2\n  v9 = ashr.i128 v7, v8\n  v10 = trunc.i64 v9\n  ret v10\n";
    let drv = "#include <stdint.h>\nint64_t div(int64_t, int64_t, int64_t, int64_t *);\nint64_t mul(int64_t, int64_t, int64_t *);\nint64_t shr(int64_t, int64_t, int32_t);\nint main(void) {\n  int64_t r = 0;\n  if (div(3, 5, 7, &r) != (int64_t)(((unsigned __int128)3 << 64 | 5) / 7) || r != (int64_t)(((unsigned __int128)3 << 64 | 5) % 7)) return 1;\n  int64_t h = 0;\n  if (mul(-1, -1, &h) != 1 || h != -2) return 2;\n  if (shr(0, -2, 65) != -1 || shr(0, 4, 1) != 0 || shr(0, 4, 64) != 4 || shr(8, 0, 3) != 1) return 3;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// A loop header's parameter keeps its home past its last use to the back edge, which writes it again;
// here its last use is the checked increment in the back edge's own block.
@test
fn loop_parameters_keep_their_homes() {
    let lir = "lir ptr 8\nsym @id fn global\nsym @f fn global\nfn @f\n  sig (ptr, i64) -> i64\nb0(v0: ptr, v1: i64):\n  v2 = iconst.i64 0\n  v3 = iconst.i64 1\n  jmp b1(v2, v2)\nb1(v4: i64, v5: i64):\n  v6 = icmp.ult v4, v1\n  br v6, b2, b3\nb2:\n  v7 = ptradd v0, v4 * 8\n  v8 = load.i64 v7 align 3\n  v9 = call.i64 @id(v8) : (i64) -> i64\n  v10 = add.i64 v5, v9\n  v11, v12 = addo.u.i64 v4, v3\n  br v12, b4, b1(v11, v10)\nb3:\n  ret v5\nb4: cold\n  panic \"attempt to add with overflow\"\n";
    let drv = "#include <stdint.h>\nint64_t f(const int64_t *, int64_t);\nint64_t id(int64_t x) { return x; }\nvoid __sc_panic(const char *m) { (void)m; __builtin_trap(); }\nint main(void) {\n  int64_t a[4] = {1, 2, 3, 4};\n  return f(a, 4) == 10 ? 0 : 1;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// Values a loop keeps past their last use in its last block hold their homes over the back edge: a
// later value of that block takes no register or slot of theirs.
@test
fn loop_kept_values_keep_their_homes() {
    let lir = "lir ptr 8\nsym @id fn global\nsym @f fn global\nfn @f\n  sig (ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, i64) -> i64\nb0(v0: ptr, v1: ptr, v2: ptr, v3: ptr, v4: ptr, v5: ptr, v6: ptr, v7: ptr, v8: i64):\n  v9 = iconst.i64 0\n  v10 = iconst.i64 1\n  jmp b1(v9, v9)\nb1(v11: i64, v12: i64):\n  v13 = icmp.ult v11, v8\n  br v13, b2, b3\nb2:\n  v14 = load.i64 v0 align 3\n  v15 = load.i64 v1 align 3\n  v16 = load.i64 v2 align 3\n  v17 = load.i64 v3 align 3\n  v18 = load.i64 v4 align 3\n  v19 = load.i64 v5 align 3\n  v20 = load.i64 v6 align 3\n  v21 = load.i64 v7 align 3\n  v22 = add.i64 v14, v15\n  v23 = add.i64 v22, v16\n  v24 = add.i64 v23, v17\n  v25 = add.i64 v24, v18\n  v26 = add.i64 v25, v19\n  v27 = add.i64 v26, v20\n  v28 = add.i64 v27, v21\n  v29 = add.i64 v12, v28\n  v30 = call.i64 @id(v29) : (i64) -> i64\n  v31 = call.i64 @id(v11) : (i64) -> i64\n  v32 = add.i64 v31, v10\n  jmp b1(v32, v30)\nb3:\n  ret v12\n";
    let drv = "#include <stdint.h>\nint64_t f(const int64_t *, const int64_t *, const int64_t *, const int64_t *, const int64_t *, const int64_t *, const int64_t *, const int64_t *, int64_t);\nint64_t id(int64_t x) { return x; }\nint main(void) {\n  int64_t a[8] = {1, 2, 3, 4, 5, 6, 7, 8};\n  return f(a, a + 1, a + 2, a + 3, a + 4, a + 5, a + 6, a + 7, 3) == 108 ? 0 : 1;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// A frame of exactly 4 KiB (the slot and two spills): the stack pointer moves by all of it.
@test
fn a_page_sized_frame_runs() {
    let lir = "lir ptr 8\nsym @id fn global\nsym @g fn global\nfn @g\n  sig (i64) -> i64\n  slot s0 size 4080 align 3\nb0(v0: i64):\n  v1 = slotaddr s0\n  v2 = ptradd v1+8\n  store v0, v1 align 3\n  store v0, v2 align 3\n  v3 = call.i64 @id(v0) : (i64) -> i64\n  v4 = load.i64 v2 align 3\n  v5 = add.i64 v3, v4\n  ret v5\n";
    let drv = "#include <stdint.h>\nint64_t g(int64_t);\nint64_t id(int64_t x) { return x; }\nint main(void) { return g(21) == 42 ? 0 : 1; }\n";
    assert_eq(run_native(lir, drv), 0);
}

// Float constants that fit the 8-bit immediate of `fmov`.
@test
fn float_immediates_run() {
    let lir = "lir ptr 8\nsym @kd fn global\nsym @kf fn global\nfn @kd\n  sig () -> f64\nb0:\n  v0 = fconst.f64 0x3ff0000000000000\n  v1 = fconst.f64 0x4000000000000000\n  v2 = fconst.f64 0xc028000000000000\n  v3 = fconst.f64 0x3fc0000000000000\n  v4 = fadd.f64 v0, v1\n  v5 = fadd.f64 v4, v2\n  v6 = fadd.f64 v5, v3\n  ret v6\nfn @kf\n  sig () -> f32\nb0:\n  v0 = fconst.f32 0x3f800000\n  v1 = fconst.f32 0x40000000\n  v2 = fconst.f32 0x3f000000\n  v3 = fconst.f32 0xc1f80000\n  v4 = fadd.f32 v0, v1\n  v5 = fadd.f32 v4, v2\n  v6 = fadd.f32 v5, v3\n  ret v6\n";
    let drv = "double kd(void);\nfloat kf(void);\nint main(void) { return kd() == -8.875 && kf() == -27.5f ? 0 : 1; }\n";
    assert_eq(run_native(lir, drv), 0);
}

// A vector wider than the C side's vector registers (16 bytes here) passes as C declares it, a struct of
// its lanes: through memory (System V: on the stack, the result through rdi; arm64 and Microsoft x64:
// by reference, the result through x8 or rcx). A bare `vector_size(32)` type is no such case: gcc and
// clang return one differently without AVX.
@test
fn wide_vectors_cross_the_c_abi() {
    let lir = "lir ptr 8\nsym @tw fn global\nfn @tw\n  sig (v8f32) -> v8f32\nb0(v0: v8f32):\n  v1 = fadd.v8f32 v0, v0\n  ret v1\n";
    let drv = "typedef struct { _Alignas(32) float l[8]; } v8;\nv8 tw(v8);\nint main(void) {\n  v8 a = {{1, 2, 3, 4, 5, 6, 7, 8}};\n  v8 r = tw(a);\n  for (int i = 0; i < 8; i++) if (r.l[i] != 2 * a.l[i]) return 1;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// A program of two modules, `main` and `lib`, that pass arrays, results, a widened f32, enums with
// payloads and borrowed dyn values across modules: built with each module alone native, the calls cross between C and native code
// both ways and must agree with C's ABI.
const MIXED_LIB: str<'static> = M"(pub interface Sh { fn area(self: &Self) i32; }
pub struct Row { pub w: i32 }
extend Row as Sh { pub fn area(self: &Self) i32 { return self.w; } }
@noinline
pub fn bump(mut a: [i32; 4]) i32 { a[0] = 9; return a[0] + a[3]; }
@noinline
pub fn quad(k: i32) [i32; 4] { return [k, k + 1, k + 2, k + 3]; }
@noinline
pub fn halves() [f32; 4] { return [0.5, 1.5, 2.5, 3.5]; }
@noinline
pub fn twice(x: f64) f64 { return 2.0 * x; }
@noinline
pub fn areas(v: &Vector<&dyn Sh>) i32 { return v.at(0).area() + v.at(1).area(); }
@noinline
pub fn pick(o: Option<u64>, d: u64) u64 { return o.unwrap_or(d); }
@noinline
pub fn pickf(o: Option<f64>, d: f64) f64 { return o.unwrap_or(d); }
@noinline
pub fn some(x: f64) Option<f64> { return Option::<f64>::Some(x); }
)";

const MIXED_MAIN: str<'static> = M"(import lib;
fn main() i32 {
    let a: [i32; 4] = [1, 2, 3, 4];
    if lib::bump(a) != 13 || a[0] != 1 { return 1; }
    if lib::quad(5)[3] != 8 || lib::halves()[2] != 2.5 { return 2; }
    let g: fn(f64) f64 = lib::twice;
    let x: f32 = 1.25;
    if g(x) != 2.5 { return 3; }
    let r = lib::Row { w: 3 };
    let q = lib::Row { w: 4 };
    let mut v: Vector<&dyn lib::Sh> = Vector::new();
    v.push(&r);
    v.push(&q);
    if lib::areas(&v) != 7 { return 4; }
    if lib::pick(Option::<u64>::Some(7), 5) != 7 || lib::pick(Option::<u64>::None, 5) != 5 { return 5; }
    if lib::pickf(Option::<f64>::None, 1.5) != 1.5 || lib::some(2.5).unwrap_or(0.0) != 2.5 { return 6; }
    return 0;
}
)";

@test
fn c_and_native_modules_call_each_other() {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", MIXED_MAIN);
    p.mkfile("lib.spc", MIXED_LIB);
    for sel in ["main", "lib"] {
        let r = cli::superc_env_in(p.dir(), "SC_NATIVE", sel, "build main.spc -o bin");
        if !r.ok() {
            r.show();
        }
        assert(r.ok(), "the mixed program builds");
        assert_eq(p.run_bin(), 0);
    }
}

// C values of `@layout` types pass as the scalars their header's typedefs name: a `double` handle in a
// vector register, an `unsigned long long` one and a pointer one in integer registers, from native code. The
// header's pointer constants (a cast to `void *`, and to a typedef of a pointer) are read too.
@test
fn header_scalars_cross_the_c_abi() {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "h.h",
        "typedef double dv;\ntypedef unsigned long long hv;\ntypedef struct node *pv;\n#define VBAD ((void *)-2)\n#define HBAD ((pv)(long long)-1)\ndv mk(double x);\ndouble get(dv v);\ndv half(dv v, hv k, dv w);\nhv inc(hv k, dv v);\npv same(pv x);\n",
    );
    p.mkfile(
        "h.c",
        "#include \"h.h\"\ndv mk(double x) { return x; }\ndouble get(dv v) { return v; }\ndv half(dv v, hv k, dv w) { return v / 2 + k + w; }\nhv inc(hv k, dv v) { return k + (hv)v; }\npv same(pv x) { return x; }\n",
    );
    assert(p.c_lib("hs", "h.c"), "the C library builds");
    p.mkfile(
        "main.spc",
        format(
            "@link(\"-L{} -lhs\")\nextern \"C\" \"h.h\" {{\n    @layout(8, 8)\n    type dv;\n    @layout(8, 8)\n    type hv;\n    @layout(sizeof(usize), sizeof(usize))\n    type pv;\n    fn mk(x: f64) dv;\n    fn get(v: dv) f64;\n    fn half(v: dv, k: hv, w: dv) dv;\n    fn inc(k: hv, v: dv) hv;\n    fn same(x: pv) pv;\n    const VBAD: *mut void;\n    const HBAD: *mut void;\n}}\n\nfn main() i32 {{\n    let k = unsafe inc(unsafe zeroed::<hv>(), unsafe mk(4.0));\n    let r = unsafe get(unsafe half(unsafe mk(3.0), k, unsafe mk(0.25)));\n    let q = unsafe same(unsafe zeroed::<pv>());\n    if r != 5.75 || unsafe *(((&q) as *const pv) as *const usize) != 0 {{\n        return 1;\n    }}\n    if VBAD as usize != usize::MAX - 1 || HBAD as usize != usize::MAX {{\n        return 2;\n    }}\n    return 0;\n}}\n",
            p.dir(),
        ).as_str(),
    );
    let r = cli::superc_env_in(p.dir(), "SC_NATIVE_STATS", "1", "build main.spc -o bin");
    assert(r.ok(), "the program builds");
    assert(!r.out_has("main through C"), "main compiles natively");
    assert_eq(p.run_bin(), 0);
}

// Vectors of 4 to 32 bytes between modules: built with each module alone native, under both C vector
// forms (vector registers, and lane arrays with SC_SIMD_SCALAR=1), C and native code must agree on where
// each vector travels.
const VEC_LIB: str<'static> = M"(@noinline
pub fn add4(a: f32x4, b: f32x4) f32x4 { return a + b; }
@noinline
pub fn add2(a: f64x2, k: f64, b: f64x2) f64x2 { return a + b + [k, k]; }
@noinline
pub fn mul8(a: i16x8, b: i16x8) i16x8 { return a * b; }
@noinline
pub fn wide(a: f32x8, n: i32, b: f32x8) f32x8 { return a - b + [n as f32; 8]; }
@noinline
pub fn small(a: Simd<u8, 4>, b: Simd<i32, 2>) Simd<u8, 4> { return a + [b[0] as u8, b[1] as u8, 1, 1]; }
)";

const VEC_MAIN: str<'static> = M"(import lib;
fn main() i32 {
    let a: f32x4 = [1.0, 2.0, 3.0, 4.0];
    if lib::add4(a, a)[3] != 8.0 { return 1; }
    let d: f64x2 = [0.5, 1.5];
    if lib::add2(d, 1.0, d)[1] != 4.0 { return 2; }
    let s: i16x8 = [1, 2, 3, 4, 5, 6, 7, -8];
    if lib::mul8(s, s)[7] != 64 { return 3; }
    let w: f32x8 = [9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0];
    let z: f32x8 = [1.0; 8];
    if lib::wide(w, 2, z)[0] != 10.0 || lib::wide(w, 2, z)[7] != 3.0 { return 4; }
    let u: Simd<u8, 4> = [10, 20, 30, 40];
    let r = lib::small(u, [5, 6]);
    if r[0] != 15 || r[1] != 26 || r[3] != 41 { return 5; }
    return 0;
}
)";

@test
fn vectors_cross_between_c_and_native_modules() {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", VEC_MAIN);
    p.mkfile("lib.spc", VEC_LIB);
    for scalar in ["0", "1"] {
        let _s = cli::set_env("SC_SIMD_SCALAR", scalar);
        for sel in ["main", "lib"] {
            let r = cli::superc_env_in(p.dir(), "SC_NATIVE", sel, "build main.spc -o bin");
            if !r.ok() {
                r.show();
            }
            assert(r.ok(), "the vector program builds");
            assert_eq(p.run_bin(), 0);
        }
    }
}

// A native object holds the C header constants it reads, so an edit of the header rebuilds it; a header's
// `static` function, which no object exports, sends its caller through C.
@test
fn header_edits_reach_native_objects() {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("val.h", "#define KVAL 40\nstatic inline int one(void) { return 1; }\n");
    p.mkfile(
        "main.spc",
        "extern \"C\" \"val.h\" {\n    const KVAL: i32;\n    fn one() i32;\n}\n\nfn main() i32 {\n    return KVAL + unsafe one();\n}\n",
    );
    assert_eq(cli::superc_in(p.dir(), "run").exit, 41);
    p.mkfile("val.h", "#define KVAL 41\nstatic inline int one(void) { return 1; }\n");
    assert_eq(cli::superc_in(p.dir(), "run").exit, 42);
}

// The native objects under `dir` (`rel` its path below the tree's root), each as its relative path and
// its bytes, in listing order sorted by path.
fn objects(dir: str, rel: str, names: &mut Vector<String>, bodies: &mut Vector<String>) {
    let mut d = fs::read_dir(dir).unwrap();
    while let Some(Ok(e)) = d.next() {
        let path = format("{}/{}", dir, e.name);
        let r = format("{}/{}", rel, e.name);
        if e.kind == Option::<fs::FileKind>::Some(fs::FileKind::Dir) {
            objects(path.as_str(), r.as_str(), names, bodies);
        } else if e.name.ends_with(".o") {
            names.push(r);
            bodies.push(cli::read_text(path.as_str()));
        }
    }
}

// The objects of the build tree of project `p`, sorted by path.
fn tree_objects(p: &cli::Proj) Vector<String> {
    let mut names = Vector::<String>::new();
    let mut bodies = Vector::<String>::new();
    objects(format("{}/build/debug/raw", p.dir()).as_str(), "", &mut names, &mut bodies);
    let mut key = Vector::<u64>::new();
    for k in 0..names.len() {
        key.push(names.at(k).as_str().hash() << 16 | k as u64);
    }
    key.sort();
    let mut out = Vector::<String>::new();
    for k in 0..key.len() {
        let i = (key[k] & 0xFFFF) as usize;
        out.push(format("{}\n{}", names.at(i).as_str(), bodies.at(i).as_str()));
    }
    return out;
}

// Two builds of a program give identical native objects: a clean build twice, and a build that replays
// the emission cache of the modules an undone edit left as they were.
@test
fn native_objects_are_identical_across_builds() {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("main.spc", MIXED_MAIN);
    p.mkfile("lib.spc", MIXED_LIB);
    assert(cli::superc_in(p.dir(), "build").ok(), "the first build");
    let first = tree_objects(&p);
    assert(first.len() >= 3, "the build writes native objects");
    let _ = fs::remove_all(format("{}/build", p.dir()).as_str());
    assert(cli::superc_in(p.dir(), "build").ok(), "the clean build");
    let clean = tree_objects(&p);
    assert(clean.len() == first.len(), "a clean build writes the same objects");
    for k in 0..first.len() {
        assert(clean.at(k).as_str() == first.at(k).as_str(), "a clean build writes the same bytes");
    }
    p.mkfile("lib.spc", format("{}pub fn extra() i32 {{ return 5; }}\n", MIXED_LIB).as_str());
    assert(cli::superc_in(p.dir(), "build").ok(), "the edited build");
    p.mkfile("lib.spc", MIXED_LIB);
    assert(cli::superc_in(p.dir(), "build").ok(), "the build of the undone edit");
    let again = tree_objects(&p);
    assert(again.len() == first.len(), "the cached build writes the same objects");
    for k in 0..first.len() {
        assert(again.at(k).as_str() == first.at(k).as_str(), "the cached build writes the same bytes");
    }
}
