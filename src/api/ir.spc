// Read views of a checked session's lowered forms. HIR: the analyzed syntax after the sugar lowering, each node
// with what it resolves to and its type. Core IR: one function lowered, borrow-checked and drop-elaborated as
// the borrow check keeps it, with its locals, blocks, calls, moves, borrows and drops. A view is owned data
// copied out of the analysis: it holds no borrow of the session and no compiler pointer. Both schemas are
// provisional: they follow the compiler version.
import api::errors as *;
import api::session as ses;
import api::syntax as syn;
import api::semantic as sem;
import lsp::analysis as an;
import lsp::features as feat;
import module::loader as loader;
import ast::ast as *;
import ir::core as ir;
import ir::print as irp;
import typechecker::render as rnd;

/// One node of the analyzed form of a file: its kind, its range, whether the compiler made it after parsing
/// (the sugar lowering of `launch`, `select` and `parallel for`, or a checker rewrite such as formatting
/// sugar), the declaration it resolves to, and its type as the compiler spells it (empty: none).
pub struct HirNode {
    pub kind: syn::SyntaxKind,
    pub range: syn::TextRange,
    pub lowered: bool,
    pub resolves_to: Option<sem::SymbolKey>,
    pub ty: String,
}

// Whether node `i` of `a` was appended after parsing: by the sugar lowering, or by a checker rewrite.
fn synthesized(a: &Ast, i: NodeId) bool {
    if Ast::in_body(i) {
        return a.hir_body != 0 && (i & NODE_BODY_MASK) >= a.hir_body;
    }
    return a.hir_base != 0 && i >= a.hir_base;
}

/// The analyzed nodes of `file` whose ranges lie in `[start, end)`, in text order (a node before the nodes
/// inside it).
pub fn hir_nodes(s: &ses::Session, file: str, start: u32, end: u32) Result<Vector<HirNode>, ApiError> {
    if !s.checked() {
        return Result::<Vector<HirNode>, ApiError>::Err(
            ApiError::new(Code::NotChecked, "the session holds no analysis of its current inputs"),
        );
    }
    let m = switch s.module_of(file) {
        Some(md) => md.index() as usize,
        None => {
            return Result::<Vector<HirNode>, ApiError>::Err(
                ApiError::at(Code::InvalidArgument, "the file is not part of the analysis", file, 0, 0),
            );
        },
    };
    let p = s.package();
    let a = &p.modules[m].ast;
    let src = p.modules[m].source.as_str();
    let mut ids = Vector::<NodeId>::new();
    let n = a.nnodes();
    for i0 in 1..n {
        let i = a.nth_id(i0);
        let sp = a.at_const(i).span;
        if sp.start >= start && sp.end <= end && sp.end > sp.start {
            ids.push(i);
        }
    }
    // Text order, an outer node first; of two nodes with one range, the later-made one (the parent).
    ids.sort_by(
        |x: &NodeId, y: &NodeId| {
            let sx = a.at_const(*x).span;
            let sy = a.at_const(*y).span;
            if sx.start != sy.start {
                return sx.start.cmp(&sy.start);
            }
            if sx.end != sy.end {
                return sy.end.cmp(&sx.end);
            }
            return y.cmp(x);
        },
    );
    let mut out = Vector::<HirNode>::with_capacity(ids.len());
    for k in 0..ids.len() {
        let i = ids[k];
        let nd = a.at_const(i);
        let mut key = Option::<sem::SymbolKey>::None;
        let d = a.resolution_def(i);
        if d.node != NODE_NONE {
            key = sem::key_of(s, d);
        }
        let mut ty = String::new();
        if a.valid(i) && a.type_of(i) != TYPE_NONE {
            rnd::render_type_str(p, a, src, a.type_of(i), &mut ty);
        }
        out.push(
            HirNode {
                kind: syn::kind_of(nd.kind),
                range: syn::TextRange { start: nd.span.start, end: nd.span.end },
                lowered: synthesized(a, i),
                resolves_to: key,
                ty: ty,
            },
        );
    }
    return Result::<Vector<HirNode>, ApiError>::Ok(out);
}

/// What ends a Core IR block.
@derive(Eq, Format)
pub enum Terminator {
    Goto,
    Switch,
    Call,
    Return,
    Drop,
    Assert,
    Unreachable,
}

/// A local of a Core IR body: its name (empty for a temporary), its type, and whether it is a parameter.
pub struct Local {
    pub name: String,
    pub ty: String,
    pub param: bool,
}

/// A block: its statements' count, what ends it, and the successors it names.
pub struct Block {
    pub statements: u32,
    pub terminator: Terminator,
    pub successors: Vector<u32>,
}

/// A call: the declaration it calls (None for a call through a function value) and its range.
pub struct Call {
    pub callee: Option<sem::SymbolKey>,
    pub range: syn::TextRange,
}

/// A move, a borrow or a drop of a local's place, at a range of the source.
pub struct PlaceEvent {
    pub local: u32,
    pub range: syn::TextRange,
    pub mutable: bool, // a borrow: `&mut`
}

/// One function's Core IR: lowered, borrow-checked and drop-elaborated, as the borrow check keeps it.
pub struct CoreFunction {
    pub text: String, // the compiler's own printed form of the body
    pub generic: bool,
    pub locals: Vector<Local>,
    pub blocks: Vector<Block>,
    pub calls: Vector<Call>,
    pub moves: Vector<PlaceEvent>,
    pub borrows: Vector<PlaceEvent>,
    pub drops: Vector<PlaceEvent>,
}

/// The Core IR of the function or method named at `off` of `file` (its declaration or a use). Lowers it
/// again as its module's borrow check does; parses its module's bodies back when they were released.
/// `InvalidArgument` when no function is named there or it has no body.
pub fn core_function(s: &mut ses::Session, file: str, off: u32) Result<CoreFunction, ApiError> {
    if !s.checked() {
        return Result::<CoreFunction, ApiError>::Err(
            ApiError::new(Code::NotChecked, "the session holds no analysis of its current inputs"),
        );
    }
    let m = switch s.module_of(file) {
        Some(md) => md.index() as usize,
        None => {
            return Result::<CoreFunction, ApiError>::Err(
                ApiError::at(Code::InvalidArgument, "the file is not part of the analysis", file, 0, 0),
            );
        },
    };
    let d = feat::def_at(s.package(), m, off);
    if d.node == NODE_NONE || s.package().modules[d.module as usize].ast.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
        return Result::<CoreFunction, ApiError>::Err(
            ApiError::at(Code::InvalidArgument, "no function is named here", file, off, off),
        );
    }
    let mut body = ir::CoreBody::new(d, d.module);
    if !an::lower_item(s.package_mut(), d, &mut body) {
        return Result::<CoreFunction, ApiError>::Err(
            ApiError::at(Code::InvalidArgument, "the function has no body to lower", file, off, off),
        );
    }
    return Result::<CoreFunction, ApiError>::Ok(materialize(s, &body));
}

// Record operand `op` of body `b` in `out` when it is a user move (`CoreBody.user_moves`): a value the
// source consumes, not a copy the lowering made.
fn user_move(b: &ir::CoreBody, op: u32, start: u32, end: u32, out: &mut Vector<PlaceEvent>) {
    let w = (op / 64) as usize;
    if w >= b.user_moves.len() || (b.user_moves[w] >> (op % 64) as u64 & 1) == 0 {
        return;
    }
    let o = &b.operands[op as usize];
    if o.kind == ir::OP_COPY || o.kind == ir::OP_MOVE {
        out.push(PlaceEvent { local: b.places[o.data as usize].base, range: syn::TextRange { start: start, end: end } });
    }
}

// The owned view of body `b`.
fn materialize(s: &ses::Session, b: &ir::CoreBody) CoreFunction {
    let p = s.package();
    let a = &p.modules[b.module as usize].ast;
    let src = p.modules[b.module as usize].source.as_str();
    let mut f = CoreFunction { text: irp::print_body(b), generic: b.is_generic };
    for i in 0..b.locals.len() {
        let l = &b.locals[i];
        let mut ty = String::new();
        if l.ty != TYPE_NONE {
            rnd::render_type_str(p, a, src, l.ty, &mut ty);
        }
        let mut name = String::new();
        if l.name_len != 0 {
            let s0 = l.span.start as usize + l.name_off as usize;
            name.push_str(src.slice(s0, s0 + l.name_len as usize));
        }
        f.locals.push(Local { name: name, ty: ty, param: l.storage == ir::LS_ARG });
    }
    for k in 0..b.blocks.len() {
        let bb = &b.blocks[k];
        let t = &bb.term;
        let kind = switch t.kind {
            ir::TM_GOTO => Terminator::Goto,
            ir::TM_SWITCH => Terminator::Switch,
            ir::TM_CALL => Terminator::Call,
            ir::TM_RETURN => Terminator::Return,
            ir::TM_DROP => Terminator::Drop,
            ir::TM_ASSERT => Terminator::Assert,
            _ => Terminator::Unreachable,
        };
        let mut succ = Vector::<u32>::new();
        if t.kind != ir::TM_RETURN && t.kind != ir::TM_UNREACHABLE {
            succ.push(t.t0);
        }
        if t.kind == ir::TM_SWITCH {
            for j in 0..t.sw_len {
                let tg = (b.switch_pool[(t.sw_start + j) as usize] & 0xFFFFFFFF) as u32;
                if !succ.contains(&tg) {
                    succ.push(tg);
                }
            }
        }
        f.blocks.push(Block { statements: bb.stmt_len, terminator: kind, successors: succ });
        if t.kind == ir::TM_CALL {
            let mut callee = Option::<sem::SymbolKey>::None;
            if t.callee.node != NODE_NONE {
                callee = sem::key_of(s, t.callee);
            }
            f.calls.push(Call { callee: callee, range: syn::TextRange { start: t.span.start, end: t.span.end } });
            for j in 0..t.args_len {
                user_move(b, b.oper_pool[(t.args_start + j) as usize], t.span.start, t.span.end, &mut f.moves);
            }
        }
        if t.kind == ir::TM_DROP {
            f.drops.push(
                PlaceEvent {
                    local: b.places[t.a as usize].base,
                    range: syn::TextRange { start: t.span.start, end: t.span.end },
                },
            );
        }
        for si in bb.stmt_start..bb.stmt_start + bb.stmt_len {
            let st = &b.statements[si as usize];
            if st.kind != ir::ST_ASSIGN {
                continue;
            }
            let rv = &b.rvalues[st.rvalue as usize];
            let r = syn::TextRange { start: st.span.start, end: st.span.end };
            if rv.kind == ir::RV_REF {
                f.borrows.push(PlaceEvent { local: b.places[rv.a as usize].base, range: r, mutable: rv.b == 1 });
            } else if rv.kind == ir::RV_USE {
                user_move(b, rv.a, r.start, r.end, &mut f.moves);
            } else if rv.kind == ir::RV_AGGREGATE {
                for j in 0..rv.b {
                    user_move(b, b.oper_pool[(rv.a + j) as usize], r.start, r.end, &mut f.moves);
                }
            }
        }
    }
    return f;
}
