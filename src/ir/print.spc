// Deterministic Core IR debug printer: a stable text form for the IR expected-output tests.
import ast::ast as *;
import ir::core as ir;

// The printed name of check intrinsic `c`.
const fn check_name(c: u8) str<'static> {
    if c == ir::IN_BOUNDS {
        return "bounds";
    }
    if c == ir::IN_BOUNDS_PROVEN {
        return "bounds.proven";
    }
    if c == ir::IN_BOUNDS_GROUP {
        return "bounds.group";
    }
    if c == ir::IN_RANGE_BOUNDS {
        return "range_bounds";
    }
    return "range_bounds.proven";
}

fn p_place(out: &mut String, b: &ir::CoreBody, pl: ir::PlaceId) {
    let p = b.places.at(pl as usize);
    out.push_str("_");
    out.push_u64(p.base);
    for i in 0..p.proj_len {
        let pj = b.projections.at((p.proj_start + i) as usize);
        if pj.kind == ir::PJ_DEREF {
            out.push_str(".*");
        } else if pj.kind == ir::PJ_FIELD {
            out.push_str(".f");
            out.push_u64(pj.sub);
        } else if pj.kind == ir::PJ_INDEX_CONST {
            out.push_str("[");
            out.push_u64(pj.data);
            out.push_str("]");
        } else if pj.kind == ir::PJ_INDEX_OP {
            out.push_str("[op");
            out.push_u64(pj.data);
            out.push_str("]");
        } else {
            out.push_str(".variant");
            out.push_u64(pj.data);
        }
    }
}

fn p_operand(out: &mut String, b: &ir::CoreBody, op: ir::OperandId) {
    if op == ir::IR_NONE {
        out.push_str("_"); // an aggregate member a designated literal leaves zero
        return;
    }
    let o = b.operands.at(op as usize);
    if o.kind == ir::OP_COPY {
        out.push_str("copy ");
        p_place(out, b, o.data);
    } else if o.kind == ir::OP_MOVE {
        out.push_str("move ");
        p_place(out, b, o.data);
    } else {
        let c = b.constants.at(o.data as usize);
        if c.kind == ir::CK_INT || c.kind == ir::CK_BOOL {
            out.push_str("const ");
            out.push_u64(c.val as u64);
        } else if c.kind == ir::CK_STR {
            out.push_str("const str");
        } else if c.kind == ir::CK_FLOAT {
            out.push_str("const float");
        } else if c.kind == ir::CK_ITEM {
            out.push_str("item m");
            out.push_u64(c.item.module);
            out.push_str(":n");
            out.push_u64(c.item.node);
        } else if c.kind == ir::CK_UNIT {
            out.push_str("unit");
        } else {
            out.push_str("const?");
        }
    }
}

fn p_rvalue(out: &mut String, b: &ir::CoreBody, rid: ir::RvalueId) {
    let r = b.rvalues.at(rid as usize);
    if r.kind == ir::RV_USE {
        p_operand(out, b, r.a);
    } else if r.kind == ir::RV_REF {
        if r.b != 0 {
            out.push_str("&mut ");
        } else {
            out.push_str("& ");
        }
        p_place(out, b, r.a);
    } else if r.kind == ir::RV_ADDR {
        out.push_str("addr ");
        p_place(out, b, r.a);
    } else if r.kind == ir::RV_UNARY {
        out.push_str("un");
        out.push_u64(r.b);
        out.push_str(" ");
        p_operand(out, b, r.a);
    } else if r.kind == ir::RV_BINARY {
        out.push_str("bin");
        out.push_u64(r.c);
        out.push_str("(");
        p_operand(out, b, r.a);
        out.push_str(", ");
        p_operand(out, b, r.b);
        out.push_str(")");
    } else if r.kind == ir::RV_CAST {
        out.push_str(
            if r.b == ir::CAST_SIMD_ARRAY {
                "cast.simd ";
            } else if r.b == ir::CAST_MASK_BITS {
                "cast.mask ";
            } else {
                "cast ";
            },
        );
        p_operand(out, b, r.a);
    } else if r.kind == ir::RV_AGGREGATE {
        out.push_str("agg");
        out.push_u64(r.c);
        out.push_str("[");
        for i in 0..r.b {
            if i != 0 {
                out.push_str(", ");
            }
            p_operand(out, b, b.oper_pool[(r.a + i) as usize]);
        }
        out.push_str("]");
    } else if r.kind == ir::RV_REPEAT {
        out.push_str("repeat(");
        p_operand(out, b, r.a);
        out.push_str(")");
    } else if r.kind == ir::RV_LEN {
        out.push_str("len ");
        p_place(out, b, r.a);
    } else if r.kind == ir::RV_DISCRIMINANT {
        out.push_str("discr ");
        p_place(out, b, r.a);
    } else if r.kind == ir::RV_DYN {
        out.push_str("dyn ");
        p_operand(out, b, r.a);
    } else if r.kind == ir::RV_CLOSURE {
        out.push_str("closure n");
        out.push_u64(r.item.node);
    } else if r.kind == ir::RV_INTRINSIC && ir::is_check(r.c) {
        out.push_str(check_name(r.c));
        out.push_str("(");
        for i in 0..ir::check_arity(r.c) {
            if i != 0 {
                out.push_str(", ");
            }
            p_operand(out, b, b.oper_pool[(r.a + i) as usize]);
        }
        out.push_str(")");
    } else if r.kind == ir::RV_SLICE {
        out.push_str("slice");
        out.push_u64(r.c);
        out.push_str(" ");
        p_place(out, b, r.a);
        out.push_str("[");
        if r.b != ir::IR_NONE {
            p_operand(out, b, r.b);
        }
        out.push_str("..");
        if r.item.node != ir::IR_NONE {
            p_operand(out, b, r.item.node);
        }
        out.push_str("]");
    } else {
        out.push_str("intrinsic");
        out.push_u64(r.c);
    }
}

/// Render `b` into a stable text block (types as raw TypeIds; ids are dense and deterministic).
pub fn print_body(b: &ir::CoreBody) String {
    let mut out = String::new();
    out.push_str("body m");
    out.push_u64(b.module);
    out.push_str(":n");
    out.push_u64(b.owner.node);
    out.push_str(" args=");
    out.push_u64(b.args);
    out.push_str(" rets=");
    out.push_u64(b.returns);
    out.push_str(" locals=");
    out.push_u64(b.locals.len() as u64);
    out.push_str("\n");
    for bi in 0..b.blocks.len() {
        out.push_str("bb");
        out.push_u64(bi as u64);
        out.push_str(":\n");
        let blk = b.blocks.at(bi);
        for si in 0..blk.stmt_len {
            let s = b.statements.at((blk.stmt_start + si) as usize);
            out.push_str("  ");
            if s.kind == ir::ST_ASSIGN {
                p_place(&mut out, b, s.place);
                out.push_str(" = ");
                p_rvalue(&mut out, b, s.rvalue);
            } else if s.kind == ir::ST_STORAGE_LIVE {
                out.push_str("live _");
                out.push_u64(s.a);
            } else if s.kind == ir::ST_STORAGE_DEAD {
                out.push_str("dead _");
                out.push_u64(s.a);
            } else {
                out.push_str("stmt");
                out.push_u64(s.kind);
            }
            out.push_str("\n");
        }
        let t = &blk.term;
        out.push_str("  ");
        if t.kind == ir::TM_GOTO {
            out.push_str("goto bb");
            out.push_u64(t.t0);
        } else if t.kind == ir::TM_SWITCH {
            out.push_str("switch(");
            p_operand(&mut out, b, t.a);
            out.push_str(")");
            for k in 0..t.sw_len {
                let pair = b.switch_pool[(t.sw_start + k) as usize];
                out.push_str(" ");
                out.push_u64(pair >> 32);
                out.push_str("->bb");
                out.push_u64(pair & 0xFFFFFFFFu64);
            }
            out.push_str(" else bb");
            out.push_u64(t.t0);
        } else if t.kind == ir::TM_CALL {
            out.push_str("call ");
            if t.callee.node != NODE_NONE {
                out.push_str("m");
                out.push_u64(t.callee.module);
                out.push_str(":n");
                out.push_u64(t.callee.node);
            } else {
                out.push_str("op");
                out.push_u64(t.a);
            }
            out.push_str("(");
            for k in 0..t.args_len {
                if k != 0 {
                    out.push_str(", ");
                }
                p_operand(&mut out, b, b.oper_pool[(t.args_start + k) as usize]);
            }
            out.push_str(")");
            if t.intr != ir::CI_NONE {
                out.push_str(" intrinsic ");
                out.push_str(ir::ci_name(t.intr));
            }
            out.push_str(" -> bb");
            out.push_u64(t.t0);
        } else if t.kind == ir::TM_RETURN {
            out.push_str("return");
            if t.args_len == ir::RET_CANCEL {
                out.push_str(" (cancel)");
            }
        } else if t.kind == ir::TM_DROP {
            out.push_str("drop ");
            p_place(&mut out, b, t.a);
            if t.args_len == 1 {
                out.push_str(" if _");
                out.push_u64(t.args_start);
            }
            out.push_str(" -> bb");
            out.push_u64(t.t0);
        } else if t.kind == ir::TM_ASSERT {
            out.push_str("assert -> bb");
            out.push_u64(t.t0);
        } else {
            out.push_str("unreachable");
        }
        out.push_str("\n");
    }
    return out;
}
