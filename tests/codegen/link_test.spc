// The link step: the link record's name, the archiver of a static library, the response file of a long
// Windows command line (pure builders, called directly on every host), the strip and spawn paths of a
// real link, and a C static library the own linker links.
import stdlib;
import build_system::build as bsys;
import driver_shim as shim;
import driver::util as dutil;
import tests::cli_harness as cli;

@test
fn link_record_names_fit_and_differ() {
    let mut deep = String::new();
    for _ in 0..100 {
        deep.push_str("dir/");
    }
    deep.push_str("app");
    let rec = bsys::link_record("out", deep.as_str());
    assert(rec.as_str().starts_with("out/__link-"), "the record lies in the out-dir");
    assert(rec.len() - 4 < 255, "a 400-byte path gives a name under NAME_MAX");
    let a = bsys::link_record("out", "a/b_c");
    let b = bsys::link_record("out", "a_b/c");
    assert(a.as_str() != b.as_str(), "paths that flatten alike have their own records");
    assert(a.as_str() == bsys::link_record("out", "a/b_c").as_str(), "one path has one record");
}

@test
fn a_cross_static_library_uses_the_target_archiver() {
    // wasm and Android are never the host.
    assert(bsys::archiver("/opt/wasi/bin/clang", 3).as_str() == "/opt/wasi/bin/llvm-ar", "the wasi-sdk's llvm-ar");
    assert(
        bsys::archiver("/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/clang", 5).as_str() == "/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar",
        "the NDK's llvm-ar",
    );
    assert(bsys::archiver("clang -target wasm32", 3).as_str() == "llvm-ar", "a clang from PATH: llvm-ar from PATH");
    let foreign = if PLATFORM == Platform::Windows {
        2;
    } else {
        0;
    };
    assert(
        bsys::archiver("/opt/x/bin/x86_64-w64-mingw32-gcc-posix", foreign).as_str() == "/opt/x/bin/x86_64-w64-mingw32-ar",
        "a cross gcc's own ar",
    );
    let host = unsafe shim::sc_host_platform();
    assert(bsys::archiver("/opt/x/bin/clang", host).as_str() == "ar", "the host's format: the host ar");
    if host == 1 {
        assert(bsys::archiver("xcrun --sdk iphoneos clang", 4).as_str() == "ar", "iOS objects are Mach-O");
    }
}

@test
fn a_long_command_line_moves_its_objects_into_a_response_file() {
    let p = cli::proj_new();
    let rsp = format("{}/link.rsp", p.dir());
    let mut args = Vector::<String>::new();
    let words: [str; 6] = ["gcc", "-o", "app.tmp", "obj\\a b.o", "obj/c.o", "-lm"];
    for w in words {
        args.push(String::from_str(w));
    }
    assert_eq(bsys::fit_cmdline(&mut args, 3, 2, rsp.as_str(), 1000), 0);
    assert(args.len() == 6, "a line that fits stays as it is");
    assert(cli::read_text(rsp.as_str()).len() == 0, "and writes no response file");
    assert_eq(bsys::fit_cmdline(&mut args, 3, 2, rsp.as_str(), 40), 1);
    assert(args.len() == 5, "the objects leave the line");
    assert(args[2].as_str() == "app.tmp", "the arguments before the objects stay");
    assert(args[4].as_str() == "-lm", "and so do the ones after them");
    assert(args[3].as_str() == format("@{}", rsp.as_str()).as_str(), "the response file takes the objects' place");
    assert(
        cli::read_text(rsp.as_str()).as_str() == "\"obj/a b.o\"\n\"obj/c.o\"\n",
        "one quoted object per line, with forward slashes",
    );
    let bad = format("{}/missing/link.rsp", p.dir());
    assert_eq(bsys::fit_cmdline(&mut args, 0, 1, bad.as_str(), 1), -1);
}

// A stripped macOS binary runs the host `strip` on the linked temp (the other targets strip at link):
// a failed strip installs nothing and records no link, so the next build links and strips again. Stubs
// stand for the C compiler (it writes empty outputs) and `strip`.
@test
fn a_failed_strip_installs_nothing() {
    if PLATFORM != Platform::MacOS {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n\n[profile.debug]\nstrip = true\n");
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    p.mkfile(
        "cc.sh",
        "#!/bin/sh\no=\"\"; prev=\"\"\nfor a in \"$@\"; do [ \"$prev\" = -o ] && o=\"$a\"; prev=\"$a\"; done\n[ -n \"$o\" ] && : > \"$o\"\nexit 0\n",
    );
    p.mkfile("bin/strip", "#!/bin/sh\nexit 3\n");
    let root = p.dir();
    let mut cmd = String::new();
    cmd.format_into("chmod +x \"{}/cc.sh\" \"{}/bin/strip\"", root, root);
    assert(cli::run_quiet(cmd.cstr()) == 0, "chmod");
    let path = stdlib::get_env("PATH").unwrap_or(String::new());
    let _path = cli::set_env("PATH", format("{}/bin:{}", root, path.as_str()).as_str());
    // The C backend: the stub compiler's link, which the own linker would replace.
    let _nat = cli::set_env("SC_NATIVE", "0");
    let build = format("build --cc={}/cc.sh", root);
    let r = cli::superc_env_in(root, "SC_NO_CACHE", "1", build.as_str());
    assert(!r.ok() && r.out_has("strip failed (exit 3)"), "the failed strip fails the build");
    let bin = format("{}/build/debug/app", root);
    assert(dutil::file_mtime(bin.as_str()) == 0, "nothing is installed");
    let mut rec = bsys::link_record(format("{}/build", root).as_str(), "build/debug/app");
    rec.push_str(".cmd");
    assert(dutil::file_mtime(rec.as_str()) == 0, "no link is recorded");
    p.mkfile("bin/strip", "#!/bin/sh\nexit 0\n");
    let r2 = cli::superc_env_in(root, "SC_NO_CACHE", "1", build.as_str());
    assert(r2.ok(), "the next build links and strips");
    assert(dutil::file_mtime(bin.as_str()) != 0, "and installs the binary");
    assert(dutil::file_mtime(rec.as_str()) != 0, "and records the link");
}

// The compiles and the link start the compiler PATH names by its path; a PATH match that cannot start
// (a file without the execute bit) falls back to the search, which skips it.
@test
fn a_compiler_path_match_that_cannot_start_falls_back_to_the_search() {
    if !cli::has_cc() {
        return; // it names the C compiler
    }
    if cli::on_wasm() || cli::on_windows() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("main.spc", "fn main() i32 {\n    return 5;\n}\n");
    p.mkfile("shadow/cc", "not a program\n");
    let root = p.dir();
    let path = stdlib::get_env("PATH").unwrap_or(String::new());
    let _path = cli::set_env("PATH", format("{}/shadow:{}", root, path.as_str()).as_str());
    assert_eq(cli::superc_in(root, "run --cc=cc").exit, 5);
}

// A C static library of two members (the program needs one): functions, data, a function-pointer table,
// a thread-local, a constructor, a weak definition, a switch table, a float constant and C library calls.
const AR_LIB_A: str = M"(#include <stdlib.h>
#include <string.h>
long long lib_counter = 5;
static int ctor_ran;
__attribute__((constructor)) static void init(void) { ctor_ran = 42; }
int lib_ctor_ran(void) { return ctor_ran; }
static int sq(int x) { return x * x; }
static int tw(int x) { return 2 * x; }
static int (*const table[])(int) = { sq, tw, sq };
int lib_sum_table(int n) { int s = 0; for (int i = 0; i < 3; i++) s += table[i](n); return s; }
const char *lib_name(void) { return "archive member"; }
_Thread_local int tls_v = 10;
int lib_tls_bump(void) { return ++tls_v; }
__attribute__((weak)) int lib_weak(void) { return 7; }
int lib_switch(int k) {
    switch (k) { case 0: return 11; case 1: return 22; case 2: return 33; case 3: return 44; case 4: return 55; case 5: return 66; default: return -1; }
}
double lib_scale(double x) { return x * 2.5 + 0.125; }
int lib_heap(int n) { char *p = malloc(n + 1); memset(p, 'x', n); p[n] = 0; int r = (int)strlen(p); free(p); return r; }
)";

const AR_LIB_B: str = M"(int lib_add(int a, int b) { return a + b; }
int unused_member_fn(void) { return 1; }
)";

// The program: each check that fails sets its bit of the exit code.
const AR_MAIN: str = M"(extern "C" {
    fn lib_add(a: i32, b: i32) i32;
    fn lib_sum_table(n: i32) i32;
    fn lib_name() *const char;
    fn lib_tls_bump() i32;
    fn lib_ctor_ran() i32;
    fn lib_weak() i32;
    fn lib_switch(k: i32) i32;
    fn lib_scale(x: f64) f64;
    fn lib_heap(n: i32) i32;
    static mut lib_counter: i64;
}

fn main() i32 {
    let mut bad = 0;
    if unsafe lib_add(2, 3) != 5 { bad += 1; }
    if unsafe lib_sum_table(3) != 24 { bad += 2; }
    if unsafe str::from_cstr(lib_name()) != "archive member" { bad += 4; }
    if unsafe lib_tls_bump() != 11 || unsafe lib_tls_bump() != 12 { bad += 8; }
    if unsafe lib_ctor_ran() != 42 { bad += 16; }
    if unsafe lib_weak() != 7 { bad += 32; }
    if unsafe lib_switch(3) != 44 || unsafe lib_switch(9) != -1 { bad += 64; }
    if unsafe lib_scale(2.0) != 5.125 { bad += 128; }
    if unsafe lib_heap(17) != 17 || unsafe lib_counter != 5 { bad += 256; }
    return bad;
}
)";

// The C compiler builds the library and its archiver archives it, for the host and, with a wasi-sdk, for
// wasm32 (run by wasmtime); the own linker links the program (SC_LINK=own: a link it does not serve
// fails), taking only the member the program needs.
@test
fn a_c_static_library_links_with_the_own_linker() {
    if !cli::has_cc() {
        return; // the C compiler builds the library
    }
    let p = cli::proj_new();
    p.mkfile("a.c", AR_LIB_A);
    p.mkfile("b.c", AR_LIB_B);
    assert(p.c_lib("demo", "a.c b.c"), "the C compiler builds the library");
    let mut m = format("@link(\"-L{} -ldemo\")\n", p.dir());
    m.push_str(AR_MAIN);
    p.mkfile("main.spc", m.as_str());
    let r = cli::superc_env_in(p.dir(), "SC_LINK", "own", "build main.spc -o bin");
    assert(r.ok(), "the own linker links the library");
    assert_eq(p.run_bin(), 0);
    let sdk = stdlib::get_env("WASI_SDK_PATH").unwrap_or(String::new());
    if sdk.len() == 0 || cli::on_wasm() {
        return;
    }
    let w = format("{}/wasm", p.dir());
    for c in ["a", "b"] {
        let mut cmd = format(
            "\"{}/bin/clang\" --target=wasm32-wasip1 -O2 -c \"{}/{}.c\" -o \"{}/{}.o\"",
            sdk.as_str(),
            p.dir(),
            c,
            p.dir(),
            c,
        );
        assert(cli::run_with(cmd.cstr(), null, null, null, "") == 0, "clang compiles the member for wasm32");
    }
    dutil::mkdir_p(w.as_str());
    let mut arc = format(
        "\"{}/bin/llvm-ar\" rcs \"{}/libdemo.a\" \"{}/a.o\" \"{}/b.o\"",
        sdk.as_str(),
        w.as_str(),
        p.dir(),
        p.dir(),
    );
    assert(cli::run_with(arc.cstr(), null, null, null, "") == 0, "llvm-ar archives them");
    let mut wm = format("@link(\"-L{} -ldemo\")\n", w.as_str());
    wm.push_str(AR_MAIN);
    p.mkfile("main.spc", wm.as_str());
    let rw = cli::superc_env_in(p.dir(), "SC_LINK", "own", "build main.spc --target=wasm -o bin.wasm");
    assert(rw.ok(), "the own linker links the wasm32 library");
    let mut run = format("wasmtime run \"{}/bin.wasm\"", p.dir());
    assert_eq(cli::run_with(run.cstr(), null, null, null, ""), 0);
}
