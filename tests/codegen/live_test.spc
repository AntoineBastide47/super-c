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
