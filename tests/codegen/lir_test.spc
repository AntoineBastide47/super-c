// The LIR library: a tool builds a package with the package-table calls, the verifier accepts it and
// rejects broken bodies, and the text form reads back to the same text.
import lir::ir as *;
import lir::verify as verify;
import lir::print as lprint;
import lir::parse as lparse;
import lir::eval as leval;
import ir::interp as iri;

// `fn mid(a: i64, b: i64) i64 { return (a + b) / 2; }` with its overflow check, built by a tool: a new
// symbol, a message, a file of its own, and a body defined after the verifier accepts it.
fn mid_package() Package {
    let mut p = Package::new(8);
    let f = p.add_file("tool.input");
    let s = p.add_symbol("mid", SK_FUNC, SL_GLOBAL);
    assert(s != NONE, "a new symbol");
    assert_eq(p.add_symbol("mid", SK_FUNC, SL_LOCAL), NONE);
    let m = p.add_message("attempt to add with overflow");
    let mut b = Body::new();
    let ps: []u32 = [T_I64 as u32, T_I64 as u32];
    b.sig = b.signature(ps, 2, false, T_I64);
    let tys: []u8 = [T_I64, T_I64];
    let b0 = b.add_block(tys);
    let none: []u8 = [];
    let b1 = b.add_block(none);
    let b2 = b.add_block(none);
    b.blocks.index_mut(b2 as usize).flags = BLOCK_COLD;
    b.begin(b0);
    let l = b.loc(Loc { file: f, line: 1, col: 5 });
    let x = b.param(b0, 0);
    let y = b.param(b0, 1);
    let sum = b.emit(Inst { op: O_ADDO, ty: T_I64, aux: OV_SIGNED, a: x, b: y, c: VNONE }, l);
    let noargs: []u32 = [];
    let eb2 = b.edge(b2, noargs);
    let eb1 = b.edge(b1, noargs);
    let _ = b.emit(Inst { op: O_BR, ty: T_NONE, aux: 0, a: VFLAG | sum, b: eb2, c: eb1 }, l);
    b.begin(b1);
    let two = b.emit(Inst { op: O_ICONST, ty: T_I64, aux: 0, a: 2, b: 0, c: VNONE }, 0);
    let q = b.emit(Inst { op: O_SDIV, ty: T_I64, aux: 0, a: sum, b: two, c: VNONE }, 0);
    let _ = b.emit(Inst { op: O_RET, ty: T_NONE, aux: 0, a: q, b: VNONE, c: VNONE }, 0);
    b.begin(b2);
    let _ = b.emit(Inst { op: O_PANIC, ty: T_NONE, aux: 0, a: b.ref_msg(m), b: VNONE, c: VNONE }, l);
    let mut v = verify::Verifier::new();
    assert(v.check(&p, "mid", &b), v.err.as_str());
    assert(p.define(s, &b), "defined");
    assert(!p.define(s, &b), "defined once");
    return p;
}

@test
fn a_tool_built_body_verifies_and_reads_back() {
    let p = mid_package();
    let mut t1 = String::new();
    lprint::print_package(&p, &mut t1);
    let mut err = String::new();
    let q = lparse::parse(t1.as_str(), &mut err);
    assert(q.is_some(), err.as_str());
    let p2 = q.unwrap();
    let mut v = verify::Verifier::new();
    for i in 0..p2.syms.len() {
        let s = p2.syms[i];
        if s.def != NONE && s.kind == SK_FUNC {
            assert(v.check(&p2, p2.spell(s.name), &p2.bodies[s.def as usize]), v.err.as_str());
        }
    }
    let mut t2 = String::new();
    lprint::print_package(&p2, &mut t2);
    assert_eq(t1.as_str(), t2.as_str());
    assert(t1.as_str().contains("v2, v3 = addo.s.i64 v0, v1 !1:5"), t1.as_str());
    assert(t1.as_str().contains("br v3, b2, b1 !1:5"), t1.as_str());
    assert(t1.as_str().contains("panic \"attempt to add with overflow\""), t1.as_str());
}

@test
fn the_verifier_rejects_a_use_its_definition_does_not_dominate() {
    let p = mid_package();
    let mut b = p.bodies[0].compact();
    // `ret` of b1 returns the quotient of b1: dominated. Make b2 (reached from b0 only) return it: b1
    // does not dominate b2.
    let n = b.insts.len();
    b.insts.index_mut(n - 1).op = O_RET;
    b.insts.index_mut(n - 1).a = 3;
    let mut v = verify::Verifier::new();
    assert(!v.check(&p, "mid", &b), "a use b1 does not dominate");
    assert(v.err.as_str().contains("does not dominate"), v.err.as_str());
}

@test
fn the_parser_names_the_line_and_column_of_an_error() {
    let mut err = String::new();
    let q = lparse::parse(
        "lir ptr 8\nsym @f fn global\nfn @f\n  sig () -> i32\nb0:\n  v0 = iconst.i32 1\n  ret v1\n",
        &mut err,
    );
    assert(q.is_none(), "an undefined value");
    assert(err.as_str().starts_with("7:"), err.as_str());
    let q2 = lparse::parse("lir ptr 8\nsym @f fn global\nfn @f\n  sig () -> i32\nb0:\n  v0 = bogus.i32 1\n", &mut err);
    assert(q2.is_none(), "an unknown opcode");
}

@test
fn the_evaluator_runs_a_tool_built_body() {
    let p = mid_package();
    let s = p.find_symbol("mid");
    let mut e = leval::Eval::new(&p);
    let a: []u64 = [10, 31];
    let o = e.run(s, a);
    assert_eq(o.kind, leval::EV_OK);
    assert_eq(o.value, 20);
    // i64::MAX + 1 overflows: the panic and its location.
    let big: []u64 = [0x7FFFFFFFFFFFFFFF, 1];
    let o2 = e.run(s, big);
    assert_eq(o2.kind, iri::IT_TRAP_PANIC);
    assert_eq(o2.msg.as_str(), "attempt to add with overflow");
    assert_eq(o2.loc.line, 1);
    assert_eq(o2.loc.col, 5);
}

// A package of text: it parses, each body verifies, and it prints back to the same text.
fn read_package(text: str) Package {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let p = q.unwrap();
    let mut v = verify::Verifier::new();
    for i in 0..p.syms.len() {
        let s = p.syms[i];
        if s.def != NONE && s.kind == SK_FUNC {
            assert(v.check(&p, p.spell(s.name), &p.bodies[s.def as usize]), v.err.as_str());
        }
    }
    let mut t = String::new();
    lprint::print_package(&p, &mut t);
    assert_eq(t.as_str(), text);
    return p;
}

@test
fn the_evaluator_runs_vector_operations() {
    let p = read_package(
        "lir ptr 8\nsym @sat fn global\nsym @abs fn global\nfn @sat\n  sig () -> i8\nb0:\n  v0 = wconst.v4i8 0x64646464\n  v1 = vop.saturating_add.s.v4i8 (v0, v0)\n  v2 = vop.reduce_add.s.i8 (v1)\n  ret v2\nfn @abs\n  sig () -> i8\nb0:\n  v0 = wconst.v4i8 0x80010203\n  v1 = vop.abs.s.v4i8 (v0)\n  v2 = vop.reduce_add.s.i8 (v1)\n  ret v2\n",
    );
    let mut e = leval::Eval::new(&p);
    let none: []u64 = [];
    // Each lane saturates at 127; their sum wraps to -4.
    let o = e.run(p.find_symbol("sat"), none);
    assert_eq(o.kind, leval::EV_OK);
    assert_eq(o.value, 0xFC);
    // Lane 3 holds i8::MIN: its absolute value overflows.
    let o2 = e.run(p.find_symbol("abs"), none);
    assert_eq(o2.kind, iri::IT_TRAP_UB_OVERFLOW);
    assert_eq(o2.msg.as_str(), "attempt to negate with overflow");
}

@test
fn the_call_check_rejects_a_call_its_callee_does_not_take() {
    let p = read_package(
        "lir ptr 8\nsym @g fn global\nsym @f fn global\nfn @g\n  sig (i64) -> void\nb0(v0: i64):\n  ret\nfn @f\n  sig (i32, ptr) -> void\nb0(v0: i32, v1: ptr):\n  call @g(v0) : (i32) -> void\n  vastart v1\n  vaend v1\n  ret\n",
    );
    let mut v = verify::Verifier::new();
    let f = p.syms[p.find_symbol("f") as usize];
    assert(!v.check_calls(&p, "f", &p.bodies[f.def as usize]), "an i32 argument to an i64 parameter");
    assert(v.err.as_str().contains("a call of its callee's signature"), v.err.as_str());
    let g = p.syms[p.find_symbol("g") as usize];
    assert(v.check_calls(&p, "g", &p.bodies[g.def as usize]), v.err.as_str());
}
