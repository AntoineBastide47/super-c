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
// `Opt::ret_chunks` joins at most RUN_MAX result stores before a return.
const RUN_MAX: usize = 16;
// `same_params` compares the parameters of loop headers of at most SAME_MAX of them.
const SAME_MAX: u32 = 16;
// `Opt::sb` for an instruction more than one other block reads.
const MANY: u32 = 0xFFFFFFFE;
// `slice_of` looks through at most NONNULL_STEPS offsets, `nonnull` as many conversions.
const NONNULL_STEPS: u32 = 4;
// `zero_unless_zero` looks through at most ZERO_TEST_DEPTH extensions and negations.
const ZERO_TEST_DEPTH: u32 = 4;

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
// `flag_next` moves a flag's definition at most FLAG_REACH instructions.
const FLAG_REACH: u32 = 8;
// `memcmp_eq` expands counts of at most MEMCMP_MAX bytes, in at most MEMCMP_LOADS loads a side.
const MEMCMP_MAX: u64 = 32;
const MEMCMP_LOADS: u32 = 4;
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
// `Opt::result_into` follows at most RESULT_HOPS copies of a call's result.
const RESULT_HOPS: u32 = 4;
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
    // `divide` keeps scalar quotients and remainders by a constant for the loop vectorizer (`defer_div`,
    // until the loop transforms ran), and whether it kept one (`deferred`).
    defer_div: bool,
    deferred: bool,
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
    aggint: u64, // per such parameter `k` below 32 and 8-byte chunk `c`, bit 2k + c: an integer load reads it
    aggload: [u32; 64], // per such chunk, its load this walk made at the entry's start (`agg_chunk`), NONE
    rslot: Vector<u32>, // per slot, the one call whose aggregate result it holds, which only loads read, else NONE
    rcall: bool, // a call has an aggregate result of at most 16 bytes (`operands`; `result_slots`)
    rload: Vector<Value>, // per slot and 8-byte chunk (2 per slot), its load after that call (`res_chunk`), NONE
    made: Map<u64, u32>, // a made constant's hash to the constant
    moved: Vector<bool>,
    nofx: Vector<bool>, // per instruction, a call that writes no memory and comes back: it goes when unused
    hoisted: Vector<u64>, // block << 32 | instruction, in the order they moved
    pnew: Vector<bool>, // per block, a preheader `preheaders` made
    touched: Vector<bool>, // per block, one `promote_places` changed: a preheader or a block of a loop
    // `reassociate`'s scratch: per value its uses and its one user (NONE: an edge's or none), a chain's
    // nodes and leaves, the partial sums (depth << 32 | value).
    rcount: Vector<u32>,
    ruser: Vector<u32>,
    rnodes: Vector<u32>,
    rleaves: Vector<u32>,
    rsums: Vector<u64>,
    pre: Vector<u64>, // instruction << 32 | an instruction the walk made to run right before it, in order
    unbiased: Map<u32, u32>, // per indexed address with an offset, the address without it (`visit`)
    merged: bool, // the last rebuild merged blocks
    selected: bool, // the last walk made selects (`diamond`), which no walk simplified
    refold: bool, // the last walk folded a value its readers saw before (`null_test`, `merge_exits`)
    rethru: bool, // `thread` made a jump a return (`ret_folded`)
    // The last walk dropped a store in a loop, whose loads may leave it now, or one before a call, whose
    // loads may move past it (`sink_load`).
    unstored: bool,
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
    /// Per slot, whether its address reaches memory or a callee (`privates`): an escape but a by-value
    /// aggregate argument the backend copies (`arg_copied`).
    pleak: Vector<bool>,
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
    pok: Vector<bool>, // per block parameter, whether `ptr_params` makes it a pointer
    sn: Vector<u32>, // per instruction, the reads in its own block (`sink_heads`)
    uargs: Vector<Value>, // the arguments of an edge `unnest` makes
    sb: Vector<u32>, // per instruction, the one other block that reads it, NONE or MANY (`sink_heads`)
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
            defer_div: false,
            deferred: false,
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
            nofx: Vector::<bool>::new(),
            hoisted: Vector::<u64>::new(),
            pnew: Vector::<bool>::new(),
            touched: Vector::<bool>::new(),
            rcount: Vector::<u32>::new(),
            ruser: Vector::<u32>::new(),
            rnodes: Vector::<u32>::new(),
            rleaves: Vector::<u32>::new(),
            rsums: Vector::<u64>::new(),
            pre: Vector::<u64>::new(),
            unbiased: Map::<u32, u32>::new(),
            merged: false,
            selected: false,
            refold: false,
            rethru: false,
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
            pleak: Vector::<bool>::new(),
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
            aggint: 0,
            aggload: [NONE; 64],
            rslot: Vector::<u32>::new(),
            rcall: false,
            rload: Vector::<Value>::new(),
            made: Map::<u64, u32>::new(),
            pmap: Vector::<u32>::new(),
            params: Vector::<u8>::new(),
            live: Vector::<bool>::new(),
            uses: Vector::<Value>::new(),
            pok: Vector::<bool>::new(),
            sn: Vector::<u32>::new(),
            uargs: Vector::<Value>::new(),
            sb: Vector::<u32>::new(),
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

    // The block parameters of `b` (but the entry's) of the pointers' integer type that every edge passes as
    // `ptrtoint` of a pointer and that only `inttoptr` reads: pointers, which the edges pass, each
    // `inttoptr` of one the parameter itself (a `ptradd` of 0, which the walk folds). An `Option<&T>` as a
    // pointer or 0 (an iterator's `next`) gives such an integer. Whether any changed.
    fn ptr_params(self: &mut Self, pk: &Package, b: &mut Body) bool {
        let np = b.params.len();
        let it = int_type_of(pk.ptr_bytes);
        let e0 = b.blocks[0].param_len as usize;
        fill(&mut self.pok, np, false);
        let mut any = false;
        for q in e0..np {
            self.pok[q] = b.params[q] == it;
            any = any || self.pok[q];
        }
        // An edge must pass `ptrtoint` of a pointer: without one, no parameter qualifies.
        let mut casts = false;
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            casts = casts || t.op == O_PTRTOINT && b.type_of(t.a) == T_PTR;
        }
        if !any || !casts {
            return false;
        }
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                self.uses.truncate(0);
                lv::uses_into(b, t, &mut self.uses);
                for u in 0..self.uses.len() {
                    let v = self.uses[u];
                    if (v & VPARAM) != 0 && v != VNONE && !(t.op == O_INTTOPTR && t.a == v) {
                        self.pok[(v & ~VPARAM) as usize] = false;
                    }
                }
                if !is_terminator(t.op) {
                    continue;
                }
                b.succ_edges(t, &mut self.edges);
                for x in 0..self.edges.len() {
                    let ed = self.edges[x];
                    let ps = b.blocks[b.edge_target(ed) as usize].param_start;
                    for q in 0..b.edge_nargs(ed) {
                        let a = b.edge_arg(ed, q);
                        if (a & VPARAM) != 0 && a != VNONE {
                            self.pok[(a & ~VPARAM) as usize] = false;
                        }
                        if !is_op(b, a, O_PTRTOINT) || b.type_of(b.insts[a as usize].a) != T_PTR {
                            self.pok[(ps + q) as usize] = false;
                        }
                    }
                }
            }
        }
        any = false;
        for q in e0..np {
            if self.pok[q] {
                b.params[q] = T_PTR;
                any = true;
            }
        }
        if !any {
            return false;
        }
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                if t.op == O_INTTOPTR && (t.a & VPARAM) != 0 && t.a != VNONE && self.pok[(t.a & ~VPARAM) as usize] {
                    b.insts[i as usize] = Inst { op: O_PTRADD, ty: T_PTR, aux: 0, a: t.a, b: VNONE, c: 0 };
                }
                if !is_terminator(t.op) {
                    continue;
                }
                b.succ_edges(t, &mut self.edges);
                for x in 0..self.edges.len() {
                    let ed = self.edges[x];
                    let ps = b.blocks[b.edge_target(ed) as usize].param_start;
                    for q in 0..b.edge_nargs(ed) {
                        if self.pok[(ps + q) as usize] {
                            let a = b.edge_arg(ed, q);
                            b.pool[(ed + 2 + q) as usize] = b.insts[a as usize].a;
                        }
                    }
                }
            }
        }
        return true;
    }

    // Each loop whose header only jumps into the header of a loop inside it, passing its own parameters
    // (each once), so that the inner loop goes on from where it stopped: the inner loop's back edges go to
    // the outer header, which passes their arguments on, and its other parameters unchanged. The two loops
    // are one, which steps once per item (a `filter` that `count` drains: the search for the next match
    // and the count, one loop the vectorizer reads). Whether any did.
    pub(package) fn unnest(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if b.naked {
            return false;
        }
        self.tables(pk, b, K_NEST);
        let mut any = false;
        for h1 in 0..b.blocks.len() as u32 {
            let hb = b.blocks[h1 as usize];
            let t = term(b, h1);
            if self.inner[h1 as usize] != h1 || hb.len != 1 || t.op != O_JMP {
                continue;
            }
            let h2 = b.edge_target(t.a);
            if h2 == h1 || self.inner[h2 as usize] != h2 || self.lparent[h2 as usize] != h1 || self.pred_at[h2 as usize + 1] - self.pred_at[h2 as usize] < 2 {
                continue;
            }
            // The outer header's arguments: each a parameter of its own, none twice.
            let np = hb.param_len as u32;
            let na = b.edge_nargs(t.a);
            let mut ok = true;
            for q in 0..na {
                let a = b.edge_arg(t.a, q);
                let r = a & ~VPARAM;
                ok = ok && (a & VPARAM) != 0 && a != VNONE && r >= hb.param_start && r < hb.param_start + np;
                for q2 in 0..q {
                    ok = ok && b.edge_arg(t.a, q2) != a;
                }
            }
            // The inner header's other predecessors: blocks of its loop, which end in a jump or a branch.
            for x in self.pred_at[h2 as usize]..self.pred_at[h2 as usize + 1] {
                let s = self.preds[x as usize];
                let op = term(b, s).op;
                ok = ok && (s == h1 || self.dominates(h2, s) && (op == O_JMP || op == O_BR));
            }
            if !ok {
                continue;
            }
            for x in self.pred_at[h2 as usize]..self.pred_at[h2 as usize + 1] {
                let s = self.preds[x as usize];
                if s == h1 || x > self.pred_at[h2 as usize] && self.preds[x as usize - 1] == s {
                    continue;
                }
                let st = term(b, s);
                for side in 0..2u32 {
                    let e = if side == 0 {
                        if st.op == O_JMP {
                            st.a
                        } else {
                            st.b
                        }
                    } else if st.op == O_BR {
                        st.c
                    } else {
                        NONE
                    };
                    if e == NONE || b.edge_target(e) != h2 {
                        continue;
                    }
                    // The outer header's parameters: the edge's argument where the outer header passes it on,
                    // else itself.
                    self.uargs.truncate(0);
                    for r in 0..np {
                        let pv = VPARAM | hb.param_start + r;
                        let mut v = pv;
                        for q in 0..na {
                            if b.edge_arg(t.a, q) == pv {
                                v = b.edge_arg(e, q);
                            }
                        }
                        self.uargs.push(v);
                    }
                    let ne = b.edge(h1, &self.uargs);
                    let at = (b.blocks[s as usize].start + b.blocks[s as usize].len - 1) as usize;
                    if st.op == O_JMP {
                        b.insts.index_mut(at).a = ne;
                    } else if side == 0 {
                        b.insts.index_mut(at).b = ne;
                    } else {
                        b.insts.index_mut(at).c = ne;
                    }
                }
            }
            any = true;
        }
        if any {
            self.forget();
        }
        return any;
    }

    // Each loop header's exit merged with the exit of the block it enters in the loop (`merge_exits`): a
    // loop that stops at the end of either of two slices tests one bound, the counted shape the
    // vectorizer reads. Whether any did.
    pub(package) fn merge_heads(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if b.naked {
            return false;
        }
        self.tables(pk, b, K_MEM);
        self.fresh(b);
        self.pure.clear();
        self.made.clear();
        let mut any = false;
        for h in 0..b.blocks.len() as u32 {
            let hb = b.blocks[h as usize];
            if self.inner[h as usize] == h && term(b, h).op == O_BR && self.merge_exits(b, h, hb.start + hb.len - 1) {
                any = true;
            }
        }
        if any {
            self.rebuild(b);
        }
        self.forget();
        return any;
    }

    // The instructions of each loop header that compute a value from their operands alone and that only the
    // block the header enters inside the loop reads, or one block it dominates (a step the back edge
    // passes), when that block has no other predecessor: moved to its start, in their order. The header is then a test alone, the counted shape the vectorizer and the
    // unroller read (an iterator's `next` computes its item before the test). Whether any moved.
    pub(package) fn sink_heads(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if b.naked {
            return false;
        }
        // The rebuild reads the slots the memory analysis finds read (`dead_store`).
        self.tables(pk, b, K_MEM);
        let nb = b.blocks.len();
        let ni = b.insts.len();
        let mut any = false;
        for h in 0..nb {
            any = any || self.inner[h] == h as u32;
        }
        if !any {
            return false;
        }
        // The reads of each instruction: in its own block, and the one other block.
        fill(&mut self.sn, ni, 0);
        fill(&mut self.sb, ni, NONE);
        for k in 0..nb {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                self.uses.truncate(0);
                lv::uses_into(b, t, &mut self.uses);
                if is_terminator(t.op) {
                    b.succ_edges(t, &mut self.edges);
                    for e in 0..self.edges.len() {
                        for q in 0..b.edge_nargs(self.edges[e]) {
                            self.uses.push(b.edge_arg(self.edges[e], q));
                        }
                    }
                }
                for u in 0..self.uses.len() {
                    let v = self.uses[u];
                    if (v & (VPARAM | VFLAG)) != 0 || v == VNONE {
                        continue;
                    }
                    if self.blk_of[v as usize] == k as u32 {
                        self.sn[v as usize] += 1;
                    } else if self.sb[v as usize] == NONE || self.sb[v as usize] == k as u32 {
                        self.sb[v as usize] = k as u32;
                    } else {
                        self.sb[v as usize] = MANY;
                    }
                }
            }
        }
        self.fresh(b);
        any = false;
        for h in 0..nb as u32 {
            let hb = b.blocks[h as usize];
            let t = term(b, h);
            if self.inner[h as usize] != h || t.op != O_BR || same_edge(b, t.b, t.c) {
                continue;
            }
            let x = b.edge_target(t.b);
            let y = b.edge_target(t.c);
            let u = if self.inner[x as usize] == h && x != h && self.inner[y as usize] != h {
                x
            } else if self.inner[y as usize] == h && y != h && self.inner[x as usize] != h {
                y
            } else {
                NONE
            };
            if u == NONE || b.blocks[u as usize].len < 2 || self.pred_at[u as usize + 1] - self.pred_at[u as usize] != 1 {
                continue;
            }
            // From the last instruction back: one that moves no longer counts as a read in the header.
            let n0 = self.pre.len();
            for j in 1..hb.len {
                let i = hb.start + hb.len - 1 - j;
                let s = b.insts[i as usize];
                let op = s.op;
                let movable = op >= O_ADD && op <= O_INTTOPTR && !(op >= O_SDIV && op <= O_UREM) && !(op >= O_ADDO && op <= O_MULO) || op == O_PTRADD || op == O_SELECT;
                let r = self.sb[i as usize];
                if !movable || self.sn[i as usize] != 0 || r == NONE || r == MANY || r != u && !self.dominates(u, r) {
                    continue;
                }
                self.moved[i as usize] = true;
                self.blk_of[i as usize] = u;
                self.pre.push(b.blocks[u as usize].start as u64 << 32 | i as u64);
                self.uses.truncate(0);
                lv::uses_into(b, s, &mut self.uses);
                for q in 0..self.uses.len() {
                    let v = self.uses[q];
                    if (v & (VPARAM | VFLAG)) == 0 && v != VNONE && self.blk_of[v as usize] == h {
                        self.sn[v as usize] -= 1;
                        if self.sb[v as usize] == NONE {
                            self.sb[v as usize] = u;
                        } else if self.sb[v as usize] != u {
                            self.sb[v as usize] = MANY;
                        }
                    }
                }
            }
            // In their order: they were found last first.
            let n1 = self.pre.len();
            for q in 0..(n1 - n0) / 2 {
                let a = self.pre[n0 + q];
                self.pre[n0 + q] = self.pre[n1 - 1 - q];
                self.pre[n1 - 1 - q] = a;
            }
            any = any || n1 != n0;
        }
        if any {
            self.rebuild(b);
        }
        self.forget();
        return any;
    }

    /// `lu::pointer_ivs` on body `b` of package `pk`, then the rebuild, which drops what it left unused (the
    /// addresses its accesses no longer read, a counter whose exit test went) and renumbers the body.
    /// Whether it changed it.
    pub(package) fn pointer_ivs(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if !lu::pointer_ivs(b) {
            return false;
        }
        // The rebuild reads the block map alone (`fresh`).
        self.forget();
        self.tables(pk, b, K_GRAPH);
        self.fresh(b);
        self.rebuild(b);
        self.forget();
        return true;
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
        self.rethru = false;
        if self.ptr_params(pk, b) {
            self.forget();
        }
        let slotted = self.param_slots(pk, b);
        // `thread` computes the graph and the dominators: they stand when it moves no edge (`kept`).
        let threaded = self.thread(pk, b) || slotted;
        self.tables(pk, b, K_NEST);
        // The walk hoists into preheaders: the memory facts are those of the body that has them.
        let entered = self.preheaders(b);
        self.tables(pk, b, K_MEM);
        self.slot_writes(pk, b);
        let changed = self.walk(pk, b) || force || threaded || entered || self.unused_call(b);
        if entered {
            self.unenter(b);
        }
        if changed {
            self.rebuild(b);
        }
        if b.slots.len() == 0 || !self.promote {
            let r = self.thread_rounds(pk, b) || changed;
            let w = self.rewalk(pk, b);
            return self.settle(pk, b) || w || r;
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
            let w = self.rewalk(pk, b);
            return self.settle(pk, b) || w || r;
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
        let _ = self.settle(pk, b);
        return true;
    }

    // The block parameters the walk left integers of pointers (`ptr_params`) as pointers, and two more walks:
    // the first folds their reads (a null test of one is a constant), the second what those folds leave (an
    // `and` with that constant). Whether it ran.
    fn settle(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if !self.ptr_params(pk, b) {
            return false;
        }
        self.forget();
        for _ in 0..2 {
            self.tables(pk, b, K_MEM);
            self.slot_writes(pk, b);
            let _ = self.walk(pk, b);
            self.rebuild(b);
        }
        return true;
    }

    // Blocks the last rebuild merged are one block now, the selects the last walk made are new, a fold of
    // the last walk came after its readers (`refold`), a jump this `run` made a return left the values it
    // passed dead, which the walk counted where it would make two returns one (`rethru`, `ret_diamond`), and
    // a loop may write less: one more walk numbers and forwards across the blocks (a load the second
    // repeats), simplifies the selects and hoists the loads. Whether it ran.
    fn rewalk(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if !self.merged && !self.selected && !self.unstored && !self.refold && !self.rethru {
            return false;
        }
        self.rethru = false;
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
            ((pk.fmath | b.fmath) & FM_ASSOC) != 0,
            pk.hfa_regs,
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
        self.unr.apairs = pk.apairs;
        self.unr.vmulh = pk.vec_mulh;
        self.unr.vaccs = pk.vec_accs;
        self.unr.vsat = pk.vec_sat;
        self.unr.vabsd = pk.vec_absd;
        self.unr.vsumw = pk.vec_sumw;
        self.unr.vfma = pk.vfloat && pk.fma;
        self.unr.vfn.truncate(0);
        for s in 0..b.syms.len() {
            let sy = pk.syms[b.syms[s] as usize];
            let f = if pk.vfloat && sy.kind == SK_FUNC && sy.def == NONE {
                lu::lane_fn(pk.spell(sy.name))
            } else {
                0u8
            };
            let round = f == core::SIMD_FLOOR || f == core::SIMD_CEIL || f == core::SIMD_TRUNC;
            self.unr.vfn.push(
                if round && !pk.vround || f == core::SIMD_FMA && !pk.fma {
                    0u8
                } else {
                    f
                },
            );
        }
        let any = self.unr.run(
            b,
            pk.ptr_bytes,
            pk.fmath | b.fmath,
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
    /// loop, so the loop's path takes no branch around the exit's moves. Not an exit whose arguments the
    /// other side passes too: an exit parameter shares the register of the loop's parameter that takes the
    /// same value (`lv::Live::share`), and the back edge's moves before the branch serve both. Whether any.
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
            if b.edge_nargs(e) == 0 || args_among(
                b,
                e,
                if ib {
                    t.b
                } else {
                    t.c
                },
            ) {
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
        if sites.len() == 0 || lv::frame_escapes(b, []) {
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
    /// pointer, or in a `static mut`, from outside the loop (LLVM's LICM scalar promotion), when the loop has
    /// a preheader, calls nothing, orders no memory (an atomic, a fence) and no other access of it may touch
    /// the place's bytes. A data race is undefined behavior: with no synchronizing operation and no
    /// suspension point in the loop, no other thread may read or write a static meanwhile; the store back is
    /// then made only when the value differs from the one loaded before the loop (a loop that wrote nothing
    /// writes nothing, as another thread may write the static outside such a run). A new slot takes the
    /// place's accesses in the loop, loaded from the place in a block between the preheader and the loop and
    /// stored back to it in a block on each edge out; the promotion of `run` makes the slot values. Whether
    /// any loop's did.
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
            let stat = self.static_place(pk, s);
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
                    let n0 = b.insts.len();
                    let w = b.emit(Inst { op: O_LOAD, ty: ty, aux: al, a: sa, b: VNONE, c: 0 }, l);
                    if stat {
                        // A static: stored back only when the loop changed it, then on along a copy of `e`.
                        let (x, y) = if ty == T_F32 || ty == T_F64 {
                            let it = if ty == T_F32 {
                                T_I32
                            } else {
                                T_I64
                            };
                            (
                                b.emit(Inst { op: O_BITCAST, ty: it, aux: 0, a: w, b: VNONE, c: VNONE }, l),
                                b.emit(Inst { op: O_BITCAST, ty: it, aux: 0, a: v, b: VNONE, c: VNONE }, l)
                            )
                        } else {
                            (w, v)
                        };
                        let ne = b.emit(Inst { op: O_ICMP, ty: T_I8, aux: C_NE, a: x, b: y, c: VNONE }, l);
                        self.uargs.truncate(0);
                        for a in 0..b.edge_nargs(e) {
                            self.uargs.push(b.edge_arg(e, a));
                        }
                        let skip = b.edge(to, &self.uargs);
                        let sk = b.add_block(none);
                        b.blocks.index_mut(sk as usize).flags = b.blocks[ek as usize].flags;
                        let into = b.edge(sk, noargs);
                        let _ = b.emit(Inst { op: O_BR, ty: T_NONE, aux: 0, a: ne, b: into, c: skip }, l);
                        b.begin(sk);
                    }
                    let _ = b.emit(Inst { op: O_STORE, ty: T_NONE, aux: st.aux, a: st.a, b: w, c: st.c }, l);
                    let _ = b.emit(jump(e), l);
                    if b.inl.len() != 0 {
                        for _ in n0..b.insts.len() {
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

    /// Regroup each integer sum of `b` that a chain of additions makes, each used once by the next in its
    /// block (`a + b + c + d`), into a tree of less depth where its leaves allow: on the positions of the
    /// chain's additions, in order, each adds the two partial sums of least depth there (ties: the earliest),
    /// and the last gives the chain's value (the MachineCombiner's reassociation; exact, as an integer sum
    /// wraps). A chain of fewer than 4 leaves or more than 64, or one no regrouping makes shallower, stays.
    pub(package) fn reassociate(self: &mut Self, b: &mut Body) {
        let ni = b.insts.len();
        fill(&mut self.rcount, ni, 0);
        fill(&mut self.ruser, ni, NONE);
        let mut ops = Vector::<Value>::new();
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                lv::uses(b, t, &mut ops);
                if t.op == O_JMP || t.op == O_BR || t.op == O_SWITCH {
                    b.succ_edges(t, &mut self.edges);
                    for q in 0..self.edges.len() {
                        for x in 0..b.edge_nargs(self.edges[q]) {
                            ops.push(b.edge_arg(self.edges[q], x));
                        }
                    }
                }
                for q in 0..ops.len() {
                    let v = ops[q];
                    if v != VNONE && (v & (VPARAM | VFLAG)) == 0 {
                        self.rcount[v as usize] += 1;
                        self.ruser[v as usize] = if t.op == O_JMP || t.op == O_BR || t.op == O_SWITCH {
                            NONE
                        } else {
                            i
                        };
                    }
                }
            }
        }
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            // Each root once; a chain's nodes precede its root.
            for r in bk.start..bk.start + bk.len {
                if !self.sum_node(b, bk, r) || self.chained(b, bk, r) {
                    continue;
                }
                // The chain's nodes and leaves: at most the block's instructions each.
                self.rnodes.truncate(0);
                self.rleaves.truncate(0);
                self.rnodes.push(r);
                let mut at: usize = 0;
                while at < self.rnodes.len() {
                    let t = b.insts[self.rnodes[at] as usize];
                    for v in [t.a, t.b] {
                        if (v & (VPARAM | VFLAG)) == 0 && self.chained(b, bk, v) && self.ruser[v as usize] == self.rnodes[at] {
                            self.rnodes.push(v);
                        } else {
                            self.rleaves.push(v);
                        }
                    }
                    at += 1;
                }
                let nl = self.rleaves.len();
                if nl < 4 || nl > 64 {
                    continue;
                }
                // The chain's depth now, by its nodes from the root down: each node's below its parent.
                self.rsums.truncate(0);
                self.rnodes.sort();
                for x in 0..self.rnodes.len() {
                    let t = b.insts[self.rnodes[x] as usize];
                    let mut d: u32 = 0;
                    for v in [t.a, t.b] {
                        for y in 0..x {
                            if self.rnodes[y] == v {
                                d = d.max((self.rsums[y] >> 32) as u32);
                            }
                        }
                    }
                    self.rsums.push((d + 1) as u64 << 32 | self.rnodes[x] as u64);
                }
                let depth = (self.rsums[self.rsums.len() - 1] >> 32) as u32;
                if self.regroup(b, bk, false) >= depth {
                    continue;
                }
                let _ = self.regroup(b, bk, true);
            }
        }
    }

    // `reassociate`'s regrouping of chain `rnodes` (in order) over `rleaves` in block `bk`: written into the
    // nodes when `write`; the depth of the result.
    fn regroup(self: &mut Self, b: &mut Body, bk: Block, write: bool) u32 {
        self.rsums.truncate(0);
        let mut used: u64 = 0;
        let mut last: u32 = 0;
        for x in 0..self.rnodes.len() {
            let p = self.rnodes[x];
            // The leaves defined before the node, each once (at most 64, `reassociate`).
            for y in 0..self.rleaves.len() {
                let v = self.rleaves[y];
                let inside = (v & (VPARAM | VFLAG)) == 0 && v >= bk.start && v < bk.start + bk.len;
                if (used >> y as u64 & 1) == 0 && (!inside || v < p) {
                    used |= 1u64 << y as u64;
                    self.rsums.push(v);
                }
            }
            // The two of least depth, the earlier first on a tie.
            let mut pick: [usize; 2] = [0, 0];
            for z in 0..2usize {
                let mut best = self.rsums.len();
                for q in 0..self.rsums.len() {
                    if (best == self.rsums.len() || self.rsums[q] >> 32 < self.rsums[best] >> 32) && !(z == 1 && q == pick[0]) {
                        best = q;
                    }
                }
                pick[z] = best;
            }
            let (s0, s1) = (self.rsums[pick[0]], self.rsums[pick[1]]);
            let d = ((s0 >> 32).max(s1 >> 32) + 1) as u32;
            if write {
                let t = b.insts[p as usize];
                b.insts[p as usize] = Inst { op: O_ADD, ty: t.ty, aux: 0, a: s0 as u32, b: s1 as u32, c: VNONE };
            }
            let hi = pick[0].max(pick[1]);
            let lo = pick[0].min(pick[1]);
            let _ = self.rsums.remove(hi);
            let _ = self.rsums.remove(lo);
            self.rsums.push(d as u64 << 32 | p as u64);
            last = d;
        }
        return last;
    }

    // Whether instruction `i` of block `bk` is an integer addition `reassociate` may regroup.
    const fn sum_node(self: &Self, b: &Body, bk: Block, i: u32) bool {
        let t = b.insts[i as usize];
        return i >= bk.start && i < bk.start + bk.len && t.op == O_ADD && is_int(t.ty) && t.ty != T_I128 && !is_vec(
            t.ty,
        );
    }

    // Whether value `v` is a chain's inner node in block `bk` (`reassociate`): an addition `sum_node` whose
    // one use is another such addition of its type.
    const fn chained(self: &Self, b: &Body, bk: Block, v: Value) bool {
        if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || !self.sum_node(b, bk, v) || self.rcount[v as usize] != 1 {
            return false;
        }
        let u = self.ruser[v as usize];
        return u != NONE && self.sum_node(b, bk, u) && b.insts[u as usize].ty == b.insts[v as usize].ty;
    }

    // The store that names the place `promote_places` keeps in a register for loop `h`: an innermost loop
    // with a preheader no earlier loop's change touched, whose blocks end in jumps and branches and hold no
    // call nor other access of memory but loads and stores. The place: a store's address from outside the
    // loop, of an exclusive class or into a data symbol the package defines (`static_place`), and an offset;
    // a scalar that a load of the loop reads too, whose load before the loop cannot fault; every other
    // access of the loop of another class (neither may be any), of other bytes of the same address, of
    // another object, or of another type tag. A static whose address another pointer may hold stays in
    // memory when an access through such a pointer may touch it. NONE when none.
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
                if cand == NONE && t.op == O_STORE && (t.aux & MEM_VOLATILE) == 0 && self.outside(t.a, h) && (self.loop_acc(
                    i,
                    h,
                ) >= CL_NOALIAS && self.loop_acc(i, h) < CL_MANY || self.static_place(pk, i)) {
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
                let o = self.aobj[i as usize];
                let apart = c < CL_MANY && c != cls || c == cls && t.a == s.a && (qlo + type_bytes(tt, pk.ptr_bytes) as i64 <= lo || lo + n <= qlo) || (c >= CL_MANY || c == CL_OTHER) && tbaa(
                    t,
                ) != 0 && tbaa(s) != 0 && tbaa(t) != tbaa(s) || o != NONE && self.aobj[cand as usize] != NONE && o != self.aobj[cand as usize];
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

    // Whether store `i` of the body writes a `static mut`: a writable data object the package defines
    // (`aobj`), also a thread-local one: a loop that calls nothing has no suspension point, so it runs on one
    // thread and the address from before it is its copy's.
    fn static_place(self: &Self, pk: &Package, i: u32) bool {
        let o = self.aobj[i as usize];
        if o == NONE || (o & (lu::OBJ_SLOT | lu::OBJ_PRIVATE | lu::OBJ_FRESH)) != 0 {
            return false;
        }
        let y = pk.syms[o as usize];
        return (y.kind == SK_DATA || y.kind == SK_TLS) && y.def != NONE && !pk.data[y.def as usize].readonly;
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

    // `ops_at`, `ops_arg`, `ops` for `b`: the passes over one body read its instructions' operands once;
    // `rcall`.
    fn operands(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        self.ops_at.truncate(0);
        self.ops_arg.truncate(0);
        self.ops.truncate(0);
        self.ops_dst.truncate(0);
        self.rcall = false;
        for i in 0..ni {
            let t = b.insts[i];
            self.rcall = self.rcall || (t.op == O_CALL || t.op == O_CALLIND) && (b.pool[t.b as usize + 2] & AGG) != 0 && b.pool[(b.pool[t.b as usize + 2] & ~AGG) as usize] <= 16;
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
                    o + n.unwrap() as i64 * scale_of(t) as i64 + (t.c as i32) as i64
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
        self.privates(pk, b);
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

    // Whether a call the walk found removable (`nofx`) is a value nothing reads: the rebuild drops it.
    fn unused_call(self: &mut Self, b: &Body) bool {
        let mut any = false;
        for i in 0..self.nofx.len() {
            any = any || self.nofx[i];
        }
        if !any {
            return false;
        }
        let ni = b.insts.len();
        let mut used = Vector::<bool>::new();
        used.resize_default(ni);
        for i in 0..ni {
            let t = b.insts[i];
            lv::uses_into(b, t, &mut self.uses);
            if is_terminator(t.op) {
                b.succ_edges(t, &mut self.edges);
                for e in 0..self.edges.len() {
                    for q in 0..b.edge_nargs(self.edges[e]) {
                        self.uses.push(b.edge_arg(self.edges[e], q));
                    }
                }
            }
            for u in 0..self.uses.len() {
                let v = self.uses[u];
                if v != VNONE && (v & (VPARAM | VFLAG)) == 0 && v as usize < ni {
                    used[v as usize] = true;
                }
            }
        }
        for i in 0..self.nofx.len().min(ni) {
            if self.nofx[i] && !used[i] {
                return true;
            }
        }
        return false;
    }

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
        fill(&mut self.nofx, ni, false);
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
        self.aggint = 0;
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
                    let kp = (v & ~VPARAM) - ps;
                    if load && kp < 32 && t.c < 16 && is_int(t.ty) && t.ty != T_PTR && t.ty != T_I128 {
                        self.aggint |= 1u64 << (2 * kp + t.c / 8) as u64;
                    }
                }
            }
        }
        return out;
    }

    // Store or constant fill `i`, the last before block `blk`'s `ret`, of the run of them before it (past
    // instructions that touch no memory and loads of the body's own slots) to the address of an aggregate result of at most 16 bytes
    // (`ret_part`): each 8-byte chunk (of 1, 2, 4 or 8 bytes) whose every leaf byte (of the result's
    // layout; the others are padding) two or more of the run write, each byte once, one of them with an
    // integer, is one store of their values joined (bits of a float as an integer, a fill's bytes as a
    // constant, each shifted to its offset, padding 0). The targets return such a chunk in one integer
    // register, which the code generator moves the store's value into (`ret_stores`). Whether it did.
    fn ret_chunks(self: &mut Self, pk: &Package, b: &mut Body, blk: u32, i: u32) bool {
        let rt = b.pool[b.sig as usize + 2];
        if b.sig == NONE || (rt & AGG) == 0 || b.pool[(rt & ~AGG) as usize] > 16 {
            return false;
        }
        let size = b.pool[(rt & ~AGG) as usize];
        let pv = VPARAM | b.blocks[0].param_start + b.pool[b.sig as usize];
        let bk = b.blocks[blk as usize];
        // The run, from `i` back, at most RUN_MAX.
        let mut run = StaticVector::<u32, RUN_MAX>::new();
        let mut j = i + 1;
        while j > bk.start && run.len() < RUN_MAX {
            j -= 1;
            let s = b.insts[j as usize];
            // Past a load this walk replaced, and one of the body's own slot, which the result's bytes (the
            // caller's) are not.
            if s.op != O_STORE && s.op != O_MEMSET && (pure_op(s.op) || s.op == O_LOAD && (self.repl[j as usize] != VNONE || is_op(
                b,
                s.a,
                O_SLOTADDR,
            ))) {
                continue;
            }
            if self.repl[j as usize] != VNONE || ret_part(b, pk.ptr_bytes, j, pv).0 == NONE {
                break;
            }
            run.push(j);
        }
        let mut any = false;
        for c in 0..(size + 7) / 8 {
            let cs = (size - 8 * c).min(8);
            if (cs & cs - 1) != 0 {
                continue;
            }
            // Its parts: each within the chunk, their bytes once each, one an integer's.
            let mut mask: u32 = 0;
            let mut n: u32 = 0;
            let mut int = false;
            let mut ok = true;
            for r in 0..run.len() {
                let (off, sz, x, _) = ret_part(b, pk.ptr_bytes, run[r], pv);
                if off + sz <= 8 * c || off >= 8 * c + cs {
                    continue;
                }
                if off < 8 * c || off + sz > 8 * c + cs {
                    ok = false;
                    continue;
                }
                let m = (1u32 << sz) - 1 << off - 8 * c;
                ok = ok && (mask & m) == 0;
                mask |= m;
                n += 1;
                int = int || x == VNONE || is_int(b.type_of(x));
            }
            // The chunk's leaf bytes.
            let lay = (rt & ~AGG) as usize;
            let mut leaves: u32 = 0;
            for q in 0..b.pool[lay + 2] {
                let lo = b.pool[lay + 3 + 2 * q as usize];
                let ls = type_bytes(b.pool[lay + 4 + 2 * q as usize] as u8, pk.ptr_bytes);
                if lo >= 8 * c && lo + ls <= 8 * c + cs {
                    leaves |= (1u32 << ls) - 1 << lo - 8 * c;
                } else if lo < 8 * c + cs && lo + ls > 8 * c {
                    ok = false;
                }
            }
            if !ok || n < 2 || !int || (mask & leaves) != leaves {
                continue;
            }
            let ct = int_type_of(cs);
            let mut v = VNONE;
            // The joined store's alignment: the chunk's first byte's store's; no type tag (it writes several).
            let mut al: u16 = 0;
            for r in 0..run.len() {
                let (off, sz, val, fill) = ret_part(b, pk.ptr_bytes, run[r], pv);
                if off < 8 * c || off >= 8 * c + cs {
                    continue;
                }
                let mut x = val;
                if val == VNONE {
                    x = self.constant(b, ct, fill);
                } else {
                    let vt = b.type_of(val);
                    if is_float(vt) {
                        x = self.made(
                            pk,
                            b,
                            blk,
                            i,
                            Inst { op: O_BITCAST, ty: int_type_of(sz), aux: 0, a: x, b: VNONE, c: VNONE },
                        );
                    }
                    if sz < cs {
                        x = self.made(pk, b, blk, i, Inst { op: O_ZEXT, ty: ct, aux: 0, a: x, b: VNONE, c: VNONE });
                    }
                }
                if off > 8 * c {
                    let sh = self.constant(b, ct, 8 * (off - 8 * c));
                    x = self.made(pk, b, blk, i, Inst { op: O_SHL, ty: ct, aux: 0, a: x, b: sh, c: VNONE });
                }
                v = if v == VNONE {
                    x
                } else {
                    self.made(pk, b, blk, i, Inst { op: O_OR, ty: ct, aux: 0, a: v, b: x, c: VNONE })
                };
                self.repl[run[r] as usize] = DROPPED;
                if off == 8 * c && val != VNONE {
                    al = b.insts[run[r] as usize].aux & 15;
                }
            }
            let _ = self.before(b, blk, i, Inst { op: O_STORE, ty: T_NONE, aux: al, a: pv, b: v, c: 8 * c });
            any = true;
        }
        return any;
    }

    // Load `i` (`u`) of an 8-byte chunk of entry aggregate parameter `k` (`aggp`) that an integer load
    // reads (`aggint`), of fewer bytes than the chunk: the chunk's load (1, 2, 4 or 8 bytes) shifted and
    // truncated, an f32's or f64's bits as the float. The targets pass such a chunk in one integer
    // register, which the code generator takes for the chunk's load (`place::parts_taken`). The
    // parameter's bytes are a copy nothing writes: one load at the entry's start serves each part
    // (`aggload`). Whether it did.
    fn agg_chunk(self: &mut Self, pk: &Package, b: &mut Body, blk: u32, i: u32, u: Inst, k: u32) bool {
        let lay = (b.pool[(b.sig + 3 + k) as usize] & ~AGG) as usize;
        let size = b.pool[lay];
        let c = u.c / 8;
        let cs = (size - 8 * c).min(8);
        let s = type_bytes(u.ty, pk.ptr_bytes);
        let o = u.c - 8 * c;
        if k >= 32 || u.c >= 16 || (self.aggint >> (2 * k + c) as u64 & 1) == 0 || (cs & cs - 1) != 0 || s >= cs || o + s > cs || is_vec(
            u.ty,
        ) || u.ty == T_PTR {
            return false;
        }
        let ct = int_type_of(cs);
        let slot = (2 * k + c) as usize;
        if self.aggload[slot] == NONE {
            // The aggregate's alignment, no type tag (the chunk holds several values).
            let al = b.pool[lay + 1] as u16 & 15;
            self.aggload[slot] = self.placed(
                b,
                0,
                i,
                Inst { op: O_LOAD, ty: ct, aux: al, a: u.a, b: VNONE, c: 8 * c },
                true,
            );
        }
        let w = self.aggload[slot];
        let mut x = w;
        if o != 0 {
            let sh = self.constant(b, ct, 8 * o as u64);
            x = self.before(b, blk, i, Inst { op: O_LSHR, ty: ct, aux: 0, a: x, b: sh, c: VNONE });
        }
        let it = int_type_of(s);
        if s < cs {
            x = self.before(b, blk, i, Inst { op: O_TRUNC, ty: it, aux: 0, a: x, b: VNONE, c: VNONE });
        }
        if is_float(u.ty) {
            x = self.before(b, blk, i, Inst { op: O_BITCAST, ty: u.ty, aux: 0, a: x, b: VNONE, c: VNONE });
        }
        self.repl[i as usize] = x;
        return true;
    }

    // `rslot`: per slot of `b`, the call whose aggregate result of at most 16 bytes it receives, when that
    // call is the only use of the slot's addresses but loads (not volatile) of them; NONE else. `rload`
    // emptied.
    fn result_slots(self: &mut Self, b: &Body) {
        let ns = b.slots.len();
        fill(&mut self.rslot, ns, NONE);
        fill(&mut self.rload, 2 * ns, NONE);
        if ns == 0 {
            return;
        }
        // Only a call with an aggregate result of at most 16 bytes gives a slot one (`rcall`).
        if !self.rcall {
            return;
        }
        // A slot another use rules out: NONE - 1.
        let bad = NONE - 1;
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                let u0 = self.ops_at[i as usize];
                let nu = self.ops_at[i as usize + 1] - u0;
                for q in 0..nu {
                    let v = self.ops[(u0 + q) as usize];
                    if !is_op(b, v, O_SLOTADDR) {
                        continue;
                    }
                    let s = b.insts[v as usize].a as usize;
                    if t.op == O_LOAD && t.a == v && nu == 1 && (t.aux & MEM_VOLATILE) == 0 {
                        continue;
                    }
                    // The result's address of a call (its last operand), once.
                    let call = (t.op == O_CALL || t.op == O_CALLIND) && (b.pool[t.b as usize + 2] & AGG) != 0 && b.pool[(b.pool[t.b as usize + 2] & ~AGG) as usize] <= 16 && b.pool[(t.c + b.pool[t.b as usize]) as usize] == v;
                    let mut once = true;
                    for r in 0..nu {
                        once = once && (r == q || self.ops[(u0 + r) as usize] != v);
                    }
                    self.rslot[s] = if call && once && self.rslot[s] == NONE {
                        i
                    } else {
                        bad
                    };
                }
            }
        }
        for s in 0..ns {
            if self.rslot[s] == bad {
                self.rslot[s] = NONE;
            }
        }
    }

    // Load `i` (`u`) of block `blk` from a slot that only holds call `c`'s aggregate result (`rslot`), `c`
    // before it on every path: a part of the result's 8-byte chunk that holds an integer field (which
    // every target returns in an integer register), read from that chunk's load right after the call
    // (`rload`), shifted, truncated, as a float's or a pointer's bits. The code generators give that load
    // the result's register (`lv::Live::rrelay`). Whether it did.
    fn res_chunk(self: &mut Self, pk: &Package, b: &mut Body, blk: u32, i: u32, u: Inst) bool {
        let s = b.insts[u.a as usize].a;
        let ci = self.rslot[s as usize];
        let cb = self.blk_of[ci as usize];
        if !self.dominates(cb, blk) || cb == blk && ci > i || is_vec(u.ty) || u.ty == T_I128 || u.c >= 16 {
            return false;
        }
        let t = b.insts[ci as usize];
        let lay = (b.pool[t.b as usize + 2] & ~AGG) as usize;
        let size = b.pool[lay];
        let c = u.c / 8;
        let cs = (size - 8 * c).min(8);
        let sz = type_bytes(u.ty, pk.ptr_bytes);
        let o = u.c - 8 * c;
        if (cs & cs - 1) != 0 || o + sz > cs {
            return false;
        }
        // An integer field in the chunk.
        let mut int = false;
        for q in 0..b.pool[lay + 2] as usize {
            let lo = b.pool[lay + 3 + 2 * q];
            int = int || lo >= 8 * c && lo < 8 * c + cs && is_int(b.pool[lay + 4 + 2 * q] as u8);
        }
        if !int {
            return false;
        }
        let ct = int_type_of(cs);
        let at = (2 * s + c) as usize;
        // A load of the whole chunk after the call, with only loads of the slot between (an earlier walk's):
        // the chunk's load, which the later ones read.
        if o == 0 && sz == cs && u.ty == ct && blk == cb {
            let mut next = true;
            for j in ci + 1..i {
                let w = b.insts[j as usize];
                next = next && w.op == O_LOAD && w.a == u.a;
            }
            if next {
                if self.rload[at] == NONE {
                    self.rload[at] = i;
                }
                return false;
            }
        }
        if self.rload[at] == NONE {
            // At the call's own address of the result, which dominates its next instruction; the
            // aggregate's alignment, no type tag (the chunk holds several values).
            let rv = b.pool[(t.c + b.pool[t.b as usize]) as usize];
            let al = b.pool[lay + 1] as u16 & 15;
            let ld = Inst { op: O_LOAD, ty: ct, aux: al, a: rv, b: VNONE, c: 8 * c };
            // Before the instruction after the call, or at the block's end when that is the terminator.
            let cbk = b.blocks[cb as usize];
            self.rload[at] = if ci + 2 == cbk.start + cbk.len {
                self.placed(b, cb, ci, ld, false)
            } else {
                self.before(b, cb, ci + 1, ld)
            };
        }
        let mut x = self.rload[at];
        if o != 0 {
            let sh = self.constant(b, ct, 8 * o as u64);
            x = self.before(b, blk, i, Inst { op: O_LSHR, ty: ct, aux: 0, a: x, b: sh, c: VNONE });
        }
        if sz < cs {
            x = self.before(b, blk, i, Inst { op: O_TRUNC, ty: int_type_of(sz), aux: 0, a: x, b: VNONE, c: VNONE });
        }
        if is_float(u.ty) {
            x = self.before(b, blk, i, Inst { op: O_BITCAST, ty: u.ty, aux: 0, a: x, b: VNONE, c: VNONE });
        } else if u.ty == T_PTR {
            x = self.before(b, blk, i, Inst { op: O_INTTOPTR, ty: T_PTR, aux: 0, a: x, b: VNONE, c: VNONE });
        }
        self.repl[i as usize] = x;
        return true;
    }

    fn walk(self: &mut Self, pk: &Package, b: &mut Body) bool {
        // The walk reads the analyses `tables` made for the body (`K_MEM`), then changes it.
        self.kept = K_NONE;
        let nb = b.blocks.len();
        self.fresh(b);
        self.made.clear();
        self.selected = false;
        self.refold = false;
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
        self.aggload = [NONE; 64];
        self.result_slots(b);
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
        let mut changed = self.param_cycles(b);
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
            if self.inner[k] != NONE {
                changed = self.index_ivs(b, k as u32) || changed;
            }
            if self.inner[k] == k as u32 {
                changed = self.same_params(b, k as u32) || changed;
                changed = self.offset_test(pk, b, k as u32) || changed;
            }
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
                    // call (`agg_params`); one of part of an integer chunk reads the chunk (`agg_chunk`).
                    let u = b.insts[i as usize];
                    if (u.op == O_STORE || u.op == O_MEMSET) && self.repl[i as usize] == VNONE && i + 1 < bk.start + bk.len && b.insts[i as usize + 1].op == O_RET {
                        changed = self.ret_chunks(pk, b, k as u32, i) || changed;
                    }
                    if u.op == O_ICMP && self.repl[i as usize] == VNONE && self.null_test(pk, b, k as u32, i) {
                        changed = true;
                        self.refold = true;
                    }
                    if u.op == O_SELECT && self.repl[i as usize] == VNONE && is_int(u.ty) && u.ty != T_PTR && u.ty != T_I128 {
                        changed = self.select_step(b, k as u32, i) || changed;
                    }
                    // A select on a condition the branches before the block decide is that side.
                    if b.insts[i as usize].op == O_SELECT && self.repl[i as usize] == VNONE {
                        let d = self.cond_at(b, k as u32, u.a, THREAD_DEPTH);
                        if d != 0 {
                            self.repl[i as usize] = if d == 1 {
                                u.b
                            } else {
                                u.c
                            };
                            changed = true;
                        }
                    }
                    if u.op == O_BR && self.repl[i as usize] == VNONE && u.b != u.c {
                        changed = edge_selects(b, u) || changed;
                        if self.merge_exits(b, k as u32, i) {
                            changed = true;
                            self.refold = true;
                        }
                    }
                    if u.op == O_LOAD && self.repl[i as usize] == VNONE && is_op(b, u.a, O_SLOTADDR) && self.rslot[b.insts[u.a as usize].a as usize] != NONE {
                        changed = self.res_chunk(pk, b, k as u32, i, u) || changed;
                    }
                    if self.aggp != 0 && u.op == O_LOAD && self.repl[i as usize] == VNONE && (u.a & VPARAM) != 0 && (u.a & ~VPARAM) >= b.blocks[0].param_start && (u.a & ~VPARAM) - b.blocks[0].param_start < 64 && (self.aggp >> ((u.a & ~VPARAM) - b.blocks[0].param_start) as u64 & 1) != 0 {
                        changed = self.agg_chunk(pk, b, k as u32, i, u, (u.a & ~VPARAM) - b.blocks[0].param_start) || changed;
                    }
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
    // leaves the block), then joins `pend`; a call keeps those it cannot read: the ones of a class it does
    // not reach, and, for a call that comes back (no `FX_STALL`), the ones whose bytes it does not read
    // (`call_apart`); any other instruction but a pure one that cannot trap empties `pend`. Whether it
    // dropped any.
    fn overwrite(self: &mut Self, pk: &Package, b: &Body, i: u32) bool {
        let t = b.insts[i as usize];
        if pure_op(t.op) && !tls_addr(pk, b, t) && (t.op < O_SDIV || t.op > O_UREM) {
            return false;
        }
        if t.op == O_CALL || t.op == O_CALLIND {
            // A call keeps the stores into an exclusive parameter's referent whose class it does not reach
            // (`carry`'s test): no pointer it holds points there, and a panic in it ends the program, so no
            // code reads those bytes before a later store writes them. A call that comes back keeps those
            // of bytes it does not read either (`call_apart`).
            let wb = self.write_bits(pk, b, i) | self.sbits;
            let back = t.op == O_CALL && (pk.syms[b.syms[t.a as usize] as usize].fx & FX_STALL) == 0;
            let mut x: usize = 0;
            // Each step keeps or drops one entry.
            while x < self.pend.len() {
                let j = self.pend[x];
                let s = b.insts[j as usize];
                let c = self.acc(j, s.a);
                let lo = (s.c as i32) as i64;
                if c >= CL_NOALIAS && c < CL_FROZEN && (class_bit(c) & wb) == 0 || back && self.call_apart(
                    pk,
                    b,
                    i,
                    t,
                    self.val(s.a),
                    lo,
                    lo + type_bytes(b.type_of(s.b), pk.ptr_bytes) as i64,
                ) {
                    x += 1;
                } else {
                    let _ = self.pend.swap_remove(x);
                }
            }
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
                // Each step reads one instruction between the two stores.
                for x in j + 1..i {
                    self.unstored = self.unstored || b.insts[x as usize].op == O_CALL;
                }
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
        if !self.selectable(b, e0, e1, true) {
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

    // Whether edges `e0` and `e1` into one block differ in 1 to MAX_SELECTS arguments, each an integer of up
    // to 64 bits, a pointer or a scalar float: the selects of an if-conversion (`diamond`). The walk's
    // replacements apply when `walk`.
    fn selectable(self: &Self, b: &Body, e0: u32, e1: u32, walk: bool) bool {
        let jb = b.blocks[b.edge_target(e0) as usize];
        let mut nsel: u32 = 0;
        for q in 0..jb.param_len as u32 {
            let (x, y) = if walk {
                (self.val(b.edge_arg(e0, q)), self.val(b.edge_arg(e1, q)))
            } else {
                (b.edge_arg(e0, q), b.edge_arg(e1, q))
            };
            if x != y {
                let ty = b.params[(jb.param_start + q) as usize];
                if !(is_int(ty) && ty != T_I128 || ty == T_PTR || ty == T_F32 || ty == T_F64) {
                    return false;
                }
                nsel += 1;
            }
        }
        return nsel != 0 && nsel <= MAX_SELECTS;
    }

    // Branch `t`, instruction `i` ending block `k`, whose sides each enter a block that `k` alone enters,
    // costs at most SPEC_MAX together (`speculated`) and returns an integer of up to 64 bits, a
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

    // The weighted cost, excluding constants, of side `a` of block `k`'s branch (`arm`) that `speculate`
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
            // Expensive arithmetic must not run on both sides of a select. Other multiplies and
            // loads consume more of the budget than a register operation.
            n += if t.op == O_FDIV || t.op == O_FSQRT || t.ty == T_I128 {
                SPEC_MAX + 1
            } else if t.op == O_MUL || t.op == O_FMUL || t.op == O_FMA || t.op == O_LOAD {
                2
            } else {
                1
            };
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
    // (`order_facts`), a `bool` or bounded load's (`load_bound`), or one an `and` with a constant, a right
    // shift, a remainder or quotient by a constant or a zero extension keeps, `depth` instructions deep;
    // None when unknown.
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
        if (v & VPARAM) != 0 {
            return best;
        }
        let t = b.insts[v as usize];
        let m = width_mask(t.ty, pk.ptr_bytes);
        let mut r = load_bound(t, m);
        if depth == 0 && r.is_none() {
            return best;
        }
        // A load (`r` set) is none of these.
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
    // low mask that covers its operand's bound, an integer comparison with a constant that every value
    // up to the bound answers alike (a signed one when the bound leaves the sign bit clear).
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
        if t.op == O_ICMP && t.aux <= C_UGE {
            let k = const_of(b, t.b);
            let at = b.type_of(t.a);
            if k.is_none() || is_vec(at) || at == T_I128 {
                return VNONE;
            }
            let x = self.ubound(pk, b, t.a, UB_DEPTH);
            if x.is_none() {
                return VNONE;
            }
            let m = width_mask(at, pk.ptr_bytes);
            let hi = x.unwrap();
            let kv = k.unwrap() & m;
            let mut c = t.aux;
            if c >= C_SLT && c <= C_SGE {
                // Values 0 to `hi` without the sign bit compare signed as unsigned, above a negative constant.
                if hi > m >> 1 {
                    return VNONE;
                }
                if kv > m >> 1 {
                    b.insts[i as usize] = iconst(t.ty, (c == C_SGT || c == C_SGE) as u64);
                    return VNONE;
                }
                c += C_ULT - C_SLT;
            }
            // Decided when every value 0 to `hi` gives one answer.
            let r: Option<u64> = if c <= C_NE {
                if kv > hi {
                    Some((c == C_NE) as u64)
                } else {
                    None
                }
            } else if c == C_ULT || c == C_UGE {
                if hi < kv {
                    Some((c == C_ULT) as u64)
                } else {
                    None
                }
            } else if hi <= kv {
                Some((c == C_ULE) as u64)
            } else {
                None
            };
            if r.is_some() {
                b.insts[i as usize] = iconst(t.ty, r.unwrap());
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

    // The value of condition `c` the order facts in scope decide (`order_facts`), if any: `x <u y` itself,
    // or `x <u a + 1` false where `a <u x` holds (`a + 1` does not wrap: an inclusive range's second test,
    // `i + 1 <=u last` after `i <u last`).
    fn order_decided(self: &Self, b: &Body, c: Value) Option<u64> {
        let (x, y, neg) = Opt::as_ult(b, c);
        if x == VNONE {
            return None;
        }
        if let Some(r) = self.rel.get(&rel_key(x, y)) {
            return Some((*r != 0 != neg) as u64);
        }
        if is_op(b, y, O_ADD) && const_of(b, b.insts[y as usize].b) == Some(1u64) {
            if let Some(r) = self.rel.get(&rel_key(b.insts[y as usize].a, x)) {
                if *r != 0 {
                    return Some(neg as u64);
                }
            }
        }
        return None;
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

    // The block parameters of a set that every edge into them passes either a member of the set or one value
    // `v` (an iterator's flag that only a constant ever sets, carried through a loop and its joins): each is
    // `v` (`prepl`), by induction over the edges taken, when `v` dominates their blocks (the redundant phi
    // cycles of Braun et al., "Simple and Efficient Construction of Static Single Assignment Form"). The sets
    // are the parameters the edges connect. Whether any is.
    fn param_cycles(self: &mut Self, b: &Body) bool {
        let np = b.params.len();
        if np == 0 {
            return false;
        }
        let mut uf = Vector::<u32>::with_capacity(np);
        let mut ext = Vector::<Value>::with_capacity(np);
        let mut bad = Vector::<bool>::with_capacity(np);
        for q in 0..np {
            uf.push(q as u32);
            ext.push(VNONE);
            bad.push(false);
        }
        // Two passes over the reached edges: the sets, then each set's other values.
        for pass in 0..2u32 {
            for k in 1..b.blocks.len() {
                let kb = b.blocks[k];
                if self.rpo[k] == NONE || kb.param_len == 0 {
                    continue;
                }
                for x in self.pred_at[k]..self.pred_at[k + 1] {
                    let src = self.preds[x as usize];
                    if self.rpo[src as usize] == NONE || x > self.pred_at[k] && self.preds[x as usize - 1] == src {
                        continue;
                    }
                    b.succ_edges(term(b, src), &mut self.edges);
                    for e in 0..self.edges.len() {
                        let ed = self.edges[e];
                        if b.edge_target(ed) != k as u32 {
                            continue;
                        }
                        for q in 0..kb.param_len as u32 {
                            let pq = kb.param_start + q;
                            let a = b.edge_arg(ed, q);
                            let ap = a & ~VPARAM;
                            let member = (a & VPARAM) != 0 && a != VNONE && ap as usize < np;
                            if pass == 0 {
                                if member {
                                    let (ra, rq) = (set_of(&mut uf, ap), set_of(&mut uf, pq));
                                    uf[ra as usize] = rq;
                                }
                                continue;
                            }
                            let r = set_of(&mut uf, pq) as usize;
                            if member && set_of(&mut uf, ap) as usize == r {
                                continue;
                            }
                            if ext[r] == VNONE {
                                ext[r] = a;
                            } else if ext[r] != a && !same_iconst(b, ext[r], a) {
                                bad[r] = true;
                            }
                        }
                    }
                }
            }
        }
        // The entry's parameters take the caller's values.
        let e0 = b.blocks[0];
        for q in e0.param_start..e0.param_start + e0.param_len as u32 {
            let r = set_of(&mut uf, q) as usize;
            bad[r] = true;
        }
        let mut any = false;
        for q in 0..np as u32 {
            let r = set_of(&mut uf, q) as usize;
            let v = ext[r];
            if bad[r] || v == VNONE || (v & VFLAG) != 0 || self.rpo[self.pblock[q as usize] as usize] == NONE {
                continue;
            }
            let d = self.def_blk(v);
            if d != NONE && self.dominates(d, self.pblock[q as usize]) && d != self.pblock[q as usize] {
                self.prepl[q as usize] = v;
                any = true;
            }
        }
        return any;
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

    // Thread the edges of the graph (`follow`): through a block that holds only a jump (its parameters
    // read by the jump alone), and through a block whose branch or switch the edge's constant arguments decide (a `&&`
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
        // parameter, and the nearest block that dominates every block outside its own that reads it
        // (`preader`, `ireader`: NONE for none, MULTI for a reader no path reaches). An edge's argument is
        // read in its terminator's block; one of the value's own block is read inside it (`through` checks
        // the edge it threads along).
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
                            self.preader[q] = self.reader(self.preader[q], k as u32);
                        }
                    } else {
                        let x = (v & ~VFLAG) as usize;
                        self.icount[x] = (self.icount[x] + 1).min(2);
                        self.in_or[x] = self.in_or[x] || is_or;
                        if self.blk_of[x] != k as u32 {
                            self.ireader[x] = self.reader(self.ireader[x], k as u32);
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
                let r = self.ret_folded(pk, b, k as u32, t.a);
                if r.is_some() {
                    // The jump returns what its target would.
                    let mut rt = term(b, j);
                    rt.a = r.unwrap();
                    b.insts[i as usize] = rt;
                    any = true;
                    self.rethru = true;
                    continue;
                }
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
        // The first pass checks every edge, the second rewrites them, each once: terminators may share an
        // edge (`done`). The predecessors come in block order, a block once per edge.
        let mut done = Vector::<u32>::new();
        for pass in 0..2u32 {
            for x in self.pred_at[j as usize]..self.pred_at[j as usize + 1] {
                let src = self.preds[x as usize];
                if x > self.pred_at[j as usize] && self.preds[x as usize - 1] == src {
                    continue;
                }
                b.succ_edges(term(b, src), &mut self.edges);
                for e in 0..self.edges.len() {
                    let ed = self.edges[e];
                    if b.edge_target(ed) != j || pass == 1 && done.contains(&ed) {
                        continue;
                    }
                    if pass == 1 {
                        done.push(ed);
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
        // The comparison reads the result as it now is (`ret_folded` evaluates it before the walk).
        let z = self.tconst(b, t.ty, 0);
        b.insts[u as usize] = Inst { op: O_ICMP, ty: t.ty, aux: C_NE, a: VPARAM | p, b: z, c: VNONE };
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
            if j != k && j != 0 && jb.len == 1 && jt.op == O_JMP && !self.hdr[j as usize] && !self.hdr[b.edge_target(
                jt.a,
            ) as usize] && self.read_here(jb) {
                e = if jb.param_len == 0 {
                    jt.a
                } else {
                    self.thread_edge(b, e, j, jt.a)
                };
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

    // Whether only block `jb`'s own instructions read its parameters.
    fn read_here(self: &Self, jb: Block) bool {
        for q in jb.param_start..jb.param_start + jb.param_len as u32 {
            if self.preader[q as usize] != NONE {
                return false;
            }
        }
        return true;
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
            if (a & VPARAM) == 0 && a != VNONE && self.made_in(a & ~VFLAG, j) {
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

    // What the return ending block `j` gives along jump `e` of block `k` into `j`, as a value `k` has: `j`
    // heads no loop and holds at most THREAD_BLOCK_MAX pure instructions, and each one the return reads,
    // `j`'s parameters the edge's arguments, simplifies (`simplify`, on scratch instructions after the
    // body's) to a value `k` has or to a constant a block that dominates `k` holds (an `Option` built on
    // each side of a join and taken apart after it). None when not.
    fn ret_folded(self: &Self, pk: &Package, b: &mut Body, k: u32, e: u32) Option<Value> {
        let j = b.edge_target(e);
        let jb = b.blocks[j as usize];
        let jt = term(b, j);
        if j == k || j == 0 || self.hdr[j as usize] || jt.op != O_RET || jb.len - 1 > THREAD_BLOCK_MAX {
            return None;
        }
        let base = b.insts.len() as u32;
        // Per instruction of `j`: its value along the edge, VNONE when it does not simplify.
        let mut sub: [Value; THREAD_BLOCK_MAX as usize] = [VNONE; THREAD_BLOCK_MAX as usize];
        let mut ok = true;
        for i in jb.start..jb.start + jb.len - 1 {
            let mut s = b.insts[i as usize];
            let op = s.op;
            if op != O_ICONST && !(op >= O_ADD && op <= O_INTTOPTR && (op < O_ADDO || op > O_MULO)) && op != O_SELECT {
                ok = false;
                break;
            }
            let mut known = true;
            if op != O_ICONST {
                let (va, ka) = thru_val(b, jb, e, &sub, s.a);
                let (vb, kb) = thru_val(b, jb, e, &sub, s.b);
                s.a = va;
                s.b = vb;
                known = ka && kb;
                if op == O_SELECT {
                    let (vc, kc) = thru_val(b, jb, e, &sub, s.c);
                    s.c = vc;
                    known = known && kc;
                }
            }
            if !known {
                continue;
            }
            let x = b.insts.len() as u32;
            b.insts.push(s);
            let r = if op == O_ICONST {
                VNONE
            } else {
                simplify(pk, b, x)
            };
            if b.insts.len() as u32 != x + 1 {
                ok = false;
                break;
            }
            sub[(i - jb.start) as usize] = if r != VNONE {
                r
            } else if b.insts[x as usize].op == O_ICONST {
                x
            } else {
                VNONE
            };
        }
        let (mut w, kw) = thru_val(b, jb, e, &sub, jt.a);
        ok = ok && kw;
        if ok && w != VNONE && (w & (VPARAM | VFLAG)) == 0 && w >= base {
            // A constant: one a block that dominates `k` holds.
            let c = b.insts[w as usize];
            w = VNONE;
            let mut d = k;
            for _ in 0..b.blocks.len() {
                let db = b.blocks[d as usize];
                for x in db.start..db.start + db.len {
                    if w == VNONE && same(b.insts[x as usize], c) {
                        w = x;
                    }
                }
                if w != VNONE || d == 0 {
                    break;
                }
                d = self.idom[d as usize];
            }
            ok = w != VNONE;
        }
        b.insts.truncate(base as usize);
        return if ok {
            Some(w)
        } else {
            None
        };
    }

    // Whether edge `e` of block `k` into `j` is a side of a diamond the walk makes selects of (`diamond`):
    // `k` branches into `j` and into a small block of pure, speculable instructions (`arm`) that jumps to
    // `j`, or `k` is that block.
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
        let mut n: u32 = 0;
        for i in ob.start..ob.start + ob.len - 1 {
            let x = b.insts[i as usize];
            if !pure_op(x.op) || !speculable(pk, b, x) {
                return false;
            }
            if x.op != O_ICONST && x.op != O_FCONST {
                n += 1;
            }
        }
        return n <= SPEC_MAX && self.selectable(b, direct, oe, false);
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

    // Reader `r` (`preader`, `ireader`) after block `k` reads the value too: the nearest block that
    // dominates both (Cooper, Harvey and Kennedy's intersection on the reverse postorder).
    fn reader(self: &Self, r: u32, k: u32) u32 {
        if r == MULTI || self.rpo[k as usize] == NONE {
            return MULTI;
        }
        if r == NONE || r == k {
            return k;
        }
        let mut x = r;
        let mut y = k;
        // Each step moves one of the two up the dominator tree: at most twice the block count.
        for _ in 0..2 * self.rpo.len() {
            if x == y {
                return x;
            }
            if self.rpo[x as usize] > self.rpo[y as usize] {
                x = self.idom[x as usize];
            } else {
                y = self.idom[y as usize];
            }
        }
        assert(false, "opt: a dominator walk that does not meet");
        return MULTI;
    }

    // Whether reader `x` (`preader`, `ireader`: the block that dominates every block that reads a value of
    // block `j`) stays out of the paths an edge threaded along `j`'s edge `s` takes: none, or a block that
    // a block only `j` enters, through another edge, dominates.
    fn apart(self: &Self, b: &Body, j: u32, s: u32, x: u32) bool {
        if x == NONE {
            return true;
        }
        if x == MULTI {
            return false;
        }
        // Up the dominator tree to `j`'s child: at most the block count.
        let mut y = x;
        for _ in 0..b.blocks.len() {
            if y == j || y == 0 || self.idom[y as usize] == j {
                break;
            }
            y = self.idom[y as usize];
        }
        return y != j && self.idom[y as usize] == j && y != b.edge_target(s) && self.pred_at[y as usize + 1] - self.pred_at[y as usize] == 1;
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
        if (v & VFLAG) == 0 && self.made_in(v, j) {
            return VNONE;
        }
        return v;
    }

    // Whether instruction `i` is one of block `j`'s; a constant `thread` made (`tconst`) is no block's.
    const fn made_in(self: &Self, i: u32, j: u32) bool {
        return i as usize < self.blk_of.len() && self.blk_of[i as usize] == j;
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

    // Null test `i` (block `k`) of an element address of a slice parameter (`slice_of`), `p == 0` or
    // `p != 0`, where the branches before `k` make the slice not empty (`len_set_at`): the constant.
    // Whether it did.
    fn null_test(self: &Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if t.aux != C_EQ && t.aux != C_NE || const_of(b, t.b) != Some(0u64) {
            return false;
        }
        let s = slice_of(b, t.a);
        if s == VNONE || !self.len_set_at(pk, b, k, s, THREAD_DEPTH) {
            return false;
        }
        b.insts[i as usize] = iconst(t.ty, (t.aux == C_NE) as u64);
        return true;
    }

    // Select `i` (block `k`) of a loop's carried value `a` (a parameter of a loop header) and `a op d` (an
    // `add`, `or`, `xor`, or `sub` of `d` from `a`): `a op select(c, d, 0)` (arms
    // swapped when `a` is the first), the step a reduction the vectorizer widens (a conditional count,
    // `a + zext(c)`). Whether it did.
    fn select_step(self: &mut Self, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        for side in 0..2u32 {
            let (x, a) = if side == 0 {
                (t.b, t.c)
            } else {
                (t.c, t.b)
            };
            if (a & VPARAM) == 0 || a == VNONE || self.inner[self.pblock[(a & ~VPARAM) as usize] as usize] != self.pblock[(a & ~VPARAM) as usize] || (x & (VPARAM | VFLAG)) != 0 || x == VNONE {
                continue;
            }
            let o = b.insts[x as usize];
            if o.op != O_ADD && o.op != O_OR && o.op != O_XOR && o.op != O_SUB || o.ty != t.ty {
                continue;
            }
            let d = if o.a == a {
                o.b
            } else if o.b == a && o.op != O_SUB {
                o.a
            } else {
                VNONE
            };
            if d == VNONE {
                continue;
            }
            let z = self.constant(b, t.ty, 0);
            let s = self.before(
                b,
                k,
                i,
                Inst {
                    op: O_SELECT,
                    ty: t.ty,
                    aux: 0,
                    a: t.a,
                    b: if side == 0 {
                        d
                    } else {
                        z
                    },
                    c: if side == 0 {
                        z
                    } else {
                        d
                    },
                },
            );
            b.insts[i as usize] = Inst { op: o.op, ty: t.ty, aux: 0, a: a, b: s, c: VNONE };
            return true;
        }
        return false;
    }

    // The parameters of loop header `k` (at most SAME_MAX) that equal an earlier one of its own: each edge
    // into `k` passes the two one value, or the same operation of each with one other operand (`i + 1` and
    // `j + 1`, two counters a `zip` steps together), so by induction they are equal; the later one is the
    // earlier (`prepl`). Whether any is.
    fn same_params(self: &mut Self, b: &Body, k: u32) bool {
        let kb = b.blocks[k as usize];
        let np = kb.param_len as u32;
        if np < 2 || np > SAME_MAX || self.rpo[k as usize] == NONE {
            return false;
        }
        let mut any = false;
        for q in 1..np {
            let vq = VPARAM | kb.param_start + q;
            if self.prepl[(kb.param_start + q) as usize] != VNONE {
                continue;
            }
            for p0 in 0..q {
                let vp = VPARAM | kb.param_start + p0;
                if b.params[(kb.param_start + p0) as usize] != b.params[(kb.param_start + q) as usize] || self.prepl[(kb.param_start + p0) as usize] != VNONE || !self.args_agree(
                    b,
                    k,
                    p0,
                    q,
                    vp,
                    vq,
                ) {
                    continue;
                }
                self.prepl[(kb.param_start + q) as usize] = vp;
                any = true;
                break;
            }
        }
        return any;
    }

    // Whether every edge into block `k` passes as its parameters `p` and `q` (values `vp`, `vq`) one value,
    // or the same operation of `vp` and of `vq` with one other operand.
    fn args_agree(self: &mut Self, b: &Body, k: u32, p: u32, q: u32, vp: Value, vq: Value) bool {
        for x in self.pred_at[k as usize]..self.pred_at[k as usize + 1] {
            let src = self.preds[x as usize];
            if x > self.pred_at[k as usize] && self.preds[x as usize - 1] == src {
                continue;
            }
            b.succ_edges(term(b, src), &mut self.edges);
            for e in 0..self.edges.len() {
                let ed = self.edges[e];
                if b.edge_target(ed) != k {
                    continue;
                }
                let a = self.val(b.edge_arg(ed, p));
                let c = self.val(b.edge_arg(ed, q));
                if a == c || a == vp && c == vq {
                    continue;
                }
                if (a & (VPARAM | VFLAG)) != 0 || (c & (VPARAM | VFLAG)) != 0 || a == VNONE || c == VNONE {
                    return false;
                }
                let ta = b.insts[a as usize];
                let tc = b.insts[c as usize];
                let same_op = ta.op == tc.op && ta.ty == tc.ty && ta.aux == tc.aux && ta.c == tc.c && (ta.op >= O_ADD && ta.op <= O_ASHR || ta.op == O_PTRADD);
                let steps = same_op && (self.val(ta.a) == vp && self.val(tc.a) == vq && self.val(ta.b) == self.val(tc.b) || self.val(
                    ta.b,
                ) == vp && self.val(tc.b) == vq && self.val(ta.a) == self.val(tc.a));
                if !steps {
                    return false;
                }
            }
        }
        return true;
    }

    // Whether condition `c` holds (1) or fails (2) where block `k` starts, or neither is known (0): `k` has
    // one predecessor, whose branch on `c` or on the opposite comparison enters `k` by one side alone, or
    // which `depth` such steps back does.
    fn cond_at(self: &Self, b: &Body, k: u32, c: Value, depth: u32) u8 {
        if depth == 0 || self.rpo[k as usize] == NONE || self.pred_at[k as usize + 1] - self.pred_at[k as usize] != 1 {
            return 0;
        }
        let src = self.preds[self.pred_at[k as usize] as usize];
        if src == k {
            return 0;
        }
        let st = term(b, src);
        if st.op == O_BR && !same_edge(b, st.b, st.c) && b.edge_target(st.b) == k != (b.edge_target(st.c) == k) {
            let r = same_test(b, st.a, c);
            if r != 0 {
                return if r == 1 == (b.edge_target(st.b) == k) {
                    1
                } else {
                    2
                };
            }
        }
        return self.cond_at(b, src, c, depth - 1);
    }

    // Whether the length of slice parameter `s` is not 0 where block `k` starts: each edge into `k` (at most
    // IMPLY_FAN) is a branch on a comparison that implies it there (`len_set`), or leaves a block where it
    // holds, `depth` blocks back.
    fn len_set_at(self: &Self, pk: &Package, b: &Body, k: u32, s: Value, depth: u32) bool {
        if depth == 0 || self.rpo[k as usize] == NONE {
            return false;
        }
        let np = self.pred_at[k as usize + 1] - self.pred_at[k as usize];
        if np == 0 || np > IMPLY_FAN {
            return false;
        }
        for x in self.pred_at[k as usize]..self.pred_at[k as usize + 1] {
            let src = self.preds[x as usize];
            if x > self.pred_at[k as usize] && self.preds[x as usize - 1] == src {
                continue;
            }
            let st = term(b, src);
            let mut here = true;
            for n in 0..edge_count(st) {
                let ed = edge_at(b, st, n);
                if b.edge_target(ed) != k {
                    continue;
                }
                here = here && st.op == O_BR && !same_edge(b, st.b, st.c) && len_set(
                    b,
                    pk.ptr_bytes,
                    s,
                    st.a,
                    ed == st.b,
                );
            }
            if !here && !self.len_set_at(pk, b, src, s, depth - 1) {
                return false;
            }
        }
        return true;
    }

    // Value `v` read in block `k`: when it is a select of another block whose condition the branches into
    // `k` decide (`cond`, `order_decided`, or an equality with a constant `entry_fact` settles), the arm it
    // takes there (the pointer of an `Option` of a reference that a `None` test left).
    fn select_arm(self: &Self, pk: &Package, b: &Body, k: u32, v: Value) Value {
        if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || v as usize >= self.blk_of.len() || self.blk_of[v as usize] == k || b.insts[v as usize].op != O_SELECT {
            return v;
        }
        let s = b.insts[v as usize];
        let mut c = switch self.cond.get(&(s.a as u64)) {
            Some(x) => Option::<u64>::Some(*x),
            None => self.order_decided(b, s.a),
        };
        if c.is_none() && is_op(b, s.a, O_ICMP) {
            let e = b.insts[s.a as usize];
            let kb = const_of(b, e.b);
            if (e.aux == C_EQ || e.aux == C_NE) && kb.is_some() && const_of(b, e.a).is_none() {
                let r = self.entry_fact(pk, b, k, e.a, kb.unwrap(), THREAD_DEPTH);
                if r.is_some() {
                    c = Some((r.unwrap() == (e.aux == C_EQ)) as u64);
                }
            }
        }
        return if c.is_none() {
            v
        } else if c.unwrap() != 0 {
            s.b
        } else {
            s.c
        };
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
        return self.add_const(b, t, h);
    }

    // Constant `t` (hash `h`) at the end of the instructions, which the rebuild places in the entry
    // (`extra`).
    fn add_const(self: &mut Self, b: &mut Body, t: Inst, h: u64) Value {
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

    // Checked operation `i` (`addo`, `subo`, `mulo`) whose plain operation on its operands an earlier
    // instruction computes: that one becomes the checked operation, whose value and flag are `i`'s (one
    // product, not two). Else `i` stands for the plain operation in the numbering (`as_plain`), for a later
    // one. Whether it merged.
    fn checked_plain(self: &mut Self, b: &mut Body, i: u32) bool {
        let t = b.insts[i as usize];
        let p = as_plain(t);
        let h = value_hash(b, p);
        let f = switch self.pure.get(&h) {
            Some(v) => *v,
            None => NONE,
        };
        if f != NONE && same_value(b, b.insts[f as usize], p) {
            b.insts[f as usize] = t;
            self.repl[i as usize] = f;
            self.frepl[i as usize] = VFLAG | f;
            return true;
        }
        self.enter(LOG_PURE, h, i);
        return false;
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
        if t0.op == O_CALL && i as usize < self.nofx.len() {
            self.nofx[i as usize] = (pk.syms[b.syms[t0.a as usize] as usize].fx & (FX_WRITE | FX_ARG | FX_STALL)) == 0;
        }
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
        if !is_terminator(t.op) {
            if lv::operand_a(f) {
                t.a = self.select_arm(pk, b, k, t.a);
            }
            if lv::operand_b(f) {
                t.b = self.select_arm(pk, b, k, t.b);
            }
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
            if t.op == O_BR {
                self.step_next(b, k, t);
            }
            b.insts[i as usize] = t;
            return !same(t, t0);
        }
        // A reference is never null (`nonnull`).
        if t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) && (const_of(b, t.b) == Some(0u64) && nonnull(
            b,
            t.a,
            pk.ptr_bytes,
        ) || const_of(b, t.a) == Some(0u64) && nonnull(b, t.b, pk.ptr_bytes)) {
            t = iconst(t.ty, (t.aux == C_NE) as u64);
        }
        // An unsigned compare with a constant that the largest value of its other side settles (`umax_cmp`): a
        // shift amount masked below the width, a bit count, a remainder.
        if t.op == O_ICMP && t.aux >= C_ULT && t.aux <= C_UGE {
            let r = umax_cmp(b, t, pk.ptr_bytes);
            if r.is_some() {
                t = iconst(t.ty, r.unwrap() as u64);
            }
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
                        Inst { op: O_PTRADD, ty: pa.ty, aux: pa.aux & PTR_SCALE, a: pa.a, b: pa.b, c: 0 },
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
                        Inst { op: O_PTRADD, ty: pa.ty, aux: pa.aux & PTR_SCALE, a: pa.a, b: pa.b, c: 0 },
                    );
                    self.unbiased.insert(t.a, q);
                }
                // `q` may leave the object: no longer in bounds of its base.
                t.a = q;
                t.c = off as u32;
                t.aux &= ~PTR_INBOUNDS;
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
        // A fill of 1, 2, 4 or 8 bytes with a constant byte is a store of the integer of those bytes.
        let fill = if t.op == O_MEMSET && (t.aux & MEM_VOLATILE) == 0 {
            const_of(b, t.b)
        } else {
            Option::<u64>::None
        };
        if size.is_some() && fill.is_some() {
            let n = size.unwrap();
            if n == 1 || n == 2 || n == 4 || n == 8 {
                let ty = int_type_of(n as u32);
                let v = self.constant(b, ty, (fill.unwrap() & 0xFF) * 0x0101010101010101 & width_mask(ty, 8));
                // At a constant offset from an address: that address and the offset.
                let (base, off) = if is_op(b, t.a, O_PTRADD) && b.insts[t.a as usize].b == VNONE {
                    (b.insts[t.a as usize].a, b.insts[t.a as usize].c)
                } else {
                    (t.a, 0u32)
                };
                t = Inst { op: O_STORE, ty: T_NONE, aux: 0, a: base, b: v, c: off };
                b.insts[i as usize] = t;
            }
        }
        if t.op == O_MEMCPY && (t.aux & MEM_VOLATILE) == 0 && size.is_some() && self.result_into(pk, b, k, i, t) {
            return true;
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
        if t.op == O_CALL || t.op == O_CALLIND {
            t = self.copied_args(pk, b, i);
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
            // A load of bytes no write touches (a private slot's, a read-only referent's: `frozen`) reads one
            // value in every memory state.
            let st = if p == PRIV_KEPT || i as usize < self.acls.len() && self.acls[i as usize] == CL_FROZEN {
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
            if safe && self.sink_load(pk, b, k, i, t) {
                return true;
            }
        } else if (t.op == O_ADDO || t.op == O_SUBO || t.op == O_MULO) && (self.fold_checked(pk, b, i) || self.checked_plain(
            b,
            i,
        )) {
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
            if self.hoist_call(pk, b, k, i) {
                return true;
            }
        } else if tls_addr(pk, b, t) {
            // The running thread's copy: a task moves to another thread only in a call that writes memory,
            // so one address serves until the untagged accesses' state changes, and it leaves the loops
            // without such a call.
            let h = mix(value_hash(b, t), self.tstate[0] as u64 + 1);
            let found = switch self.pure.get(&h) {
                Some(v) => *v,
                None => NONE,
            };
            if found != NONE && same_value(b, as_plain(b.insts[found as usize]), t) {
                self.repl[i as usize] = found;
                return true;
            }
            self.enter(LOG_PURE, h, i);
            if self.hoist(pk, b, k, i, false, false, false) {
                return true;
            }
        } else if pure_op(t.op) && !tls_addr(pk, b, t) {
            if (pk.fmath | b.fmath) != 0 && t.op >= O_FADD && t.op <= O_FDIV && !is_vec(t.ty) {
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
            if b.insts[i as usize].op == O_OR && pk.bitrev && bit_reverse(pk, b, i) {
                let _ = self.number(pk, b, k, i);
                return true;
            }
            if b.insts[i as usize].op == O_SELECT && self.sign_select(pk, b, k, i) {
                return true;
            }
            if b.insts[i as usize].op == O_SELECT {
                let r = self.floor_sub(b, i);
                if r != VNONE {
                    self.repl[i as usize] = r;
                    return true;
                }
                self.flag_next(b, k, i);
            }
            if b.insts[i as usize].op == O_ICMP && self.narrow_cmp(pk, b, i) {
                let _ = self.number(pk, b, k, i);
                return true;
            }
            if b.insts[i as usize].op == O_ICMP && self.icmp_select(pk, b, k, i) {
                return true;
            }
            if b.insts[i as usize].op == O_ICMP && self.flag_test(b, i) {
                if self.repl[i as usize] == VNONE {
                    let _ = self.number(pk, b, k, i);
                }
                return true;
            }
            let rr = self.range_fold(pk, b, i);
            if rr != VNONE {
                self.repl[i as usize] = rr;
                return true;
            }
            let lop = b.insts[i as usize].op;
            if lop == O_VCMP && self.signed_vcmp(pk, b, k, i) {
                return true;
            }
            if lop >= O_CLZ && lop <= O_POPCNT && self.narrow_count(pk, b, k, i) || lop == O_TRUNC && self.narrow_const(
                pk,
                b,
                k,
                i,
            ) {
                return true;
            }
            if (lop == O_AND || lop == O_OR) && (self.range_check(pk, b, k, i) || self.pow2_test(pk, b, k, i) || self.bound_min(
                b,
                k,
                i,
            )) || lop == O_OR && self.bit_set(pk, b, k, i) || lop == O_ICMP && self.srem_cmp(pk, b, k, i) {
                return true;
            }
            self.pow2(b, i);
            self.shift_pair(pk, b, i);
            self.add_pair(pk, b, i);
            self.split_base(b, k, i);
            if self.divide(pk, b, k, i) || self.rem_by_quotient(b, k, i) {
                return true;
            }
            return self.number(pk, b, k, i) || !same(b.insts[i as usize], t0);
        }
        return !same(t, t0);
    }

    // Comparison `i` (block `k`) of integer lanes of vectors of at most 32 bytes as unsigned, on a target
    // that compares them as signed only (`Package.vucmp`): the signed comparison of the operands with their
    // sign bits flipped (an `xor` with a splat of the lanes' sign bit, which folds into a constant
    // operand). Whether it did.
    fn signed_vcmp(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        let vt = b.type_of(t.a);
        let lt = lane_type(vt);
        let nb = type_bytes(vt, 8);
        if pk.vucmp || t.aux < C_ULT || t.aux > C_UGE || !is_int(lt) || nb > 32 || nb % 8 != 0 {
            return false;
        }
        let bits = 8 * type_bytes(lt, 8);
        let mut w: u64 = 0;
        for l in 0..64 / bits {
            w |= 1u64 << (l * bits + bits - 1) as u64;
        }
        let at = b.words.len() as u32;
        for _ in 0..nb / 8 {
            b.words.push(w);
        }
        let s = self.before(b, k, i, Inst { op: O_WCONST, ty: vt, aux: 0, a: at, b: nb / 8, c: VNONE });
        let x = self.before(b, k, i, Inst { op: O_XOR, ty: vt, aux: 0, a: t.a, b: s, c: VNONE });
        let y = self.before(b, k, i, Inst { op: O_XOR, ty: vt, aux: 0, a: t.b, b: s, c: VNONE });
        b.insts[i as usize] = Inst { op: O_VCMP, ty: t.ty, aux: t.aux - C_ULT + C_SLT, a: x, b: y, c: VNONE };
        return true;
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

    // Address `i` of block `k`, `ptradd p, (x + y) * s + c` in a loop that defines `x` but neither `p` nor
    // `y`: in place `ptradd q, x * s + c`, `q = ptradd p, y * s` made in the loop's preheader. The same
    // address (both wrap alike); the loop's access steps through `x` alone, the shape the loop vectorizer
    // reads (a row's elements `m[r * w + x]`).
    fn split_base(self: &mut Self, b: &mut Body, k: u32, i: u32) {
        let t = b.insts[i as usize];
        let h = self.inner[k as usize];
        if t.op != O_PTRADD || h == NONE || self.preh[h as usize] == NONE || t.b == VNONE || (t.b & (VPARAM | VFLAG)) != 0 || !self.outside(
            t.a,
            h,
        ) {
            return;
        }
        let s = b.insts[t.b as usize];
        if s.op != O_ADD {
            return;
        }
        for side in 0..2u32 {
            let (x, y) = if side == 0 {
                (s.a, s.b)
            } else {
                (s.b, s.a)
            };
            if self.outside(x, h) || !self.outside(y, h) || const_of(b, y).is_some() {
                continue;
            }
            let p = self.preh[h as usize];
            let at = b.blocks[p as usize].start + b.blocks[p as usize].len - 1;
            let q = self.placed(
                b,
                p,
                at,
                Inst { op: O_PTRADD, ty: T_PTR, aux: t.aux & PTR_SCALE, a: t.a, b: y, c: 0 },
                false,
            );
            // `q` may leave the object: the address is no longer in bounds of its base.
            b.insts[i as usize] = Inst { op: O_PTRADD, ty: T_PTR, aux: t.aux & ~PTR_INBOUNDS, a: q, b: x, c: t.c };
            return;
        }
    }

    // Instruction `i`, a logical shift right of a shift left by the same constant (or left of right): in
    // place the mask of the bits both keep (`x << k >> k` is `x & (ones >> k)`). A shift of a shift the
    // same way, both by constants below the width: in place one shift by their sum (`x << 1 << 62` is
    // `x << 63`); from the width up, 0, or for an arithmetic one the sign (a shift by the width less 1).
    fn shift_pair(self: &mut Self, pk: &Package, b: &mut Body, i: u32) {
        let t = b.insts[i as usize];
        if t.op != O_LSHR && t.op != O_SHL && t.op != O_ASHR || !is_int(t.ty) || t.ty == T_I128 || (t.a & (VPARAM | VFLAG)) != 0 {
            return;
        }
        let x = b.insts[t.a as usize];
        let k = const_of(b, t.b);
        let bits = type_bits(t.ty, pk.ptr_bytes) as u64;
        let k1 = if x.op == t.op {
            const_of(b, x.b)
        } else {
            Option::<u64>::None
        };
        if x.ty == t.ty && k.is_some() && k1.is_some() && k.unwrap() < bits && k1.unwrap() < bits {
            let s = k.unwrap() + k1.unwrap();
            if s >= bits && t.op != O_ASHR {
                b.insts[i as usize] = iconst(t.ty, 0);
                return;
            }
            let sv = self.constant(b, t.ty, s.min(bits - 1));
            b.insts[i as usize] = Inst { op: t.op, ty: t.ty, aux: 0, a: x.a, b: sv, c: VNONE };
            return;
        }
        if t.op == O_ASHR || x.op != if t.op == O_LSHR {
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

    // Store `i` of block `k`, the last of stores of pieces of one integer value `x` (`x as u8`,
    // `(x >> 16) as u16`, ...: `stored_piece`) through one address, with no other memory access between
    // them (up to 3 instructions a byte back), that cover a contiguous range of 2, 4 or 8 of its bytes in
    // its little-endian order: one store of that range of `x` at the lowest offset, the others dropped,
    // untagged (LLVM's store merging). Byte stores in the reverse order store the range's bytes reversed
    // (`Package.bswap`). A run that a store after `i` continues waits for that store. Every native target is
    // little-endian. Whether it did.
    fn combine_stores(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        let (x, s0, n0) = stored_piece(b, t.b, pk.ptr_bytes);
        if x == VNONE {
            return false;
        }
        let xt = b.type_of(x);
        let w = type_bytes(xt, pk.ptr_bytes);
        if !is_int(xt) || xt == T_PTR || xt == T_I128 {
            return false;
        }
        let bk = b.blocks[k as usize];
        let end = bk.start + bk.len;
        // Each step goes forward one instruction of the block.
        let mut j = i + 1;
        for _ in 0..3 * w {
            if j >= end {
                break;
            }
            if self.blk_of[j as usize] == k && self.repl[j as usize] != DROPPED {
                let u = b.insts[j as usize];
                if u.op == O_STORE {
                    if u.a == t.a && stored_piece(b, u.b, pk.ptr_bytes).0 == x {
                        return false;
                    }
                    break;
                }
                if u.op == O_LOAD || writes_memory(u) || is_terminator(u.op) {
                    break;
                }
            }
            j += 1;
        }
        // Per byte of `x`, the offset its store writes (`i64::MIN`: none); the other stores of the run.
        let mut at = [i64::MIN; 8];
        for q in 0..n0 {
            at[(s0 + q) as usize] = t.c as i32 + q as i64;
        }
        let mut run = StaticVector::<u32, 8>::new();
        let mut bytes = n0 == 1;
        j = i;
        // Each step goes back one instruction of the block: a piece's store, its shift and its truncation.
        for _ in 0..3 * w {
            if j == bk.start {
                break;
            }
            j -= 1;
            if self.blk_of[j as usize] != k || self.repl[j as usize] == DROPPED {
                continue;
            }
            let u = b.insts[j as usize];
            if u.op == O_STORE {
                let (y, s, n) = stored_piece(b, u.b, pk.ptr_bytes);
                if y != x || u.a != t.a || u.aux != t.aux || run.len() == 7 {
                    break;
                }
                for q in s..s + n {
                    if at[q as usize] != i64::MIN {
                        return false;
                    }
                    at[q as usize] = u.c as i32 + (q - s) as i64;
                }
                bytes = bytes && n == 1;
                run.push(j);
                continue;
            }
            if u.op == O_LOAD || writes_memory(u) || is_terminator(u.op) {
                break;
            }
        }
        if run.len() == 0 {
            return false;
        }
        // The covered bytes `lo` to `hi`, every one between.
        let mut lo = w;
        let mut hi: u32 = 0;
        for q in 0..w {
            if at[q as usize] != i64::MIN {
                lo = lo.min(q);
                hi = q;
            }
        }
        let n = hi - lo + 1;
        if n != 2 && n != 4 && n != 8 {
            return false;
        }
        // Byte `q` at `at[lo] + q - lo` (little-endian) or at `at[hi] + hi - q` (big-endian).
        let mut le = true;
        let mut be = pk.bswap && bytes;
        for q in lo..hi + 1 {
            let a = at[q as usize];
            le = le && a != i64::MIN && a == at[lo as usize] + (q - lo) as i64;
            be = be && a != i64::MIN && a == at[hi as usize] + (hi - q) as i64;
        }
        if !le && !be {
            return false;
        }
        let pt = if n == 2 {
            T_I16
        } else if n == 4 {
            T_I32
        } else {
            T_I64
        };
        let mut v = x;
        if lo != 0 {
            let sh = self.constant(b, xt, 8 * lo as u64);
            v = self.made(pk, b, k, i, Inst { op: O_LSHR, ty: xt, aux: 0, a: v, b: sh, c: VNONE });
        }
        if pt != xt {
            v = self.made(pk, b, k, i, Inst { op: O_TRUNC, ty: pt, aux: 0, a: v, b: VNONE, c: VNONE });
        }
        if !le {
            v = self.made(pk, b, k, i, Inst { op: O_BSWAP, ty: pt, aux: 0, a: v, b: VNONE, c: VNONE });
        }
        for q in 0..run.len() {
            self.repl[run[q] as usize] = DROPPED;
        }
        let off = if le {
            at[lo as usize]
        } else {
            at[hi as usize]
        };
        b.insts[i as usize] = Inst {
            op: O_STORE,
            ty: T_NONE,
            aux: t.aux & ~MEM_TBAA,
            a: t.a,
            b: v,
            c: (off as i32) as u32,
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

    // `and` or `or` `i` (block `k`) of two comparisons of one value `x` with two others in one direction:
    // one comparison with their minimum or maximum (`x <u a && x <u b` is `x <u umin(a, b)`, `x >=u a ||
    // x >=u b` is `x >=u umin(a, b)`; the maximum for the other two; signed the same), as a loop that
    // stops at the end of either of two slices tests (`zip`). Whether it did.
    fn bound_min(self: &mut Self, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if !is_op(b, t.a, O_ICMP) || !is_op(b, t.b, O_ICMP) || t.a == t.b {
            return false;
        }
        // Each as `x c y` with `x` the shared value.
        let p = b.insts[t.a as usize];
        let q = b.insts[t.b as usize];
        let (x, pc, pa, qc, qa) = if p.a == q.a {
            (p.a, p.aux, p.b, q.aux, q.b)
        } else if p.b == q.b {
            (p.b, mirror(p.aux), p.a, mirror(q.aux), q.a)
        } else if p.a == q.b {
            (p.a, p.aux, p.b, mirror(q.aux), q.a)
        } else if p.b == q.a {
            (p.b, mirror(p.aux), p.a, q.aux, q.b)
        } else {
            (VNONE, 0u16, VNONE, 0u16, VNONE)
        };
        if x == VNONE || pc != qc || pc == C_EQ || pc == C_NE || pa == qa || !is_int(b.type_of(x)) || b.type_of(x) == T_I128 {
            return false;
        }
        // `x` below the bound (`<`, `<=`): `and` takes the minimum; above it, `or` does.
        let below = pc == C_ULT || pc == C_ULE || pc == C_SLT || pc == C_SLE;
        let min = below == (t.op == O_AND);
        let signed = pc >= C_SLT && pc <= C_SGE;
        let ty = b.type_of(pa);
        let lt = self.before(
            b,
            k,
            i,
            Inst {
                op: O_ICMP,
                ty: T_I8,
                aux: if signed {
                    C_SLT
                } else {
                    C_ULT
                },
                a: pa,
                b: qa,
                c: VNONE,
            },
        );
        let m = self.before(
            b,
            k,
            i,
            Inst {
                op: O_SELECT,
                ty: ty,
                aux: 0,
                a: lt,
                b: if min {
                    pa
                } else {
                    qa
                },
                c: if min {
                    qa
                } else {
                    pa
                },
            },
        );
        b.insts[i as usize] = Inst { op: O_ICMP, ty: t.ty, aux: pc, a: x, b: m, c: VNONE };
        // The minimum or maximum, made before `i`, leaves its loop in one more walk.
        self.refold = true;
        return true;
    }

    // Branch `i` of block `k` that leaves for block `x`, its other side block `s` (no other predecessor, no
    // effect but its branch), whose branch leaves for `x` with the same arguments or goes on: one branch
    // in `k` on both conditions (`c1 || c2` when both leave where they hold, `c1 && c2` when both stay
    // where they hold, the second comparison's opposite when they differ), `s` going on alone; the
    // second condition, a comparison of values from outside `s`, copied to `k`'s end. Two exits of a loop
    // (a `zip`'s two ends) become one test. Whether it did.
    fn merge_exits(self: &mut Self, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if (t.a & (VPARAM | VFLAG)) != 0 || t.a == VNONE || same_edge(b, t.b, t.c) {
            return false;
        }
        for side in 0..2u32 {
            let (ex, stay) = if side == 0 {
                (t.b, t.c)
            } else {
                (t.c, t.b)
            };
            let s = b.edge_target(stay);
            let x = b.edge_target(ex);
            if s == k || s == x || b.edge_nargs(stay) != 0 || self.pred_at[s as usize + 1] - self.pred_at[s as usize] != 1 {
                continue;
            }
            let ts = term(b, s);
            if ts.op != O_BR || same_edge(b, ts.b, ts.c) || (ts.a & (VPARAM | VFLAG)) != 0 || ts.a == VNONE || !is_op(
                b,
                ts.a,
                O_ICMP,
            ) {
                continue;
            }
            let ex2_true = b.edge_target(ts.b) == x && self.args_alike(b, ts.b, ex);
            let ex2_false = b.edge_target(ts.c) == x && self.args_alike(b, ts.c, ex);
            if !ex2_true && !ex2_false {
                continue;
            }
            // `s` does nothing but its branch: loads and pure instructions alone.
            let sb = b.blocks[s as usize];
            let mut quiet = true;
            for j in sb.start..sb.start + sb.len - 1 {
                quiet = quiet && (droppable(b.insts[j as usize]) || self.repl[j as usize] != VNONE);
            }
            let c2 = b.insts[ts.a as usize];
            let outside = |v: Value| (v & (VPARAM | VFLAG)) != 0 && v != VNONE && self.pblock[(v & ~VPARAM) as usize] != s || (v & (VPARAM | VFLAG)) == 0 && v != VNONE && self.blk_of[v as usize] != s;
            if !quiet || !outside(c2.a) || !outside(c2.b) {
                continue;
            }
            // Where `k` leaves: on `c1` true (side 0) or false; `s` alike. The second condition in `k`'s sense.
            let k_true = side == 0;
            let same = k_true == ex2_true;
            let c2k = self.placed(
                b,
                k,
                i,
                Inst {
                    op: O_ICMP,
                    ty: T_I8,
                    aux: if same {
                        c2.aux
                    } else {
                        opposite(c2.aux)
                    },
                    a: c2.a,
                    b: c2.b,
                    c: VNONE,
                },
                false,
            );
            let both = self.placed(
                b,
                k,
                i,
                Inst {
                    op: if k_true {
                        O_OR
                    } else {
                        O_AND
                    },
                    ty: T_I8,
                    aux: 0,
                    a: t.a,
                    b: c2k,
                    c: VNONE,
                },
                false,
            );
            b.insts.index_mut(i as usize).a = both;
            // `s` goes on: its branch on the constant that takes the other side.
            let on = self.constant(b, T_I8, (!ex2_true) as u64);
            let ti = sb.start + sb.len - 1;
            b.insts.index_mut(ti as usize).a = on;
            return true;
        }
        return false;
    }

    // Whether edges `e` and `f` pass the same values.
    fn args_alike(self: &Self, b: &Body, e: u32, f: u32) bool {
        if b.edge_nargs(e) != b.edge_nargs(f) {
            return false;
        }
        for q in 0..b.edge_nargs(e) {
            if self.val(b.edge_arg(e, q)) != self.val(b.edge_arg(f, q)) {
                return false;
            }
        }
        return true;
    }

    // `and` `i` (block `k`) of `x != 0` and `(x & (x - 1)) == 0`, either order, `x` an integer: whether `x`
    // is a power of two, in place `(x ^ (x - 1)) >u x - 1`; the `or` of their opposites `<=u` (LLVM's
    // expansion of `ctpop(x) == 1` without a population count). Whether it did.
    fn pow2_test(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        let neg = t.op == O_OR;
        for q in 0..2u32 {
            let (p, z) = if q == 0 {
                (t.a, t.b)
            } else {
                (t.b, t.a)
            };
            let x = zero_test(b, p, neg);
            let d = low_clear(b, pk.ptr_bytes, z, neg, x);
            if x != VNONE && d != VNONE {
                let ty = b.type_of(x);
                let xd = self.before(b, k, i, Inst { op: O_XOR, ty: ty, aux: 0, a: x, b: d, c: VNONE });
                b.insts[i as usize] = Inst {
                    op: O_ICMP,
                    ty: t.ty,
                    aux: if neg {
                        C_ULE
                    } else {
                        C_UGT
                    },
                    a: xd,
                    b: d,
                    c: VNONE,
                };
                return true;
            }
        }
        return false;
    }

    // Comparison `i` of an extended value with a constant its type holds, or of two values extended the
    // same way from one type: the comparison of the narrow values (an equality or an order that the
    // extension keeps: unsigned for `zext`, signed for `sext`). Whether it did.
    fn narrow_cmp(self: &mut Self, pk: &Package, b: &mut Body, i: u32) bool {
        let t = b.insts[i as usize];
        let (ea, eb) = (extension(b, t.a), extension(b, t.b));
        let e = if ea.op != O_ICONST {
            ea
        } else {
            eb
        };
        if e.op == O_ICONST || is_vec(b.type_of(t.a)) {
            return false;
        }
        let nt = b.type_of(e.a);
        let sg = e.op == O_SEXT;
        let eq = t.aux == C_EQ || t.aux == C_NE;
        let ok = eq || sg == (t.aux == C_SLT || t.aux == C_SLE || t.aux == C_SGT || t.aux == C_SGE);
        if !ok || !is_int(nt) || nt == T_I128 {
            return false;
        }
        if ea.op == e.op && eb.op == e.op && b.type_of(eb.a) == nt {
            b.insts[i as usize] = Inst { op: O_ICMP, ty: t.ty, aux: t.aux, a: ea.a, b: eb.a, c: VNONE };
            return true;
        }
        let kv = const_of(
            b,
            if ea.op != O_ICONST {
                t.b
            } else {
                t.a
            },
        );
        if kv.is_none() {
            return false;
        }
        let wt = b.type_of(t.a);
        let wb = type_bits(wt, pk.ptr_bytes);
        let nb = type_bits(nt, pk.ptr_bytes);
        let c = kv.unwrap() & width_mask(wt, pk.ptr_bytes);
        let low = c & width_mask(nt, pk.ptr_bytes);
        // The constant is an extension of its low bits the same way.
        let fits = if sg {
            let top = (low >> (nb - 1) as u64 & 1) != 0;
            let ext = if top {
                low | width_mask(wt, pk.ptr_bytes) & ~width_mask(nt, pk.ptr_bytes)
            } else {
                low
            };
            ext == c
        } else {
            low == c
        };
        if !fits || nb >= wb {
            return false;
        }
        let n = self.constant(b, nt, low);
        b.insts[i as usize] = if ea.op != O_ICONST {
            Inst { op: O_ICMP, ty: t.ty, aux: t.aux, a: ea.a, b: n, c: VNONE }
        } else {
            Inst { op: O_ICMP, ty: t.ty, aux: t.aux, a: n, b: eb.a, c: VNONE }
        };
        return true;
    }

    // Truncation `i` (block `k`) of an addition, subtraction, product, bitwise operation or left shift by
    // less than its width of a value extended from its type or a narrower one and a constant: that
    // operation at its type on the value
    // (extended the same way to it) and the constant's low bits (the result's low bits are the
    // operands'), simplified. Whether it did.
    fn narrow_const(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if !is_int(t.ty) || (t.a & (VPARAM | VFLAG)) != 0 || t.a == VNONE {
            return false;
        }
        let w = b.insts[t.a as usize];
        // A left shift by less than the narrow width: its low bits are the shifted value's.
        let shl = w.op == O_SHL && const_of(b, w.b).is_some() && const_of(b, w.b).unwrap() < type_bits(
            t.ty,
            pk.ptr_bytes,
        ) as u64;
        if (w.op < O_ADD || w.op > O_XOR || w.op >= O_SDIV && w.op <= O_UREM) && !shl || !is_int(w.ty) || w.ty == T_I128 {
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

    // Comparison `i` that tests the carry or the signed overflow of an addition or subtraction (`flag_of`):
    // the operation becomes the checked one, whose flag `i` is (`repl`) or whose flag's equality with 0 `i`
    // becomes. Whether it did.
    fn flag_test(self: &mut Self, b: &mut Body, i: u32) bool {
        let (s, signed, negated) = flag_of(b, b.insts[i as usize]);
        if s == VNONE {
            return false;
        }
        let a = b.insts[s as usize];
        let op = if a.op == O_ADD {
            O_ADDO
        } else {
            O_SUBO
        };
        b.insts[s as usize] = Inst {
            op: op,
            ty: a.ty,
            aux: if signed {
                OV_SIGNED
            } else {
                0
            },
            a: a.a,
            b: a.b,
            c: VNONE,
        };
        if negated {
            let z = self.constant(b, T_I8, 0);
            b.insts[i as usize] = Inst { op: O_ICMP, ty: T_I8, aux: C_EQ, a: VFLAG | s, b: z, c: VNONE };
        } else {
            self.repl[i as usize] = VFLAG | s;
        }
        return true;
    }

    // Body `k` of a loop whose header only tests a counter `q` (`counted`'s shape: the body jumps back): each
    // pointer the header carries that the body steps by a constant and alone reads becomes its initial value
    // plus that step times the iterations done, before the body's first instruction; a counter that steps
    // down by 1 to 0, which only its step reads, first counts up from 0 to its initial value. The vectorizer
    // and the unroller read such a loop as indexed (LLVM's canonical induction variable and its rewrite of
    // the others). Whether it did.
    fn index_ivs(self: &mut Self, b: &mut Body, k: u32) bool {
        let h = self.inner[k as usize];
        if h == NONE || h == k {
            return false;
        }
        let hb = b.blocks[h as usize];
        let bk = b.blocks[k as usize];
        let tk = term(b, k);
        let th = term(b, h);
        if bk.len < 2 || hb.len != 2 || tk.op != O_JMP || b.edge_target(tk.a) != h || th.op != O_BR || th.a != hb.start || self.pred_at[h as usize + 1] - self.pred_at[h as usize] != 2 {
            return false;
        }
        let stay_t = b.edge_target(th.b) == k;
        let se = if stay_t {
            th.b
        } else {
            th.c
        };
        if !stay_t && b.edge_target(th.c) != k || b.edge_nargs(se) != 0 {
            return false;
        }
        // The preheader's edge.
        let mut pe = NONE;
        for j in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
            let pb = self.preds[j as usize];
            if pb != k {
                let tp = term(b, pb);
                b.succ_edges(tp, &mut self.edges);
                for e in 0..self.edges.len() {
                    if b.edge_target(self.edges[e]) == h {
                        pe = self.edges[e];
                    }
                }
            }
        }
        if pe == NONE {
            return false;
        }
        // The counter: the test of a parameter with a value from outside the loop.
        let c = b.insts[th.a as usize];
        if c.op != O_ICMP {
            return false;
        }
        let np = hb.param_len as u32;
        let mut m = NONE;
        for q in 0..np {
            let pv = VPARAM | hb.param_start + q;
            if c.a == pv && outside(b, c.b, h) || c.b == pv && outside(b, c.a, h) {
                m = q;
            }
        }
        if m == NONE {
            return false;
        }
        let qv = VPARAM | hb.param_start + m;
        let qt = b.params[(hb.param_start + m) as usize];
        let qnext = b.edge_arg(tk.a, m);
        let step = counter_step(b, qnext, qv);
        if step == 0 || !in_block(b, qnext, k) || !is_int(qt) || qt == T_PTR || qt == T_I128 {
            return false;
        }
        let q0 = self.val(b.edge_arg(pe, m));
        // Down by 1 to 0: `q != 0` stays, `q == 0` leaves.
        let bound = if c.a == qv {
            c.b
        } else {
            c.a
        };
        let down = step == 2 && const_of(b, bound) == Some(0u64) && (stay_t && c.aux == C_NE || !stay_t && c.aux == C_EQ);
        let up = step == 1 && const_of(b, q0) == Some(0u64);
        if !down && !up {
            return false;
        }
        // The pointers: stepped in the body by a constant, read in it alone.
        let mut ivs = StaticVector::<(u32, u32), 8>::new();
        for q in 0..np {
            let pn = b.edge_arg(tk.a, q);
            let s = ptr_step(b, pn, VPARAM | hb.param_start + q);
            if q != m && s != 0 && in_block(b, pn, k) && ivs.len() < 8 && self.only_in(
                b,
                VPARAM | hb.param_start + q,
                k,
            ) {
                ivs.push((q, s));
            }
        }
        if ivs.len() == 0 || down && !self.only_step(b, qv, qnext, h) {
            return false;
        }
        if down {
            // Count up from 0 to the initial value: the preheader passes 0, the body adds 1, the header tests
            // the count against the initial value.
            let z = self.constant(b, qt, 0);
            b.pool[(pe + 2 + m) as usize] = z;
            let sn = b.insts[qnext as usize];
            let one = self.constant(b, qt, 1);
            b.insts[qnext as usize] = Inst { op: O_ADD, ty: qt, aux: 0, a: sn.a, b: one, c: VNONE };
            if c.a == qv {
                b.insts.index_mut(th.a as usize).b = q0;
            } else {
                b.insts.index_mut(th.a as usize).a = q0;
            }
        }
        for x in 0..ivs.len() {
            let (q, s) = ivs[x];
            let p0 = self.val(b.edge_arg(pe, q));
            let pv = self.before(b, k, bk.start, Inst { op: O_PTRADD, ty: T_PTR, aux: s as u16, a: p0, b: qv, c: 0 });
            self.prepl[(hb.param_start + q) as usize] = pv;
        }
        return true;
    }

    // Whether value `v` is read by instructions and edges of block `k` alone.
    fn only_in(self: &mut Self, b: &Body, v: Value, k: u32) bool {
        for j in 0..b.blocks.len() {
            if j as u32 == k {
                continue;
            }
            let bj = b.blocks[j];
            for i in bj.start..bj.start + bj.len {
                lv::uses(b, b.insts[i as usize], &mut self.uses);
                for u in 0..self.uses.len() {
                    if self.uses[u] == v {
                        return false;
                    }
                }
                b.succ_edges(b.insts[i as usize], &mut self.edges);
                for e in 0..self.edges.len() {
                    for q in 0..b.edge_nargs(self.edges[e]) {
                        if b.edge_arg(self.edges[e], q) == v {
                            return false;
                        }
                    }
                }
            }
        }
        return true;
    }

    // Whether counter `q` of header `h` is read only there and by `next`, its step.
    fn only_step(self: &mut Self, b: &Body, q: Value, next: Value, h: u32) bool {
        for j in 0..b.blocks.len() {
            let bj = b.blocks[j];
            for i in bj.start..bj.start + bj.len {
                if i == next || j as u32 == h {
                    continue;
                }
                lv::uses(b, b.insts[i as usize], &mut self.uses);
                for u in 0..self.uses.len() {
                    if self.uses[u] == q {
                        return false;
                    }
                }
                b.succ_edges(b.insts[i as usize], &mut self.edges);
                for e in 0..self.edges.len() {
                    for x in 0..b.edge_nargs(self.edges[e]) {
                        if b.edge_arg(self.edges[e], x) == q {
                            return false;
                        }
                    }
                }
            }
        }
        return true;
    }

    // Select `i` of block `k` on a comparison or a checked operation's flag defined earlier in `k`, which no
    // instruction between reads (up to FLAG_REACH back): that definition moves right before `i`, where
    // every backend tests its flags in place rather than setting a register.
    fn flag_next(self: &mut Self, b: &Body, k: u32, i: u32) {
        let c = b.insts[i as usize].a;
        if c == VNONE || (c & VPARAM) != 0 {
            return;
        }
        let s = c & ~VFLAG;
        let d = b.insts[s as usize];
        let ok = if (c & VFLAG) != 0 {
            d.op >= O_ADDO && d.op <= O_MULO
        } else {
            d.op == O_ICMP || d.op == O_FCMP
        };
        if !ok || s >= i || self.blk_of[s as usize] != k || self.moved[s as usize] || i - s > FLAG_REACH {
            return;
        }
        // Whether an instruction lies between: else the definition is in place already.
        let mut between = false;
        for j in s + 1..i {
            if self.blk_of[j as usize] != k || self.repl[j as usize] == DROPPED {
                continue;
            }
            if self.reads(b, j, s) {
                return;
            }
            between = between || !self.moved[j as usize] && self.repl[j as usize] == VNONE;
        }
        // The instructions the walk made before those (`pre`): the newest entries, from the last back.
        let mut q = self.pre.len();
        // Each step goes back one entry.
        while q > 0 {
            q -= 1;
            let at = (self.pre[q] >> 32) as u32;
            if at <= s || at > i || self.blk_of[at as usize] != k {
                break;
            }
            if self.reads(b, self.pre[q] as u32, s) {
                return;
            }
            between = true;
        }
        if !between {
            return;
        }
        self.moved[s as usize] = true;
        self.pre.push(i as u64 << 32 | s as u64);
    }

    // Branch `t` ending block `k` on a comparison in `k` of an `add` or `sub` of `k` by a constant (a counter's
    // step), or on whether an `add`, `sub` or `and` of `k` equals 0: when instructions lie between them and
    // read neither (up to FLAG_REACH back), the operation moves right before the comparison. Its operand's
    // reads end before it, so the step writes the operand's register in place, and every backend tests
    // the flags it sets against 0.
    fn step_next(self: &mut Self, b: &Body, k: u32, t: Inst) {
        let c = t.a;
        if c == VNONE || (c & (VPARAM | VFLAG)) != 0 || self.blk_of[c as usize] != k || self.moved[c as usize] {
            return;
        }
        let ct = b.insts[c as usize];
        if ct.op != O_ICMP {
            return;
        }
        let eq = ct.aux == C_EQ || ct.aux == C_NE;
        let s = if eq && const_of(b, ct.b) == Some(0u64) {
            ct.a
        } else if eq && const_of(b, ct.a) == Some(0u64) {
            ct.b
        } else if self.counter_step(b, ct.a) {
            ct.a
        } else if self.counter_step(b, ct.b) {
            ct.b
        } else {
            VNONE
        };
        if s == VNONE || (s & (VPARAM | VFLAG)) != 0 || s >= c || self.blk_of[s as usize] != k || self.moved[s as usize] || c - s > FLAG_REACH {
            return;
        }
        let d = b.insts[s as usize].op;
        if d != O_ADD && d != O_SUB && d != O_AND {
            return;
        }
        let mut between = false;
        for j in s + 1..c {
            if self.blk_of[j as usize] != k || self.repl[j as usize] == DROPPED {
                continue;
            }
            if self.reads(b, j, s) {
                return;
            }
            between = between || !self.moved[j as usize] && self.repl[j as usize] == VNONE;
        }
        // The instructions the walk made before those (`pre`): the newest entries, from the last back.
        let mut q = self.pre.len();
        // Each step goes back one entry.
        while q > 0 {
            q -= 1;
            let at = (self.pre[q] >> 32) as u32;
            if at <= s || at > c || self.blk_of[at as usize] != k {
                break;
            }
            if self.reads(b, self.pre[q] as u32, s) {
                return;
            }
            between = true;
        }
        if !between {
            return;
        }
        self.moved[s as usize] = true;
        self.pre.push(c as u64 << 32 | s as u64);
    }

    // Select `i` of `n - a` where `a <u n` or `a <=u n` holds and of 0 else (a subtraction floored at 0, as a
    // vector loop's remainder count takes it) when `a <=u n` always holds (`at_most`): the subtraction.
    // VNONE else.
    fn floor_sub(self: &Self, b: &Body, i: u32) Value {
        let t = b.insts[i as usize];
        let c = self.val(t.a);
        if is_vec(t.ty) || t.ty == T_I128 || c == VNONE || (c & (VPARAM | VFLAG)) != 0 || b.insts[c as usize].op != O_ICMP {
            return VNONE;
        }
        let tb = self.val(t.b);
        let tc = self.val(t.c);
        let on_true = const_of(b, tc) == Some(0u64);
        let s = if on_true {
            tb
        } else if const_of(b, tb) == Some(0u64) {
            tc
        } else {
            VNONE
        };
        if s == VNONE || (s & (VPARAM | VFLAG)) != 0 || b.insts[s as usize].op != O_SUB {
            return VNONE;
        }
        let n = self.val(b.insts[s as usize].a);
        let a = self.val(b.insts[s as usize].b);
        let ct = b.insts[c as usize];
        let (ca, cb) = (self.val(ct.a), self.val(ct.b));
        let aux = if ca == a && cb == n {
            ct.aux
        } else if ca == n && cb == a {
            mirror(ct.aux)
        } else {
            return VNONE;
        };
        let ok = if on_true {
            aux == C_ULT || aux == C_ULE
        } else {
            aux == C_UGE || aux == C_UGT
        };
        if !ok || !self.at_most(b, a, n, UB_DEPTH) {
            return VNONE;
        }
        return s;
    }

    // Whether `a <=u n` always holds: `a` is `n`, 0, an `and` with an operand that is at most `n`, a select
    // of two, or a parameter every edge into its block passes such a value for (up to `depth` deep).
    fn at_most(self: &Self, b: &Body, a: Value, n: Value, depth: u32) bool {
        if a == n || const_of(b, a) == Some(0u64) {
            return true;
        }
        if depth == 0 || (a & VFLAG) != 0 {
            return false;
        }
        if (a & VPARAM) == 0 {
            let x = b.insts[a as usize];
            if x.op == O_SELECT {
                let (l, r) = (self.val(x.b), self.val(x.c));
                return self.at_most(b, l, n, depth - 1) && self.at_most(b, r, n, depth - 1);
            }
            if x.op != O_AND {
                return false;
            }
            let (p, q) = (self.val(x.a), self.val(x.b));
            return self.at_most(b, p, n, depth - 1) || self.at_most(b, q, n, depth - 1);
        }
        // A parameter or block the walk added has no entry in the maps.
        let k = if (a & ~VPARAM) as usize < self.pblock.len() {
            self.def_blk(a)
        } else {
            NONE
        };
        if k == NONE || k == 0 || k as usize >= self.rpo.len() || k as usize + 1 >= self.pred_at.len() || self.rpo[k as usize] == NONE {
            return false;
        }
        let np = self.pred_at[k as usize + 1] - self.pred_at[k as usize];
        if np == 0 || np > IMPLY_FAN {
            return false;
        }
        let q = (a & ~VPARAM) - b.blocks[k as usize].param_start;
        for x in self.pred_at[k as usize]..self.pred_at[k as usize + 1] {
            let st = term(b, self.preds[x as usize]);
            for e in 0..edge_count(st) {
                let ed = edge_at(b, st, e);
                if b.edge_target(ed) == k && !self.at_most(b, self.val(b.edge_arg(ed, q)), n, depth - 1) {
                    return false;
                }
            }
        }
        return true;
    }

    // Whether `v` is an `add` or `sub` of a value by a constant.
    fn counter_step(self: &Self, b: &Body, v: Value) bool {
        if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let x = b.insts[v as usize];
        return (x.op == O_ADD || x.op == O_SUB) && (const_of(b, x.b).is_some() || x.op == O_ADD && const_of(b, x.a).is_some());
    }

    // Whether instruction `j` reads value `s` or its flag (operands as the walk replaced them).
    fn reads(self: &mut Self, b: &Body, j: u32, s: u32) bool {
        lv::uses(b, b.insts[j as usize], &mut self.uses);
        for u in 0..self.uses.len() {
            let v = self.val(self.uses[u]);
            if v == s || v == (VFLAG | s) {
                return true;
            }
        }
        return false;
    }

    // Select `i` of block `k` of `~c` or `c` by the sign of `x`, an integer of its type: `(x >>s (n - 1)) ^ c`,
    // no compare (LLVM InstCombine's select of a sign test). Whether it did.
    fn sign_select(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if !is_int(t.ty) || t.ty == T_PTR || t.ty == T_I128 || t.a == VNONE || (t.a & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let c = b.insts[t.a as usize];
        if c.op != O_ICMP || const_of(b, c.b) != Some(0u64) || c.aux != C_SLT && c.aux != C_SGE || b.type_of(c.a) != t.ty {
            return false;
        }
        let x = const_of(b, t.b);
        let y = const_of(b, t.c);
        let m = width_mask(t.ty, pk.ptr_bytes);
        if x.is_none() || y.is_none() || ((x.unwrap() ^ y.unwrap()) & m) != m {
            return false;
        }
        // The constant where `x` is not negative.
        let k0 = if c.aux == C_SLT {
            y.unwrap()
        } else {
            x.unwrap()
        };
        let sh = self.constant(b, t.ty, type_bits(t.ty, pk.ptr_bytes) as u64 - 1);
        let sg = self.made(pk, b, k, i, Inst { op: O_ASHR, ty: t.ty, aux: 0, a: c.a, b: sh, c: VNONE });
        let kv = self.constant(b, t.ty, k0 & m);
        b.insts[i as usize] = Inst { op: O_XOR, ty: t.ty, aux: 0, a: sg, b: kv, c: VNONE };
        let _ = self.number(pk, b, k, i);
        return true;
    }

    // Integer comparison `i` of block `k` of a select with a constant, whose arms are each a constant, a
    // three-way comparison (`order_test`) or such a select, ZO_DEPTH deep: a select of the arms'
    // comparisons, each a flag constant or one comparison (LLVM InstCombine's fold of a compare into a
    // select whose arms simplify). Whether it did.
    fn icmp_select(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if t.aux > C_UGE {
            return false;
        }
        let left = const_of(b, t.b).is_some();
        let s = if left {
            t.a
        } else {
            t.b
        };
        if !left && const_of(b, t.a).is_none() || (s & (VPARAM | VFLAG)) != 0 || s == VNONE || b.insts[s as usize].op != O_SELECT || !cmp_arm(
            pk,
            b,
            t,
            left,
            s,
            ZO_DEPTH,
        ) {
            return false;
        }
        self.repl[i as usize] = self.cmp_into(pk, b, k, i, t, left, s);
        return true;
    }

    // Comparison `t` with value `v` in place of its non-constant side (`left`: its first), made before
    // instruction `i` of block `k`, through the selects `cmp_arm` accepts. The value made.
    fn cmp_into(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32, t: Inst, left: bool, v: Value) Value {
        let mut u = t;
        if left {
            u.a = v;
        } else {
            u.b = v;
        }
        let x = const_of(b, u.a);
        let y = const_of(b, u.b);
        if x.is_some() && y.is_some() {
            return self.constant(
                b,
                t.ty,
                holds_const(u.aux, x.unwrap(), y.unwrap(), type_bits(b.type_of(v), pk.ptr_bytes)) as u64,
            );
        }
        let f = order_test(b, u, pk.ptr_bytes);
        if f.is_some() {
            return self.made(pk, b, k, i, f.unwrap());
        }
        let sel = b.insts[v as usize];
        let p = self.cmp_into(pk, b, k, i, t, left, sel.b);
        let q = self.cmp_into(pk, b, k, i, t, left, sel.c);
        return self.made(pk, b, k, i, Inst { op: O_SELECT, ty: t.ty, aux: 0, a: sel.a, b: p, c: q });
    }

    fn fold_ptr(self: &Self, pk: &Package, b: &mut Body, i: u32) bool {
        return fold_ptr(pk, b, i, self.unit);
    }

    // Call `i` of block `k` of the C library's `memcmp` of a count up to MEMCMP_MAX bytes that is a constant
    // or that a branch into the block settles: loads of both sides, the widest power of two of at most 8
    // bytes, up to MEMCMP_LOADS each, the last overlapping the one before for a count it does not divide
    // (LLVM ExpandMemCmp). A result whose one reader is an equality with 0 right after is whether a pair
    // differs: then the widest power of two that fits each remaining count, unless that takes more loads
    // than the overlapping ones (5 bytes as 4 and 1, 7 as two overlapping 4), a narrower pair extended to
    // the widest. Another is the order of the first pair that differs, compared as big-endian
    // numbers (`Package.bswap`). A load of read-only data folds to its constant. Whether it did.
    fn memcmp_eq(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        let bk = b.blocks[k as usize];
        if t.aux != 3 || t.ty != T_I32 {
            return false;
        }
        let mut eq = false;
        if i as usize < self.icount.len() && self.icount[i as usize] == 1 && i + 1 < bk.start + bk.len {
            let u = b.insts[i as usize + 1];
            eq = u.op == O_ICMP && (u.aux == C_EQ || u.aux == C_NE) && (u.a == i && const_of(b, u.b) == Some(0u64) || u.b == i && const_of(
                b,
                u.a,
            ) == Some(0u64));
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
        let w: u32 = if c >= 8 {
            8
        } else if c >= 4 {
            4
        } else if c >= 2 {
            2
        } else {
            1
        };
        let parts = (c + w - 1) / w;
        if parts > MEMCMP_LOADS || !eq && w > 1 && !pk.bswap {
            return false;
        }
        let ty = if w == 8 {
            T_I64
        } else if w == 4 {
            T_I32
        } else if w == 2 {
            T_I16
        } else {
            T_I8
        };
        let mut la = StaticVector::<Value, 4>::new();
        let mut lb = StaticVector::<Value, 4>::new();
        for q in 0..parts {
            let off = (q * w).min(c - w);
            let x = self.made(pk, b, k, i, Inst { op: O_LOAD, ty: ty, aux: 0, a: pa, b: VNONE, c: off });
            let _ = fold_data(pk, b, x);
            let y = self.made(pk, b, k, i, Inst { op: O_LOAD, ty: ty, aux: 0, a: pb, b: VNONE, c: off });
            let _ = fold_data(pk, b, y);
            la.push(x);
            lb.push(y);
        }
        // Equality over fewer loads of falling widths (4 and 1 for 5 bytes) when they take no more.
        let mut np: u32 = 0;
        let mut left = c;
        while left != 0 {
            let s = if left >= 8 {
                8u32
            } else if left >= 4 {
                4u32
            } else if left >= 2 {
                2u32
            } else {
                1u32
            };
            left -= s;
            np += 1;
        }
        if eq && np <= parts && np > 1 {
            // With conditional comparisons (`Package.ccmp`), the reader is the pairs' equalities' `and` (its
            // test `== 0`) or their inequalities' `or` (`!= 0`), and the call's result goes; else the
            // reader tests the `or` of the pairs' differences.
            let ui = i + 1;
            let rel = b.insts[ui as usize].aux;
            let mut d = VNONE;
            let mut off: u32 = 0;
            for q in 0..np {
                let s = if c - off >= 8 {
                    8u32
                } else if c - off >= 4 {
                    4u32
                } else if c - off >= 2 {
                    2u32
                } else {
                    1u32
                };
                // A narrower pair loads zero-extended to the widest width.
                let st = int_type_of(s);
                let mut x = self.made(pk, b, k, i, Inst { op: O_LOAD, ty: st, aux: 0, a: pa, b: VNONE, c: off });
                let _ = fold_data(pk, b, x);
                let mut y = self.made(pk, b, k, i, Inst { op: O_LOAD, ty: st, aux: 0, a: pb, b: VNONE, c: off });
                let _ = fold_data(pk, b, y);
                if st != ty {
                    x = self.made(pk, b, k, i, Inst { op: O_ZEXT, ty: ty, aux: 0, a: x, b: VNONE, c: VNONE });
                    y = self.made(pk, b, k, i, Inst { op: O_ZEXT, ty: ty, aux: 0, a: y, b: VNONE, c: VNONE });
                }
                off += s;
                if pk.ccmp {
                    let z = self.made(pk, b, k, i, Inst { op: O_ICMP, ty: T_I8, aux: rel, a: x, b: y, c: VNONE });
                    if q == 0 {
                        d = z;
                        continue;
                    }
                    let o = Inst {
                        op: if rel == C_EQ {
                            O_AND
                        } else {
                            O_OR
                        },
                        ty: T_I8,
                        aux: 0,
                        a: d,
                        b: z,
                        c: VNONE,
                    };
                    if q + 1 == np {
                        b.insts[ui as usize] = o;
                        b.insts[i as usize] = iconst(T_I32, 0);
                        return true;
                    }
                    d = self.made(pk, b, k, i, o);
                    continue;
                }
                let z = self.made(pk, b, k, i, Inst { op: O_XOR, ty: ty, aux: 0, a: x, b: y, c: VNONE });
                d = if d == VNONE {
                    z
                } else {
                    self.made(pk, b, k, i, Inst { op: O_OR, ty: ty, aux: 0, a: d, b: z, c: VNONE })
                };
            }
            let zero = self.constant(b, ty, 0);
            let ne = self.made(pk, b, k, i, Inst { op: O_ICMP, ty: T_I8, aux: C_NE, a: d, b: zero, c: VNONE });
            b.insts[i as usize] = Inst { op: O_ZEXT, ty: T_I32, aux: 0, a: ne, b: VNONE, c: VNONE };
            return true;
        }
        if eq {
            // One pair: its compare; more: the `or` of their differences against 0.
            let (l, r) = if parts == 1 {
                (la[0], lb[0])
            } else {
                let mut d = VNONE;
                for q in 0..parts as usize {
                    let x = self.made(pk, b, k, i, Inst { op: O_XOR, ty: ty, aux: 0, a: la[q], b: lb[q], c: VNONE });
                    d = if d == VNONE {
                        x
                    } else {
                        self.made(pk, b, k, i, Inst { op: O_OR, ty: ty, aux: 0, a: d, b: x, c: VNONE })
                    };
                }
                (d, self.constant(b, ty, 0))
            };
            let ne = self.made(pk, b, k, i, Inst { op: O_ICMP, ty: T_I8, aux: C_NE, a: l, b: r, c: VNONE });
            b.insts[i as usize] = Inst { op: O_ZEXT, ty: T_I32, aux: 0, a: ne, b: VNONE, c: VNONE };
            return true;
        }
        // From the last pair back: the pair's order where it differs, else the order after it.
        let mut r = VNONE;
        for e in 0..parts as usize {
            let q = parts as usize - 1 - e;
            let mut x = la[q];
            let mut y = lb[q];
            if w > 1 {
                x = self.made(pk, b, k, i, Inst { op: O_BSWAP, ty: ty, aux: 0, a: x, b: VNONE, c: VNONE });
                y = self.made(pk, b, k, i, Inst { op: O_BSWAP, ty: ty, aux: 0, a: y, b: VNONE, c: VNONE });
            }
            let gt = self.made(pk, b, k, i, Inst { op: O_ICMP, ty: T_I8, aux: C_UGT, a: x, b: y, c: VNONE });
            let lt = self.made(pk, b, k, i, Inst { op: O_ICMP, ty: T_I8, aux: C_ULT, a: x, b: y, c: VNONE });
            let g = self.made(pk, b, k, i, Inst { op: O_ZEXT, ty: T_I32, aux: 0, a: gt, b: VNONE, c: VNONE });
            let l = self.made(pk, b, k, i, Inst { op: O_ZEXT, ty: T_I32, aux: 0, a: lt, b: VNONE, c: VNONE });
            let o = Inst { op: O_SUB, ty: T_I32, aux: 0, a: g, b: l, c: VNONE };
            if e == 0 && parts == 1 {
                b.insts[i as usize] = o;
                return true;
            }
            let ov = self.made(pk, b, k, i, o);
            if e == 0 {
                r = ov;
                continue;
            }
            let ne = self.made(pk, b, k, i, Inst { op: O_ICMP, ty: T_I8, aux: C_NE, a: la[q], b: lb[q], c: VNONE });
            let s = Inst { op: O_SELECT, ty: T_I32, aux: 0, a: ne, b: ov, c: r };
            if q == 0 {
                b.insts[i as usize] = s;
                return true;
            }
            r = self.made(pk, b, k, i, s);
        }
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
    // Instruction `x` made before instruction `at` of block `k` (`before`), simplified (`simplify`) as the
    // walk, which has passed it, would: the value it is.
    fn made(self: &mut Self, pk: &Package, b: &mut Body, k: u32, at: u32, x: Inst) Value {
        let v = self.before(b, k, at, x);
        let r = simplify(pk, b, v);
        if r != VNONE {
            self.repl[v as usize] = r;
            return r;
        }
        return v;
    }

    // Instruction `t`, with instruction `at`'s location, at the end of block `k`, before its terminator
    // (`hoisted`); or at the entry's start (`extra`) when `start`.
    fn placed(self: &mut Self, b: &mut Body, k: u32, at: u32, t: Inst, start: bool) Value {
        let v = b.insts.len() as u32;
        b.insts.push(t);
        b.locs.push(b.locs[at as usize]);
        if b.inl.len() != 0 {
            b.inl.push(b.inl[at as usize]);
        }
        self.repl.push(VNONE);
        self.frepl.push(VNONE);
        self.moved.push(true);
        if start {
            self.blk_of.push(0);
            self.extra.push(v);
        } else {
            self.blk_of.push(k);
            self.hoisted.push(k as u64 << 32 | v as u64);
        }
        return v;
    }

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
    // division's), nor an unsigned one by a power of two (`pow2`). A vector's divisor is one constant in
    // every lane, of a size whose high products the backend computes (`Package.vec_mulh`); a scalar of such
    // a size stays while the loop vectorizer may take it (`defer_div`). Whether it did.
    fn divide(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if t.op < O_SDIV || t.op > O_UREM || t.ty == T_I128 || t.ty == T_PTR {
            return false;
        }
        let vec = is_vec(t.ty);
        let lt = if vec {
            lane_type(t.ty)
        } else {
            t.ty
        };
        if !is_int(lt) || vec && (pk.vec_mulh & type_bytes(lt, pk.ptr_bytes) as u8) == 0 {
            return false;
        }
        let c = if vec {
            splat_of(b, t.b)
        } else {
            const_of(b, t.b)
        };
        if c.is_none() {
            return false;
        }
        let bits = type_bits(lt, pk.ptr_bytes);
        let d = c.unwrap() & width_mask(lt, pk.ptr_bytes);
        let signed = t.op == O_SDIV || t.op == O_SREM;
        if signed && (d == 0 || d == width_mask(lt, pk.ptr_bytes)) || !signed && (d == 0 || (d & d - 1) == 0 || bits == 64 && !pk.mul_high) {
            return false;
        }
        if self.defer_div && !vec && (pk.vec_mulh & type_bytes(lt, pk.ptr_bytes) as u8) != 0 {
            self.deferred = true;
            return false;
        }
        if signed {
            return self.divide_signed(pk, b, k, i, le::sign_ext(d, bits));
        }
        let (m, sh, add) = magic(d, bits);
        let n = t.a;
        let mut q = VNONE;
        if bits == 32 && !add && !vec {
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
        let mv = self.lane_const(b, t.ty, m);
        let h = self.before(b, k, i, Inst { op: O_MULHU, ty: t.ty, aux: 0, a: n, b: mv, c: VNONE });
        let mut q = h;
        if add {
            let diff = self.before(b, k, i, Inst { op: O_SUB, ty: t.ty, aux: 0, a: n, b: h, c: VNONE });
            let one = self.lane_const(b, t.ty, 1);
            let half = self.before(b, k, i, Inst { op: O_LSHR, ty: t.ty, aux: 0, a: diff, b: one, c: VNONE });
            q = self.before(b, k, i, Inst { op: O_ADD, ty: t.ty, aux: 0, a: half, b: h, c: VNONE });
        }
        if sh != 0 {
            let sv = self.lane_const(b, t.ty, sh);
            q = self.before(b, k, i, Inst { op: O_LSHR, ty: t.ty, aux: 0, a: q, b: sv, c: VNONE });
        }
        return q;
    }

    // `divide` of signed quotient or remainder `i` by `d`, the constant sign-extended. By a power of two
    // 2^s (or its negation), the dividend plus 2^s - 1 when negative (`bias`), shifted, the remainder the
    // dividend less those bits but the low `s`; by another, `h`: the product by `smagic`'s multiplier `m` of
    // `|d|` over `2^(bits + sh)`, rounded down, of the dividend's sign. Up to 32 bits, the 64-bit product by
    // `m` read unsigned, shifted once (its magnitude is below `2^(2 * bits - 1)`: no correction, Lemire
    // 2026); at 64, the high half of the product by `m`, plus the dividend when `m` is negative, shifted.
    // The quotient rounds toward 0 from the dividend's sign, off `h`'s path: `h + 1` when negative by a
    // positive `d`, `-1 - h` when negative by a negative one, else `h` or `-h`.
    fn divide_signed(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32, d: i64) bool {
        let t = b.insts[i as usize];
        let ty = t.ty;
        let vec = is_vec(ty);
        let lt = if vec {
            lane_type(ty)
        } else {
            ty
        };
        let bits = type_bits(lt, pk.ptr_bytes);
        let quot = t.op == O_SDIV;
        let n = t.a;
        if d == 1 {
            self.repl[i as usize] = if quot {
                n
            } else {
                self.lane_const(b, ty, 0)
            };
            return true;
        }
        let ad = if d < 0 {
            0u64.wrapping_sub(d as u64)
        } else {
            d as u64
        };
        let wm = width_mask(lt, pk.ptr_bytes);
        if (ad & ad - 1) == 0 {
            let s = ad.trailing_zeros() as u64;
            let mut sgn = n;
            if s > 1 {
                let sv = self.lane_const(b, ty, s - 1);
                sgn = self.before(b, k, i, Inst { op: O_ASHR, ty: ty, aux: 0, a: n, b: sv, c: VNONE });
            }
            let rv = self.lane_const(b, ty, bits as u64 - s);
            let bias = self.before(b, k, i, Inst { op: O_LSHR, ty: ty, aux: 0, a: sgn, b: rv, c: VNONE });
            let up = self.before(b, k, i, Inst { op: O_ADD, ty: ty, aux: 0, a: n, b: bias, c: VNONE });
            if !quot {
                let mv = self.lane_const(b, ty, ~(ad - 1) & wm);
                let low = self.before(b, k, i, Inst { op: O_AND, ty: ty, aux: 0, a: up, b: mv, c: VNONE });
                self.repl[i as usize] = self.before(b, k, i, Inst { op: O_SUB, ty: ty, aux: 0, a: n, b: low, c: VNONE });
                return true;
            }
            let sv = self.lane_const(b, ty, s);
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
        let (m, sh) = smagic(ad, bits);
        let h = if bits <= 32 && !vec {
            let w = self.before(b, k, i, Inst { op: O_SEXT, ty: T_I64, aux: 0, a: n, b: VNONE, c: VNONE });
            let mv = self.constant(b, T_I64, m);
            let p = self.before(b, k, i, Inst { op: O_MUL, ty: T_I64, aux: 0, a: w, b: mv, c: VNONE });
            let sv = self.constant(b, T_I64, bits + sh);
            let hw = self.before(b, k, i, Inst { op: O_ASHR, ty: T_I64, aux: 0, a: p, b: sv, c: VNONE });
            self.before(b, k, i, Inst { op: O_TRUNC, ty: ty, aux: 0, a: hw, b: VNONE, c: VNONE })
        } else {
            let mv = self.lane_const(b, ty, m);
            let mut h = self.before(b, k, i, Inst { op: O_MULHS, ty: ty, aux: 0, a: n, b: mv, c: VNONE });
            if le::sign_ext(m, bits) < 0 {
                h = self.before(b, k, i, Inst { op: O_ADD, ty: ty, aux: 0, a: h, b: n, c: VNONE });
            }
            if sh != 0 {
                let sv = self.lane_const(b, ty, sh);
                h = self.before(b, k, i, Inst { op: O_ASHR, ty: ty, aux: 0, a: h, b: sv, c: VNONE });
            }
            h
        };
        let top = self.lane_const(b, ty, bits as u64 - 1);
        let q = if d > 0 {
            let neg = self.before(b, k, i, Inst { op: O_LSHR, ty: ty, aux: 0, a: n, b: top, c: VNONE });
            self.before(b, k, i, Inst { op: O_ADD, ty: ty, aux: 0, a: h, b: neg, c: VNONE })
        } else {
            let sgn = self.before(b, k, i, Inst { op: O_ASHR, ty: ty, aux: 0, a: n, b: top, c: VNONE });
            self.before(b, k, i, Inst { op: O_SUB, ty: ty, aux: 0, a: sgn, b: h, c: VNONE })
        };
        if quot {
            self.repl[i as usize] = q;
            return true;
        }
        let prod = self.before(b, k, i, Inst { op: O_MUL, ty: ty, aux: 0, a: q, b: t.b, c: VNONE });
        self.repl[i as usize] = self.before(b, k, i, Inst { op: O_SUB, ty: ty, aux: 0, a: n, b: prod, c: VNONE });
        return true;
    }

    // Constant `v` of type `ty`: a scalar one (`constant`), or a vector of `v` in every lane, in the entry
    // too, once per type and value.
    fn lane_const(self: &mut Self, b: &mut Body, ty: u8, v: u64) Value {
        if !is_vec(ty) {
            return self.constant(b, ty, v);
        }
        let lb = type_bits(lane_type(ty), 8) as u64;
        let x = if lb == 64 {
            v
        } else {
            v & (1u64 << lb) - 1
        };
        let h = mix(O_WCONST as u64 | ty as u64 << 8, x);
        let f = switch self.made.get(&h) {
            Some(y) => *y,
            None => NONE,
        };
        if f != NONE && b.insts[f as usize].op == O_WCONST && b.insts[f as usize].ty == ty && splat_of(b, f) == Some(x) {
            return f;
        }
        let (w, nw) = splat_words(b, ty, x);
        return self.add_const(b, Inst { op: O_WCONST, ty: ty, aux: 0, a: w, b: nw, c: VNONE }, h);
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

    // Call `i` of `b`, each by-value aggregate argument that a copy of as many bytes wrote with no write since
    // (neither memory state changed) passing that copy's source in its place, when the source still holds
    // the bytes (the copy did not overlap it: no move, or a private destination that the source does not
    // point into) and the callee sees them as its copy: one of at most `Package.arg_copy` bytes, which the
    // backend copies; a larger one when the callee neither writes nor keeps its parameter nor compares its
    // address (`Sym.wargs`, `Sym.esc`) and nothing writes the source during the call (`kept_source`). The
    // copy may then go. The call.
    fn copied_args(self: &mut Self, pk: &Package, b: &mut Body, i: u32) Inst {
        let t = b.insts[i as usize];
        let np = b.pool[t.b as usize].min(t.aux);
        for k in 0..np {
            let pt = b.pool[(t.b + 3 + k) as usize];
            let v = b.pool[(t.c + k) as usize];
            if (pt & AGG) == 0 {
                continue;
            }
            let big = b.pool[(pt & ~AGG) as usize] > pk.arg_copy;
            if big && (t.op != O_CALL || k >= 64 || ((pk.syms[b.syms[t.a as usize] as usize].wargs | pk.syms[b.syms[t.a as usize] as usize].esc) >> k as u64 & 1) != 0) {
                continue;
            }
            let m = self.recall(v, self.pprior, T_NONE, self.tprior);
            if m == VNONE || (m & (VPARAM | VFLAG)) != 0 || b.insts[m as usize].op != O_MEMCPY {
                continue;
            }
            let c = b.insts[m as usize];
            let n = const_of(b, c.c);
            let ca = self.base(b, c.a);
            let cb = self.base(b, c.b);
            // A slot whose address leaks nowhere holds no bytes of a source not derived from it.
            let s = if (c.a & (VPARAM | VFLAG)) == 0 && c.a as usize < self.pder.len() {
                self.pder[c.a as usize]
            } else {
                NONE
            };
            let foreign = s != NONE && !self.pleak[s as usize] && ((c.b & (VPARAM | VFLAG)) != 0 || c.b as usize < self.pder.len() && self.pder[c.b as usize] != s);
            // A caller's memory that nothing writes holds no byte of this frame.
            let kept = big && self.kept_source(b, i, t, k, c.b);
            let apart = (c.aux & MEM_OVERLAP) == 0 || ca != NONE && cb != NONE && ca != cb || foreign || kept;
            if c.a != v || c.b == v || (c.aux & MEM_VOLATILE) != 0 || n.is_none() || n.unwrap() != b.pool[(pt & ~AGG) as usize] as u64 || !apart || big && !kept {
                continue;
            }
            b.pool[(t.c + k) as usize] = c.b;
        }
        return t;
    }

    // Copy `t`, instruction `i` of block `k`, of a call's whole aggregate result from the slot that call
    // writes it to, right after the call (pure instructions and whole copies between slots that pass the
    // result on between), into an exclusive parameter's referent: the call writes its result there in place
    // of those slots, which nothing else uses, and the copies go. The callee keeps no copy of its result's
    // address (`Sym.esc`) and no other argument reaches that referent, so it neither reads those bytes nor
    // sees them change but through its result; a panic in it ends the program, so no code reads the bytes
    // it left half written. Whether it did.
    fn result_into(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32, t: Inst) bool {
        let n = const_of(b, t.c);
        let c = self.acc(i, t.a);
        if c < CL_NOALIAS || c >= CL_FROZEN || (class_bit(c) & self.sbits) != 0 {
            return false;
        }
        // Back to the call, through at most RESULT_HOPS copies (`hops`): each step goes back one
        // instruction of the block.
        let mut hops = Vector::<u32>::new();
        let mut src = t.b;
        let bk = b.blocks[k as usize];
        let mut j = i;
        while j > bk.start {
            if (src & (VPARAM | VFLAG)) != 0 || b.insts[src as usize].op != O_SLOTADDR {
                return false;
            }
            j -= 1;
            let w = b.insts[j as usize];
            if self.moved[j as usize] || self.blk_of[j as usize] != k {
                return false;
            }
            if self.repl[j as usize] != VNONE || pure_op(w.op) {
                continue;
            }
            if w.op != O_MEMCPY || w.a != src || w.b == src || (w.aux & MEM_VOLATILE) != 0 || const_of(b, w.c) != n || hops.len() as u32 == RESULT_HOPS {
                break;
            }
            hops.push(j);
            src = w.b;
        }
        let u = b.insts[j as usize];
        if j == i || u.op != O_CALL || self.repl[j as usize] != VNONE {
            return false;
        }
        let np = b.pool[u.b as usize];
        let rt = b.pool[u.b as usize + 2];
        if (rt & AGG) == 0 || u.aux != np + 1 || b.pool[(u.c + np) as usize] != src || np >= 64 || n != Option::<u64>::Some(
            b.pool[(rt & ~AGG) as usize],
        ) || (pk.syms[b.syms[u.a as usize] as usize].esc >> np as u64 & 1) != 0 {
            return false;
        }
        for q in 0..np {
            let v = b.pool[(u.c + q) as usize];
            let d = self.acc(j, v);
            if v == src || b.type_of(v) == T_PTR && (d == c || d == CL_MANY) {
                return false;
            }
        }
        // No other instruction takes those slots' addresses.
        for x in 0..b.insts.len() as u32 {
            let mut chain = x == i || x == j;
            for h in 0..hops.len() {
                chain = chain || hops[h] == x;
            }
            if self.repl[x as usize] != VNONE || chain {
                continue;
            }
            let w = b.insts[x as usize];
            if w.op == O_SLOTADDR && result_slot(b, t, &hops, w.a) && x != t.b && !result_addr(b, t, &hops, x) {
                return false;
            }
            lv::uses(b, w, &mut self.uses);
            b.succ_edges(w, &mut self.edges);
            for e in 0..self.edges.len() {
                for a in 0..b.edge_nargs(self.edges[e]) {
                    self.uses.push(b.edge_arg(self.edges[e], a));
                }
            }
            for q in 0..self.uses.len() {
                if result_addr(b, t, &hops, self.uses[q]) {
                    return false;
                }
            }
        }
        b.pool[(u.c + np) as usize] = t.a;
        self.repl[i as usize] = DROPPED;
        for h in 0..hops.len() {
            self.repl[hops[h] as usize] = DROPPED;
        }
        // The call now writes the stores' memory `overwrite` keeps across it.
        self.pend.truncate(0);
        return true;
    }

    // Whether no write touches the memory at address `a` while call `t` (instruction `i` of `b`) runs, when
    // `a` passes as its argument `k`, which the callee does not write: a read-only parameter's referent
    // (`REF_READONLY`, through constant offsets), or an exclusive parameter's that no other argument
    // reaches.
    fn kept_source(self: &Self, b: &Body, i: u32, t: Inst, k: u32, a: Value) bool {
        let mut x = a;
        // Each step goes back one offset.
        for _ in 0..FRAME_DEPTH {
            if (x & (VPARAM | VFLAG)) != 0 || b.insts[x as usize].op != O_PTRADD || b.insts[x as usize].b != VNONE {
                break;
            }
            x = b.insts[x as usize].a;
        }
        let q = entry_param(b, x);
        if q != NONE && q as usize < b.refs.len() && (b.refs[q as usize] & (REF_READONLY | REF_INNER)) == REF_READONLY {
            return true;
        }
        let c = self.class(a);
        if c < CL_NOALIAS || c >= CL_FROZEN || (class_bit(c) & self.sbits) != 0 {
            return false;
        }
        for q in 0..t.aux as u32 {
            let d = self.acc(i, b.pool[(t.c + q) as usize]);
            if q != k && b.type_of(b.pool[(t.c + q) as usize]) == T_PTR && (d == c || d == CL_MANY) {
                return false;
            }
        }
        return true;
    }

    // Value-number pure instruction `i` of block `k`: an equal one of a dominating block replaces it, else
    // it enters the scope and moves out of the loops it does not vary in. Whether it went or moved.
    fn number(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        let h = value_hash(b, t);
        let found = switch self.pure.get(&h) {
            Some(v) => *v,
            None => NONE,
        };
        if found != NONE && same_value(b, as_plain(b.insts[found as usize]), t) {
            // A reference's address (`PTR_NONNULL`) that stands for another address too says nothing more:
            // its fact holds where a reference is made.
            if t.op == O_PTRADD && (t.aux & PTR_NONNULL) == 0 {
                b.insts.index_mut(found as usize).aux &= PTR_SCALE;
            }
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
        let fm = pk.fmath | b.fmath;
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
                // Only an operation of two values has a value second operand (a call's is its signature).
                let c1 = if x.op == op && x.ty == t.ty {
                    float_const(b, x.b)
                } else {
                    Option::<u64>::None
                };
                if c1.is_some() {
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
    // address, a copy's source, a copy's or a fill's destination, the slice a vector access reads
    // (`header_read`) or an argument a call only reads (`lends`). Every other use lets unknown code write it. The reached blocks in reverse postorder:
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
                    ) || lends(pk, b, t, v) {
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
    // compared) escapes; one that is not a by-value aggregate argument the backend copies leaks (`pleak`).
    fn privates(self: &mut Self, pk: &Package, b: &Body) {
        let ni = b.insts.len();
        fill(&mut self.pder, ni, NONE);
        fill(&mut self.pesc, b.slots.len(), false);
        fill(&mut self.pleak, b.slots.len(), false);
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
                    if !arg_copied(pk, b, t, v) {
                        self.pleak[self.pder[v as usize] as usize] = true;
                    }
                }
            }
        }
    }

    // The object address `a` of `b` points into (`lu::Classes.obj`): a slot (`privates`), private or not,
    // a data symbol the package defines (not a C library's, which another name may alias), or the block an
    // allocation returns (`ALLOC_FRESH`), through at most FRAME_DEPTH steps of address arithmetic; NONE for
    // any other.
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
            if call_alloc(pk, b, t) == ALLOC_FRESH && t.ty == T_PTR && v < lu::OBJ_FRESH {
                return v | lu::OBJ_FRESH;
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
    // a scope's class aside), nor a store bytes of its own address apart from its own, nor a call bytes
    // its arguments reach none of (`call_apart`). A place moves only along the states a load of it reads:
    // the untagged accesses' and its type's tag's; another tag's state may be its number by chance and then
    // miss the writes of the place's own tag.
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
            let apart = !other_class && !other_bytes && t.op == O_CALL && self.call_apart(
                pk,
                b,
                i,
                t,
                p.addr,
                lo,
                lo + type_bytes(p.ty, pk.ptr_bytes) as i64,
            );
            if (other_class || other_bytes || apart) && self.recall(p.addr, p.off, p.ty, to) == VNONE {
                self.remember(p.addr, p.off, p.ty, p.val, to);
            }
        }
    }

    // Load `t`, instruction `i` of block `k`, that cannot fault: moved past the next call of its block when
    // that call does not write its bytes (`call_apart`) and nothing before the call reads it, loads or
    // writes memory: its value then need not live across the call. Whether it moved.
    fn sink_load(self: &mut Self, pk: &Package, b: &Body, k: u32, i: u32, t: Inst) bool {
        let bk = b.blocks[k as usize];
        let lo = (t.c as i32) as i64;
        let hi = lo + type_bytes(t.ty, pk.ptr_bytes) as i64;
        // Each step reads one later instruction of the block.
        for j in i + 1..bk.start + bk.len - 1 {
            let u = b.insts[j as usize];
            if self.moved[j as usize] || self.repl[j as usize] != VNONE {
                return false;
            }
            lv::uses(b, u, &mut self.uses);
            for q in 0..self.uses.len() {
                if self.uses[q] == i {
                    return false;
                }
            }
            if u.op == O_CALL {
                if !self.call_apart(pk, b, j, u, t.a, lo, hi) {
                    return false;
                }
                self.moved[i as usize] = true;
                if j + 1 == bk.start + bk.len - 1 {
                    self.hoisted.push(k as u64 << 32 | i as u64);
                } else {
                    self.pre.push((j + 1) as u64 << 32 | i as u64);
                }
                return true;
            }
            if u.op == O_LOAD || writes_memory(u) {
                return false;
            }
        }
        return false;
    }

    // Whether call `t`, instruction `i` of `b`, reads and writes none of the bytes `[lo, hi)` past address
    // `a`, of an exclusive class (a parameter's, an inlined call's or an allocation's) but a scope's: the
    // call reaches that class only through its arguments of it (`arg_bits`), each `a`'s base at a constant
    // offset, through which the callee reaches only bytes apart from those (`Sym.span`).
    fn call_apart(self: &Self, pk: &Package, b: &Body, i: u32, t: Inst, a: Value, lo: i64, hi: i64) bool {
        let c = self.class(a);
        if c < CL_NOALIAS || c >= CL_FROZEN || (class_bit(c) & self.sbits) != 0 {
            return false;
        }
        let sy = pk.syms[b.syms[t.a as usize] as usize];
        let (base, off) = address_of(b, a);
        for q in 0..t.aux as u32 {
            let v = b.pool[(t.c + q) as usize];
            if (class_bit(self.acc(i, v)) & class_bit(c)) == 0 {
                continue;
            }
            let (vb, vo) = address_of(b, v);
            let s = if sy.span != NONE && q as u64 < pk.spans[sy.span as usize] {
                pk.spans[(sy.span + 1 + q) as usize]
            } else {
                SPAN_ANY
            };
            if s == SPAN_NONE {
                continue;
            }
            if vb != base || s == SPAN_ANY || span_lo(s) + vo < off + hi && off + lo < span_hi(s) + vo {
                return false;
            }
        }
        return true;
    }

    // Whether load `t` cannot fault wherever its address is defined: it reads inside a slot, a data
    // symbol of the package (a thread-local one's copy), an aggregate the caller passes by reference or a reference parameter's
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
                if (s.kind == SK_DATA || s.kind == SK_TLS) && s.def != NONE {
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
        // and keep the others in a register (a 64-bit integer on arm64, a float, a wide constant).
        let konst = t.op == O_ICONST || t.op == O_FCONST || t.op == O_WCONST;
        let tls = tls_addr(pk, b, t);
        if !load && !konst && !tls && !speculable(pk, b, t) {
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
            if h == NONE || self.preh[h as usize] == NONE || tls && self.moves_task(pk, b, h) || load && !kept && private && self.pwrite[h as usize] || load && !kept && !private && (self.writes[h as usize] & cls) != 0 && (tbaa(
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

    // Whether a block of loop `h` of `b` holds a call, assembly or a system operation that writes memory: a
    // task may resume on another thread after it.
    fn moves_task(self: &Self, pk: &Package, b: &Body, h: u32) bool {
        let r = self.lb_at[h as usize];
        for q in (r >> 32) as u32..r as u32 {
            let bk = b.blocks[self.lbs[q as usize] as usize];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                if (t.op == O_CALL || t.op == O_CALLIND || t.op == O_ASM || t.op == O_SYS) && writes(pk, b, t) {
                    return true;
                }
            }
        }
        return false;
    }

    // Header `h`'s exit test `q + c <u n`, before a body of other blocks, of a counter `q` that starts at a
    // constant and steps by a constant `d`, `c` a nonzero constant whose sum with the start does not wrap, `n`
    // from outside the loop, at most `max - d + 1` (any `n` for a step by 1; else a bound the branches in
    // scope set, `ubound`): `q <u n - min(n, c)`, the difference made in the preheader. Each sum the test
    // reads is below `n + d`, so none wraps and both tests agree; the header then only tests its counter, a
    // counted loop (LLVM's IndVarSimplify). Whether it did.
    fn offset_test(self: &mut Self, pk: &Package, b: &mut Body, h: u32) bool {
        let p = self.preh[h as usize];
        let th = term(b, h);
        if p == NONE || th.op != O_BR || (th.a & (VPARAM | VFLAG)) != 0 || th.a == VNONE || b.edge_target(th.b) == h || b.edge_target(
            th.c,
        ) == h {
            return false;
        }
        let c = b.insts[th.a as usize];
        if c.op != O_ICMP || c.aux != C_ULT || (c.a & (VPARAM | VFLAG)) != 0 || c.a == VNONE || !self.outside(c.b, h) {
            return false;
        }
        let s = b.insts[c.a as usize];
        let hb = b.blocks[h as usize];
        if s.op != O_ADD || !is_int(s.ty) || s.ty == T_I128 || (s.a & VPARAM) == 0 || s.a == VNONE || (s.a & ~VPARAM) < hb.param_start || (s.a & ~VPARAM) >= hb.param_start + hb.param_len as u32 {
            return false;
        }
        let off = const_of(b, s.b);
        let bits = type_bits(s.ty, 8);
        let top = if bits >= 64 {
            ~0u64
        } else {
            (1u64 << bits as u64) - 1
        };
        if off.is_none() || off.unwrap() == 0 || off.unwrap() > top {
            return false;
        }
        let kc = off.unwrap();
        let qi = (s.a & ~VPARAM) - hb.param_start;
        // The start from the preheader, one step `d` from each other edge into the header.
        let mut d: u64 = 0;
        for j in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
            let pb = self.preds[j as usize];
            b.succ_edges(term(b, pb), &mut self.edges);
            for e in 0..self.edges.len() {
                let ed = self.edges[e];
                if b.edge_target(ed) != h {
                    continue;
                }
                let x = self.val(b.edge_arg(ed, qi));
                if pb == p {
                    let st = const_of(b, x);
                    if st.is_none() || st.unwrap() > top - kc {
                        return false;
                    }
                    continue;
                }
                if (x & (VPARAM | VFLAG)) != 0 || x == VNONE {
                    return false;
                }
                let u = b.insts[x as usize];
                let k = if u.op != O_ADD || u.ty != s.ty {
                    0u64
                } else if u.a == s.a {
                    const_of(b, u.b).unwrap_or(0) & top
                } else if u.b == s.a {
                    const_of(b, u.a).unwrap_or(0) & top
                } else {
                    0u64
                };
                if k == 0 || d != 0 && k != d {
                    return false;
                }
                d = k;
            }
        }
        let n = self.val(c.b);
        if d != 1 && (d == 0 || self.ubound(pk, b, n, UB_DEPTH).unwrap_or(top) > top - d + 1) {
            return false;
        }
        let at = b.blocks[p as usize].start + b.blocks[p as usize].len - 1;
        let kv = self.constant(b, s.ty, kc);
        let zv = self.constant(b, s.ty, 0);
        let ge = self.placed(b, p, at, Inst { op: O_ICMP, ty: T_I8, aux: C_UGE, a: n, b: kv, c: VNONE }, false);
        let dv = self.placed(b, p, at, Inst { op: O_SUB, ty: s.ty, aux: 0, a: n, b: kv, c: VNONE }, false);
        let n2 = self.placed(b, p, at, Inst { op: O_SELECT, ty: s.ty, aux: 0, a: ge, b: dv, c: zv }, false);
        b.insts[th.a as usize] = Inst { op: O_ICMP, ty: c.ty, aux: C_ULT, a: s.a, b: n2, c: VNONE };
        return true;
    }

    // Call `i` of block `k`, of a function that writes no memory, to the preheader of the loop `k` heads,
    // when its arguments come from outside the loop, the loop writes no memory but private slots' (which
    // no call reaches) and nothing before the call in `k` writes memory: every entry into the loop runs
    // the call first, with the arguments and the memory every iteration has, so the preheader runs it
    // once in place of each iteration. From any block of the innermost loop when the function comes back
    // (no `FX_STALL`): it may run where that block would not. Whether it moved.
    fn hoist_call(self: &mut Self, pk: &Package, b: &Body, k: u32, i: u32) bool {
        let h = self.inner[k as usize];
        let t = b.insts[i as usize];
        let back = (pk.syms[b.syms[t.a as usize] as usize].fx & FX_STALL) == 0;
        if h == NONE || h != k && !back || self.preh[h as usize] == NONE || self.writes[h as usize] != 0 || self.tags[h as usize] != 0 {
            return false;
        }
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
        // The walk's removable calls (`nofx`) hold for this rebuild alone: another runs on renumbered
        // instructions.
        let nofx = replace(&mut self.nofx, Vector::<bool>::new());
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
                if self.repl[i as usize] == VNONE && !droppable(t) && !self.dead_store(b, t) && !(t.op == O_CALL && i as usize < nofx.len() && nofx[i as usize]) {
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
    bodies: UnsafeCell<Vector<Body>>,
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
    ok: UnsafeCell<Vector<bool>>,
    // Per body whose loop transforms or packing made vectors, its final form: `bodies` holds the form
    // before them, which callers inline (`job`), until `finish` swaps the two (`inlined`).
    finals: UnsafeCell<Vector<Option<Body>>>,
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
        specialize(pk);
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
        let mut sp = Vector::<u64>::new();
        let mut sp_at = Vector::<u32>::new();
        let fx = effects(pk, &bodies, &cs, &mut wargs, &mut esc, &mut sp, &mut sp_at);
        // Per body, its count, then its parameters' ranges.
        pk.spans.truncate(0);
        for s in 0..pk.syms.len() {
            let d = pk.syms[s].def;
            pk.syms.index_mut(s).span = NONE;
            if pk.syms[s].kind == SK_FUNC && d != NONE {
                pk.syms.index_mut(s).fx = fx[d as usize];
                pk.syms.index_mut(s).esc = esc[d as usize];
                pk.syms.index_mut(s).wargs = wargs[d as usize];
                pk.syms.index_mut(s).span = pk.spans.len() as u32;
                pk.spans.push(sp_at[d as usize + 1] - sp_at[d as usize]);
                pk.spans.extend_from_slice(sp[sp_at[d as usize] as usize..sp_at[d as usize + 1] as usize]);
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
            bodies: UnsafeCell::<Vector<Body>>::new(bodies),
            finals: UnsafeCell::<Vector<Option<Body>>>::new(finals),
            held: held,
            call_at: call_at,
            calls: calls,
            wargs: wargs,
            shape: shape,
            unit: unit,
            bunit: bunit,
            level: level,
            ok: UnsafeCell::<Vector<bool>>::new(ok),
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
        // The jobs at one level write their own bodies, results and flags at once: through the cells.
        let base = unsafe (*r.bodies.get()).as_mut_ptr();
        let mut sc = r.take();
        let b = unsafe &mut *(base + j as usize);
        sc.o.forget();
        sc.o.pslots = true;
        sc.o.unit = r.bunit[j as usize];
        // Scalar quotients by a constant stay for the loop vectorizer until the loop transforms ran.
        sc.o.defer_div = r.cf.loops.vector != 0 && p.vector != 0 && p.vec_mulh != 0;
        sc.o.deferred = false;
        // The inliner reads the rare blocks, the loop transforms and the code generators too: marked before
        // the inlining (a copy takes its call's marks) and once the transforms made their blocks.
        sc.o.estimate(p, b);
        let inlined = sc.il.run(p, base, r.ok.get_ref(), &r.level, &r.unit, j, r.cf.inline, b);
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
        // The places loops keep in registers, before the loop transforms: a final value then takes a sum
        // that went through memory.
        if sc.o.promote_places(p, b) {
            let _ = sc.o.run(p, b, true);
        }
        // A body callers may inline keeps its form before the loop transforms and the packing: when those
        // make vectors or rotate its loops (a rotated loop is no counted one a caller's vectorizer reads),
        // callers inline that form, as LLVM vectorizes after inlining. A caller packs its
        // copy once the copy's slots are values (`lir::promote`), which a vector access of a slot prevents.
        // The copy, only of a body small enough to inline: a larger one that ends with vectors inlines in
        // neither form (`fits`).
        let bu = r.cf.loops;
        if bu.vector != 0 && sc.o.unnest(p, b) {
            let _ = sc.o.run(p, b, true);
        }
        if bu.vector != 0 && sc.o.merge_heads(p, b) {
            let _ = sc.o.run(p, b, true);
        }
        if bu.vector != 0 && sc.o.sink_heads(p, b) {
            let _ = sc.o.run(p, b, true);
        }
        let snap = r.inline && r.shape[j as usize] && bu.vector != 0 && !packed(b);
        let pre = if snap && il::bounded(b, r.cf.inline) {
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
        sc.o.defer_div = false;
        if sc.o.deferred {
            sc.o.deferred = false;
            let _ = sc.o.run(p, b, true);
        }
        // Then rotation, which moves the exit tests the transforms above read; the loads each iteration
        // starts with leave the rotated loops, so their sums have final values too.
        let rotated = bu.rotate != 0 && sc.o.rotate(p, b, bu.rotate);
        if rotated && bu.fin != 0 {
            let _ = sc.o.loop_opts(
                p,
                b,
                lu::Budgets {
                    peel: 0,
                    partial: 0,
                    version: 0,
                    unswitch: 0,
                    rotate: 0,
                    vector: 0,
                    interleave: 0,
                    fin: bu.fin,
                },
            );
        }
        // The final values compute in 128 bits (`lir::loops`): in words too.
        if sc.o.split_pairs(p, b) {
            let _ = sc.o.run(p, b, true);
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
        // Where the backend computes them in registers: arm64 every vector; x86-64 up to 32 bytes (one
        // `pmax` where it has one, else a `pcmpgt` mask, as the select).
        let minmax = p.vector != 0 && p.vops != 0 && vec_minmaxes(
            b,
            if p.vops == VOPS_ALL {
                p.vector
            } else {
                p.vector.min(32)
            },
        );
        if sc.o.dead_allocs(p, b) || placed || minmax {
            let _ = sc.o.run(p, b, true);
        }
        // The loops' counted addresses as pointers their accesses step, on the loops' final shape.
        if p.postinc {
            let _ = sc.o.pointer_ivs(p, b);
        }
        if p.sum_trees {
            sc.o.reassociate(b);
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
        if snap && (packed(b) || rotated) {
            if pre.is_some() {
                let fin = replace(b, pre.unwrap());
                b.compact_pool(&mut sc.o.cps);
                unsafe *((*r.finals.get()).as_mut_ptr() + j as usize) = Some(fin);
            } else if packed(b) {
                fits = false;
            }
        }
        unsafe *((*r.ok.get()).as_mut_ptr() + j as usize) = fits && il::bounded(b, r.cf.inline);
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
        let finals = self.finals.get_mut();
        let bodies = self.bodies.get_mut();
        for j in 0..finals.len() {
            let f = replace(finals.index_mut(j), Option::<Body>::None);
            if f.is_some() {
                let pre = replace(bodies.index_mut(j), f.unwrap());
                finals.set(j, Some(pre));
            }
        }
        pk.bodies = replace(bodies, Vector::<Body>::new());
        const_slots(pk);
        symbol_tables(pk);
        // The calls through a method a constant table holds (`fold_ptr`): the jobs, which ran at once, did
        // not read another body's signature.
        direct_calls(pk);
    }

    /// After `finish`, the form of body `k` its callers inlined: the one before the loop transforms and
    /// the packing when those made vectors or rotated its loops, else `pk`'s.
    pub(package) fn inlined<'a>(self: &'a Self, pk: &'a Package, k: u32) &'a Body {
        if let Some(b) = self.finals.get_ref().at(k as usize) {
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
        return self.ok.get_ref()[k as usize];
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

// Each switch of the optimized bodies that selects symbol addresses (`sws::symbol_table`) reads them from
// a read-only table of its own (LLVM's switch to lookup table): a load in place of a branch per case. A
// body that took one is optimized again, which removes the cases' blocks.
fn symbol_tables(pk: &mut Package) {
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
    let ptr = pk.ptr_bytes;
    let mut st = sws::SymTable::new();
    let mut o = Opt::new();
    for j in 0..held {
        if owner[j] == NONE {
            continue;
        }
        let mut took = false;
        let nb = pk.bodies[j].blocks.len();
        for k in 0..nb {
            let b = &pk.bodies[j];
            let bk = b.blocks[k];
            if bk.len == 0 {
                continue;
            }
            let t = b.insts[(bk.start + bk.len - 1) as usize];
            if t.op != O_SWITCH || !is_int(b.type_of(t.a)) || b.type_of(t.a) == T_I128 || !sws::symbol_table(
                b,
                t,
                type_bits(b.type_of(t.a), ptr),
                &mut st,
            ) {
                continue;
            }
            let o = pk.syms[owner[j] as usize];
            let name = format("{}.tab{}", pk.spell(o.name), k);
            let d = pk.add_symbol(&name, SK_DATA, SL_LOCAL);
            if d == NONE {
                continue;
            }
            pk.syms.index_mut(d as usize).unit = o.unit;
            pk.syms.index_mut(d as usize).own = o.own;
            let mut rs = Vector::<Reloc>::with_capacity(st.syms.len());
            for x in 0..st.syms.len() {
                rs.push(Reloc { offset: x as u32 * ptr, sym: st.syms[x], addend: st.adds[x] });
            }
            let none: []u8 = [];
            if !pk.add_data(d, st.span * ptr, ptr.trailing_zeros() as u8, true, none, rs[0..rs.len()]) {
                continue;
            }
            sws::use_symbol_table(pk.bodies.index_mut(j), k as u32, &st, d, ptr);
            took = true;
        }
        if took {
            let mut b = replace(pk.bodies.index_mut(j), Body::new());
            o.forget();
            o.unit = pk.syms[owner[j] as usize].unit;
            let _ = o.run(pk, &mut b, true);
            let _ = ret_edges(&mut b);
            o.estimate(pk, &mut b);
            pk.bodies[j] = b;
        }
    }
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
// nothing (but `FX_STALL`): no code of the caller runs after it. A body that may not come back (`FX_STALL`):
// one that may end the program, loops, calls a function that may not come back, or is on a cycle of calls (a
// least fixed point: a body comes back when each body it calls does). A held body (`Package.held`) keeps the flags and the
// parameters its unit's build found: the others then take the values a build without held bodies gives
// them. Into `wargs`, per body, the parameters whose memory it may write (`FX_ARG`), a bit each; into
// `esc`, those whose pointer it may let escape (`Sym.esc`): its own uses' (`own_escapes`), every argument
// past its parameters (a variadic one, which its accesses do not show), and a pass to a body's parameter
// that escapes; into `sp`, the byte ranges of its parameters (`Sym.span`'s entries,
// `sp[sp_at[k]..sp_at[k + 1]]`, `spans`). The calls and their arguments' roots are `cs`'s.
fn effects(
    p: &Package,
    bodies: &Vector<Body>,
    cs: &Calls,
    wargs: &mut Vector<u64>,
    esc: &mut Vector<u64>,
    sp: &mut Vector<u64>,
    sp_at: &mut Vector<u32>,
) Vector<u8> {
    let n = bodies.len();
    let held = if p.held.body == NONE {
        n
    } else {
        p.held.body as usize
    };
    let mut fx = Vector::<u8>::with_capacity(n);
    wargs.truncate(0);
    esc.truncate(0);
    sp.truncate(0);
    sp_at.truncate(0);
    // Per body below `held`, its parameters' passes to a body and their offsets (`own_escapes`):
    // `pass[at[k]..at[k + 1]]`.
    let mut pass = Vector::<u64>::new();
    let mut poff = Vector::<i64>::new();
    let mut at = Vector::<u32>::with_capacity(held + 1);
    for k in 0..n {
        sp_at.push(sp.len() as u32);
        if k >= held {
            fx.push(p.held.fx[k - held]);
            wargs.push(p.held.wargs[k - held]);
            esc.push(p.held.esc[k - held]);
            let hd = &p.held;
            sp.extend_from_slice(hd.spans[hd.span_at[k - held] as usize..hd.span_at[k - held + 1] as usize]);
            continue;
        }
        let mut w: u64 = 0;
        fx.push(own_effects(p, &bodies[k], &mut w));
        wargs.push(w);
        at.push(pass.len() as u32);
        let np = (bodies[k].blocks[0].param_len as u64).min(64);
        esc.push(
            own_escapes(p, &bodies[k], &mut pass, &mut poff, sp) | if np < 64 {
                ~0u64 << np
            } else {
                0u64
            },
        );
    }
    sp_at.push(sp.len() as u32);
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
            stalls(&mut fx, cs, held);
            spans(sp, sp_at, esc, &pass, &poff, &at, held);
            return fx;
        }
    }
    assert(false, "opt: the effect inference does not settle");
    return fx;
}

// The byte ranges of the parameters of the bodies below `held` (`effects`), from their own accesses in
// `sp`: any byte through one that escapes (`esc`); with each pass to a body's parameter (`pass`, `poff`,
// `at`) that parameter's bytes moved by the pass's offset. The least fixed point: a worklist of the
// bodies whose ranges grew, each pass into such a body evaluated again; a range only grows, to SPAN_ANY
// past SPAN_MAX, so the result does not depend on the order.
fn spans(
    sp: &mut Vector<u64>,
    sp_at: &Vector<u32>,
    esc: &Vector<u64>,
    pass: &Vector<u64>,
    poff: &Vector<i64>,
    at: &Vector<u32>,
    held: usize,
) {
    let n = sp_at.len() - 1;
    for k in 0..held {
        for x in sp_at[k]..sp_at[k + 1] {
            if (esc[k] >> (x - sp_at[k]) as u64 & 1) != 0 {
                sp[x as usize] = SPAN_ANY;
            }
        }
    }
    // The passes by callee (`into[into_at[c]..into_at[c + 1]]`) and per pass its caller.
    let np = pass.len();
    let mut from = Vector::<u32>::with_capacity(np);
    for k in 0..held {
        for _ in at[k]..at[k + 1] {
            from.push(k as u32);
        }
    }
    let mut into_at = Vector::<u32>::new();
    into_at.resize_default(n + 1);
    for x in 0..np {
        into_at[(pass[x] >> 32) as usize + 1] += 1;
    }
    for c in 0..n {
        into_at[c + 1] += into_at[c];
    }
    let mut into = Vector::<u32>::new();
    into.resize_default(np);
    let mut fill_at = Vector::<u32>::new();
    fill_at.extend_copy(&into_at);
    for x in 0..np {
        let c = (pass[x] >> 32) as usize;
        into[fill_at[c] as usize] = x as u32;
        fill_at[c] += 1;
    }
    let mut queued = Vector::<bool>::new();
    queued.resize_default(n);
    let mut work = Vector::<u32>::with_capacity(n);
    for c in 0..n {
        queued[c] = true;
        work.push(c as u32);
    }
    // Each entry grows at most 4 * SPAN_MAX + 2 times, and each growth queues at most one body.
    let bound = n + (sp.len() + 1) * (4 * SPAN_MAX as usize + 2);
    for _ in 0..bound {
        if work.len() == 0 {
            return;
        }
        let c = work.pop().unwrap() as usize;
        queued[c] = false;
        for y in into_at[c]..into_at[c + 1] {
            let x = into[y as usize] as usize;
            let k = from[x] as usize;
            let q = (pass[x] >> 8 & 0xFF) as u32;
            let r = sp_at[k] + (pass[x] & 0xFF) as u32;
            let s = if sp_at[c] + q < sp_at[c + 1] {
                sp[(sp_at[c] + q) as usize]
            } else {
                SPAN_ANY
            };
            let v = span_join(sp[r as usize], span_shift(s, poff[x]));
            if v != sp[r as usize] {
                sp[r as usize] = v;
                if !queued[k] {
                    queued[k] = true;
                    work.push(k as u32);
                }
            }
        }
    }
    assert(work.len() == 0, "opt: the parameter ranges do not settle");
}

// `FX_STALL` for each body below `held` that is on a cycle of calls or calls one (`effects`): the bodies
// that come back are those whose own code does and each of whose calls' bodies does, from none up.
fn stalls(fx: &mut Vector<u8>, cs: &Calls, held: usize) {
    let n = fx.len();
    let mut back = Vector::<bool>::with_capacity(n);
    for k in 0..n {
        back.push(k >= held && (fx[k] & FX_STALL) == 0);
    }
    // Each round adds a body or ends: at most `held` + 1 rounds.
    for _ in 0..held + 1 {
        let mut changed = false;
        for k in 0..held {
            if back[k] || (fx[k] & FX_STALL) != 0 {
                continue;
            }
            let mut all = true;
            for x in cs.at[k]..cs.at[k + 1] {
                all = all && (!cs.live[x as usize] || back[cs.callee[x as usize] as usize]);
            }
            if all {
                back[k] = true;
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    for k in 0..held {
        if !back[k] {
            fx[k] |= FX_STALL;
        }
    }
}

// The flags (`FX_*`) of body `b`'s own instructions (`effects`), and into `w` the parameters whose memory
// they may write: a call of a body counts for none here.
fn own_effects(p: &Package, b: &Body, w: &mut u64) u8 {
    let mut f: u8 = if has_cycle(b) {
        FX_STALL
    } else {
        0
    };
    for k in 0..b.blocks.len() {
        let bk = b.blocks[k];
        let end = b.insts[(bk.start + bk.len - 1) as usize].op;
        if end == O_PANIC || end == O_UNREACHABLE {
            f |= FX_STALL;
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
                // Another function's call, assembly or a system operation may not come back.
                if t.op == O_CALL || t.op == O_CALLIND || t.op == O_ASM || t.op == O_SYS {
                    f |= FX_STALL;
                }
            }
        }
    }
    return f;
}

// Whether a block of `b` reaches itself (a loop): a depth-first walk that meets a block on its path.
fn has_cycle(b: &Body) bool {
    let nb = b.blocks.len();
    // Per block: 0 unseen, 1 on the walk's path, 2 done.
    let mut state = Vector::<u8>::with_capacity(nb);
    for _ in 0..nb {
        state.push(0);
    }
    // The path: a block and its next edge to take, each block on it once.
    let mut path = Vector::<u64>::with_capacity(nb);
    let mut es = Vector::<u32>::new();
    state[0] = 1;
    path.push(0);
    // Each step takes an edge or leaves a block: at most the edges and blocks.
    while path.len() != 0 {
        let top = path[path.len() - 1];
        let k = (top & 0xFFFFFFFF) as u32;
        let e = (top >> 32) as u32;
        let bk = b.blocks[k as usize];
        b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut es);
        if e as usize >= es.len() {
            state[k as usize] = 2;
            let _ = path.pop();
            continue;
        }
        let at = path.len() - 1;
        path[at] = e as u64 + 1 << 32 | k as u64;
        let s = b.edge_target(es[e as usize]);
        if state[s as usize] == 1 {
            return true;
        }
        if state[s as usize] == 0 {
            state[s as usize] = 1;
            path.push(s);
        }
    }
    return false;
}

// The parameters (the first 64, a bit each) whose pointer body `b`'s own instructions may let escape
// (`effects`): a use of the parameter, or of address arithmetic on it, but as an access's address, the
// base of more arithmetic or a comparison's operand (not a by-value aggregate's, whose address compared
// tells its copy from the bytes `copied_args` passes in its place). A pass to a body's parameter goes into
// `pass` instead (`body << 32 | argument << 8 | parameter`), its offset from the parameter into `poff`
// (OFF_ANY: not constant): it escapes when that parameter does. Into `span`, per parameter of the first
// 64, the bytes its accesses touch (`Sym.span`'s entries). A block that ends the program counts for
// nothing.
fn own_escapes(p: &Package, b: &Body, pass: &mut Vector<u64>, poff: &mut Vector<i64>, span: &mut Vector<u64>) u64 {
    let ni = b.insts.len();
    // Per instruction, the parameter its value is address arithmetic on (NONE: none) and the constant
    // offset (`doff`, OFF_ANY: not constant or past SPAN_MAX). Each pass sets at least one more or ends: at
    // most `ni + 1`.
    let mut der = Vector::<u32>::with_capacity(ni);
    let mut doff = Vector::<i64>::with_capacity(ni);
    for _ in 0..ni {
        der.push(NONE);
        doff.push(OFF_ANY);
    }
    for _ in 0..ni + 1 {
        let mut changed = false;
        for i in 0..ni {
            let t = b.insts[i];
            if t.op == O_PTRADD && der[i] == NONE {
                let k = param_of(b, &der, t.a);
                if k != NONE {
                    der[i] = k;
                    let o = off_of(&doff, t.a);
                    let n = if t.b == VNONE {
                        Option::<u64>::Some(0)
                    } else {
                        const_of(b, t.b)
                    };
                    if o != OFF_ANY && n.is_some() {
                        // A 32-bit index is a 32-bit target's: its address arithmetic wraps at 32 bits.
                        let x = if t.b != VNONE && b.type_of(t.b) == T_I32 {
                            ((n.unwrap() as u32) as i32) as i64
                        } else {
                            n.unwrap() as i64
                        };
                        let d = o.wrapping_add(x.wrapping_mul(scale_of(t))).wrapping_add(t.c as i32);
                        if d >= -SPAN_MAX && d <= SPAN_MAX {
                            doff[i] = d;
                        }
                    }
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
    }
    let e = b.blocks[0];
    let np = (e.param_len as usize).min(64);
    let s0 = span.len();
    for _ in 0..np {
        span.push(SPAN_NONE);
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
                        poff.push(off_of(&doff, b.pool[(t.c + q) as usize]));
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
                let cmp = t.op == O_ICMP && x != NONE && !(b.sig != NONE && x < b.pool[b.sig as usize] && (b.pool[(b.sig + 3 + x) as usize] & AGG) != 0);
                let kept = t.op == O_LOAD && t.a == v && u == 0 || t.op == O_STORE && t.a == v && t.b != v || t.op == O_MEMCPY && (t.a == v || t.b == v) && t.c != v || t.op == O_MEMSET && t.a == v && t.b != v && t.c != v || t.op == O_PTRADD && t.a == v && t.b != v || cmp;
                if x != NONE && !kept {
                    out |= 1u64 << x as u64;
                }
                if x == NONE || !kept || t.op == O_PTRADD || t.op == O_ICMP {
                    continue;
                }
                // An access: its bytes from the parameter, any when the offset or a copy's count is not
                // constant.
                let o = off_of(&doff, v);
                let (lo, n) = if t.op == O_LOAD {
                    ((t.c as i32) as i64, type_bytes(t.ty, p.ptr_bytes) as i64)
                } else if t.op == O_STORE {
                    ((t.c as i32) as i64, type_bytes(b.type_of(t.b), p.ptr_bytes) as i64)
                } else {
                    let c = const_of(b, t.c);
                    (
                        0i64,
                        if c.is_some() && c.unwrap() <= SPAN_MAX as u64 {
                            c.unwrap() as i64
                        } else {
                            OFF_ANY
                        }
                    )
                };
                span[s0 + x as usize] = span_join(
                    span[s0 + x as usize],
                    if o == OFF_ANY || n == OFF_ANY {
                        SPAN_ANY
                    } else {
                        span_of(o + lo, o + lo + n)
                    },
                );
            }
        }
    }
    return out;
}

// The constant offset (`own_escapes`' `doff`) of address value `v` from the parameter it is address
// arithmetic on: 0 for the parameter itself.
const fn off_of(doff: &Vector<i64>, v: Value) i64 {
    return if (v & (VPARAM | VFLAG)) != 0 {
        0i64
    } else {
        doff[v as usize]
    };
}

// The `Sym.span` entry of the bytes `[lo, hi)`: SPAN_ANY past SPAN_MAX.
const fn span_of(lo: i64, hi: i64) u64 {
    if lo >= hi {
        return SPAN_NONE;
    }
    if lo < -SPAN_MAX || hi > SPAN_MAX {
        return SPAN_ANY;
    }
    return ((lo as i32) as u32) as u64 << 32 | ((hi as i32) as u32) as u64;
}

// The bytes of `Sym.span` entry `s` (not SPAN_NONE or SPAN_ANY).
const fn span_lo(s: u64) i64 {
    return ((s >> 32) as u32) as i32;
}

const fn span_hi(s: u64) i64 {
    return (s as u32) as i32;
}

// The `Sym.span` entry of the bytes either of `a` and `c` holds.
const fn span_join(a: u64, c: u64) u64 {
    if a == SPAN_ANY || c == SPAN_ANY {
        return SPAN_ANY;
    }
    if a == SPAN_NONE || c == SPAN_NONE {
        return a | c;
    }
    return span_of(span_lo(a).min(span_lo(c)), span_hi(a).max(span_hi(c)));
}

// `Sym.span` entry `s` moved `off` bytes (OFF_ANY: not constant).
const fn span_shift(s: u64, off: i64) u64 {
    if s == SPAN_NONE || s == SPAN_ANY {
        return s;
    }
    return if off == OFF_ANY {
        SPAN_ANY
    } else {
        span_of(span_lo(s) + off, span_hi(s) + off)
    };
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
// else (past FRAME_DEPTH steps with every parameter in `w`).
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
        if steps > FRAME_DEPTH {
            // The rest may hold any parameter.
            *w = ~0u64;
            return ROOT_ANY;
        }
        if (x & VFLAG) != 0 || x == VNONE {
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

// `umax_of` looks through at most UMAX_DEPTH instructions.
const UMAX_DEPTH: u32 = 4;

// Whether unsigned compare `t` of `b` (pointers `ptr` bytes) of an integer and a constant holds whatever the
// integer is, from the largest value it can hold (`umax_of`); None when that does not settle it.
const fn umax_cmp(b: &Body, t: Inst, ptr: u32) Option<bool> {
    let ty = b.type_of(t.a);
    let ka = const_of(b, t.a);
    let kb = const_of(b, t.b);
    if !is_int(ty) || ty == T_I128 || ka.is_some() == kb.is_some() {
        return None;
    }
    let all = ones_below(type_bits(ty, ptr));
    // `x op c`, or `c op x` read as `x op' c` with the operands swapped (`<` becomes `>`).
    let (c, m, op) = if kb.is_some() {
        (kb.unwrap() & all, umax_of(b, t.a, ptr, UMAX_DEPTH), t.aux)
    } else {
        (
            ka.unwrap() & all,
            umax_of(b, t.b, ptr, UMAX_DEPTH),
            if t.aux < C_UGT {
                t.aux + 2
            } else {
                t.aux - 2
            }
        )
    };
    if op == C_ULT && m < c || op == C_ULE && m <= c {
        return Some(true);
    }
    if op == C_UGT && m <= c || op == C_UGE && m < c {
        return Some(false);
    }
    return None;
}

// The `n` low bits set (`n` at most 64).
const fn ones_below(n: u32) u64 {
    return if n >= 64 {
        0xFFFFFFFFFFFFFFFF
    } else {
        (1u64 << n) - 1
    };
}

// The largest unsigned value integer `v` of `b` (pointers `ptr` bytes) can hold, from its form up to `depth`
// instructions deep: a constant, a mask, a zero extension, a bit count, a quotient or a remainder, a right
// shift; else its type's largest.
const fn umax_of(b: &Body, v: Value, ptr: u32, depth: u32) u64 {
    let all = ones_below(type_bits(b.type_of(v), ptr));
    let k = const_of(b, v);
    if k.is_some() {
        return k.unwrap() & all;
    }
    if (v & (VPARAM | VFLAG)) != 0 || depth == 0 {
        return all;
    }
    let t = b.insts[v as usize];
    if t.op == O_AND {
        let x = umax_of(b, t.a, ptr, depth - 1);
        let y = umax_of(b, t.b, ptr, depth - 1);
        return if x < y {
            x
        } else {
            y
        };
    }
    if t.op == O_ZEXT {
        return umax_of(b, t.a, ptr, depth - 1);
    }
    if t.op == O_CLZ || t.op == O_CTZ || t.op == O_POPCNT {
        return type_bits(b.type_of(t.a), ptr);
    }
    if t.op == O_UDIV || t.op == O_LSHR {
        let x = umax_of(b, t.a, ptr, depth - 1);
        let s = const_of(b, t.b);
        if s.is_none() {
            return x;
        }
        let d = s.unwrap() & all;
        return if t.op == O_UDIV && d != 0 {
            x / d
        } else if t.op == O_LSHR && d < 64 {
            x >> d
        } else {
            x
        };
    }
    if t.op == O_UREM {
        // Below the divisor, which is not 0 when the remainder is computed.
        let x = umax_of(b, t.a, ptr, depth - 1);
        let y = umax_of(b, t.b, ptr, depth - 1);
        return if y != 0 && y - 1 < x {
            y - 1
        } else {
            x
        };
    }
    return all;
}

// The integer constant value `v` is (up to 64 bits, truncated to its type), if it is one.
const fn const_of(b: &Body, v: Value) Option<u64> {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_ICONST || b.insts[v as usize].ty == T_I128 {
        return None;
    }
    let t = b.insts[v as usize];
    return Some(t.b as u64 << 32 | t.a as u64);
}

// Store or fill `j` of `b` (pointers `ptr` bytes) into the result at address `pv` (`Opt::ret_chunks`): the
// offset, the bytes and the value of a store of a scalar of up to 8 bytes (no pointer, no vector), or of a
// fill of 1 to 8 bytes with a constant byte at a constant offset, its value VNONE and its bytes' integer
// fourth; the offset NONE when `j` is neither, or is volatile or past 16 bytes.
fn ret_part(b: &Body, ptr: u32, j: u32, pv: Value) (u32, u32, Value, u64) {
    let none = (NONE, 0u32, VNONE, 0u64);
    let s = b.insts[j as usize];
    if (s.aux & MEM_VOLATILE) != 0 {
        return none;
    }
    if s.op == O_STORE {
        let vt = b.type_of(s.b);
        if s.a != pv || s.c >= 16 || is_vec(vt) || vt == T_I128 || vt == T_PTR {
            return none;
        }
        return (s.c, type_bytes(vt, ptr), s.b, 0);
    }
    if s.op != O_MEMSET {
        return none;
    }
    let n = const_of(b, s.c);
    let f = const_of(b, s.b);
    let (base, off) = if is_op(b, s.a, O_PTRADD) && b.insts[s.a as usize].b == VNONE {
        (b.insts[s.a as usize].a, b.insts[s.a as usize].c)
    } else {
        (s.a, 0u32)
    };
    if base != pv || n.is_none() || f.is_none() || n.unwrap() == 0 || n.unwrap() > 8 || off >= 16 {
        return none;
    }
    let sz = n.unwrap() as u32;
    let bits = (f.unwrap() & 0xFF) * 0x0101010101010101;
    return (
        off,
        sz,
        VNONE,
        if sz == 8 {
            bits
        } else {
            bits & (1u64 << 8 * sz) - 1
        }
    );
}

// The `x` of comparison `v` of `b`, `x != 0` (`x == 0` when `eq`) of an integer `x` (no pointer); VNONE
// when `v` is no such comparison.
fn zero_test(b: &Body, v: Value, eq: bool) Value {
    if (v & (VPARAM | VFLAG)) != 0 || v == VNONE {
        return VNONE;
    }
    let t = b.insts[v as usize];
    let ty = if t.op == O_ICMP {
        b.type_of(t.a)
    } else {
        T_NONE
    };
    if t.op != O_ICMP || t.aux != if eq {
        C_EQ
    } else {
        C_NE
    } || !is_int(ty) || ty == T_PTR || ty == T_I128 || const_of(b, t.b) != Some(0u64) {
        return VNONE;
    }
    return t.a;
}

// The `d` of comparison `v` of `b`, `(x & d) == 0` (`!= 0` when `ne`) with `d` = `x - 1` (`x + -1`),
// pointers `ptr` bytes; VNONE when `v` is no such comparison (or `x` is VNONE).
fn low_clear(b: &Body, ptr: u32, v: Value, ne: bool, x: Value) Value {
    if x == VNONE || (v & (VPARAM | VFLAG)) != 0 || v == VNONE {
        return VNONE;
    }
    let t = b.insts[v as usize];
    if t.op != O_ICMP || t.aux != if ne {
        C_NE
    } else {
        C_EQ
    } || const_of(b, t.b) != Some(0u64) || !is_op(b, t.a, O_AND) {
        return VNONE;
    }
    let a = b.insts[t.a as usize];
    let d = if a.a == x {
        a.b
    } else if a.b == x {
        a.a
    } else {
        VNONE
    };
    if d == VNONE || (d & (VPARAM | VFLAG)) != 0 {
        return VNONE;
    }
    let s = b.insts[d as usize];
    let ones = width_mask(b.type_of(x), ptr);
    if s.a == x && (s.op == O_ADD && const_of(b, s.b) == Some(ones) || s.op == O_SUB && const_of(b, s.b) == Some(1u64)) {
        return d;
    }
    return VNONE;
}

// Whether condition `c` of `b` is condition `x` (1), its opposite comparison (2), or neither (0).
fn same_test(b: &Body, x: Value, c: Value) u8 {
    if x == c {
        return 1;
    }
    if !is_op(b, x, O_ICMP) || !is_op(b, c, O_ICMP) {
        return 0;
    }
    let p = b.insts[x as usize];
    let q = b.insts[c as usize];
    if p.a != q.a || p.b != q.b {
        return 0;
    }
    return if p.aux == q.aux {
        1
    } else if p.aux == opposite(q.aux) {
        2
    } else {
        0
    };
}

// Operand `v` of block `jb`'s instructions along edge `e` into it (`Opt::ret_folded`): a parameter of `jb` is
// the edge's argument, an instruction of `jb` its value in `sub`, another value itself; and whether it is
// known (an instruction of `jb` that did not simplify is not).
fn thru_val(b: &Body, jb: Block, e: u32, sub: &[Value; THREAD_BLOCK_MAX as usize], v: Value) (Value, bool) {
    if v == VNONE || (v & VFLAG) != 0 {
        return (v, true);
    }
    if (v & VPARAM) != 0 {
        let q = v & ~VPARAM;
        if q >= jb.param_start && q < jb.param_start + jb.param_len as u32 {
            return (b.edge_arg(e, q - jb.param_start), true);
        }
        return (v, true);
    }
    if v >= jb.start && v < jb.start + jb.len {
        let w = sub[(v - jb.start) as usize];
        return (w, w != VNONE);
    }
    return (v, true);
}

// Branch `t` of `b`: each edge argument that is a select on the branch's condition, or on the opposite
// comparison, takes the side the edge implies (`select(c, x, y)` passed where `c` holds is `x`). Whether
// any did.
fn edge_selects(b: &mut Body, t: Inst) bool {
    let mut any = false;
    for q in 0..2u32 {
        let e = if q == 0 {
            t.b
        } else {
            t.c
        };
        // Where the edge runs, the condition holds (the true edge) or fails.
        let holds = q == 0;
        for k in 0..b.edge_nargs(e) {
            let v = b.edge_arg(e, k);
            if !is_op(b, v, O_SELECT) {
                continue;
            }
            let s = b.insts[v as usize];
            let same = s.a == t.a;
            let mut opp = false;
            if !same && is_op(b, s.a, O_ICMP) && is_op(b, t.a, O_ICMP) {
                let x = b.insts[s.a as usize];
                let y = b.insts[t.a as usize];
                opp = x.a == y.a && x.b == y.b && x.aux == opposite(y.aux);
            }
            if same || opp {
                b.pool[(e + 2 + k) as usize] = if same == holds {
                    s.b
                } else {
                    s.c
                };
                any = true;
            }
        }
    }
    return any;
}

// The slice or `str` parameter (`REF_INNER`: its address at offset 0, its length at the pointers' bytes)
// whose element pointer address `p` of `b` (maybe as an integer, `ptrtoint`) offsets, through at most
// NONNULL_STEPS offsets; VNONE when none. A slice that is not empty points at its elements, never null,
// and an offset within them is not null either.
fn slice_of(b: &Body, p: Value) Value {
    let mut q = p;
    if is_op(b, q, O_PTRTOINT) {
        q = b.insts[q as usize].a;
    }
    for _ in 0..NONNULL_STEPS {
        if !is_op(b, q, O_PTRADD) {
            break;
        }
        q = b.insts[q as usize].a;
    }
    if !is_op(b, q, O_LOAD) || b.insts[q as usize].c != 0 || b.insts[q as usize].ty != T_PTR {
        return VNONE;
    }
    let s = b.insts[q as usize].a;
    let e = b.blocks[0].param_start;
    if (s & VPARAM) == 0 || s == VNONE || (s & ~VPARAM) < e || ((s & ~VPARAM) - e) as usize >= b.refs.len() || (b.refs[((s & ~VPARAM) - e) as usize] & REF_INNER) == 0 {
        return VNONE;
    }
    return s;
}

// Whether comparison `c` of `b` holding (failing, when not `holds`) implies the length of slice parameter
// `s` (at offset `ptr`) is not 0: `i <u len`, `len >u i` or `len != 0`.
fn len_set(b: &Body, ptr: u32, s: Value, c: Value, holds: bool) bool {
    if !is_op(b, c, O_ICMP) {
        return false;
    }
    let k = b.insts[c as usize];
    let cc = if holds {
        k.aux
    } else {
        opposite(k.aux)
    };
    let len = |v: Value| is_op(b, v, O_LOAD) && b.insts[v as usize].a == s && b.insts[v as usize].c == ptr;
    return cc == C_ULT && len(k.b) || cc == C_UGT && len(k.a) || cc == C_NE && (len(k.a) && const_of(b, k.b) == Some(
        0u64,
    ) || len(k.b) && const_of(b, k.a) == Some(0u64));
}

// Whether value `v` of `b` is 0 unless value `x` is 0: a test that `x` is 0 (`x == 0`, `x <u 1`), extended
// or negated (`-y`, `0 - y`), at most ZERO_TEST_DEPTH times.
fn zero_unless_zero(b: &Body, v: Value, x: Value) bool {
    let mut u = v;
    for _ in 0..ZERO_TEST_DEPTH {
        if u == VNONE || (u & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let t = b.insts[u as usize];
        if t.op == O_ICMP {
            let k = const_of(b, t.b);
            return t.a == x && k.is_some() && (k.unwrap() == 0 && (t.aux == C_EQ || t.aux == C_ULE) || k.unwrap() == 1 && t.aux == C_ULT);
        }
        if t.op == O_SUB && const_of(b, t.a) == Some(0u64) {
            u = t.b;
            continue;
        }
        if t.op != O_ZEXT && t.op != O_SEXT && t.op != O_NEG {
            return false;
        }
        u = t.a;
    }
    return false;
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
        // Inserts of one scalar into every lane: its splat.
        let n = lanes(t.ty);
        let mut set: u64 = 0;
        let mut v = i;
        for _ in 0..n.min(LANE_WALK) {
            if (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_VINSERT || b.insts[v as usize].b != t.b {
                break;
            }
            set |= 1u64 << b.insts[v as usize].aux as u64;
            v = b.insts[v as usize].a;
        }
        if n <= LANE_WALK && set == if n == 64 {
            ~0u64
        } else {
            (1u64 << n as u64) - 1
        } {
            b.insts[i as usize] = Inst { op: O_SPLAT, ty: t.ty, aux: 0, a: t.b, b: VNONE, c: VNONE };
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
// order, signed or not) of at most `max` bytes: the lanes' maximum or minimum (`vop.max`, `vop.min`; arm64
// `smax`, x86-64 `pmaxsw`), as LLVM InstCombine's select of a compare. Outside the walk, which reads a
// vector operation's operands in the pool only where it numbers them. Whether any changed.
fn vec_minmaxes(b: &mut Body, max: u32) bool {
    let mut any = false;
    for i in 0..b.insts.len() {
        if b.insts[i].op == O_VSEL && type_bytes(b.insts[i].ty, 8) <= max && vec_minmax(b, i as u32) {
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

// Vector instruction `i` of `b` (integer lanes), in place: a sum with a negation a difference, a
// difference with one a sum; an `xor` of two constants (`vec_words`) a wide constant.
fn simplify_vec(b: &mut Body, i: u32) {
    let t = b.insts[i as usize];
    let lt = lane_type(t.ty);
    if !is_int(lt) {
        return;
    }
    if (t.op == O_ADD || t.op == O_SUB) && is_op(b, t.b, O_NEG) {
        let o = if t.op == O_ADD {
            O_SUB
        } else {
            O_ADD
        };
        b.insts[i as usize] = Inst { op: o, ty: t.ty, aux: 0, a: t.a, b: b.insts[t.b as usize].a, c: VNONE };
        return;
    }
    if t.op == O_ADD && is_op(b, t.a, O_NEG) {
        b.insts[i as usize] = Inst { op: O_SUB, ty: t.ty, aux: 0, a: t.b, b: b.insts[t.a as usize].a, c: VNONE };
        return;
    }
    let nb = type_bytes(t.ty, 8);
    let mut x: [u64; 8] = [0; 8];
    let mut y: [u64; 8] = [0; 8];
    // A lane mask's choice of 1 or 0 is the mask's lowest bits; a sum with them is a difference with the
    // mask (each lane -1 or 0).
    if t.op == O_VSEL && b.type_of(t.a) == t.ty && lane_mask(b, t.a, 4) && lanes_are(b, t.b, t.ty, 1) && lanes_are(
        b,
        t.c,
        t.ty,
        0,
    ) {
        b.insts[i as usize] = Inst { op: O_AND, ty: t.ty, aux: 0, a: t.a, b: t.b, c: VNONE };
        return;
    }
    if t.op == O_ADD {
        for (s, o) in [(t.a, t.b), (t.b, t.a)] {
            if is_op(b, s, O_AND) {
                let m = b.insts[s as usize];
                let mk = if lanes_are(b, m.b, t.ty, 1) {
                    m.a
                } else if lanes_are(b, m.a, t.ty, 1) {
                    m.b
                } else {
                    VNONE
                };
                if mk != VNONE && b.type_of(mk) == t.ty && lane_mask(b, mk, 4) {
                    b.insts[i as usize] = Inst { op: O_SUB, ty: t.ty, aux: 0, a: o, b: mk, c: VNONE };
                    return;
                }
            }
        }
    }
    if t.op == O_XOR && nb % 8 == 0 && vec_words(b, t.a, t.ty, &mut x) && vec_words(b, t.b, t.ty, &mut y) {
        let at = b.words.len() as u32;
        for q in 0..nb / 8 {
            b.words.push(x[q as usize] ^ y[q as usize]);
        }
        b.insts[i as usize] = Inst { op: O_WCONST, ty: t.ty, aux: 0, a: at, b: nb / 8, c: VNONE };
    }
}

// Whether every lane of vector `v` of `b` (of type `vt`) is the constant `k`.
fn lanes_are(b: &Body, v: Value, vt: u8, k: u64) bool {
    if (v & (VPARAM | VFLAG)) != 0 || v == VNONE {
        return false;
    }
    let t = b.insts[v as usize];
    let bits = 8 * type_bytes(lane_type(vt), 8);
    if t.op == O_SPLAT {
        let c = const_of(b, t.a);
        return c.is_some() && le::trunc_bits(c.unwrap(), bits) == k;
    }
    let mut w: [u64; 8] = [0; 8];
    if type_bytes(vt, 8) % 8 != 0 || !vec_words(b, v, vt, &mut w) {
        return false;
    }
    let mut e: u64 = 0;
    for l in 0..64 / bits {
        e |= k << (l * bits) as u64;
    }
    for q in 0..type_bytes(vt, 8) / 8 {
        if w[q as usize] != e {
            return false;
        }
    }
    return true;
}

// The 8-byte words of vector constant `v` of `b` of type `vt` (a multiple of 8 bytes, at most 64), in
// `out`: a wide constant's, or a splat of an integer constant's. Whether it is one.
fn vec_words(b: &Body, v: Value, vt: u8, out: &mut [u64; 8]) bool {
    if (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let t = b.insts[v as usize];
    let nw = type_bytes(vt, 8) / 8;
    if t.op == O_WCONST && t.b == nw {
        for q in 0..nw {
            out[q as usize] = b.words[(t.a + q) as usize];
        }
        return true;
    }
    if t.op != O_SPLAT {
        return false;
    }
    let c = const_of(b, t.a);
    if c.is_none() {
        return false;
    }
    let bits = 8 * type_bytes(lane_type(vt), 8);
    let mut w: u64 = 0;
    for l in 0..64 / bits {
        w |= le::trunc_bits(c.unwrap(), bits) << (l * bits) as u64;
    }
    for q in 0..nw {
        out[q as usize] = w;
    }
    return true;
}

// The zero or sign extension that defines `v` (not of an overflow flag), else an `iconst` (no extension).
fn extension(b: &Body, v: Value) Inst {
    if v != VNONE && (v & (VPARAM | VFLAG)) == 0 && (b.insts[v as usize].op == O_ZEXT || b.insts[v as usize].op == O_SEXT) && (b.insts[v as usize].a & VFLAG) == 0 {
        return b.insts[v as usize];
    }
    return iconst(T_I32, 0);
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
        simplify_vec(b, i);
        return VNONE;
    }
    let ptr = pk.ptr_bytes;
    // A byte or bit reversal or a bit count of a constant.
    if (t.op == O_BSWAP || t.op == O_BITREV || t.op >= O_CLZ && t.op <= O_POPCNT) && is_int(t.ty) && t.ty != T_PTR {
        let c = const_of(b, t.a);
        if c.is_some() {
            let bits = type_bits(t.ty, ptr);
            let x = le::trunc_bits(c.unwrap(), bits);
            let r = if t.op == O_BSWAP {
                x.swap_bytes() >> (64 - bits) as u64
            } else if t.op == O_BITREV {
                x.reverse_bits() >> (64 - bits) as u64
            } else if t.op == O_POPCNT {
                x.count_ones() as u64
            } else if x == 0 {
                bits as u64
            } else if t.op == O_CLZ {
                (x.leading_zeros() - (64 - bits as usize)) as u64
            } else {
                x.trailing_zeros() as u64
            };
            b.insts[i as usize] = iconst(t.ty, r);
            return VNONE;
        }
    }
    // A null test of `select(c, 0, p)` (or `select(c, p, 0)`), `p` never null (`nonnull`: an `Option` of a
    // reference) or an element address of a slice parameter, which is not null where `c` (its opposite)
    // implies the slice is not empty: the test is the condition or its opposite (an iterator's `next` as a
    // pointer or null, `slice_of`).
    if t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) && const_of(b, t.b) == Some(0u64) && is_op(b, t.a, O_SELECT) {
        let s = b.insts[t.a as usize];
        let (p, when) = if const_of(b, s.b) == Some(0u64) {
            (s.c, false)
        } else if const_of(b, s.c) == Some(0u64) {
            (s.b, true)
        } else {
            (VNONE, false)
        };
        let sl = slice_of(b, p);
        let set = p != VNONE && sl != VNONE && len_set(b, ptr, sl, s.a, when);
        if set || p != VNONE && nonnull(b, p, ptr) && (t.aux == C_NE == when || is_op(b, s.a, O_ICMP)) {
            if t.aux == C_NE == when {
                return s.a;
            }
            let c = b.insts[s.a as usize];
            b.insts[i as usize] = Inst { op: O_ICMP, ty: t.ty, aux: opposite(c.aux), a: c.a, b: c.b, c: VNONE };
            return VNONE;
        }
    }
    if t.op == O_ICMP && t.aux <= C_UGE {
        let f = order_test(b, t, ptr);
        if f.is_some() {
            b.insts[i as usize] = f.unwrap();
            return VNONE;
        }
        let g = in_bounds_test(b, t);
        if g.is_some() {
            b.insts[i as usize] = g.unwrap();
            return VNONE;
        }
    }
    if is_int(t.ty) && t.ty != T_PTR && (t.op == O_TRUNC || t.op == O_LSHR || t.op == O_SHL || t.op == O_AND || t.op == O_OR) {
        let r = demanded_fold(b, i, ptr);
        if r != VNONE {
            return r;
        }
        t = b.insts[i as usize];
    }
    if t.op == O_SELECT {
        let c = const_of(b, t.a);
        if c.is_some() {
            return if c.unwrap() != 0 {
                t.b
            } else {
                t.c
            };
        }
        // A select on a zero extension of an `i8` (a flag) tests that `i8`.
        if (t.a & (VPARAM | VFLAG)) == 0 && t.a != VNONE {
            let c = b.insts[t.a as usize];
            if c.op == O_ZEXT && b.type_of(c.a) == T_I8 {
                b.insts.index_mut(i as usize).a = c.a;
                t = b.insts[i as usize];
            }
        }
        // A select on a flag's equality with 0 or its `xor` with 1 (`!f`) is one on the flag, arms swapped.
        if (t.a & (VPARAM | VFLAG)) == 0 && t.a != VNONE {
            let c = b.insts[t.a as usize];
            let not = c.op == O_XOR && const_of(b, c.b) == Some(1u64) && zero_one(b, c.a, ZO_DEPTH);
            if not || c.op == O_ICMP && (c.aux == C_EQ || c.aux == C_NE) && const_of(b, c.b) == Some(0u64) && zero_one(
                b,
                c.a,
                ZO_DEPTH,
            ) {
                b.insts[i as usize] = if not || c.aux == C_EQ {
                    Inst { op: O_SELECT, ty: t.ty, aux: 0, a: c.a, b: t.c, c: t.b }
                } else {
                    Inst { op: O_SELECT, ty: t.ty, aux: 0, a: c.a, b: t.b, c: t.c }
                };
                t = b.insts[i as usize];
            }
        }
        // An arm that is a select on a condition this one decides (`implied`) is that select's arm.
        let tb = decided_arm(b, t.a, t.b, true);
        let tc = decided_arm(b, t.a, t.c, false);
        if tb != t.b || tc != t.c {
            if tb == tc {
                return tb;
            }
            b.insts.index_mut(i as usize).b = tb;
            b.insts.index_mut(i as usize).c = tc;
            t = b.insts[i as usize];
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
            let off = (t.c as i32) as i64 + le::sign_ext(ix.unwrap(), type_bits(b.type_of(t.b), ptr)) * scale_of(t) as i64;
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
                let off = (t.c as i32) as i64 + d * scale_of(t) as i64;
                if kv > -0x80000000 && kv < 0x80000000 && off >= -0x80000000 && off <= 0x7FFFFFFF {
                    // The index alone times the scale may overflow: the same address, not in bounds.
                    t.b = x.a;
                    t.c = off as u32;
                    t.aux &= ~PTR_INBOUNDS;
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
            if f.is_some() && f.unwrap() != 0 && scale_of(t) as u64 * f.unwrap() <= PTR_SCALE as u64 {
                t.aux = (scale_of(t) as u64 * f.unwrap()) as u16 | t.aux & PTR_NONNULL;
                t.b = x2.a;
            }
        }
        if t.b == VNONE && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_PTRADD && b.insts[t.a as usize].b == VNONE {
            let off = (t.c as i32) as i64 + (b.insts[t.a as usize].c as i32) as i64;
            if off >= -0x80000000 && off <= 0x7FFFFFFF {
                // In bounds of the inner base when both steps are.
                if (b.insts[t.a as usize].aux & PTR_INBOUNDS) == 0 {
                    t.aux &= ~PTR_INBOUNDS;
                }
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
        if y == ones && op == O_MUL && t.ty != T_I128 {
            b.insts[i as usize] = Inst { op: O_NEG, ty: t.ty, aux: 0, a: t.a, b: VNONE, c: VNONE };
            return VNONE;
        }
        return cancel(b, t);
    }
    // A product with a factor that is 0 unless the other is 0 is 0 (`x * -(x == 0)`, which a 128-bit
    // product splits into: `lir::pairs`).
    if op == O_MUL && t.ty != T_I128 && (zero_unless_zero(b, t.a, t.b) || zero_unless_zero(b, t.b, t.a)) {
        b.insts[i as usize] = iconst(t.ty, 0);
        return VNONE;
    }
    // A sum with a negation is a difference, a difference with one a sum.
    if (op == O_ADD || op == O_SUB) && t.ty != T_I128 {
        if is_op(b, t.b, O_NEG) {
            let o = if op == O_ADD {
                O_SUB
            } else {
                O_ADD
            };
            b.insts[i as usize] = Inst { op: o, ty: t.ty, aux: 0, a: t.a, b: b.insts[t.b as usize].a, c: VNONE };
            return VNONE;
        }
        if op == O_ADD && is_op(b, t.a, O_NEG) {
            b.insts[i as usize] = Inst { op: O_SUB, ty: t.ty, aux: 0, a: t.b, b: b.insts[t.a as usize].a, c: VNONE };
            return VNONE;
        }
    }
    if t.a == t.b {
        if op == O_AND || op == O_OR {
            return t.a;
        }
        if op == O_SUB || op == O_XOR {
            b.insts[i as usize] = iconst(t.ty, 0);
        }
    }
    // `(x - y) - x` and `x - (x + y)` are `-y` (a constant negated), `x - (x - y)` is `y`.
    if op == O_SUB && t.ty != T_I128 {
        let none = Inst { op: 0, ty: 0, aux: 0, a: VNONE, b: VNONE, c: VNONE };
        let c = if (t.b & (VPARAM | VFLAG)) == 0 {
            b.insts[t.b as usize]
        } else {
            none
        };
        if c.op == O_SUB && same_term(b, c.a, t.a) {
            return c.b;
        }
        let a = if (t.a & (VPARAM | VFLAG)) == 0 {
            b.insts[t.a as usize]
        } else {
            none
        };
        let y = if a.op == O_SUB && same_term(b, a.a, t.b) {
            a.b
        } else if c.op == O_ADD && same_term(b, c.a, t.a) {
            c.b
        } else if c.op == O_ADD && same_term(b, c.b, t.a) {
            c.a
        } else {
            VNONE
        };
        if y != VNONE {
            let k = const_of(b, y);
            b.insts[i as usize] = if k.is_some() {
                iconst(t.ty, le::trunc_bits(k.unwrap().wrapping_neg(), type_bits(t.ty, ptr)))
            } else {
                Inst { op: O_NEG, ty: t.ty, aux: 0, a: y, b: VNONE, c: VNONE }
            };
            return VNONE;
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

// The outcomes (bits: below, equal, above) of a comparison of two integers for which code `c` holds.
const fn outcomes(c: u16) u32 {
    let k = if c < C_SLT {
        c
    } else {
        (c - C_SLT) % 4 + 2
    };
    return if k == C_EQ {
        0b010
    } else if k == C_NE {
        0b101
    } else if k == 2 {
        0b001
    } else if k == 3 {
        0b011
    } else if k == 4 {
        0b100
    } else {
        0b110
    };
}

// The value of condition `q` of `b` where condition `p` is `truth`: 1 true, 0 false, 2 unknown. `q` is `p`,
// or both are integer comparisons of the same two values (either order) whose outcomes, of one
// signedness, one contains or excludes the other's (`a < b` decides `a <= b`, `b > a` and `a == b`).
fn implied(b: &Body, p: Value, q: Value, truth: bool) u8 {
    if q == p {
        return truth as u8;
    }
    if (p & (VPARAM | VFLAG)) != 0 || (q & (VPARAM | VFLAG)) != 0 || p == VNONE || q == VNONE {
        return 2;
    }
    let x = b.insts[p as usize];
    let y = b.insts[q as usize];
    if x.op != O_ICMP || y.op != O_ICMP || x.aux > C_UGE || y.aux > C_UGE {
        return 2;
    }
    let qc = if y.a == x.a && y.b == x.b {
        y.aux
    } else if y.a == x.b && y.b == x.a {
        mirror(y.aux)
    } else {
        return 2;
    };
    let pc = if truth {
        x.aux
    } else {
        opposite(x.aux)
    };
    // Of two ordered comparisons, one signed and one unsigned: unrelated.
    if pc >= C_SLT && qc >= C_SLT && pc >= C_ULT != qc >= C_ULT {
        return 2;
    }
    let ps = outcomes(pc);
    let qs = outcomes(qc);
    return if (ps & ~qs) == 0 {
        1
    } else if (ps & qs) == 0 {
        0
    } else {
        2
    };
}

// Arm `v` of a select on `p`, taken where `p` is `truth`: through each select on a condition `p` decides
// there (`implied`), the arm it takes. At most ZO_DEPTH steps.
fn decided_arm(b: &Body, p: Value, v: Value, truth: bool) Value {
    let mut x = v;
    for _ in 0..ZO_DEPTH {
        if (x & (VPARAM | VFLAG)) != 0 || x == VNONE || b.insts[x as usize].op != O_SELECT {
            return x;
        }
        let s = b.insts[x as usize];
        let d = implied(b, p, s.a, truth);
        if d == 2 {
            return x;
        }
        x = if d == 1 {
            s.b
        } else {
            s.c
        };
    }
    return x;
}

// Whether comparison `t` with value `v` in place of its non-constant side (`left`: its first) folds into
// constants and comparisons (`Opt::icmp_select`): `v` is a constant, a three-way comparison, or a select of
// such values, `depth` selects deep.
fn cmp_arm(pk: &Package, b: &Body, t: Inst, left: bool, v: Value, depth: u32) bool {
    if const_of(b, v).is_some() {
        return true;
    }
    let mut u = t;
    if left {
        u.a = v;
    } else {
        u.b = v;
    }
    if order_test(b, u, pk.ptr_bytes).is_some() {
        return true;
    }
    if depth == 0 || (v & (VPARAM | VFLAG)) != 0 || v == VNONE || b.insts[v as usize].op != O_SELECT {
        return false;
    }
    let s = b.insts[v as usize];
    return is_int(s.ty) && s.ty != T_PTR && s.ty != T_I128 && cmp_arm(pk, b, t, left, s.b, depth - 1) && cmp_arm(
        pk,
        b,
        t,
        left,
        s.c,
        depth - 1,
    );
}

// Integer condition `c` between constants `x` and `y` of `bits` bits.
fn holds_const(c: u16, x: u64, y: u64, bits: u32) bool {
    let xu = le::trunc_bits(x, bits);
    let yu = le::trunc_bits(y, bits);
    let xs = le::sign_ext(x, bits);
    let ys = le::sign_ext(y, bits);
    return if c == C_EQ {
        xu == yu
    } else if c == C_NE {
        xu != yu
    } else if c == C_SLT {
        xs < ys
    } else if c == C_SLE {
        xs <= ys
    } else if c == C_SGT {
        xs > ys
    } else if c == C_SGE {
        xs >= ys
    } else if c == C_ULT {
        xu < yu
    } else if c == C_ULE {
        xu <= yu
    } else if c == C_UGT {
        xu > yu
    } else {
        xu >= yu
    };
}

// The two values and the signedness of three-way comparison `v` of `b`: `(x > y) - (x < y)` of flags
// extended, the comparisons of one signedness and of one pair (either order). VNONE when `v` is not one.
fn three_way(b: &Body, v: Value) (Value, Value, bool) {
    let none = (VNONE, VNONE, false);
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_SUB {
        return none;
    }
    let s = b.insts[v as usize];
    if (s.a & (VPARAM | VFLAG)) != 0 || (s.b & (VPARAM | VFLAG)) != 0 || b.insts[s.a as usize].op != O_ZEXT || b.insts[s.b as usize].op != O_ZEXT {
        return none;
    }
    let f = b.insts[s.a as usize].a;
    let g = b.insts[s.b as usize].a;
    if (f & (VPARAM | VFLAG)) != 0 || (g & (VPARAM | VFLAG)) != 0 || b.insts[f as usize].op != O_ICMP || b.insts[g as usize].op != O_ICMP {
        return none;
    }
    let x = b.insts[f as usize];
    let y = b.insts[g as usize];
    let gc = if y.a == x.a && y.b == x.b {
        y.aux
    } else if y.a == x.b && y.b == x.a {
        mirror(y.aux)
    } else {
        return none;
    };
    if x.aux == C_SGT && gc == C_SLT || x.aux == C_UGT && gc == C_ULT {
        return (x.a, x.b, x.aux == C_SGT);
    }
    return none;
}

// Comparison `t` of a three-way comparison of `x` and `y` (`three_way`, of -1, 0 or 1) with a constant: the
// comparison of `x` and `y` that holds for the same outcomes, or a constant flag. None when `t` is not one.
fn order_test(b: &Body, t: Inst, ptr: u32) Option<Inst> {
    let (v, k, code) = if const_of(b, t.b).is_some() {
        (t.a, const_of(b, t.b).unwrap(), t.aux)
    } else if const_of(b, t.a).is_some() {
        (t.b, const_of(b, t.a).unwrap(), mirror(t.aux))
    } else {
        return None;
    };
    let (x, y, signed) = three_way(b, v);
    if x == VNONE {
        return None;
    }
    let bits = type_bits(b.type_of(v), ptr);
    let m = width_mask(b.type_of(v), ptr);
    let ks = le::sign_ext(k, bits);
    // Per outcome (below, equal, above: -1, 0, 1), whether `code` holds of it against `k`.
    let mut holds: u32 = 0;
    for o in 0..3 {
        let r = o as i64 - 1;
        let h = if code == C_EQ {
            (r as u64 & m) == (k & m)
        } else if code == C_NE {
            (r as u64 & m) != (k & m)
        } else if code < C_ULT {
            let d = code - C_SLT;
            d == 0 && r < ks || d == 1 && r <= ks || d == 2 && r > ks || d == 3 && r >= ks
        } else {
            let (ru, ku) = (r as u64 & m, k & m);
            let d = code - C_ULT;
            d == 0 && ru < ku || d == 1 && ru <= ku || d == 2 && ru > ku || d == 3 && ru >= ku
        };
        holds |= h as u32 << o as u32;
    }
    if holds == 0 || holds == 7 {
        return Some(iconst(t.ty, (holds == 7) as u64));
    }
    let base = if signed {
        C_SLT
    } else {
        C_ULT
    };
    let codes: [u16; 6] = [C_EQ, C_NE, base, base + 1, base + 2, base + 3];
    for q in 0..6 {
        if outcomes(codes[q]) == holds {
            return Some(Inst { op: O_ICMP, ty: t.ty, aux: codes[q], a: x, b: y, c: VNONE });
        }
    }
    return None;
}

// Address `v` of `b` as base, index (VNONE: none), scale and offset: a `ptradd` in bounds of its base
// (PTR_INBOUNDS), else `v` itself at offset 0.
fn in_bounds_parts(b: &Body, v: Value) (Value, Value, u32, i64) {
    if (v & (VPARAM | VFLAG)) == 0 && v != VNONE {
        let t = b.insts[v as usize];
        if t.op == O_PTRADD && (t.aux & PTR_INBOUNDS) != 0 {
            let s = if t.b == VNONE {
                0u32
            } else {
                scale_of(t)
            };
            return (t.a, t.b, s, (t.c as i32) as i64);
        }
    }
    return (v, VNONE, 0, 0);
}

// Comparison `t` of two addresses in bounds of one base (PTR_INBOUNDS, `in_bounds_parts`) as their offsets
// compare: both in one object of at most `isize::MAX` bytes, so `base + i * s + c` orders as `i * s + c`
// signed, which no product overflows (LLVM's `inbounds` compares). Of constant offsets alone, or of one
// index, a constant; of two indices of one type, scale and offset, the indices' comparison (signed for an
// order: `p + i < p + n` is `i <s n`). None for another comparison.
fn in_bounds_test(b: &Body, t: Inst) Option<Inst> {
    if b.type_of(t.a) != T_PTR || t.aux > C_UGE || t.aux >= C_SLT && t.aux <= C_SGE {
        return None;
    }
    let (p, i, s, c) = in_bounds_parts(b, t.a);
    let (q, n, r, d) = in_bounds_parts(b, t.b);
    if p != q || p == t.a && q == t.b {
        return None;
    }
    // The signed condition of an unsigned one; `==` and `!=` stay.
    let sc = if t.aux <= C_NE {
        t.aux
    } else {
        t.aux - (C_ULT - C_SLT)
    };
    if i == n {
        // Equal products: the offsets decide.
        let hold = if sc == C_EQ {
            c == d
        } else if sc == C_NE {
            c != d
        } else if sc == C_SLT {
            c < d
        } else if sc == C_SLE {
            c <= d
        } else if sc == C_SGT {
            c > d
        } else {
            c >= d
        };
        return Some(iconst(t.ty, hold as u64));
    }
    if i == VNONE || n == VNONE || s != r || c != d || b.type_of(i) != b.type_of(n) {
        return None;
    }
    return Some(Inst { op: O_ICMP, ty: t.ty, aux: sc, a: i, b: n, c: VNONE });
}

// `zero_bits` follows at most ZB_DEPTH operations.
const ZB_DEPTH: u32 = 6;

// The bits of integer value `v` of `b` known to be 0, within its type's width (LLVM's known bits, for
// zeros): constants, extensions, comparisons, `bool` values, bitwise operations, shifts by constants,
// selects and bit counts, `depth` operations deep.
fn zero_bits(b: &Body, v: Value, ptr: u32, depth: u32) u64 {
    if v == VNONE {
        return 0;
    }
    if (v & VFLAG) != 0 {
        return ~1u64;
    }
    if (v & VPARAM) != 0 {
        let k = entry_param(b, v);
        return if k < 64 && (b.bools >> k as u64 & 1) != 0 {
            ~1u64
        } else {
            0
        };
    }
    let t = b.insts[v as usize];
    if !is_int(t.ty) || t.ty == T_PTR || t.ty == T_I128 {
        return 0;
    }
    let m = width_mask(t.ty, ptr);
    if t.op == O_ICONST {
        return ~const_of(b, v).unwrap() & m;
    }
    if t.op == O_ICMP || t.op == O_FCMP {
        return ~1u64 & m;
    }
    let lb = load_bound(t, m);
    if lb.is_some() {
        // The bits above the bound's highest.
        let x = lb.unwrap();
        return if x == 0 {
            m
        } else {
            ~(u64::MAX >> x.leading_zeros() as u64) & m
        };
    }
    if t.op >= O_CLZ && t.op <= O_POPCNT {
        // A count is at most the width: below twice the width.
        return ~(2 * type_bits(t.ty, ptr) as u64 - 1) & m;
    }
    if depth == 0 {
        return 0;
    }
    let d = depth - 1;
    let z = if t.op == O_ZEXT {
        let at = b.type_of(t.a);
        if !is_int(at) || at == T_PTR || at == T_I128 {
            return 0;
        }
        zero_bits(b, t.a, ptr, d) | ~width_mask(at, ptr)
    } else if t.op == O_TRUNC {
        if b.type_of(t.a) == T_I128 {
            return 0;
        }
        zero_bits(b, t.a, ptr, d)
    } else if t.op == O_AND {
        zero_bits(b, t.a, ptr, d) | zero_bits(b, t.b, ptr, d)
    } else if t.op == O_OR || t.op == O_XOR {
        zero_bits(b, t.a, ptr, d) & zero_bits(b, t.b, ptr, d)
    } else if t.op == O_SELECT {
        zero_bits(b, t.b, ptr, d) & zero_bits(b, t.c, ptr, d)
    } else if t.op == O_SHL || t.op == O_LSHR {
        let c = const_of(b, t.b);
        if c.is_none() || c.unwrap() >= type_bits(t.ty, ptr) as u64 {
            return 0;
        }
        let s = c.unwrap();
        if t.op == O_SHL {
            zero_bits(b, t.a, ptr, d) << s | (1u64 << s) - 1
        } else {
            (zero_bits(b, t.a, ptr, d) & m) >> s | ~(m >> s)
        }
    } else {
        0
    };
    return z & m;
}

// `or` leaves `rejoined` takes at most.
const REJOIN_MAX: usize = 8;

// The value whose bits `v` of `b` keeps in place and their mask: `x`, `x & c`, `zext(trunc x)`,
// `zext(trunc(x >> s)) << s`, `x >> s << s`, `x << s >> s`, each of `x` of `v`'s type; VNONE when `v` is
// none of them.
fn in_place(b: &Body, v: Value, ty: u8, ptr: u32) (Value, u64) {
    let m = width_mask(ty, ptr);
    let bits = type_bits(ty, ptr) as u64;
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
        return (v, m);
    }
    let t = b.insts[v as usize];
    if t.op == O_AND && const_of(b, t.b).is_some() {
        return (t.a, const_of(b, t.b).unwrap() & m);
    }
    let c = if t.op == O_SHL || t.op == O_LSHR {
        const_of(b, t.b)
    } else {
        Option::<u64>::None
    };
    if c.is_some() && c.unwrap() < bits && (t.a & (VPARAM | VFLAG)) == 0 {
        let s = c.unwrap();
        let u = b.insts[t.a as usize];
        let back = if t.op == O_SHL {
            O_LSHR
        } else {
            O_SHL
        };
        // `x >> s << s` and `x << s >> s`.
        if u.op == back && const_of(b, u.b) == c && u.ty == ty {
            return (
                u.a,
                if t.op == O_SHL {
                    m & ~((1u64 << s) - 1)
                } else {
                    m >> s
                }
            );
        }
        // `zext(trunc(x >> s)) << s`.
        if t.op == O_SHL {
            let (x, lo, n) = piece_of(b, t.a, ptr);
            if x != VNONE && lo == s && b.type_of(x) == ty {
                return (x, width_mask(int_type_of(n), ptr) << s & m);
            }
        }
        return (VNONE, 0);
    }
    let (x, lo, n) = piece_of(b, v, ptr);
    if x != VNONE && lo == 0 && b.type_of(x) == ty {
        return (x, width_mask(int_type_of(n), ptr));
    }
    if t.ty == ty {
        return (v, m);
    }
    return (VNONE, 0);
}

// `zext(trunc.N x)` or `zext(trunc.N(x >> s))` of `b`: `x`, `s` and the bytes N. VNONE when `v` is neither.
fn piece_of(b: &Body, v: Value, ptr: u32) (Value, u64, u32) {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_ZEXT {
        return (VNONE, 0, 0);
    }
    let (x, j, n) = stored_piece(b, b.insts[v as usize].a, ptr);
    return (x, 8 * j as u64, n);
}

// The integer type of `n` bytes (1, 2, 4 or 8).
const fn int_type_of(n: u32) u8 {
    return if n == 1 {
        T_I8
    } else if n == 2 {
        T_I16
    } else if n == 4 {
        T_I32
    } else {
        T_I64
    };
}

// `or` tree `i` of `b` whose leaves (at most REJOIN_MAX) each keep bits of one value `x` in place
// (`in_place`) and together all of them: `x` (the pieces of a value a wide store split into fields, which a
// wide load joins). VNONE when it is not one.
fn rejoined(b: &Body, i: u32, ptr: u32) Value {
    let t = b.insts[i as usize];
    if !is_int(t.ty) || t.ty == T_PTR || t.ty == T_I128 {
        return VNONE;
    }
    let mut todo = StaticVector::<Value, REJOIN_MAX>::new();
    todo.push(t.a);
    todo.push(t.b);
    let mut src = VNONE;
    let mut mask: u64 = 0;
    let mut leaves: usize = 0;
    // Each step takes one node of the tree: an `or` adds two, a leaf none; at most REJOIN_MAX leaves.
    for _ in 0..2 * REJOIN_MAX {
        if todo.len() == 0 {
            break;
        }
        let v = todo.pop().unwrap();
        if v != VNONE && (v & (VPARAM | VFLAG)) == 0 && b.insts[v as usize].op == O_OR && b.insts[v as usize].ty == t.ty {
            if todo.len() + 2 > REJOIN_MAX {
                return VNONE;
            }
            todo.push(b.insts[v as usize].a);
            todo.push(b.insts[v as usize].b);
            continue;
        }
        let (x, km) = in_place(b, v, t.ty, ptr);
        leaves += 1;
        if x == VNONE || src != VNONE && x != src || leaves > REJOIN_MAX {
            return VNONE;
        }
        src = x;
        mask |= km;
    }
    if todo.len() != 0 || src == VNONE || leaves < 2 {
        return VNONE;
    }
    return if mask == width_mask(t.ty, ptr) {
        src
    } else {
        VNONE
    };
}

// Through `or` and `xor` operations: `v` without each operand whose possibly-set bits are outside mask `dm`
// (the bits a reader of `v` reads). At most ZB_DEPTH steps.
fn undemanded(b: &Body, v: Value, dm: u64, ptr: u32) Value {
    let mut x = v;
    for _ in 0..ZB_DEPTH {
        if (x & (VPARAM | VFLAG)) != 0 || x == VNONE {
            return x;
        }
        let t = b.insts[x as usize];
        if t.op != O_OR && t.op != O_XOR || !is_int(t.ty) || t.ty == T_PTR || t.ty == T_I128 {
            return x;
        }
        let m = width_mask(t.ty, ptr);
        if (~zero_bits(b, t.b, ptr, ZB_DEPTH) & m & dm) == 0 {
            x = t.a;
        } else if (~zero_bits(b, t.a, ptr, ZB_DEPTH) & m & dm) == 0 {
            x = t.b;
        } else {
            return x;
        }
    }
    return x;
}

// Demanded and known bits of integer instruction `i` (a truncation, shift by a constant, `and` or `or`; LLVM
// InstCombine's SimplifyDemandedBits, in part): an `or` or `xor` operand whose bits it does not read goes
// (`undemanded`); `x << c >> c` and `x >> c << c` are `x` masked, and an `and` that keeps every bit its
// other operand may have is that operand, as is an `or` with a value of no possible bit; a truncation to
// known 0 bits is 0. The value `i` is (VNONE: none; `i` may be rewritten).
fn demanded_fold(b: &mut Body, i: u32, ptr: u32) Value {
    let t = b.insts[i as usize];
    let m = width_mask(t.ty, ptr);
    if t.op == O_OR {
        if (~zero_bits(b, t.b, ptr, ZB_DEPTH) & m) == 0 {
            return t.a;
        }
        if (~zero_bits(b, t.a, ptr, ZB_DEPTH) & m) == 0 {
            return t.b;
        }
        return rejoined(b, i, ptr);
    }
    let at = b.type_of(t.a);
    if !is_int(at) || at == T_PTR || at == T_I128 {
        return VNONE;
    }
    // A truncation to bits that are known 0 (a part of a word below its shifted field) is 0.
    if t.op == O_TRUNC && (~zero_bits(b, t.a, ptr, ZB_DEPTH) & m) == 0 {
        b.insts[i as usize] = iconst(t.ty, 0);
        return VNONE;
    }
    let c = const_of(b, t.b);
    let dm = if t.op == O_TRUNC {
        m
    } else if t.op == O_AND {
        if c.is_none() {
            return VNONE;
        }
        c.unwrap() & m
    } else {
        if c.is_none() || c.unwrap() >= type_bits(t.ty, ptr) as u64 {
            return VNONE;
        }
        if t.op == O_LSHR {
            m & ~((1u64 << c.unwrap()) - 1)
        } else {
            m >> c.unwrap()
        }
    };
    let x = undemanded(b, t.a, dm, ptr);
    if x != t.a {
        b.insts.index_mut(i as usize).a = x;
    }
    let u = b.insts[i as usize];
    if u.op == O_AND {
        let z = zero_bits(b, u.a, ptr, ZB_DEPTH);
        if (~z & m & ~dm) == 0 {
            return u.a;
        }
        return VNONE;
    }
    // `x << c >> c` and `x >> c << c`, which the `and` that follows folds when `x`'s other bits are 0.
    if (u.op == O_LSHR || u.op == O_SHL) && (u.a & (VPARAM | VFLAG)) == 0 {
        let w = b.insts[u.a as usize];
        let inner = if u.op == O_LSHR {
            O_SHL
        } else {
            O_LSHR
        };
        if w.op == inner && w.ty == u.ty && const_of(b, w.b) == c {
            let z = zero_bits(b, w.a, ptr, ZB_DEPTH);
            let keep = if u.op == O_LSHR {
                m >> c.unwrap()
            } else {
                m & ~((1u64 << c.unwrap()) - 1)
            };
            if (~z & m & ~keep) == 0 {
                return w.a;
            }
        }
    }
    return VNONE;
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

// Whether value `v` of `b` is never null: a reference parameter (`ref_param`), the address a reference
// takes (`PTR_NONNULL`) or a slot's, as a pointer or an integer as wide (`ptrtoint`, `inttoptr`), through at
// most NONNULL_STEPS conversions.
fn nonnull(b: &Body, v: Value, ptr: u32) bool {
    let mut x = v;
    for _ in 0..NONNULL_STEPS {
        if ref_param(b, x) {
            return true;
        }
        if x == VNONE || (x & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let t = b.insts[x as usize];
        if t.op == O_PTRADD && (t.aux & PTR_NONNULL) != 0 || t.op == O_SLOTADDR {
            return true;
        }
        if t.op != O_PTRTOINT && t.op != O_INTTOPTR || type_bits(t.ty, ptr) != ptr * 8 || type_bits(b.type_of(t.a), ptr) != ptr * 8 {
            return false;
        }
        x = t.a;
    }
    return false;
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
            t[k as usize] = op >= O_ICONST && op <= O_INTTOPTR || op == O_PTRADD || op == O_SELECT || op == O_FMA || op == O_MULHU || op == O_MULHS || op == O_BSWAP || op == O_BITREV || op >= O_CLZ && op <= O_POPCNT || op == O_SPLAT || op == O_VCMP || op == O_VSEL || op == O_VUNZIP || op == O_HTOF || op == O_FTOH || op == O_FSQRT || op == O_VZIPLO || op == O_VZIPHI || op == O_VEXTRACT || op == O_VINSERT || op == O_VSUMW;
        }
    }
    return t;
}

// Whether pure `t` of `b` may run where the program would not run it: it has operands (a constant is
// `tidy`'s to place), cannot trap and gives a defined value (a shift amount below the width; no division
// or float to integer conversion). Checked arithmetic gives its wrapped value and its flag, defined both.
fn speculable(pk: &Package, b: &Body, t: Inst) bool {
    let op = t.op;
    if op <= O_SLOTADDR || op >= O_SDIV && op <= O_UREM || op == O_FPTOSI || op == O_FPTOUI {
        return false;
    }
    if op == O_SHL || op == O_LSHR || op == O_ASHR {
        let c = const_of(b, t.b);
        return c.is_some() && c.unwrap() < type_bits(t.ty, pk.ptr_bytes) as u64;
    }
    return true;
}

// Whether `t` of `b` is the address of a thread-local variable: the running thread's copy, which a call that
// writes memory may change (a task resumes on another thread).
const fn tls_addr(pk: &Package, b: &Body, t: Inst) bool {
    return t.op == O_SYMADDR && pk.syms[b.syms[t.a as usize] as usize].kind == SK_TLS;
}

// Whether value `v` is an operand of call `t` of `b` only as by-value aggregate arguments of at most
// `Package.arg_copy` bytes, which the backend copies: the callee never sees `v`.
fn arg_copied(pk: &Package, b: &Body, t: Inst, v: Value) bool {
    if t.op != O_CALL && t.op != O_CALLIND || t.op == O_CALLIND && t.a == v {
        return false;
    }
    let np = b.pool[t.b as usize];
    for k in 0..t.aux as u32 {
        if b.pool[(t.c + k) as usize] != v {
            continue;
        }
        let pt = if k < np {
            b.pool[(t.b + 3 + k) as usize]
        } else {
            0
        };
        if (pt & AGG) == 0 || b.pool[(pt & ~AGG) as usize] > pk.arg_copy {
            return false;
        }
    }
    return true;
}

// Whether value `v` is an operand of call `t` of `b` only as arguments a direct call reads alone: the
// callee writes no memory through those parameters and keeps no copy of them (`Sym.wargs`, `Sym.esc`), so
// the call reads what `v` points to and no code writes it through `v` after the call.
fn lends(pk: &Package, b: &Body, t: Inst, v: Value) bool {
    if t.op != O_CALL {
        return false;
    }
    let sy = pk.syms[b.syms[t.a as usize] as usize];
    for k in 0..t.aux as u32 {
        if b.pool[(t.c + k) as usize] == v && (k >= 64 || ((sy.wargs | sy.esc) >> k as u64 & 1) != 0) {
            return false;
        }
    }
    return true;
}

// Whether slot `s` is one `result_into`'s copy `t` and its copies `hops` pass the result through.
fn result_slot(b: &Body, t: Inst, hops: &Vector<u32>, s: u32) bool {
    if b.insts[t.b as usize].a == s {
        return true;
    }
    for h in 0..hops.len() {
        if b.insts[b.insts[hops[h] as usize].b as usize].a == s {
            return true;
        }
    }
    return false;
}

// Whether value `v` is the address of a slot `result_slot` names, as copy `t` or one of `hops` reads it.
fn result_addr(b: &Body, t: Inst, hops: &Vector<u32>, v: Value) bool {
    if v == t.b {
        return true;
    }
    for h in 0..hops.len() {
        if b.insts[hops[h] as usize].b == v {
            return true;
        }
    }
    return false;
}

// Whether `t` and `u` are the same instruction.
const fn same(t: Inst, u: Inst) bool {
    return t.op == u.op && t.ty == u.ty && t.aux == u.aux && t.a == u.a && t.b == u.b && t.c == u.c;
}

// The hash of pure instruction `t` of `b`, a wide constant's by its words.
fn value_hash(b: &Body, t: Inst) u64 {
    if t.op == O_PTRADD {
        // Of the address alone: one a reference takes (`PTR_NONNULL`) is the same value.
        return hash(Inst { op: t.op, ty: t.ty, aux: t.aux & PTR_SCALE, a: t.a, b: t.b, c: t.c });
    }
    if t.op != O_WCONST {
        return hash(t);
    }
    let mut h = mix(O_WCONST as u64 | t.ty as u64 << 8, t.b);
    for q in 0..t.b {
        h = mix(h, b.words[(t.a + q) as usize]);
    }
    return h;
}

// Comparison `t` of `b` that tests whether an addition or subtraction `s` carried or overflowed: a sum
// `s = x + y` below `x` (either order) carried, at or above it did not; the sign of `(x ^ s) & (y ^ s)`
// for `s = x + y`, or of `(x ^ y) & (x ^ s)` for `s = x - y` (operands in any order), compared with 0 is
// the signed overflow (`< 0`) or its absence (`>= 0`). `s`, whether signed, whether `t` is the flag's
// negation; VNONE when `t` is none of these (LLVM's `uadd.with.overflow` and `sadd.with.overflow`
// idioms).
fn flag_of(b: &Body, t: Inst) (Value, bool, bool) {
    let none = (VNONE, false, false);
    // Most comparisons are equalities.
    if t.op != O_ICMP || t.aux < C_SLT || t.aux > C_UGE {
        return none;
    }
    if t.aux < C_ULT {
        return signed_flag_of(b, t);
    }
    for side in 0..2 {
        let (s, x, code) = if side == 0 {
            (t.a, t.b, t.aux)
        } else {
            (t.b, t.a, mirror(t.aux))
        };
        if (code == C_ULT || code == C_UGE) && is_op(b, s, O_ADD) {
            let a = b.insts[s as usize];
            if is_int(a.ty) && a.ty != T_PTR && a.ty != T_I128 && (a.a == x || a.b == x) {
                return (s, false, code == C_UGE);
            }
        }
    }
    return none;
}

// `flag_of` for signed comparison `t`.
fn signed_flag_of(b: &Body, t: Inst) (Value, bool, bool) {
    let none = (VNONE, false, false);
    let (m, code) = if const_of(b, t.b) == Some(0u64) {
        (t.a, t.aux)
    } else if const_of(b, t.a) == Some(0u64) {
        (t.b, mirror(t.aux))
    } else {
        return none;
    };
    if code != C_SLT && code != C_SGE || !is_op(b, m, O_AND) {
        return none;
    }
    let mi = b.insts[m as usize];
    if !is_int(mi.ty) || mi.ty == T_PTR || mi.ty == T_I128 || !is_op(b, mi.a, O_XOR) || !is_op(b, mi.b, O_XOR) {
        return none;
    }
    let p = b.insts[mi.a as usize];
    let q = b.insts[mi.b as usize];
    // Each common operand `c` of the two `xor`s, with their other operands `po` and `qo`.
    for e in 0..4 {
        let (c, po) = if e < 2 {
            (p.a, p.b)
        } else {
            (p.b, p.a)
        };
        let (qc, qo) = if e % 2 == 0 {
            (q.a, q.b)
        } else {
            (q.b, q.a)
        };
        if c != qc {
            continue;
        }
        // `s` the common operand, `s = po + qo`; or `x` the common one, `s = x - y` the other.
        let mut s = VNONE;
        if is_op(b, c, O_ADD) && (b.insts[c as usize].a == po && b.insts[c as usize].b == qo || b.insts[c as usize].a == qo && b.insts[c as usize].b == po) {
            s = c;
        } else if is_op(b, po, O_SUB) && b.insts[po as usize].a == c && b.insts[po as usize].b == qo {
            s = po;
        } else if is_op(b, qo, O_SUB) && b.insts[qo as usize].a == c && b.insts[qo as usize].b == po {
            s = qo;
        }
        if s != VNONE && b.insts[s as usize].ty == mi.ty {
            return (s, true, code == C_SGE);
        }
    }
    return none;
}

// `bit_sources` follows at most BIT_DEPTH operations.
const BIT_DEPTH: u32 = 12;

// The value whose bits integer value `v` of `b` (of `bits` bits) moves, and per bit of `v` the bit of that
// value it holds (`src`, 0xFF: 0): through `or`s of values of disjoint bits, `and`s with constants, shifts
// by constants and byte swaps of one type, `depth` operations deep; else `v` itself. VNONE when the two
// sides of an `or` move different values or overlap.
fn bit_sources(b: &Body, v: Value, bits: u32, depth: u32, src: &mut [u8; 64]) Value {
    let t = if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
        Inst { op: O_ICONST, ty: T_NONE, aux: 0, a: VNONE, b: VNONE, c: VNONE }
    } else {
        b.insts[v as usize]
    };
    let c = if t.op == O_AND || t.op == O_SHL || t.op == O_LSHR {
        const_of(b, t.b)
    } else {
        Option::<u64>::None
    };
    let moves = t.op == O_OR || t.op == O_BSWAP || c.is_some() && (t.op == O_AND || c.unwrap() < bits as u64);
    if depth == 0 || !moves || b.type_of(v) != b.type_of(t.a) {
        for j in 0..bits {
            src[j as usize] = j as u8;
        }
        return v;
    }
    let mut x = [0xFFu8; 64];
    let base = bit_sources(b, t.a, bits, depth - 1, &mut x);
    if base == VNONE {
        return VNONE;
    }
    if t.op == O_OR {
        let mut y = [0xFFu8; 64];
        let other = bit_sources(b, t.b, bits, depth - 1, &mut y);
        if other != base {
            return VNONE;
        }
        for j in 0..bits as usize {
            if x[j] != 0xFF && y[j] != 0xFF {
                return VNONE;
            }
            src[j] = if x[j] != 0xFF {
                x[j]
            } else {
                y[j]
            };
        }
        return base;
    }
    for j in 0..bits {
        let s = if t.op == O_AND {
            if (c.unwrap() >> j as u64 & 1) != 0 {
                x[j as usize]
            } else {
                0xFF
            }
        } else if t.op == O_SHL {
            if j >= c.unwrap() as u32 {
                x[(j - c.unwrap() as u32) as usize]
            } else {
                0xFF
            }
        } else if t.op == O_LSHR {
            if j + c.unwrap() as u32 < bits {
                x[(j + c.unwrap() as u32) as usize]
            } else {
                0xFF
            }
        } else {
            // A byte swap: bit `j` comes from byte `bits / 8 - 1 - j / 8`, the same bit of that byte.
            x[((bits / 8 - 1 - j / 8) * 8 + j % 8) as usize]
        };
        src[j as usize] = s;
    }
    return base;
}

// Whether value `v` of `b` is a shift, a mask or a byte swap: what each side of a bit reversal's `or` is.
fn moves_bits(b: &Body, v: Value) bool {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let op = b.insts[v as usize].op;
    return op == O_SHL || op == O_LSHR || op == O_AND || op == O_BSWAP;
}

// `or` `i` of `b` whose bits are those of one value in reverse order (`bit_sources`; `u32::reverse_bits`'s
// swaps of halves, nibbles, pairs and bits): in place, that value's `bitrev` (`Package.bitrev`). Whether it
// did.
fn bit_reverse(pk: &Package, b: &mut Body, i: u32) bool {
    let t = b.insts[i as usize];
    if !is_int(t.ty) || t.ty == T_PTR || t.ty == T_I128 || !moves_bits(b, t.a) || !moves_bits(b, t.b) {
        return false;
    }
    let bits = type_bits(t.ty, pk.ptr_bytes);
    let mut src = [0xFFu8; 64];
    let x = bit_sources(b, i, bits, BIT_DEPTH, &mut src);
    if x == VNONE || x == i {
        return false;
    }
    for j in 0..bits {
        if src[j as usize] != (bits - 1 - j) as u8 {
            return false;
        }
    }
    b.insts[i as usize] = Inst { op: O_BITREV, ty: t.ty, aux: 0, a: x, b: VNONE, c: VNONE };
    return true;
}

// Whether value `v` of `b` is an instruction of operation `op`.
fn is_op(b: &Body, v: Value, op: u8) bool {
    return v != VNONE && (v & (VPARAM | VFLAG)) == 0 && b.insts[v as usize].op == op;
}

// The plain operation whose value checked operation `t` (`addo`, `subo`, `mulo`) gives; else `t`.
const fn as_plain(t: Inst) Inst {
    let op = if t.op == O_ADDO {
        O_ADD
    } else if t.op == O_SUBO {
        O_SUB
    } else if t.op == O_MULO {
        O_MUL
    } else {
        return t;
    };
    return Inst { op: op, ty: t.ty, aux: 0, a: t.a, b: t.b, c: VNONE };
}

// Whether pure instructions `t` and `u` of `b` compute one value: equal, or wide constants of equal words.
fn same_value(b: &Body, t: Inst, u: Inst) bool {
    if t.op == O_PTRADD && u.op == O_PTRADD {
        return same(
            Inst { op: t.op, ty: t.ty, aux: t.aux & PTR_SCALE, a: t.a, b: t.b, c: t.c },
            Inst { op: u.op, ty: u.ty, aux: u.aux & PTR_SCALE, a: u.a, b: u.b, c: u.c },
        );
    }
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

// The multiplier and shift of signed division by `d` at `bits` bits (Warren, Hacker's Delight, 10-1:
// `magic`), `d` at least 3 and no power of two: the multiplier `bits` wide, the smallest shift. The loop
// raises `p` from `bits` while `2^p / anc` is below `d - 2^p % d`, at most `bits` times: past that
// `2^p / anc` reaches `2^(bits - 1)`, above every `d`.
const fn smagic(d: u64, bits: u32) (u64, u32) {
    let one: u128 = 1;
    let two = one << (bits - 1) as usize;
    let ad = d as u128;
    let anc = two - 1 - two % ad;
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
    return ((q2 + 1 & wm) as u64, p - bits);
}

// The multiplier and shift that divide a `bits`-bit unsigned value by `d` (neither 0 nor a power of two)
// with a high product (Granlund and Montgomery 1994; Warren, Hacker's Delight, 10-8): `(m, s, false)` for
// `mulhu(n, m) >> s`, with the least `s` whose `m = ceil(2^(bits + s) / d)` fits in `bits` bits and errs
// by at most `2^s` (`m * d - 2^(bits + s) <= 2^s`, exact for every `n`); else `(m, l - 1, true)` for
// `((n - h) / 2 + h) >> (l - 1)`, `h = mulhu(n, m)`, `m = 2^bits * (2^l - d) / d + 1`, `l = ceil(log2 d)`.
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

// The value whose piece stored value `v` is, the piece's first byte and its byte count (`combine_stores`):
// `trunc x` is the low bytes of `x`, `trunc (lshr x, 8j)` the bytes from `j`. VNONE when `v` is neither.
fn stored_piece(b: &Body, v: Value, ptr: u32) (Value, u32, u32) {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_TRUNC || !is_int(b.insts[v as usize].ty) {
        return (VNONE, 0, 0);
    }
    let n = type_bytes(b.insts[v as usize].ty, ptr);
    let x = b.insts[v as usize].a;
    if (x & (VPARAM | VFLAG)) == 0 && x != VNONE && b.insts[x as usize].op == O_LSHR {
        let s = const_of(b, b.insts[x as usize].b);
        let xn = type_bytes(b.type_of(x), ptr) as u64;
        if s.is_some() && s.unwrap() % 8 == 0 && s.unwrap() / 8 + n as u64 <= xn {
            return (b.insts[x as usize].a, (s.unwrap() / 8) as u32, n);
        }
        return (VNONE, 0, 0);
    }
    return (x, 0, n);
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

// Interprocedural constant propagation by copies (GCC's IPA-CP): a function of `Sym.internal` whose
// direct calls from the own bodies of its unit all pass one constant (`O_ICONST`, `O_FCONST`) to a scalar
// parameter, but its own calls that pass that parameter on, gets a copy `<name>.cp<mask>` without those
// parameters: its new entry passes the constants to the old one. Those calls call the copy without them.
// The function stays for its other callers (its module's instances, which a build renders while the unit
// replays, and assembly): the decision reads only the unit's own bodies, which a build renders or replays
// together, so an incremental build makes the copies a full build makes. The copies go before the held
// bodies (`Package.held`).
fn specialize(pk: &mut Package) {
    let n = pk.bodies.len();
    let held = if pk.held.body == NONE {
        n
    } else {
        pk.held.body as usize
    };
    let ns = pk.syms.len();
    // Per body below `held`, its function's symbol; per symbol, the parameters every call passes one
    // constant (`mask`, after `seen`), those constants (`vals`, by `symbol << 6 | parameter`), and the
    // calls from other bodies.
    let mut owner = Vector::<u32>::new();
    fill(&mut owner, held, NONE);
    for s in 0..ns {
        let y = pk.syms[s];
        if y.kind == SK_FUNC && y.def != NONE && y.def as usize < held {
            owner[y.def as usize] = s as u32;
        }
    }
    let mut mask = Vector::<u64>::new();
    fill(&mut mask, ns, 0);
    let mut seen = Vector::<bool>::new();
    fill(&mut seen, ns, false);
    let mut ext = Vector::<u32>::new();
    fill(&mut ext, ns, 0);
    let mut vals = Map::<u64, Inst>::new();
    for k in 0..held {
        if owner[k] == NONE || !pk.syms[owner[k] as usize].own {
            continue;
        }
        let b = &pk.bodies[k];
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            if t.op != O_CALL {
                continue;
            }
            let s = b.syms[t.a as usize];
            let f = pk.syms[s as usize];
            if !f.internal || !f.own || f.def == NONE || f.def as usize >= held || f.unit != pk.syms[owner[k] as usize].unit {
                continue;
            }
            let e = &pk.bodies[f.def as usize];
            if !seen[s as usize] {
                seen[s as usize] = true;
                let np = e.blocks[0].param_len as u32;
                if e.sig != NONE && !e.naked && e.pool[e.sig as usize] == np && (e.pool[(e.sig + 1) as usize] & SIG_VARIADIC) == 0 {
                    mask[s as usize] = if np >= 64 {
                        ~0u64
                    } else {
                        (1u64 << np as u64) - 1
                    };
                }
            }
            if t.aux as u32 != e.blocks[0].param_len as u32 {
                mask[s as usize] = 0;
            }
            if k as u32 != f.def {
                ext[s as usize] += 1;
            }
            for q in 0..(t.aux as u32).min(64) {
                if (mask[s as usize] >> q as u64 & 1) == 0 {
                    continue;
                }
                let v = b.pool[(t.c + q) as usize];
                if k as u32 == f.def && v == b.param(0, q) {
                    continue; // passed on: the copy's own call passes the constant too
                }
                let key = s as u64 << 6 | q as u64;
                let mut c = iconst(T_I8, 0);
                let fits = const_inst(b, v, &mut c) && c.ty == e.params[(e.blocks[0].param_start + q) as usize] && (e.pool[(e.sig + 3 + q) as usize] & AGG) == 0;
                let same = switch vals.get(&key) {
                    Some(w) => same_const(*w, c),
                    None => true,
                };
                if fits && same {
                    vals.insert(key, c);
                } else {
                    mask[s as usize] &= ~(1u64 << q as u64);
                }
            }
        }
    }
    // The copies, in symbol order, each of its function's body as the lowering made it; per symbol its
    // copy's symbol (`copy`).
    let mut copy = Vector::<u32>::new();
    fill(&mut copy, ns, NONE);
    let mut made = Vector::<Body>::new();
    let mut made_sym = Vector::<u32>::new();
    let mut made_of = Vector::<u32>::new();
    for s in 0..ns {
        let m = mask[s];
        if m == 0 || ext[s] == 0 {
            continue;
        }
        // Each parameter of the mask passed one constant at least once.
        let mut all = true;
        for q in 0..64u32 {
            all = all && ((m >> q as u64 & 1) == 0 || vals.get(&(s as u64 << 6 | q as u64)).is_some());
        }
        if !all {
            continue;
        }
        let f = pk.syms[s];
        let name = format("{}.cp{}", pk.spell(f.name), m);
        let mut c = pk.find_symbol(&name);
        if c == NONE {
            c = pk.add_symbol(&name, SK_FUNC, SL_GLOBAL);
        } else if pk.syms[c as usize].kind != SK_FUNC || pk.syms[c as usize].def != NONE {
            continue;
        }
        let y = pk.syms.index_mut(c as usize);
        y.unit = f.unit;
        y.own = true;
        y.cold = f.cold;
        y.noinline = f.noinline;
        copy[s] = c;
        made.push(pk.bodies[f.def as usize].compact());
        made_sym.push(c);
        made_of.push(s as u32);
    }
    if made.len() == 0 {
        return;
    }
    // The calls that pass the constants call the copies, in the unit's own bodies and the copies; a copy's
    // own calls that pass the parameters on too.
    for k in 0..held + made.len() {
        let caller = if k < held {
            owner[k]
        } else {
            made_sym[k - held]
        };
        if caller == NONE || !pk.syms[caller as usize].own {
            continue;
        }
        let unit = pk.syms[caller as usize].unit;
        let b = if k < held {
            pk.bodies.index_mut(k)
        } else {
            made.index_mut(k - held)
        };
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            if t.op != O_CALL {
                continue;
            }
            let s = b.syms[t.a as usize];
            if copy[s as usize] == NONE || pk.syms[s as usize].unit != unit {
                continue;
            }
            let m = mask[s as usize];
            let mut ok = true;
            for q in 0..(t.aux as u32).min(64) {
                if (m >> q as u64 & 1) == 0 {
                    continue;
                }
                let v = b.pool[(t.c + q) as usize];
                let mut c = iconst(T_I8, 0);
                let own = k >= held && made_of[k - held] == s && v == b.param(0, q);
                ok = ok && (own || const_inst(b, v, &mut c) && (switch vals.get(&(s as u64 << 6 | q as u64)) {
                    Some(w) => same_const(*w, c),
                    None => false,
                }));
            }
            if ok {
                retarget(b, i as u32, copy[s as usize], m);
            }
        }
    }
    for j in 0..made.len() {
        let s = made_of[j];
        let mut cs = Vector::<Inst>::with_capacity(64);
        for q in 0..64u32 {
            cs.push(
                switch vals.get(&(s as u64 << 6 | q as u64)) {
                    Some(w) => *w,
                    None => iconst(T_I8, 0),
                },
            );
        }
        drop_params(made.index_mut(j), mask[s as usize], &cs);
    }
    // Before the held bodies: theirs move up.
    let k0 = made.len() as u32;
    if pk.held.body != NONE {
        for s in 0..pk.syms.len() {
            let y = pk.syms.index_mut(s);
            if y.kind == SK_FUNC && y.def != NONE && y.def >= pk.held.body {
                y.def += k0;
            }
        }
        pk.held.body += k0;
    }
    let mut hb = Vector::<Body>::with_capacity(n - held);
    while pk.bodies.len() > held {
        hb.push(pk.bodies.pop().unwrap());
    }
    for j in 0..made.len() {
        pk.syms.index_mut(made_sym[j] as usize).def = pk.bodies.len() as u32;
        pk.bodies.push(replace(made.index_mut(j), Body::new()));
    }
    while let Some(b) = hb.pop() {
        pk.bodies.push(b);
    }
}

// Into `out` the constant instruction value `v` of `b` is, when it is a scalar one of at most 64 bits.
fn const_inst(b: &Body, v: Value, out: &mut Inst) bool {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let t = b.insts[v as usize];
    if t.op != O_ICONST && t.op != O_FCONST || t.ty == T_I128 || is_vec(t.ty) {
        return false;
    }
    *out = Inst { op: t.op, ty: t.ty, aux: 0, a: t.a, b: t.b, c: VNONE };
    return true;
}

// Whether constant instructions `x` and `y` (`const_inst`) are one value of one type.
const fn same_const(x: Inst, y: Inst) bool {
    return x.op == y.op && x.ty == y.ty && x.a == y.a && x.b == y.b;
}

// Make call `i` of `b` a call of symbol `sym` without the arguments of `mask` (`specialize`).
fn retarget(b: &mut Body, i: u32, sym: u32, mask: u64) {
    let t = b.insts[i as usize];
    let mut ls = NONE;
    for x in 0..b.syms.len() {
        if b.syms[x] == sym {
            ls = x as u32;
        }
    }
    if ls == NONE {
        b.syms.push(sym);
        ls = b.syms.len() as u32 - 1;
    }
    let mut args = Vector::<Value>::with_capacity(t.aux as usize);
    let mut ps = Vector::<u32>::with_capacity(t.aux as usize);
    for q in 0..t.aux as u32 {
        if q >= 64 || (mask >> q as u64 & 1) == 0 {
            args.push(b.pool[(t.c + q) as usize]);
            ps.push(b.pool[(t.b + 3 + q) as usize]);
        }
    }
    let gone = t.aux as u32 - args.len() as u32;
    let fl = b.pool[(t.b + 1) as usize];
    let ret = b.pool[(t.b + 2) as usize];
    let sg = b.signature(&ps, (fl & ~SIG_VARIADIC) - gone, false, ret);
    let c = b.pool_list(&args);
    let u = b.insts.index_mut(i as usize);
    u.a = ls;
    u.aux = args.len() as u8;
    u.b = sg;
    u.c = c;
}

// Drop the entry parameters of `b` that `mask` names (`specialize`): a new entry without them passes
// their constants `cs` (by parameter) and its own parameters to the old one, which the edges into the
// entry enter too, and the signature, the reference facts and the `bool` bits lose them.
fn drop_params(b: &mut Body, mask: u64, cs: &Vector<Inst>) {
    let e = b.blocks[0];
    let np = e.param_len as u32;
    let nb = b.blocks.len() as u32;
    let mut types = Vector::<u8>::with_capacity(np as usize);
    let mut ps = Vector::<u32>::with_capacity(np as usize);
    for q in 0..np {
        if q >= 64 || (mask >> q as u64 & 1) == 0 {
            types.push(b.params[(e.param_start + q) as usize]);
            ps.push(b.pool[(b.sig + 3 + q) as usize]);
        }
    }
    let gone = np - types.len() as u32;
    let ne = b.add_block(&types);
    let at = b.locs[e.start as usize];
    b.begin(ne);
    let mut args = Vector::<Value>::with_capacity(np as usize);
    let mut kept: u32 = 0;
    for q in 0..np {
        if q < 64 && (mask >> q as u64 & 1) != 0 {
            args.push(b.emit(cs[q as usize], at));
        } else {
            args.push(b.param(ne, kept));
            kept += 1;
        }
    }
    let _ = b.emit(jump(b.edge(ne, &args)), at);
    if b.inl.len() != 0 {
        for _ in 0..gone + 1 {
            b.inl.push(0);
        }
    }
    // Block `ne` is the old entry once the two swap.
    let mut es = Vector::<u32>::new();
    for k in 0..nb {
        let bk = b.blocks[k as usize];
        if bk.len == 0 {
            continue;
        }
        b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut es);
        for x in 0..es.len() {
            if b.pool[es[x] as usize] == 0 {
                b.pool[es[x] as usize] = ne;
            }
        }
    }
    let old = b.blocks[0];
    b.blocks.set(0, b.blocks[ne as usize]);
    b.blocks.set(ne as usize, old);
    let fl = b.pool[(b.sig + 1) as usize];
    let ret = b.pool[(b.sig + 2) as usize];
    b.sig = b.signature(&ps, (fl & ~SIG_VARIADIC) - gone, false, ret);
    // Kept parameter `q`'s new position.
    let below = |q: u64| q - if q >= 64 {
        mask.count_ones() as u64
    } else {
        (mask & (1u64 << q) - 1).count_ones() as u64
    };
    if b.refs.len() != 0 {
        let mut rs = Vector::<u32>::with_capacity(b.refs.len());
        for q in 0..b.refs.len() {
            if q >= 64 || (mask >> q as u64 & 1) == 0 {
                rs.push(b.refs[q]);
            }
        }
        b.refs = rs;
    }
    let mut os = Vector::<u64>::with_capacity(b.owned.len());
    for x in 0..b.owned.len() {
        let p = b.owned[x] >> 32;
        if p >= 64 || (mask >> p & 1) == 0 {
            os.push(below(p) << 32 | b.owned[x] & 0xFFFFFFFF);
        }
    }
    b.owned = os;
    let mut bs: u64 = 0;
    for q in 0..64u64 {
        if (mask >> q & 1) == 0 && (b.bools >> q & 1) != 0 {
            bs |= 1u64 << below(q);
        }
    }
    b.bools = bs;
}

// Whether every argument of edge `e` of `b` is an argument of edge `o` too.
fn args_among(b: &Body, e: u32, o: u32) bool {
    for q in 0..b.edge_nargs(e) {
        let mut found = false;
        for j in 0..b.edge_nargs(o) {
            found = found || b.edge_arg(o, j) == b.edge_arg(e, q);
        }
        if !found {
            return false;
        }
    }
    return true;
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

// The step of counter parameter `q` that `v` (what a loop passes it back) takes: 1 for `q + 1`, 2 for `q - 1`
// (or `q + -1`), else 0.
fn counter_step(b: &Body, v: Value, q: Value) u32 {
    if !is_op(b, v, O_ADD) && !is_op(b, v, O_SUB) || b.insts[v as usize].a != q {
        return 0;
    }
    let t = b.insts[v as usize];
    let c = const_of(b, t.b);
    if c.is_none() {
        return 0;
    }
    let m = width_mask(t.ty, 8);
    let k = c.unwrap() & m;
    return if t.op == O_ADD && k == 1 || t.op == O_SUB && k == m {
        1
    } else if t.op == O_SUB && k == 1 || t.op == O_ADD && k == m {
        2
    } else {
        0
    };
}

// The constant positive byte step of pointer parameter `q` that `v` (what a loop passes it back) takes,
// `ptradd q, k * scale + c` of a constant `k` or none (the step up to PTR_SCALE); else 0.
fn ptr_step(b: &Body, v: Value, q: Value) u32 {
    if !is_op(b, v, O_PTRADD) || b.insts[v as usize].a != q {
        return 0;
    }
    let t = b.insts[v as usize];
    let mut s = (t.c as i32) as i64;
    if t.b != VNONE {
        let k = const_of(b, t.b);
        if k.is_none() || k.unwrap() > 0xFFFF {
            return 0;
        }
        s += k.unwrap() as i64 * scale_of(t) as i64;
    }
    return if s > 0 && s <= PTR_SCALE as i64 {
        s as u32
    } else {
        0
    };
}

// The representative of parameter `q`'s set in union-find `uf`, its path halved (`param_cycles`).
fn set_of(uf: &mut Vector<u32>, q: u32) u32 {
    let mut x = q;
    // Each step halves the path: at most its length.
    while uf[x as usize] != x {
        let up = uf[uf[x as usize] as usize];
        uf[x as usize] = up;
        x = up;
    }
    return x;
}

// Whether values `x` and `y` of `b` are integer constants of one type and value.
fn same_iconst(b: &Body, x: Value, y: Value) bool {
    if (x & (VPARAM | VFLAG)) != 0 || (y & (VPARAM | VFLAG)) != 0 || x == VNONE || y == VNONE {
        return false;
    }
    let (s, u) = (b.insts[x as usize], b.insts[y as usize]);
    return s.op == O_ICONST && u.op == O_ICONST && s.ty == u.ty && s.a == u.a && s.b == u.b;
}

// Whether value `v` of `b` is defined outside block `k`: not one of its instructions or parameters.
fn outside(b: &Body, v: Value, k: u32) bool {
    if v == VNONE || (v & VFLAG) != 0 {
        return false;
    }
    let bk = b.blocks[k as usize];
    if (v & VPARAM) != 0 {
        let q = v & ~VPARAM;
        return q < bk.param_start || q >= bk.param_start + bk.param_len as u32;
    }
    return !in_block(b, v, k);
}

// Whether instruction value `v` of `b` is one of block `k`'s.
fn in_block(b: &Body, v: Value, k: u32) bool {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let bk = b.blocks[k as usize];
    return v >= bk.start && v < bk.start + bk.len;
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
