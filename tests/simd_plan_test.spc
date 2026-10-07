// The vector lowering planner (`emit::simd_plan`) over a fixed synthetic backend table: for each
// operation, lane type and lane count, the chosen form, chunk and entry equal the table below; the
// planner is a pure function of its arguments; a missing entry gives the lane loop.
import ast::ast as *;
import ir::core as ir;
import ir::cpu_features as cf;
import emit::simd_plan as sp;

const SIMD: cf::CpuFeatureSet = cf::CpuFeatureSet { w: [1, 0] };
const RELAXED: cf::CpuFeatureSet = cf::CpuFeatureSet { w: [3, 0] };
const NONE: cf::CpuFeatureSet = cf::CpuFeatureSet { w: [0, 0] };
const F: BuiltinType = BuiltinType::BT_F32;
const I: BuiltinType = BuiltinType::BT_I32;

// One entry of the synthetic table: an operation over `n` lanes of `t`, result `r`.
struct Row {
    pub op: u32,
    pub t: BuiltinType,
    pub n: u64,
    pub fs: cf::CpuFeatureSet,
    pub lanes: bool,
}

// One case: the plan's arguments, then the expected form, chunk lanes and count, and the nodes of the
// entry and of the combining entry (0: none).
struct Case {
    pub op: u32,
    pub t: BuiltinType,
    pub n: u64,
    pub fs: cf::CpuFeatureSet,
    pub checked: bool,
    pub form: u8,
    pub chunk: u64,
    pub chunks: u64,
    pub entry: u32,
    pub combine: u32,
}

const fn simd(c: u8) u32 {
    return ir::OP_SIMD + c as u32;
}

// The table: row `k` is the entry of node `k + 1`, in the table's order.
const ROWS: [Row; 10] = [
    Row { op: ir::OP_ADD, t: F, n: 4, fs: SIMD },
    Row { op: ir::OP_ADD, t: F, n: 8, fs: SIMD }, // the widest chunk for 16 lanes
    Row { op: ir::OP_MUL, t: F, n: 4, fs: SIMD },
    Row { op: ir::OP_MUL, t: F, n: 4, fs: RELAXED }, // the more specific entry
    Row { op: simd(ir::SIMD_REDUCE_ADD_TREE), t: F, n: 4, fs: SIMD },
    Row { op: simd(ir::SIMD_REDUCE_ADD_ORD), t: F, n: 4, fs: SIMD },
    Row { op: simd(ir::SIMD_CONCAT), t: F, n: 4, fs: SIMD },
    Row { op: simd(ir::SIMD_LOAD_MASKED), t: I, n: 4, fs: SIMD, lanes: true }, // a lane access
    Row { op: simd(ir::SIMD_REDUCE_MUL_TREE), t: F, n: 4, fs: SIMD }, // combined by the Mul entries
    Row { op: simd(ir::SIMD_REDUCE_MIN), t: I, n: 4, fs: SIMD }, // no Min entry combines it
];

const CASES: [Case; 16] = [
    Case { op: ir::OP_ADD, t: F, n: 4, fs: SIMD, form: sp::PF_NATIVE, chunk: 4, chunks: 1, entry: 1 },
    Case { op: ir::OP_ADD, t: F, n: 8, fs: SIMD, form: sp::PF_NATIVE, chunk: 8, chunks: 1, entry: 2 },
    Case { op: ir::OP_ADD, t: F, n: 16, fs: SIMD, form: sp::PF_SPLIT, chunk: 8, chunks: 2, entry: 2 },
    Case { op: ir::OP_ADD, t: F, n: 2, fs: SIMD, form: sp::PF_SCALAR, chunk: 2, chunks: 1 },
    Case { op: ir::OP_ADD, t: F, n: 16, fs: NONE, form: sp::PF_SCALAR, chunk: 16, chunks: 1 },
    Case { op: ir::OP_ADD, t: I, n: 4, fs: SIMD, form: sp::PF_SCALAR, chunk: 4, chunks: 1 },
    Case { op: ir::OP_MUL, t: F, n: 4, fs: RELAXED, form: sp::PF_NATIVE, chunk: 4, chunks: 1, entry: 4 },
    Case { op: ir::OP_MUL, t: F, n: 4, fs: SIMD, form: sp::PF_NATIVE, chunk: 4, chunks: 1, entry: 3 },
    Case { op: ir::OP_MUL, t: F, n: 16, fs: SIMD, form: sp::PF_SPLIT, chunk: 4, chunks: 4, entry: 3 },
    // The float tree reduction adds the upper chunks onto the lower ones with its definition's Add.
    Case {
        op: simd(ir::SIMD_REDUCE_ADD_TREE),
        t: F,
        n: 16,
        fs: SIMD,
        form: sp::PF_SPLIT,
        chunk: 4,
        chunks: 4,
        entry: 5,
        combine: 1,
    },
    Case {
        op: simd(ir::SIMD_REDUCE_MUL_TREE),
        t: F,
        n: 8,
        fs: SIMD,
        form: sp::PF_SPLIT,
        chunk: 4,
        chunks: 2,
        entry: 9,
        combine: 3,
    },
    // An ordered reduction, a concatenation, an extreme without its combining entry: never split.
    Case { op: simd(ir::SIMD_REDUCE_ADD_ORD), t: F, n: 8, fs: SIMD, form: sp::PF_SCALAR, chunk: 8, chunks: 1 },
    Case { op: simd(ir::SIMD_CONCAT), t: F, n: 8, fs: SIMD, form: sp::PF_SCALAR, chunk: 8, chunks: 1 },
    Case { op: simd(ir::SIMD_REDUCE_MIN), t: I, n: 8, fs: SIMD, form: sp::PF_SCALAR, chunk: 8, chunks: 1 },
    // A memory checker keeps the checked lane loop of a lane access.
    Case { op: simd(ir::SIMD_LOAD_MASKED), t: I, n: 4, fs: SIMD, form: sp::PF_NATIVE, chunk: 4, chunks: 1, entry: 8 },
    Case {
        op: simd(ir::SIMD_LOAD_MASKED),
        t: I,
        n: 4,
        fs: SIMD,
        checked: true,
        form: sp::PF_SCALAR,
        chunk: 4,
        chunks: 1,
    },
];

fn table() Vector<cf::SimdEntry> {
    let rows: []Row = ROWS;
    let mut t = Vector::<cf::SimdEntry>::new();
    for k in 0..rows.len() {
        let r = rows[k];
        let key = r.op as u64 | r.t as u64 << 16 | r.t as u64 << 24 | r.n << 32;
        t.push(cf::SimdEntry { key: key, fs: r.fs, module: 0, node: k as u32 + 1, lanes: r.lanes });
    }
    t.sort_by(sp::entry_cmp);
    return t;
}

// The node of the entry a plan names (`combine`: of its combining entry), 0 for none.
fn node_of(t: &Vector<cf::SimdEntry>, pl: &sp::Plan, combine: bool) u32 {
    if pl.form == sp::PF_SCALAR || combine && pl.combine == ir::IR_NONE {
        return 0;
    }
    return t.at(pick(combine, pl.combine, pl.entry) as usize).node;
}

@test
fn plans_match_the_table() {
    let t = table();
    let cases: []Case = CASES;
    for k in 0..cases.len() {
        let c = cases[k];
        let pl = sp::plan(&t, c.fs, c.checked, c.op, c.t, c.t, c.n);
        let again = sp::plan(&t, c.fs, c.checked, c.op, c.t, c.t, c.n);
        let comb = node_of(&t, &pl, true);
        let ok = pl.form == c.form && pl.chunk_lanes == c.chunk && pl.chunks == c.chunks && node_of(&t, &pl, false) == c.entry && comb == c.combine;
        if !ok {
            eprintln(
                "case {}: form {} chunk {} x {} entry {} combine {}",
                k,
                pl.form,
                pl.chunk_lanes,
                pl.chunks,
                node_of(&t, &pl, false),
                comb,
            );
        }
        assert(ok, "the plan of a case");
        assert(
            pl.form == again.form && pl.entry == again.entry && pl.combine == again.combine && pl.chunk_lanes == again.chunk_lanes && pl.chunks == again.chunks,
            "the same arguments give the same plan",
        );
    }
}

// The result's lane type is part of the key: a cast to `i32` lanes does not plan a cast to `u32`.
@test
fn the_result_type_selects_the_entry() {
    let mut t = Vector::<cf::SimdEntry>::new();
    let key = ir::OP_CAST as u64 | F as u64 << 16 | I as u64 << 24 | 4u64 << 32;
    t.push(cf::SimdEntry { key: key, fs: SIMD, module: 0, node: 1, lanes: false });
    assert(sp::plan(&t, SIMD, false, ir::OP_CAST, F, I, 4).form == sp::PF_NATIVE, "f32 to i32");
    assert(sp::plan(&t, SIMD, false, ir::OP_CAST, F, BuiltinType::BT_U32, 4).form == sp::PF_SCALAR, "f32 to u32");
    assert(sp::plan(&t, SIMD, false, ir::OP_CAST, F, I, 8).form == sp::PF_SPLIT, "eight lanes in two chunks");
}
