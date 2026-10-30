// The target table: its rows against the C environments bindgen models, the axis names against std's
// enums, and the rule that shared code names no target.
import std::platform::fs;
import std::target as stdt;
import bindgen::ctarget as ct;
import bindgen::ctarget_data as data;
import ir::cpu_features as cf;
import module::loader as loader;
import driver::util as dutil;
import target::table as tgt;
import tests::cli_harness as cli;

// The std enums are the target table's axes, name and discriminant: a mismatch fails the build of the
// test suite.
const fn axis_matches(is_isa: bool) bool {
    let vs = tgt::axis_variants(is_isa);
    let ti = if is_isa {
        type_info::<stdt::Arch>()
    } else {
        type_info::<stdt::Platform>()
    };
    if ti.variants.len != vs.len() {
        return false;
    }
    for i in 0..vs.len() {
        let v = ti.variants.get(i);
        if v.name != vs[i] || v.tag != i as i32 {
            return false;
        }
    }
    return true;
}

static_assert(axis_matches(false), "std::target::Platform is the target table's @platform axis");
static_assert(axis_matches(true), "std::target::Arch is the target table's @arch axis");

const fn target_at(i: usize) tgt::Target {
    let t: []tgt::Target = tgt::TARGETS;
    return t[i];
}

// The value of macro `name` in the `#define` lines `predefs`; empty when undefined.
const fn macro_value<'a>(predefs: str<'a>, name: str) str<'a> {
    let mut it = predefs.lines();
    while let Some(line) = it.next() {
        if line.starts_with("#define ") && line.slice(8, line.len()).starts_with(name) {
            let rest = line.slice(8 + name.len(), line.len());
            if rest.starts_with(" ") {
                return rest.slice(1, rest.len());
            }
        }
    }
    return "";
}

// A scratch sysroot every system layout accepts.
fn any_root(p: &cli::Proj, row: data::Row) String {
    p.mkfile("root/usr/include/.keep", "");
    p.mkfile("root/usr/local/include/.keep", "");
    p.mkfile("root/include/.keep", "");
    p.mkfile(format("root/usr/include/{}/.keep", row.dir).as_str(), "");
    p.mkfile(format("root/include/{}/.keep", row.dir).as_str(), "");
    p.mkfile(format("root/{}/include/_mingw.h", row.dir).as_str(), "");
    p.mkfile(format("root/{}/usr/include/.keep", row.dir).as_str(), "");
    return format("{}/root", p.dir());
}

// Each row's C data model, byte order and triple are the ones its C environment predefines, and row `i`
// owns C environment `i`.
@test
fn rows_match_their_c_environments() {
    let rows: []data::Row = data::ROWS;
    let ts: []tgt::Target = tgt::TARGETS;
    assert_eq(rows.len(), ts.len());
    for i in 0..rows.len() {
        let t = target_at(i);
        assert_eq(t.cenv as usize, i);
        assert_eq(t.triple, rows[i].triple);
        let p = cli::proj_new();
        let root = any_root(&p, rows[i]);
        let mut env = ct::CTarget::new();
        assert(ct::c_target(t.os, t.isa, &root, &mut env), t.triple);
        let pd = env.predefs.as_str();
        assert_eq(macro_value(pd, "__SIZEOF_POINTER__"), format("{}", tgt::isa(t.isa).ptr_bytes).as_str());
        assert_eq(macro_value(pd, "__SIZEOF_LONG__"), format("{}", t.long_bytes).as_str());
        let mant = macro_value(pd, "__LDBL_MANT_DIG__");
        let ld: u8 = if mant == "53" {
            64
        } else if mant == "64" {
            80
        } else {
            128
        };
        assert(mant == "53" || mant == "64" || mant == "113", t.triple);
        assert_eq(t.long_double_bits, ld);
        assert_eq(
            macro_value(pd, "__BYTE_ORDER__"),
            if t.big_endian {
                "__ORDER_BIG_ENDIAN__"
            } else {
                "__ORDER_LITTLE_ENDIAN__"
            },
        );
    }
}

// Each (system, instruction set) pair names at most one row, every row's parts are in their tables, its
// baseline holds only features of its instruction set, closed, and none it never has.
@test
fn rows_are_consistent() {
    let t: []tgt::Target = tgt::TARGETS;
    let isas: []tgt::Isa = tgt::ISAS;
    let ccs: []tgt::CallConv = tgt::CALLCONVS;
    let objs: []tgt::ObjFormat = tgt::OBJFORMATS;
    let oses: []tgt::Os = tgt::OSES;
    let dbgs: []tgt::Debug = tgt::DEBUGS;
    for i in 0..t.len() {
        assert_eq(tgt::find(t[i].os, t[i].isa), i as i32);
        assert(t[i].isa as usize < isas.len() && t[i].cc as usize < ccs.len(), t[i].triple);
        assert(t[i].obj as usize < objs.len() && t[i].os as usize < oses.len(), t[i].triple);
        assert(t[i].debug as usize < dbgs.len(), t[i].triple);
        assert(t[i].page_bytes != 0 && (t[i].page_bytes & t[i].page_bytes - 1) == 0, "a page is a power of two");
        assert_eq(cf::close(t[i].features).w[0], t[i].features.w[0]);
        for k in 0..cf::FEATURE_COUNT {
            if cf::has(t[i].features, k) {
                assert_eq(cf::row(k).arch, t[i].isa as i32);
                assert(!cf::has(t[i].never, k), t[i].triple);
            }
        }
    }
    assert_eq(tgt::find(2, 2), -1);
}

@test
fn axis_names_index_their_tables() {
    for is_isa in [false, true] {
        let ns = tgt::axis_names(is_isa);
        for i in 0..ns.len() {
            assert_eq(tgt::axis_index(ns[i], is_isa), i as i32);
        }
        assert_eq(tgt::axis_index("solaris", is_isa), -1);
    }
    assert_eq(tgt::axis_list(false).as_str(), "windows, macos, linux, wasm, ios, or android");
    assert_eq(tgt::axis_list(true).as_str(), "x86_64, aarch64, or wasm32");
}

// Whether `src` holds a string literal that is exactly a name of the `@platform` or `@arch` axis.
fn names_a_target(src: str) bool {
    for is_isa in [false, true] {
        let ns = tgt::axis_names(is_isa);
        for i in 0..ns.len() {
            if src.contains(format("\"{}\"", ns[i]).as_str()) {
                return true;
            }
        }
    }
    return false;
}

// Appends to `out` every `.spc` file under `dir` that names a target, except under `src/target/`.
fn target_names_under(dir: str, out: &mut String) {
    let opened = fs::read_dir(dir);
    assert(opened.is_ok(), dir);
    let mut d = opened.unwrap();
    let mut subdirs = Vector::<String>::new();
    while let Some(Ok(e)) = d.next() {
        let path = format("{}/{}", dir, e.name);
        if e.name.ends_with(".spc") {
            let mut mt: i64 = 0;
            let src = loader::read_file_mt(&path, &mut mt).unwrap();
            if names_a_target(&src) {
                out.push_str(&path);
                out.push_byte(b'\n');
            }
        } else if e.name != "." && e.name != ".." && path.as_str() != "src/target" && dutil::is_dir(&path) {
            subdirs.push(path);
        }
    }
    for i in 0..subdirs.len() {
        target_names_under(&subdirs[i], out);
    }
}

// Shared code reads a target row or part, never a target name: a new target touches only `src/target/`.
@test
fn no_target_name_outside_the_table() {
    let mut found = String::new();
    target_names_under("src", &mut found);
    assert_eq(found.as_str(), "");
}
