// Differential rejection parity: every snippet runs through BOTH the established AST
// flow walk and the Core IR loan analysis on one typed package. Both must reject, and (unless a
// case is marked as a reviewed precision difference) a primary error line must coincide. One
// acceptance case pins behavior the established checker permits, so the new analysis cannot drift
// stricter there.
import driver_shim as shim;
import module::loader as loader;
import ast::ast as *;
import resolver::resolver as res;
import typechecker::typechecker as tc;
import borrowck::borrowck as bck;
import consteval::consteval as ce;
import ir::lower as irl;
import borrowck::move_paths as bmp;
import borrowck::facts as bfx;
import borrowck::dataflow as bdf;
import borrowck::loans as bln;

fn t_resolve(p: &mut loader::Package, i: usize) bool {
    let pkg = p as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = replace(&mut m.ast, Ast::new(0));
    let mut r = res::Resolver::new(a, str::from_raw(src as *const u8, len), pkg);
    p.set_override(i as ModuleId, &mut r.ast);
    r.resolve();
    p.clear_override(i as ModuleId);
    let had = r.has_errors();
    if had {
        r.log_errors();
    }
    p.modules[i].ast = r.take_ast();
    return !had;
}

// Type checking plus the ESTABLISHED flow walk; the walk's error offsets land in `old_errs`
// (user-module records only -- earlier modules must stay clean).
fn t_old(p: &mut loader::Package, i: usize, last: bool, old_errs: &mut Vector<u32>) bool {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = replace(&mut m.ast, Ast::new(0));
    let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
    t.bc_mode = 1; // the comparison baseline is the AST walk, whatever the production default
    p.set_override(i as ModuleId, t.ast.get());
    t.check();
    let tc_clean = !t.has_errors();
    if tc_clean {
        t.borrowck();
    }
    if last {
        for e in 0..t.errors.errors.len() {
            old_errs.push(t.errors.errors.at(e).start);
        }
    }
    p.clear_override(i as ModuleId);
    let had = t.has_errors() && !last;
    if had {
        t.log_errors();
    }
    p.modules[i].ast = t.take_ast();
    return tc_clean && !had;
}

// Resolve + typecheck + old flow walk. Asserts the snippet TYPECHECKS; the old walk's verdict
// comes back as user-module error offsets.
fn typed_both(src: str, old_errs: &mut Vector<u32>) loader::Package {
    let mut p = loader::package_from_source(
        src.ptr() as *const char,
        src.len(),
        "std".ptr() as *const char,
        unsafe shim::sc_host_platform(),
    );
    assert(p.ok, "snippet parses");
    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, 0, 0);
    p.ceval = &mut ceval;
    let n = p.modules.len();
    let mut ok = true;
    for i in 0..n {
        ok = t_resolve(&mut p, i) && ok;
    }
    assert(ok, "snippet resolves");
    for i in 0..n {
        ok = t_old(&mut p, i, i == n - 1, old_errs) && ok;
    }
    assert(ok, "snippet typechecks");
    p.ceval = null;
    return p;
}

fn find_fn(p: &loader::Package, name: str) NodeId {
    let u = p.modules.len() - 1;
    let a = unsafe &*p.module_ast_const(u as ModuleId);
    let src = p.modules.at(u).source.as_str();
    let items = a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let nid = unsafe a.list(items)[i as usize];
        if a.at_const(nid).kind != NodeKind::NODE_FUNCTION {
            continue;
        }
        let sp = a.at_const(a.at_const(nid).as_data.function.name).as_data.name.text;
        if src.slice(sp.start as usize, sp.end as usize) == name {
            return nid;
        }
    }
    return NODE_NONE;
}

// Run the new pass over `name`; error start offsets land in `new_errs`.
fn new_verdict(p: &loader::Package, name: str, new_errs: &mut Vector<u32>) {
    let node = find_fn(p, name);
    assert(node != NODE_NONE, "function found");
    let u = (p.modules.len() - 1) as ModuleId;
    let mut lw = irl::Lowerer::new(p, u, node);
    assert(lw.lower_fn(node), "body lowers");
    let mut ow = bfx::Owner::new(p);
    let forest = bmp::MoveForest::build(&lw.body);
    let bfacts = bfx::generate(&mut ow, &lw.body, &forest);
    let cfg = bdf::build_cfg(&lw.body);
    let lv = bdf::solve_liveness(&bfacts, &cfg);
    let mv = bdf::solve_moves(&lw.body, &forest, &bfacts, &cfg);
    let sv = bln::solve(&lw.body, &bfacts, &cfg, &lv);
    for e in 0..mv.errs.len() {
        new_errs.push(mv.errs.at(e).span.start);
    }
    for e in 0..sv.errs.len() {
        new_errs.push(sv.errs.at(e).span.start);
    }
}

const fn line_of(src: str, off: u32) u32 {
    let mut line: u32 = 1;
    let mut i: usize = 0;
    while i < src.len() && i < off as usize {
        if src.byte_at(i) == 10 {
            line += 1;
        }
        i += 1;
    }
    return line;
}

// Both checkers reject, and a primary error line coincides.
fn both_reject_same_line(src: str, name: str) {
    let mut old_errs = Vector::<u32>::new();
    let p = typed_both(src, &mut old_errs);
    assert(old_errs.len() != 0, "the established walk rejects");
    let mut new_errs = Vector::<u32>::new();
    new_verdict(&p, name, &mut new_errs);
    assert(new_errs.len() != 0, "the loan analysis rejects");
    let usrc = p.modules.at(p.modules.len() - 1).source.as_str();
    let mut hit = false;
    for o in 0..old_errs.len() {
        for n in 0..new_errs.len() {
            if line_of(usrc, old_errs[o]) == line_of(usrc, new_errs[n]) {
                hit = true;
            }
        }
    }
    assert(hit, "a primary error line coincides");
    old_errs.free();
    new_errs.free();
}

// ---- coinciding rejections ------------------------------------------------------------------------

@test
fn diff_use_after_move() {
    both_reject_same_line(
        "fn take(s: String) { s.free(); }\nfn main() i32 { let s = String::new(); take(s);\nlet n = s.len();\nreturn n as i32; }",
        "main",
    );
}

@test
fn diff_double_move() {
    both_reject_same_line(
        "fn main() i32 { let s = String::new();\nlet t = s;\nlet u = s;\nt.free(); u.free(); return 0; }",
        "main",
    );
}

@test
fn diff_use_after_free() {
    both_reject_same_line(
        "fn main() i32 { let mut s = String::new();\ns.free();\ns.push_byte(48);\nreturn 0; }",
        "main",
    );
}

@test
fn diff_conditional_uninit() {
    both_reject_same_line(
        "fn f(c: bool) i32 { let x: i32;\nif c { x = 1; }\nreturn x;\n}\nfn main() i32 { return f(true); }",
        "f",
    );
}

@test
fn diff_assign_under_borrow() {
    both_reject_same_line("fn main() i32 { let mut x = 1;\nlet r = &x;\nx = 2;\nreturn *r; }", "main");
}

@test
fn diff_double_mut_borrow() {
    both_reject_same_line(
        "fn main() i32 { let mut x = 1;\nlet a = &mut x;\nlet b = &mut x;\n*a = 2; *b = 3; return x; }",
        "main",
    );
}

@test
fn diff_loop_move() {
    both_reject_same_line(
        "fn take(s: String) { s.free(); }\nfn f(n: i32) { let s = String::new(); let mut i = 0;\nwhile i < n {\ntake(s);\ni += 1; } }\nfn main() i32 { f(0); return 0; }",
        "f",
    );
}

@test
fn diff_return_local_borrow() {
    both_reject_same_line("fn f() &i32 { let x = 1;\nreturn &x;\n}\nfn main() i32 { return *f(); }", "f");
}

@test
fn diff_scope_dangle() {
    both_reject_same_line("fn main() i32 { let r: &i32;\n{\nlet x = 1;\nr = &x;\n}\nreturn *r; }", "main");
}

@test
fn diff_out_param_store() {
    // Store-through-out-param escapes belong to the walk's declared-lifetime checks in BOTH modes;
    // the parity bar is the PRODUCTION pipeline, so compare full borrowck old vs new.
    let src = "fn f(out: &mut &i32) { let x = 1;\n*out = &x;\n}\nfn main() i32 { let g = 5; let mut slot: &i32 = &g; f(&mut slot); return *slot; }";
    let mut old_errs = Vector::<u32>::new();
    let mut p = typed_both(src, &mut old_errs);
    assert(old_errs.len() != 0, "the established walk rejects");
    let mut new_errs = Vector::<u32>::new();
    prod_verdict(&mut p, &mut new_errs);
    assert(new_errs.len() != 0, "the production Core IR mode rejects");
    let usrc = p.modules.at(p.modules.len() - 1).source.as_str();
    let mut hit = false;
    for o in 0..old_errs.len() {
        for n in 0..new_errs.len() {
            if line_of(usrc, old_errs[o]) == line_of(usrc, new_errs[n]) {
                hit = true;
            }
        }
    }
    assert(hit, "a primary error line coincides");
    old_errs.free();
    new_errs.free();
}

// Run the full PRODUCTION borrowck (Core IR mode) over the user module; error offsets land in `out`.
fn prod_verdict(p: &mut loader::Package, out: &mut Vector<u32>) {
    let pkg = p as *mut loader::Package;
    let i = p.modules.len() - 1;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = replace(&mut m.ast, Ast::new(0));
    let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
    t.bc_mode = 2;
    p.set_override(i as ModuleId, t.ast.get());
    t.borrowck();
    p.clear_override(i as ModuleId);
    for e in 0..t.errors.errors.len() {
        out.push(t.errors.errors.at(e).start);
    }
    let back = t.take_ast();
    p.modules[i].ast = back;
}

// ---- reviewed differences -------------------------------------------------------------------------

@test
fn diff_partial_move_reviewed() {
    // The established walk rejects the FIELD MOVE itself (`takes(p.a)`: no partial moves out of a
    // Free value). The loan analysis tracks the partial move and rejects the later WHOLE-VALUE use
    // instead -- one line later, by design (location-sensitive precision; drop elaboration owns the
    // remaining-fields story).
    let mut old_errs = Vector::<u32>::new();
    let p = typed_both(
        "struct P { pub a: String, pub b: String }\nfn takes(s: String) { s.free(); }\nfn takep(p: P) { let _ = p; }\nfn main() i32 { let p = P { a: String::new(), b: String::new() };\ntakes(p.a);\ntakep(p);\nreturn 0; }",
        &mut old_errs,
    );
    assert(old_errs.len() != 0, "the established walk rejects the field move");
    let mut new_errs = Vector::<u32>::new();
    new_verdict(&p, "main", &mut new_errs);
    assert(new_errs.len() != 0, "the loan analysis rejects the whole-value use");
    old_errs.free();
    new_errs.free();
}

@test
fn diff_return_field_move_reviewed() {
    // Closed checker hole: `return q.a` moves a field out of a Free value exactly like a call
    // argument does, and the established walk now rejects it in return position too (the emitter
    // would silently leak the sibling field). The loan analysis tracks the partial move and
    // accepts; that stays a reviewed difference until elaborated drops reach the backend.
    let mut old_errs = Vector::<u32>::new();
    let p = typed_both(
        "struct Q { pub a: String, pub b: String }\nfn f(q: Q) String {\nreturn q.a;\n}\nfn main() i32 { let q = Q { a: String::new(), b: String::new() }; f(q).free(); return 0; }",
        &mut old_errs,
    );
    assert(old_errs.len() != 0, "the established walk rejects the return-position field move");
    let mut new_errs = Vector::<u32>::new();
    new_verdict(&p, "f", &mut new_errs);
    assert(new_errs.len() == 0, "the loan analysis tracks the partial move");
    old_errs.free();
    new_errs.free();
}

// ---- acceptance parity ----------------------------------------------------------------------------

@test
fn diff_closure_capture_accepted() {
    // The established walk permits writes to a mutably captured variable while the closure is
    // live; capture loans must not reject it either (they only guard storage death and escapes).
    let mut old_errs = Vector::<u32>::new();
    let p = typed_both(
        "fn main() i32 { let mut x = 1;\nlet c = || { x += 1; };\nx += 2;\nc();\nreturn x; }",
        &mut old_errs,
    );
    assert(old_errs.len() == 0, "the established walk accepts");
    let mut new_errs = Vector::<u32>::new();
    new_verdict(&p, "main", &mut new_errs);
    assert(new_errs.len() == 0, "the loan analysis accepts");
    old_errs.free();
    new_errs.free();
}
