// Semantic queries over a checked session: symbols at positions with their stable keys, references, types
// and layouts, outlines, calls, interface relations, and rename.
import api::semantic as *;
import api::session as ses;
import api::syntax as syn;
import api::errors as *;
import tests::cli_harness as cli;

const MAIN: str = M"(import shapes;

fn main() i32 {
    let s = shapes::Square { side: 3 };
    let a = shapes::area(&s);
    let b = shapes::area(&s);
    return a + b - 18;
}
)";

const SHAPES: str = M"(pub interface Shape {
    fn area(self: &Self) i32;
}

/// A square.
pub struct Square {
    pub side: i32,
}

extend Square as Shape {
    pub fn area(self: &Self) i32 {
        return self.side * self.side;
    }
}

pub fn area(s: &Square) i32 {
    return s.area();
}
)";

struct Fx {
    pub proj: cli::Proj,
    pub main: String,
    pub shapes: String,
    pub s: ses::Session,
}

@test_init
fn fx() Fx {
    let proj = cli::proj_new();
    proj.mkfile("main.spc", MAIN);
    proj.mkfile("shapes.spc", SHAPES);
    let main = format("{}/main.spc", proj.dir());
    let mut s = ses::Session::open_file(&main, ses::Config::host("std")).unwrap();
    assert(s.check().is_ok(), "checks");
    let mut real_shapes = String::new();
    for m in s.modules().unwrap() {
        if m.path() == "shapes" {
            real_shapes = String::from_str(m.file());
        }
    }
    let real_main = String::from_str(s.root_file());
    return Fx { proj: proj, main: real_main, shapes: real_shapes, s: s };
}

@test
fn names_what_a_position_refers_to(fx: &mut Fx) {
    let at = MAIN.find("area(&s)") as u32;
    let y = symbol_at(&fx.s, &fx.main, at).unwrap().unwrap();
    assert_eq(y.name(), "area");
    assert(y.kind() == SymbolKind::Function, "a free function");
    assert_eq(y.module_path(), "shapes");
    let l = y.location().unwrap();
    assert(
        l.file.as_str() == fx.shapes.as_str() && SHAPES.slice(l.start as usize, l.end as usize) == "area",
        "declared in shapes",
    );
    assert(y.signature().as_str().starts_with("fn area(s: &Square) i32"), "its head");
    let k = y.key().unwrap();
    assert_eq(k.module.as_str(), "shapes");
    assert_eq(k.owner.as_str(), "");
    assert_eq(k.ordinal, 0);
    let back = resolve(&fx.s, &k).unwrap();
    assert(back.location().unwrap().start == l.start, "the key resolves back");
    let sq = symbol_at(&fx.s, &fx.main, MAIN.find("Square") as u32).unwrap().unwrap();
    assert(sq.kind() == SymbolKind::Struct, "a struct");
    assert_eq(sq.doc().as_str(), "A square.");
    // A method's key names its extend.
    let mat = SHAPES.find("self.side * ") as u32 - 40;
    let mut method = Option::<SymbolKey>::None;
    let ol = outline(&fx.s, &fx.shapes).unwrap();
    for i in 0..ol.len() {
        let e = &ol[i];
        if e.kind == SymbolKind::Method && e.parent >= 0 {
            let m = symbol_at(&fx.s, &fx.shapes, e.name_range.start).unwrap().unwrap();
            if m.key().unwrap().owner.as_str() == "Square as Shape" {
                method = m.key();
            }
        }
    }
    assert(method.is_some(), "the method's key names 'Square as Shape'");
    assert(mat > 0, "offset in range");
}

@test
fn finds_references_and_renames(fx: &mut Fx) {
    let at = SHAPES.find("pub fn area(s: &") as u32 + 7;
    let opts = ses::RequestOptions::none();
    let refs = references_at(&mut fx.s, &fx.shapes, at, true, &opts).unwrap();
    assert_eq(refs.len(), 3);
    assert(refs[0].file.as_str() == fx.main.as_str(), "the uses come first, by file");
    let mut tight = ses::RequestOptions::none();
    tight.result_limit = 8;
    assert(
        references_at(&mut fx.s, &fx.shapes, at, true, &tight).unwrap_err().code == Code::Limit,
        "a result limit applies",
    );
    let bad = rename(&mut fx.s, &fx.shapes, at, "not an ident");
    assert(bad.unwrap_err().code == Code::InvalidArgument, "an invalid name rejects");
    let we = rename(&mut fx.s, &fx.shapes, at, "surface").unwrap();
    assert_eq(we.edits.len(), 3);
    let _ = we.apply(&mut fx.s).unwrap();
    assert(fx.s.check().is_ok(), "checks");
    let mut errors: usize = 0;
    for d in fx.s.diagnostics().unwrap() {
        if d.severity() == ses::SEV_ERROR {
            errors += 1;
        }
    }
    assert_eq(errors, 0);
    assert(fx.s.text(&fx.main).unwrap().unwrap().as_str().find("shapes::surface(&s)") >= 0, "the uses are renamed");
}

@test
fn reads_types_and_layouts(fx: &mut Fx) {
    let at = MAIN.find("let s") as u32 + 4;
    let t = type_at(&fx.s, &fx.main, at).unwrap().unwrap();
    assert_eq(t.display().as_str(), "Square");
    let (size, align) = t.layout().unwrap();
    assert_eq(size, 4);
    assert_eq(align, 4);
    let use_at = MAIN.find("a + b") as u32;
    assert_eq(type_at(&fx.s, &fx.main, use_at).unwrap().unwrap().display().as_str(), "i32");
    assert(hover(&fx.s, &fx.main, use_at).unwrap().unwrap().as_str().find("i32") >= 0, "the hover names the type");
}

@test
fn reads_calls_relations_and_names(fx: &mut Fx) {
    let at = MAIN.find("let a") as u32;
    let calls = calls_from(&fx.s, &fx.main, at).unwrap();
    assert_eq(calls.len(), 2);
    assert_eq(calls[0].callee.name(), "area");
    let names = visible_names(&fx.s, &fx.main, MAIN.find("return") as u32).unwrap();
    let mut seen = false;
    for i in 0..names.len() {
        seen = seen || names[i].as_str() == "a";
    }
    assert(seen, "a local is visible");
    let sq = symbol_at(&fx.s, &fx.main, MAIN.find("Square") as u32).unwrap().unwrap();
    let up = relations(sq, true);
    assert_eq(up.len(), 1);
    let found = find_symbols(&fx.s, "Squ", 10).unwrap();
    assert(found.len() >= 1 && found[0].file.as_str() == fx.shapes.as_str(), "the declaration is found by name");
}

@test
fn finds_references_by_key_and_implementations(fx: &mut Fx) {
    let at = MAIN.find("Square") as u32;
    let key = symbol_at(&fx.s, &fx.main, at).unwrap().unwrap().key().unwrap();
    let opts = ses::RequestOptions::none();
    let refs = references_to(&mut fx.s, &key, false, &opts).unwrap();
    assert(refs.len() >= 2, "the struct's uses in both files");
    let iat = SHAPES.find("Shape {") as u32;
    let impls = implementations(&fx.s, &fx.shapes, iat).unwrap();
    assert_eq(impls.len(), 1);
}
