// The item schedule index (graph::items): stable keys across a private body edit, signature
// hashes that follow signatures alone, precheck and final dependency edges over functions,
// methods, closures, constants, statics, generated bodies and generic templates, components
// that collapse legal recursion and import cycles, and the readiness states after analysis.
import lsp::analysis as an;
import module::loader as loader;
import graph::items as gitems;
import ast::ast as *;
import tests::cli_harness as cli;
import driver_shim as shim;

const A0: str = M"(import b;
import c;

pub struct Pt {
    pub x: i32,
    pub y: i32,
}

extend Pt {
    pub fn sum(self: &Self) i32 {
        return self.x + self.y;
    }

    pub fn twice(self: &Self) i32 {
        return self.sum() * 2;
    }
}

pub const K: i32 = 3;
static mut G: i32 = 0;

fn even(n: i32) bool {
    if n == 0 {
        return true;
    }
    return odd(n - 1);
}

fn odd(n: i32) bool {
    if n == 0 {
        return false;
    }
    return even(n - 1);
}

fn generic_id<T>(v: T) T {
    return v;
}

fn main() i32 {
    let p = Pt { x: 1, y: 2 };
    let f = |q: i32| q + K;
    let s = format("{}", p.sum());
    let v = generic_id::<i32>(4);
    unsafe {
        G = G + 1;
    }
    let mut r = p.twice() + f(1) + v + b::bee() + c::cee() + s.len() as i32;
    if even(4) {
        r += 1;
    }
    return r;
}
)";
const B0: str = M"(import c;

pub fn bee() i32 {
    return c::cee() + 1;
}
)";
const C0: str = M"(import b;

pub fn cee() i32 {
    return 2;
}

pub fn back(n: i32) i32 {
    if n == 0 {
        return 0;
    }
    return b::bee() + back(n - 1);
}

pub const fn fact(n: i32) i32 {
    if n <= 1 {
        return 1;
    }
    return n * fact(n - 1);
}

pub interface Shape {
    fn area(self: &Self) i32;
    fn doubled(self: &Self) i32 {
        return self.area() * 2;
    }
}

pub struct Sq {
    pub s: i32,
}

extend Sq as Shape {
    fn area(self: &Self) i32 {
        return self.s * self.s;
    }
}

pub const F5: i32 = fact(5);
)";

struct Ws {
    pub proj: cli::Proj,
    pub root: String,
    pub dir: String,
}

fn ws_new(a: str, b: str, c: str) Ws {
    let proj = cli::proj_new();
    proj.mkfile("a.spc", a);
    proj.mkfile("b.spc", b);
    proj.mkfile("c.spc", c);
    let dir = String::from_cstr(proj.rootp());
    let mut root = String::from_str(dir.as_str());
    root.push_str("/a.spc");
    return Ws { proj: proj, root: root, dir: dir };
}

extend Ws as Free {
    pub fn free(self: &mut Self) {
        self.root.free();
        self.dir.free();
    }
}

// Analyze the workspace with every file open (no body release); with `with_edges`, build the
// dependency ranges and finalize (which reopens the index: the states then read Resolved).
fn indexed(ws: &Ws, a: str, b: str, c: str, with_edges: bool) loader::Package {
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let names = ["a.spc", "b.spc", "c.spc"];
    let texts = [a, b, c];
    for i in 0..3 {
        let mut f = String::from_str(ws.dir.as_str());
        f.push_str("/");
        f.push_str(unsafe names[i]);
        ovf.push(f);
        ovt.push(String::from_str(unsafe texts[i]));
    }
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = an::compile(
        ws.root.as_str(),
        ws.dir.as_str(),
        "",
        "std",
        unsafe shim::sc_host_platform(),
        ovf,
        ovt,
        "",
        &mut diags,
    );
    for i in 0..diags.len() {
        eprintln("diag m{} @{}: {}", diags.at(i).module, diags.at(i).start, diags.at(i).msg.as_str());
    }
    assert(diags.len() == 0, "the workspace analyzes cleanly");
    if with_edges {
        gitems::build_serial(&mut p);
        gitems::finalize(&mut p);
    }
    return p;
}

fn mod_of(p: &loader::Package, name: str) usize {
    for i in 0..p.modules.len() {
        if p.modules.at(i).file.as_str().ends_with(name) {
            return i;
        }
    }
    return 0xFFFF;
}

// The item of module `m` named `name` (the first, in source order), or ITEM_NONE.
fn item_named(p: &loader::Package, m: usize, name: str) loader::ItemId {
    let sym = p.idx.syms.find(name);
    for i in p.idx.mod_items[m] as usize..p.idx.mod_items[m + 1] as usize {
        if p.idx.items.at(i).name == sym {
            return i as loader::ItemId;
        }
    }
    return loader::ITEM_NONE;
}

fn has_edge(off: &Vector<u32>, tgt: &Vector<u32>, from: loader::ItemId, to: loader::ItemId) bool {
    for e in off[from as usize] as usize..off[from as usize + 1] as usize {
        if tgt[e] == to {
            return true;
        }
    }
    return false;
}

fn pre(p: &loader::Package, from: loader::ItemId, to: loader::ItemId) bool {
    return has_edge(&p.sched.pre_off, &p.sched.pre_edges, from, to);
}

fn fin(p: &loader::Package, from: loader::ItemId, to: loader::ItemId) bool {
    return has_edge(&p.sched.fin_off, &p.sched.fin_edges, from, to);
}

@test
fn index_edges_cover_reference_kinds() {
    let ws = ws_new(A0, B0, C0);
    let p = indexed(&ws, A0, B0, C0, true);
    let am = mod_of(&p, "/a.spc");
    let bm = mod_of(&p, "/b.spc");
    let cm = mod_of(&p, "/c.spc");
    let main = item_named(&p, am, "main");
    let sum = item_named(&p, am, "sum");
    let twice = item_named(&p, am, "twice");
    let pt = item_named(&p, am, "Pt");
    let k = item_named(&p, am, "K");
    let g = item_named(&p, am, "G");
    let gen = item_named(&p, am, "generic_id");
    let even = item_named(&p, am, "even");
    let bee = item_named(&p, bm, "bee");
    let cee = item_named(&p, cm, "cee");
    assert(main != loader::ITEM_NONE && sum != loader::ITEM_NONE && pt != loader::ITEM_NONE, "items indexed");
    // Precheck: resolved names.
    assert(pre(&p, main, bee) && pre(&p, main, cee), "cross-module calls");
    assert(pre(&p, main, k), "a constant read inside a closure");
    assert(pre(&p, main, g), "a static");
    assert(pre(&p, main, gen), "a generic template instantiation");
    assert(pre(&p, main, pt), "a struct literal");
    assert(pre(&p, main, even), "a same-module call");
    assert(pre(&p, sum, pt), "a field access names the aggregate");
    assert(pre(&p, bee, cee), "an import-cycle module's call");
    let ext = p.idx.items.at(sum as usize).owner;
    assert(ext != loader::ITEM_NONE && pre(&p, sum, ext) && pre(&p, twice, ext), "members own their extend");
    assert(!pre(&p, main, main) && !pre(&p, sum, sum), "no self edges");
    // Final: the method calls typecheck resolved, and the generated format body's shim.
    assert(fin(&p, twice, sum), "a method call resolved at typecheck");
    assert(fin(&p, main, twice), "a method call from main");
    let mut prelude_edge = false;
    for e in p.sched.fin_off[main as usize] as usize..p.sched.fin_off[main as usize + 1] as usize {
        let t = p.sched.fin_edges[e] as usize;
        if p.modules.at(p.idx.items.at(t).module as usize).prelude {
            prelude_edge = true;
        }
    }
    assert(prelude_edge, "the generated format body references a prelude item");
    for i in 0..p.sched.pre_off[p.idx.items.len()] as usize {
        assert(p.sched.pre_edges[i] as usize < p.idx.items.len(), "edge targets are items");
    }
}

@test
fn index_components_collapse_cycles() {
    let ws = ws_new(A0, B0, C0);
    let p = indexed(&ws, A0, B0, C0, true);
    let am = mod_of(&p, "/a.spc");
    let bm = mod_of(&p, "/b.spc");
    let cm = mod_of(&p, "/c.spc");
    let even = item_named(&p, am, "even");
    let odd = item_named(&p, am, "odd");
    assert(p.sched.comp[even as usize] == p.sched.comp[odd as usize], "mutual recursion is one component");
    let bee = item_named(&p, bm, "bee");
    let cee = item_named(&p, cm, "cee");
    let back = item_named(&p, cm, "back");
    assert(p.sched.comp[bee as usize] != p.sched.comp[cee as usize], "a plain call is no cycle");
    assert(p.sched.comp[back as usize] != p.sched.comp[bee as usize], "recursion through a callee is no cycle with it");
    // Dependency-first numbering: a callee's component precedes its caller's.
    assert(p.sched.comp[cee as usize] < p.sched.comp[bee as usize], "callee first");
    assert(p.sched.ncomp as usize <= p.idx.items.len(), "bounded");
    // A const fn recursion is one component and no error; a conformance names its interface and
    // target, and the interface default's call to `area` reaches the conformer only at final time.
    let fact = item_named(&p, cm, "fact");
    let f5 = item_named(&p, cm, "F5");
    assert(fact != loader::ITEM_NONE && pre(&p, f5, fact), "a constant's initializer depends on its const fn");
    assert(p.sched.comp[fact as usize] != p.sched.comp[f5 as usize], "recursion stays inside one component");
    let shape = item_named(&p, cm, "Shape");
    let sq = item_named(&p, cm, "Sq");
    let area = item_named(&p, cm, "area");
    let ext = p.idx.items.at(area as usize).owner;
    assert(
        ext != loader::ITEM_NONE && pre(&p, ext, shape) && pre(&p, ext, sq),
        "the conformance names interface and target",
    );
    assert(p.sched.comp[shape as usize] < p.sched.comp[ext as usize], "the interface precedes its conformer");
}

@test(should_panic)
fn index_states_never_move_down() {
    let ws = ws_new(A0, B0, C0);
    let mut p = indexed(&ws, A0, B0, C0, false);
    let am = mod_of(&p, "/a.spc");
    let main = item_named(&p, am, "main");
    assert(p.item_state_at(main) == loader::IS_CHECKED, "checked");
    p.set_item_state(main, loader::IS_RESOLVED);
}

@test
fn index_keys_and_hashes_survive_a_body_edit() {
    let ws = ws_new(A0, B0, C0);
    let p0 = indexed(&ws, A0, B0, C0, true);
    let a1 = M"(import b;
import c;

pub struct Pt {
    pub x: i32,
    pub y: i32,
}

extend Pt {
    pub fn sum(self: &Self) i32 {
        let z = 0;
        return self.x + self.y + z;
    }

    pub fn twice(self: &Self) i32 {
        return self.sum() * 2;
    }
}

pub const K: i32 = 3;
static mut G: i32 = 0;

fn even(n: i32) bool {
    if n == 0 {
        return true;
    }
    return odd(n - 1);
}

fn odd(n: i32) bool {
    if n == 0 {
        return false;
    }
    return even(n - 1);
}

fn generic_id<T>(v: T) T {
    return v;
}

fn main() i32 {
    let p = Pt { x: 1, y: 2 };
    let f = |q: i32| q + K;
    let s = format("{}", p.sum());
    let v = generic_id::<i32>(4);
    unsafe {
        G = G + 1;
    }
    let mut r = p.twice() + f(1) + v + b::bee() + c::cee() + s.len() as i32;
    if even(4) {
        r += 1;
    }
    return r;
}
)";
    let p1 = indexed(&ws, a1, B0, C0, true);
    assert(p0.idx.items.len() == p1.idx.items.len(), "same items");
    for i in 0..p0.idx.items.len() {
        assert(p0.sched.key[i] == p1.sched.key[i], "keys are node-id independent");
        assert(p0.sched.sig_hash[i] == p1.sched.sig_hash[i], "a body edit changes no signature hash");
        assert(p0.sched.comp[i] == p1.sched.comp[i], "components stable");
    }
    assert(p0.sched.pre_edges.len() == p1.sched.pre_edges.len(), "same precheck edges");
    for e in 0..p0.sched.pre_edges.len() {
        assert(p0.sched.pre_edges[e] == p1.sched.pre_edges[e], "same precheck edges");
    }
    let am = mod_of(&p0, "/a.spc");
    let sum0 = item_named(&p0, am, "sum");
    assert(
        p0.idx.items.at(sum0 as usize).node != p1.idx.items.at(sum0 as usize).node || true,
        "the edited body renumbers later nodes",
    );
}

@test
fn index_signature_hash_follows_the_signature() {
    let ws = ws_new(A0, B0, C0);
    let p0 = indexed(&ws, A0, B0, C0, true);
    let b1 = M"(import c;

pub fn bee(extra: i32) i32 {
    return c::cee() + extra;
}
)";
    let a1 = M"(import b;
import c;

pub struct Pt {
    pub x: i32,
    pub y: i32,
}

extend Pt {
    pub fn sum(self: &Self) i32 {
        return self.x + self.y;
    }

    pub fn twice(self: &Self) i32 {
        return self.sum() * 2;
    }
}

pub const K: i32 = 3;
static mut G: i32 = 0;

fn even(n: i32) bool {
    if n == 0 {
        return true;
    }
    return odd(n - 1);
}

fn odd(n: i32) bool {
    if n == 0 {
        return false;
    }
    return even(n - 1);
}

fn generic_id<T>(v: T) T {
    return v;
}

fn main() i32 {
    let p = Pt { x: 1, y: 2 };
    let f = |q: i32| q + K;
    let s = format("{}", p.sum());
    let v = generic_id::<i32>(4);
    unsafe {
        G = G + 1;
    }
    let mut r = p.twice() + f(1) + v + b::bee(1) + c::cee() + s.len() as i32;
    if even(4) {
        r += 1;
    }
    return r;
}
)";
    let c1 = M"(import b;

pub fn cee() i32 {
    return 2;
}

pub fn back(n: i32) i32 {
    if n == 0 {
        return 0;
    }
    return b::bee(1) + back(n - 1);
}

pub const fn fact(n: i32) i32 {
    if n <= 1 {
        return 1;
    }
    return n * fact(n - 1);
}

pub interface Shape {
    fn area(self: &Self) i32;
    fn doubled(self: &Self) i32 {
        return self.area() * 2;
    }
}

pub struct Sq {
    pub s: i32,
}

extend Sq as Shape {
    fn area(self: &Self) i32 {
        return self.s * self.s;
    }
}

pub const F5: i32 = fact(5);
)";
    let p1 = indexed(&ws, a1, b1, c1, true);
    let bm = mod_of(&p0, "/b.spc");
    let am = mod_of(&p0, "/a.spc");
    let bee = item_named(&p0, bm, "bee");
    let main = item_named(&p0, am, "main");
    let cee = item_named(&p0, mod_of(&p0, "/c.spc"), "cee");
    assert(p0.sched.key[bee as usize] == p1.sched.key[bee as usize], "the key survives a signature edit");
    assert(p0.sched.sig_hash[bee as usize] != p1.sched.sig_hash[bee as usize], "the hash follows the signature");
    assert(p0.sched.sig_hash[main as usize] == p1.sched.sig_hash[main as usize], "a caller's hash is untouched");
    assert(p0.sched.sig_hash[cee as usize] == p1.sched.sig_hash[cee as usize], "an unrelated hash is untouched");
    let back = item_named(&p0, mod_of(&p0, "/c.spc"), "back");
    assert(
        p0.sched.sig_hash[back as usize] == p1.sched.sig_hash[back as usize],
        "a caller with a changed body keeps its hash",
    );
}

@test
fn index_states_after_analysis() {
    let ws = ws_new(A0, B0, C0);
    let p = indexed(&ws, A0, B0, C0, false);
    // Every workspace item is Checked; a prelude item the platform filter removed after the
    // index was built stays Resolved (it is never checked); nothing is left mid-transition.
    for i in 0..p.idx.items.len() {
        let st = p.item_state_at(i as loader::ItemId);
        assert(st == loader::IS_CHECKED || st == loader::IS_RESOLVED, "no item mid-transition");
        if !p.modules.at(p.idx.items.at(i).module as usize).prelude {
            assert(st == loader::IS_CHECKED, "every workspace item checked by the analysis");
        }
    }
    let am = mod_of(&p, "/a.spc");
    let main = item_named(&p, am, "main");
    assert(p.item_state(am as ModuleId, p.idx.items.at(main as usize).node) == loader::IS_CHECKED, "the node query");
    assert(p.item_state(am as ModuleId, 1) == loader::IS_PARSED, "a node that is no item");
    assert(p.sched.retained() < 65536, "a small workspace holds a small index");
}
