// Typed AST -> Core IR lowering. Consumes ONLY the typed-facts boundary
// (ast::facts) plus syntax structure and source spans; every semantic decision (types, resolutions,
// call targets, operator methods, coercions, deref chains, dyn erasures) is read from the recorded
// facts, never re-derived (a `for` loop's `next` method is the checker's recorded call target).
//
// Evaluation order:
//   - receiver before call arguments; arguments left to right
//   - short-circuit && and || evaluate the right operand only on the deciding path
//   - assignment evaluates the target place FIRST, then the value (C order the emitter relies on)
//   - aggregate fields and array elements in source order
//   - match: scrutinee once, then per-arm tests in arm order, guard after bindings, body last
//   - `defer` bodies run LIFO at every scope exit (return, break, continue, block end)
//   - multi-return destinations are written in declaration order at the call
//
// A body that reaches a construct the lowerer does not support fails with a reason string; the
// driver's SC_CORE_IR mode counts the reasons.
import lexer::token as tok;
import lexer::token_type as tt;
import ast::ast as *;
import ast::facts as facts;
import module::loader as loader;
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
    pub defer_depth: usize, // defers deeper than this run before `continue`
    pub brk_defer_depth: usize, // defers deeper than this run before `break` (<= defer_depth)
    pub locals_depth: usize, // scope locals deeper than this end their storage before leaving
    pub result: ir::PlaceId, // `break value` destination for loop expressions; IR_NONE when none
}

/// The elements of consumed array `arr` after index `idx` (`idx + 1 .. len`): freed at every exit
/// of a by-value `for` over the array. A `defers` entry tagged DEFER_TAIL names one by index.
struct TailDrop {
    pub arr: ir::PlaceId,
    pub idx: ir::PlaceId,
    pub len: ir::PlaceId,
    pub elem: TypeId,
    pub span: tok::Span,
}

/// Tag bit of a `defers` entry that is a TailDrop index, not a defer statement node.
const DEFER_TAIL: NodeId = 0x80000000u32;

/// The widest integer pattern piece whose values a match switch lists as cases, and the most cases
/// of one switch: wider pieces keep their comparison.
const SW_PIECE_MAX: i64 = 256;
const SW_CASES_MAX: i64 = 1024;
/// The deepest expression nesting the argument-order walk follows (`may_write`): deeper, an
/// argument is assumed to write.
const WALK_MAX: u32 = 64;

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
}

// The nodes whose value an `if`, `switch` or value-block arm yields as the whole expression's value:
// the arm (`arm`), its value (`val`: the arm itself or its block's tail) and the operand of a `&`
// that is the value (`rf`). A temporary one of them borrows (an array viewed as a slice, a `&`
// operand) lives in the scope around the expression, as it would without the arms: `depth` scopes
// are open there (EXT_NONE: no arm is being lowered).
struct ExtCx {
    pub arm: NodeId,
    pub val: NodeId,
    pub rf: NodeId,
    pub depth: u32,
}

const EXT_NONE: u32 = 0xFFFFFFFFu32;

// The result of a lowering given a destination (`lower_into`) that stored its value there: no
// operand reads it, since a temp and a copy are what the destination saves. Never an OperandId.
const WROTE: ir::OperandId = 0xFFFFFFFEu32;

const fn ext_none() ExtCx {
    return ExtCx { arm: NODE_NONE, val: NODE_NONE, rf: NODE_NONE, depth: EXT_NONE };
}

const fn vd_none() DefId {
    return DefId { module: 0, node: NODE_NONE };
}

const fn vd_is(d: DefId, decl: NodeId, m: ModuleId) bool {
    return d.node != NODE_NONE && d.node == decl && d.module == m;
}

// `Lowerer.err` when lowering met a TYPE_ERROR node or generic argument.
const ERR_TYPE_SLUG: str<'static> = "error type";
const ERR_UNSEEN: str<'static> = "a declaration the reader does not see checked";

/// `Lowerer.err` for a call of an `@intrinsic` this compiler does not know, which only
/// `--bootstrap-tags` accepts: the newer compiler that knows it checks the body.
pub const UNKNOWN_INTRINSIC_SLUG: str<'static> = "an intrinsic this compiler does not know";

// The `data` of a member projection: IR_NONE for a named field (its identity is the decl in
// `sub`, as a member access spells it), else the positional index.
const fn member_data(sub: NodeId, index: u32) u32 {
    if sub != NODE_NONE {
        return ir::IR_NONE;
    }
    return index;
}

pub struct Lowerer {
    pub f: facts::TypedFacts,
    pub pkg: *const loader::Package,
    pub module: ModuleId,
    pub src: str<'static>,
    pub body: ir::CoreBody,
    pub err: str<'static>, // first unsupported-construct reason ("" = ok)
    pub err_node: NodeId, // the node that failed (diagnostic snippet in the SC_CORE_IR report)
    /// A program error found while lowering an instance (NODE_NONE when none): a vector index list
    /// that does not evaluate there, or names a lane past its operands (`user_msg`). The lowering goes
    /// on, the list reading lane 0, as a failed per-instance static_assert does; the emitter reports
    /// it, and the evaluator refuses the body with it.
    pub user_err: NodeId,
    pub user_msg: str<'static>,
    /// The instance env for substitution-aware lowering (reflection expansion needs the CONCRETE
    /// owner); empty for the shared generic pre-pass.
    pub env: Vector<LSub>,
    // The index-list argument of the vector operation call being lowered (`index_op`).
    list_node: NodeId,
    proj_frames: Vector<ProjFrame>,
    binds: Vector<Binding>,
    bind_ix: Map<NodeId, ir::LocalId>, // decl -> its latest local in `binds`
    loops: Vector<LoopCtx>,
    defers: Vector<NodeId>, // active defer statement nodes (or DEFER_TAIL entries), innermost last
    tail_drops: Vector<TailDrop>,
    scope_defers: Vector<usize>, // per open scope: defers length at entry
    scope_locals: Vector<ir::LocalId>, // user locals per scope, in declaration order
    scope_local_marks: Vector<usize>, // per open scope: scope_locals length at entry
    ext: ExtCx, // the value arm being lowered: its borrowed temporaries' scope
    // `local << 32 | source place` per by-value pattern binding, in binding order: a guarded arm
    // hands its bindings back to the scrutinee on the guard's failure edge.
    moved_binds: Vector<u64>,
    item_keys: Vector<u64>, // the `item_ix` keys of this body
    item_ix: Map<u64, ir::LocalId>, // module << 32 | decl node -> its cached LS_STATIC_REF local
    pub closures: Vector<NodeId>, // closure nodes queued for their own lowering
    pub mut_binds: Vector<NodeId>, // decls mutated in this CLOSURE body (walk's mut_caps peel)
    pub unsafe_spans: Vector<u64>, // start<<32|end per unsafe expr; licenses the IR free-move rules
    pub tape: Vector<u64>, // borrowck replay events (ir::TP_*), in walk order; muted inside desugars
    tape_mute: u32,
    in_defer: u32, // lowering a defer body (an exit path): cancellation checks are masked there
    free_mask: bool, // a `Free::free` body that can accept a cancellation: it runs masked
    // The clean nodes of the open root (`chk_nodes[chk_base..]`, see `chk_open`): the calls among
    // them may carry a cancellation check. Any other call is evaluated with pending sibling
    // temporaries (evaluated arguments, a left operand) that the ladder cannot see.
    chk_nodes: Vector<NodeId>,
    chk_base: usize,
    // The first local of the open root (saved per nesting in `chk_lbases`): the temporaries from it
    // on are the ones a call's sibling operands may still hold (`poison_check_at`).
    chk_lbase: u32,
    chk_lbases: Vector<u32>,
    // A std::parallel body: its primitives report cancellation through their results and clean up
    // raw resources after a failed wait, so only the call at the root of an expression statement or
    // a plain `let` carries a check there.
    chk_narrow: bool,
    // Depth of value blocks and value loops lowered in an unclean position: no root opens inside
    // them, and their loop safepoints take no cancellation ladder.
    chk_mask: u32,
    // The locals of the `let`s whose initializers are being lowered: registered in scope_locals but
    // still UNINITIALIZED on a cancel edge inside the initializer (a dead there is a drop-use that
    // poisons loan liveness across loop back edges), so every ladder skips them.
    pending_lets: Vector<ir::LocalId>,
    // The locals whose one definition the lowering knows, each with its rvalue: an immutable `let`
    // (`built_def`), a match scrutinee's temp, a fresh aggregate temp, an immutable pattern binding.
    // `place_variant` reads the variant of an enum value through them. The keys this body added.
    known: Map<ir::LocalId, ir::RvalueId>,
    known_keys: Vector<ir::LocalId>,
    // Per-body cache of the check-eligibility test (cancel pass ran, sugar items present, owner on
    // a coroutine stack, not the runtime module): 0 uncomputed, 1 off, 2 on.
    chk_on: u8,
    // The runtime's `cancel_after_wait`, resolved with the cache above: a call to it never carries a
    // check (see `maybe_cancel_check`).
    chk_caw_m: ModuleId,
    chk_caw_n: NodeId,
    // Combined-safepoint ladder sharing: sibling loops with the same live scope state jump to one
    // ladder block instead of each emitting their own defers-then-deads sequence.
    sp_ladder_b: u32, // 0xFFFFFFFF = none cached
    sp_ladder_locals: Vector<ir::LocalId>,
    sp_ladder_defers: Vector<NodeId>,
    sp_ladder_pending: Vector<ir::LocalId>,
    // Reusable u32 buffers (argument lists, match work lists): call/aggregate lowering builds one
    // per expression, so the pool keeps their capacity across the whole body and package.
    u32_pool: Vector<Vector<u32>>,
    views: ViewDecls,
    lay: lay::Svc, // layout queries of the open body (cleared per body: type ids change at publications)
    // The compile-time evaluation this lowering runs for (null: none): a foreign declaration's
    // record is read only where the reader sees its item checked (`checked_here`).
    ev: *const iri::Interp,
    /// The node whose item the reader does not see, when `checked_here` failed the lowering
    /// (`need_n` NODE_NONE otherwise): `Interp::lower_refused` records the refusal.
    pub need_m: ModuleId,
    pub need_n: NodeId,
    cur: ir::BlockId,
    run_start: u32, // statements index where the open block's run began
}

/// A finished lowering the package keeps: the Core IR body and the closure nodes it queued for
/// their own lowering. `Lowerer::take_kept` makes it a Lowerer again for the consumers that need one.
pub struct KeptBody {
    pub body: ir::CoreBody,
    pub closures: Vector<NodeId>,
}

extend KeptBody {
    /// A compact copy of a finished body and its closure list.
    pub fn copy(body: &ir::CoreBody, closures: &Vector<NodeId>) KeptBody {
        return KeptBody { body: ir::CoreBody::compact_from(body), closures: closures.clone() };
    }

    /// An empty record for body `owner` of module `m`: what a taken slot holds.
    pub fn empty(m: ModuleId, owner: NodeId) KeptBody {
        return KeptBody {
            body: ir::CoreBody::new(DefId { module: m, node: owner }, m),
            closures: Vector::<NodeId>::new(),
        };
    }
}

/// The function and closure bodies of module `m` of `p`: what the keep holds of it at most.
pub fn module_bodies(p: &loader::Package, m: usize) usize {
    if !p.modules.at(m).has_ast {
        return 0;
    }
    let a = unsafe &*p.module_ast_const(m as ModuleId);
    let nb9 = a.nodes.len();
    let mut n: usize = 0;
    for i in 0..a.nnodes() {
        let k = a.at_const(Ast::nth_id_n(nb9, i)).kind;
        if k == NodeKind::NODE_FUNCTION || k == NodeKind::NODE_CLOSURE {
            n += 1;
        }
    }
    return n;
}

/// Package-lifetime store of finished lowerings, keyed `skey_mix(0, module << 32 | owner)`:
/// borrowck adopts every body it lowers so the instance graph starts from these instead of
/// lowering the package a second time. Entries move out on first demand and never return.
pub struct Keep {
    pub ix: Map<u64, u64>,
    pub kept: Vector<KeptBody>,
    /// Read-only views outstanding (the interpreter's window from the borrow frontier to the
    /// constant pre-pass): while nonzero no body may move or be taken, and a body may be added
    /// only into reserved capacity (`reserve_bodies`), since a viewer holds pointers into `kept`.
    pub viewers: u32,
}

extend Keep {
    pub fn new() Keep {
        return Keep { ix: Map::<u64, u64>::new(), kept: Vector::<KeptBody>::new(), viewers: 0 };
    }

    /// Size `kept` for `n` bodies, the `module_bodies` of every module, at once, so the doubling
    /// chain does not churn multi-megabyte blocks through the allocator each build.
    pub fn reserve_bodies(self: &mut Self, n: usize) {
        self.kept.reserve(n);
    }

    /// The `kept` slot of the non-generic body `(module, node)`, or -1. Never a generic body: a
    /// caller without a substitution env cannot execute one.
    pub fn view(self: &Self, module: ModuleId, node: NodeId) i64 {
        let key = skey_mix(0, module as u64 << 32 | node as u64);
        switch self.ix.get(&key) {
            Some(v) => {
                if self.kept.at((*v) as usize).body.is_generic {
                    return -1;
                }
                return (*v) as i64;
            },
            None => {
                return -1;
            },
        };
    }

    /// Rewrite every kept body's types through the package's last publication; returns how many
    /// bodies had a map to apply.
    pub const fn remap_types(self: &mut Self, p: &loader::Package) usize {
        let mut n: usize = 0;
        for i in 0..self.kept.len() {
            let lw = self.kept.index_mut(i);
            let m = lw.body.module as usize;
            if m < p.pub_map.len() && p.pub_map.at(m).len() != 0 {
                lw.body.remap_types(p.pub_map.at(m));
                n += 1;
            }
        }
        return n;
    }

    /// Move every body of `other` in (first key wins, matching `put`); `other` is left empty.
    /// Slot order in `kept` is not load-bearing -- consumers index through `ix` by owner key.
    pub fn absorb(self: &mut Self, other: &mut Keep) {
        if self.viewers == 0 {
            self.kept.reserve(other.kept.len());
        } else {
            assert(self.kept.len() + other.kept.len() <= self.kept.capacity(), "a viewed keep never reallocates");
        }
        for i in 0..other.kept.len() {
            let d = other.kept.at(i).body.owner;
            let key = skey_mix(0, d.module as u64 << 32 | d.node as u64);
            if self.ix.contains_key(&key) {
                continue;
            }
            let moved = replace(other.kept.index_mut(i), KeptBody::empty(d.module, d.node));
            self.ix.insert(key, self.kept.len() as u64);
            self.kept.push(moved);
        }
    }

    pub fn put(self: &mut Self, src: &Lowerer) {
        assert(self.viewers == 0 || self.kept.len() < self.kept.capacity(), "a viewed keep never reallocates");
        let d = src.body.owner;
        let key = skey_mix(0, d.module as u64 << 32 | d.node as u64);
        if self.ix.contains_key(&key) {
            return;
        }
        self.ix.insert(key, self.kept.len() as u64);
        self.kept.push(KeptBody::copy(&src.body, &src.closures));
    }
}

// Decode call_info: (fmod << 40 | fdecl << 8 | skip).
pub const fn ci_module(v: u64) ModuleId {
    return (v >> 40) as ModuleId;
}
pub const fn ci_decl(v: u64) NodeId {
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
            src: sp,
            body: ir::CoreBody::new(DefId { module: module, node: owner }, module),
            err: "",
            err_node: NODE_NONE,
            user_err: NODE_NONE,
            user_msg: "",
            env: Vector::<LSub>::new(),
            list_node: NODE_NONE,
            proj_frames: Vector::<ProjFrame>::new(),
            binds: Vector::<Binding>::new(),
            bind_ix: Map::<NodeId, ir::LocalId>::new(),
            loops: Vector::<LoopCtx>::new(),
            defers: Vector::<NodeId>::new(),
            tail_drops: Vector::<TailDrop>::new(),
            scope_defers: Vector::<usize>::new(),
            scope_locals: Vector::<ir::LocalId>::new(),
            scope_local_marks: Vector::<usize>::new(),
            ext: ext_none(),
            moved_binds: Vector::<u64>::new(),
            item_keys: Vector::<u64>::new(),
            item_ix: Map::<u64, ir::LocalId>::new(),
            closures: Vector::<NodeId>::new(),
            mut_binds: Vector::<NodeId>::new(),
            unsafe_spans: Vector::<u64>::new(),
            tape: Vector::<u64>::new(),
            tape_mute: 0,
            in_defer: 0,
            free_mask: false,
            chk_nodes: Vector::<NodeId>::new(),
            chk_base: 0,
            chk_lbase: 0,
            chk_lbases: Vector::<u32>::new(),
            chk_narrow: false,
            chk_mask: 0,
            pending_lets: Vector::<ir::LocalId>::new(),
            known: Map::<ir::LocalId, ir::RvalueId>::new(),
            known_keys: Vector::<ir::LocalId>::new(),
            chk_on: 0,
            chk_caw_m: 0,
            chk_caw_n: NODE_NONE,
            sp_ladder_b: 0xFFFFFFFFu32,
            sp_ladder_locals: Vector::<ir::LocalId>::new(),
            sp_ladder_defers: Vector::<NodeId>::new(),
            sp_ladder_pending: Vector::<ir::LocalId>::new(),
            u32_pool: Vector::<Vector<u32>>::new(),
            lay: lay::Svc::new(pkg),
            views: ViewDecls {
                ok: false,
                v_str: vd_none(),
                v_slice: vd_none(),
                v_slice_mut: vd_none(),
                v_vector: vd_none(),
                v_string: vd_none(),
            },
            ev: null,
            need_m: 0,
            need_n: NODE_NONE,
            cur: 0,
            run_start: 0,
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

    /// The bytes a finished lowering keeps: the body's pools and the replay tape.
    pub const fn retained_bytes(self: &Self) u64 {
        return self.body.retained_bytes() + (self.tape.capacity() * 8) as u64;
    }

    /// Re-target a reused Lowerer at another module, keeping every pool's heap capacity: the
    /// instance graph lowers the whole package through one scratch Lowerer. Clears any staged
    /// instance `env` (scratch lowerings are always env-free).
    pub fn retarget(self: &mut Self, module: ModuleId) {
        let p = unsafe &*self.pkg;
        self.f = facts::TypedFacts::of(p.module_ast_const(module));
        self.module = module;
        let sp = p.modules.at(module as usize).source.as_str();
        self.src = sp;
        self.env.truncate(0);
    }

    /// A Lowerer holding the kept body in `slot` as its finished product, as if it had lowered
    /// it; the slot is left empty.
    pub fn take_kept(pkg: *const loader::Package, slot: &mut KeptBody) Lowerer {
        let d = slot.body.owner;
        let mut lw = Lowerer::new(pkg, d.module, d.node);
        lw.body = replace(&mut slot.body, ir::CoreBody::new(d, d.module));
        lw.closures = replace(&mut slot.closures, Vector::<NodeId>::new());
        return lw;
    }

    // Reset every per-body pool and cursor so one Lowerer lowers many bodies back to back, keeping
    // heap capacity. Module context (f/pkg/src) and a caller-staged instance `env` survive. A fresh
    // Lowerer passes through as a no-op, so single-use callers are unchanged.
    fn begin_body(self: &mut Self, owner: NodeId) {
        self.body.clear(DefId { module: self.module, node: owner }, self.module);
        self.err = "";
        self.err_node = NODE_NONE;
        self.user_err = NODE_NONE;
        self.need_n = NODE_NONE;
        self.list_node = NODE_NONE;
        self.proj_frames.truncate(0);
        // Remove only this body's keys: clearing the whole table would cost its capacity per body.
        for i in 0..self.binds.len() {
            self.bind_ix.remove(&self.binds[i].decl);
        }
        self.binds.truncate(0);
        self.loops.truncate(0);
        self.defers.truncate(0);
        self.tail_drops.truncate(0);
        self.scope_defers.truncate(0);
        self.scope_locals.truncate(0);
        self.scope_local_marks.truncate(0);
        self.moved_binds.truncate(0);
        for i in 0..self.item_keys.len() {
            self.item_ix.remove(&self.item_keys[i]);
        }
        self.item_keys.truncate(0);
        self.closures.truncate(0);
        self.mut_binds.truncate(0);
        self.unsafe_spans.truncate(0);
        self.tape.truncate(0);
        self.lay.reset();
        self.tape_mute = 0;
        self.in_defer = 0;
        self.free_mask = false;
        self.chk_nodes.truncate(0);
        self.chk_base = 0;
        self.chk_lbase = 0;
        self.chk_lbases.truncate(0);
        self.chk_narrow = loader::runtime_path(unsafe (&*self.pkg).modules.at(self.module as usize).path.as_str());
        self.chk_mask = 0;
        self.pending_lets.truncate(0);
        self.forget_known(0);
        self.chk_on = 0;
        self.sp_ladder_b = 0xFFFFFFFFu32;
        self.sp_ladder_locals.truncate(0);
        self.sp_ladder_defers.truncate(0);
        self.sp_ladder_pending.truncate(0);
        self.cur = 0;
        self.run_start = 0;
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

    @always_inline
    fn tp(self: &mut Self, k: u8, aux: u32, node: NodeId) {
        if self.tape_mute == 0 {
            self.tape.push(k as u64 << 56 | aux as u64 << 32 | node as u64);
        }
    }

    /// Move the events recorded at `[from..len)` to position `at`, sliding `[at..from)` right.
    /// Lets a construct whose CFG order differs from walk order (a do-while tail condition) record
    /// its events in place and land them where the replay expects them. No-op when nothing landed.
    /// Rotates in place: reversing both runs and then the whole range swaps their order.
    const fn tape_splice(self: &mut Self, at: usize, from: usize) {
        let n = self.tape.len();
        if from <= at || from >= n {
            return;
        }
        self.tape_reverse(at, from);
        self.tape_reverse(from, n);
        self.tape_reverse(at, n);
    }

    // Reverse the tape events in `[lo..hi)`.
    const fn tape_reverse(self: &mut Self, lo: usize, hi: usize) {
        let mut i = lo;
        let mut j = hi;
        while i + 1 < j {
            j -= 1;
            self.tape.swap(i, j);
            i += 1;
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
    @always_inline
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

    /// Whether lowering stopped at a node the checker rejected (TYPE_ERROR): its diagnostic is
    /// already reported, so a caller refusing the body reports nothing more.
    pub const fn failed_on_error_type(self: &Self) bool {
        return self.err == ERR_TYPE_SLUG;
    }

    const fn fail_at(self: &mut Self, why: str<'static>, node: NodeId) {
        if self.err.len() == 0 {
            self.err = why;
            self.err_node = node;
        }
    }

    /// Lower for compile-time evaluation `ev`: a declaration record of an item the reader does not see
    /// checked fails the lowering, and the evaluation runs again once the owner is checked.
    pub const fn read_for(self: &mut Self, ev: *const iri::Interp) {
        self.ev = ev;
        self.lay.ev = ev;
    }

    // Whether the reader sees the item that holds node `n` of module `m` checked (`Interp::visible_node`):
    // always outside an evaluation. An item of the reader's own component that follows it is not
    // checked yet, and another component's item may have another job writing it.
    fn seen_here(self: &Self, m: ModuleId, n: NodeId) bool {
        return self.ev == null || unsafe (&*self.ev).visible_node(m, n);
    }

    // Whether the checked record of node `n` of module `m` may be read (`seen_here`). Otherwise the
    // lowering fails and names the node for `Interp::lower_refused`: the body cache has no reader in
    // its key, so a lowering must not depend on the schedule.
    fn checked_here(self: &mut Self, m: ModuleId, n: NodeId) bool {
        if self.seen_here(m, n) {
            return true;
        }
        self.fail_at(ERR_UNSEEN, NODE_NONE);
        self.need_m = m;
        self.need_n = n;
        return false;
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
            self.body.blocks[b as usize].term = ir::term0(ir::TM_UNREACHABLE, sp);
            self.body.blocks[b as usize].sealed = true;
        }
    }

    fn stmt(self: &mut Self, s: ir::Statement) {
        self.body.statements.push(s);
    }

    fn assign(self: &mut Self, place: ir::PlaceId, rv: ir::Rvalue, sp: tok::Span) {
        self.body.push_assign(place, rv, sp);
    }

    // ---- small constructors -----------------------------------------------------------------------

    fn temp(self: &mut Self, ty: TypeId, sp: tok::Span) ir::LocalId {
        return self.body.add_local(self.local_decl(ty, ir::LS_TEMP, true, sp, NODE_NONE));
    }

    // Assign `rv` to a fresh temp of its result type and return the temp's place.
    fn rv_temp(self: &mut Self, rv: ir::Rvalue, sp: tok::Span) ir::PlaceId {
        let pl = self.place_of_local(self.temp(rv.target, sp));
        self.assign(pl, rv, sp);
        if rv.kind == ir::RV_AGGREGATE && rv.c != ir::AGG_ARRAY {
            self.note_known(self.body.places.at(pl as usize).base, self.body.rvalues.len() as u32 - 1);
        }
        return pl;
    }

    // Store `rv` into destination `dest` (`lower_into`) when there is one and it holds the
    // rvalue's type: WROTE. Otherwise into a fresh temp, and the operand that reads it.
    fn rv_out(self: &mut Self, dest: ir::PlaceId, rv: ir::Rvalue, sp: tok::Span) ir::OperandId {
        if dest != ir::IR_NONE && self.body.places.at(dest as usize).ty == rv.target {
            self.assign(dest, rv, sp);
            return WROTE;
        }
        return self.copy_op(self.rv_temp(rv, sp));
    }

    // The place a value of type `ty` lowers into: `dest` when there is one and it holds `ty`, else a
    // fresh temp's.
    fn out_place(self: &mut Self, dest: ir::PlaceId, ty: TypeId, sp: tok::Span) ir::PlaceId {
        if dest != ir::IR_NONE && self.body.places.at(dest as usize).ty == ty {
            return dest;
        }
        return self.place_of_local(self.temp(ty, sp));
    }

    // The result of a producer that wrote place `pl`, given destination `dest`: WROTE when `pl` is
    // `dest`, else the operand that reads `pl`.
    fn out_op(self: &mut Self, dest: ir::PlaceId, pl: ir::PlaceId) ir::OperandId {
        if pl == dest {
            return WROTE;
        }
        return self.copy_op(pl);
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

    // A constant operand that selects no item.
    fn kop(self: &mut Self, kind: u8, ty: TypeId, val: i64, sp: tok::Span) ir::OperandId {
        return self.const_op(
            ir::Constant { kind: kind, ty: ty, val: val, raw: sp, item: DefId { module: 0, node: NODE_NONE } },
        );
    }

    fn unit_op(self: &mut Self, ty: TypeId, sp: tok::Span) ir::OperandId {
        return self.kop(ir::CK_UNIT, ty, 0, sp);
    }

    fn copy_op(self: &mut Self, pl: ir::PlaceId) ir::OperandId {
        let ty = self.body.places.at(pl as usize).ty;
        self.body.operands.push(ir::Operand { kind: ir::OP_COPY, data: pl, ty: ty });
        return self.body.operands.len() as u32 - 1;
    }

    const fn rv_use(self: &Self, op: ir::OperandId, ty: TypeId) ir::Rvalue {
        return ir::rv(ir::RV_USE, op, 0, 0, ty);
    }

    // Arguments evaluate left to right: a value read or moved out of a place (operand `op` of
    // argument `a`) is taken into a temp where it is written when a later argument (`args` from
    // `from`) may write that place's root binding (`may_write`; for a `static`, any argument that
    // is not a name or a literal), so the call sees the value at the argument's own position. A temp
    // that may own its value is registered for the scope-exit drop (`own_temp`): the call consumes
    // it, an exit before the call releases it. A fresh temporary, nothing else writes, a constant
    // and every other operand stay as they are; the user-move mark stays on `op` (the move). An
    // operand that parameter `pi` of `target` borrows (an implicit autoref) is a place, not a value:
    // it stays too, as do `&mut` references and `[]mut` views (below).
    fn pin_read(self: &mut Self, op: ir::OperandId, a: NodeId, args: NodeList, from: u32, target: DefId, pi: usize) ir::OperandId {
        if from >= args.len {
            return op;
        }
        let o = *self.body.operands.at(op as usize);
        if o.kind != ir::OP_COPY && o.kind != ir::OP_MOVE || self.borrowed_arg(target, pi, o.ty) {
            return op;
        }
        // A `&mut` or `[]mut T` handed to a call is reborrowed there, while a copy into a temp
        // would move it: both stay at the call.
        let y = *self.f.ty(o.ty);
        if y.kind == TypeKind::TYPE_REFERENCE && y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 || self.view_kind(
            o.ty,
        ) == 2 {
            return op;
        }
        let pl = *self.body.places.at(o.data as usize);
        if pl.proj_len == 0 && self.body.locals.at(pl.base as usize).storage == ir::LS_TEMP {
            return op;
        }
        let r = self.root_binding(a);
        if r.node == NODE_NONE {
            return op;
        }
        let stat = self.decl_kind(r) == NodeKind::NODE_CONST;
        for j in from..args.len {
            let b = unsafe self.f.list(args)[j as usize];
            let w = if stat {
                self.f.node(b).kind != NodeKind::NODE_LITERAL && self.f.node(b).kind != NodeKind::NODE_IDENTIFIER;
            } else {
                self.may_write(b, r, 0);
            };
            if w {
                let t = self.copy_op(self.spill(op, self.f.node(a).span));
                self.own_operand(t, a);
                return t;
            }
        }
        return op;
    }

    // Does parameter `pi` of call target `target` take an argument of type `ty` by implicit
    // borrow: a reference or pointer parameter for an operand that is neither (see `Gen::arg_kinds`)?
    fn borrowed_arg(self: &mut Self, target: DefId, pi: usize, ty: TypeId) bool {
        if self.decl_kind(target) != NodeKind::NODE_FUNCTION || !self.checked_here(target.module, target.node) {
            return false;
        }
        let fa = unsafe &*(&*self.pkg).module_ast_const(target.module);
        let ps = fa.at_const(target.node).as_data.function.params;
        if pi >= ps.len as usize {
            return false;
        }
        let pk = fa.type_at(fa.type_of(unsafe fa.list(ps)[pi])).kind;
        let ok = self.f.ty(ty).kind;
        return (pk == TypeKind::TYPE_REFERENCE || pk == TypeKind::TYPE_POINTER) && ok != TypeKind::TYPE_REFERENCE && ok != TypeKind::TYPE_POINTER;
    }

    // The binding place expression `e` is rooted at, through fields, dereferences and indexes;
    // none for another root (a call result, a literal). Each step moves to a child node.
    fn root_binding(self: &Self, e: NodeId) DefId {
        let mut c = e;
        for _i in 0..unsafe (&*self.f.ast).nnodes() {
            let n = self.f.node(c);
            if n.kind == NodeKind::NODE_IDENTIFIER {
                return self.f.res(c);
            }
            if n.kind == NodeKind::NODE_MEMBER && !n.as_data.member.path {
                c = n.as_data.member.object;
            } else if n.kind == NodeKind::NODE_UNARY && n.as_data.unary.op == tt::TokenType::Star {
                c = n.as_data.unary.operand;
            } else if n.kind == NodeKind::NODE_INDEX {
                c = n.as_data.index.object;
            } else {
                break;
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    // Can evaluating expression `id` write a place rooted at binding `r`: an assignment to, a
    // `&mut` of, or a call of a method not taking `&self` on such a place, or such a place passed to
    // a call? True for an expression kind this does not follow (a block, a closure, a literal of
    // an aggregate) and past WALK_MAX levels.
    fn may_write(self: &Self, id: NodeId, r: DefId, depth: u32) bool {
        if depth > WALK_MAX {
            return true;
        }
        let n = self.f.node(id);
        let k = n.kind;
        if k == NodeKind::NODE_LITERAL || k == NodeKind::NODE_IDENTIFIER || k == NodeKind::NODE_SIZEOF || k == NodeKind::NODE_ALIGNOF {
            return false;
        }
        if k == NodeKind::NODE_MEMBER {
            return !n.as_data.member.path && self.may_write(n.as_data.member.object, r, depth + 1);
        }
        if k == NodeKind::NODE_CAST {
            return self.may_write(n.as_data.cast.expression, r, depth + 1);
        }
        if k == NodeKind::NODE_INDEX {
            return self.may_write(n.as_data.index.object, r, depth + 1) || self.may_write(
                n.as_data.index.index,
                r,
                depth + 1,
            );
        }
        if k == NodeKind::NODE_UNARY {
            let u = n.as_data.unary;
            if u.op == tt::TokenType::Ampersand && u.qualifier == TypeQualifier::TYPE_QUAL_MUT && self.same_def(
                self.root_binding(u.operand),
                r,
            ) {
                return true;
            }
            return self.may_write(u.operand, r, depth + 1);
        }
        if k == NodeKind::NODE_BINARY {
            return self.may_write(n.as_data.binary.left, r, depth + 1) || self.may_write(
                n.as_data.binary.right,
                r,
                depth + 1,
            );
        }
        if k == NodeKind::NODE_ASSIGNMENT {
            let bd = n.as_data.binary;
            return self.same_def(self.root_binding(bd.left), r) || self.may_write(bd.left, r, depth + 1) || self.may_write(
                bd.right,
                r,
                depth + 1,
            );
        }
        if k != NodeKind::NODE_CALL {
            return true;
        }
        let cd = n.as_data.call;
        let cn = self.f.node(cd.callee);
        if cn.kind == NodeKind::NODE_MEMBER && !cn.as_data.member.path {
            let obj = cn.as_data.member.object;
            if self.same_def(self.root_binding(obj), r) && !self.shared_receiver(id) || self.may_write(
                obj,
                r,
                depth + 1,
            ) {
                return true;
            }
        } else if cn.kind != NodeKind::NODE_IDENTIFIER && cn.kind != NodeKind::NODE_MEMBER && cn.kind != NodeKind::NODE_GENERIC_SPECIALIZATION {
            if self.may_write(cd.callee, r, depth + 1) {
                return true;
            }
        }
        for i in 0..cd.args.len {
            let b = unsafe self.f.list(cd.args)[i as usize];
            if self.same_def(self.root_binding(b), r) || self.may_write(b, r, depth + 1) {
                return true;
            }
        }
        return false;
    }

    // Does method call `id` take its receiver as `&self` (no write through it)?
    fn shared_receiver(self: &Self, id: NodeId) bool {
        switch self.f.call_info(id) {
            Some(v) => {
                let t = DefId { module: ci_module(v), node: ci_decl(v) };
                if (v & 0xFFu64) == 0 || self.decl_kind(t) != NodeKind::NODE_FUNCTION {
                    return false;
                }
                let fa = unsafe &*(&*self.pkg).module_ast_const(t.module);
                let ps = fa.at_const(t.node).as_data.function.params;
                if ps.len == 0 {
                    return false;
                }
                let pt = fa.at_const(unsafe fa.list(ps)[0]).as_data.parameter.ty;
                return pt != NODE_NONE && fa.at_const(pt).kind == NodeKind::NODE_REFERENCE_TYPE && fa.at_const(pt).as_data.indirect_type.qualifier != TypeQualifier::TYPE_QUAL_MUT;
            },
            None => {
                return false;
            },
        };
    }

    const fn same_def(self: &Self, a: DefId, b: DefId) bool {
        return a.node != NODE_NONE && a.node == b.node && a.module == b.module;
    }

    // Store operand `op` into a fresh temp and return the temp's place (for projections off values).
    fn spill(self: &mut Self, op: ir::OperandId, sp: tok::Span) ir::PlaceId {
        let ty = self.body.operands.at(op as usize).ty;
        return self.rv_temp(self.rv_use(op, ty), sp);
    }

    // An expression's value that lowered into a fresh, unregistered temporary (a call result, an
    // `if`/`switch`/block value, a desugared `format`) OWNS that value: register the temporary for
    // the scope-exit drop, keyed on `key`. Drop elaboration skips non-owning types. True when the
    // operand is such a temporary.
    fn own_temp(self: &mut Self, op: ir::OperandId, key: NodeId) bool {
        let o = *self.body.operands.at(op as usize);
        if o.kind != ir::OP_COPY && o.kind != ir::OP_MOVE {
            return false;
        }
        let pl = *self.body.places.at(o.data as usize);
        let mut ld = *self.body.locals.at(pl.base as usize);
        if pl.proj_len != 0 || ld.storage != ir::LS_TEMP || ld.decl != NODE_NONE {
            return false;
        }
        ld.decl = key;
        self.body.locals.set(pl.base as usize, ld);
        let d = self.ext.depth as usize;
        if self.ext_on(key) && d < self.scope_local_marks.len() {
            // A temporary an arm's value borrows: the last local of the scope around the arms.
            self.scope_locals.insert(self.scope_local_marks[d], pl.base);
            for i in d..self.scope_local_marks.len() {
                self.scope_local_marks.set(i, self.scope_local_marks[i] + 1);
            }
        } else {
            self.scope_locals.push(pl.base);
        }
        return true;
    }

    // Whether node `id` is in the value position of the arm being lowered (`ExtCx`).
    const fn ext_on(self: &Self, id: NodeId) bool {
        return id != NODE_NONE && (id == self.ext.arm || id == self.ext.val || id == self.ext.rf);
    }

    // The scope depth a value `if`, `switch` or block `id` gives the temporaries its arms' values
    // borrow: the depth around it, or its own arm's when `id` is the value of an enclosing arm.
    const fn ext_depth_for(self: &Self, id: NodeId) u32 {
        if self.ext_on(id) {
            return self.ext.depth;
        }
        return self.scope_local_marks.len() as u32;
    }

    // `own_temp` for an operand an operator only reads, when its type can own: a builtin, pointer
    // or reference temporary stays unregistered, so the backend folds it into its reader.
    fn own_operand(self: &mut Self, op: ir::OperandId, key: NodeId) {
        let k = self.f.ty(self.body.operands.at(op as usize).ty).kind;
        if k != TypeKind::TYPE_BUILTIN && k != TypeKind::TYPE_POINTER && k != TypeKind::TYPE_REFERENCE {
            let _ = self.own_temp(op, key);
        }
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
        self.stmt(ir::Statement { kind: ir::ST_STORAGE_LIVE, place: ir::IR_NONE, rvalue: ir::IR_NONE, a: l, span: sp });
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
                ir::Statement { kind: ir::ST_STORAGE_DEAD, place: ir::IR_NONE, rvalue: ir::IR_NONE, a: l, span: sp },
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
            if (d & DEFER_TAIL) != 0 {
                self.emit_tail_drop(self.tail_drops[(d & ~DEFER_TAIL) as usize]);
                continue;
            }
            self.tp(ir::TP_MARK_PUSH, 0, d);
            // A defer body is cleanup: cancellation checks are masked inside it (a synthetic return
            // from within a defer would abandon the rest of the exit path).
            self.in_defer += 1;
            self.lower_stmt(self.f.node(d).as_data.single.value);
            self.in_defer -= 1;
            self.tp(ir::TP_MARK_POP, 0, d);
        }
    }

    // `j = idx + 1; while j < len { drop arr[j]; j += 1; }`: the elements the loop did not take.
    fn emit_tail_drop(self: &mut Self, td: TailDrop) {
        let sp = td.span;
        let ut = Ast::builtin(BuiltinType::BT_USIZE);
        let jpl = self.place_of_local(self.temp(ut, sp));
        let one = self.kop(ir::CK_INT, ut, 1, sp);
        self.assign(jpl, ir::rv(ir::RV_BINARY, self.copy_op(td.idx), one, tt::TokenType::Plus as u8, ut), sp);
        let head = self.open_block();
        let body_b = self.open_block();
        let done = self.open_block();
        self.seal(ir::goto_term(head, sp), head);
        let cop = self.bool_bin(self.copy_op(jpl), self.copy_op(td.len), tt::TokenType::LessThan, sp);
        self.branch_bool(cop, body_b, done, sp);
        let mut tm = ir::term0(ir::TM_DROP, sp);
        tm.a = self.place_project(
            td.arr,
            ir::Projection { kind: ir::PJ_INDEX_OP, data: self.copy_op(jpl), sub: 0, ty: td.elem },
        );
        let cont = self.open_block();
        tm.t0 = cont;
        self.seal(tm, cont);
        let one2 = self.kop(ir::CK_INT, ut, 1, sp);
        self.assign(jpl, ir::rv(ir::RV_BINARY, self.copy_op(jpl), one2, tt::TokenType::Plus as u8, ut), sp);
        self.seal(ir::goto_term(head, sp), done);
    }

    /// A local slot with the declaration facts the emitter reads after the body syntax is
    /// released: the binding's name text and its declaration kind.
    const fn local_decl(self: &Self, ty: TypeId, storage: u8, is_mutable: bool, span: tok::Span, decl: NodeId) ir::LocalDecl {
        let mut name = tok::Span::empty();
        let mut dkind = ir::LK_NONE;
        if decl != NODE_NONE {
            let n = self.f.node(decl);
            name = unsafe (&*self.f.ast).decl_name_span(decl);
            if n.kind == NodeKind::NODE_LET {
                dkind = ir::LK_LET;
            } else if n.kind == NodeKind::NODE_FOR || n.kind == NodeKind::NODE_INLINE_FOR {
                dkind = ir::LK_FOR;
            } else if n.kind == NodeKind::NODE_PATTERN_NAME {
                dkind = ir::LK_PATTERN;
            }
        }
        let mut off: u16 = 0;
        let mut len: u16 = 0;
        if name.end > name.start && name.start >= span.start && name.start - span.start < 65536 && name.end - name.start < 65536 {
            off = (name.start - span.start) as u16;
            len = (name.end - name.start) as u16;
        }
        return ir::LocalDecl {
            ty: ty,
            storage: storage,
            is_mutable: is_mutable,
            dkind: dkind,
            span: span,
            decl: decl,
            name_off: off,
            name_len: len,
            item: DefId { module: 0, node: NODE_NONE },
        };
    }

    fn bind(self: &mut Self, decl: NodeId, l: ir::LocalId) {
        self.binds.push(Binding { decl: decl, local: l });
        self.bind_ix.insert(decl, l);
    }

    fn local_of(self: &Self, decl: NodeId) ir::LocalId {
        return switch self.bind_ix.get(&decl) {
            Some(l) => *l,
            None => ir::IR_NONE,
        };
    }

    // The cached LS_STATIC_REF local naming item `d` (globals, statics, constants read as places).
    fn item_local(self: &mut Self, d: DefId, ty: TypeId, sp: tok::Span) ir::LocalId {
        // keyed by the FULL DefId: node ids collide across modules
        let key = d.module as u64 << 32 | d.node as u64;
        let hit = switch self.item_ix.get(&key) {
            Some(l) => *l,
            None => ir::IR_NONE,
        };
        if hit != ir::IR_NONE {
            return hit;
        }
        // A constant the reader cannot see keeps the use type: the engine reads the constant's cell
        // whatever the local's type, and the C emitter lowers with no reader.
        // An array constant read as a slice has the slice type on the use node; its place keeps the
        // declared array type, and the emitter wraps the array where a slice is wanted.
        let mut lty = ty;
        if self.decl_kind(d) == NodeKind::NODE_CONST && ty != TYPE_NONE && self.f.ty(ty).kind != TypeKind::TYPE_ARRAY && self.seen_here(
            d.module,
            d.node,
        ) {
            let dt = unsafe (*(&*self.pkg).module_ast_const(d.module)).type_of(d.node);
            if dt != TYPE_NONE {
                let rt = self.reintern_ty(d.module, dt);
                if self.f.ty(rt).kind == TypeKind::TYPE_ARRAY {
                    lty = rt;
                }
            }
        }
        let mut ld = ir::LocalDecl::anon(lty, ir::LS_STATIC_REF, sp);
        ld.item = d;
        let l = self.body.add_local(ld);
        self.item_keys.push(key);
        self.item_ix.insert(key, l);
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
            let rt = self.ret_ty(unsafe self.f.list(rets)[i as usize]);
            let _ = self.body.add_local(self.local_decl(rt, ir::LS_RET, true, sp, NODE_NONE));
        }
        self.body.returns = rets.len;
        let params = fd.params;
        for i in 0..params.len {
            let pn = unsafe self.f.list(params)[i as usize];
            let pd = self.f.node(pn).as_data.parameter;
            let l = self.body.add_local(
                self.local_decl(self.nty(pn), ir::LS_ARG, pd.is_mutable, self.f.node(pn).span, pn),
            );
            self.bind(pn, l);
        }
        self.body.args = params.len;
        self.open_entry();
        // Argument storage ends at every function exit, after all scope locals (registration
        // precedes the body scope, so reverse dead order frees them last).
        for i in 0..params.len {
            self.scope_locals.push(rets.len + i);
        }
        self.scope_enter();
        // A destructor completes: one that can reach a cancellation acceptance runs masked, so its
        // waits finish and no accepted request is left for a caller whose drop carries no edge.
        if self.free_can_accept(fnode) {
            self.free_mask = true;
            self.mask_call(loader::SugarItem::SI_CANCEL_MENTER, sp);
        }
        if fd.is_intrinsic() {
            // The operation itself over the arguments: the body a function value or a bound call runs.
            let mut ops = self.avget();
            for i in 0..params.len {
                ops.push(self.copy_op(self.place_of_local(rets.len + i)));
            }
            let rt = if rets.len == 1 {
                self.body.locals.at(0).ty;
            } else {
                Ast::builtin(BuiltinType::BT_VOID);
            };
            let r = self.lower_intrinsic(DefId { module: self.module, node: fnode }, &mut ops, rt, sp);
            self.avput(ops);
            if r != ir::IR_NONE && rets.len == 1 {
                let pl = self.place_of_local(0);
                self.assign(pl, self.rv_use(r, rt), sp);
            }
        } else {
            self.lower_stmt(fd.body);
        }
        self.scope_exit();
        self.emit_deads_down_to(0);
        // Fall-off return (void functions; a returning tail already sealed the block).
        return self.finish_body(sp);
    }

    /// Lower a closure's body: parameters then captures become argument locals (captures bind their
    /// ORIGINAL declaring nodes, so the body's uses resolve to them).
    pub fn lower_closure_body(self: &mut Self, cnode: NodeId) bool {
        self.begin_body(cnode);
        let cd = self.f.node(cnode).as_data.closure;
        let sp = self.f.node(cnode).span;
        let rets = cd.returns;
        for i in 0..rets.len {
            let rt = self.ret_ty(unsafe self.f.list(rets)[i as usize]);
            let _ = self.body.add_local(self.local_decl(rt, ir::LS_RET, true, sp, NODE_NONE));
        }
        self.body.returns = rets.len;
        if rets.len == 0 && (cd.expr_body || cd.ret_infer) {
            // a closure with no written return list still returns its body's INFERRED type (an
            // expression body's, or what a block's `return`s give); a unit body keeps zero return
            // slots
            let bt = self.nty(cd.body);
            if bt != TYPE_NONE && !(self.f.ty(bt).kind == TypeKind::TYPE_BUILTIN && self.f.ty(bt).as_data.builtin == BuiltinType::BT_VOID) {
                let _ = self.body.add_local(self.local_decl(bt, ir::LS_RET, true, sp, NODE_NONE));
                self.body.returns = 1;
            }
        }
        let params = cd.params;
        for i in 0..params.len {
            let pn = unsafe self.f.list(params)[i as usize];
            let l = self.body.add_local(self.local_decl(self.nty(pn), ir::LS_ARG, false, self.f.node(pn).span, pn));
            self.bind(pn, l);
        }
        let caps = cd.captures;
        for i in 0..caps.len {
            let c = unsafe self.f.list(caps)[i as usize];
            let decl = self.cap_decl(c);
            let l = self.body.add_local(self.local_decl(self.nty(c), ir::LS_ARG, true, self.f.node(c).span, decl));
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
        self.open_entry();
        // Parameters are the body's to destroy; CAPTURES are not. The env stays whole across any
        // number of calls, and whoever owns the closure VALUE frees the env (and so the captures)
        // exactly once when it drops -- the derived closure glue in the emitter.
        // An expr-body closure may hold an inferred return slot that `rets` does not list.
        for i in 0..params.len {
            self.scope_locals.push(self.body.returns + i);
        }
        self.scope_enter();
        if cd.expr_body && self.body.returns != 0 {
            let pl = self.place_of_local(0);
            self.lower_value_into(cd.body, pl, EXT_NONE);
        } else {
            self.lower_stmt(cd.body);
        }
        self.scope_exit();
        self.emit_deads_down_to(0);
        return self.finish_body(sp);
    }

    /// Lower a constant/static initializer expression as a one-return body.
    pub fn lower_const(self: &mut Self, cnode: NodeId) bool {
        let cd = self.f.node(cnode).as_data.const_def;
        return self.lower_value_body(cd.value, self.nty(cnode), self.f.node(cnode).span);
    }

    /// `lower_const` through a Lowerer that may hold an earlier body (`retarget` it first for another
    /// module): its pools keep their heap capacity.
    pub fn relower_const(self: &mut Self, cnode: NodeId) bool {
        self.begin_body(cnode);
        return self.lower_const(cnode);
    }

    /// Lower a bare TYPED expression as a one-return body (the facade behind expression-level
    /// CTFE requests: array lengths, discriminants, folds).
    pub fn lower_expr_root(self: &mut Self, expr: NodeId) bool {
        return self.lower_value_body(expr, self.nty(expr), self.f.node(expr).span);
    }

    // A one-return body of type `ty` that returns `expr` (none: the slot stays unwritten).
    fn lower_value_body(self: &mut Self, expr: NodeId, ty: TypeId, sp: tok::Span) bool {
        let _ = self.body.add_local(self.local_decl(ty, ir::LS_RET, true, sp, NODE_NONE));
        self.body.returns = 1;
        self.open_entry();
        if expr != NODE_NONE {
            let pl = self.place_of_local(0);
            let _ = self.lower_into(expr, pl, false, sp);
        }
        return self.finish_body(sp);
    }

    // Open the entry block and start its statement run.
    fn open_entry(self: &mut Self) {
        self.body.entry = self.open_block();
        self.cur = self.body.entry;
        self.run_start = 0;
    }

    // Seal the open block with the fall-off return, drop the unsealed trailing block, and report
    // success.
    // Is `fnode` the `free` of a `Free` conformance that can reach a cancellation acceptance?
    fn free_can_accept(self: &mut Self, fnode: NodeId) bool {
        let fd = self.f.node(fnode).as_data.function;
        let nm = self.f.node(fd.name).as_data.name.text;
        if self.src.slice(nm.start as usize, nm.end as usize) != "free" || !self.chk_enabled() {
            return false;
        }
        let pk = unsafe &*self.pkg;
        let ext = unsafe (&*pk.module_ast_const(self.module)).container_of(fnode);
        if ext == NODE_NONE || self.f.node(ext).kind != NodeKind::NODE_EXTEND || self.f.node(ext).as_data.extend_def.interface_type == NODE_NONE {
            return false;
        }
        let iface = self.f.res(self.f.node(ext).as_data.extend_def.interface_type);
        let fh = pk.prelude_lookup("Free", true);
        if iface.module != fh.mid || iface.node != fh.node {
            return false;
        }
        return pk.cancel_on(self.module, self.f.node(fnode).span);
    }

    // A call to runtime hook `si` (no arguments, no result, no edge).
    fn mask_call(self: &mut Self, si: loader::SugarItem, sp: tok::Span) {
        let pk = unsafe &*self.pkg;
        let c0 = self.body.oper_pool.len() as u32;
        let _ = self.emit_call(
            pk.sugar_item(si),
            ir::IR_NONE,
            c0,
            0,
            0,
            0,
            TYPE_NONE,
            TYPE_NONE,
            Ast::builtin(BuiltinType::BT_VOID),
            sp,
        );
    }

    fn finish_body(self: &mut Self, sp: tok::Span) bool {
        if self.free_mask {
            self.mask_call(loader::SugarItem::SI_CANCEL_MEXIT, sp);
        }
        let t = ir::term0(ir::TM_RETURN, sp);
        let end = self.open_block();
        self.seal(t, end);
        while self.body.blocks.len() != 0 && !self.body.blocks.at(self.body.blocks.len() - 1).sealed {
            let _ = self.body.blocks.pop();
        }
        return self.err.len() == 0;
    }

    // ---- statements -------------------------------------------------------------------------------

    fn lower_stmt(self: &mut Self, id: NodeId) {
        if id == NODE_NONE || self.err.len() != 0 {
            return;
        }
        let k = self.f.node(id).kind;
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
            let cb = self.chk_open(v, true);
            let op = self.lower_expr(v);
            self.chk_close(cb);
            self.tp(ir::TP_MARK_POP, 0, id);
            // A fully discarded result still OWNS its value (`foo();`).
            if op != ir::IR_NONE {
                let _ = self.own_temp(op, id);
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
            let cb = self.chk_open(id, false);
            let _ = self.lower_match(id, ir::IR_NONE);
            self.chk_close(cb);
        } else if k == NodeKind::NODE_ASM {
            self.lower_asm(id);
        } else if k == NodeKind::NODE_CONST || k == NodeKind::NODE_STATIC_ASSERT || k == NodeKind::NODE_FUNCTION || k == NodeKind::NODE_STRUCT || k == NodeKind::NODE_ENUM || k == NodeKind::NODE_TYPE_ALIAS {
            // Item statements: a local const is static data evaluated at compile time, like an item
            // const; nested items own their own bodies.
        } else {
            // Everything else is an expression in statement position.
            let cb = self.chk_open(id, false);
            let _ = self.lower_expr(id);
            self.chk_close(cb);
        }
    }

    // Inline assembly: outputs lower as places (copies carry the place id), inputs as values;
    // template/constraints/clobbers are copied as source spans into the body's asm record.
    fn lower_asm(self: &mut Self, id: NodeId) {
        let d = self.f.node(id).as_data.asm_stmt;
        let sp = self.f.node(id).span;
        let mut argv = self.avget();
        let mut i: u32 = 0;
        while i + 1 < d.outputs.len {
            let pe = unsafe self.f.list(d.outputs)[(i + 1) as usize];
            let pl = self.lower_place(pe);
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
        // The statement's text, owned by the body: the emitter renders it after the syntax is gone.
        let cons = self.body.asm_spans.len() as u32;
        i = 0;
        while i + 1 < d.outputs.len {
            self.body.asm_spans.push(self.f.node(unsafe self.f.list(d.outputs)[i as usize]).as_data.literal.raw);
            i += 2;
        }
        i = 0;
        while i + 1 < d.inputs.len {
            self.body.asm_spans.push(self.f.node(unsafe self.f.list(d.inputs)[i as usize]).as_data.literal.raw);
            i += 2;
        }
        for k in 0..d.clobbers.len {
            self.body.asm_spans.push(self.f.node(unsafe self.f.list(d.clobbers)[k as usize]).as_data.literal.raw);
        }
        let rec = self.body.asms.len() as NodeId;
        self.body.asms.push(
            ir::AsmRec {
                template: if d.template == NODE_NONE {
                    tok::Span::empty();
                } else {
                    self.f.node(d.template).as_data.literal.raw;
                },
                cons: cons,
                nout: d.outputs.len / 2,
                nin: d.inputs.len / 2,
                nclob: d.clobbers.len,
            },
        );
        let ut = Ast::builtin(BuiltinType::BT_VOID);
        let _ = self.rv_temp(
            ir::Rvalue {
                kind: ir::RV_INTRINSIC,
                a: start,
                b: argv.len() as u32,
                c: ir::IN_ASM,
                target: ut,
                item: DefId { module: self.module, node: rec },
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
                self.fail_at("let-pattern-without-value", NODE_NONE);
                return;
            }
            // The pattern's names bind after the value: nothing is pending while it evaluates.
            let cb = self.chk_open(ld.value, false);
            let s0 = self.body.statements.len() as u32;
            let b0 = self.body.blocks.len() as u32;
            let blk0 = self.cur;
            let vpl = self.value_temp(ld.value, true, sp);
            self.chk_close(cb);
            if vpl == ir::IR_NONE {
                return;
            }
            let km = self.known_keys.len();
            // The value's temp keeps its one value: the bindings read its members (`place_variant`).
            let rid = self.built_def(vpl, s0, b0, blk0);
            if rid != ir::IR_NONE {
                self.note_known(self.body.places.at(vpl as usize).base, rid);
            }
            self.pattern_bind(ld.name, vpl);
            if ld.is_mutable {
                // `let mut (a, b) = ..`: the bindings take other values later.
                self.forget_known(km);
            }
            let tk: u8 = if nk == NodeKind::NODE_PATTERN_TUPLE {
                ir::TP_LET_TUPLE;
            } else {
                ir::TP_LET;
            };
            self.tp(tk, 0, id);
            return;
        }
        let ty = self.nty(id);
        let l = self.body.add_local(self.local_decl(ty, ir::LS_USER, ld.is_mutable, sp, id));
        self.bind(id, l);
        self.bind(ld.name, l);
        self.user_local_live(l, sp);
        if ld.value == NODE_NONE {
            self.body.has_uninit_decl = true; // split init: only this form can use-before-init
        }
        if ld.value != NODE_NONE {
            // `l` is uninitialized until the assign below: every ladder inside the initializer
            // skips it.
            self.pending_lets.push(l);
            let cb = self.chk_open(ld.value, true);
            let pl = self.place_of_local(l);
            let s0 = self.body.statements.len() as u32;
            let b0 = self.body.blocks.len() as u32;
            let blk0 = self.cur;
            let ok = self.lower_into(ld.value, pl, true, sp);
            self.chk_close(cb);
            let _ = self.pending_lets.pop();
            if !ok {
                return;
            }
            if !ld.is_mutable {
                let rid = self.built_def(pl, s0, b0, blk0);
                if rid != ir::IR_NONE {
                    self.note_known(l, rid);
                }
            }
        }
        self.tp(ir::TP_LET, 0, id);
    }

    fn lower_return(self: &mut Self, id: NodeId) {
        let rd = self.f.node(id).as_data.return_stmt;
        let sp = self.f.node(id).span;
        self.tp(ir::TP_MARK_PUSH, 0, id);
        if rd.values.len == 1 && self.body.returns > 1 {
            // `return pair();`: the call's results, member by member, are the return values.
            let v = unsafe self.f.list(rd.values)[0];
            let cb = self.chk_open(v, false);
            let tpl = self.value_temp(v, true, sp);
            self.chk_close(cb);
            if tpl == ir::IR_NONE {
                return;
            }
            for i in 0..self.body.returns {
                let ty = self.body.locals.at(i as usize).ty;
                let mpl = self.place_project(
                    tpl,
                    ir::Projection { kind: ir::PJ_FIELD, data: member_data(NODE_NONE, i), sub: NODE_NONE, ty: ty },
                );
                self.tp(ir::TP_RET_VAL, i, v);
                let pl = self.place_of_local(i);
                let rv = self.rv_use(self.copy_op(mpl), ty);
                self.assign(pl, rv, sp);
            }
            self.tp(ir::TP_RET_POST, 0, id);
            self.emit_defers_down_to(0);
            self.emit_deads_down_to(0);
            let t = ir::term0(ir::TM_RETURN, sp);
            let next = self.open_block();
            self.seal(t, next);
            return;
        }
        for i in 0..rd.values.len {
            let v = unsafe self.f.list(rd.values)[i as usize];
            // A later value would evaluate with this one pending: only a lone value is a root.
            let mut root = NODE_NONE;
            if rd.values.len == 1 {
                root = v;
            }
            let cb = self.chk_open(root, false);
            let pl = self.place_of_local(i);
            let ok = self.lower_into(v, pl, true, sp);
            self.chk_close(cb);
            if !ok {
                return;
            }
            self.tp(ir::TP_RET_VAL, i, v);
        }
        self.tp(ir::TP_RET_POST, 0, id);
        self.emit_defers_down_to(0);
        self.emit_deads_down_to(0);
        if self.free_mask {
            self.mask_call(loader::SugarItem::SI_CANCEL_MEXIT, sp);
        }
        let t = ir::term0(ir::TM_RETURN, sp);
        let next = self.open_block();
        self.seal(t, next);
    }

    const fn find_loop(self: &Self, label: tok::Span) i64 {
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
            self.fail_at("break-outside-loop", NODE_NONE);
            return;
        }
        let lc = self.loops[li as usize];
        if fd.value != NODE_NONE {
            // The loop's result is its destination: written once, then the loop exits.
            if lc.result != ir::IR_NONE {
                if !self.lower_into(fd.value, lc.result, false, sp) {
                    return;
                }
            } else if self.lower_expr(fd.value) == ir::IR_NONE {
                return;
            }
        }
        self.emit_defers_down_to(lc.brk_defer_depth);
        self.emit_deads_down_to(lc.locals_depth);
        let t = ir::goto_term(lc.brk, sp);
        let next = self.open_block();
        self.seal(t, next);
    }

    fn lower_continue(self: &mut Self, id: NodeId) {
        let fd = self.f.node(id).as_data.flow;
        let sp = self.f.node(id).span;
        let li = self.find_loop(fd.label);
        if li < 0 {
            self.fail_at("continue-outside-loop", NODE_NONE);
            return;
        }
        let lc = self.loops[li as usize];
        self.emit_defers_down_to(lc.defer_depth);
        self.emit_deads_down_to(lc.locals_depth);
        let t = ir::goto_term(lc.cont, sp);
        let next = self.open_block();
        self.seal(t, next);
    }

    // Bool switch: true -> `then`, otherwise -> `els`. Continues writing in `then`.
    fn branch_bool(self: &mut Self, cond: ir::OperandId, then_b: ir::BlockId, els: ir::BlockId, sp: tok::Span) {
        self.branch_on(cond, then_b, els, then_b, sp);
    }

    // Seal the open block with `cond ? then_b : els` and continue in `next`.
    fn branch_on(
        self: &mut Self,
        cond: ir::OperandId,
        then_b: ir::BlockId,
        els: ir::BlockId,
        next: ir::BlockId,
        sp: tok::Span,
    ) {
        let mut t = ir::term0(ir::TM_SWITCH, sp);
        t.a = cond;
        t.sw_start = self.body.switch_pool.len() as u32;
        self.body.switch_pool.push(1u64 << 32 | then_b as u64);
        t.sw_len = 1;
        t.t0 = els;
        self.seal(t, next);
    }

    fn lower_if_stmt(self: &mut Self, id: NodeId) {
        let d = self.f.node(id).as_data.if_stmt;
        // A binder-const branch (only the taken side lowers, so the untaken side's calls are never
        // demanded) or `sizeof(T) <op> <const>`, which folds per instance (a ZST container path
        // may not even be spellable for the other instantiation).
        let mut kc: i32 = -1;
        if self.proj_frames.len() != 0 {
            kc = self.binder_cond(d.condition);
        }
        if kc < 0 {
            kc = self.zst_cond(d.condition);
        }
        if kc < 0 {
            kc = self.bc_cond(d.condition);
        }
        if kc == 1 {
            self.lower_stmt(d.then_branch);
        } else if kc == 0 {
            self.lower_stmt(d.else_branch);
        } else {
            let cb = self.chk_open(id, false);
            let _ = self.lower_if_arms(id, ir::IR_NONE);
            self.chk_close(cb);
        }
    }

    // Lower `if` node `id`'s condition and arms; the arms write their values into `dest` (none:
    // statement arms). False when the condition fails to lower.
    fn lower_if_arms(self: &mut Self, id: NodeId, dest: ir::PlaceId) bool {
        let d = self.f.node(id).as_data.if_stmt;
        let sp = self.f.node(id).span;
        self.tp(ir::TP_MARK_PUSH, 0, id);
        let cop = self.lower_expr(d.condition);
        self.tp(ir::TP_MARK_POP, 0, id);
        if cop == ir::IR_NONE {
            return false;
        }
        let depth = self.ext_depth_for(id);
        let then_b = self.open_block();
        let els_b = self.open_block();
        let join = self.open_block();
        self.branch_bool(cop, then_b, els_b, sp);
        self.tp(ir::TP_FLOW_SAVE, 0, id);
        self.lower_arm(d.then_branch, dest, depth);
        self.tp(ir::TP_FLOW_ELSE, 0, id);
        self.seal(ir::goto_term(join, sp), els_b);
        self.lower_arm(d.else_branch, dest, depth);
        self.tp(ir::TP_FLOW_JOIN, 0, id);
        self.seal(ir::goto_term(join, sp), join);
        return true;
    }

    // Lower arm `n` as a statement (`dest` none) or as a value into `dest`, whose borrowed
    // temporaries live at scope depth `depth`.
    fn lower_arm(self: &mut Self, n: NodeId, dest: ir::PlaceId, depth: u32) {
        if dest == ir::IR_NONE {
            self.lower_stmt(n);
        } else {
            self.lower_value_into(n, dest, depth);
        }
    }

    // A preemption safepoint marker at the top of a loop body; the backend prints it only for
    // programs that use the coroutine runtime, and never inside std::parallel itself. In a body
    // that can carry a cancellation edge, the combined form is emitted instead: the
    // same tick, whose cold half also accepts a pending unmasked cancellation and enters this
    // frame's cleanup ladder -- a compute-bound task that never waits still cleanly stops.
    fn loop_safepoint(self: &mut Self, sp: tok::Span) {
        if self.loop_ticks() {
            self.safepoint(sp);
        }
    }

    // Do this body's loops take a safepoint? Only a body a launched coroutine can execute needs
    // the preemption tick; every other loop skips the intrinsic (and so the emitted `__sc_spc`
    // countdown and its hook check).
    fn loop_ticks(self: &mut Self) bool {
        let ow9 = self.body.owner;
        if ow9.node != NODE_NONE {
            let osp = unsafe (&*(&*self.pkg).module_ast_const(ow9.module)).at_const(ow9.node).span;
            if !unsafe (&*self.pkg).co_on(ow9.module, osp) {
                return false;
            }
            self.body.inst_ticks = unsafe (&*self.pkg).co_inst_on(ow9.module, osp);
        }
        return true;
    }

    // The safepoint itself: plain, or combined with a cancellation check.
    fn safepoint(self: &mut Self, sp: tok::Span) {
        if self.in_defer == 0 && self.chk_mask == 0 && unsafe (&*self.pkg).cancel_used && self.chk_enabled() {
            self.safepoint_cancel(sp);
            return;
        }
        let ut = Ast::builtin(BuiltinType::BT_VOID);
        let _ = self.rv_temp(ir::rv(ir::RV_INTRINSIC, 0, 0, ir::IN_SAFEPOINT, ut), sp);
    }

    // The combined preemption + cancellation safepoint: tick result 1 means the cold half accepted
    // a pending request -- run this frame's cancellation ladder. The locals in scope at a loop-body
    // top are initialized except the pending `let`s whose initializer holds the loop, which the
    // ladder skips. Safepoints whose live scope state matches a previously emitted ladder JUMP to
    // that ladder instead of duplicating it -- sibling loops in one body then share one cleanup
    // sequence.
    fn safepoint_cancel(self: &mut Self, sp: tok::Span) {
        let it = Ast::builtin(BuiltinType::BT_I32);
        let pl = self.rv_temp(ir::rv(ir::RV_INTRINSIC, 0, 0, ir::IN_SAFEPOINT_C, it), sp);
        let cond = self.copy_op(pl);
        if self.sp_ladder_b != 0xFFFFFFFFu32 && self.sp_ladder_locals.eq(&self.scope_locals) && self.sp_ladder_defers.eq(
            &self.defers,
        ) && self.sp_ladder_pending.eq(&self.pending_lets) {
            let cont0 = self.open_block();
            self.branch_on(cond, self.sp_ladder_b, cont0, cont0, sp);
            return;
        }
        let ladder_b = self.open_block();
        let cont_b = self.open_block();
        self.branch_bool(cond, ladder_b, cont_b, sp);
        self.cancel_ladder(cont_b, sp);
        self.sp_ladder_b = ladder_b;
        self.sp_ladder_locals = self.scope_locals.clone();
        self.sp_ladder_defers = self.defers.clone();
        self.sp_ladder_pending = self.pending_lets.clone();
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
            self.seal(ir::goto_term(body_b, sp), body_b);
        } else {
            self.seal(ir::goto_term(head, sp), head);
        }
        if !d.is_do {
            // head: evaluate the condition (an infinite `loop` has no condition node)
            if d.condition != NODE_NONE {
                self.tp(ir::TP_MARK_PUSH, 0, id);
                let cb = self.chk_open(d.condition, false);
                let cop = self.lower_loop_cond(d.condition, sp);
                self.chk_close(cb);
                self.tp(ir::TP_MARK_POP, 0, id);
                if cop == ir::IR_NONE {
                    return;
                }
                self.branch_bool(cop, body_b, exit, sp);
            } else {
                self.seal(ir::goto_term(body_b, sp), body_b);
            }
        }
        let ar9: u32 = if d.is_do || d.condition == NODE_NONE {
            1;
        } else {
            0;
        };
        self.loop_body(d.label, exit, head, ar9, d.body, id, sp, self.scope_locals.len(), self.defers.len(), true);
        if d.is_do {
            // tail: condition decides back-edge vs exit; `head` is the continue target
            self.seal(ir::goto_term(head, sp), head);
            if d.condition != NODE_NONE {
                let cond_from = self.tape.len();
                self.tp(ir::TP_MARK_PUSH, 0, id);
                let cb = self.chk_open(d.condition, false);
                let cop = self.lower_loop_cond(d.condition, sp);
                self.chk_close(cb);
                self.tp(ir::TP_MARK_POP, 0, id);
                self.tape_splice(cond_at, cond_from);
                if cop == ir::IR_NONE {
                    return;
                }
                self.branch_bool(cop, body_b, exit, sp);
                self.seal(ir::goto_term(exit, sp), exit);
            } else {
                self.seal(ir::goto_term(body_b, sp), exit);
            }
        } else {
            self.seal(ir::goto_term(head, sp), exit);
        }
        self.tp(ir::TP_LOOP_POP, 0, id);
    }

    // Lower loop condition `c` in a scope of its own: the temporaries one evaluation owns drop before
    // the branch, so each iteration releases its own. A value read out of such a temporary is copied
    // first.
    fn lower_loop_cond(self: &mut Self, c: NodeId, sp: tok::Span) ir::OperandId {
        self.scope_enter();
        let mark = self.scope_locals.len();
        let mut cop = self.lower_expr(c);
        if cop != ir::IR_NONE && self.scope_locals.len() > mark && self.body.operands.at(cop as usize).kind != ir::OP_CONST {
            cop = self.copy_op(self.spill(cop, sp));
        }
        self.scope_exit();
        return cop;
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
    // field-type substitution for instance owners. A null `args` replaces the projection types of
    // the active copies instead (proj_subst_ty).
    fn proj_ty_map(self: &mut Self, t: TypeId, pm: ModuleId, params: NodeList, args: *const TypeId, n: u32) TypeId {
        if t == TYPE_NONE {
            return t;
        }
        let y = *self.f.ty(t);
        if y.kind == TypeKind::TYPE_GENERIC && args != null {
            let da = unsafe &*(&*self.pkg).module_ast_const(pm);
            for i in 0..n {
                if y.module == pm && unsafe da.list(params)[i as usize] == y.as_data.decl {
                    return unsafe args[i as usize];
                }
            }
            return t;
        }
        if y.kind == TypeKind::TYPE_FIELD_PROJECTION && args == null {
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
        if y.arr_sym() {
            let e = self.proj_ty_map(y.as_data.arr.elem, pm, params, args, n);
            let lt = self.proj_ty_map(y.as_data.arr.len, pm, params, args, n);
            if e == y.as_data.arr.elem && lt == y.as_data.arr.len {
                return t;
            }
            let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
            return sa.intern_array(y.kind, e, lt);
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
        if y.kind == TypeKind::TYPE_INSTANCE || y.fn_sig() {
            let src = *self.f.instance(y.rec());
            let mut na = src;
            let mut changed = false;
            for i in 0..src.n {
                unsafe na.args[i as usize] = self.proj_ty_map(unsafe src.args[i as usize], pm, params, args, n);
                if unsafe na.args[i as usize] != unsafe src.args[i as usize] {
                    changed = true;
                }
            }
            if changed {
                let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
                if y.fn_sig() {
                    return sa.intern_sig_rec(&na, y.qualifier);
                }
                return sa.intern_instance(src.module, src.decl, &na.args[0], src.n);
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
    // The declaration node the active copy of frame `fr` names (a field, a variant or a payload
    // entry), with its module in `out_m`; NONE when out of range.
    fn frame_node(self: &Self, fr: ProjFrame, out_m: &mut ModuleId) NodeId {
        if fr.mode == 0 {
            return self.proj_field_node(fr.owner_st, fr.idx, out_m);
        }
        if fr.mode == 1 {
            return self.proj_variant_node(fr.owner_st, fr.idx, out_m);
        }
        let pv = self.proj_variant_node(fr.owner_st, fr.vidx, out_m);
        if pv == NODE_NONE {
            return NODE_NONE;
        }
        let dap = unsafe &*(&*self.pkg).module_ast_const(*out_m);
        let pls = dap.at_const(pv).as_data.variant.payload;
        if fr.idx >= pls.len as i64 {
            return NODE_NONE;
        }
        return unsafe dap.list(pls)[fr.idx as usize];
    }

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
        return self.proj_member_ty(owner, dm, fid);
    }

    // The TYPE of member declaration `fid` of module `dm` (a struct field, a tuple element or a
    // variant payload entry of `owner`) under the owner's instance args, in THIS pool.
    fn proj_member_ty(self: &mut Self, owner: TypeId, dm: ModuleId, fid: NodeId) TypeId {
        if !self.checked_here(dm, fid) {
            return TYPE_NONE;
        }
        let da = unsafe &*(&*self.pkg).module_ast_const(dm);
        let ftl = da.type_of(da.member_type_node(fid, true));
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
    const fn proj_frame_of(self: &Self, binder: NodeId) i64 {
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
        if self.proj_frames.len() == 0 {
            return t;
        }
        return self.proj_ty_map(t, 0, NodeList { start: 0, len: 0 }, null, 0);
    }

    // The type of result `rn` of a signature: a named result (`(r: T)`) is a parameter node, typed
    // through its type node.
    fn ret_ty(self: &mut Self, rn: NodeId) TypeId {
        let n = *self.f.node(rn);
        return self.nty(pick(n.kind == NodeKind::NODE_PARAMETER, n.as_data.parameter.ty, rn));
    }

    // Every node-type read routes through the active-copy substitution.
    fn nty(self: &mut Self, id: NodeId) TypeId {
        let t = self.f.node_type(id);
        if t == TYPE_ERROR {
            // The checker rejected this node (and reported it): nothing it means can be lowered.
            self.fail_at(ERR_TYPE_SLUG, id);
        }
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
        return self.proj_member_ty(owner, dm, unsafe da.list(pls)[k as usize]);
    }

    // The C-visible tag value of variant `idx`: its (possibly explicit) discriminant.
    fn proj_tag_val(self: &mut Self, owner: TypeId, idx: i64) i64 {
        let mut dm: ModuleId = 0;
        let dn = self.proj_owner_decl(owner, &mut dm);
        if dn == NODE_NONE {
            return idx;
        }
        return self.tag_of_decl(dm, dn, idx);
    }

    // The C tag value of variant `idx` within enum declaration `dn` of module `dm`: its explicit
    // discriminant, else the previous variant's plus one.
    pub fn tag_of_decl(self: &mut Self, dm: ModuleId, dn: NodeId, idx: i64) i64 {
        let da = unsafe &*(&*self.pkg).module_ast_const(dm);
        let ms = da.at_const(dn).as_data.aggregate.members;
        let mut cur: i64 = 0 - 1;
        let mut i: i64 = 0;
        while i <= idx && i < ms.len as i64 {
            cur = self.next_tag(dm, unsafe da.list(ms)[i as usize], cur);
            i += 1;
        }
        return cur;
    }

    // The C tag of every variant of enum declaration `dn` of module `dm`, in declaration order and
    // truncated to the 32 bits a switch value carries: one pass instead of one `tag_of_decl` per
    // switch edge. True when a tag is negative: the discriminant then reads as i32, else as u32.
    fn tags_of_decl(self: &mut Self, dm: ModuleId, dn: NodeId, out: &mut Vector<u32>) bool {
        let da = unsafe &*(&*self.pkg).module_ast_const(dm);
        let ms = da.at_const(dn).as_data.aggregate.members;
        let mut cur: i64 = 0 - 1;
        let mut neg = false;
        for i in 0..ms.len {
            cur = self.next_tag(dm, unsafe da.list(ms)[i as usize], cur);
            neg = neg || cur < 0;
            out.push((cur as u64 & 0xFFFFFFFF) as u32);
        }
        return neg;
    }

    // The type a discriminant of enum declaration `dn` of module `dm` reads as, and in `tag` the
    // tag of its variant `idx`: i32 when a tag is negative, else u32.
    fn tag_ty(self: &mut Self, dm: ModuleId, dn: NodeId, idx: i64, tag: &mut i64) TypeId {
        let da = unsafe &*(&*self.pkg).module_ast_const(dm);
        let ms = da.at_const(dn).as_data.aggregate.members;
        let mut cur: i64 = 0 - 1;
        let mut neg = false;
        for i in 0..ms.len {
            cur = self.next_tag(dm, unsafe da.list(ms)[i as usize], cur);
            neg = neg || cur < 0;
            if i as i64 == idx {
                *tag = cur;
            }
        }
        return Ast::builtin(
            if neg {
                BuiltinType::BT_I32;
            } else {
                BuiltinType::BT_U32;
            },
        );
    }

    // An enum variant's discriminant: its explicit value, else the previous variant's plus one.
    // An explicit value that does not fold fails the lowering (the type check reports it).
    fn next_tag(self: &mut Self, dm: ModuleId, vid: NodeId, prev: i64) i64 {
        if (unsafe &*(&*self.pkg).module_ast_const(dm)).at_const(vid).as_data.variant.value == NODE_NONE {
            return prev + 1;
        }
        let cev = (unsafe (&*self.pkg).cir) as *mut iri::Interp;
        let mut v: i64 = 0;
        if cev == null || !unsafe (*cev).discr(dm, vid, prev, &mut v) {
            self.fail_at("enum-discriminant", vid);
        }
        return v;
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
            let op = self.kop(ir::CK_INT, ty, fr.idx, sp);
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
            if name == "size" {
                let l = self.lay.layout(self.module, fty);
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
                    v = self.lay.field_offset(self.module, fr.owner_st, fid);
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
            if v < 0 {
                self.fail_at("binder-layout", id);
                return ir::IR_NONE;
            }
            if ty == TYPE_NONE {
                ty = Ast::builtin(BuiltinType::BT_USIZE);
            }
            let op = self.kop(ir::CK_INT, ty, v, sp);
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
            let op = self.kop(ir::CK_INT, ty, v, sp);
            return self.spill(op, sp);
        }
        if name == "name" {
            let mut dmn: ModuleId = 0;
            let nid2 = self.frame_node(fr, &mut dmn);
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
        let node = self.frame_node(fr, &mut dm);
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
        return self.kop(ir::CK_INT, cty, v, sp);
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

    /// Fold `sizeof(T) <op> <const-int>` (either side) under the active instance env: sizes are
    /// per-instance constants, and the untaken side of a ZST container branch may not even be
    /// spellable C for this instantiation (pointer arithmetic over an incomplete element type).
    /// -1 = not that shape / not foldable.
    // A closed condition that reads a build constant (PROFILE, or a form the early prune does not
    // decide): 1 or 0 when the engine folds it, else -1. Only the taken branch lowers, so the
    // dead one reaches no later stage and no emitted C.
    fn bc_cond(self: &mut Self, cond: NodeId) i32 {
        let pk = unsafe &*self.pkg;
        if pk.build_module < 0 || pk.cir == null || self.bc_closed(cond, pk.build_module, 0) != 2 {
            return -1;
        }
        let cev = unsafe &mut *(pk.cir as *mut iri::Interp);
        let v = cev.eval(self.module, cond);
        if v.kind != iri::IV_BOOL {
            return -1;
        }
        return (v.i != 0) as i32;
    }

    // 0: `nid` reads a run-time value; 1: it is closed (literals, constants, enum variants and
    // operators over them); 2: it is closed and reads a constant of module `bm`.
    fn bc_closed(self: &Self, nid: NodeId, bm: i32, depth: u32) i32 {
        if nid == NODE_NONE || depth > 24 {
            return 0;
        }
        let n = *self.f.node(nid);
        if n.kind == NodeKind::NODE_LITERAL {
            return 1;
        }
        if n.kind == NodeKind::NODE_UNARY {
            return self.bc_closed(n.as_data.unary.operand, bm, depth + 1);
        }
        if n.kind == NodeKind::NODE_CAST {
            return self.bc_closed(n.as_data.cast.expression, bm, depth + 1);
        }
        if n.kind == NodeKind::NODE_BINARY {
            let l = self.bc_closed(n.as_data.binary.left, bm, depth + 1);
            if l == 0 {
                return 0;
            }
            let r = self.bc_closed(n.as_data.binary.right, bm, depth + 1);
            return if r == 0 {
                0;
            } else if l > r {
                l;
            } else {
                r;
            };
        }
        if n.kind != NodeKind::NODE_IDENTIFIER && (n.kind != NodeKind::NODE_MEMBER || !n.as_data.member.path) {
            return 0;
        }
        let d = self.f.res(nid);
        if d.node == NODE_NONE {
            return 0;
        }
        let dn = unsafe (*(&*self.pkg).module_ast_const(d.module)).at_const(d.node);
        if dn.kind == NodeKind::NODE_VARIANT {
            return 1;
        }
        if dn.kind != NodeKind::NODE_CONST || dn.as_data.const_def.is_static_mut || dn.as_data.const_def.is_extern {
            return 0;
        }
        return if d.module as i32 == bm {
            2;
        } else {
            1;
        };
    }

    // The body of the arm a `switch PROFILE` takes, when every arm is a string literal, an
    // alternative of them or `_`, and no arm has a guard; else NODE_NONE.
    fn bc_profile_arm(self: &Self, d: MatchData) NodeId {
        let pk = unsafe &*self.pkg;
        let vn = self.f.node(d.value);
        if vn.kind != NodeKind::NODE_IDENTIFIER || self.f.res(d.value).module as i32 != pk.build_module {
            return NODE_NONE;
        }
        let sp = vn.as_data.name.text;
        if bc_index(self.src.slice(sp.start as usize, sp.end as usize)) != BC_PROFILE {
            return NODE_NONE;
        }
        let mut taken = NODE_NONE;
        for i in 0..d.arms.len {
            let ad = self.f.node(unsafe self.f.list(d.arms)[i as usize]).as_data.match_arm;
            if ad.guard != NODE_NONE {
                return NODE_NONE;
            }
            let pn = *self.f.node(ad.pattern);
            let mut hit = self.bc_profile_hit(ad.pattern, pk.profile_name());
            if pn.kind == NodeKind::NODE_PATTERN_OR {
                hit = 0;
                for j in 0..pn.as_data.pattern.children.len {
                    let h = self.bc_profile_hit(
                        unsafe self.f.list(pn.as_data.pattern.children)[j as usize],
                        pk.profile_name(),
                    );
                    if h < 0 {
                        return NODE_NONE;
                    }
                    hit = hit | h;
                }
            }
            if hit < 0 {
                return NODE_NONE;
            }
            if hit == 1 && taken == NODE_NONE {
                taken = ad.body;
            }
        }
        return taken;
    }

    // Whether pattern `pat` matches profile `name`: 1 or 0, -1 when it is no plain string literal
    // or `_`.
    fn bc_profile_hit(self: &Self, pat: NodeId, name: str) i32 {
        let pn = self.f.node(pat);
        if pn.kind == NodeKind::NODE_PATTERN_WILDCARD {
            return 1;
        }
        if pn.kind != NodeKind::NODE_PATTERN_LITERAL {
            return -1;
        }
        let ln = self.f.node(pn.as_data.single.value);
        if ln.kind != NodeKind::NODE_LITERAL || ln.as_data.literal.token_type != tt::TokenType::StringLiteral {
            return -1;
        }
        let raw = ln.as_data.literal.raw;
        let text = self.src.slice(raw.start as usize + 1, raw.end as usize - 1);
        if text.find_byte(b'\\') >= 0 {
            return -1;
        }
        return (text == name) as i32;
    }

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
                penv: null,
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
                frames[i].penv = pp9;
            }
        }
        let head = if ne != 0 {
            frames.at(0) as *const lay::LayoutEnv;
        } else {
            null;
        };
        let lo = self.lay.layout_of(self.module, measured, head, 0);
        if !lo.ok && lo.unbound {
            self.body.has_zst_cond = true; // symbolic here: an instance with a fuller env re-lowers
            return -1;
        }
        // A bound type no env can lay out (a const-generic array, an opaque field) is MATERIAL
        // by the same convention storage elision applies (Mangler::is_zst): the fold must be a pure
        // function of the zero-size signature, never of which instantiation lowered the shared
        // variant first.
        let mk = self.f.node(mn).kind;
        let mv = if !lo.ok {
            1i64;
        } else if mk == NodeKind::NODE_SIZEOF {
            lo.size as i64;
        } else {
            lo.align as i64;
        };
        let r = self.binder_cond_cmp(cond, mv, ln, lm);
        if r < 0 {
            self.body.has_zst_cond = true;
        }
        return r;
    }

    // The shared tail of the binder-const `if` fold: the constant side `mv` against the literal
    // side, honoring operand order for the ordered comparisons.
    fn binder_cond_cmp(self: &mut Self, cond: NodeId, mv: i64, lit: NodeId, mem_left: bool) i32 {
        if unsafe (&*self.pkg).cir == null {
            return -1;
        }
        let cev = unsafe &mut *((&*self.pkg).cir as *mut iri::Interp);
        let cv = cev.eval(self.module, lit);
        if cv.kind != iri::IV_INT {
            return -1;
        }
        // (a, b) in source operand order
        let a = if mem_left {
            mv;
        } else {
            cv.i;
        };
        let b = if mem_left {
            cv.i;
        } else {
            mv;
        };
        let op = self.f.node(cond).as_data.binary.op;
        let mut r = false;
        if op == tt::TokenType::EqualEqual {
            r = a == b;
        } else if op == tt::TokenType::BangEqual {
            r = a != b;
        } else if op == tt::TokenType::LessThan {
            r = a < b;
        } else if op == tt::TokenType::GreaterThan {
            r = a > b;
        } else if op == tt::TokenType::LessThanEqual {
            r = a <= b;
        } else if op == tt::TokenType::GreaterThanEqual {
            r = a >= b;
        } else {
            return -1;
        }
        return r as i32;
    }

    // Expand `inline for <bind> in fields/variants/payloads(..)` over the CONCRETE owner: the body
    // lowers once per copy with a frame on the stack. False = owner symbolic (caller falls back).
    fn expand_binder(self: &mut Self, id: NodeId) bool {
        let d = self.f.node(id).as_data.for_stmt;
        let pt = self.nty(id);
        if pt == TYPE_NONE || self.f.ty(pt).kind != TypeKind::TYPE_FIELD_PROJECTION {
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
            return false;
        }
        let owner = self.reintern_ty(orm, ort);
        let mut dm0: ModuleId = 0;
        if self.proj_owner_decl(owner, &mut dm0) == NODE_NONE {
            // A concrete owner without a declaration (a builtin, a pointer, an array) has no fields
            // or variants: zero copies, as an enum's fields loop has. An owner still symbolic keeps
            // the placeholder for the per-instance re-lowering.
            return concrete_kind(self.f.ty(owner).kind);
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
                self.unrolled_body(d.body, id, k != 0);
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
            self.unrolled_body(d.body, id, k != 0);
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
        if mu == null || unsafe (*mu).n == 0 {
            return false;
        }
        let mut tm = self.module;
        let mut tt = unsafe (*mu).args[0];
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
            cev.field_count(dm, dn);
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
                },
                None => {},
            };
            if !resolved && self.f.res(cd.callee).node == NODE_NONE {
                // binder/reflect expansion lowers the body per iteration; the replay sees ONE loop:
                // the first copy's events are the canonical iteration, later copies are muted
                self.for_open(id);
                if self.expand_binder(id) {
                    self.for_close(id);
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
                let l = self.for_binding(id, d.binding, ity, false, sp);
                let pl = self.place_of_local(l);
                self.assign(pl, ir::rv(ir::RV_INTRINSIC, fresh, kept, ir::IN_REFLECT, ity), sp);
                self.tp(ir::TP_BODY_START, 1, id);
                self.lower_stmt(d.body);
                self.tp(ir::TP_BODY_END, 0, id);
                self.for_close(id);
                return;
            }
        }
        if self.f.node(d.iterable).kind != NodeKind::NODE_RANGE {
            // iterator protocol: the checker recorded the selected `next` and its Option return
            switch self.f.call_info(id) {
                Some(ci) => {
                    self.for_open(id);
                    self.lower_for_iter(id, DefId { module: ci_module(ci), node: ci_decl(ci) });
                    self.for_close(id);
                    return;
                },
                None => {},
            };
            let ity = self.nty(d.iterable);
            let ik = self.f.ty(ity).kind;
            if ik == TypeKind::TYPE_INSTANCE && self.is_range_instance(ity) {
                self.for_open(id);
                self.lower_for_range_value(id);
                self.for_close(id);
                return;
            }
            if ik == TypeKind::TYPE_ARRAY || ik == TypeKind::TYPE_SLICE || ik == TypeKind::TYPE_INSTANCE {
                self.for_open(id);
                self.lower_for_indexed(id);
                self.for_close(id);
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
                self.for_open(id);
                if rd.inclusive {
                    hi += 1;
                }
                let mut v = lo;
                while v < hi {
                    let l = self.for_binding(id, d.binding, ity, false, sp);
                    let cvo = self.kop(ir::CK_INT, ity, v, sp);
                    let rvc = self.rv_use(cvo, ity);
                    self.assign(self.place_of_local(l), rvc, sp);
                    self.unrolled_body(d.body, id, v != lo);
                    if self.err.len() != 0 {
                        return;
                    }
                    v += 1;
                }
                self.for_close(id);
                return;
            }
        }
        // `..e` counts from zero; `s..` has no bound check (exit only via break)
        self.for_open(id);
        let sop: ir::OperandId = if rd.start != NODE_NONE {
            self.lower_expr(rd.start);
        } else {
            self.kop(ir::CK_INT, ity, 0, sp);
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
        let l = self.for_binding(id, d.binding, ity, true, sp);
        let ipl = self.place_of_local(l);
        let rv0 = self.rv_use(sop, ity);
        self.assign(ipl, rv0, sp);
        let head = self.open_block();
        let body_b = self.open_block();
        let step = self.open_block();
        let exit = self.open_block();
        self.seal(ir::goto_term(head, sp), head);
        // An exclusive range over a builtin integer whose binding the body cannot assign is a
        // counted loop: its tick moves to the chunk top (`chunk_open`, `chunk_close`).
        let counted = rd.end != NODE_NONE && !rd.inclusive && self.counted_ty(ity) && !self.binding_mut(d.binding) && self.loop_ticks();
        let mut pre = ir::IR_NONE;
        let mut inner = ir::IR_NONE;
        if rd.end == NODE_NONE {
            self.seal(ir::goto_term(body_b, sp), body_b);
        } else {
            let iop = self.copy_op(ipl);
            let eop2 = self.range_end(ecst, epl);
            let cmp_op = if rd.inclusive {
                tt::TokenType::LessThanEqual;
            } else {
                tt::TokenType::LessThan;
            };
            let cop = self.bool_bin(iop, eop2, cmp_op, sp);
            self.branch_bool(cop, body_b, exit, sp);
            if counted {
                inner = self.chunk_open(sp, &mut pre);
            }
        }
        self.loop_body(d.label, exit, step, 0, d.body, id, sp, self.scope_locals.len(), self.defers.len(), !counted);
        self.seal(ir::goto_term(step, sp), step);
        if rd.inclusive {
            // The body ran with `i <= end`: step only while `i < end`, so an end at the type's
            // maximum ends the loop instead of wrapping or trapping the increment.
            let eop3 = self.range_end(ecst, epl);
            let more = self.cmp_test(ipl, eop3, tt::TokenType::LessThan, sp);
            let inc = self.open_block();
            self.branch_bool(more, inc, exit, sp);
        }
        // step: i = i + 1
        let iop2 = self.copy_op(ipl);
        let one = self.kop(ir::CK_INT, ity, 1, sp);
        self.assign(ipl, ir::rv(ir::RV_BINARY, iop2, one, tt::TokenType::Plus as u8, ity), sp);
        self.seal(ir::goto_term(head, sp), exit);
        if counted {
            let eop4 = self.range_end(ecst, epl);
            self.chunk_close(pre, inner, step, ipl, eop4, head, exit, sp);
        }
        self.for_close(id);
    }

    // A fresh operand for a range loop's end: the constant `ecst`, else a copy of `epl`.
    fn range_end(self: &mut Self, ecst: u32, epl: ir::PlaceId) ir::OperandId {
        if ecst != ir::IR_NONE {
            let c = *self.body.constants.at(ecst as usize);
            return self.const_op(c);
        }
        return self.copy_op(epl);
    }

    // Is `t` a builtin integer: a type whose loop index `IN_CHUNK` counts?
    const fn counted_ty(self: &Self, t: TypeId) bool {
        let y = self.f.ty(t);
        if y.kind != TypeKind::TYPE_BUILTIN {
            return false;
        }
        let bt = y.as_data.builtin as u32;
        return bt >= BuiltinType::BT_I8 as u32 && bt <= BuiltinType::BT_USIZE as u32;
    }

    // Does a `for` binding name a mutable local (`for mut i in ..`), which the body may assign?
    const fn binding_mut(self: &Self, binding: NodeId) bool {
        if binding == NODE_NONE {
            return false;
        }
        let bn = self.f.node(binding);
        if bn.kind == NodeKind::NODE_PATTERN_NAME {
            return self.f.node(bn.as_data.pattern.name).as_data.name.is_mutable;
        }
        return bn.kind != NodeKind::NODE_IDENTIFIER && bn.kind != NodeKind::NODE_PATTERN_WILDCARD;
    }

    // A counted loop's chunk top, the open block, entered once `i < end` held: its safepoint, then a
    // goto to the returned block, where the body starts. `pre` receives the chunk top's last block.
    fn chunk_open(self: &mut Self, sp: tok::Span, pre: &mut ir::BlockId) ir::BlockId {
        self.safepoint(sp);
        *pre = self.cur;
        self.body.count_blocks += 1;
        let inner = self.open_block();
        self.seal(ir::goto_term(inner, sp), inner);
        return inner;
    }

    // Strip-mine the counted loop opened by `chunk_open` (its step, sealed with a goto to `head`, is
    // `step`; the open block is `exit`) when its body, the blocks from `inner` on, runs no call, drop
    // or safepoint: then the chunk top goes on to `lim = IN_CHUNK(i, end)` and a test block
    // `i < lim`, which enters the body or returns to `head`, whose `i < end` test starts the next
    // chunk; the step continues at the test, so the chunk's backedges never tick. The body keeps
    // the test as its only predecessor: the branch fact `i < lim` reaches it, and with `lim <= end`
    // (BCE reads IN_CHUNK) so does `i < end`. A body with a call keeps its tick per iteration at
    // the chunk top: a chunk there spares little and costs a chunk end per loop entry.
    fn chunk_close(
        self: &mut Self,
        pre: ir::BlockId,
        inner: ir::BlockId,
        step: ir::BlockId,
        ipl: ir::PlaceId,
        eop: ir::OperandId,
        head: ir::BlockId,
        exit: ir::BlockId,
        sp: tok::Span,
    ) {
        if !self.chunk_free(inner) {
            return;
        }
        self.body.count_blocks += 2;
        self.body.chunks += 1;
        let ity = self.body.places.at(ipl as usize).ty;
        let chunk = self.open_block();
        self.cur = chunk;
        self.run_start = self.body.statements.len() as u32;
        let iop = self.copy_op(ipl);
        let start = self.body.oper_pool.len() as u32;
        self.body.oper_pool.push(iop);
        self.body.oper_pool.push(eop);
        let lim = self.rv_temp(ir::rv(ir::RV_INTRINSIC, start, 2, ir::IN_CHUNK, ity), sp);
        let test = self.open_block();
        self.seal(ir::goto_term(test, sp), test);
        let lop = self.copy_op(lim);
        let more = self.cmp_test(ipl, lop, tt::TokenType::LessThan, sp);
        self.branch_on(more, inner, head, exit, sp);
        self.body.blocks[pre as usize].term.t0 = chunk;
        self.body.blocks[step as usize].term.t0 = test;
    }

    // Do the blocks from `first` on run no call, drop or safepoint?
    const fn chunk_free(self: &Self, first: ir::BlockId) bool {
        for bi in first as usize..self.body.blocks.len() {
            let bb = *self.body.blocks.at(bi);
            if bb.term.kind == ir::TM_CALL || bb.term.kind == ir::TM_DROP {
                return false;
            }
            for si in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                let s = *self.body.statements.at(si as usize);
                if s.kind == ir::ST_ASSIGN {
                    let rv = self.body.rvalues.at(s.rvalue as usize);
                    if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_SAFEPOINT || rv.c == ir::IN_SAFEPOINT_C) {
                        return false;
                    }
                }
            }
        }
        return true;
    }

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
        let l = self.for_binding(id, d.binding, elem, true, sp);
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
        self.seal(ir::goto_term(head, sp), head);
        // cond = (inclusive && x <= end) || (!inclusive && x < end)
        let epl = self.place_project(
            rpl,
            ir::Projection { kind: ir::PJ_FIELD, data: o_end as u32, sub: f_end, ty: elem },
        );
        let ipl = self.place_project(rpl, ir::Projection { kind: ir::PJ_FIELD, data: o_inc as u32, sub: f_inc, ty: bt });
        let le_op = self.lower_cmp2(xpl, epl, tt::TokenType::LessThanEqual, sp);
        let lt_op = self.lower_cmp2(xpl, epl, tt::TokenType::LessThan, sp);
        let inc_op = self.copy_op(ipl);
        let npl = self.rv_temp(ir::rv(ir::RV_UNARY, inc_op, tt::TokenType::Bang as u32, 0, bt), sp);
        let inc_op2 = self.copy_op(ipl);
        let a1 = self.bool_and(inc_op2, le_op, sp);
        let nop = self.copy_op(npl);
        let a2 = self.bool_and(nop, lt_op, sp);
        let cond = self.bool_bin(a1, a2, tt::TokenType::PipePipe, sp);
        self.branch_bool(cond, body_b, exit, sp);
        self.loop_body(d.label, exit, step, 0, d.body, id, sp, self.scope_locals.len(), self.defers.len(), true);
        self.seal(ir::goto_term(step, sp), step);
        // The body ran with `x < end` (or `x <= end`): step only while `x < end`, so an inclusive
        // end at the type's maximum ends the loop instead of wrapping or trapping the increment.
        let more = self.lower_cmp2(xpl, epl, tt::TokenType::LessThan, sp);
        let inc = self.open_block();
        self.branch_bool(more, inc, exit, sp);
        let xop = self.copy_op(xpl);
        let one = self.kop(ir::CK_INT, elem, 1, sp);
        self.assign(xpl, ir::rv(ir::RV_BINARY, xop, one, tt::TokenType::Plus as u8, elem), sp);
        self.seal(ir::goto_term(head, sp), exit);
    }

    fn lower_cmp2(self: &mut Self, l: ir::PlaceId, r: ir::PlaceId, rel: tt::TokenType, sp: tok::Span) ir::OperandId {
        let rop = self.copy_op(r);
        return self.cmp_test(l, rop, rel, sp);
    }

    fn bool_and(self: &mut Self, a: ir::OperandId, b: ir::OperandId, sp: tok::Span) ir::OperandId {
        return self.bool_bin(a, b, tt::TokenType::AmpersandAmpersand, sp);
    }

    fn bool_bin(self: &mut Self, a: ir::OperandId, b: ir::OperandId, op: tt::TokenType, sp: tok::Span) ir::OperandId {
        let bt = Ast::builtin(BuiltinType::BT_BOOL);
        let pl = self.rv_temp(ir::rv(ir::RV_BINARY, a, b, op as u8, bt), sp);
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
        let mu = self.f.type_args(id);
        if mu == null || unsafe (*mu).n == 0 {
            self.fail_at("iter-opt-type", id);
            return;
        }
        let opt_ty = unsafe (*mu).args[0];
        let elem = self.nty(id);
        let mut ok_ord: i64 = -1;
        let vd = self.carrier_variant(opt_ty, "Some", "Ok", &mut ok_ord);
        if ok_ord < 0 {
            self.fail_at("iter-carrier", id);
            return;
        }
        let l = self.for_binding_decl(id, d.binding, elem, true, sp);
        let t = self.temp(opt_ty, sp);
        let tpl = self.place_of_local(t);
        let head = self.open_block();
        let body_b = self.open_block();
        let exit = self.open_block();
        self.seal(ir::goto_term(head, sp), head);
        // t = it.next()
        let recv = self.copy_op(it_pl);
        let start = self.body.oper_pool.len() as u32;
        self.body.oper_pool.push(recv);
        let dstart = self.body.dest_pool.len() as u32;
        self.body.dest_pool.push(tpl);
        let mut tm = ir::term0(ir::TM_CALL, sp);
        tm.callee = next_def;
        tm.a = ir::IR_NONE;
        tm.args_start = start;
        tm.args_len = 1;
        tm.dests_start = dstart;
        tm.dests_len = 1;
        let cont = self.open_block();
        tm.t0 = cont;
        self.seal(tm, cont);
        // A `for` statement's head evaluates nothing unregistered besides `next`'s own result: a
        // clean position unless an enclosing value block masks it, or the narrow std::parallel rule.
        if self.chk_mask == 0 && !self.chk_narrow {
            self.cancel_check_at(next_def, false, tpl, opt_ty, sp);
        } else {
            self.poison_check_at(next_def, false, tpl, sp);
        }
        let ut = Ast::builtin(BuiltinType::BT_U32);
        let dp = self.rv_temp(ir::rv(ir::RV_DISCRIMINANT, tpl, 0, 0, ut), sp);
        let oop = self.kop(ir::CK_INT, ut, ok_ord, sp);
        let cond = self.eq_test(dp, oop, sp);
        self.branch_bool(cond, body_b, exit, sp);
        // x = downcast(t, Some).f0
        let ppl = self.place_project(
            tpl,
            ir::Projection { kind: ir::PJ_DOWNCAST, data: ok_ord as u32, sub: vd.node, ty: opt_ty },
        );
        let fpl = self.place_project(ppl, ir::Projection { kind: ir::PJ_FIELD, data: 0, sub: NODE_NONE, ty: elem });
        let eop = self.copy_op(fpl);
        let lbase = self.iter_binding_live(l, sp);
        let xpl = self.place_of_local(l);
        let erv = self.rv_use(eop, elem);
        self.assign(xpl, erv, sp);
        self.loop_body(d.label, exit, head, 0, d.body, id, sp, lbase, self.defers.len(), true);
        self.iter_binding_dead(lbase);
        self.seal(ir::goto_term(head, sp), exit);
    }

    // `for` over an indexable sequence (array, slice, sequence value): an index loop over RV_LEN
    // with an explicit element load per iteration.
    fn lower_for_indexed(self: &mut Self, id: NodeId) {
        let d = self.f.node(id).as_data.for_stmt;
        let sp = self.f.node(id).span;
        let mut ipl = self.lower_place(d.iterable);
        if ipl == ir::IR_NONE {
            return;
        }
        let elem_ty = self.nty(id);
        // By-value iteration over an owned array whose elements own (the checker's `consumes`):
        // the loop consumes the array into a temp that no scope drops, moves each element into the
        // binding, and frees the elements it did not take at every exit (a TailDrop). Any other
        // loop reads the elements in place.
        let consume = d.consumes && self.f.ty(self.body.places.at(ipl as usize).ty).kind == TypeKind::TYPE_ARRAY && !self.body.place_has_deref(
            ipl,
        ) && self.body.locals.at(self.body.places.at(ipl as usize).base as usize).storage != ir::LS_STATIC_REF;
        if consume {
            let aop = self.copy_op(ipl);
            self.mark_user_move(aop);
            ipl = self.spill(aop, sp);
        }
        let ut = Ast::builtin(BuiltinType::BT_USIZE);
        let lpl = self.len_temp(ipl, sp);
        let il = self.temp(ut, sp);
        let idx_pl = self.place_of_local(il);
        let zero = self.kop(ir::CK_INT, ut, 0, sp);
        let rz = self.rv_use(zero, ut);
        self.assign(idx_pl, rz, sp);
        let dmark = self.defers.len();
        if consume {
            self.defers.push(DEFER_TAIL | self.tail_drops.len() as NodeId);
            self.tail_drops.push(TailDrop { arr: ipl, idx: idx_pl, len: lpl, elem: elem_ty, span: sp });
        }
        let el = self.for_binding_decl(id, d.binding, elem_ty, true, sp);
        let head = self.open_block();
        let body_b = self.open_block();
        let step = self.open_block();
        let exit = self.open_block();
        self.seal(ir::goto_term(head, sp), head);
        let iop = self.copy_op(idx_pl);
        let lop = self.copy_op(lpl);
        let cop = self.bool_bin(iop, lop, tt::TokenType::LessThan, sp);
        self.branch_bool(cop, body_b, exit, sp);
        // A counted loop: its tick moves to the chunk top (`chunk_open`, `chunk_close`), before the
        // element load. A consuming loop keeps its tick after the load: its cancellation ladder's
        // TailDrop frees the elements after the one the binding took.
        let counted = !consume && self.loop_ticks();
        let mut pre = ir::IR_NONE;
        let mut inner = ir::IR_NONE;
        if counted {
            inner = self.chunk_open(sp, &mut pre);
        }
        let iop2 = self.copy_op(idx_pl);
        let mut iop_e = iop2;
        if self.checked_view(self.peeled_view_ty(ipl)) {
            // normalized element check against the cached loop length; BCE proves it from the
            // loop guard (index < length) and marks it PROVEN
            let lop_e = self.copy_op(lpl);
            let ck_e = self.bounds_check_len(iop2, lop_e, NODE_NONE, sp);
            iop_e = self.copy_op(ck_e);
        }
        let epl = self.place_project(ipl, ir::Projection { kind: ir::PJ_INDEX_OP, data: iop_e, sub: 0, ty: elem_ty });
        let eop = self.copy_op(epl);
        if !consume {
            // The element leaves storage the loop does not own: the checker's move rules decide.
            self.mark_user_move(eop);
        }
        let erv = self.rv_use(eop, elem_ty);
        let lbase = self.iter_binding_live(el, sp);
        let bind_pl = self.place_of_local(el);
        self.assign(bind_pl, erv, sp);
        self.loop_body(d.label, exit, step, 0, d.body, id, sp, lbase, dmark, !counted);
        self.iter_binding_dead(lbase);
        self.seal(ir::goto_term(step, sp), step);
        let iop3 = self.copy_op(idx_pl);
        let one = self.kop(ir::CK_INT, ut, 1, sp);
        self.assign(idx_pl, ir::rv(ir::RV_BINARY, iop3, one, tt::TokenType::Plus as u8, ut), sp);
        self.seal(ir::goto_term(head, sp), exit);
        if counted {
            let lop4 = self.copy_op(lpl);
            self.chunk_close(pre, inner, step, idx_pl, lop4, head, exit, sp);
        }
        // Every exit but the normal one (which took every element) ran the TailDrop on its way,
        // inside the loop: the index it reads is the loop's own.
        self.defers.truncate(dmark);
    }

    // ---- expressions ------------------------------------------------------------------------------

    // Lower expression `id` and return its operand, or IR_NONE on failure. Adjustments (coercion,
    // dyn erasure) recorded at the node wrap the base operand here, so consumers never re-read the
    // side tables.
    fn lower_expr(self: &mut Self, id: NodeId) ir::OperandId {
        return self.lower_expr_d(id, ir::IR_NONE);
    }

    // Lower expression `id` so its value lands in place `dest`, the destination of a `let`, a
    // return value, an arm or a scrutinee (contract below). False when it fails to lower. `user`:
    // the value is a user consumption (`mark_user_move`) when it is read from a place. `sp` is the
    // span of the store into `dest` when no producer writes it (the statement's).
    //
    // The destination contract: nothing the expression evaluates reads, names, borrows or drops
    // `dest`, and `dest` holds no value to drop. A value written there early is then unobservable,
    // so a producer (an `if`, `switch` or block arm, a loop's `break`, an aggregate, a call, a
    // conversion) stores its result into `dest` itself instead of into a temporary the caller
    // copies. A fresh `let` local, a return slot (in which no call writes, `emit_call`) and a fresh
    // temporary hold it. An assignment's place does not: the old value drops after the new one is
    // computed and the place may be read by it (`x = f(x)`), and an arm's defers and its locals'
    // drops run after its value is stored.
    fn lower_into(self: &mut Self, id: NodeId, dest: ir::PlaceId, user: bool, sp: tok::Span) bool {
        let op = self.lower_expr_d(id, dest);
        if op == ir::IR_NONE {
            return false;
        }
        if op != WROTE {
            if user {
                self.mark_user_move(op);
            }
            let ty = self.body.places.at(dest as usize).ty;
            self.assign(dest, self.rv_use(op, ty), sp);
        }
        return true;
    }

    // A fresh temp holding the value of `id`, the place of a spilled operand; IR_NONE when it fails
    // to lower. The value lowers into the temp (`lower_into`) when its type is the node's, so no
    // temporary that a spill copies precedes it. `user` and `sp`, the temp's span, as for
    // `lower_into`.
    fn value_temp(self: &mut Self, id: NodeId, user: bool, sp: tok::Span) ir::PlaceId {
        if self.plain_value(id) && self.nty(id) != TYPE_NONE {
            let pl = self.place_of_local(self.temp(self.nty(id), sp));
            if !self.lower_into(id, pl, user, sp) {
                return ir::IR_NONE;
            }
            return pl;
        }
        let op = self.lower_expr(id);
        if op == ir::IR_NONE {
            return ir::IR_NONE;
        }
        if user {
            self.mark_user_move(op);
        }
        return self.spill(op, sp);
    }

    // The one rvalue that defines whole-local place `pl` after the lowering that wrote statements
    // `s0..` and opened blocks `b0..` from open block `blk0`: its one write there, when that is in the
    // open block (every path of the lowering ends through it). IR_NONE otherwise.
    const fn built_def(self: &Self, pl: ir::PlaceId, s0: u32, b0: u32, blk0: ir::BlockId) ir::RvalueId {
        let b = &self.body;
        let x = b.places.at(pl as usize).base;
        if b.places.at(pl as usize).proj_len != 0 {
            return ir::IR_NONE;
        }
        let mut n: u32 = 0;
        let mut rid = ir::IR_NONE;
        for i in s0..b.statements.len() as u32 {
            let st = *b.statements.at(i as usize);
            if st.kind == ir::ST_ASSIGN && b.places.at(st.place as usize).base == x {
                n += 1;
                if i >= self.run_start && b.places.at(st.place as usize).proj_len == 0 {
                    rid = st.rvalue;
                }
            }
        }
        // A call the lowering sealed may write it as its destination: block `blk0` is visited first.
        for i in b0..b.blocks.len() as u32 + 1 {
            let t = b.blocks.at(pick(i == b0, blk0, i - 1) as usize).term;
            for j in 0..pick(t.kind == ir::TM_CALL, t.dests_len, 0) {
                let d = b.dest_pool[(t.dests_start + j) as usize];
                if d != ir::IR_NONE && b.places.at(d as usize).base == x {
                    return ir::IR_NONE;
                }
            }
        }
        return pick(n == 1, rid, ir::IR_NONE);
    }

    // Record that rvalue `rid` is the one definition of local `l` (`known`).
    fn note_known(self: &mut Self, l: ir::LocalId, rid: ir::RvalueId) {
        self.known.insert(l, rid);
        self.known_keys.push(l);
    }

    // Forget the definitions recorded since `known_keys` held `mark` keys.
    fn forget_known(self: &mut Self, mark: usize) {
        for i in mark..self.known_keys.len() {
            self.known.remove(&self.known_keys[i]);
        }
        self.known_keys.truncate(mark);
    }

    // The variant of the enum value place `pl` reads, when the lowering saw it built: through the
    // locals whose one definition it knows (`known`), their copies, and the struct, tuple and payload
    // members of their aggregates. NODE_NONE otherwise.
    fn place_variant(self: &Self, pl: ir::PlaceId) DefId {
        let none = DefId { module: 0, node: NODE_NONE };
        let b = &self.body;
        // The projections still to apply (`path[at..n]`); a longer path is unknown.
        let mut path = Array::<u32, 8> {};
        let mut n: usize = 0;
        let mut at: usize = 0;
        let mut x = ir::IR_NONE;
        let mut next = pl;
        // Each round reads one place or crosses one aggregate member.
        for _ in 0..16 {
            if next != ir::IR_NONE {
                // Place `next`'s projections go before the rest of the path.
                let q = *b.places.at(next as usize);
                let m = q.proj_len as usize;
                if m + n - at > 8 {
                    return none;
                }
                let mut tmp = Array::<u32, 8> {};
                for i in 0..m {
                    tmp[i] = q.proj_start + i as u32;
                }
                for i in at..n {
                    tmp[m + i - at] = path[i];
                }
                path = tmp;
                n = m + n - at;
                at = 0;
                x = q.base;
                next = ir::IR_NONE;
            }
            let rid = switch self.known.get(&x) {
                Some(v) => *v,
                None => ir::IR_NONE,
            };
            if rid == ir::IR_NONE {
                return none;
            }
            let rv = *b.rvalues.at(rid as usize);
            if rv.kind == ir::RV_USE {
                let op = *b.operands.at(rv.a as usize);
                if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
                    return none;
                }
                next = op.data;
                continue;
            }
            if rv.kind != ir::RV_AGGREGATE {
                return none;
            }
            if at == n {
                return pick(rv.c == ir::AGG_VARIANT, rv.item, none);
            }
            let mut pj = *b.projections.at(path[at] as usize);
            if pj.kind == ir::PJ_DOWNCAST {
                if rv.c != ir::AGG_VARIANT || rv.item.node != pj.sub || at + 1 == n {
                    return none;
                }
                at += 1;
                pj = *b.projections.at(path[at] as usize);
            } else if rv.c != ir::AGG_STRUCT && rv.c != ir::AGG_TUPLE {
                return none;
            }
            if pj.kind != ir::PJ_FIELD || pj.data == ir::PJ_UNION_FIELD {
                return none;
            }
            // A tuple literal names no declaration: its type's does (`Tuple2`).
            let k = if pj.data != ir::IR_NONE {
                pj.data as i64;
            } else {
                self.member_pos(pick(rv.item.node != NODE_NONE, rv.item, self.nominal_of(rv.target)), pj.sub);
            };
            if k < 0 || k >= rv.b as i64 {
                return none;
            }
            let o = b.oper_pool[(rv.a + k as u32) as usize];
            if o == ir::IR_NONE {
                return none;
            }
            let mo = *b.operands.at(o as usize);
            if mo.kind != ir::OP_COPY && mo.kind != ir::OP_MOVE {
                return none;
            }
            at += 1;
            next = mo.data;
        }
        return none;
    }

    // The position of member `sub` in struct or variant declaration `d`, or -1.
    fn member_pos(self: &Self, d: DefId, sub: NodeId) i64 {
        if d.node == NODE_NONE || sub == NODE_NONE {
            return -1;
        }
        let da = unsafe &*(&*self.pkg).module_ast_const(d.module);
        let nd = da.at_const(d.node);
        let ms = if nd.kind == NodeKind::NODE_VARIANT {
            nd.as_data.variant.payload;
        } else if nd.kind == NodeKind::NODE_STRUCT {
            nd.as_data.aggregate.members;
        } else {
            return -1;
        };
        for j in 0..ms.len {
            if unsafe da.list(ms)[j as usize] == sub {
                return j;
            }
        }
        return -1;
    }

    // Whether the checker recorded no conversion on node `id` that `apply_adjust` applies: its
    // base value is its value.
    fn plain_value(self: &Self, id: NodeId) bool {
        if self.f.coercion(id) != null || self.f.dyn_conv(id) != null || self.f.wide_lit(id) != null {
            return false;
        }
        let n = self.f.node(id);
        let star = n.kind == NodeKind::NODE_UNARY && n.as_data.unary.op == tt::TokenType::Star;
        return n.kind == NodeKind::NODE_MEMBER || star || self.f.derefs(id) == null;
    }

    // `lower_expr` with destination `dest` (IR_NONE: none): WROTE when the value was stored there.
    fn lower_expr_d(self: &mut Self, id: NodeId, dest: ir::PlaceId) ir::OperandId {
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
                if co != null && unsafe (*co).method.node == NODE_NONE {
                    let target = unsafe (*co).target;
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
                return self.addr_op(apl, self.nty(id), pty, sp, dest);
            }
        }
        // The base value is the value when no conversion follows it.
        let mut bdest = ir::IR_NONE;
        if dest != ir::IR_NONE && self.plain_value(id) && self.nty(id) == self.body.places.at(dest as usize).ty {
            bdest = dest;
        }
        let base = self.lower_expr_base(id, bdest);
        if base == ir::IR_NONE || base == WROTE {
            return base;
        }
        return self.apply_adjust_d(id, base, self.f.node(id).span, dest);
    }

    // Apply the conversions the checker recorded on node `id` to its value `base`, at span `sp`.
    fn apply_adjust(self: &mut Self, id: NodeId, base: ir::OperandId, sp: tok::Span) ir::OperandId {
        return self.apply_adjust_d(id, base, sp, ir::IR_NONE);
    }

    // `apply_adjust` whose last conversion stores into destination `dest` (`rv_out`).
    fn apply_adjust_d(self: &mut Self, id: NodeId, base: ir::OperandId, sp: tok::Span, dest: ir::PlaceId) ir::OperandId {
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
                    let steps = unsafe (*du).n;
                    for s in 0..steps {
                        let m = unsafe (*du).method[s as usize];
                        if m.node == NODE_NONE {
                            continue; // a raw pointer/reference hop changes no representation
                        }
                        let rt = unsafe (*du).recv[s as usize];
                        let mut rt2 = self.deref_ret_ty(m, rt);
                        if rt2 == TYPE_NONE {
                            rt2 = rt;
                        }
                        let start = self.body.oper_pool.len() as u32;
                        self.body.oper_pool.push(op);
                        let rpl = self.emit_call_to(
                            m,
                            ir::IR_NONE,
                            start,
                            1,
                            0,
                            0,
                            TYPE_NONE,
                            TYPE_NONE,
                            rt2,
                            sp,
                            ir::IR_NONE,
                        );
                        self.maybe_cancel_check(id, m, false, rpl, rt2, sp);
                        op = self.copy_op(rpl);
                    }
                }
            }
        }
        // An array the checker coerced to a slice view: the node records the view and the operand
        // keeps the array. The view temp is the one place the emitter builds `{ arr, N }`; it
        // borrows the array (`b` = the view kind), so an array temporary lives to the scope's end.
        // A call records the view as a conversion and keeps its array type.
        // Each conversion below stores into `dest` when no later one follows it.
        let mut co = self.f.coercion(id);
        let dy = self.f.dyn_conv(id);
        {
            let ot = self.body.operands.at(op as usize).ty;
            if ot != TYPE_NONE && self.f.ty(ot).kind == TypeKind::TYPE_ARRAY {
                let mut vt = self.nty(id);
                if co != null && self.view_kind(unsafe (*co).target) != 0 {
                    vt = unsafe (*co).target;
                    co = null;
                }
                let fin = pick(co == null && dy == null, dest, ir::IR_NONE);
                let vk = self.view_kind(vt);
                if vk != 0 {
                    op = self.view_of(op, id, vt, vk, sp, fin);
                } else if vt != TYPE_NONE && self.f.ty(vt).kind == TypeKind::TYPE_SIMD {
                    // An array literal the checker typed as a vector: its array, then the lanes.
                    op = self.rv_out(fin, ir::rv(ir::RV_CAST, op, ir::CAST_SIMD_ARRAY, 0, vt), sp);
                }
                if op == WROTE {
                    return op;
                }
            }
        }
        if co != null && self.view_kind(unsafe (*co).target) == 1 && self.view_kind(
            self.body.operands.at(op as usize).ty,
        ) == 2 {
            // `[]mut T` as `[]T`: the shared view borrows the view, as an array's view borrows it.
            op = self.rv_out(pick(dy == null, dest, ir::IR_NONE), ir::rv(ir::RV_USE, op, 1, 0, unsafe (*co).target), sp);
            if op == WROTE {
                return op;
            }
            co = null;
        }
        if co != null && self.f.wide_lit(id) != null {
            // a wide literal already CARRIES the target-width limbs: the widening `from` shim
            // would truncate through its scalar parameter, so the constant retypes instead
            let target = unsafe (*co).target;
            let wi = unsafe (&*(&*self.pkg).module_ast_const(self.body.module)).wide_lit_of(id);
            return self.kop(ir::CK_WIDE, target, wi, sp);
        }
        if co != null {
            let target = unsafe (*co).target;
            let method = unsafe (*co).method;
            let ck: u8 = if method.node != NODE_NONE {
                ir::CAST_COERCE_FROM;
            } else {
                ir::CAST_NUMERIC;
            };
            op = self.rv_out(
                pick(dy == null, dest, ir::IR_NONE),
                ir::Rvalue { kind: ir::RV_CAST, a: op, b: ck, c: 0, target: target, item: method },
                sp,
            );
            if op == WROTE {
                return op;
            }
        }
        if dy != null {
            let dt = unsafe (*dy).dyn_ty;
            op = self.rv_out(dest, ir::rv(ir::RV_DYN, op, unsafe (*dy).alloc, 0, dt), sp);
        }
        return op;
    }

    // Is parameter `i` of the call's callee (`target`, else the function value `callee_op`) of a
    // raw-pointer type?
    fn param_is_ptr(self: &mut Self, target: DefId, callee_op: ir::OperandId, i: u32) bool {
        if target.node != NODE_NONE {
            let ca = unsafe &*(&*self.pkg).module_ast_const(target.module);
            let n = ca.at_const(target.node);
            if n.kind != NodeKind::NODE_FUNCTION || i >= n.as_data.function.params.len {
                return false;
            }
            let pn = ca.at_const(unsafe ca.list(n.as_data.function.params)[i as usize]).as_data.parameter.ty;
            return pn != NODE_NONE && ca.at_const(pn).kind == NodeKind::NODE_POINTER_TYPE;
        }
        if callee_op == ir::IR_NONE {
            return false;
        }
        let fy = *self.f.ty(self.body.operands.at(callee_op as usize).ty);
        let sa = unsafe &*(&*self.pkg).module_ast_const(self.module);
        if !fy.fn_sig() || i >= sa.sig_len(&fy, false) {
            return false;
        }
        return self.f.ty(sa.sig_at(&fy, false, i)).kind == TypeKind::TYPE_POINTER;
    }

    // Expression `e` lowered into a slot of raw-pointer type when `ptr`: a reference becomes the
    // pointer where it is made, as `as` makes it, so the borrow it took ends there.
    fn lower_slot(self: &mut Self, e: NodeId, ptr: bool, sp: tok::Span) ir::OperandId {
        let op = self.lower_expr(e);
        if !ptr || op == ir::IR_NONE {
            return op;
        }
        let ot = self.body.operands.at(op as usize).ty;
        if ot == TYPE_NONE || self.f.ty(ot).kind != TypeKind::TYPE_REFERENCE {
            return op;
        }
        let y = *self.f.ty(ot);
        let q = if y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            TypeQualifier::TYPE_QUAL_MUT as u8;
        } else {
            TypeQualifier::TYPE_QUAL_CONST as u8;
        };
        let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
        let pt = sa.intern_type(
            Ty { kind: TypeKind::TYPE_POINTER, qualifier: q, as_data: TyAs { elem: y.as_data.elem } },
        );
        let r = self.copy_op(self.rv_temp(ir::rv(ir::RV_CAST, op, self.cast_kind(ot, pt), 0, pt), sp));
        self.tp(ir::TP_CAST_ERASE, 0, e);
        return r;
    }

    // The view of kind `vk` and type `vt` of array operand `op`, stored into `dest` (`rv_out`); a
    // temporary array lives in the scope `key` registers it in (`own_temp`).
    fn view_of(self: &mut Self, op: ir::OperandId, key: NodeId, vt: TypeId, vk: u32, sp: tok::Span, dest: ir::PlaceId) ir::OperandId {
        let _ = self.own_temp(op, key);
        return self.rv_out(dest, ir::rv(ir::RV_USE, op, vk, 0, vt), sp);
    }

    // Value `op` of `if`, `switch` or block arm `arm` as `ty`, the type of the whole expression: the
    // checker types the whole expression as a slice when the arms yield arrays, so each arm's array
    // becomes its view here, at span `sp`.
    fn arm_view(self: &mut Self, op: ir::OperandId, arm: NodeId, ty: TypeId, sp: tok::Span, dest: ir::PlaceId) ir::OperandId {
        let ot = self.body.operands.at(op as usize).ty;
        if ot == TYPE_NONE || self.f.ty(ot).kind != TypeKind::TYPE_ARRAY {
            return op;
        }
        let vk = self.view_kind(ty);
        if vk == 0 {
            return op;
        }
        return self.view_of(op, arm, ty, vk, sp, dest);
    }

    // The value of node `id` before its conversions; a producer stores it into `dest` (IR_NONE:
    // none) when the destination holds its type (`rv_out`, `out_place`): WROTE.
    fn lower_expr_base(self: &mut Self, id: NodeId, dest: ir::PlaceId) ir::OperandId {
        let k = self.f.node(id).kind;
        let sp = self.f.node(id).span;
        let ty = self.nty(id);
        // `type_info::<T>().qualified_name` read alone: the name constant, no descriptor.
        if k == NodeKind::NODE_MEMBER && self.node_name_eq(self.f.node(id).as_data.member.member, "qualified_name") {
            let call = self.f.node(id).as_data.member.object;
            if self.f.node(call).kind == NodeKind::NODE_CALL && self.is_intrinsic_callee(
                self.f.node(call).as_data.call.callee,
                "type_info",
            ) {
                let mu = self.f.type_args(call);
                if mu != null && unsafe (*mu).n != 0 {
                    return self.intrinsic_value(ir::IN_TYPE_NAME, unsafe (*mu).args[0], ty, sp, dest);
                }
            }
        }
        if k == NodeKind::NODE_LITERAL {
            return self.lower_literal(id);
        }
        if k == NodeKind::NODE_IDENTIFIER || k == NodeKind::NODE_MEMBER || k == NodeKind::NODE_INDEX {
            // An item that is a value, no place: its value, not a temporary that copies it.
            let vi = self.value_item(id);
            if vi.node != NODE_NONE {
                return self.item_value(id, vi, ty, sp, dest);
            }
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
                        let outer = inner0;
                        inner0 = inn.as_data.unary.operand;
                        if inn.as_data.unary.op == tt::TokenType::Unsafe {
                            self.note_unsafe(outer);
                        }
                        continue;
                    }
                    break;
                }
                let ik = self.f.node(inner0).kind;
                let deref0 = ik == NodeKind::NODE_UNARY && self.f.node(inner0).as_data.unary.op == tt::TokenType::Star;
                if ik == NodeKind::NODE_IDENTIFIER || ik == NodeKind::NODE_MEMBER || ik == NodeKind::NODE_INDEX || deref0 {
                    let pl = self.lower_place(id);
                    if pl == ir::IR_NONE {
                        return ir::IR_NONE;
                    }
                    return self.copy_op(pl);
                }
            }
            return self.lower_unary(id, dest);
        }
        if k == NodeKind::NODE_BINARY {
            return self.lower_binary(id, dest);
        }
        if k == NodeKind::NODE_ASSIGNMENT {
            return self.lower_assignment(id);
        }
        if k == NodeKind::NODE_CALL {
            return self.lower_call(id, dest);
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
                        let outer = e;
                        e = en.as_data.unary.operand;
                        if en.as_data.unary.op == tt::TokenType::Unsafe {
                            self.note_unsafe(outer);
                        }
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
                        let a = self.addr_op(apl, self.nty(e), ty, sp, dest);
                        if er9 {
                            self.tp(ir::TP_CAST_ERASE, 0, d.expression);
                        }
                        return a;
                    }
                }
            }
            let op = self.lower_expr(d.expression);
            if op == ir::IR_NONE || self.f.dyn_conv(d.expression) != null {
                // A cast to a dyn type is the erasure the operand's lowering already performed.
                return op;
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
            let ck = self.cast_kind(self.body.operands.at(op as usize).ty, cty);
            let r = self.rv_out(dest, ir::rv(ir::RV_CAST, op, ck, 0, cty), sp);
            if er9 {
                self.tp(ir::TP_CAST_ERASE, 0, d.expression);
            }
            return r;
        }
        if k == NodeKind::NODE_STRUCT_INITIALIZER {
            return self.lower_struct_init(id, dest);
        }
        if k == NodeKind::NODE_ARRAY_LITERAL || k == NodeKind::NODE_TUPLE {
            return self.lower_array_or_tuple(id, dest);
        }
        if k == NodeKind::NODE_RANGE {
            return self.lower_range(id, dest);
        }
        if k == NodeKind::NODE_IF {
            return self.lower_if_expr(id, dest);
        }
        if k == NodeKind::NODE_MATCH {
            let pl = self.out_place(dest, ty, sp);
            if !self.lower_match(id, pl) {
                return ir::IR_NONE;
            }
            return self.out_op(dest, pl);
        }
        if k == NodeKind::NODE_WHILE {
            // `loop { .. break v; .. }` in value position
            let pl = self.out_place(dest, ty, sp);
            self.lower_loop_expr(id, pl);
            return self.out_op(dest, pl);
        }
        if k == NodeKind::NODE_BLOCK {
            // A block in value position is a build-constant `if` or `switch` the early prune
            // replaced by its taken arm: the temporaries its value borrows live as long as that
            // arm's would (`ExtCx`).
            let pl = self.out_place(dest, ty, sp);
            let outer = self.ext;
            self.ext = ExtCx { arm: id, val: self.value_tail(id), rf: NODE_NONE, depth: self.ext_depth_for(id) };
            self.lower_value_block(id, pl, false);
            self.ext = outer;
            return self.out_op(dest, pl);
        }
        if k == NodeKind::NODE_SIZEOF || k == NodeKind::NODE_ALIGNOF {
            let ik: u8 = if k == NodeKind::NODE_SIZEOF {
                ir::IN_SIZEOF;
            } else {
                ir::IN_ALIGNOF;
            };
            return self.intrinsic_value(ik, self.nty(self.f.node(id).as_data.single.value), ty, sp, dest);
        }
        if k == NodeKind::NODE_VA_EXPR {
            return self.lower_va(id, dest);
        }
        if k == NodeKind::NODE_CLOSURE {
            return self.lower_closure(id, dest);
        }
        if k == NodeKind::NODE_GENERIC_SPECIALIZATION {
            let d = self.f.node(id).as_data.specialization;
            return self.lower_expr_named(d.expression, id);
        }
        if k == NodeKind::NODE_TYPE_PATH {
            // A path in value position: unit variant construction or an item constant.
            return self.lower_path_value(id, dest);
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
                    ir::Constant { kind: ir::CK_ITEM, ty: ty, val: ir::targ_val(ts, tn), raw: sp, item: d },
                );
            }
        }
        return self.lower_expr(inner);
    }

    fn lower_literal(self: &mut Self, id: NodeId) ir::OperandId {
        let d = self.f.node(id).as_data.literal;
        let ty = self.nty(id);
        let w = self.f.wide_lit(id);
        if w != null {
            // `val` carries the wide_lits pool INDEX (the emitter reads the limbs back by it)
            let wi = unsafe (&*(&*self.pkg).module_ast_const(self.body.module)).wide_lit_of(id);
            return self.kop(ir::CK_WIDE, ty, wi, d.raw);
        }
        let t = d.token_type;
        if t == tt::TokenType::True {
            return self.kop(ir::CK_BOOL, ty, 1, d.raw);
        }
        if t == tt::TokenType::False {
            return self.kop(ir::CK_BOOL, ty, 0, d.raw);
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
            return self.kop(ir::CK_STR, ty, t as i64 | segf, d.raw);
        }
        if t == tt::TokenType::FloatLiteral {
            return self.kop(ir::CK_FLOAT, ty, 0, d.raw);
        }
        if t == tt::TokenType::Null {
            return self.kop(ir::CK_INT, ty, 0, d.raw);
        }
        // Char/byte-char literals: `val` IS the decoded code point (the C spelling prints it).
        if t == tt::TokenType::CharacterLiteral || t == tt::TokenType::ByteCharacterLiteral {
            return self.kop(ir::CK_INT, ty, tok::char_literal_value(self.src, d.raw).unwrap_or(0), d.raw);
        }
        // Integer literals: `val` is the exact value of every spelling (hex, binary, octal,
        // separators, suffixes); 0 past u64::MAX, which the checker reports.
        let c = ir::Constant {
            kind: ir::CK_INT,
            ty: ty,
            val: 0,
            raw: d.raw,
            item: DefId { module: 0, node: NODE_NONE },
        };
        let mut v: i64 = 0;
        let _ = c.int_value(self.src, &mut v);
        return self.kop(ir::CK_INT, ty, v, d.raw);
    }

    fn lower_unary(self: &mut Self, id: NodeId, dest: ir::PlaceId) ir::OperandId {
        let d = self.f.node(id).as_data.unary;
        if d.op == tt::TokenType::Move || d.op == tt::TokenType::Unsafe {
            // `move` or `unsafe` over a value that is not a place (a literal, a closure, a call) is
            // that value: no temporary hides it from the analyses that read it. `lower_expr` noted
            // the `unsafe` span.
            return self.lower_expr_d(d.operand, dest);
        }
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        if d.op == tt::TokenType::Ampersand && ty != TYPE_NONE && self.f.ty(ty).kind == TypeKind::TYPE_REFERENCE && self.f.derefs(
            id,
        ) == null {
            // `&*e` of a raw-pointer value that is no place (`&*(p + i)`): that pointer, retyped, so
            // no temporary holds it only to be dereferenced. A reborrow through a raw pointer holds
            // no loan either way.
            let on = *self.f.node(d.operand);
            if on.kind == NodeKind::NODE_UNARY && on.as_data.unary.op == tt::TokenType::Star && self.f.derefs(d.operand) == null {
                let inner = on.as_data.unary.operand;
                let it = self.nty(inner);
                let ik = self.f.node(inner).kind;
                if it != TYPE_NONE && self.f.ty(it).kind == TypeKind::TYPE_POINTER && (ik == NodeKind::NODE_BINARY || ik == NodeKind::NODE_CALL) {
                    self.tp(ir::TP_REF, 0, id);
                    let pop = self.lower_expr(inner);
                    if pop == ir::IR_NONE {
                        return ir::IR_NONE;
                    }
                    return self.rv_out(dest, ir::rv(ir::RV_USE, pop, 0, 0, ty), sp);
                }
            }
        }
        if d.op == tt::TokenType::Ampersand || d.op == tt::TokenType::AmpersandAmpersand {
            // `&` as an arm's value: the temporary it borrows lives as the arm's value needs.
            let rf = self.ext.rf;
            if self.ext_on(id) {
                self.ext.rf = d.operand;
            }
            let pl = self.lower_place(d.operand);
            self.ext.rf = rf;
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
            return self.rv_out(dest, ir::rv(rk, pl, mutable, 0, bty), sp);
        }
        if d.op == tt::TokenType::Star {
            let pl = self.lower_place(id);
            if pl == ir::IR_NONE {
                return ir::IR_NONE;
            }
            return self.copy_op(pl);
        }
        if d.op == tt::TokenType::Question {
            return self.lower_question(id, d.operand, dest);
        }
        // A negative wide literal records its (two's-complemented) limbs on the UNARY node.
        if self.f.wide_lit(id) != null {
            let wi = unsafe (&*(&*self.pkg).module_ast_const(self.body.module)).wide_lit_of(id);
            return self.kop(ir::CK_WIDE, ty, wi, sp);
        }
        // A negative integer literal folds to ONE constant; a spelled value too wide for the
        // checker's default i32 carries in i64 (the old emitter's textual `-...LL` behavior). Any
        // other literal operand lowers once and continues below.
        let mut op = ir::IR_NONE;
        if d.op == tt::TokenType::Minus && self.f.node(d.operand).kind == NodeKind::NODE_LITERAL {
            let mut mag: u64 = 0;
            let lit_ok = lit_int_value(self.src, self.f.node(d.operand).as_data.literal.raw, &mut mag);
            op = self.lower_expr(d.operand);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            if lit_ok {
                let o9 = *self.body.operands.at(op as usize);
                if o9.kind == ir::OP_CONST {
                    let c9 = *self.body.constants.at(o9.data as usize);
                    if c9.kind == ir::CK_INT {
                        let v9 = mag.wrapping_neg() as i64;
                        let mut ty9 = ty;
                        if (v9 < -2147483648 || v9 > 2147483647) && ty9 != TYPE_NONE {
                            let yv = *self.f.ty(ty9);
                            if yv.kind == TypeKind::TYPE_BUILTIN && (yv.as_data.builtin == BuiltinType::BT_I32 || yv.as_data.builtin == BuiltinType::BT_I16 || yv.as_data.builtin == BuiltinType::BT_I8) {
                                ty9 = Ast::builtin(BuiltinType::BT_I64);
                            }
                        }
                        return self.kop(ir::CK_INT, ty9, v9, sp);
                    }
                }
            }
        }
        if op == ir::IR_NONE {
            op = self.lower_expr(d.operand);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
        }
        // Overloaded unary (`-` via Neg, `!` via Not) resolves through op_method like binaries.
        switch self.f.op_method(id) {
            Some(m) => {
                return self.lower_op_call_from(
                    id,
                    (m >> 32) as ModuleId,
                    (m & 0xFFFFFFFFu64) as NodeId,
                    op,
                    NODE_NONE,
                    ty,
                    false,
                    dest,
                );
            },
            None => {},
        };
        return self.rv_out(dest, ir::rv(ir::RV_UNARY, op, d.op as u32, 0, ty), sp);
    }

    // `expr?`: test the carrier's discriminant; the ok arm yields the payload, the error arm writes
    // the converted error variant into the return slot and returns through the pending defers and
    // storage deaths.
    fn lower_question(self: &mut Self, id: NodeId, operand: NodeId, dest: ir::PlaceId) ir::OperandId {
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        // `?` consumes the carrier like any other user move.
        let vpl = self.value_temp(operand, true, sp);
        if vpl == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let mut ok_ord: i64 = -1;
        let vd = self.carrier_variant(self.body.places.at(vpl as usize).ty, "Some", "Ok", &mut ok_ord);
        if ok_ord < 0 {
            self.fail_at("question-carrier", id);
            return ir::IR_NONE;
        }
        let ut = Ast::builtin(BuiltinType::BT_U32);
        let dp = self.rv_temp(ir::rv(ir::RV_DISCRIMINANT, vpl, 0, 0, ut), sp);
        let oop = self.kop(ir::CK_INT, ut, ok_ord, sp);
        let eq = self.eq_test(dp, oop, sp);
        let start = self.body.oper_pool.len() as u32;
        self.body.oper_pool.push(eq);
        let cond = self.copy_op(
            self.rv_temp(ir::rv(ir::RV_INTRINSIC, start, 1, ir::IN_LIKELY, Ast::builtin(BuiltinType::BT_BOOL)), sp),
        );
        let ok_b = self.open_block();
        let err_b = self.open_block();
        // true -> ok_b, otherwise err_b; keep writing the ERROR path first, then seal into ok_b.
        self.branch_on(cond, ok_b, err_b, err_b, sp);
        // error path: read the error payload (Err has one; None has none), convert it through the
        // checker-selected `from` when the error types differ, and rewrap it as the RETURN type's
        // error variant into slot 0
        if self.body.returns != 0 {
            let vty = self.body.places.at(vpl as usize).ty;
            let mut err_ord: i64 = -1;
            let evd = self.carrier_variant(vty, "None", "Err", &mut err_ord);
            let rt = self.body.locals.at(0).ty;
            let mut rerr: i64 = -1;
            let rev = self.carrier_variant(rt, "None", "Err", &mut rerr);
            if err_ord < 0 || rerr < 0 {
                self.fail_at("question-variants", id);
                return ir::IR_NONE;
            }
            let start = self.body.oper_pool.len() as u32;
            let mut n: u32 = 0;
            if self.has_payload(evd) && self.has_payload(rev) {
                let epl0 = self.place_project(
                    vpl,
                    ir::Projection { kind: ir::PJ_DOWNCAST, data: err_ord as u32, sub: evd.node, ty: vty },
                );
                let ety = self.proj_payload_ty(vty, err_ord, 0);
                let epl = self.place_project(
                    epl0,
                    ir::Projection { kind: ir::PJ_FIELD, data: 0, sub: NODE_NONE, ty: ety },
                );
                let mut eop = self.copy_op(epl);
                let conv = self.f.res(id);
                if conv.node != NODE_NONE {
                    let cty = self.proj_payload_ty(rt, rerr, 0);
                    let cstart = self.body.oper_pool.len() as u32;
                    self.body.oper_pool.push(eop);
                    eop = self.emit_call(conv, ir::IR_NONE, cstart, 1, 0, 0, TYPE_NONE, TYPE_NONE, cty, sp);
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
        self.emit_deads_down_to(0);
        self.seal(ir::term0(ir::TM_RETURN, sp), ok_b);
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
        // The payload leaves the consumed carrier through a plumbing move (as a pattern bind does), so
        // the caller's user move reads a whole temp, not a field of a Free value.
        return self.rv_out(dest, self.rv_use(self.copy_op(fpl), ty), sp);
    }

    // Whether variant `vd` carries a payload.
    const fn has_payload(self: &Self, vd: DefId) bool {
        return unsafe (&*(&*self.pkg).module_ast_const(vd.module)).at_const(vd.node).as_data.variant.payload.len != 0;
    }

    // The variant spelled `n1` or `n2` of enum-carrier type `t` (Option/Result, an enum or its
    // instance), and its ordinal in `ord`; NONE and ord -1 when `t` has no such variant.
    fn carrier_variant(self: &Self, t: TypeId, n1: str, n2: str, ord: &mut i64) DefId {
        return self.variant_named(self.nominal_of(t), n1, n2, ord);
    }

    // The declaration of struct, enum or instance type `t`; NONE for any other type.
    const fn nominal_of(self: &Self, t: TypeId) DefId {
        let y = *self.f.ty(t);
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.f.instance(y.as_data.inst);
            return DefId { module: it.module, node: it.decl };
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return DefId { module: y.module, node: y.as_data.decl };
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    // The variant spelled `n1` or `n2` of enum `e`, and its ordinal in `ord`; NONE and ord -1 when
    // `e` is not an enum or has no such variant.
    fn variant_named(self: &Self, e: DefId, n1: str, n2: str, ord: &mut i64) DefId {
        *ord = -1;
        if e.node == NODE_NONE {
            return e;
        }
        let a = unsafe &*(&*self.pkg).module_ast_const(e.module);
        if a.at_const(e.node).kind != NodeKind::NODE_ENUM {
            return DefId { module: 0, node: NODE_NONE };
        }
        let src = unsafe (&*self.pkg).modules.at(e.module as usize).source.as_str();
        let ms = a.at_const(e.node).as_data.aggregate.members;
        for j in 0..ms.len {
            let vn = unsafe a.list(ms)[j as usize];
            let nsp = a.at_const(a.at_const(vn).as_data.variant.name).as_data.name.text;
            let nm = src.slice(nsp.start as usize, nsp.end as usize);
            if nm == n1 || nm == n2 {
                *ord = j;
                return DefId { module: e.module, node: vn };
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    // A left-associative chain (`x + x + ... + x`) nests on its left operand. Its left spine is
    // lowered with a loop, so the stack depth does not grow with the chain: each node's setup runs
    // outermost first and the rest of its work innermost first, the order recursion would give.
    // The root's value lands in `dest` (`rv_out`).
    fn lower_binary(self: &mut Self, id: NodeId, dest: ir::PlaceId) ir::OperandId {
        let mut spine = self.avget(); // node, setup place, destination triples
        let mut n = id;
        let mut up = dest; // the destination of `n`'s value
        loop {
            let rpl = self.lower_binary_setup(n, up);
            spine.push(n);
            spine.push(rpl);
            spine.push(up);
            let l = self.f.node(n).as_data.binary.left;
            // The left operand of `&&`/`||` that is itself one writes the parent's result place:
            // the parent's first store would copy it there.
            up = ir::IR_NONE;
            if rpl != ir::IR_NONE && self.short_circuit(l) && self.plain_value(l) && self.nty(l) == self.nty(n) {
                up = rpl;
            }
            n = l;
            if self.f.node(n).kind != NodeKind::NODE_BINARY {
                break;
            }
        }
        let mut op = self.lower_expr(n);
        let mut i = spine.len();
        while i > 0 && op != ir::IR_NONE {
            i -= 3;
            let b = spine[i];
            op = self.lower_binary_rest(b, spine[i + 1], op, spine[i + 2]);
            if b != id && op != ir::IR_NONE && op != WROTE {
                op = self.apply_adjust(b, op, self.f.node(b).span);
            }
        }
        self.avput(spine);
        return op;
    }

    // Whether node `id` is an `&&` or `||`.
    const fn short_circuit(self: &Self, id: NodeId) bool {
        let n = self.f.node(id);
        return n.kind == NodeKind::NODE_BINARY && (n.as_data.binary.op == tt::TokenType::AmpersandAmpersand || n.as_data.binary.op == tt::TokenType::PipePipe);
    }

    // The work of binary node `id` before its left operand: the result place of `&&`/`||`, which is
    // `dest` when it holds the result's type (IR_NONE for the other operators).
    fn lower_binary_setup(self: &mut Self, id: NodeId, dest: ir::PlaceId) ir::PlaceId {
        if !self.short_circuit(id) {
            return ir::IR_NONE;
        }
        return self.out_place(dest, self.nty(id), self.f.node(id).span);
    }

    // The work of binary node `id` after its left operand `lop` (WROTE: a left `&&`/`||` stored it
    // into `rpl`, `lower_binary`); `rpl` is its setup place, and the value lands in `dest`
    // (`rv_out`).
    fn lower_binary_rest(self: &mut Self, id: NodeId, rpl: ir::PlaceId, lop: ir::OperandId, dest: ir::PlaceId) ir::OperandId {
        let d = self.f.node(id).as_data.binary;
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        if d.op == tt::TokenType::AmpersandAmpersand || d.op == tt::TokenType::PipePipe {
            // result = lhs; if (deciding) result = rhs
            if lop != WROTE {
                let rv = self.rv_use(lop, ty);
                self.assign(rpl, rv, sp);
            }
            let rhs_b = self.open_block();
            let join = self.open_block();
            let cop = self.copy_op(rpl);
            if d.op == tt::TokenType::AmpersandAmpersand {
                self.branch_bool(cop, rhs_b, join, sp);
            } else {
                // ||: false -> evaluate rhs
                let mut tm = ir::term0(ir::TM_SWITCH, sp);
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
            self.assign(rpl, rv2, sp);
            self.seal(ir::goto_term(join, sp), join);
            return self.out_op(dest, rpl);
        }
        switch self.f.op_method(id) {
            Some(m) => {
                let eq = d.op == tt::TokenType::EqualEqual || d.op == tt::TokenType::BangEqual;
                let ord = d.op == tt::TokenType::LessThan || d.op == tt::TokenType::LessThanEqual || d.op == tt::TokenType::GreaterThan || d.op == tt::TokenType::GreaterThanEqual;
                if !eq && !ord {
                    return self.lower_op_call_from(
                        id,
                        (m >> 32) as ModuleId,
                        (m & 0xFFFFFFFFu64) as NodeId,
                        lop,
                        d.right,
                        ty,
                        false,
                        dest,
                    );
                }
                // A comparison of aggregates: `eq` decides `==` and `!=`, `cmp`'s sign the ordering. It
                // reads its operands and never consumes them: a temporary operand (`mk() == s`) is
                // dropped by its scope.
                self.own_operand(lop, d.left);
                let it = Ast::builtin(BuiltinType::BT_I32);
                let r = self.lower_op_call_from(
                    id,
                    (m >> 32) as ModuleId,
                    (m & 0xFFFFFFFFu64) as NodeId,
                    lop,
                    d.right,
                    pick(eq, ty, it),
                    true,
                    pick(d.op == tt::TokenType::EqualEqual, dest, ir::IR_NONE),
                );
                if r == ir::IR_NONE || d.op == tt::TokenType::EqualEqual {
                    return r;
                }
                if eq {
                    return self.rv_out(dest, ir::rv(ir::RV_UNARY, r, tt::TokenType::Bang as u32, 0, ty), sp);
                }
                let zero = self.kop(ir::CK_INT, it, 0, sp);
                return self.rv_out(dest, ir::rv(ir::RV_BINARY, r, zero, d.op as u8, ty), sp);
            },
            None => {},
        };
        let rop = self.lower_expr(d.right);
        if rop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        // The operator reads its operands and never consumes them: a temporary operand (an owning
        // comparison side such as `mk() == s`) is dropped by its scope.
        self.own_operand(lop, d.left);
        self.own_operand(rop, d.right);
        return self.rv_out(dest, ir::rv(ir::RV_BINARY, lop, rop, d.op as u8, ty), sp);
    }

    // An operator method call (binary/compound/unary/index overloads) after the receiver: `lop` is the
    // lowered left operand; `ty` is the result type, which lands in `dest` (`emit_call_to`).
    fn lower_op_call_from(
        self: &mut Self,
        id: NodeId,
        m: ModuleId,
        decl: NodeId,
        lop: ir::OperandId,
        rhs: NodeId,
        ty: TypeId,
        reads: bool,
        dest: ir::PlaceId,
    ) ir::OperandId {
        let sp = self.f.node(id).span;
        if self.is_intrinsic_fn(DefId { module: m, node: decl }) {
            let mut argv = self.avget();
            argv.push(lop);
            // A vector operator: the operation over the values (`lower_intrinsic`), no call.
            let rop = if rhs != NODE_NONE {
                self.lower_expr(rhs);
            } else {
                lop;
            };
            if rop == ir::IR_NONE {
                return ir::IR_NONE;
            }
            if rhs != NODE_NONE {
                argv.push(rop);
            }
            let r = self.lower_intrinsic(DefId { module: m, node: decl }, &mut argv, ty, sp);
            self.avput(argv);
            return r;
        }
        let recv = self.op_recv(DefId { module: m, node: decl }, lop, sp);
        let mut rop = ir::IR_NONE;
        if rhs != NODE_NONE {
            rop = self.lower_expr(rhs);
            if rop == ir::IR_NONE {
                return ir::IR_NONE;
            }
            if reads {
                self.own_operand(rop, rhs);
            }
        }
        return self.lower_op_call_ops(id, m, decl, recv, rop, ty, dest);
    }

    // The receiver operand `lop` of operator method `md`: a constant receiver (`2.0 * v` through
    // `extend f32 as Mul<V>`) of a by-reference `self` borrows a temporary.
    fn op_recv(self: &mut Self, md: DefId, lop: ir::OperandId, sp: tok::Span) ir::OperandId {
        if self.body.operands.at(lop as usize).kind == ir::OP_CONST && self.param_is_ref(md, 0) {
            return self.copy_op(self.spill(lop, sp));
        }
        return lop;
    }

    // The call of operator method `decl` on node `id` over the lowered receiver `lop` (`op_recv`) and
    // right operand `rop` (IR_NONE: none); `ty` is the result type, which lands in `dest`
    // (`emit_call_to`).
    fn lower_op_call_ops(
        self: &mut Self,
        id: NodeId,
        m: ModuleId,
        decl: NodeId,
        lop: ir::OperandId,
        rop_in: ir::OperandId,
        ty: TypeId,
        dest: ir::PlaceId,
    ) ir::OperandId {
        let sp = self.f.node(id).span;
        let mut argv = self.avget();
        argv.push(lop);
        if rop_in != ir::IR_NONE {
            let mut rop = rop_in;
            // A by-reference parameter (`other: &i32`) borrows the right operand, as `m.add(&n)` does:
            // the operand's place, or a temporary holding a constant (`m + 5`). A numeric operand of
            // another type arrives converted (`operand_fits_param`).
            let ro = *self.body.operands.at(rop as usize);
            let by_val = ro.ty == TYPE_NONE || self.f.ty(ro.ty).kind != TypeKind::TYPE_REFERENCE;
            if by_val && self.param_is_ref(DefId { module: m, node: decl }, 1) {
                let pl = if ro.kind == ir::OP_CONST {
                    self.spill(rop, sp);
                } else {
                    ro.data;
                };
                let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
                let rty = sa.intern_type(
                    Ty { kind: TypeKind::TYPE_REFERENCE, as_data: TyAs { elem: self.body.places.at(pl as usize).ty } },
                );
                rop = self.copy_op(self.rv_temp(ir::rv(ir::RV_REF, pl, 0, 0, rty), sp));
            }
            argv.push(rop);
        }
        let start = self.pool_ops(&argv);
        let n = argv.len() as u32;
        self.avput(argv);
        // Through a type parameter's bound: the conformance each instance dispatches to.
        let bc = self.proj_subst_ty(self.f.bound_call(id));
        // A keyed extend's operator (`ext_keyed`) names the extend's arguments, as a call does.
        let ts = self.body.targ_pool.len() as u32;
        let tn = self.copy_targs(id);
        let rpl = self.emit_call_to(
            DefId { module: m, node: decl },
            ir::IR_NONE,
            start,
            n,
            ts,
            tn,
            bc,
            TYPE_NONE,
            ty,
            sp,
            dest,
        );
        // The operator's implicit call is checked like an explicit one; a compound assignment checks
        // after it stores the result (`lower_assignment`).
        if self.f.node(id).kind != NodeKind::NODE_ASSIGNMENT {
            self.maybe_cancel_check(id, DefId { module: m, node: decl }, false, rpl, ty, sp);
        } else if !self.chk_has(id) || !self.chk_place_clean(self.f.node(id).as_data.binary.left) {
            // Unchecked after the store: poison must not reach the place.
            self.poison_check_at(DefId { module: m, node: decl }, false, rpl, sp);
        }
        return self.out_op(dest, rpl);
    }

    // Whether parameter `i` of function `f` is declared a reference.
    const fn param_is_ref(self: &Self, f: DefId, i: u32) bool {
        let fa = unsafe (&*self.pkg).module_ast_const(f.module);
        let fnn = unsafe (*fa).at_const(f.node);
        if fnn.kind != NodeKind::NODE_FUNCTION || i >= fnn.as_data.function.params.len {
            return false;
        }
        let pn = unsafe (*fa).at_const(unsafe (*fa).list(fnn.as_data.function.params)[i as usize]);
        if pn.kind != NodeKind::NODE_PARAMETER || pn.as_data.parameter.ty == NODE_NONE {
            return false;
        }
        return unsafe (*fa).at_const(pn.as_data.parameter.ty).kind == NodeKind::NODE_REFERENCE_TYPE;
    }

    // Copy the checker's bound generic arguments for `node` into targ_pool; returns the count
    // (the range starts at the pool length the caller sampled first).
    fn copy_targs(self: &mut Self, node: NodeId) u32 {
        let mu = self.f.type_args(node);
        if mu == null {
            return 0;
        }
        let n = unsafe (*mu).n;
        for i in 0..n {
            if unsafe (*mu).args[i as usize] == TYPE_ERROR {
                self.fail_at(ERR_TYPE_SLUG, node);
            }
            let ta = self.proj_subst_ty(unsafe (*mu).args[i as usize]);
            self.body.targ_pool.push(ta);
        }
        return n;
    }

    // Shared call emission: args already in oper_pool[start, start+n); `iface` is the conformance a
    // bound call dispatches to (`Terminator.iface`). Returns the result operand.
    fn emit_call(
        self: &mut Self,
        callee: DefId,
        callee_op: ir::OperandId,
        start: u32,
        n: u32,
        targs_start: u32,
        targs_len: u32,
        iface: TypeId,
        recv: TypeId,
        ty: TypeId,
        sp: tok::Span,
    ) ir::OperandId {
        return self.copy_op(
            self.emit_call_to(callee, callee_op, start, n, targs_start, targs_len, iface, recv, ty, sp, ir::IR_NONE),
        );
    }

    // `emit_call` whose result lands in destination `dest` (`out_place`); returns the result's
    // place. A return slot is never a call's destination: the slot's store before `return`
    // spells `return f(..)` (the emitter's return-slot forwarding), and a tail call is a call
    // into a temporary moved into the slot (`ir::tailcall`).
    fn emit_call_to(
        self: &mut Self,
        callee: DefId,
        callee_op: ir::OperandId,
        start: u32,
        n: u32,
        targs_start: u32,
        targs_len: u32,
        iface: TypeId,
        recv: TypeId,
        ty: TypeId,
        sp: tok::Span,
        dest: ir::PlaceId,
    ) ir::PlaceId {
        let mut d = dest;
        if d != ir::IR_NONE && self.body.locals.at(self.body.places.at(d as usize).base as usize).storage == ir::LS_RET {
            d = ir::IR_NONE;
        }
        let dst = self.out_place(d, ty, sp);
        let dstart = self.body.dest_pool.len() as u32;
        self.body.dest_pool.push(dst);
        let mut tm = ir::term0(ir::TM_CALL, sp);
        tm.callee = callee;
        tm.a = callee_op;
        tm.args_start = start;
        tm.args_len = n;
        tm.dests_start = dstart;
        tm.dests_len = 1;
        tm.targs_start = targs_start;
        tm.targs_len = targs_len;
        tm.iface = iface;
        tm.recv = recv;
        tm.intr = self.call_intr(callee, start, n);
        let cont = self.open_block();
        tm.t0 = cont;
        self.seal(tm, cont);
        if ty != TYPE_NONE && self.f.ty(ty).kind == TypeKind::TYPE_NEVER {
            // The call does not return: its `never` result exists nowhere, and the code that reads
            // it lowers into a block no edge reaches.
            let dead = self.open_block();
            self.seal(ir::term0(ir::TM_UNREACHABLE, sp), dead);
        }
        return dst;
    }

    // The verified intrinsic kind of a call of `callee` with the `n` arguments at `start`: the callee
    // is the extern routine `ir::ci_of_name` names (by its `@import` C name when it has one), the arity
    // matches, and the first argument is a pointer or a reference (a fence takes none). CI_NONE otherwise.
    const fn call_intr(self: &Self, callee: DefId, start: u32, n: u32) u8 {
        if callee.node == NODE_NONE {
            return ir::CI_NONE;
        }
        let a = unsafe &*(&*self.pkg).module_ast_const(callee.module);
        let nd = a.at_const(callee.node);
        if nd.kind != NodeKind::NODE_FUNCTION || !nd.as_data.function.is_extern() {
            return ir::CI_NONE;
        }
        let at = a.attr_of(callee.node, AttrKind::ATTR_IMPORT);
        let nsp = if at != null {
            unsafe (*at).str_span;
        } else {
            a.at_const(nd.as_data.function.name).as_data.name.text;
        };
        let src = unsafe (&*self.pkg).modules.at(callee.module as usize).source.as_str();
        let k = ir::ci_of_name(src.slice(nsp.start as usize, nsp.end as usize));
        if k == ir::CI_NONE || ir::ci_arity(k) != n {
            return ir::CI_NONE;
        }
        if k != ir::CI_FENCE {
            let op = *self.body.operands.at(self.body.oper_pool[start as usize] as usize);
            let pk = self.f.ty(op.ty).kind;
            if pk != TypeKind::TYPE_POINTER && pk != TypeKind::TYPE_REFERENCE {
                return ir::CI_NONE;
            }
        }
        return k;
    }

    // A call, or the aggregate or intrinsic a call spells; its value lands in `dest`
    // (`emit_call_to`, `rv_out`).
    fn lower_call(self: &mut Self, id: NodeId, dest: ir::PlaceId) ir::OperandId {
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
                let r9 = self.finish_aggregate(agg, vd, &argv, ty, sp, dest);
                self.avput(argv);
                return r9;
            }
        }
        // Method call: receiver first, then arguments; the selected target comes from call_info.
        let ci = self.f.call_info(id);
        let mut target = DefId { module: 0, node: NODE_NONE };
        switch ci {
            Some(v) => {
                // A field callee (`t.1()`, `w.f()`) whose type names a function item records that
                // function with no receiver slot: it calls the stored value, like a fn-pointer field.
                if ck != NodeKind::NODE_MEMBER || self.f.node(d.callee).as_data.member.path || (v & 0xFFu64) != 0 {
                    target = DefId { module: ci_module(v), node: ci_decl(v) };
                }
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
        // A `const fn` call with constant arguments runs at compile time: its value replaces it.
        if target.node != NODE_NONE {
            let fo = self.fold_call(id, target, ty, sp);
            if fo != ir::IR_NONE {
                return fo;
            }
        }
        // `type_info::<T>()` / `zeroed::<T>()`: compiler intrinsics, not resolved functions.
        if target.node == NODE_NONE && self.is_intrinsic_callee(d.callee, "type_info") {
            // the subject type rides in `b` so the backend can name the exported descriptor
            let mu = self.f.type_args(id);
            let mut bt9 = TYPE_NONE;
            if mu != null && unsafe (*mu).n != 0 {
                bt9 = unsafe (*mu).args[0];
            }
            return self.intrinsic_value(ir::IN_TYPE_INFO, bt9, ty, sp, dest);
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
            let svd = self.carrier_variant(ty, "Some", "Ok", &mut sord);
            let mut nord: i64 = -1;
            let nvd = self.carrier_variant(ty, "None", "None", &mut nord);
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
            self.assign(self.place_of_local(fl), ir::rv(ir::RV_INTRINSIC, fstart, 1, ir::IN_DYN_TID, rt9), sp);
            let rpl = self.out_place(dest, ty, sp);
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
            self.assign(self.place_of_local(dv), ir::rv(ir::RV_INTRINSIC, dstart, 1, ir::IN_DYN_DATA, rt9), sp);
            let mut sargs = self.avget();
            sargs.push(self.copy_op(self.place_of_local(dv)));
            let _ = self.finish_aggregate(ir::AGG_VARIANT, svd, &sargs, ty, sp, rpl);
            self.avput(sargs);
            self.seal(ir::goto_term(join, sp), none_b);
            let nargs = self.avget();
            let _ = self.finish_aggregate(ir::AGG_VARIANT, nvd, &nargs, ty, sp, rpl);
            self.avput(nargs);
            self.seal(ir::goto_term(join, sp), join);
            return self.out_op(dest, rpl);
        }
        if target.node == NODE_NONE && self.is_intrinsic_callee(d.callee, "zeroed") {
            return self.intrinsic_value(ir::IN_ZEROED, 0, ty, sp, dest);
        }
        if target.node == NODE_NONE && self.is_intrinsic_callee(d.callee, "dangling") {
            // the pointee rides in `b` so the backend can pick the sentinel alignment
            let mu = self.f.type_args(id);
            let mut bt9 = TYPE_NONE;
            if mu != null && unsafe (*mu).n != 0 {
                bt9 = unsafe (*mu).args[0];
            }
            return self.intrinsic_value(ir::IN_DANGLING, bt9, ty, sp, dest);
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
        // `x.free()` with no resolved method (a dyn value, or a synthesized destructor): destruction
        // IS the call. Lower it as an explicit drop so the analyses see the consume and the backend
        // prints glue.
        if target.node == NODE_NONE && unsafe (&*self.f.ast).is_free_call(id, self.src) {
            let obj = self.f.node(d.callee).as_data.member.object;
            let opl = self.lower_place(obj);
            if opl == ir::IR_NONE {
                return ir::IR_NONE;
            }
            self.tp(ir::TP_CALL, 1, id);
            let mut tm = ir::term0(ir::TM_DROP, sp);
            tm.a = opl;
            let cont = self.open_block();
            tm.t0 = cont;
            self.seal(tm, cont);
            return self.unit_op(ty, sp);
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
            if du9 != null && unsafe (*du9).n > 0 {
                let mut base9 = self.lower_place(recv);
                if base9 == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                base9 = self.apply_place_derefs(base9, du9, recv, sp);
                if base9 == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                rop = self.copy_op(base9);
            } else {
                rop = self.lower_expr(recv);
            }
            if rop == ir::IR_NONE {
                return ir::IR_NONE;
            }
            if du9 == null || unsafe (*du9).n == 0 {
                // a temporary RECEIVER owns its value: scope-drop it after use (the deref-chain
                // path lowers the receiver as a place, which registers it)
                let _ = self.own_temp(rop, recv);
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
                // A constant receiver of a `&self` method (`7i64.twice()`) borrows a temporary.
                if ptk1 == NodeKind::NODE_REFERENCE_TYPE && self.body.operands.at(rop as usize).kind == ir::OP_CONST {
                    rop = self.copy_op(self.spill(rop, sp));
                }
                // The checker looks the method up on the receiver's referent: a receiver behind more
                // than one reference (`s.len()` with `s: &&String`) reads through the extra ones, so
                // the call takes one reference, or the value of a by-value `self`.
                if ptk1 != NodeKind::NODE_POINTER_TYPE && (du9 == null || unsafe (*du9).n == 0) {
                    for _ in 0..8 {
                        let ry = *self.f.ty(self.body.operands.at(rop as usize).ty);
                        if ry.kind != TypeKind::TYPE_REFERENCE || self.f.ty(ry.as_data.elem).kind != TypeKind::TYPE_REFERENCE {
                            break;
                        }
                        let ro = *self.body.operands.at(rop as usize);
                        let rpl = if ro.kind == ir::OP_COPY || ro.kind == ir::OP_MOVE {
                            ro.data;
                        } else {
                            self.spill(rop, sp);
                        };
                        rop = self.copy_op(
                            self.place_project(
                                rpl,
                                ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: ry.as_data.elem },
                            ),
                        );
                    }
                }
            }
            rop = self.pin_read(rop, recv, d.args, 0, target, 0);
            argv.push(rop);
        } else if target.node == NODE_NONE {
            // fn-value call (closure, fn pointer): the callee is an operand
            callee_op = self.lower_expr(d.callee);
            if callee_op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            // A reference to a `dyn fn` value or a function pointer calls its pointee (the
            // checker's `tc_ref_callable`).
            for _ in 0..8 {
                let cy = *self.f.ty(self.body.operands.at(callee_op as usize).ty);
                if cy.kind != TypeKind::TYPE_REFERENCE || !self.ref_callable(cy.as_data.elem) {
                    break;
                }
                let pl = self.spill(callee_op, sp);
                callee_op = self.copy_op(
                    self.place_project(pl, ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: cy.as_data.elem }),
                );
            }
        } else {
            // direct call: nothing to evaluate for the callee
        }
        self.tp(ir::TP_CALL_MARK, 0, id);
        // A vector operation's index list is a constant, read by `index_op`, never a run-time value.
        let mut lst = false;
        if target.node != NODE_NONE && self.is_intrinsic_fn(target) {
            let ik = self.intrinsic_code(target);
            lst = ik >> 8 == ir::SI_SIMD && ir::simd_op(ik as u8).rule == ir::SR_INDEX;
        }
        for i in 0..d.args.len {
            let a = unsafe self.f.list(d.args)[i as usize];
            if lst && i + 1 == d.args.len {
                self.list_node = a;
                continue;
            }
            let mut op = self.lower_slot(a, self.param_is_ptr(target, callee_op, argv.len() as u32), sp);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            self.mark_user_move(op);
            op = self.pin_read(op, a, d.args, i + 1, target, argv.len());
            argv.push(op);
        }
        self.tp(ir::TP_CALL, 0, id);
        let ts = self.body.targ_pool.len() as u32;
        let mut tn = self.copy_targs(id);
        if tn == 0 {
            // `Type::<Args>::assoc()`: the bound args ride the CALLEE (or its qualifying path),
            // not the call node
            tn = self.copy_targs(d.callee);
            // Only a path's qualifier carries them: a method call's receiver may be a turbofished
            // call of its own (`x.m::<u8>().get()`), whose arguments are not this call's. A member of
            // an extend without parameters (`extend String { fn mk() .. }`) binds none, so the
            // qualifier's (`String<Global>`) are not its call's.
            if tn == 0 && self.f.node(d.callee).kind == NodeKind::NODE_MEMBER && self.f.node(d.callee).as_data.member.path && (target.node == NODE_NONE || unsafe (*(&*self.pkg).module_ast_const(
                target.module,
            )).extend_arity(target.node) != 0) {
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
                    let mut it9 = TyInstance {};
                    if is_ty9 && oty9 != TYPE_NONE && self.f.targs_of(oty9, &mut it9) {
                        for k9 in 0..it9.n {
                            self.body.targ_pool.push(unsafe it9.args[k9 as usize]);
                        }
                        tn = it9.n;
                    }
                }
            }
        }
        if target.node != NODE_NONE && self.is_intrinsic_fn(target) {
            self.body.targ_pool.truncate(ts as usize);
            let r = self.lower_intrinsic(target, &mut argv, ty, sp);
            self.avput(argv);
            return r;
        }
        let start = self.pool_ops(&argv);
        let n = argv.len() as u32;
        self.avput(argv);
        let bc = self.proj_subst_ty(self.f.bound_call(id));
        // `T::count()` / `Self::make()`: an interface's associated function through a type parameter
        // names its implementor by the parameter, whatever its result or first argument are; through a
        // type (`P::twice()`, an inherited default), by that type.
        let mut impl9 = TYPE_NONE;
        // The member path that names the callee, under a turbofish (`T::f::<U>(..)`) too.
        let mut pm9 = NODE_NONE;
        if ck == NodeKind::NODE_GENERIC_SPECIALIZATION {
            // `Type::<Args>::f::<U>()`: the qualifying instance names the receiver of a function
            // whose own arguments are the call's.
            let in9 = self.f.node(d.callee).as_data.specialization.expression;
            if self.f.node(in9).kind == NodeKind::NODE_MEMBER && self.f.node(in9).as_data.member.path {
                pm9 = in9;
                let q9 = self.nty(self.f.node(in9).as_data.member.object);
                if q9 != TYPE_NONE && (self.f.ty(q9).kind == TypeKind::TYPE_INSTANCE || self.f.ty(q9).is_vec()) {
                    impl9 = q9;
                }
            }
        } else if ck == NodeKind::NODE_MEMBER && self.f.node(d.callee).as_data.member.path {
            pm9 = d.callee;
            // `Type::<Args>::f(..)`: the qualifying instance names the receiver of an associated
            // function of a generic extend (it has no receiver value), and of a function with
            // parameters of its own (the call's bound args are the function's, as under a turbofish).
            let fa9 = unsafe (&*self.pkg).module_ast_const(target.module);
            if target.node != NODE_NONE && (unsafe (*fa9).extend_arity(target.node) > 0 && !unsafe (&*self.pkg).self_first(
                target,
            ) || self.decl_kind(target) == NodeKind::NODE_FUNCTION && unsafe (*fa9).at_const(target.node).as_data.function.generics.len != 0) {
                let q9 = self.nty(self.f.node(d.callee).as_data.member.object);
                if q9 != TYPE_NONE && (self.f.ty(q9).kind == TypeKind::TYPE_INSTANCE || self.f.ty(q9).is_vec()) {
                    impl9 = q9;
                }
            }
        }
        if impl9 == TYPE_NONE && pm9 != NODE_NONE && target.node != NODE_NONE && iface_of_member(
            unsafe &*(&*self.pkg).module_ast_const(target.module),
            target.node,
        ) != NODE_NONE {
            let od9 = self.f.res(self.f.node(pm9).as_data.member.object);
            if od9.node != NODE_NONE && (self.decl_kind(od9) == NodeKind::NODE_GENERIC_PARAM || self.decl_kind(od9) == NodeKind::NODE_INTERFACE) {
                let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
                impl9 = sa.intern_type(
                    Ty { kind: TypeKind::TYPE_GENERIC, module: od9.module, as_data: TyAs { decl: od9.node } },
                );
            } else {
                impl9 = self.nty(self.f.node(pm9).as_data.member.object);
            }
        }
        let rpl = self.emit_call_to(target, callee_op, start, n, ts, tn, bc, impl9, ty, sp, dest);
        self.maybe_cancel_check(id, target, callee_op != ir::IR_NONE, rpl, ty, sp);
        return self.out_op(dest, rpl);
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
    // the backend spells as a zero the (also unwinding) caller never reads. A call to a fn value
    // nothing pins carries the check when some fn value of the package can accept a cancellation
    // (`Package::cancel_fnv`).
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
                        let rt = pk.find("std::parallel::runtime");
                        if rt >= 0 {
                            let caw = pk.glob_lookup(rt as ModuleId, "cancel_after_wait", false);
                            self.chk_caw_m = caw.mid;
                            self.chk_caw_n = caw.node;
                        }
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
        res: ir::PlaceId,
        ty: TypeId,
        sp: tok::Span,
    ) {
        if !self.chk_has(id) {
            // Pending sibling temporaries: the request waits for the next edge, unless the callee
            // itself unwound.
            self.poison_check_at(target, is_fn_value, res, sp);
            return;
        }
        self.cancel_check_at(target, is_fn_value, res, ty, sp);
    }

    // Whether a call of `target` (a fn value when `is_fn_value`) takes a cancellation check here.
    fn chk_callee(self: &mut Self, target: DefId, is_fn_value: bool) bool {
        if self.in_defer != 0 {
            return false; // cleanup is masked: no edge inside a defer body
        }
        if !self.chk_enabled() {
            return false;
        }
        let pk = unsafe &*self.pkg;
        if is_fn_value {
            return pk.cancel_fnv; // else no fn value of the package can accept a cancellation
        }
        if target.node == NODE_NONE {
            return false;
        }
        let ta = unsafe &*pk.module_ast_const(target.module);
        if ta.at_const(target.node).kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        if !pk.cancel_on(target.module, ta.at_const(target.node).span) {
            return false; // this callee can never accept a cancellation
        }
        // The acceptance call of a primitive's own wait cleanup: it reports through its result so
        // the primitive can finish removing its registrations and hand back the value it waited
        // with, and the edge belongs after the PRIMITIVE, at its caller's check. A check here
        // unwound the primitive mid-cleanup: a channel's unsent payload leaked on every target
        // whose reachability analysis marks the primitive.
        return target.node != self.chk_caw_n || target.module != self.chk_caw_m;
    }

    // The check after a call outside the open root's clean nodes: sibling operands may be pending,
    // so an accepted request waits for the next edge, but a callee that returned through its own
    // ladder (probe 1) returned poison, which nothing may read. That edge unwinds at once, its
    // ladder dropping the pending temporaries with the scope's locals (drop elaboration frees the
    // ones still initialized). `res` is the place of the call's result (IR_NONE: none), never
    // dropped here.
    fn poison_check_at(self: &mut Self, target: DefId, is_fn_value: bool, res: ir::PlaceId, sp: tok::Span) {
        if !self.chk_callee(target, is_fn_value) {
            return;
        }
        let pk = unsafe &*self.pkg;
        let probe = pk.sugar_item(loader::SugarItem::SI_CANCEL_PROBE);
        let it = Ast::builtin(BuiltinType::BT_I32);
        let c0 = self.body.oper_pool.len() as u32;
        let cond = self.emit_call(probe, ir::IR_NONE, c0, 0, 0, 0, TYPE_NONE, TYPE_NONE, it, sp);
        let ladder_b = self.open_block();
        let cont_b = self.open_block();
        let mut t = ir::term0(ir::TM_SWITCH, sp);
        t.a = cond;
        t.sw_start = self.body.switch_pool.len() as u32;
        self.body.switch_pool.push(1u64 << 32 | ladder_b as u64);
        t.sw_len = 1;
        t.t0 = cont_b;
        self.seal(t, ladder_b);
        let mut rl = ir::IR_NONE;
        if res != ir::IR_NONE {
            rl = self.body.places.at(res as usize).base;
        }
        let mark = self.scope_locals.len();
        for l in self.chk_lbase..self.body.locals.len() as u32 {
            let mut ld = *self.body.locals.at(l as usize);
            if l == rl || ld.storage != ir::LS_TEMP || ld.decl != NODE_NONE || ld.ty == TYPE_NONE {
                continue;
            }
            let k = self.f.ty(ld.ty).kind;
            if k == TypeKind::TYPE_BUILTIN || k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE {
                continue;
            }
            // Registered for this ladder only: the normal path still consumes the value.
            ld.decl = self.body.owner.node;
            self.body.locals.set(l as usize, ld);
            self.scope_locals.push(l);
        }
        self.cancel_ladder(cont_b, sp);
        self.scope_locals.truncate(mark);
    }

    // The check after a call in a clean position (see `maybe_cancel_check`); `res` is the place of
    // the call's result (IR_NONE: none).
    fn cancel_check_at(self: &mut Self, target: DefId, is_fn_value: bool, res: ir::PlaceId, ty: TypeId, sp: tok::Span) {
        if !self.chk_callee(target, is_fn_value) {
            return;
        }
        let pk = unsafe &*self.pkg;
        let probe = pk.sugar_item(loader::SugarItem::SI_CANCEL_PROBE);
        let it = Ast::builtin(BuiltinType::BT_I32);
        let ut = Ast::builtin(BuiltinType::BT_VOID);
        let c0 = self.body.oper_pool.len() as u32;
        let cond = self.emit_call(probe, ir::IR_NONE, c0, 0, 0, 0, TYPE_NONE, TYPE_NONE, it, sp);
        let real_b = self.open_block();
        let ladder_b = self.open_block();
        let cont_b = self.open_block();
        let mut t = ir::term0(ir::TM_SWITCH, sp);
        t.a = cond;
        t.sw_start = self.body.switch_pool.len() as u32;
        self.body.switch_pool.push(2u64 << 32 | real_b as u64);
        self.body.switch_pool.push(1u64 << 32 | ladder_b as u64);
        t.sw_len = 2;
        t.t0 = cont_b;
        self.seal(t, real_b);
        // Real value: spill it into a tracked local so the ladder (and any later exit) frees it.
        if res != ir::IR_NONE && ty != TYPE_NONE && ty != ut {
            // The spill's whole lifetime is THIS block: live, take the value, die (the drop
            // elaborates unconditionally right here, before the defers -- temporary operation state
            // is removed first). Nothing outside the block can see it, so no loan the value carries
            // outlives the check.
            let rpl = res;
            let sl = self.body.add_local(self.local_decl(ty, ir::LS_INL, false, sp, NODE_NONE));
            self.stmt(
                ir::Statement { kind: ir::ST_STORAGE_LIVE, place: ir::IR_NONE, rvalue: ir::IR_NONE, a: sl, span: sp },
            );
            let op2 = self.copy_op(rpl);
            let pl = self.place_of_local(sl);
            let rv = self.rv_use(op2, ty);
            self.assign(pl, rv, sp);
            self.stmt(
                ir::Statement { kind: ir::ST_STORAGE_DEAD, place: ir::IR_NONE, rvalue: ir::IR_NONE, a: sl, span: sp },
            );
        }
        self.seal(ir::goto_term(ladder_b, sp), ladder_b);
        // The ladder: masked cleanup, then hand the edge to the caller. Call-result receiver
        // temporaries registered above the call hold values and die here.
        self.cancel_ladder(cont_b, sp);
    }

    // Open the clean skeleton of `root` (an expression evaluated with nothing unregistered
    // pending: a statement, a `let` initializer, a lone return value, an `if` or `while`
    // condition) and return the enclosing base for `chk_close`. A clean node's first-evaluated
    // parts are clean too: a method receiver, a field access's object, a unary or cast operand, a
    // binary operator's left side, both sides of `&&` and `||` (the left is a bool, consumed by
    // the branch), a switch scrutinee and its arm bodies, an `if`'s condition and branches, and
    // the right side of an assignment to a call-free place. A call among these nodes may carry a
    // cancellation check; a value block or value loop outside them masks every root inside it.
    // `stmt`: the root of an expression statement or a plain `let`, the one root a std::parallel
    // body keeps (`chk_narrow`).
    fn chk_open(self: &mut Self, root: NodeId, stmt: bool) usize {
        let base = self.chk_base;
        self.chk_base = self.chk_nodes.len();
        self.chk_lbases.push(self.chk_lbase);
        self.chk_lbase = self.body.locals.len() as u32;
        // A body that takes no cancellation checks (`chk_enabled`) needs no clean nodes: every
        // reader of them checks that first.
        if root == NODE_NONE || self.chk_mask != 0 || !self.chk_enabled() {
            return base;
        }
        self.chk_nodes.push(root);
        if self.chk_narrow {
            if !stmt || self.f.node(root).kind != NodeKind::NODE_CALL {
                let _ = self.chk_nodes.pop();
            }
            return base;
        }
        // A worklist over the skeleton itself: every node enters once, and it holds only nodes of
        // the root's expression tree.
        let mut i = self.chk_base;
        while i < self.chk_nodes.len() {
            let n = self.chk_nodes[i];
            i += 1;
            let nd = self.f.node(n);
            let k = nd.kind;
            if k == NodeKind::NODE_CALL {
                let c = nd.as_data.call.callee;
                if self.f.node(c).kind == NodeKind::NODE_MEMBER && !self.f.node(c).as_data.member.path {
                    self.chk_nodes.push(self.f.node(c).as_data.member.object);
                }
            } else if k == NodeKind::NODE_MEMBER {
                if !nd.as_data.member.path {
                    self.chk_nodes.push(nd.as_data.member.object);
                }
            } else if k == NodeKind::NODE_UNARY {
                self.chk_nodes.push(nd.as_data.unary.operand);
            } else if k == NodeKind::NODE_CAST {
                self.chk_nodes.push(nd.as_data.cast.expression);
            } else if k == NodeKind::NODE_BINARY {
                self.chk_nodes.push(nd.as_data.binary.left);
                if nd.as_data.binary.op == tt::TokenType::AmpersandAmpersand || nd.as_data.binary.op == tt::TokenType::PipePipe {
                    self.chk_nodes.push(nd.as_data.binary.right);
                }
            } else if k == NodeKind::NODE_ASSIGNMENT {
                // An operator method takes the right side as an argument after the place.
                if self.f.op_method(n).is_none() && self.chk_place_clean(nd.as_data.binary.left) {
                    self.chk_nodes.push(nd.as_data.binary.right);
                }
            } else if k == NodeKind::NODE_MATCH {
                let md = nd.as_data.match_expr;
                self.chk_nodes.push(md.value);
                for a in 0..md.arms.len {
                    self.chk_nodes.push(self.f.node(unsafe self.f.list(md.arms)[a as usize]).as_data.match_arm.body);
                }
            } else if k == NodeKind::NODE_IF {
                let fd = nd.as_data.if_stmt;
                self.chk_nodes.push(fd.condition);
                self.chk_nodes.push(fd.then_branch);
                if fd.else_branch != NODE_NONE {
                    self.chk_nodes.push(fd.else_branch);
                }
            }
        }
        return base;
    }

    fn chk_close(self: &mut Self, base: usize) {
        self.chk_nodes.truncate(self.chk_base);
        self.chk_base = base;
        self.chk_lbase = self.chk_lbases.pop().unwrap();
    }

    // The local of assignment target `left` when it names an immutable split-init `let` (its one
    // assign), else IR_NONE.
    fn chk_split_let(self: &Self, left: NodeId) ir::LocalId {
        if self.f.node(left).kind != NodeKind::NODE_IDENTIFIER {
            return ir::IR_NONE;
        }
        let d = self.f.res(left);
        if d.node == NODE_NONE || d.module != self.module {
            return ir::IR_NONE;
        }
        let dn = unsafe (&*(&*self.pkg).module_ast_const(d.module)).at_const(d.node);
        if dn.kind != NodeKind::NODE_LET || dn.as_data.let_stmt.value != NODE_NONE || dn.as_data.let_stmt.is_mutable {
            return ir::IR_NONE;
        }
        return self.local_of(d.node);
    }

    // Is `n` a clean node of the open root?
    const fn chk_has(self: &Self, n: NodeId) bool {
        for i in self.chk_base..self.chk_nodes.len() {
            if self.chk_nodes[i] == n {
                return true;
            }
        }
        return false;
    }

    // An assignment target whose place evaluates no call: a local, a field, a deref, or an element
    // at a name or literal index. A split-init `let` target is uninitialized or maybe-initialized
    // on a cancel edge in the right side: an immutable one is definitely uninitialized (it is
    // assigned once), so the ladder skips it (`chk_split_let`); a `mut` one qualifies only when its
    // type holds no loan and no drop, so its dead is inert.
    fn chk_place_clean(self: &Self, left: NodeId) bool {
        let mut n = left;
        loop {
            let nd = self.f.node(n);
            if nd.kind == NodeKind::NODE_IDENTIFIER {
                let d = self.f.res(n);
                if d.node == NODE_NONE || d.module != self.module {
                    return true;
                }
                let dn = unsafe (&*(&*self.pkg).module_ast_const(d.module)).at_const(d.node);
                if dn.kind != NodeKind::NODE_LET || dn.as_data.let_stmt.value != NODE_NONE || !dn.as_data.let_stmt.is_mutable {
                    return true;
                }
                let l = self.local_of(d.node);
                if l == ir::IR_NONE {
                    return false;
                }
                let tk = self.f.ty(self.body.locals.at(l as usize).ty).kind;
                return tk == TypeKind::TYPE_BUILTIN || tk == TypeKind::TYPE_POINTER;
            }
            if nd.kind == NodeKind::NODE_MEMBER && !nd.as_data.member.path {
                n = nd.as_data.member.object;
            } else if nd.kind == NodeKind::NODE_UNARY && nd.as_data.unary.op == tt::TokenType::Star {
                n = nd.as_data.unary.operand;
            } else if nd.kind == NodeKind::NODE_INDEX {
                let ik = self.f.node(nd.as_data.index.index).kind;
                if ik != NodeKind::NODE_IDENTIFIER && ik != NodeKind::NODE_LITERAL {
                    return false;
                }
                n = nd.as_data.index.object;
            } else {
                return false;
            }
        }
    }

    // The cancellation ladder in the open block: masked cleanup of every defer and scope local,
    // then a cancel return; writing continues in `next`.
    fn cancel_ladder(self: &mut Self, next: ir::BlockId, sp: tok::Span) {
        let pk = unsafe &*self.pkg;
        let ut = Ast::builtin(BuiltinType::BT_VOID);
        let b0 = self.body.oper_pool.len() as u32;
        let _ = self.emit_call(
            pk.sugar_item(loader::SugarItem::SI_CANCEL_LBEGIN),
            ir::IR_NONE,
            b0,
            0,
            0,
            0,
            TYPE_NONE,
            TYPE_NONE,
            ut,
            sp,
        );
        self.emit_defers_down_to(0);
        // A pending `let` local is uninitialized on this path: no dead for it.
        let mut i = self.scope_locals.len();
        while i > 0 {
            i -= 1;
            let l = self.scope_locals[i];
            if self.pending_lets.contains(&l) {
                continue;
            }
            let lsp = self.body.locals.at(l as usize).span;
            self.stmt(
                ir::Statement { kind: ir::ST_STORAGE_DEAD, place: ir::IR_NONE, rvalue: ir::IR_NONE, a: l, span: lsp },
            );
        }
        let e0 = self.body.oper_pool.len() as u32;
        let _ = self.emit_call(
            pk.sugar_item(loader::SugarItem::SI_CANCEL_LEND),
            ir::IR_NONE,
            e0,
            0,
            0,
            0,
            TYPE_NONE,
            TYPE_NONE,
            ut,
            sp,
        );
        let mut rt = ir::term0(ir::TM_RETURN, sp);
        rt.args_len = ir::RET_CANCEL;
        self.seal(rt, next);
    }

    fn intrinsic_value(self: &mut Self, ik: u8, bv: TypeId, ty: TypeId, sp: tok::Span, dest: ir::PlaceId) ir::OperandId {
        return self.rv_out(dest, ir::rv(ir::RV_INTRINSIC, self.body.oper_pool.len() as u32, bv, ik, ty), sp);
    }

    // Whether `f` is an `@intrinsic` function: a call lowers to the operation it names.
    const fn is_intrinsic_fn(self: &Self, f: DefId) bool {
        let n = unsafe (&*(&*self.pkg).module_ast_const(f.module)).at_const(f.node);
        return n.kind == NodeKind::NODE_FUNCTION && n.as_data.function.is_intrinsic();
    }

    // The place operand `op` reads, or a temp holding it.
    fn op_place(self: &mut Self, op: ir::OperandId, sp: tok::Span) ir::PlaceId {
        let o = *self.body.operands.at(op as usize);
        if o.kind == ir::OP_COPY || o.kind == ir::OP_MOVE {
            return o.data;
        }
        return self.spill(op, sp);
    }

    // The lane count of vector type `vt` as a `usize` operand: a constant once known, the const-generic
    // parameter, else `sizeof(vt) / sizeof(lane)` (a vector holds its lanes without padding).
    fn lanes_op(self: &mut Self, vt: TypeId, sp: tok::Span) ir::OperandId {
        let ut = Ast::builtin(BuiltinType::BT_USIZE);
        let n = self.f.lanes(self.f.ty(vt));
        if n != 0 {
            return self.kop(ir::CK_INT, ut, n as i64, sp);
        }
        // The const-generic parameter itself, which every instance binds (a constant for the evaluator).
        let ly = *self.f.ty(self.f.ty(vt).as_data.arr.len);
        if ly.kind == TypeKind::TYPE_GENERIC {
            return self.copy_op(
                self.place_of_local(self.item_local(DefId { module: ly.module, node: ly.as_data.decl }, ut, sp)),
            );
        }
        let a = self.intrinsic_value(ir::IN_SIZEOF, vt, ut, sp, ir::IR_NONE);
        let b = self.intrinsic_value(ir::IN_SIZEOF, self.f.ty(vt).as_data.arr.elem, ut, sp, ir::IR_NONE);
        return self.copy_op(self.rv_temp(ir::rv(ir::RV_BINARY, a, b, tt::TokenType::Slash as u8, ut), sp));
    }

    // A call of `@intrinsic` function `f` over the operands `ops`, of type `ty`: the operation its name
    // gives (`ir::simd_intrinsic`). An operand of a reference parameter (an operator method's `&Self`)
    // is read through; a reference passed to a pointer parameter stays the address.
    // A vector load or store checks its lanes against the slice first: `IN_BOUNDS_GROUP(start, len, N)`.
    fn lower_intrinsic(self: &mut Self, f: DefId, ops: &mut Vector<ir::OperandId>, ty: TypeId, sp: tok::Span) ir::OperandId {
        let k = self.intrinsic_code(f);
        if k == 0 {
            // A name only `--bootstrap-tags` accepts (`tc_check_intrinsic`): a newer compiler's.
            self.fail_at(UNKNOWN_INTRINSIC_SLUG, NODE_NONE);
            return ir::IR_NONE;
        }
        let fa = unsafe &*(&*self.pkg).module_ast_const(f.module);
        let ps = fa.at_const(f.node).as_data.function.params;
        for i in 0..ops.len() {
            let ot = self.body.operands.at(ops[i] as usize).ty;
            let pt = fa.at_const(unsafe fa.list(ps)[i]).as_data.parameter.ty;
            if self.f.ty(ot).kind == TypeKind::TYPE_REFERENCE && pt != NODE_NONE && fa.at_const(pt).kind == NodeKind::NODE_REFERENCE_TYPE {
                let pl = self.op_place(ops[i], sp);
                let d = self.place_project(
                    pl,
                    ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: self.f.ty(ot).as_data.elem },
                );
                ops.set(i, self.copy_op(d));
            }
        }
        let c = k as u8;
        let kind = k >> 8;
        if kind == ir::SI_HINT {
            let n = ops.len() as u32;
            return self.copy_op(self.rv_temp(ir::rv(ir::RV_INTRINSIC, self.pool_ops(ops), n, c, ty), sp));
        }
        let shift = c == tt::TokenType::LeftShift as u8 || c == tt::TokenType::RightShift as u8;
        // A mask operator's operands are masks.
        let vec = self.f.ty(ty).kind == TypeKind::TYPE_SIMD;
        for i in 0..pick(kind == ir::SI_BINARY && vec, 2usize, 0usize) {
            // A lane scalar beside a vector operator (`v * s`, `s * v`): the vector of the scalar in
            // every lane. A shift keeps a scalar count.
            if self.f.ty(self.body.operands.at(ops[i] as usize).ty).kind != TypeKind::TYPE_SIMD && (i == 0 || !shift) {
                let arr = self.rv_temp(
                    ir::rv(ir::RV_REPEAT, ops[i], self.lanes_op(ty, sp), 0, self.vec_array_ty(ty)),
                    sp,
                );
                ops.set(
                    i,
                    self.copy_op(self.rv_temp(ir::rv(ir::RV_CAST, self.copy_op(arr), ir::CAST_SIMD_ARRAY, 0, ty), sp)),
                );
            }
        }
        if kind == ir::SI_BINARY || kind == ir::SI_UNARY || kind == ir::SI_CAST {
            let rv = if kind == ir::SI_BINARY {
                ir::rv(ir::RV_BINARY, ops[0], ops[1], c, ty);
            } else {
                ir::rv(pick(kind == ir::SI_UNARY, ir::RV_UNARY, ir::RV_CAST), ops[0], c, 0, ty);
            };
            return self.copy_op(self.rv_temp(rv, sp));
        }
        if c == ir::SIMD_LOAD || c == ir::SIMD_STORE {
            let s = self.op_place(ops[0], sp);
            let lop = self.copy_op(self.len_temp(s, sp));
            let vt = if c == ir::SIMD_LOAD {
                ty;
            } else {
                self.body.operands.at(ops[2] as usize).ty;
            };
            let wop = self.lanes_op(vt, sp);
            let start = self.body.oper_pool.len() as u32;
            self.body.oper_pool.push(ops[1]);
            self.body.oper_pool.push(lop);
            self.body.oper_pool.push(wop);
            let mut g = ir::rv(ir::RV_INTRINSIC, start, 3, ir::IN_BOUNDS_GROUP, Ast::builtin(BuiltinType::BT_USIZE));
            g.item.node = ir::CHECK_VEC;
            ops.set(0, self.copy_op(s));
            ops.set(1, self.copy_op(self.rv_temp(g, sp)));
        } else if ir::simd_op(c).rule >= ir::SR_MLOAD {
            // The masked and gather forms check their active lanes themselves; the slice is a place.
            ops.set(0, self.copy_op(self.op_place(ops[0], sp)));
        }
        if ir::simd_op(c).rule == ir::SR_INDEX {
            let node = self.list_node;
            self.list_node = NODE_NONE;
            return self.index_op(c, node, ops, ty, sp);
        }
        return self.simd_op(c, ops, ty, ir::IR_NONE, sp);
    }

    // The `ir::simd_intrinsic` lowering of `@intrinsic` function `f`, 0 for none.
    fn intrinsic_code(self: &Self, f: DefId) u32 {
        let at = unsafe (&*(&*self.pkg).module_ast_const(f.module)).attr_of(f.node, AttrKind::ATTR_INTRINSIC);
        if at == null {
            return 0;
        }
        let src = unsafe (&*self.pkg).modules.at(f.module as usize).source.as_str();
        return ir::simd_intrinsic(
            src.slice((unsafe (*at).str_span.start) as usize, (unsafe (*at).str_span.end) as usize),
        );
    }

    // `RV_SIMD` code `c` over `ops`, of type `ty`, in a fresh temp; `aux` is its index list's start.
    fn simd_op(self: &mut Self, c: u8, ops: &Vector<ir::OperandId>, ty: TypeId, aux: u32, sp: tok::Span) ir::OperandId {
        let start = self.pool_ops(ops);
        let mut r = ir::rv(ir::RV_SIMD, start, ops.len() as u32, c, ty);
        r.item.node = aux;
        return self.copy_op(self.rv_temp(r, sp));
    }

    // The lane count of vector type `vt`, through the instance env for a const-generic one; 0 when
    // it is not known.
    fn env_lanes(self: &Self, vt: TypeId) u64 {
        let n = self.f.lanes(self.f.ty(vt));
        let mut rm: ModuleId = 0;
        let mut rt = TYPE_NONE;
        if n != 0 || !self.env_resolve(self.f.ty(vt).as_data.arr.len, &mut rm, &mut rt) {
            return n;
        }
        let y = *unsafe (&*(&*self.pkg).module_ast_const(rm)).type_at(rt);
        return pick(y.kind == TypeKind::TYPE_CONST, y.as_data.value as u64, 0u64);
    }

    // SIMD_SWIZZLE or SIMD_SHUFFLE over `ops` with index list `node`, a constant expression: its lanes
    // packed into `simd_aux`. A shared generic lowering whose list or lane count names a parameter
    // keeps no record and re-lowers per instance (`has_lists`), where both are known; so does the
    // operation's own body (NODE_NONE), which no call reaches: the checker refuses it as a value.
    fn index_op(self: &mut Self, c: u8, node: NodeId, ops: &mut Vector<ir::OperandId>, ty: TypeId, sp: tok::Span) ir::OperandId {
        if node == NODE_NONE {
            // The operation's own body: its list is the last parameter.
            ops.truncate(ops.len() - 1);
        }
        let n = self.env_lanes(self.body.operands.at(ops[0] as usize).ty);
        let mut lst = Vector::<u64>::new();
        let mut st: u8 = 2;
        if node != NODE_NONE && unsafe (&*self.pkg).cir != null {
            st = unsafe (*((&*self.pkg).cir as *mut iri::Interp)).eval_lanes(self.module, node, &self.env, &mut lst);
        }
        if node == NODE_NONE || self.env.len() == 0 && (st == 1 || st == 0 && n == 0) {
            self.body.has_lists = true;
            return self.simd_op(c, ops, ty, ir::IR_NONE, sp);
        }
        let m = self.env_lanes(ty);
        if st != 0 || n == 0 || m == 0 {
            if self.env.len() == 0 || n == 0 || m == 0 {
                self.fail_at("a vector index list that is not a constant", node);
                return ir::IR_NONE;
            }
            // An instance's list that does not evaluate (a run-time value beside a generic parameter,
            // or a trap): the program's error, reported by the emitter; the lanes read lane 0.
            self.user_err = node;
            self.user_msg = pick(
                st == 2,
                "the index list cannot be evaluated: it traps",
                "the index list must be a compile-time constant",
            );
            lst.truncate(0);
            lst.resize_default(m as usize);
        }
        let aux = self.body.simd_aux.len() as u32;
        self.body.simd_aux.push(lst.len() as u32);
        for i in 0..lst.len() {
            let mut k = lst[i];
            if k >= n * ops.len() as u64 {
                self.user_err = node;
                self.user_msg = "the index list names a lane past the lanes of its operands";
                k = 0;
            }
            if i % 4 == 0 {
                self.body.simd_aux.push(0);
            }
            let w = self.body.simd_aux.len() - 1;
            self.body.simd_aux.set(w, self.body.simd_aux[w] | k as u32 << (i % 4 * 8) as u32);
        }
        return self.simd_op(c, ops, ty, aux, sp);
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
            // The comparison and the failure report only read the two values: a temporary side
            // is dropped by its scope.
            self.own_operand(l, a0);
            self.own_operand(r, unsafe self.f.list(d.args)[1]);
            lsave = l;
            rsave = r;
            tsp = self.f.node(id).span;
            let tokv = if ak == 2 {
                tt::TokenType::EqualEqual;
            } else {
                tt::TokenType::BangEqual;
            };
            cond = self.bool_bin(l, r, tokv, sp);
        }
        if cond == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let mut tm = ir::term0(ir::TM_ASSERT, tsp);
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
                },
            );
            let rsc = self.const_op(
                ir::Constant {
                    kind: ir::CK_STR,
                    ty: bt9,
                    val: tt::TokenType::RawStringLiteral as i64,
                    raw: self.f.node(a1n).span,
                    item: no9,
                },
            );
            // The report reads the values through operands of its own: the emitter counts a local's
            // reads by operand, and the comparison already holds `lsave` and `rsave`.
            self.body.operands.push(*self.body.operands.at(lsave as usize));
            self.body.operands.push(*self.body.operands.at(rsave as usize));
            let nops = self.body.operands.len() as u32;
            let mut av = self.avget();
            av.push(nops - 2);
            av.push(nops - 1);
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
        switch self.f.op_method(id) {
            Some(m) => {
                // An operator method takes the place first, as a call takes its receiver.
                let pl = self.lower_place(d.left);
                if pl == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                // compound assignment through an operator method: place = method(place, rhs)
                let lop = self.copy_op(pl);
                let lt = self.body.places.at(pl as usize).ty;
                let res = self.lower_op_call_from(
                    id,
                    (m >> 32) as ModuleId,
                    (m & 0xFFFFFFFFu64) as NodeId,
                    lop,
                    d.right,
                    lt,
                    false,
                    ir::IR_NONE,
                );
                if res == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                let rv = self.rv_use(res, lt);
                self.assign(pl, rv, sp);
                // Checked once the place holds the result: the ladder drops it with the place.
                if self.chk_has(id) && self.chk_place_clean(d.left) {
                    self.cancel_check_at(
                        DefId { module: (m >> 32) as ModuleId, node: (m & 0xFFFFFFFFu64) as NodeId },
                        false,
                        ir::IR_NONE,
                        TYPE_NONE,
                        sp,
                    );
                }
                self.tp(ir::TP_ASSIGN_POST, 0, id);
                return self.unit_op(ty, sp);
            },
            None => {},
        };
        // An immutable split-init target is uninitialized until this assign (see `chk_place_clean`).
        let split = self.chk_split_let(d.left);
        if split != ir::IR_NONE {
            self.pending_lets.push(split);
        }
        // The value first, then the place it lands in (Rust's order): a place reached through a
        // `&mut` (`v.index_mut(k).f = v[k].f`) is claimed only once the value no longer reads it.
        let mut rop = self.lower_expr(d.right);
        if split != ir::IR_NONE {
            let _ = self.pending_lets.pop();
        }
        if rop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        self.mark_user_move(rop);
        // A value read through a reference is read now, so the reference ends before the place.
        let ro = *self.body.operands.at(rop as usize);
        if (ro.kind == ir::OP_COPY || ro.kind == ir::OP_MOVE) && self.body.place_has_deref(ro.data) {
            rop = self.copy_op(self.spill(rop, sp));
        }
        let pl = self.lower_place(d.left);
        if pl == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let lt = self.body.places.at(pl as usize).ty;
        if d.op == tt::TokenType::Equal {
            let rv = self.rv_use(rop, lt);
            self.assign(pl, rv, sp);
        } else {
            // `x op= y` stores `x op y` into the place in one statement: the operator reads its
            // operands before the store.
            let lop = self.copy_op(pl);
            self.assign(pl, ir::rv(ir::RV_BINARY, lop, rop, compound_base_op(d.op) as u8, lt), sp);
        }
        self.tp(ir::TP_ASSIGN_POST, 0, id);
        return self.unit_op(ty, sp);
    }

    fn lower_struct_init(self: &mut Self, id: NodeId, dest: ir::PlaceId) ir::OperandId {
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
                let fv = self.f.node(fi).as_data.field_initializer.value;
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
                let fty = da.at_const(unsafe da.list(members)[idx as usize]).as_data.field.ty;
                let op = self.lower_slot(
                    fv,
                    fty != NODE_NONE && da.at_const(fty).kind == NodeKind::NODE_POINTER_TYPE,
                    sp,
                );
                if op == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                self.mark_user_move(op);
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
            let rv9 = self.finish_aggregate(ir::AGG_VARIANT, sd, &argv, ty, sp, dest);
            self.avput(argv);
            return rv9;
        }
        let rs9 = self.finish_aggregate(ir::AGG_STRUCT, sd, &argv, ty, sp, dest);
        self.avput(argv);
        return rs9;
    }

    // The aggregate of operands `ops`, stored into `dest` (`rv_out`).
    fn finish_aggregate(
        self: &mut Self,
        agg: u8,
        item: DefId,
        ops: &Vector<ir::OperandId>,
        ty: TypeId,
        sp: tok::Span,
        dest: ir::PlaceId,
    ) ir::OperandId {
        let start = self.pool_ops(ops);
        let rv = ir::Rvalue { kind: ir::RV_AGGREGATE, a: start, b: ops.len() as u32, c: agg, target: ty, item: item };
        return self.rv_out(dest, rv, sp);
    }

    fn lower_array_or_tuple(self: &mut Self, id: NodeId, dest: ir::PlaceId) ir::OperandId {
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
            if ty == TYPE_NONE || self.f.ty(ty).kind == TypeKind::TYPE_ARRAY {
                return self.rv_out(dest, ir::rv(ir::RV_REPEAT, vop, cop, 0, ty), sp);
            }
            if self.f.ty(ty).kind == TypeKind::TYPE_SIMD {
                // A repeat typed as a vector fills its array; `apply_adjust` converts it.
                let aty = self.vec_array_ty(ty);
                return self.copy_op(self.rv_temp(ir::rv(ir::RV_REPEAT, vop, cop, 0, aty), sp));
            }
            // A repeat coerced to a slice: fill an array temp of the checked count; `apply_adjust`
            // views it.
            let mut n: i64 = -1;
            if unsafe (&*self.pkg).cir != null {
                let cv = unsafe (&mut *((&*self.pkg).cir as *mut iri::Interp)).eval(self.module, c);
                if cv.kind == iri::IV_INT {
                    n = cv.i;
                }
            }
            if n < 0 {
                self.fail_at("array-repeat-count", id);
                return ir::IR_NONE;
            }
            let elem = self.f.instance(self.f.ty(ty).as_data.inst).args[0];
            let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
            let aty = sa.intern_type(
                Ty { kind: TypeKind::TYPE_ARRAY, as_data: TyAs { arr: TyArr { elem: elem, len: n as u32 } } },
            );
            return self.copy_op(self.rv_temp(ir::rv(ir::RV_REPEAT, vop, cop, 0, aty), sp));
        }
        let mut argv = self.avget();
        let mut cur: i64 = 0;
        let mut designated = false;
        // The element type an array literal's elements go into (a tuple's: per element below).
        let mut et = TYPE_NONE;
        if ty != TYPE_NONE && self.f.ty(ty).kind == TypeKind::TYPE_ARRAY {
            et = self.f.ty(ty).as_data.arr.elem;
        } else if self.slice_view(ty) {
            et = self.f.instance(self.f.ty(ty).as_data.inst).args[0];
        }
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
            let mut st = et;
            if k == NodeKind::NODE_TUPLE && ty != TYPE_NONE && self.f.ty(ty).kind == TypeKind::TYPE_INSTANCE && i < self.f.instance(
                self.f.ty(ty).as_data.inst,
            ).n as u32 {
                st = unsafe self.f.instance(self.f.ty(ty).as_data.inst).args[i as usize];
            }
            let op = self.lower_slot(e, st != TYPE_NONE && self.f.ty(st).kind == TypeKind::TYPE_POINTER, sp);
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
        if designated && k == NodeKind::NODE_ARRAY_LITERAL && ty != TYPE_NONE {
            // The checker types a designated literal with at least its extent (the expected
            // length when it underfills one): the omitted tail zero-fills.
            let y = *self.f.ty(ty);
            if y.kind == TypeKind::TYPE_ARRAY {
                while argv.len() as u64 < y.as_data.arr.len as u64 {
                    argv.push(ir::IR_NONE);
                }
            }
        }
        // A literal coerced to a slice builds its array; `apply_adjust` views it. One typed as a
        // vector builds its array too, which `apply_adjust` converts.
        let mut aty = ty;
        if ty != TYPE_NONE && self.f.ty(ty).kind == TypeKind::TYPE_SIMD {
            aty = self.vec_array_ty(ty);
        } else if self.slice_view(ty) {
            let elem = self.f.instance(self.f.ty(ty).as_data.inst).args[0];
            let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
            aty = sa.intern_type(
                Ty { kind: TypeKind::TYPE_ARRAY, as_data: TyAs { arr: TyArr { elem: elem, len: argv.len() as u32 } } },
            );
        }
        let ra9 = self.finish_aggregate(agg, DefId { module: 0, node: NODE_NONE }, &argv, aty, sp, dest);
        self.avput(argv);
        return ra9;
    }

    fn lower_range(self: &mut Self, id: NodeId, dest: ir::PlaceId) ir::OperandId {
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
        argv.push(self.kop(ir::CK_BOOL, bt, iv, tok::Span { start: 0, end: 0 }));
        let rr9 = self.finish_aggregate(ir::AGG_STRUCT, DefId { module: 0, node: NODE_NONE }, &argv, ty, sp, dest);
        self.avput(argv);
        return rr9;
    }

    // A value `if`: each arm writes `dest` (`out_place`).
    fn lower_if_expr(self: &mut Self, id: NodeId, dest: ir::PlaceId) ir::OperandId {
        let sp = self.f.node(id).span;
        let pl = self.out_place(dest, self.nty(id), sp);
        let d = self.f.node(id).as_data.if_stmt;
        let kc = self.bc_cond(d.condition);
        if kc >= 0 {
            self.lower_arm(pick(kc == 1, d.then_branch, d.else_branch), pl, self.ext_depth_for(id));
        } else if !self.lower_if_arms(id, pl) {
            return ir::IR_NONE;
        }
        return self.out_op(dest, pl);
    }

    // The address of place `apl` as raw pointer type `pty`, stored into `dest` (`rv_out`); `rt` is
    // the written borrow's type (a `&mut` borrow gives a mutable address).
    fn addr_op(self: &mut Self, apl: ir::PlaceId, rt: TypeId, pty: TypeId, sp: tok::Span, dest: ir::PlaceId) ir::OperandId {
        let mu: u32 = if rt != TYPE_NONE && self.f.ty(rt).kind == TypeKind::TYPE_REFERENCE && self.f.ty(rt).qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            1;
        } else {
            0;
        };
        return self.rv_out(dest, ir::rv(ir::RV_ADDR, apl, mu, 0, pty), sp);
    }

    // Lower a branch that produces a value into `dest`: a block whose last expression statement is
    // the value, or a bare expression. The temporaries the value borrows live at scope depth
    // `depth` (EXT_NONE: in the branch's own scopes). The value's producer writes `dest` itself
    // (`lower_expr_d`), so `dest` follows the `lower_into` contract.
    fn lower_value_into(self: &mut Self, id: NodeId, dest: ir::PlaceId, depth: u32) {
        if id == NODE_NONE || self.err.len() != 0 {
            return;
        }
        let outer = self.ext;
        self.ext = ext_none();
        if depth != EXT_NONE {
            self.ext = ExtCx { arm: id, val: id, rf: NODE_NONE, depth: depth };
        }
        if self.f.node(id).kind == NodeKind::NODE_BLOCK {
            if depth != EXT_NONE {
                self.ext.val = self.value_tail(id);
            }
            self.lower_value_block(id, dest, true);
        } else {
            let ty = self.body.places.at(dest as usize).ty;
            let mut op = self.lower_expr_d(id, dest);
            if op != ir::IR_NONE && op != WROTE {
                op = self.arm_view(op, id, ty, self.f.node(id).span, dest);
            }
            if op != ir::IR_NONE && op != WROTE {
                let rv = self.rv_use(op, ty);
                self.assign(dest, rv, self.f.node(id).span);
            }
        }
        self.ext = outer;
    }

    // The expression value block `id` yields: its last statement's expression, or NODE_NONE.
    const fn value_tail(self: &Self, id: NodeId) NodeId {
        let stmts = self.f.node(id).as_data.block.statements;
        if stmts.len == 0 {
            return NODE_NONE;
        }
        let s = unsafe self.f.list(stmts)[(stmts.len - 1) as usize];
        if self.f.node(s).kind != NodeKind::NODE_EXPRESSION_STATEMENT {
            return NODE_NONE;
        }
        return self.f.node(s).as_data.single.value;
    }

    // A value block: statements run, and the LAST expression statement's value lands in `dest`.
    // A block with no value-producing tail still writes `dest` (unit), so every consumer of the
    // destination reads initialized storage. `arm`: the block is an arm, and the conversions the
    // checker recorded on it apply to the tail's value.
    fn lower_value_block(self: &mut Self, id: NodeId, dest: ir::PlaceId, arm: bool) {
        // Outside the open root's clean nodes, something unregistered is pending: no root inside.
        let masked = !self.chk_has(id);
        if masked {
            self.chk_mask += 1;
        }
        self.lower_value_block_in(id, dest, arm);
        if masked {
            self.chk_mask -= 1;
        }
    }

    fn lower_value_block_in(self: &mut Self, id: NodeId, dest: ir::PlaceId, arm: bool) {
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
                let cb = self.chk_open(v, false);
                // The tail writes `dest` unless the arm's conversions follow it.
                let tdest = pick(!arm || self.plain_value(id), dest, ir::IR_NONE);
                let mut op = self.lower_expr_d(v, tdest);
                if op != ir::IR_NONE && op != WROTE {
                    // The block's conversions apply at its value, which a borrow error names.
                    let vsp = self.f.node(v).span;
                    if arm {
                        op = self.apply_adjust_d(id, op, vsp, dest);
                    }
                    if op != WROTE {
                        op = self.arm_view(op, id, ty, vsp, dest);
                    }
                }
                self.chk_close(cb);
                self.tp(ir::TP_MARK_POP, 0, s);
                if op == ir::IR_NONE {
                    return;
                }
                if op != WROTE {
                    let rv = self.rv_use(op, ty);
                    self.assign(dest, rv, self.f.node(s).span);
                }
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
        let masked = !self.chk_has(id);
        if masked {
            self.chk_mask += 1;
        }
        let d = self.f.node(id).as_data.while_stmt;
        let sp = self.f.node(id).span;
        let head = self.open_block();
        let exit = self.open_block();
        self.seal(ir::goto_term(head, sp), head);
        self.push_loop(d.label, exit, head, result, self.scope_locals.len(), self.defers.len());
        // A value loop preempts like a statement loop: every backedge enters `head`.
        self.loop_safepoint(sp);
        self.lower_stmt(d.body);
        let _ = self.loops.pop();
        self.seal(ir::goto_term(head, sp), exit);
        if masked {
            self.chk_mask -= 1;
        }
        self.tape_mute -= 1;
    }

    // Lower one copy of an unrolled (`inline for`) body: the first copy is the replay's canonical
    // iteration; later copies mute their tape events.
    fn unrolled_body(self: &mut Self, body: NodeId, id: NodeId, muted: bool) {
        if muted {
            self.tape_mute += 1;
            self.lower_stmt(body);
            self.tape_mute -= 1;
        } else {
            self.tp(ir::TP_BODY_START, 1, id);
            self.lower_stmt(body);
            self.tp(ir::TP_BODY_END, 0, id);
        }
    }

    // The tape events that open and close `for` loop `id` (one loop for the replay).
    fn for_open(self: &mut Self, id: NodeId) {
        self.tp(ir::TP_LOOP_PUSH, 1, id);
        self.tp(ir::TP_MARK_PUSH, 0, id);
    }

    fn for_close(self: &mut Self, id: NodeId) {
        self.tp(ir::TP_MARK_POP, 0, id);
        self.tp(ir::TP_LOOP_POP, 0, id);
    }

    // The live user local of `for` loop `id`'s element, bound to the loop node and its binding.
    fn for_binding(self: &mut Self, id: NodeId, binding: NodeId, ty: TypeId, mutable: bool, sp: tok::Span) ir::LocalId {
        let l = self.for_binding_decl(id, binding, ty, mutable, sp);
        self.user_local_live(l, sp);
        return l;
    }

    // `for_binding` without the storage marker: the caller makes the local live per iteration.
    fn for_binding_decl(self: &mut Self, id: NodeId, binding: NodeId, ty: TypeId, mutable: bool, sp: tok::Span) ir::LocalId {
        // A lone name (`x`, `mut x`) is the element local itself; a destructuring pattern binds
        // its names from that local at the start of each iteration (`loop_body`).
        let single = binding != NODE_NONE && self.for_pattern(id) == NODE_NONE;
        let mut m = mutable;
        if single && self.f.node(binding).kind == NodeKind::NODE_PATTERN_NAME {
            m = m || self.f.node(self.f.node(binding).as_data.pattern.name).as_data.name.is_mutable;
        }
        let l = self.body.add_local(self.local_decl(ty, ir::LS_USER, m, sp, id));
        self.bind(id, l);
        if single {
            self.bind(binding, l);
        }
        return l;
    }

    // The destructuring pattern of `for` loop `id`, or NODE_NONE (another loop, or a binding that
    // is a lone name).
    const fn for_pattern(self: &Self, id: NodeId) NodeId {
        if self.f.node(id).kind != NodeKind::NODE_FOR {
            return NODE_NONE;
        }
        let b = self.f.node(id).as_data.for_stmt.binding;
        let bn = self.f.node(b);
        if bn.kind == NodeKind::NODE_IDENTIFIER || bn.kind == NodeKind::NODE_PATTERN_NAME && bn.as_data.pattern.children.len == 0 {
            return NODE_NONE;
        }
        return b;
    }

    // An element binding lives for ONE iteration: an owned element is freed at the end of the
    // iteration that took it (and at `break`, `continue` and `return`). Returns the scope depth
    // below the binding for `loop_body` and `iter_binding_dead`.
    fn iter_binding_live(self: &mut Self, l: ir::LocalId, sp: tok::Span) usize {
        let lbase = self.scope_locals.len();
        self.user_local_live(l, sp);
        return lbase;
    }

    // End the per-iteration binding at the body's natural end.
    fn iter_binding_dead(self: &mut Self, lbase: usize) {
        self.emit_deads_down_to(lbase);
        self.scope_locals.truncate(lbase);
    }

    // Enter a loop whose `break` goes to `brk` (storing a value into `result`) and whose
    // `continue` goes to `cont`.
    // `locals_depth` is where `break`/`continue` end local storage: below a per-iteration binding.
    // `brk_defers` is where `break` stops running defers: below a loop's own TailDrop entry.
    fn push_loop(
        self: &mut Self,
        label: tok::Span,
        brk: ir::BlockId,
        cont: ir::BlockId,
        result: ir::PlaceId,
        locals_depth: usize,
        brk_defers: usize,
    ) {
        self.loops.push(
            LoopCtx {
                label: label,
                brk: brk,
                cont: cont,
                defer_depth: self.defers.len(),
                brk_defer_depth: brk_defers,
                locals_depth: locals_depth,
                result: result,
            },
        );
    }

    // Lower statement loop `id`'s body inside its loop context, after the loop safepoint (none with
    // `tick` false: a strip-mined loop ticks once per chunk); `ar` is the body-start tape argument.
    fn loop_body(
        self: &mut Self,
        label: tok::Span,
        brk: ir::BlockId,
        cont: ir::BlockId,
        ar: u32,
        body: NodeId,
        id: NodeId,
        sp: tok::Span,
        lbase: usize,
        brk_defers: usize,
        tick: bool,
    ) {
        self.push_loop(label, brk, cont, ir::IR_NONE, lbase, brk_defers);
        if tick {
            self.loop_safepoint(sp);
        }
        self.tp(ir::TP_BODY_START, ar, id);
        // A destructuring `for` moves the element's parts into the pattern's names; they live for
        // the iteration (`break` and `continue` end them through `lbase`).
        let pat = self.for_pattern(id);
        if pat != NODE_NONE {
            // The checker proved the pattern irrefutable: bind with no tests, as a switch arm
            // does after its decision tree (a reference element binds by reference).
            self.scope_enter();
            self.pattern_bind_total(pat, self.place_of_local(self.local_of(id)));
        }
        self.lower_stmt(body);
        if pat != NODE_NONE {
            self.scope_exit();
        }
        self.tp(ir::TP_BODY_END, 0, id);
        let _ = self.loops.pop();
    }

    fn lower_va(self: &mut Self, id: NodeId, dest: ir::PlaceId) ir::OperandId {
        let d = self.f.node(id).as_data.va_op;
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        if d.op == VA_START || d.op == VA_END {
            // Both write the `va_list` itself (va_start also INITIALIZES it -- the init analysis
            // must see the write, never a read of the not-yet-started list), so the list is the
            // assignment's PLACE and the C prints the macro over that lvalue.
            let apl = self.lower_place(d.ap);
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
            self.assign(apl, ir::rv(ir::RV_INTRINSIC, start, n, ik, TYPE_NONE), sp);
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
        return self.rv_out(dest, ir::rv(ir::RV_INTRINSIC, start, n, ir::IN_VA_ARG, ty), sp);
    }

    fn lower_closure(self: &mut Self, id: NodeId, dest: ir::PlaceId) ir::OperandId {
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
        return self.rv_out(
            dest,
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
    }

    // A capture entry names the captured binding's decl (identifier node resolving to it).
    const fn cap_decl(self: &mut Self, c: NodeId) NodeId {
        let d = self.f.res(c);
        if d.module == self.module && d.node != NODE_NONE {
            return d.node;
        }
        return c; // the checker records the captured DECL itself, not a reference to it
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

    fn lower_path_value(self: &mut Self, id: NodeId, dest: ir::PlaceId) ir::OperandId {
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        let d = self.path_res(id);
        if d.node == NODE_NONE {
            self.fail_at("path-unresolved", id);
            return ir::IR_NONE;
        }
        return self.item_value(id, d, ty, sp, dest);
    }

    // The item an identifier or member path `id` names when it is a value and no place: a function,
    // a variant, a constant with type arguments (`item_value`), and through a path any item but a
    // plain constant (`lower_member_place`). NODE_NONE otherwise: `lower_place` lowers it.
    fn value_item(self: &mut Self, id: NodeId) DefId {
        let none = DefId { module: 0, node: NODE_NONE };
        let n = self.f.node(id);
        if n.kind == NodeKind::NODE_IDENTIFIER {
            let d = self.f.res(id);
            if d.node == NODE_NONE || d.module == self.module && self.local_of(d.node) != ir::IR_NONE {
                return none;
            }
            let dk = self.decl_kind(d);
            if dk == NodeKind::NODE_FUNCTION || dk == NodeKind::NODE_VARIANT || dk == NodeKind::NODE_CONST && self.f.type_args(
                id,
            ) != null {
                return d;
            }
            return none;
        }
        if n.kind != NodeKind::NODE_MEMBER || !n.as_data.member.path {
            return none;
        }
        let pd = self.path_res(id);
        if pd.node == NODE_NONE || self.decl_kind(pd) == NodeKind::NODE_CONST && self.f.type_args(id) == null && !self.retyped_int_const(
            pd,
            self.nty(id),
        ) {
            return none;
        }
        return pd;
    }

    // An item in value position: functions become item constants, constants/statics become places;
    // a unit variant's value lands in `dest` (`finish_aggregate`).
    fn item_value(self: &mut Self, id: NodeId, d0: DefId, ty: TypeId, sp: tok::Span, dest: ir::PlaceId) ir::OperandId {
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
                let mn = self.f.node(md0.member).as_data.name.text;
                let mtxt = self.src.slice(mn.start as usize, mn.end as usize);
                let mut vord: i64 = -1;
                let vd = self.variant_named(od, mtxt, mtxt, &mut vord);
                if vd.node != NODE_NONE {
                    d = vd;
                }
            }
        }
        let dk = self.decl_kind(d);
        // A generic extend's constant, or a generic function's local constant that uses its
        // parameters, is a value per instance: the arguments ride along (the checker records them on
        // the reference).
        if dk == NodeKind::NODE_FUNCTION || dk == NodeKind::NODE_CONST && self.f.type_args(id) != null {
            let ts = self.body.targ_pool.len() as u32;
            let tn = self.copy_targs(id);
            return self.const_op(
                ir::Constant { kind: ir::CK_ITEM, ty: ty, val: ir::targ_val(ts, tn), raw: sp, item: d },
            );
        }
        if dk == NodeKind::NODE_VARIANT {
            // unit variant construction
            let argv = self.avget();
            let ru9 = self.finish_aggregate(ir::AGG_VARIANT, d, &argv, ty, sp, dest);
            self.avput(argv);
            return ru9;
        }
        if dk == NodeKind::NODE_CONST && self.retyped_int_const(d, ty) {
            // A builtin limit that literal-only arithmetic or a pattern reads as the literal of its
            // value has the use's type, which its C object does not: it lowers to that literal.
            let cev = (unsafe (&*self.pkg).cir) as *mut iri::Interp;
            if cev != null {
                let cv = unsafe (*cev).eval(d.module, d.node);
                if cv.kind == iri::IV_INT {
                    return self.kop(ir::CK_INT, ty, cv.i, sp);
                }
            }
            self.fail_at("limit-value", id);
            return ir::IR_NONE;
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

    // Whether constant `d`, read at a use of type `ty`, is an integer constant of another integer
    // type: a builtin limit the checker retyped as a literal.
    fn retyped_int_const(self: &mut Self, d: DefId, ty: TypeId) bool {
        if !self.seen_here(d.module, d.node) {
            return false;
        }
        let dt = unsafe (*(&*self.pkg).module_ast_const(d.module)).type_of(d.node);
        if dt == TYPE_NONE || ty == TYPE_NONE {
            return false;
        }
        let rt = self.reintern_ty(d.module, dt);
        return rt != ty && self.f.ty(rt).kind == TypeKind::TYPE_BUILTIN && self.f.ty(ty).kind == TypeKind::TYPE_BUILTIN && bt_int_width(
            self.f.ty(rt).as_data.builtin,
            false,
        ) != 0 && bt_int_width(self.f.ty(ty).as_data.builtin, false) != 0;
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
            // A constant with type arguments has a value per instance (`item_value`).
            if dk == NodeKind::NODE_FUNCTION || dk == NodeKind::NODE_VARIANT || dk == NodeKind::NODE_CONST && self.f.type_args(
                id,
            ) != null {
                let op = self.item_value(id, d, ty, sp, ir::IR_NONE);
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
            let mut base = self.lower_place(self.f.node(id).as_data.unary.operand);
            if base == ir::IR_NONE {
                return ir::IR_NONE;
            }
            // `*x` on a Deref type calls the recorded impl (exactly as `x.method()` does); the
            // call's type is the impl's declared `&Target` return
            let du = self.f.derefs(id);
            if du != null {
                base = self.apply_place_derefs(base, du, id, sp);
                if base == ir::IR_NONE {
                    return ir::IR_NONE;
                }
            }
            let mut pty = ty;
            if du == null && self.slice_view(ty) {
                let by = *self.f.ty(self.body.places.at(base as usize).ty);
                if by.kind == TypeKind::TYPE_REFERENCE || by.kind == TypeKind::TYPE_POINTER {
                    pty = self.storage_ty(ty, by.as_data.elem);
                }
            }
            return self.place_project(base, ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: pty });
        }
        // Any other expression used as a place: evaluate and spill.
        let op = self.lower_expr(id);
        if op == ir::IR_NONE {
            return ir::IR_NONE;
        }
        // A temporary used as a place still OWNS its value: the temporary is the place,
        // scope-tracked WITHOUT a live marker (the value initialized before this point, and only
        // the scope-end dead matters for drop elaboration), so a field read does not leak it.
        if self.own_temp(op, id) {
            return self.body.operands.at(op as usize).data;
        }
        return self.spill(op, sp);
    }

    // The SUBSTITUTED `&Target` a deref impl returns for receiver type `recv` (self pool): the
    // declared `&T` with the enclosing extend's generics bound by the receiver instance's args.
    // Apply auto-deref chain `du` to place `base`: a user Deref hop calls the recorded impl and
    // spills its `&Target` result, a builtin hop projects a deref. IR_NONE when a call fails.
    // `key`: the node the hops apply to; a user hop there is an implicit call, checked like an
    // explicit one (`maybe_cancel_check`).
    fn apply_place_derefs(self: &mut Self, base0: ir::PlaceId, du: *const DerefUse, key: NodeId, sp: tok::Span) ir::PlaceId {
        let mut base = base0;
        for s in 0..unsafe (*du).n {
            let m = unsafe (*du).method[s as usize];
            let rt = unsafe (*du).recv[s as usize];
            if m.node != NODE_NONE {
                let mut rt2 = self.deref_ret_ty(m, self.body.places.at(base as usize).ty);
                if rt2 == TYPE_NONE {
                    rt2 = rt;
                }
                let rop = self.copy_op(base);
                let start = self.body.oper_pool.len() as u32;
                self.body.oper_pool.push(rop);
                // The call's result place is the base: no temporary copies it.
                base = self.emit_call_to(m, ir::IR_NONE, start, 1, 0, 0, TYPE_NONE, TYPE_NONE, rt2, sp, ir::IR_NONE);
                self.maybe_cancel_check(key, m, false, base, rt2, sp);
            } else {
                base = self.place_project(base, ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: rt });
            }
        }
        return base;
    }

    // A `dyn fn` value (its record names no interface) or a function pointer, behind at most 8
    // references: a call through a reference to it calls the pointee.
    const fn ref_callable(self: &Self, t: TypeId) bool {
        let mut y = *self.f.ty(t);
        for _ in 0..8 {
            if y.kind != TypeKind::TYPE_REFERENCE {
                break;
            }
            y = *self.f.ty(y.as_data.elem);
        }
        return y.fn_sig() || y.kind == TypeKind::TYPE_DYN && self.f.instance(y.as_data.inst).decl == NODE_NONE;
    }

    fn deref_ret_ty(self: &mut Self, m: DefId, recv: TypeId) TypeId {
        // The method's return type and its extend's target are one item's records.
        if !self.checked_here(m.module, m.node) {
            return TYPE_NONE;
        }
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
        let mut it = TyInstance {};
        if !self.f.targs_of(rv, &mut it) {
            return rr;
        }
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
            let pat = fa.type_of(fa.at_const(nid).as_data.extend_def.target_type);
            if ext_is_identity(fa, pat, fa, m.module, nid) {
                let mut n = gens.len;
                if n > it.n as u32 {
                    n = it.n;
                }
                return self.proj_ty_map(rr, m.module, gens, &it.args[0], n);
            }
            // The extend's own arguments, each solved from the target argument that names it.
            let mut ea = [TYPE_NONE; 8];
            let mut pi = TyInstance {};
            let _ = fa.targs_of(pat, &mut pi);
            let np = ext_arity(fa, nid, pi.n);
            let mut j: u32 = 0;
            while j < np && j < it.n as u32 {
                let x = xarg_of(fa, unsafe pi.args[j as usize], fa, m.module, gens);
                if x.par < 8 && x.kind == XA_PARAM {
                    unsafe ea[x.par as usize] = unsafe it.args[j as usize];
                } else if x.par < 8 && x.kind == XA_FORM {
                    let bt = (unsafe &*self.pkg).const_param_bt(m.module, unsafe fa.list(gens)[x.par as usize]);
                    unsafe ea[x.par as usize] = self.ext_form_arg(&x, unsafe it.args[j as usize], bt);
                }
                j += 1;
            }
            return self.proj_ty_map(rr, m.module, gens, &ea[0], pick(gens.len < 8, gens.len, 8));
        }
        return rr;
    }

    // The value of FORM argument `x`'s parameter (of type `bt`) at the instance argument `r` (self
    // pool): a constant for a constant, else the form `(r - k) / c` (`xarg_solve_lin`), bare when it
    // is one parameter of type `bt`. TYPE_NONE when it does not solve.
    fn ext_form_arg(self: &mut Self, x: &XArg, r: TypeId, bt: BuiltinType) TypeId {
        let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
        let y = *self.f.ty(r);
        if y.kind == TypeKind::TYPE_CONST {
            let mut q = i128::zero();
            if !xarg_solve(x, y.cval(), bt, lay::target_for((unsafe &*self.pkg).arch).ptr == 4, &mut q) {
                return TYPE_NONE;
            }
            return sa.const_value(cval_bits(q), bt);
        }
        let mut rl = ConstLin::new(bt);
        if y.kind == TypeKind::TYPE_GENERIC {
            rl = ConstLin::new((unsafe &*self.pkg).const_param_bt(y.module, y.as_data.decl));
            let _ = rl.add_term(DefId { module: y.module, node: y.as_data.decl }, i128::one());
        } else if y.kind == TypeKind::TYPE_CONST_EXPR {
            rl = *sa.const_lin_at(y.as_data.inst);
        } else {
            return TYPE_NONE;
        }
        let mut s = ConstLin::new(bt);
        if !xarg_solve_lin(x, &rl, bt, &mut s) {
            return TYPE_NONE;
        }
        let p0 = s.p[0];
        let pk = (unsafe &*(&*self.pkg).module_ast_const(p0.module)).at_const(p0.node).kind;
        if s.n == 1 && s.k.is_zero() && s.c[0] == i128::one() && pk == NodeKind::NODE_GENERIC_PARAM && (unsafe &*self.pkg).const_param_bt(
            p0.module,
            p0.node,
        ) == bt {
            return sa.intern_type(
                Ty { kind: TypeKind::TYPE_GENERIC, module: p0.module, as_data: TyAs { decl: p0.node } },
            );
        }
        return sa.intern_const_lin(&s);
    }

    fn lower_member_place(self: &mut Self, id: NodeId) ir::PlaceId {
        let d = self.f.node(id).as_data.member;
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        if d.path {
            // Path member (Enum::Variant, Type::CONST): an item, not a projection. A static
            // resolves to its OWN place (writes must reach the global, never a spilled copy).
            let pd = self.path_res(id);
            if pd.node != NODE_NONE && self.decl_kind(pd) == NodeKind::NODE_CONST && self.f.type_args(id) == null && !self.retyped_int_const(
                pd,
                ty,
            ) {
                let l2 = self.item_local(pd, ty, sp);
                return self.place_of_local(l2);
            }
            let op = self.lower_path_value(id, ir::IR_NONE);
            if op == ir::IR_NONE {
                return ir::IR_NONE;
            }
            return self.spill(op, sp);
        }
        let mut base = self.lower_place(d.object);
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
            base = self.apply_place_derefs(base, du, id, sp);
            if base == ir::IR_NONE {
                return ir::IR_NONE;
            }
        }
        // Implicit derefs through references or pointers on field access (`mm.r` on `&mut &mut H`),
        // also through the `&Target` a user Deref hop returns: the field lies in the referent's
        // storage, not the reference's.
        for _ in 0..8 {
            let bty = self.body.places.at(base as usize).ty;
            let byk = self.f.ty(bty).kind;
            if byk != TypeKind::TYPE_REFERENCE && byk != TypeKind::TYPE_POINTER {
                break;
            }
            let inner = self.f.ty(bty).as_data.elem;
            base = self.place_project(base, ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: inner });
        }
        let fd = self.f.res(d.member);
        // Union members overlap: the marker data value makes place conflicts treat every field
        // pair of the same union as the same storage.
        let mut fdata = ir::IR_NONE;
        let mut fsub = fd.node;
        {
            let bty2 = self.body.places.at(base as usize).ty;
            if bty2 != TYPE_NONE {
                let od = self.nominal_of(bty2);
                if od.node != NODE_NONE {
                    let da = unsafe &*(&*self.pkg).module_ast_const(od.module);
                    let nd = da.at_const(od.node);
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
        let mut pty = ty;
        if self.slice_view(ty) {
            pty = self.storage_ty(ty, self.proj_member_ty(self.body.places.at(base as usize).ty, fd.module, fd.node));
        }
        return self.place_project(base, ir::Projection { kind: ir::PJ_FIELD, data: fdata, sub: fsub, ty: pty });
    }

    // ---- bounds-check normalization -------------------------------------------------------------

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

    // ---- Compile-time calls ----

    // The value of call `id` of `const fn` `target` (result type `ty`) when its arguments are constant
    // (`maybe_const`) and it evaluates at compile time: a constant operand of an integer, `bool`,
    // `char`, float, `str` or bare enum, or an aggregate of them (`fold_value`). IR_NONE leaves the
    // call to run: a generic body, a run-time argument, a trap, another result type, a lowering the
    // evaluator drives for its own run, or no evaluator (lint).
    fn fold_call(self: &mut Self, id: NodeId, target: DefId, ty: TypeId, sp: tok::Span) ir::OperandId {
        let pk = unsafe &*self.pkg;
        if self.body.is_generic || ty == TYPE_NONE || pk.cir == null || self.decl_kind(target) != NodeKind::NODE_FUNCTION {
            return ir::IR_NONE;
        }
        let cev = unsafe &mut *(pk.cir as *mut iri::Interp);
        if !cev.record_folds || cev.folding_self() {
            return ir::IR_NONE;
        }
        let fa = unsafe &*pk.module_ast_const(target.module);
        let fd = fa.at_const(target.node).as_data.function;
        if !fd.is_const() || fd.is_extern() || fd.body == NODE_NONE || !self.foldable_ty(ty, 0) || !self.maybe_const(id) {
            return ir::IR_NONE;
        }
        // A failed evaluation is no error: the call runs as written.
        let mut leaves = Vector::<iri::Leaf>::new();
        let at = self.body.bytes.len();
        cev.pause_folds();
        let ok = cev.eval_leaves(self.module, id, &mut leaves, &mut self.body.bytes);
        cev.resume_folds();
        let mut k: usize = 0;
        // The constants keep the call's position but no spelling: an empty span renders `val`.
        let op = if ok {
            self.fold_value(ty, &leaves, at, &mut k, tok::Span { start: sp.start, end: sp.start });
        } else {
            ir::IR_NONE;
        };
        if op == ir::IR_NONE || k != leaves.len() {
            self.body.bytes.truncate(at);
            return ir::IR_NONE;
        }
        // The replay still sees the call boundary, and each by-value argument's consumption is
        // marked explicitly: no IR op survives to carry it.
        let d = self.f.node(id).as_data.call;
        let recv = self.f.node(d.callee).kind == NodeKind::NODE_MEMBER && !self.f.node(d.callee).as_data.member.path && fd.params.len == d.args.len + 1;
        self.tp(ir::TP_CALL_MARK, 0, id);
        if recv && !self.by_ref_param(target, 0) {
            self.tp(ir::TP_CONST_MOVE, 0, self.f.node(d.callee).as_data.member.object);
        }
        for i in 0..d.args.len {
            let pi = if recv {
                i + 1;
            } else {
                i;
            };
            if !self.by_ref_param(target, pi as usize) {
                self.tp(ir::TP_CONST_MOVE, 0, unsafe self.f.list(d.args)[i as usize]);
            }
        }
        self.tp(ir::TP_CALL, 0, id);
        return op;
    }

    // Whether a value of type `ty` (nested `depth` aggregates deep) folds to constants: an integer,
    // `bool`, `char`, float, `str`, bare enum, or an array or a struct of them.
    fn foldable_ty(self: &mut Self, ty: TypeId, depth: u32) bool {
        if ty == TYPE_NONE || depth > 16 {
            return false;
        }
        let y = *self.f.ty(ty);
        if y.kind == TypeKind::TYPE_BUILTIN {
            let bt = y.as_data.builtin;
            return bt != BuiltinType::BT_VOID && bt != BuiltinType::BT_VALIST && bt != BuiltinType::BT_C32 && bt != BuiltinType::BT_C64;
        }
        if y.kind == TypeKind::TYPE_ENUM {
            let ea = unsafe &*(&*self.pkg).module_ast_const(y.module);
            return !ea.enum_has_payload(y.as_data.decl);
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            return y.as_data.arr.len != 0 && self.foldable_ty(y.as_data.arr.elem, depth + 1);
        }
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        if y.kind == TypeKind::TYPE_STRUCT && vd_is(self.view_decls().v_str, y.as_data.decl, y.module) {
            return true;
        }
        let mut dm: ModuleId = 0;
        let dn = self.proj_owner_decl(ty, &mut dm);
        let da = unsafe &*(&*self.pkg).module_ast_const(dm);
        if dn == NODE_NONE || da.at_const(dn).kind != NodeKind::NODE_STRUCT || da.at_const(dn).as_data.aggregate.is_union {
            return false;
        }
        let ms = da.at_const(dn).as_data.aggregate.members;
        if ms.len == 0 {
            return false;
        }
        for i in 0..ms.len {
            if !da.at_const(dn).as_data.aggregate.is_tuple && da.at_const(unsafe da.list(ms)[i as usize]).kind != NodeKind::NODE_FIELD {
                return false;
            }
            if !self.foldable_ty(self.proj_field_ty(ty, i), depth + 1) {
                return false;
            }
        }
        return true;
    }

    // The operand of a folded value of type `ty` (`foldable_ty`) from `leaves[*k..]`, whose `str`
    // bytes start at `at` in the body's pool; it advances `*k` past them. IR_NONE when they do not
    // match the type.
    fn fold_value(self: &mut Self, ty: TypeId, leaves: &Vector<iri::Leaf>, at: usize, k: &mut usize, sp: tok::Span) ir::OperandId {
        let y = *self.f.ty(ty);
        if y.kind == TypeKind::TYPE_BUILTIN || y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_STRUCT && vd_is(
            self.view_decls().v_str,
            y.as_data.decl,
            y.module,
        ) {
            if *k >= leaves.len() {
                return ir::IR_NONE;
            }
            let l = leaves[*k];
            *k += 1;
            if y.kind == TypeKind::TYPE_STRUCT {
                return if l.kind == iri::LF_BYTES {
                    self.kop(ir::CK_BYTES, ty, l.v + (at as i64 << 32), sp);
                } else {
                    ir::IR_NONE;
                };
            }
            if y.kind == TypeKind::TYPE_ENUM {
                return self.fold_variant(ty, l, sp);
            }
            let bt = y.as_data.builtin;
            if bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64 {
                if l.kind != iri::LF_FLOAT {
                    return ir::IR_NONE;
                }
                // An f32 NaN narrows by its bits: a conversion would quiet a signaling one.
                let u = l.v as u64;
                let bits = if bt != BuiltinType::BT_F32 {
                    l.v;
                } else if (u >> 52 & 0x7FF) == 0x7FF && (u & 0xFFFFFFFFFFFFF) != 0 {
                    (u >> 63 << 31 | 0xFFu64 << 23 | u >> 29 & 0x7FFFFF) as i64;
                } else {
                    (f64::from_bits(u) as f32).to_bits() as i64;
                };
                return self.kop(ir::CK_FBITS, ty, bits, sp);
            }
            if l.kind != pick(bt == BuiltinType::BT_BOOL, iri::LF_BOOL, iri::LF_INT) {
                return ir::IR_NONE;
            }
            return self.kop(pick(bt == BuiltinType::BT_BOOL, ir::CK_BOOL, ir::CK_INT), ty, l.v, sp);
        }
        let mut argv = self.avget();
        let mut agg = ir::AGG_ARRAY;
        let mut item = DefId { module: 0, node: NODE_NONE };
        if y.kind == TypeKind::TYPE_ARRAY {
            for _i in 0..y.as_data.arr.len {
                argv.push(self.fold_value(y.as_data.arr.elem, leaves, at, k, sp));
            }
        } else {
            let mut dm: ModuleId = 0;
            let dn = self.proj_owner_decl(ty, &mut dm);
            let ag = (unsafe &*(&*self.pkg).module_ast_const(dm)).at_const(dn).as_data.aggregate;
            agg = pick(ag.is_tuple, ir::AGG_TUPLE, ir::AGG_STRUCT);
            item = DefId { module: dm, node: dn };
            for i in 0..ag.members.len {
                argv.push(self.fold_value(self.proj_field_ty(ty, i), leaves, at, k, sp));
            }
        }
        let mut op = ir::IR_NONE;
        if !argv.contains(&ir::IR_NONE) {
            op = self.finish_aggregate(agg, item, &argv, ty, sp, ir::IR_NONE);
        }
        self.avput(argv);
        return op;
    }

    // The unit variant of bare enum `ty` whose value leaf `l` holds; IR_NONE when none has it.
    fn fold_variant(self: &mut Self, ty: TypeId, l: iri::Leaf, sp: tok::Span) ir::OperandId {
        let y = *self.f.ty(ty);
        if l.kind != iri::LF_INT {
            return ir::IR_NONE;
        }
        let ord = (unsafe &mut *((&*self.pkg).cir as *mut iri::Interp)).variant_of(y.module, y.as_data.decl, l.v);
        if ord < 0 {
            return ir::IR_NONE;
        }
        let ea = unsafe &*(&*self.pkg).module_ast_const(y.module);
        let vd = DefId {
            module: y.module,
            node: unsafe ea.list(ea.at_const(y.as_data.decl).as_data.aggregate.members)[ord as usize],
        };
        let argv = self.avget();
        let op = self.finish_aggregate(ir::AGG_VARIANT, vd, &argv, ty, sp, ir::IR_NONE);
        self.avput(argv);
        return op;
    }

    // Whether parameter `pi` of function `target` is a reference or a pointer: its argument is
    // borrowed (an implicit autoref included), not moved.
    fn by_ref_param(self: &Self, target: DefId, pi: usize) bool {
        let fa = unsafe &*(&*self.pkg).module_ast_const(target.module);
        let ps = fa.at_const(target.node).as_data.function.params;
        if pi >= ps.len as usize {
            return false;
        }
        let pt = fa.type_of(unsafe fa.list(ps)[pi]);
        if pt == TYPE_NONE {
            return false;
        }
        let pk = fa.type_at(pt).kind;
        return pk == TypeKind::TYPE_REFERENCE || pk == TypeKind::TYPE_POINTER;
    }

    // Whether expression `id` looks constant, the gate of a compile-time call (anything else makes an
    // evaluation pure waste): literals, `sizeof`, `alignof`, constants, functions and variants named,
    // and operators, casts, indexes, field reads, aggregates and `const fn` calls over them.
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
            // A left-nested chain is walked with a loop, so the depth does not grow with its length.
            let mut l = id;
            while self.f.node(l).kind == NodeKind::NODE_BINARY {
                if !self.maybe_const(self.f.node(l).as_data.binary.right) {
                    return false;
                }
                l = self.f.node(l).as_data.binary.left;
            }
            return self.maybe_const(l);
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
        if k == NodeKind::NODE_ARRAY_LITERAL || k == NodeKind::NODE_TUPLE {
            for i in 0..n.as_data.array_literal.elements.len {
                if !self.maybe_const(unsafe self.f.list(n.as_data.array_literal.elements)[i as usize]) {
                    return false;
                }
            }
            return true;
        }
        if k == NodeKind::NODE_STRUCT_INITIALIZER {
            for i in 0..n.as_data.struct_initializer.fields.len {
                let fi = unsafe self.f.list(n.as_data.struct_initializer.fields)[i as usize];
                if !self.maybe_const(self.f.node(fi).as_data.field_initializer.value) {
                    return false;
                }
            }
            return true;
        }
        if k == NodeKind::NODE_CALL {
            let c = n.as_data.call;
            // A `const fn` (a method's receiver too), a variant or a tuple struct.
            let ck = self.f.node(c.callee).kind;
            if ck == NodeKind::NODE_MEMBER && !self.f.node(c.callee).as_data.member.path {
                if !self.maybe_const(self.f.node(c.callee).as_data.member.object) {
                    return false;
                }
            } else if !self.maybe_const(c.callee) {
                return false;
            }
            let mut t = self.path_res(c.callee);
            switch self.f.call_info(id) {
                Some(v) => {
                    t = DefId { module: ci_module(v), node: ci_decl(v) };
                },
                None => {},
            };
            if t.node == NODE_NONE {
                return false;
            }
            let tk = self.decl_kind(t);
            if tk == NodeKind::NODE_FUNCTION && !(unsafe &*(&*self.pkg).module_ast_const(t.module)).at_const(t.node).as_data.function.is_const() || tk != NodeKind::NODE_FUNCTION && tk != NodeKind::NODE_VARIANT && tk != NodeKind::NODE_STRUCT {
                return false;
            }
            for i in 0..c.args.len {
                if !self.maybe_const(unsafe self.f.list(c.args)[i as usize]) {
                    return false;
                }
            }
            return true;
        }
        if k == NodeKind::NODE_MEMBER && !n.as_data.member.path {
            return self.maybe_const(n.as_data.member.object);
        }
        if k == NodeKind::NODE_IDENTIFIER || k == NodeKind::NODE_MEMBER || k == NodeKind::NODE_TYPE_PATH || k == NodeKind::NODE_GENERIC_SPECIALIZATION {
            let d = self.path_res(id);
            if d.node == NODE_NONE {
                return false;
            }
            let dk = self.decl_kind(d);
            if dk == NodeKind::NODE_FUNCTION || dk == NodeKind::NODE_VARIANT {
                return true;
            }
            if dk == NodeKind::NODE_CONST {
                let cd = (unsafe &*(&*self.pkg).module_ast_const(d.module)).at_const(d.node).as_data.const_def;
                return cd.value != NODE_NONE && !cd.is_static_mut;
            }
            return false;
        }
        return false;
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
            self.views = ViewDecls {
                ok: true,
                v_str: DefId { module: hs.mid, node: hs.node },
                v_slice: DefId { module: hl.mid, node: hl.node },
                v_slice_mut: DefId { module: hm.mid, node: hm.node },
                v_vector: DefId { module: hv.mid, node: hv.node },
                v_string: DefId { module: hg.mid, node: hg.node },
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
        if y.kind == TypeKind::TYPE_SIMD {
            return true;
        }
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

    /// True for the prelude `Slice<T>` / `SliceMut<T>` instances: the views an array coerces to.
    fn slice_view(self: &mut Self, ty: TypeId) bool {
        return self.view_kind(ty) != 0;
    }

    /// 1 for a prelude `Slice<T>` instance, 2 for `SliceMut<T>`, else 0.
    fn view_kind(self: &mut Self, ty: TypeId) u32 {
        if ty == TYPE_NONE {
            return 0;
        }
        let y = *self.f.ty(ty);
        if y.kind != TypeKind::TYPE_INSTANCE {
            return 0;
        }
        let it = *self.f.instance(y.as_data.inst);
        let v = self.view_decls();
        if vd_is(v.v_slice, it.decl, it.module) {
            return 1;
        }
        if vd_is(v.v_slice_mut, it.decl, it.module) {
            return 2;
        }
        return 0;
    }

    /// The type of a place whose node the checker coerced to slice view `ty`: `natural`, the
    /// storage's own type, when it is an array (the view is built from the place's value).
    const fn storage_ty(self: &Self, ty: TypeId, natural: TypeId) TypeId {
        if natural != TYPE_NONE && self.f.ty(natural).kind == TypeKind::TYPE_ARRAY {
            return natural;
        }
        return ty;
    }

    /// `base` reached through every reference wrapper: the place of the value itself. Element
    /// projections and the length read of a bounds check both address the view, never the reference.
    fn deref_refs(self: &mut Self, base: ir::PlaceId) ir::PlaceId {
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

    /// The cast kind of `src as dst`: a vector and its array, a mask and its bits, else numeric.
    const fn cast_kind(self: &Self, src: TypeId, dst: TypeId) u8 {
        let sk = pick(src == TYPE_NONE, TypeKind::TYPE_ERROR, self.f.ty(src).kind);
        let dk = pick(dst == TYPE_NONE, TypeKind::TYPE_ERROR, self.f.ty(dst).kind);
        if sk == TypeKind::TYPE_SIMD || dk == TypeKind::TYPE_SIMD {
            return ir::CAST_SIMD_ARRAY;
        }
        if sk == TypeKind::TYPE_MASK || dk == TypeKind::TYPE_MASK {
            return ir::CAST_MASK_BITS;
        }
        return ir::CAST_NUMERIC;
    }

    /// `[T; N]` for vector type `Simd<T, N>` `t`, in this pool.
    fn vec_array_ty(self: &mut Self, t: TypeId) TypeId {
        let y = *self.f.ty(t);
        let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
        return sa.intern_array(TypeKind::TYPE_ARRAY, y.as_data.arr.elem, y.as_data.arr.len);
    }

    /// `t = IN_BOUNDS(index, len)` against an already-materialized length operand. Returns the
    /// temp place holding the checked index; the caller addresses through it (dynamic index) or
    /// discards it (constant index, which keeps PJ_INDEX_CONST for place disjointness). `item` is the
    /// check's `item.node`: `ir::CHECK_LANES` for a lane check.
    fn bounds_check_len(self: &mut Self, iop: ir::OperandId, lop: ir::OperandId, item: NodeId, sp: tok::Span) ir::PlaceId {
        let ut = Ast::builtin(BuiltinType::BT_USIZE);
        let start = self.body.oper_pool.len() as u32;
        self.body.oper_pool.push(iop);
        self.body.oper_pool.push(lop);
        let mut rv = ir::rv(ir::RV_INTRINSIC, start, 2, ir::IN_BOUNDS, ut);
        rv.item.node = item;
        return self.rv_temp(rv, sp);
    }

    /// Materialize `RV_LEN(view)` into a temp and return its place.
    fn len_temp(self: &mut Self, view: ir::PlaceId, sp: tok::Span) ir::PlaceId {
        let ut = Ast::builtin(BuiltinType::BT_USIZE);
        return self.rv_temp(ir::rv(ir::RV_LEN, view, 0, 0, ut), sp);
    }

    /// `t = IN_BOUNDS(index, RV_LEN(view))`: the explicit element check. A vector's is a lane check
    /// (`ir::CHECK_LANES`) against its lane count, a constant once known, as a loop bound is.
    fn bounds_check(self: &mut Self, view: ir::PlaceId, iop: ir::OperandId, sp: tok::Span) ir::PlaceId {
        let t = self.peeled_view_ty(view);
        let vec = t != TYPE_NONE && self.f.ty(t).kind == TypeKind::TYPE_SIMD;
        let mut n: u64 = 0;
        if vec {
            n = self.f.lanes(self.f.ty(t));
        }
        let lop = if n != 0 {
            self.kop(ir::CK_INT, Ast::builtin(BuiltinType::BT_USIZE), n as i64, sp);
        } else {
            self.copy_op(self.len_temp(view, sp));
        };
        return self.bounds_check_len(iop, lop, pick(vec, ir::CHECK_LANES, NODE_NONE), sp);
    }

    // `obj[lo..hi]` through an `Index` conformance: `m` (`index_range`, or `index_range_mut` for a
    // mutated sub-view) called on `obj` and the bounds packed into the range node's `Range<usize>`. A
    // missing start is 0; a missing end is the `len` method the checker recorded on the range node.
    fn lower_index_range_call(self: &mut Self, id: NodeId, m: u64) ir::PlaceId {
        let d = self.f.node(id).as_data.index;
        let sp = self.f.node(id).span;
        let md = DefId { module: (m >> 32) as ModuleId, node: (m & 0xFFFFFFFFu64) as NodeId };
        let lop = self.lower_expr(d.object);
        if lop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        // A temporary object (`mk()[1..3]`) is the scope's to drop, as an operator's left operand.
        self.own_operand(lop, d.object);
        let recv = self.op_recv(md, lop, sp);
        let rd = self.f.node(d.index).as_data.pattern_range;
        let ut = Ast::builtin(BuiltinType::BT_USIZE);
        let mut sop = ir::IR_NONE;
        if rd.start != NODE_NONE {
            sop = self.lower_expr(rd.start);
        } else {
            sop = self.kop(ir::CK_INT, ut, 0, sp);
        }
        if sop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let mut eop = ir::IR_NONE;
        if rd.end != NODE_NONE {
            eop = self.lower_expr(rd.end);
        } else {
            let lm = self.f.op_method(d.index).unwrap();
            let mut lv = self.avget();
            lv.push(recv);
            let start = self.pool_ops(&lv);
            self.avput(lv);
            let ts = self.body.targ_pool.len() as u32;
            let tn = self.copy_targs(d.index);
            eop = self.emit_call(
                DefId { module: (lm >> 32) as ModuleId, node: (lm & 0xFFFFFFFFu64) as NodeId },
                ir::IR_NONE,
                start,
                1,
                ts,
                tn,
                TYPE_NONE,
                TYPE_NONE,
                ut,
                sp,
            );
        }
        if eop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let mut argv = self.avget();
        argv.push(sop);
        argv.push(eop);
        argv.push(self.kop(ir::CK_BOOL, Ast::builtin(BuiltinType::BT_BOOL), rd.inclusive as i64, sp));
        let rop = self.finish_aggregate(
            ir::AGG_STRUCT,
            DefId { module: 0, node: NODE_NONE },
            &argv,
            self.nty(d.index),
            sp,
            ir::IR_NONE,
        );
        self.avput(argv);
        if rop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let res = self.lower_op_call_ops(id, md.module, md.node, recv, rop, self.nty(id), ir::IR_NONE);
        if res == ir::IR_NONE {
            return ir::IR_NONE;
        }
        return self.spill(res, sp);
    }

    // Does a statement from index `from` on store to a place other than a fresh temporary?
    const fn writes_since(self: &Self, from: usize) bool {
        for i in from..self.body.statements.len() {
            let st = *self.body.statements.at(i);
            if st.kind == ir::ST_ASSIGN {
                let pl = *self.body.places.at(st.place as usize);
                if pl.proj_len != 0 || self.body.locals.at(pl.base as usize).storage != ir::LS_TEMP {
                    return true;
                }
            }
        }
        return false;
    }

    // `base` rebuilt with a fresh bounds check before each checked element projection, in order.
    fn recheck_indices(self: &mut Self, base: ir::PlaceId, sp: tok::Span) ir::PlaceId {
        let bp = *self.body.places.at(base as usize);
        let mut pl = self.place_of_local(bp.base);
        for i in 0..bp.proj_len {
            let mut pj = *self.body.projections.at((bp.proj_start + i) as usize);
            let vt = self.peeled_view_ty(pl);
            if pj.kind == ir::PJ_INDEX_OP && self.checked_view(vt) {
                pj.data = self.copy_op(self.bounds_check(pl, pj.data, sp));
            } else if pj.kind == ir::PJ_INDEX_CONST && self.checked_view(vt) && self.f.ty(vt).kind != TypeKind::TYPE_SIMD {
                let _ = self.bounds_check(
                    pl,
                    self.kop(ir::CK_INT, Ast::builtin(BuiltinType::BT_USIZE), pj.data, sp),
                    sp,
                );
            }
            pl = self.place_project(pl, pj);
        }
        return pl;
    }

    fn lower_index_place(self: &mut Self, id: NodeId) ir::PlaceId {
        let d = self.f.node(id).as_data.index;
        let ty = self.nty(id);
        let sp = self.f.node(id).span;
        switch self.f.op_method(id) {
            Some(m) => {
                if self.f.node(d.index).kind == NodeKind::NODE_RANGE {
                    return self.lower_index_range_call(id, m);
                }
                // Index conformance: place = *method(&obj, idx) -- the call yields the element ref.
                let lop = self.lower_expr(d.object);
                if lop == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                // A temporary object (`mk()[1]`) is the scope's to drop, as an operator's left operand.
                self.own_operand(lop, d.object);
                // `&E` from `index`, `&mut E` from `index_mut`: the method's declared result.
                let ma = unsafe (&*self.pkg).module_ast_const((m >> 32) as ModuleId);
                let mf = unsafe (*ma).at_const((m & 0xFFFFFFFFu64) as NodeId).as_data.function;
                let mut q = TypeQualifier::TYPE_QUAL_NONE as u8;
                if mf.returns.len == 1 {
                    let rn = unsafe (*ma).at_const(unsafe (*ma).slot_type_node(unsafe (*ma).list(mf.returns)[0]));
                    if rn.kind == NodeKind::NODE_REFERENCE_TYPE && rn.as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                        q = TypeQualifier::TYPE_QUAL_MUT as u8;
                    }
                }
                let sa = unsafe &mut *((&*self.pkg).module_ast_const(self.module) as *mut Ast);
                let rty = sa.intern_type(
                    Ty { kind: TypeKind::TYPE_REFERENCE, qualifier: q, as_data: TyAs { elem: ty } },
                );
                let res = self.lower_op_call_from(
                    id,
                    (m >> 32) as ModuleId,
                    (m & 0xFFFFFFFFu64) as NodeId,
                    lop,
                    d.index,
                    rty,
                    false,
                    ir::IR_NONE,
                );
                if res == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                let rpl = self.spill(res, sp);
                return self.place_project(rpl, ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: ty });
            },
            None => {},
        };
        let mut base = self.lower_place(d.object);
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
            // cannot overflow. A raw pointer keeps the legacy operands; a view slices through its
            // `index_range`.
            let pvt = self.peeled_view_ty(base);
            if pvt != TYPE_NONE && self.f.ty(pvt).kind == TypeKind::TYPE_ARRAY {
                let ut = Ast::builtin(BuiltinType::BT_USIZE);
                let vbase = self.deref_refs(base);
                let lpl = self.len_temp(vbase, sp);
                if sop == ir::IR_NONE {
                    sop = self.kop(ir::CK_INT, ut, 0, sp);
                }
                let mut excl = eop;
                if eop == ir::IR_NONE {
                    excl = self.copy_op(lpl);
                } else if rd.inclusive {
                    let lop0 = self.copy_op(lpl);
                    let ck = self.bounds_check_len(eop, lop0, NODE_NONE, sp);
                    let one = self.kop(ir::CK_INT, ut, 1, sp);
                    let ckop = self.copy_op(ck);
                    let etpl = self.rv_temp(ir::rv(ir::RV_BINARY, ckop, one, tt::TokenType::Plus as u8, ut), sp);
                    excl = self.copy_op(etpl);
                }
                let lop1 = self.copy_op(lpl);
                let start = self.body.oper_pool.len() as u32;
                self.body.oper_pool.push(sop);
                self.body.oper_pool.push(excl);
                self.body.oper_pool.push(lop1);
                let vtpl = self.rv_temp(ir::rv(ir::RV_INTRINSIC, start, 3, ir::IN_RANGE_BOUNDS, ut), sp);
                eop = self.copy_op(vtpl);
                fl = 0;
            }
            // A view through a reference slices its referent.
            let sbase = self.deref_refs(base);
            return self.rv_temp(
                ir::Rvalue {
                    kind: ir::RV_SLICE,
                    a: sbase,
                    b: sop,
                    c: fl,
                    target: ty,
                    item: DefId { module: 0, node: eop },
                },
                sp,
            );
        }
        // An element THROUGH a reference is the referent's storage, not the reference's: the index
        // projection sits behind a deref, exactly as a field access does, so a loan on the element
        // outlives the slot holding the reference (a call-result temporary dies at the end of its
        // block; `v.get()[i].lock()` borrows the vector, not that temporary).
        base = self.deref_refs(base);
        let mut ety = ty;
        if self.slice_view(ty) {
            let by = *self.f.ty(self.body.places.at(base as usize).ty);
            if by.kind == TypeKind::TYPE_ARRAY {
                ety = self.storage_ty(ty, by.as_data.arr.elem);
            } else if by.kind == TypeKind::TYPE_INSTANCE {
                ety = self.storage_ty(ty, self.f.instance(by.as_data.inst).args[0]);
            }
        }
        let blk = self.cur;
        let nst = self.body.statements.len();
        let iop = self.lower_expr(d.index);
        if iop == ir::IR_NONE {
            return ir::IR_NONE;
        }
        // The place reads its base again after the index operand: an operand that can write (a call,
        // a branch, a store to a user place) may change an element the base's checks already proved.
        if self.cur != blk || self.writes_since(nst) {
            base = self.recheck_indices(base, sp);
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
                        // The checker bounds a vector's constant lane (per instance when generic).
                        let vt = self.peeled_view_ty(base);
                        if self.checked_view(vt) && self.f.ty(vt).kind != TypeKind::TYPE_SIMD {
                            let _ = self.bounds_check(base, iop, sp);
                        }
                        return self.place_project(
                            base,
                            ir::Projection { kind: ir::PJ_INDEX_CONST, data: cn.val as u32, sub: 0, ty: ety },
                        );
                    }
                }
            }
        }
        let mut iop_use = iop;
        if self.checked_view(self.peeled_view_ty(base)) {
            let ck1 = self.bounds_check(base, iop, sp);
            iop_use = self.copy_op(ck1);
        }
        return self.place_project(base, ir::Projection { kind: ir::PJ_INDEX_OP, data: iop_use, sub: 0, ty: ety });
    }

    // ---- match ------------------------------------------------------------------------------------

    // Naive arm-order fallback lowering (guarded matches; the decision tree covers the rest): test each
    // arm's pattern; on success bind + run guard + body; else fall to the next arm.
    fn lower_match(self: &mut Self, id: NodeId, dest: ir::PlaceId) bool {
        let d = self.f.node(id).as_data.match_expr;
        let sp = self.f.node(id).span;
        let taken = self.bc_profile_arm(d);
        let depth = self.ext_depth_for(id);
        if taken != NODE_NONE {
            self.scope_enter();
            self.lower_arm(taken, dest, depth);
            self.scope_exit();
            return self.err.len() == 0;
        }
        self.tp(ir::TP_MARK_PUSH, 0, id);
        let sty = self.nty(d.value);
        let mut by_value = false;
        let mut user = false;
        if sty != TYPE_NONE {
            let sk = self.f.ty(sty).kind;
            // A by-value scrutinee consumes like any other user move.
            user = sk != TypeKind::TYPE_REFERENCE && sk != TypeKind::TYPE_POINTER;
            by_value = user && sk != TypeKind::TYPE_BUILTIN;
        }
        let mut guarded = false;
        for i in 0..d.arms.len {
            guarded = guarded || self.f.node(unsafe self.f.list(d.arms)[i as usize]).as_data.match_arm.guard != NODE_NONE;
        }
        // The scrutinee evaluates once into a temp the tests read. A local of a type that owns
        // nothing is tested in place when no guard runs between the tests: only the arm bodies,
        // which run after every test, can write it.
        let s0 = self.body.statements.len() as u32;
        let b0 = self.body.blocks.len() as u32;
        let blk0 = self.cur;
        let mut vpl = self.scrutinee_local(d.value);
        if by_value || guarded || vpl == ir::IR_NONE {
            vpl = self.value_temp(d.value, user, sp);
        }
        if vpl == ir::IR_NONE {
            return false;
        }
        // The scrutinee's temp keeps its one value through the tests: they read its variant when the
        // lowering sees it (`place_variant`).
        let rid = self.built_def(vpl, s0, b0, blk0);
        if rid != ir::IR_NONE {
            self.note_known(self.body.places.at(vpl as usize).base, rid);
        }
        // A by-value scrutinee's temporary owns the value. Every arm scope ends its storage, so drop
        // elaboration frees there what the arm's bindings did not move out.
        let mut own = ir::IR_NONE;
        if by_value {
            own = self.body.places.at(vpl as usize).base;
            let mut ld = *self.body.locals.at(own as usize);
            ld.decl = id;
            self.body.locals.set(own as usize, ld);
        }
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
                self.lower_match_tree(id, dest, vpl, own, &cx, &tree);
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
            self.own_scrutinee(own);
            self.tp(ir::TP_ARM, i, arm);
            let bmark = self.moved_binds.len();
            self.lower_pattern_test(ad.pattern, vpl, next_arm);
            if self.err.len() != 0 {
                return false;
            }
            let bend = self.moved_binds.len();
            if ad.guard != NODE_NONE {
                let gop = self.lower_expr(ad.guard);
                if gop == ir::IR_NONE {
                    return false;
                }
                let ok_b = self.open_block();
                if own == ir::IR_NONE {
                    self.branch_bool(gop, ok_b, next_arm, sp);
                } else {
                    // A failed guard hands the bindings back: the next arm tests the whole value.
                    let back = self.open_block();
                    self.branch_on(gop, ok_b, back, back, sp);
                    for k in bmark..bend {
                        let l = (self.moved_binds[k] >> 32) as ir::LocalId;
                        let lk = self.f.ty(self.body.locals.at(l as usize).ty).kind;
                        if lk != TypeKind::TYPE_BUILTIN && lk != TypeKind::TYPE_POINTER && lk != TypeKind::TYPE_REFERENCE {
                            let src = self.moved_binds[k] as ir::PlaceId;
                            let op = self.copy_op(self.place_of_local(l));
                            self.assign(src, self.rv_use(op, self.body.locals.at(l as usize).ty), sp);
                        }
                    }
                    self.seal(ir::goto_term(next_arm, sp), ok_b);
                }
            }
            self.moved_binds.truncate(bmark);
            if dest != ir::IR_NONE {
                self.lower_value_into(ad.body, dest, depth);
            } else {
                self.lower_stmt(ad.body);
            }
            self.tp(ir::TP_ARM_END, i, arm);
            self.scope_exit();
            if self.err.len() != 0 {
                return false;
            }
            self.seal(ir::goto_term(join, sp), next_arm);
        }
        self.tp(ir::TP_MATCH_POST, 0, id);
        // no arm matched: exhaustiveness says unreachable
        let u = ir::term0(ir::TM_UNREACHABLE, sp);
        self.seal(u, join);
        return true;
    }

    // The place of the user local or argument scrutinee `v` names, or IR_NONE.
    fn scrutinee_local(self: &mut Self, v: NodeId) ir::PlaceId {
        if self.f.node(v).kind != NodeKind::NODE_IDENTIFIER || !self.plain_value(v) {
            return ir::IR_NONE;
        }
        let r = self.f.res(v);
        if r.module != self.module || r.node == NODE_NONE {
            return ir::IR_NONE;
        }
        let l = self.local_of(r.node);
        if l == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let st = self.body.locals.at(l as usize).storage;
        if st != ir::LS_USER && st != ir::LS_ARG {
            return ir::IR_NONE;
        }
        return self.place_of_local(l);
    }

    // Register the owned scrutinee temporary `own` (IR_NONE: none) in the arm scope just entered:
    // the arm's exits end its storage after the arm's bindings.
    fn own_scrutinee(self: &mut Self, own: ir::LocalId) {
        if own != ir::IR_NONE {
            self.scope_locals.push(own);
        }
    }

    // Emit `test` == false -> on_fail, continuing in a fresh success block.
    fn require(self: &mut Self, cond: ir::OperandId, on_fail: ir::BlockId, sp: tok::Span) {
        let ok_b = self.open_block();
        self.branch_bool(cond, ok_b, on_fail, sp);
    }

    // Compare place `v` against operand `rhs` for equality into a bool operand.
    fn eq_test(self: &mut Self, v: ir::PlaceId, rhs: ir::OperandId, sp: tok::Span) ir::OperandId {
        return self.cmp_test(v, rhs, tt::TokenType::EqualEqual, sp);
    }

    // Discriminant-of-`v` == ordinal(variant) as a bool operand; also yields the payload place
    // (downcast projection) for sub-pattern tests.
    fn variant_test(self: &mut Self, v: ir::PlaceId, vd: DefId, sp: tok::Span, payload: &mut ir::PlaceId) ir::OperandId {
        let mut ord: i64 = 0;
        let en = unsafe (&*self.pkg).variant_enum(vd, &mut ord);
        if ord < 0 {
            self.fail_at("variant-ordinal", vd.node);
            return ir::IR_NONE;
        }
        let vty = self.body.places.at(v as usize).ty;
        // the C tag carries the variant's discriminant, not its ordinal
        let mut tag: i64 = 0;
        let ut = self.tag_ty(vd.module, en, ord, &mut tag);
        let kv = self.place_variant(v);
        let cond = if kv.node != NODE_NONE {
            // The value's variant is known (see `emit_tree`): the test is a constant.
            let hit = kv.module == vd.module && kv.node == vd.node;
            self.kop(ir::CK_BOOL, Ast::builtin(BuiltinType::BT_BOOL), pick(hit, 1i64, 0i64), sp);
        } else {
            let dp = self.rv_temp(ir::rv(ir::RV_DISCRIMINANT, v, 0, 0, ut), sp);
            let ord_op = self.kop(ir::CK_INT, ut, tag, sp);
            self.eq_test(dp, ord_op, sp);
        };
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

    // The referent of `pl` behind every reference or pointer layer of its type: a destructuring or
    // value-testing pattern reads the value the scrutinee refers to.
    fn pat_deref(self: &mut Self, pl: ir::PlaceId) ir::PlaceId {
        let mut cur = pl;
        let mut y = *self.f.ty(self.body.places.at(cur as usize).ty);
        while y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_POINTER {
            cur = self.place_project(cur, ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: y.as_data.elem });
            y = *self.f.ty(y.as_data.elem);
        }
        return cur;
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
        if k == NodeKind::NODE_PATTERN_WILDCARD {
            return;
        }
        if k == NodeKind::NODE_IDENTIFIER {
            self.bind_name(p, v, sp); // a struct pattern's shorthand field binds its name
            return;
        }
        if k == NodeKind::NODE_PATTERN_NAME {
            let pd = self.f.node(p).as_data.pattern;
            let vd = self.f.res(pd.name);
            if vd.node != NODE_NONE && self.decl_kind(vd) == NodeKind::NODE_VARIANT {
                let mut payload = ir::IR_NONE;
                let cond = self.variant_test(self.pat_deref(v), vd, sp, &mut payload);
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
            let cond = self.eq_test(self.pat_deref(v), lop, sp);
            self.require(cond, on_fail, sp);
            return;
        }
        if k == NodeKind::NODE_PATTERN_RANGE {
            let rd = self.f.node(p).as_data.pattern_range;
            let rv = self.pat_deref(v);
            if rd.start != NODE_NONE {
                let lo = self.pattern_bound(rd.start);
                let lop = self.lower_expr(lo);
                if lop == ir::IR_NONE {
                    return;
                }
                let cond = self.cmp_test(rv, lop, tt::TokenType::GreaterThanEqual, sp);
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
                let cond = self.cmp_test(rv, hop, rel, sp);
                self.require(cond, on_fail, sp);
            }
            return;
        }
        if k == NodeKind::NODE_PATTERN_TUPLE {
            let pd = self.f.node(p).as_data.pattern;
            if pd.name == NODE_NONE && pd.children.len == 1 {
                // a parenthesized pattern
                self.lower_pattern_test(unsafe self.f.list(pd.children)[0], v, on_fail);
                return;
            }
            let dv = self.pat_deref(v);
            let base = self.pat_variant_base(pd.name, dv, on_fail, sp);
            if base == ir::IR_NONE {
                return;
            }
            // element sub-patterns against payload/tuple fields _i
            for i in 0..pd.children.len {
                let c = unsafe self.f.list(pd.children)[i as usize];
                let cpl = self.tuple_field(base, i, c);
                self.lower_pattern_test(c, cpl, on_fail);
                if self.err.len() != 0 {
                    return;
                }
            }
            if dv == v {
                self.mention_parts(v, base);
            }
            return;
        }
        if k == NodeKind::NODE_PATTERN_STRUCT {
            let pd = self.f.node(p).as_data.pattern;
            let dv = self.pat_deref(v);
            let base = self.pat_variant_base(pd.name, dv, on_fail, sp);
            if base == ir::IR_NONE {
                return;
            }
            if dv == v {
                self.mention_parts(v, base);
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
                let fpl = self.struct_field(base, i, fsub, subp);
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
                self.seal(ir::goto_term(ok_b, sp), cont);
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
            base = self.pat_deref(base);
            let bty = self.body.places.at(base as usize).ty;
            // The declared member is the sub-place's type: a pattern node carries its binding's
            // type (a reference under a by-reference binding mode) or the enum through an
            // expected-type spill.
            let mut ty = bty;
            let mut pt = TYPE_NONE;
            if path.downcast >= 0 {
                pt = self.proj_payload_ty(bty, path.downcast, path.field);
            } else if path.fdecl != NODE_NONE {
                let mut om: ModuleId = 0;
                if self.proj_owner_decl(bty, &mut om) != NODE_NONE {
                    pt = self.proj_member_ty(bty, om, path.fdecl);
                }
            } else {
                // A tuple element: the member at position `field`.
                pt = self.proj_field_ty(bty, path.field);
            }
            if pt != TYPE_NONE {
                ty = pt;
            } else if path.pat != NODE_NONE && self.nty(path.pat) != TYPE_NONE {
                ty = self.nty(path.pat);
            }
            if path.downcast >= 0 {
                base = self.place_project(
                    base,
                    ir::Projection { kind: ir::PJ_DOWNCAST, data: path.downcast as u32, sub: path.vdecl.node, ty: bty },
                );
            }
            let mut fsub2 = path.fdecl;
            if fsub2 != NODE_NONE {
                // the field node lives in the struct's or variant's own module
                let fdk = self.decl_kind(DefId { module: path.vdecl.module, node: fsub2 });
                if fdk != NodeKind::NODE_FIELD {
                    fsub2 = NODE_NONE; // positional payload member: `._i`
                }
            } else if path.downcast < 0 {
                fsub2 = self.named_member(bty, path.field);
            }
            base = self.place_project(
                base,
                ir::Projection { kind: ir::PJ_FIELD, data: member_data(fsub2, path.field), sub: fsub2, ty: ty },
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
            if k == NodeKind::NODE_PATTERN_TUPLE && pd.name == NODE_NONE && pd.children.len == 1 {
                // a parenthesized pattern
                self.pattern_bind_total(unsafe self.f.list(pd.children)[0], v);
                return;
            }
            let mut base = self.pat_deref(v);
            let by_value = base == v;
            let vd = if pd.name != NODE_NONE {
                self.f.res(pd.name);
            } else {
                DefId { module: 0, node: NODE_NONE };
            };
            let isv = vd.node != NODE_NONE && self.decl_kind(vd) == NodeKind::NODE_VARIANT;
            if isv {
                let mut ord: i64 = 0;
                let _ = unsafe (&*self.pkg).variant_enum(vd, &mut ord);
                if ord >= 0 {
                    let bty = self.body.places.at(base as usize).ty;
                    base = self.place_project(
                        base,
                        ir::Projection { kind: ir::PJ_DOWNCAST, data: ord as u32, sub: vd.node, ty: bty },
                    );
                }
            }
            for i in 0..pd.children.len {
                let cid = unsafe self.f.list(pd.children)[i as usize];
                if k == NodeKind::NODE_PATTERN_STRUCT {
                    let fpd = self.f.node(cid).as_data.pattern;
                    if fpd.children.len == 0 {
                        continue;
                    }
                    let subp = unsafe self.f.list(fpd.children)[0];
                    let fpl = self.struct_field(base, i, self.f.res(fpd.name).node, subp);
                    self.pattern_bind_total(subp, fpl);
                } else {
                    let cpl = self.tuple_field(base, i, cid);
                    self.pattern_bind_total(cid, cpl);
                }
            }
            if by_value {
                self.mention_parts(v, base);
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
            self.seal(ir::goto_term(armb[n.arm as usize], sp), cont);
            return;
        }
        if n.kind == pat::DT_FAIL {
            self.seal(ir::term0(ir::TM_UNREACHABLE, sp), cont);
            return;
        }
        let k0 = cx.pats.at(t.edges.at(n.edge_start as usize).pat as usize).kind;
        if k0 == pat::PC_TUPLE || k0 == pat::PC_STRUCT {
            // single always-complete constructor: no runtime test
            let child = t.edges.at(n.edge_start as usize).child;
            self.emit_tree(t, cx, child, vpl, cache, armb, cont, sp);
            return;
        }
        // every test reads the value behind the scrutinee's references
        let pl = self.pat_deref(self.place_of_path(t, n.place, vpl, cache));
        if k0 == pat::PC_VARIANT || k0 == pat::PC_BOOL {
            // one switch over the discriminant / value; no place is read twice. The C tag carries
            // each variant's discriminant, not its ordinal.
            let own = self.body.places.at(pl as usize).ty;
            let mut tags = self.avget();
            let mut tm9: ModuleId = 0;
            let td9 = if k0 == pat::PC_VARIANT {
                self.proj_owner_decl(own, &mut tm9);
            } else {
                NODE_NONE;
            };
            let mut signed = false;
            if td9 != NODE_NONE {
                signed = self.tags_of_decl(tm9, td9, &mut tags);
            }
            let mut sw_op = ir::IR_NONE;
            if k0 == pat::PC_VARIANT {
                let ut = Ast::builtin(
                    if signed {
                        BuiltinType::BT_I32;
                    } else {
                        BuiltinType::BT_U32;
                    },
                );
                let kv = self.place_variant(pl);
                if kv.node != NODE_NONE {
                    // The value's variant is known: the switch reads its tag, and the C layout takes
                    // its arm alone (`CFlow`). The other arms would read payload bytes the value never
                    // set.
                    let mut ord: i64 = 0;
                    let _ = unsafe (&*self.pkg).variant_enum(kv, &mut ord);
                    let tv: u64 = if td9 != NODE_NONE {
                        tags[ord as usize];
                    } else {
                        ord as u64 & 0xFFFFFFFF;
                    };
                    sw_op = self.kop(ir::CK_INT, ut, pick(signed, (tv as u32) as i32, tv as i64), sp);
                } else {
                    let dp = self.rv_temp(ir::rv(ir::RV_DISCRIMINANT, pl, 0, 0, ut), sp);
                    sw_op = self.copy_op(dp);
                }
            } else {
                sw_op = self.copy_op(pl);
            }
            let mut blocks = self.avget();
            for e in 0..n.edge_len {
                blocks.push(self.open_block());
            }
            let dflt: ir::BlockId = if n.default_child != pat::P_NONE {
                self.open_block();
            } else {
                blocks[(n.edge_len - 1) as usize];
            };
            let mut tm = ir::term0(ir::TM_SWITCH, sp);
            tm.a = sw_op;
            tm.sw_start = self.body.switch_pool.len() as u32;
            let pairs: u32 = if n.default_child != pat::P_NONE {
                n.edge_len;
            } else {
                n.edge_len - 1;
            };
            for e in 0..pairs {
                let ep = cx.pats.at(t.edges.at((n.edge_start + e) as usize).pat as usize);
                let cv: u64 = if td9 != NODE_NONE {
                    tags[ep.val as usize];
                } else {
                    ep.val as u64 & 0xFFFFFFFF;
                };
                self.body.switch_pool.push(cv << 32 | blocks[e as usize] as u64);
            }
            self.avput(tags);
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
            self.avput(blocks);
            return;
        }
        // integers / ranges / opaque literals: a comparison chain, one edge at a time, after the
        // switch over the pieces `int_switch_plan` gives cases (`sw[e]` 1 for each; `dp` is the piece
        // the switch's default edge reaches untested)
        let mut sw = self.avget();
        let mut dp = pat::P_NONE;
        let ncase = self.int_switch_plan(t, cx, &n, &mut sw, &mut dp);
        if ncase != 0 {
            let mut blocks = self.avget();
            for e in 0..n.edge_len {
                blocks.push(
                    if sw[e as usize] == 1 {
                        self.open_block();
                    } else {
                        ir::IR_NONE;
                    },
                );
            }
            let dflt = self.open_block();
            let mut tm = ir::term0(ir::TM_SWITCH, sp);
            tm.a = self.copy_op(pl);
            tm.sw_start = self.body.switch_pool.len() as u32;
            let mut first = dflt;
            for e in 0..n.edge_len {
                if sw[e as usize] != 1 {
                    continue;
                }
                if first == dflt {
                    first = blocks[e as usize];
                }
                let ep = cx.pats.at(t.edges.at((n.edge_start + e) as usize).pat as usize);
                let hi = if ep.kind == pat::PC_INT {
                    ep.val;
                } else {
                    ep.hi;
                };
                // A piece holds at most SW_PIECE_MAX values.
                let mut v = ep.val;
                while v <= hi {
                    self.body.switch_pool.push((v as u64 & 0xFFFFFFFFu64) << 32 | blocks[e as usize] as u64);
                    v += 1;
                }
            }
            tm.sw_len = ncase;
            tm.t0 = dflt;
            self.seal(tm, first);
            for e in 0..n.edge_len {
                if sw[e as usize] != 1 {
                    continue;
                }
                let mut next = dflt;
                for e2 in e + 1..n.edge_len {
                    if sw[e2 as usize] == 1 {
                        next = blocks[e2 as usize];
                        break;
                    }
                }
                self.emit_tree(t, cx, t.edges.at((n.edge_start + e) as usize).child, vpl, cache, armb, next, sp);
            }
            self.avput(blocks);
        }
        for e in 0..n.edge_len {
            if ncase != 0 && (sw[e as usize] == 1 || e == dp) {
                continue;
            }
            let eid = (n.edge_start + e) as usize;
            let ep = *cx.pats.at(t.edges.at(eid).pat as usize);
            let hit = self.open_block();
            let miss = self.open_block();
            let mut cond = ir::IR_NONE;
            if ep.kind == pat::PC_INT {
                // A value pattern keeps its spelling; a split piece is its value.
                let ity = self.body.places.at(pl as usize).ty;
                let cop = if ep.node != NODE_NONE {
                    self.lower_expr(self.f.node(ep.node).as_data.single.value);
                } else {
                    self.kop(ir::CK_INT, ity, ep.val, sp);
                };
                if cop == ir::IR_NONE {
                    return;
                }
                cond = self.eq_test(pl, cop, sp);
            } else if ep.kind == pat::PC_RANGE && ep.node == NODE_NONE {
                // A split piece: its bounds, except one at the type's extreme, which every value meets.
                let ity = self.body.places.at(pl as usize).ty;
                if ep.val != pat::dom_min(ep.uns, ep.bits) {
                    let lop = self.kop(ir::CK_INT, ity, ep.val, sp);
                    cond = self.cmp_test(pl, lop, tt::TokenType::GreaterThanEqual, sp);
                }
                if ep.hi != pat::dom_max(ep.uns, ep.bits) {
                    let hop = self.kop(ir::CK_INT, ity, ep.hi, sp);
                    let c2 = self.cmp_test(pl, hop, tt::TokenType::LessThanEqual, sp);
                    cond = if cond == ir::IR_NONE {
                        c2;
                    } else {
                        self.bool_and(cond, c2, sp);
                    };
                }
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
                        cond = self.bool_and(cond, c2, sp);
                    }
                }
                if ok && cond == ir::IR_NONE {
                    let bt = Ast::builtin(BuiltinType::BT_BOOL);
                    cond = self.kop(ir::CK_BOOL, bt, 1, sp);
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
            self.branch_bool(cond, hit, miss, sp);
            self.emit_tree(t, cx, t.edges.at(eid).child, vpl, cache, armb, miss, sp);
        }
        self.avput(sw);
        if n.default_child != pat::P_NONE {
            self.emit_tree(t, cx, n.default_child, vpl, cache, armb, cont, sp);
        } else if dp != pat::P_NONE {
            self.emit_tree(t, cx, t.edges.at((n.edge_start + dp) as usize).child, vpl, cache, armb, cont, sp);
        } else {
            self.seal(ir::term0(ir::TM_UNREACHABLE, sp), cont);
        }
    }

    // The switch plan of integer test node `n` (its edges are disjoint pieces of the matched type):
    // `sw[e]` is 1 when the values of edge `e`'s piece are switch cases, which a piece of at most
    // SW_PIECE_MAX values is while the cases stay within SW_CASES_MAX; a wider piece keeps its test.
    // With no default child the pieces cover the type, so the widest one is the switch's default
    // edge (`dp`) and needs no test. The case count; 0 keeps the whole chain: a type past the 32-bit
    // case encoding, a head of another kind, or fewer than two cases.
    fn int_switch_plan(
        self: &Self,
        t: &pat::DecisionTree,
        cx: &pat::PatCx,
        n: &pat::DtNode,
        sw: &mut Vector<u32>,
        dp: &mut u32,
    ) u32 {
        let mut widest: i64 = 0;
        let mut wi = pat::P_NONE;
        for e in 0..n.edge_len {
            let ep = cx.pats.at(t.edges.at((n.edge_start + e) as usize).pat as usize);
            if !(ep.kind == pat::PC_INT || ep.kind == pat::PC_RANGE && ep.arity == 1) || ep.bits > 32 {
                return 0;
            }
            sw.push(0);
            let w = if ep.kind == pat::PC_INT {
                1;
            } else {
                ep.hi - ep.val + 1;
            };
            if n.default_child == pat::P_NONE && w > widest {
                widest = w;
                wi = e;
            }
        }
        let mut nc: i64 = 0;
        for e in 0..n.edge_len {
            let ep = cx.pats.at(t.edges.at((n.edge_start + e) as usize).pat as usize);
            let w = if ep.kind == pat::PC_INT {
                1;
            } else {
                ep.hi - ep.val + 1;
            };
            if e != wi && w <= SW_PIECE_MAX && nc + w <= SW_CASES_MAX {
                sw.set(e as usize, 1);
                nc += w;
            }
        }
        if nc < 2 {
            return 0;
        }
        *dp = wi;
        return nc as u32;
    }

    // Tree-driven match lowering: emit the tree, then each arm exactly once (bindings from the
    // original pattern, in source order, then the body), all joining after the match.
    fn lower_match_tree(
        self: &mut Self,
        id: NodeId,
        dest: ir::PlaceId,
        vpl: ir::PlaceId,
        own: ir::LocalId,
        cx: &pat::PatCx,
        t: &pat::DecisionTree,
    ) {
        let d = self.f.node(id).as_data.match_expr;
        let sp = self.f.node(id).span;
        let depth = self.ext_depth_for(id);
        let join = self.open_block();
        let mut armb = self.avget();
        for i in 0..d.arms.len {
            armb.push(self.open_block());
        }
        let mut cache = self.avget();
        for i in 0..t.paths.len() {
            cache.push(ir::IR_NONE);
        }
        let after = self.open_block();
        self.emit_tree(t, cx, t.root, vpl, &mut cache, &armb, after, sp);
        self.avput(cache);
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
            self.own_scrutinee(own);
            self.tp(ir::TP_ARM, i, arm9);
            self.pattern_bind_total(ad.pattern, vpl);
            if dest != ir::IR_NONE {
                self.lower_value_into(ad.body, dest, depth);
            } else {
                self.lower_stmt(ad.body);
            }
            self.tp(ir::TP_ARM_END, i, arm9);
            self.scope_exit();
            if self.err.len() != 0 {
                return;
            }
            self.seal(ir::goto_term(join, sp), join);
            if i != d.arms.len - 1 {
                // the next arm block writes next; seal moved the cursor to join already
                self.cur = join;
            }
        }
        self.avput(armb);
        self.cur = join;
        self.run_start = self.body.statements.len() as u32;
    }

    fn cmp_test(self: &mut Self, v: ir::PlaceId, rhs: ir::OperandId, rel: tt::TokenType, sp: tok::Span) ir::OperandId {
        let vop = self.copy_op(v);
        return self.bool_bin(vop, rhs, rel, sp);
    }

    // The place a tuple/struct pattern's sub-patterns match against: when `name` names a variant,
    // test it on `v` (a miss goes to `on_fail`) and give its payload; else `v`. IR_NONE when the
    // variant test fails to lower.
    fn pat_variant_base(self: &mut Self, name: NodeId, v: ir::PlaceId, on_fail: ir::BlockId, sp: tok::Span) ir::PlaceId {
        if name == NODE_NONE {
            return v;
        }
        let vd = self.f.res(name);
        if vd.node == NODE_NONE || self.decl_kind(vd) != NodeKind::NODE_VARIANT {
            return v;
        }
        let mut payload = ir::IR_NONE;
        let cond = self.variant_test(v, vd, sp, &mut payload);
        if cond == ir::IR_NONE {
            return ir::IR_NONE;
        }
        self.require(cond, on_fail, sp);
        return payload;
    }

    // A range-pattern bound is a PATTERN_LITERAL wrapper or a bare expression.
    const fn pattern_bound(self: &Self, b: NodeId) NodeId {
        if self.f.node(b).kind == NodeKind::NODE_PATTERN_LITERAL {
            return self.f.node(b).as_data.single.value;
        }
        return b;
    }

    // Element `i` of tuple or variant payload place `base`, matched by sub-pattern `c`. The declared
    // member is the element's type: the pattern node carries its binding's type (a reference under
    // a by-reference binding mode) or the enum through an expected-type spill.
    fn tuple_field(self: &mut Self, base: ir::PlaceId, i: u32, c: NodeId) ir::PlaceId {
        let bp = *self.body.places.at(base as usize);
        let mut cty = TYPE_NONE;
        let mut sub = NODE_NONE;
        if bp.proj_len != 0 && self.body.projections.at((bp.proj_start + bp.proj_len - 1) as usize).kind == ir::PJ_DOWNCAST {
            let lp = *self.body.projections.at((bp.proj_start + bp.proj_len - 1) as usize);
            cty = self.proj_payload_ty(lp.ty, lp.data, i);
        } else {
            cty = self.proj_field_ty(bp.ty, i);
            sub = self.named_member(bp.ty, i);
        }
        if cty == TYPE_NONE {
            cty = self.nty(c);
        }
        return self.place_project(
            base,
            ir::Projection { kind: ir::PJ_FIELD, data: member_data(sub, i), sub: sub, ty: cty },
        );
    }

    // The FIELD declaration of member `i` of struct `owner` (a tuple is the prelude struct
    // `Tuple2` with members `_0`, `_1`), or NODE_NONE for a positional member. A member place names
    // it as a member access does, so both reach one move path.
    fn named_member(self: &Self, owner: TypeId, i: u32) NodeId {
        let mut dm: ModuleId = 0;
        let fid = self.proj_field_node(owner, i, &mut dm);
        if fid == NODE_NONE || unsafe (&*(&*self.pkg).module_ast_const(dm)).at_const(fid).kind != NodeKind::NODE_FIELD {
            return NODE_NONE;
        }
        return fid;
    }

    // Field `fsub` (a FIELD declaration, or NODE_NONE for positional member `i`) of struct or
    // variant payload place `base`, matched by sub-pattern `c`; typed like `tuple_field`.
    fn struct_field(self: &mut Self, base: ir::PlaceId, i: u32, fsub: NodeId, c: NodeId) ir::PlaceId {
        let bty = self.body.places.at(base as usize).ty;
        let mut fty = TYPE_NONE;
        let mut om: ModuleId = 0;
        if fsub != NODE_NONE && self.proj_owner_decl(bty, &mut om) != NODE_NONE {
            fty = self.proj_member_ty(bty, om, fsub);
        }
        if fty == TYPE_NONE {
            fty = self.nty(c);
        }
        return self.place_project(
            base,
            ir::Projection { kind: ir::PJ_FIELD, data: member_data(fsub, i), sub: fsub, ty: fty },
        );
    }

    // Give every member of by-value aggregate place `base` a place. A destructuring pattern moves
    // some members out; drop elaboration then frees each member still owned through its move path,
    // and a member no place names has none.
    fn mention_members(self: &mut Self, base: ir::PlaceId) {
        let bty = self.body.places.at(base as usize).ty;
        let mut dm: ModuleId = 0;
        let dn = self.proj_owner_decl(bty, &mut dm);
        if dn == NODE_NONE {
            return;
        }
        let ag = unsafe (&*(&*self.pkg).module_ast_const(dm)).at_const(dn).as_data.aggregate;
        if unsafe (&*(&*self.pkg).module_ast_const(dm)).at_const(dn).kind != NodeKind::NODE_STRUCT || ag.is_union {
            return;
        }
        for k in 0..ag.members.len {
            let fid = self.proj_field_node(bty, k, &mut dm);
            if fid == NODE_NONE {
                return;
            }
            let _ = self.tuple_field(base, k, NODE_NONE);
        }
    }

    // Give every member of the by-value place `base` a place: the payload members of the variant
    // when `base` is a downcast of `v`, else the members of struct or tuple `v`.
    fn mention_parts(self: &mut Self, v: ir::PlaceId, base: ir::PlaceId) {
        if base == v {
            self.mention_members(base);
            return;
        }
        let bp = *self.body.places.at(base as usize);
        let lp = *self.body.projections.at((bp.proj_start + bp.proj_len - 1) as usize);
        let mut dm: ModuleId = 0;
        let vid = self.proj_variant_node(lp.ty, lp.data, &mut dm);
        if vid == NODE_NONE {
            return;
        }
        let pls = unsafe (&*(&*self.pkg).module_ast_const(dm)).at_const(vid).as_data.variant.payload;
        for k in 0..pls.len {
            let pid = unsafe (&*(&*self.pkg).module_ast_const(dm)).list(pls)[k as usize];
            let mut fsub = NODE_NONE;
            if unsafe (&*(&*self.pkg).module_ast_const(dm)).at_const(pid).kind == NodeKind::NODE_FIELD {
                fsub = pid;
            }
            let fty = self.proj_payload_ty(lp.ty, lp.data, k);
            let _ = self.place_project(
                base,
                ir::Projection { kind: ir::PJ_FIELD, data: member_data(fsub, k), sub: fsub, ty: fty },
            );
        }
    }

    // Bind name pattern `p` to place `v`. A by-reference binding mode shows as one more reference
    // layer on the binding's checked type than on the place: the binding borrows the place.
    fn bind_name(self: &mut Self, p: NodeId, v: ir::PlaceId, sp: tok::Span) {
        let ty = self.body.places.at(v as usize).ty;
        let bty = self.nty(p);
        let by_ref = bty != TYPE_NONE && self.ref_depth(bty) == self.ref_depth(ty) + 1;
        let lty = if by_ref {
            bty;
        } else {
            ty;
        };
        let l = self.body.add_local(self.local_decl(lty, ir::LS_USER, true, sp, p));
        self.bind(p, l);
        self.user_local_live(l, sp);
        let pl = self.place_of_local(l);
        if by_ref {
            let mb: u32 = if self.f.ty(bty).qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                1;
            } else {
                0;
            };
            self.assign(pl, ir::rv(ir::RV_REF, v, mb, 0, bty), sp);
            return;
        }
        self.moved_binds.push(l as u64 << 32 | v as u64);
        let op = self.copy_op(v);
        let rv = self.rv_use(op, ty);
        self.assign(pl, rv, sp);
        // A binding is immutable (`lower_let` forgets a `let mut` pattern's).
        self.note_known(l, self.body.rvalues.len() as u32 - 1);
    }

    // The number of reference layers on `t`.
    fn ref_depth(self: &Self, t: TypeId) u32 {
        let mut n: u32 = 0;
        let mut y = *self.f.ty(t);
        while y.kind == TypeKind::TYPE_REFERENCE {
            n += 1;
            y = *self.f.ty(y.as_data.elem);
        }
        return n;
    }

    // Bind an irrefutable pattern against `v` (let destructuring); refutable shapes route through
    // lower_pattern_test with an unreachable fail block.
    fn pattern_bind(self: &mut Self, p: NodeId, v: ir::PlaceId) {
        let k = self.f.node(p).kind;
        let sp = self.f.node(p).span;
        if k == NodeKind::NODE_PATTERN_WILDCARD {
            return;
        }
        if k == NodeKind::NODE_PATTERN_NAME || k == NodeKind::NODE_IDENTIFIER {
            let pd = self.f.node(p).as_data.pattern;
            if k == NodeKind::NODE_PATTERN_NAME && pd.children.len != 0 {
                self.pattern_bind(unsafe self.f.list(pd.children)[0], v);
            }
            self.bind_name(p, v, sp);
            return;
        }
        if k == NodeKind::NODE_PATTERN_TUPLE {
            let pd = self.f.node(p).as_data.pattern;
            for i in 0..pd.children.len {
                let c = unsafe self.f.list(pd.children)[i as usize];
                let cpl = self.tuple_field(v, i, c);
                self.pattern_bind(c, cpl);
                if self.err.len() != 0 {
                    return;
                }
            }
            self.mention_members(v);
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

// Does an enum with members `ms` carry a payload variant (its C tag is then the ordinal)?
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
    if op == tt::TokenType::PipeEqual {
        return tt::TokenType::Pipe as u32;
    }
    if op == tt::TokenType::CaretEqual {
        return tt::TokenType::Caret as u32;
    }
    if op == tt::TokenType::LeftShiftEqual {
        return tt::TokenType::LeftShift as u32;
    }
    if op == tt::TokenType::RightShiftEqual {
        return tt::TokenType::RightShift as u32;
    }
    return op as u32;
}

// An integer literal's exact magnitude (dec/hex, `_` separators, [iu]NN suffix stripped);
// false when the spelling is not a plain integer or passes 2^63 (the magnitude of i64's minimum).
const fn lit_int_value(src: str, sp: tok::Span, out: &mut u64) bool {
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
    let base: u64 = if hex {
        16;
    } else {
        10;
    };
    let mut v: u64 = 0;
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
        // At most 2^63: the magnitude of i64's minimum.
        if dv < 0 || v > ((1u64 << 63) - dv as u64) / base {
            return false;
        }
        v = v * base + dv as u64;
        any = true;
        i += 1;
    }
    if !any {
        return false;
    }
    *out = v;
    return true;
}

// Whether a type of kind `k` is concrete: no substitution can still change it.
const fn concrete_kind(k: TypeKind) bool {
    return k != TypeKind::TYPE_GENERIC && k != TypeKind::TYPE_ASSOC && k != TypeKind::TYPE_CONST_EXPR && k != TypeKind::TYPE_FIELD_PROJECTION && k != TypeKind::TYPE_CONST && k != TypeKind::TYPE_ERROR;
}
