// The incremental-analysis oracle: every scripted edit runs through analysis::recompile against a
// retained package AND through a from-scratch analysis::compile of the same overlays, then the two
// must agree: diagnostics as a multiset, and name-resolution probes at sampled positions. The
// RecompileStats counters additionally pin the exit-gate observables: a body edit re-analyzes ONE
// module (importers untouched), a signature edit re-analyzes exactly the importers' closure, a
// `const fn` body edit is interface-class (CTFE reads it cross-module), an import edit or syntax
// error leaves the incremental domain entirely (recompile refuses; the caller full-rebuilds).
// Body ownership: a module without an editor buffer releases its bodies after every round; a
// round parses them back when the document opens, when the module must re-analyze, or when the
// constant engine demands one of its bodies (then re-runs the demanding module), and a feature
// query on a closed module parses them back through ensure_bodies.
import lsp::analysis as an;
import lsp::features as feat;
import module::loader as loader;
import ast::ast as *;
import tests::cli_harness as cli;
import driver_shim as shim;
import typechecker::typechecker as tc;
import ir::recursion as recur;

const A0: str = M"(import b;
import d;

fn main() i32 {
    let v = b::bee();
    let r = d::dee(v);
    return r - r;
}
)";
const B0: str = M"(import c;

pub fn bee() i32 {
    return c::cee() + 1;
}
)";
const C0: str = M"(pub fn cee() i32 {
    return 1;
}

pub const fn k() i32 {
    return 2;
}
)";
const D0: str = M"(pub fn dee(v: i32) i32 {
    let w = v + 1;
    return w;
}

pub fn other() i32 {
    let unused_probe = 3;
    return 4;
}
)";

struct Ws {
    pub proj: cli::Proj,
    pub root: String, // <proj>/a.spc
    pub dir: String, // <proj>
}

fn ws_new() Ws {
    let proj = cli::proj_new();
    proj.mkfile("a.spc", A0);
    proj.mkfile("b.spc", B0);
    proj.mkfile("c.spc", C0);
    proj.mkfile("d.spc", D0);
    let dir = String::from_str(proj.dir());
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

// A workspace over four given sources (a.spc is the root).
fn ws_of(a: str, b: str, c: str, d: str) Ws {
    let proj = cli::proj_new();
    proj.mkfile("a.spc", a);
    proj.mkfile("b.spc", b);
    proj.mkfile("c.spc", c);
    proj.mkfile("d.spc", d);
    let dir = String::from_str(proj.dir());
    let mut root = String::from_str(dir.as_str());
    root.push_str("/a.spc");
    return Ws { proj: proj, root: root, dir: dir };
}

// One `an::recompile` round over the test's owned overlays (the server passes borrowed views of its
// documents the same way), then the borrow round the server runs after it.
fn recompile_ov(
    ws: &Ws,
    p: &mut loader::Package,
    ovf: &Vector<String>,
    ovt: &Vector<String>,
    diags: &mut Vector<an::DiagRec>,
    st: &mut an::RecompileStats,
) bool {
    let mut fv = Vector::<str>::new();
    let mut tv = Vector::<str>::new();
    for i in 0..ovf.len() {
        fv.push(ovf.at(i).as_str());
        tv.push(ovt.at(i).as_str());
    }
    let ok = an::recompile(p, unsafe shim::sc_host_platform(), ws.root.as_str(), "", &fv, &tv, diags, st);
    if ok {
        settle(p, ovf, diags);
    }
    return ok;
}

fn never_stop(_ctx: *mut void, _between: bool) bool {
    return false;
}

// The server's borrow round after an analysis, run to its end.
fn settle(p: &mut loader::Package, ovf: &Vector<String>, diags: &mut Vector<an::DiagRec>) {
    let mut fv = Vector::<str>::new();
    for i in 0..ovf.len() {
        fv.push(ovf.at(i).as_str());
    }
    let r = an::borrowck_pending(p, diags, &fv, never_stop, null);
    assert(!r.canceled, "a round that is never asked to stop finishes");
}

// One incremental round and the diagnostic oracle only (the workspaces below need no `bee`).
fn round_diags(
    ws: &Ws,
    p: &mut loader::Package,
    diags: &mut Vector<an::DiagRec>,
    ovf: &Vector<String>,
    ovt: &Vector<String>,
    st: &mut an::RecompileStats,
    label: str,
) {
    let ok = recompile_ov(ws, p, ovf, ovt, diags, st);
    assert(ok, label);
    let mut rd = Vector::<an::DiagRec>::new();
    let rp = fresh(ws, ovf, ovt, &mut rd);
    assert(diags_equal(diags, &rd), label);
    let _ = rp;
}

// Errors recorded against module `<name>`.
fn errors_in(p: &loader::Package, diags: &Vector<an::DiagRec>, name: str) usize {
    let m = mod_of(p, name);
    let mut n: usize = 0;
    for i in 0..diags.len() {
        if diags.at(i).module as usize == m && diags.at(i).severity == 1 {
            n += 1;
        }
    }
    return n;
}

fn ov(ws: &Ws, name: str, text: str, ovf: &mut Vector<String>, ovt: &mut Vector<String>) {
    let mut f = String::from_str(ws.dir.as_str());
    f.push_str("/");
    f.push_str(name);
    ovf.push(f);
    ovt.push(String::from_str(text));
}

fn fresh(ws: &Ws, ovf: &Vector<String>, ovt: &Vector<String>, diags: &mut Vector<an::DiagRec>) loader::Package {
    let mut f2 = Vector::<String>::new();
    let mut t2 = Vector::<String>::new();
    for i in 0..ovf.len() {
        f2.push(ovf.at(i).clone());
        t2.push(ovt.at(i).clone());
    }
    let mut p = an::compile(
        ws.root.as_str(),
        ws.dir.as_str(),
        "",
        "std",
        unsafe shim::sc_host_platform(),
        f2,
        t2,
        "",
        diags,
    );
    settle(&mut p, ovf, diags);
    return p;
}

// Multiset equality over the semantic identity of each record.
fn diags_equal(a: &Vector<an::DiagRec>, b: &Vector<an::DiagRec>) bool {
    if a.len() != b.len() {
        eprintln("diags_equal: incr {} vs fresh {}", a.len(), b.len());
        for i in 0..a.len() {
            eprintln(
                "  incr m{} @{}+{} s{} {}",
                a.at(i).module,
                a.at(i).start,
                a.at(i).len,
                a.at(i).severity,
                a.at(i).msg.as_str(),
            );
        }
        for i in 0..b.len() {
            eprintln(
                "  fresh m{} @{}+{} s{} {}",
                b.at(i).module,
                b.at(i).start,
                b.at(i).len,
                b.at(i).severity,
                b.at(i).msg.as_str(),
            );
        }
        return false;
    }
    let mut used = Vector::<bool>::new();
    for _ in 0..b.len() {
        used.push(false);
    }
    for i in 0..a.len() {
        let x = a.at(i);
        let mut hit = false;
        for j in 0..b.len() {
            if used[j] || hit {
                continue;
            }
            let y = b.at(j);
            if x.module == y.module && x.start == y.start && x.len == y.len && x.severity == y.severity && x.msg.as_str() == y.msg.as_str() {
                used.set(j, true);
                hit = true;
            }
        }
        if !hit {
            return false;
        }
    }
    return true;
}

// The resolution target of the first identifier spelling `needle` in module `mid`: packed
// (target module << 32 | target decl's span start): node-id independent, so it compares across a
// spliced arena and a fresh one.
fn probe_res(p: &loader::Package, mid: usize, needle: str) u64 {
    let a = &p.modules.at(mid).ast;
    let src = p.modules.at(mid).source.as_str();
    for i0 in 1..a.nnodes() {
        let i = a.nth_id(i0);
        let n = a.at_const(i);
        if n.kind != NodeKind::NODE_IDENTIFIER {
            continue;
        }
        let sp = n.as_data.name.text;
        if (sp.end - sp.start) as usize != needle.len() {
            continue;
        }
        if src.slice(sp.start as usize, sp.end as usize) != needle {
            continue;
        }
        let d = a.resolution_def(i);
        if d.node == NODE_NONE {
            continue;
        }
        let ta = unsafe &*p.module_ast_const(d.module);
        return d.module as u64 << 32 | ta.at_const(d.node).span.start as u64;
    }
    return 0;
}

// Module index of `<name>` inside the package (by file suffix match).
fn mod_of(p: &loader::Package, name: str) usize {
    for i in 0..p.modules.len() {
        if p.modules.at(i).file.as_str().ends_with(name) {
            return i;
        }
    }
    return 0xFFFF;
}

// One incremental round + the oracle: recompile must succeed, agree with a fresh compile on the
// diagnostic multiset, and (when `probe_mod` names a module) on the resolution probe.
fn round(
    ws: &Ws,
    p: &mut loader::Package,
    diags: &mut Vector<an::DiagRec>,
    ovf: &Vector<String>,
    ovt: &Vector<String>,
    st: &mut an::RecompileStats,
    label: str,
) {
    let ok = recompile_ov(ws, p, ovf, ovt, diags, st);
    assert(ok, label);
    let mut rd = Vector::<an::DiagRec>::new();
    let mut rp = fresh(ws, ovf, ovt, &mut rd);
    assert(diags_equal(diags, &rd), label);
    // The probes read a's bodies, released while a.spc has no buffer: a feature query's path.
    let am = mod_of(p, "/a.spc");
    let ram = mod_of(&rp, "/a.spc");
    an::ensure_bodies(p, am);
    an::ensure_bodies(&mut rp, ram);
    assert(probe_res(p, am, "bee") != 0, label);
    assert(probe_res(p, am, "bee") == probe_res(&rp, ram, "bee"), label);
    assert(probe_res(p, am, "dee") == probe_res(&rp, ram, "dee"), label);
}

@test
fn incr_noop_round() {
    let ws = ws_new();
    let ovf = Vector::<String>::new();
    let ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    let mut st = an::RecompileStats {};
    let ok = recompile_ov(&ws, &mut p, &ovf, &ovt, &mut diags, &mut st);
    assert(ok, "noop ok");
    assert(st.reparsed == 0 && st.analyzed == 0, "noop does no semantic work");
}

@test
fn incr_body_edit_stays_local() {
    let ws = ws_new();
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    // Grow dee's body: strictly inside the braces of a plain fn.
    let d1: str = M"(pub fn dee(v: i32) i32 {
    let w = v + 2 + 100;
    return w;
}

pub fn other() i32 {
    let unused_probe = 3;
    return 4;
}
)";
    ov(&ws, "d.spc", d1, &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    round(&ws, &mut p, &mut diags, &ovf, &ovt, &mut st, "body edit oracle");
    assert(st.body_only == 1, "body edit takes the splice path");
    assert(st.analyzed == 1, "a private body edit re-analyzes ONE module; importers keep their analyses");
}

@test
fn incr_body_edit_keeps_sibling_desugars() {
    // Sibling bodies re-typecheck from their retained, already desugared trees: every synthesized
    // callee and local use keeps its seeded resolution, and the generated statements raise no lint.
    let ws = ws_new();
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let d0: str = M"(pub fn dee(v: i32) i32 {
    let w = v + 1;
    return w;
}

fn parse(s: str) Result<i32, String> {
    if s.len() == 0 {
        return Result::<i32, String>::Err(format("empty"));
    }
    return Result::<i32, String>::Ok(s.len() as i32);
}

pub fn other(s: str) i32 {
    let t = format("{} and {}", 1, s);
    println("{}", t.len());
    let mut n: i32 = 1;
    n += t.len() as i32;
    let k = switch s { "a" => 1, "b" => 2, _ => 3, };
    let add = |x: i32| x + n;
    let m = M"(n is {n} k is {k})";
    let r = parse(s).unwrap_or(0);
    return add(k) + m.len() as i32 + r;
}
)";
    ov(&ws, "d.spc", d0, &mut ovf, &mut ovt);
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    assert(diags.len() == 0, "the baseline is clean");
    let d1 = String::from_str(d0);
    let at = d1.as_str().find("let w = v + 1;") as usize;
    let mut e = String::from_str(d1.as_str().slice(0, at));
    e.push_str("let w = v + 2 + 100;");
    e.push_str(d1.as_str().slice(at + 14, d1.len()));
    ovt.set(0, e);
    let mut st = an::RecompileStats {};
    round(&ws, &mut p, &mut diags, &ovf, &ovt, &mut st, "sibling desugar oracle");
    assert(st.body_only == 1, "the edit takes the splice path");
    assert(diags.len() == 0, "no diagnostic from the re-checked siblings");
}

@test
fn incr_body_edit_diag_positions_shift() {
    let ws = ws_new();
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    // Introduce a type error inside dee AND grow the text before `other`, so other's node spans shift.
    let d1: str = M"(pub fn dee(v: i32) i32 {
    let w = v + 1;
    let bad: i32 = true;
    return w + bad;
}

pub fn other() i32 {
    let unused_probe = 3;
    return 4;
}
)";
    ov(&ws, "d.spc", d1, &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    round(&ws, &mut p, &mut diags, &ovf, &ovt, &mut st, "body diag oracle");
    assert(st.body_only == 1, "diag edit stays on the splice path");
    // And fixing it clears the record again.
    let mut ovf2 = Vector::<String>::new();
    let mut ovt2 = Vector::<String>::new();
    ov(&ws, "d.spc", D0, &mut ovf2, &mut ovt2);
    let mut st2 = an::RecompileStats {};
    round(&ws, &mut p, &mut diags, &ovf2, &ovt2, &mut st2, "body diag fix oracle");
}

@test
fn incr_signature_edit_invalidates_importers() {
    let ws = ws_new();
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    // Bee grows a parameter: a's call site must now error, c and d must stay untouched.
    let b1: str = M"(import c;

pub fn bee(extra: i32) i32 {
    return c::cee() + extra;
}
)";
    ov(&ws, "b.spc", b1, &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    round(&ws, &mut p, &mut diags, &ovf, &ovt, &mut st, "signature edit oracle");
    assert(st.body_only == 0, "a signature edit is not a body edit");
    assert(st.analyzed == 2, "exactly the changed module and its importer re-analyze");
    let mut have_a_err = false;
    let am = mod_of(&p, "/a.spc");
    for i in 0..diags.len() {
        if diags.at(i).module as usize == am && diags.at(i).severity == 1 {
            have_a_err = true;
        }
    }
    assert(have_a_err, "the importer's call site reports against the new signature");
}

@test
fn incr_const_fn_body_is_interface() {
    let ws = ws_new();
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    let c1: str = M"(pub fn cee() i32 {
    return 1;
}

pub const fn k() i32 {
    return 3;
}
)";
    ov(&ws, "c.spc", c1, &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    round(&ws, &mut p, &mut diags, &ovf, &ovt, &mut st, "const fn body oracle");
    assert(st.body_only == 0, "a const fn body is cross-module semantics: no splice");
    // Nothing names `k`: the owner re-analyzes alone; its importers' analyses stand.
    assert(st.analyzed == 1, "the const owner re-analyzes");
    assert(st.kept == 2, "both modules that reach the owner through imports keep their analysis");
}

// The touched-item walk follows references across modules: a constant folded from the edited
// `const fn`, then a constant folded from that one, re-analyze; a module that names only the
// owner's untouched function stands.
@test
fn incr_const_fn_body_reaches_folders() {
    let ws = ws_of(
        M"(import b;
import d;

const KA: i32 = b::KB + 1;

fn main() i32 {
    return KA - d::dee();
}
)",
        M"(import c;

pub const KB: i32 = c::k();
)",
        M"(pub fn cee() i32 {
    return 1;
}

pub const fn k() i32 {
    return 2;
}
)",
        M"(import c;

pub fn dee() i32 {
    return c::cee();
}
)",
    );
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    let c1: str = M"(pub fn cee() i32 {
    return 1;
}

pub const fn k() i32 {
    return 3;
}
)";
    ov(&ws, "c.spc", c1, &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    round_diags(&ws, &mut p, &mut diags, &ovf, &ovt, &mut st, "const fold chain oracle");
    assert(st.analyzed == 3, "the owner, the folder and the folder's folder re-analyze");
    assert(st.kept == 1, "the module naming only the untouched function stands");
}

// A method's signature edit inside an extend touches that member alone: its callers re-analyze,
// the callers of its siblings stand.
@test
fn incr_method_edit_keeps_sibling_callers() {
    let ws = ws_of(
        M"(import b;
import d;

fn main() i32 {
    return b::bee() + d::dee();
}
)",
        M"(import c;

pub fn bee() i32 {
    let s = c::S { x: 1 };
    return s.m2();
}

pub fn other() i32 {
    let s = c::S { x: 1 };
    let v: i32 = s.m1();
    return v;
}
)",
        M"(pub struct S {
    pub x: i32,
}

extend S {
    pub fn m1(self: &Self) i32 {
        return self.x;
    }

    pub fn m2(self: &Self) i32 {
        return self.x + 1;
    }
}
)",
        M"(import c;

pub fn dee() i32 {
    let s = c::S { x: 2 };
    return s.m2();
}
)",
    );
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    assert(errors_in(&p, &diags, "/b.spc") == 0, "clean baseline");
    // m1 now returns i64: b's typed binding errors; d (names m2 only) and a (names bee only) stand.
    let c1: str = M"(pub struct S {
    pub x: i32,
}

extend S {
    pub fn m1(self: &Self) i64 {
        return self.x;
    }

    pub fn m2(self: &Self) i32 {
        return self.x + 1;
    }
}
)";
    ov(&ws, "c.spc", c1, &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    round_diags(&ws, &mut p, &mut diags, &ovf, &ovt, &mut st, "method signature oracle");
    assert(st.body_only == 0, "a signature edit is not a body edit");
    assert(st.analyzed == 2, "the owner and the caller of the edited method re-analyze");
    assert(st.kept == 2, "the modules naming only the sibling method stand");
    assert(errors_in(&p, &diags, "/b.spc") == 1, "the caller reports against the new signature");
}

// An alias edit reaches the users of a function whose signature spells the alias: the walk
// follows the intra-module reference from the function to the alias, then the callers.
@test
fn incr_alias_edit_reaches_signature_users() {
    let ws = ws_of(
        M"(import b;
import d;

fn main() i32 {
    return b::bee() + d::dee();
}
)",
        M"(import c;

pub fn bee() i32 {
    let v = c::make();
    return v.f;
}
)",
        M"(pub struct S {
    pub f: i32,
}

pub struct T {
    pub g: i32,
}

pub type A = S;

pub fn make() A {
    return S { f: 1 };
}

pub fn other() i32 {
    return 4;
}
)",
        M"(import c;

pub fn dee() i32 {
    return c::other();
}
)",
    );
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    let c1: str = M"(pub struct S {
    pub f: i32,
}

pub struct T {
    pub g: i32,
}

pub type A = T;

pub fn make() A {
    return T { g: 1 };
}

pub fn other() i32 {
    return 4;
}
)";
    ov(&ws, "c.spc", c1, &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    round_diags(&ws, &mut p, &mut diags, &ovf, &ovt, &mut st, "alias chain oracle");
    // The caller of the function returning the alias re-analyzes; its own signature stands, so
    // its caller and the module naming only `other` stand.
    assert(st.analyzed == 2, "the owner and the caller of the function returning the alias re-analyze");
    assert(st.kept == 2, "the caller's caller and the module naming only the untouched function stand");
    assert(errors_in(&p, &diags, "/b.spc") == 1, "the field read reports against the new target");
}

// An edit of an extend's own bytes (here the interface it conforms to) re-analyzes every module
// that reaches the owner: a bound is satisfied without naming the extend.
@test
fn incr_extend_header_edit_reaches_importers() {
    let ws = ws_of(
        M"(import b;
import d;

fn main() i32 {
    return b::bee() + d::dee();
}
)",
        M"(import c;

fn g<T: c::I>(x: &T) i32 {
    return x.f();
}

pub fn bee() i32 {
    let s = c::S { x: 1 };
    return g(&s);
}
)",
        M"(pub interface I {
    fn f(self: &Self) i32;
}

pub interface J {
    fn f(self: &Self) i32;
}

pub struct S {
    pub x: i32,
}

extend S as I {
    fn f(self: &Self) i32 {
        return self.x;
    }
}
)",
        M"(import c;

pub fn dee() i32 {
    let s = c::S { x: 2 };
    return s.x;
}
)",
    );
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    assert(errors_in(&p, &diags, "/b.spc") == 0, "clean baseline");
    let c1: str = M"(pub interface I {
    fn f(self: &Self) i32;
}

pub interface J {
    fn f(self: &Self) i32;
}

pub struct S {
    pub x: i32,
}

extend S as J {
    fn f(self: &Self) i32 {
        return self.x;
    }
}
)";
    ov(&ws, "c.spc", c1, &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    round_diags(&ws, &mut p, &mut diags, &ovf, &ovt, &mut st, "extend header oracle");
    assert(st.kept == 0, "an extend header edit keeps no reacher");
    assert(st.analyzed == 4, "every module reaching the owner re-analyzes");
    assert(errors_in(&p, &diags, "/b.spc") == 1, "the bound no longer holds");
}

// A reacher whose last analysis reported an error re-analyzes even when it names no touched
// item: the edit may be what its error was about.
@test
fn incr_erring_reacher_reanalyzes() {
    let ws = ws_of(
        M"(import b;
import d;

fn main() i32 {
    return b::bee() + d::dee();
}
)",
        M"(import c;

pub fn bee() i32 {
    return c::cee();
}
)",
        M"(pub fn cee() i32 {
    return 1;
}

pub fn other() i32 {
    return 2;
}
)",
        M"(import c;

pub fn dee() i32 {
    let v: i32 = "text";
    return v + c::cee();
}
)",
    );
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    assert(errors_in(&p, &diags, "/d.spc") == 1, "the baseline error");
    let c1: str = M"(pub fn cee() i32 {
    return 1;
}

pub fn other() i64 {
    return 2;
}
)";
    ov(&ws, "c.spc", c1, &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    round_diags(&ws, &mut p, &mut diags, &ovf, &ovt, &mut st, "erring reacher oracle");
    assert(st.analyzed == 2, "the owner and the erring reacher re-analyze");
    assert(st.kept == 2, "the clean reachers naming only the untouched function stand");
}

// The reference record survives a body release: the module that names a definition is known
// without its bodies, and a reference scan parses back that module alone.
@test
fn release_reference_record_names_referencers() {
    let ws = ws_new();
    let ovf = Vector::<String>::new();
    let ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    let am = mod_of(&p, "/a.spc");
    let bm = mod_of(&p, "/b.spc");
    let cm = mod_of(&p, "/c.spc");
    assert(p.modules.at(bm).ast.b.released && p.modules.at(am).ast.b.released, "closed modules release");
    let cee = probe_decl(&p, cm, "cee");
    assert(cee != NODE_NONE, "cee declares in c");
    assert(an::refers(&p, bm, cm as u32, cee, cee), "b names cee from its released body");
    assert(!an::refers(&p, am, cm as u32, cee, cee), "a never names cee");
    an::ensure_bodies(&mut p, bm);
    let locs = feat::references_of_def(&p, DefId { module: cm as ModuleId, node: cee }, false);
    assert(locs.len() == 1 && locs.at(0).module as usize == bm, "the one call site, in b");
    assert(p.modules.at(am).ast.b.released, "a stays released");
}

// The declaration node named `needle` in module `mid` (a function's name node resolves to it).
fn probe_decl(p: &loader::Package, mid: usize, needle: str) NodeId {
    let a = &p.modules.at(mid).ast;
    let src = p.modules.at(mid).source.as_str();
    for i0 in 1..a.nnodes() {
        let i = a.nth_id(i0);
        let n = a.at_const(i);
        if n.kind != NodeKind::NODE_FUNCTION {
            continue;
        }
        let nm = n.as_data.function.name;
        let sp = a.at_const(nm).as_data.name.text;
        if src.slice(sp.start as usize, sp.end as usize) == needle {
            return i;
        }
    }
    return NODE_NONE;
}

@test
fn incr_import_edit_leaves_domain() {
    let ws = ws_new();
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    let a1: str = M"(import b;
import c;
import d;

fn main() {
    let v = b::bee();
    d::dee(v);
    _ = c::cee();
}
)";
    ov(&ws, "a.spc", a1, &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    let ok = recompile_ov(&ws, &mut p, &ovf, &ovt, &mut diags, &mut st);
    assert(!ok, "an import-surface edit falls back to the full compile");
}

@test
fn incr_parse_error_leaves_domain() {
    let ws = ws_new();
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    ov(&ws, "b.spc", "import c;\npub fn bee() i32 {", &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    let ok = recompile_ov(&ws, &mut p, &ovf, &ovt, &mut diags, &mut st);
    assert(!ok, "a parse error falls back to the full compile");
}

@test
fn release_closed_bodies_after_compile() {
    let ws = ws_new();
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    let dm = mod_of(&p, "/d.spc");
    assert(p.modules.at(dm).ast.b.released, "a module without a buffer releases its bodies");
    assert(p.modules.at(dm).ast.b.nodes.len() == 0, "the released arena is empty");
    assert(p.modules.at(dm).ast.nodes.len() > 1, "the module arena stays");
    // Opening the document (same text) parses the bodies back and re-analyzes that module only.
    ov(&ws, "d.spc", D0, &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    round(&ws, &mut p, &mut diags, &ovf, &ovt, &mut st, "reopen");
    assert(st.reparsed == 0 && st.bodies_back == 1 && st.analyzed == 1, "opening parses one module back");
    assert(!p.modules.at(dm).ast.b.released, "an open document keeps its bodies");
    let mut rd = Vector::<an::DiagRec>::new();
    let rp = fresh(&ws, &ovf, &ovt, &mut rd);
    assert(probe_res(&p, dm, "w") != 0, "the local resolves in the parsed-back body");
    assert(probe_res(&p, dm, "w") == probe_res(&rp, mod_of(&rp, "/d.spc"), "w"), "parsed-back body resolves as fresh");
    // A body edit in the reopened document still takes the splice path.
    let d1 = M"(pub fn dee(v: i32) i32 {
    let w = v + 1;
    let w2 = w + 1;
    return w2;
}

pub fn other() i32 {
    let unused_probe = 3;
    return 4;
}
)";
    let mut ovt2 = Vector::<String>::new();
    ovt2.push(String::from_str(d1));
    let mut st2 = an::RecompileStats {};
    round(&ws, &mut p, &mut diags, &ovf, &ovt2, &mut st2, "edit after reopen");
    assert(st2.body_only == 1 && st2.bodies_back == 0, "the reopened body splices in place");
}

@test
fn release_feature_query_parses_back_then_releases() {
    let ws = ws_new();
    let ovf = Vector::<String>::new();
    let ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    let am = mod_of(&p, "/a.spc");
    assert(p.modules.at(am).ast.b.released, "released before the query");
    an::ensure_bodies(&mut p, am);
    assert(!p.modules.at(am).ast.b.released, "the query parsed the bodies back");
    let mut rd = Vector::<an::DiagRec>::new();
    let mut rp = fresh(&ws, &ovf, &ovt, &mut rd);
    let ram = mod_of(&rp, "/a.spc");
    an::ensure_bodies(&mut rp, ram);
    assert(
        probe_res(&p, am, "bee") != 0 && probe_res(&p, am, "bee") == probe_res(&rp, ram, "bee"),
        "resolutions as fresh",
    );
    assert(probe_res(&p, am, "dee") == probe_res(&rp, ram, "dee"), "resolutions as fresh");
    assert(diags_equal(&diags, &rd), "the query leaves the records alone");
    // The next round releases the closed module again.
    let mut st = an::RecompileStats {};
    let ok = recompile_ov(&ws, &mut p, &ovf, &ovt, &mut diags, &mut st);
    assert(ok && st.analyzed == 0, "a no-op round");
    assert(p.modules.at(am).ast.b.released, "released again after the round");
}

@test
fn release_signature_edit_parses_importer_back() {
    let ws = ws_new();
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    let b1 = M"(import c;

pub fn bee(extra: i32) i32 {
    return c::cee() + extra;
}
)";
    ov(&ws, "b.spc", b1, &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    round(&ws, &mut p, &mut diags, &ovf, &ovt, &mut st, "signature edit over released importers");
    // b opened (parsed back, then fully reparsed) and its closed importer a parsed back; the
    // folds of their calls may demand a released callee module on top.
    assert(st.bodies_back >= 2 && st.analyzed == 2, "the importer's bodies come back for its re-analysis");
    // The oracle's probes parsed a back; a following no-op round releases the closed importer
    // again and keeps the open document's bodies.
    let mut st2 = an::RecompileStats {};
    let ok = recompile_ov(&ws, &mut p, &ovf, &ovt, &mut diags, &mut st2);
    assert(ok && st2.analyzed == 0, "a no-op round");
    let am = mod_of(&p, "/a.spc");
    let bm = mod_of(&p, "/b.spc");
    assert(!p.modules.at(bm).ast.b.released, "the open document keeps its bodies");
    assert(p.modules.at(am).ast.b.released, "the closed importer releases again after the round");
}

// A `const fn` whose body calls a plain function of another module: an array length in an open
// document evaluates it, so the engine demands the plain body, which its module released (an
// evaluation refused for good would report the length as not constant).
const E_A: str = M"(import c;

fn main() i32 {
    let arr: [i32; c::k3()] = [0, 0, 0];
    return arr[0];
}
)";
const E_C: str = M"(import d;

pub const fn k3() i32 {
    return d::plain3();
}
)";
const E_D: str = M"(pub fn plain3() i32 {
    return 3;
}
)";

@test
fn release_engine_demand_parses_back_and_reruns() {
    let proj = cli::proj_new();
    proj.mkfile("a.spc", E_A);
    proj.mkfile("c.spc", E_C);
    proj.mkfile("d.spc", E_D);
    let dir = String::from_str(proj.dir());
    let mut root = String::from_str(dir.as_str());
    root.push_str("/a.spc");
    let ws = Ws { proj: proj, root: root, dir: dir };
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    assert(diags.len() == 0, "the full analysis evaluates the length");
    let dm = mod_of(&p, "/d.spc");
    assert(p.modules.at(dm).ast.b.released, "the plain callee's module releases");
    // Open a.spc and edit its body: the fold demands d's plain body.
    let a1 = M"(import c;

fn main() i32 {
    let z = 1;
    let arr: [i32; c::k3()] = [0, 0, 0];
    return arr[0] + z - 1;
}
)";
    ov(&ws, "a.spc", a1, &mut ovf, &mut ovt);
    let mut st = an::RecompileStats {};
    let ok = recompile_ov(&ws, &mut p, &ovf, &ovt, &mut diags, &mut st);
    assert(ok, "demand round");
    let mut rd = Vector::<an::DiagRec>::new();
    let _rp = fresh(&ws, &ovf, &ovt, &mut rd);
    assert(diags_equal(&diags, &rd), "the demand round reports the fold like a fresh analysis");
    assert(st.passes == 1, "one extra pass after the demand");
    assert(st.bodies_back == 2, "a opened and d demanded");
    assert(!p.modules.at(dm).ast.b.released, "a demanded module stays live");
    assert(dm < p.body_hold.len() && p.body_hold[dm], "and is held across rounds");
    // The next edit needs no parse-back and no extra pass.
    let a2 = M"(import c;

fn main() i32 {
    let z = 2;
    let arr: [i32; c::k3()] = [0, 0, 0];
    return arr[0] + z - 2;
}
)";
    let mut ovt2 = Vector::<String>::new();
    ovt2.push(String::from_str(a2));
    let mut st2 = an::RecompileStats {};
    let ok2 = recompile_ov(&ws, &mut p, &ovf, &ovt2, &mut diags, &mut st2);
    assert(ok2, "the next round succeeds");
    assert(st2.passes == 0, "a held module serves the next round directly: no pass");
    assert(st2.bodies_back == 0, "a held module serves the next round directly: no body comes back");
    let mut rd2 = Vector::<an::DiagRec>::new();
    let _rp2 = fresh(&ws, &ovf, &ovt2, &mut rd2);
    assert(diags_equal(&diags, &rd2), "steady state matches fresh");
}

// Module `m`'s analysis as node-id independent text, one line per node in sorted order: its kind,
// its span, the declaration it resolves to (module path, declaration span) and its type. The body
// arena takes part when `bodies` is set.
fn state_lines(p: &loader::Package, m: usize, bodies: bool) Vector<String> {
    let a = &p.modules.at(m).ast;
    let src = p.modules.at(m).source.as_str();
    let mut out = Vector::<String>::new();
    let nn = if bodies {
        a.nnodes();
    } else {
        a.nodes.len();
    };
    for k in 0..nn {
        let id = a.nth_id(k);
        let n = a.at_const(id);
        let mut line = format("{} {}..{}", n.kind as u32, n.span.start, n.span.end);
        let d = a.resolution_def(id);
        if d.node != NODE_NONE {
            let ta = unsafe &*p.module_ast_const(d.module);
            line.format_into(" -> {}@{}", p.modules.at(d.module as usize).path.as_str(), ta.at_const(d.node).span.start);
        }
        let t = a.type_of(id);
        if t != TYPE_NONE {
            let ts = tc::type_str_of(p, a, src, t);
            line.push_str(" : ");
            line.push_string(&ts);
        }
        out.push(line);
    }
    out.sort();
    return out;
}

// True when the incremental package `p` holds the analysis a fresh one (`q`) holds: per module (by
// file), the same source, the same arena sizes, and the same per-node resolutions and types. Body
// ownership is a retention policy, not analysis: a round holds a body the constant engine
// demanded, so the body arenas compare where both are live. The first difference prints.
fn state_equal(p: &loader::Package, q: &loader::Package) bool {
    if p.modules.len() != q.modules.len() {
        eprintln("state_equal: {} modules vs {}", p.modules.len(), q.modules.len());
        return false;
    }
    for i in 0..p.modules.len() {
        let mi = p.modules.at(i);
        let mut j = q.modules.len();
        for k in 0..q.modules.len() {
            if q.modules.at(k).file.as_str() == mi.file.as_str() {
                j = k;
            }
        }
        if j == q.modules.len() {
            eprintln("state_equal: {} is not in the fresh package", mi.file.as_str());
            return false;
        }
        let mj = q.modules.at(j);
        if mi.source.as_str() != mj.source.as_str() {
            eprintln("state_equal: {}: the sources differ", mi.file.as_str());
            return false;
        }
        let bodies = !mi.ast.b.released && !mj.ast.b.released;
        if mi.ast.nodes.len() != mj.ast.nodes.len() || bodies && mi.ast.b.nodes.len() != mj.ast.b.nodes.len() {
            eprintln(
                "state_equal: {}: arenas {}+{} vs {}+{}",
                mi.file.as_str(),
                mi.ast.nodes.len(),
                mi.ast.b.nodes.len(),
                mj.ast.nodes.len(),
                mj.ast.b.nodes.len(),
            );
            return false;
        }
        let a = state_lines(p, i, bodies);
        let b = state_lines(q, j, bodies);
        for k in 0..a.len() {
            if a.at(k).as_str() != b.at(k).as_str() {
                eprintln("state_equal: {}: `{}` vs `{}`", mi.file.as_str(), a.at(k).as_str(), b.at(k).as_str());
                return false;
            }
        }
        if p.recur.reported[i] != q.recur.reported[j] {
            eprintln(
                "state_equal: {}: reported by the recursion check {} vs {}",
                mi.file.as_str(),
                p.recur.reported[i],
                q.recur.reported[j],
            );
            return false;
        }
        let sa = summary_lines(p, i);
        let sb = summary_lines(q, j);
        if sa.len() != sb.len() {
            eprintln("state_equal: {}: {} function summaries vs {}", mi.file.as_str(), sa.len(), sb.len());
            return false;
        }
        for k in 0..sa.len() {
            if sa.at(k).as_str() != sb.at(k).as_str() {
                eprintln(
                    "state_equal: {}: summary `{}` vs `{}`",
                    mi.file.as_str(),
                    sa.at(k).as_str(),
                    sb.at(k).as_str(),
                );
                return false;
            }
        }
    }
    return true;
}

// Module `m`'s recursion summaries (`Package.recur`) as node-id independent text, one sorted line per
// function: its declaration's span start, its entry, and per point its kind, span, callee (module
// path, declaration span) and successors.
fn summary_lines(p: &loader::Package, m: usize) Vector<String> {
    let s = p.recur.mods.at(m);
    let a = &p.modules.at(m).ast;
    let mut out = Vector::<String>::new();
    for fi in 0..s.fns.len() {
        let fs = *s.fns.at(fi);
        let mut line = format("fn@{} entry {}", a.at_const(fs.node).span.start, fs.entry);
        for x in 0..fs.count {
            let pt = *s.points.at((fs.first + x) as usize);
            line.format_into(" | {} {}..{}", pt.kind, pt.span.start, pt.span.end);
            if pt.kind == recur::PK_CALL {
                let ta = unsafe &*p.module_ast_const(pt.callee.module);
                line.format_into(
                    " -> {}@{}",
                    p.modules.at(pt.callee.module as usize).path.as_str(),
                    ta.at_const(pt.callee.node).span.start,
                );
            }
            for k in 0..pt.succ_len {
                line.format_into(" {}", s.succ[(pt.succ_start + k) as usize]);
            }
        }
        out.push(line);
    }
    out.sort();
    return out;
}

// One incremental round, then the full oracle: the records (every pass: analysis, borrow check,
// unused-item lint, recursion), the whole analyzed state and the reachability its scans solve to
// equal a fresh analysis of the same buffers.
fn round_state(
    ws: &Ws,
    p: &mut loader::Package,
    diags: &mut Vector<an::DiagRec>,
    ovf: &Vector<String>,
    ovt: &Vector<String>,
    label: str,
) {
    let mut st = an::RecompileStats {};
    assert(recompile_ov(ws, p, ovf, ovt, diags, &mut st), label);
    let mut rd = Vector::<an::DiagRec>::new();
    let mut rp = fresh(ws, ovf, ovt, &mut rd);
    assert(diags_equal(diags, &rd), label);
    assert(state_equal(p, &rp), label);
    assert(reach_equal(p, &mut rp), label);
}

// True when the coroutine and cancellation reachability solved over `p`'s retained scans equals the
// one solved over a fresh analysis's (`q`): per module (by module path), the same coroutine spans, instance
// spans and cancellation marks, and the same package-wide bits. The states return to unsolved.
fn reach_equal(p: &mut loader::Package, q: &mut loader::Package) bool {
    let ps = replace(&mut p.reach_scans, Vector::<loader::ReachScan>::new());
    p.reach_solve(&ps);
    p.reach_scans = ps;
    let qs = replace(&mut q.reach_scans, Vector::<loader::ReachScan>::new());
    q.reach_solve(&qs);
    q.reach_scans = qs;
    let mut same = p.cancel_used == q.cancel_used && p.cancel_fnv == q.cancel_fnv && p.co_inst.len() == q.co_inst.len();
    for i in 0..p.modules.len() {
        let mut j = q.modules.len();
        for k in 0..q.modules.len() {
            if q.modules.at(k).path.as_str() == p.modules.at(i).path.as_str() {
                j = k;
            }
        }
        if j == q.modules.len() {
            same = false;
            continue;
        }
        same = same && p.co_spans.at(i).eq(q.co_spans.at(j)) && p.cancel_marks.at(i).len() == q.cancel_marks.at(j).len();
        if i < p.co_inst.len() && j < q.co_inst.len() {
            same = same && p.co_inst.at(i).eq(q.co_inst.at(j));
        }
        let mut it = p.cancel_marks.at(i).iter();
        loop {
            switch it.next() {
                Some(e) => {
                    same = same && q.cancel_marks.at(j).contains(e);
                },
                _ => {
                    break;
                },
            };
        }
    }
    if !same {
        eprintln("reach_equal: the solved reachability differs from a fresh analysis's");
    }
    p.co_state = 0;
    p.cancel_state = 0;
    q.co_state = 0;
    q.cancel_state = 0;
    return same;
}

// The text of `base` with the first `from` replaced by `to`.
fn edited(base: str, from: str, to: str) String {
    let at = base.find(from);
    assert(at >= 0, "the edited text holds the replaced text");
    let mut s = String::from_str(base.slice(0, at as usize));
    s.push_str(to);
    s.push_str(base.slice(at as usize + from.len(), base.len()));
    return s;
}

// A series of edits of every kind the incremental path takes (a body splice, a signature edit and
// its revert, a `const fn` body, a borrow error and its fix, a reopen of a closed document), each
// followed by the full state oracle: incremental analysis and a fresh one hold the same state.
@test
fn incr_state_equals_fresh_over_edit_series() {
    let ws = ws_new();
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    ov(&ws, "d.spc", D0, &mut ovf, &mut ovt);
    ov(&ws, "b.spc", B0, &mut ovf, &mut ovt);
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    let mut rd0 = Vector::<an::DiagRec>::new();
    let rp0 = fresh(&ws, &ovf, &ovt, &mut rd0);
    assert(state_equal(&p, &rp0), "two fresh analyses hold the same state");
    ovt.set(0, edited(D0, "let w = v + 1;", "let w = v + 2 + 100;"));
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "body splice");
    ovt.set(
        1,
        edited(
            B0,
            "pub fn bee() i32 {\n    return c::cee() + 1;",
            "pub fn bee(extra: i32) i32 {\n    return c::cee() + extra;",
        ),
    );
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "signature edit");
    assert(errors_in(&p, &diags, "/a.spc") != 0, "the caller reports against the new signature");
    ovt.set(1, String::from_str(B0));
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "signature revert");
    let c1 = edited(C0, "return 2;", "return 5;");
    ov(&ws, "c.spc", c1.as_str(), &mut ovf, &mut ovt);
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "const fn body");
    ovt.set(
        0,
        edited(D0, "let w = v + 1;\n    return w;", "let mut w = v + 1;\n    let r = &w;\n    w += 1;\n    return *r;"),
    );
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "borrow error");
    assert(borrow_errors(&diags) == 1, "the borrow check reports the assignment under the borrow");
    ovt.set(0, String::from_str(D0));
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "borrow fix");
    assert(borrow_errors(&diags) == 0, "the fix clears the borrow record");
    // Close d.spc (its bodies release), then open it again.
    let _ = ovf.remove(0);
    let _ = ovt.remove(0);
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "close");
    ov(&ws, "d.spc", D0, &mut ovf, &mut ovt);
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "reopen");
}

// A plain function's body is read by the constant engine through a `const fn` of another module: a
// body edit there changes an array length two modules away, so the folding module re-analyzes.
@test
fn incr_plain_body_reaches_const_fn_folder() {
    let proj = cli::proj_new();
    proj.mkfile("a.spc", E_A);
    proj.mkfile("c.spc", E_C);
    proj.mkfile("d.spc", E_D);
    let dir = String::from_str(proj.dir());
    let mut root = String::from_str(dir.as_str());
    root.push_str("/a.spc");
    let ws = Ws { proj: proj, root: root, dir: dir };
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    ov(&ws, "d.spc", E_D, &mut ovf, &mut ovt);
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    assert(errors_in(&p, &diags, "/a.spc") == 0, "three elements fill the folded length");
    ovt.set(0, edited(E_D, "return 3;", "return 4;"));
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "plain body read by a const fn");
    assert(errors_in(&p, &diags, "/a.spc") != 0, "the folded length no longer matches the elements");
}

// The constant engine evaluates with the budgets of the root's build: a constant within the
// default step budget but past build.toml's `const-eval-steps` is reported, as the build reports it.
const CE_SRC: str = M"(const fn sum(n: i64) i64 {
    let mut s: i64 = 0;
    let mut i: i64 = 0;
    while i < n {
        s += i;
        i += 1;
    }
    return s;
}

const N: i64 = sum(20000);

fn main() i32 {
    return (N - 199990000) as i32;
}
)";

// The analysis records of `a.spc` under build.toml text `manifest`.
fn budget_records(manifest: str, diags: &mut Vector<an::DiagRec>) {
    let proj = cli::proj_new();
    proj.mkfile("build.toml", manifest);
    proj.mkfile("a.spc", CE_SRC);
    let dir = String::from_str(proj.dir());
    let mut root = String::from_str(dir.as_str());
    root.push_str("/a.spc");
    let ws = Ws { proj: proj, root: root, dir: dir };
    let ovf = Vector::<String>::new();
    let ovt = Vector::<String>::new();
    let _p = fresh(&ws, &ovf, &ovt, diags);
}

@test
fn const_eval_budget_follows_manifest() {
    let mut dflt = Vector::<an::DiagRec>::new();
    budget_records("bin = \"app\"\nroot = \"a.spc\"\n", &mut dflt);
    assert(dflt.len() == 0, "the default budget evaluates the constant");
    let mut small = Vector::<an::DiagRec>::new();
    budget_records("bin = \"app\"\nroot = \"a.spc\"\nconst-eval-steps = 1000\n", &mut small);
    let mut hit = false;
    for i in 0..small.len() {
        if small.at(i).severity == 1 && small.at(i).msg.as_str().contains("const-eval step budget exceeded") {
            hit = true;
        }
    }
    assert(hit, "the manifest's budget is exceeded, as the build reports");
}

// Unbounded-recursion records.
fn recur_errors(diags: &Vector<an::DiagRec>) usize {
    let mut n: usize = 0;
    for i in 0..diags.len() {
        if diags.at(i).phase == an::PH_RECUR && diags.at(i).severity == 1 {
            n += 1;
        }
    }
    return n;
}

// A recursion cycle through two modules is reported in both, and a body edit of one that gives the
// cycle a way out clears both records (the other module's analysis and borrow check stand), as a
// fresh analysis of the same buffers does; the revert reports them again.
@test
fn incr_cross_module_recursion_follows_edits() {
    let c0: str = M"(import b;

pub fn pong(n: i32) i32 {
    if n > 3 {
        return b::ping(n);
    }
    return b::ping(n - 1);
}
)";
    let ws = ws_of(
        M"(import b;
import d;

fn main() i32 {
    return b::ping(1) + d::dee();
}
)",
        M"(import c;

pub fn ping(n: i32) i32 {
    return c::pong(n + 1);
}
)",
        c0,
        M"(pub fn dee() i32 {
    return 0;
}
)",
    );
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    ov(&ws, "c.spc", c0, &mut ovf, &mut ovt);
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    assert(recur_errors(&diags) == 2, "both members of the cycle are reported");
    assert(errors_in(&p, &diags, "/b.spc") == 1, "one record in b");
    assert(errors_in(&p, &diags, "/c.spc") == 1, "one record in c");
    ovt.set(0, edited(c0, "        return b::ping(n);", "        return n;"));
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "cycle broken");
    assert(recur_errors(&diags) == 0, "the edit clears both records");
    ovt.set(0, String::from_str(c0));
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "cycle restored");
    assert(recur_errors(&diags) == 2, "the revert reports both again");
}

// The `@tail_recurse` error a cancellation check after the self call gives follows the reachability
// another module decides: b's function is task-reachable only through a's `launch`, so a body edit of
// a that calls it directly clears b's error (b's analysis stands, its borrow check runs again), and
// the revert reports it again, as fresh analyses of the same buffers do.
@test
fn incr_cancellation_reach_follows_another_module() {
    let a0: str = M"(import b;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;

fn main() i32 {
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        let _ = b::spin(3);
        w.done();
    };
    let _ = rt::request_cancel(rt::current_key(), rt::CR_USER);
    wg.wait();
    rt::shutdown();
    return 0;
}
)";
    let ws = ws_of(
        a0,
        M"(import std::parallel::time as time;

@tail_recurse
pub fn spin(n: i64) i64 {
    if n == 0 {
        return 0;
    }
    time::sleep(time::Duration::from_nanos(1));
    return spin(n - 1);
}
)",
        C0,
        D0,
    );
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    ov(&ws, "a.spc", a0, &mut ovf, &mut ovt);
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    // The runtime's deferred static_asserts read layouts its own check recorded: they fold, and no
    // analysis error holds the borrow checks of its importers back.
    assert(errors_in(&p, &diags, "/parallel/runtime.spc") == 0, "the runtime analyzes without an error");
    assert(cancel_errors(&diags) == 1, "the launched self call keeps a cancellation check after it");
    assert(errors_in(&p, &diags, "/b.spc") == 1, "the error is b's");
    ovt.set(
        0,
        edited(
            a0,
            "launch || {\n        let _ = b::spin(3);\n        w.done();\n    };",
            "let _ = b::spin(3);\n    w.done();",
        ),
    );
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "launch removed");
    assert(cancel_errors(&diags) == 0, "no task runs the function: the error clears");
    ovt.set(0, String::from_str(a0));
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "launch restored");
    assert(cancel_errors(&diags) == 1, "the revert reports it again");
}

fn cancel_errors(diags: &Vector<an::DiagRec>) usize {
    let mut n: usize = 0;
    for i in 0..diags.len() {
        if diags.at(i).phase == an::PH_BORROW && diags.at(i).msg.as_str().contains("it can accept a task cancellation") {
            n += 1;
        }
    }
    return n;
}

// Borrow-check records.
fn borrow_errors(diags: &Vector<an::DiagRec>) usize {
    let mut n: usize = 0;
    for i in 0..diags.len() {
        if diags.at(i).phase == an::PH_BORROW && diags.at(i).severity == 1 {
            n += 1;
        }
    }
    return n;
}

fn always_stop(_ctx: *mut void, _between: bool) bool {
    return true;
}

// A request always waits: the stop the server answers between two checks.
fn stop_between(_ctx: *mut void, between: bool) bool {
    return between;
}

// A round stopped at every module boundary still finishes one check per round, so the owed checks
// end within their count of rounds however many requests arrive.
@test
fn borrow_round_progresses_under_requests() {
    let ws = ws_new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = an::compile(
        ws.root.as_str(),
        ws.dir.as_str(),
        "",
        "std",
        unsafe shim::sc_host_platform(),
        Vector::<String>::new(),
        Vector::<String>::new(),
        "",
        &mut diags,
    );
    let mut owed: usize = 0;
    for m in 0..p.bc_pending.len() {
        if p.bc_pending[m] {
            owed += 1;
        }
    }
    assert(owed == 4, "the four workspace modules owe their checks");
    let fv = Vector::<str>::new();
    let mut rounds: usize = 0;
    for _ in 0..owed + 1 {
        let r = an::borrowck_pending(&mut p, &mut diags, &fv, stop_between, null);
        rounds += 1;
        if !r.canceled {
            break;
        }
        assert(r.checked, "every stopped round finished a check first");
    }
    assert(rounds == owed, "one check per round, and the last round ends unstopped");
    for m in 0..p.bc_pending.len() {
        assert(!p.bc_pending[m], "nothing is owed");
    }
}

// The borrow round runs after the analysis and keeps the bodies it still owes: a round asked to
// stop leaves the check owed and the records as they were; the next round finishes it, and the
// closed module releases its bodies then.
@test
fn borrow_round_stops_and_resumes() {
    let d1 = edited(
        D0,
        "let w = v + 1;\n    return w;",
        "let mut w = v + 1;\n    let r = &w;\n    w += 1;\n    return *r;",
    );
    let ws = ws_of(A0, B0, C0, d1.as_str());
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = an::compile(
        ws.root.as_str(),
        ws.dir.as_str(),
        "",
        "std",
        unsafe shim::sc_host_platform(),
        Vector::<String>::new(),
        Vector::<String>::new(),
        "",
        &mut diags,
    );
    let dm = mod_of(&p, "/d.spc");
    assert(borrow_errors(&diags) == 0, "the analysis alone reports no borrow record");
    assert(dm < p.bc_pending.len(), "the module has a borrow-check record");
    assert(p.bc_pending[dm], "the analysis owes the borrow check");
    assert(!p.modules.at(dm).ast.b.released, "a module that owes its borrow check keeps its bodies");
    let fv = Vector::<str>::new();
    let r = an::borrowck_pending(&mut p, &mut diags, &fv, always_stop, null);
    assert(r.canceled, "a stop ends the round");
    assert(!r.changed, "before the first item");
    assert(p.bc_pending[dm], "the check stays owed");
    assert(borrow_errors(&diags) == 0, "no borrow record yet");
    let r2 = an::borrowck_pending(&mut p, &mut diags, &fv, never_stop, null);
    assert(!r2.canceled, "the next round finishes");
    assert(r2.changed, "the next round changes the records");
    assert(borrow_errors(&diags) == 1, "the borrow record lands");
    assert(!p.bc_pending[dm], "nothing is owed after the round");
    assert(p.modules.at(dm).ast.b.released, "the closed module releases its bodies after its check");
}

// A body edit that changes a function's result attributability (a returned parameter becomes a
// returned local) owes the borrow check of a caller whose analysis stands.
@test
fn borrow_round_follows_result_attributability() {
    let ws = ws_of(
        M"(import b;
import d;

fn main() i32 {
    return b::bee() + d::dee();
}
)",
        M"(import c;

pub fn bee() i32 {
    let x = 1;
    let y = 2;
    return *c::pick(&x, &y);
}
)",
        M"(pub fn pick<'a>(x: &'a i32, y: &'a i32) &'a i32 {
    let _ = y;
    return x;
}
)",
        M"(pub fn dee() i32 {
    return 0;
}
)",
    );
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    let c0 = M"(pub fn pick<'a>(x: &'a i32, y: &'a i32) &'a i32 {
    let _ = y;
    return x;
}
)";
    ov(&ws, "c.spc", c0, &mut ovf, &mut ovt);
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    let bm = mod_of(&p, "/b.spc");
    let cm = mod_of(&p, "/c.spc");
    let pick = probe_decl(&p, cm, "pick");
    assert(p.item_ret_attr(cm as ModuleId, pick) == 1, "a returned parameter attributes the result");
    ovt.set(0, edited(c0, "    return x;", "    let t = x;\n    return t;"));
    let mut fv = Vector::<str>::new();
    let mut tv = Vector::<str>::new();
    fv.push(ovf.at(0).as_str());
    tv.push(ovt.at(0).as_str());
    let mut st = an::RecompileStats {};
    assert(
        an::recompile(&mut p, unsafe shim::sc_host_platform(), ws.root.as_str(), "", &fv, &tv, &mut diags, &mut st),
        "body edit round",
    );
    assert(st.body_only == 1, "the edit is body-only");
    assert(st.analyzed == 1, "the body edit re-analyzes its own module alone");
    assert(p.item_ret_attr(cm as ModuleId, pick) == 0, "a returned local does not attribute the result");
    assert(p.bc_pending[bm], "the caller owes its borrow check again");
    assert(!p.modules.at(bm).ast.b.released, "and its bodies are live for it");
    settle(&mut p, &ovf, &mut diags);
    let mut rd = Vector::<an::DiagRec>::new();
    let rp = fresh(&ws, &ovf, &ovt, &mut rd);
    assert(diags_equal(&diags, &rd), "the records match a fresh analysis");
    assert(state_equal(&p, &rp), "the state matches a fresh analysis");
}

// The unused-item lint is package-wide and follows every edit: a removed call leaves the private
// callee unused, the restored call clears the warning.
@test
fn unused_item_lint_follows_edits() {
    let d0: str = M"(pub fn dee(v: i32) i32 {
    return helper(v);
}

fn helper(v: i32) i32 {
    return v + 1;
}
)";
    let ws = ws_of(A0, B0, C0, d0);
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    ov(&ws, "d.spc", d0, &mut ovf, &mut ovt);
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    assert(unused_warnings(&diags) == 0, "the helper is used");
    ovt.set(0, edited(d0, "return helper(v);", "return v;"));
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "call removed");
    assert(unused_warnings(&diags) == 1, "the helper is unused");
    ovt.set(0, String::from_str(d0));
    round_state(&ws, &mut p, &mut diags, &ovf, &ovt, "call restored");
    assert(unused_warnings(&diags) == 0, "the warning clears");
}

fn unused_warnings(diags: &Vector<an::DiagRec>) usize {
    let mut n: usize = 0;
    for i in 0..diags.len() {
        if diags.at(i).phase == an::PH_UNUSED {
            n += 1;
        }
    }
    return n;
}

// A static_assert the analysis cannot decide in module order (an import cycle types the asserting
// module before the `const fn` it calls) evaluates once every module is typed, and its failure is
// reported as the driver reports it.
@test
fn deferred_static_assert_reports() {
    let proj = cli::proj_new();
    proj.mkfile(
        "a.spc",
        M"(import b;

pub const fn k() i32 {
    return 2;
}

fn main() i32 {
    return b::bee();
}
)",
    );
    proj.mkfile("b.spc", M"(import a;

static_assert(a::k() == 3);

pub fn bee() i32 {
    return 0;
}
)");
    let dir = String::from_str(proj.dir());
    let mut root = String::from_str(dir.as_str());
    root.push_str("/a.spc");
    let ws = Ws { proj: proj, root: root, dir: dir };
    let ovf = Vector::<String>::new();
    let ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let p = fresh(&ws, &ovf, &ovt, &mut diags);
    let bm = mod_of(&p, "/b.spc");
    let mut hit = false;
    for i in 0..diags.len() {
        let d = diags.at(i);
        if d.module as usize == bm && d.severity == 1 && d.msg.as_str() == "static assertion failed" {
            hit = true;
        }
    }
    assert(hit, "the deferred assertion fails");
}

// The declarations of an extern block are items checked before the module's later items, as the
// driver's schedule checks them: a constant or a static of another module reads the size of a header
// struct and of an opaque type with a `@layout` at compile time.
@test
fn incr_extern_type_sizes_fold() {
    let a0: str = "import b;\nfn main() i32 {\n    return unsafe b::A[0] as i32 + unsafe b::B[0] as i32;\n}\n";
    let b0: str = "extern \"C\" \"pthread.h\" {\n    @layout(8, 8)\n    pub type K;\n}\nextern \"C\" \"stdlib.h\" {\n    @import(\"div_t\")\n    pub struct D { pub quot: i32, pub rem: i32 }\n}\npub const N: usize = sizeof(K) / 8;\npub static mut A: [u64; N] = [0u64; N];\npub static mut B: [u64; sizeof(D) / 8] = [0u64; sizeof(D) / 8];\n";
    let ws = ws_of(a0, b0, C0, D0);
    let mut ovf = Vector::<String>::new();
    let mut ovt = Vector::<String>::new();
    ov(&ws, "a.spc", a0, &mut ovf, &mut ovt);
    let mut diags = Vector::<an::DiagRec>::new();
    let p = fresh(&ws, &ovf, &ovt, &mut diags);
    for i in 0..diags.len() {
        eprintln("{}", diags.at(i).msg.as_str());
    }
    assert(errors_in(&p, &diags, "/b.spc") == 0, "the sizes fold");
    assert(diags.len() == 0, "no diagnostic");
}
