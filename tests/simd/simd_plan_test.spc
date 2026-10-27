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
}

// One case: the plan's arguments, then the expected form, chunk lanes and count, and the nodes of the
// entry and of the combining entry (0: none).
struct Case {
    pub op: u32,
    pub t: BuiltinType,
    pub n: u64,
    pub fs: cf::CpuFeatureSet,
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
    Row { op: simd(ir::SIMD_LOAD_MASKED), t: I, n: 4, fs: SIMD }, // a lane access
    Row { op: simd(ir::SIMD_REDUCE_MUL_TREE), t: F, n: 4, fs: SIMD }, // combined by the Mul entries
    Row { op: simd(ir::SIMD_REDUCE_MIN), t: I, n: 4, fs: SIMD }, // no Min entry combines it
];

const CASES: [Case; 15] = [
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
    // A lane access takes its entry.
    Case { op: simd(ir::SIMD_LOAD_MASKED), t: I, n: 4, fs: SIMD, form: sp::PF_NATIVE, chunk: 4, chunks: 1, entry: 8 },
];

fn table() Vector<cf::SimdEntry> {
    let rows: []Row = ROWS;
    let mut t = Vector::<cf::SimdEntry>::new();
    for k in 0..rows.len() {
        let r = rows[k];
        let key = r.op as u64 | r.t as u64 << 16 | r.t as u64 << 24 | r.n << 32;
        t.push(cf::SimdEntry { key: key, fs: r.fs, module: 0, node: k as u32 + 1 });
    }
    t.sort_by(sp::entry_cmp);
    return t;
}

// The node of the entry a plan names (`combine`: of its combining entry), 0 for none.
const fn node_of(t: &Vector<cf::SimdEntry>, pl: &sp::Plan, combine: bool) u32 {
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
        let pl = sp::plan(&t, c.fs, c.op, c.t, c.t, c.n, 256);
        let again = sp::plan(&t, c.fs, c.op, c.t, c.t, c.n, 256);
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
    t.push(cf::SimdEntry { key: key, fs: SIMD, module: 0, node: 1 });
    assert(sp::plan(&t, SIMD, ir::OP_CAST, F, I, 4, 256).form == sp::PF_NATIVE, "f32 to i32");
    assert(sp::plan(&t, SIMD, ir::OP_CAST, F, BuiltinType::BT_U32, 4, 256).form == sp::PF_SCALAR, "f32 to u32");
    assert(sp::plan(&t, SIMD, ir::OP_CAST, F, I, 8, 256).form == sp::PF_SPLIT, "eight lanes in two chunks");
}

// On AVX-512 the planner prefers 256-bit entries: a lane-wise operation over 512 bits splits into
// 256-bit chunks unless the preferred width is 512; an operation that cannot split (`compress`)
// takes its 512-bit entry rather than the lane loop.
@test
fn the_preferred_width_splits_what_splits() {
    let z = cf::close(cf::with(NONE, cf::F_AVX512F));
    let mut t = Vector::<cf::SimdEntry>::new();
    let add = ir::OP_ADD as u64 | F as u64 << 16 | F as u64 << 24;
    let cmp = simd(ir::SIMD_COMPRESS) as u64 | I as u64 << 16 | I as u64 << 24 | 16u64 << 32;
    t.push(cf::SimdEntry { key: add | 8u64 << 32, fs: z, module: 0, node: 1 });
    t.push(cf::SimdEntry { key: add | 16u64 << 32, fs: z, module: 0, node: 2 });
    t.push(cf::SimdEntry { key: cmp, fs: z, module: 0, node: 3 });
    t.sort_by(sp::entry_cmp);
    let s = sp::plan(&t, z, ir::OP_ADD, F, F, 16, 256);
    assert(s.form == sp::PF_SPLIT && s.chunk_lanes == 8, "two 256-bit chunks");
    assert(sp::plan(&t, z, ir::OP_ADD, F, F, 16, 512).form == sp::PF_NATIVE, "512 bits");
    let c = sp::plan(&t, z, simd(ir::SIMD_COMPRESS), I, I, 16, 256);
    assert(c.form == sp::PF_NATIVE && t.at(c.entry as usize).node == 3, "no split: the 512-bit entry");
}

// A gather widens its indexes to 64 bits: at the 256-bit preference an AVX-512 gather of 8 lanes
// (512-bit indexes) gives way to the AVX2 one; at 512 the larger feature set wins.
@test
fn a_gather_counts_its_index_width() {
    let z = cf::close(cf::with(NONE, cf::F_AVX512F));
    let a2 = cf::close(cf::with(NONE, cf::find_variant("Avx2") as usize));
    let mut t = Vector::<cf::SimdEntry>::new();
    let key = simd(ir::SIMD_GATHER) as u64 | F as u64 << 16 | BuiltinType::BT_U32 as u64 << 24 | 8u64 << 32;
    t.push(cf::SimdEntry { key: key, fs: z, module: 0, node: 1 });
    t.push(cf::SimdEntry { key: key, fs: a2, module: 0, node: 2 });
    t.sort_by(sp::entry_cmp);
    let g = simd(ir::SIMD_GATHER);
    assert(t.at(sp::find(&t, z, g, F, BuiltinType::BT_U32, 8, 256) as usize).node == 2, "the AVX2 gather");
    assert(t.at(sp::find(&t, z, g, F, BuiltinType::BT_U32, 8, 512) as usize).node == 1, "the AVX-512 gather");
}
