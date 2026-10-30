// The C ABI: a library target over a vendored compiler builds libsuperc, and a C client compiled against
// sdk/libsuperc.h uses it through its functions and its version 1 table: sessions, generation checks,
// diagnostics with stable codes, symbols, references, formatting, and balanced result ownership.
import tests::cli_harness as cli;
import stdlib;
import api::c_abi as abi;
import api::errors as apierr;

const CLIENT: str = M"(#include "libsuperc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(c, n) do { if (!(c)) { fprintf(stderr, "check %d failed\n", n); return n; } } while (0)

static const char APP[] = "fn main() i32 {\n    let b: bool = 3;\n    return 0;\n}\n";
static const char FIXED[] = "fn twice(x: i32) i32 {\n    return x + x;\n}\n\nfn main() i32 {\n    return twice(2) - twice(2);\n}\n";

int main(int argc, char **argv) {
    const char *app = argv[1];
    const char *std_dir = getenv("SC_STD_DIR");
    superc_api_v1 t;
    memset(&t, 0, sizeof t);
    CHECK(superc_api_table(99, &t, sizeof t) == SUPERC_VERSION_MISMATCH, 1);
    CHECK(superc_api_table(SUPERC_TABLE_V1, &t, sizeof t) == SUPERC_OK && t.version == 1, 2);
    CHECK(t.api_version() == (SUPERC_API_MAJOR << 16 | SUPERC_API_MINOR), 3);
    superc_session *s = 0;
    CHECK(t.session_open_file(app, strlen(app), std_dir, strlen(std_dir), &s) == SUPERC_OK, 4);
    CHECK(t.session_set_text(s, app, strlen(app), APP, strlen(APP), 0) == SUPERC_OK, 5);
    CHECK(t.session_check(s) == SUPERC_OK, 6);
    uint64_t gen = t.session_generation(s);
    superc_result *r = 0;
    CHECK(t.session_diagnostics(s, gen, &r) == SUPERC_OK, 7);
    int errors = 0;
    for (size_t i = 0; i < t.result_count(r); i++) {
        superc_item it;
        it.size = sizeof it;
        CHECK(t.result_item(r, i, &it) == SUPERC_OK, 8);
        if (it.severity == SUPERC_SEVERITY_ERROR) {
            const char *name;
            size_t len;
            t.code_name(it.code, &name, &len);
            CHECK(len == strlen("mismatched_types_expected_found") && memcmp(name, "mismatched_types_expected_found", len) == 0, 9);
            errors++;
        }
    }
    CHECK(errors == 1, 10);
    t.result_free(r);
    /* A change makes the old generation stale. */
    CHECK(t.session_set_text(s, app, strlen(app), FIXED, strlen(FIXED), 0) == SUPERC_OK, 11);
    CHECK(t.session_diagnostics(s, gen, &r) == SUPERC_STALE_HANDLE, 12);
    CHECK(t.session_check(s) == SUPERC_OK, 13);
    gen = t.session_generation(s);
    uint32_t at = (uint32_t)(strstr(FIXED, "twice(2) -") - FIXED);
    CHECK(t.session_symbol_at(s, gen, app, strlen(app), at, &r) == SUPERC_OK && t.result_count(r) == 1, 14);
    superc_item it;
    it.size = sizeof it;
    CHECK(t.result_item(r, 0, &it) == SUPERC_OK && it.text_len == 5 && memcmp(it.text, "twice", 5) == 0, 15);
    t.result_free(r);
    CHECK(t.session_references(s, gen, app, strlen(app), at, &r) == SUPERC_OK && t.result_count(r) == 3, 16);
    t.result_free(r);
    CHECK(t.format("fn  main( )i32{return 0;}", 25, &r) == SUPERC_OK, 17);
    const char *txt;
    size_t len;
    t.result_text(r, &txt, &len);
    CHECK(len == strlen("fn main() i32 {\n    return 0;\n}\n") && memcmp(txt, "fn main() i32 {\n    return 0;\n}\n", len) == 0, 18);
    t.result_free(r);
    CHECK(superc_format("fn ;", 4, &r) == SUPERC_PARSE_FAILED, 19);
    t.session_free(s);
    return 0;
}
)";

// Every symbol the shared library in `libdir` exports is the C ABI's (`superc_`).
@platform(macos | linux)
fn exports_only_the_c_abi(libdir: str) {
    let lib = if PLATFORM == Platform::MacOS {
        format("{}/libsuperc.dylib", libdir)
    } else {
        format("{}/libsuperc.so", libdir)
    };
    let flags = if PLATFORM == Platform::MacOS {
        "-gU"
    } else {
        "-D --defined-only"
    };
    let mut cmd = format("nm {} {}", flags, lib.as_str());
    let mut op = format("{}/.nm", libdir);
    let r = cli::exec_env(cmd.cstr(), op.cstr(), "");
    assert(r.ok(), "nm lists the library");
    let out = unsafe str::from_cstr(r.out);
    let mut n: usize = 0;
    for line in out.lines() {
        let t = line.trim();
        if t.len() == 0 {
            continue;
        }
        let mut k = t.len();
        while k > 0 && t.byte_at(k - 1) != b' ' {
            k -= 1;
        }
        let name = t.slice(k, t.len());
        assert(name.starts_with("superc_") || name.starts_with("_superc_"), name);
        n += 1;
    }
    assert_eq(n, 18);
}

@platform(windows | wasm)
fn exports_only_the_c_abi(libdir: str) {}

@test(timeout = 900)
fn a_c_client_uses_libsuperc() {
    let proj = cli::proj_new();
    cli::copy_tree("src", format("{}/vendor/superc/src", proj.dir()).as_str());
    assert(proj.copyfile("vendor/superc/build.toml", "build.toml"), "the manifest copies");
    assert(proj.copyfile("libsuperc.h", "sdk/libsuperc.h"), "the header copies");
    proj.mkfile("lib.spc", "import vendor::superc::src::api::c_abi;\n");
    proj.mkfile("build.toml", "[lib]\nname = \"superc\"\nroot = \"lib.spc\"\ntype = [\"shared\"]\nexports = \"c\"\n");
    proj.mkfile("app/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    proj.mkfile("client.c", CLIENT);
    let r = cli::superc_env_in(proj.dir(), "SC_NONE", "", "build --lib");
    if !r.ok() {
        r.show();
    }
    assert(r.ok(), "libsuperc builds");
    let libdir = format("{}/build/debug-lib", proj.dir());
    exports_only_the_c_abi(&libdir);
    if !cli::has_cc() {
        return;
    }
    let mut cmd = format(
        "{} -I{} -o {}/client {}/client.c -L{} -lsuperc -Wl,-rpath,{}",
        unsafe str::from_cstr(cli::cc_name()),
        proj.dir(),
        proj.dir(),
        proj.dir(),
        libdir.as_str(),
        libdir.as_str(),
    );
    let mut op = format("{}/.ccout", proj.dir());
    let cc = cli::exec_env(cmd.cstr(), op.cstr(), "");
    if !cc.ok() {
        cc.show();
    }
    assert(cc.ok(), "the C client compiles against the header");
    let std_dir = stdlib::get_env("SC_STD_DIR").unwrap();
    let mut run = format("{}/client {}/app/main.spc", proj.dir(), proj.dir());
    let mut rp = format("{}/.runout", proj.dir());
    let res = cli::exec_env(run.cstr(), rp.cstr(), format("SC_STD_DIR={}", std_dir.as_str()).as_str());
    if res.exit != 0 {
        res.show();
    }
    assert_eq(res.exit, 0);
}

// The same calls in process, through the exported functions themselves.
@test
fn the_exported_functions_follow_their_contract() {
    let proj = cli::proj_new();
    proj.mkfile(
        "main.spc",
        "fn twice(x: i32) i32 {\n    return x + x;\n}\n\nfn main() i32 {\n    return twice(2) - 4;\n}\n",
    );
    let path = format("{}/main.spc", proj.dir());
    let std_dir = "std";
    let mut h = null as *mut abi::Handle;
    assert_eq(abi::session_open_file(path.as_ptr(), path.len(), std_dir.ptr(), std_dir.len(), &mut h), 0);
    assert_eq(abi::session_check(h), 0);
    let gen = abi::session_generation(h);
    let mut r = null as *mut abi::Res;
    assert_eq(abi::session_diagnostics(h, gen + 1, &mut r), 2);
    assert_eq(abi::session_diagnostics(h, gen, &mut r), 0);
    assert_eq(abi::result_count(r), 0);
    abi::result_free(r);
    let src = cli::read_text(&path);
    let at = src.as_str().find("twice(2)") as u32;
    assert_eq(abi::session_symbol_at(h, gen, path.as_ptr(), path.len(), at, &mut r), 0);
    let mut it = abi::CItem { size: sizeof(abi::CItem) as u32 };
    assert_eq(abi::result_item(r, 0, &mut it), 0);
    assert_eq(unsafe str::from_raw(it.text, it.text_len), "twice");
    let mut tp = null as *const u8;
    let mut tl: usize = 0;
    abi::result_text(r, &mut tp, &mut tl);
    assert(unsafe str::from_raw(tp, tl).starts_with("fn twice"), "the symbol's head");
    abi::result_free(r);
    assert_eq(abi::session_references(h, gen, path.as_ptr(), path.len(), at, &mut r), 0);
    assert_eq(abi::result_count(r), 2);
    abi::result_free(r);
    let mut v: i64 = -1;
    let bad = "fn main() i32 {\n    return true;\n}\n";
    assert_eq(abi::session_set_text(h, path.as_ptr(), path.len(), bad.ptr(), bad.len(), &mut v), 0);
    assert_eq(v, 0);
    assert_eq(abi::session_check(h), 0);
    assert_eq(abi::session_error(h, &mut r), 0);
    abi::result_free(r);
    let mut np = null as *const u8;
    let mut nl: usize = 0;
    abi::code_name(1, &mut np, &mut nl);
    assert_eq(unsafe str::from_raw(np, nl), "lexical_error");
    let txt = "fn  main( )i32{return 0;}";
    assert_eq(abi::format_text(txt.ptr(), txt.len(), &mut r), 0);
    abi::result_free(r);
    assert_eq(abi::api_version(), apierr::API_VERSION);
    let mut t = unsafe zeroed::<abi::TableV1>();
    assert_eq(abi::api_table(2, &mut t, sizeof(abi::TableV1)), 16);
    assert_eq(abi::api_table(abi::TABLE_V1, &mut t, sizeof(abi::TableV1)), 0);
    assert_eq(t.api_version(), apierr::API_VERSION);
    abi::session_free(h);
    let dir = proj.dir();
    let mut hp = null as *mut abi::Handle;
    assert_eq(abi::session_open_project(dir.ptr(), dir.len(), std_dir.ptr(), std_dir.len(), &mut hp), 1);
}
