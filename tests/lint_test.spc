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
