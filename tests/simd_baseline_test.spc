// The C kernels of bench/simd_baseline give their scalar loops' results on every instruction set the host
// runs. The kernels come prebuilt (kernels.sh): this test compiles the host's C files into the library the
// module links, `build/simd_baseline/<arch>/libsimd_baseline.a`, under a scratch project, and builds and
// runs a program over the module there, so the suite itself links no C kernel.
import tests::cli_harness as cli;
import std::platform::fs;

@test(timeout = 300)
fn simd_baseline_kernels_match_the_scalar_loops() {
    let arch = if ARCH == Arch::AArch64 {
        "aarch64";
    } else {
        "x86_64";
    };
    let srcs: []str = if ARCH == Arch::AArch64 {
        ["neon"];
    } else {
        ["sse2", "avx2", "avx512"];
    };
    let dir = fs::realpath("bench/simd_baseline").unwrap();
    let p = cli::proj_new();
    let root = p.dir();
    for f in ["kernels.spc", "sb.h", "sse2.h", "avx2.h", "avx512.h", "neon.h", "simd128.h"] {
        assert(p.copyfile(format("src/{}", f).as_str(), format("{}/{}", dir.as_str(), f).as_str()), "the module copies");
    }
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        "import kernels;\n\nfn main() i32 {\n    let m = kernels::first_mismatch();\n    if m.len() != 0 {\n        eprintln(\"{}\", m.as_str());\n        return 1;\n    }\n    return 0;\n}\n",
    );
    let out = format("{}/build/simd_baseline/{}", root, arch);
    assert(fs::mkdir_all(out.as_str()).is_ok(), "the library directory");
    let ar_env = stdlib::getenv("AR");
    let ar = if ar_env != null && unsafe *ar_env != 0 as char {
        unsafe str::from_cstr(ar_env);
    } else {
        "ar";
    };
    let mut arc = format("{} rcs \"{}/libsimd_baseline.a\"", ar, out.as_str());
    for s in srcs {
        let mut c = format(
            "{} -std=c11 -O2 -funsigned-char -ffp-contract=off -c \"{}/{}.c\" -o \"{}/{}.o\"",
            unsafe str::from_cstr(cli::cc_name()),
            dir.as_str(),
            s,
            out.as_str(),
            s,
        );
        assert(cli::run_quiet(c.cstr()) == 0, "a C kernel compiles");
        arc.format_into(" \"{}/{}.o\"", out.as_str(), s);
    }
    assert(cli::run_quiet(arc.cstr()) == 0, "the kernels archive");
    let b = cli::superc_in(root, "build");
    if !b.ok() {
        b.show();
    }
    assert(b.ok(), "the program builds against the library");
    let r = cli::exe_env_in(
        format("{}/app{}", root, unsafe str::from_cstr(cli::binext())).as_str(),
        root,
        "SC_LEAK_CHECK",
        "fatal",
        "",
    );
    if r.exit != 0 {
        r.show();
    }
    assert(r.exit == 0, "every C kernel gives its scalar loop's result");
}
