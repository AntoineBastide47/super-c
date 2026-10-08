// Vector code on aarch64 (Neon in every build): the C of a program without vectors does not depend on
// the optional features; vector operations lower to the instructions of their backend entries; a float
// tree reduction adds halves, not adjacent pairs; the operations of `std::simd::aarch64` match scalar
// models and need their features; every memory binding of ffi/arm_neon.spc states its range; and
// `std::cpu::detect` reports the machine's features. The host checks run on an aarch64 host only.
import tests::harness as h;
import tests::cli_harness as cli;
import driver_shim as shim;
import std::cpu;
import std::cpu::detect as detect;

fn aarch64_host() bool {
    return unsafe shim::sc_host_arch() == 1 && !h::simd_lane();
}

// The emitted tree of `src` built with `flags`: its manifest (every output file's content hash) and
// main.c.
fn emitted(src: str, flags: str) String {
    let p = cli::proj_new();
    p.mkfile("main.spc", src);
    let r = p.compile_flags(flags, "main.spc");
    assert(r.ok(), flags);
    let root = str::from_cstr(p.rootp());
    let mut t = cli::read_text(format("{}/build/dev/raw/__sc_manifest", root).as_str());
    t.push_str(cli::read_text(format("{}/build/dev/raw/main.c", root).as_str()).as_str());
    return t;
}

@test
fn a_program_without_vectors_emits_the_same_c() {
    if !aarch64_host() {
        return;
    }
    let src = "fn main(args: Vector<str>) i32 {\n    let v = [1, 2, 3];\n    return unsafe v[args.len() % 3] - 2;\n}\n";
    let a = emitted(src, "");
    assert(
        a.len() != 0 && a.as_str() == emitted(src, "--target-feature=+i8mm,+bf16").as_str(),
        "the features change nothing",
    );
    let vsrc = "fn main(args: Vector<str>) i32 {\n    let v = f32x4::splat(args.len() as f32);\n    return (v + v).get(0) as i32 - 2;\n}\n";
    assert(emitted(vsrc, "").contains("__sc_si_aarch64__add_f32x4"), "a vector operation calls its entry");
    // A program that names vectors only through an alias of the module loads the backend too.
    let asrc = "import std::simd as v;\nfn main(args: Vector<str>) i32 {\n    let a = [args.len() as f32; 4];\n    return v::reduce_add_tree(v::load::<f32, 4>(a, 0) + v::load::<f32, 4>(a, 0)) as i32 - 8;\n}\n";
    assert(emitted(asrc, "").contains("__sc_si_aarch64__add_f32x4"), "an aliased module");
}

const RELEASE: [str; 1] = ["--profile=release"];

// Kernel `k` (`src`), called from `main` on `args` built from the run-time value `n`, lowers to
// instructions holding each of `want` and none of `avoid`.
fn check(label: str, src: str, args: str, want: []str, avoid: []str) {
    let ops: []str = RELEASE;
    let full = kernel(src, args);
    h::expect_asm(label, full.as_str(), ops, "main__k", want, avoid);
    // The instructions come from an entry, not from the lane loop the C compiler vectorized.
    let b = h::diff_build(full.as_str(), ops);
    let c = cli::read_text(format("{}/build/release/raw/main.c", str::from_cstr(b.proj.rootp())).as_str());
    if !c.contains("__sc_si_aarch64__") {
        eprintln("{}: no entry call in the C", label);
    }
    assert(c.contains("__sc_si_aarch64__"), label);
}

// `src` with a `main` that calls the kernel `k` on `args` built from a run-time value.
fn kernel(src: str, args: str) String {
    return format(
        "import std::simd;\n@c.noinline\n{}fn main(args: Vector<str>) i32 {{\n    let n = args.len();\n    return ({}) as i32;\n}}\n",
        src,
        args,
    );
}

// Each kernel lowers to its Neon instructions with no call left: a required kernel that falls back to
// lane loops fails.
@test
fn operations_lower_to_their_instructions() {
    if !aarch64_host() {
        return;
    }
    check(
        "lane-wise add",
        "fn k(a: f32x4, b: f32x4) f32x4 {\n    return a + b;\n}\n",
        "k(f32x4::splat(n as f32), f32x4::splat(1.0)).get(0)",
        ["fadd"],
        ["=bl"],
    );
    // A 64-bit vector takes the `d` form of its entry.
    check(
        "a 64-bit add",
        "fn k(a: Simd<f32, 2>, b: Simd<f32, 2>) Simd<f32, 2> {\n    return a + b;\n}\n",
        "k(Simd::<f32, 2>::splat(n as f32), Simd::<f32, 2>::splat(1.0)).get(0)",
        ["fadd"],
        ["=bl"],
    );
    check(
        "fma",
        "fn k(a: f32x4, b: f32x4) f32x4 {\n    return a.fma(b, a);\n}\n",
        "k(f32x4::splat(n as f32), f32x4::splat(1.0)).get(0)",
        ["fmla"],
        ["=bl"],
    );
    // A comparison whose one use is a choice stays in lanes: no mask in between.
    check(
        "count of a comparison",
        "fn k(a: u8x64, b: u8x64) usize {\n    return a.equal(b).count();\n}\n",
        "k(u8x64::splat(n as u8), u8x64::splat(1))",
        ["cmeq", "addv"],
        ["=bl", "cnt"],
    );
    check(
        "a choice of narrower lanes",
        "fn k(a: f32x16, b: f32x16, p: u8x16, q: u8x16) u8x16 {\n    return a.less_than(b).choose(p, q);\n}\n",
        "k(f32x16::splat(n as f32), f32x16::splat(1.0), u8x16::splat(2), u8x16::splat(3)).get(0)",
        ["fcmgt", "uzp1"],
        ["=bl", "addv"],
    );
    check(
        "compress_store",
        "fn k(v: f32x16, t: f32x16) usize {\n    let mut a = [0.0f32; 32];\n    return simd::compress_store(a, 1, v.greater_than(t), v) + a[3] as usize;\n}\n",
        "k(f32x16::splat(n as f32), f32x16::splat(0.5))",
        ["tbl"],
        [],
    );
    check(
        "gather's index check",
        "fn k(s: []f32, x: u32x16) f32 {\n    return simd::reduce_add_tree(simd::gather(s, x, Mask::<16>::splat(true), f32x16::splat(0.0)));\n}\n",
        "k([1.0f32; 64], u32x16::splat(n as u32)) as usize",
        ["cmhi", "umaxv"],
        [],
    );
    check(
        "compare and choose",
        "fn k(a: i8x16, b: i8x16, c: i8x16) i8x16 {\n    return a.less_than(b).choose(c, a);\n}\n",
        "k(i8x16::splat(n as i8), i8x16::splat(1), i8x16::splat(2)).get(0)",
        ["cmgt"],
        ["=bl", "addv"],
    );
    check(
        "compare to a mask",
        "fn k(a: u8x16, b: u8x16) u32 {\n    return a.equal(b).count() as u32;\n}\n",
        "k(u8x16::splat(n as u8), u8x16::splat(1))",
        ["cmeq", "addv"],
        ["=bl"],
    );
    check(
        "any of a comparison",
        "fn k(a: i32x4, b: i32x4) bool {\n    return a.less_than(b).any();\n}\n",
        "k(i32x4::splat(n as i32), i32x4::splat(1))",
        ["cmgt", "umaxv"],
        ["=bl", "addv"],
    );
    check(
        "all of a comparison",
        "fn k(a: u16x8, b: u16x8) bool {\n    return a.equal(b).all();\n}\n",
        "k(u16x8::splat(n as u16), u16x8::splat(1))",
        ["cmeq", "uminv"],
        ["=bl", "addv"],
    );
    check(
        "a run-time index",
        "fn k(a: u8x16, b: u8x16) u8x16 {\n    return simd::swizzle_or_zero(a, b);\n}\n",
        "k(u8x16::splat(n as u8), u8x16::splat(1)).get(0)",
        ["tbl"],
        ["=bl"],
    );
    // `sdot` where the build has `dotprod` (every macOS build, `SC_SIMD_FEATURES`), else the widened
    // products.
    let dot = "fn k(a: i8x16, b: i8x16) i32 {\n    return simd::dot::<i32>(a, b);\n}\n";
    let dargs = "k(i8x16::splat(n as i8), i8x16::splat(1))";
    let more = stdlib::getenv("SC_SIMD_FEATURES");
    if PLATFORM == Platform::MacOS || more != null && str::from_cstr(more).contains("dotprod") {
        check("a dot product", dot, dargs, ["sdot", "addv"], ["=bl"]);
    } else {
        check("a dot product", dot, dargs, ["smull", "addv"], ["=bl", "sdot"]);
    }
    check(
        "a load",
        "fn k(s: []f32) f32x4 {\n    return simd::load::<f32, 4>(s, 0) + f32x4::splat(1.0);\n}\n",
        "k([n as f32; 4]).get(0)",
        ["ldr", "fadd"],
        [],
    );
    check(
        "a min_num reduction",
        "fn k(a: f32x4, b: f32x4) f32 {\n    return simd::reduce_min_num(a + b);\n}\n",
        "k(f32x4::splat(n as f32), f32x4::splat(1.0))",
        ["fminnmv"],
        ["=bl"],
    );
    check(
        "a tree sum",
        "fn k(a: f32x4) f32 {\n    return simd::reduce_add_tree(a);\n}\n",
        "k(f32x4::splat(n as f32))",
        ["fadd"],
        ["=bl"],
    );
}

// The sum of [1e8, 1, -1e8, 1] by halves is (1e8 + -1e8) + (1 + 1) = 2; by adjacent pairs
// (`faddp`) it is (1e8 + 1) + (-1e8 + 1) = 0 in f32.
@test
fn a_float_tree_reduction_adds_halves() {
    h::expect_run(
        "halves, not pairs",
        "import std::simd;\nfn main(args: Vector<str>) i32 {\n    let k = args.len() as f32;\n    let v = f32x4::from_array([1.0e8 * k, 1.0, -1.0e8 * k, 1.0]);\n    let w = Simd::<f32, 8>::from_array([1.0e8 * k, 1.0, -1.0e8 * k, 1.0, 0.0, 0.0, 0.0, 0.0]);\n    assert(simd::reduce_add_tree(v) == 2.0 && simd::reduce_add_tree(w) == 2.0, \"halves\");\n    return 0;\n}\n",
        "",
        "",
    );
}

// A vector of 16 bytes or less is a C vector under the planner: its lanes have no address of their
// own, so a lane borrow, a constant's pointer to a lane and the byte moves address through the vector.
@test
fn register_vectors_address_their_lanes() {
    h::expect_run(
        "lane addresses",
        "import std::simd;\nstatic mut V: f32x4 = f32x4::from_array([1.0, 2.0, 3.0, 4.0]);\nconst A: f32x4 = f32x4::from_array([1.0, 2.0, 3.0, 4.0]);\nconst R: &f32 = &A[2];\nfn bump(x: &mut f32) {\n    *x = *x + 10.0;\n}\nfn main(args: Vector<str>) i32 {\n    let n = args.len() as f32;\n    let mut v = f32x4::splat(n);\n    bump(&mut v[2]);\n    unsafe bump(&mut V[1]);\n    let w = simd::concat(Simd::<f32, 2>::splat(n), Simd::<f32, 2>::splat(2.0));\n    let h = (u8x16::splat(n as u8) + u8x16::splat(1)).high_half();\n    assert(v[2] == 11.0 && unsafe V[1] == 12.0 && *R == 3.0 && w[3] == 2.0 && h[7] == 2, \"lanes\");\n    return 0;\n}\n",
        "",
        "",
    );
}

// The operations of `std::simd::aarch64` against scalar models, built with every feature they need
// and run on a machine that has them. A build may use its features anywhere, so the `i8mm` models
// are a build of their own, run only on a machine with `i8mm` (an Apple M1 lacks it).
@test
fn arch_operations_match_scalar_models() {
    if !aarch64_host() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", ARCH_MODELS);
    assert_eq(build_run(&p, "--target-feature=+dotprod,+rdm,+aes,+sha2,+sha3,+crc"), 0);
    if detect::has(cpu::Feature::I8mm) {
        let q = cli::proj_new();
        q.mkfile("main.spc", I8MM_MODELS);
        assert_eq(build_run(&q, "--target-feature=+i8mm"), 0);
    }
}

// A call of an operation whose feature the build lacks is an error naming the feature and its flag.
@test
fn arch_operations_need_their_feature() {
    if !aarch64_host() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import std::simd::aarch64 as a64;\nfn main() i32 {\n    let a = u8x16::splat(1);\n    return a64::vmmla_u32(u32x4::splat(0), a, a).get(0) as i32 + a64::table_lookup(a, a).get(0) as i32 - 9;\n}\n",
    );
    let r = p.compile_flags("", "main.spc");
    assert(!r.ok() && r.out_has("`vmmla_u32` needs `+i8mm` (`--target-feature=+i8mm`)"), "i8mm");
    assert(!r.out_has("`table_lookup` needs"), "neon is there");
    assert(p.compile_flags("--target-feature=+i8mm", "main.spc").ok(), "with the feature");
}

// Every load and store binding states the bytes it reads or writes.
@test
fn neon_memory_bindings_state_their_range() {
    let text = cli::read_text("ffi/arm_neon.spc");
    let mut prev = String::new();
    let mut n: u32 = 0;
    for line in text.as_str().lines() {
        let t = line.trim();
        if t.starts_with("pub fn vld") || t.starts_with("pub fn vst") {
            n += 1;
            let want = pick(t.starts_with("pub fn vld"), "@c.reads(ptr, ", "@c.writes(ptr, ");
            if !prev.as_str().starts_with(want) {
                eprintln("{}: {}", t, prev.as_str());
            }
            assert(prev.as_str().starts_with(want), "a memory binding states its range");
        }
        prev = String::from_str(t);
    }
    assert(n >= 40, "the loads and stores");
}

// `std::cpu::detect`: the OS query alone (`detected`) reports every feature of the build on an aarch64
// machine, and `dotprod` and `lse` on macOS arm64; `features` is that and the build's set, the same on
// each call; a C constructor that asks before `main` gets the answer `main` gets.
@test
fn detection_reports_the_machine() {
    let p = cli::proj_new();
    p.mkfile("pre.h", "int pre_dotprod(void);\n");
    p.mkfile(
        "pre.c",
        "#include \"pre.h\"\nint sc_cpu_has(int feature);\nstatic int g = -1;\n__attribute__((constructor)) static void pre(void) { g = sc_cpu_has(5); }\nint pre_dotprod(void) { return g; }\n",
    );
    p.mkfile(
        "main.spc",
        M"(import std::cpu;
import std::cpu::detect as detect;
extern "C" "pre.h" {
    fn pre_dotprod() i32;
}
fn main() i32 {
    let f = detect::features();
    let s = detect::static_features();
    let d = detect::detected();
    if f.bits[0] != (d.bits[0] | s.bits[0]) || detect::features().bits[0] != f.bits[0] || ARCH == Arch::AArch64 && !(d.has(cpu::Feature::Neon) && d.contains(s)) {
        return 1;
    }
    if unsafe pre_dotprod() != detect::has(cpu::Feature::Dotprod) as i32 {
        return 2;
    }
    if PLATFORM == Platform::MacOS && ARCH == Arch::AArch64 && !(d.has(cpu::Feature::Dotprod) && d.has(cpu::Feature::Lse)) {
        return 3;
    }
    if !s.has(cpu::Feature::Neon) && ARCH == Arch::AArch64 || s.has(cpu::Feature::Sve) {
        return 4;
    }
    return 0;
}
)",
    );
    assert_eq(build_run(&p, ""), 0);
}

// Two threads that ask at once get one answer, with no race report. The constructor answered before
// `main`, so they race on the published answer and on fresh OS queries, not on the first detection.
@test
fn concurrent_queries_agree_without_a_race() {
    if cli::on_windows() || cli::on_wasm() || h::simd_lane() {
        return;
    }
    let src = M"(import std::cpu::detect as detect;
import std::parallel::thread as thread;
static mut A: u64 = 0;
fn main() i32 {
    let t = thread::spawn(fn() {
        unsafe A = detect::features().bits[0] ^ detect::detected().bits[0];
    });
    let b = detect::features().bits[0] ^ detect::detected().bits[0];
    t.join();
    return pick(unsafe A == b, 0, 1);
}
fn pick(c: bool, a: i32, b: i32) i32 {
    if c {
        return a;
    }
    return b;
}
)";
    let b = h::diff_build(src, ["--profile=race"]);
    assert(b.built, b.diag.as_str());
    let r = h::diff_run(&b, "");
    if r.exit != 0 || r.err.contains("ThreadSanitizer") {
        eprintln("exit {}: {}", r.exit, r.err.as_str());
    }
    assert(r.exit == 0 && !r.err.contains("ThreadSanitizer"), "one answer, no race");
}

// Build `main.spc` of project `p` with `flags` and run it: its exit code (-1: no build), and its output
// on stderr when it fails.
fn build_run(p: &cli::Proj, flags: str) i32 {
    let root = str::from_cstr(p.rootp());
    let b = p.run_raw(format("build \"{}/main.spc\" -o \"{}/app\" {}", root, root, flags).as_str());
    if !b.ok() {
        b.show();
        return -1;
    }
    let mut cmd = format("\"{}/app\"", root);
    let mut out = format("{}/.app_out", root);
    let rc = cli::run_io(cmd.cstr(), null, out.cstr(), null);
    if rc != 0 {
        eprintln("{}", cli::read_text(out.as_str()).as_str());
    }
    return rc;
}

const fn pick<T>(c: bool, a: T, b: T) T {
    if c {
        return a;
    }
    return b;
}

const I8MM_MODELS: str = M"(import stdlib;
import std::simd::aarch64 as a64;

static mut SEED: u64 = 0;

fn next() u64 {
    unsafe SEED = unsafe SEED.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    return unsafe SEED >> 24;
}

fn fail(what: str) {
    println("{} differs from its model", what);
    unsafe stdlib::exit(1);
}

fn main(args: Vector<str>) i32 {
    unsafe SEED = args.len() as u64;
    for _ in 0..64 {
        let mut a8 = [0u8; 16];
        let mut b8 = [0u8; 16];
        for i in 0..16usize {
            unsafe a8[i] = next() as u8;
            unsafe b8[i] = next() as u8;
        }
        let ua = u8x16::from_array(a8);
        let ub = u8x16::from_array(b8);
        let sa = ua.cast::<i8>();
        let sb = ub.cast::<i8>();
        let acc = i32x4::from_array([next() as i32, next() as i32, next() as i32, next() as i32]);
        let m = a64::vmmla_i32(acc, sa, sb);
        let mu = a64::vmmla_u32(acc.cast::<u32>(), ua, ub);
        let us = a64::vusmmla_i32(acc, ua, sb);
        for i in 0..2usize {
            for j in 0..2usize {
                let mut s = acc[2 * i + j];
                let mut su = acc[2 * i + j] as u32;
                let mut ss = acc[2 * i + j];
                for k in 0..8usize {
                    s = s.wrapping_add(sa[8 * i + k] as i32 * sb[8 * j + k] as i32);
                    su = su.wrapping_add(ua[8 * i + k] as u32 * ub[8 * j + k] as u32);
                    ss = ss.wrapping_add(ua[8 * i + k] as i32 * sb[8 * j + k] as i32);
                }
                if m[2 * i + j] != s || mu[2 * i + j] != su || us[2 * i + j] != ss {
                    fail("vmmla");
                }
            }
        }
    }
    return 0;
}
)";

const ARCH_MODELS: str = M"(import stdlib;
import std::cpu;
import std::cpu::detect as detect;
import std::simd::aarch64 as a64;

static mut SEED: u64 = 0;

fn next() u64 {
    unsafe SEED = unsafe SEED.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    return unsafe SEED >> 24;
}

fn ror(x: u32, n: u32) u32 {
    return x >> n | x << (32 - n);
}

fn crc(c0: u32, data: u64, bytes: u64, poly: u32) u32 {
    let mut c = c0;
    for i in 0..bytes * 8 {
        let bit = (data >> i & 1) as u32;
        c = if ((c ^ bit) & 1) != 0 {
            c >> 1 ^ poly;
        } else {
            c >> 1;
        };
    }
    return c;
}

fn sat(v: i64, w: u32) i64 {
    let hi = (1i64 << (w - 1)) - 1;
    return v.min(hi).max(-hi - 1);
}

fn fail(what: str) {
    println("{} differs from its model", what);
    unsafe stdlib::exit(1);
}

fn main(args: Vector<str>) i32 {
    unsafe SEED = args.len() as u64;
    for _ in 0..64 {
        let mut a8 = [0u8; 16];
        let mut b8 = [0u8; 16];
        let mut c8 = [0u8; 16];
        for i in 0..16usize {
            unsafe a8[i] = next() as u8;
            unsafe b8[i] = next() as u8;
            unsafe c8[i] = next() as u8;
        }
        let ua = u8x16::from_array(a8);
        let ub = u8x16::from_array(b8);
        let uc = u8x16::from_array(c8);
        let sa = ua.cast::<i8>();
        let sb = ub.cast::<i8>();
        let acc = i32x4::from_array([next() as i32, next() as i32, next() as i32, next() as i32]);
        // dot products and matrix products
        if !(detect::has(cpu::Feature::Dotprod) && detect::has(cpu::Feature::Rdm) && detect::has(cpu::Feature::Aes) && detect::has(
            cpu::Feature::Sha2,
        ) && detect::has(cpu::Feature::Sha3) && detect::has(cpu::Feature::Crc)) {
            return 0; // a machine without one of them (an Armv8.0 core) checks none
        }
        let d = a64::vdot_i32(sa, sb, acc);
        let du = a64::vdot_u32(ua, ub, acc.cast::<u32>());
        for i in 0..4usize {
            let mut s = acc[i];
            let mut su = acc[i] as u32;
            for k in 0..4usize {
                s = s.wrapping_add(sa[4 * i + k] as i32 * sb[4 * i + k] as i32);
                su = su.wrapping_add(ua[4 * i + k] as u32 * ub[4 * i + k] as u32);
            }
            if d[i] != s || du[i] != su {
                fail("vdot");
            }
        }
        // rounding doubling multiply-accumulate
        let x16 = i16x8::from_array([next() as i16, next() as i16, next() as i16, -32768, 32767, next() as i16, 1, -1]);
        let y16 = i16x8::from_array([next() as i16, -32768, next() as i16, -32768, 32767, next() as i16, next() as i16, 3]);
        let z16 = i16x8::from_array([next() as i16, -32768, next() as i16, 32767, -32768, next() as i16, next() as i16, 5]);
        let ah = a64::vqrdmlah_i16(x16, y16, z16);
        let sh = a64::vqrdmlsh_i16(x16, y16, z16);
        for i in 0..8usize {
            let p = 2 * y16[i] as i64 * z16[i] as i64;
            let base = (x16[i] as i64) << 16;
            if ah[i] as i64 != sat((base + p + (1 << 15)) >> 16, 16) || sh[i] as i64 != sat((base - p + (1 << 15)) >> 16, 16) {
                fail("vqrdmlah/vqrdmlsh i16");
            }
        }
        // (2^32 x + 2 y z + 2^31) >> 32 halved first, so no term passes 64 bits
        let x32 = i32x4::from_array([next() as i32, -2147483648, 2147483647, next() as i32]);
        let y32 = i32x4::from_array([next() as i32, -2147483648, next() as i32, 2147483647]);
        let z32 = i32x4::from_array([next() as i32, -2147483648, next() as i32, -2147483648]);
        let a32 = a64::vqrdmlah_i32(x32, y32, z32);
        let s32 = a64::vqrdmlsh_i32(x32, y32, z32);
        for i in 0..4usize {
            let p = y32[i] as i64 * z32[i] as i64;
            let base = (x32[i] as i64) << 31;
            if a32[i] as i64 != sat((base + p + (1 << 30)) >> 31, 32) || s32[i] as i64 != sat((base - p + (1 << 30)) >> 31, 32) {
                fail("vqrdmlah/vqrdmlsh i32");
            }
        }
        // AES: a round undone, MixColumns undone
        let e = a64::aese(ua, ub);
        if !a64::aesd(e, u8x16::splat(0)).equal(ua ^ ub).all() || !a64::aesimc(a64::aesmc(uc)).equal(uc).all() {
            fail("aes");
        }
        // SHA-256: four schedule words, four rounds
        let mut w = [0u32; 20];
        for i in 0..16usize {
            unsafe w[i] = next() as u32;
        }
        for t in 16..20usize {
            let s0 = ror(unsafe w[t - 15], 7) ^ ror(unsafe w[t - 15], 18) ^ unsafe w[t - 15] >> 3;
            let s1 = ror(unsafe w[t - 2], 17) ^ ror(unsafe w[t - 2], 19) ^ unsafe w[t - 2] >> 10;
            unsafe w[t] = s1.wrapping_add(unsafe w[t - 7]).wrapping_add(s0).wrapping_add(unsafe w[t - 16]);
        }
        let w4 = a64::sha256su1(a64::sha256su0(wv(&w, 0), wv(&w, 4)), wv(&w, 8), wv(&w, 12));
        if !w4.equal(wv(&w, 16)).all() {
            fail("sha256su0/su1");
        }
        let mut st = [0u32; 8];
        for i in 0..8usize {
            unsafe st[i] = next() as u32;
        }
        let abcd = u32x4::from_array([st[0], st[1], st[2], st[3]]);
        let efgh = u32x4::from_array([st[4], st[5], st[6], st[7]]);
        let wk = wv(&w, 0);
        let h0 = a64::sha256h(abcd, efgh, wk);
        let h1 = a64::sha256h2(efgh, abcd, wk);
        for r in 0..4usize {
            let e0 = st[4];
            let a0 = st[0];
            let s1 = ror(e0, 6) ^ ror(e0, 11) ^ ror(e0, 25);
            let ch = e0 & st[5] ^ ~e0 & st[6];
            let t1 = st[7].wrapping_add(s1).wrapping_add(ch).wrapping_add(wk[r]);
            let s0 = ror(a0, 2) ^ ror(a0, 13) ^ ror(a0, 22);
            let maj = a0 & st[1] ^ a0 & st[2] ^ st[1] & st[2];
            for k in [7usize, 6, 5, 4, 3, 2, 1] {
                unsafe st[k] = unsafe st[k - 1];
            }
            st[4] = st[4].wrapping_add(t1);
            st[0] = t1.wrapping_add(s0).wrapping_add(maj);
        }
        if !h0.equal(u32x4::from_array([st[0], st[1], st[2], st[3]])).all() || !h1.equal(u32x4::from_array([st[4], st[5], st[6], st[7]])).all() {
            fail("sha256h/h2");
        }
        // SHA-3 helpers
        let x64 = u64x2::from_array([next() << 20 ^ next(), next() << 20 ^ next()]);
        let y64 = u64x2::from_array([next() << 20 ^ next(), next() << 20 ^ next()]);
        let r1 = a64::rax1(x64, y64);
        let xr = a64::xar::<13>(x64, y64);
        for i in 0..2usize {
            if r1[i] != (x64[i] ^ (y64[i] << 1 | y64[i] >> 63)) || xr[i] != ((x64[i] ^ y64[i]) >> 13 | (x64[i] ^ y64[i]) << 51) {
                fail("rax1/xar");
            }
        }
        if !a64::eor3(ua, ub, uc).equal(ua ^ ub ^ uc).all() || !a64::bcax(ua, ub, uc).equal(ua ^ (ub & ~uc)).all() {
            fail("eor3/bcax");
        }
        // CRC-32 and CRC-32C
        let c0 = next() as u32;
        let dv = next() << 20 ^ next();
        let ok = a64::crc32b(c0, dv as u8) == crc(c0, dv, 1, 0xEDB88320) && a64::crc32h(c0, dv as u16) == crc(c0, dv, 2, 0xEDB88320) && a64::crc32w(
            c0,
            dv as u32,
        ) == crc(c0, dv, 4, 0xEDB88320) && a64::crc32x(c0, dv) == crc(c0, dv, 8, 0xEDB88320);
        let okc = a64::crc32cb(c0, dv as u8) == crc(c0, dv, 1, 0x82F63B78) && a64::crc32ch(c0, dv as u16) == crc(c0, dv, 2, 0x82F63B78) && a64::crc32cw(
            c0,
            dv as u32,
        ) == crc(c0, dv, 4, 0x82F63B78) && a64::crc32cx(c0, dv) == crc(c0, dv, 8, 0x82F63B78);
        if !ok || !okc {
            fail("crc32");
        }
        // table lookups: an index past the table gives 0
        let ix = ub & u8x16::splat(127);
        let mut big = [0u8; 64];
        for i in 0..64usize {
            unsafe big[i] = next() as u8;
        }
        let mut b32 = [0u8; 32];
        for i in 0..32usize {
            unsafe b32[i] = unsafe big[i + 32];
        }
        let t2 = Simd::<u8, 32>::from_array(b32);
        let t4 = Simd::<u8, 64>::from_array(big);
        let mut t3 = [0u8; 48];
        for i in 0..48usize {
            unsafe t3[i] = unsafe big[i];
        }
        let l1 = a64::table_lookup(ua, ix);
        let l2 = a64::table_lookup_2(t2, ix);
        let l3 = a64::table_lookup_3(t3, ix);
        let l4 = a64::table_lookup_4(t4, ix);
        for i in 0..16usize {
            let k = ix[i] as usize;
            if l1[i] != pick_u8(k < 16, ua[k % 16]) || l2[i] != pick_u8(k < 32, t2[k % 32]) || l3[i] != pick_u8(k < 48, unsafe t3[k % 48]) || l4[i] != pick_u8(k < 64, t4[k % 64]) {
                fail("table_lookup");
            }
        }
    }
    // a known MixColumns column, and SubBytes of zero
    let mc = a64::aesmc(u8x16::from_array([0xdb, 0x13, 0x53, 0x45, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
    if mc[0] != 0x8e || mc[1] != 0x4d || mc[2] != 0xa1 || mc[3] != 0xbc || a64::aese(u8x16::splat(0), u8x16::splat(0))[5] != 0x63 {
        fail("aes vectors");
    }
    return 0;
}

fn wv(w: &[u32; 20], k: usize) u32x4 {
    return u32x4::from_array([unsafe w[k], unsafe w[k + 1], unsafe w[k + 2], unsafe w[k + 3]]);
}

fn pick_u8(c: bool, v: u8) u8 {
    if c {
        return v;
    }
    return 0;
}
)";
