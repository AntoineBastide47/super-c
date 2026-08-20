// Production flow diagnostics from the Core IR loan/move analysis. `bc_fn` calls `bc_ir_collect`
// before the AST walk: on success the walk runs silent (`bc_quiet`) for the flow-owned categories
// and these records land in its place, worded exactly as the walk words them. A body that fails to
// lower falls back to the noisy walk, so no function ever goes unchecked.
import stdlib;
import utils::errors as diag;
import lexer::token as tok;
import ast::ast as *;
import module::loader as loader;
import typechecker::typechecker as tc;
import ir::core as ir;
import ir::lower as irl;
import borrowck::move_paths as bmp;
import borrowck::facts as bfx;
import borrowck::dataflow as bdf;
import borrowck::loans as bln;

pub struct FlowErr {
    pub start: u32,
    pub len: u32,
    pub cat: u8, // dedup category; 10 also selects the borrow-conflict note
    pub msg: String,
}

// Nesting stacks for the walk-tape replay (one per strictly-nested event family). Pooled in
// BorrowCtx; pre/acc/ovf are depth-indexed SLOTS (never popped) so FlowState is copied row-wise
// by save/clear instead of whole-struct by push.
pub struct RepSt {
    pub bms: Vector<u32>,
    pub les: Vector<i32>,
    pub mbm: Vector<u32>,
    pub pre: Vector<tc::FlowState>,
    pub acc: Vector<tc::FlowState>,
    pub ovf: Vector<u8>,
    pub seg: Vector<u64>, // start<<32 | nmoved0<<16 | nborrows0
    pub fdepth: usize,
}

extend RepSt {
    pub fn new() RepSt {
        return RepSt {
            bms: Vector::<u32>::new(),
            les: Vector::<i32>::new(),
            mbm: Vector::<u32>::new(),
            pre: Vector::<tc::FlowState>::new(),
            acc: Vector::<tc::FlowState>::new(),
            ovf: Vector::<u8>::new(),
            seg: Vector::<u64>::new(),
            fdepth: 0,
        };
    }

    pub fn reset(self: &mut Self) {
        self.bms.truncate(0);
        self.les.truncate(0);
        self.mbm.truncate(0);
        self.seg.truncate(0);
        self.fdepth = 0;
    }
}

// Reusable owner of the per-body borrow pipeline: one instance is built once per analyze pass and
// reset-and-refilled for every body, so vector capacity is kept instead of reallocated 1873+ times.
pub struct BorrowCtx {
    pub forest: bmp::MoveForest,
    pub facts: bfx::BodyFacts,
    pub cfg: bdf::Cfg,
    pub liveness: bdf::Liveness,
    pub moves: bdf::MoveFlow,
    pub solver: bln::Solver,
    pub cap_spans: Vector<u32>,
    pub rep: RepSt,
    pub escaping: Vector<u32>,
    /// Spent Lowerers recycled across bodies: lower_fn/lower_closure_body re-seed on entry, so a
    /// pooled entry only donates its heap capacity. Same-module only (BorrowCtx is per-module).
    pub lower_pool: Vector<irl::Lowerer>,
}

extend BorrowCtx {
    pub fn new() BorrowCtx {
        return BorrowCtx {
            forest: bmp::MoveForest::empty(),
            facts: bfx::BodyFacts::empty(),
            cfg: bdf::Cfg::empty(),
            liveness: bdf::Liveness::empty(),
            moves: bdf::MoveFlow::empty(),
            solver: bln::Solver::empty(),
            cap_spans: Vector::<u32>::new(),
            rep: RepSt::new(),
            escaping: Vector::<u32>::new(),
            lower_pool: Vector::<irl::Lowerer>::new(),
        };
    }
}

// A Lowerer for `owner`: recycled from the pool when one is spent, else freshly built.
fn bc_lw_take(ctx: &mut BorrowCtx, pkg: *const loader::Package, m: ModuleId, owner: NodeId) irl::Lowerer {
    switch ctx.lower_pool.pop() {
        Some(lw) => {
            return lw;
        },
        _ => {},
    };
    return irl::Lowerer::new(pkg, m, owner);
}

/// Run the six analysis stages for `body` into `ctx` (reset-and-refill keeps vector capacity
/// across bodies). Returns true when any move or borrow error was recorded -- the wording pass
/// (or the module's serial replay) then has something to say. Pure over the frozen `body`, the
/// package's read-only ASTs, and the two private accumulators, so workers may run it concurrently.
pub fn bc_run_stages(ow: &mut bfx::Owner, ctx: &mut BorrowCtx, body: &ir::CoreBody) bool {
    // Conservative pre-classification, each check over-approximating a fact-generation trigger.
    // `slim` (no carrier-typed local -- field-transitive -- and no ref/addr/slice/dyn/closure/asm)
    // proves no loan, origin, universal, or access can exist: fact generation records only the
    // move/init events. `boring` additionally proves no owned local (no move or free event) and
    // no split-init declaration (no uninit): every stage is a no-op and all of them skip.
    let m = body.module;
    let mut carrier = false;
    let mut owned = false;
    for l in 0..body.locals.len() {
        let ty = body.locals.at(l).ty;
        if !carrier && ow.carries(m, ty) {
            carrier = true;
        }
        if !owned && ow.owns(m, ty) {
            owned = true;
        }
        if carrier && owned {
            break;
        }
    }
    // The syntax sweeps only matter when the locals scan left slim possible.
    let mut synt = carrier;
    if !synt {
        for r in 0..body.rvalues.len() {
            let k = body.rvalues.at(r).kind;
            if k == ir::RV_REF || k == ir::RV_ADDR || k == ir::RV_SLICE || k == ir::RV_DYN || k == ir::RV_CLOSURE {
                synt = true;
                break;
            }
        }
    }
    if !synt {
        for s in 0..body.statements.len() {
            if body.statements.at(s).kind == ir::ST_ASM {
                synt = true;
                break;
            }
        }
    }
    let slim = !carrier && !synt;
    if slim && !owned && !body.has_uninit_decl {
        ctx.moves.errs.truncate(0);
        ctx.solver.errs.truncate(0);
        return false;
    }
    ctx.forest.build_into(body);
    bfx::generate_into(ow, body, &ctx.forest, &mut ctx.facts);
    // Boundary liveness only feeds the loan solver's origin-liveness stage, which runs for
    // loan-bearing bodies and for declared return-lifetime placeholders (the solver's
    // zero-loan gate, mirrored); leave the stale rows unread otherwise.
    let mut lv_need = ctx.facts.loans.len() != 0;
    if !lv_need && ctx.facts.nuniversal > 1 {
        for r in 0..ctx.facts.ret_origin.len() {
            if !ctx.facts.ret_elided[r] {
                lv_need = true;
            }
        }
    }
    // No move events and every local initializes at its declaration (which dominates its uses):
    // no move, double-move, partial, or uninit error can exist -- skip the move/init dataflow.
    let mv_need = body.has_uninit_decl || ctx.facts.nmoves != 0;
    // The CFG feeds only those two and the solver's placeholder flood; a body needing none of
    // them never walks it (the solver's early return only stores the stale pointer).
    if lv_need || mv_need {
        ctx.cfg.build_into(body);
    }
    if lv_need {
        ctx.cfg.build_preds(); // liveness is the only predecessor consumer
        ctx.liveness.build_into(&ctx.facts, &ctx.cfg);
    }
    if mv_need {
        ctx.moves.build_into(body, &ctx.forest, &ctx.facts, &ctx.cfg);
    } else {
        ctx.moves.errs.truncate(0);
    }
    ctx.solver.build_into(body, &ctx.facts, &ctx.cfg, &ctx.liveness);
    return ctx.moves.errs.len() != 0 || ctx.solver.errs.len() != 0;
}

// Walk-parity wording. The categories keep loop replays and defer duplication deduplicated.
const CAT_UNINIT: u8 = 0;
const CAT_MOVED: u8 = 1;
const CAT_FREED: u8 = 2;
const CAT_PARTIAL: u8 = 3;
const CAT_CAP_MOVED: u8 = 4;
const CAT_C_READ: u8 = 5;
const CAT_C_ASSIGN: u8 = 6;
const CAT_C_MOVE: u8 = 7;
const CAT_C_FREE: u8 = 8;
const CAT_C_CAP: u8 = 9;
const CAT_C_ISSUE: u8 = 10;
const CAT_DANGLE: u8 = 11;
const CAT_ESCAPE: u8 = 12;
const CAT_F_DEREF: u8 = 13; // Free value moved out of a dereference
const CAT_F_REF: u8 = 14; // Free field moved out of borrowed content
const CAT_F_WHOLE: u8 = 15; // Free field moved out of a Free aggregate
const CAT_F_CAP: u8 = 16; // Free capture moved out of its closure
const CAT_F_CONST: u8 = 17; // owning const moved

extend tc::TypeChecker {
    /// The active flow-walk mode: true = Core IR analysis owns flow diagnostics. `bc_mode` forces a
    /// side (differential tests); otherwise `SC_BORROW_WALK=old` reverts to the AST walk.
    pub fn bc_flow_new(self: &mut Self) bool {
        if self.bc_mode == 0 {
            let v = stdlib::getenv("SC_BORROW_WALK");
            self.bc_mode = 2;
            if v != null && diag::cstr(v) == "old" {
                self.bc_mode = 1;
            }
        }
        return self.bc_mode == 2;
    }

    /// Lower `fnid` and its closures BEFORE the walk (whose capture analysis the facts read).
    /// False = a body did not lower; the caller runs the noisy walk instead. Lowerers come from
    /// `ctx.lower_pool` when available (entry re-seeds them), so steady state allocates nothing.
    pub fn bc_ir_lower(self: &mut Self, fnid: NodeId, ctx: &mut BorrowCtx, bodies: &mut Vector<irl::Lowerer>) bool {
        let pkg = self.package as *const loader::Package;
        let m = self.cur_module();
        let mut lw = bc_lw_take(ctx, pkg, m, fnid);
        if !lw.lower_fn(fnid) {
            ctx.lower_pool.push(lw);
            return false;
        }
        let mut cns = Vector::<NodeId>::new();
        let mut pars = Vector::<NodeId>::new();
        for c in 0..lw.closures.len() {
            cns.push(lw.closures[c]);
            pars.push(NODE_NONE);
        }
        bodies.push(lw);
        let mut ok = true;
        let mut i: usize = 0;
        while i < cns.len() {
            let cn = cns[i];
            let mut cl = bc_lw_take(ctx, pkg, m, cn);
            if cl.lower_closure_body(cn) {
                for c2 in 0..cl.closures.len() {
                    cns.push(cl.closures[c2]);
                    pars.push(cn);
                }
                bodies.push(cl);
            } else {
                ctx.lower_pool.push(cl);
                ok = false;
            }
            i += 1;
        }
        // The walk's tc_mark_capture_mut, from the recorded peels: a binding mutated in a closure
        // body sets the mut_caps bit in EVERY enclosing closure that captures it (parent chain).
        for b in 0..bodies.len() {
            let bw = bodies.at(b);
            for k in 0..bw.mut_binds.len() {
                let d = bw.mut_binds[k];
                let mut c = bw.body.owner.node;
                loop {
                    let idx = self.tc_capture_index(c, d);
                    if idx >= 0 {
                        let old = self.cur_ast().at(c).as_data.closure.mut_caps as u64;
                        self.cur_ast().at(c).as_data.closure.mut_caps = (old | 1u64 << idx as u64) as u32;
                    }
                    let mut p = NODE_NONE;
                    for j in 0..cns.len() {
                        if cns[j] == c {
                            p = pars[j];
                            break;
                        }
                    }
                    if p == NODE_NONE {
                        break;
                    }
                    c = p;
                }
            }
        }
        return ok;
    }

    /// Analyze the pre-lowered bodies AFTER the walk ran (mut-capture bits are now final).
    pub fn bc_ir_analyze(
        self: &mut Self,
        ow: &mut bfx::Owner,
        bodies: &Vector<irl::Lowerer>,
        ctx: &mut BorrowCtx,
        out: &mut Vector<FlowErr>,
    ) {
        let mut seen = Vector::<u64>::new();
        for b in 0..bodies.len() {
            self.bc_ir_body(ow, &bodies.at(b).body, ctx, &mut seen, out);
        }
    }

    /// The walk's Free-move safety rules, ported over Core IR moves (the walk stays silent for
    /// them under `bc_quiet`). Only USER-consumption moves (CoreBody.user_moves, set by the
    /// lowerer at let/return/argument/aggregate/assign positions) are checked, so pattern binds
    /// and spill plumbing never fire. Unsafe regions come from the walk's recorded spans; a
    /// `.free()` receiver is exempt like the walk's bc_free_recv.
    fn bc_ir_free_rules(
        self: &mut Self,
        ow: &mut bfx::Owner,
        body: &ir::CoreBody,
        seen: &mut Vector<u64>,
        out: &mut Vector<FlowErr>,
    ) {
        // Every rule moves a Free value INTO some local (a binding or a temp), so a body with no
        // owned-typed local cannot fire any of them -- skip the sweep.
        let mut owned = false;
        for l in 0..body.locals.len() {
            if ow.owns(body.module, body.locals.at(l).ty) {
                owned = true;
                break;
            }
        }
        if !owned {
            return;
        }
        // In a closure body, argument locals after the declared parameters are the captures; a
        // whole-binding user move of a Free one is the walk's capture-move error.
        let mut cap_lo: u32 = 0xFFFFFFFFu32;
        let mut cap_hi: u32 = 0;
        let onode = body.owner.node;
        if onode != NODE_NONE {
            let oa = self.mod_ast(body.owner.module);
            if oa.at_const(onode).kind == NodeKind::NODE_CLOSURE {
                cap_lo = body.returns + oa.at_const(onode).as_data.closure.params.len;
                cap_hi = body.returns + body.args;
            }
        }
        for bi in 0..body.blocks.len() {
            let blk = *body.blocks.at(bi);
            for si in 0..blk.stmt_len {
                let s = *body.statements.at((blk.stmt_start + si) as usize);
                if s.kind != ir::ST_ASSIGN {
                    continue;
                }
                let rv = *body.rvalues.at(s.rvalue as usize);
                let k = rv.kind;
                if k == ir::RV_USE || k == ir::RV_UNARY || k == ir::RV_CAST || k == ir::RV_REPEAT || k == ir::RV_DYN {
                    self.bc_free_rule_op(body, cap_lo, cap_hi, rv.a, s.span, false, seen, out);
                } else if k == ir::RV_BINARY {
                    self.bc_free_rule_op(body, cap_lo, cap_hi, rv.a, s.span, false, seen, out);
                    self.bc_free_rule_op(body, cap_lo, cap_hi, rv.b, s.span, false, seen, out);
                } else if k == ir::RV_AGGREGATE || k == ir::RV_CLOSURE {
                    for i in 0..rv.b {
                        let oi = body.oper_pool[(rv.a + i) as usize];
                        if oi != ir::IR_NONE {
                            self.bc_free_rule_op(body, cap_lo, cap_hi, oi, s.span, false, seen, out);
                        }
                    }
                }
            }
            let t = blk.term;
            if t.kind == ir::TM_CALL {
                let mut exempt = false;
                if t.args_len == 1 && t.callee.node != NODE_NONE {
                    let fa = self.mod_ast(t.callee.module);
                    let fd = fa.at_const(t.callee.node);
                    if fd.kind == NodeKind::NODE_FUNCTION {
                        let nm = fa.at_const(fd.as_data.function.name).as_data.name.text;
                        exempt = tc::span_is(self.mod_src(t.callee.module), nm, "free");
                    }
                }
                for i in 0..t.args_len {
                    let oi = body.oper_pool[(t.args_start + i) as usize];
                    if oi != ir::IR_NONE {
                        self.bc_free_rule_op(body, cap_lo, cap_hi, oi, t.span, exempt, seen, out);
                    }
                }
            } else if t.kind == ir::TM_SWITCH || t.kind == ir::TM_ASSERT {
                if t.a != ir::IR_NONE {
                    self.bc_free_rule_op(body, cap_lo, cap_hi, t.a, t.span, false, seen, out);
                }
            }
        }
    }

    fn bc_free_rule_op(
        self: &mut Self,
        body: &ir::CoreBody,
        cap_lo: u32,
        cap_hi: u32,
        oi: u32,
        sp: tok::Span,
        exempt: bool,
        seen: &mut Vector<u64>,
        out: &mut Vector<FlowErr>,
    ) {
        if oi == ir::IR_NONE || oi as usize >= body.operands.len() {
            return;
        }
        let op = *body.operands.at(oi as usize);
        if op.kind != ir::OP_MOVE && op.kind != ir::OP_COPY {
            return;
        }
        let uw = (oi / 64) as usize;
        if uw >= body.user_moves.len() || (body.user_moves[uw] >> (oi & 63) as u64 & 1u64) == 0 {
            return; // plumbing move (pattern bind, spill), not a user consumption
        }
        let pl = *body.places.at(op.data as usize);
        if pl.proj_len == 0 {
            // Whole-binding move: the capture and owning-const rules apply.
            let bl = *body.locals.at(pl.base as usize);
            if bl.storage == ir::LS_STATIC_REF && bl.item.node != NODE_NONE {
                let ca = self.mod_ast(bl.item.module);
                if ca.at_const(bl.item.node).kind == NodeKind::NODE_CONST {
                    let cd = ca.at_const(bl.item.node).as_data.const_def;
                    if !cd.is_static_mut && !cd.is_extern && self.tc_type_is_free(pl.ty) {
                        self.bc_ir_push(
                            out,
                            seen,
                            CAT_F_CONST,
                            sp,
                            format("cannot move a value out of a 'const' binding"),
                        );
                    }
                }
                return;
            }
            // A RUNTIME local const (plain-fn initializer) is a scope-owned value: a copy of it
            // would double-free at scope exit.
            if bl.decl != NODE_NONE && self.mod_ast(body.module).at_const(bl.decl).kind == NodeKind::NODE_CONST && self.tc_type_is_free(
                pl.ty,
            ) {
                self.bc_ir_push(out, seen, CAT_F_CONST, sp, format("cannot move a value out of a 'const' binding"));
                return;
            }
            if pl.base >= cap_lo && pl.base < cap_hi && self.tc_type_is_free(pl.ty) {
                self.bc_ir_push(
                    out,
                    seen,
                    CAT_F_CAP,
                    sp,
                    format("cannot move a captured value out of a closure (the closure's env owns it)"),
                );
            }
            return;
        }
        // The walk's own predicate (memoized), so generic bodies answer exactly as the walk does.
        if !self.tc_type_is_free(pl.ty) {
            return;
        }
        // The statement span CONTAINS any unsafe-expression span inside it, so licensing is by
        // intersection, not by start-containment.
        let mut in_unsafe = false;
        for u in 0..self.bc_unsafe_spans.len() {
            let r = self.bc_unsafe_spans[u];
            if r >> 32 < sp.end as u64 && sp.start as u64 < (r & 0xFFFFFFFFu64) {
                in_unsafe = true;
            }
        }
        let base_ty = body.locals.at(pl.base as usize).ty;
        let bk = if base_ty != TYPE_NONE {
            self.type_at(base_ty).kind;
        } else {
            TypeKind::TYPE_ERROR;
        };
        // The whole pointee moved out of a dereference (`*r`, `p[i]`): the input type of the final
        // projection is the reference/pointer itself.
        let last = *body.projections.at((pl.proj_start + pl.proj_len - 1) as usize);
        let mut last_in = base_ty;
        if pl.proj_len > 1 {
            last_in = body.projections.at((pl.proj_start + pl.proj_len - 2) as usize).ty;
        }
        let lik = if last_in != TYPE_NONE {
            self.type_at(last_in).kind;
        } else {
            TypeKind::TYPE_ERROR;
        };
        let deref_of_ind = lik == TypeKind::TYPE_REFERENCE || lik == TypeKind::TYPE_POINTER;
        if deref_of_ind && (last.kind == ir::PJ_DEREF || last.kind == ir::PJ_INDEX_CONST || last.kind == ir::PJ_INDEX_OP) {
            if !in_unsafe && !exempt {
                self.bc_ir_push(
                    out,
                    seen,
                    CAT_F_DEREF,
                    sp,
                    format("cannot move a Free value out of a dereference (it would be freed twice)"),
                );
            }
            return;
        }
        if bk == TypeKind::TYPE_POINTER {
            return; // raw pointers are the unsafe world's escape hatch
        }
        // Pointer-typed fields are HANDLES (raw pointers are borrows by rule): copying one out of
        // borrowed or owned content escapes no ownership.
        let mk = self.type_at(pl.ty).kind;
        if mk == TypeKind::TYPE_POINTER || mk == TypeKind::TYPE_REFERENCE {
            return;
        }
        let mut has_deref = false;
        for i in 0..pl.proj_len {
            if body.projections.at((pl.proj_start + i) as usize).kind == ir::PJ_DEREF {
                has_deref = true;
            }
        }
        if bk == TypeKind::TYPE_REFERENCE && has_deref {
            if !in_unsafe && !exempt {
                self.bc_ir_push(
                    out,
                    seen,
                    CAT_F_REF,
                    sp,
                    format(
                        "cannot move a field out of a reference; use 'replace' to swap ownership out (or an 'unsafe' block to take responsibility)",
                    ),
                );
            }
            return;
        }
        if !has_deref && !exempt && base_ty != TYPE_NONE && self.tc_type_is_free(base_ty) {
            self.bc_ir_push(
                out,
                seen,
                CAT_F_WHOLE,
                sp,
                format(
                    "cannot move a field out of a value implementing Free; move the whole value or swap in a replacement first",
                ),
            );
        }
    }

    fn bc_ir_push(
        self: &mut Self,
        out: &mut Vector<FlowErr>,
        seen: &mut Vector<u64>,
        cat: u8,
        sp: tok::Span,
        msg: String,
    ) {
        let key = cat as u64 << 32 | sp.start as u64;
        for k in 0..seen.len() {
            if seen[k] == key {
                return;
            }
        }
        seen.push(key);
        // `emit_ordered` places each record by span start; append order only breaks ties.
        out.push(FlowErr { start: sp.start, len: sp.end - sp.start, cat: cat, msg: msg });
    }

    fn bc_ir_body(
        self: &mut Self,
        ow: &mut bfx::Owner,
        body: &ir::CoreBody,
        ctx: &mut BorrowCtx,
        seen: &mut Vector<u64>,
        out: &mut Vector<FlowErr>,
    ) {
        let _ = bc_run_stages(ow, ctx, body);
        self.bc_ir_free_rules(ow, body, seen, out);
        // Capture sites: a move-of-moved AT a closure creation is worded as a capture. Only the
        // move-error wording below reads them, so scan the body only when an error exists at all.
        ctx.cap_spans.truncate(0);
        if ctx.moves.errs.len() != 0 {
            for bi in 0..body.blocks.len() {
                let blk = *body.blocks.at(bi);
                for si in 0..blk.stmt_len {
                    let s = *body.statements.at((blk.stmt_start + si) as usize);
                    if s.kind == ir::ST_ASSIGN && body.rvalues.at(s.rvalue as usize).kind == ir::RV_CLOSURE {
                        ctx.cap_spans.push(s.span.start);
                    }
                }
            }
        }
        for e in 0..ctx.moves.errs.len() {
            let er = *ctx.moves.errs.at(e);
            if er.kind == bdf::ME_UNINIT {
                self.bc_ir_push(out, seen, CAT_UNINIT, er.span, format("use of possibly uninitialized value"));
            } else if er.kind == bdf::ME_PARTIAL {
                self.bc_ir_push(out, seen, CAT_PARTIAL, er.span, format("use of partially moved value"));
            } else {
                // A freed ANCESTOR taints the whole subtree (`a.free(); a.t` is a use after free).
                let mut freed = false;
                let mut fp = er.path;
                while fp != bmp::MP_NONE {
                    for f in 0..ctx.facts.freed.len() {
                        if ctx.facts.freed[f] == fp {
                            freed = true;
                        }
                    }
                    fp = ctx.forest.paths.at(fp as usize).parent;
                }
                let mut cap = false;
                for c in 0..ctx.cap_spans.len() {
                    if ctx.cap_spans[c] == er.span.start {
                        cap = true;
                    }
                }
                if freed {
                    self.bc_ir_push(out, seen, CAT_FREED, er.span, format("use after free"));
                } else if cap {
                    self.bc_ir_push(
                        out,
                        seen,
                        CAT_CAP_MOVED,
                        er.span,
                        format("closure captures a moved value (use of moved value)"),
                    );
                } else {
                    self.bc_ir_push(out, seen, CAT_MOVED, er.span, format("use of moved value"));
                }
            }
        }
        // An escaping loan's storage-death conflict is the same defect seen from the other end;
        // the return-site report subsumes it.
        ctx.escaping.truncate(0);
        for e in 0..ctx.solver.errs.len() {
            if ctx.solver.errs.at(e).kind == bln::BE_ESCAPE {
                ctx.escaping.push(ctx.solver.errs.at(e).loan);
            }
        }
        for e in 0..ctx.solver.errs.len() {
            let er = *ctx.solver.errs.at(e);
            if er.kind == bln::BE_CONFLICT {
                if er.acc == bln::ACC_DEAD {
                    let mut esc = false;
                    for k in 0..ctx.escaping.len() {
                        if ctx.escaping[k] == er.loan {
                            esc = true;
                        }
                    }
                    if esc {
                        continue;
                    }
                }
                self.bc_ir_conflict(body, &ctx.facts, &er, seen, out);
            } else if er.kind == bln::BE_ESCAPE {
                self.bc_ir_escape(body, &ctx.facts, &mut ctx.solver, &er, seen, out);
            }
            // BE_PLACEHOLDER stays with the walk's signature-level lifetime checks.
        }
    }

    fn bc_ir_conflict(
        self: &mut Self,
        body: &ir::CoreBody,
        f: &bfx::BodyFacts,
        er: &bln::BorrowErr,
        seen: &mut Vector<u64>,
        out: &mut Vector<FlowErr>,
    ) {
        if er.acc == bln::ACC_DEAD {
            self.bc_ir_push(
                out,
                seen,
                CAT_DANGLE,
                er.span,
                format(
                    "borrowed value does not live long enough: it is destroyed at the end of this block while a reference to it is still stored",
                ),
            );
            return;
        }
        // An access that itself issues (or activates) a loan at this point is the second borrow of
        // a value.
        let mut issue = bfx::BF_NONE;
        for li in 0..f.loans.len() {
            let lo = f.loans.at(li);
            if lo.issued_at == er.point + 1 && lo.span.start == er.span.start && li as u32 != er.loan {
                issue = li as u32;
            }
            if er.acc == bfx::ACC_ACT && lo.activated_at == er.point && lo.span.start == er.span.start && li as u32 != er.loan {
                issue = li as u32;
            }
        }
        // A WRITE access at a call's entry is the receiver/argument autoref claiming `&mut`.
        let mut autoref_mut = false;
        if issue == bfx::BF_NONE && er.acc == bfx::ACC_WRITE {
            for bi in 0..body.blocks.len() {
                let blk = *body.blocks.at(bi);
                if f.block_base[bi] + blk.stmt_len * 2 == er.point && blk.term.kind == ir::TM_CALL {
                    autoref_mut = true;
                }
            }
        }
        if issue != bfx::BF_NONE || autoref_mut {
            let mut nk = bfx::LK_MUT;
            if issue != bfx::BF_NONE {
                nk = f.loans.at(issue as usize).kind;
            }
            if nk == bfx::LK_CAP {
                self.bc_ir_push(out, seen, CAT_C_CAP, er.span, format("cannot capture this value while it is borrowed"));
                return;
            }
            let mut k1 = "mutable";
            if nk == bfx::LK_SHARED {
                k1 = "immutable";
            }
            let mut k2 = "mutable";
            if f.loans.at(er.loan as usize).kind == bfx::LK_SHARED {
                k2 = "immutable";
            }
            self.bc_ir_push(
                out,
                seen,
                CAT_C_ISSUE,
                er.span,
                format("cannot borrow this value as {} while it is already borrowed as {}", k1, k2),
            );
            return;
        }
        if er.acc == bfx::ACC_READ {
            self.bc_ir_push(
                out,
                seen,
                CAT_C_READ,
                er.span,
                format("cannot use this value while it is mutably borrowed"),
            );
        } else if er.acc == bfx::ACC_MOVE {
            self.bc_ir_push(out, seen, CAT_C_MOVE, er.span, format("cannot move this value while it is borrowed"));
        } else if er.acc == bfx::ACC_FREE {
            self.bc_ir_push(
                out,
                seen,
                CAT_C_FREE,
                er.span,
                format("cannot free a borrowed value: its owning binding frees it again at scope exit"),
            );
        } else if er.acc == bfx::ACC_CAP {
            self.bc_ir_push(out, seen, CAT_C_CAP, er.span, format("cannot capture this value while it is borrowed"));
        } else {
            self.bc_ir_push(
                out,
                seen,
                CAT_C_ASSIGN,
                er.span,
                format("cannot assign to this value while it is borrowed"),
            );
        }
    }

    // A local-storage borrow that reaches a RETURN placeholder is only an error the walk reports
    // when the returned value itself carries it; stores through `&mut` parameters belong to the
    // walk's declared-lifetime store checks.
    fn bc_ir_escape(
        self: &mut Self,
        body: &ir::CoreBody,
        f: &bfx::BodyFacts,
        sv: &mut bln::Solver,
        er: &bln::BorrowErr,
        seen: &mut Vector<u64>,
        out: &mut Vector<FlowErr>,
    ) {
        let lo = f.loans.at(er.loan as usize);
        let mut ret: u32 = bfx::BF_NONE;
        for r in 0..body.returns {
            if r as usize < f.local_origin.len() && f.local_origin[r as usize] != bfx::BF_NONE && sv.origin_reaches(
                lo.origin,
                f.local_origin[r as usize],
            ) {
                ret = r;
            }
        }
        if ret == bfx::BF_NONE {
            return;
        }
        let rty = body.locals.at(ret as usize).ty;
        let mut is_ref = false;
        if rty != TYPE_NONE {
            let k = self.type_at(rty).kind;
            is_ref = k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_POINTER;
        }
        if is_ref && !lo.pin {
            // A direct `&local` (or `&param`) reaching the return.
            let base = body.places.at(lo.place as usize).base;
            let mut what = "local variable";
            if body.locals.at(base as usize).storage == ir::LS_ARG {
                what = "function parameter";
            }
            self.bc_ir_push(
                out,
                seen,
                CAT_ESCAPE,
                er.span,
                format("returning a pointer/reference to a {}, which does not outlive the call", what),
            );
        } else {
            // A call-result pin (or a carried value): the walk words this by the returned TYPE.
            let mut what = "a value borrowing";
            if is_ref {
                what = "a reference borrowed";
            }
            self.bc_ir_push(
                out,
                seen,
                CAT_ESCAPE,
                er.span,
                format("returning {} from a local, which does not outlive the call", what),
            );
        }
    }

    /// Insert the collected records into the diagnostic stream at their source positions (the walk's
    /// own out-of-order region diags use the same watermark protocol).
    pub fn bc_ir_emit(self: &mut Self, res: &mut Vector<FlowErr>) {
        for i in 0..res.len() {
            let start = res.at(i).start;
            let len = res.at(i).len;
            let cat = res.at(i).cat;
            let msg = replace(&mut res[i].msg, String::new());
            let di = self.errors.emit_ordered(self.err_wm, start, len, msg);
            if cat == CAT_F_CONST {
                self.errors.note_at(
                    di,
                    format(
                        "a constant of an owning type is read or borrowed, never moved: the copy would free storage the constant still owns",
                    ),
                );
            }
            if cat == CAT_C_ISSUE {
                self.errors.note_at(
                    di,
                    format(
                        "a value may have many '&' borrows or a single '&mut', not both; the earlier borrow must end first",
                    ),
                );
            }
        }
    }
}
