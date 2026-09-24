// The shared pattern compiler: matrix usefulness drives exhaustiveness and
// unreachable-arm verdicts, and the decision tree drives Core IR match lowering. The sequential walker's
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
    // The sequential walker demanded a whole-variant cover per arm; the matrix proves the split
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

// Constructor completeness has no variant cap: an enum with more than 256 variants is exhaustive once
// every variant has an arm.
@test
fn many_variant_enum_is_exhaustive() {
    let mut src = String::from_str("enum E { ");
    for i in 0..300 {
        src.push_str(format("V{}, ", i).as_str());
    }
    src.push_str("}\nfn f(e: E) i32 { return switch e { ");
    for i in 0..300 {
        src.push_str(format("V{} => {}, ", i, i).as_str());
    }
    src.push_str("}; }\nfn main() i32 { return f(E::V299) - 299; }\n");
    h::expect_ok("300-variant switch listing every variant", src.as_str());
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

// A literal or range sub-pattern under a reference scrutinee tests the referent (bool, integer,
// range, nested payload, struct field), and a binding under it borrows the matched place.
@test
fn literal_patterns_test_the_referent() {
    h::expect_exit(
        "literal and range patterns under references",
        "enum E { B(bool), Iv(i32), P(i32, bool), N }\nstruct S { pub x: i32, pub on: bool }\nfn by_enum(e: &E) i32 {\n    return switch e {\n        B(true) => 1,\n        B(false) => 2,\n        Iv(7) => 3,\n        Iv(0..=5) => 4,\n        Iv(_) => 5,\n        P(1, true) => 6,\n        P(_, _) => 7,\n        N => 8,\n    };\n}\nfn by_int(x: &i32) i32 {\n    return switch x {\n        7 => 1,\n        10..20 => 2,\n        _ => 3,\n    };\n}\nfn by_struct(s: &S) i32 {\n    return switch s {\n        S { x: 3, on: true } => 1,\n        S { x, on: false } => *x,\n        _ => 0,\n    };\n}\nfn nested(o: Option<&E>) i32 {\n    if let Some(B(true)) = o {\n        return 1;\n    }\n    if let Some(Iv(n)) = o {\n        return *n;\n    }\n    return 0;\n}\nfn bump(e: &mut E) {\n    switch e {\n        Iv(n) => {\n            *n += 1;\n        },\n        _ => {},\n    };\n}\nfn main() i32 {\n    let bt = E::B(true);\n    let bf = E::B(false);\n    let i7 = E::Iv(7);\n    let i4 = E::Iv(4);\n    let i9 = E::Iv(9);\n    let p1 = E::P(1, true);\n    let p2 = E::P(1, false);\n    let n = E::N;\n    if by_enum(&bt) != 1 || by_enum(&bf) != 2 || by_enum(&i7) != 3 || by_enum(&i4) != 4 {\n        return 1;\n    }\n    if by_enum(&i9) != 5 || by_enum(&p1) != 6 || by_enum(&p2) != 7 || by_enum(&n) != 8 {\n        return 2;\n    }\n    let seven = 7;\n    let fifteen = 15;\n    let other = 30;\n    if by_int(&seven) != 1 || by_int(&fifteen) != 2 || by_int(&other) != 3 {\n        return 3;\n    }\n    let s1 = S { x: 3, on: true };\n    let s2 = S { x: 9, on: false };\n    let s3 = S { x: 4, on: true };\n    if by_struct(&s1) != 1 || by_struct(&s2) != 9 || by_struct(&s3) != 0 {\n        return 4;\n    }\n    let k = E::Iv(42);\n    if nested(Option::<&E>::Some(&bt)) != 1 || nested(Option::<&E>::Some(&bf)) != 0 || nested(Option::<&E>::Some(&k)) != 42 {\n        return 5;\n    }\n    let mut m = E::Iv(1);\n    bump(&mut m);\n    if by_enum(&m) != 4 {\n        return 6;\n    }\n    return 0;\n}\n",
        0,
    );
}

// The compile-time evaluator runs the same lowering: literal tests read the referent and bindings
// borrow the matched place.
@test
fn reference_patterns_evaluate_at_compile_time() {
    h::expect_exit(
        "reference patterns in const fn",
        "enum E { B(bool), Iv(i32), N }\nstruct S { pub x: i32, pub e: E }\nconst fn cval(e: &E) i32 {\n    return switch e {\n        B(true) => 10,\n        Iv(3) => 30,\n        Iv(n) => *n,\n        _ => 0,\n    };\n}\nconst fn sval(s: &S) i32 {\n    return switch s {\n        S { x: 1, e: Iv(k) } => *k + 100,\n        S { x, e: _ } => *x,\n    };\n}\nconst EB: E = E::B(true);\nconst EI: E = E::Iv(3);\nconst EK: E = E::Iv(8);\nconst SS: S = S { x: 1, e: E::Iv(5) };\nstatic_assert(cval(&EB) == 10, \"bool\");\nstatic_assert(cval(&EI) == 30, \"int\");\nstatic_assert(cval(&EK) == 8, \"bind\");\nstatic_assert(sval(&SS) == 105, \"nested\");\nfn main() i32 {\n    return cval(&EK) - 8;\n}\n",
        0,
    );
}

fn t_resolve(p: &mut loader::Package, i: usize) bool {
    let pkg = p as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut r = res::Resolver::new(unsafe &mut *((&mut m.ast) as *mut Ast), str::from_raw(src as *const u8, len), pkg);
    r.resolve();
    let had = r.has_errors();
    return !had;
}

// Resolve `src`, find its first switch, feed the unguarded arms to a PatCx, and answer one probe:
// `probe_arm` < 0 asks whether a wildcard is still useful (NOT exhaustive); otherwise whether that
// arm is still reachable behind its predecessors.
fn engine_over(src: str, probe_arm: i64) bool {
    let mut p = loader::package_from_source(src, "std", unsafe shim::sc_host_platform());
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
    for k in 0..a.nnodes() {
        if a.at_const(a.nth_id(k)).kind == NodeKind::NODE_MATCH && mid == NODE_NONE {
            mid = a.nth_id(k);
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
    // Integers stay never-complete: the catch-all is reachable behind any literal set.
    assert(
        engine_over("fn f(n: i32) i32 { return switch n { 1 => 1, 2 => 2, _ => 0 }; }\n", 2),
        "catch-all reachable behind integer literals",
    );
    // A duplicate literal arm is not.
    assert(
        !engine_over("fn f(n: i32) i32 { return switch n { 1 => 1, 1 => 2, _ => 0 }; }\n", 1),
        "duplicate literal arm unreachable",
    );
    // An arm behind a complete or-cover is not.
    assert(
        !engine_over("enum E { A, B }\nfn f(e: E) i32 { return switch e { A | B => 1, B => 2 }; }\n", 1),
        "arm behind a complete or-cover unreachable",
    );
    // A complete variant switch leaves no wildcard useful.
    assert(
        !engine_over("enum E { A, B(i32), C }\nfn f(e: E) i32 { return switch e { A => 0, B(x) => x, C => 2 }; }\n", -1),
        "complete variant switch exhaustive",
    );
    // Range coverage never proves integers complete (established diagnostics).
    assert(
        engine_over("fn f(n: u8) i32 { return switch n { 0..=255 => 1, _ => 0 }; }\n", -1) == false,
        "a catch-all row absorbs the wildcard probe",
    );
}
