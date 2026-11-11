// Register allocation facts over parsed LIR, including folded operand uses and split prefixes.
import lir::ir as *;
import lir::parse as lparse;
import codegen::live as lv;

@test
fn a_displaced_interval_keeps_its_register_prefix() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i64) -> i64
b0(v0: i64):
  v1 = add.i64 v0, v0
  v2 = icmp.eq v0, v1
  br v2, b1, b2
b1:
  jmp b2
b2:
  v3 = add.i64 v0, v0
  v4 = add.i64 v3, v3
  v5 = add.i64 v3, v4
  jmp b3
b3:
  v6 = add.i64 v1, v5
  ret v6
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    let mut live = lv::Live::new();
    live.run(b);
    live.split = true;
    let mut want = Vector::<u8>::new();
    want.resize_default(live.end.len());
    want[0] = lv::WANT_SCRATCH;
    want[4] = lv::WANT_SCRATCH;
    live.plan(b, &want, lv::Caps { xc: 0, xs: 1, xj: 1, vc: 0, vs: 0, vj: 0 });
    assert_eq(live.home_at(0, live.pos[0]), lv::HOME_SCRATCH);
    assert_eq(live.home_at(0, live.pos[2]), lv::HOME_NONE);
    assert_eq(live.home_at(4, live.pos[2]), lv::HOME_SCRATCH);
    assert_eq(live.splits.len(), 1);
    // A prefix that enters only blocks whose one predecessor comes before them gains nothing: no cut.
    let q = lparse::parse(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i64) -> i64
b0(v0: i64):
  v1 = add.i64 v0, v0
  jmp b1
b1:
  v2 = add.i64 v0, v0
  v3 = add.i64 v2, v2
  v4 = add.i64 v2, v3
  jmp b2
b2:
  v5 = add.i64 v1, v4
  ret v5
)",
        &mut err,
    ).unwrap();
    let c = &q.bodies[0];
    live.run(c);
    want.truncate(0);
    want.resize_default(live.end.len());
    want[0] = lv::WANT_SCRATCH;
    want[2] = lv::WANT_SCRATCH;
    live.plan(c, &want, lv::Caps { xc: 0, xs: 1, xj: 1, vc: 0, vs: 0, vj: 0 });
    assert_eq(live.home_at(0, live.pos[0]), lv::HOME_NONE);
    assert_eq(live.splits.len(), 0);
}

// A value that lives through a loop's call and has no callee-saved register takes a caller-saved one over
// the blocks that do not call (`Live::segments`): the call's block is out, the edge past it joins the
// blocks around it into one span, and the value keeps a stack home. No segment without the generator's
// call tables.
@test
fn a_value_without_a_home_holds_a_register_between_calls() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 8
sym @g fn global
sym @f fn global
fn @f
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = add.i64 v0, v0
  jmp b1(v0)
b1(v3: i64):
  v4 = add.i64 v3, v2
  v5 = icmp.ult v4, v1
  br v5, b2, b3
b2:
  v6 = call.i64 @g(v4) : (i64) -> i64
  jmp b1(v6)
b3:
  v7 = add.i64 v4, v2
  ret v7
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    let mut live = lv::Live::new();
    live.run(b);
    live.split = true;
    let np = live.order.len();
    let mut want = Vector::<u8>::new();
    want.resize_default(live.end.len());
    want[0] = lv::WANT_CALLEE;
    // The call is instruction 5, in block 2.
    fill(&mut live.cfirst, np, NONE);
    fill(&mut live.clast, np, NONE);
    live.cfirst[live.pos[2] as usize] = 5;
    live.clast[live.pos[2] as usize] = 5;
    live.plan(b, &want, lv::Caps { xc: 0, xs: 1, xj: 1, vc: 0, vs: 0, vj: 0 });
    assert_eq(live.home[0], lv::HOME_NONE);
    assert(live.seg_val(0), "the value has a segment");
    assert_eq(live.seg_x.len(), 1);
    assert_eq(live.seg_a[0], live.pos[0]);
    assert_eq(live.seg_b[0], live.pos[3]);
    assert_eq(live.home_at(0, live.pos[0]), lv::HOME_SCRATCH);
    assert_eq(live.home_at(0, live.pos[1]), lv::HOME_SCRATCH);
    assert_eq(live.home_at(0, live.pos[2]), lv::HOME_NONE);
    assert_eq(live.home_at(0, live.pos[3]), lv::HOME_SCRATCH);
    assert(live.seg_mem[0], "the call's block reads it from its stack home");
    // A block that nothing writes the argument registers in may hold it in one of them: the same span,
    // of the wider class when the narrow one has no register left.
    fill(&mut live.wfirst, np, NONE);
    fill(&mut live.wlast, np, NONE);
    live.wfirst[live.pos[2] as usize] = 5;
    live.wlast[live.pos[2] as usize] = 5;
    fill(&mut live.scap, np, 4);
    live.plan(b, &want, lv::Caps { xc: 0, xs: 0, xj: 1, vc: 0, vs: 0, vj: 0 });
    assert_eq(live.seg_x.len(), 1);
    assert_eq(live.seg_h[0], lv::HOME_WIDE);
    assert_eq(live.home_at(0, live.pos[2]), lv::HOME_NONE);
    live.cfirst.truncate(0);
    live.plan(b, &want, lv::Caps { xc: 0, xs: 1, xj: 1, vc: 0, vs: 0, vj: 0 });
    assert(!live.seg_val(0), "no segment without the call tables");
}

// A loop header's parameter shares its entry value's register only where the other homes leave it one
// within the joint cap of the blocks its range covers: `v2` fits in `b0` (cap 2) beside `v0`, the loop
// (cap 1) holds `v0` alone, so `v3` takes no home.
@test
fn a_shared_register_keeps_the_joint_cap_of_the_sharers_blocks() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i64) -> i64
b0(v0: i64):
  v1 = add.i64 v0, v0
  v2 = add.i64 v1, v0
  jmp b1(v2)
b1(v3: i64):
  v4 = add.i64 v3, v0
  v5 = icmp.ult v4, v0
  br v5, b1(v4), b2
b2:
  ret v4
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    let ni = b.insts.len();
    let mut live = lv::Live::new();
    live.run(b);
    let np = live.order.len();
    let mut want = Vector::<u8>::new();
    want.resize_default(live.end.len());
    want[ni] = lv::WANT_CALLEE;
    want[1] = lv::WANT_CALLEE;
    want[ni + 1] = lv::WANT_CALLEE;
    fill(&mut live.jcap, np, 1);
    live.jcap[live.pos[0] as usize] = 2;
    live.plan(b, &want, lv::Caps { xc: 2, xs: 0, xj: 2, vc: 0, vs: 0, vj: 0 });
    assert_eq(live.home[1], lv::HOME_CALLEE);
    assert_eq(live.home_at(ni as u32, live.pos[1]), lv::HOME_CALLEE);
    assert_eq(live.home_at(ni as u32 + 1, live.pos[1]), lv::HOME_NONE);
}

@test
fn next_uses_follow_folded_operands_and_repeated_reads() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (ptr, f64) -> f64
b0(v0: ptr, v1: f64):
  v2 = load.f64 v0 align 0
  v3 = fmul.f64 v1, v2
  v4 = fadd.f64 v3, v3
  ret v4
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    let mut live = lv::Live::new();
    live.fold_max = 8;
    live.fold_ops = lv::FOLD_LDOP;
    live.run(b);
    let ptr = b.insts.len();
    assert(live.pfold[0], "the load is folded");
    assert_eq(live.next[ptr], 1);
    live.advance(b, 0);
    assert_eq(live.next[ptr], 1);
    live.advance(b, 1);
    assert_eq(live.next[ptr], NONE);
    assert_eq(live.next[1], 2);
    live.advance(b, 2);
    assert_eq(live.next[1], NONE);
}

// A select side that truncates a 64-bit value, on a condition over that value: the free truncation fold
// takes only 16- and 32-bit operands, so it stays (and sizing the operand's type does not overflow).
@test
fn a_select_side_truncating_64_bits_stays() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 4
sym @f fn global
fn @f
  sig (i64) -> i8
b0(v0: i64):
  v1 = iconst.i64 200
  v2 = icmp.ult v0, v1
  v3 = trunc.i8 v0
  v4 = iconst.i8 0
  v5 = select.i8 v2, v3, v4
  ret v5
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    let mut live = lv::Live::new();
    live.fold_max = 8;
    live.fold_ops = lv::FOLD_FREE_ZEXT;
    live.run(b);
    assert(!live.pfold[2], "the truncation stays");
}

// One callee-saved register, a value read three times per iteration of a first loop and once after a
// second loop, and a lighter value that the second loop reads across its call: the scan gives the
// register to the first value for its whole range. `Live::seg_evict` splits it around the second loop: it
// holds the register through the first loop, the second value holds it in the block that enters the
// second loop and in the loop, and the block after the loop (an edge from the loop enters it) reads the
// first value from its stack home. With two registers each value keeps a whole home.
@test
fn a_holder_idle_in_a_loop_gives_its_register_to_the_loops_value() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 8
sym @g fn global
sym @f fn global
fn @f
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = add.i64 v0, v0
  jmp b1(v0)
b1(v3: i64):
  v4 = add.i64 v3, v2
  v5 = add.i64 v4, v2
  v6 = add.i64 v5, v2
  v7 = icmp.ult v6, v1
  br v7, b1(v6), b2
b2:
  v8 = add.i64 v1, v1
  jmp b3(v0)
b3(v9: i64):
  v10 = add.i64 v9, v8
  v11 = call.i64 @g(v10) : (i64) -> i64
  v12 = icmp.ult v11, v8
  br v12, b3(v11), b4
b4:
  v13 = add.i64 v11, v2
  ret v13
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    let mut live = lv::Live::new();
    live.run(b);
    live.split = true;
    let np = live.order.len();
    let mut want = Vector::<u8>::new();
    want.resize_default(live.end.len());
    // Instruction 0 is the first value, instruction 7 the second.
    want[0] = lv::WANT_CALLEE;
    want[7] = lv::WANT_CALLEE;
    // The call is instruction 10, in block 3.
    fill(&mut live.cfirst, np, NONE);
    fill(&mut live.clast, np, NONE);
    live.cfirst[live.pos[3] as usize] = 10;
    live.clast[live.pos[3] as usize] = 10;
    live.plan(b, &want, lv::Caps { xc: 1, xs: 0, xj: 1, vc: 0, vs: 0, vj: 0 });
    assert_eq(live.home[0], lv::HOME_NONE);
    assert(live.seg_val(0) && live.seg_mem[0], "the first value has segments and a stack home");
    assert_eq(live.home_at(0, live.pos[0]), lv::HOME_CALLEE);
    assert_eq(live.home_at(0, live.pos[1]), lv::HOME_CALLEE);
    assert_eq(live.home_at(0, live.pos[2]), lv::HOME_NONE);
    assert_eq(live.home_at(0, live.pos[3]), lv::HOME_NONE);
    assert_eq(live.home_at(0, live.pos[4]), lv::HOME_NONE);
    assert_eq(live.home_at(7, live.pos[2]), lv::HOME_CALLEE);
    assert_eq(live.home_at(7, live.pos[3]), lv::HOME_CALLEE);
    live.plan(b, &want, lv::Caps { xc: 2, xs: 0, xj: 2, vc: 0, vs: 0, vj: 0 });
    assert_eq(live.home[0], lv::HOME_CALLEE);
    assert_eq(live.home[7], lv::HOME_CALLEE);
    assert(!live.seg_val(0) && !live.seg_val(7), "no segment with a register for each");
}
