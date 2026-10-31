// The native backend: LIR text compiles to an object, which links with a C driver and runs, on the host
// and for wasm32 (with a wasi-sdk in WASI_SDK_PATH and wasmtime on the PATH, as the wasm lane has).
import lir::ir as *;
import lir::parse as lparse;
import lir::verify as verify;
import target::native as nat;
import target::table as tgt;
import tests::cli_harness as cli;
import std::platform::fs;
import std::platform::process;
import stdio;
import stdlib;
import module::loader;

// The package options a test may set (`object_of`): sibling calls (`Package.tail`), 32-byte vectors
// (`Package.vector`: x86-64's ymm registers with AVX2), binary16 instructions (`Package.half`: arithmetic
// on macOS arm64, whose every processor has FEAT_FP16, else conversions), 64-byte vectors (x86-64's zmm
// registers with AVX-512).
const TAIL: u32 = 1;
const WIDE: u32 = 2;
const HALF: u32 = 4;
const Z512: u32 = 8;
const POPCNT: u32 = 16;

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
    if tgt::host_isa() != tgt::axis_index("x86_64", true) {
        return 0;
    }
    let head = "int main(void) {\n";
    let at = driver.find(head);
    assert(at >= 0, "the driver's main");
    let d = format(
        "{}{}  if (!__builtin_cpu_supports(\"popcnt\")) return 0;\n{}",
        driver.slice(0, at as usize),
        head,
        driver.slice(at as usize + head.len(), driver.len()),
    );
    return run_native_with(text, &d, POPCNT);
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
    p.popcnt = (opts & POPCNT) != 0;
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
    let mut v = verify::Verifier::new();
    for i in 0..p.syms.len() {
        let s = p.syms[i];
        if s.def != NONE && s.kind == SK_FUNC && !v.check(&p, p.spell(s.name), &p.bodies[s.def as usize]) {
            eprint("verify: {}\n", v.err.as_str());
            return false;
        }
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
    assert_eq(run_wasm(lir, drv), 0);
}

// A run of 8-byte stores of 0 at consecutive offsets (x86-64: a zeroed xmm register stored 16 bytes at a
// time, an odd last store alone), and one a volatile store breaks, write those bytes alone.
@test
fn runs_of_zero_stores_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @zero5 fn global\nsym @zero4 fn global\nfn @zero5\n  sig (ptr) -> void\nb0(v0: ptr):\n  v1 = iconst.i64 0\n  store v1, v0+8 align 0\n  store v1, v0+16 align 0\n  store v1, v0+24 align 0\n  store v1, v0+32 align 0\n  store v1, v0+40 align 0\n  ret\nfn @zero4\n  sig (ptr) -> void\nb0(v0: ptr):\n  v1 = iconst.i64 0\n  store v1, v0 align 0\n  store v1, v0+8 align 0\n  store v1, v0+16 align 0 volatile\n  store v1, v0+24 align 0\n  ret\n";
    let drv = "#include <stdint.h>\nvoid zero5(uint64_t *);\nvoid zero4(uint64_t *);\nint main(void) {\n  uint64_t a[7];\n  for (int i = 0; i < 7; i++) a[i] = 0x1111111111111111ull * (i + 1);\n  zero5(a);\n  if (a[0] != 0x1111111111111111ull || a[6] != 0x7777777777777777ull) return 1;\n  for (int i = 1; i < 6; i++) if (a[i] != 0) return 2;\n  uint64_t b[5];\n  for (int i = 0; i < 5; i++) b[i] = 9;\n  zero4(b);\n  for (int i = 0; i < 4; i++) if (b[i] != 0) return 3;\n  if (b[4] != 9) return 4;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
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

// An `and`, `or` or `xor` of an inverted value (`not`, or `xor` with all ones; arm64 `bic`, `orn`, `eon`) in
// 64, 32 and 8 bits, a right shift of a left shift by at most as much (arm64 `sbfx`, `ubfx`), and a field
// inserted into the other bits of a value (arm64 `bfi`; not with a mask that keeps bits of the field),
// with their results.
@test
fn inverted_operands_and_shifted_fields_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @bic64 fn global\nsym @orn32 fn global\nsym @eon64 fn global\nsym @bicx32 fn global\nsym @bic8 fn global\nsym @sbf32 fn global\nsym @ubf64 fn global\nsym @sbf64 fn global\nsym @ubf32 fn global\nsym @bfi32 fn global\nsym @bfi64 fn global\nsym @nobfi fn global\nfn @bic64\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = not.i64 v0\n  v3 = and.i64 v2, v1\n  ret v3\nfn @orn32\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = not.i32 v1\n  v3 = or.i32 v0, v2\n  ret v3\nfn @eon64\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = iconst.i64 -1\n  v3 = xor.i64 v1, v2\n  v4 = xor.i64 v0, v3\n  ret v4\nfn @bicx32\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = iconst.i32 -1\n  v3 = xor.i32 v0, v2\n  v4 = and.i32 v1, v3\n  ret v4\nfn @bic8\n  sig (i8, i8) -> i8\nb0(v0: i8, v1: i8):\n  v2 = not.i8 v0\n  v3 = and.i8 v2, v1\n  ret v3\nfn @sbf32\n  sig (i32) -> i32\nb0(v0: i32):\n  v1 = iconst.i32 20\n  v2 = shl.i32 v0, v1\n  v3 = iconst.i32 24\n  v4 = ashr.i32 v2, v3\n  ret v4\nfn @ubf64\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = iconst.i64 3\n  v2 = shl.i64 v0, v1\n  v3 = iconst.i64 60\n  v4 = lshr.i64 v2, v3\n  ret v4\nfn @sbf64\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = iconst.i64 8\n  v2 = shl.i64 v0, v1\n  v3 = iconst.i64 8\n  v4 = ashr.i64 v2, v3\n  ret v4\nfn @ubf32\n  sig (i32) -> i32\nb0(v0: i32):\n  v1 = iconst.i32 0\n  v2 = shl.i32 v0, v1\n  v3 = iconst.i32 31\n  v4 = lshr.i32 v2, v3\n  ret v4\nfn @bfi32\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = iconst.i32 4294902015\n  v3 = and.i32 v0, v2\n  v4 = iconst.i32 255\n  v5 = and.i32 v1, v4\n  v6 = iconst.i32 8\n  v7 = shl.i32 v5, v6\n  v8 = or.i32 v3, v7\n  ret v8\nfn @bfi64\n  sig (i64, i64) -> i64\nb0(v0: i64, v1: i64):\n  v2 = iconst.i64 65535\n  v3 = and.i64 v1, v2\n  v4 = iconst.i64 40\n  v5 = shl.i64 v3, v4\n  v6 = iconst.i64 -72056494526300161\n  v7 = and.i64 v0, v6\n  v8 = or.i64 v5, v7\n  ret v8\nfn @nobfi\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = iconst.i32 4294901775\n  v3 = and.i32 v0, v2\n  v4 = iconst.i32 255\n  v5 = and.i32 v1, v4\n  v6 = iconst.i32 8\n  v7 = shl.i32 v5, v6\n  v8 = or.i32 v3, v7\n  ret v8\n";
    let drv = "#include <stdint.h>\nint64_t bic64(int64_t, int64_t);\nint32_t orn32(int32_t, int32_t);\nint64_t eon64(int64_t, int64_t);\nint32_t bicx32(int32_t, int32_t);\nuint8_t bic8(uint8_t, uint8_t);\nint32_t sbf32(int32_t);\nuint64_t ubf64(uint64_t);\nint64_t sbf64(int64_t);\nuint32_t ubf32(uint32_t);\nuint32_t bfi32(uint32_t, uint32_t);\nuint64_t bfi64(uint64_t, uint64_t);\nuint32_t nobfi(uint32_t, uint32_t);\nint main(void) {\n  uint64_t s = 0x9E3779B97F4A7C15u;\n  for (int i = 0; i < 1000; i++) {\n    s ^= s << 13;\n    s ^= s >> 7;\n    s ^= s << 17;\n    uint64_t r = s * 0x2545F4914F6CDD1Du;\n    if (bic64((int64_t)s, (int64_t)r) != (int64_t)(~s & r)) return 1;\n    if (orn32((int32_t)s, (int32_t)r) != (int32_t)((uint32_t)s | ~(uint32_t)r)) return 2;\n    if (eon64((int64_t)s, (int64_t)r) != (int64_t)(s ^ ~r)) return 3;\n    if (bicx32((int32_t)s, (int32_t)r) != (int32_t)((uint32_t)r & ~(uint32_t)s)) return 4;\n    if (bic8((uint8_t)s, (uint8_t)r) != (uint8_t)(~(uint8_t)s & (uint8_t)r)) return 5;\n    if (sbf32((int32_t)s) != (int32_t)((uint32_t)s << 20) >> 24) return 6;\n    if (ubf64(s) != (s << 3) >> 60) return 7;\n    if (sbf64((int64_t)s) != (int64_t)(s << 8) >> 8) return 8;\n    if (ubf32((uint32_t)s) != (uint32_t)s >> 31) return 9;\n    if (bfi32((uint32_t)s, (uint32_t)r) != (((uint32_t)s & 0xffff00ffu) | (((uint32_t)r & 0xffu) << 8))) return 10;\n    if (bfi64(s, r) != ((s & ~(UINT64_C(0xffff) << 40)) | ((r & 0xffff) << 40))) return 11;\n    if (nobfi((uint32_t)s, (uint32_t)r) != (((uint32_t)s & 0xffff000fu) | (((uint32_t)r & 0xffu) << 8))) return 12;\n  }\n  return 0;\n}\n";
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
// in place of the call (`frintm`, `frintp`, `frinta`, `frintz`, `fabs`, `fminnm`, `fmaxnm`), equal the
// library's on signed zeros, halves, the last fraction below one half, infinities and NaN (a minimum or
// maximum of two zeros may be either).
@test
fn libm_rounding_minimum_and_maximum_calls_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @floor fn global\nsym @t_floor fn global\nsym @floorf fn global\nsym @t_floorf fn global\nsym @ceil fn global\nsym @t_ceil fn global\nsym @ceilf fn global\nsym @t_ceilf fn global\nsym @round fn global\nsym @t_round fn global\nsym @roundf fn global\nsym @t_roundf fn global\nsym @trunc fn global\nsym @t_trunc fn global\nsym @truncf fn global\nsym @t_truncf fn global\nsym @fabs fn global\nsym @t_fabs fn global\nsym @fabsf fn global\nsym @t_fabsf fn global\nsym @fmin fn global\nsym @t_fmin fn global\nsym @fminf fn global\nsym @t_fminf fn global\nsym @fmax fn global\nsym @t_fmax fn global\nsym @fmaxf fn global\nsym @t_fmaxf fn global\nfn @t_floor\n  sig (f64) -> f64\nb0(v0: f64):\n  v1 = call.f64 @floor(v0) : (f64) -> f64\n  ret v1\nfn @t_floorf\n  sig (f32) -> f32\nb0(v0: f32):\n  v1 = call.f32 @floorf(v0) : (f32) -> f32\n  ret v1\nfn @t_ceil\n  sig (f64) -> f64\nb0(v0: f64):\n  v1 = call.f64 @ceil(v0) : (f64) -> f64\n  ret v1\nfn @t_ceilf\n  sig (f32) -> f32\nb0(v0: f32):\n  v1 = call.f32 @ceilf(v0) : (f32) -> f32\n  ret v1\nfn @t_round\n  sig (f64) -> f64\nb0(v0: f64):\n  v1 = call.f64 @round(v0) : (f64) -> f64\n  ret v1\nfn @t_roundf\n  sig (f32) -> f32\nb0(v0: f32):\n  v1 = call.f32 @roundf(v0) : (f32) -> f32\n  ret v1\nfn @t_trunc\n  sig (f64) -> f64\nb0(v0: f64):\n  v1 = call.f64 @trunc(v0) : (f64) -> f64\n  ret v1\nfn @t_truncf\n  sig (f32) -> f32\nb0(v0: f32):\n  v1 = call.f32 @truncf(v0) : (f32) -> f32\n  ret v1\nfn @t_fabs\n  sig (f64) -> f64\nb0(v0: f64):\n  v1 = call.f64 @fabs(v0) : (f64) -> f64\n  ret v1\nfn @t_fabsf\n  sig (f32) -> f32\nb0(v0: f32):\n  v1 = call.f32 @fabsf(v0) : (f32) -> f32\n  ret v1\nfn @t_fmin\n  sig (f64, f64) -> f64\nb0(v0: f64, v1: f64):\n  v2 = call.f64 @fmin(v0, v1) : (f64, f64) -> f64\n  ret v2\nfn @t_fminf\n  sig (f32, f32) -> f32\nb0(v0: f32, v1: f32):\n  v2 = call.f32 @fminf(v0, v1) : (f32, f32) -> f32\n  ret v2\nfn @t_fmax\n  sig (f64, f64) -> f64\nb0(v0: f64, v1: f64):\n  v2 = call.f64 @fmax(v0, v1) : (f64, f64) -> f64\n  ret v2\nfn @t_fmaxf\n  sig (f32, f32) -> f32\nb0(v0: f32, v1: f32):\n  v2 = call.f32 @fmaxf(v0, v1) : (f32, f32) -> f32\n  ret v2\n";
    let drv = "#include <math.h>\n#include <string.h>\n#include <stdint.h>\ndouble t_floor(double);\nfloat t_floorf(float);\ndouble t_ceil(double);\nfloat t_ceilf(float);\ndouble t_round(double);\nfloat t_roundf(float);\ndouble t_trunc(double);\nfloat t_truncf(float);\ndouble t_fabs(double);\nfloat t_fabsf(float);\ndouble t_fmin(double, double);\nfloat t_fminf(float, float);\ndouble t_fmax(double, double);\nfloat t_fmaxf(float, float);\nstatic int same64(double x, double y) { uint64_t a, b; memcpy(&a, &x, 8); memcpy(&b, &y, 8); return a == b || (x != x && y != y) || (x == 0 && y == 0); }\nstatic int same32(float x, float y) { uint32_t a, b; memcpy(&a, &x, 4); memcpy(&b, &y, 4); return a == b || (x != x && y != y) || (x == 0 && y == 0); }\nstatic int bits64(double x, double y) { uint64_t a, b; memcpy(&a, &x, 8); memcpy(&b, &y, 8); return a == b || (x != x && y != y); }\nstatic int bits32(float x, float y) { uint32_t a, b; memcpy(&a, &x, 4); memcpy(&b, &y, 4); return a == b || (x != x && y != y); }\nint main(void) {\n  double v[14] = {0.0, -0.0, 0.5, -0.5, 1.5, -1.5, 2.5, -2.5, 0.49999999999999994, 4503599627370497.0, 1e300, -INFINITY, NAN, -3.75};\n  for (int i = 0; i < 14; i++) {\n    double x = v[i];\n    float f = (float)x;\n    if (!bits64(t_floor(x), floor(x))) return 1;\n    if (!bits32(t_floorf(f), floorf(f))) return 2;\n    if (!bits64(t_ceil(x), ceil(x))) return 3;\n    if (!bits32(t_ceilf(f), ceilf(f))) return 4;\n    if (!bits64(t_round(x), round(x))) return 5;\n    if (!bits32(t_roundf(f), roundf(f))) return 6;\n    if (!bits64(t_trunc(x), trunc(x))) return 7;\n    if (!bits32(t_truncf(f), truncf(f))) return 8;\n    if (!bits64(t_fabs(x), fabs(x))) return 9;\n    if (!bits32(t_fabsf(f), fabsf(f))) return 10;\n    for (int j = 0; j < 14; j++) {\n      double y = v[j];\n      float g = (float)y;\n      if (!same64(t_fmin(x, y), fmin(x, y))) return 11;\n      if (!same32(t_fminf(f, g), fminf(f, g))) return 12;\n      if (!same64(t_fmax(x, y), fmax(x, y))) return 13;\n      if (!same32(t_fmaxf(f, g), fmaxf(f, g))) return 14;\n    }\n  }\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
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
// side, in 32 and 64 bits, a constant compared first (x86-64 `cmp` then `adc 0` or `sbb -1`); the bit
// length `width - clz(x)` (x86-64 `bsr`, `add 1`, `cmove` for 0); comparison values (x86-64 `xor` of the
// register before the compare, `setcc` after).
@test
fn carry_selects_bit_lengths_and_comparison_values_run() {
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let lir = "lir ptr 8\nsym @c_ult_t32 fn global\nsym @c_ult_t64 fn global\nsym @c_ult_f32 fn global\nsym @c_ult_f64 fn global\nsym @c_ugt_t32 fn global\nsym @c_ugt_t64 fn global\nsym @c_ugt_f32 fn global\nsym @c_ugt_f64 fn global\nsym @c_ule_t32 fn global\nsym @c_ule_t64 fn global\nsym @c_ule_f32 fn global\nsym @c_ule_f64 fn global\nsym @c_uge_t32 fn global\nsym @c_uge_t64 fn global\nsym @c_uge_f32 fn global\nsym @c_uge_f64 fn global\nsym @c_imm fn global\nsym @blen32 fn global\nsym @blen64 fn global\nsym @cmpv fn global\nfn @c_ult_t32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.ult v0, v1\n  v6 = select.i32 v5, v4, v2\n  ret v6\nfn @c_ult_t64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.ult v0, v1\n  v6 = select.i64 v5, v4, v2\n  ret v6\nfn @c_ult_f32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.ult v0, v1\n  v6 = select.i32 v5, v2, v4\n  ret v6\nfn @c_ult_f64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.ult v0, v1\n  v6 = select.i64 v5, v2, v4\n  ret v6\nfn @c_ugt_t32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.ugt v0, v1\n  v6 = select.i32 v5, v4, v2\n  ret v6\nfn @c_ugt_t64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.ugt v0, v1\n  v6 = select.i64 v5, v4, v2\n  ret v6\nfn @c_ugt_f32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.ugt v0, v1\n  v6 = select.i32 v5, v2, v4\n  ret v6\nfn @c_ugt_f64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.ugt v0, v1\n  v6 = select.i64 v5, v2, v4\n  ret v6\nfn @c_ule_t32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.ule v0, v1\n  v6 = select.i32 v5, v4, v2\n  ret v6\nfn @c_ule_t64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.ule v0, v1\n  v6 = select.i64 v5, v4, v2\n  ret v6\nfn @c_ule_f32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.ule v0, v1\n  v6 = select.i32 v5, v2, v4\n  ret v6\nfn @c_ule_f64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.ule v0, v1\n  v6 = select.i64 v5, v2, v4\n  ret v6\nfn @c_uge_t32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.uge v0, v1\n  v6 = select.i32 v5, v4, v2\n  ret v6\nfn @c_uge_t64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.uge v0, v1\n  v6 = select.i64 v5, v4, v2\n  ret v6\nfn @c_uge_f32\n  sig (i32, i32, i32) -> i32\nb0(v0: i32, v1: i32, v2: i32):\n  v3 = iconst.i32 1\n  v4 = add.i32 v2, v3\n  v5 = icmp.uge v0, v1\n  v6 = select.i32 v5, v2, v4\n  ret v6\nfn @c_uge_f64\n  sig (i64, i64, i64) -> i64\nb0(v0: i64, v1: i64, v2: i64):\n  v3 = iconst.i64 1\n  v4 = add.i64 v2, v3\n  v5 = icmp.uge v0, v1\n  v6 = select.i64 v5, v2, v4\n  ret v6\nfn @c_imm\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = iconst.i32 1\n  v3 = add.i32 v1, v2\n  v4 = iconst.i32 100\n  v5 = icmp.ugt v4, v0\n  v6 = select.i32 v5, v3, v1\n  ret v6\nfn @blen32\n  sig (i32) -> i32\nb0(v0: i32):\n  v1 = clz.i32 v0\n  v2 = iconst.i32 32\n  v3 = sub.i32 v2, v1\n  ret v3\nfn @blen64\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = clz.i64 v0\n  v2 = iconst.i64 64\n  v3 = sub.i64 v2, v1\n  ret v3\nfn @cmpv\n  sig (i32, i32) -> i32\nb0(v0: i32, v1: i32):\n  v2 = icmp.slt v0, v1\n  v3 = zext.i32 v2\n  v4 = icmp.eq v0, v1\n  v5 = zext.i32 v4\n  v6 = add.i32 v3, v5\n  v7 = icmp.ne v6, v0\n  v8 = zext.i32 v7\n  v9 = add.i32 v6, v8\n  ret v9\n";
    let drv = "#include <stdint.h>\nuint32_t c_ult_t32(uint32_t, uint32_t, uint32_t);\nuint64_t c_ult_t64(uint64_t, uint64_t, uint64_t);\nuint32_t c_ult_f32(uint32_t, uint32_t, uint32_t);\nuint64_t c_ult_f64(uint64_t, uint64_t, uint64_t);\nuint32_t c_ugt_t32(uint32_t, uint32_t, uint32_t);\nuint64_t c_ugt_t64(uint64_t, uint64_t, uint64_t);\nuint32_t c_ugt_f32(uint32_t, uint32_t, uint32_t);\nuint64_t c_ugt_f64(uint64_t, uint64_t, uint64_t);\nuint32_t c_ule_t32(uint32_t, uint32_t, uint32_t);\nuint64_t c_ule_t64(uint64_t, uint64_t, uint64_t);\nuint32_t c_ule_f32(uint32_t, uint32_t, uint32_t);\nuint64_t c_ule_f64(uint64_t, uint64_t, uint64_t);\nuint32_t c_uge_t32(uint32_t, uint32_t, uint32_t);\nuint64_t c_uge_t64(uint64_t, uint64_t, uint64_t);\nuint32_t c_uge_f32(uint32_t, uint32_t, uint32_t);\nuint64_t c_uge_f64(uint64_t, uint64_t, uint64_t);\nuint32_t c_imm(uint32_t, uint32_t);\nuint32_t blen32(uint32_t);\nuint64_t blen64(uint64_t);\nint32_t cmpv(int32_t, int32_t);\nint main(void) {\n  uint64_t vs[7] = {0, 1, 2, 99, 100, 0xFFFFFFFFu, UINT64_MAX};\n  for (int i = 0; i < 7; i++)\n    for (int j = 0; j < 7; j++) {\n      uint64_t a = vs[i], b = vs[j], c = vs[(i + j) % 7];\n      uint32_t a32 = (uint32_t)a, b32 = (uint32_t)b, c32 = (uint32_t)c;\n      if (c_ult_t32(a32, b32, c32) != ((a32 < b32) ? (uint32_t)(c32 + 1) : c32)) return 1;\n      if (c_ult_t64(a, b, c) != ((a < b) ? c + 1 : c)) return 2;\n      if (c_ult_f32(a32, b32, c32) != ((a32 < b32) ? c32 : (uint32_t)(c32 + 1))) return 3;\n      if (c_ult_f64(a, b, c) != ((a < b) ? c : c + 1)) return 4;\n      if (c_ugt_t32(a32, b32, c32) != ((a32 > b32) ? (uint32_t)(c32 + 1) : c32)) return 5;\n      if (c_ugt_t64(a, b, c) != ((a > b) ? c + 1 : c)) return 6;\n      if (c_ugt_f32(a32, b32, c32) != ((a32 > b32) ? c32 : (uint32_t)(c32 + 1))) return 7;\n      if (c_ugt_f64(a, b, c) != ((a > b) ? c : c + 1)) return 8;\n      if (c_ule_t32(a32, b32, c32) != ((a32 <= b32) ? (uint32_t)(c32 + 1) : c32)) return 9;\n      if (c_ule_t64(a, b, c) != ((a <= b) ? c + 1 : c)) return 10;\n      if (c_ule_f32(a32, b32, c32) != ((a32 <= b32) ? c32 : (uint32_t)(c32 + 1))) return 11;\n      if (c_ule_f64(a, b, c) != ((a <= b) ? c : c + 1)) return 12;\n      if (c_uge_t32(a32, b32, c32) != ((a32 >= b32) ? (uint32_t)(c32 + 1) : c32)) return 13;\n      if (c_uge_t64(a, b, c) != ((a >= b) ? c + 1 : c)) return 14;\n      if (c_uge_f32(a32, b32, c32) != ((a32 >= b32) ? c32 : (uint32_t)(c32 + 1))) return 15;\n      if (c_uge_f64(a, b, c) != ((a >= b) ? c : c + 1)) return 16;\n      if (c_imm(a32, c32) != (100u > a32 ? c32 + 1 : c32)) return 17;\n      if (blen32(a32) != (a32 ? 32 - __builtin_clz(a32) : 0)) return 18;\n      if (blen64(a) != (a ? 64 - __builtin_clzll(a) : 0)) return 19;\n      int32_t x = (int32_t)a32, y = (int32_t)b32;\n      int32_t s = (x < y) + (x == y);\n      if (cmpv(x, y) != s + (s != x)) return 20;\n    }\n  return 0;\n}\n";
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
  sig (i16) -> i16
b0(v0: i16):
  v1 = iconst.i16 21846
  v2 = mulhs.i16 v1, v0
  ret v2
fn @hs8
  sig (i8) -> i8
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
uint8_t r8(int8_t, int8_t);
uint8_t rc8(int8_t);
uint16_t r16r(int16_t, int32_t);
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
      if (r8((int8_t)x, (int8_t)n) != (uint8_t)rot(u, (unsigned)n & 7, 8)) return 3;
      if (r16r((int16_t)x, n) != (uint16_t)rot(u, (16 - ((unsigned)n & 15)) & 15, 16)) return 18;
      unsigned s = (unsigned)n & 63;
      if ((uint64_t)rx(x, n) != ((u << s) ^ (u >> ((0u - (unsigned)n) & 63)))) return 4;
    }
    if ((uint64_t)rc64(x) != rot(u, 13, 64)) return 5;
    if (rc8((int8_t)x) != (uint8_t)rot(u, 3, 8)) return 19;
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

// The even lanes of two vectors (`vunzip`) of every lane width, in vector registers (8 and 16 bytes) and
// in memory (32 and 64 bytes; ymm and zmm registers with AVX2 and AVX-512): lane k is lane 2k of the two
// operands' lanes in order, its bits unchanged (lanes with the sign bit set included).
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
    let mut lir = String::from_str("lir ptr 8\n");
    let mut drv = String::from_str("#include <stdint.h>\n#include <string.h>\n");
    let mut body = String::from_str("int main(void) {\n  int r = 0;\n");
    for k in 0..names.len() {
        lir.format_into(
            "sym @u{} fn global\nfn @u{}\n  sig (ptr, ptr, ptr) -> void\nb0(v0: ptr, v1: ptr, v2: ptr):\n  v3 = load.{} v1 align 0\n  v4 = load.{} v2 align 0\n  v5 = vunzip.{} v3, v4\n  store v5, v0 align 0\n  ret\n",
            k,
            k,
            names[k],
            names[k],
            names[k],
        );
        drv.format_into("void u{}(void *, const void *, const void *);\n", k);
        body.format_into(
            "  {{\n    {} a[64], b[64], o[64];\n    for (int i = 0; i < 64; i++) {{ a[i] = ({})(i * 37 - 100); b[i] = ({})(i * 53 + 7); }}\n    u{}(o, a, b);\n    for (int i = 0; i < {}; i++) if (memcmp(&o[i], 2 * i < {} ? &a[2 * i] : &b[2 * i - {}], sizeof o[i]) != 0) r = {};\n  }}\n",
            cty[k],
            cty[k],
            cty[k],
            k,
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
    assert_eq(run_wasm(lir, drv), 0);
}

// Switches: dense ones (a jump table), a sparse one, a wide one whose value less the lowest case does not
// fit 32 bits, and one that drives a loop.
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
// and the store writes that register, as it does an xmm-held vector of any other home. It compiles for
// x86-64 on every host and runs on the host.
@test
fn a_stored_vector_join_runs() {
    let lir = M"(lir ptr 8
sym @pick fn global
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
)";
    let mut obj = Vector::<u8>::new();
    let x64 = tgt::axis_index("x86_64", true);
    assert(object_of(lir, tgt::axis_index("linux", false), x64, 0, &mut obj), "the System V object");
    obj.truncate(0);
    assert(object_of(lir, tgt::axis_index("windows", false), x64, 0, &mut obj), "the Microsoft x64 object");
    if !cli::has_cc() {
        return; // a C driver links it
    }
    let drv = "void pick(signed char, float *);\nint main(void) {\n  float a[12] = {1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0};\n  pick(1, a);\n  if (a[8] != 1 || a[11] != 4) return 1;\n  pick(0, a);\n  if (a[8] != 5 || a[11] != 8) return 2;\n  return 0;\n}\n";
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
    let drv = "#include <stdint.h>\nint dense(int);\nint sparse(int64_t);\nint wide(int64_t);\nint machine(int);\nint main(void) {\n  int d[10] = {-1, -1, 10, 20, 30, 20, -1, 107, 10, -1};\n  for (int i = 0; i < 10; i++) if (dense(i) != d[i]) return 1;\n  if (dense(-2) != -1 || dense(1 << 30) != -1) return 2;\n  if (sparse(0) != 1 || sparse(1000) != 2 || sparse(-5) != 3 || sparse((int64_t)1 << 40) != 2 || sparse(5) != 4) return 3;\n  int w[7] = {3, 1, 2, 1, 2, 3, 1};\n  for (int i = 0; i < 7; i++) if (wide(9 + i) != w[i]) return 4;\n  if (wide(((int64_t)1 << 33) + 10) != 3 || wide(-1) != 3) return 5;\n  if (machine(3) != 111 || machine(0) != 0 || machine(9) != -1) return 6;\n  return 0;\n}\n";
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
