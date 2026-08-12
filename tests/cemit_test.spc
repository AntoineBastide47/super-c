// Streaming-backend cases: subset functions emit as strict C11, the result compiles
// with a real C compiler under -Werror, RUNS, and returns the same values the language semantics
// require -- the behavioral half of the exit gate on the current subset. Determinism: two serial
// emissions must be byte-identical.
import stdio;
import driver_shim as shim;
import module::loader as loader;
import ast::ast as *;
import resolver::resolver as res;
import typechecker::typechecker as tc;
import consteval::consteval as ce;
import ir::lower as irl;
import ir::verify as irv;
import backend::cemit as cb;

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
    p.set_override(i as ModuleId, t.ast.get());
    t.check();
    p.clear_override(i as ModuleId);
    let had = t.has_errors();
    if had {
        t.log_errors();
    }
    p.modules[i].ast = t.take_ast();
    return !had;
}

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

// Emit `names` as one TU; assert every body lowers, verifies, and emits.
fn emit_tu(p: &loader::Package, names: *const str, n: usize, em: &mut cb::CEmit) {
    em.out.clear();
    em.out.push_str("#include <stdint.h>\n#include <stdbool.h>\n#include <stdlib.h>\n");
    let u = (p.modules.len() - 1) as ModuleId;
    // prototypes first so call order never matters
    let mut bodies = Vector::<irl::Lowerer>::new();
    for i in 0..n {
        let node = find_fn(p, unsafe names[i]);
        assert(node != NODE_NONE, "function found");
        let mut lw = irl::Lowerer::new(p, u, node);
        assert(lw.lower_fn(node), "body lowers");
        let tp = unsafe (&*p.module_ast_const(u)).type_pool.len();
        assert(irv::verify(&lw.body, tp).len() == 0, "body verifies");
        bodies.push(lw);
    }
    for i in 0..bodies.len() {
        let node = bodies.at(i).body.owner.node;
        let mut sym = String::new();
        cb::fn_symbol(u, node, &mut sym);
        let ok = em.emit_fn(&bodies.at(i).body, sym.as_str());
        assert(ok, "body emits");
        sym.free();
    }
    bodies.free();
}

// Write the buffer + a `main` returning `expect_expr`, compile strict C11, run, return exit code.
fn compile_run(em: &cb::CEmit, main_body: str) i32 {
    let mut path = String::new();
    path.push_str("build/cemit_probe.c");
    let f = stdio::fopen(path.as_str(), "wb");
    assert(f != null, "probe file opens");
    let s = em.out.as_str();
    let _ = unsafe stdio::fwrite(s.ptr(), 1, s.len(), f);
    let mb = main_body;
    let _ = unsafe stdio::fwrite(mb.ptr(), 1, mb.len(), f);
    unsafe stdio::fclose(f);
    let rc = unsafe shim::sc_run(
        "cc -std=c11 -Wall -Werror -o build/cemit_probe build/cemit_probe.c".ptr() as *const char,
        null,
        null,
        null,
        null,
    );
    assert(rc == 0, "strict C11 compile");
    path.free();
    return unsafe shim::sc_exec("build/cemit_probe".ptr() as *const char);
}

@test
fn arithmetic_and_branches_behave() {
    let p = typed_package(
        "pub fn collatz_steps(n0: u64) u64 { let mut n = n0; let mut steps: u64 = 0; while n != 1 { if n % 2 == 0 { n = n / 2; } else { n = 3 * n + 1; } steps += 1; } return steps; }\npub fn mix(a: i32, b: i32) i32 { let mut acc = a * 3 - b; acc = acc ^ (b << 2); if acc < 0 { acc = -acc; } return acc % 251; }\nfn main() i32 { return 0; }",
    );
    let mut em = cb::CEmit::new(&p);
    let names: [str; 2] = ["collatz_steps", "mix"];
    emit_tu(&p, &names[0], 2, &mut em);
    let u = (p.modules.len() - 1) as ModuleId;
    let mut m1 = String::new();
    m1.push_str("int main(void) {\n");
    // collatz(27) = 111; mix(45, 17) = ((45*3-17) ^ (17<<2)) then abs, % 251
    m1.push_str("  if (");
    cb::fn_symbol(u, find_fn(&p, "collatz_steps"), &mut m1);
    m1.push_str("(27ULL) != 111ULL) return 1;\n");
    m1.push_str("  int32_t acc = 45 * 3 - 17; acc = acc ^ (17 << 2); if (acc < 0) acc = -acc;\n");
    m1.push_str("  if (");
    cb::fn_symbol(u, find_fn(&p, "mix"), &mut m1);
    m1.push_str("(45, 17) != acc % 251) return 2;\n  return 0;\n}\n");
    let rc = compile_run(&em, m1.as_str());
    assert(rc == 0, "emitted C behaves");
    m1.free();
}

@test
fn calls_and_recursion_behave() {
    let p = typed_package(
        "pub fn gcd(a: u64, b: u64) u64 { if b == 0 { return a; } return gcd(b, a % b); }\npub fn lcm(a: u64, b: u64) u64 { return a / gcd(a, b) * b; }\nfn main() i32 { return 0; }",
    );
    let mut em = cb::CEmit::new(&p);
    let names: [str; 2] = ["gcd", "lcm"];
    emit_tu(&p, &names[0], 2, &mut em);
    let u = (p.modules.len() - 1) as ModuleId;
    let mut m1 = String::new();
    m1.push_str("int main(void) {\n  if (");
    cb::fn_symbol(u, find_fn(&p, "gcd"), &mut m1);
    m1.push_str("(1071ULL, 462ULL) != 21ULL) return 1;\n  if (");
    cb::fn_symbol(u, find_fn(&p, "lcm"), &mut m1);
    m1.push_str("(21ULL, 6ULL) != 42ULL) return 2;\n  return 0;\n}\n");
    let rc = compile_run(&em, m1.as_str());
    assert(rc == 0, "emitted calls behave");
    m1.free();
}

@test
fn deterministic_output() {
    let p = typed_package(
        "pub fn f(a: i64, b: i64) i64 { let mut x = a; let mut i: i64 = 0; while i < b { x = x * 31 + i; i += 1; } return x; }\nfn main() i32 { return 0; }",
    );
    let mut e1 = cb::CEmit::new(&p);
    let mut e2 = cb::CEmit::new(&p);
    let names: [str; 1] = ["f"];
    emit_tu(&p, &names[0], 1, &mut e1);
    emit_tu(&p, &names[0], 1, &mut e2);
    assert(e1.out.as_str() == e2.out.as_str(), "two serial emissions are byte-identical");
}

@test
fn portable_subset_is_strict() {
    // The emitter's own output never contains the banned extensions.
    let p = typed_package(
        "pub fn f(a: i32) i32 { let mut v = a; if v > 10 { v = v - 1; } return v * 2; }\nfn main() i32 { return 0; }",
    );
    let mut em = cb::CEmit::new(&p);
    let names: [str; 1] = ["f"];
    emit_tu(&p, &names[0], 1, &mut em);
    assert(!em.out.contains("__auto_type"), "no __auto_type");
    assert(!em.out.contains("({"), "no statement expressions");
}
