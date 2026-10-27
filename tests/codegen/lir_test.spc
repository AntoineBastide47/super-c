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
    // Lane 3 holds i8::MIN: its absolute value overflows, and the trap names the lane.
    let o2 = e.run(p.find_symbol("abs"), none);
    assert_eq(o2.kind, iri::IT_TRAP_UB_OVERFLOW);
    assert_eq(o2.msg.as_str(), "lane 3: attempt to negate with overflow");
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

// Every opcode, type, condition, order, operation suffix and table of the text form, in print order:
// it parses, verifies and prints back to the same bytes.
const FORMS: str = M"(lir ptr 8 vec 32
file f0 "forms.spc"
file f1 "lib/\"q\"\x09.spc"
sym @ints fn global
sym @floats fn local
sym @memory fn global
sym @bare fn global
sym @atomics fn global
sym @calls fn global
sym @va fn global
sym @vectors fn global
sym @"odd name" fn local
sym @puts fn global ext
sym @table data global used section "__DATA,__table"
sym @msg data local
sym @counter tls global
fn @ints
  file f0
  sig (i64, i32, i8.s, i16) -> i64
b0(v0: i64, v1: i32, v2: i8, v3: i16):
  v4 = iconst.i64 -5 !1:1
  v5 = add.i64 v0, v4 !2:3
  v6 = sub.i64 v5, v0
  v7 = mul.i64 v6, v5
  v8 = sdiv.i64 v7, v4
  v9 = udiv.i64 v8, v4
  v10 = srem.i64 v9, v4
  v11 = urem.i64 v10, v4
  v12 = and.i64 v11, v0
  v13 = or.i64 v12, v0
  v14 = xor.i64 v13, v0
  v15 = shl.i64 v14, v4
  v16 = lshr.i64 v15, v4
  v17 = ashr.i64 v16, v4
  v18 = neg.i64 v17
  v19 = not.i64 v18
  v20, v21 = addo.s.i64 v19, v0
  v22, v23 = subo.u.i32 v1, v1
  v24, v25 = mulo.s.i8 v2, v2
  v26 = clz.i64 v20
  v27 = ctz.i32 v22
  v28 = popcnt.i8 v24
  v29 = sext.i64 v28
  v30 = zext.i64 v3
  v31 = trunc.i16 v29
  v32 = iconst.ptr 0
  v33 = ptrtoint.i64 v32
  v34 = inttoptr.ptr v33
  v35 = wconst.i128 0x1, 0xffffffffffffffff
  v36 = add.i128 v35, v35
  v37 = trunc.i64 v36
  v38 = icmp.eq v0, v37
  v39 = icmp.ne v0, v37
  v40 = icmp.slt v0, v37
  v41 = icmp.sle v0, v37
  v42 = icmp.sgt v0, v37
  v43 = icmp.sge v0, v37
  v44 = icmp.ult v0, v37
  v45 = icmp.ule v0, v37
  v46 = icmp.ugt v0, v37
  v47 = icmp.uge v32, v34
  v48 = select.i64 v38, v30, v37
  br v21, b1, b2(v48)
b1: cold
  panic "attempt to add with overflow" !f1:9:9
b2(v49: i64):
  switch v49 [0 -> b3, -1 -> b4(v49)] else b5
b3:
  jmp b4(v49)
b4(v50: i64):
  ret v50
b5:
  unreachable
fn @floats
  sig (f32, f64) -> f64
b0(v0: f32, v1: f64):
  v2 = fconst.f32 0x3f800000
  v3 = fconst.f64 0x3ff0000000000000
  v4 = fadd.f32 v0, v2
  v5 = fsub.f64 v1, v3
  v6 = fmul.f64 v5, v5
  v7 = fdiv.f64 v6, v3
  v8 = fneg.f64 v7
  v9 = fpext.f64 v4
  v10 = fptrunc.f32 v8
  v11 = fptosi.i32 v10
  v12 = fptosi.unchecked.i64 v8
  v13 = fptoui.i64 v9
  v14 = fptoui.unchecked.i8 v10
  v15 = sitofp.f64 v12
  v16 = uitofp.f32 v14
  v17 = bitcast.i64 v15
  v18 = bitcast.f64 v17
  v19 = fcmp.oeq v18, v9
  v20 = fcmp.one v18, v9
  v21 = fcmp.olt v18, v9
  v22 = fcmp.ole v18, v9
  v23 = fcmp.ogt v18, v9
  v24 = fcmp.oge v18, v9
  v25 = fcmp.ueq v16, v4
  v26 = fcmp.une v16, v4
  v27 = fcmp.uno v16, v4
  v28 = select.f64 v27, v18, v15
  v29 = fma.f64 v28, v15, v18
  ret v29
fn @memory
  sig (ptr, i64) -> void
  slot s0 size 32 align 3
  slot s1 size 4 align 2
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = ptradd v2+8
  v4 = ptradd v0, v1 * 4-16
  store v1, v3 align 3
  v5 = load.i64 v2+8 align 3 volatile
  store v5, v4+4 align 2 volatile
  v6 = iconst.i8 0
  v7 = iconst.i64 32
  memset v2, v6, v7
  memcpy v0, v2, v7
  memcpy.overlap v4, v0, v7
  v8 = symaddr @table+8
  v9 = symaddr @counter
  v10 = load.ptr v8 align 3
  v11 = slotaddr s1
  store v6, v11+3 align 0
  v12 = load.i16 v9-2 align 1
  asm "ldr %0, %2; add %0, %0, %1" out["=r" i64] in["r", "m"] clobber["memory", "x9"] (v2, v1, v0)
  ret
fn @bare
  naked
  sig () -> void
b0:
  asm "ret" out[] in[] clobber[] ()
  ret
fn @atomics
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = aload.i32 v0 acquire
  astore v1, v0+4 release
  v3 = armw.xchg.i32 v1, v0 seq_cst
  v4 = armw.add.i32 v1, v0 relaxed
  v5 = armw.sub.i32 v1, v0 acq_rel
  v6 = armw.and.i32 v1, v0 acquire
  v7 = armw.or.i32 v1, v0 release
  v8 = armw.xor.i32 v1, v0+8 seq_cst
  v9 = acas v0, v2, v1 seq_cst acquire weak
  v10 = acas v0, v3, v4 acq_rel relaxed
  fence seq_cst
  fence acquire
  ret v8
fn @calls
  layout l0 size 16 align 3 [0 i64, 8 f64]
  sig (l0, ptr) -> l0
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = retaddr
  call @calls(v0, v1, v2) : (l0, ptr) -> l0
  v4 = call.i32 @puts(v1) : (ptr) -> i32
  v5 = call.i32 @va(v1, v4, v3) : (ptr, ... i32, ptr) -> i32
  v6 = symaddr @ints
  v7 = iconst.i64 1
  v8 = iconst.i8 -1
  v9 = iconst.i16 2
  v10 = call.ind.i64 v6(v7, v5, v8, v9) : (i64, i32, i8.s, i16) -> i64
  call @"odd name"() : () -> void
  ret
fn @va
  sig (ptr, ...) -> i32
  slot s0 size 32 align 3
b0(v0: ptr):
  v1 = slotaddr s0
  vastart v1
  v2 = vaarg.i32 v1
  vaend v1
  ret v2
fn @vectors
  sig () -> v4i32
b0:
  v0 = wconst.v4f32 0x3f8000003f800000, 0x3f8000003f800000
  v1 = vop.rem.v4f32 (v0, v0)
  v2 = vop.cast.ds.unchecked.v4i32 (v1)
  v3 = vop.shuffle.v4i32 (v2, v2) lanes [3, 2, 5, 0]
  v4 = vop.reduce_add.s.i32 (v3)
  v5 = icmp.slt v4, v4
  br v5, b1, b2
b1: cold
  panic "lane fault" lane v4
b2:
  ret v3
fn @"odd name"
  sig () -> void
b0:
  ret
data @table size 24 align 3 bytes 0102030405060708 reloc 8 @msg+4 reloc 16 @ints-1
data @msg size 6 align 0 ro bytes 68656c6c6f00
data @counter size 8 align 3
)";

@test
fn every_form_of_the_text_reads_back() {
    let p = read_package(FORMS);
    // The calls take their callees' signatures.
    let mut v = verify::Verifier::new();
    for i in 0..p.syms.len() {
        let s = p.syms[i];
        if s.def != NONE && s.kind == SK_FUNC {
            assert(v.check_calls(&p, p.spell(s.name), &p.bodies[s.def as usize]), v.err.as_str());
        }
    }
    // Every opcode, comparison condition and read-modify-write operation, and each machine type as a
    // result.
    let mut ops = Vector::<bool>::new();
    ops.resize_default(OP_COUNT as usize);
    let mut conds = Vector::<bool>::new();
    conds.resize_default(C_COUNT as usize);
    let mut rmws = Vector::<bool>::new();
    rmws.resize_default(6);
    let mut tys = Vector::<bool>::new();
    tys.resize_default(T_PTR as usize + 2);
    for i in 0..p.bodies.len() {
        let b = &p.bodies[i];
        for k in 0..b.insts.len() {
            let t = b.insts[k];
            ops.set(t.op as usize, true);
            if t.op == O_ICMP || t.op == O_FCMP {
                conds.set(t.aux as usize, true);
            }
            if t.op == O_ARMW {
                rmws.set((t.aux >> 4) as usize, true);
            }
            tys.set(ty_slot(t.ty), true);
        }
    }
    for op in 1..OP_COUNT as usize {
        assert(ops[op], op_info(op as u8).name);
    }
    for c in 0..C_COUNT as usize {
        assert(conds[c], cond_name(c as u16));
    }
    for r in 0..6usize {
        assert(rmws[r], rmw_name(r as u16));
    }
    for t in T_I8 as usize..T_PTR as usize + 2 {
        assert(tys[t], "a result of each machine type and a vector");
    }
}

// The coverage slot of result type `t`: its code, a vector's after the pointer's.
const fn ty_slot(t: u8) usize {
    if is_vec(t) {
        return T_PTR as usize + 1;
    }
    return t as usize;
}
