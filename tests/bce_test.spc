// Bounds-check normalization and elimination (plans/1_bounds_check_elimination.md §13):
// safety cases panic at the semantic operation, removal cases inspect the generated C for the
// explicit check calls, and the verifier rejects malformed check operations. Dynamic values are
// derived from argv so compile-time evaluation cannot fold the failing access away.
import tests::harness as h;
import ast::ast as *;
import ir::core as ir;
import ir::verify as irv;
import lexer::token as tok;
import driver_shim as shim;
import module::loader as loader;
import resolver::resolver as res;
import typechecker::typechecker as tc;
import ir::interp as iri;
import ir::lower as irl;

fn expect_c_user_absent(label: str, src: str, needle: str) {
    let c = h::compile_c_user(src);
    assert(c.ok(), label);
    assert(!c.code_has(needle), label);
}

fn expect_panics(label: str, src: str) {
    let r = h::compile_and_run(src);
    assert(r.built, label);
    assert(r.exit != 0, label);
}

// ---- §13.1 safety: every failing safe access panics before pointer arithmetic ------------------

@test
fn safety_element_checks() {
    // element index equal to the length
    expect_panics(
        "index == len panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 2] = [1, 2];\n    let s: []i32 = a[0..2];\n    let i = argv.len() + 1; // == 2 at runtime\n    return s[i];\n}\n",
    );
    // empty view element access
    expect_panics(
        "empty view access panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 2] = [1, 2];\n    let s: []i32 = a[0..0];\n    let i = argv.len() - 1; // == 0\n    return s[i];\n}\n",
    );
    // a valid dynamic access still works
    h::expect_exit(
        "valid dynamic access",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 3] = [7, 8, 9];\n    let s: []i32 = a[0..3];\n    let i = argv.len() - 1; // == 0\n    return s[i] - 7;\n}\n",
        0,
    );
}

@test
fn safety_range_checks() {
    // exclusive range with start > end
    expect_panics(
        "start > end panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let lo = argv.len() + 2; // == 3\n    let t: []i32 = s[lo..1];\n    return t.len() as i32;\n}\n",
    );
    // exclusive range with end > len
    expect_panics(
        "end > len panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let hi = argv.len() + 4; // == 5\n    let t: []i32 = s[0..hi];\n    return t.len() as i32;\n}\n",
    );
    // inclusive range with end == len
    expect_panics(
        "inclusive end == len panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let hi = argv.len() + 3; // == 4\n    let t: []i32 = s[0..=hi];\n    return t.len() as i32;\n}\n",
    );
    // inclusive range with end == usize::MAX: `end + 1` must NOT wrap past the check
    expect_panics(
        "inclusive end == usize::MAX panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let hi = 0xFFFFFFFFFFFFFFFFu64 as usize - 1 + argv.len(); // == usize::MAX\n    let t: []i32 = s[0..=hi];\n    return t.len() as i32;\n}\n",
    );
    // a range whose length subtraction would underflow without the ordered check
    expect_panics(
        "underflowing range panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let lo = argv.len() + 3; // == 4\n    let t: []i32 = s[lo..2];\n    return t.len() as i32;\n}\n",
    );
    // valid inclusive range still slices
    h::expect_exit(
        "valid inclusive range",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let hi = argv.len() + 1; // == 2\n    let t: []i32 = s[0..=hi];\n    return t.len() as i32 - 3;\n}\n",
        0,
    );
}

@test
fn safety_mutation_and_zst() {
    // a vector mutation between the proof and the access keeps the (passing) check honest
    h::expect_exit(
        "mutation between proof and access",
        "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(5);\n    let n = v.len() - argv.len() + 1; // == 1\n    v.push(6);\n    return v[n] - 6;\n}\n",
        0,
    );
    // zero-sized elements use logical lengths: in-range works, out-of-range panics
    h::expect_exit(
        "zst logical length in range",
        "struct Z {}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<Z>::new();\n    v.push(Z {});\n    v.push(Z {});\n    let i = argv.len(); // == 1\n    let _ = v[i];\n    return v.len() as i32 - 2;\n}\n",
        0,
    );
    expect_panics(
        "zst logical length out of range panics",
        "struct Z {}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<Z>::new();\n    v.push(Z {});\n    let i = argv.len() + 1; // == 2\n    let _ = v[i];\n    return 0;\n}\n",
    );
}

// ---- §13.2 removal: proved checks vanish from the generated C, retained ones stay --------------

@test
fn removal_canonical_loops() {
    // the canonical indexed `for` loop body carries no element check
    expect_c_user_absent(
        "for-in-slice loop has no bounds call",
        "fn sum(s: []i32) i32 {\n    let mut t = 0;\n    for v in s { t += v; }\n    return t;\n}\n",
        "__sc_bounds(",
    );
    // `for i in 0..s.len()` with a same-index access proves through the guard
    expect_c_user_absent(
        "indexed range loop has no bounds call",
        "fn sum(s: []i32) i32 {\n    let mut t = 0;\n    for i in 0..s.len() { t += s[i]; }\n    return t;\n}\n",
        "__sc_bounds(",
    );
    // a dominating guard proves the guarded access
    expect_c_user_absent(
        "dominating guard proves access",
        "fn get(s: []i32, i: usize) i32 {\n    if i < s.len() {\n        return s[i];\n    }\n    return 0;\n}\n",
        "__sc_bounds(",
    );
    // the full-view range check is proved away
    expect_c_user_absent(
        "full-view slice has no range call",
        "fn all(s: []i32) []i32 { return s[0..s.len()]; }\n",
        "__sc_range(",
    );
}

@test
fn removal_keeps_unproved() {
    // an arbitrary dynamic index keeps exactly its check
    h::expect_c("unproved index keeps its check", "fn get(s: []i32, i: usize) i32 { return s[i]; }\n", "__sc_bounds(");
    // a mutation between the guard and the access keeps the check
    h::expect_c(
        "mutating call between guard and access keeps the check",
        "fn get(v: &mut Vector<i32>, i: usize) i32 {\n    if i < v.len() {\n        v.push(0);\n        return (*v)[i];\n    }\n    return 0;\n}\n",
        "__sc_bounds(",
    );
    // an unclassifiable call (a fn value) between guard and access keeps the check; a direct
    // call of a harmless local fn is transparent and no longer retains it
    {
        let c = h::compile_c_user(
            "fn poke() {}\nfn get(s: []i32, i: usize) i32 {\n    if i < s.len() {\n        let f: fn() = poke;\n        f();\n        return s[i];\n    }\n    return 0;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(3);\n    let s: []i32 = v[0..1];\n    return get(s, argv.len() - 1) - 3;\n}\n",
        );
        assert(c.ok(), "fn-value call snippet compiles");
        assert(c.code_has("__sc_bounds("), "a fn-value call between guard and access keeps the check");
    }
    // a dynamic range keeps its range check
    h::expect_c(
        "dynamic range keeps its check",
        "fn cut(s: []i32, a: usize, b: usize) []i32 { return s[a..b]; }\n",
        "__sc_range(",
    );
}

@test
fn removal_behavior_parity() {
    // the same program computes the same result with the pass disabled
    let SRC: str = "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 5] = [1, 2, 3, 4, 5];\n    let s: []i32 = a[0..5];\n    let mut t = 0;\n    for v in s { t += v; }\n    for i in 0..s.len() { t += s[i]; }\n    let m: []i32 = s[1..=3];\n    for v in m { t += v; }\n    return t - 39 - (argv.len() as i32 - 1);\n}\n";
    h::expect_exit("bce enabled computes 39", SRC, 0);
    // the fork-per-test runner isolates this env change; the spawned build inherits it
    let _ = unsafe shim::sc_setenv("SC_BCE".ptr() as *const char, "0".ptr() as *const char);
    h::expect_exit("bce disabled computes 39", SRC, 0);
}

// ---- §13.3 verifier: malformed check operations are rejected -----------------------------------

fn check_body(opers: u32) ir::CoreBody {
    let mut b = ir::CoreBody::new(DefId { module: 0, node: 0 }, 0);
    let ut = Ast::builtin(BuiltinType::BT_USIZE);
    let l = b.add_local(
        ir::LocalDecl {
            ty: ut,
            storage: ir::LS_TEMP,
            is_mutable: false,
            span: tok_span(),
            decl: NODE_NONE,
            item: DefId { module: 0, node: NODE_NONE },
        },
    );
    b.places.push(ir::Place { base: l, proj_start: 0, proj_len: 0, ty: ut });
    b.constants.push(
        ir::Constant {
            kind: ir::CK_INT,
            ty: ut,
            val: 0,
            raw: tok_span(),
            item: DefId { module: 0, node: NODE_NONE },
            targ_start: 0,
            targ_len: 0,
        },
    );
    b.operands.push(ir::Operand { kind: ir::OP_CONST, data: 0, ty: ut });
    b.oper_pool.push(0);
    b.oper_pool.push(0);
    b.rvalues.push(
        ir::Rvalue {
            kind: ir::RV_INTRINSIC,
            a: 0,
            b: opers,
            c: ir::IN_BOUNDS,
            target: ut,
            item: DefId { module: 0, node: NODE_NONE },
        },
    );
    b.statements.push(ir::Statement { kind: ir::ST_ASSIGN, place: 0, rvalue: 0, a: 0, b: 0, span: tok_span() });
    let blk = b.add_block();
    b.blocks[blk as usize].stmt_start = 0;
    b.blocks[blk as usize].stmt_len = 1;
    b.blocks[blk as usize].term.kind = ir::TM_RETURN;
    b.blocks[blk as usize].sealed = true;
    return b;
}

const fn tok_span() tok::Span {
    return tok::Span { start: 0, end: 0 };
}

@test
fn verifier_rejects_malformed_checks() {
    // wrong operand count
    let bad = check_body(1);
    assert_eq(irv::verify(&bad, 4096, null), "check-operand-count");
    // operand range past the pool
    let mut bad2 = check_body(2);
    bad2.oper_pool.truncate(1);
    assert_eq(irv::verify(&bad2, 4096, null), "check-operand-out-of-range");
    // a well-formed check verifies
    let good = check_body(2);
    assert_eq(irv::verify(&good, 4096, null), "");
}

// ---- §8.5 affine offsets and §9 range-check coalescing -----------------------------------------

fn expect_c_user_present(label: str, src: str, needle: str) {
    let c = h::compile_c_user(src);
    assert(c.ok(), label);
    assert(c.code_has(needle), label);
}

@test
fn affine_guard_removes_check() {
    // the exact `k + 1` value proven by the dominating guard re-proves at the access
    let SRC: str = "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..64 {\n        v.push(i);\n    }\n    let k = argv.len() + 20;\n    let mut s = 0;\n    if k + 1 < v.len() {\n        s += v[k + 1];\n    }\n    return s - 22;\n}\n";
    expect_c_user_absent("affine guard removes the body check", SRC, "__sc_bounds(");
    h::expect_exit("affine guard behavior", SRC, 0);
}

@test
fn coalescing_groups_adjacent_checks() {
    // three adjacent accesses collapse to ONE group check at the first site
    let SRC: str = "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..64 {\n        v.push(i);\n    }\n    let j = argv.len() + 40;\n    let mut s = 0;\n    s += v[j] + v[j + 1] + v[j + 2];\n    return s - 126;\n}\n";
    expect_c_user_present("group check emitted", SRC, "__sc_bounds_group(");
    expect_c_user_absent("no per-element checks in the group", SRC, "__sc_bounds(");
    h::expect_exit("group behavior", SRC, 0);
}

@test
fn coalescing_panic_parity() {
    // a failing group panics (earlier site, same panic class); disabled BCE panics too
    let SRC: str = "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..64 {\n        v.push(i);\n    }\n    let j = argv.len() + 61; // == 62: j + 2 is out of bounds\n    let mut s = 0;\n    s += v[j] + v[j + 1] + v[j + 2];\n    return s;\n}\n";
    expect_panics("group check panics", SRC);
    // the fork-per-test runner isolates this env change; the spawned build inherits it
    let _ = unsafe shim::sc_setenv("SC_BCE".ptr() as *const char, "0".ptr() as *const char);
    expect_panics("disabled pass panics identically", SRC);
}

@test
fn coalescing_blocked_by_mutation() {
    // a growth call between the accesses invalidates the group: per-element checks stay
    let SRC: str = "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..64 {\n        v.push(i);\n    }\n    let j = argv.len() + 40;\n    let mut s = 0;\n    s += v[j];\n    v.push(64);\n    s += v[j + 1];\n    return s - 83;\n}\n";
    expect_c_user_absent("no group across a mutating call", SRC, "__sc_bounds_group(");
    expect_c_user_present("per-element checks retained", SRC, "__sc_bounds(");
    h::expect_exit("blocked group behavior", SRC, 0);
}

// ---- §13.3 verifier def-chain rules: safe accesses address through their checks ----------------

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

@test
fn verifier_rejects_unchecked_projection() {
    let p = typed_package("pub fn f(v: &Vector<i32>, i: usize) i32 {\n    return v[i];\n}\n");
    let node = find_fn(&p, "f");
    assert(node != NODE_NONE, "f found");
    let u = (p.modules.len() - 1) as ModuleId;
    let mut lw = irl::Lowerer::new(&p, u, node);
    assert(lw.lower_fn(node), "body lowers");
    let tp = unsafe (&*p.module_ast_const(u)).type_pool.len();
    assert_eq(irv::verify(&lw.body, tp, &p), "");
    // corrupt: route the projection operand through the raw `i` parameter, not the check result
    let mut hit = false;
    for j in 0..lw.body.projections.len() {
        if lw.body.projections.at(j).kind != ir::PJ_INDEX_OP {
            continue;
        }
        let old = *lw.body.operands.at(lw.body.projections.at(j).data as usize);
        let il = lw.body.returns + 1; // locals: return slots, then params v, i
        lw.body.places.push(ir::Place { base: il, proj_start: 0, proj_len: 0, ty: old.ty });
        lw.body.operands.push(ir::Operand { kind: ir::OP_COPY, data: lw.body.places.len() as u32 - 1, ty: old.ty });
        lw.body.projections[j].data = lw.body.operands.len() as u32 - 1;
        hit = true;
    }
    assert(hit, "an indexed projection exists");
    assert_eq(irv::verify(&lw.body, tp, &p), "index-not-checked");
}

@test
fn verifier_rejects_unvalidated_slice_end() {
    let p = typed_package(
        "pub fn g(v: &Vector<i32>, a2: usize, b2: usize) usize {\n    let t: []i32 = v[a2..b2];\n    return t.len();\n}\n",
    );
    let node = find_fn(&p, "g");
    assert(node != NODE_NONE, "g found");
    let u = (p.modules.len() - 1) as ModuleId;
    let mut lw = irl::Lowerer::new(&p, u, node);
    assert(lw.lower_fn(node), "body lowers");
    let tp = unsafe (&*p.module_ast_const(u)).type_pool.len();
    assert_eq(irv::verify(&lw.body, tp, &p), "");
    // corrupt: hand RV_SLICE the raw `b2` parameter instead of the validated exclusive end
    let mut hit = false;
    for j in 0..lw.body.rvalues.len() {
        if lw.body.rvalues.at(j).kind != ir::RV_SLICE {
            continue;
        }
        let old = *lw.body.operands.at(lw.body.rvalues.at(j).item.node as usize);
        let bl = lw.body.returns + 2; // locals: return slots, then params v, a2, b2
        lw.body.places.push(ir::Place { base: bl, proj_start: 0, proj_len: 0, ty: old.ty });
        lw.body.operands.push(ir::Operand { kind: ir::OP_COPY, data: lw.body.places.len() as u32 - 1, ty: old.ty });
        lw.body.rvalues[j].item.node = lw.body.operands.len() as u32 - 1;
        hit = true;
    }
    assert(hit, "a slice rvalue exists");
    assert_eq(irv::verify(&lw.body, tp, &p), "slice-end-not-validated");
}

// ---- Core IR inliner + panic-guard folding -----------------------------------------------------

@test
fn inline_fold_canonical_at_loop() {
    // the inlined Vector::at guard folds against the cached loop bound: no panic branch survives
    // in the user TU (the standalone at() instance lives in the owner TU, not here)
    expect_c_user_absent(
        "canonical at() loop folds its guard",
        "fn sum(v: &Vector<i32>) i32 {\n    let mut t = 0;\n    for i in 0..v.len() {\n        t += *v.at(i);\n    }\n    return t;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    v.push(2);\n    return sum(&v) - 3 - (argv.len() as i32 - 1);\n}\n",
        "Vector::at: index out of bounds",
    );
}

@test
fn inline_unproven_at_keeps_guard() {
    // an unproven index keeps the inlined guard, with the callee's exact panic message
    let c = h::compile_c_user(
        "fn get(v: &Vector<i32>, k: usize) i32 {\n    return *v.at(k);\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(7);\n    return get(&v, argv.len() - 1) - 7;\n}\n",
    );
    assert(c.ok(), "unproven at() compiles");
    assert(c.code_has("Vector::at: index out of bounds"), "inlined guard keeps the panic message");
}

@test
fn inline_fold_blocked_by_mutation() {
    // a mutating call between the bound and the access keeps the inlined guard
    let c = h::compile_c_user(
        "fn poke(v: &mut Vector<i32>) i32 {\n    let mut t = 0;\n    for i in 0..v.len() {\n        v.push(0);\n        t += *v.at(i);\n    }\n    return t;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    return poke(&mut v) - 1;\n}\n",
    );
    assert(c.ok(), "mutating loop compiles");
    assert(c.code_has("Vector::at: index out of bounds"), "mutation keeps the guard");
}

@test
fn inline_behavior_parity() {
    // identical results with the inliner off, the fold rule off, and both off
    let SRC: str = "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for k in 0..10 {\n        v.push(k);\n    }\n    let mut t = 0;\n    for i in 0..v.len() {\n        t += *v.at(i);\n    }\n    let mut s = String::new();\n    s.push_str(\"ab\");\n    t += s.len() as i32;\n    return t - 47 - (argv.len() as i32 - 1);\n}\n";
    h::expect_exit("inline+fold on", SRC, 0);
    let _ = unsafe shim::sc_setenv("SC_BCE_DISABLE".ptr() as *const char, "fold".ptr() as *const char);
    h::expect_exit("fold off", SRC, 0);
    let _ = unsafe shim::sc_setenv("SC_INLINE".ptr() as *const char, "0".ptr() as *const char);
    h::expect_exit("inline off, fold off", SRC, 0);
    let _ = unsafe shim::sc_setenv("SC_BCE_DISABLE".ptr() as *const char, "".ptr() as *const char);
    h::expect_exit("inline off", SRC, 0);
}

@test
fn inline_panic_site_parity() {
    // an out-of-range at() panics under every switch combination
    let BAD: str = "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    return *v.at(argv.len() + 5);\n}\n";
    expect_panics("oob panics (inline+fold on)", BAD);
    let _ = unsafe shim::sc_setenv("SC_BCE_DISABLE".ptr() as *const char, "fold".ptr() as *const char);
    expect_panics("oob panics (fold off)", BAD);
    let _ = unsafe shim::sc_setenv("SC_INLINE".ptr() as *const char, "0".ptr() as *const char);
    expect_panics("oob panics (both off)", BAD);
}

@test
fn inline_omitted_aggregate_members() {
    // spelled-count array literals carry IR_NONE oper-pool entries: the splice must keep them
    h::expect_exit(
        "inlined callee with omitted aggregate members",
        "fn mk(x: i32) [i32; 4] {\n    let a: [i32; 4] = [[0] = x];\n    return a;\n}\nfn main(argv: Vector<str>) i32 {\n    let a = mk(argv.len() as i32);\n    return a[0] + a[1] + a[2] + a[3] - 1;\n}\n",
        0,
    );
}

@test
fn inline_deterministic_emission() {
    // two in-process emissions of the same snippet are byte-identical
    let src: str = "fn sum(v: &Vector<i32>) i32 {\n    let mut t = 0;\n    for i in 0..v.len() {\n        t += *v.at(i);\n    }\n    return t;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(4);\n    return sum(&v) - 4 - (argv.len() as i32 - 1);\n}\n";
    let a = h::compile_c_user(src);
    let b2 = h::compile_c_user(src);
    assert(a.ok(), "first emission ok");
    assert(b2.ok(), "second emission ok");
    assert(str::from_cstr(a.code) == str::from_cstr(b2.code), "byte-identical emissions");
}

// ---- signature-based call transparency ---------------------------------------------------------

@test
fn sig_fact_survives_readonly_call() {
    // a shared-reference helper between the guard and the access cannot resize the vector, so the
    // guard fact survives and the check proves away
    expect_c_user_absent(
        "read-only call keeps the guard fact",
        "@c.noinline\nfn peek(v: &Vector<i32>) i32 {\n    if v.len() > 2 {\n        return *v.at(0);\n    }\n    return 0;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..8 {\n        v.push(i);\n    }\n    let mut s = 0;\n    let k = argv.len() + 3;\n    if k < v.len() {\n        s += peek(&v);\n        s += v[k];\n    }\n    return s - 4 - (argv.len() as i32 - 1);\n}\n",
        "__sc_bounds(",
    );
}

@test
fn sig_mut_call_kills() {
    // a &mut argument names the vector: its facts die at the call and the check stays
    let c = h::compile_c_user(
        "@c.noinline\nfn grow(v: &mut Vector<i32>) {\n    v.push(9);\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    v.push(2);\n    let k = argv.len() - 1;\n    if k < v.len() {\n        grow(&mut v);\n        return v[k] - 1;\n    }\n    return 1;\n}\n",
    );
    assert(c.ok(), "mut-call snippet compiles");
    assert(c.code_has("__sc_bounds("), "a &mut call kills the guard fact");
}

@test
fn sig_raw_arg_kills() {
    // a raw-pointer argument is unclassifiable: the call keeps the old kill-everything behavior
    let c = h::compile_c_user(
        "@c.noinline\nfn taker(p: *const i32) i32 {\n    return unsafe *p;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    v.push(2);\n    let q = v.as_ptr();\n    let k = argv.len() - 1;\n    if k < v.len() {\n        let t = taker(q);\n        return v[k] - t;\n    }\n    return 1;\n}\n",
    );
    assert(c.ok(), "raw-arg snippet compiles");
    assert(c.code_has("__sc_bounds("), "a raw-pointer argument keeps the check");
}

@test
fn sig_static_kills() {
    // a static collection is reachable from any callee: transparency never keeps its facts
    let c = h::compile_c_user(
        "static mut G: str = \"abcd\";\n@c.noinline\nfn shrink() {\n    unsafe {\n        G = \"a\";\n    }\n}\nfn main(argv: Vector<str>) i32 {\n    let k = argv.len() + 1;\n    if k < unsafe G.len() {\n        shrink();\n        return unsafe G[k] as i32 - 99;\n    }\n    return 1;\n}\n",
    );
    assert(c.ok(), "static snippet compiles");
    assert(c.code_has("__sc_bounds("), "a static collection keeps its check across calls");
}

@test
fn sig_escaped_ref_kills() {
    // a &mut stored into memory escapes: later calls kill the escaped root even when their own
    // arguments are harmless
    let c = h::compile_c_user(
        "struct Slot<'a> {\n    pub m: &'a mut Vector<i32>,\n}\n@c.noinline\nfn touch() i32 {\n    return 1;\n}\n@c.noinline\nfn use_slot(s: &Slot) i32 {\n    return s.m.len() as i32;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    v.push(2);\n    let k = argv.len() - 1;\n    let mut out = 0;\n    {\n        let s = Slot { m: &mut v };\n        out += use_slot(&s);\n    }\n    if k < v.len() {\n        let t = touch();\n        return v[k] + out - t - 2;\n    }\n    return 1;\n}\n",
    );
    assert(c.ok(), "escaped-ref snippet compiles");
    assert(c.code_has("__sc_bounds("), "an escaped &mut keeps the check across later calls");
}

@test
fn sig_disable_and_inline_parity() {
    // identical behavior with transparency off and with the inliner off; the OOB path panics the
    // same way in every mode
    let SRC: str = "@c.noinline\nfn peek(v: &Vector<i32>) i32 {\n    if v.len() > 2 {\n        return *v.at(0);\n    }\n    return 0;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..8 {\n        v.push(i);\n    }\n    let mut s = 0;\n    let k = argv.len() + 3;\n    if k < v.len() {\n        s += peek(&v);\n        s += v[k];\n    }\n    return s - 4 - (argv.len() as i32 - 1);\n}\n";
    let BAD: str = "@c.noinline\nfn peek(v: &Vector<i32>) i32 {\n    return v.len() as i32;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    let k = argv.len() + 4;\n    let _ = peek(&v);\n    return v[k];\n}\n";
    h::expect_exit("sig on", SRC, 0);
    expect_panics("sig on, oob panics", BAD);
    let _ = unsafe shim::sc_setenv("SC_BCE_DISABLE".ptr() as *const char, "sig".ptr() as *const char);
    h::expect_exit("sig off", SRC, 0);
    expect_panics("sig off, oob panics", BAD);
    let _ = unsafe shim::sc_setenv("SC_INLINE".ptr() as *const char, "0".ptr() as *const char);
    h::expect_exit("sig off, inline off", SRC, 0);
    let _ = unsafe shim::sc_setenv("SC_BCE_DISABLE".ptr() as *const char, "".ptr() as *const char);
    h::expect_exit("sig on, inline off", SRC, 0);
    expect_panics("sig on inline off, oob panics", BAD);
    let _ = unsafe shim::sc_setenv("SC_INLINE".ptr() as *const char, "".ptr() as *const char);
}
