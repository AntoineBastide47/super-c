// Core IR structural verifier: rejects a body when a structural invariant fails. The checks are
// pure reads; the IR tests and the SC_CORE_IR re-verification of inlined bodies run them. A
// symbolic or error type is always permitted in a generic body.
import ast::ast as *;
import ir::core as ir;
import module::loader as loader;

// The five prelude length-carrying views whose safe access must address through an explicit
// check result. Looked up once per verified body; a null package skips the def-chain rules
// (structural-only verification, used by unit fixtures).
struct SafeViews {
    pub s_str: DefId,
    pub s_slice: DefId,
    pub s_slice_mut: DefId,
    pub s_vector: DefId,
    pub s_string: DefId,
    pub s_array: DefId,
}

const fn hit_def(h: loader::LookupHit) DefId {
    return DefId { module: h.mid, node: h.node };
}

fn safe_views(pk: &loader::Package) SafeViews {
    return SafeViews {
        s_str: hit_def(pk.prelude_lookup("str", true)),
        s_slice: hit_def(pk.prelude_lookup("Slice", true)),
        s_slice_mut: hit_def(pk.prelude_lookup("SliceMut", true)),
        s_vector: hit_def(pk.prelude_lookup("Vector", true)),
        s_string: hit_def(pk.prelude_lookup("String", true)),
        s_array: hit_def(pk.prelude_lookup("Array", true)),
    };
}

const fn same_def(a: DefId, node: NodeId, m: ModuleId) bool {
    return a.node != NODE_NONE && a.node == node && a.module == m;
}

// Peel reference wrappers: safe indexing and slicing operate through autoref.
fn peel_refs(da: &Ast, ty0: TypeId) TypeId {
    let mut ty = ty0;
    let mut guard = 0;
    while guard < 3 && ty != TYPE_NONE {
        let y = *da.type_at(ty);
        if y.kind != TypeKind::TYPE_REFERENCE {
            break;
        }
        ty = y.as_data.elem;
        guard += 1;
    }
    return ty;
}

// Is `ty` (after peeling references) one of the checked views (str/Slice/SliceMut/Vector/String)?
// Mirrors the lowering's checked_view gate; symbolic and unresolved types answer false, so the
// rule fires only where the lowering provably inserted a check.
fn is_checked_view(da: &Ast, sv: &SafeViews, ty0: TypeId) bool {
    let ty = peel_refs(da, ty0);
    if ty == TYPE_NONE {
        return false;
    }
    let y = *da.type_at(ty);
    if y.kind == TypeKind::TYPE_STRUCT {
        return same_def(sv.s_str, y.as_data.decl, y.module);
    }
    if y.kind != TypeKind::TYPE_INSTANCE {
        return false;
    }
    let it = *da.instance(y.as_data.inst);
    return same_def(sv.s_slice, it.decl, it.module) || same_def(sv.s_slice_mut, it.decl, it.module) || same_def(
        sv.s_vector,
        it.decl,
        it.module,
    ) || same_def(sv.s_string, it.decl, it.module);
}

// Is `ty` (after peeling references) a range-validated slicing base: a checked view, a raw
// array, or the prelude Array instance?
fn is_sliceable(da: &Ast, sv: &SafeViews, ty0: TypeId) bool {
    let ty = peel_refs(da, ty0);
    if ty == TYPE_NONE {
        return false;
    }
    if is_checked_view(da, sv, ty) {
        return true;
    }
    let y = *da.type_at(ty);
    if y.kind == TypeKind::TYPE_ARRAY {
        return true;
    }
    if y.kind != TypeKind::TYPE_INSTANCE {
        return false;
    }
    let it = *da.instance(y.as_data.inst);
    return same_def(sv.s_array, it.decl, it.module);
}

/// First violated rule as a static string, or "" when the body verifies.
pub fn verify(b: &ir::CoreBody, type_pool_len: usize, pkg: *const loader::Package) str<'static> {
    if b.blocks.len() == 0 {
        return "no-blocks";
    }
    if b.entry as usize >= b.blocks.len() {
        return "entry-out-of-range";
    }
    for i in 0..b.locals.len() {
        if b.locals.at(i).ty as usize >= type_pool_len {
            return "local-type-out-of-range";
        }
    }
    for i in 0..b.places.len() {
        let p = b.places.at(i);
        if p.base as usize >= b.locals.len() {
            return "place-base-out-of-range";
        }
        if p.proj_len != 0 && (p.proj_start + p.proj_len) as usize > b.projections.len() {
            return "place-proj-out-of-range";
        }
    }
    for i in 0..b.projections.len() {
        let pj = b.projections.at(i);
        if pj.kind == ir::PJ_INDEX_OP && pj.data as usize >= b.operands.len() {
            return "proj-index-operand";
        }
        if pj.ty as usize >= type_pool_len {
            return "proj-type-out-of-range";
        }
    }
    for i in 0..b.operands.len() {
        let o = b.operands.at(i);
        if o.kind == ir::OP_COPY || o.kind == ir::OP_MOVE {
            if o.data as usize >= b.places.len() {
                return "operand-place-out-of-range";
            }
        } else if o.data as usize >= b.constants.len() {
            return "operand-const-out-of-range";
        }
    }
    for i in 0..b.rvalues.len() {
        let r = b.rvalues.at(i);
        if r.kind == ir::RV_USE || r.kind == ir::RV_UNARY || r.kind == ir::RV_CAST {
            if r.a as usize >= b.operands.len() {
                return "rvalue-operand-out-of-range";
            }
        } else if r.kind == ir::RV_BINARY {
            if r.a as usize >= b.operands.len() || r.b as usize >= b.operands.len() {
                return "rvalue-operand-out-of-range";
            }
        } else if r.kind == ir::RV_REF || r.kind == ir::RV_ADDR || r.kind == ir::RV_LEN || r.kind == ir::RV_DISCRIMINANT {
            if r.a as usize >= b.places.len() {
                return "rvalue-place-out-of-range";
            }
        } else if r.kind == ir::RV_INTRINSIC && ir::is_check(r.c) {
            let want = ir::check_arity(r.c);
            if r.b != want {
                return "check-operand-count";
            }
            if r.a as usize + want as usize > b.oper_pool.len() {
                return "check-operand-out-of-range";
            }
            for k in 0..want {
                if b.oper_pool[(r.a + k) as usize] as usize >= b.operands.len() {
                    return "check-operand-out-of-range";
                }
            }
        } else if r.kind == ir::RV_INTRINSIC && (r.c == ir::IN_SIZEOF || r.c == ir::IN_ALIGNOF || r.c == ir::IN_TYPE_INFO || r.c == ir::IN_DANGLING) {
            // `b` carries the measured/described TypeId, not an operand count
            if r.b as usize >= type_pool_len {
                return "intrinsic-type-out-of-range";
            }
        } else if r.kind == ir::RV_SLICE {
            if r.a as usize >= b.places.len() {
                return "slice-place-out-of-range";
            }
            if r.b != ir::IR_NONE && r.b as usize >= b.operands.len() {
                return "slice-start-out-of-range";
            }
            if r.item.node != ir::IR_NONE && r.item.node as usize >= b.operands.len() {
                return "slice-end-out-of-range";
            }
        } else if r.kind == ir::RV_AGGREGATE || r.kind == ir::RV_CLOSURE || r.kind == ir::RV_INTRINSIC {
            if r.b != 0 && (r.a + r.b) as usize > b.oper_pool.len() {
                return "rvalue-range-out-of-range";
            }
        }
        if r.target as usize >= type_pool_len {
            return "rvalue-type-out-of-range";
        }
    }
    for i in 0..b.statements.len() {
        let s = b.statements.at(i);
        if s.kind == ir::ST_ASSIGN {
            if s.place as usize >= b.places.len() {
                return "stmt-place-out-of-range";
            }
            if s.rvalue as usize >= b.rvalues.len() {
                return "stmt-rvalue-out-of-range";
            }
        }
        if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD {
            if s.a as usize >= b.locals.len() {
                return "storage-local-out-of-range";
            }
        }
    }
    // Blocks: sealed, statement runs in range, successors exist, calls resolved.
    for i in 0..b.blocks.len() {
        let blk = b.blocks.at(i);
        if !blk.sealed {
            return "unsealed-block";
        }
        if (blk.stmt_start + blk.stmt_len) as usize > b.statements.len() {
            return "block-stmts-out-of-range";
        }
        let t = &blk.term;
        if t.kind == ir::TM_GOTO || t.kind == ir::TM_DROP || t.kind == ir::TM_ASSERT {
            if t.t0 as usize >= b.blocks.len() {
                return "successor-out-of-range";
            }
        } else if t.kind == ir::TM_SWITCH {
            if t.a as usize >= b.operands.len() {
                return "switch-operand";
            }
            if t.t0 as usize >= b.blocks.len() {
                return "switch-otherwise";
            }
            for k in 0..t.sw_len {
                let pair = b.switch_pool[(t.sw_start + k) as usize];
                if (pair & 0xFFFFFFFFu64) as usize >= b.blocks.len() {
                    return "switch-target";
                }
            }
        } else if t.kind == ir::TM_CALL {
            if t.t0 as usize >= b.blocks.len() {
                return "call-successor";
            }
            if t.callee.node == NODE_NONE && t.a == ir::IR_NONE {
                return "call-unresolved";
            }
            if t.a != ir::IR_NONE && t.a as usize >= b.operands.len() {
                return "call-callee-operand";
            }
            if t.args_len != 0 && (t.args_start + t.args_len) as usize > b.oper_pool.len() {
                return "call-args-out-of-range";
            }
            if t.dests_len != 0 && (t.dests_start + t.dests_len) as usize > b.dest_pool.len() {
                return "call-dests-out-of-range";
            }
            for k in 0..t.dests_len {
                if b.dest_pool[(t.dests_start + k) as usize] as usize >= b.places.len() {
                    return "call-dest-place";
                }
            }
        } else if t.kind != ir::TM_RETURN && t.kind != ir::TM_UNREACHABLE {
            return "terminator-kind";
        }
    }
    // Return-slot layout: locals [0, returns) are LS_RET.
    for i in 0..b.returns {
        if i as usize >= b.locals.len() || b.locals.at(i as usize).storage != ir::LS_RET {
            return "return-slot-layout";
        }
    }
    // Def-chain rules (plan 6.4): a safe indexed projection addresses through an element-check
    // result, and a safe RV_SLICE takes its exclusive end from a range-check result. Marks: 0 =
    // untouched, 1 = element-check temp, 2 = range-check temp, 3 = anything else (poisoned).
    if pkg != null {
        let pk = unsafe &*pkg;
        let da = unsafe &*pk.module_ast_const(b.module);
        let sv = safe_views(pk);
        let mut marks = Vector::<u8>::new();
        marks.resize_default(b.locals.len());
        for i in 0..b.statements.len() {
            let s = b.statements.at(i);
            if s.kind != ir::ST_ASSIGN {
                continue;
            }
            let p0 = *b.places.at(s.place as usize);
            if p0.proj_len != 0 {
                marks.set(p0.base as usize, 3);
                continue;
            }
            let r = *b.rvalues.at(s.rvalue as usize);
            let mut m: u8 = 3;
            if r.kind == ir::RV_INTRINSIC && (r.c == ir::IN_BOUNDS || r.c == ir::IN_BOUNDS_PROVEN || r.c == ir::IN_BOUNDS_GROUP) {
                m = 1;
            } else if r.kind == ir::RV_INTRINSIC && (r.c == ir::IN_RANGE_BOUNDS || r.c == ir::IN_RANGE_BOUNDS_PROVEN) {
                m = 2;
            }
            if marks[p0.base as usize] == 0 {
                marks.set(p0.base as usize, m);
            } else {
                marks.set(p0.base as usize, 3);
            }
        }
        for i in 0..b.blocks.len() {
            let t = &b.blocks.at(i).term;
            if t.kind == ir::TM_CALL {
                for k in 0..t.dests_len {
                    let dp = *b.places.at(b.dest_pool[(t.dests_start + k) as usize] as usize);
                    marks.set(dp.base as usize, 3);
                }
            }
        }
        let mut fail: str<'static> = "";
        for i in 0..b.places.len() {
            let p = b.places.at(i);
            let mut cur = b.locals.at(p.base as usize).ty;
            for j in 0..p.proj_len {
                let pj = *b.projections.at((p.proj_start + j) as usize);
                if pj.kind == ir::PJ_INDEX_OP && is_checked_view(da, &sv, cur) {
                    let o = *b.operands.at(pj.data as usize);
                    let mut ok = false;
                    if o.kind == ir::OP_COPY || o.kind == ir::OP_MOVE {
                        let op0 = *b.places.at(o.data as usize);
                        ok = op0.proj_len == 0 && marks[op0.base as usize] == 1;
                    }
                    if !ok {
                        fail = "index-not-checked";
                    }
                }
                cur = pj.ty;
            }
        }
        for i in 0..b.rvalues.len() {
            let r = b.rvalues.at(i);
            if r.kind != ir::RV_SLICE {
                continue;
            }
            if !is_sliceable(da, &sv, b.places.at(r.a as usize).ty) {
                continue;
            }
            let mut ok = false;
            if r.item.node != ir::IR_NONE {
                let o = *b.operands.at(r.item.node as usize);
                if o.kind == ir::OP_COPY || o.kind == ir::OP_MOVE {
                    let op0 = *b.places.at(o.data as usize);
                    ok = op0.proj_len == 0 && marks[op0.base as usize] == 2;
                }
            }
            if !ok {
                fail = "slice-end-not-validated";
            }
        }
        marks.free();
        if fail.len() != 0 {
            return fail;
        }
    }
    return "";
}
