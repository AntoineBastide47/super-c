// The incremental-analysis oracle: every scripted edit runs through analysis::recompile against a
// retained package AND through a from-scratch analysis::compile of the same overlays, then the two
// must agree: diagnostics as a multiset, and name-resolution probes at sampled positions. The
// RecompileStats counters additionally pin the exit-gate observables: a body edit re-analyzes ONE
// module (importers untouched), a signature edit re-analyzes exactly the importers' closure, a
// `const fn` body edit is interface-class (CTFE reads it cross-module), an import edit or syntax
// error leaves the incremental domain entirely (recompile refuses; the caller full-rebuilds).
import lsp::analysis as an;
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
    for i in 1..a.nodes.len() {
        let n = a.at_const(i as NodeId);
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
        let d = a.resolution_def(i as NodeId);
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
    let ok = an::recompile(p, unsafe shim::sc_host_platform(), ws.root.as_str(), "", ovf, ovt, diags, st);
    assert(ok, label);
    let mut rd = Vector::<an::DiagRec>::new();
    let rp = fresh(ws, ovf, ovt, &mut rd);
    assert(diags_equal(diags, &rd), label);
    let am = mod_of(p, "/a.spc");
    assert(probe_res(p, am, "bee") == probe_res(&rp, mod_of(&rp, "/a.spc"), "bee"), label);
    assert(probe_res(p, am, "dee") == probe_res(&rp, mod_of(&rp, "/a.spc"), "dee"), label);
}

@test
fn incr_noop_round() {
    let ws = ws_new();
    let ovf = Vector::<String>::new();
    let ovt = Vector::<String>::new();
    let mut diags = Vector::<an::DiagRec>::new();
    let mut p = fresh(&ws, &ovf, &ovt, &mut diags);
    let mut st = an::RecompileStats {};
    let ok = an::recompile(
        &mut p,
        unsafe shim::sc_host_platform(),
        ws.root.as_str(),
        "",
        &ovf,
        &ovt,
        &mut diags,
        &mut st,
    );
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
    assert(st.analyzed == 3, "the const owner and its transitive importers re-analyze");
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
    let ok = an::recompile(
        &mut p,
        unsafe shim::sc_host_platform(),
        ws.root.as_str(),
        "",
        &ovf,
        &ovt,
        &mut diags,
        &mut st,
    );
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
    let ok = an::recompile(
        &mut p,
        unsafe shim::sc_host_platform(),
        ws.root.as_str(),
        "",
        &ovf,
        &ovt,
        &mut diags,
        &mut st,
    );
    assert(!ok, "a parse error falls back to the full compile");
}
