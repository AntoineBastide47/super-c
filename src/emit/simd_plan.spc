// The vector lowering planner: for one vector operation of one lane type and lane count, the
// hardware entry of the backend table (`Package::simd_table`, the `@simd_impl` functions) the
// renderer calls, the chunk entry it calls once per chunk, or the scalar lane loop. A pure function
// of its arguments and the table: no global state, no worker order. Features select instructions
// only, so every form gives the operation's language result.
import ast::ast as *;
import ir::core as ir;
import ir::cpu_features as cf;

pub const PF_SCALAR: u8 = 0;
pub const PF_NATIVE: u8 = 1;
pub const PF_SPLIT: u8 = 2;

/// The lowering of one operation: `form`, the entry (a `simd_table` index; for PF_SPLIT the entry of
/// one chunk of `chunk_lanes` lanes, called `chunks` times in lane order), and for a split reduction
/// `combine`, the lane-wise entry that adds the upper half of the chunks onto the lower half
/// (IR_NONE otherwise).
pub struct Plan {
    pub form: u8,
    pub entry: u32,
    pub combine: u32,
    pub chunk_lanes: u64,
    pub chunks: u64,
}

/// The backend table's order (`Package::simd_table`): by key, then by feature count, the largest first,
/// then by declaration.
pub fn entry_cmp(x: &cf::SimdEntry, y: &cf::SimdEntry) i32 {
    if x.key != y.key {
        return pick(x.key < y.key, -1, 1);
    }
    let cx = cf::count(x.fs);
    let cy = cf::count(y.fs);
    if cx != cy {
        return pick(cx > cy, -1, 1);
    }
    return pick((x.module as u64 << 32 | x.node as u64) < (y.module as u64 << 32 | y.node as u64), -1, 1);
}

/// The table index of the entry for `op` over `n` lanes of `t` with result lane or scalar type `r`
/// whose features `fs` holds, the one with the most features; -1 when none. Under a memory checker
/// (`checked`) an entry that touches memory in active lanes only (`SimdEntry.lanes`) is never one:
/// the checked lane loop reports an inactive lane's access, a binding could not.
pub fn find(
    tab: &Vector<cf::SimdEntry>,
    fs: cf::CpuFeatureSet,
    checked: bool,
    op: u32,
    t: BuiltinType,
    r: BuiltinType,
    n: u64,
) i64 {
    let key = op as u64 | t as u64 << 16 | r as u64 << 24 | n << 32;
    let mut lo: usize = 0;
    let mut hi = tab.len();
    while lo < hi {
        let mid = (lo + hi) / 2;
        if tab.at(mid).key < key {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    while lo < tab.len() && tab.at(lo).key == key {
        if cf::contains(fs, tab.at(lo).fs) && !(checked && tab.at(lo).lanes) {
            return lo as i64;
        }
        lo += 1;
    }
    return -1;
}

/// How operation `op` (`ir::OP_*`) over `lanes` lanes of `t`, with result lane or scalar type `r`, lowers
/// under features `fs` (`checked`: under a memory checker): the entry for all the lanes, else the
/// widest chunk an entry exists for when the chunks combine (lane-wise operations, and the
/// reductions `combine_op` names), else the lane loop.
pub fn plan(
    tab: &Vector<cf::SimdEntry>,
    fs: cf::CpuFeatureSet,
    checked: bool,
    op: u32,
    t: BuiltinType,
    r: BuiltinType,
    lanes: u64,
) Plan {
    let mut p = Plan { form: PF_SCALAR, entry: 0, combine: ir::IR_NONE, chunk_lanes: lanes, chunks: 1 };
    let e = find(tab, fs, checked, op, t, r, lanes);
    if e >= 0 {
        p.form = PF_NATIVE;
        p.entry = e as u32;
        return p;
    }
    let cop = combine_op(op);
    if !lane_wise(op) && cop == ir::OP_COUNT {
        return p;
    }
    let mut c = lanes / 2;
    while c >= 1 {
        let ce = find(tab, fs, checked, op, t, r, c);
        let ke = if cop == ir::OP_COUNT {
            0i64;
        } else {
            find(tab, fs, checked, cop, t, t, c);
        };
        if ce >= 0 && ke >= 0 {
            p.form = PF_SPLIT;
            p.entry = ce as u32;
            p.combine = pick(cop == ir::OP_COUNT, ir::IR_NONE, ke as u32);
            p.chunk_lanes = c;
            p.chunks = lanes / c;
            return p;
        }
        c /= 2;
    }
    return p;
}

// Whether lane `i` of operation `op`'s result reads lane `i` of its vector operands only: its chunks
// are independent.
fn lane_wise(op: u32) bool {
    if op < ir::OP_SIMD || op >= ir::OP_CMP_LANES {
        return op != ir::OP_ANY_LANES && op != ir::OP_ALL_LANES;
    }
    let c = (op - ir::OP_SIMD) as u8;
    let r = ir::simd_op(c).rule;
    return r == ir::SR_VEC || r == ir::SR_MASK || r == ir::SR_CHOOSE || r == ir::SR_LANES || r == ir::SR_CHANGED || r == ir::SR_LOAD || r == ir::SR_STORE || c == ir::SIMD_LOAD_MASKED || c == ir::SIMD_STORE_MASKED;
}

// The lane-wise operation that combines two chunks of reduction `op` by its definition: the float
// tree reductions add or multiply the upper half onto the lower half, and the wrapping and bitwise
// integer reductions and the integer extremes are order-free. OP_COUNT for every other operation.
fn combine_op(op: u32) u32 {
    if op < ir::OP_SIMD || op >= ir::OP_CMP_LANES {
        return ir::OP_COUNT;
    }
    let c = (op - ir::OP_SIMD) as u8;
    let k = if c == ir::SIMD_REDUCE_ADD_TREE {
        ir::OP_ADD;
    } else if c == ir::SIMD_REDUCE_MUL_TREE {
        ir::OP_MUL;
    } else if c == ir::SIMD_REDUCE_ADD {
        ir::OP_SIMD + ir::SIMD_WRAP_ADD as u32;
    } else if c == ir::SIMD_REDUCE_MUL {
        ir::OP_SIMD + ir::SIMD_WRAP_MUL as u32;
    } else if c == ir::SIMD_REDUCE_MIN {
        ir::OP_SIMD + ir::SIMD_MIN as u32;
    } else if c == ir::SIMD_REDUCE_MAX {
        ir::OP_SIMD + ir::SIMD_MAX as u32;
    } else if c == ir::SIMD_REDUCE_AND {
        ir::OP_AND;
    } else if c == ir::SIMD_REDUCE_OR {
        ir::OP_OR;
    } else if c == ir::SIMD_REDUCE_XOR {
        ir::OP_XOR;
    } else {
        ir::OP_COUNT;
    };
    return k;
}
