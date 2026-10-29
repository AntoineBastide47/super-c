// Visibility levels across files, directories and packages (`pub(module)`, `pub(package)`), the signature
// leak rule, implicit directory modules and the `std_internals` manifest key,
// driven through `$SUPERC` on scratch projects.
import tests::cli_harness as cli;
import module::loader as loader;

// Whether `r` reports `msg` at `at` (a file's path tail and its line and column).
const fn r_has(r: &cli::CliResult, msg: str, at: str) bool {
    let t = r.text();
    let mut i: usize = 0;
    while i < t.len() {
        if t.slice(i, t.len()).starts_with(msg) {
            let rest = t.slice(i + msg.len(), t.len());
            if rest.starts_with("\n--> ") {
                let loc = rest.slice(5, rest.len());
                let e = loc.find_byte(b'\n');
                if loc.slice(
                    0,
                    if e < 0 {
                        loc.len();
                    } else {
                        e as usize;
                    },
                ).ends_with(at) {
                    return true;
                }
            }
        }
        i += 1;
    }
    return false;
}

// The library every visibility test imports: directory `a` (files `m1`, `m2`, `sub/m3`), directory `b`
// and the vendored package `v`.
fn levels_project() cli::Proj {
    let p = cli::proj_new();
    p.mkfile(
        "a/m1.spc",
        M"(pub(module) fn modf() i32 { return 1; }
pub(package) fn pkgf() i32 { return 2; }
fn filef() i32 { return 3; }
pub(module) struct MS { pub v: i32 }
extend MS { pub fn get(self: &Self) i32 { return self.v; } }
pub struct F { pub(module) m: i32, pub(package) p: i32, q: i32 }
extend F { pub fn new() F { return F { m: 2, p: 3, q: 4 }; } }
pub fn mkf() F { return F::new(); }
pub fn own_file(x: &F) i32 { return x.q + filef(); }
)",
    );
    p.mkfile(
        "a/m2.spc",
        M"(import a::m1;
pub fn ok_a() i32 { let x = m1::mkf(); let s = m1::MS { v: 1 }; return m1::modf() + m1::pkgf() + x.m + x.p + s.get(); }
)",
    );
    p.mkfile("a/sub/m3.spc", "import a::m1;\npub fn ok_sub() i32 { return m1::modf() + m1::MS { v: 2 }.get(); }\n");
    p.mkfile("b/m4.spc", "import a::m1;\npub fn ok_b() i32 { return m1::pkgf() + m1::mkf().p; }\n");
    p.mkfile("vendor/v/lib.spc", "pub(package) fn vp() i32 { return 1; }\npub fn vpub() i32 { return vp(); }\n");
    return p;
}

// Every level admits its own scope: the directory and its subdirectories for `pub(module)`, the package
// for `pub(package)`, directly, through a transitive import and through a glob import, also one that
// re-exports (`fw::pkgf` names the item `b/fw.spc` glob-imports).
@test
fn levels_admit_their_scope() {
    let p = levels_project();
    p.mkfile("b/fw.spc", "import a::m1 as *;\n");
    p.mkfile(
        "main.spc",
        M"(import b::m4;
import b::fw;
import a::m2;
import a::sub::m3;
import a::m1 as *;
import vendor::v::lib;
fn main() i32 {
    let x = mkf();
    return m4::ok_b() + m2::ok_a() + m3::ok_sub() + a::m1::pkgf() + pkgf() + lib::vpub() + x.p + a::m1::own_file(&x) + fw::pkgf() - 25;
}
)",
    );
    assert(p.compile("main.spc").ok());
}

// Outside its scope each level is rejected, directly, through a transitive import (`a::m1` reached
// through `b::m4`) and through a glob import, with the level in the note; the diagnostics are the same
// at one worker and at every core.
@test
fn levels_reject_outside_their_scope() {
    let p = levels_project();
    p.mkfile(
        "b/m5.spc",
        "import a::m1;\npub fn bad_b() i32 { let s: m1::MS = m1::MS { v: 1 }; return m1::modf() + s.v; }\n",
    );
    p.mkfile(
        "main.spc",
        M"(import b::m4;
import b::m5;
import a::m1 as *;
import vendor::v::lib;
fn main() i32 {
    return m4::ok_b() + m5::bad_b() + a::m1::modf() + modf() + a::m1::filef() + lib::vp();
}
)",
    );
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    let r = cli::superc_in(p.dir(), "build --jobs=1");
    assert(r.exit != 0);
    assert(r_has(&r, "error: no visible item 'modf' in module 'a::m1'", "main.spc:6:46"));
    assert(r.out_has("it is 'pub(module)': visible to the files under 'a' only"));
    assert(r_has(&r, "error: cannot find value 'modf'", "main.spc:6:55"));
    assert(r_has(&r, "error: no visible item 'filef' in module 'a::m1'", "main.spc:6:71"));
    assert(r.out_has("the item is missing, or private to its file"));
    assert(r_has(&r, "error: no visible item 'vp' in module 'lib'", "main.spc:6:86"));
    assert(r.out_has("it is 'pub(package)': visible to the files of its package only"));
    assert(r_has(&r, "error: no visible type 'MS' in the imported module", "b/m5.spc:2:33"));
    assert(r_has(&r, "error: no visible item 'modf' in module 'm1'", "b/m5.spc:2:66"));
    let all = cli::superc_in(p.dir(), "build --jobs=8");
    assert(all.text() == r.text(), "the diagnostics do not depend on the worker count");
}

// A field without a modifier is its file's (`own_file` reads `q`), `pub(module)` its directory's.
@test
fn field_levels() {
    let p = levels_project();
    p.mkfile("main.spc", "import a::m1;\nfn main() i32 {\n    let x = m1::mkf();\n    return x.p + x.m + x.q;\n}\n");
    let r = p.compile("main.spc");
    assert(r.exit != 0);
    assert(r_has(&r, "error: field 'm' is not visible here", "main.spc:4:20"));
    assert(r_has(&r, "error: field 'q' is private", "main.spc:4:26"));
    assert(!r.out_has("'p'"));
    // A literal and the patterns of another file name the field the same way.
    p.mkfile(
        "main.spc",
        "import a::m1 as *;\nfn main() i32 {\n    let y = F { m: 1, p: 2, q: 3 };\n    let z = switch y { F { q, .. } => q, };\n    if let F { q: w, .. } = y { return w; }\n    return z;\n}\n",
    );
    let r2 = p.compile("main.spc");
    assert(r_has(&r2, "error: field 'm' is not visible here", "main.spc:3:17"));
    assert(r_has(&r2, "error: field 'q' is private", "main.spc:3:29"));
    assert(r_has(&r2, "error: field 'q' is private", "main.spc:4:28"));
    assert(r_has(&r2, "error: field 'q' is private", "main.spc:5:16"));
}

// A signature, field type, alias target or bound names no type less visible than its item; a method wider
// than its type is accepted and reaches no further than the type.
@test
fn leaks_and_member_widths() {
    let p = levels_project();
    p.mkfile(
        "a/m6.spc",
        M"(import a::m1;
pub fn leak() m1::MS { return m1::MS { v: 1 }; }
pub(module) fn fine() m1::MS { return m1::MS { v: 1 }; }
pub(package) struct L { pub x: m1::MS, y: m1::MS }
pub(package) type T = m1::MS;
interface Hid {}
pub fn bound<X: Hid>(x: X) {}
pub(module) fn tuple() (i32, m1::MS) { return (1, m1::MS { v: 1 }); }
)",
    );
    p.mkfile("main.spc", "import a::m6;\nfn main() i32 {\n    return 0;\n}\n");
    let r = p.compile("main.spc");
    assert(r.exit != 0);
    assert(r_has(&r, "error: 'm1::MS' is less visible than the pub item that names it", "a/m6.spc:2:15"));
    assert(r.out_has("it is pub(module): widen it, or narrow the item"));
    assert(r_has(&r, "error: 'm1::MS' is less visible than the pub(package) item that names it", "a/m6.spc:4:32"));
    assert(r_has(&r, "error: 'm1::MS' is less visible than the pub(package) item that names it", "a/m6.spc:5:23"));
    assert(r_has(&r, "error: 'Hid' is less visible than the pub item that names it", "a/m6.spc:7:17"));
    assert(r.out_has("it is private to its file"));
    assert(!r.out_has("m6.spc:3:"), "a pub(module) function may name a pub(module) type of its directory");
    assert(!r.out_has("m6.spc:4:45"), "a private field names any type");
    assert(!r.out_has("m6.spc:8:"), "a pub(module) tuple element is not a leak");
    // `pub fn get` of the pub(module) `MS`: no error at the declaration, no reach past the type.
    assert(!r.out_has("m1.spc"));
    p.mkfile("b/m7.spc", "import a::m1;\npub fn far() i32 { return m1::MS::get(&m1::MS { v: 1 }); }\n");
    p.mkfile("main.spc", "import b::m7;\nfn main() i32 {\n    return m7::far();\n}\n");
    let r2 = p.compile("main.spc");
    assert(r_has(&r2, "error: no visible type 'MS' in the imported module", "b/m7.spc:2:31"));
}

// A directory without an index file imports as a module that sees the visible items of every file directly
// in it (not its subdirectories); a name two of its files declare is an error only where it is used.
@test
fn implicit_directory_modules() {
    let p = cli::proj_new();
    p.mkfile(
        "geo/point.spc",
        "pub struct Point { pub x: i32 }\npub fn origin() Point { return Point { x: 0 }; }\npub fn twice(n: i32) i32 { return 2 * n; }\n",
    );
    p.mkfile(
        "geo/line.spc",
        "import geo::point;\npub fn len(a: point::Point, b: point::Point) i32 { return b.x - a.x; }\npub fn twice(n: i32) i32 { return n + n; }\n",
    );
    p.mkfile("geo/sub/deep.spc", "pub fn deep() i32 { return 9; }\n");
    p.mkfile("geo/not-a-module.spc", "this file is skipped\n");
    p.mkfile(
        "main.spc",
        "import geo;\nimport geo as g;\nfn main() i32 {\n    return geo::len(geo::origin(), g::Point { x: 3 }) - 3;\n}\n",
    );
    assert(p.compile("main.spc").ok());
    p.mkfile(
        "main.spc",
        "import geo;\nimport geo as *;\nfn main() i32 {\n    return geo::twice(1) + twice(2) + geo::deep();\n}\n",
    );
    let r = p.compile("main.spc");
    assert(r_has(&r, "error: 'twice' is ambiguous: two files of directory module 'geo' declare it", "main.spc:4:17"));
    assert(r_has(&r, "error: 'twice' is ambiguous: two files of directory module 'geo' declare it", "main.spc:4:28"));
    assert(r_has(&r, "error: no visible item 'deep' in module 'geo'", "main.spc:4:44"));
}

// A project names std's `pub(package)` items only with `std_internals = true`; a call the format sugar
// synthesizes reaches a `pub(package)` std helper without the key.
@test
fn std_internals_and_synthesized_calls() {
    let p = cli::proj_new();
    let root = p.dir();
    cli::copy_std(root);
    let sp = format("{}/sc/std/string.spc", root);
    let s = loader::read_file(sp.as_str()).unwrap();
    let narrowed = s.replace("pub fn sugar_fmt_new() String", "pub(package) fn sugar_fmt_new() String");
    assert(narrowed.as_str() != s.as_str(), "std/string.spc declares sugar_fmt_new");
    p.mkfile("sc/std/string.spc", narrowed.as_str());
    p.mkfile("sc/std/zz/inner.spc", "pub(package) fn secret() i32 { return 7; }\n");
    p.mkfile(
        "src/main.spc",
        "import std::zz::inner;\nfn main() i32 {\n    let n = inner::secret();\n    println(\"{}\", n);\n    return n - 7;\n}\n",
    );
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    let sd = format("{}/sc/std", root);
    let r = cli::superc_env_in(root, "SC_STD_DIR", sd.as_str(), "build");
    assert(r.out_has("error: no visible item 'secret' in module 'inner'"));
    assert(
        r.out_has("unstable std internals, which a project names only with 'std_internals = true' in its build.toml"),
    );
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\nstd_internals = true\n");
    assert(cli::superc_env_in(root, "SC_STD_DIR", sd.as_str(), "build").ok());
    p.mkfile("src/main.spc", "fn main() i32 {\n    let s = sugar_fmt_new();\n    return s.len() as i32;\n}\n");
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    assert(
        cli::superc_env_in(root, "SC_STD_DIR", sd.as_str(), "build").out_has("error: cannot find value 'sugar_fmt_new'"),
    );
}
