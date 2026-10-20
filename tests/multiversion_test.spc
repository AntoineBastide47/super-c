// Per-function CPU features: a function's `@target_feature` set adds to the build's for its own calls,
// pointer coercions and vector code; a use beyond the caller's set needs `unsafe` (an error on wasm32,
// where features are per build); such a function is no closure-bound value and is not inlined into a
// caller that lacks its features. Function addresses cast to `usize` and back. `detect::dispatch`
// selects one function per process by the machine's features; the x86 query's decision on fixed
// register values.
import tests::harness as h;
import tests::cli_harness as cli;
import build_system::build as bsys;
import driver_shim as shim;
import std::cpu;
import sc_cpu;

const V3: str = "import std::cpu;\n@arch(x86_64)\n@target_feature(cpu::X86_64_V3)\nfn wide(a: i32) i32 {\n    return a + 1;\n}\n";

// `src` (after `V3`) built for x86-64 Linux with `flags`, C emitted only: the result.
fn x86(p: &cli::Proj, src: str, flags: str) cli::CliResult {
    p.mkfile("main.spc", format("{}{}", V3, src).as_str());
    return p.compile_flags(format("--arch=x86_64 --target=linux {}", flags).as_str(), "main.spc");
}

const NEED: str = "`wide` needs `+sse3,+ssse3,+sse4.1,+sse4.2,+popcnt,+cx16,+lahf-sahf,+avx,+avx2,+fma,+bmi1,+bmi2,+f16c,+lzcnt,+movbe`: use it in a function whose `@target_feature` enables it, or inside `unsafe` after a run-time check (`std::cpu::detect::has`)";

// A call or pointer coercion beyond the caller's features needs `unsafe`; inside a function whose set
// holds them, it needs nothing, and `unsafe` there is reported as unnecessary.
@test
fn uses_beyond_the_callers_features_need_unsafe() {
    let p = cli::proj_new();
    // A call, and a pointer coercion.
    let mut uses = cli::Batch::new(V3, "");
    uses.flags = String::from_str("--arch=x86_64 --target=linux");
    uses.add_at(
        "a call",
        "fn main(args: Vector<str>) i32 {\n    return wide(args.len() as i32) - 2;\n}\n",
        NEED,
        "8:12",
    );
    uses.add("a pointer coercion", "fn main() i32 {\n    let f: fn(i32) i32 = wide;\n    return f(0) - 1;\n}\n", NEED);
    p.expect_batch(uses);
    let ok = x86(
        &p,
        "@arch(x86_64)\n@target_feature(cpu::X86_64_V4)\nfn caller(a: i32) i32 {\n    let f: fn(i32) i32 = wide;\n    return wide(a) + f(a);\n}\nfn main(args: Vector<str>) i32 {\n    let f: fn(i32) i32 = unsafe wide;\n    return unsafe wide(0) + f(0) + unsafe caller(args.len() as i32) - 6;\n}\n",
        "",
    );
    assert(ok.ok(), "inside the features, and inside `unsafe`");
    let lint = p.run_raw(format("lint --arch=x86_64 --target=linux \"{}/main.spc\"", p.dir()).as_str());
    assert(!lint.out_has("unnecessary 'unsafe'"), "each `unsafe` is needed");
    p.mkfile(
        "main.spc",
        format(
            "{}@arch(x86_64)\n@target_feature(cpu::X86_64_V3)\nfn caller(a: i32) i32 {{\n    return unsafe wide(a);\n}}\nfn main() i32 {{\n    return 0;\n}}\n",
            V3,
        ).as_str(),
    );
    let l2 = p.run_raw(format("lint --arch=x86_64 --target=linux \"{}/main.spc\"", p.dir()).as_str());
    assert(l2.out_has("unnecessary 'unsafe': nothing inside requires it"), "the function's own features");
    // A build whose features hold the function's needs no `unsafe`.
    let b = x86(&p, "fn main() i32 {\n    return wide(0) - 1;\n}\n", "--target-cpu=x86-64-v3");
    assert(b.ok(), "the build's features");
}

// Such a function is no value of a closure bound: the bound's caller runs it without the check. A
// function-pointer parameter takes it.
@test
fn closure_bounds_reject_feature_functions() {
    let p = cli::proj_new();
    let mut b = cli::Batch::new(V3, "");
    b.flags = String::from_str("--arch=x86_64 --target=linux");
    b.add(
        "a closure bound",
        "fn apply<F: fn(i32) i32>(f: F, a: i32) i32 {\n    return f(a);\n}\nfn main() i32 {\n    return unsafe apply(wide, 0) - 1;\n}\n",
        "`wide` needs CPU features: it is no value of a closure bound (`F: fn(..)`); pass a function pointer `fn(..)` instead",
    );
    // By its type: through a local, or as an `unsafe` operand.
    let by_type = "fn apply<F: fn(i32) i32>(f: F, a: i32) i32 {\n    return f(a);\n}\n@arch(x86_64)\n@target_feature(cpu::X86_64_V3)\nfn inner(a: i32) i32 {\n    let g = wide;\n    return apply(g, a);\n}\nfn main() i32 {\n    return apply(unsafe wide, 0) + unsafe inner(0) - 2;\n}\n";
    b.add("through a local", by_type, "`g` needs CPU features");
    b.add("as an `unsafe` operand", by_type, "`unsafe wide` needs CPU features");
    b.add(
        "an export",
        "@arch(x86_64)\n@target_feature([cpu::Feature::Avx2])\n@c.export(\"k\")\npub fn k() {}\nfn main() i32 {\n    return 0;\n}\n",
        "a '@c.export' function cannot need CPU features",
    );
    p.expect_batch(b);
    let ok = x86(
        &p,
        "fn apply(f: fn(i32) i32, a: i32) i32 {\n    return f(a);\n}\nfn main() i32 {\n    return apply(unsafe wide, 0) - 1;\n}\n",
        "",
    );
    assert(ok.ok(), "a function pointer");
}

// The C of such a function carries its target attribute; the release inliner keeps its call in a
// baseline caller, and inlines a function without features.
@test
fn feature_functions_keep_their_calls() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        format(
            "{}fn narrow(a: i32) i32 {{\n    return a + 2;\n}}\nfn main(args: Vector<str>) i32 {{\n    return unsafe wide(args.len() as i32) + narrow(args.len() as i32) - 5;\n}}\n",
            V3,
        ).as_str(),
    );
    // The C alone: a C compiler for another instruction set rejects the x86 target attribute.
    let root = p.dir();
    let _ = p.run_raw(
        format("build \"{}/main.spc\" -o \"{}/app\" --profile=release --arch=x86_64 --target=linux", root, root).as_str(),
    );
    let c = cli::read_text(format("{}/build/release/raw/main.c", p.dir()).as_str());
    assert(
        c.contains(
            "__attribute__((target(\"sse3,ssse3,sse4.1,sse4.2,popcnt,cx16,sahf,avx,avx2,fma,bmi,bmi2,f16c,lzcnt,movbe\"))) int32_t wide(",
        ),
        "the C target",
    );
    let m = c.as_str().find("int32_t __sc_user_main(");
    assert(m > 0, "main");
    let body = c.as_str().slice(m as usize, c.len());
    assert(body.contains("wide(") && !body.contains("narrow("), "wide is called, narrow inlined");
    // An AArch64 function's set renders in clang's spelling and GCC's (an architecture base and the
    // extensions beyond it).
    p.mkfile(
        "main.spc",
        "import std::cpu;\n@arch(aarch64)\n@target_feature([cpu::Feature::I8mm])\nfn mm(a: i32) i32 {\n    return a;\n}\nfn main() i32 {\n    return unsafe mm(0);\n}\n",
    );
    assert(p.compile_flags("--arch=aarch64 --target=linux", "main.spc").ok(), "aarch64");
    let a = cli::read_text(format("{}/build/debug/raw/main.c", p.dir()).as_str());
    assert(
        a.contains("SC_TGT_A64(\"+rdm+i8mm+crc+lse\", \"arch=armv8.2-a+i8mm\")))) int32_t mm("),
        "the aarch64 target",
    );
}

// A feature function's call of a function with vector code runs a copy of it compiled with the caller's
// features (`<name>__fs<features>`, in the module's instance file): 256-bit FMA there, the 128-bit
// original elsewhere. A function without vector code keeps its one copy.
@test
fn feature_functions_compile_their_vector_callees_with_their_features() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import std::cpu;\nimport std::simd;\n\n@c.noinline\nfn kern(c: []mut f32, a: []f32) {\n    let mut i: usize = 0;\n    while i + 8 <= a.len() {\n        simd::store(c, i, simd::load::<f32, 8>(a, i).fma(simd::load::<f32, 8>(a, i), simd::load::<f32, 8>(c, i)));\n        i += 8;\n    }\n}\n\n// 128-bit lanes: the copy declares the original's vector type.\n@c.noinline\nfn kern4(c: []mut f32, a: []f32) {\n    simd::store(c, 0, simd::load::<f32, 4>(a, 0) + simd::load::<f32, 4>(c, 0));\n}\n\n@c.noinline\nfn plain(a: i32) i32 {\n    return a * 3;\n}\n\n@arch(x86_64)\n@target_feature([cpu::Feature::Fma])\nfn fast(c: []mut f32, a: []f32, x: i32) i32 {\n    kern(c, a);\n    kern4(c, a);\n    return plain(x);\n}\n\nfn main(args: Vector<str>) i32 {\n    let a: [f32; 8] = [1.0; 8];\n    let mut c: [f32; 8] = [0.0; 8];\n    kern(c, a);\n    kern4(c, a);\n    return unsafe fast(c, a, args.len() as i32) + plain(0) - 3;\n}\n",
    );
    let root = p.dir();
    let _ = p.run_raw(
        format(
            "build \"{}/main.spc\" -o \"{}/app\" --profile=release --arch=x86_64 --target=linux --jobs=1",
            root,
            root,
        ).as_str(),
    );
    let c = cli::read_text(format("{}/build/release/raw/main.c", root).as_str());
    let i = cli::read_text(format("{}/build/release/raw/main__inst.c", root).as_str());
    // One emitter renders both files (`--jobs=1`): the copies' file includes the vector type the
    // original declared first.
    assert(i.contains("__sc_v4_f32 _") && i.contains("#include \"__sc_t/__sc_v4_f32.h\""), "the copies' type headers");
    let at = i.as_str().find(
        "__attribute__((noinline, target(\"sse3,ssse3,sse4.1,sse4.2,popcnt,avx,fma\"))) void main__kern__fs",
    );
    assert(at >= 0, "the copy carries the caller's target");
    assert(i.as_str().slice(at as usize, i.len()).contains("__sc_si_x86_64__fma_f32x8("), "the copy's vectors");
    assert(
        c.contains("main__kern__fs") && c.contains("__sc_si_x86_64__load_f32x4(") && !c.contains("f32x8"),
        "the original's vectors",
    );
    assert(!c.contains("plain__fs") && !i.contains("plain__fs"), "no copy without vector code");
}

// The run-time choice: an x86_64 function with vector code opens with a call of its copy at each
// `--simd-dispatch` level the CPU has (`__sc_simd_lvl()`, the forward header), the highest first; a
// function without vector code has none, and `off`, another instruction set, or a `debug` build or a
// script without `--profile` (no level set) none at all.
@test
fn vector_functions_choose_their_copy_at_run_time() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import std::simd;\n\n@c.noinline\nfn kern(c: []mut f32, a: []f32) {\n    let mut i: usize = 0;\n    while i + 8 <= a.len() {\n        simd::store(c, i, simd::load::<f32, 8>(a, i).fma(simd::load::<f32, 8>(a, i), simd::load::<f32, 8>(c, i)));\n        i += 8;\n    }\n}\n\n@c.noinline\nfn plain(a: i32) i32 {\n    return a * 3;\n}\n\nfn main(args: Vector<str>) i32 {\n    let a: [f32; 8] = [1.0; 8];\n    let mut c: [f32; 8] = [0.0; 8];\n    kern(c, a);\n    return plain(args.len() as i32) - 3;\n}\n",
    );
    let root = p.dir();
    let mut texts = Vector::<String>::new();
    // The profile directory, then the flags (a script without `--profile` builds into `debug`).
    let profs: [str; 7] = ["release", "release", "release", "release", "debug", "debug", "debug"];
    let flags: [str; 7] = [
        "--profile=release --arch=x86_64 --target=linux",
        "--profile=release --arch=x86_64 --target=linux --simd-dispatch=x86-64-v3,x86-64-v4",
        "--profile=release --arch=x86_64 --target=linux --simd-dispatch=off",
        "--profile=release --arch=aarch64 --target=linux",
        "--profile=debug --arch=x86_64 --target=linux",
        "--profile=debug --arch=x86_64 --target=linux --simd-dispatch=x86-64-v3",
        "--arch=x86_64 --target=linux",
    ];
    for i in 0..7 {
        bsys::rm_rf(format("{}/build", root).as_str());
        let _ = p.run_raw(format("build \"{}/main.spc\" -o \"{}/app\" {}", root, root, unsafe flags[i]).as_str());
        let raw = format("{}/build/{}/raw", root, unsafe profs[i]);
        let mut t = cli::read_text(format("{}/main.c", raw).as_str());
        t.push_str(cli::read_text(format("{}/main__inst.c", raw).as_str()).as_str());
        t.push_str(cli::read_text(format("{}/__sc_fwd.h", raw).as_str()).as_str());
        texts.push(t);
    }
    let v3 = "__attribute__((noinline, target(\"sse3,ssse3,sse4.1,sse4.2,popcnt,cx16,sahf,avx,avx2,fma,bmi,bmi2,f16c,lzcnt,movbe\"))) void main__kern__fs";
    let d = texts[0].as_str();
    assert(d.contains("  if (__sc_simd_lvl() >= 1) { main__kern__fs") && !d.contains(">= 2"), "the default level");
    assert(d.contains(v3) && d.contains("__sc_simd_lvl_init(void)"), "the copy and the level");
    assert(d.find("int32_t main__plain(") > 0 && !d.contains("main__plain__fs"), "no copy without vector code");
    let two = texts[1].as_str();
    assert(
        two.find("__sc_simd_lvl() >= 2") > 0 && two.find("__sc_simd_lvl() >= 2") < two.find("__sc_simd_lvl() >= 1"),
        "the highest first",
    );
    assert(!texts[2].contains("__sc_simd_lvl") && !texts[3].contains("__sc_simd_lvl"), "off, and aarch64");
    assert(!texts[4].contains("__sc_simd_lvl") && texts[5].contains(v3), "debug: off unless set");
    assert(texts[6].contains("main__kern(") && !texts[6].contains("__sc_simd_lvl"), "no profile: off");
    let bad = p.run_raw(format("build \"{}/main.spc\" -o \"{}/app\" --simd-dispatch=x86-64-v9", root, root).as_str());
    assert(!bad.ok() && bad.out_has("simd dispatch: unknown target CPU 'x86-64-v9'"), "a bad level");
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\nsimd-dispatch = \"x86-64-v9\"\n");
    let man = cli::superc_env_in(root, "SC_NO_CACHE", "1", "build");
    assert(!man.ok() && man.out_has("simd dispatch: unknown target CPU 'x86-64-v9'"), "a bad manifest level");
}

// A function's address casts to `usize`, and back inside `unsafe`; a generic cast to a type that is no
// function pointer fails for that instance.
fn function_addresses_cast_to_usize_and_back(b: &mut h::ExitBatch) {
    b.add(
        "a round trip",
        "fn add1(a: i32) i32 {\n    return a + 1;\n}\nfn main() i32 {\n    let f: fn(i32) i32 = add1;\n    let x = add1 as usize;\n    let y = f as usize;\n    let g = unsafe (x as fn(i32) i32);\n    return g(41) - 42 + pick(x == y && x != 0, 0, 1);\n}\nfn pick(c: bool, a: i32, b: i32) i32 {\n    if c {\n        return a;\n    }\n    return b;\n}\n",
        0,
    );
    // `FnPtr` through a `where` predicate.
    b.add(
        "a where predicate",
        "fn back<F>(u: usize) F where F: FnPtr {\n    return unsafe (u as F);\n}\nfn one() i32 {\n    return 1;\n}\nfn main() i32 {\n    let f = back::<fn() i32>(one as usize);\n    return f() - 1;\n}\n",
        0,
    );
}

@test
fn function_address_casts_are_checked() {
    h::expect_err_msg(
        "back without unsafe",
        "fn add1(a: i32) i32 {\n    return a + 1;\n}\nfn main() i32 {\n    let g = (add1 as usize) as fn(i32) i32;\n    return g(0) - 1;\n}\n",
        "casting an address to a function pointer",
    );
    // The build checks a cast in a generic body per instance, and the dispatch table's types.
    let mut errs = cli::Batch::new("", "");
    errs.add(
        "a closure bound is no function pointer",
        "import std::cpu;\nimport std::cpu::detect as detect;\nstatic mut D: detect::Dispatch = detect::Dispatch::new();\nfn main() i32 {\n    let k = 1;\n    let c = fn() i32 { return k; };\n    let f = unsafe detect::dispatch(&mut unsafe D, [(cpu::Feature::Neon, c)], c);\n    return f() - 1;\n}\n",
        "FnPtr",
    );
    errs.add(
        "a generic cast to a struct",
        "struct S {\n    pub v: usize,\n}\nfn to<T>(x: usize) T {\n    return unsafe (x as T);\n}\nfn main() i32 {\n    let s = to::<S>(0);\n    return s.v as i32;\n}\n",
        "invalid cast from 'usize' to 'S'",
    );
    h::expect_err_msg(
        "a number as a reference",
        "fn main() i32 {\n    let r = 16usize as &i32;\n    return 0;\n}\n",
        "a reference never comes from a number",
    );
    errs.add(
        "a generic cast of a number to a reference",
        "fn conv<T>(x: usize) T {\n    return x as T;\n}\nfn main() i32 {\n    let r = conv::<&i32>(16);\n    return 0;\n}\n",
        "invalid cast from 'usize' to '&i32'",
    );
    h::expect_err_msg(
        "a closure as an address",
        "fn main(args: Vector<str>) i32 {\n    let k = args.len();\n    let c = fn(x: usize) usize { return x + k; };\n    let u = c as usize;\n    return (u - u) as i32;\n}\n",
        "invalid cast from",
    );
    h::expect_build_errs(errs);
}

// The exit-code cases of the provider functions above, one program per group (`h::ExitBatch`).
@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    function_addresses_cast_to_usize_and_back(&mut b);
    b.run();
}

// A dispatch row whose feature does not imply its function's features is reported: the row would run
// the function on a machine without them.
@test
fn dispatch_rows_cover_their_functions() {
    let p = cli::proj_new();
    let r = x86(
        &p,
        "import std::cpu::detect as detect;\nstatic mut D: detect::Dispatch = detect::Dispatch::new();\nfn base(x: i32) i32 {\n    return x;\n}\n@arch(x86_64)\n@target_feature([cpu::Feature::Avx2])\nfn a2(a: i32) i32 {\n    return a;\n}\nfn main() i32 {\n    let f = unsafe detect::dispatch::<fn(i32) i32, 2>(&mut unsafe D, [(cpu::Feature::Avx2, wide), (cpu::Feature::Avx2, a2)], base);\n    return f(0) - 1;\n}\n",
        "",
    );
    assert(r.ok(), "a warning");
    assert(
        r.out_has("the row's feature `avx2` does not imply `+cx16,+lahf-sahf,+fma,+bmi1,+bmi2,+f16c,+lzcnt,+movbe`"),
        "the level's row",
    );
    let o = unsafe str::from_cstr(r.out);
    let first = o.find("does not imply");
    assert(
        first >= 0 && o.slice(first as usize + 1, o.len()).find("does not imply") < 0,
        "one row: the covered one passes",
    );
}

// `--target-cpu` names an x86-64 level of an x86_64 build; the last flag wins.
@test
fn target_cpu_is_a_level() {
    let p = cli::proj_new();
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let bad = p.compile_flags("--arch=x86_64 --target=linux --target-cpu=avx2", "main.spc");
    assert(!bad.ok() && bad.out_has("unknown target CPU 'avx2'"), "a feature is no level");
    let other = p.compile_flags("--arch=aarch64 --target=linux --target-cpu=x86-64-v3", "main.spc");
    assert(
        !other.ok() && other.out_has("target CPU 'x86-64-v3' is an x86_64 level; the build is for aarch64"),
        "another set",
    );
    let last = x86(&p, "fn main() i32 {\n    return wide(0) - 1;\n}\n", "--target-cpu=x86-64-v3 --target-cpu=x86-64");
    assert(!last.ok() && last.out_has("`wide` needs"), "the last flag, not their union");
}

const DISPATCH: str = M"(import std::cpu;
import std::cpu::detect as detect;
import std::parallel::thread as thread;
import sc_cpu;

static mut D: detect::Dispatch = detect::Dispatch::new();
static mut A: i32 = -1;

fn base(x: i32) i32 {
    return x;
}

@arch(x86_64)
@target_feature([cpu::Feature::Avx2])
fn hi(x: i32) i32 {
    return x + 2;
}

@arch(x86_64)
@target_feature([cpu::Feature::Sse3])
fn lo(x: i32) i32 {
    return x + 1;
}

@arch(x86_64)
const HI: cpu::Feature = cpu::Feature::Avx2;
@arch(x86_64)
const LO: cpu::Feature = cpu::Feature::Sse3;

@arch(aarch64)
@target_feature([cpu::Feature::I8mm])
fn hi(x: i32) i32 {
    return x + 2;
}

@arch(aarch64)
@target_feature([cpu::Feature::Dotprod])
fn lo(x: i32) i32 {
    return x + 1;
}

@arch(aarch64)
const HI: cpu::Feature = cpu::Feature::I8mm;
@arch(aarch64)
const LO: cpu::Feature = cpu::Feature::Dotprod;

fn chosen() fn(i32) i32 {
    return unsafe detect::dispatch::<fn(i32) i32, 2>(&mut unsafe D, [(HI, hi), (LO, lo)], base);
}

fn main() i32 {
    let t = thread::spawn(fn() {
        unsafe A = chosen()(0);
    });
    let a = chosen()(0);
    t.join();
    let want = if detect::has(HI) {
        2;
    } else if detect::has(LO) {
        1;
    } else {
        0;
    };
    print("{}", a);
    // One detection, by the constructor; the same choice on each call and thread.
    return if a == want && unsafe A == a && chosen()(0) == a && sc_cpu::sc_cpu_query_count() == 1 {
        0;
    } else {
        1;
    };
}
)";

// `DISPATCH` built with `flags`, and with the build's environment variable `key` set to `val` when
// `key` is not empty: its project, and whether it built.
fn dispatch_build(flags: str, key: str, val: str) (cli::Proj, bool) {
    let p = cli::proj_new();
    p.mkfile("main.spc", DISPATCH);
    let root = p.dir();
    let args = format("build \"{}/main.spc\" -o \"{}/app\" {}", root, root, flags);
    let b = if key.len() == 0 {
        p.run_raw(args.as_str());
    } else {
        cli::superc_env_in(root, key, val, args.as_str());
    };
    if !b.ok() {
        b.show();
    }
    let built = b.exit == 0;
    return p, built;
}

// A run of the build `p` of `dispatch_build` (`built` when it built) with environment `env`: its
// output, "fail" when the build or the run fails.
fn dispatch_exec(p: &cli::Proj, built: bool, env: str) String {
    if !built {
        return String::from_str("fail");
    }
    let root = p.dir();
    let mut cmd = format("\"{}/app\"", root);
    let mut out = format("{}/.out", root);
    let mut err = format("{}/.err", root);
    let rc = cli::run_with(cmd.cstr(), null, out.cstr(), err.cstr(), env);
    let e = cli::read_text(err.as_str());
    if rc != 0 || e.contains("ThreadSanitizer") {
        eprintln("[{}]: exit {}: {}", env, rc, e.as_str());
        return String::from_str("fail");
    }
    return cli::read_text(out.as_str());
}

// Build `DISPATCH` with `flags` (and the build variable `key`=`val`) and run it once: its output,
// "fail" when it fails.
fn dispatch_run(flags: str, key: str, val: str) String {
    let (p, built) = dispatch_build(flags, key, val);
    return dispatch_exec(&p, built, "");
}

// The first table entry whose feature the machine has, else the fallback; one choice per process,
// with no race report when two threads make the first call; the same under link-time optimization.
@test
fn dispatch_chooses_once_in_table_order() {
    let a = unsafe shim::sc_host_arch();
    if cli::on_windows() || cli::on_wasm() || h::simd_lane() || a > 1 {
        return;
    }
    // One build: the masked features (`SC_CPU_OFF`) act on its runs.
    let (p, built) = dispatch_build("", "", "");
    let all = dispatch_exec(&p, built, "");
    assert(all.as_str() != "fail", "the machine's choice");
    // The masked features: the build's own set stays.
    let none = dispatch_exec(&p, built, "SC_CPU_OFF=0xFFFFFFFFFFFFFFFF");
    // macOS x86_64 builds have `sse3`, so there the `lo` row stays.
    let mac = unsafe shim::sc_host_platform() == 1;
    assert(none.as_str() != "fail", "the run without features");
    assert(a == 1 || none.as_str() == pick(mac, "1", "0"), "the fallback");
    let hi = pick(a == 0, cpu::Feature::Avx2, cpu::Feature::I8mm) as u64;
    let off = dispatch_exec(&p, built, format("SC_CPU_OFF={}", 1u64 << hi).as_str());
    assert(off.as_str() != "fail", "the run without the first entry's feature");
    assert(off.as_str() != "2", "the next entry");
    assert(dispatch_run("--profile=race", "", "").as_str() == all.as_str(), "no race");
    assert(dispatch_run("--profile=release", "", "").as_str() == all.as_str(), "lto");
    // `SC_LTO` is a variable of the build, not of the run.
    assert(dispatch_run("--profile=release", "SC_LTO", "thin").as_str() == all.as_str(), "thin lto");
}

// The steady state of a dispatching call inlines: one acquire load (aarch64 `ldar` or `ldapr`; on
// x86-64 a plain load) and the indirect call, with no fence; the first call is an outlined direct call.
@test
fn dispatch_needs_no_fence() {
    // Each unit alone, as a large program builds: in one unit the C compiler sees the target and may
    // turn the indirect call into a compare and a branch.
    let _unit = cli::set_env("SC_UNITY_MAX", "0");
    let a = unsafe shim::sc_host_arch();
    if cli::on_wasm() || h::simd_lane() || a > 1 {
        return;
    }
    let src = "import std::cpu;\nimport std::cpu::detect as detect;\nstatic mut D: detect::Dispatch = detect::Dispatch::new();\nfn one(x: i32) i32 {\n    return x + 1;\n}\n@c.noinline\nfn run(x: i32) i32 {\n    return unsafe detect::dispatch::<fn(i32) i32, 1>(&mut unsafe D, [(cpu::Feature::Simd128, one)], one)(x);\n}\nfn main(args: Vector<str>) i32 {\n    return run(args.len() as i32) - 2;\n}\n";
    if a == 1 {
        h::expect_asm("aarch64", src, ["--profile=release"], "main__run", ["lda", "blr"], ["dmb"]);
    } else {
        h::expect_asm("x86-64", src, ["--profile=release"], "main__run", ["call"], ["mfence", "lock"]);
    }
}

const fn pick<T>(c: bool, a: T, b: T) T {
    if c {
        return a;
    }
    return b;
}

// The x86 query's decision: AVX needs OSXSAVE and the XCR0 SSE and AVX state bits; AVX-512 the opmask
// and ZMM state bits too, or the OS's own report (macOS); AVX10 its version.
@test
fn x86_decision_needs_the_register_state() {
    let bit = fn(w: u64, f: cpu::Feature) bool {
        return (w >> f as u64 & 1) != 0;
    };
    let mut r: [u32; 7] = [0; 7];
    r[0] = 1 << 28 | 1 << 27 | 1 << 20; // avx, osxsave, sse4.2
    r[1] = 1 << 5 | 1 << 16; // avx2, avx512f
    let w0 = unsafe sc_cpu::sc_cpu_x86_decide(&r[0], 0, 0);
    assert(bit(w0, cpu::Feature::Sse2) && bit(w0, cpu::Feature::Sse42) && !bit(w0, cpu::Feature::Avx), "no state");
    let w1 = unsafe sc_cpu::sc_cpu_x86_decide(&r[0], 6, 0);
    assert(
        bit(w1, cpu::Feature::Avx) && bit(w1, cpu::Feature::Avx2) && !bit(w1, cpu::Feature::Avx512f),
        "the AVX state",
    );
    assert(bit(unsafe sc_cpu::sc_cpu_x86_decide(&r[0], 0xE6, 0), cpu::Feature::Avx512f), "the ZMM state");
    assert(bit(unsafe sc_cpu::sc_cpu_x86_decide(&r[0], 6, 1), cpu::Feature::Avx512f), "the OS's report");
    r[0] = 1 << 28 | 1 << 20;
    assert(!bit(unsafe sc_cpu::sc_cpu_x86_decide(&r[0], 0xE6, 1), cpu::Feature::Avx), "no OSXSAVE");
    r[0] = 1 << 28 | 1 << 27;
    r[4] = 1 << 19;
    r[6] = 1 << 18 | 2;
    let w2 = unsafe sc_cpu::sc_cpu_x86_decide(&r[0], 0xE6, 0);
    assert(bit(w2, cpu::Feature::Avx101) && bit(w2, cpu::Feature::Avx102), "AVX10.2");
    r[6] = 2;
    assert(!bit(unsafe sc_cpu::sc_cpu_x86_decide(&r[0], 0xE6, 0), cpu::Feature::Avx101), "no 512-bit form");
}

// On an x86-64 host: the detected set holds the baseline, an x86-64-v2 machine reports `cx16`, and
// `has_level` agrees with the level's members.
@test
fn x86_detection_reports_the_machine() {
    if unsafe shim::sc_host_arch() != 0 || h::simd_lane() {
        return;
    }
    h::expect_exit(
        "x86 detection",
        "import std::cpu;\nimport std::cpu::detect as detect;\nfn main() i32 {\n    let d = detect::detected();\n    let v2 = d.has(cpu::Feature::Sse42) && d.has(cpu::Feature::Popcnt);\n    let mut all = true;\n    for f in cpu::X86_64_V3 {\n        all = all && detect::has(f);\n    }\n    return pick(d.has(cpu::Feature::Sse2) && (!v2 || d.has(cpu::Feature::Cx16)) && detect::has_level(cpu::Level::V3) == all, 0, 1);\n}\nfn pick(c: bool, a: i32, b: i32) i32 {\n    if c {\n        return a;\n    }\n    return b;\n}\n",
        0,
    );
}
