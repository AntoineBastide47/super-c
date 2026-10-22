// Tests of bindgen's C environment (`src/bindgen/ctarget.spc`). The tables are checked against the
// reference compiler: clang of the pinned major release (`ctarget_data::PINNED_VERSION`). The macro and
// `__has_*` tests run where $SC_CTARGET_CLANG, $CC, `clang` or `cc` (in that order) is such a clang, and
// pass without checking elsewhere; with SC_CTARGET_REQUIRE=1 a missing oracle fails them (CI sets it), as
// does the test of the built-in headers' values. The built-in headers parse with any clang; the directory,
// ABI and discovery tests need no compiler.
import stdlib;
import driver_shim as shim;
import driver::util as dutil;
import module::loader as loader;
import bindgen::ctarget as ct;
import bindgen::ctarget_data as data;
import tests::cli_harness as cli;
import tests::ctarget_universe as univ;

const PINNED: [str<'static>; 5] = [
    "__clang_major__",
    "__clang_minor__",
    "__clang_patchlevel__",
    "__clang_version__",
    "__VERSION__",
];
// Upstream clang's answers whatever the vendor's build (scripts/gen_ctarget.py asks with the same flags): no
// configuration file, and each target's own runtime library, not the build's CLANG_DEFAULT_RTLIB.
const ORACLE_FLAGS: str<'static> = "--no-default-config --rtlib=platform";
// The library builtins Debian's clang packages remove (debian/patches/23-strlcpy_strlcat_warning_removed.diff):
// the tables model upstream clang, so a Debian or Ubuntu oracle is not asked about them.
const DEBIAN_DROPS: [str<'static>; 2] = ["builtin:strlcat", "builtin:strlcpy"];
const KINDS: [str<'static>; 6] = ["feature", "extension", "attribute", "c_attribute", "builtin", "declspec_attribute"];

// The reference compiler the run found: the command (empty: no clang), whether it has the pinned major, and
// whether it is a Debian or Ubuntu build (DEBIAN_DROPS).
struct Oracle {
    pub clang: String,
    pub pinned: bool,
    pub debian: bool,
}

fn run(cmd: str, work: str, out: &mut String) i32 {
    let mut c = String::from_str(cmd);
    let mut w = String::from_str(work);
    let rc = cli::run_with(c.cstr(), null, w.cstr(), null, "");
    *out = cli::read_text(work);
    return rc;
}

// The major release of the pinned clang.
fn pinned_major() str<'static> {
    let v = data::PINNED_VERSION;
    return v.slice(0, v.find_byte(b'.') as usize);
}

fn find_oracle() Oracle {
    let mut o = Oracle { clang: String::new(), pinned: false, debian: false };
    let mut cands = Vector::<String>::new();
    for name in ["SC_CTARGET_CLANG", "CC"] {
        let v = stdlib::get_env(name).unwrap_or(String::new());
        if v.len() != 0 {
            cands.push(v);
        }
    }
    cands.push(String::from_str("clang"));
    cands.push(String::from_str("cc"));
    let mut work = String::from_str(unsafe str::from_cstr(shim::sc_tmpdir()));
    work.format_into("/super-c-ctarget-oracle-{}", unsafe shim::sc_getpid());
    let want = format("#define __clang_major__ {}\n", pinned_major());
    for i in 0..cands.len() {
        let mut out = String::new();
        let cmd = format("{} {} -dM -E -x c /dev/null", cands[i].as_str(), ORACLE_FLAGS);
        if run(cmd.as_str(), work.as_str(), &mut out) != 0 || !out.as_str().contains("#define __clang__ 1") {
            continue;
        }
        let pinned = out.as_str().contains(want.as_str());
        if o.clang.len() == 0 || pinned {
            o.clang = cands[i].clone();
            o.pinned = pinned;
        }
        if pinned {
            break;
        }
    }
    let mut ver = String::new();
    if o.clang.len() != 0 && run(format("{} --version", o.clang.as_str()).as_str(), work.as_str(), &mut ver) == 0 {
        o.debian = ver.as_str().contains("Debian clang") || ver.as_str().contains("Ubuntu clang");
    }
    let mut w = work.clone();
    let _ = unsafe shim::sc_unlink(w.cstr());
    return o;
}

fn is_pinned(name: str) bool {
    let p: []str<'static> = PINNED;
    for i in 0..p.len() {
        if p[i] == name {
            return true;
        }
    }
    return false;
}

// The name a `#define` line defines, with the pinned version macros left out: empty for those and
// for any other line.
fn defined_name(line: str) str {
    if !line.starts_with("#define ") {
        return "";
    }
    let body = line.slice(8, line.len());
    let mut e: usize = 0;
    while e < body.len() && body[e] != b' ' && body[e] != b'(' {
        e += 1;
    }
    let name = body.slice(0, e);
    if is_pinned(name) {
        return "";
    }
    return name;
}

// The `#define` lines of `text`, pinned version macros left out, sorted.
fn define_lines<'a>(text: str<'a>) Vector<str<'a>> {
    let mut v = Vector::<str<'a>>::new();
    let mut it = text.lines();
    while let Some(line) = it.next() {
        if defined_name(line).len() != 0 {
            v.push(line);
        }
    }
    v.sort();
    return v;
}

// Compares the `#define` lines of two dumps: the number of lines only one has. The first few are
// printed under `label`.
fn diff_defines(label: str, ours: str, theirs: str) usize {
    let a = define_lines(ours);
    let b = define_lines(theirs);
    let mut i: usize = 0;
    let mut j: usize = 0;
    let mut n: usize = 0;
    while i < a.len() || j < b.len() {
        let c = if i == a.len() {
            1;
        } else if j == b.len() {
            -1;
        } else {
            a[i].cmp(&b[j]);
        };
        if c == 0 {
            i += 1;
            j += 1;
            continue;
        }
        n += 1;
        if n <= 5 {
            if c < 0 {
                eprintln("{}: only in the table: {}", label, a[i]);
            } else {
                eprintln("{}: only in the reference: {}", label, b[j]);
            }
        }
        if c < 0 {
            i += 1;
        } else {
            j += 1;
        }
    }
    return n;
}

const fn row_at(i: usize) data::Row {
    let rows: []data::Row = data::ROWS;
    return rows[i];
}

// A scratch sysroot for row `row` holding every directory its target looks in; the root of the tree.
fn fake_root(p: &cli::Proj, row: data::Row) String {
    let root = format("{}/root", p.dir());
    if row.target == 1 || row.target == 4 {
        p.mkfile("root/usr/include/.keep", "");
        p.mkfile("root/usr/local/include/.keep", "");
        p.mkfile("root/System/Library/Frameworks/.keep", "");
        p.mkfile("root/System/Library/SubFrameworks/.keep", "");
        p.mkfile("root/Library/Frameworks/.keep", "");
    } else if row.target == 2 || row.target == 5 {
        p.mkfile("root/usr/local/include/.keep", "");
        p.mkfile(format("root/usr/include/{}/.keep", row.dir).as_str(), "");
        p.mkfile("root/include/.keep", "");
        p.mkfile("root/usr/include/.keep", "");
    } else if row.target == 0 {
        p.mkfile(format("root/{}/include/_mingw.h", row.dir).as_str(), "");
        p.mkfile(format("root/{}/usr/include/.keep", row.dir).as_str(), "");
        p.mkfile("root/include/.keep", "");
    } else {
        p.mkfile(format("root/include/{}/.keep", row.dir).as_str(), "");
        p.mkfile("root/include/.keep", "");
    }
    return root;
}

fn dirs_of(t: &ct::CTarget) String {
    let mut s = String::new();
    for i in 0..t.sys_dirs.len() {
        s.push_str(t.sys_dirs[i].as_str());
        s.push_byte(b'\n');
    }
    return s;
}

// The environment of (`target`, `arch`) over a scratch sysroot.
fn table_of(target: i32, arch: i32, t: &mut ct::CTarget) {
    let tmp = cli::proj_new();
    let ri = data::find_row(target, arch);
    assert(ri >= 0, "the pair has a row");
    let root = fake_root(&tmp, row_at(ri as usize));
    assert(ct::c_target(target, arch, root.as_str(), t), row_at(ri as usize).triple);
}

@test
fn system_dirs_follow_the_compiler_order() {
    let p = cli::proj_new();
    let root = format("{}/root", p.dir());
    let r = root.as_str();
    let mut t = ct::CTarget::new();
    let _ = fake_root(&p, row_at(data::find_row(1, 1) as usize));
    assert(ct::c_target(1, 1, r, &mut t), "macos");
    assert_eq(dirs_of(&t).as_str(), format("{}/usr/local/include\n<super-c>\n{}/usr/include\n", r, r).as_str());
    assert_eq(t.frameworks.len(), 3usize);
    assert_eq(t.frameworks[0].as_str(), format("{}/System/Library/Frameworks", r).as_str());
    assert(ct::c_target(4, 0, r, &mut t), "ios");
    assert_eq(dirs_of(&t).as_str(), format("{}/usr/local/include\n<super-c>\n{}/usr/include\n", r, r).as_str());
    let _ = fake_root(&p, row_at(data::find_row(2, 0) as usize));
    assert(ct::c_target(2, 0, r, &mut t), "linux");
    assert_eq(
        dirs_of(&t).as_str(),
        format(
            "<super-c>\n{}/usr/local/include\n{}/usr/include/x86_64-linux-gnu\n{}/include\n{}/usr/include\n",
            r,
            r,
            r,
            r,
        ).as_str(),
    );
    assert_eq(t.frameworks.len(), 0usize);
    let _ = fake_root(&p, row_at(data::find_row(5, 1) as usize));
    assert(ct::c_target(5, 1, format("{}/", r).as_str(), &mut t), "android, trailing slash");
    assert_eq(
        dirs_of(&t).as_str(),
        format(
            "<super-c>\n{}/usr/local/include\n{}/usr/include/aarch64-linux-android\n{}/include\n{}/usr/include\n",
            r,
            r,
            r,
            r,
        ).as_str(),
    );
    let _ = fake_root(&p, row_at(data::find_row(0, 0) as usize));
    assert(ct::c_target(0, 0, r, &mut t), "windows");
    assert_eq(
        dirs_of(&t).as_str(),
        format("<super-c>\n{}/x86_64-w64-mingw32/include\n{}/x86_64-w64-mingw32/usr/include\n{}/include\n", r, r, r).as_str(),
    );
    let _ = fake_root(&p, row_at(data::find_row(3, 2) as usize));
    assert(ct::c_target(3, 2, r, &mut t), "wasm");
    assert_eq(dirs_of(&t).as_str(), format("<super-c>\n{}/include/wasm32-wasip1\n{}/include\n", r, r).as_str());
}

@test
fn every_pair_has_an_environment() {
    let rows: []data::Row = data::ROWS;
    assert_eq(rows.len(), 11usize);
    for i in 0..rows.len() {
        let mut t = ct::CTarget::new();
        table_of(rows[i].target, rows[i].arch, &mut t);
        let builtin = String::from_str(ct::BUILTIN_DIR);
        assert(t.sys_dirs.contains(&builtin), rows[i].triple);
        assert(t.predefs.as_str().contains("#define __clang_major__ "), "the version macros");
        assert(t.predefs.as_str().contains("#define __STDC_VERSION__ 201710L\n"), "the C dialect");
        assert(t.has.len() > 500, "the has table");
        assert(t.headers.len() > 10, "the header list");
        for h in 0..t.headers.len() {
            assert(ct::builtin_header(t.headers[h]).len() > 0, t.headers[h]);
        }
    }
    let mut t = ct::CTarget::new();
    assert(!ct::c_target(2, 2, "/", &mut t), "unknown pair");
    assert(!ct::c_target(9, 0, "/", &mut t), "unknown target");
    assert_eq(ct::builtin_header("nothing.h").len(), 0usize);
}

// True when the environment of (`target`, `arch`) predefines `text` (`NAME VALUE`).
fn fact(target: i32, arch: i32, text: str) bool {
    let mut t = ct::CTarget::new();
    table_of(target, arch, &mut t);
    return t.predefs.as_str().contains(format("#define {}\n", text).as_str());
}

@test
fn predefined_abi_facts() {
    // Sizes and signedness that decide how bindgen maps C types: LP64 on Unix, LLP64 on Windows, ILP32 on wasm.
    for target in [1, 4, 2, 5] {
        for arch in [0, 1] {
            assert(fact(target, arch, "__SIZEOF_LONG__ 8"), "long");
            assert(fact(target, arch, "__SIZEOF_POINTER__ 8"), "pointer");
            assert(fact(target, arch, "__SIZEOF_INT__ 4"), "int");
            assert(fact(target, arch, "__LP64__ 1"), "LP64");
        }
    }
    for arch in [0, 1] {
        assert(fact(0, arch, "__SIZEOF_LONG__ 4"), "windows long");
        assert(fact(0, arch, "__SIZEOF_POINTER__ 8"), "windows pointer");
        assert(fact(0, arch, "__SIZEOF_WCHAR_T__ 2"), "windows wchar_t");
        assert(fact(0, arch, "_WIN64 1"), "windows");
        assert(fact(0, arch, "__MINGW64__ 1"), "mingw");
        assert(!fact(0, arch, "__LP64__ 1"), "windows is not LP64");
    }
    assert(fact(3, 2, "__SIZEOF_LONG__ 4"), "wasm long");
    assert(fact(3, 2, "__SIZEOF_POINTER__ 4"), "wasm pointer");
    assert(fact(3, 2, "__wasm32__ 1"), "wasm32");
    assert(fact(3, 2, "__wasi__ 1"), "wasi");
    assert(fact(3, 2, "_WASI_EMULATED_SIGNAL 1"), "emulated signal");
    assert(fact(1, 1, "__APPLE__ 1"), "apple");
    assert(fact(1, 1, "__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ 110000"), "macOS floor");
    assert(fact(4, 1, "__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__ 130000"), "iOS floor");
    assert(fact(2, 1, "__linux__ 1"), "linux");
    assert(fact(5, 0, "__ANDROID__ 1"), "android");
    assert(fact(1, 0, "__x86_64__ 1"), "x86_64");
    assert(fact(1, 1, "__aarch64__ 1"), "aarch64");
    assert(!fact(1, 1, "__x86_64__ 1"), "no x86_64 on aarch64");
}

// True when the environment of (`target`, `arch`) answers `key` true.
fn answers_yes(target: i32, arch: i32, key: str) bool {
    let mut t = ct::CTarget::new();
    table_of(target, arch, &mut t);
    for i in 0..t.has.len() {
        if t.has[i] == key {
            return true;
        }
    }
    return false;
}

@test
fn has_table_answers_the_sdk_questions() {
    // The questions the macOS SDK headers ask, as the preprocessor passes them on.
    for key in [
        "builtin:__is_target_os",
        "extension:define_target_os_macros",
        "target_os:macos",
        "target_vendor:apple",
        "target_arch:arm64",
        "attribute:ns_error_domain",
        "attribute:__format_arg__",
        "feature:attribute_ns_consumed",
        "builtin:__builtin_memmove",
    ] {
        assert(answers_yes(1, 1, key), key);
    }
    assert(answers_yes(4, 0, "target_environment:simulator"), "simulator");
    assert(answers_yes(4, 0, "target_os:ios"), "ios");
    assert(answers_yes(2, 0, "target_os:linux"), "linux");
    assert(answers_yes(2, 0, "attribute:__cold__"), "glibc attribute");
    assert(!answers_yes(1, 1, "target_os:ios"), "macOS is not iOS");
}

// Clang's own dialects, each a distinct set of predefined macros; the others are aliases.
const STDS: [str<'static>; 12] = [
    "c89",
    "gnu89",
    "c99",
    "gnu99",
    "c11",
    "gnu11",
    "c17",
    "gnu17",
    "c23",
    "gnu23",
    "c2y",
    "gnu2y",
];
// What the build adds to every compile (the manifest's default `cstd` and `-funsigned-char`).
const BUILD_FLAGS: str<'static> = "-D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700 -funsigned-char";

@test
fn c_flags_apply_to_the_predefined_macros() {
    let mut t = ct::CTarget::new();
    table_of(1, 1, &mut t);
    let base = t.predefs.clone();
    assert(ct::apply_c_flags("-std=c11 -DFOO -DBAR=2 -D BAZ -DF(x)=x -UFOO -funsigned-char", &mut t), "flags");
    let p = t.predefs.as_str();
    assert(p.contains("#define __STDC_VERSION__ 201112L\n"), "std");
    assert(p.contains("#define __STRICT_ANSI__ 1\n"), "strict");
    assert(p.contains("#define BAR 2\n") && p.contains("#define BAZ 1\n") && p.contains("#define F(x) x\n"), "-D");
    assert(!p.contains("#define FOO "), "-U");
    assert(p.contains("#define __CHAR_UNSIGNED__ 1\n"), "-funsigned-char");
    // Aliases of one dialect give one result.
    for pair in [
        ("c90", "c89"),
        ("gnu90", "gnu89"),
        ("c18", "c17"),
        ("gnu18", "gnu17"),
        ("c2x", "c23"),
        ("gnu2x", "gnu23"),
    ] {
        let mut a = ct::CTarget::new();
        a.predefs = base.clone();
        let mut b = ct::CTarget::new();
        b.predefs = base.clone();
        assert(ct::apply_c_flags(format("-std={}", pair.0).as_str(), &mut a), pair.0);
        assert(ct::apply_c_flags(format("-std={}", pair.1).as_str(), &mut b), pair.1);
        assert(a.predefs.as_str() == b.predefs.as_str(), pair.0);
    }
    // Anything else is refused and leaves the macros as they were.
    for bad in ["-O2", "-std=c++17", "-std=iso9899:1999", "-Wall", "-D"] {
        let mut u = ct::CTarget::new();
        u.predefs = base.clone();
        assert(!ct::apply_c_flags(bad, &mut u), bad);
        assert(u.predefs.as_str() == base.as_str(), bad);
    }
}

@test
fn c_flags_equal_the_reference_compiler() {
    let o = find_oracle();
    if !oracle_ready(&o) {
        return;
    }
    let tmp = cli::proj_new();
    let work = format("{}/dump.txt", tmp.dir());
    let rows: []data::Row = data::ROWS;
    let stds: []str<'static> = STDS;
    let mut fails: usize = 0;
    for i in 0..rows.len() {
        let mut base = ct::CTarget::new();
        table_of(rows[i].target, rows[i].arch, &mut base);
        // Every dialect on one row of each kind (the type widths, the strict-mode names and the bit width
        // of the target differ between these); a few on the others, to keep the clang runs few.
        let all = rows[i].target == 1 && rows[i].arch == 1 || rows[i].target == 2 && rows[i].arch == 0 || rows[i].target == 0 && rows[i].arch == 0 || rows[i].target == 3;
        for k in 0..stds.len() {
            if !all && stds[k] != "c89" && stds[k] != "c11" && stds[k] != "gnu23" {
                continue;
            }
            let mut t = ct::CTarget::new();
            t.predefs = base.predefs.clone();
            let flags = format("-std={} {}", stds[k], BUILD_FLAGS);
            assert(ct::apply_c_flags(flags.as_str(), &mut t), stds[k]);
            let cmd = format(
                "{} {} --target={}{} {} -dM -E -x c /dev/null",
                o.clang.as_str(),
                ORACLE_FLAGS,
                rows[i].triple,
                rows[i].flags,
                flags.as_str(),
            );
            let mut theirs = String::new();
            assert_eq(run(cmd.as_str(), work.as_str(), &mut theirs), 0);
            let label = format("{} {}", rows[i].triple, stds[k]);
            fails += diff_defines(label.as_str(), t.predefs.as_str(), theirs.as_str());
        }
    }
    assert_eq(fails, 0usize);
}

// The oracle applies: a pinned clang is there. With SC_CTARGET_REQUIRE set a missing one fails the test.
fn oracle_ready(o: &Oracle) bool {
    if o.clang.len() != 0 && o.pinned {
        return true;
    }
    assert(
        stdlib::get_env("SC_CTARGET_REQUIRE").unwrap_or(String::new()).len() == 0,
        "SC_CTARGET_REQUIRE is set and no clang of the pinned major release was found (set SC_CTARGET_CLANG)",
    );
    println("skipped: no clang of the pinned major release (set SC_CTARGET_CLANG)");
    return false;
}

@test
fn predefined_macros_equal_the_reference_compiler() {
    let o = find_oracle();
    if !oracle_ready(&o) {
        return;
    }
    let tmp = cli::proj_new();
    let work = format("{}/dump.txt", tmp.dir());
    let rows: []data::Row = data::ROWS;
    let mut fails: usize = 0;
    for i in 0..rows.len() {
        let mut t = ct::CTarget::new();
        table_of(rows[i].target, rows[i].arch, &mut t);
        let mut theirs = String::new();
        let cmd = format(
            "{} {} --target={}{} -dM -E -x c /dev/null",
            o.clang.as_str(),
            ORACLE_FLAGS,
            rows[i].triple,
            rows[i].flags,
        );
        assert_eq(run(cmd.as_str(), work.as_str(), &mut theirs), 0);
        fails += diff_defines(rows[i].triple, t.predefs.as_str(), theirs.as_str());
    }
    assert_eq(fails, 0usize);
}

// The names the generator asked: the stored canonical ones and, for features, extensions, attributes and
// C attributes, their double-underscore spellings (left out where that is a predefined macro).
fn asked_names(taken: &Map<String, bool>) Vector<String> {
    let mut out = Vector::<String>::new();
    let mut names = univ::NAMES.lines();
    while let Some(n) = names.next() {
        out.push(String::from_str(n));
        let c = n.find_byte(b':') as usize;
        let kind = n.slice(0, c);
        if kind != "feature" && kind != "extension" && kind != "attribute" && kind != "c_attribute" {
            continue;
        }
        let name = n.slice(c + 1, n.len());
        let mut tail: usize = 0;
        for i in 0..name.len() {
            if name[i] == b':' {
                tail = i + 1;
            }
        }
        let last = format("__{}__", name.slice(tail, name.len()));
        if taken.get(&last).is_none() {
            out.push(format("{}:{}__{}__", kind, name.slice(0, tail), name.slice(tail, name.len())));
        }
    }
    return out;
}

// The `#if` source that asks the reference compiler about every `kind:name` of `names`: one
// `"kind:name"` line per true answer. A `target_*` kind is an `__is_target_*` operator.
fn has_source(names: &Vector<String>) String {
    let mut src = String::new();
    for i in 0..names.len() {
        let n = names[i].as_str();
        let c = n.find_byte(b':') as usize;
        let op = if n.starts_with("target_") {
            "__is_";
        } else {
            "__has_";
        };
        src.format_into("#if {}{}({})\n@@\"{}\"\n#endif\n", op, n.slice(0, c), n.slice(c + 1, n.len()), n);
    }
    return src;
}

fn answers(text: str) Map<String, bool> {
    let mut m = Map::<String, bool>::new();
    let mut it = text.lines();
    while let Some(line) = it.next() {
        if line.starts_with("@@\"") && line.ends_with("\"") {
            m.insert(String::from_str(line.slice(3, line.len() - 1)), true);
        }
    }
    return m;
}

fn debian_drops(key: str) bool {
    let d: []str<'static> = DEBIAN_DROPS;
    for i in 0..d.len() {
        if d[i] == key {
            return true;
        }
    }
    return false;
}

@test
fn has_answers_equal_the_reference_compiler() {
    let o = find_oracle();
    if !oracle_ready(&o) {
        return;
    }
    let rows: []data::Row = data::ROWS;
    let tmp = cli::proj_new();
    // Every name the generator asked, true or false: a true name the tables lost shows here.
    let mut taken = Map::<String, bool>::new();
    for i in 0..rows.len() {
        let mut t = ct::CTarget::new();
        table_of(rows[i].target, rows[i].arch, &mut t);
        let mut it = t.predefs.as_str().lines();
        while let Some(line) = it.next() {
            let body = line.slice(8, line.len());
            let mut e: usize = 0;
            while e < body.len() && body[e] != b' ' && body[e] != b'(' {
                e += 1;
            }
            taken.insert(String::from_str(body.slice(0, e)), true);
        }
    }
    let universe = asked_names(&taken);
    tmp.mkfile("has.c", has_source(&universe).as_str());
    let src = format("{}/has.c", tmp.dir());
    let work = format("{}/out.txt", tmp.dir());
    let mut fails: usize = 0;
    for i in 0..rows.len() {
        let cmd = format(
            "{} {} --target={}{} -E -P -x c {}",
            o.clang.as_str(),
            ORACLE_FLAGS,
            rows[i].triple,
            rows[i].flags,
            src.as_str(),
        );
        let mut out = String::new();
        assert_eq(run(cmd.as_str(), work.as_str(), &mut out), 0);
        let truth = answers(out.as_str());
        let mut mine = ct::CTarget::new();
        table_of(rows[i].target, rows[i].arch, &mut mine);
        let mut have = Map::<String, bool>::new();
        for k in 0..mine.has.len() {
            let key = String::from_str(mine.has[k]);
            if truth.get(&key).is_none() && !(o.debian && debian_drops(mine.has[k])) {
                fails += 1;
                eprintln("{}: has table lists {}, the compiler says no", rows[i].triple, mine.has[k]);
            }
            have.insert(key, true);
        }
        for k in 0..universe.len() {
            let key = universe[k].clone();
            if truth.get(&key).is_some() && have.get(&key).is_none() {
                fails += 1;
                eprintln("{}: has table lacks {}", rows[i].triple, universe[k].as_str());
            }
        }
    }
    assert_eq(fails, 0usize);
}

// Every `kind:name` that the `__has_*` operators of the `.h` files below `dir` take, added to `out`.
// Directories named `c++` are C++ library headers and are left out. `depth` bounds the walk.
fn scan_has(dir: str, depth: usize, out: &mut Vector<String>) {
    if depth > 8 {
        return;
    }
    let mut d = String::from_str(dir);
    let dh = unsafe shim::sc_opendir(d.cstr());
    if dh == null {
        return;
    }
    let mut names = Vector::<String>::new();
    loop {
        let e = unsafe shim::sc_readdir(dh);
        if e == null {
            break;
        }
        let nm = unsafe shim::sc_dirent_name(e);
        if unsafe nm[0] == '.' as char {
            continue;
        }
        names.push(unsafe String::from_cstr(nm));
    }
    let _ = unsafe shim::sc_closedir(dh);
    for i in 0..names.len() {
        let n = names[i].as_str();
        let mut child = format("{}/{}", dir, n);
        if unsafe shim::sc_stat_isdir(child.cstr()) == 1 {
            if n != "c++" {
                scan_has(child.as_str(), depth + 1, out);
            }
        } else if n.ends_with(".h") {
            if let Some(text) = loader::read_file(child.as_str()) {
                scan_text(text.as_str(), out);
            }
        }
    }
}

// A letter, digit, underscore, or the colon of a `scope::name`.
const fn is_name_byte(c: u8) bool {
    return c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9' || c == b'_' || c == b':';
}

fn skip_blanks(text: str, i: usize) usize {
    let mut j = i;
    while j < text.len() && (text[j] == b' ' || text[j] == b'\t') {
        j += 1;
    }
    return j;
}

fn scan_text(text: str, out: &mut Vector<String>) {
    let ks: []str<'static> = KINDS;
    let mut at: usize = 0;
    loop {
        let f = text.slice(at, text.len()).find("__has_");
        if f < 0 {
            break;
        }
        let k0 = at + f as usize + 6;
        at = k0;
        let mut i = k0;
        while i < text.len() && is_name_byte(text[i]) && text[i] != b':' {
            i += 1;
        }
        let kind = text.slice(k0, i);
        let mut known = false;
        for j in 0..ks.len() {
            known = known || ks[j] == kind;
        }
        i = skip_blanks(text, i);
        if !known || i >= text.len() || text[i] != b'(' {
            continue;
        }
        let n0 = skip_blanks(text, i + 1);
        let mut e = n0;
        while e < text.len() && is_name_byte(text[e]) {
            e += 1;
        }
        if e > n0 {
            out.push(format("{}:{}", kind, text.slice(n0, e)));
        }
    }
}

// The environment of the running system found by discovery; false (after a note) where the host has
// no C library tree to find: wasm and Android hosts.
fn host_target(t: &mut ct::CTarget) bool {
    let target = unsafe shim::sc_host_platform();
    let arch = unsafe shim::sc_host_arch();
    if target == 3 || target == 5 {
        println("skipped: no C toolchain to find on this host");
        return false;
    }
    assert(ct::c_target(target, arch, "", t), "the host's sysroot is found");
    return true;
}

@test
fn sysroot_discovery_finds_the_host_headers() {
    let mut t = ct::CTarget::new();
    if !host_target(&mut t) {
        return;
    }
    assert(t.sys_dirs.len() >= 2, "the built-in directory and a system one");
    for i in 0..t.sys_dirs.len() {
        if t.sys_dirs[i].as_str() != ct::BUILTIN_DIR {
            let mut d = t.sys_dirs[i].clone();
            assert(unsafe shim::sc_stat_isdir(d.cstr()) == 1, d.as_str());
        }
    }
    for i in 0..t.frameworks.len() {
        let mut d = t.frameworks[i].clone();
        assert(unsafe shim::sc_stat_isdir(d.cstr()) == 1, d.as_str());
    }
}

@test
fn host_headers_use_only_known_has_names() {
    let o = find_oracle();
    let mut t = ct::CTarget::new();
    if !o.pinned || !host_target(&mut t) {
        // Another release answers differently: nothing to enforce.
        return;
    }
    let mut keys = Vector::<String>::new();
    for i in 0..t.sys_dirs.len() {
        if t.sys_dirs[i].as_str() != ct::BUILTIN_DIR {
            scan_has(t.sys_dirs[i].as_str(), 0, &mut keys);
        }
    }
    for i in 0..t.frameworks.len() {
        scan_has(t.frameworks[i].as_str(), 0, &mut keys);
    }
    keys.sort();
    keys.dedup();
    let tmp = cli::proj_new();
    tmp.mkfile("has.c", has_source(&keys).as_str());
    let work = format("{}/out.txt", tmp.dir());
    let mut out = String::new();
    assert_eq(
        run(
            format("{} {} -E -P -x c {}/has.c", o.clang.as_str(), ORACLE_FLAGS, tmp.dir()).as_str(),
            work.as_str(),
            &mut out,
        ),
        0,
    );
    let truth = answers(out.as_str());
    let mut mine = Map::<String, bool>::new();
    for i in 0..t.has.len() {
        mine.insert(String::from_str(t.has[i]), true);
    }
    let mut missing: usize = 0;
    for i in 0..keys.len() {
        if truth.get(&keys[i]).is_some() && mine.get(&keys[i]).is_none() {
            missing += 1;
            eprintln("the host headers test {}: the compiler says yes, the table lacks it", keys[i].as_str());
        }
    }
    assert_eq(missing, 0usize);
}

// Writes the built-in headers of `t` under `<root>/hdr` and returns the `-isystem` flags of the
// built-in directory followed, when `hosted`, by the target's C library directories.
fn isystem_flags(p: &cli::Proj, t: &ct::CTarget, hosted: bool) String {
    for i in 0..t.headers.len() {
        let name = t.headers[i];
        p.mkfile(format("hdr/{}", name).as_str(), ct::builtin_header(name));
    }
    let mut flags = format("-nostdinc -isystem {}/hdr", p.dir());
    if hosted {
        for i in 0..t.sys_dirs.len() {
            if t.sys_dirs[i].as_str() != ct::BUILTIN_DIR {
                flags.format_into(" -isystem {}", t.sys_dirs[i].as_str());
            }
        }
    }
    return flags;
}

// The reference compiler of an Apple host links only against an SDK; the one discovery found.
fn sdk_flag(t: &ct::CTarget) String {
    if unsafe shim::sc_host_platform() != 1 {
        return String::new();
    }
    for i in 0..t.sys_dirs.len() {
        let inc = t.sys_dirs[i].as_str();
        if inc.ends_with("/usr/include") {
            return format(" -isysroot {}", inc.slice(0, inc.len() - "/usr/include".len()));
        }
    }
    return String::new();
}

// Whether built-in header `name` includes the C library's headers (math.h, complex.h, stdlib.h).
const fn needs_libc(name: str) bool {
    return name == "tgmath.h" || name == "mm_malloc.h" || name.ends_with("intrin.h") && name != "mmintrin.h";
}

@test
fn builtin_headers_parse_as_c() {
    let o = find_oracle();
    let mut t = ct::CTarget::new();
    if o.clang.len() == 0 || !host_target(&mut t) {
        println("skipped: no clang or no host sysroot");
        return;
    }
    let p = cli::proj_new();
    for hosted in [false, true] {
        let flags = isystem_flags(&p, &t, hosted);
        // One translation unit that includes every header in turn.
        let mut src = String::new();
        for i in 0..t.headers.len() {
            if hosted || !needs_libc(t.headers[i]) {
                src.format_into("#include <{}>\n", t.headers[i]);
            }
        }
        p.mkfile(format("all{}.c", hosted as i32).as_str(), src.as_str());
        let files = format(" {}/all{}.c", p.dir(), hosted as i32);
        let cmd = format(
            "{} {}{} -fsyntax-only -Wall -Werror -Wno-missing-sysroot{}",
            o.clang.as_str(),
            flags.as_str(),
            if hosted {
                "";
            } else {
                " -ffreestanding";
            },
            files.as_str(),
        );
        let mut out = String::new();
        let rc = run(cmd.as_str(), format("{}/parse.txt", p.dir()).as_str(), &mut out);
        if rc != 0 {
            eprintln("{}", out.as_str());
        }
        assert_eq(rc, 0);
    }
}

// The x86_64 headers (intrin.h included) parse over a mingw-w64 tree and add no declaration the tree
// lacks: parsed with the C library's windows.h. Needs a mingw-w64 tree to find.
@test
fn builtin_headers_parse_for_windows() {
    let o = find_oracle();
    let mut t = ct::CTarget::new();
    if o.clang.len() == 0 || !ct::c_target(0, 0, "", &mut t) {
        return;
    }
    let p = cli::proj_new();
    let flags = isystem_flags(&p, &t, true);
    let mut src = String::from_str("#include <windows.h>\n#include <intrin.h>\n");
    for i in 0..t.headers.len() {
        src.format_into("#include <{}>\n", t.headers[i]);
    }
    p.mkfile("windows.c", src.as_str());
    let files = format(" {}/windows.c", p.dir());
    let cmd = format(
        "{} --no-default-config --target=x86_64-w64-mingw32 {} -fsyntax-only -Wno-missing-sysroot{}",
        o.clang.as_str(),
        flags.as_str(),
        files.as_str(),
    );
    let mut out = String::new();
    let rc = run(cmd.as_str(), format("{}/parse.txt", p.dir()).as_str(), &mut out);
    if rc != 0 {
        eprintln("{}", out.as_str());
    }
    assert_eq(rc, 0);
}

// C23's `va_start(ap)` has no named parameter to pass on; C17 still needs the two arguments.
@test
fn stdarg_accepts_the_c23_va_start() {
    let o = find_oracle();
    let mut t = ct::CTarget::new();
    if o.clang.len() == 0 || !host_target(&mut t) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "va.c",
        "#include <stdarg.h>\nint f(int n, ...) { va_list ap; va_start(ap); va_end(ap); return n; }\nint g(int n, ...) { va_list ap; va_start(ap, n); va_end(ap); return n; }\n",
    );
    let flags = isystem_flags(&p, &t, false);
    let mut out = String::new();
    let c23 = format("{} {} -std=c23 -ffreestanding -fsyntax-only {}/va.c", o.clang.as_str(), flags.as_str(), p.dir());
    assert_eq(run(c23.as_str(), format("{}/va.txt", p.dir()).as_str(), &mut out), 0);
    let c17 = format("{} {} -std=c17 -ffreestanding -fsyntax-only {}/va.c", o.clang.as_str(), flags.as_str(), p.dir());
    assert(run(c17.as_str(), format("{}/va.txt", p.dir()).as_str(), &mut out) != 0, "C17 refuses it");
}

// The values the headers give, printed one per line.
const VALUES: str<'static> = M"(int printf(const char *, ...);
#include <stddef.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdalign.h>
#include <stdint.h>
#include <limits.h>
#include <float.h>
#include <stdatomic.h>
#define S(x) printf("%s = %llu\n", #x, (unsigned long long)(x))
#define D(x) printf("%s = %lld\n", #x, (long long)(x))
#define F(x) printf("%s = %.21Lg\n", #x, (long double)(x))
struct pad { char c; long double ld; };
int main(void) {
    S(sizeof(size_t)); S(sizeof(ptrdiff_t)); S(sizeof(wchar_t)); S(sizeof(max_align_t)); S(alignof(max_align_t));
    S(sizeof(va_list)); S(offsetof(struct pad, ld)); S((size_t)NULL);
    D(true); D(false); D(__bool_true_false_are_defined); D(__alignas_is_defined);
    S(sizeof(int8_t)); S(sizeof(int16_t)); S(sizeof(int32_t)); S(sizeof(int64_t));
    S(sizeof(int_least8_t)); S(sizeof(int_least16_t)); S(sizeof(int_least32_t)); S(sizeof(int_least64_t));
    S(sizeof(int_fast8_t)); S(sizeof(int_fast16_t)); S(sizeof(int_fast32_t)); S(sizeof(int_fast64_t));
    S(sizeof(intptr_t)); S(sizeof(intmax_t)); D((uintptr_t)-1 > 0); D((uint_fast16_t)-1 > 0);
    D(INT8_MIN); D(INT16_MIN); D(INT32_MIN); D(INT64_MIN); D(INT8_MAX); D(INT16_MAX); D(INT32_MAX); D(INT64_MAX);
    S(UINT8_MAX); S(UINT16_MAX); S(UINT32_MAX); S(UINT64_MAX);
    D(INT_LEAST8_MIN); D(INT_LEAST16_MIN); D(INT_LEAST32_MIN); D(INT_LEAST64_MIN); D(INT_LEAST8_MAX); D(INT_LEAST64_MAX);
    S(UINT_LEAST8_MAX); S(UINT_LEAST16_MAX); S(UINT_LEAST32_MAX); S(UINT_LEAST64_MAX);
    D(INT_FAST8_MIN); D(INT_FAST16_MIN); D(INT_FAST32_MIN); D(INT_FAST64_MIN); D(INT_FAST16_MAX); D(INT_FAST32_MAX);
    S(UINT_FAST8_MAX); S(UINT_FAST16_MAX); S(UINT_FAST32_MAX); S(UINT_FAST64_MAX);
    D(INTPTR_MIN); D(INTPTR_MAX); S(UINTPTR_MAX); D(INTMAX_MIN); D(INTMAX_MAX); S(UINTMAX_MAX);
    D(PTRDIFF_MIN); D(PTRDIFF_MAX); S(SIZE_MAX); D(SIG_ATOMIC_MIN); D(SIG_ATOMIC_MAX);
    D(WCHAR_MIN); D(WCHAR_MAX); D(WINT_MIN); S(WINT_MAX);
    D(INT8_C(7)); D(INT64_C(7)); S(UINT32_C(7)); S(UINTMAX_C(7)); S(sizeof(INT64_C(7))); S(sizeof(UINT8_C(7)));
    D(CHAR_BIT); D(CHAR_MIN); D(CHAR_MAX); D(SCHAR_MIN); D(SCHAR_MAX); S(UCHAR_MAX);
    D(SHRT_MIN); D(SHRT_MAX); S(USHRT_MAX); D(INT_MIN); D(INT_MAX); S(UINT_MAX);
    D(LONG_MIN); D(LONG_MAX); S(ULONG_MAX); D(LLONG_MIN); D(LLONG_MAX); S(ULLONG_MAX);
    D(FLT_RADIX); D(FLT_EVAL_METHOD); D(FLT_ROUNDS); D(DECIMAL_DIG);
    D(FLT_MANT_DIG); D(DBL_MANT_DIG); D(LDBL_MANT_DIG); D(FLT_DIG); D(DBL_DIG); D(LDBL_DIG);
    D(FLT_MIN_EXP); D(DBL_MIN_EXP); D(LDBL_MIN_EXP); D(FLT_MIN_10_EXP); D(DBL_MIN_10_EXP); D(LDBL_MIN_10_EXP);
    D(FLT_MAX_EXP); D(DBL_MAX_EXP); D(LDBL_MAX_EXP); D(FLT_MAX_10_EXP); D(DBL_MAX_10_EXP); D(LDBL_MAX_10_EXP);
    F(FLT_MAX); F(DBL_MAX); F(LDBL_MAX); F(FLT_EPSILON); F(DBL_EPSILON); F(LDBL_EPSILON);
    F(FLT_MIN); F(DBL_MIN); F(LDBL_MIN); F(FLT_TRUE_MIN); F(DBL_TRUE_MIN); F(LDBL_TRUE_MIN);
    D(FLT_DECIMAL_DIG); D(DBL_DECIMAL_DIG); D(LDBL_DECIMAL_DIG); D(FLT_HAS_SUBNORM); D(LDBL_HAS_SUBNORM);
    D(ATOMIC_BOOL_LOCK_FREE); D(ATOMIC_CHAR_LOCK_FREE); D(ATOMIC_INT_LOCK_FREE); D(ATOMIC_LLONG_LOCK_FREE);
    D(ATOMIC_POINTER_LOCK_FREE); S(sizeof(atomic_int)); S(sizeof(atomic_flag)); S(sizeof(atomic_size_t));
    S(sizeof(memory_order)); D(memory_order_seq_cst);
    atomic_int a; atomic_init(&a, 3); D(atomic_fetch_add(&a, 4)); D(atomic_load(&a));
    return 0;
})";

@test
fn builtin_headers_give_the_compilers_values() {
    // The headers read the pinned release's predefined macros (`__INT8_C` is newer than clang 18).
    let o = find_oracle();
    let mut t = ct::CTarget::new();
    if !oracle_ready(&o) || !host_target(&mut t) {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("values.c", VALUES);
    let prog = format("{}/values.c", p.dir());
    let work = format("{}/run.txt", p.dir());
    for hosted in [false, true] {
        let mode = if hosted {
            "";
        } else {
            " -ffreestanding";
        };
        let cflags = format("{}{}", mode, sdk_flag(&t));
        let ours_flags = isystem_flags(&p, &t, hosted);
        let sys = format("{}/sys{}", p.dir(), hosted as i32);
        let our = format("{}/our{}", p.dir(), hosted as i32);
        let mut out = String::new();
        let rc = run(
            format("{}{} -Wno-missing-sysroot -o {} {}", o.clang.as_str(), cflags.as_str(), sys.as_str(), prog.as_str()).as_str(),
            work.as_str(),
            &mut out,
        );
        if rc != 0 {
            eprintln("{}", out.as_str());
        }
        assert_eq(rc, 0);
        let rc2 = run(
            format(
                "{}{} {} -Wno-missing-sysroot -o {} {}",
                o.clang.as_str(),
                cflags.as_str(),
                ours_flags.as_str(),
                our.as_str(),
                prog.as_str(),
            ).as_str(),
            work.as_str(),
            &mut out,
        );
        if rc2 != 0 {
            eprintln("{}", out.as_str());
        }
        assert_eq(rc2, 0);
        let mut want = String::new();
        let mut got = String::new();
        assert_eq(run(sys.as_str(), work.as_str(), &mut want), 0);
        assert_eq(run(our.as_str(), work.as_str(), &mut got), 0);
        assert(want.len() > 1000, "the program printed its table");
        let mut wi = want.as_str().lines();
        let mut gi = got.as_str().lines();
        let mut bad: usize = 0;
        loop {
            let w = wi.next();
            let g = gi.next();
            if w.is_none() && g.is_none() {
                break;
            }
            if w != g {
                bad += 1;
                eprintln("{}: system '{}', built-in '{}'", mode, w.unwrap_or("(none)"), g.unwrap_or("(none)"));
            }
        }
        assert_eq(bad, 0usize);
    }
}

// SDKROOT, DEVELOPER_DIR, ANDROID_NDK_HOME, WASI_SDK_PATH and a mingw-w64 toolchain in PATH each locate
// a sysroot.
@test
fn sysroot_discovery_reads_the_environment() {
    let p = cli::proj_new();
    let mut t = ct::CTarget::new();
    p.mkfile("sdk/usr/include/.keep", "");
    {
        let _g = cli::set_env("SDKROOT", format("{}/sdk", p.dir()).as_str());
        assert(ct::c_target(1, 1, "", &mut t), "SDKROOT");
        assert_eq(t.sys_dirs[1].as_str(), format("{}/sdk/usr/include", p.dir()).as_str());
        // iOS ignores it, as `xcrun --sdk` does: the macOS SDK is not an iOS one.
        if ct::c_target(4, 1, "", &mut t) {
            assert(!t.sys_dirs[1].as_str().starts_with(p.dir()), "SDKROOT does not name an iOS SDK");
        }
    }
    if unsafe shim::sc_host_platform() == 1 {
        for sdk in ["MacOSX", "iPhoneOS", "iPhoneSimulator"] {
            p.mkfile(format("dev/Platforms/{}.platform/Developer/SDKs/{}.sdk/usr/include/.keep", sdk, sdk).as_str(), "");
        }
        let _s = cli::set_env("SDKROOT", "");
        let _d = cli::set_env("DEVELOPER_DIR", format("{}/dev", p.dir()).as_str());
        let want = [(1, 1, "MacOSX"), (4, 1, "iPhoneOS"), (4, 0, "iPhoneSimulator")];
        for w in want {
            assert(ct::c_target(w.0, w.1, "", &mut t), w.2);
            assert_eq(
                t.sys_dirs[1].as_str(),
                format("{}/dev/Platforms/{}.platform/Developer/SDKs/{}.sdk/usr/include", p.dir(), w.2, w.2).as_str(),
            );
        }
    }
    p.mkfile("wasi/share/wasi-sysroot/include/wasm32-wasip1/.keep", "");
    p.mkfile("wasi/share/wasi-sysroot/include/.keep", "");
    {
        let _g = cli::set_env("WASI_SDK_PATH", format("{}/wasi", p.dir()).as_str());
        assert(ct::c_target(3, 2, "", &mut t), "WASI_SDK_PATH");
        assert_eq(t.sys_dirs.len(), 3usize);
        assert_eq(t.sys_dirs[2].as_str(), format("{}/wasi/share/wasi-sysroot/include", p.dir()).as_str());
    }
    {
        let _g = cli::set_env("ANDROID_NDK_HOME", format("{}/ndk", p.dir()).as_str());
        assert(!ct::c_target(5, 1, "", &mut t), "an NDK with no sysroot");
        let mut llvm = String::new();
        assert(dutil::ndk_llvm(&mut llvm), "the NDK is known");
        let rel = llvm.as_str().slice(p.dir().len() + 1, llvm.len());
        p.mkfile(format("{}/sysroot/usr/include/aarch64-linux-android/.keep", rel).as_str(), "");
        p.mkfile(format("{}/sysroot/usr/include/.keep", rel).as_str(), "");
        assert(ct::c_target(5, 1, "", &mut t), "ANDROID_NDK_HOME");
        assert_eq(t.sys_dirs.len(), 3usize);
    }
    p.mkfile("mingw/bin/x86_64-w64-mingw32-gcc", "");
    p.mkfile("mingw/x86_64-w64-mingw32/include/_mingw.h", "");
    {
        let _g = cli::set_env("PATH", format("{}/mingw/bin", p.dir()).as_str());
        let _c = cli::set_env("CC", "");
        assert(ct::c_target(0, 0, "", &mut t), "a mingw-w64 toolchain in PATH");
        assert_eq(t.sys_dirs.len(), 2usize);
        assert(t.sys_dirs[1].as_str().ends_with("/mingw/x86_64-w64-mingw32/include"), t.sys_dirs[1].as_str());
        assert(!ct::c_target(0, 1, "", &mut t), "no aarch64 toolchain in PATH");
    }
}
