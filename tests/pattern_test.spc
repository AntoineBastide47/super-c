// The shared pattern compiler: matrix usefulness drives exhaustiveness and
// unreachable-arm verdicts, and the decision tree drives Core IR match lowering. The legacy
// verdicts are pinned by tests/typechecker_test.spc::switch_exhaustiveness; this file pins the
// matrix's added precision and the engine's direct answers.
import tests::harness as h;
import driver_shim as shim;
import module::loader as loader;
import ast::ast as *;
import resolver::resolver as res;
import pattern::pattern as pat;

@test
fn deep_split_coverage_is_exhaustive() {
    // The legacy walker demanded a whole-variant cover per arm; the matrix proves the split
    // covers Some entirely. A reviewed precision improvement, kept deliberately.
    h::expect_ok(
        "payload split across arms covers the variant",
        "fn f(o: Option<bool>) i32 { return switch o { Some(true) => 1, Some(false) => 2, None => 0 }; }\nfn main() i32 { return f(Option::<bool>::None); }\n",
    );
    h::expect_ok(
        "nested variant split covers",
        "enum E { A(bool), B }\nfn f(e: E) i32 { return switch e { A(true) => 1, A(false) => 2, B => 0 }; }\nfn main() i32 { return f(E::B); }\n",
    );
}

@test
fn matrix_still_rejects_partial_covers() {
    h::expect_err_msg(
        "partial payload split stays non-exhaustive",
        "fn f(o: Option<bool>) i32 { return switch o { Some(true) => 1, None => 0 }; }\n",
        "not exhaustive",
    );
    h::expect_err_msg(
        "guarded arms cover nothing",
        "enum E { A, B }\nfn f(e: E) i32 { return switch e { A if true => 1, B => 0 }; }\n",
        "not exhaustive",
    );
}

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
    p.modules[i].ast = r.take_ast();
    return !had;
}

// Resolve `src`, find its first switch, feed the unguarded arms to a PatCx, and answer one probe:
// `probe_arm` < 0 asks whether a wildcard is still useful (NOT exhaustive); otherwise whether that
// arm is still reachable behind its predecessors.
fn engine_over(src: str, probe_arm: i64) bool {
    let mut p = loader::package_from_source(
        src.ptr() as *const char,
        src.len(),
        "std".ptr() as *const char,
        unsafe shim::sc_host_platform(),
    );
    assert(p.ok, "snippet parses");
    let n = p.modules.len();
    let mut ok = true;
    for i in 0..n {
        ok = t_resolve(&mut p, i) && ok;
    }
    assert(ok, "snippet resolves");
    let u = n - 1;
    let a = unsafe &*p.module_ast_const(u as ModuleId);
    let mut mid = NODE_NONE;
    for k in 0..a.nodes.len() {
        if a.at_const(k as NodeId).kind == NodeKind::NODE_MATCH && mid == NODE_NONE {
            mid = k as NodeId;
        }
    }
    assert(mid != NODE_NONE, "switch found");
    let src2 = p.modules.at(u).source.as_str();
    let mut cx = pat::PatCx::new(&p, a, src2);
    let arms = a.at_const(mid).as_data.match_expr.arms;
    for i in 0..arms.len {
        let arm = a.at_const(unsafe a.list(arms)[i as usize]).as_data.match_arm;
        if probe_arm >= 0 && i as i64 >= probe_arm {
            continue;
        }
        if arm.guard == NODE_NONE {
            cx.add_arm(arm.pattern, i);
        }
    }
    if probe_arm < 0 {
        return cx.wildcard_useful();
    }
    let ap = a.at_const(unsafe a.list(arms)[probe_arm as usize]).as_data.match_arm.pattern;
    return cx.arm_reachable(ap, probe_arm as u32);
}

@test
fn usefulness_verdicts() {
    // integers stay never-complete: the catch-all is reachable behind any literal set
    assert(
        engine_over("fn f(n: i32) i32 { return switch n { 1 => 1, 2 => 2, _ => 0 }; }\n", 2),
        "catch-all reachable behind integer literals",
    );
    // a duplicate literal arm is not
    assert(
        !engine_over("fn f(n: i32) i32 { return switch n { 1 => 1, 1 => 2, _ => 0 }; }\n", 1),
        "duplicate literal arm unreachable",
    );
    // an arm behind a complete or-cover is not
    assert(
        !engine_over("enum E { A, B }\nfn f(e: E) i32 { return switch e { A | B => 1, B => 2 }; }\n", 1),
        "arm behind a complete or-cover unreachable",
    );
    // a complete variant switch leaves no wildcard useful
    assert(
        !engine_over("enum E { A, B(i32), C }\nfn f(e: E) i32 { return switch e { A => 0, B(x) => x, C => 2 }; }\n", -1),
        "complete variant switch exhaustive",
    );
    // range coverage never proves integers complete (established diagnostics)
    assert(
        engine_over("fn f(n: u8) i32 { return switch n { 0..=255 => 1, _ => 0 }; }\n", -1) == false,
        "a catch-all row absorbs the wildcard probe",
    );
}
