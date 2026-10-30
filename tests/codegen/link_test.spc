// The link step: the link record's name, a C static library the own linker links, the import
// libraries a Windows link takes for their DLLs, and the garbage collection of `-ffunction-sections`.
import stdlib;
import build_system::build as bsys;
import driver::util as dutil;
import tests::cli_harness as cli;
import codegen::obj as ob;
import target::assembler as asmr;
import target::coff as coff;
import link::pe;
import std::platform::fs;
import module::loader as loader;
import std::platform::dylib;
import target::table as tgt;

@test
fn link_record_names_fit_and_differ() {
    let mut deep = String::new();
    for _ in 0..100 {
        deep.push_str("dir/");
    }
    deep.push_str("app");
    let rec = bsys::link_record("out", &deep);
    assert(rec.as_str().starts_with("out/__link-"), "the record lies in the out-dir");
    assert(rec.len() - 4 < 255, "a 400-byte path gives a name under NAME_MAX");
    let a = bsys::link_record("out", "a/b_c");
    let b = bsys::link_record("out", "a_b/c");
    assert(a.as_str() != b.as_str(), "paths that flatten alike have their own records");
    assert(a.as_str() == bsys::link_record("out", "a/b_c").as_str(), "one path has one record");
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
// wasm32 (run by wasmtime); the own linker links the program, taking only the member the program needs.
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
    p.mkfile("main.spc", &m);
    let r = cli::superc_in(p.dir(), "build main.spc -o bin");
    assert(r.ok(), "the own linker links the library");
    assert_eq(p.run_bin(), 0);
    // Garbage collection keeps the constructor, the table's functions and the thread-local the program
    // reaches through the library.
    let rg = cli::superc_in(p.dir(), "build main.spc -ffunction-sections -fdata-sections -o bin");
    assert(rg.ok(), "the own linker collects the library's unused parts");
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
    dutil::mkdir_p(&w);
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
    p.mkfile("main.spc", &wm);
    let rw = cli::superc_in(p.dir(), "build main.spc --target=wasm -o bin.wasm");
    assert(rw.ok(), "the own linker links the wasm32 library");
    let mut run = format("wasmtime run \"{}/bin.wasm\"", p.dir());
    assert_eq(cli::run_with(run.cstr(), null, null, null, ""), 0);
    let rwg = cli::superc_in(p.dir(), "build main.spc --target=wasm -ffunction-sections -fdata-sections -o bin.wasm");
    assert(rwg.ok(), "the own linker collects the wasm32 library's unused parts");
    assert_eq(cli::run_with(run.cstr(), null, null, null, ""), 0);
}

// An archive of `members` (name, bytes) in the System V layout.
fn ar_of(members: [](str, Vector<u8>)) Vector<u8> {
    let mut out = Vector::<u8>::new();
    for c in "!<arch>\n".bytes() {
        out.push(c);
    }
    for i in 0..members.len() {
        let name = members[i].0;
        let bytes = &members[i].1;
        let head = format("{}/", name);
        let mut h = format("{:<16}{:<12}{:<6}{:<6}{:<8}{:<10}`\n", head.as_str(), 0, 0, 0, 644, bytes.len());
        for c in h.as_str().bytes() {
            out.push(c);
        }
        for k in 0..bytes.len() {
            out.push(bytes[k]);
        }
        if bytes.len() % 2 != 0 {
            out.push(b'\n');
        }
        h.clear();
    }
    return out;
}

// mingw-w64's import libraries (`libws2_32.a`) hold objects beside their imports (short import objects, or
// GNU dlltool's objects of `.idata$` sections): `-l` takes such a library for its DLL, not as a static one.
@test
fn an_archive_with_imports_stands_for_its_dll() {
    let mut o = ob::Obj::new();
    let mut a = asmr::Asm::new(asmr::ISA_X64, asmr::FMT_COFF);
    assert(a.module(&mut o, ".globl helper\nhelper:\nret\n"), "the object assembles");
    let mut obj = Vector::<u8>::new();
    coff::write(&o, 0, &mut obj);
    // A short import object of `f` from `x.dll`: signatures 0 and 0xFFFF, version 0, machine x86-64, time,
    // the size of the names, ordinal or hint, type code by name, then the names.
    let names = "f\0x.dll\0";
    let mut imp: Vector<u8> = Vector::<u8>::new();
    for v in [0u16, 0xFFFF, 0, 0x8664] {
        imp.push(v as u8);
        imp.push((v >> 8) as u8);
    }
    for _ in 0..4 {
        imp.push(0);
    }
    imp.push(names.len() as u8);
    for _ in 0..3 {
        imp.push(0);
    }
    for v in [0u16, 0x4] {
        imp.push(v as u8);
        imp.push((v >> 8) as u8);
    }
    for c in names.bytes() {
        imp.push(c);
    }
    let p = cli::proj_new();
    let dir = p.dir();
    let lib_a = ar_of([("helper.o", obj.clone()), ("f.o", imp)]);
    let lib_b = ar_of([("helper.o", obj)]);
    assert(fs::publish(format("{}/libx.a", dir).as_str(), &lib_a).is_ok(), "the import library");
    assert(fs::publish(format("{}/liby.a", dir).as_str(), &lib_b).is_ok(), "the static library");
    let mut dirs = Vector::<String>::new();
    dirs.push(String::from_str(dir));
    let opts = pe::Opts {
        out: String::new(),
        shared: false,
        objs: Vector::<String>::new(),
        libs: Vector::<String>::new(),
        dirs: dirs,
        strip: false,
        stack: 0,
        exports: None,
    };
    let mut path = String::new();
    assert(!pe::static_lib(&opts, "x", &mut path), "an archive with an import is an import library");
    assert(pe::static_lib(&opts, "y", &mut path), "an archive of objects alone is a static library");
}

// A program at `-O2` with a function every call of which inlines (its body stays in the object), an
// `@export` function and an `@used` variable nothing refers to, and code reached only through a function
// pointer in data. Emission leaves out what nothing names, so dead code comes from the optimizer.
const GC_MAIN: str = M"(pub fn gc_inlined_marker(x: i64) i64 {
    return x * 977 + 3;
}

@export("gc_exported_marker")
fn gc_exported_marker(x: i32) i32 {
    return x + 1;
}

@used
static mut gc_used_marker: [u8; 24] = [5; 24];

@noinline
fn gc_through_table(x: i64) i64 {
    return x * 2;
}

static mut GC_TABLE: [fn(i64) i64; 1] = [gc_through_table];

fn main() i32 {
    let f = unsafe GC_TABLE[0];
    return (f(21) - 42 + gc_inlined_marker(2) - 1957) as i32;
}
)";

// Functions and variables in sections of their own (the default from -O1): the link drops the body nothing
// calls any more, keeps the exported function, the `@used` variable and what a kept table points to, and
// the program still runs.
@test
fn section_garbage_collection_drops_what_nothing_reaches() {
    let p = cli::proj_new();
    p.mkfile("main.spc", GC_MAIN);
    let full = format("{}/full{}", p.dir(), unsafe str::from_cstr(cli::binext()));
    let gc = format("{}/gc{}", p.dir(), unsafe str::from_cstr(cli::binext()));
    let a = format("build main.spc -O2 -fno-function-sections -fno-data-sections -o \"{}\"", full.as_str());
    assert(cli::superc_in(p.dir(), &a).ok(), "the plain build");
    let b = format("build main.spc -O2 -o \"{}\"", gc.as_str());
    assert(cli::superc_in(p.dir(), &b).ok(), "the collected build");
    let fb = loader::read_file(&full).unwrap();
    let gb = loader::read_file(&gc).unwrap();
    assert(has(&fb, "gc_inlined_marker"), "the plain build keeps the inlined function's body");
    assert(!has(&gb, "gc_inlined_marker"), "the collected build drops it");
    assert(has(&gb, "gc_exported_marker"), "an exported function stays");
    assert(has(&gb, "gc_used_marker"), "an '@used' variable stays");
    assert(has(&gb, "gc_through_table"), "a function a kept table points to stays");
    assert(gb.len() < fb.len(), "the collected build is smaller");
    let mut run = format("\"{}\"", gc.as_str());
    assert_eq(cli::run_with(run.cstr(), null, null, null, ""), 0);
    // The wasm linker: its name section names the functions it keeps.
    if stdlib::get_env("WASI_SDK_PATH").unwrap_or(String::new()).len() == 0 || cli::on_wasm() {
        return;
    }
    let wa = format(
        "build main.spc -O2 -fno-function-sections -fno-data-sections --target=wasm -o \"{}/full.wasm\"",
        p.dir(),
    );
    assert(cli::superc_in(p.dir(), &wa).ok(), "the plain wasm build");
    let wb = format("build main.spc -O2 --target=wasm -o \"{}/gc.wasm\"", p.dir());
    assert(cli::superc_in(p.dir(), &wb).ok(), "the collected wasm build");
    let wfp = format("{}/full.wasm", p.dir());
    let wgp = format("{}/gc.wasm", p.dir());
    let wf = loader::read_file(&wfp).unwrap();
    let wg = loader::read_file(&wgp).unwrap();
    assert(has(&wf, "gc_inlined_marker"), "the plain wasm build keeps the inlined function's body");
    assert(!has(&wg, "gc_inlined_marker"), "the collected wasm build drops it");
    assert(has(&wg, "gc_exported_marker"), "an exported function stays in wasm");
    assert(has(&wg, "gc_through_table"), "a function a kept table points to stays in wasm");
    assert(wg.len() < wf.len(), "the collected wasm build is smaller");
    let mut wrun = format("wasmtime run \"{}\"", wgp.as_str());
    assert_eq(cli::run_with(wrun.cstr(), null, null, null, ""), 0);
}

// Whether the bytes `b` hold those of `s`.
fn has(b: str, s: str) bool {
    let n = s.len();
    if b.len() < n {
        return false;
    }
    for i in 0..b.len() - n + 1 {
        let mut k: usize = 0;
        while k < n && b.byte_at(i + k) == s.byte_at(k) {
            k += 1;
        }
        if k == n {
            return true;
        }
    }
    return false;
}

// Whether the shared library `x` the project in `dir` builds into `build/debug-lib` defines `name` for a
// program that loads it.
fn lib_defines(dir: str, name: str) bool {
    let lib = format("{}/build/debug-lib/{}", dir, bsys::lib_file("x", true, tgt::host_os()).as_str());
    let l = (unsafe dylib::open(&lib)).unwrap();
    return (unsafe l.symbol(name)).is_ok();
}

// A shared library exports every global by default, and its `@export` symbols alone with `exports = "c"`.
@platform(!wasm)
@test(timeout = 300)
fn a_c_export_list_keeps_the_export_symbols_alone() {
    let p = cli::proj_new();
    p.mkfile(
        "lib.spc",
        "@export(\"x_api\")\npub fn api() i32 {\n    return helper() + 1;\n}\n\npub fn helper() i32 {\n    return 41;\n}\n",
    );
    let toml = "[lib]\nname = \"x\"\nroot = \"lib.spc\"\ntype = [\"shared\"]\n";
    p.mkfile("build.toml", toml);
    assert(cli::superc_in(p.dir(), "build --lib").ok(), "the library builds");
    assert(lib_defines(p.dir(), "x_api") && lib_defines(p.dir(), "helper"), "every global is exported");
    p.mkfile("build.toml", format("{}exports = \"c\"\n", toml).as_str());
    assert(cli::superc_in(p.dir(), "build --lib").ok(), "the library builds again");
    assert(lib_defines(p.dir(), "x_api"), "the export symbol is exported");
    assert(!lib_defines(p.dir(), "helper"), "the other globals are not");
}
