// Typed AST -> Core IR lowering. Consumes ONLY the typed-facts boundary
// (ast::facts) plus syntax structure and source spans; every semantic decision (types, resolutions,
// call targets, operator methods, coercions, deref chains, dyn erasures) is read from the recorded
// facts, never re-derived -- except the for-loop `next` method shim, which mirrors codegen until the
// instance graph owns method demand.
//
// Evaluation order (documented before implementation, per the plan; matches the current emitter):
//   - receiver before call arguments; arguments left to right
//   - short-circuit && and || evaluate the right operand only on the deciding path
//   - assignment evaluates the target place FIRST, then the value (C order the emitter relies on)
//   - aggregate fields and array elements in source order
//   - match: scrutinee once, then per-arm tests in arm order, guard after bindings, body last
//   - `defer` bodies run LIFO at every scope exit (return, break, continue, block end)
//   - multi-return destinations are written in declaration order at the call
//
// A body that reaches a construct this phase cannot lower yet fails with a reason string; the
// driver's SC_CORE_IR mode counts reasons so coverage gaps stay visible until the corpus is clean.
import lexer::token as tok;
import lexer::token_type as tt;
import ast::ast as *;
import ast::facts as facts;
import module::loader as loader;
import ir::core as ir;
import pattern::pattern as pat;

/// One binding in scope: the declaring node (LET name / parameter / pattern name) -> its local.
struct Binding {
    pub decl: NodeId,
    pub local: ir::LocalId,
}

/// One enclosing loop, for break/continue routing (label span empty = unlabeled).
struct LoopCtx {
    pub label: tok::Span,
    pub brk: ir::BlockId,
    pub cont: ir::BlockId,
    pub defer_depth: usize, // defers deeper than this run before leaving the loop
    pub result: ir::PlaceId, // `break value` destination for loop expressions; IR_NONE when none
}

pub struct Lowerer {
    pub f: facts::TypedFacts,
    pub pkg: *const loader::Package,
    pub module: ModuleId,
    pub src: str<'static>,
    pub body: ir::CoreBody,
    pub err: str<'static>, // first unsupported-construct reason ("" = ok)
    pub err_node: NodeId, // the node that failed (diagnostic snippet in the SC_CORE_IR report)
    binds: Vector<Binding>,
    loops: Vector<LoopCtx>,
    defers: Vector<NodeId>, // active defer statement nodes, innermost last
    scope_defers: Vector<usize>, // per open scope: defers length at entry
    item_locals: Vector<Binding>, // cached LS_STATIC_REF locals per referenced item decl node
    pub closures: Vector<NodeId>, // closure nodes queued for their own lowering
    cur: ir::BlockId,
    run_start: u32, // statements index where the open block's run began
    ret_locals: u32, // first return-slot local
}

// Decode call_info: (fmod << 40 | fdecl << 8 | skip).
const fn ci_module(v: u64) ModuleId {
    return (v >> 40) as ModuleId;
}
const fn ci_decl(v: u64) NodeId {
    return (v >> 8 & 0xFFFFFFFFu64) as NodeId;
}

extend Lowerer {
    pub fn new(pkg: *const loader::Package, module: ModuleId, owner: NodeId) Lowerer {
        let a = unsafe (&*pkg).module_ast_const(module);
        let sp = unsafe (&*pkg).modules.at(module as usize).source.as_str();
        return Lowerer {
            f: facts::TypedFacts::of(a),
            pkg: pkg,
            module: module,
            src: str::from_raw(sp.ptr(), sp.len()),
            body: ir::CoreBody::new(DefId { module: module, node: owner }, module),
            err: "",
            err_node: NODE_NONE,
            binds: Vector::<Binding>::new(),
            loops: Vector::<LoopCtx>::new(),
            defers: Vector::<NodeId>::new(),
            scope_defers: Vector::<usize>::new(),
            item_locals: Vector::<Binding>::new(),
            closures: Vector::<NodeId>::new(),
            cur: 0,
            run_start: 0,
            ret_locals: 0,
        };
    }

    fn fail(self: &mut Self, why: str<'static>) {
        if self.err.len() == 0 {
            self.err = why;
        }
    }

    fn fail_at(self: &mut Self, why: str<'static>, node: NodeId) {
        if self.err.len() == 0 {
            self.err = why;
            self.err_node = node;
        }
    }

    // ---- block builder ----------------------------------------------------------------------------

    fn open_block(self: &mut Self) ir::BlockId {
        return self.body.add_block();
    }

    // Seal the open block with `t` and continue in `next` (its statement run starts now).
    fn seal(self: &mut Self, t: ir::Terminator, next: ir::BlockId) {
        let b = self.cur as usize;
        if !self.body.blocks[b].sealed {
            self.body.blocks[b].stmt_start = self.run_start;
            self.body.blocks[b].stmt_len = self.body.statements.len() as u32 - self.run_start;
            self.body.blocks[b].term = t;
            self.body.blocks[b].sealed = true;
        }
        self.cur = next;
        self.run_start = self.body.statements.len() as u32;
    }

    // Seal an untouched (empty) block with `unreachable` without moving the write cursor.
    fn seal_dead(self: &mut Self, b: ir::BlockId, sp: tok::Span) {
        if !self.body.blocks[b as usize].sealed {
            self.body.blocks[b as usize].stmt_start = self.body.statements.len() as u32;
            self.body.blocks[b as usize].stmt_len = 0;
            self.body.blocks[b as usize].term = self.term0(ir::TM_UNREACHABLE, sp);
            self.body.blocks[b as usize].sealed = true;
        }
    }

    fn goto_term(self: &Self, to: ir::BlockId, sp: tok::Span) ir::Terminator {
        let mut t = self.term0(ir::TM_GOTO, sp);
        t.t0 = to;
        return t;
    }

    const fn term0(self: &Self, kind: u8, sp: tok::Span) ir::Terminator {
        return ir::Terminator {
            kind: kind,
            a: ir::IR_NONE,
            args_start: 0,
            args_len: 0,
            dests_start: 0,
            dests_len: 0,
            sw_start: 0,
            sw_len: 0,
            t0: ir::IR_NONE,
            callee: DefId { module: 0, node: NODE_NONE },
            targs_start: 0,
            targs_len: 0,
            is_variadic: false,
            span: sp,
        };
    }

    fn stmt(self: &mut Self, s: ir::Statement) {
        self.body.statements.push(s);
    }

    fn assign(self: &mut Self, place: ir::PlaceId, rv: ir::Rvalue, sp: tok::Span) {
        self.body.rvalues.push(rv);
        self.stmt(
            ir::Statement {
                kind: ir::ST_ASSIGN,
                place: place,
                rvalue: self.body.rvalues.len() as u32 - 1,
                a: 0,
                b: 0,
                span: sp,
            },
        );
    }

    // ---- small constructors -----------------------------------------------------------------------

    fn temp(self: &mut Self, ty: TypeId, sp: tok::Span) ir::LocalId {
        return self.body.add_local(
            ir::LocalDecl {
                ty: ty,
                storage: ir::LS_TEMP,
                is_mutable: true,
                span: sp,
                decl: NODE_NONE,
                item: DefId { module: 0, node: NODE_NONE },
            },
        );
    }

    fn place_of_local(self: &mut Self, l: ir::LocalId) ir::PlaceId {
        let ty = self.body.locals.at(l as usize).ty;
        self.body.places.push(ir::Place { base: l, proj_start: 0, proj_len: 0, ty: ty });
        return self.body.places.len() as u32 - 1;
    }

    fn place_project(self: &mut Self, base: ir::PlaceId, pj: ir::Projection) ir::PlaceId {
        // Places are append-only: extending re-emits the base's projections then the new one, so a
        // projection range stays contiguous.
        let bp = *self.body.places.at(base as usize);
        let start = self.body.projections.len() as u32;
        for i in 0..bp.proj_len {
            let p = *self.body.projections.at((bp.proj_start + i) as usize);
            self.body.projections.push(p);
        }
        self.body.projections.push(pj);
        self.body.places.push(ir::Place { base: bp.base, proj_start: start, proj_len: bp.proj_len + 1, ty: pj.ty });
        return self.body.places.len() as u32 - 1;
    }

    fn const_op(self: &mut Self, c: ir::Constant) ir::OperandId {
        self.body.constants.push(c);
        self.body.operands.push(
            ir::Operand { kind: ir::OP_CONST, data: self.body.constants.len() as u32 - 1, ty: c.ty },
        );
        return self.body.operands.len() as u32 - 1;
    }

    fn unit_op(self: &mut Self, ty: TypeId, sp: tok::Span) ir::OperandId {
        return self.const_op(
            ir::Constant {
                kind: ir::CK_UNIT,
                ty: ty,
                val: 0,
                raw: sp,
                item: DefId { module: 0, node: NODE_NONE },
                targ_start: 0,
                targ_len: 0,
            },
        );
    }

    fn copy_op(self: &mut Self, pl: ir::PlaceId) ir::OperandId {
        let ty = self.body.places.at(pl as usize).ty;
        self.body.operands.push(ir::Operand { kind: ir::OP_COPY, data: pl, ty: ty });
        return self.body.operands.len() as u32 - 1;
    }

    fn rv_use(self: &Self, op: ir::OperandId, ty: TypeId) ir::Rvalue {
        return ir::Rvalue {
            kind: ir::RV_USE,
            a: op,
            b: 0,
            c: 0,
            target: ty,
            item: DefId { module: 0, node: NODE_NONE },
        };
    }

    // Store operand `op` into a fresh temp and return the temp's place (for projections off values).
    fn spill(self: &mut Self, op: ir::OperandId, sp: tok::Span) ir::PlaceId {
        let ty = self.body.operands.at(op as usize).ty;
        let t = self.temp(ty, sp);
        let pl = self.place_of_local(t);
        let rv = self.rv_use(op, ty);
        self.assign(pl, rv, sp);
        return pl;
    }

    // ---- scopes, bindings, defers -----------------------------------------------------------------

    fn scope_enter(self: &mut Self) {
        self.scope_defers.push(self.defers.len());
    }

    // Run this scope's defers (LIFO) and drop them; called at the block's natural end.
    fn scope_exit(self: &mut Self) {
        let base = self.scope_defers[self.scope_defers.len() - 1];
        let _ = self.scope_defers.pop();
        self.emit_defers_down_to(base);
        while self.defers.len() > base {
            let _ = self.defers.pop();
        }
    }

    // Emit defer bodies (innermost first) down to `base` WITHOUT popping (early exits leave the
    // scope stack intact for the code that follows the branch point).
    fn emit_defers_down_to(self: &mut Self, base: usize) {
        let mut i = self.defers.len();
        while i > base {
            i -= 1;
            let d = self.defers[i];
            self.lower_stmt(self.f.node(d).as_data.single.value);
        }
    }

    fn bind(self: &mut Self, decl: NodeId, l: ir::LocalId) {
        self.binds.push(Binding { decl: decl, local: l });
    }

    fn local_of(self: &Self, decl: NodeId) ir::LocalId {
        let mut i = self.binds.len();
        while i > 0 {
            i -= 1;
            if self.binds[i].decl == decl {
                return self.binds[i].local;
            }
        }
        return ir::IR_NONE;
    }

    // The cached LS_STATIC_REF local naming item `d` (globals, statics, constants read as places).
    fn item_local(self: &mut Self, d: DefId, ty: TypeId, sp: tok::Span) ir::LocalId {
        for i in 0..self.item_locals.len() {
            if self.item_locals[i].decl == d.node {
                return self.item_locals[i].local;
            }
        }
        let l = self.body.add_local(
            ir::LocalDecl { ty: ty, storage: ir::LS_STATIC_REF, is_mutable: true, span: sp, decl: NODE_NONE, item: d },
        );
        self.item_locals.push(Binding { decl: d.node, local: l });
        return l;
    }

    // ---- entry ------------------------------------------------------------------------------------

    /// Lower function/method `fnode`. Returns false (with `err` set) when a construct is not yet
    /// supported; the produced body is then incomplete and must be discarded.
    pub fn lower_fn(self: &mut Self, fnode: NodeId) bool {
        let fd = self.f.node(fnode).as_data.function;
        self.body.is_generic = fd.generics.len != 0;
        let sp = self.f.node(fnode).span;
        // Return slots first (locals [0, returns)), then arguments -- a fixed layout the verifier
        // and printer rely on.
        let rets = fd.returns;
        for i in 0..rets.len {
            let rn = unsafe self.f.list(rets)[i as usize];
            let rt = self.ret_slot_type(rn);
            let _ = self.body.add_local(
                ir::LocalDecl {
                    ty: rt,
                    storage: ir::LS_RET,
                    is_mutable: true,
                    span: sp,
                    decl: NODE_NONE,
                    item: DefId { module: 0, node: NODE_NONE },
                },
            );
        }
        self.body.returns = rets.len;
        let params = fd.params;
        for i in 0..params.len {
            let pn = unsafe self.f.list(params)[i as usize];
            let pd = self.f.node(pn).as_data.parameter;
            let l = self.body.add_local(
                ir::LocalDecl {
                    ty: self.f.node_type(pn),
                    storage: ir::LS_ARG,
                    is_mutable: pd.is_mutable,
                    span: self.f.node(pn).span,
                    decl: pn,
                    item: DefId { module: 0, node: NODE_NONE },
                },
            );
            self.bind(pn, l);
        }
        self.body.args = params.len;
        self.body.entry = self.open_block();
        self.cur = self.body.entry;
        self.run_start = 0;
        self.scope_enter();
        self.lower_stmt(fd.body);
        self.scope_exit();
        // Fall-off return (void functions; a returning tail already sealed the block).
        let t = self.term0(ir::TM_RETURN, sp);
        let end = self.open_block();
        self.seal(t, end);
        let u = self.term0(ir::TM_UNREACHABLE, sp);
        let dead = self.open_block();
        self.seal(u, dead);
        // The trailing block the seal opened stays unsealed; drop it.
        while self.body.blocks.len() != 0 && !self.body.blocks.at(self.body.blocks.len() - 1).sealed {
            let _ = self.body.blocks.pop();
        }
        return self.err.len() == 0;
    }

    /// Lower a closure's body: parameters then captures become argument locals (captures bind their
    /// ORIGINAL declaring nodes, so the body's uses resolve to them).
    pub fn lower_closure_body(self: &mut Self, cnode: NodeId) bool {
        let cd = self.f.node(cnode).as_data.closure;
        let sp = self.f.node(cnode).span;
        let rets = cd.returns;
        for i in 0..rets.len {
            let rn = unsafe self.f.list(rets)[i as usize];
            let _ = self.body.add_local(
                ir::LocalDecl {
                    ty: self.f.node_type(rn),
                    storage: ir::LS_RET,
                    is_mutable: true,
                    span: sp,
                    decl: NODE_NONE,
                    item: DefId { module: 0, node: NODE_NONE },
                },
            );
        }
        self.body.returns = rets.len;
        let params = cd.params;
        for i in 0..params.len {
            let pn = unsafe self.f.list(params)[i as usize];
            let l = self.body.add_local(
                ir::LocalDecl {
                    ty: self.f.node_type(pn),
                    storage: ir::LS_ARG,
                    is_mutable: false,
                    span: self.f.node(pn).span,
                    decl: pn,
                    item: DefId { module: 0, node: NODE_NONE },
                },
            );
            self.bind(pn, l);
        }
        let caps = cd.captures;
        for i in 0..caps.len {
            let c = unsafe self.f.list(caps)[i as usize];
            let decl = self.cap_decl(c);
            let l = self.body.add_local(
                ir::LocalDecl {
                    ty: self.f.node_type(c),
                    storage: ir::LS_ARG,
                    is_mutable: true,
                    span: self.f.node(c).span,
                    decl: decl,
                    item: DefId { module: 0, node: NODE_NONE },
                },
            );
            if decl != NODE_NONE {
                self.bind(decl, l);
            }
        }
        self.body.args = params.len + caps.len;
        self.body.entry = self.open_block();
        self.cur = self.body.entry;
        self.run_start = 0;
        self.scope_enter();
        if cd.expr_body && self.body.returns != 0 {
            let pl = self.place_of_local(0);
            self.lower_value_into(cd.body, pl);
        } else {
            self.lower_stmt(cd.body);
        }
        self.scope_exit();
        let t = self.term0(ir::TM_RETURN, sp);
        let end = self.open_block();
        self.seal(t, end);
        while self.body.blocks.len() != 0 && !self.body.blocks.at(self.body.blocks.len() - 1).sealed {
            let _ = self.body.blocks.pop();
        }
        return self.err.len() == 0;
    }

    /// Lower a constant/static initializer expression as a one-return body.
    pub fn lower_const(self: &mut Self, cnode: NodeId) bool {
        let cd = self.f.node(cnode).as_data.const_def;
        let sp = self.f.node(cnode).span;
        let ty = self.f.node_type(cnode);
        let _ = self.body.add_local(
            ir::LocalDecl {
                ty: ty,
                storage: ir::LS_RET,
                is_mutable: true,
                span: sp,
                decl: NODE_NONE,
                item: DefId { module: 0, node: NODE_NONE },
            },
        );
        self.body.returns = 1;
        self.body.entry = self.open_block();
        self.cur = self.body.entry;
        self.run_start = 0;
        if cd.value != NODE_NONE {
            let op = self.lower_expr(cd.value);
            if op != ir::IR_NONE {
                let pl = self.place_of_local(0);
                let rv = self.rv_use(op, ty);
                self.assign(pl, rv, sp);
            }
        }
        let t = self.term0(ir::TM_RETURN, sp);
        let end = self.open_block();
        self.seal(t, end);
        while self.body.blocks.len() != 0 && !self.body.blocks.at(self.body.blocks.len() - 1).sealed {
            let _ = self.body.blocks.pop();
        }
        return self.err.len() == 0;
    }

    // A return slot's declared type: returns are PARAMETER nodes (named) or bare type nodes.
    fn ret_slot_type(self: &mut Self, rn: NodeId) TypeId {
        return self.f.node_type(rn);
    }

    // ---- statements -------------------------------------------------------------------------------

    fn lower_stmt(self: &mut Self, id: NodeId) {
        if id == NODE_NONE || self.err.len() != 0 {
            return;
        }
        let k = self.f.node(id).kind;
        let _sp = self.f.node(id).span;
        if k == NodeKind::NODE_BLOCK {
            self.scope_enter();
            let stmts = self.f.node(id).as_data.block.statements;
            for i in 0..stmts.len {
                self.lower_stmt(unsafe self.f.list(stmts)[i as usize]);
                if self.err.len() != 0 {
                    return;
                }
            }
            self.scope_exit();
        } else if k == NodeKind::NODE_LET {
            self.lower_let(id);
        } else if k == NodeKind::NODE_EXPRESSION_STATEMENT {
            let v = self.f.node(id).as_data.single.value;
            let _ = self.lower_expr(v);
        } else if k == NodeKind::NODE_RETURN {
            self.lower_return(id);
        } else if k == NodeKind::NODE_IF {
            self.lower_if_stmt(id);
        } else if k == NodeKind::NODE_WHILE {
            self.lower_while(id);
        } else if k == NodeKind::NODE_FOR {
            self.lower_for(id);
        } else if k == NodeKind::NODE_INLINE_FOR {
            // Numeric unroll is an emission concern (the bounds fold at const evaluation); the loop lowers
            // structurally like `for` so its body is verified Core IR.
            self.lower_for(id);
        } else if k == NodeKind::NODE_BREAK {
            self.lower_break(id);
        } else if k == NodeKind::NODE_CONTINUE {
            self.lower_continue(id);
        } else if k == NodeKind::NODE_DEFER {
            self.defers.push(id);
        } else if k == NodeKind::NODE_MATCH {
            let _ = self.lower_match(id, ir::IR_NONE);
        } else if k == NodeKind::NODE_ASM {
            self.lower_asm(id);
        } else if k == NodeKind::NODE_STATIC_ASSERT || k == NodeKind::NODE_CONST || k == NodeKind::NODE_FUNCTION || k == NodeKind::NODE_STRUCT || k == NodeKind::NODE_ENUM || k == NodeKind::NODE_TYPE_ALIAS {
            // Item statements: local consts fold at CTFE; nested items own their own bodies.
        } else {
            // Everything else is an expression in statement position.
            let _ = self.lower_expr(id);
        }
    }

    fn lower_let(self: &mut Self, id: NodeId) {
        let ld = self.f.node(id).as_data.let_stmt;
        let sp = self.f.node(id).span;
        let nk = self.f.node(ld.name).kind;
        if nk != NodeKind::NODE_IDENTIFIER {
            // Destructuring let (`let (a, b) = ..`, `let Some(x) = ..`): bind through the pattern
            // machinery against the value.
            if ld.value == NODE_NONE {
                self.fail("let-pattern-without-value");
                return;
            }
            let vop = self.lower_expr(ld.value);
            if vop == ir::IR_NONE {
                return;
            }
            let vpl = self.spill(vop, sp);
            let fail = ir::IR_NONE;
            self.pattern_bind(ld.name, vpl, fail);
            return;
        }
        let ty = self.f.node_type(id);
        let l = self.body.add_local(
            ir::LocalDecl {
                ty: ty,
                storage: ir::LS_USER,
                is_mutable: ld.is_mutable,
                span: sp,
                decl: id,
                item: DefId { module: 0, node: NODE_NONE },
            },
        );
        self.bind(id, l);
        self.bind(ld.name, l);
        if ld.value != NODE_NONE {
            let op = self.lower_expr(ld.value);
            if op == ir::IR_NONE {
                return;
            }
            let pl = self.place_of_local(l);
            let rv = self.rv_use(op, ty);
            self.assign(pl, rv, sp);
        }
    }

    fn lower_return(self: &mut Self, id: NodeId) {
        let rd = self.f.node(id).as_data.return_stmt;
        let sp = self.f.node(id).span;
        for i in 0..rd.values.len {
            let v = unsafe self.f.list(rd.values)[i as usize];
            let op = self.lower_expr(v);
            if op == ir::IR_NONE {
                return;
            }
            let pl = self.place_of_local(i);
            let ty = self.body.locals.at(i as usize).ty;
            let rv = self.rv_use(op, ty);
            self.assign(pl, rv, sp);
        }
        self.emit_defers_down_to(0);
        let t = self.term0(ir::TM_RETURN, sp);
        let next = self.open_block();
        self.seal(t, next);
    }

    fn find_loop(self: &Self, label: tok::Span) i64 {
        let mut i = self.loops.len();
        while i > 0 {
            i -= 1;
            if label.end <= label.start {
                return i as i64;
            }
            let l = self.loops[i].label;
            if l.end > l.start && l.end - l.start == label.end - label.start && self.src.slice(
                l.start as usize,
                l.end as usize,
            ) == self.src.slice(label.start as usize, label.end as usize) {
                return i as i64;
            }
        }
        return -1;
    }

    fn lower_break(self: &mut Self, id: NodeId) {
        let fd = self.f.node(id).as_data.flow;
        let sp = self.f.node(id).span;
        let li = self.find_loop(fd.label);
        if li < 0 {
            self.fail("break-outside-loop");
            return;
        }
        let lc = self.loops[li as usize];
        if fd.value != NODE_NONE {
            let op = self.lower_expr(fd.value);
            if op == ir::IR_NONE {
                return;
            }
            if lc.result != ir::IR_NONE {
                let ty = self.body.places.at(lc.result as usize).ty;
                let rv = self.rv_use(op, ty);
                self.assign(lc.result, rv, sp);
            }
        }
        self.emit_defers_down_to(lc.defer_depth);
        let t = self.goto_term(lc.brk, sp);
        let next = self.open_block();
        self.seal(t, next);
    }

    fn lower_continue(self: &mut Self, id: NodeId) {
        let fd = self.f.node(id).as_data.flow;
        let sp = self.f.node(id).span;
        let li = self.find_loop(fd.label);
        if li < 0 {
            self.fail("continue-outside-loop");
            return;
        }
        let lc = self.loops[li as usize];
        self.emit_defers_down_to(lc.defer_depth);
        let t = self.goto_term(lc.cont, sp);
        let next = self.open_block();
        self.seal(t, next);
    }

    // Bool switch: true -> `then`, otherwise -> `els`. Continues writing in `then`.
    fn branch_bool(self: &mut Self, cond: ir::OperandId, then_b: ir::BlockId, els: ir::BlockId, sp: tok::Span) {
        let mut t = self.term0(ir::TM_SWITCH, sp);
        t.a = cond;
        t.sw_start = self.body.switch_pool.len() as u32;
        self.body.switch_pool.push(1u64 << 32 | then_b as u64);
        t.sw_len = 1;
        t.t0 = els;
        self.seal(t, then_b);
    }

    fn lower_if_stmt(self: &mut Self, id: NodeId) {
        let d = self.f.node(id).as_data.if_stmt;
        let sp = self.f.node(id).span;
        let cop = self.lower_expr(d.condition);
        if cop == ir::IR_NONE {
            return;
        }
        let then_b = self.open_block();
        let els_b = self.open_block();
        let join = self.open_block();
        self.branch_bool(cop, then_b, els_b, sp);
        self.lower_stmt(d.then_branch);
        self.seal(self.goto_term(join, sp), els_b);
        if d.else_branch != NODE_NONE {
            self.lower_stmt(d.else_branch);
        }
        self.seal(self.goto_term(join, sp), join);
    }

    fn lower_while(self: &mut Self, id: NodeId) {
        let d = self.f.node(id).as_data.while_stmt;
        let sp = self.f.node(id).span;
        let head = self.open_block();
        let body_b = self.open_block();
        let exit = self.open_block();
        if d.is_do {
            self.seal(self.goto_term(body_b, sp), body_b);
        } else {
            self.seal(self.goto_term(head, sp), head);
        }
        if !d.is_do {
            // head: evaluate the condition (an infinite `loop` has no condition node)
            if d.condition != NODE_NONE {
                let cop = self.lower_expr(d.condition);
                if cop == ir::IR_NONE {
                    return;
                }
                self.branch_bool(cop, body_b, exit, sp);
            } else {
                self.seal(self.goto_term(body_b, sp), body_b);
            }
        }
        self.loops.push(
            LoopCtx { label: d.label, brk: exit, cont: head, defer_depth: self.defers.len(), result: ir::IR_NONE },
        );
        self.lower_stmt(d.body);
        let _ = self.loops.pop();
        if d.is_do {
            // tail: condition decides back-edge vs exit; `head` is the continue target
            self.seal(self.goto_term(head, sp), head);
            if d.condition != NODE_NONE {
                let cop = self.lower_expr(d.condition);
                if cop == ir::IR_NONE {
                    return;
                }
                self.branch_bool(cop, body_b, exit, sp);
                self.seal(self.goto_term(exit, sp), exit);
            } else {
                self.seal(self.goto_term(body_b, sp), exit);
            }
        } else {
            self.seal(self.goto_term(head, sp), exit);
        }
    }

    // `for` over a range literal lowers to an index loop. `inline for` over `fields`/`variants`/
    // `payloads` binders (angle 3) stays a compatibility intrinsic: the binder's operands feed one
    // IN_REFLECT assignment to the binding, and the body lowers once with normal semantics --
    // substitution-aware instance lowering replaces this with real per-field expansion.
    fn lower_for(self: &mut Self, id: NodeId) {
        let d = self.f.node(id).as_data.for_stmt;
        let sp = self.f.node(id).span;
        if self.f.node(d.iterable).kind == NodeKind::NODE_CALL {
            let cd = self.f.node(d.iterable).as_data.call;
            let ci2 = self.f.call_info(d.iterable);
            let mut resolved = false;
            switch ci2 {
                Some(v2) => {
                    resolved = ci_decl(v2) != NODE_NONE;
                    let _ = v2;
                },
                None => {},
            };
            if !resolved && self.f.res(cd.callee).node == NODE_NONE {
                let ity = self.f.node_type(id);
                let start = self.body.oper_pool.len() as u32;
                let mut n: u32 = 0;
                for i in 0..cd.args.len {
                    let a = unsafe self.f.list(cd.args)[i as usize];
                    let op = self.lower_expr(a);
                    if op == ir::IR_NONE {
                        return;
                    }
                    self.push_arg_marker(op, &mut n);
                }
                let fresh = self.body.oper_pool.len() as u32;
                let total = fresh - start;
                let mut kept: u32 = 0;
                let mut i2: u32 = 0;
                while i2 < total && kept < n {
                    let v3 = self.body.oper_pool[(start + i2) as usize];
                    self.body.oper_pool.push(v3);
                    kept += 1;
                    i2 += 1;
                }
                let l = self.body.add_local(
                    ir::LocalDecl {
                        ty: ity,
                        storage: ir::LS_USER,
                        is_mutable: false,
                        span: sp,
                        decl: id,
                        item: DefId { module: 0, node: NODE_NONE },
                    },
                );
                self.bind(id, l);
                if d.binding != NODE_NONE {
                    self.bind(d.binding, l);
                }
                let pl = self.place_of_local(l);
                self.assign(
                    pl,
                    ir::Rvalue {
                        kind: ir::RV_INTRINSIC,
                        a: fresh,
                        b: kept,
                        c: ir::IN_REFLECT,
                        target: ity,
                        item: DefId { module: 0, node: NODE_NONE },
                    },
                    sp,
                );
                self.lower_stmt(d.body);
                return;
            }
        }
        if self.f.node(d.iterable).kind != NodeKind::NODE_RANGE {
            let ik = self.f.ty(self.f.node_type(d.iterable)).kind;
            if ik == TypeKind::TYPE_ARRAY || ik == TypeKind::TYPE_SLICE || ik == TypeKind::TYPE_INSTANCE {
                self.lower_for_indexed(id);
                return;
            }
            self.fail_at("for-iterable", id);
            return;
        }
        let rd = self.f.node(d.iterable).as_data.pattern_range;
        let ity = self.f.node_type(id);
        let sop = self.lower_expr(rd.start);
        if sop == ir::IR_NONE {
            return;
        }
        let eop = self.lower_expr(rd.end);
        if eop == ir::IR_NONE {
            return;
        }
        let epl = self.spill(eop, sp);
        // induction variable = the user binding
        let l = self.body.add_local(
            ir::LocalDecl {
                ty: ity,
                storage: ir::LS_USER,
                is_mutable: true,
                span: sp,
                decl: id,
                item: DefId { module: 0, node: NODE_NONE },
            },
        );
        self.bind(id, l);
        if d.binding != NODE_NONE {
            self.bind(d.binding, l);
        }
        let ipl = self.place_of_local(l);
        let rv0 = self.rv_use(sop, ity);
        self.assign(ipl, rv0, sp);
        let head = self.open_block();
        let body_b = self.open_block();
        let step = self.open_block();
        let exit = self.open_block();
        self.seal(self.goto_term(head, sp), head);
        let iop = self.copy_op(ipl);
        let eop2 = self.copy_op(epl);
        let bt = Ast::builtin(BuiltinType::BT_BOOL);
        let ct = self.temp(bt, sp);
        let cpl = self.place_of_local(ct);
        let cmp_op: u32 = if rd.inclusive {
            tt::TokenType::LessThanEqual as u32;
        } else {
            tt::TokenType::LessThan as u32;
        };
        self.assign(
            cpl,
            ir::Rvalue {
                kind: ir::RV_BINARY,
                a: iop,
                b: eop2,
                c: cmp_op as u8,
                target: bt,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        let cop = self.copy_op(cpl);
        self.branch_bool(cop, body_b, exit, sp);
        self.loops.push(
            LoopCtx { label: d.label, brk: exit, cont: step, defer_depth: self.defers.len(), result: ir::IR_NONE },
        );
        self.lower_stmt(d.body);
        let _ = self.loops.pop();
        self.seal(self.goto_term(step, sp), step);
        // step: i = i + 1
        let iop2 = self.copy_op(ipl);
        let one = self.const_op(
            ir::Constant {
                kind: ir::CK_INT,
                ty: ity,
                val: 1,
                raw: sp,
                item: DefId { module: 0, node: NODE_NONE },
                targ_start: 0,
                targ_len: 0,
            },
        );
        self.assign(
            ipl,
            ir::Rvalue {
                kind: ir::RV_BINARY,
                a: iop2,
                b: one,
                c: tt::TokenType::Plus as u8,
                target: ity,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        self.seal(self.goto_term(head, sp), exit);
    }

    // `for` over an indexable sequence (array, slice, sequence value): an index loop over RV_LEN
    // with an explicit element load per iteration -- the uniform sequence model until
    // instance-aware lowering specializes it per concrete carrier.
    fn lower_for_indexed(self: &mut Self, id: NodeId) {
        let d = self.f.node(id).as_data.for_stmt;
        let sp = self.f.node(id).span;
        let ipl = self.lower_place(d.iterable);
        if ipl == ir::IR_NONE {
            return;
        }
        let elem_ty = self.f.node_type(id);
        let ut = Ast::builtin(BuiltinType::BT_USIZE);
        let ll = self.temp(ut, sp);
        let lpl = self.place_of_local(ll);
        self.assign(
            lpl,
            ir::Rvalue { kind: ir::RV_LEN, a: ipl, b: 0, c: 0, target: ut, item: DefId { module: 0, node: NODE_NONE } },
            sp,
        );
        let il = self.temp(ut, sp);
        let idx_pl = self.place_of_local(il);
        let zero = self.const_op(
            ir::Constant {
                kind: ir::CK_INT,
                ty: ut,
                val: 0,
                raw: sp,
                item: DefId { module: 0, node: NODE_NONE },
                targ_start: 0,
                targ_len: 0,
            },
        );
        let rz = self.rv_use(zero, ut);
        self.assign(idx_pl, rz, sp);
        let el = self.body.add_local(
            ir::LocalDecl {
                ty: elem_ty,
                storage: ir::LS_USER,
                is_mutable: true,
                span: sp,
                decl: id,
                item: DefId { module: 0, node: NODE_NONE },
            },
        );
        self.bind(id, el);
        if d.binding != NODE_NONE {
            self.bind(d.binding, el);
        }
        let head = self.open_block();
        let body_b = self.open_block();
        let step = self.open_block();
        let exit = self.open_block();
        self.seal(self.goto_term(head, sp), head);
        let iop = self.copy_op(idx_pl);
        let lop = self.copy_op(lpl);
        let bt = Ast::builtin(BuiltinType::BT_BOOL);
        let ct = self.temp(bt, sp);
        let cpl = self.place_of_local(ct);
        self.assign(
            cpl,
            ir::Rvalue {
                kind: ir::RV_BINARY,
                a: iop,
                b: lop,
                c: tt::TokenType::LessThan as u8,
                target: bt,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        let cop = self.copy_op(cpl);
        self.branch_bool(cop, body_b, exit, sp);
        let iop2 = self.copy_op(idx_pl);
        let epl = self.place_project(ipl, ir::Projection { kind: ir::PJ_INDEX_OP, data: iop2, sub: 0, ty: elem_ty });
        let eop = self.copy_op(epl);
        let erv = self.rv_use(eop, elem_ty);
        let bind_pl = self.place_of_local(el);
        self.assign(bind_pl, erv, sp);
        self.loops.push(
            LoopCtx { label: d.label, brk: exit, cont: step, defer_depth: self.defers.len(), result: ir::IR_NONE },
        );
        self.lower_stmt(d.body);
        let _ = self.loops.pop();
        self.seal(self.goto_term(step, sp), step);
        let iop3 = self.copy_op(idx_pl);
        let one = self.const_op(
            ir::Constant {
                kind: ir::CK_INT,
                ty: ut,
                val: 1,
                raw: sp,
                item: DefId { module: 0, node: NODE_NONE },
                targ_start: 0,
                targ_len: 0,
            },
        );
        self.assign(
            idx_pl,
            ir::Rvalue {
                kind: ir::RV_BINARY,
                a: iop3,
                b: one,
                c: tt::TokenType::Plus as u8,
                target: ut,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        self.seal(self.goto_term(head, sp), exit);
    }

    fn lower_asm(self: &mut Self, id: NodeId) {
        let d = self.f.node(id).as_data.asm_stmt;
        let sp = self.f.node(id).span;
        let start = self.body.oper_pool.len() as u32;
        let mut n: u32 = 0;
        for i in 0..d.outputs.len {
            let e = unsafe self.f.list(d.outputs)[i as usize];
            let op = self.lower_expr(e);
            if op == ir::IR_NONE {
                return;
            }
            self.body.oper_pool.push(op);
            n += 1;
        }
        for i in 0..d.inputs.len {
            let e = unsafe self.f.list(d.inputs)[i as usize];
            let op = self.lower_expr(e);
            if op == ir::IR_NONE {
                return;
            }
            self.body.oper_pool.push(op);
            n += 1;
        }
        self.stmt(ir::Statement { kind: ir::ST_ASM, place: ir::IR_NONE, rvalue: ir::IR_NONE, a: start, b: n, span: sp });
    }

    // ---- expressions ------------------------------------------------------------------------------

    // Lower expression `id` and return its operand, or IR_NONE on failure. Adjustments (coercion,
    // dyn erasure) recorded at the node wrap the base operand here, so consumers never re-read the
    // side tables.
    fn lower_expr(self: &mut Self, id: NodeId) ir::OperandId {
        if id == NODE_NONE || self.err.len() != 0 {
            return ir::IR_NONE;
        }
        let base = self.lower_expr_base(id);
        if base == ir::IR_NONE {
            return ir::IR_NONE;
        }
        return self.apply_adjust(id, base);
    }

    fn apply_adjust(self: &mut Self, id: NodeId, base: ir::OperandId) ir::OperandId {
        let sp = self.f.node(id).span;
        let mut op = base;
        let co = self.f.coercion(id);
        if co != null {
            let target = unsafe co.target;
            let method = unsafe co.method;
            let t = self.temp(target, sp);
            let pl = self.place_of_local(t);
            let ck: u8 = if method.node != NODE_NONE {
                ir::CAST_COERCE_FROM;
            } else {
                ir::CAST_NUMERIC;
            };
            self.assign(pl, ir::Rvalue { kind: ir::RV_CAST, a: op, b: ck, c: 0, target: target, item: method }, sp);
            op = self.copy_op(pl);
        }
        let dy = self.f.dyn_conv(id);
        if dy != null {
            let dt = unsafe dy.dyn_ty;
            let t = self.temp(dt, sp);
            let pl = self.place_of_local(t);
            self.assign(
                pl,
                ir::Rvalue {
                    kind: ir::RV_DYN,
                    a: op,
                    b: unsafe dy.alloc,
                    c: 0,
                    target: dt,
                    item: DefId { module: 0, node: NODE_NONE },
                },
                sp,
            );
            op = self.copy_op(pl);
        }
        return op;
    }

    fn lower_expr_base(self: &mut Self, id: NodeId) ir::OperandId {
        let k = self.f.node(id).kind;
        let sp = self.f.node(id).span;
        let ty = self.f.node_type(id);
        if k == NodeKind::NODE_LITERAL {
            return self.lower_literal(id);
        }
        if k == NodeKind::NODE_IDENTIFIER || k == NodeKind::NODE_MEMBER || k == NodeKind::NODE_INDEX {
            let pl = self.lower_place(id);
            if pl == ir::IR_NONE {
                return ir::IR_NONE;
            }
            return self.copy_op(pl);
        }
        if k == NodeKind::NODE_UNARY {
            return self.lower_unary(id);
        }
        if k == NodeKind::NODE_BINARY {
            return self.lower_binary(id);
        }
        if k == NodeKind::NODE_ASSIGNMENT {
            return self.lower_assignment(id);
        }
        if k == NodeKind::NODE_CALL {
            return self.lower_call(id);
        }
        if k == NodeKind::NODE_CAST {
            let d = self.f.node(id).as_data.cast;
            let op = self.lower_expr(d.expression);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            let t = self.temp(ty, sp);
            let pl = self.place_of_local(t);
            self.assign(
                pl,
                ir::Rvalue {
                    kind: ir::RV_CAST,
                    a: op,
                    b: ir::CAST_NUMERIC,
                    c: 0,
                    target: ty,
                    item: DefId { module: 0, node: NODE_NONE },
                },
                sp,
            );
            return self.copy_op(pl);
        }
        if k == NodeKind::NODE_STRUCT_INITIALIZER {
            return self.lower_struct_init(id);
        }
        if k == NodeKind::NODE_ARRAY_LITERAL || k == NodeKind::NODE_TUPLE {
            return self.lower_array_or_tuple(id);
        }
        if k == NodeKind::NODE_RANGE {
            return self.lower_range(id);
        }
        if k == NodeKind::NODE_IF {
            return self.lower_if_expr(id);
        }
        if k == NodeKind::NODE_MATCH {
            let t = self.temp(ty, sp);
            let pl = self.place_of_local(t);
            if !self.lower_match(id, pl) {
                return ir::IR_NONE;
            }
            return self.copy_op(pl);
        }
        if k == NodeKind::NODE_WHILE {
            // `loop { .. break v; .. }` in value position
            let t = self.temp(ty, sp);
            let pl = self.place_of_local(t);
            self.lower_loop_expr(id, pl);
            return self.copy_op(pl);
        }
        if k == NodeKind::NODE_BLOCK {
            let t = self.temp(ty, sp);
            let pl = self.place_of_local(t);
            self.lower_value_block(id, pl);
            return self.copy_op(pl);
        }
        if k == NodeKind::NODE_SIZEOF || k == NodeKind::NODE_ALIGNOF {
            let ik: u8 = if k == NodeKind::NODE_SIZEOF {
                ir::IN_SIZEOF;
            } else {
                ir::IN_ALIGNOF;
            };
            let t = self.temp(ty, sp);
            let pl = self.place_of_local(t);
            self.assign(
                pl,
                ir::Rvalue {
                    kind: ir::RV_INTRINSIC,
                    a: self.body.oper_pool.len() as u32,
                    b: 0,
                    c: ik,
                    target: ty,
                    item: DefId { module: 0, node: NODE_NONE },
                },
                sp,
            );
            return self.copy_op(pl);
        }
        if k == NodeKind::NODE_VA_EXPR {
            return self.lower_va(id);
        }
        if k == NodeKind::NODE_CLOSURE {
            return self.lower_closure(id);
        }
        if k == NodeKind::NODE_GENERIC_SPECIALIZATION {
            let d = self.f.node(id).as_data.specialization;
            return self.lower_expr_named(d.expression, id);
        }
        if k == NodeKind::NODE_TYPE_PATH {
            // A path in value position: unit variant construction or an item constant.
            return self.lower_path_value(id);
        }
        if k == NodeKind::NODE_NEW {
            let nd = self.f.node(id).as_data.new_expr;
            let iop = self.lower_expr(nd.initializer);
            if iop == ir::IR_NONE {
                return ir::IR_NONE;
            }
            let start = self.body.oper_pool.len() as u32;
            self.body.oper_pool.push(iop);
            let t = self.temp(ty, sp);
            let pl = self.place_of_local(t);
            self.assign(
                pl,
                ir::Rvalue {
                    kind: ir::RV_INTRINSIC,
                    a: start,
                    b: 1,
                    c: ir::IN_NEW,
                    target: ty,
                    item: DefId { module: 0, node: NODE_NONE },
                },
                sp,
            );
            return self.copy_op(pl);
        }
        self.fail_at("expr-kind", id);
        return ir::IR_NONE;
    }

    // Lower `inner` but read semantic facts recorded on `outer` (generic specialization wraps the
    // callee/identifier; resolutions and types land on the wrapper).
    fn lower_expr_named(self: &mut Self, inner: NodeId, outer: NodeId) ir::OperandId {
        let k = self.f.node(inner).kind;
        if k == NodeKind::NODE_IDENTIFIER || k == NodeKind::NODE_TYPE_PATH || k == NodeKind::NODE_MEMBER {
            // The wrapper's own type/resolution stand for the specialized value.
            let d = self.f.res(outer);
            let ty = self.f.node_type(outer);
            let sp = self.f.node(outer).span;
            if d.node != NODE_NONE {
                return self.const_op(
                    ir::Constant { kind: ir::CK_ITEM, ty: ty, val: 0, raw: sp, item: d, targ_start: 0, targ_len: 0 },
                );
            }
        }
        return self.lower_expr(inner);
    }

    fn lower_literal(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.literal;
        let ty = self.f.node_type(id);
        let _sp = self.f.node(id).span;
        let no = DefId { module: 0, node: NODE_NONE };
        let w = self.f.wide_lit(id);
        if w != null {
            return self.const_op(
                ir::Constant { kind: ir::CK_WIDE, ty: ty, val: 0, raw: d.raw, item: no, targ_start: 0, targ_len: 0 },
            );
        }
        let t = d.token_type;
        if t == tt::TokenType::True {
            return self.const_op(
                ir::Constant { kind: ir::CK_BOOL, ty: ty, val: 1, raw: d.raw, item: no, targ_start: 0, targ_len: 0 },
            );
        }
        if t == tt::TokenType::False {
            return self.const_op(
                ir::Constant { kind: ir::CK_BOOL, ty: ty, val: 0, raw: d.raw, item: no, targ_start: 0, targ_len: 0 },
            );
        }
        if t == tt::TokenType::StringLiteral || t == tt::TokenType::MatchertextLiteral || t == tt::TokenType::RawStringLiteral || t == tt::TokenType::ByteStringLiteral {
            return self.const_op(
                ir::Constant { kind: ir::CK_STR, ty: ty, val: 0, raw: d.raw, item: no, targ_start: 0, targ_len: 0 },
            );
        }
        if t == tt::TokenType::FloatLiteral {
            return self.const_op(
                ir::Constant { kind: ir::CK_FLOAT, ty: ty, val: 0, raw: d.raw, item: no, targ_start: 0, targ_len: 0 },
            );
        }
        if t == tt::TokenType::Null {
            return self.const_op(
                ir::Constant { kind: ir::CK_INT, ty: ty, val: 0, raw: d.raw, item: no, targ_start: 0, targ_len: 0 },
            );
        }
        // Integer/char literals: the exact value is CTFE's business; the span keeps the
        // spelling, `val` carries the common decimal fast path.
        return self.const_op(
            ir::Constant {
                kind: ir::CK_INT,
                ty: ty,
                val: parse_dec(self.src, d.raw),
                raw: d.raw,
                item: no,
                targ_start: 0,
                targ_len: 0,
            },
        );
    }

    fn lower_unary(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.unary;
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        if d.op == tt::TokenType::Ampersand || d.op == tt::TokenType::AmpersandAmpersand {
            let pl = self.lower_place(d.operand);
            if pl == ir::IR_NONE {
                return ir::IR_NONE;
            }
            let mutable: u32 = if d.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                1;
            } else {
                0;
            };
            let t = self.temp(ty, sp);
            let tp = self.place_of_local(t);
            self.assign(
                tp,
                ir::Rvalue {
                    kind: ir::RV_REF,
                    a: pl,
                    b: mutable,
                    c: 0,
                    target: ty,
                    item: DefId { module: 0, node: NODE_NONE },
                },
                sp,
            );
            return self.copy_op(tp);
        }
        if d.op == tt::TokenType::Star {
            let pl = self.lower_place(id);
            if pl == ir::IR_NONE {
                return ir::IR_NONE;
            }
            return self.copy_op(pl);
        }
        if d.op == tt::TokenType::Question {
            return self.lower_question(id, d.operand);
        }
        // Overloaded unary (`-` via Neg, `!` via Not) resolves through op_method like binaries.
        switch self.f.op_method(id) {
            Some(m) => {
                return self.lower_op_call(
                    id,
                    (m >> 32) as ModuleId,
                    (m & 0xFFFFFFFFu64) as NodeId,
                    d.operand,
                    NODE_NONE,
                );
            },
            None => {},
        };
        let op = self.lower_expr(d.operand);
        if op == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let t = self.temp(ty, sp);
        let pl = self.place_of_local(t);
        self.assign(
            pl,
            ir::Rvalue {
                kind: ir::RV_UNARY,
                a: op,
                b: d.op as u32,
                c: 0,
                target: ty,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        return self.copy_op(pl);
    }

    // `expr?`: test the carrier's discriminant; the ok arm yields the payload, the error arm fills
    // the return slot through the IN_TRY_ERR compatibility intrinsic (the `From` conversion and
    // rewrap stay CTFE/codegen-owned) and returns through the pending defers.
    fn lower_question(self: &mut Self, id: NodeId, operand: NodeId) ir::OperandId {
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        let vop = self.lower_expr(operand);
        if vop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let vpl = self.spill(vop, sp);
        let mut ok_ord: i64 = -1;
        let mut vd = DefId { module: 0, node: NODE_NONE };
        self.carrier_ok_variant(self.body.places.at(vpl as usize).ty, &mut ok_ord, &mut vd);
        if ok_ord < 0 {
            self.fail_at("question-carrier", id);
            return ir::IR_NONE;
        }
        let ut = Ast::builtin(BuiltinType::BT_U32);
        let dt = self.temp(ut, sp);
        let dp = self.place_of_local(dt);
        self.assign(
            dp,
            ir::Rvalue {
                kind: ir::RV_DISCRIMINANT,
                a: vpl,
                b: 0,
                c: 0,
                target: ut,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        let oop = self.const_op(
            ir::Constant {
                kind: ir::CK_INT,
                ty: ut,
                val: ok_ord,
                raw: sp,
                item: DefId { module: 0, node: NODE_NONE },
                targ_start: 0,
                targ_len: 0,
            },
        );
        let cond = self.eq_test(dp, oop, sp);
        let ok_b = self.open_block();
        let err_b = self.open_block();
        // true -> ok_b, otherwise err_b; keep writing the ERROR path first, then seal into ok_b.
        let mut tsw = self.term0(ir::TM_SWITCH, sp);
        tsw.a = cond;
        tsw.sw_start = self.body.switch_pool.len() as u32;
        self.body.switch_pool.push(1u64 << 32 | ok_b as u64);
        tsw.sw_len = 1;
        tsw.t0 = err_b;
        self.seal(tsw, err_b);
        if self.body.returns != 0 {
            let rop = self.copy_op(vpl);
            let rt = self.body.locals.at(0).ty;
            let rpl = self.place_of_local(0);
            let start = self.body.oper_pool.len() as u32;
            self.body.oper_pool.push(rop);
            self.assign(
                rpl,
                ir::Rvalue {
                    kind: ir::RV_INTRINSIC,
                    a: start,
                    b: 1,
                    c: ir::IN_TRY_ERR,
                    target: rt,
                    item: DefId { module: 0, node: NODE_NONE },
                },
                sp,
            );
        }
        self.emit_defers_down_to(0);
        self.seal(self.term0(ir::TM_RETURN, sp), ok_b);
        let ppl = self.place_project(
            vpl,
            ir::Projection {
                kind: ir::PJ_DOWNCAST,
                data: ok_ord as u32,
                sub: vd.node,
                ty: self.body.places.at(vpl as usize).ty,
            },
        );
        let fpl = self.place_project(ppl, ir::Projection { kind: ir::PJ_FIELD, data: 0, sub: NODE_NONE, ty: ty });
        return self.copy_op(fpl);
    }

    // The payload-carrying "ok" variant (Some/Ok) of a `?` carrier type, by ordinal + decl.
    fn carrier_ok_variant(self: &Self, t: TypeId, ord: &mut i64, vd: &mut DefId) {
        *ord = -1;
        let y = *self.f.ty(t);
        let mut em: ModuleId = 0;
        let mut ed = NODE_NONE;
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.f.instance(y.as_data.inst);
            em = it.module;
            ed = it.decl;
        } else if y.kind == TypeKind::TYPE_ENUM {
            em = y.module;
            ed = y.as_data.decl;
        }
        if ed == NODE_NONE {
            return;
        }
        let a = unsafe &*(&*self.pkg).module_ast_const(em);
        if a.at_const(ed).kind != NodeKind::NODE_ENUM {
            return;
        }
        let src = unsafe (&*self.pkg).modules.at(em as usize).source.as_str();
        let ms = a.at_const(ed).as_data.aggregate.members;
        for j in 0..ms.len {
            let vn = unsafe a.list(ms)[j as usize];
            let nsp = a.at_const(a.at_const(vn).as_data.variant.name).as_data.name.text;
            let nm = src.slice(nsp.start as usize, nsp.end as usize);
            if nm == "Some" || nm == "Ok" {
                *ord = j;
                *vd = DefId { module: em, node: vn };
                return;
            }
        }
    }

    fn lower_binary(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.binary;
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        if d.op == tt::TokenType::AmpersandAmpersand || d.op == tt::TokenType::PipePipe {
            // result = lhs; if (deciding) result = rhs
            let t = self.temp(ty, sp);
            let pl = self.place_of_local(t);
            let lop = self.lower_expr(d.left);
            if lop == ir::IR_NONE {
                return ir::IR_NONE;
            }
            let rv = self.rv_use(lop, ty);
            self.assign(pl, rv, sp);
            let rhs_b = self.open_block();
            let join = self.open_block();
            let cop = self.copy_op(pl);
            if d.op == tt::TokenType::AmpersandAmpersand {
                self.branch_bool(cop, rhs_b, join, sp);
            } else {
                // ||: false -> evaluate rhs
                let mut tm = self.term0(ir::TM_SWITCH, sp);
                tm.a = cop;
                tm.sw_start = self.body.switch_pool.len() as u32;
                self.body.switch_pool.push(0u64 << 32 | rhs_b as u64);
                tm.sw_len = 1;
                tm.t0 = join;
                self.seal(tm, rhs_b);
            }
            let rop = self.lower_expr(d.right);
            if rop == ir::IR_NONE {
                return ir::IR_NONE;
            }
            let rv2 = self.rv_use(rop, ty);
            self.assign(pl, rv2, sp);
            self.seal(self.goto_term(join, sp), join);
            return self.copy_op(pl);
        }
        switch self.f.op_method(id) {
            Some(m) => {
                return self.lower_op_call(id, (m >> 32) as ModuleId, (m & 0xFFFFFFFFu64) as NodeId, d.left, d.right);
            },
            None => {},
        };
        let lop = self.lower_expr(d.left);
        if lop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let rop = self.lower_expr(d.right);
        if rop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let t = self.temp(ty, sp);
        let pl = self.place_of_local(t);
        self.assign(
            pl,
            ir::Rvalue {
                kind: ir::RV_BINARY,
                a: lop,
                b: rop,
                c: d.op as u8,
                target: ty,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        return self.copy_op(pl);
    }

    // An operator method call (binary/compound/unary overloads): receiver is the left operand.
    fn lower_op_call(self: &mut Self, id: NodeId, m: ModuleId, decl: NodeId, lhs: NodeId, rhs: NodeId) ir::OperandId {
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        let lop = self.lower_expr(lhs);
        if lop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let start = self.body.oper_pool.len() as u32;
        self.body.oper_pool.push(lop);
        let mut n: u32 = 1;
        if rhs != NODE_NONE {
            let rop = self.lower_expr(rhs);
            if rop == ir::IR_NONE {
                return ir::IR_NONE;
            }
            self.body.oper_pool.push(rop);
            n += 1;
        }
        return self.emit_call(DefId { module: m, node: decl }, ir::IR_NONE, start, n, 0, 0, ty, sp);
    }

    // Copy the checker's bound generic arguments for `node` into targ_pool; returns the count
    // (the range starts at the pool length the caller sampled first).
    fn copy_targs(self: &mut Self, node: NodeId) u32 {
        let mu = self.f.generic_args(node);
        if mu == null {
            return 0;
        }
        let n = unsafe mu.n;
        for i in 0..n {
            self.body.targ_pool.push(unsafe mu.args[i as usize]);
        }
        return n;
    }

    // Shared call emission: args already in oper_pool[start, start+n); returns the result operand.
    fn emit_call(
        self: &mut Self,
        callee: DefId,
        callee_op: ir::OperandId,
        start: u32,
        n: u32,
        targs_start: u32,
        targs_len: u32,
        ty: TypeId,
        sp: tok::Span,
    ) ir::OperandId {
        let t = self.temp(ty, sp);
        let dst = self.place_of_local(t);
        let dstart = self.body.dest_pool.len() as u32;
        self.body.dest_pool.push(dst);
        let mut tm = self.term0(ir::TM_CALL, sp);
        tm.callee = callee;
        tm.a = callee_op;
        tm.args_start = start;
        tm.args_len = n;
        tm.dests_start = dstart;
        tm.dests_len = 1;
        tm.targs_start = targs_start;
        tm.targs_len = targs_len;
        let cont = self.open_block();
        tm.t0 = cont;
        self.seal(tm, cont);
        return self.copy_op(dst);
    }

    fn lower_call(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.call;
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        let ck = self.f.node(d.callee).kind;
        // Method call: receiver first, then arguments; the selected target comes from call_info.
        let ci = self.f.call_info(id);
        let mut target = DefId { module: 0, node: NODE_NONE };
        switch ci {
            Some(v) => {
                target = DefId { module: ci_module(v), node: ci_decl(v) };
            },
            None => {},
        };
        // `type_info::<T>()` / `zeroed::<T>()`: compiler intrinsics, not resolved functions.
        if target.node == NODE_NONE && self.is_intrinsic_callee(d.callee, "type_info") {
            return self.intrinsic_value(ir::IN_TYPE_INFO, ty, sp);
        }
        if target.node == NODE_NONE && self.is_intrinsic_callee(d.callee, "zeroed") {
            return self.intrinsic_value(ir::IN_ZEROED, ty, sp);
        }
        let start = self.body.oper_pool.len() as u32;
        let mut n: u32 = 0;
        let mut callee_op = ir::IR_NONE;
        if ck == NodeKind::NODE_MEMBER && !self.f.node(d.callee).as_data.member.path && target.node != NODE_NONE {
            let recv = self.f.node(d.callee).as_data.member.object;
            let rop = self.lower_expr(recv);
            if rop == ir::IR_NONE {
                return ir::IR_NONE;
            }
            self.push_arg_marker(rop, &mut n);
        } else if target.node == NODE_NONE {
            // fn-value call (closure, fn pointer): the callee is an operand
            callee_op = self.lower_expr(d.callee);
            if callee_op == ir::IR_NONE {
                return ir::IR_NONE;
            }
        } else {
            // direct call: nothing to evaluate for the callee
        }
        for i in 0..d.args.len {
            let a = unsafe self.f.list(d.args)[i as usize];
            let op = self.lower_expr(a);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            self.push_arg_marker(op, &mut n);
        }
        // Arguments were evaluated in order but interleave with nested calls appending to the pool;
        // re-collect the recorded operands contiguously.
        let ts = self.body.targ_pool.len() as u32;
        let tn = self.copy_targs(id);
        return self.emit_call_scattered(target, callee_op, start, n, ts, tn, ty, sp);
    }

    fn intrinsic_value(self: &mut Self, ik: u8, ty: TypeId, sp: tok::Span) ir::OperandId {
        let t = self.temp(ty, sp);
        let pl = self.place_of_local(t);
        self.assign(
            pl,
            ir::Rvalue {
                kind: ir::RV_INTRINSIC,
                a: self.body.oper_pool.len() as u32,
                b: 0,
                c: ik,
                target: ty,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        return self.copy_op(pl);
    }

    // An unresolved callee spelling a compiler intrinsic name (behind an optional specialization).
    fn is_intrinsic_callee(self: &Self, callee: NodeId, name: str) bool {
        let mut c = callee;
        if self.f.node(c).kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
            c = self.f.node(c).as_data.specialization.expression;
        }
        if self.f.node(c).kind != NodeKind::NODE_IDENTIFIER {
            return false;
        }
        if self.f.res(c).node != NODE_NONE {
            return false;
        }
        let s = self.f.node(c).as_data.name.text;
        return (s.end - s.start) as usize == name.len() && self.src.slice(s.start as usize, s.end as usize) == name;
    }

    // Argument operands can interleave with nested-call pool pushes; record them in a side run and
    // copy into a contiguous range at emission.
    fn push_arg_marker(self: &mut Self, op: ir::OperandId, n: &mut u32) {
        self.body.oper_pool.push(op);
        *n = *n + 1;
    }

    fn emit_call_scattered(
        self: &mut Self,
        callee: DefId,
        callee_op: ir::OperandId,
        start: u32,
        n: u32,
        targs_start: u32,
        targs_len: u32,
        ty: TypeId,
        sp: tok::Span,
    ) ir::OperandId {
        // Compact the (possibly interleaved) recorded args into a fresh contiguous range.
        let fresh = self.body.oper_pool.len() as u32;
        let total = fresh - start;
        let mut kept: u32 = 0;
        let mut i: u32 = 0;
        while i < total && kept < n {
            let v = self.body.oper_pool[(start + i) as usize];
            self.body.oper_pool.push(v);
            kept += 1;
            i += 1;
        }
        return self.emit_call(callee, callee_op, fresh, kept, targs_start, targs_len, ty, sp);
    }

    fn lower_assignment(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.binary;
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        let pl = self.lower_place(d.left);
        if pl == ir::IR_NONE {
            return ir::IR_NONE;
        }
        switch self.f.op_method(id) {
            Some(m) => {
                // compound assignment through an operator method: place = method(place, rhs)
                let lop = self.copy_op(pl);
                let start = self.body.oper_pool.len() as u32;
                self.body.oper_pool.push(lop);
                let rop = self.lower_expr(d.right);
                if rop == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                self.body.oper_pool.push(rop);
                let lt = self.body.places.at(pl as usize).ty;
                let res = self.emit_call_scattered(
                    DefId { module: (m >> 32) as ModuleId, node: (m & 0xFFFFFFFFu64) as NodeId },
                    ir::IR_NONE,
                    start,
                    2,
                    0,
                    0,
                    lt,
                    sp,
                );
                if res == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                let rv = self.rv_use(res, lt);
                self.assign(pl, rv, sp);
                return self.unit_op(ty, sp);
            },
            None => {},
        };
        let rop = self.lower_expr(d.right);
        if rop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let lt = self.body.places.at(pl as usize).ty;
        if d.op == tt::TokenType::Equal {
            let rv = self.rv_use(rop, lt);
            self.assign(pl, rv, sp);
        } else {
            let lop = self.copy_op(pl);
            let t = self.temp(lt, sp);
            let tp = self.place_of_local(t);
            self.assign(
                tp,
                ir::Rvalue {
                    kind: ir::RV_BINARY,
                    a: lop,
                    b: rop,
                    c: compound_base_op(d.op) as u8,
                    target: lt,
                    item: DefId { module: 0, node: NODE_NONE },
                },
                sp,
            );
            let cop = self.copy_op(tp);
            let rv = self.rv_use(cop, lt);
            self.assign(pl, rv, sp);
        }
        return self.unit_op(ty, sp);
    }

    fn lower_struct_init(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.struct_initializer;
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        let start = self.body.oper_pool.len() as u32;
        let mut n: u32 = 0;
        for i in 0..d.fields.len {
            let fi = unsafe self.f.list(d.fields)[i as usize];
            let v = self.f.node(fi).as_data.field_initializer.value;
            let op = self.lower_expr(v);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            self.push_arg_marker(op, &mut n);
        }
        return self.finish_aggregate(ir::AGG_STRUCT, self.f.res(id), start, n, ty, sp);
    }

    fn finish_aggregate(self: &mut Self, agg: u8, item: DefId, start: u32, n: u32, ty: TypeId, sp: tok::Span) ir::OperandId {
        let fresh = self.body.oper_pool.len() as u32;
        let total = fresh - start;
        let mut kept: u32 = 0;
        let mut i: u32 = 0;
        while i < total && kept < n {
            let v = self.body.oper_pool[(start + i) as usize];
            self.body.oper_pool.push(v);
            kept += 1;
            i += 1;
        }
        let t = self.temp(ty, sp);
        let pl = self.place_of_local(t);
        self.assign(pl, ir::Rvalue { kind: ir::RV_AGGREGATE, a: fresh, b: kept, c: agg, target: ty, item: item }, sp);
        return self.copy_op(pl);
    }

    fn lower_array_or_tuple(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.array_literal;
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        let k = self.f.node(id).kind;
        if k == NodeKind::NODE_ARRAY_LITERAL && d.repeat {
            let v = unsafe self.f.list(d.elements)[0];
            let c = unsafe self.f.list(d.elements)[1];
            let vop = self.lower_expr(v);
            if vop == ir::IR_NONE {
                return ir::IR_NONE;
            }
            let cop = self.lower_expr(c);
            if cop == ir::IR_NONE {
                return ir::IR_NONE;
            }
            let t = self.temp(ty, sp);
            let pl = self.place_of_local(t);
            self.assign(
                pl,
                ir::Rvalue {
                    kind: ir::RV_REPEAT,
                    a: vop,
                    b: cop,
                    c: 0,
                    target: ty,
                    item: DefId { module: 0, node: NODE_NONE },
                },
                sp,
            );
            return self.copy_op(pl);
        }
        let start = self.body.oper_pool.len() as u32;
        let mut n: u32 = 0;
        for i in 0..d.elements.len {
            let mut e = unsafe self.f.list(d.elements)[i as usize];
            if self.f.node(e).kind == NodeKind::NODE_FIELD_INITIALIZER {
                // designated array initializer `[idx] = value`: the designator is a constant, the
                // element operand is the value
                e = self.f.node(e).as_data.field_initializer.value;
            }
            let op = self.lower_expr(e);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            self.push_arg_marker(op, &mut n);
        }
        let agg: u8 = if k == NodeKind::NODE_TUPLE {
            ir::AGG_TUPLE;
        } else {
            ir::AGG_ARRAY;
        };
        return self.finish_aggregate(agg, DefId { module: 0, node: NODE_NONE }, start, n, ty, sp);
    }

    fn lower_range(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.pattern_range;
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        let start = self.body.oper_pool.len() as u32;
        let mut n: u32 = 0;
        if d.start != NODE_NONE {
            let op = self.lower_expr(d.start);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            self.push_arg_marker(op, &mut n);
        }
        if d.end != NODE_NONE {
            let op = self.lower_expr(d.end);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            self.push_arg_marker(op, &mut n);
        }
        return self.finish_aggregate(ir::AGG_STRUCT, DefId { module: 0, node: NODE_NONE }, start, n, ty, sp);
    }

    fn lower_if_expr(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.if_stmt;
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        let t = self.temp(ty, sp);
        let pl = self.place_of_local(t);
        let cop = self.lower_expr(d.condition);
        if cop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let then_b = self.open_block();
        let els_b = self.open_block();
        let join = self.open_block();
        self.branch_bool(cop, then_b, els_b, sp);
        self.lower_value_into(d.then_branch, pl);
        self.seal(self.goto_term(join, sp), els_b);
        if d.else_branch != NODE_NONE {
            self.lower_value_into(d.else_branch, pl);
        }
        self.seal(self.goto_term(join, sp), join);
        return self.copy_op(pl);
    }

    // Lower a branch that produces a value into `dest`: a block whose last expression statement is
    // the value, or a bare expression.
    fn lower_value_into(self: &mut Self, id: NodeId, dest: ir::PlaceId) {
        if id == NODE_NONE || self.err.len() != 0 {
            return;
        }
        if self.f.node(id).kind == NodeKind::NODE_BLOCK {
            self.lower_value_block(id, dest);
            return;
        }
        let op = self.lower_expr(id);
        if op == ir::IR_NONE {
            return;
        }
        let ty = self.body.places.at(dest as usize).ty;
        let rv = self.rv_use(op, ty);
        self.assign(dest, rv, self.f.node(id).span);
    }

    // A value block: statements run, and the LAST expression statement's value lands in `dest`.
    fn lower_value_block(self: &mut Self, id: NodeId, dest: ir::PlaceId) {
        self.scope_enter();
        let stmts = self.f.node(id).as_data.block.statements;
        let ty = self.body.places.at(dest as usize).ty;
        for i in 0..stmts.len {
            let s = unsafe self.f.list(stmts)[i as usize];
            if i == stmts.len - 1 && self.f.node(s).kind == NodeKind::NODE_EXPRESSION_STATEMENT {
                let v = self.f.node(s).as_data.single.value;
                let op = self.lower_expr(v);
                if op == ir::IR_NONE {
                    return;
                }
                let rv = self.rv_use(op, ty);
                self.assign(dest, rv, self.f.node(s).span);
            } else {
                self.lower_stmt(s);
            }
            if self.err.len() != 0 {
                return;
            }
        }
        self.scope_exit();
    }

    fn lower_loop_expr(self: &mut Self, id: NodeId, result: ir::PlaceId) {
        let d = self.f.node(id).as_data.while_stmt;
        let sp = self.f.node(id).span;
        let head = self.open_block();
        let exit = self.open_block();
        self.seal(self.goto_term(head, sp), head);
        self.loops.push(
            LoopCtx { label: d.label, brk: exit, cont: head, defer_depth: self.defers.len(), result: result },
        );
        self.lower_stmt(d.body);
        let _ = self.loops.pop();
        self.seal(self.goto_term(head, sp), exit);
    }

    fn lower_va(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.va_op;
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        let ik: u8 = if d.op == VA_START {
            ir::IN_VA_START;
        } else if d.op == VA_ARG {
            ir::IN_VA_ARG;
        } else {
            ir::IN_VA_END;
        };
        let start = self.body.oper_pool.len() as u32;
        let mut n: u32 = 0;
        if d.ap != NODE_NONE {
            let op = self.lower_expr(d.ap);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            self.push_arg_marker(op, &mut n);
        }
        if d.extra != NODE_NONE {
            let op = self.lower_expr(d.extra);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            self.push_arg_marker(op, &mut n);
        }
        let t = self.temp(ty, sp);
        let pl = self.place_of_local(t);
        self.assign(
            pl,
            ir::Rvalue {
                kind: ir::RV_INTRINSIC,
                a: start,
                b: n,
                c: ik,
                target: ty,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        return self.copy_op(pl);
    }

    fn lower_closure(self: &mut Self, id: NodeId) ir::OperandId {
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        let caps = self.f.captures(id);
        let start = self.body.oper_pool.len() as u32;
        let mut n: u32 = 0;
        for i in 0..caps.len {
            let c = unsafe self.f.list(caps)[i as usize];
            let l = self.local_of(self.cap_decl(c));
            if l == ir::IR_NONE {
                continue;
            }
            let pl = self.place_of_local(l);
            let op = self.copy_op(pl);
            self.push_arg_marker(op, &mut n);
        }
        self.closures.push(id);
        let fresh = self.body.oper_pool.len() as u32;
        let total = fresh - start;
        let mut kept: u32 = 0;
        let mut i2: u32 = 0;
        while i2 < total && kept < n {
            let v = self.body.oper_pool[(start + i2) as usize];
            self.body.oper_pool.push(v);
            kept += 1;
            i2 += 1;
        }
        let t = self.temp(ty, sp);
        let pl = self.place_of_local(t);
        self.assign(
            pl,
            ir::Rvalue {
                kind: ir::RV_CLOSURE,
                a: fresh,
                b: kept,
                c: 0,
                target: ty,
                item: DefId { module: self.module, node: id },
            },
            sp,
        );
        return self.copy_op(pl);
    }

    // A capture entry names the captured binding's decl (identifier node resolving to it).
    fn cap_decl(self: &mut Self, c: NodeId) NodeId {
        let d = self.f.res(c);
        if d.module == self.module {
            return d.node;
        }
        return NODE_NONE;
    }

    // The resolution of a path-shaped expression: the node's own, else the member name's, else the
    // last path part's, else the specialization payload's (the checker stamps whichever it had).
    fn path_res(self: &Self, id: NodeId) DefId {
        let d = self.f.res(id);
        if d.node != NODE_NONE {
            return d;
        }
        let k = self.f.node(id).kind;
        if k == NodeKind::NODE_MEMBER {
            let md = self.f.node(id).as_data.member;
            let d2 = self.f.res(md.member);
            if d2.node != NODE_NONE {
                return d2;
            }
            return self.path_res(md.object);
        }
        if k == NodeKind::NODE_TYPE_PATH {
            let parts = self.f.node(id).as_data.type_path.parts;
            if parts.len != 0 {
                return self.f.res(unsafe self.f.list(parts)[(parts.len - 1) as usize]);
            }
        }
        if k == NodeKind::NODE_GENERIC_SPECIALIZATION {
            return self.path_res(self.f.node(id).as_data.specialization.expression);
        }
        return d;
    }

    fn lower_path_value(self: &mut Self, id: NodeId) ir::OperandId {
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        let d = self.path_res(id);
        if d.node == NODE_NONE {
            self.fail_at("path-unresolved", id);
            return ir::IR_NONE;
        }
        return self.item_value(id, d, ty, sp);
    }

    // The enclosing enum of variant `vd` plus its ordinal among the members; -1 when absent.
    fn variant_ordinal(self: &Self, vd: DefId, out_enum: &mut NodeId) i64 {
        let a = unsafe &*(&*self.pkg).module_ast_const(vd.module);
        let items = a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let nid = unsafe a.list(items)[i as usize];
            if a.at_const(nid).kind != NodeKind::NODE_ENUM {
                continue;
            }
            let ms = a.at_const(nid).as_data.aggregate.members;
            for j in 0..ms.len {
                if unsafe a.list(ms)[j as usize] == vd.node {
                    *out_enum = nid;
                    return j;
                }
            }
        }
        *out_enum = NODE_NONE;
        return -1;
    }

    // An item in value position: functions become item constants, constants/statics become places.
    fn item_value(self: &mut Self, id: NodeId, d: DefId, ty: TypeId, sp: tok::Span) ir::OperandId {
        let dk = self.decl_kind(d);
        if dk == NodeKind::NODE_FUNCTION {
            let ts = self.body.targ_pool.len() as u32;
            let tn = self.copy_targs(id);
            return self.const_op(
                ir::Constant { kind: ir::CK_ITEM, ty: ty, val: 0, raw: sp, item: d, targ_start: ts, targ_len: tn },
            );
        }
        if dk == NodeKind::NODE_VARIANT {
            // unit variant construction
            let start = self.body.oper_pool.len() as u32;
            return self.finish_aggregate(ir::AGG_VARIANT, d, start, 0, ty, sp);
        }
        let l = self.item_local(d, ty, sp);
        let pl = self.place_of_local(l);
        return self.copy_op(pl);
    }

    fn decl_kind(self: &Self, d: DefId) NodeKind {
        if d.node == NODE_NONE {
            return NodeKind::NODE_NONE_KIND;
        }
        let a = unsafe (&*self.pkg).module_ast_const(d.module);
        return unsafe (&*a).at_const(d.node).kind;
    }

    // ---- places -----------------------------------------------------------------------------------

    fn lower_place(self: &mut Self, id: NodeId) ir::PlaceId {
        if id == NODE_NONE || self.err.len() != 0 {
            return ir::IR_NONE;
        }
        let k = self.f.node(id).kind;
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        if k == NodeKind::NODE_IDENTIFIER {
            let d = self.f.res(id);
            if d.module == self.module {
                let l = self.local_of(d.node);
                if l != ir::IR_NONE {
                    return self.place_of_local(l);
                }
            }
            if d.node == NODE_NONE {
                self.fail_at("ident-unresolved", id);
                return ir::IR_NONE;
            }
            let dk = self.decl_kind(d);
            if dk == NodeKind::NODE_FUNCTION || dk == NodeKind::NODE_VARIANT {
                let op = self.item_value(id, d, ty, sp);
                if op == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                return self.spill(op, sp);
            }
            let l2 = self.item_local(d, ty, sp);
            return self.place_of_local(l2);
        }
        if k == NodeKind::NODE_MEMBER {
            return self.lower_member_place(id);
        }
        if k == NodeKind::NODE_INDEX {
            return self.lower_index_place(id);
        }
        if k == NodeKind::NODE_UNARY && self.f.node(id).as_data.unary.op == tt::TokenType::Star {
            let base = self.lower_place_or_spill(self.f.node(id).as_data.unary.operand);
            if base == ir::IR_NONE {
                return ir::IR_NONE;
            }
            return self.place_project(base, ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: ty });
        }
        // Any other expression used as a place: evaluate and spill.
        let op = self.lower_expr(id);
        if op == ir::IR_NONE {
            return ir::IR_NONE;
        }
        return self.spill(op, sp);
    }

    fn lower_place_or_spill(self: &mut Self, id: NodeId) ir::PlaceId {
        return self.lower_place(id);
    }

    fn lower_member_place(self: &mut Self, id: NodeId) ir::PlaceId {
        let d = self.f.node(id).as_data.member;
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        if d.path {
            // Path member (Enum::Variant, Type::CONST): an item, not a projection.
            let op = self.lower_path_value(id);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            return self.spill(op, sp);
        }
        let mut base = self.lower_place_or_spill(d.object);
        if base == ir::IR_NONE {
            return ir::IR_NONE;
        }
        // Auto-deref chain recorded on the member: apply user/builtin derefs before the field.
        let du = self.f.derefs(id);
        if du != null {
            let steps = unsafe du.n;
            for s in 0..steps {
                let m = unsafe du.method[s as usize];
                let rt = unsafe du.recv[s as usize];
                if m.node != NODE_NONE {
                    let rop = self.copy_op(base);
                    let start = self.body.oper_pool.len() as u32;
                    self.body.oper_pool.push(rop);
                    let res = self.emit_call(m, ir::IR_NONE, start, 1, 0, 0, rt, sp);
                    if res == ir::IR_NONE {
                        return ir::IR_NONE;
                    }
                    base = self.spill(res, sp);
                } else {
                    base = self.place_project(base, ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: rt });
                }
            }
        } else {
            // implicit deref through references/pointers on field access
            let bty = self.body.places.at(base as usize).ty;
            let byk = self.f.ty(bty).kind;
            if byk == TypeKind::TYPE_REFERENCE || byk == TypeKind::TYPE_POINTER {
                let inner = self.f.ty(bty).as_data.elem;
                base = self.place_project(base, ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: inner });
            }
        }
        let fd = self.f.res(d.member);
        return self.place_project(base, ir::Projection { kind: ir::PJ_FIELD, data: ir::IR_NONE, sub: fd.node, ty: ty });
    }

    fn lower_index_place(self: &mut Self, id: NodeId) ir::PlaceId {
        let d = self.f.node(id).as_data.index;
        let ty = self.f.node_type(id);
        let sp = self.f.node(id).span;
        switch self.f.op_method(id) {
            Some(m) => {
                // Index conformance: place = *method(&obj, idx) -- the call yields the element ref.
                let res = self.lower_op_call(
                    id,
                    (m >> 32) as ModuleId,
                    (m & 0xFFFFFFFFu64) as NodeId,
                    d.object,
                    d.index,
                );
                if res == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                return self.spill(res, sp);
            },
            None => {},
        };
        let base = self.lower_place_or_spill(d.object);
        if base == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let iop = self.lower_expr(d.index);
        if iop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        return self.place_project(base, ir::Projection { kind: ir::PJ_INDEX_OP, data: iop, sub: 0, ty: ty });
    }

    // ---- match ------------------------------------------------------------------------------------

    // Naive arm-order fallback lowering (guarded matches; the decision tree covers the rest): test each
    // arm's pattern; on success bind + run guard + body; else fall to the next arm.
    fn lower_match(self: &mut Self, id: NodeId, dest: ir::PlaceId) bool {
        let d = self.f.node(id).as_data.match_expr;
        let sp = self.f.node(id).span;
        let vop = self.lower_expr(d.value);
        if vop == ir::IR_NONE {
            return false;
        }
        let vpl = self.spill(vop, sp);
        // Guard-free matches lower through the shared decision tree, so no place is
        // retested once its constructor is known. Guarded matches (and or-patterns that bind, or a
        // budget overflow) keep the sequential arm chain below -- guards run after their arm's
        // tests and before its body either way.
        let mut sequential = false;
        for i in 0..d.arms.len {
            let ad = self.f.node(unsafe self.f.list(d.arms)[i as usize]).as_data.match_arm;
            if ad.guard != NODE_NONE || self.or_pattern_binds(ad.pattern) {
                sequential = true;
            }
        }
        if !sequential {
            let mut cx = pat::PatCx::new(self.pkg, self.f.ast, self.src);
            for i in 0..d.arms.len {
                let ad = self.f.node(unsafe self.f.list(d.arms)[i as usize]).as_data.match_arm;
                cx.add_arm(ad.pattern, i);
            }
            let tree = cx.build_tree();
            if tree.ok {
                self.lower_match_tree(id, dest, vpl, &cx, &tree);
                return self.err.len() == 0;
            }
        }
        let join = self.open_block();
        for i in 0..d.arms.len {
            let arm = unsafe self.f.list(d.arms)[i as usize];
            let ad = self.f.node(arm).as_data.match_arm;
            let next_arm = self.open_block();
            self.lower_pattern_test(ad.pattern, vpl, next_arm);
            if self.err.len() != 0 {
                return false;
            }
            if ad.guard != NODE_NONE {
                let gop = self.lower_expr(ad.guard);
                if gop == ir::IR_NONE {
                    return false;
                }
                let ok_b = self.open_block();
                self.branch_bool(gop, ok_b, next_arm, sp);
            }
            if dest != ir::IR_NONE {
                self.lower_value_into(ad.body, dest);
            } else {
                self.lower_stmt(ad.body);
            }
            if self.err.len() != 0 {
                return false;
            }
            self.seal(self.goto_term(join, sp), next_arm);
        }
        // no arm matched: exhaustiveness says unreachable
        let u = self.term0(ir::TM_UNREACHABLE, sp);
        self.seal(u, join);
        return true;
    }

    // Emit `test` == false -> on_fail, continuing in a fresh success block.
    fn require(self: &mut Self, cond: ir::OperandId, on_fail: ir::BlockId, sp: tok::Span) {
        let ok_b = self.open_block();
        self.branch_bool(cond, ok_b, on_fail, sp);
    }

    // Compare place `v` against operand `rhs` for equality into a bool operand.
    fn eq_test(self: &mut Self, v: ir::PlaceId, rhs: ir::OperandId, sp: tok::Span) ir::OperandId {
        let vop = self.copy_op(v);
        let bt = Ast::builtin(BuiltinType::BT_BOOL);
        let t = self.temp(bt, sp);
        let tp = self.place_of_local(t);
        self.assign(
            tp,
            ir::Rvalue {
                kind: ir::RV_BINARY,
                a: vop,
                b: rhs,
                c: tt::TokenType::EqualEqual as u8,
                target: bt,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        return self.copy_op(tp);
    }

    // Discriminant-of-`v` == ordinal(variant) as a bool operand; also yields the payload place
    // (downcast projection) for sub-pattern tests.
    fn variant_test(self: &mut Self, v: ir::PlaceId, vd: DefId, sp: tok::Span, payload: &mut ir::PlaceId) ir::OperandId {
        let mut en = NODE_NONE;
        let ord = self.variant_ordinal(vd, &mut en);
        if ord < 0 {
            self.fail_at("variant-ordinal", vd.node);
            return ir::IR_NONE;
        }
        let vty = self.body.places.at(v as usize).ty;
        let ut = Ast::builtin(BuiltinType::BT_U32);
        let dt = self.temp(ut, sp);
        let dp = self.place_of_local(dt);
        self.assign(
            dp,
            ir::Rvalue {
                kind: ir::RV_DISCRIMINANT,
                a: v,
                b: 0,
                c: 0,
                target: ut,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        let ord_op = self.const_op(
            ir::Constant {
                kind: ir::CK_INT,
                ty: ut,
                val: ord,
                raw: sp,
                item: DefId { module: 0, node: NODE_NONE },
                targ_start: 0,
                targ_len: 0,
            },
        );
        let cond = self.eq_test(dp, ord_op, sp);
        *payload = self.place_project(
            v,
            ir::Projection { kind: ir::PJ_DOWNCAST, data: ord as u32, sub: vd.node, ty: vty },
        );
        return cond;
    }

    // Does pattern `p` (or a child) create a binding? Or-patterns with bindings are not lowered yet.
    fn pattern_binds(self: &Self, p: NodeId) bool {
        let k = self.f.node(p).kind;
        if k == NodeKind::NODE_PATTERN_NAME {
            let vd = self.f.res(self.f.node(p).as_data.pattern.name);
            let is_var = vd.node != NODE_NONE && self.decl_kind(vd) == NodeKind::NODE_VARIANT;
            if !is_var {
                return true;
            }
        }
        if k == NodeKind::NODE_PATTERN_NAME || k == NodeKind::NODE_PATTERN_TUPLE || k == NodeKind::NODE_PATTERN_STRUCT || k == NodeKind::NODE_PATTERN_OR || k == NodeKind::NODE_PATTERN_FIELD {
            let ch = self.f.node(p).as_data.pattern.children;
            for i in 0..ch.len {
                if self.pattern_binds(unsafe self.f.list(ch)[i as usize]) {
                    return true;
                }
            }
        }
        return false;
    }

    // Test pattern `p` against place `v`; on mismatch jump to `on_fail`; on success fall through
    // with bindings in scope. Mirrors the emitter's pattern semantics (variant tags, @-patterns,
    // tuple `_i` fields, struct fields, ranges, or-alternatives).
    fn lower_pattern_test(self: &mut Self, p: NodeId, v: ir::PlaceId, on_fail: ir::BlockId) {
        if self.err.len() != 0 || p == NODE_NONE {
            return;
        }
        let k = self.f.node(p).kind;
        let sp = self.f.node(p).span;
        if k == NodeKind::NODE_PATTERN_WILDCARD || k == NodeKind::NODE_IDENTIFIER {
            return;
        }
        if k == NodeKind::NODE_PATTERN_NAME {
            let pd = self.f.node(p).as_data.pattern;
            let vd = self.f.res(pd.name);
            if vd.node != NODE_NONE && self.decl_kind(vd) == NodeKind::NODE_VARIANT {
                let mut payload = ir::IR_NONE;
                let cond = self.variant_test(v, vd, sp, &mut payload);
                if cond == ir::IR_NONE {
                    return;
                }
                self.require(cond, on_fail, sp);
                return;
            }
            if pd.children.len != 0 {
                // `name @ subpattern`: test the subpattern, then bind the name.
                self.lower_pattern_test(unsafe self.f.list(pd.children)[0], v, on_fail);
            }
            self.bind_name(p, v, sp);
            return;
        }
        if k == NodeKind::NODE_PATTERN_LITERAL {
            let val = self.f.node(p).as_data.single.value;
            let lop = self.lower_expr(val);
            if lop == ir::IR_NONE {
                return;
            }
            let cond = self.eq_test(v, lop, sp);
            self.require(cond, on_fail, sp);
            return;
        }
        if k == NodeKind::NODE_PATTERN_RANGE {
            let rd = self.f.node(p).as_data.pattern_range;
            if rd.start != NODE_NONE {
                let lo = self.pattern_bound(rd.start);
                let lop = self.lower_expr(lo);
                if lop == ir::IR_NONE {
                    return;
                }
                let cond = self.cmp_test(v, lop, tt::TokenType::GreaterThanEqual, sp);
                self.require(cond, on_fail, sp);
            }
            if rd.end != NODE_NONE {
                let hi = self.pattern_bound(rd.end);
                let hop = self.lower_expr(hi);
                if hop == ir::IR_NONE {
                    return;
                }
                let rel: tt::TokenType = if rd.inclusive {
                    tt::TokenType::LessThanEqual;
                } else {
                    tt::TokenType::LessThan;
                };
                let cond = self.cmp_test(v, hop, rel, sp);
                self.require(cond, on_fail, sp);
            }
            return;
        }
        if k == NodeKind::NODE_PATTERN_TUPLE {
            let pd = self.f.node(p).as_data.pattern;
            let mut base = v;
            if pd.name != NODE_NONE {
                let vd = self.f.res(pd.name);
                if vd.node != NODE_NONE && self.decl_kind(vd) == NodeKind::NODE_VARIANT {
                    let mut payload = ir::IR_NONE;
                    let cond = self.variant_test(v, vd, sp, &mut payload);
                    if cond == ir::IR_NONE {
                        return;
                    }
                    self.require(cond, on_fail, sp);
                    base = payload;
                }
            }
            if pd.name == NODE_NONE || base != v {
                // element sub-patterns against payload/tuple fields _i
                for i in 0..pd.children.len {
                    let c = unsafe self.f.list(pd.children)[i as usize];
                    let cpl = self.tuple_field(base, i, c);
                    self.lower_pattern_test(c, cpl, on_fail);
                    if self.err.len() != 0 {
                        return;
                    }
                }
                return;
            }
            if pd.children.len == 1 {
                self.lower_pattern_test(unsafe self.f.list(pd.children)[0], v, on_fail);
            } else {
                for i in 0..pd.children.len {
                    let c = unsafe self.f.list(pd.children)[i as usize];
                    let cpl = self.tuple_field(v, i, c);
                    self.lower_pattern_test(c, cpl, on_fail);
                    if self.err.len() != 0 {
                        return;
                    }
                }
            }
            return;
        }
        if k == NodeKind::NODE_PATTERN_STRUCT {
            let pd = self.f.node(p).as_data.pattern;
            let mut base = v;
            if pd.name != NODE_NONE {
                let vd = self.f.res(pd.name);
                if vd.node != NODE_NONE && self.decl_kind(vd) == NodeKind::NODE_VARIANT {
                    let mut payload = ir::IR_NONE;
                    let cond = self.variant_test(v, vd, sp, &mut payload);
                    if cond == ir::IR_NONE {
                        return;
                    }
                    self.require(cond, on_fail, sp);
                    base = payload;
                }
            }
            for i in 0..pd.children.len {
                let fid = unsafe self.f.list(pd.children)[i as usize];
                let fpd = self.f.node(fid).as_data.pattern;
                if fpd.children.len == 0 {
                    continue;
                }
                let subp = unsafe self.f.list(fpd.children)[0];
                let fd = self.f.res(fpd.name);
                let fty = self.f.node_type(subp);
                let fpl = self.place_project(
                    base,
                    ir::Projection { kind: ir::PJ_FIELD, data: i, sub: fd.node, ty: fty },
                );
                self.lower_pattern_test(subp, fpl, on_fail);
                if self.err.len() != 0 {
                    return;
                }
            }
            return;
        }
        if k == NodeKind::NODE_PATTERN_OR {
            let pd = self.f.node(p).as_data.pattern;
            if self.pattern_binds(p) {
                self.fail_at("or-pattern-binding", p);
                return;
            }
            if pd.children.len == 0 {
                return;
            }
            let ok_b = self.open_block();
            for i in 0..pd.children.len {
                let c = unsafe self.f.list(pd.children)[i as usize];
                let last = i == pd.children.len - 1;
                let next_alt: ir::BlockId = if last {
                    on_fail;
                } else {
                    self.open_block();
                };
                self.lower_pattern_test(c, v, next_alt);
                if self.err.len() != 0 {
                    return;
                }
                // success falls into ok_b; the failing edge continues with the next alternative
                let cont: ir::BlockId = if last {
                    ok_b;
                } else {
                    next_alt;
                };
                self.seal(self.goto_term(ok_b, sp), cont);
            }
            return;
        }
        self.fail_at("pattern-kind", p);
    }

    // Does `p` contain an or-pattern that binds a name? (Those keep sequential lowering.)
    fn or_pattern_binds(self: &Self, p: NodeId) bool {
        if p == NODE_NONE {
            return false;
        }
        let k = self.f.node(p).kind;
        if k == NodeKind::NODE_PATTERN_OR {
            return self.pattern_binds(p);
        }
        if k == NodeKind::NODE_PATTERN_NAME || k == NodeKind::NODE_PATTERN_TUPLE || k == NodeKind::NODE_PATTERN_STRUCT || k == NodeKind::NODE_PATTERN_FIELD {
            let ch = self.f.node(p).as_data.pattern.children;
            for i in 0..ch.len {
                if self.or_pattern_binds(unsafe self.f.list(ch)[i as usize]) {
                    return true;
                }
            }
        }
        return false;
    }

    // Materialize the place a DtPath denotes (memoized per path id).
    fn place_of_path(self: &mut Self, t: &pat::DecisionTree, pid: u32, vpl: ir::PlaceId, cache: &mut Vector<u32>) ir::PlaceId {
        if cache[pid as usize] != ir::IR_NONE {
            return cache[pid as usize];
        }
        let path = *t.paths.at(pid as usize);
        let mut base = vpl;
        if path.parent != pat::P_NONE {
            base = self.place_of_path(t, path.parent, vpl, cache);
        }
        if path.parent != pat::P_NONE || path.downcast >= 0 || path.fdecl != NODE_NONE || path.pat != NODE_NONE {
            let mut ty = self.body.places.at(base as usize).ty;
            if path.pat != NODE_NONE {
                let pt = self.f.node_type(path.pat);
                if pt != TYPE_NONE {
                    ty = pt;
                }
            }
            if path.downcast >= 0 {
                let bty = self.body.places.at(base as usize).ty;
                base = self.place_project(
                    base,
                    ir::Projection { kind: ir::PJ_DOWNCAST, data: path.downcast as u32, sub: path.vdecl.node, ty: bty },
                );
            }
            base = self.place_project(
                base,
                ir::Projection { kind: ir::PJ_FIELD, data: path.field, sub: path.fdecl, ty: ty },
            );
        }
        cache.set(pid as usize, base);
        return base;
    }

    // Bind every name in `p` against `v` WITHOUT tests: the decision tree already proved the
    // constructors on this path, so variant payloads are reached by direct downcast projections.
    fn pattern_bind_total(self: &mut Self, p: NodeId, v: ir::PlaceId) {
        if p == NODE_NONE || self.err.len() != 0 {
            return;
        }
        let k = self.f.node(p).kind;
        let sp = self.f.node(p).span;
        if k == NodeKind::NODE_PATTERN_WILDCARD || k == NodeKind::NODE_PATTERN_LITERAL || k == NodeKind::NODE_PATTERN_RANGE {
            return;
        }
        if k == NodeKind::NODE_PATTERN_OR {
            return; // binding or-alternatives never reach the tree path
        }
        if k == NodeKind::NODE_IDENTIFIER {
            self.bind_name(p, v, sp);
            return;
        }
        if k == NodeKind::NODE_PATTERN_NAME {
            let pd = self.f.node(p).as_data.pattern;
            let vd = self.f.res(pd.name);
            if vd.node != NODE_NONE && self.decl_kind(vd) == NodeKind::NODE_VARIANT {
                return; // a bare variant test binds nothing
            }
            if pd.children.len != 0 {
                self.pattern_bind_total(unsafe self.f.list(pd.children)[0], v);
            }
            self.bind_name(p, v, sp);
            return;
        }
        if k == NodeKind::NODE_PATTERN_TUPLE || k == NodeKind::NODE_PATTERN_STRUCT {
            let pd = self.f.node(p).as_data.pattern;
            let mut base = v;
            let vd = if pd.name != NODE_NONE {
                self.f.res(pd.name);
            } else {
                DefId { module: 0, node: NODE_NONE };
            };
            let isv = vd.node != NODE_NONE && self.decl_kind(vd) == NodeKind::NODE_VARIANT;
            if isv {
                let mut en = NODE_NONE;
                let ord = self.variant_ordinal(vd, &mut en);
                if ord >= 0 {
                    let bty = self.body.places.at(v as usize).ty;
                    base = self.place_project(
                        v,
                        ir::Projection { kind: ir::PJ_DOWNCAST, data: ord as u32, sub: vd.node, ty: bty },
                    );
                }
            }
            if k == NodeKind::NODE_PATTERN_TUPLE && !isv && pd.children.len == 1 {
                self.pattern_bind_total(unsafe self.f.list(pd.children)[0], base);
                return;
            }
            for i in 0..pd.children.len {
                let cid = unsafe self.f.list(pd.children)[i as usize];
                if k == NodeKind::NODE_PATTERN_STRUCT {
                    let fpd = self.f.node(cid).as_data.pattern;
                    if fpd.children.len == 0 {
                        continue;
                    }
                    let subp = unsafe self.f.list(fpd.children)[0];
                    let fd = self.f.res(fpd.name);
                    let fty = self.f.node_type(subp);
                    let fpl = self.place_project(
                        base,
                        ir::Projection { kind: ir::PJ_FIELD, data: i, sub: fd.node, ty: fty },
                    );
                    self.pattern_bind_total(subp, fpl);
                } else {
                    let cpl = self.tuple_field(base, i, cid);
                    self.pattern_bind_total(cid, cpl);
                }
            }
        }
    }

    // Emit the decision tree: every DT_TEST reads its memoized place once; leaves jump to shared
    // per-arm blocks (bindings + body emitted exactly once per arm). `cont` is where the write
    // cursor must land when this subtree is fully sealed.
    fn emit_tree(
        self: &mut Self,
        t: &pat::DecisionTree,
        cx: &pat::PatCx,
        node: u32,
        vpl: ir::PlaceId,
        cache: &mut Vector<u32>,
        armb: &Vector<u32>,
        cont: ir::BlockId,
        sp: tok::Span,
    ) {
        if self.err.len() != 0 {
            return;
        }
        let n = *t.nodes.at(node as usize);
        if n.kind == pat::DT_LEAF {
            self.seal(self.goto_term(armb[n.arm as usize], sp), cont);
            return;
        }
        if n.kind == pat::DT_FAIL {
            self.seal(self.term0(ir::TM_UNREACHABLE, sp), cont);
            return;
        }
        let pl = self.place_of_path(t, n.place, vpl, cache);
        let k0 = cx.pats.at(t.edges.at(n.edge_start as usize).pat as usize).kind;
        if k0 == pat::PC_TUPLE || k0 == pat::PC_STRUCT {
            // single always-complete constructor: no runtime test
            let child = t.edges.at(n.edge_start as usize).child;
            self.emit_tree(t, cx, child, vpl, cache, armb, cont, sp);
            return;
        }
        if k0 == pat::PC_VARIANT || k0 == pat::PC_BOOL {
            // one switch over the discriminant / value; no place is read twice
            let mut sw_op = ir::IR_NONE;
            if k0 == pat::PC_VARIANT {
                let ut = Ast::builtin(BuiltinType::BT_U32);
                let dt = self.temp(ut, sp);
                let dp = self.place_of_local(dt);
                self.assign(
                    dp,
                    ir::Rvalue {
                        kind: ir::RV_DISCRIMINANT,
                        a: pl,
                        b: 0,
                        c: 0,
                        target: ut,
                        item: DefId { module: 0, node: NODE_NONE },
                    },
                    sp,
                );
                sw_op = self.copy_op(dp);
            } else {
                sw_op = self.copy_op(pl);
            }
            let mut blocks = Vector::<u32>::new();
            for e in 0..n.edge_len {
                blocks.push(self.open_block());
            }
            let dflt: ir::BlockId = if n.default_child != pat::P_NONE {
                self.open_block();
            } else {
                blocks[(n.edge_len - 1) as usize];
            };
            let mut tm = self.term0(ir::TM_SWITCH, sp);
            tm.a = sw_op;
            tm.sw_start = self.body.switch_pool.len() as u32;
            let pairs: u32 = if n.default_child != pat::P_NONE {
                n.edge_len;
            } else {
                n.edge_len - 1;
            };
            for e in 0..pairs {
                let ep = cx.pats.at(t.edges.at((n.edge_start + e) as usize).pat as usize);
                self.body.switch_pool.push(ep.val as u64 << 32 | blocks[e as usize] as u64);
            }
            tm.sw_len = pairs;
            tm.t0 = dflt;
            self.seal(tm, blocks[0]);
            for e in 0..n.edge_len {
                let next: ir::BlockId = if e + 1 <= n.edge_len - 1 {
                    blocks[(e + 1) as usize];
                } else if n.default_child != pat::P_NONE {
                    dflt;
                } else {
                    cont;
                };
                self.emit_tree(t, cx, t.edges.at((n.edge_start + e) as usize).child, vpl, cache, armb, next, sp);
            }
            if n.default_child != pat::P_NONE {
                self.emit_tree(t, cx, n.default_child, vpl, cache, armb, cont, sp);
            }
            return;
        }
        // integers / ranges / opaque literals: a comparison chain, one edge at a time
        for e in 0..n.edge_len {
            let eid = (n.edge_start + e) as usize;
            let ep = *cx.pats.at(t.edges.at(eid).pat as usize);
            let hit = self.open_block();
            let miss = self.open_block();
            let mut cond = ir::IR_NONE;
            if ep.kind == pat::PC_INT {
                let ity = self.body.places.at(pl as usize).ty;
                let cop = self.const_op(
                    ir::Constant {
                        kind: ir::CK_INT,
                        ty: ity,
                        val: ep.val,
                        raw: sp,
                        item: DefId { module: 0, node: NODE_NONE },
                    },
                );
                cond = self.eq_test(pl, cop, sp);
            } else if ep.kind == pat::PC_RANGE {
                let rd = self.f.node(ep.node).as_data.pattern_range;
                let mut ok = true;
                if rd.start != NODE_NONE {
                    let lo = self.pattern_bound(rd.start);
                    let lop = self.lower_expr(lo);
                    if lop == ir::IR_NONE {
                        return;
                    }
                    cond = self.cmp_test(pl, lop, tt::TokenType::GreaterThanEqual, sp);
                    ok = false;
                }
                if rd.end != NODE_NONE {
                    let hi = self.pattern_bound(rd.end);
                    let hop = self.lower_expr(hi);
                    if hop == ir::IR_NONE {
                        return;
                    }
                    let rel: tt::TokenType = if rd.inclusive {
                        tt::TokenType::LessThanEqual;
                    } else {
                        tt::TokenType::LessThan;
                    };
                    let c2 = self.cmp_test(pl, hop, rel, sp);
                    if cond == ir::IR_NONE {
                        cond = c2;
                    } else {
                        // both bounds: fold with a boolean and
                        let bt = Ast::builtin(BuiltinType::BT_BOOL);
                        let at = self.temp(bt, sp);
                        let ap = self.place_of_local(at);
                        self.assign(
                            ap,
                            ir::Rvalue {
                                kind: ir::RV_BINARY,
                                a: cond,
                                b: c2,
                                c: tt::TokenType::AmpersandAmpersand as u8,
                                target: bt,
                                item: DefId { module: 0, node: NODE_NONE },
                            },
                            sp,
                        );
                        cond = self.copy_op(ap);
                    }
                }
                if ok && cond == ir::IR_NONE {
                    let bt = Ast::builtin(BuiltinType::BT_BOOL);
                    cond = self.const_op(
                        ir::Constant {
                            kind: ir::CK_BOOL,
                            ty: bt,
                            val: 1,
                            raw: sp,
                            item: DefId { module: 0, node: NODE_NONE },
                        },
                    );
                }
            } else {
                // opaque literal: compare against the lowered pattern expression
                let val = if self.f.node(ep.node).kind == NodeKind::NODE_PATTERN_LITERAL {
                    self.f.node(ep.node).as_data.single.value;
                } else {
                    ep.node;
                };
                let lop = self.lower_expr(val);
                if lop == ir::IR_NONE {
                    return;
                }
                cond = self.eq_test(pl, lop, sp);
            }
            let mut tm = self.term0(ir::TM_SWITCH, sp);
            tm.a = cond;
            tm.sw_start = self.body.switch_pool.len() as u32;
            self.body.switch_pool.push(1u64 << 32 | hit as u64);
            tm.sw_len = 1;
            tm.t0 = miss;
            self.seal(tm, hit);
            self.emit_tree(t, cx, t.edges.at(eid).child, vpl, cache, armb, miss, sp);
        }
        if n.default_child != pat::P_NONE {
            self.emit_tree(t, cx, n.default_child, vpl, cache, armb, cont, sp);
        } else {
            self.seal(self.term0(ir::TM_UNREACHABLE, sp), cont);
        }
    }

    // Tree-driven match lowering: emit the tree, then each arm exactly once (bindings from the
    // original pattern, in source order, then the body), all joining after the match.
    fn lower_match_tree(
        self: &mut Self,
        id: NodeId,
        dest: ir::PlaceId,
        vpl: ir::PlaceId,
        cx: &pat::PatCx,
        t: &pat::DecisionTree,
    ) {
        let d = self.f.node(id).as_data.match_expr;
        let sp = self.f.node(id).span;
        let join = self.open_block();
        let mut armb = Vector::<u32>::new();
        for i in 0..d.arms.len {
            armb.push(self.open_block());
        }
        let mut cache = Vector::<u32>::new();
        for i in 0..t.paths.len() {
            cache.push(ir::IR_NONE);
        }
        let after = self.open_block();
        self.emit_tree(t, cx, t.root, vpl, &mut cache, &armb, after, sp);
        if self.err.len() != 0 {
            return;
        }
        self.seal_dead(after, sp);
        for i in 0..d.arms.len {
            self.cur = armb[i as usize];
            self.run_start = self.body.statements.len() as u32;
            let ad = self.f.node(unsafe self.f.list(d.arms)[i as usize]).as_data.match_arm;
            self.pattern_bind_total(ad.pattern, vpl);
            if dest != ir::IR_NONE {
                self.lower_value_into(ad.body, dest);
            } else {
                self.lower_stmt(ad.body);
            }
            if self.err.len() != 0 {
                return;
            }
            self.seal(self.goto_term(join, sp), join);
            if i != d.arms.len - 1 {
                // the next arm block writes next; seal moved the cursor to join already
                self.cur = join;
            }
        }
        self.cur = join;
        self.run_start = self.body.statements.len() as u32;
    }

    fn cmp_test(self: &mut Self, v: ir::PlaceId, rhs: ir::OperandId, rel: tt::TokenType, sp: tok::Span) ir::OperandId {
        let vop = self.copy_op(v);
        let bt = Ast::builtin(BuiltinType::BT_BOOL);
        let t = self.temp(bt, sp);
        let tp = self.place_of_local(t);
        self.assign(
            tp,
            ir::Rvalue {
                kind: ir::RV_BINARY,
                a: vop,
                b: rhs,
                c: rel as u8,
                target: bt,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        return self.copy_op(tp);
    }

    // A range-pattern bound is a PATTERN_LITERAL wrapper or a bare expression.
    fn pattern_bound(self: &Self, b: NodeId) NodeId {
        if self.f.node(b).kind == NodeKind::NODE_PATTERN_LITERAL {
            return self.f.node(b).as_data.single.value;
        }
        return b;
    }

    fn tuple_field(self: &mut Self, base: ir::PlaceId, i: u32, c: NodeId) ir::PlaceId {
        let cty = self.f.node_type(c);
        return self.place_project(base, ir::Projection { kind: ir::PJ_FIELD, data: i, sub: NODE_NONE, ty: cty });
    }

    fn bind_name(self: &mut Self, p: NodeId, v: ir::PlaceId, sp: tok::Span) {
        let ty = self.body.places.at(v as usize).ty;
        let l = self.body.add_local(
            ir::LocalDecl {
                ty: ty,
                storage: ir::LS_USER,
                is_mutable: true,
                span: sp,
                decl: p,
                item: DefId { module: 0, node: NODE_NONE },
            },
        );
        self.bind(p, l);
        let pl = self.place_of_local(l);
        let op = self.copy_op(v);
        let rv = self.rv_use(op, ty);
        self.assign(pl, rv, sp);
    }

    // Bind an irrefutable pattern against `v` (let destructuring); refutable shapes route through
    // lower_pattern_test with an unreachable fail block.
    fn pattern_bind(self: &mut Self, p: NodeId, v: ir::PlaceId, on_fail: ir::BlockId) {
        let k = self.f.node(p).kind;
        let sp = self.f.node(p).span;
        if k == NodeKind::NODE_PATTERN_WILDCARD {
            return;
        }
        if k == NodeKind::NODE_PATTERN_NAME || k == NodeKind::NODE_IDENTIFIER {
            let pd = self.f.node(p).as_data.pattern;
            if k == NodeKind::NODE_PATTERN_NAME && pd.children.len != 0 {
                self.pattern_bind(unsafe self.f.list(pd.children)[0], v, on_fail);
            }
            self.bind_name(p, v, sp);
            return;
        }
        if k == NodeKind::NODE_PATTERN_TUPLE {
            let pd = self.f.node(p).as_data.pattern;
            for i in 0..pd.children.len {
                let c = unsafe self.f.list(pd.children)[i as usize];
                let cpl = self.tuple_field(v, i, c);
                self.pattern_bind(c, cpl, on_fail);
                if self.err.len() != 0 {
                    return;
                }
            }
            return;
        }
        if k == NodeKind::NODE_PATTERN_STRUCT || k == NodeKind::NODE_PATTERN_LITERAL {
            // A refutable pattern in let position (`let Some(x) = ..` under a prior guarantee):
            // route through the tester against a dead fail block.
            let dead = self.open_block();
            self.lower_pattern_test(p, v, dead);
            self.seal_dead(dead, sp);
            return;
        }
        self.fail_at("let-pattern", p);
    }
}

// The base arithmetic op a compound assignment applies (PlusEqual -> Plus, ...).
const fn compound_base_op(op: tt::TokenType) u32 {
    if op == tt::TokenType::PlusEqual {
        return tt::TokenType::Plus as u32;
    }
    if op == tt::TokenType::MinusEqual {
        return tt::TokenType::Minus as u32;
    }
    if op == tt::TokenType::StarEqual {
        return tt::TokenType::Star as u32;
    }
    if op == tt::TokenType::SlashEqual {
        return tt::TokenType::Slash as u32;
    }
    if op == tt::TokenType::PercentEqual {
        return tt::TokenType::Percent as u32;
    }
    if op == tt::TokenType::AmpersandEqual {
        return tt::TokenType::Ampersand as u32;
    }
    return op as u32;
}

// Decimal fast path for integer literal spellings; 0 for hex/underscored/suffixed forms (the span
// keeps the exact spelling for CTFE).
fn parse_dec(src: str, sp: tok::Span) i64 {
    let mut v: i64 = 0;
    let mut i = sp.start as usize;
    while i < sp.end as usize {
        let b = src[i];
        if b < b'0' || b > b'9' {
            return 0;
        }
        if v > 922337203685477580 {
            return 0;
        }
        v = v * 10 + (b - b'0') as i64;
        i += 1;
    }
    return v;
}
