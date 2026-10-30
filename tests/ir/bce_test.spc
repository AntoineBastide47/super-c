// Bounds-check normalization and elimination:
// safety cases panic at the semantic operation, removal cases inspect the generated C for the
// explicit check calls, and the verifier rejects malformed check operations. Dynamic values are
// derived from argv so compile-time evaluation cannot fold the failing access away.
import tests::harness as h;
import tests::cli_harness as cli;
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

// How many times `needle` occurs in `code`.
const fn occurrences(code: str, needle: str) usize {
    let mut n: usize = 0;
    let mut rest = code;
    loop {
        let at = rest.find(needle);
        if at < 0 {
            return n;
        }
        n += 1;
        rest = rest.slice(at as usize + needle.len(), rest.len());
    }
}

// How many checks of the kind `kind` names a snippet's C spells; any other `kind` counts as itself. A
// structural view's check calls the runtime helper `kind` names; a std container's check is the panic
// guard of its `index` method, inlined (its message, counted once per panic site by the literal's
// first spelling: a `str` literal spells its text twice) or called. "__sc_bounds(": an element check;
// "__sc_bounds_group(": a group, a coalesced check or a widened guard (`__sc_fits`), whose one panic
// message is the group's, not an element check's; "__sc_range(": a range check.
const fn check_count(code: str, kind: str) usize {
    if kind == "__sc_bounds_group(" {
        return occurrences(code, kind) + occurrences(code, "__sc_fits(");
    }
    if kind == "__sc_range(" {
        return occurrences(code, kind) + occurrences(code, "[a..b]: range out of bounds\",") + occurrences(
            code,
            "__index_range(",
        );
    }
    if kind == "__sc_bounds(" {
        let n = occurrences(code, kind) + occurrences(code, "[i]: index out of bounds\",") + occurrences(
            code,
            "__index(",
        );
        let g = occurrences(code, "__sc_fits(");
        if n < g {
            return 0;
        }
        return n - g;
    }
    return occurrences(code, kind);
}

// Does the snippet's C spell a check of kind `kind` (`check_count`)?
const fn spelled(c: &h::CompiledC, kind: str) bool {
    return c.code != null && check_count(unsafe str::from_cstr(c.code), kind) != 0;
}

// The snippet's C function `def` opens spells a check of kind `kind` (`check_count`) when `present`, and
// none otherwise. A program's own container keeps its `index` method, guard included, in the snippet's
// unit: only the function under test counts.
fn expect_in_fn(label: str, src: str, def: str, kind: str, present: bool) {
    let c = h::compile_c_user(src);
    assert(c.ok(), label);
    let body = h::c_fn(unsafe str::from_cstr(c.code), def);
    if check_count(body, kind) != 0 != present {
        eprintln("{}", body);
    }
    assert(check_count(body, kind) != 0 == present, label);
}

fn expect_c_user_absent(label: str, src: str, needle: str) {
    let c = h::compile_c_user(src);
    assert(c.ok(), label);
    if spelled(&c, needle) {
        eprintln("{}", unsafe str::from_cstr(c.code));
    }
    assert(!spelled(&c, needle), label);
}

// Program `s` as a batch module: its one `fn main(argv: Vector<str>) i32` renamed `case_main`, public
// and `@noinline`, so it stays a function of its own.
fn case_module(s: str) String {
    let head = "fn main(argv: Vector<str>) i32 {\n";
    let mut at: isize = -1;
    let mut i: usize = 0;
    while i + head.len() <= s.len() {
        if (i == 0 || s.byte_at(i - 1) == b'\n') && s.slice(i, i + head.len()) == head {
            assert(at < 0, "one main per program");
            at = i as isize;
        }
        i += 1;
    }
    assert(at >= 0, "the program has `fn main(argv: Vector<str>) i32`");
    let mut m = String::from_str(s.slice(0, at as usize));
    m.push_str("@noinline\npub fn case_main(argv: Vector<str>) i32 {\n");
    m.push_str(s.slice(at as usize + head.len(), s.len()));
    return m;
}

// The root over modules `case_0` .. `case_<n-1>`: it runs the `case_main` that `BATCH_CASE` names with
// its own arguments.
fn case_root(n: usize) String {
    let mut root = String::from_str("import stdlib;\n");
    let mut arms = String::new();
    for k in 0..n {
        root.format_into("import case_{};\n", k);
        arms.format_into("    if k == {} {{\n        return case_{}::case_main(argv);\n    }}\n", k, k);
    }
    root.format_into(
        "fn main(argv: Vector<str>) i32 {{\n    let e = stdlib::getenv(\"BATCH_CASE\");\n    let k = if e == null {{\n        -1\n    }} else {{\n        unsafe str::from_cstr(e).parse_i64().unwrap_or(-1)\n    }};\n{}    return 99;\n}}\n",
        arms.as_str(),
    );
    return root;
}

fn safety_element_checks(b: &mut h::ExitBatch) {
    // Element index equal to the length.
    b.add_trap(
        "index == len panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 2] = [1, 2];\n    let s: []i32 = a[0..2];\n    let i = argv.len() + 1; // == 2 at runtime\n    return s[i];\n}\n",
        "index out of bounds",
    );
    // Empty view element access.
    b.add_trap(
        "empty view access panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 2] = [1, 2];\n    let s: []i32 = a[0..0];\n    let i = argv.len() - 1; // == 0\n    return s[i];\n}\n",
        "index out of bounds",
    );
    // A valid dynamic access still works.
    b.add(
        "valid dynamic access",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 3] = [7, 8, 9];\n    let s: []i32 = a[0..3];\n    let i = argv.len() - 1; // == 0\n    return s[i] - 7;\n}\n",
        0,
    );
}

fn safety_range_checks(b: &mut h::ExitBatch) {
    // Exclusive range with start > end.
    b.add_trap(
        "start > end panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let lo = argv.len() + 2; // == 3\n    let t: []i32 = s[lo..1];\n    return t.len() as i32;\n}\n",
        "range out of bounds",
    );
    // Exclusive range with end > len.
    b.add_trap(
        "end > len panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let hi = argv.len() + 4; // == 5\n    let t: []i32 = s[0..hi];\n    return t.len() as i32;\n}\n",
        "range out of bounds",
    );
    // Inclusive range with end == len.
    b.add_trap(
        "inclusive end == len panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let hi = argv.len() + 3; // == 4\n    let t: []i32 = s[0..=hi];\n    return t.len() as i32;\n}\n",
        "range out of bounds",
    );
    // inclusive range with end == usize::MAX: `end + 1` must NOT wrap past the check.
    b.add_trap(
        "inclusive end == usize::MAX panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let hi = 0xFFFFFFFFFFFFFFFFu64 as usize - 1 + argv.len(); // == usize::MAX\n    let t: []i32 = s[0..=hi];\n    return t.len() as i32;\n}\n",
        "range out of bounds",
    );
    // A range whose length subtraction would underflow without the ordered check.
    b.add_trap(
        "underflowing range panics",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let lo = argv.len() + 3; // == 4\n    let t: []i32 = s[lo..2];\n    return t.len() as i32;\n}\n",
        "range out of bounds",
    );
    // Valid inclusive range still slices.
    b.add(
        "valid inclusive range",
        "fn main(argv: Vector<str>) i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let hi = argv.len() + 1; // == 2\n    let t: []i32 = s[0..=hi];\n    return t.len() as i32 - 3;\n}\n",
        0,
    );
}

fn safety_mutation_and_zst(b: &mut h::ExitBatch) {
    // A vector mutation between the proof and the access keeps the (passing) check honest.
    b.add(
        "mutation between proof and access",
        "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(5);\n    let n = v.len() - argv.len() + 1; // == 1\n    v.push(6);\n    return v[n] - 6;\n}\n",
        0,
    );
    // Zero-sized elements use logical lengths: in-range works, out-of-range panics.
    b.add(
        "zst logical length in range",
        "struct Z {}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<Z>::new();\n    v.push(Z {});\n    v.push(Z {});\n    let i = argv.len(); // == 1\n    let _ = v[i];\n    return v.len() as i32 - 2;\n}\n",
        0,
    );
    b.add_trap(
        "zst logical length out of range panics",
        "struct Z {}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<Z>::new();\n    v.push(Z {});\n    let i = argv.len() + 1; // == 2\n    let _ = v[i];\n    return 0;\n}\n",
        "index out of bounds",
    );
}

@test
fn removal_canonical_loops() {
    // The canonical indexed `for` loop body carries no element check.
    expect_c_user_absent(
        "for-in-slice loop has no bounds call",
        "fn sum(s: []i32) i32 {\n    let mut t = 0;\n    for v in s { t += v; }\n    return t;\n}\n",
        "__sc_bounds(",
    );
    // `for i in 0..s.len()` with a same-index access proves through the guard.
    expect_c_user_absent(
        "indexed range loop has no bounds call",
        "fn sum(s: []i32) i32 {\n    let mut t = 0;\n    for i in 0..s.len() { t += s[i]; }\n    return t;\n}\n",
        "__sc_bounds(",
    );
    // A dominating guard proves the guarded access.
    expect_c_user_absent(
        "dominating guard proves access",
        "fn get(s: []i32, i: usize) i32 {\n    if i < s.len() {\n        return s[i];\n    }\n    return 0;\n}\n",
        "__sc_bounds(",
    );
    // The full-view range check is proved away.
    expect_c_user_absent(
        "full-view slice has no range call",
        "fn all(s: []i32) []i32 { return s[0..s.len()]; }\n",
        "__sc_range(",
    );
    // A byte, cast up, indexes 256 elements in bounds.
    expect_in_fn(
        "a byte index into 256 elements",
        "pub struct T { pub c: Array<u8, 256> }\n@noinline\npub fn at(t: &T, b: u8) u8 {\n    return t.c[b as usize];\n}\n",
        "at(",
        "__sc_bounds(",
        false,
    );
}

@test
fn removal_keeps_unproved() {
    // An arbitrary dynamic index keeps exactly its check.
    expect_c_user_present(
        "unproved index keeps its check",
        "fn get(s: []i32, i: usize) i32 { return s[i]; }\n",
        "__sc_bounds(",
    );
    // A mutation between the guard and the access keeps the check.
    expect_c_user_present(
        "mutating call between guard and access keeps the check",
        "fn get(v: &mut Vector<i32>, i: usize) i32 {\n    if i < v.len() {\n        v.push(0);\n        return (*v)[i];\n    }\n    return 0;\n}\n",
        "__sc_bounds(",
    );
    // an unclassifiable call (a fn value) between guard and access keeps the check of a view it can
    // reach (behind a reference); a view in the frame's own storage, whose address never escaped,
    // is out of the callee's reach.
    {
        let c = h::compile_c_user(
            "struct W<'a> { pub s: []'a i32 }\nfn poke() {}\nfn get(w: &mut W, i: usize) i32 {\n    if i < w.s.len() {\n        let f: fn() = poke;\n        f();\n        return w.s[i];\n    }\n    return 0;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(3);\n    let mut w = W { s: v[0..1] };\n    return get(&mut w, argv.len() - 1) - 3;\n}\n",
        );
        assert(c.ok(), "fn-value call snippet compiles");
        assert(spelled(&c, "__sc_bounds("), "a fn-value call between guard and access keeps the check");
        expect_c_user_absent(
            "a fn-value call cannot reach a local view",
            "fn poke() {}\nfn get(s: []i32, i: usize) i32 {\n    if i < s.len() {\n        let f: fn() = poke;\n        f();\n        return s[i];\n    }\n    return 0;\n}\n",
            "__sc_bounds(",
        );
    }
    // A dynamic range keeps its range check.
    expect_c_user_present(
        "dynamic range keeps its check",
        "fn cut(s: []i32, a: usize, b: usize) []i32 { return s[a..b]; }\n",
        "__sc_range(",
    );
}

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
            name_off: 0,
            name_len: 0,
            dkind: ir::LK_NONE,
        },
    );
    b.places.push(ir::Place { base: l, proj_start: 0, proj_len: 0, ty: ut });
    b.constants.push(
        ir::Constant { kind: ir::CK_INT, ty: ut, val: 0, raw: tok_span(), item: DefId { module: 0, node: NODE_NONE } },
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
    b.statements.push(ir::Statement { kind: ir::ST_ASSIGN, place: 0, rvalue: 0, a: 0, span: tok_span() });
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
    // Wrong operand count.
    let bad = check_body(1);
    assert_eq(irv::verify(&bad, 4096, null), "check-operand-count");
    // Operand range past the pool.
    let mut bad2 = check_body(2);
    bad2.oper_pool.truncate(1);
    assert_eq(irv::verify(&bad2, 4096, null), "check-operand-out-of-range");
    // A well-formed check verifies.
    let good = check_body(2);
    assert_eq(irv::verify(&good, 4096, null), "");
}

fn expect_c_user_present(label: str, src: str, needle: str) {
    let c = h::compile_c_user(src);
    assert(c.ok(), label);
    if !spelled(&c, needle) {
        eprintln("{}", unsafe str::from_cstr(c.code));
    }
    assert(spelled(&c, needle), label);
}

fn affine_guard_removes_check(b: &mut h::ExitBatch) {
    // the exact `k + 1` value proven by the dominating guard re-proves at the access.
    let SRC: str = "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..64 {\n        v.push(i);\n    }\n    let k = argv.len() + 20;\n    let mut s = 0;\n    if k + 1 < v.len() {\n        s += v[k + 1];\n    }\n    return s - 22;\n}\n";
    expect_c_user_absent("affine guard removes the body check", SRC, "__sc_bounds(");
    b.add("affine guard behavior", SRC, 0);
}

fn coalescing_groups_adjacent_checks(b: &mut h::ExitBatch) {
    // Three adjacent accesses collapse to ONE group check at the first site.
    let SRC: str = "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..64 {\n        v.push(i);\n    }\n    let j = argv.len() + 40;\n    let mut s = 0;\n    s += v[j] + v[j + 1] + v[j + 2];\n    return s - 126;\n}\n";
    expect_c_user_present("group check emitted", SRC, "__sc_bounds_group(");
    expect_c_user_absent("no per-element checks in the group", SRC, "__sc_bounds(");
    b.add("group behavior", SRC, 0);
}

@test
fn coalescing_panic_parity() {
    // A failing group panics (earlier site, same panic class); disabled BCE panics too.
    let SRC: str = "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..64 {\n        v.push(i);\n    }\n    let j = argv.len() + 61; // == 62: j + 2 is out of bounds\n    let mut s = 0;\n    s += v[j] + v[j + 1] + v[j + 2];\n    return s;\n}\n";
    h::expect_trap("group check panics", SRC, "index out of bounds");
    // The guard restores the variable when the test ends; the spawned build inherits it.
    let _env2 = cli::set_env("SC_BCE", "0");
    h::expect_trap("disabled pass panics identically", SRC, "index out of bounds");
}

// A program's own container: its `index` checks its own length field, as std's do.
const BUF: str = M"(struct Buf {
    pub ptr: *const i32,
    pub n: usize,
}
extend Buf as Index<i32, []i32> {
    pub fn index(self: &Self, i: usize) &i32 {
        if i >= self.n {
            panic("Buf[i]: index out of bounds");
        }
        return &unsafe self.ptr[i];
    }
    pub fn index_range(self: &Self, r: Range<usize>) []i32 {
        return unsafe Slice::<i32> { ptr: self.ptr + r.start, len: r.end - r.start };
    }
}
)";

@test
fn guard_widening_groups_any_container() {
    // Three guards over one root and one length, with pure code between: one group test at the first,
    // and the member guards fold, for std's Vector and for the program's own container alike.
    let tri_user = format("{}fn tri(b: &Buf, j: usize) i32 {{\n    return b[j] + b[j + 1] + b[j + 2];\n}}\n", BUF);
    expect_in_fn("a user container's guards widen", &tri_user, "int32_t tri(", "__sc_bounds_group(", true);
    expect_in_fn("no member guard of a user container", &tri_user, "int32_t tri(", "__sc_bounds(", false);
    let tri_vec = "fn tri(v: &Vector<i32>, j: usize) i32 {\n    return v[j] + v[j + 1] + v[j + 2];\n}\n";
    expect_c_user_present("a Vector's guards widen", tri_vec, "__sc_bounds_group(");
    expect_c_user_absent("no member guard of a Vector", tri_vec, "__sc_bounds(");
    // A loop bounded by the container's own length field proves its guard.
    let sum_user = format(
        "{}fn sum(b: &Buf) i32 {{\n    let mut s = 0;\n    for i in 0..b.n {{\n        s += b[i];\n    }}\n    return s;\n}}\n",
        BUF,
    );
    expect_in_fn("a user container's loop guard folds", &sum_user, "int32_t sum(", "__sc_bounds(", false);
}

@test
fn guard_widening_keeps_its_panic() {
    // The widened test fails with the guards' own panic, and only where a member would.
    let SRC = format(
        "{}fn tri(b: &Buf, j: usize) i32 {{\n    return b[j] + b[j + 1] + b[j + 2];\n}}\nfn main(argv: Vector<str>) i32 {{\n    let mut v = Vector::<i32>::new();\n    for i in 0..64 {{\n        v.push(i);\n    }}\n    let b = Buf {{ ptr: v.as_ptr(), n: v.len() }};\n    return tri(&b, argv.len() + 60) - 186;\n}}\n",
        BUF,
    );
    h::expect_exit("the last member in range", &SRC, 0);
    let BAD = SRC.replace("argv.len() + 60", "argv.len() + 61");
    h::expect_trap("the last member out of range", &BAD, "panic: Buf[i]: index out of bounds");
}

@test
fn guard_widening_stops_at_effects_and_other_panics() {
    // A store between the guards: each keeps its own guard.
    let store = format(
        "{}fn f(b: &Buf, j: usize, out: &mut i32) i32 {{\n    let x = b[j];\n    *out = x;\n    return x + b[j + 1];\n}}\n",
        BUF,
    );
    expect_in_fn("no group across a store", &store, "int32_t f(", "__sc_bounds_group(", false);
    expect_in_fn("each guard stays across a store", &store, "int32_t f(", "__sc_bounds(", true);
    // Guards written by hand widen when they panic alike, and not when the panics differ.
    let same = "fn g(s: []i32, j: usize) i32 {\n    if j >= s.len() {\n        panic(\"out\");\n    }\n    if j + 1 >= s.len() {\n        panic(\"out\");\n    }\n    return 0;\n}\n";
    expect_c_user_present("one panic: the guards widen", same, "__sc_fits(");
    let differ = "fn g(s: []i32, j: usize) i32 {\n    if j >= s.len() {\n        panic(\"first\");\n    }\n    if j + 1 >= s.len() {\n        panic(\"second\");\n    }\n    return 0;\n}\n";
    expect_c_user_absent("two panics: no widening", differ, "__sc_fits(");
}

fn coalescing_blocked_by_mutation(b: &mut h::ExitBatch) {
    // A growth call between the accesses invalidates the group: per-element checks stay.
    let SRC: str = "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..64 {\n        v.push(i);\n    }\n    let j = argv.len() + 40;\n    let mut s = 0;\n    s += v[j];\n    v.push(64);\n    s += v[j + 1];\n    return s - 83;\n}\n";
    expect_c_user_absent("no group across a mutating call", SRC, "__sc_bounds_group(");
    expect_c_user_present("per-element checks retained", SRC, "__sc_bounds(");
    b.add("blocked group behavior", SRC, 0);
}

fn t_resolve(p: &mut loader::Package, i: usize) bool {
    let pkg = p as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut r = res::Resolver::new(
        unsafe &mut *((&mut m.ast) as *mut Ast),
        unsafe str::from_raw(src as *const u8, len),
        pkg,
    );
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
    let mut t = tc::TypeChecker::new(&mut m.ast, unsafe str::from_raw(src as *const u8, len), pkg);
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
        let sp = a.at_const(a.ext(nid).function.name).as_data.name.text;
        if src.slice(sp.start as usize, sp.end as usize) == name {
            return nid;
        }
    }
    return NODE_NONE;
}

@test
fn verifier_rejects_unchecked_projection() {
    let p = typed_package("pub fn f(v: Simd<i32, 4>, i: usize) i32 {\n    return v[i];\n}\n");
    let node = find_fn(&p, "f");
    assert(node != NODE_NONE, "f found");
    let u = (p.modules.len() - 1) as ModuleId;
    let mut lw = irl::Lowerer::new(&p, u, node);
    assert(lw.lower_fn(node), "body lowers");
    let tp = unsafe (&*p.module_ast_const(u)).type_bound();
    assert_eq(irv::verify(&lw.body, tp, &p), "");
    // corrupt: route the projection operand through the raw `i` parameter, not the check result.
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
        "pub fn g(v: [i32; 4], a2: usize, b2: usize) usize {\n    let t: []i32 = unsafe v[a2..b2];\n    return t.len();\n}\n",
    );
    let node = find_fn(&p, "g");
    assert(node != NODE_NONE, "g found");
    let u = (p.modules.len() - 1) as ModuleId;
    let mut lw = irl::Lowerer::new(&p, u, node);
    assert(lw.lower_fn(node), "body lowers");
    let tp = unsafe (&*p.module_ast_const(u)).type_bound();
    assert_eq(irv::verify(&lw.body, tp, &p), "");
    // corrupt: hand RV_SLICE the raw `b2` parameter instead of the validated exclusive end.
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

@test
fn inline_fold_canonical_at_loop() {
    // The inlined Vector::at guard folds against the cached loop bound: no panic branch survives
    // in the user TU (the standalone at() instance lives in the owner TU, not here).
    expect_c_user_absent(
        "canonical at() loop folds its guard",
        "fn sum(v: &Vector<i32>) i32 {\n    let mut t = 0;\n    for i in 0..v.len() {\n        t += *v.at(i);\n    }\n    return t;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    v.push(2);\n    return sum(&v) - 3 - (argv.len() as i32 - 1);\n}\n",
        "Vector::at: index out of bounds",
    );
}

@test
fn inline_unproven_at_keeps_guard() {
    // An unproven index keeps the inlined guard, with the callee's exact panic message.
    let c = h::compile_c_user(
        "fn get(v: &Vector<i32>, k: usize) i32 {\n    return *v.at(k);\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(7);\n    return get(&v, argv.len() - 1) - 7;\n}\n",
    );
    assert(c.ok(), "unproven at() compiles");
    assert(c.code_has("Vector::at: index out of bounds"), "inlined guard keeps the panic message");
}

@test
fn inline_fold_blocked_by_mutation() {
    // A mutating call between the bound and the access keeps the inlined guard.
    let c = h::compile_c_user(
        "fn poke(v: &mut Vector<i32>) i32 {\n    let mut t = 0;\n    for i in 0..v.len() {\n        v.push(0);\n        t += *v.at(i);\n    }\n    return t;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    return poke(&mut v) - 1;\n}\n",
    );
    assert(c.ok(), "mutating loop compiles");
    assert(c.code_has("Vector::at: index out of bounds"), "mutation keeps the guard");
}

@test
fn inline_behavior_parity() {
    // Identical results with the inliner off, the fold rule off, and both off.
    let SRC: str = "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for k in 0..10 {\n        v.push(k);\n    }\n    let mut t = 0;\n    for i in 0..v.len() {\n        t += *v.at(i);\n    }\n    let mut s = String::new();\n    s.push_str(\"ab\");\n    t += s.len() as i32;\n    return t - 47 - (argv.len() as i32 - 1);\n}\n";
    h::expect_exit("inline+fold on", SRC, 0);
    let _env3 = cli::set_env("SC_BCE_DISABLE", "fold");
    h::expect_exit("fold off", SRC, 0);
    let _env4 = cli::set_env("SC_INLINE", "0");
    h::expect_exit("inline off, fold off", SRC, 0);
    let _env5 = cli::set_env("SC_BCE_DISABLE", "");
    h::expect_exit("inline off", SRC, 0);
}

@test
fn inline_panic_site_parity() {
    // An out-of-range at() panics under every switch combination.
    let BAD: str = "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    return *v.at(argv.len() + 5);\n}\n";
    h::expect_trap("oob panics (inline+fold on)", BAD, "index out of bounds");
    let _env6 = cli::set_env("SC_BCE_DISABLE", "fold");
    h::expect_trap("oob panics (fold off)", BAD, "index out of bounds");
    let _env7 = cli::set_env("SC_INLINE", "0");
    h::expect_trap("oob panics (both off)", BAD, "index out of bounds");
}

fn inline_omitted_aggregate_members(b: &mut h::ExitBatch) {
    // Spelled-count array literals carry IR_NONE oper-pool entries: the splice must keep them.
    b.add(
        "inlined callee with omitted aggregate members",
        "fn mk(x: i32) [i32; 4] {\n    let a: [i32; 4] = [[0] = x];\n    return a;\n}\nfn main(argv: Vector<str>) i32 {\n    let a = mk(argv.len() as i32);\n    return a[0] + a[1] + a[2] + a[3] - 1;\n}\n",
        0,
    );
}

@test
fn sig_fact_survives_readonly_call() {
    // A shared-reference helper between the guard and the access cannot resize the vector, so the
    // guard fact survives and the check proves away.
    expect_c_user_absent(
        "read-only call keeps the guard fact",
        "@noinline\nfn peek(v: &Vector<i32>) i32 {\n    if v.len() > 2 {\n        return *v.at(0);\n    }\n    return 0;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..8 {\n        v.push(i);\n    }\n    let mut s = 0;\n    let k = argv.len() + 3;\n    if k < v.len() {\n        s += peek(&v);\n        s += v[k];\n    }\n    return s - 4 - (argv.len() as i32 - 1);\n}\n",
        "__sc_bounds(",
    );
}

@test
fn sig_mut_call_kills() {
    // A &mut argument names the vector: its facts die at the call and the check stays.
    let c = h::compile_c_user(
        "@noinline\nfn grow(v: &mut Vector<i32>) {\n    v.push(9);\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    v.push(2);\n    let k = argv.len() - 1;\n    if k < v.len() {\n        grow(&mut v);\n        return v[k] - 1;\n    }\n    return 1;\n}\n",
    );
    assert(c.ok(), "mut-call snippet compiles");
    assert(spelled(&c, "__sc_bounds("), "a &mut call kills the guard fact");
}

@test
fn sig_raw_arg_kills() {
    // A raw-pointer argument is unclassifiable: the call writes anything the pointer reaches. A
    // pointer to the vector itself reaches its length.
    let c = h::compile_c_user(
        "@noinline\nfn taker(p: *mut Vector<i32>) i32 {\n    return unsafe (*p).len() as i32;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    v.push(2);\n    let q = &mut v as *mut Vector<i32>;\n    let k = argv.len() - 1;\n    if k < v.len() {\n        let t = taker(q);\n        return v[k] - t;\n    }\n    return 1;\n}\n",
    );
    assert(c.ok(), "raw-arg snippet compiles");
    assert(spelled(&c, "__sc_bounds("), "a raw-pointer argument keeps the check");
}

@test
fn sig_static_kills() {
    // A static collection is reachable from any callee: transparency never keeps its facts.
    let c = h::compile_c_user(
        "static mut G: str = \"abcd\";\n@noinline\nfn shrink() {\n    unsafe {\n        G = \"a\";\n    }\n}\nfn main(argv: Vector<str>) i32 {\n    let k = argv.len() + 1;\n    if k < unsafe G.len() {\n        shrink();\n        return unsafe G[k] as i32 - 99;\n    }\n    return 1;\n}\n",
    );
    assert(c.ok(), "static snippet compiles");
    assert(spelled(&c, "__sc_bounds("), "a static collection keeps its check across calls");
}

@test
fn sig_escaped_ref_kills() {
    // A &mut stored into memory escapes: later calls kill the escaped root even when their own
    // arguments are harmless.
    let c = h::compile_c_user(
        "struct Slot<'a> {\n    pub m: &'a mut Vector<i32>,\n}\n@noinline\nfn touch() i32 {\n    return 1;\n}\n@noinline\nfn use_slot(s: &Slot) i32 {\n    return s.m.len() as i32;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    v.push(2);\n    let k = argv.len() - 1;\n    let mut out = 0;\n    {\n        let s = Slot { m: &mut v };\n        out += use_slot(&s);\n    }\n    if k < v.len() {\n        let t = touch();\n        return v[k] + out - t - 2;\n    }\n    return 1;\n}\n",
    );
    assert(c.ok(), "escaped-ref snippet compiles");
    assert(spelled(&c, "__sc_bounds("), "an escaped &mut keeps the check across later calls");
}

@test
fn sig_disable_and_inline_parity() {
    // Identical behavior with transparency off and with the inliner off; the OOB path panics the
    // same way in every mode.
    let SRC: str = "@noinline\nfn peek(v: &Vector<i32>) i32 {\n    if v.len() > 2 {\n        return *v.at(0);\n    }\n    return 0;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..8 {\n        v.push(i);\n    }\n    let mut s = 0;\n    let k = argv.len() + 3;\n    if k < v.len() {\n        s += peek(&v);\n        s += v[k];\n    }\n    return s - 4 - (argv.len() as i32 - 1);\n}\n";
    let BAD: str = "@noinline\nfn peek(v: &Vector<i32>) i32 {\n    return v.len() as i32;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    let k = argv.len() + 4;\n    let _ = peek(&v);\n    return v[k];\n}\n";
    // One build per setting: both programs share it.
    let mut on = h::ExitBatch::new();
    on.add("sig on", SRC, 0);
    on.add_trap("sig on, oob panics", BAD, "index out of bounds");
    on.run();
    let _env8 = cli::set_env("SC_BCE_DISABLE", "sig");
    let mut off = h::ExitBatch::new();
    off.add("sig off", SRC, 0);
    off.add_trap("sig off, oob panics", BAD, "index out of bounds");
    off.run();
    let _env9 = cli::set_env("SC_INLINE", "0");
    h::expect_exit("sig off, inline off", SRC, 0);
    let _env10 = cli::set_env("SC_BCE_DISABLE", "");
    let mut no_inline = h::ExitBatch::new();
    no_inline.add("sig on, inline off", SRC, 0);
    no_inline.add_trap("sig on inline off, oob panics", BAD, "index out of bounds");
    no_inline.run();
    let _env11 = cli::set_env("SC_INLINE", "");
}

@test
fn asm_write_kills_bounds_facts() {
    // An assembly output that rewrites the guarded index keeps the access check.
    expect_c_user_present(
        "asm output rewrites the index",
        "fn get(s: []i32, k0: usize) i32 {\n    let mut k = k0 * 2;\n    if k < s.len() {\n        unsafe { asm(\"\" : \"=r\"(k) : \"0\"(100usize)); }\n        return s[k];\n    }\n    return 0;\n}\n",
        "__sc_bounds(",
    );
    // Assembly with a pointer to the vector and a memory clobber may write its length.
    expect_c_user_present(
        "asm writes the length through a pointer",
        "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..8 {\n        v.push(i);\n    }\n    let k = argv.len() + 3;\n    let p = &mut v as *mut Vector<i32>;\n    if k < v.len() {\n        unsafe { asm(\"\" : : \"r\"(p) : \"memory\"); }\n        return v[k];\n    }\n    return 0;\n}\n",
        "__sc_bounds(",
    );
}

@test
fn join_versions_are_path_sound() {
    // After a join, the guard on `x` says nothing about `big`, whatever branch the walk saw last.
    let SRC: str = "fn get(v: []i32, s0: usize, c: bool) i32 {\n    let big = s0 + 100;\n    let mut x = s0;\n    if c {\n        x = s0;\n    } else {\n        x = big;\n    }\n    if x < v.len() {\n        return v[big];\n    }\n    return 7;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut w = Vector::<i32>::new();\n    w.push(1);\n    w.push(2);\n    return get(w[0..2], argv.len() - 1, true);\n}\n";
    expect_c_user_present("the unrelated access keeps its check", SRC, "__sc_bounds(");
    h::expect_trap("the unrelated access panics", SRC, "index out of bounds");
    // `c || i < len` does not bound `i` on its true edge.
    expect_c_user_present(
        "an or-condition keeps the check",
        "fn get(s: []i32, i: usize, c: bool) i32 {\n    if c || i < s.len() {\n        return s[i];\n    }\n    return 0;\n}\n",
        "__sc_bounds(",
    );
    // `c && i < len` bounds `i` on its true edge.
    expect_c_user_absent(
        "an and-condition proves the access",
        "fn get(s: []i32, i: usize, c: bool) i32 {\n    if c && i < s.len() {\n        return s[i];\n    }\n    return 0;\n}\n",
        "__sc_bounds(",
    );
}

@test
fn loop_header_kills_lengths_the_loop_writes() {
    // The bound read before the loop is stale on the second iteration once the body pops.
    let SRC: str = "fn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for k in 0..argv.len() + 2 {\n        v.push(k as i32);\n    }\n    let n = v.len();\n    let mut i: usize = 0;\n    let mut x = 0;\n    while i < n {\n        x += v[i];\n        let _ = v.pop();\n        i += 1;\n    }\n    return x;\n}\n";
    expect_c_user_present("the popped vector keeps its check", SRC, "__sc_bounds(");
    h::expect_trap("the stale bound panics", SRC, "index out of bounds");
}

fn interval_facts_remove_strided_checks(b: &mut h::ExitBatch) {
    // `n = len - len % 4` is a multiple of 4 below the length and `i` steps by 4 from 0, so
    // `i + 3 < n <= len` for every access of the unrolled body.
    let SRC: str = "fn sum4(s: []i32) i32 {\n    let n = s.len() - s.len() % 4;\n    let mut t = 0;\n    let mut i: usize = 0;\n    while i < n {\n        t += s[i] + s[i + 1] + s[i + 2] + s[i + 3];\n        i += 4;\n    }\n    return t;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for k in 0..argv.len() + 9 {\n        v.push(k as i32);\n    }\n    return sum4(v[0..v.len()]) - 28;\n}\n";
    expect_c_user_absent("no element check", SRC, "__sc_bounds(");
    expect_c_user_absent("no group check", SRC, "__sc_bounds_group(");
    b.add("strided sum", SRC, 0);
}

fn interval_join_keeps_the_hull(b: &mut h::ExitBatch) {
    // `k` is 2 or 5 after the join and the length is at least 8 past the guard.
    let SRC: str = "fn hull(s: []i32, c: bool) i32 {\n    if s.len() < 8 {\n        return 0;\n    }\n    let k: usize = if c {\n        2\n    } else {\n        5\n    };\n    return s[k];\n}\nfn masked(s: []i32, k: usize) i32 {\n    if s.len() >= 8 {\n        return s[k & 7] + s[k % 8];\n    }\n    return 0;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for k in 0..8 {\n        v.push(k);\n    }\n    let s: []i32 = v[0..8];\n    return hull(s, argv.len() == 1) + masked(s, argv.len() + 8) - 4;\n}\n";
    expect_c_user_absent("hull and mask bounds prove the accesses", SRC, "__sc_bounds(");
    b.add("hull behavior", SRC, 0);
}

fn interval_widening_terminates_on_nested_loops(b: &mut h::ExitBatch) {
    // Both headers widen; the branch bounds `j < i < 64` still prove the inner access.
    let SRC: str = "fn nested(s: []i32) i32 {\n    if s.len() < 64 {\n        return 0;\n    }\n    let mut t = 0;\n    let mut i: usize = 0;\n    while i < 64 {\n        let mut j: usize = 0;\n        while j < i {\n            t += s[j];\n            j += 1;\n        }\n        i += 1;\n    }\n    return t;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for _k in 0..64 {\n        v.push(1);\n    }\n    return nested(v[0..64]) - 2016 + argv.len() as i32 - 1;\n}\n";
    expect_c_user_absent("the inner access is proven", SRC, "__sc_bounds(");
    b.add("nested behavior", SRC, 0);
}

// Project program `src` (it imports std::simd) calls the vector range check in its C (`--emit-c`) when
// `present`, and its run exits 0, or traps with `trap` when that is not empty.
fn vec_check(label: str, src: str, present: bool, trap: str) {
    let cb = h::diff_build(src, ["--emit-c"]);
    assert(cb.built, label);
    let c = cli::read_text(format("{}/build/debug/raw/main.c", cb.proj.dir()).as_str());
    assert(c.len() != 0, label);
    assert(c.contains("__sc_bounds_vec(") == present, label);
    // a proven vector access leaves no element check either
    assert(present || !c.contains("__sc_bounds("), label);
    let b = h::diff_build(src, []);
    assert(b.built, label);
    let r = h::diff_run(&b, "");
    let ok = if trap.len() == 0 {
        r.exit == 0
    } else {
        r.exit != 0 && r.err.contains(trap)
    };
    if !ok {
        eprintln("{}: exit {}: {}", label, r.exit, r.err.as_str());
    }
    assert(ok, label);
}

// `vec_check` for several programs in one project, built twice: case k is module `case_k`
// (`case_module`) under `case_root`, its C (`--emit-c`) is `build/debug/raw/case_k.c`, and each case runs
// in its own process. On the vector conformance lane (a wasm32 run) or when a build fails, each case
// builds alone.
struct VecProgs {
    labels: Vector<String>,
    srcs: Vector<String>,
    present: Vector<bool>,
    traps: Vector<String>,
}

extend VecProgs {
    fn new() VecProgs {
        return VecProgs {
            labels: Vector::<String>::new(),
            srcs: Vector::<String>::new(),
            present: Vector::<bool>::new(),
            traps: Vector::<String>::new(),
        };
    }

    fn add(self: &mut VecProgs, label: str, src: str, present: bool, trap: str) {
        self.labels.push(String::from_str(label));
        self.srcs.push(String::from_str(src));
        self.present.push(present);
        self.traps.push(String::from_str(trap));
    }

    fn check(self: &VecProgs) {
        if h::simd_lane() {
            for k in 0..self.srcs.len() {
                vec_check(
                    self.labels.at(k).as_str(),
                    self.srcs.at(k).as_str(),
                    *self.present.at(k),
                    self.traps.at(k).as_str(),
                );
            }
            return;
        }
        let p = h::diff_proj();
        let q = h::diff_proj();
        for k in 0..self.srcs.len() {
            let m = case_module(self.srcs.at(k).as_str());
            p.mkfile(format("case_{}.spc", k).as_str(), &m);
            q.mkfile(format("case_{}.spc", k).as_str(), &m);
        }
        p.mkfile("main.spc", case_root(self.srcs.len()).as_str());
        q.mkfile("main.spc", case_root(self.srcs.len()).as_str());
        let cb = h::diff_build_in(p, ["--emit-c"]);
        let b = h::diff_build_in(q, []);
        let root = b.proj.dir();
        for k in 0..self.srcs.len() {
            let label = self.labels.at(k).as_str();
            let c = cli::read_text(format("{}/build/debug/raw/case_{}.c", cb.proj.dir(), k).as_str());
            if !cb.built || !b.built || !c.contains("case_main(") {
                eprintln("--- case {} builds alone", k);
                vec_check(label, self.srcs.at(k).as_str(), *self.present.at(k), self.traps.at(k).as_str());
                continue;
            }
            let present = *self.present.at(k);
            assert(c.contains("__sc_bounds_vec(") == present, label);
            // a proven vector access leaves no element check either
            assert(present || !c.contains("__sc_bounds("), label);
            let mut cmd = format("\"{}/prog{}\"", root, unsafe str::from_cstr(cli::binext()));
            let mut errp = format("{}/.err", root);
            let exit = cli::run_with(cmd.cstr(), null, null, errp.cstr(), format("BATCH_CASE={}", k).as_str());
            let err = cli::read_text(&errp);
            let trap = self.traps.at(k).as_str();
            let ok = if trap.len() == 0 {
                exit == 0
            } else {
                exit != 0 && err.contains(trap)
            };
            if !ok {
                eprintln("{}: exit {}: {}", label, exit, err.as_str());
            }
            assert(ok, label);
        }
    }
}

// A vector load or store checks `start <= len && N <= len - start` once (IN_BOUNDS_GROUP): in a loop
// over `len - len % N` stepping by N the interval and stride facts prove it; against the bare length,
// or after the slice's owner shrinks, the check stays.
@test
fn vector_access_group_checks() {
    let mut vp = VecProgs::new();
    let STRIDED: str = "import std::simd;\nfn sum(s: []i32, d: []mut i32) i32 {\n    let n = s.len() - s.len() % 4;\n    let mut acc = Simd::<i32, 4>::splat(0);\n    let mut i: usize = 0;\n    while i < n {\n        let v = simd::load::<i32, 4>(s, i);\n        acc = acc.wrapping_add(v);\n        i += 4;\n    }\n    return acc[0] + acc[3] + d.len() as i32;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for k in 0..argv.len() + 9 {\n        v.push(k as i32);\n    }\n    let mut d = [0; 4];\n    return sum(v[0..v.len()], d) - 18;\n}\n";
    vp.add("the strided load is proven", STRIDED, false, "");
    let BARE: str = "import std::simd;\nfn sum(s: []i32) i32 {\n    let mut acc = Simd::<i32, 4>::splat(0);\n    let mut i: usize = 0;\n    while i < s.len() {\n        acc = acc.wrapping_add(simd::load::<i32, 4>(s, i));\n        i += 4;\n    }\n    return acc[0];\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for k in 0..argv.len() + 8 {\n        v.push(k as i32);\n    }\n    return sum(v[0..v.len()]);\n}\n";
    vp.add(
        "the bare length keeps the check: the last partial load traps",
        BARE,
        true,
        "4 lanes from 8 but the length is 9",
    );
    let SHRINK: str = "import std::simd;\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for k in 0..argv.len() + 7 {\n        v.push(k as i32);\n    }\n    let n = v.len() - v.len() % 4;\n    let mut t = 0;\n    let mut i: usize = 0;\n    while i < n {\n        t += simd::load::<i32, 4>(v[0..v.len()], i)[0];\n        let _ = v.pop();\n        let _ = v.pop();\n        let _ = v.pop();\n        i += 4;\n    }\n    return t;\n}\n";
    vp.add(
        "a pop in the loop keeps the check: the load past the shrunk length traps",
        SHRINK,
        true,
        "4 lanes from 4 but the length is 5",
    );
    let BETWEEN: str = "import std::simd;\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for k in 0..argv.len() + 7 {\n        v.push(k as i32);\n    }\n    let i = argv.len() + 3; // == 4\n    if i + 4 > v.len() {\n        return 9;\n    }\n    let a = simd::load::<i32, 4>(v[0..v.len()], i);\n    let _ = v.pop();\n    let b = simd::load::<i32, 4>(v[0..v.len()], i);\n    return a[0] + b[0];\n}\n";
    vp.add(
        "a store to the length's base keeps the second check, which traps",
        BETWEEN,
        true,
        "4 lanes from 4 but the length is 7",
    );
    // A slice built by a struct literal: its length is the value of its `len` operand, so the loop
    // over that value's aligned part is proven; a later write to the field keeps the check.
    let VIEW: str = "import std::simd;\nfn sum(p: *const i32, n: usize) i32 {\n    let s = unsafe Slice::<i32> { ptr: p, len: n };\n    let m = n - n % 4;\n    let mut acc = Simd::<i32, 4>::splat(0);\n    let mut i: usize = 0;\n    while i < m {\n        acc = acc.wrapping_add(simd::load::<i32, 4>(s, i));\n        i += 4;\n    }\n    return acc[0];\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for k in 0..argv.len() + 9 {\n        v.push(k as i32);\n    }\n    let s = v[0..v.len()];\n    return sum(s.ptr, s.len) - 4;\n}\n";
    vp.add("a view literal's length is its len operand", VIEW, false, "");
    let VIEW_SET: str = "import std::simd;\nfn sum(p: *const i32, n: usize) i32 {\n    let mut s = unsafe Slice::<i32> { ptr: p, len: n };\n    unsafe s.len = n - 3;\n    let m = n - n % 4;\n    let mut acc = Simd::<i32, 4>::splat(0);\n    let mut i: usize = 0;\n    while i < m {\n        acc = acc.wrapping_add(simd::load::<i32, 4>(s, i));\n        i += 4;\n    }\n    return acc[0];\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    for k in 0..argv.len() + 9 {\n        v.push(k as i32);\n    }\n    let s = v[0..v.len()];\n    return sum(s.ptr, s.len) - 4;\n}\n";
    vp.add(
        "a write to the view's len keeps the check: the second load traps",
        VIEW_SET,
        true,
        "4 lanes from 4 but the length is 7",
    );
    // An early-return guard bounds the loop's limit by the other slice's length: both accesses are
    // proven (`i < m <= n <= y.len()`).
    let GUARD: str = "import std::simd;\nfn sum(x: []f32, y: []f32) f32 {\n    let n = x.len();\n    if y.len() < n {\n        return 0.0;\n    }\n    let m = n - n % 4;\n    let mut acc = Simd::<f32, 4>::splat(0.0);\n    let mut i: usize = 0;\n    while i < m {\n        acc = acc + simd::load::<f32, 4>(x, i) * simd::load::<f32, 4>(y, i);\n        i += 4;\n    }\n    let mut s = acc[0] + acc[1] + acc[2] + acc[3];\n    for k in m..n {\n        s = s + x[k] * y[k];\n    }\n    return s;\n}\nfn main(argv: Vector<str>) i32 {\n    let mut v = Vector::<f32>::new();\n    for k in 0..argv.len() + 8 {\n        v.push(k as f32);\n    }\n    return sum(v[0..v.len()], v[0..v.len()]) as i32 - 204;\n}\n";
    vp.add("a guard proves the other slice and the scalar tail", GUARD, false, "");
    vp.check();
}

// A whole reassignment of a view kills the length facts of its old value: the next access checks
// the new length, in straight-line code, in a loop, and after an index operand that reassigns the
// indexed view.
fn safety_reassigned_view(b: &mut h::ExitBatch) {
    b.add_trap(
        "reassigned view",
        M"(@noinline
fn f(mut x: []u32, y: []u32) u32 {
    let a = x[0];
    x = y;
    return a + x[0];
}
fn main(argv: Vector<str>) i32 {
    let a0: [u32; 1] = [7];
    let mut v = Vector::<u32>::new();
    if argv.len() > 5 {
        v.push(1);
    }
    return f(a0, v[0..v.len()]) as i32;
}
)",
        "index out of bounds",
    );
    b.add_trap(
        "view reassigned in a loop",
        M"(@noinline
fn f(mut x: []u32, y: []u32, n: usize) u32 {
    let mut s = x[0];
    for _ in 0..n {
        s += x[0];
        x = y;
    }
    return s;
}
fn main(argv: Vector<str>) i32 {
    let a0: [u32; 1] = [7];
    let mut v = Vector::<u32>::new();
    if argv.len() > 5 {
        v.push(1);
    }
    return f(a0, v[0..v.len()], argv.len() + 1) as i32;
}
)",
        "index out of bounds",
    );
    // The object `x[0]` is read before the index operand empties `x`: its element is still there.
    b.add(
        "view reassigned by an index operand",
        M"(fn pick(mut x: [][]u32, go: bool) u32 {
    if !go {
        return 0;
    }
    let y = x[1..1];
    return x[0][switch 0 { _ => { x = y; 0 } }];
}
fn main(argv: Vector<str>) i32 {
    let a0: []u32 = [7];
    let x: [][]u32 = [a0];
    return pick(x, argv.len() < 5) as i32;
}
)",
        7,
    );
}

// The exit-code and trap cases of the provider functions above, one program per group
// (`h::ExitBatch`): a group builds once where each case built alone.
@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    safety_element_checks(&mut b);
    safety_range_checks(&mut b);
    safety_mutation_and_zst(&mut b);
    affine_guard_removes_check(&mut b);
    coalescing_groups_adjacent_checks(&mut b);
    coalescing_blocked_by_mutation(&mut b);
    b.run();
}

@test
fn exit_cases_01() {
    let mut b = h::ExitBatch::new();
    inline_omitted_aggregate_members(&mut b);
    interval_facts_remove_strided_checks(&mut b);
    interval_join_keeps_the_hull(&mut b);
    interval_widening_terminates_on_nested_loops(&mut b);
    safety_reassigned_view(&mut b);
    b.run();
}

// The proof rules over joins, comparison kinds, constant bounds, bounded values, value numbering,
// offsets and loop counters: each function `removal_by_rule` lists proves every check (the others
// before `keep_` hold the shapes it does not prove), each `keep_` function keeps its own (a check
// the program needs).
const RULES: str = M"(pub struct Cur {
    pub buf: Vector<u8>,
    pub pos: usize,
}
@noinline
pub fn bump(c: &mut Cur) {
    c.pos += 1;
}
@noinline
pub fn shrink(v: &mut Vector<i32>) {
    let _ = v.pop();
}
@used @noinline
pub fn join_access(xs: []i32) i32 {
    let mut t = 0;
    for i in 0..xs.len() {
        if t > 100 {
            t = 0;
        }
        t += xs[i];
    }
    return t;
}
@used @noinline
pub fn eq_len(a: []i32, b: []i32) i32 {
    if a.len() != b.len() {
        return 0;
    }
    let mut t = 0;
    for i in 0..a.len() {
        t += a[i] * b[i];
    }
    return t;
}
@used @noinline
pub fn last_nonempty(xs: []i32) i32 {
    if xs.is_empty() {
        return 0;
    }
    return xs[0] + xs[xs.len() - 1];
}
@used @noinline
pub fn assert_guard(xs: []i32, i: usize) i32 {
    assert(i < xs.len());
    return xs[i];
}
@used @noinline
pub fn array_const(a: &Array<i32, 8>, i: usize) i32 {
    let mut t = a[i & 7] + a[i % 8];
    for k in 0..8usize {
        t += a[k];
    }
    return t;
}
@used @noinline
pub fn derived_index(xs: []i32, i: usize) i32 {
    if xs.len() == 0 {
        return 0;
    }
    let mut t = xs[i % xs.len()];
    for k in 0..xs.len() {
        t += xs[k / 2];
    }
    return t;
}
@used @noinline
pub fn cursor(c: &Cur) u8 {
    if c.pos < c.buf.len() {
        return c.buf[c.pos];
    }
    return 0;
}
@used @noinline
pub fn sub_views(xs: []i32, n: usize) i32 {
    if n > xs.len() || xs.len() < 3 {
        return 0;
    }
    let s = xs[..n];
    let mut t = 0;
    for i in 0..n {
        t += s[i];
    }
    for i in 0..xs.len() - 2 {
        let w = xs[i..i + 3];
        t += w[0] + w[1] + w[2];
    }
    return t;
}
@used @noinline
pub fn min_len(a: []i32, b: []i32) i32 {
    let n = a.len().min(b.len());
    let mut t = 0;
    for i in 0..n {
        t += a[i] * b[i];
    }
    return t;
}
@used @noinline
pub fn or_return(xs: []i32, i: usize, j: usize) i32 {
    if i >= xs.len() || j >= xs.len() {
        return 0;
    }
    return xs[i] + xs[j];
}
@used @noinline
pub fn pairs(xs: []i32) i32 {
    let mut t = 0;
    for i in 0..xs.len() / 2 {
        t += xs[2 * i] + xs[2 * i + 1];
    }
    for i in 1..xs.len() {
        t += xs[i - 1];
    }
    return t;
}
@used @noinline
pub fn loops(xs: []i32, start: usize) i32 {
    let mut t = 0;
    let mut i = xs.len();
    while i > 0 {
        i -= 1;
        t += xs[i];
    }
    let mut j: usize = 0;
    while j != xs.len() {
        t += xs[j];
        j += 1;
    }
    if xs.len() != 0 {
        let mut k = start % xs.len();
        for _r in 0..xs.len() {
            t += xs[k];
            k = (k + 1) % xs.len();
        }
    }
    return t;
}
@used @noinline
pub fn switches(xs: []i32, a: &Array<i32, 4>, i: usize) i32 {
    let x = switch xs.len() {
        0 => 0,
        1 => xs[0],
        _ => xs[1],
    };
    return x + switch i {
        0..=3 => a[i],
        _ => -1,
    };
}
@used @noinline
pub fn casts_and_bridges(xs: []i32, i: usize, i0: usize) i32 {
    let mut t = 0;
    for k in 0u32..xs.len() as u32 {
        t += xs[k as usize];
    }
    if i < 10 && xs.len() > 20 {
        t += xs[i];
    }
    if xs.is_empty() {
        return t;
    }
    let mut c = i0;
    if c >= xs.len() {
        c = 0;
    }
    return t + xs[c];
}
@used @noinline
pub fn counters(xs: []i32) i32 {
    let mut t = 0;
    let mut i = xs.len();
    while i > 0 {
        i -= 1;
        t += xs[i];
    }
    let mut j: usize = 0;
    while j != xs.len() {
        t += xs[j];
        j += 1;
    }
    for k in 1..xs.len() {
        t += xs[k - 1];
    }
    let n = xs.len();
    if n != 0 {
        let mut r = n / 2;
        for _s in 0..n {
            t += xs[r];
            r = (r + 1) % n;
        }
        let mut d: usize = 0;
        loop {
            t += xs[d];
            d += 1;
            if d >= n {
                break;
            }
        }
    }
    return t;
}
@used @noinline
pub fn bridges(xs: []i32, a: &mut Array<u32, 8>, i: usize, g: i32) i32 {
    let mut t = 0;
    if i < 10 && xs.len() > 20 {
        t += xs[i];
    }
    let mut cn: i32 = 0;
    for k in 0..g {
        if k % 2 == 0 && (cn as usize) < 8 {
            a[cn as usize] = 1;
            a[cn as usize] += 2;
            cn += 1;
        }
    }
    let hi = if i > xs.len() {
        xs.len()
    } else {
        i
    };
    for k in 0..hi {
        t += xs[k];
    }
    return t + cn;
}
@used @noinline
pub fn keep_closure(xs: []i32, start: usize) i32 {
    let mut i = start;
    if i < xs.len() {
        let bump = || {
            i += 1;
        };
        bump();
        return xs[i];
    }
    return 0;
}
@used @noinline
pub fn keep_raw_alias(c: &UnsafeCell<Vector<i32>>, i: usize) i32 {
    let p = c.get();
    let q = c.get();
    if i < unsafe (*p).len() {
        shrink(unsafe &mut *q);
        return unsafe (*p)[i];
    }
    return 0;
}
@used @noinline
pub fn keep_step2(xs: []i32) i32 {
    let mut t = 0;
    let mut i = xs.len();
    while i > 0 {
        i -= 2;
        t += xs[i];
    }
    return t;
}
@used @noinline
pub fn keep_wrapping(xs: []i32, i: usize) i32 {
    let j = i.wrapping_add(1);
    if j < xs.len() {
        return xs[i];
    }
    return 0;
}
@used @noinline
pub fn keep_offset(xs: []i32, i: usize) i32 {
    if i + 1 < xs.len() {
        return xs[i + 1];
    }
    return xs[i];
}
@used @noinline
pub fn keep_bumped_cursor(c: &mut Cur) u8 {
    if c.pos < c.buf.len() {
        bump(c);
        return c.buf[c.pos];
    }
    return 0;
}
@used @noinline
pub fn keep_pop_loop(v: &mut Vector<i32>) i32 {
    let mut t = 0;
    let mut i = v.len();
    while i > 0 {
        i -= 1;
        let _ = v.pop();
        let _ = v.pop();
        t += v[i];
    }
    return t;
}
)";

@test
fn removal_by_rule() {
    let c = h::compile_c_user(RULES);
    assert(c.ok(), "the rule cases compile");
    let code = unsafe str::from_cstr(c.code);
    let removed: []str = [
        "int32_t join_access(Slice__i32 xs) {",
        "int32_t eq_len(Slice__i32 a, Slice__i32 b) {",
        "int32_t last_nonempty(Slice__i32 xs) {",
        "int32_t assert_guard(Slice__i32 xs, size_t i) {",
        "int32_t array_const(const Array__i32__8 *a, size_t i) {",
        "int32_t derived_index(Slice__i32 xs, size_t i) {",
        "uint8_t cursor(const Cur *c) {",
        "int32_t min_len(Slice__i32 a, Slice__i32 b) {",
        "int32_t or_return(Slice__i32 xs, size_t i, size_t j) {",
        "int32_t counters(Slice__i32 xs) {",
        "int32_t bridges(Slice__i32 xs, Array__u32__8 *restrict a, size_t i, int32_t g) {",
    ];
    for def in removed {
        let body = h::c_fn(code, def);
        if check_count(body, "__sc_bounds(") + check_count(body, "__sc_range(") != 0 {
            eprintln("{}{}", def, body);
        }
        assert(check_count(body, "__sc_bounds(") + check_count(body, "__sc_range(") == 0, def);
    }
    let kept: []str = [
        "int32_t keep_closure(Slice__i32 xs, size_t start) {",
        "int32_t keep_raw_alias(const UnsafeCell__Vector__i32 *c, size_t i) {",
        "int32_t keep_step2(Slice__i32 xs) {",
        "int32_t keep_wrapping(Slice__i32 xs, size_t i) {",
        "int32_t keep_offset(Slice__i32 xs, size_t i) {",
        "uint8_t keep_bumped_cursor(Cur *restrict c) {",
        "int32_t keep_pop_loop(Vector__i32 *restrict v) {",
    ];
    for def in kept {
        assert(check_count(h::c_fn(code, def), "__sc_bounds(") != 0, def);
    }
}

// The rules' programs run: the proved accesses give the same values, and each kept check fires.
fn rule_programs(b: &mut h::ExitBatch) {
    let sums = format(
        "{}fn main(argv: Vector<str>) i32 {{\n    let mut v = Vector::<i32>::new();\n    for k in 0..argv.len() + 23 {{\n        v.push(k as i32);\n    }}\n    let xs = v.as_slice();\n    let mut a = Array::<i32, 8>::new();\n    let mut a4 = Array::<i32, 4>::new();\n    for k in 0..8usize {{\n        a[k] = k as i32;\n    }}\n    for k in 0..4usize {{\n        a4[k] = k as i32 + 1;\n    }}\n    let i = argv.len() + 2;\n    let mut t = join_access(xs) + eq_len(xs, xs) + last_nonempty(xs) + assert_guard(xs, i) + array_const(&a, i);\n    t += derived_index(xs, i) + sub_views(xs, i) + min_len(xs, xs[..5]) + or_return(xs, i, i + 1) + pairs(xs);\n    t += loops(xs, i) + switches(xs, &a4, i) + casts_and_bridges(xs, i, 99);\n    return t - 7025;\n}}\n",
        RULES,
    );
    b.add("the proved accesses keep their values", &sums, 0);
    let counted = format(
        "{}fn main(argv: Vector<str>) i32 {{\n    let mut v = Vector::<i32>::new();\n    for k in 0..argv.len() + 23 {{\n        v.push(k as i32);\n    }}\n    let xs = v.as_slice();\n    let mut a = Array::<u32, 8>::new();\n    let i = argv.len() + 2;\n    let t = counters(xs) + bridges(xs, &mut a, i, 11) + bridges(xs, &mut a, 40, 3);\n    return t % 200 - 47;\n}}\n",
        RULES,
    );
    b.add("the counters, bridges and cast pairs keep their values", &counted, 0);
    let closure = format(
        "{}fn main(argv: Vector<str>) i32 {{\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    v.push(2);\n    return keep_closure(v.as_slice(), argv.len());\n}}\n",
        RULES,
    );
    b.add_trap("a closure's write to a captured index", &closure, "index out of bounds");
    let alias = format(
        "{}fn main(argv: Vector<str>) i32 {{\n    let mut v = Vector::<i32>::new();\n    v.push(5);\n    let c = UnsafeCell::<Vector<i32>>::new(v);\n    return keep_raw_alias(&c, argv.len() - 1);\n}}\n",
        RULES,
    );
    b.add_trap("a pop through an aliasing pointer", &alias, "index out of bounds");
    let pop = format(
        "{}fn main(argv: Vector<str>) i32 {{\n    let mut v = Vector::<i32>::new();\n    for k in 0..argv.len() + 3 {{\n        v.push(k as i32);\n    }}\n    return keep_pop_loop(&mut v);\n}}\n",
        RULES,
    );
    b.add_trap("a loop that shrinks its vector", &pop, "index out of bounds");
    let cur = format(
        "{}fn main(argv: Vector<str>) i32 {{\n    let mut v = Vector::<u8>::new();\n    v.push(1);\n    let mut c = Cur {{ buf: v, pos: argv.len() - 1 }};\n    return keep_bumped_cursor(&mut c) as i32;\n}}\n",
        RULES,
    );
    b.add_trap("a cursor a call bumps", &cur, "index out of bounds");
}

@test
fn exit_cases_02() {
    let mut b = h::ExitBatch::new();
    rule_programs(&mut b);
    b.run();
}
