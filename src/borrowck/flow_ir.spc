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
import ir::tailcall as irt;
import ir::recursion as recur;
import ir::inline as inl;
import ir::print as irp;
import ir::verify as irv;
import emit::probe as prb;
import utils::errors as diag;

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
// The package's coroutine and cancellation reachability (once); in the driver's stage, the whole
// per-module prologue: the module reference rows, the body counts and the scans.
pub const BP_REACH: usize = 12;
pub const BP_DROPS: usize = 13; // drop elaboration of the kept bodies (schedule and rewrite)
pub const BP_PUBLISH: usize = 14; // the type publication before the stage
pub const BP_KEEP: usize = 15; // the keep: its reservation, the kept copies and their absorption
pub const BP_TAIL: usize = 16; // tail-call conversion of the kept bodies
const BP_NAMES: [str<'static>; 17] = [
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
    "publish",
    "keep",
    "tail",
];
static_assert(BP_TAIL + 1 == 17, "one name per borrow region");
static_assert(BP_TAIL < prb::P_COUNT, "the borrow regions fit the probe");

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
    const fn top_insert(self: &mut Self, ns: u64, id: u64, sz: u64) {
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
    pub const fn tally_ir(self: &mut Self, lw: &irl::Lowerer) {
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
/// The most lifetime positions the check keeps apart in one value: a value of a type with more is
/// one opaque position.
const UNI_SLOTS_MAX: u32 = 64;
/// Position keys (`bc_uni_walk`): a named lifetime is its token (bit 63, `Owner::lt_tok`), every
/// other key carries a kind bit.
const UK_GEN: u64 = 1u64 << 62; // a type parameter, | module << 32 | node; the aux's low 16 bits: the position in it
const UK_EL: u64 = 1u64 << 61; // an elided lifetime, | type node << 8 | its slot
const UK_STATIC: u64 = 1u64 << 60;
const UK_OPQ: u64 = 1u64 << 59; // an opaque position: an erased object, a function type
const UK_TY: u64 = 1u64 << 58; // a function-pointer signature's opaque position, | its type
const UK_ANY: u64 = 1u64 << 57; // a called object's captures: they may reach every output position
/// Aux bit of a position behind a reference; the aux's high word is the node the key was read from.
const UA_BEHIND: u64 = 1u64 << 16;
/// Aux bits of a function pointer's slot: its lifetime appears in a result (covariant), in a parameter
/// (contravariant); both: invariant.
const UA_CO: u64 = 1u64 << 17;
const UA_CONTRA: u64 = 1u64 << 18;
/// A position no slot holds (behind a raw pointer), and one of `'static` data.
const POS_NONE: u32 = 0xFFFFFFFF;
const POS_STATIC: u32 = 0xFFFFFFFE;
/// `UniSt::emap` of an edge not mapped yet, and of one mapping every source slot to every target slot.
const EM_NONE: u64 = 0xFFFFFFFFFFFFFFFF;
const EM_COARSE: u64 = 0xFFFFFFFFFFFFFFFE;

/// Scratch of the universal-region check (`bc_ir_universal`), kept across bodies. Region 0 is
/// `'static`; every other region is a lifetime the signature names or an elided input position. A
/// slot is one lifetime position of an origin's value (`bc_uni_len`).
pub struct UniSt {
    pub names: Vector<tok::Span>, // per region: its name, empty for an elided input position
    pub ol: Vector<u64>, // per region: the regions it is known to outlive
    pub pos: Vector<u64>, // pairs: an elided input position (type node << 8 | slot), its region
    pub base: Vector<u32>, // per origin: its first slot
    pub cnt: Vector<u32>, // per origin: its slot count
    pub opq: Vector<bool>, // per origin: one slot for the whole value (no local, or positions unknown)
    pub st: Vector<u64>, // per slot: the regions arrived there
    pub sk: Vector<u64>, // per slot of a parameter or a return slot: the regions it is declared to hold
    pub cv: Vector<bool>, // per slot: a parameter's position behind a reference or a view, in caller storage
    pub gen: Vector<bool>, // per slot: a parameter's or return slot's type parameter position
    pub vr: Vector<u8>, // per slot of a parameter or return slot: its variance (UA_CO, UA_CONTRA bits >> 17; 0: covariant)
    pub phl: Vector<u32>, // per universal origin: the parameter local it stands for, or BF_NONE
    pub emap: Vector<u64>, // per subset edge: EM_*, or its slot pairs (start << 32 | count in `pairs`)
    pub pairs: Vector<u64>, // source slot << 32 | target slot
    pub keys: Vector<u64>, // a walk's (key, aux) pairs
    pub bind: Vector<u64>, // a call's argument positions: (key, aux, slot) triples
    pub ka: Vector<u64>, // a call's keys per argument and result (`bc_uni_call_keys`)
    pub kof: Vector<u32>,
    pub wargs: Vector<TypeId>, // a field walk's declaration arguments (`bc_uni_walk`)
    pub wdecl: DefId,
    pub pa: Vector<u32>, // position scratch
    pub pb: Vector<u32>,
    pub pc: Vector<u32>,
    pub toks: Vector<u64>,
    pub start: Vector<u32>, // per origin (+1): CSR into `edges` of the subset edges leaving it
    pub edges: Vector<u32>,
    pub queue: Vector<u32>,
    pub queued: Vector<bool>,
    pub first: u32, // the first region of the parameter being walked
    pub m0: u64, // a signature walk's regions at the value's own level
    pub m1: u64, // a signature walk's regions behind a reference
    pub look: bool, // a signature walk looks its regions up: it creates none
    pub over: bool, // the signature has more than UNI_MAX regions
}

extend UniSt {
    /// Empty scratch with no heap storage.
    pub fn new() UniSt {
        return UniSt {
            names: Vector::<tok::Span>::new(),
            ol: Vector::<u64>::new(),
            pos: Vector::<u64>::new(),
            base: Vector::<u32>::new(),
            cnt: Vector::<u32>::new(),
            opq: Vector::<bool>::new(),
            st: Vector::<u64>::new(),
            sk: Vector::<u64>::new(),
            cv: Vector::<bool>::new(),
            gen: Vector::<bool>::new(),
            vr: Vector::<u8>::new(),
            phl: Vector::<u32>::new(),
            emap: Vector::<u64>::new(),
            pairs: Vector::<u64>::new(),
            keys: Vector::<u64>::new(),
            bind: Vector::<u64>::new(),
            ka: Vector::<u64>::new(),
            kof: Vector::<u32>::new(),
            wargs: Vector::<TypeId>::new(),
            wdecl: DefId { module: 0, node: NODE_NONE },
            pa: Vector::<u32>::new(),
            pb: Vector::<u32>::new(),
            pc: Vector::<u32>::new(),
            toks: Vector::<u64>::new(),
            start: Vector::<u32>::new(),
            edges: Vector::<u32>::new(),
            queue: Vector::<u32>::new(),
            queued: Vector::<bool>::new(),
            first: UNI_NONE,
            m0: 0,
            m1: 0,
            look: false,
            over: false,
        };
    }

    /// Heap bytes kept across bodies (capacity, not length).
    pub const fn scratch_bytes(self: &Self) u64 {
        let words = self.ol.capacity() + self.pos.capacity() + self.st.capacity() + self.sk.capacity() + self.emap.capacity() + self.pairs.capacity() + self.keys.capacity() + self.bind.capacity() + self.ka.capacity() + self.toks.capacity();
        let halves = self.kof.capacity() + self.base.capacity() + self.cnt.capacity() + self.phl.capacity() + self.wargs.capacity() + self.pa.capacity() + self.pb.capacity() + self.pc.capacity() + self.start.capacity() + self.edges.capacity() + self.queue.capacity();
        return (self.names.capacity() * sizeof(tok::Span) + words * sizeof(u64) + halves * sizeof(u32) + self.opq.capacity() + self.cv.capacity() + self.gen.capacity() + self.vr.capacity() + self.queued.capacity()) as u64;
    }

    // Add region `r` to the walk's regions at the value's own level, or behind a reference.
    const fn mark(self: &mut Self, r: u32, behind: bool) {
        if behind {
            self.m1 = self.m1 | 1u64 << r as u64;
        } else {
            self.m0 = self.m0 | 1u64 << r as u64;
        }
    }

    // Does a region of `rs` not outlive every region of `s`? A value at a position whose region is
    // unknown among several may sit at any of them.
    const fn fails(self: &Self, rs: u64, s: u64) bool {
        if rs == 0 || s == 0 {
            return false;
        }
        for r in 0..self.names.len() {
            if (rs >> r as u64 & 1u64) != 0 && (self.ol[r] & s) != s {
                return true;
            }
        }
        return false;
    }

    // Append slot pair `src` -> `dst` unless one is no slot.
    fn pair(self: &mut Self, src: u32, dst: u32) {
        if src < POS_STATIC && dst < POS_STATIC {
            self.pairs.push(src as u64 << 32 | dst as u64);
        }
    }

    // Does a region of `rs` arriving at slot `s` break the slot's declared regions by its variance:
    // covariant, it must outlive them; contravariant, they must outlive it; invariant, both?
    const fn fails_at(self: &Self, rs: u64, s: usize) bool {
        let v = self.vr[s];
        let sk = self.sk[s];
        if v != 1 && self.fails(rs, sk) {
            return true;
        }
        if v == 0 || rs == 0 || sk == 0 {
            return false;
        }
        for r in 0..self.names.len() {
            if (sk >> r as u64 & 1u64) != 0 && (self.ol[r] & rs) != rs {
                return true;
            }
        }
        return false;
    }

    // The regions of `rs` that slot `s` must check: at a type parameter's position, those its bounds
    // name come with any value of the type.
    const fn typed(self: &Self, rs: u64, s: usize) u64 {
        if self.gen[s] {
            return rs & ~self.sk[s];
        }
        return rs;
    }

    // The regions at the slots of origin `o`.
    const fn all(self: &Self, o: u32) u64 {
        let mut rs: u64 = 0;
        for i in 0..self.cnt[o as usize] {
            rs = rs | self.st[(self.base[o as usize] + i) as usize];
        }
        return rs;
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
    /// The language server's summarizer (null = none): the body of every function checked is
    /// summarized for the unbounded-recursion check (`ir::recursion`).
    pub recur: *mut recur::Summarizer,
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
            recur: null,
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
        } else if k > ir::RV_SIMD {
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
    // A destruction observes what its local stores only where the local may still hold a value: the
    // move/init solution decides each recorded one before liveness reads the rows.
    if ctx.facts.drop_uses.len() != 0 {
        if mv_need {
            ctx.ensure_cfg(body);
            ctx.ensure_moves(body);
            ow.mark_covered(body.module, &mut ctx.forest);
        }
        for i in 0..ctx.facts.drop_uses.len() {
            let du = *ctx.facts.drop_uses.at(i);
            let runs = !mv_need || ctx.moves.holds_at(&ctx.forest, &ctx.facts, du.block, du.point, du.path);
            ctx.facts.drop_use(i, runs);
        }
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
// operation (a reference, a carrying projected copy or view, a closure capture, a `&mut` or
// `[]mut T` reborrowed into a literal or a field, or a call's implicit autoref), every conflict
// names a loan and a place of the body, and each fixpoint queue stayed within its monotone bound
// (every push after the seeds follows a row change, and a row changes at most once per lattice bit).
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
                rk == ir::RV_REF || rk == ir::RV_USE || rk == ir::RV_SLICE || rk == ir::RV_CLOSURE || rk == ir::RV_AGGREGATE,
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
    body.inline_size_ok = inl::callee_size_ok(body, ow.pkg);
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

// Bit `k` of a capture mask; past the 64th capture, every bit.
const fn bit_or_all(k: u32) u64 {
    if k >= 64 {
        return 0xFFFFFFFFFFFFFFFFu64;
    }
    return 1u64 << k as u64;
}

extend tc::TypeChecker {
    // A body the lowering cannot express is a hard error (no body may go unchecked, and no other
    // checker exists): reported at the failing construct with the lowerer's reason slug.
    fn bc_lower_err(self: &mut Self, lw: &irl::Lowerer, owner: NodeId) {
        // Under `--bootstrap-tags` a body that calls an intrinsic this compiler does not know goes
        // unchecked: the newer compiler checks it, and an emission of it fails.
        if lw.err == irl::UNKNOWN_INTRINSIC_SLUG && unsafe (*self.package).bootstrap {
            return;
        }
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
                    if idx >= 0 && !self.tc_value_owns(
                        unsafe (*self.cur_ast()).type_of(
                            unsafe (*self.cur_ast()).list(unsafe (*self.cur_ast()).at_const(c).as_data.closure.captures)[idx as usize],
                        ),
                    ) {
                        let old = (unsafe (*self.cur_ast()).at(c).as_data.closure.mut_caps) as u64;
                        unsafe (*self.cur_ast()).at(c).as_data.closure.mut_caps = (old | 1u64 << idx as u64) as u32;
                        let cf = unsafe (*self.cur_ast()).closure_fact(c);
                        assert(cf != null, "every checked closure has recorded facts");
                        let rc = unsafe (*cf).ref_caps;
                        let _ = unsafe (*self.cur_ast()).set_closure_caps(c, old | 1u64 << idx as u64, rc);
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
        // Children first, in source order: a closure's body is checked before every body that can
        // call it, so that call stores its arguments where the body does (`Owner::cap_reach`).
        // A function without closures, nearly every one, has the one body and needs no order.
        let n = bodies.len();
        let mut order = Vector::<usize>::new();
        if n > 1 {
            order.reserve(n);
            let mut done = Vector::<bool>::new();
            done.resize_default(n);
            let mut stack = Vector::<u64>::new(); // body << 32 | its next child
            for r in 0..n {
                if done[r] {
                    continue;
                }
                done.set(r, true);
                stack.push(r as u64 << 32);
                // Each body is pushed once and each push advances once per child.
                while stack.len() != 0 {
                    let top = stack[stack.len() - 1];
                    let b = (top >> 32) as usize;
                    let c = (top & 0xFFFFFFFFu64) as usize;
                    if c == bodies.at(b).closures.len() {
                        stack.truncate(stack.len() - 1);
                        order.push(b);
                        continue;
                    }
                    stack.set(stack.len() - 1, top + 1);
                    let cn = bodies.at(b).closures[c];
                    for cb in 0..n {
                        if !done[cb] && bodies.at(cb).body.owner.node == cn {
                            done.set(cb, true);
                            stack.push(cb as u64 << 32);
                            break;
                        }
                    }
                }
            }
        }
        // The calls of the function to itself, converted or not: `@tail_recurse` requires one.
        let mut selfs: u32 = 0;
        let mut clean = true;
        // Without a keep (the language server) the bodies are elaborated and their self calls
        // converted only under `@tail_recurse`, for its errors.
        let f = self.icx.current_fn;
        let tagged = unsafe (*self.cur_ast()).attr_of(f, AttrKind::ATTR_TAIL_RECURSE) != null;
        let convert = ctx.keep != null || tagged;
        for oi in 0..n {
            let b = if n > 1 {
                order[oi];
            } else {
                0usize;
            };
            if ctx.st.pr.on {
                ctx.st.tally_ir(bodies.at(b));
            }
            let n0 = out.len();
            let td = ctx.st.pr.start();
            self.bc_gen_sigs(ow, &bodies.at(b).body);
            ctx.st.pr.stop(BP_DECL, td);
            self.bc_ir_body(ow, &bodies.at(b).body, ctx, &mut seen, out);
            if convert {
                // A rejected body never reaches emission, and its elaboration has no correct
                // schedule to verify (a field moved out of a `Free` value cannot be released).
                let rejected = self.errors.errors.len() != self.err_wm || out.len() != n0 || ctx.moves.errs.len() != 0 || ctx.solver.errs.len() != 0;
                bc_elaborate(ow, ctx, &mut bodies.index_mut(b).body, !rejected);
                clean = clean && !rejected;
                if !rejected {
                    let tt = ctx.st.pr.start();
                    selfs += self.bc_tail_calls(ow, ctx, &mut bodies.index_mut(b).body);
                    ctx.st.pr.stop(BP_TAIL, tt);
                }
            }
            ctx.trim_scratch();
        }
        if tagged && clean && selfs == 0 {
            let nm = unsafe (*self.cur_ast()).at_const(unsafe (*self.cur_ast()).at_const(f).as_data.function.name).span;
            self.errors.emit_span(
                nm,
                format(
                    "'@tail_recurse' function '{}' never calls itself",
                    diag::span_str(self.source, nm.start, nm.end),
                ),
            );
        }
    }

    // The tail calls of elaborated body `body` of the function under check (`ir::tailcall`): its
    // calls to itself become jumps where they can; under `@tail_recurse` each one that cannot is an
    // error with the reason, and so is a call to it from a closure of it. The calls seen.
    fn bc_tail_calls(self: &mut Self, ow: &mut bfx::Owner, ctx: &mut BorrowCtx, body: &mut ir::CoreBody) u32 {
        let f = self.icx.current_fn;
        let m = self.cur_module();
        let tagged = unsafe (*self.cur_ast()).attr_of(f, AttrKind::ATTR_TAIL_RECURSE) != null;
        if body.owner.node != f {
            // A closure of the function: a call of the function runs in a frame of its own.
            let mut seen: u32 = 0;
            for bi in 0..body.blocks.len() {
                let t = body.blocks.at(bi).term;
                if t.kind == ir::TM_CALL && t.callee.node == f && t.callee.module == m {
                    seen += 1;
                    if tagged {
                        self.bc_tail_err(
                            t.span,
                            format("the call is inside a closure, which runs in a frame of its own"),
                        );
                    }
                }
            }
            return seen;
        }
        let mut misses = Vector::<irt::TailMiss>::new();
        let done = irt::convert(body, ow, &mut misses);
        if done != 0 && ctx.validate {
            bc_validate_elaborated(ow, body);
        }
        if tagged {
            for i in 0..misses.len() {
                let ms = *misses.at(i);
                let why = self.bc_tail_reason(body, &ms);
                self.bc_tail_err(ms.span, why);
            }
        }
        return done + misses.len() as u32;
    }

    fn bc_tail_err(self: &mut Self, sp: tok::Span, why: String) {
        self.errors.emit_span(
            sp,
            format("'@tail_recurse': this call of the function to itself cannot become a jump: {}", why),
        );
    }

    // The words of miss `ms` of `body`.
    fn bc_tail_reason(self: &mut Self, body: &ir::CoreBody, ms: &irt::TailMiss) String {
        let mut nm = String::from_str("a temporary");
        if ms.local != irt::LOCAL_UNKNOWN && ms.local < body.locals.len() as u32 {
            let ln = body.locals.at(ms.local as usize).name();
            if ln.end > ln.start {
                nm = format("'{}'", diag::span_str(self.source, ln.start, ln.end));
            }
        } else {
            nm = String::from_str("a local of the call");
        }
        let mut pn = String::new();
        if ms.reason == irt::TR_ADJUST || ms.reason == irt::TR_BORROW {
            let ln = body.locals.at((body.returns + ms.arg) as usize).name();
            pn = format("parameter '{}'", diag::span_str(self.source, ln.start, ln.end));
        }
        return switch ms.reason {
            irt::TR_NOT_TAIL => format("it is not in tail position: the function does not return its result as it is"),
            irt::TR_DROP => format("{} is dropped after it returns", nm.as_str()),
            irt::TR_AFTER => if self.bc_in_defer(ms.at) {
                format("a 'defer' block runs after it returns");
            } else {
                format("code runs after it returns");
            },
            irt::TR_INSTANCE => format("it may call another instance of the function (other generic arguments)"),
            irt::TR_ADJUST => format(
                "the argument for {} has another type than the parameter (another instance, or a conversion the jump does not repeat)",
                pn.as_str(),
            ),
            irt::TR_BORROW => format(
                "the argument for {} may hold a borrow of {}, which the next iteration overwrites",
                pn.as_str(),
                nm.as_str(),
            ),
            irt::TR_CANCEL => format("it can accept a task cancellation, whose check runs after it returns"),
            _ => format("the function takes a raw address of {}, which could be read after the call", nm.as_str()),
        };
    }

    // Does `sp` lie in a `defer` statement of the module?
    fn bc_in_defer(self: &mut Self, sp: tok::Span) bool {
        let a = unsafe &*self.cur_ast();
        for i in 0..a.nnodes() {
            let n = a.at_const(a.nth_id(i));
            if n.kind == NodeKind::NODE_DEFER && n.span.start <= sp.start && sp.end <= n.span.end {
                return true;
            }
        }
        return false;
    }

    // The `fn(..)` bound type of each generic parameter whose value `body` calls, and the function
    // type of each closure naming lifetimes it calls (`Owner::gen_sigs`): the call follows them.
    fn bc_gen_sigs(self: &mut Self, ow: &mut bfx::Owner, body: &ir::CoreBody) {
        for bi in 0..body.blocks.len() {
            let t = body.blocks.at(bi).term;
            if t.kind != ir::TM_CALL {
                continue;
            }
            if t.callee.node != NODE_NONE && unsafe (*self.mod_ast(t.callee.module)).at_const(t.callee.node).kind == NodeKind::NODE_CLOSURE {
                // A closure called as its hoisted function.
                let key = t.callee.module as u64 << 32 | t.callee.node as u64;
                if !ow.gen_sigs.contains_key(&key) {
                    let mut cls = Vector::<u8>::new();
                    let sig = self.tc_closure_sig(
                        unsafe (*self.mod_ast(t.callee.module)).type_of(t.callee.node),
                        &mut cls,
                    );
                    self.bc_closure_sig(ow, key, sig, &cls, t.callee);
                }
                continue;
            }
            if t.callee.node != NODE_NONE || t.a == ir::IR_NONE {
                continue;
            }
            let ct = body.operands.at(t.a as usize).ty;
            let y = *self.type_at(ct);
            let key = y.module as u64 << 32 | y.as_data.decl as u64;
            if y.kind != TypeKind::TYPE_GENERIC && (y.kind != TypeKind::TYPE_FUNCTION || y.fn_sig()) || ow.gen_sigs.contains_key(
                &key,
            ) {
                continue;
            }
            if y.kind == TypeKind::TYPE_FUNCTION {
                // A closure whose parameters name lifetimes: its classes, as a function type's.
                let mut cls = Vector::<u8>::new();
                let sig = self.tc_closure_sig(ct, &mut cls);
                self.bc_closure_sig(ow, key, sig, &cls, DefId { module: y.module, node: y.as_data.decl });
                continue;
            }
            let fb = self.generic_fn_bound(y.module, y.as_data.decl);
            if fb != NODE_NONE {
                ow.gen_sigs.insert(key, self.lower_type_in(y.module, fb));
            }
        }
    }

    // Record closure `c`'s function type `sig` and classes `cls` (`tc_closure_sig`) under `key`; one
    // no classes can show is an error, as its calls cannot follow its lifetimes.
    fn bc_closure_sig(self: &mut Self, ow: &mut bfx::Owner, key: u64, sig: TypeId, cls: &Vector<u8>, c: DefId) {
        if sig == TYPE_NONE {
            return;
        }
        ow.gen_sigs.insert(key, sig);
        ow.gen_cls.insert(key, ow.gen_cls_pool.len() as u64 << 16 | cls.len() as u64);
        for k in 0..cls.len() {
            ow.gen_cls_pool.push(cls[k]);
        }
        if sig == TYPE_ERROR {
            self.errors.emit_span(
                unsafe (*self.mod_ast(c.module)).at_const(c.node).span,
                format("this closure cannot be called: a function type cannot show how its parameters relate lifetimes"),
            );
            self.note_lt_limits();
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
                    if !cd.is_static_mut && !cd.is_extern && self.tc_value_owns(pl.ty) {
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
            if pl.base >= cap_lo && pl.base < cap_hi && self.tc_value_owns(pl.ty) {
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
        // The walk's own predicate (memoized), so generic bodies answer exactly as the walk does. A
        // pointer or a reference owns nothing: moving one copies a handle.
        if !self.tc_value_owns(pl.ty) {
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
        // Two arguments of one call that share borrowed storage, one mutably (read only when this
        // body's facts were built).
        if ctx.built {
            for c in 0..ctx.facts.clashes.len() {
                let cl = *ctx.facts.clashes.at(c);
                let k1 = if cl.second == 2 {
                    "mutable";
                } else {
                    "immutable";
                };
                let k2 = if cl.first == 2 {
                    "mutable";
                } else {
                    "immutable";
                };
                self.bc_ir_push(
                    out,
                    seen,
                    CAT_C_ISSUE,
                    cl.span,
                    format("cannot borrow this value as {} while it is already borrowed as {}", k1, k2),
                );
            }
        }
        // Skipped stages leave the previous body's facts behind.
        if ctx.built && body.owner.node == self.icx.current_fn {
            self.bc_ir_universal(ow, body, ctx, seen, out);
        }
        if ctx.built && body.owner.node != NODE_NONE && unsafe (*self.mod_ast(body.owner.module)).at_const(
            body.owner.node,
        ).kind == NodeKind::NODE_CLOSURE {
            self.bc_closure_escape(ow, body, &ctx.facts, seen, out);
        }
        ctx.st.pr.stop(BP_RULES, tr);
    }

    // A closure takes its arguments at any lifetime (its parameters name none): what an argument
    // borrows outlives no capture, no other argument and not `'static`. Report a flow from a
    // parameter's placeholder into a capture (its placeholder, or its own storage when the closure
    // holds it), another parameter's placeholder or `'static`, flow-insensitively, at the edge that
    // reaches it. Record the captures each parameter reaches (`Owner::cap_reach`).
    fn bc_closure_escape(
        self: &mut Self,
        ow: &mut bfx::Owner,
        body: &ir::CoreBody,
        f: &bfx::BodyFacts,
        seen: &mut Vector<u64>,
        out: &mut Vector<FlowErr>,
    ) {
        let np = unsafe (*self.mod_ast(body.owner.module)).at_const(body.owner.node).as_data.closure.params.len.min(
            body.args,
        );
        let no = f.norigins as usize;
        if no == 0 {
            // A loan-skipped body: no origin, no flow.
            return;
        }
        let mut ext = Vector::<bool>::new();
        let mut reach = Vector::<bool>::new();
        let key = body.owner.module as u64 << 32 | body.owner.node as u64;
        let start = ow.cap_reach_pool.len();
        ow.cap_reach_pool.resize_default(start + np as usize);
        ow.cap_reach.insert(key, start as u64 << 16 | np as u64);
        ow.cap_keep.insert(key, self.bc_closure_keep(ow, body, f, np));
        ow.res_deep.insert(key, self.bc_closure_result(body, f, np));
        for p in 0..np {
            let up = f.arg_universal[(body.returns + p) as usize];
            if up == bfx::BF_NONE {
                continue;
            }
            // A parameter its type makes `'static` may go anywhere; one naming an enclosing lifetime
            // may go into the captures (a call stores its argument where they point) and into a
            // parameter naming the same lifetime (a call ties the two).
            let mut pl = Vector::<tok::Span>::new();
            let st = self.bc_closure_param_lts(body, p, &mut pl);
            // The origins outside parameter `p`: `'static`, each capture's placeholder and storage,
            // each other parameter's placeholder.
            ext.truncate(0);
            ext.resize_default(no);
            ext.set(0, !st);
            for i in 0..body.args {
                let l = (body.returns + i) as usize;
                let uo = f.arg_universal[l];
                if st || uo == bfx::BF_NONE || uo == up || pl.len() != 0 && i >= np {
                    continue;
                }
                if i >= np && f.local_origin[l] != bfx::BF_NONE {
                    ext.set(f.local_origin[l] as usize, true);
                }
                let mut ql = Vector::<tok::Span>::new();
                let _ = i < np && self.bc_closure_param_lts(body, i, &mut ql);
                let mut shared = false;
                for a in 0..pl.len() {
                    for b in 0..ql.len() {
                        shared = shared || tc::spans_eq2(self.source, pl[a], self.source, ql[b]);
                    }
                }
                if !shared {
                    ext.set(uo as usize, true);
                }
            }
            // The origins the parameter's placeholder reaches.
            reach.truncate(0);
            reach.resize_default(no);
            reach.set(up as usize, true);
            let mut grew = true;
            // Each pass that grows the set marks one more of `no` origins.
            for _pass in 0..no + 1 {
                if !grew {
                    break;
                }
                grew = false;
                for k in 0..f.subsets.len() {
                    let e = *f.subsets.at(k);
                    if !reach[e.from as usize] || reach[e.to as usize] {
                        continue;
                    }
                    if ext[e.to as usize] {
                        let mut si: u32 = 0;
                        let blk = *body.blocks.at(self.bc_uni_site(f, e.point, &mut si));
                        let sp = if si < blk.stmt_len {
                            body.statements.at((blk.stmt_start + si) as usize).span;
                        } else {
                            blk.term.span;
                        };
                        self.bc_ir_push(
                            out,
                            seen,
                            CAT_U_STORE,
                            sp,
                            format(
                                "borrowed value does not live long enough: a closure argument is stored where it must outlive the closure",
                            ),
                        );
                        continue;
                    }
                    reach.set(e.to as usize, true);
                    grew = true;
                }
            }
            // The captures the parameter reaches; past the 64th, all.
            let mut m: u64 = 0;
            for k in np..body.args {
                let l = (body.returns + k) as usize;
                let lo = f.local_origin[l];
                let uo = f.arg_universal[l];
                if lo != bfx::BF_NONE && reach[lo as usize] || uo != bfx::BF_NONE && reach[uo as usize] {
                    m = if k - np < 64 {
                        m | 1u64 << (k - np) as u64;
                    } else {
                        0xFFFFFFFFFFFFFFFFu64;
                    };
                }
            }
            ow.cap_reach_pool.set(start + p as usize, m);
        }
    }

    // Do the results of closure `body` (`np` parameters) hold only what lies behind its by-reference
    // captures? None of the origins that reach a return slot is a by-value capture's (its own or its
    // placeholder), and no loan that reaches one borrows a capture's own storage. A caller then
    // ties a call through the closure value to what lies behind the value's references only
    // (`Owner::res_deep`, `Gen::closure_result_tie`).
    fn bc_closure_result(self: &Self, body: &ir::CoreBody, f: &bfx::BodyFacts, np: u32) bool {
        let no = f.norigins as usize;
        if body.args - np > 64 {
            return false;
        }
        let cf = unsafe (*self.mod_ast(body.owner.module)).closure_fact(body.owner.node);
        let by_ptr = if cf != null {
            unsafe (&*cf).mut_caps | unsafe (&*cf).ref_caps;
        } else {
            0u64;
        };
        // The origins that reach a return slot, found backward from the slots.
        let mut into = Vector::<bool>::new();
        into.resize_default(no);
        let mut stack = Vector::<u32>::new();
        for r in 0..body.returns {
            let lo = f.local_origin[r as usize];
            if lo != bfx::BF_NONE && !into[lo as usize] {
                into.set(lo as usize, true);
                stack.push(lo);
            }
            if r as usize < f.ret_origin.len() {
                let ro = f.ret_origin[r as usize];
                if ro != bfx::BF_NONE && !into[ro as usize] {
                    into.set(ro as usize, true);
                    stack.push(ro);
                }
            }
        }
        let mut st = Vector::<u32>::new();
        st.resize_default(no + 1);
        for e in 0..f.subsets.len() {
            let t = f.subsets.at(e).to as usize;
            st.set(t + 1, st[t + 1] + 1);
        }
        for o in 0..no {
            st.set(o + 1, st[o + 1] + st[o]);
        }
        let mut cur = Vector::<u32>::new();
        for o in 0..no {
            cur.push(st[o]);
        }
        let mut src = Vector::<u32>::new();
        src.resize_default(st[no] as usize);
        for e in 0..f.subsets.len() {
            let sb = *f.subsets.at(e);
            src.set(cur[sb.to as usize] as usize, sb.from);
            cur.set(sb.to as usize, cur[sb.to as usize] + 1);
        }
        // Each origin is pushed once.
        while stack.len() != 0 {
            let x = stack[stack.len() - 1] as usize;
            stack.truncate(stack.len() - 1);
            for i in st[x]..st[x + 1] {
                let y = src[i as usize];
                if !into[y as usize] {
                    into.set(y as usize, true);
                    stack.push(y);
                }
            }
        }
        for k in np..body.args {
            let l = (body.returns + k) as usize;
            let lo = f.local_origin[l];
            let uo = f.arg_universal[l];
            if (by_ptr >> (k - np) as u64 & 1u64) == 0 && (lo != bfx::BF_NONE && into[lo as usize] || uo != bfx::BF_NONE && into[uo as usize]) {
                return false;
            }
        }
        // A loan on a capture's own storage counts where it reaches a return slot at a level the
        // edges keep: a copy read through the reference holding it (`*v.index(0)`) drops it.
        let mut isret = Vector::<bool>::new();
        let mut fst = Vector::<u32>::new();
        let mut fe = Vector::<u32>::new();
        let mut seen = Vector::<bool>::new();
        for i in 0..f.loans.len() {
            let ln = *f.loans.at(i);
            let b = body.places.at(ln.place as usize).base;
            if !into[ln.origin as usize] || ln.through || b < body.returns + np || b >= body.returns + body.args {
                continue;
            }
            if isret.len() == 0 {
                isret.resize_default(no);
                for r in 0..body.returns {
                    let lo = f.local_origin[r as usize];
                    if lo != bfx::BF_NONE {
                        isret.set(lo as usize, true);
                    }
                    if r as usize < f.ret_origin.len() && f.ret_origin[r as usize] != bfx::BF_NONE {
                        isret.set(f.ret_origin[r as usize] as usize, true);
                    }
                }
                // The edges by source: their indices into `f.subsets`.
                fst.resize_default(no + 1);
                for e in 0..f.subsets.len() {
                    let s = f.subsets.at(e).from as usize;
                    fst.set(s + 1, fst[s + 1] + 1);
                }
                for o in 0..no {
                    fst.set(o + 1, fst[o + 1] + fst[o]);
                }
                for o in 0..no {
                    cur.set(o, fst[o]);
                }
                fe.resize_default(f.subsets.len());
                for e in 0..f.subsets.len() {
                    let s = f.subsets.at(e).from as usize;
                    fe.set(cur[s] as usize, e as u32);
                    cur.set(s, cur[s] + 1);
                }
            }
            // States (origin, level), each pushed once.
            seen.truncate(0);
            seen.resize_default(no * 3);
            stack.truncate(0);
            let l0 = (ln.level as u32).min(2);
            seen.set(ln.origin as usize * 3 + l0 as usize, true);
            stack.push(ln.origin * 3 + l0);
            while stack.len() != 0 {
                let x = stack[stack.len() - 1];
                stack.truncate(stack.len() - 1);
                let o = (x / 3) as usize;
                if isret[o] {
                    return false;
                }
                for j in fst[o]..fst[o + 1] {
                    let sb = *f.subsets.at(fe[j as usize] as usize);
                    let nd = bfx::sd_level(sb.delta, x % 3);
                    if nd != bfx::SD_DROP as u32 && !seen[sb.to as usize * 3 + nd as usize] {
                        seen.set(sb.to as usize * 3 + nd as usize, true);
                        stack.push(sb.to * 3 + nd);
                    }
                }
            }
        }
        return true;
    }

    // The captures (bit k) whose contents the destruction of closure `body` (`np` parameters) may
    // read: the ones it owns whose destruction observes borrows, and each one whose own origin or a
    // loan on it reaches one of those through the body's flows (past the 64th capture, all).
    fn bc_closure_keep(self: &Self, ow: &mut bfx::Owner, body: &ir::CoreBody, f: &bfx::BodyFacts, np: u32) u64 {
        let no = f.norigins as usize;
        let cf = unsafe (*self.mod_ast(body.owner.module)).closure_fact(body.owner.node);
        let by_ptr = if cf != null {
            unsafe (&*cf).mut_caps | unsafe (&*cf).ref_caps;
        } else {
            0u64;
        };
        let mut keep: u64 = 0;
        // The origins that reach an observing owned capture, found backward from those captures.
        let mut into = Vector::<bool>::new();
        into.resize_default(no);
        let mut stack = Vector::<u32>::new();
        for k in np..body.args {
            let lo = f.local_origin[(body.returns + k) as usize];
            let ty = body.locals.at((body.returns + k) as usize).ty;
            if lo == bfx::BF_NONE || k - np < 64 && (by_ptr >> (k - np) as u64 & 1u64) != 0 || !ow.owns(
                body.owner,
                body.owner.module,
                ty,
            ) || !ow.observes(body.owner.module, ty) {
                continue;
            }
            keep = keep | bit_or_all(k - np);
            if !into[lo as usize] {
                into.set(lo as usize, true);
                stack.push(lo);
            }
        }
        if stack.len() == 0 {
            return keep;
        }
        // The sources of each origin, by counting sort on the target.
        let mut st = Vector::<u32>::new();
        st.resize_default(no + 1);
        for e in 0..f.subsets.len() {
            let t = f.subsets.at(e).to as usize;
            st.set(t + 1, st[t + 1] + 1);
        }
        for o in 0..no {
            st.set(o + 1, st[o + 1] + st[o]);
        }
        let mut cur = Vector::<u32>::new();
        for o in 0..no {
            cur.push(st[o]);
        }
        let mut src = Vector::<u32>::new();
        src.resize_default(st[no] as usize);
        for e in 0..f.subsets.len() {
            let sb = *f.subsets.at(e);
            src.set(cur[sb.to as usize] as usize, sb.from);
            cur.set(sb.to as usize, cur[sb.to as usize] + 1);
        }
        // Each origin is pushed once.
        while stack.len() != 0 {
            let x = stack[stack.len() - 1] as usize;
            stack.truncate(stack.len() - 1);
            for i in st[x]..st[x + 1] {
                let y = src[i as usize];
                if !into[y as usize] {
                    into.set(y as usize, true);
                    stack.push(y);
                }
            }
        }
        for k in np..body.args {
            let l = (body.returns + k) as usize;
            let lo = f.local_origin[l];
            let uo = f.arg_universal[l];
            if lo != bfx::BF_NONE && into[lo as usize] || uo != bfx::BF_NONE && into[uo as usize] {
                keep = keep | bit_or_all(k - np);
            }
        }
        for i in 0..f.loans.len() {
            let ln = *f.loans.at(i);
            let b = body.places.at(ln.place as usize).base;
            if b >= body.returns + np && b < body.returns + body.args && into[ln.origin as usize] {
                keep = keep | bit_or_all(b - body.returns - np);
            }
        }
        return keep;
    }

    // The lifetimes closure parameter `p`'s type names (into `out`), `'static` aside; true when its own
    // lifetime is `'static`.
    fn bc_closure_param_lts(self: &Self, body: &ir::CoreBody, p: u32, out: &mut Vector<tok::Span>) bool {
        let a = self.mod_ast(body.owner.module);
        let ps = unsafe (*a).at_const(body.owner.node).as_data.closure.params;
        if p >= ps.len {
            return false;
        }
        let tyn = unsafe (*a).slot_type_node(unsafe (*a).list(ps)[p as usize]);
        if tyn == NODE_NONE {
            return false;
        }
        let tn = *unsafe (*a).at_const(tyn);
        if tn.has_lt_slot() && tc::span_is(self.source, self.tc_lt_name(tn.as_data.indirect_type.lifetime), "'static") {
            return true;
        }
        let mut all = Vector::<tok::Span>::new();
        self.tc_typenode_lifetimes(body.owner.module, tyn, &mut all, 0);
        for i in 0..all.len() {
            if !tc::span_is(self.source, all[i], "'static") {
                out.push(all[i]);
            }
        }
        return false;
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
    // outliving every region. Each origin's value has one slot per lifetime position of its type
    // (`bc_uni_len`); the parameters' slots start at the regions their signature spells there.
    // The regions flow over the body's subset edges, flow-insensitively like NLL's outlives
    // constraints, slot to slot where the operation at the edge shows which position of the
    // source lands at which position of the target (`bc_uni_map`), into the placeholders: the
    // return slots, the storage the parameters reach, and `'static`. A region arriving at a
    // position must outlive the region the signature declares there; one arriving at a position
    // the check cannot tell must outlive every region of the slot.
    fn bc_ir_universal(
        self: &mut Self,
        ow: &mut bfx::Owner,
        body: &ir::CoreBody,
        ctx: &mut BorrowCtx,
        seen: &mut Vector<u64>,
        out: &mut Vector<FlowErr>,
    ) {
        let f = &ctx.facts;
        let nu = f.nuniversal;
        // Only an edge from the body into a placeholder or a parameter's local can force a region to
        // outlive another.
        let mut into = false;
        for k in 0..f.subsets.len() {
            let e = f.subsets.at(k);
            let tl = f.origin_local[e.to as usize];
            if e.from >= nu && (e.to < nu || tl != bfx::BF_NONE && tl >= body.returns && tl < body.returns + body.args) {
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
        u.pos.truncate(0);
        u.over = false;
        u.look = false;
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
            if i as i32 == es && u.first != UNI_NONE {
                elide = u.first;
            }
        }
        for r in 0..nr {
            let _ = self.bc_uni_type(u, unsafe (*a).slot_type_node(unsafe (*a).list(rets)[r as usize]), false, elide, 0);
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
        // Each body origin's slots: the lifetime positions of its local's type.
        let no = f.norigins as usize;
        u.base.truncate(0);
        u.cnt.truncate(0);
        u.opq.truncate(0);
        let mut ns: u32 = 0;
        for o in 0..no {
            let l = f.origin_local[o];
            let mut c: u32 = UNI_SLOTS_MAX + 1;
            if o >= nu as usize && l != bfx::BF_NONE && l as usize < body.locals.len() {
                c = self.bc_uni_len(body.locals.at(l as usize).ty, 0);
            }
            let opq = c > UNI_SLOTS_MAX;
            if opq {
                c = 1;
            }
            u.base.push(ns);
            u.cnt.push(c);
            u.opq.push(opq);
            ns += c;
        }
        u.st.truncate(0);
        u.st.resize_default(ns as usize);
        u.sk.truncate(0);
        u.sk.resize_default(ns as usize);
        u.cv.truncate(0);
        u.cv.resize_default(ns as usize);
        u.gen.truncate(0);
        u.gen.resize_default(ns as usize);
        u.vr.truncate(0);
        u.vr.resize_default(ns as usize);
        u.queue.truncate(0);
        u.queued.truncate(0);
        u.queued.resize_default(no);
        u.phl.truncate(0);
        for _o in 0..nu {
            u.phl.push(bfx::BF_NONE);
        }
        // A parameter's slots start at the regions its signature spells there, which are also what
        // the storage it reaches is declared to hold; a return slot's, what it is declared to hold.
        u.look = true;
        for i in 0..np {
            let l = body.returns + i;
            let uo = f.arg_universal[l as usize];
            if uo != bfx::BF_NONE {
                u.phl.set(uo as usize, l);
            }
            let lo = f.local_origin[l as usize];
            if lo != bfx::BF_NONE {
                self.bc_uni_seed(
                    ow,
                    u,
                    lo,
                    unsafe (*a).slot_type_node(unsafe (*a).list(params)[i as usize]),
                    body.locals.at(l as usize).ty,
                    UNI_NONE,
                    true,
                );
                if u.all(lo) != 0 && !u.queued[lo as usize] {
                    u.queued.set(lo as usize, true);
                    u.queue.push(lo);
                }
            }
        }
        for r in 0..nr {
            let lo = f.local_origin[r as usize];
            if lo != bfx::BF_NONE && lo >= nu {
                self.bc_uni_seed(
                    ow,
                    u,
                    lo,
                    unsafe (*a).slot_type_node(unsafe (*a).list(rets)[r as usize]),
                    body.locals.at(r as usize).ty,
                    elide,
                    false,
                );
            }
        }
        u.look = false;
        // A closure naming one of this function's lifetimes holds that region.
        for k in 0..f.named.len() {
            let to = (f.named[k] >> 32) as u32;
            let nm = f.uni_name[(f.named[k] & 0xFFFFFFFFu64) as usize];
            for i in 1..u.names.len() {
                if tc::spans_eq2(self.source, u.names[i], self.source, nm) {
                    for s in 0..u.cnt[to as usize] {
                        let at = (u.base[to as usize] + s) as usize;
                        u.st.set(at, u.st[at] | 1u64 << i as u64);
                    }
                    if !u.queued[to as usize] {
                        u.queued.set(to as usize, true);
                        u.queue.push(to);
                    }
                }
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
        u.emap.truncate(0);
        for _k in 0..f.subsets.len() {
            u.emap.push(EM_NONE);
        }
        u.pairs.truncate(0);
        // A slot only gains regions, and each gain queues its origin once.
        let bound = u.queue.len() as u64 + ns as u64 * UNI_MAX as u64;
        let mut pushes = u.queue.len() as u64;
        while u.queue.len() != 0 {
            let x = u.queue[u.queue.len() - 1] as usize;
            u.queue.truncate(u.queue.len() - 1);
            u.queued.set(x, false);
            for k in u.start[x]..u.start[x + 1] {
                let ek = u.edges[k as usize];
                let t = f.subsets.at(ek as usize).to;
                if t < nu {
                    // Checked below, edge by edge.
                    continue;
                }
                if !self.bc_uni_pass(ow, u, body, f, ek) {
                    continue;
                }
                if !u.queued[t as usize] {
                    u.queued.set(t as usize, true);
                    u.queue.push(t);
                    pushes += 1;
                    assert(pushes <= bound, "the universal-region flow stays within its monotone bound");
                }
            }
        }
        // Each edge from the body into a placeholder, and each into a return slot's local (the
        // value a return stores; the return's own edge into the placeholder passes it on whole).
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
            // A store into a parameter's local reaches caller storage at its positions behind a
            // reference or a view.
            let tl = if e.to >= nu {
                f.origin_local[e.to as usize];
            } else {
                bfx::BF_NONE;
            };
            let mut vis = rs == UNI_NONE && tl != bfx::BF_NONE && tl >= body.returns && tl < body.returns + np;
            if vis {
                // A mutable borrow's edge back into the borrowed parameter carries what is later stored
                // through it; that store's own edge reports it, where it happens.
                let mut si: u32 = 0;
                let blk = *body.blocks.at(self.bc_uni_site(f, e.point, &mut si));
                if si < blk.stmt_len {
                    let st = *body.statements.at((blk.stmt_start + si) as usize);
                    let rv = *body.rvalues.at(st.rvalue as usize);
                    vis = !(st.kind == ir::ST_ASSIGN && (rv.kind == ir::RV_REF || rv.kind == ir::RV_USE && rv.b != 0) && body.places.at(
                        st.place as usize,
                    ).base == f.origin_local[e.from as usize]);
                }
            }
            if e.to >= nu && rs == UNI_NONE && !vis || e.to < nu && f.origin_local[e.from as usize] < body.returns {
                continue;
            }
            let ph = if rs == UNI_NONE {
                e.to as usize;
            } else {
                f.ret_origin[rs as usize] as usize;
            };
            if !self.bc_uni_check(ow, u, body, f, k as u32, ph == 0, vis) {
                continue;
            }
            let mut si: u32 = 0;
            let blk = *body.blocks.at(self.bc_uni_site(f, e.point, &mut si));
            let mut sp = blk.term.span;
            if si < blk.stmt_len {
                sp = body.statements.at((blk.stmt_start + si) as usize).span;
            }
            let mut cat = CAT_U_STORE;
            let mut msg = format(
                "borrowed value does not live long enough: it is stored into caller-visible data whose lifetime it is not declared to outlive",
            );
            if ph == 0 {
                cat = CAT_U_STATIC;
                msg = format("lifetime mismatch: this argument's lifetime is not declared to outlive 'static");
            } else if rs != UNI_NONE {
                cat = CAT_U_RET;
                msg = format(
                    "lifetime mismatch: the returned value's lifetime is not declared to outlive the return type's lifetime",
                );
            }
            // A declaration-level check already reported this relation at its operand, or this store
            // was reported as reaching `'static` (a `'static` member) or caller storage.
            let mut dup = false;
            for d in self.err_wm..self.errors.errors.len() {
                if self.errors.errors[d].msg.equals(&msg) {
                    dup = true;
                }
            }
            if cat == CAT_U_STORE && seen.contains(&(CAT_U_STATIC as u64 << 32 | sp.start as u64)) || cat == CAT_U_STATIC && seen.contains(
                &(CAT_U_STORE as u64 << 32 | sp.start as u64),
            ) {
                dup = true;
            }
            if !dup {
                self.bc_ir_push(out, seen, cat, sp, msg);
            }
        }
    }

    // Seed origin `o` from signature type node `tn` of its local's type `ty`: each slot holds the
    // region the node spells at that position, as a parameter's start (`param`) and as the regions
    // the slot is declared to hold. An elided position is a parameter's own region, a return's
    // `elide`; a type parameter's position holds the regions its bounds name, and takes a value of
    // that type only, so no region is declared there. A node that does not spell the type's
    // positions makes the origin one opaque slot of all its regions.
    fn bc_uni_seed(
        self: &Self,
        ow: &mut bfx::Owner,
        u: &mut UniSt,
        o: u32,
        tn: NodeId,
        ty: TypeId,
        elide: u32,
        param: bool,
    ) {
        let b = u.base[o as usize] as usize;
        if param && !u.opq[o as usize] {
            let mut lv = replace(&mut u.toks, Vector::<u64>::new());
            lv.truncate(0);
            self.bc_uni_levels(ty, false, 0, &mut lv);
            for i in 0..lv.len().min(u.cnt[o as usize] as usize) {
                u.cv.set(b + i, lv[i] != 0);
            }
            u.toks = lv;
        }
        let el = if param {
            UNI_NONE;
        } else {
            elide;
        };
        u.keys.truncate(0);
        if !u.opq[o as usize] && self.bc_uni_walk(ow, u, self.cur_module(), self.bc_uni_ext(), tn, ty, false, 0) {
            let mut ok = true;
            for i in 0..u.cnt[o as usize] as usize {
                let key = u.keys[2 * i];
                let aux = u.keys[2 * i + 1];
                let mut r: u64 = 0;
                let mut sink = true;
                if key == UK_STATIC {
                    r = 1;
                } else if key >> 63 != 0 {
                    let x = self.bc_uni_named(u, self.tc_lt_name((aux >> 32) as NodeId));
                    if x != UNI_NONE {
                        r = 1u64 << x as u64;
                    }
                } else if (key & UK_EL) != 0 {
                    if param {
                        let at = key ^ UK_EL;
                        let mut j: usize = 0;
                        while j + 1 < u.pos.len() {
                            if u.pos[j] == at {
                                r = 1u64 << u.pos[j + 1];
                            }
                            j += 2;
                        }
                    } else if elide < UNI_UNSOURCED {
                        r = 1u64 << elide as u64;
                    } else {
                        sink = false;
                    }
                } else {
                    u.m0 = 0;
                    u.m1 = 0;
                    let _ = self.bc_uni_type(u, (aux >> 32) as NodeId, false, el, 0);
                    r = u.m0 | u.m1;
                    // A value of a type parameter holds the regions its bounds name; a value of the type
                    // brings no other (`bc_uni_check`), but its bounds' methods may store one.
                    u.gen.set(b + i, (key & UK_GEN) != 0);
                }
                if r == 0 && sink && !u.gen[b + i] {
                    ok = false;
                }
                if param {
                    u.st.set(b + i, r);
                }
                if sink {
                    u.sk.set(b + i, r);
                    let v = (aux >> 17 & 3u64) as u8;
                    u.vr.set(
                        b + i,
                        if v == 3 {
                            2;
                        } else if v == 2 {
                            1;
                        } else {
                            0;
                        },
                    );
                }
            }
            if ok {
                return;
            }
        }
        u.m0 = 0;
        u.m1 = 0;
        let _ = self.bc_uni_type(u, tn, false, el, 0);
        u.opq.set(o as usize, true);
        if param {
            u.st.set(b, u.m0 | u.m1);
        }
        u.sk.set(b, u.m0 | u.m1);
    }

    // The extend or interface the current function belongs to, or NODE_NONE.
    fn bc_uni_ext(self: &Self) NodeId {
        let ext = self.enclosing(self.cur_module(), self.icx.current_fn, NodeKind::NODE_EXTEND);
        if ext != NODE_NONE {
            return ext;
        }
        return self.enclosing(self.cur_module(), self.icx.current_fn, NodeKind::NODE_INTERFACE);
    }

    // Pass the regions of edge `k` into its target's slots; true when one gained a region.
    fn bc_uni_pass(self: &Self, ow: &mut bfx::Owner, u: &mut UniSt, body: &ir::CoreBody, f: &bfx::BodyFacts, k: u32) bool {
        let e = *f.subsets.at(k as usize);
        let m = self.bc_uni_map(ow, u, body, f, k);
        let mut grew = false;
        if m == EM_COARSE {
            let rs = u.all(e.from);
            for i in 0..u.cnt[e.to as usize] {
                let at = (u.base[e.to as usize] + i) as usize;
                if (u.st[at] | rs) != u.st[at] {
                    u.st.set(at, u.st[at] | rs);
                    grew = true;
                }
            }
            return grew;
        }
        for i in m >> 32..(m >> 32) + (m & 0xFFFFFFFFu64) {
            let p = u.pairs[i as usize];
            let src = (p >> 32) as usize;
            let dst = (p & 0xFFFFFFFFu64) as usize;
            if (u.st[dst] | u.st[src]) != u.st[dst] {
                u.st.set(dst, u.st[dst] | u.st[src]);
                grew = true;
            }
        }
        return grew;
    }

    // Does the value edge `k` brings to a placeholder, a return slot's local or a parameter's local
    // (`vis`: only its positions in caller storage) hold a region that does not outlive what the
    // position it lands at is declared to hold? Into `'static` (`stat`): every region of the value
    // the operation reads, past a read through a reference only those behind one.
    fn bc_uni_check(
        self: &Self,
        ow: &mut bfx::Owner,
        u: &mut UniSt,
        body: &ir::CoreBody,
        f: &bfx::BodyFacts,
        k: u32,
        stat: bool,
        vis: bool,
    ) bool {
        let e = *f.subsets.at(k as usize);
        if stat {
            return u.fails(self.bc_uni_static(ow, u, body, f, &e), 1);
        }
        let mut tor = e.to;
        if e.to < f.nuniversal {
            let l = u.phl[e.to as usize];
            if l == bfx::BF_NONE {
                return false;
            }
            tor = f.local_origin[l as usize];
        }
        let m = self.bc_uni_map(ow, u, body, f, k);
        if m == EM_COARSE {
            let rs = u.all(e.from);
            for i in 0..u.cnt[tor as usize] {
                let s = (u.base[tor as usize] + i) as usize;
                if (!vis || u.cv[s]) && u.fails_at(u.typed(rs, s), s) {
                    return true;
                }
            }
            return false;
        }
        for i in m >> 32..(m >> 32) + (m & 0xFFFFFFFFu64) {
            let p = u.pairs[i as usize];
            let s = (p & 0xFFFFFFFFu64) as usize;
            if (!vis || u.cv[s]) && u.fails_at(u.typed(u.st[(p >> 32) as usize], s), s) {
                return true;
            }
        }
        return false;
    }

    // The regions of edge `e`'s source that must outlive `'static`: those at the positions of the
    // places of its local the operation at the edge's point reads (all of its slots when it reads
    // none, or one does not map), only those behind a reference when the edge drops the value's own
    // level past what the place itself reads through (`bc_uni_project` already left those).
    fn bc_uni_static(
        self: &Self,
        ow: &mut bfx::Owner,
        u: &mut UniSt,
        body: &ir::CoreBody,
        f: &bfx::BodyFacts,
        e: &bfx::SubsetAt,
    ) u64 {
        let x = e.from;
        let xl = f.origin_local[x as usize];
        if u.opq[x as usize] {
            return u.all(x);
        }
        let mut reads = replace(&mut u.pc, Vector::<u32>::new());
        reads.truncate(0);
        self.bc_uni_reads(body, f, e.point, xl, &mut reads);
        let mut pa = replace(&mut u.pa, Vector::<u32>::new());
        let mut rs: u64 = 0;
        let mut all = reads.len() == 0;
        let drops = bfx::sd_level(e.delta, 0) == bfx::SD_DROP as u32;
        for i in 0..reads.len() {
            pa.truncate(0);
            if !self.bc_uni_project(ow, u, body, x, reads[i], &mut pa) {
                all = true;
                break;
            }
            let deref = drops && !self.bc_uni_through(body, reads[i]);
            rs = rs | self.bc_uni_behind(u, &pa, body.places.at(reads[i] as usize).ty, deref);
        }
        if all {
            pa.truncate(0);
            for i in 0..u.cnt[x as usize] {
                pa.push(u.base[x as usize] + i);
            }
            rs = self.bc_uni_behind(u, &pa, body.locals.at(xl as usize).ty, drops);
        }
        u.pa = pa;
        u.pc = reads;
        return rs;
    }

    // The regions at slots `pos` of a value of type `ty`; with `deref`, only those behind a reference.
    fn bc_uni_behind(self: &Self, u: &mut UniSt, pos: &Vector<u32>, ty: TypeId, deref: bool) u64 {
        let mut keep = replace(&mut u.toks, Vector::<u64>::new());
        keep.truncate(0);
        if deref {
            self.bc_uni_levels(ty, false, 0, &mut keep);
        }
        let mut rs: u64 = 0;
        for i in 0..pos.len() {
            if pos[i] < POS_STATIC && (!deref || i < keep.len() && keep[i] != 0) {
                rs = rs | u.st[pos[i] as usize];
            }
        }
        u.toks = keep;
        return rs;
    }

    // Per lifetime position of type `ty` (`bc_uni_len`), 1 when it lies behind a reference.
    fn bc_uni_levels(self: &Self, ty: TypeId, behind: bool, depth: i32, out: &mut Vector<u64>) {
        let n = self.bc_uni_len(ty, depth);
        if n == 0 || n > UNI_SLOTS_MAX {
            return;
        }
        let b = if behind {
            1u64;
        } else {
            0u64;
        };
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_REFERENCE {
            out.push(b);
            self.bc_uni_levels(y.as_data.elem, true, depth + 1, out);
        } else if y.kind == TypeKind::TYPE_ARRAY {
            self.bc_uni_levels(y.as_data.arr.elem, behind, depth + 1, out);
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            let view = self.bc_uni_view(it.module, it.decl);
            for _k in 0..unsafe (*self.mod_ast(it.module)).lifetimes_of(it.decl).len {
                out.push(b);
            }
            for i in 0..it.n {
                self.bc_uni_levels(unsafe it.args[i as usize], behind || view, depth + 1, out);
            }
        } else {
            for _k in 0..n {
                out.push(b);
            }
        }
    }

    // The places of local `xl` the operation at `point` reads into its result, into `out`.
    fn bc_uni_reads(self: &Self, body: &ir::CoreBody, f: &bfx::BodyFacts, point: u32, xl: u32, out: &mut Vector<u32>) {
        let mut si: u32 = 0;
        let blk = *body.blocks.at(self.bc_uni_site(f, point, &mut si));
        let mut start: u32 = 0;
        let mut len: u32 = 0;
        let mut pool = true;
        if si < blk.stmt_len {
            let st = *body.statements.at((blk.stmt_start + si) as usize);
            if st.kind != ir::ST_ASSIGN {
                return;
            }
            let rv = *body.rvalues.at(st.rvalue as usize);
            if rv.kind == ir::RV_REF || rv.kind == ir::RV_SLICE {
                if body.places.at(rv.a as usize).base == xl {
                    out.push(rv.a);
                }
                return;
            }
            if rv.kind == ir::RV_USE || rv.kind == ir::RV_CAST || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_DYN || rv.kind == ir::RV_REPEAT {
                start = rv.a;
                len = 1;
                pool = false;
            } else if rv.kind == ir::RV_AGGREGATE || rv.kind == ir::RV_CLOSURE {
                start = rv.a;
                len = rv.b;
            }
        } else if blk.term.kind == ir::TM_CALL {
            start = blk.term.args_start;
            len = blk.term.args_len;
        }
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
            if (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && body.places.at(op.data as usize).base == xl {
                out.push(op.data);
            }
        }
    }

    // The lifetime positions of a value of type `ty` (this body's module): a reference's own, then
    // its pointee's; a declaration's lifetime parameters, then each type argument's (a view's: its
    // own, then its element's); an array's element's; a function pointer's lifetimes fixed outside
    // its type, by class; one for a type parameter, an erased object, a closure or an associated
    // type; none for any other type. UNI_SLOTS_MAX + 1 past the bound.
    fn bc_uni_len(self: &Self, ty: TypeId, depth: i32) u32 {
        if ty == TYPE_NONE {
            return 0;
        }
        if depth > 8 {
            return UNI_SLOTS_MAX + 1;
        }
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_REFERENCE {
            return (1 + self.bc_uni_len(y.as_data.elem, depth + 1)).min(UNI_SLOTS_MAX + 1);
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            return self.bc_uni_len(y.as_data.arr.elem, depth + 1);
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return unsafe (*self.mod_ast(y.module)).lifetimes_of(y.as_data.decl).len;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            if !unsafe (*self.cur_ast()).instance_valid(y.as_data.inst) {
                return UNI_SLOTS_MAX + 1;
            }
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            let mut n = unsafe (*self.mod_ast(it.module)).lifetimes_of(it.decl).len;
            for i in 0..it.n {
                n += self.bc_uni_len(unsafe it.args[i as usize], depth + 1);
                if n > UNI_SLOTS_MAX {
                    return UNI_SLOTS_MAX + 1;
                }
            }
            return n;
        }
        if y.fn_sig() && !self.bc_uni_wide(&y) {
            return self.bc_uni_outer_count(&y);
        }
        if y.kind == TypeKind::TYPE_DYN && unsafe (*self.cur_ast()).dyn_fn_sig(&y) != TYPE_NONE {
            // A function object: its captures' bound, then its signature's outer lifetimes.
            return 1 + self.bc_uni_outer_count(self.type_at(unsafe (*self.cur_ast()).dyn_fn_sig(&y)));
        }
        if y.kind == TypeKind::TYPE_GENERIC || y.kind == TypeKind::TYPE_DYN || y.kind == TypeKind::TYPE_FUNCTION || y.kind == TypeKind::TYPE_OPAQUE || y.kind == TypeKind::TYPE_ASSOC || y.kind == TypeKind::TYPE_FIELD_PROJECTION || y.kind == TypeKind::TYPE_SLICE {
            return 1;
        }
        return 0;
    }

    // Are function-pointer type `y`'s lifetime classes past the encoding (`LTS_WIDE`)? A value of it can
    // be neither called nor converted: one opaque position.
    fn bc_uni_wide(self: &Self, y: &Ty) bool {
        return unsafe (*self.cur_ast()).instance(y.as_data.fnp.sig).lts == LTS_WIDE;
    }

    // The lifetime classes function-pointer type `y` fixes outside it (`LC_OUTER`).
    fn bc_uni_outer_count(self: &Self, y: &Ty) u32 {
        let a = self.cur_ast();
        let mut g: u32 = 0;
        for k in 0..unsafe (*a).sig_lt_len(y) {
            let c = unsafe (*a).sig_lt_class(y, k);
            if c >= LC_OUTER && c != LC_TOO_MANY && (c - LC_OUTER) as u32 >= g {
                g = (c - LC_OUTER) as u32 + 1;
            }
        }
        return g;
    }

    // Is (m, d) the prelude's `Slice` or `SliceMut`?
    const fn bc_uni_view(self: &Self, m: ModuleId, d: NodeId) bool {
        return d != NODE_NONE && (m == self.ph_slice.mid && d == self.ph_slice.node || m == self.ph_slicemut.mid && d == self.ph_slicemut.node);
    }

    // The declaration of a struct, enum or instance type `ty` into `d`, and its argument count;
    // false for another type.
    fn bc_uni_decl(self: &Self, ty: TypeId, d: &mut DefId, nargs: &mut u32) bool {
        let y = *self.type_at(ty);
        *nargs = 0;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            *d = DefId { module: y.module, node: y.as_data.decl };
            return y.as_data.decl != NODE_NONE;
        }
        if y.kind != TypeKind::TYPE_INSTANCE || !unsafe (*self.cur_ast()).instance_valid(y.as_data.inst) {
            return false;
        }
        let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
        *d = DefId { module: it.module, node: it.decl };
        *nargs = it.n;
        return true;
    }

    // Argument `i` of instance type `ty`.
    fn bc_uni_arg(self: &Self, ty: TypeId, i: u32) TypeId {
        let it = *unsafe (*self.cur_ast()).instance(self.type_at(ty).as_data.inst);
        return unsafe it.args[i as usize];
    }

    // Type node `tyn` of module `m`, a `Self` path read as the target type of extend `ext` (kept for an
    // interface's, NODE_NONE when there is none).
    fn bc_uni_unself(self: &Self, m: ModuleId, ext: NodeId, tyn: NodeId) NodeId {
        if tyn == NODE_NONE || unsafe (*self.mod_ast(m)).at_const(tyn).kind != NodeKind::NODE_TYPE_PATH || !self.tc_path_is_self(
            m,
            tyn,
        ) {
            return tyn;
        }
        if ext == NODE_NONE {
            return NODE_NONE;
        }
        if unsafe (*self.mod_ast(m)).at_const(ext).kind == NodeKind::NODE_INTERFACE {
            return tyn;
        }
        return unsafe (*self.mod_ast(m)).at_const(ext).as_data.extend_def.target_type;
    }

    // Append the key of lifetime node `lt` of module `m` (elided: slot `slot` of type node `at`).
    fn bc_uni_ltkey(
        self: &Self,
        ow: &bfx::Owner,
        u: &mut UniSt,
        m: ModuleId,
        lt: NodeId,
        at: NodeId,
        slot: u32,
        bf: u64,
    ) {
        if lt != NODE_NONE && tc::span_is(self.mod_src(m), self.tc_lt_name_in(m, lt), "'static") {
            u.keys.push(UK_STATIC);
            u.keys.push(bf);
            return;
        }
        let tk = ow.lt_tok(m, lt);
        if tk == 0 {
            u.keys.push(UK_EL | at as u64 << 8 | slot as u64);
            u.keys.push(bf);
            return;
        }
        u.keys.push(tk);
        u.keys.push(lt as u64 << 32 | bf);
    }

    // Walk type node `tn0` of module `m` (`Self` naming extend `ext`'s target) along type `ty`
    // (this body's module), appending to `u.keys` a (key, aux) pair per lifetime position of `ty`
    // (`bc_uni_len`): what the node spells there (`UK_*`). Inside a declaration whose arguments a
    // field walk knows (`u.wdecl`), its type parameter stands for its argument only. False when
    // the node does not spell the type's structure (an alias, another type) or the type is past
    // the bound.
    fn bc_uni_walk(
        self: &Self,
        ow: &bfx::Owner,
        u: &mut UniSt,
        m: ModuleId,
        ext: NodeId,
        tn0: NodeId,
        ty: TypeId,
        behind: bool,
        depth: i32,
    ) bool {
        let ns = self.bc_uni_len(ty, 0);
        if ns == 0 {
            return true;
        }
        if ns > UNI_SLOTS_MAX || depth > 8 {
            return false;
        }
        let tn = self.bc_uni_unself(m, ext, tn0);
        if tn == NODE_NONE {
            return false;
        }
        let a = self.mod_ast(m);
        let n = *unsafe (*a).at_const(tn);
        let bf = if behind {
            UA_BEHIND;
        } else {
            0;
        };
        if n.kind == NodeKind::NODE_TYPE_PATH {
            let mut d = unsafe (*a).path_def(tn);
            if ext != NODE_NONE && unsafe (*a).at_const(ext).kind == NodeKind::NODE_INTERFACE && self.tc_path_is_self(
                m,
                tn,
            ) {
                // An interface's `Self` stands for the receiver's type.
                d = DefId { module: m, node: ext };
            }
            if d.node != NODE_NONE && (d.node == ext && d.module == m || unsafe (*self.mod_ast(d.module)).at_const(
                d.node,
            ).kind == NodeKind::NODE_GENERIC_PARAM) {
                if u.wdecl.node != NODE_NONE {
                    let gi = self.bc_uni_gen_index(u.wdecl, d);
                    if gi != UNI_NONE && (gi as usize >= u.wargs.len() || u.wargs[gi as usize] != ty) {
                        return false;
                    }
                }
                for j in 0..ns {
                    u.keys.push(UK_GEN | d.module as u64 << 32 | d.node as u64);
                    u.keys.push(tn as u64 << 32 | bf | j as u64);
                }
                return true;
            }
        }
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_REFERENCE {
            if !n.is_ref_type() {
                return false;
            }
            self.bc_uni_ltkey(ow, u, m, n.as_data.indirect_type.lifetime, tn, 0, bf);
            return self.bc_uni_walk(ow, u, m, ext, n.as_data.indirect_type.ty, y.as_data.elem, true, depth + 1);
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            return n.kind == NodeKind::NODE_ARRAY_TYPE && self.bc_uni_walk(
                ow,
                u,
                m,
                ext,
                n.as_data.array_type.element,
                y.as_data.arr.elem,
                behind,
                depth + 1,
            );
        }
        if y.fn_sig() && !self.bc_uni_wide(&y) {
            return self.bc_uni_walk_fn(ow, u, m, tn, &y, ns, bf, depth);
        }
        if y.kind == TypeKind::TYPE_DYN && unsafe (*self.cur_ast()).dyn_fn_sig(&y) != TYPE_NONE {
            // `Box<dyn ..>` is the owned object type itself.
            if n.kind == NodeKind::NODE_TYPE_PATH && n.as_data.type_path.args.len == 1 {
                let bd = unsafe (*a).path_def(tn);
                if bd.node == self.ph_box.node && bd.module == self.ph_box.mid {
                    return self.bc_uni_walk(
                        ow,
                        u,
                        m,
                        ext,
                        unsafe (*a).list(n.as_data.type_path.args)[0],
                        ty,
                        behind,
                        depth + 1,
                    );
                }
            }
            if n.kind != NodeKind::NODE_DYN_TYPE {
                return false;
            }
            // The captures' bound: `'static` for an owned object.
            if y.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 {
                u.keys.push(UK_STATIC);
                u.keys.push(bf);
            } else {
                self.bc_uni_ltkey(ow, u, m, n.as_data.indirect_type.lifetime, tn, 0, bf);
            }
            let fy = *self.type_at(unsafe (*self.cur_ast()).dyn_fn_sig(&y));
            return self.bc_uni_walk_fn(ow, u, m, n.as_data.indirect_type.ty, &fy, ns - 1, bf, depth);
        }
        let mut d = DefId { module: 0, node: NODE_NONE };
        let mut nargs: u32 = 0;
        if !self.bc_uni_decl(ty, &mut d, &mut nargs) {
            // One opaque position.
            u.keys.push(UK_OPQ);
            u.keys.push(tn as u64 << 32 | bf);
            return true;
        }
        return self.bc_uni_walk_decl(ow, u, m, ext, tn, ty, d, nargs, behind, depth);
    }

    // `bc_uni_walk` of function type node `tn` (module `m`) along function-pointer type `y`: per class
    // of a lifetime the type fixes outside it (`ns`), the lifetime the node names there.
    fn bc_uni_walk_fn(
        self: &Self,
        ow: &bfx::Owner,
        u: &mut UniSt,
        m: ModuleId,
        tn: NodeId,
        y: &Ty,
        ns: u32,
        bf: u64,
        depth: i32,
    ) bool {
        let a = self.mod_ast(m);
        let n = *unsafe (*a).at_const(tn);
        {
            if n.kind != NodeKind::NODE_FUNCTION_TYPE {
                return false;
            }
            let k0 = u.keys.len();
            for _g in 0..ns {
                u.keys.push(0);
                u.keys.push(bf);
            }
            let ft = n.as_data.function_type;
            let mut kp: u32 = 0;
            for i in 0..ft.returns.len + ft.params.len {
                let r = i < ft.returns.len;
                let sl = if r {
                    unsafe (*a).list(ft.returns)[i as usize];
                } else {
                    unsafe (*a).list(ft.params)[(i - ft.returns.len) as usize];
                };
                let j = if r {
                    i;
                } else {
                    i - ft.returns.len;
                };
                let st = unsafe (*self.cur_ast()).sig_at(y, r, j);
                let f = if r {
                    UA_CO;
                } else {
                    UA_CONTRA;
                };
                if !self.bc_uni_outer(ow, u, m, unsafe (*a).slot_type_node(sl), st, y, &mut kp, k0, f, depth + 1) {
                    return false;
                }
            }
            for g in 0..ns as usize {
                if u.keys[k0 + 2 * g] == 0 {
                    return false;
                }
            }
            return true;
        }
    }

    // `bc_uni_walk` of type node `tn` along type `ty` of declaration `d` (`nargs` arguments).
    fn bc_uni_walk_decl(
        self: &Self,
        ow: &bfx::Owner,
        u: &mut UniSt,
        m: ModuleId,
        ext: NodeId,
        tn: NodeId,
        ty: TypeId,
        d: DefId,
        nargs: u32,
        behind: bool,
        depth: i32,
    ) bool {
        let a = self.mod_ast(m);
        let n = *unsafe (*a).at_const(tn);
        let bf = if behind {
            UA_BEHIND;
        } else {
            0;
        };
        if n.kind == NodeKind::NODE_SLICE_TYPE {
            if !self.bc_uni_view(d.module, d.node) || nargs != 1 {
                return false;
            }
            self.bc_uni_ltkey(ow, u, m, n.as_data.indirect_type.lifetime, tn, 0, bf);
            return self.bc_uni_walk(ow, u, m, ext, n.as_data.indirect_type.ty, self.bc_uni_arg(ty, 0), true, depth + 1);
        }
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let es = n.as_data.array_literal.elements;
            if es.len != nargs {
                return false;
            }
            for i in 0..nargs {
                if !self.bc_uni_walk(
                    ow,
                    u,
                    m,
                    ext,
                    unsafe (*a).list(es)[i as usize],
                    self.bc_uni_arg(ty, i),
                    behind,
                    depth + 1,
                ) {
                    return false;
                }
            }
            return true;
        }
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return false;
        }
        let pd = unsafe (*a).path_def(tn);
        if pd.node != d.node || pd.module != d.module {
            return false;
        }
        // A declaration's fields may hold its lifetimes and type arguments behind references of their
        // own: a value of it may be stored through at every position in it.
        let nlt = unsafe (*self.mod_ast(d.module)).lifetimes_of(d.node).len;
        let args = n.as_data.type_path.args;
        let mut k: u32 = 0;
        for i in 0..args.len {
            let aid = unsafe (*a).list(args)[i as usize];
            if unsafe (*a).at_const(aid).kind == NodeKind::NODE_LIFETIME && k < nlt {
                self.bc_uni_ltkey(ow, u, m, aid, tn, k, UA_BEHIND);
                k += 1;
            }
        }
        while k < nlt {
            self.bc_uni_ltkey(ow, u, m, NODE_NONE, tn, k, UA_BEHIND);
            k += 1;
        }
        let mut ti: u32 = 0;
        for i in 0..args.len {
            let aid = unsafe (*a).list(args)[i as usize];
            if unsafe (*a).at_const(aid).kind != NodeKind::NODE_LIFETIME {
                if ti >= nargs || !self.bc_uni_walk(ow, u, m, ext, aid, self.bc_uni_arg(ty, ti), true, depth + 1) {
                    return false;
                }
                ti += 1;
            }
        }
        // A defaulted argument the path leaves out must hold no lifetime position.
        while ti < nargs {
            if self.bc_uni_len(self.bc_uni_arg(ty, ti), 0) != 0 {
                return false;
            }
            ti += 1;
        }
        return true;
    }

    // Walk type node `tn` of module `m` along type `ty` of function-pointer type `fy`'s signature in
    // `Package::lt_walk` order, counting its lifetime positions in `kp`: the first lifetime named at a
    // position of class `LC_OUTER + g` keys slot `g` of the value (`u.keys[k0 + 2g]`). False when the
    // node does not spell the type's structure.
    fn bc_uni_outer(
        self: &Self,
        ow: &bfx::Owner,
        u: &mut UniSt,
        m: ModuleId,
        tn: NodeId,
        ty: TypeId,
        fy: &Ty,
        kp: &mut u32,
        k0: usize,
        vf: u64,
        depth: i32,
    ) bool {
        if ty == TYPE_NONE {
            return true;
        }
        if tn == NODE_NONE || depth > 16 {
            return false;
        }
        let a = self.mod_ast(m);
        let n = *unsafe (*a).at_const(tn);
        let y = *self.type_at(ty);
        if n.kind == NodeKind::NODE_TYPE_PATH {
            let gd = unsafe (*a).path_def(tn);
            if gd.node != NODE_NONE && unsafe (*self.mod_ast(gd.module)).at_const(gd.node).kind == NodeKind::NODE_GENERIC_PARAM {
                // The argument's positions: each one's class keys by its slot in the parameter.
                let mut j: u32 = 0;
                return self.bc_uni_outer_gen(
                    u,
                    UK_GEN | gd.module as u64 << 32 | gd.node as u64,
                    ty,
                    fy,
                    kp,
                    k0,
                    vf,
                    &mut j,
                    depth + 1,
                );
            }
        }
        if y.kind == TypeKind::TYPE_REFERENCE {
            if !n.is_ref_type() {
                return false;
            }
            self.bc_uni_outer_at(ow, u, m, n.as_data.indirect_type.lifetime, tn, 0, fy, kp, k0, vf);
            // Behind a `&mut`, a lifetime is invariant.
            let iv = if y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                UA_CO | UA_CONTRA;
            } else {
                vf;
            };
            return self.bc_uni_outer(ow, u, m, n.as_data.indirect_type.ty, y.as_data.elem, fy, kp, k0, iv, depth + 1);
        }
        if y.kind == TypeKind::TYPE_POINTER {
            return n.kind == NodeKind::NODE_POINTER_TYPE && self.bc_uni_outer(
                ow,
                u,
                m,
                n.as_data.indirect_type.ty,
                y.as_data.elem,
                fy,
                kp,
                k0,
                UA_CO | UA_CONTRA,
                depth + 1,
            );
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            return n.kind == NodeKind::NODE_ARRAY_TYPE && self.bc_uni_outer(
                ow,
                u,
                m,
                n.as_data.array_type.element,
                y.as_data.arr.elem,
                fy,
                kp,
                k0,
                vf,
                depth + 1,
            );
        }
        if y.fn_sig() || y.kind == TypeKind::TYPE_DYN || y.kind == TypeKind::TYPE_SLICE {
            return false;
        }
        let mut d = DefId { module: 0, node: NODE_NONE };
        let mut nargs: u32 = 0;
        if !self.bc_uni_decl(ty, &mut d, &mut nargs) {
            // No lifetime position (`lt_walk`).
            return true;
        }
        if n.kind == NodeKind::NODE_SLICE_TYPE {
            if nargs != 1 {
                return false;
            }
            self.bc_uni_outer_at(ow, u, m, n.as_data.indirect_type.lifetime, tn, 0, fy, kp, k0, vf);
            return self.bc_uni_outer(
                ow,
                u,
                m,
                n.as_data.indirect_type.ty,
                self.bc_uni_arg(ty, 0),
                fy,
                kp,
                k0,
                vf,
                depth + 1,
            );
        }
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let es = n.as_data.array_literal.elements;
            if es.len != nargs {
                return false;
            }
            for i in 0..nargs {
                if !self.bc_uni_outer(
                    ow,
                    u,
                    m,
                    unsafe (*a).list(es)[i as usize],
                    self.bc_uni_arg(ty, i),
                    fy,
                    kp,
                    k0,
                    vf,
                    depth + 1,
                ) {
                    return false;
                }
            }
            return true;
        }
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return false;
        }
        let pd = unsafe (*a).path_def(tn);
        if pd.node != d.node || pd.module != d.module {
            return false;
        }
        let nlt = unsafe (*self.mod_ast(d.module)).lifetimes_of(d.node).len;
        let args = n.as_data.type_path.args;
        let mut k: u32 = 0;
        for i in 0..args.len {
            let aid = unsafe (*a).list(args)[i as usize];
            if unsafe (*a).at_const(aid).kind == NodeKind::NODE_LIFETIME && k < nlt {
                self.bc_uni_outer_at(ow, u, m, aid, tn, k, fy, kp, k0, UA_CO | UA_CONTRA);
                k += 1;
            }
        }
        while k < nlt {
            self.bc_uni_outer_at(ow, u, m, NODE_NONE, tn, k, fy, kp, k0, UA_CO | UA_CONTRA);
            k += 1;
        }
        let mut ti: u32 = 0;
        for i in 0..args.len {
            let aid = unsafe (*a).list(args)[i as usize];
            if unsafe (*a).at_const(aid).kind != NodeKind::NODE_LIFETIME {
                if ti >= nargs || !self.bc_uni_outer(
                    ow,
                    u,
                    m,
                    aid,
                    self.bc_uni_arg(ty, ti),
                    fy,
                    kp,
                    k0,
                    UA_CO | UA_CONTRA,
                    depth + 1,
                ) {
                    return false;
                }
                ti += 1;
            }
        }
        return ti == nargs;
    }

    // `bc_uni_outer` of a type parameter `gk` (a key) standing for type `ty`: walk `ty` in
    // `Package::lt_walk` order, its layout slots counted in `j` (`bc_uni_len`), and key a position of
    // class `LC_OUTER + g` by (`gk`, its slot). False for a type whose positions and slots do not align.
    fn bc_uni_outer_gen(
        self: &Self,
        u: &mut UniSt,
        gk: u64,
        ty: TypeId,
        fy: &Ty,
        kp: &mut u32,
        k0: usize,
        vf: u64,
        j: &mut u32,
        depth: i32,
    ) bool {
        if ty == TYPE_NONE {
            return true;
        }
        if depth > 16 {
            return false;
        }
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_REFERENCE {
            self.bc_uni_outer_key(u, gk, *j, fy, kp, k0, vf);
            *j += 1;
            return self.bc_uni_outer_gen(u, gk, y.as_data.elem, fy, kp, k0, vf, j, depth + 1);
        }
        if y.kind == TypeKind::TYPE_POINTER {
            // Positions the classes count and no slot holds.
            return self.bc_uni_fn_walk(u, fy, y.as_data.elem, true, false, kp, depth + 1, 0, false);
        }
        if y.arr_like() {
            return self.bc_uni_outer_gen(u, gk, y.as_data.arr.elem, fy, kp, k0, vf, j, depth + 1);
        }
        if y.fn_sig() || y.kind == TypeKind::TYPE_DYN || y.kind == TypeKind::TYPE_SLICE {
            return false;
        }
        let mut d = DefId { module: 0, node: NODE_NONE };
        let mut nargs: u32 = 0;
        if self.bc_uni_decl(ty, &mut d, &mut nargs) {
            for _k in 0..unsafe (*self.mod_ast(d.module)).lifetimes_of(d.node).len {
                self.bc_uni_outer_key(u, gk, *j, fy, kp, k0, vf);
                *j += 1;
            }
            for i in 0..nargs {
                if !self.bc_uni_outer_gen(u, gk, self.bc_uni_arg(ty, i), fy, kp, k0, vf, j, depth + 1) {
                    return false;
                }
            }
            return true;
        }
        // A type parameter's or opaque type's one slot: no position the classes count.
        *j += self.bc_uni_len(ty, 0);
        return true;
    }

    // Lifetime position `kp` of function-pointer type `fy` at slot `j` of a type parameter `gk`
    // (`bc_uni_outer_gen`): its class's slot takes that key when it has none.
    fn bc_uni_outer_key(self: &Self, u: &mut UniSt, gk: u64, j: u32, fy: &Ty, kp: &mut u32, k0: usize, vf: u64) {
        let c = unsafe (*self.cur_ast()).sig_lt_class(fy, *kp);
        *kp += 1;
        if c < LC_OUTER || c == LC_TOO_MANY {
            return;
        }
        let g = k0 + 2 * (c - LC_OUTER) as usize;
        if g >= u.keys.len() {
            return;
        }
        u.keys.set(g + 1, u.keys[g + 1] | vf);
        if u.keys[g] == 0 {
            u.keys.set(g, gk);
            u.keys.set(g + 1, u.keys[g + 1] | j as u64);
        }
    }

    // Lifetime position `kp` of function-pointer type `fy`, named by lifetime node `lt` (elided: slot
    // `slot` of type node `at`): when its class is `LC_OUTER + g` and slot `g` has no key yet
    // (`bc_uni_outer`), the lifetime's key.
    fn bc_uni_outer_at(
        self: &Self,
        ow: &bfx::Owner,
        u: &mut UniSt,
        m: ModuleId,
        lt: NodeId,
        at: NodeId,
        slot: u32,
        fy: &Ty,
        kp: &mut u32,
        k0: usize,
        vf: u64,
    ) {
        let c = unsafe (*self.cur_ast()).sig_lt_class(fy, *kp);
        *kp += 1;
        if c < LC_OUTER || c == LC_TOO_MANY {
            return;
        }
        let g = k0 + 2 * (c - LC_OUTER) as usize;
        if g >= u.keys.len() {
            return;
        }
        u.keys.set(g + 1, u.keys[g + 1] | vf);
        if u.keys[g] != 0 {
            return;
        }
        let k1 = u.keys.len();
        self.bc_uni_ltkey(ow, u, m, lt, at, slot, 0);
        let key = u.keys[k1];
        let aux = u.keys[k1 + 1];
        u.keys.truncate(k1);
        if key >> 63 != 0 {
            u.keys.set(g, key);
            u.keys.set(g + 1, u.keys[g + 1] | aux);
        }
    }

    // The index of type parameter `g` among declaration `d`'s, or UNI_NONE.
    fn bc_uni_gen_index(self: &Self, d: DefId, g: DefId) u32 {
        if g.module != d.module {
            return UNI_NONE;
        }
        let gs = unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.aggregate.generics;
        for i in 0..gs.len {
            if unsafe (*self.mod_ast(d.module)).list(gs)[i as usize] == g.node {
                return i;
            }
        }
        return UNI_NONE;
    }

    // Replace the slots `pos[mark..]` of a value of struct, enum or instance type `pty` by those of
    // its field of declared type node `fnode` and type `fty`: the field's positions name the
    // declaration's lifetimes and type parameters, whose slots the value's are. False when the
    // field's type does not map (or, for `fty` not the field's type, does not match it).
    fn bc_uni_field(
        self: &Self,
        ow: &bfx::Owner,
        u: &mut UniSt,
        pty: TypeId,
        fnode: NodeId,
        fty: TypeId,
        pos: &mut Vector<u32>,
        mark: usize,
    ) bool {
        let mut d = DefId { module: 0, node: NODE_NONE };
        let mut nargs: u32 = 0;
        if fnode == NODE_NONE || !self.bc_uni_decl(pty, &mut d, &mut nargs) {
            return false;
        }
        let w0 = u.wdecl;
        let k0 = u.keys.len();
        let a0 = u.wargs.len();
        u.wdecl = d;
        for i in 0..nargs {
            u.wargs.push(self.bc_uni_arg(pty, i));
        }
        // The walk reads the declaration's own arguments from the top of `wargs`.
        let mut wa = replace(&mut u.wargs, Vector::<TypeId>::new());
        let mut own = Vector::<TypeId>::new();
        for i in a0..wa.len() {
            own.push(wa[i]);
        }
        wa.truncate(a0);
        u.wargs = own;
        let ok = self.bc_uni_walk(ow, u, d.module, NODE_NONE, fnode, fty, false, 0);
        u.wargs = wa;
        u.wdecl = w0;
        if !ok {
            u.keys.truncate(k0);
            return false;
        }
        let da = self.mod_ast(d.module);
        let lts = unsafe (*da).lifetimes_of(d.node);
        let pl = pos.len();
        let mut i = k0;
        while i + 1 < u.keys.len() {
            let key = u.keys[i];
            let aux = u.keys[i + 1];
            i += 2;
            if key == UK_STATIC {
                pos.push(POS_STATIC);
                continue;
            }
            let mut at = POS_NONE;
            if key >> 63 != 0 {
                for k in 0..lts.len {
                    if ow.lt_tok(d.module, unsafe (*da).list(lts)[k as usize]) == key {
                        at = (mark + k as usize) as u32;
                    }
                }
            } else if (key & UK_GEN) != 0 {
                let gi = self.bc_uni_gen_index(
                    d,
                    DefId { module: (key >> 32 & 0xFFFFFF) as ModuleId, node: (key & 0xFFFFFFFFu64) as NodeId },
                );
                if gi != UNI_NONE && gi < nargs {
                    let mut off = lts.len;
                    for g in 0..gi {
                        off += self.bc_uni_len(self.bc_uni_arg(pty, g), 0);
                    }
                    at = (mark + (off + (aux & 0xFFFF) as u32) as usize) as u32;
                }
            }
            if at == POS_NONE || at as usize >= pl {
                pos.truncate(pl);
                u.keys.truncate(k0);
                return false;
            }
            pos.push(pos[at as usize]);
        }
        u.keys.truncate(k0);
        let cnt = pos.len() - pl;
        for j in 0..cnt {
            pos.set(mark + j, pos[pl + j]);
        }
        pos.truncate(mark + cnt);
        return true;
    }

    // The declared type node of the field projection `pj` reads of a value of type `ty` (a
    // variant's payload after a downcast to `variant`), or NODE_NONE.
    fn bc_uni_field_node(self: &Self, ty: TypeId, variant: NodeId, pj: &ir::Projection) NodeId {
        let mut d = DefId { module: 0, node: NODE_NONE };
        let mut nargs: u32 = 0;
        if !self.bc_uni_decl(ty, &mut d, &mut nargs) {
            return NODE_NONE;
        }
        let da = self.mod_ast(d.module);
        let ms = if variant != NODE_NONE {
            unsafe (*da).at_const(variant).as_data.variant.payload;
        } else {
            unsafe (*da).at_const(d.node).as_data.aggregate.members;
        };
        let mut mn = NODE_NONE;
        if pj.sub != NODE_NONE {
            for j in 0..ms.len {
                if unsafe (*da).list(ms)[j as usize] == pj.sub {
                    mn = pj.sub;
                }
            }
        } else if pj.data < ms.len {
            mn = unsafe (*da).list(ms)[pj.data as usize];
        }
        if mn != NODE_NONE && unsafe (*da).at_const(mn).kind == NodeKind::NODE_FIELD {
            return unsafe (*da).at_const(mn).as_data.field.ty;
        }
        return mn;
    }

    // Append to `out` the slots of place `p`'s value within origin `o`'s (its base local's): per
    // lifetime position of the place's type, a slot, POS_STATIC (a field declared `'static`) or
    // POS_NONE (behind a raw pointer). False when a projection leaves what the check maps.
    fn bc_uni_project(
        self: &Self,
        ow: &bfx::Owner,
        u: &mut UniSt,
        body: &ir::CoreBody,
        o: u32,
        p: ir::PlaceId,
        out: &mut Vector<u32>,
    ) bool {
        let mark = out.len();
        if u.opq[o as usize] {
            return false;
        }
        for i in 0..u.cnt[o as usize] {
            out.push(u.base[o as usize] + i);
        }
        let pl = *body.places.at(p as usize);
        let mut ty = body.locals.at(pl.base as usize).ty;
        let mut variant = NODE_NONE;
        for k in 0..pl.proj_len {
            let pj = *body.projections.at((pl.proj_start + k) as usize);
            let y = *self.type_at(ty);
            if pj.kind == ir::PJ_DEREF || pj.kind == ir::PJ_INDEX_OP || pj.kind == ir::PJ_INDEX_CONST {
                let mut d = DefId { module: 0, node: NODE_NONE };
                let mut nargs: u32 = 0;
                let view = pj.kind != ir::PJ_DEREF && self.bc_uni_decl(ty, &mut d, &mut nargs) && self.bc_uni_view(
                    d.module,
                    d.node,
                );
                if y.kind == TypeKind::TYPE_REFERENCE && pj.kind == ir::PJ_DEREF || view {
                    // The pointee or element: past the reference's or view's own position.
                    for j in mark..out.len() - 1 {
                        out.set(j, out[j + 1]);
                    }
                    out.truncate(out.len() - 1);
                } else if y.kind == TypeKind::TYPE_POINTER {
                    out.truncate(mark);
                    for _j in 0..self.bc_uni_len(pj.ty, 0) {
                        out.push(POS_NONE);
                    }
                } else if y.kind != TypeKind::TYPE_ARRAY && !y.is_vec() {
                    return false;
                }
            } else if pj.kind == ir::PJ_DOWNCAST {
                variant = pj.sub;
            } else if pj.kind == ir::PJ_FIELD {
                if !self.bc_uni_field(ow, u, ty, self.bc_uni_field_node(ty, variant, &pj), pj.ty, out, mark) {
                    return false;
                }
                variant = NODE_NONE;
            } else {
                return false;
            }
            ty = pj.ty;
        }
        return out.len() - mark == self.bc_uni_len(pl.ty, 0) as usize;
    }

    // Does place `p` read through a reference or a view (a step `bc_uni_project` leaves the
    // reference's or view's own position at)?
    fn bc_uni_through(self: &Self, body: &ir::CoreBody, p: ir::PlaceId) bool {
        let pl = *body.places.at(p as usize);
        let mut ty = body.locals.at(pl.base as usize).ty;
        for k in 0..pl.proj_len {
            let pj = *body.projections.at((pl.proj_start + k) as usize);
            let mut d = DefId { module: 0, node: NODE_NONE };
            let mut nargs: u32 = 0;
            if pj.kind == ir::PJ_DEREF && self.type_at(ty).kind == TypeKind::TYPE_REFERENCE || (pj.kind == ir::PJ_INDEX_OP || pj.kind == ir::PJ_INDEX_CONST) && self.bc_uni_decl(
                ty,
                &mut d,
                &mut nargs,
            ) && self.bc_uni_view(d.module, d.node) {
                return true;
            }
            ty = pj.ty;
        }
        return false;
    }

    // Append to `out` the slots of each place a value of type `w` may take within a value of type
    // `c` whose slots are `src[at..]`: the value itself, a reference's or view's pointee, an array's
    // element, a type argument's value, a field of type `w`. Returns how many.
    fn bc_uni_locate(
        self: &Self,
        ow: &bfx::Owner,
        u: &mut UniSt,
        c: TypeId,
        src: &Vector<u32>,
        at: usize,
        w: TypeId,
        out: &mut Vector<u32>,
        depth: i32,
    ) u32 {
        let lc = self.bc_uni_len(c, 0);
        if depth > 4 || lc > UNI_SLOTS_MAX || at + lc as usize > src.len() {
            return 0;
        }
        if c == w {
            for i in 0..lc {
                out.push(src[at + i as usize]);
            }
            return 1;
        }
        let y = *self.type_at(c);
        if y.kind == TypeKind::TYPE_REFERENCE {
            return self.bc_uni_locate(ow, u, y.as_data.elem, src, at + 1, w, out, depth + 1);
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            return self.bc_uni_locate(ow, u, y.as_data.arr.elem, src, at, w, out, depth + 1);
        }
        let mut d = DefId { module: 0, node: NODE_NONE };
        let mut nargs: u32 = 0;
        if !self.bc_uni_decl(c, &mut d, &mut nargs) {
            return 0;
        }
        let mut n: u32 = 0;
        let mut off = (unsafe (*self.mod_ast(d.module)).lifetimes_of(d.node).len) as usize;
        for i in 0..nargs {
            let ai = self.bc_uni_arg(c, i);
            n += self.bc_uni_locate(ow, u, ai, src, at + off, w, out, depth + 1);
            off += self.bc_uni_len(ai, 0) as usize;
        }
        let dn = *unsafe (*self.mod_ast(d.module)).at_const(d.node);
        if dn.kind == NodeKind::NODE_STRUCT {
            let ms = dn.as_data.aggregate.members;
            for j in 0..ms.len {
                let fd = unsafe (*self.mod_ast(d.module)).list(ms)[j as usize];
                if unsafe (*self.mod_ast(d.module)).at_const(fd).kind != NodeKind::NODE_FIELD {
                    continue;
                }
                let mark = out.len();
                for i in 0..lc {
                    out.push(src[at + i as usize]);
                }
                if self.bc_uni_field(
                    ow,
                    u,
                    c,
                    unsafe (*self.mod_ast(d.module)).at_const(fd).as_data.field.ty,
                    w,
                    out,
                    mark,
                ) {
                    n += 1;
                } else {
                    out.truncate(mark);
                }
            }
        }
        return n;
    }

    // The slot pairs of subset edge `k` (`UniSt::emap`), mapped once: where the operation at the
    // edge's point puts each position of the source origin's value within the target's (an origin,
    // or the parameter local a placeholder stands for). EM_COARSE when it cannot tell.
    fn bc_uni_map(self: &Self, ow: &mut bfx::Owner, u: &mut UniSt, body: &ir::CoreBody, f: &bfx::BodyFacts, k: u32) u64 {
        if u.emap[k as usize] != EM_NONE {
            return u.emap[k as usize];
        }
        let e = *f.subsets.at(k as usize);
        let mut tor = e.to;
        if e.to < f.nuniversal {
            let l = u.phl[e.to as usize];
            tor = if l == bfx::BF_NONE {
                bfx::BF_NONE;
            } else {
                f.local_origin[l as usize];
            };
        }
        let mut r = EM_COARSE;
        if tor != bfx::BF_NONE && !u.opq[e.from as usize] && !u.opq[tor as usize] {
            let start = u.pairs.len();
            let mut pa = replace(&mut u.pa, Vector::<u32>::new());
            let mut pb = replace(&mut u.pb, Vector::<u32>::new());
            let mut pc = replace(&mut u.pc, Vector::<u32>::new());
            pa.truncate(0);
            pb.truncate(0);
            pc.truncate(0);
            if self.bc_uni_map_op(ow, u, body, f, &e, tor, &mut pa, &mut pb, &mut pc) {
                r = start as u64 << 32 | (u.pairs.len() - start) as u64;
            } else {
                u.pairs.truncate(start);
            }
            u.pa = pa;
            u.pb = pb;
            u.pc = pc;
        }
        u.emap.set(k as usize, r);
        return r;
    }

    // The slots of place `p`'s value within target origin `tor` (whose local is `tl`) into `pb`, one
    // list per place it may be: the place itself when it is of `tl`, else each place of its type
    // within `tl`'s value (`bc_uni_locate`). Returns how many.
    fn bc_uni_dest(
        self: &Self,
        ow: &bfx::Owner,
        u: &mut UniSt,
        body: &ir::CoreBody,
        tor: u32,
        tl: u32,
        p: ir::PlaceId,
        pb: &mut Vector<u32>,
        pc: &mut Vector<u32>,
    ) u32 {
        pb.truncate(0);
        if body.places.at(p as usize).base == tl {
            if self.bc_uni_project(ow, u, body, tor, p, pb) {
                return 1;
            }
            pb.truncate(0);
            return 0;
        }
        pc.truncate(0);
        for i in 0..u.cnt[tor as usize] {
            pc.push(u.base[tor as usize] + i);
        }
        return self.bc_uni_locate(ow, u, body.locals.at(tl as usize).ty, pc, 0, body.places.at(p as usize).ty, pb, 0);
    }

    // Emit the pairs of edge `e` from the operation at its point (see `bc_uni_map`); false when it
    // cannot tell where a position lands.
    fn bc_uni_map_op(
        self: &Self,
        ow: &mut bfx::Owner,
        u: &mut UniSt,
        body: &ir::CoreBody,
        f: &bfx::BodyFacts,
        e: &bfx::SubsetAt,
        tor: u32,
        pa: &mut Vector<u32>,
        pb: &mut Vector<u32>,
        pc: &mut Vector<u32>,
    ) bool {
        let xl = f.origin_local[e.from as usize];
        let tl = f.origin_local[tor as usize];
        let mut si: u32 = 0;
        let blk = *body.blocks.at(self.bc_uni_site(f, e.point, &mut si));
        if si >= blk.stmt_len {
            return blk.term.kind == ir::TM_CALL && self.bc_uni_map_call(
                ow,
                u,
                body,
                e,
                xl,
                tor,
                tl,
                &blk.term,
                pa,
                pb,
                pc,
            );
        }
        let st = *body.statements.at((blk.stmt_start + si) as usize);
        if st.kind != ir::ST_ASSIGN {
            return false;
        }
        let rv = *body.rvalues.at(st.rvalue as usize);
        let dty = body.places.at(st.place as usize).ty;
        // The borrowed place of a borrow (an array's view borrows the array).
        let mut q: ir::PlaceId = ir::IR_NONE;
        if rv.kind == ir::RV_REF || rv.kind == ir::RV_SLICE {
            q = rv.a;
        } else if rv.kind == ir::RV_USE && rv.b != 0 {
            let op = *body.operands.at(rv.a as usize);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                q = op.data;
            }
        }
        if q != ir::IR_NONE && rv.kind != ir::RV_SLICE && body.places.at(st.place as usize).base == xl && body.places.at(
            q as usize,
        ).base == tl {
            // What a mutable borrow's holder stores behind it lands in the borrowed place.
            if !self.bc_uni_project(ow, u, body, e.from, st.place, pa) || !self.bc_uni_project(ow, u, body, tor, q, pb) || pa.len() != pb.len() + 1 {
                return false;
            }
            for i in 0..pb.len() {
                u.pair(pa[i + 1], pb[i]);
            }
            return true;
        }
        let nc = self.bc_uni_dest(ow, u, body, tor, tl, st.place, pb, pc);
        let lv = self.bc_uni_len(dty, 0) as usize;
        if nc == 0 || pb.len() != nc as usize * lv {
            return false;
        }
        if q != ir::IR_NONE {
            if body.places.at(q as usize).base != xl {
                return false;
            }
            pa.truncate(0);
            if !self.bc_uni_project(ow, u, body, e.from, q, pa) {
                return false;
            }
            // A borrow's or view's own position holds the loan; the borrowed value lies behind it.
            if rv.kind == ir::RV_SLICE {
                // The elements, wherever the container holds them.
                pc.truncate(0);
                let mut d = DefId { module: 0, node: NODE_NONE };
                let mut nargs: u32 = 0;
                if !self.bc_uni_decl(dty, &mut d, &mut nargs) || nargs != 1 {
                    return false;
                }
                let elem = self.bc_uni_arg(dty, 0);
                let le = self.bc_uni_len(elem, 0) as usize;
                let ne = self.bc_uni_locate(ow, u, body.places.at(q as usize).ty, pa, 0, elem, pc, 0) as usize;
                if le + 1 != lv || ne == 0 && le != 0 {
                    return false;
                }
                for c in 0..nc as usize {
                    for j in 0..ne {
                        for i in 0..le {
                            u.pair(pc[j * le + i], pb[c * lv + 1 + i]);
                        }
                    }
                }
                return true;
            }
            if pa.len() + 1 != lv {
                return false;
            }
            for c in 0..nc as usize {
                for i in 0..pa.len() {
                    u.pair(pa[i], pb[c * lv + 1 + i]);
                }
            }
            return true;
        }
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_CAST || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_REPEAT || rv.kind == ir::RV_DYN {
            let op = *body.operands.at(rv.a as usize);
            if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE || body.places.at(op.data as usize).base != xl {
                return false;
            }
            pa.truncate(0);
            if !self.bc_uni_project(ow, u, body, e.from, op.data, pa) {
                return false;
            }
            if rv.kind == ir::RV_DYN {
                // An erased object holds what its value holds, at its one position.
                for c in 0..nc as usize {
                    for i in 0..pa.len() {
                        for j in 0..lv {
                            u.pair(pa[i], pb[c * lv + j]);
                        }
                    }
                }
                return true;
            }
            if pa.len() != lv {
                return false;
            }
            for c in 0..nc as usize {
                for i in 0..lv {
                    u.pair(pa[i], pb[c * lv + i]);
                }
            }
            return true;
        }
        if rv.kind == ir::RV_AGGREGATE || rv.kind == ir::RV_CLOSURE {
            let mut hit = false;
            for i in 0..rv.b {
                let oi = body.oper_pool[(rv.a + i) as usize];
                if oi == ir::IR_NONE {
                    continue;
                }
                let op = *body.operands.at(oi as usize);
                if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE || body.places.at(op.data as usize).base != xl {
                    continue;
                }
                hit = true;
                pa.truncate(0);
                if !self.bc_uni_project(ow, u, body, e.from, op.data, pa) {
                    return false;
                }
                for c in 0..nc as usize {
                    if rv.kind == ir::RV_CLOSURE {
                        // A closure holds what it captures, at its one position.
                        for s in 0..pa.len() {
                            for j in 0..lv {
                                u.pair(pa[s], pb[c * lv + j]);
                            }
                        }
                        continue;
                    }
                    // The member's positions within the built value (an array's element is the value's).
                    pc.truncate(0);
                    for j in 0..lv {
                        pc.push(pb[c * lv + j]);
                    }
                    if rv.c != ir::AGG_ARRAY {
                        let mut fnode = NODE_NONE;
                        let mut d = DefId { module: 0, node: NODE_NONE };
                        let mut nargs: u32 = 0;
                        if self.bc_uni_decl(dty, &mut d, &mut nargs) {
                            let da = self.mod_ast(d.module);
                            let ms = if rv.c == ir::AGG_VARIANT {
                                unsafe (*da).at_const(rv.item.node).as_data.variant.payload;
                            } else {
                                unsafe (*da).at_const(d.node).as_data.aggregate.members;
                            };
                            if i < ms.len {
                                fnode = unsafe (*da).list(ms)[i as usize];
                                if unsafe (*da).at_const(fnode).kind == NodeKind::NODE_FIELD {
                                    fnode = unsafe (*da).at_const(fnode).as_data.field.ty;
                                }
                            }
                        }
                        if !self.bc_uni_field(ow, u, dty, fnode, body.places.at(op.data as usize).ty, pc, 0) {
                            return false;
                        }
                    }
                    if pc.len() != pa.len() {
                        return false;
                    }
                    for s in 0..pa.len() {
                        u.pair(pa[s], pc[s]);
                    }
                }
            }
            return hit;
        }
        return false;
    }

    // The keys of argument place type `qty` passed as callee parameter type node `pn` (module `m`,
    // `Self` naming extend `ext`'s target), appended to `u.keys`: a reference parameter taking a
    // place that is no reference borrows it for the call, so all its positions lie behind it.
    fn bc_uni_arg_keys(self: &Self, ow: &bfx::Owner, u: &mut UniSt, m: ModuleId, ext: NodeId, pn: NodeId, qty: TypeId) bool {
        let tn = self.bc_uni_unself(m, ext, pn);
        if tn == NODE_NONE {
            return false;
        }
        let n = *unsafe (*self.mod_ast(m)).at_const(tn);
        let yk = self.type_at(qty).kind;
        if n.is_ref_type() && yk != TypeKind::TYPE_REFERENCE && yk != TypeKind::TYPE_POINTER {
            return self.bc_uni_walk(ow, u, m, ext, n.as_data.indirect_type.ty, qty, true, 0);
        }
        return self.bc_uni_walk(ow, u, m, ext, tn, qty, false, 0);
    }

    // Does type parameter `g` have a bound naming a type or a lifetime (a method of it may store a
    // value of another type into one of it, or make one of it from one)?
    fn bc_uni_gen_open(self: &Self, g: DefId) bool {
        let ga = self.mod_ast(g.module);
        if unsafe (*ga).at_const(g.node).kind == NodeKind::NODE_INTERFACE {
            // An interface's `Self`: its methods may store what the interface's parameters name.
            return unsafe (*ga).at_const(g.node).as_data.interface_def.generics.len != 0 || unsafe (*ga).lifetimes_of(
                g.node,
            ).len != 0;
        }
        let bs = unsafe (*ga).at_const(g.node).as_data.generic_param.bounds;
        for i in 0..bs.len {
            let b = *unsafe (*ga).at_const(unsafe (*ga).list(bs)[i as usize]);
            if b.kind != NodeKind::NODE_TYPE_PATH || b.as_data.type_path.args.len != 0 {
                return true;
            }
        }
        for w in 0..unsafe (*ga).where_bounds.len() {
            if unsafe (*ga).where_scope(w, g.node, NODE_NONE) != WHERE_NONE {
                return true;
            }
        }
        return false;
    }

    // Pair each argument position of `u.bind` whose value may land at a callee output position of
    // key `key` (aux `aux`) with target slot `dst`: one of the same lifetime, of one the callee
    // declares to outlive it (`rel`), or of `'static`; the same position of the same type
    // parameter; any one where either is a type parameter whose bounds name other types.
    fn bc_uni_take(self: &Self, ow: &bfx::Owner, u: &mut UniSt, rel: u64, key: u64, aux: u64, dst: u32) {
        if dst >= POS_STATIC {
            return;
        }
        let gen = (key & UK_GEN) != 0 && key >> 63 == 0;
        let open = gen && self.bc_uni_gen_open(
            DefId { module: (key >> 32 & 0xFFFFFF) as ModuleId, node: (key & 0xFFFFFFFFu64) as NodeId },
        );
        let lt = key >> 63 != 0 || (key & UK_EL) != 0 || key == UK_STATIC;
        let mut toks = replace(&mut u.toks, Vector::<u64>::new());
        toks.truncate(0);
        if key >> 63 != 0 {
            toks.push(key);
            ow.rel_widen(rel, true, &mut toks);
        }
        let mut i: usize = 0;
        while i + 2 < u.bind.len() {
            let bk = u.bind[i];
            let ba = u.bind[i + 1];
            let src = u.bind[i + 2] as u32;
            i += 3;
            let bgen = (bk & UK_GEN) != 0 && bk >> 63 == 0;
            let ok = open || bk == UK_ANY || bgen && self.bc_uni_gen_open(
                DefId { module: (bk >> 32 & 0xFFFFFF) as ModuleId, node: (bk & 0xFFFFFFFFu64) as NodeId },
            ) || bk == key && (!gen || (ba & 0xFFFF) == (aux & 0xFFFF)) || lt && (bk == UK_STATIC || toks.contains(&bk));
            if ok {
                u.pair(src, dst);
            }
        }
        u.toks = toks;
    }

    // The lifetime positions of callee type node `tn0` (module `m`, `Self` naming extend `ext`'s
    // target) as the elision rule counts them, the key of the first in walk order into `first`.
    fn bc_uni_first(
        self: &Self,
        ow: &bfx::Owner,
        u: &mut UniSt,
        m: ModuleId,
        ext: NodeId,
        tn0: NodeId,
        depth: i32,
        first: &mut u64,
    ) u32 {
        let tn = self.bc_uni_unself(m, ext, tn0);
        if tn == NODE_NONE || depth > 6 {
            return 0;
        }
        let a = self.mod_ast(m);
        let n = *unsafe (*a).at_const(tn);
        if n.has_lt_slot() {
            self.bc_uni_firstkey(ow, u, m, n.as_data.indirect_type.lifetime, tn, 0, first);
            return 1 + self.bc_uni_first(ow, u, m, ext, n.as_data.indirect_type.ty, depth + 1, first);
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            return self.bc_uni_first(ow, u, m, ext, n.as_data.array_type.element, depth + 1, first);
        }
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let es = n.as_data.array_literal.elements;
            let mut c: u32 = 0;
            for i in 0..es.len {
                c += self.bc_uni_first(ow, u, m, ext, unsafe (*a).list(es)[i as usize], depth + 1, first);
            }
            return c;
        }
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return 0;
        }
        let d = unsafe (*a).path_def(tn);
        let mut nlt: u32 = 0;
        if d.node != NODE_NONE && unsafe (*self.mod_ast(d.module)).at_const(d.node).kind != NodeKind::NODE_GENERIC_PARAM {
            nlt = unsafe (*self.mod_ast(d.module)).lifetimes_of(d.node).len;
        }
        let args = n.as_data.type_path.args;
        let mut c: u32 = 0;
        let mut named: u32 = 0;
        for i in 0..args.len {
            let aid = unsafe (*a).list(args)[i as usize];
            if unsafe (*a).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                if named < nlt {
                    self.bc_uni_firstkey(ow, u, m, aid, tn, named, first);
                    named += 1;
                }
            } else {
                c += self.bc_uni_first(ow, u, m, ext, aid, depth + 1, first);
            }
        }
        if named < nlt {
            self.bc_uni_firstkey(ow, u, m, NODE_NONE, tn, named, first);
        }
        return c + nlt;
    }

    // Set `first` to the key of lifetime node `lt` (`bc_uni_ltkey`) when it holds none yet.
    fn bc_uni_firstkey(
        self: &Self,
        ow: &bfx::Owner,
        u: &mut UniSt,
        m: ModuleId,
        lt: NodeId,
        at: NodeId,
        slot: u32,
        first: &mut u64,
    ) {
        if *first != 0 {
            return;
        }
        let k0 = u.keys.len();
        self.bc_uni_ltkey(ow, u, m, lt, at, slot, 0);
        *first = u.keys[k0];
        u.keys.truncate(k0);
    }

    // The keys of every argument's and result's positions at call `term` into `u.ka`, part `i`'s from
    // `u.kof[i]` to `u.kof[i + 1]` (the arguments, then the results; a variadic argument has none),
    // and the callee's outlives relation into `rel`: by the callee's signature, else by a function
    // value's type. False when a type does not line up or a position is opaque.
    fn bc_uni_call_keys(
        self: &Self,
        ow: &mut bfx::Owner,
        u: &mut UniSt,
        body: &ir::CoreBody,
        term: &ir::Terminator,
        rel: &mut u64,
    ) bool {
        u.ka.truncate(0);
        u.kof.truncate(0);
        *rel = 0;
        let c = term.callee;
        if c.node == NODE_NONE {
            return self.bc_uni_fn_keys(u, body, term);
        }
        let cm = c.module;
        let ca = self.mod_ast(cm);
        let fnn = *unsafe (*ca).at_const(c.node);
        if fnn.kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        let ps = fnn.as_data.function.params;
        let rets = fnn.as_data.function.returns;
        let mut ext = unsafe (*ca).container_of(c.node);
        if ext != NODE_NONE && unsafe (*ca).at_const(ext).kind != NodeKind::NODE_EXTEND && unsafe (*ca).at_const(ext).kind != NodeKind::NODE_INTERFACE {
            ext = NODE_NONE;
        }
        *rel = ow.callee_rel(c);
        // An elided return lifetime is the first lifetime position of a `self` parameter having one,
        // else the only lifetime position of the parameters (`tc_elision_source`).
        let mut etok: u64 = 0;
        let mut inputs: u32 = 0;
        for i in 0..ps.len {
            let pid = unsafe (*ca).list(ps)[i as usize];
            let mut first: u64 = 0;
            let cnt = self.bc_uni_first(ow, u, cm, ext, unsafe (*ca).slot_type_node(pid), 0, &mut first);
            if i == 0 && cnt != 0 && tc::span_is(
                self.mod_src(cm),
                unsafe (*ca).at_const(unsafe (*ca).at_const(pid).as_data.parameter.name).as_data.name.text,
                "self",
            ) {
                etok = first;
                inputs = 1;
                break;
            }
            if cnt != 0 {
                etok = first;
            }
            inputs += cnt;
        }
        if inputs != 1 {
            etok = 0;
        }
        for j in 0..term.args_len {
            u.kof.push(u.ka.len() as u32);
            let oi = body.oper_pool[(term.args_start + j) as usize];
            if j >= ps.len || oi == ir::IR_NONE {
                continue;
            }
            let op = *body.operands.at(oi as usize);
            if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
                continue;
            }
            let k0 = u.keys.len();
            let qty = body.places.at(op.data as usize).ty;
            if !self.bc_uni_arg_keys(
                ow,
                u,
                cm,
                ext,
                unsafe (*ca).slot_type_node(unsafe (*ca).list(ps)[j as usize]),
                qty,
            ) || u.keys.len() - k0 != 2 * self.bc_uni_len(qty, 0) as usize {
                u.keys.truncate(k0);
                return false;
            }
            for i in k0..u.keys.len() {
                u.ka.push(u.keys[i]);
            }
            u.keys.truncate(k0);
        }
        for d in 0..term.dests_len {
            u.kof.push(u.ka.len() as u32);
            if d >= rets.len {
                continue;
            }
            let dty = body.places.at(body.dest_pool[(term.dests_start + d) as usize] as usize).ty;
            let k0 = u.keys.len();
            if !self.bc_uni_walk(
                ow,
                u,
                cm,
                ext,
                unsafe (*ca).slot_type_node(unsafe (*ca).list(rets)[d as usize]),
                dty,
                false,
                0,
            ) || u.keys.len() - k0 != 2 * self.bc_uni_len(dty, 0) as usize {
                u.keys.truncate(k0);
                return false;
            }
            for i in 0..(u.keys.len() - k0) / 2 {
                let mut key = u.keys[k0 + 2 * i];
                if key >> 63 == 0 && (key & UK_EL) != 0 {
                    if etok == 0 {
                        u.keys.truncate(k0);
                        return false;
                    }
                    key = etok;
                }
                u.ka.push(key);
                u.ka.push(u.keys[k0 + 2 * i + 1]);
            }
            u.keys.truncate(k0);
        }
        u.kof.push(u.ka.len() as u32);
        for i in 0..u.ka.len() / 2 {
            if u.ka[2 * i] == UK_OPQ {
                return false;
            }
        }
        return true;
    }

    // The keys of a call through a value of function-pointer type (`bc_uni_call_keys`): at each
    // lifetime position the type's class there (`Ast::sig_lt_class`; the default classes give an
    // elided result the only input position), at a type parameter's position the type itself.
    fn bc_uni_fn_keys(self: &Self, u: &mut UniSt, body: &ir::CoreBody, term: &ir::Terminator) bool {
        if term.a == ir::IR_NONE {
            return false;
        }
        let fo = *body.operands.at(term.a as usize);
        if fo.kind != ir::OP_COPY && fo.kind != ir::OP_MOVE {
            return false;
        }
        let a = self.cur_ast();
        let mut fy = *self.type_at(body.places.at(fo.data as usize).ty);
        if fy.kind == TypeKind::TYPE_DYN && unsafe (*a).dyn_fn_sig(&fy) != TYPE_NONE {
            fy = *self.type_at(unsafe (*a).dyn_fn_sig(&fy));
        }
        if !fy.fn_sig() || self.bc_uni_wide(&fy) {
            return false;
        }
        let it = *unsafe (*a).instance(fy.as_data.fnp.sig);
        let nres = it.module as u32;
        let npar = it.decl;
        let ncls = unsafe (*a).sig_lt_len(&fy);
        // The classes number the results' positions, then the parameters' (`Package::lt_walk`).
        let mut nrpos: u32 = 0;
        for r in 0..nres {
            if !self.bc_uni_fn_walk(u, &fy, unsafe (*a).sig_at(&fy, true, r), false, false, &mut nrpos, 0, ncls, false) {
                return false;
            }
        }
        let mut npos = nrpos;
        for p in 0..npar {
            if !self.bc_uni_fn_walk(u, &fy, unsafe (*a).sig_at(&fy, false, p), false, false, &mut npos, 0, ncls, false) {
                return false;
            }
        }
        let single = ncls == 0 && npos - nrpos == 1;
        let mut kp = nrpos;
        for j in 0..term.args_len {
            u.kof.push(u.ka.len() as u32);
            if j >= npar {
                continue;
            }
            let pt = unsafe (*a).sig_at(&fy, false, j);
            let k0 = u.keys.len();
            let oi = body.oper_pool[(term.args_start + j) as usize];
            let ok = self.bc_uni_fn_walk(u, &fy, pt, false, true, &mut kp, 0, ncls, single);
            let mut lq: usize = 0;
            if oi != ir::IR_NONE && (body.operands.at(oi as usize).kind == ir::OP_COPY || body.operands.at(oi as usize).kind == ir::OP_MOVE) {
                lq = self.bc_uni_len(body.places.at(body.operands.at(oi as usize).data as usize).ty, 0) as usize;
            }
            if !ok || u.keys.len() - k0 != 2 * lq && lq != 0 {
                u.keys.truncate(k0);
                return false;
            }
            if lq != 0 {
                for i in k0..u.keys.len() {
                    u.ka.push(u.keys[i]);
                }
            }
            u.keys.truncate(k0);
        }
        kp = 0;
        for d in 0..term.dests_len {
            u.kof.push(u.ka.len() as u32);
            if d >= nres {
                continue;
            }
            let k0 = u.keys.len();
            let dty = body.places.at(body.dest_pool[(term.dests_start + d) as usize] as usize).ty;
            if !self.bc_uni_fn_walk(u, &fy, unsafe (*a).sig_at(&fy, true, d), false, true, &mut kp, 0, ncls, single) || u.keys.len() - k0 != 2 * self.bc_uni_len(
                dty,
                0,
            ) as usize {
                u.keys.truncate(k0);
                return false;
            }
            for i in k0..u.keys.len() {
                u.ka.push(u.keys[i]);
            }
            u.keys.truncate(k0);
        }
        u.kof.push(u.ka.len() as u32);
        return true;
    }

    // Walk type `ty` of function-pointer type `fy`'s signature in `Package::lt_walk` order, counting
    // its lifetime positions in `kpos`, and (`emit`) append to `u.keys` a key per position of the
    // value's own layout (`bc_uni_len`): a lifetime position's class (`bc_uni_fn_key`), a type
    // parameter's type. False for a position the walk cannot key (a nested function or erased type).
    fn bc_uni_fn_walk(
        self: &Self,
        u: &mut UniSt,
        fy: &Ty,
        ty: TypeId,
        behind: bool,
        emit: bool,
        kpos: &mut u32,
        depth: i32,
        ncls: u32,
        single: bool,
    ) bool {
        if ty == TYPE_NONE {
            return true;
        }
        if depth > 16 {
            return false;
        }
        let y = *self.type_at(ty);
        let bf = if behind {
            UA_BEHIND;
        } else {
            0;
        };
        if y.kind == TypeKind::TYPE_REFERENCE {
            if emit && !self.bc_uni_fn_key(u, fy, *kpos, ncls, single, bf) {
                return false;
            }
            *kpos += 1;
            return self.bc_uni_fn_walk(u, fy, y.as_data.elem, true, emit, kpos, depth + 1, ncls, single);
        }
        if y.kind == TypeKind::TYPE_POINTER {
            // Counted by the classes, held by no slot.
            return self.bc_uni_fn_walk(u, fy, y.as_data.elem, true, false, kpos, depth + 1, ncls, single);
        }
        if y.arr_like() {
            return self.bc_uni_fn_walk(u, fy, y.as_data.arr.elem, behind, emit, kpos, depth + 1, ncls, single);
        }
        if y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_DYN || y.fn_sig() {
            return false;
        }
        let mut d = DefId { module: 0, node: NODE_NONE };
        let mut nargs: u32 = 0;
        if self.bc_uni_decl(ty, &mut d, &mut nargs) {
            for _k in 0..unsafe (*self.mod_ast(d.module)).lifetimes_of(d.node).len {
                if emit && !self.bc_uni_fn_key(u, fy, *kpos, ncls, single, UA_BEHIND) {
                    return false;
                }
                *kpos += 1;
            }
            for i in 0..nargs {
                if !self.bc_uni_fn_walk(u, fy, self.bc_uni_arg(ty, i), true, emit, kpos, depth + 1, ncls, single) {
                    return false;
                }
            }
            return true;
        }
        if emit && self.bc_uni_len(ty, 0) == 1 {
            // A type parameter's (or another opaque type's) one position: values of that type only.
            u.keys.push(UK_TY | ty as u64);
            u.keys.push(bf);
        }
        return true;
    }

    // Append the key of lifetime position `k` of function-pointer type `fy` (`ncls` classes; none:
    // each position its own lifetime, and `single`: the one input position's, which the results take).
    fn bc_uni_fn_key(self: &Self, u: &mut UniSt, fy: &Ty, k: u32, ncls: u32, single: bool, bf: u64) bool {
        let mut key = UK_EL | 1u64 << 40 | k as u64;
        if ncls == 0 {
            if single {
                key = UK_EL | 1u64 << 41;
            }
        } else {
            let c = unsafe (*self.cur_ast()).sig_lt_class(fy, k);
            if c == LC_TOO_MANY {
                return false;
            }
            if c == LC_STATIC {
                key = UK_STATIC;
            } else if c >= LC_OUTER {
                key = UK_EL | 1u64 << 42 | (c - LC_OUTER) as u64;
            } else if c >= LC_GROUP {
                key = UK_EL | 1u64 << 41 | (c - LC_GROUP) as u64;
            }
        }
        u.keys.push(key);
        u.keys.push(bf);
        return true;
    }

    // Emit the pairs of edge `e` (source local `xl`, target origin `tor` of local `tl`) at call `term`
    // (see `bc_uni_map`): the callee's signature says which argument positions a value at a position
    // of its result, or one it stores through an argument, may come from (`bc_uni_call_keys`).
    fn bc_uni_map_call(
        self: &Self,
        ow: &mut bfx::Owner,
        u: &mut UniSt,
        body: &ir::CoreBody,
        e: &bfx::SubsetAt,
        xl: u32,
        tor: u32,
        tl: u32,
        term: &ir::Terminator,
        pa: &mut Vector<u32>,
        pb: &mut Vector<u32>,
        pc: &mut Vector<u32>,
    ) bool {
        let mut rel: u64 = 0;
        if !self.bc_uni_call_keys(ow, u, body, term, &mut rel) {
            return false;
        }
        // The positions of each argument read from the source's local, with their keys.
        u.bind.truncate(0);
        let mut hit = false;
        for j in 0..term.args_len {
            let oi = body.oper_pool[(term.args_start + j) as usize];
            if oi == ir::IR_NONE {
                continue;
            }
            let op = *body.operands.at(oi as usize);
            if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE || body.places.at(op.data as usize).base != xl {
                continue;
            }
            hit = true;
            let ks = u.kof[j as usize] as usize;
            let ke = u.kof[j as usize + 1] as usize;
            if ks == ke {
                // A variadic argument: the callee names none of its positions.
                continue;
            }
            pa.truncate(0);
            if !self.bc_uni_project(ow, u, body, e.from, op.data, pa) || ke - ks != 2 * pa.len() {
                return false;
            }
            for i in 0..pa.len() {
                if pa[i] < POS_STATIC {
                    u.bind.push(u.ka[ks + 2 * i]);
                    u.bind.push(u.ka[ks + 2 * i + 1]);
                    u.bind.push(pa[i]);
                }
            }
        }
        // The called value itself, a function pointer (no data, no storage) or a function object (its
        // captures, behind its first slot, may reach every output; its class slots follow).
        let mut fl = bfx::BF_NONE;
        let mut off: usize = 0;
        let mut fp: ir::PlaceId = ir::IR_NONE;
        if term.callee.node == NODE_NONE && term.a != ir::IR_NONE {
            let fo = *body.operands.at(term.a as usize);
            if fo.kind == ir::OP_COPY || fo.kind == ir::OP_MOVE {
                let fy = *self.type_at(body.places.at(fo.data as usize).ty);
                if fy.fn_sig() || fy.kind == TypeKind::TYPE_DYN && unsafe (*self.cur_ast()).dyn_fn_sig(&fy) != TYPE_NONE {
                    fl = body.places.at(fo.data as usize).base;
                    fp = fo.data;
                    if !fy.fn_sig() {
                        off = 1;
                    }
                }
            }
        }
        if fl == xl && off == 1 {
            pa.truncate(0);
            if !self.bc_uni_project(ow, u, body, e.from, fp, pa) || pa.len() == 0 {
                return false;
            }
            u.bind.push(UK_ANY);
            u.bind.push(0);
            u.bind.push(pa[0]);
            hit = true;
        }

        if !hit {
            return fl == xl;
        }
        if fl == tl {
            // Into the called value: an argument at a position of a lifetime its type fixes outside it
            // must outlive that lifetime, which the value's slot of its class is declared to hold.
            pa.truncate(0);
            if !self.bc_uni_project(ow, u, body, tor, fp, pa) {
                return false;
            }
            let mut i: usize = 0;
            while i + 2 < u.bind.len() {
                let g = off + (u.bind[i] & 0xFFFFFFFFu64) as usize;
                let outer = (u.bind[i] & (UK_EL | 1u64 << 42)) == (UK_EL | 1u64 << 42) && u.bind[i] >> 63 == 0;
                if outer && g < pa.len() {
                    u.pair(u.bind[i + 2] as u32, pa[g]);
                }
                i += 3;
            }
            return true;
        }
        let mut reached = false;
        // Each position of a result takes the argument positions of its key.
        for d in 0..term.dests_len {
            let ks = u.kof[(term.args_len + d) as usize] as usize;
            let ke = u.kof[(term.args_len + d) as usize + 1] as usize;
            let dp = body.dest_pool[(term.dests_start + d) as usize];
            let lv = self.bc_uni_len(body.places.at(dp as usize).ty, 0) as usize;
            if ks == ke || lv == 0 {
                continue;
            }
            let nc = self.bc_uni_dest(ow, u, body, tor, tl, dp, pb, pc) as usize;
            if nc == 0 {
                continue;
            }
            if pb.len() != nc * lv || ke - ks != 2 * lv {
                return false;
            }
            reached = true;
            for i in 0..lv {
                for cnd in 0..nc {
                    self.bc_uni_take(ow, u, rel, u.ka[ks + 2 * i], u.ka[ks + 2 * i + 1], pb[cnd * lv + i]);
                }
            }
        }
        // What the callee stores through an argument: at each position behind one of its references
        // (or of a type parameter whose bounds let it store), the argument positions of its key.
        for j in 0..term.args_len {
            let ks = u.kof[j as usize] as usize;
            let ke = u.kof[j as usize + 1] as usize;
            let oi = body.oper_pool[(term.args_start + j) as usize];
            if ks == ke || oi == ir::IR_NONE {
                continue;
            }
            let op = *body.operands.at(oi as usize);
            if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
                continue;
            }
            let q = op.data;
            let qty = body.places.at(q as usize).ty;
            let qy = *self.type_at(qty);
            let mut nc: usize = 0;
            let mut skip: usize = 0;
            pb.truncate(0);
            if body.places.at(q as usize).base == tl {
                if !self.bc_uni_project(ow, u, body, tor, q, pb) {
                    return false;
                }
                nc = 1;
            } else if qy.kind == TypeKind::TYPE_REFERENCE {
                // A reference into the target's value: stores land behind it.
                pc.truncate(0);
                for i in 0..u.cnt[tor as usize] {
                    pc.push(u.base[tor as usize] + i);
                }
                nc = self.bc_uni_locate(ow, u, body.locals.at(tl as usize).ty, pc, 0, qy.as_data.elem, pb, 0) as usize;
                skip = 1;
            } else {
                // A value holding a reference into the target's value: stores land behind it.
                if self.bc_uni_interior(ow, u, body, tor, tl, qty, ks, (ke - ks) / 2, rel, pa, pb, pc) {
                    reached = true;
                }
                continue;
            }
            if nc == 0 {
                continue;
            }
            reached = true;
            let lq = (ke - ks) / 2;
            let lw = lq - skip;
            if pb.len() != nc * lw {
                return false;
            }
            for i in skip..lq {
                let key = u.ka[ks + 2 * i];
                let aux = u.ka[ks + 2 * i + 1];
                let gen = key >> 63 == 0 && (key & UK_GEN) != 0;
                if (aux & UA_BEHIND) == 0 && !(gen && self.bc_uni_gen_open(
                    DefId { module: (key >> 32 & 0xFFFFFF) as ModuleId, node: (key & 0xFFFFFFFFu64) as NodeId },
                )) {
                    continue;
                }
                for cnd in 0..nc {
                    self.bc_uni_take(ow, u, rel, key, aux, pb[cnd * lw + i - skip]);
                }
            }
        }
        return reached;
    }

    // Stores through the references a call argument of struct type `qty` holds in its fields, into
    // the value of target origin `tor` (local `tl`): each field `&P` whose pointee `P` spells a value
    // within the target's (`bc_uni_subtrees`) takes, at each of its positions, the argument
    // positions of its key (the argument's keys from `u.ka[ks..]`, `lq` positions). True when a
    // field reaches the target.
    fn bc_uni_interior(
        self: &Self,
        ow: &mut bfx::Owner,
        u: &mut UniSt,
        body: &ir::CoreBody,
        tor: u32,
        tl: u32,
        qty: TypeId,
        ks: usize,
        lq: usize,
        rel: u64,
        pa: &mut Vector<u32>,
        pb: &mut Vector<u32>,
        pc: &mut Vector<u32>,
    ) bool {
        let mut d = DefId { module: 0, node: NODE_NONE };
        let mut nargs: u32 = 0;
        if !self.bc_uni_decl(qty, &mut d, &mut nargs) || unsafe (*self.mod_ast(d.module)).at_const(d.node).kind != NodeKind::NODE_STRUCT {
            return false;
        }
        // The values within the target's: (type, first slot) pairs in `pc`.
        pa.truncate(0);
        for i in 0..u.cnt[tor as usize] {
            pa.push(u.base[tor as usize] + i);
        }
        pc.truncate(0);
        self.bc_uni_subtrees(body.locals.at(tl as usize).ty, 0, pc, 0);
        let da = self.mod_ast(d.module);
        let ms = unsafe (*da).at_const(d.node).as_data.aggregate.members;
        let mut hit = false;
        for j in 0..ms.len {
            let fd = unsafe (*da).list(ms)[j as usize];
            if unsafe (*da).at_const(fd).kind != NodeKind::NODE_FIELD {
                continue;
            }
            let fnode = *unsafe (*da).at_const(unsafe (*da).at_const(fd).as_data.field.ty);
            if !fnode.has_lt_slot() {
                continue;
            }
            let mut c: usize = 0;
            while c + 1 < pc.len() {
                let sty = pc[c];
                let sat = pc[c + 1] as usize;
                c += 2;
                // The argument's positions, by index, mapped to the pointee's.
                pb.truncate(0);
                for i in 0..lq {
                    pb.push(i as u32);
                }
                if !self.bc_uni_field(ow, u, qty, fnode.as_data.indirect_type.ty, sty, pb, 0) {
                    continue;
                }
                hit = true;
                for i in 0..pb.len() {
                    if pb[i] < POS_STATIC && sat + i < pa.len() {
                        let ai = pb[i] as usize;
                        self.bc_uni_take(ow, u, rel, u.ka[ks + 2 * ai], u.ka[ks + 2 * ai + 1], pa[sat + i]);
                    }
                }
            }
        }
        return hit;
    }

    // Append to `out` a (type, first slot offset) pair per value within a value of type `c` whose
    // slots start at offset `at`: the value, a reference's or view's pointee, an array's element, a
    // type argument's value.
    fn bc_uni_subtrees(self: &Self, c: TypeId, at: u32, out: &mut Vector<u32>, depth: i32) {
        let lc = self.bc_uni_len(c, 0);
        if depth > 4 || lc == 0 || lc > UNI_SLOTS_MAX {
            return;
        }
        out.push(c);
        out.push(at);
        let y = *self.type_at(c);
        if y.kind == TypeKind::TYPE_REFERENCE {
            self.bc_uni_subtrees(y.as_data.elem, at + 1, out, depth + 1);
            return;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            self.bc_uni_subtrees(y.as_data.arr.elem, at, out, depth + 1);
            return;
        }
        let mut d = DefId { module: 0, node: NODE_NONE };
        let mut nargs: u32 = 0;
        if !self.bc_uni_decl(c, &mut d, &mut nargs) {
            return;
        }
        let mut off = at + unsafe (*self.mod_ast(d.module)).lifetimes_of(d.node).len;
        for i in 0..nargs {
            let ai = self.bc_uni_arg(c, i);
            self.bc_uni_subtrees(ai, off, out, depth + 1);
            off += self.bc_uni_len(ai, 0);
        }
    }

    // Does type node `tyn` of module `m` name lifetime `nm` (a span of `m`'s source)?
    pub fn bc_names_lt(self: &Self, m: ModuleId, tyn: NodeId, nm: tok::Span, depth: i32) bool {
        if tyn == NODE_NONE || depth > 6 {
            return false;
        }
        let a = self.mod_ast(m);
        let n = *unsafe (*a).at_const(tyn);
        if n.kind == NodeKind::NODE_LIFETIME {
            return tc::spans_eq2(self.mod_src(m), self.tc_lt_name_in(m, tyn), self.mod_src(m), nm);
        }
        if n.has_lt_slot() {
            return self.bc_names_lt(m, n.as_data.indirect_type.lifetime, nm, depth + 1) || self.bc_names_lt(
                m,
                n.as_data.indirect_type.ty,
                nm,
                depth + 1,
            );
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            return self.bc_names_lt(m, n.as_data.array_type.element, nm, depth + 1);
        }
        let args = if n.kind == NodeKind::NODE_TYPE_PATH {
            n.as_data.type_path.args;
        } else if n.kind == NodeKind::NODE_TUPLE_TYPE {
            n.as_data.array_literal.elements;
        } else {
            NodeList { start: 0, len: 0 };
        };
        for i in 0..args.len {
            if self.bc_names_lt(m, unsafe (*a).list(args)[i as usize], nm, depth + 1) {
                return true;
            }
        }
        return false;
    }

    // The block of `point` (the operation at it is statement `*si`, the terminator past the last).
    const fn bc_uni_site(self: &Self, f: &bfx::BodyFacts, point: u32, si: &mut u32) usize {
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

    // The region lifetime node `lt` of the current module denotes. An elided position (NODE_NONE,
    // slot `slot` of type node `at`) takes `elide`: for UNI_NONE (an input) a fresh anonymous region,
    // recorded in `u.pos`, or in look-up mode the one recorded; none for UNI_UNSOURCED.
    // The region of lifetime name `nm` (current module): `'static`, a name seen, or a fresh one.
    fn bc_uni_named(self: &Self, u: &mut UniSt, nm: tok::Span) u32 {
        if tc::span_is(self.source, nm, "'static") {
            return 0;
        }
        for i in 1..u.names.len() {
            if tc::spans_eq2(self.source, u.names[i], self.source, nm) {
                return i as u32;
            }
        }
        if u.look {
            return UNI_NONE;
        }
        return u.fresh(nm);
    }

    fn bc_uni_region(self: &Self, u: &mut UniSt, lt: NodeId, elide: u32, at: NodeId, slot: u32) u32 {
        let mut r = elide;
        if lt != NODE_NONE {
            r = self.bc_uni_named(u, self.tc_lt_name(lt));
        } else if elide == UNI_NONE && u.look {
            r = UNI_NONE;
            let key = at as u64 << 8 | slot as u64;
            let mut i: usize = 0;
            while i + 1 < u.pos.len() {
                if u.pos[i] == key {
                    r = u.pos[i + 1] as u32;
                }
                i += 2;
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
        if n.kind == NodeKind::NODE_DYN_TYPE {
            // An erased object holds borrows its type does not show: an owned `dyn I` only `'static`
            // ones (Rust's default object lifetime), a `&'a dyn I` ones that outlive `'a`.
            let fm = self.bc_uni_fn(u, n.as_data.indirect_type.ty, behind, depth);
            if n.as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_NONE {
                u.mark(0, behind);
                return 1u64 | fm;
            }
            let r = self.bc_uni_region(u, n.as_data.indirect_type.lifetime, elide, tyn, 0);
            if r == UNI_NONE {
                return fm;
            }
            u.mark(r, behind);
            u.mark(r, true);
            return 1u64 << r as u64 | fm;
        }
        if n.kind == NodeKind::NODE_FUNCTION_TYPE {
            return self.bc_uni_fn(u, tyn, behind, depth);
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
        if d.node == NODE_NONE {
            return 0;
        }
        if unsafe (*self.mod_ast(d.module)).at_const(d.node).kind == NodeKind::NODE_GENERIC_PARAM {
            // A type parameter holds the regions its bounds name (`T: Put<'a>` may be an `H<'a>`).
            if d.module != self.cur_module() {
                return 0;
            }
            let mut gm = self.bc_uni_bounds(
                u,
                unsafe (*a).at_const(d.node).as_data.generic_param.bounds,
                behind,
                elide,
                depth,
            );
            for w in 0..unsafe (*a).where_bounds.len() {
                let sc = unsafe (*a).where_scope(w, d.node, self.icx.current_fn);
                if sc == WHERE_OWN || sc == WHERE_IN {
                    let pred = unsafe (*a).where_bounds.at(w).pred;
                    gm = gm | self.bc_uni_bounds(
                        u,
                        unsafe (*a).at_const(pred).as_data.where_predicate.bounds,
                        behind,
                        elide,
                        depth,
                    );
                }
            }
            return gm;
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

    // The regions the arguments of bound list `bs` (current module) name, as `bc_uni_type` adds them.
    // The regions function type `fnn` fixes (current module): the lifetimes its positions name that
    // its own `for<..>` does not bind. A value of it holds them: a call stores its arguments there.
    fn bc_uni_fn(self: &Self, u: &mut UniSt, fnn: NodeId, behind: bool, depth: i32) u64 {
        let a = self.cur_ast();
        if fnn == NODE_NONE || depth > 6 || unsafe (*a).at_const(fnn).kind != NodeKind::NODE_FUNCTION_TYPE {
            return 0;
        }
        let mut out = Vector::<tok::Span>::new();
        let ft = unsafe (*a).at_const(fnn).as_data.function_type;
        for i in 0..ft.params.len + ft.returns.len {
            let sl = if i < ft.params.len {
                unsafe (*a).list(ft.params)[i as usize];
            } else {
                unsafe (*a).list(ft.returns)[(i - ft.params.len) as usize];
            };
            self.tc_typenode_lifetimes(self.cur_module(), unsafe (*a).slot_type_node(sl), &mut out, 0);
        }
        let bound = unsafe (*a).lifetimes_of(fnn);
        let mut m: u64 = 0;
        for i in 0..out.len() {
            let sp = out[i];
            let mut own = false;
            for k in 0..bound.len {
                own = own || tc::spans_eq2(
                    self.source,
                    self.tc_lt_name(unsafe (*a).list(bound)[k as usize]),
                    self.source,
                    sp,
                );
            }
            let r = self.bc_uni_named(u, sp);
            if own || r == UNI_NONE {
                continue;
            }
            u.mark(r, behind);
            u.mark(r, true);
            m = m | 1u64 << r as u64;
        }
        return m;
    }

    fn bc_uni_bounds(self: &Self, u: &mut UniSt, bs: NodeList, behind: bool, elide: u32, depth: i32) u64 {
        let a = self.cur_ast();
        let mut m: u64 = 0;
        for i in 0..bs.len {
            let b = unsafe (*a).list(bs)[i as usize];
            if unsafe (*a).at_const(b).kind == NodeKind::NODE_FUNCTION_TYPE {
                m = m | self.bc_uni_fn(u, b, behind, depth);
                continue;
            }
            if unsafe (*a).at_const(b).kind != NodeKind::NODE_TYPE_PATH {
                continue;
            }
            let args = unsafe (*a).at_const(b).as_data.type_path.args;
            for j in 0..args.len {
                let aid = unsafe (*a).list(args)[j as usize];
                if unsafe (*a).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                    let r = self.bc_uni_region(u, aid, elide, b, j);
                    if r != UNI_NONE {
                        u.mark(r, behind);
                        m = m | 1u64 << r as u64;
                    }
                } else {
                    m = m | self.bc_uni_type(u, aid, behind, elide, depth + 1);
                }
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
                format("borrowed value does not live long enough: this value must satisfy 'static");
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
                // A closure's arguments past its declared parameters are its captures, held by copy.
                let oa = self.mod_ast(body.owner.module);
                if body.owner.node != NODE_NONE && unsafe (*oa).at_const(body.owner.node).kind == NodeKind::NODE_CLOSURE && base >= body.returns + unsafe (*oa).at_const(
                    body.owner.node,
                ).as_data.closure.params.len {
                    what = "closure capture (a closure holds its captures by copy; capture a reference instead)";
                }
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
