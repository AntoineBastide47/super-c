// Refactorings checked before they are offered (parse and, semantically, no added error), applied through
// the session, and structural matching with semantic predicates.
import api::refactor as *;
import api::session as ses;
import api::syntax as syn;
import api::semantic as sem;
import api::errors as *;
import tests::cli_harness as cli;

const MAIN: str = M"(import util;
import other;

fn main() i32 {
    let total = util::add(1, 2) * util::add(3, 4);
    return total - 21;
}
)";

const UTIL: str = M"(import other;

pub fn add(a: i32, b: i32) i32 {
    return a + b - other::zero();
}
)";

const OTHER: str = M"(pub fn zero() i32 {
    return 0;
}
)";

struct Fx {
    pub proj: cli::Proj,
    pub main: String,
    pub util: String,
    pub other: String,
    pub s: ses::Session,
}

@test_init
fn fx() Fx {
    let proj = cli::proj_new();
    proj.mkfile("main.spc", MAIN);
    proj.mkfile("util.spc", UTIL);
    proj.mkfile("other.spc", OTHER);
    let main = format("{}/main.spc", proj.dir());
    let mut s = ses::Session::open_file(main.as_str(), ses::Config::host("std")).unwrap();
    assert(s.check().is_ok(), "checks");
    let mut util = String::new();
    let mut other = String::new();
    for m in s.modules().unwrap() {
        if m.path() == "util" {
            util = String::from_str(m.file());
        }
        if m.path() == "other" {
            other = String::from_str(m.file());
        }
    }
    let real = String::from_str(s.root_file());
    return Fx { proj: proj, main: real, util: util, other: other, s: s };
}

fn errors(s: &mut ses::Session) usize {
    assert(s.check().is_ok(), "checks");
    let mut n: usize = 0;
    for d in s.diagnostics().unwrap() {
        if d.severity() == ses::SEV_ERROR {
            n += 1;
        }
    }
    return n;
}

fn sel(file: &String, start: u32, end: u32) Selection {
    return Selection { file: file.clone(), start: start, end: end };
}

@test
fn organizes_imports(fx: &mut Fx) {
    let mut r = OrganizeImports {};
    let o = prepare(&mut r, &mut fx.s, sel(&fx.main, 0, 0), "", Validation::Semantic).unwrap();
    assert_eq(o.files.len(), 1);
    assert(o.files[0].text.as_str().starts_with("import util;\n\nfn main"), "the unused import is gone");
    let _ = o.edit.apply(&mut fx.s).unwrap();
    assert_eq(errors(&mut fx.s), 0);
}

@test
fn extracts_a_local(fx: &mut Fx) {
    let at = MAIN.find("util::add(3, 4)") as u32;
    let mut r = ExtractLocal {};
    let o = prepare(&mut r, &mut fx.s, sel(&fx.main, at, at + 15), "rhs", Validation::Semantic).unwrap();
    let t = o.files[0].text.as_str();
    assert(
        t.find("    let rhs = util::add(3, 4);\n    let total = util::add(1, 2) * rhs;") >= 0,
        "the local is bound before its statement",
    );
    let _ = o.edit.apply(&mut fx.s).unwrap();
    assert_eq(errors(&mut fx.s), 0);
}

@test
fn changes_a_signature_and_its_calls(fx: &mut Fx) {
    let at = UTIL.find("add(a") as u32;
    let mut r = ChangeSignature {};
    let bad = prepare(&mut r, &mut fx.s, sel(&fx.util, at, at), "0,0", Validation::Syntax);
    assert(bad.unwrap_err().code == Code::InvalidArgument, "a non-permutation rejects");
    let o = prepare(&mut r, &mut fx.s, sel(&fx.util, at, at), "1,0", Validation::Semantic).unwrap();
    let _ = o.edit.apply(&mut fx.s).unwrap();
    assert(
        fx.s.text(fx.util.as_str()).unwrap().unwrap().as_str().find("pub fn add(b: i32, a: i32) i32") >= 0,
        "the parameters swap",
    );
    assert(
        fx.s.text(fx.main.as_str()).unwrap().unwrap().as_str().find("util::add(2, 1) * util::add(4, 3)") >= 0,
        "every call swaps",
    );
    assert_eq(errors(&mut fx.s), 0);
}

@test
fn adds_an_import(fx: &mut Fx) {
    let src = "import util;\n\nfn main() i32 {\n    return zero() + util::add(0, 0);\n}\n";
    let _ = fx.s.set_text(fx.main.as_str(), src);
    assert(errors(&mut fx.s) >= 1, "the name does not resolve");
    let at = src.find("zero") as u32;
    let mut r = AddImport {};
    let o = prepare(&mut r, &mut fx.s, sel(&fx.main, at, at), "other", Validation::Syntax).unwrap();
    assert(
        o.files[0].text.as_str().starts_with("import util;\nimport other;\n"),
        "the import is added after the others",
    );
}

@test
fn implements_interface_members(fx: &mut Fx) {
    let src = "interface Shape {\n    fn area(self: &Self) i32;\n    fn name(self: &Self) i32 {\n        return 0;\n    }\n}\n\nstruct Sq {}\n\nextend Sq as Shape {\n}\n\nfn main() i32 {\n    return 0;\n}\n";
    let _ = fx.s.set_text(fx.main.as_str(), src);
    assert(fx.s.check().is_ok(), "checks");
    let at = src.find("extend Sq") as u32 + 3;
    let mut r = ImplementMembers {};
    let o = prepare(&mut r, &mut fx.s, sel(&fx.main, at, at), "", Validation::Syntax).unwrap();
    let t = o.files[0].text.as_str();
    assert(
        t.find("fn area(self: &Self) i32 {") >= 0 && t.find("fn name(self: &Self) i32 {\n        panic") < 0,
        "only the required method is stubbed",
    );
}

@test
fn moves_an_item(fx: &mut Fx) {
    let at = UTIL.find("add(a") as u32;
    let mut r = MoveItem {};
    let o = prepare(&mut r, &mut fx.s, sel(&fx.util, at, at), fx.other.as_str(), Validation::Semantic).unwrap();
    let _ = o.edit.apply(&mut fx.s).unwrap();
    assert_eq(errors(&mut fx.s), 0);
    let m = fx.s.text(fx.main.as_str()).unwrap().unwrap();
    assert(
        m.as_str().find("other::add(1, 2)") >= 0 && m.as_str().find("import other;") >= 0,
        "the uses follow the item",
    );
    let o2 = fx.s.text(fx.other.as_str()).unwrap().unwrap();
    assert(
        o2.as_str().find("pub fn add(a: i32, b: i32) i32 {\n    return a + b - zero();") >= 0,
        "the item lives in its new module",
    );
}

@test
fn matches_structure_with_semantic_predicates(fx: &mut Fx) {
    let t = syn::tree_of(&mut fx.s, fx.main.as_str()).unwrap();
    let at = UTIL.find("add(a") as u32;
    let key = sem::symbol_at(&fx.s, fx.util.as_str(), at).unwrap().unwrap().key().unwrap();
    let s = &fx.s;
    let file = fx.main.as_str();
    let k = &key;
    let ms = find_all(
        &t,
        |n: syn::Node, m: &mut Match| {
            if calls(s, file, n, k) {
                m.bind("call", n);
                return inside(n, syn::SyntaxKind::Let);
            }
            return false;
        },
    );
    assert_eq(ms.len(), 2);
    assert_eq(ms[0].get(&t, "call").unwrap().text(), "util::add(1, 2)");
    assert(has_type(&fx.s, fx.main.as_str(), ms[1].get(&t, "").unwrap(), "i32"), "a call's type");
}
