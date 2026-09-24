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

// A workspace over four given sources (a.spc is the root).
fn ws_of(a: str, b: str, c: str, d: str) Ws {
    let proj = cli::proj_new();
    proj.mkfile("a.spc", a);
    proj.mkfile("b.spc", b);
    proj.mkfile("c.spc", c);
    proj.mkfile("d.spc", d);
    let dir = String::from_cstr(proj.rootp());
    let mut root = String::from_str(dir.as_str());
    root.push_str("/a.spc");
    return Ws { proj: proj, root: root, dir: dir };
}

// One `an::recompile` round over the test's owned overlays (the server passes borrowed views of its
// documents the same way).
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
    return an::recompile(p, unsafe shim::sc_host_platform(), ws.root.as_str(), "", &fv, &tv, diags, st);
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
    return an::compile(ws.root.as_str(), ws.dir.as_str(), "", "std", unsafe shim::sc_host_platform(), f2, t2, "", diags);
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
    let dir = String::from_cstr(proj.rootp());
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
    assert(ok2 && st2.passes == 0 && st2.bodies_back == 0, "a held module serves the next round directly");
    let mut rd2 = Vector::<an::DiagRec>::new();
    let _rp2 = fresh(&ws, &ovf, &ovt2, &mut rd2);
    assert(diags_equal(&diags, &rd2), "steady state matches fresh");
}
