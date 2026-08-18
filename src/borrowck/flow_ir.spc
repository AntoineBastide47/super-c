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
    pub escaping: Vector<u32>,
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
            escaping: Vector::<u32>::new(),
        };
    }
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
    /// False = a body did not lower; the caller runs the noisy walk instead.
    pub fn bc_ir_lower(self: &mut Self, fnid: NodeId, bodies: &mut Vector<irl::Lowerer>) bool {
        let pkg = self.package as *const loader::Package;
        let m = self.cur_module();
        let mut lw = irl::Lowerer::new(pkg, m, fnid);
        if !lw.lower_fn(fnid) {
            return false;
        }
        let mut cns = Vector::<NodeId>::new();
        for c in 0..lw.closures.len() {
            cns.push(lw.closures[c]);
        }
        bodies.push(lw);
        let mut ok = true;
        let mut i: usize = 0;
        while i < cns.len() {
            let cn = cns[i];
            let mut cl = irl::Lowerer::new(pkg, m, cn);
            if cl.lower_closure_body(cn) {
                for c2 in 0..cl.closures.len() {
                    cns.push(cl.closures[c2]);
                }
                bodies.push(cl);
            } else {
                ok = false;
            }
            i += 1;
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
        // Reset-and-refill each stage into the reusable context (keeps vector capacity across bodies).
        ctx.forest.build_into(body);
        bfx::generate_into(ow, body, &ctx.forest, &mut ctx.facts);
        ctx.cfg.build_into(body);
        ctx.liveness.build_into(&ctx.facts, &ctx.cfg);
        ctx.moves.build_into(body, &ctx.forest, &ctx.facts, &ctx.cfg);
        ctx.solver.build_into(body, &ctx.facts, &ctx.cfg, &ctx.liveness);
        // Capture sites: a move-of-moved AT a closure creation is worded as a capture.
        ctx.cap_spans.truncate(0);
        for bi in 0..body.blocks.len() {
            let blk = *body.blocks.at(bi);
            for si in 0..blk.stmt_len {
                let s = *body.statements.at((blk.stmt_start + si) as usize);
                if s.kind == ir::ST_ASSIGN && body.rvalues.at(s.rvalue as usize).kind == ir::RV_CLOSURE {
                    ctx.cap_spans.push(s.span.start);
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
