// Register allocation facts over parsed LIR, including folded operand uses and the register plan.
import lir::ir as *;
import lir::parse as lparse;
import codegen::live as lv;

// `Live::assign` over `b` with the callee-saved registers `xc`, the caller-saved ones `xs` and the ones
// that pass arguments too `xw`; no parameter arrives in a register.
fn plan(live: &mut lv::Live, b: &Body, want: &Vector<u8>, xc: u64, xs: u64, xw: u64) {
    plan_paired(live, b, want, xc, xs, xw, 0);
}

// `plan` where each register of `pair` is saved together with the next one.
fn plan_paired(live: &mut lv::Live, b: &Body, want: &Vector<u8>, xc: u64, xs: u64, xw: u64, pair: u64) {
    let mut arr = Vector::<u64>::new();
    arr.resize_default(b.blocks[0].param_len as usize + 1);
    let n = (xc | xs | xw).count_ones() as u32;
    live.assign(
        b,
        want,
        lv::Caps { xc: xc.count_ones() as u32, xs: xs.count_ones() as u32, xj: n.max(1), vc: 0, vs: 0, vj: 0, vu: 0 },
        lv::Sets { xc: xc, xs: xs, xw: xw, vc: 0, vs: 0, xa: 0, vu: 0, first: 0, pair: pair },
        &arr,
        0,
    );
}

// The register the plan gives value index `x` in block `k`; `REG_NONE` when it holds none there.
const fn reg_in(live: &lv::Live, x: usize, k: usize) u8 {
    let s = live.seg_of(x as u32, live.pos[k]);
    return if s == NONE {
        lv::REG_NONE
    } else {
        live.seg_r[s as usize]
    };
}

// One register holds the values that are live at no common position: a loop counter's first value, the
// header parameter the entry passes it to, and the step the back edge passes (which reads the parameter
// last), so no edge moves anything. A value live with them has no register.
@test
fn a_counter_its_entry_value_and_its_step_share_one_register() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = add.i64 v0, v0
  jmp b1(v1)
b1(v3: i64):
  v4 = iconst.i64 1
  v5 = add.i64 v3, v4
  v6 = icmp.ult v5, v2
  br v6, b1(v5), b2
b2:
  v7 = add.i64 v5, v2
  ret v7
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    let mut live = lv::Live::new();
    live.run(b);
    let ni = b.insts.len();
    let mut want = Vector::<u8>::new();
    want.resize_default(live.end.len());
    // Instruction 0 is the first value, instruction 4 the step; the header's parameter is the second one.
    assert(b.insts[4].op == O_ADD && b.insts[1].op == O_ADD, "the step and the bound");
    want[0] = lv::WANT_SCRATCH;
    want[4] = lv::WANT_SCRATCH;
    want[ni + 1] = lv::WANT_SCRATCH;
    want[1] = lv::WANT_SCRATCH;
    plan(&mut live, b, &want, 0, 1 << 9, 0);
    assert_eq(reg_in(&live, 0, 0), 9);
    assert_eq(reg_in(&live, ni + 1, 1), 9);
    assert_eq(reg_in(&live, 4, 1), 9);
    assert_eq(reg_in(&live, 4, 2), 9);
    assert(!live.seg_val(1), "the bound, live with the counter, has no register");
    // A second register holds the bound over all of its blocks.
    plan(&mut live, b, &want, 0, 3 << 9, 0);
    assert_eq(reg_in(&live, 4, 1), reg_in(&live, ni + 1, 1));
    assert(reg_in(&live, 1, 0) != lv::REG_NONE && reg_in(&live, 1, 0) == reg_in(&live, 1, 2), "the bound's");
    assert(reg_in(&live, 1, 1) != reg_in(&live, 4, 1), "two registers");
}

// A value that lives through a loop's call and has no callee-saved register takes a caller-saved one over
// the blocks that do not call (`Live::spans`): the call's block is out, and the value keeps a stack home.
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
    let np = live.order.len();
    let mut want = Vector::<u8>::new();
    want.resize_default(live.end.len());
    want[0] = lv::WANT_CALLEE | lv::WANT_SCRATCH;
    // The call is instruction 5, in block 2.
    fill(&mut live.cfirst, np, NONE);
    fill(&mut live.clast, np, NONE);
    live.cfirst[live.pos[2] as usize] = 5;
    live.clast[live.pos[2] as usize] = 5;
    plan(&mut live, b, &want, 0, 1 << 9, 0);
    assert(live.seg_val(0), "the value has a segment");
    assert_eq(reg_in(&live, 0, 0), 9);
    assert_eq(reg_in(&live, 0, 1), 9);
    assert_eq(reg_in(&live, 0, 2), lv::REG_NONE);
    assert_eq(reg_in(&live, 0, 3), 9);
    assert(live.seg_mem[0], "the call's block reads it from its stack home");
    // A block that nothing writes the argument registers in may hold it in one of them, when the narrow
    // class has no register.
    fill(&mut live.wfirst, np, NONE);
    fill(&mut live.wlast, np, NONE);
    live.wfirst[live.pos[2] as usize] = 5;
    live.wlast[live.pos[2] as usize] = 5;
    fill(&mut live.scap, np, 4);
    plan(&mut live, b, &want, 0, 0, 1 << 1);
    assert_eq(reg_in(&live, 0, 1), 1);
    assert_eq(reg_in(&live, 0, 2), lv::REG_NONE);
}

// A loop header's parameter takes its entry value's register only where the block's joint cap leaves it
// one: `v2` holds one in `b0` (cap 2) beside `v0`, and the loop (cap 1) holds one of `v0` and `v3`.
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
    plan(&mut live, b, &want, 1 << 3 | 1 << 5, 0, 0);
    assert(reg_in(&live, 1, 0) != lv::REG_NONE, "the entry value holds a register");
    assert_eq((reg_in(&live, ni, 1) != lv::REG_NONE) as u32 + (reg_in(&live, ni + 1, 1) != lv::REG_NONE) as u32, 1);
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
// second loop, and a lighter value that the second loop reads across its call: the plan gives the
// register to the first value over all of its blocks, then takes it out of the blocks where the second
// value lives, which the first is idle in (`Live::evict`): the first value holds the register through
// the first loop and after the second (the edge out of that loop loads it), the second value holds it in
// the block that enters the second loop and in the loop. With two registers each value keeps one over
// all of its blocks.
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
    plan(&mut live, b, &want, 1 << 19, 0, 0);
    assert(live.seg_val(0) && live.seg_mem[0], "the first value has a segment and a stack home");
    assert_eq(reg_in(&live, 0, 0), 19);
    assert_eq(reg_in(&live, 0, 1), 19);
    assert_eq(reg_in(&live, 0, 2), lv::REG_NONE);
    assert_eq(reg_in(&live, 0, 3), lv::REG_NONE);
    assert_eq(reg_in(&live, 0, 4), 19);
    assert_eq(reg_in(&live, 7, 2), 19);
    assert_eq(reg_in(&live, 7, 3), 19);
    assert(!live.seg_mem[7], "the second value holds it over all of its blocks");
    plan(&mut live, b, &want, 3 << 19, 0, 0);
    assert(!live.seg_mem[0] && !live.seg_mem[7], "a register for each");
    assert(reg_in(&live, 0, 3) != lv::REG_NONE && reg_in(&live, 0, 3) != reg_in(&live, 7, 3), "two registers");
}

// A block parameter without a home that the block after its own reads first (that block continues the
// parameter's: no other block enters it) is loaded there, as the edges into the parameter's block store
// it: a register over the two blocks saves that load (`Live::spans`), so the parameter holds one.
@test
fn a_parameter_first_read_past_its_block_holds_a_register() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = add.i64 v1, v1
  jmp b1(v0)
b1(v3: i64):
  v4 = icmp.ult v2, v1
  br v4, b2, b3
b2:
  v5 = add.i64 v3, v2
  v6 = add.i64 v5, v2
  jmp b1(v6)
b3:
  ret v2
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    let mut live = lv::Live::new();
    live.run(b);
    let np = live.order.len();
    let x = b.insts.len() + 2;
    let mut want = Vector::<u8>::new();
    want.resize_default(live.end.len());
    // The sum holds the one home; the loop's parameter asks one too.
    want[0] = lv::WANT_SCRATCH;
    want[x] = lv::WANT_SCRATCH;
    fill(&mut live.cfirst, np, NONE);
    fill(&mut live.clast, np, NONE);
    fill(&mut live.wfirst, np, NONE);
    fill(&mut live.wlast, np, NONE);
    fill(&mut live.scap, np, 2);
    plan(&mut live, b, &want, 0, 1 << 9, 1 << 1);
    assert_eq(reg_in(&live, 0, 0), 9);
    assert_eq(reg_in(&live, 0, 3), 9);
    assert(live.seg_val(x as u32), "the parameter has a segment");
    assert_eq(reg_in(&live, x, 1), 1);
    assert_eq(reg_in(&live, x, 2), 1);
}

// A block past a chain of branches longer than the entry's count has halvings still runs (`Live::
// frequencies`: a share of at least 1), and a loop there runs more: a value without a home that the loop
// reads gains from a register over it. With a frequency of 0 no span would gain.
@test
fn a_loop_past_a_long_chain_of_branches_still_weighs() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = icmp.eq v0, v1
  v3 = add.i64 v1, v1
  br v2, b1, b26
b1:
  br v2, b2, b26
b2:
  br v2, b3, b26
b3:
  br v2, b4, b26
b4:
  br v2, b5, b26
b5:
  br v2, b6, b26
b6:
  br v2, b7, b26
b7:
  br v2, b8, b26
b8:
  br v2, b9, b26
b9:
  br v2, b10, b26
b10:
  br v2, b11, b26
b11:
  br v2, b12, b26
b12:
  br v2, b13, b26
b13:
  br v2, b14, b26
b14:
  br v2, b15, b26
b15:
  br v2, b16, b26
b16:
  br v2, b17, b26
b17:
  br v2, b18, b26
b18:
  br v2, b19, b26
b19:
  br v2, b20, b26
b20:
  br v2, b21, b26
b21:
  br v2, b22, b26
b22:
  br v2, b23, b26
b23:
  v4 = add.i64 v0, v3
  jmp b24(v0)
b24(v5: i64):
  v6 = add.i64 v5, v4
  v7 = icmp.ult v6, v1
  br v7, b25, b26
b25:
  jmp b24(v6)
b26:
  ret v3
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    let mut live = lv::Live::new();
    live.run(b);
    let np = live.order.len();
    // `v3` is instruction 1; `v4`, after the entry's three instructions and the chain's 22 branches, 25.
    let x: usize = 25;
    assert(b.insts[x].op == O_ADD && b.insts[x + 1].op == O_JMP, "the value the loop reads");
    let mut want = Vector::<u8>::new();
    want.resize_default(live.end.len());
    want[1] = lv::WANT_SCRATCH;
    want[x] = lv::WANT_SCRATCH;
    fill(&mut live.cfirst, np, NONE);
    fill(&mut live.clast, np, NONE);
    fill(&mut live.wfirst, np, NONE);
    fill(&mut live.wlast, np, NONE);
    fill(&mut live.scap, np, 2);
    plan(&mut live, b, &want, 0, 1 << 9, 1 << 1);
    assert(live.seg_val(1) && !live.seg_mem[1], "the first value's register");
    assert(live.seg_val(x as u32), "the value has a segment over the loop");
    assert_eq(reg_in(&live, x, 24), 1);
}

// A conversion between integers takes the register of its operand when that ends there (`over_inst`): a
// loaded 32-bit value and its extension, live in turn, hold the one register.
@test
fn an_extension_takes_its_operands_register() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i32 v0 align 2
  jmp b1
b1:
  v2 = zext.i64 v1
  jmp b2
b2:
  v3 = add.i64 v2, v2
  ret v3
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    let mut live = lv::Live::new();
    live.run(b);
    let mut want = Vector::<u8>::new();
    want.resize_default(live.end.len());
    // Instruction 0 is the load, instruction 2 the extension.
    assert(b.insts[2].op == O_ZEXT, "the extension");
    want[0] = lv::WANT_SCRATCH;
    want[2] = lv::WANT_SCRATCH;
    plan(&mut live, b, &want, 0, 1 << 9, 0);
    assert_eq(reg_in(&live, 0, 0), 9);
    assert_eq(reg_in(&live, 0, 1), 9);
    assert_eq(reg_in(&live, 2, 1), 9);
    assert_eq(reg_in(&live, 2, 2), 9);
}

// A pointer plus a constant and a widening sum write their result over their first operand (`over_inst`):
// with one register of each kind, a loaded pointer and its step hold the one, the accumulator and the sum
// the other.
@test
fn a_pointer_step_and_a_widening_sum_take_their_operands_registers() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.ptr v0 align 3
  v2 = load.v4i32 v0+16 align 2
  jmp b1
b1:
  v3 = load.v16i8 v1 align 0
  v4 = ptradd v1+16
  v5 = vsumw.v4i32 v2, v3
  jmp b2
b2:
  v6 = load.i32 v4 align 2
  v7 = vop.reduce_add.i32 (v5)
  v8 = add.i32 v6, v7
  ret v8
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    let mut live = lv::Live::new();
    live.run(b);
    let mut want = Vector::<u8>::new();
    want.resize_default(live.end.len());
    // Instructions 0 and 1 are the loads of the entry, 4 the step, 5 the sum.
    assert(b.insts[4].op == O_PTRADD && b.insts[5].op == O_VSUMW, "the step and the sum");
    want[0] = lv::WANT_SCRATCH;
    want[4] = lv::WANT_SCRATCH;
    want[1] = lv::WANT_SCRATCH | lv::WANT_V;
    want[5] = lv::WANT_SCRATCH | lv::WANT_V;
    let mut arr = Vector::<u64>::new();
    arr.resize_default(2);
    live.assign(
        b,
        &want,
        lv::Caps { xc: 0, xs: 1, xj: 1, vc: 0, vs: 1, vj: 1, vu: 0 },
        lv::Sets { xc: 0, xs: 1 << 9, xw: 0, vc: 0, vs: 1 << 48, xa: 0, vu: 0, first: 0, pair: 0 },
        &arr,
        0,
    );
    assert_eq(reg_in(&live, 0, 1), 9);
    assert_eq(reg_in(&live, 4, 1), 9);
    assert_eq(reg_in(&live, 4, 2), 9);
    assert_eq(reg_in(&live, 1, 1), 48);
    assert_eq(reg_in(&live, 5, 1), 48);
    assert_eq(reg_in(&live, 5, 2), 48);
}

// `sel`: a comparison of two loaded values and the select of them, which reads the first loaded value
// last, as its false side; the select's result is read in the next block.
fn sel_body(err: &mut String) Package {
    return lparse::parse(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = load.i64 v0+8 align 3
  jmp b1
b1:
  v3 = icmp.ult v1, v2
  v4 = select.i64 v3, v2, v1
  jmp b2
b2:
  v5 = add.i64 v4, v4
  ret v5
)",
        err,
    ).unwrap();
}

// On a target that reads every operand before it writes the result (`Live.three`), a result takes the
// register of any operand that ends at its instruction: a select and its false side hold the one register.
// Without it only the first operand gives its register (`over_inst`), and one of the two has none there.
@test
fn on_a_three_address_target_a_result_takes_any_ending_operands_register() {
    let mut err = String::new();
    let p = sel_body(&mut err);
    let b = &p.bodies[0];
    // Instruction 0 is the first load, instruction 4 the select.
    assert(b.insts[4].op == O_SELECT, "the select");
    for three in 0..2u32 {
        let mut live = lv::Live::new();
        live.three = three == 1;
        live.run(b);
        let mut want = Vector::<u8>::new();
        want.resize_default(live.end.len());
        want[0] = lv::WANT_SCRATCH;
        want[4] = lv::WANT_SCRATCH;
        plan(&mut live, b, &want, 0, 1 << 9, 0);
        let both = reg_in(&live, 0, 1) == 9 && reg_in(&live, 4, 1) == 9;
        assert_eq(both, three == 1);
    }
}

// A register one value alone holds in a block, which no edge out of the block writes, is the block's
// `solo` (a temporary may take it when the value ends): the loaded value's in the entry, the select's in
// the last block; in the block between both hold it in turn.
@test
fn a_register_one_value_holds_in_a_block_is_solo() {
    let mut err = String::new();
    let p = sel_body(&mut err);
    let b = &p.bodies[0];
    let mut live = lv::Live::new();
    live.three = true;
    live.run(b);
    let mut want = Vector::<u8>::new();
    want.resize_default(live.end.len());
    want[0] = lv::WANT_SCRATCH;
    want[4] = lv::WANT_SCRATCH;
    plan(&mut live, b, &want, 0, 1 << 9, 0);
    assert_eq(live.solo[live.pos[0] as usize], 1 << 9);
    assert_eq(live.solo[live.pos[1] as usize], 0);
    assert_eq(live.solo[live.pos[2] as usize], 1 << 9);
    assert_eq(live.bmask[live.pos[1] as usize], 1 << 9);
}

// A load of one part of an aggregate the body takes in registers is in its part's register when it is
// made (`Live.part_in`): the plan leaves it there. Without that the registers the aggregate arrives in
// are held to its last load, and the first load takes another.
@test
fn a_load_of_a_part_stays_in_the_register_it_arrives_in() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = load.i64 v0+8 align 3
  jmp b1
b1:
  v3 = add.i64 v1, v2
  ret v3
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    for known in 0..2u32 {
        let mut live = lv::Live::new();
        live.run(b);
        let mut want = Vector::<u8>::new();
        want.resize_default(live.end.len());
        want[0] = lv::WANT_SCRATCH;
        want[1] = lv::WANT_SCRATCH;
        // The aggregate arrives in registers 0 and 1.
        let mut arr = Vector::<u64>::new();
        arr.push(3);
        arr.push(0);
        if known == 1 {
            fill(&mut live.part_in, live.end.len(), lv::REG_NONE);
            live.part_in[0] = 0;
            live.part_in[1] = 1;
        }
        live.assign(
            b,
            &want,
            lv::Caps { xc: 0, xs: 4, xj: 4, vc: 0, vs: 0, vj: 0, vu: 0 },
            lv::Sets { xc: 0, xs: 15, xw: 0, vc: 0, vs: 0, xa: 0, vu: 0, first: 0, pair: 0 },
            &arr,
            0,
        );
        assert_eq(reg_in(&live, 0, 0) == 0, known == 1);
        if known == 1 {
            assert_eq(reg_in(&live, 1, 0), 1);
        }
    }
}

// A loop's parameter lives across a call; its step, made after the call, is read more often (three times
// in the loop, the parameter twice). The
// parameter is ordered no later than the step that replaces it, so it takes the callee-saved register
// first and the step follows it there: the back edge moves nothing.
@test
fn a_step_heavier_than_its_parameter_follows_it() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 8
sym @fib fn global
fn @fib
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  jmp b1(v0, v1)
b1(v2: i32, v3: i32):
  v4 = iconst.i32 1
  v5 = sub.i32 v2, v4
  v6 = call.i32 @fib(v5) : (i32) -> i32
  v7 = iconst.i32 2
  v8 = sub.i32 v2, v7
  v9 = add.i32 v3, v6
  v10 = add.i32 v9, v8
  v11 = xor.i32 v10, v8
  v12 = icmp.uge v8, v7
  br v12, b1(v8, v11), b2
b2:
  v13 = add.i32 v11, v8
  ret v13
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    let mut live = lv::Live::new();
    live.run(b);
    let np = live.order.len();
    let ni = b.insts.len();
    let mut want = Vector::<u8>::new();
    want.resize_default(live.end.len());
    // The call is instruction 4, the step instruction 6; the loop's first parameter is value `ni + 1`.
    assert(b.insts[4].op == O_CALL && b.insts[6].op == O_SUB, "the call and the step");
    want[ni + 1] = lv::WANT_CALLEE | lv::WANT_SCRATCH;
    want[6] = lv::WANT_CALLEE | lv::WANT_SCRATCH;
    fill(&mut live.cfirst, np, NONE);
    fill(&mut live.clast, np, NONE);
    live.cfirst[live.pos[1] as usize] = 4;
    live.clast[live.pos[1] as usize] = 4;
    plan(&mut live, b, &want, 1 << 19, 1 << 9, 0);
    assert_eq(reg_in(&live, ni + 1, 1), 19);
    assert_eq(reg_in(&live, 6, 1), 19);
}

// A loop's parameter and the step that replaces it, which reads no parameter and weighs more, with no
// call: the heaviest value takes the first register while the parameter lives, and ends before the step.
// The parameter is ordered no later than the step, so it takes the second register and the step follows
// it there. The step placed first would take the first register, which the parameter cannot hold, and
// the back edge would copy it.
@test
fn a_step_that_reads_no_parameter_follows_its_parameter() {
    let mut err = String::new();
    let p = lparse::parse(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  jmp b1(v0)
b1(v2: i64):
  v3 = add.i64 v1, v1
  v4 = add.i64 v3, v3
  v5 = xor.i64 v2, v3
  v6 = mul.i64 v5, v4
  v7 = icmp.ult v6, v1
  br v7, b1(v6), b2
b2:
  ret v6
)",
        &mut err,
    ).unwrap();
    let b = &p.bodies[0];
    let mut live = lv::Live::new();
    live.run(b);
    let ni = b.insts.len();
    let mut want = Vector::<u8>::new();
    want.resize_default(live.end.len());
    // Instruction 1 is the heaviest value, instruction 4 the step; the loop's parameter is value `ni + 2`.
    assert(b.insts[1].op == O_ADD && b.insts[4].op == O_MUL, "the heaviest value and the step");
    want[1] = lv::WANT_SCRATCH;
    want[4] = lv::WANT_SCRATCH;
    want[ni + 2] = lv::WANT_SCRATCH;
    plan(&mut live, b, &want, 0, 3 << 9, 0);
    assert_eq(reg_in(&live, 1, 1), 9);
    assert_eq(reg_in(&live, ni + 2, 1), 10);
    assert_eq(reg_in(&live, 4, 1), 10);
}

// A callee-saved register the body does not save yet costs two entries (`SAVE_COST`); the other register
// of a pair the body saves costs nothing (`Sets.pair`). A value made and read twice on one side of an
// even branch (one and a half entries), live there with a heavier value that holds x19: it takes x20
// where x19 and x20 are saved together, and no register where each is saved alone.
@test
fn a_value_takes_the_other_register_of_a_saved_pair() {
    for paired in 0..2u32 {
        let mut err = String::new();
        let p = lparse::parse(
            M"(lir ptr 8
sym @g fn global
sym @f fn global
fn @f
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = add.i64 v0, v1
  call @g() : () -> void
  v3 = icmp.ult v2, v1
  br v3, b1, b2
b1:
  v4 = add.i64 v2, v2
  call @g() : () -> void
  v5 = add.i64 v4, v2
  v6 = add.i64 v5, v4
  ret v6
b2:
  ret v2
)",
            &mut err,
        ).unwrap();
        let b = &p.bodies[0];
        let mut live = lv::Live::new();
        live.run(b);
        let mut want = Vector::<u8>::new();
        want.resize_default(live.end.len());
        // Instruction 0 is the heavier value, instruction 4 the lighter one; a call follows each.
        assert(b.insts[0].op == O_ADD && b.insts[1].op == O_CALL, "the heavier value and its call");
        assert(b.insts[4].op == O_ADD && b.insts[5].op == O_CALL, "the lighter value and its call");
        want[0] = lv::WANT_CALLEE;
        want[4] = lv::WANT_CALLEE;
        plan_paired(&mut live, b, &want, 3 << 19, 0, 0, paired as u64 << 19);
        assert_eq(reg_in(&live, 0, 1), 19);
        let r = if paired == 1 {
            20u8
        } else {
            lv::REG_NONE
        };
        assert_eq(reg_in(&live, 4, 1), r);
    }
}

// The frame a generator sets up on the edges into the blocks it lays out last (`set_after`) pays when
// those edges run less often than the entry (`after_into`, `frame_pays`): on one side of an even branch
// it does, also with one value saved around the call there (`around_cost`), not with three; not when the
// entry block is one of those blocks, nor when the block is in a loop.
@test
fn a_frame_on_a_path_pays_when_its_edges_run_less_often_than_the_entry() {
    let texts: [str; 3] = [
        M"(lir ptr 8
sym @g fn global
sym @f fn global
fn @f
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = icmp.eq v0, v1
  br v2, b2, b1
b1:
  v3 = call.i64 @g(v0) : (i64) -> i64
  v4 = add.i64 v3, v0
  ret v4
b2:
  ret v1
)",
        M"(lir ptr 8
sym @g fn global
sym @f fn global
fn @f
  sig (i64) -> i64
b0(v0: i64):
  v1 = call.i64 @g(v0) : (i64) -> i64
  ret v1
)",
        M"(lir ptr 8
sym @g fn global
sym @f fn global
fn @f
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  jmp b1(v1)
b1(v2: i64):
  v3 = icmp.ult v2, v0
  br v3, b2, b4
b2:
  v4 = iconst.i64 1
  v5 = add.i64 v2, v4
  v6 = and.i64 v2, v4
  v7 = icmp.eq v6, v1
  br v7, b3, b1(v5)
b3:
  v8 = call.i64 @g(v5) : (i64) -> i64
  jmp b1(v8)
b4:
  ret v2
)",
    ];
    // Per body, the block that holds the call.
    let blocks: [usize; 3] = [1, 0, 3];
    for k in 0..3usize {
        let mut err = String::new();
        let p = lparse::parse(texts[k], &mut err).unwrap();
        let b = &p.bodies[0];
        let mut live = lv::Live::new();
        live.run(b);
        let mut framed = Vector::<bool>::new();
        framed.resize_default(b.blocks.len());
        framed[blocks[k]] = true;
        // The call is its block's first instruction; in the first body the parameter lives past it.
        let call = b.blocks[blocks[k]].start;
        assert(b.insts[call as usize].op == O_CALL, "the call");
        let around = live.around_cost(&p, b, blocks[k] as u32, call, 1);
        live.set_after(b, &framed);
        let into = live.after_into(b);
        assert_eq(live.frame_pays(into, 0), k == 0);
        if k == 0 {
            assert(around != 0, "the parameter is saved around the call");
            assert(live.frame_pays(into, around), "one value saved around the call");
            assert(!live.frame_pays(into, 3 * around), "three values saved around the call");
        }
    }
}

// On a target whose instructions write over an operand (`Live.two`), a result takes the register of an
// operand that ends at its instruction only when the instruction may be written over it: the second
// operand of a sum (it commutes) gives its register, the second operand of a difference does not.
@test
fn on_a_two_address_target_only_an_operand_that_may_be_overwritten_gives_its_register() {
    for sum in 0..2u32 {
        let text = format(
            M"(lir ptr 8
sym @f fn global
fn @f
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = load.i64 v0+8 align 3
  jmp b1
b1:
  v3 = {}.i64 v2, v1
  jmp b2
b2:
  v4 = add.i64 v3, v3
  ret v4
)",
            if sum == 1 {
                "add"
            } else {
                "sub"
            },
        );
        let mut err = String::new();
        let p = lparse::parse(&text, &mut err).unwrap();
        let b = &p.bodies[0];
        let mut live = lv::Live::new();
        live.three = true;
        live.two = true;
        live.run(b);
        let mut want = Vector::<u8>::new();
        want.resize_default(live.end.len());
        // Instruction 0 is the first load, instruction 3 the sum or the difference.
        want[0] = lv::WANT_SCRATCH;
        want[3] = lv::WANT_SCRATCH;
        plan(&mut live, b, &want, 0, 1 << 9, 0);
        let both = reg_in(&live, 0, 1) == 9 && reg_in(&live, 3, 1) == 9;
        assert_eq(both, sum == 1);
    }
}
