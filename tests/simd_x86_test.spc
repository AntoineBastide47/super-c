// Vector code on x86-64: the planner serves each function from the entries its own features allow;
// every memory binding of ffi/immintrin.spc states its range; on an x86-64 host, the C of a program
// without vectors does not depend on the level, vector operations lower to the instructions of their
// level (AVX-512 checked in the assembly only when the machine lacks it), a baseline function holds no
// AVX register, and the operations of `std::simd::x86` match scalar models.
import tests::harness as h;
import tests::cli_harness as cli;
import driver_shim as shim;
import stdlib;
import std::cpu;
import std::cpu::detect as detect;
import ir::cpu_features as cf;
import tests::gen::simd_entry as se;

fn x86_host() bool {
    return unsafe shim::sc_host_arch() == 0 && !h::simd_lane();
}

// The definition of C function `name` (with its module prefix) in `c`, from its opening line to its
// closing brace at column 0; empty when `c` does not define it.
fn fn_body<'a>(c: str<'a>, name: str) str<'a> {
    let head = format("__{}(", name);
    let mut at: usize = 0;
    // Each match moves `at` forward: at most one pass over `c`.
    while at < c.len() {
        let k = c.slice(at, c.len()).find(head.as_str());
        if k < 0 {
            return "";
        }
        let rest = c.slice(at + k as usize, c.len());
        let eol = rest.find("\n");
        let end = rest.find("\n}\n");
        if eol > 0 && rest.slice(0, eol as usize).ends_with("{") && end > 0 {
            return rest.slice(0, end as usize);
        }
        at = at + k as usize + head.len();
    }
    return "";
}

// The line of `c` that holds the first `needle`; empty when none does.
fn line_of<'a>(c: str<'a>, needle: str) str<'a> {
    let k = c.find(needle);
    if k < 0 {
        return "";
    }
    let mut st = k as usize;
    while st > 0 && c.byte_at(st - 1) != b'\n' {
        st -= 1;
    }
    return c.slice(st, k as usize + needle.len());
}

// A function with `@target_feature(cpu::X86_64_V3)` in a baseline build uses the AVX entries and is
// compiled for AVX2; a baseline function of the same build splits the same operation into SSE chunks.
@test
fn each_function_plans_with_its_own_features() {
    let c = h::compile_c_arch(
        "import std::cpu;\n@arch(x86_64)\n@target_feature(cpu::X86_64_V3)\nfn wide(a: f32x8, b: f32x8) f32x8 {\n    return a + b;\n}\nfn base(a: f32x8, b: f32x8) f32x8 {\n    return a + b;\n}\n@arch(x86_64)\n@target_feature(cpu::X86_64_V4)\nfn wide4(a: f32x16, b: f32x16) f32x16 {\n    return a * b;\n}\nfn main() i32 {\n    let v = f32x8::splat(1.0);\n    let z = f32x16::splat(1.0);\n    return base(v, v).get(0) as i32 + unsafe wide(v, v).get(0) as i32 + unsafe wide4(z, z).get(0) as i32 - 5;\n}\n",
        0,
    );
    assert(c.ok(), "the program builds");
    let code = unsafe str::from_cstr(c.code);
    let w = fn_body(code, "wide");
    let b = fn_body(code, "base");
    assert(w.contains("__sc_si_x86_64__add_f32x8(") && !w.contains("add_f32x4("), "the AVX entry");
    assert(b.contains("__sc_si_x86_64__add_f32x4(") && !b.contains("add_f32x8("), "two SSE chunks");
    // On AVX-512 the planner prefers 256-bit entries (`--simd-width=512` lifts it).
    let w4 = fn_body(code, "wide4");
    assert(w4.contains("__sc_si_x86_64__mul_f32x8(") && !w4.contains("mul_f32x16("), "two 256-bit chunks");
    // The features beyond the host platform's baseline (macOS: `core2`).
    let wl = line_of(code, "__wide(__sc_v8_f32 a, __sc_v8_f32 b) {");
    assert(
        wl.starts_with("__attribute__((target(\"") && wl.contains("avx2,fma,bmi,bmi2,f16c,lzcnt,movbe\"))) "),
        "the level's C target",
    );
    assert(
        !line_of(code, "__base(__sc_v8_f32 a, __sc_v8_f32 b) {").starts_with("__attribute__"),
        "none on a baseline function",
    );
}

// Every binding that reads or writes memory through a pointer states its bytes, or that it touches its
// active lanes only.
@test
fn immintrin_memory_bindings_state_their_range() {
    let text = cli::read_text("ffi/immintrin.spc");
    let mut prev = String::new();
    let mut n: u32 = 0;
    for line in text.lines() {
        let l = line.trim();
        if l.starts_with("pub fn _mm") && (l.contains("load") || l.contains("store") || l.contains("gather") || l.contains(
            "scatter",
        )) {
            n += 1;
            // A masked or indexed access touches its active lanes; another one its register's bytes
            // (`loadl`/`storel`: the low 8).
            let lanes = l.contains("mask") || l.contains("gather") || l.contains("scatter");
            let bytes = if l.contains("loadl") || l.contains("storel") {
                8;
            } else if l.starts_with("pub fn _mm512") {
                64;
            } else if l.starts_with("pub fn _mm256") {
                32;
            } else {
                16;
            };
            let want = format("@{}(p, {})", pick(l.contains("load"), "reads", "writes"), bytes);
            let ok = pick(lanes, prev.as_str().contains("@lane_access"), prev.as_str().contains(want.as_str()));
            if !ok {
                eprintln("no memory annotation: {}", l);
            }
            assert(ok, "a memory binding states its range");
        }
        if l.starts_with("@") {
            prev.push_str(l);
        } else {
            prev.clear();
        }
    }
    assert(n > 40, "the bindings were read");
}

// The emitted tree of `src` built with `flags`: its manifest and main.c.
fn emitted(src: str, flags: str) String {
    let p = cli::proj_new();
    p.mkfile("main.spc", src);
    let r = p.compile_flags(flags, "main.spc");
    assert(r.ok(), flags);
    let root = p.dir();
    let mut t = cli::read_text(format("{}/build/debug/raw/__sc_manifest", root).as_str());
    t.push_str(cli::read_text(format("{}/build/debug/raw/main.c", root).as_str()).as_str());
    return t;
}

@test
fn a_program_without_vectors_emits_the_same_c() {
    let x86 = "--arch=x86_64 --target=linux";
    let src = "fn main(args: Vector<str>) i32 {\n    let v = [1, 2, 3];\n    return unsafe v[args.len() % 3] - 2;\n}\n";
    let a = emitted(src, x86);
    assert(
        a.len() != 0 && a.as_str() == emitted(src, "--arch=x86_64 --target=linux --target-cpu=x86-64-v3").as_str(),
        "the level changes nothing",
    );
    let vsrc = "fn main(args: Vector<str>) i32 {\n    let v = f32x4::splat(args.len() as f32);\n    return (v + v).get(0) as i32 - 2;\n}\n";
    assert(emitted(vsrc, x86).contains("__sc_si_x86_64__add_f32x4"), "a vector operation calls its entry");
}

// The project of a build of `src` with `flags`.
fn vector_build(src: str, flags: str) cli::Proj {
    let p = cli::proj_new();
    p.mkfile("main.spc", src);
    let r = p.compile_flags(flags, "main.spc");
    assert(r.ok(), flags);
    return p;
}

// The C definition of vector struct `name` that build `p` emitted.
fn vector_def(p: &cli::Proj, name: str) String {
    return cli::read_text(format("{}/build/debug/raw/__sc_t/{}.h", p.dir(), name).as_str());
}

// A build whose own features hold AVX (AVX-512F) keeps a 32-byte (64-byte) vector in one C vector,
// which the C ABI passes in one register, at the layout's alignment of 16; a narrower build names the
// 16-byte chunks.
@test
fn a_wide_vector_is_one_c_vector_where_the_build_has_its_register() {
    let src = "fn main(args: Vector<str>) i32 {\n    let v = f32x8::splat(args.len() as f32);\n    let w = f32x16::splat(2.0);\n    return (v + v).get(0) as i32 + (w + w).get(0) as i32 - 6;\n}\n";
    let pb = vector_build(src, "--arch=x86_64 --target=linux");
    let base = vector_def(&pb, "__sc_v8_f32");
    assert(base.contains("__sc_v4_f32 c[2];"), "the baseline names the chunks");
    assert(!base.contains("vector_size(32)"), "the baseline has no 32-byte vector");
    let avx = vector_build(src, "--arch=x86_64 --target=linux --target-cpu=x86-64-v3");
    let v3 = vector_def(&avx, "__sc_v8_f32");
    assert(
        v3.contains("typedef float __sc_g8_f32 __attribute__((vector_size(32), aligned(16)));"),
        "AVX: a 32-byte vector type",
    );
    assert(v3.contains("__sc_g8_f32 l;"), "AVX: one 32-byte vector");
    assert(!v3.contains(" c["), "AVX: no chunks");
    let v3w = vector_def(&avx, "__sc_v16_f32");
    assert(v3w.contains("__sc_v4_f32 c[4];"), "AVX: a 64-byte vector keeps its chunks");
    let p4 = vector_build(src, "--arch=x86_64 --target=linux --target-cpu=x86-64-v4");
    let v4 = vector_def(&p4, "__sc_v16_f32");
    assert(v4.contains("__attribute__((vector_size(64), aligned(16)))"), "AVX-512F: one 64-byte vector");
    assert(!v4.contains(" c["), "AVX-512F: no chunks");
}

const RELEASE: [str; 1] = ["--profile=release"];

const fn pick<T>(c: bool, a: T, b: T) T {
    if c {
        return a;
    }
    return b;
}

// Kernel `k` of `src` (one `@c.noinline` function per kernel, `fn k` renamed) lowers to assembly holding
// each mnemonic of `want` and none of `avoid`; `flags` are the build's. A kernel that takes a `[]mut T`
// has its body in `main__k__r` (the split view ABI); `main__k` only forwards to it.
fn kernel_asm(label: str, src: str, flags: []str, want: []str, avoid: []str) {
    let d = h::asm_check(
        format(
            "import std::simd;\nimport std::cpu;\n@c.noinline\n{}fn main(args: Vector<str>) i32 {{\n    return 0;\n}}\n",
            src,
        ).as_str(),
        flags,
        pick(src.contains("[]mut "), "main__k__r", "main__k"),
        want,
        avoid,
    );
    if d.len() != 0 {
        eprintln("{}: {}", label, d.as_str());
    }
    assert(d.len() == 0, label);
}

// Kernels built as one program: each `fn k` of a source is renamed `k<i>`, with `@c.noinline`.
struct Kernels {
    decls: String,
    labels: Vector<String>,
    want: Vector<Vector<String>>,
    avoid: Vector<Vector<String>>,
}

extend Kernels {
    fn new() Kernels {
        return Kernels {
            decls: String::new(),
            labels: Vector::<String>::new(),
            want: Vector::<Vector<String>>::new(),
            avoid: Vector::<Vector<String>>::new(),
        };
    }

    // Kernel `k` of `src` lowers to assembly holding each mnemonic of `want` and none of `avoid`.
    fn add(self: &mut Kernels, label: str, src: str, want: []str, avoid: []str) {
        let name = format("k{}", self.labels.len());
        self.decls.format_into(
            "@c.noinline\n{}",
            String::from_str(src).replace("fn k(", format("fn {}(", name.as_str()).as_str()).as_str(),
        );
        self.labels.push(String::from_str(label));
        let mut w = Vector::<String>::new();
        for x in want {
            w.push(String::from_str(x));
        }
        self.want.push(w);
        let mut a = Vector::<String>::new();
        for x in avoid {
            a.push(String::from_str(x));
        }
        self.avoid.push(a);
    }

    // Build every kernel under the release profile, then check each one's assembly. A kernel that takes
    // a `[]mut T` has its body in `main__k<i>__r` (the split view ABI); `main__k<i>` only forwards to it.
    fn run(self: &Kernels) {
        let src = format(
            "import std::simd;\nimport std::cpu;\n{}fn main(args: Vector<str>) i32 {{\n    return 0;\n}}\n",
            self.decls.as_str(),
        );
        let ops: []str = RELEASE;
        let b = h::diff_build(src.as_str(), ops);
        if !b.built {
            eprintln("{}", b.diag.as_str());
        }
        assert(b.built, "the kernels build");
        let mut code = String::new();
        let e = h::asm_text(&b, ops, "main__k0", &mut code);
        assert(e.len() == 0, e.as_str());
        let mut failed = false;
        for i in 0..self.labels.len() {
            let mut fname = format("main__k{}", i);
            if code.as_str().contains(format("main__k{}__r", i).as_str()) {
                fname.push_str("__r");
            }
            let label = self.labels.at(i).as_str();
            for w in 0..self.want.at(i).len() {
                let d = h::asm_match(code.as_str(), fname.as_str(), [self.want.at(i).at(w).as_str()], []);
                if d.len() != 0 {
                    eprintln("{}: {}", label, d.as_str());
                    failed = true;
                }
            }
            for a in 0..self.avoid.at(i).len() {
                let d = h::asm_match(code.as_str(), fname.as_str(), [], [self.avoid.at(i).at(a).as_str()]);
                if d.len() != 0 {
                    eprintln("{}: {}", label, d.as_str());
                    failed = true;
                }
            }
        }
        assert(!failed, "every kernel lowers to its instructions");
    }
}

// Each level's kernels lower to its instructions: SSE at the baseline, AVX2 and FMA in an
// `x86-64-v3` function, AVX-512 (mask registers, compress, 512-bit arithmetic with
// `--simd-width=512`) in an `x86-64-v4` one; a baseline function names no AVX register.
@test
fn operations_lower_to_their_instructions() {
    if !x86_host() {
        return;
    }
    let mut ks = Kernels::new();
    // A run with more features (`SC_SIMD_FEATURES`) builds every function with them: no baseline one.
    let more = stdlib::getenv("SC_SIMD_FEATURES");
    let base = more == null || unsafe *more == 0 as char;
    if base {
        ks.add("f32x4 add", "fn k(a: f32x4, b: f32x4) f32x4 {\n    return a + b;\n}\n", ["addps"], ["%ymm", "%zmm"]);
    }
    if base {
        ks.add(
            "u8x16 compare to a mask",
            "fn k(a: u8x16, b: u8x16) u64 {\n    return a.equal(b).to_bits();\n}\n",
            ["pcmpeqb", "pmovmskb"],
            ["%ymm"],
        );
    }
    let v3 = "@arch(x86_64)\n@target_feature(cpu::X86_64_V3)\n";
    ks.add(
        "f32x8 add",
        format("{}fn k(a: f32x8, b: f32x8) f32x8 {{\n    return a + b;\n}}\n", v3).as_str(),
        ["vaddps", "%ymm"],
        [],
    );
    ks.add(
        "fma",
        format("{}fn k(a: f32x8, b: f32x8) f32x8 {{\n    return a.fma(b, a);\n}}\n", v3).as_str(),
        ["vfmadd"],
        [],
    );
    // Under run features with AVX-512BW (an `x86-64-v4` run) the comparison gives a mask register.
    let src = format("{}fn k(a: u8x32, b: u8x32) u64 {{\n    return a.equal(b).to_bits();\n}}\n", v3);
    if cf::has(se::run_features(true), cf::find_variant("Avx512bw") as usize) {
        ks.add("u8x32 compare to a mask", src.as_str(), ["vpcmpeqb", "%k", "kmov"], ["vpmovmskb"]);
    } else {
        ks.add("u8x32 compare to a mask", src.as_str(), ["vpcmpeqb", "vpmovmskb"], []);
    }
    ks.add(
        "gather",
        format(
            "{}fn k(s: []f32, x: u32x8) f32x8 {{\n    return simd::gather(s, x, Mask::<8>::splat(true), f32x8::splat(0.0));\n}}\n",
            v3,
        ).as_str(),
        ["vgatherqps"],
        [],
    );
    let v4 = "@arch(x86_64)\n@target_feature(cpu::X86_64_V4)\n";
    ks.add(
        "compress through a mask register",
        format(
            "{}fn k(m: u64, a: i32x16, b: i32x16) i32x16 {{\n    return simd::compress(Mask::<16>::from_bits_truncate(m), a, b);\n}}\n",
            v4,
        ).as_str(),
        ["vpcompressd", "%k"],
        [],
    );
    ks.add(
        "compress_store through a masked store",
        format(
            "{}fn k(s: []mut i32, m: u64, a: i32x16) usize {{\n    return simd::compress_store(s, 0, Mask::<16>::from_bits_truncate(m), a);\n}}\n",
            v4,
        ).as_str(),
        ["vpcompressd", "vmovdqu32", "%k"],
        [],
    );
    ks.add(
        "a stored comparison chooses through a mask register",
        format("{}fn k(a: i32x8, b: i32x8) i32x8 {{\n    let m = a.less_than(b);\n    return m.choose(a, b);\n}}\n", v4).as_str(),
        ["vpcmpd", "%k"],
        [],
    );
    if base {
        ks.add(
            "a baseline function beside an AVX2 one splits into SSE",
            "@arch(x86_64)\n@target_feature(cpu::X86_64_V3)\nfn w(a: f32x8) f32x8 {\n    return a + a;\n}\nfn k(a: f32x8, b: f32x8) f32x8 {\n    return a + b + unsafe w(a);\n}\n",
            ["addps"],
            ["%ymm", "%zmm"],
        );
    }
    ks.add(
        "a comparison into a mask register",
        format("{}fn k(a: i32x8, b: i32x8) u64 {{\n    return a.less_than(b).to_bits();\n}}\n", v4).as_str(),
        ["vpcmpd", "%k", "kmov"],
        ["vpmovmskb", "vmovmskps"],
    );
    ks.run();
    kernel_asm(
        "512 bits with --simd-width=512",
        format("{}fn k(a: f32x16, b: f32x16) f32x16 {{\n    return a * b;\n}}\n", v4).as_str(),
        ["--profile=release", "--simd-width=512"],
        ["%zmm"],
        [],
    );
}

// `std::simd::x86` against scalar models, each where this machine has its features.
@test
fn x86_operations_match_models() {
    if !x86_host() {
        return;
    }
    let src = M"(import std::cpu;
import std::cpu::detect;
import std::simd::x86;

fn clmul_model(a: u64, b: u64) u64 {
    let mut r: u64 = 0;
    for i in 0..64u64 {
        if (b >> i & 1) != 0 {
            r ^= a << i;
        }
    }
    return r;
}

fn pick(c: bool, a: i32, b: i32) i32 {
    if c {
        return a;
    }
    return b;
}

fn gfmul_model(a: u8, b: u8) u8 {
    let mut x = a as u32;
    let mut r: u32 = 0;
    for i in 0..8u32 {
        if (b as u32 >> i & 1) != 0 {
            r ^= x;
        }
        x = x << 1;
        if (x & 256) != 0 {
            x ^= 0x11B;
        }
    }
    return r as u8;
}

fn main(args: Vector<str>) i32 {
    let k = args.len() as u8;
    let mut a: [u8; 16] = [0; 16];
    let mut b: [u8; 16] = [0; 16];
    for i in 0..16 {
        unsafe a[i] = (i as u32 * 37 + k as u32 * 11) as u8 ^ 0xA5;
        unsafe b[i] = (i as u32 * 101 + k as u32 * 3) as u8 ^ 0x3C;
    }
    let va = u8x16::from_array(a);
    let vb = u8x16::from_array(b);
    // sad
    let s = x86::sad_u8(va, vb);
    for h in 0..2 {
        let mut t: u64 = 0;
        for i in 0..8 {
            let x = unsafe a[h * 8 + i] as i32 - unsafe b[h * 8 + i] as i32;
            t += pick(x < 0, -x, x) as u64;
        }
        assert(s[h] == t, "sad_u8");
    }
    // madd
    let ia = va.bitcast::<i16, 8>();
    let ib = vb.bitcast::<i16, 8>();
    let m = x86::madd(ia, ib);
    for i in 0..4 {
        let w = (ia[2 * i] as i64 * ib[2 * i] as i64 + ia[2 * i + 1] as i64 * ib[2 * i + 1] as i64) as u64 as u32 as i32;
        assert(m[i] == w, "madd");
    }
    if detect::has(cpu::Feature::Ssse3) {
        let d = unsafe x86::maddubs(va, vb.bitcast::<i8, 16>());
        for i in 0..8 {
            let w = unsafe a[2 * i] as i32 * (unsafe b[2 * i] as i8) as i32 + unsafe a[2 * i + 1] as i32 * (unsafe b[2 * i + 1] as i8) as i32;
            assert(d[i] as i32 == pick(w > 32767, 32767, pick(w < -32768, -32768, w)), "maddubs");
        }
    }
    if detect::has(cpu::Feature::Pclmulqdq) {
        let qa = va.bitcast::<u64, 2>();
        let qb = vb.bitcast::<u64, 2>();
        let r = unsafe x86::clmul::<0x11>(qa, qb);
        assert(r[0] == clmul_model(qa[1], qb[1]), "clmul, low half of the product");
    }
    if detect::has(cpu::Feature::Gfni) {
        let g = unsafe x86::gf2p8mul(va, vb);
        for i in 0..16 {
            assert(g[i] == gfmul_model(unsafe a[i], unsafe b[i]), "gf2p8mul");
        }
    }
    return 0;
}
)";
    h::expect_exit("std::simd::x86", src, 0);
}

// On AVX-512 hardware, `x86-64-v4` builds that prefer 256-bit and 512-bit entries give the same
// results; elsewhere the check is not run (the entries' instructions are checked above).
@test
fn preferred_widths_agree() {
    if !x86_host() || !detect::has_level(cpu::Level::V4) {
        return;
    }
    h::expect_same_output(
        "simd-width",
        "import std::simd;\nfn main(args: Vector<str>) i32 {\n    let k = args.len() as f32;\n    let mut a = [0.0f32; 64];\n    for i in 0..64 {\n        unsafe a[i] = i as f32 * 0.37 - k;\n    }\n    let x = simd::load::<f32, 16>(a, 0);\n    let y = simd::load::<f32, 16>(a, 32);\n    let m = x.less_than(y);\n    println(\"{} {} {}\", simd::reduce_add_tree(x * y + x), m.count(), simd::reduce_max_num(m.choose(x, y)));\n    let b = simd::load::<f32, 16>(a, 8).cast::<i32>();\n    println(\"{}\", simd::reduce_add(b.wrapping_mul(b)));\n    return 0;\n}\n",
        ["--target-cpu=x86-64-v4", "--simd-width=256"],
        ["--target-cpu=x86-64-v4", "--simd-width=512"],
    );
    h::expect_same_output(
        "the lane loops",
        "import std::simd;\nfn main(args: Vector<str>) i32 {\n    let k = args.len() as f32;\n    let x = f32x16::splat(k) * f32x16::splat(0.5);\n    println(\"{}\", simd::reduce_add_tree(x + x));\n    return 0;\n}\n",
        ["--target-cpu=x86-64-v4", "--simd-width=512"],
        ["--target-cpu=x86-64-v4", "SC_SIMD_SCALAR=1"],
    );
}

// Every operation of `std::simd::x86` compiles under its features (one function holds them all). The
// whole module's units compile: about 90 s in a full CI shard, so it takes the long timeout.
@test(timeout = 300)
fn x86_operations_compile() {
    if !x86_host() {
        return;
    }
    let b = h::diff_build(
        M"(import std::cpu;
import std::simd::x86;

@arch(x86_64)
@target_feature([cpu::Feature::Avx512vnni, cpu::Feature::Avx512vbmi, cpu::Feature::Avx512cd, cpu::Feature::Vaes, cpu::Feature::Vpclmulqdq, cpu::Feature::Gfni, cpu::Feature::Aesni, cpu::Feature::Pclmulqdq])
fn all(k: u8) u64 {
    let b = u8x16::splat(k);
    let y = u8x32::splat(k);
    let z = u8x64::splat(k);
    let q = u64x2::splat(k as u64);
    let i = i32x16::splat(k as i32);
    let u = u32x16::splat(k as u32);
    let w = i16x32::splat(k as i16);
    let mut t = x86::maddubs(b, b.bitcast::<i8, 16>())[0] as u64 + x86::madd(i16x8::splat(k as i16), i16x8::splat(2))[0] as u64;
    t += x86::sad_u8(b, b)[0] + x86::clmul::<0x11>(q, q)[1];
    t += (x86::aesenc(b, b)[0] ^ x86::aesenclast(b, b)[1] ^ x86::aesdec(b, b)[2] ^ x86::aesdeclast(b, b)[3]) as u64;
    t += (x86::aesenc_x2(y, y)[0] ^ x86::aesenclast_x2(y, y)[1] ^ x86::aesdec_x2(y, y)[2] ^ x86::aesdeclast_x2(y, y)[3]) as u64;
    t += (x86::aesenc_x4(z, z)[0] ^ x86::aesenclast_x4(z, z)[1] ^ x86::aesdec_x4(z, z)[2] ^ x86::aesdeclast_x4(z, z)[3]) as u64;
    t += (x86::gf2p8affine::<3>(b, q)[0] ^ x86::gf2p8mul(b, b)[1]) as u64;
    t += x86::dpbusd(i, z, z.bitcast::<i8, 64>())[0] as u64 + x86::dpwssd(i, w, w)[1] as u64;
    t += x86::permutex2var_i32(i, u, i)[0] as u64 + x86::permutex2var_i16(w, u16x32::splat(1), w)[0] as u64;
    t += x86::permutex2var_u8(z, z, z)[0] as u64 + x86::permutex2var_i64(i64x8::splat(1), u64x8::splat(2), i64x8::splat(3))[0] as u64;
    t += x86::ternarylogic::<0x96>(u, u, u)[0] as u64 + x86::conflict_u32(u)[1] as u64 + x86::conflict_u64(u64x8::splat(1))[2];
    return t;
}

fn main(args: Vector<str>) i32 {
    return pick(args.len() == 9, unsafe all(1) as i32, 0);
}

fn pick(c: bool, a: i32, b: i32) i32 {
    if c {
        return a;
    }
    return b;
}
)",
        [],
    );
    if !b.built {
        eprintln("{}", b.diag.as_str());
    }
    assert(b.built, "std::simd::x86 compiles");
}
