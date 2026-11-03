// The native backend: LIR text compiles to an object, which links with a C driver and runs, on the host
// and for wasm32 (with a wasi-sdk in WASI_SDK_PATH and wasmtime on the PATH, as the wasm lane has).
import lir::ir as *;
import lir::parse as lparse;
import lir::verify as verify;
import target::native as nat;
import target::table as tgt;
import target::win64 as w64;
import codegen::abi as ab;
import tests::cli_harness as cli;
import std::platform::fs;
import std::platform::process;
import stdio;
import stdlib;
import module::loader;

// The package options a test may set (`object_of`): sibling calls (`Package.tail`), 32-byte vectors
// (`Package.vector`: x86-64's ymm registers with AVX2), binary16 instructions (`Package.half`: arithmetic
// on macOS arm64, whose every processor has FEAT_FP16, else conversions), 64-byte vectors (x86-64's zmm
// registers with AVX-512), `popcnt`, SSE4.1's roundings (`Package.sse41`), arm64's LSE atomics and RCpc
// acquire loads (`Package.lse`, `Package.rcpc`); equal edges of a body sharing one record, as the
// optimizer's rewrites may leave them (`SHARE`); no frame pointer kept (`Package.omit_fp`); and a fused
// multiply-add (`Package.fma`: x86-64's FMA3).
const TAIL: u32 = 1;
const WIDE: u32 = 2;
const HALF: u32 = 4;
const Z512: u32 = 8;
const POPCNT: u32 = 16;
const SSE41: u32 = 32;
const LSE: u32 = 64;
const RCPC: u32 = 128;
const SHARE: u32 = 256;
const OMIT_FP: u32 = 512;
const FMA: u32 = 1024;

// Compile LIR `text` natively on the host, link it with C `driver` and run it; the exit code, or -1 when
// a step failed (the failure on stderr). 0 on a host without a native backend.
fn run_native(text: str, driver: str) i32 {
    return run_native_with(text, driver, 0);
}

// `run_native` with package options `opts` (TAIL, WIDE, HALF, Z512, POPCNT).
fn run_native_with(text: str, driver: str, opts: u32) i32 {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return 0;
    }
    return run_lir(text, driver, tgt::host_os(), tgt::host_isa(), unsafe str::from_cstr(cli::cc_name()), "", opts);
}

// `run_native` with 32-byte vectors on an x86-64 host: the driver's `main` (`int main(void) {`) returns 0
// first on a processor without AVX2. 0 on another host.
fn run_wide(text: str, driver: str) i32 {
    if tgt::host_isa() != tgt::axis_index("x86_64", true) {
        return 0;
    }
    let head = "int main(void) {\n";
    let at = driver.find(head);
    assert(at >= 0, "the driver's main");
    let d = format(
        "{}{}  if (!__builtin_cpu_supports(\"avx2\")) return 0;\n{}",
        driver.slice(0, at as usize),
        head,
        driver.slice(at as usize + head.len(), driver.len()),
    );
    return run_native_with(text, &d, WIDE);
}

// `run_native` with `popcnt` on an x86-64 host: the driver's `main` returns 0 first on a processor without
// it. 0 on another host.
fn run_popcnt(text: str, driver: str) i32 {
    return run_x64_feature(text, driver, "popcnt", POPCNT);
}

// `run_native` with SSE4.1 on an x86-64 host, as `run_popcnt`.
fn run_sse41(text: str, driver: str) i32 {
    return run_x64_feature(text, driver, "sse4.1", SSE41);
}

// `run_native` with package option `opt` on an x86-64 host: the driver's `main` returns 0 first on a
// processor without feature `name` (`__builtin_cpu_supports`). 0 on another host.
fn run_x64_feature(text: str, driver: str, name: str, opt: u32) i32 {
    if tgt::host_isa() != tgt::axis_index("x86_64", true) {
        return 0;
    }
    let head = "int main(void) {\n";
    let at = driver.find(head);
    assert(at >= 0, "the driver's main");
    let d = format(
        "{}{}  if (!__builtin_cpu_supports(\"{}\")) return 0;\n{}",
        driver.slice(0, at as usize),
        head,
        name,
        driver.slice(at as usize + head.len(), driver.len()),
    );
    return run_native_with(text, &d, opt);
}

// `run_native` with 32-byte vectors, SSE4.1 and FMA3 on an x86-64 host: the driver's `main` returns 0 first on a
// processor without AVX2 or FMA3. 0 on another host.
fn run_fma(text: str, driver: str) i32 {
    if tgt::host_isa() != tgt::axis_index("x86_64", true) {
        return 0;
    }
    let head = "int main(void) {\n";
    let at = driver.find(head);
    assert(at >= 0, "the driver's main");
    let d = format(
        "{}{}  if (!__builtin_cpu_supports(\"avx2\") || !__builtin_cpu_supports(\"fma\")) return 0;\n{}",
        driver.slice(0, at as usize),
        head,
        driver.slice(at as usize + head.len(), driver.len()),
    );
    return run_native_with(text, &d, WIDE | SSE41 | FMA);
}

// `run_native` with 64-byte vectors on an x86-64 host: under the emulator command `SC_SDE` names (Intel
// SDE, as CI's AVX-512 lane runs), else the driver's `main` returns 0 first on a processor without
// AVX-512 BW. 0 on another host.
fn run_zmm(text: str, driver: str) i32 {
    if tgt::host_isa() != tgt::axis_index("x86_64", true) || !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return 0;
    }
    let sde = stdlib::get_env("SC_SDE").unwrap_or(String::new());
    if sde.len() != 0 {
        let runner = format("{} ", sde.as_str());
        return run_lir(
            text,
            driver,
            tgt::host_os(),
            tgt::host_isa(),
            unsafe str::from_cstr(cli::cc_name()),
            &runner,
            Z512,
        );
    }
    let head = "int main(void) {\n";
    let at = driver.find(head);
    assert(at >= 0, "the driver's main");
    let d = format(
        "{}{}  if (!__builtin_cpu_supports(\"avx512bw\")) return 0;\n{}",
        driver.slice(0, at as usize),
        head,
        driver.slice(at as usize + head.len(), driver.len()),
    );
    return run_native_with(text, &d, Z512);
}

// `run_native` for wasm32, its pointers 4 bytes in place of the text's 8: the wasi-sdk's clang links,
// wasmtime runs. 0 without WASI_SDK_PATH.
fn run_wasm(text: str, driver: str) i32 {
    let sdk = stdlib::get_env("WASI_SDK_PATH").unwrap_or(String::new());
    if sdk.len() == 0 {
        return 0;
    }
    assert(text.starts_with("lir ptr 8\n"), "the text's header");
    let t = format("lir ptr 4\n{}", text.slice(10, text.len()));
    let cc = format("\"{}/bin/clang\" --target=wasm32-wasip1", sdk.as_str());
    return run_lir(&t, driver, tgt::axis_index("wasm", false), tgt::axis_index("wasm32", true), &cc, "wasmtime run ", 0);
}

// Compile LIR `text` for `(os, isa)` into object `obj`, with package options `opts` (TAIL, WIDE, HALF, Z512, POPCNT);
// whether it did (the failure on stderr).
fn object_of(text: str, os: i32, isa: i32, opts: u32, obj: &mut Vector<u8>) bool {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    if q.is_none() {
        eprint("parse: {}\n", err.as_str());
        return false;
    }
    let mut p = q.unwrap();
    p.tail = (opts & TAIL) != 0;
    p.omit_fp = (opts & OMIT_FP) != 0;
    p.popcnt = (opts & POPCNT) != 0;
    p.sse41 = (opts & SSE41) != 0;
    p.lse = (opts & LSE) != 0;
    p.rcpc = (opts & RCPC) != 0;
    p.fma = (opts & FMA) != 0;
    p.bitrev = isa == tgt::axis_index("aarch64", true);
    // The aggregates the backend copies, as a build sets them (`CEmit`).
    p.arg_copy = if tgt::callconv_of(os, isa).arg_copy != 0 {
        tgt::callconv_of(os, isa).arg_copy
    } else {
        tgt::isa(isa).arg_copy
    };
    if (opts & WIDE) != 0 {
        p.vector = 32;
    }
    if (opts & Z512) != 0 {
        p.vector = 64;
    }
    if (opts & HALF) != 0 {
        p.half = if isa == tgt::axis_index("aarch64", true) && os == tgt::axis_index("macos", false) {
            HALF_ARITH
        } else {
            HALF_CVT
        };
    }
    if (opts & SHARE) != 0 {
        for d in 0..p.bodies.len() {
            share_edges(p.bodies.index_mut(d));
        }
    }
    let mut v = verify::Verifier::new();
    for i in 0..p.syms.len() {
        let s = p.syms[i];
        if s.def != NONE && s.kind == SK_FUNC && !v.check(&p, p.spell(s.name), &p.bodies[s.def as usize]) {
            eprint("verify: {}\n", v.err.as_str());
            return false;
        }
    }
    // The thunks `prepare` adds compile too.
    if !nat::prepare(&mut p, os, isa, &mut err) {
        eprint("native: {}\n", err.as_str());
        return false;
    }
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
    if !nat::object(&p, os, isa, fs_[0..fs_.len()], ds[0..ds.len()], "", obj, &mut err) {
        eprint("native: {}\n", err.as_str());
        return false;
    }
    return true;
}

// Each jump's and branch's edge of `b` that equals an earlier one (its target and arguments) takes that
// one's record.
fn share_edges(b: &mut Body) {
    let mut seen = Vector::<u32>::new();
    for k in 0..b.blocks.len() {
        let bk = b.blocks[k];
        if bk.len == 0 {
            continue;
        }
        let at = (bk.start + bk.len - 1) as usize;
        let mut t = b.insts[at];
        if t.op == O_JMP {
            t.a = shared_edge(b, &mut seen, t.a);
        } else if t.op == O_BR {
            t.b = shared_edge(b, &mut seen, t.b);
            t.c = shared_edge(b, &mut seen, t.c);
        }
        b.insts[at] = t;
    }
}

// The edge of `seen` equal to edge `e` of `b`, else `e`, which `seen` takes.
fn shared_edge(b: &Body, seen: &mut Vector<u32>, e: u32) u32 {
    for j in 0..seen.len() {
        let s = seen[j];
        let mut same = b.edge_target(s) == b.edge_target(e) && b.edge_nargs(s) == b.edge_nargs(e);
        for q in 0..b.edge_nargs(e) {
            same = same && b.edge_arg(s, q) == b.edge_arg(e, q);
        }
        if same {
            return s;
        }
    }
    seen.push(e);
    return e;
}

// Compile LIR `text` for `(os, isa)` (with package options `opts`), link it with C `driver` by C compiler
// command `cc` and run the program through command prefix `runner`; the exit code, or -1 when a step
// failed (the failure on stderr).
fn run_lir(text: str, driver: str, os: i32, isa: i32, cc: str, runner: str, opts: u32) i32 {
    let mut obj = Vector::<u8>::new();
    if !object_of(text, os, isa, opts, &mut obj) {
        return -1;
    }
    let dir = format("{}/native_{}", cli::tmp_dir().as_str(), process::pid().unwrap_or(1));
    let _ = fs::mkdir_all(&dir);
    let op = format("{}/lir.o", dir.as_str());
    let cp = format("{}/main.c", dir.as_str());
    let bp = format("{}/prog", dir.as_str());
    let f = stdio::fopen(&op, "wb");
    unsafe stdio::fwrite(obj.as_ptr(), 1, obj.len(), f);
    unsafe stdio::fclose(f);
    let g = stdio::fopen(&cp, "wb");
    unsafe stdio::fwrite(driver.ptr(), 1, driver.len(), g);
    unsafe stdio::fclose(g);
    // The driver may call the C math library: its link flag where the C library does not hold it.
    let mut cmd = format("{} -o \"{}\" \"{}\" \"{}\" {}", cc, bp.as_str(), cp.as_str(), op.as_str(), tgt::os(os).libm);
    if cli::run_with(cmd.cstr(), null, null, null, "") != 0 {
        return -1;
    }
    let mut run = format("{}\"{}\"", runner, bp.as_str());
    let rc = cli::run_with(run.cstr(), null, null, null, "");
    // SC_NATIVE_KEEP keeps the object and the program for a look.
    if stdlib::getenv("SC_NATIVE_KEEP") == null {
        let _ = fs::remove_all(&dir);
    } else {
        eprint("native: kept {}\n", dir.as_str());
    }
    return rc;
}

@test
fn arithmetic_and_a_loop_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @sum_to fn global\nsym @mid fn global\nfn @sum_to\n  sig (i32) -> i64\nb0(v0: i32):\n  v1 = iconst.i64 0\n  v2 = iconst.i32 0\n  v3 = iconst.i32 1\n  jmp b1(v2, v1)\nb1(v4: i32, v5: i64):\n  v6 = icmp.ult v4, v0\n  br v6, b3, b2\nb2:\n  ret v5\nb3:\n  v7 = zext.i64 v4\n  v8 = add.i64 v5, v7\n  v9 = add.i32 v4, v3\n  jmp b1(v9, v8)\nfn @mid\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2, v3 = addo.s.i64 v0, v1\n  br v3, b2, b1\nb1:\n  v4 = iconst.i64 2\n  v5 = sdiv.i64 v2, v4\n  ret v5\nb2:\n  v6 = iconst.i64 -1\n  ret v6\n";
    let drv = "#include <stdint.h>\nint64_t sum_to(int32_t);\nint64_t mid(int64_t, int64_t);\nint main(void) {\n  if (sum_to(10) != 45) return 1;\n  if (mid(10, 31) != 20) return 2;\n  if (mid(INT64_MAX, 1) != -1) return 3;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// The system operations run as the processor's instructions: the spin hint and the barriers, the cycle
// counter, the floating-point control state against the driver's own read of it; on x86-64 CPUID and
// XGETBV against the driver's, on arm64 RDSVL where SME is. wasm32 has the spin hint and the barriers.
@test
fn system_operations_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let common = "lir ptr 8\nsym @sysops fn global\nsym @spin fn global\nsym @machine fn global\nfn @sysops\n  sig (ptr) -> i64\nb0(v0: ptr):\n  sys.spin\n  sys.barrier\n  sys.keep v0\n  sys.fpsave v0\n  v1 = sys.cycles.i64\n  v2 = sys.cycles.i64\n  v3 = sub.i64 v2, v1\n  ret v3\nfn @spin\n  sig (ptr) -> void\nb0(v0: ptr):\n  sys.spin\n  sys.barrier\n  sys.keep v0\n  ret\n";
    let x64 = "fn @machine\n  sig (ptr, i32) -> i64\nb0(v0: ptr, v1: i32):\n  v2 = iconst.i32 0\n  sys.cpuid v0, v1, v2\n  v3 = iconst.i64 0\n  v4 = icmp.ne v1, v2\n  br v4, b2, b1\nb1:\n  ret v3\nb2:\n  v5 = sys.xgetbv.i64 v2\n  ret v5\n";
    let a64 = "fn @machine\n  sig (ptr, i32) -> i64\nb0(v0: ptr, v1: i32):\n  v2 = iconst.i64 0\n  v3 = iconst.i32 0\n  v4 = icmp.ne v1, v3\n  br v4, b2, b1\nb1:\n  ret v2\nb2:\n  v5 = sys.svl.i64\n  ret v5\n";
    let drv = M"(#include <stdint.h>
#include <string.h>
#if defined(__APPLE__) && defined(__aarch64__)
#include <sys/sysctl.h>
#elif defined(__linux__) && defined(__aarch64__)
#include <sys/auxv.h>
#endif
int64_t sysops(void *);
void spin(void *);
int64_t machine(void *, int32_t);
int main(void) {
  uint64_t buf[2] = {0, 0};
#if defined(__x86_64__) || defined(__aarch64__)
  if (sysops(buf) < 0) return 1;
#endif
#if defined(__x86_64__)
  uint32_t m = 0;
  uint16_t cw = 0;
  __asm__ volatile("stmxcsr %0" : "=m"(m));
  __asm__ volatile("fnstcw %0" : "=m"(cw));
  if ((uint32_t)buf[0] != m || (uint16_t)(buf[0] >> 32) != cw) return 2;
  uint32_t r[4] = {0, 0, 0, 0};
  uint32_t a, b, c, d;
  (void)machine(r, 0);
  __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(0), "c"(0));
  if (r[0] != a || r[1] != b || r[2] != c || r[3] != d) return 3;
  (void)machine(r, 1);
  if ((r[2] >> 27 & 1) != 0) {
    uint32_t lo, hi;
    __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    if ((uint64_t)machine(r, 1) != ((uint64_t)hi << 32 | lo)) return 4;
  }
#elif defined(__aarch64__)
  uint64_t f = 0;
  __asm__ volatile("mrs %0, fpcr" : "=r"(f));
  if (buf[0] != f) return 2;
  int sme = 0;
#if defined(__APPLE__)
  size_t n = sizeof(sme);
  if (sysctlbyname("hw.optional.arm.FEAT_SME", &sme, &n, 0, 0) != 0) sme = 0;
#elif defined(__linux__)
  sme = (getauxval(AT_HWCAP2) >> 23 & 1) != 0;
#endif
  if (sme) {
    uint64_t v = 0;
    __asm__ volatile(".arch_extension sme\n\trdsvl %0, #1" : "=r"(v));
    if ((uint64_t)machine(buf, 1) != v || v == 0) return 3;
  }
#else
  spin(buf);
#endif
  return 0;
}
)";
    let isa = tgt::isa(tgt::host_isa()).name;
    if isa == "x86_64" || isa == "aarch64" {
        let text = format(
            "{}{}",
            common,
            if isa == "x86_64" {
                x64
            } else {
                a64
            },
        );
        assert_eq(run_native(&text, drv), 0);
    }
    let w = "lir ptr 8\nsym @spin fn global\nfn @spin\n  sig (ptr) -> void\nb0(v0: ptr):\n  sys.spin\n  sys.barrier\n  sys.keep v0\n  ret\n";
    assert_eq(run_wasm(w, drv), 0);
}

@test
fn wide_integers_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @div fn global\nsym @mul fn global\nsym @shr fn global\nfn @div\n  sig (i64, i64, i64, ptr) -> i64\nb0(v0: i64, v1: i64, v2: i64, v3: ptr):\n  v4 = zext.i128 v0\n  v5 = wconst.i128 0x40, 0x0\n  v6 = shl.i128 v4, v5\n  v7 = zext.i128 v1\n  v8 = or.i128 v6, v7\n  v9 = zext.i128 v2\n  v10 = urem.i128 v8, v9\n  v11 = trunc.i64 v10\n  store v11, v3 align 3\n  v12 = udiv.i128 v8, v9\n  v13 = trunc.i64 v12\n  ret v13\nfn @mul\n  sig (i64, i64, ptr) -> i64\nb0(v0: i64, v1: i64, v2: ptr):\n  v3 = zext.i128 v0\n  v4 = zext.i128 v1\n  v5 = mul.i128 v3, v4\n  v6 = wconst.i128 0x40, 0x0\n  v7 = lshr.i128 v5, v6\n  v8 = trunc.i64 v7\n  store v8, v2 align 3\n  v9 = trunc.i64 v5\n  ret v9\nfn @shr\n  sig (i64, i64, i32) -> i64\nb0(v0: i64, v1: i64, v2: i32):\n  v3 = sext.i128 v1\n  v4 = wconst.i128 0x40, 0x0\n  v5 = shl.i128 v3, v4\n  v6 = zext.i128 v0\n  v7 = or.i128 v5, v6\n  v8 = zext.i128 v2\n  v9 = ashr.i128 v7, v8\n  v10 = trunc.i64 v9\n  ret v10\n";
    // Microsoft x64 code divides through the runtime's `__sc_<name>` (`std::rt::builtins`), which a C
    // driver alone does not link: the driver defines them.
    let drv = "#include <stdint.h>\n#ifdef _WIN32\ntypedef unsigned __int128 u128;\nvoid __sc_udivti3(u128 *o, const u128 *a, const u128 *b) { *o = *a / *b; }\nvoid __sc_umodti3(u128 *o, const u128 *a, const u128 *b) { *o = *a % *b; }\n#endif\nint64_t div(int64_t, int64_t, int64_t, int64_t *);\nint64_t mul(int64_t, int64_t, int64_t *);\nint64_t shr(int64_t, int64_t, int32_t);\nint main(void) {\n  int64_t r = 0;\n  if (div(3, 5, 7, &r) != (int64_t)(((unsigned __int128)3 << 64 | 5) / 7) || r != (int64_t)(((unsigned __int128)3 << 64 | 5) % 7)) return 1;\n  int64_t h = 0;\n  if (mul(-1, -1, &h) != 1 || h != -2) return 2;\n  if (shr(0, -2, 65) != -1 || shr(0, 4, 1) != 0 || shr(0, 4, 64) != 4 || shr(8, 0, 3) != 1) return 3;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A loop header's parameter keeps its home past its last use to the back edge, which writes it again;
// here its last use is the checked increment in the back edge's own block.
@test
fn loop_parameters_keep_their_homes() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @id fn global\nsym @f fn global\nfn @f\n  sig (ptr, i64) -> i64\nb0(v0: ptr, v1: i64):\n  v2 = iconst.i64 0\n  v3 = iconst.i64 1\n  jmp b1(v2, v2, v0)\nb1(v4: i64, v5: i64, v6: ptr):\n  v7 = icmp.ult v4, v1\n  br v7, b2, b3\nb2:\n  v8 = load.i64 v6 align 3\n  v9 = call.i64 @id(v8) : (i64) -> i64\n  v10 = add.i64 v5, v9\n  v11 = ptradd v6+8\n  v12, v13 = addo.u.i64 v4, v3\n  br v13, b4, b1(v12, v10, v11)\nb3:\n  ret v5\nb4: cold\n  panic \"attempt to add with overflow\"\n";
    let drv = "#include <stdint.h>\nint64_t f(const int64_t *, int64_t);\nint64_t id(int64_t x) { return x; }\nvoid __sc_panic(const char *m) { (void)m; __builtin_trap(); }\nint main(void) {\n  int64_t a[4] = {1, 2, 3, 4};\n  return f(a, 4) == 10 ? 0 : 1;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Values a loop keeps past their last use in its last block hold their homes over the back edge: a
// later value of that block takes no register or slot of theirs.
@test
fn loop_kept_values_keep_their_homes() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @id fn global\nsym @f fn global\nfn @f\n  sig (ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, i64) -> i64\nb0(v0: ptr, v1: ptr, v2: ptr, v3: ptr, v4: ptr, v5: ptr, v6: ptr, v7: ptr, v8: i64):\n  v9 = iconst.i64 0\n  v10 = iconst.i64 1\n  jmp b1(v9, v9)\nb1(v11: i64, v12: i64):\n  v13 = icmp.ult v11, v8\n  br v13, b2, b3\nb2:\n  v14 = load.i64 v0 align 3\n  v15 = load.i64 v1 align 3\n  v16 = load.i64 v2 align 3\n  v17 = load.i64 v3 align 3\n  v18 = load.i64 v4 align 3\n  v19 = load.i64 v5 align 3\n  v20 = load.i64 v6 align 3\n  v21 = load.i64 v7 align 3\n  v22 = add.i64 v14, v15\n  v23 = add.i64 v22, v16\n  v24 = add.i64 v23, v17\n  v25 = add.i64 v24, v18\n  v26 = add.i64 v25, v19\n  v27 = add.i64 v26, v20\n  v28 = add.i64 v27, v21\n  v29 = add.i64 v12, v28\n  v30 = call.i64 @id(v29) : (i64) -> i64\n  v31 = call.i64 @id(v11) : (i64) -> i64\n  v32 = add.i64 v31, v10\n  jmp b1(v32, v30)\nb3:\n  ret v12\n";
    let drv = "#include <stdint.h>\nint64_t f(const int64_t *, const int64_t *, const int64_t *, const int64_t *, const int64_t *, const int64_t *, const int64_t *, const int64_t *, int64_t);\nint64_t id(int64_t x) { return x; }\nint main(void) {\n  int64_t a[8] = {1, 2, 3, 4, 5, 6, 7, 8};\n  return f(a, a + 1, a + 2, a + 3, a + 4, a + 5, a + 6, a + 7, 3) == 108 ? 0 : 1;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A comparison only branches and selects read, an `and` only tested against 0 (an 8-bit one with the
// bits above its width set in its register), a product added or subtracted, a shifted field masked:
// each folds into its user's instruction where the target has one, with the scalar results.
@test
fn folded_compares_and_fields_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @tst8 fn global\nsym @tst64 fn global\nsym @msub fn global\nsym @madd fn global\nsym @field fn global\nsym @field32 fn global\nsym @spread fn global\nfn @tst8\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = trunc.i8 v0\n  v3 = trunc.i8 v1\n  v4 = and.i8 v2, v3\n  v5 = iconst.i8 0\n  v6 = icmp.eq v4, v5\n  v7 = iconst.i32 7\n  v8 = iconst.i32 9\n  v9 = select.i32 v6, v7, v8\n  ret v9\nfn @tst64\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = and.i64 v0, v1\n  v3 = iconst.i64 0\n  v4 = icmp.ne v2, v3\n  br v4, b1, b2\nb1:\n  v5 = iconst.i64 1\n  ret v5\nb2:\n  v6 = iconst.i64 2\n  ret v6\nfn @msub\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = mul.i64 v1, v2\n  v4 = sub.i64 v0, v3\n  ret v4\nfn @madd\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = mul.i32 v1, v2\n  v4 = add.i32 v0, v3\n  ret v4\nfn @field\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = iconst.i64 12\n  v2 = lshr.i64 v0, v1\n  v3 = iconst.i64 255\n  v4 = and.i64 v2, v3\n  ret v4\nfn @field32\n  sig (i32) -> i32\nb0(v0: i32):\n  v1 = iconst.i32 28\n  v2 = lshr.i32 v0, v1\n  v3 = iconst.i32 15\n  v4 = and.i32 v2, v3\n  ret v4\nfn @spread\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = icmp.slt v0, v1\n  v3 = select.i64 v2, v0, v1\n  v4 = select.i64 v2, v1, v0\n  v5 = sub.i64 v4, v3\n  ret v5\n";
    let drv = "#include <stdint.h>\nint32_t tst8(int32_t, int32_t);\nint64_t tst64(int64_t, int64_t);\nint64_t msub(int64_t, int64_t, int64_t);\nint32_t madd(int32_t, int32_t, int32_t);\nint64_t field(int64_t);\nint32_t field32(int32_t);\nint64_t spread(int64_t, int64_t);\nint main(void) {\n  if (tst8(0x100, 0x1FF) != 7 || tst8(0x101, 0x01) != 9) return 1;\n  if (tst64(INT64_C(1) << 40, INT64_C(1) << 40) != 1 || tst64(INT64_C(1) << 40, 1) != 2) return 2;\n  if (msub(100, 7, 9) != 37 || msub(0, -3, 5) != 15) return 3;\n  if (madd(1, 0x10000, 0x10000) != 1 || madd(-4, 3, 2) != 2) return 4;\n  if (field(INT64_C(0xABCDE123456)) != 0x23 || field(-1) != 255) return 5;\n  if (field32((int32_t)0xF0000000u) != 15 || field32(0x0FFFFFFF) != 0) return 6;\n  if (spread(3, -5) != 8 || spread(-5, 3) != 8) return 7;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// `and`s and `or`s of comparisons fold into chains of conditional comparisons (arm64 `ccmp`, `ccmn` for a
// negative constant): nested, mixed, of 8 and 64 bits, against registers, as a value, a branch's
// condition and a select's.
@test
fn chains_of_compared_flags_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @and3 fn global\nsym @mix fn global\nsym @small fn global\nsym @wide fn global\nsym @brc fn global\nsym @selc fn global\nfn @and3\n  sig (i32, i32, i32) -> i8\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 3\n  v4 = iconst.i32 9\n  v5 = iconst.i32 0\n  v6 = icmp.eq v0, v3\n  v7 = icmp.ult v1, v4\n  v8 = icmp.ne v2, v5\n  v9 = and.i8 v7, v8\n  v10 = and.i8 v6, v9\n  ret v10\nfn @mix\n  sig (i32, i32, i32) -> i8\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 -7\n  v4 = icmp.slt v0, v3\n  v5 = icmp.sgt v1, v2\n  v6 = or.i8 v4, v5\n  v7 = iconst.i32 100\n  v8 = icmp.ule v2, v7\n  v9 = and.i8 v6, v8\n  ret v9\nfn @small\n  sig (i8, i8) -> i8\nb0(v0: i8, v1: i8):\n  v2 = iconst.i8 -3\n  v3 = icmp.sge v0, v2\n  v4 = icmp.ult v1, v0\n  v5 = or.i8 v3, v4\n  ret v5\nfn @wide\n  sig (i64, i64) -> i8\nb0(v0: i64, v1: i64):\n  v2 = iconst.i64 1000000\n  v3 = icmp.ugt v0, v2\n  v4 = icmp.eq v1, v0\n  v5 = and.i8 v3, v4\n  ret v5\nfn @brc\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = iconst.i32 0\n  v3 = icmp.eq v0, v2\n  v4 = icmp.eq v1, v2\n  v5 = or.i8 v3, v4\n  br v5, b1, b2\nb1:\n  v6 = iconst.i32 11\n  ret v6\nb2:\n  v7 = iconst.i32 22\n  ret v7\nfn @selc\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = iconst.i64 5\n  v3 = icmp.sgt v0, v2\n  v4 = icmp.slt v1, v2\n  v5 = and.i8 v3, v4\n  v6 = select.i64 v5, v0, v1\n  ret v6\n";
    let drv = "#include <stdint.h>\nint8_t and3(int32_t, int32_t, int32_t);\nint8_t mix(int32_t, int32_t, int32_t);\nint8_t small(int8_t, int8_t);\nint8_t wide(int64_t, int64_t);\nint32_t brc(int32_t, int32_t);\nint64_t selc(int64_t, int64_t);\nint main(void) {\n  for (int32_t a = -12; a < 12; a++)\n    for (int32_t b = -12; b < 12; b++)\n      for (int32_t c = -2; c < 120; c += 7) {\n        if (and3(a, b, c) != (a == 3 && (uint32_t)b < 9 && c != 0)) return 1;\n        if (mix(a, b, c) != ((a < -7 || b > c) && (uint32_t)c <= 100)) return 2;\n      }\n  for (int32_t a = -128; a < 128; a++)\n    for (int32_t b = -128; b < 128; b += 3)\n      if (small((int8_t)a, (int8_t)b) != (a >= -3 || (uint8_t)b < (uint8_t)a)) return 3;\n  int64_t ws[5] = {0, 1000000, 1000001, INT64_C(1) << 40, -1};\n  for (int i = 0; i < 5; i++)\n    for (int j = 0; j < 5; j++)\n      if (wide(ws[i], ws[j]) != ((uint64_t)ws[i] > 1000000 && ws[j] == ws[i])) return 4;\n  for (int32_t a = -1; a < 2; a++)\n    for (int32_t b = -1; b < 2; b++)\n      if (brc(a, b) != ((a == 0 || b == 0) ? 11 : 22)) return 5;\n  for (int64_t a = 0; a < 10; a++)\n    for (int64_t b = 0; b < 10; b++)\n      if (selc(a, b) != ((a > 5 && b < 5) ? a : b)) return 6;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A bit count of a 32-bit value truncated from a 64-bit one counts the 32 bits only: the register's bits
// above them are not the value's.
@test
fn a_narrow_bit_count_ignores_the_bits_above_it() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @pop32 fn global\nfn @pop32\n  sig (i64) -> i32\nb0(v0: i64):\n  v1 = trunc.i32 v0\n  v2 = popcnt.i32 v1\n  ret v2\n";
    let drv = "#include <stdint.h>\nint32_t pop32(int64_t);\nint main(void) {\n  return pop32(-1) != 32 || pop32(INT64_C(0x500000003)) != 2;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A branch on a float comparison whose sides each return a value returns a select (arm64 `fcmp` with
// `fcsel`, a comparison with zero against #0.0), for every ordered and unordered condition and NaN or
// signed zero operands.
@test
fn float_return_diamonds_select() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @s_olt fn global\nsym @s_ogt fn global\nsym @s_ole fn global\nsym @s_oge fn global\nsym @s_oeq fn global\nsym @s_une fn global\nsym @s_uno fn global\nsym @s_one fn global\nsym @s_ueq fn global\nsym @fneg_abs fn global\nfn @s_olt\n  sig (f64, f64, f64, f64) -> f64\nb0(v0: f64, v1: f64, v2: f64, v3: f64):\n  v4 = fcmp.olt v0, v1\n  br v4, b1, b2\nb1:\n  ret v2\nb2:\n  ret v3\nfn @s_ogt\n  sig (f64, f64, f64, f64) -> f64\nb0(v0: f64, v1: f64, v2: f64, v3: f64):\n  v4 = fcmp.ogt v0, v1\n  br v4, b1, b2\nb1:\n  ret v2\nb2:\n  ret v3\nfn @s_ole\n  sig (f64, f64, f64, f64) -> f64\nb0(v0: f64, v1: f64, v2: f64, v3: f64):\n  v4 = fcmp.ole v0, v1\n  br v4, b1, b2\nb1:\n  ret v2\nb2:\n  ret v3\nfn @s_oge\n  sig (f64, f64, f64, f64) -> f64\nb0(v0: f64, v1: f64, v2: f64, v3: f64):\n  v4 = fcmp.oge v0, v1\n  br v4, b1, b2\nb1:\n  ret v2\nb2:\n  ret v3\nfn @s_oeq\n  sig (f64, f64, f64, f64) -> f64\nb0(v0: f64, v1: f64, v2: f64, v3: f64):\n  v4 = fcmp.oeq v0, v1\n  br v4, b1, b2\nb1:\n  ret v2\nb2:\n  ret v3\nfn @s_une\n  sig (f64, f64, f64, f64) -> f64\nb0(v0: f64, v1: f64, v2: f64, v3: f64):\n  v4 = fcmp.une v0, v1\n  br v4, b1, b2\nb1:\n  ret v2\nb2:\n  ret v3\nfn @s_uno\n  sig (f64, f64, f64, f64) -> f64\nb0(v0: f64, v1: f64, v2: f64, v3: f64):\n  v4 = fcmp.uno v0, v1\n  br v4, b1, b2\nb1:\n  ret v2\nb2:\n  ret v3\nfn @s_one\n  sig (f64, f64, f64, f64) -> f64\nb0(v0: f64, v1: f64, v2: f64, v3: f64):\n  v4 = fcmp.one v0, v1\n  br v4, b1, b2\nb1:\n  ret v2\nb2:\n  ret v3\nfn @s_ueq\n  sig (f64, f64, f64, f64) -> f64\nb0(v0: f64, v1: f64, v2: f64, v3: f64):\n  v4 = fcmp.ueq v0, v1\n  br v4, b1, b2\nb1:\n  ret v2\nb2:\n  ret v3\nfn @fneg_abs\n  sig (f32) -> f32\nb0(v0: f32):\n  v1 = fconst.f32 0x0\n  v2 = fcmp.olt v0, v1\n  br v2, b1, b2\nb1:\n  v3 = fneg.f32 v0\n  ret v3\nb2:\n  ret v0\n";
    let drv = "#include <math.h>\ndouble s_olt(double, double, double, double);\ndouble s_ogt(double, double, double, double);\ndouble s_ole(double, double, double, double);\ndouble s_oge(double, double, double, double);\ndouble s_oeq(double, double, double, double);\ndouble s_une(double, double, double, double);\ndouble s_uno(double, double, double, double);\ndouble s_one(double, double, double, double);\ndouble s_ueq(double, double, double, double);\nfloat fneg_abs(float);\nint main(void) {\n  double v[6] = {0.0, -0.0, 1.0, -2.5, 1e300, NAN};\n  for (int i = 0; i < 6; i++)\n    for (int j = 0; j < 6; j++) {\n      double a = v[i], b = v[j];\n      if (s_olt(a, b, 1.0, 2.0) != ((a < b) ? 1.0 : 2.0)) return 1;\n      if (s_ogt(a, b, 1.0, 2.0) != ((a > b) ? 1.0 : 2.0)) return 2;\n      if (s_ole(a, b, 1.0, 2.0) != ((a <= b) ? 1.0 : 2.0)) return 3;\n      if (s_oge(a, b, 1.0, 2.0) != ((a >= b) ? 1.0 : 2.0)) return 4;\n      if (s_oeq(a, b, 1.0, 2.0) != ((a == b) ? 1.0 : 2.0)) return 5;\n      if (s_une(a, b, 1.0, 2.0) != ((!(a == b)) ? 1.0 : 2.0)) return 6;\n      if (s_uno(a, b, 1.0, 2.0) != ((a != a || b != b) ? 1.0 : 2.0)) return 7;\n      if (s_one(a, b, 1.0, 2.0) != ((a < b || a > b) ? 1.0 : 2.0)) return 8;\n      if (s_ueq(a, b, 1.0, 2.0) != (!(a < b || a > b) ? 1.0 : 2.0)) return 9;\n      float f = (float)a;\n      float w = f < 0.0f ? -f : f;\n      float g = fneg_abs(f);\n      if (!(g == w || (g != g && w != w)) || signbit(g) != signbit(w)) return 20;\n    }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A parameter of 8 or 16 bits that a loop compares and shifts, passed with other bits above its type (C
// passes a 32-bit value): the loop reads it extended (arm64 extends it once on entry).
@test
fn small_parameters_a_loop_compares_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @count fn global\nsym @below fn global\nfn @count\n  sig (ptr, i64, i8) -> i64\nb0(v0: ptr, v1: i64, v2: i8):\n  v3 = iconst.i64 0\n  v4 = iconst.i64 1\n  jmp b1(v3, v3)\nb1(v5: i64, v6: i64):\n  v7 = icmp.ult v5, v1\n  br v7, b2, b3\nb2:\n  v8 = ptradd v0, v5 * 1\n  v9 = load.i8 v8 align 0\n  v10 = icmp.eq v9, v2\n  v11 = zext.i64 v10\n  v12 = add.i64 v6, v11\n  v13 = add.i64 v5, v4\n  jmp b1(v13, v12)\nb3:\n  ret v6\nfn @below\n  sig (ptr, i64, i16) -> i64\nb0(v0: ptr, v1: i64, v2: i16):\n  v3 = iconst.i64 0\n  v4 = iconst.i64 1\n  v5 = iconst.i16 1\n  jmp b1(v3, v3)\nb1(v6: i64, v7: i64):\n  v8 = icmp.ult v6, v1\n  br v8, b2, b3\nb2:\n  v9 = ptradd v0, v6 * 1\n  v10 = load.i8 v9 align 0\n  v11 = zext.i16 v10\n  v12 = lshr.i16 v2, v5\n  v13 = icmp.ult v11, v12\n  v14 = zext.i64 v13\n  v15 = add.i64 v7, v14\n  v16 = add.i64 v6, v4\n  jmp b1(v16, v15)\nb3:\n  ret v7\n";
    let drv = "#include <stdint.h>\nuint64_t count(const uint8_t *, uint64_t, uint32_t);\nuint64_t below(const uint8_t *, uint64_t, uint32_t);\nint main(void) {\n  uint8_t s[256];\n  for (int i = 0; i < 256; i++) s[i] = (uint8_t)(i * 37);\n  for (uint32_t c = 0; c < 256; c += 17) {\n    uint64_t want = 0, under = 0;\n    for (int i = 0; i < 256; i++) {\n      want += s[i] == c;\n      under += s[i] < ((c * 3) >> 1);\n    }\n    if (count(s, 256, 0xABCD0000u | c) != want) return 1;\n    if (below(s, 256, 0xAB0000u | (c * 3)) != under) return 2;\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// A run of 8-byte stores of 0 at consecutive offsets (x86-64: a zeroed xmm register stored 16 bytes at a
// time, an odd last store alone; arm64: a zeroed q register stored by `stp q` per 32 bytes from a 16-byte
// offset, the rest by `stp xzr`), and one a volatile store breaks, write those bytes alone; a rare block
// the layout puts after such a run, of lower instructions, keeps its stores.
@test
fn runs_of_zero_stores_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @zero5 fn global\nsym @zero4 fn global\nsym @zcold fn global\nsym @zero9 fn global\nfn @zero9\n  sig (ptr) -> void\nb0(v0: ptr):\n  v1 = iconst.i64 0\n  store v1, v0+16 align 0\n  store v1, v0+24 align 0\n  store v1, v0+32 align 0\n  store v1, v0+40 align 0\n  store v1, v0+48 align 0\n  store v1, v0+56 align 0\n  store v1, v0+64 align 0\n  store v1, v0+72 align 0\n  store v1, v0+80 align 0\n  ret\nfn @zero5\n  sig (ptr) -> void\nb0(v0: ptr):\n  v1 = iconst.i64 0\n  store v1, v0+8 align 0\n  store v1, v0+16 align 0\n  store v1, v0+24 align 0\n  store v1, v0+32 align 0\n  store v1, v0+40 align 0\n  ret\nfn @zero4\n  sig (ptr) -> void\nb0(v0: ptr):\n  v1 = iconst.i64 0\n  store v1, v0 align 0\n  store v1, v0+8 align 0\n  store v1, v0+16 align 0 volatile\n  store v1, v0+24 align 0\n  ret\nfn @zcold\n  sig (ptr, i8) -> void\nb0(v0: ptr, v1: i8):\n  v2 = iconst.i64 0\n  v3 = iconst.i64 7\n  br v1, b1, b2\nb1: unlikely\n  store v3, v0+40 align 0\n  ret\nb2:\n  store v2, v0 align 0\n  store v2, v0+8 align 0\n  store v2, v0+16 align 0\n  store v2, v0+24 align 0\n  ret\n";
    let drv = "#include <stdint.h>\nvoid zero5(uint64_t *);\nvoid zero4(uint64_t *);\nvoid zcold(uint64_t *, int8_t);\nvoid zero9(uint64_t *);\nint main(void) {\n  uint64_t z[13];\n  for (int i = 0; i < 13; i++) z[i] = 5;\n  zero9(z);\n  for (int i = 0; i < 13; i++) if (z[i] != (i >= 2 && i < 11 ? 0 : 5)) return 7;\n  uint64_t a[7];\n  for (int i = 0; i < 7; i++) a[i] = 0x1111111111111111ull * (i + 1);\n  zero5(a);\n  if (a[0] != 0x1111111111111111ull || a[6] != 0x7777777777777777ull) return 1;\n  for (int i = 1; i < 6; i++) if (a[i] != 0) return 2;\n  uint64_t b[5];\n  for (int i = 0; i < 5; i++) b[i] = 9;\n  zero4(b);\n  for (int i = 0; i < 4; i++) if (b[i] != 0) return 3;\n  if (b[4] != 9) return 4;\n  uint64_t c[6] = {1, 1, 1, 1, 1, 1};\n  zcold(c, 0);\n  if (c[0] != 0 || c[3] != 0 || c[5] != 1) return 5;\n  zcold(c, 1);\n  if (c[5] != 7) return 6;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Atomic read-modify-writes that return the old value, compare-and-swaps that store and that do not, and
// acquire and sequentially consistent loads of 8 to 64 bits: arm64 with LSE (`ldadd`, `cas`) and without
// (exclusive load and store loops), with RCpc (`ldapr`) and without.
@test
fn atomic_operations_of_every_width_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @at fn global
fn @at
  sig (ptr, ptr, ptr, ptr, ptr) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: ptr, v4: ptr):
  v5 = iconst.i8 53
  v6 = armw.add.i8 v5, v0 acq_rel
  v7 = iconst.i8 17
  v8 = armw.sub.i8 v7, v0 relaxed
  v9 = iconst.i8 90
  v10 = armw.and.i8 v9, v0 seq_cst
  v11 = iconst.i8 129
  v12 = armw.or.i8 v11, v0 acquire
  v13 = iconst.i8 126
  v14 = armw.xor.i8 v13, v0 release
  v15 = iconst.i8 108
  v16 = armw.xchg.i8 v15, v0 seq_cst
  v17 = iconst.i8 108
  v18 = iconst.i8 71
  v19 = acas v0, v17, v18 seq_cst seq_cst
  v20 = iconst.i8 19
  v21 = acas v0, v17, v20 acquire relaxed
  v22 = aload.i8 v0 acquire
  v23 = aload.i8 v0 seq_cst
  v24 = iconst.i16 53
  v25 = armw.add.i16 v24, v1 acq_rel
  v26 = iconst.i16 17
  v27 = armw.sub.i16 v26, v1 relaxed
  v28 = iconst.i16 90
  v29 = armw.and.i16 v28, v1 seq_cst
  v30 = iconst.i16 129
  v31 = armw.or.i16 v30, v1 acquire
  v32 = iconst.i16 126
  v33 = armw.xor.i16 v32, v1 release
  v34 = iconst.i16 108
  v35 = armw.xchg.i16 v34, v1 seq_cst
  v36 = iconst.i16 108
  v37 = iconst.i16 71
  v38 = acas v1, v36, v37 seq_cst seq_cst
  v39 = iconst.i16 19
  v40 = acas v1, v36, v39 acquire relaxed
  v41 = aload.i16 v1 acquire
  v42 = aload.i16 v1 seq_cst
  v43 = iconst.i32 53
  v44 = armw.add.i32 v43, v2 acq_rel
  v45 = iconst.i32 17
  v46 = armw.sub.i32 v45, v2 relaxed
  v47 = iconst.i32 90
  v48 = armw.and.i32 v47, v2 seq_cst
  v49 = iconst.i32 129
  v50 = armw.or.i32 v49, v2 acquire
  v51 = iconst.i32 126
  v52 = armw.xor.i32 v51, v2 release
  v53 = iconst.i32 108
  v54 = armw.xchg.i32 v53, v2 seq_cst
  v55 = iconst.i32 108
  v56 = iconst.i32 71
  v57 = acas v2, v55, v56 seq_cst seq_cst
  v58 = iconst.i32 19
  v59 = acas v2, v55, v58 acquire relaxed
  v60 = aload.i32 v2 acquire
  v61 = aload.i32 v2 seq_cst
  v62 = iconst.i64 53
  v63 = armw.add.i64 v62, v3 acq_rel
  v64 = iconst.i64 17
  v65 = armw.sub.i64 v64, v3 relaxed
  v66 = iconst.i64 90
  v67 = armw.and.i64 v66, v3 seq_cst
  v68 = iconst.i64 129
  v69 = armw.or.i64 v68, v3 acquire
  v70 = iconst.i64 126
  v71 = armw.xor.i64 v70, v3 release
  v72 = iconst.i64 108
  v73 = armw.xchg.i64 v72, v3 seq_cst
  v74 = iconst.i64 108
  v75 = iconst.i64 71
  v76 = acas v3, v74, v75 seq_cst seq_cst
  v77 = iconst.i64 19
  v78 = acas v3, v74, v77 acquire relaxed
  v79 = aload.i64 v3 acquire
  v80 = aload.i64 v3 seq_cst
  store v6, v4+0 align 0
  store v8, v4+8 align 0
  store v10, v4+16 align 0
  store v12, v4+24 align 0
  store v14, v4+32 align 0
  store v16, v4+40 align 0
  store v19, v4+48 align 0
  store v21, v4+56 align 0
  store v22, v4+64 align 0
  store v23, v4+72 align 0
  store v25, v4+80 align 0
  store v27, v4+88 align 0
  store v29, v4+96 align 0
  store v31, v4+104 align 0
  store v33, v4+112 align 0
  store v35, v4+120 align 0
  store v38, v4+128 align 0
  store v40, v4+136 align 0
  store v41, v4+144 align 0
  store v42, v4+152 align 0
  store v44, v4+160 align 0
  store v46, v4+168 align 0
  store v48, v4+176 align 0
  store v50, v4+184 align 0
  store v52, v4+192 align 0
  store v54, v4+200 align 0
  store v57, v4+208 align 0
  store v59, v4+216 align 0
  store v60, v4+224 align 0
  store v61, v4+232 align 0
  store v63, v4+240 align 0
  store v65, v4+248 align 0
  store v67, v4+256 align 0
  store v69, v4+264 align 0
  store v71, v4+272 align 0
  store v73, v4+280 align 0
  store v76, v4+288 align 0
  store v78, v4+296 align 0
  store v79, v4+304 align 0
  store v80, v4+312 align 0
  ret
)";
    let drv = "#include <stdint.h>\n#include <string.h>\nvoid at(void *, void *, void *, void *, unsigned char *);\n#define CHECK(T, at0, x) { T v = (T)(x); T w; uint64_t o = at0; \\\n  memcpy(&w, r + o, sizeof(T)); if (w != v) return 1; v = (T)(v + 0x35); o += 8; \\\n  memcpy(&w, r + o, sizeof(T)); if (w != v) return 2; v = (T)(v - 0x11); o += 8; \\\n  memcpy(&w, r + o, sizeof(T)); if (w != v) return 3; v = (T)(v & 0x5A); o += 8; \\\n  memcpy(&w, r + o, sizeof(T)); if (w != v) return 4; v = (T)(v | 0x81); o += 8; \\\n  memcpy(&w, r + o, sizeof(T)); if (w != v) return 5; v = (T)(v ^ 0x7E); o += 8; \\\n  memcpy(&w, r + o, sizeof(T)); if (w != v) return 6; o += 8; \\\n  if (r[o] != 1) return 7; o += 8; \\\n  if (r[o] != 0) return 8; o += 8; \\\n  memcpy(&w, r + o, sizeof(T)); if (w != 0x47) return 9; o += 8; \\\n  memcpy(&w, r + o, sizeof(T)); if (w != 0x47) return 10; }\nint main(void) {\n  uint8_t a = 0xF3; uint16_t b = 0x8123; uint32_t c = 0x80001234u; uint64_t d = 0x8000000012345678ull;\n  unsigned char r[320];\n  memset(r, 0xEE, sizeof r);\n  at(&a, &b, &c, &d, r);\n  CHECK(uint8_t, 0, 0xF3) CHECK(uint16_t, 80, 0x8123) CHECK(uint32_t, 160, 0x80001234u)\n  CHECK(uint64_t, 240, 0x8000000012345678ull)\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_native_with(lir, drv, LSE | RCPC), 0);
}

// Atomic read-modify-writes whose old value nothing reads (x86-64 `lock or`, `lock and`, `lock add`,
// `lock sub`, `lock xor` on the memory, with an immediate or a register) of 16, 32 and 64 bits.
@test
fn atomic_updates_without_their_old_values_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @rmw fn global\nfn @rmw\n  sig (ptr, ptr, ptr, i64) -> void\nb0(v0: ptr, v1: ptr, v2: ptr, v3: i64):\n  v4 = iconst.i32 4\n  v5 = armw.or.i32 v4, v0 relaxed\n  v6 = iconst.i32 -2\n  v7 = armw.and.i32 v6, v0 seq_cst\n  v8 = armw.add.i64 v3, v1 acq_rel\n  v9 = iconst.i16 5\n  v10 = armw.sub.i16 v9, v2 relaxed\n  v11 = iconst.i64 255\n  v12 = armw.xor.i64 v11, v1 release\n  ret\n";
    let drv = "#include <stdint.h>\nvoid rmw(uint32_t *, uint64_t *, uint16_t *, uint64_t);\nint main(void) {\n  uint32_t a = 0x13;\n  uint64_t b = 0x100000000ull;\n  uint16_t c = 3;\n  rmw(&a, &b, &c, 0x7777);\n  if (a != ((0x13u | 4u) & 0xFFFFFFFEu)) return 1;\n  if (b != ((0x100000000ull + 0x7777) ^ 255)) return 2;\n  if (c != (uint16_t)(3 - 5)) return 3;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// A float absolute value by a select (`x < 0 ? -x : x`, x86-64 `maxsd` of `-x` and `x`) keeps -0 and NaN as
// the select does; a trailing-zero count of 32 or 64 bits counts the width for 0 (x86-64 `tzcnt` into the
// width preset).
@test
fn float_absolute_selects_and_trailing_zero_counts_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @abs64 fn global\nsym @abs32 fn global\nsym @ctz32 fn global\nsym @ctz64 fn global\nfn @abs64\n  sig (f64) -> f64\nb0(v0: f64):\n  v1 = fconst.f64 0x0\n  v2 = fcmp.olt v0, v1\n  v3 = fneg.f64 v0\n  v4 = select.f64 v2, v3, v0\n  ret v4\nfn @abs32\n  sig (f32) -> f32\nb0(v0: f32):\n  v1 = fconst.f32 0x80000000\n  v2 = fcmp.olt v0, v1\n  v3 = fneg.f32 v0\n  v4 = select.f32 v2, v3, v0\n  ret v4\nfn @ctz32\n  sig (i32) -> i32\nb0(v0: i32):\n  v1 = ctz.i32 v0\n  ret v1\nfn @ctz64\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = ctz.i64 v0\n  ret v1\n";
    let drv = "#include <math.h>\n#include <string.h>\n#include <stdint.h>\ndouble abs64(double);\nfloat abs32(float);\nuint32_t ctz32(uint32_t);\nuint64_t ctz64(uint64_t);\nstatic int bits64(double x, double y) { uint64_t a, b; memcpy(&a, &x, 8); memcpy(&b, &y, 8); return a == b; }\nstatic int bits32(float x, float y) { uint32_t a, b; memcpy(&a, &x, 4); memcpy(&b, &y, 4); return a == b; }\nint main(void) {\n  double v[9] = {0.0, -0.0, 1.5, -1.5, INFINITY, -INFINITY, NAN, -NAN, -1e-310};\n  for (int i = 0; i < 9; i++) {\n    double x = v[i];\n    float f = (float)x;\n    if (!bits64(abs64(x), x < 0.0 ? -x : x)) return 1;\n    if (!bits32(abs32(f), f < -0.0f ? -f : f)) return 2;\n  }\n  if (ctz32(0) != 32 || ctz64(0) != 64) return 3;\n  for (int k = 0; k < 64; k++) {\n    uint64_t x = (0x8000000000000000ull >> k) | (0x8000000000000000ull >> (k / 2));\n    if (ctz64(x) != (uint64_t)__builtin_ctzll(x)) return 4;\n    if ((uint32_t)x != 0 && ctz32((uint32_t)x) != (uint32_t)__builtin_ctz((uint32_t)x)) return 5;\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A 64-bit product of two 32-bit extensions, or of one and a constant within its range, is one widening
// multiply (arm64 `umull`, `smull`; not with a constant past the range, `umulb`); a sum,
// difference or bitwise operation of a value shifted by a constant takes it as a shifted operand, but
// not next to a product a multiply-add computes (`madsh`).
@test
fn widening_products_and_shifted_operands_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @umulw fn global\nsym @smulw fn global\nsym @addsh fn global\nsym @subsh fn global\nsym @orsh fn global\nsym @xorsh fn global\nsym @madsh fn global\nsym @umulk fn global\nsym @smulk fn global\nsym @umulb fn global\nfn @umulk\n  sig (i32) -> i64\nb0(v0: i32):\n  v1 = zext.i64 v0\n  v2 = iconst.i64 3435973837\n  v3 = mul.i64 v1, v2\n  ret v3\nfn @smulk\n  sig (i32) -> i64\nb0(v0: i32):\n  v1 = sext.i64 v0\n  v2 = iconst.i64 -7\n  v3 = mul.i64 v1, v2\n  ret v3\nfn @umulb\n  sig (i32) -> i64\nb0(v0: i32):\n  v1 = zext.i64 v0\n  v2 = iconst.i64 4294967297\n  v3 = mul.i64 v1, v2\n  ret v3\nfn @umulw\n  sig (i32, i32) -> i64\nb0(v0: i32, v1: i32):\n  v2 = zext.i64 v0\n  v3 = zext.i64 v1\n  v4 = mul.i64 v2, v3\n  ret v4\nfn @smulw\n  sig (i32, i32) -> i64\nb0(v0: i32, v1: i32):\n  v2 = sext.i64 v0\n  v3 = sext.i64 v1\n  v4 = mul.i64 v2, v3\n  ret v4\nfn @addsh\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = iconst.i64 3\n  v3 = lshr.i64 v1, v2\n  v4 = add.i64 v3, v0\n  ret v4\nfn @subsh\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = iconst.i64 5\n  v3 = shl.i64 v1, v2\n  v4 = sub.i64 v0, v3\n  ret v4\nfn @orsh\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = iconst.i32 3\n  v3 = ashr.i32 v1, v2\n  v4 = or.i32 v0, v3\n  ret v4\nfn @xorsh\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = iconst.i32 31\n  v3 = shl.i32 v1, v2\n  v4 = xor.i32 v3, v0\n  ret v4\nfn @madsh\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 3\n  v4 = shl.i64 v0, v3\n  v5 = mul.i64 v1, v2\n  v6 = add.i64 v4, v5\n  ret v6\n";
    let drv = "#include <stdint.h>\nuint64_t umulw(uint32_t, uint32_t);\nint64_t smulw(int32_t, int32_t);\nuint64_t addsh(uint64_t, uint64_t);\nuint64_t subsh(uint64_t, uint64_t);\nint32_t orsh(int32_t, int32_t);\nuint32_t xorsh(uint32_t, uint32_t);\nuint64_t madsh(uint64_t, uint64_t, uint64_t);\nuint64_t umulk(uint32_t);\nint64_t smulk(int32_t);\nuint64_t umulb(uint32_t);\nint main(void) {\n  uint64_t s = 0x9E3779B97F4A7C15ull;\n  for (int i = 0; i < 1000; i++) {\n    s ^= s << 13; s ^= s >> 7; s ^= s << 17;\n    uint32_t a = (uint32_t)s, b = (uint32_t)(s >> 32);\n    if (umulw(a, b) != (uint64_t)a * b) return 1;\n    if (smulw((int32_t)a, (int32_t)b) != (int64_t)(int32_t)a * (int32_t)b) return 2;\n    if (addsh(s, s * 7) != s + ((s * 7) >> 3)) return 3;\n    if (subsh(s, s * 7) != s - ((s * 7) << 5)) return 4;\n    if (orsh((int32_t)a, (int32_t)b) != ((int32_t)a | ((int32_t)b >> 3))) return 5;\n    if (xorsh(a, b) != (a ^ (b << 31))) return 6;\n    if (madsh(s, a, b) != (s << 3) + (uint64_t)a * b) return 7;\n    if (umulk(a) != (uint64_t)a * 3435973837u) return 8;\n    if (smulk((int32_t)a) != (int64_t)(int32_t)a * -7) return 9;\n    if (umulb(a) != (uint64_t)a * 4294967297ull) return 10;\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A select of a value and that value plus 1, negated or inverted, or of a value and 1 or all ones, is one
// conditional instruction (arm64 `cinc`, `cneg`, `csinv`, `csinc` with the zero register), in 8, 32 and
// 64 bits.
@test
fn conditional_increments_negations_and_inversions_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @iabs fn global\nsym @cinc fn global\nsym @cmp3 fn global\nsym @one fn global\nsym @ones fn global\nsym @inv fn global\nsym @dec fn global\nfn @iabs\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = iconst.i64 0\n  v2 = icmp.slt v0, v1\n  v3 = sub.i64 v1, v0\n  v4 = select.i64 v2, v3, v0\n  ret v4\nfn @cinc\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = icmp.ugt v0, v1\n  v4 = iconst.i32 1\n  v5 = add.i32 v2, v4\n  v6 = select.i32 v3, v2, v5\n  ret v6\nfn @cmp3\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = icmp.slt v0, v1\n  v3 = icmp.sgt v0, v1\n  v4 = zext.i32 v3\n  v5 = iconst.i32 -1\n  v6 = select.i32 v2, v5, v4\n  ret v6\nfn @one\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = iconst.i32 7\n  v3 = icmp.eq v0, v2\n  v4 = iconst.i32 1\n  v5 = select.i32 v3, v1, v4\n  ret v5\nfn @ones\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = iconst.i64 0\n  v3 = icmp.sge v0, v2\n  v4 = iconst.i64 -1\n  v5 = select.i64 v3, v4, v1\n  ret v5\nfn @inv\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = iconst.i32 100\n  v3 = icmp.ult v0, v2\n  v4 = iconst.i32 -1\n  v5 = xor.i32 v1, v4\n  v6 = select.i32 v3, v5, v1\n  ret v6\nfn @dec\n  sig (i8, i8) -> i8\nb0(v0: i8, v1: i8):\n  v2 = icmp.ugt v0, v1\n  v3 = iconst.i8 -1\n  v4 = sub.i8 v1, v3\n  v5 = select.i8 v2, v4, v1\n  ret v5\n";
    let drv = "#include <stdint.h>\nint64_t iabs(int64_t);\nint32_t cinc(int32_t, int32_t, int32_t);\nint32_t cmp3(int32_t, int32_t);\nint32_t one(int32_t, int32_t);\nint64_t ones(int64_t, int64_t);\nint32_t inv(int32_t, int32_t);\nuint8_t dec(uint8_t, uint8_t);\nint main(void) {\n  int64_t xs[6] = {0, 1, -1, INT64_C(1) << 40, -(INT64_C(1) << 40), INT64_MIN + 1};\n  for (int i = 0; i < 6; i++) {\n    if (iabs(xs[i]) != (xs[i] < 0 ? -xs[i] : xs[i])) return 1;\n    if (ones(xs[i], 5) != (xs[i] >= 0 ? -1 : 5)) return 5;\n  }\n  for (int32_t a = -3; a < 4; a++)\n    for (int32_t b = -3; b < 4; b++) {\n      if (cinc(a, b, 10) != ((uint32_t)a > (uint32_t)b ? 10 : 11)) return 2;\n      if (cmp3(a, b) != (a < b ? -1 : a > b)) return 3;\n      if (one(a + 5, b) != (a + 5 == 7 ? b : 1)) return 4;\n      if (inv(a * 60, b) != ((uint32_t)(a * 60) < 100 ? ~b : b)) return 6;\n    }\n  for (int a = 0; a < 256; a += 5)\n    for (int b = 0; b < 256; b += 7)\n      if (dec((uint8_t)a, (uint8_t)b) != (uint8_t)(a > b ? b + 1 : b)) return 7;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Selects between a value and its negation on the value's sign (x86-64: the negation's sign flag picks, no
// comparison) in 32 and 64 bits, the comparison either way round, `abs` and its negation; and comparisons
// that only 8-bit operations read (x86-64: `setcc` alone, no extension), widened after their `and`, stored,
// branched and selected on.
@test
fn absolute_values_and_byte_comparisons_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @abs32 fn global
sym @nabs64 fn global
sym @absm fn global
sym @nabs32 fn global
sym @all3 fn global
sym @any2 fn global
sym @flags fn global
fn @abs32
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = icmp.slt v0, v1
  v3 = sub.i32 v1, v0
  v4 = select.i32 v2, v3, v0
  ret v4
fn @nabs64
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = icmp.sge v0, v1
  v3 = neg.i64 v0
  v4 = select.i64 v2, v3, v0
  ret v4
fn @absm
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = icmp.sgt v1, v0
  v3 = sub.i64 v1, v0
  v4 = select.i64 v2, v3, v0
  ret v4
fn @nabs32
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = icmp.sle v0, v1
  v3 = neg.i32 v0
  v4 = select.i32 v2, v0, v3
  ret v4
fn @all3
  sig (i32, i32, i32) -> i64
b0(v0: i32, v1: i32, v2: i32):
  v3 = iconst.i32 1048579
  v4 = icmp.eq v0, v3
  v5 = iconst.i32 1048585
  v6 = icmp.ult v1, v5
  v7 = and.i8 v4, v6
  v8 = iconst.i32 0
  v9 = icmp.ne v2, v8
  v10 = and.i8 v7, v9
  v11 = zext.i64 v10
  ret v11
fn @any2
  sig (i32, i32) -> i64
b0(v0: i32, v1: i32):
  v2 = iconst.i32 1048579
  v3 = icmp.eq v0, v2
  v4 = icmp.ugt v1, v2
  v5 = or.i8 v3, v4
  v6 = zext.i64 v5
  ret v6
fn @flags
  sig (ptr, i32, i32) -> i32
b0(v0: ptr, v1: i32, v2: i32):
  v3 = icmp.slt v1, v2
  store v3, v0 align 0
  v4 = icmp.eq v1, v2
  v5 = or.i8 v3, v4
  v6 = iconst.i64 1
  v7 = ptradd v0, v6 * 1
  store v5, v7 align 0
  br v4, b1, b2
b1:
  v8 = iconst.i32 7
  ret v8
b2:
  v9 = iconst.i32 10
  v10 = iconst.i32 20
  v11 = select.i32 v3, v9, v10
  ret v11
)";
    let drv = "#include <stdint.h>\nint32_t abs32(int32_t);\nint64_t nabs64(int64_t);\nint64_t absm(int64_t);\nint32_t nabs32(int32_t);\nint64_t all3(uint32_t, uint32_t, uint32_t);\nint64_t any2(uint32_t, uint32_t);\nint32_t flags(uint8_t *, int32_t, int32_t);\nint main(void) {\n  int64_t xs[7] = {0, 1, -1, INT64_C(1) << 40, -(INT64_C(1) << 40), INT64_MIN, INT64_MAX};\n  for (int i = 0; i < 7; i++) {\n    int64_t x = xs[i];\n    int32_t y = (int32_t)(x >> 8) | (int32_t)x;\n    if (i == 5) y = INT32_MIN;\n    uint64_t ux = (uint64_t)x, uy = (uint32_t)y;\n    if (abs32(y) != (int32_t)(y < 0 ? 0u - (uint32_t)uy : (uint32_t)uy)) return 1;\n    if (nabs64(x) != (int64_t)(x >= 0 ? 0 - ux : ux)) return 2;\n    if (absm(x) != (int64_t)(x < 0 ? 0 - ux : ux)) return 3;\n    if (nabs32(y) != (y <= 0 ? y : (int32_t)(0u - (uint32_t)uy))) return 4;\n  }\n  for (uint32_t a = 0; a < 6; a++)\n    for (uint32_t b = 6; b < 12; b++)\n      for (uint32_t c = 0; c < 2; c++)\n        if (all3(a | 0x100000u, b | 0x100000u, c << 20) != (int64_t)(a == 3 && b < 9 && c != 0)) return 5;\n  for (uint32_t a = 0; a < 6; a++)\n    for (uint32_t b = 0; b < 6; b++)\n      if (any2(a | 0x100000u, b | 0x100000u) != (int64_t)(a == 3 || b > 3)) return 7;\n  for (int32_t a = -2; a < 3; a++)\n    for (int32_t b = -2; b < 3; b++) {\n      uint8_t m[2] = {9, 9};\n      int32_t r = flags(m, a * 0x10001, b * 0x10001);\n      if (m[0] != (a < b) || m[1] != (a <= b) || r != (a == b ? 7 : a < b ? 10 : 20)) return 6;\n    }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// An `and`, `or` or `xor` of an inverted value (`not`, or `xor` with all ones; arm64 `bic`, `orn`, `eon`) in
// 64, 32 and 8 bits, a right shift of a left shift by at most as much (arm64 `sbfx`, `ubfx`), and a field
// inserted into the other bits of a value (arm64 `bfi`; not with a mask that keeps bits of the field),
// also as a value's truncation extended under an extended field shifted above it (not with bits between
// them), with their results.
@test
fn inverted_operands_and_shifted_fields_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @bic64 fn global\nsym @orn32 fn global\nsym @eon64 fn global\nsym @bicx32 fn global\nsym @bic8 fn global\nsym @sbf32 fn global\nsym @ubf64 fn global\nsym @sbf64 fn global\nsym @ubf32 fn global\nsym @bfi32 fn global\nsym @bfi64 fn global\nsym @nobfi fn global\nsym @bfiz fn global\nsym @bfiz16 fn global\nsym @nobfiz fn global\nfn @bic64\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = not.i64 v0\n  v3 = and.i64 v2, v1\n  ret v3\nfn @orn32\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = not.i32 v1\n  v3 = or.i32 v0, v2\n  ret v3\nfn @eon64\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = iconst.i64 -1\n  v3 = xor.i64 v1, v2\n  v4 = xor.i64 v0, v3\n  ret v4\nfn @bicx32\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = iconst.i32 -1\n  v3 = xor.i32 v0, v2\n  v4 = and.i32 v1, v3\n  ret v4\nfn @bic8\n  sig (i8, i8) -> i8\nb0(v0: i8, v1: i8):\n  v2 = not.i8 v0\n  v3 = and.i8 v2, v1\n  ret v3\nfn @sbf32\n  sig (i32) -> i32\nb0(v0: i32):\n  v1 = iconst.i32 20\n  v2 = shl.i32 v0, v1\n  v3 = iconst.i32 24\n  v4 = ashr.i32 v2, v3\n  ret v4\nfn @ubf64\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = iconst.i64 3\n  v2 = shl.i64 v0, v1\n  v3 = iconst.i64 60\n  v4 = lshr.i64 v2, v3\n  ret v4\nfn @sbf64\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = iconst.i64 8\n  v2 = shl.i64 v0, v1\n  v3 = iconst.i64 8\n  v4 = ashr.i64 v2, v3\n  ret v4\nfn @ubf32\n  sig (i32) -> i32\nb0(v0: i32):\n  v1 = iconst.i32 0\n  v2 = shl.i32 v0, v1\n  v3 = iconst.i32 31\n  v4 = lshr.i32 v2, v3\n  ret v4\nfn @bfi32\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = iconst.i32 4294902015\n  v3 = and.i32 v0, v2\n  v4 = iconst.i32 255\n  v5 = and.i32 v1, v4\n  v6 = iconst.i32 8\n  v7 = shl.i32 v5, v6\n  v8 = or.i32 v3, v7\n  ret v8\nfn @bfi64\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = iconst.i64 65535\n  v3 = and.i64 v1, v2\n  v4 = iconst.i64 40\n  v5 = shl.i64 v3, v4\n  v6 = iconst.i64 -72056494526300161\n  v7 = and.i64 v0, v6\n  v8 = or.i64 v5, v7\n  ret v8\nfn @nobfi\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = iconst.i32 4294901775\n  v3 = and.i32 v0, v2\n  v4 = iconst.i32 255\n  v5 = and.i32 v1, v4\n  v6 = iconst.i32 8\n  v7 = shl.i32 v5, v6\n  v8 = or.i32 v3, v7\n  ret v8\nfn @bfiz\n  sig (i64, i32) -> i64\nb0(v0: i64, v1: i32):\n  v2 = trunc.i32 v0\n  v3 = zext.i64 v2\n  v4 = zext.i64 v1\n  v5 = iconst.i64 32\n  v6 = shl.i64 v4, v5\n  v7 = or.i64 v6, v3\n  ret v7\nfn @bfiz16\n  sig (i32, i16) -> i32\nb0(v0: i32, v1: i16):\n  v2 = trunc.i16 v0\n  v3 = zext.i32 v2\n  v4 = zext.i32 v1\n  v5 = iconst.i32 16\n  v6 = shl.i32 v4, v5\n  v7 = or.i32 v3, v6\n  ret v7\nfn @nobfiz\n  sig (i32, i16) -> i32\nb0(v0: i32, v1: i16):\n  v2 = trunc.i8 v0\n  v3 = zext.i32 v2\n  v4 = zext.i32 v1\n  v5 = iconst.i32 16\n  v6 = shl.i32 v4, v5\n  v7 = or.i32 v3, v6\n  ret v7\n";
    let drv = "#include <stdint.h>\nint64_t bic64(int64_t, int64_t);\nint32_t orn32(int32_t, int32_t);\nint64_t eon64(int64_t, int64_t);\nint32_t bicx32(int32_t, int32_t);\nuint8_t bic8(uint8_t, uint8_t);\nint32_t sbf32(int32_t);\nuint64_t ubf64(uint64_t);\nint64_t sbf64(int64_t);\nuint32_t ubf32(uint32_t);\nuint32_t bfi32(uint32_t, uint32_t);\nuint64_t bfi64(uint64_t, uint64_t);\nuint32_t nobfi(uint32_t, uint32_t);\nuint64_t bfiz(uint64_t, uint32_t);\nuint32_t bfiz16(uint32_t, uint16_t);\nuint32_t nobfiz(uint32_t, uint16_t);\nint main(void) {\n  uint64_t s = 0x9E3779B97F4A7C15u;\n  for (int i = 0; i < 1000; i++) {\n    s ^= s << 13;\n    s ^= s >> 7;\n    s ^= s << 17;\n    uint64_t r = s * 0x2545F4914F6CDD1Du;\n    if (bic64((int64_t)s, (int64_t)r) != (int64_t)(~s & r)) return 1;\n    if (orn32((int32_t)s, (int32_t)r) != (int32_t)((uint32_t)s | ~(uint32_t)r)) return 2;\n    if (eon64((int64_t)s, (int64_t)r) != (int64_t)(s ^ ~r)) return 3;\n    if (bicx32((int32_t)s, (int32_t)r) != (int32_t)((uint32_t)r & ~(uint32_t)s)) return 4;\n    if (bic8((uint8_t)s, (uint8_t)r) != (uint8_t)(~(uint8_t)s & (uint8_t)r)) return 5;\n    if (sbf32((int32_t)s) != (int32_t)((uint32_t)s << 20) >> 24) return 6;\n    if (ubf64(s) != (s << 3) >> 60) return 7;\n    if (sbf64((int64_t)s) != (int64_t)(s << 8) >> 8) return 8;\n    if (ubf32((uint32_t)s) != (uint32_t)s >> 31) return 9;\n    if (bfi32((uint32_t)s, (uint32_t)r) != (((uint32_t)s & 0xffff00ffu) | (((uint32_t)r & 0xffu) << 8))) return 10;\n    if (bfi64(s, r) != ((s & ~(UINT64_C(0xffff) << 40)) | ((r & 0xffff) << 40))) return 11;\n    if (nobfi((uint32_t)s, (uint32_t)r) != (((uint32_t)s & 0xffff000fu) | (((uint32_t)r & 0xffu) << 8))) return 12;\n    if (bfiz(s, (uint32_t)r) != ((s & 0xffffffffu) | ((uint64_t)(uint32_t)r << 32))) return 13;\n    if (bfiz16((uint32_t)s, (uint16_t)r) != (((uint32_t)s & 0xffffu) | ((uint32_t)(uint16_t)r << 16))) return 14;\n    if (nobfiz((uint32_t)s, (uint16_t)r) != ((uint32_t)(uint8_t)s | ((uint32_t)(uint16_t)r << 16))) return 15;\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Products of a loaded operand, in 32 and 64 bits, the load either side (x86-64: `imul` reads the memory),
// and a load's square and a load by a constant, which keep the load apart.
@test
fn products_of_loaded_operands_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @mul32 fn global
sym @mul64 fn global
sym @sq64 fn global
sym @mulk fn global
fn @mul32
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = load.i32 v0 align 2
  v3 = mul.i32 v1, v2
  ret v3
fn @mul64
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = load.i64 v0+8 align 3
  v3 = mul.i64 v2, v1
  ret v3
fn @sq64
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = mul.i64 v1, v1
  ret v2
fn @mulk
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.i32 v0 align 2
  v2 = iconst.i32 12345
  v3 = mul.i32 v1, v2
  ret v3
)";
    let drv = "#include <stdint.h>\nuint32_t mul32(const uint32_t *, uint32_t);\nuint64_t mul64(const uint64_t *, uint64_t);\nuint64_t sq64(const uint64_t *);\nuint32_t mulk(const uint32_t *);\nint main(void) {\n  uint64_t s = 0x9E3779B97F4A7C15u;\n  for (int i = 0; i < 100; i++) {\n    s ^= s << 13;\n    s ^= s >> 7;\n    s ^= s << 17;\n    uint64_t m[2] = {s, s * 31};\n    uint32_t w = (uint32_t)(s >> 7);\n    if (mul32(&w, (uint32_t)s) != w * (uint32_t)s) return 1;\n    if (mul64(m, s >> 3) != m[1] * (s >> 3)) return 2;\n    if (sq64(m) != s * s) return 3;\n    if (mulk(&w) != w * 12345u) return 4;\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Narrow results whose register holds other bits above them (a truncation, a comparison set in a byte):
// the caller extends them (x86-64 returns them as they are, as clang's callers expect), signed or not.
@test
fn narrow_results_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @lo8 fn global
sym @lo16 fn global
sym @hi8 fn global
sym @lt fn global
fn @lo8
  sig (i32) -> i8
b0(v0: i32):
  v1 = trunc.i8 v0
  ret v1
fn @lo16
  sig (i64) -> i16.s
b0(v0: i64):
  v1 = trunc.i16 v0
  ret v1
fn @hi8
  sig (i32) -> i8.s
b0(v0: i32):
  v1 = trunc.i8 v0
  ret v1
fn @lt
  sig (i32, i32) -> i8
b0(v0: i32, v1: i32):
  v2 = icmp.slt v0, v1
  ret v2
)";
    let drv = "#include <stdint.h>\n#include <stdbool.h>\nuint8_t lo8(uint32_t);\nint16_t lo16(int64_t);\nint8_t hi8(int32_t);\nbool lt(int32_t, int32_t);\nint main(void) {\n  if (lo8(0x12345678u) != 0x78) return 1;\n  if ((int)lo16(INT64_C(0x123456789ABCDEF0)) != (int)(int16_t)0xDEF0) return 2;\n  if ((int)hi8((int32_t)0x7FFFFF80) != -128) return 3;\n  if (lt(0x7FFFFF00, 1) != 0 || lt(-5, 3) != 1) return 4;\n  if (lt(-5, 3) + lt(3, -5) * 4 != 1) return 5;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Vector constants of each MOVI form on arm64 (a repeated byte, bytes each 0 or all ones, 4- and 2-byte
// lanes of one nonzero byte at each place, 8-byte vectors) and some of none (two bytes in a lane, words that
// differ), stored for the driver to read.
@test
fn vector_constants_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @consts fn global
fn @consts
  sig (ptr) -> void
b0(v0: ptr):
  v1 = wconst.v16i8 0xa0a0a0a0a0a0a0a, 0xa0a0a0a0a0a0a0a
  store v1, v0 align 0
  v2 = wconst.v2i64 0xff00ff0000ffff00, 0xff00ff0000ffff00
  store v2, v0+16 align 0
  v3 = wconst.v4i32 0x8000000080000000, 0x8000000080000000
  store v3, v0+32 align 0
  v4 = wconst.v4i32 0x5500000055, 0x5500000055
  store v4, v0+48 align 0
  v5 = wconst.v4i32 0xc0000000c000, 0xc0000000c000
  store v5, v0+64 align 0
  v6 = wconst.v4i32 0x7f0000007f0000, 0x7f0000007f0000
  store v6, v0+80 align 0
  v7 = wconst.v8i16 0x3300330033003300, 0x3300330033003300
  store v7, v0+96 align 0
  v8 = wconst.v8i16 0x11001100110011, 0x11001100110011
  store v8, v0+112 align 0
  v9 = wconst.v8i16 0x123412341234, 0x123412341234
  store v9, v0+128 align 0
  v10 = wconst.v2i64 0x1, 0x2
  store v10, v0+144 align 0
  v11 = wconst.v8i8 0xfefefefefefefefe
  store v11, v0+160 align 0
  ret
)";
    let drv = "#include <stdint.h>\n#include <string.h>\nvoid consts(uint8_t *);\nint main(void) {\n  uint8_t m[168];\n  memset(m, 0x5A, sizeof m);\n  consts(m);\n  uint64_t w[21];\n  memcpy(w, m, sizeof w);\n  const uint64_t e[21] = {0x0a0a0a0a0a0a0a0aull, 0x0a0a0a0a0a0a0a0aull, 0xff00ff0000ffff00ull, 0xff00ff0000ffff00ull, 0x8000000080000000ull, 0x8000000080000000ull, 0x5500000055ull, 0x5500000055ull, 0xc0000000c000ull, 0xc0000000c000ull, 0x7f0000007f0000ull, 0x7f0000007f0000ull, 0x3300330033003300ull, 0x3300330033003300ull, 0x11001100110011ull, 0x11001100110011ull, 0x123412341234ull, 0x123412341234ull, 1, 2, 0xfefefefefefefefeull};\n  for (int k = 0; k < 21; k++) if (w[k] != e[k]) return k + 1;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Branches on an `and` or `or` of two comparisons (x86-64: a jump after each comparison, `FOLD_BRCONJ`), one
// whose settled edge passes values (both conditions in bytes then), and comparisons of extended values with
// constants (compared narrow).
@test
fn branches_on_two_comparisons_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @inr fn global
sym @either fn global
sym @moved fn global
sym @tag fn global
fn @inr
  sig (i32, i32, i32) -> i32
b0(v0: i32, v1: i32, v2: i32):
  v3 = icmp.sge v0, v1
  v4 = icmp.sle v0, v2
  v5 = and.i8 v3, v4
  br v5, b1, b2
b1:
  v6 = iconst.i32 1
  ret v6
b2:
  v7 = iconst.i32 0
  ret v7
fn @either
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.eq v0, v2
  v4 = icmp.eq v1, v2
  v5 = or.i8 v3, v4
  br v5, b1, b2
b1:
  v6 = iconst.i64 7
  ret v6
b2:
  v7 = mul.i64 v0, v1
  ret v7
fn @moved
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 10
  v3 = icmp.ult v0, v2
  v4 = icmp.ugt v1, v0
  v5 = and.i8 v3, v4
  v6 = add.i64 v0, v1
  v7 = sub.i64 v1, v0
  br v5, b1(v6), b1(v7)
b1(v8: i64):
  ret v8
fn @tag
  sig (i64) -> i32
b0(v0: i64):
  v1 = trunc.i8 v0
  v2 = zext.i32 v1
  v3 = iconst.i32 200
  v4 = icmp.ugt v2, v3
  v5 = sext.i32 v1
  v6 = iconst.i32 -3
  v7 = icmp.eq v5, v6
  v8 = zext.i32 v4
  v9 = zext.i32 v7
  v10 = iconst.i32 2
  v11 = mul.i32 v9, v10
  v12 = add.i32 v8, v11
  ret v12
)";
    let drv = "#include <stdint.h>\nint32_t inr(int32_t, int32_t, int32_t);\nint64_t either(int64_t, int64_t);\nint64_t moved(uint64_t, uint64_t);\nint32_t tag(uint64_t);\nint main(void) {\n  for (int32_t x = -3; x < 4; x++)\n    for (int32_t lo = -2; lo < 2; lo++)\n      if (inr(x, lo, lo + 2) != (x >= lo && x <= lo + 2)) return 1;\n  for (int64_t a = -1; a < 2; a++)\n    for (int64_t b = -1; b < 2; b++)\n      if (either(a, b) != (a == 0 || b == 0 ? 7 : a * b)) return 2;\n  for (uint64_t a = 8; a < 12; a++)\n    for (uint64_t b = 7; b < 13; b++)\n      if (moved(a, b) != (a < 10 && b > a ? a + b : b - a)) return 3;\n  for (uint64_t v = 0; v < 512; v += 7) {\n    uint64_t x = v | 0xABCD00ull << 8;\n    uint8_t lo = (uint8_t)x;\n    if (tag(x) != (lo > 200) + 2 * ((int8_t)lo == -3)) return 4;\n  }\n  if (tag(0x1FDu) != 3) return 5;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Returned values that take the return register or a dying argument's home: a shift loop unrolled by 4
// whose remainder loop and exit take the registers its last values leave (`home_dying` when the value
// already took a loop parameter's register over), a bit count and a constant minus a leading zero count
// that the return reads (`next_reg`, a constant's temporary given to the result: `take_dying`), a select
// of a sum or 0 that writes over the sum (x86-64 `select_op`).
@test
fn returned_values_take_their_registers_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @shl fn global
sym @pop fn global
sym @lg2 fn global
sym @inc_or_zero fn global
fn @shl
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 4
  v2 = iconst.i32 1
  v3 = iconst.i32 0
  v4 = iconst.i32 -4
  v5 = and.i32 v0, v4
  v6 = icmp.ne v5, v3
  br v6, b2(v3, v2), b3(v3, v2)
b1(v7: i32, v8: i32):
  v9 = shl.i32 v7, v2
  v10 = add.i32 v8, v2
  v11 = icmp.ult v10, v0
  br v11, b1(v9, v10), b5
b2(v12: i32, v13: i32):
  v14 = shl.i32 v13, v1
  v15 = add.i32 v12, v1
  v16 = icmp.ne v15, v5
  br v16, b2(v15, v14), b3(v15, v14)
b3(v17: i32, v18: i32):
  v19 = icmp.ult v17, v0
  br v19, b1(v18, v17), b4(v18)
b4(v20: i32):
  ret v20
b5:
  ret v9
fn @pop
  sig (i64) -> i64
b0(v0: i64):
  v1 = popcnt.i64 v0
  ret v1
fn @lg2
  sig (i32) -> i32
b0(v0: i32):
  v1 = clz.i32 v0
  v2 = iconst.i32 32
  v3 = sub.i32 v2, v1
  ret v3
fn @inc_or_zero
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = add.i64 v1, v2
  v4 = iconst.i64 0
  v5 = icmp.ne v0, v4
  v6 = select.i64 v5, v3, v4
  ret v6
)";
    let drv = M"(#include <stdint.h>
uint32_t shl(uint32_t);
int64_t pop(int64_t);
uint32_t lg2(uint32_t);
int64_t inc_or_zero(int64_t, int64_t);
int main(void) {
  for (int64_t c = -1; c < 2; c++)
    for (int64_t x = -2; x < 3; x++)
      if (inc_or_zero(c, x) != (c != 0 ? x + 1 : 0)) return 4;
  for (uint32_t n = 0; n < 40; n++)
    if (shl(n) != (n < 32 ? 1u << n : 0u)) return 1;
  for (int k = 0; k < 64; k++) {
    uint64_t x = 0x9E3779B97F4A7C15ull >> k;
    if (pop((int64_t)x) != __builtin_popcountll(x)) return 2;
    uint32_t y = (uint32_t)(x >> 32) >> (k & 31);
    if (lg2(y) != (y == 0 ? 0u : 32u - (uint32_t)__builtin_clz(y))) return 3;
  }
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_popcnt(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A switch whose cases pass constants to one block and whose blocks after it pass constants to blocks
// that store and return, the arguments' homes dying at the edges: every register home ends with its value
// (`a64gen`'s check at the body's end).
@test
fn constant_edges_after_a_switch_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @__sc_panic fn global
sym @range fn global
fn @range
  sig (i32, i8, ptr, ptr) -> void
  ref p2 16 noalias
  ref p3 16 noalias
  bool p1
b0(v0: i32, v1: i8, v2: ptr, v3: ptr):
  v4 = iconst.i8 4
  v5 = iconst.i64 0
  v6 = iconst.i8 7
  v7 = iconst.i64 64
  v8 = iconst.i64 1
  v9 = iconst.i64 9223372036854775807
  v10 = iconst.i64 -1
  v11 = iconst.i32 0
  v12 = iconst.i32 64
  v13 = iconst.i32 32
  v14 = iconst.i32 16
  v15 = iconst.i32 8
  switch v0 [2 -> b2(v15), 7 -> b2(v15), 3 -> b2(v14), 8 -> b2(v14), 4 -> b2(v13), 9 -> b2(v13), 5 -> b2(v12), 10 -> b2(v12), 6 -> b1, 11 -> b1] else b2(v11)
b1:
  v16 = select.i32 v1, v13, v12
  jmp b3(v16)
b2(v17: i32):
  jmp b3(v17)
b3(v18: i32):
  v19 = zext.i64 v18
  v20 = trunc.i8 v0
  v21 = sub.i8 v20, v6
  v22 = icmp.ule v21, v4
  br v22, b7, b4
b4:
  v23 = icmp.eq v18, v12
  br v23, b6(v9), b5
b5:
  v24 = sub.i64 v19, v8
  v25 = icmp.uge v24, v7
  br v25, b10, b11
b6(v26: i64):
  v27 = sub.i64 v5, v26
  v28 = sub.i64 v27, v8
  v29 = iconst.i64 63
  v30 = ashr.i64 v28, v29
  store v28, v2 align 0
  store v30, v2+8 align 0
  v31 = ashr.i64 v26, v29
  store v26, v3 align 0
  store v31, v3+8 align 0
  ret
b7:
  v32 = icmp.eq v18, v12
  br v32, b9(v10), b8
b8:
  v33 = icmp.uge v18, v12
  br v33, b12, b13
b9(v34: i64):
  store v5, v2 align 0
  store v5, v2+8 align 0
  store v34, v3 align 0
  store v5, v3+8 align 0
  ret
b10: cold
  panic "attempt to shift left with overflow"
b11:
  v35 = shl.i64 v8, v24
  v36 = sub.i64 v35, v8
  jmp b6(v36)
b12: cold
  panic "attempt to shift left with overflow"
b13:
  v37 = shl.i64 v8, v19
  v38 = sub.i64 v37, v8
  jmp b9(v38)
)";
    let drv = M"(#include <stdint.h>
void range(int32_t, int8_t, int64_t *, int64_t *);
void __sc_panic(const char *m) { (void)m; __builtin_trap(); }
int main(void) {
  for (int32_t k = 2; k < 12; k++)
    for (int8_t b = 0; b < 2; b++) {
      int64_t lo[2], hi[2];
      range(k, b, lo, hi);
      int w = k == 2 || k == 7 ? 8 : k == 3 || k == 8 ? 16 : k == 4 || k == 9 ? 32 : k == 5 || k == 10 ? 64 : b ? 32 : 64;
      if (k >= 7) {
        uint64_t m = w == 64 ? ~0ull : (1ull << w) - 1;
        if (lo[0] != 0 || lo[1] != 0 || hi[0] != (int64_t)m || hi[1] != 0) return 1;
      } else {
        int64_t top = w == 64 ? INT64_MAX : (int64_t)((1ull << (w - 1)) - 1);
        if (lo[0] != -top - 1 || lo[1] != -1 || hi[0] != top || hi[1] != 0) return 2;
      }
    }
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Comparisons of 8- and 16-bit truncations of wider values, under every condition, against each other and
// a constant, into a value, a branch and a conditional comparison: each reads the low bits in the source's
// register (`lv::FOLD_TRUNC`).
@test
fn comparisons_of_truncations_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @c8 fn global
sym @z8 fn global
sym @j8 fn global
sym @c16 fn global
sym @z16 fn global
sym @j16 fn global
fn @c8
  sig (i64, i32) -> i64
b0(v0: i64, v1: i32):
  v2 = trunc.i8 v0
  v3 = trunc.i8 v1
  v4 = iconst.i8 5
  v5 = iconst.i64 0
  v6 = icmp.eq v2, v3
  v7 = zext.i64 v6
  v8 = iconst.i64 0
  v9 = shl.i64 v7, v8
  v10 = or.i64 v5, v9
  v11 = icmp.eq v2, v4
  v12 = zext.i64 v11
  v13 = iconst.i64 1
  v14 = shl.i64 v12, v13
  v15 = or.i64 v10, v14
  v16 = icmp.ne v2, v3
  v17 = zext.i64 v16
  v18 = iconst.i64 2
  v19 = shl.i64 v17, v18
  v20 = or.i64 v15, v19
  v21 = icmp.ne v2, v4
  v22 = zext.i64 v21
  v23 = iconst.i64 3
  v24 = shl.i64 v22, v23
  v25 = or.i64 v20, v24
  v26 = icmp.slt v2, v3
  v27 = zext.i64 v26
  v28 = iconst.i64 4
  v29 = shl.i64 v27, v28
  v30 = or.i64 v25, v29
  v31 = icmp.slt v2, v4
  v32 = zext.i64 v31
  v33 = iconst.i64 5
  v34 = shl.i64 v32, v33
  v35 = or.i64 v30, v34
  v36 = icmp.sle v2, v3
  v37 = zext.i64 v36
  v38 = iconst.i64 6
  v39 = shl.i64 v37, v38
  v40 = or.i64 v35, v39
  v41 = icmp.sle v2, v4
  v42 = zext.i64 v41
  v43 = iconst.i64 7
  v44 = shl.i64 v42, v43
  v45 = or.i64 v40, v44
  v46 = icmp.sgt v2, v3
  v47 = zext.i64 v46
  v48 = iconst.i64 8
  v49 = shl.i64 v47, v48
  v50 = or.i64 v45, v49
  v51 = icmp.sgt v2, v4
  v52 = zext.i64 v51
  v53 = iconst.i64 9
  v54 = shl.i64 v52, v53
  v55 = or.i64 v50, v54
  v56 = icmp.sge v2, v3
  v57 = zext.i64 v56
  v58 = iconst.i64 10
  v59 = shl.i64 v57, v58
  v60 = or.i64 v55, v59
  v61 = icmp.sge v2, v4
  v62 = zext.i64 v61
  v63 = iconst.i64 11
  v64 = shl.i64 v62, v63
  v65 = or.i64 v60, v64
  v66 = icmp.ult v2, v3
  v67 = zext.i64 v66
  v68 = iconst.i64 12
  v69 = shl.i64 v67, v68
  v70 = or.i64 v65, v69
  v71 = icmp.ult v2, v4
  v72 = zext.i64 v71
  v73 = iconst.i64 13
  v74 = shl.i64 v72, v73
  v75 = or.i64 v70, v74
  v76 = icmp.ule v2, v3
  v77 = zext.i64 v76
  v78 = iconst.i64 14
  v79 = shl.i64 v77, v78
  v80 = or.i64 v75, v79
  v81 = icmp.ule v2, v4
  v82 = zext.i64 v81
  v83 = iconst.i64 15
  v84 = shl.i64 v82, v83
  v85 = or.i64 v80, v84
  v86 = icmp.ugt v2, v3
  v87 = zext.i64 v86
  v88 = iconst.i64 16
  v89 = shl.i64 v87, v88
  v90 = or.i64 v85, v89
  v91 = icmp.ugt v2, v4
  v92 = zext.i64 v91
  v93 = iconst.i64 17
  v94 = shl.i64 v92, v93
  v95 = or.i64 v90, v94
  v96 = icmp.uge v2, v3
  v97 = zext.i64 v96
  v98 = iconst.i64 18
  v99 = shl.i64 v97, v98
  v100 = or.i64 v95, v99
  v101 = icmp.uge v2, v4
  v102 = zext.i64 v101
  v103 = iconst.i64 19
  v104 = shl.i64 v102, v103
  v105 = or.i64 v100, v104
  ret v105
fn @z8
  sig (i32) -> i32
b0(v0: i32):
  v1 = trunc.i8 v0
  v2 = iconst.i8 0
  v3 = icmp.eq v1, v2
  br v3, b1, b2
b1:
  v4 = iconst.i32 7
  ret v4
b2:
  v5 = iconst.i32 9
  ret v5
fn @j8
  sig (i64, i64) -> i32
b0(v0: i64, v1: i64):
  v2 = trunc.i8 v0
  v3 = trunc.i8 v1
  v4 = iconst.i8 3
  v5 = iconst.i8 0
  v6 = icmp.slt v2, v4
  v7 = icmp.ne v3, v5
  v8 = and.i8 v6, v7
  v9 = iconst.i32 11
  v10 = iconst.i32 13
  v11 = select.i32 v8, v9, v10
  ret v11
fn @c16
  sig (i64, i32) -> i64
b0(v0: i64, v1: i32):
  v2 = trunc.i16 v0
  v3 = trunc.i16 v1
  v4 = iconst.i16 5
  v5 = iconst.i64 0
  v6 = icmp.eq v2, v3
  v7 = zext.i64 v6
  v8 = iconst.i64 0
  v9 = shl.i64 v7, v8
  v10 = or.i64 v5, v9
  v11 = icmp.eq v2, v4
  v12 = zext.i64 v11
  v13 = iconst.i64 1
  v14 = shl.i64 v12, v13
  v15 = or.i64 v10, v14
  v16 = icmp.ne v2, v3
  v17 = zext.i64 v16
  v18 = iconst.i64 2
  v19 = shl.i64 v17, v18
  v20 = or.i64 v15, v19
  v21 = icmp.ne v2, v4
  v22 = zext.i64 v21
  v23 = iconst.i64 3
  v24 = shl.i64 v22, v23
  v25 = or.i64 v20, v24
  v26 = icmp.slt v2, v3
  v27 = zext.i64 v26
  v28 = iconst.i64 4
  v29 = shl.i64 v27, v28
  v30 = or.i64 v25, v29
  v31 = icmp.slt v2, v4
  v32 = zext.i64 v31
  v33 = iconst.i64 5
  v34 = shl.i64 v32, v33
  v35 = or.i64 v30, v34
  v36 = icmp.sle v2, v3
  v37 = zext.i64 v36
  v38 = iconst.i64 6
  v39 = shl.i64 v37, v38
  v40 = or.i64 v35, v39
  v41 = icmp.sle v2, v4
  v42 = zext.i64 v41
  v43 = iconst.i64 7
  v44 = shl.i64 v42, v43
  v45 = or.i64 v40, v44
  v46 = icmp.sgt v2, v3
  v47 = zext.i64 v46
  v48 = iconst.i64 8
  v49 = shl.i64 v47, v48
  v50 = or.i64 v45, v49
  v51 = icmp.sgt v2, v4
  v52 = zext.i64 v51
  v53 = iconst.i64 9
  v54 = shl.i64 v52, v53
  v55 = or.i64 v50, v54
  v56 = icmp.sge v2, v3
  v57 = zext.i64 v56
  v58 = iconst.i64 10
  v59 = shl.i64 v57, v58
  v60 = or.i64 v55, v59
  v61 = icmp.sge v2, v4
  v62 = zext.i64 v61
  v63 = iconst.i64 11
  v64 = shl.i64 v62, v63
  v65 = or.i64 v60, v64
  v66 = icmp.ult v2, v3
  v67 = zext.i64 v66
  v68 = iconst.i64 12
  v69 = shl.i64 v67, v68
  v70 = or.i64 v65, v69
  v71 = icmp.ult v2, v4
  v72 = zext.i64 v71
  v73 = iconst.i64 13
  v74 = shl.i64 v72, v73
  v75 = or.i64 v70, v74
  v76 = icmp.ule v2, v3
  v77 = zext.i64 v76
  v78 = iconst.i64 14
  v79 = shl.i64 v77, v78
  v80 = or.i64 v75, v79
  v81 = icmp.ule v2, v4
  v82 = zext.i64 v81
  v83 = iconst.i64 15
  v84 = shl.i64 v82, v83
  v85 = or.i64 v80, v84
  v86 = icmp.ugt v2, v3
  v87 = zext.i64 v86
  v88 = iconst.i64 16
  v89 = shl.i64 v87, v88
  v90 = or.i64 v85, v89
  v91 = icmp.ugt v2, v4
  v92 = zext.i64 v91
  v93 = iconst.i64 17
  v94 = shl.i64 v92, v93
  v95 = or.i64 v90, v94
  v96 = icmp.uge v2, v3
  v97 = zext.i64 v96
  v98 = iconst.i64 18
  v99 = shl.i64 v97, v98
  v100 = or.i64 v95, v99
  v101 = icmp.uge v2, v4
  v102 = zext.i64 v101
  v103 = iconst.i64 19
  v104 = shl.i64 v102, v103
  v105 = or.i64 v100, v104
  ret v105
fn @z16
  sig (i32) -> i32
b0(v0: i32):
  v1 = trunc.i16 v0
  v2 = iconst.i16 0
  v3 = icmp.eq v1, v2
  br v3, b1, b2
b1:
  v4 = iconst.i32 7
  ret v4
b2:
  v5 = iconst.i32 9
  ret v5
fn @j16
  sig (i64, i64) -> i32
b0(v0: i64, v1: i64):
  v2 = trunc.i16 v0
  v3 = trunc.i16 v1
  v4 = iconst.i16 3
  v5 = iconst.i16 0
  v6 = icmp.slt v2, v4
  v7 = icmp.ne v3, v5
  v8 = and.i8 v6, v7
  v9 = iconst.i32 11
  v10 = iconst.i32 13
  v11 = select.i32 v8, v9, v10
  ret v11
)";
    let drv = M"(#include <stdint.h>
int64_t c8(int64_t, int32_t);
int32_t z8(int32_t);
int32_t j8(int64_t, int64_t);
int64_t c16(int64_t, int32_t);
int32_t z16(int32_t);
int32_t j16(int64_t, int64_t);
static int64_t want8(int64_t x, int32_t y) {
  int8_t sa = (int8_t)x, sb = (int8_t)y, sk = 5;
  uint8_t ua = (uint8_t)x, ub = (uint8_t)y, uk = 5;
  int64_t r = 0; int bit = 0;
  r |= (int64_t)(ua == ub) << bit++;
  r |= (int64_t)(ua == uk) << bit++;
  r |= (int64_t)(ua != ub) << bit++;
  r |= (int64_t)(ua != uk) << bit++;
  r |= (int64_t)(sa < sb) << bit++;
  r |= (int64_t)(sa < sk) << bit++;
  r |= (int64_t)(sa <= sb) << bit++;
  r |= (int64_t)(sa <= sk) << bit++;
  r |= (int64_t)(sa > sb) << bit++;
  r |= (int64_t)(sa > sk) << bit++;
  r |= (int64_t)(sa >= sb) << bit++;
  r |= (int64_t)(sa >= sk) << bit++;
  r |= (int64_t)(ua < ub) << bit++;
  r |= (int64_t)(ua < uk) << bit++;
  r |= (int64_t)(ua <= ub) << bit++;
  r |= (int64_t)(ua <= uk) << bit++;
  r |= (int64_t)(ua > ub) << bit++;
  r |= (int64_t)(ua > uk) << bit++;
  r |= (int64_t)(ua >= ub) << bit++;
  r |= (int64_t)(ua >= uk) << bit++;
  return r;
}
static int64_t want16(int64_t x, int32_t y) {
  int16_t sa = (int16_t)x, sb = (int16_t)y, sk = 5;
  uint16_t ua = (uint16_t)x, ub = (uint16_t)y, uk = 5;
  int64_t r = 0; int bit = 0;
  r |= (int64_t)(ua == ub) << bit++;
  r |= (int64_t)(ua == uk) << bit++;
  r |= (int64_t)(ua != ub) << bit++;
  r |= (int64_t)(ua != uk) << bit++;
  r |= (int64_t)(sa < sb) << bit++;
  r |= (int64_t)(sa < sk) << bit++;
  r |= (int64_t)(sa <= sb) << bit++;
  r |= (int64_t)(sa <= sk) << bit++;
  r |= (int64_t)(sa > sb) << bit++;
  r |= (int64_t)(sa > sk) << bit++;
  r |= (int64_t)(sa >= sb) << bit++;
  r |= (int64_t)(sa >= sk) << bit++;
  r |= (int64_t)(ua < ub) << bit++;
  r |= (int64_t)(ua < uk) << bit++;
  r |= (int64_t)(ua <= ub) << bit++;
  r |= (int64_t)(ua <= uk) << bit++;
  r |= (int64_t)(ua > ub) << bit++;
  r |= (int64_t)(ua > uk) << bit++;
  r |= (int64_t)(ua >= ub) << bit++;
  r |= (int64_t)(ua >= uk) << bit++;
  return r;
}
int main(void) {
  static const int64_t xs[] = {0, 1, 5, 6, -1, -5, 127, 128, 255, 256, 0x7FFF, 0x8000, 0xFFFF, 0x10005, -0x10000, 0x123456789ABCDEF0};
  for (int i = 0; i < 16; i++)
    for (int j = 0; j < 16; j++) {
      int64_t x = xs[i], y = xs[j];
      if (c8(x, (int32_t)y) != want8(x, (int32_t)y)) return 8;
      if (z8((int32_t)x) != ((int8_t)x == 0 ? 7 : 9)) return 9;
      if (j8(x, y) != ((int8_t)x < 3 && (int8_t)y != 0 ? 11 : 13)) return 10;
      if (c16(x, (int32_t)y) != want16(x, (int32_t)y)) return 16;
      if (z16((int32_t)x) != ((int16_t)x == 0 ? 7 : 9)) return 17;
      if (j16(x, y) != ((int16_t)x < 3 && (int16_t)y != 0 ? 11 : 13)) return 18;
    }
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Sums and differences of two-word values: the high words with the low words' carry or borrow (`addo`,
// `subo` and the extension of their flag), 64 and 32 bits, either operand order, a constant high word, and
// a comparison between, which sets the flags, so that sum does not fold (`lv::FOLD_ADC`: `adc`, `sbc`,
// x86-64 `sbb`).
@test
fn sums_with_a_carry_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @add64 fn global
sym @sub64 fn global
sym @add32 fn global
sym @addk fn global
sym @mixed fn global
fn @add64
  sig (ptr, i64, i64, i64, i64) -> void
b0(v0: ptr, v1: i64, v2: i64, v3: i64, v4: i64):
  v5, v6 = addo.u.i64 v1, v3
  v7, v8 = addo.u.i64 v2, v4
  v9 = zext.i64 v6
  v10, v11 = addo.u.i64 v9, v7
  store v5, v0 align 3
  store v10, v0+8 align 3
  ret
fn @sub64
  sig (ptr, i64, i64, i64, i64) -> void
b0(v0: ptr, v1: i64, v2: i64, v3: i64, v4: i64):
  v5, v6 = subo.u.i64 v1, v3
  v7 = sub.i64 v2, v4
  v8 = zext.i64 v6
  v9 = sub.i64 v7, v8
  store v5, v0 align 3
  store v9, v0+8 align 3
  ret
fn @add32
  sig (ptr, i32, i32, i32, i32) -> void
b0(v0: ptr, v1: i32, v2: i32, v3: i32, v4: i32):
  v5, v6 = addo.u.i32 v1, v3
  v7 = zext.i32 v6
  v8 = add.i32 v2, v4
  v9 = add.i32 v8, v7
  store v5, v0 align 2
  store v9, v0+4 align 2
  ret
fn @addk
  sig (ptr, i64, i64, i64) -> void
b0(v0: ptr, v1: i64, v2: i64, v3: i64):
  v4 = iconst.i64 0
  v5, v6 = addo.u.i64 v1, v3
  v7 = add.i64 v2, v4
  v8 = zext.i64 v6
  v9 = add.i64 v7, v8
  store v5, v0 align 3
  store v9, v0+8 align 3
  ret
fn @mixed
  sig (ptr, i64, i64, i64, i64) -> void
b0(v0: ptr, v1: i64, v2: i64, v3: i64, v4: i64):
  v5, v6 = addo.u.i64 v1, v3
  v7 = icmp.ult v2, v4
  v8 = add.i64 v2, v4
  v9 = zext.i64 v6
  v10 = add.i64 v8, v9
  v11 = zext.i64 v7
  store v5, v0 align 3
  store v10, v0+8 align 3
  store v11, v0+16 align 3
  ret
)";
    let drv = M"(#include <stdint.h>
void add64(uint64_t *, uint64_t, uint64_t, uint64_t, uint64_t);
void sub64(uint64_t *, uint64_t, uint64_t, uint64_t, uint64_t);
void add32(uint32_t *, uint32_t, uint32_t, uint32_t, uint32_t);
void addk(uint64_t *, uint64_t, uint64_t, uint64_t);
void mixed(uint64_t *, uint64_t, uint64_t, uint64_t, uint64_t);
int main(void) {
  static const uint64_t xs[] = {0, 1, 2, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x100000000ull, 0x7FFFFFFFFFFFFFFFull, 0x8000000000000000ull, 0xFFFFFFFFFFFFFFFEull, 0xFFFFFFFFFFFFFFFFull, 0x123456789ABCDEFull};
  for (int i = 0; i < 12; i++)
    for (int j = 0; j < 12; j++) {
      uint64_t x = xs[i], y = xs[j], h1 = xs[(i + 3) % 12], h2 = xs[(j + 5) % 12];
      unsigned __int128 a = (unsigned __int128)h1 << 64 | x, b = (unsigned __int128)h2 << 64 | y;
      uint64_t r[3];
      add64(r, x, h1, y, h2);
      unsigned __int128 s = a + b;
      if (r[0] != (uint64_t)s || r[1] != (uint64_t)(s >> 64)) return 1;
      sub64(r, x, h1, y, h2);
      unsigned __int128 d = a - b;
      if (r[0] != (uint64_t)d || r[1] != (uint64_t)(d >> 64)) return 2;
      uint32_t q[2];
      add32(q, (uint32_t)x, (uint32_t)h1, (uint32_t)y, (uint32_t)h2);
      uint64_t s32 = ((uint64_t)(uint32_t)h1 << 32 | (uint32_t)x) + ((uint64_t)(uint32_t)h2 << 32 | (uint32_t)y);
      if (q[0] != (uint32_t)s32 || q[1] != (uint32_t)(s32 >> 32)) return 3;
      addk(r, x, h1, y);
      unsigned __int128 sk = a + y;
      if (r[0] != (uint64_t)sk || r[1] != (uint64_t)(sk >> 64)) return 4;
      mixed(r, x, h1, y, h2);
      uint64_t lo = x + y, hi = h1 + h2 + (lo < x);
      if (r[0] != lo || r[1] != hi || r[2] != (h1 < h2)) return 5;
    }
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Fills, copies and overlapping moves of run-time sizes (`memset`, `memcpy`, `memcpy` with MEM_OVERLAP):
// the C routines on arm64 and x86-64, the bulk memory forms on wasm32 (`memory.fill`, `memory.copy`).
// Right before a return, with sibling calls, the routine is one (no `BL` on arm64), but for a copy out of
// the frame (`stage`), which the epilogue would free first.
@test
fn memory_operations_of_run_time_sizes_run() {
    let lir = M"(lir ptr 8
sym @fill fn global
sym @copy fn global
sym @move fn global
sym @stage fn global
fn @fill
  sig (ptr, i8, i64) -> void
b0(v0: ptr, v1: i8, v2: i64):
  memset v0, v1, v2
  ret
fn @copy
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  memcpy v0, v1, v2
  ret
fn @move
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  memcpy.overlap v0, v1, v2
  ret
fn @stage
  sig (ptr, i64) -> void
  slot s0 size 64 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i8 9
  v4 = iconst.i64 64
  memset v2, v3, v4
  memcpy v0, v2, v1
  ret
)";
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(lir, tgt::axis_index("linux", false), tgt::axis_index("aarch64", true), TAIL, &mut obj),
        "the arm64 object",
    );
    assert_eq(elf_text_count(&obj, 0xFC000000, 0x94000000), 1);
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = M"(#include <stdint.h>
#include <string.h>
void fill(uint8_t *, int8_t, int64_t);
void copy(uint8_t *, const uint8_t *, int64_t);
void move(uint8_t *, const uint8_t *, int64_t);
void stage(uint8_t *, int64_t);
int main(void) {
  for (int64_t n = 0; n < 40; n++) {
    uint8_t a[64], b[64], c[64];
    for (int k = 0; k < 64; k++) { a[k] = (uint8_t)k; b[k] = (uint8_t)(200 - k); }
    memcpy(c, a, 64);
    fill(a + 3, (int8_t)0x5A, n);
    for (int k = 0; k < 64; k++) if (a[k] != (k >= 3 && k < 3 + n ? 0x5A : (uint8_t)k)) return 1;
    copy(b + 1, c + 2, n);
    for (int k = 0; k < 64; k++) if (b[k] != (k >= 1 && k < 1 + n ? (uint8_t)(k + 1) : (uint8_t)(200 - k))) return 2;
    move(c + 5, c + 1, n);
    for (int k = 0; k < 64; k++) if (c[k] != (k >= 5 && k < 5 + n ? (uint8_t)(k - 4) : (uint8_t)k)) return 3;
    memset(a, 0, 64);
    stage(a, n);
    for (int k = 0; k < 64; k++) if (a[k] != (k < n ? 9 : 0)) return 4;
  }
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_native_with(lir, drv, TAIL), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// How many 32-bit words of the `.text` section of ELF object `o` have bits `mask` equal to `want`.
fn elf_text_count(o: &Vector<u8>, mask: u32, want: u32) u32 {
    let shoff = le_at(o, 0x28, 8) as usize;
    let shsize = le_at(o, 0x3A, 2) as usize;
    let strs = le_at(o, shoff + le_at(o, 0x3E, 2) as usize * shsize + 0x18, 8) as usize;
    let mut n: u32 = 0;
    for k in 0..le_at(o, 0x3C, 2) as usize {
        let sh = shoff + k * shsize;
        let name = strs + le_at(o, sh, 4) as usize;
        if !(o[name] == b'.' && o[name + 1] == b't' && o[name + 2] == b'e' && o[name + 3] == b'x' && o[name + 4] == b't' && o[name + 5] == 0) {
            continue;
        }
        let off = le_at(o, sh + 0x18, 8) as usize;
        for w in 0..le_at(o, sh + 0x20, 8) as usize / 4 {
            n += ((le_at(o, off + w * 4, 4) as u32 & mask) == want) as u32;
        }
    }
    return n;
}

// The `n`-byte little-endian integer at `o[at..]`.
fn le_at(o: &Vector<u8>, at: usize, n: usize) u64 {
    let mut v: u64 = 0;
    for k in 0..n {
        v |= o[at + k] as u64 << (8 * k) as u64;
    }
    return v;
}

// Loops whose exit passes a value the back edge passes on too (a swap: Euclid's remainders, Fibonacci
// pairs), ending on a register test or on flags: one edge's moves among the other's run before the branch
// (arm64 `homes_free`), the test's register kept.
@test
fn loops_ending_on_a_swap_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @gcd fn global
sym @fibm fn global
fn @gcd
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 0
  v3 = icmp.eq v1, v2
  br v3, b2(v0), b1(v0, v1)
b1(v4: i32, v5: i32):
  v6 = urem.i32 v4, v5
  v7 = icmp.eq v6, v2
  br v7, b2(v5), b1(v5, v6)
b2(v8: i32):
  ret v8
fn @fibm
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2, v3, v0)
b1(v4: i64, v5: i64, v6: i64):
  v7 = add.i64 v4, v5
  v8 = urem.i64 v7, v1
  v9 = sub.i64 v6, v3
  v10 = icmp.ult v9, v3
  br v10, b2(v5), b1(v5, v8, v9)
b2(v11: i64):
  ret v11
)";
    let drv = "#include <stdint.h>\nuint32_t gcd(uint32_t, uint32_t);\nuint64_t fibm(uint64_t, uint64_t);\nint main(void) {\n  for (uint32_t a = 0; a < 60; a++)\n    for (uint32_t b = 0; b < 60; b++) {\n      uint32_t x = a, y = b;\n      while (y != 0) { uint32_t r = x % y; x = y; y = r; }\n      if (gcd(a, b) != x) return 1;\n    }\n  for (uint64_t n = 1; n < 40; n++) {\n    uint64_t p = 0, q = 1, k = n;\n    for (;;) { uint64_t s = (p + q) % 1000003; k--; if (k < 1) break; p = q; q = s; }\n    if (fibm(n, 1000003) != q) return 2;\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A branch on an `and` of two comparisons whose second operand lives in memory across a call, its false
// edge the next block: the jump after the first comparison does not take that block, which keeps the
// registers the second comparison leaves (x86-64 `branch_conj`).
@test
fn a_conjunction_past_a_call_runs() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @opq fn global
sym @conj fn global
fn @conj
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = mul.i64 v0, v2
  v4 = add.i64 v3, v1
  v5 = iconst.i64 4
  v6 = mul.i64 v0, v5
  v7 = add.i64 v6, v1
  v8 = iconst.i64 7
  v9 = mul.i64 v0, v8
  v10 = add.i64 v9, v1
  v11 = iconst.i64 10
  v12 = mul.i64 v0, v11
  v13 = add.i64 v12, v1
  v14 = iconst.i64 13
  v15 = mul.i64 v0, v14
  v16 = add.i64 v15, v1
  v17 = iconst.i64 16
  v18 = mul.i64 v0, v17
  v19 = add.i64 v18, v1
  v20 = iconst.i64 19
  v21 = mul.i64 v0, v20
  v22 = add.i64 v21, v1
  v23 = iconst.i64 22
  v24 = mul.i64 v0, v23
  v25 = add.i64 v24, v1
  v26 = iconst.i64 25
  v27 = mul.i64 v0, v26
  v28 = add.i64 v27, v1
  v29 = iconst.i64 28
  v30 = mul.i64 v0, v29
  v31 = add.i64 v30, v1
  v32 = iconst.i64 31
  v33 = mul.i64 v0, v32
  v34 = add.i64 v33, v1
  v35 = iconst.i64 34
  v36 = mul.i64 v0, v35
  v37 = add.i64 v36, v1
  v38 = iconst.i64 37
  v39 = mul.i64 v0, v38
  v40 = add.i64 v39, v1
  v41 = iconst.i64 40
  v42 = mul.i64 v0, v41
  v43 = add.i64 v42, v1
  call @opq() : () -> void
  v44 = iconst.i64 12
  v45 = icmp.eq v0, v44
  v46 = icmp.eq v43, v44
  v47 = and.i8 v45, v46
  br v47, b2, b1
b1:
  v48 = add.i64 v4, v7
  v49 = add.i64 v48, v10
  v50 = add.i64 v49, v13
  v51 = add.i64 v50, v16
  v52 = add.i64 v51, v19
  v53 = add.i64 v52, v22
  v54 = add.i64 v53, v25
  v55 = add.i64 v54, v28
  v56 = add.i64 v55, v31
  v57 = add.i64 v56, v34
  v58 = add.i64 v57, v37
  v59 = add.i64 v58, v40
  v60 = add.i64 v59, v43
  ret v60
b2:
  v61 = iconst.i64 77
  ret v61
)";
    let drv = "#include <stdint.h>\nvoid opq(void) {}\nint64_t conj(int64_t, int64_t);\nint main(void) {\n  static const int64_t c[14] = {1, 4, 7, 10, 13, 16, 19, 22, 25, 28, 31, 34, 37, 40};\n  for (int64_t a = 10; a < 14; a++)\n    for (int64_t b = -60; b < 60; b++) {\n      int64_t s = 0, last = 0;\n      for (int k = 0; k < 14; k++) { last = a * c[k] + b; s += last; }\n      int64_t want = a == 12 && last == 12 ? 77 : s;\n      if (conj(a, b) != want) return 1;\n    }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Leading zero counts of 16 and 8 bits, every value (x86-64: the zero-extended operand's highest set bit
// against the width's, the width for 0).
@test
fn narrow_leading_zero_counts_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @lz16 fn global
sym @lz8 fn global
fn @lz16
  sig (i16) -> i32
b0(v0: i16):
  v1 = clz.i16 v0
  v2 = zext.i32 v1
  ret v2
fn @lz8
  sig (i8) -> i8
b0(v0: i8):
  v1 = clz.i8 v0
  ret v1
)";
    let drv = "#include <stdint.h>\nuint32_t lz16(uint16_t);\nuint8_t lz8(uint8_t);\nint main(void) {\n  for (uint32_t x = 0; x < 65536; x++) {\n    uint32_t n = 16;\n    for (uint32_t y = x; y != 0; y >>= 1) n--;\n    if (lz16((uint16_t)x) != n) return 1;\n    if (x < 256 && lz8((uint8_t)x) != (uint8_t)(n - 8)) return 2;\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Bit counts of 64, 32, 16 and 8 bits with the processor's count instruction (x86-64 `popcnt`, the
// narrow operands zero-extended) and without it.
@test
fn bit_counts_with_and_without_popcnt_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @p64 fn global\nsym @p32 fn global\nsym @p16 fn global\nsym @p8 fn global\nfn @p64\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = popcnt.i64 v0\n  ret v1\nfn @p32\n  sig (i32) -> i32\nb0(v0: i32):\n  v1 = popcnt.i32 v0\n  ret v1\nfn @p16\n  sig (i16) -> i16\nb0(v0: i16):\n  v1 = popcnt.i16 v0\n  ret v1\nfn @p8\n  sig (i8) -> i8\nb0(v0: i8):\n  v1 = popcnt.i8 v0\n  ret v1\n";
    let drv = "#include <stdint.h>\nuint64_t p64(uint64_t);\nuint32_t p32(uint32_t);\nuint16_t p16(uint16_t);\nuint8_t p8(uint8_t);\nint main(void) {\n  uint64_t s = 0x9E3779B97F4A7C15u;\n  for (int i = 0; i < 1000; i++) {\n    s ^= s << 13;\n    s ^= s >> 7;\n    s ^= s << 17;\n    if (p64(s) != (uint64_t)__builtin_popcountll(s)) return 1;\n    if (p32((uint32_t)s) != (uint32_t)__builtin_popcount((uint32_t)s)) return 2;\n    if (p16((uint16_t)s) != (uint16_t)__builtin_popcount((uint16_t)s)) return 3;\n    if (p8((uint8_t)s) != (uint8_t)__builtin_popcount((uint8_t)s)) return 4;\n  }\n  if (p64(UINT64_MAX) != 64 || p64(0) != 0 || p32(UINT32_MAX) != 32 || p16(0xFFFF) != 16 || p8(0xFF) != 8) return 5;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_popcnt(lir, drv), 0);
}

// The C library's exact rounding, absolute value, minimum and maximum of f64 and f32, which arm64 expands
// in place of the call (`frintm`, `frintp`, `frinta`, `frintz`, `fabs`, `fminnm`, `fmaxnm`) and x86-64 too
// (SSE2's `andpd`, `minsd`, `maxsd`; SSE4.1's `roundsd`), equal the library's on signed zeros, halves, the
// last fraction below one half, infinities and NaN (a minimum or maximum of two zeros may be either).
@test
fn libm_rounding_minimum_and_maximum_calls_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @floor fn global\nsym @t_floor fn global\nsym @floorf fn global\nsym @t_floorf fn global\nsym @ceil fn global\nsym @t_ceil fn global\nsym @ceilf fn global\nsym @t_ceilf fn global\nsym @round fn global\nsym @t_round fn global\nsym @roundf fn global\nsym @t_roundf fn global\nsym @trunc fn global\nsym @t_trunc fn global\nsym @truncf fn global\nsym @t_truncf fn global\nsym @fabs fn global\nsym @t_fabs fn global\nsym @fabsf fn global\nsym @t_fabsf fn global\nsym @fmin fn global\nsym @t_fmin fn global\nsym @fminf fn global\nsym @t_fminf fn global\nsym @fmax fn global\nsym @t_fmax fn global\nsym @fmaxf fn global\nsym @t_fmaxf fn global\nfn @t_floor\n  sig (f64) -> f64\nb0(v0: f64):\n  v1 = call.f64 @floor(v0) : (f64) -> f64\n  ret v1\nfn @t_floorf\n  sig (f32) -> f32\nb0(v0: f32):\n  v1 = call.f32 @floorf(v0) : (f32) -> f32\n  ret v1\nfn @t_ceil\n  sig (f64) -> f64\nb0(v0: f64):\n  v1 = call.f64 @ceil(v0) : (f64) -> f64\n  ret v1\nfn @t_ceilf\n  sig (f32) -> f32\nb0(v0: f32):\n  v1 = call.f32 @ceilf(v0) : (f32) -> f32\n  ret v1\nfn @t_round\n  sig (f64) -> f64\nb0(v0: f64):\n  v1 = call.f64 @round(v0) : (f64) -> f64\n  ret v1\nfn @t_roundf\n  sig (f32) -> f32\nb0(v0: f32):\n  v1 = call.f32 @roundf(v0) : (f32) -> f32\n  ret v1\nfn @t_trunc\n  sig (f64) -> f64\nb0(v0: f64):\n  v1 = call.f64 @trunc(v0) : (f64) -> f64\n  ret v1\nfn @t_truncf\n  sig (f32) -> f32\nb0(v0: f32):\n  v1 = call.f32 @truncf(v0) : (f32) -> f32\n  ret v1\nfn @t_fabs\n  sig (f64) -> f64\nb0(v0: f64):\n  v1 = call.f64 @fabs(v0) : (f64) -> f64\n  ret v1\nfn @t_fabsf\n  sig (f32) -> f32\nb0(v0: f32):\n  v1 = call.f32 @fabsf(v0) : (f32) -> f32\n  ret v1\nfn @t_fmin\n  sig (f64, f64) -> f64\nb0(v0: f64, v1: f64):\n  v2 = call.f64 @fmin(v0, v1) : (f64, f64) -> f64\n  ret v2\nfn @t_fminf\n  sig (f32, f32) -> f32\nb0(v0: f32, v1: f32):\n  v2 = call.f32 @fminf(v0, v1) : (f32, f32) -> f32\n  ret v2\nfn @t_fmax\n  sig (f64, f64) -> f64\nb0(v0: f64, v1: f64):\n  v2 = call.f64 @fmax(v0, v1) : (f64, f64) -> f64\n  ret v2\nfn @t_fmaxf\n  sig (f32, f32) -> f32\nb0(v0: f32, v1: f32):\n  v2 = call.f32 @fmaxf(v0, v1) : (f32, f32) -> f32\n  ret v2\n";
    let drv = "#include <math.h>\n#include <string.h>\n#include <stdint.h>\ndouble t_floor(double);\nfloat t_floorf(float);\ndouble t_ceil(double);\nfloat t_ceilf(float);\ndouble t_round(double);\nfloat t_roundf(float);\ndouble t_trunc(double);\nfloat t_truncf(float);\ndouble t_fabs(double);\nfloat t_fabsf(float);\ndouble t_fmin(double, double);\nfloat t_fminf(float, float);\ndouble t_fmax(double, double);\nfloat t_fmaxf(float, float);\nstatic int same64(double x, double y) { uint64_t a, b; memcpy(&a, &x, 8); memcpy(&b, &y, 8); return a == b || (x != x && y != y) || (x == 0 && y == 0); }\nstatic int same32(float x, float y) { uint32_t a, b; memcpy(&a, &x, 4); memcpy(&b, &y, 4); return a == b || (x != x && y != y) || (x == 0 && y == 0); }\nstatic int bits64(double x, double y) { uint64_t a, b; memcpy(&a, &x, 8); memcpy(&b, &y, 8); return a == b || (x != x && y != y); }\nstatic int bits32(float x, float y) { uint32_t a, b; memcpy(&a, &x, 4); memcpy(&b, &y, 4); return a == b || (x != x && y != y); }\nint main(void) {\n  double v[14] = {0.0, -0.0, 0.5, -0.5, 1.5, -1.5, 2.5, -2.5, 0.49999999999999994, 4503599627370497.0, 1e300, -INFINITY, NAN, -3.75};\n  for (int i = 0; i < 14; i++) {\n    double x = v[i];\n    float f = (float)x;\n    if (!bits64(t_floor(x), floor(x))) return 1;\n    if (!bits32(t_floorf(f), floorf(f))) return 2;\n    if (!bits64(t_ceil(x), ceil(x))) return 3;\n    if (!bits32(t_ceilf(f), ceilf(f))) return 4;\n    if (!bits64(t_round(x), round(x))) return 5;\n    if (!bits32(t_roundf(f), roundf(f))) return 6;\n    if (!bits64(t_trunc(x), trunc(x))) return 7;\n    if (!bits32(t_truncf(f), truncf(f))) return 8;\n    if (!bits64(t_fabs(x), fabs(x))) return 9;\n    if (!bits32(t_fabsf(f), fabsf(f))) return 10;\n    for (int j = 0; j < 14; j++) {\n      double y = v[j];\n      float g = (float)y;\n      if (!same64(t_fmin(x, y), fmin(x, y))) return 11;\n      if (!same32(t_fminf(f, g), fminf(f, g))) return 12;\n      if (!same64(t_fmax(x, y), fmax(x, y))) return 13;\n      if (!same32(t_fmaxf(f, g), fmaxf(f, g))) return 14;\n    }\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_sse41(lir, drv), 0);
}

// The float lane operations the loop vectorizer makes of C's calls (`vop.abs`, `floor`, `ceil`, `trunc`,
// `min.num`, `max.num`, `fma`) equal the library's lane by lane through signed zeros, halves, infinities,
// subnormals and quiet and signaling NaNs; a minimum or maximum of a vector in one register equals the
// scalar call's bits (x86-64: the packed forms of its expansion; arm64: FMINNM and FMAXNM). x86-64
// computes them in registers with SSE2 and SSE4.1, AVX2 and FMA3, AVX-512.
@test
fn float_lane_operations_run() {
    let mut lir = String::from_str(
        "lir ptr 8\nsym @fminf fn global\nsym @fmaxf fn global\nsym @fmin fn global\nsym @fmax fn global\n",
    );
    let tys: [str; 6] = ["v4f32", "v8f32", "v16f32", "v2f64", "v4f64", "v8f64"];
    let nbs: [u32; 6] = [16, 32, 64, 16, 32, 64];
    // The bodies of vectors of at most 32 bytes, which x86-64 holds in registers with AVX2.
    let mut regs = String::from_str("lir ptr 8\n");
    for q in 0..6usize {
        let t = tys[q];
        let mut one = String::new();
        one.format_into(
            "sym @v_{} fn global\nfn @v_{}\n  sig (ptr, ptr, ptr, ptr) -> void\nb0(v0: ptr, v1: ptr, v2: ptr, v3: ptr):\n  v4 = load.{} v0 align 0\n  v5 = load.{} v1 align 0\n  v6 = load.{} v2 align 0\n  v7 = vop.abs.{} (v4)\n  v8 = vop.floor.{} (v4)\n  v9 = vop.ceil.{} (v4)\n  v10 = vop.trunc.{} (v4)\n  v11 = vop.min.num.{} (v4, v5)\n  v12 = vop.max.num.{} (v4, v5)\n  v13 = vop.fma.{} (v4, v5, v6)\n",
            t,
            t,
            t,
            t,
            t,
            t,
            t,
            t,
            t,
            t,
            t,
            t,
        );
        for k in 0..7u32 {
            one.format_into("  store v{}, v3+{} align 0\n", 7 + k, k * nbs[q]);
        }
        one.push_str("  ret\n");
        lir.push_str(&one);
        if nbs[q] <= 32 {
            regs.push_str(&one);
        }
    }
    let names: [str; 4] = ["fminf", "fmaxf", "fmin", "fmax"];
    for q in 0..4usize {
        let ft = if q < 2 {
            "f32"
        } else {
            "f64"
        };
        lir.format_into(
            "sym @s{} fn global\nfn @s{}\n  sig ({}, {}) -> {}\nb0(v0: {}, v1: {}):\n  v2 = call.{} @{}(v0, v1) : ({}, {}) -> {}\n  ret v2\n",
            names[q].slice(1, names[q].len()),
            names[q].slice(1, names[q].len()),
            ft,
            ft,
            ft,
            ft,
            ft,
            ft,
            names[q],
            ft,
            ft,
            ft,
        );
    }
    // x86-64's objects: ROUNDPS and ROUNDPD with SSE4.1, a packed unordered comparison (CMPPS 3, of C's
    // `fmin` and `fmax`), and with AVX2 and FMA3 no call of `fma` or `fmaf`.
    let x64 = tgt::axis_index("x86_64", true);
    let mut obj = Vector::<u8>::new();
    assert(object_of(&regs, tgt::axis_index("linux", false), x64, SSE41, &mut obj), "the x86-64 object");
    let mut rps = false;
    let mut rpd = false;
    let mut unord = false;
    for x in 2..obj.len() - 4 {
        rps = rps || obj[x] == 0x0F && obj[x + 1] == 0x3A && obj[x + 2] == 0x08;
        rpd = rpd || obj[x] == 0x0F && obj[x + 1] == 0x3A && obj[x + 2] == 0x09;
        // The byte before the opcode or its REX prefix: not F3 or F2 (CMPSS, CMPSD).
        let pre = if (obj[x - 1] & 0xF0) == 0x40 {
            obj[x - 2]
        } else {
            obj[x - 1]
        };
        unord = unord || pre != 0xF3 && pre != 0xF2 && obj[x] == 0x0F && obj[x + 1] == 0xC2 && obj[x + 3] == 0x03;
    }
    assert(rps && rpd && unord, "packed roundings and comparisons");
    let mut wide = Vector::<u8>::new();
    assert(object_of(&regs, tgt::axis_index("linux", false), x64, SSE41 | WIDE | FMA, &mut wide), "the AVX2 object");
    let mut calls = false;
    for x in 0..wide.len() - 5 {
        calls = calls || wide[x] == b'f' && wide[x + 1] == b'm' && wide[x + 2] == b'a' && (wide[x + 3] == 0 || wide[x + 3] == b'f' && wide[x + 4] == 0);
    }
    assert(!calls, "a fused multiply-add in registers calls nothing");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = M"(#include <math.h>
#include <string.h>
#include <stdint.h>
typedef void (*lanes_fn)(const void *, const void *, const void *, void *);
void v_v4f32(const void *, const void *, const void *, void *);
void v_v8f32(const void *, const void *, const void *, void *);
void v_v16f32(const void *, const void *, const void *, void *);
void v_v2f64(const void *, const void *, const void *, void *);
void v_v4f64(const void *, const void *, const void *, void *);
void v_v8f64(const void *, const void *, const void *, void *);
float sminf(float, float);
float smaxf(float, float);
double smin(double, double);
double smax(double, double);
static const uint32_t F[16] = {0x00000000u, 0x80000000u, 0x3F000000u, 0xBF000000u, 0x40200000u, 0xC0200000u, 0x3EFFFFFFu, 0x4B000001u, 0x7F800000u, 0xFF800000u, 0x7FC00000u, 0x7FA00000u, 0xFFC00001u, 0x00000001u, 0xC0700000u, 0x3FC00000u};
static const uint64_t D[16] = {0x0u, 0x8000000000000000u, 0x3FE0000000000000u, 0xBFE0000000000000u, 0x4004000000000000u, 0xC004000000000000u, 0x3FDFFFFFFFFFFFFFu, 0x4330000000000001u, 0x7FF0000000000000u, 0xFFF0000000000000u, 0x7FF8000000000000u, 0x7FF4000000000000u, 0xFFF8000000000001u, 0x1u, 0xC00E000000000000u, 0x3FF8000000000000u};
static int nan32(uint32_t x) { return (x & 0x7FFFFFFFu) > 0x7F800000u; }
static int nan64(uint64_t x) { return (x & 0x7FFFFFFFFFFFFFFFu) > 0x7FF0000000000000u; }
static uint32_t b32(float x) { uint32_t u; memcpy(&u, &x, 4); return u; }
static uint64_t b64(double x) { uint64_t u; memcpy(&u, &x, 8); return u; }
static float f32v(uint32_t u) { float x; memcpy(&x, &u, 4); return x; }
static double f64v(uint64_t u) { double x; memcpy(&x, &u, 8); return x; }
/* Lanes of `n` floats; a minimum or maximum equals the scalar call's bits (`exact`), else a NaN may be any. */
static int check32(lanes_fn f, int n, int exact) {
  uint32_t a[16], b[16], c[16], o[7 * 16];
  for (int r = 0; r < 256; r++) {
    for (int k = 0; k < n; k++) { a[k] = F[(r + k) % 16]; b[k] = F[(r / 16 + k) % 16]; c[k] = F[(r * 7 + k) % 16]; }
    f(a, b, c, o);
    for (int k = 0; k < n; k++) {
      float x = f32v(a[k]), y = f32v(b[k]), z = f32v(c[k]);
      uint32_t lo = b32(sminf(x, y)), hi = b32(smaxf(x, y)), m = b32(fmaf(x, y, z));
      if (o[k] != b32(fabsf(x)) && !(nan32(o[k]) && nan32(a[k]))) return 1;
      if (o[n + k] != b32(floorf(x)) && !(nan32(o[n + k]) && nan32(a[k]))) return 2;
      if (o[2 * n + k] != b32(ceilf(x)) && !(nan32(o[2 * n + k]) && nan32(a[k]))) return 3;
      if (o[3 * n + k] != b32(truncf(x)) && !(nan32(o[3 * n + k]) && nan32(a[k]))) return 4;
      if (o[4 * n + k] != lo && (exact || !(nan32(o[4 * n + k]) && nan32(lo)))) return 5;
      if (o[5 * n + k] != hi && (exact || !(nan32(o[5 * n + k]) && nan32(hi)))) return 6;
      if (o[6 * n + k] != m && !(nan32(o[6 * n + k]) && nan32(m))) return 7;
    }
  }
  return 0;
}
static int check64(lanes_fn f, int n, int exact) {
  uint64_t a[8], b[8], c[8], o[7 * 8];
  for (int r = 0; r < 256; r++) {
    for (int k = 0; k < n; k++) { a[k] = D[(r + k) % 16]; b[k] = D[(r / 16 + k) % 16]; c[k] = D[(r * 7 + k) % 16]; }
    f(a, b, c, o);
    for (int k = 0; k < n; k++) {
      double x = f64v(a[k]), y = f64v(b[k]), z = f64v(c[k]);
      uint64_t lo = b64(smin(x, y)), hi = b64(smax(x, y)), m = b64(fma(x, y, z));
      if (o[k] != b64(fabs(x)) && !(nan64(o[k]) && nan64(a[k]))) return 1;
      if (o[n + k] != b64(floor(x)) && !(nan64(o[n + k]) && nan64(a[k]))) return 2;
      if (o[2 * n + k] != b64(ceil(x)) && !(nan64(o[2 * n + k]) && nan64(a[k]))) return 3;
      if (o[3 * n + k] != b64(trunc(x)) && !(nan64(o[3 * n + k]) && nan64(a[k]))) return 4;
      if (o[4 * n + k] != lo && (exact || !(nan64(o[4 * n + k]) && nan64(lo)))) return 5;
      if (o[5 * n + k] != hi && (exact || !(nan64(o[5 * n + k]) && nan64(hi)))) return 6;
      if (o[6 * n + k] != m && !(nan64(o[6 * n + k]) && nan64(m))) return 7;
    }
  }
  return 0;
}
/* wasm32's `fminf` is C code (musl's), which gives the second of two NaNs. */
#ifdef __wasm__
#define EXACT 0
#else
#define EXACT 1
#endif
int main(void) {
  int e;
  if ((e = check32(v_v4f32, 4, EXACT)) != 0) return e;
  if ((e = check64(v_v2f64, 2, EXACT)) != 0) return 10 + e;
  if ((e = check32(v_v8f32, 8, 0)) != 0) return 20 + e;
  if ((e = check64(v_v4f64, 4, 0)) != 0) return 30 + e;
  if ((e = check32(v_v16f32, 16, 0)) != 0) return 40 + e;
  if ((e = check64(v_v8f64, 8, 0)) != 0) return 50 + e;
  return 0;
}
)";
    assert_eq(run_native(&lir, drv), 0);
    assert_eq(run_sse41(&lir, drv), 0);
    assert_eq(run_fma(&lir, drv), 0);
    assert_eq(run_zmm(&lir, drv), 0);
    assert_eq(run_wasm(&lir, drv), 0);
}

// Vector extensions to lanes twice as wide, zero and sign (x86-64: SSE2's unpacking, SSE4.1's `pmovzx`
// and `pmovsx`).
@test
fn vector_extensions_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @vext fn global
fn @vext
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = load.v8i8 v0 align 0
  v3 = zext.v8i16 v2
  v4 = sext.v8i16 v2
  store v3, v1+0 align 0
  store v4, v1+16 align 0
  v5 = load.v4i16 v0 align 0
  v6 = zext.v4i32 v5
  v7 = sext.v4i32 v5
  store v6, v1+32 align 0
  store v7, v1+48 align 0
  v8 = load.v2i32 v0 align 0
  v9 = zext.v2i64 v8
  v10 = sext.v2i64 v8
  store v9, v1+64 align 0
  store v10, v1+80 align 0
  ret
)";
    let drv = "#include <stdint.h>\n#include <string.h>\nvoid vext(const void *, void *);\n#define T(N, S, U, WS, WU, at) { S s[N]; U u[N]; WS ws[N]; WU wu[N]; memcpy(s, a, sizeof s); memcpy(u, a, sizeof u); memcpy(wu, o + at, sizeof wu); memcpy(ws, o + at + 16, sizeof ws); for (int i = 0; i < N; i++) { if (wu[i] != (WU)u[i]) return at / 32 * 2 + 1; if (ws[i] != (WS)s[i]) return at / 32 * 2 + 2; } }\nint main(void) {\n  unsigned char a[8], o[96];\n  for (int k = 0; k < 4; k++) {\n    for (int i = 0; i < 8; i++) a[i] = (unsigned char)(i * 89 + k * 61 + 200);\n    vext(a, o);\n    T(8, int8_t, uint8_t, int16_t, uint16_t, 0) T(4, int16_t, uint16_t, int32_t, uint32_t, 32) T(2, int32_t, uint32_t, int64_t, uint64_t, 64)\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_sse41(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A select of floats of one width on a comparison of floats of the other: the comparison's own width
// compares (on x86-64 a branch on the flags, not a mask of the select's width).
@test
fn float_selects_on_comparisons_of_the_other_width_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @s32on64 fn global\nsym @s64on32 fn global\nfn @s32on64\n  sig (f64, f64, f32, f32) -> f32\nb0(v0: f64, v1: f64, v2: f32, v3: f32):\n  v4 = fcmp.olt v0, v1\n  v5 = select.f32 v4, v2, v3\n  ret v5\nfn @s64on32\n  sig (f32, f32, f64, f64) -> f64\nb0(v0: f32, v1: f32, v2: f64, v3: f64):\n  v4 = fcmp.oge v0, v1\n  v5 = select.f64 v4, v2, v3\n  ret v5\n";
    let drv = "#include <math.h>\nfloat s32on64(double, double, float, float);\ndouble s64on32(float, float, double, double);\nint main(void) {\n  double v[5] = {0.0, -1.5, 2.0, 1e300, NAN};\n  for (int i = 0; i < 5; i++)\n    for (int j = 0; j < 5; j++) {\n      double a = v[i], b = v[j];\n      if (s32on64(a, b, 1.25f, -3.5f) != (a < b ? 1.25f : -3.5f)) return 1;\n      float fa = (float)a, fb = (float)b;\n      if (s64on32(fa, fb, 1e200, -2e-200) != (fa >= fb ? 1e200 : -2e-200)) return 2;\n    }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A select of the lesser or greater of two floats by `<` or `>`, either side first, in 64 and 32 bits
// (x86-64 `mins`, `maxs`: their unordered and equal cases give the second operand, as the select does),
// on NaN, infinities and signed zeros.
@test
fn float_minimum_and_maximum_selects_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @m_olt_ab_f64 fn global\nsym @m_olt_ba_f64 fn global\nsym @m_ogt_ab_f64 fn global\nsym @m_ogt_ba_f64 fn global\nsym @m_olt_ab_f32 fn global\nsym @m_olt_ba_f32 fn global\nsym @m_ogt_ab_f32 fn global\nsym @m_ogt_ba_f32 fn global\nfn @m_olt_ab_f64\n  sig (f64, f64) -> f64\nb0(v0: f64, v1: f64):\n  v2 = fcmp.olt v0, v1\n  v3 = select.f64 v2, v0, v1\n  ret v3\nfn @m_olt_ba_f64\n  sig (f64, f64) -> f64\nb0(v0: f64, v1: f64):\n  v2 = fcmp.olt v0, v1\n  v3 = select.f64 v2, v1, v0\n  ret v3\nfn @m_ogt_ab_f64\n  sig (f64, f64) -> f64\nb0(v0: f64, v1: f64):\n  v2 = fcmp.ogt v0, v1\n  v3 = select.f64 v2, v0, v1\n  ret v3\nfn @m_ogt_ba_f64\n  sig (f64, f64) -> f64\nb0(v0: f64, v1: f64):\n  v2 = fcmp.ogt v0, v1\n  v3 = select.f64 v2, v1, v0\n  ret v3\nfn @m_olt_ab_f32\n  sig (f32, f32) -> f32\nb0(v0: f32, v1: f32):\n  v2 = fcmp.olt v0, v1\n  v3 = select.f32 v2, v0, v1\n  ret v3\nfn @m_olt_ba_f32\n  sig (f32, f32) -> f32\nb0(v0: f32, v1: f32):\n  v2 = fcmp.olt v0, v1\n  v3 = select.f32 v2, v1, v0\n  ret v3\nfn @m_ogt_ab_f32\n  sig (f32, f32) -> f32\nb0(v0: f32, v1: f32):\n  v2 = fcmp.ogt v0, v1\n  v3 = select.f32 v2, v0, v1\n  ret v3\nfn @m_ogt_ba_f32\n  sig (f32, f32) -> f32\nb0(v0: f32, v1: f32):\n  v2 = fcmp.ogt v0, v1\n  v3 = select.f32 v2, v1, v0\n  ret v3\n";
    let drv = "#include <math.h>\n#include <string.h>\n#include <stdint.h>\ndouble m_olt_ab_f64(double, double);\ndouble m_olt_ba_f64(double, double);\ndouble m_ogt_ab_f64(double, double);\ndouble m_ogt_ba_f64(double, double);\nfloat m_olt_ab_f32(float, float);\nfloat m_olt_ba_f32(float, float);\nfloat m_ogt_ab_f32(float, float);\nfloat m_ogt_ba_f32(float, float);\nstatic int same64(double x, double y) { uint64_t a, b; memcpy(&a, &x, 8); memcpy(&b, &y, 8); return a == b || (x != x && y != y); }\nstatic int same32(float x, float y) { uint32_t a, b; memcpy(&a, &x, 4); memcpy(&b, &y, 4); return a == b || (x != x && y != y); }\nint main(void) {\n  double v[7] = {0.0, -0.0, 1.0, -2.5, 1e300, -INFINITY, NAN};\n  for (int i = 0; i < 7; i++)\n    for (int j = 0; j < 7; j++) {\n      double a = v[i], b = v[j];\n      float fa = (float)a, fb = (float)b;\n      if (!same64(m_olt_ab_f64(a, b), a < b ? a : b)) return 1;\n      if (!same64(m_olt_ba_f64(a, b), a < b ? b : a)) return 2;\n      if (!same64(m_ogt_ab_f64(a, b), a > b ? a : b)) return 3;\n      if (!same64(m_ogt_ba_f64(a, b), a > b ? b : a)) return 4;\n      if (!same32(m_olt_ab_f32(fa, fb), fa < fb ? fa : fb)) return 5;\n      if (!same32(m_olt_ba_f32(fa, fb), fa < fb ? fb : fa)) return 6;\n      if (!same32(m_ogt_ab_f32(fa, fb), fa > fb ? fa : fb)) return 7;\n      if (!same32(m_ogt_ba_f32(fa, fb), fa > fb ? fb : fa)) return 8;\n    }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A select of a value and that value plus 1 on an unsigned order comparison, the increment on either
// side, in 32 and 64 bits, a constant compared first (x86-64 `cmp` then `adc 0` or `sbb -1`), or on
// another comparison, of bytes or signed (x86-64 `setcc` into a zeroed register, then `add`); the bit
// length `width - clz(x)` (x86-64 `bsr`, `add 1`, `cmove` for 0); comparison values (x86-64 `xor` of the
// register before the compare, `setcc` after).
@test
fn carry_selects_bit_lengths_and_comparison_values_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @c_ult_t32 fn global\nsym @c_ult_t64 fn global\nsym @c_ult_f32 fn global\nsym @c_ult_f64 fn global\nsym @c_ugt_t32 fn global\nsym @c_ugt_t64 fn global\nsym @c_ugt_f32 fn global\nsym @c_ugt_f64 fn global\nsym @c_ule_t32 fn global\nsym @c_ule_t64 fn global\nsym @c_ule_f32 fn global\nsym @c_ule_f64 fn global\nsym @c_uge_t32 fn global\nsym @c_uge_t64 fn global\nsym @c_uge_f32 fn global\nsym @c_uge_f64 fn global\nsym @c_imm fn global\nsym @c_eq8 fn global\nsym @c_slt_f32 fn global\nsym @blen32 fn global\nsym @blen64 fn global\nsym @cmpv fn global\nfn @c_ult_t32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.ult v0, v1\n  v6 = select.i32 v5, v4, v2\n  ret v6\nfn @c_ult_t64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.ult v0, v1\n  v6 = select.i64 v5, v4, v2\n  ret v6\nfn @c_ult_f32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.ult v0, v1\n  v6 = select.i32 v5, v2, v4\n  ret v6\nfn @c_ult_f64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.ult v0, v1\n  v6 = select.i64 v5, v2, v4\n  ret v6\nfn @c_ugt_t32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.ugt v0, v1\n  v6 = select.i32 v5, v4, v2\n  ret v6\nfn @c_ugt_t64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.ugt v0, v1\n  v6 = select.i64 v5, v4, v2\n  ret v6\nfn @c_ugt_f32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.ugt v0, v1\n  v6 = select.i32 v5, v2, v4\n  ret v6\nfn @c_ugt_f64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.ugt v0, v1\n  v6 = select.i64 v5, v2, v4\n  ret v6\nfn @c_ule_t32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.ule v0, v1\n  v6 = select.i32 v5, v4, v2\n  ret v6\nfn @c_ule_t64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.ule v0, v1\n  v6 = select.i64 v5, v4, v2\n  ret v6\nfn @c_ule_f32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.ule v0, v1\n  v6 = select.i32 v5, v2, v4\n  ret v6\nfn @c_ule_f64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.ule v0, v1\n  v6 = select.i64 v5, v2, v4\n  ret v6\nfn @c_uge_t32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.uge v0, v1\n  v6 = select.i32 v5, v4, v2\n  ret v6\nfn @c_uge_t64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.uge v0, v1\n  v6 = select.i64 v5, v4, v2\n  ret v6\nfn @c_uge_f32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.uge v0, v1\n  v6 = select.i32 v5, v2, v4\n  ret v6\nfn @c_uge_f64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.uge v0, v1\n  v6 = select.i64 v5, v2, v4\n  ret v6\nfn @c_imm\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = iconst.i32 1\n  v3 = add.i32 v1, v2\n  v4 = iconst.i32 100\n  v5 = icmp.ugt v4, v0\n  v6 = select.i32 v5, v3, v1\n  ret v6\nfn @c_eq8\n  sig (i8, i8, i64) -> i64\nb0(v0: i8, v1: i8, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.eq v0, v1\n  v6 = select.i64 v5, v4, v2\n  ret v6\nfn @c_slt_f32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.slt v0, v1\n  v6 = select.i32 v5, v2, v4\n  ret v6\nfn @blen32\n  sig (i32) -> i32\nb0(v0: i32):\n  v1 = clz.i32 v0\n  v2 = iconst.i32 32\n  v3 = sub.i32 v2, v1\n  ret v3\nfn @blen64\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = clz.i64 v0\n  v2 = iconst.i64 64\n  v3 = sub.i64 v2, v1\n  ret v3\nfn @cmpv\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = icmp.slt v0, v1\n  v3 = zext.i32 v2\n  v4 = icmp.eq v0, v1\n  v5 = zext.i32 v4\n  v6 = add.i32 v3, v5\n  v7 = icmp.ne v6, v0\n  v8 = zext.i32 v7\n  v9 = add.i32 v6, v8\n  ret v9\n";
    let drv = "#include <stdint.h>\nuint32_t c_ult_t32(uint32_t, uint32_t, uint32_t);\nuint64_t c_ult_t64(uint64_t, uint64_t, uint64_t);\nuint32_t c_ult_f32(uint32_t, uint32_t, uint32_t);\nuint64_t c_ult_f64(uint64_t, uint64_t, uint64_t);\nuint32_t c_ugt_t32(uint32_t, uint32_t, uint32_t);\nuint64_t c_ugt_t64(uint64_t, uint64_t, uint64_t);\nuint32_t c_ugt_f32(uint32_t, uint32_t, uint32_t);\nuint64_t c_ugt_f64(uint64_t, uint64_t, uint64_t);\nuint32_t c_ule_t32(uint32_t, uint32_t, uint32_t);\nuint64_t c_ule_t64(uint64_t, uint64_t, uint64_t);\nuint32_t c_ule_f32(uint32_t, uint32_t, uint32_t);\nuint64_t c_ule_f64(uint64_t, uint64_t, uint64_t);\nuint32_t c_uge_t32(uint32_t, uint32_t, uint32_t);\nuint64_t c_uge_t64(uint64_t, uint64_t, uint64_t);\nuint32_t c_uge_f32(uint32_t, uint32_t, uint32_t);\nuint64_t c_uge_f64(uint64_t, uint64_t, uint64_t);\nuint32_t c_imm(uint32_t, uint32_t);\nuint64_t c_eq8(uint8_t, uint8_t, uint64_t);\nuint32_t c_slt_f32(int32_t, int32_t, uint32_t);\nuint32_t blen32(uint32_t);\nuint64_t blen64(uint64_t);\nint32_t cmpv(int32_t, int32_t);\nint main(void) {\n  uint64_t vs[7] = {0, 1, 2, 99, 100, 0xFFFFFFFFu, UINT64_MAX};\n  for (int i = 0; i < 7; i++)\n    for (int j = 0; j < 7; j++) {\n      uint64_t a = vs[i], b = vs[j], c = vs[(i + j) % 7];\n      uint32_t a32 = (uint32_t)a, b32 = (uint32_t)b, c32 = (uint32_t)c;\n      if (c_ult_t32(a32, b32, c32) != ((a32 < b32) ? (uint32_t)(c32 + 1) : c32)) return 1;\n      if (c_ult_t64(a, b, c) != ((a < b) ? c + 1 : c)) return 2;\n      if (c_ult_f32(a32, b32, c32) != ((a32 < b32) ? c32 : (uint32_t)(c32 + 1))) return 3;\n      if (c_ult_f64(a, b, c) != ((a < b) ? c : c + 1)) return 4;\n      if (c_ugt_t32(a32, b32, c32) != ((a32 > b32) ? (uint32_t)(c32 + 1) : c32)) return 5;\n      if (c_ugt_t64(a, b, c) != ((a > b) ? c + 1 : c)) return 6;\n      if (c_ugt_f32(a32, b32, c32) != ((a32 > b32) ? c32 : (uint32_t)(c32 + 1))) return 7;\n      if (c_ugt_f64(a, b, c) != ((a > b) ? c : c + 1)) return 8;\n      if (c_ule_t32(a32, b32, c32) != ((a32 <= b32) ? (uint32_t)(c32 + 1) : c32)) return 9;\n      if (c_ule_t64(a, b, c) != ((a <= b) ? c + 1 : c)) return 10;\n      if (c_ule_f32(a32, b32, c32) != ((a32 <= b32) ? c32 : (uint32_t)(c32 + 1))) return 11;\n      if (c_ule_f64(a, b, c) != ((a <= b) ? c : c + 1)) return 12;\n      if (c_uge_t32(a32, b32, c32) != ((a32 >= b32) ? (uint32_t)(c32 + 1) : c32)) return 13;\n      if (c_uge_t64(a, b, c) != ((a >= b) ? c + 1 : c)) return 14;\n      if (c_uge_f32(a32, b32, c32) != ((a32 >= b32) ? c32 : (uint32_t)(c32 + 1))) return 15;\n      if (c_uge_f64(a, b, c) != ((a >= b) ? c : c + 1)) return 16;\n      if (c_imm(a32, c32) != (100u > a32 ? c32 + 1 : c32)) return 17;\n      if (c_eq8((uint8_t)a, (uint8_t)b, c) != ((uint8_t)a == (uint8_t)b ? c + 1 : c)) return 21;\n      if (c_slt_f32((int32_t)a32, (int32_t)b32, c32) != ((int32_t)a32 < (int32_t)b32 ? c32 : c32 + 1)) return 22;\n      if (blen32(a32) != (a32 ? 32 - __builtin_clz(a32) : 0)) return 18;\n      if (blen64(a) != (a ? 64 - __builtin_clzll(a) : 0)) return 19;\n      int32_t x = (int32_t)a32, y = (int32_t)b32;\n      int32_t s = (x < y) + (x == y);\n      if (cmpv(x, y) != s + (s != x)) return 20;\n    }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Products of 32-bit lanes in a register, wrapping, of signed and unsigned values, a square and operands
// a load gives: x86-64 SSE2 has no such product (`pmuludq` pairs, through the vector scratch registers
// the operands leave), AVX2 `vpmulld`.
@test
fn products_of_32_bit_lanes_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @mul4 fn global
fn @mul4
  sig (ptr, ptr, ptr) -> void
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.v4i32 v0 align 2
  v4 = load.v4i32 v1 align 2
  v5 = mul.v4i32 v3, v4
  v6 = mul.v4i32 v5, v3
  v7 = mul.v4i32 v6, v6
  v8 = load.v4i32 v1 align 2
  v9 = mul.v4i32 v8, v7
  store v9, v2 align 2
  ret
)";
    let drv = "#include <stdint.h>\nvoid mul4(const uint32_t *, const uint32_t *, uint32_t *);\nint main(void) {\n  uint32_t a[4] = {3, 0xFFFFFFFFu, 0x80000001u, 123456789u};\n  uint32_t b[4] = {7, 0xFFFFFFFEu, 0x7FFFFFFFu, 987654321u};\n  uint32_t d[4];\n  mul4(a, b, d);\n  for (int k = 0; k < 4; k++) {\n    uint32_t e = a[k] * b[k] * a[k];\n    if (d[k] != b[k] * (e * e)) return k + 1;\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wide(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Bits of a vector in a register read as another vector type of its size (`bitcast`): the register
// stays, no memory; halves of 16-bit lanes interleaved with 0 read as 32-bit lanes (a widening).
@test
fn vector_bitcasts_in_registers_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @widen fn global
fn @widen
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = load.v8i16 v0 align 1
  v3 = iconst.i16 0
  v4 = splat.v8i16 v3
  v5 = vziplo.v8i16 v2, v4
  v6 = bitcast.v4i32 v5
  v7 = vziphi.v8i16 v2, v4
  v8 = bitcast.v4i32 v7
  v9 = add.v4i32 v6, v8
  v10 = add.v4i32 v9, v6
  store v10, v1 align 2
  v11 = bitcast.v8i16 v10
  store v11, v1+16 align 1
  ret
)";
    let drv = "#include <stdint.h>\n#include <string.h>\nvoid widen(const uint16_t *, uint32_t *);\nint main(void) {\n  uint16_t a[8] = {1, 2, 65535, 4, 5, 60000, 7, 8};\n  uint32_t d[8];\n  widen(a, d);\n  for (int k = 0; k < 4; k++) if (d[k] != 2u * a[k] + a[k + 4]) return k + 1;\n  if (memcmp(d, d + 4, 16) != 0) return 5;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wide(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A loop that carries 18 vectors, more than the caller-saved vector homes: on arm64 the others take
// v8..v15, whose low halves the prologue saves; none goes through memory, and each sum is right.
@test
fn many_loop_vectors_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @acc fn global\nfn @acc\n  sig (ptr, i64, ptr) -> void\nb0(v0: ptr, v1: i64, v2: ptr):\n  v3 = iconst.i32 0\n  v4 = splat.v4i32 v3\n  v5 = iconst.i64 0\n  jmp b1(v5, v4, v4, v4, v4, v4, v4, v4, v4, v4, v4, v4, v4, v4, v4, v4, v4, v4, v4)\nb1(v6: i64, v7: v4i32, v8: v4i32, v9: v4i32, v10: v4i32, v11: v4i32, v12: v4i32, v13: v4i32, v14: v4i32, v15: v4i32, v16: v4i32, v17: v4i32, v18: v4i32, v19: v4i32, v20: v4i32, v21: v4i32, v22: v4i32, v23: v4i32, v24: v4i32):\n  v25 = icmp.ult v6, v1\n  br v25, b2, b3\nb2:\n  v26 = iconst.i64 288\n  v27 = mul.i64 v6, v26\n  v28 = ptradd v0, v27 * 1\n  v29 = load.v4i32 v28+0 align 2\n  v30 = add.v4i32 v7, v29\n  v31 = load.v4i32 v28+16 align 2\n  v32 = add.v4i32 v8, v31\n  v33 = load.v4i32 v28+32 align 2\n  v34 = add.v4i32 v9, v33\n  v35 = load.v4i32 v28+48 align 2\n  v36 = add.v4i32 v10, v35\n  v37 = load.v4i32 v28+64 align 2\n  v38 = add.v4i32 v11, v37\n  v39 = load.v4i32 v28+80 align 2\n  v40 = add.v4i32 v12, v39\n  v41 = load.v4i32 v28+96 align 2\n  v42 = add.v4i32 v13, v41\n  v43 = load.v4i32 v28+112 align 2\n  v44 = add.v4i32 v14, v43\n  v45 = load.v4i32 v28+128 align 2\n  v46 = add.v4i32 v15, v45\n  v47 = load.v4i32 v28+144 align 2\n  v48 = add.v4i32 v16, v47\n  v49 = load.v4i32 v28+160 align 2\n  v50 = add.v4i32 v17, v49\n  v51 = load.v4i32 v28+176 align 2\n  v52 = add.v4i32 v18, v51\n  v53 = load.v4i32 v28+192 align 2\n  v54 = add.v4i32 v19, v53\n  v55 = load.v4i32 v28+208 align 2\n  v56 = add.v4i32 v20, v55\n  v57 = load.v4i32 v28+224 align 2\n  v58 = add.v4i32 v21, v57\n  v59 = load.v4i32 v28+240 align 2\n  v60 = add.v4i32 v22, v59\n  v61 = load.v4i32 v28+256 align 2\n  v62 = add.v4i32 v23, v61\n  v63 = load.v4i32 v28+272 align 2\n  v64 = add.v4i32 v24, v63\n  v65 = iconst.i64 1\n  v66 = add.i64 v6, v65\n  jmp b1(v66, v30, v32, v34, v36, v38, v40, v42, v44, v46, v48, v50, v52, v54, v56, v58, v60, v62, v64)\nb3:\n  store v7, v2+0 align 2\n  store v8, v2+16 align 2\n  store v9, v2+32 align 2\n  store v10, v2+48 align 2\n  store v11, v2+64 align 2\n  store v12, v2+80 align 2\n  store v13, v2+96 align 2\n  store v14, v2+112 align 2\n  store v15, v2+128 align 2\n  store v16, v2+144 align 2\n  store v17, v2+160 align 2\n  store v18, v2+176 align 2\n  store v19, v2+192 align 2\n  store v20, v2+208 align 2\n  store v21, v2+224 align 2\n  store v22, v2+240 align 2\n  store v23, v2+256 align 2\n  store v24, v2+272 align 2\n  ret\n";
    let drv = "#include <stdint.h>\nvoid acc(const uint32_t *, int64_t, uint32_t *);\nint main(void) {\n  static uint32_t a[5 * 18 * 4];\n  uint32_t d[18 * 4];\n  for (int k = 0; k < 5 * 18 * 4; k++) a[k] = (uint32_t)(k * 2654435761u);\n  acc(a, 5, d);\n  for (int k = 0; k < 18 * 4; k++) {\n    uint32_t s = 0;\n    for (int r = 0; r < 5; r++) s += a[r * 18 * 4 + k];\n    if (d[k] != s) return 1;\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// A load one comparison or operation reads folds into it (x86-64 `lv::FOLD_LDOP`): the memory against an
// immediate or a register either way, a byte, a global's (RIP-relative), the second operand of a `sub`,
// the first of an `and`; a store between the load and its use keeps the load.
@test
fn loads_read_by_one_operation_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @g data global
sym @cmi fn global
sym @crm fn global
sym @cmr fn global
sym @cb fn global
sym @addm fn global
sym @subm fn global
sym @andm fn global
sym @xg fn global
sym @kept fn global
fn @cmi
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.i32 v0+4 align 2
  v2 = iconst.i32 7
  v3 = icmp.eq v1, v2
  v4 = iconst.i32 10
  v5 = iconst.i32 20
  v6 = select.i32 v3, v4, v5
  ret v6
fn @crm
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = load.i64 v0+8 align 3
  v3 = icmp.ult v1, v2
  br v3, b1, b2
b1:
  ret v1
b2:
  ret v2
fn @cmr
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = load.i32 v0 align 2
  v3 = icmp.slt v2, v1
  v4 = zext.i32 v3
  ret v4
fn @cb
  sig (ptr, i8) -> i32
b0(v0: ptr, v1: i8):
  v2 = load.i8 v0+3 align 0
  v3 = icmp.eq v2, v1
  v4 = zext.i32 v3
  ret v4
fn @addm
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = load.i64 v0+8 align 3
  v3 = add.i64 v1, v2
  ret v3
fn @subm
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = load.i32 v0 align 2
  v3 = sub.i32 v1, v2
  ret v3
fn @andm
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = load.i32 v0+4 align 2
  v3 = and.i32 v2, v1
  ret v3
fn @xg
  sig (i32) -> i32
b0(v0: i32):
  v1 = symaddr @g
  v2 = load.i32 v1 align 2
  v3 = xor.i32 v0, v2
  v4 = iconst.i32 5
  v5 = load.i32 v1+4 align 2
  v6 = icmp.ugt v5, v4
  v7 = zext.i32 v6
  v8 = add.i32 v3, v7
  ret v8
fn @kept
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = load.i32 v0 align 2
  store v1, v0 align 2
  v3 = add.i32 v1, v2
  ret v3
data @g size 8 align 2 bytes f00f000009000000
)";
    let drv = "#include <stdint.h>\nint32_t cmi(const int32_t *);\nint64_t crm(const int64_t *, int64_t);\nint32_t cmr(const int32_t *, int32_t);\nint32_t cb(const uint8_t *, uint8_t);\nint64_t addm(const int64_t *, int64_t);\nint32_t subm(const int32_t *, int32_t);\nint32_t andm(const int32_t *, int32_t);\nint32_t xg(int32_t);\nint32_t kept(int32_t *, int32_t);\nint main(void) {\n  int32_t a[2] = {-3, 7};\n  int64_t q[2] = {0, 100};\n  uint8_t s[4] = {1, 2, 3, 200};\n  if (cmi(a) != 10) return 1;\n  a[1] = 8;\n  if (cmi(a) != 20) return 2;\n  if (crm(q, 99) != 99 || crm(q, 100) != 100 || crm(q, -1) != 100) return 3;\n  if (cmr(a, -2) != 1 || cmr(a, -3) != 0 || cmr(a, -4) != 0) return 4;\n  if (cb(s, 200) != 1 || cb(s, 3) != 0) return 5;\n  if (addm(q, -1) != 99) return 6;\n  if (subm(a, 10) != 13) return 7;\n  if (andm(a, 12) != 8) return 8;\n  if (xg(0xFF) != (0xFF ^ 0xFF0) + 1) return 9;\n  int32_t w = 4;\n  if (kept(&w, 9) != 13 || w != 9) return 10;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Products by 2^s + 1 and 2^s - 1 (a shifted sum, a shift and a difference; `lea` by 3, 5 and 9, then a
// shift by their multiples by 2^s; a product by all ones, which no shift within the width gives,
// multiplies), and
// loads and stores of consecutive bytes through one address (`ldp`, `stp`), with their results.
@test
fn constant_products_and_paired_accesses_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @k3 fn global\nsym @k7 fn global\nsym @k9w fn global\nsym @kn fn global\nsym @kw fn global\nsym @ks fn global\nsym @ksw fn global\nsym @swap4 fn global\nfn @k3\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = iconst.i64 3\n  v2 = mul.i64 v0, v1\n  ret v2\nfn @k7\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = iconst.i64 7\n  v2 = mul.i64 v0, v1\n  ret v2\nfn @k9w\n  sig (i32) -> i32\nb0(v0: i32):\n  v1 = iconst.i32 9\n  v2 = mul.i32 v0, v1\n  ret v2\nfn @kn\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = iconst.i64 -1\n  v2 = mul.i64 v0, v1\n  ret v2\nfn @kw\n  sig (i32) -> i32\nb0(v0: i32):\n  v1 = iconst.i32 4294967295\n  v2 = mul.i32 v0, v1\n  v3 = iconst.i32 2147483647\n  v4 = mul.i32 v0, v3\n  v5 = add.i32 v2, v4\n  ret v5\nfn @ks\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = iconst.i64 40\n  v2 = mul.i64 v0, v1\n  v3 = iconst.i64 12\n  v4 = mul.i64 v0, v3\n  v5 = iconst.i64 31\n  v6 = mul.i64 v0, v5\n  v7 = add.i64 v2, v4\n  v8 = add.i64 v7, v6\n  ret v8\nfn @ksw\n  sig (i32) -> i32\nb0(v0: i32):\n  v1 = iconst.i32 72\n  v2 = mul.i32 v0, v1\n  v3 = iconst.i32 10\n  v4 = mul.i32 v0, v3\n  v5 = add.i32 v2, v4\n  ret v5\nfn @swap4\n  sig (ptr) -> i64\nb0(v0: ptr):\n  v1 = load.i64 v0 align 3\n  v2 = load.i64 v0+8 align 3\n  v3 = load.i32 v0+16 align 2\n  v4 = load.i32 v0+20 align 2\n  store v2, v0 align 3\n  store v1, v0+8 align 3\n  store v4, v0+16 align 2\n  store v3, v0+20 align 2\n  v5 = sext.i64 v3\n  v6 = add.i64 v1, v5\n  ret v6\n";
    let drv = "#include <stdint.h>\nint64_t k3(int64_t);\nint64_t k7(int64_t);\nint32_t k9w(int32_t);\nint64_t kn(int64_t);\nint32_t kw(int32_t);\nint64_t ks(int64_t);\nint32_t ksw(int32_t);\nint64_t swap4(void *);\nstruct S { int64_t a, b; int32_t c, d; };\nint main(void) {\n  if (k3(-5) != -15 || k3(INT64_C(1) << 62) != (int64_t)(UINT64_C(3) << 62)) return 1;\n  if (k7(6) != 42 || k7(-1) != -7) return 2;\n  if (k9w(-3) != -27 || k9w(0x10000000) != (int32_t)0x90000000u) return 3;\n  if (kn(5) != -5 || kn(INT64_MIN) != INT64_MIN) return 5;\n  if (kw(3) != (int32_t)(3u * 0xFFFFFFFFu + 3u * 0x7FFFFFFFu)) return 6;\n  if (ks(-7) != -7 * 83 || ks(INT64_C(1) << 60) != (int64_t)(UINT64_C(83) << 60)) return 7;\n  if (ksw(-9) != -9 * 82 || ksw(0x7FFFFFF) != (int32_t)(0x7FFFFFFu * 82u)) return 8;\n  struct S s = {1, 2, -3, 4};\n  if (swap4(&s) != -2 || s.a != 2 || s.b != 1 || s.c != 4 || s.d != -3) return 4;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Rotations (`lv::FOLD_ROT`: a constant amount, a masked amount and its negation through extensions, a
// right one; 8 and 16 bits, by a constant and by a register either way, which arm64 rotates in a 32-bit
// register filled with the value's copies; a masked `xor` of shifts, which a 0 amount sets to 0, stays two
// shifts),
// high products of every width (`mulhs`, `mulhu`: a constant first in rax on x86-64), sums an address
// computes (`lv::FOLD_LEA`: a shifted index, a displacement, an inner sum, an operand that stays live) and
// products by constants (`lea` pairs, a shift and a sum, a negation), with their results; a sum on memory
// whose other operand folds into it (a shifted index, an inner sum), which x86-64 computes in a register,
// not on memory (`add [m], r`): its object builds for x86-64 on any host. A narrow result returns
// zero-extended: the driver reads it unsigned.
@test
fn rotations_high_products_and_address_sums_run() {
    let lir = M"(lir ptr 8
sym @rl64 fn global
sym @rr32 fn global
sym @rc64 fn global
sym @r8 fn global
sym @rc8 fn global
sym @r16r fn global
sym @rx fn global
sym @hs64 fn global
sym @hs32 fn global
sym @hs16 fn global
sym @hs8 fn global
sym @hu64 fn global
sym @hu32 fn global
sym @hv64 fn global
sym @lea fn global
sym @live fn global
sym @lsub fn global
sym @idx fn global
sym @ks fn global
sym @mi fn global
sym @ms fn global
fn @rl64
  sig (i64, i32) -> i64
b0(v0: i64, v1: i32):
  v2 = iconst.i32 63
  v3 = iconst.i32 64
  v4 = and.i32 v1, v2
  v5 = zext.i64 v4
  v6 = shl.i64 v0, v5
  v7 = sub.i32 v3, v4
  v8 = and.i32 v7, v2
  v9 = zext.i64 v8
  v10 = lshr.i64 v0, v9
  v11 = or.i64 v6, v10
  ret v11
fn @rr32
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 31
  v3 = and.i32 v1, v2
  v4 = lshr.i32 v0, v3
  v5 = neg.i32 v1
  v6 = and.i32 v5, v2
  v7 = shl.i32 v0, v6
  v8 = or.i32 v4, v7
  ret v8
fn @rc64
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 13
  v2 = iconst.i64 51
  v3 = shl.i64 v0, v1
  v4 = lshr.i64 v0, v2
  v5 = xor.i64 v3, v4
  ret v5
fn @r8
  sig (i8, i8) -> i8
b0(v0: i8, v1: i8):
  v2 = iconst.i8 7
  v3 = iconst.i8 8
  v4 = and.i8 v1, v2
  v5 = shl.i8 v0, v4
  v6 = sub.i8 v3, v4
  v7 = and.i8 v6, v2
  v8 = lshr.i8 v0, v7
  v9 = or.i8 v5, v8
  ret v9
fn @rc8
  sig (i8) -> i8
b0(v0: i8):
  v1 = iconst.i8 3
  v2 = iconst.i8 5
  v3 = shl.i8 v0, v1
  v4 = lshr.i8 v0, v2
  v5 = or.i8 v3, v4
  ret v5
fn @r16r
  sig (i16, i32) -> i16
b0(v0: i16, v1: i32):
  v2 = iconst.i32 15
  v3 = and.i32 v1, v2
  v4 = trunc.i16 v3
  v5 = lshr.i16 v0, v4
  v6 = neg.i32 v1
  v7 = and.i32 v6, v2
  v8 = trunc.i16 v7
  v9 = shl.i16 v0, v8
  v10 = or.i16 v5, v9
  ret v10
fn @rx
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 63
  v3 = and.i64 v1, v2
  v4 = shl.i64 v0, v3
  v5 = neg.i64 v1
  v6 = and.i64 v5, v2
  v7 = lshr.i64 v0, v6
  v8 = xor.i64 v4, v7
  ret v8
fn @hs64
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 6148914691236517206
  v2 = mulhs.i64 v0, v1
  ret v2
fn @hs32
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 -1840700269
  v2 = mulhs.i32 v0, v1
  ret v2
fn @hs16
  sig (i16.s) -> i16
b0(v0: i16):
  v1 = iconst.i16 21846
  v2 = mulhs.i16 v1, v0
  ret v2
fn @hs8
  sig (i8.s) -> i8
b0(v0: i8):
  v1 = iconst.i8 -109
  v2 = mulhs.i8 v0, v1
  ret v2
fn @hu64
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 -6148914691236517205
  v2 = mulhu.i64 v1, v0
  ret v2
fn @hu32
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 2863311531
  v2 = mulhu.i32 v0, v1
  ret v2
fn @hv64
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = mulhs.i64 v0, v1
  ret v2
fn @lea
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 3
  v3 = shl.i64 v1, v2
  v4 = add.i64 v0, v3
  v5 = iconst.i64 40
  v6 = add.i64 v4, v5
  ret v6
fn @live
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = add.i64 v0, v1
  v3 = xor.i64 v2, v0
  ret v3
fn @lsub
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = add.i32 v0, v1
  v3 = iconst.i32 9
  v4 = sub.i32 v2, v3
  ret v4
fn @idx
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1
  v2 = shl.i64 v0, v1
  v3 = iconst.i64 7
  v4 = add.i64 v2, v3
  ret v4
fn @ks
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 15
  v2 = mul.i64 v0, v1
  v3 = iconst.i64 13
  v4 = mul.i64 v0, v3
  v5 = iconst.i64 -9
  v6 = mul.i64 v0, v5
  v7 = iconst.i64 -16
  v8 = mul.i64 v0, v7
  v9 = iconst.i64 33
  v10 = mul.i64 v0, v9
  v11 = iconst.i64 45
  v12 = mul.i64 v0, v11
  v13 = add.i64 v2, v4
  v14 = xor.i64 v13, v6
  v15 = add.i64 v14, v8
  v16 = xor.i64 v15, v10
  v17 = add.i64 v16, v12
  ret v17
fn @mi
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 3
  v3 = shl.i64 v1, v2
  v4 = load.i64 v0 align 3
  v5 = add.i64 v4, v3
  store v5, v0 align 3
  ret
fn @ms
  sig (ptr, i64, i64) -> void
b0(v0: ptr, v1: i64, v2: i64):
  v3 = add.i64 v1, v2
  v4 = load.i64 v0+8 align 3
  v5 = add.i64 v4, v3
  store v5, v0+8 align 3
  ret
)";
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(lir, tgt::axis_index("linux", false), tgt::axis_index("x86_64", true), 0, &mut obj),
        "the x86-64 object",
    );
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = M"(#include <stdint.h>
int64_t rl64(int64_t, int32_t);
int32_t rr32(int32_t, int32_t);
int64_t rc64(int64_t);
uint8_t r8(uint8_t, uint8_t);
uint8_t rc8(uint8_t);
uint16_t r16r(uint16_t, int32_t);
int64_t rx(int64_t, int64_t);
int64_t hs64(int64_t);
int32_t hs32(int32_t);
uint16_t hs16(int16_t);
uint8_t hs8(int8_t);
int64_t hu64(int64_t);
int32_t hu32(int32_t);
int64_t hv64(int64_t, int64_t);
int64_t lea(int64_t, int64_t);
int64_t live(int64_t, int64_t);
int32_t lsub(int32_t, int32_t);
int64_t idx(int64_t);
int64_t ks(int64_t);
void mi(int64_t *, int64_t);
void ms(int64_t *, int64_t, int64_t);
static uint64_t rot(uint64_t x, unsigned s, unsigned w) {
  uint64_t m = w == 64 ? ~UINT64_C(0) : (UINT64_C(1) << w) - 1;
  x &= m;
  s %= w;
  return s == 0 ? x : ((x << s) | (x >> (w - s))) & m;
}
int main(void) {
  static const int64_t xs[] = {0, 1, -1, 3, 0x5A, -0x80, INT64_MIN, INT64_MAX, INT64_C(0x123456789ABCDEF0), -INT64_C(1000000007)};
  for (int i = 0; i < 10; i++) {
    int64_t x = xs[i];
    uint64_t u = (uint64_t)x;
    for (int n = -3; n < 140; n++) {
      if ((uint64_t)rl64(x, n) != rot(u, (unsigned)n & 63, 64)) return 1;
      if ((uint32_t)rr32((int32_t)x, n) != (uint32_t)rot(u, (32 - ((unsigned)n & 31)) & 31, 32)) return 2;
      if (r8((uint8_t)x, (uint8_t)n) != (uint8_t)rot(u, (unsigned)n & 7, 8)) return 3;
      if (r16r((uint16_t)x, n) != (uint16_t)rot(u, (16 - ((unsigned)n & 15)) & 15, 16)) return 18;
      unsigned s = (unsigned)n & 63;
      if ((uint64_t)rx(x, n) != ((u << s) ^ (u >> ((0u - (unsigned)n) & 63)))) return 4;
    }
    if ((uint64_t)rc64(x) != rot(u, 13, 64)) return 5;
    if (rc8((uint8_t)x) != (uint8_t)rot(u, 3, 8)) return 19;
    if (hs64(x) != (int64_t)(((__int128)x * INT64_C(6148914691236517206)) >> 64)) return 6;
    if (hs32((int32_t)x) != (int32_t)(((int64_t)(int32_t)x * -1840700269) >> 32)) return 7;
    if (hs16((int16_t)x) != (uint16_t)(((int32_t)(int16_t)x * 21846) >> 16)) return 8;
    if (hs8((int8_t)x) != (uint8_t)(((int32_t)(int8_t)x * -109) >> 8)) return 9;
    if ((uint64_t)hu64(x) != (uint64_t)(((unsigned __int128)u * UINT64_C(0xAAAAAAAAAAAAAAAB)) >> 64)) return 10;
    if ((uint32_t)hu32((int32_t)x) != (uint32_t)(((uint64_t)(uint32_t)x * UINT64_C(0xAAAAAAAB)) >> 32)) return 11;
    for (int j = 0; j < 10; j++) {
      int64_t y = xs[j];
      uint64_t v = (uint64_t)y;
      if (hv64(x, y) != (int64_t)(((__int128)x * y) >> 64)) return 12;
      if ((uint64_t)lea(x, y) != u + (v << 3) + 40) return 13;
      if ((uint64_t)live(x, y) != ((u + v) ^ u)) return 14;
      if ((uint32_t)lsub((int32_t)x, (int32_t)y) != (uint32_t)u + (uint32_t)v - 9) return 15;
    }
    if ((uint64_t)idx(x) != (u << 1) + 7) return 16;
    if ((uint64_t)ks(x) != (((u * 15 + u * 13) ^ (u * (uint64_t)-9)) + u * (uint64_t)-16 ^ u * 33) + u * 45) return 17;
  }
  int64_t m[2] = {5, 7};
  mi(m, 3);
  ms(m, 10, -4);
  if (m[0] != 29 || m[1] != 13) return 20;
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// An aggregate passed in registers whose entry block only loads its parts: the loads take the registers
// when no call comes before them, and read its memory after one (the call writes the registers: its
// result arrives in the first one).
@test
fn register_passed_aggregate_parts_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @three fn global\nsym @before fn global\nsym @after fn global\nfn @before\n  layout l0 size 16 align 3 [0 i64, 8 i64]\n  sig (l0, i64) -> i64\nb0(v0: ptr, v1: i64):\n  v2 = load.i64 v0 align 3\n  v3 = load.i64 v0+8 align 3\n  v4 = call.i64 @three() : () -> i64\n  v5 = sub.i64 v2, v3\n  v6 = add.i64 v5, v4\n  v7 = add.i64 v6, v1\n  ret v7\nfn @after\n  layout l0 size 16 align 3 [0 i64, 8 i64]\n  sig (l0, i64) -> i64\nb0(v0: ptr, v1: i64):\n  v2 = call.i64 @three() : () -> i64\n  v3 = load.i64 v0 align 3\n  v4 = load.i64 v0+8 align 3\n  v5 = sub.i64 v3, v4\n  v6 = add.i64 v5, v2\n  v7 = add.i64 v6, v1\n  ret v7\n";
    let drv = "#include <stdint.h>\nstruct P { int64_t a, b; };\nint64_t before(struct P, int64_t);\nint64_t after(struct P, int64_t);\nint64_t three(void) { return 3000; }\nint main(void) {\n  struct P p = {50, 8};\n  if (before(p, 3) != 3045) return 1;\n  if (after(p, 4) != 3046) return 2;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// The high halves of vector lanes' products (`mulhs`, `mulhu`; the lane sizes `Package.vec_mulh` names) run
// against the C driver's products of the lanes' extremes, -1, 0 and a sequence of both signs: on arm64
// lanes of 8, 16 and 32 bits in 8- and 16-byte registers and in 32-byte vectors in memory; on x86-64 those
// of 16 and 32 bits, in xmm registers with SSE2 and with SSE4.1, in ymm (AVX2) and zmm (AVX-512) ones, and
// lane by lane in memory.
@test
fn vector_high_products_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let x64 = tgt::host_isa() == tgt::axis_index("x86_64", true);
    // (signed, lane bits, lanes)
    let cases: [(bool, u32, u32); 12] = [
        (true, 8, 16),
        (false, 8, 16),
        (true, 16, 8),
        (false, 16, 8),
        (true, 32, 4),
        (false, 32, 4),
        (true, 8, 8),
        (false, 16, 4),
        (true, 32, 2),
        (true, 32, 8),
        (false, 16, 16),
        (false, 8, 32),
    ];
    let mut lir = String::from_str("lir ptr 8\n");
    let mut fns = String::new();
    let mut drv = String::from_str(
        "#include <stdint.h>\nstatic uint64_t s = 0x9E3779B97F4A7C15u;\nstatic uint64_t next(void) { s = s * 6364136223846793005u + 1442695040888963407u; return s >> 17; }\n",
    );
    let mut calls = String::new();
    for c in 0..12usize {
        let (sg, w, n) = unsafe cases[c];
        if x64 && w == 8 {
            continue; // no product of bytes
        }
        let vt = format("v{}i{}", n, w);
        let op = if sg {
            "mulhs"
        } else {
            "mulhu"
        };
        let al = (w / 8).trailing_zeros();
        lir.push_str(format("sym @h{} fn global\n", c).as_str());
        fns.push_str(
            format(
                "fn @h{}\n  sig (ptr, ptr, ptr) -> void\nb0(v0: ptr, v1: ptr, v2: ptr):\n  v3 = load.{} v1 align {}\n  v4 = load.{} v2 align {}\n  v5 = {}.{} v3, v4\n  store v5, v0 align {}\n  ret\n",
                c,
                vt,
                al,
                vt,
                al,
                op,
                vt,
                al,
            ).as_str(),
        );
        let ct = format(
            "{}int{}_t",
            if sg {
                ""
            } else {
                "u"
            },
            w,
        );
        let wide = if sg {
            "int64_t"
        } else {
            "uint64_t"
        };
        drv.push_str(
            format("void h{}({} *, const {} *, const {} *);\n", c, ct.as_str(), ct.as_str(), ct.as_str()).as_str(),
        );
        calls.push_str(
            format(
                "  for (int r = 0; r < 64; r++) {{\n    {} a[{}], b[{}], d[{}];\n    for (int k = 0; k < {}; k++) {{ a[k] = ({})next(); b[k] = ({})next(); }}\n    if (r == 0) {{\n      {} e[4] = {{ ({})((uint64_t)1 << {}), ({})~((uint64_t)1 << {}), ({})-1, 0 }};\n      {} f[4] = {{ e[0], e[0], ({})-1, e[1] }};\n      for (int k = 0; k < {} && k < 4; k++) {{ a[k] = e[k]; b[k] = f[k]; }}\n    }}\n    h{}(d, a, b);\n    for (int k = 0; k < {}; k++) if (d[k] != ({})((({})a[k] * ({})b[k]) >> {})) return {};\n  }}\n",
                ct.as_str(),
                n,
                n,
                n,
                n,
                ct.as_str(),
                ct.as_str(),
                ct.as_str(),
                ct.as_str(),
                w - 1,
                ct.as_str(),
                w - 1,
                ct.as_str(),
                ct.as_str(),
                ct.as_str(),
                n,
                c,
                n,
                ct.as_str(),
                wide,
                wide,
                w,
                c + 1,
            ).as_str(),
        );
    }
    lir.push_str(&fns);
    drv.push_str("int main(void) {\n");
    drv.push_str(&calls);
    drv.push_str("  return 0;\n}\n");
    assert_eq(run_native(&lir, &drv), 0);
    assert_eq(run_sse41(&lir, &drv), 0);
    assert_eq(run_wide(&lir, &drv), 0);
    assert_eq(run_zmm(&lir, &drv), 0);
}

// Lane quotients and remainders by constants as the optimizer gives them, their operands and constants in
// registers: high products by a wide constant or by a splat of a parameter (x86-64 multiplies the odd lanes
// by it unmoved), a sum with a lane shift by an immediate (arm64 USRA and SSRA, over a dying sum, a
// constant, a value read again after, or a loop's accumulator), a difference with a product (arm64 MLS,
// x86-64 `pmulld` with SSE4.1), constants of one repeated 2- or 4-byte element (arm64 DUP of the element).
@test
fn lane_divisions_by_constants_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @sdiv7 fn global
sym @udiv7 fn global
sym @urem10 fn global
sym @udiv3 fn global
sym @ssra fn global
sym @mulhs_by fn global
sym @usra_sum fn global
fn @sdiv7
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = wconst.v4i32 0x9249249392492493, 0x9249249392492493
  v3 = wconst.v4i32 0x200000002, 0x200000002
  v4 = wconst.v4i32 0x1f0000001f, 0x1f0000001f
  v5 = load.v4i32 v1 align 2
  v6 = mulhs.v4i32 v5, v2
  v7 = add.v4i32 v6, v5
  v8 = ashr.v4i32 v7, v3
  v9 = lshr.v4i32 v5, v4
  v10 = add.v4i32 v8, v9
  store v10, v0 align 2
  ret
fn @udiv7
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = wconst.v4i32 0x2492492524924925, 0x2492492524924925
  v3 = wconst.v4i32 0x100000001, 0x100000001
  v4 = wconst.v4i32 0x200000002, 0x200000002
  v5 = load.v4i32 v1 align 2
  v6 = mulhu.v4i32 v5, v2
  v7 = sub.v4i32 v5, v6
  v8 = lshr.v4i32 v7, v3
  v9 = add.v4i32 v8, v6
  v10 = lshr.v4i32 v9, v4
  store v10, v0 align 2
  ret
fn @urem10
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = wconst.v4i32 0xcccccccdcccccccd, 0xcccccccdcccccccd
  v3 = wconst.v4i32 0x300000003, 0x300000003
  v4 = wconst.v4i32 0xa0000000a, 0xa0000000a
  v5 = load.v4i32 v1 align 2
  v6 = mulhu.v4i32 v5, v2
  v7 = lshr.v4i32 v6, v3
  v8 = mul.v4i32 v7, v4
  v9 = sub.v4i32 v5, v8
  store v9, v0 align 2
  ret
fn @udiv3
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = wconst.v8i16 0xaaabaaabaaabaaab, 0xaaabaaabaaabaaab
  v3 = wconst.v8i16 0x1000100010001, 0x1000100010001
  v4 = wconst.v4i16 0x1234567812345678
  v5 = load.v8i16 v1 align 1
  v6 = mulhu.v8i16 v5, v2
  v7 = lshr.v8i16 v6, v3
  store v7, v0 align 1
  v8 = load.v4i16 v1+16 align 1
  v9 = add.v4i16 v8, v4
  store v9, v0+16 align 1
  ret
fn @ssra
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = wconst.v2i32 0x300000003
  v3 = wconst.v2i32 0x8765432187654321
  v4 = load.v2i32 v1 align 2
  v5 = load.v2i32 v1+8 align 2
  v6 = ashr.v2i32 v5, v2
  v7 = add.v2i32 v3, v6
  v8 = add.v2i32 v7, v4
  v9 = ashr.v2i32 v4, v2
  v10 = add.v2i32 v9, v5
  v11 = add.v2i32 v10, v5
  store v8, v0 align 2
  store v11, v0+8 align 2
  ret
fn @mulhs_by
  sig (ptr, ptr, i32) -> void
b0(v0: ptr, v1: ptr, v2: i32):
  v3 = splat.v4i32 v2
  v4 = load.v4i32 v1 align 2
  v5 = load.v4i32 v1+16 align 2
  v6 = mulhs.v4i32 v4, v3
  v7 = mulhu.v4i32 v5, v3
  v8 = add.v4i32 v6, v7
  store v8, v0 align 2
  ret
fn @usra_sum
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i32 0
  v4 = splat.v4i32 v3
  v5 = wconst.v4i32 0x500000005, 0x500000005
  v6 = iconst.i64 0
  v7 = iconst.i64 1
  jmp b1(v6, v4, v1)
b1(v8: i64, v9: v4i32, v10: ptr):
  v11 = icmp.ult v8, v2
  br v11, b2, b3
b2:
  v12 = load.v4i32 v10 align 2
  v13 = lshr.v4i32 v12, v5
  v14 = add.v4i32 v9, v13
  v15 = add.i64 v8, v7
  v16 = ptradd v10+16
  jmp b1(v15, v14, v16)
b3:
  store v9, v0 align 2
  ret
)";
    let drv = M"(#include <stdint.h>
void sdiv7(int32_t *, const int32_t *);
void udiv7(uint32_t *, const uint32_t *);
void urem10(uint32_t *, const uint32_t *);
void udiv3(uint16_t *, const uint16_t *);
void ssra(int32_t *, const int32_t *);
void mulhs_by(uint32_t *, const int32_t *, int32_t);
void usra_sum(uint32_t *, const uint32_t *, int64_t);
static uint64_t s = 0x9E3779B97F4A7C15u;
static uint32_t next(void) { s = s * 6364136223846793005u + 1442695040888963407u; return (uint32_t)(s >> 29); }
int main(void) {
  for (int r = 0; r < 256; r++) {
    uint32_t u[12];
    for (int k = 0; k < 12; k++) u[k] = next();
    if (r == 0) { u[0] = 0; u[1] = 0x7FFFFFFFu; u[2] = 0x80000000u; u[3] = 0xFFFFFFFFu; u[4] = 7; u[5] = 0xFFFFFFF9u; u[6] = 9; u[7] = 10; }
    const int32_t *a = (const int32_t *)u;
    int32_t q[4];
    uint32_t p[4];
    uint16_t h[12];
    sdiv7(q, a);
    for (int k = 0; k < 4; k++) if (q[k] != a[k] / 7) return 1;
    udiv7(p, u);
    for (int k = 0; k < 4; k++) if (p[k] != u[k] / 7) return 2;
    urem10(p, u);
    for (int k = 0; k < 4; k++) if (p[k] != u[k] % 10) return 3;
    const uint16_t *w = (const uint16_t *)u;
    udiv3(h, w);
    for (int k = 0; k < 8; k++) if (h[k] != w[k] / 3) return 4;
    const uint16_t c[4] = {0x5678, 0x1234, 0x5678, 0x1234};
    for (int k = 0; k < 4; k++) if (h[8 + k] != (uint16_t)(w[8 + k] + c[k])) return 5;
    ssra(q, a);
    for (int k = 0; k < 2; k++) {
      uint32_t e = 0x87654321u + (uint32_t)(a[2 + k] >> 3) + (uint32_t)a[k];
      if ((uint32_t)q[k] != e || (uint32_t)q[2 + k] != (uint32_t)(a[k] >> 3) + 2u * (uint32_t)a[2 + k]) return 6;
    }
    int32_t m = (int32_t)u[8];
    mulhs_by(p, a, m);
    for (int k = 0; k < 4; k++) {
      uint32_t hs = (uint32_t)(((int64_t)a[k] * m) >> 32), hu = (uint32_t)(((uint64_t)u[4 + k] * (uint32_t)m) >> 32);
      if (p[k] != hs + hu) return 7;
    }
    usra_sum(p, u, 3);
    for (int k = 0; k < 4; k++) if (p[k] != (u[k] >> 5) + (u[4 + k] >> 5) + (u[8 + k] >> 5)) return 8;
  }
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_sse41(lir, drv), 0);
    assert_eq(run_wide(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Saturating sums and differences, absolute differences and widening sums of integer lanes, as the loop
// vectorizer makes them: in registers (arm64 UQADD, UABD, UADDLP and UADALP; x86-64 PADDUS, PSUBUS and
// their `or`, PMAXS less PMINS or, bytes without SSE4.1, the difference negated where the second is
// greater, PSADBW of an absolute difference or of zeros, then PADDQ), each lane width and sign, a loop's
// accumulator, and 32- and 64-byte vectors (in registers with AVX2 and AVX-512, else lane by lane).
@test
fn lane_idioms_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @sat fn global
sym @absd fn global
sym @sums fn global
sym @sad_loop fn global
sym @wide32 fn global
sym @wide64 fn global
fn @sat
  sig (ptr, ptr, ptr) -> void
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.v16i8 v1 align 0
  v4 = load.v16i8 v2 align 0
  v5 = vop.saturating_add.v16i8 (v3, v4)
  store v5, v0 align 0
  v6 = vop.saturating_add.s.v16i8 (v3, v4)
  store v6, v0+16 align 0
  v7 = vop.saturating_sub.v16i8 (v3, v4)
  store v7, v0+32 align 0
  v8 = vop.saturating_sub.s.v16i8 (v3, v4)
  store v8, v0+48 align 0
  v9 = load.v8i16 v1 align 1
  v10 = load.v8i16 v2 align 1
  v11 = vop.saturating_add.v8i16 (v9, v10)
  store v11, v0+64 align 1
  v12 = vop.saturating_add.s.v8i16 (v9, v10)
  store v12, v0+80 align 1
  v13 = vop.saturating_sub.v8i16 (v9, v10)
  store v13, v0+96 align 1
  v14 = vop.saturating_sub.s.v8i16 (v9, v10)
  store v14, v0+112 align 1
  ret
fn @absd
  sig (ptr, ptr, ptr) -> void
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.v16i8 v1 align 0
  v4 = load.v16i8 v2 align 0
  v5 = vop.abs_diff.v16i8 (v3, v4)
  store v5, v0 align 0
  v6 = vop.abs_diff.s.v16i8 (v3, v4)
  store v6, v0+16 align 0
  v7 = load.v8i16 v1 align 1
  v8 = load.v8i16 v2 align 1
  v9 = vop.abs_diff.v8i16 (v7, v8)
  store v9, v0+32 align 1
  v10 = vop.abs_diff.s.v8i16 (v7, v8)
  store v10, v0+48 align 1
  ret
fn @sums
  sig (ptr, ptr, ptr) -> void
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.v16i8 v1 align 0
  v4 = load.v2i64 v0 align 3
  v5 = vsumw.v2i64 v4, v3
  store v5, v0 align 3
  v6 = load.v4i32 v0+16 align 2
  v7 = vsumw.v4i32 v6, v3
  store v7, v0+16 align 2
  v8 = load.v8i16 v1 align 1
  v9 = load.v4i32 v0+32 align 2
  v10 = vsumw.v4i32 v9, v8
  store v10, v0+32 align 2
  v11 = load.v2i64 v0+48 align 3
  v12 = vsumw.v2i64 v11, v8
  store v12, v0+48 align 3
  v13 = load.v4i32 v1 align 2
  v14 = load.v2i64 v0+64 align 3
  v15 = vsumw.v2i64 v14, v13
  store v15, v0+64 align 3
  v16 = load.v16i8 v2 align 0
  v17 = vop.abs_diff.v16i8 (v3, v16)
  v18 = load.v2i64 v0+80 align 3
  v19 = vsumw.v2i64 v18, v17
  store v19, v0+80 align 3
  v20 = load.v8i16 v0+96 align 1
  v21 = vsumw.v8i16 v20, v3
  store v21, v0+96 align 1
  ret
fn @sad_loop
  sig (ptr, ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = load.v2i64 v0 align 3
  jmp b1(v4, v6, v1, v2)
b1(v7: i64, v8: v2i64, v9: ptr, v10: ptr):
  v11 = icmp.ult v7, v3
  br v11, b2, b3
b2:
  v12 = load.v16i8 v9 align 0
  v13 = load.v16i8 v10 align 0
  v14 = vop.abs_diff.v16i8 (v12, v13)
  v15 = vsumw.v2i64 v8, v14
  v16 = add.i64 v7, v5
  v17 = ptradd v9+16
  v18 = ptradd v10+16
  jmp b1(v16, v15, v17, v18)
b3:
  store v8, v0 align 3
  ret
fn @wide32
  sig (ptr, ptr, ptr, ptr) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: ptr):
  v4 = load.v32i8 v1 align 0
  v5 = load.v32i8 v2 align 0
  v6 = vop.saturating_add.v32i8 (v4, v5)
  store v6, v0 align 0
  v7 = vop.abs_diff.v32i8 (v4, v5)
  store v7, v0+32 align 0
  v8 = vop.abs_diff.s.v32i8 (v4, v5)
  store v8, v0+64 align 0
  v9 = load.v4i64 v3 align 3
  v10 = vsumw.v4i64 v9, v7
  store v10, v3 align 3
  ret
fn @wide64
  sig (ptr, ptr, ptr, ptr) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: ptr):
  v4 = load.v64i8 v1 align 0
  v5 = load.v64i8 v2 align 0
  v6 = vop.saturating_sub.v64i8 (v4, v5)
  store v6, v0 align 0
  v7 = vop.abs_diff.v64i8 (v4, v5)
  store v7, v0+64 align 0
  v8 = vop.abs_diff.s.v64i8 (v4, v5)
  store v8, v0+128 align 0
  v9 = load.v8i64 v3 align 3
  v10 = vsumw.v8i64 v9, v4
  store v10, v3 align 3
  ret
)";
    let drv = M"(#include <stdint.h>
#include <string.h>
void sat(uint8_t *, const uint8_t *, const uint8_t *);
void absd(uint8_t *, const uint8_t *, const uint8_t *);
void sums(uint8_t *, const uint8_t *, const uint8_t *);
void sad_loop(uint64_t *, const uint8_t *, const uint8_t *, int64_t);
void wide32(uint8_t *, const uint8_t *, const uint8_t *, uint64_t *);
void wide64(uint8_t *, const uint8_t *, const uint8_t *, uint64_t *);
static uint64_t s = 0x9E3779B97F4A7C15u;
static uint64_t next(void) { s = s * 6364136223846793005u + 1442695040888963407u; return s; }
static int64_t clamp(int64_t v, int64_t lo, int64_t hi) { return v < lo ? lo : v > hi ? hi : v; }
static uint64_t dist(int64_t x, int64_t y) { return (uint64_t)(x > y ? x - y : y - x); }
int main(void) {
  for (int r = 0; r < 64; r++) {
    uint8_t a[128], b[128], o[256];
    uint16_t a16[8], b16[8], o16[32];
    uint32_t a32[4], o32[12];
    uint64_t acc[16], o64[16];
    for (int k = 0; k < 128; k++) { a[k] = (uint8_t)(next() >> 56); b[k] = (uint8_t)(next() >> 56); }
    if (r == 0) for (int k = 0; k < 128; k++) { a[k] = (uint8_t)(k & 1 ? 0xFF : k * 2); b[k] = (uint8_t)(k & 2 ? 0x80 : 0x7F - k); }
    memcpy(a16, a, 16); memcpy(b16, b, 16); memcpy(a32, a, 16);
    sat(o, a, b);
    memcpy(o16, o + 64, 64);
    for (int k = 0; k < 16; k++) {
      if (o[k] != clamp(a[k] + b[k], 0, 255)) return 1;
      if ((int8_t)o[16 + k] != clamp((int8_t)a[k] + (int8_t)b[k], -128, 127)) return 2;
      if (o[32 + k] != clamp(a[k] - b[k], 0, 255)) return 3;
      if ((int8_t)o[48 + k] != clamp((int8_t)a[k] - (int8_t)b[k], -128, 127)) return 4;
    }
    for (int k = 0; k < 8; k++) {
      if (o16[k] != clamp(a16[k] + b16[k], 0, 65535)) return 5;
      if ((int16_t)o16[8 + k] != clamp((int16_t)a16[k] + (int16_t)b16[k], -32768, 32767)) return 6;
      if (o16[16 + k] != clamp(a16[k] - b16[k], 0, 65535)) return 7;
      if ((int16_t)o16[24 + k] != clamp((int16_t)a16[k] - (int16_t)b16[k], -32768, 32767)) return 8;
    }
    absd(o, a, b);
    memcpy(o16, o + 32, 32);
    for (int k = 0; k < 16; k++) {
      if (o[k] != dist(a[k], b[k])) return 9;
      if (o[16 + k] != (uint8_t)dist((int8_t)a[k], (int8_t)b[k])) return 10;
    }
    for (int k = 0; k < 8; k++) {
      if (o16[k] != dist(a16[k], b16[k])) return 11;
      if (o16[8 + k] != (uint16_t)dist((int16_t)a16[k], (int16_t)b16[k])) return 12;
    }
    for (int k = 0; k < 16; k++) acc[k] = next();
    memcpy(o, acc, 128);
    sums(o, a, b);
    memcpy(o64, o, 128);
    const uint32_t *acc32 = (const uint32_t *)acc;
    const uint16_t *acc16 = (const uint16_t *)acc;
    memcpy(o32, o + 16, 48);
    memcpy(o16, o + 96, 16);
    for (int k = 0; k < 2; k++) {
      uint64_t e = acc[k], f = acc[6 + k], g = acc[8 + k], h = acc[10 + k];
      for (int j = 0; j < 8; j++) { e += a[8 * k + j]; h += dist(a[8 * k + j], b[8 * k + j]); }
      for (int j = 0; j < 4; j++) f += a16[4 * k + j];
      for (int j = 0; j < 2; j++) g += a32[2 * k + j];
      if (o64[k] != e) return 13;
      if (o64[6 + k] != f) return 16;
      if (o64[8 + k] != g) return 17;
      if (o64[10 + k] != h) return 18;
    }
    for (int k = 0; k < 4; k++) {
      uint32_t e = acc32[4 + k] + a[4 * k] + a[4 * k + 1] + a[4 * k + 2] + a[4 * k + 3];
      uint32_t f = acc32[8 + k] + a16[2 * k] + a16[2 * k + 1];
      if (o32[k] != e) return 14;
      if (o32[4 + k] != f) return 15;
    }
    for (int k = 0; k < 8; k++) if (o16[k] != (uint16_t)(acc16[48 + k] + a[2 * k] + a[2 * k + 1])) return 19;
    uint64_t sl[2] = {acc[0], acc[1]};
    sad_loop(sl, a, b, 8);
    for (int k = 0; k < 2; k++) {
      uint64_t e = acc[k];
      for (int v = 0; v < 8; v++) for (int j = 0; j < 8; j++) e += dist(a[16 * v + 8 * k + j], b[16 * v + 8 * k + j]);
      if (sl[k] != e) return 20;
    }
    uint64_t w[8];
    memcpy(w, acc, 64);
    wide32(o, a, b, w);
    for (int k = 0; k < 32; k++) {
      if (o[k] != clamp(a[k] + b[k], 0, 255)) return 21;
      if (o[32 + k] != dist(a[k], b[k])) return 22;
      if (o[64 + k] != (uint8_t)dist((int8_t)a[k], (int8_t)b[k])) return 23;
    }
    for (int k = 0; k < 4; k++) {
      uint64_t e = acc[k];
      for (int j = 0; j < 8; j++) e += dist(a[8 * k + j], b[8 * k + j]);
      if (w[k] != e) return 24;
    }
    memcpy(w, acc, 64);
    wide64(o, a, b, w);
    for (int k = 0; k < 64; k++) {
      if (o[k] != clamp(a[k] - b[k], 0, 255)) return 25;
      if (o[64 + k] != dist(a[k], b[k])) return 26;
      if (o[128 + k] != (uint8_t)dist((int8_t)a[k], (int8_t)b[k])) return 27;
    }
    for (int k = 0; k < 8; k++) {
      uint64_t e = acc[k];
      for (int j = 0; j < 8; j++) e += a[8 * k + j];
      if (w[k] != e) return 28;
    }
  }
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_sse41(lir, drv), 0);
    assert_eq(run_wide(lir, drv), 0);
    assert_eq(run_zmm(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// wasm32 keeps a value the next instruction reads on the operand stack: neither `local.set` nor
// `local.get` when nothing reads it again, `local.tee` when an instruction does; an equality with 0 is
// `eqz`; a body that ends in its return ends without it. Each runs as before.
@test
fn wasm_values_stay_on_the_stack() {
    let lir = M"(lir ptr 8
sym @sq1 fn global
sym @tw fn global
sym @isz fn global
fn @sq1
  sig (i32) -> i32
b0(v0: i32):
  v1 = mul.i32 v0, v0
  v2 = iconst.i32 1
  v3 = add.i32 v1, v2
  ret v3
fn @tw
  sig (i32) -> i32
b0(v0: i32):
  v1 = mul.i32 v0, v0
  v2 = add.i32 v1, v1
  ret v2
fn @isz
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = icmp.eq v0, v1
  v3 = zext.i32 v2
  ret v3
)";
    let mut obj = Vector::<u8>::new();
    let t = format("lir ptr 4\n{}", lir.slice(10, lir.len()));
    assert(
        object_of(&t, tgt::axis_index("wasm", false), tgt::axis_index("wasm32", true), 0, &mut obj),
        "the wasm object",
    );
    // local.get 0, local.get 0, i32.mul, then: i32.const 1, i32.add, end; local.tee 0 (the parameter's
    // local, free past the product), local.get 0, i32.add, end; and local.get 0, i32.eqz, end.
    let sq1: [u8; 9] = [0x20, 0x00, 0x20, 0x00, 0x6C, 0x41, 0x01, 0x6A, 0x0B];
    let tw: [u8; 11] = [0x20, 0x00, 0x20, 0x00, 0x6C, 0x22, 0x00, 0x20, 0x00, 0x6A, 0x0B];
    let isz: [u8; 4] = [0x20, 0x00, 0x45, 0x0B];
    assert(holds(&obj, sq1[0..9]), "sq1");
    assert(holds(&obj, tw[0..11]), "tw");
    assert(holds(&obj, isz[0..4]), "isz");
    let drv = M"(#include <stdint.h>
int32_t sq1(int32_t);
int32_t tw(int32_t);
int32_t isz(int32_t);
int main(void) {
  for (int32_t x = -3; x < 4; x++) {
    if (sq1(x) != x * x + 1 || tw(x) != 2 * x * x || isz(x) != (x == 0)) return 1;
  }
  return 0;
}
)";
    if cli::has_cc() {
        assert_eq(run_native(lir, drv), 0);
        assert_eq(run_wasm(lir, drv), 0);
    }
}

// wasm32 locals: a loop's parameters take the entry parameters' locals their first edge passes, so that edge
// and an exit's edge into a block that returns its parameter move nothing; a truncation of a value that
// fits, or one a select takes only where its condition bounds the value, masks nothing; a parameter one
// instruction reads right after its only edge, and a value a return reads right after its write, stay on
// the stack; a comparison only
// a select reads is computed at the select, inverted when a constant true side goes second. Each runs as
// before.
@test
fn wasm_locals_follow_their_values() {
    let lir = M"(lir ptr 8
sym @gcd fn global
sym @sat fn global
sym @hi8 fn global
sym @mid8 fn global
sym @pick fn global
sym @sat2 fn global
sym @sw fn global
fn @gcd
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 0
  v3 = icmp.eq v1, v2
  br v3, b3, b1(v0, v1)
b1(v4: i32, v5: i32):
  v6 = urem.i32 v4, v5
  v7 = icmp.eq v6, v2
  br v7, b2(v5), b1(v5, v6)
b2(v8: i32):
  ret v8
b3:
  ret v0
fn @sat
  sig (i8, i8) -> i8
b0(v0: i8, v1: i8):
  v2 = iconst.i32 255
  v3 = iconst.i8 -1
  v4 = zext.i32 v0
  v5 = zext.i32 v1
  v6 = add.i32 v4, v5
  v7 = trunc.i8 v6
  v8 = icmp.ugt v6, v2
  v9 = select.i8 v8, v3, v7
  ret v9
fn @hi8
  sig (i32) -> i8
b0(v0: i32):
  v1 = iconst.i32 24
  v2 = lshr.i32 v0, v1
  v3 = trunc.i8 v2
  ret v3
fn @mid8
  sig (i32) -> i8
b0(v0: i32):
  v1 = iconst.i32 16
  v2 = lshr.i32 v0, v1
  v3 = trunc.i8 v2
  ret v3
fn @pick
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 7
  v2 = iconst.i32 0
  v3 = icmp.eq v0, v2
  br v3, b1(v1), b2
b1(v4: i32):
  ret v4
b2:
  v5 = iconst.i32 9
  ret v5
fn @sat2
  sig (i8, i8) -> i8
b0(v0: i8, v1: i8):
  v2 = iconst.i32 256
  v3 = iconst.i8 -1
  v4 = zext.i32 v0
  v5 = zext.i32 v1
  v6 = add.i32 v4, v5
  v7 = trunc.i8 v6
  v8 = icmp.ult v6, v2
  v9 = select.i8 v8, v7, v3
  ret v9
fn @sw
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 2
  v3 = iconst.i32 5
  v4 = iconst.i32 3
  v5 = iconst.i32 1
  switch v0 [0 -> b4, 1 -> b3, 2 -> b2] else b1
b1:
  v6 = sub.i32 v1, v2
  ret v6
b2:
  v7 = xor.i32 v1, v3
  ret v7
b3:
  v8 = mul.i32 v1, v4
  ret v8
b4:
  v9 = add.i32 v1, v5
  ret v9
)";
    let mut obj = Vector::<u8>::new();
    let t = format("lir ptr 4\n{}", lir.slice(10, lir.len()));
    assert(
        object_of(&t, tgt::axis_index("wasm", false), tgt::axis_index("wasm32", true), 0, &mut obj),
        "the wasm object",
    );
    // pick: if, i32.const 7, return: the edge's write and the return's read of the parameter go.
    let pick: [u8; 5] = [0x04, 0x40, 0x41, 0x07, 0x0F];
    assert(holds(&obj, pick[0..5]), "pick");
    // gcd: end of the early return, loop, local.get 0, local.get 1, i32.rem_u (no copy into the loop's
    // locals); i32.eqz, if, local.get 1, return (no copy into the exit's).
    let gcd_in: [u8; 8] = [0x0B, 0x03, 0x40, 0x20, 0x00, 0x20, 0x01, 0x70];
    let gcd_out: [u8; 6] = [0x45, 0x04, 0x40, 0x20, 0x01, 0x0F];
    // sat: local.get 0, local.get 1, i32.add, local.tee 1, i32.const 255, local.get 1, i32.const 255,
    // i32.le_u, select, end.
    let sat: [u8; 17] = [
        0x20,
        0x00,
        0x20,
        0x01,
        0x6A,
        0x22,
        0x01,
        0x41,
        0xFF,
        0x01,
        0x20,
        0x01,
        0x41,
        0xFF,
        0x01,
        0x4D,
        0x1B,
    ];
    // hi8: local.get 0, i32.const 24, i32.shr_u, end; mid8 masks: i32.const 16, i32.shr_u, i32.const 255,
    // i32.and.
    // sat2: i32.add, local.tee 1, i32.const 255, local.get 1, i32.const 256, i32.lt_u, select.
    let sat2: [u8; 13] = [0x6A, 0x22, 0x01, 0x41, 0xFF, 0x01, 0x20, 0x01, 0x41, 0x80, 0x02, 0x49, 0x1B];
    // sw: local.get 1, i32.const 1, i32.add, return: the sum, whose local the switch's value had, stays
    // on the stack though the next compare reads that local.
    let sw: [u8; 6] = [0x20, 0x01, 0x41, 0x01, 0x6A, 0x0F];
    let hi8: [u8; 6] = [0x20, 0x00, 0x41, 0x18, 0x76, 0x0B];
    let mid8: [u8; 7] = [0x41, 0x10, 0x76, 0x41, 0xFF, 0x01, 0x71];
    assert(holds(&obj, gcd_in[0..8]), "gcd's loop");
    assert(holds(&obj, gcd_out[0..6]), "gcd's exit");
    assert(holds(&obj, sat[0..17]), "sat");
    assert(holds(&obj, sat2[0..13]), "sat2");
    assert(holds(&obj, sw[0..6]), "sw");
    assert(holds(&obj, hi8[0..6]), "hi8");
    assert(holds(&obj, mid8[0..7]), "mid8");
    let drv = M"(#include <stdint.h>
uint32_t gcd(uint32_t, uint32_t);
uint8_t sat(uint8_t, uint8_t);
uint8_t hi8(uint32_t);
uint8_t mid8(uint32_t);
int32_t pick(int32_t);
uint8_t sat2(uint8_t, uint8_t);
uint32_t sw(uint32_t, uint32_t);
static uint32_t ref(uint32_t a, uint32_t b) { while (b) { uint32_t r = a % b; a = b; b = r; } return a; }
int main(void) {
  for (uint32_t a = 0; a < 40; a++) {
    for (uint32_t b = 0; b < 40; b++) {
      if (gcd(a * 7, b * 3) != ref(a * 7, b * 3)) return 1;
      unsigned s = (a * 13 + b * 7) & 255, u = (a * 5 + b * 11) & 255;
      if (sat(s, u) != (s + u > 255 ? 255 : s + u) || sat2(s, u) != sat(s, u)) return 2;
      uint32_t x = a * 0x9E3779B9u + b * 0x85EBCA6Bu;
      if (hi8(x) != (x >> 24) || mid8(x) != ((x >> 16) & 255)) return 3;
      if (pick((int32_t)a - 3) != (a == 3 ? 7 : 9)) return 4;
      uint32_t e = a % 5;
      if (sw(e, b) != (e == 0 ? b + 1 : e == 1 ? b * 3 : e == 2 ? (b ^ 5) : b - 2)) return 5;
    }
  }
  return 0;
}
)";
    if cli::has_cc() {
        assert_eq(run_native(lir, drv), 0);
        assert_eq(run_wasm(lir, drv), 0);
    }
}

// x86-64: a commutative operation whose result the return's part takes writes over the operand already in
// that register (`or rax, rdx`, no copy after); a loop's products that replace its header parameters share
// their registers in the plan, so the invariant bound and the exit's parameters keep registers too (no
// frame for slots). Each runs as before.
@test
fn x86_results_and_loop_steps_keep_their_registers() {
    let lir = M"(lir ptr 8
sym @dm fn global
sym @fact fn global
fn @dm
  layout l0 size 8 align 2 [0 i32, 4 i32]
  sig (i32, i32) -> l0
b0(v0: i32, v1: i32, v2: ptr):
  v3 = iconst.i64 32
  v4 = udiv.i32 v0, v1
  v5 = mul.i32 v4, v1
  v6 = sub.i32 v0, v5
  v7 = zext.i64 v6
  v8 = shl.i64 v7, v3
  v9 = zext.i64 v4
  v10 = or.i64 v8, v9
  store v10, v2 align 2
  ret
fn @fact
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1
  v2 = iconst.i64 0
  v3 = iconst.i64 -4
  v4 = and.i64 v0, v3
  v5 = icmp.ne v4, v2
  br v5, b3, b2(v0, v1)
b1(v6: i64, v7: i64):
  v8 = mul.i64 v7, v6
  v9 = sub.i64 v6, v1
  v10 = icmp.eq v9, v2
  br v10, b7, b1(v9, v8)
b2(v11: i64, v12: i64):
  v13 = icmp.eq v11, v2
  br v13, b6(v12), b1(v11, v12)
b3:
  v14 = sub.i64 v0, v4
  v15 = iconst.i64 2
  v16 = iconst.i64 3
  v17 = iconst.i64 4
  jmp b4(v0, v1, v1, v1, v1)
b4(v18: i64, v19: i64, v20: i64, v21: i64, v22: i64):
  v23 = sub.i64 v18, v1
  v24 = sub.i64 v18, v15
  v25 = sub.i64 v18, v16
  v26 = mul.i64 v19, v18
  v27 = mul.i64 v20, v23
  v28 = mul.i64 v21, v24
  v29 = mul.i64 v22, v25
  v30 = sub.i64 v18, v17
  v31 = icmp.ugt v30, v14
  br v31, b4(v30, v26, v27, v28, v29), b5
b5:
  v32 = mul.i64 v26, v27
  v33 = mul.i64 v32, v28
  v34 = mul.i64 v33, v29
  jmp b2(v14, v34)
b6(v35: i64):
  ret v35
b7:
  ret v8
)";
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(lir, tgt::axis_index("linux", false), tgt::axis_index("x86_64", true), 0, &mut obj),
        "the x86-64 object",
    );
    // dm: or rax, rdx; leave; ret. fact: no `sub rsp, imm8` (no slot).
    let orr: [u8; 5] = [0x48, 0x09, 0xD0, 0xC9, 0xC3];
    let sub_rsp: [u8; 3] = [0x48, 0x83, 0xEC];
    assert(holds(&obj, orr[0..5]), "dm's or");
    assert(!holds(&obj, sub_rsp[0..3]), "fact's slots");
    let drv = M"(#include <stdint.h>
struct qr { uint32_t q, r; };
struct qr dm(uint32_t, uint32_t);
uint64_t fact(uint64_t);
int main(void) {
  for (uint32_t a = 0; a < 50; a++) {
    struct qr x = dm(a * 977u + 13u, a % 7u + 1u);
    if (x.q != (a * 977u + 13u) / (a % 7u + 1u) || x.r != (a * 977u + 13u) % (a % 7u + 1u)) return 1;
    uint64_t f = 1;
    for (uint64_t k = 1; k <= a; k++) f *= k;
    if (fact(a) != f) return 2;
  }
  return 0;
}
)";
    if cli::has_cc() {
        assert_eq(run_native(lir, drv), 0);
        assert_eq(run_wasm(lir, drv), 0);
    }
}

// wasm32: an edge that passes one value to two parameters of a loop header, the value live on past the
// loop on another path: each parameter takes its own local, though the value's local may go to one.
@test
fn wasm_one_argument_to_two_parameters_keeps_two_locals() {
    let lir = M"(lir ptr 8
sym @two fn global
fn @two
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 0
  v3 = icmp.sle v0, v2
  br v3, b4, b1(v2, v1, v1)
b1(v4: i32, v5: i32, v6: i32):
  v7 = icmp.slt v4, v0
  br v7, b2, b3
b2:
  v8 = add.i32 v5, v4
  v9 = iconst.i32 1
  v10 = shl.i32 v6, v9
  v11 = add.i32 v10, v9
  v12 = add.i32 v4, v9
  jmp b1(v12, v8, v11)
b3:
  v13 = iconst.i32 1000
  v14 = mul.i32 v5, v13
  v15 = add.i32 v14, v6
  ret v15
b4:
  v16 = sub.i32 v2, v1
  ret v16
)";
    let drv = M"(#include <stdint.h>
int32_t two(int32_t, int32_t);
int main(void) {
  return two(5, 3) == 13127 && two(0, 3) == -3 && two(2, 10) == 11043 ? 0 : 1;
}
)";
    if cli::has_cc() {
        assert_eq(run_native(lir, drv), 0);
        assert_eq(run_wasm(lir, drv), 0);
    }
}

// Whether `bytes` holds `seq` at some offset.
fn holds(bytes: &Vector<u8>, seq: []u8) bool {
    let n = seq.len();
    if bytes.len() < n {
        return false;
    }
    for at in 0..bytes.len() - n + 1 {
        let mut k: usize = 0;
        while k < n && bytes[at + k] == seq[k] {
            k += 1;
        }
        if k == n {
            return true;
        }
    }
    return false;
}

// A body whose one call is in a rare block, with aggregates in registers that its entry stores into slots,
// after a body of more blocks: the stores use the frame, so the frame is set up at the entry, not on the
// edge into the rare block (no shrink-wrapping).
@test
fn register_aggregates_stored_at_entry_keep_the_frame() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @steps fn global
sym @fail fn global
sym @need fn global
fn @steps
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1
  v2 = iconst.i64 3
  v3 = icmp.ult v0, v2
  br v3, b1, b2
b1:
  v4 = add.i64 v0, v1
  jmp b3(v4)
b2:
  v5 = sub.i64 v0, v1
  jmp b3(v5)
b3(v6: i64):
  v7 = icmp.eq v6, v2
  br v7, b4, b5
b4:
  v8 = mul.i64 v6, v2
  jmp b6(v8)
b5:
  v9 = xor.i64 v6, v2
  jmp b6(v9)
b6(v10: i64):
  ret v10
fn @need
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (ptr, l0, ptr, i32, i8, l0) -> i8
b0(v0: ptr, v1: ptr, v2: ptr, v3: i32, v4: i8, v5: ptr):
  br v4, b1, b2
b1:
  v6 = iconst.i8 1
  ret v6
b2: unlikely
  v7 = call.i8 @fail(v0, v1, v2, v3, v5) : (ptr, l0, ptr, i32, l0) -> i8
  ret v7
)";
    let drv = M"(#include <stdint.h>
struct S { const char *p; int64_t n; };
int64_t steps(int64_t);
int8_t need(void *, struct S, void *, int32_t, int8_t, struct S);
int8_t fail(void *c, struct S name, void *b, int32_t i, struct S what) {
  return (int8_t)(name.n + what.n + i + (c == b) + name.p[0] - what.p[0]);
}
int main(void) {
  struct S a = {"x", 5}, w = {"y", 7};
  int x = 0;
  if (steps(1) != 1 || steps(2) != 9 || steps(5) != 7) return 1;
  if (need(&x, a, &x, 2, 1, w) != 1) return 2;
  if (need(&x, a, &x, 2, 0, w) != 5 + 7 + 2 + 1 - 1) return 3;
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
}

// Aggregates a call takes in registers, built by stores into a slot no other access reads: the stores'
// values go to the argument registers (the last of each part, a constant, a float part, a slot two calls
// share); a slot read after the call keeps its stores. A runtime call (`memset`) takes its operands from
// their registers, its fill byte extended.
@test
fn relayed_aggregate_arguments_and_runtime_calls_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @take fn global
sym @takef fn global
sym @relay fn global
sym @kept fn global
sym @fill fn global
fn @relay
  layout l0 size 16 align 3 [0 i64, 8 i64]
  layout l1 size 16 align 3 [0 f64, 8 i64]
  sig (i64, i64, f64) -> i64
  slot s0 size 16 align 3
  slot s1 size 16 align 3
b0(v0: i64, v1: i64, v2: f64):
  v3 = slotaddr s0
  v4 = iconst.i64 7
  store v0, v3 align 3
  store v4, v3+8 align 3
  store v1, v3+8 align 3
  v5 = call.i64 @take(v3, v0) : (l0, i64) -> i64
  store v5, v3 align 3
  store v4, v3+8 align 3
  v6 = call.i64 @take(v3, v1) : (l0, i64) -> i64
  v7 = slotaddr s1
  store v2, v7 align 3
  store v6, v7+8 align 3
  v8 = call.i64 @takef(v7) : (l1) -> i64
  v9 = add.i64 v8, v5
  ret v9
fn @kept
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> i64
  slot s0 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  store v0, v1+8 align 3
  v2 = call.i64 @take(v1, v0) : (l0, i64) -> i64
  v3 = load.i64 v1+8 align 3
  v4 = add.i64 v2, v3
  ret v4
fn @fill
  sig (ptr, i32, i64) -> void
b0(v0: ptr, v1: i32, v2: i64):
  v3 = trunc.i8 v1
  memset v0, v3, v2
  ret
)";
    let drv = M"(#include <stdint.h>
#include <string.h>
struct P { int64_t a, b; };
struct Q { double d; int64_t b; };
int64_t relay(int64_t, int64_t, double);
int64_t kept(int64_t);
void fill(unsigned char *, int, int64_t);
int64_t take(struct P p, int64_t k) { return p.a * 3 + p.b * 5 + k; }
int64_t takef(struct Q q) { return (int64_t)(q.d * 2) + q.b; }
int main(void) {
  int64_t t1 = 11 * 3 + 13 * 5 + 11;
  int64_t t2 = t1 * 3 + 7 * 5 + 13;
  if (relay(11, 13, 2.5) != 5 + t2 + t1) return 1;
  if (kept(4) != 4 * 3 + 4 * 5 + 4 + 4) return 2;
  unsigned char b[40];
  memset(b, 1, sizeof b);
  fill(b + 3, 0x1A5, 29);
  for (int k = 0; k < 40; k++) {
    if (b[k] != (k >= 3 && k < 32 ? 0xA5 : 1)) return 3;
  }
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
}

// Float loop values across calls: callee-saved xmm homes under Microsoft x64 (the prologue saves them, so
// the C caller's live doubles survive), memory under System V, v8..v15 on arm64.
@test
fn float_loop_values_live_across_calls() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @g fn global\nsym @fl fn global\nfn @fl\n  sig (i64) -> f64\nb0(v0: i64):\n  v1 = iconst.i64 0\n  v2 = fconst.f64 0x3ff0000000000000\n  v3 = fconst.f64 0x4000000000000000\n  jmp b1(v1, v2, v3, v3)\nb1(v4: i64, v5: f64, v6: f64, v7: f64):\n  v8 = call.f64 @g(v4) : (i64) -> f64\n  v9 = fadd.f64 v5, v8\n  v10 = fmul.f64 v6, v3\n  v11 = fsub.f64 v7, v8\n  v12 = iconst.i64 1\n  v13 = add.i64 v4, v12\n  v14 = icmp.slt v13, v0\n  br v14, b1(v13, v9, v10, v11), b2\nb2:\n  v15 = fadd.f64 v9, v10\n  v16 = fadd.f64 v15, v11\n  ret v16\n";
    let drv = "#include <stdint.h>\ndouble fl(int64_t);\ndouble g(int64_t i) { return (double)i * 0.5; }\nint main(void) {\n  double s = 0, t = 1, u = 3, w = 7;\n  for (int k = 0; k < 4; k++) {\n    double r = fl(10);\n    s += r;\n    t *= 1.5;\n    u -= 0.25;\n    w += t;\n  }\n  return s == 4 * 2051.0 && t == 5.0625 && u == 2.0 && w == 19.1875 ? 0 : 1;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A scalar in every lane (`splat`), for each lane type, of 8, 16 and 32 bytes: the vector's bytes and
// not one past them.
@test
fn splats_of_every_lane_type_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @b16 fn global\nsym @h8 fn global\nsym @w4 fn global\nsym @d2 fn global\nsym @f4 fn global\nsym @g2 fn global\nsym @b8 fn global\nsym @f2 fn global\nsym @g4 fn global\nfn @b16\n  sig (ptr, i8) -> void\nb0(v0: ptr, v1: i8):\n  v2 = splat.v16i8 v1\n  store v2, v0 align 0\n  ret\nfn @h8\n  sig (ptr, i16) -> void\nb0(v0: ptr, v1: i16):\n  v2 = splat.v8i16 v1\n  store v2, v0 align 0\n  ret\nfn @w4\n  sig (ptr, i32) -> void\nb0(v0: ptr, v1: i32):\n  v2 = splat.v4i32 v1\n  store v2, v0 align 0\n  ret\nfn @d2\n  sig (ptr, i64) -> void\nb0(v0: ptr, v1: i64):\n  v2 = splat.v2i64 v1\n  store v2, v0 align 0\n  ret\nfn @f4\n  sig (ptr, f32) -> void\nb0(v0: ptr, v1: f32):\n  v2 = splat.v4f32 v1\n  store v2, v0 align 0\n  ret\nfn @g2\n  sig (ptr, f64) -> void\nb0(v0: ptr, v1: f64):\n  v2 = splat.v2f64 v1\n  store v2, v0 align 0\n  ret\nfn @b8\n  sig (ptr, i8) -> void\nb0(v0: ptr, v1: i8):\n  v2 = splat.v8i8 v1\n  store v2, v0 align 0\n  ret\nfn @f2\n  sig (ptr, f32) -> void\nb0(v0: ptr, v1: f32):\n  v2 = splat.v2f32 v1\n  store v2, v0 align 0\n  ret\nfn @g4\n  sig (ptr, f64) -> void\nb0(v0: ptr, v1: f64):\n  v2 = splat.v4f64 v1\n  store v2, v0 align 0\n  ret\n";
    let drv = "#include <stdint.h>\nvoid b16(void *, int8_t);\nvoid h8(void *, int16_t);\nvoid w4(void *, int32_t);\nvoid d2(void *, int64_t);\nvoid f4(void *, float);\nvoid g2(void *, double);\nvoid b8(void *, int8_t);\nvoid f2(void *, float);\nvoid g4(void *, double);\nint main(void) {\n  int r = 0;\n  { int8_t a[17] = {0}; b16(a, -7); for (int i = 0; i < 16; i++) if (a[i] != -7) r = 1; }\n  { int8_t a[17] = {0}; b16(a, -7); if (a[16] != 0) r = 20; }\n  { int16_t a[9] = {0}; h8(a, -1234); for (int i = 0; i < 8; i++) if (a[i] != -1234) r = 2; }\n  { int16_t a[9] = {0}; h8(a, -1234); if (a[8] != 0) r = 21; }\n  { int32_t a[5] = {0}; w4(a, -123456789); for (int i = 0; i < 4; i++) if (a[i] != -123456789) r = 3; }\n  { int32_t a[5] = {0}; w4(a, -123456789); if (a[4] != 0) r = 22; }\n  { int64_t a[3] = {0}; d2(a, INT64_C(-1234567890123)); for (int i = 0; i < 2; i++) if (a[i] != INT64_C(-1234567890123)) r = 4; }\n  { int64_t a[3] = {0}; d2(a, INT64_C(-1234567890123)); if (a[2] != 0) r = 23; }\n  { float a[5] = {0}; f4(a, 1.5f); for (int i = 0; i < 4; i++) if (a[i] != 1.5f) r = 5; }\n  { float a[5] = {0}; f4(a, 1.5f); if (a[4] != 0) r = 24; }\n  { double a[3] = {0}; g2(a, -2.25); for (int i = 0; i < 2; i++) if (a[i] != -2.25) r = 6; }\n  { double a[3] = {0}; g2(a, -2.25); if (a[2] != 0) r = 25; }\n  { int8_t a[9] = {0}; b8(a, -7); for (int i = 0; i < 8; i++) if (a[i] != -7) r = 7; }\n  { int8_t a[9] = {0}; b8(a, -7); if (a[8] != 0) r = 26; }\n  { float a[3] = {0}; f2(a, 1.5f); for (int i = 0; i < 2; i++) if (a[i] != 1.5f) r = 8; }\n  { float a[3] = {0}; f2(a, 1.5f); if (a[2] != 0) r = 27; }\n  { double a[5] = {0}; g4(a, -2.25); for (int i = 0; i < 4; i++) if (a[i] != -2.25) r = 9; }\n  { double a[5] = {0}; g4(a, -2.25); if (a[4] != 0) r = 28; }\n  return r;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Six sums a loop updates on one side of a branch, then passes through a block that jumps back to the
// header: that block's parameters share the header parameters' registers or slots (`back_share`), and
// the updates write them in place.
@test
fn sums_through_a_join_into_the_loop_header_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @acc fn global\nfn @acc\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = iconst.i64 0\n  v2 = iconst.i64 1\n  v3 = iconst.i64 3\n  v4 = iconst.i64 5\n  jmp b1(v1, v1, v1, v1, v1, v1, v1)\nb1(v5: i64, v6: i64, v7: i64, v8: i64, v9: i64, v10: i64, v11: i64):\n  v12 = icmp.slt v5, v0\n  br v12, b2, b5\nb2:\n  v13 = and.i64 v5, v2\n  v14 = icmp.ne v13, v1\n  br v14, b3, b4(v6, v7, v8, v9, v10, v11)\nb3:\n  v15 = add.i64 v6, v5\n  v16 = add.i64 v7, v3\n  v17 = add.i64 v8, v13\n  v18 = mul.i64 v5, v4\n  v19 = add.i64 v9, v18\n  v20 = sub.i64 v10, v5\n  v21 = xor.i64 v11, v5\n  jmp b4(v15, v16, v17, v19, v20, v21)\nb4(v22: i64, v23: i64, v24: i64, v25: i64, v26: i64, v27: i64):\n  v28 = add.i64 v5, v2\n  jmp b1(v28, v22, v23, v24, v25, v26, v27)\nb5:\n  v29 = mul.i64 v7, v3\n  v30 = mul.i64 v8, v4\n  v31 = iconst.i64 7\n  v32 = mul.i64 v9, v31\n  v33 = iconst.i64 11\n  v34 = mul.i64 v10, v33\n  v35 = iconst.i64 13\n  v36 = mul.i64 v11, v35\n  v37 = add.i64 v6, v29\n  v38 = add.i64 v37, v30\n  v39 = add.i64 v38, v32\n  v40 = add.i64 v39, v34\n  v41 = add.i64 v40, v36\n  ret v41\n";
    let drv = "#include <stdint.h>\nint64_t acc(int64_t);\nstatic int64_t want(int64_t n) {\n  int64_t a = 0, b = 0, c = 0, d = 0, e = 0, f = 0;\n  for (int64_t i = 0; i < n; i++) {\n    if (i & 1) { a += i; b += 3; c += i & 1; d += i * 5; e -= i; f ^= i; }\n  }\n  return a + b * 3 + c * 5 + d * 7 + e * 11 + f * 13;\n}\nint main(void) {\n  int64_t ns[4] = {0, 1, 10, 1001};\n  for (int k = 0; k < 4; k++) if (acc(ns[k]) != want(ns[k])) return k + 1;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A loop whose latch exits on its other edge: the next counter is defined in the counter's register when
// no path from that exit reads the counter before the header (`probe`; the header's own exit reads it
// first), and not when one does (`last` reads the counter the latch leaves with).
@test
fn a_latch_exit_that_reads_no_counter_lets_the_step_take_its_register() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @probe fn global\nsym @last fn global\nfn @probe\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = iconst.i64 0\n  v3 = iconst.i64 1\n  v4 = iconst.i64 3\n  v5 = iconst.i64 10\n  v6 = iconst.i64 -1\n  jmp b1(v2)\nb1(v7: i64):\n  v8 = mul.i64 v7, v4\n  v9 = icmp.eq v8, v1\n  br v9, b3, b2\nb2:\n  v10 = add.i64 v7, v3\n  v11 = icmp.slt v10, v0\n  br v11, b1(v10), b4\nb3:\n  v12 = mul.i64 v7, v5\n  ret v12\nb4:\n  ret v6\nfn @last\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = iconst.i64 0\n  v3 = iconst.i64 1\n  v4 = iconst.i64 3\n  v5 = iconst.i64 10\n  v6 = iconst.i64 100\n  jmp b1(v2)\nb1(v7: i64):\n  v8 = mul.i64 v7, v4\n  v9 = icmp.eq v8, v1\n  br v9, b3, b2\nb2:\n  v10 = add.i64 v7, v3\n  v11 = icmp.slt v10, v0\n  br v11, b1(v10), b4\nb3:\n  v12 = mul.i64 v7, v5\n  ret v12\nb4:\n  v13 = mul.i64 v7, v6\n  ret v13\n";
    let drv = "#include <stdint.h>\nint64_t probe(int64_t, int64_t);\nint64_t last(int64_t, int64_t);\nint main(void) {\n  if (probe(10, 9) != 30 || probe(10, 27) != 90 || probe(10, 11) != -1 || probe(1, 0) != 0) return 1;\n  if (last(10, 9) != 30 || last(10, 11) != 900 || last(1, 5) != 0) return 2;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Lane-wise comparisons (`vcmp`) of every lane type and condition, and lane selects (`vsel`), in vector
// registers (8 and 16 bytes) and in memory (32 and 64 bytes; ymm and zmm registers with AVX2 and AVX-512):
// each lane's mask against C's comparison, signed and unsigned limits, NaN and signed zeros included. The
// x86-64 objects build on every host.
@test
fn lane_compares_and_selects_run() {
    // Per vector type: its text, its C lane type and the unsigned one, its lanes, whether its lanes are
    // floats.
    let names: []str = [
        "v16i8",
        "v8i16",
        "v4i32",
        "v2i64",
        "v8i32",
        "v8i8",
        "v4f32",
        "v2f64",
        "v4f64",
        "v2f32",
        "v32i8",
        "v16i16",
        "v4i64",
        "v8f32",
        "v64i8",
        "v32i16",
        "v16i32",
        "v8i64",
        "v16f32",
        "v8f64",
    ];
    let cty: []str = [
        "int8_t",
        "int16_t",
        "int32_t",
        "int64_t",
        "int32_t",
        "int8_t",
        "float",
        "double",
        "double",
        "float",
        "int8_t",
        "int16_t",
        "int64_t",
        "float",
        "int8_t",
        "int16_t",
        "int32_t",
        "int64_t",
        "float",
        "double",
    ];
    let uty: []str = [
        "uint8_t",
        "uint16_t",
        "uint32_t",
        "uint64_t",
        "uint32_t",
        "uint8_t",
        "int32_t",
        "int64_t",
        "int64_t",
        "int32_t",
        "uint8_t",
        "uint16_t",
        "uint64_t",
        "int32_t",
        "uint8_t",
        "uint16_t",
        "uint32_t",
        "uint64_t",
        "int32_t",
        "int64_t",
    ];
    let nl: []u32 = [16, 8, 4, 2, 8, 8, 4, 2, 4, 2, 32, 16, 4, 8, 64, 32, 16, 8, 16, 8];
    let isf: []bool = [
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        true,
        true,
    ];
    let conds: []str = ["eq", "ne", "slt", "sle", "sgt", "sge", "ult", "ule", "ugt", "uge"];
    let cops: []str = ["==", "!=", "<", "<=", ">", ">=", "<", "<=", ">", ">="];
    let fconds: []str = ["oeq", "une", "olt", "ole", "ogt", "oge"];
    let fops: []str = ["==", "!=", "<", "<=", ">", ">="];
    let mut lir = String::from_str("lir ptr 8\n");
    let mut decl = String::from_str("#include <stdint.h>\n#include <math.h>\n#include <string.h>\n");
    let mut body = String::from_str("int main(void) {\n  int r = 0;\n");
    let mut nf: u32 = 0;
    for k in 0..names.len() {
        let fl = isf[k];
        let n = if fl {
            6usize
        } else {
            10usize
        };
        // The inputs: limits and repeats, equal lanes among them.
        let eb = if cty[k] == "int8_t" {
            1u32
        } else if cty[k] == "int16_t" {
            2u32
        } else if cty[k] == "int32_t" || cty[k] == "float" {
            4u32
        } else {
            8u32
        };
        let vals = if fl {
            "0.0, -0.0, 1.5, -2.0, NAN, INFINITY, -INFINITY, 3.0"
        } else if eb == 1 {
            "0, 1, -1, 127, -128, 5, -5, 100"
        } else if eb == 2 {
            "0, 1, -1, 32767, -32768, 5, -5, 1000"
        } else if eb == 4 {
            "0, 1, -1, 2147483647, -2147483647 - 1, 5, -5, 100000"
        } else {
            "0, 1, -1, INT64_MAX, INT64_MIN, 5, -5, 100000"
        };
        let mty = if fl && eb == 4 {
            "int32_t"
        } else if fl {
            "int64_t"
        } else {
            cty[k]
        };
        let mname = if names[k] == "v4f32" {
            "v4i32"
        } else if names[k] == "v2f64" {
            "v2i64"
        } else if names[k] == "v4f64" {
            "v4i64"
        } else if names[k] == "v2f32" {
            "v2i32"
        } else if names[k] == "v8f32" {
            "v8i32"
        } else if names[k] == "v16f32" {
            "v16i32"
        } else if names[k] == "v8f64" {
            "v8i64"
        } else {
            names[k]
        };
        body.format_into(
            "  {{\n    {} v[8] = {{{}}};\n    {} a[64], b[64], o[64], x[64], y[64]; {} m[64], w[64];\n    for (int i = 0; i < 64; i++) {{ a[i] = v[i % 8]; b[i] = i % 4 == 0 ? a[i] : v[(i * 3 + 1) % 8]; m[i] = i % 3 == 0 ? -1 : 0; x[i] = a[i]; y[i] = b[i]; }}\n",
            cty[k],
            vals,
            cty[k],
            mty,
        );
        for c in 0..n {
            let cond = if fl {
                fconds[c]
            } else {
                conds[c]
            };
            lir.format_into(
                "sym @c{} fn global\nfn @c{}\n  sig (ptr, ptr, ptr) -> void\nb0(v0: ptr, v1: ptr, v2: ptr):\n  v3 = load.{} v1 align 0\n  v4 = load.{} v2 align 0\n  v5 = vcmp.{}.{} v3, v4\n  store v5, v0 align 0\n  ret\n",
                nf,
                nf,
                names[k],
                names[k],
                cond,
                mname,
            );
            decl.format_into("void c{}(void *, const void *, const void *);\n", nf);
            let (l, rr) = if !fl && c >= 6 {
                (format("({})a[i]", uty[k]), format("({})b[i]", uty[k]))
            } else {
                (String::from_str("a[i]"), String::from_str("b[i]"))
            };
            let op = if fl {
                fops[c]
            } else {
                cops[c]
            };
            body.format_into(
                "    c{}(w, a, b); for (int i = 0; i < {}; i++) if (w[i] != ({} {} {} ? -1 : 0)) r = {};\n",
                nf,
                nl[k],
                l.as_str(),
                op,
                rr.as_str(),
                nf + 1,
            );
            nf += 1;
        }
        lir.format_into(
            "sym @s{} fn global\nfn @s{}\n  sig (ptr, ptr, ptr, ptr) -> void\nb0(v0: ptr, v1: ptr, v2: ptr, v3: ptr):\n  v4 = load.{} v1 align 0\n  v5 = load.{} v2 align 0\n  v6 = load.{} v3 align 0\n  v7 = vsel.{} v4, v5, v6\n  store v7, v0 align 0\n  ret\n",
            k,
            k,
            mname,
            names[k],
            names[k],
            names[k],
        );
        decl.format_into("void s{}(void *, const void *, const void *, const void *);\n", k);
        body.format_into(
            "    s{}(o, m, x, y); if (memcmp(o, x, 0) != 0) r = 999; for (int i = 0; i < {}; i++) if (memcmp(&o[i], m[i] ? &x[i] : &y[i], sizeof o[i]) != 0) r = {};\n  }}\n",
            k,
            nl[k],
            200 + k,
        );
    }
    body.push_str("  return r;\n}\n");
    decl.push_str(&body);
    let mut obj = Vector::<u8>::new();
    let x64 = tgt::axis_index("x86_64", true);
    assert(object_of(&lir, tgt::axis_index("linux", false), x64, 0, &mut obj), "the System V object");
    assert(object_of(&lir, tgt::axis_index("windows", false), x64, 0, &mut obj), "the Microsoft x64 object");
    assert(object_of(&lir, tgt::axis_index("linux", false), x64, WIDE, &mut obj), "the AVX2 object");
    assert(object_of(&lir, tgt::axis_index("windows", false), x64, WIDE, &mut obj), "the Microsoft x64 AVX2 object");
    assert(object_of(&lir, tgt::axis_index("linux", false), x64, Z512, &mut obj), "the AVX-512 object");
    assert(object_of(&lir, tgt::axis_index("windows", false), x64, Z512, &mut obj), "the Microsoft x64 AVX-512 object");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    assert_eq(run_native(&lir, &decl), 0);
    assert_eq(run_wide(&lir, &decl), 0);
    assert_eq(run_zmm(&lir, &decl), 0);
    assert_eq(run_wasm(&lir, &decl), 0);
}

// The even and odd lanes of two vectors (`vunzip`, `vunzip.odd`) of every lane width, in vector registers
// (8 and 16 bytes) and in memory (32 and 64 bytes; ymm and zmm registers with AVX2 and AVX-512): lane k is
// lane 2k (2k + 1) of the two operands' lanes in order, its bits unchanged (lanes with the sign bit set
// included).
@test
fn even_lanes_of_two_vectors_run() {
    let names: []str = [
        "v16i8",
        "v8i16",
        "v4i32",
        "v2i64",
        "v4f32",
        "v2f64",
        "v8i8",
        "v8i32",
        "v32i8",
        "v16i16",
        "v4i64",
        "v8f32",
        "v4f64",
        "v64i8",
        "v32i16",
        "v16i32",
        "v8i64",
        "v16f32",
        "v8f64",
    ];
    let cty: []str = [
        "int8_t",
        "int16_t",
        "int32_t",
        "int64_t",
        "float",
        "double",
        "int8_t",
        "int32_t",
        "int8_t",
        "int16_t",
        "int64_t",
        "float",
        "double",
        "int8_t",
        "int16_t",
        "int32_t",
        "int64_t",
        "float",
        "double",
    ];
    let nl: []u32 = [16, 8, 4, 2, 4, 2, 8, 8, 32, 16, 4, 8, 4, 64, 32, 16, 8, 16, 8];
    let eb: []u32 = [1, 2, 4, 8, 4, 8, 1, 4, 1, 2, 8, 4, 8, 1, 2, 4, 8, 4, 8];
    let mut lir = String::from_str("lir ptr 8\n");
    let mut drv = String::from_str("#include <stdint.h>\n#include <string.h>\n");
    let mut body = String::from_str("int main(void) {\n  int r = 0;\n");
    for k in 0..names.len() {
        lir.format_into(
            "sym @u{} fn global\nfn @u{}\n  sig (ptr, ptr, ptr) -> void\nb0(v0: ptr, v1: ptr, v2: ptr):\n  v3 = load.{} v1 align 0\n  v4 = load.{} v2 align 0\n  v5 = vunzip.{} v3, v4\n  v6 = vunzip.odd.{} v3, v4\n  store v5, v0 align 0\n  store v6, v0+{} align 0\n  ret\n",
            k,
            k,
            names[k],
            names[k],
            names[k],
            names[k],
            nl[k] * eb[k],
        );
        drv.format_into("void u{}(void *, const void *, const void *);\n", k);
        body.format_into(
            "  {{\n    {} a[64], b[64], o[128];\n    for (int i = 0; i < 64; i++) {{ a[i] = ({})(i * 37 - 100); b[i] = ({})(i * 53 + 7); }}\n    u{}(o, a, b);\n    for (int i = 0; i < {}; i++) for (int p = 0; p < 2; p++) if (memcmp(&o[p * {} + i], 2 * i + p < {} ? &a[2 * i + p] : &b[2 * i + p - {}], sizeof o[i]) != 0) r = {};\n  }}\n",
            cty[k],
            cty[k],
            cty[k],
            k,
            nl[k],
            nl[k],
            nl[k],
            nl[k],
            k + 1,
        );
    }
    body.push_str("  return r;\n}\n");
    drv.push_str(&body);
    let mut obj = Vector::<u8>::new();
    let x64 = tgt::axis_index("x86_64", true);
    assert(object_of(&lir, tgt::axis_index("linux", false), x64, 0, &mut obj), "the System V object");
    assert(object_of(&lir, tgt::axis_index("windows", false), x64, 0, &mut obj), "the Microsoft x64 object");
    assert(object_of(&lir, tgt::axis_index("linux", false), x64, WIDE, &mut obj), "the AVX2 object");
    assert(object_of(&lir, tgt::axis_index("windows", false), x64, WIDE, &mut obj), "the Microsoft x64 AVX2 object");
    assert(object_of(&lir, tgt::axis_index("linux", false), x64, Z512, &mut obj), "the AVX-512 object");
    assert(object_of(&lir, tgt::axis_index("windows", false), x64, Z512, &mut obj), "the Microsoft x64 AVX-512 object");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    assert_eq(run_native(&lir, &drv), 0);
    assert_eq(run_wide(&lir, &drv), 0);
    assert_eq(run_zmm(&lir, &drv), 0);
    assert_eq(run_wasm(&lir, &drv), 0);
}

// 16-byte vectors passed and returned in vector registers stay there (arm64, System V; Microsoft x64
// passes them by reference into registers and returns them through memory): a sum straight into the
// result's register, a vector passed to a call from its register, a parameter a loop reads from its home
// and one that crosses a call.
@test
fn vectors_pass_and_return_in_registers() {
    let lir = M"(lir ptr 8
sym @vadd fn global noinline
sym @vchain fn global
sym @vscale fn global
fn @vadd
  sig (v4f32, v4f32) -> v4f32
b0(v0: v4f32, v1: v4f32):
  v2 = fadd.v4f32 v0, v1
  ret v2
fn @vchain
  sig (v4f32, v4f32, v4f32) -> v4f32
b0(v0: v4f32, v1: v4f32, v2: v4f32):
  v3 = fmul.v4f32 v0, v1
  v4 = call.v4f32 @vadd(v3, v2) : (v4f32, v4f32) -> v4f32
  v5 = fmul.v4f32 v4, v0
  ret v5
fn @vscale
  sig (v4f32, ptr, i64) -> v4f32
b0(v0: v4f32, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = wconst.v4f32 0x0, 0x0
  jmp b1(v3, v5)
b1(v6: i64, v7: v4f32):
  v8 = icmp.ult v6, v2
  br v8, b2, b3
b2:
  v9 = ptradd v1, v6 * 16
  v10 = load.v4f32 v9 align 2
  v11 = fmul.v4f32 v10, v0
  v12 = fadd.v4f32 v7, v11
  v13 = add.i64 v6, v4
  jmp b1(v13, v12)
b3:
  v14 = call.v4f32 @vadd(v7, v0) : (v4f32, v4f32) -> v4f32
  ret v14
)";
    let drv = M"(#include <stdint.h>
typedef float f4 __attribute__((vector_size(16)));
f4 vadd(f4, f4);
f4 vchain(f4, f4, f4);
f4 vscale(f4, const f4 *, int64_t);
int main(void) {
  f4 a = {1, 2, 3, 4}, b = {5, -6, 7, 0.5f}, c = {0.25f, 8, -1, 3};
  f4 s = vadd(a, b), h = vchain(a, b, c);
  f4 xs[3] = {{1, 1, 1, 1}, {2, 0, -2, 4}, {0.5f, 3, 1, -1}};
  f4 k = vscale(b, xs, 3);
  for (int i = 0; i < 4; i++) {
    if (s[i] != a[i] + b[i]) return 1 + i;
    if (h[i] != (a[i] * b[i] + c[i]) * a[i]) return 5 + i;
    if (k[i] != ((xs[0][i] * b[i] + xs[1][i] * b[i]) + xs[2][i] * b[i]) + b[i]) return 9 + i;
  }
  return 0;
}
)";
    let mut obj = Vector::<u8>::new();
    let x64 = tgt::axis_index("x86_64", true);
    assert(object_of(lir, tgt::axis_index("linux", false), x64, 0, &mut obj), "the System V object");
    assert(object_of(lir, tgt::axis_index("windows", false), x64, 0, &mut obj), "the Microsoft x64 object");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    assert_eq(run_native(lir, drv), 0);
}

// The halves of a 16-byte vector in registers (arm64: the low one its register's D view, copied when the
// vector lives on; the high one by `ext`), and lane 0 of a float vector as its register's scalar view: a
// float tree sum of four lanes, as `reduce_add_tree` gives it.
@test
fn vector_halves_and_low_lanes_run() {
    let lir = M"(lir ptr 8
sym @halves fn global
fn @halves
  sig (ptr, ptr) -> f32
b0(v0: ptr, v1: ptr):
  v2 = load.v4f32 v0 align 2
  v3 = vop.low_half.v2f32 (v2)
  v4 = vop.high_half.v2f32 (v2)
  v5 = fadd.v2f32 v3, v4
  store v5, v1 align 2
  v6 = load.v4i32 v0+16 align 2
  v7 = vop.high_half.v2i32 (v6)
  store v7, v1+8 align 2
  v8 = vop.low_half.v2i32 (v6)
  store v8, v1+16 align 2
  v9 = vextract.0.f32 v5
  v10 = vextract.1.f32 v5
  v11 = fadd.f32 v9, v10
  ret v11
)";
    let drv = M"(#include <stdint.h>
#include <string.h>
float halves(const void *, void *);
int main(void) {
  float f[4] = {1.5f, -20, 300.25f, 4000};
  int32_t w[4] = {7, -8, 9, -10};
  unsigned char in[32], o[24];
  memcpy(in, f, 16);
  memcpy(in + 16, w, 16);
  float r = halves(in, o);
  float s[2]; int32_t h[2], l[2];
  memcpy(s, o, 8); memcpy(h, o + 8, 8); memcpy(l, o + 16, 8);
  if (s[0] != f[0] + f[2] || s[1] != f[1] + f[3]) return 1;
  if (h[0] != w[2] || h[1] != w[3] || l[0] != w[0] || l[1] != w[1]) return 2;
  if (r != (f[0] + f[2]) + (f[1] + f[3])) return 3;
  return 0;
}
)";
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(lir, tgt::axis_index("linux", false), tgt::axis_index("x86_64", true), 0, &mut obj),
        "the x86-64 object",
    );
    if !cli::has_cc() {
        return; // a C driver links it
    }
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// The address a reference takes is never null (`PTR_NONNULL`): a switch on `Vector::last`, a `None` test of
// an `Option` of a reference, tests the length, and the `Some` side reads the element through no select.
@test
fn a_switch_on_an_optional_reference_tests_the_length() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "@noinline\nfn last(v: &Vector<u32>) u32 {\n    return switch v.last() { Some(x) => *x, None => 0 };\n}\n\nfn main() i32 {\n    let v = Vector::<u32>::new();\n    return last(&v) as i32;\n}\n",
    );
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "last", "build -O2 main.spc -o app");
    let ok = r.ok() && r.out_has("fn @") && !r.out_has("select");
    if !ok {
        r.show();
    }
    assert(ok, "no select");
}

// A loop that reads `s[n - 1 - k]` with its check hoisted vectorizes: each vector loads the elements below
// and reverses its lanes (a `swizzle`; arm64 `rev64` and `ext`, x86-64 `pshufd`), for lanes of 1 to 8 bytes,
// with each element in its place.
@test
fn reversed_accesses_vectorize() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(@noinline
fn rev8(d: []mut u8, s: []u8) { let n = d.len(); for k in 0..n { d[k] = s[n - 1 - k]; } }
@noinline
fn rev16(d: []mut u16, s: []u16) { let n = d.len(); for k in 0..n { d[k] = s[n - 1 - k]; } }
@noinline
fn rev32(d: []mut u32, s: []u32) { let n = d.len(); for k in 0..n { d[k] = s[n - 1 - k]; } }
@noinline
fn rev64(d: []mut u64, s: []u64) { let n = d.len(); for k in 0..n { d[k] = s[n - 1 - k] + 1; } }

fn main() i32 {
    let mut a = Vector::<u8>::new();
    let mut b = Vector::<u8>::new();
    let mut c = Vector::<u16>::new();
    let mut e = Vector::<u16>::new();
    let mut f = Vector::<u32>::new();
    let mut g = Vector::<u32>::new();
    let mut h = Vector::<u64>::new();
    let mut q = Vector::<u64>::new();
    for k in 0..67usize {
        a.push((k * 3 + 1) as u8);
        c.push((k * 5 + 2) as u16);
        f.push((k * 7 + 3) as u32);
        h.push((k * 11 + 4) as u64);
        b.push(0);
        e.push(0);
        g.push(0);
        q.push(0);
    }
    rev8(b.as_mut_slice(), a.as_slice());
    rev16(e.as_mut_slice(), c.as_slice());
    rev32(g.as_mut_slice(), f.as_slice());
    rev64(q.as_mut_slice(), h.as_slice());
    for k in 0..67usize {
        if b[k] != a[66 - k] || e[k] != c[66 - k] || g[k] != f[66 - k] || q[k] != h[66 - k] + 1 {
            return 1;
        }
    }
    return 0;
}
)",
    );
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "rev32", "build --profile=release main.spc -o app");
    let ok = r.ok() && r.out_has("swizzle");
    if !ok {
        r.show();
    }
    assert(ok, "a swizzle");
    let mut cmd = format("\"{}/app\"", p.dir());
    assert_eq(cli::run_with(cmd.cstr(), null, null, null, ""), 0);
}

// On an arm64 host, `reduce_add_tree` of an `f32x4` (its Neon entry's `vget_low_f32` and `vget_lane_f32`)
// lowers to a vector's low half and lane reads at constant indexes (`intrin::lane_read`), through no slot.
@test
fn neon_low_halves_and_lane_reads_lower_to_vector_operations() {
    if tgt::host_isa() != tgt::axis_index("aarch64", true) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import std::simd;\n@noinline\nfn tree(v: f32x4) f32 {\n    return simd::reduce_add_tree(v);\n}\n\nfn main() i32 {\n    return tree(f32x4::splat(2.5)) as i32 - 10;\n}\n",
    );
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "tree", "build -O2 main.spc -o app");
    let ok = r.ok() && r.out_has("vop.low_half.v2f32") && r.out_has("vextract.1.f32") && !r.out_has("slotaddr");
    if !ok {
        r.show();
    }
    assert(ok, "a low half and lane reads");
}

// A splat of a lane of a vector in a register broadcasts the lane in place (`lv::FOLD_LANE`; arm64 `dup v,
// v[k]`, x86-64 `pshufd`): 4- and 8-byte lanes, integer and float, of 8- and 16-byte vectors, every index;
// a float product by one multiplies by the lane (arm64 `fmul v, v, v[k]`, `lv::FOLD_LANE_MUL`).
@test
fn splats_of_lanes_run() {
    let lir = M"(lir ptr 8
sym @lsplat fn global
fn @lsplat
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = load.v4f32 v0 align 2
  v3 = vextract.0.f32 v2
  v4 = splat.v4f32 v3
  v5 = vextract.3.f32 v2
  v6 = splat.v4f32 v5
  v7 = fmul.v4f32 v4, v2
  v8 = fadd.v4f32 v7, v6
  store v8, v1 align 2
  v9 = load.v2f64 v0+16 align 3
  v10 = vextract.1.f64 v9
  v11 = splat.v2f64 v10
  store v11, v1+16 align 3
  v12 = load.v4i32 v0 align 2
  v13 = vextract.2.i32 v12
  v14 = splat.v4i32 v13
  v15 = add.v4i32 v14, v12
  store v15, v1+32 align 2
  v16 = load.v2i64 v0 align 3
  v17 = vextract.1.i64 v16
  v18 = splat.v2i64 v17
  v19 = vextract.0.i64 v16
  v20 = splat.v2i64 v19
  v21 = xor.v2i64 v18, v20
  store v21, v1+48 align 3
  v22 = load.v2f32 v0 align 2
  v23 = vextract.1.f32 v22
  v24 = splat.v2f32 v23
  store v24, v1+64 align 2
  v25 = vextract.1.f32 v2
  v26 = splat.v2f32 v25
  store v26, v1+72 align 2
  v27 = vextract.2.f32 v2
  v28 = splat.v4f32 v27
  v29 = fmul.v4f32 v2, v28
  store v29, v1+80 align 2
  v30 = vextract.1.f64 v9
  v31 = splat.v2f64 v30
  v32 = fmul.v2f64 v9, v31
  store v32, v1+96 align 3
  v33 = vextract.1.f32 v22
  v34 = splat.v2f32 v33
  v35 = fmul.v2f32 v22, v34
  store v35, v1+112 align 2
  ret
)";
    let drv = M"(#include <stdint.h>
#include <string.h>
void lsplat(const void *, void *);
int main(void) {
  float f[8] = {1.5f, -2, 3.25f, 8, 0, 0, 0, 0};
  double d[2];
  unsigned char in[32], o[120];
  memcpy(in, f, 16);
  d[0] = 7.5; d[1] = -0.125;
  memcpy(in + 16, d, 16);
  lsplat(in, o);
  float r[4], s[2], u[2], m[4], t[2]; double e[2], g[2]; int32_t w[4], iw[4]; int64_t q[2], iq[2];
  memcpy(m, o + 80, 16); memcpy(g, o + 96, 16); memcpy(t, o + 112, 8);
  memcpy(r, o, 16); memcpy(e, o + 16, 16); memcpy(w, o + 32, 16); memcpy(q, o + 48, 16);
  memcpy(s, o + 64, 8); memcpy(u, o + 72, 8); memcpy(iw, in, 16); memcpy(iq, in, 16);
  for (int i = 0; i < 4; i++) {
    if (r[i] != f[0] * f[i] + f[3]) return 1 + i;
    if (w[i] != (int32_t)((uint32_t)iw[2] + (uint32_t)iw[i])) return 5 + i;
    if (m[i] != f[i] * f[2]) return 15 + i;
  }
  for (int i = 0; i < 2; i++) {
    if (e[i] != d[1]) return 9 + i;
    if (q[i] != (iq[0] ^ iq[1])) return 11 + i;
    if (s[i] != f[1] || u[i] != f[1]) return 13 + i;
    if (g[i] != d[i] * d[1] || t[i] != f[i] * f[1]) return 19 + i;
  }
  return 0;
}
)";
    let mut obj = Vector::<u8>::new();
    let x64 = tgt::axis_index("x86_64", true);
    assert(object_of(lir, tgt::axis_index("linux", false), x64, 0, &mut obj), "the x86-64 object");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// 32- and 64-byte vectors passed to and returned from calls, in a body that holds them in registers: with
// AVX2 and 32-byte vector registers (`vec 32`) in ymm registers, with AVX-512 and 64-byte ones (`vec 64`)
// in zmm registers, which no `vzeroupper` before the call or the return clears; a sibling call too.
@test
fn wide_vectors_cross_calls() {
    let lir = M"(lir ptr 8
sym @twice fn global noinline
sym @again fn global noinline
sym @wide fn global
fn @twice
  sig (v8i32) -> v8i32
b0(v0: v8i32):
  v1 = add.v8i32 v0, v0
  ret v1
fn @again
  sig (v8i32) -> v8i32
b0(v0: v8i32):
  v1 = sub.v8i32 v0, v0
  v2 = add.v8i32 v1, v0
  v3 = call.v8i32 @twice(v2) : (v8i32) -> v8i32
  ret v3
fn @wide
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = load.v8i32 v1 align 0
  v3 = add.v8i32 v2, v2
  v4 = call.v8i32 @twice(v3) : (v8i32) -> v8i32
  v5 = call.v8i32 @again(v4) : (v8i32) -> v8i32
  v6 = add.v8i32 v5, v2
  store v6, v0 align 0
  ret
)";
    let drv = M"(#include <stdint.h>
void wide(int32_t *, const int32_t *);
int main(void) {
  int32_t a[8], o[8];
  for (int i = 0; i < 8; i++) a[i] = i * 1000 - 3000;
  wide(o, a);
  for (int i = 0; i < 8; i++) if (o[i] != a[i] * 9) return i + 1;
  return 0;
}
)";
    let ymm = format("lir ptr 8 vec 32\n{}", lir.slice(10, lir.len()));
    let mut obj = Vector::<u8>::new();
    let x64 = tgt::axis_index("x86_64", true);
    assert(object_of(&ymm, tgt::axis_index("linux", false), x64, WIDE | TAIL, &mut obj), "the AVX2 object");
    assert(
        object_of(&ymm, tgt::axis_index("windows", false), x64, WIDE | TAIL, &mut obj),
        "the Microsoft x64 AVX2 object",
    );
    if !cli::has_cc() {
        return; // a C driver links it
    }
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_native_with(lir, drv, TAIL), 0);
    assert_eq(run_wide(&ymm, drv), 0);
    // The same with 16 lanes.
    let zlir = String::from_str(lir).replace("v8i32", "v16i32");
    let zmm = format("lir ptr 8 vec 64\n{}", zlir.as_str().slice(10, zlir.len()));
    let zdrv = String::from_str(drv).replace("[8]", "[16]").replace("i < 8", "i < 16");
    assert(object_of(&zmm, tgt::axis_index("linux", false), x64, Z512 | TAIL, &mut obj), "the AVX-512 object");
    assert(
        object_of(&zmm, tgt::axis_index("windows", false), x64, Z512 | TAIL, &mut obj),
        "the Microsoft x64 AVX-512 object",
    );
    assert_eq(run_native(&zlir, &zdrv), 0);
    assert_eq(run_zmm(&zmm, &zdrv), 0);
}

// Lane-wise arithmetic of 16-, 32- and 64-byte vectors of every lane type, splats and vector constants
// (zero, all ones, one word repeated, several words): each result's bits against C's, integers wrapping.
// With 32-byte vectors in ymm registers too (`run_wide`), and 64-byte ones in zmm registers (`run_zmm`).
@test
fn vector_arithmetic_of_every_width_runs() {
    let names: []str = [
        "v16i8",
        "v8i16",
        "v4i32",
        "v2i64",
        "v4f32",
        "v2f64",
        "v32i8",
        "v16i16",
        "v8i32",
        "v4i64",
        "v8f32",
        "v4f64",
        "v64i8",
        "v32i16",
        "v16i32",
        "v8i64",
        "v16f32",
        "v8f64",
    ];
    let lty: []str = [
        "i8",
        "i16",
        "i32",
        "i64",
        "f32",
        "f64",
        "i8",
        "i16",
        "i32",
        "i64",
        "f32",
        "f64",
        "i8",
        "i16",
        "i32",
        "i64",
        "f32",
        "f64",
    ];
    let cty: []str = [
        "uint8_t",
        "uint16_t",
        "uint32_t",
        "uint64_t",
        "float",
        "double",
        "uint8_t",
        "uint16_t",
        "uint32_t",
        "uint64_t",
        "float",
        "double",
        "uint8_t",
        "uint16_t",
        "uint32_t",
        "uint64_t",
        "float",
        "double",
    ];
    let nl: []u32 = [16, 8, 4, 2, 4, 2, 32, 16, 8, 4, 8, 4, 64, 32, 16, 8, 16, 8];
    let iops: []str = ["add", "sub", "mul", "and", "or", "xor", "neg", "not"];
    let icx: []str = [
        "a[i] + b[i]",
        "a[i] - b[i]",
        "a[i] * b[i]",
        "a[i] & b[i]",
        "a[i] | b[i]",
        "a[i] ^ b[i]",
        "0 - a[i]",
        "~a[i]",
    ];
    let fops: []str = ["fadd", "fsub", "fmul", "fdiv", "fneg"];
    let fcx: []str = ["a[i] + b[i]", "a[i] - b[i]", "a[i] * b[i]", "a[i] / b[i]", "-a[i]"];
    let mut lir = String::from_str("lir ptr 8\n");
    let mut drv = String::from_str("#include <stdint.h>\n#include <string.h>\n");
    let mut body = String::from_str("int main(void) {\n  int r = 0;\n");
    let mut nf: u32 = 0;
    for k in 0..names.len() {
        let fl = lty[k] == "f32" || lty[k] == "f64";
        body.format_into(
            "  {{\n    {} a[64], b[64], o[64], e[64];\n    for (int i = 0; i < 64; i++) {{ a[i] = ({})(i * 37 - 100); b[i] = ({})(i * 53 + 7); }}\n",
            cty[k],
            cty[k],
            cty[k],
        );
        let n = if fl {
            fops.len()
        } else {
            iops.len()
        };
        for o in 0..n {
            let (op, cx) = if fl {
                (fops[o], fcx[o])
            } else {
                (iops[o], icx[o])
            };
            let un = op == "neg" || op == "not" || op == "fneg";
            lir.format_into(
                "sym @a{} fn global\nfn @a{}\n  sig (ptr, ptr, ptr) -> void\nb0(v0: ptr, v1: ptr, v2: ptr):\n  v3 = load.{} v1 align 0\n  v4 = load.{} v2 align 0\n",
                nf,
                nf,
                names[k],
                names[k],
            );
            if un {
                lir.format_into("  v5 = {}.{} v3\n", op, names[k]);
            } else {
                lir.format_into("  v5 = {}.{} v3, v4\n", op, names[k]);
            }
            lir.push_str("  store v5, v0 align 0\n  ret\n");
            drv.format_into("void a{}(void *, const void *, const void *);\n", nf);
            body.format_into(
                "    a{}(o, a, b); for (int i = 0; i < {}; i++) {{ e[i] = ({})({}); if (memcmp(&o[i], &e[i], sizeof o[i]) != 0) r = {}; }}\n",
                nf,
                nl[k],
                cty[k],
                cx,
                nf + 1,
            );
            nf += 1;
        }
        // A splat of the scalar argument.
        lir.format_into(
            "sym @p{} fn global\nfn @p{}\n  sig (ptr, {}) -> void\nb0(v0: ptr, v1: {}):\n  v2 = splat.{} v1\n  store v2, v0 align 0\n  ret\n",
            k,
            k,
            lty[k],
            lty[k],
            names[k],
        );
        drv.format_into("void p{}(void *, {});\n", k, cty[k]);
        body.format_into(
            "    p{}(o, a[5]); for (int i = 0; i < {}; i++) if (memcmp(&o[i], &a[5], sizeof o[i]) != 0) r = {};\n  }}\n",
            k,
            nl[k],
            500 + k,
        );
    }
    // Vector constants: zero, all ones, one word repeated, four words (eight for 64 bytes: the four twice).
    let words: []str = [
        "0x0, 0x0, 0x0, 0x0",
        "0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff",
        "0x123456789abcdef0, 0x123456789abcdef0, 0x123456789abcdef0, 0x123456789abcdef0",
        "0x1, 0x8000000000000000, 0x7f7f7f7f7f7f7f7f, 0xfedcba9876543210",
    ];
    let cwords: []str = [
        "0, 0, 0, 0",
        "~0ull, ~0ull, ~0ull, ~0ull",
        "0x123456789ABCDEF0ull, 0x123456789ABCDEF0ull, 0x123456789ABCDEF0ull, 0x123456789ABCDEF0ull",
        "1, 0x8000000000000000ull, 0x7F7F7F7F7F7F7F7Full, 0xFEDCBA9876543210ull",
    ];
    for c in 0..words.len() {
        for wide in 0..3usize {
            let (ty, nw, w) = if wide == 2 {
                ("v16i32", 8u32, format("{}, {}", words[c], words[c]))
            } else if wide == 1 {
                ("v8i32", 4u32, String::from_str(words[c]))
            } else {
                // The first two words of the four.
                let s = words[c];
                let cut = s.find(", ");
                let rest = s.slice(cut as usize + 2, s.len());
                let cut2 = rest.find(", ");
                ("v4i32", 2u32, String::from_str(s.slice(0, cut as usize + 2 + cut2 as usize)))
            };
            lir.format_into(
                "sym @w{} fn global\nfn @w{}\n  sig (ptr) -> void\nb0(v0: ptr):\n  v1 = wconst.{} {}\n  store v1, v0 align 0\n  ret\n",
                3 * c + wide,
                3 * c + wide,
                ty,
                w.as_str(),
            );
            drv.format_into("void w{}(void *);\n", 3 * c + wide);
            body.format_into(
                "  {{ uint64_t e[8] = {{{}, {}}}, o[8]; w{}(o); if (memcmp(o, e, {}) != 0) r = {}; }}\n",
                cwords[c],
                cwords[c],
                3 * c + wide,
                8 * nw,
                700 + 3 * c + wide,
            );
        }
    }
    body.push_str("  return r;\n}\n");
    drv.push_str(&body);
    let mut obj = Vector::<u8>::new();
    let x64 = tgt::axis_index("x86_64", true);
    let lin = tgt::axis_index("linux", false);
    let win = tgt::axis_index("windows", false);
    assert(object_of(&lir, lin, x64, 0, &mut obj), "the System V object");
    assert(object_of(&lir, win, x64, 0, &mut obj), "the Microsoft x64 object");
    assert(object_of(&lir, lin, x64, WIDE, &mut obj), "the AVX2 object");
    assert(object_of(&lir, win, x64, WIDE, &mut obj), "the Microsoft x64 AVX2 object");
    assert(object_of(&lir, lin, x64, Z512, &mut obj), "the AVX-512 object");
    assert(object_of(&lir, win, x64, Z512, &mut obj), "the Microsoft x64 AVX-512 object");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    assert_eq(run_native(&lir, &drv), 0);
    assert_eq(run_wide(&lir, &drv), 0);
    assert_eq(run_zmm(&lir, &drv), 0);
    assert_eq(run_wasm(&lir, &drv), 0);
}

// A frame of exactly 4 KiB (the slot and two spills): the stack pointer moves by all of it.
@test
fn a_page_sized_frame_runs() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @id fn global\nsym @g fn global\nfn @g\n  sig (i64) -> i64\n  slot s0 size 4080 align 3\nb0(v0: i64):\n  v1 = slotaddr s0\n  v2 = ptradd v1+8\n  store v0, v1 align 3\n  store v0, v2 align 3\n  v3 = call.i64 @id(v0) : (i64) -> i64\n  v4 = load.i64 v2 align 3\n  v5 = add.i64 v3, v4\n  ret v5\n";
    let drv = "#include <stdint.h>\nint64_t g(int64_t);\nint64_t id(int64_t x) { return x; }\nint main(void) { return g(21) == 42 ? 0 : 1; }\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Float constants that fit the 8-bit immediate of `fmov`.
@test
fn float_immediates_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @kd fn global\nsym @kf fn global\nfn @kd\n  sig () -> f64\nb0:\n  v0 = fconst.f64 0x3ff0000000000000\n  v1 = fconst.f64 0x4000000000000000\n  v2 = fconst.f64 0xc028000000000000\n  v3 = fconst.f64 0x3fc0000000000000\n  v4 = fadd.f64 v0, v1\n  v5 = fadd.f64 v4, v2\n  v6 = fadd.f64 v5, v3\n  ret v6\nfn @kf\n  sig () -> f32\nb0:\n  v0 = fconst.f32 0x3f800000\n  v1 = fconst.f32 0x40000000\n  v2 = fconst.f32 0x3f000000\n  v3 = fconst.f32 0xc1f80000\n  v4 = fadd.f32 v0, v1\n  v5 = fadd.f32 v4, v2\n  v6 = fadd.f32 v5, v3\n  ret v6\n";
    let drv = "double kd(void);\nfloat kf(void);\nint main(void) { return kd() == -8.875 && kf() == -27.5f ? 0 : 1; }\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A loop's values stay live through a cold block that branches back into the loop, though the layout puts
// the cold block last: the call's result there takes no home of the counter's.
@test
fn a_cold_block_inside_a_loop_keeps_the_loop_values() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @poll fn global
sym @count fn global
fn @count
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 1
  v3 = iconst.i32 3
  jmp b1(v1, v1)
b1(v4: i32, v5: i32):
  v6 = icmp.ult v4, v0
  br v6, b2, b5
b2:
  v7 = urem.i32 v4, v3
  v8 = icmp.eq v7, v1
  br v8, b3, b4(v5)
b3: cold
  v9 = call.i32 @poll() : () -> i32
  v10 = add.i32 v5, v9
  jmp b4(v10)
b4(v11: i32):
  v12 = add.i32 v4, v2
  v13 = add.i32 v11, v4
  jmp b1(v12, v13)
b5:
  ret v5
)";
    let drv = "int count(int);\nint poll(void) { return 100; }\nint main(void) { return count(10) == 445 ? 0 : 1; }\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// binary16 conversions (`htof`, `ftoh`) and arithmetic (an `fadd`, `fsub`, `fmul` or `fdiv` between them,
// in binary16 on macOS arm64) against the C compiler's `_Float16`: every encoding widened, every finite
// one's value, its midpoints to its neighbours and the floats next to those rounded, and pseudo-random pairs
// combined, NaNs alike as NaNs. A C compiler without `_Float16`, or an x86-64 processor without F16C, runs
// nothing. The x86-64 objects build on every host.
@test
fn binary16_conversions_and_arithmetic_run() {
    let lir = M"(lir ptr 8
sym @h2f fn global
sym @f2h fn global
sym @hop fn global
fn @h2f
  sig (i16) -> f32
b0(v0: i16):
  v1 = htof.f32 v0
  ret v1
fn @f2h
  sig (f32) -> i16
b0(v0: f32):
  v1 = ftoh.i16 v0
  ret v1
fn @hop
  sig (i16, i16, i32) -> i16
b0(v0: i16, v1: i16, v2: i32):
  v3 = htof.f32 v0
  v4 = htof.f32 v1
  v5 = fadd.f32 v3, v4
  v6 = ftoh.i16 v5
  v7 = fsub.f32 v3, v4
  v8 = ftoh.i16 v7
  v9 = fmul.f32 v3, v4
  v10 = ftoh.i16 v9
  v11 = fdiv.f32 v3, v4
  v12 = ftoh.i16 v11
  v13 = iconst.i32 1
  v14 = iconst.i32 2
  v15 = iconst.i32 3
  v16 = icmp.eq v2, v13
  v17 = icmp.eq v2, v14
  v18 = icmp.eq v2, v15
  v19 = select.i16 v16, v8, v6
  v20 = select.i16 v17, v10, v19
  v21 = select.i16 v18, v12, v20
  ret v21
)";
    let drv = M"(#include <stdint.h>
#include <string.h>
#include <stdio.h>
float h2f(uint16_t);
uint16_t f2h(float);
uint16_t hop(uint16_t, uint16_t, int32_t);
#ifdef __FLT16_MANT_DIG__
static uint32_t fbits(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float hval(uint16_t h) { _Float16 v; memcpy(&v, &h, 2); return (float)v; }
static uint16_t hround(float f) { _Float16 v = (_Float16)f; uint16_t h; memcpy(&h, &v, 2); return h; }
static int hnan(uint16_t h) { return (h & 0x7FFF) > 0x7C00; }
static int same(uint16_t got, uint16_t want) { return got == want || hnan(got) && hnan(want); }
static float fnext(float f, int up) { uint32_t u = fbits(f); u = up ? u + 1 : u - 1; memcpy(&f, &u, 4); return f; }
#endif
int main(void) {
#ifndef __FLT16_MANT_DIG__
  return 0;
#else
#if defined(__x86_64__)
  if (!__builtin_cpu_supports("f16c")) return 0;
#endif
  for (uint32_t h = 0; h < 65536; h++) {
    float want = hval((uint16_t)h), got = h2f((uint16_t)h);
    if (want != want ? got == got : fbits(got) != fbits(want)) { printf("h2f %x\n", h); return 1; }
    if ((h & 0x7C00) == 0x7C00) continue;
    float lo = want, hi = hval((uint16_t)(h + 1));
    if ((h & 0x7FFF) == 0x7BFF) hi = 65536.0f;
    float mid = (lo + hi) / 2;
    float probes[5] = {lo, mid, fnext(mid, 0), fnext(mid, 1), (lo + mid) / 2};
    for (int k = 0; k < 5; k++) {
      if (!same(f2h(probes[k]), hround(probes[k]))) { printf("f2h %x %d\n", h, k); return 2; }
    }
  }
  uint32_t s = 12345;
  for (int n = 0; n < 200000; n++) {
    s = s * 1103515245u + 12345u;
    uint16_t a = (uint16_t)(s >> 8);
    s = s * 1103515245u + 12345u;
    uint16_t b = (uint16_t)(s >> 8);
    float x = hval(a), y = hval(b);
    uint16_t want[4] = {hround(x + y), hround(x - y), hround(x * y), hround(x / y)};
    for (int k = 0; k < 4; k++) {
      if (!same(hop(a, b, k), want[k])) { printf("hop %x %x %d\n", a, b, k); return 3; }
    }
  }
  return 0;
#endif
}
)";
    let x64 = tgt::axis_index("x86_64", true);
    let mut obj = Vector::<u8>::new();
    assert(object_of(lir, tgt::axis_index("linux", false), x64, HALF, &mut obj), "the System V object");
    assert(object_of(lir, tgt::axis_index("windows", false), x64, HALF, &mut obj), "the Microsoft x64 object");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    assert_eq(run_native_with(lir, drv, HALF), 0);
}

// Branches on a value against zero (`cbz` on arm64) at every width, on one bit (`tbz`), and on the result of
// a subtraction (its flags on x86-64); an index scaled by 16; and a loop of eight values in registers
// across a call in a cold block (`@mix` takes every temporary register), which saves them around it.
@test
fn zero_tests_scales_and_cold_calls_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @z8 fn global
sym @z16 fn global
sym @z64 fn global
sym @bit fn global
sym @steps fn global
sym @at16 fn global
sym @mix fn global
sym @sums fn global
fn @z8
  sig (i8) -> i32
b0(v0: i8):
  v1 = iconst.i8 0
  v2 = iconst.i32 1
  v3 = iconst.i32 2
  v4 = icmp.ne v0, v1
  br v4, b1, b2
b1:
  ret v2
b2:
  ret v3
fn @z16
  sig (i16) -> i32
b0(v0: i16):
  v1 = iconst.i16 0
  v2 = iconst.i32 1
  v3 = iconst.i32 2
  v4 = icmp.eq v0, v1
  br v4, b1, b2
b1:
  ret v2
b2:
  ret v3
fn @z64
  sig (i64) -> i32
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i32 1
  v3 = iconst.i32 2
  v4 = icmp.eq v0, v1
  br v4, b1, b2
b1:
  ret v2
b2:
  ret v3
fn @bit
  sig (i64) -> i32
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 -9223372036854775808
  v3 = iconst.i64 16
  v4 = iconst.i32 1
  v5 = iconst.i32 2
  v6 = iconst.i32 4
  v7 = and.i64 v0, v2
  v8 = icmp.ne v7, v1
  br v8, b1, b2
b1:
  ret v4
b2:
  v9 = and.i64 v0, v3
  v10 = icmp.eq v9, v1
  br v10, b3, b4
b3:
  ret v5
b4:
  ret v6
fn @steps
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 1
  jmp b1(v0, v1)
b1(v3: i32, v4: i32):
  v5 = sub.i32 v3, v2
  v6 = add.i32 v4, v2
  v7 = icmp.eq v5, v1
  br v7, b2, b1(v5, v6)
b2:
  ret v6
fn @at16
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = ptradd v0, v1 * 16
  v3 = load.i64 v2+8 align 3
  ret v3
fn @mix
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 3
  v2 = mul.i64 v0, v1
  v3 = add.i64 v2, v1
  v4 = xor.i64 v3, v0
  v5 = mul.i64 v4, v3
  v6 = add.i64 v5, v2
  v7 = sub.i64 v6, v4
  v8 = mul.i64 v7, v6
  v9 = xor.i64 v8, v5
  v10 = add.i64 v9, v7
  v11 = mul.i64 v10, v2
  v12 = add.i64 v11, v3
  v13 = xor.i64 v12, v4
  v14 = add.i64 v13, v5
  v15 = add.i64 v14, v6
  v16 = add.i64 v15, v7
  v17 = add.i64 v16, v8
  v18 = add.i64 v17, v9
  v19 = add.i64 v18, v10
  v20 = add.i64 v19, v11
  v21 = iconst.i64 0
  v22 = and.i64 v20, v21
  ret v22
fn @sums
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = iconst.i64 7
  jmp b1(v1, v1, v1, v1, v1, v1, v1, v1)
b1(v4: i64, v5: i64, v6: i64, v7: i64, v8: i64, v9: i64, v10: i64, v11: i64):
  v12 = icmp.ult v4, v0
  br v12, b2, b5
b2:
  v13 = and.i64 v4, v3
  v14 = icmp.eq v13, v1
  br v14, b3, b4(v5)
b3: cold
  v15 = call.i64 @mix(v4) : (i64) -> i64
  v16 = add.i64 v5, v15
  jmp b4(v16)
b4(v17: i64):
  v18 = add.i64 v17, v4
  v19 = add.i64 v6, v18
  v20 = add.i64 v7, v19
  v21 = add.i64 v8, v20
  v22 = add.i64 v9, v21
  v23 = add.i64 v10, v22
  v24 = add.i64 v11, v23
  v25 = add.i64 v4, v2
  jmp b1(v25, v18, v19, v20, v21, v22, v23, v24)
b5:
  v26 = add.i64 v5, v6
  v27 = add.i64 v26, v7
  v28 = add.i64 v27, v8
  v29 = add.i64 v28, v9
  v30 = add.i64 v29, v10
  v31 = add.i64 v30, v11
  ret v31
)";
    let drv = M"(
#include <stdint.h>
int z8(int8_t);
int z16(int16_t);
int z64(int64_t);
int bit(int64_t);
int steps(int);
int64_t at16(int64_t *, int64_t);
int64_t sums(int64_t);
static int64_t model(int64_t n) {
    int64_t a[7] = {0};
    for (int64_t i = 0; i < n; i++) {
        int64_t s = a[0] + i;
        a[0] = s;
        for (int k = 1; k < 7; k++) {
            s = a[k] + s;
            a[k] = s;
        }
    }
    int64_t t = 0;
    for (int k = 0; k < 7; k++) {
        t += a[k];
    }
    return t;
}
int main(void) {
    int64_t t[6] = {1, 2, 3, 4, 5, 6};
    int ok = z8(0) == 2 && z8(-128) == 1 && z8(1) == 1 && z16(0) == 1 && z16(-32768) == 2 && z16(256) == 2;
    ok = ok && z64(0) == 1 && z64(INT64_MIN) == 2 && z64((int64_t)1 << 32) == 2;
    ok = ok && bit(INT64_MIN) == 1 && bit(16) == 4 && bit(15) == 2 && bit(0) == 2;
    ok = ok && steps(1) == 1 && steps(5) == 5 && at16(t, 0) == 2 && at16(t, 2) == 6;
    ok = ok && sums(0) == 0 && sums(1) == model(1) && sums(100) == model(100);
    return ok ? 0 : 1;
}
)";
    assert_eq(run_native(lir, drv), 0);
}

// The instructions that hold the most registers on x86-64 besides the homes, each with values that live
// past it in rax and rdx and a result a call later reads: an unsigned 64-bit division, checked product and
// high product, a narrow division and checked sum (their operands extended). They compile for x86-64 on
// every host (`end_inst` asserts each one's count against `need`) and run on the host.
@test
fn register_hungry_instructions_compile_and_run() {
    let lir = "lir ptr 8\nsym @id fn global\nsym @dv fn global\nsym @mo fn global\nsym @mh fn global\nsym @nr fn global\nfn @dv\n  sig (i64, i64, ptr) -> i64\nb0(v0: i64, v1: i64, v2: ptr):\n  v3 = load.i64 v2 align 3\n  v4 = udiv.i64 v0, v1\n  v5 = load.i64 v2+8 align 3\n  v6 = add.i64 v3, v5\n  v7 = call.i64 @id(v6) : (i64) -> i64\n  v8 = add.i64 v7, v4\n  ret v8\nfn @mo\n  sig (i64, i64, ptr) -> i64\nb0(v0: i64, v1: i64, v2: ptr):\n  v3 = load.i64 v2 align 3\n  v4, v5 = mulo.u.i64 v0, v1\n  v6 = zext.i64 v5\n  v7 = load.i64 v2+8 align 3\n  v8 = add.i64 v3, v7\n  v9 = call.i64 @id(v8) : (i64) -> i64\n  v10 = add.i64 v9, v4\n  v11 = add.i64 v10, v6\n  ret v11\nfn @mh\n  sig (i64, i64, ptr) -> i64\nb0(v0: i64, v1: i64, v2: ptr):\n  v3 = load.i64 v2 align 3\n  v4 = mulhu.i64 v0, v1\n  v5 = load.i64 v2+8 align 3\n  v6 = add.i64 v3, v5\n  v7 = call.i64 @id(v6) : (i64) -> i64\n  v8 = add.i64 v7, v4\n  ret v8\nfn @nr\n  sig (i64, i64, ptr) -> i64\nb0(v0: i64, v1: i64, v2: ptr):\n  v3 = load.i64 v2 align 3\n  v4 = trunc.i8 v0\n  v5 = trunc.i8 v1\n  v6 = sdiv.i8 v4, v5\n  v7, v8 = addo.s.i8 v4, v5\n  v9 = sext.i64 v6\n  v10 = sext.i64 v7\n  v11 = zext.i64 v8\n  v12 = load.i64 v2+8 align 3\n  v13 = add.i64 v3, v12\n  v14 = call.i64 @id(v13) : (i64) -> i64\n  v15 = add.i64 v14, v9\n  v16 = add.i64 v15, v10\n  v17 = add.i64 v16, v11\n  ret v17\n";
    let mut obj = Vector::<u8>::new();
    let x64 = tgt::axis_index("x86_64", true);
    assert(object_of(lir, tgt::axis_index("linux", false), x64, 0, &mut obj), "the System V object");
    assert(object_of(lir, tgt::axis_index("windows", false), x64, 0, &mut obj), "the Microsoft x64 object");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = "#include <stdint.h>\nint64_t id(int64_t x) { return x; }\nuint64_t dv(uint64_t, uint64_t, const int64_t *);\nuint64_t mo(uint64_t, uint64_t, const int64_t *);\nuint64_t mh(uint64_t, uint64_t, const int64_t *);\nint64_t nr(int64_t, int64_t, const int64_t *);\nstatic int64_t n(int8_t a, int8_t b) { int8_t s = (int8_t)(uint8_t)((uint8_t)a + (uint8_t)b); return 3 + a / b + s + (a + b != s); }\nint main(void) {\n  const int64_t m[2] = {1, 2};\n  unsigned __int128 p = (unsigned __int128)UINT64_MAX * 3;\n  if (dv(1000, 7, m) != 3 + 1000 / 7 || mh(UINT64_MAX, 3, m) != 3 + (uint64_t)(p >> 64)) return 1;\n  if (mo(UINT64_MAX, 3, m) != 3 + (uint64_t)p + 1 || mo(6, 7, m) != 3 + 42) return 2;\n  if (nr(100, 7, m) != n(100, 7) || nr(100, 60, m) != n(100, 60) || nr(-100, -60, m) != n(-100, -60)) return 3;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// A vector join that a store writes to memory: the join's parameter takes an xmm register home on x86-64,
// and the store writes that register, as it does an xmm-held vector of any other home. A loop's vector
// sum that a reduction after the loop reads lane by lane in memory: it takes no register of the loop's
// parameter as its home, but a slot. They compile for x86-64 on every host and run on the host.
@test
fn a_stored_vector_join_runs() {
    let lir = M"(lir ptr 8
sym @pick fn global
sym @vsum fn global
fn @pick
  sig (i8, ptr) -> void
b0(v0: i8, v1: ptr):
  br v0, b1, b2
b1:
  v2 = load.v4f32 v1 align 2
  jmp b3(v2)
b2:
  v3 = load.v4f32 v1+16 align 2
  jmp b3(v3)
b3(v4: v4f32):
  store v4, v1+32 align 2
  ret
fn @vsum
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = wconst.v2i64 0x0, 0x0
  v3 = iconst.i64 0
  v4 = iconst.i64 2
  jmp b1(v3, v2)
b1(v5: i64, v6: v2i64):
  v7 = ptradd v0, v5 * 8
  v8 = load.v2i64 v7 align 3
  v9 = add.v2i64 v6, v8
  v10 = add.i64 v5, v4
  v11 = icmp.ult v10, v1
  br v11, b1(v10, v9), b2
b2:
  v12 = vop.reduce_add.i64 (v9)
  ret v12
)";
    let mut obj = Vector::<u8>::new();
    let x64 = tgt::axis_index("x86_64", true);
    assert(object_of(lir, tgt::axis_index("linux", false), x64, 0, &mut obj), "the System V object");
    obj.truncate(0);
    assert(object_of(lir, tgt::axis_index("windows", false), x64, 0, &mut obj), "the Microsoft x64 object");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = "#include <stdint.h>\nvoid pick(signed char, float *);\nint64_t vsum(const int64_t *, int64_t);\nint main(void) {\n  float a[12] = {1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0};\n  pick(1, a);\n  if (a[8] != 1 || a[11] != 4) return 1;\n  pick(0, a);\n  if (a[8] != 5 || a[11] != 8) return 2;\n  const int64_t q[6] = {1, 2, 3, 4, 5, -6};\n  if (vsum(q, 6) != 9 || vsum(q, 2) != 3) return 3;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// Sibling calls (`Package.tail`): a call whose result its block returns at once jumps to its callee after
// the caller's epilogue, so mutual recursion ten million deep runs in a constant stack; through a pointer
// too, after a call that keeps a value in a callee-saved register, which the epilogue restores, and before
// a block that returns at the body's end, which keeps the epilogue. They compile for x86-64 on every host.
@test
fn sibling_calls_run_in_a_constant_stack() {
    let lir = M"(lir ptr 8
sym @g fn global noinline
sym @even fn global
sym @odd fn global
sym @apply fn global
sym @framed fn global
sym @pick fn global
fn @g
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = mul.i64 v0, v1
  ret v2
fn @even
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = icmp.eq v0, v1
  br v2, b1, b2
b1:
  v3 = iconst.i64 1
  ret v3
b2:
  v4 = iconst.i64 1
  v5 = sub.i64 v0, v4
  v6 = call.i64 @odd(v5) : (i64) -> i64
  ret v6
fn @odd
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = icmp.eq v0, v1
  br v2, b1, b2
b1:
  ret v1
b2:
  v3 = iconst.i64 1
  v4 = sub.i64 v0, v3
  v5 = call.i64 @even(v4) : (i64) -> i64
  ret v5
fn @apply
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = call.ind.i64 v0(v1) : (i64) -> i64
  ret v2
fn @framed
  sig (i64) -> i64
b0(v0: i64):
  v1 = call.i64 @g(v0, v0) : (i64, i64) -> i64
  v2 = add.i64 v1, v0
  v3 = call.i64 @g(v2, v1) : (i64, i64) -> i64
  ret v3
fn @pick
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 10
  v2 = icmp.sgt v0, v1
  br v2, b2, b1
b1:
  v3 = iconst.i64 2
  v4 = call.i64 @g(v0, v3) : (i64, i64) -> i64
  ret v4
b2:
  ret v0
)";
    let mut obj = Vector::<u8>::new();
    let x64 = tgt::axis_index("x86_64", true);
    assert(object_of(lir, tgt::axis_index("linux", false), x64, TAIL, &mut obj), "the System V object");
    assert(object_of(lir, tgt::axis_index("windows", false), x64, TAIL, &mut obj), "the Microsoft x64 object");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = M"(#include <stdint.h>
int64_t even(int64_t);
int64_t odd(int64_t);
int64_t apply(int64_t (*)(int64_t), int64_t);
int64_t framed(int64_t);
int64_t pick(int64_t);
static int64_t neg(int64_t x) { return -x; }
int main(void) {
  if (even(10000000) != 1 || odd(10000001) != 1 || even(7) != 0) return 1;
  if (apply(neg, 5) != -5) return 2;
  if (framed(3) != 108) return 3;
  if (pick(4) != 8 || pick(11) != 11) return 4;
  return 0;
}
)";
    assert_eq(run_native_with(lir, drv, TAIL), 0);
}

// Switches: dense ones (a jump table; from 0, of 8 and 64 bits, the value's register its index), a sparse
// one, a wide one whose value less the lowest case does not fit 32 bits, and one that drives a loop.
@test
fn switches_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @dense fn global
sym @sparse fn global
sym @wide fn global
sym @machine fn global
sym @from0 fn global
sym @byte0 fn global
fn @from0
  sig (i64) -> i32
b0(v0: i64):
  switch v0 [0 -> b1, 1 -> b2, 2 -> b3, 3 -> b1, 4 -> b4] else b5
b1:
  v1 = iconst.i32 10
  ret v1
b2:
  v2 = iconst.i32 20
  ret v2
b3:
  v3 = iconst.i32 30
  ret v3
b4:
  v4 = iconst.i32 40
  ret v4
b5:
  v5 = iconst.i32 -1
  ret v5
fn @byte0
  sig (i8) -> i32
b0(v0: i8):
  switch v0 [0 -> b1, 1 -> b2, 2 -> b3, 3 -> b4] else b5
b1:
  v1 = iconst.i32 1
  ret v1
b2:
  v2 = iconst.i32 2
  ret v2
b3:
  v3 = iconst.i32 3
  ret v3
b4:
  v4 = iconst.i32 4
  ret v4
b5:
  v5 = iconst.i32 -1
  ret v5
fn @dense
  sig (i32) -> i32
b0(v0: i32):
  switch v0 [2 -> b1, 3 -> b2, 4 -> b3, 5 -> b2, 7 -> b4(v0), 8 -> b1] else b5
b1:
  v1 = iconst.i32 10
  ret v1
b2:
  v2 = iconst.i32 20
  ret v2
b3:
  v3 = iconst.i32 30
  ret v3
b4(v4: i32):
  v5 = iconst.i32 100
  v6 = add.i32 v4, v5
  ret v6
b5:
  v7 = iconst.i32 -1
  ret v7
fn @sparse
  sig (i64) -> i32
b0(v0: i64):
  switch v0 [0 -> b1, 1000 -> b2, -5 -> b3, 1099511627776 -> b2] else b4
b1:
  v1 = iconst.i32 1
  ret v1
b2:
  v2 = iconst.i32 2
  ret v2
b3:
  v3 = iconst.i32 3
  ret v3
b4:
  v4 = iconst.i32 4
  ret v4
fn @wide
  sig (i64) -> i32
b0(v0: i64):
  switch v0 [10 -> b1, 11 -> b2, 12 -> b1, 13 -> b2, 15 -> b1] else b3
b1:
  v1 = iconst.i32 1
  ret v1
b2:
  v2 = iconst.i32 2
  ret v2
b3:
  v3 = iconst.i32 3
  ret v3
fn @machine
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 1
  v3 = iconst.i32 2
  v4 = iconst.i32 10
  v5 = iconst.i32 100
  jmp b1(v1, v0)
b1(v6: i32, v7: i32):
  switch v7 [0 -> b2(v6), 1 -> b3, 2 -> b4, 3 -> b5] else b6
b2(v8: i32):
  ret v8
b3:
  v9 = add.i32 v6, v2
  jmp b1(v9, v3)
b4:
  v10 = add.i32 v6, v4
  jmp b1(v10, v1)
b5:
  v11 = add.i32 v6, v5
  jmp b1(v11, v2)
b6:
  v12 = iconst.i32 -1
  ret v12
)";
    let drv = "#include <stdint.h>\nint dense(int);\nint sparse(int64_t);\nint wide(int64_t);\nint machine(int);\nint from0(int64_t);\nint byte0(uint8_t);\nint main(void) {\n  int f[6] = {10, 20, 30, 10, 40, -1};\n  for (int i = 0; i < 6; i++) if (from0(i) != f[i]) return 7;\n  if (from0(-1) != -1 || from0((int64_t)1 << 32) != -1) return 8;\n  for (int i = 0; i < 256; i++) if (byte0((uint8_t)i) != (i < 4 ? i + 1 : -1)) return 9;\n  int d[10] = {-1, -1, 10, 20, 30, 20, -1, 107, 10, -1};\n  for (int i = 0; i < 10; i++) if (dense(i) != d[i]) return 1;\n  if (dense(-2) != -1 || dense(1 << 30) != -1) return 2;\n  if (sparse(0) != 1 || sparse(1000) != 2 || sparse(-5) != 3 || sparse((int64_t)1 << 40) != 2 || sparse(5) != 4) return 3;\n  int w[7] = {3, 1, 2, 1, 2, 3, 1};\n  for (int i = 0; i < 7; i++) if (wide(9 + i) != w[i]) return 4;\n  if (wide(((int64_t)1 << 33) + 10) != 3 || wide(-1) != 3) return 5;\n  if (machine(3) != 111 || machine(0) != 0 || machine(9) != -1) return 6;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Panics with one message share the object's thunk of it (`__sc_pk.<k>`: the message's address, then a
// jump to `__sc_panic`, in the cold text): each site is one call (arm64 `bl`) and loads no message. Each
// site still panics with its message.
@test
fn panics_of_one_message_share_a_thunk() {
    let lir = M"(lir ptr 8
sym @divs fn global
fn @divs
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = icmp.eq v1, v3
  br v4, b4, b1
b1:
  v5 = udiv.i64 v0, v1
  v6 = icmp.eq v2, v3
  br v6, b5, b2
b2:
  v7 = udiv.i64 v0, v2
  v8 = add.i64 v5, v7
  v9 = icmp.ugt v8, v0
  br v9, b6, b3
b3:
  ret v8
b4: cold
  panic "attempt to divide by zero"
b5: cold
  panic "attempt to divide by zero"
b6: cold
  panic "attempt to add with overflow"
)";
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(lir, tgt::axis_index("linux", false), tgt::axis_index("aarch64", true), 0, &mut obj),
        "the arm64 object",
    );
    // In `.text` (the thunks are in the cold text): no `adrp` of a message, one `bl` per site.
    assert_eq(elf_text_count(&obj, 0x9F000000, 0x90000000), 0);
    assert_eq(elf_text_count(&obj, 0xFC000000, 0x94000000), 3);
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = "#include <stdint.h>\n#include <stdlib.h>\n#include <stdio.h>\nint64_t divs(int64_t, int64_t, int64_t);\nvoid __sc_panic(const char *m) { puts(m); fflush(stdout); exit(divs(12, 4, 3) == 7 ? 3 : 9); }\nint main(int argc, char **argv) {\n  (void)argv;\n  if (divs(12, 4, 3) != 7) return 1;\n  return (int)divs(1, argc == 1 ? 0 : 1, 1);\n}\n";
    assert_eq(run_native(lir, drv), 3);
}

// A bounded load's bound (`range`) is no operand: on x86-64 the load folds into its compare, and a bound
// that equals a folded value's number is not taken for a use of it (each bound from 0 to 7, so one names
// the compare whatever the backend's numbering).
@test
fn a_folded_bounded_load_takes_no_bound_as_operand() {
    for k in 0..8u32 {
        let lir = format(
            "lir ptr 8\nsym @tagged fn global\nfn @tagged\n  sig (ptr) -> i32\nb0(v0: ptr):\n  v1 = iconst.i8 1\n  v2 = load.i8 v0 align 0 range {}\n  v3 = icmp.ne v2, v1\n  v4 = iconst.i32 5\n  v5 = iconst.i32 7\n  br v3, b1, b2\nb1:\n  ret v4\nb2:\n  ret v5\n",
            k,
        );
        let mut obj = Vector::<u8>::new();
        assert(
            object_of(&lir, tgt::axis_index("linux", false), tgt::axis_index("x86_64", true), 0, &mut obj),
            "the x86-64 object",
        );
    }
}

// A signed lane maximum or minimum against zero, either side (x86-64 before SSE4.1: the other operand
// under its compare mask): 32-bit and 8-bit lanes, the extremes too.
@test
fn signed_lane_extremes_against_zero() {
    let lir = M"(lir ptr 8
sym @clamp fn global
fn @clamp
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = load.v4i32 v1 align 2
  v3 = wconst.v4i32 0x0, 0x0
  v4 = vop.max.s.v4i32 (v2, v3)
  store v4, v0 align 2
  v5 = vop.min.s.v4i32 (v3, v2)
  store v5, v0+16 align 2
  v6 = load.v16i8 v1+16 align 0
  v7 = wconst.v16i8 0x0, 0x0
  v8 = vop.max.s.v16i8 (v7, v6)
  store v8, v0+32 align 0
  v9 = vop.min.s.v16i8 (v6, v7)
  store v9, v0+48 align 0
  ret
)";
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = "#include <stdint.h>\n#include <string.h>\nvoid clamp(uint8_t *, const uint8_t *);\nint main(void) {\n  int32_t w[4] = {5, -7, 0, -2147483647 - 1};\n  int8_t b[16] = {1, -1, 0, 127, -128, 3, -3, 9, -9, 64, -64, 2, -2, 100, -100, 0};\n  uint8_t in[32], out[64];\n  memcpy(in, w, 16);\n  memcpy(in + 16, b, 16);\n  clamp(out, in);\n  int32_t mx[4], mn[4];\n  int8_t bx[16], bn[16];\n  memcpy(mx, out, 16);\n  memcpy(mn, out + 16, 16);\n  memcpy(bx, out + 32, 16);\n  memcpy(bn, out + 48, 16);\n  for (int i = 0; i < 4; i++) if (mx[i] != (w[i] > 0 ? w[i] : 0) || mn[i] != (w[i] < 0 ? w[i] : 0)) return 1 + i;\n  for (int i = 0; i < 16; i++) if (bx[i] != (b[i] > 0 ? b[i] : 0) || bn[i] != (b[i] < 0 ? b[i] : 0)) return 10 + i;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// A lane select with a zero side keeps the other side's lanes under the mask (`m ? x : 0`) or under its
// complement (`m ? 0 : x`): one `pand` or `pandn` on x86-64.
@test
fn lane_selects_with_a_zero_side() {
    let lir = M"(lir ptr 8
sym @split fn global
fn @split
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = load.v4i32 v1 align 2
  v3 = wconst.v4i32 0x0, 0x0
  v4 = vcmp.sgt.v4i32 v2, v3
  v5 = vsel.v4i32 v4, v2, v3
  store v5, v0 align 2
  v6 = vsel.v4i32 v4, v3, v2
  store v6, v0+16 align 2
  ret
)";
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = "#include <stdint.h>\nvoid split(int32_t *, const int32_t *);\nint main(void) {\n  int32_t in[4] = {5, -7, 0, 2147483647}, out[8];\n  split(out, in);\n  for (int i = 0; i < 4; i++) {\n    if (out[i] != (in[i] > 0 ? in[i] : 0)) return 1 + i;\n    if (out[4 + i] != (in[i] > 0 ? 0 : in[i])) return 5 + i;\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// C's `fmin`/`fmax` of lanes against a constant with no NaN and no zero lane (one MINPS/MAXPS on
// x86-64, the constant either side): a NaN lane gives the constant, every other lane the lesser or
// greater, zeros and infinities too.
@test
fn lane_fmin_and_fmax_of_an_ordinary_constant() {
    let lir = M"(lir ptr 8
sym @vmin fn global
sym @vmax fn global
fn @vmin
  sig (ptr) -> void
b0(v0: ptr):
  v1 = load.v4f32 v0 align 2
  v2 = wconst.v4f32 0xc040000040200000, 0x7149f2ca42c80000
  v3 = vop.min.num.v4f32 (v1, v2)
  store v3, v0 align 2
  ret
fn @vmax
  sig (ptr) -> void
b0(v0: ptr):
  v1 = load.v2f64 v0 align 3
  v2 = wconst.v2f64 0xc004000000000000, 0x4059000000000000
  v3 = vop.max.num.v2f64 (v2, v1)
  store v3, v0 align 3
  ret
)";
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = "#include <string.h>\nvoid vmin(float *);\nvoid vmax(double *);\nint main(void) {\n  float k[4] = {2.5f, -3.0f, 100.0f, 1e30f};\n  float inf = 1.0f / 0.0f, nan = 0.0f / 0.0f;\n  float in[3][4] = {{nan, -0.0f, 200.0f, -inf}, {1.0f, nan, inf, 1e31f}, {-0.0f, 0.0f, 99.0f, nan}};\n  for (int r = 0; r < 3; r++) {\n    float v[4], w[4];\n    memcpy(v, in[r], sizeof v);\n    vmin(v);\n    for (int i = 0; i < 4; i++) w[i] = in[r][i] != in[r][i] ? k[i] : in[r][i] < k[i] ? in[r][i] : k[i];\n    if (memcmp(v, w, sizeof v) != 0) return 1 + r;\n  }\n  double c[2] = {-2.5, 100.0};\n  double dn = 0.0 / 0.0, din = 1.0 / 0.0;\n  double dd[3][2] = {{dn, -0.0}, {din, dn}, {-din, 100.0}};\n  for (int r = 0; r < 3; r++) {\n    double v[2], w[2];\n    memcpy(v, dd[r], sizeof v);\n    vmax(v);\n    for (int i = 0; i < 2; i++) w[i] = dd[r][i] != dd[r][i] ? c[i] : dd[r][i] > c[i] ? dd[r][i] : c[i];\n    if (memcmp(v, w, sizeof v) != 0) return 4 + r;\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// Microsoft x64: a loop of C's `fminf` calls (an intrinsic, in xmm registers) beside its vector loop
// (`min.num`) compiles; the homes the vector loop takes (callee-saved xmm registers) all free.
@test
fn windows_fminf_loops_free_their_vector_homes() {
    let lir = M"(lir ptr 8
sym @fminf fn global
sym @fmin fn global
fn @fmin
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0) -> void
  ref p0 0 inner noalias
b0(v0: ptr):
  v1 = load.ptr v0 align 3 tbaa 8
  v2 = fconst.f32 0x42c80000
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = load.i64 v0+8 align 3 tbaa 4
  v6 = iconst.i64 -8
  v7 = and.i64 v5, v6
  v8 = icmp.ne v7, v3
  br v8, b4, b1(v3)
b1(v9: i64): novec
  v10 = icmp.ult v9, v5
  br v10, b3(v9), b2
b2:
  ret
b3(v11: i64):
  v12 = ptradd v1, v11 * 4 inbounds nonnull
  v13 = load.f32 v12 align 2 tbaa 6
  v14 = call.f32 @fminf(v13, v2) : (f32, f32) -> f32
  store v14, v12 align 2 tbaa 6
  v15 = add.i64 v11, v4
  v16 = icmp.ult v15, v5
  br v16, b3(v15), b2
b4:
  v17 = wconst.v4f32 0x42c8000042c80000, 0x42c8000042c80000
  v18 = iconst.i64 8
  jmp b5(v3)
b5(v19: i64): novec
  v20 = ptradd v1, v19 * 4
  v21 = load.v4f32 v20 align 2 tbaa 6
  v22 = vop.min.num.v4f32 (v21, v17)
  store v22, v20 align 2 tbaa 6
  v23 = load.v4f32 v20+16 align 2 tbaa 6
  v24 = vop.min.num.v4f32 (v23, v17)
  store v24, v20+16 align 2 tbaa 6
  v25 = add.i64 v19, v18
  v26 = icmp.ult v25, v7
  br v26, b5(v25), b6
b6:
  jmp b1(v7)
)";
    let mut win = Vector::<u8>::new();
    assert(
        object_of(lir, tgt::axis_index("windows", false), tgt::axis_index("x86_64", true), SSE41, &mut win),
        "the Microsoft x64 object",
    );
}

// A switch on a bounded load (an enum's tag, `range`) whose table holds every value up to the bound
// branches through it with no bound test, one whose bound passes the cases takes the default's entries up
// to it, and one without the bound keeps its test; the `xor` of a `bool` load with 1 returns as loaded,
// with no zero extension (arm64).
@test
fn bounded_switch_tables_take_no_bound_test() {
    let lir = M"(lir ptr 8
sym @op fn global
sym @past fn global
sym @plain fn global
sym @not fn global
fn @op
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = load.i8 v0 align 0 range 4
  switch v2 [0 -> b1, 1 -> b2, 2 -> b3, 3 -> b4, 4 -> b5] else b6
b1:
  v3 = add.i32 v1, v1
  ret v3
b2:
  v4 = mul.i32 v1, v1
  ret v4
b3:
  v5 = sub.i32 v1, v1
  ret v5
b4:
  v6 = iconst.i32 7
  v7 = xor.i32 v1, v6
  ret v7
b5:
  v8 = iconst.i32 3
  v9 = shl.i32 v1, v8
  ret v9
b6:
  v10 = iconst.i32 -1
  ret v10
fn @past
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = load.i8 v0 align 0 range 5
  switch v2 [0 -> b1, 1 -> b2, 2 -> b3, 3 -> b4] else b5
b1:
  v3 = add.i32 v1, v1
  ret v3
b2:
  v4 = mul.i32 v1, v1
  ret v4
b3:
  v5 = sub.i32 v1, v1
  ret v5
b4:
  v6 = iconst.i32 7
  v7 = xor.i32 v1, v6
  ret v7
b5:
  v8 = iconst.i32 3
  v9 = shl.i32 v1, v8
  ret v9
fn @plain
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = load.i8 v0 align 0
  switch v2 [0 -> b1, 1 -> b2, 2 -> b3, 3 -> b4] else b5
b1:
  v3 = add.i32 v1, v1
  ret v3
b2:
  v4 = mul.i32 v1, v1
  ret v4
b3:
  v5 = sub.i32 v1, v1
  ret v5
b4:
  v6 = iconst.i32 7
  v7 = xor.i32 v1, v6
  ret v7
b5:
  v8 = iconst.i32 3
  v9 = shl.i32 v1, v8
  ret v9
fn @not
  sig (ptr) -> i8
b0(v0: ptr):
  v1 = iconst.i8 1
  v2 = load.i8 v0 align 0 bool
  v3 = xor.i8 v2, v1
  ret v3
)";
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(lir, tgt::axis_index("linux", false), tgt::axis_index("aarch64", true), 0, &mut obj),
        "the arm64 object",
    );
    // `b.hi` (the bound tests) and `uxtb` (`ubfm w, w, #0, #7`).
    assert_eq(elf_text_count(&obj, 0xFF00001F, 0x54000008), 1);
    assert_eq(elf_text_count(&obj, 0xFFFFFC00, 0x53001C00), 0);
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = "#include <stdint.h>\nint op(const uint8_t *, int);\nint past(const uint8_t *, int);\nint plain(const uint8_t *, int);\nuint8_t not(const uint8_t *);\nint main(void) {\n  int w[6] = {12, 36, 0, 1, 48, 48};\n  for (uint8_t i = 0; i < 6; i++) {\n    if (i < 5 && op(&i, 6) != (i < 4 ? w[i] : 48)) return 1;\n    if (past(&i, 6) != w[i] || plain(&i, 6) != w[i]) return 2;\n  }\n  uint8_t big = 200;\n  if (plain(&big, 6) != 48) return 3;\n  uint8_t t = 1, f = 0;\n  if (not(&t) != 0 || not(&f) != 1) return 4;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// i128 comparisons on the halves, and shifts by 0, 64 and 127.
@test
fn wide_integer_compares_and_shifts_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @cmp fn global
sym @shifts fn global
fn @cmp
  sig (i64, i64, i64, i64) -> i32
b0(v0: i64, v1: i64, v2: i64, v3: i64):
  v4 = wconst.i128 0x40, 0x0
  v5 = zext.i128 v0
  v6 = sext.i128 v1
  v7 = shl.i128 v6, v4
  v8 = or.i128 v7, v5
  v9 = zext.i128 v2
  v10 = sext.i128 v3
  v11 = shl.i128 v10, v4
  v12 = or.i128 v11, v9
  v13 = icmp.slt v8, v12
  v14 = icmp.ult v8, v12
  v15 = icmp.eq v8, v12
  v16 = icmp.sge v8, v12
  v17 = icmp.ule v8, v12
  v18 = zext.i32 v13
  v19 = zext.i32 v14
  v20 = zext.i32 v15
  v21 = zext.i32 v16
  v22 = zext.i32 v17
  v23 = iconst.i32 1
  v24 = iconst.i32 2
  v25 = iconst.i32 3
  v26 = iconst.i32 4
  v27 = shl.i32 v19, v23
  v28 = shl.i32 v20, v24
  v29 = shl.i32 v21, v25
  v30 = shl.i32 v22, v26
  v31 = or.i32 v18, v27
  v32 = or.i32 v31, v28
  v33 = or.i32 v32, v29
  v34 = or.i32 v33, v30
  ret v34
fn @shifts
  sig (i64, i64, i32, ptr) -> void
b0(v0: i64, v1: i64, v2: i32, v3: ptr):
  v4 = wconst.i128 0x40, 0x0
  v5 = zext.i128 v0
  v6 = sext.i128 v1
  v7 = shl.i128 v6, v4
  v8 = or.i128 v7, v5
  v9 = zext.i128 v2
  v10 = shl.i128 v8, v9
  v11 = lshr.i128 v8, v9
  v12 = ashr.i128 v8, v9
  v13 = trunc.i64 v10
  v14 = lshr.i128 v10, v4
  v15 = trunc.i64 v14
  v16 = trunc.i64 v11
  v17 = lshr.i128 v11, v4
  v18 = trunc.i64 v17
  v19 = trunc.i64 v12
  v20 = lshr.i128 v12, v4
  v21 = trunc.i64 v20
  store v13, v3 align 3
  store v15, v3+8 align 3
  store v16, v3+16 align 3
  store v18, v3+24 align 3
  store v19, v3+32 align 3
  store v21, v3+40 align 3
  ret
)";
    let drv = "#include <stdint.h>\ntypedef __int128 i128;\ntypedef unsigned __int128 u128;\nint cmp(int64_t, int64_t, int64_t, int64_t);\nvoid shifts(int64_t, int64_t, int32_t, int64_t *);\nstatic int want(i128 a, i128 b) { return (a < b) | ((u128)a < (u128)b) << 1 | (a == b) << 2 | (a >= b) << 3 | ((u128)a <= (u128)b) << 4; }\nint main(void) {\n  int64_t v[5][2] = {{0, 0}, {5, 0}, {0, -1}, {-1, -1}, {7, 1}};\n  for (int i = 0; i < 5; i++)\n    for (int j = 0; j < 5; j++) {\n      i128 a = (i128)((u128)(uint64_t)v[i][1] << 64 | (uint64_t)v[i][0]);\n      i128 b = (i128)((u128)(uint64_t)v[j][1] << 64 | (uint64_t)v[j][0]);\n      if (cmp(v[i][0], v[i][1], v[j][0], v[j][1]) != want(a, b)) return 1;\n    }\n  int n[4] = {0, 1, 64, 127};\n  for (int k = 0; k < 4; k++) {\n    int64_t o[6];\n    shifts(0x0123456789abcdefLL, (int64_t)0xfedcba9876543210ULL, n[k], o);\n    i128 x = (i128)((u128)0xfedcba9876543210ULL << 64 | 0x0123456789abcdefULL);\n    u128 l = (u128)x << n[k], r = (u128)x >> n[k];\n    i128 s = x >> n[k];\n    if (o[0] != (int64_t)l || o[1] != (int64_t)(l >> 64) || o[2] != (int64_t)r || o[3] != (int64_t)(r >> 64) || o[4] != (int64_t)s || o[5] != (int64_t)((u128)s >> 64)) return 2 + k;\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Variadic calls both ways: LIR calls a C function that reads an int, a long long, a double and an int,
// and C calls a LIR function that reads them. A `va_list` slot holds the largest one (AAPCS64's 32 bytes).
@test
fn variadic_calls_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @mix fn global ext
sym @call_mix fn global
sym @lsum fn global
fn @call_mix
  sig () -> i64
b0:
  v0 = iconst.i32 3
  v1 = iconst.i32 -7
  v2 = iconst.i64 1099511627776
  v3 = fconst.f64 0x4004000000000000
  v4 = iconst.i32 40
  v5 = call.i64 @mix(v0, v1, v2, v3, v4) : (i32, ... i32, i64, f64, i32) -> i64
  ret v5
fn @lsum
  sig (i32, ...) -> i64
  slot s0 size 32 align 3
b0(v0: i32):
  v1 = slotaddr s0
  vastart v1
  v2 = vaarg.i32 v1
  v3 = vaarg.i64 v1
  v4 = vaarg.f64 v1
  v5 = vaarg.i32 v1
  vaend v1
  v6 = sext.i64 v2
  v7 = add.i64 v6, v3
  v8 = fptosi.i64 v4
  v9 = add.i64 v7, v8
  v10 = sext.i64 v5
  v11 = add.i64 v9, v10
  v12 = sext.i64 v0
  v13 = mul.i64 v11, v12
  ret v13
)";
    let drv = "#include <stdarg.h>\n#include <stdint.h>\nint64_t call_mix(void);\nint64_t lsum(int, ...);\nint64_t mix(int n, ...) {\n  va_list ap;\n  va_start(ap, n);\n  int a = va_arg(ap, int);\n  long long b = va_arg(ap, long long);\n  double c = va_arg(ap, double);\n  int d = va_arg(ap, int);\n  va_end(ap);\n  return n * (a + b + (long long)c + d);\n}\nint main(void) {\n  int64_t want = 3 * (-7 + ((int64_t)1 << 40) + 2 + 40);\n  if (call_mix() != want) return 1;\n  if (lsum(3, -7, (long long)1 << 40, 2.5, 40) != want) return 2;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Variadic arguments past the argument registers: nine integers and nine floats, then an `__int128`, which
// the stack holds at 16-byte alignment (Apple and wasm keep every variadic argument in memory).
@test
fn variadic_arguments_past_the_registers_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @lmany fn global
fn @lmany
  sig (i32, ...) -> i64
  slot s0 size 32 align 3
b0(v0: i32):
  v1 = slotaddr s0
  vastart v1
  v2 = vaarg.i64 v1
  v3 = vaarg.i64 v1
  v4 = vaarg.i64 v1
  v5 = vaarg.i64 v1
  v6 = vaarg.i64 v1
  v7 = vaarg.i64 v1
  v8 = vaarg.i64 v1
  v9 = vaarg.i64 v1
  v10 = vaarg.i64 v1
  v11 = vaarg.f64 v1
  v12 = vaarg.f64 v1
  v13 = vaarg.f64 v1
  v14 = vaarg.f64 v1
  v15 = vaarg.f64 v1
  v16 = vaarg.f64 v1
  v17 = vaarg.f64 v1
  v18 = vaarg.f64 v1
  v19 = vaarg.f64 v1
  v20 = vaarg.i128 v1
  vaend v1
  v21 = add.i64 v2, v3
  v22 = add.i64 v21, v4
  v23 = add.i64 v22, v5
  v24 = add.i64 v23, v6
  v25 = add.i64 v24, v7
  v26 = add.i64 v25, v8
  v27 = add.i64 v26, v9
  v28 = add.i64 v27, v10
  v29 = fptosi.i64 v11
  v30 = add.i64 v28, v29
  v31 = fptosi.i64 v12
  v32 = add.i64 v30, v31
  v33 = fptosi.i64 v13
  v34 = add.i64 v32, v33
  v35 = fptosi.i64 v14
  v36 = add.i64 v34, v35
  v37 = fptosi.i64 v15
  v38 = add.i64 v36, v37
  v39 = fptosi.i64 v16
  v40 = add.i64 v38, v39
  v41 = fptosi.i64 v17
  v42 = add.i64 v40, v41
  v43 = fptosi.i64 v18
  v44 = add.i64 v42, v43
  v45 = fptosi.i64 v19
  v46 = add.i64 v44, v45
  v47 = trunc.i64 v20
  v48 = add.i64 v46, v47
  v49 = sext.i64 v0
  v50 = mul.i64 v48, v49
  ret v50
)";
    let drv = "#include <stdint.h>\nint64_t lmany(int, ...);\nint main(void) {\n  __int128 w = (__int128)1 << 70 | 33;\n  int64_t r = lmany(2, 1LL, 2LL, 3LL, 4LL, 5LL, 6LL, 7LL, 8LL, 9LL, 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, w);\n  return r == 2 * (45 + 36 + 33) ? 0 : 1;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A variadic body that calls only in a rare block, after a body of the same shape (arm64 shrink-wrapping):
// its entry stores the register save area (the standard convention), so it sets its frame up there, which
// the caller's frame relies on. The C side checks its own locals after the calls.
@test
fn a_variadic_body_with_rare_calls_keeps_its_frame_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @poll fn global ext
sym @first fn global
sym @second fn global
fn @first
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = icmp.eq v0, v1
  br v2, b1, b2
b1: cold
  v3 = call.i64 @poll() : () -> i64
  ret v3
b2:
  ret v0
fn @second
  sig (i64, ...) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = icmp.eq v0, v1
  br v2, b1, b2
b1: cold
  v3 = call.i64 @poll() : () -> i64
  ret v3
b2:
  ret v0
)";
    let drv = "#include <stdint.h>\nint64_t first(int64_t);\nint64_t second(int64_t, ...);\nint64_t poll(void) { return 0; }\nint main(void) {\n  volatile int64_t g[24];\n  for (int i = 0; i < 24; i++) g[i] = i + 1;\n  if (first(5) != 5 || second(7, 1, 2.0) != 7) return 1;\n  for (int i = 0; i < 24; i++) if (g[i] != i + 1) return 2;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Function addresses in data (relocations) and indirect calls through them.
@test
fn indirect_calls_through_data_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @twice fn local
sym @thrice fn local
sym @tab data local
sym @apply fn global
fn @twice
  sig (i32) -> i32
b0(v0: i32):
  v1 = add.i32 v0, v0
  ret v1
fn @thrice
  sig (i32) -> i32
b0(v0: i32):
  v1 = add.i32 v0, v0
  v2 = add.i32 v1, v0
  ret v2
fn @apply
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = symaddr @tab
  v3 = iconst.i32 0
  v4 = icmp.eq v0, v3
  br v4, b1, b2
b1:
  v5 = load.ptr v2 align 3
  jmp b3(v5)
b2:
  v6 = load.ptr v2+8 align 3
  jmp b3(v6)
b3(v7: ptr):
  v8 = call.ind.i32 v7(v1) : (i32) -> i32
  ret v8
data @tab size 16 align 3 ro reloc 0 @twice reloc 8 @thrice
)";
    let drv = "int apply(int, int);\nint main(void) { return apply(0, 21) == 42 && apply(1, 5) == 15 ? 0 : 1; }\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Funnel shifts, `x << k | y >> (w - k)` of two values by constants (`lv::rotate_of`: arm64 `extr`, x86-64
// `shld`), of 64 and 32 bits, through `or`, `xor` and `add`, the right-shifted value first or second, one
// that stays live, and one in a loop that reads the loop's old value only through its folded shift, whose
// result goes back to that value (`x64gen::step_reg` gives it the register only when nothing else reads
// it); and the high half of a product whose operand dies in the register `mul` reads on x86-64 (`tri`, a
// triangle number from its 128-bit product's words).
@test
fn funnel_shifts_and_word_products_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @f64 fn global
sym @f32 fn global
sym @fadd fn global
sym @flive fn global
sym @halve fn global
sym @tri fn global
fn @f64
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 13
  v3 = iconst.i64 51
  v4 = shl.i64 v0, v2
  v5 = lshr.i64 v1, v3
  v6 = or.i64 v4, v5
  ret v6
fn @f32
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 5
  v3 = iconst.i32 27
  v4 = lshr.i32 v1, v2
  v5 = shl.i32 v0, v3
  v6 = xor.i32 v4, v5
  ret v6
fn @fadd
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 63
  v3 = iconst.i64 1
  v4 = shl.i64 v1, v2
  v5 = lshr.i64 v0, v3
  v6 = add.i64 v5, v4
  ret v6
fn @flive
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 40
  v3 = iconst.i64 24
  v4 = shl.i64 v1, v2
  v5 = lshr.i64 v0, v3
  v6 = or.i64 v4, v5
  v7 = add.i64 v6, v0
  v8 = xor.i64 v7, v1
  ret v8
fn @halve
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 63
  jmp b1(v3, v0, v1)
b1(v6: i64, v7: i64, v8: i64):
  v9 = icmp.ult v6, v2
  br v9, b2, b3
b2:
  v10 = lshr.i64 v7, v4
  v11 = shl.i64 v8, v5
  v12 = or.i64 v11, v10
  v13 = lshr.i64 v8, v4
  v14 = add.i64 v6, v4
  jmp b1(v14, v12, v13)
b3:
  v15 = xor.i64 v7, v8
  ret v15
fn @tri
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1
  v2 = iconst.i64 63
  v3 = sub.i64 v0, v1
  v4 = mul.i64 v0, v3
  v5 = mulhu.i64 v0, v3
  v6 = lshr.i64 v4, v1
  v7 = shl.i64 v5, v2
  v8 = or.i64 v6, v7
  ret v8
)";
    let drv = M"(#include <stdint.h>
int64_t f64(int64_t, int64_t);
int32_t f32(int32_t, int32_t);
int64_t fadd(int64_t, int64_t);
int64_t flive(int64_t, int64_t);
int64_t halve(int64_t, int64_t, int64_t);
int64_t tri(int64_t);
int main(void) {
  uint64_t x = 0x9e3779b97f4a7c15u, y = 0xc2b2ae3d27d4eb4fu;
  uint32_t a = 0x85ebca6bu, b = 0x27d4eb2fu;
  if ((uint64_t)f64((int64_t)x, (int64_t)y) != (x << 13 | y >> 51)) return 1;
  if ((uint32_t)f32((int32_t)a, (int32_t)b) != (b >> 5 ^ a << 27)) return 2;
  if ((uint64_t)fadd((int64_t)x, (int64_t)y) != (x >> 1) + (y << 63)) return 3;
  if ((uint64_t)flive((int64_t)x, (int64_t)y) != (((y << 40 | x >> 24) + x) ^ y)) return 4;
  unsigned __int128 w = (unsigned __int128)y << 64 | x;
  for (int k = 0; k < 37; k++) w >>= 1;
  if ((uint64_t)halve((int64_t)x, (int64_t)y, 37) != ((uint64_t)w ^ (uint64_t)(w >> 64))) return 7;
  uint64_t n = 0x123456789u;
  if ((uint64_t)tri((int64_t)n) != (uint64_t)((unsigned __int128)n * (n - 1) >> 1)) return 5;
  if (tri(0) != 0 || tri(1) != 0 || tri(10) != 45) return 6;
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
}

// Super-C's own convention under Microsoft x64 (`w64::classify`'s `sc`): a 16-byte aggregate (a slice)
// passes in two integer registers by position (rcx and rdx, then the next argument in r8) and returns in
// rax and rdx, where C's convention passes and returns it through memory. A function of that convention
// whose address the package takes gets a C entry, a thunk that calls it (`w64::thunks`), which the
// address names; a direct call names the function. Only under Microsoft x64, and the objects build.
@test
fn slices_pass_in_two_registers_between_super_c_functions_on_windows() {
    let lir = M"(lir ptr 8
sym @sum fn global
sym @take fn global
sym @call fn global
fn @sum
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, i32) -> l0
b0(v0: ptr, v1: i32, v2: ptr):
  v3 = load.ptr v0 align 3
  v4 = load.i64 v0+8 align 3
  v5 = zext.i64 v1
  v6 = add.i64 v4, v5
  store v3, v2 align 3
  store v6, v2+8 align 3
  ret
fn @take
  sig () -> ptr
b0:
  v0 = symaddr @sum
  ret v0
fn @call
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (ptr, i64) -> i64
  slot s0 size 16 align 3
  slot s1 size 16 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i32 3
  store v0, v2 align 3
  store v1, v2+8 align 3
  call @sum(v2, v4, v3) : (l0, i32) -> l0
  v5 = load.i64 v3+8 align 3
  ret v5
)";
    let mut err = String::new();
    let mut p = lparse::parse(lir, &mut err).unwrap();
    let b = &p.bodies[p.syms[p.find_symbol("sum") as usize].def as usize];
    let mut lay = ab::CallLayout::new();
    w64::classify(b, b.sig, 8, true, &mut lay);
    assert(
        lay.locs[0].kind == ab::L_REG && lay.locs[0].n == 2 && lay.locs[1].kind == ab::L_REG,
        "the slice in two registers",
    );
    assert_eq(lay.parts[lay.locs[0].p0 as usize].reg, w64::gp_arg(0));
    assert_eq(lay.parts[lay.locs[0].p0 as usize + 1].reg, w64::gp_arg(1));
    assert_eq(lay.parts[lay.locs[1].p0 as usize].reg, w64::gp_arg(2));
    assert(lay.ret.kind == ab::L_REG && lay.ret.n == 2, "the result in rax and rdx");
    w64::classify(b, b.sig, 8, false, &mut lay);
    assert(lay.locs[0].kind == ab::L_REF_REG && lay.ret.kind == ab::L_SRET, "C passes and returns it in memory");
    let x64 = tgt::axis_index("x86_64", true);
    assert(nat::prepare(&mut p, tgt::axis_index("windows", false), x64, &mut err), err.as_str());
    let th = p.find_symbol("sum.msabi");
    assert(th != NONE && p.syms[th as usize].used && p.syms[th as usize].def != NONE, "a C entry");
    let tk = &p.bodies[p.syms[p.find_symbol("take") as usize].def as usize];
    assert_eq(tk.syms[tk.insts[0].a as usize], th);
    let cl = &p.bodies[p.syms[p.find_symbol("call") as usize].def as usize];
    let sum = p.find_symbol("sum");
    let mut direct = false;
    let mut entry = false;
    for k in 0..cl.syms.len() {
        direct = direct || cl.syms[k] == sum;
        entry = entry || cl.syms[k] == th;
    }
    assert(direct && !entry, "a direct call names the function");
    // The thunk is local: it goes in the object of the code that takes the address, a unit's own.
    let mut u = lparse::parse(lir, &mut err).unwrap();
    let ut = u.find_symbol("take");
    u.syms.index_mut(ut as usize).unit = 0;
    u.syms.index_mut(ut as usize).own = true;
    assert(nat::prepare(&mut u, tgt::axis_index("windows", false), x64, &mut err), err.as_str());
    let uth = u.find_symbol("sum.msabi0");
    assert(uth != NONE && u.syms[uth as usize].unit == 0 && u.syms[uth as usize].own, "in the unit's own object");
    let mut q = lparse::parse(lir, &mut err).unwrap();
    assert(nat::prepare(&mut q, tgt::axis_index("linux", false), x64, &mut err), err.as_str());
    assert(q.find_symbol("sum.msabi") == NONE, "System V needs no entry");
    let mut obj = Vector::<u8>::new();
    assert(object_of(lir, tgt::axis_index("windows", false), x64, 0, &mut obj), "the Microsoft x64 object");
    assert(object_of(lir, tgt::axis_index("linux", false), x64, 0, &mut obj), "the System V object");
}

// A call's aggregate result in registers whose parts the loads right after it read whole, from a slot
// nothing else uses (`place::result_loads`): the loads take the result's registers and the call stores
// nothing; of one part and of two. A slot that a later load reads too keeps the stores, as does one whose
// load folds into its user (x86-64's memory operand, `lv.pfold`). Two loads of one part each keep the
// value. The C side checks each sum.
@test
fn call_results_stay_in_their_registers_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @mk fn global noinline
sym @pair fn global noinline
sym @one fn global
sym @two fn global
sym @kept fn global
sym @folded fn global
sym @dup fn global
fn @mk
  layout l0 size 8 align 2 [0 i32, 4 i32]
  sig (i32) -> l0
b0(v0: i32, v1: ptr):
  v2 = iconst.i32 7
  v3 = mul.i32 v0, v2
  store v0, v1 align 2
  store v3, v1+4 align 2
  ret
fn @pair
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> l0
b0(v0: i64, v1: ptr):
  v2 = iconst.i64 3
  v3 = shl.i64 v0, v2
  store v0, v1 align 3
  store v3, v1+8 align 3
  ret
fn @one
  layout l0 size 8 align 2 [0 i32, 4 i32]
  sig (i32) -> i64
  slot s0 size 8 align 2
b0(v0: i32):
  v1 = slotaddr s0
  call @mk(v0, v1) : (i32) -> l0
  v2 = load.i64 v1 align 2
  v3 = iconst.i64 32
  v4 = lshr.i64 v2, v3
  v5 = add.i64 v2, v4
  ret v5
fn @two
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> i64
  slot s0 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  call @pair(v0, v1) : (i64) -> l0
  v2 = load.i64 v1 align 3
  v3 = load.i64 v1+8 align 3
  v4 = sub.i64 v3, v2
  ret v4
fn @kept
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> i64
  slot s0 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  call @pair(v0, v1) : (i64) -> l0
  v2 = load.i64 v1 align 3
  v3 = iconst.i64 0
  v4 = icmp.eq v2, v3
  br v4, b1, b2
b1:
  ret v3
b2:
  v5 = load.i64 v1+8 align 3
  ret v5
fn @folded
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64, i64) -> i64
  slot s0 size 16 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  call @pair(v0, v2) : (i64) -> l0
  v3 = load.i64 v2+8 align 3
  v4 = add.i64 v1, v3
  v5 = load.i64 v2 align 3
  v6 = sub.i64 v4, v5
  ret v6
fn @dup
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> i64
  slot s0 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  call @pair(v0, v1) : (i64) -> l0
  v2 = load.i64 v1 align 3
  v3 = load.i64 v1 align 3
  v4 = load.i64 v1+8 align 3
  v5 = mul.i64 v2, v4
  v6 = add.i64 v5, v3
  v7 = mul.i64 v6, v3
  ret v7
)";
    let drv = M"(#include <stdint.h>
int64_t one(int32_t);
int64_t two(int64_t);
int64_t kept(int64_t);
int64_t folded(int64_t, int64_t);
int64_t dup(int64_t);
int main(void) {
  uint64_t o = (uint64_t)(uint32_t)5 | (uint64_t)(uint32_t)35 << 32;
  if ((uint64_t)one(5) != o + (o >> 32)) return 1;
  if (two(9) != 72 - 9) return 2;
  if (kept(4) != 32 || kept(0) != 0) return 3;
  if (folded(5, 100) != 100 + 40 - 5) return 4;
  if (dup(5) != (5 * 40 + 5) * 5) return 5;
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Small aggregates by value whose fields share an 8-byte chunk, in the form the optimizer gives them
// (`lir::opt`'s `agg_chunk`, `ret_chunks`): each parameter chunk is one load, which takes the chunk's
// register, and each result chunk one store, which the return moves into its register; a float's bits
// share a chunk with an integer. The C side reads each field.
@test
fn aggregate_fields_in_shared_chunks_cross_the_c_abi() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @padd fn global
sym @opt fn global
sym @fi fn global
sym @tri fn global
fn @padd
  layout l0 size 8 align 2 [0 i32, 4 i32]
  sig (l0, l0) -> l0
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = iconst.i64 32
  v4 = load.i64 v0 align 2
  v5 = load.i64 v1 align 2
  v6 = trunc.i32 v4
  v7 = trunc.i32 v5
  v8 = add.i32 v6, v7
  v9 = lshr.i64 v4, v3
  v10 = trunc.i32 v9
  v11 = lshr.i64 v5, v3
  v12 = trunc.i32 v11
  v13 = sub.i32 v10, v12
  v14 = zext.i64 v8
  v15 = zext.i64 v13
  v16 = shl.i64 v15, v3
  v17 = or.i64 v14, v16
  store v17, v2 align 2
  ret
fn @opt
  layout l0 size 8 align 2 [0 i8, 4 i32]
  sig (i32) -> l0
b0(v0: i32, v1: ptr):
  v2 = iconst.i32 5
  v3 = iconst.i64 0
  v4 = iconst.i64 32
  v5 = iconst.i64 1
  v6 = icmp.ugt v0, v2
  br v6, b2, b1
b1:
  store v3, v1 align 0
  ret
b2:
  v7 = zext.i64 v0
  v8 = shl.i64 v7, v4
  v9 = or.i64 v8, v5
  store v9, v1 align 0
  ret
fn @fi
  layout l0 size 8 align 2 [0 f32, 4 i32]
  sig (l0) -> l0
b0(v0: ptr, v1: ptr):
  v2 = iconst.i64 32
  v3 = load.i64 v0 align 2
  v4 = trunc.i32 v3
  v5 = bitcast.f32 v4
  v6 = fadd.f32 v5, v5
  v7 = lshr.i64 v3, v2
  v8 = trunc.i32 v7
  v9 = add.i32 v8, v8
  v10 = bitcast.i32 v6
  v11 = zext.i64 v10
  v12 = zext.i64 v9
  v13 = shl.i64 v12, v2
  v14 = or.i64 v11, v13
  store v14, v1 align 2
  ret
fn @tri
  layout l0 size 12 align 2 [0 i32, 4 i32, 8 i32]
  sig (i32) -> l0
b0(v0: i32, v1: ptr):
  v2 = iconst.i32 1
  v3 = iconst.i32 2
  v4 = iconst.i64 32
  v5 = add.i32 v0, v2
  v6 = add.i32 v0, v3
  v7 = zext.i64 v0
  v8 = zext.i64 v5
  v9 = shl.i64 v8, v4
  v10 = or.i64 v7, v9
  store v10, v1 align 2
  store v6, v1+8 align 2
  ret
)";
    let drv = M"(#include <stdint.h>
typedef struct { int32_t x, y; } P;
typedef struct { uint8_t some; uint32_t v; } O;
typedef struct { float f; int32_t i; } FI;
typedef struct { int32_t a, b, c; } T;
P padd(P, P);
O opt(uint32_t);
FI fi(FI);
T tri(int32_t);
int main(void) {
  P p = padd((P){7, -3}, (P){5, 9});
  O s = opt(9), n = opt(2);
  FI f = fi((FI){1.5f, -4});
  T t = tri(-1);
  if (p.x != 12 || p.y != -12) return 1;
  if (s.some != 1 || s.v != 9 || n.some != 0 || n.v != 0) return 2;
  if (f.f != 3.0f || f.i != -8) return 3;
  if (t.a != -1 || t.b != 0 || t.c != 1) return 4;
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Aggregates by value both ways: one of two scalars, and one of a single double.
@test
fn aggregates_cross_the_c_abi() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @swap fn global
sym @half fn global
sym @cswap fn global ext
sym @via_c fn global
fn @swap
  layout l0 size 16 align 3 [0 i64, 8 f64]
  sig (l0) -> l0
b0(v0: ptr, v1: ptr):
  v2 = load.i64 v0 align 3
  v3 = load.f64 v0+8 align 3
  v4 = fptosi.i64 v3
  v5 = sitofp.f64 v2
  store v4, v1 align 3
  store v5, v1+8 align 3
  ret
fn @half
  layout l0 size 8 align 3 [0 f64]
  sig (l0) -> l0
b0(v0: ptr, v1: ptr):
  v2 = load.f64 v0 align 3
  v3 = fconst.f64 0x3fe0000000000000
  v4 = fmul.f64 v2, v3
  store v4, v1 align 3
  ret
fn @via_c
  layout l0 size 16 align 3 [0 i64, 8 f64]
  sig (i64) -> i64
  slot s0 size 16 align 3
  slot s1 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = sitofp.f64 v0
  store v0, v1 align 3
  store v3, v1+8 align 3
  call @cswap(v1, v2) : (l0) -> l0
  v4 = load.i64 v2 align 3
  ret v4
)";
    let drv = "#include <stdint.h>\ntypedef struct { int64_t a; double b; } P;\ntypedef struct { double d; } H;\nP swap(P);\nH half(H);\nint64_t via_c(int64_t);\nP cswap(P p) { P r = {(int64_t)p.b + 1, (double)p.a}; return r; }\nint main(void) {\n  P p = {7, 2.5};\n  P q = swap(p);\n  if (q.a != 2 || q.b != 7.0) return 1;\n  H h = {3.0};\n  if (half(h).d != 1.5) return 2;\n  if (via_c(41) != 42) return 3;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// `and`s and `or`s of a bit test and a comparison (arm64: `tst` then `ccmp`), the bit test on either side,
// and a chain's result returned in place.
@test
fn chains_that_start_with_a_bit_test_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @pow2 fn global
sym @either fn global
fn @pow2
  sig (i32) -> i8
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 1
  v3 = icmp.ne v0, v1
  v4 = sub.i32 v0, v2
  v5 = and.i32 v0, v4
  v6 = icmp.eq v5, v1
  v7 = and.i8 v3, v6
  ret v7
fn @either
  sig (i64, i64) -> i8
b0(v0: i64, v1: i64):
  v2 = iconst.i64 7
  v3 = iconst.i64 0
  v4 = iconst.i64 100
  v5 = and.i64 v0, v2
  v6 = icmp.ne v5, v3
  v7 = icmp.sgt v1, v4
  v8 = or.i8 v6, v7
  ret v8
)";
    let drv = "#include <stdint.h>\nuint8_t pow2(uint32_t);\nuint8_t either(int64_t, int64_t);\nint main(void) {\n  if (pow2(0) != 0 || pow2(1) != 1 || pow2(64) != 1 || pow2(96) != 0 || pow2(0x80000000u) != 1) return 1;\n  if (either(8, 5) != 0 || either(9, 5) != 1 || either(8, 101) != 1 || either(16, -5) != 0) return 2;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Bit reversals of 8, 16, 32 and 64 bits (arm64 `rbit`, shifted down for the narrow ones).
@test
fn bit_reversals_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @r8 fn global
sym @r16 fn global
sym @r32 fn global
sym @r64 fn global
fn @r8
  sig (i8) -> i8
b0(v0: i8):
  v1 = bitrev.i8 v0
  ret v1
fn @r16
  sig (i16) -> i16
b0(v0: i16):
  v1 = bitrev.i16 v0
  ret v1
fn @r32
  sig (i32) -> i32
b0(v0: i32):
  v1 = bitrev.i32 v0
  ret v1
fn @r64
  sig (i64) -> i64
b0(v0: i64):
  v1 = bitrev.i64 v0
  ret v1
)";
    let drv = "#include <stdint.h>\nuint8_t r8(uint8_t);\nuint16_t r16(uint16_t);\nuint32_t r32(uint32_t);\nuint64_t r64(uint64_t);\nint main(void) {\n  if (r8(0x01) != 0x80 || r8(0x0F) != 0xF0) return 1;\n  if (r16(0x0001) != 0x8000 || r16(0x1234) != 0x2C48) return 2;\n  if (r32(0x12345678u) != 0x1E6A2C48u) return 3;\n  if (r64(1) != 0x8000000000000000ull || r64(0x00000000000000F0ull) != 0x0F00000000000000ull) return 4;\n  return 0;\n}\n";
    if tgt::host_isa() == tgt::axis_index("aarch64", true) {
        assert_eq(run_native(lir, drv), 0);
    }
}

// Loads and stores at an index that is a 32-bit value zero- or sign-extended (arm64 `uxtw`, `sxtw`; a
// negative index), or an 8- or 16-bit parameter zero-extended (Apple arm64: the caller extended it).
@test
fn extended_indexes_address_right() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @ld32 fn global
sym @lds32 fn global
sym @st32 fn global
sym @ld8 fn global
sym @ld16 fn global
fn @ld32
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = zext.i64 v1
  v3 = ptradd v0, v2 * 4
  v4 = load.i32 v3 align 2
  ret v4
fn @lds32
  sig (ptr, i32) -> i64
b0(v0: ptr, v1: i32):
  v2 = sext.i64 v1
  v3 = ptradd v0, v2 * 8
  v4 = load.i64 v3 align 3
  ret v4
fn @st32
  sig (ptr, i32, i16) -> void
b0(v0: ptr, v1: i32, v2: i16):
  v3 = zext.i64 v1
  v4 = ptradd v0, v3 * 2
  store v2, v4 align 1
  ret
fn @ld8
  sig (ptr, i8) -> i32
b0(v0: ptr, v1: i8):
  v2 = zext.i64 v1
  v3 = ptradd v0, v2 * 4
  v4 = load.i32 v3 align 2
  ret v4
fn @ld16
  sig (ptr, i16) -> i32
b0(v0: ptr, v1: i16):
  v2 = zext.i64 v1
  v3 = ptradd v0, v2 * 4
  v4 = load.i32 v3 align 2
  ret v4
)";
    let drv = "#include <stdint.h>\nint32_t ld32(const int32_t *, uint32_t);\nint64_t lds32(const int64_t *, int32_t);\nvoid st32(int16_t *, uint32_t, int16_t);\nint32_t ld8(const int32_t *, uint8_t);\nint32_t ld16(const int32_t *, uint16_t);\nstatic int32_t a[70000];\nstatic int64_t w[9] = {1, 2, 3, 4, 5, 6, 7, 8, 9};\nstatic int16_t h[8];\nint main(void) {\n  for (int i = 0; i < 70000; i++) a[i] = i * 3;\n  if (ld32(a, 65537) != 196611) return 1;\n  if (lds32(w + 4, -3) != 2 || lds32(w + 4, 4) != 9) return 2;\n  st32(h, 5, -7);\n  if (h[5] != -7 || h[4] != 0) return 3;\n  if (ld8(a, 255) != 765) return 4;\n  if (ld16(a, 65535) != 196605) return 5;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// Indirect calls whose target is in a register no argument takes, in one an argument takes (moved first),
// and a sibling one, each reading its arguments right.
@test
fn indirect_calls_through_registers_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @via3 fn global
sym @via0 fn global
sym @tail fn global
fn @via3
  sig (i64, i64, ptr) -> i64
b0(v0: i64, v1: i64, v2: ptr):
  v3 = call.ind.i64 v2(v0, v1) : (i64, i64) -> i64
  v4 = iconst.i64 1
  v5 = add.i64 v3, v4
  ret v5
fn @via0
  sig (ptr, i64, i64) -> i64
b0(v0: ptr, v1: i64, v2: i64):
  v3 = call.ind.i64 v0(v2, v1) : (i64, i64) -> i64
  v4 = iconst.i64 2
  v5 = mul.i64 v3, v4
  ret v5
fn @tail
  sig (ptr, i64, i64) -> i64
b0(v0: ptr, v1: i64, v2: i64):
  v3 = call.ind.i64 v0(v2, v1) : (i64, i64) -> i64
  ret v3
)";
    let drv = "#include <stdint.h>\ntypedef int64_t (*F)(int64_t, int64_t);\nint64_t via3(int64_t, int64_t, F);\nint64_t via0(F, int64_t, int64_t);\nint64_t tail(F, int64_t, int64_t);\nstatic int64_t sub(int64_t a, int64_t b) { return a - b; }\nint main(void) {\n  if (via3(10, 3, sub) != 8) return 1;\n  if (via0(sub, 10, 3) != -14) return 2;\n  if (tail(sub, 10, 3) != -7) return 3;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_native_with(lir, drv, TAIL), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Sums, minimums, maximums, `and`s, `or`s and `xor`s of a vector's integer lanes (arm64: `addv`, `addp`,
// `smaxv`, `uminv` and the like in v registers; x86-64: halves combined in xmm registers,
// `reduce_halves`): lanes of 1, 2, 4 and 8 bytes, signed and unsigned.
@test
fn vector_reductions_in_registers_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @reds fn global
fn @reds
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = load.v4i32 v0 align 2
  v3 = vop.reduce_add.i32 (v2)
  v4 = vop.reduce_max.s.i32 (v2)
  v5 = vop.reduce_min.i32 (v2)
  v6 = load.v16i8 v0 align 0
  v7 = vop.reduce_add.i8 (v6)
  v8 = vop.reduce_min.s.i8 (v6)
  v9 = vop.reduce_max.i8 (v6)
  v10 = load.v8i16 v0 align 1
  v11 = vop.reduce_add.i16 (v10)
  v12 = load.v2i64 v0 align 3
  v13 = vop.reduce_add.i64 (v12)
  v14 = load.v2i32 v0 align 2
  v15 = vop.reduce_add.i32 (v14)
  v16 = vop.reduce_max.s.i32 (v14)
  v17 = vop.reduce_and.i32 (v2)
  v18 = vop.reduce_or.i8 (v6)
  v19 = vop.reduce_xor.i16 (v10)
  v20 = vop.reduce_xor.i64 (v12)
  store v17, v1+40 align 2
  store v18, v1+44 align 0
  store v19, v1+46 align 1
  store v20, v1+48 align 3
  store v3, v1 align 2
  store v4, v1+4 align 2
  store v5, v1+8 align 2
  store v7, v1+12 align 0
  store v8, v1+13 align 0
  store v9, v1+14 align 0
  store v11, v1+16 align 1
  store v13, v1+24 align 3
  store v15, v1+32 align 2
  store v16, v1+36 align 2
  ret
)";
    let drv = "#include <stdint.h>\n#include <string.h>\nvoid reds(const void *, void *);\nint main(void) {\n  int32_t w[4] = {7, -3, 100, -40};\n  unsigned char o[56];\n  reds(w, o);\n  int32_t s, mx, mn; int8_t bs, bmn; uint8_t bmx; int16_t hs; int64_t ds; int32_t ps, pm;\n  memcpy(&s, o, 4); memcpy(&mx, o + 4, 4); memcpy(&mn, o + 8, 4);\n  memcpy(&bs, o + 12, 1); memcpy(&bmn, o + 13, 1); memcpy(&bmx, o + 14, 1);\n  memcpy(&hs, o + 16, 2); memcpy(&ds, o + 24, 8); memcpy(&ps, o + 32, 4); memcpy(&pm, o + 36, 4);\n  if (s != 64 || mx != 100 || mn != 7) return 1;\n  const uint8_t *b = (const uint8_t *)w;\n  int bsum = 0, bmin = 127, bmax = 0;\n  for (int i = 0; i < 16; i++) { bsum += b[i]; if ((int8_t)b[i] < bmin) bmin = (int8_t)b[i]; if (b[i] > bmax) bmax = b[i]; }\n  if (bs != (int8_t)bsum || bmn != bmin || bmx != bmax) return 2;\n  const int16_t *h = (const int16_t *)w;\n  int hsum = 0;\n  for (int i = 0; i < 8; i++) hsum += h[i];\n  if (hs != (int16_t)hsum) return 3;\n  const int64_t *d = (const int64_t *)w;\n  if (ds != (int64_t)((uint64_t)d[0] + (uint64_t)d[1])) return 4;\n  if (ps != 4 || pm != 7) return 5;\n  int32_t ra; uint8_t ro; int16_t rx; int64_t rq;\n  memcpy(&ra, o + 40, 4); memcpy(&ro, o + 44, 1); memcpy(&rx, o + 46, 2); memcpy(&rq, o + 48, 8);\n  if (ra != (w[0] & w[1] & w[2] & w[3])) return 6;\n  uint8_t bo = 0; for (int i = 0; i < 16; i++) bo |= b[i];\n  if (ro != bo) return 7;\n  int16_t hx = 0; for (int i = 0; i < 8; i++) hx ^= h[i];\n  if (rx != hx) return 8;\n  if (rq != (d[0] ^ d[1])) return 9;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// The minimum and maximum of a vector's integer lanes and the lanes' minimum and maximum of two vectors,
// signed and unsigned, of every lane width (x86-64: `pminsw`, `pmaxub`, SSE4.1's and AVX2's `pmin`/`pmax`
// (`pmaxud` in the SSE4.1 object), else a `pcmpgt` mask; 64-bit lanes by one `cmov`), in xmm and in ymm
// registers.
@test
fn vector_minimums_and_maximums_of_every_lane_width_run() {
    let lir = M"(lir ptr 8
sym @mm fn global
fn @mm
  sig (ptr, ptr, ptr) -> void
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.v16i8 v0 align 0
  v4 = load.v16i8 v1 align 0
  v5 = vop.reduce_min.s.i8 (v3)
  v6 = vop.reduce_max.s.i8 (v3)
  v7 = vop.reduce_min.i8 (v3)
  v8 = vop.reduce_max.i8 (v3)
  v9 = vop.min.s.v16i8 (v3, v4)
  v10 = vop.max.s.v16i8 (v3, v4)
  v11 = vop.min.v16i8 (v3, v4)
  v12 = vop.max.v16i8 (v3, v4)
  v13 = load.v8i16 v0 align 0
  v14 = load.v8i16 v1 align 0
  v15 = vop.reduce_min.s.i16 (v13)
  v16 = vop.reduce_max.s.i16 (v13)
  v17 = vop.reduce_min.i16 (v13)
  v18 = vop.reduce_max.i16 (v13)
  v19 = vop.min.s.v8i16 (v13, v14)
  v20 = vop.max.s.v8i16 (v13, v14)
  v21 = vop.min.v8i16 (v13, v14)
  v22 = vop.max.v8i16 (v13, v14)
  v23 = load.v4i32 v0 align 0
  v24 = load.v4i32 v1 align 0
  v25 = vop.reduce_min.s.i32 (v23)
  v26 = vop.reduce_max.s.i32 (v23)
  v27 = vop.reduce_min.i32 (v23)
  v28 = vop.reduce_max.i32 (v23)
  v29 = vop.min.s.v4i32 (v23, v24)
  v30 = vop.max.s.v4i32 (v23, v24)
  v31 = vop.min.v4i32 (v23, v24)
  v32 = vop.max.v4i32 (v23, v24)
  v33 = load.v2i64 v0 align 0
  v34 = load.v2i64 v1 align 0
  v35 = vop.reduce_min.s.i64 (v33)
  v36 = vop.reduce_max.s.i64 (v33)
  v37 = vop.reduce_min.i64 (v33)
  v38 = vop.reduce_max.i64 (v33)
  store v5, v2+0 align 0
  store v6, v2+8 align 0
  store v7, v2+16 align 0
  store v8, v2+24 align 0
  store v9, v2+128 align 0
  store v10, v2+144 align 0
  store v11, v2+160 align 0
  store v12, v2+176 align 0
  store v15, v2+32 align 0
  store v16, v2+40 align 0
  store v17, v2+48 align 0
  store v18, v2+56 align 0
  store v19, v2+192 align 0
  store v20, v2+208 align 0
  store v21, v2+224 align 0
  store v22, v2+240 align 0
  store v25, v2+64 align 0
  store v26, v2+72 align 0
  store v27, v2+80 align 0
  store v28, v2+88 align 0
  store v29, v2+256 align 0
  store v30, v2+272 align 0
  store v31, v2+288 align 0
  store v32, v2+304 align 0
  store v35, v2+96 align 0
  store v36, v2+104 align 0
  store v37, v2+112 align 0
  store v38, v2+120 align 0
  ret
)";
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(lir, tgt::axis_index("linux", false), tgt::axis_index("x86_64", true), SSE41, &mut obj),
        "the SSE4.1 object",
    );
    let mut pmaxud = false;
    for x in 0..obj.len() - 3 {
        pmaxud = pmaxud || obj[x] == 0x66 && obj[x + 1] == 0x0F && obj[x + 2] == 0x38 && obj[x + 3] == 0x3F;
    }
    assert(pmaxud, "pmaxud");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = "#include <stdint.h>\n#include <string.h>\nvoid mm(const void *, const void *, void *);\n#define RED(T, n, at) { T x[n]; memcpy(x, a, 16); T lo = x[0], hi = x[0]; for (int i = 1; i < n; i++) { if (x[i] < lo) lo = x[i]; if (x[i] > hi) hi = x[i]; } T r0, r1; memcpy(&r0, o + at, sizeof(T)); memcpy(&r1, o + at + 8, sizeof(T)); if (r0 != lo || r1 != hi) return at / 8 + 1; }\n#define LANE(T, n, at) { T x[n], y[n], r[n]; memcpy(x, a, 16); memcpy(y, b, 16); memcpy(r, o + at, 16); for (int i = 0; i < n; i++) if (r[i] != (x[i] < y[i] ? x[i] : y[i])) return at / 16 + 40; memcpy(r, o + at + 16, 16); for (int i = 0; i < n; i++) if (r[i] != (x[i] > y[i] ? x[i] : y[i])) return at / 16 + 60; }\nint main(void) {\n  unsigned char a[16], b[16], o[320];\n  for (int i = 0; i < 16; i++) { a[i] = (unsigned char)(i * 73 + 129); b[i] = (unsigned char)(i * 151 + 7); }\n  mm(a, b, o);\n  RED(int8_t, 16, 0) RED(uint8_t, 16, 16) RED(int16_t, 8, 32) RED(uint16_t, 8, 48)\n  RED(int32_t, 4, 64) RED(uint32_t, 4, 80) RED(int64_t, 2, 96) RED(uint64_t, 2, 112)\n  LANE(int8_t, 16, 128) LANE(uint8_t, 16, 160) LANE(int16_t, 8, 192) LANE(uint16_t, 8, 224)\n  LANE(int32_t, 4, 256) LANE(uint32_t, 4, 288)\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wide(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
    let wide = M"(lir ptr 8
sym @mm fn global
fn @mm
  sig (ptr, ptr, ptr) -> void
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.v32i8 v0 align 0
  v4 = load.v32i8 v1 align 0
  v5 = vop.min.s.v32i8 (v3, v4)
  v6 = vop.max.s.v32i8 (v3, v4)
  v7 = vop.min.v32i8 (v3, v4)
  v8 = vop.max.v32i8 (v3, v4)
  v9 = load.v16i16 v0 align 0
  v10 = load.v16i16 v1 align 0
  v11 = vop.min.s.v16i16 (v9, v10)
  v12 = vop.max.s.v16i16 (v9, v10)
  v13 = vop.min.v16i16 (v9, v10)
  v14 = vop.max.v16i16 (v9, v10)
  v15 = load.v8i32 v0 align 0
  v16 = load.v8i32 v1 align 0
  v17 = vop.min.s.v8i32 (v15, v16)
  v18 = vop.max.s.v8i32 (v15, v16)
  v19 = vop.min.v8i32 (v15, v16)
  v20 = vop.max.v8i32 (v15, v16)
  store v5, v2+0 align 0
  store v6, v2+32 align 0
  store v7, v2+64 align 0
  store v8, v2+96 align 0
  store v11, v2+128 align 0
  store v12, v2+160 align 0
  store v13, v2+192 align 0
  store v14, v2+224 align 0
  store v17, v2+256 align 0
  store v18, v2+288 align 0
  store v19, v2+320 align 0
  store v20, v2+352 align 0
  ret
)";
    let wdrv = "#include <stdint.h>\n#include <string.h>\nvoid mm(const void *, const void *, void *);\n#define LANE(T, n, at) { T x[n], y[n], r[n]; memcpy(x, a, 32); memcpy(y, b, 32); memcpy(r, o + at, 32); for (int i = 0; i < n; i++) if (r[i] != (x[i] < y[i] ? x[i] : y[i])) return at / 32 + 1; memcpy(r, o + at + 32, 32); for (int i = 0; i < n; i++) if (r[i] != (x[i] > y[i] ? x[i] : y[i])) return at / 32 + 20; }\nint main(void) {\n  unsigned char a[32], b[32], o[384];\n  for (int i = 0; i < 32; i++) { a[i] = (unsigned char)(i * 73 + 129); b[i] = (unsigned char)(i * 151 + 7); }\n  mm(a, b, o);\n  LANE(int8_t, 32, 0) LANE(uint8_t, 32, 64) LANE(int16_t, 16, 128) LANE(uint16_t, 16, 192)\n  LANE(int32_t, 8, 256) LANE(uint32_t, 8, 320)\n  return 0;\n}\n";
    assert_eq(run_wide(wide, wdrv), 0);
}

// Whether any lane of an 8-byte lane mask is set (`vop.reduce_or` compared with 0): arm64's UMAXV takes 8
// and 16-bit lanes, two 32-bit lanes another form.
@test
fn any_lane_of_a_narrow_mask_runs() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @anyn fn global
fn @anyn
  sig (ptr, ptr) -> i32
b0(v0: ptr, v1: ptr):
  v2 = iconst.i32 0
  v3 = load.v8i8 v0 align 0
  v4 = load.v8i8 v1 align 0
  v5 = vcmp.eq.v8i8 v3, v4
  v6 = vcmp.ult.v8i8 v3, v4
  v7 = or.v8i8 v5, v6
  v8 = vop.reduce_or.i8 (v5)
  v9 = iconst.i8 0
  v10 = icmp.ne v8, v9
  v11 = vop.reduce_or.i8 (v7)
  v12 = iconst.i8 0
  v13 = icmp.ne v11, v12
  v14 = load.v4i16 v0 align 0
  v15 = load.v4i16 v1 align 0
  v16 = vcmp.eq.v4i16 v14, v15
  v17 = vcmp.ult.v4i16 v14, v15
  v18 = or.v4i16 v16, v17
  v19 = vop.reduce_or.i16 (v16)
  v20 = iconst.i16 0
  v21 = icmp.ne v19, v20
  v22 = vop.reduce_or.i16 (v18)
  v23 = iconst.i16 0
  v24 = icmp.ne v22, v23
  v25 = load.v2i32 v0 align 0
  v26 = load.v2i32 v1 align 0
  v27 = vcmp.eq.v2i32 v25, v26
  v28 = vcmp.ult.v2i32 v25, v26
  v29 = or.v2i32 v27, v28
  v30 = vop.reduce_or.i32 (v27)
  v31 = iconst.i32 0
  v32 = icmp.ne v30, v31
  v33 = vop.reduce_or.i32 (v29)
  v34 = iconst.i32 0
  v35 = icmp.ne v33, v34
  v36 = zext.i32 v10
  v37 = iconst.i32 0
  v38 = shl.i32 v36, v37
  v39 = or.i32 v2, v38
  v40 = zext.i32 v13
  v41 = iconst.i32 1
  v42 = shl.i32 v40, v41
  v43 = or.i32 v39, v42
  v44 = zext.i32 v21
  v45 = iconst.i32 2
  v46 = shl.i32 v44, v45
  v47 = or.i32 v43, v46
  v48 = zext.i32 v24
  v49 = iconst.i32 3
  v50 = shl.i32 v48, v49
  v51 = or.i32 v47, v50
  v52 = zext.i32 v32
  v53 = iconst.i32 4
  v54 = shl.i32 v52, v53
  v55 = or.i32 v51, v54
  v56 = zext.i32 v35
  v57 = iconst.i32 5
  v58 = shl.i32 v56, v57
  v59 = or.i32 v55, v58
  ret v59
)";
    let drv = "#include <stdint.h>\n#include <string.h>\nint32_t anyn(const void *, const void *);\n#define T(U, at) { U x[8 / sizeof(U)], y[8 / sizeof(U)]; memcpy(x, a, 8); memcpy(y, b, 8); int e = 0, o = 0; for (unsigned i = 0; i < 8 / sizeof(U); i++) { e |= x[i] == y[i]; o |= x[i] < y[i] || x[i] == y[i]; } want |= e << at | o << (at + 1); }\nstatic int check(const unsigned char *a, const unsigned char *b) {\n  int want = 0;\n  T(uint8_t, 0) T(uint16_t, 2) T(uint32_t, 4)\n  return anyn(a, b) == want;\n}\nint main(void) {\n  unsigned char a[8], b[8];\n  for (int i = 0; i < 8; i++) { a[i] = (unsigned char)(i * 37 + 3); b[i] = a[i]; }\n  if (!check(a, b)) return 1;\n  for (int i = 0; i < 8; i++) b[i] = (unsigned char)(a[i] - 1);\n  if (!check(a, b)) return 2;\n  b[7] = a[7];\n  if (!check(a, b)) return 3;\n  b[7] = (unsigned char)(a[7] + 1);\n  if (!check(a, b)) return 4;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_sse41(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Whether any lane of a lane mask is set (`vop.reduce_or` compared with 0) of comparisons of every lane
// width and their `and`, `or` and `xor` (x86-64: `pmovmskb` and `test`, AVX2's `vpmovmskb` for 32 bytes).
@test
fn any_lane_of_a_mask_runs() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @anyl fn global
fn @anyl
  sig (ptr, ptr) -> i32
b0(v0: ptr, v1: ptr):
  v2 = iconst.i32 0
  v3 = iconst.i32 1
  v4 = load.v16i8 v0 align 0
  v5 = load.v16i8 v1 align 0
  v6 = vcmp.eq.v16i8 v4, v5
  v7 = vcmp.sgt.v16i8 v4, v5
  v8 = vcmp.ult.v16i8 v4, v5
  v9 = and.v16i8 v6, v7
  v10 = or.v16i8 v8, v6
  v11 = xor.v16i8 v6, v7
  v12 = vop.reduce_or.i8 (v6)
  v13 = iconst.i8 0
  v14 = icmp.ne v12, v13
  v15 = vop.reduce_or.i8 (v9)
  v16 = iconst.i8 0
  v17 = icmp.ne v15, v16
  v18 = vop.reduce_or.i8 (v10)
  v19 = iconst.i8 0
  v20 = icmp.ne v18, v19
  v21 = vop.reduce_or.i8 (v11)
  v22 = iconst.i8 0
  v23 = icmp.ne v21, v22
  v24 = load.v8i16 v0 align 0
  v25 = load.v8i16 v1 align 0
  v26 = vcmp.eq.v8i16 v24, v25
  v27 = vcmp.sgt.v8i16 v24, v25
  v28 = vcmp.ult.v8i16 v24, v25
  v29 = and.v8i16 v26, v27
  v30 = or.v8i16 v28, v26
  v31 = xor.v8i16 v26, v27
  v32 = vop.reduce_or.i16 (v26)
  v33 = iconst.i16 0
  v34 = icmp.ne v32, v33
  v35 = vop.reduce_or.i16 (v29)
  v36 = iconst.i16 0
  v37 = icmp.ne v35, v36
  v38 = vop.reduce_or.i16 (v30)
  v39 = iconst.i16 0
  v40 = icmp.ne v38, v39
  v41 = vop.reduce_or.i16 (v31)
  v42 = iconst.i16 0
  v43 = icmp.ne v41, v42
  v44 = load.v4i32 v0 align 0
  v45 = load.v4i32 v1 align 0
  v46 = vcmp.eq.v4i32 v44, v45
  v47 = vcmp.sgt.v4i32 v44, v45
  v48 = vcmp.ult.v4i32 v44, v45
  v49 = and.v4i32 v46, v47
  v50 = or.v4i32 v48, v46
  v51 = xor.v4i32 v46, v47
  v52 = vop.reduce_or.i32 (v46)
  v53 = iconst.i32 0
  v54 = icmp.ne v52, v53
  v55 = vop.reduce_or.i32 (v49)
  v56 = iconst.i32 0
  v57 = icmp.ne v55, v56
  v58 = vop.reduce_or.i32 (v50)
  v59 = iconst.i32 0
  v60 = icmp.ne v58, v59
  v61 = vop.reduce_or.i32 (v51)
  v62 = iconst.i32 0
  v63 = icmp.ne v61, v62
  v64 = load.v2i64 v0 align 0
  v65 = load.v2i64 v1 align 0
  v66 = vcmp.eq.v2i64 v64, v65
  v67 = vcmp.sgt.v2i64 v64, v65
  v68 = vcmp.ult.v2i64 v64, v65
  v69 = and.v2i64 v66, v67
  v70 = or.v2i64 v68, v66
  v71 = xor.v2i64 v66, v67
  v72 = vop.reduce_or.i64 (v66)
  v73 = iconst.i64 0
  v74 = icmp.ne v72, v73
  v75 = vop.reduce_or.i64 (v69)
  v76 = iconst.i64 0
  v77 = icmp.ne v75, v76
  v78 = vop.reduce_or.i64 (v70)
  v79 = iconst.i64 0
  v80 = icmp.ne v78, v79
  v81 = vop.reduce_or.i64 (v71)
  v82 = iconst.i64 0
  v83 = icmp.ne v81, v82
  v84 = zext.i32 v14
  v85 = iconst.i32 0
  v86 = shl.i32 v84, v85
  v87 = or.i32 v2, v86
  v88 = zext.i32 v17
  v89 = iconst.i32 1
  v90 = shl.i32 v88, v89
  v91 = or.i32 v87, v90
  v92 = zext.i32 v20
  v93 = iconst.i32 2
  v94 = shl.i32 v92, v93
  v95 = or.i32 v91, v94
  v96 = zext.i32 v23
  v97 = iconst.i32 3
  v98 = shl.i32 v96, v97
  v99 = or.i32 v95, v98
  v100 = zext.i32 v34
  v101 = iconst.i32 4
  v102 = shl.i32 v100, v101
  v103 = or.i32 v99, v102
  v104 = zext.i32 v37
  v105 = iconst.i32 5
  v106 = shl.i32 v104, v105
  v107 = or.i32 v103, v106
  v108 = zext.i32 v40
  v109 = iconst.i32 6
  v110 = shl.i32 v108, v109
  v111 = or.i32 v107, v110
  v112 = zext.i32 v43
  v113 = iconst.i32 7
  v114 = shl.i32 v112, v113
  v115 = or.i32 v111, v114
  v116 = zext.i32 v54
  v117 = iconst.i32 8
  v118 = shl.i32 v116, v117
  v119 = or.i32 v115, v118
  v120 = zext.i32 v57
  v121 = iconst.i32 9
  v122 = shl.i32 v120, v121
  v123 = or.i32 v119, v122
  v124 = zext.i32 v60
  v125 = iconst.i32 10
  v126 = shl.i32 v124, v125
  v127 = or.i32 v123, v126
  v128 = zext.i32 v63
  v129 = iconst.i32 11
  v130 = shl.i32 v128, v129
  v131 = or.i32 v127, v130
  v132 = zext.i32 v74
  v133 = iconst.i32 12
  v134 = shl.i32 v132, v133
  v135 = or.i32 v131, v134
  v136 = zext.i32 v77
  v137 = iconst.i32 13
  v138 = shl.i32 v136, v137
  v139 = or.i32 v135, v138
  v140 = zext.i32 v80
  v141 = iconst.i32 14
  v142 = shl.i32 v140, v141
  v143 = or.i32 v139, v142
  v144 = iconst.i32 32768
  br v83, b1, b2
b1:
  v145 = or.i32 v143, v144
  ret v145
b2:
  ret v143
)";
    let drv = "#include <stdint.h>\n#include <string.h>\nint32_t anyl(const void *, const void *);\n#define T(S, U, at) { S x[16 / sizeof(S)], y[16 / sizeof(S)]; memcpy(x, a, 16); memcpy(y, b, 16); int e = 0, n = 0, o = 0, q = 0; for (unsigned i = 0; i < 16 / sizeof(S); i++) { int eq = x[i] == y[i], gt = x[i] > y[i]; e |= eq; n |= eq && gt; o |= (U)x[i] < (U)y[i] || eq; q |= eq != gt; } want |= e << at | n << (at + 1) | o << (at + 2) | q << (at + 3); }\nstatic int check(const unsigned char *a, const unsigned char *b) {\n  int want = 0;\n  T(int8_t, uint8_t, 0) T(int16_t, uint16_t, 4) T(int32_t, uint32_t, 8) T(int64_t, uint64_t, 12)\n  return anyl(a, b) == want;\n}\nint main(void) {\n  unsigned char a[16], b[16];\n  for (int i = 0; i < 16; i++) { a[i] = (unsigned char)(i * 37 + 3); b[i] = (unsigned char)(i * 37 + 3); }\n  if (!check(a, b)) return 1;\n  for (int i = 0; i < 16; i++) b[i] = (unsigned char)(a[i] + 1);\n  if (!check(a, b)) return 2;\n  b[16 - 1] = a[16 - 1];\n  if (!check(a, b)) return 3;\n  for (int i = 0; i < 16; i++) b[i] = (unsigned char)(a[i] - 1);\n  if (!check(a, b)) return 4;\n  b[0] = 0x80; a[0] = 0x7F;\n  if (!check(a, b)) return 5;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wide(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
    let wide = M"(lir ptr 8
sym @anyl fn global
fn @anyl
  sig (ptr, ptr) -> i32
b0(v0: ptr, v1: ptr):
  v2 = iconst.i32 0
  v3 = iconst.i32 1
  v4 = load.v32i8 v0 align 0
  v5 = load.v32i8 v1 align 0
  v6 = vcmp.eq.v32i8 v4, v5
  v7 = vcmp.sgt.v32i8 v4, v5
  v8 = vcmp.ult.v32i8 v4, v5
  v9 = and.v32i8 v6, v7
  v10 = or.v32i8 v8, v6
  v11 = xor.v32i8 v6, v7
  v12 = vop.reduce_or.i8 (v6)
  v13 = iconst.i8 0
  v14 = icmp.ne v12, v13
  v15 = vop.reduce_or.i8 (v9)
  v16 = iconst.i8 0
  v17 = icmp.ne v15, v16
  v18 = vop.reduce_or.i8 (v10)
  v19 = iconst.i8 0
  v20 = icmp.ne v18, v19
  v21 = vop.reduce_or.i8 (v11)
  v22 = iconst.i8 0
  v23 = icmp.ne v21, v22
  v24 = load.v16i16 v0 align 0
  v25 = load.v16i16 v1 align 0
  v26 = vcmp.eq.v16i16 v24, v25
  v27 = vcmp.sgt.v16i16 v24, v25
  v28 = vcmp.ult.v16i16 v24, v25
  v29 = and.v16i16 v26, v27
  v30 = or.v16i16 v28, v26
  v31 = xor.v16i16 v26, v27
  v32 = vop.reduce_or.i16 (v26)
  v33 = iconst.i16 0
  v34 = icmp.ne v32, v33
  v35 = vop.reduce_or.i16 (v29)
  v36 = iconst.i16 0
  v37 = icmp.ne v35, v36
  v38 = vop.reduce_or.i16 (v30)
  v39 = iconst.i16 0
  v40 = icmp.ne v38, v39
  v41 = vop.reduce_or.i16 (v31)
  v42 = iconst.i16 0
  v43 = icmp.ne v41, v42
  v44 = load.v8i32 v0 align 0
  v45 = load.v8i32 v1 align 0
  v46 = vcmp.eq.v8i32 v44, v45
  v47 = vcmp.sgt.v8i32 v44, v45
  v48 = vcmp.ult.v8i32 v44, v45
  v49 = and.v8i32 v46, v47
  v50 = or.v8i32 v48, v46
  v51 = xor.v8i32 v46, v47
  v52 = vop.reduce_or.i32 (v46)
  v53 = iconst.i32 0
  v54 = icmp.ne v52, v53
  v55 = vop.reduce_or.i32 (v49)
  v56 = iconst.i32 0
  v57 = icmp.ne v55, v56
  v58 = vop.reduce_or.i32 (v50)
  v59 = iconst.i32 0
  v60 = icmp.ne v58, v59
  v61 = vop.reduce_or.i32 (v51)
  v62 = iconst.i32 0
  v63 = icmp.ne v61, v62
  v64 = load.v4i64 v0 align 0
  v65 = load.v4i64 v1 align 0
  v66 = vcmp.eq.v4i64 v64, v65
  v67 = vcmp.sgt.v4i64 v64, v65
  v68 = vcmp.ult.v4i64 v64, v65
  v69 = and.v4i64 v66, v67
  v70 = or.v4i64 v68, v66
  v71 = xor.v4i64 v66, v67
  v72 = vop.reduce_or.i64 (v66)
  v73 = iconst.i64 0
  v74 = icmp.ne v72, v73
  v75 = vop.reduce_or.i64 (v69)
  v76 = iconst.i64 0
  v77 = icmp.ne v75, v76
  v78 = vop.reduce_or.i64 (v70)
  v79 = iconst.i64 0
  v80 = icmp.ne v78, v79
  v81 = vop.reduce_or.i64 (v71)
  v82 = iconst.i64 0
  v83 = icmp.ne v81, v82
  v84 = zext.i32 v14
  v85 = iconst.i32 0
  v86 = shl.i32 v84, v85
  v87 = or.i32 v2, v86
  v88 = zext.i32 v17
  v89 = iconst.i32 1
  v90 = shl.i32 v88, v89
  v91 = or.i32 v87, v90
  v92 = zext.i32 v20
  v93 = iconst.i32 2
  v94 = shl.i32 v92, v93
  v95 = or.i32 v91, v94
  v96 = zext.i32 v23
  v97 = iconst.i32 3
  v98 = shl.i32 v96, v97
  v99 = or.i32 v95, v98
  v100 = zext.i32 v34
  v101 = iconst.i32 4
  v102 = shl.i32 v100, v101
  v103 = or.i32 v99, v102
  v104 = zext.i32 v37
  v105 = iconst.i32 5
  v106 = shl.i32 v104, v105
  v107 = or.i32 v103, v106
  v108 = zext.i32 v40
  v109 = iconst.i32 6
  v110 = shl.i32 v108, v109
  v111 = or.i32 v107, v110
  v112 = zext.i32 v43
  v113 = iconst.i32 7
  v114 = shl.i32 v112, v113
  v115 = or.i32 v111, v114
  v116 = zext.i32 v54
  v117 = iconst.i32 8
  v118 = shl.i32 v116, v117
  v119 = or.i32 v115, v118
  v120 = zext.i32 v57
  v121 = iconst.i32 9
  v122 = shl.i32 v120, v121
  v123 = or.i32 v119, v122
  v124 = zext.i32 v60
  v125 = iconst.i32 10
  v126 = shl.i32 v124, v125
  v127 = or.i32 v123, v126
  v128 = zext.i32 v63
  v129 = iconst.i32 11
  v130 = shl.i32 v128, v129
  v131 = or.i32 v127, v130
  v132 = zext.i32 v74
  v133 = iconst.i32 12
  v134 = shl.i32 v132, v133
  v135 = or.i32 v131, v134
  v136 = zext.i32 v77
  v137 = iconst.i32 13
  v138 = shl.i32 v136, v137
  v139 = or.i32 v135, v138
  v140 = zext.i32 v80
  v141 = iconst.i32 14
  v142 = shl.i32 v140, v141
  v143 = or.i32 v139, v142
  v144 = iconst.i32 32768
  br v83, b1, b2
b1:
  v145 = or.i32 v143, v144
  ret v145
b2:
  ret v143
)";
    let wdrv = "#include <stdint.h>\n#include <string.h>\nint32_t anyl(const void *, const void *);\n#define T(S, U, at) { S x[32 / sizeof(S)], y[32 / sizeof(S)]; memcpy(x, a, 32); memcpy(y, b, 32); int e = 0, n = 0, o = 0, q = 0; for (unsigned i = 0; i < 32 / sizeof(S); i++) { int eq = x[i] == y[i], gt = x[i] > y[i]; e |= eq; n |= eq && gt; o |= (U)x[i] < (U)y[i] || eq; q |= eq != gt; } want |= e << at | n << (at + 1) | o << (at + 2) | q << (at + 3); }\nstatic int check(const unsigned char *a, const unsigned char *b) {\n  int want = 0;\n  T(int8_t, uint8_t, 0) T(int16_t, uint16_t, 4) T(int32_t, uint32_t, 8) T(int64_t, uint64_t, 12)\n  return anyl(a, b) == want;\n}\nint main(void) {\n  unsigned char a[32], b[32];\n  for (int i = 0; i < 32; i++) { a[i] = (unsigned char)(i * 37 + 3); b[i] = (unsigned char)(i * 37 + 3); }\n  if (!check(a, b)) return 1;\n  for (int i = 0; i < 32; i++) b[i] = (unsigned char)(a[i] + 1);\n  if (!check(a, b)) return 2;\n  b[32 - 1] = a[32 - 1];\n  if (!check(a, b)) return 3;\n  for (int i = 0; i < 32; i++) b[i] = (unsigned char)(a[i] - 1);\n  if (!check(a, b)) return 4;\n  b[0] = 0x80; a[0] = 0x7F;\n  if (!check(a, b)) return 5;\n  return 0;\n}\n";
    assert_eq(run_wide(wide, wdrv), 0);
}

// A vector difference whose second operand dies there while the first lives on (x86-64: the result may
// take the second's register only for an operation that commutes).
@test
fn a_vector_difference_whose_second_operand_dies_runs() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @vdiff fn global
fn @vdiff
  sig (ptr, ptr, ptr) -> void
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.v2i64 v0 align 3
  v4 = load.v2i64 v1 align 3
  v5 = vop.wrapping_sub.v2i64 (v3, v4)
  v6 = vop.wrapping_add.v2i64 (v3, v5)
  store v6, v2 align 3
  store v5, v2+16 align 3
  ret
)";
    let drv = "#include <stdint.h>\nvoid vdiff(const int64_t *, const int64_t *, int64_t *);\nint main(void) {\n  int64_t a[2] = {1000003, -77}, b[2] = {5, 900000000001}, o[4];\n  vdiff(a, b, o);\n  for (int i = 0; i < 2; i++) { if (o[2 + i] != a[i] - b[i] || o[i] != a[i] + (a[i] - b[i])) return 1 + i; }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A loop's vector accumulator added to a load that dies there, the accumulator first and second (x86-64:
// the sum takes the accumulator's register or the load's, `def_shared` and `def_over`).
@test
fn a_vector_accumulator_and_a_dying_load_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @vsum fn global
fn @vsum
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = wconst.v2i64 0x0, 0x0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3, v2, v2)
b1(v5: i64, v6: v2i64, v7: v2i64):
  v8 = ptradd v0, v5 * 16
  v9 = load.v2i64 v8 align 3
  v10 = load.v2i64 v8 align 3
  v11 = add.v2i64 v6, v9
  v12 = xor.v2i64 v10, v7
  v13 = add.i64 v5, v4
  v14 = icmp.ult v13, v1
  br v14, b1(v13, v11, v12), b2
b2:
  v15 = vop.reduce_add.i64 (v11)
  v16 = vop.reduce_xor.i64 (v12)
  v17 = add.i64 v15, v16
  ret v17
)";
    let drv = "#include <stdint.h>\nint64_t vsum(const int64_t *, int64_t);\nint main(void) {\n  int64_t a[10];\n  int64_t s = 0, x = 0;\n  for (int i = 0; i < 10; i++) { a[i] = (int64_t)i * 1000003 - 7; s += a[i]; x ^= a[i]; }\n  if (vsum(a, 5) != s + x) return 1;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// Vector shifts of every lane by one constant (a splat of a constant, or a wide constant of equal lanes),
// left, logical and arithmetic, of 2-, 4- and 8-byte lanes (x86-64: SSE2's `psll`, `psrl`, `psra` by an
// immediate; AVX2's for 32 bytes).
@test
fn vector_shifts_by_a_constant_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @sh fn global
fn @sh
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = load.v8i16 v0 align 0
  v3 = iconst.i16 5
  v4 = splat.v8i16 v3
  v5 = wconst.v8i16 0x6000600060006, 0x6000600060006
  v6 = shl.v8i16 v2, v4
  v7 = lshr.v8i16 v2, v4
  v8 = shl.v8i16 v2, v5
  v9 = lshr.v8i16 v2, v5
  v10 = ashr.v8i16 v2, v4
  v11 = ashr.v8i16 v2, v5
  v12 = load.v4i32 v0 align 0
  v13 = iconst.i32 13
  v14 = splat.v4i32 v13
  v15 = wconst.v4i32 0xe0000000e, 0xe0000000e
  v16 = shl.v4i32 v12, v14
  v17 = lshr.v4i32 v12, v14
  v18 = shl.v4i32 v12, v15
  v19 = lshr.v4i32 v12, v15
  v20 = ashr.v4i32 v12, v14
  v21 = ashr.v4i32 v12, v15
  v22 = load.v2i64 v0 align 0
  v23 = iconst.i64 37
  v24 = splat.v2i64 v23
  v25 = wconst.v2i64 0x26, 0x26
  v26 = shl.v2i64 v22, v24
  v27 = lshr.v2i64 v22, v24
  v28 = shl.v2i64 v22, v25
  v29 = lshr.v2i64 v22, v25
  store v6, v1+0 align 0
  store v7, v1+16 align 0
  store v8, v1+32 align 0
  store v9, v1+48 align 0
  store v10, v1+64 align 0
  store v11, v1+80 align 0
  store v16, v1+96 align 0
  store v17, v1+112 align 0
  store v18, v1+128 align 0
  store v19, v1+144 align 0
  store v20, v1+160 align 0
  store v21, v1+176 align 0
  store v26, v1+192 align 0
  store v27, v1+208 align 0
  store v28, v1+224 align 0
  store v29, v1+240 align 0
  ret
)";
    let drv = "#include <stdint.h>\n#include <string.h>\nvoid sh(const void *, void *);\n#define CHK(S, U, k, n) { S x[16 / sizeof(S)], r[16 / sizeof(S)]; memcpy(x, a, 16); \\\n  for (int j = 0; j < n; j++) { int s = j < 2 || j == 4 ? k : k + 1; int op = j % 2; if (j >= 4) op = 2; \\\n    memcpy(r, o + off, 16); off += 16; \\\n    for (unsigned i = 0; i < 16 / sizeof(S); i++) { S want = op == 0 ? (S)((U)x[i] << s) : op == 1 ? (S)((U)x[i] >> s) : (S)(x[i] >> s); \\\n      if (r[i] != want) return 1 + j; } } }\nint main(void) {\n  unsigned char a[16], o[16 * 16];\n  for (int i = 0; i < 16; i++) a[i] = (unsigned char)(i * 89 + 151);\n  sh(a, o);\n  int off = 0;\n  CHK(int16_t, uint16_t, 5, 6) CHK(int32_t, uint32_t, 13, 6) CHK(int64_t, uint64_t, 37, 4)\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wide(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
    let wide = M"(lir ptr 8
sym @sh fn global
fn @sh
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = load.v16i16 v0 align 0
  v3 = iconst.i16 5
  v4 = splat.v16i16 v3
  v5 = wconst.v16i16 0x6000600060006, 0x6000600060006, 0x6000600060006, 0x6000600060006
  v6 = shl.v16i16 v2, v4
  v7 = lshr.v16i16 v2, v4
  v8 = shl.v16i16 v2, v5
  v9 = lshr.v16i16 v2, v5
  v10 = ashr.v16i16 v2, v4
  v11 = ashr.v16i16 v2, v5
  v12 = load.v8i32 v0 align 0
  v13 = iconst.i32 13
  v14 = splat.v8i32 v13
  v15 = wconst.v8i32 0xe0000000e, 0xe0000000e, 0xe0000000e, 0xe0000000e
  v16 = shl.v8i32 v12, v14
  v17 = lshr.v8i32 v12, v14
  v18 = shl.v8i32 v12, v15
  v19 = lshr.v8i32 v12, v15
  v20 = ashr.v8i32 v12, v14
  v21 = ashr.v8i32 v12, v15
  v22 = load.v4i64 v0 align 0
  v23 = iconst.i64 37
  v24 = splat.v4i64 v23
  v25 = wconst.v4i64 0x26, 0x26, 0x26, 0x26
  v26 = shl.v4i64 v22, v24
  v27 = lshr.v4i64 v22, v24
  v28 = shl.v4i64 v22, v25
  v29 = lshr.v4i64 v22, v25
  store v6, v1+0 align 0
  store v7, v1+32 align 0
  store v8, v1+64 align 0
  store v9, v1+96 align 0
  store v10, v1+128 align 0
  store v11, v1+160 align 0
  store v16, v1+192 align 0
  store v17, v1+224 align 0
  store v18, v1+256 align 0
  store v19, v1+288 align 0
  store v20, v1+320 align 0
  store v21, v1+352 align 0
  store v26, v1+384 align 0
  store v27, v1+416 align 0
  store v28, v1+448 align 0
  store v29, v1+480 align 0
  ret
)";
    let wdrv = "#include <stdint.h>\n#include <string.h>\nvoid sh(const void *, void *);\n#define CHK(S, U, k, n) { S x[32 / sizeof(S)], r[32 / sizeof(S)]; memcpy(x, a, 32); \\\n  for (int j = 0; j < n; j++) { int s = j < 2 || j == 4 ? k : k + 1; int op = j % 2; if (j >= 4) op = 2; \\\n    memcpy(r, o + off, 32); off += 32; \\\n    for (unsigned i = 0; i < 32 / sizeof(S); i++) { S want = op == 0 ? (S)((U)x[i] << s) : op == 1 ? (S)((U)x[i] >> s) : (S)(x[i] >> s); \\\n      if (r[i] != want) return 1 + j; } } }\nint main(void) {\n  unsigned char a[32], o[16 * 32];\n  for (int i = 0; i < 32; i++) a[i] = (unsigned char)(i * 89 + 151);\n  sh(a, o);\n  int off = 0;\n  CHK(int16_t, uint16_t, 5, 6) CHK(int32_t, uint32_t, 13, 6) CHK(int64_t, uint64_t, 37, 4)\n  return 0;\n}\n";
    assert_eq(run_wide(wide, wdrv), 0);
}

// Switches whose dense cases all pass constants to one block read the values from a table: signed i8
// cases, i16 cases with a hole the default (elsewhere) takes, two columns (f64, i32), i64 cases from 2^40,
// i32 cases near the top of the unsigned range, f32 values whose holes take the default's, and twelve
// columns of every integer width.
@test
fn switches_whose_cases_pass_constants_read_tables_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @l8 fn global
sym @l16 fn global
sym @l32 fn global
sym @l64 fn global
sym @lu fn global
sym @lf fn global
sym @lm fn global
fn @l8
  sig (i8.s) -> i64
b0(v0: i8):
  v1 = iconst.i64 -3000016
  v2 = iconst.i64 -2000013
  v3 = iconst.i64 -1000010
  v4 = iconst.i64 -7
  v5 = iconst.i64 999996
  v6 = iconst.i64 1999999
  v7 = iconst.i64 3000002
  v8 = iconst.i64 77
  switch v0 [-3 -> b1(v1), -2 -> b1(v2), -1 -> b1(v3), 0 -> b1(v4), 1 -> b1(v5), 2 -> b1(v6), 3 -> b1(v7)] else b1(v8)
b1(v9: i64):
  ret v9
fn @l16
  sig (i16.s) -> i16
b0(v0: i16):
  v1 = iconst.i16 6500
  v2 = iconst.i16 6537
  v3 = iconst.i16 6574
  v4 = iconst.i16 6648
  v5 = iconst.i16 6685
  v6 = iconst.i16 6722
  v7 = iconst.i16 6759
  switch v0 [1000 -> b1(v1), 1001 -> b1(v2), 1002 -> b1(v3), 1004 -> b1(v4), 1005 -> b1(v5), 1006 -> b1(v6), 1007 -> b1(v7)] else b2
b1(v8: i16):
  ret v8
b2:
  v9 = iconst.i16 -1
  v10 = add.i16 v0, v9
  ret v10
fn @l32
  sig (i32) -> f64
b0(v0: i32):
  v1 = fconst.f64 0x4002000000000000
  v2 = iconst.i32 -5
  v3 = fconst.f64 0x4008000000000000
  v4 = iconst.i32 -2
  v5 = fconst.f64 0x400e000000000000
  v6 = iconst.i32 1
  v7 = fconst.f64 0x4012000000000000
  v8 = iconst.i32 4
  v9 = fconst.f64 0x4015000000000000
  v10 = iconst.i32 7
  v11 = fconst.f64 0x4018000000000000
  v12 = iconst.i32 10
  v13 = fconst.f64 0x3fe0000000000000
  v14 = iconst.i32 -7
  switch v0 [5 -> b1(v1, v2), 6 -> b1(v3, v4), 7 -> b1(v5, v6), 8 -> b1(v7, v8), 9 -> b1(v9, v10), 10 -> b1(v11, v12)] else b1(v13, v14)
b1(v15: f64, v16: i32):
  v17 = sitofp.f64 v16
  v18 = fadd.f64 v15, v17
  ret v18
fn @l64
  sig (i64) -> i32
b0(v0: i64):
  v1 = iconst.i32 -9
  v2 = iconst.i32 -8
  v3 = iconst.i32 -5
  v4 = iconst.i32 0
  v5 = iconst.i32 7
  v6 = iconst.i32 16
  v7 = iconst.i32 1234
  switch v0 [1099511627776 -> b1(v1), 1099511627777 -> b1(v2), 1099511627778 -> b1(v3), 1099511627779 -> b1(v4), 1099511627780 -> b1(v5), 1099511627781 -> b1(v6)] else b1(v7)
b1(v8: i32):
  ret v8
fn @lu
  sig (i32) -> i8
b0(v0: i32):
  v1 = iconst.i8 4
  v2 = iconst.i8 2
  v3 = iconst.i8 0
  v4 = iconst.i8 5
  v5 = iconst.i8 3
  v6 = iconst.i8 1
  v7 = iconst.i8 9
  switch v0 [-16 -> b1(v1), -15 -> b1(v2), -14 -> b1(v3), -13 -> b1(v4), -12 -> b1(v5), -11 -> b1(v6)] else b1(v7)
b1(v8: i8):
  ret v8
fn @lf
  sig (i32) -> f32
b0(v0: i32):
  v1 = fconst.f32 0x3f000000
  v2 = fconst.f32 0x3fe00000
  v3 = fconst.f32 0x40880000
  v4 = fconst.f32 0x40b00000
  v5 = fconst.f32 0x41000000
  v6 = fconst.f32 0x41140000
  v7 = fconst.f32 0xc0000000
  switch v0 [0 -> b1(v1), 1 -> b1(v2), 3 -> b1(v3), 4 -> b1(v4), 6 -> b1(v5), 7 -> b1(v6)] else b1(v7)
b1(v8: f32):
  ret v8
fn @lm
  sig (i32) -> i64
b0(v0: i32):
  v1 = iconst.i8 -1
  v2 = iconst.i16 12
  v3 = iconst.i32 25
  v4 = iconst.i64 38
  v5 = iconst.i8 51
  v6 = iconst.i16 -36
  v7 = iconst.i32 -23
  v8 = iconst.i64 -10
  v9 = iconst.i8 3
  v10 = iconst.i16 16
  v11 = iconst.i32 29
  v12 = iconst.i64 42
  v13 = iconst.i8 38
  v14 = iconst.i16 -36
  v15 = iconst.i32 -10
  v16 = iconst.i64 16
  v17 = iconst.i8 42
  v18 = iconst.i16 -32
  v19 = iconst.i32 -6
  v20 = iconst.i64 20
  v21 = iconst.i8 46
  v22 = iconst.i16 -28
  v23 = iconst.i32 -2
  v24 = iconst.i64 24
  v25 = iconst.i8 -23
  v26 = iconst.i16 16
  v27 = iconst.i32 55
  v28 = iconst.i64 -6
  v29 = iconst.i8 33
  v30 = iconst.i16 -28
  v31 = iconst.i32 11
  v32 = iconst.i64 50
  v33 = iconst.i8 -11
  v34 = iconst.i16 28
  v35 = iconst.i32 -33
  v36 = iconst.i64 6
  v37 = iconst.i8 16
  v38 = iconst.i16 -32
  v39 = iconst.i32 20
  v40 = iconst.i64 -28
  v41 = iconst.i8 24
  v42 = iconst.i16 -24
  v43 = iconst.i32 28
  v44 = iconst.i64 -20
  v45 = iconst.i8 32
  v46 = iconst.i16 -16
  v47 = iconst.i32 36
  v48 = iconst.i64 -12
  v49 = iconst.i8 55
  v50 = iconst.i16 20
  v51 = iconst.i32 -15
  v52 = iconst.i64 50
  v53 = iconst.i8 15
  v54 = iconst.i16 -20
  v55 = iconst.i32 45
  v56 = iconst.i64 10
  v57 = iconst.i8 -25
  v58 = iconst.i16 40
  v59 = iconst.i32 5
  v60 = iconst.i64 -30
  v61 = iconst.i8 -6
  v62 = iconst.i16 -5
  v63 = iconst.i32 -4
  v64 = iconst.i64 -3
  v65 = iconst.i8 -2
  v66 = iconst.i16 -1
  v67 = iconst.i32 0
  v68 = iconst.i64 1
  v69 = iconst.i8 2
  v70 = iconst.i16 3
  v71 = iconst.i32 4
  v72 = iconst.i64 5
  switch v0 [0 -> b1(v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12), 1 -> b1(v13, v14, v15, v16, v17, v18, v19, v20, v21, v22, v23, v24), 2 -> b1(v25, v26, v27, v28, v29, v30, v31, v32, v33, v34, v35, v36), 3 -> b1(v37, v38, v39, v40, v41, v42, v43, v44, v45, v46, v47, v48), 4 -> b1(v49, v50, v51, v52, v53, v54, v55, v56, v57, v58, v59, v60)] else b1(v61, v62, v63, v64, v65, v66, v67, v68, v69, v70, v71, v72)
b1(v73: i8, v74: i16, v75: i32, v76: i64, v77: i8, v78: i16, v79: i32, v80: i64, v81: i8, v82: i16, v83: i32, v84: i64):
  v85 = sext.i64 v73
  v86 = iconst.i64 1
  v87 = mul.i64 v85, v86
  v88 = sext.i64 v74
  v89 = iconst.i64 2
  v90 = mul.i64 v88, v89
  v91 = add.i64 v87, v90
  v92 = sext.i64 v75
  v93 = iconst.i64 3
  v94 = mul.i64 v92, v93
  v95 = add.i64 v91, v94
  v96 = iconst.i64 4
  v97 = mul.i64 v76, v96
  v98 = add.i64 v95, v97
  v99 = sext.i64 v77
  v100 = iconst.i64 5
  v101 = mul.i64 v99, v100
  v102 = add.i64 v98, v101
  v103 = sext.i64 v78
  v104 = iconst.i64 6
  v105 = mul.i64 v103, v104
  v106 = add.i64 v102, v105
  v107 = sext.i64 v79
  v108 = iconst.i64 7
  v109 = mul.i64 v107, v108
  v110 = add.i64 v106, v109
  v111 = iconst.i64 8
  v112 = mul.i64 v80, v111
  v113 = add.i64 v110, v112
  v114 = sext.i64 v81
  v115 = iconst.i64 9
  v116 = mul.i64 v114, v115
  v117 = add.i64 v113, v116
  v118 = sext.i64 v82
  v119 = iconst.i64 10
  v120 = mul.i64 v118, v119
  v121 = add.i64 v117, v120
  v122 = sext.i64 v83
  v123 = iconst.i64 11
  v124 = mul.i64 v122, v123
  v125 = add.i64 v121, v124
  v126 = iconst.i64 12
  v127 = mul.i64 v84, v126
  v128 = add.i64 v125, v127
  ret v128
)";
    let drv = "#include <stdint.h>\nint64_t l8(int8_t); int16_t l16(int16_t); double l32(int32_t); int32_t l64(int64_t); int8_t lu(int32_t); float lf(int32_t); int64_t lm(int32_t);\nint main(void) {\n  for (int x = -128; x < 128; x++) { int64_t w = 77; switch (x) { case -3: w = -3000016ll; break; case -2: w = -2000013ll; break; case -1: w = -1000010ll; break; case 0: w = -7ll; break; case 1: w = 999996ll; break; case 2: w = 1999999ll; break; case 3: w = 3000002ll; break; } if (l8((int8_t)x) != w) return 1; }\n  for (int x = 990; x < 1012; x++) { int16_t w = (int16_t)(x - 1); switch (x) { case 1000: w = 6500; break; case 1001: w = 6537; break; case 1002: w = 6574; break; case 1004: w = 6648; break; case 1005: w = 6685; break; case 1006: w = 6722; break; case 1007: w = 6759; break; } if (l16((int16_t)x) != w) return 2; }\n  if (l16(-32768) != 32767) return 2;\n  for (int x = -3; x < 14; x++) { double w = 0.5 - 7; switch (x) { case 5: w = 2.25 + -5; break; case 6: w = 3.0 + -2; break; case 7: w = 3.75 + 1; break; case 8: w = 4.5 + 4; break; case 9: w = 5.25 + 7; break; case 10: w = 6.0 + 10; break; } if (l32(x) != w) return 3; }\n  for (int64_t d = -3; d < 9; d++) { int64_t x = 1099511627776ll + d; int32_t w = 1234; if (d >= 0 && d < 6) w = (int32_t)(d * d - 9); if (l64(x) != w) return 4; }\n  if (l64(0) != 1234 || l64(-1) != 1234) return 4;\n  for (int x = -20; x < 4; x++) { int8_t w = 9; switch (x) { case -16: w = 4; break; case -15: w = 2; break; case -14: w = 0; break; case -13: w = 5; break; case -12: w = 3; break; case -11: w = 1; break; } if (lu(x) != w) return 5; }\n  if (lu(2147483647) != 9 || lu(-2147483647 - 1) != 9) return 5;\n  for (int x = -2; x < 10; x++) { float w = -2.0f; switch (x) { case 0: w = 0.5f; break; case 1: w = 1.75f; break; case 3: w = 4.25f; break; case 4: w = 5.5f; break; case 6: w = 8.0f; break; case 7: w = 9.25f; break; } if (lf(x) != w) return 6; }\n  static const int64_t mt[6][12] = { { -1, 12, 25, 38, 51, -36, -23, -10, 3, 16, 29, 42 }, { 38, -36, -10, 16, 42, -32, -6, 20, 46, -28, -2, 24 }, { -23, 16, 55, -6, 33, -28, 11, 50, -11, 28, -33, 6 }, { 16, -32, 20, -28, 24, -24, 28, -20, 32, -16, 36, -12 }, { 55, 20, -15, 50, 15, -20, 45, 10, -25, 40, 5, -30 }, { -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5 } };\n  for (int x = -2; x < 8; x++) { int r = x >= 0 && x < 5 ? x : 5; int64_t w = 0; for (int q = 0; q < 12; q++) w += mt[r][q] * (q + 1); if (lm(x) != w) return 7; }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Dense switches whose cases go to blocks of their own branch through a table: signed i8 cases, i16
// cases with holes whose even cases pass an argument (moves past the table) and whose default passes
// another, i64 cases from 2^40, and 257 i32 cases over 300 entries sharing five blocks.
@test
fn dense_switches_branch_through_tables_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @j8 fn global
sym @j16 fn global
sym @j64 fn global
sym @jbig fn global
fn @j8
  sig (i8.s, i32) -> i32
b0(v0: i8, v1: i32):
  switch v0 [-2 -> b1, -1 -> b2, 0 -> b3, 1 -> b4, 2 -> b5, 3 -> b6] else b7
b1:
  v2 = iconst.i32 1
  v3 = mul.i32 v1, v2
  v4 = iconst.i32 -2
  v5 = add.i32 v3, v4
  ret v5
b2:
  v6 = iconst.i32 2
  v7 = mul.i32 v1, v6
  v8 = iconst.i32 -1
  v9 = add.i32 v7, v8
  ret v9
b3:
  v10 = iconst.i32 3
  v11 = mul.i32 v1, v10
  v12 = iconst.i32 0
  v13 = add.i32 v11, v12
  ret v13
b4:
  v14 = iconst.i32 4
  v15 = mul.i32 v1, v14
  v16 = iconst.i32 1
  v17 = add.i32 v15, v16
  ret v17
b5:
  v18 = iconst.i32 5
  v19 = mul.i32 v1, v18
  v20 = iconst.i32 2
  v21 = add.i32 v19, v20
  ret v21
b6:
  v22 = iconst.i32 6
  v23 = mul.i32 v1, v22
  v24 = iconst.i32 3
  v25 = add.i32 v23, v24
  ret v25
b7:
  v26 = iconst.i32 -99
  ret v26
fn @j16
  sig (i16.s, i32) -> i32
b0(v0: i16, v1: i32):
  v2 = iconst.i32 5
  switch v0 [100 -> b1(v1), 101 -> b3, 102 -> b1(v1), 104 -> b1(v1), 105 -> b4, 106 -> b1(v1), 108 -> b1(v1), 109 -> b5, 110 -> b1(v1)] else b2(v2)
b1(v3: i32):
  v4 = iconst.i32 3
  v5 = mul.i32 v3, v4
  ret v5
b2(v6: i32):
  v7 = sub.i32 v1, v6
  ret v7
b3:
  v8 = iconst.i32 707
  v9 = xor.i32 v1, v8
  ret v9
b4:
  v10 = iconst.i32 735
  v11 = xor.i32 v1, v10
  ret v11
b5:
  v12 = iconst.i32 763
  v13 = xor.i32 v1, v12
  ret v13
fn @j64
  sig (i64) -> i64
b0(v0: i64):
  switch v0 [1099511627776 -> b1, 1099511627777 -> b2, 1099511627778 -> b3, 1099511627779 -> b4, 1099511627780 -> b5, 1099511627781 -> b6] else b7
b1:
  v1 = iconst.i64 0
  v2 = add.i64 v0, v1
  ret v2
b2:
  v3 = iconst.i64 11
  v4 = add.i64 v0, v3
  ret v4
b3:
  v5 = iconst.i64 22
  v6 = add.i64 v0, v5
  ret v6
b4:
  v7 = iconst.i64 33
  v8 = add.i64 v0, v7
  ret v8
b5:
  v9 = iconst.i64 44
  v10 = add.i64 v0, v9
  ret v10
b6:
  v11 = iconst.i64 55
  v12 = add.i64 v0, v11
  ret v12
b7:
  v13 = iconst.i64 -1
  ret v13
fn @jbig
  sig (i32) -> i32
b0(v0: i32):
  switch v0 [1 -> b2, 2 -> b3, 3 -> b4, 4 -> b5, 5 -> b1, 6 -> b2, 8 -> b4, 9 -> b5, 10 -> b1, 11 -> b2, 12 -> b3, 13 -> b4, 15 -> b1, 16 -> b2, 17 -> b3, 18 -> b4, 19 -> b5, 20 -> b1, 22 -> b3, 23 -> b4, 24 -> b5, 25 -> b1, 26 -> b2, 27 -> b3, 29 -> b5, 30 -> b1, 31 -> b2, 32 -> b3, 33 -> b4, 34 -> b5, 36 -> b2, 37 -> b3, 38 -> b4, 39 -> b5, 40 -> b1, 41 -> b2, 43 -> b4, 44 -> b5, 45 -> b1, 46 -> b2, 47 -> b3, 48 -> b4, 50 -> b1, 51 -> b2, 52 -> b3, 53 -> b4, 54 -> b5, 55 -> b1, 57 -> b3, 58 -> b4, 59 -> b5, 60 -> b1, 61 -> b2, 62 -> b3, 64 -> b5, 65 -> b1, 66 -> b2, 67 -> b3, 68 -> b4, 69 -> b5, 71 -> b2, 72 -> b3, 73 -> b4, 74 -> b5, 75 -> b1, 76 -> b2, 78 -> b4, 79 -> b5, 80 -> b1, 81 -> b2, 82 -> b3, 83 -> b4, 85 -> b1, 86 -> b2, 87 -> b3, 88 -> b4, 89 -> b5, 90 -> b1, 92 -> b3, 93 -> b4, 94 -> b5, 95 -> b1, 96 -> b2, 97 -> b3, 99 -> b5, 100 -> b1, 101 -> b2, 102 -> b3, 103 -> b4, 104 -> b5, 106 -> b2, 107 -> b3, 108 -> b4, 109 -> b5, 110 -> b1, 111 -> b2, 113 -> b4, 114 -> b5, 115 -> b1, 116 -> b2, 117 -> b3, 118 -> b4, 120 -> b1, 121 -> b2, 122 -> b3, 123 -> b4, 124 -> b5, 125 -> b1, 127 -> b3, 128 -> b4, 129 -> b5, 130 -> b1, 131 -> b2, 132 -> b3, 134 -> b5, 135 -> b1, 136 -> b2, 137 -> b3, 138 -> b4, 139 -> b5, 141 -> b2, 142 -> b3, 143 -> b4, 144 -> b5, 145 -> b1, 146 -> b2, 148 -> b4, 149 -> b5, 150 -> b1, 151 -> b2, 152 -> b3, 153 -> b4, 155 -> b1, 156 -> b2, 157 -> b3, 158 -> b4, 159 -> b5, 160 -> b1, 162 -> b3, 163 -> b4, 164 -> b5, 165 -> b1, 166 -> b2, 167 -> b3, 169 -> b5, 170 -> b1, 171 -> b2, 172 -> b3, 173 -> b4, 174 -> b5, 176 -> b2, 177 -> b3, 178 -> b4, 179 -> b5, 180 -> b1, 181 -> b2, 183 -> b4, 184 -> b5, 185 -> b1, 186 -> b2, 187 -> b3, 188 -> b4, 190 -> b1, 191 -> b2, 192 -> b3, 193 -> b4, 194 -> b5, 195 -> b1, 197 -> b3, 198 -> b4, 199 -> b5, 200 -> b1, 201 -> b2, 202 -> b3, 204 -> b5, 205 -> b1, 206 -> b2, 207 -> b3, 208 -> b4, 209 -> b5, 211 -> b2, 212 -> b3, 213 -> b4, 214 -> b5, 215 -> b1, 216 -> b2, 218 -> b4, 219 -> b5, 220 -> b1, 221 -> b2, 222 -> b3, 223 -> b4, 225 -> b1, 226 -> b2, 227 -> b3, 228 -> b4, 229 -> b5, 230 -> b1, 232 -> b3, 233 -> b4, 234 -> b5, 235 -> b1, 236 -> b2, 237 -> b3, 239 -> b5, 240 -> b1, 241 -> b2, 242 -> b3, 243 -> b4, 244 -> b5, 246 -> b2, 247 -> b3, 248 -> b4, 249 -> b5, 250 -> b1, 251 -> b2, 253 -> b4, 254 -> b5, 255 -> b1, 256 -> b2, 257 -> b3, 258 -> b4, 260 -> b1, 261 -> b2, 262 -> b3, 263 -> b4, 264 -> b5, 265 -> b1, 267 -> b3, 268 -> b4, 269 -> b5, 270 -> b1, 271 -> b2, 272 -> b3, 274 -> b5, 275 -> b1, 276 -> b2, 277 -> b3, 278 -> b4, 279 -> b5, 281 -> b2, 282 -> b3, 283 -> b4, 284 -> b5, 285 -> b1, 286 -> b2, 288 -> b4, 289 -> b5, 290 -> b1, 291 -> b2, 292 -> b3, 293 -> b4, 295 -> b1, 296 -> b2, 297 -> b3, 298 -> b4, 299 -> b5] else b6
b1:
  v1 = iconst.i32 1
  ret v1
b2:
  v2 = iconst.i32 2
  ret v2
b3:
  v3 = iconst.i32 5
  ret v3
b4:
  v4 = iconst.i32 10
  ret v4
b5:
  v5 = iconst.i32 17
  ret v5
b6:
  v6 = iconst.i32 0
  ret v6
)";
    let drv = "#include <stdint.h>\nint32_t j8(int8_t, int32_t); int32_t j16(int16_t, int32_t); int64_t j64(int64_t); int32_t jbig(int32_t);\nint main(void) {\n  for (int x = -128; x < 128; x++) { int32_t w = x >= -2 && x <= 3 ? 1000 * (x + 3) + x : -99; if (j8((int8_t)x, 1000) != w) return 1; }\n  for (int x = 90; x < 120; x++) { int32_t w; int in = x >= 100 && x <= 110 && x != 103 && x != 107; if (!in) w = 40 - 5; else if (x % 2 == 0) w = 40 * 3; else w = 40 ^ (x * 7); if (j16((int16_t)x, 40) != w) return 2; }\n  if (j16(-32768, 40) != 35 || j16(32767, 40) != 35) return 2;\n  for (int64_t d = -3; d < 9; d++) { int64_t x = 1099511627776ll + d; int64_t w = d >= 0 && d < 6 ? x + d * 11 : -1; if (j64(x) != w) return 3; }\n  if (j64(0) != -1 || j64(-1) != -1) return 3;\n  for (int x = -5; x < 310; x++) { int32_t w = x >= 0 && x < 300 && x % 7 ? (x % 5) * (x % 5) + 1 : 0; if (jbig(x) != w) return 4; }\n  if (jbig(-2147483647 - 1) != 0 || jbig(2147483647) != 0) return 4;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Loops that step pointers (`lir::loops::pointer_ivs`), each step the first read of its pointer after an
// access at offset 0: a pair of 8-byte loads, single 4-byte loads, a pair of stores, single stores,
// 16-byte vectors in pairs and alone, scalar floats loaded and stored, a step down, a step past a pair's immediate (an `add`), and a
// pointer read after its step (an `add`). arm64 steps them in the access (post-indexed `ldp`, `ldr`, `stp`, `str`).
@test
fn loops_that_step_pointers_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @pairs fn global
sym @words fn global
sym @scatter fn global
sym @store1 fn global
sym @vsum fn global
sym @back fn global
sym @far fn global
sym @reread fn global
sym @vone fn global
sym @fscale fn global
sym @ffill fn global
fn @pairs
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = ptradd v0, v1 * 16
  v4 = icmp.eq v1, v2
  br v4, b2(v2), b1(v2, v0)
b1(v5: i64, v6: ptr):
  v7 = load.i64 v6 align 3
  v8 = load.i64 v6+8 align 3
  v9 = mul.i64 v7, v8
  v10 = add.i64 v5, v9
  v11 = ptradd v6+16
  v12 = icmp.ne v11, v3
  br v12, b1(v10, v11), b2(v10)
b2(v13: i64):
  ret v13
fn @words
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i32 0
  v3 = ptradd v0, v1 * 4
  v4 = iconst.i64 0
  v5 = icmp.eq v1, v4
  v6 = iconst.i32 31
  br v5, b2(v2), b1(v2, v0)
b1(v7: i32, v8: ptr):
  v9 = load.i32 v8 align 2
  v10 = mul.i32 v7, v6
  v11 = add.i32 v10, v9
  v12 = ptradd v8+4
  v13 = icmp.ne v12, v3
  br v13, b1(v11, v12), b2(v11)
b2(v14: i32):
  ret v14
fn @scatter
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = ptradd v0, v1 * 16
  v4 = icmp.eq v1, v2
  v5 = iconst.i64 1
  br v4, b2, b1(v2, v0)
b1(v6: i64, v7: ptr):
  v8 = sub.i64 v2, v6
  store v6, v7 align 3
  store v8, v7+8 align 3
  v9 = add.i64 v6, v5
  v10 = ptradd v7+16
  v11 = icmp.ne v10, v3
  br v11, b1(v9, v10), b2
b2:
  ret
fn @store1
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = ptradd v0, v1 * 4
  v4 = icmp.eq v1, v2
  v5 = iconst.i32 7
  v6 = iconst.i32 5
  br v4, b2, b1(v6, v0)
b1(v7: i32, v8: ptr):
  store v7, v8 align 2
  v9 = mul.i32 v7, v5
  v10 = ptradd v8+4
  v11 = icmp.ne v10, v3
  br v11, b1(v9, v10), b2
b2:
  ret
fn @vsum
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = ptradd v0, v1 * 32
  v4 = wconst.v4i32 0x0, 0x0
  v5 = icmp.eq v1, v2
  br v5, b2(v4), b1(v4, v0)
b1(v6: v4i32, v7: ptr):
  v8 = load.v4i32 v7 align 2
  v9 = load.v4i32 v7+16 align 2
  v10 = add.v4i32 v6, v8
  v11 = add.v4i32 v10, v9
  v12 = ptradd v7+32
  v13 = icmp.ne v12, v3
  br v13, b1(v11, v12), b2(v11)
b2(v14: v4i32):
  v15 = vop.reduce_add.i32 (v14)
  ret v15
fn @back
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = ptradd v0, v1 * 16
  v4 = ptradd v3-16
  v5 = ptradd v0-16
  v6 = iconst.i64 3
  jmp b1(v2, v4)
b1(v7: i64, v8: ptr):
  v9 = load.i64 v8 align 3
  v10 = load.i64 v8+8 align 3
  v11 = mul.i64 v7, v6
  v12 = add.i64 v11, v9
  v13 = sub.i64 v12, v10
  v14 = ptradd v8-16
  v15 = icmp.ne v14, v5
  br v15, b1(v13, v14), b2(v13)
b2(v16: i64):
  ret v16
fn @far
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = ptradd v0, v1 * 4096
  v4 = icmp.eq v1, v2
  br v4, b2(v2), b1(v2, v0)
b1(v5: i64, v6: ptr):
  v7 = load.i64 v6 align 3
  v8 = load.i64 v6+8 align 3
  v9 = sub.i64 v7, v8
  v10 = add.i64 v5, v9
  v11 = ptradd v6+4096
  v12 = icmp.ne v11, v3
  br v12, b1(v10, v11), b2(v10)
b2(v13: i64):
  ret v13
fn @reread
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = ptradd v0, v1 * 16
  v4 = ptradd v3-16
  jmp b1(v2, v0)
b1(v5: i64, v6: ptr):
  v7 = load.i64 v6 align 3
  v8 = load.i64 v6+8 align 3
  v9 = add.i64 v7, v8
  v10 = add.i64 v5, v9
  v11 = ptradd v6+16
  v12 = icmp.ne v6, v4
  br v12, b1(v10, v11), b2(v10)
b2(v13: i64):
  ret v13
fn @vone
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = ptradd v0, v1 * 16
  v4 = wconst.v4i32 0x0, 0x0
  v5 = icmp.eq v1, v2
  br v5, b2(v4), b1(v4, v0)
b1(v6: v4i32, v7: ptr):
  v8 = load.v4i32 v7 align 2
  v9 = add.v4i32 v6, v8
  v10 = ptradd v7+16
  v11 = icmp.ne v10, v3
  br v11, b1(v9, v10), b2(v9)
b2(v12: v4i32):
  v13 = vop.reduce_add.i32 (v12)
  ret v13
fn @fscale
  sig (ptr, ptr, i64, f64) -> f64
b0(v0: ptr, v1: ptr, v2: i64, v3: f64):
  v4 = iconst.i64 0
  v5 = ptradd v1, v2 * 8
  v6 = fconst.f64 0x0
  v7 = icmp.eq v2, v4
  br v7, b2(v6), b1(v6, v1, v0)
b1(v8: f64, v9: ptr, v10: ptr):
  v11 = load.f64 v9 align 3
  v12 = fmul.f64 v11, v3
  store v12, v10 align 3
  v13 = fadd.f64 v8, v12
  v14 = ptradd v9+8
  v15 = ptradd v10+8
  v16 = icmp.ne v14, v5
  br v16, b1(v13, v14, v15), b2(v13)
b2(v17: f64):
  ret v17
fn @ffill
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = ptradd v0, v2 * 8
  v5 = icmp.eq v2, v3
  br v5, b2, b1(v0)
b1(v6: ptr):
  v7 = load.f64 v1 align 3
  store v7, v6 align 3
  v8 = ptradd v6+8
  v9 = icmp.ne v8, v4
  br v9, b1(v8), b2
b2:
  ret
)";
    let drv = "#include <stdint.h>\nlong long pairs(const long long *, long long);\nint words(const int *, long long);\nvoid scatter(long long *, long long);\nvoid store1(int *, long long);\nint vsum(const int *, long long);\nlong long back(const long long *, long long);\nlong long far(const long long *, long long);\nlong long reread(const long long *, long long);\nint vone(const int *, long long);\ndouble fscale(double *, const double *, long long, double);\nvoid ffill(double *, const double *, long long);\nstatic long long a[2048];\nstatic double fd[64], fo[64];\nstatic long long s[64];\nint main(void) {\n  for (int i = 0; i < 2048; i++) a[i] = (long long)((i * 2654435761u) % 1000u) - 500;\n  const long long ns[4] = {1, 3, 8, 4};\n  for (int k = 0; k < 4; k++) {\n    long long n = ns[k];\n    long long e = 0;\n    for (long long i = 0; i < n; i++) e += a[2 * i] * a[2 * i + 1];\n    if (pairs(a, n) != e) return 1;\n    const int *w = (const int *)a;\n    uint32_t ew = 0;\n    for (long long i = 0; i < 4 * n; i++) ew = ew * 31u + (uint32_t)w[i];\n    if ((uint32_t)words(w, 4 * n) != ew) return 2;\n    scatter(s, n);\n    for (long long i = 0; i < n; i++) if (s[2 * i] != i || s[2 * i + 1] != -i) return 3;\n    int *q = (int *)s;\n    store1(q, 2 * n);\n    uint32_t x = 5;\n    for (long long i = 0; i < 2 * n; i++) { if ((uint32_t)q[i] != x) return 4; x *= 7u; }\n    uint32_t ev = 0;\n    for (long long i = 0; i < 8 * n; i++) ev += (uint32_t)w[i];\n    if ((uint32_t)vsum(w, n) != ev) return 5;\n    long long eb = 0;\n    for (long long i = n - 1; i >= 0; i--) eb = eb * 3 + a[2 * i] - a[2 * i + 1];\n    if (back(a, n) != eb) return 6;\n    long long ef = 0;\n    for (long long i = 0; i < (n < 4 ? n : 4); i++) ef += a[512 * i] - a[512 * i + 1];\n    if (far(a, n < 4 ? n : 4) != ef) return 7;\n    long long er = 0;\n    for (long long i = 0; i < n; i++) er += a[2 * i] + a[2 * i + 1];\n    if (reread(a, n) != er) return 8;\n    uint32_t eo = 0;\n    for (long long i = 0; i < 4 * n; i++) eo += (uint32_t)w[i];\n    if ((uint32_t)vone(w, n) != eo) return 10;\n    for (int i = 0; i < 64; i++) fd[i] = (double)(i * 3 - 50) / 8.0;\n    double ef2 = 0.0;\n    for (long long i = 0; i < 2 * n; i++) ef2 += fd[i] * 1.5;\n    if (fscale(fo, fd, 2 * n, 1.5) != ef2) return 11;\n    for (long long i = 0; i < 2 * n; i++) if (fo[i] != fd[i] * 1.5) return 12;\n    ffill(fo, &fd[5], 3 * n);\n    for (long long i = 0; i < 3 * n; i++) if (fo[i] != fd[5]) return 13;\n  }\n  if (pairs(a, 0) != 0 || words((const int *)a, 0) != 0 || vsum((const int *)a, 0) != 0 || far(a, 0) != 0) return 9;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// Vector products added to or subtracted from an accumulator, the product first or second, of 1-, 2- and
// 4-byte lanes in 8- and 16-byte vectors, the accumulator read again after (arm64: MLA and MLS).
@test
fn vector_products_added_and_subtracted_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @mla fn global
fn @mla
  sig (ptr, ptr, ptr, ptr) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: ptr):
  v4 = load.v8i8 v0 align 0
  v5 = load.v8i8 v1 align 0
  v6 = load.v8i8 v2 align 0
  v7 = mul.v8i8 v5, v6
  v8 = add.v8i8 v4, v7
  v9 = mul.v8i8 v5, v6
  v10 = sub.v8i8 v4, v9
  v11 = mul.v8i8 v5, v6
  v12 = add.v8i8 v11, v4
  v13 = load.v4i16 v0 align 0
  v14 = load.v4i16 v1 align 0
  v15 = load.v4i16 v2 align 0
  v16 = mul.v4i16 v14, v15
  v17 = add.v4i16 v13, v16
  v18 = mul.v4i16 v14, v15
  v19 = sub.v4i16 v13, v18
  v20 = mul.v4i16 v14, v15
  v21 = add.v4i16 v20, v13
  v22 = load.v2i32 v0 align 0
  v23 = load.v2i32 v1 align 0
  v24 = load.v2i32 v2 align 0
  v25 = mul.v2i32 v23, v24
  v26 = add.v2i32 v22, v25
  v27 = mul.v2i32 v23, v24
  v28 = sub.v2i32 v22, v27
  v29 = mul.v2i32 v23, v24
  v30 = add.v2i32 v29, v22
  v31 = load.v16i8 v0 align 0
  v32 = load.v16i8 v1 align 0
  v33 = load.v16i8 v2 align 0
  v34 = mul.v16i8 v32, v33
  v35 = add.v16i8 v31, v34
  v36 = mul.v16i8 v32, v33
  v37 = sub.v16i8 v31, v36
  v38 = mul.v16i8 v32, v33
  v39 = add.v16i8 v38, v31
  v40 = load.v8i16 v0 align 0
  v41 = load.v8i16 v1 align 0
  v42 = load.v8i16 v2 align 0
  v43 = mul.v8i16 v41, v42
  v44 = add.v8i16 v40, v43
  v45 = mul.v8i16 v41, v42
  v46 = sub.v8i16 v40, v45
  v47 = mul.v8i16 v41, v42
  v48 = add.v8i16 v47, v40
  v49 = load.v4i32 v0 align 0
  v50 = load.v4i32 v1 align 0
  v51 = load.v4i32 v2 align 0
  v52 = mul.v4i32 v50, v51
  v53 = add.v4i32 v49, v52
  v54 = mul.v4i32 v50, v51
  v55 = sub.v4i32 v49, v54
  v56 = mul.v4i32 v50, v51
  v57 = add.v4i32 v56, v49
  store v8, v3+0 align 0
  store v10, v3+8 align 0
  store v12, v3+16 align 0
  store v4, v3+24 align 0
  store v17, v3+32 align 0
  store v19, v3+40 align 0
  store v21, v3+48 align 0
  store v13, v3+56 align 0
  store v26, v3+64 align 0
  store v28, v3+72 align 0
  store v30, v3+80 align 0
  store v22, v3+88 align 0
  store v35, v3+96 align 0
  store v37, v3+112 align 0
  store v39, v3+128 align 0
  store v31, v3+144 align 0
  store v44, v3+160 align 0
  store v46, v3+176 align 0
  store v48, v3+192 align 0
  store v40, v3+208 align 0
  store v53, v3+224 align 0
  store v55, v3+240 align 0
  store v57, v3+256 align 0
  store v49, v3+272 align 0
  ret
)";
    let drv = "#include <stdint.h>\n#include <string.h>\nvoid mla(const void *, const void *, const void *, void *);\nint main(void) {\n  unsigned char a[16], x[16], y[16], o[288];\n  for (int i = 0; i < 16; i++) { a[i] = (unsigned char)(i * 31 + 7); x[i] = (unsigned char)(i * 17 + 200); y[i] = (unsigned char)(i * 13 + 99); }\n  mla(a, x, y, o);\n  { uint8_t aa[8], xx[8], yy[8], rr[8]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 0, sizeof rr); for (int i = 0; i < 8; i++) if (rr[i] != (uint8_t)(aa[i] + xx[i] * yy[i])) return 1; }\n  { uint8_t aa[8], xx[8], yy[8], rr[8]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 8, sizeof rr); for (int i = 0; i < 8; i++) if (rr[i] != (uint8_t)(aa[i] - xx[i] * yy[i])) return 2; }\n  { uint8_t aa[8], xx[8], yy[8], rr[8]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 16, sizeof rr); for (int i = 0; i < 8; i++) if (rr[i] != (uint8_t)(aa[i] + xx[i] * yy[i])) return 3; }\n  { uint8_t aa[8], xx[8], yy[8], rr[8]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 24, sizeof rr); for (int i = 0; i < 8; i++) if (rr[i] != (uint8_t)(aa[i])) return 4; }\n  { uint16_t aa[4], xx[4], yy[4], rr[4]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 32, sizeof rr); for (int i = 0; i < 4; i++) if (rr[i] != (uint16_t)(aa[i] + xx[i] * yy[i])) return 5; }\n  { uint16_t aa[4], xx[4], yy[4], rr[4]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 40, sizeof rr); for (int i = 0; i < 4; i++) if (rr[i] != (uint16_t)(aa[i] - xx[i] * yy[i])) return 6; }\n  { uint16_t aa[4], xx[4], yy[4], rr[4]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 48, sizeof rr); for (int i = 0; i < 4; i++) if (rr[i] != (uint16_t)(aa[i] + xx[i] * yy[i])) return 7; }\n  { uint16_t aa[4], xx[4], yy[4], rr[4]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 56, sizeof rr); for (int i = 0; i < 4; i++) if (rr[i] != (uint16_t)(aa[i])) return 8; }\n  { uint32_t aa[2], xx[2], yy[2], rr[2]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 64, sizeof rr); for (int i = 0; i < 2; i++) if (rr[i] != (uint32_t)(aa[i] + xx[i] * yy[i])) return 9; }\n  { uint32_t aa[2], xx[2], yy[2], rr[2]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 72, sizeof rr); for (int i = 0; i < 2; i++) if (rr[i] != (uint32_t)(aa[i] - xx[i] * yy[i])) return 10; }\n  { uint32_t aa[2], xx[2], yy[2], rr[2]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 80, sizeof rr); for (int i = 0; i < 2; i++) if (rr[i] != (uint32_t)(aa[i] + xx[i] * yy[i])) return 11; }\n  { uint32_t aa[2], xx[2], yy[2], rr[2]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 88, sizeof rr); for (int i = 0; i < 2; i++) if (rr[i] != (uint32_t)(aa[i])) return 12; }\n  { uint8_t aa[16], xx[16], yy[16], rr[16]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 96, sizeof rr); for (int i = 0; i < 16; i++) if (rr[i] != (uint8_t)(aa[i] + xx[i] * yy[i])) return 13; }\n  { uint8_t aa[16], xx[16], yy[16], rr[16]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 112, sizeof rr); for (int i = 0; i < 16; i++) if (rr[i] != (uint8_t)(aa[i] - xx[i] * yy[i])) return 14; }\n  { uint8_t aa[16], xx[16], yy[16], rr[16]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 128, sizeof rr); for (int i = 0; i < 16; i++) if (rr[i] != (uint8_t)(aa[i] + xx[i] * yy[i])) return 15; }\n  { uint8_t aa[16], xx[16], yy[16], rr[16]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 144, sizeof rr); for (int i = 0; i < 16; i++) if (rr[i] != (uint8_t)(aa[i])) return 16; }\n  { uint16_t aa[8], xx[8], yy[8], rr[8]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 160, sizeof rr); for (int i = 0; i < 8; i++) if (rr[i] != (uint16_t)(aa[i] + xx[i] * yy[i])) return 17; }\n  { uint16_t aa[8], xx[8], yy[8], rr[8]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 176, sizeof rr); for (int i = 0; i < 8; i++) if (rr[i] != (uint16_t)(aa[i] - xx[i] * yy[i])) return 18; }\n  { uint16_t aa[8], xx[8], yy[8], rr[8]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 192, sizeof rr); for (int i = 0; i < 8; i++) if (rr[i] != (uint16_t)(aa[i] + xx[i] * yy[i])) return 19; }\n  { uint16_t aa[8], xx[8], yy[8], rr[8]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 208, sizeof rr); for (int i = 0; i < 8; i++) if (rr[i] != (uint16_t)(aa[i])) return 20; }\n  { uint32_t aa[4], xx[4], yy[4], rr[4]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 224, sizeof rr); for (int i = 0; i < 4; i++) if (rr[i] != (uint32_t)(aa[i] + xx[i] * yy[i])) return 21; }\n  { uint32_t aa[4], xx[4], yy[4], rr[4]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 240, sizeof rr); for (int i = 0; i < 4; i++) if (rr[i] != (uint32_t)(aa[i] - xx[i] * yy[i])) return 22; }\n  { uint32_t aa[4], xx[4], yy[4], rr[4]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 256, sizeof rr); for (int i = 0; i < 4; i++) if (rr[i] != (uint32_t)(aa[i] + xx[i] * yy[i])) return 23; }\n  { uint32_t aa[4], xx[4], yy[4], rr[4]; memcpy(aa, a, sizeof aa); memcpy(xx, x, sizeof xx); memcpy(yy, y, sizeof yy); memcpy(rr, o + 272, sizeof rr); for (int i = 0; i < 4; i++) if (rr[i] != (uint32_t)(aa[i])) return 24; }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Narrow results that blocks join (`cls`'s through a switch, from constants and a sum, `pick`'s through a
// branch), which the C driver reads at their width; a loop reads and writes bytes at offsets of one indexed
// address (x86-64 folds it into each access) and counts matches.
@test
fn narrow_joins_and_indexed_accesses_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @cls fn global
sym @pick fn global
sym @cnt fn global
fn @cls
  sig (i8) -> i8
b0(v0: i8):
  v1 = iconst.i8 200
  v2 = iconst.i8 7
  v3 = iconst.i8 -1
  v4 = add.i8 v0, v1
  switch v0 [1 -> b1(v1), 2 -> b1(v2), 3 -> b1(v3), 4 -> b1(v1)] else b1(v4)
b1(v5: i8):
  ret v5
fn @pick
  sig (i32) -> i16
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = icmp.eq v0, v1
  v3 = iconst.i16 40000
  v4 = iconst.i16 -2
  br v2, b1(v3), b1(v4)
b1(v5: i16):
  ret v5
fn @cnt
  sig (ptr, i64, i8) -> i64
b0(v0: ptr, v1: i64, v2: i8):
  v3 = iconst.i64 0
  v4 = iconst.i64 2
  v5 = icmp.eq v1, v3
  br v5, b2(v3), b1(v3, v3)
b1(v6: i64, v7: i64):
  v8 = ptradd v0, v6 * 1
  v9 = load.i8 v8 align 0
  v10 = load.i8 v8+1 align 0
  v11 = icmp.eq v9, v2
  v12 = zext.i64 v11
  v13 = icmp.eq v10, v2
  v14 = zext.i64 v13
  v15 = add.i64 v7, v12
  v16 = add.i64 v15, v14
  store v10, v8 align 0
  v17 = add.i64 v6, v4
  v18 = icmp.ult v17, v1
  br v18, b1(v17, v16), b2(v16)
b2(v19: i64):
  ret v19
)";
    let drv = "#include <stdint.h>\nunsigned char cls(unsigned char);\nunsigned short pick(int);\nint64_t cnt(unsigned char *, int64_t, unsigned char);\nint main(void) {\n  if (cls(1) != 200 || cls(2) != 7 || cls(3) != 255 || cls(4) != 200 || cls(0) != 200 || cls(9) != 209 || cls(100) != 44) return 1;\n  if (pick(0) != 40000 || pick(5) != 65534) return 2;\n  unsigned char s[10] = {3, 9, 9, 3, 9, 1, 3, 3, 0, 9};\n  if (cnt(s, 10, 3) != 4 || cnt(s, 0, 3) != 0) return 3;\n  for (int k = 0; k < 10; k += 2) if (s[k] != s[k + 1]) return 4;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// The parameters of the block after a loop, which an edge before the loop also enters, take the loop's
// parameter registers; the loop leaves through a block of its own, so its steps outlive the loop and hold
// those registers last. Values the block computes next take other registers: the last parameter lives on.
@test
fn a_loop_exit_keeps_the_registers_it_shares_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @lev fn global
fn @lev
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 64
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 2
  v5 = icmp.ugt v0, v1
  br v5, b1(v0, v2, v2), b3(v0, v2, v2)
b1(v6: i64, v7: i64, v8: i64):
  v9 = sub.i64 v6, v3
  v10 = lshr.i64 v9, v4
  v11 = add.i64 v7, v10
  v12 = shl.i64 v10, v3
  v13 = sub.i64 v6, v12
  v14 = add.i64 v8, v3
  v15 = icmp.ugt v13, v1
  br v15, b1(v13, v11, v14), b2
b2:
  jmp b3(v13, v11, v14)
b3(v16: i64, v17: i64, v18: i64):
  v19 = shl.i64 v17, v3
  v20 = lshr.i64 v19, v4
  v21 = and.i64 v19, v1
  v22 = xor.i64 v20, v16
  v23 = add.i64 v22, v21
  v24 = mul.i64 v23, v18
  v25 = add.i64 v24, v18
  ret v25
)";
    let drv = "#include <stdint.h>\nuint64_t lev(uint64_t);\nstatic uint64_t ref(uint64_t bl) {\n  uint64_t k = 0, n = 0;\n  while (bl > 64) { uint64_t t = (bl - 1) >> 2; k += t; bl -= t << 1; n++; }\n  uint64_t a = k << 1;\n  return (((a >> 2) ^ bl) + (a & 64)) * n + n;\n}\nint main(void) {\n  uint64_t xs[6] = {0, 64, 65, 100, 1000, 123456789};\n  for (int i = 0; i < 6; i++) if (lev(xs[i]) != ref(xs[i])) return i + 1;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A branch past a loop that passes only constants to the block after it moves them in a stub past the last
// block (`lv::Live::late`): the block's parameters take registers after the loop. `cnt` counts matches
// (the integer constants on an empty slice), `fsum` adds floats (a float constant).
@test
fn constants_into_a_block_past_a_loop_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @cnt fn global
sym @fsum fn global
fn @cnt
  sig (ptr, i64, i8) -> i64
b0(v0: ptr, v1: i64, v2: i8):
  v3 = iconst.i64 0
  v4 = iconst.i64 7
  v5 = icmp.eq v1, v3
  br v5, b3(v3, v4), b1(v3, v3)
b1(v6: i64, v7: i64):
  v8 = ptradd v0, v6 * 1
  v9 = load.i8 v8 align 0
  v10 = icmp.eq v9, v2
  v11 = zext.i64 v10
  v12 = add.i64 v7, v11
  v13 = iconst.i64 1
  v14 = add.i64 v6, v13
  v15 = icmp.ult v14, v1
  br v15, b1(v14, v12), b2
b2:
  jmp b3(v12, v14)
b3(v16: i64, v17: i64):
  v18 = iconst.i64 1000
  v19 = mul.i64 v17, v18
  v20 = add.i64 v16, v19
  ret v20
fn @fsum
  sig (ptr, i64) -> f64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = fconst.f64 0x4004000000000000
  v4 = icmp.eq v1, v2
  br v4, b3(v3), b1(v2, v3)
b1(v5: i64, v6: f64):
  v7 = ptradd v0, v5 * 8
  v8 = load.f64 v7 align 3
  v9 = fadd.f64 v6, v8
  v10 = iconst.i64 1
  v11 = add.i64 v5, v10
  v12 = icmp.ult v11, v1
  br v12, b1(v11, v9), b2
b2:
  jmp b3(v9)
b3(v13: f64):
  v14 = fconst.f64 0x4000000000000000
  v15 = fmul.f64 v13, v14
  ret v15
)";
    let drv = "#include <stdint.h>\nint64_t cnt(const uint8_t *, int64_t, uint8_t);\ndouble fsum(const double *, int64_t);\nint main(void) {\n  uint8_t s[5] = {4, 1, 4, 4, 9};\n  if (cnt(s, 0, 4) != 7000 || cnt(s, 5, 4) != 5003 || cnt(s, 2, 9) != 2000) return 1;\n  double d[3] = {1.0, 0.5, 4.0};\n  if (fsum(d, 0) != 5.0 || fsum(d, 3) != 16.0) return 2;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// `skip`'s branches before and after its loop pass the same constant to the block past the loop, one edge
// record for both (`SHARE`): the branch before the loop moves in a stub (`lv::Live::late`), the one after
// the loop, the block's only other way in, in place.
@test
fn a_shared_edge_past_a_loop_runs() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @skip fn global
fn @skip
  sig (ptr, i64, i64) -> i64
b0(v0: ptr, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 5
  v5 = icmp.eq v1, v3
  br v5, b4(v4), b1(v3, v3)
b1(v6: i64, v7: i64):
  v8 = ptradd v0, v6 * 8
  v9 = load.i64 v8 align 3
  v10 = add.i64 v7, v9
  v11 = iconst.i64 1
  v12 = add.i64 v6, v11
  v13 = icmp.ult v12, v1
  br v13, b1(v12, v10), b2
b2:
  v14 = icmp.eq v2, v3
  br v14, b4(v4), b3
b3:
  ret v10
b4(v15: i64):
  v16 = iconst.i64 100
  v17 = mul.i64 v15, v16
  ret v17
)";
    let drv = "#include <stdint.h>\nint64_t skip(const int64_t *, int64_t, int64_t);\nint main(void) {\n  int64_t s[3] = {1, 2, 4};\n  if (skip(s, 0, 1) != 500 || skip(s, 3, 0) != 500 || skip(s, 3, 1) != 7) return 1;\n  return 0;\n}\n";
    assert_eq(run_native_with(lir, drv, SHARE), 0);
}

// Switches with a case of 0 (arm64 `cbz`): `last` tests it last, its block next (the default's is cold:
// the branch inverts to it, `cbnz`), `first` tests it first, `byte` on an 8-bit value, `wide` on a 64-bit one.
@test
fn switch_cases_of_zero_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @last fn global
sym @first fn global
sym @byte fn global
sym @wide fn global
fn @last
  sig (i32) -> i32
b0(v0: i32):
  switch v0 [3 -> b2, 0 -> b1] else b3
b1:
  v1 = iconst.i32 10
  ret v1
b2:
  v2 = iconst.i32 20
  ret v2
b3: cold
  v3 = iconst.i32 30
  ret v3
fn @first
  sig (i32) -> i32
b0(v0: i32):
  switch v0 [0 -> b3, 7 -> b2, 9 -> b1] else b1
b1:
  v1 = iconst.i32 1
  ret v1
b2:
  v2 = iconst.i32 2
  ret v2
b3:
  v3 = iconst.i32 3
  ret v3
fn @byte
  sig (i8) -> i32
b0(v0: i8):
  switch v0 [0 -> b1, 5 -> b2] else b3
b1:
  v1 = iconst.i32 1
  ret v1
b2:
  v2 = iconst.i32 2
  ret v2
b3:
  v3 = iconst.i32 3
  ret v3
fn @wide
  sig (i64) -> i32
b0(v0: i64):
  switch v0 [8 -> b2, 0 -> b1] else b3
b1:
  v1 = iconst.i32 1
  ret v1
b2:
  v2 = iconst.i32 2
  ret v2
b3:
  v3 = iconst.i32 3
  ret v3
)";
    let drv = "#include <stdint.h>\nint32_t last(int32_t);\nint32_t first(int32_t);\nint32_t byte(uint8_t);\nint32_t wide(int64_t);\nint main(void) {\n  if (last(0) != 10 || last(3) != 20 || last(1) != 30 || last(-1) != 30) return 1;\n  if (first(0) != 3 || first(7) != 2 || first(9) != 1 || first(4) != 1) return 2;\n  if (byte(0) != 1 || byte(5) != 2 || byte(255) != 3) return 3;\n  if (wide(0) != 1 || wide(8) != 2 || wide(1LL << 32) != 3) return 4;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Float selects on a comparison with +0.0 as one side (x86-64: the mask's other half alone, `andnps` or
// `andps`): `lo` gives 0 below 0, `hi` gives 0 unless above 1, in both widths; a NaN takes the false side.
@test
fn float_selects_of_zero_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @lo fn global
sym @hi fn global
sym @lo64 fn global
fn @lo
  sig (f32) -> f32
b0(v0: f32):
  v1 = fconst.f32 0x0
  v2 = fcmp.olt v0, v1
  v3 = select.f32 v2, v1, v0
  ret v3
fn @hi
  sig (f32) -> f32
b0(v0: f32):
  v1 = fconst.f32 0x0
  v2 = fconst.f32 0x3f800000
  v3 = fcmp.ogt v0, v2
  v4 = select.f32 v3, v0, v1
  ret v4
fn @lo64
  sig (f64) -> f64
b0(v0: f64):
  v1 = fconst.f64 0x0
  v2 = fcmp.olt v0, v1
  v3 = select.f64 v2, v1, v0
  ret v3
)";
    let drv = "#include <math.h>\nfloat lo(float);\nfloat hi(float);\ndouble lo64(double);\nint main(void) {\n  if (lo(-2.5f) != 0.0f || signbit(lo(-2.5f)) || lo(0.75f) != 0.75f || !isnan(lo(NAN))) return 1;\n  if (hi(2.5f) != 2.5f || hi(0.5f) != 0.0f || signbit(hi(0.5f)) || hi(NAN) != 0.0f) return 2;\n  if (lo64(-1e300) != 0.0 || lo64(3.0) != 3.0 || !isnan(lo64(NAN))) return 3;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Aggregate arguments at addresses in registers load their parts in the call's parallel move. Each
// address arrives in the argument register that the other aggregate's parts take: `pass2`'s first part
// waits until the loads through its register's old value are done, `pass1`'s two loads form a cycle.
@test
fn aggregate_parts_load_through_argument_registers_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @two fn global ext
sym @one fn global ext
sym @pass2 fn global
sym @pass1 fn global
fn @pass2
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (ptr, ptr) -> i64
b0(v0: ptr, v1: ptr):
  v2 = call.i64 @two(v1, v0) : (l0, l0) -> i64
  ret v2
fn @pass1
  layout l0 size 8 align 3 [0 i64]
  sig (ptr, ptr) -> i64
b0(v0: ptr, v1: ptr):
  v2 = call.i64 @one(v1, v0) : (l0, l0) -> i64
  ret v2
)";
    let drv = "#include <stdint.h>\nstruct P { int64_t a, b; };\nstruct Q { int64_t a; };\nint64_t two(struct P x, struct P y) { return x.a + 10 * x.b + 100 * y.a + 1000 * y.b; }\nint64_t one(struct Q x, struct Q y) { return x.a + 10 * y.a; }\nint64_t pass2(struct P *, struct P *);\nint64_t pass1(struct Q *, struct Q *);\nint main(void) {\n  struct P p = {1, 2}, q = {3, 4};\n  if (pass2(&p, &q) != 2143) return 1;\n  struct Q r = {5}, s = {6};\n  if (pass1(&r, &s) != 56) return 2;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A loop whose product by a constant is the first addend of a sum (arm64 `madd`, the constant kept in a
// register) parses decimal digits.
@test
fn a_loop_of_products_added_to_runs() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @parse fn global
fn @parse
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i32 0
  v4 = iconst.i32 10
  v5 = iconst.i8 48
  v6 = iconst.i64 1
  v7 = icmp.eq v1, v2
  br v7, b2(v3), b1(v2, v3)
b1(v8: i64, v9: i32):
  v10 = ptradd v0, v8 * 1
  v11 = load.i8 v10 align 0
  v12 = sub.i8 v11, v5
  v13 = zext.i32 v12
  v14 = mul.i32 v9, v4
  v15 = add.i32 v14, v13
  v16 = add.i64 v8, v6
  v17 = icmp.ult v16, v1
  br v17, b1(v16, v15), b2(v15)
b2(v18: i32):
  ret v18
)";
    let drv = "#include <stdint.h>\nint32_t parse(const char *, int64_t);\nint main(void) {\n  if (parse(\"1234567\", 7) != 1234567) return 1;\n  if (parse(\"\", 0) != 0) return 2;\n  if (parse(\"90\", 2) != 90) return 3;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
}

// A result in registers whose parts swap the parameters' registers (a cycle the moves break through a
// free register, the result needing no memory), integer and float, and one a return of memory reads.
@test
fn results_that_swap_registers_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @order fn global
sym @forder fn global
sym @kept fn global
fn @order
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64, i64) -> l0
b0(v0: i64, v1: i64, v2: ptr):
  v3 = icmp.slt v0, v1
  br v3, b2, b1
b1:
  store v1, v2 align 3
  store v0, v2+8 align 3
  ret
b2:
  store v0, v2 align 3
  store v1, v2+8 align 3
  ret
fn @forder
  layout l0 size 16 align 3 [0 f64, 8 f64]
  sig (f64, f64) -> l0
b0(v0: f64, v1: f64, v2: ptr):
  v3 = fcmp.olt v0, v1
  br v3, b2, b1
b1:
  store v1, v2 align 3
  store v0, v2+8 align 3
  ret
b2:
  store v0, v2 align 3
  store v1, v2+8 align 3
  ret
fn @kept
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64, i64) -> l0
b0(v0: i64, v1: i64, v2: ptr):
  store v1, v2 align 3
  store v0, v2+8 align 3
  v3 = load.i64 v2 align 3
  v4 = add.i64 v3, v0
  store v4, v2+8 align 3
  ret
)";
    let drv = "#include <stdint.h>\ntypedef struct { int64_t a, b; } P;\ntypedef struct { double a, b; } F;\nP order(int64_t, int64_t);\nF forder(double, double);\nP kept(int64_t, int64_t);\nint main(void) {\n  P p = order(9, 4);\n  if (p.a != 4 || p.b != 9) return 1;\n  p = order(-3, 5);\n  if (p.a != -3 || p.b != 5) return 2;\n  F f = forder(2.5, -1.0);\n  if (f.a != -1.0 || f.b != 2.5) return 3;\n  p = kept(3, 10);\n  if (p.a != 10 || p.b != 13) return 4;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Float to integer conversions saturate, NaN to 0, as the evaluator defines them.
@test
fn float_to_integer_conversions_saturate() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @conv fn global
fn @conv
  sig (f64, ptr) -> void
b0(v0: f64, v1: ptr):
  v2 = fptosi.i32 v0
  v3 = fptoui.i8 v0
  v4 = fptosi.i64 v0
  v5 = fptoui.i64 v0
  v6 = zext.i64 v2
  v7 = zext.i64 v3
  store v6, v1 align 3
  store v7, v1+8 align 3
  store v4, v1+16 align 3
  store v5, v1+24 align 3
  ret
)";
    let drv = "#include <stdint.h>\n#include <math.h>\nvoid conv(double, uint64_t *);\nint main(void) {\n  double in[7] = {NAN, 1e20, -1e20, -0.5, 300.0, 2147483647.5, 1.8e19};\n  uint64_t want[7][4] = {\n    {0, 0, 0, 0},\n    {0x7fffffff, 255, 0x7fffffffffffffffULL, 0xffffffffffffffffULL},\n    {0x80000000, 0, 0x8000000000000000ULL, 0},\n    {0, 0, 0, 0},\n    {300, 255, 300, 300},\n    {0x7fffffff, 255, 2147483647, 2147483647},\n    {0x7fffffff, 255, 0x7fffffffffffffffULL, 18000000000000000000ULL},\n  };\n  for (int i = 0; i < 7; i++) {\n    uint64_t o[4];\n    conv(in[i], o);\n    for (int k = 0; k < 4; k++) if (o[k] != want[i][k]) return 1 + i;\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A vector wider than the C side's vector registers (16 bytes here) passes as C declares it, a struct of
// its lanes: through memory (System V: on the stack, the result through rdi; arm64 and Microsoft x64:
// by reference, the result through x8 or rcx). A bare `vector_size(32)` type is no such case: gcc and
// clang return one differently without AVX.
@test
fn wide_vectors_cross_the_c_abi() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @tw fn global\nfn @tw\n  sig (v8f32) -> v8f32\nb0(v0: v8f32):\n  v1 = fadd.v8f32 v0, v0\n  ret v1\n";
    let drv = "typedef struct { _Alignas(32) float l[8]; } v8;\nv8 tw(v8);\nint main(void) {\n  v8 a = {{1, 2, 3, 4, 5, 6, 7, 8}};\n  v8 r = tw(a);\n  for (int i = 0; i < 8; i++) if (r.l[i] != 2 * a.l[i]) return 1;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A program of two modules, `main` and `lib`, that pass arrays, results, a widened f32, enums with payloads and
// borrowed dyn values across modules: built with each module alone native, the calls cross between C and native code
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

// C values of `@layout` types pass as the scalars their header's typedefs name: a `double` handle in a
// vector register, an `unsigned long long` one and a pointer one in integer registers, from native code. The
// header's pointer constants (a cast to `void *`, and to a typedef of a pointer) are read too.
@test
fn header_scalars_cross_the_c_abi() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
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
    assert(cli::superc_in(p.dir(), "build main.spc -o bin").ok(), "the program builds");
    assert_eq(p.run_bin(), 0);
}

// Header structs and unions of `@layout` types pass by value as the C compiler passes them, from native
// code: the header's members give their leaves (`bindgen::c_layout`): a double and an integer, three floats
// (a homogeneous aggregate on arm64), memory past 16 bytes, a union, a nested struct with an array.
@test
fn header_structs_cross_the_c_abi() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "h.h",
        "typedef struct { double a; long long b; } pair;\ntypedef struct { float x, y, z; } v3;\ntypedef struct { int a[6]; } big;\ntypedef union { double d; long long i; } num;\ntypedef struct { pair p; float f[2]; } nest;\npair mkp(double a, long long b);\ndouble sump(pair p);\nv3 mk3(float x, float y, float z);\nfloat dot3(v3 a, v3 b);\nbig mkb(int k);\nint sumb(big g);\nnum mku(long long i);\nlong long getu(num u);\nnest mkn(double a, long long b, float f);\ndouble sumn(nest n);\n",
    );
    p.mkfile(
        "h.c",
        "#include \"h.h\"\npair mkp(double a, long long b) { pair p = { a, b }; return p; }\ndouble sump(pair p) { return p.a + (double)p.b; }\nv3 mk3(float x, float y, float z) { v3 v = { x, y, z }; return v; }\nfloat dot3(v3 a, v3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }\nbig mkb(int k) { big g; for (int i = 0; i < 6; i++) g.a[i] = k + i; return g; }\nint sumb(big g) { int s = 0; for (int i = 0; i < 6; i++) s += g.a[i]; return s; }\nnum mku(long long i) { num u; u.i = i; return u; }\nlong long getu(num u) { return u.i; }\nnest mkn(double a, long long b, float f) { nest n = { { a, b }, { f, 2 * f } }; return n; }\ndouble sumn(nest n) { return n.p.a + (double)n.p.b + n.f[0] + n.f[1]; }\n",
    );
    assert(p.c_lib("hr", "h.c"), "the C library builds");
    p.mkfile(
        "main.spc",
        format(
            "@link(\"-L{} -lhr\")\nextern \"C\" \"h.h\" {{\n    @layout(16, 8)\n    type pair;\n    @layout(12, 4)\n    type v3;\n    @layout(24, 4)\n    type big;\n    @layout(8, 8)\n    type num;\n    @layout(24, 8)\n    type nest;\n    fn mkp(a: f64, b: i64) pair;\n    fn sump(p: pair) f64;\n    fn mk3(x: f32, y: f32, z: f32) v3;\n    fn dot3(a: v3, b: v3) f32;\n    fn mkb(k: i32) big;\n    fn sumb(g: big) i32;\n    fn mku(i: i64) num;\n    fn getu(u: num) i64;\n    fn mkn(a: f64, b: i64, f: f32) nest;\n    fn sumn(n: nest) f64;\n}}\n\nfn main() i32 {{\n    if unsafe sump(unsafe mkp(1.5, 2)) != 3.5 {{\n        return 1;\n    }}\n    if unsafe dot3(unsafe mk3(1.0, 2.0, 3.0), unsafe mk3(4.0, 5.0, 6.0)) != 32.0 {{\n        return 2;\n    }}\n    if unsafe sumb(unsafe mkb(3)) != 33 {{\n        return 3;\n    }}\n    if unsafe getu(unsafe mku(41)) != 41 {{\n        return 4;\n    }}\n    if unsafe sumn(unsafe mkn(1.5, 2, 0.25)) != 4.25 {{\n        return 5;\n    }}\n    return 0;\n}}\n",
            p.dir(),
        ).as_str(),
    );
    assert(cli::superc_in(p.dir(), "build main.spc -o bin").ok(), "the program builds");
    assert_eq(p.run_bin(), 0);
}

// A header type whose layout bindgen cannot derive (a `long double` member) cannot be checked against its
// `@layout`: the build fails and names it.
@test
fn a_layout_bindgen_cannot_derive_is_an_error() {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("h.h", "typedef struct { double a; long double b; } pair;\ndouble sum(pair p);\n");
    p.mkfile(
        "main.spc",
        "extern \"C\" \"h.h\" {\n    @layout(16, 8)\n    type pair;\n    fn sum(p: pair) f64;\n}\n\nfn main() i32 {\n    return unsafe sum(unsafe zeroed::<pair>()) as i32;\n}\n",
    );
    let r = cli::superc_in(p.dir(), "build main.spc -o bin");
    assert(
        !r.ok() && r.out_has(
            "'pair' must have 16 bytes aligned to 8 in C ('@layout'), but its layout does not follow from \"h.h\"",
        ),
        "the layout is unchecked",
    );
}

// A native object holds the C header constants it reads, so an edit of the header rebuilds it; a rebuild
// that changes only `main` replays the std modules.
@test
fn header_edits_reach_native_objects() {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("val.h", "#define KVAL 40\n");
    p.mkfile(
        "main.spc",
        "extern \"C\" \"val.h\" {\n    const KVAL: i32;\n}\n\nfn main() i32 {\n    return KVAL + 1;\n}\n",
    );
    assert_eq(cli::superc_in(p.dir(), "run").exit, 41);
    p.mkfile("val.h", "#define KVAL 41\n");
    assert_eq(cli::superc_in(p.dir(), "run").exit, 42);
    p.mkfile(
        "main.spc",
        "extern \"C\" \"val.h\" {\n    const KVAL: i32;\n}\n\nfn main() i32 {\n    return KVAL + 2;\n}\n",
    );
    assert_eq(cli::superc_in(p.dir(), "run").exit, 43);
}

// A header's `static` function has no object that defines it: a call of it is an error that names it.
@test
fn a_call_of_a_header_static_function_is_an_error() {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("val.h", "static inline int one(void) { return 1; }\n");
    p.mkfile(
        "main.spc",
        "extern \"C\" \"val.h\" {\n    fn one() i32;\n}\n\nfn main() i32 {\n    return unsafe one();\n}\n",
    );
    let r = cli::superc_in(p.dir(), "build main.spc -o bin");
    assert(
        !r.ok() && r.out_has(
            "calls a function no object defines (a C header's `static` function, or an intrinsic the native backend lacks): `one`",
        ),
        "the call is refused",
    );
}

// The native objects under `dir` (`rel` its path below the tree's root), each as its relative path and
// its bytes, in listing order sorted by path.
fn objects(dir: str, rel: str, names: &mut Vector<String>, bodies: &mut Vector<String>) {
    let mut d = fs::read_dir(dir).unwrap();
    while let Some(Ok(e)) = d.next() {
        let path = format("{}/{}", dir, e.name);
        let r = format("{}/{}", rel, e.name);
        if e.kind == Option::<fs::FileKind>::Some(fs::FileKind::Dir) {
            objects(&path, &r, names, bodies);
        } else if e.name.ends_with(".o") {
            names.push(r);
            bodies.push(cli::read_text(&path));
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
        key.push(hash(names.at(k)) << 16 | k as u64);
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

// Inline assembly compiles natively: register, immediate, memory and matching operands, a `+` operand,
// named registers (x86-64), a loop on a local label, `%=`, and a clobbered callee-saved register while
// a loop keeps a value in one.
const INLINE_ASM: str<'static> = M"(@arch(aarch64)
fn work(x: i64, y: i64) i64 {
    let mut a: i64 = 0;
    let mut b: i64 = x;
    let mut m: i64 = 0;
    let mut s: i64 = 0;
    let mut n: i64 = 3;
    let mut acc: i64 = 0;
    let mut w: i32 = 0;
    let mut c: i64 = 0;
    unsafe {
        asm("add %0, %1, %2" : "=r"(a) : "r"(x), "r"(y));
        asm("add %0, %1, %2" : "=r"(c) : "r"(x * 3), "r"(y + 1));
        asm("add %0, %0, #%1" : "+r"(b) : "i"(5));
        asm("ldr %0, %1" : "=r"(m) : "m"(y));
        asm("str %1, %0" : "=m"(s) : "r"(a));
        asm("1:\n add %1, %1, #2\n subs %0, %0, #1\n b.ne 1b" : "+r"(n), "+r"(acc) :  : "cc");
        asm("add %w0, %w0, #1 // %=" : "=r"(w) : "0"(41));
        asm("mov x19, #0\n mov x20, #0" :  :  : "x19", "x20", "d8");
    }
    return a + b + m + s + acc + w as i64 + c;
}

@arch(x86_64)
fn work(x: i64, y: i64) i64 {
    let mut a: i64 = 0;
    let mut b: i64 = x;
    let mut m: i64 = 0;
    let mut s: i64 = 0;
    let mut n: i64 = 3;
    let mut acc: i64 = 0;
    let mut w: i32 = 0;
    let mut hi: i64 = 0;
    let mut c: i64 = 0;
    unsafe {
        asm("leaq (%1,%2), %0" : "=r"(a) : "r"(x), "r"(y));
        asm("leaq (%1,%2), %0" : "=r"(c) : "r"(x * 3), "r"(y + 1));
        asm("addq %1, %0" : "+r"(b) : "i"(5));
        asm("movq %1, %0" : "=r"(m) : "m"(y));
        asm("movq %1, %0" : "=m"(s) : "r"(a));
        asm("1:\n addq $2, %1\n decq %0\n jne 1b" : "+r"(n), "+r"(acc) :  : "cc");
        asm("addl $1, %k0 # %=" : "=r"(w) : "0"(41));
        asm("movq %%rax, %%rdx" : "=d"(hi) : "a"(x));
        asm("xorl %%ebx, %%ebx\n xorl %%r12d, %%r12d" :  :  : "rbx", "r12");
    }
    return a + b + m + s + acc + w as i64 + hi - x + c;
}

@arch(wasm32)
fn work(x: i64, y: i64) i64 {
    return 6 * x + 3 * y + 64;
}

fn main() i32 {
    let mut t: i64 = 0;
    let mut i: i64 = 0;
    // The loop keeps `t` and `i` in callee-saved registers across the clobbers.
    while i < 4 {
        t += work(i, 10);
        i += 1;
    }
    // 6x + 3y + 64 per call: 6 * 6 + 4 * 94.
    return (t - 412) as i32;
}
)";

// Calls whose arguments the backends move without a copy, run against the C driver: an aggregate result
// into the caller's memory, from a body that returns nothing (`fwd_sret`, a sibling call), an aggregate
// argument by its address, swapped with a scalar one (`fwd_ref`), constant stack arguments and swapped
// register ones (`swap_many`), stack arguments from the registers the register arguments then take
// (`regs_many`), and a sum of stack parameters (`sum10`, which x86-64 adds from memory).
@test
fn calls_pass_results_and_arguments_in_place() {
    let lir = M"(lir ptr 8
sym @mk fn global ext
sym @take fn global ext
sym @many fn global ext
sym @fwd_sret fn global
sym @fwd_ref fn global
sym @swap_many fn global
sym @regs_many fn global
sym @sum10 fn global
fn @fwd_sret
  layout l0 size 40 align 3 [0 i64, 8 i64, 16 i64, 24 i64, 32 i64]
  sig (ptr, i64) -> void
  ref p0 40 noalias
b0(v0: ptr, v1: i64):
  call @mk(v1, v0) : (i64) -> l0
  ret
fn @fwd_ref
  layout l0 size 40 align 3 [0 i64, 8 i64, 16 i64, 24 i64, 32 i64]
  sig (i64, ptr) -> i64
  ref p1 40 readonly
b0(v0: i64, v1: ptr):
  v2 = call.i64 @take(v1, v0) : (l0, i64) -> i64
  ret v2
fn @swap_many
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 2
  v5 = call.i64 @many(v1, v0, v2, v2, v2, v2, v2, v2, v3, v4) : (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) -> i64
  ret v5
fn @regs_many
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = call.i64 @many(v0, v1, v0, v1, v0, v1, v0, v1, v0, v1) : (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) -> i64
  v3 = add.i64 v2, v0
  ret v3
fn @sum10
  sig (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64, v3: i64, v4: i64, v5: i64, v6: i64, v7: i64, v8: i64, v9: i64):
  v10 = add.i64 v0, v1
  v11 = add.i64 v10, v2
  v12 = add.i64 v11, v3
  v13 = add.i64 v12, v4
  v14 = add.i64 v13, v5
  v15 = add.i64 v14, v6
  v16 = sub.i64 v15, v7
  v17 = sub.i64 v16, v8
  v18 = add.i64 v9, v17
  ret v18
)";
    let mut obj = Vector::<u8>::new();
    let x64 = tgt::axis_index("x86_64", true);
    assert(object_of(lir, tgt::axis_index("linux", false), x64, TAIL, &mut obj), "the System V object");
    assert(object_of(lir, tgt::axis_index("windows", false), x64, TAIL, &mut obj), "the Microsoft x64 object");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = M"(#include <stdint.h>
struct B { int64_t a, b, c, d, e; };
struct B mk(int64_t a) { struct B r = {a, a + 1, a + 2, a + 3, a + 4}; return r; }
int64_t take(struct B b, int64_t k) { return b.a * k + b.e; }
int64_t many(int64_t a, int64_t b, int64_t c, int64_t d, int64_t e, int64_t f, int64_t g, int64_t h, int64_t i, int64_t j) {
  return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h + 9 * i + 10 * j;
}
void fwd_sret(struct B *, int64_t);
int64_t fwd_ref(int64_t, const struct B *);
int64_t swap_many(int64_t, int64_t);
int64_t regs_many(int64_t, int64_t);
int64_t sum10(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
int main(void) {
  struct B b = {0, 0, 0, 0, 0};
  fwd_sret(&b, 7);
  if (b.a != 7 || b.c != 9 || b.e != 11) return 1;
  if (fwd_ref(3, &b) != 32 || b.a != 7) return 2;
  if (swap_many(3, 5) != 40) return 3;
  if (regs_many(3, 5) != 228) return 4;
  if (sum10(1, 2, 4, 8, 16, 32, 64, 128, 256, 512) != 127 - 128 - 256 + 512) return 5;
  return 0;
}
)";
    assert_eq(run_native_with(lir, drv, TAIL), 0);
    assert_eq(run_native(lir, drv), 0);
}

// An aggregate parameter whose one use is an argument the call takes in registers of the same parts goes
// on in the registers it arrived in: `down` and `step` pass it on to each other in sibling calls (through
// a pointer too), their argument registers swapped, ten million deep in a constant stack; `shifty` holds
// its registers over a shift and a division (rcx and rdx on System V), `fswap` its float registers. An
// 8-byte aggregate passed on by its address (`by_addr`) keeps its memory, which the frame holds: no
// sibling call (`peek` writes its own stack before it reads it).
@test
fn aggregate_parameters_pass_on_in_their_registers() {
    let lir = M"(lir ptr 8
sym @fin fn global
sym @step fn global
sym @down fn global
sym @eat fn global ext
sym @shifty fn global
sym @fsum fn global ext
sym @fswap fn global
sym @peek fn global ext
sym @by_addr fn global
fn @by_addr
  layout l0 size 8 align 3 [0 i64]
  sig (l0) -> i64
b0(v0: ptr):
  v1 = call.i64 @peek(v0) : (ptr) -> i64
  ret v1
fn @fin
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64, l0) -> i64
b0(v0: i64, v1: ptr):
  v2 = load.i64 v1 align 3
  v3 = load.i64 v1+8 align 3
  v4 = sub.i64 v2, v3
  v5 = add.i64 v4, v0
  ret v5
fn @step
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64, l0) -> i64
b0(v0: i64, v1: ptr):
  v2 = call.i64 @down(v1, v0) : (l0, i64) -> i64
  ret v2
fn @down
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (l0, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.eq v1, v2
  v4 = symaddr @fin
  v5 = symaddr @step
  v6 = select.ptr v3, v4, v5
  v7 = iconst.i64 1
  v8 = sub.i64 v1, v7
  v9 = call.ind.i64 v6(v8, v0) : (i64, l0) -> i64
  ret v9
fn @shifty
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64, i64, l0) -> i64
b0(v0: i64, v1: i64, v2: ptr):
  v3 = shl.i64 v0, v1
  v4 = sdiv.i64 v0, v1
  v5 = add.i64 v3, v4
  v6 = call.i64 @eat(v2, v5) : (l0, i64) -> i64
  ret v6
fn @fswap
  layout l0 size 16 align 3 [0 f64, 8 f64]
  sig (f64, l0) -> f64
b0(v0: f64, v1: ptr):
  v2 = call.f64 @fsum(v1, v0) : (l0, f64) -> f64
  ret v2
)";
    let mut obj = Vector::<u8>::new();
    let x64 = tgt::axis_index("x86_64", true);
    assert(object_of(lir, tgt::axis_index("linux", false), x64, TAIL, &mut obj), "the System V object");
    assert(object_of(lir, tgt::axis_index("windows", false), x64, TAIL, &mut obj), "the Microsoft x64 object");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = M"(#include <stdint.h>
struct P { int64_t a, b; };
struct F { double x, y; };
int64_t down(struct P, int64_t);
int64_t shifty(int64_t, int64_t, struct P);
double fswap(double, struct F);
struct Q { int64_t a; };
int64_t by_addr(struct Q);
int64_t peek(const struct Q *q) {
  volatile int64_t pad[64];
  for (int i = 0; i < 64; i++) pad[i] = -1;
  return q->a + 1 + pad[0] + 1;
}
int64_t eat(struct P p, int64_t v) { return p.a * 3 + p.b * 5 + v; }
double fsum(struct F f, double x) { return f.x * 2 + f.y * 3 + x; }
int main(void) {
  struct P p = {7, 100};
  if (down(p, 10000000) != -94 || down(p, 0) != -94) return 1;
  if (shifty(13, 3, p) != 629) return 2;
  struct F f = {1.5, 2.25};
  if (fswap(0.5, f) != 10.25) return 3;
  struct Q q = {41};
  if (by_addr(q) != 42) return 4;
  return 0;
}
)";
    assert_eq(run_native_with(lir, drv, TAIL), 0);
}

@test
fn inline_assembly_compiles_natively() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", INLINE_ASM);
    // The x86-64 forms compile for both of its targets; the link needs their C toolchains.
    for os in ["linux", "windows"] {
        let r = cli::superc_env_in(
            p.dir(),
            "SC_NATIVE_STATS",
            "1",
            format("build --target={} --arch=x86_64 main.spc -o bin", os).as_str(),
        );
        assert(r.out_has("main native"), "main compiles natively for x86-64");
    }
    if !nat::supported(tgt::host_os(), tgt::host_isa()) || !nat::asm_native(tgt::host_os(), tgt::host_isa()) {
        return;
    }
    assert(cli::superc_in(p.dir(), "build main.spc -o bin").ok(), "the program builds");
    assert_eq(p.run_bin(), 0);
}

// Whether the LIR optimizer runs is part of what a project's emission and a module's object are a
// function of: a build that turns it on compiles again rather than taking the last build's tree and
// objects, and one that turns it off again gives the first build's bytes.
@test
fn a_build_that_switches_the_optimizer_compiles_again() {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"bin\"\nroot = \"main.spc\"\n");
    p.mkfile(
        "main.spc",
        "fn main(args: Vector<str>) i32 {\n    let mut s: usize = 0;\n    for i in 0..args.len() {\n        s += i * 3;\n    }\n    return s as i32;\n}\n",
    );
    let mut bins = Vector::<String>::new();
    for opt in ["0", "1", "0"] {
        let r = cli::superc_env_in(p.dir(), "SC_LIR_OPT", opt, "build");
        if !r.ok() {
            r.show();
        }
        assert(r.ok(), "the program builds");
        assert_eq(p.run_bin(), 0);
        bins.push(
            loader::read_file(format("{}/bin{}", p.dir(), unsafe str::from_cstr(cli::binext())).as_str()).unwrap(),
        );
    }
    assert(bins[0].as_str() != bins[1].as_str(), "the optimized build compiles again");
    assert(bins[0].as_str() == bins[2].as_str(), "the unoptimized build gives its bytes again");
}

// A load or store whose address is a `ptradd` with an index and no other use reads the index in its
// own address (`Live::fold`): every access width, scaled by its size or by 1, and a vector.
@test
fn indexed_accesses_fold_their_address() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @ld8 fn global
sym @ld16 fn global
sym @ld32 fn global
sym @ld64 fn global
sym @ldf fn global
sym @ldb fn global
sym @st32 fn global
sym @cpv fn global
fn @ld8
  sig (ptr, i64) -> i8
b0(v0: ptr, v1: i64):
  v2 = ptradd v0, v1 * 1
  v3 = load.i8 v2 align 0
  ret v3
fn @ld16
  sig (ptr, i64) -> i16
b0(v0: ptr, v1: i64):
  v2 = ptradd v0, v1 * 2
  v3 = load.i16 v2 align 1
  ret v3
fn @ld32
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = ptradd v0, v1 * 4
  v3 = load.i32 v2 align 2
  ret v3
fn @ld64
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = ptradd v0, v1 * 8
  v3 = iconst.i64 1
  v4 = add.i64 v1, v3
  v5 = load.i64 v2 align 3
  v6 = add.i64 v5, v4
  ret v6
fn @ldf
  sig (ptr, i64) -> f64
b0(v0: ptr, v1: i64):
  v2 = ptradd v0, v1 * 8
  v3 = load.f64 v2 align 3
  ret v3
fn @ldb
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = ptradd v0, v1 * 1
  v3 = load.i64 v2 align 0
  ret v3
fn @st32
  sig (ptr, i64, i32) -> void
b0(v0: ptr, v1: i64, v2: i32):
  v3 = ptradd v0, v1 * 4
  store v2, v3 align 2
  ret
fn @cpv
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = ptradd v1, v2 * 16
  v4 = load.v4i32 v3 align 2
  v5 = ptradd v0, v2 * 16
  store v4, v5 align 2
  ret
)";
    let drv = M"(#include <stdint.h>
#include <string.h>
int8_t ld8(const void *, int64_t);
int16_t ld16(const void *, int64_t);
int32_t ld32(const void *, int64_t);
int64_t ld64(const void *, int64_t);
double ldf(const void *, int64_t);
int64_t ldb(const void *, int64_t);
void st32(void *, int64_t, int32_t);
void cpv(void *, const void *, int64_t);
int main(void) {
  int8_t b[4] = {1, 2, 3, 4};
  int16_t h[4] = {10, 20, 30, 40};
  int32_t w[4] = {100, -200, 300, 400};
  int64_t q[4] = {1000, -2000, 3000, 4000};
  double d[4] = {0.5, 1.5, 2.5, 3.5};
  unsigned char raw[16] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
  int32_t v[8] = {1, 2, 3, 4, 5, 6, 7, 8}, o[8] = {0};
  if (ld8(b, 1) != 2) return 1;
  if (ld16(h, 2) != 30) return 2;
  if (ld32(w, 1) != -200) return 3;
  if (ld64(q, 3) != 4004) return 4;
  if (ldf(d, 2) != 2.5) return 5;
  int64_t x;
  memcpy(&x, raw + 3, 8);
  if (ldb(raw, 3) != x) return 6;
  st32(w, 3, -7);
  if (w[3] != -7 || w[2] != 300) return 7;
  cpv(o, v, 1);
  if (o[4] != 5 || o[7] != 8 || o[0] != 0) return 8;
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
}

// Forty loops in one function, each counter stepping in its parameter's register and each loop holding a
// float constant in a register: every loop's registers free at its end, so the last loop has as many as
// the first.
@test
fn many_loops_free_their_registers() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let mut lir = String::from_str(
        "lir ptr 8\nsym @many fn global\nfn @many\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = iconst.i64 0\n  v2 = iconst.i64 1\n  v3 = fconst.f64 0x0\n  v4 = fconst.f64 0x3ff8000000000000\n  jmp b1(v1, v1, v3)\n",
    );
    // Loop j: header b(3j+1), body b(3j+2), exit b(3j+3); values from 9j + 5.
    let n: u32 = 40;
    for j in 0..n {
        let h = 3 * j + 1;
        let v = 9 * j + 5;
        lir.format_into("b{}(v{}: i64, v{}: i64, v{}: f64):\n", h, v, v + 1, v + 2);
        lir.format_into("  v{} = icmp.ult v{}, v0\n  br v{}, b{}, b{}\n", v + 3, v, v + 3, h + 1, h + 2);
        lir.format_into("b{}:\n  v{} = iconst.i64 {}\n  v{} = add.i64 v{}, v{}\n", h + 1, v + 4, j, v + 5, v + 1, v);
        lir.format_into("  v{} = add.i64 v{}, v{}\n  v{} = fadd.f64 v{}, v4\n", v + 6, v + 5, v + 4, v + 7, v + 2);
        lir.format_into("  v{} = add.i64 v{}, v2\n  jmp b{}(v{}, v{}, v{})\n", v + 8, v, h, v + 8, v + 6, v + 7);
        if j + 1 < n {
            lir.format_into("b{}:\n  jmp b{}(v1, v{}, v{})\n", h + 2, h + 3, v + 1, v + 2);
        } else {
            lir.format_into(
                "b{}:\n  v{} = fptosi.i64 v{}\n  v{} = add.i64 v{}, v{}\n  ret v{}\n",
                h + 2,
                v + 9,
                v + 2,
                v + 10,
                v + 1,
                v + 9,
                v + 10,
            );
        }
    }
    // Per loop with n = 4: 0 + 1 + 2 + 3 + 4j, and 4 * 1.5 = 6.
    let drv = "#include <stdint.h>\nint64_t many(int64_t);\nint main(void) { return many(4) == 3360 + 240 ? 0 : 1; }\n";
    assert_eq(run_native(&lir, drv), 0);
    assert_eq(run_wasm(&lir, drv), 0);
}

// A vector conversion case of `vector_conversions_and_lane_shifts_run`: LIR types `from` and `to`,
// operation `op`, C lane types `cf` and `ct`, `n` lanes, a lane's input of `i` and its result of `x` (a
// shift's of `x` by `s`).
struct Conv {
    pub from: str<'static>,
    pub to: str<'static>,
    pub op: str<'static>,
    pub cf: str<'static>,
    pub ct: str<'static>,
    pub n: u32,
    pub init: str<'static>,
    pub res: str<'static>,
}

extend Conv as Copy {}

// Vector conversions of each kind the loop vectorizer mixes widths with (`Package.vops`), and shifts of
// each lane by its own amount: in vector registers where the target has the form (x86-64: SSE2 for
// integer widening and narrowing, i32 to f32 and back, f32 to f64 and back, AVX2 for those of 32-byte
// vectors and for the shifts), lane by lane in memory elsewhere. A float to an integer saturates (NaN
// gives 0), as the scalar conversion does.
@test
fn vector_conversions_and_lane_shifts_run() {
    let cases: []Conv = [
        Conv {
            from: "v4i32",
            to: "v4f32",
            op: "sitofp",
            cf: "int32_t",
            ct: "float",
            n: 4,
            init: "(int32_t)(i * 0x9E3779B9u)",
            res: "(float)x",
        },
        Conv {
            from: "v4f32",
            to: "v4i32",
            op: "fptosi",
            cf: "float",
            ct: "int32_t",
            n: 4,
            init: "fl[i % 8]",
            res: "sat32(x)",
        },
        Conv {
            from: "v4i16",
            to: "v4i32",
            op: "sext",
            cf: "int16_t",
            ct: "int32_t",
            n: 4,
            init: "(int16_t)(i * 40503u)",
            res: "(int32_t)x",
        },
        Conv {
            from: "v4i16",
            to: "v4i32",
            op: "zext",
            cf: "int16_t",
            ct: "int32_t",
            n: 4,
            init: "(int16_t)(i * 40503u)",
            res: "(int32_t)(uint16_t)x",
        },
        Conv {
            from: "v2i64",
            to: "v2i32",
            op: "trunc",
            cf: "int64_t",
            ct: "int32_t",
            n: 2,
            init: "(int64_t)(i * 0x9E3779B97F4A7C15u)",
            res: "(int32_t)(uint32_t)x",
        },
        Conv {
            from: "v4i32",
            to: "v4i16",
            op: "trunc",
            cf: "int32_t",
            ct: "int16_t",
            n: 4,
            init: "(int32_t)(i * 0x9E3779B9u)",
            res: "(int16_t)(uint16_t)x",
        },
        Conv {
            from: "v8i16",
            to: "v8i8",
            op: "trunc",
            cf: "int16_t",
            ct: "int8_t",
            n: 8,
            init: "(int16_t)(i * 40503u)",
            res: "(int8_t)(uint8_t)x",
        },
        Conv {
            from: "v8i8",
            to: "v8i16",
            op: "sext",
            cf: "int8_t",
            ct: "int16_t",
            n: 8,
            init: "(int8_t)(i * 157u)",
            res: "(int16_t)x",
        },
        Conv {
            from: "v2i32",
            to: "v2i64",
            op: "zext",
            cf: "int32_t",
            ct: "int64_t",
            n: 2,
            init: "(int32_t)(i * 0x9E3779B9u)",
            res: "(int64_t)(uint32_t)x",
        },
        Conv {
            from: "v2f32",
            to: "v2f64",
            op: "fpext",
            cf: "float",
            ct: "double",
            n: 2,
            init: "fin[i % 8]",
            res: "(double)x",
        },
        Conv {
            from: "v2f64",
            to: "v2f32",
            op: "fptrunc",
            cf: "double",
            ct: "float",
            n: 2,
            init: "(double)fin[i % 8] * 1.000001",
            res: "(float)x",
        },
        Conv {
            from: "v2i64",
            to: "v2f64",
            op: "sitofp",
            cf: "int64_t",
            ct: "double",
            n: 2,
            init: "(int64_t)(i * 0x9E3779B97F4A7C15u)",
            res: "(double)x",
        },
        Conv {
            from: "v4i32",
            to: "v4f32",
            op: "uitofp",
            cf: "int32_t",
            ct: "float",
            n: 4,
            init: "(int32_t)(i * 0x9E3779B9u)",
            res: "(float)(uint32_t)x",
        },
        Conv {
            from: "v4f32",
            to: "v4i32",
            op: "fptoui",
            cf: "float",
            ct: "int32_t",
            n: 4,
            init: "fl[i % 8]",
            res: "(int32_t)satu32(x)",
        },
        Conv {
            from: "v8i32",
            to: "v8f32",
            op: "sitofp",
            cf: "int32_t",
            ct: "float",
            n: 8,
            init: "(int32_t)(i * 0x9E3779B9u)",
            res: "(float)x",
        },
        Conv {
            from: "v8f32",
            to: "v8i32",
            op: "fptosi",
            cf: "float",
            ct: "int32_t",
            n: 8,
            init: "fl[i % 8]",
            res: "sat32(x)",
        },
        Conv {
            from: "v8i16",
            to: "v8i32",
            op: "sext",
            cf: "int16_t",
            ct: "int32_t",
            n: 8,
            init: "(int16_t)(i * 40503u)",
            res: "(int32_t)x",
        },
        Conv {
            from: "v8i16",
            to: "v8i32",
            op: "zext",
            cf: "int16_t",
            ct: "int32_t",
            n: 8,
            init: "(int16_t)(i * 40503u)",
            res: "(int32_t)(uint16_t)x",
        },
        Conv {
            from: "v4i64",
            to: "v4i32",
            op: "trunc",
            cf: "int64_t",
            ct: "int32_t",
            n: 4,
            init: "(int64_t)(i * 0x9E3779B97F4A7C15u)",
            res: "(int32_t)(uint32_t)x",
        },
        Conv {
            from: "v8i32",
            to: "v8i16",
            op: "trunc",
            cf: "int32_t",
            ct: "int16_t",
            n: 8,
            init: "(int32_t)(i * 0x9E3779B9u)",
            res: "(int16_t)(uint16_t)x",
        },
        Conv {
            from: "v16i16",
            to: "v16i8",
            op: "trunc",
            cf: "int16_t",
            ct: "int8_t",
            n: 16,
            init: "(int16_t)(i * 40503u)",
            res: "(int8_t)(uint8_t)x",
        },
        Conv {
            from: "v16i8",
            to: "v16i16",
            op: "sext",
            cf: "int8_t",
            ct: "int16_t",
            n: 16,
            init: "(int8_t)(i * 157u)",
            res: "(int16_t)x",
        },
        Conv {
            from: "v4i32",
            to: "v4i64",
            op: "zext",
            cf: "int32_t",
            ct: "int64_t",
            n: 4,
            init: "(int32_t)(i * 0x9E3779B9u)",
            res: "(int64_t)(uint32_t)x",
        },
        Conv {
            from: "v4f32",
            to: "v4f64",
            op: "fpext",
            cf: "float",
            ct: "double",
            n: 4,
            init: "fin[i % 8]",
            res: "(double)x",
        },
        Conv {
            from: "v4f64",
            to: "v4f32",
            op: "fptrunc",
            cf: "double",
            ct: "float",
            n: 4,
            init: "(double)fin[i % 8] * 1.000001",
            res: "(float)x",
        },
    ];
    let shifts: []Conv = [
        Conv {
            from: "v4i32",
            to: "v4i32",
            op: "shl",
            cf: "int32_t",
            ct: "int32_t",
            n: 4,
            init: "",
            res: "(int32_t)((uint32_t)x << s)",
        },
        Conv {
            from: "v4i32",
            to: "v4i32",
            op: "lshr",
            cf: "int32_t",
            ct: "int32_t",
            n: 4,
            init: "",
            res: "(int32_t)((uint32_t)x >> s)",
        },
        Conv { from: "v4i32", to: "v4i32", op: "ashr", cf: "int32_t", ct: "int32_t", n: 4, init: "", res: "x >> s" },
        Conv {
            from: "v2i64",
            to: "v2i64",
            op: "shl",
            cf: "int64_t",
            ct: "int64_t",
            n: 2,
            init: "",
            res: "(int64_t)((uint64_t)x << s)",
        },
        Conv {
            from: "v2i64",
            to: "v2i64",
            op: "lshr",
            cf: "int64_t",
            ct: "int64_t",
            n: 2,
            init: "",
            res: "(int64_t)((uint64_t)x >> s)",
        },
        Conv { from: "v2i64", to: "v2i64", op: "ashr", cf: "int64_t", ct: "int64_t", n: 2, init: "", res: "x >> s" },
        Conv {
            from: "v8i32",
            to: "v8i32",
            op: "shl",
            cf: "int32_t",
            ct: "int32_t",
            n: 8,
            init: "",
            res: "(int32_t)((uint32_t)x << s)",
        },
        Conv { from: "v8i32", to: "v8i32", op: "ashr", cf: "int32_t", ct: "int32_t", n: 8, init: "", res: "x >> s" },
        Conv {
            from: "v4i64",
            to: "v4i64",
            op: "lshr",
            cf: "int64_t",
            ct: "int64_t",
            n: 4,
            init: "",
            res: "(int64_t)((uint64_t)x >> s)",
        },
    ];
    let mut lir = String::from_str("lir ptr 8\n");
    let mut drv = String::from_str(
        "#include <stdint.h>\n#include <string.h>\n#include <math.h>\nstatic const float fl[8] = {0.0f, -0.5f, 1.5f, 3e9f, -3e9f, NAN, 2147483520.0f, -2147483648.0f};\nstatic const float fin[8] = {0.0f, -0.5f, 1.5f, 3e9f, -3e9f, 1e-40f, 3.4e38f, -7.25f};\nstatic int32_t sat32(float f) { return f != f ? 0 : f >= 2147483648.0f ? INT32_MAX : f < -2147483648.0f ? INT32_MIN : (int32_t)f; }\nstatic uint32_t satu32(float f) { return f != f || f <= -1.0f ? 0 : f >= 4294967296.0f ? UINT32_MAX : (uint32_t)f; }\n",
    );
    let mut body = String::from_str("int main(void) {\n  int r = 0;\n");
    for k in 0..cases.len() {
        let c = cases[k];
        lir.format_into(
            "sym @c{} fn global\nfn @c{}\n  sig (ptr, ptr) -> void\nb0(v0: ptr, v1: ptr):\n  v2 = load.{} v1 align 0\n  v3 = {}.{} v2\n  store v3, v0 align 0\n  ret\n",
            k,
            k,
            c.from,
            c.op,
            c.to,
        );
        drv.format_into("void c{}(void *, const void *);\n", k);
        body.format_into(
            "  {{\n    {} a[64]; {} o[64];\n    for (int i = 0; i < 64; i++) a[i] = {};\n    for (int b = 0; b < 64; b += {}) c{}(o + b, a + b);\n    for (int i = 0; i < 64; i++) {{ {} x = a[i]; {} e = {}; if (memcmp(&e, &o[i], sizeof e) != 0) r = {}; }}\n  }}\n",
            c.cf,
            c.ct,
            c.init,
            c.n,
            k,
            c.cf,
            c.ct,
            c.res,
            k + 1,
        );
    }
    for k in 0..shifts.len() {
        let c = shifts[k];
        let bits = if c.cf == "int32_t" {
            32
        } else {
            64
        };
        lir.format_into(
            "sym @s{} fn global\nfn @s{}\n  sig (ptr, ptr, ptr) -> void\nb0(v0: ptr, v1: ptr, v2: ptr):\n  v3 = load.{} v1 align 0\n  v4 = load.{} v2 align 0\n  v5 = {}.{} v3, v4\n  store v5, v0 align 0\n  ret\n",
            k,
            k,
            c.from,
            c.from,
            c.op,
            c.from,
        );
        drv.format_into("void s{}(void *, const void *, const void *);\n", k);
        body.format_into(
            "  {{\n    {} a[64], m[64], o[64];\n    for (int i = 0; i < 64; i++) {{ a[i] = ({})(i * 0x9E3779B97F4A7C15u); m[i] = (i * 7 + 3) % {}; }}\n    for (int b = 0; b < 64; b += {}) s{}(o + b, a + b, m + b);\n    for (int i = 0; i < 64; i++) {{ {} x = a[i]; int s = (int)m[i]; if (({}) != o[i]) r = {}; }}\n  }}\n",
            c.cf,
            c.cf,
            bits,
            c.n,
            k,
            c.cf,
            c.res,
            k + 41,
        );
    }
    body.push_str("  return r;\n}\n");
    drv.push_str(&body);
    let mut obj = Vector::<u8>::new();
    let x64 = tgt::axis_index("x86_64", true);
    assert(object_of(&lir, tgt::axis_index("linux", false), x64, 0, &mut obj), "the SSE2 object");
    assert(object_of(&lir, tgt::axis_index("linux", false), x64, WIDE, &mut obj), "the AVX2 object");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    assert_eq(run_native(&lir, &drv), 0);
    assert_eq(run_wide(&lir, &drv), 0);
    assert_eq(run_wasm(&lir, &drv), 0);
}

// The little-endian `n`-byte word at byte `at` of `b`.
fn word_at(b: &Vector<u8>, at: u32, n: u32) u32 {
    let mut w: u32 = 0;
    for k in 0..n {
        w |= b[(at + k) as usize] as u32 << 8 * k;
    }
    return w;
}

// The file offset of the raw data of the COFF section named `name` of object `b`, its size in the high
// half; 0 when there is none.
fn coff_section(b: &Vector<u8>, name: str) u64 {
    let ns = word_at(b, 2, 2);
    let at = 20 + word_at(b, 16, 2);
    for s in 0..ns {
        let h = at + 40 * s;
        let mut ok = true;
        for k in 0..8u32 {
            let c = if k as usize < name.len() {
                name.byte_at(k as usize)
            } else {
                0u8
            };
            ok = ok && b[(h + k) as usize] == c;
        }
        if ok {
            return word_at(b, h + 16, 4) as u64 << 32 | word_at(b, h + 20, 4) as u64;
        }
    }
    return 0;
}

// Vector forms wasm32 computes in SIMD128 registers that the other run tests reach in memory alone: an
// extension of a vector of 8 bytes whose lanes a lane loop computed (wasm32: `i16x8.load8x8_s` from its
// home), a shuffle of two vectors' lanes, a float tree sum, and the NaN-propagating minimum and maximum
// (a NaN operand's bits, the first one's before the second's; -0 below +0) and C's `fmin` (the other
// operand of a NaN, the first of two with its quiet bit set).
@test
fn vector_forms_of_simd128_run() {
    let lir = M"(lir ptr 8
sym @forms fn global
fn @forms
  sig (ptr, ptr, ptr) -> void
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.v8i8 v0 align 0
  v4 = vop.count_ones.v8i8 (v3)
  v5 = sext.v8i16 v4
  store v5, v2 align 0
  v6 = sext.v8i16 v3
  store v6, v2+16 align 0
  v7 = load.v4i32 v0 align 0
  v8 = load.v4i32 v1 align 0
  v9 = vop.shuffle.v4i32 (v7, v8) lanes [3, 6, 5, 0]
  store v9, v2+32 align 0
  v10 = load.v4f32 v0 align 0
  v11 = load.v4f32 v1 align 0
  v12 = vop.reduce_add_tree.f32 (v10)
  store v12, v2+48 align 0
  v13 = vop.minimum.v4f32 (v10, v11)
  store v13, v2+64 align 0
  v14 = vop.maximum.v4f32 (v10, v11)
  store v14, v2+80 align 0
  v15 = vop.min.num.v4f32 (v10, v11)
  store v15, v2+96 align 0
  ret
)";
    let drv = M"(#include <stdint.h>
#include <string.h>
void forms(const void *, const void *, void *);
static const uint32_t F[8] = {0x00000000u, 0x80000000u, 0x3F800000u, 0xC0400000u, 0x7FC00001u, 0xFFA00000u, 0x41200000u, 0x3E800000u};
static int nan32(uint32_t x) { return (x & 0x7FFFFFFFu) > 0x7F800000u; }
static float f32v(uint32_t u) { float x; memcpy(&x, &u, 4); return x; }
static uint32_t b32(float x) { uint32_t u; memcpy(&u, &x, 4); return u; }
/* The minimum (`lo`) or maximum: a NaN operand, `x` first; of equal values the one of the side's sign. */
static uint32_t ext(uint32_t x, uint32_t y, int lo) {
  if (nan32(x)) return x;
  if (nan32(y)) return y;
  float a = f32v(x), b = f32v(y);
  if (a == b) return lo ? (x | y) : (x & y);
  return (lo ? a < b : a > b) ? x : y;
}
/* A signaling NaN gives what the scalar instruction gives (arm64's FMINNM: the default NaN); wasm32 has none. */
#ifdef __wasm__
#define WASM 1
#else
#define WASM 0
#endif
static int snan(uint32_t x) { return nan32(x) && (x & 0x00400000u) == 0; }
static uint32_t num(uint32_t x, uint32_t y) {
  if (nan32(x) && nan32(y)) return x | 0x00400000u;
  return ext(nan32(x) ? y : x, nan32(y) ? x : y, 1);
}
int main(void) {
  for (int r = 0; r < 64; r++) {
    uint32_t a[4], b[4], o[28];
    for (int k = 0; k < 4; k++) { a[k] = F[(r + k) % 8]; b[k] = F[(r / 8 + 3 * k) % 8]; }
    if (r % 2 == 1) { a[0] = 0x9E3779B9u * (uint32_t)r; a[1] = 0x80FF7F01u; }
    forms(a, b, o);
    const int8_t *ab = (const int8_t *)a;
    const int16_t *h = (const int16_t *)o;
    for (int k = 0; k < 8; k++) {
      if (h[k] != (int16_t)(int8_t)__builtin_popcount((uint8_t)ab[k])) return 1;
      if (h[8 + k] != (int16_t)ab[k]) return 2;
    }
    if (o[8] != a[3] || o[9] != b[2] || o[10] != b[1] || o[11] != a[0]) return 3;
    float s = (f32v(a[0]) + f32v(a[2])) + (f32v(a[1]) + f32v(a[3]));
    if (o[12] != b32(s) && !(nan32(o[12]) && nan32(b32(s)))) return 4;
    for (int k = 0; k < 4; k++) {
      if (o[16 + k] != ext(a[k], b[k], 1)) return 5;
      if (o[20 + k] != ext(a[k], b[k], 0)) return 6;
      if (o[24 + k] != num(a[k], b[k]) && (WASM || !snan(a[k]) && !snan(b[k]))) return 7;
    }
  }
  return 0;
}
)";
    if !cli::has_cc() {
        return; // a C driver links it
    }
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Swaps of a vector's lanes (`lv::lane_perm`: the 8-byte halves, the lanes within each 8 bytes, both) are
// one shuffle in registers: x86-64's PSHUFD (immediates 0x4E, 0xB1, 0x1B), arm64's EXT and REV64. They run.
@test
fn lane_swaps_run_in_registers() {
    let src = M"(lir ptr 8
sym @sw fn global
fn @sw
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  v2 = load.v4f32 v0 align 0
  v3 = vop.swizzle.v4f32 (v2) lanes [2, 3, 0, 1]
  v4 = vop.swizzle.v4f32 (v2) lanes [1, 0, 3, 2]
  v5 = vop.swizzle.v4f32 (v2) lanes [3, 2, 1, 0]
  v6 = load.v2f64 v0 align 0
  v7 = vop.swizzle.v2f64 (v6) lanes [1, 0]
  store v3, v1 align 0
  store v4, v1+16 align 0
  store v5, v1+32 align 0
  store v7, v1+48 align 0
  ret
)";
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(src, tgt::axis_index("linux", false), tgt::axis_index("x86_64", true), 0, &mut obj),
        "the x86-64 object",
    );
    // PSHUFD: 66 [REX] 0F 70 /r ib.
    let mut seen: u32 = 0;
    for x in 0..obj.len() - 4 {
        if obj[x] == 0x0F && obj[x + 1] == 0x70 && (obj[x - 1] == 0x66 || obj[x - 2] == 0x66) {
            let ib = obj[x + 3];
            seen |= (ib == 0x4E) as u32 | (ib == 0xB1) as u32 << 1 | (ib == 0x1B) as u32 << 2;
        }
    }
    assert_eq(seen, 7);
    let mut arm = Vector::<u8>::new();
    assert(
        object_of(src, tgt::axis_index("linux", false), tgt::axis_index("aarch64", true), 0, &mut arm),
        "the arm64 object",
    );
    // EXT #8 (16 bytes) and REV64 of 4-byte lanes (16 bytes).
    assert(
        elf_text_count(&arm, 0xFFE0FC00, 0x6E004000) >= 2 && elf_text_count(&arm, 0xFFFFFC00, 0x4EA00800) >= 2,
        "EXT and REV64",
    );
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = "#include <string.h>\nvoid sw(const void *, void *);\nint main(void) {\n  float a[4] = {1, 2, 3, 4}, o[16];\n  double d[2];\n  sw(a, o);\n  float w[12] = {3, 4, 1, 2, 2, 1, 4, 3, 4, 3, 2, 1};\n  if (memcmp(o, w, sizeof w) != 0) return 1;\n  double e[2];\n  memcpy(e, a, 16);\n  memcpy(d, o + 12, 16);\n  return d[0] == e[1] && d[1] == e[0] ? 0 : 2;\n}\n";
    assert_eq(run_native(src, drv), 0);
}

// x86-64: an intrinsic whose instructions write vector registers alone (`floorf`'s ROUNDSS with SSE4.1) is
// no call for the register allocation: the loop around it keeps its pointers and count in scratch
// registers, so the body saves none and sets no frame up (its first instruction no push). It runs.
@test
fn vector_intrinsics_in_a_loop_are_no_calls() {
    let src = M"(lir ptr 8
sym @floorf fn global
sym @fl fn global
fn @fl
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 4
  v8 = load.f32 v7 align 2
  v9 = call.f32 @floorf(v8) : (f32) -> f32
  v10 = ptradd v0, v5 * 4
  store v9, v10 align 2
  v11 = add.i64 v5, v4
  jmp b1(v11)
b3:
  ret
)";
    let mut win = Vector::<u8>::new();
    assert(
        object_of(src, tgt::axis_index("windows", false), tgt::axis_index("x86_64", true), SSE41 | OMIT_FP, &mut win),
        "the Microsoft x64 object",
    );
    let at = (coff_section(&win, ".text") as u32) as usize;
    let first = win[at];
    assert(first != 0x53 && first != 0x55 && first != 0x56 && first != 0x57 && first != 0x41, "no register saved");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = "#include <math.h>\nvoid fl(float *, const float *, long long);\nint main(void) {\n  float a[9], d[9];\n  for (int k = 0; k < 9; k++) a[k] = (float)k * 0.75f - 3.1f;\n  fl(d, a, 9);\n  for (int k = 0; k < 9; k++) if (d[k] != floorf(a[k])) return k + 1;\n  return 0;\n}\n";
    assert_eq(run_native(src, drv), 0);
    assert_eq(run_sse41(src, drv), 0);
}

// x86-64: a parameter live across intrinsics that write vector registers alone (`fabs`), in a body that
// calls nothing else: it takes no home in a register the intrinsics write (Microsoft x64's xmm0, where it
// arrives). Each object builds, and it runs.
@test
fn a_value_across_vector_intrinsics_keeps_a_home_they_do_not_write() {
    let src = M"(lir ptr 8
sym @fabs fn global
sym @past fn global
fn @past
  sig (f64) -> i8
b0(v0: f64):
  v1 = fconst.f64 0x0
  v2 = fconst.f64 0x3690000000000000
  v3 = call.f64 @fabs(v0) : (f64) -> f64
  v4 = fconst.f64 0x47effffff0000000
  v5 = fcmp.oge v3, v4
  br v5, b4, b1
b1:
  v6 = fcmp.une v0, v1
  br v6, b2, b3(v6)
b2:
  v7 = call.f64 @fabs(v0) : (f64) -> f64
  v8 = fcmp.ole v7, v2
  ret v8
b3(v9: i8):
  ret v9
b4:
  ret v5
)";
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(src, tgt::axis_index("windows", false), tgt::axis_index("x86_64", true), 0, &mut obj),
        "the Microsoft x64 object",
    );
    assert(
        object_of(src, tgt::axis_index("linux", false), tgt::axis_index("x86_64", true), 0, &mut obj),
        "the System V object",
    );
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = M"(#include <stdint.h>
int8_t past(double);
int main(void) {
  return past(1.0) == 0 && past(-1e39) == 1 && past(1e-46) == 1 && past(0.0) == 0 && past(3e38) == 0 ? 0 : 1;
}
)";
    assert_eq(run_native(src, drv), 0);
}

// x86-64: code that ends in a call that does not return (a panic) has no epilogue after it, in a body that
// only panics and after a shrink-wrapped rare panic; under Microsoft x64 a trap follows such a last call, so
// its return address stays in the function for the unwinder. The division still runs.
@test
fn code_that_ends_in_a_panic_has_no_epilogue() {
    let src = M"(lir ptr 8
sym @p fn global
sym @q fn global
fn @p
  sig (i64) -> i64
b0(v0: i64):
  panic "no value"
fn @q
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 0
  v3 = icmp.eq v1, v2
  br v3, b2, b1
b1:
  v4 = udiv.i32 v0, v1
  ret v4
b2: cold
  panic "attempt to divide by zero"
)";
    let x64 = tgt::axis_index("x86_64", true);
    // With and without a frame pointer: after each call (E8 rel32) no `leave`, `pop rbp`, `add rsp` or `ret`.
    for opts in [0u32, OMIT_FP] {
        let mut obj = Vector::<u8>::new();
        assert(object_of(src, tgt::axis_index("linux", false), x64, opts, &mut obj), "the x86-64 object");
        let mut epi = false;
        for x in 0..obj.len() - 8 {
            let e = obj[x + 5];
            epi = epi || obj[x] == 0xE8 && word_at(&obj, x as u32 + 1, 4) == 0 && (e == 0xC9 || e == 0x5D || e == 0xC3 || e == 0x48 && obj[x + 6] == 0x83 && obj[x + 7] == 0xC4);
        }
        assert(!epi, "no epilogue after a panic");
    }
    let mut win = Vector::<u8>::new();
    assert(object_of(src, tgt::axis_index("windows", false), x64, 0, &mut win), "the Microsoft x64 object");
    let t = coff_section(&win, ".text");
    let (n, at) = ((t >> 32) as u32, t as u32);
    // Each call (E8 rel32) is followed by a trap or by the shrink-wrapped stub's `sub rsp`.
    let mut calls: u32 = 0;
    let mut trapped: u32 = 0;
    for x in at..at + n - 5 {
        if win[x as usize] == 0xE8 && word_at(&win, x + 1, 4) == 0 {
            calls += 1;
            trapped += (win[(x + 5) as usize] == 0xCC) as u32;
        }
    }
    assert(calls >= 2 && trapped >= 2, "a trap after each last call");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = "#include <stdint.h>\n#include <stdlib.h>\nint32_t q(int32_t, int32_t);\nvoid __sc_panic(const char *m) { (void)m; exit(7); }\nint main(void) {\n  if (q(17, 5) != 3) return 1;\n  q(1, 0);\n  return 2;\n}\n";
    assert_eq(run_native(src, drv), 7);
}

// Microsoft x64 passes an aggregate of 40 bytes by reference: the address the LIR passes goes as it is (the
// LIR copies a by-value argument the callee may write). A read-only referent's (`@copyref`) is the caller's,
// so the call is a sibling jump, the whole body (sibling calls on, no frame pointer); a slot of the frame
// (`@local`) keeps the frame and a call. One of 6 bytes (`@smallref`), within the 8 the backend copies
// (`Package.arg_copy`), passes as the address of a copy in the frame: a call.
@test
fn microsoft_x64_passes_an_aggregates_address_as_it_is() {
    let src = M"(lir ptr 8
sym @copyref fn global
sym @smallref fn global
sym @local fn global
sym @take fn global noinline
sym @take6 fn global noinline
fn @copyref
  layout l0 size 40 align 3 [0 i64, 8 i64, 16 i64, 24 i64, 32 i64]
  sig (ptr) -> i64
  ref p0 40 readonly
b0(v0: ptr):
  v1 = call.i64 @take(v0) : (l0) -> i64
  ret v1
fn @smallref
  layout l0 size 6 align 1 [0 i16, 2 i16, 4 i16]
  sig (ptr) -> i64
  ref p0 6 readonly
b0(v0: ptr):
  v1 = call.i64 @take6(v0) : (l0) -> i64
  ret v1
fn @local
  layout l0 size 40 align 3 [0 i64, 8 i64, 16 i64, 24 i64, 32 i64]
  sig (i64) -> i64
  slot s0 size 40 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  store v0, v1+8 align 3
  store v0, v1+16 align 3
  store v0, v1+24 align 3
  store v0, v1+32 align 3
  v2 = call.i64 @take(v1) : (l0) -> i64
  ret v2
fn @take
  layout l0 size 40 align 3 [0 i64, 8 i64, 16 i64, 24 i64, 32 i64]
  sig (l0) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = load.i64 v0+32 align 3
  v3 = add.i64 v1, v2
  ret v3
fn @take6
  layout l0 size 6 align 1 [0 i16, 2 i16, 4 i16]
  sig (l0) -> i64
b0(v0: ptr):
  v1 = load.i16 v0 align 1
  v2 = zext.i64 v1
  ret v2
)";
    let mut win = Vector::<u8>::new();
    assert(
        object_of(src, tgt::axis_index("windows", false), tgt::axis_index("x86_64", true), OMIT_FP | TAIL, &mut win),
        "the Microsoft x64 object",
    );
    let t = coff_section(&win, ".text");
    let (n, at) = ((t >> 32) as u32, t as u32);
    // `@copyref` first: `jmp rel32` (E9) at its start; `@smallref`'s and `@local`'s calls (E8 rel32) after.
    assert(n > 5 && win[at as usize] == 0xE9, "a sibling jump is the whole of copyref");
    let mut calls: u32 = 0;
    for x in at..at + n - 5 {
        calls += (win[x as usize] == 0xE8 && word_at(&win, x + 1, 4) == 0) as u32;
    }
    assert(calls == 2, "smallref and local call");
}

// Shrink-wrapped under Microsoft x64: the warm code, which keeps no frame, has no function table entry
// (an entry's absence is a leaf's rule); the framed code after it has one whose prologue is done (0
// bytes), and the stub that sets the frame up on the edge into it one with its prologue. The rare path
// leaves through its own epilogue: no edge goes back to the warm code.
@test
fn shrink_wrapped_windows_code_has_its_unwind_entries() {
    let src = M"(lir ptr 8
sym @g fn global
sym @f fn global
fn @f
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 100
  v2 = icmp.ugt v0, v1
  br v2, b2, b1
b1:
  v3 = add.i64 v0, v0
  ret v3
b2: unlikely
  v4 = call.i64 @g(v0) : (i64) -> i64
  v5 = add.i64 v4, v0
  ret v5
)";
    let mut obj = Vector::<u8>::new();
    assert(object_of(src, tgt::axis_index("windows", false), tgt::axis_index("x86_64", true), 0, &mut obj), "object");
    let pd = coff_section(&obj, ".pdata");
    let xd = coff_section(&obj, ".xdata");
    assert_eq(pd >> 32, 24);
    let p = pd as u32;
    let x = xd as u32;
    // (start, end, unwind information) twice: the framed code, then the stub right after it.
    assert(
        word_at(&obj, p, 4) > 0 && word_at(&obj, p + 4, 4) == word_at(&obj, p + 12, 4),
        "two entries in a row past the warm code",
    );
    assert_eq(word_at(&obj, x + word_at(&obj, p + 8, 4) + 1, 1), 0);
    assert(word_at(&obj, x + word_at(&obj, p + 20, 4) + 1, 1) > 0, "the stub's prologue");
}

// Only a single-use right operand can become an SSE memory operand. A write between the load and
// arithmetic must keep the old value; a left operand must keep subtraction and division order.
@test
fn scalar_float_loads_fold_into_the_right_operand() {
    let ops: []str = ["fadd", "fsub", "fmul", "fdiv"];
    let types: []str = ["f32", "f64"];
    let ctypes: []str = ["float", "double"];
    let results: []str = ["10", "6", "16", "4"];
    let mut lir = String::from_str("lir ptr 8\n");
    let mut drv = String::new();
    let mut main = String::from_str("int main(void) {\n");
    for t in 0..types.len() {
        for op in 0..ops.len() {
            lir.format_into(
                "sym @f{}{} fn global\nfn @f{}{}\n  sig (ptr, {}) -> {}\nb0(v0: ptr, v1: {}):\n  v2 = load.{} v0 align 0\n  v3 = {}.{} v1, v2\n  ret v3\n",
                t,
                op,
                t,
                op,
                types[t],
                types[t],
                types[t],
                types[t],
                ops[op],
                types[t],
            );
            drv.format_into("{} f{}{}({} *, {});\n", ctypes[t], t, op, ctypes[t], ctypes[t]);
            main.format_into(
                "  {{ {} x = 2; if (f{}{}(&x, 8) != {}) return {}; }}\n",
                ctypes[t],
                t,
                op,
                results[op],
                1 + t * 4 + op,
            );
        }
    }
    lir.push_str(
        M"(sym @left fn global
sym @write fn global
fn @left
  sig (ptr, f64) -> f64
b0(v0: ptr, v1: f64):
  v2 = load.f64 v0 align 0
  v3 = fsub.f64 v2, v1
  ret v3
fn @write
  sig (ptr, f64) -> f64
b0(v0: ptr, v1: f64):
  v2 = load.f64 v0 align 0
  store v1, v0 align 0
  v3 = fdiv.f64 v1, v2
  ret v3
)",
    );
    drv.push_str("double left(double *, double);\ndouble write(double *, double);\n");
    main.push_str("  double x = 2; if (left(&x, 8) != -6 || write(&x, 8) != 4 || x != 8) return 9;\n  return 0;\n}\n");
    drv.push_str(&main);
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(&lir, tgt::axis_index("windows", false), tgt::axis_index("x86_64", true), 0, &mut obj),
        "x64 object",
    );
    let section = coff_section(&obj, ".text");
    let start = section as u32;
    let end = start + (section >> 32) as u32;
    let mut folded: u32 = 0;
    for i in start..end.saturating_sub(4) {
        if obj[i as usize] != 0xF2 && obj[i as usize] != 0xF3 {
            continue;
        }
        let mut j = i + 1;
        if obj[j as usize] >= 0x40 && obj[j as usize] <= 0x4F {
            j += 1;
        }
        let op = obj[(j + 1) as usize];
        if obj[j as usize] == 0x0F && (op == 0x58 || op == 0x59 || op == 0x5C || op == 0x5E) && (obj[(j + 2) as usize] & 0xC0) != 0xC0 {
            folded += 1;
        }
    }
    assert_eq(folded, 8);
    if cli::has_cc() {
        assert_eq(run_native(&lir, &drv), 0);
    }
}

// Reversed accesses separated by integer arithmetic pair even when the loaded values live in the
// next block. A store between loads must keep the second load after that store.
@test
fn separated_reversed_accesses_pair_without_crossing_memory() {
    let lir = M"(lir ptr 8
sym @pair fn global
sym @barrier fn global
fn @pair
  sig (ptr, ptr, i64) -> i64
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = load.f64 v0+8 align 3
  v4 = add.i64 v2, v2
  v5 = load.f64 v0 align 3
  jmp b1
b1:
  store v3, v1+8 align 3
  v6 = add.i64 v4, v2
  store v5, v1 align 3
  ret v6
fn @barrier
  sig (ptr, f64) -> f64
b0(v0: ptr, v1: f64):
  v2 = load.f64 v0+8 align 3
  store v1, v0 align 3
  v3 = load.f64 v0 align 3
  v4 = fsub.f64 v2, v3
  ret v4
)";
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(lir, tgt::axis_index("linux", false), tgt::axis_index("aarch64", true), 0, &mut obj),
        "arm64 object",
    );
    let sh = word_at(&obj, 40, 4);
    let mut loads: u32 = 0;
    let mut stores: u32 = 0;
    for s in 0..word_at(&obj, 60, 2) {
        let h = sh + s * word_at(&obj, 58, 2);
        if (word_at(&obj, h + 8, 4) & 4) == 0 {
            continue;
        }
        let at = word_at(&obj, h + 24, 4);
        for i in 0..word_at(&obj, h + 32, 4) / 4 {
            let w = word_at(&obj, at + 4 * i, 4);
            // Offset-mode LDP/STP of doubles through a general base, excluding frame saves.
            if (w >> 5 & 31) != 31 && (w >> 5 & 31) != 29 {
                loads += ((w & 0xFFC00000) == 0x6D400000) as u32;
                stores += ((w & 0xFFC00000) == 0x6D000000) as u32;
            }
        }
    }
    assert_eq(loads, 1);
    assert_eq(stores, 1);
    if cli::has_cc() {
        assert_eq(
            run_native(
                lir,
                M"(#include <stdint.h>
int64_t pair(double *, double *, int64_t);
double barrier(double *, double);
int main(void) {
  double a[2] = {2, 8}, b[2] = {0, 0};
  if (pair(a, b, 7) != 21 || b[0] != 2 || b[1] != 8) return 1;
  if (barrier(a, 3) != 5 || a[0] != 3) return 2;
  return 0;
}
)",
            ),
            0,
        );
    }
}

// Long-lived homes must leave room for operands and a distinct result, including multi-instruction
// vector operations. The first sixteen values have more uses, so the arithmetic operands spill.
@test
fn xmm_homes_leave_room_for_instruction_temporaries() {
    let types: []str = ["f32", "f64", "v4i32"];
    let mut lir = String::from_str("lir ptr 8\n");
    let mut drv = String::from_str("#include <stdint.h>\n");
    let mut main = String::from_str("int main(void) {\n");
    for ty in 0..types.len() {
        for op in 0..3 {
            if ty == 2 && op != 0 {
                continue;
            }
            lir.format_into(
                "sym @f{}{} fn global\nfn @f{}{}\n  sig (ptr, ptr) -> void\nb0(v0: ptr, v1: ptr):\n",
                ty,
                op,
                ty,
                op,
            );
            for k in 0..20 {
                lir.format_into("  v{} = load.{} v0+{} align 0\n", 2 + k, types[ty], k * 16);
            }
            lir.push_str("  jmp b1\nb1:\n");
            if ty == 2 {
                lir.push_str("  v22 = mulhs.v4i32 v18, v19\n  store v22, v1+320 align 0\n");
            } else if op == 0 {
                lir.format_into("  v22 = fadd.{} v18, v19\n  store v22, v1+320 align 0\n", types[ty]);
            } else if op == 1 {
                lir.format_into("  v22 = fma.{} v18, v19, v20\n  store v22, v1+320 align 0\n", types[ty]);
            } else {
                lir.format_into(
                    "  v22 = fcmp.olt v18, v19\n  v23 = select.{} v22, v20, v21\n  store v23, v1+320 align 0\n",
                    types[ty],
                );
            }
            lir.push_str("  jmp b2\nb2:\n");
            for k in 0..20 {
                for _ in 0..(if k < 16 {
                    3
                } else {
                    1
                }) {
                    lir.format_into("  store v{}, v1+{} align 0\n", k + 2, k * 16);
                }
            }
            lir.push_str("  ret\n");
            // FMA emission is checked on both x64 ABIs without requiring FMA3 on the test host.
            if op == 1 {
                continue;
            }
            let ct = if ty == 0 {
                "float"
            } else if ty == 1 {
                "double"
            } else {
                "int32_t"
            };
            let stride = if ty == 1 {
                2
            } else {
                4
            };
            drv.format_into("void f{}{}({} *, {} *);\n", ty, op, ct, ct);
            main.format_into(
                "  {{ {} a[84], b[84] = {{0}}; for (int i = 0; i < 84; ++i) a[i] = i + 1; f{}{}(a, b);\n",
                ct,
                ty,
                op,
            );
            main.format_into("    for (int i = 0; i < 20; ++i) if (b[i*{}] != a[i*{}]) return 1;\n", stride, stride);
            if ty == 2 {
                main.push_str("    for (int i = 80; i < 84; ++i) if (b[i] != 0) return 2;\n");
            } else if op == 0 {
                main.format_into("    if (b[20*{}] != a[16*{}] + a[17*{}]) return 3;\n", stride, stride, stride);
            } else {
                main.format_into("    if (b[20*{}] != a[18*{}]) return 4;\n", stride, stride);
            }
            main.push_str("  }\n");
        }
    }
    main.push_str("  return 0;\n}\n");
    drv.push_str(&main);
    for os in ["windows", "linux"] {
        let mut obj = Vector::<u8>::new();
        assert(
            object_of(&lir, tgt::axis_index(os, false), tgt::axis_index("x86_64", true), 0, &mut obj),
            "xmm pressure object",
        );
    }
    if cli::has_cc() {
        assert_eq(run_native(&lir, &drv), 0);
    }
}

// Values loaded before a branch remain live across either a bypass edge or a loop with many heavier
// values. Stores check each old value independently, so a wrong spill cannot hide in a checksum.
@test
fn split_register_homes_survive_bypass_edges_and_loops() {
    let mut lir = String::from_str(
        "lir ptr 8\nsym @f fn global\nfn @f\n  sig (ptr, ptr, i64) -> void\nb0(v0: ptr, v1: ptr, v2: i64):\n",
    );
    for k in 0..32 {
        lir.format_into("  v{} = load.i64 v0+{} align 3\n", 3 + k, k * 8);
    }
    lir.push_str("  v35 = iconst.i64 0\n  v36 = icmp.eq v2, v35\n  br v36, b3, b1\nb1:\n");
    for k in 0..32 {
        lir.format_into("  v{} = load.i64 v0+{} align 3\n", 37 + k, (32 + k) * 8);
    }
    lir.push_str("  jmp b2(v2)\nb2(v69: i64):\n");
    for k in 0..32 {
        lir.format_into("  v{} = add.i64 v{}, v69\n  store v{}, v1+{} align 3\n", 70 + k, 37 + k, 70 + k, (32 + k) * 8);
    }
    lir.push_str(
        "  v102 = iconst.i64 1\n  v103 = sub.i64 v69, v102\n  v104 = icmp.ne v103, v35\n  br v104, b2(v103), b3\nb3:\n",
    );
    for k in 0..32 {
        // Reverse reads force different next-use distances under register pressure.
        lir.format_into("  store v{}, v1+{} align 3\n", 34 - k, (31 - k) * 8);
    }
    lir.push_str("  ret\n");
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(&lir, tgt::axis_index("linux", false), tgt::axis_index("x86_64", true), 0, &mut obj),
        "x64 pressure object",
    );
    if cli::has_cc() {
        assert_eq(
            run_native(
                &lir,
                M"(#include <stdint.h>
void f(uint64_t *, uint64_t *, uint64_t);
int main(void) {
  uint64_t a[64], b[64];
  for (int i = 0; i < 64; ++i) a[i] = (uint64_t)i * UINT64_C(0x9E3779B97F4A7C15);
  for (int n = 0; n < 4; ++n) {
    for (int i = 0; i < 64; ++i) b[i] = 0;
    f(a, b, (uint64_t)n);
    for (int i = 0; i < 32; ++i) if (a[i] != b[i]) return 1;
    for (int i = 32; i < 64; ++i) if (b[i] != (n ? a[i] + 1 : 0)) return 2;
  }
  return 0;
}
)",
            ),
            0,
        );
    }
}

// Stack parameters of a body that keeps no frame are read through sp (`a64gen` `sp_args`): a leaf's ten
// integers, a leaf's aggregate past the argument registers; a body that calls, and one whose values
// outlive a call, set up a frame and read them through x29 (`fp_args`).
@test
fn stack_parameters_of_frameless_bodies_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @sum10 fn global
sym @agg9 fn global
sym @call10 fn global
sym @keep10 fn global
sym @bump fn global ext
fn @sum10
  sig (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64, v3: i64, v4: i64, v5: i64, v6: i64, v7: i64, v8: i64, v9: i64):
  v10 = iconst.i64 3
  v11 = mul.i64 v8, v10
  v12 = add.i64 v0, v1
  v13 = add.i64 v12, v7
  v14 = add.i64 v13, v11
  v15 = sub.i64 v14, v9
  ret v15
fn @agg9
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64, i64, i64, i64, i64, i64, i64, i64, l0) -> i64
b0(v0: i64, v1: i64, v2: i64, v3: i64, v4: i64, v5: i64, v6: i64, v7: i64, v8: ptr):
  v9 = load.i64 v8 align 3
  v10 = load.i64 v8+8 align 3
  v11 = sub.i64 v9, v10
  v12 = add.i64 v11, v7
  ret v12
fn @call10
  sig (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64, v3: i64, v4: i64, v5: i64, v6: i64, v7: i64, v8: i64, v9: i64):
  v10 = call.i64 @bump(v9) : (i64) -> i64
  v11 = add.i64 v10, v8
  ret v11
fn @keep10
  sig (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64, v3: i64, v4: i64, v5: i64, v6: i64, v7: i64, v8: i64, v9: i64):
  v10 = call.i64 @bump(v0) : (i64) -> i64
  v11 = add.i64 v10, v8
  v12 = sub.i64 v11, v9
  ret v12
)";
    let drv = M"(#include <stdint.h>
struct P { int64_t a, b; };
int64_t sum10(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
int64_t agg9(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, struct P);
int64_t call10(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
int64_t keep10(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
int64_t bump(int64_t x) { volatile int64_t pad[32]; for (int i = 0; i < 32; i++) pad[i] = x; return pad[5] + 1; }
int main(void) {
  if (sum10(1, 2, 3, 4, 5, 6, 7, 8, 1000, 20000) != 1 + 2 + 8 + 3000 - 20000) return 1;
  struct P p = {700, 50};
  if (agg9(1, 2, 3, 4, 5, 6, 7, 8, p) != 658) return 2;
  if (call10(1, 2, 3, 4, 5, 6, 7, 8, 300, 4000) != 4301) return 3;
  if (keep10(1, 2, 3, 4, 5, 6, 7, 8, 300, 4000) != 2 + 300 - 4000) return 4;
  return 0;
}
)";
    assert_eq(run_native_with(lir, drv, OMIT_FP), 0);
    assert_eq(run_native(lir, drv), 0);
}

// Left shifts of zero extensions: when the shift moves every bit the extension clears out of the result,
// it shifts the narrow value's register (`lv::FOLD_ZSHL`), whose bits above the value are not 0 (the
// values are truncations); a shift that leaves some of them keeps the extension.
@test
fn shifts_of_zero_extensions_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @hi32 fn global
sym @hi40 fn global
sym @b24 fn global
sym @h8 fn global
fn @hi32
  sig (i64) -> i64
b0(v0: i64):
  v1 = trunc.i32 v0
  v2 = zext.i64 v1
  v3 = iconst.i64 32
  v4 = shl.i64 v2, v3
  ret v4
fn @hi40
  sig (i64) -> i64
b0(v0: i64):
  v1 = trunc.i32 v0
  v2 = zext.i64 v1
  v3 = iconst.i64 40
  v4 = shl.i64 v2, v3
  ret v4
fn @b24
  sig (i32) -> i32
b0(v0: i32):
  v1 = trunc.i8 v0
  v2 = zext.i32 v1
  v3 = iconst.i32 24
  v4 = shl.i32 v2, v3
  ret v4
fn @h8
  sig (i64) -> i64
b0(v0: i64):
  v1 = trunc.i16 v0
  v2 = zext.i64 v1
  v3 = iconst.i64 8
  v4 = shl.i64 v2, v3
  ret v4
)";
    let drv = M"(#include <stdint.h>
uint64_t hi32(uint64_t);
uint64_t hi40(uint64_t);
uint32_t b24(uint32_t);
uint64_t h8(uint64_t);
int main(void) {
  uint64_t xs[4] = {0, 0x123456789ABCDEF0u, 0xFFFFFFFFFFFFFFFFu, 0x80000001FFFF7F80u};
  for (int i = 0; i < 4; i++) {
    uint64_t x = xs[i];
    if (hi32(x) != (uint64_t)(uint32_t)x << 32) return 1;
    if (hi40(x) != (uint64_t)(uint32_t)x << 40) return 2;
    if (b24((uint32_t)x) != (uint32_t)(uint8_t)x << 24) return 3;
    if (h8(x) != (uint64_t)(uint16_t)x << 8) return 4;
  }
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
}

// Narrow integer parameters and their zero extensions: wasm keeps every narrow integer zero-extended in an
// i32 local, so an unsigned parameter, which the caller extends, needs no mask and its extension is no
// copy (`lv::FOLD_FREE_ZEXT`); a signed one, which the caller sign-extends, is masked at the entry. The C
// driver passes values whose bits above the narrow type are set where the type is signed.
@test
fn narrow_parameters_extend_once_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @usum fn global
sym @ssum fn global
sym @mix fn global
fn @usum
  sig (i8, i16) -> i32
b0(v0: i8, v1: i16):
  v2 = zext.i32 v0
  v3 = zext.i32 v1
  v4 = add.i32 v2, v3
  ret v4
fn @ssum
  sig (i8.s, i16.s) -> i32
b0(v0: i8, v1: i16):
  v2 = zext.i32 v0
  v3 = zext.i32 v1
  v4 = add.i32 v2, v3
  ret v4
fn @mix
  sig (i8, i8.s) -> i32
b0(v0: i8, v1: i8):
  v2 = zext.i16 v0
  v3 = zext.i32 v2
  v4 = sext.i32 v1
  v5 = mul.i32 v3, v4
  v6 = zext.i32 v1
  v7 = add.i32 v5, v6
  ret v7
)";
    let drv = M"(#include <stdint.h>
int32_t usum(uint8_t, uint16_t);
int32_t ssum(int8_t, int16_t);
int32_t mix(uint8_t, int8_t);
int main(void) {
  if (usum(200, 60000) != 60200) return 1;
  if (ssum(-1, -2) != 255 + 65534) return 2;
  if (mix(250, -3) != 250 * -3 + 253) return 3;
  if (mix(7, 100) != 800) return 4;
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A thread-local variable's address in an executable on x86-64 Linux is the thread pointer plus an offset
// the link sets (local-exec: `mov fs:[0]` and a `lea`), with no call of `__tls_get_addr`. On arm64 the
// getter keeps x1..x15, so the values a loop carries in a body that calls nothing else stay in them: no
// callee-saved register is saved.
@test
fn thread_local_addresses_take_no_call_in_an_executable() {
    let lir = M"(lir ptr 8
sym @t tls global
sym @spread fn global
fn @spread
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = symaddr @t
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3, v3, v3, v3, v3, v3)
b1(v5: i64, v6: i64, v7: i64, v8: i64, v9: i64, v10: i64):
  v11 = icmp.ult v5, v1
  br v11, b2, b3
b2:
  v12 = load.i64 v0+0 align 3
  v13 = load.i64 v0+8 align 3
  v14 = load.i64 v0+16 align 3
  v15 = load.i64 v0+24 align 3
  v16 = load.i64 v0+32 align 3
  v17 = add.i64 v6, v12
  v18 = add.i64 v7, v13
  v19 = add.i64 v8, v14
  v20 = add.i64 v9, v15
  v21 = add.i64 v10, v16
  v22 = add.i64 v5, v4
  jmp b1(v22, v17, v18, v19, v20, v21)
b3:
  v23 = load.i64 v2 align 3
  v24 = add.i64 v23, v6
  v25 = add.i64 v24, v7
  v26 = add.i64 v25, v8
  v27 = add.i64 v26, v9
  v28 = add.i64 v27, v10
  store v28, v2 align 3
  ret v28
data @t size 8 align 3
)";
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(lir, tgt::axis_index("linux", false), tgt::axis_index("x86_64", true), 0, &mut obj),
        "the x86-64 object",
    );
    // mov r64, fs:[0]: the segment prefix, REX.W, the load, a ModRM of an absolute address, the SIB of none.
    // The address is rematerialized at each use (the load and the store after the loop): no register or
    // slot holds it across the loop.
    let mut fs0: u32 = 0;
    for i in 0..obj.len() - 4 {
        fs0 += (obj[i] == 0x64 && (obj[i + 1] & 0xFB) == 0x48 && obj[i + 2] == 0x8B && (obj[i + 3] & 0xC7) == 0x04 && obj[i + 4] == 0x25) as u32;
    }
    assert(
        fs0 == 2 && !unsafe str::from_raw(obj.as_ptr(), obj.len()).contains("__tls_get_addr"),
        "local-exec addresses",
    );
    let oses: [str; 2] = ["macos", "linux"];
    for os in oses {
        assert(
            object_of(lir, tgt::axis_index(os, false), tgt::axis_index("aarch64", true), 0, &mut obj),
            "the arm64 object",
        );
        // No store of a pair from x19..x28 (stp, signed offset or pre-index).
        for i in 0..obj.len() / 4 {
            let w = obj[4 * i] as u32 | obj[4 * i + 1] as u32 << 8 | obj[4 * i + 2] as u32 << 16 | obj[4 * i + 3] as u32 << 24;
            let stp = (w & 0xFFC00000) == 0xA9000000 || (w & 0xFFC00000) == 0xA9800000;
            assert(!(stp && (w & 31) >= 19 && (w & 31) <= 28), os);
        }
    }
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = M"(#include <stdint.h>
int64_t spread(const int64_t *, int64_t);
int main(void) {
  int64_t a[5] = {1, 2, 3, 4, 5};
  if (spread(a, 2) != 30) return 1;
  if (spread(a, 1) != 45) return 2;
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Two loads of 8 bytes through one address, the second of the bytes before the first, and of two types of
// one access kind (`i64`, `ptr`), pair into one `ldp` on arm64, the first loaded into the second register.
@test
fn loads_of_descending_offsets_pair() {
    let lir = M"(lir ptr 8
sym @diff fn global
fn @diff
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0+8 align 3
  v2 = load.ptr v0 align 3
  v3 = load.i64 v2 align 3
  v4 = sub.i64 v3, v1
  ret v4
)";
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(lir, tgt::axis_index("macos", false), tgt::axis_index("aarch64", true), 0, &mut obj),
        "the arm64 object",
    );
    // LDP (64-bit, signed offset).
    let mut n: u32 = 0;
    for i in 0..obj.len() / 4 {
        let w = obj[4 * i] as u32 | obj[4 * i + 1] as u32 << 8 | obj[4 * i + 2] as u32 << 16 | obj[4 * i + 3] as u32 << 24;
        n += ((w & 0xFFC00000) == 0xA9400000) as u32;
    }
    assert_eq(n, 1);
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = M"(#include <stdint.h>
struct S { const int64_t *p; int64_t n; };
int64_t diff(const struct S *);
int main(void) {
  int64_t a[1] = {100};
  struct S s = {a, 30};
  return diff(&s) == 70 ? 0 : 1;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// An aggregate parameter a call takes on in the registers it arrives in keeps its parts when a
// thread-local address before the call runs a getter that writes x0 (arm64) or calls `__tls_get_addr`.
@test
fn aggregates_passed_on_survive_a_thread_local_address() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = M"(lir ptr 8
sym @t tls global
sym @g fn global
sym @f fn global
fn @f
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0) -> i64
b0(v0: ptr):
  v1 = symaddr @t
  v2 = load.i64 v1 align 3
  v3 = iconst.i64 1
  v4 = add.i64 v2, v3
  store v4, v1 align 3
  v5 = call.i64 @g(v0) : (l0) -> i64
  ret v5
data @t size 8 align 3
)";
    let drv = M"(#include <stdint.h>
struct S { const int64_t *p; int64_t n; };
int64_t f(struct S);
int64_t g(struct S s) { return s.p[0] + s.n; }
int main(void) {
  int64_t a[1] = {40};
  struct S s = {a, 2};
  if (f(s) != 42) return 1;
  if (f(s) != 42) return 2;
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A sum of lanes 0 and 1 of a float vector of two lanes, each read once, adds them pairwise on arm64
// (`faddp`, `lv::FOLD_LANE_PAIR`) in either order, with the vector in its register; a lane read twice
// stays a lane read.
@test
fn sums_of_two_lanes_add_them_pairwise() {
    let lir = M"(lir ptr 8
sym @pair32 fn global
sym @pair64 fn global
sym @twice fn global
fn @pair32
  sig (ptr) -> f32
b0(v0: ptr):
  v1 = load.v2f32 v0 align 2
  v2 = vextract.1.f32 v1
  v3 = vextract.0.f32 v1
  v4 = fadd.f32 v2, v3
  ret v4
fn @pair64
  sig (ptr) -> f64
b0(v0: ptr):
  v1 = load.v2f64 v0 align 3
  v2 = vextract.0.f64 v1
  v3 = vextract.1.f64 v1
  v4 = fadd.f64 v2, v3
  ret v4
fn @twice
  sig (ptr) -> f32
b0(v0: ptr):
  v1 = load.v2f32 v0 align 2
  v2 = vextract.0.f32 v1
  v3 = vextract.1.f32 v1
  v4 = fadd.f32 v2, v3
  v5 = fadd.f32 v4, v2
  ret v5
)";
    let mut obj = Vector::<u8>::new();
    assert(
        object_of(lir, tgt::axis_index("macos", false), tgt::axis_index("aarch64", true), 0, &mut obj),
        "the arm64 object",
    );
    // FADDP (scalar) of 2S and of 2D.
    let mut n: u32 = 0;
    for i in 0..obj.len() / 4 {
        let w = obj[4 * i] as u32 | obj[4 * i + 1] as u32 << 8 | obj[4 * i + 2] as u32 << 16 | obj[4 * i + 3] as u32 << 24;
        n += ((w & 0xFFBFFC00) == 0x7E30D800) as u32;
    }
    assert_eq(n, 2);
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = M"(#include <stdint.h>
float pair32(const float *);
double pair64(const double *);
float twice(const float *);
int main(void) {
  float f[2] = {1.5f, 2.25f};
  double d[2] = {-3.5, 0.125};
  if (pair32(f) != 3.75f) return 1;
  if (pair64(d) != -3.375) return 2;
  if (twice(f) != 5.25f) return 3;
  return 0;
}
)";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}
