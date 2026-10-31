// The optimizer of an optimizing build: one walk of a LIR body's dominator tree, after Click's global
// value numbering and Cranelift's scoped elaboration (Fallin 2026: the hash-consed dominator walk carries
// most of the gain of its e-graph). Each instruction is rewritten in place as the walk reaches it:
//
// - its operands take the values that replaced theirs;
// - an operation of constants folds to a constant by the evaluator's own arithmetic (`le::int_fold`),
//   an identity (`x + 0`, `x * 1`, `x & x`, ...) to its operand, a branch on a constant to a jump;
// - a pure operation a dominating block already computed becomes that value;
// - a load of a place a dominating instruction read or stored in the same memory state becomes that
//   value (each write starts a memory state, and a block whose one predecessor is its dominator
//   continues that block's last);
// - a branch whose sides reach one block, each directly or through an empty block, becomes a jump whose
//   arguments that differ by side are selects on its condition (if-conversion);
// - an unsigned comparison an edge into a dominating block decides, through the minimums its bound is
//   (`i <u min(a, b)`: `i <u a` and `i <u b`), decides the same comparison of other values (a bounds
//   check of a loop over the shorter of two slices);
// - a load of read-only data folds to the constant it reads;
// - a pure operation of loop-invariant operands that cannot trap moves to the loop's preheader, and so
//   does a load of a field of a slot, a data symbol, an aggregate parameter or a reference parameter's
//   referent in a loop that writes none of the memory it may read (`classes`: an exclusive reference
//   parameter's referent is reached through that parameter alone).
//
// A rebuild then drops what was replaced and places what moved, and the lowering's `tidy` removes what
// nothing uses. Every step is linear in the body, the loop membership tests in its nesting depth.
import lir::ir as *;
import ir::core as core;
import lir::eval as le;
import lir::verify as lv;
import std::parallel::sync as psync;
import lir::inline as il;
import lir::promote as pr;
import lir::loops as lu;
import lir::slp as sl;
import lir::pairs as pa;
import lir::wide as wd;
import lir::print as lp;
import lir::switches as sws;
import stdlib;
import std::platform::clock as pclock;

// `Opt.repl` of an instruction without a value that the rebuild drops.
const DROPPED: u32 = 0xFFFFFFFE;

// The scoped tables (`Opt.log`).
const LOG_PURE: u8 = 0;
const LOG_MEM: u8 = 1;
const LOG_COND: u8 = 2;
const LOG_REL: u8 = 3;
const LOG_UB: u8 = 4;
const LOG_EQ: u8 = 5;
// `Opt::overwrite` keeps at most PEND_MAX stores.
const PEND_MAX: u32 = 8;
// `Opt::ubound` follows at most UB_DEPTH instructions.
const UB_DEPTH: u32 = 4;
// An if-conversion makes at most MAX_SELECTS selects; a minimum's operands are followed MIN_DEPTH deep.
const MAX_SELECTS: u32 = 2;
// The instructions but constants an if-conversion moves out of its two sides (`Opt::speculate`).
const SPEC_MAX: u32 = 4;
// `ConstSlot::find` follows address chains at most CONST_PASSES deep.
const CONST_PASSES: u32 = 8;
// `bit_set` takes at most SET_MAX comparisons.
const SET_MAX: usize = 16;
// `param_slots` copies by-value aggregates of at most PSLOT_MAX bytes into slots.
const PSLOT_MAX: u32 = 64;
// `dead_allocs` takes at most FRESH_MAX allocations of a body.
const FRESH_MAX: usize = 16;
// `memcmp_eq` expands counts of at most MEMCMP_MAX bytes.
const MEMCMP_MAX: u64 = 16;
const MIN_DEPTH: u32 = 3;
// `Opt::private_load`'s answers besides a value, and the memory state of the loads it keeps.
const PRIV_NONE: Value = VNONE;
const PRIV_KEPT: Value = VNONE - 1;
const KEPT_STATE: u32 = NONE;
// Private memory with more writes than this has no load promoted or kept (`private_load` scans them).
const SLOT_WRITES_MAX: u32 = 64;
// The loop transforms run at most LOOP_ROUNDS times per body: each round may double a loop.
// A vector load of what scalar stores just wrote waits for them (no store forwarding): its cost in
// instructions (`Opt::weigh`).
const GATHER_COST: u64 = 8;
const LOOP_ROUNDS: u32 = 3;
// `Opt::between_writes` visits at most BETWEEN_MAX blocks; WRITES_ALL is its answer past them.
const BETWEEN_MAX: u32 = 16;
const WRITES_ALL: u32 = 0x10000;
// `in_frame` follows at most FRAME_DEPTH values.
const FRAME_DEPTH: u32 = 8;
// `Opt::preader` and `ireader` of a value several blocks read, or an edge.
const MULTI: u32 = 0xFFFFFFFE;
// `Opt::thread_rounds` runs at most THREAD_ROUNDS times per optimization of a body. A block an edge
// threads through holds at most THREAD_BLOCK_MAX instructions, its terminator included, and its
// branch's condition is followed THREAD_DEPTH instructions deep.
const THREAD_ROUNDS: u32 = 3;
const THREAD_BLOCK_MAX: u32 = 8;
// `twins` compares blocks of at most TWIN_MAX instructions.
const TWIN_MAX: u32 = 16;
const THREAD_DEPTH: u32 = 4;
// `Opt::implied` follows a parameter back through at most IMPLY_FAN edges into its block.
const IMPLY_FAN: u32 = 4;
// A write carries at most RECENT_MAX of the places known last into its memory state (`Opt::carry`).
const RECENT_MAX: usize = 16;
// The analyses `Opt::tables` keeps for the body at hand (`Opt.kept`), each level with those before it.
const K_NONE: u8 = 0;
const K_GRAPH: u8 = 1; // `graph`
const K_DOM: u8 = 2; // `dominators`
const K_NEST: u8 = 3; // `nest`
const K_MEM: u8 = 4; // `memory`

/// The optimizer's scratch, reused from body to body.
pub(package) struct Opt {
    // The control flow graph: per block, its successors and predecessors as ranges of one list each.
    succ_at: Vector<u32>,
    succs: Vector<u32>,
    pred_at: Vector<u32>,
    preds: Vector<u32>,
    edges: Vector<u32>,
    // Reverse postorder, immediate dominators and the dominator tree (children as ranges; preorder and
    // postorder numbers for the dominance test).
    rpo: Vector<u32>,
    order: Vector<u32>,
    idom: Vector<u32>,
    kid_at: Vector<u32>,
    kids: Vector<u32>,
    dpre: Vector<u32>,
    dpost: Vector<u32>,
    // Loops: per block, its innermost loop's header (NONE outside loops); per header, the header of the
    // loop around it, its preheader (NONE: none) and the alias classes its blocks write (`class_bit`).
    inner: Vector<u32>,
    lparent: Vector<u32>,
    preh: Vector<u32>,
    writes: Vector<u64>,
    // The alias class of each instruction's and each block parameter's value (`classes`).
    icls: Vector<u8>,
    pcls: Vector<u8>,
    // Scoped classes (`Body.scopes`): per class, its site (NONE: a parameter's) and its roots' block;
    // per scope, its class index; per instruction, the scope classes it belongs to; the scope classes;
    // pinned roots; per instruction, its access's class (`acc`) for the loop transforms.
    csite: Vector<u32>,
    croot: Vector<u32>,
    sgroup: Vector<u32>,
    cgroup: Vector<u32>, // per class, its scope group (`scope_seeds`)
    cbase: Vector<u8>, // per class, the class its scope roots have apart from their pins (`class_flow`)
    site_cls: Vector<u64>, // per `lines` entry, the scope classes of its inline site (`scope_seeds`)
    imem: Vector<u64>,
    sbits: u64,
    fbits: u64, // the classes of allocations' blocks (`fresh_seeds`)
    cnext: u32, // the first class index past the parameters' and the scopes'
    fcall: Vector<u32>, // per class index, the allocation whose block it is (`fresh_seeds`)
    oparam: Vector<u32>, // per class index, the parameter whose owned buffer it is (`owned_seeds`)
    ooff: Vector<u32>, // per class index, the owned field's offset in the parameter's referent
    oload: Vector<u32>, // per instruction, the class index of the owned field it loads (NONE: none)
    oder: Vector<u32>, // per instruction, the parameter its address arithmetic starts from (`owned_seeds`)
    ooffs: Vector<i64>, // per instruction, that arithmetic's constant offset (OFF_ANY: not constant)
    ipin: Vector<bool>,
    ppin: Vector<bool>,
    acls: Vector<u8>,
    aobj: Vector<u32>, // per load or store, the object it accesses (`object`)
    frz: Vector<bool>, // per instruction, a load of a read-only referent (`frozen`)
    mark: Vector<u32>,
    hdr: Vector<bool>, // per block, whether it heads a loop (`thread`)
    preader: Vector<u32>, // per block parameter, the block outside its own that reads it (`thread`)
    pcount: Vector<u8>, // per block parameter, how many instructions read it, up to 2 (`thread`)
    icount: Vector<u8>, // per instruction, how many instructions read it, up to 2 (`thread`)
    ireader: Vector<u32>, // per instruction, the block outside its own that reads it (`thread`)
    in_or: Vector<bool>, // per instruction, whether an `or` reads it (`thread`, for `bit_set`)
    // `dead_allocs`: the allocations, whether each may go, per block whether a path visited it, the blocks
    // to visit, an instruction's operands.
    fresh: Vector<u32>,
    pslots: bool, // whether `param_slots` may look at the body (once per body after the inliner)
    unit: u32, // the unit of the body's function (`Sym.unit`; NONE: none), for `fold_ptr`
    fresh_ok: Vector<bool>,
    fresh_free: Vector<u32>, // per allocation, the block of its one free (NONE: none)
    seen: Vector<bool>,
    fstack: Vector<u32>,
    fuses: Vector<Value>,
    puser: Vector<u32>, // per block parameter, the last instruction that reads it (`thread`)
    textra: Vector<u32>, // the constants `thread` made, for the walk's `extra`
    settle: Vector<u32>, // `thread`'s settled branches: block, edge
    trepl: Vector<u64>, // instruction << 32 | the value `thread` replaced it with, for the walk
    // Per block parameter its block; per instruction its block (a moved one's new block), what replaced
    // it (VNONE: nothing) and whether it moved.
    pblock: Vector<u32>,
    blk_of: Vector<u32>,
    repl: Vector<u32>,
    prepl: Vector<u32>, // per block parameter, the value that replaced it (VNONE: none)
    frepl: Vector<u32>, // per checked operation, the value that replaced its flag (VNONE: none)
    extra: Vector<u32>, // the constants the walk made, which the entry block starts with
    aggp: u64, // the entry parameters whose loads move to the entry's start (`agg_params`)
    made: Map<u64, u32>, // a made constant's hash to the constant
    moved: Vector<bool>,
    hoisted: Vector<u64>, // block << 32 | instruction, in the order they moved
    pnew: Vector<bool>, // per block, a preheader `preheaders` made
    touched: Vector<bool>, // per block, one `promote_places` changed: a preheader or a block of a loop
    pre: Vector<u64>, // instruction << 32 | an instruction the walk made to run right before it, in order
    unbiased: Map<u32, u32>, // per indexed address with an offset, the address without it (`visit`)
    merged: bool, // the last rebuild merged blocks
    selected: bool, // the last walk made selects (`diamond`), which no walk simplified
    unstored: bool, // the last walk dropped a store in a loop, whose loads may leave it now
    pre_at: Vector<u32>, // the rebuild's ranges of `pre_list` per instruction
    pre_list: Vector<u32>,
    // The scoped tables: a pure instruction's hash to the instruction, a memory place's hash to its
    // `places` entry, a branch condition the edge into the scope decides to 0 or 1. `log` holds each
    // insertion of the open scopes: its table, key and the entry it replaced (NONE: none).
    pure: Map<u64, u32>,
    mem: Map<u64, u32>,
    cond: Map<u64, u32>,
    rel: Map<u64, u32>, // `y << 32 | x` -> whether `x <u y` holds (`rel_key`)
    eqs: Map<u64, u32>, // the pairs of values the branches in scope make equal (`rel_key` of the lower first)
    ub: Map<u64, u32>, // value -> constant `k` << 1 | 1 when `value <u k` holds, `k` << 1 when `value <=u k`
    log: Vector<(u8, u64, u32)>,
    places: Vector<Place>,
    recent: Vector<u32>, // the `places` entries made last in the walk's block and its dominators (`carry`)
    end_recent: Vector<u32>, // per block, `recent` at its end: RECENT_MAX entries, NONE past its count
    state: u32, // the current memory state of the visited access (its tag's)
    prior: u32, // the memory state of the visited access's tag before it
    // The private and the untagged memory states before the visited instruction: no write between two
    // instructions when both are the same.
    pprior: u32,
    tprior: u32,
    tstate: [u32; TBAA_TAGS], // per type tag, the current memory state of its accesses
    tags: Vector<u16>, // per loop header, the type tags its blocks write (`tags_in`)
    // Private memory (`slot_writes`): the slots, then the aggregate arguments (each a copy the callee
    // owns). Per instruction the one its address value points into (NONE: none) and the offset; per one
    // whether its address escapes; the writes, by place (`wat`).
    sbase: Vector<u32>,
    soff: Vector<i64>,
    sesc: Vector<bool>,
    wr: Vector<SlotWrite>,
    wat: Vector<u32>,
    wl: Vector<SlotWrite>,
    end_state: Vector<u32>, // per block and type tag, its state at its end
    pstate: u32, // the current memory state of the private slots' accesses (`privates`)
    end_pstate: Vector<u32>, // per block, `pstate` at its end
    pder: Vector<u32>, // per instruction, the slot its address derives from (NONE: none)
    pwrite: Vector<bool>, // per loop header, whether the loop writes a private slot's memory
    lst: Vector<u32>, // the loops' plain stores of an exclusive parameter's class, each loop's together
    lst_at: Vector<u64>, // per loop header, its range of `lst`: start << 32 | end
    imprecise: Vector<u64>, // per loop header, the classes a write but a plain store touches
    pesc: Vector<bool>, // per slot, whether its address escapes
    bwrites: Vector<u16>, // per block, the type tags its writes write (bit 0: an untagged write, all of them)
    rmark: Vector<u32>, // per block, the last block whose `between_writes` reached it
    rstack: Vector<u32>,
    stack: Vector<u64>,
    pend: Vector<u32>, // the walk's block's stores no instruction since may read (`overwrite`)
    work: Vector<u32>,
    // The rebuild.
    bmap: Vector<u32>, // per block, its new number (NONE: unreached)
    in_at: Vector<u32>, // per block, the range of `ins` (and `insrc`) of the edges into it
    ins: Vector<u32>,
    insrc: Vector<u32>, // the block each of those edges leaves
    nxt: Vector<u32>, // per block, the block that continues it (NONE: none)
    sread: Vector<bool>, // per slot, whether it is read (`slot_reads`)
    sused: Vector<u32>, // per slot, NONE when no emitted instruction takes its address (`emit`), else its new number
    done_pool: Vector<bool>, // per pool word, whether it is renumbered
    cps: PoolScratch, // `Body::compact_pool`'s
    pmap: Vector<u32>, // per block parameter, its new number
    params: Vector<u8>,
    live: Vector<bool>,
    uses: Vector<Value>,
    newidx: Vector<u32>,
    into: Vector<u32>,
    done: Vector<bool>, // per block, whether another block's chain continues into it
    insts: Vector<Inst>,
    locs: Vector<u32>,
    inls: Vector<u32>,
    blocks: Vector<Block>,
    // Promotion of private slots (`lir::promote`) and the body it builds.
    prom: pr::Promoter,
    pbody: Body,
    pub(package) unr: lu::LoopOpt,
    slp: sl::Slp,
    pairs: pa::Pairs,
    wide: wd::Wide,
    wgt: Vector<u64>, // per block, the weight of an instruction there (`weigh`)
    // The analyses that describe the body at hand (`K_*`, `tables`); a change of the body drops them.
    kept: u8,
    // Per instruction, its operands, then a terminator's edges' arguments: `ops[ops_at[i]..ops_at[i + 1]]`,
    // the arguments from `ops_arg[i]`; per entry, the block parameter an argument passes to (`ops_dst`,
    // NONE for an operand; `graph`).
    ops_at: Vector<u32>,
    ops_arg: Vector<u32>,
    ops: Vector<Value>,
    ops_dst: Vector<u32>,
    // Per loop header, its blocks in `lbs` as start << 32 | end, in block order (`nest`).
    lb_at: Vector<u64>,
    lbs: Vector<u32>,
    lsort: Vector<u32>,
    // Per block in a loop, its writes, found once (`memory`): `writes_in`, `tags_in`, `pwrites_in`, and
    // `note_stores`' classes and stores (`bst[bst_at[k]..bst_at[k + 1]]`).
    bw: Vector<u64>,
    bt: Vector<u16>,
    bpw: Vector<bool>,
    bimp: Vector<u64>,
    bst_at: Vector<u32>,
    bst: Vector<u32>,
    // `preheaders`' changes for `unpreheaders`: each terminator it rewrote with its old form, and the
    // lengths of the instructions, locations, inline marks, parameters, pool and blocks before it.
    pundo: Vector<(u32, Inst)>,
    plen: [u32; 6],
    promote: bool, // SC_LIR_PROMOTE=0 promotes nothing (a debugging aid)
}

/// What `optimize` does: the inline budget, and the loop transforms' budgets.
pub(package) struct Config {
    pub(package) inline: il::Budget,
    pub(package) loops: lu::Budgets,
}

extend Config as Copy {}

// A write into private memory whose address does not escape: bytes `off` to `end` of `slot` (`Opt.sbase`),
// by store `inst` in block `blk` (NONE: a copy or a fill).
struct SlotWrite {
    pub(package) slot: u32,
    pub(package) off: i64,
    pub(package) end: i64,
    pub(package) inst: u32,
    pub(package) blk: u32,
}

extend SlotWrite as Copy {}

// A memory place in a memory state, and the value it holds.
struct Place {
    pub(package) addr: u32,
    pub(package) off: u32,
    pub(package) ty: u8,
    pub(package) state: u32,
    pub(package) val: u32,
}

extend Place as Copy {}

extend Opt {
    pub(package) fn new() Opt {
        return Opt {
            succ_at: Vector::<u32>::new(),
            succs: Vector::<u32>::new(),
            pred_at: Vector::<u32>::new(),
            preds: Vector::<u32>::new(),
            edges: Vector::<u32>::new(),
            rpo: Vector::<u32>::new(),
            order: Vector::<u32>::new(),
            idom: Vector::<u32>::new(),
            kid_at: Vector::<u32>::new(),
            kids: Vector::<u32>::new(),
            dpre: Vector::<u32>::new(),
            dpost: Vector::<u32>::new(),
            inner: Vector::<u32>::new(),
            lparent: Vector::<u32>::new(),
            preh: Vector::<u32>::new(),
            writes: Vector::<u64>::new(),
            icls: Vector::<u8>::new(),
            pcls: Vector::<u8>::new(),
            csite: Vector::<u32>::new(),
            croot: Vector::<u32>::new(),
            sgroup: Vector::<u32>::new(),
            cgroup: Vector::<u32>::new(),
            cbase: Vector::<u8>::new(),
            site_cls: Vector::<u64>::new(),
            imem: Vector::<u64>::new(),
            sbits: 0,
            fbits: 0,
            cnext: 0,
            fcall: Vector::<u32>::new(),
            oparam: Vector::<u32>::new(),
            ooff: Vector::<u32>::new(),
            oload: Vector::<u32>::new(),
            oder: Vector::<u32>::new(),
            ooffs: Vector::<i64>::new(),
            ipin: Vector::<bool>::new(),
            ppin: Vector::<bool>::new(),
            acls: Vector::<u8>::new(),
            aobj: Vector::<u32>::new(),
            frz: Vector::<bool>::new(),
            mark: Vector::<u32>::new(),
            hdr: Vector::<bool>::new(),
            preader: Vector::<u32>::new(),
            pcount: Vector::<u8>::new(),
            icount: Vector::<u8>::new(),
            ireader: Vector::<u32>::new(),
            in_or: Vector::<bool>::new(),
            fresh: Vector::<u32>::new(),
            pslots: true,
            unit: NONE,
            fresh_ok: Vector::<bool>::new(),
            fresh_free: Vector::<u32>::new(),
            seen: Vector::<bool>::new(),
            fstack: Vector::<u32>::new(),
            fuses: Vector::<Value>::new(),
            puser: Vector::<u32>::new(),
            textra: Vector::<u32>::new(),
            settle: Vector::<u32>::new(),
            trepl: Vector::<u64>::new(),
            pblock: Vector::<u32>::new(),
            blk_of: Vector::<u32>::new(),
            repl: Vector::<u32>::new(),
            moved: Vector::<bool>::new(),
            hoisted: Vector::<u64>::new(),
            pnew: Vector::<bool>::new(),
            touched: Vector::<bool>::new(),
            pre: Vector::<u64>::new(),
            unbiased: Map::<u32, u32>::new(),
            merged: false,
            selected: false,
            unstored: false,
            pre_at: Vector::<u32>::new(),
            pre_list: Vector::<u32>::new(),
            pure: Map::<u64, u32>::new(),
            mem: Map::<u64, u32>::new(),
            cond: Map::<u64, u32>::new(),
            rel: Map::<u64, u32>::new(),
            eqs: Map::<u64, u32>::new(),
            ub: Map::<u64, u32>::new(),
            log: Vector::<(u8, u64, u32)>::new(),
            places: Vector::<Place>::new(),
            recent: Vector::<u32>::new(),
            end_recent: Vector::<u32>::new(),
            sbase: Vector::<u32>::new(),
            soff: Vector::<i64>::new(),
            sesc: Vector::<bool>::new(),
            wr: Vector::<SlotWrite>::new(),
            wat: Vector::<u32>::new(),
            wl: Vector::<SlotWrite>::new(),
            state: 0,
            prior: 0,
            pprior: 0,
            tprior: 0,
            end_state: Vector::<u32>::new(),
            pstate: 0,
            end_pstate: Vector::<u32>::new(),
            pder: Vector::<u32>::new(),
            pwrite: Vector::<bool>::new(),
            lst: Vector::<u32>::new(),
            lst_at: Vector::<u64>::new(),
            imprecise: Vector::<u64>::new(),
            pesc: Vector::<bool>::new(),
            bwrites: Vector::<u16>::new(),
            rmark: Vector::<u32>::new(),
            rstack: Vector::<u32>::new(),
            tstate: [0u32; TBAA_TAGS],
            tags: Vector::<u16>::new(),
            stack: Vector::<u64>::new(),
            pend: Vector::<u32>::new(),
            work: Vector::<u32>::new(),
            bmap: Vector::<u32>::new(),
            in_at: Vector::<u32>::new(),
            ins: Vector::<u32>::new(),
            insrc: Vector::<u32>::new(),
            nxt: Vector::<u32>::new(),
            sread: Vector::<bool>::new(),
            sused: Vector::<u32>::new(),
            done_pool: Vector::<bool>::new(),
            cps: PoolScratch::new(),
            prepl: Vector::<u32>::new(),
            frepl: Vector::<u32>::new(),
            extra: Vector::<u32>::new(),
            aggp: 0,
            made: Map::<u64, u32>::new(),
            pmap: Vector::<u32>::new(),
            params: Vector::<u8>::new(),
            live: Vector::<bool>::new(),
            uses: Vector::<Value>::new(),
            newidx: Vector::<u32>::new(),
            into: Vector::<u32>::new(),
            done: Vector::<bool>::new(),
            insts: Vector::<Inst>::new(),
            locs: Vector::<u32>::new(),
            inls: Vector::<u32>::new(),
            blocks: Vector::<Block>::new(),
            prom: pr::Promoter::new(),
            pbody: Body::new(),
            unr: lu::LoopOpt::new(),
            slp: sl::Slp::new(),
            pairs: pa::Pairs::new(),
            wide: wd::Wide::new(),
            wgt: Vector::<u64>::new(),
            kept: K_NONE,
            ops_at: Vector::<u32>::new(),
            ops_arg: Vector::<u32>::new(),
            ops: Vector::<Value>::new(),
            ops_dst: Vector::<u32>::new(),
            lb_at: Vector::<u64>::new(),
            lbs: Vector::<u32>::new(),
            lsort: Vector::<u32>::new(),
            bw: Vector::<u64>::new(),
            bt: Vector::<u16>::new(),
            bpw: Vector::<bool>::new(),
            bimp: Vector::<u64>::new(),
            bst_at: Vector::<u32>::new(),
            bst: Vector::<u32>::new(),
            pundo: Vector::<(u32, Inst)>::new(),
            plen: [0u32; 6],
            promote: !stdlib::env_is("SC_LIR_PROMOTE", "0"),
        };
    }

    /// Drop the analyses of the body at hand (`tables`): the next body's passes compute their own.
    pub(package) fn forget(self: &mut Self) {
        self.kept = K_NONE;
    }

    // The analyses up to level `want` (`K_*`) for body `b`: those `kept` lacks, computed.
    fn tables(self: &mut Self, pk: &Package, b: &Body, want: u8) {
        let have = self.kept;
        if have >= want {
            return;
        }
        if have < K_GRAPH {
            self.graph(b);
        }
        if have < K_DOM && want >= K_DOM {
            self.dominators(b);
        }
        if have < K_NEST && want >= K_NEST {
            self.nest(b);
        }
        if want >= K_MEM {
            self.memory(pk, b);
        }
        self.kept = want;
    }

    /// Optimize body `b` of package `pk`; with `force` the rebuild runs though nothing changed (after the
    /// inliner, which leaves blocks the entry may not reach). Whether it changed.
    pub(package) fn run(self: &mut Self, pk: &Package, b: &mut Body, force: bool) bool {
        if b.naked {
            return false;
        }
        self.merged = false;
        let slotted = self.param_slots(pk, b);
        // `thread` computes the graph and the dominators: they stand when it moves no edge (`kept`).
        let threaded = self.thread(pk, b) || slotted;
        self.tables(pk, b, K_NEST);
        // The walk hoists into preheaders: the memory facts are those of the body that has them.
        let entered = self.preheaders(b);
        self.tables(pk, b, K_MEM);
        self.slot_writes(pk, b);
        let changed = self.walk(pk, b) || force || threaded || entered;
        if entered {
            self.unenter(b);
        }
        if changed {
            self.rebuild(b);
        }
        if b.slots.len() == 0 || !self.promote {
            let r = self.thread_rounds(pk, b) || changed;
            return self.rewalk(pk, b) || r;
        }
        // Promotion, once the walk forwarded the parameters an inlined body's entry takes (a slot's
        // address among them); it keeps the blocks and their edges' targets, so the graph and the
        // dominators stand for the walk that follows it, and for `thread` when it promotes nothing.
        self.tables(pk, b, K_DOM);
        let promoted = self.prom.run(
            b,
            &self.succ_at,
            &self.succs,
            &self.pred_at,
            &self.preds,
            &self.idom,
            &self.order,
            &self.kid_at,
            &self.kids,
            &self.blk_of,
            pk.ptr_bytes,
            &mut self.pbody,
        );
        if !promoted {
            let r = self.thread_rounds(pk, b) || changed;
            return self.rewalk(pk, b) || r;
        }
        let nb = replace(&mut self.pbody, Body::new());
        self.pbody = replace(b, nb);
        self.block_map(b);
        self.operands(b);
        self.kept = K_DOM;
        self.tables(pk, b, K_MEM);
        self.slot_writes(pk, b);
        let _ = self.walk(pk, b);
        self.rebuild(b);
        // Promotion turns the flags a `&&` or `||` stores into parameters `thread` reads.
        let _ = self.thread_rounds(pk, b);
        let _ = self.rewalk(pk, b);
        return true;
    }

    // Blocks the last rebuild merged are one block now, the selects the last walk made are new, and a
    // loop may write less: one more walk numbers and forwards across the blocks (a load the second
    // repeats), simplifies the selects and hoists the loads. Whether it ran.
    fn rewalk(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if !self.merged && !self.selected && !self.unstored {
            return false;
        }
        self.tables(pk, b, K_MEM);
        self.slot_writes(pk, b);
        let _ = self.walk(pk, b);
        self.rebuild(b);
        return true;
    }

    // `thread`, then the walk and the rebuild, while `thread` moves an edge, at most THREAD_ROUNDS times:
    // each round may leave a branch whose sides now meet (a three-way comparison tested against 0 takes
    // two). Whether any round ran.
    fn thread_rounds(self: &mut Self, pk: &Package, b: &mut Body) bool {
        let mut round: u32 = 0;
        while round < THREAD_ROUNDS && self.thread(pk, b) {
            self.tables(pk, b, K_MEM);
            self.slot_writes(pk, b);
            let _ = self.walk(pk, b);
            self.rebuild(b);
            round += 1;
        }
        return round != 0;
    }

    /// Pack body `b`'s isomorphic scalar values into vectors (`lir::slp`), kept when the instruction
    /// count weighted by loop depth drops; then optimize it again. Whether it changed.
    pub(package) fn slp(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if b.naked || pk.vector < 16 {
            return false;
        }
        let before = self.weigh(pk, b);
        if !self.slp.plan(
            b,
            pk.ptr_bytes,
            pk.vector.min(64),
            (pk.fmath & FM_ASSOC) != 0,
            &self.wgt,
            &self.blk_of,
            &self.pblock,
        ) {
            return false;
        }
        let saved = b.compact();
        let ni = b.insts.len();
        self.kept = K_NONE;
        self.fresh(b);
        self.slp.emit(b);
        for x in 0..b.insts.len() - ni {
            self.repl.push(VNONE);
            self.frepl.push(VNONE);
            self.moved.push(true);
            self.blk_of.push(self.slp.blk[x]);
        }
        self.pre.extend_copy(&self.slp.pre);
        self.hoisted.extend_copy(&self.slp.tail);
        self.rebuild(b);
        let _ = self.run(pk, b, true);
        if self.weigh(pk, b) >= before {
            *b = saved;
            self.kept = K_NONE;
            return false;
        }
        return true;
    }

    /// Mark the rare blocks of body `b` past the lowering's marks (`BLOCK_COLD`, `BLOCK_UNLIKELY`): a block
    /// that panics is cold; one that calls a `@cold` function, or ends in `unreachable` (after a call that
    /// does not return), is unlikely. A block whose every successor is rare is too (cold when each one is),
    /// and so is a block the entry reaches only through rare blocks (cold when only through cold ones). It
    /// only adds marks.
    pub(package) fn estimate(self: &mut Self, pk: &Package, b: &mut Body) {
        if b.naked {
            return;
        }
        // The marks change no analysis `tables` keeps.
        self.tables(pk, b, K_GRAPH);
        let nb = b.blocks.len();
        for k in 0..nb {
            let bk = b.blocks[k];
            let mut f = bk.flags;
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                if t.op == O_PANIC {
                    f |= BLOCK_COLD;
                } else if t.op == O_UNREACHABLE || t.op == O_CALL && pk.syms[b.syms[t.a as usize] as usize].cold {
                    f |= BLOCK_UNLIKELY;
                }
            }
            b.blocks.index_mut(k).flags = f;
        }
        let n = self.order.len();
        let mut seen = Vector::<bool>::new();
        // Each round but the last adds a mark to a block: at most two per block.
        for _ in 0..2 * n + 1 {
            let mut changed = false;
            // The successors, in postorder.
            for i in 0..n {
                let k = self.order[n - 1 - i] as usize;
                if self.succ_at[k] == self.succ_at[k + 1] {
                    continue;
                }
                let mut all = BLOCK_RARE;
                for e in self.succ_at[k]..self.succ_at[k + 1] {
                    let f = b.blocks[self.succs[e as usize] as usize].flags;
                    all &= if (f & BLOCK_COLD) != 0 {
                        BLOCK_RARE
                    } else {
                        f & BLOCK_UNLIKELY
                    };
                }
                let add = if all == BLOCK_RARE {
                    BLOCK_COLD
                } else {
                    all
                };
                if (b.blocks[k].flags | add) != b.blocks[k].flags {
                    b.blocks.index_mut(k).flags |= add;
                    changed = true;
                }
            }
            // The blocks reached only through marked ones.
            changed = self.unreached(b, BLOCK_COLD, BLOCK_COLD, &mut seen) || changed;
            changed = self.unreached(b, BLOCK_RARE, BLOCK_UNLIKELY, &mut seen) || changed;
            if !changed {
                return;
            }
        }
        assert(false, "opt: the rare blocks do not settle");
    }

    // Mark `add` on each reachable block of `b` the entry reaches only through a block marked in `mask`
    // (`graph`'s); none when the entry is marked. Whether any was not marked yet.
    fn unreached(self: &mut Self, b: &mut Body, mask: u16, add: u16, seen: &mut Vector<bool>) bool {
        if (b.blocks[0].flags & mask) != 0 {
            return false;
        }
        let nb = b.blocks.len();
        fill(seen, nb, false);
        seen[0] = true;
        self.stack.truncate(0);
        self.stack.push(0);
        // Each block enters the stack once.
        while self.stack.len() != 0 {
            let k = self.stack.pop().unwrap() as usize;
            for e in self.succ_at[k]..self.succ_at[k + 1] {
                let s = self.succs[e as usize] as usize;
                if !seen[s] && (b.blocks[s].flags & mask) == 0 {
                    seen[s] = true;
                    self.stack.push(s as u64);
                }
            }
        }
        let mut changed = false;
        for k in 0..nb {
            if self.rpo[k] != NONE && !seen[k] && (b.blocks[k].flags & mask) == 0 {
                b.blocks.index_mut(k).flags |= add;
                changed = true;
            }
        }
        return changed;
    }

    // `wgt` for body `b`: an instruction weighs 16 per loop around it, up to three; and the instruction
    // count with each instruction weighed, a vector load from a slot (`lir::slp`'s gathers) GATHER_COST
    // more.
    fn weigh(self: &mut Self, pk: &Package, b: &Body) u64 {
        self.tables(pk, b, K_NEST);
        let nb = b.blocks.len();
        self.wgt.truncate(0);
        let mut sum: u64 = 0;
        for k in 0..nb {
            let mut depth: u32 = 0;
            let mut h = self.inner[k];
            // Each step leaves one loop.
            while h != NONE && depth < nb as u32 {
                depth += 1;
                h = self.lparent[h as usize];
            }
            let w = 1u64 << (4 * depth.min(3)) as u64;
            self.wgt.push(w);
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                let gather = t.op == O_LOAD && is_vec(t.ty) && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_SLOTADDR;
                sum += w * if gather {
                    1 + GATHER_COST
                } else {
                    1u64
                };
            }
        }
        return sum;
    }

    /// Rotate the innermost loops of body `b` whose header holds at most `max` instructions
    /// (`lir::loops`), then optimize it again. Whether any changed.
    pub(package) fn rotate(self: &mut Self, pk: &Package, b: &mut Body, max: u32) bool {
        if b.naked {
            return false;
        }
        self.tables(pk, b, K_NEST);
        let any = self.unr.rotate(b, max, &self.inner, &self.lparent, &self.preh, &self.dpre, &self.dpost);
        if !any {
            return false;
        }
        self.kept = K_NONE;
        let _ = self.run(pk, b, true);
        return true;
    }

    /// Transform the innermost loops of body `b` (`lir::loops`) within budgets `bu`, then optimize it
    /// again. Whether any changed.
    pub(package) fn loop_opts(self: &mut Self, pk: &Package, b: &mut Body, bu: lu::Budgets) bool {
        if b.naked {
            return false;
        }
        self.tables(pk, b, K_NEST);
        let pre = self.preheaders(b);
        self.tables(pk, b, K_MEM);
        self.unr.vops = pk.vops;
        let any = self.unr.run(
            b,
            pk.ptr_bytes,
            pk.fmath,
            pk.vector,
            bu,
            &self.inner,
            &self.lparent,
            &self.preh,
            &self.dpre,
            &self.dpost,
            lu::Classes {
                acc: self.acls.as_slice(),
                obj: self.aobj.as_slice(),
                member: self.imem.as_slice(),
                scoped: self.sbits,
                root: self.croot.as_slice(),
            },
        );
        // A transform that does not apply leaves the body as it was: the preheaders no transform used go.
        if !any {
            if pre {
                self.unpreheaders(b);
            }
            return false;
        }
        self.kept = K_NONE;
        let _ = self.run(pk, b, true);
        return true;
    }

    /// Give each loop exit of body `b` that passes arguments from a branch whose other side stays in the
    /// loop a block of its own that jumps on with them: the native layout places that block after the
    /// loop, so the loop's path takes no branch around the exit's moves. Whether any.
    pub(package) fn split_exits(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if b.naked {
            return false;
        }
        self.tables(pk, b, K_NEST);
        let none: []u8 = [];
        let noargs: []Value = [];
        let nb = b.blocks.len();
        let mut any = false;
        for k in 0..nb {
            let h = self.inner[k];
            let i = (b.blocks[k].start + b.blocks[k].len - 1) as usize;
            let mut t = b.insts[i];
            if h == NONE || t.op != O_BR {
                continue;
            }
            let ib = self.in_loop(h, b.edge_target(t.b));
            if ib == self.in_loop(h, b.edge_target(t.c)) {
                continue;
            }
            let e = if ib {
                t.c
            } else {
                t.b
            };
            if b.edge_nargs(e) == 0 {
                continue;
            }
            let x = b.add_block(none);
            b.begin(x);
            let _ = b.emit(jump(e), b.locs[i]);
            if b.inl.len() != 0 {
                b.inl.push(b.inl[i]);
            }
            let ne = b.edge(x, noargs);
            if ib {
                t.c = ne;
            } else {
                t.b = ne;
            }
            b.insts[i] = t;
            any = true;
        }
        if any {
            self.kept = K_NONE;
        }
        return any;
    }

    /// Turn each call of body `b`'s own function (body `j`) whose result its block returns at once into a
    /// jump back to the body's start with the call's arguments (tail recursion elimination, LLVM's
    /// TailCallElim; `Package.tail`): a new entry block jumps to the old one, which the calls' jumps then
    /// enter too. A call whose block returns `op(call, x)` instead, `op` an integer add, mul, and, or or xor
    /// (associative and commutative) and the same for every such call, keeps `x` in an accumulator (LLVM's
    /// accumulator recursion elimination): the jumps enter a block between the new entry and the old one
    /// whose last parameter the accumulator is, `op`'s identity first, and every other return gives
    /// `op(accumulator, value)`. Only when the call's signature is the body's, no parameter or result is an
    /// aggregate (an aggregate argument is a copy in the caller's frame) and no slot's address escapes (each
    /// call had a frame of its own). Whether any call did.
    pub(package) fn tail_self(self: &mut Self, pk: &Package, b: &mut Body, j: u32) bool {
        if !pk.tail || b.naked || b.sig == NONE || (b.pool[b.sig as usize + 1] & SIG_VARIADIC) != 0 {
            return false;
        }
        let np = b.pool[b.sig as usize];
        for k in 0..np + 1 {
            // The result, then the parameters.
            let code = b.pool[(b.sig + 2 + k) as usize];
            if (code & AGG) != 0 {
                return false;
            }
        }
        let nb = b.blocks.len() as u32;
        // Per site, its block, its call and whether it accumulates; `aop` the accumulating sites' operation.
        let mut sites = Vector::<(u32, u32, bool)>::new();
        let mut aop: u8 = 0;
        let mut accs = false;
        let mut mixed = false;
        for k in 0..nb {
            let bk = b.blocks[k as usize];
            if bk.len < 2 {
                continue;
            }
            let ri = bk.start + bk.len - 1;
            let r = b.insts[ri as usize];
            if r.op != O_RET {
                continue;
            }
            let ai = acc_call(pk, b, j, bk.start, ri);
            let acc = ai != NONE;
            let ci = if acc {
                ai
            } else {
                ri - 1
            };
            let c = b.insts[ci as usize];
            if !self_call(pk, b, j, c) || !same_sig(b, c.b, b.sig) || !acc && r.a != ci && !(c.ty == T_NONE && r.a == VNONE) {
                continue;
            }
            if acc {
                let op = b.insts[ri as usize - 1].op;
                mixed = mixed || accs && aop != op;
                aop = op;
                accs = true;
            }
            sites.push((k, ci, acc));
        }
        if mixed {
            sites.retain(|s: &(u32, u32, bool)| !s.2);
            accs = false;
        }
        if sites.len() == 0 || lv::frame_escapes(b) {
            return false;
        }
        // The new entry: the old one's parameters again, passed on to it, through the accumulator's block
        // `h` when a site accumulates.
        let e0 = b.blocks[0];
        let mut types = Vector::<u8>::with_capacity(e0.param_len as usize + 1);
        for q in 0..e0.param_len as u32 {
            types.push(b.params[(e0.param_start + q) as usize]);
        }
        let ne = b.add_block(&types);
        let mut args = Vector::<Value>::with_capacity(types.len() + 1);
        for q in 0..e0.param_len as u32 {
            args.push(b.param(ne, q));
        }
        let at = b.locs[e0.start as usize];
        let rty = b.pool[(b.sig + 2) as usize] as u8;
        let mut into = ne;
        let mut accv = VNONE;
        if accs {
            types.push(rty);
            let h = b.add_block(&types);
            b.begin(ne);
            let bits = type_bytes(rty, pk.ptr_bytes) * 8;
            let id = if aop == O_MUL {
                1u64
            } else if aop != O_AND {
                0u64
            } else if bits == 64 {
                ~0u64
            } else {
                (1u64 << bits as u64) - 1
            };
            args.push(b.emit(iconst(rty, id), at));
            let _ = b.emit(jump(b.edge(h, &args)), at);
            args.truncate(0);
            for q in 0..e0.param_len as u32 {
                args.push(b.param(h, q));
            }
            b.begin(h);
            let _ = b.emit(jump(b.edge(ne, &args)), at);
            if b.inl.len() != 0 {
                b.inl.push(0);
                b.inl.push(0);
                b.inl.push(0);
            }
            into = h;
            accv = b.param(h, e0.param_len);
        } else {
            b.begin(ne);
            let _ = b.emit(jump(b.edge(ne, &args)), at);
            if b.inl.len() != 0 {
                b.inl.push(0);
            }
        }
        let old = b.blocks[0];
        b.blocks.set(0, b.blocks[ne as usize]);
        b.blocks.set(ne as usize, old);
        // Each call: a jump to the old entry (now block `ne`), or to `h`, with its arguments and the
        // accumulator, its return gone. An accumulating call's `op` takes the accumulator for the call's
        // result, the call a constant the next walk drops, the return the jump.
        for x in 0..sites.len() {
            let (k, ci, acc) = sites[x];
            let c = b.insts[ci as usize];
            args.truncate(0);
            for q in 0..np {
                args.push(b.pool[(c.c + q) as usize]);
            }
            if !acc {
                if accs {
                    args.push(accv);
                }
                b.insts[ci as usize] = jump(b.edge(into, &args));
                b.blocks.index_mut(k as usize).len -= 1;
                continue;
            }
            let bk = b.blocks[k as usize];
            let oi = bk.start + bk.len - 2;
            let mut o = b.insts[oi as usize];
            let v = if o.a == ci {
                o.b
            } else {
                o.a
            };
            o.a = accv;
            o.b = v;
            b.insts[oi as usize] = o;
            b.insts[ci as usize] = iconst(c.ty, 0);
            args.push(oi);
            b.insts[oi as usize + 1] = jump(b.edge(into, &args));
        }
        // Every other return: through `op(accumulator, value)`.
        if accs {
            let rt: []u8 = [rty];
            let xb = b.add_block(rt);
            for k in 0..xb {
                let bk = b.blocks[k as usize];
                let ri = bk.start + bk.len - 1;
                if bk.len != 0 && b.insts[ri as usize].op == O_RET {
                    let v: []Value = [b.insts[ri as usize].a];
                    b.insts[ri as usize] = jump(b.edge(xb, v));
                }
            }
            b.begin(xb);
            let s = b.emit(Inst { op: aop, ty: rty, aux: 0, a: accv, b: b.param(xb, 0), c: VNONE }, at);
            let _ = b.emit(Inst { op: O_RET, ty: T_NONE, aux: 0, a: s, b: VNONE, c: VNONE }, at);
            if b.inl.len() != 0 {
                b.inl.push(0);
                b.inl.push(0);
            }
        }
        self.kept = K_NONE;
        return true;
    }

    /// Split each 128-bit integer of body `b` into its two 64-bit words (`Package.pairs`, `lir::pairs`).
    /// Whether any was.
    pub(package) fn split_pairs(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if !pk.pairs || b.naked || !pa::has_i128(b) {
            return false;
        }
        self.tables(pk, b, K_GRAPH);
        self.pairs.run(b, &self.order, &self.rpo, &mut self.pbody);
        let nb = replace(&mut self.pbody, Body::new());
        self.pbody = replace(b, nb);
        self.kept = K_NONE;
        return true;
    }

    /// Split each vector of body `b` wider than the native backend's registers into register-wide parts
    /// (`lir::wide`). Whether `b` had one.
    pub(package) fn split_wide(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if pk.vector == 0 || b.naked || !wd::has_wide(b, pk.vector) {
            return false;
        }
        self.tables(pk, b, K_GRAPH);
        self.wide.run(b, pk.vector, &self.order, &self.rpo, &mut self.pbody);
        let nb = replace(&mut self.pbody, Body::new());
        self.pbody = replace(b, nb);
        self.kept = K_NONE;
        return true;
    }

    /// Keep in a register the place each innermost loop of body `b` reads and writes through an exclusive
    /// pointer from outside the loop (LLVM's LICM scalar promotion), when the loop has a preheader, calls
    /// nothing and no other access of it may touch the place's bytes: a new slot takes the place's accesses
    /// in the loop, loaded from the place in a block between the preheader and the loop and stored back to
    /// it in a block on each edge out; the promotion of `run` makes the slot values. Whether any loop's did.
    pub(package) fn promote_places(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if b.naked {
            return false;
        }
        self.tables(pk, b, K_MEM);
        self.fresh(b);
        let nb = b.blocks.len();
        fill(&mut self.touched, nb, false);
        let none: []u8 = [];
        let noargs: []Value = [];
        let mut any = false;
        for h in 0..nb as u32 {
            let s = self.place_of(pk, b, h);
            if s == NONE {
                continue;
            }
            let st = b.insts[s as usize];
            let ty = b.type_of(st.b);
            let al = type_align(ty, pk.ptr_bytes).trailing_zeros() as u16;
            let slot = b.slot(type_bytes(ty, pk.ptr_bytes), al as u8);
            // The block before the loop: the place's value into the slot.
            let pre = self.preh[h as usize];
            let pi = b.blocks[pre as usize].start + b.blocks[pre as usize].len - 1;
            let pt = b.insts[pi as usize];
            let nk = b.add_block(none);
            b.begin(nk);
            let loc = b.locs[pi as usize];
            let sa = b.emit(Inst { op: O_SLOTADDR, ty: T_PTR, aux: 0, a: slot, b: 0, c: 0 }, loc);
            let v = b.emit(Inst { op: O_LOAD, ty: ty, aux: st.aux, a: st.a, b: VNONE, c: st.c }, loc);
            let _ = b.emit(Inst { op: O_STORE, ty: T_NONE, aux: al, a: sa, b: v, c: 0 }, loc);
            let _ = b.emit(pt, loc);
            if b.inl.len() != 0 {
                for _ in 0..4 {
                    b.inl.push(b.inl[pi as usize]);
                }
            }
            b.insts[pi as usize] = jump(b.edge(nk, noargs));
            self.touched[pre as usize] = true;
            let r = self.lb_at[h as usize];
            for q in (r >> 32) as u32..r as u32 {
                let x = self.lbs[q as usize] as usize;
                self.touched[x] = true;
                let bk = b.blocks[x];
                // The loop's accesses of the place: the slot's.
                for i in bk.start..bk.start + bk.len {
                    let t = b.insts[i as usize];
                    if (t.op == O_LOAD || t.op == O_STORE) && t.a == st.a && t.c == st.c {
                        b.insts[i as usize] = Inst { op: t.op, ty: t.ty, aux: al, a: sa, b: t.b, c: 0 };
                    }
                }
                // Each edge out: a block that stores the slot's value back to the place, then goes on.
                let ti = bk.start + bk.len - 1;
                let mut t = b.insts[ti as usize];
                b.succ_edges(t, &mut self.edges);
                for q in 0..self.edges.len() {
                    let e = self.edges[q];
                    let to = b.edge_target(e);
                    if self.inner[to as usize] == h {
                        continue;
                    }
                    let ek = b.add_block(none);
                    b.blocks.index_mut(ek as usize).flags = b.blocks[to as usize].flags & BLOCK_RARE;
                    b.begin(ek);
                    let l = b.locs[ti as usize];
                    let w = b.emit(Inst { op: O_LOAD, ty: ty, aux: al, a: sa, b: VNONE, c: 0 }, l);
                    let _ = b.emit(Inst { op: O_STORE, ty: T_NONE, aux: st.aux, a: st.a, b: w, c: st.c }, l);
                    let _ = b.emit(jump(e), l);
                    if b.inl.len() != 0 {
                        for _ in 0..3 {
                            b.inl.push(b.inl[ti as usize]);
                        }
                    }
                    let ne = b.edge(ek, noargs);
                    if t.op == O_JMP {
                        t.a = ne;
                    } else if q == 0 {
                        t.b = ne;
                    } else {
                        t.c = ne;
                    }
                }
                b.insts[ti as usize] = t;
            }
            any = true;
        }
        if any {
            self.kept = K_NONE;
        }
        return any;
    }

    // The store that names the place `promote_places` keeps in a register for loop `h`: an innermost loop
    // with a preheader no earlier loop's change touched, whose blocks end in jumps and branches and hold no
    // call nor other access of memory but loads and stores. The place: a store's address from outside the
    // loop, of an exclusive class, and an offset; a scalar that a load of the loop reads too, whose load
    // before the loop cannot fault; every other access of the loop of another class (neither may be any),
    // of other bytes of the same address, or of another type tag. NONE when none.
    fn place_of(self: &Self, pk: &Package, b: &Body, h: u32) u32 {
        // The blocks the loop tables cover (`nest`'s): `promote_places` adds others.
        if self.inner[h as usize] != h || self.preh[h as usize] == NONE || self.touched[self.preh[h as usize] as usize] {
            return NONE;
        }
        let r = self.lb_at[h as usize];
        for q in (r >> 32) as u32..r as u32 {
            let x = self.lbs[q as usize] as usize;
            if self.touched[x] || self.inner[x] != h {
                return NONE;
            }
        }
        let mut cand = NONE;
        for q in (r >> 32) as u32..r as u32 {
            let x = self.lbs[q as usize] as usize;
            let bk = b.blocks[x];
            let te = b.insts[(bk.start + bk.len - 1) as usize].op;
            if te != O_JMP && te != O_BR {
                return NONE;
            }
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                if t.op != O_LOAD && t.op != O_STORE && (writes_memory(t) || t.op == O_VAARG) {
                    return NONE;
                }
                if cand == NONE && t.op == O_STORE && (t.aux & MEM_VOLATILE) == 0 && self.outside(t.a, h) && self.loop_acc(
                    i,
                    h,
                ) >= CL_NOALIAS && self.loop_acc(i, h) < CL_MANY {
                    cand = i;
                }
            }
        }
        if cand == NONE {
            return NONE;
        }
        let s = b.insts[cand as usize];
        let ty = b.type_of(s.b);
        let n = type_bytes(ty, pk.ptr_bytes) as i64;
        let cls = self.loop_acc(cand, h);
        let lo = (s.c as i32) as i64;
        if !(is_int(ty) && ty != T_I128 || ty == T_PTR || ty == T_F32 || ty == T_F64) {
            return NONE;
        }
        let mut read = false;
        for q in (r >> 32) as u32..r as u32 {
            let x = self.lbs[q as usize] as usize;
            let bk = b.blocks[x];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                if t.op != O_LOAD && t.op != O_STORE {
                    continue;
                }
                let tt = if t.op == O_LOAD {
                    t.ty
                } else {
                    b.type_of(t.b)
                };
                if t.a == s.a && t.c == s.c {
                    // The place itself, whole, in its type.
                    if tt != ty || (t.aux & MEM_VOLATILE) != 0 {
                        return NONE;
                    }
                    read = read || t.op == O_LOAD;
                    continue;
                }
                let c = self.loop_acc(i, h);
                let qlo = (t.c as i32) as i64;
                let apart = c < CL_MANY && c != cls || c == cls && t.a == s.a && (qlo + type_bytes(tt, pk.ptr_bytes) as i64 <= lo || lo + n <= qlo) || c >= CL_MANY && tbaa(
                    t,
                ) != 0 && tbaa(s) != 0 && tbaa(t) != tbaa(s);
                if !apart {
                    return NONE;
                }
            }
        }
        if !read || !self.safe_load(pk, b, Inst { op: O_LOAD, ty: ty, aux: s.aux, a: s.a, b: VNONE, c: s.c }) {
            return NONE;
        }
        return cand;
    }

    // Give each loop header no preheader enters one (LLVM's LoopSimplify): a block that the jumps and
    // branches from outside the loop enter instead, and that jumps on to the header: with the one such
    // edge's arguments, or with the header's parameters for several. A header a switch enters from
    // outside keeps none. Whether any.
    fn preheaders(self: &mut Self, b: &mut Body) bool {
        let nb = b.blocks.len();
        let mut any = false;
        fill(&mut self.pnew, nb, false);
        self.pundo.truncate(0);
        self.plen = [
            b.insts.len() as u32,
            b.locs.len() as u32,
            b.inl.len() as u32,
            b.params.len() as u32,
            b.pool.len() as u32,
            nb as u32,
        ];
        for h in 0..nb as u32 {
            if self.inner[h as usize] != h || self.preh[h as usize] != NONE || self.rpo[h as usize] == NONE {
                continue;
            }
            let mut ok = true;
            let mut n: u32 = 0;
            let mut one = NONE;
            for x in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
                let q = self.preds[x as usize];
                if !self.in_loop(h, q) {
                    let t = term(b, q);
                    ok = ok && (t.op == O_JMP || t.op == O_BR);
                    n += 1;
                    one = if t.op == O_JMP {
                        t.a
                    } else if b.edge_target(t.b) == h {
                        t.b
                    } else {
                        t.c
                    };
                    // A branch with both sides into the header is two edges.
                    if t.op == O_BR && b.edge_target(t.b) == h && b.edge_target(t.c) == h {
                        n += 1;
                    }
                }
            }
            if !ok || n == 0 {
                continue;
            }
            let hb = b.blocks[h as usize];
            let mut types = Vector::<u8>::with_capacity(hb.param_len as usize);
            let mut args = Vector::<Value>::with_capacity(hb.param_len as usize);
            if n == 1 {
                for q in 0..b.edge_nargs(one) {
                    args.push(b.edge_arg(one, q));
                }
            } else {
                for q in hb.param_start..hb.param_start + hb.param_len as u32 {
                    types.push(b.params[q as usize]);
                }
            }
            let loc = b.locs[hb.start as usize];
            let x = b.add_block(&types);
            for q in 0..types.len() as u32 {
                args.push(b.param(x, q));
            }
            b.begin(x);
            self.pnew.push(true);
            let into = b.edge(h, &args);
            let _ = b.emit(jump(into), loc);
            if b.inl.len() != 0 {
                b.inl.push(0);
            }
            for y in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
                let q = self.preds[y as usize];
                if self.in_loop(h, q) {
                    continue;
                }
                let i = (b.blocks[q as usize].start + b.blocks[q as usize].len - 1) as usize;
                let mut t = b.insts[i];
                self.pundo.push((i as u32, t));
                if t.op == O_JMP {
                    t.a = Opt::redirect(b, t.a, h, x, n == 1);
                } else {
                    t.b = Opt::redirect(b, t.b, h, x, n == 1);
                    t.c = Opt::redirect(b, t.c, h, x, n == 1);
                }
                b.insts[i] = t;
            }
            any = true;
        }
        if any {
            self.kept = K_NONE;
        }
        return any;
    }

    // Undo the last `preheaders`: the body as it was before it.
    fn unpreheaders(self: &mut Self, b: &mut Body) {
        // In reverse: a terminator rewritten twice gets its first form.
        let n = self.pundo.len();
        for q in 0..n {
            let (i, t) = self.pundo[n - 1 - q];
            b.insts[i as usize] = t;
        }
        b.insts.truncate(self.plen[0] as usize);
        b.locs.truncate(self.plen[1] as usize);
        b.inl.truncate(self.plen[2] as usize);
        b.params.truncate(self.plen[3] as usize);
        b.pool.truncate(self.plen[4] as usize);
        b.blocks.truncate(self.plen[5] as usize);
        self.pundo.truncate(0);
        self.kept = K_NONE;
    }

    // Take out each preheader `preheaders` made that the walk moved nothing into and that has no
    // parameters (the walk may have put those in place of the header's): the edge into it enters its
    // loop's header again, with the arguments its jump passes. The rebuild drops it.
    fn unenter(self: &mut Self, b: &mut Body) {
        self.kept = K_NONE;
        for q in 0..self.hoisted.len() {
            let k = (self.hoisted[q] >> 32) as usize;
            if k < self.pnew.len() {
                self.pnew[k] = false;
            }
        }
        let mut args = Vector::<Value>::new();
        for k in 0..b.blocks.len() {
            let i = (b.blocks[k].start + b.blocks[k].len - 1) as usize;
            let mut t = b.insts[i];
            if t.op == O_JMP {
                t.a = self.unentered(b, t.a, &mut args);
            } else if t.op == O_BR {
                t.b = self.unentered(b, t.b, &mut args);
                t.c = self.unentered(b, t.c, &mut args);
            }
            b.insts[i] = t;
        }
    }

    // Edge `e`, or the edge past the unused preheader it enters (`unenter`).
    fn unentered(self: &Self, b: &mut Body, e: u32, args: &mut Vector<Value>) u32 {
        let x = b.edge_target(e);
        if x as usize >= self.pnew.len() || !self.pnew[x as usize] || b.blocks[x as usize].param_len != 0 {
            return e;
        }
        let j = b.insts[b.blocks[x as usize].start as usize].a;
        args.truncate(0);
        for q in 0..b.edge_nargs(j) {
            args.push(b.edge_arg(j, q));
        }
        return b.edge(b.edge_target(j), args.as_slice());
    }

    // Edge `e` of `b`, entering block `x` when it enters `h`: without arguments when `bare`, else with
    // its own.
    fn redirect(b: &mut Body, e: u32, h: u32, x: u32, bare: bool) u32 {
        if b.edge_target(e) != h {
            return e;
        }
        let mut args = Vector::<Value>::with_capacity(b.edge_nargs(e) as usize);
        if !bare {
            for q in 0..b.edge_nargs(e) {
                args.push(b.edge_arg(e, q));
            }
        }
        return b.edge(x, &args);
    }

    // ---- Analysis --------------------------------------------------------------------------------------

    fn graph(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        self.succ_at.truncate(0);
        self.succs.truncate(0);
        for k in 0..nb {
            self.succ_at.push(self.succs.len() as u32);
            b.succ_edges(term(b, k as u32), &mut self.edges);
            for e in 0..self.edges.len() {
                self.succs.push(b.edge_target(self.edges[e]));
            }
        }
        self.succ_at.push(self.succs.len() as u32);
        // Postorder by an explicit-stack depth-first search (block << 1 | finished), then its reverse.
        fill(&mut self.rpo, nb, NONE);
        self.work.truncate(0);
        self.stack.truncate(0);
        self.stack.push(0);
        // Each pop finishes a block, visits one, or drops a repeat: at most 2 per block and 1 per edge.
        while self.stack.len() != 0 {
            let x = self.stack.pop().unwrap();
            let k = (x >> 1) as usize;
            if (x & 1) != 0 {
                self.work.push(k as u32);
                continue;
            }
            if self.rpo[k] != NONE {
                continue;
            }
            self.rpo[k] = 0;
            self.stack.push(k as u64 << 1 | 1);
            for e in self.succ_at[k]..self.succ_at[k + 1] {
                let s = self.succs[e as usize];
                if self.rpo[s as usize] == NONE {
                    self.stack.push(s as u64 << 1);
                }
            }
        }
        self.order.truncate(0);
        let n = self.work.len();
        for i in 0..n {
            let k = self.work[n - 1 - i];
            self.rpo[k as usize] = i as u32;
            self.order.push(k);
        }
        // The predecessors among the reached blocks, in block order: a block the rewrites left behind (a
        // branch folded, an edge threaded) enters nothing.
        fill(&mut self.pred_at, nb + 1, 0);
        for k in 0..nb {
            if self.rpo[k] != NONE {
                for e in self.succ_at[k]..self.succ_at[k + 1] {
                    self.pred_at[self.succs[e as usize] as usize + 1] += 1;
                }
            }
        }
        for k in 0..nb {
            self.pred_at[k + 1] += self.pred_at[k];
        }
        fill(&mut self.preds, self.pred_at[nb] as usize, 0);
        fill(&mut self.work, nb, 0);
        for k in 0..nb {
            if self.rpo[k] != NONE {
                for e in self.succ_at[k]..self.succ_at[k + 1] {
                    let s = self.succs[e as usize] as usize;
                    self.preds[(self.pred_at[s] + self.work[s]) as usize] = k as u32;
                    self.work[s] += 1;
                }
            }
        }
        self.block_map(b);
        self.operands(b);
    }

    // `ops_at`, `ops_arg`, `ops` for `b`: the passes over one body read its instructions' operands once.
    fn operands(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        self.ops_at.truncate(0);
        self.ops_arg.truncate(0);
        self.ops.truncate(0);
        self.ops_dst.truncate(0);
        for i in 0..ni {
            let t = b.insts[i];
            self.ops_at.push(self.ops.len() as u32);
            lv::uses_into(b, t, &mut self.ops);
            while self.ops_dst.len() < self.ops.len() {
                self.ops_dst.push(NONE);
            }
            self.ops_arg.push(self.ops.len() as u32);
            if is_terminator(t.op) {
                b.succ_edges(t, &mut self.edges);
                for e in 0..self.edges.len() {
                    let ed = self.edges[e];
                    let ps = b.blocks[b.edge_target(ed) as usize].param_start;
                    for q in 0..b.edge_nargs(ed) {
                        self.ops.push(b.edge_arg(ed, q));
                        self.ops_dst.push(ps + q);
                    }
                }
            }
        }
        self.ops_at.push(self.ops.len() as u32);
    }

    // Per block parameter and per instruction of `b`, its block (`pblock`, `blk_of`; NONE: none). The walk
    // moves instructions in it.
    fn block_map(self: &mut Self, b: &Body) {
        fill(&mut self.pblock, b.params.len(), NONE);
        fill(&mut self.blk_of, b.insts.len(), NONE);
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                self.pblock[q as usize] = k as u32;
            }
            for i in bk.start..bk.start + bk.len {
                self.blk_of[i as usize] = k as u32;
            }
        }
    }

    // Immediate dominators by Cooper, Harvey and Kennedy's iteration in reverse postorder, then the
    // dominator tree's children and its preorder and postorder numbers.
    fn dominators(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        fill(&mut self.idom, nb, NONE);
        self.idom[0] = 0;
        let mut changed = true;
        // A reducible graph settles in two passes; any graph in at most its block count.
        let mut passes: usize = 0;
        while changed && passes <= nb {
            changed = false;
            passes += 1;
            for i in 1..self.order.len() {
                let k = self.order[i] as usize;
                let mut d = NONE;
                for p in self.pred_at[k]..self.pred_at[k + 1] {
                    let q = self.preds[p as usize];
                    if self.idom[q as usize] == NONE {
                        continue;
                    }
                    d = if d == NONE {
                        q
                    } else {
                        self.intersect(d, q)
                    };
                }
                if d != self.idom[k] {
                    self.idom[k] = d;
                    changed = true;
                }
            }
        }
        fill(&mut self.kid_at, nb + 1, 0);
        for i in 1..self.order.len() {
            self.kid_at[self.idom[self.order[i] as usize] as usize + 1] += 1;
        }
        for k in 0..nb {
            self.kid_at[k + 1] += self.kid_at[k];
        }
        fill(&mut self.kids, self.order.len(), 0);
        fill(&mut self.work, nb, 0);
        for i in 1..self.order.len() {
            let k = self.order[i];
            let d = self.idom[k as usize] as usize;
            self.kids[(self.kid_at[d] + self.work[d]) as usize] = k;
            self.work[d] += 1;
        }
        fill(&mut self.dpre, nb, 0);
        fill(&mut self.dpost, nb, 0);
        let mut pre: u32 = 0;
        let mut post: u32 = 0;
        self.stack.truncate(0);
        self.stack.push(0);
        // Each block is pushed and finished once.
        while self.stack.len() != 0 {
            let x = self.stack.pop().unwrap();
            let k = (x >> 1) as usize;
            if (x & 1) != 0 {
                self.dpost[k] = post;
                post += 1;
                continue;
            }
            self.dpre[k] = pre;
            pre += 1;
            self.stack.push(k as u64 << 1 | 1);
            for c in self.kid_at[k]..self.kid_at[k + 1] {
                self.stack.push(self.kids[c as usize] as u64 << 1);
            }
        }
    }

    const fn intersect(self: &Self, a0: u32, c0: u32) u32 {
        let mut a = a0;
        let mut c = c0;
        // Each step climbs one dominator: at most the block count in all.
        while a != c {
            while self.rpo[a as usize] > self.rpo[c as usize] {
                a = self.idom[a as usize];
            }
            while self.rpo[c as usize] > self.rpo[a as usize] {
                c = self.idom[c as usize];
            }
        }
        return a;
    }

    // The alias class of every address value: CL_NOALIAS + k for one that comes from exclusive reference
    // parameter k (`Body.refs`) through address arithmetic, selects and block parameters, CL_OTHER for one
    // that comes from none, CL_MANY for one that may come from several. Two accesses of different classes,
    // neither CL_MANY, touch different bytes: the language makes the parameter the only path to its
    // referent during the call. A parameter whose value escapes (any use but as an access's address,
    // address arithmetic, a select, a comparison or a block argument) is not exclusive here: another
    // pointer may hold it. Joins at block parameters iterate in reverse postorder up to CLASS_ROUNDS
    // times; a body they do not settle in that many has no exclusive parameter.
    //
    // An inlined call's exclusive parameter (`Body.scopes`) is a class of its own past the parameters',
    // its roots pinned to it, that holds only for the accesses of the call's copy (`acc`, `imem`) and
    // only for the loops its roots are outside of (`loop_acc`): a root inside a loop is a new pointer in
    // each iteration, each a call of its own. A use of it outside the copy is no escape.
    //
    // The block an allocation returns (`ALLOC_FRESH`) is a class of its own past those, its call pinned
    // to it: no other pointer reaches the block until the pointer escapes, and returning it or freeing it
    // is no escape (no access of the body follows the one, any access of the block after the other is
    // undefined).
    fn classes(self: &mut Self, pk: &Package, b: &Body) {
        fill(&mut self.icls, b.insts.len(), CL_OTHER);
        fill(&mut self.pcls, b.params.len(), CL_OTHER);
        fill(&mut self.csite, CL_MANY as usize, NONE);
        fill(&mut self.croot, CL_MANY as usize, NONE);
        self.sbits = 0;
        self.fbits = 0;
        self.imem.truncate(0);
        let e = b.blocks[0];
        self.cnext = e.param_len;
        let mut seeds: u64 = 0;
        for k in 0..b.refs.len() {
            if (b.refs[k] & REF_NOALIAS) != 0 && k < (CL_FROZEN - CL_NOALIAS) as usize && k < e.param_len as usize {
                seeds |= 1u64 << k as u64;
            }
        }
        let mut cand: u64 = 0;
        if b.scopes.len() != 0 {
            cand = self.scope_seeds(b, seeds);
        }
        seeds |= cand;
        let fresh = self.fresh_seeds(pk, b);
        seeds |= fresh;
        let owned = self.owned_seeds(b, seeds, self.cnext + fresh.count_ones() as u32);
        seeds |= owned;
        // Each pass drops at least one seed that escapes.
        for _ in 0..CL_MANY {
            if seeds == 0 || !self.class_flow(b, seeds, fresh) {
                fill(&mut self.icls, b.insts.len(), CL_OTHER);
                fill(&mut self.pcls, b.params.len(), CL_OTHER);
                self.sbits = 0;
                return;
            }
            let mut kept = seeds & ~self.escaped(pk, b, cand << 1, fresh << 1);
            // An owned buffer's class goes with its parameter's: another pointer may then load the field.
            for idx in 0..(CL_FROZEN - CL_NOALIAS) as u64 {
                if (owned >> idx & 1) != 0 && (kept >> self.oparam[idx as usize] as u64 & 1) == 0 {
                    kept &= ~(1u64 << idx);
                }
            }
            if kept == seeds {
                self.sbits = (seeds & cand) << 1;
                self.fbits = (seeds & fresh) << 1;
                return;
            }
            seeds = kept;
        }
        assert(false, "opt: the escape passes do not settle");
    }

    // The scopes' seeds (bits of their class indices, past the parameters'): one per site and group whose
    // roots share one block and are no exclusive parameter; `csite`, `croot`, `sgroup` and the members
    // (`imem`) set.
    fn scope_seeds(self: &mut Self, b: &Body, params: u64) u64 {
        let e = b.blocks[0];
        let ni = b.insts.len();
        fill(&mut self.cgroup, CL_MANY as usize, NONE);
        let mut next = e.param_len as u32;
        let mut out: u64 = 0;
        fill(&mut self.sgroup, b.scopes.len(), NONE);
        for x in 0..b.scopes.len() {
            let sc = b.scopes[x];
            let r = sc.root;
            let blk = if r == VNONE {
                NONE
            } else if (r & VPARAM) != 0 {
                self.pblock[(r & ~VPARAM) as usize]
            } else {
                self.blk_of[(r & ~VFLAG) as usize]
            };
            let k = entry_param(b, r);
            // The class of an earlier scope of the same site and group; none once the classes ran out.
            let mut idx = NONE;
            for c in CL_NOALIAS as u32 + e.param_len as u32..CL_NOALIAS as u32 + next {
                if self.csite[c as usize] == sc.site && self.cgroup[c as usize] == sc.group {
                    idx = c - CL_NOALIAS as u32;
                }
            }
            if idx == NONE && next < (CL_FROZEN - CL_NOALIAS) as u32 {
                idx = next;
                next += 1;
                out |= 1u64 << idx as u64;
                self.csite[(CL_NOALIAS as u32 + idx) as usize] = sc.site;
                self.cgroup[(CL_NOALIAS as u32 + idx) as usize] = sc.group;
                self.croot[(CL_NOALIAS as u32 + idx) as usize] = blk;
            }
            self.sgroup[x] = idx;
            self.cnext = next;
            // A group's roots in two blocks, or one that is an exclusive parameter, end it.
            if idx != NONE && (blk == NONE || self.croot[(CL_NOALIAS as u32 + idx) as usize] != blk || k < 64 && (params >> k as u64 & 1) != 0) {
                out &= ~(1u64 << idx as u64);
            }
        }
        if out == 0 || b.inl.len() != ni {
            return 0;
        }
        fill(&mut self.site_cls, b.lines.len(), 0);
        for c in CL_NOALIAS..CL_MANY {
            if (out >> (c - CL_NOALIAS) as u64 & 1) != 0 {
                self.site_cls[self.csite[c as usize] as usize] |= class_bit(c);
            }
        }
        fill(&mut self.imem, ni, 0);
        for i in 0..ni {
            self.imem[i] = self.site_cls[b.inl[i] as usize];
        }
        return out;
    }

    // The allocations' seeds (bits of their class indices, from `cnext`): each call of an `ALLOC_FRESH`
    // function that returns a pointer, while class indices are left; `fcall` set.
    fn fresh_seeds(self: &mut Self, pk: &Package, b: &Body) u64 {
        fill(&mut self.fcall, CL_MANY as usize, NONE);
        let mut out: u64 = 0;
        let mut next = self.cnext;
        for i in 0..b.insts.len() {
            if next >= (CL_FROZEN - CL_NOALIAS) as u32 {
                break;
            }
            let t = b.insts[i];
            if t.op == O_CALL && t.ty == T_PTR && call_alloc(pk, b, t) == ALLOC_FRESH {
                self.fcall[next as usize] = i as u32;
                out |= 1u64 << next as u64;
                next += 1;
            }
        }
        return out;
    }

    // The owned buffers' seeds (bits of their class indices, from `start`): per `Body.owned` field of an
    // exclusive parameter `params` holds (no view), while class indices are left, unless an address into
    // the parameter's referent has a use but as an access's address, the base of address arithmetic or a
    // comparison's operand (a copy, a call or a join could reach the field another way), or an access may
    // touch the field's bytes but a pointer load of exactly them, which `oload` pins to the class (a load
    // of it elsewhere would give a pointer of no class); `oparam`, `ooff` set. The user's promise
    // (`@owned`): while the parameter lives, no pointer but one loaded from the field reaches the buffer.
    fn owned_seeds(self: &mut Self, b: &Body, params: u64, start: u32) u64 {
        self.oload.truncate(0);
        if b.owned.len() == 0 {
            return 0;
        }
        fill(&mut self.oparam, CL_MANY as usize, NONE);
        fill(&mut self.ooff, CL_MANY as usize, 0);
        let mut out: u64 = 0;
        let mut next = start;
        for x in 0..b.owned.len() {
            let k = (b.owned[x] >> 32) as u32;
            if next >= (CL_FROZEN - CL_NOALIAS) as u32 {
                break;
            }
            if k < 64 && (params >> k as u64 & 1) != 0 && !inner(b, k) {
                self.oparam[next as usize] = k;
                self.ooff[next as usize] = b.owned[x] as u32;
                out |= 1u64 << next as u64;
                next += 1;
            }
        }
        if out == 0 {
            return 0;
        }
        // Per instruction, the parameter its address arithmetic starts from and the constant offset. Each
        // pass sets one more or ends: at most `ni + 1`.
        let ni = b.insts.len();
        fill(&mut self.oder, ni, NONE);
        self.ooffs.truncate(0);
        for _ in 0..ni {
            self.ooffs.push(OFF_ANY);
        }
        for _ in 0..ni + 1 {
            let mut changed = false;
            for i in 0..ni {
                let t = b.insts[i];
                if t.op != O_PTRADD || self.oder[i] != NONE {
                    continue;
                }
                let (k, o) = self.param_at(b, t.a);
                if k == NONE {
                    continue;
                }
                let n = if t.b == VNONE {
                    Option::<u64>::Some(0)
                } else {
                    const_of(b, t.b)
                };
                self.oder[i] = k;
                self.ooffs[i] = if o == OFF_ANY || n.is_none() {
                    OFF_ANY
                } else {
                    o + n.unwrap() as i64 * t.aux as i64 + (t.c as i32) as i64
                };
                changed = true;
            }
            if !changed {
                break;
            }
        }
        fill(&mut self.oload, ni, NONE);
        let mut lost: u64 = 0; // the parameters whose fields lose their classes
        let mut gone: u64 = 0;
        for i in 0..ni {
            let t = b.insts[i];
            let u0 = self.ops_at[i];
            for u in 0..self.ops_at[i + 1] - u0 {
                let v = self.ops[(u0 + u) as usize];
                let (k, o) = self.param_at(b, v);
                if k == NONE || k >= 64 {
                    continue;
                }
                let addr = t.op == O_LOAD && t.a == v && u == 0 || t.op == O_STORE && t.a == v && t.b != v || t.op == O_PTRADD && t.a == v && t.b != v || t.op == O_ICMP;
                if !addr {
                    lost |= 1u64 << k as u64;
                    continue;
                }
                if t.op != O_LOAD && t.op != O_STORE {
                    continue;
                }
                let ty = if t.op == O_LOAD {
                    t.ty
                } else {
                    b.type_of(t.b)
                };
                let at = if o == OFF_ANY {
                    OFF_ANY
                } else {
                    o + (t.c as i32) as i64
                };
                for idx in 0..(CL_FROZEN - CL_NOALIAS) as usize {
                    if (out >> idx as u64 & 1) == 0 || self.oparam[idx] != k {
                        continue;
                    }
                    let f = self.ooff[idx] as i64;
                    if at == OFF_ANY {
                        if ty == T_PTR || is_vec(ty) {
                            gone |= 1u64 << idx as u64;
                        }
                    } else if at == f && t.op == O_LOAD && ty == T_PTR {
                        self.oload[i] = idx as u32;
                    } else if at < f + 8 && f < at + type_bytes(ty, 8) as i64 {
                        gone |= 1u64 << idx as u64;
                    }
                }
            }
        }
        for idx in 0..(CL_FROZEN - CL_NOALIAS) as usize {
            if (out >> idx as u64 & 1) != 0 && (lost >> self.oparam[idx] as u64 & 1) != 0 {
                gone |= 1u64 << idx as u64;
            }
        }
        return out & ~gone;
    }

    // The entry parameter value `v` of `b` is or is address arithmetic on (`oder`), with the constant offset
    // (`ooffs`, OFF_ANY when not constant); NONE for none.
    fn param_at(self: &Self, b: &Body, v: Value) (u32, i64) {
        let k = entry_param(b, v);
        if k != NONE {
            return (k, 0i64);
        }
        if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || v as usize >= self.oder.len() {
            return (NONE, 0i64);
        }
        return (self.oder[v as usize], self.ooffs[v as usize]);
    }

    // The scope classes instruction `i` belongs to (`imem`).
    const fn member(self: &Self, i: u32) u64 {
        return if i as usize < self.imem.len() {
            self.imem[i as usize]
        } else {
            0u64
        };
    }

    // The class of instruction `i`'s access through address `a`: its address's, CL_MANY for a scope's
    // class outside that scope's copy.
    const fn acc(self: &Self, i: u32, a: Value) u8 {
        let c = self.class(a);
        if c < CL_MANY && (class_bit(c) & self.sbits) != 0 && (self.member(i) & class_bit(c)) == 0 {
            return CL_MANY;
        }
        return c;
    }

    // The class of load or store `i`'s access (`acls`) as loop `h` sees it: CL_MANY for a scope's whose
    // roots the loop holds.
    const fn loop_acc(self: &Self, i: u32, h: u32) u8 {
        let c = if i as usize < self.acls.len() {
            self.acls[i as usize]
        } else {
            CL_MANY
        };
        if c < CL_MANY && (class_bit(c) & self.sbits) != 0 && (self.croot[c as usize] == NONE || self.in_loop(
            h,
            self.croot[c as usize],
        )) {
            return CL_MANY;
        }
        return c;
    }

    // The classes of `classes` from the parameters, scopes and allocations `seeds` marks (the allocations'
    // bits `fresh`): whether the joins settled.
    fn class_flow(self: &mut Self, b: &Body, seeds: u64, fresh: u64) bool {
        let e = b.blocks[0];
        for i in 0..b.insts.len() {
            let op = b.insts[i].op;
            self.icls[i] = if op == O_PTRADD || op == O_SELECT {
                CL_UNSET
            } else {
                CL_OTHER
            };
        }
        fill(&mut self.pcls, b.params.len(), CL_UNSET);
        for q in e.param_start..e.param_start + e.param_len as u32 {
            let k = q - e.param_start;
            self.pcls[q as usize] = if k < 64 && (seeds >> k as u64 & 1) != 0 && !inner(b, k) {
                CL_NOALIAS + k as u8
            } else {
                CL_OTHER
            };
        }
        // The scopes' roots, pinned to their classes.
        fill(&mut self.ipin, b.insts.len(), false);
        fill(&mut self.ppin, b.params.len(), false);
        for x in 0..b.scopes.len() {
            let idx = self.sgroup[x];
            let r = b.scopes[x].root;
            if idx == NONE || (seeds >> idx as u64 & 1) == 0 || r == VNONE || (r & VFLAG) != 0 {
                continue;
            }
            let c = CL_NOALIAS + idx as u8;
            if (r & VPARAM) != 0 {
                if !self.ppin[(r & ~VPARAM) as usize] {
                    self.pcls[(r & ~VPARAM) as usize] = c;
                    self.ppin[(r & ~VPARAM) as usize] = true;
                }
            } else if !self.ipin[r as usize] {
                self.icls[r as usize] = c;
                self.ipin[r as usize] = true;
            }
        }
        // The allocations' blocks, pinned to their classes.
        for idx in 0..(CL_FROZEN - CL_NOALIAS) as u32 {
            if ((seeds & fresh) >> idx as u64 & 1) != 0 {
                let i = self.fcall[idx as usize] as usize;
                self.icls[i] = CL_NOALIAS + idx as u8;
                self.ipin[i] = true;
            }
        }
        // The owned buffers' pointer loads, pinned to their classes.
        for i in 0..self.oload.len() {
            let idx = self.oload[i];
            if idx != NONE && (seeds >> idx as u64 & 1) != 0 {
                self.icls[i] = CL_NOALIAS + idx as u8;
                self.ipin[i] = true;
            }
        }
        // A view parameter's elements: the pointer a load reads from its offset 0.
        let views = any_inner(b);
        for i in 0..b.insts.len() {
            if !views {
                break;
            }
            let t = b.insts[i];
            let k = entry_param(b, t.a);
            if t.op == O_LOAD && t.ty == T_PTR && t.c == 0 && k < 64 && (seeds >> k as u64 & 1) != 0 && inner(b, k) {
                self.icls[i] = CL_NOALIAS + k as u8;
            }
        }
        // Each round joins every value once; a value's class rises at most twice.
        for _ in 0..CLASS_ROUNDS {
            let mut changed = false;
            for o in 0..self.order.len() {
                let k = self.order[o];
                let bk = b.blocks[k as usize];
                for i in bk.start..bk.start + bk.len {
                    let t = b.insts[i as usize];
                    let c = if t.op == O_PTRADD {
                        self.class(t.a)
                    } else if t.op == O_SELECT {
                        join(self.class(t.b), self.class(t.c))
                    } else {
                        CL_OTHER
                    };
                    if (t.op == O_PTRADD || t.op == O_SELECT) && c != self.icls[i as usize] && !self.ipin[i as usize] {
                        self.icls[i as usize] = c;
                        changed = true;
                    }
                }
                // The edges' arguments (`operands`).
                let ti = (bk.start + bk.len - 1) as usize;
                for x in self.ops_arg[ti]..self.ops_at[ti + 1] {
                    let q = self.ops_dst[x as usize] as usize;
                    let c = join(self.pcls[q], self.class(self.ops[x as usize]));
                    if c != self.pcls[q] && !self.ppin[q] {
                        self.pcls[q] = c;
                        changed = true;
                    }
                }
            }
            if !changed {
                // A value of no reachable definition is no parameter's.
                for i in 0..self.icls.len() {
                    if self.icls[i] == CL_UNSET {
                        self.icls[i] = CL_OTHER;
                    }
                }
                for q in 0..self.pcls.len() {
                    if self.pcls[q] == CL_UNSET {
                        self.pcls[q] = CL_OTHER;
                    }
                }
                self.root_bases(b, seeds);
                return true;
            }
        }
        return false;
    }

    // Per scope class, the class its roots would have without their pins (`cbase`): a root is address
    // arithmetic or a select over values of that class, CL_MANY for a block parameter's.
    fn root_bases(self: &mut Self, b: &Body, seeds: u64) {
        fill(&mut self.cbase, CL_MANY as usize, CL_UNSET);
        for x in 0..b.scopes.len() {
            let idx = self.sgroup[x];
            let r = b.scopes[x].root;
            if idx == NONE || (seeds >> idx as u64 & 1) == 0 || r == VNONE || (r & VFLAG) != 0 {
                continue;
            }
            let s = CL_NOALIAS as usize + idx as usize;
            self.cbase[s] = join(self.cbase[s], self.unpinned(b, r, seeds));
        }
    }

    // The class pinned root `r` would have without its pin (`class_flow`'s rules, one step).
    const fn unpinned(self: &Self, b: &Body, r: Value, seeds: u64) u8 {
        if (r & VPARAM) != 0 {
            let k = entry_param(b, r);
            if k == NONE {
                return CL_MANY;
            }
            if k < 64 && (seeds >> k as u64 & 1) != 0 && !inner(b, k) {
                return CL_NOALIAS + k as u8;
            }
            return CL_OTHER;
        }
        let t = b.insts[r as usize];
        if t.op == O_PTRADD {
            return self.class(t.a);
        }
        if t.op == O_SELECT {
            return join(self.class(t.b), self.class(t.c));
        }
        return CL_OTHER;
    }

    // The classes (bits) a use of a value of class `c` lets escape at an instruction outside the copies of
    // the scope classes `foreign`: its own; for one of those scope classes, its roots' base's (`cbase`),
    // since past its copy a root is a pointer of that class.
    const fn escape_bits(self: &Self, c: u8, foreign: u64) u64 {
        let mut x = c;
        // Each step goes from a scope class to its roots' base; a cycle of roots ends with every class.
        for _ in 0..CL_MANY {
            if x >= CL_MANY || (class_bit(x) & foreign) == 0 {
                return class_bit(x) & ~foreign;
            }
            x = self.cbase[x as usize];
        }
        return class_bit(CL_MANY) & ~foreign;
    }

    // The parameters (bits) whose value escapes: a use of a value of their class but as an access's
    // address, address arithmetic's base, a select's operand, a comparison's operand, a block argument or
    // an argument of a parameter the callee does not let escape (`Sym.esc`; the call then writes the
    // class, `arg_bits`); for a view parameter (`REF_INNER`), any use of the parameter itself but as a
    // load's address. A scope class (bits `scoped`) escapes only through a use in its own copy, there
    // through any call argument too: its root may be an offset into a parameter's referent, and the
    // copy's accesses folded onto the parameter's address are of the parameter's class, which the call's
    // write would not reach; a use outside its copy is one of its roots' base (`escape_bits`). An
    // allocation's class (bits `fresh`) escapes not through a return or a free (`ALLOC_FREE`).
    fn escaped(self: &mut Self, pk: &Package, b: &Body, scoped: u64, fresh: u64) u64 {
        let views = any_inner(b);
        let mut out: u64 = 0;
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            let op = t.op;
            let u0 = self.ops_at[i];
            let nu = self.ops_arg[i] - u0;
            if views {
                for u in 0..self.ops_at[i + 1] - u0 {
                    let v = self.ops[(u0 + u) as usize];
                    let k = entry_param(b, v);
                    if k < 63 && inner(b, k) && !(op == O_LOAD && u == 0 && t.a == v) {
                        out |= 2u64 << k as u64;
                    }
                }
            }
            if op == O_LOAD || op == O_MEMCPY || op == O_MEMSET || op == O_PTRADD || op == O_SELECT || op == O_ICMP || op == O_JMP || op == O_BR || op == O_SWITCH {
                continue;
            }
            let foreign = scoped & ~self.member(i as u32);
            if op == O_STORE {
                out |= self.escape_bits(self.class(t.b), foreign);
                continue;
            }
            let freed = if op == O_RET || op == O_CALL && call_alloc(pk, b, t) == ALLOC_FREE {
                fresh
            } else {
                0u64
            };
            // A call's uses are its arguments.
            let kept = if op == O_CALL {
                ~pk.syms[b.syms[t.a as usize] as usize].esc
            } else {
                0u64
            };
            for u in 0..nu {
                let c = self.class(self.ops[(u0 + u) as usize]);
                if u < 64 && (kept >> u as u64 & 1) != 0 && (class_bit(c) & scoped) == 0 {
                    continue;
                }
                out |= self.escape_bits(c, foreign) & ~freed;
            }
        }
        return out >> 1;
    }

    // The alias class of value `v` (`classes`); CL_MANY for an instruction made after them.
    const fn class(self: &Self, v: Value) u8 {
        if v == VNONE || (v & VFLAG) != 0 {
            return CL_OTHER;
        }
        if (v & VPARAM) != 0 {
            let q = (v & ~VPARAM) as usize;
            return if q < self.pcls.len() {
                self.pcls[q]
            } else {
                CL_MANY
            };
        }
        return if v as usize < self.icls.len() {
            self.icls[v as usize]
        } else {
            CL_MANY
        };
    }

    // The alias classes block `k` of `b` writes (`class_bit`): a store's, a copy's or a fill's access
    // class (`acc`); CL_OTHER for any other write, which reaches no exclusive parameter's referent; and a
    // write outside a scope's copy, the scope's class too.
    fn writes_in(self: &Self, pk: &Package, b: &Body, k: u32) u64 {
        let bk = b.blocks[k as usize];
        let mut out: u64 = 0;
        for i in bk.start..bk.start + bk.len {
            let t = b.insts[i as usize];
            if self.private(t) {
                continue; // `pwrites_in`
            }
            if writes(pk, b, t) {
                out |= self.write_bits(pk, b, i);
            }
        }
        return out;
    }

    // The alias classes write `i` of `b` touches (`class_bit`): a store's, a copy's or a fill's access
    // class (`acc`); CL_OTHER for any other write, which reaches no exclusive parameter's referent; and,
    // outside a scope's copy, the scope's class too.
    // A free writes none.
    fn write_bits(self: &Self, pk: &Package, b: &Body, i: u32) u64 {
        let t = b.insts[i as usize];
        if call_alloc(pk, b, t) == ALLOC_FREE {
            return 0;
        }
        let c = if t.op == O_STORE || t.op == O_MEMCPY || t.op == O_MEMSET {
            self.acc(i, t.a)
        } else {
            CL_OTHER
        };
        return class_bit(c) | self.sbits & ~self.member(i) | self.arg_bits(b, i, t);
    }

    // The classes call `t`, instruction `i` of `b`, may write through its arguments (a class a callee does
    // not let escape stays, `escaped`); none for any other instruction.
    fn arg_bits(self: &Self, b: &Body, i: u32, t: Inst) u64 {
        let mut out: u64 = 0;
        if t.op == O_CALL || t.op == O_CALLIND {
            for q in 0..t.aux as u32 {
                out |= class_bit(self.acc(i, b.pool[(t.c + q) as usize]));
            }
        }
        return out;
    }

    // The plain stores of block `k` of `b` whose class is an exclusive parameter's, into `bst`; the classes
    // the block's other writes touch (`writes_in`'s, those stores' aside).
    fn note_stores(self: &mut Self, pk: &Package, b: &Body, k: u32) u64 {
        let bk = b.blocks[k as usize];
        let mut imp: u64 = 0;
        for i in bk.start..bk.start + bk.len {
            let t = b.insts[i as usize];
            if self.private(t) {
                continue;
            }
            let other = self.sbits & ~self.member(i);
            if t.op == O_STORE || t.op == O_MEMCPY || t.op == O_MEMSET {
                let c = self.acc(i, t.a);
                if t.op == O_STORE && (t.aux & MEM_VOLATILE) == 0 && c >= CL_NOALIAS && c < CL_MANY {
                    self.bst.push(i);
                    imp |= other;
                } else {
                    imp |= class_bit(c) | other;
                }
            } else if writes(pk, b, t) {
                imp |= class_bit(CL_OTHER) | other | self.arg_bits(b, i, t);
            }
        }
        return imp;
    }

    // Whether load `t` of class bit `cls`, an exclusive parameter's, reads no byte loop
    // `h` writes: every write of that class in the loop is a plain store through the load's address value
    // at a constant range apart from the load's (another field of the parameter's referent).
    fn fields_apart(self: &Self, pk: &Package, b: &Body, h: u32, t: Inst, cls: u64) bool {
        if (cls & cls - 1) != 0 || (cls & class_bit(CL_OTHER)) != 0 || (self.imprecise[h as usize] & cls) != 0 {
            return false;
        }
        let a = self.val(t.a);
        let lo = (t.c as i32) as i64;
        let hi = lo + type_bytes(t.ty, pk.ptr_bytes) as i64;
        let r = self.lst_at[h as usize];
        for x in (r >> 32) as u32..r as u32 {
            let si = self.lst[x as usize];
            if (class_bit(self.loop_acc(si, h)) & cls) == 0 {
                continue;
            }
            let st = b.insts[si as usize];
            if st.op != O_STORE || self.val(st.a) != a {
                return false;
            }
            let slo = (st.c as i32) as i64;
            let shi = slo + type_bytes(b.type_of(st.b), pk.ptr_bytes) as i64;
            if slo < hi && lo < shi {
                return false;
            }
        }
        return true;
    }

    // Whether block `k` of `b` writes a private slot's memory (`privates`).
    fn pwrites_in(self: &Self, b: &Body, k: u32) bool {
        let bk = b.blocks[k as usize];
        for i in bk.start..bk.start + bk.len {
            let t = b.insts[i as usize];
            if (t.op == O_STORE || t.op == O_MEMCPY || t.op == O_MEMSET) && self.private(t) {
                return true;
            }
        }
        return false;
    }

    // The type tags block `k` of `b` writes (bit 0: an untagged write, all of them; `write_tag`), a private
    // slot's writes aside (`pwrites_in`).
    fn tags_in(self: &Self, pk: &Package, b: &Body, k: u32) u16 {
        let bk = b.blocks[k as usize];
        let mut out: u16 = 0;
        for i in bk.start..bk.start + bk.len {
            let t = b.insts[i as usize];
            if self.private(t) {
                continue;
            }
            let g = write_tag(pk, b, t);
            if !writes(pk, b, t) || g >= TBAA_TAGS {
                continue;
            }
            // A volatile store, like any write but a store or a call, may touch any tag.
            out |= if t.op == O_STORE && (t.aux & MEM_VOLATILE) == 0 || t.op == O_CALL {
                1u16 << g as u16
            } else {
                1u16
            };
        }
        return out;
    }

    // Whether block `a` dominates block `x`.
    const fn dominates(self: &Self, a: u32, x: u32) bool {
        return self.dpre[a as usize] <= self.dpre[x as usize] && self.dpost[x as usize] <= self.dpost[a as usize];
    }

    // The natural loops: a back edge `u -> h` (`h` dominates `u`) makes `h` a header, and the blocks that
    // reach `u` without passing `h` its body (`lb_at`, `lbs`, in block order). A header dominates the headers of the loops inside its own, so in reverse postorder an
    // outer loop comes first: each block keeps the last loop that holds it, its innermost, and a header's
    // innermost loop before its own is its parent. A loop's preheader is its one predecessor outside it,
    // when that block only jumps to it.
    fn nest(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        fill(&mut self.inner, nb, NONE);
        fill(&mut self.lparent, nb, NONE);
        fill(&mut self.preh, nb, NONE);
        fill(&mut self.mark, nb, NONE);
        fill(&mut self.lb_at, nb, 0);
        self.lbs.truncate(0);
        for hi in 0..self.order.len() {
            let h = self.order[hi];
            self.work.truncate(0);
            for p in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
                let u = self.preds[p as usize];
                if self.dominates(h, u) && self.mark[u as usize] != h && u != h {
                    self.mark[u as usize] = h;
                    self.work.push(u);
                }
            }
            if self.work.len() == 0 && !self.has_pred(h, h) {
                continue;
            }
            self.lparent[h as usize] = self.inner[h as usize];
            self.inner[h as usize] = h;
            self.mark[h as usize] = h;
            self.lsort.truncate(0);
            self.lsort.push(h);
            // Each block enters the walk once.
            while self.work.len() != 0 {
                let x = self.work.pop().unwrap();
                self.inner[x as usize] = h;
                self.lsort.push(x);
                for p in self.pred_at[x as usize]..self.pred_at[x as usize + 1] {
                    let q = self.preds[p as usize];
                    if self.mark[q as usize] != h {
                        self.mark[q as usize] = h;
                        self.work.push(q);
                    }
                }
            }
            self.lsort.sort();
            let s0 = self.lbs.len() as u64;
            self.lbs.extend_copy(&self.lsort);
            self.lb_at[h as usize] = s0 << 32 | self.lbs.len() as u64;
            let mut outside = NONE;
            let mut n: u32 = 0;
            for p in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
                let q = self.preds[p as usize];
                if self.mark[q as usize] != h {
                    outside = q;
                    n += 1;
                }
            }
            if n == 1 && term(b, outside).op == O_JMP {
                self.preh[h as usize] = outside;
            }
        }
    }

    // The memory facts of body `b` and of the loops `nest` found: the private slots, the alias classes,
    // each load's and store's access class and object; per loop the classes, the type tags and the private
    // memory its blocks write, and its plain stores of an exclusive parameter's class, from one summary per
    // block in a loop.
    fn memory(self: &mut Self, pk: &Package, b: &Body) {
        let nb = b.blocks.len();
        fill(&mut self.writes, nb, 0);
        fill(&mut self.tags, nb, 0);
        fill(&mut self.pwrite, nb, false);
        fill(&mut self.lst_at, nb, 0);
        fill(&mut self.imprecise, nb, 0);
        self.lst.truncate(0);
        self.privates(b);
        self.classes(pk, b);
        // The classes of the loads' and stores' accesses before the walk forwards their addresses: a
        // parameter an inlined body's accesses go through, a scope's, becomes the caller's pointer.
        fill(&mut self.acls, b.insts.len(), CL_MANY);
        fill(&mut self.aobj, b.insts.len(), NONE);
        frozen(b, &mut self.frz);
        for i in 0..b.insts.len() {
            let op = b.insts[i].op;
            if op == O_LOAD && self.frz[i] {
                self.acls[i] = CL_FROZEN;
            } else if op == O_LOAD || op == O_STORE {
                self.acls[i] = self.acc(i as u32, b.insts[i].a);
            }
            if op == O_LOAD || op == O_STORE {
                self.aobj[i] = self.object(pk, b, b.insts[i].a);
            }
        }
        // Each block in a loop, once.
        fill(&mut self.bst_at, nb + 1, 0);
        self.bst.truncate(0);
        self.bw.truncate(0);
        self.bt.truncate(0);
        self.bpw.truncate(0);
        self.bimp.truncate(0);
        for k in 0..nb {
            self.bst_at[k] = self.bst.len() as u32;
            let inl = self.inner[k] != NONE;
            self.bw.push(
                if inl {
                    self.writes_in(pk, b, k as u32)
                } else {
                    0u64
                },
            );
            self.bt.push(
                if inl {
                    self.tags_in(pk, b, k as u32)
                } else {
                    0u16
                },
            );
            self.bpw.push(inl && self.pwrites_in(b, k as u32));
            self.bimp.push(
                if inl {
                    self.note_stores(pk, b, k as u32)
                } else {
                    0u64
                },
            );
        }
        self.bst_at[nb] = self.bst.len() as u32;
        // Each loop, outer ones first: its blocks' writes.
        for hi in 0..self.order.len() {
            let h = self.order[hi];
            if self.inner[h as usize] != h {
                continue;
            }
            let mut wr: u64 = 0;
            let mut tg: u16 = 0;
            let mut pw = false;
            let mut imp: u64 = 0;
            let s0 = self.lst.len() as u64;
            let r = self.lb_at[h as usize];
            for q in (r >> 32) as u32..r as u32 {
                let x = self.lbs[q as usize] as usize;
                wr |= self.bw[x];
                tg |= self.bt[x];
                pw = pw || self.bpw[x];
                imp |= self.bimp[x];
                for s in self.bst_at[x]..self.bst_at[x + 1] {
                    self.lst.push(self.bst[s as usize]);
                }
            }
            // A scope whose roots the loop holds is a call per iteration: its writes may reach any byte.
            for c in CL_NOALIAS..CL_MANY {
                if (wr & self.sbits & class_bit(c)) != 0 && self.croot[c as usize] != NONE && self.in_loop(
                    h,
                    self.croot[c as usize],
                ) {
                    wr = ~0u64;
                }
            }
            self.writes[h as usize] = wr;
            self.tags[h as usize] = tg;
            self.pwrite[h as usize] = pw;
            self.lst_at[h as usize] = s0 << 32 | self.lst.len() as u64;
            self.imprecise[h as usize] = imp;
        }
    }

    const fn has_pred(self: &Self, k: u32, p: u32) bool {
        for q in self.pred_at[k as usize]..self.pred_at[k as usize + 1] {
            if self.preds[q as usize] == p {
                return true;
            }
        }
        return false;
    }

    // Whether loop `h` holds block `x`.
    const fn in_loop(self: &Self, h: u32, x: u32) bool {
        let mut l = self.inner[x as usize];
        // Each step leaves one loop.
        while l != NONE {
            if l == h {
                return true;
            }
            l = self.lparent[l as usize];
        }
        return false;
    }

    // ---- The walk --------------------------------------------------------------------------------------

    // Whether an instruction changed.
    // The rebuild's tables for body `b` with nothing replaced, moved or made.
    // Its block map is `graph`'s (`block_map`): every caller runs on the body `tables` just read.
    fn fresh(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        assert(self.blk_of.len() == ni && self.pblock.len() == b.params.len(), "opt: the block map is the body's");
        fill(&mut self.repl, ni, VNONE);
        fill(&mut self.prepl, b.params.len(), VNONE);
        fill(&mut self.frepl, ni, VNONE);
        fill(&mut self.moved, ni, false);
        self.extra.truncate(0);
        self.hoisted.truncate(0);
        self.pre.truncate(0);
        self.unbiased.clear();
    }

    // The entry parameters that point at a by-value aggregate of at most PSLOT_MAX bytes (the body's own copy)
    // that only loads and stores at constant offsets and copies of a constant size address, and that a store
    // or a copy in a loop writes: each becomes a slot that a new entry block copies the aggregate into and
    // passes to the old one, for that parameter, which promotion then turns into values: a loop a tail
    // recursion made carries them in registers. Once per body; not when an edge enters the entry. Whether
    // any did.
    fn param_slots(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if b.sig == NONE || !self.pslots {
            return false;
        }
        self.pslots = false;
        let e = b.blocks[0];
        let np = b.pool[b.sig as usize].min(e.param_len).min(64);
        let mut cand: u64 = 0;
        for k in 0..np {
            let pt = b.pool[(b.sig + 3 + k) as usize];
            if (pt & AGG) != 0 && b.pool[(pt & ~AGG) as usize] <= PSLOT_MAX {
                cand |= 1u64 << k as u64;
            }
        }
        if cand == 0 {
            return false;
        }
        // Only where a loop writes it: elsewhere the walk forwards its stores to its loads.
        self.tables(pk, b, K_NEST);
        let mut looped: u64 = 0;
        for k in 0..b.blocks.len() {
            if self.inner[k] == NONE {
                continue;
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                let a = if t.op == O_STORE || t.op == O_MEMCPY {
                    t.a
                } else {
                    VNONE
                };
                if a != VNONE && (a & VPARAM) != 0 && (a & ~VPARAM) >= e.param_start && (a & ~VPARAM) < e.param_start + np {
                    looped |= 1u64 << ((a & ~VPARAM) - e.param_start) as u64;
                }
            }
        }
        cand &= looped;
        if cand == 0 {
            return false;
        }
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            self.fuses.truncate(0);
            lv::uses_into(b, t, &mut self.fuses);
            if is_terminator(t.op) {
                b.succ_edges(t, &mut self.edges);
                for x in 0..self.edges.len() {
                    if b.edge_target(self.edges[x]) == 0 {
                        return false;
                    }
                    for q in 0..b.edge_nargs(self.edges[x]) {
                        self.fuses.push(b.edge_arg(self.edges[x], q));
                    }
                }
            }
            for u in 0..self.fuses.len() {
                let v = self.fuses[u];
                if v == VNONE || (v & VPARAM) == 0 || (v & ~VPARAM) < e.param_start || (v & ~VPARAM) >= e.param_start + np {
                    continue;
                }
                let ok = t.op == O_LOAD && t.a == v || t.op == O_STORE && t.a == v && t.b != v || t.op == O_MEMCPY && t.a == v != (t.b == v) && const_of(
                    b,
                    t.c,
                ).is_some();
                if !ok {
                    cand &= ~(1u64 << ((v & ~VPARAM) - e.param_start) as u64);
                }
            }
        }
        if cand == 0 {
            return false;
        }
        // The new entry: the old one's parameters again, passed on to it but the copied ones' slots.
        let mut types = Vector::<u8>::with_capacity(e.param_len as usize);
        for q in 0..e.param_len as u32 {
            types.push(b.params[(e.param_start + q) as usize]);
        }
        let ne = b.add_block(&types);
        let mut args = Vector::<Value>::with_capacity(types.len());
        for q in 0..e.param_len as u32 {
            args.push(b.param(ne, q));
        }
        let at = b.locs[e.start as usize];
        let it = if pk.ptr_bytes == 8 {
            T_I64
        } else {
            T_I32
        };
        b.begin(ne);
        let mut made: u32 = 0;
        for k in 0..np {
            if (cand >> k as u64 & 1) == 0 {
                continue;
            }
            let lay = (b.pool[(b.sig + 3 + k) as usize] & ~AGG) as usize;
            let s = b.slots.len() as u32;
            b.slots.push(Slot { size: b.pool[lay], align_log2: b.pool[lay + 1] as u8 });
            let sa = b.emit(Inst { op: O_SLOTADDR, ty: T_PTR, aux: 0, a: s, b: VNONE, c: VNONE }, at);
            let n = b.emit(iconst(it, b.pool[lay]), at);
            let _ = b.emit(Inst { op: O_MEMCPY, ty: T_NONE, aux: 0, a: sa, b: args[k as usize], c: n }, at);
            args[k as usize] = sa;
            made += 3;
        }
        let _ = b.emit(jump(b.edge(ne, &args)), at);
        if b.inl.len() != 0 {
            for _ in 0..made + 1 {
                b.inl.push(0);
            }
        }
        let old = b.blocks[0];
        b.blocks.set(0, b.blocks[ne as usize]);
        b.blocks.set(ne as usize, old);
        self.kept = K_NONE;
        return true;
    }

    // The entry parameters (bits) that point at a by-value aggregate of at most 16 bytes, which the targets
    // pass in registers, that only loads outside cold blocks read: their loads may move to the entry's
    // start, where the code generator takes each part's register for its load and the aggregate needs no
    // memory.
    fn agg_params(self: &mut Self, b: &Body) u64 {
        if b.sig == NONE {
            return 0;
        }
        let np = b.pool[b.sig as usize];
        let ps = b.blocks[0].param_start;
        let mut out: u64 = 0;
        for k in 0..np {
            let pt = b.pool[(b.sig + 3 + k) as usize];
            if k < 64 && (pt & AGG) != 0 && b.pool[(pt & ~AGG) as usize] <= 16 {
                out |= 1u64 << k as u64;
            }
        }
        if out == 0 {
            return 0;
        }
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                let u0 = self.ops_at[i as usize];
                let nu = self.ops_at[i as usize + 1] - u0;
                for q in 0..nu {
                    let v = self.ops[(u0 + q) as usize];
                    if (v & VPARAM) == 0 || v == VNONE || (v & ~VPARAM) < ps || (v & ~VPARAM) - ps >= 64 {
                        continue;
                    }
                    let load = t.op == O_LOAD && t.a == v && (t.aux & MEM_VOLATILE) == 0 && nu == 1;
                    if !load || (bk.flags & BLOCK_COLD) != 0 {
                        out &= ~(1u64 << ((v & ~VPARAM) - ps) as u64);
                    }
                }
            }
        }
        return out;
    }

    fn walk(self: &mut Self, pk: &Package, b: &mut Body) bool {
        // The walk reads the analyses `tables` made for the body (`K_MEM`), then changes it.
        self.kept = K_NONE;
        let nb = b.blocks.len();
        self.fresh(b);
        self.made.clear();
        self.selected = false;
        self.unstored = false;
        // What `thread` made and replaced.
        for x in 0..self.textra.len() {
            let i = self.textra[x];
            self.extra.push(i);
            self.blk_of[i as usize] = 0;
            self.made.insert(hash(b.insts[i as usize]), i);
        }
        self.textra.truncate(0);
        for x in 0..self.trepl.len() {
            let r = self.trepl[x];
            self.repl[(r >> 32) as usize] = r as u32;
        }
        self.trepl.truncate(0);
        self.pure.clear();
        self.mem.clear();
        self.cond.clear();
        self.rel.clear();
        self.ub.clear();
        self.eqs.clear();
        self.log.truncate(0);
        self.places.truncate(0);
        fill(&mut self.end_state, nb * TBAA_TAGS, 0);
        fill(&mut self.end_recent, nb * RECENT_MAX, NONE);
        fill(&mut self.end_pstate, nb, 0);
        fill(&mut self.bwrites, nb, 0);
        fill(&mut self.rmark, nb, NONE);
        self.aggp = self.agg_params(b);
        for k in 0..nb {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                if writes(pk, b, t) && !self.private(t) {
                    let g = if (t.aux & MEM_VOLATILE) != 0 && (t.op == O_LOAD || t.op == O_STORE) {
                        0usize
                    } else {
                        write_tag(pk, b, t)
                    };
                    if g < TBAA_TAGS {
                        self.bwrites[k] |= 1u16 << g as u16;
                    }
                }
            }
        }
        let mut states: u32 = 0;
        let mut changed = false;
        // Preorder over the dominator tree: block << 1 enters a block, n << 33 | 1 closes its scope at log
        // length n.
        self.stack.truncate(0);
        self.stack.push(0);
        // Each block is entered and left once.
        while self.stack.len() != 0 {
            let x = self.stack.pop().unwrap();
            if (x & 1) != 0 {
                self.unwind((x >> 33) as usize);
                continue;
            }
            let k = (x >> 1) as usize;
            self.stack.push(self.log.len() as u64 << 33 | 1);
            // The places its dominator knew last; those of a state no longer current are not found.
            self.recent.truncate(0);
            for r in 0..RECENT_MAX {
                let at = if k == 0 {
                    NONE
                } else {
                    self.end_recent[self.idom[k] as usize * RECENT_MAX + r]
                };
                if at == NONE {
                    break;
                }
                self.recent.push(at);
            }
            if k != 0 && self.pred_at[k + 1] - self.pred_at[k] == 1 && self.preds[self.pred_at[k] as usize] == self.idom[k] {
                let d = self.idom[k] as usize * TBAA_TAGS;
                for g in 0..TBAA_TAGS {
                    unsafe self.tstate[g] = self.end_state[d + g];
                }
                self.pstate = self.end_pstate[self.idom[k] as usize];
                // Its parameters are its one edge's arguments.
                changed = self.forward_params(b, k as u32) || changed;
                // Its one edge decides its dominator's branch condition here and below.
                let t = term(b, self.idom[k]);
                if t.op == O_BR && b.edge_target(t.b) != b.edge_target(t.c) && const_of(b, t.a).is_none() {
                    let taken: u32 = if b.edge_target(t.b) == k as u32 {
                        1
                    } else {
                        0
                    };
                    self.enter(LOG_COND, t.a, taken);
                    self.order_facts(b, t.a, taken != 0);
                }
            } else if k != 0 {
                // Several edges enter: the tags no block between its dominator and it writes keep the
                // dominator's state; the others, and the untagged accesses when any is written, a new one.
                changed = self.same_args(b, k as u32) || changed;
                let w = self.between_writes(k as u32);
                states += 1;
                self.pstate = states;
                let d = self.idom[k] as usize * TBAA_TAGS;
                for g in 0..TBAA_TAGS {
                    let kept = w != WRITES_ALL && (w & 1) == 0 && (g == 0 && w == 0 || g != 0 && (w >> g as u32 & 1) == 0);
                    unsafe self.tstate[g] = if kept {
                        self.end_state[d + g]
                    } else {
                        states
                    };
                }
            } else {
                states += 1;
                self.tstate = [states; TBAA_TAGS];
                self.pstate = states;
            }
            let bk = b.blocks[k];
            self.pend.truncate(0);
            let mut called = false;
            for i in bk.start..bk.start + bk.len {
                // A write starts a new state for its tag's accesses and the untagged ones; an untagged
                // write, for all.
                let t = b.insts[i as usize];
                let g = write_tag(pk, b, t);
                let before = self.tstate;
                let pbefore = self.pstate;
                // An access of a private slot's memory has states of its own: no other access touches it.
                let private = self.private(t);
                self.prior = if private {
                    pbefore
                } else if g < TBAA_TAGS {
                    unsafe before[g]
                } else {
                    before[0]
                };
                self.pprior = pbefore;
                self.tprior = before[0];
                if writes(pk, b, t) && g < TBAA_TAGS {
                    states += 1;
                    if private {
                        self.pstate = states;
                    } else if g == 0 || (t.aux & MEM_VOLATILE) != 0 {
                        self.tstate = [states; TBAA_TAGS];
                    } else {
                        unsafe self.tstate[g] = states;
                        self.tstate[0] = states;
                    }
                }
                self.state = if private {
                    self.pstate
                } else if g < TBAA_TAGS {
                    unsafe self.tstate[g]
                } else {
                    self.tstate[0]
                };
                // An instruction `thread` replaced is gone; one `speculate` moved stays as it is.
                if self.moved[i as usize] {
                    continue;
                }
                if self.repl[i as usize] == VNONE {
                    // An instruction the visit puts before `i` (a copy's load) may read the pending stores.
                    let np = self.pre.len();
                    changed = self.visit(pk, b, k as u32, i) || changed;
                    if self.pre.len() != np {
                        self.pend.truncate(0);
                    }
                    // A load of a small by-value aggregate parameter moves to the entry's start, before any
                    // call (`agg_params`).
                    let u = b.insts[i as usize];
                    if self.aggp != 0 && u.op == O_LOAD && self.repl[i as usize] == VNONE && (k != 0 || called) && (u.a & VPARAM) != 0 && (u.a & ~VPARAM) - b.blocks[0].param_start < 64 && (self.aggp >> ((u.a & ~VPARAM) - b.blocks[0].param_start) as u64 & 1) != 0 {
                        self.moved[i as usize] = true;
                        self.blk_of[i as usize] = 0;
                        self.extra.push(i);
                        changed = true;
                    }
                    called = called || u.op == O_CALL || u.op == O_CALLIND;
                    // A store the visit dropped wrote nothing.
                    if t.op == O_STORE && self.repl[i as usize] == DROPPED {
                        self.tstate = before;
                        self.pstate = pbefore;
                        self.unstored = self.unstored || self.inner[k] != NONE;
                    } else if !private && writes(pk, b, t) && g < TBAA_TAGS {
                        self.carry(pk, b, i, before);
                    }
                    if self.repl[i as usize] == VNONE {
                        changed = self.overwrite(pk, b, i) || changed;
                    }
                } else {
                    changed = true;
                }
            }
            for g in 0..TBAA_TAGS {
                self.end_state[k * TBAA_TAGS + g] = unsafe self.tstate[g];
            }
            for r in 0..self.recent.len() {
                self.end_recent[k * RECENT_MAX + r] = self.recent[r];
            }
            self.end_pstate[k] = self.pstate;
            for c in self.kid_at[k]..self.kid_at[k + 1] {
                self.stack.push(self.kids[c as usize] as u64 << 1);
            }
        }
        return changed;
    }

    // Instruction `i`, which stays, in the walk's order within its block: a store drops each earlier one
    // of `pend` it writes all bytes of through the same address (no instruction between reads memory or
    // leaves the block), then joins `pend`; any other instruction but a pure one that cannot trap empties
    // `pend`. Whether it dropped any.
    fn overwrite(self: &mut Self, pk: &Package, b: &Body, i: u32) bool {
        let t = b.insts[i as usize];
        if pure_op(t.op) && !tls_addr(pk, b, t) && (t.op < O_SDIV || t.op > O_UREM) {
            return false;
        }
        if t.op != O_STORE || (t.aux & MEM_VOLATILE) != 0 {
            self.pend.truncate(0);
            return false;
        }
        let a = self.val(t.a);
        let lo = (t.c as i32) as i64;
        let hi = lo + type_bytes(b.type_of(t.b), pk.ptr_bytes) as i64;
        let mut dropped = false;
        let mut x: usize = 0;
        // Each step keeps or drops one entry.
        while x < self.pend.len() {
            let j = self.pend[x];
            let s = b.insts[j as usize];
            let slo = (s.c as i32) as i64;
            if self.repl[j as usize] == VNONE && self.val(s.a) == a && lo <= slo && slo + type_bytes(
                b.type_of(s.b),
                pk.ptr_bytes,
            ) as i64 <= hi {
                self.repl[j as usize] = DROPPED;
                dropped = true;
                let last = self.pend.len() - 1;
                self.pend[x] = self.pend[last];
                self.pend.truncate(last);
            } else {
                x += 1;
            }
        }
        if self.pend.len() as u32 >= PEND_MAX {
            self.pend.truncate(0);
        }
        self.pend.push(i);
        return dropped;
    }

    // The type tags (`bwrites`) the blocks on the paths from block `k`'s immediate dominator into `k` write,
    // `k` included when such a path passes it again; WRITES_ALL when more than BETWEEN_MAX blocks are on them.
    fn between_writes(self: &mut Self, k: u32) u32 {
        let d = self.idom[k as usize];
        let mut w: u32 = 0;
        let mut n: u32 = 0;
        self.rstack.truncate(0);
        for q in self.pred_at[k as usize]..self.pred_at[k as usize + 1] {
            self.rstack.push(self.preds[q as usize]);
        }
        // Each block enters the stack once (`rmark`), at most BETWEEN_MAX of them.
        while self.rstack.len() != 0 {
            let x = self.rstack.pop().unwrap();
            if x == d || self.rmark[x as usize] == k {
                continue;
            }
            self.rmark[x as usize] = k;
            n += 1;
            if n > BETWEEN_MAX {
                return WRITES_ALL;
            }
            w |= self.bwrites[x as usize];
            for q in self.pred_at[x as usize]..self.pred_at[x as usize + 1] {
                self.rstack.push(self.preds[q as usize]);
            }
        }
        return w;
    }

    fn unwind(self: &mut Self, to: usize) {
        // Each entry undoes one insertion.
        while self.log.len() > to {
            let (table, key, prev) = self.log.pop().unwrap();
            let m = if table == LOG_PURE {
                &mut self.pure
            } else if table == LOG_MEM {
                &mut self.mem
            } else if table == LOG_COND {
                &mut self.cond
            } else if table == LOG_REL {
                &mut self.rel
            } else if table == LOG_EQ {
                &mut self.eqs
            } else {
                &mut self.ub
            };
            if prev == NONE {
                let _ = m.remove(&key);
            } else {
                m.insert(key, prev);
            }
        }
    }

    fn enter(self: &mut Self, table: u8, key: u64, v: u32) {
        let m = if table == LOG_PURE {
            &mut self.pure
        } else if table == LOG_MEM {
            &mut self.mem
        } else if table == LOG_COND {
            &mut self.cond
        } else if table == LOG_REL {
            &mut self.rel
        } else if table == LOG_EQ {
            &mut self.eqs
        } else {
            &mut self.ub
        };
        let prev = switch m.get(&key) {
            Some(p) => *p,
            None => NONE,
        };
        m.insert(key, v);
        self.log.push((table, key, prev));
    }

    // ---- If-conversion and order facts ----

    // Branch `t`, instruction `i` ending block `k`, whose sides reach one block `j`, each through its edge
    // or an empty block it alone enters: the edge of a jump to `j` whose arguments that differ by side
    // are selects on the condition (at most MAX_SELECTS, integers up to 64 bits, pointers or scalar floats), which move
    // to the end of `k`; when the two sides alone enter `j`, its parameters take them in the rest of the
    // walk. NONE when not.
    fn diamond(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32, t: Inst) u32 {
        let (e0, s0) = self.arm(b, k, t.b);
        let (e1, s1) = self.arm(b, k, t.c);
        let j = b.edge_target(e0);
        // A rare side of a warm branch keeps its branch: the warm path then neither runs its code nor waits for
        // a select.
        let rare = (b.blocks[s0 as usize].flags | b.blocks[s1 as usize].flags) & ~b.blocks[k as usize].flags & BLOCK_RARE;
        if j != b.edge_target(e1) || j == k || rare != 0 || self.speculated(pk, b, k, s0) + self.speculated(
            pk,
            b,
            k,
            s1,
        ) > SPEC_MAX {
            return NONE;
        }
        // The join's parameters are the selects when the two sides alone enter it.
        let p0 = self.preds[self.pred_at[j as usize] as usize];
        let p1 = self.preds[self.pred_at[j as usize] as usize + 1];
        let only = self.pred_at[j as usize + 1] - self.pred_at[j as usize] == 2 && (p0 == s0 && p1 == s1 || p0 == s1 && p1 == s0);
        let jb = b.blocks[j as usize];
        let mut nsel: u32 = 0;
        for q in 0..jb.param_len as u32 {
            if self.val(b.edge_arg(e0, q)) != self.val(b.edge_arg(e1, q)) {
                let ty = b.params[(jb.param_start + q) as usize];
                if !(is_int(ty) && ty != T_I128 || ty == T_PTR || ty == T_F32 || ty == T_F64) {
                    return NONE;
                }
                nsel += 1;
            }
        }
        if nsel == 0 || nsel > MAX_SELECTS {
            return NONE;
        }
        self.selected = true;
        // The sides' instructions move to the end of `k`, in order, before the selects that read them.
        self.speculate(b, k, s0);
        self.speculate(b, k, s1);
        let mut args = Vector::<Value>::with_capacity(jb.param_len as usize);
        for q in 0..jb.param_len as u32 {
            let x = self.val(b.edge_arg(e0, q));
            let y = self.val(b.edge_arg(e1, q));
            let mut v = x;
            if x != y {
                v = b.insts.len() as u32;
                b.insts.push(
                    Inst { op: O_SELECT, ty: b.params[(jb.param_start + q) as usize], aux: 0, a: t.a, b: x, c: y },
                );
                b.locs.push(b.locs[i as usize]);
                if b.inl.len() != 0 {
                    b.inl.push(b.inl[i as usize]);
                }
                self.repl.push(VNONE);
                self.frepl.push(VNONE);
                self.moved.push(true);
                self.blk_of.push(k);
                self.hoisted.push(k as u64 << 32 | v as u64);
                // Its operands are final: simplified now, as no later walk may see it (the rewalk's own).
                let r = simplify(pk, b, v);
                if r != VNONE {
                    v = r;
                }
            }
            if only {
                self.prepl[(jb.param_start + q) as usize] = v;
            }
            args.push(v);
        }
        return b.edge(j, &args);
    }

    // Branch `t`, instruction `i` ending block `k`, whose sides each enter a block that `k` alone enters,
    // runs at most SPEC_MAX instructions together (`speculated`) and returns an integer of up to 64 bits, a
    // pointer or a scalar float: those instructions move to the end of `k` (`speculate`), which returns the select of the
    // two results on the condition (if-conversion of a return diamond, as LLVM's SimplifyCFG with
    // FoldTwoEntryPHINode after merging the returns). The value `k` returns; NONE when not.
    fn ret_diamond(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32, t: Inst) u32 {
        let s0 = b.edge_target(t.b);
        let s1 = b.edge_target(t.c);
        if s0 == s1 || s0 == k || s1 == k {
            return NONE;
        }
        let r0 = self.ret_arm(b, t.b);
        let r1 = self.ret_arm(b, t.c);
        if r0 == VNONE || r1 == VNONE {
            return NONE;
        }
        let ty = b.type_of(r0);
        let rare = (b.blocks[s0 as usize].flags | b.blocks[s1 as usize].flags) & ~b.blocks[k as usize].flags & BLOCK_RARE;
        if !(is_int(ty) && ty != T_I128 || ty == T_PTR || ty == T_F32 || ty == T_F64) || rare != 0 || self.speculated(
            pk,
            b,
            k,
            s0,
        ) + self.speculated(pk, b, k, s1) > SPEC_MAX {
            return NONE;
        }
        self.selected = true;
        self.speculate(b, k, s0);
        self.speculate(b, k, s1);
        let x = self.val(r0);
        let y = self.val(r1);
        if x == y {
            return x;
        }
        let v = b.insts.len() as u32;
        b.insts.push(Inst { op: O_SELECT, ty: ty, aux: 0, a: t.a, b: x, c: y });
        b.locs.push(b.locs[i as usize]);
        if b.inl.len() != 0 {
            b.inl.push(b.inl[i as usize]);
        }
        self.repl.push(VNONE);
        self.frepl.push(VNONE);
        self.moved.push(true);
        self.blk_of.push(k);
        self.hoisted.push(k as u64 << 32 | v as u64);
        let r = simplify(pk, b, v);
        return if r != VNONE {
            r
        } else {
            v
        };
    }

    // The value the block edge `e` enters returns as a side `ret_diamond` takes (one predecessor, at most
    // SPEC_MAX instructions before a return of a value or a jump to a block that only returns, parameters
    // only before a return alone: the edge's arguments); VNONE when it is not one.
    fn ret_arm(self: &Self, b: &Body, e: u32) Value {
        let a = b.edge_target(e);
        let ab = b.blocks[a as usize];
        let ta = term(b, a);
        if ab.len > SPEC_MAX + 1 || self.pred_at[a as usize + 1] - self.pred_at[a as usize] != 1 || ab.param_len != 0 && (ab.len != 1 || ta.op != O_RET) {
            return VNONE;
        }
        if ta.op == O_RET && ta.a != VNONE && (ta.a & VPARAM) != 0 && (ta.a & ~VPARAM) >= ab.param_start && (ta.a & ~VPARAM) < ab.param_start + ab.param_len as u32 {
            return b.edge_arg(e, (ta.a & ~VPARAM) - ab.param_start);
        }
        if ta.op == O_RET {
            return ta.a;
        }
        if ta.op != O_JMP {
            return VNONE;
        }
        // A jump to a block that only returns (`ret_through`, which the walk reaches after this branch):
        // not a value the walk placed in that block.
        let (ok, r) = ret_through(b, ta.a);
        let x = r & ~VFLAG;
        if !ok || r == VNONE || (r & VPARAM) == 0 && x as usize < self.blk_of.len() && self.blk_of[x as usize] == b.edge_target(
            ta.a,
        ) {
            return VNONE;
        }
        return r;
    }

    // Side `e` of a branch ending block `k`, as `diamond` takes it: the edge out of the block without
    // parameters it alone enters that holds at most SPEC_MAX instructions besides its jump, and that block;
    // else `e` and `k`.
    fn arm(self: &Self, b: &Body, k: u32, e: u32) (u32, u32) {
        let a = b.edge_target(e);
        let ab = b.blocks[a as usize];
        let ta = term(b, a);
        if a != k && ab.param_len == 0 && ab.len <= SPEC_MAX + 1 && ta.op == O_JMP && self.pred_at[a as usize + 1] - self.pred_at[a as usize] == 1 {
            return (ta.a, a);
        }
        return (e, k);
    }

    // How many instructions but constants side `a` of block `k`'s branch (`arm`) runs that `speculate`
    // would move into `k`: each must be pure and speculable, or a load that cannot fault (`safe_load`);
    // SPEC_MAX + 1 when one is not.
    fn speculated(self: &Self, pk: &Package, b: &Body, k: u32, a: u32) u32 {
        if a == k {
            return 0;
        }
        let ab = b.blocks[a as usize];
        let mut n: u32 = 0;
        for x in ab.start..ab.start + ab.len - 1 {
            let mut t = b.insts[x as usize];
            if t.op == O_ICONST || t.op == O_FCONST {
                continue;
            }
            if lv::operand_a(op_info(t.op).form) {
                t.a = self.val(t.a);
            }
            let ok = if t.op == O_LOAD {
                (t.aux & MEM_VOLATILE) == 0 && !is_vec(t.ty) && self.safe_load(pk, b, t)
            } else {
                pure_op(t.op) && speculable(pk, b, t)
            };
            if !ok {
                return SPEC_MAX + 1;
            }
            n += 1;
        }
        return n;
    }

    // Move the instructions of side `a` of block `k`'s branch (`speculated`) to the end of `k`.
    fn speculate(self: &mut Self, b: &mut Body, k: u32, a: u32) {
        if a == k {
            return;
        }
        let ab = b.blocks[a as usize];
        for x in ab.start..ab.start + ab.len - 1 {
            let mut t = b.insts[x as usize];
            let f = op_info(t.op).form;
            if lv::operand_a(f) {
                t.a = self.val(t.a);
            }
            if lv::operand_b(f) {
                t.b = self.val(t.b);
            }
            if lv::operand_c(f) {
                t.c = self.val(t.c);
            }
            b.insts[x as usize] = t;
            self.moved[x as usize] = true;
            self.blk_of[x as usize] = k;
            self.hoisted.push(k as u64 << 32 | x as u64);
        }
    }

    // Comparison `c` as `x <u y` (`rel_key(x, y)`) and whether `c` is its negation; `(VNONE, VNONE, _)`
    // when `c` is no unsigned order comparison of scalars.
    const fn as_ult(b: &Body, c: Value) (Value, Value, bool) {
        if (c & (VPARAM | VFLAG)) != 0 {
            return (VNONE, VNONE, false);
        }
        let t = b.insts[c as usize];
        if t.op != O_ICMP || is_vec(t.ty) {
            return (VNONE, VNONE, false);
        }
        if t.aux == C_ULT {
            return (t.a, t.b, false);
        }
        if t.aux == C_UGE {
            return (t.a, t.b, true);
        }
        if t.aux == C_UGT {
            return (t.b, t.a, false);
        }
        if t.aux == C_ULE {
            return (t.b, t.a, true);
        }
        return (VNONE, VNONE, false);
    }

    // Condition `c`, `holds` on the edge into the scope: `x <u y` decided, and with it `x <u m` for each
    // minimum `m` that `y` is made of (`min_parts`).
    fn order_facts(self: &mut Self, b: &Body, c: Value, holds: bool) {
        // An equality that holds here: its sides are one value below.
        if (c & (VPARAM | VFLAG)) == 0 && b.insts[c as usize].op == O_ICMP && !is_vec(b.insts[c as usize].ty) {
            let t = b.insts[c as usize];
            if t.aux == C_EQ && holds || t.aux == C_NE && !holds {
                self.enter(LOG_EQ, eq_key(t.a, t.b), 1);
            }
        }
        let (x, y, neg) = Opt::as_ult(b, c);
        if x == VNONE {
            return;
        }
        let lt = holds != neg;
        self.enter(LOG_REL, rel_key(x, y), lt as u32);
        if lt {
            self.min_parts(b, x, y, MIN_DEPTH);
        }
        // A constant side bounds the other: `x <u k`, or `y <=u k` when `k <u y` fails.
        if lt && const_of(b, y).is_some() && (x & VFLAG) == 0 {
            self.enter(LOG_UB, x, y << 1 | 1);
        } else if !lt && const_of(b, x).is_some() && (y & VFLAG) == 0 {
            self.enter(LOG_UB, y, x << 1);
        }
    }

    // The greatest unsigned value `v` takes here: a constant's, a bound the branches in scope set
    // (`order_facts`), or one an `and` with a constant, a right shift, a remainder or quotient by a
    // constant or a zero extension keeps, `depth` instructions deep; None when unknown.
    fn ubound(self: &Self, pk: &Package, b: &Body, v: Value, depth: u32) Option<u64> {
        if v == VNONE || (v & VFLAG) != 0 {
            return None;
        }
        let k = const_of(b, v);
        if k.is_some() {
            return Some(k.unwrap() & width_mask(b.type_of(v), pk.ptr_bytes));
        }
        let mut best = Option::<u64>::None;
        if let Some(f) = self.ub.get(&(v as u64)) {
            let c = const_of(b, *f >> 1).unwrap() & width_mask(b.type_of(*f >> 1), pk.ptr_bytes);
            best = if (*f & 1) == 0 {
                Some(c)
            } else if c == 0 {
                // No value is below 0: the block does not run.
                Some(0)
            } else {
                Some(c - 1)
            };
        }
        if (v & VPARAM) != 0 || depth == 0 {
            return best;
        }
        let t = b.insts[v as usize];
        let m = width_mask(t.ty, pk.ptr_bytes);
        let mut r = Option::<u64>::None;
        if t.op == O_AND {
            let x = self.ubound(pk, b, t.a, depth - 1);
            let y = self.ubound(pk, b, t.b, depth - 1);
            if x.is_some() && y.is_some() {
                r = Some(x.unwrap().min(y.unwrap()));
            } else if x.is_some() {
                r = x;
            } else {
                r = y;
            }
        } else if t.op == O_LSHR {
            let x = self.ubound(pk, b, t.a, depth - 1);
            let s = const_of(b, t.b);
            if s.is_some() && (s.unwrap() & m) < type_bits(t.ty, pk.ptr_bytes) as u64 {
                let hi = if x.is_some() {
                    x.unwrap()
                } else {
                    m
                };
                r = Some(hi >> (s.unwrap() & m));
            }
        } else if t.op == O_UREM || t.op == O_UDIV {
            let d = const_of(b, t.b);
            if d.is_some() && (d.unwrap() & m) != 0 {
                let dv = d.unwrap() & m;
                if t.op == O_UREM {
                    r = Some(dv - 1);
                } else {
                    let x = self.ubound(pk, b, t.a, depth - 1);
                    r = Some(
                        if x.is_some() {
                            x.unwrap()
                        } else {
                            m
                        } / dv,
                    );
                }
            }
        } else if t.op == O_ZEXT {
            let x = self.ubound(pk, b, t.a, depth - 1);
            r = if x.is_some() {
                x
            } else {
                Some(width_mask(b.type_of(t.a), pk.ptr_bytes))
            };
        } else if t.op == O_SEXT {
            // An operand whose sign bit its bound clears extends as with zeros.
            let x = self.ubound(pk, b, t.a, depth - 1);
            if x.is_some() && x.unwrap() >> (type_bits(b.type_of(t.a), pk.ptr_bytes) - 1) as u64 == 0 {
                r = x;
            }
        } else if t.op == O_TRUNC {
            // The operand's bound when the narrower type holds it, else any value of that type.
            let x = self.ubound(pk, b, t.a, depth - 1);
            r = if x.is_some() && x.unwrap() <= m {
                x
            } else {
                Some(m)
            };
        }
        if r.is_some() && best.is_some() {
            return Some(r.unwrap().min(best.unwrap()));
        }
        if r.is_some() {
            return r;
        }
        return best;
    }

    // Instruction `i`, which the bounds in scope (`ubound`) decide: a remainder or quotient by a constant
    // above its dividend's bound (the dividend, 0), a right shift that leaves nothing, an `and` with a
    // low mask that covers its operand's bound, an unsigned comparison with a constant past the bound.
    // Its replacement value (VNONE: none); a constant result rewrites `i` in place.
    fn range_fold(self: &mut Self, pk: &Package, b: &mut Body, i: u32) Value {
        let t = b.insts[i as usize];
        if is_vec(t.ty) || t.ty == T_I128 {
            return VNONE;
        }
        if t.op == O_UREM || t.op == O_UDIV || t.op == O_LSHR || t.op == O_AND {
            let k = const_of(b, t.b);
            if k.is_none() {
                return VNONE;
            }
            let m = width_mask(t.ty, pk.ptr_bytes);
            let c = k.unwrap() & m;
            let x = self.ubound(pk, b, t.a, UB_DEPTH);
            if x.is_none() {
                return VNONE;
            }
            let hi = x.unwrap();
            if (t.op == O_UREM || t.op == O_UDIV) && c != 0 && hi < c {
                if t.op == O_UREM {
                    return t.a;
                }
                b.insts[i as usize] = iconst(t.ty, 0);
                return VNONE;
            }
            if t.op == O_LSHR && c < type_bits(t.ty, pk.ptr_bytes) as u64 && hi >> c == 0 {
                b.insts[i as usize] = iconst(t.ty, 0);
                return VNONE;
            }
            if t.op == O_AND && (c & c + 1) == 0 && hi <= c {
                return t.a;
            }
            return VNONE;
        }
        if t.op == O_ICMP && (t.aux == C_ULT || t.aux == C_UGE) {
            let k = const_of(b, t.b);
            if k.is_none() || is_vec(b.type_of(t.a)) || b.type_of(t.a) == T_I128 {
                return VNONE;
            }
            let x = self.ubound(pk, b, t.a, UB_DEPTH);
            if x.is_some() && x.unwrap() < (k.unwrap() & width_mask(b.type_of(t.a), pk.ptr_bytes)) {
                b.insts[i as usize] = iconst(t.ty, (t.aux == C_ULT) as u64);
            }
        }
        return VNONE;
    }

    // `x <u y` holds: so does `x <u` each operand of minimum `y` (a select of the lesser of two values),
    // and of the minimums they are, `depth` deep.
    fn min_parts(self: &mut Self, b: &Body, x: Value, y: Value, depth: u32) {
        if depth == 0 || (y & (VPARAM | VFLAG)) != 0 {
            return;
        }
        let t = b.insts[y as usize];
        if t.op != O_SELECT {
            return;
        }
        let (u, w, neg) = Opt::as_ult(b, t.a);
        if !(u == t.b && w == t.c && !neg || u == t.c && w == t.b && neg) {
            return;
        }
        self.enter(LOG_REL, rel_key(x, t.b), 1);
        self.enter(LOG_REL, rel_key(x, t.c), 1);
        self.min_parts(b, x, t.b, depth - 1);
        self.min_parts(b, x, t.c, depth - 1);
    }

    // The value of condition `c` the order facts in scope decide (`order_facts`), if any.
    fn order_decided(self: &Self, b: &Body, c: Value) Option<u64> {
        let (x, y, neg) = Opt::as_ult(b, c);
        if x == VNONE {
            return None;
        }
        return switch self.rel.get(&rel_key(x, y)) {
            Some(r) => Some((*r != 0 != neg) as u64),
            None => Option::<u64>::None,
        };
    }

    // The parameters of block `k`, whose one predecessor (its dominator, which the walk visited) has
    // the one edge into it: replaced by that edge's arguments. Whether it has any that did.
    fn forward_params(self: &mut Self, b: &Body, k: u32) bool {
        let bk = b.blocks[k as usize];
        if bk.param_len == 0 {
            return false;
        }
        b.succ_edges(term(b, self.idom[k as usize]), &mut self.edges);
        for e in 0..self.edges.len() {
            if b.edge_target(self.edges[e]) == k {
                for q in 0..bk.param_len as u32 {
                    self.prepl[(bk.param_start + q) as usize] = b.edge_arg(self.edges[e], q);
                }
                return true;
            }
        }
        // The predecessor's branch folded to its other edge: the rebuild drops the block.
        return false;
    }

    // The parameters of block `k` that every edge into it passes one value for (or the parameter itself, on
    // a loop's edge) are that value. Whether any is.
    // The block that defines value `v` (NONE: none known).
    const fn def_blk(self: &Self, v: Value) u32 {
        if (v & VPARAM) != 0 {
            return self.pblock[(v & ~VPARAM) as usize];
        }
        let x = (v & ~VFLAG) as usize;
        return if x < self.blk_of.len() {
            self.blk_of[x]
        } else {
            NONE
        };
    }

    fn same_args(self: &mut Self, b: &Body, k: u32) bool {
        let bk = b.blocks[k as usize];
        let mut any = false;
        for q in 0..bk.param_len as u32 {
            let p = VPARAM | bk.param_start + q;
            let mut v = VNONE;
            let mut one = true;
            for x in self.pred_at[k as usize]..self.pred_at[k as usize + 1] {
                b.succ_edges(term(b, self.preds[x as usize]), &mut self.edges);
                for e in 0..self.edges.len() {
                    if b.edge_target(self.edges[e]) == k {
                        let a = self.val(b.edge_arg(self.edges[e], q));
                        if a != p && a != v {
                            one = one && v == VNONE;
                            v = a;
                        }
                    }
                }
            }
            // The value must dominate the block: the walk visits its definition first, so it is final. An
            // edge a folded branch left as the only one may come from a block that does not.
            let d = if one && v != VNONE {
                self.def_blk(v)
            } else {
                NONE
            };
            if d != NONE && self.dominates(d, k) {
                self.prepl[(bk.param_start + q) as usize] = v;
                any = true;
            }
        }
        return any;
    }

    // ---- Jump threading ----

    // Thread the edges of the graph (`follow`): through a block that holds only a jump and takes no
    // parameter, and through a block whose branch or switch the edge's constant arguments decide (a `&&`
    // or `||` joins there, an `Option` a call returned is tested there: `through`); a jump into a block
    // that only branches on one of its parameters becomes a branch on its argument. Neither kind of block
    // heads a loop, and no edge moves into a loop header: an edge into a block that heads no loop comes
    // from inside every loop around it, so the graph stays reducible and each loop keeps its preheader.
    // Whether any edge moved.
    fn thread(self: &mut Self, pk: &Package, b: &mut Body) bool {
        self.tables(pk, b, K_DOM);
        // Its rewrites move edges alone: the graph and the dominators stand when it moves none.
        self.kept = K_DOM;
        let nb = b.blocks.len();
        fill(&mut self.hdr, nb, false);
        for k in 0..nb {
            for x in self.pred_at[k]..self.pred_at[k + 1] {
                if self.rpo[k] != NONE && self.dominates(k as u32, self.preds[x as usize]) {
                    self.hdr[k] = true;
                }
            }
        }
        // Per parameter and per instruction: how many instructions read it (up to 2), the last one for a
        // parameter, and the block outside its own that reads it (`preader`, `ireader`: NONE for none,
        // MULTI for several). An edge's argument is read in its terminator's block; one of the value's own
        // block is read inside it (`through` checks the edge it threads along).
        fill(&mut self.pcount, b.params.len(), 0);
        fill(&mut self.puser, b.params.len(), NONE);
        fill(&mut self.preader, b.params.len(), NONE);
        fill(&mut self.icount, b.insts.len(), 0);
        fill(&mut self.ireader, b.insts.len(), NONE);
        fill(&mut self.in_or, b.insts.len(), false);
        for k in 0..nb {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let ti = b.insts[i as usize];
                let is_or = ti.op == O_OR;
                let u0 = self.ops_at[i as usize];
                for u in 0..self.ops_at[i as usize + 1] - u0 {
                    let v = self.ops[(u0 + u) as usize];
                    if v == VNONE {
                        continue;
                    }
                    if (v & VPARAM) != 0 {
                        let q = (v & ~VPARAM) as usize;
                        self.pcount[q] = (self.pcount[q] + 1).min(2);
                        self.puser[q] = i;
                        if self.pblock[q] != k as u32 {
                            self.preader[q] = reader(self.preader[q], k as u32);
                        }
                    } else {
                        let x = (v & ~VFLAG) as usize;
                        self.icount[x] = (self.icount[x] + 1).min(2);
                        self.in_or[x] = self.in_or[x] || is_or;
                        if self.blk_of[x] != k as u32 {
                            self.ireader[x] = reader(self.ireader[x], k as u32);
                        }
                    }
                }
            }
        }
        let mut any = false;
        for q in 0..b.params.len() {
            if self.pcount[q] == 1 && self.param_cmp(pk, b, q as u32) {
                any = true;
            }
        }
        // The branches every edge into their block decides alike, all on the graph before any edge
        // moves (`settled` reads every edge into a block), then their jumps.
        self.settle.truncate(0);
        for k in 0..nb {
            let t = term(b, k as u32);
            if self.rpo[k] != NONE && (t.op == O_BR || t.op == O_SWITCH) {
                let s = self.settled(pk, b, k as u32);
                if s != NONE {
                    self.settle.push(k as u32);
                    self.settle.push(s);
                }
            }
        }
        for x in 0..self.settle.len() / 2 {
            let k = self.settle[2 * x];
            let bk = b.blocks[k as usize];
            b.insts[(bk.start + bk.len - 1) as usize] = jump(self.settle[2 * x + 1]);
            any = true;
        }
        for k in 0..nb {
            if self.rpo[k] == NONE {
                continue;
            }
            let i = b.blocks[k].start + b.blocks[k].len - 1;
            let mut t = b.insts[i as usize];
            if t.op == O_JMP {
                t.a = self.follow(pk, b, k as u32, t.a, VNONE, 0);
                let j = b.edge_target(t.a);
                let q = self.threadable(b, k as u32, j);
                if q != NONE && !self.diamond_side(pk, b, k as u32, t.a, j) {
                    let jt = term(b, j);
                    let a = b.edge_arg(t.a, q);
                    t = Inst {
                        op: O_BR,
                        ty: T_NONE,
                        aux: 0,
                        a: a,
                        b: self.thread_edge(b, t.a, j, jt.b),
                        c: self.thread_edge(b, t.a, j, jt.c),
                    };
                }
            } else if t.op == O_BR {
                t.b = self.follow(pk, b, k as u32, t.b, t.a, 1);
                t.c = self.follow(pk, b, k as u32, t.c, t.a, 0);
                if same_edge(b, t.b, t.c) || b.edge_nargs(t.b) == 0 && b.edge_nargs(t.c) == 0 && twins(
                    b,
                    b.edge_target(t.b),
                    b.edge_target(t.c),
                ) {
                    t = jump(t.b);
                }
            } else if t.op == O_SWITCH {
                for q in 0..t.aux as u32 + 1 {
                    let at = (t.c + q) as usize;
                    let e = b.pool[at];
                    let ne = self.follow(pk, b, k as u32, e, VNONE, 0);
                    if ne != e {
                        b.pool[at] = ne;
                        any = true;
                    }
                }
            }
            if !same(t, b.insts[i as usize]) {
                b.insts[i as usize] = t;
                any = true;
            }
        }
        if any {
            self.kept = K_NONE;
        }
        return any;
    }

    // Parameter `p`, whose one use is a comparison with a constant in its own block (a three-way
    // comparison's result tested against 0), when every edge into the block passes a constant for it, or
    // a select of two constants the edge alone reads: each edge passes the comparison's result instead (a
    // select of the results), and the comparison's uses read the parameter. Whether it did.
    fn param_cmp(self: &mut Self, pk: &Package, b: &mut Body, p: u32) bool {
        let j = self.pblock[p as usize];
        let u = self.puser[p as usize];
        if j == 0 || j == NONE || self.rpo[j as usize] == NONE {
            return false;
        }
        let jb = b.blocks[j as usize];
        let t = b.insts[u as usize];
        let ty = b.params[p as usize];
        if u < jb.start || u >= jb.start + jb.len || t.op != O_ICMP || t.a != (VPARAM | p) || !is_int(ty) || ty == T_I128 {
            return false;
        }
        let k = const_of(b, t.b);
        if k.is_none() {
            return false;
        }
        let q = p - jb.param_start;
        // The first pass checks every edge, the second rewrites them. The predecessors come in block order,
        // a block once per edge.
        for pass in 0..2u32 {
            for x in self.pred_at[j as usize]..self.pred_at[j as usize + 1] {
                let src = self.preds[x as usize];
                if x > self.pred_at[j as usize] && self.preds[x as usize - 1] == src {
                    continue;
                }
                b.succ_edges(term(b, src), &mut self.edges);
                for e in 0..self.edges.len() {
                    let ed = self.edges[e];
                    if b.edge_target(ed) != j {
                        continue;
                    }
                    let a = b.edge_arg(ed, q);
                    let c = const_of(b, a);
                    let sel = c.is_none() && (a & (VPARAM | VFLAG)) == 0 && b.insts[a as usize].op == O_SELECT && self.icount[a as usize] == 1 && const_of(
                        b,
                        b.insts[a as usize].b,
                    ).is_some() && const_of(b, b.insts[a as usize].c).is_some();
                    if c.is_none() && !sel {
                        return false;
                    }
                    if pass == 1 && sel {
                        let st = b.insts[a as usize];
                        let r0 = le::icmp(t.aux, ty, pk.ptr_bytes, const_of(b, st.b).unwrap(), k.unwrap()) as u64;
                        let r1 = le::icmp(t.aux, ty, pk.ptr_bytes, const_of(b, st.c).unwrap(), k.unwrap()) as u64;
                        let x0 = self.tconst(b, t.ty, r0);
                        let x1 = self.tconst(b, t.ty, r1);
                        b.insts[a as usize] = Inst { op: O_SELECT, ty: t.ty, aux: 0, a: st.a, b: x0, c: x1 };
                    } else if pass == 1 {
                        let r = le::icmp(t.aux, ty, pk.ptr_bytes, c.unwrap(), k.unwrap()) as u64;
                        b.pool[(ed + 2 + q) as usize] = self.tconst(b, t.ty, r);
                    }
                }
            }
        }
        b.params[p as usize] = t.ty;
        self.trepl.push(u as u64 << 32 | (VPARAM | p) as u64);
        return true;
    }

    // An integer constant of type `ty` and bits `v` that `thread` makes: the walk's entry block starts with
    // it (`extra`).
    fn tconst(self: &mut Self, b: &mut Body, ty: u8, v: u64) Value {
        let t = iconst(ty, v);
        for x in 0..self.textra.len() {
            if same(b.insts[self.textra[x] as usize], t) {
                return self.textra[x];
            }
        }
        let i = b.insts.len() as u32;
        b.insts.push(t);
        b.locs.push(0);
        if b.inl.len() != 0 {
            b.inl.push(0);
        }
        self.textra.push(i);
        return i;
    }

    // Edge `e0` of block `k`'s terminator, threaded (`thread`): the edge it becomes. Along it, value `cond`
    // (VNONE: none) is `holds`: the condition of `k`'s branch.
    fn follow(self: &mut Self, pk: &Package, b: &mut Body, k: u32, e0: u32, cond: Value, holds: u64) u32 {
        let mut e = e0;
        // Each step passes a block of one instruction that heads no loop: at most the block count.
        for _ in 0..b.blocks.len() {
            let j = b.edge_target(e);
            let jb = b.blocks[j as usize];
            let jt = term(b, j);
            if j != k && j != 0 && jb.len == 1 && jb.param_len == 0 && jt.op == O_JMP && !self.hdr[j as usize] && !self.hdr[b.edge_target(
                jt.a,
            ) as usize] {
                e = jt.a;
                continue;
            }
            let s = self.through(pk, b, k, e, cond, holds);
            if s == NONE {
                return e;
            }
            e = self.thread_edge(b, e, j, s);
        }
        return e;
    }

    // The edge of block `j`'s terminator that edge `e` into `j` (of block `k`'s terminator, along which value
    // `cond` is `holds`) takes for sure: `j` heads no loop, nor does any block it enters, it holds at most
    // THREAD_BLOCK_MAX pure instructions, and `e`'s arguments decide its branch or switch (`decide`). The
    // edge leaves `j` behind, so a block that reads `j`'s parameters or instructions must be one only `j`
    // enters, through another of its edges (an `Option`'s payload read where it is `Some`). NONE when not.
    fn through(self: &Self, pk: &Package, b: &Body, k: u32, e: u32, cond: Value, holds: u64) u32 {
        let j = b.edge_target(e);
        let jb = b.blocks[j as usize];
        let jt = term(b, j);
        if j == k || j == 0 || self.hdr[j as usize] || jt.op != O_BR && jt.op != O_SWITCH || jb.len > THREAD_BLOCK_MAX {
            return NONE;
        }
        for i in jb.start..jb.start + jb.len - 1 {
            if !pure_op(b.insts[i as usize].op) {
                return NONE;
            }
        }
        // A branch whose one side enters `j` and whose other side is a small block of pure instructions that
        // jumps to `j` too is a diamond the walk makes selects of (`diamond`: `a || b` of comparisons, an
        // `or`): threading either side (from the branch, or from the small block) would leave none.
        if self.diamond_side(pk, b, k, e, j) {
            return NONE;
        }
        let c = self.decide(pk, b, k, j, e, jt.a, cond, holds, THREAD_DEPTH);
        if c.is_none() {
            return NONE;
        }
        let s = decided(b, jt, c.unwrap());
        if self.hdr[b.edge_target(s) as usize] {
            return NONE;
        }
        for i in jb.start..jb.start + jb.len - 1 {
            if !self.apart(b, j, s, self.ireader[i as usize]) {
                return NONE;
            }
        }
        // The new edge passes `s`'s arguments, `j`'s parameters replaced: none may be `j`'s instruction.
        for q in 0..b.edge_nargs(s) {
            let a = b.edge_arg(s, q);
            if (a & VPARAM) == 0 && a != VNONE && self.blk_of[(a & ~VFLAG) as usize] == j {
                return NONE;
            }
        }
        for q in jb.param_start..jb.param_start + jb.param_len as u32 {
            if !self.apart(b, j, s, self.preader[q as usize]) {
                return NONE;
            }
        }
        return s;
    }

    // Whether edge `e` of block `k` into `j` is a side of a diamond the walk makes selects of: `k` branches
    // into `j` and into a small block of pure, speculable instructions (`arm`) that jumps to `j`, or `k` is
    // that block.
    fn diamond_side(self: &Self, pk: &Package, b: &Body, k: u32, e: u32, j: u32) bool {
        let kt = term(b, k);
        let (p, other) = if kt.op == O_BR && (kt.b == e || kt.c == e) {
            (k, other_edge(kt, e))
        } else if kt.op == O_JMP && self.pred_at[k as usize + 1] - self.pred_at[k as usize] == 1 {
            let p = self.preds[self.pred_at[k as usize] as usize];
            let pt = term(b, p);
            if pt.op != O_BR || b.edge_target(pt.b) != k && b.edge_target(pt.c) != k {
                return false;
            }
            (
                p,
                if b.edge_target(pt.b) == k {
                    pt.b
                } else {
                    pt.c
                }
            )
        } else {
            return false;
        };
        let pt = term(b, p);
        let direct = other_edge(pt, other);
        let (oe, os) = self.arm(b, p, other);
        if os == p || b.edge_target(oe) != j || b.edge_target(direct) != j {
            return false;
        }
        let ob = b.blocks[os as usize];
        for i in ob.start..ob.start + ob.len - 1 {
            if !pure_op(b.insts[i as usize].op) || !speculable(pk, b, b.insts[i as usize]) {
                return false;
            }
        }
        return true;
    }

    // The edge of block `j`'s branch or switch that every edge into `j` decides alike (`decide`): `j` is
    // not the entry, heads no loop and has at most IMPLY_FAN edges into it; NONE when not.
    fn settled(self: &Self, pk: &Package, b: &Body, j: u32) u32 {
        let jt = term(b, j);
        let n = self.pred_at[j as usize + 1] - self.pred_at[j as usize];
        if j == 0 || self.hdr[j as usize] || n == 0 || n > IMPLY_FAN {
            return NONE;
        }
        let mut r = Option::<u64>::None;
        for x in self.pred_at[j as usize]..self.pred_at[j as usize + 1] {
            let src = self.preds[x as usize];
            if x > self.pred_at[j as usize] && self.preds[x as usize - 1] == src {
                continue;
            }
            let st = term(b, src);
            for q in 0..edge_count(st) {
                let ed = edge_at(b, st, q);
                if b.edge_target(ed) != j {
                    continue;
                }
                let c = self.decide(pk, b, src, j, ed, jt.a, VNONE, 0, THREAD_DEPTH);
                if c.is_none() || r.is_some() && r.unwrap() != c.unwrap() {
                    return NONE;
                }
                r = c;
            }
        }
        if r.is_none() {
            return NONE;
        }
        return decided(b, jt, r.unwrap());
    }

    // Whether reader `x` (`preader`, `ireader`) of a value of block `j` stays out of the paths an edge
    // threaded along `j`'s edge `s` takes: none, or a block only `j` enters, through another edge.
    fn apart(self: &Self, b: &Body, j: u32, s: u32, x: u32) bool {
        if x == NONE {
            return true;
        }
        if x == MULTI || x == b.edge_target(s) || self.pred_at[x as usize + 1] - self.pred_at[x as usize] != 1 || self.preds[self.pred_at[x as usize] as usize] != j {
            return false;
        }
        return true;
    }

    // Value `v` of block `j` as it reaches `j` along edge `e`: a parameter of `j` is the edge's argument, a
    // value of another block itself; VNONE for an instruction of `j`.
    fn along(self: &Self, b: &Body, j: u32, e: u32, v: Value) Value {
        if (v & VPARAM) != 0 {
            let jb = b.blocks[j as usize];
            let p = v & ~VPARAM;
            if p >= jb.param_start && p < jb.param_start + jb.param_len as u32 {
                return b.edge_arg(e, p - jb.param_start);
            }
            return v;
        }
        if (v & VFLAG) == 0 && self.blk_of[v as usize] == j {
            return VNONE;
        }
        return v;
    }

    // Whether value `a` equals constant `c` where edge `e` of block `k`'s terminator leaves, as the
    // branches before it settle: `k`'s branch on an equality of `a` with a constant, else what holds where
    // `k` starts (`entry_fact`); None when they do not.
    fn implied(self: &Self, pk: &Package, b: &Body, k: u32, e: u32, a: Value, c: u64, depth: u32) Option<bool> {
        let m = width_mask(b.type_of(a), pk.ptr_bytes);
        let ka = const_of(b, a);
        if ka.is_some() {
            return Some((ka.unwrap() & m) == (c & m));
        }
        let t = term(b, k);
        if t.op == O_BR && (e == t.b || e == t.c) && !same_edge(b, t.b, t.c) && (t.a & (VPARAM | VFLAG)) == 0 {
            let ci = b.insts[t.a as usize];
            if ci.op == O_ICMP && (ci.aux == C_EQ || ci.aux == C_NE) {
                let other = if ci.a == a {
                    ci.b
                } else if ci.b == a {
                    ci.a
                } else {
                    VNONE
                };
                let k2 = const_of(b, other);
                if k2.is_some() {
                    // Along the edge `a == k2` holds, or `a != k2`.
                    let same = (k2.unwrap() & m) == (c & m);
                    if ci.aux == C_EQ == (e == t.b) {
                        return Some(same);
                    }
                    if same {
                        return Some(false);
                    }
                }
            }
        }
        return self.entry_fact(pk, b, k, a, c, depth);
    }

    // Whether value `a` (no instruction of block `k`) equals constant `c` where `k` starts: for a parameter
    // of `k`, its argument on every edge into `k` (at most IMPLY_FAN of them, `implied`), else along the
    // one edge into `k`, `depth` blocks back; None when the branches do not settle it.
    fn entry_fact(self: &Self, pk: &Package, b: &Body, k: u32, a: Value, c: u64, depth: u32) Option<bool> {
        if depth == 0 || self.rpo[k as usize] == NONE {
            return None;
        }
        let np = self.pred_at[k as usize + 1] - self.pred_at[k as usize];
        let kb = b.blocks[k as usize];
        let p = a & ~VPARAM;
        if (a & VPARAM) != 0 && p >= kb.param_start && p < kb.param_start + kb.param_len as u32 {
            if np == 0 || np > IMPLY_FAN {
                return None;
            }
            let mut r = Option::<bool>::None;
            for x in self.pred_at[k as usize]..self.pred_at[k as usize + 1] {
                let src = self.preds[x as usize];
                if x > self.pred_at[k as usize] && self.preds[x as usize - 1] == src {
                    continue;
                }
                let st = term(b, src);
                for n in 0..edge_count(st) {
                    let ed = edge_at(b, st, n);
                    if b.edge_target(ed) != k {
                        continue;
                    }
                    let ri = self.implied(pk, b, src, ed, b.edge_arg(ed, p - kb.param_start), c, depth - 1);
                    if ri.is_none() || r.is_some() && r.unwrap() != ri.unwrap() {
                        return None;
                    }
                    r = ri;
                }
            }
            return r;
        }
        if np != 1 {
            return None;
        }
        let src = self.preds[self.pred_at[k as usize] as usize];
        let st = term(b, src);
        let mut only = NONE;
        for n in 0..edge_count(st) {
            let ed = edge_at(b, st, n);
            if b.edge_target(ed) == k {
                if only != NONE {
                    return None;
                }
                only = ed;
            }
        }
        if only == NONE {
            return None;
        }
        return self.implied(pk, b, src, only, a, c, depth - 1);
    }

    // The value `v` of block `j` (its parameter, an instruction of it, or a value of a block that dominates
    // it) takes along edge `e` (of block `k`'s terminator) into `j`, when the edge's constant arguments,
    // `cond` being `holds` and the branches before the edge (`implied`) decide it, through at most `depth`
    // instructions; None when not.
    fn decide(
        self: &Self,
        pk: &Package,
        b: &Body,
        k: u32,
        j: u32,
        e: u32,
        v: Value,
        cond: Value,
        holds: u64,
        depth: u32,
    ) Option<u64> {
        if v == cond && cond != VNONE {
            return Some(holds);
        }
        if (v & VPARAM) != 0 {
            let jb = b.blocks[j as usize];
            let p = v & ~VPARAM;
            if p < jb.param_start || p >= jb.param_start + jb.param_len as u32 {
                return None;
            }
            let a = b.edge_arg(e, p - jb.param_start);
            if a == cond && cond != VNONE {
                return Some(holds);
            }
            return const_of(b, a);
        }
        if (v & VFLAG) != 0 || self.blk_of[v as usize] != j || depth == 0 {
            return const_of(b, v);
        }
        // A comparison `param_cmp` moved into the edges is its parameter now.
        for x in 0..self.trepl.len() {
            if (self.trepl[x] >> 32) as u32 == v {
                return self.decide(pk, b, k, j, e, self.trepl[x] as u32, cond, holds, depth - 1);
            }
        }
        let t = b.insts[v as usize];
        let ptr = pk.ptr_bytes;
        if is_vec(t.ty) || t.ty == T_I128 {
            return None;
        }
        if t.op == O_ICONST {
            return const_of(b, v);
        }
        if t.op == O_SELECT {
            let c = self.decide(pk, b, k, j, e, t.a, cond, holds, depth - 1);
            if c.is_none() {
                return c;
            }
            return self.decide(
                pk,
                b,
                k,
                j,
                e,
                if c.unwrap() != 0 {
                    t.b
                } else {
                    t.c
                },
                cond,
                holds,
                depth - 1,
            );
        }
        if t.op != O_ICMP && t.op != O_ZEXT && t.op != O_SEXT && t.op != O_TRUNC && (t.op < O_ADD || t.op > O_XOR || t.op == O_MUL || t.op >= O_SDIV && t.op <= O_UREM) {
            return None;
        }
        let x = self.decide(pk, b, k, j, e, t.a, cond, holds, depth - 1);
        if x.is_none() {
            // An equality with a constant the branches before the edge settle.
            if t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) {
                let y = self.decide(pk, b, k, j, e, t.b, cond, holds, depth - 1);
                let a = self.along(b, j, e, t.a);
                if y.is_some() && a != VNONE {
                    let r = self.implied(pk, b, k, e, a, y.unwrap(), THREAD_DEPTH);
                    if r.is_some() {
                        return Some((r.unwrap() == (t.aux == C_EQ)) as u64);
                    }
                }
            }
            return x;
        }
        let mut r: u64 = 0;
        if t.op == O_ZEXT || t.op == O_SEXT || t.op == O_TRUNC {
            if !le::scalar_convert(t.op, t.aux, b.type_of(t.a), t.ty, ptr, x.unwrap(), &mut r) {
                return None;
            }
            return Some(r);
        }
        let y = self.decide(pk, b, k, j, e, t.b, cond, holds, depth - 1);
        if y.is_none() {
            if t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) {
                let a = self.along(b, j, e, t.b);
                if a != VNONE {
                    let r = self.implied(pk, b, k, e, a, x.unwrap(), THREAD_DEPTH);
                    if r.is_some() {
                        return Some((r.unwrap() == (t.aux == C_EQ)) as u64);
                    }
                }
            }
            return y;
        }
        if t.op == O_ICMP {
            return Some(le::icmp(t.aux, b.type_of(t.a), ptr, x.unwrap(), y.unwrap()) as u64);
        }
        if le::int_fold(t.op, t.ty, ptr, x.unwrap(), y.unwrap(), &mut r) != le::FOLD_OK {
            return None;
        }
        return Some(r);
    }

    // The index of the parameter of block `j` that its branch tests, when `j` holds that branch alone,
    // heads no loop and is not block `k`, and neither side heads a loop; NONE when not.
    fn threadable(self: &Self, b: &Body, k: u32, j: u32) u32 {
        let jb = b.blocks[j as usize];
        let t = term(b, j);
        if j == k || j == 0 || jb.len != 1 || t.op != O_BR || (t.a & VPARAM) == 0 || self.hdr[j as usize] || self.hdr[b.edge_target(
            t.b,
        ) as usize] || self.hdr[b.edge_target(t.c) as usize] {
            return NONE;
        }
        let p = t.a & ~VPARAM;
        if p < jb.param_start || p >= jb.param_start + jb.param_len as u32 {
            return NONE;
        }
        // The blocks `j` dominates may read its parameters; then `j` stays on every path into them.
        for q in jb.param_start..jb.param_start + jb.param_len as u32 {
            if self.preader[q as usize] != NONE {
                return NONE;
            }
        }
        return p - jb.param_start;
    }

    // A new edge for edge `e` into block `j` that continues along `j`'s side `s`: `s`'s target, its
    // arguments with `j`'s parameters replaced by `e`'s arguments.
    fn thread_edge(self: &mut Self, b: &mut Body, e: u32, j: u32, s: u32) u32 {
        let jb = b.blocks[j as usize];
        self.uses.truncate(0);
        for q in 0..b.edge_nargs(s) {
            let x = b.edge_arg(s, q);
            let p = x & ~VPARAM;
            self.uses.push(
                if (x & VPARAM) != 0 && p >= jb.param_start && p < jb.param_start + jb.param_len as u32 {
                    b.edge_arg(e, p - jb.param_start)
                } else {
                    x
                },
            );
        }
        return b.edge(b.edge_target(s), &self.uses);
    }

    // The value `v` stands for now.
    const fn val(self: &Self, v: Value) Value {
        if v == VNONE {
            return v;
        }
        if (v & VPARAM) != 0 {
            let r = self.prepl[(v & ~VPARAM) as usize];
            return if r == VNONE {
                v
            } else {
                r
            };
        }
        if (v & VFLAG) != 0 && self.frepl[(v & ~VFLAG) as usize] != VNONE {
            return self.frepl[(v & ~VFLAG) as usize];
        }
        let r = self.repl[(v & ~VFLAG) as usize];
        if r == VNONE {
            return v;
        }
        return r | v & VFLAG;
    }

    // An integer constant of type `ty` and bits `v` (truncated to it): one the dominating blocks hold, else
    // a new one at the start of the entry block.
    fn constant(self: &mut Self, b: &mut Body, ty: u8, v: u64) Value {
        let t = iconst(ty, v);
        let h = hash(t);
        let mut found = switch self.pure.get(&h) {
            Some(x) => *x,
            None => NONE,
        };
        if found == NONE || !same(b.insts[found as usize], t) {
            found = (switch self.made.get(&h) {
                Some(x) => *x,
                None => NONE,
            });
        }
        if found != NONE && same(b.insts[found as usize], t) {
            return found;
        }
        let i = b.insts.len() as u32;
        b.insts.push(t);
        b.locs.push(0);
        if b.inl.len() != 0 {
            b.inl.push(0);
        }
        self.repl.push(VNONE);
        self.frepl.push(VNONE);
        self.moved.push(false);
        self.blk_of.push(0);
        self.extra.push(i);
        self.made.insert(h, i);
        return i;
    }

    // Checked operation `i` of constants, or of an identity (`x + 0`, `x - 0`, `x * 1`, `x * 0`): its value
    // and flag replaced by the result and a constant flag. Whether it folded.
    fn fold_checked(self: &mut Self, pk: &Package, b: &mut Body, i: u32) bool {
        let t = b.insts[i as usize];
        if is_vec(t.ty) || t.ty == T_I128 {
            return false;
        }
        let ca = const_of(b, t.a);
        let cb = const_of(b, t.b);
        let signed = (t.aux & OV_SIGNED) != 0;
        let base = if t.op == O_ADDO {
            O_ADD
        } else if t.op == O_SUBO {
            O_SUB
        } else {
            O_MUL
        };
        let mut val = VNONE;
        let mut flag: u64 = 0;
        if ca.is_some() && cb.is_some() {
            let mut r: u64 = 0;
            let _ = le::int_fold(base, t.ty, pk.ptr_bytes, ca.unwrap(), cb.unwrap(), &mut r);
            val = self.constant(b, t.ty, r);
            flag = le::overflows(t.op, t.ty, pk.ptr_bytes, signed, ca.unwrap(), cb.unwrap()) as u64;
        } else if cb.is_some() && (cb.unwrap() == 0 && t.op != O_MULO || cb.unwrap() == 1 && t.op == O_MULO) {
            val = t.a;
        } else if cb.is_some() && cb.unwrap() == 0 && t.op == O_MULO || ca.is_some() && ca.unwrap() == 0 && t.op == O_MULO {
            val = self.constant(b, t.ty, 0);
        } else if ca.is_some() && t.op != O_SUBO && (ca.unwrap() == 0 && t.op == O_ADDO || ca.unwrap() == 1 && t.op == O_MULO) {
            val = t.b;
        } else {
            return false;
        }
        self.repl[i as usize] = val;
        self.frepl[i as usize] = self.constant(b, T_I8, flag);
        return true;
    }

    // Instruction `i` of block `k`: its operands, then folding, numbering, memory forwarding and
    // hoisting. Whether it changed.
    fn visit(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t0 = b.insts[i as usize];
        let mut t = t0;
        let f = op_info(t.op).form;
        if lv::operand_a(f) {
            t.a = self.val(t.a);
        }
        if lv::operand_b(f) {
            t.b = self.val(t.b);
        }
        if lv::operand_c(f) {
            t.c = self.val(t.c);
        }
        if f == F_CALL || f == F_CALLIND {
            for q in 0..t.aux as u32 {
                let at = (t.c + q) as usize;
                b.pool[at] = self.val(b.pool[at]);
            }
        } else if f == F_VOP || f == F_ASM {
            for q in 0..t.b {
                let at = (t.a + q) as usize;
                b.pool[at] = self.val(b.pool[at]);
            }
        }
        if is_terminator(t.op) {
            b.succ_edges(t, &mut self.edges);
            for e in 0..self.edges.len() {
                let x = self.edges[e];
                for q in 0..b.edge_nargs(x) {
                    let at = (x + 2 + q) as usize;
                    b.pool[at] = self.val(b.pool[at]);
                }
            }
            // A branch or a switch on a constant jumps, and so does a branch on a condition the edge into a
            // dominating block decides.
            let mut c = if t.op == O_BR || t.op == O_SWITCH {
                const_of(b, t.a)
            } else {
                Option::<u64>::None
            };
            if t.op == O_BR && c.is_none() {
                if let Some(x) = self.cond.get(&(t.a as u64)) {
                    c = Some(*x);
                } else {
                    c = self.order_decided(b, t.a);
                }
            }
            if t.op == O_BR && c.is_some() {
                t = jump(
                    if c.unwrap() != 0 {
                        t.b
                    } else {
                        t.c
                    },
                );
            } else if t.op == O_BR {
                let e = self.diamond(pk, b, k, i, t);
                if e != NONE {
                    t = jump(e);
                } else {
                    let r = self.ret_diamond(pk, b, k, i, t);
                    if r != NONE {
                        t = Inst { op: O_RET, ty: T_NONE, aux: 0, a: r, b: VNONE, c: VNONE };
                    }
                }
            } else if t.op == O_SWITCH && c.is_some() {
                let mut e = b.switch_edge(t, t.aux);
                for q in 0..t.aux as u32 {
                    if b.words[(t.b + q) as usize] == c.unwrap() {
                        e = b.switch_edge(t, q);
                        break;
                    }
                }
                t = jump(e);
            }
            // A jump to a block that only returns returns here: a call before it becomes a sibling call, and
            // the moves into the block's parameter go (LLVM's tail duplication of return blocks).
            if t.op == O_JMP {
                // The block comes later in the walk: its value may have a replacement already, or be one
                // the walk placed in that block (a hoisted instruction), which this block does not see.
                let (ok, r) = ret_through(b, t.a);
                let v = self.val(r);
                let x = v & ~VFLAG;
                if ok && (v == VNONE || (v & VPARAM) != 0 || x as usize >= self.blk_of.len() || self.blk_of[x as usize] != b.edge_target(
                    t.a,
                )) {
                    t = Inst { op: O_RET, ty: T_NONE, aux: 0, a: v, b: VNONE, c: VNONE };
                }
            }
            b.insts[i as usize] = t;
            return !same(t, t0);
        }
        // A reference parameter is never null.
        if t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) && (const_of(b, t.b) == Some(0u64) && ref_param(b, t.a) || const_of(
            b,
            t.a,
        ) == Some(0u64) && ref_param(b, t.b)) {
            t = iconst(t.ty, (t.aux == C_NE) as u64);
        }
        // An equality of a value from before the block with a constant that the branches into the block
        // settle (`entry_fact`): the `None` test of an `Option` a loop that stops on `Some` returns. So is
        // `x <u 1`, which is `x == 0`, and `x >=u 1` (a bounds check of index 0 after a length test).
        let below1 = t.op == O_ICMP && (t.aux == C_ULT || t.aux == C_UGE) && const_of(b, t.b) == Some(1u64);
        if below1 && (t.a & VFLAG) == 0 && !((t.a & VPARAM) == 0 && (t.a as usize >= self.blk_of.len() || self.blk_of[t.a as usize] == k)) && const_of(
            b,
            t.a,
        ).is_none() {
            let r = self.entry_fact(pk, b, k, t.a, 0, THREAD_DEPTH);
            if r.is_some() {
                t = iconst(t.ty, (r.unwrap() == (t.aux == C_ULT)) as u64);
            }
        } else if t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) {
            let kb = const_of(b, t.b);
            let a = if kb.is_some() {
                t.a
            } else {
                t.b
            };
            let kc = if kb.is_some() {
                kb
            } else {
                const_of(b, t.a)
            };
            let local = (a & VFLAG) != 0 || (a & VPARAM) == 0 && (a as usize >= self.blk_of.len() || self.blk_of[a as usize] == k);
            if kc.is_some() && const_of(b, a).is_none() && !local {
                let r = self.entry_fact(pk, b, k, a, kc.unwrap(), THREAD_DEPTH);
                if r.is_some() {
                    t = iconst(t.ty, (r.unwrap() == (t.aux == C_EQ)) as u64);
                }
            }
        }
        // A load or a store through a constant offset from another address takes that address and the sum
        // of the offsets: one place per base for `recall`, and an addressing mode for the code generator.
        if (t.op == O_LOAD || t.op == O_STORE) && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_PTRADD && b.insts[t.a as usize].b == VNONE {
            let off = (t.c as i32) as i64 + (b.insts[t.a as usize].c as i32) as i64;
            if off >= -0x80000000 && off <= 0x7FFFFFFF {
                t.a = b.insts[t.a as usize].a;
                t.c = off as u32;
            }
        }
        // Through an indexed address with an offset (a field of an element): that address without the
        // offset, made right before it once, and the offset joins the access's (`ldr x, [x, #off]` on
        // arm64 after one `add`; the accesses of other fields share the address). Not for an address moved
        // or made in this walk: its place in the instructions is not where it runs.
        if (t.op == O_LOAD || t.op == O_STORE) && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_PTRADD && b.insts[t.a as usize].b != VNONE && b.insts[t.a as usize].c != 0 && !self.moved[t.a as usize] && !slot_based(
            b,
            b.insts[t.a as usize].a,
        ) {
            let pa = b.insts[t.a as usize];
            let off = (t.c as i32) as i64 + (pa.c as i32) as i64;
            if off >= -0x80000000 && off <= 0x7FFFFFFF {
                let mut q = switch self.unbiased.get(&t.a) {
                    Some(x) => *x,
                    None => NONE,
                };
                if q == NONE {
                    q = self.before(
                        b,
                        self.blk_of[t.a as usize],
                        t.a,
                        Inst { op: O_PTRADD, ty: pa.ty, aux: pa.aux, a: pa.a, b: pa.b, c: 0 },
                    );
                    self.unbiased.insert(t.a, q);
                }
                t.a = q;
                t.c = off as u32;
            }
        }
        // An indexed address from an indexed address with an offset (an element of a row at an offset):
        // from that address without the offset, made as above, the offset joining this one's. The rows'
        // elements at one index are then one address and constant offsets (`lir::slp` packs their loads).
        if t.op == O_PTRADD && t.b != VNONE && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_PTRADD && b.insts[t.a as usize].b != VNONE && b.insts[t.a as usize].c != 0 && !self.moved[t.a as usize] && !slot_based(
            b,
            b.insts[t.a as usize].a,
        ) {
            let pa = b.insts[t.a as usize];
            let off = (t.c as i32) as i64 + (pa.c as i32) as i64;
            if off >= -0x80000000 && off <= 0x7FFFFFFF {
                let mut q = switch self.unbiased.get(&t.a) {
                    Some(x) => *x,
                    None => NONE,
                };
                if q == NONE {
                    q = self.before(
                        b,
                        self.blk_of[t.a as usize],
                        t.a,
                        Inst { op: O_PTRADD, ty: pa.ty, aux: pa.aux, a: pa.a, b: pa.b, c: 0 },
                    );
                    self.unbiased.insert(t.a, q);
                }
                t.a = q;
                t.c = off as u32;
            }
        }
        b.insts[i as usize] = t;
        // A copy or a fill of no byte does nothing.
        let size = if t.op == O_MEMCPY || t.op == O_MEMSET {
            const_of(b, t.c)
        } else {
            Option::<u64>::None
        };
        if size.is_some() && size.unwrap() == 0 {
            self.repl[i as usize] = DROPPED;
            return true;
        }
        // A copy of 1, 2, 4 or 8 bytes is a load and a store of an integer that size, untagged (the bytes
        // of any type): the load reads before the store writes, as a copy of overlapping bytes must.
        if t.op == O_MEMCPY && size.is_some() && (t.aux & MEM_VOLATILE) == 0 {
            let n = size.unwrap();
            let ty = if n == 1 {
                T_I8
            } else if n == 2 {
                T_I16
            } else if n == 4 {
                T_I32
            } else if n == 8 {
                T_I64
            } else {
                T_NONE
            };
            if ty != T_NONE {
                let v = self.before(b, k, i, Inst { op: O_LOAD, ty: ty, aux: 0, a: t.b, b: VNONE, c: 0 });
                t = Inst { op: O_STORE, ty: T_NONE, aux: 0, a: t.a, b: v, c: 0 };
                b.insts[i as usize] = t;
            }
        }
        if t.op == O_MEMCPY && (t.aux & MEM_VOLATILE) == 0 && size.is_some() {
            // A copy of the bytes a copy of as many wrote, with no write since (neither memory state
            // changed): a copy of that copy's source, which holds them still when that copy did not
            // overlap it (no move, or one between two private memories), as a move (the source may be
            // the destination's bytes). The source copy may then go.
            let m = self.recall(t.b, self.pprior, T_NONE, self.tprior);
            if m != VNONE {
                let c = b.insts[m as usize];
                let ca = self.base(b, c.a);
                let cb = self.base(b, c.b);
                let apart = (c.aux & MEM_OVERLAP) == 0 || ca != NONE && cb != NONE && ca != cb;
                if c.op == O_MEMCPY && c.a == t.b && const_of(b, c.c) == size && c.b != t.b && apart {
                    t.b = c.b;
                    t.aux |= MEM_OVERLAP;
                    b.insts[i as usize] = t;
                }
            }
            // Keyed by the destination and both states after the copy; not in `recent`, whose places
            // `carry` keeps across writes that do not touch them, as a source's write would.
            self.enter(LOG_MEM, place_hash(t.a, self.pstate, T_NONE, self.tstate[0]), self.places.len() as u32);
            self.places.push(Place { addr: t.a, off: self.pstate, ty: T_NONE, state: self.tstate[0], val: i });
        }
        if t.op == O_STORE && (t.aux & MEM_VOLATILE) == 0 {
            // A store of the value its place holds (a load of it, or a store to it) does nothing.
            if self.recall(t.a, t.c, b.type_of(t.b), self.prior) == t.b {
                self.repl[i as usize] = DROPPED;
                return true;
            }
            // A store of a constant right after one of the bytes next to it, both of 1, 2 or 4 bytes: one
            // store of both, twice as wide (little-endian), the other dropped, untagged (its bytes are two
            // values of the narrower type; the verifier takes a tag of the stored type only). The bytes
            // written are the same; an untagged write starts the states of every tag.
            if i > 0 && self.blk_of[i as usize - 1] == k && self.repl[i as usize - 1] == VNONE && !self.moved[i as usize - 1] && b.insts[i as usize - 1].op == O_STORE {
                let p = b.insts[i as usize - 1];
                let ty = b.type_of(t.b);
                let n = type_bytes(ty, pk.ptr_bytes);
                let kp = const_of(b, p.b);
                let kt = const_of(b, t.b);
                let fit = (n == 1 || n == 2 || n == 4) && ty != T_PTR && is_int(ty) && p.aux == t.aux && p.a == t.a && kp.is_some() && kt.is_some() && b.type_of(
                    p.b,
                ) == ty;
                let pc = (p.c as i32) as i64;
                let tc = (t.c as i32) as i64;
                if fit && (tc == pc + n as i64 || pc == tc + n as i64) {
                    let m = (1u64 << 8 * n as u64) - 1;
                    let (lo, hi, at) = if pc < tc {
                        (kp.unwrap(), kt.unwrap(), p.c)
                    } else {
                        (kt.unwrap(), kp.unwrap(), t.c)
                    };
                    let wty = if n == 1 {
                        T_I16
                    } else if n == 2 {
                        T_I32
                    } else {
                        T_I64
                    };
                    t.b = self.constant(b, wty, lo & m | (hi & m) << 8 * n as u64);
                    t.c = at;
                    t.aux = t.aux & ~MEM_TBAA;
                    b.insts[i as usize] = t;
                    self.repl[i as usize - 1] = DROPPED;
                }
            }
            if self.combine_stores(pk, b, k, i) {
                return true;
            }
            // A load of the place the store wrote, in the state the store starts, reads the stored value.
            self.remember(t.a, t.c, b.type_of(t.b), t.b, self.state);
        } else if t.op == O_LOAD && (t.aux & MEM_VOLATILE) == 0 {
            let p = self.private_load(pk, b, k, i, t);
            if p != PRIV_NONE && p != PRIV_KEPT {
                self.repl[i as usize] = p;
                return true;
            }
            let sv = if p == PRIV_NONE {
                self.private_splat(pk, b, k, i, t)
            } else {
                VNONE
            };
            if sv != VNONE {
                b.insts[i as usize] = Inst { op: O_SPLAT, ty: t.ty, aux: 0, a: sv, b: VNONE, c: VNONE };
                let _ = self.number(pk, b, k, i);
                return true;
            }
            // A load of bytes no write touches reads one value in every memory state.
            let st = if p == PRIV_KEPT {
                KEPT_STATE
            } else {
                self.state
            };
            let seen = self.recall(t.a, t.c, t.ty, st);
            if seen != VNONE {
                self.repl[i as usize] = seen;
                return true;
            }
            let part = self.recall_part(pk, b, k, i, t, st);
            if part != VNONE {
                self.repl[i as usize] = part;
                return true;
            }
            if fold_data(pk, b, i) || self.fold_ptr(pk, b, i) {
                let _ = self.number(pk, b, k, i);
                return true;
            }
            self.remember(t.a, t.c, t.ty, i, st);
            // A load that may fault leaves only the loop whose every entry runs it.
            let safe = self.safe_load(pk, b, t);
            if (safe || self.runs_first(b, k, i)) && self.hoist(pk, b, k, i, true, p == PRIV_KEPT, !safe) {
                return true;
            }
        } else if (t.op == O_ADDO || t.op == O_SUBO || t.op == O_MULO) && self.fold_checked(pk, b, i) {
            return true;
        } else if t.op == O_CALL && call_alloc(pk, b, t) == ALLOC_MEMCMP && self.memcmp_eq(pk, b, k, i) {
            return true;
        } else if t.op == O_CALL && t.ty != T_NONE && (pk.syms[b.syms[t.a as usize] as usize].fx & (FX_WRITE | FX_ARG)) == 0 {
            // A call of a function that writes no memory gives what an earlier one with the same
            // arguments gave, when it reads none either, or none was written since (the untagged
            // accesses' memory state, which every write starts anew).
            let reads = (pk.syms[b.syms[t.a as usize] as usize].fx & FX_READ) != 0;
            let h = mix(
                call_hash(b, t),
                if reads {
                    self.tstate[0] as u64 + 1
                } else {
                    0u64
                },
            );
            let found = switch self.pure.get(&h) {
                Some(v) => *v,
                None => NONE,
            };
            if found != NONE && same_call(b, b.insts[found as usize], t) {
                self.repl[i as usize] = found;
                return true;
            }
            self.enter(LOG_PURE, h, i);
            if self.hoist_call(b, k, i) {
                return true;
            }
        } else if pure_op(t.op) && !tls_addr(pk, b, t) {
            if pk.fmath != 0 && t.op >= O_FADD && t.op <= O_FDIV && !is_vec(t.ty) {
                let r = self.fast_math(pk, b, k, i);
                if r != VNONE {
                    self.repl[i as usize] = r;
                    return true;
                }
            }
            if t.op == O_FDIV && (t.ty == T_F32 || t.ty == T_F64) {
                self.exact_reciprocal(b, i);
            }
            // Two operands the branches in scope make equal: one of them twice (`x - y` is 0 where `x == y`).
            if (t.op == O_SUB || t.op == O_XOR || t.op == O_AND || t.op == O_OR || t.op == O_ICMP) && t.a != t.b && !is_vec(
                t.ty,
            ) && self.eqs.get(&eq_key(t.a, t.b)).is_some() {
                let mut u = b.insts[i as usize];
                u.b = u.a;
                b.insts[i as usize] = u;
            }
            // A truncation of an addition, subtraction, product or bitwise operation of two values extended
            // from its type, which it alone reads, is that operation on them: the result's low bits are
            // those of the operands'. (Another reader keeps the wide operation; the truncation is free.)
            if t.op == O_TRUNC && is_int(t.ty) && (t.a & (VPARAM | VFLAG)) == 0 && t.a != VNONE && (t.a as usize >= self.icount.len() || self.icount[t.a as usize] == 1) {
                let w = b.insts[t.a as usize];
                if w.op >= O_ADD && w.op <= O_XOR && !(w.op >= O_SDIV && w.op <= O_UREM) {
                    let x = ext_from(b, w.a, t.ty);
                    let y = ext_from(b, w.b, t.ty);
                    if x != VNONE && y != VNONE {
                        b.insts[i as usize] = Inst { op: w.op, ty: t.ty, aux: 0, a: x, b: y, c: VNONE };
                    }
                }
            }
            let r = simplify(pk, b, i);
            if r != VNONE {
                self.repl[i as usize] = r;
                return true;
            }
            if b.insts[i as usize].op == O_OR && (self.combine_loads(pk, b, k, i) || self.byte_perm(pk, b, i)) {
                return true;
            }
            let rr = self.range_fold(pk, b, i);
            if rr != VNONE {
                self.repl[i as usize] = rr;
                return true;
            }
            let lop = b.insts[i as usize].op;
            if lop >= O_CLZ && lop <= O_POPCNT && self.narrow_count(pk, b, k, i) || lop == O_TRUNC && self.narrow_const(
                pk,
                b,
                k,
                i,
            ) {
                return true;
            }
            if (lop == O_AND || lop == O_OR) && self.range_check(pk, b, k, i) || lop == O_OR && self.bit_set(
                pk,
                b,
                k,
                i,
            ) || lop == O_ICMP && self.srem_cmp(pk, b, k, i) {
                return true;
            }
            self.pow2(b, i);
            self.shift_pair(pk, b, i);
            self.add_pair(pk, b, i);
            if self.divide(pk, b, k, i) || self.rem_by_quotient(b, k, i) {
                return true;
            }
            return self.number(pk, b, k, i) || !same(b.insts[i as usize], t0);
        }
        return !same(t, t0);
    }

    // Instruction `i`, a sum or difference of a constant and a sum or difference of a constant: in place one
    // sum of the inner operand and the constants combined (`(x + 1) + 1` is `x + 2`; an unrolled loop's
    // counter steps).
    fn add_pair(self: &mut Self, pk: &Package, b: &mut Body, i: u32) {
        let t = b.insts[i as usize];
        if t.op != O_ADD && t.op != O_SUB || !is_int(t.ty) || t.ty == T_I128 || (t.a & (VPARAM | VFLAG)) != 0 {
            return;
        }
        let x = b.insts[t.a as usize];
        let k2 = const_of(b, t.b);
        if x.op != O_ADD && x.op != O_SUB || x.ty != t.ty || k2.is_none() {
            return;
        }
        let k1 = const_of(b, x.b);
        if k1.is_none() {
            return;
        }
        let s1 = if x.op == O_ADD {
            k1.unwrap()
        } else {
            0u64.wrapping_sub(k1.unwrap())
        };
        let s2 = if t.op == O_ADD {
            k2.unwrap()
        } else {
            0u64.wrapping_sub(k2.unwrap())
        };
        let kv = self.constant(b, t.ty, le::trunc_bits(s1.wrapping_add(s2), type_bits(t.ty, pk.ptr_bytes)));
        b.insts[i as usize] = Inst { op: O_ADD, ty: t.ty, aux: 0, a: x.a, b: kv, c: VNONE };
    }

    // Instruction `i`, a logical shift right of a shift left by the same constant (or left of right): in
    // place the mask of the bits both keep (`x << k >> k` is `x & (ones >> k)`).
    fn shift_pair(self: &mut Self, pk: &Package, b: &mut Body, i: u32) {
        let t = b.insts[i as usize];
        if t.op != O_LSHR && t.op != O_SHL || !is_int(t.ty) || t.ty == T_I128 || (t.a & (VPARAM | VFLAG)) != 0 {
            return;
        }
        let x = b.insts[t.a as usize];
        let k = const_of(b, t.b);
        let bits = type_bits(t.ty, pk.ptr_bytes) as u64;
        if x.op != if t.op == O_LSHR {
            O_SHL
        } else {
            O_LSHR
        } || k.is_none() || k.unwrap() == 0 || k.unwrap() >= bits || const_of(b, x.b) != k {
            return;
        }
        let ones = le::trunc_bits(0xFFFFFFFFFFFFFFFF, bits as u32);
        let m = if t.op == O_LSHR {
            ones >> k.unwrap()
        } else {
            ones << k.unwrap() & ones
        };
        let mv = self.constant(b, t.ty, m);
        b.insts[i as usize] = Inst { op: O_AND, ty: t.ty, aux: 0, a: x.a, b: mv, c: VNONE };
    }

    // Instruction `i`, an integer product, unsigned quotient or unsigned remainder by a power of two:
    // in place a shift left, a shift right or a mask.
    fn pow2(self: &mut Self, b: &mut Body, i: u32) {
        let t = b.insts[i as usize];
        if t.op != O_MUL && t.op != O_UDIV && t.op != O_UREM || !is_int(t.ty) || t.ty == T_I128 {
            return;
        }
        let c = const_of(b, t.b);
        if c.is_none() || c.unwrap() == 0 || (c.unwrap() & c.unwrap() - 1) != 0 {
            return;
        }
        let y = c.unwrap();
        if t.op == O_UREM {
            let m = self.constant(b, t.ty, y - 1);
            b.insts[i as usize] = Inst { op: O_AND, ty: t.ty, aux: 0, a: t.a, b: m, c: VNONE };
            return;
        }
        let s = self.constant(b, t.ty, y.trailing_zeros() as u64);
        let op = if t.op == O_MUL {
            O_SHL
        } else {
            O_LSHR
        };
        b.insts[i as usize] = Inst { op: op, ty: t.ty, aux: 0, a: t.a, b: s, c: VNONE };
    }

    // Store `i` of block `k`, the last of byte stores of the bytes of one value `x` of 2, 4 or 8 bytes
    // (`x as u8`, `(x >> 8) as u8`, ...) at consecutive offsets from one address, with no other memory access
    // between them (up to 3 instructions a byte back): one store of `x` (little-endian) or of its bytes
    // reversed (`Package.bswap`) at the lowest offset, the others dropped, untagged (LLVM's store merging).
    // Every native target is little-endian. Whether it did.
    fn combine_stores(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        let (x, j0) = stored_byte(b, t.b);
        if x == VNONE {
            return false;
        }
        let xt = b.type_of(x);
        let w = type_bytes(xt, pk.ptr_bytes);
        // The run ends with its first or last byte (written in order).
        if !is_int(xt) || xt == T_PTR || w != 2 && w != 4 && w != 8 || j0 != 0 && j0 != w - 1 {
            return false;
        }
        // Per byte of `x`, the offset its store writes (`i64::MIN`: none yet); the other stores of the run.
        let mut at = [i64::MIN; 8];
        let mut run = StaticVector::<u32, 8>::new();
        at[j0 as usize] = t.c as i32;
        let bk = b.blocks[k as usize];
        let mut j = i;
        let mut found: u32 = 1;
        // Each step goes back one instruction of the block: a byte's store and its shift and truncation.
        for _ in 0..3 * w {
            if found == w || j == bk.start {
                break;
            }
            j -= 1;
            if self.blk_of[j as usize] != k || self.repl[j as usize] == DROPPED {
                continue;
            }
            let u = b.insts[j as usize];
            if u.op == O_STORE {
                let (y, jb) = stored_byte(b, u.b);
                if y != x || u.a != t.a || u.aux != t.aux || at[jb as usize] != i64::MIN {
                    return false;
                }
                at[jb as usize] = u.c as i32;
                run.push(j);
                found += 1;
                continue;
            }
            if u.op == O_LOAD || writes_memory(u) || is_terminator(u.op) {
                return false;
            }
        }
        if found != w {
            return false;
        }
        // Byte `q` at `lo + q` (little-endian) or at `lo + w - 1 - q` (big-endian).
        let mut le = true;
        let mut be = pk.bswap;
        let lo = at[0].min(at[w as usize - 1]);
        for q in 0..w {
            le = le && at[q as usize] == lo + q as i64;
            be = be && at[q as usize] == lo + (w - 1 - q) as i64;
        }
        if !le && !be {
            return false;
        }
        let v = if le {
            x
        } else {
            self.before(b, k, i, Inst { op: O_BSWAP, ty: xt, aux: 0, a: x, b: VNONE, c: VNONE })
        };
        for q in 0..run.len() {
            self.repl[run[q] as usize] = DROPPED;
        }
        b.insts[i as usize] = Inst {
            op: O_STORE,
            ty: T_NONE,
            aux: t.aux & ~MEM_TBAA,
            a: t.a,
            b: v,
            c: (lo as i32) as u32,
        };
        return true;
    }

    // `or` `i` of block `k` that assembles a little-endian word from its bytes (`b0 | b1 << 8 | ...`, each
    // the zero extension of a byte load, of consecutive bytes from one address): one load of the word,
    // unaligned, when the byte loads are in the block and nothing between the first and `i` writes; a
    // big-endian word (`b0 << 24 | ... | b3`) the load's bytes reversed (`Package.bswap`). Every native
    // target is little-endian. Whether it did.
    fn combine_loads(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        let n = type_bytes(t.ty, pk.ptr_bytes);
        if t.op != O_OR || !is_int(t.ty) || n != 2 && n != 4 && n != 8 {
            return false;
        }
        let mut stack = [VNONE; 16];
        stack[0] = t.a;
        stack[1] = t.b;
        let mut sp: usize = 2;
        let mut seen: u32 = 0;
        let mut base = VNONE;
        let mut boff: i64 = 0;
        let mut roff: i64 = 0;
        let mut fwd = true;
        let mut rev = pk.bswap;
        let mut first = i;
        // Each step takes one node of the tree: at most 2n of them before the bytes run out.
        for _ in 0..4 * n {
            if sp == 0 {
                break;
            }
            sp -= 1;
            let v = self.val(unsafe stack[sp]);
            if (v & (VPARAM | VFLAG)) != 0 {
                return false;
            }
            let x = b.insts[v as usize];
            if x.op == O_OR && x.ty == t.ty {
                if sp + 2 > 16 {
                    return false;
                }
                unsafe stack[sp] = x.a;
                unsafe stack[sp + 1] = x.b;
                sp += 2;
                continue;
            }
            let mut sh: u64 = 0;
            let mut zv = v;
            if x.op == O_SHL && x.ty == t.ty {
                let c = const_of(b, x.b);
                if c.is_none() {
                    return false;
                }
                sh = c.unwrap();
                zv = self.val(x.a);
            }
            if (zv & (VPARAM | VFLAG)) != 0 || b.insts[zv as usize].op != O_ZEXT || b.insts[zv as usize].ty != t.ty {
                return false;
            }
            let lv = self.val(b.insts[zv as usize].a);
            if (lv & (VPARAM | VFLAG)) != 0 {
                return false;
            }
            let l = b.insts[lv as usize];
            let j = sh / 8;
            if l.op != O_LOAD || l.ty != T_I8 || (l.aux & MEM_VOLATILE) != 0 || sh % 8 != 0 || j >= n as u64 || (seen >> j as u32 & 1) != 0 || self.blk_of[lv as usize] != k || self.moved[lv as usize] {
                return false;
            }
            seen |= 1u32 << j as u32;
            let o = (l.c as i32) as i64 - j as i64;
            let ro = (l.c as i32) as i64 + j as i64 - (n - 1) as i64;
            if base == VNONE {
                base = l.a;
                boff = o;
                roff = ro;
            } else if l.a != base {
                return false;
            }
            fwd = fwd && o == boff;
            rev = rev && ro == roff;
            if !fwd && !rev {
                return false;
            }
            if lv < first {
                first = lv;
            }
        }
        let off = if fwd {
            boff
        } else {
            roff
        };
        if sp != 0 || seen != (1u32 << n) - 1 || off < -0x80000000 || off > 0x7FFFFFFF || n == 1 {
            return false;
        }
        for q in first..i {
            if writes_memory(b.insts[q as usize]) {
                return false;
            }
        }
        let ld = Inst { op: O_LOAD, ty: t.ty, aux: 0, a: base, b: VNONE, c: off as u32 };
        if fwd {
            b.insts[i as usize] = ld;
            return true;
        }
        let w = self.before(b, k, i, ld);
        b.insts[i as usize] = Inst { op: O_BSWAP, ty: t.ty, aux: 0, a: w, b: VNONE, c: VNONE };
        return true;
    }

    // `or` `i` of block `k` that no `or` reads, a tree of `or`s each read once whose leaves are at least 3
    // and at most SET_MAX equalities of one integer `x` with constants within 64 of each other, `lo` the
    // least: `x - lo <=u span` and bit `x - lo` of the constants' mask (LLVM's bit tests for switches); from
    // 0 when every constant is below 64. Whether it did.
    fn bit_set(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if is_vec(t.ty) || i as usize < self.in_or.len() && self.in_or[i as usize] {
            return false;
        }
        let mut x = VNONE;
        let mut vals = StaticVector::<u64, SET_MAX>::new();
        let mut stack = StaticVector::<Value, SET_MAX>::new();
        stack.push(t.a);
        stack.push(t.b);
        // Each step takes a value off the stack; an `or` puts back two: at most 2 * SET_MAX steps.
        for _ in 0..2 * SET_MAX {
            if stack.len() == 0 {
                break;
            }
            let v = stack.pop().unwrap();
            if (v & (VPARAM | VFLAG)) != 0 || v as usize < self.icount.len() && self.icount[v as usize] != 1 {
                return false;
            }
            let u = b.insts[v as usize];
            if u.op == O_OR && u.ty == t.ty {
                if stack.len() + 2 > SET_MAX {
                    return false;
                }
                stack.push(u.a);
                stack.push(u.b);
                continue;
            }
            if u.op != O_ICMP || u.aux != C_EQ || u.ty != t.ty || x != VNONE && u.a != x || vals.len() == SET_MAX {
                return false;
            }
            let c = const_of(b, u.b);
            if c.is_none() {
                return false;
            }
            x = u.a;
            vals.push(c.unwrap());
        }
        let ty = b.type_of(x);
        if stack.len() != 0 || vals.len() < 3 || !is_int(ty) || ty == T_I128 {
            return false;
        }
        let m = width_mask(ty, pk.ptr_bytes);
        let mut lo = u64::MAX;
        let mut hi: u64 = 0;
        for q in 0..vals.len() {
            lo = lo.min(vals[q] & m);
            hi = hi.max(vals[q] & m);
        }
        if hi - lo >= 64 {
            return false;
        }
        if hi < 64 {
            lo = 0;
        }
        let mut mask: u64 = 0;
        for q in 0..vals.len() {
            mask |= 1u64 << (vals[q] & m) - lo;
        }
        let mut d = x;
        if lo != 0 {
            let lv = self.constant(b, ty, lo);
            d = self.before(b, k, i, Inst { op: O_SUB, ty: ty, aux: 0, a: x, b: lv, c: VNONE });
        }
        let sv = self.constant(b, ty, hi - lo);
        let inr = self.before(b, k, i, Inst { op: O_ICMP, ty: t.ty, aux: C_ULE, a: d, b: sv, c: VNONE });
        let mut d64 = d;
        if type_bits(ty, pk.ptr_bytes) < 64 {
            d64 = self.before(b, k, i, Inst { op: O_ZEXT, ty: T_I64, aux: 0, a: d, b: VNONE, c: VNONE });
        }
        // The amount within the width: the range test discards the bit past it.
        let k63 = self.constant(b, T_I64, 63);
        let amt = self.before(b, k, i, Inst { op: O_AND, ty: T_I64, aux: 0, a: d64, b: k63, c: VNONE });
        let mv = self.constant(b, T_I64, mask);
        let sh = self.before(b, k, i, Inst { op: O_LSHR, ty: T_I64, aux: 0, a: mv, b: amt, c: VNONE });
        let low = self.before(b, k, i, Inst { op: O_TRUNC, ty: t.ty, aux: 0, a: sh, b: VNONE, c: VNONE });
        // The range test is 0 or 1: it keeps bit 0 of the shifted mask alone.
        b.insts[i as usize] = Inst { op: O_AND, ty: t.ty, aux: 0, a: inr, b: low, c: VNONE };
        return true;
    }

    // `and` `i` of block `k` of two comparisons of one integer `x` with constants, each of which holds on
    // one interval of `x` (signed or unsigned, the same for both): `x` in their intersection [`lo`, `hi`],
    // one unsigned comparison `x - lo <=u hi - lo`; an `or` of two such, `x` out of the intersection of
    // their opposites, `x - lo >u hi - lo` (LLVM InstCombine's range checks). Whether it did.
    fn range_check(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if t.op != O_AND && t.op != O_OR || t.a == t.b {
            return false;
        }
        let neg = t.op == O_OR;
        let (x, sg, lo1, hi1) = bound_by(pk, b, t.a, neg);
        let (y, sg2, lo2, hi2) = bound_by(pk, b, t.b, neg);
        if x == VNONE || x != y || sg != sg2 {
            return false;
        }
        let ty = b.type_of(x);
        let w = type_bits(ty, pk.ptr_bytes);
        // In the comparison's order: signed values biased to unsigned ones.
        let bias = if sg {
            1u64 << (w - 1) as u64
        } else {
            0u64
        };
        let m = width_mask(ty, pk.ptr_bytes);
        let lo = (lo1 ^ bias).max(lo2 ^ bias) ^ bias;
        let hi = (hi1 ^ bias).min(hi2 ^ bias) ^ bias;
        if (lo ^ bias) > (hi ^ bias) {
            b.insts[i as usize] = iconst(t.ty, neg as u64);
            return true;
        }
        let lv = self.constant(b, ty, lo);
        let d = self.before(b, k, i, Inst { op: O_SUB, ty: ty, aux: 0, a: x, b: lv, c: VNONE });
        let span = self.constant(b, ty, hi.wrapping_sub(lo) & m);
        b.insts[i as usize] = Inst {
            op: O_ICMP,
            ty: t.ty,
            aux: if neg {
                C_UGT
            } else {
                C_ULE
            },
            a: d,
            b: span,
            c: VNONE,
        };
        return true;
    }

    // Truncation `i` (block `k`) of an addition, subtraction, product or bitwise operation of a value
    // extended from its type or a narrower one and a constant: that operation at its type on the value
    // (extended the same way to it) and the constant's low bits (the result's low bits are the
    // operands'), simplified. Whether it did.
    fn narrow_const(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if !is_int(t.ty) || (t.a & (VPARAM | VFLAG)) != 0 || t.a == VNONE {
            return false;
        }
        let w = b.insts[t.a as usize];
        if w.op < O_ADD || w.op > O_XOR || w.op >= O_SDIV && w.op <= O_UREM || !is_int(w.ty) || w.ty == T_I128 {
            return false;
        }
        let (e, c) = if const_of(b, w.b).is_some() {
            (w.a, const_of(b, w.b))
        } else {
            (w.b, const_of(b, w.a))
        };
        if c.is_none() || (e & (VPARAM | VFLAG)) != 0 || e == VNONE {
            return false;
        }
        let x = b.insts[e as usize];
        let xt = if x.op == O_ZEXT || x.op == O_SEXT {
            b.type_of(x.a)
        } else {
            T_NONE
        };
        if !is_int(xt) || type_bits(xt, pk.ptr_bytes) > type_bits(t.ty, pk.ptr_bytes) {
            return false;
        }
        let v = if xt == t.ty {
            x.a
        } else {
            self.before(b, k, i, Inst { op: x.op, ty: t.ty, aux: 0, a: x.a, b: VNONE, c: VNONE })
        };
        let kv = self.constant(b, t.ty, c.unwrap() & width_mask(t.ty, pk.ptr_bytes));
        let sub_first = w.op == O_SUB && const_of(b, w.b).is_none();
        b.insts[i as usize] = if sub_first {
            Inst { op: w.op, ty: t.ty, aux: 0, a: kv, b: v, c: VNONE }
        } else {
            Inst { op: w.op, ty: t.ty, aux: 0, a: v, b: kv, c: VNONE }
        };
        let r = simplify(pk, b, i);
        if r != VNONE {
            self.repl[i as usize] = r;
        }
        return true;
    }

    // Bit count `i` (block `k`) of a zero-extended integer: the count of the narrow one (`clz` plus the
    // extension's bits); `ctz` of one with the bit above it set (`x as u64 | 1 << 32`, a zero counting
    // the narrow width) the same. Whether it did.
    fn narrow_count(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if !is_int(t.ty) || t.ty == T_I128 || (t.a & (VPARAM | VFLAG)) != 0 || t.a == VNONE {
            return false;
        }
        let mut x = b.insts[t.a as usize];
        let wide = type_bits(t.ty, pk.ptr_bytes);
        if t.op == O_CTZ && x.op == O_OR {
            // The bit right above the narrow value, the other operand a zero extension.
            let (e, c) = if const_of(b, x.b).is_some() {
                (x.a, const_of(b, x.b))
            } else {
                (x.b, const_of(b, x.a))
            };
            if c.is_none() || (e & (VPARAM | VFLAG)) != 0 || e == VNONE || b.insts[e as usize].op != O_ZEXT {
                return false;
            }
            let nt = b.type_of(b.insts[e as usize].a);
            if c.unwrap() != 1u64 << type_bits(nt, pk.ptr_bytes) as u64 {
                return false;
            }
            x = b.insts[e as usize];
        } else if x.op != O_ZEXT {
            return false;
        }
        let nt = b.type_of(x.a);
        let narrow = type_bits(nt, pk.ptr_bytes);
        if !is_int(nt) || narrow < 8 || narrow >= wide || nt == T_I128 {
            return false;
        }
        let n = self.before(b, k, i, Inst { op: t.op, ty: nt, aux: 0, a: x.a, b: VNONE, c: VNONE });
        let z = self.before(b, k, i, Inst { op: O_ZEXT, ty: t.ty, aux: 0, a: n, b: VNONE, c: VNONE });
        if t.op != O_CLZ {
            self.repl[i as usize] = z;
            return true;
        }
        let d = self.constant(b, t.ty, wide - narrow);
        self.repl[i as usize] = self.before(b, k, i, Inst { op: O_ADD, ty: t.ty, aux: 0, a: z, b: d, c: VNONE });
        return true;
    }

    // Equality `i` (block `k`) of a signed remainder by 2^s, in the form `divide_signed` gives it
    // (`n - ((n + bias) & -2^s)`), with a constant `c`: `n`'s low `s` bits and its sign against `c`'s, or
    // its low bits against 0 for `c` 0; a constant when no remainder is `c` (LLVM InstCombine's
    // `X srem 2^s == C`). Whether it did.
    fn srem_cmp(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if t.aux != C_EQ && t.aux != C_NE || (t.a & (VPARAM | VFLAG)) != 0 || t.a == VNONE {
            return false;
        }
        let c = const_of(b, t.b);
        let r = b.insts[t.a as usize];
        let ty = r.ty;
        if c.is_none() || r.op != O_SUB || !is_int(ty) || ty == T_I128 || (r.b & (VPARAM | VFLAG)) != 0 || r.b == VNONE {
            return false;
        }
        let n = r.a;
        let w = type_bits(ty, pk.ptr_bytes) as u64;
        let wm = width_mask(ty, pk.ptr_bytes);
        let low = b.insts[r.b as usize];
        if low.op != O_AND || (low.a & (VPARAM | VFLAG)) != 0 || low.a == VNONE {
            return false;
        }
        let m = const_of(b, low.b);
        if m.is_none() {
            return false;
        }
        let p = 0u64.wrapping_sub(m.unwrap()) & wm;
        let up = b.insts[low.a as usize];
        if p < 2 || (p & p - 1) != 0 || up.op != O_ADD || up.a != n || (up.b & (VPARAM | VFLAG)) != 0 || up.b == VNONE {
            return false;
        }
        let s = p.trailing_zeros() as u64;
        let bias = b.insts[up.b as usize];
        if bias.op != O_LSHR {
            return false;
        }
        let sgn_ok = if s == 1 {
            bias.a == n
        } else {
            (bias.a & (VPARAM | VFLAG)) == 0 && bias.a != VNONE && b.insts[bias.a as usize].op == O_ASHR && b.insts[bias.a as usize].a == n && const_of(
                b,
                b.insts[bias.a as usize].b,
            ) == Some(s - 1)
        };
        if const_of(b, bias.b) != Some(w - s) || !sgn_ok {
            return false;
        }
        let cv = c.unwrap() & wm;
        let sign = 1u64 << w - 1;
        let mask = p - 1;
        let neg = (cv & sign) != 0;
        // The remainders lie in (-2^s, 2^s): a `c` outside never equals one.
        let mag = if neg {
            0u64.wrapping_sub(cv) & wm
        } else {
            cv
        };
        if mag >= p {
            b.insts[i as usize] = iconst(t.ty, (t.aux == C_NE) as u64);
            return true;
        }
        let (mv, want) = if cv == 0 {
            (mask, 0u64)
        } else if neg {
            (sign | mask, sign | cv & mask)
        } else {
            (sign | mask, cv)
        };
        let mk = self.constant(b, ty, mv);
        let a = self.before(b, k, i, Inst { op: O_AND, ty: ty, aux: 0, a: n, b: mk, c: VNONE });
        let wv = self.constant(b, ty, want);
        b.insts[i as usize] = Inst { op: O_ICMP, ty: t.ty, aux: t.aux, a: a, b: wv, c: VNONE };
        return true;
    }

    // `or` `i` whose every byte is a byte of one value `x` of its type, through `or`s, shifts by whole bytes
    // and masks of whole bytes (`bytes_of`): `x` when each byte keeps its place, `x`'s bytes reversed
    // (`O_BSWAP`, `Package.bswap`) when each takes the mirrored one (LLVM's byte swap idiom). Whether it
    // did.
    fn byte_perm(self: &mut Self, pk: &Package, b: &mut Body, i: u32) bool {
        let t = b.insts[i as usize];
        let n = type_bytes(t.ty, pk.ptr_bytes);
        if t.op != O_OR || !is_int(t.ty) || n != 2 && n != 4 && n != 8 || !byte_part(b, self.val(t.a)) || !byte_part(
            b,
            self.val(t.b),
        ) {
            return false;
        }
        let mut src = VNONE;
        // A tree of shared parts expands: 16 steps a byte covers the halving steps of 8 bytes.
        let mut budget: u32 = 16 * n;
        let mut by = [NOBYTE; 8];
        if !self.bytes_of(b, n, i, &mut src, &mut by, &mut budget) {
            return false;
        }
        let mut same = true;
        let mut mirror = pk.bswap;
        for j in 0..n {
            same = same && by[j as usize] == j as u8;
            mirror = mirror && by[j as usize] == (n - 1 - j) as u8;
        }
        if same {
            self.repl[i as usize] = src;
            return true;
        }
        if !mirror {
            return false;
        }
        b.insts[i as usize] = Inst { op: O_BSWAP, ty: t.ty, aux: 0, a: src, b: VNONE, c: VNONE };
        return true;
    }

    // Into `by`, for each of the `n` bytes of value `v` (of the type of the `or` at hand), the byte of `src`
    // it is (NOBYTE: 0), through `or`s of disjoint bytes, shifts by whole bytes and `and`s with masks of
    // whole bytes; any other value (or the first one past `budget` steps) is `src` itself, which must be the
    // same everywhere. False when it is not.
    fn bytes_of(self: &Self, b: &Body, n: u32, v0: Value, src: &mut Value, by: &mut [u8; 8], budget: &mut u32) bool {
        if *budget == 0 {
            return false;
        }
        *budget -= 1;
        let v = self.val(v0);
        if let Some(c) = const_of(b, v) {
            if c == 0 {
                for j in 0..8 {
                    by[j] = NOBYTE;
                }
                return true;
            }
        }
        if (v & (VPARAM | VFLAG)) == 0 && v != VNONE {
            let x = b.insts[v as usize];
            let bin = x.op == O_OR || x.op == O_SHL || x.op == O_LSHR || x.op == O_AND;
            let s = if bin {
                const_of(b, x.b)
            } else {
                Option::<u64>::None
            };
            if x.op == O_OR {
                let mut r = [NOBYTE; 8];
                if !self.bytes_of(b, n, x.a, src, by, budget) || !self.bytes_of(b, n, x.b, src, &mut r, budget) {
                    return false;
                }
                for j in 0..n as usize {
                    if by[j] != NOBYTE && r[j] != NOBYTE {
                        return false;
                    }
                    if by[j] == NOBYTE {
                        by[j] = r[j];
                    }
                }
                return true;
            }
            if (x.op == O_SHL || x.op == O_LSHR) && s.is_some() && s.unwrap() % 8 == 0 && s.unwrap() < 8 * n as u64 {
                let mut r = [NOBYTE; 8];
                if !self.bytes_of(b, n, x.a, src, &mut r, budget) {
                    return false;
                }
                let d = (s.unwrap() / 8) as usize;
                for j in 0..n as usize {
                    by[j] = if x.op == O_SHL {
                        if j >= d {
                            r[j - d]
                        } else {
                            NOBYTE
                        }
                    } else if j + d < n as usize {
                        r[j + d]
                    } else {
                        NOBYTE
                    };
                }
                return true;
            }
            if x.op == O_AND {
                let (m, o) = if s.is_some() {
                    (s, x.a)
                } else {
                    (const_of(b, x.a), x.b)
                };
                if m.is_some() && whole_bytes(m.unwrap(), n) {
                    if !self.bytes_of(b, n, o, src, by, budget) {
                        return false;
                    }
                    for j in 0..n as usize {
                        if (m.unwrap() >> (8 * j) as u64 & 0xFF) == 0 {
                            by[j] = NOBYTE;
                        }
                    }
                    return true;
                }
            }
        }
        if *src == VNONE {
            *src = v;
        } else if *src != v {
            return false;
        }
        for j in 0..n as usize {
            by[j] = j as u8;
        }
        return true;
    }

    // The allocations (`ALLOC_FRESH` by the name, at most FRESH_MAX) whose pointer only stores write
    // through, equalities with null test and one free (`ALLOC_FREE`) takes, which every path from the
    // allocation to a return or back to it passes once: they go with their stores and free, and the tests
    // fold as for a block that exists (LLVM InstCombine's removal of unused allocations). The runtime's
    // leak tracker counts such a pair as nothing either. Whether any went.
    pub(package) fn dead_allocs(self: &mut Self, pk: &Package, b: &mut Body) bool {
        self.fresh.truncate(0);
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            if t.op == O_CALL && t.ty == T_PTR && self.fresh.len() < FRESH_MAX && named_alloc(pk, b, t) == ALLOC_FRESH {
                self.fresh.push(i as u32);
            }
        }
        if self.fresh.len() == 0 {
            return false;
        }
        fill(&mut self.fresh_ok, self.fresh.len(), true);
        fill(&mut self.fresh_free, self.fresh.len(), NONE);
        let lo = self.fresh[0];
        let hi = self.fresh[self.fresh.len() - 1];
        let mut left = self.fresh.len();
        let nb = b.blocks.len();
        for k in 0..nb {
            if left == 0 {
                return false;
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                self.fuses.truncate(0);
                lv::uses_into(b, t, &mut self.fuses);
                if is_terminator(t.op) {
                    b.succ_edges(t, &mut self.edges);
                    for e in 0..self.edges.len() {
                        for q in 0..b.edge_nargs(self.edges[e]) {
                            self.fuses.push(b.edge_arg(self.edges[e], q));
                        }
                    }
                }
                for u in 0..self.fuses.len() {
                    let v = self.fuses[u];
                    if v < lo || v > hi {
                        continue;
                    }
                    for f in 0..self.fresh.len() {
                        if v != self.fresh[f] || !self.fresh_ok[f] {
                            continue;
                        }
                        let ok = t.op == O_STORE && t.a == v && t.b != v && (t.aux & MEM_VOLATILE) == 0 || t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) && (const_of(
                            b,
                            t.a,
                        ) == Some(0u64) || const_of(b, t.b) == Some(0u64));
                        let free = t.op == O_CALL && t.aux == 1 && named_alloc(pk, b, t) == ALLOC_FREE && self.fresh_free[f] == NONE;
                        if free {
                            self.fresh_free[f] = k as u32;
                        }
                        if !ok && !free {
                            self.fresh_ok[f] = false;
                            left -= 1;
                        }
                    }
                }
            }
        }
        let mut any = false;
        for f in 0..self.fresh.len() {
            let fb = self.fresh_free[f];
            if !self.fresh_ok[f] || fb == NONE || !self.freed_once(b, self.fresh[f], fb) {
                continue;
            }
            let v = self.fresh[f];
            for i in 0..b.insts.len() {
                let t = b.insts[i];
                if t.op == O_ICMP && (t.a == v || t.b == v) {
                    b.insts[i] = iconst(t.ty, (t.aux == C_NE) as u64);
                } else if t.op == O_STORE && t.a == v || t.op == O_CALL && t.aux == 1 && b.pool[t.c as usize] == v {
                    b.insts[i] = iconst(T_I8, 0);
                }
            }
            b.insts[v as usize] = iconst(T_PTR, 0);
            any = true;
        }
        if any {
            self.kept = K_NONE;
        }
        return any;
    }

    // Whether every path from allocation `v` (`dead_allocs`) to a return or back to the allocation passes
    // block `fb`, which frees it, and every path from that free to a return passes the allocation before
    // the free again: the block is freed once.
    fn freed_once(self: &mut Self, b: &Body, v: u32, fb: u32) bool {
        let mut home = NONE;
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            if v >= bk.start && v < bk.start + bk.len {
                home = k as u32;
            }
        }
        // The free in the allocation's block comes after it (it reads its value).
        return home == fb || self.reaches_end(b, home, fb, home) && self.reaches_end(b, fb, home, fb);
    }

    // Whether every path from the end of block `from` reaches block `stop` before a return or block `back`.
    fn reaches_end(self: &mut Self, b: &Body, from: u32, stop: u32, back: u32) bool {
        fill(&mut self.seen, b.blocks.len(), false);
        self.fstack.truncate(0);
        b.succ_edges(term(b, from), &mut self.edges);
        for e in 0..self.edges.len() {
            self.fstack.push(b.edge_target(self.edges[e]));
        }
        // Each step visits one block once, or drops one already visited.
        for _ in 0..b.blocks.len() + self.fstack.len() + b.pool.len() {
            if self.fstack.len() == 0 {
                return true;
            }
            let k = self.fstack.pop().unwrap();
            if k == stop || self.seen[k as usize] {
                continue;
            }
            let tt = term(b, k);
            if k == back || tt.op == O_RET {
                return false;
            }
            self.seen[k as usize] = true;
            b.succ_edges(tt, &mut self.edges);
            for e in 0..self.edges.len() {
                self.fstack.push(b.edge_target(self.edges[e]));
            }
        }
        return false;
    }

    fn fold_ptr(self: &Self, pk: &Package, b: &mut Body, i: u32) bool {
        return fold_ptr(pk, b, i, self.unit);
    }

    // Call `i` of block `k` of the C library's `memcmp` whose result only an equality with 0 right after it
    // reads, of a count
    // up to MEMCMP_MAX bytes that is a constant or that a branch into the block settles: a compare of loads
    // of both sides, two each (overlapping) for a count that is not a power of two (LLVM ExpandMemCmp). A
    // load of read-only data folds to its constant. Whether it did.
    fn memcmp_eq(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        let bk = b.blocks[k as usize];
        if t.aux != 3 || t.ty != T_I32 || i as usize >= self.icount.len() || self.icount[i as usize] != 1 || i + 1 >= bk.start + bk.len {
            return false;
        }
        let u = b.insts[i as usize + 1];
        if u.op != O_ICMP || u.aux != C_EQ && u.aux != C_NE || !(u.a == i && const_of(b, u.b) == Some(0u64) || u.b == i && const_of(
            b,
            u.a,
        ) == Some(0u64)) {
            return false;
        }
        let pa = self.val(b.pool[t.c as usize]);
        let pb = self.val(b.pool[t.c as usize + 1]);
        let nv = self.val(b.pool[t.c as usize + 2]);
        let mut n = const_of(b, nv);
        if n.is_none() {
            n = self.count_fact(pk, b, k, nv);
        }
        if n.is_none() || n.unwrap() > MEMCMP_MAX {
            return false;
        }
        let c = n.unwrap() as u32;
        if c == 0 {
            b.insts[i as usize] = iconst(T_I32, 0);
            return true;
        }
        // The widest power of two not past the count, at most 8 bytes: its loads at 0 and at `c - w`.
        let w: u32 = if c >= 8 {
            8
        } else if c >= 4 {
            4
        } else if c >= 2 {
            2
        } else {
            1
        };
        let ty = if w == 8 {
            T_I64
        } else if w == 4 {
            T_I32
        } else if w == 2 {
            T_I16
        } else {
            T_I8
        };
        let mut d = VNONE;
        let mut la1 = VNONE;
        let mut lb1 = VNONE;
        let offs: [u32; 2] = [0, c - w];
        let parts: u32 = if c == w {
            1
        } else {
            2
        };
        for q in 0..parts {
            let la = self.before(b, k, i, Inst { op: O_LOAD, ty: ty, aux: 0, a: pa, b: VNONE, c: offs[q as usize] });
            let _ = fold_data(pk, b, la);
            let lb = self.before(b, k, i, Inst { op: O_LOAD, ty: ty, aux: 0, a: pb, b: VNONE, c: offs[q as usize] });
            let _ = fold_data(pk, b, lb);
            if parts == 1 {
                la1 = la;
                lb1 = lb;
                break;
            }
            let x = self.before(b, k, i, Inst { op: O_XOR, ty: ty, aux: 0, a: la, b: lb, c: VNONE });
            d = if d == VNONE {
                x
            } else {
                self.before(b, k, i, Inst { op: O_OR, ty: ty, aux: 0, a: d, b: x, c: VNONE })
            };
        }
        // One load each: their compare; two: the `or` of their differences against 0.
        if parts == 2 {
            la1 = d;
            lb1 = self.constant(b, ty, 0);
        }
        let ne = self.before(b, k, i, Inst { op: O_ICMP, ty: T_I8, aux: C_NE, a: la1, b: lb1, c: VNONE });
        b.insts[i as usize] = Inst { op: O_ZEXT, ty: T_I32, aux: 0, a: ne, b: VNONE, c: VNONE };
        return true;
    }

    // The constant that value `n` (no instruction of block `k`) equals where `k` starts, by the equality
    // the branch of `k`'s one predecessor tests (`entry_fact`); None when none settles it.
    fn count_fact(self: &Self, pk: &Package, b: &Body, k: u32, n: Value) Option<u64> {
        if self.pred_at[k as usize + 1] - self.pred_at[k as usize] != 1 {
            return None;
        }
        let st = term(b, self.preds[self.pred_at[k as usize] as usize]);
        if st.op != O_BR || (st.a & (VPARAM | VFLAG)) != 0 || st.a == VNONE {
            return None;
        }
        let ci = b.insts[st.a as usize];
        if ci.op != O_ICMP || ci.aux != C_EQ && ci.aux != C_NE || ci.a != n {
            return None;
        }
        let c = const_of(b, ci.b);
        if c.is_none() || self.entry_fact(pk, b, k, n, c.unwrap(), THREAD_DEPTH) != Some(true) {
            return None;
        }
        return c;
    }

    // An instruction for block `k` that runs right before instruction `at` (`pre`), its operands final;
    // its value.
    fn before(self: &mut Self, b: &mut Body, k: u32, at: u32, t: Inst) Value {
        let v = b.insts.len() as u32;
        b.insts.push(t);
        b.locs.push(b.locs[at as usize]);
        if b.inl.len() != 0 {
            b.inl.push(b.inl[at as usize]);
        }
        self.repl.push(VNONE);
        self.frepl.push(VNONE);
        self.moved.push(true);
        self.blk_of.push(k);
        self.pre.push(at as u64 << 32 | v as u64);
        return v;
    }

    // Instruction `i` of block `k`, a quotient or remainder of an integer by a constant: replaced by the high
    // half of the product by the multiplier `magic` (unsigned) or `smagic` (signed) gives, a 64-bit one where
    // the backend has one instruction for it (`Package.mul_high`); a signed one by a power of two by shifts
    // (Warren, Hacker's Delight, 10-1). Not by 0, nor a signed one by -1 (the minimum's overflow stays the
    // division's), nor an unsigned one by a power of two (`pow2`). Whether it did.
    fn divide(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if t.op < O_SDIV || t.op > O_UREM || !is_int(t.ty) || t.ty == T_I128 || t.ty == T_PTR {
            return false;
        }
        let bits = type_bits(t.ty, pk.ptr_bytes);
        let c = const_of(b, t.b);
        if c.is_none() {
            return false;
        }
        if t.op == O_SDIV || t.op == O_SREM {
            return self.divide_signed(pk, b, k, i, le::sign_ext(c.unwrap(), bits));
        }
        if bits == 64 && !pk.mul_high {
            return false;
        }
        let d = c.unwrap() & width_mask(t.ty, pk.ptr_bytes);
        if d == 0 || (d & d - 1) == 0 {
            return false;
        }
        let (m, sh, add) = magic(d, bits);
        let n = t.a;
        let mut q = VNONE;
        if bits == 32 && !add {
            // A 32-bit dividend: its 64-bit product by the multiplier, shifted once by 32 more.
            let w = self.before(b, k, i, Inst { op: O_ZEXT, ty: T_I64, aux: 0, a: n, b: VNONE, c: VNONE });
            let mv = self.constant(b, T_I64, m);
            let p = self.before(b, k, i, Inst { op: O_MUL, ty: T_I64, aux: 0, a: w, b: mv, c: VNONE });
            let sv = self.constant(b, T_I64, 32 + sh);
            let h = self.before(b, k, i, Inst { op: O_LSHR, ty: T_I64, aux: 0, a: p, b: sv, c: VNONE });
            q = self.before(b, k, i, Inst { op: O_TRUNC, ty: t.ty, aux: 0, a: h, b: VNONE, c: VNONE });
        }
        if q == VNONE {
            q = self.mulhu_quotient(b, k, i, n, m, sh, add);
        }
        if t.op == O_UDIV {
            self.repl[i as usize] = q;
            return true;
        }
        let prod = self.before(b, k, i, Inst { op: O_MUL, ty: t.ty, aux: 0, a: q, b: t.b, c: VNONE });
        self.repl[i as usize] = self.before(b, k, i, Inst { op: O_SUB, ty: t.ty, aux: 0, a: n, b: prod, c: VNONE });
        return true;
    }

    // `divide`'s quotient of `n` (instruction `i` of block `k`) by the high half of its product by `m`,
    // `add` adding `n` back (a multiplier one bit wider than the type), shifted right by `sh`.
    fn mulhu_quotient(self: &mut Self, b: &mut Body, k: u32, i: u32, n: Value, m: u64, sh: u64, add: bool) Value {
        let t = b.insts[i as usize];
        let mv = self.constant(b, t.ty, m);
        let h = self.before(b, k, i, Inst { op: O_MULHU, ty: t.ty, aux: 0, a: n, b: mv, c: VNONE });
        let mut q = h;
        if add {
            let diff = self.before(b, k, i, Inst { op: O_SUB, ty: t.ty, aux: 0, a: n, b: h, c: VNONE });
            let one = self.constant(b, t.ty, 1);
            let half = self.before(b, k, i, Inst { op: O_LSHR, ty: t.ty, aux: 0, a: diff, b: one, c: VNONE });
            q = self.before(b, k, i, Inst { op: O_ADD, ty: t.ty, aux: 0, a: half, b: h, c: VNONE });
        }
        if sh != 0 {
            let sv = self.constant(b, t.ty, sh);
            q = self.before(b, k, i, Inst { op: O_LSHR, ty: t.ty, aux: 0, a: q, b: sv, c: VNONE });
        }
        return q;
    }

    // `divide` of signed quotient or remainder `i` by `d`, the constant sign-extended. By a power of two
    // 2^s (or its negation), the dividend plus 2^s - 1 when negative (`bias`), shifted, the remainder the
    // dividend less those bits but the low `s`; by another, the high half of the product by `smagic`'s
    // multiplier, corrected by the dividend when the multiplier's sign is not the divisor's, shifted, plus
    // 1 when negative (rounding toward 0).
    fn divide_signed(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32, d: i64) bool {
        let t = b.insts[i as usize];
        let ty = t.ty;
        let bits = type_bits(ty, pk.ptr_bytes);
        let quot = t.op == O_SDIV;
        let n = t.a;
        if d == 0 || d == -1 {
            return false;
        }
        if d == 1 {
            self.repl[i as usize] = if quot {
                n
            } else {
                self.constant(b, ty, 0)
            };
            return true;
        }
        let ad = if d < 0 {
            0u64.wrapping_sub(d as u64)
        } else {
            d as u64
        };
        let wm = width_mask(ty, pk.ptr_bytes);
        if (ad & ad - 1) == 0 {
            let s = ad.trailing_zeros() as u64;
            let mut sgn = n;
            if s > 1 {
                let sv = self.constant(b, ty, s - 1);
                sgn = self.before(b, k, i, Inst { op: O_ASHR, ty: ty, aux: 0, a: n, b: sv, c: VNONE });
            }
            let rv = self.constant(b, ty, bits as u64 - s);
            let bias = self.before(b, k, i, Inst { op: O_LSHR, ty: ty, aux: 0, a: sgn, b: rv, c: VNONE });
            let up = self.before(b, k, i, Inst { op: O_ADD, ty: ty, aux: 0, a: n, b: bias, c: VNONE });
            if !quot {
                let mv = self.constant(b, ty, ~(ad - 1) & wm);
                let low = self.before(b, k, i, Inst { op: O_AND, ty: ty, aux: 0, a: up, b: mv, c: VNONE });
                self.repl[i as usize] = self.before(b, k, i, Inst { op: O_SUB, ty: ty, aux: 0, a: n, b: low, c: VNONE });
                return true;
            }
            let sv = self.constant(b, ty, s);
            let mut q = self.before(b, k, i, Inst { op: O_ASHR, ty: ty, aux: 0, a: up, b: sv, c: VNONE });
            if d < 0 {
                q = self.before(b, k, i, Inst { op: O_NEG, ty: ty, aux: 0, a: q, b: VNONE, c: VNONE });
            }
            self.repl[i as usize] = q;
            return true;
        }
        if bits == 64 && !pk.mul_high {
            return false;
        }
        let (m, sh) = smagic(d, bits);
        let mv = self.constant(b, ty, m);
        let mut h = self.before(b, k, i, Inst { op: O_MULHS, ty: ty, aux: 0, a: n, b: mv, c: VNONE });
        let ms = le::sign_ext(m, bits);
        if d > 0 && ms < 0 {
            h = self.before(b, k, i, Inst { op: O_ADD, ty: ty, aux: 0, a: h, b: n, c: VNONE });
        } else if d < 0 && ms > 0 {
            h = self.before(b, k, i, Inst { op: O_SUB, ty: ty, aux: 0, a: h, b: n, c: VNONE });
        }
        if sh != 0 {
            let sv = self.constant(b, ty, sh);
            h = self.before(b, k, i, Inst { op: O_ASHR, ty: ty, aux: 0, a: h, b: sv, c: VNONE });
        }
        let top = self.constant(b, ty, bits as u64 - 1);
        let neg = self.before(b, k, i, Inst { op: O_LSHR, ty: ty, aux: 0, a: h, b: top, c: VNONE });
        let q = self.before(b, k, i, Inst { op: O_ADD, ty: ty, aux: 0, a: h, b: neg, c: VNONE });
        if quot {
            self.repl[i as usize] = q;
            return true;
        }
        let prod = self.before(b, k, i, Inst { op: O_MUL, ty: ty, aux: 0, a: q, b: t.b, c: VNONE });
        self.repl[i as usize] = self.before(b, k, i, Inst { op: O_SUB, ty: ty, aux: 0, a: n, b: prod, c: VNONE });
        return true;
    }

    // Remainder `i` of block `k` of an integer by a value whose quotient a dominating instruction computes:
    // the dividend less that quotient times the divisor (one division where `a / b + a % b` took two).
    // Whether it did.
    fn rem_by_quotient(self: &mut Self, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if t.op != O_UREM && t.op != O_SREM || !is_int(t.ty) || t.ty == T_I128 || is_vec(t.ty) {
            return false;
        }
        let d = Inst {
            op: if t.op == O_UREM {
                O_UDIV
            } else {
                O_SDIV
            },
            ty: t.ty,
            aux: t.aux,
            a: t.a,
            b: t.b,
            c: t.c,
        };
        let q = switch self.pure.get(&value_hash(b, d)) {
            Some(v) => *v,
            None => NONE,
        };
        if q == NONE || !same_value(b, b.insts[q as usize], d) {
            return false;
        }
        let prod = self.before(b, k, i, Inst { op: O_MUL, ty: t.ty, aux: 0, a: q, b: t.b, c: VNONE });
        self.repl[i as usize] = self.before(b, k, i, Inst { op: O_SUB, ty: t.ty, aux: 0, a: t.a, b: prod, c: VNONE });
        return true;
    }

    // Value-number pure instruction `i` of block `k`: an equal one of a dominating block replaces it, else
    // it enters the scope and moves out of the loops it does not vary in. Whether it went or moved.
    fn number(self: &mut Self, pk: &Package, b: &Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        let h = value_hash(b, t);
        let found = switch self.pure.get(&h) {
            Some(v) => *v,
            None => NONE,
        };
        if found != NONE && same_value(b, b.insts[found as usize], t) {
            self.repl[i as usize] = found;
            return true;
        }
        // On a hash collision the newer entry shadows the older: either is correct.
        self.enter(LOG_PURE, h, i);
        return self.hoist(pk, b, k, i, false, false, false);
    }

    // Division `i` of a scalar float by a power of 2 whose reciprocal is a normal number: in place, the
    // product by that reciprocal, which rounds the same exact value once (LLVM's exact inverse; `x / 2.0`
    // is `x * 0.5` in every mode).
    fn exact_reciprocal(self: &mut Self, b: &mut Body, i: u32) {
        let mut t = b.insts[i as usize];
        if t.op != O_FDIV {
            return; // `fast_math` made it a product already
        }
        let c = float_const(b, t.b);
        let frac = if t.ty == T_F64 {
            0xFFFFFFFFFFFFFu64
        } else {
            0x7FFFFFu64
        };
        if c.is_none() || (c.unwrap() & frac) != 0 || !regular(t.ty, c.unwrap()) {
            return;
        }
        let one = if t.ty == T_F64 {
            0x3FF0000000000000u64
        } else {
            0x3F800000u64
        };
        let r = le::float_op(O_FDIV, t.ty, one, c.unwrap());
        if regular(t.ty, r) {
            t.op = O_FMUL;
            t.b = self.fconstant(b, t.ty, r);
            b.insts[i as usize] = t;
        }
    }

    // The rewrites of float operation `i` the package's `fmath` allows: an identity's operand (`x + 0` without
    // signed zeros; `x * 1`, `x / 1` and, without signed zeros either, `x * 0` and `x - x` when no value is
    // NaN or infinite) as its replacement, or in place a division by a constant as a product by its
    // reciprocal, two constants of one operation chain as one (reassociation), a sum of a product as a
    // fused multiply-add (contraction). The replacement, or VNONE.
    fn fast_math(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) Value {
        let fm = pk.fmath;
        let mut t = b.insts[i as usize];
        let op = t.op;
        // A commutative operation takes a constant second.
        if (op == O_FADD || op == O_FMUL) && float_const(b, t.a).is_some() && float_const(b, t.b).is_none() {
            let x = t.a;
            t.a = t.b;
            t.b = x;
            b.insts[i as usize] = t;
        }
        let one = if t.ty == T_F64 {
            0x3FF0000000000000u64
        } else {
            0x3F800000u64
        };
        let cb = float_const(b, t.b);
        let finite = (fm & FM_FINITE) != 0;
        let nsz = (fm & FM_NSZ) != 0;
        if cb.is_some() {
            let c = cb.unwrap();
            if op == O_FADD && c == 0 && nsz || (op == O_FMUL || op == O_FDIV) && c == one && finite {
                return t.a;
            }
            if op == O_FMUL && c == 0 && finite && nsz {
                return t.b;
            }
            if op == O_FDIV && (fm & FM_RECIP) != 0 {
                let r = le::float_op(O_FDIV, t.ty, one, c);
                if regular(t.ty, r) {
                    t.op = O_FMUL;
                    t.b = self.fconstant(b, t.ty, r);
                    b.insts[i as usize] = t;
                    return VNONE;
                }
            }
            // (x op c1) op c2: x op (c1 op c2).
            if (op == O_FADD || op == O_FMUL) && (fm & FM_ASSOC) != 0 && (t.a & (VPARAM | VFLAG)) == 0 {
                let x = b.insts[t.a as usize];
                let c1 = float_const(b, x.b);
                if x.op == op && x.ty == t.ty && c1.is_some() {
                    let r = le::float_op(op, t.ty, c1.unwrap(), c);
                    if regular(t.ty, r) || r == 0 {
                        t.a = x.a;
                        t.b = self.fconstant(b, t.ty, r);
                        b.insts[i as usize] = t;
                        return VNONE;
                    }
                }
            }
        }
        if op == O_FSUB && t.a == t.b && finite && nsz {
            return self.fconstant(b, t.ty, 0);
        }
        // a * b + c: one rounding; a * b - c and c - a * b too when the operand they negate is a constant
        // (`-c`, `-a`). Not when `c` is a loop's accumulator, a parameter of the header of a loop holding the
        // sum: the chain through it waits on the fused operation's latency, longer than an addition's, where
        // the product computes beside it (GCC's FMA deferring, PR 81616).
        if (op == O_FADD || op == O_FSUB) && (fm & FM_CONTRACT) != 0 && pk.fma {
            let sign = if t.ty == T_F64 {
                1u64 << 63
            } else {
                1u64 << 31
            };
            let mut m = VNONE;
            let mut x = VNONE;
            let mut y = VNONE;
            let mut c = VNONE;
            if is_fmul(b, t.a, t.ty) {
                m = t.a;
                c = t.b;
                let cc = float_const(b, c);
                if op == O_FSUB && cc.is_none() {
                    m = VNONE;
                } else if op == O_FSUB {
                    c = self.fconstant(b, t.ty, cc.unwrap() ^ sign);
                }
                if m != VNONE {
                    x = b.insts[m as usize].a;
                    y = b.insts[m as usize].b;
                }
            } else if is_fmul(b, t.b, t.ty) {
                m = t.b;
                c = t.a;
                x = b.insts[m as usize].a;
                y = b.insts[m as usize].b;
                if op == O_FSUB {
                    let xc = float_const(b, x);
                    let yc = float_const(b, y);
                    if xc.is_some() {
                        x = self.fconstant(b, t.ty, xc.unwrap() ^ sign);
                    } else if yc.is_some() {
                        y = self.fconstant(b, t.ty, yc.unwrap() ^ sign);
                    } else {
                        m = VNONE;
                    }
                }
            }
            if m != VNONE && !self.carried(c, k) {
                b.insts[i as usize] = Inst { op: O_FMA, ty: t.ty, aux: 0, a: x, b: y, c: c };
            }
        }
        return VNONE;
    }

    // Whether `c` is a parameter of the header of a loop holding block `k`: a value the loop carries.
    fn carried(self: &Self, c: Value, k: u32) bool {
        if (c & (VPARAM | VFLAG)) != VPARAM {
            return false;
        }
        let h = self.pblock[(c & ~VPARAM) as usize];
        return self.inner[h as usize] == h && self.in_loop(h, k);
    }

    // The float constant of type `ty` with bits `v`, made in the entry block as `constant` makes integers.
    fn fconstant(self: &mut Self, b: &mut Body, ty: u8, v: u64) Value {
        let t = Inst { op: O_FCONST, ty: ty, aux: 0, a: v as u32, b: (v >> 32) as u32, c: VNONE };
        let h = hash(t);
        let found = switch self.made.get(&h) {
            Some(x) => *x,
            None => NONE,
        };
        if found != NONE && same(b.insts[found as usize], t) {
            return found;
        }
        let i = b.insts.len() as u32;
        b.insts.push(t);
        b.locs.push(0);
        if b.inl.len() != 0 {
            b.inl.push(0);
        }
        self.repl.push(VNONE);
        self.frepl.push(VNONE);
        self.moved.push(false);
        self.blk_of.push(0);
        self.extra.push(i);
        self.made.insert(h, i);
        return i;
    }

    // ---- Memory ----

    // The writes into each slot or aggregate argument whose address does not escape (`sbase`, `soff`,
    // `sesc`, `wat`, `wl`): its address and the constant offsets from it are only a load's or a store's
    // address, a copy's source, a copy's or a fill's destination, or the slice a vector access reads
    // (`header_read`). Every other use lets unknown code write it. The reached blocks in reverse postorder:
    // a definition comes before its uses.
    fn slot_writes(self: &mut Self, pk: &Package, b: &Body) {
        let ns = b.slots.len() + b.blocks[0].param_len as usize;
        let ni = b.insts.len();
        fill(&mut self.sbase, ni, NONE);
        self.soff.truncate(0);
        self.soff.resize_default(ni);
        fill(&mut self.sesc, ns, false);
        self.wr.truncate(0);
        for q in 0..self.order.len() {
            let k = self.order[q];
            let bk = b.blocks[k as usize];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                if t.op == O_SLOTADDR {
                    self.sbase[i as usize] = t.a;
                    continue;
                }
                if t.op == O_PTRADD && t.b == VNONE && self.base(b, t.a) != NONE {
                    self.sbase[i as usize] = self.base(b, t.a);
                    self.soff[i as usize] = self.base_off(t.a) + (t.c as i32) as i64;
                    continue;
                }
                let u0 = self.ops_at[i as usize];
                for u in 0..self.ops_at[i as usize + 1] - u0 {
                    let v = self.ops[(u0 + u) as usize];
                    let s = self.base(b, v);
                    if s == NONE {
                        continue;
                    }
                    let o = self.base_off(v);
                    let size = if t.op == O_MEMCPY || t.op == O_MEMSET {
                        const_of(b, t.c)
                    } else {
                        Option::<u64>::None
                    };
                    let end = if size.is_some() && size.unwrap() < 1u64 << 40 {
                        o + size.unwrap() as i64
                    } else {
                        0x7FFFFFFFFFFFFFFF
                    };
                    if t.op == O_LOAD || t.op == O_MEMCPY && t.b == v && t.a != v || t.op == O_VOP && header_read(
                        b,
                        t,
                        v,
                    ) {
                        // A read.
                    } else if t.op == O_STORE && t.a == v && t.b != v && (t.aux & MEM_VOLATILE) == 0 {
                        let at = o + (t.c as i32) as i64;
                        self.wr.push(
                            SlotWrite {
                                slot: s,
                                off: at,
                                end: at + type_bytes(b.type_of(t.b), pk.ptr_bytes) as i64,
                                inst: i,
                                blk: k,
                            },
                        );
                    } else if t.op == O_MEMCPY && t.a == v && t.b != v || t.op == O_MEMSET && t.a == v {
                        self.wr.push(SlotWrite { slot: s, off: o, end: end, inst: NONE, blk: k });
                    } else {
                        self.sesc[s as usize] = true;
                    }
                }
            }
        }
        // The writes by slot: a counting sort.
        fill(&mut self.wat, ns + 1, 0);
        for w in 0..self.wr.len() {
            self.wat[self.wr[w].slot as usize + 1] += 1;
        }
        for s in 0..ns {
            self.wat[s + 1] += self.wat[s];
        }
        fill(&mut self.work, ns, 0);
        self.wl.truncate(0);
        for w in 0..self.wr.len() {
            self.wl.push(self.wr[w]);
        }
        for w in 0..self.wr.len() {
            let s = self.wr[w].slot as usize;
            self.wl[(self.wat[s] + self.work[s]) as usize] = self.wr[w];
            self.work[s] += 1;
        }
    }

    // The private memory address value `v` points into (`sbase`'s numbering), NONE for none.
    const fn base(self: &Self, b: &Body, v: Value) u32 {
        if (v & VFLAG) != 0 {
            return NONE;
        }
        if (v & VPARAM) == 0 {
            // A select the walk made (`diamond`) takes values `slot_writes` saw escape as edge arguments.
            return if v as usize < self.sbase.len() {
                self.sbase[v as usize]
            } else {
                NONE
            };
        }
        let p = v & ~VPARAM;
        let e = b.blocks[0];
        // The parameters past the signature's: an aggregate result's pointer, the caller's memory.
        if b.sig == NONE || p < e.param_start || p >= e.param_start + b.pool[b.sig as usize] || (b.pool[(b.sig + 3 + p - e.param_start) as usize] & AGG) == 0 {
            return NONE;
        }
        return b.slots.len() as u32 + p - e.param_start;
    }

    // The offset of address value `v` into its private memory (`base`).
    const fn base_off(self: &Self, v: Value) i64 {
        if (v & (VPARAM | VFLAG)) != 0 {
            return 0;
        }
        return self.soff[v as usize];
    }

    // Load `t` (instruction `i` of block `k`) of private memory whose address does not escape: PRIV_NONE
    // when that does not hold or another write touches its bytes; PRIV_KEPT when no write touches them, so
    // it reads the same value wherever it runs; else the value of the one store that writes exactly its
    // bytes when that store dominates it (as LLVM's mem2reg promotes an alloca of one store: on any path
    // to the load the last write of those bytes is that store's).
    fn private_load(self: &Self, pk: &Package, b: &Body, k: u32, i: u32, t: Inst) Value {
        let s = self.base(b, t.a) as usize;
        if s == NONE as usize || self.sesc[s] || self.wat[s + 1] - self.wat[s] > SLOT_WRITES_MAX {
            return PRIV_NONE;
        }
        let off = self.base_off(t.a) + (t.c as i32) as i64;
        let end = off + type_bytes(t.ty, pk.ptr_bytes) as i64;
        let mut one = NONE;
        let mut blk = NONE;
        for q in self.wat[s]..self.wat[s + 1] {
            let w = self.wl[q as usize];
            if w.off < end && off < w.end {
                if one != NONE || w.inst == NONE || w.off != off || w.end != end {
                    return PRIV_NONE;
                }
                one = w.inst;
                blk = w.blk;
            }
        }
        if one == NONE {
            return PRIV_KEPT;
        }
        let st = b.insts[one as usize];
        if b.type_of(st.b) != t.ty || blk == k && one >= i || blk != k && !self.dominates(blk, k) {
            return PRIV_NONE;
        }
        return self.val(st.b);
    }

    // The value a vector load `t` (instruction `i` of block `k`) of a private slot splats: one store alone
    // writes each of its lanes, each of the same value, and each runs before the load (`[x; N]` as a
    // vector); VNONE otherwise.
    fn private_splat(self: &Self, pk: &Package, b: &Body, k: u32, i: u32, t: Inst) Value {
        if !is_vec(t.ty) || lanes(t.ty) > 64 {
            return VNONE;
        }
        let s = self.base(b, t.a) as usize;
        if s == NONE as usize || self.sesc[s] || self.wat[s + 1] - self.wat[s] > SLOT_WRITES_MAX {
            return VNONE;
        }
        let lt = lane_type(t.ty);
        let eb = type_bytes(lt, pk.ptr_bytes) as i64;
        let off = self.base_off(t.a) + (t.c as i32) as i64;
        let end = off + type_bytes(t.ty, pk.ptr_bytes) as i64;
        let mut v = VNONE;
        let mut seen: u64 = 0;
        for q in self.wat[s]..self.wat[s + 1] {
            let w = self.wl[q as usize];
            if w.off >= end || off >= w.end {
                continue;
            }
            if w.inst == NONE || w.off < off || w.end - w.off != eb || (w.off - off) % eb != 0 {
                return VNONE;
            }
            let lane = 1u64 << ((w.off - off) / eb) as u64;
            let st = b.insts[w.inst as usize];
            let x = self.val(st.b);
            if (seen & lane) != 0 || b.type_of(st.b) != lt || v != VNONE && x != v || w.blk == k && w.inst >= i || w.blk != k && !self.dominates(
                w.blk,
                k,
            ) {
                return VNONE;
            }
            seen |= lane;
            v = x;
        }
        return if seen.count_ones() as u32 == lanes(t.ty) {
            v
        } else {
            VNONE
        };
    }

    // The private slots: those whose address and the addresses derived from it (`ptradd`) are only the
    // addresses of loads, stores, copies and fills (`pder`, `pesc`). No pointer but these reaches their
    // memory, so no other access touches it. A derived address another way used (stored, passed, joined,
    // compared) escapes.
    fn privates(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        fill(&mut self.pder, ni, NONE);
        fill(&mut self.pesc, b.slots.len(), false);
        // In reverse postorder a definition comes before its uses: block arguments, which escape, aside.
        for q in 0..self.order.len() {
            let bk = b.blocks[self.order[q] as usize];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                if t.op == O_SLOTADDR {
                    self.pder[i as usize] = t.a;
                } else if t.op == O_PTRADD && (t.a & (VPARAM | VFLAG)) == 0 && t.a < ni as u32 {
                    self.pder[i as usize] = self.pder[t.a as usize];
                }
            }
        }
        for i in 0..ni {
            let t = b.insts[i];
            let u0 = self.ops_at[i];
            for u in 0..self.ops_at[i + 1] - u0 {
                let v = self.ops[(u0 + u) as usize];
                if (v & (VPARAM | VFLAG)) != 0 || v as usize >= ni || self.pder[v as usize] == NONE {
                    continue;
                }
                let addr = t.op == O_LOAD && t.a == v && u == 0 || t.op == O_STORE && t.a == v && t.b != v || t.op == O_MEMCPY && (t.a == v || t.b == v) && t.c != v || t.op == O_MEMSET && t.a == v && t.b != v && t.c != v || t.op == O_PTRADD && t.a == v && t.b != v;
                if !addr || (t.op == O_LOAD || t.op == O_STORE) && (t.aux & MEM_VOLATILE) != 0 {
                    self.pesc[self.pder[v as usize] as usize] = true;
                }
            }
        }
    }

    // The object address `a` of `b` points into (`lu::Classes.obj`): a slot (`privates`), private or not,
    // or a data symbol the package defines (not a C library's, which another name may alias), through at
    // most FRAME_DEPTH steps of address arithmetic; NONE for any other.
    fn object(self: &Self, pk: &Package, b: &Body, a: Value) u32 {
        if (a & (VPARAM | VFLAG)) != 0 {
            return NONE;
        }
        let s = self.pder[a as usize];
        if s != NONE {
            return s | if self.pesc[s as usize] {
                lu::OBJ_SLOT
            } else {
                lu::OBJ_PRIVATE
            };
        }
        let mut v = a;
        for _ in 0..FRAME_DEPTH {
            let t = b.insts[v as usize];
            if t.op == O_SYMADDR {
                let s = b.syms[t.a as usize];
                let y = pk.syms[s as usize];
                return if y.kind != SK_FUNC && !y.ext {
                    s
                } else {
                    NONE
                };
            }
            if t.op != O_PTRADD || (t.a & (VPARAM | VFLAG)) != 0 {
                return NONE;
            }
            v = t.a;
        }
        return NONE;
    }

    // Whether instruction `t` accesses only a private slot's memory (`privates`): a load from one, or a
    // store, copy or fill into one.
    fn private(self: &Self, t: Inst) bool {
        if t.op != O_LOAD && t.op != O_STORE && t.op != O_MEMCPY && t.op != O_MEMSET || (t.a & (VPARAM | VFLAG)) != 0 || t.a as usize >= self.pder.len() {
            return false;
        }
        let s = self.pder[t.a as usize];
        return s != NONE && !self.pesc[s as usize] && (t.aux & MEM_VOLATILE) == 0;
    }

    // The value a load of `addr + off` of type `ty` reads in memory state `state`, VNONE when unknown.
    fn recall(self: &Self, addr: u32, off: u32, ty: u8, state: u32) Value {
        let found = switch self.mem.get(&place_hash(addr, off, ty, state)) {
            Some(v) => *v,
            None => NONE,
        };
        if found == NONE {
            return VNONE;
        }
        let p = self.places[found as usize];
        return if p.addr == addr && p.off == off && p.ty == ty && p.state == state {
            p.val
        } else {
            VNONE
        };
    }

    // Load `t`, instruction `i` of block `k`, of an integer of at most 4 bytes: the bytes of a wider integer
    // a store left in the place that holds them in memory state `st`, shifted down and truncated
    // (little-endian, as every native target is). VNONE when none.
    fn recall_part(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32, t: Inst, st: u32) Value {
        let n = type_bytes(t.ty, pk.ptr_bytes) as i64;
        if !is_int(t.ty) || n > 4 {
            return VNONE;
        }
        let off = (t.c as i32) as i64;
        let wides: [u8; 3] = [T_I16, T_I32, T_I64];
        for w in wides {
            let m = type_bytes(w, pk.ptr_bytes) as i64;
            if m <= n {
                continue;
            }
            // Each start of a wider place that holds the load's bytes: at most 7.
            for d in 0..m - n + 1 {
                let o0 = off + n - m + d;
                let v = self.recall(t.a, (o0 as i32) as u32, w, st);
                if v == VNONE {
                    continue;
                }
                let mut x = v;
                if off != o0 {
                    let sh = self.constant(b, w, ((off - o0) * 8) as u64);
                    x = self.before(b, k, i, Inst { op: O_LSHR, ty: w, aux: 0, a: v, b: sh, c: VNONE });
                }
                return self.before(b, k, i, Inst { op: O_TRUNC, ty: t.ty, aux: 0, a: x, b: VNONE, c: VNONE });
            }
        }
        return VNONE;
    }

    fn remember(self: &mut Self, addr: u32, off: u32, ty: u8, v: Value, state: u32) {
        if self.recent.len() == RECENT_MAX {
            let _ = self.recent.remove(0);
        }
        self.recent.push(self.places.len() as u32);
        self.enter(LOG_MEM, place_hash(addr, off, ty, state), self.places.len() as u32);
        self.places.push(Place { addr: addr, off: off, ty: ty, state: state, val: v });
    }

    // Write `i`, which started memory state `states` for the type tags whose state `before` held
    // otherwise: each place of `recent` known in such a state that the write cannot touch holds its value
    // in the new state too. A write cannot touch a place of an alias class it writes none of (`write_bits`,
    // a scope's class aside), nor a store bytes of its own address apart from its own. A place moves only
    // along the states a load of it reads: the untagged accesses' and its type's tag's; another tag's
    // state may be its number by chance and then miss the writes of the place's own tag.
    fn carry(self: &mut Self, pk: &Package, b: &Body, i: u32, before: [u32; TBAA_TAGS]) {
        let t = b.insts[i as usize];
        let wb = self.write_bits(pk, b, i);
        let n = self.recent.len();
        // Each entry is checked once; the carried ones join `recent` after the old ones.
        for r in 0..n {
            let p = self.places[self.recent[r] as usize];
            let mut to = NONE;
            let tags: [usize; 2] = [0, tbaa_of(p.ty) as usize];
            for g in tags {
                if unsafe before[g] == p.state && unsafe self.tstate[g] != p.state {
                    to = unsafe self.tstate[g];
                }
            }
            if to == NONE {
                continue;
            }
            let c = self.class(p.addr);
            let other_class = c < CL_MANY && (class_bit(c) & self.sbits) == 0 && (wb & class_bit(c)) == 0;
            let lo = (p.off as i32) as i64;
            let tlo = (t.c as i32) as i64;
            let other_bytes = t.op == O_STORE && t.a == p.addr && (tlo >= lo + type_bytes(p.ty, pk.ptr_bytes) as i64 || lo >= tlo + type_bytes(
                b.type_of(t.b),
                pk.ptr_bytes,
            ) as i64);
            if (other_class || other_bytes) && self.recall(p.addr, p.off, p.ty, to) == VNONE {
                self.remember(p.addr, p.off, p.ty, p.val, to);
            }
        }
    }

    // Whether load `t` cannot fault wherever its address is defined: it reads inside a slot, a data
    // symbol of the package, an aggregate the caller passes by reference or a reference parameter's
    // referent (an entry block parameter: valid for the whole call).
    fn safe_load(self: &Self, pk: &Package, b: &Body, t: Inst) bool {
        if (t.a & VFLAG) != 0 {
            return false;
        }
        let mut size: i64 = -1;
        let (base, off0) = address(b, t);
        let mut off = off0;
        if (base & VFLAG) != 0 {
            return false;
        }
        if (base & VPARAM) != 0 {
            let p = base & ~VPARAM;
            let e = b.blocks[0];
            if b.sig != NONE && p >= e.param_start && p < e.param_start + b.pool[b.sig as usize] {
                let k = p - e.param_start;
                let code = b.pool[(b.sig + 3 + k) as usize];
                if (code & AGG) != 0 {
                    size = b.pool[(code & ~AGG) as usize];
                } else if k as usize < b.refs.len() {
                    size = b.refs[k as usize] & REF_BYTES;
                }
            }
        } else {
            let a = b.insts[base as usize];
            if a.op == O_SLOTADDR {
                size = b.slots[a.a as usize].size;
            } else if a.op == O_SYMADDR {
                let s = pk.syms[b.syms[a.a as usize] as usize];
                if s.kind == SK_DATA && s.def != NONE {
                    size = pk.data[s.def as usize].size;
                    off += a.b as i32;
                }
            }
        }
        return off >= 0 && off + type_bytes(t.ty, pk.ptr_bytes) as i64 <= size;
    }

    // ---- Hoisting ----

    // Move instruction `i` of block `k`, pure or a load (`load`), to the preheader of each loop around it
    // whose blocks do not define its operands (and, for a load, write no memory); with `one`, of the
    // innermost loop only. Whether it moved.
    fn hoist(self: &mut Self, pk: &Package, b: &Body, k: u32, i: u32, load: bool, kept: bool, one: bool) bool {
        let t = b.insts[i as usize];
        // A constant leaves its loops too: the backends rebuild one that one instruction makes at each use
        // and keep the others in a register (a 64-bit integer on arm64, a float).
        let konst = t.op == O_ICONST || t.op == O_FCONST;
        if !load && !konst && !speculable(pk, b, t) {
            return false;
        }
        let mut target = k;
        // Each step leaves one loop.
        loop {
            let h = self.inner[target as usize];
            // A load stays when the loop writes its alias class (a scope's too, outside the scope) and its
            // type tag (or untagged); one of a private slot's memory, when the loop writes that memory.
            let private = self.private(t);
            let cls = class_bit(self.loop_acc(i, h)) | self.sbits & ~self.member(i);
            if h == NONE || self.preh[h as usize] == NONE || load && !kept && private && self.pwrite[h as usize] || load && !kept && !private && (self.writes[h as usize] & cls) != 0 && (tbaa(
                t,
            ) == 0 || (self.tags[h as usize] & (1u16 << tbaa(t) as u16 | 1)) != 0) && !self.fields_apart(
                pk,
                b,
                h,
                t,
                cls,
            ) || !self.invariant(t, h) {
                break;
            }
            target = self.preh[h as usize];
            if one {
                break;
            }
        }
        if target == k {
            return false;
        }
        self.moved[i as usize] = true;
        self.blk_of[i as usize] = target;
        self.hoisted.push(target as u64 << 32 | i as u64);
        return true;
    }

    // Call `i` of block `k`, of a function that writes no memory, to the preheader of the loop `k` heads,
    // when its arguments come from outside the loop, the loop writes no memory but private slots' (which
    // no call reaches) and nothing before the call in `k` writes memory: every entry into the loop runs
    // the call first, with the arguments and the memory every iteration has, so the preheader runs it
    // once in place of each iteration. Whether it moved.
    fn hoist_call(self: &mut Self, b: &Body, k: u32, i: u32) bool {
        let h = self.inner[k as usize];
        if h != k || self.preh[h as usize] == NONE || self.writes[h as usize] != 0 || self.tags[h as usize] != 0 {
            return false;
        }
        let t = b.insts[i as usize];
        for q in 0..t.aux as u32 {
            if !self.outside(b.pool[(t.c + q) as usize], h) {
                return false;
            }
        }
        for j in b.blocks[k as usize].start..i {
            if self.repl[j as usize] == VNONE && !self.moved[j as usize] && writes_memory(b.insts[j as usize]) {
                return false;
            }
        }
        let target = self.preh[h as usize];
        self.moved[i as usize] = true;
        self.blk_of[i as usize] = target;
        self.hoisted.push(target as u64 << 32 | i as u64);
        return true;
    }

    // Whether instruction `i` of loop header `k` runs on every entry into the loop: no instruction before
    // it in `k` may leave the function or trap but by a fault of memory (a call, inline assembly, a system
    // operation, a division).
    fn runs_first(self: &Self, b: &Body, k: u32, i: u32) bool {
        if self.inner[k as usize] != k {
            return false;
        }
        for j in b.blocks[k as usize].start..i {
            let op = b.insts[j as usize].op;
            if op == O_CALL || op == O_CALLIND || op == O_ASM || op == O_SYS || op >= O_SDIV && op <= O_UREM || op == O_VAARG {
                return false;
            }
        }
        return true;
    }

    // Whether every operand of `t` is defined outside loop `h`.
    const fn invariant(self: &Self, t: Inst, h: u32) bool {
        let f = op_info(t.op).form;
        return (!lv::operand_a(f) || self.outside(t.a, h)) && (!lv::operand_b(f) || self.outside(t.b, h)) && (!lv::operand_c(
            f,
        ) || self.outside(t.c, h));
    }

    const fn outside(self: &Self, v: Value, h: u32) bool {
        if v == VNONE {
            return true;
        }
        let d = if (v & VPARAM) != 0 {
            self.pblock[(v & ~VPARAM) as usize]
        } else {
            self.blk_of[(v & ~VFLAG) as usize]
        };
        return !self.in_loop(h, d);
    }

    // ---- The rebuild -----------------------------------------------------------------------------------

    // The body without what the entry no longer reaches, what was replaced, and the pure instructions and
    // block parameters nothing uses (an edge argument is a use only for a parameter that stays); a block
    // whose one predecessor jumps to it continues that block; each moved instruction at the end of its
    // new block before the terminator, in the order they moved; every block, parameter and value
    // renumbered. No operand names a replaced value: the walk visits a definition before its uses.
    fn rebuild(self: &mut Self, b: &mut Body) {
        self.kept = K_NONE;
        let ni = b.insts.len();
        let nb = b.blocks.len();
        let npar = b.params.len();
        fill(&mut self.sused, b.slots.len(), NONE);
        self.reach(b);
        // The edges into each reached block (`into_at` ranges of `ins`), and its predecessor count.
        fill(&mut self.in_at, nb + 1, 0);
        for k in 0..nb {
            if self.bmap[k] != NONE {
                b.succ_edges(term(b, k as u32), &mut self.edges);
                for e in 0..self.edges.len() {
                    self.in_at[b.edge_target(self.edges[e]) as usize + 1] += 1;
                }
            }
        }
        for k in 0..nb {
            self.in_at[k + 1] += self.in_at[k];
        }
        fill(&mut self.ins, self.in_at[nb] as usize, 0);
        fill(&mut self.insrc, self.in_at[nb] as usize, 0);
        fill(&mut self.work, nb, 0);
        for k in 0..nb {
            if self.bmap[k] != NONE {
                b.succ_edges(term(b, k as u32), &mut self.edges);
                for e in 0..self.edges.len() {
                    let s = b.edge_target(self.edges[e]) as usize;
                    self.ins[(self.in_at[s] + self.work[s]) as usize] = self.edges[e];
                    self.insrc[(self.in_at[s] + self.work[s]) as usize] = k as u32;
                    self.work[s] += 1;
                }
            }
        }
        // Liveness over instructions and parameters: what has an effect in a reached block (and the entry
        // block's parameters, the signature's), then what it uses; a parameter that stays keeps its
        // edges' arguments.
        fill(&mut self.live, ni + npar, false);
        self.work.truncate(0);
        let e0 = b.blocks[0];
        for q in e0.param_start..e0.param_start + e0.param_len as u32 {
            self.mark(ni as u32 + q);
        }
        self.slot_reads(b);
        for k in 0..nb {
            if self.bmap[k] == NONE {
                continue;
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                if self.repl[i as usize] == VNONE && !droppable(t) && !self.dead_store(b, t) {
                    self.mark(i);
                }
            }
        }
        // The instructions made to run before another or at a block's end (a vector store or a gather's
        // stores `lir::slp` made, say).
        for q in 0..self.pre.len() + self.hoisted.len() {
            let v = if q < self.pre.len() {
                self.pre[q] as u32
            } else {
                self.hoisted[q - self.pre.len()] as u32
            };
            let t = b.insts[v as usize];
            if self.bmap[self.blk_of[v as usize] as usize] != NONE && !droppable(t) && !self.dead_store(b, t) {
                self.mark(v);
            }
        }
        // Each instruction and parameter enters the walk once.
        while self.work.len() != 0 {
            let x = self.work.pop().unwrap();
            if x as usize < ni {
                lv::uses(b, b.insts[x as usize], &mut self.uses);
                for u in 0..self.uses.len() {
                    let v = self.uses[u];
                    self.mark(
                        if (v & VPARAM) != 0 {
                            ni as u32 + (v & ~VPARAM)
                        } else {
                            v & ~VFLAG
                        },
                    );
                }
                continue;
            }
            let p = x - ni as u32;
            let k = self.pblock[p as usize] as usize;
            let q = p - b.blocks[k].param_start;
            for j in self.in_at[k]..self.in_at[k + 1] {
                let v = b.edge_arg(self.ins[j as usize], q);
                self.mark(
                    if (v & VPARAM) != 0 {
                        ni as u32 + (v & ~VPARAM)
                    } else {
                        v & ~VFLAG
                    },
                );
            }
        }
        // Merges: `nxt[p]` is the block that continues block `p` (NONE: none), a block it alone jumps to.
        fill(&mut self.nxt, nb, NONE);
        for k in 1..nb {
            if self.bmap[k] == NONE || self.in_at[k + 1] - self.in_at[k] != 1 {
                continue;
            }
            let bk = b.blocks[k];
            let mut kept = false;
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                kept = kept || self.live[ni + q as usize];
            }
            let p = self.insrc[self.in_at[k] as usize];
            if !kept && p != k as u32 && term(b, p).op == O_JMP {
                self.nxt[p as usize] = k as u32;
            }
        }
        // The heads: the reached blocks no other continues, numbered in order; a merged block takes its
        // head's number.
        fill(&mut self.done, nb, false);
        self.merged = false;
        for k in 0..nb {
            if self.nxt[k] != NONE {
                self.done[self.nxt[k] as usize] = true;
                self.merged = true;
            }
        }
        let mut nk: u32 = 0;
        for k in 0..nb {
            if self.bmap[k] != NONE && !self.done[k] {
                self.bmap[k] = nk;
                let mut cur = self.nxt[k];
                // Each step takes one block of the chain.
                while cur != NONE {
                    self.bmap[cur as usize] = nk;
                    cur = self.nxt[cur as usize];
                }
                nk += 1;
            }
        }
        // The moved instructions left, grouped by block: `into[work[k] .. work[k + 1]]`.
        fill(&mut self.work, nb + 1, 0);
        for q in 0..self.hoisted.len() {
            if self.live[(self.hoisted[q] as u32) as usize] {
                self.work[(self.hoisted[q] >> 32) as usize + 1] += 1;
            }
        }
        for k in 0..nb {
            self.work[k + 1] += self.work[k];
        }
        fill(&mut self.into, self.work[nb] as usize, 0);
        fill(&mut self.newidx, nb, 0);
        for q in 0..self.hoisted.len() {
            let i = self.hoisted[q] as u32;
            if self.live[i as usize] {
                let k = (self.hoisted[q] >> 32) as usize;
                self.into[(self.work[k] + self.newidx[k]) as usize] = i;
                self.newidx[k] += 1;
            }
        }
        // The instructions to run right before each (`pre`), in the order the walk made them.
        // Counted into `pre_at[i + 2]`, summed, then placed with `pre_at[i + 1]` as the cursor: it ends at
        // the range's end, so `pre_list[pre_at[i] .. pre_at[i + 1]]` holds instruction `i`'s.
        fill(&mut self.pre_at, ni + 2, 0);
        for q in 0..self.pre.len() {
            self.pre_at[(self.pre[q] >> 32) as usize + 2] += 1;
        }
        for x in 0..ni {
            self.pre_at[x + 2] += self.pre_at[x + 1];
        }
        fill(&mut self.pre_list, self.pre.len(), 0);
        for q in 0..self.pre.len() {
            let at = (self.pre[q] >> 32) as usize;
            self.pre_list[self.pre_at[at + 1] as usize] = self.pre[q] as u32;
            self.pre_at[at + 1] += 1;
        }
        // New numbers in emission order: per head block its parameters that stay, then its chain's
        // instructions.
        fill(&mut self.newidx, ni, NONE);
        fill(&mut self.pmap, npar, NONE);
        self.params.truncate(0);
        let mut n: u32 = 0;
        for k in 0..nb {
            if self.bmap[k] == NONE || self.done[k] {
                continue;
            }
            let bk = b.blocks[k];
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                if self.live[ni + q as usize] {
                    self.pmap[q as usize] = self.params.len() as u32;
                    self.params.push(b.params[q as usize]);
                }
            }
            if k == 0 {
                for q in 0..self.extra.len() {
                    if self.live[self.extra[q] as usize] {
                        self.newidx[self.extra[q] as usize] = n;
                        n += 1;
                    }
                }
            }
            let mut cur = k as u32;
            // Each step takes one block of the chain.
            while cur != NONE {
                let ck = b.blocks[cur as usize];
                for i in ck.start..ck.start + ck.len - 1 {
                    for q in self.pre_at[i as usize]..self.pre_at[i as usize + 1] {
                        let x = self.pre_list[q as usize];
                        if self.live[x as usize] {
                            self.newidx[x as usize] = n;
                            n += 1;
                        }
                    }
                    if self.live[i as usize] && !self.moved[i as usize] {
                        self.newidx[i as usize] = n;
                        n += 1;
                    }
                }
                for q in self.work[cur as usize]..self.work[cur as usize + 1] {
                    self.newidx[self.into[q as usize] as usize] = n;
                    n += 1;
                }
                if self.nxt[cur as usize] == NONE {
                    self.newidx[(ck.start + ck.len - 1) as usize] = n;
                    n += 1;
                }
                cur = self.nxt[cur as usize];
            }
        }
        self.insts.truncate(0);
        self.locs.truncate(0);
        self.inls.truncate(0);
        self.blocks.truncate(0);
        fill(&mut self.done_pool, b.pool.len(), false);
        let mut np: u32 = 0;
        for k in 0..nb {
            if self.bmap[k] == NONE || self.done[k] {
                continue;
            }
            let bk = b.blocks[k];
            let start = self.insts.len() as u32;
            let ps = np;
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                if self.live[ni + q as usize] {
                    np += 1;
                }
            }
            if k == 0 {
                for q in 0..self.extra.len() {
                    if self.live[self.extra[q] as usize] {
                        self.emit(b, self.extra[q]);
                    }
                }
            }
            let mut cur = k as u32;
            let mut flags = bk.flags;
            // Each step takes one block of the chain.
            while cur != NONE {
                let ck = b.blocks[cur as usize];
                flags &= ck.flags;
                for i in ck.start..ck.start + ck.len - 1 {
                    for q in self.pre_at[i as usize]..self.pre_at[i as usize + 1] {
                        let x = self.pre_list[q as usize];
                        if self.live[x as usize] {
                            self.emit(b, x);
                        }
                    }
                    if self.live[i as usize] && !self.moved[i as usize] {
                        self.emit(b, i);
                    }
                }
                for q in self.work[cur as usize]..self.work[cur as usize + 1] {
                    self.emit(b, self.into[q as usize]);
                }
                if self.nxt[cur as usize] == NONE {
                    self.emit(b, ck.start + ck.len - 1);
                }
                cur = self.nxt[cur as usize];
            }
            self.blocks.push(
                Block {
                    start: start,
                    len: self.insts.len() as u32 - start,
                    param_start: ps,
                    param_len: (np - ps) as u16,
                    flags: flags,
                },
            );
        }
        // A scope's root: its replacement, renumbered; one no longer live goes.
        let mut ns: usize = 0;
        for x in 0..b.scopes.len() {
            let sc = b.scopes[x];
            let v = self.val(sc.root);
            let live = v != VNONE && (v & VFLAG) == 0 && if (v & VPARAM) != 0 {
                self.live[ni + (v & ~VPARAM) as usize]
            } else {
                self.live[v as usize]
            };
            if live {
                b.scopes[ns] = Scope { site: sc.site, group: sc.group, root: self.renum(v) };
                ns += 1;
            }
        }
        b.scopes.truncate(ns);
        self.insts = replace(&mut b.insts, replace(&mut self.insts, Vector::<Inst>::new()));
        self.locs = replace(&mut b.locs, replace(&mut self.locs, Vector::<u32>::new()));
        if b.inl.len() != 0 {
            self.inls = replace(&mut b.inl, replace(&mut self.inls, Vector::<u32>::new()));
        }
        self.blocks = replace(&mut b.blocks, replace(&mut self.blocks, Vector::<Block>::new()));
        self.params = replace(&mut b.params, replace(&mut self.params, Vector::<u8>::new()));
        self.drop_slots(b);
    }

    // Drop the slots no emitted instruction takes the address of (promoted, merged or dead ones; `sused`),
    // and renumber the others in order.
    fn drop_slots(self: &mut Self, b: &mut Body) {
        let mut n: u32 = 0;
        for s in 0..b.slots.len() {
            if self.sused[s] != NONE {
                self.sused[s] = n;
                b.slots[n as usize] = b.slots[s];
                n += 1;
            }
        }
        if n as usize == b.slots.len() {
            return;
        }
        b.slots.truncate(n as usize);
        for i in 0..b.insts.len() {
            if b.insts[i].op == O_SLOTADDR {
                let t = b.insts[i].a;
                b.insts.index_mut(i).a = self.sused[t as usize];
            }
        }
    }

    // `sread`: per slot, whether a reached instruction reads it or takes its address further than a store
    // or a fill into it. The instructions the walk made sit past every block (`hoisted`, and `pre`
    // before an instruction): a diamond's select may take a slot's address on to a call, a copy's load
    // reads its source.
    fn slot_reads(self: &mut Self, b: &Body) {
        fill(&mut self.sread, b.slots.len(), false);
        for k in 0..b.blocks.len() {
            if self.bmap[k] == NONE {
                continue;
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                self.slot_reads_of(b, i);
            }
        }
        for q in 0..self.hoisted.len() {
            if self.bmap[(self.hoisted[q] >> 32) as usize] != NONE {
                self.slot_reads_of(b, self.hoisted[q] as u32);
            }
        }
        for q in 0..self.pre.len() {
            let v = self.pre[q] as u32;
            if self.bmap[self.blk_of[v as usize] as usize] != NONE {
                self.slot_reads_of(b, v);
            }
        }
    }

    // `slot_reads` of instruction `i`, unless the walk replaced it.
    fn slot_reads_of(self: &mut Self, b: &Body, i: u32) {
        let t = b.insts[i as usize];
        if self.repl[i as usize] != VNONE {
            return;
        }
        lv::uses(b, t, &mut self.uses);
        b.succ_edges(t, &mut self.edges);
        for e in 0..self.edges.len() {
            for q in 0..b.edge_nargs(self.edges[e]) {
                self.uses.push(b.edge_arg(self.edges[e], q));
            }
        }
        for u in 0..self.uses.len() {
            let v = self.uses[u];
            if (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_SLOTADDR {
                continue;
            }
            let into = (t.op == O_STORE || t.op == O_MEMSET || t.op == O_MEMCPY) && t.a == v && t.b != v && (t.op == O_STORE || t.c != v);
            if !into {
                self.sread[b.insts[v as usize].a as usize] = true;
            }
        }
    }

    // Whether `t` of `b` stores, fills or copies into a slot nothing reads (`sread`), not volatile.
    const fn dead_store(self: &Self, b: &Body, t: Inst) bool {
        if t.op != O_STORE && t.op != O_MEMSET && t.op != O_MEMCPY || (t.op == O_STORE || t.op == O_MEMCPY) && (t.aux & MEM_VOLATILE) != 0 || (t.a & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let a = b.insts[t.a as usize];
        return a.op == O_SLOTADDR && !self.sread[a.a as usize];
    }

    // `bmap`: 0 for each block the entry reaches through the rewritten terminators, else NONE.
    fn reach(self: &mut Self, b: &Body) {
        fill(&mut self.bmap, b.blocks.len(), NONE);
        self.bmap[0] = 0;
        self.work.truncate(0);
        self.work.push(0);
        // Each block enters the walk once.
        while self.work.len() != 0 {
            let k = self.work.pop().unwrap();
            b.succ_edges(term(b, k), &mut self.edges);
            for e in 0..self.edges.len() {
                let s = b.edge_target(self.edges[e]);
                if self.bmap[s as usize] == NONE {
                    self.bmap[s as usize] = 0;
                    self.work.push(s);
                }
            }
        }
    }

    // Instruction or parameter `x` (an instruction index, or the instruction count plus a parameter
    // index) is live.
    fn mark(self: &mut Self, x: u32) {
        if !self.live[x as usize] {
            self.live[x as usize] = true;
            self.work.push(x);
        }
    }

    const fn renum(self: &Self, v: Value) Value {
        if v == VNONE {
            return v;
        }
        if (v & VPARAM) != 0 {
            return VPARAM | self.pmap[(v & ~VPARAM) as usize];
        }
        return self.newidx[(v & ~VFLAG) as usize] | v & VFLAG;
    }

    fn emit(self: &mut Self, b: &mut Body, i: u32) {
        let mut t = b.insts[i as usize];
        let f = op_info(t.op).form;
        if lv::operand_a(f) {
            t.a = self.renum(t.a);
        }
        if lv::operand_b(f) {
            t.b = self.renum(t.b);
        }
        if lv::operand_c(f) {
            t.c = self.renum(t.c);
        }
        if f == F_CALL || f == F_CALLIND {
            for q in 0..t.aux as u32 {
                self.renum_pool(b, t.c + q);
            }
        } else if f == F_VOP || f == F_ASM {
            for q in 0..t.b {
                self.renum_pool(b, t.a + q);
            }
        }
        // Each edge: its target's number, and the arguments of the parameters that stay.
        b.succ_edges(t, &mut self.edges);
        for e in 0..self.edges.len() {
            let x = self.edges[e];
            if self.done_pool[x as usize] {
                continue;
            }
            self.done_pool[x as usize] = true;
            let tk = b.pool[x as usize];
            let tb = b.blocks[tk as usize];
            let mut kept: u32 = 0;
            for q in 0..b.pool[x as usize + 1] {
                if self.live[b.insts.len() + (tb.param_start + q) as usize] {
                    b.pool[(x + 2 + kept) as usize] = self.renum(b.pool[(x + 2 + q) as usize]);
                    kept += 1;
                }
            }
            b.pool[x as usize] = self.bmap[tk as usize];
            b.pool[x as usize + 1] = kept;
        }
        if t.op == O_SLOTADDR {
            self.sused[t.a as usize] = 0;
        }
        self.insts.push(t);
        self.locs.push(b.locs[i as usize]);
        if b.inl.len() != 0 {
            self.inls.push(b.inl[i as usize]);
        }
    }

    const fn renum_pool(self: &mut Self, b: &mut Body, at: u32) {
        if !self.done_pool[at as usize] {
            self.done_pool[at as usize] = true;
            b.pool[at as usize] = self.renum(b.pool[at as usize]);
        }
    }
}

/// The optimization of a package's bodies as a job graph: `new` takes the bodies, `job` optimizes one,
/// `finish` gives them back. Callees go first: each body inlines the callees that fit the inline
/// budget (`lir::inline`), goes through `Opt::run`, then `Opt::loop_opts`. A body's level is one more
/// than its callees' that may inline (0 without any; a call back into a body the walk is inside does not
/// count), and a body inlines only callees of a lower level, so each body waits for its direct callees of
/// a lower level (`edges`) and for nothing else: the result does not depend on the schedule. A body of a
/// unit `sealed` marks (by unit) inlines into bodies of its unit only.
pub(package) struct Run {
    /// One edge per callee a body waits for: `callee << 32 | caller`, each pair once.
    pub(package) edges: Vector<u64>,
    /// The bodies by level: a serial order every edge runs forward in.
    pub(package) order: Vector<u32>,
    pk: *const Package,
    bodies: Vector<Body>,
    // The first held body (`Package.held`), the body count without any.
    held: u32,
    // Per body, its direct calls before optimization, as bodies in instruction order:
    // `calls[call_at[k]..call_at[k + 1]]`.
    call_at: Vector<u32>,
    calls: Vector<u32>,
    // Per body, the parameters whose memory a call of it may write (`effects`).
    wargs: Vector<u64>,
    shape: Vector<bool>,
    unit: Vector<u32>,
    bunit: Vector<u32>, // per body, its function's `Sym.unit` (NONE: none)
    level: Vector<u32>,
    // Per body, whether a caller may inline it: written by the body's job, read by its callers' jobs.
    ok: Vector<bool>,
    // Per body whose loop transforms or packing made vectors, its final form: `bodies` holds the form
    // before them, which callers inline (`job`), until `finish` swaps the two (`inlined`).
    finals: Vector<Option<Body>>,
    inline: bool,
    cf: Config,
    // `SC_LIR_PRINT`: each optimized body whose function's name holds it prints to stderr (a debugging aid).
    print: String,
    // `SC_VEC_REPORT=1`: each loop the vectorizer left prints its location and why (a debugging aid).
    report: bool,
    // Scratch a job takes and gives back: it grows once per worker, not once per body.
    free: psync::Mutex<Vector<Box<Scratch>>>,
}

struct Scratch {
    pub(package) il: il::Inliner,
    pub(package) o: Opt,
}

extend Run {
    /// The job graph of `pk`'s bodies under `cf`; `pk` keeps no body until `finish`.
    pub(package) fn new(pk: &mut Package, sealed: &Vector<bool>, cf: Config) Run {
        direct_calls(pk);
        let bodies = replace(&mut pk.bodies, Vector::<Body>::new());
        let n = bodies.len();
        let held = if pk.held.body == NONE {
            n as u32
        } else {
            pk.held.body
        };
        let mut cs = Calls {
            at: Vector::<u32>::with_capacity(n + 1),
            callee: Vector::<u32>::new(),
            live: Vector::<bool>::new(),
            arg_at: Vector::<u32>::new(),
            arg: Vector::<u32>::new(),
            bits: Vector::<u64>::new(),
        };
        calls_of(pk, &bodies, held, &mut cs);
        let mut wargs = Vector::<u64>::new();
        let mut esc = Vector::<u64>::new();
        let fx = effects(pk, &bodies, &cs, &mut wargs, &mut esc);
        for s in 0..pk.syms.len() {
            let d = pk.syms[s].def;
            if pk.syms[s].kind == SK_FUNC && d != NONE {
                pk.syms.index_mut(s).fx = fx[d as usize];
                pk.syms.index_mut(s).esc = esc[d as usize];
            }
        }
        let p: &Package = pk;
        let pkp = p as *const Package;
        let hd = &p.held;
        let call_at = replace(&mut cs.at, Vector::<u32>::new());
        let calls = replace(&mut cs.callee, Vector::<u32>::new());
        let mut shape = Vector::<bool>::with_capacity(n);
        shape.resize_default(n);
        let mut ok = Vector::<bool>::with_capacity(n);
        ok.resize_default(n);
        let mut unit = Vector::<u32>::with_capacity(n);
        let mut bunit = Vector::<u32>::with_capacity(n);
        for _ in 0..n {
            unit.push(NONE);
            bunit.push(NONE);
        }
        for s in 0..p.syms.len() {
            let sy = p.syms[s];
            if sy.kind == SK_FUNC && sy.def != NONE {
                bunit[sy.def as usize] = sy.unit;
                if sy.def < held {
                    shape[sy.def as usize] = il::shape_ok(p, s as u32, &bodies[sy.def as usize]);
                }
                if sy.unit < sealed.len() as u32 && sealed[sy.unit as usize] {
                    unit[sy.def as usize] = sy.unit;
                }
            }
        }
        // A held body's facts are the ones its unit's build found.
        for k in held as usize..n {
            let f = hd.flags[k - held as usize];
            shape[k] = (f & HELD_SHAPE) != 0;
            ok[k] = (f & HELD_OK) != 0;
        }
        let mut level = Vector::<u32>::new();
        levels(p, n, &call_at, &calls, &shape, &mut level);
        let mut top: u32 = 0;
        for i in 0..n {
            top = top.max(level[i]);
        }
        // The bodies by level: a counting sort, stable by index.
        let mut at = Vector::<u32>::new();
        at.resize_default(top as usize + 2);
        for i in 0..n {
            at[level[i] as usize + 1] += 1;
        }
        for l in 0..top as usize + 1 {
            at[l + 1] += at[l];
        }
        let mut order = Vector::<u32>::new();
        order.resize_default(n);
        for i in 0..n {
            order[at[level[i] as usize] as usize] = i as u32;
            at[level[i] as usize] += 1;
        }
        // A caller waits for each distinct direct callee of a lower level (`seen`: the last caller that
        // listed it).
        let mut edges = Vector::<u64>::new();
        let mut seen = Vector::<u32>::new();
        for _ in 0..n {
            seen.push(NONE);
        }
        for k in 0..n {
            for q in call_at[k]..call_at[k + 1] {
                let c = calls[q as usize];
                if level[c as usize] < level[k] && seen[c as usize] != k as u32 {
                    seen[c as usize] = k as u32;
                    edges.push(c as u64 << 32 | k as u64);
                }
            }
        }
        let mut finals = Vector::<Option<Body>>::with_capacity(n);
        for _ in 0..n {
            finals.push(Option::<Body>::None);
        }
        return Run {
            edges: edges,
            order: order,
            pk: pkp,
            bodies: bodies,
            finals: finals,
            held: held,
            call_at: call_at,
            calls: calls,
            wargs: wargs,
            shape: shape,
            unit: unit,
            bunit: bunit,
            level: level,
            ok: ok,
            // SC_LIR_INLINE=0 inlines nothing (a debugging aid).
            inline: !stdlib::env_is("SC_LIR_INLINE", "0"),
            cf: cf,
            print: stdlib::get_env("SC_LIR_PRINT").unwrap_or(String::new()),
            report: stdlib::env_is("SC_VEC_REPORT", "1"),
            free: psync::Mutex::<Vector<Box<Scratch>>>::new(Vector::<Box<Scratch>>::new()),
        };
    }

    /// Optimize body `j`, once every body `edges` makes it wait for is done. Jobs of one `Run` run in
    /// parallel: each writes its own body and `ok` entry, and reads its callees' ones.
    pub(package) fn job(self: &Self, j: u32) {
        let r = self;
        if j >= r.held {
            return;
        }
        let p = unsafe &*r.pk;
        let base = r.bodies.as_ptr() as *mut Body;
        let mut sc = r.take();
        let b = unsafe &mut *(base + j as usize);
        sc.o.forget();
        sc.o.pslots = true;
        sc.o.unit = r.bunit[j as usize];
        // The inliner reads the rare blocks, the loop transforms and the code generators too: marked before
        // the inlining (a copy takes its call's marks) and once the transforms made their blocks.
        sc.o.estimate(p, b);
        let inlined = sc.il.run(p, base, &r.ok, &r.level, &r.unit, j, b);
        // The switches as compares and branches, before the first walk, which simplifies them (a test that
        // returns a value on either side returns a select).
        let lowered = p.switch_tree && sws::lower(b, p.ptr_bytes);
        if inlined || lowered {
            sc.o.forget();
        }
        let _ = sc.o.run(p, b, inlined || lowered);
        if sc.o.tail_self(p, b, j) {
            let _ = sc.o.run(p, b, true);
        }
        if sc.o.split_pairs(p, b) {
            let _ = sc.o.run(p, b, true);
        }
        if sc.o.split_wide(p, b) {
            let _ = sc.o.run(p, b, true);
        }
        // A body callers may inline keeps its form before the loop transforms and the packing: when those
        // make vectors, callers inline that form, as LLVM vectorizes after inlining. A caller packs its
        // copy once the copy's slots are values (`lir::promote`), which a vector access of a slot prevents.
        // The copy, only of a body small enough to inline: a larger one that ends with vectors inlines in
        // neither form (`fits`).
        let bu = r.cf.loops;
        let snap = r.inline && r.shape[j as usize] && bu.vector != 0 && !packed(b);
        let pre = if snap && il::small(b, r.cf.inline) {
            Option::<Body>::Some(b.compact())
        } else {
            Option::<Body>::None
        };
        // A loop a round copied is innermost again for the next one.
        sc.o.unr.wide = false;
        let mut round: u32 = 0;
        while round < LOOP_ROUNDS && (bu.peel != 0 || bu.partial != 0 || bu.version != 0 || bu.unswitch != 0 || bu.vector != 0 || bu.fin != 0) && sc.o.loop_opts(
            p,
            b,
            bu,
        ) {
            round += 1;
        }
        // Then rotation, which moves the exit tests the transforms above read; the loads each iteration
        // starts with leave the rotated loops, so their sums have final values too.
        if bu.rotate != 0 && sc.o.rotate(p, b, bu.rotate) && bu.fin != 0 {
            let _ = sc.o.loop_opts(
                p,
                b,
                lu::Budgets { peel: 0, partial: 0, version: 0, unswitch: 0, rotate: 0, vector: 0, fin: bu.fin },
            );
        }
        // Vectors of mixed lane widths two registers wide, by parts.
        if sc.o.unr.wide && sc.o.split_wide(p, b) {
            let _ = sc.o.run(p, b, true);
        }
        if r.report && sc.o.unr.rejected.len() != 0 {
            r.vec_report(p, &sc.o.unr.rejected);
        }
        // Then the packing of straight-line values into vectors, on the loops' final shape.
        if bu.vector != 0 {
            let _ = sc.o.slp(p, b);
        }
        // Once the walks forwarded the loads of the allocations' blocks; the run folds their null tests.
        let placed = sc.o.promote_places(p, b);
        // Where every vector operation is in registers (arm64): x86-64 without SSE4.1 has no lane maximum.
        let minmax = p.vector != 0 && p.vops == VOPS_ALL && vec_minmaxes(b);
        if sc.o.dead_allocs(p, b) || placed || minmax {
            let _ = sc.o.run(p, b, true);
        }
        let _ = sc.o.split_exits(p, b);
        if ret_edges(b) {
            sc.o.forget();
        }
        sc.o.estimate(p, b);
        if r.print.len() != 0 {
            r.print_body(p, j, b);
        }
        // Its callers copy its pool when they inline it, and the code generators read it: the passes'
        // dead records go.
        b.compact_pool(&mut sc.o.cps);
        let mut fits = r.inline && r.shape[j as usize];
        if snap && packed(b) {
            if pre.is_some() {
                let fin = replace(b, pre.unwrap());
                b.compact_pool(&mut sc.o.cps);
                unsafe *(r.finals.as_ptr() as *mut Option<Body> + j as usize) = Some(fin);
            } else {
                fits = false;
            }
        }
        unsafe *(r.ok.as_ptr() as *mut bool + j as usize) = fits && il::small(b, r.cf.inline);
        r.give(sc);
    }

    // `SC_VEC_REPORT`: each loop the vectorizer left (`rs`: its header's location and the reason), as
    // `file:line:col: not vectorized: reason` on stderr.
    fn vec_report(self: &Self, p: &Package, rs: &Vector<(Loc, String)>) {
        for k in 0..rs.len() {
            let l = rs[k].0;
            let file = if l.file < p.files.len() as u32 {
                p.spell(p.files[l.file as usize])
            } else {
                "?"
            };
            eprint("{}:{}:{}: not vectorized: {}\n", file, l.line, l.col, rs[k].1.as_str());
        }
    }

    // Body `j`'s text on stderr when its function's name holds `print`.
    fn print_body(self: &Self, p: &Package, j: u32, b: &Body) {
        for s in 0..p.syms.len() {
            let name = p.spell(p.syms[s].name);
            if p.syms[s].kind == SK_FUNC && p.syms[s].def == j && name.contains(&self.print) {
                let mut out = String::new();
                lp::print_body(p, name, b, &mut out);
                eprint("; body {}\n{}", j, out.as_str());
            }
        }
    }

    // A scratch from the free list, or a new one. The lock is held for this call only, never while a
    // body is optimized.
    fn take(self: &Self) Box<Scratch> {
        let mut g = self.free.lock();
        switch g.get_mut().pop() {
            Some(x) => {
                return x;
            },
            None => {},
        }
        return Box::new(Scratch { il: il::Inliner::new(), o: Opt::new() });
    }

    fn give(self: &Self, sc: Box<Scratch>) {
        let mut g = self.free.lock();
        g.get_mut().push(sc);
    }

    /// Give the bodies back to `pk`, the package `new` took them from, in their final forms, their constant
    /// slots in read-only data (`const_slots`).
    pub(package) fn finish(self: &mut Self, pk: &mut Package) {
        for j in 0..self.finals.len() {
            let f = replace(&mut self.finals[j], Option::<Body>::None);
            if f.is_some() {
                let pre = replace(&mut self.bodies[j], f.unwrap());
                self.finals[j] = Some(pre);
            }
        }
        pk.bodies = replace(&mut self.bodies, Vector::<Body>::new());
        const_slots(pk);
        // The calls through a method a constant table holds (`fold_ptr`): the jobs, which ran at once, did
        // not read another body's signature.
        direct_calls(pk);
    }

    /// After `finish`, the form of body `k` its callers inlined: the one before the loop transforms and
    /// the packing when those made vectors, else `pk`'s.
    pub(package) fn inlined<'a>(self: &'a Self, pk: &'a Package, k: u32) &'a Body {
        if let Some(b) = self.finals.at(k as usize) {
            return b;
        }
        return &pk.bodies[k as usize];
    }

    /// Whether body `k` passed the inliner's shape test, and whether its callers may inline it (after its
    /// job).
    pub(package) const fn shape_of(self: &Self, k: u32) bool {
        return self.shape[k as usize];
    }

    pub(package) const fn inlinable(self: &Self, k: u32) bool {
        return self.ok[k as usize];
    }

    /// The parameters whose memory a call of body `k` may write (`FX_ARG`), a bit each.
    pub(package) const fn wargs_of(self: &Self, k: u32) u64 {
        return self.wargs[k as usize];
    }

    /// The direct calls of body `k` before optimization, as bodies in instruction order.
    pub(package) const fn calls_of(self: &Self, k: u32) Slice<u32> {
        return self.calls[self.call_at[k as usize] as usize..self.call_at[k as usize + 1] as usize];
    }
}

// Whether `b` holds a vector value or stores one.
fn packed(b: &Body) bool {
    for i in 0..b.insts.len() {
        let t = b.insts[i];
        if is_vec(t.ty) || t.op == O_STORE && is_vec(b.type_of(t.b)) {
            return true;
        }
    }
    return false;
}

/// `Run::job` for `driver::sched::run_jobs`: `ctx` is the `Run`.
pub(package) fn job(ctx: *mut void, j: u32) {
    (unsafe &*(ctx as *const Run)).job(j);
}

/// `Run::new`, every job in `order` on this thread, then `finish`.
pub(package) fn optimize(pk: &mut Package, sealed: &Vector<bool>, cf: Config) {
    let mut r = Run::new(pk, sealed, cf);
    for k in 0..r.order.len() {
        r.job(r.order[k]);
    }
    r.finish(pk);
}

// At most CONST_SLOT_BYTES bytes of a slot go to read-only data (`const_slots`).
const CONST_SLOT_BYTES: u32 = 4096;
// `const_slot`'s offset of an address the slot gives at a variable place, and of a value it does not give.
const OFF_VAR: u64 = 0xFFFFFFFFFFFFFFFE;
const OFF_NONE: u64 = 0xFFFFFFFFFFFFFFFF;

// Place each slot of the optimized bodies that only constants of disjoint bytes are stored into, and whose
// address only those stores and loads read (through offsets and indices), in read-only data of its own:
// the code loads from it rather than store the constants at each call (a constant local array; LLVM
// promotes such an alloca to a constant global). A byte no store writes is 0, which a read of it before
// any store, undefined, may give. The stores become unused constants.
fn const_slots(pk: &mut Package) {
    let held = if pk.held.body == NONE {
        pk.bodies.len()
    } else {
        pk.held.body as usize
    };
    let mut owner = Vector::<u32>::with_capacity(pk.bodies.len());
    for _ in 0..pk.bodies.len() {
        owner.push(NONE);
    }
    for s in 0..pk.syms.len() {
        let y = pk.syms[s];
        if y.kind == SK_FUNC && y.def != NONE {
            owner[y.def as usize] = s as u32;
        }
    }
    let mut cs = ConstSlot {
        slot: Vector::<u32>::new(),
        off: Vector::<u64>::new(),
        bad: Vector::<bool>::new(),
        has: Vector::<bool>::new(),
        adds: Vector::<u32>::new(),
        us: Vector::<Value>::new(),
        es: Vector::<u32>::new(),
        stores: Vector::<u32>::new(),
        bytes: Vector::<u8>::new(),
        set: Vector::<bool>::new(),
    };
    for k in 0..held {
        if owner[k] == NONE || pk.bodies[k].slots.len() == 0 || !cs.scan(&pk.bodies[k]) {
            continue;
        }
        for s in 0..pk.bodies[k].slots.len() {
            if !cs.fill_bytes(&pk.bodies[k], s as u32, pk.ptr_bytes) {
                continue;
            }
            let o = pk.syms[owner[k] as usize];
            let name = format("{}.const{}", pk.spell(o.name), s);
            let d = pk.add_symbol(&name, SK_DATA, SL_LOCAL);
            if d == NONE {
                continue;
            }
            pk.syms.index_mut(d as usize).unit = o.unit;
            pk.syms.index_mut(d as usize).own = o.own;
            let sl = pk.bodies[k].slots[s];
            let none: []Reloc = [];
            if !pk.add_data(d, sl.size, sl.align_log2, true, &cs.bytes, none) {
                continue;
            }
            let b = pk.bodies.index_mut(k);
            let r = b.ref_sym(d);
            for i in 0..b.insts.len() {
                let t = b.insts[i];
                if t.op == O_SLOTADDR && t.a == s as u32 {
                    b.insts[i] = Inst { op: O_SYMADDR, ty: T_PTR, aux: 0, a: r, b: 0, c: VNONE };
                } else if t.op == O_STORE && cs.slot[i] == s as u32 {
                    b.insts[i] = iconst(T_I8, 0);
                }
            }
            b.slots.index_mut(s).size = 0;
            b.slots.index_mut(s).align_log2 = 0;
        }
    }
}

// `const_slots`'s scratch, per body: per instruction the slot an address it gives is into (`slot`, NONE for
// none; a store's, its address's) and the offset into it (`off`, OFF_VAR for a variable one), per slot
// whether something but stores of constants and loads reads its address (`bad`) and whether a constant
// store writes it (`has`); the slot addresses and offsets (`adds`), operands, edges, the constant stores;
// per slot at hand its bytes and which are stored.
struct ConstSlot {
    slot: Vector<u32>,
    off: Vector<u64>,
    bad: Vector<bool>,
    has: Vector<bool>,
    adds: Vector<u32>,
    us: Vector<Value>,
    es: Vector<u32>,
    stores: Vector<u32>,
    bytes: Vector<u8>,
    set: Vector<bool>,
}

extend ConstSlot {
    // The slots of `b` and the addresses they give, each instruction read a few times: whether a slot is
    // stored into with constants and read by loads alone (not `bad`).
    fn scan(self: &mut Self, b: &Body) bool {
        let n = b.insts.len();
        // A slot read at constant offsets alone became values (`lir::promote`): a table has an index. Most
        // bodies have no constant store into a slot nor an indexed slot address: one look at each
        // instruction tells; the slots' addresses and the offsets kept for the passes below.
        let mut cstore = false;
        let mut indexed = false;
        self.adds.truncate(0);
        for i in 0..n {
            let t = b.insts[i];
            if t.op == O_STORE {
                cstore = cstore || (t.b & (VPARAM | VFLAG)) == 0 && (b.insts[t.b as usize].op == O_ICONST || b.insts[t.b as usize].op == O_FCONST) && (t.a & (VPARAM | VFLAG)) == 0 && (b.insts[t.a as usize].op == O_SLOTADDR || b.insts[t.a as usize].op == O_PTRADD);
            } else if t.op == O_SLOTADDR || t.op == O_PTRADD {
                indexed = indexed || t.op == O_PTRADD && t.b != VNONE && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_SLOTADDR;
                self.adds.push(i as u32);
            }
        }
        if !cstore || !indexed {
            return false;
        }
        fill(&mut self.slot, n, NONE);
        fill(&mut self.off, n, 0);
        fill(&mut self.bad, b.slots.len(), false);
        for q in 0..self.adds.len() {
            let i = self.adds[q] as usize;
            let t = b.insts[i];
            if t.op == O_SLOTADDR && t.a as usize < b.slots.len() {
                let sz = b.slots[t.a as usize].size;
                if sz == 0 || sz > CONST_SLOT_BYTES {
                    self.bad[t.a as usize] = true;
                } else {
                    self.slot[i] = t.a;
                }
            }
        }
        // The addresses offsets and indices give, a chain at most CONST_PASSES deep (a use may come before
        // its definition in the instruction order); a deeper one makes the body's slots stay.
        let mut changed = true;
        let mut pass: u32 = 0;
        while changed {
            if pass == CONST_PASSES {
                return false;
            }
            pass += 1;
            changed = false;
            for q in 0..self.adds.len() {
                let i = self.adds[q] as usize;
                let t = b.insts[i];
                if t.op != O_PTRADD || self.slot[i] != NONE || !self.gives(t.a) {
                    continue;
                }
                let base = self.off[t.a as usize];
                self.slot[i] = self.slot[t.a as usize];
                self.off[i] = if t.b != VNONE || base == OFF_VAR {
                    OFF_VAR
                } else {
                    base.wrapping_add(((t.c as i32) as i64) as u64)
                };
                changed = true;
            }
        }
        self.stores.truncate(0);
        for i in 0..n {
            let t = b.insts[i];
            if t.op >= O_JMP && t.op <= O_SWITCH {
                b.succ_edges(t, &mut self.es);
                for q in 0..self.es.len() {
                    for x in 0..b.edge_nargs(self.es[q]) {
                        let v = b.edge_arg(self.es[q], x);
                        if self.gives(v) {
                            self.bad[self.slot[v as usize] as usize] = true;
                        }
                    }
                }
            }
            if t.op == O_SLOTADDR {
                continue;
            }
            lv::uses(b, t, &mut self.us);
            // A load's or an offset's address, a store's address (of a constant at a known offset, not
            // volatile): kept; any other read of a slot's address makes the slot stay.
            let mut keep = VNONE;
            if t.op == O_LOAD && (t.aux & MEM_VOLATILE) == 0 || t.op == O_PTRADD {
                keep = t.a;
            } else if t.op == O_STORE && (t.aux & MEM_VOLATILE) == 0 && self.gives(t.a) && self.off[t.a as usize] != OFF_VAR && (t.b & (VPARAM | VFLAG)) == 0 && (b.insts[t.b as usize].op == O_ICONST || b.insts[t.b as usize].op == O_FCONST) {
                keep = t.a;
                self.slot[i] = self.slot[t.a as usize];
                self.off[i] = self.off[t.a as usize];
                self.stores.push(i as u32);
            }
            for q in 0..self.us.len() {
                let v = self.us[q];
                if self.gives(v) && (v != keep || q != 0) {
                    self.bad[self.slot[v as usize] as usize] = true;
                }
            }
            if t.op == O_STORE && keep == VNONE && self.gives(t.a) {
                self.bad[self.slot[t.a as usize] as usize] = true;
            }
        }
        // A slot without a constant store stays.
        fill(&mut self.has, b.slots.len(), false);
        for q in 0..self.stores.len() {
            self.has[self.slot[self.stores[q] as usize] as usize] = true;
        }
        let mut any = false;
        for s in 0..b.slots.len() {
            any = any || self.has[s] && !self.bad[s];
        }
        return any;
    }

    // Slot `s`'s bytes from its constant stores (`scan`), when it is not `bad`, has one, and none overlaps
    // another or passes its end (constants of `ptr`-byte pointers aside). Whether it goes to data.
    fn fill_bytes(self: &mut Self, b: &Body, s: u32, ptr: u32) bool {
        if self.bad[s as usize] || !self.has[s as usize] {
            return false;
        }
        let size = b.slots[s as usize].size;
        self.bytes.truncate(0);
        self.set.truncate(0);
        for _ in 0..size {
            self.bytes.push(0);
            self.set.push(false);
        }
        let mut n: u32 = 0;
        for q in 0..self.stores.len() {
            let i = self.stores[q] as usize;
            let t = b.insts[i];
            if self.slot[i] != s {
                continue;
            }
            let c = b.insts[t.b as usize];
            let ty = c.ty;
            if !(is_int(ty) && ty != T_I128 || ty == T_F32 || ty == T_F64) {
                return false;
            }
            let w = type_bytes(ty, ptr) as u64;
            let at = self.off[i].wrapping_add(((t.c as i32) as i64) as u64);
            if at >= size as u64 || at + w > size as u64 {
                return false;
            }
            let bits = c.b as u64 << 32 | c.a as u64;
            for q in 0..w {
                if self.set[(at + q) as usize] {
                    return false;
                }
                self.set[(at + q) as usize] = true;
                self.bytes[(at + q) as usize] = (bits >> 8 * q) as u8;
            }
            n += 1;
        }
        return n != 0;
    }

    // Whether value `v` is an address a slot gives.
    fn gives(self: &Self, v: Value) bool {
        return (v & (VPARAM | VFLAG)) == 0 && v != VNONE && self.slot[v as usize] != NONE;
    }
}

// The direct calls of the bodies (`Run::new`): per body, its range of `callee` (in instruction order; a
// held body's from its record). Per call, whether `effects` counts it (`live`: one of a body below `held`
// outside a block that ends the program), and its range of `arg` and `bits`: for each of its first 64
// arguments, `q | root << 8` and the parameters the root takes (`root`).
struct Calls {
    pub(package) at: Vector<u32>,
    pub(package) callee: Vector<u32>,
    pub(package) live: Vector<bool>,
    pub(package) arg_at: Vector<u32>,
    pub(package) arg: Vector<u32>,
    pub(package) bits: Vector<u64>,
}

// `Calls` of `bodies`, each body's instructions read once.
fn calls_of(p: &Package, bodies: &Vector<Body>, held: u32, cs: &mut Calls) {
    let hd = &p.held;
    let mut ends = Vector::<bool>::new();
    for k in 0..bodies.len() {
        cs.at.push(cs.callee.len() as u32);
        if k as u32 >= held {
            let h = k - held as usize;
            for q in hd.at[h]..hd.at[h + 1] {
                let sy = p.syms[hd.calls[q as usize] as usize];
                if sy.kind == SK_FUNC && sy.def != NONE {
                    cs.callee.push(sy.def);
                    cs.live.push(false);
                    cs.arg_at.push(cs.arg.len() as u32);
                }
            }
            continue;
        }
        let b = &bodies[k];
        fill(&mut ends, b.insts.len(), false);
        for x in 0..b.blocks.len() {
            let bk = b.blocks[x];
            let end = b.insts[(bk.start + bk.len - 1) as usize].op;
            if end == O_PANIC || end == O_UNREACHABLE {
                for i in bk.start..bk.start + bk.len {
                    ends[i as usize] = true;
                }
            }
        }
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            let c = call_target(p, b, t);
            if c == NONE {
                continue;
            }
            cs.callee.push(c);
            cs.live.push(!ends[i]);
            cs.arg_at.push(cs.arg.len() as u32);
            if ends[i] {
                continue;
            }
            for q in 0..(t.aux as u32).min(64) {
                let mut m: u64 = 0;
                let r = root(b, b.pool[(t.c + q) as usize], &mut m);
                cs.arg.push(q | r as u32 << 8);
                cs.bits.push(m);
            }
        }
    }
    cs.at.push(cs.callee.len() as u32);
    cs.arg_at.push(cs.arg.len() as u32);
}

// Per body of `bodies`, the memory outside its frame a call of it may read or write (`Sym.fx`): its own
// loads, stores, copies and fills of any memory but its slots, any other access or ordering of memory
// (an atomic, a fence, assembly, a system or vector operation, a variadic access, a volatile load), and
// its calls': a body's, as this inference finds it (a fixed point: the flags only grow, at most twice per
// body), both for any other call. A block that ends the program (`panic`, `unreachable`) counts for
// nothing: no code of the caller runs after it. A held body (`Package.held`) keeps the flags and the
// parameters its unit's build found: the others then take the values a build without held bodies gives
// them. Into `wargs`, per body, the parameters whose memory it may write (`FX_ARG`), a bit each; into
// `esc`, those whose pointer it may let escape (`Sym.esc`): its own uses' (`own_escapes`), and a pass to
// a body's parameter that escapes. The calls and their arguments' roots are `cs`'s.
fn effects(p: &Package, bodies: &Vector<Body>, cs: &Calls, wargs: &mut Vector<u64>, esc: &mut Vector<u64>) Vector<u8> {
    let n = bodies.len();
    let held = if p.held.body == NONE {
        n
    } else {
        p.held.body as usize
    };
    let mut fx = Vector::<u8>::with_capacity(n);
    wargs.truncate(0);
    esc.truncate(0);
    // Per body below `held`, its parameters' passes to a body (`own_escapes`): `pass[at[k]..at[k + 1]]`.
    let mut pass = Vector::<u64>::new();
    let mut at = Vector::<u32>::with_capacity(held + 1);
    for k in 0..n {
        if k >= held {
            fx.push(p.held.fx[k - held]);
            wargs.push(p.held.wargs[k - held]);
            esc.push(p.held.esc[k - held]);
            continue;
        }
        let mut w: u64 = 0;
        fx.push(own_effects(p, &bodies[k], &mut w));
        wargs.push(w);
        at.push(pass.len() as u32);
        esc.push(own_escapes(p, &bodies[k], &mut pass));
    }
    at.push(pass.len() as u32);
    // Each round adds one of a body's 3 flags, 64 written or 64 escaping parameters, or ends.
    for _ in 0..131 * n + 1 {
        let mut changed = false;
        for k in 0..held {
            let mut f = fx[k];
            let mut w = wargs[k];
            let mut s = esc[k];
            for x in at[k]..at[k + 1] {
                let e = pass[x as usize];
                if (esc[(e >> 32) as usize] >> (e >> 8 & 0xFF) & 1) != 0 {
                    s |= 1u64 << (e & 0xFF);
                }
            }
            for x in cs.at[k]..cs.at[k + 1] {
                let c = cs.callee[x as usize] as usize;
                let (a0, a1) = (cs.arg_at[x as usize], cs.arg_at[x as usize + 1]);
                if !cs.live[x as usize] {
                    continue;
                }
                f |= fx[c] & ~FX_ARG;
                // A write through an argument: none in this frame, this body's own through its parameters.
                for y in a0..a1 {
                    let q = cs.arg[y as usize] & 0xFF;
                    if (wargs[c] >> q as u64 & 1) == 0 {
                        continue;
                    }
                    let r = (cs.arg[y as usize] >> 8) as u8;
                    if r == ROOT_ARGS {
                        w |= cs.bits[y as usize];
                        f |= FX_ARG;
                    } else if r == ROOT_ANY {
                        f |= FX_WRITE;
                    }
                }
            }
            if f != fx[k] || w != wargs[k] || s != esc[k] {
                fx[k] = f;
                wargs[k] = w;
                esc[k] = s;
                changed = true;
            }
        }
        if !changed {
            return fx;
        }
    }
    assert(false, "opt: the effect inference does not settle");
    return fx;
}

// The flags (`FX_*`) of body `b`'s own instructions (`effects`), and into `w` the parameters whose memory
// they may write: a call of a body counts for none here.
fn own_effects(p: &Package, b: &Body, w: &mut u64) u8 {
    let mut f: u8 = 0;
    for k in 0..b.blocks.len() {
        let bk = b.blocks[k];
        let end = b.insts[(bk.start + bk.len - 1) as usize].op;
        if end == O_PANIC || end == O_UNREACHABLE {
            continue;
        }
        for i in bk.start..bk.start + bk.len {
            let t = b.insts[i as usize];
            if t.op == O_LOAD {
                if (t.aux & MEM_VOLATILE) != 0 {
                    f |= FX_READ | FX_WRITE;
                } else if !in_frame(b, t.a) {
                    f |= FX_READ;
                }
            } else if t.op == O_STORE || t.op == O_MEMSET {
                if (t.aux & MEM_VOLATILE) != 0 && t.op == O_STORE {
                    f |= FX_WRITE;
                } else {
                    f |= write_effect(b, t.a, w);
                }
            } else if t.op == O_MEMCPY {
                f |= write_effect(b, t.a, w);
                if !in_frame(b, t.b) {
                    f |= FX_READ;
                }
            } else if t.op == O_CALL && call_target(p, b, t) != NONE {
                continue;
            } else if writes_memory(t) {
                f |= FX_READ | FX_WRITE;
            }
        }
    }
    return f;
}

// The parameters (the first 64, a bit each) whose pointer body `b`'s own instructions may let escape
// (`effects`): a use of the parameter, or of address arithmetic on it, but as an access's address, the
// base of more arithmetic or a comparison's operand. A pass to a body's parameter goes into `pass`
// instead (`body << 32 | argument << 8 | parameter`): it escapes when that parameter does. A block that
// ends the program counts for nothing.
fn own_escapes(p: &Package, b: &Body, pass: &mut Vector<u64>) u64 {
    let ni = b.insts.len();
    // Per instruction, the parameter its value is address arithmetic on (NONE: none). Each pass sets at
    // least one more or ends: at most `ni + 1`.
    let mut der = Vector::<u32>::with_capacity(ni);
    for _ in 0..ni {
        der.push(NONE);
    }
    for _ in 0..ni + 1 {
        let mut changed = false;
        for i in 0..ni {
            let t = b.insts[i];
            if t.op == O_PTRADD && der[i] == NONE {
                let k = param_of(b, &der, t.a);
                if k != NONE {
                    der[i] = k;
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
    }
    let mut out: u64 = 0;
    let mut uses = Vector::<Value>::new();
    let mut edges = Vector::<u32>::new();
    for k in 0..b.blocks.len() {
        let bk = b.blocks[k];
        let end = b.insts[(bk.start + bk.len - 1) as usize].op;
        if end == O_PANIC || end == O_UNREACHABLE {
            continue;
        }
        for i in bk.start..bk.start + bk.len {
            let t = b.insts[i as usize];
            let c = call_target(p, b, t);
            if c != NONE {
                for q in 0..t.aux as u32 {
                    let x = param_of(b, &der, b.pool[(t.c + q) as usize]);
                    if x == NONE {
                        continue;
                    }
                    if q < 64 {
                        pass.push(c as u64 << 32 | q as u64 << 8 | x as u64);
                    } else {
                        out |= 1u64 << x as u64;
                    }
                }
                continue;
            }
            lv::uses(b, t, &mut uses);
            if is_terminator(t.op) {
                b.succ_edges(t, &mut edges);
                for d in 0..edges.len() {
                    for a in 0..b.edge_nargs(edges[d]) {
                        uses.push(b.edge_arg(edges[d], a));
                    }
                }
            }
            for u in 0..uses.len() {
                let v = uses[u];
                let x = param_of(b, &der, v);
                let kept = t.op == O_LOAD && t.a == v && u == 0 || t.op == O_STORE && t.a == v && t.b != v || t.op == O_MEMCPY && (t.a == v || t.b == v) && t.c != v || t.op == O_MEMSET && t.a == v && t.b != v && t.c != v || t.op == O_PTRADD && t.a == v && t.b != v || t.op == O_ICMP;
                if x != NONE && !kept {
                    out |= 1u64 << x as u64;
                }
            }
        }
    }
    return out;
}

// The parameter (of the first 64) value `v` of `b` is or is address arithmetic on (`der`), NONE for none.
fn param_of(b: &Body, der: &Vector<u32>, v: Value) u32 {
    if v == VNONE || (v & VFLAG) != 0 {
        return NONE;
    }
    if (v & VPARAM) != 0 {
        let e = b.blocks[0];
        let x = v & ~VPARAM;
        return if x >= e.param_start && x - e.param_start < (e.param_len as u32).min(64) {
            x - e.param_start
        } else {
            NONE
        };
    }
    return der[v as usize];
}

// Whether address `v` of `b` is inside one of its slots (`root`).
fn in_frame(b: &Body, v: Value) bool {
    let mut w: u64 = 0;
    return root(b, v, &mut w) == ROOT_FRAME;
}

// The effect (`FX_*`) of a write through address `v` of `b` on memory outside its frame: none in a slot,
// FX_ARG through its parameters (added to `w`, a bit each), else FX_WRITE.
fn write_effect(b: &Body, v: Value, w: &mut u64) u8 {
    let r = root(b, v, w);
    return if r == ROOT_FRAME {
        0u8
    } else if r == ROOT_ARGS {
        FX_ARG
    } else {
        FX_WRITE
    };
}

// `root`: what address arithmetic and selects (at most FRAME_DEPTH steps) derive an address from:
// slots only, slots and the signature's first 64 parameters (added to `w`, a bit each), or anything
// else.
const ROOT_FRAME: u8 = 0;
const ROOT_ARGS: u8 = 1;
const ROOT_ANY: u8 = 2;

fn root(b: &Body, v: Value, w: &mut u64) u8 {
    let mut work = Vector::<Value>::new();
    work.push(v);
    let mut steps: u32 = 0;
    let mut r = ROOT_FRAME;
    let mut m: u64 = 0;
    // Each step takes one value; FRAME_DEPTH bounds them.
    while work.len() != 0 {
        let x = work.pop().unwrap();
        steps += 1;
        if steps > FRAME_DEPTH || (x & VFLAG) != 0 || x == VNONE {
            return ROOT_ANY;
        }
        if (x & VPARAM) != 0 {
            let q = entry_param(b, x);
            if q == NONE || q >= 64 {
                return ROOT_ANY;
            }
            m |= 1u64 << q as u64;
            r = ROOT_ARGS;
            continue;
        }
        let t = b.insts[x as usize];
        if t.op == O_PTRADD {
            work.push(t.a);
        } else if t.op == O_SELECT {
            work.push(t.b);
            work.push(t.c);
        } else if t.op != O_SLOTADDR {
            return ROOT_ANY;
        }
    }
    *w |= m;
    return r;
}

// Per body of the `n` of `p`, its level (`optimize`): an explicit-stack depth-first search over the direct
// calls (`calls[call_at[k]..call_at[k + 1]]`) of the bodies `shape` marks (body << 1 | finished).
fn levels(
    p: &Package,
    n: usize,
    call_at: &Vector<u32>,
    calls: &Vector<u32>,
    shape: &Vector<bool>,
    level: &mut Vector<u32>,
) {
    level.truncate(0);
    level.resize_default(n);
    // 0: not seen, 1: on the stack, 2: finished.
    let mut st = Vector::<u8>::new();
    st.resize_default(n);
    let mut stack = Vector::<u64>::new();
    // The walk enters the bodies in symbol order (name, then unit), then in index order for the bodies
    // no symbol defines: where it enters a call cycle decides the cycle's levels, and the bodies' indices
    // follow the emission's schedule, which depends on the worker count.
    let mut fns = Vector::<u32>::new();
    for k in 0..p.syms.len() {
        if p.syms[k].kind == SK_FUNC && p.syms[k].def != NONE {
            fns.push(k as u32);
        }
    }
    fns.sort_stable_in_place_by(
        |x: &u32, y: &u32| {
            let ny = p.spell(p.syms[(*y) as usize].name);
            let c = p.spell(p.syms[(*x) as usize].name).cmp(&ny);
            return if c != 0 {
                c
            } else {
                (p.syms[(*x) as usize].unit > p.syms[(*y) as usize].unit) as i32 - (p.syms[(*x) as usize].unit < p.syms[(*y) as usize].unit) as i32
            };
        },
    );
    let mut roots = Vector::<u32>::with_capacity(fns.len() + n);
    for k in 0..fns.len() {
        roots.push(p.syms[fns[k] as usize].def);
    }
    for r in 0..n {
        roots.push(r as u32);
    }
    for q in 0..roots.len() {
        let r = roots[q] as usize;
        if st[r] != 0 {
            continue;
        }
        stack.push(r as u64 << 1);
        // Each body is pushed once per call into it and finished once.
        while stack.len() != 0 {
            let x = stack.pop().unwrap();
            let k = (x >> 1) as usize;
            if (x & 1) != 0 {
                let mut lv: u32 = 0;
                for q in call_at[k]..call_at[k + 1] {
                    let c = calls[q as usize];
                    if shape[c as usize] && st[c as usize] == 2 && c as usize != k && level[c as usize] + 1 > lv {
                        lv = level[c as usize] + 1;
                    }
                }
                level[k] = lv;
                st[k] = 2;
                continue;
            }
            if st[k] != 0 {
                continue;
            }
            st[k] = 1;
            stack.push(k as u64 << 1 | 1);
            for q in call_at[k]..call_at[k + 1] {
                let c = calls[q as usize];
                if shape[c as usize] && st[c as usize] == 0 {
                    stack.push(c as u64 << 1);
                }
            }
        }
    }
}

// The body index a direct call `t` of `b` reaches (NONE: not a call, or no body).
const fn call_target(p: &Package, b: &Body, t: Inst) u32 {
    if t.op != O_CALL {
        return NONE;
    }
    let sy = p.syms[b.syms[t.a as usize] as usize];
    return if sy.kind == SK_FUNC && sy.def != NONE {
        sy.def
    } else {
        NONE
    };
}

// Whether `t` has no effect but its value: dropped when nothing uses it.
const fn droppable(t: Inst) bool {
    return pure_op(t.op) || t.op == O_LOAD && (t.aux & MEM_VOLATILE) == 0;
}

// ---- Folding ------------------------------------------------------------------------------------------

// The integer constant value `v` is (up to 64 bits, truncated to its type), if it is one.
const fn const_of(b: &Body, v: Value) Option<u64> {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_ICONST || b.insts[v as usize].ty == T_I128 {
        return None;
    }
    let t = b.insts[v as usize];
    return Some(t.b as u64 << 32 | t.a as u64);
}

// The words of 128-bit constant `v` (low, high), if it is one.
fn wide_of(b: &Body, v: Value) Option<(u64, u64)> {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_WCONST || b.insts[v as usize].ty != T_I128 {
        return None;
    }
    let w = b.insts[v as usize].a as usize;
    return Some((b.words[w], b.words[w + 1]));
}

// Pure 128-bit instruction `i` of `b`, its operands final, as `simplify`: an extension of a constant and
// an operation on constants become constants; an operation with a constant that leaves its other operand
// is that operand.
fn simplify_wide(b: &mut Body, i: u32) Value {
    let t = b.insts[i as usize];
    let mut r: (u64, u64) = (0, 0);
    if t.op == O_ZEXT || t.op == O_SEXT {
        let x = const_of(b, t.a);
        if x.is_none() {
            return VNONE;
        }
        let bits = type_bits(b.type_of(t.a), 8);
        let l = if t.op == O_SEXT {
            le::sign_ext(x.unwrap(), bits) as u64
        } else {
            x.unwrap()
        };
        r = (
            l,
            if t.op == O_SEXT && l >> 63 != 0 {
                ~0u64
            } else {
                0u64
            }
        );
    } else if t.op >= O_ADD && t.op <= O_NOT && t.op != O_SDIV && t.op != O_UDIV && t.op != O_SREM && t.op != O_UREM {
        let x = wide_of(b, t.a);
        let y = if t.op == O_NEG || t.op == O_NOT {
            Option::<(u64, u64)>::Some((0, 0))
        } else {
            wide_of(b, t.b)
        };
        if y.is_some() && x.is_none() {
            let (yl, yh) = y.unwrap();
            let zero = yl == 0 && yh == 0;
            if zero && (t.op == O_ADD || t.op == O_SUB || t.op == O_OR || t.op == O_XOR || t.op == O_SHL || t.op == O_LSHR || t.op == O_ASHR) || yl == 1 && yh == 0 && t.op == O_MUL {
                return t.a;
            }
            return VNONE;
        }
        if x.is_none() || y.is_none() {
            return cancel(b, t);
        }
        let (xl, xh) = x.unwrap();
        let (yl, yh) = y.unwrap();
        let (trap, rl, rh) = le::int128_fold(t.op, xl, xh, yl, yh);
        if trap != le::FOLD_OK {
            return VNONE;
        }
        r = (rl, rh);
    } else {
        return VNONE;
    }
    let w = b.words.len() as u32;
    b.words.push(r.0);
    b.words.push(r.1);
    b.insts[i as usize] = Inst { op: O_WCONST, ty: T_I128, aux: 0, a: w, b: 2, c: VNONE };
    return VNONE;
}

// The value of type `ty` that `v` extends (`zext`, `sext`), else VNONE.
const fn ext_from(b: &Body, v: Value, ty: u8) Value {
    if (v & (VPARAM | VFLAG)) != 0 {
        return VNONE;
    }
    let t = b.insts[v as usize];
    return if (t.op == O_ZEXT || t.op == O_SEXT) && b.type_of(t.a) == ty {
        t.a
    } else {
        VNONE
    };
}

// Lane access `i` of `b` (`O_VEXTRACT`, `O_VINSERT`) through the lanes it reads: a lane of a splat is its
// scalar; a lane of an insert is the inserted scalar, or the same lane of the vector inserted into; an
// insert of a vector's own lane is the vector; an insert into an insert of the same lane replaces it. The
// value it equals, else VNONE (and maybe `i` rewritten in place).
fn lane_fold(b: &mut Body, i: u32) Value {
    let mut t = b.insts[i as usize];
    if t.op == O_VINSERT {
        if (t.b & (VPARAM | VFLAG)) == 0 && b.insts[t.b as usize].op == O_VEXTRACT && b.insts[t.b as usize].a == t.a && b.insts[t.b as usize].aux == t.aux {
            return t.a;
        }
        if (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_VINSERT && b.insts[t.a as usize].aux == t.aux {
            t.a = b.insts[t.a as usize].a;
            b.insts[i as usize] = t;
        }
        return VNONE;
    }
    // Past the inserts of other lanes, at most LANE_WALK of them.
    let mut v = t.a;
    for _ in 0..LANE_WALK {
        if (v & (VPARAM | VFLAG)) != 0 {
            break;
        }
        let s = b.insts[v as usize];
        if s.op == O_SPLAT {
            return s.a;
        }
        if s.op != O_VINSERT {
            break;
        }
        if s.aux == t.aux {
            return s.b;
        }
        v = s.a;
    }
    if v != t.a {
        t.a = v;
        b.insts[i as usize] = t;
    }
    return VNONE;
}

// Whether float `v` of `b` is the result of an arithmetic operation or a conversion, so no signaling NaN.
const fn quiet(b: &Body, v: Value) bool {
    if (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let op = b.insts[v as usize].op;
    return op >= O_FADD && op <= O_FDIV || op == O_FMA || op == O_FSQRT || op >= O_FPEXT && op <= O_FPTRUNC || op == O_SITOFP || op == O_UITOFP;
}

// The inserts `lane_fold` looks through.
const LANE_WALK: u32 = 64;

const fn float_const(b: &Body, v: Value) Option<u64> {
    if (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_FCONST {
        return None;
    }
    let t = b.insts[v as usize];
    return Some(t.b as u64 << 32 | t.a as u64);
}

// Pure instruction `i` of `b`, its operands final: the value it equals (VNONE: none). Else it may be
// rewritten in place: to a constant, to a canonical form (a commutative operation's constant second), or
// an address with its constant index and its base address's offset in its own.
// Each vector select of integer lanes of at most 4 bytes, of `x` or `y` by their comparison `x REL y` (an
// order, signed or not): the lanes' maximum or minimum (`vop.max`, `vop.min`; arm64 `smax`, x86-64
// `pmaxsd`), as LLVM InstCombine's select of a compare. Outside the walk, which reads a vector operation's
// operands in the pool only where it numbers them. Whether any changed.
fn vec_minmaxes(b: &mut Body) bool {
    let mut any = false;
    for i in 0..b.insts.len() {
        if b.insts[i].op == O_VSEL && vec_minmax(b, i as u32) {
            any = true;
        }
    }
    return any;
}

// `vec_minmaxes` of vector select `i`: whether it changed.
fn vec_minmax(b: &mut Body, i: u32) bool {
    let t = b.insts[i as usize];
    let lt = lane_type(t.ty);
    if !is_int(lt) || type_bytes(lt, 8) > 4 || (t.a & (VPARAM | VFLAG)) != 0 || t.a == VNONE {
        return false;
    }
    let m = b.insts[t.a as usize];
    let same = m.a == t.b && m.b == t.c;
    if m.op != O_VCMP || !same && !(m.a == t.c && m.b == t.b) || m.a == m.b {
        return false;
    }
    let gt = m.aux == C_SGT || m.aux == C_SGE || m.aux == C_UGT || m.aux == C_UGE;
    let lt_ = m.aux == C_SLT || m.aux == C_SLE || m.aux == C_ULT || m.aux == C_ULE;
    if !gt && !lt_ {
        return false;
    }
    let signed = m.aux == C_SGT || m.aux == C_SGE || m.aux == C_SLT || m.aux == C_SLE;
    // `x > y ? x : y` is the maximum; with the sides swapped, the minimum.
    let max = gt == same;
    let code = (core::OP_SIMD + if max {
        core::SIMD_MAX
    } else {
        core::SIMD_MIN
    } as u32) as u16 | if signed {
        VOP_SIGNED
    } else {
        0
    };
    let ops = [t.b, t.c];
    let at = b.pool_list(ops[0..2]);
    b.insts[i as usize] = Inst { op: O_VOP, ty: t.ty, aux: code, a: at, b: 2, c: VNONE };
    return true;
}

fn simplify(pk: &Package, b: &mut Body, i: u32) Value {
    let mut t = b.insts[i as usize];
    if t.op == O_VEXTRACT || t.op == O_VINSERT {
        return lane_fold(b, i);
    }
    if t.ty == T_I128 {
        return simplify_wide(b, i);
    }
    if is_vec(t.ty) {
        return VNONE;
    }
    let ptr = pk.ptr_bytes;
    if t.op == O_SELECT {
        let c = const_of(b, t.a);
        if c.is_some() {
            return if c.unwrap() != 0 {
                t.b
            } else {
                t.c
            };
        }
        // A flag (`zero_one`) chosen as 1 or 0 is the flag; as 0 or 1, the opposite comparison, or the
        // flag's equality with that 0.
        let x = const_of(b, t.b);
        let y = const_of(b, t.c);
        let zc = zero_one(b, t.a, ZO_DEPTH);
        let ct = b.type_of(t.a);
        let f = zc && ct == t.ty && x.is_some() && y.is_some();
        if f && x.unwrap() == 1 && y.unwrap() == 0 {
            return t.a;
        }
        // Of another width: the flag extended or truncated, as its value is 0 or 1.
        let g = zc && is_int(t.ty) && x.is_some() && y.is_some();
        if g && !f && x.unwrap() == 1 && y.unwrap() == 0 {
            let wide = type_bits(t.ty, ptr) > type_bits(ct, ptr);
            b.insts[i as usize] = Inst {
                op: if wide {
                    O_ZEXT
                } else {
                    O_TRUNC
                },
                ty: t.ty,
                aux: 0,
                a: t.a,
                b: VNONE,
                c: VNONE,
            };
            return VNONE;
        }
        if f && x.unwrap() == 0 && y.unwrap() == 1 {
            let icmp = (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_ICMP;
            let ci = if icmp {
                b.insts[t.a as usize]
            } else {
                Inst { op: O_ICMP, ty: t.ty, aux: C_NE, a: t.a, b: t.b, c: VNONE }
            };
            b.insts[i as usize] = Inst { op: O_ICMP, ty: t.ty, aux: opposite(ci.aux), a: ci.a, b: ci.b, c: VNONE };
            return VNONE;
        }
        // A choice between a constant 0 or 1 and another flag, on a flag: one operation on the two flags
        // (`c ? 0 : f` is `f >u c`, `c ? f : 1` is `f >=u c`).
        let fc = zc && ct == t.ty;
        let flag_b = zero_one(b, t.b, ZO_DEPTH) && b.type_of(t.b) == t.ty;
        let flag_c = zero_one(b, t.c, ZO_DEPTH) && b.type_of(t.c) == t.ty;
        if fc && x.is_some() && x.unwrap() <= 1 && flag_c {
            b.insts[i as usize] = if x.unwrap() == 0 {
                Inst { op: O_ICMP, ty: t.ty, aux: C_UGT, a: t.c, b: t.a, c: VNONE }
            } else {
                Inst { op: O_OR, ty: t.ty, aux: 0, a: t.a, b: t.c, c: VNONE }
            };
            return VNONE;
        }
        if fc && y.is_some() && y.unwrap() <= 1 && flag_b {
            b.insts[i as usize] = if y.unwrap() == 0 {
                Inst { op: O_AND, ty: t.ty, aux: 0, a: t.a, b: t.b, c: VNONE }
            } else {
                Inst { op: O_ICMP, ty: t.ty, aux: C_UGE, a: t.b, b: t.a, c: VNONE }
            };
            return VNONE;
        }
        // The flag itself on one side, another flag on the other: `c ? f : c` is `c & f`, `c ? c : f` is
        // `c | f` (a `&&` or `||` of flags).
        if fc && (t.c == t.a && flag_b || t.b == t.a && flag_c) {
            let op = if t.c == t.a {
                O_AND
            } else {
                O_OR
            };
            let f = if t.c == t.a {
                t.b
            } else {
                t.c
            };
            b.insts[i as usize] = Inst { op: op, ty: t.ty, aux: 0, a: t.a, b: f, c: VNONE };
            return VNONE;
        }
        // A choice between the two sides of an equality on it is one side: `x != y ? x : y` is `x`.
        if (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_ICMP {
            let ci = b.insts[t.a as usize];
            if (ci.aux == C_EQ || ci.aux == C_NE) && (t.b == ci.a && t.c == ci.b || t.b == ci.b && t.c == ci.a) {
                return if ci.aux == C_NE {
                    t.b
                } else {
                    t.c
                };
            }
        }
        return if t.b == t.c {
            t.b
        } else {
            VNONE
        };
    }
    if t.op == O_PTRADD {
        // A slot's address keeps its index: a constant offset past the slot in a path that never runs
        // would fail the verifier's check of slot accesses.
        let ix = const_of(b, t.b);
        if ix.is_some() && !slot_based(b, t.a) {
            let off = (t.c as i32) as i64 + le::sign_ext(ix.unwrap(), type_bits(b.type_of(t.b), ptr)) * t.aux as i64;
            if off >= -0x80000000 && off <= 0x7FFFFFFF {
                t.b = VNONE;
                t.c = off as u32;
            }
        }
        // A pointer-wide index plus or minus a constant: the constant scaled joins the offset (modulo
        // 2^64 both ways).
        if t.b != VNONE && (t.b & (VPARAM | VFLAG)) == 0 && type_bits(b.type_of(t.b), ptr) == ptr * 8 && !slot_based(
            b,
            t.a,
        ) {
            let x = b.insts[t.b as usize];
            // An `or` of a constant below `2^s` with a value shifted left by `s` adds it.
            let low = if x.op == O_OR && (x.a & (VPARAM | VFLAG)) == 0 && b.insts[x.a as usize].op == O_SHL {
                const_of(b, b.insts[x.a as usize].b)
            } else {
                Option::<u64>::None
            };
            let k = if x.op == O_ADD || x.op == O_SUB {
                const_of(b, x.b)
            } else if low.is_some() && low.unwrap() < 64 && const_of(b, x.b).is_some() && const_of(b, x.b).unwrap() < 1u64 << low.unwrap() {
                const_of(b, x.b)
            } else {
                Option::<u64>::None
            };
            if k.is_some() {
                let kv = le::sign_ext(k.unwrap(), ptr * 8);
                let d = if x.op == O_SUB {
                    -kv
                } else {
                    kv
                };
                let off = (t.c as i32) as i64 + d * t.aux as i64;
                if kv > -0x80000000 && kv < 0x80000000 && off >= -0x80000000 && off <= 0x7FFFFFFF {
                    t.b = x.a;
                    t.c = off as u32;
                }
            }
            // A pointer-wide index times a constant (a product, or a left shift below the width): the
            // constant joins the scale when the product fits it (modulo 2^64 both ways), so a strided access
            // is one of the counter.
            let x2 = if (t.b & (VPARAM | VFLAG)) == 0 {
                b.insts[t.b as usize]
            } else {
                Inst { op: 0, ty: 0, aux: 0, a: VNONE, b: VNONE, c: VNONE }
            };
            let f = if x2.op == O_MUL && (x2.b & (VPARAM | VFLAG)) == 0 && b.insts[x2.b as usize].op == O_ICONST {
                const_of(b, x2.b)
            } else if x2.op == O_SHL && (x2.b & (VPARAM | VFLAG)) == 0 && b.insts[x2.b as usize].op == O_ICONST && const_of(
                b,
                x2.b,
            ).unwrap() < 16 {
                Option::<u64>::Some(1u64 << const_of(b, x2.b).unwrap())
            } else {
                Option::<u64>::None
            };
            if f.is_some() && f.unwrap() != 0 && t.aux as u64 * f.unwrap() <= 0xFFFF {
                t.aux = (t.aux as u64 * f.unwrap()) as u16;
                t.b = x2.a;
            }
        }
        if t.b == VNONE && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_PTRADD && b.insts[t.a as usize].b == VNONE {
            let off = (t.c as i32) as i64 + (b.insts[t.a as usize].c as i32) as i64;
            if off >= -0x80000000 && off <= 0x7FFFFFFF {
                t.a = b.insts[t.a as usize].a;
                t.c = off as u32;
            }
        }
        b.insts[i as usize] = t;
        return if t.b == VNONE && t.c == 0 {
            t.a
        } else {
            VNONE
        };
    }
    if t.op == O_ICMP {
        let ca = const_of(b, t.a);
        let cb = const_of(b, t.b);
        if ca.is_some() && cb.is_some() {
            b.insts[i as usize] = iconst(t.ty, le::icmp(t.aux, b.type_of(t.a), ptr, ca.unwrap(), cb.unwrap()) as u64);
        } else if ca.is_some() || cb.is_some() {
            // A constant compared with selects of constants (an ordering `cmp` returns, tested): the
            // comparison of each, when that leaves a constant or one of the selects' conditions.
            let (k, r) = sel_cmp(b, t, ptr, ca.is_none(), SEL_CMP_DEPTH);
            if k == SC_VALUE && b.type_of(r) == t.ty {
                return r;
            }
            if k <= 1 {
                b.insts[i as usize] = iconst(t.ty, k);
                return VNONE;
            }
            // The constant second (an immediate operand), the condition mirrored; an unsigned order
            // against zero is equality or a constant.
            let mut c = t;
            if ca.is_some() {
                c = Inst { op: O_ICMP, ty: t.ty, aux: mirror(t.aux), a: t.b, b: t.a, c: VNONE };
            }
            // A flag (a comparison, extended or not) against 0 or 1 is the comparison or its opposite; another
            // flag (`zero_one`) of the result's type, the flag itself when the test is its being 1.
            let kk = const_of(b, c.b).unwrap();
            let mut fl = c.a;
            if (fl & (VPARAM | VFLAG)) == 0 && b.insts[fl as usize].op == O_ZEXT && zero_one(
                b,
                b.insts[fl as usize].a,
                ZO_DEPTH,
            ) {
                fl = b.insts[fl as usize].a;
            }
            if (c.aux == C_EQ || c.aux == C_NE) && kk <= 1 && c.aux == C_NE == (kk == 0) && b.type_of(fl) == t.ty && zero_one(
                b,
                fl,
                ZO_DEPTH,
            ) {
                return fl;
            }
            if (c.aux == C_EQ || c.aux == C_NE) && kk <= 1 && (fl & (VPARAM | VFLAG)) == 0 && b.insts[fl as usize].op == O_ICMP {
                let f = b.insts[fl as usize];
                let same_dir = c.aux == C_NE == (kk == 0);
                b.insts[i as usize] = Inst {
                    op: O_ICMP,
                    ty: t.ty,
                    aux: if same_dir {
                        f.aux
                    } else {
                        opposite(f.aux)
                    },
                    a: f.a,
                    b: f.b,
                    c: VNONE,
                };
                return VNONE;
            }
            if const_of(b, c.b).unwrap() == 0 && (c.aux == C_ULT || c.aux == C_UGE) {
                b.insts[i as usize] = iconst(t.ty, (c.aux == C_UGE) as u64);
                return VNONE;
            }
            if const_of(b, c.b).unwrap() == 0 && (c.aux == C_UGT || c.aux == C_ULE) {
                c.aux = if c.aux == C_UGT {
                    C_NE
                } else {
                    C_EQ
                };
            }
            b.insts[i as usize] = c;
        } else if t.a == t.b {
            let c = t.aux;
            b.insts[i as usize] = iconst(
                t.ty,
                (c == C_EQ || c == C_SLE || c == C_SGE || c == C_ULE || c == C_UGE) as u64,
            );
        }
        return VNONE;
    }
    if t.op >= O_FADD && t.op <= O_FDIV {
        let x = float_const(b, t.a);
        let y = float_const(b, t.b);
        // -0.0 + v is v when v is no signaling NaN: the result of an arithmetic operation.
        let neg0 = 1u64 << (type_bits(t.ty, 8) - 1) as u64;
        if t.op == O_FADD && x.is_some() && x.unwrap() == neg0 && quiet(b, t.b) {
            return t.b;
        }
        if t.op == O_FADD && y.is_some() && y.unwrap() == neg0 && quiet(b, t.a) {
            return t.a;
        }
        // So is 1.0 * v.
        let one: u64 = if t.ty == T_F32 {
            0x3F800000
        } else {
            0x3FF0000000000000
        };
        if t.op == O_FMUL && x.is_some() && x.unwrap() == one && quiet(b, t.b) && (t.ty == T_F32 || t.ty == T_F64) {
            return t.b;
        }
        if t.op == O_FMUL && y.is_some() && y.unwrap() == one && quiet(b, t.a) && (t.ty == T_F32 || t.ty == T_F64) {
            return t.a;
        }
        if x.is_some() && y.is_some() {
            let r = le::float_op(t.op, t.ty, x.unwrap(), y.unwrap());
            // A NaN result keeps its operation: the machine chooses its payload.
            if !is_nan(t.ty, r) {
                b.insts[i as usize] = Inst {
                    op: O_FCONST,
                    ty: t.ty,
                    aux: 0,
                    a: r as u32,
                    b: (r >> 32) as u32,
                    c: VNONE,
                };
            }
        }
        return VNONE;
    }
    // A value's bits read as another type and back are the value.
    if t.op == O_BITCAST && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_BITCAST && b.type_of(
        b.insts[t.a as usize].a,
    ) == t.ty {
        return b.insts[t.a as usize].a;
    }
    // A pointer turned into an integer of its width and back is the pointer, and the reverse.
    if (t.op == O_INTTOPTR || t.op == O_PTRTOINT) && (t.a & (VPARAM | VFLAG)) == 0 {
        let x = b.insts[t.a as usize];
        if (x.op == O_PTRTOINT && t.op == O_INTTOPTR || x.op == O_INTTOPTR && t.op == O_PTRTOINT) && b.type_of(x.a) == t.ty && type_bits(
            b.type_of(t.a),
            ptr,
        ) == ptr * 8 {
            return x.a;
        }
    }
    if t.op == O_TRUNC && b.type_of(t.a) == T_I128 {
        let x = wide_of(b, t.a);
        if x.is_some() {
            b.insts[i as usize] = iconst(t.ty, x.unwrap().0);
        }
        return VNONE;
    }
    // A truncation of an extension or a truncation: the operand at the type (itself, extended, truncated).
    // An extension of a truncated bit count of the extension's type: the count, which any type holds.
    if (t.op == O_TRUNC || t.op == O_ZEXT) && is_int(t.ty) && (t.a & (VPARAM | VFLAG)) == 0 && t.a != VNONE {
        let w = b.insts[t.a as usize];
        let ft = if w.op == O_ZEXT || w.op == O_SEXT || w.op == O_TRUNC {
            b.type_of(w.a)
        } else {
            T_NONE
        };
        if t.op == O_TRUNC && (w.op == O_ZEXT || w.op == O_SEXT || w.op == O_TRUNC) && is_int(ft) {
            if ft == t.ty {
                return w.a;
            }
            let wider = type_bits(ft, ptr) > type_bits(t.ty, ptr);
            b.insts[i as usize] = Inst {
                op: if wider {
                    O_TRUNC
                } else {
                    w.op
                },
                ty: t.ty,
                aux: 0,
                a: w.a,
                b: VNONE,
                c: VNONE,
            };
            return VNONE;
        }
        if t.op == O_ZEXT && w.op == O_TRUNC && ft == t.ty && type_bits(w.ty, ptr) >= 8 && (w.a & VPARAM) == 0 && b.insts[w.a as usize].op >= O_CLZ && b.insts[w.a as usize].op <= O_POPCNT {
            return w.a;
        }
        if t.op == O_ZEXT && w.op == O_ZEXT {
            b.insts[i as usize] = Inst { op: O_ZEXT, ty: t.ty, aux: 0, a: w.a, b: VNONE, c: VNONE };
            return VNONE;
        }
    }
    if t.op == O_SEXT || t.op == O_ZEXT || t.op == O_TRUNC || t.op == O_INTTOPTR || t.op == O_PTRTOINT {
        let x = const_of(b, t.a);
        let mut r: u64 = 0;
        if x.is_some() && le::scalar_convert(t.op, t.aux, b.type_of(t.a), t.ty, ptr, x.unwrap(), &mut r) {
            b.insts[i as usize] = iconst(t.ty, r);
        }
        return VNONE;
    }
    if !is_int(t.ty) || t.op < O_ADD || t.op > O_NOT {
        return VNONE;
    }
    // A commutative operation takes a constant second.
    let op = t.op;
    if (op == O_ADD || op == O_MUL || op == O_AND || op == O_OR || op == O_XOR) && const_of(b, t.a).is_some() && const_of(
        b,
        t.b,
    ).is_none() {
        let x = t.a;
        t.a = t.b;
        t.b = x;
        b.insts[i as usize] = t;
    }
    let ca = const_of(b, t.a);
    let cb = if op == O_NEG || op == O_NOT {
        Option::<u64>::Some(0)
    } else {
        const_of(b, t.b)
    };
    let mut r: u64 = 0;
    if ca.is_some() && cb.is_some() {
        if le::int_fold(op, t.ty, ptr, ca.unwrap(), cb.unwrap(), &mut r) == le::FOLD_OK {
            b.insts[i as usize] = iconst(t.ty, r);
        }
        return VNONE;
    }
    if op == O_NEG || op == O_NOT {
        return VNONE;
    }
    let ones = le::trunc_bits(0xFFFFFFFFFFFFFFFF, type_bits(t.ty, ptr));
    if cb.is_some() {
        let y = cb.unwrap();
        // The negation of a comparison (`!(a < b)`) is the opposite comparison.
        if op == O_XOR && y == 1 && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_ICMP && b.insts[t.a as usize].ty == t.ty {
            let c = b.insts[t.a as usize];
            b.insts[i as usize] = Inst { op: O_ICMP, ty: t.ty, aux: opposite(c.aux), a: c.a, b: c.b, c: VNONE };
            return VNONE;
        }
        if y == 0 && (op == O_ADD || op == O_SUB || op == O_OR || op == O_XOR || op == O_SHL || op == O_LSHR || op == O_ASHR) || y == 1 && (op == O_MUL || op == O_SDIV || op == O_UDIV) || y == ones && op == O_AND {
            return t.a;
        }
        if y == 0 && (op == O_MUL || op == O_AND) || y == ones && op == O_OR {
            b.insts[i as usize] = iconst(t.ty, y);
            return VNONE;
        }
        return cancel(b, t);
    }
    if t.a == t.b {
        if op == O_AND || op == O_OR {
            return t.a;
        }
        if op == O_SUB || op == O_XOR {
            b.insts[i as usize] = iconst(t.ty, 0);
        }
    }
    return cancel(b, t);
}

// The operand a sum or difference `t` leaves when one of its terms cancels: `(x + y) - x` is `y`,
// `(x - y) + y` is `x`; VNONE when none does.
fn cancel(b: &Body, t: Inst) Value {
    let a = if (t.a & (VPARAM | VFLAG)) == 0 {
        b.insts[t.a as usize]
    } else {
        Inst { op: 0, ty: 0, aux: 0, a: VNONE, b: VNONE, c: VNONE }
    };
    let c = if t.b != VNONE && (t.b & (VPARAM | VFLAG)) == 0 {
        b.insts[t.b as usize]
    } else {
        Inst { op: 0, ty: 0, aux: 0, a: VNONE, b: VNONE, c: VNONE }
    };
    if t.op == O_SUB && a.op == O_ADD {
        if same_term(b, a.a, t.b) {
            return a.b;
        }
        if same_term(b, a.b, t.b) {
            return a.a;
        }
    }
    if t.op == O_ADD && a.op == O_SUB && same_term(b, a.b, t.b) {
        return a.a;
    }
    if t.op == O_ADD && c.op == O_SUB && same_term(b, c.b, t.a) {
        return c.a;
    }
    return VNONE;
}

// Whether terms `x` and `y` of one sum are one value: the same, or equal constants not yet numbered one.
fn same_term(b: &Body, x: Value, y: Value) bool {
    if x == y {
        return true;
    }
    let k = const_of(b, x);
    return k.is_some() && k == const_of(b, y);
}

// Whether float bits `r` of type `ty` are a normal number: neither zero, subnormal, infinite nor NaN.
fn regular(ty: u8, r: u64) bool {
    let e = if ty == T_F64 {
        r >> 52 & 0x7FF
    } else {
        r >> 23 & 0xFF
    };
    let top = if ty == T_F64 {
        0x7FFu64
    } else {
        0xFFu64
    };
    return e != 0 && e != top;
}

// Whether `v` of `b` is a scalar float product of type `ty`.
fn is_fmul(b: &Body, v: Value, ty: u8) bool {
    return (v & (VPARAM | VFLAG)) == 0 && v != VNONE && b.insts[v as usize].op == O_FMUL && b.insts[v as usize].ty == ty;
}

// Whether signatures `s` and `r` of `b`'s pool are one: the parameter counts, the result and the
// parameters' codes.
fn same_sig(b: &Body, s: u32, r: u32) bool {
    let n = b.pool[s as usize];
    if n != b.pool[r as usize] {
        return false;
    }
    for k in 0..n + 2 {
        if b.pool[(s + 1 + k) as usize] != b.pool[(r + 1 + k) as usize] {
            return false;
        }
    }
    return true;
}

// `zero_one` follows at most ZO_DEPTH operations.
const ZO_DEPTH: u32 = 3;

// Whether value `v` of `b` is 0 or 1: a comparison, an overflow flag, a `bool` parameter (`Body.bools`), a
// `bool` load (`MEM_BOOL`), and the `and`, `or`, `xor`, select, extension or truncation of such values,
// `depth` operations deep.
fn zero_one(b: &Body, v: Value, depth: u32) bool {
    if v == VNONE {
        return false;
    }
    if (v & VFLAG) != 0 {
        return true;
    }
    if (v & VPARAM) != 0 {
        let k = entry_param(b, v);
        return k < 64 && (b.bools >> k as u64 & 1) != 0;
    }
    let t = b.insts[v as usize];
    if t.op == O_ICMP || t.op == O_FCMP || t.op == O_LOAD && (t.aux & MEM_BOOL) != 0 {
        return true;
    }
    if depth == 0 || !is_int(t.ty) {
        return false;
    }
    if t.op == O_AND {
        return zero_one(b, t.a, depth - 1) || zero_one(b, t.b, depth - 1);
    }
    if t.op == O_OR || t.op == O_XOR {
        return zero_one(b, t.a, depth - 1) && (zero_one(b, t.b, depth - 1) || t.op == O_XOR && const_of(b, t.b) == Option::<
            u64
        >::Some(1));
    }
    if t.op == O_SELECT {
        return zero_one(b, t.b, depth - 1) && zero_one(b, t.c, depth - 1);
    }
    return (t.op == O_ZEXT || t.op == O_TRUNC) && zero_one(b, t.a, depth - 1);
}

// Whether address `v` of `b` is a slot's address plus constant offsets.
const fn slot_based(b: &Body, v: Value) bool {
    let mut x = v;
    // Each step goes to an earlier address of the chain: at most the instruction count.
    for _ in 0..b.insts.len() {
        if (x & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let t = b.insts[x as usize];
        if t.op == O_SLOTADDR {
            return true;
        }
        if t.op != O_PTRADD || t.b != VNONE {
            return false;
        }
        x = t.a;
    }
    return false;
}

// Pointer load `i` of `b`, of read-only data of the package at the place of a relocation (a method in a
// conformance table): the relocation's symbol address, when an object of unit `unit` may name it (a global
// symbol, or one of that unit); a call through it becomes direct (`direct_calls`). Whether it did.
fn fold_ptr(pk: &Package, b: &mut Body, i: u32, unit: u32) bool {
    let t = b.insts[i as usize];
    if t.ty != T_PTR || (t.a & (VPARAM | VFLAG)) != 0 || b.insts[t.a as usize].op != O_SYMADDR {
        return false;
    }
    let at = b.insts[t.a as usize];
    let s = pk.syms[b.syms[at.a as usize] as usize];
    if s.kind != SK_DATA || s.def == NONE {
        return false;
    }
    let d = pk.data[s.def as usize];
    let off = (at.b as i32) as i64 + (t.c as i32) as i64;
    if !d.readonly || off < 0 || off + pk.ptr_bytes as i64 > d.size as i64 {
        return false;
    }
    for r in d.relocs..d.relocs + d.nrelocs {
        let rl = pk.relocs[r as usize];
        if rl.offset as i64 != off {
            continue;
        }
        let y = pk.syms[rl.sym as usize];
        if y.linkage != SL_GLOBAL && y.unit != unit || rl.addend < i32::MIN as i64 || rl.addend > i32::MAX as i64 {
            return false;
        }
        let bs = b.ref_sym(rl.sym);
        b.insts[i as usize] = Inst { op: O_SYMADDR, ty: T_PTR, aux: 0, a: bs, b: (rl.addend as i32) as u32, c: VNONE };
        return true;
    }
    return false;
}

// A load of read-only data of the package at a constant place clear of its relocations: rewritten to the
// constant it reads. Whether instruction `i` folded.
fn fold_data(pk: &Package, b: &mut Body, i: u32) bool {
    let t = b.insts[i as usize];
    if (t.a & (VPARAM | VFLAG)) != 0 || is_vec(t.ty) || t.ty == T_PTR || t.ty == T_I128 || b.insts[t.a as usize].op != O_SYMADDR {
        return false;
    }
    let at = b.insts[t.a as usize];
    let s = pk.syms[b.syms[at.a as usize] as usize];
    if s.kind != SK_DATA || s.def == NONE {
        return false;
    }
    let d = pk.data[s.def as usize];
    let off = (at.b as i32) as i64 + (t.c as i32) as i64;
    let n = type_bytes(t.ty, pk.ptr_bytes) as i64;
    if !d.readonly || off < 0 || off + n > d.size as i64 {
        return false;
    }
    for r in d.relocs..d.relocs + d.nrelocs {
        let ro = pk.relocs[r as usize].offset as i64;
        if ro < off + n && ro + pk.ptr_bytes as i64 > off {
            return false;
        }
    }
    // Little-endian, as every native target.
    let mut v: u64 = 0;
    for q in 0..n {
        if off + q < d.nbytes as i64 {
            v |= pk.bytes[(d.bytes as i64 + off + q) as usize] as u64 << (8 * q) as u64;
        }
    }
    b.insts[i as usize] = if is_float(t.ty) {
        Inst { op: O_FCONST, ty: t.ty, aux: 0, a: v as u32, b: (v >> 32) as u32, c: VNONE }
    } else {
        iconst(t.ty, v)
    };
    return true;
}

// ---- Helpers ------------------------------------------------------------------------------------------

// Whether vector operation `t` reads the slice at `v`, its first operand and no other, and writes no byte
// of it: a checked load or store, or a masked, partial or gather access of a slice.
const fn header_read(b: &Body, t: Inst, v: Value) bool {
    let code = (t.aux & VOP_CODE) as u32;
    if code < core::OP_SIMD || code >= core::OP_CMP_LANES || t.b == 0 || b.pool[t.a as usize] != v {
        return false;
    }
    for q in 1..t.b {
        if b.pool[(t.a + q) as usize] == v {
            return false;
        }
    }
    let c = (code - core::OP_SIMD) as u8;
    let rule = core::simd_op(c).rule;
    return rule == core::SR_LOAD && c != core::SIMD_LOAD_RAW || rule == core::SR_STORE && c != core::SIMD_STORE_RAW || (rule == core::SR_MLOAD || rule == core::SR_MSTORE) && c < core::SIMD_GATHER_PTR;
}

// The `Sym.alloc` of the function call `t` calls, ALLOC_NONE for any other instruction and for a function
// the package defines: its own code (wasm's C library, the runtime's leak tracker) reads what it writes.
// The `Sym.alloc` of call `t`'s function by its name alone, whether the package defines it or not
// (`dead_allocs`): ALLOC_NONE for another instruction.
fn named_alloc(pk: &Package, b: &Body, t: Inst) u8 {
    return if t.op == O_CALL {
        pk.syms[b.syms[t.a as usize] as usize].alloc
    } else {
        ALLOC_NONE
    };
}

fn call_alloc(pk: &Package, b: &Body, t: Inst) u8 {
    if t.op != O_CALL {
        return ALLOC_NONE;
    }
    let s = pk.syms[b.syms[t.a as usize] as usize];
    return if s.def == NONE {
        s.alloc
    } else {
        ALLOC_NONE
    };
}

// The type tag of the memory write `t` writes that the program may read (`TBAA_TAGS` past the tags: none):
// a load's or a store's own, an allocation's `errno` (an `i32`); a free writes none; 0 for any other write,
// which may touch any.
fn write_tag(pk: &Package, b: &Body, t: Inst) usize {
    let a = call_alloc(pk, b, t);
    return if t.op == O_LOAD || t.op == O_STORE {
        tbaa(t)
    } else if a == ALLOC_FRESH {
        tbaa_of(T_I32) as usize
    } else if a == ALLOC_FREE {
        TBAA_TAGS
    } else {
        0usize
    };
}

// `writes_memory`, but for a call of a function whose body writes no memory outside its frame
// (`Sym.fx`).
fn writes(pk: &Package, b: &Body, t: Inst) bool {
    return writes_memory(t) && (t.op != O_CALL || (pk.syms[b.syms[t.a as usize] as usize].fx & (FX_WRITE | FX_ARG)) != 0);
}

// The signature parameter value `v` of `b` is (its index), else NONE.
const fn entry_param(b: &Body, v: Value) u32 {
    let e = b.blocks[0];
    if v == VNONE || (v & VPARAM) == 0 || (v & ~VPARAM) < e.param_start || (v & ~VPARAM) >= e.param_start + e.param_len as u32 {
        return NONE;
    }
    return (v & ~VPARAM) - e.param_start;
}

// Per instruction of `b` into `out`: whether it is a load through a read-only parameter's referent
// (`REF_READONLY`): through the parameter, or a view's (`REF_INNER`) pointer at its offset 0, then
// offsets of either (`ptradd`, a `select` of two). One pass in order: a pointer defined after its use
// counts as none.
fn frozen(b: &Body, out: &mut Vector<bool>) {
    let ni = b.insts.len();
    out.truncate(0);
    out.resize_default(ni);
    let e = b.blocks[0];
    let mut any = false;
    for k in 0..b.refs.len() {
        any = any || (b.refs[k] & REF_READONLY) != 0 && k < e.param_len as usize;
    }
    if !any {
        return;
    }
    // Per instruction, whether its value points into a read-only referent.
    let mut fp = Vector::<bool>::new();
    fp.resize_default(ni);
    for i in 0..ni {
        let t = b.insts[i];
        let base = if t.op == O_LOAD || t.op == O_PTRADD {
            t.a
        } else {
            VNONE
        };
        let mut via = false;
        if (base & VPARAM) != 0 && (base & VFLAG) == 0 {
            let p = base & ~VPARAM;
            if p >= e.param_start && p < e.param_start + e.param_len as u32 {
                let q = (p - e.param_start) as usize;
                let r = if q < b.refs.len() {
                    b.refs[q]
                } else {
                    0u32
                };
                via = (r & REF_READONLY) != 0 && ((r & REF_INNER) == 0 || t.op == O_LOAD && t.c == 0 && t.ty == T_PTR);
                // A view's own words are no element: its pointer, through which the elements are.
                if (r & REF_INNER) != 0 {
                    fp[i] = via;
                    continue;
                }
                // An `@owned` field's pointer: its buffer is read-only too (`Body.owned`).
                fp[i] = via && t.op == O_LOAD && t.ty == T_PTR && owned_at(b, q as u32, t.c);
            }
        } else if base != VNONE && (base & VFLAG) == 0 {
            via = fp[base as usize];
        }
        if t.op == O_LOAD {
            out[i] = via;
        } else if t.op == O_PTRADD {
            fp[i] = via;
        } else if t.op == O_SELECT && (t.b & (VPARAM | VFLAG)) == 0 && (t.c & (VPARAM | VFLAG)) == 0 && t.b != VNONE && t.c != VNONE {
            fp[i] = fp[t.b as usize] && fp[t.c as usize];
        }
    }
}

// Whether `Body.owned` holds a field of parameter `k` at offset `off`.
fn owned_at(b: &Body, k: u32, off: u32) bool {
    for x in 0..b.owned.len() {
        if b.owned[x] == (k as u64 << 32 | off as u64) {
            return true;
        }
    }
    return false;
}

// Whether signature parameter `k` of `b` is a view whose loaded pointer is exclusive (`REF_INNER`).
const fn inner(b: &Body, k: u32) bool {
    return k < b.refs.len() as u32 && (b.refs[k as usize] & REF_INNER) != 0;
}

// Whether value `v` is a reference parameter of `b` (`Body.refs`), not a view: never null.
fn ref_param(b: &Body, v: Value) bool {
    if v == VNONE || (v & VPARAM) == 0 || (v & VFLAG) != 0 {
        return false;
    }
    let e = b.blocks[0];
    let p = v & ~VPARAM;
    if p < e.param_start || p >= e.param_start + e.param_len as u32 || p - e.param_start >= b.refs.len() as u32 {
        return false;
    }
    let r = b.refs[(p - e.param_start) as usize];
    return r != 0 && (r & REF_INNER) == 0;
}

// Whether any signature parameter of `b` is a view (`inner`).
fn any_inner(b: &Body) bool {
    for k in 0..b.refs.len() {
        if (b.refs[k] & REF_INNER) != 0 {
            return true;
        }
    }
    return false;
}

// `Opt::owned_seeds`: an offset that is not constant.
const OFF_ANY: i64 = -0x8000000000000000;

// An alias class (`CL_*`) not yet joined.
const CL_UNSET: u8 = 65;
// The rounds of joins `Opt::classes` runs before it gives up.
const CLASS_ROUNDS: u32 = 8;

// The bits of the classes an access of class `c` may touch.
const fn class_bit(c: u8) u64 {
    return if c >= CL_MANY {
        ~0u64
    } else {
        1u64 << c as u64
    };
}

// The class of a value that may be either `a`'s or `b`'s.
const fn join(a: u8, b: u8) u8 {
    return if a == CL_UNSET || a == b {
        b
    } else if b == CL_UNSET {
        a
    } else {
        CL_MANY
    };
}

// Whether opcode `op` computes a value from its operands alone, the same each time it does not trap.
const fn pure_op(op: u8) bool {
    return PURE[op as usize];
}

// `pure_op` per operation; a byte indexes the 256 entries.
const PURE: [bool; 256] = pure_ops();

const fn pure_ops() [bool; 256] {
    let mut t = [false; 256];
    for k in 0..256u32 {
        let op = k as u8;
        unsafe {
            t[k as usize] = op >= O_ICONST && op <= O_INTTOPTR || op == O_PTRADD || op == O_SELECT || op == O_FMA || op == O_MULHU || op == O_MULHS || op == O_BSWAP || op >= O_CLZ && op <= O_POPCNT || op == O_SPLAT || op == O_VCMP || op == O_VSEL || op == O_VUNZIP || op == O_HTOF || op == O_FTOH || op == O_FSQRT || op == O_VZIPLO || op == O_VZIPHI || op == O_VEXTRACT || op == O_VINSERT;
        }
    }
    return t;
}

// Whether pure `t` of `b` may run where the program would not run it: it has operands (a constant is
// `tidy`'s to place), cannot trap and gives a defined value (a shift amount below the width; no checked
// arithmetic, division or float to integer conversion).
fn speculable(pk: &Package, b: &Body, t: Inst) bool {
    let op = t.op;
    if op <= O_SLOTADDR || op >= O_SDIV && op <= O_UREM || op >= O_ADDO && op <= O_MULO || op == O_FPTOSI || op == O_FPTOUI {
        return false;
    }
    if op == O_SHL || op == O_LSHR || op == O_ASHR {
        let c = const_of(b, t.b);
        return c.is_some() && c.unwrap() < type_bits(t.ty, pk.ptr_bytes) as u64;
    }
    return true;
}

// Whether `t` of `b` is the address of a thread-local variable: the running thread's copy, which a call
// may change (a task resumes on another thread), so no two of them are one value.
const fn tls_addr(pk: &Package, b: &Body, t: Inst) bool {
    return t.op == O_SYMADDR && pk.syms[b.syms[t.a as usize] as usize].kind == SK_TLS;
}

// Whether `t` and `u` are the same instruction.
const fn same(t: Inst, u: Inst) bool {
    return t.op == u.op && t.ty == u.ty && t.aux == u.aux && t.a == u.a && t.b == u.b && t.c == u.c;
}

// The hash of pure instruction `t` of `b`, a wide constant's by its words.
fn value_hash(b: &Body, t: Inst) u64 {
    if t.op != O_WCONST {
        return hash(t);
    }
    let mut h = mix(O_WCONST as u64 | t.ty as u64 << 8, t.b);
    for q in 0..t.b {
        h = mix(h, b.words[(t.a + q) as usize]);
    }
    return h;
}

// Whether pure instructions `t` and `u` of `b` compute one value: equal, or wide constants of equal words.
fn same_value(b: &Body, t: Inst, u: Inst) bool {
    if t.op != O_WCONST || u.op != O_WCONST {
        return same(t, u);
    }
    if t.ty != u.ty || t.b != u.b {
        return false;
    }
    for q in 0..t.b {
        if b.words[(t.a + q) as usize] != b.words[(u.a + q) as usize] {
            return false;
        }
    }
    return true;
}

// The `Opt.rel` key of `x <u y`.
// The key of `x` and `y` in `Opt.eqs`, either order.
const fn eq_key(x: Value, y: Value) u64 {
    return if x < y {
        rel_key(x, y)
    } else {
        rel_key(y, x)
    };
}

const fn rel_key(x: Value, y: Value) u64 {
    return y as u64 << 32 | x as u64;
}

// `sel_cmp`'s answers besides a constant 0 or 1: a value, or none.
const SC_VALUE: u8 = 2;
const SC_NONE: u8 = 3;
// `sel_cmp` follows selects SEL_CMP_DEPTH deep.
const SEL_CMP_DEPTH: u32 = 3;

// Comparison `t` of a tree of selects of constants (operand `a` when `left`, else `b`) with a constant,
// at most `depth` selects deep: `(0 or 1, _)` when it is that constant, `(SC_VALUE, c)` when it is the
// comparison `c` a select tests, else `(SC_NONE, _)`.
fn sel_cmp(b: &Body, t: Inst, ptr: u32, left: bool, depth: u32) (u8, Value) {
    let v = if left {
        t.a
    } else {
        t.b
    };
    let ty = b.type_of(t.a);
    let k = const_of(b, v);
    if k.is_some() {
        let o = if left {
            const_of(b, t.b).unwrap()
        } else {
            const_of(b, t.a).unwrap()
        };
        let r = if left {
            le::icmp(t.aux, ty, ptr, k.unwrap(), o)
        } else {
            le::icmp(t.aux, ty, ptr, o, k.unwrap())
        };
        return (r as u8, VNONE);
    }
    if depth == 0 || (v & (VPARAM | VFLAG)) != 0 {
        return (SC_NONE, VNONE);
    }
    // A comparison widened (`simplify`'s form of a select of 1 or 0): as that select.
    let z = b.insts[v as usize];
    if z.op == O_ZEXT && (z.a & (VPARAM | VFLAG)) == 0 && b.insts[z.a as usize].op == O_ICMP {
        let o = if left {
            const_of(b, t.b)
        } else {
            const_of(b, t.a)
        };
        if o.is_none() {
            return (SC_NONE, VNONE);
        }
        let (x, y) = if left {
            (le::icmp(t.aux, ty, ptr, 1, o.unwrap()) as u8, le::icmp(t.aux, ty, ptr, 0, o.unwrap()) as u8)
        } else {
            (le::icmp(t.aux, ty, ptr, o.unwrap(), 1) as u8, le::icmp(t.aux, ty, ptr, o.unwrap(), 0) as u8)
        };
        if x == y {
            return (x, VNONE);
        }
        if x == 1 {
            return (SC_VALUE, z.a);
        }
        return (SC_NONE, VNONE);
    }
    if z.op != O_SELECT {
        return (SC_NONE, VNONE);
    }
    let sel = z;
    let mut tx = t;
    let mut ty2 = t;
    if left {
        tx.a = sel.b;
        ty2.a = sel.c;
    } else {
        tx.b = sel.b;
        ty2.b = sel.c;
    }
    let (x, _) = sel_cmp(b, tx, ptr, left, depth - 1);
    let (y, _) = sel_cmp(b, ty2, ptr, left, depth - 1);
    if x <= 1 && x == y {
        return (x, VNONE);
    }
    // The select's condition is the result when it is a comparison (0 or 1) and picks 1 over 0.
    let c = sel.a;
    if x == 1 && y == 0 && (c & (VPARAM | VFLAG)) == 0 && b.insts[c as usize].op == O_ICMP {
        return (SC_VALUE, c);
    }
    return (SC_NONE, VNONE);
}

// Reader `r` (`Opt::preader`) after block `k` reads the value too.
const fn reader(r: u32, k: u32) u32 {
    return if r == NONE || r == k {
        k
    } else {
        MULTI
    };
}

// The multiplier and shift that divide a `bits`-bit unsigned value by `d` (neither 0 nor a power of two)
// with a high product (Granlund and Montgomery 1994; Warren, Hacker's Delight, 10-8): `(m, s, false)` for
// `mulhu(n, m) >> s`, with the least `s` whose `m = ceil(2^(bits + s) / d)` fits in `bits` bits and errs
// by at most `2^s` (`m * d - 2^(bits + s) <= 2^s`, exact for every `n`); else `(m, l - 1, true)` for
// `((n - h) / 2 + h) >> (l - 1)`, `h = mulhu(n, m)`, `m = 2^bits * (2^l - d) / d + 1`, `l = ceil(log2 d)`.
// The multiplier and shift of signed division by `d` at `bits` bits (Warren, Hacker's Delight, 10-1:
// `magic`), `|d|` at least 3 and no power of two: the multiplier `bits` wide, the smallest shift. The loop
// raises `p` from `bits` while `2^p / anc` is below `|d| - 2^p % |d|`, at most `bits` times: past that
// `2^p / anc` reaches `2^(bits - 1)`, above every `|d|`.
const fn smagic(d: i64, bits: u32) (u64, u32) {
    let one: u128 = 1;
    let two = one << (bits - 1) as usize;
    let ad = if d < 0 {
        0u64.wrapping_sub(d as u64)
    } else {
        d as u64
    } as u128;
    let t = if d < 0 {
        two + 1
    } else {
        two
    };
    let anc = t - 1 - t % ad;
    let mut p = bits - 1;
    let mut q1 = two / anc;
    let mut r1 = two - q1 * anc;
    let mut q2 = two / ad;
    let mut r2 = two - q2 * ad;
    for _ in 0..bits {
        p += 1;
        q1 *= 2;
        r1 *= 2;
        if r1 >= anc {
            q1 += 1;
            r1 -= anc;
        }
        q2 *= 2;
        r2 *= 2;
        if r2 >= ad {
            q2 += 1;
            r2 -= ad;
        }
        let delta = ad - r2;
        if q1 > delta || q1 == delta && r1 != 0 {
            break;
        }
    }
    let wm = (one << bits as usize) - 1;
    let m = q2 + 1 & wm;
    let ms = if d < 0 {
        wm + 1 - m & wm
    } else {
        m
    };
    return (ms as u64, p - bits);
}

const fn magic(d: u64, bits: u32) (u64, u32, bool) {
    let one: u128 = 1;
    let l = 64 - (d - 1).leading_zeros() as u32;
    let top = one << bits as usize;
    let dd = d as u128;
    for s in 0..l {
        let p = one << (bits + s) as usize;
        let m = (p + dd - 1) / dd;
        if m < top && m * dd - p <= one << s as usize {
            return (m as u64, s, false);
        }
    }
    let m = top * ((one << l as usize) - dd) / dd + 1;
    return (m as u64, l - 1, true);
}

// Whether edges `x` and `y` of `b` enter one block with the same arguments.
// Whether blocks `x` and `y`, without parameters, of at most TWIN_MAX instructions, compute the same values
// from the same values and end by the same jump or return: a branch to one or the other jumps to `x` (LLVM
// SimplifyCFG's merge of identical successors). Only `y` reads its own results, as it jumps or returns.
fn twins(b: &Body, x: u32, y: u32) bool {
    let bx = b.blocks[x as usize];
    let by = b.blocks[y as usize];
    if x == y || bx.len != by.len || bx.len > TWIN_MAX || bx.param_len != 0 || by.param_len != 0 {
        return false;
    }
    for j in 0..bx.len {
        let s = b.insts[(bx.start + j) as usize];
        let u = b.insts[(by.start + j) as usize];
        if s.op != u.op || s.ty != u.ty || s.aux != u.aux {
            return false;
        }
        let f = op_info(s.op).form;
        if f == F_JMP {
            if b.edge_target(s.a) != b.edge_target(u.a) {
                return false;
            }
            for q in 0..b.edge_nargs(s.a) {
                if !twin_val(bx, by, b.edge_arg(s.a, q), b.edge_arg(u.a, q)) {
                    return false;
                }
            }
            continue;
        }
        if f > F_STORE && f != F_OVF && f != F_RET {
            return false;
        }
        let a = if lv::operand_a(f) {
            twin_val(bx, by, s.a, u.a)
        } else {
            s.a == u.a
        };
        let bb = if lv::operand_b(f) {
            twin_val(bx, by, s.b, u.b)
        } else {
            s.b == u.b
        };
        let c = if lv::operand_c(f) {
            twin_val(bx, by, s.c, u.c)
        } else {
            s.c == u.c
        };
        if !a || !bb || !c {
            return false;
        }
    }
    return true;
}

// Whether value `v` in block `bx` stands where value `w` in block `by` does (`twins`): one value from
// outside both blocks, or the results at the same place in each.
const fn twin_val(bx: Block, by: Block, v: Value, w: Value) bool {
    if v == VNONE || w == VNONE || (v & VPARAM) != 0 || (w & VPARAM) != 0 {
        return v == w;
    }
    let i = v & ~VFLAG;
    let j = w & ~VFLAG;
    if i >= bx.start && i < bx.start + bx.len {
        return (v & VFLAG) == (w & VFLAG) && j == by.start + i - bx.start;
    }
    return v == w && !(j >= by.start && j < by.start + by.len);
}

// The value whose byte `v` is and the byte's index (`combine_stores`): `trunc.i8 x` is byte 0 of `x`,
// `trunc.i8 (lshr x, 8j)` byte `j`. VNONE when `v` is neither.
fn stored_byte(b: &Body, v: Value) (Value, u32) {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_TRUNC || b.insts[v as usize].ty != T_I8 {
        return (VNONE, 0);
    }
    let x = b.insts[v as usize].a;
    if (x & (VPARAM | VFLAG)) == 0 && x != VNONE && b.insts[x as usize].op == O_LSHR {
        let s = const_of(b, b.insts[x as usize].b);
        let n = type_bits(b.type_of(x), 8) as u64;
        if s.is_some() && s.unwrap() % 8 == 0 && s.unwrap() < n {
            return (b.insts[x as usize].a, (s.unwrap() / 8) as u32);
        }
        return (VNONE, 0);
    }
    return (x, 0);
}

fn same_edge(b: &Body, x: u32, y: u32) bool {
    if b.edge_target(x) != b.edge_target(y) {
        return false;
    }
    for q in 0..b.edge_nargs(x) {
        if b.edge_arg(x, q) != b.edge_arg(y, q) {
            return false;
        }
    }
    return true;
}

// The edge branch `t` takes when its condition is `c`.
const fn side(t: Inst, c: u64) u32 {
    return if c != 0 {
        t.b
    } else {
        t.c
    };
}

// The bits of a value of type `ty`.
const fn width_mask(ty: u8, ptr: u32) u64 {
    let w = type_bits(ty, ptr);
    return if w >= 64 {
        ~0u64
    } else {
        (1u64 << w as u64) - 1
    };
}

// The edge branch or switch `t` takes for condition value `c`.
fn decided(b: &Body, t: Inst, c: u64) u32 {
    if t.op == O_BR {
        return side(t, c);
    }
    for q in 0..t.aux as u32 {
        if b.words[(t.b + q) as usize] == c {
            return b.switch_edge(t, q);
        }
    }
    return b.switch_edge(t, t.aux);
}

// The number of edges terminator `t` holds, and its edge `n`.
const fn edge_count(t: Inst) u32 {
    return if t.op == O_JMP {
        1u32
    } else if t.op == O_BR {
        2u32
    } else if t.op == O_SWITCH {
        t.aux as u32 + 1
    } else {
        0u32
    };
}

fn edge_at(b: &Body, t: Inst, n: u32) u32 {
    return if t.op == O_JMP {
        t.a
    } else if t.op == O_BR {
        side(t, (n == 0) as u64)
    } else {
        b.switch_edge(t, n)
    };
}

// Whether `c` calls body `j`'s own function.
fn self_call(pk: &Package, b: &Body, j: u32, c: Inst) bool {
    return c.op == O_CALL && pk.syms[b.syms[c.a as usize] as usize].def == j && pk.syms[b.syms[c.a as usize] as usize].kind == SK_FUNC;
}

// The call of body `j`'s own function (in the block from instruction `start`) whose result the instruction
// before return `ri` combines with another value by an integer add, mul, and, or or xor of the call's
// type (associative and commutative: accumulator recursion elimination, `Opt::tail_self`), the
// instructions between them pure, unable to trap and not reading the call's result; else NONE.
fn acc_call(pk: &Package, b: &Body, j: u32, start: u32, ri: u32) u32 {
    let oi = ri - 1;
    let o = b.insts[oi as usize];
    let ops = o.op == O_ADD || o.op == O_MUL || o.op == O_AND || o.op == O_OR || o.op == O_XOR;
    if oi < start || b.insts[ri as usize].a != oi || !ops || !is_int(o.ty) || o.ty == T_I128 || o.a == o.b {
        return NONE;
    }
    for side in 0..2 {
        let c = if side == 0 {
            o.a
        } else {
            o.b
        };
        if (c & (VPARAM | VFLAG)) != 0 || c < start || c >= oi || !self_call(pk, b, j, b.insts[c as usize]) || b.insts[c as usize].ty != o.ty {
            continue;
        }
        let mut ok = true;
        for i in c + 1..oi {
            let t = b.insts[i as usize];
            let traps = t.op >= O_SDIV && t.op <= O_UREM || t.op >= O_ADDO && t.op <= O_MULO || t.op == O_FPTOSI || t.op == O_FPTOUI;
            ok = ok && pure_op(t.op) && !traps && t.a != c && t.b != c && t.c != c;
        }
        if ok {
            return c;
        }
    }
    return NONE;
}

// `Opt::bytes_of`: a byte that is 0.
const NOBYTE: u8 = 0xFF;

// When flag `v` is a comparison of an integer `x` of up to 64 bits with a constant that holds (with
// `neg`, fails) on one interval of `x`: `x`, whether the order is signed, and the interval's bounds (each
// in `x`'s bits); else VNONE.
fn bound_by(pk: &Package, b: &Body, v: Value, neg: bool) (Value, bool, u64, u64) {
    let none = (VNONE, false, 0u64, 0u64);
    if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || b.insts[v as usize].op != O_ICMP {
        return none;
    }
    let c = b.insts[v as usize];
    let ty = b.type_of(c.a);
    if !is_int(ty) || ty == T_I128 {
        return none;
    }
    let (x, k, cond) = if const_of(b, c.b).is_some() {
        (c.a, const_of(b, c.b).unwrap(), c.aux)
    } else if const_of(b, c.a).is_some() {
        (c.b, const_of(b, c.a).unwrap(), mirror(c.aux))
    } else {
        return none;
    };
    if const_of(b, x).is_some() {
        return none;
    }
    let cond2 = if neg {
        opposite(cond)
    } else {
        cond
    };
    let w = type_bits(ty, pk.ptr_bytes);
    let m = width_mask(ty, pk.ptr_bytes);
    let sg = cond2 == C_SLT || cond2 == C_SLE || cond2 == C_SGT || cond2 == C_SGE;
    let (min, max) = if sg {
        (1u64 << (w - 1) as u64, (1u64 << (w - 1) as u64) - 1)
    } else {
        (0u64, m)
    };
    let kc = k & m;
    // An empty interval (`x <u 0`) is no range.
    return if (cond2 == C_ULT || cond2 == C_SLT) && kc != min {
        (x, sg, min, kc.wrapping_sub(1) & m)
    } else if cond2 == C_ULE || cond2 == C_SLE {
        (x, sg, min, kc)
    } else if (cond2 == C_UGT || cond2 == C_SGT) && kc != max {
        (x, sg, kc.wrapping_add(1) & m, max)
    } else if cond2 == C_UGE || cond2 == C_SGE {
        (x, sg, kc, max)
    } else {
        none
    };
}

// Whether `v` is an `or`, a shift or an `and`: what a byte permutation's operands are (`Opt::byte_perm`).
fn byte_part(b: &Body, v: Value) bool {
    if (v & (VPARAM | VFLAG)) != 0 || v == VNONE {
        return false;
    }
    let op = b.insts[v as usize].op;
    return op == O_OR || op == O_SHL || op == O_LSHR || op == O_AND;
}

// Whether each of the low `n` bytes of mask `m` is 0 or 0xFF.
const fn whole_bytes(m: u64, n: u32) bool {
    for j in 0..n {
        let x = m >> (8 * j) as u64 & 0xFF;
        if x != 0 && x != 0xFF {
            return false;
        }
    }
    return true;
}

// Whether edge `e` of `b` enters a block whose one instruction returns, and the value that return gives on
// that edge (the edge's argument for a parameter of the block; VNONE for none).
// The edge of branch `t` that is not `e`.
const fn other_edge(t: Inst, e: u32) u32 {
    return if t.b == e {
        t.c
    } else {
        t.b
    };
}

// Make each indirect call of `pk`'s bodies through the address of a function whose signature the call fits
// a direct call of it, before the bodies' calls order their optimization: the inliner may inline it (a
// local binding of a function called; LLVM's InstCombine).
fn direct_calls(pk: &mut Package) {
    // (body, instruction, the body's symbol number), found before any changes.
    let mut fix = Vector::<(u32, u32, u32)>::new();
    for k in 0..pk.bodies.len() {
        let b = &pk.bodies[k];
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            if t.op != O_CALLIND || (t.a & (VPARAM | VFLAG)) != 0 {
                continue;
            }
            let f = b.insts[t.a as usize];
            if f.op != O_SYMADDR || f.b != 0 {
                continue;
            }
            let sy = pk.syms[b.syms[f.a as usize] as usize];
            if sy.kind == SK_FUNC && sy.def != NONE && lv::call_fits(&pk.bodies[sy.def as usize], b, t.b) {
                fix.push((k as u32, i as u32, f.a));
            }
        }
    }
    for q in 0..fix.len() {
        let (k, i, s) = fix[q];
        let t = pk.bodies.index_mut(k as usize).insts.index_mut(i as usize);
        t.op = O_CALL;
        t.a = s;
    }
}

// At most RET_EDGES branch edges of a body return through blocks of their own (`ret_edges`).
const RET_EDGES: u32 = 8;

// Give each edge of a branch of `b` that passes arguments to a block that only returns a block of its own
// that returns the value (`ret_through`), up to RET_EDGES and but one edge into each such block (which stays
// reachable): the native code returns at once rather than move the arguments and jump (LLVM's tail
// duplication of return blocks; the walk makes a jump's own return). Whether any.
fn ret_edges(b: &mut Body) bool {
    let nb = b.blocks.len();
    // Per block, the edges into it.
    let mut into = Vector::<u32>::with_capacity(nb);
    for _ in 0..nb {
        into.push(0);
    }
    let mut es = Vector::<u32>::new();
    for k in 0..nb {
        let bk = b.blocks[k];
        if bk.len != 0 {
            b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut es);
            for q in 0..es.len() {
                into[b.edge_target(es[q]) as usize] += 1;
            }
        }
    }
    let mut n: u32 = 0;
    for k in 0..nb {
        let bk = b.blocks[k];
        if bk.len == 0 {
            continue;
        }
        let at = bk.start + bk.len - 1;
        let mut t = b.insts[at as usize];
        if t.op != O_BR {
            continue;
        }
        for side in 0..2 {
            let e = if side == 0 {
                t.b
            } else {
                t.c
            };
            let (ok, v) = ret_through(b, e);
            let j = b.edge_target(e);
            if !ok || b.edge_nargs(e) == 0 || n == RET_EDGES || into[j as usize] < 2 {
                continue;
            }
            into[j as usize] -= 1;
            let rb = b.blocks[j as usize];
            let r = b.add_block([]);
            b.blocks.index_mut(r as usize).flags = rb.flags;
            b.begin(r);
            let _ = b.emit(Inst { op: O_RET, ty: T_NONE, aux: 0, a: v, b: VNONE, c: VNONE }, b.locs[rb.start as usize]);
            if b.inl.len() != 0 {
                b.inl.push(b.inl[rb.start as usize]);
            }
            let ne = b.edge(r, []);
            if side == 0 {
                t.b = ne;
            } else {
                t.c = ne;
            }
            n += 1;
        }
        b.insts[at as usize] = t;
    }
    return n != 0;
}

fn ret_through(b: &Body, e: u32) (bool, Value) {
    let jb = b.blocks[b.edge_target(e) as usize];
    let r = b.insts[jb.start as usize];
    if jb.len != 1 || r.op != O_RET {
        return (false, VNONE);
    }
    if r.a != VNONE && (r.a & VPARAM) != 0 {
        let p = r.a & ~VPARAM;
        if p >= jb.param_start && p < jb.param_start + jb.param_len {
            return (true, b.edge_arg(e, p - jb.param_start));
        }
    }
    return (true, r.a);
}

const fn jump(e: u32) Inst {
    return Inst { op: O_JMP, ty: T_NONE, aux: 0, a: e, b: 0, c: 0 };
}

// An integer constant of type `ty` (`v` truncated to it), as the lowering writes one.
const fn iconst(ty: u8, v: u64) Inst {
    return Inst { op: O_ICONST, ty: ty, aux: 0, a: v as u32, b: (v >> 32) as u32, c: VNONE };
}

const fn is_nan(ty: u8, r: u64) bool {
    if ty == T_F32 {
        return (r & 0x7F800000) == 0x7F800000 && (r & 0x7FFFFF) != 0;
    }
    return (r & 0x7FF0000000000000) == 0x7FF0000000000000 && (r & 0xFFFFFFFFFFFFF) != 0;
}

const fn mix(h: u64, x: u64) u64 {
    let m = (h ^ x).wrapping_mul(0x9E3779B97F4A7C15);
    return m ^ m >> 31;
}

// The hash of call `t` of `b` by its callee, type and arguments.
fn call_hash(b: &Body, t: Inst) u64 {
    let mut h = mix(O_CALL as u64 | t.ty as u64 << 8 | t.aux as u64 << 16, b.syms[t.a as usize]);
    for q in 0..t.aux as u32 {
        h = mix(h, b.pool[(t.c + q) as usize]);
    }
    return h;
}

// Whether calls `x` and `y` of `b` call one function with the same arguments and type.
fn same_call(b: &Body, x: Inst, y: Inst) bool {
    if x.op != O_CALL || x.ty != y.ty || x.aux != y.aux || b.syms[x.a as usize] != b.syms[y.a as usize] {
        return false;
    }
    for q in 0..x.aux as u32 {
        if b.pool[(x.c + q) as usize] != b.pool[(y.c + q) as usize] {
            return false;
        }
    }
    return true;
}

const fn hash(t: Inst) u64 {
    return mix(mix(mix(t.op as u64 | t.ty as u64 << 8 | t.aux as u64 << 16, t.a), t.b), t.c);
}

const fn place_hash(addr: u32, off: u32, ty: u8, state: u32) u64 {
    return mix(mix(addr as u64 | ty as u64 << 32, off), state);
}
