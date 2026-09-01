// Deterministic Core IR debug printer: a stable text form used only by the
// SC_CORE_IR development mode and the IR expected-output tests. Never runs in a normal build.
import ast::ast as *;
import ir::core as ir;

fn p_u(out: &mut String, v: u64) {
    out.push_u64(v);
}

fn p_place(out: &mut String, b: &ir::CoreBody, pl: ir::PlaceId) {
    let p = b.places.at(pl as usize);
    out.push_str("_");
    p_u(out, p.base);
    for i in 0..p.proj_len {
        let pj = b.projections.at((p.proj_start + i) as usize);
        if pj.kind == ir::PJ_DEREF {
            out.push_str(".*");
        } else if pj.kind == ir::PJ_FIELD {
            out.push_str(".f");
            p_u(out, pj.sub);
        } else if pj.kind == ir::PJ_INDEX_CONST {
            out.push_str("[");
            p_u(out, pj.data);
            out.push_str("]");
        } else if pj.kind == ir::PJ_INDEX_OP {
            out.push_str("[op");
            p_u(out, pj.data);
            out.push_str("]");
        } else {
            out.push_str(".variant");
            p_u(out, pj.data);
        }
    }
}

fn p_operand(out: &mut String, b: &ir::CoreBody, op: ir::OperandId) {
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
            p_u(out, c.val as u64);
        } else if c.kind == ir::CK_STR {
            out.push_str("const str");
        } else if c.kind == ir::CK_FLOAT {
            out.push_str("const float");
        } else if c.kind == ir::CK_ITEM {
            out.push_str("item m");
            p_u(out, c.item.module);
            out.push_str(":n");
            p_u(out, c.item.node);
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
        p_u(out, r.b);
        out.push_str(" ");
        p_operand(out, b, r.a);
    } else if r.kind == ir::RV_BINARY {
        out.push_str("bin");
        p_u(out, r.c);
        out.push_str("(");
        p_operand(out, b, r.a);
        out.push_str(", ");
        p_operand(out, b, r.b);
        out.push_str(")");
    } else if r.kind == ir::RV_CAST {
        out.push_str("cast ");
        p_operand(out, b, r.a);
    } else if r.kind == ir::RV_AGGREGATE {
        out.push_str("agg");
        p_u(out, r.c);
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
        p_u(out, r.item.node);
    } else if r.kind == ir::RV_INTRINSIC && (r.c == ir::IN_BOUNDS || r.c == ir::IN_BOUNDS_PROVEN) {
        out.push_str(
            if r.c == ir::IN_BOUNDS {
                "bounds(";
            } else {
                "bounds.proven(";
            },
        );
        p_operand(out, b, b.oper_pool[r.a as usize]);
        out.push_str(", ");
        p_operand(out, b, b.oper_pool[(r.a + 1) as usize]);
        out.push_str(")");
    } else if r.kind == ir::RV_INTRINSIC && r.c == ir::IN_BOUNDS_GROUP {
        out.push_str("bounds.group(");
        p_operand(out, b, b.oper_pool[r.a as usize]);
        out.push_str(", ");
        p_operand(out, b, b.oper_pool[(r.a + 1) as usize]);
        out.push_str(", ");
        p_operand(out, b, b.oper_pool[(r.a + 2) as usize]);
        out.push_str(")");
    } else if r.kind == ir::RV_INTRINSIC && (r.c == ir::IN_RANGE_BOUNDS || r.c == ir::IN_RANGE_BOUNDS_PROVEN) {
        out.push_str(
            if r.c == ir::IN_RANGE_BOUNDS {
                "range_bounds(";
            } else {
                "range_bounds.proven(";
            },
        );
        p_operand(out, b, b.oper_pool[r.a as usize]);
        out.push_str(", ");
        p_operand(out, b, b.oper_pool[(r.a + 1) as usize]);
        out.push_str(", ");
        p_operand(out, b, b.oper_pool[(r.a + 2) as usize]);
        out.push_str(")");
    } else {
        out.push_str("intrinsic");
        p_u(out, r.c);
    }
}

/// Render `b` into a stable text block (types as raw TypeIds; ids are dense and deterministic).
pub fn print_body(b: &ir::CoreBody) String {
    let mut out = String::new();
    out.push_str("body m");
    p_u(&mut out, b.module);
    out.push_str(":n");
    p_u(&mut out, b.owner.node);
    out.push_str(" args=");
    p_u(&mut out, b.args);
    out.push_str(" rets=");
    p_u(&mut out, b.returns);
    out.push_str(" locals=");
    p_u(&mut out, b.locals.len() as u64);
    out.push_str("\n");
    for bi in 0..b.blocks.len() {
        out.push_str("bb");
        p_u(&mut out, bi as u64);
        out.push_str(":\n");
        let blk = b.blocks.at(bi);
        for si in 0..blk.stmt_len {
            let s = b.statements.at((blk.stmt_start + si) as usize);
            out.push_str("  ");
            if s.kind == ir::ST_ASSIGN {
                p_place(&mut out, b, s.place);
                out.push_str(" = ");
                p_rvalue(&mut out, b, s.rvalue);
            } else if s.kind == ir::ST_ASM {
                out.push_str("asm");
            } else if s.kind == ir::ST_STORAGE_LIVE {
                out.push_str("live _");
                p_u(&mut out, s.a);
            } else if s.kind == ir::ST_STORAGE_DEAD {
                out.push_str("dead _");
                p_u(&mut out, s.a);
            } else {
                out.push_str("stmt");
                p_u(&mut out, s.kind);
            }
            out.push_str("\n");
        }
        let t = &blk.term;
        out.push_str("  ");
        if t.kind == ir::TM_GOTO {
            out.push_str("goto bb");
            p_u(&mut out, t.t0);
        } else if t.kind == ir::TM_SWITCH {
            out.push_str("switch(");
            p_operand(&mut out, b, t.a);
            out.push_str(")");
            for k in 0..t.sw_len {
                let pair = b.switch_pool[(t.sw_start + k) as usize];
                out.push_str(" ");
                p_u(&mut out, pair >> 32);
                out.push_str("->bb");
                p_u(&mut out, pair & 0xFFFFFFFFu64);
            }
            out.push_str(" else bb");
            p_u(&mut out, t.t0);
        } else if t.kind == ir::TM_CALL {
            out.push_str("call ");
            if t.callee.node != NODE_NONE {
                out.push_str("m");
                p_u(&mut out, t.callee.module);
                out.push_str(":n");
                p_u(&mut out, t.callee.node);
            } else {
                out.push_str("op");
                p_u(&mut out, t.a);
            }
            out.push_str("(");
            for k in 0..t.args_len {
                if k != 0 {
                    out.push_str(", ");
                }
                p_operand(&mut out, b, b.oper_pool[(t.args_start + k) as usize]);
            }
            out.push_str(") -> bb");
            p_u(&mut out, t.t0);
        } else if t.kind == ir::TM_RETURN {
            out.push_str("return");
        } else if t.kind == ir::TM_DROP {
            out.push_str("drop -> bb");
            p_u(&mut out, t.t0);
        } else if t.kind == ir::TM_ASSERT {
            out.push_str("assert -> bb");
            p_u(&mut out, t.t0);
        } else {
            out.push_str("unreachable");
        }
        out.push_str("\n");
    }
    return out;
}
