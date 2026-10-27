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
    let root = p.dir();
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.out_has("unnecessary cast: '&mut i32' converts to '*mut i32' implicitly here"));

    let mut fargs = String::from_str("lint --fix \"");
    fargs.push_str(root);
    fargs.push_str("/main.spc\"");
    let fr = p.run_raw(fargs.as_str());
    // Clean after the fix.
    assert(fr.ok());
    let mut mp = String::from_str(root);
    mp.push_str("/main.spc");
    let fixed = loader::read_file(mp.as_str()).unwrap();
    assert(fixed.as_str().contains("return take(&mut x) - 1;"));
    assert(!fixed.as_str().contains("as *mut i32"));
}

// A lint in a directory with no build.toml (none above it either) takes the command line's target
// settings alone: it reads no manifest, so it reports none missing.
@test
fn lint_without_a_manifest() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let r = cli::superc_in(p.dir(), "lint main.spc");
    assert(r.ok(), "the lint passes");
    assert(!r.out_has("build.toml"), "no manifest is read");
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
    let root = p.dir();
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.out_has("'&mut i32' converts to '&i32' implicitly here"));
    assert(r.out_has("'u8' converts to 'i64' implicitly here"));
    assert(r.out_has("'i32' converts to 'i64' implicitly here"));
    assert(r.out_has("'null' converts to '*mut i32' implicitly here"));
    // The unannotated-let cast is load-bearing: quiet.
    assert(!r.out_has("'&mut i32' converts to '*mut i32'"));
}

// `--const`: the deep (all-paths) CTFE scan flags functions provably evaluable at compile
// time: through branches, matches, loops and statically-resolved method calls, and stays silent
// on extern calls (also in a loop body), recursion, `@no_const` functions, declared `const fn`s
// and functions holding a build-constant branch (another build runs the removed code). Off by
// default (no warning without the flag).
@test
fn const_suggestion_lint() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct P {\n    pub x: i32,\n}\n\nextend P {\n    fn norm(self: Self) i32 {\n        if self.x < 0 {\n            return -self.x;\n        }\n        return self.x;\n    }\n}\n\nfn branchy(a: i32) i32 {\n    if a > 10 {\n        return a - 10;\n    }\n    return 10 - a;\n}\n\nfn use_method(p: P) i32 {\n    return p.norm();\n}\n\nconst fn already(a: i32) i32 {\n    return a + 1;\n}\n\nfn looping(n: i32) i32 {\n    let mut s = 0;\n    for i in 0..n {\n        s = s + i;\n    }\n    while s > 100 {\n        s = s - 1;\n        if s == 50 {\n            break;\n        }\n    }\n    return s;\n}\n\nfn loop_prints(n: i32) i32 {\n    for i in 0..n {\n        println(\"{}\", i);\n    }\n    return n;\n}\n\nfn prints(a: i32) i32 {\n    println(\"{}\", a);\n    return a;\n}\n\nfn rec(n: i32) i32 {\n    if n <= 1 {\n        return 1;\n    }\n    return n * rec(n - 1);\n}\n\n@no_const\nfn tagged(a: i32) i32 {\n    return a + 1;\n}\n\nfn gated() i32 {\n    if THREAD_SANITIZER {\n        return 1;\n    }\n    return 0;\n}\n\nfn main() i32 {\n    let p = P { x: 3 };\n    return branchy(4) + use_method(p) + already(1) + looping(2) + loop_prints(0) + prints(0) + rec(2) + tagged(0) + gated() - 22;\n}\n",
    );
    let root = p.dir();
    let mut args = String::from_str("lint --const \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    // Warnings exit 1, compiler-warning semantics.
    assert(r.exit != 0);
    assert(r.out_has("function 'norm' can be declared 'const fn'"));
    assert(r.out_has("function 'branchy' can be declared 'const fn'"));
    assert(r.out_has("function 'use_method' can be declared 'const fn'"));
    assert(!r.out_has("'already'"));
    assert(r.out_has("function 'looping' can be declared 'const fn'"));
    assert(!r.out_has("'loop_prints'"), "an extern call in a loop body disqualifies");
    assert(!r.out_has("'prints'"));
    assert(!r.out_has("'rec'"));
    assert(!r.out_has("'tagged'"), "a '@no_const' function is never suggested");
    assert(!r.out_has("'gated'"), "code another build runs may not be constant");
    assert(!r.out_has("'main'"));

    // Off by default: the same file lints clean.
    let mut dargs = String::from_str("lint \"");
    dargs.push_str(root);
    dargs.push_str("/main.spc\"");
    let d = p.run_raw(dargs.as_str());
    assert_eq(d.exit, 0);
    assert(!d.out_has("can be declared 'const fn'"));

    // `--fix` inserts `const ` before the `fn` keyword; the re-lint fixpoint then reports nothing.
    let mut fargs = String::from_str("lint --fix --const \"");
    fargs.push_str(root);
    fargs.push_str("/main.spc\"");
    let fx = p.run_raw(fargs.as_str());
    assert_eq(fx.exit, 0);
    let mut mp = String::from_str(root);
    mp.push_str("/main.spc");
    let fixed = loader::read_file(mp.as_str()).unwrap();
    assert(fixed.as_str().contains("const fn branchy"));
    assert(fixed.as_str().contains("const fn use_method"));
    // Extend member.
    assert(fixed.as_str().contains("const fn norm"));
    assert(fixed.as_str().contains("const fn looping"));
    assert(!fixed.as_str().contains("const fn loop_prints"));
    assert(!fixed.as_str().contains("const fn prints"));
    assert(!fixed.as_str().contains("const fn rec"));
    assert(!fixed.as_str().contains("const fn main"));
    // `already` was const before the fix.
    assert(!fixed.as_str().contains("const const"));
}

// Ownership is DERIVED for structs and enums (their members' frees are synthesized), so plain
// aggregates lint clean, but a UNION cannot derive (only the author knows the active member):
// an owning union without an explicit Free impl is an error, with no machine fix.
@test
fn union_free_lint() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct Derived {\n    pub s: String,\n}\n\nunion Bad {\n    pub s: String,\n    pub n: u64,\n}\n\nunion Good {\n    pub s: String,\n    pub n: u64,\n}\n\nextend Good as Free {\n    pub fn free(self: &mut Good) {\n        unsafe self.s.free();\n    }\n}\n\nfn main() i32 {\n    let d = Derived { s: String::from_str(\"x\") };\n    let b = Bad { n: 3u64 };\n    let g = Good { s: String::from_str(\"y\") };\n    let k = d.s.len() + unsafe b.n as usize + unsafe g.s.len();\n    return (k - 5) as i32;\n}\n",
    );
    let root = p.dir();
    let mut dargs = String::from_str("lint \"");
    dargs.push_str(root);
    dargs.push_str("/main.spc\"");
    let d = p.run_raw(dargs.as_str());
    assert(d.exit != 0);
    assert(d.out_has("union 'Bad' has owning fields ('s') but no 'free'"));
    // Structs derive: never flagged.
    assert(!d.out_has("'Derived'"));
    // Explicit impl satisfies the rule.
    assert(!d.out_has("union 'Good'"));
}

// Ownership derives through nested instances of one generic declaration: `W<W<String>>` owns
// exactly as `W<String>` does, so both unions are flagged.
@test
fn union_free_lint_nested_instance() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct W<T> {\n    pub x: T,\n}\n\nunion Deep {\n    pub a: W<W<String>>,\n    pub n: u64,\n}\n\nunion Flat {\n    pub a: W<String>,\n    pub n: u64,\n}\n\nfn main() i32 {\n    let d = Deep { n: 1u64 };\n    let f = Flat { n: 1u64 };\n    return (unsafe d.n + unsafe f.n) as i32 - 2;\n}\n",
    );
    let root = p.dir();
    let mut dargs = String::from_str("lint \"");
    dargs.push_str(root);
    dargs.push_str("/main.spc\"");
    let d = p.run_raw(dargs.as_str());
    assert(d.out_has("union 'Deep' has owning fields ('a') but no 'free'"));
    assert(d.out_has("union 'Flat' has owning fields ('a') but no 'free'"));
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
        "enum E {\n    A(i32),\n    B,\n}\n\nfn muts(a: i32) i32 {\n    let mut kept = a;\n    kept = kept + 1;\n    let mut extra = a;\n    return kept + extra;\n}\n\nfn stores(a: i32) i32 {\n    let mut v = a;\n    v = 7;\n    return v;\n}\n\nfn labeled(n: i32) i32 {\n    let mut s = 0;\n    'outer: for i in 0..n {\n        s = s + i;\n    }\n    'used: for i in 0..n {\n        if i == 1 {\n            break 'used;\n        }\n        s = s + i;\n    }\n    return s;\n}\n\nfn unreach(a: i32) i32 {\n    let mut s = a;\n    if a > 0 {\n        return s;\n        s = 0;\n    }\n    return -s;\n}\n\nfn arms(e: E) i32 {\n    return switch e {\n        _ => {\n            0;\n        },\n        B => {\n            1;\n        },\n    };\n}\n\nfn derefs(a: i32) i32 {\n    let r = &a;\n    let b = *&a;\n    let c = &*r;\n    return b + *c;\n}\n\nfn aliased(a: i32) i32 {\n    let mut w = a;\n    w = 2;\n    let r = &w;\n    let mut z = a;\n    z = 4;\n    let f = |q: i32, y: i32| q + z;\n    let mut s = 0;\n    'w: while s < 100 {\n        s = s + 1;\n        'inner: while s < 50 {\n            continue 'w;\n        }\n    }\n    return *r + f(1, 2) + s;\n}\n\nfn main() i32 {\n    let e = E::A(2);\n    return muts(1) + stores(2) + labeled(3) + unreach(4) + arms(e) + derefs(5) + aliased(1) - 30;\n}\n",
    );
    let root = p.dir();
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.exit != 0);
    assert(r.out_has("'extra' does not need to be mutable"));
    assert(!r.out_has("'kept' does not need"));
    // Mutated: the dead store still requires mut.
    assert(!r.out_has("'v' does not need"));
    assert(r.out_has("value assigned to 'v' is overwritten before it is read"));
    assert(r.out_has("unused label ''outer'"));
    assert(!r.out_has("''used'"));
    // Address-taken and closure-captured bindings are exempt from the dead-store lint.
    assert(!r.out_has("value assigned to 'w'"));
    assert(!r.out_has("value assigned to 'z'"));
    assert(r.out_has("unused parameter 'y'"));
    assert(r.out_has("unused label ''inner'"));
    assert(!r.out_has("''w'"));
    assert(r.out_has("unreachable statement"));
    assert(r.out_has("unreachable arm: a previous arm matches every value"));
    assert(r.out_has("unnecessary '*&': the expression can be used directly"));
    assert(r.out_has("unnecessary '&*': the reference can be used directly"));

    let mut fargs = String::from_str("lint --fix \"");
    fargs.push_str(root);
    fargs.push_str("/main.spc\"");
    // Report-only findings remain, so the final pass still exits 1.
    p.run_raw(fargs.as_str());
    let mut mp = String::from_str(root);
    mp.push_str("/main.spc");
    let fixed = loader::read_file(mp.as_str()).unwrap();
    // Mut dropped.
    assert(fixed.as_str().contains("let extra = a;"));
    // Mut kept.
    assert(fixed.as_str().contains("let mut kept = a;"));
    // *& dropped.
    assert(fixed.as_str().contains("let b = a;"));
    // &* dropped.
    assert(fixed.as_str().contains("let c = r;"));
}

// Lint runs the package-wide checks a build runs once every module is typechecked: a conformance
// declared in two modules fails the lint as it fails the build.
@test
fn lint_reports_cross_module_duplicate_conformance() {
    let p = cli::proj_new();
    p.mkfile(
        "lib.spc",
        "pub struct P {\n    pub a: i32,\n}\n\nextend P as Default {\n    pub fn default() P {\n        return P { a: 1 };\n    }\n}\n",
    );
    p.mkfile(
        "main.spc",
        "import lib;\n\nextend lib::P as Default {\n    pub fn default() lib::P {\n        return lib::P { a: 2 };\n    }\n}\n\nfn main() i32 {\n    let p = lib::P::default();\n    return p.a;\n}\n",
    );
    // Run from the project root, which has no `src/`, so `import lib` resolves beside main.spc. The path
    // is absolute: a wasm guest has no working directory.
    let root = p.dir();
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", args.as_str());
    assert(r.out_shows("duplicate conformance"));
    assert(r.exit != 0, "the lint fails");
}

// In a project with `src/`, a file outside the project's module tree (src, tests, bench, std, ffi)
// is a standalone program: its imports resolve beside it, as `super-c build <file>` resolves them,
// whether the file is listed or found under a listed directory.
@test
fn lint_resolves_a_standalone_program_beside_itself() {
    if cli::on_wasm() {
        return; // the project layout is read from the working directory, which the guest lacks
    }
    let p = cli::proj_new();
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    p.mkfile("tools/t/lib.spc", "pub fn one() i32 {\n    return 1;\n}\n");
    p.mkfile("tools/t/main.spc", "import lib;\n\nfn main() i32 {\n    return lib::one() - 1;\n}\n");
    let root = p.dir();
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/tools/t/main.spc\"");
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", args.as_str());
    assert(!r.out_shows("cannot open module"), "the listed file resolves `lib` beside it");
    assert_eq(r.exit, 0);
    let rd = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint");
    assert(!rd.out_shows("cannot open module"), "the collected file resolves `lib` beside it");
    assert_eq(rd.exit, 0);
}

// Char-range patterns compare decoded code points: two ranges of different non-ASCII chars that
// share a UTF-8 lead byte are disjoint, so neither arm is reported unreachable.
@test
fn non_ascii_char_ranges_are_disjoint() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "fn cls(c: char) i32 {\n    return switch c {\n        'à'..='ÿ' => 1,\n        'À'..='Ö' => 2,\n        _ => 3,\n    };\n}\n\nfn main() i32 {\n    return cls('a') - 3;\n}\n",
    );
    let mut args = String::from_str("lint \"");
    args.push_str(p.dir());
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(!r.out_has("unreachable arm"));
    assert_eq(r.exit, 0);
}

// A glob import re-exports its module's names: unused, it is reported only in a module nothing imports.
@test
fn glob_imports_re_export() {
    let p = cli::proj_new();
    p.mkfile("extra.spc", "pub fn e() i32 {\n    return 1;\n}\n");
    p.mkfile("lib.spc", "import extra as *;\n\npub fn l() i32 {\n    return 2;\n}\n");
    p.mkfile("main.spc", "import lib;\nimport extra as *;\n\nfn main() i32 {\n    return lib::l() - 2;\n}\n");
    let mut args = String::from_str("lint \"");
    args.push_str(p.dir());
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.out_has("unused import 'extra'") && r.out_has("main.spc:2:1"));
    assert(!r.out_has("lib.spc"));
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
    let root = p.dir();
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
    // Unused import deleted.
    assert(!fixed.as_str().contains("import stdio;"));
    assert(fixed.as_str().contains("import string as cstring;"));
}

// The always-panics check (the `unconditional_panic` analog, an ERROR): a fully const-foldable
// statement chain that DETERMINISTICALLY traps: UB, or a panic reached inside a `const fn` (the
// checked-accessor class): fails the build; explicit user `panic(..)` calls and anything
// runtime-dependent stay silent.
@test
fn always_panics_lint() {
    let p = cli::proj_new();
    let at = "fn main() i32 {\n    let y = 13i32;\n    let arr = Array::<i32, 512>::filled(&y);\n    let x = arr.at(1000000);\n    return *x;\n}\n";
    // An error on the PLAIN compile path, not only under `lint`. Through a closure: the call stack
    // names the closure frame (its syntax may be released by then).
    let mut c = cli::Batch::new("", "");
    c.add("a provable panic fails the build", at, "error: this statement always panics at runtime");
    c.add("the panic names its call stack", at, "call stack: at -> panic");
    c.add(
        "a closure's call stack",
        "fn main() i32 {\n    let f = |a: i32| a + 2147483647;\n    return f(1);\n}\n",
        "error: this statement is undefined behavior when executed: arithmetic overflow (call stack: <closure>;",
    );
    p.expect_batch(c);
    let root = p.dir();
    p.mkfile("main.spc", at);
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.exit != 0, "the lint fails on a provable panic");
    assert(r.out_has("error: this statement always panics at runtime"), "and names it");

    // UB through folded locals errors too (its own wording: UB is not a panic).
    p.mkfile("ub.spc", "fn main() i32 {\n    let z = 0;\n    let q = 1 / z;\n    return q;\n}\n");
    let mut uargs = String::from_str("lint \"");
    uargs.push_str(root);
    uargs.push_str("/ub.spc\"");
    let u = p.run_raw(uargs.as_str());
    assert(u.exit != 0, "the lint fails on a provable division by zero");
    assert(u.out_has("error: this statement is undefined behavior when executed: division by zero"), "and names it");

    // Silent: an explicit panic helper (intent), a runtime-dependent index, and a guard that folds false.
    p.mkfile(
        "quiet.spc",
        "fn die(msg: str) {\n    panic(msg);\n}\n\nfn with_param(i: usize) i32 {\n    let a = [1, 2, 3];\n    return unsafe a[i];\n}\n\nfn main() i32 {\n    let ok = [1, 2, 3];\n    let v = ok[1];\n    if v > 5 {\n        die(\"big\");\n    }\n    return with_param(0) + v;\n}\n",
    );
    let mut qargs = String::from_str("lint \"");
    qargs.push_str(root);
    qargs.push_str("/quiet.spc\"");
    let q = p.run_raw(qargs.as_str());
    assert_eq(q.exit, 0);
    assert(!q.out_has("always panics"), "intent, run-time indexes and folded guards are silent");
}

// A build checks the project's modules, not the std and ffi trees (check.sh lints those): a provable
// panic, an unbounded recursion and an unused item in a nested std module or an ffi binding are silent,
// and the same code in a project module is reported.
@test
fn build_checks_skip_std_and_ffi_panic_recursion_and_unused() {
    let p = cli::proj_new();
    let root = p.dir();
    cli::copy_std(root);
    let code = String::from_str(
        M"(pub fn zz_TAG_panics() i32 {
    let y = 13i32;
    let arr = Array::<i32, 512>::filled(&y);
    let x = arr.at(1000000);
    return *x;
}

pub fn zz_TAG_spins(n: u64) u64 {
    return zz_TAG_spins(n + 1);
}

fn zz_TAG_unused() {}
)",
    );
    p.mkfile("sc/std/zz/probe.spc", code.replace("TAG", "std").as_str());
    p.mkfile("sc/ffi/zz_probe.spc", code.replace("TAG", "ffi").as_str());
    p.mkfile("own.spc", code.replace("TAG", "own").as_str());
    p.mkfile(
        "main.spc",
        M"(import std::zz::probe;
import zz_probe;
import own;

fn main() i32 {
    let s = probe::zz_std_spins(1) + zz_probe::zz_ffi_spins(1) + own::zz_own_spins(1);
    return probe::zz_std_panics() + zz_probe::zz_ffi_panics() + own::zz_own_panics() + s as i32;
}
)",
    );
    let mut env = String::new();
    env.format_into("{}/cache SC_STD_DIR={}/sc/std", root, root);
    let r = cli::superc_env_in(root, "SC_CACHE_DIR", env.as_str(), "build main.spc");
    assert(r.exit != 0, "the project module's findings fail the build");
    assert(r.out_has("error: this statement always panics at runtime"), "a project panic is reported");
    assert(r.out_shows("error: function 'zz_own_spins' cannot return without calling itself"), "and its recursion");
    assert(r.out_shows("unused function 'zz_own_unused'"), "and its unused item");
    assert(!r.out_has("probe.spc"), "the std and ffi modules report nothing");
    assert(!r.out_has("zz_std_") && !r.out_has("zz_ffi_"), "nothing names their functions");
}

// Unbounded recursion is an ERROR on every build (ir/recursion.spc): a function or method no path of
// which returns before it calls itself again, directly or through a cycle of such functions, a call in
// tail position or after a loop included. A base case, a panic, an exit and a call through a function
// value each give a path that ends, and stay silent.
@test
fn unbounded_recursion_is_an_error() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct Bag {
    pub n: usize,
}

extend Bag {
    pub fn size(self: &Bag) usize {
        return self.size();
    }
}

fn forever(n: u64) u64 {
    return forever(n + 1);
}

fn ping(n: i32) i32 {
    return pong(n + 1);
}

fn pong(n: i32) i32 {
    if n > 3 {
        return ping(n);
    }
    return ping(n - 1);
}

fn spin(n: i32) i32 {
    let mut i = n;
    while i < 100 {
        i += 1;
    }
    return spin(i);
}

fn main(args: Vector<str>) i32 {
    let b = Bag { n: args.len() };
    return forever(1) as i32 + ping(1) + spin(0) + b.size() as i32;
}
)",
    );
    let c = p.compile("main.spc");
    assert(c.exit != 0, "unbounded recursion fails the build");
    assert(c.out_shows("error: function 'forever' cannot return without calling itself"), "a direct call");
    assert(c.out_shows("error: function 'size' cannot return without calling itself"), "a method");
    assert(c.out_shows("error: function 'spin' cannot return without calling itself"), "a call after a loop");
    assert(
        c.out_shows("error: function 'ping' cannot return without calling 'pong', which cannot return either"),
        "a cycle's first function",
    );
    assert(
        c.out_shows("error: function 'pong' cannot return without calling 'ping', which cannot return either"),
        "a cycle's second function",
    );
    assert(c.out_shows("no path returns before such a call"), "the reason");
    assert(!c.out_has("function 'main'"), "a caller of the cycle is not part of it");

    p.mkfile(
        "quiet.spc",
        M"(import stdlib;

fn counted(n: i32) i32 {
    if n <= 0 {
        return 0;
    }
    return counted(n - 1);
}

fn until_panic(n: i32) i32 {
    if n == 0 {
        panic("done");
    }
    return until_panic(n - 1);
}

fn until_exit(n: i32) i32 {
    if n == 0 {
        unsafe stdlib::exit(0);
    }
    return until_exit(n - 1);
}

fn through(f: fn(i32) i32, n: i32) i32 {
    return f(n);
}

fn twice(n: i32) i32 {
    return through(twice, n);
}

fn main(args: Vector<str>) i32 {
    let k = args.len() as i32;
    if k > 100 {
        return twice(k);
    }
    return counted(k) + until_panic(k) + until_exit(k);
}
)",
    );
    let q = p.compile("quiet.spc");
    assert(q.ok(), "a path that ends is silent");
}

// A function that cannot end is reported at its first call of a function that cannot end either, never
// at an earlier call of one that ends. A cancellation the lowering checks after a call in a task is
// not a path of the body: it does not end the function.
@test
fn unbounded_recursion_names_a_call_that_never_returns() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(fn first(n: i32) i32 {
    let a = second(n);
    return first(a);
}

fn second(n: i32) i32 {
    if n == 0 {
        return 0;
    }
    return first(n - 1);
}

fn main() i32 {
    return first(1);
}
)",
    );
    let c = p.compile("main.spc");
    assert(c.exit != 0, "unbounded recursion fails the build");
    assert(
        c.out_shows("error: function 'first' cannot return without calling itself"),
        "at the call that never returns",
    );
    assert(!c.out_has("function 'second'"), "second returns when its argument is 0");
    p.mkfile(
        "task.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::time as time;

fn spin(n: i64) i64 {
    time::sleep(time::Duration::from_nanos(1));
    return spin(n - 1);
}

fn main() i32 {
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        let _ = spin(3);
        w.done();
    };
    let _ = rt::request_cancel(rt::current_key(), rt::CR_USER);
    wg.wait();
    rt::shutdown();
    return 0;
}
)",
    );
    let t = p.compile("task.spc");
    assert(t.exit != 0, "a cancellation does not end the recursion");
    assert(t.out_shows("error: function 'spin' cannot return without calling itself"), "the task's recursion");
}

// A constant operation that traps on every execution is an error at the operation: an ordinary body,
// a closure, a generic body (once, with a note, not at the call), and an initializer, used or not,
// whose message names the item. A trap through a call stays at the item's name; a branch a closed
// condition makes dead is not checked.
@test
fn constant_traps_at_the_operation() {
    let p = cli::proj_new();
    let root = p.dir();
    let op = "error: this operation is undefined behavior when executed:";
    let body = "fn main() i32 {\n    let x: i32 = 5;\n    let a = x / (1 - 1);\n    let b = x << 40;\n    let c: i8 = -(-128i8);\n    let d: i32 = 2147483647 + 1;\n    return a + b + c as i32 + d;\n}\n";
    let gen = "fn g<T>(x: T) i32 {\n    return 2147483647 + 1;\n}\n\nfn main() i32 {\n    return g::<i32>(1) + g::<u8>(2);\n}\n";
    let mut b = cli::Batch::new("", "");
    // The generic body traps once, with a note, and not at the call; no initializer fails internally.
    b.forbid("call stack");
    b.forbid("internal");
    b.add_at("a division by zero", body, format("{} division by zero\n--> ", op).as_str(), "3:13");
    b.add_at("a shift out of range", body, format("{} shift out of range\n--> ", op).as_str(), "4:13");
    b.add_at("a negation overflow", body, format("{} arithmetic overflow\n--> ", op).as_str(), "5:17");
    b.add_at("an addition overflow", body, format("{} arithmetic overflow\n--> ", op).as_str(), "6:18");
    b.add_at(
        "in a closure",
        "fn main() i32 {\n    let f = |a: i32| a + (2147483647 + 1);\n    return f(1);\n}\n",
        format("{} arithmetic overflow\n--> ", op).as_str(),
        "2:27",
    );
    b.add_at("in a generic body", gen, format("{} arithmetic overflow\n--> ", op).as_str(), "2:12");
    b.add_at(
        "the generic body's note",
        gen,
        "= note: its operands do not depend on a type parameter: every instantiation traps",
        "2:12",
    );
    b.add_at(
        "an unused static",
        "static mut S: i32 = 2147483647 + 1;\n\nfn main() i32 {\n    return 0;\n}\n",
        "error: static 'S' cannot be evaluated at compile time: arithmetic overflow\n--> ",
        "1:21",
    );
    b.add_at(
        "a used static",
        "static mut U: i32 = 7 / 0;\n\nfn main() i32 {\n    return unsafe U;\n}\n",
        "error: static 'U' cannot be evaluated at compile time: division by zero\n--> ",
        "1:21",
    );
    b.add_at(
        "a constant",
        "const C: u8 = 255 + 1;\n\nfn main() i32 {\n    return 0;\n}\n",
        "error: constant 'C' cannot be evaluated at compile time: arithmetic overflow\n--> ",
        "1:15",
    );
    p.expect_batch(b);
    p.mkfile(
        "call.spc",
        "const fn f(x: i32) i32 {\n    return x + 2147483647;\n}\n\nstatic mut S: i32 = f(1);\n\nfn main() i32 {\n    return 0;\n}\n",
    );
    let cl = p.compile("call.spc");
    assert(cl.exit != 0, "a trap through a call fails the build");
    assert(
        cl.out_shows("error: static 'S' cannot be evaluated at compile time: arithmetic overflow (call stack: f;"),
        "the trap names the item and its call stack",
    );
    assert(cl.out_shows(format("\n--> {}/call.spc:5:12", root).as_str()), "at the item's initializer");
    p.mkfile(
        "dead.spc",
        "fn main() i32 {\n    let x: i32 = 5;\n    if false {\n        return x / 0;\n    }\n    if 1 > 2 {\n        return 2147483647i32 + 1;\n    } else {\n        return 0;\n    }\n}\n",
    );
    assert(p.compile("dead.spc").ok(), "a branch a closed guard removes does not trap");
}

// A private associated function reached only through a type path (`S::helper(..)`) is resolved by
// the type checker, not the resolver: the unused-item lint must read the post-typecheck item edges,
// or it reports the function unused.
@test
fn type_path_call_marks_a_private_associated_function_used() {
    // The wasm guest has no stable cwd or subprocesses; this drives a working-directory-
    // dependent guest command, so it runs on native and Windows only.
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "solo.spc",
        "struct S {\n    pub v: i32,\n}\n\nextend S {\n    fn helper(v: i32) i32 {\n        return v + 1;\n    }\n\n    pub fn run(self: &S) i32 {\n        return S::helper(self.v);\n    }\n}\n\nfn main() i32 {\n    let s = S { v: 1 };\n    return s.run() - 2;\n}\n",
    );
    let root = p.dir();
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint solo.spc");
    assert(r.ok(), "a private associated function called through a type path is used");
}

// A reference that is the first node of a module's first releasable body (a leading turbofish
// callee) sits at body-arena id 0, a real node: the item edges must keep it, or the unused-item
// lint reports the generic function unused.
@test
fn leading_turbofish_call_marks_a_generic_function_used() {
    let p = cli::proj_new();
    let g = "fn g<T>(x: T) T {\n    return x;\n}\n\n";
    let mains = [
        "fn main() i32 {\n    g::<i32>(1);\n    return 0;\n}\n",
        "fn main() i32 {\n    return g::<i32>(1) - 1;\n}\n",
        "fn main() i32 {\n    return (g::<i32>(1)) - 1;\n}\n",
        "fn k() i32 {\n    return g::<i32>(1);\n}\n\nfn main() i32 {\n    return k() - 1;\n}\n",
    ];
    let root = p.dir();
    for m in mains {
        let mut src = String::from_str(g);
        src.push_str(m);
        p.mkfile("main.spc", src.as_str());
        let mut args = String::from_str("lint \"");
        args.push_str(root);
        args.push_str("/main.spc\"");
        let r = p.run_raw(args.as_str());
        assert(!r.out_has("unused function 'g'"), "a leading turbofish call uses the generic function");
        assert_eq(r.exit, 0);
    }
}

// A cast to a type alias is not unnecessary: the alias may name another type on another target (`mode_t`
// is `u16` on macOS, `u32` on Linux). A cast to the type itself is.
@test
fn a_cast_to_an_alias_is_kept() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "type mode = u32;\n\nfn widen(x: u32) mode {\n    return x as mode;\n}\n\nfn same(x: u32) u32 {\n    return x as u32;\n}\n\nfn main() i32 {\n    return (widen(1) + same(1)) as i32 - 2;\n}\n",
    );
    let r = p.run_raw(format("lint \"{}/main.spc\"", p.dir()).as_str());
    assert(r.out_has("main.spc:8:12"), "the cast to the type itself is reported");
    assert(!r.out_has("main.spc:4:12"), "the cast to the alias is not");
}

@test
fn standalone_file_lint_and_fix() {
    // The wasm guest has no stable cwd or subprocesses; this drives a working-directory-
    // dependent guest command, so it runs on native and Windows only.
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "solo.spc",
        "fn take(q: *mut i32) i32 {\n    return unsafe *q;\n}\n\nfn main() i32 {\n    let mut x = 1;\n    return take((&mut x) as *mut i32) - 1;\n}\n",
    );
    let root = p.dir();
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint solo.spc");
    // The redundant coalescing cast is reported through the per-path route.
    assert(r.out_has("unnecessary cast"), "the standalone lint reports the redundant cast");
    // --fix removes it in place.
    let fr = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint --fix solo.spc");
    assert(fr.ok(), "the fix run succeeds");
    let mut sp = String::from_str(root);
    sp.push_str("/solo.spc");
    let fixed = loader::read_file(sp.as_str()).unwrap();
    assert(fixed.as_str().contains("return take(&mut x) - 1;"), "the cast was removed");
    assert(!fixed.as_str().contains("as *mut i32"), "no cast remains");
}

// The const-suggestion lint (`lint --const`) proves whether a function is fully compile-time
// evaluable. Its deep effect scan recurses into `switch`/`match` arms and their patterns, so a
// const-foldable function built around a switch exercises that scan.
@test
fn const_suggestion_scans_a_switch() {
    // The wasm guest has no stable cwd or subprocesses; this drives a working-directory-
    // dependent guest command, so it runs on native and Windows only.
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    // `classify` is scanned through its switch arms and patterns; `dbl` is a straight-line
    // const-eligible function the lint flags, proving the sweep ran.
    p.mkfile(
        "solo.spc",
        "fn classify(n: i32) i32 {\n    return switch n {\n        0 => 10,\n        1..=5 => 20,\n        _ => 0,\n    };\n}\nfn dbl(n: i32) i32 {\n    return n * 2;\n}\nfn main() i32 { return classify(1) + dbl(0) - 20; }\n",
    );
    let root = p.dir();
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint --const solo.spc");
    assert(r.out_shows("function 'dbl' can be declared 'const fn'"), "the sweep ran");
    assert(r.out_shows("function 'classify' can be declared 'const fn'"), "the scan sees through the switch");
}

// A closed `if`/`while` condition the engine folds is always true or false: the warning names
// it, the dead branch or loop body is reported unreachable, and `--fix` folds the statement (an
// `if` becomes its live branch, `while false` disappears, `while true` becomes `loop`).
@test
fn constant_condition_lint_and_fix() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(const K: bool = 1 < 2;
fn f(x: i32) i32 {
    if K {
        return x + 1;
    } else {
        return x - 1;
    }
}
fn g() i32 {
    let mut n = 0;
    while false {
        n = n + 1;
    }
    while true {
        n = n + 1;
        if n > 3 {
            break;
        }
    }
    return n;
}
fn main() i32 {
    return f(1) + g() - 6;
}
)",
    );
    let root = p.dir();
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.out_has("condition is always true"), "the const condition and `while true` fold to true");
    assert(r.out_has("condition is always false"), "`while false` folds to false");
    assert(r.out_has("unreachable branch"), "the else branch of the true condition never runs");
    assert(r.out_has("unreachable loop body"), "the body of `while false` never runs");
    let mut fargs = String::from_str("lint --fix \"");
    fargs.push_str(root);
    fargs.push_str("/main.spc\"");
    let fr = p.run_raw(fargs.as_str());
    assert(fr.ok(), "the folded program lints clean");
    let mut mp = String::from_str(root);
    mp.push_str("/main.spc");
    let fixed = loader::read_file(mp.as_str()).unwrap();
    let t = fixed.as_str();
    assert(t.contains("return x + 1;"), "the live branch stays");
    assert(!t.contains("return x - 1;"), "the dead branch is folded away");
    assert(!t.contains("if K"), "the folded `if` is gone");
    assert(!t.contains("while false"), "the never-running loop is gone");
    assert(t.contains("loop {"), "`while true` reads as `loop`");
    assert(!t.contains("while true"), "and the old spelling is gone");
    let run = p.compile("main.spc");
    assert(run.ok(), "the folded program compiles");
}

// Code after a statement that never completes is unreachable: a `return`, an `if` whose two
// branches both return, and a `loop` no `break` leaves; a `loop` with a `break` is not.
@test
fn unreachable_code_lint() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(fn a(x: i32) i32 {
    if x > 0 {
        return 1;
    } else {
        return 2;
    }
    return 3;
}
fn b() i32 {
    loop {
        a(1);
    }
    return 4;
}
fn c() i32 {
    let mut n = 0;
    loop {
        n = n + 1;
        if n > 2 {
            break;
        }
    }
    return n;
}
fn main() i32 {
    return a(1) + b() + c();
}
)",
    );
    let root = p.dir();
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.out_has("main.spc:7:5"), "the statement after the diverging `if` is reported");
    assert(r.out_has("main.spc:13:5"), "the statement after the endless `loop` is reported");
    assert(!r.out_has("main.spc:23:5"), "the statement after a loop with a `break` is not");
}

// A `mut` on one tuple-let element is checked like any binding's.
@test
fn tuple_let_element_mut_lint() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "fn f() (i32, i32) {\n    return 1, 2;\n}\n\nfn main() i32 {\n    let (mut a, mut b) = f();\n    a += 1;\n    return a + b - 4;\n}\n",
    );
    let root = p.dir();
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.exit != 0);
    assert(r.out_has("'b' does not need to be mutable"));
    assert(!r.out_has("'a' does not need"));
}

// A format argument is checked once before the call rewrites into its format block and again
// inside the block: its warnings and fixes are reported once, and `--fix` deletes the unnecessary
// `unsafe` once.
@test
fn format_argument_warnings_report_once() {
    let p = cli::proj_new();
    p.mkfile("main.spc", "fn main() i32 {\n    let g = [1, 2];\n    print(\"{}\\n\", unsafe g[1]);\n    return 0;\n}\n");
    let root = p.dir();
    let mut args = String::from_str("lint \"");
    args.push_str(root);
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    let out = unsafe str::from_cstr(r.out);
    let needle = "unnecessary 'unsafe'";
    let first = out.find(needle);
    assert(first >= 0, "the warning is reported");
    let rest = out.slice(first as usize + needle.len(), out.len());
    assert(rest.find(needle) < 0, "the warning is reported once");
    let mut fargs = String::from_str("lint --fix \"");
    fargs.push_str(root);
    fargs.push_str("/main.spc\"");
    p.run_raw(fargs.as_str());
    let mut mp = String::from_str(root);
    mp.push_str("/main.spc");
    let fixed = loader::read_file(mp.as_str()).unwrap();
    assert(fixed.as_str().contains("print(\"{}\\n\", g[1]);"));
}

const BC_LINT: str = M"(@platform(windows)
fn win_count(n: i32) i32 {
    return n;
}

fn count(n: i32) i32 {
    let mut v = 0;
    if PLATFORM == Platform::Windows {
        v = win_count(n);
    }
    if PROFILE == "release" {
        v += 1;
    }
    if POINTER_WIDTH == 64 && v >= 0 {
        v += 2;
    }
    return v;
}

fn main() i32 {
    return count(1) - count(1);
}
)";

const BC_LINT_REST: str = M"(fn win_only() i32 {
    return 3;
}

fn never() i32 {
    return 4;
}

fn page(x: i32) i32 {
    let mut y = 1;
    let z = 2;
    let w = 5;
    if PLATFORM == Platform::Windows {
        y = win_only() + z;
    }
    unsafe {
        if PLATFORM == Platform::Linux {
            return y;
        }
    }
    if PLATFORM != Platform::Windows {
        return y + x;
    }
    return 0;
}

fn main() i32 {
    let mut m = 1;
    return page(0) - 1 + m;
}
)";

// Code the platform filter removed suppresses only the answers it could change: a name its text
// spells (`win_only`, `z`, the write to `y`) is used, an `unsafe` that holds it may be needed, and a
// statement after a decided branch may be reachable elsewhere. Every other warning of the module
// stays, on every target.
@test
fn build_constant_removed_code_suppresses_only_its_names() {
    let p = cli::proj_new();
    p.mkfile("main.spc", BC_LINT_REST);
    let root = p.dir();
    for t in 0..3 {
        let mut args = String::new();
        args.format_into(
            "lint{} \"{}/main.spc\"",
            if t == 0 {
                "";
            } else if t == 1 {
                " --target=windows";
            } else {
                " --target=linux";
            },
            root,
        );
        let r = p.run_raw(args.as_str());
        assert(r.out_has("unused variable 'w'"));
        assert(r.out_has("unused function 'never'"));
        assert(r.out_has("'m' does not need to be mutable"));
        assert(!r.out_has("win_only") && !r.out_has("'z'") && !r.out_has("'y'"));
        assert(!r.out_has("unsafe") && !r.out_has("unreachable"));
    }
}

// Conditions over build constants are deliberate switches: no constant-condition or unreachable
// warning, and the code the platform filter removed (the only use of `n` and the only write to `v`
// outside Windows) does not make a binding look unused or needlessly mutable.
@test
fn build_constant_conditions_lint_quietly() {
    let p = cli::proj_new();
    p.mkfile("main.spc", BC_LINT);
    let root = p.dir();
    for t in 0..3 {
        let mut args = String::new();
        args.format_into(
            "lint{} \"{}/main.spc\"",
            if t == 0 {
                "";
            } else if t == 1 {
                " --target=windows";
            } else {
                " --target=linux";
            },
            root,
        );
        let r = p.run_raw(args.as_str());
        assert(r.ok(), "the build-constant conditions lint clean on every target");
        assert(!r.out_has("warning"));
    }
}

// Lint loads the prelude before the files: an explicit import of a prelude file reaches the prelude
// module, as in a build, so its types are the prelude's, not a second copy's.
@test
fn lint_explicit_prelude_import_is_the_prelude_module() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import std::vector;\n\nfn main() i32 {\n    let v = vector::Vector::<i32>::new();\n    let w: Vector<i32> = v;\n    return w.len() as i32;\n}\n",
    );
    let mut args = String::from_str("lint \"");
    args.push_str(p.dir());
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(!r.out_has("mismatched types"));
    assert_eq(r.exit, 0);
}

// An import that only an item gated out by `@arch` uses is not reported: another instruction set
// compiles the item.
@test
fn arch_gated_uses_keep_imports() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import string as cstring;\n\n@arch(wasm32)\nfn len_of(s: str) usize {\n    return unsafe cstring::strlen(s.ptr() as *const char);\n}\n\n@arch(x86_64 | aarch64)\nfn len_of(s: str) usize {\n    return s.len();\n}\n\nfn main() i32 {\n    return len_of(\"ab\") as i32 - 2;\n}\n",
    );
    let mut args = String::from_str("lint \"");
    args.push_str(p.dir());
    args.push_str("/main.spc\"");
    let r = p.run_raw(args.as_str());
    assert(!r.out_has("unused import"), "the gated item uses it");
    assert_eq(r.exit, 0);
}

// A byte pointer across the elements of a nested array or a vector stays inside one object, which
// the pointer rules allow: the compile-time model cannot follow such a view, so it reports nothing,
// and the program runs.
@test
fn byte_views_of_aggregates_are_no_provable_fault() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let srcs: [str; 2] = [
        "fn main() i32 {\n    let mut buf: [[u8; 32]; 2] = [[0; 32], [0; 32]];\n    let base = &mut buf as *mut [[u8; 32]; 2] as *mut u8;\n    for i in 0usize..32 {\n        unsafe *(base + 8 + i) = 1;\n    }\n    return buf[1][0] as i32 - 1;\n}\n",
        "fn main() i32 {\n    let mut v = Simd::<u8, 64>::splat(0);\n    let base = &mut v as *mut Simd<u8, 64> as *mut u8;\n    unsafe *(base + 40) = 7;\n    return v[40] as i32 - 7;\n}\n",
    ];
    for src in srcs {
        let p = cli::proj_new();
        p.mkfile("main.spc", src);
        let r = p.compile("main.spc");
        assert(r.ok() && !r.out_has("undefined behavior"), "no compile-time fault");
        assert(p.cc_build("").ok() && p.run_bin() == 0, "the run writes the bytes");
    }
}

// A conformance uses its interface and the interfaces of its parameters' bounds, generic or not; an
// interface nothing names, and a struct only an extend block names, stay unused.
@test
fn conformances_use_their_interfaces() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "interface Lane {}\nextend f32 as Lane {}\ninterface Twice { fn twice(self: &Self) i64; }\nextend<T: Lane> T as Twice { fn twice(self: &Self) i64 { return 2; } }\ninterface Never { fn n(self: &Self) i32; }\nstruct Lonely { pub x: i32 }\nextend Lonely { fn get(self: &Lonely) i32 { return self.x; } }\nfn main() i32 {\n    return (0.5f32.twice() != 2) as i32;\n}\n",
    );
    let mut args = String::new();
    args.format_into("lint \"{}/main.spc\"", p.dir());
    let r = p.run_raw(args.as_str());
    assert(!r.out_has("unused interface 'Lane'") && !r.out_has("unused interface 'Twice'"), "conformed interfaces");
    assert(r.out_has("unused interface 'Never'") && r.out_has("unused struct 'Lonely'"), "unused items");
}

// A constant evaluation that lowers a std operator method reads that method's parameter types from the
// method's module pool. `lint` type-checks the prelude in process, so the method's types are still
// provisional (one pool each) and a read through the wrong pool trips the pool bounds assert of
// `Ast::type_at`. Without that assert the pre-fix compiler passes this test by chance.
@test
fn const_eval_operator_reads_foreign_provisional_types() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import std::math::scalar as *;\nconst fn twice<T: Scalar>(a: T) T { return a + a; }\nconst X: f32 = twice(1.5);\nfn main() i32 {\n    return (X != 3.0) as i32;\n}\n",
    );
    let mut args = String::new();
    args.format_into("lint \"{}/main.spc\"", p.dir());
    let r = p.run_raw(args.as_str());
    assert(r.ok(), "lint evaluates the constant");
}

// A file of the test suite lints as `super-c test` builds it, with TEST set: an `@when(TEST)` item
// of the sources that only the tests use resolves.
@test
fn lint_sets_test_for_the_test_suite() {
    if cli::on_wasm() {
        return; // the project layout is read from the working directory, which the guest lacks
    }
    let p = cli::proj_new();
    p.mkfile("src/main.spc", "import util;\n\nfn main() i32 {\n    return util::twice(0);\n}\n");
    p.mkfile(
        "src/util.spc",
        "pub fn twice(x: i32) i32 {\n    return x * 2;\n}\n\n@when(TEST)\npub fn probe() i32 {\n    return 21;\n}\n",
    );
    p.mkfile(
        "tests/util_test.spc",
        "import util;\n\n@test\nfn probe_doubles() {\n    assert(util::twice(util::probe()) == 42, \"probe\");\n}\n",
    );
    let r = cli::superc_env_in(p.dir(), "SC_NO_EMIT_CACHE", "1", "lint");
    assert(!r.out_shows("no visible item 'probe'"), "the test file sees the TEST item");
    assert_eq(r.exit, 0);
}
