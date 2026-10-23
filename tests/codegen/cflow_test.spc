// CFlow on hand-built control-flow graphs no source construct produces: irreducible loops, whose
// dominators and post-dominators take the iterated rounds after the first.
import ast::ast as *;
import ir::core as ir;
import emit::cflow as cfl;
import lexer::token as tok;

// A body whose block i branches to `succ[off[i] .. off[i + 1]]` through a switch on a local (never
// threaded, never folded), and returns when it has no successor.
fn graph(off: []u32, succ: []u32) ir::CoreBody {
    let ut = Ast::builtin(BuiltinType::BT_I32);
    let sp = tok::Span { start: 0, end: 0 };
    let mut b = ir::CoreBody::new(DefId { module: 0, node: 0 }, 0);
    let l = b.add_local(ir::LocalDecl::anon(ut, ir::LS_TEMP, sp));
    b.places.push(ir::Place { base: l, proj_start: 0, proj_len: 0, ty: ut });
    b.operands.push(ir::Operand { kind: ir::OP_COPY, data: 0, ty: ut });
    for i in 0..off.len() - 1 {
        let x = b.add_block() as usize;
        let k = off[i + 1] - off[i];
        b.blocks[x].sealed = true;
        if k == 0 {
            b.blocks[x].term.kind = ir::TM_RETURN;
            continue;
        }
        b.blocks[x].term.kind = ir::TM_SWITCH;
        b.blocks[x].term.a = 0;
        b.blocks[x].term.sw_start = b.switch_pool.len() as u32;
        b.blocks[x].term.sw_len = k - 1;
        for j in 0..k - 1 {
            b.switch_pool.push(j as u64 << 32 | succ[(off[i] + j) as usize] as u64);
        }
        b.blocks[x].term.t0 = succ[(off[i + 1] - 1) as usize];
    }
    return b;
}

@test
fn two_entry_loop_dominators() {
    // 0 enters the loop {1, 2} at both blocks; both leave it for 3.
    let b = graph([0u32, 2, 4, 6, 6], [1u32, 2, 2, 3, 1, 3]);
    let mut cf = cfl::CFlow::new_empty();
    cf.build_into(&b);
    assert(!cf.reducible, "a loop with two entries is irreducible");
    for x in 1..4 {
        assert_eq(cf.idom[x as usize], 0u32);
        assert_eq(cf.ipdom[(x - 1) as usize], 3u32);
    }
    assert_eq(cf.ipdom[3], 4u32);
}

@test
fn chk_figure_graph_dominators() {
    // The irreducible graph of Cooper, Harvey and Kennedy's figure 4 (blocks 6 5 4 1 2 3 as 0..5),
    // whose dominators take more than one round, and a return after 3 (block 6).
    let b = graph([0u32, 2, 3, 5, 6, 8, 10, 10], [1u32, 2, 3, 4, 5, 4, 3, 5, 4, 6]);
    let mut cf = cfl::CFlow::new_empty();
    cf.build_into(&b);
    assert(!cf.reducible, "the figure's graph is irreducible");
    for x in 1..6 {
        assert_eq(cf.idom[x as usize], 0u32);
    }
    assert_eq(cf.idom[6], 5u32);
    // Post-dominators: every path to the return passes 5; block 1 reaches 5 only through 3 and 4.
    assert_eq(cf.ipdom[0], 5u32);
    assert_eq(cf.ipdom[1], 3u32);
    assert_eq(cf.ipdom[2], 5u32);
    assert_eq(cf.ipdom[3], 4u32);
    assert_eq(cf.ipdom[4], 5u32);
    assert_eq(cf.ipdom[5], 6u32);
    assert_eq(cf.ipdom[6], 7u32);
}

@test
fn chk_figure_reverse_post_dominators() {
    // The figure's graph reversed (its root the exit, its entries the returns 4 and 5), entered at 3:
    // a reducible CFG whose post-dominators take more than one round.
    let b = graph([0u32, 1, 3, 6, 8, 8, 8], [3u32, 2, 5, 1, 4, 3, 2, 4]);
    let mut cf = cfl::CFlow::new_empty();
    cf.build_into(&b);
    assert(cf.reducible, "every cycle has one entry");
    assert_eq(cf.idom[1], 2u32);
    assert_eq(cf.idom[2], 3u32);
    assert_eq(cf.idom[3], 0u32);
    assert_eq(cf.idom[4], 3u32);
    assert_eq(cf.idom[5], 1u32);
    assert_eq(cf.ipdom[0], 3u32);
    for x in 1..6 {
        assert_eq(cf.ipdom[x as usize], 6u32);
    }
}
