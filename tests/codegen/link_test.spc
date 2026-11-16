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
import link::util as lu;
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
const fn has(b: str, s: str) bool {
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
@platform(!wasm)
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

// A C shared library whose exports share a prefix: their names in the export trie run through a node per
// shared part, and each binds under its whole name. The own linker links the program against it.
@platform(macos)
@test
fn a_c_shared_library_links_with_the_own_linker() {
    if !cli::has_cc() {
        return; // the C compiler builds the library
    }
    let p = cli::proj_new();
    p.mkfile("d.c", "int dyl_add(int a, int b) { return a + b; }\nint dyl_mul(int a, int b) { return a * b; }\n");
    let mut cc = format(
        "{} -dynamiclib \"{}/d.c\" -install_name \"{}/libdyl.dylib\" -o \"{}/libdyl.dylib\"",
        unsafe str::from_cstr(cli::cc_name()),
        p.dir(),
        p.dir(),
        p.dir(),
    );
    assert(cli::run_with(cc.cstr(), null, null, null, "") == 0, "the C compiler builds the library");
    let mut m = format("@link(\"-L{} -ldyl\")\n", p.dir());
    m.push_str(
        "extern \"C\" {\n    fn dyl_add(a: i32, b: i32) i32;\n    fn dyl_mul(a: i32, b: i32) i32;\n}\n\nfn main() i32 {\n    return unsafe dyl_add(2, 3) + unsafe dyl_mul(4, 5) - 25;\n}\n",
    );
    p.mkfile("main.spc", &m);
    let r = cli::superc_in(p.dir(), "build main.spc -o bin");
    assert(r.ok(), "the own linker links the shared library");
    assert_eq(p.run_bin(), 0);
}

// `atexit` through the own linker (on Linux the runtime's, `__cxa_atexit` keyed on the image's
// `__dso_handle`): the handlers run at exit, the last registered first. `first` sees whether `later` ran.
const AT_EXIT_MAIN: str = M"(static mut LATER_RAN: bool = false;

extern "C" {
    fn atexit(f: fn()) i32;
    fn _Exit(code: i32);
}

fn first() {
    unsafe _Exit(if unsafe LATER_RAN {
        7
    } else {
        9
    });
}

fn later() {
    unsafe LATER_RAN = true;
}

fn main() i32 {
    if unsafe atexit(first) != 0 || unsafe atexit(later) != 0 {
        return 1;
    }
    return 0;
}
)";

@test
fn exit_handlers_run_last_registered_first() {
    let p = cli::proj_new();
    p.mkfile("main.spc", AT_EXIT_MAIN);
    assert(cli::superc_in(p.dir(), "build main.spc -o bin").ok(), "the program builds");
    assert_eq(p.run_bin(), 7);
}

// Two modules whose `@noinline` functions return one string literal: each object defines its copy. With
// variables in sections of their own (the default from -O1), each copy is a weak definition and the link
// keeps one; without, each object's copy is its own.
@test
fn a_string_literal_of_two_objects_links_once() {
    let p = cli::proj_new();
    p.mkfile("a.spc", "@noinline\npub fn a_text() str<'static> {\n    return \"dedup marker 7f3a9c\";\n}\n");
    p.mkfile("b.spc", "@noinline\npub fn b_text() str<'static> {\n    return \"dedup marker 7f3a9c\";\n}\n");
    p.mkfile(
        "main.spc",
        "import a;\nimport b;\n\nfn main() i32 {\n    return (a::a_text().len() + b::b_text().len()) as i32 - 38;\n}\n",
    );
    let one = format("{}/one{}", p.dir(), unsafe str::from_cstr(cli::binext()));
    let two = format("{}/two{}", p.dir(), unsafe str::from_cstr(cli::binext()));
    let a = format("build main.spc -O2 -o \"{}\"", one.as_str());
    assert(cli::superc_in(p.dir(), &a).ok(), "the build with data sections");
    let b = format("build main.spc -O2 -fno-data-sections -o \"{}\"", two.as_str());
    assert(cli::superc_in(p.dir(), &b).ok(), "the build without");
    let ob = loader::read_file(&one).unwrap();
    let tb = loader::read_file(&two).unwrap();
    assert_eq(count(&ob, "dedup marker 7f3a9c"), 1);
    assert_eq(count(&tb, "dedup marker 7f3a9c"), 2);
    let mut run = format("\"{}\"", one.as_str());
    assert_eq(cli::run_with(run.cstr(), null, null, null, ""), 0);
    if stdlib::get_env("WASI_SDK_PATH").unwrap_or(String::new()).len() == 0 || cli::on_wasm() {
        return;
    }
    let w = format("build main.spc -O2 --target=wasm -o \"{}/one.wasm\"", p.dir());
    assert(cli::superc_in(p.dir(), &w).ok(), "the wasm build");
    let wp = format("{}/one.wasm", p.dir());
    let wb = loader::read_file(&wp).unwrap();
    assert_eq(count(&wb, "dedup marker 7f3a9c"), 1);
    let mut wrun = format("wasmtime run \"{}\"", wp.as_str());
    assert_eq(cli::run_with(wrun.cstr(), null, null, null, ""), 0);
}

// How many times the bytes `b` hold those of `s`.
const fn count(b: str, s: str) u32 {
    let n = s.len();
    let mut c: u32 = 0;
    if b.len() < n {
        return 0;
    }
    for i in 0..b.len() - n + 1 {
        let mut k: usize = 0;
        while k < n && b.byte_at(i + k) == s.byte_at(k) {
            k += 1;
        }
        c += (k == n) as u32;
    }
    return c;
}

// `n` arm64 `nop` words, the word at index `at` a `b.ne` back by `back` words (0: none).
fn nops_with_loop(n: usize, at: usize, back: u32) Vector<u8> {
    let mut b = Vector::<u8>::new();
    for i in 0..n {
        let w: u32 = if back != 0 && i == at {
            0x54000001 | (0x80000 - back & 0x7FFFF) << 5
        } else {
            0xD503201F
        };
        ob::w32(&mut b, w);
    }
    return b;
}

// The bytes the linkers leave before arm64 code so that no 4096-byte boundary falls inside a short function
// or loop of it (`link::util::keep_pad`): none when the boundary is at the start, at the end, at a loop's
// head, after its branch or outside every loop; else the bytes that bring the function's or the widest
// loop's first instruction to the boundary, rounded up to the alignment. A loop of more than 128 bytes may
// hold one.
@test
fn short_code_stays_off_a_page_boundary() {
    let small = nops_with_loop(5, 0, 0);
    assert_eq(lu::keep_pad(small[0..small.len()], 0xFF0, 4, 0), 16);
    assert_eq(lu::keep_pad(small[0..small.len()], 0xFFC, 4, 0), 4);
    assert_eq(lu::keep_pad(small[0..small.len()], 0x1000, 4, 0), 0);
    assert_eq(lu::keep_pad(small[0..small.len()], 0xFEC, 4, 0), 0);
    assert_eq(lu::keep_pad(small[0..small.len()], 0xFF0, 64, 0), 64);
    // Words 54 to 60 are a loop.
    let f = nops_with_loop(100, 60, 6);
    let c = f[0..f.len()];
    assert_eq(lu::keep_pad(c, 0x2000 - 4 * 57, 4, 0), 12);
    assert_eq(lu::keep_pad(c, 0x2000 - 4 * 60, 4, 0), 24);
    assert_eq(lu::keep_pad(c, 0x2000 - 4 * 54, 4, 0), 0);
    assert_eq(lu::keep_pad(c, 0x2000 - 4 * 61, 4, 0), 0);
    assert_eq(lu::keep_pad(c, 0x2000 - 4 * 10, 4, 0), 0);
    assert_eq(lu::keep_pad(c, 0x2000 - 4 * 57, 16, 0), 16);
    // Words 50 to 70 are a loop around it: the outer one moves to the boundary.
    let mut g = nops_with_loop(100, 60, 6);
    let outer = nops_with_loop(100, 70, 20);
    for k in 280usize..284 {
        g[k] = outer[k];
    }
    assert_eq(lu::keep_pad(g[0..g.len()], 0x2000 - 4 * 57, 4, 0), 28);
    // Words 20 to 60 are a loop of 164 bytes.
    let wide = nops_with_loop(100, 60, 40);
    assert_eq(lu::keep_pad(wide[0..wide.len()], 0x2000 - 4 * 40, 4, 0), 0);
}

// With lines of 64 bytes (a Linux arm64 link), code that fits a line moves to where it holds the fewest
// boundaries between two: a function of at most 64 bytes, and each loop of at most 64 bytes. The move off
// a page boundary then keeps the place in the line.
@test
fn code_that_fits_a_line_stays_inside_one() {
    let small = nops_with_loop(5, 0, 0);
    assert_eq(lu::keep_pad(small[0..small.len()], 0x30, 4, 64), 16);
    assert_eq(lu::keep_pad(small[0..small.len()], 0x2C, 4, 64), 0);
    assert_eq(lu::keep_pad(small[0..small.len()], 0x40, 4, 64), 0);
    assert_eq(lu::keep_pad(small[0..small.len()], 0x30, 4, 0), 0);
    assert_eq(lu::keep_pad(small[0..small.len()], 0xFF0, 4, 64), 16);
    // Words 54 to 60 are a loop: bytes 216 to 244.
    let f = nops_with_loop(100, 60, 6);
    let c = f[0..f.len()];
    assert_eq(lu::keep_pad(c, 0, 4, 64), 0);
    assert_eq(lu::keep_pad(c, 16, 4, 64), 24);
    // Words 36 to 60 are a loop of 100 bytes that holds the page boundary: it moves past it by whole lines.
    let g = nops_with_loop(100, 60, 24);
    assert_eq(lu::keep_pad(g[0..g.len()], 0x2000 - 200, 4, 0), 56);
    assert_eq(lu::keep_pad(g[0..g.len()], 0x2000 - 200, 4, 64), 64);
    // Two loops of 60 bytes, 8 bytes apart: one place holds a boundary in neither.
    let mut two = nops_with_loop(40, 14, 14);
    let w: u32 = 0x54000001 | (0x80000 - 14u32 & 0x7FFFF) << 5;
    for q in 0..4usize {
        two[4 * 31 + q] = (w >> 8 * q as u32) as u8;
    }
    assert_eq(lu::keep_pad(two[0..two.len()], 0x40, 4, 64), 0);
    assert_eq(lu::keep_pad(two[0..two.len()], 0x44, 4, 64), 60);
}

// A little-endian value of `n` bytes at `at` of the bytes `b`.
const fn le(b: str, at: usize, n: usize) u64 {
    let mut v: u64 = 0;
    for k in 0..n {
        v |= b.byte_at(at + k) as u64 << (8 * k) as u64;
    }
    return v;
}

// The start and end addresses of each function of arm64 image `b`, a Mach-O or ELF executable, into `out`
// (start << 32 | end, sorted); false when `b` is neither. A Mach-O function ends where the next symbol of
// its section starts.
fn function_ranges(b: str, out: &mut Vector<u64>) bool {
    if le(b, 0, 4) == 0xFEEDFACF && le(b, 4, 4) == 0x0100000C {
        let mut at: usize = 32;
        let mut starts = Vector::<u64>::new();
        for _ in 0..le(b, 16, 4) as usize {
            if le(b, at, 4) == 2 {
                let (symoff, nsyms) = (le(b, at + 8, 4) as usize, le(b, at + 12, 4) as usize);
                for k in 0..nsyms {
                    let y = symoff + 16 * k;
                    // A symbol defined in section 1, the code; no debugger entry.
                    if (le(b, y + 4, 1) & 0xEE) == 0x0E && le(b, y + 5, 1) == 1 {
                        starts.push(le(b, y + 8, 8));
                    }
                }
            }
            at += le(b, at + 4, 4) as usize;
        }
        starts.sort();
        for k in 1..starts.len() {
            if starts[k] != starts[k - 1] {
                out.push((starts[k - 1] & 0xFFFFFFFF) << 32 | starts[k] & 0xFFFFFFFF);
            }
        }
        return true;
    }
    if le(b, 0, 4) == 0x464C457F && le(b, 18, 2) == 183 {
        let (shoff, shsize, shnum) = (le(b, 0x28, 8) as usize, le(b, 0x3A, 2) as usize, le(b, 0x3C, 2) as usize);
        for k in 0..shnum {
            let sh = shoff + k * shsize;
            if le(b, sh + 4, 4) != 2 {
                continue;
            }
            let (off, size) = (le(b, sh + 0x18, 8) as usize, le(b, sh + 0x20, 8) as usize);
            for q in 0..size / 24 {
                let y = off + 24 * q;
                // A function with a size.
                if (le(b, y + 4, 1) & 0xF) == 2 && le(b, y + 16, 8) != 0 {
                    let a = le(b, y + 8, 8);
                    out.push((a & 0xFFFFFFFF) << 32 | a + le(b, y + 16, 8) & 0xFFFFFFFF);
                }
            }
        }
        out.sort();
        return true;
    }
    return false;
}

// Three thousand functions of a few instructions each, linked for arm64: none of at most 128 bytes holds
// a 4096-byte boundary between two of its instructions, and the program runs.
@test(timeout = 300)
fn the_link_keeps_short_functions_off_page_boundaries() {
    if cli::on_wasm() {
        return;
    }
    let mut src = String::new();
    for k in 0..3000 {
        src.format_into("@noinline\nfn f{}(x: i64) i64 {{\n    return x * 3 + {};\n}}\n\n", k, k);
    }
    // A table keeps them: the link drops a function nothing names.
    src.push_str("static mut TABLE: [fn(i64) i64; 3000] = [");
    for k in 0..3000 {
        src.format_into("f{}, ", k);
    }
    src.push_str("];\n\nfn main() i32 {\n    let mut s: i64 = 1;\n    for k in 0..3000usize {\n");
    src.push_str("        let f = unsafe TABLE[k];\n        s = f(s) & 0xFFFF;\n    }\n");
    src.push_str("    return (s >> 16) as i32;\n}\n");
    let p = cli::proj_new();
    p.mkfile("main.spc", &src);
    let exe = format("{}/keep{}", p.dir(), unsafe str::from_cstr(cli::binext()));
    let a = format("build main.spc -O2 -o \"{}\"", exe.as_str());
    assert(cli::superc_in(p.dir(), &a).ok(), "the build");
    let img = loader::read_file(&exe).unwrap();
    let mut fns = Vector::<u64>::new();
    if !function_ranges(&img, &mut fns) {
        return; // no arm64 image: the rule is arm64's
    }
    let mut short: u32 = 0;
    for k in 0..fns.len() {
        let (lo, hi) = (fns[k] >> 32, fns[k] & 0xFFFFFFFF);
        if hi - lo > 128 {
            continue;
        }
        short += 1;
        // The first boundary after the function's first instruction is at its end or after.
        assert((lo | 4095) + 1 >= hi, format("a function at {} to {} holds a boundary", lo, hi).as_str());
    }
    assert(short >= 3000, "the image names its functions");
    let mut run = format("\"{}\"", exe.as_str());
    assert_eq(cli::run_with(run.cstr(), null, null, null, ""), 0);
}
