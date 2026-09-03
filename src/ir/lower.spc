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
import stdlib;
import ir::core as ir;
import ir::layout as lay;
import ir::interp as iri;
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
    pub locals_depth: usize, // scope locals deeper than this end their storage before leaving
    pub result: ir::PlaceId, // `break value` destination for loop expressions; IR_NONE when none
}

/// One instance-env binding for substitution-aware lowering: generic param decl `(pm, pnode)`
/// resolves to pool type `(am, at)` (a copy of the backend demand chain, innermost last).
pub struct LSub {
    pub pm: ModuleId,
    pub pnode: NodeId,
    pub am: ModuleId,
    pub at: TypeId,
}

// One active reflection-binder copy: `inline for f in fields/variants/payloads(..)` re-lowers its
// body once per copy with this frame on the stack; member reads on `f` resolve through it.
struct ProjFrame {
    pub binder: NodeId,
    pub idx: i64,
    pub vidx: i64, // payloads mode: the OUTER variants binder's current variant
    pub mode: u8, // 0 fields / 1 variants / 2 payloads
    pub sub0: ir::PlaceId,
    pub sub1: ir::PlaceId,
    pub owner_st: TypeId, // the concrete owner, reinterned into THIS module's pool
}

/// The prelude view decls the safe-access gates compare against, resolved lazily once per
/// Lowerer (`ok` = resolved). Package-constant, so a kept Lowerer's cache stays valid.
struct ViewDecls {
    pub ok: bool,
    pub v_str: DefId,
    pub v_slice: DefId,
    pub v_slice_mut: DefId,
    pub v_vector: DefId,
    pub v_string: DefId,
    pub v_array: DefId,
}

const fn vd_none() DefId {
    return DefId { module: 0, node: NODE_NONE };
}

const fn vd_is(d: DefId, decl: NodeId, m: ModuleId) bool {
    return d.node != NODE_NONE && d.node == decl && d.module == m;
}

pub struct Lowerer {
    pub f: facts::TypedFacts,
    pub pkg: *const loader::Package,
    pub module: ModuleId,
    pub src: str<'static>,
    pub body: ir::CoreBody,
    pub err: str<'static>, // first unsupported-construct reason ("" = ok)
    pub err_node: NodeId, // the node that failed (diagnostic snippet in the SC_CORE_IR report)
    /// The instance env for substitution-aware lowering (reflection expansion needs the CONCRETE
    /// owner); empty for the shared generic pre-pass.
    pub env: Vector<LSub>,
    proj_frames: Vector<ProjFrame>,
    binds: Vector<Binding>,
    loops: Vector<LoopCtx>,
    defers: Vector<NodeId>, // active defer statement nodes, innermost last
    scope_defers: Vector<usize>, // per open scope: defers length at entry
    scope_locals: Vector<ir::LocalId>, // user locals per scope, in declaration order
    scope_local_marks: Vector<usize>, // per open scope: scope_locals length at entry
    item_locals: Vector<Binding>, // cached LS_STATIC_REF locals per referenced item decl node
    pub closures: Vector<NodeId>, // closure nodes queued for their own lowering
    pub mut_binds: Vector<NodeId>, // decls mutated in this CLOSURE body (walk's mut_caps peel)
    pub unsafe_spans: Vector<u64>, // start<<32|end per unsafe expr; licenses the IR free-move rules
    pub tape: Vector<u64>, // borrowck replay events (ir::TP_*), in walk order; muted inside desugars
    tape_mute: u32,
    in_defer: u32, // lowering a defer body (an exit path): cancellation checks are masked there
    // The one call node this STATEMENT may put a cancellation check after: the root call of an
    // expression statement or a plain `let`. Mid-expression checks would unwind past pending
    // sibling temporaries the ladder cannot see.
    chk_root: NodeId,
    // scope_locals length the ladder deads down from: excludes a plain-let's own local, which is
    // registered before its initializer and is still UNINITIALIZED on the check's cancel edge (a
    // dead there is a drop-use that poisons loan liveness across loop back edges).
    chk_base: usize,
    // Per-body cache of the check-eligibility test (cancel pass ran, sugar items present, owner on
    // a coroutine stack, not the runtime module): 0 uncomputed, 1 off, 2 on.
    chk_on: u8,
    // Combined-safepoint ladder sharing: sibling loops with the same live scope state jump to one
    // ladder block instead of each emitting their own defers-then-deads sequence.
    sp_ladder_b: u32, // 0xFFFFFFFF = none cached
    sp_ladder_locals: Vector<ir::LocalId>,
    sp_ladder_defers: Vector<NodeId>,
    // Reusable u32 buffers (argument lists, match work lists): call/aggregate lowering builds one
    // per expression, so the pool keeps their capacity across the whole body and package.
    u32_pool: Vector<Vector<u32>>,
    views: ViewDecls,
    cur: ir::BlockId,
    run_start: u32, // statements index where the open block's run began
    ret_locals: u32, // first return-slot local
}

/// Package-lifetime store of finished lowerings, keyed `skey_mix(0, module << 32 | owner)`:
/// borrowck adopts every body it lowers so the instance graph starts from these instead of
/// lowering the package a second time. Entries move out on first demand and never return.
pub struct Keep {
    pub ix: Map<u64, u64>,
    pub kept: Vector<Lowerer>,
}

extend Keep {
    pub fn new() Keep {
        return Keep { ix: Map::<u64, u64>::new(), kept: Vector::<Lowerer>::new() };
    }

    /// Move every body of `other` in (first key wins, matching `put`); `other` is left empty.
    /// Slot order in `kept` is not load-bearing -- consumers index through `ix` by owner key.
    pub fn absorb(self: &mut Self, other: &mut Keep) {
        for i in 0..other.kept.len() {
            let d = other.kept.at(i).body.owner;
            let key = skey_mix(0, d.module as u64 << 32 | d.node as u64);
            if self.ix.contains_key(&key) {
                continue;
            }
            let pkg0 = other.kept.at(i).pkg;
            let moved = replace(other.kept.index_mut(i), Lowerer::new(pkg0, d.module, d.node));
            self.ix.insert(key, self.kept.len() as u64);
            self.kept.push(moved);
        }
    }

    pub fn put(self: &mut Self, src: &Lowerer) {
        let d = src.body.owner;
        let key = skey_mix(0, d.module as u64 << 32 | d.node as u64);
        if self.ix.contains_key(&key) {
            return;
        }
        let mut klw = Lowerer::new(src.pkg, d.module, d.node);
        klw.adopt(src);
        self.ix.insert(key, self.kept.len() as u64);
        self.kept.push(klw);
    }
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
            env: Vector::<LSub>::new(),
            proj_frames: Vector::<ProjFrame>::new(),
            binds: Vector::<Binding>::new(),
            loops: Vector::<LoopCtx>::new(),
            defers: Vector::<NodeId>::new(),
            scope_defers: Vector::<usize>::new(),
            scope_locals: Vector::<ir::LocalId>::new(),
            scope_local_marks: Vector::<usize>::new(),
            item_locals: Vector::<Binding>::new(),
            closures: Vector::<NodeId>::new(),
            mut_binds: Vector::<NodeId>::new(),
            unsafe_spans: Vector::<u64>::new(),
            tape: Vector::<u64>::new(),
            tape_mute: 0,
            in_defer: 0,
            chk_root: NODE_NONE,
            chk_base: 0,
            chk_on: 0,
            sp_ladder_b: 0xFFFFFFFFu32,
            sp_ladder_locals: Vector::<ir::LocalId>::new(),
            sp_ladder_defers: Vector::<NodeId>::new(),
            u32_pool: Vector::<Vector<u32>>::new(),
            views: ViewDecls {
                ok: false,
                v_str: vd_none(),
                v_slice: vd_none(),
                v_slice_mut: vd_none(),
                v_vector: vd_none(),
                v_string: vd_none(),
                v_array: vd_none(),
            },
            cur: 0,
            run_start: 0,
            ret_locals: 0,
        };
    }

    fn avget(self: &mut Self) Vector<u32> {
        let v9 = switch self.u32_pool.pop() {
            Some(v) => v,
            None => Vector::<u32>::new(),
        };
        return v9;
    }

    fn avput(self: &mut Self, v: Vector<u32>) {
        let mut v9 = v;
        v9.truncate(0);
        self.u32_pool.push(v9);
    }

    /// Re-target a reused Lowerer at another module, keeping every pool's heap capacity: the
    /// instance graph lowers the whole package through one scratch Lowerer. Clears any staged
    /// instance `env` (scratch lowerings are always env-free).
    pub fn retarget(self: &mut Self, module: ModuleId) {
        let p = unsafe &*self.pkg;
        self.f = facts::TypedFacts::of(p.module_ast_const(module));
        self.module = module;
        let sp = p.modules.at(module as usize).source.as_str();
        self.src = str::from_raw(sp.ptr(), sp.len());
        self.env.truncate(0);
    }

    /// Take an exact-size copy of `src`'s finished product (body + queued closure ids): the graph
    /// keeps compact bodies while lowering through one shared scratch Lowerer.
    pub fn adopt(self: &mut Self, src: &Lowerer) {
        self.body = ir::CoreBody::compact_from(&src.body);
        self.closures.truncate(0);
        self.closures.reserve(src.closures.len());
        for i in 0..src.closures.len() {
            self.closures.push(src.closures[i]);
        }
    }

    // Reset every per-body pool and cursor so one Lowerer lowers many bodies back to back, keeping
    // heap capacity. Module context (f/pkg/src) and a caller-staged instance `env` survive. A fresh
    // Lowerer passes through as a no-op, so single-use callers are unchanged.
    fn begin_body(self: &mut Self, owner: NodeId) {
        self.body.clear(DefId { module: self.module, node: owner }, self.module);
        self.err = "";
        self.err_node = NODE_NONE;
        self.proj_frames.truncate(0);
        self.binds.truncate(0);
        self.loops.truncate(0);
        self.defers.truncate(0);
        self.scope_defers.truncate(0);
        self.scope_locals.truncate(0);
        self.scope_local_marks.truncate(0);
        self.item_locals.truncate(0);
        self.closures.truncate(0);
        self.mut_binds.truncate(0);
        self.unsafe_spans.truncate(0);
        self.tape.truncate(0);
        self.tape_mute = 0;
        self.in_defer = 0;
        self.chk_root = NODE_NONE;
        self.chk_base = 0;
        self.chk_on = 0;
        self.sp_ladder_b = 0xFFFFFFFFu32;
        self.sp_ladder_locals.truncate(0);
        self.sp_ladder_defers.truncate(0);
        self.cur = 0;
        self.run_start = 0;
        self.ret_locals = 0;
    }

    // The walk's capture-mutation peel (tc_mark_capture_mut): member/index and move/unsafe wrappers
    // peel to an identifier, a deref stops it. Recorded per CLOSURE body so the flow pass can set
    // mut_caps bits on every enclosing closure that captures the binding.
    fn note_mut_bind(self: &mut Self, expr0: NodeId) {
        let ow = self.body.owner.node;
        if ow == NODE_NONE || self.f.node(ow).kind != NodeKind::NODE_CLOSURE {
            return;
        }
        let mut expr = expr0;
        loop {
            let n = self.f.node(expr);
            if n.kind == NodeKind::NODE_UNARY && (n.as_data.unary.op == tt::TokenType::Move || n.as_data.unary.op == tt::TokenType::Unsafe) {
                expr = n.as_data.unary.operand;
            } else if n.kind == NodeKind::NODE_MEMBER && !n.as_data.member.path {
                expr = n.as_data.member.object;
            } else if n.kind == NodeKind::NODE_INDEX {
                expr = n.as_data.index.object;
            } else {
                break;
            }
        }
        if self.f.node(expr).kind != NodeKind::NODE_IDENTIFIER {
            return;
        }
        let d = self.f.res(expr);
        if d.module == self.module && d.node != NODE_NONE {
            self.mut_binds.push(d.node);
        }
    }

    @c.always_inline
    fn tp(self: &mut Self, k: u8, aux: u32, node: NodeId) {
        if self.tape_mute == 0 {
            self.tape.push(k as u64 << 56 | aux as u64 << 32 | node as u64);
        }
    }

    /// Move the events recorded at `[from..len)` to position `at`, sliding `[at..from)` right.
    /// Lets a construct whose CFG order differs from walk order (a do-while tail condition) record
    /// its events in place and land them where the replay expects them. No-op when nothing landed.
    fn tape_splice(self: &mut Self, at: usize, from: usize) {
        let n = self.tape.len();
        if from <= at || from >= n {
            return;
        }
        let mut seg = Vector::<u64>::new();
        seg.reserve(n - from);
        for i in from..n {
            seg.push(self.tape[i]);
        }
        let mut w = n;
        let mut r = from;
        while r > at {
            r -= 1;
            w -= 1;
            self.tape.set(w, self.tape[r]);
        }
        for i in 0..seg.len() {
            self.tape.set(at + i, seg[i]);
        }
    }

    fn note_unsafe(self: &mut Self, id: NodeId) {
        let sp = self.f.node(id).span;
        self.unsafe_spans.push(sp.start as u64 << 32 | sp.end as u64);
    }

    // Mark `op` as a USER consumption (see CoreBody.user_moves) when it reads a place: the borrow
    // checker's free-move rules fire only on these, never on pattern/spill plumbing reads. Whether
    // the read MOVES is the type's business (Gen derives it from ownership), so both operand kinds
    // qualify here.
    @c.always_inline
    fn mark_user_move(self: &mut Self, op: ir::OperandId) {
        if op == ir::IR_NONE {
            return;
        }
        let k = self.body.operands.at(op as usize).kind;
        if k != ir::OP_MOVE && k != ir::OP_COPY {
            return;
        }
        let w = (op / 64) as usize;
        while self.body.user_moves.len() <= w {
            self.body.user_moves.push(0u64);
        }
        self.body.user_moves.set(w, self.body.user_moves[w] | 1u64 << (op & 63) as u64);
    }

    const fn fail(self: &mut Self, why: str<'static>) {
        if self.err.len() == 0 {
            self.err = why;
        }
    }

    const fn fail_at(self: &mut Self, why: str<'static>, node: NodeId) {
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
    const fn seal(self: &mut Self, t: ir::Terminator, next: ir::BlockId) {
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
    const fn seal_dead(self: &mut Self, b: ir::BlockId, sp: tok::Span) {
        if !self.body.blocks[b as usize].sealed {
            self.body.blocks[b as usize].stmt_start = self.body.statements.len() as u32;
            self.body.blocks[b as usize].stmt_len = 0;
            self.body.blocks[b as usize].term = self.term0(ir::TM_UNREACHABLE, sp);
            self.body.blocks[b as usize].sealed = true;
        }
    }

    const fn goto_term(self: &Self, to: ir::BlockId, sp: tok::Span) ir::Terminator {
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

    const fn rv_use(self: &Self, op: ir::OperandId, ty: TypeId) ir::Rvalue {
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
        self.scope_local_marks.push(self.scope_locals.len());
    }

    // Run this scope's defers (LIFO), end its locals' storage, and drop both; called at the
    // block's natural end.
    fn scope_exit(self: &mut Self) {
        let base = self.scope_defers[self.scope_defers.len() - 1];
        let _ = self.scope_defers.pop();
        self.emit_defers_down_to(base);
        while self.defers.len() > base {
            let _ = self.defers.pop();
        }
        let lbase = self.scope_local_marks[self.scope_local_marks.len() - 1];
        let _ = self.scope_local_marks.pop();
        self.emit_deads_down_to(lbase);
        while self.scope_locals.len() > lbase {
            let _ = self.scope_locals.pop();
        }
    }

    // A user local enters scope: storage marker plus registration for the matching dead marker.
    fn user_local_live(self: &mut Self, l: ir::LocalId, sp: tok::Span) {
        self.stmt(
            ir::Statement { kind: ir::ST_STORAGE_LIVE, place: ir::IR_NONE, rvalue: ir::IR_NONE, a: l, b: 0, span: sp },
        );
        self.scope_locals.push(l);
    }

    // Emit dead markers (innermost first) down to `base` WITHOUT popping (early exits leave the
    // scope stack intact, exactly like the defer machinery above).
    fn emit_deads_down_to(self: &mut Self, base: usize) {
        let mut i = self.scope_locals.len();
        while i > base {
            i -= 1;
            let l = self.scope_locals[i];
            let sp = self.body.locals.at(l as usize).span;
            self.stmt(
                ir::Statement {
                    kind: ir::ST_STORAGE_DEAD,
                    place: ir::IR_NONE,
                    rvalue: ir::IR_NONE,
                    a: l,
                    b: 0,
                    span: sp,
                },
            );
        }
    }

    // Emit defer bodies (innermost first) down to `base` WITHOUT popping (early exits leave the
    // scope stack intact for the code that follows the branch point). Events flow at EVERY exit:
    // the replay re-marks the defer's moves/borrows per exit, exactly as the walk's scope-close
    // re-walk did, each body bracketed by a borrow mark.
    fn emit_defers_down_to(self: &mut Self, base: usize) {
        let mut i = self.defers.len();
        while i > base {
            i -= 1;
            let d = self.defers[i];
            self.tp(ir::TP_MARK_PUSH, 0, d);
            // A defer body is cleanup: cancellation checks are masked inside it (a synthetic return
            // from within a defer would abandon the rest of the exit path).
            self.in_defer += 1;
            self.lower_stmt(self.f.node(d).as_data.single.value);
            self.in_defer -= 1;
            self.tp(ir::TP_MARK_POP, 0, d);
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
        // keyed by the FULL DefId: node ids collide across modules
        for i in 0..self.item_locals.len() {
            let li = self.item_locals[i].local as usize;
            if self.item_locals[i].decl == d.node && self.body.locals.at(li).item.module == d.module {
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
        self.begin_body(fnode);
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
                    ty: self.nty(pn),
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
        // Argument storage ends at every function exit, after all scope locals (registration
        // precedes the body scope, so reverse dead order frees them last).
        for i in 0..params.len {
            self.scope_locals.push(rets.len + i);
        }
        self.scope_enter();
        self.lower_stmt(fd.body);
        self.scope_exit();
        self.emit_deads_down_to(0);
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
        self.begin_body(cnode);
        let cd = self.f.node(cnode).as_data.closure;
        let sp = self.f.node(cnode).span;
        let rets = cd.returns;
        for i in 0..rets.len {
            let rn = unsafe self.f.list(rets)[i as usize];
            let _ = self.body.add_local(
                ir::LocalDecl {
                    ty: self.nty(rn),
                    storage: ir::LS_RET,
                    is_mutable: true,
                    span: sp,
                    decl: NODE_NONE,
                    item: DefId { module: 0, node: NODE_NONE },
                },
            );
        }
        self.body.returns = rets.len;
        if rets.len == 0 && cd.expr_body {
            // an expr-body closure with no written return list still returns its body's INFERRED
            // type (comparators etc); a unit body keeps zero return slots
            let bt = self.nty(cd.body);
            if bt != TYPE_NONE && !(self.f.ty(bt).kind == TypeKind::TYPE_BUILTIN && self.f.ty(bt).as_data.builtin == BuiltinType::BT_VOID) {
                let _ = self.body.add_local(
                    ir::LocalDecl {
                        ty: bt,
                        storage: ir::LS_RET,
                        is_mutable: true,
                        span: sp,
                        decl: NODE_NONE,
                        item: DefId { module: 0, node: NODE_NONE },
                    },
                );
                self.body.returns = 1;
            }
        }
        let params = cd.params;
        for i in 0..params.len {
            let pn = unsafe self.f.list(params)[i as usize];
            let l = self.body.add_local(
                ir::LocalDecl {
                    ty: self.nty(pn),
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
                    ty: self.nty(c),
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
            if c != decl {
                // a pattern-shorthand capture: body identifiers resolve to the SHORTHAND ident,
                // which itself resolves to the binding -- both spellings name this local
                self.bind(c, l);
            }
        }
        self.body.args = params.len + caps.len;
        self.body.entry = self.open_block();
        self.cur = self.body.entry;
        self.run_start = 0;
        // Parameters are the body's to destroy; CAPTURES are not. The env stays whole across any
        // number of calls, and whoever owns the closure VALUE frees the env (and so the captures)
        // exactly once when it drops -- the derived closure glue in the emitter.
        for i in 0..params.len {
            self.scope_locals.push(rets.len + i);
        }
        self.scope_enter();
        if cd.expr_body && self.body.returns != 0 {
            let pl = self.place_of_local(0);
            self.lower_value_into(cd.body, pl);
        } else {
            self.lower_stmt(cd.body);
        }
        self.scope_exit();
        self.emit_deads_down_to(0);
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
        let ty = self.nty(cnode);
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

    /// Lower a bare TYPED expression as a one-return body (the facade behind expression-level
    /// CTFE requests: array lengths, discriminants, folds).
    pub fn lower_expr_root(self: &mut Self, expr: NodeId) bool {
        let sp = self.f.node(expr).span;
        let ty = self.nty(expr);
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
        let op = self.lower_expr(expr);
        if op != ir::IR_NONE {
            let pl = self.place_of_local(0);
            let rv = self.rv_use(op, ty);
            self.assign(pl, rv, sp);
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
        return self.nty(rn);
    }

    // ---- statements -------------------------------------------------------------------------------

    fn lower_stmt(self: &mut Self, id: NodeId) {
        if id == NODE_NONE || self.err.len() != 0 {
            return;
        }
        let k = self.f.node(id).kind;
        let _sp = self.f.node(id).span;
        if k == NodeKind::NODE_BLOCK {
            self.tp(ir::TP_SCOPE_PUSH, 0, id);
            self.scope_enter();
            let stmts = self.f.node(id).as_data.block.statements;
            for i in 0..stmts.len {
                self.lower_stmt(unsafe self.f.list(stmts)[i as usize]);
                if self.err.len() != 0 {
                    return;
                }
                self.tp(ir::TP_NLL, i, id);
            }
            self.tp(ir::TP_SCOPE_POP, 0, id);
            self.scope_exit();
        } else if k == NodeKind::NODE_LET {
            self.lower_let(id);
        } else if k == NodeKind::NODE_EXPRESSION_STATEMENT {
            let v = self.f.node(id).as_data.single.value;
            self.tp(ir::TP_MARK_PUSH, 0, id);
            if self.f.node(v).kind == NodeKind::NODE_CALL {
                self.chk_root = v; // a statement-root call may carry a cancellation check
                self.chk_base = self.scope_locals.len();
            }
            let op = self.lower_expr(v);
            self.chk_root = NODE_NONE;
            self.tp(ir::TP_MARK_POP, 0, id);
            // A fully discarded result still OWNS its value: register the fresh dest temp for
            // scope-exit drop so an owning call result (`foo();`) is not leaked. Drop elaboration
            // skips non-owning types, and only unregistered temporaries are touched.
            if op != ir::IR_NONE {
                let o = *self.body.operands.at(op as usize);
                if o.kind == ir::OP_COPY || o.kind == ir::OP_MOVE {
                    let pl0 = *self.body.places.at(o.data as usize);
                    if pl0.proj_len == 0 && self.body.locals.at(pl0.base as usize).storage == ir::LS_TEMP && self.body.locals.at(
                        pl0.base as usize,
                    ).decl == NODE_NONE {
                        let mut ld0 = *self.body.locals.at(pl0.base as usize);
                        ld0.decl = id;
                        self.body.locals.set(pl0.base as usize, ld0);
                        self.scope_locals.push(pl0.base);
                    }
                }
            }
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
        } else if k == NodeKind::NODE_CONST {
            // A LOCAL const folds to static data only when its initializer is const-evaluable
            // (a `const fn` call or a value expression). An initializer calling a PLAIN fn makes
            // it a RUNTIME local: evaluated here, owned here, freed at scope exit.
            let cdf = self.f.node(id).as_data.const_def;
            let mut runtime = false;
            if cdf.value != NODE_NONE && self.f.node(cdf.value).kind == NodeKind::NODE_CALL {
                let cal = self.f.node(cdf.value).as_data.call;
                let mut fd9 = self.f.res(cal.callee);
                if fd9.node == NODE_NONE {
                    fd9 = self.path_res(cal.callee);
                }
                if fd9.node != NODE_NONE {
                    let fa9 = unsafe &*(&*self.pkg).module_ast_const(fd9.module);
                    if fa9.at_const(fd9.node).kind == NodeKind::NODE_FUNCTION && !fa9.at_const(fd9.node).as_data.function.is_const {
                        runtime = true;
                    }
                }
            }
            // Runtime initializer: ordinary events flow (the replay sees the same helper sequence
            // the walk produced). Folded initializer: no IR and no events -- the const domain's
            // own CTFE rules (traps, use-after-free, budgets) police it.
            if runtime {
                self.tp(ir::TP_MARK_PUSH, 0, id);
                let vop = self.lower_expr(cdf.value);
                if vop != ir::IR_NONE {
                    let ty9 = self.nty(cdf.value);
                    let l9 = self.body.add_local(
                        ir::LocalDecl {
                            ty: ty9,
                            storage: ir::LS_USER,
                            is_mutable: false,
                            span: self.f.node(id).span,
                            decl: id,
                            item: DefId { module: 0, node: NODE_NONE },
                        },
                    );
                    self.bind(id, l9);
                    self.bind(cdf.name, l9);
                    self.user_local_live(l9, self.f.node(id).span);
                    let pl9 = self.place_of_local(l9);
                    let rv9 = self.rv_use(vop, ty9);
                    self.assign(pl9, rv9, self.f.node(id).span);
                }
                self.tp(ir::TP_MARK_POP, 0, id);
            }
        } else if k == NodeKind::NODE_STATIC_ASSERT || k == NodeKind::NODE_FUNCTION || k == NodeKind::NODE_STRUCT || k == NodeKind::NODE_ENUM || k == NodeKind::NODE_TYPE_ALIAS {
            // Item statements: local consts fold at CTFE; nested items own their own bodies.
        } else {
            // Everything else is an expression in statement position.
            let _ = self.lower_expr(id);
        }
    }

    // Inline assembly: outputs lower as places (copies carry the place id), inputs as values;
    // template/constraints/clobbers stay in the AST the backend re-reads through `item`.
    fn lower_asm(self: &mut Self, id: NodeId) {
        let d = self.f.node(id).as_data.asm_stmt;
        let sp = self.f.node(id).span;
        let mut argv = self.avget();
        let mut i: u32 = 0;
        while i + 1 < d.outputs.len {
            let pe = unsafe self.f.list(d.outputs)[(i + 1) as usize];
            let pl = self.lower_place_or_spill(pe);
            if pl == ir::IR_NONE {
                return;
            }
            argv.push(self.copy_op(pl));
            i += 2;
        }
        i = 0;
        while i + 1 < d.inputs.len {
            let ve = unsafe self.f.list(d.inputs)[(i + 1) as usize];
            let op = self.lower_expr(ve);
            if op == ir::IR_NONE {
                return;
            }
            argv.push(op);
            i += 2;
        }
        let start = self.pool_ops(&argv);
        let ut = Ast::builtin(BuiltinType::BT_VOID);
        let t = self.temp(ut, sp);
        let pl9 = self.place_of_local(t);
        self.assign(
            pl9,
            ir::Rvalue {
                kind: ir::RV_INTRINSIC,
                a: start,
                b: argv.len() as u32,
                c: ir::IN_ASM,
                target: ut,
                item: DefId { module: self.module, node: id },
            },
            sp,
        );
        self.avput(argv);
    }

    fn lower_let(self: &mut Self, id: NodeId) {
        let ld = self.f.node(id).as_data.let_stmt;
        let sp = self.f.node(id).span;
        let nk = self.f.node(ld.name).kind;
        self.tp(ir::TP_MARK_PUSH, 0, id);
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
            self.mark_user_move(vop);
            let vpl = self.spill(vop, sp);
            let fail = ir::IR_NONE;
            self.pattern_bind(ld.name, vpl, fail);
            let tk: u8 = if nk == NodeKind::NODE_PATTERN_TUPLE {
                ir::TP_LET_TUPLE;
            } else {
                ir::TP_LET;
            };
            self.tp(tk, 0, id);
            return;
        }
        let ty = self.nty(id);
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
        self.user_local_live(l, sp);
        if ld.value == NODE_NONE {
            self.body.has_uninit_decl = true; // split init: only this form can use-before-init
        }
        if ld.value != NODE_NONE {
            if self.f.node(ld.value).kind == NodeKind::NODE_CALL {
                self.chk_root = ld.value; // a plain-let root call may carry a cancellation check
                self.chk_base = self.scope_locals.len() - 1; // exclude `l`: uninit until the assign
            }
            let op = self.lower_expr(ld.value);
            self.chk_root = NODE_NONE;
            if op == ir::IR_NONE {
                return;
            }
            self.mark_user_move(op);
            let pl = self.place_of_local(l);
            let rv = self.rv_use(op, ty);
            self.assign(pl, rv, sp);
        }
        self.tp(ir::TP_LET, 0, id);
    }

    fn lower_return(self: &mut Self, id: NodeId) {
        let rd = self.f.node(id).as_data.return_stmt;
        let sp = self.f.node(id).span;
        self.tp(ir::TP_MARK_PUSH, 0, id);
        for i in 0..rd.values.len {
            let v = unsafe self.f.list(rd.values)[i as usize];
            let op = self.lower_expr(v);
            if op == ir::IR_NONE {
                return;
            }
            self.mark_user_move(op);
            self.tp(ir::TP_RET_VAL, i, v);
            let pl = self.place_of_local(i);
            let ty = self.body.locals.at(i as usize).ty;
            let rv = self.rv_use(op, ty);
            self.assign(pl, rv, sp);
        }
        self.tp(ir::TP_RET_POST, 0, id);
        self.emit_defers_down_to(0);
        self.emit_deads_down_to(0);
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
        self.emit_deads_down_to(lc.locals_depth);
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
        self.emit_deads_down_to(lc.locals_depth);
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
        if self.proj_frames.len() != 0 {
            let bc = self.binder_cond(d.condition);
            if bc >= 0 {
                // binder-const branch: only the taken side lowers, so the untaken side's
                // calls are never demanded
                if bc == 1 {
                    self.lower_stmt(d.then_branch);
                } else if d.else_branch != NODE_NONE {
                    self.lower_stmt(d.else_branch);
                }
                return;
            }
        }
        {
            let zc = self.zst_cond(d.condition);
            if zc >= 0 {
                // `sizeof(T) <op> <const>` folds per instance: the untaken side never lowers --
                // a ZST container path may not even be spellable for the other instantiation
                if zc == 1 {
                    self.lower_stmt(d.then_branch);
                } else if d.else_branch != NODE_NONE {
                    self.lower_stmt(d.else_branch);
                }
                return;
            }
        }
        self.tp(ir::TP_MARK_PUSH, 0, id);
        let cop = self.lower_expr(d.condition);
        self.tp(ir::TP_MARK_POP, 0, id);
        if cop == ir::IR_NONE {
            return;
        }
        let then_b = self.open_block();
        let els_b = self.open_block();
        let join = self.open_block();
        self.branch_bool(cop, then_b, els_b, sp);
        self.tp(ir::TP_FLOW_SAVE, 0, id);
        self.lower_stmt(d.then_branch);
        self.tp(ir::TP_FLOW_ELSE, 0, id);
        self.seal(self.goto_term(join, sp), els_b);
        if d.else_branch != NODE_NONE {
            self.lower_stmt(d.else_branch);
        }
        self.tp(ir::TP_FLOW_JOIN, 0, id);
        self.seal(self.goto_term(join, sp), join);
    }

    // A preemption safepoint marker at the top of a loop body; the backend prints it only for
    // programs that use the coroutine runtime, and never inside std::parallel itself. In a body
    // that can carry a cancellation edge, the combined form (plan 10.4) is emitted instead: the
    // same tick, whose cold half also accepts a pending unmasked cancellation and enters this
    // frame's cleanup ladder -- a compute-bound task that never waits still cleanly stops.
    fn loop_safepoint(self: &mut Self, sp: tok::Span) {
        // Only a body a launched coroutine can execute needs the preemption tick; every other
        // loop skips the intrinsic (and so the emitted `__sc_safepoint()` and its TLS decrement).
        let ow9 = self.body.owner;
        if ow9.node != NODE_NONE {
            let osp = unsafe (&*(&*self.pkg).module_ast_const(ow9.module)).at_const(ow9.node).span;
            if !unsafe (&*self.pkg).co_on(ow9.module, osp) {
                return;
            }
        }
        if self.in_defer == 0 && unsafe (&*self.pkg).cancel_used && self.chk_enabled() {
            self.safepoint_cancel(sp);
            return;
        }
        let ut = Ast::builtin(BuiltinType::BT_VOID);
        let t = self.temp(ut, sp);
        let pl = self.place_of_local(t);
        self.assign(
            pl,
            ir::Rvalue {
                kind: ir::RV_INTRINSIC,
                a: 0,
                b: 0,
                c: ir::IN_SAFEPOINT,
                target: ut,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
    }

    // The combined preemption + cancellation safepoint: tick result 1 means the cold half accepted
    // a pending request -- run this frame's cancellation ladder. All locals in scope at a loop-body
    // top are initialized (a pending mid-let cannot exist here), so the ladder deads everything.
    // Safepoints whose live scope state matches a previously emitted ladder JUMP to that ladder
    // instead of duplicating it -- sibling loops in one body then share one cleanup sequence.
    fn safepoint_cancel(self: &mut Self, sp: tok::Span) {
        let it = Ast::builtin(BuiltinType::BT_I32);
        let t = self.temp(it, sp);
        let pl = self.place_of_local(t);
        self.assign(
            pl,
            ir::Rvalue {
                kind: ir::RV_INTRINSIC,
                a: 0,
                b: 0,
                c: ir::IN_SAFEPOINT_C,
                target: it,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        let cond = self.copy_op(pl);
        let mut reuse = self.sp_ladder_b != 0xFFFFFFFFu32;
        if reuse {
            reuse = self.sp_ladder_locals.len() == self.scope_locals.len() && self.sp_ladder_defers.len() == self.defers.len();
        }
        if reuse {
            for i in 0..self.scope_locals.len() {
                if self.sp_ladder_locals[i] != self.scope_locals[i] {
                    reuse = false;
                    break;
                }
            }
        }
        if reuse {
            for i in 0..self.defers.len() {
                if self.sp_ladder_defers[i] != self.defers[i] {
                    reuse = false;
                    break;
                }
            }
        }
        if reuse {
            let cont0 = self.open_block();
            let mut ts = self.term0(ir::TM_SWITCH, sp);
            ts.a = cond;
            ts.sw_start = self.body.switch_pool.len() as u32;
            self.body.switch_pool.push(1u64 << 32 | self.sp_ladder_b as u64);
            ts.sw_len = 1;
            ts.t0 = cont0;
            self.seal(ts, cont0);
            return;
        }
        let pk = unsafe &*self.pkg;
        let lbegin = pk.sugar_item(loader::SugarItem::SI_CANCEL_LBEGIN);
        let lend = pk.sugar_item(loader::SugarItem::SI_CANCEL_LEND);
        let ut = Ast::builtin(BuiltinType::BT_VOID);
        let ladder_b = self.open_block();
        let cont_b = self.open_block();
        let mut t9 = self.term0(ir::TM_SWITCH, sp);
        t9.a = cond;
        t9.sw_start = self.body.switch_pool.len() as u32;
        self.body.switch_pool.push(1u64 << 32 | ladder_b as u64);
        t9.sw_len = 1;
        t9.t0 = cont_b;
        self.seal(t9, ladder_b);
        let b0 = self.body.oper_pool.len() as u32;
        let _ = self.emit_call(lbegin, ir::IR_NONE, b0, 0, 0, 0, ut, sp);
        self.emit_defers_down_to(0);
        self.emit_deads_down_to(0);
        let e0 = self.body.oper_pool.len() as u32;
        let _ = self.emit_call(lend, ir::IR_NONE, e0, 0, 0, 0, ut, sp);
        let mut rt = self.term0(ir::TM_RETURN, sp);
        rt.args_len = ir::RET_CANCEL;
        self.seal(rt, cont_b);
        self.sp_ladder_b = ladder_b;
        self.sp_ladder_locals.truncate(0);
        for i in 0..self.scope_locals.len() {
            self.sp_ladder_locals.push(self.scope_locals[i]);
        }
        self.sp_ladder_defers.truncate(0);
        for i in 0..self.defers.len() {
            self.sp_ladder_defers.push(self.defers[i]);
        }
    }

    fn lower_while(self: &mut Self, id: NodeId) {
        let d = self.f.node(id).as_data.while_stmt;
        let sp = self.f.node(id).span;
        self.tp(ir::TP_LOOP_PUSH, 0, id);
        // A do-while condition replays FIRST (walk order) but lowers at the TAIL (CFG order): the
        // tail records its events in place and tape_splice moves them here.
        let cond_at = self.tape.len();
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
                self.tp(ir::TP_MARK_PUSH, 0, id);
                let cop = self.lower_expr(d.condition);
                self.tp(ir::TP_MARK_POP, 0, id);
                if cop == ir::IR_NONE {
                    return;
                }
                self.branch_bool(cop, body_b, exit, sp);
            } else {
                self.seal(self.goto_term(body_b, sp), body_b);
            }
        }
        self.loops.push(
            LoopCtx {
                label: d.label,
                brk: exit,
                cont: head,
                defer_depth: self.defers.len(),
                locals_depth: self.scope_locals.len(),
                result: ir::IR_NONE,
            },
        );
        self.loop_safepoint(sp);
        let ar9: u32 = if d.is_do || d.condition == NODE_NONE {
            1;
        } else {
            0;
        };
        self.tp(ir::TP_BODY_START, ar9, id);
        self.lower_stmt(d.body);
        self.tp(ir::TP_BODY_END, 0, id);
        let _ = self.loops.pop();
        if d.is_do {
            // tail: condition decides back-edge vs exit; `head` is the continue target
            self.seal(self.goto_term(head, sp), head);
            if d.condition != NODE_NONE {
                let cond_from = self.tape.len();
                self.tp(ir::TP_MARK_PUSH, 0, id);
                let cop = self.lower_expr(d.condition);
                self.tp(ir::TP_MARK_POP, 0, id);
                self.tape_splice(cond_at, cond_from);
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
        self.tp(ir::TP_LOOP_POP, 0, id);
    }

    // ---- reflection binder expansion --------------------------------------------------------------

    // Resolve a SELF-pool type through the instance env (innermost-wins); the result may live in
    // another module's pool.
    fn env_resolve(self: &Self, t: TypeId, rm: &mut ModuleId, rt: &mut TypeId) bool {
        let mut cm = self.module;
        let mut ct = t;
        let mut guard = 0;
        while guard < 16 {
            let y = *unsafe (&*(&*self.pkg).module_ast_const(cm)).type_at(ct);
            if y.kind != TypeKind::TYPE_GENERIC {
                *rm = cm;
                *rt = ct;
                return true;
            }
            let mut hit = false;
            let mut i = self.env.len();
            while i > 0 {
                i -= 1;
                let sb = *self.env.at(i);
                if sb.pm == y.module && sb.pnode == y.as_data.decl {
                    cm = sb.am;
                    ct = sb.at;
                    hit = true;
                    break;
                }
            }
            if !hit {
                return false;
            }
            guard += 1;
        }
        return false;
    }

    // Reintern a foreign-pool type into THIS module's pool (identity when already local).
    fn reintern_ty(self: &mut Self, rm: ModuleId, rt: TypeId) TypeId {
        if rm == self.module || rt == TYPE_NONE {
            return rt;
        }
        let oa = unsafe &*(&*self.pkg).module_ast_const(rm);
        let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
        return sa.reintern(oa, rt);
    }

    // Rebuild `t` (SELF pool) with `pm`'s params replaced by `args` (SELF pool) -- the projection
    // field-type substitution for instance owners.
    fn proj_ty_map(self: &mut Self, t: TypeId, pm: ModuleId, params: NodeList, args: *const TypeId, n: u32) TypeId {
        let y = *self.f.ty(t);
        let da = unsafe &*(&*self.pkg).module_ast_const(pm);
        if y.kind == TypeKind::TYPE_GENERIC {
            for i in 0..n {
                if y.module == pm && unsafe da.list(params)[i as usize] == y.as_data.decl {
                    return unsafe args[i as usize];
                }
            }
            return t;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            let e = self.proj_ty_map(y.as_data.elem, pm, params, args, n);
            if e == y.as_data.elem {
                return t;
            }
            let mut nt = y;
            nt.as_data.elem = e;
            let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
            return sa.intern_type(nt);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let src = *self.f.instance(y.as_data.inst);
            let mut na: [TypeId; 8] = [[0] = TYPE_NONE];
            let mut changed = false;
            for i in 0..src.n {
                unsafe na[i as usize] = self.proj_ty_map(unsafe src.args[i as usize], pm, params, args, n);
                if unsafe na[i as usize] != unsafe src.args[i as usize] {
                    changed = true;
                }
            }
            if changed {
                let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
                return sa.intern_instance(src.module, src.decl, &na[0], src.n);
            }
            return t;
        }
        return t;
    }

    // The concrete aggregate behind the SELF-pool owner type: decl module/node, or NODE_NONE.
    const fn proj_owner_decl(self: &Self, owner: TypeId, out_m: &mut ModuleId) NodeId {
        let y = *self.f.ty(owner);
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            *out_m = y.module;
            return y.as_data.decl;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.f.instance(y.as_data.inst);
            *out_m = it.module;
            return it.decl;
        }
        return NODE_NONE;
    }

    // The k-th FIELD node of the (struct) owner; NODE_NONE past the end.
    fn proj_field_node(self: &Self, owner: TypeId, idx: i64, out_m: &mut ModuleId) NodeId {
        let dn = self.proj_owner_decl(owner, out_m);
        if dn == NODE_NONE {
            return NODE_NONE;
        }
        let da = unsafe &*(&*self.pkg).module_ast_const(*out_m);
        if da.at_const(dn).kind != NodeKind::NODE_STRUCT {
            return NODE_NONE;
        }
        let ag = da.at_const(dn).as_data.aggregate;
        let mut k: i64 = 0;
        for i in 0..ag.members.len {
            let fid = unsafe da.list(ag.members)[i as usize];
            if !ag.is_tuple && da.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            if k == idx {
                return fid;
            }
            k += 1;
        }
        return NODE_NONE;
    }

    // The k-th VARIANT node of the (enum) owner; NODE_NONE past the end.
    const fn proj_variant_node(self: &Self, owner: TypeId, idx: i64, out_m: &mut ModuleId) NodeId {
        let dn = self.proj_owner_decl(owner, out_m);
        if dn == NODE_NONE {
            return NODE_NONE;
        }
        let da = unsafe &*(&*self.pkg).module_ast_const(*out_m);
        if da.at_const(dn).kind != NodeKind::NODE_ENUM {
            return NODE_NONE;
        }
        let ag = da.at_const(dn).as_data.aggregate;
        if idx < 0 || idx >= ag.members.len as i64 {
            return NODE_NONE;
        }
        return unsafe da.list(ag.members)[idx as usize];
    }

    // The k-th field's TYPE under the owner's instance args, in THIS pool; TYPE_NONE = unprojectable.
    fn proj_field_ty(self: &mut Self, owner: TypeId, idx: i64) TypeId {
        let mut dm: ModuleId = 0;
        let fid = self.proj_field_node(owner, idx, &mut dm);
        if fid == NODE_NONE {
            return TYPE_NONE;
        }
        let da = unsafe &*(&*self.pkg).module_ast_const(dm);
        let mut ftn = fid;
        if da.at_const(fid).kind == NodeKind::NODE_FIELD {
            ftn = da.at_const(fid).as_data.field.ty;
        }
        let ftl = da.type_of(ftn);
        if ftl == TYPE_NONE {
            return TYPE_NONE;
        }
        let mut ft = self.reintern_ty(dm, ftl);
        let y = *self.f.ty(owner);
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.f.instance(y.as_data.inst);
            let gda = unsafe &*(&*self.pkg).module_ast_const(it.module);
            let gens = gda.at_const(it.decl).as_data.aggregate.generics;
            let mut gn = gens.len;
            if gn > it.n as u32 {
                gn = it.n;
            }
            ft = self.proj_ty_map(ft, it.module, gens, &it.args[0], gn);
        }
        return ft;
    }

    // The innermost active frame for `binder`, or -1.
    fn proj_frame_of(self: &Self, binder: NodeId) i64 {
        let mut i = self.proj_frames.len();
        while i > 0 {
            i -= 1;
            if self.proj_frames.at(i).binder == binder {
                return i as i64;
            }
        }
        return 0 - 1;
    }

    // The concrete type of the ACTIVE copy behind a projection-typed spelling: `f.value`'s type,
    // structurally (through refs/pointers/instances). Identity while no frame is active.
    fn proj_subst_ty(self: &mut Self, t: TypeId) TypeId {
        if t == TYPE_NONE || self.proj_frames.len() == 0 {
            return t;
        }
        let y = *self.f.ty(t);
        if y.kind == TypeKind::TYPE_FIELD_PROJECTION {
            let fi = self.proj_frame_of(y.as_data.proj.binder);
            if fi < 0 {
                return t;
            }
            let fr = *self.proj_frames.at(fi as usize);
            let vt = if fr.mode == 0 {
                self.proj_field_ty(fr.owner_st, fr.idx);
            } else if fr.mode == 1 {
                self.proj_payload_ty(fr.owner_st, fr.idx, 0);
            } else {
                self.proj_payload_ty(fr.owner_st, fr.vidx, fr.idx);
            };
            if vt == TYPE_NONE {
                return t;
            }
            return vt;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            let e = self.proj_subst_ty(y.as_data.elem);
            if e == y.as_data.elem {
                return t;
            }
            let mut nt = y;
            nt.as_data.elem = e;
            let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
            return sa.intern_type(nt);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let src = *self.f.instance(y.as_data.inst);
            let mut na: [TypeId; 8] = [[0] = TYPE_NONE];
            let mut changed = false;
            for i in 0..src.n {
                unsafe na[i as usize] = self.proj_subst_ty(unsafe src.args[i as usize]);
                if unsafe na[i as usize] != unsafe src.args[i as usize] {
                    changed = true;
                }
            }
            if changed {
                let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
                return sa.intern_instance(src.module, src.decl, &na[0], src.n);
            }
            return t;
        }
        return t;
    }

    // Every node-type read routes through the active-copy substitution.
    fn nty(self: &mut Self, id: NodeId) TypeId {
        let t = self.f.node_type(id);
        return self.proj_subst_ty(t);
    }

    // The type of variant `vidx`'s payload entry `k`, in THIS pool (instance args applied).
    fn proj_payload_ty(self: &mut Self, owner: TypeId, vidx: i64, k: i64) TypeId {
        let mut dm: ModuleId = 0;
        let vid = self.proj_variant_node(owner, vidx, &mut dm);
        if vid == NODE_NONE {
            return TYPE_NONE;
        }
        let da = unsafe &*(&*self.pkg).module_ast_const(dm);
        let pls = da.at_const(vid).as_data.variant.payload;
        if k < 0 || k >= pls.len as i64 {
            return TYPE_NONE;
        }
        let pe = unsafe da.list(pls)[k as usize];
        let mut ptn = pe;
        if da.at_const(pe).kind == NodeKind::NODE_FIELD {
            ptn = da.at_const(pe).as_data.field.ty;
        }
        let ptl = da.type_of(ptn);
        if ptl == TYPE_NONE {
            return TYPE_NONE;
        }
        let mut pt = self.reintern_ty(dm, ptl);
        let y = *self.f.ty(owner);
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.f.instance(y.as_data.inst);
            let gda = unsafe &*(&*self.pkg).module_ast_const(it.module);
            let gens = gda.at_const(it.decl).as_data.aggregate.generics;
            let mut gn = gens.len;
            if gn > it.n as u32 {
                gn = it.n;
            }
            pt = self.proj_ty_map(pt, it.module, gens, &it.args[0], gn);
        }
        return pt;
    }

    // The C-visible tag value of variant `idx`: the declaration index for payload enums, the
    // (possibly explicit) enum constant value for bare ones.
    fn proj_tag_val(self: &Self, owner: TypeId, idx: i64) i64 {
        let mut dm: ModuleId = 0;
        let dn = self.proj_owner_decl(owner, &mut dm);
        if dn == NODE_NONE {
            return idx;
        }
        return self.tag_of_decl(dm, dn, idx);
    }

    // The C tag value of variant `idx` within enum declaration `dn` of module `dm`: the ordinal
    // for payload enums (tag = declaration index), the explicit discriminant for bare ones.
    fn tag_of_decl(self: &Self, dm: ModuleId, dn: NodeId, idx: i64) i64 {
        let da = unsafe &*(&*self.pkg).module_ast_const(dm);
        let ms = da.at_const(dn).as_data.aggregate.members;
        let mut has_pay = false;
        for i in 0..ms.len {
            let vid = unsafe da.list(ms)[i as usize];
            if da.at_const(vid).kind == NodeKind::NODE_VARIANT && da.at_const(vid).as_data.variant.payload.len != 0 {
                has_pay = true;
            }
        }
        if has_pay {
            return idx;
        }
        let mut cur: i64 = 0 - 1;
        let mut i: i64 = 0;
        while i <= idx && i < ms.len as i64 {
            let vid = unsafe da.list(ms)[i as usize];
            let vv = da.at_const(vid).as_data.variant.value;
            let mut set = false;
            if vv != NODE_NONE && unsafe (&*self.pkg).cir != null {
                let cev = unsafe &mut *((&*self.pkg).cir as *mut iri::Interp);
                let cv = cev.eval(dm, vv);
                if cv.kind == iri::IV_INT {
                    cur = cv.i;
                    set = true;
                }
            }
            if !set {
                cur += 1;
            }
            i += 1;
        }
        return cur;
    }

    // A member access on a reflection binder: resolved through the innermost active copy frame.
    fn lower_proj_member_place(self: &mut Self, id: NodeId, blid: NodeId) ir::PlaceId {
        let fi = self.proj_frame_of(blid);
        if fi < 0 {
            self.fail_at("binder-escape", id);
            return ir::IR_NONE;
        }
        let fr = *self.proj_frames.at(fi as usize);
        let md = self.f.node(id).as_data.member;
        let nsp = self.f.node(md.member).as_data.name.text;
        let name = self.src.slice(nsp.start as usize, nsp.end as usize);
        let sp = self.f.node(id).span;
        let mut ty = self.nty(id);
        if name == "index" {
            if ty == TYPE_NONE {
                ty = Ast::builtin(BuiltinType::BT_USIZE);
            }
            let op = self.const_op(
                ir::Constant {
                    kind: ir::CK_INT,
                    ty: ty,
                    val: fr.idx,
                    raw: sp,
                    item: DefId { module: 0, node: NODE_NONE },
                    targ_start: 0,
                    targ_len: 0,
                },
            );
            return self.spill(op, sp);
        }
        if fr.mode != 1 && (name == "size" || name == "kind" || name == "offset") {
            let fty = if fr.mode == 0 {
                self.proj_field_ty(fr.owner_st, fr.idx);
            } else {
                self.proj_payload_ty(fr.owner_st, fr.vidx, fr.idx);
            };
            if fty == TYPE_NONE {
                self.fail_at("binder-escape", id);
                return ir::IR_NONE;
            }
            let mut v: i64 = -1;
            let mut svc = lay::Svc::new(self.pkg);
            if name == "size" {
                let l = svc.layout(self.module, fty);
                if l.ok {
                    v = l.size as i64;
                }
            } else if name == "offset" {
                let mut dmf: ModuleId = 0;
                let fid = if fr.mode == 0 {
                    self.proj_field_node(fr.owner_st, fr.idx, &mut dmf);
                } else {
                    NODE_NONE;
                };
                if fid != NODE_NONE {
                    v = svc.field_offset(self.module, fr.owner_st, fid);
                }
            } else {
                let pk9 = unsafe &*self.pkg;
                let sh = pk9.prelude_lookup("str", true);
                let lh = pk9.prelude_lookup("Slice", true);
                if pk9.cir != null && sh.node != NODE_NONE && lh.node != NODE_NONE {
                    let cev = unsafe &mut *(pk9.cir as *mut iri::Interp);
                    v = cev.ti_tag(self.module, fty, sh.mid, sh.node, lh.mid, lh.node);
                    if v < 0 {
                        v = 0;
                    }
                }
            }
            svc.free();
            if v < 0 {
                self.fail_at("binder-layout", id);
                return ir::IR_NONE;
            }
            if ty == TYPE_NONE {
                ty = Ast::builtin(BuiltinType::BT_USIZE);
            }
            let op = self.const_op(
                ir::Constant {
                    kind: ir::CK_INT,
                    ty: ty,
                    val: v,
                    raw: sp,
                    item: DefId { module: 0, node: NODE_NONE },
                    targ_start: 0,
                    targ_len: 0,
                },
            );
            return self.spill(op, sp);
        }
        if fr.mode == 1 && (name == "tag" || name == "payload") {
            let mut dmv: ModuleId = 0;
            let vid = self.proj_variant_node(fr.owner_st, fr.idx, &mut dmv);
            if vid == NODE_NONE {
                self.fail_at("binder-escape", id);
                return ir::IR_NONE;
            }
            let mut v: i64 = fr.idx;
            if name == "tag" {
                v = self.proj_tag_val(fr.owner_st, fr.idx);
            } else {
                let dav = unsafe &*(&*self.pkg).module_ast_const(dmv);
                v = dav.at_const(vid).as_data.variant.payload.len;
            }
            if ty == TYPE_NONE {
                ty = Ast::builtin(BuiltinType::BT_I32);
            }
            let op = self.const_op(
                ir::Constant {
                    kind: ir::CK_INT,
                    ty: ty,
                    val: v,
                    raw: sp,
                    item: DefId { module: 0, node: NODE_NONE },
                    targ_start: 0,
                    targ_len: 0,
                },
            );
            return self.spill(op, sp);
        }
        if name == "name" {
            let mut dmn: ModuleId = 0;
            let mut nid2 = NODE_NONE;
            if fr.mode == 1 {
                nid2 = self.proj_variant_node(fr.owner_st, fr.idx, &mut dmn);
            } else if fr.mode == 2 {
                let pv = self.proj_variant_node(fr.owner_st, fr.vidx, &mut dmn);
                if pv != NODE_NONE {
                    let dap = unsafe &*(&*self.pkg).module_ast_const(dmn);
                    let pls = dap.at_const(pv).as_data.variant.payload;
                    if fr.idx < pls.len as i64 {
                        nid2 = unsafe dap.list(pls)[fr.idx as usize];
                    }
                }
            } else {
                nid2 = self.proj_field_node(fr.owner_st, fr.idx, &mut dmn);
            }
            if nid2 == NODE_NONE {
                self.fail_at("binder-escape", id);
                return ir::IR_NONE;
            }
            let dan = unsafe &*(&*self.pkg).module_ast_const(dmn);
            let nk = dan.at_const(nid2).kind;
            let span2 = if nk == NodeKind::NODE_FIELD {
                dan.at_const(dan.at_const(nid2).as_data.field.name).as_data.name.text;
            } else if nk == NodeKind::NODE_VARIANT {
                dan.at_const(dan.at_const(nid2).as_data.variant.name).as_data.name.text;
            } else {
                tok::Span { start: 0, end: 0 };
            };
            if span2.end <= span2.start {
                self.fail_at("binder-name", id);
                return ir::IR_NONE;
            }
            let op = self.const_op(
                ir::Constant {
                    kind: ir::CK_STR,
                    ty: ty,
                    val: tt::TokenType::RawStringLiteral as i64,
                    raw: span2,
                    item: DefId { module: dmn, node: nid2 },
                    targ_start: 0,
                    targ_len: 0,
                },
            );
            return self.spill(op, sp);
        }
        if fr.mode == 1 && (name == "is_active" || name == "other_active") {
            let mut dmv: ModuleId = 0;
            let vid = self.proj_variant_node(fr.owner_st, fr.idx, &mut dmv);
            if vid == NODE_NONE {
                self.fail_at("binder-escape", id);
                return ir::IR_NONE;
            }
            let mut sub = fr.sub0;
            if name == "other_active" && fr.sub1 != ir::IR_NONE {
                sub = fr.sub1;
            }
            let mut pay = ir::IR_NONE;
            let cond = self.variant_test(sub, DefId { module: dmv, node: vid }, sp, &mut pay);
            if cond == ir::IR_NONE {
                return ir::IR_NONE;
            }
            return self.spill(cond, sp);
        }
        if name == "value" || name == "other" {
            let mut sub = fr.sub0;
            if name == "other" && fr.sub1 != ir::IR_NONE {
                sub = fr.sub1;
            }
            let base = self.place_project(sub, ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: fr.owner_st });
            if fr.mode == 0 {
                let mut dmf: ModuleId = 0;
                let fid = self.proj_field_node(fr.owner_st, fr.idx, &mut dmf);
                let fty = self.proj_field_ty(fr.owner_st, fr.idx);
                if fid == NODE_NONE || fty == TYPE_NONE {
                    self.fail_at("binder-escape", id);
                    return ir::IR_NONE;
                }
                let mut dmo: ModuleId = 0;
                let odn = self.proj_owner_decl(fr.owner_st, &mut dmo);
                let dao = unsafe &*(&*self.pkg).module_ast_const(dmo);
                let mut fdata: u32 = 0;
                if dao.at_const(odn).kind == NodeKind::NODE_STRUCT && dao.at_const(odn).as_data.aggregate.is_union {
                    fdata = ir::PJ_UNION_FIELD;
                }
                let daf = unsafe &*(&*self.pkg).module_ast_const(dmf);
                let fsub = if daf.at_const(fid).kind == NodeKind::NODE_FIELD {
                    fid;
                } else {
                    NODE_NONE; // tuple member: positional `_k`
                };
                let fdata2 = if fsub == NODE_NONE {
                    fr.idx as u32;
                } else {
                    fdata;
                };
                return self.place_project(base, ir::Projection { kind: ir::PJ_FIELD, data: fdata2, sub: fsub, ty: fty });
            }
            // variants .value (single payload) / payloads .value: downcast then the payload member
            let vk = if fr.mode == 1 {
                fr.idx;
            } else {
                fr.vidx;
            };
            let pk = if fr.mode == 1 {
                0 as i64;
            } else {
                fr.idx;
            };
            let mut dmv: ModuleId = 0;
            let vid = self.proj_variant_node(fr.owner_st, vk, &mut dmv);
            let pty = self.proj_payload_ty(fr.owner_st, vk, pk);
            if vid == NODE_NONE || pty == TYPE_NONE {
                self.fail_at("binder-escape", id);
                return ir::IR_NONE;
            }
            let dcast = self.place_project(
                base,
                ir::Projection { kind: ir::PJ_DOWNCAST, data: vk as u32, sub: vid, ty: fr.owner_st },
            );
            let dav = unsafe &*(&*self.pkg).module_ast_const(dmv);
            let pls = dav.at_const(vid).as_data.variant.payload;
            let pe = unsafe dav.list(pls)[pk as usize];
            let psub = if dav.at_const(pe).kind == NodeKind::NODE_FIELD {
                pe;
            } else {
                NODE_NONE;
            };
            return self.place_project(dcast, ir::Projection { kind: ir::PJ_FIELD, data: pk as u32, sub: psub, ty: pty });
        }
        self.fail_at("binder-member", id);
        return ir::IR_NONE;
    }

    // A binder metadata CALL's per-copy value: -1 = not a metadata call; 0 = bool (`out` 0/1),
    // 1 = int (`out`), 2 = string (`out` = the metas index or -1; `out_dm`/`out_node` the decl).
    fn meta_call_val(self: &mut Self, id: NodeId, out: &mut i64, out_dm: &mut ModuleId, out_node: &mut NodeId) i32 {
        if self.f.node(id).kind != NodeKind::NODE_CALL {
            return -1;
        }
        let d = self.f.node(id).as_data.call;
        if self.f.node(d.callee).kind != NodeKind::NODE_MEMBER {
            return -1;
        }
        let cn = *self.f.node(d.callee);
        if cn.as_data.member.path || cn.as_data.member.object == NODE_NONE {
            return -1;
        }
        let mobj = cn.as_data.member.object;
        if self.f.node(mobj).kind != NodeKind::NODE_IDENTIFIER {
            return -1;
        }
        let blid = unsafe (&*self.f.ast).resolution(mobj);
        if blid == NODE_NONE || self.f.node(blid).kind != NodeKind::NODE_INLINE_FOR {
            return -1;
        }
        let fi = self.proj_frame_of(blid);
        if fi < 0 {
            return -1;
        }
        let nsp = self.f.node(cn.as_data.member.member).as_data.name.text;
        let name = self.src.slice(nsp.start as usize, nsp.end as usize);
        let is_has = name == "has_meta";
        let is_b = name == "meta_bool";
        let is_i = name == "meta_int";
        let is_s = name == "meta_str";
        if !is_has && !is_b && !is_i && !is_s {
            return -1;
        }
        if d.args.len != 1 {
            return -1;
        }
        let a0 = unsafe self.f.list(d.args)[0];
        if self.f.node(a0).kind != NodeKind::NODE_LITERAL {
            return -1;
        }
        let ksp = self.f.node(a0).span;
        let key = self.src.slice((ksp.start + 1) as usize, (ksp.end - 1) as usize);
        let fr = *self.proj_frames.at(fi as usize);
        let mut dm: ModuleId = 0;
        let mut node = NODE_NONE;
        if fr.mode == 2 {
            let vid = self.proj_variant_node(fr.owner_st, fr.vidx, &mut dm);
            if vid != NODE_NONE {
                let dap = unsafe &*(&*self.pkg).module_ast_const(dm);
                let pls = dap.at_const(vid).as_data.variant.payload;
                if fr.idx < pls.len as i64 {
                    node = unsafe dap.list(pls)[fr.idx as usize];
                }
            }
        } else if fr.mode == 1 {
            node = self.proj_variant_node(fr.owner_st, fr.idx, &mut dm);
        } else {
            node = self.proj_field_node(fr.owner_st, fr.idx, &mut dm);
        }
        let mut mi: i64 = -1;
        let mut ma = MetaAttr {
            owner: NODE_NONE,
            vkind: 0,
            ival: 0,
            key: tok::Span::empty(),
            vspan: tok::Span::empty(),
        };
        if node != NODE_NONE {
            let da = unsafe &*(&*self.pkg).module_ast_const(dm);
            let dsrc = unsafe (&*self.pkg).modules.at(dm as usize).source.as_str();
            for i in 0..da.metas.len() {
                let m2 = *da.metas.at(i);
                if m2.owner == node && dsrc.slice(m2.key.start as usize, m2.key.end as usize) == key {
                    mi = i as i64;
                    ma = m2;
                    break;
                }
            }
        }
        *out_dm = dm;
        *out_node = node;
        if is_s {
            *out = mi;
            return 2;
        }
        if is_has {
            *out = if mi >= 0 {
                1;
            } else {
                0;
            };
            return 0;
        }
        if is_b {
            *out = if mi >= 0 && ma.vkind == 0 && ma.ival != 0 {
                1;
            } else {
                0;
            };
            return 0;
        }
        *out = if mi >= 0 && ma.vkind == 1 {
            ma.ival;
        } else {
            0;
        };
        return 1;
    }

    // `f.has_meta("k")` / `f.meta_bool` / `f.meta_int` / `f.meta_str`: per-copy constants read
    // from the declaring module's @reflect table. IR_NONE = not a metadata call (caller proceeds).
    fn lower_meta_call(self: &mut Self, id: NodeId, ty: TypeId, sp: tok::Span) ir::OperandId {
        let mut v: i64 = 0;
        let mut dm: ModuleId = 0;
        let mut node = NODE_NONE;
        let k = self.meta_call_val(id, &mut v, &mut dm, &mut node);
        if k < 0 {
            return ir::IR_NONE;
        }
        if k == 2 {
            let mut rsp = tok::Span::empty();
            if v >= 0 {
                let da = unsafe &*(&*self.pkg).module_ast_const(dm);
                let ma = *da.metas.at(v as usize);
                if ma.vkind == 2 {
                    rsp = ma.vspan;
                }
            }
            return self.const_op(
                ir::Constant {
                    kind: ir::CK_STR,
                    ty: ty,
                    val: tt::TokenType::RawStringLiteral as i64,
                    raw: rsp,
                    item: DefId { module: dm, node: node },
                    targ_start: 0,
                    targ_len: 0,
                },
            );
        }
        let cty = if ty != TYPE_NONE {
            ty;
        } else if k == 1 {
            Ast::builtin(BuiltinType::BT_I64);
        } else {
            Ast::builtin(BuiltinType::BT_BOOL);
        };
        return self.const_op(
            ir::Constant {
                kind: ir::CK_INT,
                ty: cty,
                val: v,
                raw: sp,
                item: DefId { module: 0, node: NODE_NONE },
                targ_start: 0,
                targ_len: 0,
            },
        );
    }

    // -1 unknown, else 0/1: binder-const conditions decided for the copy being lowered --
    // metadata predicates, `!c`, comparisons of index/tag/payload/meta_int against foldable
    // integers, and meta_str against a string literal. The untaken branch is never lowered, so
    // its calls are never demanded (the emission contract reflect tests pin).
    fn binder_cond(self: &mut Self, cond: NodeId) i32 {
        let k = self.f.node(cond).kind;
        if k == NodeKind::NODE_CALL {
            let mut mv: i64 = 0;
            let mut mdm: ModuleId = 0;
            let mut mnode = NODE_NONE;
            if self.meta_call_val(cond, &mut mv, &mut mdm, &mut mnode) == 0 {
                return if mv != 0 {
                    1;
                } else {
                    0;
                };
            }
            return -1;
        }
        if k == NodeKind::NODE_UNARY && self.f.node(cond).as_data.unary.op == tt::TokenType::Bang {
            let inner = self.binder_cond(self.f.node(cond).as_data.unary.operand);
            if inner >= 0 {
                return 1 - inner;
            }
            return -1;
        }
        if k != NodeKind::NODE_BINARY {
            return -1;
        }
        let b = self.f.node(cond).as_data.binary;
        {
            let mut mmv: i64 = 0;
            let mut mdm2: ModuleId = 0;
            let mut mn2 = NODE_NONE;
            let mut mside = b.left;
            let mut mk2 = self.meta_call_val(mside, &mut mmv, &mut mdm2, &mut mn2);
            if mk2 < 0 {
                mside = b.right;
                mk2 = self.meta_call_val(mside, &mut mmv, &mut mdm2, &mut mn2);
            }
            if mk2 == 0 || mk2 == 1 {
                let mlit = if mside == b.left {
                    b.right;
                } else {
                    b.left;
                };
                return self.binder_cond_cmp(cond, mmv, mlit, mside == b.left);
            }
            if mk2 == 2 && (b.op == tt::TokenType::EqualEqual || b.op == tt::TokenType::BangEqual) {
                let mlit2 = if mside == b.left {
                    b.right;
                } else {
                    b.left;
                };
                let ln = *self.f.node(mlit2);
                if ln.kind == NodeKind::NODE_LITERAL && ln.as_data.literal.token_type == tt::TokenType::StringLiteral {
                    let want = self.src.slice((ln.span.start + 1) as usize, (ln.span.end - 1) as usize);
                    let mut eqv = false;
                    if mmv >= 0 {
                        let da3 = unsafe &*(&*self.pkg).module_ast_const(mdm2);
                        let ma3 = *da3.metas.at(mmv as usize);
                        if ma3.vkind == 2 {
                            let dsrc3 = unsafe (&*self.pkg).modules.at(mdm2 as usize).source.as_str();
                            eqv = dsrc3.slice(ma3.vspan.start as usize, ma3.vspan.end as usize) == want;
                        }
                    } else {
                        eqv = want.len() == 0; // a missing key reads ""
                    }
                    if b.op == tt::TokenType::BangEqual {
                        eqv = !eqv;
                    }
                    return if eqv {
                        1;
                    } else {
                        0;
                    };
                }
                return -1;
            }
        }
        let mut mem = b.left;
        let mut lit = b.right;
        if self.f.node(mem).kind != NodeKind::NODE_MEMBER {
            mem = b.right;
            lit = b.left;
        }
        if self.f.node(mem).kind != NodeKind::NODE_MEMBER || self.f.node(mem).as_data.member.path {
            return -1;
        }
        let obj = self.f.node(mem).as_data.member.object;
        if self.f.node(obj).kind != NodeKind::NODE_IDENTIFIER {
            return -1;
        }
        let lid = unsafe (&*self.f.ast).resolution(obj);
        if lid == NODE_NONE || self.f.node(lid).kind != NodeKind::NODE_INLINE_FOR {
            return -1;
        }
        let fi = self.proj_frame_of(lid);
        if fi < 0 {
            return -1;
        }
        let fr = *self.proj_frames.at(fi as usize);
        let msp = self.f.node(self.f.node(mem).as_data.member.member).as_data.name.text;
        let mname = self.src.slice(msp.start as usize, msp.end as usize);
        let mut mv: i64 = 0;
        if mname == "index" || fr.mode == 1 && mname == "tag" {
            mv = if fr.mode == 1 && mname == "tag" {
                self.proj_tag_val(fr.owner_st, fr.idx);
            } else {
                fr.idx;
            };
        } else if fr.mode == 1 && mname == "payload" {
            let mut dmx: ModuleId = 0;
            let vid = self.proj_variant_node(fr.owner_st, fr.idx, &mut dmx);
            if vid == NODE_NONE {
                return -1;
            }
            let dax = unsafe &*(&*self.pkg).module_ast_const(dmx);
            mv = dax.at_const(vid).as_data.variant.payload.len;
        } else {
            return -1;
        }
        return self.binder_cond_cmp(cond, mv, lit, mem == b.left);
    }

    // The shared tail of the binder-const `if` fold: the constant side `mv` against the literal
    // side, honoring operand order for the ordered comparisons.
    /// Fold `sizeof(T) <op> <const-int>` (either side) under the active instance env: sizes are
    /// per-instance constants, and the untaken side of a ZST container branch may not even be
    /// spellable C for this instantiation (pointer arithmetic over an incomplete element type).
    /// -1 = not that shape / not foldable.
    fn zst_cond(self: &mut Self, cond: NodeId) i32 {
        let n = *self.f.node(cond);
        if n.kind != NodeKind::NODE_BINARY {
            return -1;
        }
        let bd = n.as_data.binary;
        let lk = self.f.node(bd.left).kind;
        let rk = self.f.node(bd.right).kind;
        let lm = lk == NodeKind::NODE_SIZEOF || lk == NodeKind::NODE_ALIGNOF;
        let rm9 = rk == NodeKind::NODE_SIZEOF || rk == NodeKind::NODE_ALIGNOF;
        if !lm && !rm9 {
            return -1;
        }
        let mn = if lm {
            bd.left;
        } else {
            bd.right;
        };
        let ln = if lm {
            bd.right;
        } else {
            bd.left;
        };
        let measured = self.nty(self.f.node(mn).as_data.single.value);
        if measured == TYPE_NONE {
            return -1;
        }
        // only zero comparisons fold: their outcome is a pure function of the args' ZST bits,
        // which is what lets instantiations share one folded body per bit signature
        {
            if unsafe (&*self.pkg).cir == null {
                return -1;
            }
            let cev0 = unsafe &mut *((&*self.pkg).cir as *mut iri::Interp);
            let cv0 = cev0.eval(self.module, ln);
            if cv0.kind != iri::IV_INT || cv0.i != 0 {
                return -1;
            }
        }
        // one LayoutEnv frame per active binding, innermost first (bindings push outer-to-inner)
        let ne = self.env.len();
        let mut pnodes = Vector::<NodeId>::new();
        let mut frames = Vector::<lay::LayoutEnv>::new();
        pnodes.reserve(ne);
        frames.reserve(ne);
        for i in 0..ne {
            let sb = *self.env.at(ne - 1 - i);
            pnodes.push(sb.pnode);
            // no designated literal in field position: the bootstrap release emitter sizes the
            // field copy by the destination, which over-reads a spelled-short temp
            let mut fr9 = lay::LayoutEnv {
                parent: null,
                pmod: sb.pm,
                params: pnodes.at(i),
                argm: sb.am,
                args: [0; 8],
                n: 1,
            };
            fr9.args[0] = sb.at;
            frames.push(fr9);
        }
        for i in 0..ne {
            if i + 1 < ne {
                let pp9: *const lay::LayoutEnv = frames.at(i + 1);
                frames[i].parent = pp9;
            }
        }
        let head = if ne != 0 {
            frames.at(0) as *const lay::LayoutEnv;
        } else {
            null;
        };
        let mut svc = lay::Svc::new(self.pkg);
        let lo = svc.layout_of(self.module, measured, head, 0);
        svc.free();
        if stdlib::getenv("SC_ZC_DBG") != null {
            eprint("zst-cond: env {} ok {} size {}\n", self.env.len(), lo.ok, lo.size);
        }
        if !lo.ok {
            self.body.has_zst_cond = true; // symbolic here; instances re-lower and fold
            return -1;
        }
        let mk = self.f.node(mn).kind;
        let mv = if mk == NodeKind::NODE_SIZEOF {
            lo.size;
        } else {
            lo.align;
        } as i64;
        let r = self.binder_cond_cmp(cond, mv, ln, lm);
        if r < 0 {
            self.body.has_zst_cond = true;
        }
        return r;
    }

    fn binder_cond_cmp(self: &mut Self, cond: NodeId, mv: i64, lit: NodeId, mem_left: bool) i32 {
        if unsafe (&*self.pkg).cir == null {
            return -1;
        }
        let cev = unsafe &mut *((&*self.pkg).cir as *mut iri::Interp);
        let cv = cev.eval(self.module, lit);
        if cv.kind != iri::IV_INT {
            return -1;
        }
        let lv = cv.i;
        let op = self.f.node(cond).as_data.binary.op;
        let mut r = false;
        if op == tt::TokenType::EqualEqual {
            r = mv == lv;
        } else if op == tt::TokenType::BangEqual {
            r = mv != lv;
        } else if op == tt::TokenType::LessThan {
            r = if mem_left {
                mv < lv;
            } else {
                lv < mv;
            };
        } else if op == tt::TokenType::GreaterThan {
            r = if mem_left {
                mv > lv;
            } else {
                lv > mv;
            };
        } else if op == tt::TokenType::LessThanEqual {
            r = if mem_left {
                mv <= lv;
            } else {
                lv <= mv;
            };
        } else if op == tt::TokenType::GreaterThanEqual {
            r = if mem_left {
                mv >= lv;
            } else {
                lv >= mv;
            };
        } else {
            return -1;
        }
        return if r {
            1;
        } else {
            0;
        };
    }

    // Expand `inline for <bind> in fields/variants/payloads(..)` over the CONCRETE owner: the body
    // lowers once per copy with a frame on the stack. False = owner symbolic (caller falls back).
    fn expand_binder(self: &mut Self, id: NodeId) bool {
        let d = self.f.node(id).as_data.for_stmt;
        let pt = self.nty(id);
        if pt == TYPE_NONE || self.f.ty(pt).kind != TypeKind::TYPE_FIELD_PROJECTION {
            if stdlib::getenv("SC_PROJ_DBG") != null {
                eprintln("proj: no-proj-type node {} pt {}", id, pt);
            }
            return false;
        }
        let cd = self.f.node(d.iterable).as_data.call;
        let csp = self.f.node(cd.callee).as_data.name.text;
        let cname = self.src.slice(csp.start as usize, csp.end as usize);
        let mut mode: u8 = 0;
        if cname == "variants" {
            mode = 1;
        } else if cname == "payloads" {
            mode = 2;
        }
        let mut orm = self.module;
        let mut ort = self.f.ty(pt).as_data.proj.owner;
        if !self.env_resolve(self.f.ty(pt).as_data.proj.owner, &mut orm, &mut ort) {
            if stdlib::getenv("SC_PROJ_DBG") != null {
                eprintln("proj: owner-unresolved node {} env {}", id, self.env.len());
            }
            return false;
        }
        let owner = self.reintern_ty(orm, ort);
        let mut dm0: ModuleId = 0;
        if self.proj_owner_decl(owner, &mut dm0) == NODE_NONE {
            if stdlib::getenv("SC_PROJ_DBG") != null {
                eprintln("proj: owner-not-agg node {} kind {}", id, self.f.ty(owner).kind as u32);
            }
            return false;
        }
        let mut sub0 = ir::IR_NONE;
        let mut sub1 = ir::IR_NONE;
        let sp = self.f.node(id).span;
        if mode == 2 {
            // payloads(v): shares the OUTER variants binder's subjects and current variant
            let pav = unsafe self.f.list(cd.args)[0];
            let outer = unsafe (&*self.f.ast).resolution(pav);
            let ofi = self.proj_frame_of(outer);
            if ofi < 0 {
                return false;
            }
            sub0 = self.proj_frames.at(ofi as usize).sub0;
            sub1 = self.proj_frames.at(ofi as usize).sub1;
            let vk = self.proj_frames.at(ofi as usize).idx;
            let mut dmv: ModuleId = 0;
            let vid = self.proj_variant_node(owner, vk, &mut dmv);
            if vid == NODE_NONE {
                return false;
            }
            let dav = unsafe &*(&*self.pkg).module_ast_const(dmv);
            let np = dav.at_const(vid).as_data.variant.payload.len;
            let mut k: i64 = 0;
            while k < np as i64 {
                self.proj_frames.push(
                    ProjFrame { binder: id, idx: k, vidx: vk, mode: 2, sub0: sub0, sub1: sub1, owner_st: owner },
                );
                // first copy = the replay's canonical iteration; later copies mute their events
                let muted9 = k != 0;
                if muted9 {
                    self.tape_mute += 1;
                } else {
                    self.tp(ir::TP_BODY_START, 1, id);
                }
                self.lower_stmt(d.body);
                if muted9 {
                    self.tape_mute -= 1;
                } else {
                    self.tp(ir::TP_BODY_END, 0, id);
                }
                let _ = self.proj_frames.pop();
                if self.err.len() != 0 {
                    return true; // consumed (error recorded)
                }
                k += 1;
            }
            return true;
        }
        for i in 0..cd.args.len {
            let a = unsafe self.f.list(cd.args)[i as usize];
            let op = self.lower_expr(a);
            if op == ir::IR_NONE {
                return true; // consumed (error recorded)
            }
            let pl = self.spill(op, sp);
            if i == 0 {
                sub0 = pl;
            } else {
                sub1 = pl;
            }
        }
        let mut k: i64 = 0;
        loop {
            let mut dmk: ModuleId = 0;
            let nk = if mode == 1 {
                self.proj_variant_node(owner, k, &mut dmk);
            } else {
                self.proj_field_node(owner, k, &mut dmk);
            };
            if nk == NODE_NONE {
                break;
            }
            self.proj_frames.push(
                ProjFrame { binder: id, idx: k, vidx: 0, mode: mode, sub0: sub0, sub1: sub1, owner_st: owner },
            );
            // first copy = the replay's canonical iteration; later copies mute their events
            let muted9 = k != 0;
            if muted9 {
                self.tape_mute += 1;
            } else {
                self.tp(ir::TP_BODY_START, 1, id);
            }
            self.lower_stmt(d.body);
            if muted9 {
                self.tape_mute -= 1;
            } else {
                self.tp(ir::TP_BODY_END, 0, id);
            }
            let _ = self.proj_frames.pop();
            if self.err.len() != 0 {
                return true;
            }
            k += 1;
        }
        return true;
    }

    // The compile-time value of an inline-for range bound. Raw const evaluation handles literals and
    // ordinary consts; a const-generic parameter (`0..N`) is symbolic there until an instance binds
    // it, so this resolves the referenced parameter through the instance env to its TYPE_CONST value.
    // Returns whether `out` was set.
    fn eval_bound(self: &mut Self, node: NodeId, out: &mut i64) bool {
        if node == NODE_NONE {
            return false;
        }
        let cev = unsafe &mut *((&*self.pkg).cir as *mut iri::Interp);
        let cv = cev.eval(self.module, node);
        if cv.kind == iri::IV_INT {
            *out = cv.i;
            return true;
        }
        let d = self.f.res(node);
        if d.node != NODE_NONE {
            let mut i = self.env.len();
            while i > 0 {
                i -= 1;
                let sb = *self.env.at(i);
                if sb.pm == d.module && sb.pnode == d.node {
                    let y = *unsafe (&*(&*self.pkg).module_ast_const(sb.am)).type_at(sb.at);
                    if y.kind == TypeKind::TYPE_CONST {
                        *out = y.as_data.value;
                        return true;
                    }
                    return false;
                }
            }
        }
        return self.fold_reflect_bound(node, out);
    }

    // Whether identifier node `id` spells `name`.
    const fn node_name_eq(self: &Self, id: NodeId, name: str) bool {
        let sp = self.f.node(id).as_data.name.text;
        if sp.end <= sp.start {
            return false;
        }
        return self.src.slice(sp.start as usize, sp.end as usize) == name;
    }

    // Fold a `type_info::<T>().fields.len` bound to its field count. At an instance the type argument
    // resolves through the env to a concrete aggregate, so the field count is a compile-time constant
    // that unrolls the inline-for without materializing the runtime TypeInfo record.
    fn fold_reflect_bound(self: &mut Self, node: NodeId, out: &mut i64) bool {
        let n = *self.f.node(node);
        if n.kind != NodeKind::NODE_MEMBER {
            return false;
        }
        let md = n.as_data.member;
        if !self.node_name_eq(md.member, "len") {
            return false;
        }
        let objn = *self.f.node(md.object);
        if objn.kind != NodeKind::NODE_MEMBER {
            return false;
        }
        let md2 = objn.as_data.member;
        let is_fields = self.node_name_eq(md2.member, "fields");
        if !is_fields && !self.node_name_eq(md2.member, "variants") {
            return false;
        }
        let call = *self.f.node(md2.object);
        if call.kind != NodeKind::NODE_CALL {
            return false;
        }
        if !self.is_intrinsic_callee(call.as_data.call.callee, "type_info") {
            return false;
        }
        let mu = self.f.type_args(md2.object);
        if mu == null || unsafe mu.n == 0 {
            return false;
        }
        let mut tm = self.module;
        let mut tt = unsafe mu.args[0];
        if !self.env_resolve(tt, &mut tm, &mut tt) {
            return false;
        }
        let y = *unsafe (&*(&*self.pkg).module_ast_const(tm)).type_at(tt);
        let mut dm = tm;
        let mut dn = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            dm = y.module;
            dn = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (&*(&*self.pkg).module_ast_const(tm)).instance(y.as_data.inst);
            dm = it.module;
            dn = it.decl;
        }
        if dn == NODE_NONE {
            return false;
        }
        let cev = unsafe &mut *((&*self.pkg).cir as *mut iri::Interp);
        *out = if is_fields {
            cev.field_count_of(dm, dn);
        } else {
            cev.variant_count_of(dm, dn);
        };
        return true;
    }

    // `for` over a range literal lowers to an index loop. `inline for` over `fields`/`variants`/
    // `payloads` binders: the CONCRETE-owner path expands per copy (expand_binder); a symbolic
    // owner keeps the IN_REFLECT placeholder and flags the body for per-instance re-lowering.
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
                // binder/reflect expansion lowers the body per iteration; the replay sees ONE loop:
                // the first copy's events are the canonical iteration, later copies are muted
                self.tp(ir::TP_LOOP_PUSH, 1, id);
                self.tp(ir::TP_MARK_PUSH, 0, id);
                if self.expand_binder(id) {
                    self.tp(ir::TP_MARK_POP, 0, id);
                    self.tp(ir::TP_LOOP_POP, 0, id);
                    return;
                }
                self.body.has_reflect = true;
                let ity = self.nty(id);
                let mut argv = self.avget();
                for i in 0..cd.args.len {
                    let a = unsafe self.f.list(cd.args)[i as usize];
                    let op = self.lower_expr(a);
                    if op == ir::IR_NONE {
                        return;
                    }
                    argv.push(op);
                }
                let fresh = self.pool_ops(&argv);
                let kept = argv.len() as u32;
                self.avput(argv);
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
                self.user_local_live(l, sp);
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
                self.tp(ir::TP_BODY_START, 1, id);
                self.lower_stmt(d.body);
                self.tp(ir::TP_BODY_END, 0, id);
                self.tp(ir::TP_MARK_POP, 0, id);
                self.tp(ir::TP_LOOP_POP, 0, id);
                return;
            }
        }
        if self.f.node(d.iterable).kind != NodeKind::NODE_RANGE {
            // iterator protocol: the checker recorded the selected `next` and its Option return
            switch self.f.call_info(id) {
                Some(ci) => {
                    self.tp(ir::TP_LOOP_PUSH, 1, id);
                    self.tp(ir::TP_MARK_PUSH, 0, id);
                    self.lower_for_iter(id, DefId { module: ci_module(ci), node: ci_decl(ci) });
                    self.tp(ir::TP_MARK_POP, 0, id);
                    self.tp(ir::TP_LOOP_POP, 0, id);
                    return;
                },
                None => {},
            };
            let ity = self.nty(d.iterable);
            let ik = self.f.ty(ity).kind;
            if ik == TypeKind::TYPE_INSTANCE && self.is_range_instance(ity) {
                self.tp(ir::TP_LOOP_PUSH, 1, id);
                self.tp(ir::TP_MARK_PUSH, 0, id);
                self.lower_for_range_value(id);
                self.tp(ir::TP_MARK_POP, 0, id);
                self.tp(ir::TP_LOOP_POP, 0, id);
                return;
            }
            if ik == TypeKind::TYPE_ARRAY || ik == TypeKind::TYPE_SLICE || ik == TypeKind::TYPE_INSTANCE {
                self.tp(ir::TP_LOOP_PUSH, 1, id);
                self.tp(ir::TP_MARK_PUSH, 0, id);
                self.lower_for_indexed(id);
                self.tp(ir::TP_MARK_POP, 0, id);
                self.tp(ir::TP_LOOP_POP, 0, id);
                return;
            }
            self.fail_at("for-iterable", id);
            return;
        }
        let rd = self.f.node(d.iterable).as_data.pattern_range;
        let ity = self.nty(id);
        if self.f.node(id).kind == NodeKind::NODE_INLINE_FOR && unsafe (&*self.pkg).cir != null {
            // Physical unroll: inline-for bounds are compile-time constants. A const-generic bound
            // (`0..N`) is symbolic during the generic pre-pass and resolves only once an instance
            // binds N, so eval_bound consults the instance env; an open start counts from zero. When a
            // bound stays symbolic here the body is flagged for per-instance re-lowering (the emitter
            // re-lowers has_reflect bodies with the demand env, where this then unrolls).
            let mut lo: i64 = 0;
            let mut hi: i64 = 0;
            let lok = rd.start == NODE_NONE || self.eval_bound(rd.start, &mut lo);
            let hok = self.eval_bound(rd.end, &mut hi);
            if !(lok && hok) {
                self.body.has_reflect = true;
            }
            if lok && hok {
                // physical unroll: the body lowers once per iteration; the replay sees ONE loop
                // whose canonical iteration is the first copy (later copies mute their events)
                self.tp(ir::TP_LOOP_PUSH, 1, id);
                self.tp(ir::TP_MARK_PUSH, 0, id);
                if rd.inclusive {
                    hi += 1;
                }
                let mut v = lo;
                while v < hi {
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
                    self.user_local_live(l, sp);
                    let cvo = self.const_op(
                        ir::Constant {
                            kind: ir::CK_INT,
                            ty: ity,
                            val: v,
                            raw: sp,
                            item: DefId { module: 0, node: NODE_NONE },
                            targ_start: 0,
                            targ_len: 0,
                        },
                    );
                    let rvc = self.rv_use(cvo, ity);
                    self.assign(self.place_of_local(l), rvc, sp);
                    let muted9 = v != lo;
                    if muted9 {
                        self.tape_mute += 1;
                    } else {
                        self.tp(ir::TP_BODY_START, 1, id);
                    }
                    self.lower_stmt(d.body);
                    if muted9 {
                        self.tape_mute -= 1;
                    } else {
                        self.tp(ir::TP_BODY_END, 0, id);
                    }
                    if self.err.len() != 0 {
                        return;
                    }
                    v += 1;
                }
                self.tp(ir::TP_MARK_POP, 0, id);
                self.tp(ir::TP_LOOP_POP, 0, id);
                return;
            }
        }
        // `..e` counts from zero; `s..` has no bound check (exit only via break)
        self.tp(ir::TP_LOOP_PUSH, 1, id);
        self.tp(ir::TP_MARK_PUSH, 0, id);
        let sop: ir::OperandId = if rd.start != NODE_NONE {
            self.lower_expr(rd.start);
        } else {
            self.const_op(
                ir::Constant {
                    kind: ir::CK_INT,
                    ty: ity,
                    val: 0,
                    raw: sp,
                    item: DefId { module: 0, node: NODE_NONE },
                    targ_start: 0,
                    targ_len: 0,
                },
            );
        };
        if sop == ir::IR_NONE {
            return;
        }
        let mut epl = ir::IR_NONE;
        let mut ecst = ir::IR_NONE;
        if rd.end != NODE_NONE {
            let eop = self.lower_expr(rd.end);
            if eop == ir::IR_NONE {
                return;
            }
            let eo = *self.body.operands.at(eop as usize);
            if eo.kind == ir::OP_CONST {
                ecst = eo.data;
            } else {
                epl = self.spill(eop, sp);
            }
        }
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
        self.user_local_live(l, sp);
        let ipl = self.place_of_local(l);
        let rv0 = self.rv_use(sop, ity);
        self.assign(ipl, rv0, sp);
        let head = self.open_block();
        let body_b = self.open_block();
        let step = self.open_block();
        let exit = self.open_block();
        self.seal(self.goto_term(head, sp), head);
        if rd.end == NODE_NONE {
            self.seal(self.goto_term(body_b, sp), body_b);
        } else {
            let iop = self.copy_op(ipl);
            let eop2: ir::OperandId = if ecst != ir::IR_NONE {
                let c2 = *self.body.constants.at(ecst as usize);
                self.const_op(c2);
            } else {
                self.copy_op(epl);
            };
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
        }
        self.loops.push(
            LoopCtx {
                label: d.label,
                brk: exit,
                cont: step,
                defer_depth: self.defers.len(),
                locals_depth: self.scope_locals.len(),
                result: ir::IR_NONE,
            },
        );
        self.loop_safepoint(sp);
        self.tp(ir::TP_BODY_START, 0, id);
        self.lower_stmt(d.body);
        self.tp(ir::TP_BODY_END, 0, id);
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
        self.tp(ir::TP_MARK_POP, 0, id);
        self.tp(ir::TP_LOOP_POP, 0, id);
    }

    // `for` over an indexable sequence (array, slice, sequence value): an index loop over RV_LEN
    // with an explicit element load per iteration -- the uniform sequence model until
    // instance-aware lowering specializes it per concrete carrier.
    // Is `t` an instance of the prelude Range struct?
    fn is_range_instance(self: &Self, t: TypeId) bool {
        let y = *self.f.ty(t);
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = *self.f.instance(y.as_data.inst);
        let hit = unsafe (&*self.pkg).prelude_lookup("Range", true);
        return hit.node != NODE_NONE && it.module == hit.mid && it.decl == hit.node;
    }

    // The declared field ordinal + decl of `name` on struct `sd`; -1 when absent.
    fn field_of(self: &Self, sd: DefId, name: str, decl: &mut NodeId) i64 {
        let a = unsafe &*(&*self.pkg).module_ast_const(sd.module);
        let src = unsafe (&*self.pkg).modules.at(sd.module as usize).source.as_str();
        let ms = a.at_const(sd.node).as_data.aggregate.members;
        for i in 0..ms.len {
            let fid = unsafe a.list(ms)[i as usize];
            if a.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            let sp = a.at_const(a.at_const(fid).as_data.field.name).as_data.name.text;
            if src.slice(sp.start as usize, sp.end as usize) == name {
                *decl = fid;
                return i;
            }
        }
        return -1;
    }

    // `for x in r` over a prelude Range VALUE: x from r.start while (r.inclusive ? x <= r.end
    // : x < r.end), stepping by one -- the emitter's established range-value semantics.
    fn lower_for_range_value(self: &mut Self, id: NodeId) {
        let d = self.f.node(id).as_data.for_stmt;
        let sp = self.f.node(id).span;
        let rpl = self.lower_place(d.iterable);
        if rpl == ir::IR_NONE {
            return;
        }
        let rty = self.body.places.at(rpl as usize).ty;
        let it = *self.f.instance(self.f.ty(rty).as_data.inst);
        let sd = DefId { module: it.module, node: it.decl };
        let elem = self.nty(id);
        let bt = Ast::builtin(BuiltinType::BT_BOOL);
        let mut f_start = NODE_NONE;
        let mut f_end = NODE_NONE;
        let mut f_inc = NODE_NONE;
        let o_start = self.field_of(sd, "start", &mut f_start);
        let o_end = self.field_of(sd, "end", &mut f_end);
        let o_inc = self.field_of(sd, "inclusive", &mut f_inc);
        if o_start < 0 || o_end < 0 || o_inc < 0 {
            self.fail_at("range-fields", id);
            return;
        }
        let l = self.body.add_local(
            ir::LocalDecl {
                ty: elem,
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
        self.user_local_live(l, sp);
        let xpl = self.place_of_local(l);
        let spl = self.place_project(
            rpl,
            ir::Projection { kind: ir::PJ_FIELD, data: o_start as u32, sub: f_start, ty: elem },
        );
        let sop = self.copy_op(spl);
        let rv0 = self.rv_use(sop, elem);
        self.assign(xpl, rv0, sp);
        let head = self.open_block();
        let body_b = self.open_block();
        let step = self.open_block();
        let exit = self.open_block();
        self.seal(self.goto_term(head, sp), head);
        // cond = (inclusive && x <= end) || (!inclusive && x < end)
        let epl = self.place_project(
            rpl,
            ir::Projection { kind: ir::PJ_FIELD, data: o_end as u32, sub: f_end, ty: elem },
        );
        let ipl = self.place_project(rpl, ir::Projection { kind: ir::PJ_FIELD, data: o_inc as u32, sub: f_inc, ty: bt });
        let le_op = self.lower_cmp2(xpl, epl, tt::TokenType::LessThanEqual, sp);
        let lt_op = self.lower_cmp2(xpl, epl, tt::TokenType::LessThan, sp);
        let inc_op = self.copy_op(ipl);
        let ninc = self.temp(bt, sp);
        let npl = self.place_of_local(ninc);
        self.assign(
            npl,
            ir::Rvalue {
                kind: ir::RV_UNARY,
                a: inc_op,
                b: tt::TokenType::Bang as u32,
                c: 0,
                target: bt,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        let inc_op2 = self.copy_op(ipl);
        let a1 = self.bool_and(inc_op2, le_op, sp);
        let nop = self.copy_op(npl);
        let a2 = self.bool_and(nop, lt_op, sp);
        let cond = self.bool_or(a1, a2, sp);
        self.branch_bool(cond, body_b, exit, sp);
        self.loops.push(
            LoopCtx {
                label: d.label,
                brk: exit,
                cont: step,
                defer_depth: self.defers.len(),
                locals_depth: self.scope_locals.len(),
                result: ir::IR_NONE,
            },
        );
        self.loop_safepoint(sp);
        self.tp(ir::TP_BODY_START, 0, id);
        self.lower_stmt(d.body);
        self.tp(ir::TP_BODY_END, 0, id);
        let _ = self.loops.pop();
        self.seal(self.goto_term(step, sp), step);
        let xop = self.copy_op(xpl);
        let one = self.const_op(
            ir::Constant {
                kind: ir::CK_INT,
                ty: elem,
                val: 1,
                raw: sp,
                item: DefId { module: 0, node: NODE_NONE },
                targ_start: 0,
                targ_len: 0,
            },
        );
        self.assign(
            xpl,
            ir::Rvalue {
                kind: ir::RV_BINARY,
                a: xop,
                b: one,
                c: tt::TokenType::Plus as u8,
                target: elem,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        self.seal(self.goto_term(head, sp), exit);
    }

    fn lower_cmp2(self: &mut Self, l: ir::PlaceId, r: ir::PlaceId, rel: tt::TokenType, sp: tok::Span) ir::OperandId {
        let rop = self.copy_op(r);
        return self.cmp_test(l, rop, rel, sp);
    }

    fn bool_and(self: &mut Self, a: ir::OperandId, b: ir::OperandId, sp: tok::Span) ir::OperandId {
        return self.bool_bin(a, b, tt::TokenType::AmpersandAmpersand, sp);
    }

    fn bool_or(self: &mut Self, a: ir::OperandId, b: ir::OperandId, sp: tok::Span) ir::OperandId {
        return self.bool_bin(a, b, tt::TokenType::PipePipe, sp);
    }

    fn bool_bin(self: &mut Self, a: ir::OperandId, b: ir::OperandId, op: tt::TokenType, sp: tok::Span) ir::OperandId {
        let bt = Ast::builtin(BuiltinType::BT_BOOL);
        let t = self.temp(bt, sp);
        let pl = self.place_of_local(t);
        self.assign(
            pl,
            ir::Rvalue {
                kind: ir::RV_BINARY,
                a: a,
                b: b,
                c: op as u8,
                target: bt,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        return self.copy_op(pl);
    }

    // `for x in it` over an Iterator: the checker-selected `next` runs per iteration; the loop
    // continues while it yields the payload variant. This is the real protocol -- one call
    // terminator, one discriminant read, one downcast per iteration.
    fn lower_for_iter(self: &mut Self, id: NodeId, next_def: DefId) {
        let d = self.f.node(id).as_data.for_stmt;
        let sp = self.f.node(id).span;
        let it_pl = self.lower_place(d.iterable);
        if it_pl == ir::IR_NONE {
            return;
        }
        let mu = self.f.generic_args(id);
        if mu == null || unsafe mu.n == 0 {
            self.fail_at("iter-opt-type", id);
            return;
        }
        let opt_ty = unsafe mu.args[0];
        let elem = self.nty(id);
        let mut ok_ord: i64 = -1;
        let mut vd = DefId { module: 0, node: NODE_NONE };
        self.carrier_ok_variant(opt_ty, &mut ok_ord, &mut vd);
        if ok_ord < 0 {
            self.fail_at("iter-carrier", id);
            return;
        }
        let l = self.body.add_local(
            ir::LocalDecl {
                ty: elem,
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
        self.user_local_live(l, sp);
        let t = self.temp(opt_ty, sp);
        let tpl = self.place_of_local(t);
        let head = self.open_block();
        let body_b = self.open_block();
        let exit = self.open_block();
        self.seal(self.goto_term(head, sp), head);
        // t = it.next()
        let recv = self.copy_op(it_pl);
        let start = self.body.oper_pool.len() as u32;
        self.body.oper_pool.push(recv);
        let dstart = self.body.dest_pool.len() as u32;
        self.body.dest_pool.push(tpl);
        let mut tm = self.term0(ir::TM_CALL, sp);
        tm.callee = next_def;
        tm.a = ir::IR_NONE;
        tm.args_start = start;
        tm.args_len = 1;
        tm.dests_start = dstart;
        tm.dests_len = 1;
        let cont = self.open_block();
        tm.t0 = cont;
        self.seal(tm, cont);
        let ut = Ast::builtin(BuiltinType::BT_U32);
        let dt = self.temp(ut, sp);
        let dp = self.place_of_local(dt);
        self.assign(
            dp,
            ir::Rvalue {
                kind: ir::RV_DISCRIMINANT,
                a: tpl,
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
        self.branch_bool(cond, body_b, exit, sp);
        // x = downcast(t, Some).f0
        let ppl = self.place_project(
            tpl,
            ir::Projection { kind: ir::PJ_DOWNCAST, data: ok_ord as u32, sub: vd.node, ty: opt_ty },
        );
        let fpl = self.place_project(ppl, ir::Projection { kind: ir::PJ_FIELD, data: 0, sub: NODE_NONE, ty: elem });
        let eop = self.copy_op(fpl);
        let xpl = self.place_of_local(l);
        let erv = self.rv_use(eop, elem);
        self.assign(xpl, erv, sp);
        self.loops.push(
            LoopCtx {
                label: d.label,
                brk: exit,
                cont: head,
                defer_depth: self.defers.len(),
                locals_depth: self.scope_locals.len(),
                result: ir::IR_NONE,
            },
        );
        self.loop_safepoint(sp);
        self.tp(ir::TP_BODY_START, 0, id);
        self.lower_stmt(d.body);
        self.tp(ir::TP_BODY_END, 0, id);
        let _ = self.loops.pop();
        self.seal(self.goto_term(head, sp), exit);
    }

    fn lower_for_indexed(self: &mut Self, id: NodeId) {
        let d = self.f.node(id).as_data.for_stmt;
        let sp = self.f.node(id).span;
        let ipl = self.lower_place(d.iterable);
        if ipl == ir::IR_NONE {
            return;
        }
        let elem_ty = self.nty(id);
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
        self.user_local_live(el, sp);
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
        let mut iop_e = iop2;
        if self.checked_view(self.peeled_view_ty(ipl)) {
            // normalized element check against the cached loop length; BCE proves it from the
            // loop guard (index < length) and marks it PROVEN
            let lop_e = self.copy_op(lpl);
            let ck_e = self.bounds_check_len(iop2, lop_e, sp);
            iop_e = self.copy_op(ck_e);
        }
        let epl = self.place_project(ipl, ir::Projection { kind: ir::PJ_INDEX_OP, data: iop_e, sub: 0, ty: elem_ty });
        let eop = self.copy_op(epl);
        let erv = self.rv_use(eop, elem_ty);
        let bind_pl = self.place_of_local(el);
        self.assign(bind_pl, erv, sp);
        self.loops.push(
            LoopCtx {
                label: d.label,
                brk: exit,
                cont: step,
                defer_depth: self.defers.len(),
                locals_depth: self.scope_locals.len(),
                result: ir::IR_NONE,
            },
        );
        self.loop_safepoint(sp);
        self.tp(ir::TP_BODY_START, 0, id);
        self.lower_stmt(d.body);
        self.tp(ir::TP_BODY_END, 0, id);
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

    // ---- expressions ------------------------------------------------------------------------------

    // Lower expression `id` and return its operand, or IR_NONE on failure. Adjustments (coercion,
    // dyn erasure) recorded at the node wrap the base operand here, so consumers never re-read the
    // side tables.
    fn lower_expr(self: &mut Self, id: NodeId) ir::OperandId {
        if id == NODE_NONE || self.err.len() != 0 {
            return ir::IR_NONE;
        }
        // `&place` coerced to a raw pointer is an address, not a borrow that decays: emit RV_ADDR
        // under the coerced type so no loan outlives the borrow expression.
        {
            let mut aop = NODE_NONE;
            let mut pty = TYPE_NONE;
            let n = self.f.node(id);
            if n.kind == NodeKind::NODE_UNARY && n.as_data.unary.op == tt::TokenType::Ampersand {
                let co = self.f.coercion(id);
                if co != null && unsafe co.method.node == NODE_NONE {
                    let target = unsafe co.target;
                    if target != TYPE_NONE && self.f.ty(target).kind == TypeKind::TYPE_POINTER {
                        aop = n.as_data.unary.operand;
                        pty = target;
                    }
                }
            }
            if aop != NODE_NONE {
                let sp = self.f.node(id).span;
                let apl = self.lower_place(aop);
                if apl == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                let rt = self.nty(id);
                let mut mu: u32 = 0;
                if rt != TYPE_NONE && self.f.ty(rt).kind == TypeKind::TYPE_REFERENCE && self.f.ty(rt).qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                    mu = 1;
                }
                let t2 = self.temp(pty, sp);
                let pl2 = self.place_of_local(t2);
                self.assign(
                    pl2,
                    ir::Rvalue {
                        kind: ir::RV_ADDR,
                        a: apl,
                        b: mu,
                        c: 0,
                        target: pty,
                        item: DefId { module: 0, node: NODE_NONE },
                    },
                    sp,
                );
                return self.copy_op(pl2);
            }
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
        // A deref coercion recorded on a non-place expression (a `&W` value meeting a `&Target`
        // parameter): members and `*x` consume their chains in place lowering; every other node
        // applies the recorded hops to the lowered reference here, or the C would cast `W*` to
        // `Target*` and read the wrong storage.
        {
            let nk = self.f.node(id).kind;
            let star = nk == NodeKind::NODE_UNARY && self.f.node(id).as_data.unary.op == tt::TokenType::Star;
            if nk != NodeKind::NODE_MEMBER && !star {
                let du = self.f.derefs(id);
                if du != null {
                    let steps = unsafe du.n;
                    for s in 0..steps {
                        let m = unsafe du.method[s as usize];
                        if m.node == NODE_NONE {
                            continue; // a raw pointer/reference hop changes no representation
                        }
                        let rt = unsafe du.recv[s as usize];
                        let mut rt2 = self.deref_ret_ty(m, rt);
                        if rt2 == TYPE_NONE {
                            rt2 = rt;
                        }
                        let start = self.body.oper_pool.len() as u32;
                        self.body.oper_pool.push(op);
                        let res = self.emit_call(m, ir::IR_NONE, start, 1, 0, 0, rt2, sp);
                        if res == ir::IR_NONE {
                            return ir::IR_NONE;
                        }
                        op = res;
                    }
                }
            }
        }
        let co = self.f.coercion(id);
        if co != null && self.f.wide_lit(id) != null {
            // a wide literal already CARRIES the target-width limbs: the widening `from` shim
            // would truncate through its scalar parameter, so the constant retypes instead
            let target = unsafe co.target;
            let wi = unsafe (&*(&*self.pkg).module_ast_const(self.body.module)).wide_lit_of(id);
            return self.const_op(
                ir::Constant {
                    kind: ir::CK_WIDE,
                    ty: target,
                    val: wi,
                    raw: sp,
                    item: DefId { module: 0, node: NODE_NONE },
                    targ_start: 0,
                    targ_len: 0,
                },
            );
        }
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
        let ty = self.nty(id);
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
            // `unsafe`/`move` are transparent over places: keep the operand's PLACE-ness (a
            // `&mut` receiver must mutate the real location, not a value temp)
            let uop0 = self.f.node(id).as_data.unary.op;
            if uop0 == tt::TokenType::Unsafe || uop0 == tt::TokenType::Move {
                if uop0 == tt::TokenType::Unsafe {
                    self.note_unsafe(id);
                }
                let mut inner0 = self.f.node(id).as_data.unary.operand;
                loop {
                    let inn = self.f.node(inner0);
                    if inn.kind == NodeKind::NODE_UNARY && (inn.as_data.unary.op == tt::TokenType::Unsafe || inn.as_data.unary.op == tt::TokenType::Move) {
                        if inn.as_data.unary.op == tt::TokenType::Unsafe {
                            self.note_unsafe(inner0);
                        }
                        inner0 = inn.as_data.unary.operand;
                        continue;
                    }
                    break;
                }
                let ik = self.f.node(inner0).kind;
                if ik == NodeKind::NODE_IDENTIFIER || ik == NodeKind::NODE_MEMBER || ik == NodeKind::NODE_INDEX {
                    let pl = self.lower_place(id);
                    if pl == ir::IR_NONE {
                        return ir::IR_NONE;
                    }
                    return self.copy_op(pl);
                }
            }
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
            // the walk erases the borrow on any ref -> ptr cast
            let er9 = ty != TYPE_NONE && self.f.ty(ty).kind == TypeKind::TYPE_POINTER && self.nty(d.expression) != TYPE_NONE && self.f.ty(
                self.nty(d.expression),
            ).kind == TypeKind::TYPE_REFERENCE;
            // `&place as *T` is a raw address, not a borrow that then decays: lower it as RV_ADDR
            // so no loan pins the place through the pointer's lifetime.
            if ty != TYPE_NONE && self.f.ty(ty).kind == TypeKind::TYPE_POINTER {
                let mut e = d.expression;
                loop {
                    let en = self.f.node(e);
                    if en.kind == NodeKind::NODE_UNARY && (en.as_data.unary.op == tt::TokenType::Move || en.as_data.unary.op == tt::TokenType::Unsafe) {
                        if en.as_data.unary.op == tt::TokenType::Unsafe {
                            self.note_unsafe(e);
                        }
                        e = en.as_data.unary.operand;
                    } else {
                        break;
                    }
                }
                let mut aop = NODE_NONE;
                {
                    let en = self.f.node(e);
                    if en.kind == NodeKind::NODE_UNARY && en.as_data.unary.op == tt::TokenType::Ampersand && self.f.coercion(
                        e,
                    ) == null {
                        aop = en.as_data.unary.operand;
                    }
                }
                if aop != NODE_NONE {
                    let apl = self.lower_place(aop);
                    if apl != ir::IR_NONE {
                        let rt = self.nty(e);
                        let mut mu: u32 = 0;
                        if rt != TYPE_NONE && self.f.ty(rt).kind == TypeKind::TYPE_REFERENCE && self.f.ty(rt).qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                            mu = 1;
                        }
                        let t2 = self.temp(ty, sp);
                        let pl2 = self.place_of_local(t2);
                        self.assign(
                            pl2,
                            ir::Rvalue {
                                kind: ir::RV_ADDR,
                                a: apl,
                                b: mu,
                                c: 0,
                                target: ty,
                                item: DefId { module: 0, node: NODE_NONE },
                            },
                            sp,
                        );
                        if er9 {
                            self.tp(ir::TP_CAST_ERASE, 0, d.expression);
                        }
                        return self.copy_op(pl2);
                    }
                }
            }
            let op = self.lower_expr(d.expression);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            // an UNTYPED cast (a const initializer demanded before its module typechecks) still
            // names its builtin in the syntax: resolve it so `E::COUNT as usize` folds
            let mut cty = ty;
            if cty == TYPE_NONE && d.ty != NODE_NONE {
                let tk9 = self.f.node(d.ty).kind;
                if tk9 == NodeKind::NODE_TYPE_PATH || tk9 == NodeKind::NODE_IDENTIFIER {
                    let rd9 = self.f.res(d.ty);
                    let mut bb9: i32 = -1;
                    if rd9.node != NODE_NONE {
                        bb9 = unsafe (&*self.pkg).builtin_of_decl(rd9.module, rd9.node);
                    } else if tk9 == NodeKind::NODE_IDENTIFIER {
                        bb9 = bt_of_name(self.src, self.f.node(d.ty).as_data.name.text);
                    } else {
                        let parts9 = self.f.node(d.ty).as_data.type_path.parts;
                        if parts9.len == 1 {
                            bb9 = bt_of_name(self.src, self.f.node(unsafe self.f.list(parts9)[0]).as_data.name.text);
                        }
                    }
                    if bb9 >= 0 {
                        cty = Ast::builtin((bb9 as u8) as BuiltinType);
                    }
                }
            }
            let t = self.temp(cty, sp);
            let pl = self.place_of_local(t);
            self.assign(
                pl,
                ir::Rvalue {
                    kind: ir::RV_CAST,
                    a: op,
                    b: ir::CAST_NUMERIC,
                    c: 0,
                    target: cty,
                    item: DefId { module: 0, node: NODE_NONE },
                },
                sp,
            );
            if er9 {
                self.tp(ir::TP_CAST_ERASE, 0, d.expression);
            }
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
            let measured = self.nty(self.f.node(id).as_data.single.value);
            self.assign(
                pl,
                ir::Rvalue {
                    kind: ir::RV_INTRINSIC,
                    a: self.body.oper_pool.len() as u32,
                    b: measured,
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
            let mut start = 0 as u32;
            let mut n9 = 0 as u32;
            if nd.initializer != NODE_NONE {
                let iop = self.lower_expr(nd.initializer);
                if iop == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                start = self.body.oper_pool.len() as u32;
                self.body.oper_pool.push(iop);
                n9 = 1;
            }
            let t = self.temp(ty, sp);
            let pl = self.place_of_local(t);
            self.assign(
                pl,
                ir::Rvalue {
                    kind: ir::RV_INTRINSIC,
                    a: start,
                    b: n9,
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
            let mut d = self.f.res(outer);
            if d.node == NODE_NONE {
                d = self.f.res(inner); // resolutions land on the inner name for value turbofish
            }
            let ty = self.nty(outer);
            let sp = self.f.node(outer).span;
            if d.node != NODE_NONE {
                // a specialized fn VALUE (`job_entry::<F>`) carries its type args: the emitter
                // suffixes the symbol and demands the instance from them
                let ts = self.body.targ_pool.len() as u32;
                let tn = self.copy_targs(outer);
                return self.const_op(
                    ir::Constant { kind: ir::CK_ITEM, ty: ty, val: 0, raw: sp, item: d, targ_start: ts, targ_len: tn },
                );
            }
        }
        return self.lower_expr(inner);
    }

    fn lower_literal(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.literal;
        let ty = self.nty(id);
        let _sp = self.f.node(id).span;
        let no = DefId { module: 0, node: NODE_NONE };
        let w = self.f.wide_lit(id);
        if w != null {
            // `val` carries the wide_lits pool INDEX (the emitter reads the limbs back by it)
            let wi = unsafe (&*(&*self.pkg).module_ast_const(self.body.module)).wide_lit_of(id);
            return self.const_op(
                ir::Constant { kind: ir::CK_WIDE, ty: ty, val: wi, raw: d.raw, item: no, targ_start: 0, targ_len: 0 },
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
            // val = the literal token kind (low byte) plus the format-SEGMENT flag (bit 8):
            // quoted spellings copy verbatim into C, raw (matchertext) spellings re-escape
            // byte-wise, and segments collapse their doubled braces
            let segf: i64 = if d.seg {
                256;
            } else {
                0;
            };
            return self.const_op(
                ir::Constant {
                    kind: ir::CK_STR,
                    ty: ty,
                    val: t as i64 | segf,
                    raw: d.raw,
                    item: no,
                    targ_start: 0,
                    targ_len: 0,
                },
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
        // Char/byte-char literals: `val` IS the decoded code point (the C spelling prints it).
        if t == tt::TokenType::CharacterLiteral || t == tt::TokenType::ByteCharacterLiteral {
            return self.const_op(
                ir::Constant {
                    kind: ir::CK_INT,
                    ty: ty,
                    val: decode_char(self.src, d.raw),
                    raw: d.raw,
                    item: no,
                    targ_start: 0,
                    targ_len: 0,
                },
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
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        if d.op == tt::TokenType::Ampersand || d.op == tt::TokenType::AmpersandAmpersand {
            let pl = self.lower_place(d.operand);
            if pl == ir::IR_NONE {
                return ir::IR_NONE;
            }
            if d.op == tt::TokenType::Ampersand {
                self.tp(ir::TP_REF, 0, id);
            }
            let mutable: u32 = if d.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                1;
            } else {
                0;
            };
            // `&x` typed as a raw pointer (pointer-position typing) is an address, not a borrow.
            let mut rk = ir::RV_REF;
            if ty != TYPE_NONE && self.f.ty(ty).kind == TypeKind::TYPE_POINTER {
                rk = ir::RV_ADDR;
            }
            if rk == ir::RV_REF && ty != TYPE_NONE && self.f.ty(ty).kind == TypeKind::TYPE_REFERENCE && self.f.ty(ty).qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                self.note_mut_bind(d.operand);
            }
            // A deref-coerced borrow: the node's checked type is already the coercion TARGET, but
            // the borrow itself references the operand place; apply_adjust's recorded hops produce
            // the target from it. Typing the temp from the node would hand the hop's `deref` call a
            // receiver labeled with the wrong C type.
            let mut bty = ty;
            if ty != TYPE_NONE && self.f.derefs(id) != null && self.f.ty(ty).kind == TypeKind::TYPE_REFERENCE {
                let q = self.f.ty(ty).qualifier;
                let pty = self.body.places.at(pl as usize).ty;
                let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
                bty = sa.intern_type(Ty { kind: TypeKind::TYPE_REFERENCE, qualifier: q, as_data: TyAs { elem: pty } });
            }
            let t = self.temp(bty, sp);
            let tp = self.place_of_local(t);
            self.assign(
                tp,
                ir::Rvalue {
                    kind: rk,
                    a: pl,
                    b: mutable,
                    c: 0,
                    target: bty,
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
        // A negative wide literal records its (two's-complemented) limbs on the UNARY node.
        if self.f.wide_lit(id) != null {
            let wi = unsafe (&*(&*self.pkg).module_ast_const(self.body.module)).wide_lit_of(id);
            return self.const_op(
                ir::Constant {
                    kind: ir::CK_WIDE,
                    ty: ty,
                    val: wi,
                    raw: sp,
                    item: DefId { module: 0, node: NODE_NONE },
                    targ_start: 0,
                    targ_len: 0,
                },
            );
        }
        // A negative integer literal folds to ONE constant; a spelled value too wide for the
        // checker's default i32 carries in i64 (the old emitter's textual `-...LL` behavior).
        if d.op == tt::TokenType::Minus && self.f.node(d.operand).kind == NodeKind::NODE_LITERAL {
            let mut mag: i64 = 0;
            let lit_ok = lit_int_value(self.src, self.f.node(d.operand).as_data.literal.raw, &mut mag);
            let lop = self.lower_expr(d.operand);
            if lit_ok && lop != ir::IR_NONE {
                let o9 = *self.body.operands.at(lop as usize);
                if o9.kind == ir::OP_CONST {
                    let c9 = *self.body.constants.at(o9.data as usize);
                    if c9.kind == ir::CK_INT {
                        let v9 = 0 - mag;
                        let mut ty9 = ty;
                        if (v9 < -2147483648 || v9 > 2147483647) && ty9 != TYPE_NONE {
                            let yv = *self.f.ty(ty9);
                            if yv.kind == TypeKind::TYPE_BUILTIN && (yv.as_data.builtin == BuiltinType::BT_I32 || yv.as_data.builtin == BuiltinType::BT_I16 || yv.as_data.builtin == BuiltinType::BT_I8) {
                                ty9 = Ast::builtin(BuiltinType::BT_I64);
                            }
                        }
                        return self.const_op(
                            ir::Constant {
                                kind: ir::CK_INT,
                                ty: ty9,
                                val: v9,
                                raw: sp,
                                item: DefId { module: 0, node: NODE_NONE },
                                targ_start: 0,
                                targ_len: 0,
                            },
                        );
                    }
                }
            }
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
        let ty = self.nty(id);
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
        // error path: read the error payload (Err has one; None has none), convert it through the
        // checker-selected `from` when the error types differ, and rewrap it as the RETURN type's
        // error variant into slot 0
        if self.body.returns != 0 {
            let vty = self.body.places.at(vpl as usize).ty;
            let mut err_ord: i64 = -1;
            let mut evd = DefId { module: 0, node: NODE_NONE };
            let mut has_payload = false;
            self.carrier_err_variant(vty, &mut err_ord, &mut evd, &mut has_payload);
            let rt = self.body.locals.at(0).ty;
            let mut rok: i64 = -1;
            let mut rov = DefId { module: 0, node: NODE_NONE };
            self.carrier_ok_variant(rt, &mut rok, &mut rov);
            let mut rerr: i64 = -1;
            let mut rev = DefId { module: 0, node: NODE_NONE };
            let mut rpay = false;
            self.carrier_err_variant(rt, &mut rerr, &mut rev, &mut rpay);
            if err_ord < 0 || rerr < 0 {
                self.fail_at("question-variants", id);
                return ir::IR_NONE;
            }
            let start = self.body.oper_pool.len() as u32;
            let mut n: u32 = 0;
            if has_payload && rpay {
                let epl0 = self.place_project(
                    vpl,
                    ir::Projection { kind: ir::PJ_DOWNCAST, data: err_ord as u32, sub: evd.node, ty: vty },
                );
                let ety = self.payload_type(evd);
                let epl = self.place_project(
                    epl0,
                    ir::Projection { kind: ir::PJ_FIELD, data: 0, sub: NODE_NONE, ty: ety },
                );
                let mut eop = self.copy_op(epl);
                let conv = self.f.res(id);
                if conv.node != NODE_NONE {
                    let cty = self.payload_type(rev);
                    let cstart = self.body.oper_pool.len() as u32;
                    self.body.oper_pool.push(eop);
                    eop = self.emit_call(conv, ir::IR_NONE, cstart, 1, 0, 0, cty, sp);
                    if eop == ir::IR_NONE {
                        return ir::IR_NONE;
                    }
                }
                self.body.oper_pool.push(eop);
                n = 1;
            }
            let rpl = self.place_of_local(0);
            self.assign(
                rpl,
                ir::Rvalue { kind: ir::RV_AGGREGATE, a: start, b: n, c: ir::AGG_VARIANT, target: rt, item: rev },
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

    // The error/none variant (None/Err) of a `?` carrier, its ordinal, and whether it carries a
    // payload; plus the declared type of a variant's first payload slot.
    fn carrier_err_variant(self: &Self, t: TypeId, ord: &mut i64, vd: &mut DefId, has_payload: &mut bool) {
        *ord = -1;
        *has_payload = false;
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
            if nm == "None" || nm == "Err" {
                *ord = j;
                *vd = DefId { module: em, node: vn };
                *has_payload = a.at_const(vn).as_data.variant.payload.len != 0;
                return;
            }
        }
    }

    const fn payload_type(self: &Self, vd: DefId) TypeId {
        let a = unsafe &*(&*self.pkg).module_ast_const(vd.module);
        let pl = a.at_const(vd.node).as_data.variant.payload;
        if pl.len == 0 {
            return TYPE_NONE;
        }
        return a.type_of(unsafe a.list(pl)[0]);
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

    // The variant of enum-carrier type `t` spelled `name` (dyn_cast's None arm).
    fn carrier_variant_named(self: &Self, t: TypeId, name: str) DefId {
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
            return DefId { module: 0, node: NODE_NONE };
        }
        let a = unsafe &*(&*self.pkg).module_ast_const(em);
        if a.at_const(ed).kind != NodeKind::NODE_ENUM {
            return DefId { module: 0, node: NODE_NONE };
        }
        let src = unsafe (&*self.pkg).modules.at(em as usize).source.as_str();
        let ms = a.at_const(ed).as_data.aggregate.members;
        for j in 0..ms.len {
            let vn = unsafe a.list(ms)[j as usize];
            let nsp = a.at_const(a.at_const(vn).as_data.variant.name).as_data.name.text;
            if src.slice(nsp.start as usize, nsp.end as usize) == name {
                return DefId { module: em, node: vn };
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    fn lower_binary(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.binary;
        let ty = self.nty(id);
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
            // the RHS only runs on the deciding path: a failed fold there is not an error
            if unsafe (&*self.pkg).cir != null {
                let cev9 = unsafe &mut *((&*self.pkg).cir as *mut iri::Interp);
                cev9.pause_folds();
            }
            let rop = self.lower_expr(d.right);
            if unsafe (&*self.pkg).cir != null {
                let cev9 = unsafe &mut *((&*self.pkg).cir as *mut iri::Interp);
                cev9.resume_folds();
            }
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
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        let lop = self.lower_expr(lhs);
        if lop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let mut argv = self.avget();
        argv.push(lop);
        if rhs != NODE_NONE {
            let rop = self.lower_expr(rhs);
            if rop == ir::IR_NONE {
                return ir::IR_NONE;
            }
            argv.push(rop);
        }
        let start = self.pool_ops(&argv);
        let n = argv.len() as u32;
        self.avput(argv);
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
            let ta = self.proj_subst_ty(unsafe mu.args[i as usize]);
            self.body.targ_pool.push(ta);
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
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        let ck = self.f.node(d.callee).kind;
        if ck == NodeKind::NODE_MEMBER {
            let op9 = self.lower_meta_call(id, ty, sp);
            if op9 != ir::IR_NONE {
                return op9;
            }
        }
        // `Some(x)`: a payload variant CONSTRUCTOR call is aggregate construction, not a call.
        // `Wrap(a, b)` for a tuple struct is likewise positional aggregate construction, not a call.
        {
            let vd = self.path_res(d.callee);
            let vk = self.decl_kind(vd);
            let is_tuple_ctor = vk == NodeKind::NODE_STRUCT && unsafe (&*(&*self.pkg).module_ast_const(vd.module)).at_const(
                vd.node,
            ).as_data.aggregate.is_tuple;
            if vd.node != NODE_NONE && (vk == NodeKind::NODE_VARIANT || is_tuple_ctor) {
                let mut argv = self.avget();
                for i in 0..d.args.len {
                    let op = self.lower_expr(unsafe self.f.list(d.args)[i as usize]);
                    if op == ir::IR_NONE {
                        return ir::IR_NONE;
                    }
                    self.mark_user_move(op);
                    argv.push(op);
                }
                let agg: u8 = if is_tuple_ctor {
                    ir::AGG_TUPLE;
                } else {
                    ir::AGG_VARIANT;
                };
                let r9 = self.finish_aggregate(agg, vd, &argv, ty, sp);
                self.avput(argv);
                return r9;
            }
        }
        // Method call: receiver first, then arguments; the selected target comes from call_info.
        let ci = self.f.call_info(id);
        let mut target = DefId { module: 0, node: NODE_NONE };
        switch ci {
            Some(v) => {
                target = DefId { module: ci_module(v), node: ci_decl(v) };
            },
            None => {},
        };
        // A callee IDENTIFIER bound to a local (fn-pointer LET/param) calls the VALUE, whatever
        // call_info recorded (the checker may pin the provenance decl; the pointer decides).
        if target.node != NODE_NONE && ck == NodeKind::NODE_IDENTIFIER {
            let rd0 = self.f.res(d.callee);
            if rd0.module == self.module && rd0.node != NODE_NONE && self.local_of(rd0.node) != ir::IR_NONE {
                target = DefId { module: 0, node: NODE_NONE };
            }
        }
        // Emit-time implicit CTFE (the old backend's fold pass): a scalar call whose arguments
        // look compile-time constant runs through the evaluator -- success folds the call to its
        // value, a `const fn` failure records a fold error the driver promotes.
        if !self.body.is_generic && ty != TYPE_NONE && unsafe (&*self.pkg).cir != null {
            let cev8 = unsafe &mut *((&*self.pkg).cir as *mut iri::Interp);
            // a body the interpreter lowers for its OWN execution folds through interpretation
            // itself (and a facade root lowering IS the fold in progress); re-entrant implicit
            // folding would clobber the live evaluation state
            if cev8.record_folds && !cev8.folding_self() {
                let mut ct8 = target;
                if ct8.node == NODE_NONE {
                    ct8 = self.path_res(d.callee);
                }
                if ct8.node != NODE_NONE && self.decl_kind(ct8) == NodeKind::NODE_FUNCTION {
                    let ta8 = unsafe &*(&*self.pkg).module_ast_const(ct8.module);
                    let fd8 = ta8.at_const(ct8.node).as_data.function;
                    // scalar results only (the fold-worthwhile gate): wide-value const fns fall
                    // back to runtime calls without complaint
                    let y8 = *self.f.ty(ty);
                    let scalar8 = y8.kind == TypeKind::TYPE_BUILTIN && y8.as_data.builtin != BuiltinType::BT_VOID && y8.as_data.builtin != BuiltinType::BT_VALIST && y8.as_data.builtin != BuiltinType::BT_C32 && y8.as_data.builtin != BuiltinType::BT_C64;
                    if scalar8 && !fd8.is_extern && fd8.body != NODE_NONE && self.maybe_const(id) {
                        let v8 = cev8.eval(self.module, id);
                        if v8.kind == iri::IV_INT || v8.kind == iri::IV_BOOL {
                            // folded: the replay still sees the call boundary, and each argument's
                            // consumption is marked explicitly (no IR op survives to carry it)
                            self.tp(ir::TP_CALL_MARK, 0, id);
                            for ai8 in 0..d.args.len {
                                self.tp(ir::TP_CONST_MOVE, 0, unsafe self.f.list(d.args)[ai8 as usize]);
                            }
                            self.tp(ir::TP_CALL, 0, id);
                            let ck8: u8 = if v8.kind == iri::IV_BOOL {
                                ir::CK_BOOL;
                            } else {
                                ir::CK_INT;
                            };
                            return self.const_op(
                                ir::Constant {
                                    kind: ck8,
                                    ty: ty,
                                    val: v8.i,
                                    raw: sp,
                                    item: DefId { module: 0, node: NODE_NONE },
                                    targ_start: 0,
                                    targ_len: 0,
                                },
                            );
                        }
                    }
                }
            }
        }
        // `type_info::<T>()` / `zeroed::<T>()`: compiler intrinsics, not resolved functions.
        if target.node == NODE_NONE && self.is_intrinsic_callee(d.callee, "type_info") {
            // the subject type rides in `b` so the backend can name the exported descriptor
            let mu = self.f.type_args(id);
            let mut bt9 = TYPE_NONE;
            if mu != null && unsafe mu.n != 0 {
                bt9 = unsafe mu.args[0];
            }
            return self.intrinsic_value(ir::IN_TYPE_INFO, bt9, ty, sp);
        }
        // `dyn_cast::<T>(v)`: ordinary IR -- a vtable type-id test branching into Some/None
        // construction, so every downstream pass (drops, borrows, backend) sees plain code.
        if target.node == NODE_NONE && self.is_intrinsic_callee(d.callee, "dyn_cast") && d.args.len == 1 {
            let av = self.lower_expr(unsafe self.f.list(d.args)[0]);
            if av == ir::IR_NONE {
                return ir::IR_NONE;
            }
            let oy = *self.f.ty(ty);
            if oy.kind != TypeKind::TYPE_INSTANCE {
                self.fail_at("dyn-cast-type", id);
                return ir::IR_NONE;
            }
            let oit = *self.f.instance(oy.as_data.inst);
            if oit.n == 0 {
                self.fail_at("dyn-cast-type", id);
                return ir::IR_NONE;
            }
            let rt9 = oit.args[0]; // the &T payload of the Option result
            let mut sord: i64 = -1;
            let mut svd = DefId { module: 0, node: NODE_NONE };
            self.carrier_ok_variant(ty, &mut sord, &mut svd);
            let nvd = self.carrier_variant_named(ty, "None");
            if sord < 0 || nvd.node == NODE_NONE {
                self.fail_at("dyn-cast-carrier", id);
                return ir::IR_NONE;
            }
            let bt9 = Ast::builtin(BuiltinType::BT_BOOL);
            let fl = self.temp(bt9, sp);
            let mut argv = self.avget();
            argv.push(av);
            let fstart = self.pool_ops(&argv);
            self.avput(argv);
            self.assign(
                self.place_of_local(fl),
                ir::Rvalue {
                    kind: ir::RV_INTRINSIC,
                    a: fstart,
                    b: 1,
                    c: ir::IN_DYN_TID,
                    target: rt9,
                    item: DefId { module: 0, node: NODE_NONE },
                },
                sp,
            );
            let res = self.temp(ty, sp);
            let rpl = self.place_of_local(res);
            let some_b = self.open_block();
            let none_b = self.open_block();
            let join = self.open_block();
            let flc = self.copy_op(self.place_of_local(fl));
            self.branch_bool(flc, some_b, none_b, sp);
            let mut argd = self.avget();
            argd.push(av);
            let dstart = self.pool_ops(&argd);
            self.avput(argd);
            let dv = self.temp(rt9, sp);
            self.assign(
                self.place_of_local(dv),
                ir::Rvalue {
                    kind: ir::RV_INTRINSIC,
                    a: dstart,
                    b: 1,
                    c: ir::IN_DYN_DATA,
                    target: rt9,
                    item: DefId { module: 0, node: NODE_NONE },
                },
                sp,
            );
            let mut sargs = self.avget();
            sargs.push(self.copy_op(self.place_of_local(dv)));
            let sv = self.finish_aggregate(ir::AGG_VARIANT, svd, &sargs, ty, sp);
            self.avput(sargs);
            if sv == ir::IR_NONE {
                return ir::IR_NONE;
            }
            let srv = self.rv_use(sv, ty);
            self.assign(rpl, srv, sp);
            self.seal(self.goto_term(join, sp), none_b);
            let nargs = self.avget();
            let nv = self.finish_aggregate(ir::AGG_VARIANT, nvd, &nargs, ty, sp);
            self.avput(nargs);
            if nv == ir::IR_NONE {
                return ir::IR_NONE;
            }
            let nrv = self.rv_use(nv, ty);
            self.assign(rpl, nrv, sp);
            self.seal(self.goto_term(join, sp), join);
            return self.copy_op(rpl);
        }
        if target.node == NODE_NONE && self.is_intrinsic_callee(d.callee, "zeroed") {
            return self.intrinsic_value(ir::IN_ZEROED, 0, ty, sp);
        }
        if target.node == NODE_NONE && self.is_intrinsic_callee(d.callee, "dangling") {
            // the pointee rides in `b` so the backend can pick the sentinel alignment
            let mu = self.f.type_args(id);
            let mut bt9 = TYPE_NONE;
            if mu != null && unsafe mu.n != 0 {
                bt9 = unsafe mu.args[0];
            }
            return self.intrinsic_value(ir::IN_DANGLING, bt9, ty, sp);
        }
        // assert family: compiler builtins -- lower to TM_ASSERT so the backend bakes the failing
        // expression's text and location (the std placeholder bodies are never called). The
        // typechecker records no call_info for them, so the callee resolves through its identifier.
        if d.args.len >= 1 {
            let mut adef = target;
            if adef.node == NODE_NONE && self.f.node(d.callee).kind == NodeKind::NODE_IDENTIFIER {
                adef = self.f.res(d.callee);
            }
            if adef.node != NODE_NONE {
                let ak = self.assert_kind(adef);
                if ak != 0 {
                    return self.lower_assert(id, ak, ty, sp);
                }
            }
        }
        // `d.free()` on a dyn value has no resolved method: destruction IS the call. Lower it as
        // an explicit drop so the analyses see the consume and the backend prints glue.
        if target.node == NODE_NONE && ck == NodeKind::NODE_MEMBER && !self.f.node(d.callee).as_data.member.path && d.args.len == 0 {
            let mem = self.f.node(d.callee).as_data.member.member;
            let msp = self.f.node(mem).as_data.name.text;
            if (msp.end - msp.start) as usize == 4 && self.src.slice(msp.start as usize, msp.end as usize) == "free" {
                let obj = self.f.node(d.callee).as_data.member.object;
                let opl = self.lower_place_or_spill(obj);
                if opl == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                self.tp(ir::TP_CALL, 1, id);
                let mut tm = self.term0(ir::TM_DROP, sp);
                tm.a = opl;
                let cont = self.open_block();
                tm.t0 = cont;
                self.seal(tm, cont);
                return self.unit_op(ty, sp);
            }
        }
        let mut argv = self.avget();
        let mut callee_op = ir::IR_NONE;
        if ck == NodeKind::NODE_MEMBER && !self.f.node(d.callee).as_data.member.path && target.node != NODE_NONE {
            let recv = self.f.node(d.callee).as_data.member.object;
            // A receiver that resolved through the checker's auto-deref chain lowers each hop
            // (exactly as `*x` and field access do), so the operand the call carries has the
            // TARGET's type: the callee symbol and the arg shape need no Deref knowledge.
            let du9 = self.f.derefs(self.f.node(d.callee).as_data.member.member);
            let mut rop = ir::IR_NONE;
            if du9 != null && unsafe du9.n > 0 {
                let mut base9 = self.lower_place_or_spill(recv);
                if base9 == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                let steps9 = unsafe du9.n;
                for s9 in 0..steps9 {
                    let m9 = unsafe du9.method[s9 as usize];
                    let rt9 = unsafe du9.recv[s9 as usize];
                    if m9.node != NODE_NONE {
                        let mut rt29 = self.deref_ret_ty(m9, self.body.places.at(base9 as usize).ty);
                        if rt29 == TYPE_NONE {
                            rt29 = rt9;
                        }
                        let rop9 = self.copy_op(base9);
                        let start9 = self.body.oper_pool.len() as u32;
                        self.body.oper_pool.push(rop9);
                        let res9 = self.emit_call(m9, ir::IR_NONE, start9, 1, 0, 0, rt29, sp);
                        if res9 == ir::IR_NONE {
                            return ir::IR_NONE;
                        }
                        base9 = self.spill(res9, sp);
                    } else {
                        base9 = self.place_project(
                            base9,
                            ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: rt9 },
                        );
                    }
                }
                rop = self.copy_op(base9);
            } else {
                rop = self.lower_expr(recv);
            }
            if rop == ir::IR_NONE {
                return ir::IR_NONE;
            }
            if (du9 == null || unsafe du9.n == 0) && self.f.node(recv).kind == NodeKind::NODE_CALL {
                // a call-result RECEIVER temporary owns its value: scope-drop it after use
                // (the deref-chain path lowers the receiver as a place, which registers it)
                let o9 = *self.body.operands.at(rop as usize);
                if o9.kind == ir::OP_COPY || o9.kind == ir::OP_MOVE {
                    let pl9 = *self.body.places.at(o9.data as usize);
                    if pl9.proj_len == 0 && self.body.locals.at(pl9.base as usize).storage == ir::LS_TEMP {
                        let mut ld9 = *self.body.locals.at(pl9.base as usize);
                        ld9.decl = recv; // drops key on a decl
                        self.body.locals.set(pl9.base as usize, ld9);
                        self.scope_locals.push(pl9.base);
                    }
                }
            }
            // A by-value receiver is a USER consumption (the walk's check_call_receiver move);
            // Deref-adapted receivers are borrowed through the impl instead.
            let fa1 = unsafe &*(&*self.pkg).module_ast_const(target.module);
            let tf1 = fa1.at_const(target.node);
            if tf1.kind == NodeKind::NODE_FUNCTION && tf1.as_data.function.params.len >= 1 {
                let p1 = unsafe fa1.list(tf1.as_data.function.params)[0];
                let pt1 = fa1.at_const(p1).as_data.parameter.ty;
                let mut ptk1 = NodeKind::NODE_NONE_KIND;
                if pt1 != NODE_NONE {
                    ptk1 = fa1.at_const(pt1).kind;
                }
                if ptk1 != NodeKind::NODE_POINTER_TYPE && ptk1 != NodeKind::NODE_REFERENCE_TYPE && self.f.derefs(
                    self.f.node(d.callee).as_data.member.member,
                ) == null {
                    self.mark_user_move(rop);
                }
            }
            argv.push(rop);
        } else if target.node == NODE_NONE {
            // fn-value call (closure, fn pointer): the callee is an operand
            callee_op = self.lower_expr(d.callee);
            if callee_op == ir::IR_NONE {
                return ir::IR_NONE;
            }
        } else {
            // direct call: nothing to evaluate for the callee
        }
        self.tp(ir::TP_CALL_MARK, 0, id);
        for i in 0..d.args.len {
            let a = unsafe self.f.list(d.args)[i as usize];
            let op = self.lower_expr(a);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            self.mark_user_move(op);
            argv.push(op);
        }
        self.tp(ir::TP_CALL, 0, id);
        let ts = self.body.targ_pool.len() as u32;
        let mut tn = self.copy_targs(id);
        if tn == 0 {
            // `Type::<Args>::assoc()`: the bound args ride the CALLEE (or its qualifying path),
            // not the call node
            tn = self.copy_targs(d.callee);
            if tn == 0 && self.f.node(d.callee).kind == NodeKind::NODE_MEMBER {
                let ob9 = self.f.node(d.callee).as_data.member.object;
                tn = self.copy_targs(ob9);
                if tn == 0 {
                    // the qualifier is a TYPE whose recorded type IS the receiver instance:
                    // its arguments are the bound generics (turbofish spellings resolve through
                    // the specialization's inner expression)
                    let mut rq9 = ob9;
                    if self.f.node(rq9).kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
                        rq9 = self.f.node(rq9).as_data.specialization.expression;
                    }
                    let od9 = self.f.res(rq9);
                    let mut is_ty9 = false;
                    if od9.node != NODE_NONE {
                        let ok9 = self.decl_kind(od9);
                        is_ty9 = ok9 == NodeKind::NODE_STRUCT || ok9 == NodeKind::NODE_ENUM || ok9 == NodeKind::NODE_TYPE_ALIAS;
                    }
                    let oty9 = self.nty(ob9);
                    if is_ty9 && oty9 != TYPE_NONE && self.f.ty(oty9).kind == TypeKind::TYPE_INSTANCE {
                        let it9 = *self.f.instance(self.f.ty(oty9).as_data.inst);
                        for k9 in 0..it9.n {
                            self.body.targ_pool.push(unsafe it9.args[k9 as usize]);
                        }
                        tn = it9.n;
                    }
                }
            }
        }
        let start = self.pool_ops(&argv);
        let n = argv.len() as u32;
        self.avput(argv);
        let res = self.emit_call(target, callee_op, start, n, ts, tn, ty, sp);
        self.maybe_cancel_check(id, target, callee_op != ir::IR_NONE, res, ty, sp);
        return res;
    }

    // The compiled cancellation edge. After a call that can reach cancellation acceptance, a
    // task-reachable body outside the runtime's own modules probes for an accepted cancellation:
    //
    //   probe == 2  the callee returned a REAL value: move it into a tracked spill (the ladder
    //               frees it exactly once), then unwind.
    //   probe == 1  the callee itself edge-returned: its value is poison, abandon it, unwind.
    //   probe == 0  continue.
    //
    // The ladder is the same defers-then-deads sequence an early return takes, bracketed by the
    // runtime's ladder mask (cleanup can wait, but never re-cancel), and ends in a flagged return
    // the backend spells as a zero the (also unwinding) caller never reads. An unpinned fn-value
    // callee is cancellation-masked (plan 10.3): no check follows it, and the next pinned
    // cancellation point delivers a pending edge.
    // The per-body half of the check-eligibility test, cached in `chk_on`: everything that does
    // not depend on the callee. The sugar items are re-read (cheaply) by the emitting path.
    fn chk_enabled(self: &mut Self) bool {
        if self.chk_on == 0 {
            self.chk_on = 1;
            let pk = unsafe &*self.pkg;
            let ow = self.body.owner;
            if pk.cancel_state == 1 && ow.node != NODE_NONE {
                let probe = pk.sugar_item(loader::SugarItem::SI_CANCEL_PROBE);
                let lbegin = pk.sugar_item(loader::SugarItem::SI_CANCEL_LBEGIN);
                let lend = pk.sugar_item(loader::SugarItem::SI_CANCEL_LEND);
                if probe.node != NODE_NONE && lbegin.node != NODE_NONE && lend.node != NODE_NONE {
                    let osp = unsafe (&*pk.module_ast_const(ow.module)).at_const(ow.node).span;
                    if pk.co_on(ow.module, osp) && pk.modules.at(ow.module as usize).path.as_str() != "std::parallel::runtime" {
                        self.chk_on = 2;
                    }
                }
            }
        }
        return self.chk_on == 2;
    }

    fn maybe_cancel_check(
        self: &mut Self,
        id: NodeId,
        target: DefId,
        is_fn_value: bool,
        res: ir::OperandId,
        ty: TypeId,
        sp: tok::Span,
    ) {
        if id != self.chk_root {
            return; // only a statement-root call: no pending sibling temporaries to unwind past
        }
        if self.in_defer != 0 {
            return; // cleanup is masked: no edge inside a defer body
        }
        if is_fn_value {
            return; // unpinned callee: cancellation-masked across the call (plan 10.3)
        }
        if !self.chk_enabled() {
            return;
        }
        let pk = unsafe &*self.pkg;
        if target.node == NODE_NONE {
            return;
        }
        let ta = unsafe &*pk.module_ast_const(target.module);
        if ta.at_const(target.node).kind != NodeKind::NODE_FUNCTION {
            return;
        }
        if !pk.cancel_on(target.module, ta.at_const(target.node).span) {
            return; // this callee can never accept a cancellation
        }
        let probe = pk.sugar_item(loader::SugarItem::SI_CANCEL_PROBE);
        let lbegin = pk.sugar_item(loader::SugarItem::SI_CANCEL_LBEGIN);
        let lend = pk.sugar_item(loader::SugarItem::SI_CANCEL_LEND);
        let it = Ast::builtin(BuiltinType::BT_I32);
        let ut = Ast::builtin(BuiltinType::BT_VOID);
        let c0 = self.body.oper_pool.len() as u32;
        let cond = self.emit_call(probe, ir::IR_NONE, c0, 0, 0, 0, it, sp);
        let real_b = self.open_block();
        let ladder_b = self.open_block();
        let cont_b = self.open_block();
        let mut t = self.term0(ir::TM_SWITCH, sp);
        t.a = cond;
        t.sw_start = self.body.switch_pool.len() as u32;
        self.body.switch_pool.push(2u64 << 32 | real_b as u64);
        self.body.switch_pool.push(1u64 << 32 | ladder_b as u64);
        t.sw_len = 2;
        t.t0 = cont_b;
        self.seal(t, real_b);
        // Real value: spill it into a tracked local so the ladder (and any later exit) frees it.
        let mut spillable = res != ir::IR_NONE && ty != TYPE_NONE && ty != ut;
        if spillable {
            let rk = self.body.operands.at(res as usize).kind;
            spillable = rk == ir::OP_COPY || rk == ir::OP_MOVE;
        }
        if spillable {
            // The spill's whole lifetime is THIS block: live, take the value, die (the drop
            // elaborates unconditionally right here, before the defers -- temporary operation state
            // is removed first). Nothing outside the block can see it, so no loan the value carries
            // outlives the check.
            let rpl = self.body.operands.at(res as usize).data;
            let sl = self.body.add_local(
                ir::LocalDecl {
                    ty: ty,
                    storage: ir::LS_INL,
                    is_mutable: false,
                    span: sp,
                    decl: NODE_NONE,
                    item: DefId { module: 0, node: NODE_NONE },
                },
            );
            self.stmt(
                ir::Statement {
                    kind: ir::ST_STORAGE_LIVE,
                    place: ir::IR_NONE,
                    rvalue: ir::IR_NONE,
                    a: sl,
                    b: 0,
                    span: sp,
                },
            );
            let op2 = self.copy_op(rpl);
            let pl = self.place_of_local(sl);
            let rv = self.rv_use(op2, ty);
            self.assign(pl, rv, sp);
            self.stmt(
                ir::Statement {
                    kind: ir::ST_STORAGE_DEAD,
                    place: ir::IR_NONE,
                    rvalue: ir::IR_NONE,
                    a: sl,
                    b: 0,
                    span: sp,
                },
            );
        }
        self.seal(self.goto_term(ladder_b, sp), ladder_b);
        // The ladder: masked cleanup, then hand the edge to the caller. A pending plain-let local
        // (registered above chk_base) is uninitialized on this path: no dead for it.
        let mut pending: i64 = -1;
        if self.chk_base < self.scope_locals.len() {
            switch self.scope_locals.pop() {
                Some(pl0) => {
                    pending = pl0;
                },
                _ => {},
            };
        }
        let b0 = self.body.oper_pool.len() as u32;
        let _ = self.emit_call(lbegin, ir::IR_NONE, b0, 0, 0, 0, ut, sp);
        self.emit_defers_down_to(0);
        self.emit_deads_down_to(0);
        let e0 = self.body.oper_pool.len() as u32;
        let _ = self.emit_call(lend, ir::IR_NONE, e0, 0, 0, 0, ut, sp);
        if pending >= 0 {
            self.scope_locals.push(pending as ir::LocalId);
        }
        let mut rt = self.term0(ir::TM_RETURN, sp);
        rt.args_len = ir::RET_CANCEL;
        self.seal(rt, cont_b);
    }

    fn intrinsic_value(self: &mut Self, ik: u8, bv: TypeId, ty: TypeId, sp: tok::Span) ir::OperandId {
        let t = self.temp(ty, sp);
        let pl = self.place_of_local(t);
        self.assign(
            pl,
            ir::Rvalue {
                kind: ir::RV_INTRINSIC,
                a: self.body.oper_pool.len() as u32,
                b: bv,
                c: ik,
                target: ty,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        return self.copy_op(pl);
    }

    // An unresolved callee spelling a compiler intrinsic name (behind an optional specialization).
    // 1 assert / 2 assert_eq / 3 assert_ne when `t` is the prelude's builtin placeholder (the
    // typechecker's own gate: a prelude-module function with one of the three names).
    const fn assert_kind(self: &Self, t: DefId) u8 {
        let p = unsafe &*self.pkg;
        if !p.modules.at(t.module as usize).prelude {
            return 0;
        }
        let a = unsafe &*p.module_ast_const(t.module);
        let n = a.at_const(t.node);
        if n.kind != NodeKind::NODE_FUNCTION {
            return 0;
        }
        let sp2 = a.at_const(n.as_data.function.name).as_data.name.text;
        let nm = p.modules.at(t.module as usize).source.as_str().slice(sp2.start as usize, sp2.end as usize);
        if nm == "assert" {
            return 1;
        }
        if nm == "assert_eq" {
            return 2;
        }
        if nm == "assert_ne" {
            return 3;
        }
        return 0;
    }

    // `assert(cond[, msg])` asserts the condition directly (the span = the condition's text);
    // eq/ne compare through a bool temp (RV_BINARY dispatches str/struct equality downstream) and
    // carry the whole call as their text. The optional message rides the terminator's arg range.
    fn lower_assert(self: &mut Self, id: NodeId, ak: u8, ty: TypeId, sp: tok::Span) ir::OperandId {
        let d = self.f.node(id).as_data.call;
        let a0 = unsafe self.f.list(d.args)[0];
        let mut cond = ir::IR_NONE;
        let mut msg = ir::IR_NONE;
        let mut lsave = ir::IR_NONE;
        let mut rsave = ir::IR_NONE;
        let mut tsp = self.f.node(a0).span;
        if ak == 1 {
            cond = self.lower_expr(a0);
            if d.args.len >= 2 {
                msg = self.lower_expr(unsafe self.f.list(d.args)[1]);
                if msg == ir::IR_NONE {
                    return ir::IR_NONE;
                }
            }
        } else {
            if d.args.len < 2 {
                self.fail_at("assert-args", id);
                return ir::IR_NONE;
            }
            let l = self.lower_expr(a0);
            let r = self.lower_expr(unsafe self.f.list(d.args)[1]);
            if l == ir::IR_NONE || r == ir::IR_NONE {
                return ir::IR_NONE;
            }
            lsave = l;
            rsave = r;
            tsp = self.f.node(id).span;
            let bt = Ast::builtin(BuiltinType::BT_BOOL);
            let ct = self.temp(bt, sp);
            let cpl = self.place_of_local(ct);
            let tokv: u8 = if ak == 2 {
                tt::TokenType::EqualEqual as u8;
            } else {
                tt::TokenType::BangEqual as u8;
            };
            self.assign(
                cpl,
                ir::Rvalue {
                    kind: ir::RV_BINARY,
                    a: l,
                    b: r,
                    c: tokv,
                    target: bt,
                    item: DefId { module: 0, node: NODE_NONE },
                },
                sp,
            );
            cond = self.copy_op(cpl);
        }
        if cond == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let mut tm = self.term0(ir::TM_ASSERT, tsp);
        tm.a = cond;
        if msg != ir::IR_NONE {
            let mut mv = self.avget();
            mv.push(msg);
            tm.args_start = self.pool_ops(&mv);
            tm.args_len = 1;
            self.avput(mv);
        }
        if ak != 1 {
            // assert_eq/ne diagnostics: [left value, right value, left spelling, right spelling];
            // sw_len records the flavor so the failure prints ` == ` vs ` != `
            let a1n = unsafe self.f.list(d.args)[1];
            let no9 = DefId { module: 0, node: NODE_NONE };
            let bt9 = Ast::builtin(BuiltinType::BT_BOOL);
            let lsc = self.const_op(
                ir::Constant {
                    kind: ir::CK_STR,
                    ty: bt9,
                    val: tt::TokenType::RawStringLiteral as i64,
                    raw: self.f.node(a0).span,
                    item: no9,
                    targ_start: 0,
                    targ_len: 0,
                },
            );
            let rsc = self.const_op(
                ir::Constant {
                    kind: ir::CK_STR,
                    ty: bt9,
                    val: tt::TokenType::RawStringLiteral as i64,
                    raw: self.f.node(a1n).span,
                    item: no9,
                    targ_start: 0,
                    targ_len: 0,
                },
            );
            let mut av = self.avget();
            av.push(lsave);
            av.push(rsave);
            av.push(lsc);
            av.push(rsc);
            tm.args_start = self.pool_ops(&av);
            tm.args_len = 4;
            tm.sw_len = ak;
            self.avput(av);
        }
        let cont = self.open_block();
        tm.t0 = cont;
        self.seal(tm, cont);
        return self.unit_op(ty, sp);
    }

    const fn is_intrinsic_callee(self: &Self, callee: NodeId, name: str) bool {
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

    // Operand lowering pushes nested ranges into oper_pool as it goes, so a caller must collect its
    // own operands OUTSIDE the pool and copy them in contiguously once every one is lowered.
    fn pool_ops(self: &mut Self, ops: &Vector<ir::OperandId>) u32 {
        let start = self.body.oper_pool.len() as u32;
        for i in 0..ops.len() {
            self.body.oper_pool.push(ops[i]);
        }
        return start;
    }

    fn lower_assignment(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.binary;
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        self.note_mut_bind(d.left);
        self.tp(ir::TP_ASSIGN_PRE, 0, id);
        let pl = self.lower_place(d.left);
        if pl == ir::IR_NONE {
            return ir::IR_NONE;
        }
        switch self.f.op_method(id) {
            Some(m) => {
                // compound assignment through an operator method: place = method(place, rhs)
                let lop = self.copy_op(pl);
                let rop = self.lower_expr(d.right);
                if rop == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                let mut argv = self.avget();
                argv.push(lop);
                argv.push(rop);
                let start = self.pool_ops(&argv);
                self.avput(argv);
                let lt = self.body.places.at(pl as usize).ty;
                let res = self.emit_call(
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
                self.tp(ir::TP_ASSIGN_POST, 0, id);
                return self.unit_op(ty, sp);
            },
            None => {},
        };
        let rop = self.lower_expr(d.right);
        if rop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        self.mark_user_move(rop);
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
        self.tp(ir::TP_ASSIGN_POST, 0, id);
        return self.unit_op(ty, sp);
    }

    fn lower_struct_init(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.struct_initializer;
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        let mut sd = self.f.res(id);
        if self.f.node(d.ty).kind == NodeKind::NODE_TYPE_PATH {
            let parts = self.f.node(d.ty).as_data.type_path.parts;
            if parts.len >= 2 {
                let vd9 = self.f.res(unsafe self.f.list(parts)[(parts.len - 1) as usize]);
                if vd9.node != NODE_NONE && self.decl_kind(vd9) == NodeKind::NODE_VARIANT {
                    sd = vd9;
                }
            }
        }
        if sd.node == NODE_NONE && ty != TYPE_NONE {
            let y = *self.f.ty(ty);
            if y.kind == TypeKind::TYPE_STRUCT {
                sd = DefId { module: y.module, node: y.as_data.decl };
            } else if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *self.f.instance(y.as_data.inst);
                sd = DefId { module: it.module, node: it.decl };
            }
        }
        // Values evaluate in SOURCE order (temps), but the operand list is normalized to DECL
        // order with IR_NONE holes for omitted members -- consumers index it by member position,
        // and omitted members zero-fill (the established emitter's designated-init semantics).
        let mut argv = self.avget();
        let is_var = sd.node != NODE_NONE && self.decl_kind(sd) == NodeKind::NODE_VARIANT;
        if sd.node != NODE_NONE {
            let da = unsafe &*(&*self.pkg).module_ast_const(sd.module);
            let dsrc = unsafe (&*self.pkg).modules.at(sd.module as usize).source.as_str();
            let members = if is_var {
                da.at_const(sd.node).as_data.variant.payload;
            } else {
                da.at_const(sd.node).as_data.aggregate.members;
            };
            for _i in 0..members.len {
                argv.push(ir::IR_NONE);
            }
            for i in 0..d.fields.len {
                let fi = unsafe self.f.list(d.fields)[i as usize];
                let fnm = self.f.node(self.f.node(fi).as_data.field_initializer.name).as_data.name.text;
                let ntxt = self.src.slice(fnm.start as usize, fnm.end as usize);
                let op = self.lower_expr(self.f.node(fi).as_data.field_initializer.value);
                if op == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                self.mark_user_move(op);
                let mut idx: i64 = -1;
                for j in 0..members.len {
                    let fid = unsafe da.list(members)[j as usize];
                    let ms = da.at_const(da.at_const(fid).as_data.field.name).as_data.name.text;
                    if dsrc.slice(ms.start as usize, ms.end as usize) == ntxt {
                        idx = j;
                        break;
                    }
                }
                if idx < 0 {
                    self.fail_at("struct-field", id);
                    return ir::IR_NONE;
                }
                argv.set(idx as usize, op);
            }
        } else {
            for i in 0..d.fields.len {
                let fi = unsafe self.f.list(d.fields)[i as usize];
                let op = self.lower_expr(self.f.node(fi).as_data.field_initializer.value);
                if op == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                self.mark_user_move(op);
                argv.push(op);
            }
        }
        if is_var {
            let rv9 = self.finish_aggregate(ir::AGG_VARIANT, sd, &argv, ty, sp);
            self.avput(argv);
            return rv9;
        }
        let rs9 = self.finish_aggregate(ir::AGG_STRUCT, sd, &argv, ty, sp);
        self.avput(argv);
        return rs9;
    }

    fn finish_aggregate(self: &mut Self, agg: u8, item: DefId, ops: &Vector<ir::OperandId>, ty: TypeId, sp: tok::Span) ir::OperandId {
        let start = self.pool_ops(ops);
        let t = self.temp(ty, sp);
        let pl = self.place_of_local(t);
        self.assign(
            pl,
            ir::Rvalue { kind: ir::RV_AGGREGATE, a: start, b: ops.len() as u32, c: agg, target: ty, item: item },
            sp,
        );
        return self.copy_op(pl);
    }

    fn lower_array_or_tuple(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.array_literal;
        let ty = self.nty(id);
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
        let mut argv = self.avget();
        let mut cur: i64 = 0;
        let mut designated = false;
        for i in 0..d.elements.len {
            let mut e = unsafe self.f.list(d.elements)[i as usize];
            if self.f.node(e).kind == NodeKind::NODE_FIELD_INITIALIZER {
                // designated array initializer `[idx] = value`: the designator folds to the SLOT,
                // later elements continue from it (C semantics); omitted slots zero-fill
                let ie = self.f.node(e).as_data.field_initializer.name;
                let mut iv: i64 = -1;
                if unsafe (&*self.pkg).cir != null {
                    let cevA = unsafe &mut *((&*self.pkg).cir as *mut iri::Interp);
                    let cvA = cevA.eval(self.module, ie);
                    if cvA.kind == iri::IV_INT {
                        iv = cvA.i;
                    }
                }
                if iv < 0 {
                    self.fail_at("array-designator", id);
                    return ir::IR_NONE;
                }
                cur = iv;
                designated = true;
                e = self.f.node(e).as_data.field_initializer.value;
            }
            let op = self.lower_expr(e);
            self.mark_user_move(op);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            while argv.len() as i64 <= cur {
                argv.push(ir::IR_NONE);
            }
            argv.set(cur as usize, op);
            cur += 1;
        }
        let agg: u8 = if k == NodeKind::NODE_TUPLE {
            ir::AGG_TUPLE;
        } else {
            ir::AGG_ARRAY;
        };
        let mut aty = ty;
        if designated && k == NodeKind::NODE_ARRAY_LITERAL && ty != TYPE_NONE {
            let y = *self.f.ty(ty);
            if y.kind == TypeKind::TYPE_ARRAY {
                if y.as_data.arr.len as i64 > argv.len() as i64 {
                    while argv.len() as i64 < y.as_data.arr.len as i64 {
                        argv.push(ir::IR_NONE);
                    }
                } else if y.as_data.arr.len as i64 < argv.len() as i64 {
                    // designators reached past the recorded length: the literal's C temp must
                    // span every written slot
                    let mut nt = y;
                    nt.as_data.arr.len = argv.len() as u32;
                    let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
                    aty = sa.intern_type(nt);
                }
            }
        }
        let ra9 = self.finish_aggregate(agg, DefId { module: 0, node: NODE_NONE }, &argv, aty, sp);
        self.avput(argv);
        return ra9;
    }

    fn lower_range(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.pattern_range;
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        // fixed decl-order slots {start, end, inclusive}: absent bounds are IR_NONE holes
        // (zero-fill), the inclusivity flag is a synthesized constant -- Core IR keeps it
        let mut argv = self.avget();
        let mut sop = ir::IR_NONE;
        if d.start != NODE_NONE {
            sop = self.lower_expr(d.start);
            if sop == ir::IR_NONE {
                return ir::IR_NONE;
            }
        }
        let mut eop = ir::IR_NONE;
        if d.end != NODE_NONE {
            eop = self.lower_expr(d.end);
            if eop == ir::IR_NONE {
                return ir::IR_NONE;
            }
        }
        argv.push(sop);
        argv.push(eop);
        let bt = Ast::builtin(BuiltinType::BT_BOOL);
        let mut iv: i64 = 0;
        if d.inclusive {
            iv = 1;
        }
        argv.push(
            self.const_op(
                ir::Constant {
                    kind: ir::CK_BOOL,
                    ty: bt,
                    val: iv,
                    raw: tok::Span { start: 0, end: 0 },
                    item: DefId { module: 0, node: NODE_NONE },
                    targ_start: 0,
                    targ_len: 0,
                },
            ),
        );
        let rr9 = self.finish_aggregate(ir::AGG_STRUCT, DefId { module: 0, node: NODE_NONE }, &argv, ty, sp);
        self.avput(argv);
        return rr9;
    }

    fn lower_if_expr(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.if_stmt;
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        let t = self.temp(ty, sp);
        let pl = self.place_of_local(t);
        self.tp(ir::TP_MARK_PUSH, 0, id);
        let cop = self.lower_expr(d.condition);
        self.tp(ir::TP_MARK_POP, 0, id);
        if cop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let then_b = self.open_block();
        let els_b = self.open_block();
        let join = self.open_block();
        self.branch_bool(cop, then_b, els_b, sp);
        self.tp(ir::TP_FLOW_SAVE, 0, id);
        self.lower_value_into(d.then_branch, pl);
        self.tp(ir::TP_FLOW_ELSE, 0, id);
        self.seal(self.goto_term(join, sp), els_b);
        if d.else_branch != NODE_NONE {
            self.lower_value_into(d.else_branch, pl);
        }
        self.tp(ir::TP_FLOW_JOIN, 0, id);
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
    // A block with no value-producing tail still writes `dest` (unit), so every consumer of the
    // destination reads initialized storage.
    fn lower_value_block(self: &mut Self, id: NodeId, dest: ir::PlaceId) {
        self.tp(ir::TP_SCOPE_PUSH, 0, id);
        self.scope_enter();
        let stmts = self.f.node(id).as_data.block.statements;
        let ty = self.body.places.at(dest as usize).ty;
        let mut wrote = false;
        for i in 0..stmts.len {
            let s = unsafe self.f.list(stmts)[i as usize];
            if i == stmts.len - 1 && self.f.node(s).kind == NodeKind::NODE_EXPRESSION_STATEMENT {
                let v = self.f.node(s).as_data.single.value;
                self.tp(ir::TP_MARK_PUSH, 0, s);
                let op = self.lower_expr(v);
                self.tp(ir::TP_MARK_POP, 0, s);
                if op == ir::IR_NONE {
                    return;
                }
                let rv = self.rv_use(op, ty);
                self.assign(dest, rv, self.f.node(s).span);
                wrote = true;
            } else {
                self.lower_stmt(s);
            }
            if self.err.len() != 0 {
                return;
            }
            self.tp(ir::TP_NLL, i, id);
        }
        if !wrote {
            let sp = self.f.node(id).span;
            let uop = self.unit_op(ty, sp);
            let rv = self.rv_use(uop, ty);
            self.assign(dest, rv, sp);
        }
        self.tp(ir::TP_SCOPE_POP, 0, id);
        self.scope_exit();
    }

    fn lower_loop_expr(self: &mut Self, id: NodeId, result: ir::PlaceId) {
        self.tape_mute += 1; // the walk has no value-position loop case: nothing replays
        let d = self.f.node(id).as_data.while_stmt;
        let sp = self.f.node(id).span;
        let head = self.open_block();
        let exit = self.open_block();
        self.seal(self.goto_term(head, sp), head);
        self.loops.push(
            LoopCtx {
                label: d.label,
                brk: exit,
                cont: head,
                defer_depth: self.defers.len(),
                locals_depth: self.scope_locals.len(),
                result: result,
            },
        );
        self.lower_stmt(d.body);
        let _ = self.loops.pop();
        self.seal(self.goto_term(head, sp), exit);
        self.tape_mute -= 1;
    }

    fn lower_va(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.va_op;
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        if d.op == VA_START || d.op == VA_END {
            // Both write the `va_list` itself (va_start also INITIALIZES it -- the init analysis
            // must see the write, never a read of the not-yet-started list), so the list is the
            // assignment's PLACE and the C prints the macro over that lvalue.
            let apl = self.lower_place_or_spill(d.ap);
            if apl == ir::IR_NONE {
                return ir::IR_NONE;
            }
            let mut argv = self.avget();
            if d.op == VA_START && d.extra != NODE_NONE {
                let op = self.lower_expr(d.extra);
                if op == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                argv.push(op);
            }
            let start = self.pool_ops(&argv);
            let n = argv.len() as u32;
            self.avput(argv);
            let ik: u8 = if d.op == VA_START {
                ir::IN_VA_START;
            } else {
                ir::IN_VA_END;
            };
            self.assign(
                apl,
                ir::Rvalue {
                    kind: ir::RV_INTRINSIC,
                    a: start,
                    b: n,
                    c: ik,
                    target: TYPE_NONE,
                    item: DefId { module: 0, node: NODE_NONE },
                },
                sp,
            );
            return self.unit_op(ty, sp);
        }
        // va_arg(ap, T): the requested type is the expression's own type; `extra` is that type's
        // syntax, never an expression to lower.
        let mut argv = self.avget();
        let op = self.lower_expr(d.ap);
        if op == ir::IR_NONE {
            return ir::IR_NONE;
        }
        argv.push(op);
        let start = self.pool_ops(&argv);
        let n = argv.len() as u32;
        self.avput(argv);
        let t = self.temp(ty, sp);
        let pl = self.place_of_local(t);
        self.assign(
            pl,
            ir::Rvalue {
                kind: ir::RV_INTRINSIC,
                a: start,
                b: n,
                c: ir::IN_VA_ARG,
                target: ty,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        return self.copy_op(pl);
    }

    fn lower_closure(self: &mut Self, id: NodeId) ir::OperandId {
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        let caps = self.f.captures(id);
        let mut argv = self.avget();
        for i in 0..caps.len {
            let c = unsafe self.f.list(caps)[i as usize];
            let mut l = self.local_of(self.cap_decl(c));
            if l == ir::IR_NONE {
                l = self.local_of(c); // pattern-shorthand: the binding hangs off the capture node
            }
            if l == ir::IR_NONE {
                continue;
            }
            let pl = self.place_of_local(l);
            let op = self.copy_op(pl);
            argv.push(op);
        }
        self.tp(ir::TP_CLOSURE, 0, id);
        self.closures.push(id);
        let fresh = self.pool_ops(&argv);
        let kept = argv.len() as u32;
        self.avput(argv);
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
    const fn cap_decl(self: &mut Self, c: NodeId) NodeId {
        let d = self.f.res(c);
        if d.module == self.module && d.node != NODE_NONE {
            return d.node;
        }
        return c; // the checker records the captured DECL itself, not a reference to it
    }

    // Syntactically constant-looking (the emit-time fold gate): literals, consts, and closed
    // expressions over them -- anything else makes an eval attempt pure waste.
    fn maybe_const(self: &Self, id: NodeId) bool {
        if id == NODE_NONE {
            return true;
        }
        let n = *self.f.node(id);
        let k = n.kind;
        if k == NodeKind::NODE_LITERAL || k == NodeKind::NODE_SIZEOF || k == NodeKind::NODE_ALIGNOF {
            return true;
        }
        if k == NodeKind::NODE_BINARY {
            return self.maybe_const(n.as_data.binary.left) && self.maybe_const(n.as_data.binary.right);
        }
        if k == NodeKind::NODE_UNARY {
            return self.maybe_const(n.as_data.unary.operand);
        }
        if k == NodeKind::NODE_CAST {
            return self.maybe_const(n.as_data.cast.expression);
        }
        if k == NodeKind::NODE_INDEX {
            return self.maybe_const(n.as_data.index.object) && self.maybe_const(n.as_data.index.index);
        }
        if k == NodeKind::NODE_CALL {
            if !self.maybe_const(n.as_data.call.callee) {
                return false;
            }
            for i in 0..n.as_data.call.args.len {
                if !self.maybe_const(unsafe self.f.list(n.as_data.call.args)[i as usize]) {
                    return false;
                }
            }
            return true;
        }
        if k == NodeKind::NODE_IDENTIFIER || k == NodeKind::NODE_MEMBER && n.as_data.member.path {
            let d = self.path_res(id);
            if d.node == NODE_NONE {
                return true;
            }
            let dk = self.decl_kind(d);
            if dk == NodeKind::NODE_FUNCTION || dk == NodeKind::NODE_VARIANT {
                return true;
            }
            if dk == NodeKind::NODE_CONST {
                let da = unsafe &*(&*self.pkg).module_ast_const(d.module);
                let cd = da.at_const(d.node).as_data.const_def;
                return cd.value != NODE_NONE && !cd.is_static_mut;
            }
            return false;
        }
        return false;
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
        let ty = self.nty(id);
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
    fn item_value(self: &mut Self, id: NodeId, d0: DefId, ty: TypeId, sp: tok::Span) ir::OperandId {
        let mut d = d0;
        // An unresolved member on a resolved ENUM object: member resolution is the checker's act,
        // so a not-yet-checked module's `E::V` (a const initializer demanded early) finds the
        // variant from the object and the member's name.
        if (d.node == NODE_NONE || self.decl_kind(d) == NodeKind::NODE_ENUM) && self.f.node(id).kind == NodeKind::NODE_MEMBER && self.f.node(
            id,
        ).as_data.member.path {
            let md0 = self.f.node(id).as_data.member;
            let mut od = self.f.res(md0.object);
            if od.node == NODE_NONE && self.decl_kind(d) == NodeKind::NODE_ENUM {
                od = d;
            }
            if od.node != NODE_NONE && self.decl_kind(od) == NodeKind::NODE_ENUM {
                let ea = unsafe &*(&*self.pkg).module_ast_const(od.module);
                let esrc = unsafe (&*self.pkg).modules.at(od.module as usize).source.as_str();
                let mn = self.f.node(md0.member).as_data.name.text;
                let mtxt = self.src.slice(mn.start as usize, mn.end as usize);
                let ms0 = ea.at_const(od.node).as_data.aggregate.members;
                for vi0 in 0..ms0.len {
                    let vid0 = unsafe ea.list(ms0)[vi0 as usize];
                    if ea.at_const(vid0).kind != NodeKind::NODE_VARIANT {
                        continue;
                    }
                    let vn0 = ea.at_const(ea.at_const(vid0).as_data.variant.name).as_data.name.text;
                    if esrc.slice(vn0.start as usize, vn0.end as usize) == mtxt {
                        d = DefId { module: od.module, node: vid0 };
                        break;
                    }
                }
            }
        }
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
            let argv = self.avget();
            let ru9 = self.finish_aggregate(ir::AGG_VARIANT, d, &argv, ty, sp);
            self.avput(argv);
            return ru9;
        }
        let l = self.item_local(d, ty, sp);
        let pl = self.place_of_local(l);
        return self.copy_op(pl);
    }

    const fn decl_kind(self: &Self, d: DefId) NodeKind {
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
        // `unsafe expr` / `move expr` wrap a place without changing it; peel before shaping.
        if self.f.node(id).kind == NodeKind::NODE_UNARY {
            let uop = self.f.node(id).as_data.unary.op;
            if uop == tt::TokenType::Unsafe || uop == tt::TokenType::Move {
                if uop == tt::TokenType::Unsafe {
                    self.note_unsafe(id);
                }
                let inner = self.f.node(id).as_data.unary.operand;
                return self.lower_place(inner);
            }
        }
        let k = self.f.node(id).kind;
        let ty = self.nty(id);
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
            let md0 = self.f.node(id).as_data.member;
            if !md0.path && md0.object != NODE_NONE && self.f.node(md0.object).kind == NodeKind::NODE_IDENTIFIER {
                let blid = unsafe (&*self.f.ast).resolution(md0.object);
                if blid != NODE_NONE && self.f.node(blid).kind == NodeKind::NODE_INLINE_FOR && self.proj_frame_of(blid) >= 0 {
                    // an ACTIVE copy frame resolves the binder member; the frameless (symbolic
                    // owner) pre-pass lowers it as a plain member -- that body is never emitted
                    return self.lower_proj_member_place(id, blid);
                }
            }
            return self.lower_member_place(id);
        }
        if k == NodeKind::NODE_INDEX {
            return self.lower_index_place(id);
        }
        if k == NodeKind::NODE_UNARY && self.f.node(id).as_data.unary.op == tt::TokenType::Star {
            let mut base = self.lower_place_or_spill(self.f.node(id).as_data.unary.operand);
            if base == ir::IR_NONE {
                return ir::IR_NONE;
            }
            // `*x` on a Deref type calls the recorded impl (exactly as `x.method()` does); the
            // call's type is the impl's declared `&Target` return
            let du = self.f.derefs(id);
            if du != null {
                let steps = unsafe du.n;
                for s in 0..steps {
                    let m = unsafe du.method[s as usize];
                    let rt = unsafe du.recv[s as usize];
                    if m.node != NODE_NONE {
                        let mut rt2 = self.deref_ret_ty(m, self.body.places.at(base as usize).ty);
                        if rt2 == TYPE_NONE {
                            rt2 = rt;
                        }
                        let rop = self.copy_op(base);
                        let start = self.body.oper_pool.len() as u32;
                        self.body.oper_pool.push(rop);
                        let res = self.emit_call(m, ir::IR_NONE, start, 1, 0, 0, rt2, sp);
                        if res == ir::IR_NONE {
                            return ir::IR_NONE;
                        }
                        base = self.spill(res, sp);
                    } else {
                        base = self.place_project(base, ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: rt });
                    }
                }
            }
            return self.place_project(base, ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: ty });
        }
        // Any other expression used as a place: evaluate and spill.
        let op = self.lower_expr(id);
        if op == ir::IR_NONE {
            return ir::IR_NONE;
        }
        if k == NodeKind::NODE_CALL {
            // a call-result temporary used as a place still OWNS its value: the dest temp is
            // the place, registered for scope-exit drop (a field read must not leak the owner)
            let o = *self.body.operands.at(op as usize);
            if o.kind == ir::OP_COPY || o.kind == ir::OP_MOVE {
                let pl0 = *self.body.places.at(o.data as usize);
                if pl0.proj_len == 0 && self.body.locals.at(pl0.base as usize).storage == ir::LS_TEMP {
                    let mut ld0 = *self.body.locals.at(pl0.base as usize);
                    ld0.decl = id; // drops key on a decl
                    self.body.locals.set(pl0.base as usize, ld0);
                    // scope-tracked WITHOUT a live marker: the value initialized before this
                    // point, and only the scope-end dead matters for drop elaboration
                    self.scope_locals.push(pl0.base);
                    return o.data;
                }
            }
        }
        return self.spill(op, sp);
    }

    fn lower_place_or_spill(self: &mut Self, id: NodeId) ir::PlaceId {
        return self.lower_place(id);
    }

    // The SUBSTITUTED `&Target` a deref impl returns for receiver type `recv` (self pool): the
    // declared `&T` with the enclosing extend's generics bound by the receiver instance's args.
    fn deref_ret_ty(self: &mut Self, m: DefId, recv: TypeId) TypeId {
        let fa = unsafe &*(&*self.pkg).module_ast_const(m.module);
        let fr = fa.at_const(m.node).as_data.function.returns;
        if fr.len == 0 {
            return TYPE_NONE;
        }
        let rtn = fa.type_of(unsafe fa.list(fr)[0]);
        if rtn == TYPE_NONE {
            return TYPE_NONE;
        }
        let rr = self.reintern_ty(m.module, rtn);
        let mut rv = recv;
        let mut g = 0;
        while g < 2 && self.f.ty(rv).kind == TypeKind::TYPE_REFERENCE {
            rv = self.f.ty(rv).as_data.elem;
            g += 1;
        }
        let y = *self.f.ty(rv);
        if y.kind != TypeKind::TYPE_INSTANCE {
            return rr;
        }
        let it = *self.f.instance(y.as_data.inst);
        let items = fa.at_const(fa.root).as_data.program.items;
        for i in 0..items.len {
            let nid = unsafe fa.list(items)[i as usize];
            if fa.at_const(nid).kind != NodeKind::NODE_EXTEND {
                continue;
            }
            let ms = fa.at_const(nid).as_data.extend_def.items;
            let mut has = false;
            for j in 0..ms.len {
                if unsafe fa.list(ms)[j as usize] == m.node {
                    has = true;
                    break;
                }
            }
            if !has {
                continue;
            }
            let gens = fa.at_const(nid).as_data.extend_def.generics;
            let mut n = gens.len;
            if n > it.n as u32 {
                n = it.n;
            }
            return self.proj_ty_map(rr, m.module, gens, &it.args[0], n);
        }
        return rr;
    }

    fn lower_member_place(self: &mut Self, id: NodeId) ir::PlaceId {
        let d = self.f.node(id).as_data.member;
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        if d.path {
            // Path member (Enum::Variant, Type::CONST): an item, not a projection. A static
            // resolves to its OWN place (writes must reach the global, never a spilled copy).
            let pd = self.path_res(id);
            if pd.node != NODE_NONE && self.decl_kind(pd) == NodeKind::NODE_CONST {
                let l2 = self.item_local(pd, ty, sp);
                return self.place_of_local(l2);
            }
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
        // Auto-deref chain recorded on the member (coercions) or its NAME node (the field/method
        // Deref walk keys the chain on member.member): apply user/builtin derefs before the field.
        let mut du = self.f.derefs(id);
        if du == null {
            du = self.f.derefs(d.member);
        }
        if du != null {
            let steps = unsafe du.n;
            for s in 0..steps {
                let m = unsafe du.method[s as usize];
                let rt = unsafe du.recv[s as usize];
                if m.node != NODE_NONE {
                    let mut rt2 = self.deref_ret_ty(m, self.body.places.at(base as usize).ty);
                    if rt2 == TYPE_NONE {
                        rt2 = rt;
                    }
                    let rop = self.copy_op(base);
                    let start = self.body.oper_pool.len() as u32;
                    self.body.oper_pool.push(rop);
                    let res = self.emit_call(m, ir::IR_NONE, start, 1, 0, 0, rt2, sp);
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
        // Union members overlap: the marker data value makes place conflicts treat every field
        // pair of the same union as the same storage.
        let mut fdata = ir::IR_NONE;
        let mut fsub = fd.node;
        {
            let bty2 = self.body.places.at(base as usize).ty;
            if bty2 != TYPE_NONE {
                let y = *self.f.ty(bty2);
                let mut dm: ModuleId = 0;
                let mut dn = NODE_NONE;
                if y.kind == TypeKind::TYPE_STRUCT {
                    dm = y.module;
                    dn = y.as_data.decl;
                } else if y.kind == TypeKind::TYPE_INSTANCE {
                    let it = *self.f.instance(y.as_data.inst);
                    dm = it.module;
                    dn = it.decl;
                }
                if dn != NODE_NONE {
                    let da = unsafe &*(&*self.pkg).module_ast_const(dm);
                    let nd = da.at_const(dn);
                    if nd.kind == NodeKind::NODE_STRUCT && nd.as_data.aggregate.is_union {
                        fdata = ir::PJ_UNION_FIELD;
                    } else if nd.kind == NodeKind::NODE_STRUCT && nd.as_data.aggregate.is_tuple {
                        // tuple member: the resolution pins the positional TYPE node, not a NODE_FIELD;
                        // emit it as `._<index>` from its ordinal in the member list
                        let ms = nd.as_data.aggregate.members;
                        for mi in 0..ms.len {
                            if unsafe da.list(ms)[mi as usize] == fd.node {
                                fsub = NODE_NONE;
                                fdata = mi;
                                break;
                            }
                        }
                    }
                }
            }
        }
        return self.place_project(base, ir::Projection { kind: ir::PJ_FIELD, data: fdata, sub: fsub, ty: ty });
    }

    // ---- bounds-check normalization (plans/1_bounds_check_elimination.md) ------------------------

    /// The base type behind up to three reference wrappers (types only; no place is built).
    fn peeled_view_ty(self: &mut Self, base: ir::PlaceId) TypeId {
        let mut ty = self.body.places.at(base as usize).ty;
        let mut guard = 0;
        while guard < 3 && ty != TYPE_NONE {
            let y = *self.f.ty(ty);
            if y.kind != TypeKind::TYPE_REFERENCE {
                break;
            }
            ty = y.as_data.elem;
            guard += 1;
        }
        return ty;
    }

    /// The prelude view decls, resolved on first use and cached for the Lowerer's lifetime.
    fn view_decls(self: &mut Self) ViewDecls {
        if !self.views.ok {
            let pk = unsafe &*self.pkg;
            let hs = pk.prelude_lookup("str", true);
            let hl = pk.prelude_lookup("Slice", true);
            let hm = pk.prelude_lookup("SliceMut", true);
            let hv = pk.prelude_lookup("Vector", true);
            let hg = pk.prelude_lookup("String", true);
            let ha = pk.prelude_lookup("Array", true);
            self.views = ViewDecls {
                ok: true,
                v_str: DefId { module: hs.mid, node: hs.node },
                v_slice: DefId { module: hl.mid, node: hl.node },
                v_slice_mut: DefId { module: hm.mid, node: hm.node },
                v_vector: DefId { module: hv.mid, node: hv.node },
                v_string: DefId { module: hg.mid, node: hg.node },
                v_array: DefId { module: ha.mid, node: ha.node },
            };
        }
        return self.views;
    }

    /// True for the prelude length-carrying views whose safe access carries an explicit Core IR
    /// check: Slice, SliceMut, Vector, String, and `str`. Raw arrays are const-checked by the
    /// typechecker (dynamic raw indexing is `unsafe`); raw pointers never gain a safe-access claim.
    fn checked_view(self: &mut Self, ty: TypeId) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let y = *self.f.ty(ty);
        if y.kind == TypeKind::TYPE_STRUCT {
            let v = self.view_decls();
            return vd_is(v.v_str, y.as_data.decl, y.module);
        }
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = *self.f.instance(y.as_data.inst);
        let v = self.view_decls();
        return vd_is(v.v_slice, it.decl, it.module) || vd_is(v.v_slice_mut, it.decl, it.module) || vd_is(
            v.v_vector,
            it.decl,
            it.module,
        ) || vd_is(v.v_string, it.decl, it.module);
    }

    /// True for the prelude `Array<T, N>` instance (fixed length; range-validated like a view).
    fn array_view(self: &mut Self, ty: TypeId) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let y = *self.f.ty(ty);
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = *self.f.instance(y.as_data.inst);
        let v = self.view_decls();
        return vd_is(v.v_array, it.decl, it.module);
    }

    /// The place RV_LEN reads for a check: the view itself, reached through any reference
    /// wrappers. Only the length read derefs; the access projection keeps its original shape.
    fn view_len_place(self: &mut Self, base: ir::PlaceId) ir::PlaceId {
        let mut pl = base;
        let mut guard = 0;
        while guard < 3 {
            let ty = self.body.places.at(pl as usize).ty;
            if ty == TYPE_NONE {
                break;
            }
            let y = *self.f.ty(ty);
            if y.kind != TypeKind::TYPE_REFERENCE {
                break;
            }
            let el = y.as_data.elem;
            pl = self.place_project(pl, ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: el });
            guard += 1;
        }
        return pl;
    }

    /// `t = IN_BOUNDS(index, len)` against an already-materialized length operand. Returns the
    /// temp place holding the checked index; the caller addresses through it (dynamic index) or
    /// discards it (constant index, which keeps PJ_INDEX_CONST for place disjointness).
    fn bounds_check_len(self: &mut Self, iop: ir::OperandId, lop: ir::OperandId, sp: tok::Span) ir::PlaceId {
        let ut = Ast::builtin(BuiltinType::BT_USIZE);
        let start = self.body.oper_pool.len() as u32;
        self.body.oper_pool.push(iop);
        self.body.oper_pool.push(lop);
        let ct = self.temp(ut, sp);
        let cpl = self.place_of_local(ct);
        self.assign(
            cpl,
            ir::Rvalue {
                kind: ir::RV_INTRINSIC,
                a: start,
                b: 2,
                c: ir::IN_BOUNDS,
                target: ut,
                item: DefId { module: 0, node: NODE_NONE },
            },
            sp,
        );
        return cpl;
    }

    /// Materialize `RV_LEN(view)` into a temp and return its place.
    fn len_temp(self: &mut Self, view: ir::PlaceId, sp: tok::Span) ir::PlaceId {
        let ut = Ast::builtin(BuiltinType::BT_USIZE);
        let ll = self.temp(ut, sp);
        let lpl = self.place_of_local(ll);
        self.assign(
            lpl,
            ir::Rvalue { kind: ir::RV_LEN, a: view, b: 0, c: 0, target: ut, item: DefId { module: 0, node: NODE_NONE } },
            sp,
        );
        return lpl;
    }

    /// `t = IN_BOUNDS(index, RV_LEN(view))`: the explicit element check.
    fn bounds_check(self: &mut Self, view: ir::PlaceId, iop: ir::OperandId, sp: tok::Span) ir::PlaceId {
        let lpl = self.len_temp(view, sp);
        let lop = self.copy_op(lpl);
        return self.bounds_check_len(iop, lop, sp);
    }

    fn lower_index_place(self: &mut Self, id: NodeId) ir::PlaceId {
        let d = self.f.node(id).as_data.index;
        let ty = self.nty(id);
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
        if self.f.node(d.index).kind == NodeKind::NODE_RANGE {
            // `s[lo..hi]` slicing stays STRUCTURAL: bounds lower directly (start first), so
            // end-openness survives without a Range value
            let rd = self.f.node(d.index).as_data.pattern_range;
            let mut sop = ir::IR_NONE;
            if rd.start != NODE_NONE {
                sop = self.lower_expr(rd.start);
                if sop == ir::IR_NONE {
                    return ir::IR_NONE;
                }
            }
            let mut eop = ir::IR_NONE;
            if rd.end != NODE_NONE {
                eop = self.lower_expr(rd.end);
                if eop == ir::IR_NONE {
                    return ir::IR_NONE;
                }
            }
            let mut fl: u8 = 0;
            if rd.inclusive {
                fl = 1;
            }
            self.tp(ir::TP_SLICE, 0, id);
            // Range validation (bounds-check normalization): materialize the length, prove
            // `start <= end <= len` BEFORE any pointer arithmetic, and hand RV_SLICE the
            // validated EXCLUSIVE end. An inclusive end first proves `end < len`, so `end + 1`
            // cannot overflow. Bases outside the known safe views keep the legacy operands.
            let pvt = self.peeled_view_ty(base);
            let is_arr = pvt != TYPE_NONE && self.f.ty(pvt).kind == TypeKind::TYPE_ARRAY;
            if self.checked_view(pvt) || is_arr || self.array_view(pvt) {
                let ut = Ast::builtin(BuiltinType::BT_USIZE);
                let vbase = self.view_len_place(base);
                let lpl = self.len_temp(vbase, sp);
                if sop == ir::IR_NONE {
                    sop = self.const_op(
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
                }
                let mut excl = eop;
                if eop == ir::IR_NONE {
                    excl = self.copy_op(lpl);
                } else if rd.inclusive {
                    let lop0 = self.copy_op(lpl);
                    let ck = self.bounds_check_len(eop, lop0, sp);
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
                    let ckop = self.copy_op(ck);
                    let et = self.temp(ut, sp);
                    let etpl = self.place_of_local(et);
                    self.assign(
                        etpl,
                        ir::Rvalue {
                            kind: ir::RV_BINARY,
                            a: ckop,
                            b: one,
                            c: tt::TokenType::Plus as u8,
                            target: ut,
                            item: DefId { module: 0, node: NODE_NONE },
                        },
                        sp,
                    );
                    excl = self.copy_op(etpl);
                }
                let lop1 = self.copy_op(lpl);
                let start = self.body.oper_pool.len() as u32;
                self.body.oper_pool.push(sop);
                self.body.oper_pool.push(excl);
                self.body.oper_pool.push(lop1);
                let vt = self.temp(ut, sp);
                let vtpl = self.place_of_local(vt);
                self.assign(
                    vtpl,
                    ir::Rvalue {
                        kind: ir::RV_INTRINSIC,
                        a: start,
                        b: 3,
                        c: ir::IN_RANGE_BOUNDS,
                        target: ut,
                        item: DefId { module: 0, node: NODE_NONE },
                    },
                    sp,
                );
                eop = self.copy_op(vtpl);
                fl = 0;
            }
            let t = self.temp(ty, sp);
            let pl = self.place_of_local(t);
            self.assign(
                pl,
                ir::Rvalue {
                    kind: ir::RV_SLICE,
                    a: base,
                    b: sop,
                    c: fl,
                    target: ty,
                    item: DefId { module: 0, node: eop },
                },
                sp,
            );
            return pl;
        }
        let iop = self.lower_expr(d.index);
        if iop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        // A plain-decimal constant index keeps its value in the projection: `a[0]` and `a[1]` name
        // disjoint storage, so simultaneous `&mut` borrows of distinct slots stay legal.
        {
            let op = *self.body.operands.at(iop as usize);
            if op.kind == ir::OP_CONST {
                let cn = *self.body.constants.at(op.data as usize);
                if cn.kind == ir::CK_INT && cn.raw.end > cn.raw.start {
                    let mut dec = true;
                    for i in cn.raw.start..cn.raw.end {
                        let ch = self.src[i as usize];
                        if ch < b'0' || ch > b'9' {
                            dec = false;
                        }
                    }
                    if dec && cn.val >= 0 {
                        if self.checked_view(self.peeled_view_ty(base)) {
                            let vb0 = self.view_len_place(base);
                            let _ = self.bounds_check(vb0, iop, sp);
                        }
                        return self.place_project(
                            base,
                            ir::Projection { kind: ir::PJ_INDEX_CONST, data: cn.val as u32, sub: 0, ty: ty },
                        );
                    }
                }
            }
        }
        let mut iop_use = iop;
        if self.checked_view(self.peeled_view_ty(base)) {
            let vb1 = self.view_len_place(base);
            let ck1 = self.bounds_check(vb1, iop, sp);
            iop_use = self.copy_op(ck1);
        }
        return self.place_project(base, ir::Projection { kind: ir::PJ_INDEX_OP, data: iop_use, sub: 0, ty: ty });
    }

    // ---- match ------------------------------------------------------------------------------------

    // Naive arm-order fallback lowering (guarded matches; the decision tree covers the rest): test each
    // arm's pattern; on success bind + run guard + body; else fall to the next arm.
    fn lower_match(self: &mut Self, id: NodeId, dest: ir::PlaceId) bool {
        let d = self.f.node(id).as_data.match_expr;
        let sp = self.f.node(id).span;
        self.tp(ir::TP_MARK_PUSH, 0, id);
        let vop = self.lower_expr(d.value);
        if vop == ir::IR_NONE {
            return false;
        }
        let sty = self.nty(d.value);
        if sty != TYPE_NONE {
            let sk = self.f.ty(sty).kind;
            if sk != TypeKind::TYPE_REFERENCE && sk != TypeKind::TYPE_POINTER {
                self.mark_user_move(vop); // by-value scrutinee consumes like any other user move
            }
        }
        let vpl = self.spill(vop, sp);
        let ax9: u32 = if dest != ir::IR_NONE {
            1;
        } else {
            0;
        };
        self.tp(ir::TP_MATCH_PRE, ax9, id);
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
                self.tp(ir::TP_MATCH_POST, 0, id);
                return self.err.len() == 0;
            }
        }
        let join = self.open_block();
        for i in 0..d.arms.len {
            let arm = unsafe self.f.list(d.arms)[i as usize];
            let ad = self.f.node(arm).as_data.match_arm;
            let next_arm = self.open_block();
            self.scope_enter();
            self.tp(ir::TP_ARM, i, arm);
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
            self.tp(ir::TP_ARM_END, i, arm);
            self.scope_exit();
            if self.err.len() != 0 {
                return false;
            }
            self.seal(self.goto_term(join, sp), next_arm);
        }
        self.tp(ir::TP_MATCH_POST, 0, id);
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
        // the C tag carries a bare enum's explicit discriminant, not its ordinal
        let ord_op = self.const_op(
            ir::Constant {
                kind: ir::CK_INT,
                ty: ut,
                val: self.tag_of_decl(vd.module, en, ord),
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
                let mut fsub = NODE_NONE;
                if fpd.name != NODE_NONE {
                    let fd = self.f.res(fpd.name);
                    // only a real FIELD decl names the member; anything else is positional `._i`
                    if fd.node != NODE_NONE && self.decl_kind(fd) == NodeKind::NODE_FIELD {
                        fsub = fd.node;
                    }
                }
                let fty = self.nty(subp);
                let fpl = self.place_project(base, ir::Projection { kind: ir::PJ_FIELD, data: i, sub: fsub, ty: fty });
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
                let pt = self.nty(path.pat);
                if pt != TYPE_NONE {
                    ty = pt;
                }
            }
            if path.downcast >= 0 {
                let bty = self.body.places.at(base as usize).ty;
                // the VARIANT's declared payload entry is the member's authoritative type (the
                // pattern node may carry the ENUM via expected-type spill)
                let pt2 = self.proj_payload_ty(bty, path.downcast, path.field);
                if pt2 != TYPE_NONE {
                    ty = pt2;
                }
                base = self.place_project(
                    base,
                    ir::Projection { kind: ir::PJ_DOWNCAST, data: path.downcast as u32, sub: path.vdecl.node, ty: bty },
                );
            }
            let mut fsub2 = path.fdecl;
            if fsub2 != NODE_NONE {
                let fdk = self.decl_kind(DefId { module: self.module, node: fsub2 });
                if fdk != NodeKind::NODE_FIELD {
                    fsub2 = NODE_NONE; // positional payload member: `._i`
                }
            }
            base = self.place_project(base, ir::Projection { kind: ir::PJ_FIELD, data: path.field, sub: fsub2, ty: ty });
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
                    let fty = self.nty(subp);
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
            // the C tag carries a bare enum's explicit discriminant, not its ordinal
            let mut own = self.body.places.at(pl as usize).ty;
            let mut pg = 0;
            while k0 == pat::PC_VARIANT && pg < 4 {
                let yk = self.f.ty(own).kind;
                if yk != TypeKind::TYPE_REFERENCE && yk != TypeKind::TYPE_POINTER {
                    break;
                }
                own = self.f.ty(own).as_data.elem;
                pg += 1;
            }
            for e in 0..pairs {
                let ep = cx.pats.at(t.edges.at((n.edge_start + e) as usize).pat as usize);
                let cv: i64 = if k0 == pat::PC_VARIANT {
                    self.proj_tag_val(own, ep.val);
                } else {
                    ep.val;
                };
                self.body.switch_pool.push((cv as u64 & 0xFFFFFFFF) << 32 | blocks[e as usize] as u64);
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
            let arm9 = unsafe self.f.list(d.arms)[i as usize];
            let ad = self.f.node(arm9).as_data.match_arm;
            // Arm bindings live in the arm's own scope: payload storage ends at the arm's end.
            self.scope_enter();
            self.tp(ir::TP_ARM, i, arm9);
            self.pattern_bind_total(ad.pattern, vpl);
            if dest != ir::IR_NONE {
                self.lower_value_into(ad.body, dest);
            } else {
                self.lower_stmt(ad.body);
            }
            self.tp(ir::TP_ARM_END, i, arm9);
            self.scope_exit();
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
    const fn pattern_bound(self: &Self, b: NodeId) NodeId {
        if self.f.node(b).kind == NodeKind::NODE_PATTERN_LITERAL {
            return self.f.node(b).as_data.single.value;
        }
        return b;
    }

    fn tuple_field(self: &mut Self, base: ir::PlaceId, i: u32, c: NodeId) ir::PlaceId {
        let mut cty = self.nty(c);
        // behind a DOWNCAST the pattern node's type may carry the ENUM (expected-type spill):
        // the VARIANT's declared payload entry is the authoritative member type
        let bp = *self.body.places.at(base as usize);
        if bp.proj_len != 0 {
            let lp = *self.body.projections.at((bp.proj_start + bp.proj_len - 1) as usize);
            if lp.kind == ir::PJ_DOWNCAST {
                let pt = self.proj_payload_ty(lp.ty, lp.data, i);
                if pt != TYPE_NONE {
                    cty = pt;
                }
            }
        }
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
        self.user_local_live(l, sp);
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
// The code point of a `'x'` / `b'x'` literal (the pattern matrix owns the decode rules).
fn decode_char(src: str, sp: tok::Span) i64 {
    return pat::char_of(src, sp).unwrap_or(0);
}

// An integer literal's exact magnitude (dec/hex, `_` separators, [iu]NN suffix stripped);
// false when the spelling is not a plain integer or overflows i64.
fn lit_int_value(src: str, sp: tok::Span, out: &mut i64) bool {
    let mut i = sp.start as usize;
    let mut e = sp.end as usize;
    if e > src.len() || e <= i {
        return false;
    }
    // strip a type suffix: trailing [iu] digits
    let mut k = i;
    while k < e {
        let b = src[k];
        if b == b'i' || b == b'u' {
            let mut j = k + 1;
            let mut dig = true;
            while j < e {
                if src[j] < b'0' || src[j] > b'9' {
                    dig = false;
                    break;
                }
                j += 1;
            }
            if dig && j == e && k > i {
                e = k;
                break;
            }
        }
        k += 1;
    }
    let hex = e - i > 2 && src[i] == b'0' && (src[i + 1] | 32) == b'x';
    if hex {
        i += 2;
    }
    let mut v: i64 = 0;
    let mut any = false;
    while i < e {
        let b = src[i];
        if b == b'_' {
            i += 1;
            continue;
        }
        let mut dv: i64 = -1;
        if b >= b'0' && b <= b'9' {
            dv = b - b'0';
        } else if hex && (b | 32) >= b'a' && (b | 32) <= b'f' {
            dv = (b | 32) - b'a' + 10;
        }
        if dv < 0 {
            return false;
        }
        if hex {
            if v > 576460752303423487 {
                return false;
            }
            v = v * 16 + dv;
        } else {
            if v > 922337203685477579 {
                return false;
            }
            v = v * 10 + dv;
        }
        any = true;
        i += 1;
    }
    if !any {
        return false;
    }
    *out = v;
    return true;
}

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
