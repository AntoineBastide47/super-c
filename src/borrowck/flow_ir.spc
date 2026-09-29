// Production flow diagnostics from the Core IR loan/move analysis. `bc_fn` lowers every body,
// replays its event tape, then analyzes the lowered bodies and emits the flow categories. A body
// that fails to lower is a hard error (bc_lower_err): no body ever goes unchecked.
import lexer::token as tok;
import stdlib;
import ast::ast as *;
import module::loader as loader;
import typechecker::typechecker as tc;
import borrowck::borrowck as bck;
import ir::core as ir;
import ir::lower as irl;
import borrowck::move_paths as bmp;
import borrowck::facts as bfx;
import borrowck::dataflow as bdf;
import borrowck::loans as bln;
import ir::drops as ird;
import ir::inline as inl;
import ir::print as irp;
import ir::verify as irv;
import emit::probe as prb;

/// Borrow-pass probe regions (SC_BORROW_STATS): lowering, the tape replay, the six analysis
/// stages, the Free-move rules with the wording, diagnostic emission, and drop elaboration.
pub const BP_LOWER: usize = 0;
pub const BP_REPLAY: usize = 1;
pub const BP_FOREST: usize = 2;
pub const BP_FACTS: usize = 3;
pub const BP_CFG: usize = 4;
pub const BP_LIVE: usize = 5;
pub const BP_MOVES: usize = 6;
pub const BP_SOLVER: usize = 7;
pub const BP_RULES: usize = 8;
pub const BP_EMIT: usize = 9;
pub const BP_SETUP: usize = 10; // per-module checker construction and diagnostic finalization
pub const BP_DECL: usize = 11; // declaration-level lifetime checks and the per-function preludes
pub const BP_REACH: usize = 12; // the package's coroutine and cancellation reachability scans (once)
pub const BP_DROPS: usize = 13; // drop elaboration of the kept bodies (schedule and rewrite)
const BP_NAMES: [str<'static>; 14] = [
    "lower",
    "replay",
    "forest",
    "facts",
    "cfg",
    "liveness",
    "moves",
    "solver",
    "rules",
    "emit",
    "setup",
    "decl",
    "reach",
    "drops",
];
static_assert(BP_DROPS + 1 == 14, "one name per borrow region");
static_assert(BP_DROPS < prb::P_COUNT, "the borrow regions fit the probe");

/// Per-body tallies.
pub const BT_BODIES: usize = 0; // bodies analyzed (closures included)
pub const BT_BORING: usize = 1; // every stage skipped (stage_skip)
pub const BT_MV_SKIP: usize = 2; // move/init dataflow skipped
pub const BT_LV_SKIP: usize = 3; // liveness skipped (no loan)
pub const BT_CFG_SKIP: usize = 4; // CFG never built
pub const BT_LOANS: usize = 5;
pub const BT_PATHS: usize = 6;
pub const BT_POINTS: usize = 7;
pub const BT_BLOCKS: usize = 8;
pub const BT_LOCALS: usize = 9;
pub const BT_PLACES: usize = 10;
pub const BT_PROJS: usize = 11;
pub const BT_STMTS: usize = 12;
pub const BT_LOAN_SKIP: usize = 13; // loan discovery and dataflow skipped, move facts still generated
pub const BT_GENERIC_HELD: usize = 14; // the loan skip withheld only because a type is unresolved
pub const BT_TRIMS: usize = 15; // scratch releases past BC_SCRATCH_BUDGET
pub const BT_TAPE: usize = 16; // replay tape entries (8 bytes each)
pub const BT_IR_BYTES: usize = 17; // bytes of the lowered bodies' pools (kept exact-size)
pub const BT_TY_SLOTS: usize = 18; // type ids a publication remap rewrites in those bodies
pub const BT_ELAB: usize = 19; // bodies rewritten with drop terminators
pub const BT_DROPS: usize = 20; // drops scheduled in them
pub const BT_COUNT: usize = 21;
const TP_KINDS: usize = 32;
const TOP_N: usize = 8;

/// The probe and its tallies, one per context; task copies fold into the driver's.
pub struct BcStats {
    pub pr: prb::Probe,
    pub t: Array<u64, BT_COUNT>,
    pub top_ns: Array<u64, TOP_N>, // the slowest bodies' analysis time, descending
    pub top_id: Array<u64, TOP_N>, // module << 32 | owner node
    pub top_sz: Array<u64, TOP_N>, // blocks << 32 | points
    pub tape: Array<u64, TP_KINDS>, // replay tape entries per event kind
    pub all: bool, // record every body (SC_ITEM_STATS): (id, ns) pairs in `body_ns` and `lower_ns`
    pub body_ns: Vector<u64>,
    pub lower_ns: Vector<u64>, // Core IR lowering per body
}

extend BcStats {
    pub fn new(on: bool, mem: bool) BcStats {
        return BcStats {
            pr: prb::Probe::new(on, mem),
            t: Array::<u64, BT_COUNT>::new(),
            top_ns: Array::<u64, TOP_N>::new(),
            top_id: Array::<u64, TOP_N>::new(),
            top_sz: Array::<u64, TOP_N>::new(),
            tape: Array::<u64, TP_KINDS>::new(),
            all: false,
            body_ns: Vector::<u64>::new(),
            lower_ns: Vector::<u64>::new(),
        };
    }

    /// Record body `id` (module << 32 | node) that took `ns` when it ranks among the slowest.
    fn top_insert(self: &mut Self, ns: u64, id: u64, sz: u64) {
        if ns <= self.top_ns[TOP_N - 1] {
            return;
        }
        let mut k = TOP_N - 1;
        while k > 0 && self.top_ns[k - 1] < ns {
            self.top_ns[k] = self.top_ns[k - 1];
            self.top_id[k] = self.top_id[k - 1];
            self.top_sz[k] = self.top_sz[k - 1];
            k -= 1;
        }
        self.top_ns[k] = ns;
        self.top_id[k] = id;
        self.top_sz[k] = sz;
    }

    /// Fold a task's stats into this one.
    pub fn merge(self: &mut Self, o: &BcStats) {
        self.pr.merge(&o.pr);
        for k in 0..BT_COUNT {
            self.t[k] += o.t[k];
        }
        for k in 0..TOP_N {
            self.top_insert(o.top_ns[k], o.top_id[k], o.top_sz[k]);
        }
        for k in 0..TP_KINDS {
            self.tape[k] += o.tape[k];
        }
        for k in 0..o.body_ns.len() {
            self.body_ns.push(o.body_ns[k]);
        }
        for k in 0..o.lower_ns.len() {
            self.lower_ns.push(o.lower_ns[k]);
        }
    }

    /// Tally one lowering's product: its tape entries by kind, its pools' bytes and the type ids a
    /// publication remap would rewrite (`CoreBody::remap_types`).
    pub fn tally_ir(self: &mut Self, lw: &irl::Lowerer) {
        let b = &lw.body;
        for i in 0..lw.tape.len() {
            self.tape[(lw.tape[i] >> 56) as usize % TP_KINDS] += 1;
        }
        self.t[BT_TAPE] += lw.tape.len() as u64;
        self.t[BT_IR_BYTES] += (b.locals.len() * sizeof(ir::LocalDecl) + b.blocks.len() * sizeof(ir::BasicBlock) + b.statements.len() * sizeof(ir::Statement) + b.places.len() * sizeof(ir::Place) + b.projections.len() * sizeof(ir::Projection) + b.operands.len() * sizeof(ir::Operand) + b.rvalues.len() * sizeof(ir::Rvalue) + b.constants.len() * sizeof(ir::Constant) + (b.oper_pool.len() + b.dest_pool.len() + b.targ_pool.len()) * 4 + (b.switch_pool.len() + b.user_moves.len()) * 8 + b.asms.len() * sizeof(ir::AsmRec) + b.asm_spans.len() * sizeof(tok::Span)) as u64;
        self.t[BT_TY_SLOTS] += (b.locals.len() + b.places.len() + b.projections.len() + b.operands.len() + b.constants.len() + b.targ_pool.len() + b.rvalues.len()) as u64;
    }

    /// The report: regions, tallies, the slowest bodies, and the retained scratch capacity.
    pub fn report(self: &Self, ctx: &BorrowCtx, out: &mut String) {
        let names: []str = BP_NAMES;
        self.pr.report_regions(out, "borrow-probe", names);
        let t = &self.t;
        out.format_into(
            "  bodies {}: every stage skipped {}, loans skipped {}, held by generics {}, scratch trims {}, moves skipped {}, liveness skipped {}, cfg skipped {}, elaborated {} ({} drops)\n",
            t[BT_BODIES],
            t[BT_BORING],
            t[BT_LOAN_SKIP],
            t[BT_GENERIC_HELD],
            t[BT_TRIMS],
            t[BT_MV_SKIP],
            t[BT_LV_SKIP],
            t[BT_CFG_SKIP],
            t[BT_ELAB],
            t[BT_DROPS],
        );
        out.format_into(
            "  sizes: blocks {}, statements {}, locals {}, places {}, projections {}, points {}, move paths {}, loans {}\n",
            t[BT_BLOCKS],
            t[BT_STMTS],
            t[BT_LOCALS],
            t[BT_PLACES],
            t[BT_PROJS],
            t[BT_POINTS],
            t[BT_PATHS],
            t[BT_LOANS],
        );
        out.format_into(
            "  lowered: {} KiB of Core IR, {} type slots; tape {} entries ({} KiB):",
            t[BT_IR_BYTES] >> 10,
            t[BT_TY_SLOTS],
            t[BT_TAPE],
            t[BT_TAPE] * 8 >> 10,
        );
        for k in 0..TP_KINDS {
            if self.tape[k] == 0 {
                continue;
            }
            out.format_into(" {}={}", k, self.tape[k]);
        }
        out.push_str("\n  slowest bodies (module:node ms blocks/points):");
        for k in 0..TOP_N {
            if self.top_ns[k] == 0 {
                break;
            }
            out.format_into(
                " {}:{} {:.2} {}/{}",
                self.top_id[k] >> 32,
                self.top_id[k] & 0xFFFFFFFFu64,
                self.top_ns[k] as f64 / 1000000.0,
                self.top_sz[k] >> 32,
                self.top_sz[k] & 0xFFFFFFFFu64,
            );
        }
        out.format_into(
            "\n  retained scratch: forest {} KiB, facts {} KiB, cfg {} KiB, liveness {} KiB, moves {} KiB, solver {} KiB, drops {} KiB, lowerer pool {} entries\n",
            ctx.forest.scratch_bytes() >> 10,
            ctx.facts.scratch_bytes() >> 10,
            ctx.cfg.scratch_bytes() >> 10,
            ctx.liveness.scratch_bytes() >> 10,
            ctx.moves.scratch_bytes() >> 10,
            ctx.solver.scratch_bytes() >> 10,
            ctx.el.scratch_bytes() >> 10,
            ctx.lower_pool.len(),
        );
    }
}

/// One move/init/borrow diagnostic in source-span form, before wording and dedup.
pub struct FlowErr {
    pub start: u32,
    pub len: u32,
    pub cat: u8, // dedup category; 10 also selects the borrow-conflict note
    pub msg: String,
}

/// Nesting stacks for the walk-tape replay (one per strictly-nested event family). Pooled in
/// BorrowCtx; pre/acc are depth-indexed SLOTS (never popped) so FlowState is copied row-wise
/// by save/clear instead of whole-struct by push.
pub struct RepSt {
    pub bms: Vector<u32>,
    pub les: Vector<i32>,
    pub mbm: Vector<u32>,
    pub pre: Vector<tc::FlowState>,
    pub acc: Vector<tc::FlowState>,
    pub seg: Vector<u64>, // start<<32 | nmoved0<<16 | nborrows0
    pub fdepth: usize,
}

extend RepSt {
    /// Empty reporting state with no heap storage.
    pub fn new() RepSt {
        return RepSt {
            bms: Vector::<u32>::new(),
            les: Vector::<i32>::new(),
            mbm: Vector::<u32>::new(),
            pre: Vector::<tc::FlowState>::new(),
            acc: Vector::<tc::FlowState>::new(),
            seg: Vector::<u64>::new(),
            fdepth: 0,
        };
    }

    /// Clear for the next body, keeping capacity.
    pub fn reset(self: &mut Self) {
        self.bms.truncate(0);
        self.les.truncate(0);
        self.mbm.truncate(0);
        self.seg.truncate(0);
        self.fdepth = 0;
    }
}

/// The most regions one signature may have: `UniSt` holds a set of regions in one word.
const UNI_MAX: usize = 64;
/// No region: past UNI_MAX, or an elided output position with no elision source.
const UNI_NONE: u32 = 0xFFFFFFFF;
/// The `elide` argument of an output walk when the signature has no elision source (the elision
/// check reported it): an elided output position then has no region.
const UNI_UNSOURCED: u32 = 0xFFFFFFFE;
/// The most lifetime parameters of a struct a place walk maps through a field projection.
const UNI_FRAME_MAX: u32 = 16;
/// The most members of a struct or tuple whose regions the check keeps apart.
const UNI_MEMBERS_MAX: u32 = 16;
/// How a value's levels arrive in a slot (`UniSt::arrive`): by the edge's level change, kept (a
/// store through a parameter's reference), or all at either level (a read through one).
const UA_EDGE: u8 = 0;
const UA_KEEP: u8 = 1;
const UA_EITHER: u8 = 2;

/// Scratch of the universal-region check (`bc_ir_universal`), kept across bodies. Region 0 is
/// `'static`; every other region is a lifetime the signature names or an elided input position.
pub struct UniSt {
    pub names: Vector<tok::Span>, // per region: its name, empty for an elided input position
    pub ol: Vector<u64>, // per region: the regions it is known to outlive
    pub arg: Vector<u64>, // per parameter: its regions at the value's own level, then behind a reference
    pub ret: Vector<u64>, // per return slot: the same two words
    pub sink: Vector<u64>, // per universal origin: the two words of the slots it stands for
    pub st: Vector<u64>, // per origin: the regions arrived at its own level, behind, and at either
    pub start: Vector<u32>, // per origin (+1): CSR into `edges` of the subset edges leaving it
    pub edges: Vector<u32>,
    pub queue: Vector<u32>,
    pub queued: Vector<bool>,
    pub argof: Vector<u32>, // per origin: the parameter whose local owns it, or UNI_NONE
    pub mb: Vector<u64>, // per origin: its first member slot in `mem` << 32 | its member count
    pub mem: Vector<u64>, // per member of a body local's struct or tuple: the three words of `st`
    pub sm: Vector<u64>, // a slot's members: per member, its regions at its own level and behind
    pub pm: ModuleId, // `bc_uni_place`'s result: the place's type node, its module and frame struct
    pub pdecl: NodeId,
    pub ptyn: NodeId,
    pub pos: Vector<u64>, // pairs: an elided input position (type node << 8 | slot), its region
    pub fa: Vector<u64>, // a place walk's frame: per lifetime parameter of the struct, its region
    pub fb: Vector<u64>, // the next frame
    pub first: u32, // the first region of the parameter being walked
    pub m0: u64, // the walk's regions at the value's own level
    pub m1: u64, // the walk's regions behind a reference
    pub over: bool, // the signature has more than UNI_MAX regions
}

extend UniSt {
    /// Empty scratch with no heap storage.
    pub fn new() UniSt {
        return UniSt {
            names: Vector::<tok::Span>::new(),
            ol: Vector::<u64>::new(),
            arg: Vector::<u64>::new(),
            ret: Vector::<u64>::new(),
            sink: Vector::<u64>::new(),
            st: Vector::<u64>::new(),
            start: Vector::<u32>::new(),
            edges: Vector::<u32>::new(),
            queue: Vector::<u32>::new(),
            queued: Vector::<bool>::new(),
            argof: Vector::<u32>::new(),
            mb: Vector::<u64>::new(),
            mem: Vector::<u64>::new(),
            sm: Vector::<u64>::new(),
            pm: 0,
            pdecl: NODE_NONE,
            ptyn: NODE_NONE,
            pos: Vector::<u64>::new(),
            fa: Vector::<u64>::new(),
            fb: Vector::<u64>::new(),
            first: UNI_NONE,
            m0: 0,
            m1: 0,
            over: false,
        };
    }

    /// Heap bytes kept across bodies (capacity, not length).
    pub const fn scratch_bytes(self: &Self) u64 {
        return (self.names.capacity() * sizeof(tok::Span) + (self.ol.capacity() + self.arg.capacity() + self.ret.capacity() + self.sink.capacity() + self.st.capacity()) * sizeof(u64) + (self.start.capacity() + self.edges.capacity() + self.queue.capacity() + self.argof.capacity()) * sizeof(u32) + (self.pos.capacity() + self.fa.capacity() + self.fb.capacity() + self.mb.capacity() + self.mem.capacity() + self.sm.capacity()) * sizeof(u64) + self.queued.capacity()) as u64;
    }

    // Add region `r` to the walk's regions at the value's own level, or behind a reference.
    fn mark(self: &mut Self, r: u32, behind: bool) {
        if behind {
            self.m1 = self.m1 | 1u64 << r as u64;
        } else {
            self.m0 = self.m0 | 1u64 << r as u64;
        }
    }

    // The regions a subset edge of kind `delta` passes on from (`s0` own level, `s1` behind a
    // reference, `sa` either): `m0` and `m1` take the arriving own-level and behind regions, the
    // result is those at either level. A read through a reference drops the reference's own
    // regions and leaves the level of those behind it unknown; a store behind one puts all behind.
    fn carry(self: &mut Self, delta: u8, s0: u64, s1: u64, sa: u64) u64 {
        if delta == bfx::SD_DEREF {
            self.m0 = 0;
            self.m1 = 0;
            return s1 | sa;
        }
        if delta == bfx::SD_REF {
            self.m0 = 0;
            self.m1 = s0 | s1 | sa;
            return 0;
        }
        self.m0 = s0;
        self.m1 = s1;
        return sa;
    }

    // The regions a value (`s0` own level, `s1` behind a reference, `sa` either) brings into a slot
    // in `mode` (UA_*) over an edge of kind `delta`: into `m0` and `m1`, returning those at either.
    fn arrive(self: &mut Self, mode: u8, delta: u8, s0: u64, s1: u64, sa: u64) u64 {
        if mode == UA_KEEP {
            self.m0 = s0;
            self.m1 = s1;
            return sa;
        }
        if mode == UA_EITHER {
            self.m0 = 0;
            self.m1 = 0;
            return s1 | sa;
        }
        return self.carry(delta, s0, s1, sa);
    }

    // Does a region arriving at its own level (`a0`), behind a reference (`a1`) or at either (`va`)
    // outlive no region of the slot's at that level (`s0` its own, `s1` behind a reference)?
    fn fails(self: &Self, a0: u64, a1: u64, va: u64, s0: u64, s1: u64) bool {
        if (a0 | a1 | va) == 0 || (s0 | s1) == 0 {
            return false;
        }
        let t0 = if s0 != 0 {
            s0;
        } else {
            s1;
        };
        let t1 = if s1 != 0 {
            s1;
        } else {
            s0;
        };
        for r in 0..self.names.len() {
            let bit = 1u64 << r as u64;
            let ol = self.ol[r];
            if (a0 & bit) != 0 && (ol & t0) == 0 || (a1 & bit) != 0 && (ol & t1) == 0 || (va & bit) != 0 && (ol & (s0 | s1)) == 0 {
                return true;
            }
        }
        return false;
    }

    // Add the three words `w0`, `w1`, `wa` to the three at `v[i..i + 3]`; true when one gained a bit.
    fn join(v: &mut Vector<u64>, i: usize, w0: u64, w1: u64, wa: u64) bool {
        let n0 = v[i] | w0;
        let n1 = v[i + 1] | w1;
        let na = v[i + 2] | wa;
        if n0 == v[i] && n1 == v[i + 1] && na == v[i + 2] {
            return false;
        }
        v.set(i, n0);
        v.set(i + 1, n1);
        v.set(i + 2, na);
        return true;
    }

    // A new region named `nm` (empty: anonymous); UNI_NONE past UNI_MAX.
    fn fresh(self: &mut Self, nm: tok::Span) u32 {
        if self.names.len() >= UNI_MAX {
            self.over = true;
            return UNI_NONE;
        }
        let r = self.names.len() as u32;
        self.names.push(nm);
        self.ol.push(1u64 << r as u64);
        return r;
    }
}

/// Reusable owner of the per-body borrow pipeline: one instance is built once per analyze pass and
/// reset-and-refilled for every body, so vector capacity is kept instead of reallocated 1873+ times.
pub struct BorrowCtx {
    pub forest: bmp::MoveForest,
    pub facts: bfx::BodyFacts,
    pub cfg: bdf::Cfg,
    pub liveness: bdf::Liveness,
    pub moves: bdf::MoveFlow,
    pub solver: bln::Solver,
    pub alt: bln::Solver, // validation: the same body solved with the other row representation
    pub el: ird::ElabCtx,
    /// What `bc_run_stages` left behind for the current body, read by `bc_elaborate`: the feature
    /// bits, and whether the forest and facts, the control-flow graph and the move/init solution
    /// describe this body (a skipped stage leaves the previous body's rows).
    pub ft: u32,
    pub built: bool,
    pub have_cfg: bool,
    pub have_moves: bool,
    pub cap_spans: Vector<u32>,
    pub rep: RepSt,
    pub escaping: Vector<u32>,
    pub uni: UniSt,
    /// Spent Lowerers recycled across bodies: lower_fn/lower_closure_body re-seed on entry, so a
    /// pooled entry only donates its heap capacity (bc_lw_take retargets it at the current module).
    pub lower_pool: Vector<irl::Lowerer>,
    /// Package store the driver hands in (null = discard lowerings): every body that lowers is
    /// adopted here so the backend never lowers it again.
    pub keep: *mut irl::Keep,
    pub st: BcStats,
    /// Validation build (SC_BC_VALIDATE): every skipped stage runs and its emptiness is asserted.
    pub validate: bool,
}

/// Heap the analyses and the elaboration may keep across bodies. One outsized body grows the
/// scratch past it; the release after that body keeps every later body's retained capacity
/// bounded by its own needs.
pub const BC_SCRATCH_BUDGET: u64 = 8u64 << 20;

extend BorrowCtx {
    /// Heap bytes the analyses, the elaboration and the Lowerer pool keep across bodies (capacity,
    /// not length).
    pub const fn scratch_bytes(self: &Self) u64 {
        let mut pool: u64 = 0;
        for i in 0..self.lower_pool.len() {
            pool += self.lower_pool.at(i).retained_bytes();
        }
        return pool + self.forest.scratch_bytes() + self.facts.scratch_bytes() + self.cfg.scratch_bytes() + self.liveness.scratch_bytes() + self.moves.scratch_bytes() + self.solver.scratch_bytes() + self.alt.scratch_bytes() + self.el.scratch_bytes() + self.uni.scratch_bytes();
    }

    /// Release the analysis scratch when it outgrew the budget; the next body reallocates to its own size.
    fn trim_scratch(self: &mut Self) {
        if self.scratch_bytes() <= BC_SCRATCH_BUDGET {
            return;
        }
        self.forest = bmp::MoveForest::empty();
        self.facts = bfx::BodyFacts::empty();
        self.cfg = bdf::Cfg::empty();
        self.liveness = bdf::Liveness::empty();
        self.moves = bdf::MoveFlow::empty();
        self.solver = bln::Solver::empty();
        self.alt = bln::Solver::empty();
        self.el = ird::ElabCtx::empty();
        self.uni = UniSt::new();
        self.lower_pool = Vector::<irl::Lowerer>::new();
        if self.st.pr.on {
            self.st.t[BT_TRIMS] += 1;
        }
    }

    /// Build the control-flow graph of `body` unless it already describes it.
    fn ensure_cfg(self: &mut Self, body: &ir::CoreBody) {
        if !self.have_cfg {
            let t = self.st.pr.start();
            self.cfg.build_into(body);
            self.have_cfg = true;
            self.st.pr.stop(BP_CFG, t);
        }
    }

    /// Solve the move/init flow of `body` unless it already describes it.
    fn ensure_moves(self: &mut Self, body: &ir::CoreBody) {
        if !self.have_moves {
            let t = self.st.pr.start();
            self.moves.build_into(body, &self.forest, &self.facts, &self.cfg);
            self.have_moves = true;
            self.st.pr.stop(BP_MOVES, t);
        }
    }

    /// A context with every analysis empty; the first body allocates.
    pub fn new() BorrowCtx {
        return BorrowCtx {
            forest: bmp::MoveForest::empty(),
            facts: bfx::BodyFacts::empty(),
            cfg: bdf::Cfg::empty(),
            liveness: bdf::Liveness::empty(),
            moves: bdf::MoveFlow::empty(),
            solver: bln::Solver::empty(),
            alt: bln::Solver::empty(),
            el: ird::ElabCtx::empty(),
            ft: 0,
            built: false,
            have_cfg: false,
            have_moves: false,
            cap_spans: Vector::<u32>::new(),
            rep: RepSt::new(),
            escaping: Vector::<u32>::new(),
            uni: UniSt::new(),
            lower_pool: Vector::<irl::Lowerer>::new(),
            keep: null,
            st: BcStats::new(false, false),
            validate: stdlib::getenv("SC_BC_VALIDATE") != null,
        };
    }
}

// A Lowerer for `owner`: recycled from the pool when one is spent, else freshly built. The pool
// crosses modules (one BorrowCtx per build), so a pooled entry is retargeted at `m` first.
fn bc_lw_take(ctx: &mut BorrowCtx, pkg: *const loader::Package, m: ModuleId, owner: NodeId) irl::Lowerer {
    switch ctx.lower_pool.pop() {
        Some(lw) => {
            let mut l = lw;
            l.retarget(m);
            return l;
        },
        _ => {},
    };
    return irl::Lowerer::new(pkg, m, owner);
}

/// Typed-IR feature summary of one lowered body. Every bit over-approximates a fact-generation
/// trigger, read from the locals' types through the ownership oracle and from the operation kinds,
/// never from source syntax.
pub const FT_CARRIER: u32 = 1; // a local's type carries a borrow (reference, dyn, capturing closure, a container of one), or is an untyped multi-return temp
pub const FT_BORROWED_PARAM: u32 = 2; // an argument local carries: the signature takes a borrowed input
pub const FT_BORROW_OP: u32 = 4; // a reference, address, slice, erasure or closure rvalue, or a call taking a `&'static` parameter (an implicit autoref for it borrows)
pub const FT_GENERIC: u32 = 8; // a local's type mentions an unresolved type parameter: a possible reference
pub const FT_OWNED: u32 = 16; // a local's type owns (Free): move and drop tracking
pub const FT_UNINIT: u32 = 32; // a split-init declaration: init tracking
pub const FT_UNKNOWN: u32 = 64; // an rvalue kind outside the classified set

/// The feature bits of `body`.
pub fn body_features(ow: &mut bfx::Owner, body: &ir::CoreBody) u32 {
    let m = body.module;
    let mut ft: u32 = 0;
    if body.has_uninit_decl {
        ft = ft | FT_UNINIT;
    }
    let nargs_end = body.returns + body.args;
    for l in 0..body.locals.len() {
        let ld = *body.locals.at(l);
        if ld.ty == TYPE_NONE {
            if ld.storage == ir::LS_TEMP {
                ft = ft | FT_CARRIER;
            }
            continue;
        }
        if !ow.ast_of(m).type_concrete(ld.ty) {
            ft = ft | FT_GENERIC;
        }
        if ow.carries(m, ld.ty) {
            ft = ft | FT_CARRIER;
            if ld.storage == ir::LS_ARG && l as u32 >= body.returns && l as u32 < nargs_end {
                ft = ft | FT_BORROWED_PARAM;
            }
        }
        if ow.owns(body.owner, m, ld.ty) {
            ft = ft | FT_OWNED;
        }
    }
    for r in 0..body.rvalues.len() {
        let k = body.rvalues.at(r).kind;
        if k == ir::RV_REF || k == ir::RV_ADDR || k == ir::RV_SLICE || k == ir::RV_DYN || k == ir::RV_CLOSURE {
            ft = ft | FT_BORROW_OP;
        } else if k > ir::RV_SLICE {
            ft = ft | FT_UNKNOWN;
        }
    }
    if loan_skip(ft) {
        for bi in 0..body.blocks.len() {
            let t = body.blocks.at(bi).term;
            if t.kind == ir::TM_CALL && t.callee.node != NODE_NONE && t.args_len != 0 && ow.takes_static_ref(t.callee) {
                ft = ft | FT_BORROW_OP;
                break;
            }
        }
    }
    return ft;
}

/// May loan discovery and loan dataflow skip? Only when no bit that can produce a loan is set:
/// every loan the generator records needs a borrow rvalue, a carrying destination, or a closure,
/// and a borrowed input or an unresolved type could hide one behind a substitution.
pub const fn loan_skip(ft: u32) bool {
    return (ft & (FT_CARRIER | FT_BORROWED_PARAM | FT_BORROW_OP | FT_GENERIC | FT_UNKNOWN)) == 0;
}

/// May every analysis stage skip? The loan skip, plus no owned local (no move or free event can
/// exist) and no split-init declaration (no uninit read can exist): every stage is a no-op.
pub const fn stage_skip(ft: u32) bool {
    return loan_skip(ft) && (ft & (FT_OWNED | FT_UNINIT)) == 0;
}

/// Run the six analysis stages for `body` into `ctx` (reset-and-refill keeps vector capacity
/// across bodies); the move and borrow errors land in `ctx.moves.errs` and `ctx.solver.errs`.
/// Pure over the frozen `body`, the package's read-only ASTs, and the two private accumulators,
/// so workers may run it concurrently. Under `ctx.validate` the skipped work runs anyway and its
/// emptiness is asserted.
pub fn bc_run_stages(ow: &mut bfx::Owner, ctx: &mut BorrowCtx, body: &ir::CoreBody) {
    let ft = body_features(ow, body);
    let lskip = loan_skip(ft);
    let sskip = stage_skip(ft);
    let on9 = ctx.st.pr.on;
    let tb = if ctx.st.all {
        platform_ns();
    } else {
        0u64;
    };
    if on9 {
        ctx.st.t[BT_BODIES] += 1;
        ctx.st.t[BT_BLOCKS] += body.blocks.len() as u64;
        ctx.st.t[BT_STMTS] += body.statements.len() as u64;
        ctx.st.t[BT_LOCALS] += body.locals.len() as u64;
        ctx.st.t[BT_PLACES] += body.places.len() as u64;
        ctx.st.t[BT_PROJS] += body.projections.len() as u64;
        if sskip {
            ctx.st.t[BT_BORING] += 1;
        } else if lskip {
            ctx.st.t[BT_LOAN_SKIP] += 1;
        }
        if (ft & FT_GENERIC) != 0 && loan_skip(ft & ~FT_GENERIC) {
            ctx.st.t[BT_GENERIC_HELD] += 1;
        }
    }
    ctx.ft = ft;
    ctx.built = false;
    ctx.have_cfg = false;
    ctx.have_moves = false;
    if sskip && !ctx.validate {
        ctx.moves.errs.truncate(0);
        ctx.solver.errs.truncate(0);
        return;
    }
    let t0 = ctx.st.pr.start();
    ctx.forest.build_into(body);
    ctx.built = true;
    let t1 = ctx.st.pr.start();
    ctx.st.pr.stop(BP_FOREST, t0);
    ow.generate_into(body, &ctx.forest, &mut ctx.facts, !lskip || ctx.validate);
    ctx.st.pr.stop(BP_FACTS, t1);
    if ctx.validate {
        assert(ctx.facts.block_base.len() == body.blocks.len());
        if lskip {
            assert(ctx.facts.loans.len() == 0);
        }
        if sskip {
            assert(ctx.facts.nmoves == 0);
        }
    }
    // Boundary liveness only feeds the loan solver's origin-liveness stage, which runs for
    // loan-bearing bodies (the solver's zero-loan gate, mirrored); leave the stale rows unread
    // otherwise.
    let lv_need = ctx.facts.loans.len() != 0;
    // No move events and every local initializes at its declaration (which dominates its uses):
    // no move, double-move, partial, or uninit error can exist: skip the move/init dataflow.
    let mv_need = body.has_uninit_decl || ctx.facts.nmoves != 0;
    // The CFG feeds only those two; a body needing neither never walks it (the solver's early
    // return only stores the stale pointer).
    if lv_need || mv_need {
        ctx.ensure_cfg(body);
    }
    if lv_need {
        // Liveness is the only predecessor consumer.
        let t3 = ctx.st.pr.start();
        ctx.cfg.build_preds();
        ctx.liveness.build_into(&ctx.facts, &ctx.cfg);
        ctx.st.pr.stop(BP_LIVE, t3);
    }
    if mv_need {
        ctx.ensure_moves(body);
    } else {
        ctx.moves.errs.truncate(0);
    }
    let t5 = ctx.st.pr.start();
    ctx.solver.build_into(body, &ctx.facts, &ctx.cfg, &ctx.liveness);
    ctx.st.pr.stop(BP_SOLVER, t5);
    if ctx.validate {
        // Both row representations must give the same results.
        ctx.alt.build_rows(body, &ctx.facts, &ctx.cfg, &ctx.liveness, !ctx.solver.sparse);
        if ctx.solver.sparse {
            ctx.solver.assert_agrees(&mut ctx.alt);
        } else {
            ctx.alt.assert_agrees(&mut ctx.solver);
        }
        if lv_need || mv_need {
            assert(ctx.cfg.nblocks as usize == body.blocks.len());
        }
        if sskip {
            assert(ctx.moves.errs.len() == 0);
            assert(ctx.solver.errs.len() == 0);
        }
        bc_validate_facts(ctx, body, lv_need, mv_need);
    }
    if on9 {
        ctx.st.t[BT_LOANS] += ctx.facts.loans.len() as u64;
        ctx.st.t[BT_PATHS] += ctx.forest.paths.len() as u64;
        ctx.st.t[BT_POINTS] += ctx.facts.npoints;
        if !mv_need {
            ctx.st.t[BT_MV_SKIP] += 1;
        }
        if !lv_need {
            ctx.st.t[BT_LV_SKIP] += 1;
        }
        if !lv_need && !mv_need {
            ctx.st.t[BT_CFG_SKIP] += 1;
        }
        let dt = platform_ns() - t0.ns;
        ctx.st.top_insert(
            dt,
            body.module as u64 << 32 | body.owner.node as u64,
            body.blocks.len() as u64 << 32 | ctx.facts.npoints as u64,
        );
    }
    if ctx.st.all {
        ctx.st.body_ns.push(body.module as u64 << 32 | body.owner.node as u64);
        ctx.st.body_ns.push(platform_ns() - tb);
    }
}

// The validation build's structural checks over one body's analysis products: every move path
// has a valid parent, the init rows are sized by the path count, every loan issues at a borrow
// operation (a reference, a carrying projected copy or view, a closure capture, or a call's
// implicit autoref), every conflict names a loan and a place of the body, and each fixpoint queue
// stayed within its monotone bound (every push after the seeds follows a row change, and a row
// changes at most once per lattice bit).
fn bc_validate_facts(ctx: &BorrowCtx, body: &ir::CoreBody, lv_need: bool, mv_need: bool) {
    let nl = body.locals.len();
    for p in 0..ctx.forest.paths.len() {
        let mp = ctx.forest.paths.at(p);
        if p < nl {
            assert(mp.parent == bmp::MP_NONE && mp.base as usize == p, "a root path per local");
        } else {
            assert(mp.parent != bmp::MP_NONE && mp.parent as usize < p, "a child path follows its parent");
            assert(ctx.forest.paths.at(mp.parent as usize).base == mp.base, "a path shares its parent's local");
        }
    }
    let nb = body.blocks.len() as u32;
    let nedges = ctx.cfg.succ.len() as u32;
    if mv_need {
        let np = ctx.forest.paths.len() as u32;
        let mut w = (np + 63) / 64;
        if w == 0 {
            w = 1;
        }
        assert(ctx.moves.npaths == np && ctx.moves.words == w, "init rows sized by the path count");
        assert(ctx.moves.mi.len() as u32 == nb * w && ctx.moves.di.len() as u32 == nb * w, "one init row per block");
    }
    for l in 0..ctx.facts.loans.len() {
        let ln = ctx.facts.loans.at(l);
        assert(ln.place as usize < body.places.len(), "a loan borrows a place of the body");
        let mut bi: usize = 0;
        while bi + 1 < ctx.facts.block_base.len() && ctx.facts.block_base[bi + 1] <= ln.issued_at {
            bi += 1;
        }
        let blk = *body.blocks.at(bi);
        let si = (ln.issued_at - ctx.facts.block_base[bi]) / 2;
        if si == blk.stmt_len {
            assert(blk.term.kind == ir::TM_CALL, "a terminator loan is a call's implicit borrow");
        } else {
            let st = *body.statements.at((blk.stmt_start + si) as usize);
            assert(st.kind == ir::ST_ASSIGN, "a statement loan is issued by a store");
            let rk = body.rvalues.at(st.rvalue as usize).kind;
            assert(
                rk == ir::RV_REF || rk == ir::RV_USE || rk == ir::RV_SLICE || rk == ir::RV_CLOSURE,
                "a loan issues at a borrow operation",
            );
        }
    }
    for e in 0..ctx.solver.errs.len() {
        let er = ctx.solver.errs.at(e);
        assert(er.loan as usize < ctx.facts.loans.len(), "a borrow error names a loan of the body");
        assert(er.point < ctx.facts.npoints, "a borrow error sits at a point of the body");
    }
    if lv_need {
        assert(ctx.liveness.pushes <= nb + 2 * nedges * nl as u32, "the liveness fixpoint stays within its bound");
    }
}

/// Drop elaboration of `body` over what `bc_run_stages` left in `ctx`: the forest and facts, plus
/// the control-flow graph and the move/init solution when the stages needed them (built here
/// otherwise). Every kept body passes through once, so the keep holds elaborated bodies and the
/// emission never analyzes ownership for them again; the inliner's vet reads the pre-elaboration
/// size recorded here. A body without an owning local or an auto-freeing owning store schedules
/// nothing and is left as it is. `verify`: the checker accepted the body, so validation checks
/// the elaborated body.
pub fn bc_elaborate(ow: &mut bfx::Owner, ctx: &mut BorrowCtx, body: &mut ir::CoreBody, verify: bool) {
    let te = ctx.st.pr.start();
    body.inline_size_ok = inl::callee_size_ok(body);
    body.elaborated = true;
    let want = (ctx.ft & FT_OWNED) != 0 || ird::assign_may_schedule(ow, body);
    if !want && !ctx.validate {
        ctx.st.pr.stop(BP_DROPS, te);
        return;
    }
    if !ctx.built {
        ctx.forest.build_into(body);
        ow.generate_into(body, &ctx.forest, &mut ctx.facts, false);
        ctx.built = true;
    }
    ctx.ensure_cfg(body);
    ctx.ensure_moves(body);
    ird::elaborate_into(ow, body, &ctx.forest, &ctx.facts, &ctx.moves, &mut ctx.el);
    if ctx.validate && !want {
        assert(ctx.el.sched.drops.len() == 0, "a body outside the schedule gate schedules nothing");
    }
    if ctx.el.sched.drops.len() != 0 {
        ird::insert_drops(body, &mut ctx.el, &ctx.forest);
        if ctx.st.pr.on {
            ctx.st.t[BT_ELAB] += 1;
            ctx.st.t[BT_DROPS] += ctx.el.sched.drops.len() as u64;
        }
    }
    if ctx.validate && verify {
        bc_validate_elaborated(ow, body);
    }
    ctx.st.pr.stop(BP_DROPS, te);
}

/// The validation build's checks of one elaborated body: the structural verifier and the
/// ownership verifier; a failure prints the body and aborts.
pub fn bc_validate_elaborated(ow: &mut bfx::Owner, body: &ir::CoreBody) {
    let mut v = irv::verify(body, ow.ast_of(body.module).type_bound(), ow.pkg);
    if v.len() == 0 {
        v = ird::verify_drops(ow, body);
    }
    if v.len() != 0 {
        let file = unsafe (&*ow.pkg).modules.at(body.module as usize).file.as_str();
        let text = irp::print_body(body);
        eprintln(
            "SC_BC_VALIDATE: elaborated body {}:{} ({}) fails `{}`\n{}",
            body.module,
            body.owner.node,
            file,
            v,
            text.as_str(),
        );
        assert(false, "an elaborated body verifies and releases every value once");
    }
}

fn platform_ns() u64 {
    return std::parallel::platform::now_ns();
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
const CAT_MOVED_PARAM: u8 = 18; // use of a moved value of a type parameter (adds the `Copy` hint)
const CAT_U_RET: u8 = 19; // a returned region not declared to outlive the return type's
const CAT_U_STORE: u8 = 20; // a region stored into caller storage it is not declared to outlive
const CAT_U_STATIC: u8 = 21; // a region passed where `'static` is required
const CAT_U_LIMIT: u8 = 22; // a signature past UNI_MAX regions

extend tc::TypeChecker {
    // A body the lowering cannot express is a hard error (no body may go unchecked, and no other
    // checker exists): reported at the failing construct with the lowerer's reason slug.
    fn bc_lower_err(self: &mut Self, lw: &irl::Lowerer, owner: NodeId) {
        let a = self.cur_ast();
        let sp = if lw.err_node != NODE_NONE {
            unsafe (*a).at_const(lw.err_node).span;
        } else {
            unsafe (*a).at_const(owner).span;
        };
        self.errors.emit_span(sp, format("cannot borrow-check this body: unsupported construct ({})", lw.err));
        self.errors.note(format("this is a compiler limitation; please report it"));
    }

    /// Lower `fnid` and its closures; their tapes and facts drive the whole borrow pass.
    /// False = a body did not lower (reported here as an error). Lowerers come from
    /// `ctx.lower_pool` when available (entry re-seeds them), so steady state allocates nothing.
    pub fn bc_ir_lower(self: &mut Self, fnid: NodeId, ctx: &mut BorrowCtx, bodies: &mut Vector<irl::Lowerer>) bool {
        let pkg = self.package as *const loader::Package;
        let m = self.cur_module();
        let mut lw = bc_lw_take(ctx, pkg, m, fnid);
        let tl0 = if ctx.st.all {
            platform_ns();
        } else {
            0u64;
        };
        let lowered = lw.lower_fn(fnid);
        if tl0 != 0 {
            ctx.st.lower_ns.push(m as u64 << 32 | fnid as u64);
            ctx.st.lower_ns.push(platform_ns() - tl0);
        }
        if !lowered {
            self.bc_lower_err(&lw, fnid);
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
                self.bc_lower_err(&cl, cn);
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
                    // An owning capture the env holds is mutated in place: no `&mut` capture
                    // (the checker already moved any it borrows into mut_caps).
                    if idx >= 0 && !self.tc_capture_owns(
                        unsafe (*self.cur_ast()).type_of(
                            unsafe (*self.cur_ast()).list(unsafe (*self.cur_ast()).at_const(c).as_data.closure.captures)[idx as usize],
                        ),
                    ) {
                        let old = (unsafe (*self.cur_ast()).at(c).as_data.closure.mut_caps) as u64;
                        unsafe (*self.cur_ast()).at(c).as_data.closure.mut_caps = (old | 1u64 << idx as u64) as u32;
                        let cf = unsafe (*self.cur_ast()).closure_fact_mut(c);
                        assert(cf != null, "every checked closure has recorded facts");
                        unsafe (*cf).mut_caps = old | 1u64 << idx as u64;
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

    /// Analyze the pre-lowered bodies AFTER the walk ran (mut-capture bits are now final), then
    /// elaborate the drops of every body the keep will hold, over the analyses just built.
    pub fn bc_ir_analyze(
        self: &mut Self,
        ow: &mut bfx::Owner,
        bodies: &mut Vector<irl::Lowerer>,
        ctx: &mut BorrowCtx,
        out: &mut Vector<FlowErr>,
    ) {
        let mut seen = Vector::<u64>::new();
        for b in 0..bodies.len() {
            if ctx.st.pr.on {
                ctx.st.tally_ir(bodies.at(b));
            }
            let n0 = out.len();
            self.bc_ir_body(ow, &bodies.at(b).body, ctx, &mut seen, out);
            if ctx.keep != null {
                // A rejected body never reaches emission, and its elaboration has no correct
                // schedule to verify (a field moved out of a `Free` value cannot be released).
                let rejected = self.errors.errors.len() != self.err_wm || out.len() != n0 || ctx.moves.errs.len() != 0 || ctx.solver.errs.len() != 0;
                bc_elaborate(ow, ctx, &mut bodies.index_mut(b).body, !rejected);
            }
            ctx.trim_scratch();
        }
    }

    // The walk's Free-move safety rules, ported over Core IR moves (the walk stays silent for
    // them under `bc_quiet`). Only USER-consumption moves (CoreBody.user_moves, set by the
    // lowerer at let/return/argument/aggregate/assign positions) are checked, so pattern binds
    // and spill plumbing never fire. Unsafe regions come from the walk's recorded spans; a
    // `.free()` receiver is exempt.
    fn bc_ir_free_rules(self: &mut Self, body: &ir::CoreBody, seen: &mut Vector<u64>, out: &mut Vector<FlowErr>) {
        // In a closure body, argument locals after the declared parameters are the captures; a
        // whole-binding user move of a Free one is the walk's capture-move error.
        let mut cap_lo: u32 = 0xFFFFFFFFu32;
        let mut cap_hi: u32 = 0;
        let onode = body.owner.node;
        if onode != NODE_NONE {
            let oa = self.mod_ast(body.owner.module);
            if unsafe (*oa).at_const(onode).kind == NodeKind::NODE_CLOSURE {
                cap_lo = body.returns + unsafe (*oa).at_const(onode).as_data.closure.params.len;
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
                    // A capture taken by pointer (mutated or borrowed) is not a move.
                    let mut by_ptr: u64 = 0;
                    if k == ir::RV_CLOSURE && rv.item.node != NODE_NONE {
                        let cf = unsafe (*self.mod_ast(body.module)).closure_fact(rv.item.node);
                        if cf != null {
                            by_ptr = unsafe (&*cf).mut_caps | unsafe (&*cf).ref_caps;
                        }
                    }
                    for i in 0..rv.b {
                        if by_ptr != 0 && (by_ptr >> i as u64 & 1u64) != 0 {
                            continue;
                        }
                        self.bc_free_rule_op(
                            body,
                            cap_lo,
                            cap_hi,
                            body.oper_pool[(rv.a + i) as usize],
                            s.span,
                            false,
                            seen,
                            out,
                        );
                    }
                }
            }
            let t = blk.term;
            if t.kind == ir::TM_CALL {
                let mut exempt = false;
                if t.args_len == 1 && t.callee.node != NODE_NONE {
                    let fa = self.mod_ast(t.callee.module);
                    let fd = unsafe (*fa).at_const(t.callee.node);
                    if fd.kind == NodeKind::NODE_FUNCTION {
                        let nm = unsafe (*fa).at_const(fd.as_data.function.name).as_data.name.text;
                        exempt = tc::span_is(self.mod_src(t.callee.module), nm, "free");
                    }
                }
                for i in 0..t.args_len {
                    self.bc_free_rule_op(
                        body,
                        cap_lo,
                        cap_hi,
                        body.oper_pool[(t.args_start + i) as usize],
                        t.span,
                        exempt,
                        seen,
                        out,
                    );
                }
            } else if t.kind == ir::TM_SWITCH || t.kind == ir::TM_ASSERT {
                self.bc_free_rule_op(body, cap_lo, cap_hi, t.a, t.span, false, seen, out);
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
            // Plumbing move (pattern bind, spill), not a user consumption.
            return;
        }
        let pl = *body.places.at(op.data as usize);
        if pl.proj_len == 0 {
            // Whole-binding move: the capture and owning-const rules apply.
            let bl = *body.locals.at(pl.base as usize);
            if bl.storage == ir::LS_STATIC_REF && bl.item.node != NODE_NONE {
                let ca = self.mod_ast(bl.item.module);
                if unsafe (*ca).at_const(bl.item.node).kind == NodeKind::NODE_CONST {
                    let cd = unsafe (*ca).at_const(bl.item.node).as_data.const_def;
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
            if bl.decl != NODE_NONE && unsafe (*self.mod_ast(body.module)).at_const(bl.decl).kind == NodeKind::NODE_CONST && self.tc_type_is_free(
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
        // An indexed element of a view (slice, str, Vector: an instance or struct) lives in storage
        // the view reaches through a pointer; only an array holds its elements in place.
        let is_index = last.kind == ir::PJ_INDEX_CONST || last.kind == ir::PJ_INDEX_OP;
        let deref_of_ind = lik == TypeKind::TYPE_REFERENCE || lik == TypeKind::TYPE_POINTER || is_index && (lik == TypeKind::TYPE_INSTANCE || lik == TypeKind::TYPE_STRUCT);
        if deref_of_ind && (last.kind == ir::PJ_DEREF || is_index) {
            if !in_unsafe && !exempt {
                let msg = if self.type_at(pl.ty).kind == TypeKind::TYPE_GENERIC {
                    format(
                        "cannot move a value of a type parameter out of a dereference (it would be freed twice); add a 'Copy' bound to the parameter to copy it, or borrow it",
                    );
                } else {
                    format("cannot move a Free value out of a dereference (it would be freed twice)");
                };
                self.bc_ir_push(out, seen, CAT_F_DEREF, sp, msg);
            }
            return;
        }
        if bk == TypeKind::TYPE_POINTER {
            // Raw pointers are the unsafe world's escape hatch.
            return;
        }
        // Pointer-typed fields are HANDLES (raw pointers are borrows by rule): copying one out of
        // borrowed or owned content escapes no ownership.
        let mk = self.type_at(pl.ty).kind;
        if mk == TypeKind::TYPE_POINTER || mk == TypeKind::TYPE_REFERENCE {
            return;
        }
        let has_deref = body.place_has_deref(op.data);
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
        bc_run_stages(ow, ctx, body);
        let tr = ctx.st.pr.start();
        // Every free rule moves a Free value INTO some local (a binding or a temp), so a body with no
        // owned-typed local cannot fire any of them.
        if (ctx.ft & FT_OWNED) != 0 {
            self.bc_ir_free_rules(body, seen, out);
        }
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
                    let pty = ctx.forest.paths.at(er.path as usize).ty;
                    let cat = if pty != TYPE_NONE && self.type_at(pty).kind == TypeKind::TYPE_GENERIC {
                        CAT_MOVED_PARAM;
                    } else {
                        CAT_MOVED;
                    };
                    self.bc_ir_push(out, seen, cat, er.span, format("use of moved value"));
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
                self.bc_ir_escape(body, &ctx.facts, &ctx.solver, &er, seen, out);
            }
        }
        // Skipped stages leave the previous body's facts behind.
        if ctx.built && body.owner.node == self.icx.current_fn {
            self.bc_ir_universal(body, ctx, seen, out);
        }
        ctx.st.pr.stop(BP_RULES, tr);
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

    // Rust's check of universal regions. The regions are `'static`, each lifetime the signature
    // names and each elided input position, related by the declared bounds, by the bounds the
    // signature's references imply (what lies behind `&'r T` outlives 'r) and by `'static`
    // outliving every region. The parameters' regions flow over the body's subset edges,
    // flow-insensitively like NLL's outlives constraints, into the placeholders: the return slots,
    // the storage the parameters reach, and `'static`. A region arriving at a placeholder must
    // outlive a region of the slot's type at the level it arrives at (the value's own, behind a
    // reference, or either after a read through one). A read of a parameter's field takes the
    // regions of the field's declared type. A body local of a struct or tuple type keeps its
    // members' regions apart, and a value built or copied member by member reaches a slot of a
    // struct or tuple type member by member; past that an origin merges a value's lifetime
    // positions, so a slot with several regions at that level takes a region that outlives one.
    fn bc_ir_universal(
        self: &mut Self,
        body: &ir::CoreBody,
        ctx: &mut BorrowCtx,
        seen: &mut Vector<u64>,
        out: &mut Vector<FlowErr>,
    ) {
        let f = &ctx.facts;
        let nu = f.nuniversal;
        // Only an edge from the body into a placeholder can force a region to outlive another.
        let mut into = false;
        for k in 0..f.subsets.len() {
            let e = f.subsets.at(k);
            if e.to < nu && e.from >= nu {
                into = true;
                break;
            }
        }
        if !into {
            return;
        }
        let fnid = body.owner.node;
        let es = self.tc_elision_source(fnid);
        let a = self.cur_ast();
        let mut params = NodeList { start: 0, len: 0 };
        let mut rets = NodeList { start: 0, len: 0 };
        let _ = unsafe (*a).sig_lists(fnid, &mut params, &mut rets);
        let np = params.len.min(body.args);
        let nr = rets.len.min(body.returns);
        let u = &mut ctx.uni;
        u.names.truncate(0);
        u.ol.truncate(0);
        u.arg.truncate(0);
        u.ret.truncate(0);
        u.pos.truncate(0);
        u.over = false;
        let _ = u.fresh(tok::Span { start: 0, end: 0 });
        let mut elide = UNI_UNSOURCED;
        for i in 0..np {
            u.first = UNI_NONE;
            u.m0 = 0;
            u.m1 = 0;
            let _ = self.bc_uni_type(
                u,
                unsafe (*a).slot_type_node(unsafe (*a).list(params)[i as usize]),
                false,
                UNI_NONE,
                0,
            );
            u.arg.push(u.m0);
            u.arg.push(u.m1);
            if i as i32 == es && u.first != UNI_NONE {
                elide = u.first;
            }
        }
        for r in 0..nr {
            u.m0 = 0;
            u.m1 = 0;
            let _ = self.bc_uni_type(u, unsafe (*a).slot_type_node(unsafe (*a).list(rets)[r as usize]), false, elide, 0);
            u.ret.push(u.m0);
            u.ret.push(u.m1);
        }
        if u.over {
            let sp = self.name_span(unsafe (*a).at_const(fnid).as_data.function.name);
            self.bc_ir_push(
                out,
                seen,
                CAT_U_LIMIT,
                sp,
                format("this function exceeds the borrow checker's limit of {} lifetime positions", UNI_MAX),
            );
            return;
        }
        // The declared bounds between named regions, then the transitive closure.
        let n = u.names.len();
        for i in 1..n {
            let ri = self.tc_lt_region_of_name(u.names[i]);
            if ri == tc::REGION_NONE {
                continue;
            }
            for j in 0..n {
                let rj = if j == 0 {
                    tc::REGION_STATIC;
                } else {
                    self.tc_lt_region_of_name(u.names[j]);
                };
                if j != i && rj != tc::REGION_NONE && self.region_outlives(ri, rj) {
                    u.ol.set(i, u.ol[i] | 1u64 << j as u64);
                }
            }
        }
        let every = if n == UNI_MAX {
            0xFFFFFFFFFFFFFFFFu64;
        } else {
            (1u64 << n as u64) - 1u64;
        };
        u.ol.set(0, every);
        for k in 0..n {
            for i in 0..n {
                if (u.ol[i] >> k as u64 & 1u64) != 0 {
                    u.ol.set(i, u.ol[i] | u.ol[k]);
                }
            }
        }
        // The placeholders stand for the slots of their parameters and return slots; `'static`
        // (origin 0) for itself.
        u.sink.truncate(0);
        u.sink.resize_default(nu as usize * 2);
        u.sink.set(0, 1u64);
        u.sink.set(1, 1u64);
        let no = f.norigins as usize;
        u.st.truncate(0);
        u.st.resize_default(no * 3);
        u.queued.truncate(0);
        u.queued.resize_default(no);
        u.queue.truncate(0);
        u.argof.truncate(0);
        for _o in 0..no {
            u.argof.push(UNI_NONE);
        }
        for i in 0..np {
            let l = (body.returns + i) as usize;
            let uo = f.arg_universal[l];
            if uo != bfx::BF_NONE {
                u.sink.set(uo as usize * 2, u.sink[uo as usize * 2] | u.arg[i as usize * 2]);
                u.sink.set(uo as usize * 2 + 1, u.sink[uo as usize * 2 + 1] | u.arg[i as usize * 2 + 1]);
            }
            // Each parameter's regions start at its local.
            let lo = f.local_origin[l];
            if lo != bfx::BF_NONE && (u.arg[i as usize * 2] | u.arg[i as usize * 2 + 1]) != 0 {
                u.st.set(lo as usize * 3, u.arg[i as usize * 2]);
                u.st.set(lo as usize * 3 + 1, u.arg[i as usize * 2 + 1]);
                u.queued.set(lo as usize, true);
                u.queue.push(lo);
                u.argof.set(lo as usize, i);
            }
        }
        // The body locals whose members keep their regions apart (never a parameter or return slot).
        u.mb.truncate(0);
        u.mem.truncate(0);
        for o in 0..no {
            let l = f.origin_local[o];
            let mut cnt: u32 = 0;
            if l != bfx::BF_NONE && l >= body.returns + body.args {
                let mut d = DefId { module: 0, node: NODE_NONE };
                cnt = self.bc_uni_local_members(body, l, &mut d);
            }
            u.mb.push((u.mem.len() / 3) as u64 << 32 | cnt as u64);
            u.mem.resize_default(u.mem.len() + cnt as usize * 3);
        }
        for r in 0..nr {
            let ro = f.ret_origin[r as usize];
            if ro != bfx::BF_NONE {
                u.sink.set(ro as usize * 2, u.sink[ro as usize * 2] | u.ret[r as usize * 2]);
                u.sink.set(ro as usize * 2 + 1, u.sink[ro as usize * 2 + 1] | u.ret[r as usize * 2 + 1]);
            }
        }
        // The edges leaving each body origin (a placeholder only receives), by counting sort.
        u.start.truncate(0);
        u.start.resize_default(no + 1);
        for k in 0..f.subsets.len() {
            let e = f.subsets.at(k);
            if e.from >= nu {
                u.start.set(e.from as usize + 1, u.start[e.from as usize + 1] + 1);
            }
        }
        for o in 0..no {
            u.start.set(o + 1, u.start[o + 1] + u.start[o]);
        }
        u.edges.truncate(0);
        u.edges.resize_default(u.start[no] as usize);
        for k in 0..f.subsets.len() {
            let fr = f.subsets.at(k).from as usize;
            if fr >= nu as usize {
                // `start[fr]` advances as the cursor; the loop below restores it.
                u.edges.set(u.start[fr] as usize, k as u32);
                u.start.set(fr, u.start[fr] + 1);
            }
        }
        let mut o = no;
        while o > 0 {
            u.start.set(o, u.start[o - 1]);
            o -= 1;
        }
        u.start.set(0, 0);
        // A body origin's words (its own three, its members') only gain bits, and each gain queues it
        // once.
        let bound = u.queue.len() as u64 + (no * 3 + u.mem.len()) as u64 * UNI_MAX as u64;
        let mut pushes = u.queue.len() as u64;
        while u.queue.len() != 0 {
            let x = u.queue[u.queue.len() - 1] as usize;
            u.queue.truncate(u.queue.len() - 1);
            u.queued.set(x, false);
            for k in u.start[x]..u.start[x + 1] {
                let e = *f.subsets.at(u.edges[k as usize] as usize);
                if e.to < nu {
                    // Checked below, edge by edge.
                    continue;
                }
                if !self.bc_uni_pass(u, body, f, x, &e) {
                    continue;
                }
                let t = e.to as usize;
                if !u.queued[t] {
                    u.queued.set(t, true);
                    u.queue.push(e.to);
                    pushes += 1;
                    assert(pushes <= bound, "the universal-region flow stays within its monotone bound");
                }
            }
        }
        // Each edge from the body into a placeholder, and each into a return slot's local (the
        // value a return stores; the return's own edge into the placeholder passes it on whole):
        // every region it carries must outlive a region of the slot it reaches, at the level it
        // arrives at. The slot is the return slot, the place an assignment through a parameter
        // stores into, else every slot the placeholder stands for.
        for k in 0..f.subsets.len() {
            let e = *f.subsets.at(k);
            if e.from < nu {
                continue;
            }
            let mut rs = UNI_NONE;
            for r in 0..nr {
                if f.ret_origin[r as usize] != bfx::BF_NONE && f.local_origin[r as usize] == e.to {
                    rs = r;
                }
            }
            if e.to >= nu && rs == UNI_NONE || e.to < nu && f.origin_local[e.from as usize] < body.returns {
                continue;
            }
            let ph = if rs == UNI_NONE {
                e.to as usize;
            } else {
                f.ret_origin[rs as usize] as usize;
            };
            let v0 = self.bc_uni_from(u, body, f, e.from as usize, e.point);
            let f0 = u.m0;
            let f1 = u.m1;
            let mut s0 = u.sink[ph * 2];
            let mut s1 = u.sink[ph * 2 + 1];
            let mut si: u32 = 0;
            let blk = *body.blocks.at(self.bc_uni_site(f, e.point, &mut si));
            let ret = rs != UNI_NONE;
            let mut sp = blk.term.span;
            let mut mode = UA_EDGE;
            let mut whole = true;
            u.sm.truncate(0);
            if si < blk.stmt_len {
                let st = *body.statements.at((blk.stmt_start + si) as usize);
                sp = st.span;
                let dl = body.places.at(st.place as usize).base;
                if !ret && ph != 0 && st.kind == ir::ST_ASSIGN && dl >= body.returns && dl < body.returns + np && f.arg_universal[dl as usize] == e.to && body.place_has_deref(
                    st.place,
                ) && e.delta != bfx::SD_KEEP {
                    // An assignment through the parameter: the value keeps its own levels in the
                    // slot the place names.
                    let a = self.cur_ast();
                    let ptn = unsafe (*a).slot_type_node(unsafe (*a).list(params)[(dl - body.returns) as usize]);
                    if self.bc_uni_place(u, body, ptn, st.place) {
                        s0 = u.m0;
                        s1 = u.m1;
                        mode = if e.delta == bfx::SD_REF {
                            UA_KEEP;
                        } else {
                            UA_EITHER;
                        };
                        let _ = self.bc_uni_members(u, u.pm, u.pdecl, u.ptyn);
                    }
                }
                whole = body.places.at(st.place as usize).proj_len == 0;
            }
            if ret {
                s0 = u.ret[rs as usize * 2];
                s1 = u.ret[rs as usize * 2 + 1];
                if whole {
                    let a = self.cur_ast();
                    let rtn = unsafe (*a).slot_type_node(unsafe (*a).list(rets)[rs as usize]);
                    let _ = self.bc_uni_members(u, self.cur_module(), NODE_NONE, rtn);
                }
            }
            let mut bad = false;
            if !self.bc_uni_split(u, body, f, &e, mode, &mut bad) {
                let va = u.arrive(mode, e.delta, f0, f1, v0);
                bad = u.fails(u.m0, u.m1, va, s0, s1);
            }
            if !bad {
                continue;
            }
            let mut cat = CAT_U_STORE;
            let mut msg = format(
                "borrowed value does not live long enough: it is stored into caller-visible data whose lifetime it is not declared to outlive",
            );
            if ph == 0 {
                cat = CAT_U_STATIC;
                msg = format("lifetime mismatch: this argument's lifetime is not declared to outlive 'static");
            } else if ret {
                cat = CAT_U_RET;
                msg = format(
                    "lifetime mismatch: the returned value's lifetime is not declared to outlive the return type's lifetime",
                );
            }
            // A declaration-level check already reported this relation at its operand.
            let mut dup = false;
            for d in self.err_wm..self.errors.errors.len() {
                if self.errors.errors[d].msg.equals(&msg) {
                    dup = true;
                }
            }
            if !dup {
                self.bc_ir_push(out, seen, cat, sp, msg);
            }
        }
    }

    // The regions origin `x` passes on at `point`, before the edge's own level change: at its own
    // level in `u.m0`, behind a reference in `u.m1`, returning those at either. A parameter's own
    // regions leave at the regions of the place the operation there reads (`bc_uni_edge`); a local
    // keeping members passes on the members of the places of it the operation reads (every member
    // when it reads none); what else reached a local leaves as a whole.
    fn bc_uni_from(self: &Self, u: &mut UniSt, body: &ir::CoreBody, f: &bfx::BodyFacts, x: usize, point: u32) u64 {
        let ai = u.argof[x];
        let mut s0 = u.st[x * 3];
        let mut s1 = u.st[x * 3 + 1];
        let mut sa = u.st[x * 3 + 2];
        if ai != UNI_NONE {
            s0 = s0 & ~u.arg[ai as usize * 2];
            s1 = s1 & ~u.arg[ai as usize * 2 + 1];
            sa = sa | self.bc_uni_edge(u, body, f, ai, point);
            s0 = s0 | u.m0;
            s1 = s1 | u.m1;
        } else if (u.mb[x] & 0xFFFFFFFFu64) != 0 {
            let l = f.origin_local[x];
            let mut start: u32 = 0;
            let mut len: u32 = 0;
            let pool = self.bc_uni_ops(body, f, point, &mut start, &mut len);
            let mut hit = false;
            for k in 0..len {
                let oi = if pool {
                    body.oper_pool[(start + k) as usize];
                } else {
                    start;
                };
                if oi == ir::IR_NONE {
                    continue;
                }
                let op = *body.operands.at(oi as usize);
                if (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && body.places.at(op.data as usize).base == l {
                    hit = true;
                    sa = sa | self.bc_uni_read(u, body, x, op.data);
                    s0 = s0 | u.m0;
                    s1 = s1 | u.m1;
                }
            }
            // A borrow or view of a place of it reads that place.
            let mut si: u32 = 0;
            let blk = *body.blocks.at(self.bc_uni_site(f, point, &mut si));
            if si < blk.stmt_len {
                let st = *body.statements.at((blk.stmt_start + si) as usize);
                let rv = *body.rvalues.at(st.rvalue as usize);
                if st.kind == ir::ST_ASSIGN && (rv.kind == ir::RV_REF || rv.kind == ir::RV_SLICE) && body.places.at(
                    rv.a as usize,
                ).base == l {
                    hit = true;
                    sa = sa | self.bc_uni_read(u, body, x, rv.a);
                    s0 = s0 | u.m0;
                    s1 = s1 | u.m1;
                }
            }
            if !hit {
                let base = (u.mb[x] >> 32) as usize * 3;
                for i in 0..(u.mb[x] & 0xFFFFFFFFu64) as usize {
                    s0 = s0 | u.mem[base + i * 3];
                    s1 = s1 | u.mem[base + i * 3 + 1];
                    sa = sa | u.mem[base + i * 3 + 2];
                }
            }
        }
        u.m0 = s0;
        u.m1 = s1;
        return sa;
    }

    // The regions origin `x` passes on when `place`, a place of its local, is read: at its own level
    // in `u.m0`, behind a reference in `u.m1`, returning those at either. A parameter passes on the
    // regions of the place's declared type (`bc_uni_place`; the parameter's own when the walk
    // fails); a local keeping members, those of the member the place names (every member for the
    // whole value); besides, what else reached the origin.
    fn bc_uni_read(self: &Self, u: &mut UniSt, body: &ir::CoreBody, x: usize, place: ir::PlaceId) u64 {
        let mut s0 = u.st[x * 3];
        let mut s1 = u.st[x * 3 + 1];
        let mut sa = u.st[x * 3 + 2];
        let ai = u.argof[x];
        if ai != UNI_NONE {
            let a0 = u.arg[ai as usize * 2];
            let a1 = u.arg[ai as usize * 2 + 1];
            s0 = s0 & ~a0;
            s1 = s1 & ~a1;
            let a = self.cur_ast();
            let params = unsafe (*a).at_const(body.owner.node).as_data.function.params;
            let ptn = unsafe (*a).slot_type_node(unsafe (*a).list(params)[ai as usize]);
            if !self.bc_uni_place(u, body, ptn, place) {
                s0 = s0 | a0;
                s1 = s1 | a1;
            } else if body.place_has_deref(place) {
                sa = sa | u.m0 | u.m1;
            } else {
                s0 = s0 | u.m0;
                s1 = s1 | u.m1;
            }
        } else {
            let k = self.bc_uni_member(u, body, x, place);
            let base = (u.mb[x] >> 32) as usize * 3;
            for i in 0..(u.mb[x] & 0xFFFFFFFFu64) as u32 {
                if k == UNI_NONE || k == i {
                    s0 = s0 | u.mem[base + i as usize * 3];
                    s1 = s1 | u.mem[base + i as usize * 3 + 1];
                    sa = sa | u.mem[base + i as usize * 3 + 2];
                }
            }
        }
        u.m0 = s0;
        u.m1 = s1;
        return sa;
    }

    // Pass the regions of edge `e` from origin `x` into its target, per member where the operation
    // writes members of a local keeping them: a store into a member, an aggregate built from places
    // of `x` (each into its member), a copy of a whole local keeping the same members (member by
    // member); else into the whole value. True when the target gained a region.
    fn bc_uni_pass(self: &Self, u: &mut UniSt, body: &ir::CoreBody, f: &bfx::BodyFacts, x: usize, e: &bfx::SubsetAt) bool {
        let t = e.to as usize;
        let tc = (u.mb[t] & 0xFFFFFFFFu64) as u32;
        let tb = (u.mb[t] >> 32) as usize * 3;
        let mut si: u32 = 0;
        let blk = *body.blocks.at(self.bc_uni_site(f, e.point, &mut si));
        if tc != 0 && si < blk.stmt_len {
            let st = *body.statements.at((blk.stmt_start + si) as usize);
            let lx = f.origin_local[x];
            if st.kind == ir::ST_ASSIGN && body.places.at(st.place as usize).base == f.origin_local[t] {
                let k = self.bc_uni_member(u, body, t, st.place);
                if k != UNI_NONE {
                    let sa = self.bc_uni_from(u, body, f, x, e.point);
                    let wa = u.carry(e.delta, u.m0, u.m1, sa);
                    return UniSt::join(&mut u.mem, tb + k as usize * 3, u.m0, u.m1, wa);
                }
                let rv = *body.rvalues.at(st.rvalue as usize);
                let whole = body.places.at(st.place as usize).proj_len == 0;
                if whole && rv.kind == ir::RV_AGGREGATE && (rv.c == ir::AGG_STRUCT || rv.c == ir::AGG_TUPLE) && rv.b == tc {
                    let mut hit = false;
                    let mut grew = false;
                    for i in 0..rv.b {
                        let oi = body.oper_pool[(rv.a + i) as usize];
                        if oi == ir::IR_NONE {
                            continue;
                        }
                        let op = *body.operands.at(oi as usize);
                        if (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && body.places.at(op.data as usize).base == lx {
                            hit = true;
                            let sa = self.bc_uni_read(u, body, x, op.data);
                            let wa = u.carry(e.delta, u.m0, u.m1, sa);
                            grew = UniSt::join(&mut u.mem, tb + i as usize * 3, u.m0, u.m1, wa) || grew;
                        }
                    }
                    if hit {
                        return grew;
                    }
                }
                if whole && rv.kind == ir::RV_USE && (u.mb[x] & 0xFFFFFFFFu64) as u32 == tc && body.locals.at(
                    lx as usize,
                ).ty == body.locals.at(f.origin_local[t] as usize).ty {
                    let op = *body.operands.at(rv.a as usize);
                    let xp = *body.places.at(op.data as usize);
                    if (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && xp.base == lx && xp.proj_len == 0 {
                        let wa = u.carry(e.delta, u.st[x * 3], u.st[x * 3 + 1], u.st[x * 3 + 2]);
                        let mut grew = UniSt::join(&mut u.st, t * 3, u.m0, u.m1, wa);
                        let xb = (u.mb[x] >> 32) as usize * 3;
                        for i in 0..tc as usize {
                            let wm = u.carry(e.delta, u.mem[xb + i * 3], u.mem[xb + i * 3 + 1], u.mem[xb + i * 3 + 2]);
                            grew = UniSt::join(&mut u.mem, tb + i * 3, u.m0, u.m1, wm) || grew;
                        }
                        return grew;
                    }
                }
            }
        }
        let sa = self.bc_uni_from(u, body, f, x, e.point);
        let wa = u.carry(e.delta, u.m0, u.m1, sa);
        return UniSt::join(&mut u.st, t * 3, u.m0, u.m1, wa);
    }

    // Check edge `e` into a slot with members (`u.sm`) member by member, when the operation stores an
    // aggregate built from places of the edge's origin or a copy of a whole local keeping the same
    // members: sets `bad` when a member's regions outlive no region of the slot's member. False
    // when the edge is to be checked whole.
    fn bc_uni_split(
        self: &Self,
        u: &mut UniSt,
        body: &ir::CoreBody,
        f: &bfx::BodyFacts,
        e: &bfx::SubsetAt,
        mode: u8,
        bad: &mut bool,
    ) bool {
        let cnt = (u.sm.len() / 2) as u32;
        let mut si: u32 = 0;
        let blk = *body.blocks.at(self.bc_uni_site(f, e.point, &mut si));
        if cnt == 0 || si >= blk.stmt_len {
            return false;
        }
        let st = *body.statements.at((blk.stmt_start + si) as usize);
        let x = e.from as usize;
        let lx = f.origin_local[x];
        if st.kind != ir::ST_ASSIGN || lx == bfx::BF_NONE {
            return false;
        }
        let rv = *body.rvalues.at(st.rvalue as usize);
        if rv.kind == ir::RV_AGGREGATE && (rv.c == ir::AGG_STRUCT || rv.c == ir::AGG_TUPLE) && rv.b == cnt {
            let mut hit = false;
            for i in 0..rv.b {
                let oi = body.oper_pool[(rv.a + i) as usize];
                if oi == ir::IR_NONE {
                    continue;
                }
                let op = *body.operands.at(oi as usize);
                if (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && body.places.at(op.data as usize).base == lx {
                    hit = true;
                    let sa = self.bc_uni_read(u, body, x, op.data);
                    let va = u.arrive(mode, e.delta, u.m0, u.m1, sa);
                    if u.fails(u.m0, u.m1, va, u.sm[i as usize * 2], u.sm[i as usize * 2 + 1]) {
                        *bad = true;
                    }
                }
            }
            return hit;
        }
        if rv.kind == ir::RV_USE && (u.mb[x] & 0xFFFFFFFFu64) as u32 == cnt {
            let op = *body.operands.at(rv.a as usize);
            let xp = *body.places.at(op.data as usize);
            if (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && xp.base == lx && xp.proj_len == 0 {
                let xb = (u.mb[x] >> 32) as usize * 3;
                for i in 0..cnt as usize {
                    let va = u.arrive(
                        mode,
                        e.delta,
                        u.st[x * 3] | u.mem[xb + i * 3],
                        u.st[x * 3 + 1] | u.mem[xb + i * 3 + 1],
                        u.st[x * 3 + 2] | u.mem[xb + i * 3 + 2],
                    );
                    if u.fails(u.m0, u.m1, va, u.sm[i * 2], u.sm[i * 2 + 1]) {
                        *bad = true;
                    }
                }
                return true;
            }
        }
        return false;
    }

    // The member count of body local `l`'s struct or tuple type (its declaration in `d`) when the
    // check keeps its members' regions apart; 0 for any other type (a union's members share storage).
    fn bc_uni_local_members(self: &Self, body: &ir::CoreBody, l: u32, d: &mut DefId) u32 {
        let ty = body.locals.at(l as usize).ty;
        if ty == TYPE_NONE {
            return 0;
        }
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_STRUCT {
            *d = DefId { module: y.module, node: y.as_data.decl };
        } else if y.kind == TypeKind::TYPE_INSTANCE && unsafe (*self.cur_ast()).instance_valid(y.as_data.inst) {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            *d = DefId { module: it.module, node: it.decl };
        } else {
            return 0;
        }
        if d.node == NODE_NONE {
            return 0;
        }
        let dn = unsafe (*self.mod_ast(d.module)).at_const(d.node);
        if dn.kind != NodeKind::NODE_STRUCT || dn.as_data.aggregate.is_union || dn.as_data.aggregate.members.len > UNI_MEMBERS_MAX {
            return 0;
        }
        return dn.as_data.aggregate.members.len;
    }

    // The member of origin `x`'s local that `place` names by its first projection, or UNI_NONE (the
    // whole value, or a local keeping no members).
    fn bc_uni_member(self: &Self, u: &UniSt, body: &ir::CoreBody, x: usize, place: ir::PlaceId) u32 {
        let cnt = (u.mb[x] & 0xFFFFFFFFu64) as u32;
        let pl = *body.places.at(place as usize);
        if cnt == 0 || pl.proj_len == 0 {
            return UNI_NONE;
        }
        let pj = *body.projections.at(pl.proj_start as usize);
        if pj.kind != ir::PJ_FIELD {
            return UNI_NONE;
        }
        if pj.data != ir::IR_NONE {
            // A positional member keys by its index.
            if pj.data < cnt {
                return pj.data;
            }
            return UNI_NONE;
        }
        let mut d = DefId { module: 0, node: NODE_NONE };
        let _ = self.bc_uni_local_members(body, pl.base, &mut d);
        let ms = unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.aggregate.members;
        for j in 0..ms.len {
            if unsafe (*self.mod_ast(d.module)).list(ms)[j as usize] == pj.sub {
                return j;
            }
        }
        return UNI_NONE;
    }

    // The regions of each member of a struct or tuple type node `tyn` of module `m` in a place walk's
    // frame (see `bc_uni_frame_lt`) into `u.sm`, two words each (own level, behind a reference).
    // False, with `u.sm` empty, for any other type or when a member's regions are unknown.
    fn bc_uni_members(self: &Self, u: &mut UniSt, m: ModuleId, decl: NodeId, tyn: NodeId) bool {
        u.sm.truncate(0);
        if tyn == NODE_NONE {
            return false;
        }
        let a = self.mod_ast(m);
        let n = *unsafe (*a).at_const(tyn);
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let es = n.as_data.array_literal.elements;
            for i in 0..es.len {
                u.m0 = 0;
                u.m1 = 0;
                if !self.bc_uni_frame_type(u, m, decl, unsafe (*a).list(es)[i as usize], false, 0) {
                    u.sm.truncate(0);
                    return false;
                }
                u.sm.push(u.m0);
                u.sm.push(u.m1);
            }
            return true;
        }
        let mut ptn = tyn;
        if decl == NODE_NONE && n.kind == NodeKind::NODE_TYPE_PATH && self.tc_path_is_self(m, tyn) {
            // `Self` names the extend's target type.
            let ext = self.enclosing(m, self.icx.current_fn, NodeKind::NODE_EXTEND);
            if ext == NODE_NONE {
                return false;
            }
            ptn = unsafe (*a).at_const(ext).as_data.extend_def.target_type;
        }
        let d = self.bc_uni_enter(u, m, decl, ptn);
        if d.node == NODE_NONE {
            return false;
        }
        let da = self.mod_ast(d.module);
        let dn = *unsafe (*da).at_const(d.node);
        if dn.as_data.aggregate.is_union || dn.as_data.aggregate.members.len > UNI_MEMBERS_MAX {
            return false;
        }
        let ms = dn.as_data.aggregate.members;
        for j in 0..ms.len {
            let fd = unsafe (*da).list(ms)[j as usize];
            u.m0 = 0;
            u.m1 = 0;
            if unsafe (*da).at_const(fd).kind != NodeKind::NODE_FIELD || !self.bc_uni_frame_type(
                u,
                d.module,
                d.node,
                unsafe (*da).at_const(fd).as_data.field.ty,
                false,
                0,
            ) {
                u.sm.truncate(0);
                return false;
            }
            u.sm.push(u.m0);
            u.sm.push(u.m1);
        }
        return true;
    }

    // Enter the struct that type path `tyn` of module `m` names in frame `decl`: `u.fa` becomes the
    // struct's lifetime parameters, in order, mapped to the regions of the path's lifetime
    // arguments. The struct, or NODE_NONE when the path names no struct or a region is unknown.
    fn bc_uni_enter(self: &Self, u: &mut UniSt, m: ModuleId, decl: NodeId, tyn: NodeId) DefId {
        let none = DefId { module: 0, node: NODE_NONE };
        let n = *unsafe (*self.mod_ast(m)).at_const(tyn);
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return none;
        }
        let d = unsafe (*self.mod_ast(m)).path_def(tyn);
        if d.node == NODE_NONE || unsafe (*self.mod_ast(d.module)).at_const(d.node).kind != NodeKind::NODE_STRUCT {
            return none;
        }
        let nlt = unsafe (*self.mod_ast(d.module)).lifetimes_of(d.node).len;
        if nlt > UNI_FRAME_MAX {
            return none;
        }
        u.fb.truncate(0);
        let args = n.as_data.type_path.args;
        for j in 0..args.len {
            let aid = unsafe (*self.mod_ast(m)).list(args)[j as usize];
            if unsafe (*self.mod_ast(m)).at_const(aid).kind == NodeKind::NODE_LIFETIME && u.fb.len() < nlt as usize {
                let r = self.bc_uni_frame_lt(u, m, decl, aid, tyn, u.fb.len() as u32);
                u.fb.push(r);
            }
        }
        while u.fb.len() < nlt as usize {
            let r = self.bc_uni_frame_lt(u, m, decl, NODE_NONE, tyn, u.fb.len() as u32);
            u.fb.push(r);
        }
        for j in 0..u.fb.len() {
            if u.fb[j] == 0 {
                return none;
            }
        }
        let nf = replace(&mut u.fb, Vector::<u64>::new());
        u.fb = replace(&mut u.fa, nf);
        return d;
    }

    // The block of `point` (the operation at it is statement `*si`, the terminator past the last).
    fn bc_uni_site(self: &Self, f: &bfx::BodyFacts, point: u32, si: &mut u32) usize {
        let mut lo: usize = 0;
        let mut hi = f.block_base.len();
        while hi - lo > 1 {
            let mid = (lo + hi) / 2;
            if f.block_base[mid] <= point {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        *si = (point - f.block_base[lo]) / 2;
        return lo;
    }

    // The operands the operation at `point` reads into its result: an oper_pool range `start`,
    // `len` (true), or the single operand `start` (false).
    fn bc_uni_ops(self: &Self, body: &ir::CoreBody, f: &bfx::BodyFacts, point: u32, start: &mut u32, len: &mut u32) bool {
        let mut si: u32 = 0;
        let blk = *body.blocks.at(self.bc_uni_site(f, point, &mut si));
        *start = 0;
        *len = 0;
        if si < blk.stmt_len {
            let st = *body.statements.at((blk.stmt_start + si) as usize);
            let rv = *body.rvalues.at(st.rvalue as usize);
            if st.kind == ir::ST_ASSIGN && (rv.kind == ir::RV_USE || rv.kind == ir::RV_CAST || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_DYN || rv.kind == ir::RV_REPEAT) {
                *start = rv.a;
                *len = 1;
                return false;
            } else if st.kind == ir::ST_ASSIGN && (rv.kind == ir::RV_AGGREGATE || rv.kind == ir::RV_CLOSURE) {
                *start = rv.a;
                *len = rv.b;
            }
        } else if blk.term.kind == ir::TM_CALL {
            *start = blk.term.args_start;
            *len = blk.term.args_len;
        }
        return true;
    }

    // The regions parameter `ai`'s local passes on at `point`: the regions of each place of it the
    // operation there reads, from the signature (`bc_uni_place`). Returns those read through a
    // dereference (their level is unknown past it), leaves the others in `u.m0` and `u.m1` at the
    // value's own level and behind a reference, and falls back to the parameter's regions when a
    // read is of the whole local, a place walk fails, or the operation borrows the place.
    fn bc_uni_edge(self: &Self, u: &mut UniSt, body: &ir::CoreBody, f: &bfx::BodyFacts, ai: u32, point: u32) u64 {
        let l = body.returns + ai;
        let mut ops_start: u32 = 0;
        let mut ops_len: u32 = 0;
        let pool = self.bc_uni_ops(body, f, point, &mut ops_start, &mut ops_len);
        let a0 = u.arg[ai as usize * 2];
        let a1 = u.arg[ai as usize * 2 + 1];
        let mut m0: u64 = 0;
        let mut m1: u64 = 0;
        let mut ma: u64 = 0;
        let mut hit = false;
        for k in 0..ops_len {
            let oi = if pool {
                body.oper_pool[(ops_start + k) as usize];
            } else {
                ops_start;
            };
            if oi == ir::IR_NONE {
                continue;
            }
            let op = *body.operands.at(oi as usize);
            if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE || body.places.at(op.data as usize).base != l {
                continue;
            }
            hit = true;
            let a = self.cur_ast();
            let params = unsafe (*a).at_const(body.owner.node).as_data.function.params;
            let ptn = unsafe (*a).slot_type_node(unsafe (*a).list(params)[ai as usize]);
            if !self.bc_uni_place(u, body, ptn, op.data) {
                m0 = a0;
                m1 = a1;
                ma = 0;
                break;
            }
            if body.place_has_deref(op.data) {
                ma = ma | u.m0 | u.m1;
            } else {
                m0 = m0 | u.m0;
                m1 = m1 | u.m1;
            }
        }
        if !hit {
            m0 = a0;
            m1 = a1;
            ma = 0;
        }
        u.m0 = m0;
        u.m1 = m1;
        return ma;
    }

    // The regions of the value at `place`, a projection of the local of the parameter typed `ptn`,
    // into `u.m0` (its own level) and `u.m1` (behind a reference): the signature's type, then each
    // dereference's pointee, each slice or array element's type and each field's declared type with
    // the struct's lifetime parameters mapped to the regions of the path's lifetime arguments. False
    // when a step leaves what the signature spells: another index, a variant, a tuple member, a type
    // parameter's field.
    fn bc_uni_place(self: &Self, u: &mut UniSt, body: &ir::CoreBody, ptn: NodeId, place: ir::PlaceId) bool {
        let pl = *body.places.at(place as usize);
        let mut m = self.cur_module();
        let mut decl = NODE_NONE;
        let mut tyn = ptn;
        for k in 0..pl.proj_len {
            let pj = *body.projections.at((pl.proj_start + k) as usize);
            if tyn == NODE_NONE {
                return false;
            }
            if decl == NODE_NONE && unsafe (*self.mod_ast(m)).at_const(tyn).kind == NodeKind::NODE_TYPE_PATH && self.tc_path_is_self(
                m,
                tyn,
            ) {
                let ext = self.enclosing(m, self.icx.current_fn, NodeKind::NODE_EXTEND);
                if ext == NODE_NONE {
                    return false;
                }
                tyn = unsafe (*self.mod_ast(m)).at_const(ext).as_data.extend_def.target_type;
            }
            let n = *unsafe (*self.mod_ast(m)).at_const(tyn);
            if pj.kind == ir::PJ_DEREF && n.kind == NodeKind::NODE_REFERENCE_TYPE {
                tyn = n.as_data.indirect_type.ty;
                continue;
            }
            // An element of a slice or an array has the element type's regions.
            if (pj.kind == ir::PJ_INDEX_OP || pj.kind == ir::PJ_INDEX_CONST) && n.kind == NodeKind::NODE_SLICE_TYPE {
                tyn = n.as_data.indirect_type.ty;
                continue;
            }
            if (pj.kind == ir::PJ_INDEX_OP || pj.kind == ir::PJ_INDEX_CONST) && n.kind == NodeKind::NODE_ARRAY_TYPE {
                tyn = n.as_data.array_type.element;
                continue;
            }
            if pj.kind != ir::PJ_FIELD || pj.sub == NODE_NONE {
                return false;
            }
            let d = self.bc_uni_enter(u, m, decl, tyn);
            if d.node == NODE_NONE {
                return false;
            }
            let da = self.mod_ast(d.module);
            if unsafe (*da).at_const(pj.sub).kind != NodeKind::NODE_FIELD {
                return false;
            }
            let mems = unsafe (*da).at_const(d.node).as_data.aggregate.members;
            let mut member = false;
            for j in 0..mems.len {
                if unsafe (*da).list(mems)[j as usize] == pj.sub {
                    member = true;
                }
            }
            if !member {
                return false;
            }
            m = d.module;
            decl = d.node;
            tyn = unsafe (*da).at_const(pj.sub).as_data.field.ty;
        }
        u.pm = m;
        u.pdecl = decl;
        u.ptyn = tyn;
        u.m0 = 0;
        u.m1 = 0;
        return self.bc_uni_frame_type(u, m, decl, tyn, false, 0);
    }

    // The region (one bit) lifetime node `lt` of module `m` denotes in a place walk's frame: the
    // signature's names and elided input positions (slot `slot` of type node `at`) when `decl` is
    // NODE_NONE, else struct `decl`'s lifetime parameters through `u.fa`. 0 when unknown.
    fn bc_uni_frame_lt(self: &Self, u: &UniSt, m: ModuleId, decl: NodeId, lt: NodeId, at: NodeId, slot: u32) u64 {
        if lt == NODE_NONE {
            if decl != NODE_NONE {
                return 0;
            }
            let key = at as u64 << 8 | slot as u64;
            let mut i: usize = 0;
            while i + 1 < u.pos.len() {
                if u.pos[i] == key {
                    return 1u64 << u.pos[i + 1];
                }
                i += 2;
            }
            return 0;
        }
        let nm = self.tc_lt_name_in(m, lt);
        if tc::span_is(self.mod_src(m), nm, "'static") {
            return 1;
        }
        if decl == NODE_NONE {
            for i in 1..u.names.len() {
                if tc::spans_eq2(self.source, u.names[i], self.source, nm) {
                    return 1u64 << i as u64;
                }
            }
            return 0;
        }
        let lts = unsafe (*self.mod_ast(m)).lifetimes_of(decl);
        for k in 0..lts.len {
            if k as usize < u.fa.len() && tc::spans_eq2(
                self.mod_src(m),
                self.tc_lt_name_in(m, unsafe (*self.mod_ast(m)).list(lts)[k as usize]),
                self.mod_src(m),
                nm,
            ) {
                return u.fa[k as usize];
            }
        }
        return 0;
    }

    // The regions of type node `tyn` of module `m` in a place walk's frame (see `bc_uni_frame_lt`),
    // added to `u.m0` or, behind a reference, to `u.m1`. False when a lifetime is unknown or a type
    // parameter of the frame's struct stands in for a type.
    fn bc_uni_frame_type(self: &Self, u: &mut UniSt, m: ModuleId, decl: NodeId, tyn: NodeId, behind: bool, depth: i32) bool {
        if tyn == NODE_NONE || depth > 6 {
            return false;
        }
        let a = self.mod_ast(m);
        let n = *unsafe (*a).at_const(tyn);
        if n.kind == NodeKind::NODE_REFERENCE_TYPE || n.kind == NodeKind::NODE_SLICE_TYPE {
            let r = self.bc_uni_frame_lt(u, m, decl, n.as_data.indirect_type.lifetime, tyn, 0);
            if r == 0 {
                return false;
            }
            if behind {
                u.m1 = u.m1 | r;
            } else {
                u.m0 = u.m0 | r;
            }
            return self.bc_uni_frame_type(u, m, decl, n.as_data.indirect_type.ty, true, depth + 1);
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            return self.bc_uni_frame_type(u, m, decl, n.as_data.array_type.element, behind, depth + 1);
        }
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let es = n.as_data.array_literal.elements;
            for i in 0..es.len {
                if !self.bc_uni_frame_type(u, m, decl, unsafe (*a).list(es)[i as usize], behind, depth + 1) {
                    return false;
                }
            }
            return true;
        }
        if n.kind == NodeKind::NODE_POINTER_TYPE {
            return true;
        }
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return false;
        }
        if self.tc_path_is_self(m, tyn) {
            if decl != NODE_NONE {
                return false;
            }
            let ext = self.enclosing(m, self.icx.current_fn, NodeKind::NODE_EXTEND);
            if ext == NODE_NONE {
                return false;
            }
            return self.bc_uni_frame_type(
                u,
                m,
                decl,
                unsafe (*a).at_const(ext).as_data.extend_def.target_type,
                behind,
                depth + 1,
            );
        }
        let d = unsafe (*a).path_def(tyn);
        if d.node == NODE_NONE {
            // A builtin type.
            return n.as_data.type_path.args.len == 0;
        }
        if unsafe (*self.mod_ast(d.module)).at_const(d.node).kind == NodeKind::NODE_GENERIC_PARAM {
            // The signature's own type parameters hold no region it names.
            return decl == NODE_NONE;
        }
        let args = n.as_data.type_path.args;
        let mut named: u32 = 0;
        for i in 0..args.len {
            let aid = unsafe (*a).list(args)[i as usize];
            if unsafe (*a).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                let r = self.bc_uni_frame_lt(u, m, decl, aid, tyn, named);
                named += 1;
                if r == 0 {
                    return false;
                }
                if behind {
                    u.m1 = u.m1 | r;
                } else {
                    u.m0 = u.m0 | r;
                }
            } else if !self.bc_uni_frame_type(u, m, decl, aid, behind, depth + 1) {
                return false;
            }
        }
        let nlt = unsafe (*self.mod_ast(d.module)).lifetimes_of(d.node).len;
        for k in named..nlt {
            let r = self.bc_uni_frame_lt(u, m, decl, NODE_NONE, tyn, k);
            if r == 0 {
                return false;
            }
            if behind {
                u.m1 = u.m1 | r;
            } else {
                u.m0 = u.m0 | r;
            }
        }
        return true;
    }

    // The region lifetime node `lt` of the current module denotes. An elided position (NODE_NONE,
    // slot `slot` of type node `at`) takes `elide`: a fresh anonymous region for UNI_NONE (an input,
    // recorded for the place walks), none for UNI_UNSOURCED.
    fn bc_uni_region(self: &Self, u: &mut UniSt, lt: NodeId, elide: u32, at: NodeId, slot: u32) u32 {
        let mut r = elide;
        if lt != NODE_NONE {
            let nm = self.tc_lt_name(lt);
            r = UNI_NONE;
            if tc::span_is(self.source, nm, "'static") {
                r = 0;
            }
            for i in 1..u.names.len() {
                if r == UNI_NONE && tc::spans_eq2(self.source, u.names[i], self.source, nm) {
                    r = i as u32;
                }
            }
            if r == UNI_NONE {
                r = u.fresh(nm);
            }
        } else if elide == UNI_NONE {
            r = u.fresh(tok::Span { start: 0, end: 0 });
            if r != UNI_NONE {
                u.pos.push(at as u64 << 8 | slot as u64);
                u.pos.push(r);
            }
        } else if elide == UNI_UNSOURCED {
            r = UNI_NONE;
        }
        if u.first == UNI_NONE {
            u.first = r;
        }
        return r;
    }

    // The regions of signature type node `tyn` (current module), added to `u.m0` at the value's own
    // level or to `u.m1` behind a reference; `elide` as in `bc_uni_region`. A reference or slice
    // records the bounds it implies: every region behind it outlives its own. Returns every region
    // found.
    fn bc_uni_type(self: &Self, u: &mut UniSt, tyn: NodeId, behind: bool, elide: u32, depth: i32) u64 {
        if tyn == NODE_NONE || depth > 6 {
            return 0;
        }
        let a = self.cur_ast();
        let n = *unsafe (*a).at_const(tyn);
        if n.kind == NodeKind::NODE_REFERENCE_TYPE || n.kind == NodeKind::NODE_SLICE_TYPE {
            let r = self.bc_uni_region(u, n.as_data.indirect_type.lifetime, elide, tyn, 0);
            let inner = self.bc_uni_type(u, n.as_data.indirect_type.ty, true, elide, depth + 1);
            if r == UNI_NONE {
                return inner;
            }
            for x in 0..u.names.len() {
                if (inner >> x as u64 & 1u64) != 0 {
                    u.ol.set(x, u.ol[x] | 1u64 << r as u64);
                }
            }
            u.mark(r, behind);
            return inner | 1u64 << r as u64;
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            return self.bc_uni_type(u, n.as_data.array_type.element, behind, elide, depth + 1);
        }
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let mut m: u64 = 0;
            let es = n.as_data.array_literal.elements;
            for i in 0..es.len {
                m = m | self.bc_uni_type(u, unsafe (*a).list(es)[i as usize], behind, elide, depth + 1);
            }
            return m;
        }
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return 0;
        }
        if self.tc_path_is_self(self.cur_module(), tyn) {
            // `Self` names the lifetimes its extend's target type spells.
            let ext = self.enclosing(self.cur_module(), self.icx.current_fn, NodeKind::NODE_EXTEND);
            if ext == NODE_NONE {
                return 0;
            }
            return self.bc_uni_type(
                u,
                unsafe (*a).at_const(ext).as_data.extend_def.target_type,
                behind,
                elide,
                depth + 1,
            );
        }
        let d = unsafe (*a).path_def(tyn);
        if d.node == NODE_NONE || unsafe (*self.mod_ast(d.module)).at_const(d.node).kind == NodeKind::NODE_GENERIC_PARAM {
            return 0;
        }
        let mut m: u64 = 0;
        let mut named: u32 = 0;
        let args = n.as_data.type_path.args;
        for i in 0..args.len {
            let aid = unsafe (*a).list(args)[i as usize];
            if unsafe (*a).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                named += 1;
                let r = self.bc_uni_region(u, aid, elide, tyn, named - 1);
                if r != UNI_NONE {
                    u.mark(r, behind);
                    m = m | 1u64 << r as u64;
                }
            } else {
                m = m | self.bc_uni_type(u, aid, behind, elide, depth + 1);
            }
        }
        // Lifetime parameters the path leaves unwritten are elided positions.
        let nlt = unsafe (*self.mod_ast(d.module)).lifetimes_of(d.node).len;
        for k in named..nlt {
            let r = self.bc_uni_region(u, NODE_NONE, elide, tyn, k);
            if r != UNI_NONE {
                u.mark(r, behind);
                m = m | 1u64 << r as u64;
            }
        }
        return m;
    }

    // A local-storage borrow reaching a placeholder escapes through the returned value when a
    // return carries it, else through a store into storage a parameter reaches.
    fn bc_ir_escape(
        self: &mut Self,
        body: &ir::CoreBody,
        f: &bfx::BodyFacts,
        sv: &bln::Solver,
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
            let msg = if sv.origin_reaches(lo.origin, 0) {
                format("borrowed value does not live long enough: this argument must satisfy 'static");
            } else {
                format(
                    "borrowed value does not live long enough: it is stored into caller-visible data whose lifetime it is not declared to outlive",
                );
            };
            self.bc_ir_push(out, seen, CAT_ESCAPE, er.span, msg);
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
            if cat == CAT_MOVED_PARAM {
                self.errors.note_at(
                    di,
                    format(
                        "a value of a type parameter moves on every use: add a 'Copy' bound to the parameter to copy it, or borrow it",
                    ),
                );
            }
            if cat == CAT_U_RET {
                self.errors.note_at(
                    di,
                    format(
                        "declare the relationship in the signature, e.g. add `'b: 'a` where the argument's lifetime must outlive the return",
                    ),
                );
            }
            if cat == CAT_U_STORE {
                self.errors.note_at(
                    di,
                    format(
                        "tie the lifetimes with a shared parameter, e.g. `fn f<'a>(dst: &mut Vector<&'a T>, src: &'a T)`",
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
