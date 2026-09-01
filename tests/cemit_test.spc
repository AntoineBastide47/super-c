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
import ir::interp as iri;
import ir::lower as irl;
import ir::verify as irv;
import emit::cemit as cb;

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
        assert(irv::verify(&lw.body, tp, p).len() == 0, "body verifies");
        bodies.push(lw);
    }
    for i in 0..bodies.len() {
        let node = bodies.at(i).body.owner.node;
        let mut sym = String::new();
        let tgt = em.mg.method_target(u, node);
        assert(em.mg.fn_sym(u, node, tgt, true, &mut sym), "symbol renders");
        let ok = em.emit_fn(&bodies.at(i).body, sym.as_str());
        assert(ok, "body emits");
    }
}

// Write the buffer + a `main` returning `expect_expr`, compile strict C11, run, return exit code.
fn compile_run(em: &cb::CEmit, main_body: str, tag: str) i32 {
    let mut path = String::new();
    path.push_str("build/cemit_probe_");
    path.push_str(tag);
    path.push_str(".c");
    let f = stdio::fopen(path.as_str(), "wb");
    assert(f != null, "probe file opens");
    let s = em.out.as_str();
    let _ = unsafe stdio::fwrite(s.ptr(), 1, s.len(), f);
    let mb = main_body;
    let _ = unsafe stdio::fwrite(mb.ptr(), 1, mb.len(), f);
    unsafe stdio::fclose(f);
    let mut cmd = String::new();
    // -pedantic-errors: the emitted output is portable C11, no GNU extensions (ZST storage is
    // elided, so even zero-sized types spell portably).
    cmd.push_str("cc -std=c11 -pedantic-errors -Wall -Werror -o build/cemit_probe_");
    cmd.push_str(tag);
    cmd.push_str(" ");
    cmd.push_string(&path);
    let rc = unsafe shim::sc_run(cmd.cstr(), null, null, null, null);
    assert(rc == 0, "strict C11 compile");
    let mut bin = String::new();
    bin.push_str("build/cemit_probe_");
    bin.push_str(tag);
    let ec = unsafe shim::sc_exec(bin.cstr());
    return ec;
}

@test
fn arithmetic_and_branches_behave() {
    let p = typed_package(
        "pub fn collatz_steps(n0: u64) u64 { let mut n = n0; let mut steps: u64 = 0; while n != 1 { if n % 2 == 0 { n = n / 2; } else { n = 3 * n + 1; } steps += 1; } return steps; }\npub fn mix(a: i32, b: i32) i32 { let mut acc = a * 3 - b; acc = acc ^ (b << 2); if acc < 0 { acc = -acc; } return acc % 251; }\nfn main() i32 { return 0; }",
    );
    let mut em = cb::CEmit::new(&p);
    let names: [str; 2] = ["collatz_steps", "mix"];
    emit_tu(&p, &names[0], 2, &mut em);
    let mut m1 = String::new();
    m1.push_str("int main(void) {\n");
    // collatz(27) = 111; mix(45, 17) = ((45*3-17) ^ (17<<2)) then abs, % 251
    m1.push_str("  if (collatz_steps(27ULL) != 111ULL) return 1;\n");
    m1.push_str("  int32_t acc = 45 * 3 - 17; acc = acc ^ (17 << 2); if (acc < 0) acc = -acc;\n");
    m1.push_str("  if (mix(45, 17) != acc % 251) return 2;\n  return 0;\n}\n");
    let rc = compile_run(&em, m1.as_str(), "arith");
    assert(rc == 0, "emitted C behaves");
}

@test
fn calls_and_recursion_behave() {
    let p = typed_package(
        "pub fn gcd(a: u64, b: u64) u64 { if b == 0 { return a; } return gcd(b, a % b); }\npub fn lcm(a: u64, b: u64) u64 { return a / gcd(a, b) * b; }\nfn main() i32 { return 0; }",
    );
    let mut em = cb::CEmit::new(&p);
    let names: [str; 2] = ["gcd", "lcm"];
    emit_tu(&p, &names[0], 2, &mut em);
    let mut m1 = String::new();
    m1.push_str(
        "int main(void) {\n  if (gcd(1071ULL, 462ULL) != 21ULL) return 1;\n  if (lcm(21ULL, 6ULL) != 42ULL) return 2;\n  return 0;\n}\n",
    );
    let rc = compile_run(&em, m1.as_str(), "calls");
    assert(rc == 0, "emitted calls behave");
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
    // And prove it: the emitted TU compiles under -std=c11 -pedantic-errors -Werror (compile_run).
    let mut m1 = String::new();
    m1.push_str("int main(void) { return f(11) - 20; }\n");
    assert_eq(compile_run(&em, m1.as_str(), "pedantic"), 0);
}

// The number of `return ` statements in the emitted TU.
fn count_returns(s: str) usize {
    let mut n = 0 as usize;
    let mut i = 0 as usize;
    while i + 7 <= s.len() {
        if s.slice(i, i + 7) == "return " {
            n += 1;
        }
        i += 1;
    }
    return n;
}

// The Phase-10 readability contract, checked on ONE isolated function (no prelude noise): structured
// control, no basic-block labels or gotos, no dead sentinels, no return-slot copy. These assert on
// the emitted text only; behavior for the same shapes is covered by codegen_test / the run tests.
@test
fn structured_shape_isolated() {
    // A straight-line owning body: one call, then a direct forwarded return of the moved parameter.
    let p1 = typed_package(
        "pub struct S { pub n: i32 }\npub fn bump(s: &mut S, v: i32) { s.n = s.n + v; }\npub fn sugar(s: S, v: i32) S { let mut r = s; bump(&mut r, v); return r; }\nfn main() i32 { return 0; }",
    );
    let mut e1 = cb::CEmit::new(&p1);
    let n1: [str; 1] = ["sugar"];
    emit_tu(&p1, &n1[0], 1, &mut e1);
    assert(e1.out.contains("S sugar(S s,"), "the parameter keeps its source name");
    assert(e1.out.contains("&s"), "the coalesced parameter is operated on in place");
    assert(e1.out.contains("return s;"), "the owning value returns directly");
    assert(!e1.out.contains("goto "), "straight-line body has no goto");
    assert(!e1.out.contains("bb_"), "straight-line body has no basic-block label");
    assert(!e1.out.contains("abort()"), "no dead abort sentinel");
    assert(!e1.out.contains("_0 ="), "no return-slot copy");
    assert_eq(count_returns(e1.out.as_str()), 1);

    // An if / early return followed by a tail return: structured if, exactly two returns, no goto.
    let p2 = typed_package(
        "pub fn choose(n: i32) i32 { if n == 0 { return 100; } return 0; }\nfn main() i32 { return 0; }",
    );
    let mut e2 = cb::CEmit::new(&p2);
    let n2: [str; 1] = ["choose"];
    emit_tu(&p2, &n2[0], 1, &mut e2);
    assert(e2.out.contains("if ("), "the branch is a structured if");
    assert(e2.out.contains("return 100LL;"), "the early arm forwards its value");
    assert(!e2.out.contains("goto "), "no goto in a reducible branch");
    assert(!e2.out.contains("abort()"), "no dead abort");
    assert_eq(count_returns(e2.out.as_str()), 2);

    // A discriminant match is a native C switch, not a goto chain.
    let p3 = typed_package(
        "pub enum C { Red, Green, Blue }\npub fn tag(c: C) i32 { return switch c { Red => 1, Green => 2, Blue => 3, }; }\nfn main() i32 { return 0; }",
    );
    let mut e3 = cb::CEmit::new(&p3);
    let n3: [str; 1] = ["tag"];
    emit_tu(&p3, &n3[0], 1, &mut e3);
    assert(e3.out.contains("switch ("), "the match is a native switch");
    assert(e3.out.contains("case 1:"), "a case tests the tag value");
    assert(!e3.out.contains("goto "), "no goto in the switch");

    // A never-read local is a dead store: no declaration, no assignment.
    let p4 = typed_package("pub fn dead() i32 { let unused: i32 = 9; return 0; }\nfn main() i32 { return 0; }");
    let mut e4 = cb::CEmit::new(&p4);
    let n4: [str; 1] = ["dead"];
    emit_tu(&p4, &n4[0], 1, &mut e4);
    assert(!e4.out.contains("unused"), "the never-read local is not declared");
    assert(!e4.out.contains("9LL"), "its pure store is dropped");
}
