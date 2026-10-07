// CPU features and the attributes over them: the feature table and its std mirror, `--target-feature`
// and `target-features`, `@target_feature`, `@c.value` register types, the memory annotations of
// foreign functions, and the checks of `@simd_impl` entries and the backend table.
import ir::cpu_features as cf;
import ir::core as ir;
import build_system::build as bsys;
import build_system::manifest as mf;
import std::cpu;
import std::simd;
import tests::harness as h;
import tests::cli_harness as cli;
import string as cstring;

// The std enums follow the compiler's tables, name and discriminant: a mismatch fails the build of
// the test suite.
const fn features_match() bool {
    let ti = type_info::<cpu::Feature>();
    if ti.variants.len != cf::FEATURE_COUNT {
        return false;
    }
    for i in 0..cf::FEATURE_COUNT {
        let v = ti.variants.get(i);
        if v.name != cf::row(i).variant || v.tag != i as i32 {
            return false;
        }
    }
    return true;
}

const fn ops_match() bool {
    let ti = type_info::<simd::Op>();
    if ti.variants.len != ir::OP_COUNT as usize {
        return false;
    }
    for i in 0..ir::OP_COUNT {
        let v = ti.variants.get(i as usize);
        if v.name != ir::op_variant(i).as_str() || v.tag != i as i32 {
            return false;
        }
    }
    return true;
}

static_assert(features_match(), "std::cpu::Feature follows the compiler's feature table");
static_assert(ops_match(), "std::simd::Op follows the compiler's operation table");

// `+name` and a bare name enable, `-name` disables, in order; the closure adds what a feature
// implies; a name of another instruction set or an unknown one is an error listing the valid names.
@test
fn feature_lists_apply_in_order_and_close() {
    let mut s = cf::baseline(2);
    let mut err = String::new();
    assert(cf::is_empty(s), "wasm32 has no baseline feature");
    assert(cf::apply("+relaxed-simd", 2, true, &mut s, &mut err), "a known name");
    assert(!cf::has(s, cf::F_SIMD128) && cf::has(cf::close(s), cf::F_SIMD128), "relaxed-simd implies simd128");
    assert(cf::apply("simd128,-relaxed-simd", 2, true, &mut s, &mut err), "in order");
    assert(cf::has(s, cf::F_SIMD128) && !cf::has(s, cf::F_RELAXED_SIMD), "the later item wins");
    assert(cf::apply("+relaxed-simd,-simd128", 2, true, &mut s, &mut err), "a disabled implication");
    assert(cf::has(cf::close(s), cf::F_SIMD128), "the closure runs after the list");
    assert(!cf::apply("+simd128,+neon", 2, true, &mut s, &mut err), "another instruction set's feature");
    assert_eq(err.as_str(), "no target feature 'neon' for wasm32; the wasm32 features are: simd128, relaxed-simd");
    err.clear();
    assert(!cf::apply("+bogus", 2, true, &mut s, &mut err), "an unknown feature");
    assert_eq(err.as_str(), "unknown target feature 'bogus' for wasm32; the wasm32 features are: simd128, relaxed-simd");
    assert(cf::has(cf::baseline(0), 2) && cf::has(cf::baseline(1), 3), "sse2 and neon are the baselines");
    err.clear();
    assert(!cf::apply("-sse2", 0, true, &mut s, &mut err), "a baseline feature stays");
    assert_eq(err.as_str(), "target feature 'sse2' is part of every x86_64 build");
    // A lenient list (build.toml) skips another instruction set's features; an unknown name fails.
    let mut h = cf::baseline(1);
    assert(cf::apply("+simd128", 1, false, &mut h, &mut err) && h.w[0] == cf::baseline(1).w[0], "skipped");
    err.clear();
    assert(!cf::apply("+simd128", -1, true, &mut h, &mut err), "an unknown instruction set");
    assert_eq(err.as_str(), "no target feature 'simd128' for this instruction set; it has none");
}

// `target-features` in the build section and in a profile, which replaces it; the command line's
// list applies last; a bad name in either is an error before anything builds.
@test
fn manifest_and_command_line_features() {
    let (mo, _e) = mf::parse_check(
        "bin = \"app\"\nroot = \"main.spc\"\ntarget-features = [\"simd128\"]\n[profile.none]\ntarget-features = []\n[profile.relaxed]\ntarget-features = [\"+relaxed-simd\"]\n",
        "",
        false,
    );
    let mut m = mo.unwrap();
    m.arch = 2;
    assert(bsys::check_features(&m, ""), "valid lists");
    let simd = bsys::features_for(&m, "dev", "");
    assert(cf::has(simd, cf::F_SIMD128) && !cf::has(simd, cf::F_RELAXED_SIMD), "the build's list");
    assert(cf::is_empty(bsys::features_for(&m, "none", "")), "a profile's empty list replaces it");
    let rel = bsys::features_for(&m, "relaxed", "");
    assert(cf::has(rel, cf::F_SIMD128) && cf::has(rel, cf::F_RELAXED_SIMD), "a profile's own list, closed");
    assert(cf::is_empty(bsys::features_for(&m, "dev", "-simd128")), "the command line applies last");
    assert(!bsys::check_features(&m, "+neon"), "the command line's names are checked");
    let p = cli::proj_new();
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let r = p.compile_flags("--target=wasm --target-feature=+simd128,+avx2", "main.spc");
    assert(
        !r.ok() && r.out_has("unknown target feature 'avx2' for wasm32; the wasm32 features are: simd128, relaxed-simd"),
        "the CLI error",
    );
    // A manifest list names features of every instruction set it builds for: another's apply to
    // another build; an unknown name is an error.
    m.arch = 0;
    assert(bsys::check_features(&m, ""), "a native build of a project with a wasm32 list");
    assert(bsys::features_for(&m, "relaxed", "").w[0] == cf::baseline(0).w[0], "the baseline alone");
    p.mkfile(
        "build.toml",
        "bin = \"app\"\nroot = \"main.spc\"\n[profile.web]\ntarget-features = [\"sse2\", \"bogus\"]\n",
    );
    let root = str::from_cstr(p.rootp());
    let b = cli::superc_env_in(root, "SC_NONE", "", "build --target=wasm");
    assert(!b.ok() && b.out_has("unknown target feature 'bogus' for wasm32"), "the manifest's names are checked");
}

// `@target_feature` takes a list of `cpu::Feature`; a misspelled variant is an error at the argument,
// another type a type error, and every feature must belong to an instruction set the function's
// `@arch` gate allows.
@test
fn target_feature_arguments_are_checked() {
    h::expect_err_msg(
        "a misspelled feature",
        "@arch(x86_64 | aarch64)\n@target_feature([Feature::Neonn])\nfn f() {}\nfn main() i32 {\n    return 0;\n}\n",
        "no variant, method, or constant 'Neonn'",
    );
    h::expect_err_msg(
        "another enum",
        "@arch(x86_64 | aarch64)\n@target_feature([Op::Add])\nfn f() {}\nfn main() i32 {\n    return 0;\n}\n",
        "expected a nonempty list of 'cpu::Feature' values",
    );
    h::expect_err_msg(
        "no list",
        "@arch(x86_64 | aarch64)\n@target_feature(Feature::Sse2)\nfn f() {}\nfn main() i32 {\n    return 0;\n}\n",
        "expected a nonempty list of 'cpu::Feature' values",
    );
    h::expect_err_msg(
        "no gate",
        "@target_feature([Feature::Sse2])\nfn f() {}\nfn main() i32 {\n    return 0;\n}\n",
        "feature 'sse2' belongs to x86_64: the function needs '@arch(x86_64)'",
    );
    h::expect_err_msg(
        "another instruction set",
        "@arch(x86_64 | aarch64)\n@target_feature([Feature::Simd128])\nfn f() {}\nfn main() i32 {\n    return 0;\n}\n",
        "feature 'simd128' belongs to wasm32: the function needs '@arch(wasm32)'",
    );
    // An item the build filter removes reports its gate as one it keeps does.
    let gated = h::compile(
        "@arch(wasm32)\n@target_feature([cpu::Feature::Sse2])\nfn f() {}\nfn main() i32 {\n    return 0;\n}\n",
        h::STAGE_PARSE,
    );
    assert(gated.msg_has("feature 'sse2' belongs to x86_64: the function needs '@arch(x86_64)'"), "a gated-out item");
    h::expect_ok(
        "a trailing comma",
        "@arch(x86_64)\n@target_feature([Feature::Sse2],)\nfn f() {}\n@arch(aarch64)\n@target_feature([Feature::Neon],)\nfn f() {}\nfn main() i32 {\n    return 0;\n}\n",
    );
    let c = h::compile(
        "extern \"C\" {\n    @c.value((16, 16))\n    pub type reg_t;\n}\nfn main() i32 {\n    return 0;\n}\n",
        h::STAGE_PARSE,
    );
    assert(c.msg_has("attribute '@c.value' takes 2 arguments"), "a tuple is one argument");
    h::expect_err_msg(
        "two arguments",
        "@arch(x86_64)\n@target_feature([Feature::Sse2], 1)\nfn f() {}\nfn main() i32 {\n    return 0;\n}\n",
        "attribute '@target_feature' takes 1 argument",
    );
    h::expect_ok(
        "the baseline",
        "@arch(x86_64)\n@target_feature([Feature::Sse2])\nfn f() i32 {\n    return 1;\n}\n@arch(aarch64)\n@target_feature([Feature::Neon])\nfn f() i32 {\n    return 1;\n}\nfn main() i32 {\n    return f() - 1;\n}\n",
    );
}

// A call of a function that needs features the build lacks, or a pointer to one, is an error naming
// the flag; a function that needs them itself may call it; a build with the features compiles.
@test
fn target_feature_calls_need_the_build_features() {
    let src = "import std::cpu;\n@arch(wasm32)\n@target_feature([cpu::Feature::RelaxedSimd])\nfn relaxed_madd() i32 {\n    return 1;\n}\n@arch(wasm32)\n@target_feature([cpu::Feature::RelaxedSimd])\nfn inner() i32 {\n    return relaxed_madd();\n}\nfn main() i32 {\n    let f = inner;\n    return relaxed_madd() + f() - 2;\n}\n";
    let p = cli::proj_new();
    p.mkfile("main.spc", src);
    let r = p.compile_flags("--target=wasm --target-feature=+simd128", "main.spc");
    assert(!r.ok(), "the build lacks relaxed-simd");
    assert(
        r.out_has("`relaxed_madd` needs `+relaxed-simd` (`--target-feature=+relaxed-simd`)"),
        "the call names the flag",
    );
    assert(r.out_has("`inner` needs `+relaxed-simd`"), "a pointer to it too");
    assert(!r.out_has("main.spc:10:"), "a function that needs the feature calls it");
    // The value use and the direct call, not the call through the value.
    let o = str::from_cstr(r.out);
    let mut errs: usize = 0;
    let mut at: isize = o.find("needs `+relaxed-simd`");
    while at >= 0 {
        errs += 1;
        let rest = o.slice(at as usize + 1, o.len());
        let nx = rest.find("needs `+relaxed-simd`");
        at = if nx < 0 {
            -1;
        } else {
            at + 1 + nx;
        };
    }
    assert(errs == 2, "one error per use");
    assert(p.compile_flags("--target=wasm --target-feature=+relaxed-simd", "main.spc").ok(), "with the feature");
}

// `@c.value(size, align)` gives an opaque extern type a layout: it is Copy, sizeof and alignof read
// it, and as a field, an element, a static, a pointer target or a generic argument it is an error.
@test
fn register_types_have_a_layout_and_no_storage() {
    let decl = "extern \"C\" {\n    @c.value(32, 16)\n    pub type reg_t;\n    fn make() reg_t;\n}\n";
    let mut ok = String::from_str(decl);
    ok.push_str(
        "static_assert(sizeof(reg_t) == 32 && alignof(reg_t) == 16, \"layout\");\nfn pass(r: reg_t) reg_t {\n    let a = r;\n    let b = r;\n    return a;\n}\nfn main() i32 {\n    return 0;\n}\n",
    );
    h::expect_ok("a local, a parameter, a result, copied", ok.as_str());
    let bad: [str; 6] = [
        "struct S {\n    r: reg_t,\n}\n",
        "fn f(a: [reg_t; 2]) {}\n",
        "fn f(a: []reg_t) {}\n",
        "extern \"C\" {\n    static mut R: reg_t;\n}\n",
        "fn f(p: *const reg_t) {}\n",
        "fn f(v: Vector<reg_t>) {}\n",
    ];
    for b in bad {
        let mut s = String::from_str(decl);
        s.push_str(b);
        s.push_str("fn main() i32 {\n    return 0;\n}\n");
        h::expect_err_msg(b, s.as_str(), "`reg_t` is a register type; store it through `Simd<T, N>`");
    }
    h::expect_err_msg(
        "an alignment that does not divide the size",
        "extern \"C\" {\n    @c.value(24, 16)\n    pub type reg_t;\n}\nfn main() i32 {\n    return 0;\n}\n",
        "'@c.value' needs a nonzero size that is a multiple of the alignment",
    );
    h::expect_err_msg(
        "outside an extern block",
        "@c.value(16, 16)\ntype reg_t = i32;\nfn main() i32 {\n    return 0;\n}\n",
        "'@c.value' may only be applied to an opaque type ('type T;') in an 'extern \"C\"' block",
    );
}

// `@c.reads` and `@c.writes` name a raw pointer parameter (`*mut` for a write) and a byte count, a
// constant or an expression over the function's parameters; only in an extern block.
@test
fn memory_annotations_are_checked() {
    let cases: [[str; 2]; 5] = [
        ["    @c.reads(q, 16)\n    fn f(p: *const void);\n", "cannot find value 'q'"],
        ["    @c.reads(n, 16)\n    fn f(n: usize);\n", "parameter 'n' of '@c.reads' must be a raw pointer"],
        ["    @c.writes(p, 16)\n    fn f(p: *const void);\n", "parameter 'p' of '@c.writes' must be a '*mut' pointer"],
        [
            "    @c.reads(p, n)\n    fn f(p: *const void, n: i32);\n",
            "the byte count is a 'usize' constant or an expression over the function's other 'usize' parameters",
        ],
        ["    @c.reads(p)\n    fn f(p: *const void);\n", "attribute '@c.reads' takes 2 arguments"],
    ];
    for c in cases {
        let mut s = String::from_str("extern \"C\" {\n");
        s.push_str(c[0]);
        s.push_str("}\nfn main() i32 {\n    return 0;\n}\n");
        if c[1].starts_with("attribute") {
            assert(h::parse_has_error(s.as_str()), c[1]);
        } else if c[1].starts_with("cannot") {
            h::expect_resolve_err_msg(c[1], s.as_str(), c[1]);
        } else {
            h::expect_err_msg(c[1], s.as_str(), c[1]);
        }
    }
    h::expect_ok(
        "constant and parameter counts",
        "extern \"C\" {\n    @c.reads(p, 16)\n    fn f(p: *const void);\n    @c.writes(d, n * 4 + 1)\n    fn g(d: *mut void, n: usize);\n    @c.lane_access\n    fn h(p: *mut void);\n}\nfn main() i32 {\n    return 0;\n}\n",
    );
    // A global named like the parameter is no parameter.
    h::expect_err_msg(
        "a global",
        "const q: usize = 1;\nextern \"C\" {\n    @c.reads(q, 16)\n    fn f(p: *const void);\n}\nfn main() i32 {\n    return 0;\n}\n",
        "'q' is not a parameter of this function",
    );
    let c = h::compile("@c.reads(p, 16)\nfn f(p: *const void) {}\nfn main() i32 {\n    return 0;\n}\n", h::STAGE_PARSE);
    assert(
        c.msg_has("'@c.reads' may only be applied to a function in an 'extern \"C\"' block or an '@intrinsic' function"),
        "outside an extern block",
    );
    // The annotations have no code effect: the C of a program that calls the function is the same
    // without them.
    let with = "extern \"C\" {\n    @c.reads(p, 4)\n    fn probe(p: *const void) i32;\n}\nfn main() i32 {\n    let x: i32 = 7;\n    return unsafe probe(&x as *const i32 as *const void);\n}\n";
    let without = "extern \"C\" {\n    fn probe(p: *const void) i32;\n}\nfn main() i32 {\n    let x: i32 = 7;\n    return unsafe probe(&x as *const i32 as *const void);\n}\n";
    let cw = h::compile_c_user(with);
    let co = h::compile_c_user(without);
    assert(cw.ok() && co.ok() && unsafe cstring::strcmp(cw.code, co.code) == 0, "the same C");
}

// `@simd_impl` is reserved for std; there it takes an operation and a feature list of the entry's
// instruction set, never relaxed SIMD, a signature of the operation's shape, and one entry per key.
@test
fn simd_impl_entries_are_checked() {
    h::expect_err_msg(
        "outside std",
        "@arch(x86_64)\n@simd_impl(Op::Add, [Feature::Sse2])\nfn add(a: f32x4, b: f32x4) f32x4 {\n    return a;\n}\n@arch(aarch64)\n@simd_impl(Op::Add, [Feature::Neon])\nfn add(a: f32x4, b: f32x4) f32x4 {\n    return a;\n}\nfn main() i32 {\n    return 0;\n}\n",
        "'@simd_impl' is reserved for the standard library",
    );
    let cases: [[str; 3]; 7] = [
        [
            "Add",
            "a: f32x4",
            "a '@simd_impl(simd::Op::Add, ..)' entry has the signature `fn(Simd<T, N>, Simd<T, N>) Simd<T, N>`",
        ],
        [
            "CmpLtLanes",
            "a: f32x4, b: f32x4",
            "`fn(Simd<T, N>, Simd<T, N>) Simd<U, N>, U the unsigned type of T's width`",
        ],
        [
            "ChooseLanes",
            "m: i32x4, a: f32x4, b: f32x4",
            "`fn(Simd<U, N>, Simd<T, N>, Simd<T, N>) Simd<T, N>, U the unsigned type of T's width`",
        ],
        ["LanesToMask", "m: u32x4", "`fn(Simd<U, N>) Mask<N>, U unsigned`"],
        ["Load", "p: *const i32", "`fn(*const T) Simd<T, N>, the N elements at the pointer`"],
        ["Compress", "m: mask4, a: f32x4, b: f32x4", "'simd::Op::Compress' has no '@simd_impl' form"],
        ["Swizzle", "a: f32x4, b: Simd<u8, 8>", "'simd::Op::Swizzle' has no '@simd_impl' form"],
    ];
    for c in cases {
        let mut s = String::new();
        s.format_into(
            "@arch(x86_64)\n@simd_impl(Op::{}, [Feature::Sse2])\nfn e({}) f32x4 {{\n    return f32x4::splat(0.0);\n}}\n@arch(aarch64)\n@simd_impl(Op::{}, [Feature::Neon])\nfn e({}) f32x4 {{\n    return f32x4::splat(0.0);\n}}\nfn main() i32 {{\n    return 0;\n}}\n",
            c[0],
            c[1],
            c[0],
            c[1],
        );
        let r = h::compile_std(s.as_str(), -1, h::STAGE_TYPECHECK);
        assert(!r.ok() && r.msg_has(c[2]), c[2]);
    }
    let gated = "@arch(x86_64 | aarch64)\n@simd_impl(Op::Add, [Feature::Simd128])\nfn e(a: f32x4, b: f32x4) f32x4 {\n    return a;\n}\nfn main() i32 {\n    return 0;\n}\n";
    let r = h::compile_std(gated, -1, h::STAGE_TYPECHECK);
    assert(!r.ok() && r.msg_has("feature 'simd128' belongs to wasm32: the function needs '@arch(wasm32)'"), "the gate");
    let relaxed = "@arch(wasm32)\n@simd_impl(Op::Add, [Feature::RelaxedSimd])\nfn e(a: f32x4, b: f32x4) f32x4 {\n    return a;\n}\nfn main() i32 {\n    return 0;\n}\n";
    let rr = h::compile_std(relaxed, 2, h::STAGE_TYPECHECK);
    assert(!rr.ok() && rr.msg_has("a '@simd_impl' entry cannot need 'relaxed-simd'"), "no relaxed entry");
    let two = "@arch(x86_64)\n@simd_impl(Op::Add, [Feature::Sse2])\nfn e1(a: f32x4, b: f32x4) f32x4 {\n    return a;\n}\n@arch(x86_64)\n@simd_impl(Op::Add, [Feature::Sse2])\nfn e2(a: f32x4, b: f32x4) f32x4 {\n    return b;\n}\n@arch(aarch64)\n@simd_impl(Op::Add, [Feature::Neon])\nfn e1(a: f32x4, b: f32x4) f32x4 {\n    return a;\n}\n@arch(aarch64)\n@simd_impl(Op::Add, [Feature::Neon])\nfn e2(a: f32x4, b: f32x4) f32x4 {\n    return b;\n}\nfn main() i32 {\n    return 0;\n}\n";
    let d = h::compile_std(two, -1, h::STAGE_TYPECHECK);
    assert(
        !d.ok() && d.msg_has(
            "two '@simd_impl' entries for one operation, lane type, lane count and feature count: this one and 'e1'",
        ),
        "a duplicate key",
    );
}

// A build's features are part of every unit's fingerprint: a changed set compiles every unit again,
// an unchanged one compiles none. A C compiler that rejects a feature's flag fails the build at its
// probe (a wasi-sdk in WASI_SDK_PATH).
@test
fn feature_sets_rebuild_and_probe() {
    let sdk = stdlib::getenv("WASI_SDK_PATH");
    if sdk == null || unsafe *sdk == 0 as char || cli::on_windows() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let root = str::from_cstr(p.rootp());
    let runs: [str; 4] = [
        "build --target=wasm",
        "build --target=wasm",
        "build --target=wasm --target-feature=+simd128",
        "build --target=wasm --target-feature=+simd128",
    ];
    for i in 0usize..4 {
        let r = cli::superc_env_in(root, "SC_BUILD_STATS", "-", unsafe runs[i]);
        assert(r.ok(), unsafe runs[i]);
        assert(r.out_has("\"stale\":0,") == (i % 2 == 1), "a changed set compiles every unit, an unchanged one none");
        assert(r.out_has("\"skip_emit\":true") == (i % 2 == 1), "an unchanged set skips emission");
    }
    // A compiler that rejects -msimd128.
    let mut sh = String::new();
    sh.format_into(
        "#!/bin/sh\nfor a in \"$@\"; do\n  [ \"$a\" = -msimd128 ] && exit 1\ndone\nexec \"{}/bin/clang\" \"$@\"\n",
        str::from_cstr(sdk),
    );
    p.mkfile("cc.sh", sh.as_str());
    let mut cmd = String::new();
    cmd.format_into("chmod +x \"{}/cc.sh\"", root);
    assert(cli::run_quiet(cmd.cstr()) == 0, "chmod");
    let mut b = String::new();
    b.format_into("build --target=wasm --target-feature=+simd128 --cc={}/cc.sh", root);
    let r = cli::superc_env_in(root, "SC_NO_CACHE", "1", b.as_str());
    assert(!r.ok(), "the build fails");
    assert(r.out_has("rejects '-msimd128': target feature 'simd128' needs a compiler that supports it"), "at the probe");
    // A build without a manifest probes the same flag.
    let mut sb = String::new();
    sb.format_into("build main.spc --target=wasm --target-feature=+simd128 --cc={}/cc.sh -o app", root);
    let rs = cli::superc_env_in(root, "SC_NO_CACHE", "1", sb.as_str());
    assert(!rs.ok() && rs.out_has("rejects '-msimd128'"), "a script build");
}

// A function the program's environment calls (`main`, `@c.export`, `@test`, `@bench`) needs its
// features in the build; a function that needs features calls another that needs only what they
// imply.
@test
fn outside_callers_and_implied_features() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import std::cpu;\n@arch(wasm32)\n@target_feature([cpu::Feature::Simd128])\n@c.export(\"exported\")\npub fn exported() i32 {\n    return 1;\n}\n@arch(wasm32)\n@target_feature([cpu::Feature::Simd128])\nfn main() i32 {\n    return 0;\n}\n",
    );
    let r = p.compile_flags("--target=wasm", "main.spc");
    assert(!r.ok(), "the build lacks simd128");
    assert(
        r.out_has("`main` needs `+simd128` (`--target-feature=+simd128`); it is called from outside the program"),
        "main",
    );
    assert(r.out_has("`exported` needs `+simd128`"), "an exported function");
    assert(p.compile_flags("--target=wasm --target-feature=+simd128", "main.spc").ok(), "with the feature");
    p.mkfile(
        "main.spc",
        "import std::cpu;\n@arch(wasm32)\n@target_feature([cpu::Feature::Simd128])\nfn base() i32 {\n    return 1;\n}\n@arch(wasm32)\n@target_feature([cpu::Feature::RelaxedSimd])\nfn relaxed() i32 {\n    return base();\n}\nfn main() i32 {\n    return 0;\n}\n",
    );
    assert(p.compile_flags("--target=wasm", "main.spc").ok(), "relaxed-simd implies simd128");
}

// A method of a conformance is called through bounds, where no call names it: it takes no features.
// An `@arch` gate on an extend covers its methods.
@test
fn feature_methods_and_extend_gates() {
    h::expect_err_msg(
        "a conformance method",
        "interface Area { fn area(self: &Self) i32; }\nstruct S {\n    pub v: i32,\n}\n@arch(x86_64 | aarch64)\nextend S as Area {\n    @target_feature([Feature::Sse2])\n    fn area(self: &Self) i32 {\n        return self.v;\n    }\n}\nfn main() i32 {\n    return 0;\n}\n",
        "a method of a conformance ('extend T as I') cannot need CPU features",
    );
    h::expect_ok(
        "an extend's gate",
        "struct S {\n    pub v: i32,\n}\n@arch(x86_64)\nextend S {\n    @target_feature([Feature::Sse2])\n    pub fn get(self: &Self) i32 {\n        return self.v;\n    }\n}\n@arch(aarch64)\nextend S {\n    @target_feature([Feature::Neon])\n    pub fn get(self: &Self) i32 {\n        return self.v;\n    }\n}\nfn main() i32 {\n    let s = S { v: 0 };\n    return s.get();\n}\n",
    );
    h::expect_err_msg(
        "no compile-time value",
        "@arch(x86_64)\n@target_feature([Feature::Sse2])\nfn f() i32 {\n    return 1;\n}\n@arch(aarch64)\n@target_feature([Feature::Neon])\nfn f() i32 {\n    return 1;\n}\nconst X: i32 = f();\nfn main() i32 {\n    return X - 1;\n}\n",
        "`f` has no compile-time value",
    );
}

// More `@simd_impl` checks: a misspelled operation, a reduction's result, the lane class.
@test
fn simd_impl_operations_results_and_lanes() {
    let cases: [[str; 4]; 3] = [
        ["Addd", "a: f32x4, b: f32x4", "f32x4", "no variant, method, or constant 'Addd'"],
        [
            "ReduceAdd",
            "a: i32x4",
            "u8",
            "a '@simd_impl(simd::Op::ReduceAdd, ..)' entry has the signature `fn(Simd<T, N>) T`",
        ],
        ["Sqrt", "a: i32x4", "i32x4", "'simd::Op::Sqrt' does not apply to lanes of 'i32'"],
    ];
    for c in cases {
        let mut s = String::new();
        s.format_into(
            "@arch(x86_64)\n@simd_impl(Op::{}, [Feature::Sse2])\nfn e({}) {} {{\n    return a;\n}}\n@arch(aarch64)\n@simd_impl(Op::{}, [Feature::Neon])\nfn e({}) {} {{\n    return a;\n}}\nfn main() i32 {{\n    return 0;\n}}\n",
            c[0],
            c[1],
            c[2],
            c[0],
            c[1],
            c[2],
        );
        let r = h::compile_std(s.as_str(), -1, h::STAGE_TYPECHECK);
        if !r.msg_has(c[3]) {
            eprintln("{}: {}", c[3], str::from_cstr(&r.first[0]));
        }
        assert(!r.ok() && r.msg_has(c[3]), c[3]);
    }
}

// The byte count of a memory annotation: literals, constants, arithmetic and the other `usize`
// parameters; `@c.lane_access` states no range.
@test
fn memory_annotation_counts() {
    let cases: [str; 3] = [
        "    @c.reads(p, k as usize)\n    fn f(p: *const void, k: i32);\n",
        "    @c.reads(p, n + side())\n    fn f(p: *const void, n: usize);\n",
        "    @c.writes(p, n + (p as usize))\n    fn f(p: *mut void, n: usize);\n",
    ];
    for c in cases {
        let mut s = String::from_str("fn side() usize {\n    return 1;\n}\nextern \"C\" {\n");
        s.push_str(c);
        s.push_str("}\nfn main() i32 {\n    return 0;\n}\n");
        h::expect_err_msg(
            c,
            s.as_str(),
            "the byte count is a 'usize' constant or an expression over the function's other 'usize' parameters",
        );
    }
    h::expect_err_msg(
        "a range with lane access",
        "extern \"C\" {\n    @c.lane_access\n    @c.reads(p, 4)\n    fn f(p: *const void);\n}\nfn main() i32 {\n    return 0;\n}\n",
        "'@c.lane_access' states no range: it takes no '@c.reads' or '@c.writes'",
    );
}

// Register types stay out of storage the checker infers too, and two register types never share a
// symbol.
@test
fn register_types_in_inferred_storage() {
    let decl = "extern \"C\" {\n    @c.value(16, 16)\n    pub type reg_t;\n}\nfn id<T>(x: T) T {\n    return x;\n}\n";
    let bodies: [str; 7] = [
        "let a = [x, x];",
        "let t = (x, 1);",
        "let p = &x;",
        "let c = || x;",
        "let y = id(x);",
        "let z = id::<reg_t>(x);",
        "let o = Option::Some(x);",
    ];
    for b in bodies {
        let mut s = String::from_str(decl);
        s.format_into("pub fn f(x: reg_t) {{\n    {}\n}}\nfn main() i32 {{\n    return 0;\n}}\n", b);
        h::expect_err_msg(b, s.as_str(), "`reg_t` is a register type; store it through `Simd<T, N>`");
    }
    let mut e = String::from_str(decl);
    e.push_str("enum E {\n    A(reg_t),\n}\nfn main() i32 {\n    return 0;\n}\n");
    h::expect_err_msg("an enum payload", e.as_str(), "`reg_t` is a register type");
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "extern \"C\" \"stdint.h\" {\n    @c.value(8, 8)\n    pub type int64_t;\n}\nextern \"C\" \"math.h\" {\n    @c.value(8, 8)\n    pub type double_t;\n}\nfn two(a: int64_t) (int64_t, int64_t) {\n    return a, a;\n}\nfn twod(a: double_t) (double_t, double_t) {\n    return a, a;\n}\npub fn use_both(a: int64_t, d: double_t) {\n    let (x, _y) = two(a);\n    let (u, _v) = twod(d);\n    let _ = x;\n    let _ = u;\n}\nfn main() i32 {\n    return 0;\n}\n",
    );
    assert(p.compile("main.spc").ok(), "it compiles");
    assert(
        p.gen_has("main.c", "__sc_ret2__oint64_t__oint64_t") && p.gen_has("main.c", "__sc_ret2__odouble_t__odouble_t"),
        "two result structs",
    );
}
