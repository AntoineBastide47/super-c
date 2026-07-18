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
    let mut args = String::from_str("lint '");
    args.push_str(root);
    args.push_str("/main.spc'");
    let r = p.run_raw(args.as_str());
    assert(r.out_has("unnecessary cast: '&mut i32' converts to '*mut i32' implicitly here"));

    let mut fargs = String::from_str("lint --fix '");
    fargs.push_str(root);
    fargs.push_str("/main.spc'");
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
    let mut args = String::from_str("lint '");
    args.push_str(root);
    args.push_str("/main.spc'");
    let r = p.run_raw(args.as_str());
    assert(r.out_has("'&mut i32' converts to '&i32' implicitly here"));
    assert(r.out_has("'u8' converts to 'i64' implicitly here"));
    assert(r.out_has("'i32' converts to 'i64' implicitly here"));
    assert(r.out_has("'null' converts to '*mut i32' implicitly here"));
    assert(!r.out_has("'&mut i32' converts to '*mut i32'")); // the unannotated-let cast is load-bearing: quiet
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
    let mut args = String::from_str("lint '");
    args.push_str(root);
    args.push_str("/main.spc'");
    let r = p.run_raw(args.as_str());
    assert(r.exit != 0);
    assert(r.out_has("error: this statement always panics at runtime"));

    // UB through folded locals errors too (its own wording: UB is not a panic)
    p.mkfile("ub.spc", "fn main() i32 {\n    let z = 0;\n    let q = 1 / z;\n    return q;\n}\n");
    let mut uargs = String::from_str("lint '");
    uargs.push_str(root);
    uargs.push_str("/ub.spc'");
    let u = p.run_raw(uargs.as_str());
    assert(u.exit != 0);
    assert(u.out_has("error: this statement is undefined behavior when executed: division by zero"));

    // silent: an explicit panic helper (intent), a runtime-dependent index, and a guard that folds false
    p.mkfile(
        "quiet.spc",
        "fn die(msg: str) {\n    panic(msg);\n}\n\nfn with_param(i: usize) i32 {\n    let a = [1, 2, 3];\n    return unsafe a[i];\n}\n\nfn main() i32 {\n    let ok = [1, 2, 3];\n    let v = ok[1];\n    if v > 5 {\n        die(\"big\");\n    }\n    return with_param(0) + v;\n}\n",
    );
    let mut qargs = String::from_str("lint '");
    qargs.push_str(root);
    qargs.push_str("/quiet.spc'");
    let q = p.run_raw(qargs.as_str());
    assert_eq(q.exit, 0);
    assert(!q.out_has("always panics"));
}
