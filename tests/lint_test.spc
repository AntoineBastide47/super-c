// Lint-surface tests driven through `$SUPERC lint` as a subprocess: the redundant reference->pointer
// coalescing-cast warning and its `--fix` auto-removal.
import tests::cli_harness as cli;
import module::loader as loader;

@test
fn redundant_coalescing_cast_lint_and_fix() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "fn take(p: *mut i32) i32 {\n    return unsafe *p;\n}\n\nfn main() i32 {\n    let mut x = 1;\n    return take((&mut x) as *mut i32) - 1;\n}\n",
    );
    let root = str::from_cstr(p.rootp());
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.out_has("unnecessary cast: '&mut i32' converts to '*mut i32' implicitly here"));

    let mut fargs = String::from_str("lint --fix \"");
    fargs.push_str(root);
    fargs.push_str("/main.spc\"");
    let fr = p.run_raw(fargs.as_str());
    assert_eq(fr.exit, 0); // clean after the fix
    let mut mp = String::from_str(root);
    mp.push_str("/main.spc");
    let fixed = loader::read_file(mp.as_str()).unwrap();
    assert(fixed.as_str().contains("return take(&mut x) - 1;"));
    assert(!fixed.as_str().contains("as *mut i32"));
}

// The probe-backed lint covers EVERY implicit conversion, not an enumerated subset: reference
// weakening, literal adaptation, and null-to-pointer all flag; a cast that picks an unannotated
// binding's type never does.
@test
fn redundant_cast_lint_covers_all_implicits() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "fn share(r: &i32) i32 {\n    return *r;\n}\n\nfn sink(v: i64) i64 {\n    return v;\n}\n\nfn psink(p: *mut i32) i32 {\n    return 0;\n}\n\nfn main() i32 {\n    let mut x = 1;\n    let mr: &mut i32 = &mut x;\n    let a = share(mr as &i32);\n    let n: u8 = 3;\n    let b = sink(n as i64);\n    let c = sink(300 as i64);\n    let f = psink(null as *mut i32);\n    let keep = (&mut x) as *mut i32;\n    return (a as i64 + b + c) as i32 + f + (keep as usize) as i32 * 0;\n}\n",
    );
    let root = str::from_cstr(p.rootp());
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.out_has("'&mut i32' converts to '&i32' implicitly here"));
    assert(r.out_has("'u8' converts to 'i64' implicitly here"));
    assert(r.out_has("'i32' converts to 'i64' implicitly here"));
    assert(r.out_has("'null' converts to '*mut i32' implicitly here"));
    assert(!r.out_has("'&mut i32' converts to '*mut i32'")); // the unannotated-let cast is load-bearing: quiet
}

// `--suggest-const`: the deep (all-paths) CTFE scan flags functions provably evaluable at compile
// time -- through branches, matches and statically-resolved method calls -- and stays silent on
// loops, extern calls, recursion, and declared `const fn`s. Off by default (no warning without the
// flag).
@test
fn const_suggestion_lint() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct P {\n    pub x: i32,\n}\n\nextend P {\n    fn norm(self: Self) i32 {\n        if self.x < 0 {\n            return -self.x;\n        }\n        return self.x;\n    }\n}\n\nfn branchy(a: i32) i32 {\n    if a > 10 {\n        return a - 10;\n    }\n    return 10 - a;\n}\n\nfn use_method(p: P) i32 {\n    return p.norm();\n}\n\nconst fn already(a: i32) i32 {\n    return a + 1;\n}\n\nfn looping(n: i32) i32 {\n    let mut s = 0;\n    for i in 0..n {\n        s = s + i;\n    }\n    return s;\n}\n\nfn prints(a: i32) i32 {\n    println(\"{}\", a);\n    return a;\n}\n\nfn rec(n: i32) i32 {\n    if n <= 1 {\n        return 1;\n    }\n    return n * rec(n - 1);\n}\n\nfn main() i32 {\n    let p = P { x: 3 };\n    return branchy(4) + use_method(p) + already(1) + looping(2) + prints(0) + rec(2) - 21;\n}\n",
    );
    let root = str::from_cstr(p.rootp());
    let mut args = String::from_str("lint --suggest-const \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.exit != 0); // warnings exit 1, compiler-warning semantics
    assert(r.out_has("function 'norm' can be declared 'const fn'"));
    assert(r.out_has("function 'branchy' can be declared 'const fn'"));
    assert(r.out_has("function 'use_method' can be declared 'const fn'"));
    assert(!r.out_has("'already'"));
    assert(!r.out_has("'looping'"));
    assert(!r.out_has("'prints'"));
    assert(!r.out_has("'rec'"));
    assert(!r.out_has("'main'"));

    // off by default: the same file lints clean
    let mut dargs = String::from_str("lint \"");
    dargs.push_str(root);
    dargs.push_str("/main.spc\"");
    let d = p.run_raw(dargs.as_str());
    assert_eq(d.exit, 0);
    assert(!d.out_has("can be declared 'const fn'"));

    // `--fix` inserts `const ` before the `fn` keyword; the re-lint fixpoint then reports nothing
    let mut fargs = String::from_str("lint --fix --suggest-const \"");
    fargs.push_str(root);
    fargs.push_str("/main.spc\"");
    let fx = p.run_raw(fargs.as_str());
    assert_eq(fx.exit, 0);
    let mut mp = String::from_str(root);
    mp.push_str("/main.spc");
    let fixed = loader::read_file(mp.as_str()).unwrap();
    assert(fixed.as_str().contains("const fn branchy"));
    assert(fixed.as_str().contains("const fn use_method"));
    assert(fixed.as_str().contains("const fn norm")); // extend member
    assert(!fixed.as_str().contains("const fn looping"));
    assert(!fixed.as_str().contains("const fn prints"));
    assert(!fixed.as_str().contains("const fn rec"));
    assert(!fixed.as_str().contains("const fn main"));
    assert(!fixed.as_str().contains("const const")); // `already` was const before the fix
}

// Ownership is DERIVED for structs and enums (their members' frees are synthesized), so plain
// aggregates lint clean -- but a UNION cannot derive (only the author knows the active member):
// an owning union without an explicit Free impl is an error, with no machine fix.
@test
fn union_free_lint() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct Derived {\n    pub s: String,\n}\n\nunion Bad {\n    pub s: String,\n    pub n: u64,\n}\n\nunion Good {\n    pub s: String,\n    pub n: u64,\n}\n\nextend Good as Free {\n    pub fn free(self: &mut Good) {\n        unsafe self.s.free();\n    }\n}\n\nfn main() i32 {\n    let d = Derived { s: String::from_str(\"x\") };\n    let b = Bad { n: 3u64 };\n    let g = Good { s: String::from_str(\"y\") };\n    let k = d.s.len() + unsafe b.n as usize + unsafe g.s.len();\n    return (k - 5) as i32;\n}\n",
    );
    let root = str::from_cstr(p.rootp());
    let mut dargs = String::from_str("lint \"");
    dargs.push_str(root);
    dargs.push_str("/main.spc\"");
    let d = p.run_raw(dargs.as_str());
    assert(d.exit != 0);
    assert(d.out_has("union 'Bad' has owning fields ('s') but no 'free'"));
    assert(!d.out_has("'Derived'")); // structs derive: never flagged
    assert(!d.out_has("union 'Good'")); // explicit impl satisfies the rule
}

// The local-analysis lints: unnecessary `mut`, back-to-back dead stores, unused loop labels,
// unreachable statements after a diverging one, unreachable arms after a catch-all, and the
// cancelling `*&` / `&*` operator pairs. `--fix` deletes `mut ` and the operator pairs; the
// report-only findings survive the fix pass.
@test
fn local_analysis_lints() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "enum E {\n    A(i32),\n    B,\n}\n\nfn muts(a: i32) i32 {\n    let mut kept = a;\n    kept = kept + 1;\n    let mut extra = a;\n    return kept + extra;\n}\n\nfn stores(a: i32) i32 {\n    let mut v = a;\n    v = 7;\n    return v;\n}\n\nfn labeled(n: i32) i32 {\n    let mut s = 0;\n    'outer: for i in 0..n {\n        s = s + i;\n    }\n    'used: for i in 0..n {\n        if i == 1 {\n            break 'used;\n        }\n        s = s + i;\n    }\n    return s;\n}\n\nfn unreach(a: i32) i32 {\n    let mut s = a;\n    if a > 0 {\n        return s;\n        s = 0;\n    }\n    return -s;\n}\n\nfn arms(e: E) i32 {\n    return switch e {\n        _ => {\n            0;\n        },\n        B => {\n            1;\n        },\n    };\n}\n\nfn derefs(a: i32) i32 {\n    let r = &a;\n    let b = *&a;\n    let c = &*r;\n    return b + *c;\n}\n\nfn main() i32 {\n    let e = E::A(2);\n    return muts(1) + stores(2) + labeled(3) + unreach(4) + arms(e) + derefs(5) - 27;\n}\n",
    );
    let root = str::from_cstr(p.rootp());
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.exit != 0);
    assert(r.out_has("'extra' does not need to be mutable"));
    assert(!r.out_has("'kept' does not need"));
    assert(!r.out_has("'v' does not need")); // mutated: the dead store still requires mut
    assert(r.out_has("value assigned to 'v' is overwritten before it is read"));
    assert(r.out_has("unused label ''outer'"));
    assert(!r.out_has("''used'"));
    assert(r.out_has("unreachable statement"));
    assert(r.out_has("unreachable arm: a previous arm matches every value"));
    assert(r.out_has("unnecessary '*&': the expression can be used directly"));
    assert(r.out_has("unnecessary '&*': the reference can be used directly"));

    let mut fargs = String::from_str("lint --fix \"");
    fargs.push_str(root);
    fargs.push_str("/main.spc\"");
    p.run_raw(fargs.as_str()); // report-only findings remain, so the final pass still exits 1
    let mut mp = String::from_str(root);
    mp.push_str("/main.spc");
    let fixed = loader::read_file(mp.as_str()).unwrap();
    assert(fixed.as_str().contains("let extra = a;")); // mut dropped
    assert(fixed.as_str().contains("let mut kept = a;")); // mut kept
    assert(fixed.as_str().contains("let b = a;")); // *& dropped
    assert(fixed.as_str().contains("let c = r;")); // &* dropped
}

// The driver lints: unused imports (fixable), never-read private fields, unused tagged-enum
// variants, and discarded results of provably pure calls.
@test
fn driver_lints() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import stdio;\nimport string as cstring;\n\nstruct S {\n    pub used_field: i32,\n    ghost: i32,\n}\n\nenum T {\n    Used(i32),\n    Ghost(i32),\n}\n\nextend S {\n    pub fn new(v: i32) S {\n        return S { used_field: v, ghost: v + 1 };\n    }\n}\n\nfn pure_add(a: i32, b: i32) i32 {\n    return a + b;\n}\n\nfn len_of(s: str) i32 {\n    return (unsafe cstring::strlen(s.ptr() as *const char)) as i32;\n}\n\nfn main() i32 {\n    let s = S::new(1);\n    let t = T::Used(3);\n    let x = switch t {\n        Used(v) => {\n            v;\n        },\n        _ => {\n            0;\n        },\n    };\n    pure_add(1, 2);\n    let y = pure_add(s.used_field, x);\n    return y + len_of(\"ab\") - 6;\n}\n",
    );
    let root = str::from_cstr(p.rootp());
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.exit != 0);
    assert(r.out_has("unused import 'stdio'"));
    assert(!r.out_has("unused import 'string'"));
    assert(r.out_has("field 'ghost' is never read"));
    assert(!r.out_has("'used_field'"));
    assert(r.out_has("unused variant 'Ghost'"));
    assert(!r.out_has("unused variant 'Used'"));
    assert(r.out_has("unused result of pure function 'pure_add': the call has no effect"));

    let mut fargs = String::from_str("lint --fix \"");
    fargs.push_str(root);
    fargs.push_str("/main.spc\"");
    p.run_raw(fargs.as_str());
    let mut mp = String::from_str(root);
    mp.push_str("/main.spc");
    let fixed = loader::read_file(mp.as_str()).unwrap();
    assert(!fixed.as_str().contains("import stdio;")); // unused import deleted
    assert(fixed.as_str().contains("import string as cstring;"));
}

// The always-panics check (the `unconditional_panic` analog, an ERROR): a fully const-foldable
// statement chain that DETERMINISTICALLY traps -- UB, or a panic reached inside a `const fn` (the
// checked-accessor class) -- fails the build; explicit user `panic(..)` calls and anything
// runtime-dependent stay silent.
@test
fn always_panics_lint() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "fn main() i32 {\n    let y = 13i32;\n    let arr = Array::<i32, 512>::filled(&y);\n    let x = arr.at(1000000);\n    return *x;\n}\n",
    );
    // an error on the PLAIN compile path, not only under `lint`
    let c = p.compile("main.spc");
    assert(c.exit != 0, "a provable panic fails the build");
    assert(c.out_has("error: this statement always panics at runtime"));
    assert(c.out_has("call stack: at -> panic"));
    let root = str::from_cstr(p.rootp());
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.exit != 0);
    assert(r.out_has("error: this statement always panics at runtime"));

    // UB through folded locals errors too (its own wording: UB is not a panic)
    p.mkfile("ub.spc", "fn main() i32 {\n    let z = 0;\n    let q = 1 / z;\n    return q;\n}\n");
    let mut uargs = String::from_str("lint \"");
    uargs.push_str(root);
    uargs.push_str("/ub.spc\"");
    let u = p.run_raw(uargs.as_str());
    assert(u.exit != 0);
    assert(u.out_has("error: this statement is undefined behavior when executed: division by zero"));

    // silent: an explicit panic helper (intent), a runtime-dependent index, and a guard that folds false
    p.mkfile(
        "quiet.spc",
        "fn die(msg: str) {\n    panic(msg);\n}\n\nfn with_param(i: usize) i32 {\n    let a = [1, 2, 3];\n    return unsafe a[i];\n}\n\nfn main() i32 {\n    let ok = [1, 2, 3];\n    let v = ok[1];\n    if v > 5 {\n        die(\"big\");\n    }\n    return with_param(0) + v;\n}\n",
    );
    let mut qargs = String::from_str("lint \"");
    qargs.push_str(root);
    qargs.push_str("/quiet.spc\"");
    let q = p.run_raw(qargs.as_str());
    assert_eq(q.exit, 0);
    assert(!q.out_has("always panics"));
}
