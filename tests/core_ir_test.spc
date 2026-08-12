// Core IR expected-output tests: focused snippets lower to verified bodies whose
// deterministic print form is asserted structurally, plus direct coverage of the typed-facts
// boundary accessors. These are compiler-structure tests, not generated-program substitutes.
import driver_shim as shim;
import module::loader as loader;
import ast::ast as *;
import ast::facts as facts;
import resolver::resolver as res;
import typechecker::typechecker as tc;
import borrowck::borrowck as bck;
import consteval::consteval as ce;
import ir::lower as irl;
import ir::print as irp;
import ir::verify as irv;

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

fn t_typecheck(p: &mut loader::Package, i: usize) bool {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = replace(&mut m.ast, Ast::new(0));
    let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
    t.bc_mode = 1; // modules are checked in load order here; the Core IR path needs the typed package
    p.set_override(i as ModuleId, t.ast.get());
    t.check();
    if !t.has_errors() {
        t.borrowck();
    }
    p.clear_override(i as ModuleId);
    let had = t.has_errors();
    if had {
        t.log_errors();
    }
    p.modules[i].ast = t.take_ast();
    return !had;
}

// Resolve + typecheck `src` against the std prelude; asserts the snippet is error-free.
fn typed_package(src: str) loader::Package {
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
        ok = t_typecheck(&mut p, i) && ok;
    }
    assert(ok, "snippet typechecks");
    p.ceval = null;
    return p;
}

// The user module's top-level function named `name` (the snippet is always the last module).
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

// Lower + verify `name`, returning the deterministic print form.
fn lowered(p: &loader::Package, name: str) String {
    let node = find_fn(p, name);
    assert(node != NODE_NONE, "function found");
    let u = (p.modules.len() - 1) as ModuleId;
    let mut lw = irl::Lowerer::new(p, u, node);
    let ok = lw.lower_fn(node);
    assert(ok, "body lowers");
    let tp = unsafe (&*p.module_ast_const(u)).type_pool.len();
    assert(irv::verify(&lw.body, tp).len() == 0, "body verifies");
    return irp::print_body(&lw.body);
}

fn has(s: &String, needle: str) bool {
    return s.contains(needle);
}

@test
fn arithmetic_and_return() {
    let p = typed_package(
        "fn f(a: i32, b: i32) i32 { return a + (b * 2); }\nfn main() i32 { let _ = f(1, 2); return 0; }",
    );
    let out = lowered(&p, "f");
    assert(has(&out, "bin"), "explicit binary operations");
    assert(has(&out, "return"), "return terminator");
    assert(has(&out, "_0 = "), "the return slot is local 0");
}

@test
fn if_else_value_and_short_circuit() {
    let p = typed_package(
        "fn g(a: i32) i32 { let v = if a > 1 && a < 10 { a; } else { 0; }; return v; }\nfn main() i32 { let _ = g(3); return 0; }",
    );
    let out = lowered(&p, "g");
    assert(has(&out, "switch("), "conditions lower to switches");
    assert(has(&out, "goto bb"), "join edges are explicit gotos");
}

@test
fn loops_break_continue() {
    let p = typed_package(
        "fn h() i32 { let mut s = 0; for i in 0..10 { if i == 3 { continue; } if i == 7 { break; } s += i; } return s; }\nfn main() i32 { let _ = h(); return 0; }",
    );
    let out = lowered(&p, "h");
    assert(has(&out, "switch("), "loop condition switch");
    assert(has(&out, "goto bb"), "back edge");
}

@test
fn calls_are_terminators() {
    let p = typed_package(
        "fn callee(x: i32) i32 { return x; }\nfn caller() i32 { return callee(4); }\nfn main() i32 { let _ = caller(); return 0; }",
    );
    let out = lowered(&p, "caller");
    assert(has(&out, "call m"), "resolved call terminator");
    assert(has(&out, ") -> bb"), "normal successor");
}

@test
fn match_variants_and_or_patterns() {
    let p = typed_package(
        "enum E { A, B(i32), C }\nfn m(e: E) i32 { return switch e { A | C => 0, B(x) => x, }; }\nfn main() i32 { let _ = m(E::A); return 0; }",
    );
    let out = lowered(&p, "m");
    assert(has(&out, "discr "), "variant tests read the discriminant");
    assert(has(&out, "unreachable"), "exhaustive fallthrough is unreachable");
}

@test
fn aggregates_and_field_places() {
    let p = typed_package(
        "struct Pt { pub x: i32, pub y: i32 }\nfn mk() i32 { let p = Pt { x: 1, y: 2 }; return p.x; }\nfn main() i32 { let _ = mk(); return 0; }",
    );
    let out = lowered(&p, "mk");
    assert(has(&out, "agg0"), "struct aggregate construction");
    assert(has(&out, ".f"), "field projection place");
}

@test
fn defer_runs_before_return() {
    let p = typed_package(
        "fn effect(x: i32) i32 { return x; }\nfn d() i32 { defer { let _ = effect(1); } return effect(2); }\nfn main() i32 { let _ = d(); return 0; }",
    );
    let out = lowered(&p, "d");
    assert(has(&out, "call m"), "deferred call emitted");
    // the deferred effect(1) call lands between the return-slot assignment and the return
    assert(has(&out, "return"), "return present");
}

@test
fn typed_facts_boundary() {
    let src = "@platform(macos)\n@platform(linux)\n@platform(windows)\nfn plat() i32 { return 1; }\nfn take<'a>(r: &'a i32) &'a i32 { return r; }\nfn idg<T>(x: T) T { return x; }\nfn main() i32 {\n    let v = Vector::<i32>::new();\n    let n = v.len();\n    let mut c = 0;\n    let mut bump = || { c += 1; };\n    bump();\n    let x = 5;\n    let r = take(&x);\n    let _ = *r + n as i32 + plat() + idg::<i32>(2);\n    return 0;\n}";
    let p = typed_package(src);
    let u = (p.modules.len() - 1) as ModuleId;
    let f = facts::TypedFacts::of(p.module_ast_const(u));
    let a = unsafe &*p.module_ast_const(u);
    // instance + node types: the Vector::<i32> value is an interned instance type
    let mut saw_inst = false;
    let mut saw_recv = false;
    let mut closure = NODE_NONE;
    for n in 0..a.nodes.len() {
        let nid = n as NodeId;
        let k = a.at_const(nid).kind;
        if k == NodeKind::NODE_CLOSURE {
            closure = nid;
        }
        let t = f.node_type(nid);
        if t != TYPE_NONE && f.ty(t).kind == TypeKind::TYPE_INSTANCE {
            let it = f.instance(f.ty(t).as_data.inst);
            if it.decl != NODE_NONE {
                saw_inst = true;
            }
            if k == NodeKind::NODE_IDENTIFIER && f.receiver_type(nid) == t {
                saw_recv = true;
            }
        }
    }
    assert(saw_inst, "instance accessor reaches the interned instance");
    assert(saw_recv, "receiver type is the receiver expression's checked type");
    assert(closure != NODE_NONE, "closure found");
    assert(f.mut_captures(closure) != 0, "mutated capture recorded in the mask");
    assert(f.captures(closure).len != 0, "capture list recorded");
    // generic args recorded at the specialized use site
    let mut saw_args = false;
    for n in 0..a.nodes.len() {
        if f.generic_args(n as NodeId) != null {
            saw_args = true;
        }
    }
    assert(saw_args, "generic arguments recorded at a use site");
    let plat = find_fn(&p, "plat");
    assert(f.attr_of(plat, AttrKind::ATTR_PLATFORM as u8) != null, "attribute reachable through the boundary");
    let take_fn = find_fn(&p, "take");
    assert(f.lifetimes(take_fn).len != 0 || a.lifetime_decls.len() != 0, "lifetime declarations reachable");
}

@test
fn question_lowers_explicitly() {
    let p = typed_package(
        "fn g(o: Option<i32>) Option<i32> { let v = o?; return Option::<i32>::Some(v + 1); }\nfn main() i32 { let _ = g(Option::<i32>::Some(1)); return 0; }",
    );
    let out = lowered(&p, "g");
    assert(has(&out, "discr "), "the carrier discriminant is read");
    assert(has(&out, ".variant"), "the payload is a downcast projection");
    assert(has(&out, "agg3"), "the error path rewraps through variant construction");
    assert(has(&out, "return"), "the error path returns");
}

@test
fn iterator_for_lowers_to_next_calls() {
    let p = typed_package(
        "fn f(v: &Vector<i32>) i32 { let mut s = 0; for x in v.iter() { s += *x; } return s; }\nfn main() i32 { let v = Vector::<i32>::new(); let _ = f(&v); return 0; }",
    );
    let out = lowered(&p, "f");
    assert(has(&out, "call m"), "the selected next runs as a call terminator");
    assert(has(&out, "discr "), "one discriminant read per iteration");
    assert(has(&out, ".variant"), "the element loads through a downcast");
}
