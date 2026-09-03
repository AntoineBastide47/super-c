// Core IR loan-analysis precision tests: each case states what it checks; safety
// rejection, location-sensitive precision, two-phase behavior, or solver scaling, and runs the
// full move/loan pipeline on a lowered body. Snippets typecheck WITHOUT the established flow walk,
// so rejection cases exercise this analysis alone; the reference solver must agree wherever it runs.
import driver_shim as shim;
import module::loader as loader;
import ast::ast as *;
import resolver::resolver as res;
import typechecker::typechecker as tc;
import ir::interp as iri;
import ir::lower as irl;
import ir::verify as irv;
import borrowck::move_paths as bmp;
import borrowck::facts as bfx;
import borrowck::dataflow as bdf;
import borrowck::loans as bln;

fn t_resolve(p: &mut loader::Package, i: usize) bool {
    let pkg = p as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut r = res::Resolver::new(unsafe &mut *((&mut m.ast) as *mut Ast), str::from_raw(src as *const u8, len), pkg);
    r.resolve();
    let had = r.has_errors();
    if had {
        r.log_errors();
    }
    return !had;
}

// Type checking only: the established flow walk stays off so rejection snippets still lower.
fn t_typecheck(p: &mut loader::Package, i: usize) bool {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut t = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
    t.check();
    let had = t.has_errors();
    if had {
        t.log_errors();
    }
    return !had;
}

fn typed_package(src: str) loader::Package {
    let mut p = loader::package_from_source(src, "std", unsafe shim::sc_host_platform());
    assert(p.ok, "snippet parses");
    let pkg = (&mut p) as *mut loader::Package;
    let mut cirv = iri::interp_new(pkg);
    p.cir = &mut cirv;
    let n = p.modules.len();
    let mut ok = true;
    for i in 0..n {
        ok = t_resolve(&mut p, i) && ok;
    }
    assert(ok, "snippet resolves");
    for i in 0..n {
        ok = t_typecheck(&mut p, i) && ok;
    }
    assert(ok, "snippet typechecks");
    p.cir = null;
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

struct BorrowOut {
    pub moves: u32, // distinct move/init error sites
    pub conflicts: u32,
    pub escapes: u32,
}

// Lower `name`, run the full pipeline, and count DISTINCT error sites (loops and defers replay
// statements, so raw error records repeat).
fn analyze(p: &loader::Package, name: str) BorrowOut {
    let node = find_fn(p, name);
    assert(node != NODE_NONE, "function found");
    let u = (p.modules.len() - 1) as ModuleId;
    let mut lw = irl::Lowerer::new(p, u, node);
    assert(lw.lower_fn(node), "body lowers");
    let tp = unsafe (&*p.module_ast_const(u)).type_pool.len();
    assert(irv::verify(&lw.body, tp, p).len() == 0, "body verifies");
    let mut ow = bfx::Owner::new(p);
    let forest = bmp::MoveForest::build(&lw.body);
    let bfacts = ow.generate(&lw.body, &forest);
    let cfg = bdf::build_cfg(&lw.body);
    let lv = bdf::solve_liveness(&bfacts, &cfg);
    let mv = bdf::solve_moves(&lw.body, &forest, &bfacts, &cfg);
    let sv = bln::solve(&lw.body, &bfacts, &cfg, &lv);
    let mut out = BorrowOut { moves: 0, conflicts: 0, escapes: 0 };
    let mut seen = Vector::<u64>::new();
    for e in 0..mv.errs.len() {
        let er = *mv.errs.at(e);
        let key = er.kind as u64 << 32 | er.span.start as u64;
        let mut dup = false;
        for k in 0..seen.len() {
            if seen[k] == key {
                dup = true;
            }
        }
        if !dup {
            seen.push(key);
            out.moves += 1;
        }
    }
    for e in 0..sv.errs.len() {
        let er = *sv.errs.at(e);
        let key = 0x8000000000000000u64 | er.kind as u64 << 32 | er.span.start as u64;
        let mut dup = false;
        for k in 0..seen.len() {
            if seen[k] == key {
                dup = true;
            }
        }
        if dup {
            continue;
        }
        seen.push(key);
        if er.kind == bln::BE_CONFLICT {
            out.conflicts += 1;
        } else {
            assert(er.kind == bln::BE_ESCAPE, "solver error kinds are conflict or escape");
            out.escapes += 1;
        }
    }
    return out;
}

const fn clean(o: &BorrowOut) bool {
    return o.moves == 0 && o.conflicts == 0 && o.escapes == 0;
}

// The optimized and reference solvers must produce identical required-point sets per loan.
fn ref_agrees(p: &loader::Package, name: str) bool {
    let node = find_fn(p, name);
    let u = (p.modules.len() - 1) as ModuleId;
    let mut lw = irl::Lowerer::new(p, u, node);
    assert(lw.lower_fn(node), "body lowers");
    let mut ow = bfx::Owner::new(p);
    let forest = bmp::MoveForest::build(&lw.body);
    let bfacts = ow.generate(&lw.body, &forest);
    let cfg = bdf::build_cfg(&lw.body);
    let lv = bdf::solve_liveness(&bfacts, &cfg);
    let rr = bln::solve_reference(&lw.body, &bfacts, &cfg, &lv);
    let mut sv = bln::solve(&lw.body, &bfacts, &cfg, &lv);
    let mut same = true;
    for li in 0..bfacts.loans.len() {
        let row = sv.required_row(li as u32);
        for w in 0..rr.pwords {
            if *rr.required.at((li as u32 * rr.pwords + w) as usize) != sv.req_word(row, w) {
                same = false;
            }
        }
    }
    return same;
}

@test
fn use_after_move_rejected() {
    // Safety rejection: a second use of a moved owning value.
    let p = typed_package(
        "fn take(s: String) { s.free(); }\nfn main() i32 { let s = String::new(); take(s); let n = s.len(); return n as i32; }",
    );
    let o = analyze(&p, "main");
    assert(o.moves != 0, "use after move reported");
}

@test
fn conditional_move_rejected() {
    // Safety rejection: moved on one path, used after the join.
    let p = typed_package(
        "fn take(s: String) { s.free(); }\nfn f(c: bool) usize { let s = String::new(); if c { take(s); } return s.len(); }\nfn main() i32 { return f(true) as i32; }",
    );
    let o = analyze(&p, "f");
    assert(o.moves != 0, "maybe-moved use reported");
}

@test
fn loop_double_move_rejected() {
    // Safety rejection: a loop body that consumes the same owned value every iteration.
    let p = typed_package(
        "fn take(s: String) { s.free(); }\nfn f(n: i32) { let s = String::new(); let mut i = 0; while i < n { take(s); i += 1; } }\nfn main() i32 { f(0); return 0; }",
    );
    let o = analyze(&p, "f");
    assert(o.moves != 0, "loop move reported");
}

@test
fn partial_move_whole_use_rejected() {
    // Safety rejection: whole-value use while a field is moved out.
    let p = typed_package(
        "struct P { pub a: String, pub b: String }\nfn takes(s: String) { s.free(); }\nfn takep(p: P) { let _ = p; }\nfn main() i32 { let p = P { a: String::new(), b: String::new() }; takes(p.a); takep(p); return 0; }",
    );
    let o = analyze(&p, "main");
    assert(o.moves != 0, "partial move reported");
}

@test
fn conditional_uninit_rejected() {
    // Safety rejection: definite initialization fails on the untaken path.
    let p = typed_package(
        "fn f(c: bool) i32 { let x: i32; if c { x = 1; } return x; }\nfn main() i32 { return f(true); }",
    );
    let o = analyze(&p, "f");
    assert(o.moves != 0, "maybe-uninit read reported");
}

@test
fn split_init_accepted() {
    // Precision: both-branch late initialization is definite.
    let p = typed_package(
        "fn f(c: bool) i32 { let x: i32; if c { x = 1; } else { x = 2; } return x; }\nfn main() i32 { return f(true); }",
    );
    let o = analyze(&p, "f");
    assert(clean(&o), "split init accepted");
}

@test
fn overlapping_mut_borrows_rejected() {
    // Safety rejection: two exclusive borrows of one place, both live.
    let p = typed_package("fn main() i32 { let mut x = 1; let a = &mut x; let b = &mut x; *a = 2; *b = 3; return x; }");
    let o = analyze(&p, "main");
    assert(o.conflicts != 0, "overlapping exclusive borrows reported");
}

@test
fn shared_then_write_rejected() {
    // Safety rejection: writing the borrowed place while the shared borrow is still read.
    let p = typed_package("fn main() i32 { let mut x = 1; let r = &x; x = 2; return *r; }");
    let o = analyze(&p, "main");
    assert(o.conflicts != 0, "write under shared borrow reported");
}

@test
fn nll_last_use_accepted() {
    // Location-sensitive precision: the borrow's last use precedes the write.
    let p = typed_package("fn main() i32 { let mut x = 1; let r = &x; let v = *r; x = 2; return v + x; }");
    let o = analyze(&p, "main");
    assert(clean(&o), "dead borrow does not block the write");
}

@test
fn branch_killed_loan_accepted() {
    // Location-sensitive precision: the loan escapes on one branch and is replaced on the other
    // before the mutation.
    let p = typed_package(
        "fn f(c: bool) i32 { let mut x = 1; let mut y = 2; let mut r = &x; if c { return *r; } r = &y; x = 3; return *r + x; }\nfn main() i32 { return f(false); }",
    );
    let o = analyze(&p, "f");
    assert(clean(&o), "replaced reference frees the source");
}

@test
fn loop_reassign_kills_accepted() {
    // Location-sensitive precision: reassignment ends the prior loan before the next iteration.
    let p = typed_package(
        "fn f(n: i32) i32 { let mut x = 1; let y = 2; let mut r = &y; let mut acc = 0; let mut i = 0; while i < n { x += 1; r = &x; acc += *r; i += 1; } return acc; }\nfn main() i32 { return f(2); }",
    );
    let o = analyze(&p, "f");
    let _ = o;
    assert(o.conflicts == 0, "per-iteration reference does not conflict");
}

@test
fn disjoint_fields_accepted() {
    // Precision: exclusive borrows of disjoint fields coexist.
    let p = typed_package(
        "struct P { pub a: i32, pub b: i32 }\nfn main() i32 { let mut p = P { a: 1, b: 2 }; let ra = &mut p.a; let rb = &mut p.b; *ra = 3; *rb = 4; return p.a + p.b; }",
    );
    let o = analyze(&p, "main");
    assert(clean(&o), "disjoint fields coexist");
}

@test
fn same_field_mut_rejected() {
    // Safety rejection: two exclusive borrows of the same field.
    let p = typed_package(
        "struct P { pub a: i32, pub b: i32 }\nfn main() i32 { let mut p = P { a: 1, b: 2 }; let ra = &mut p.a; let rb = &mut p.a; *ra = 3; *rb = 4; return p.a; }",
    );
    let o = analyze(&p, "main");
    assert(o.conflicts != 0, "same-field exclusive borrows reported");
}

@test
fn reborrow_orders() {
    // Reborrows through assignments: using the source reference after the reborrow's last use is
    // legal; writing through it while the reborrow is live is not.
    let p = typed_package(
        "fn ok() i32 { let mut x = 1; let r = &mut x; let r2 = &mut *r; *r2 = 5; *r = 6; return x; }\nfn bad() i32 { let mut x = 1; let r = &mut x; let r2 = &mut *r; *r = 6; *r2 = 5; return x; }\nfn main() i32 { return ok() + bad(); }",
    );
    let a = analyze(&p, "ok");
    assert(clean(&a), "sequential reborrow accepted");
    let b = analyze(&p, "bad");
    assert(b.conflicts != 0, "interleaved reborrow reported");
}

@test
fn two_phase_receiver_accepted() {
    // Two-phase behavior: the receiver's exclusive borrow tolerates argument reads.
    let p = typed_package(
        "fn main() i32 { let mut v = Vector::<usize>::new(); v.push(v.len()); return v.len() as i32; }",
    );
    let o = analyze(&p, "main");
    assert(clean(&o), "reserved receiver borrow tolerates argument reads");
}

@test
fn local_escape_rejected() {
    // Safety rejection: a borrow of local storage reaches the caller.
    let p = typed_package("fn f() &i32 { let x = 1; return &x; }\nfn main() i32 { return *f(); }");
    let o = analyze(&p, "f");
    assert(o.escapes != 0, "local borrow escape reported");
}

@test
fn arg_passthrough_accepted() {
    // An argument-derived reference returns legally under elision.
    let p = typed_package(
        "struct W { pub v: i32 }\nfn f(w: &W) &i32 { return &w.v; }\nfn main() i32 { let w = W { v: 3 }; return *f(&w); }",
    );
    let o = analyze(&p, "f");
    assert(clean(&o), "argument reborrow returns");
}

@test
fn many_loans_scale() {
    // Solver scaling: enough live loans to spill the one-word loan set.
    let mut src = String::new();
    src.push_str("fn main() i32 { let mut acc = 0;\n");
    for i in 0..70 {
        src.push_str("let x");
        src.push_u64(i as u64);
        src.push_str(" = ");
        src.push_u64(i as u64);
        src.push_str("; let r");
        src.push_u64(i as u64);
        src.push_str(" = &x");
        src.push_u64(i as u64);
        src.push_str(";\n");
    }
    for i in 0..70 {
        src.push_str("acc += *r");
        src.push_u64(i as u64);
        src.push_str(";\n");
    }
    src.push_str("return acc; }\n");
    let p = typed_package(src.as_str());
    let o = analyze(&p, "main");
    assert(clean(&o), "dense loan set accepted");
}

@test
fn reference_solver_agrees() {
    // Implementation fidelity: diamonds, loops, kills, reborrows, and two-phase shapes produce
    // identical required-point sets in both solvers.
    let p = typed_package(
        "fn f(c: bool, n: i32) i32 { let mut x = 1; let mut y = 2; let mut r = &x; if c { r = &y; } let mut acc = 0; let mut i = 0; while i < n { acc += *r; r = &x; i += 1; } let m = &mut x; *m = 4; return acc + x; }\nfn main() i32 { return f(true, 2); }",
    );
    assert(ref_agrees(&p, "f"), "required sets agree");
    let q = typed_package(
        "fn g() i32 { let mut v = Vector::<usize>::new(); v.push(v.len()); let mut x = 5; let r = &mut x; let r2 = &mut *r; *r2 = 6; return x; }\nfn main() i32 { return g(); }",
    );
    assert(ref_agrees(&q, "g"), "reborrow and two-phase shapes agree");
}
