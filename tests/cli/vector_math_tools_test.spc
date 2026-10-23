// The tools of the vector math classes (`tools/simd_math`): the coefficient generator reproduces the
// committed coefficients, and the reduced accuracy check (10^6 inputs per function) holds. Their
// results do not depend on the vector lowering (`tests/simd/simd_math_test.spc` checks that every lowering gives
// the same bits), so this file's path names no `simd_`: CI's per-level `--filter=simd_` runs skip it.
import tests::cli_harness as cli;
import std::platform::fs;

// A copy of `tools/simd_math` in a scratch project, its binary `bin` built with the release profile (the
// tools' f128 arithmetic needs inlining across units); the binary's path.
fn tool(p: &cli::Proj, root: str, bin: str) String {
    for f in ["build.toml", "gen.spc", "check.spc", "bench.spc", "real.spc", "ref.spc", "remez.spc"] {
        let mut src = String::from_str(root);
        src.format_into("/tools/simd_math/{}", f);
        assert(p.copyfile(f, src.as_str()), "the tool's source copies");
    }
    let path = format("{}/{}{}", p.dir(), bin, unsafe str::from_cstr(cli::binext()));
    let args = format("release --bin={} -o \"{}\"", bin, path.as_str());
    let r = cli::superc_env_in(p.dir(), "SC_LEAK_CHECK", "0", args.as_str());
    if !r.ok() {
        r.show();
    }
    assert(r.ok(), "the tool builds");
    return path;
}

// The repository root: the test's working directory.
fn repo_root() String {
    let real = fs::realpath(".");
    assert(real.is_ok(), "the working directory resolves");
    return real.unwrap();
}

@test(timeout = 300)
fn generator_reproduces_coefficients() {
    let root = repo_root();
    let p = cli::proj_new();
    let exe = tool(&p, root.as_str(), "simd-math-gen");
    let mut out = String::from_str(p.dir());
    out.push_str("/out");
    let _ = fs::mkdir_all(out.as_str());
    let mut args = String::from_str("--jobs=1 ");
    args.push_str(out.as_str());
    let r = cli::exe_env_in(exe.as_str(), p.dir(), "SC_LEAK_CHECK", "0", args.as_str());
    if !r.ok() {
        r.show();
    }
    assert(r.ok(), "the generator runs");
    for f in ["coeffs_f32.spc", "coeffs_f64.spc"] {
        let mut a = out.clone();
        a.format_into("/{}", f);
        let mut b = root.clone();
        b.format_into("/std/simd/math/{}", f);
        let ta = cli::read_text(a.as_str());
        let tb = cli::read_text(b.as_str());
        assert(ta.len() > 0, "the generator writes the coefficients");
        assert(ta.equals(&tb), "the generator reproduces the committed coefficients");
    }
}

// The reduced check, a third of the functions per test. The tools run one worker thread: a test of the
// parallel suite takes one CPU, so it does not slow the tests that run beside it.
fn reduced_accuracy(part: str) {
    let root = repo_root();
    let p = cli::proj_new();
    let exe = tool(&p, root.as_str(), "simd-math-check");
    // 10^6 inputs per function: half in each lane type, every special value.
    let mut args = String::from_str("--jobs=1 --n=500000 --sample32=500000 --part=");
    args.push_str(part);
    let r = cli::exe_env_in(exe.as_str(), p.dir(), "SC_LEAK_CHECK", "0", args.as_str());
    if !r.ok() {
        r.show();
    }
    assert(r.ok(), "a result is over its class bound or a special value is wrong");
}

@test(timeout = 300)
fn reduced_accuracy_0() {
    reduced_accuracy("0/3");
}

@test(timeout = 300)
fn reduced_accuracy_1() {
    reduced_accuracy("1/3");
}

@test(timeout = 300)
fn reduced_accuracy_2() {
    reduced_accuracy("2/3");
}
