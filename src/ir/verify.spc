// Core IR structural verifier: rejects a body when a structural invariant
// fails. Runs unconditionally in the SC_CORE_IR development mode; the checks are pure reads.
// Type-level rules stay coarse until the IR interpreter and layout service land: a symbolic or error type is
// always permitted in a generic body (plan rule 15).
import ast::ast as *;
import ir::core as ir;

/// First violated rule as a static string, or "" when the body verifies.
pub fn verify(b: &ir::CoreBody, type_pool_len: usize) str<'static> {
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
    return "";
}
