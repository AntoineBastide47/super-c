// Drop-elaboration cases: partial moves, early returns, loops, match arms, and
// conditional destruction produce the right schedule against the move/init dataflow, and the
// rewritten bodies stay verifiable Core IR with explicit drop terminators.
import driver_shim as shim;
import module::loader as loader;
import ast::ast as *;
import resolver::resolver as res;
import typechecker::typechecker as tc;
import ir::interp as iri;
import ir::core as irc;
import ir::lower as irl;
import ir::verify as irv;
import ir::drops as ird;
import borrowck::move_paths as bmp;
import borrowck::facts as bfx;
import borrowck::dataflow as bdf;

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

struct DropCounts {
    pub uncond: u32,
    pub cond: u32,
    pub fields: u32,
}

// Elaborate `name`, assert the rewritten body still verifies, and return schedule counts.
fn schedule(p: &loader::Package, name: str) DropCounts {
    let node = find_fn(p, name);
    assert(node != NODE_NONE, "function found");
    let u = (p.modules.len() - 1) as ModuleId;
    let mut lw = irl::Lowerer::new(p, u, node);
    assert(lw.lower_fn(node), "body lowers");
    let mut ow = bfx::Owner::new(p);
    let forest = bmp::MoveForest::build(&lw.body);
    let bfacts = ow.generate(&lw.body, &forest);
    let cfg = bdf::build_cfg(&lw.body);
    let mv = bdf::solve_moves(&lw.body, &forest, &bfacts, &cfg);
    let mut ecx = ird::ElabCtx::empty();
    ird::elaborate_into(&mut ow, &lw.body, &forest, &bfacts, &mv, &mut ecx);
    let sched = &ecx.sched;
    let mut c = DropCounts { uncond: 0, cond: 0, fields: 0 };
    let mut overs: u32 = 0;
    for d in 0..sched.drops.len() {
        let k = sched.drops.at(d).kind;
        if k == ird::DK_UNCOND {
            c.uncond += 1;
        } else if k == ird::DK_COND {
            c.cond += 1;
        } else if k == ird::DK_OVER || k == ird::DK_OVERC {
            overs += 1;
        } else {
            c.fields += 1;
        }
    }
    ird::insert_drops(&mut lw.body, sched, &forest);
    let tp = unsafe (&*p.module_ast_const(u)).type_pool.len();
    assert(irv::verify(&lw.body, tp, p).len() == 0, "rewritten body verifies");
    // Explicit drop terminators exist for every whole-value entry.
    let mut drops_in_ir: u32 = 0;
    for b in 0..lw.body.blocks.len() {
        if lw.body.blocks.at(b).term.kind == irc::TM_DROP {
            drops_in_ir += 1;
        }
    }
    // whole-value, overwrite AND still-owned-field entries all rewrite to explicit terminators
    assert(drops_in_ir == c.uncond + c.cond + overs + c.fields, "one Drop terminator per schedule entry");
    return c;
}

@test
fn simple_scope_drop() {
    let p = typed_package("fn main() i32 { let s = String::new(); let n = s.len(); return n as i32; }");
    let c = schedule(&p, "main");
    assert(c.uncond == 1 && c.cond == 0, "one unconditional drop");
}

@test
fn moved_out_omitted() {
    let p = typed_package(
        "fn take(s: String) { s.free(); }\nfn main() i32 { let s = String::new(); take(s); return 0; }",
    );
    let c = schedule(&p, "main");
    assert(c.uncond == 0 && c.cond == 0, "a moved value is not dropped");
}

@test
fn conditional_move_flagged() {
    let p = typed_package(
        "fn take(s: String) { s.free(); }\nfn f(c: bool) { let s = String::new(); if c { take(s); } }\nfn main() i32 { f(true); return 0; }",
    );
    let c = schedule(&p, "f");
    assert(c.cond == 1, "a maybe-moved value gets one flag-guarded drop");
}

@test
fn early_return_and_loop() {
    // The early return, the per-iteration scope, and the fall-off exit each destroy correctly.
    let p = typed_package(
        "fn f(n: i32) i32 { let s = String::new(); let mut i = 0; while i < n { let t = String::new(); if i == 3 { return s.len() as i32 + t.len() as i32; } i += 1; } return s.len() as i32; }\nfn main() i32 { return f(0); }",
    );
    let c = schedule(&p, "f");
    assert(c.uncond >= 3, "loop body, early return, and fall-off exits all drop");
}

@test
fn partial_move_field_drops() {
    // After a field moves out, only the still-owned sibling drops (per-field entries).
    let p = typed_package(
        "struct P { pub a: String, pub b: String }\nfn takes(s: String) { s.free(); }\nfn main() i32 { let p = P { a: String::new(), b: String::new() }; takes(p.a); return 0; }",
    );
    let c = schedule(&p, "main");
    assert(c.fields == 1, "exactly the unmoved field drops");
    assert(c.uncond == 0 && c.cond == 0, "no whole-value drop after a partial move");
}

@test
fn tuple_partial_move_field_drops() {
    // The tuple analogue of partial_move_field_drops: a tuple member's move path is keyed
    // positionally, so the still-owned member must resolve through `tuple_child` (a named-key
    // lookup misses it, leaving the MOVED member falsely live -- a second drop, i.e. a double free).
    let p = typed_package(
        "struct T(String, String);\nfn takes(s: String) { s.free(); }\nfn main() i32 { let t = T(String::new(), String::new()); takes(t.0); return 0; }",
    );
    let c = schedule(&p, "main");
    assert(c.fields == 1, "exactly the unmoved tuple member drops");
    assert(c.uncond == 0 && c.cond == 0, "no whole-value drop after a partial tuple move");
}

@test
fn match_arm_payload() {
    // A by-value payload binding consumed in one arm drops there and nowhere else.
    let p = typed_package(
        "fn mk(c: bool) Option<String> { if c { return Option::<String>::Some(String::new()); } return Option::<String>::None; }\nfn main() i32 { switch mk(true) { Some(s) => { let n = s.len(); let _ = n; }, None => {} }; return 0; }",
    );
    let c = schedule(&p, "main");
    assert(c.uncond >= 1, "the bound payload drops at its arm's end");
}

@test
fn owning_param_drops() {
    let p = typed_package(
        "fn eat(s: String) i32 { return s.len() as i32; }\nfn main() i32 { return eat(String::new()); }",
    );
    let c = schedule(&p, "eat");
    assert(c.uncond == 1, "an owning by-value parameter drops at the exit");
}
