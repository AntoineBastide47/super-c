// The optimization levels and code-generation flags on the command line (`-O<level>`, `-f<flag>`,
// `-fno-<flag>`): each reaches the build, changes its code, and keeps what the program prints.
import tests::cli_harness as cli;
import tests::platform::platform_harness as ph;

const E: str = "SC_NO_EMIT_CACHE";

// A program each flag changes: a counted loop (unrolling), a loop with bounds checks (versioning), a loop
// with a branch on a parameter (unswitching), a small and a mid-sized callee (inlining), leaf functions
// (the frame pointer) and slots (the stack protector).
const PROGRAM: str = M"(import stdio;

@noinline
fn sum4(a: []i64) i64 {
    let mut s: i64 = 0;
    for i in 0..4usize {
        s += a[i] * (i as i64 + 1);
    }
    return s;
}

@noinline
fn dot(a: []i64, b: []i64, n: usize) i64 {
    let mut s: i64 = 0;
    for i in 0..n {
        s += a[i] * b[i];
    }
    return s;
}

@noinline
fn scale(a: []mut i64, n: usize, neg: bool) {
    for i in 0..n {
        if neg {
            a[i] = -a[i];
        } else {
            a[i] = a[i] * 3;
        }
    }
}

fn tiny(x: i64) i64 {
    return x + 1;
}

fn mid(x: i64, y: i64) i64 {
    let a = x * 7 + y;
    let b = a ^ (x >> 3);
    let c = b * 11 - y * 5;
    let d = c + (a & 1023);
    return d * 3 + (b | 7) - (c >> 2);
}

fn main() i32 {
    let mut a: [i64; 5] = [1, 2, 3, 4, 5];
    let b: [i64; 5] = [5, 4, 3, 2, 1];
    scale(a, 5, true);
    scale(a, 3, false);
    println("{} {} {} {}", sum4(a), dot(a, b, 5), tiny(a[4]), mid(a[0], a[1]));
    return 0;
}
)";

// Build `main.spc` of project `p` with `flags` into `<dir>/prog` (one file name: a Mach-O signature
// holds it); its bytes and what it prints.
fn built(p: &cli::Proj, flags: str, dir: str) (String, String) {
    let root = p.dir();
    p.mkfile(format("{}/.keep", dir).as_str(), "");
    let b = cli::superc_env_in(root, E, "1", format("build {} main.spc -o {}/prog", flags, dir).as_str());
    assert(b.ok(), flags);
    let exe = format("{}/{}/prog{}", root, dir, unsafe str::from_cstr(cli::binext()));
    let r = cli::exe_env_in(exe.as_str(), root, E, "1", "");
    assert(r.ok(), flags);
    return ph::read_text(exe.as_str()), String::from_str(unsafe str::from_cstr(r.out));
}

// Each level builds its own binary; each one prints the same. The levels and flags reach a build without
// a manifest.
@test
fn each_level_builds_its_own_code() {
    let p = cli::proj_new();
    p.mkfile("main.spc", PROGRAM);
    let levels: []str = ["-O0", "-O1", "-O2", "-O3", "-Os", "-Oz"];
    let (_, want) = built(&p, "-O0", "b");
    assert(want.as_str().contains("-58 -79 -4 3891"), want.as_str());
    let mut bins = Vector::<String>::new();
    for k in 0..levels.len() {
        let (bin, out) = built(&p, levels[k], format("b{}", k).as_str());
        assert(out.as_str() == want.as_str(), levels[k]);
        bins.push(bin);
    }
    for k in 1..bins.len() {
        assert(bins.at(k).as_str() != bins.at(k - 1).as_str(), levels[k]);
    }
}

// At `-O3`, turning one flag off (or the protector on) changes the binary and keeps what it prints.
@test
fn each_flag_changes_the_code() {
    let p = cli::proj_new();
    p.mkfile("main.spc", PROGRAM);
    let (base, want) = built(&p, "-O3", "base");
    let flags: []str = [
        "-fno-omit-frame-pointer",
        "-fno-inline",
        "-fno-inline-functions",
        "-fno-unroll-loops",
        "-fno-unswitch-loops",
        "-fno-version-loops-for-bounds",
        "-fstack-protector-strong",
    ];
    for k in 0..flags.len() {
        let (bin, out) = built(&p, format("-O3 {}", flags[k]).as_str(), format("f{}", k).as_str());
        assert(out.as_str() == want.as_str(), flags[k]);
        assert(bin.as_str() != base.as_str(), flags[k]);
    }
    // The last flag wins: on, then off again, is the base.
    let (same, _) = built(&p, "-O3 -fno-unroll-loops -funroll-loops", "again");
    assert(same.as_str() == base.as_str(), "-funroll-loops after -fno-unroll-loops");
}

// A function whose stack memory overflows past its slots stops at its return under a stack protector;
// without an overflow it runs as before.
@test
fn the_stack_protector_stops_an_overflow() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import stdio;
import stdlib;

@noinline
fn smash(n: usize) u64 {
    let mut buf: [u8; 16] = [0u8; 16];
    let p = ((&mut buf) as *mut [u8; 16]) as *mut u8;
    for i in 0..n {
        unsafe *(p + i) = 0x41;
    }
    return unsafe *p;
}

fn main() i32 {
    let n = unsafe stdlib::atoi(stdlib::getenv("N")) as usize;
    println("{}", smash(n));
    return 0;
}
)",
    );
    let root = p.dir();
    let b = cli::superc_env_in(root, E, "1", "build -O2 -fstack-protector-strong main.spc -o guarded");
    assert(b.ok(), "build");
    let exe = format("{}/guarded{}", root, unsafe str::from_cstr(cli::binext()));
    let fine = cli::exe_env_in(exe.as_str(), root, "N", "8", "");
    assert(fine.ok() && fine.out_has("65"), "no overflow");
    let smashed = cli::exe_env_in(exe.as_str(), root, "N", "64", "");
    assert(smashed.exit != 0, "the overflow stops");
}

// `-march` names the CPU as `--target-cpu` does: an unknown one is refused by the same check.
@test
fn march_is_target_cpu() {
    let p = cli::proj_new();
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let r = cli::superc_env_in(p.dir(), E, "1", "build -march=no-such-cpu main.spc -o b");
    assert(!r.ok() && r.out_has("unknown target CPU 'no-such-cpu'"), "-march");
}
