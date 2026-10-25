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

// Compile LIR `text` natively on the host, link it with C `driver` and run it; the exit code, or -1 when
// a step failed (the failure on stderr). 0 on a host without a native backend.
fn run_native(text: str, driver: str) i32 {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return 0;
    }
    return run_lir(text, driver, tgt::host_os(), tgt::host_isa(), "cc", "");
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
    return run_lir(
        t.as_str(),
        driver,
        tgt::axis_index("wasm", false),
        tgt::axis_index("wasm32", true),
        cc.as_str(),
        "wasmtime run ",
    );
}

// Compile LIR `text` for `(os, isa)`, link it with C `driver` by C compiler command `cc` and run the
// program through command prefix `runner`; the exit code, or -1 when a step failed (the failure on
// stderr).
fn run_lir(text: str, driver: str, os: i32, isa: i32, cc: str, runner: str) i32 {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    if q.is_none() {
        eprint("parse: {}\n", err.as_str());
        return -1;
    }
    let p = q.unwrap();
    let mut v = verify::Verifier::new();
    for i in 0..p.syms.len() {
        let s = p.syms[i];
        if s.def != NONE && s.kind == SK_FUNC && !v.check(&p, p.spell(s.name), &p.bodies[s.def as usize]) {
            eprint("verify: {}\n", v.err.as_str());
            return -1;
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
    let mut obj = Vector::<u8>::new();
    if !nat::object(&p, os, isa, fs_[0..fs_.len()], ds[0..ds.len()], &mut obj, &mut err) {
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
    let mut cmd = format("{} -o \"{}\" \"{}\" \"{}\"", cc, bp.as_str(), cp.as_str(), op.as_str());
    if cli::run_with(cmd.cstr(), null, null, null, "") != 0 {
        return -1;
    }
    let mut run = format("{}\"{}\"", runner, bp.as_str());
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
    assert_eq(run_wasm(lir, drv), 0);
}

@test
fn wide_integers_run() {
    let lir = "lir ptr 8\nsym @div fn global\nsym @mul fn global\nsym @shr fn global\nfn @div\n  sig (i64, i64, i64, ptr) -> i64\nb0(v0: i64, v1: i64, v2: i64, v3: ptr):\n  v4 = zext.i128 v0\n  v5 = wconst.i128 0x40, 0x0\n  v6 = shl.i128 v4, v5\n  v7 = zext.i128 v1\n  v8 = or.i128 v6, v7\n  v9 = zext.i128 v2\n  v10 = urem.i128 v8, v9\n  v11 = trunc.i64 v10\n  store v11, v3 align 3\n  v12 = udiv.i128 v8, v9\n  v13 = trunc.i64 v12\n  ret v13\nfn @mul\n  sig (i64, i64, ptr) -> i64\nb0(v0: i64, v1: i64, v2: ptr):\n  v3 = zext.i128 v0\n  v4 = zext.i128 v1\n  v5 = mul.i128 v3, v4\n  v6 = wconst.i128 0x40, 0x0\n  v7 = lshr.i128 v5, v6\n  v8 = trunc.i64 v7\n  store v8, v2 align 3\n  v9 = trunc.i64 v5\n  ret v9\nfn @shr\n  sig (i64, i64, i32) -> i64\nb0(v0: i64, v1: i64, v2: i32):\n  v3 = sext.i128 v1\n  v4 = wconst.i128 0x40, 0x0\n  v5 = shl.i128 v3, v4\n  v6 = zext.i128 v0\n  v7 = or.i128 v5, v6\n  v8 = zext.i128 v2\n  v9 = ashr.i128 v7, v8\n  v10 = trunc.i64 v9\n  ret v10\n";
    let drv = "#include <stdint.h>\nint64_t div(int64_t, int64_t, int64_t, int64_t *);\nint64_t mul(int64_t, int64_t, int64_t *);\nint64_t shr(int64_t, int64_t, int32_t);\nint main(void) {\n  int64_t r = 0;\n  if (div(3, 5, 7, &r) != (int64_t)(((unsigned __int128)3 << 64 | 5) / 7) || r != (int64_t)(((unsigned __int128)3 << 64 | 5) % 7)) return 1;\n  int64_t h = 0;\n  if (mul(-1, -1, &h) != 1 || h != -2) return 2;\n  if (shr(0, -2, 65) != -1 || shr(0, 4, 1) != 0 || shr(0, 4, 64) != 4 || shr(8, 0, 3) != 1) return 3;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A loop header's parameter keeps its home past its last use to the back edge, which writes it again;
// here its last use is the checked increment in the back edge's own block.
@test
fn loop_parameters_keep_their_homes() {
    let lir = "lir ptr 8\nsym @id fn global\nsym @f fn global\nfn @f\n  sig (ptr, i64) -> i64\nb0(v0: ptr, v1: i64):\n  v2 = iconst.i64 0\n  v3 = iconst.i64 1\n  jmp b1(v2, v2, v0)\nb1(v4: i64, v5: i64, v6: ptr):\n  v7 = icmp.ult v4, v1\n  br v7, b2, b3\nb2:\n  v8 = load.i64 v6 align 3\n  v9 = call.i64 @id(v8) : (i64) -> i64\n  v10 = add.i64 v5, v9\n  v11 = ptradd v6+8\n  v12, v13 = addo.u.i64 v4, v3\n  br v13, b4, b1(v12, v10, v11)\nb3:\n  ret v5\nb4: cold\n  panic \"attempt to add with overflow\"\n";
    let drv = "#include <stdint.h>\nint64_t f(const int64_t *, int64_t);\nint64_t id(int64_t x) { return x; }\nvoid __sc_panic(const char *m) { (void)m; __builtin_trap(); }\nint main(void) {\n  int64_t a[4] = {1, 2, 3, 4};\n  return f(a, 4) == 10 ? 0 : 1;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Values a loop keeps past their last use in its last block hold their homes over the back edge: a
// later value of that block takes no register or slot of theirs.
@test
fn loop_kept_values_keep_their_homes() {
    let lir = "lir ptr 8\nsym @id fn global\nsym @f fn global\nfn @f\n  sig (ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, i64) -> i64\nb0(v0: ptr, v1: ptr, v2: ptr, v3: ptr, v4: ptr, v5: ptr, v6: ptr, v7: ptr, v8: i64):\n  v9 = iconst.i64 0\n  v10 = iconst.i64 1\n  jmp b1(v9, v9)\nb1(v11: i64, v12: i64):\n  v13 = icmp.ult v11, v8\n  br v13, b2, b3\nb2:\n  v14 = load.i64 v0 align 3\n  v15 = load.i64 v1 align 3\n  v16 = load.i64 v2 align 3\n  v17 = load.i64 v3 align 3\n  v18 = load.i64 v4 align 3\n  v19 = load.i64 v5 align 3\n  v20 = load.i64 v6 align 3\n  v21 = load.i64 v7 align 3\n  v22 = add.i64 v14, v15\n  v23 = add.i64 v22, v16\n  v24 = add.i64 v23, v17\n  v25 = add.i64 v24, v18\n  v26 = add.i64 v25, v19\n  v27 = add.i64 v26, v20\n  v28 = add.i64 v27, v21\n  v29 = add.i64 v12, v28\n  v30 = call.i64 @id(v29) : (i64) -> i64\n  v31 = call.i64 @id(v11) : (i64) -> i64\n  v32 = add.i64 v31, v10\n  jmp b1(v32, v30)\nb3:\n  ret v12\n";
    let drv = "#include <stdint.h>\nint64_t f(const int64_t *, const int64_t *, const int64_t *, const int64_t *, const int64_t *, const int64_t *, const int64_t *, const int64_t *, int64_t);\nint64_t id(int64_t x) { return x; }\nint main(void) {\n  int64_t a[8] = {1, 2, 3, 4, 5, 6, 7, 8};\n  return f(a, a + 1, a + 2, a + 3, a + 4, a + 5, a + 6, a + 7, 3) == 108 ? 0 : 1;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A frame of exactly 4 KiB (the slot and two spills): the stack pointer moves by all of it.
@test
fn a_page_sized_frame_runs() {
    let lir = "lir ptr 8\nsym @id fn global\nsym @g fn global\nfn @g\n  sig (i64) -> i64\n  slot s0 size 4080 align 3\nb0(v0: i64):\n  v1 = slotaddr s0\n  v2 = ptradd v1+8\n  store v0, v1 align 3\n  store v0, v2 align 3\n  v3 = call.i64 @id(v0) : (i64) -> i64\n  v4 = load.i64 v2 align 3\n  v5 = add.i64 v3, v4\n  ret v5\n";
    let drv = "#include <stdint.h>\nint64_t g(int64_t);\nint64_t id(int64_t x) { return x; }\nint main(void) { return g(21) == 42 ? 0 : 1; }\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// Float constants that fit the 8-bit immediate of `fmov`.
@test
fn float_immediates_run() {
    let lir = "lir ptr 8\nsym @kd fn global\nsym @kf fn global\nfn @kd\n  sig () -> f64\nb0:\n  v0 = fconst.f64 0x3ff0000000000000\n  v1 = fconst.f64 0x4000000000000000\n  v2 = fconst.f64 0xc028000000000000\n  v3 = fconst.f64 0x3fc0000000000000\n  v4 = fadd.f64 v0, v1\n  v5 = fadd.f64 v4, v2\n  v6 = fadd.f64 v5, v3\n  ret v6\nfn @kf\n  sig () -> f32\nb0:\n  v0 = fconst.f32 0x3f800000\n  v1 = fconst.f32 0x40000000\n  v2 = fconst.f32 0x3f000000\n  v3 = fconst.f32 0xc1f80000\n  v4 = fadd.f32 v0, v1\n  v5 = fadd.f32 v4, v2\n  v6 = fadd.f32 v5, v3\n  ret v6\n";
    let drv = "double kd(void);\nfloat kf(void);\nint main(void) { return kd() == -8.875 && kf() == -27.5f ? 0 : 1; }\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
}

// A loop's values stay live through a cold block that branches back into the loop, though the layout puts
// the cold block last: the call's result there takes no home of the counter's.
@test
fn a_cold_block_inside_a_loop_keeps_the_loop_values() {
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

// Switches: dense ones (a jump table), a sparse one, a wide one whose value less the lowest case does not
// fit 32 bits, and one that drives a loop.
@test
fn switches_run() {
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
// and C calls a LIR function that reads them.
@test
fn variadic_calls_run() {
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
  slot s0 size 8 align 3
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

// Function addresses in data (relocations) and indirect calls through them.
@test
fn indirect_calls_through_data_run() {
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
    let lir = "lir ptr 8\nsym @tw fn global\nfn @tw\n  sig (v8f32) -> v8f32\nb0(v0: v8f32):\n  v1 = fadd.v8f32 v0, v0\n  ret v1\n";
    let drv = "typedef struct { _Alignas(32) float l[8]; } v8;\nv8 tw(v8);\nint main(void) {\n  v8 a = {{1, 2, 3, 4, 5, 6, 7, 8}};\n  v8 r = tw(a);\n  for (int i = 0; i < 8; i++) if (r.l[i] != 2 * a.l[i]) return 1;\n  return 0;\n}\n";
    assert_eq(run_native(lir, drv), 0);
    assert_eq(run_wasm(lir, drv), 0);
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

// A call the native backend refuses after its module lowered (a C type of unknown class by value) sends
// the module through C: the build renders its C in a second run. A rebuild that changes only `main`
// replays the std modules, which rendered no C.
@test
fn a_module_the_backend_refuses_goes_through_c() {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("h.h", "typedef struct { double a; long b; } pair;\ndouble sum(pair p);\n");
    p.mkfile("h.c", "#include \"h.h\"\ndouble sum(pair p) { return p.a + (double)p.b + 7; }\n");
    assert(p.c_lib("hp", "h.c"), "the C library builds");
    p.mkfile("main.spc", pair_main(p.dir(), "").as_str());
    let r = cli::superc_env_in(p.dir(), "SC_NATIVE_STATS", "1", "build main.spc -o bin");
    assert(r.ok(), "the program builds");
    assert(r.out_has("main through C"), "main goes through C");
    assert_eq(p.run_bin(), 7);
    p.mkfile("main.spc", pair_main(p.dir(), " + 1").as_str());
    assert(cli::superc_in(p.dir(), "build main.spc -o bin").ok(), "the program builds again");
    assert_eq(p.run_bin(), 8);
}

// The `main` of `a_module_the_backend_refuses_goes_through_c`, linked from `dir`, its result plus `more`.
fn pair_main(dir: str, more: str) String {
    return format(
        "@link(\"-L{} -lhp\")\nextern \"C\" \"h.h\" {{\n    @layout(16, 8)\n    type pair;\n    fn sum(p: pair) f64;\n}}\n\nfn main() i32 {{\n    return unsafe sum(unsafe zeroed::<pair>()) as i32{};\n}}\n",
        dir,
        more,
    );
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
// `static` function, which no object exports, sends its caller through C: a first build renders its C in
// a second run, and a rebuild replays the modules that rendered none with what they demanded.
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
    // Only `main` changes: the std modules replay.
    p.mkfile(
        "main.spc",
        "extern \"C\" \"val.h\" {\n    const KVAL: i32;\n    fn one() i32;\n}\n\nfn main() i32 {\n    return KVAL + unsafe one() + 1;\n}\n",
    );
    assert_eq(cli::superc_in(p.dir(), "run").exit, 43);
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
