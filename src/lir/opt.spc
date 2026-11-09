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
import std::parallel::runtime as prt;
import sc_runtime;
import lir::inline as il;
import lir::promote as pr;
import lir::loops as lu;
import lir::slp as sl;
import lir::pairs as pa;
import lir::wide as wd;
import lir::print as lp;
import utils::par as par;
import lir::switches as sws;
import stdlib;
import std::platform::clock as pclock;
import ast::ast as ast;

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
// A lower bound's key in the bounds' table (`ub`, LOG_UB): the value's with this bit.
const LB_KEY: u64 = 1u64 << 40;
// The keys of the two values a value is known to be at most (`Opt::note_le`), in the bounds' table.
const UP_KEY: u64 = 1u64 << 41;
const UP2_KEY: u64 = 1u64 << 42;
// The key of a value known to be at least 0 as a signed value (`Opt::param_bounds`), in the bounds' table.
const NN_KEY: u64 = 1u64 << 43;
// `Opt::edge_value` follows at most THROUGH_MAX edges.
const THROUGH_MAX: u32 = 4;
// `ub` key of a value that is nonzero (`param_bounds`: a header parameter every edge in proves nonzero).
const NZ_KEY: u64 = 1u64 << 44;
// The keys of a value's signed bounds from below and from above (`Opt::srange`), in the bounds' table: a
// constant's value shifted left by 2, plus 1 + the offset (-1, 0 or 1) the bound adds to it (`signed_bound`).
const SLO_KEY: u64 = 1u64 << 45;
const SHI_KEY: u64 = 1u64 << 46;
// The key of a value from before a loop that a counter down from it stays at most as a signed value
// (`Opt::signed_counter`), in the bounds' table.
const SHV_KEY: u64 = 1u64 << 47;
// The key of a value the branches in scope keep other than the value (`Opt::order_facts`), in the bounds' table.
const NE_KEY: u64 = 1u64 << 48;
// `Opt::overwrite` keeps at most PEND_MAX stores, and a fill of at most FILL_MAX bytes.
const PEND_MAX: u32 = 8;
const FILL_MAX: u32 = 512;
// `Opt::ubound` follows at most UB_DEPTH instructions.
const UB_DEPTH: u32 = 4;
// `Opt::room` follows at most ROOM_DEPTH facts and differences.
const ROOM_DEPTH: u32 = 2;
// An if-conversion makes at most MAX_SELECTS selects; the values an order fact's bound is at most are
// followed MIN_DEPTH deep (`Opt::upper_parts`).
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
// `memcmp_eq` expands counts of at most MEMCMP_MAX bytes (MEMCMP_EQ_MAX for an equality), in at most
// MEMCMP_LOADS loads a side (MEMCMP_EQ_LOADS).
const MEMCMP_MAX: u64 = 32;
const MEMCMP_LOADS: u32 = 4;
const MEMCMP_EQ_MAX: u64 = 64;
const MEMCMP_EQ_LOADS: u32 = 8;
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
// `Opt::join_out` keeps the facts of a join block's first JOIN_MAX parameters, of blocks with at most
// JOIN_PREDS edges in.
const JOIN_MAX: u32 = 8;
const JOIN_PREDS: u32 = 8;
// `Opt.jat` of a join block whose edges a rewrite changed during the walk: no facts.
const JOIN_BAD: u32 = 0xFFFFFFFE;
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
// The depth of the sums `inv_val` reads as invariant.
const INV_DEPTH: u32 = 3;
// The instructions of each side `hoist_common` compares.
const COMMON_MAX: u32 = 24;
const THREAD_DEPTH: u32 = 4;
// `cond_fact` and `eq_const` read conditions joined by `and` and `or` this many levels deep: a chain of
// conditional comparisons (`codegen::live`'s, 8).
const CCMP_DEPTH: u32 = 8;
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
const K_SLOTS: u8 = 5; // `slot_writes`

/// The optimizer's scratch, reused from body to body.
pub(package) struct Opt {
    // The control flow graph: per block, its successors and predecessors as ranges of one list each.
    succ_at: Vector<u32>,
    succs: Vector<u32>,
    pred_at: Vector<u32>,
    preds: Vector<u32>,
    edges: Vector<u32>,
    // Per instruction of the body `memory` saw, the slots (bit: slot index, the first 64) whose address may
    // have escaped before it on some path (`slot_escapes`); per block, those on its entry.
    sl_at: Vector<u64>,
    sl_in: Vector<u64>,
    // `slot_escapes`' scratch: per block the escapes on its exit and those its instructions add, the
    // worklist and its members.
    sl_bout: Vector<u64>,
    sl_bgen: Vector<u64>,
    sl_work: Vector<u32>,
    sl_queued: Vector<bool>,
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
    sroot: Vector<Value>, // per scope class, the value its roots are constant offsets from (`root_bases`)
    smulti: Vector<bool>, // per scope class, whether its roots are offsets from two values
    site_cls: Vector<u64>, // per `lines` entry, the scope classes of its inline site (`scope_seeds`)
    imem: Vector<u64>,
    sbits: u64,
    fbits: u64, // the classes of allocations' blocks (`fresh_seeds`)
    obits: u64, // the classes of owned buffers (`owned_seeds`)
    cnext: u32, // the first class index past the parameters' and the scopes'
    fcall: Vector<u32>, // per class index, the allocation whose block it is (`fresh_seeds`)
    oparam: Vector<u32>, // per class index, the parameter whose owned buffer it is (`owned_seeds`)
    ooff: Vector<u32>, // per class index, the owned field's offset in the parameter's referent
    oload: Vector<u32>, // per instruction, the class index of the owned field it loads (NONE: none)
    okeys: Vector<u64>, // the owned fields the body loads a pointer from, sorted (`owned_seeds`)
    sroots: Vector<u64>, // the scopes' roots and class indices, `root << 32 | index`, sorted (`scope_seeds`)
    oder: Vector<u32>, // per instruction, the parameter its address arithmetic starts from (`owned_seeds`)
    ooffs: Vector<i64>, // per instruction, that arithmetic's constant offset (OFF_ANY: not constant)
    ipin: Vector<bool>,
    ppin: Vector<bool>,
    // The work of a `class_flow` round, built once per `classes`: in reverse postorder, the address
    // arithmetic and selects of each reached block, then its terminator with CF_EDGES when it passes values.
    cf_work: Vector<u32>,
    acls: Vector<u8>,
    aobj: Vector<u32>, // per load or store, the object it accesses (`object`)
    frz: Vector<bool>, // per instruction, a load of a read-only referent (`frozen`)
    frz_ptr: Vector<bool>, // `frozen`'s per instruction, whether its value points into a read-only referent
    mark: Vector<u32>,
    hdr: Vector<bool>, // per block, whether it heads a loop (`thread`)
    preader: Vector<u32>, // per block parameter, the block outside its own that reads it (`thread`)
    pcount: Vector<u8>, // per block parameter, how many instructions read it, up to 2 (`thread`)
    icount: Vector<u8>, // per instruction, how many instructions read it, up to 2 (`readers`)
    ireader: Vector<u32>, // per instruction, the block outside its own that reads it (`thread`)
    in_or: Vector<bool>, // per instruction, whether an `or` reads it (`readers`, for `bit_set`)
    counted: bool, // `icount` and `in_or` are those of the operand tables (`readers`)
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
    // The largest aggregate parameter the target passes in registers: at most 16 bytes, at most
    // `Package.arg_copy` (wasm32 none, Microsoft x64 8 bytes).
    aggregs: u32,
    aggload: [u32; 64], // per such chunk, its load this walk made at the entry's start (`agg_chunk`), NONE
    rslot: Vector<u32>, // per slot, the one call whose aggregate result it holds, which only loads read, else NONE
    rcall: bool, // a call has an aggregate result of at most 16 bytes (`operands`; `result_slots`)
    rload: Vector<Value>, // per slot and 8-byte chunk (2 per slot), its load after that call (`res_chunk`), NONE
    made: Map<u64, u32>, // a made constant's hash to the constant
    moved: Vector<bool>,
    nofx: Vector<bool>, // per instruction, a call that writes no memory and comes back: it goes when unused
    hoisted: Vector<u64>, // block << 32 | instruction, in the order they moved
    pnew: Vector<bool>, // per block, a preheader `preheaders` made
    ptypes: Vector<u8>, // `preheaders`: a new preheader's parameter types
    pargs: Vector<Value>, // `preheaders`: its jump's arguments
    touched: Vector<bool>, // per block, one `promote_places` changed: a preheader or a block of a loop
    /// `place_of`'s guard of a place the loop reaches on its first pass only after tests (`guarded`): per test,
    /// its condition, the block it leaves to, and whether the loop goes on when it holds (bit 0) and the
    /// guard compares the entry values again (bit 1, `entry_cmp`); empty for none.
    gchain: Vector<u32>,
    gcmp: u32, // the header's comparison the guard repeats on the entry values; NONE: no guard
    gout: u32, // the header's edge out of the loop
    gstay: bool, // whether the header stays in the loop when its comparison holds
    // `reassociate`'s scratch: per value its uses and its one user (NONE: an edge's or none), a chain's
    // nodes and leaves, the partial sums (depth << 32 | value).
    rcount: Vector<u32>,
    ruser: Vector<u32>,
    rnodes: Vector<u32>,
    rleaves: Vector<u32>,
    rsums: Vector<u64>,
    pre: Vector<u64>, // instruction << 32 | an instruction the walk made to run right before it, in order
    unbiased: Map<u32, u32>, // per indexed address with an offset, the address without it (`visit`)
    merged: bool, // the last rebuild left a block one edge enters that several entered at the walk
    selected: bool, // the last walk made selects (`diamond`), which no walk simplified
    // The last walk folded a value its readers saw before (`null_test`, `merge_exits`), or made instructions
    // it did not visit (`copysign_bits`).
    refold: bool,
    // The walks before a promotion leave a copy of 1, 2, 4 or 8 bytes into or out of a slot that does not
    // escape a copy (`slot_copy`): the promotion makes it loads and stores of the slot's fields, in their
    // types, where an integer of the copy's size would pack the fields. `waited`: such a copy stayed.
    wait_copies: bool,
    waited: bool,
    rethru: bool, // `thread` made a jump a return (`ret_folded`)
    // The last walk dropped a store in a loop, whose loads may leave it now, or one before a call, whose
    // loads may move past it (`sink_load`).
    unstored: bool,
    // The walk gave a call's argument the source of the copy it took (`copied_args`): a change of the call's
    // arguments in the pool, which its instruction does not show.
    rewrote: bool,
    pre_at: Vector<u32>, // the rebuild's ranges of `pre_list` per instruction
    // `param_cycles`' scratch, per parameter: its set (union-find), the set's one outside value, whether
    // the set has more than one.
    tdirty: Vector<u32>, // the instructions but terminators `thread` rewrote (`param_cmp`)
    pc_uf: Vector<u32>,
    pc_ext: Vector<Value>,
    pc_bad: Vector<bool>,
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
    // Per depth in the dominator tree, `recent` at the end of the walk's block there: RECENT_MAX entries, NONE
    // past its count. Only a block's children read it, while the walk is below the block.
    end_recent: Vector<u32>,
    state: u32, // the current memory state of the visited access (its tag's)
    prior: u32, // the memory state of the visited access's tag before it
    // The private and the untagged memory states before the visited instruction: no write between two
    // instructions when both are the same.
    pprior: u32,
    tprior: u32,
    tbefore: [u32; TBAA_TAGS], // the type tags' states before the walk's current write (`carry`)
    tstate: [u32; TBAA_TAGS], // per type tag, the current memory state of its accesses
    tags: Vector<u16>, // per loop header, the type tags its blocks write (`block_writes`)
    // Private memory (`slot_writes`): the slots, then the aggregate arguments (each a copy the callee
    // owns). Per instruction the one its address value points into (NONE: none) and the offset; per one
    // whether its address escapes; the writes, by place (`wat`).
    sbase: Vector<u32>,
    soff: Vector<i64>,
    sesc: Vector<bool>,
    wr: Vector<SlotWrite>,
    wat: Vector<u32>,
    wl: Vector<SlotWrite>,
    end_state: Vector<u32>, // per depth (as `end_recent`) and type tag, the state at the block's end
    pstate: u32, // the current memory state of the private slots' accesses (`privates`)
    end_pstate: Vector<u32>, // per depth (as `end_recent`), `pstate` at the block's end
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
    jat: Vector<u32>, // per block, its parameters' first `JoinFact` in `jfacts` (NONE: none yet)
    jcnt: Vector<u32>, // per block, the edges into it whose facts `jfacts` holds
    jfacts: Vector<JoinFact>,
    rstack: Vector<u32>,
    stack: Vector<u64>,
    pend: Vector<u32>, // the walk's block's stores no instruction since may read (`overwrite`)
    fillc: Vector<u64>, // the bytes of the fill in `pend` (at most one) that later stores wrote
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
    // Promotion of private slots (`lir::promote`) and the body it builds; `rebuild` builds its instructions,
    // locations, inline marks and blocks in that body's tables too.
    prom: pr::Promoter,
    pbody: Body,
    cps: PoolScratch, // `Body::compact_pool`'s
    // The spare a snapshot of the body is copied into (`Run::job`, `slp`): the one a body keeps leaves it
    // empty.
    snap: Body,
    pub(package) unr: lu::LoopOpt,
    slp: sl::Slp,
    pairs: pa::Pairs,
    wide: wd::Wide,
    wgt: Vector<u64>, // per block, the weight of an instruction there (`weigh`)
    // The analyses that describe the body at hand (`K_*`, `tables`); a change of the body drops them.
    kept: u8,
    // Per instruction, its operands, then a terminator's edges' arguments: `ops[ops_at[i]..ops_at[i + 1]]`,
    // the arguments from `ops_arg[i]`; per entry, the block parameter an argument passes to (`ops_dst`,
    // 0 for an operand, which none reads; `graph`).
    ops_at: Vector<u32>,
    ops_arg: Vector<u32>,
    ops: Vector<Value>,
    ops_dst: Vector<u32>,
    // Per loop header, its blocks in `lbs` as start << 32 | end, in block order (`nest`).
    lb_at: Vector<u64>,
    lbs: Vector<u32>,
    lsort: Vector<u32>,
    // Per block in a loop, its writes, found once (`memory`, `block_writes`): classes, tags, private
    // writes, and the other writes' classes and the stores (`bst[bst_at[k]..bst_at[k + 1]]`).
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
    phd: Vector<u32>, // per block `preheaders` made, the header it enters
    // The operand lists before the last `splice_ops` (`splices` of them), and the tables before the last
    // `preheaders` that kept them (`saved`: the vectors `save_tables` names, in its order; `saved_lb`:
    // `lb_at`; the lengths of `blk_of` and `pblock`; the splice whose spares hold its operand lists).
    xat: Vector<u32>,
    xarg: Vector<u32>,
    xops: Vector<Value>,
    xdst: Vector<u32>,
    splices: u32,
    saved: Vector<Vector<u32>>,
    saved_lb: Vector<u64>,
    saved_ni: u32,
    saved_np: u32,
    saved_splice: u32,
    saved_on: bool,
    promote: bool, // SC_LIR_PROMOTE=0 promotes nothing (a debugging aid)
    // The run whose jobs share the parts a large body's passes use (`Run::proms`, `SHARE_MIN`), null outside
    // one.
    shared: *const Run,
}

/// What `optimize` does: the inline budget, and the loop transforms' budgets.
pub(package) struct Config {
    pub(package) inline: il::Budget,
    pub(package) loops: lu::Budgets,
    pub(package) jobs: u32, // the build's workers: 1 runs every pass on the calling thread
}

extend Config as Copy {}

// A write into private memory whose address does not escape: bytes `off` to `end` of `slot` (`Opt.sbase`),
// by store `inst` in block `blk` (NONE: a copy or a fill), or by copy `copy` (NONE: a store or a fill).
struct SlotWrite {
    pub(package) slot: u32,
    pub(package) off: i64,
    pub(package) end: i64,
    pub(package) inst: u32,
    pub(package) blk: u32,
    pub(package) copy: u32,
}

extend SlotWrite as Copy {}

// A memory place in a memory state, and the value it holds.
struct Place {
    pub(package) addr: u32,
    pub(package) off: u32,
    pub(package) ty: u8,
    pub(package) state: u32,
    pub(package) val: u32,
    pub(package) mem: u64, // the scopes' classes whose copy holds the access that made it (`Opt::member`)
}

extend Place as Copy {}

// What the edges into a join block recorded so far give one of its integer parameters (`Opt::join_out`): its
// unsigned range `[lo, hi]`, its signed range `[slo, shi]` where `sk`, and up to two values `w` from before the
// join it is at most (below where `ws`), `nw` of them (NONE: no edge but constants 0 yet, which any `w` is at
// least); `sw`, a value from before the join it is at most as a signed one (NONE: none yet; VNONE: none);
// `dead`: an edge gave nothing.
struct JoinFact {
    pub(package) lo: u64,
    pub(package) hi: u64,
    pub(package) slo: i64,
    pub(package) shi: i64,
    pub(package) sk: bool,
    pub(package) w: [Value; 2],
    pub(package) ws: [bool; 2],
    pub(package) nw: u32,
    pub(package) sw: Value,
    pub(package) dead: bool,
}

extend JoinFact as Copy {}

extend Opt {
    pub(package) fn new() Opt {
        return Opt {
            succ_at: Vector::<u32>::new(),
            succs: Vector::<u32>::new(),
            pred_at: Vector::<u32>::new(),
            sl_at: Vector::<u64>::new(),
            sl_in: Vector::<u64>::new(),
            sl_bout: Vector::<u64>::new(),
            sl_bgen: Vector::<u64>::new(),
            sl_work: Vector::<u32>::new(),
            sl_queued: Vector::<bool>::new(),
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
            sroot: Vector::<Value>::new(),
            smulti: Vector::<bool>::new(),
            site_cls: Vector::<u64>::new(),
            imem: Vector::<u64>::new(),
            sbits: 0,
            fbits: 0,
            obits: 0,
            cnext: 0,
            fcall: Vector::<u32>::new(),
            oparam: Vector::<u32>::new(),
            ooff: Vector::<u32>::new(),
            oload: Vector::<u32>::new(),
            okeys: Vector::<u64>::new(),
            sroots: Vector::<u64>::new(),
            oder: Vector::<u32>::new(),
            ooffs: Vector::<i64>::new(),
            ipin: Vector::<bool>::new(),
            ppin: Vector::<bool>::new(),
            cf_work: Vector::<u32>::new(),
            acls: Vector::<u8>::new(),
            aobj: Vector::<u32>::new(),
            frz: Vector::<bool>::new(),
            frz_ptr: Vector::<bool>::new(),
            mark: Vector::<u32>::new(),
            hdr: Vector::<bool>::new(),
            preader: Vector::<u32>::new(),
            pcount: Vector::<u8>::new(),
            icount: Vector::<u8>::new(),
            ireader: Vector::<u32>::new(),
            in_or: Vector::<bool>::new(),
            counted: false,
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
            ptypes: Vector::<u8>::new(),
            pargs: Vector::<Value>::new(),
            touched: Vector::<bool>::new(),
            gchain: Vector::<u32>::new(),
            gcmp: NONE,
            gout: NONE,
            gstay: false,
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
            wait_copies: false,
            waited: false,
            rethru: false,
            unstored: false,
            rewrote: false,
            pre_at: Vector::<u32>::new(),
            tdirty: Vector::<u32>::new(),
            pc_uf: Vector::<u32>::new(),
            pc_ext: Vector::<Value>::new(),
            pc_bad: Vector::<bool>::new(),
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
            tbefore: [0u32; TBAA_TAGS],
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
            jat: Vector::<u32>::new(),
            jcnt: Vector::<u32>::new(),
            jfacts: Vector::<JoinFact>::new(),
            rstack: Vector::<u32>::new(),
            tstate: [0u32; TBAA_TAGS],
            tags: Vector::<u16>::new(),
            stack: Vector::<u64>::new(),
            pend: Vector::<u32>::new(),
            fillc: Vector::<u64>::new(),
            work: Vector::<u32>::new(),
            bmap: Vector::<u32>::new(),
            in_at: Vector::<u32>::new(),
            ins: Vector::<u32>::new(),
            insrc: Vector::<u32>::new(),
            nxt: Vector::<u32>::new(),
            sread: Vector::<bool>::new(),
            sused: Vector::<u32>::new(),
            done_pool: Vector::<bool>::new(),
            prepl: Vector::<u32>::new(),
            frepl: Vector::<u32>::new(),
            extra: Vector::<u32>::new(),
            aggp: 0,
            aggint: 0,
            aggregs: 0,
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
            prom: pr::Promoter::new(),
            pbody: Body::new(),
            cps: PoolScratch::new(),
            snap: Body::empty(),
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
            phd: Vector::<u32>::new(),
            xat: Vector::<u32>::new(),
            xarg: Vector::<u32>::new(),
            xops: Vector::<Value>::new(),
            xdst: Vector::<u32>::new(),
            saved: Vector::<Vector<u32>>::new(),
            saved_lb: Vector::<u64>::new(),
            splices: 0,
            saved_ni: 0,
            saved_np: 0,
            saved_splice: 0,
            saved_on: false,
            promote: !stdlib::env_is("SC_LIR_PROMOTE", "0"),
            shared: null,
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
        let it = int_type(pk.ptr_bytes);
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
        // Only loop headers merge (`nest`'s blocks: none without a loop).
        self.tables(pk, b, K_NEST);
        if self.lbs.len() == 0 {
            return false;
        }
        self.tables(pk, b, K_MEM);
        self.fresh(b);
        self.pure.clear_keeping(KEEP_SLOTS);
        self.made.clear_keeping(KEEP_SLOTS);
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
        // Only loop headers sink (`nest`'s blocks: none without a loop). The rebuild reads the slots the
        // memory analysis finds read (`dead_store`).
        self.tables(pk, b, K_NEST);
        if self.lbs.len() == 0 {
            return false;
        }
        self.tables(pk, b, K_MEM);
        let nb = b.blocks.len();
        let ni = b.insts.len();
        let mut any = false;
        // The reads of each instruction (its operands and edge arguments, `ops`): in its own block, and the
        // one other block.
        fill(&mut self.sn, ni, 0);
        fill(&mut self.sb, ni, NONE);
        for k in 0..nb {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                for u in self.ops_at[i as usize]..self.ops_at[i as usize + 1] {
                    let v = self.ops[u as usize];
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
        return any;
    }

    /// `lu::pointer_ivs` on body `b` of package `pk`, then the rebuild, which drops what it left unused (the
    /// addresses its accesses no longer read, a counter whose exit test went) and renumbers the body.
    /// Whether it changed it.
    pub(package) fn pointer_ivs(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if !lu::pointer_ivs(b, &mut self.mark) {
            return false;
        }
        self.renumber(pk, b);
        return true;
    }

    /// `lu::pointer_counts` on body `b` of package `pk` (loops that step a pointer and no counter take one),
    /// then the rebuild, which drops the pointers the loops no longer read. Whether it changed it.
    pub(package) fn pointer_counts(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if b.naked {
            return false;
        }
        self.tables(pk, b, K_GRAPH);
        if !lu::pointer_counts(b, pk.ptr_bytes, &self.pred_at, &self.preds, &mut self.mark) {
            return false;
        }
        self.renumber(pk, b);
        return true;
    }

    // The rebuild of a body a transform outside the walk changed, which reads the block map alone (`fresh`).
    fn renumber(self: &mut Self, pk: &Package, b: &mut Body) {
        self.forget();
        self.tables(pk, b, K_GRAPH);
        self.fresh(b);
        self.rebuild(b);
        self.forget();
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
        if have < K_MEM && want >= K_MEM {
            self.memory(pk, b);
        }
        if want >= K_SLOTS {
            self.slot_writes(pk, b);
        }
        self.kept = want;
    }

    /// Optimize body `b` of package `pk`; with `force` the rebuild runs though nothing changed (after the
    /// inliner, which leaves blocks the entry may not reach). Whether it changed.
    pub(package) fn run(self: &mut Self, pk: &Package, b: &mut Body, force: bool) bool {
        return self.run_as(pk, b, force, false);
    }

    // `run`; `light`: after a loop transform, which moves no edge `thread` follows and makes no place to
    // promote, without `thread`, the promotion and `thread_rounds`.
    fn run_as(self: &mut Self, pk: &Package, b: &mut Body, force: bool, light: bool) bool {
        if b.naked {
            return false;
        }
        self.merged = false;
        self.rethru = false;
        if self.ptr_params(pk, b) {
            self.forget();
        }
        // `thread` computes the graph and the dominators: they stand when it moves no edge (`kept`).
        let threaded = !light && self.thread(pk, b);
        self.tables(pk, b, K_NEST);
        // The walk hoists into preheaders: the memory facts are those of the body that has them.
        let entered = self.preheaders(b, false);
        self.tables(pk, b, K_SLOTS);
        self.wait_copies = !light && self.promote && b.slots.len() != 0;
        self.waited = false;
        let mut changed = self.walk(pk, b) || force || threaded || entered || self.unused_call(b);
        if entered {
            self.unenter(b);
        }
        if changed {
            self.rebuild(b);
        }
        // The by-value aggregate parameters a loop writes, once the walk forwarded the parameters an inlined
        // body's entry takes (their uses are then their own): slots (`param_slots`), whose addresses one
        // more walk forwards for the promotion.
        if self.param_slots(pk, b) {
            self.tables(pk, b, K_SLOTS);
            self.wait_copies = !light && self.promote;
            let _ = self.walk(pk, b);
            self.rebuild(b);
            changed = true;
        }
        // The walks from here on make the copies loads and stores; one runs when a copy waited.
        self.wait_copies = false;
        self.refold = self.refold || self.waited;
        if light {
            let w = self.rewalk(pk, b);
            return self.settle(pk, b) || w || changed;
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
        let own = if self.shares(b) {
            let r = unsafe &*self.shared;
            Some(replace(&mut self.prom, pool_take(&r.free_lock, &r.proms).unwrap_or(pr::Promoter::new())))
        } else {
            Option::<pr::Promoter>::None
        };
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
            &self.ops_at,
            &self.ops_arg,
            &self.ops,
            pk.ptr_bytes,
            &mut self.pbody,
        );
        if let Some(x) = own {
            let r = unsafe &*self.shared;
            pool_give(&r.free_lock, &r.proms, replace(&mut self.prom, x));
        }
        if !promoted {
            let r = self.thread_rounds(pk, b) || changed;
            let w = self.rewalk(pk, b);
            return self.settle(pk, b) || w || r;
        }
        let nb = replace(&mut self.pbody, Body::empty());
        self.pbody = replace(b, nb);
        self.block_map(b);
        self.operands(b);
        self.kept = K_DOM;
        // Promotion turns the flags a `&&` or `||` stores into parameters `thread` reads: it runs before the
        // walk, which serves both.
        let _ = self.thread(pk, b);
        self.tables(pk, b, K_SLOTS);
        let _ = self.walk(pk, b);
        self.rebuild(b);
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
            self.tables(pk, b, K_SLOTS);
            let _ = self.walk(pk, b);
            self.rebuild(b);
        }
        return true;
    }

    // A block the last rebuild left with one predecessor of several (`merged`), instructions the last walk
    // hoisted into blocks it had visited, the selects the last walk made are new, a fold of the last walk
    // came after its readers (`refold`), a jump this `run` made a return left the values it passed dead,
    // which the walk counted where it would make two returns one (`rethru`, `ret_diamond`), and a loop may
    // write less: one more walk forwards into that block, numbers the hoisted instructions (a load the
    // preheader's dominator holds), simplifies the selects and hoists the loads. Whether it ran.
    fn rewalk(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if !self.merged && self.hoisted.len() == 0 && !self.selected && !self.unstored && !self.refold && !self.rethru {
            return false;
        }
        self.rethru = false;
        self.tables(pk, b, K_SLOTS);
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
            self.tables(pk, b, K_SLOTS);
            let _ = self.walk(pk, b);
            self.rebuild(b);
            round += 1;
        }
        return round != 0;
    }

    /// Whether body `b` has no loop (`nest`), no quotient kept for the loop vectorizer (`deferred`), no
    /// 128-bit value, and no `memcmp` call where the walk expands one into vectors (`memcmp_eq`): then the
    /// loop transforms, the rotation and the splits leave it as it is, and only the packing makes vectors
    /// in it.
    pub(package) fn straight(self: &mut Self, pk: &Package, b: &Body) bool {
        if self.deferred || pk.pairs && pa::has_i128(b) {
            return false;
        }
        self.tables(pk, b, K_NEST);
        if self.lbs.len() != 0 {
            return false;
        }
        if pk.vector < 16 || pk.ccmp {
            return true;
        }
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            if t.op == O_CALL && named_alloc(pk, b, t) == ALLOC_MEMCMP {
                return false;
            }
        }
        return true;
    }

    /// Pack body `b`'s isomorphic scalar values into vectors (`lir::slp`), kept when the instruction
    /// count weighted by loop depth drops; then optimize it again. The body before the packing when it
    /// kept one, else None.
    pub(package) fn slp(self: &mut Self, pk: &Package, b: &mut Body) Option<Body> {
        if b.naked || pk.vector < 16 {
            return None;
        }
        let before = self.weigh(pk, b);
        let own = if self.shares(b) {
            let r = unsafe &*self.shared;
            Some(replace(&mut self.slp, pool_take(&r.free_lock, &r.slps).unwrap_or(sl::Slp::new())))
        } else {
            Option::<sl::Slp>::None
        };
        self.slp.late_terms = !pk.apairs;
        self.slp.pairs = pk.apairs;
        self.slp.red_step = pk.vec_reduce;
        // The packs without the alias classes, then with them where they might keep a seed's lanes apart from
        // the accesses between them (`Slp.wants`): the memory analysis only for such a body.
        let none_u8: []u8 = [];
        let none_u32: []u32 = [];
        let mut ok = self.slp.plan(
            b,
            pk.ptr_bytes,
            pk.vector.min(64),
            ((pk.fmath | b.fmath) & FM_ASSOC) != 0,
            pk.hfa_regs,
            &self.wgt,
            &self.blk_of,
            &self.pblock,
            &self.ops_at,
            &self.ops,
            none_u8,
            none_u32,
            0,
        );
        if self.slp.wants {
            self.tables(pk, b, K_MEM);
            ok = self.slp.plan(
                b,
                pk.ptr_bytes,
                pk.vector.min(64),
                ((pk.fmath | b.fmath) & FM_ASSOC) != 0,
                pk.hfa_regs,
                &self.wgt,
                &self.blk_of,
                &self.pblock,
                &self.ops_at,
                &self.ops,
                &self.acls,
                &self.aobj,
                self.sbits,
            );
        }
        // A packing that saves one instruction, which the optimizer's run after it would most often undo,
        // is not tried (each try rebuilds and optimizes the body again).
        if !ok || self.slp.paid < 2 {
            self.slp_done(own);
            return None;
        }
        let mut saved = replace(&mut self.snap, Body::empty());
        b.copy_into(&mut saved);
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
        self.slp_done(own);
        self.rebuild(b);
        let _ = self.run(pk, b, true);
        if self.weigh(pk, b) >= before {
            self.snap = replace(b, saved);
            self.kept = K_NONE;
            return None;
        }
        return Some(saved);
    }

    // The packing's scratch back to the run that lent it (`Run::slps`), the scratch's own (`own`) in its place.
    fn slp_done(self: &mut Self, own: Option<sl::Slp>) {
        if let Some(x) = own {
            let r = unsafe &*self.shared;
            pool_give(&r.free_lock, &r.slps, replace(&mut self.slp, x));
        }
    }

    // The loop window's scratch `x` in place of this one's, which it returns (`Run::loops`).
    fn swap_loops(self: &mut Self, x: LoopParts) LoopParts {
        let mut y = x;
        let u = replace(&mut y.unr, lu::LoopOpt::new());
        y.unr = replace(&mut self.unr, u);
        let sv = replace(&mut y.saved, Vector::<Vector<u32>>::new());
        y.saved = replace(&mut self.saved, sv);
        let sl = replace(&mut y.saved_lb, Vector::<u64>::new());
        y.saved_lb = replace(&mut self.saved_lb, sl);
        return y;
    }

    // Whether body `b` takes the run's shared parts for a pass (`SHARE_MIN`).
    const fn shares(self: &Self, b: &Body) bool {
        return self.shared != null && b.insts.len() > SHARE_MIN;
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
        // The marks change no analysis `tables` keeps. They read the successors and the reverse postorder
        // alone (`cfg`): the rest of `graph` waits until a pass asks for it.
        if self.kept < K_GRAPH {
            self.cfg(b);
        }
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
        let mut seen = replace(&mut self.seen, Vector::<bool>::new());
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
                let add = ast::pick(all == BLOCK_RARE, BLOCK_COLD, all);
                if (b.blocks[k].flags | add) != b.blocks[k].flags {
                    b.blocks.index_mut(k).flags |= add;
                    changed = true;
                }
            }
            // The blocks reached only through marked ones.
            changed = self.unreached(b, BLOCK_COLD, BLOCK_COLD, &mut seen) || changed;
            changed = self.unreached(b, BLOCK_RARE, BLOCK_UNLIKELY, &mut seen) || changed;
            if !changed {
                self.seen = seen;
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
        let any = self.unr.rotate(
            b,
            max,
            &self.inner,
            &self.lparent,
            &self.preh,
            &self.lb_at,
            &self.lbs,
            &self.blk_of,
            &self.pblock,
            &self.dpre,
            &self.dpost,
        );
        if !any {
            return false;
        }
        self.kept = K_NONE;
        let _ = self.run_as(pk, b, true, true);
        return true;
    }

    /// Transform the innermost loops of body `b` (`lir::loops`) within budgets `bu`, then optimize it
    /// again. Whether any changed.
    pub(package) fn loop_opts(self: &mut Self, pk: &Package, b: &mut Body, bu: lu::Budgets) bool {
        if b.naked {
            return false;
        }
        self.tables(pk, b, K_NEST);
        // Every transform takes a loop (`nest`'s blocks: none without one).
        if self.lbs.len() == 0 {
            return false;
        }
        let pre = self.preheaders(b, true);
        // With the final values alone to compute, the classes serve a loop that fills or copies
        // (`LoopOpt::mem_run`) alone: without one, the transforms read none. Each of their reads asks
        // whether a store of a loop is apart from another access (`LoopOpt::apart`): without a store in a
        // loop, none.
        let fin_only = bu.peel == 0 && bu.partial == 0 && bu.version == 0 && bu.unswitch == 0 && bu.vector == 0;
        let classes = (!fin_only || self.run_loops(b)) && self.loop_stores(b);
        if classes {
            self.tables(pk, b, K_MEM);
        }
        self.unr.vops = pk.vops;
        self.unr.apairs = pk.apairs;
        self.unr.vmulh = pk.vec_mulh;
        self.unr.vaccs = pk.vec_accs;
        self.unr.vsat = pk.vec_sat;
        self.unr.vabsd = pk.vec_absd;
        self.unr.vbits = pk.vec_bits;
        self.unr.vpopcnt = pk.popcnt;
        self.unr.vtbl = pk.vtbl;
        self.unr.vmsk = pk.mask_bits;
        self.unr.vperm3 = pk.vec_perm3;
        self.unr.vsumw = pk.vec_sumw;
        self.unr.vmulw = pk.vec_mulw;
        self.unr.vfma = pk.vfloat && pk.fma;
        self.unr.vfloat = pk.vfloat;
        self.unr.vrnda = pk.vround_away;
        self.unr.vfn.truncate(0);
        for s in 0..b.syms.len() {
            let sy = pk.syms[b.syms[s] as usize];
            let f = if pk.vfloat && sy.kind == SK_FUNC && sy.def == NONE {
                lu::lane_fn(pk.spell(sy.name))
            } else {
                0u8
            };
            let round = f == core::SIMD_FLOOR || f == core::SIMD_CEIL || f == core::SIMD_TRUNC || f == lu::ROUND_AWAY;
            self.unr.vfn.push(ast::pick(round && !pk.vround || f == core::SIMD_FMA && !pk.fma, 0u8, f));
        }
        let none_u8: []u8 = [];
        let none_u32: []u32 = [];
        let none_u64: []u64 = [];
        let cl = if classes {
            lu::Classes {
                acc: self.acls.as_slice(),
                obj: self.aobj.as_slice(),
                member: self.imem.as_slice(),
                scoped: self.sbits,
                root: self.croot.as_slice(),
            }
        } else {
            lu::Classes { acc: none_u8, obj: none_u32, member: none_u64, scoped: 0, root: none_u32 }
        };
        let any = self.unr.run(
            b,
            pk.ptr_bytes,
            pk.fmath | b.fmath,
            pk.vector,
            bu,
            &self.inner,
            &self.lparent,
            &self.preh,
            &self.lb_at,
            &self.lbs,
            &self.blk_of,
            &self.pblock,
            &self.dpre,
            &self.dpost,
            cl,
        );
        // A transform that does not apply leaves the body as it was: the preheaders no transform used go.
        if !any {
            if pre {
                self.unpreheaders(b);
            }
            return false;
        }
        self.kept = K_NONE;
        let _ = self.run_as(pk, b, true, true);
        // Once a round made a copy that tests a narrow counter itself (`lu::LoopOpt::narrow_head`): the
        // extensions of a counter its header holds into the body, the counted shape the next round reads
        // (a later copy of that loop, and the walk, may bring one back).
        if self.unr.narrowed {
            if self.sink_heads(pk, b) {
                let _ = self.run_as(pk, b, true, true);
            }
        }
        return true;
    }

    // Whether a block of a loop of `b` stores. The tables of K_NEST.
    fn loop_stores(self: &Self, b: &Body) bool {
        for k in 0..b.blocks.len() {
            if self.inner[k] == NONE {
                continue;
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                if b.insts[i as usize].op == O_STORE {
                    return true;
                }
            }
        }
        return false;
    }

    // Whether an innermost loop of `b` with a preheader (the loops `LoopOpt::run` takes) may fill or copy
    // (`LoopOpt::mem_run`, `mem_pairs`, from `final_values`): one store and at most one load, or as many
    // stores as loads, up to `lu::MR_PAIRS`, every other instruction
    // without an effect (`lu::cf_pure`), its blocks ending in jumps, branches or switches, its header no
    // vectorizer's rest. The tables of K_NEST.
    fn run_loops(self: &Self, b: &Body) bool {
        let nb = b.blocks.len();
        for h in 0..nb {
            if self.inner[h] != h as u32 || self.preh[h] == NONE || (b.blocks[h].flags & (BLOCK_NOVEC | BLOCK_EPI)) != 0 {
                continue;
            }
            let r = self.lb_at[h];
            let mut stores: u32 = 0;
            let mut loads: u32 = 0;
            let mut ok = true;
            for q in (r >> 32) as u32..r as u32 {
                let k = self.lbs[q as usize] as usize;
                // A block of a loop inside this one: not innermost.
                ok = ok && (self.lparent[k] != h as u32 || k == h);
                let bk = b.blocks[k];
                for i in bk.start..bk.start + bk.len - 1 {
                    let t = b.insts[i as usize];
                    if t.op == O_STORE {
                        stores += 1;
                    } else if t.op == O_LOAD {
                        loads += 1;
                    } else {
                        ok = ok && lu::cf_pure(b, t);
                    }
                }
                let op = b.insts[(bk.start + bk.len - 1) as usize].op;
                ok = ok && (op == O_JMP || op == O_BR || op == O_SWITCH);
            }
            if ok && (stores == 1 && loads <= 1 || stores > 1 && loads == stores && stores <= lu::MR_PAIRS as u32) {
                return true;
            }
        }
        return false;
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
            let e = ast::pick(ib, t.c, t.b);
            if b.edge_nargs(e) == 0 || args_among(b, e, ast::pick(ib, t.b, t.c)) {
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
            let v = ast::pick(o.a == ci, o.b, o.a);
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
        // The rewrite reads the reverse postorder alone (`cfg`), and every table goes after it.
        if self.kept < K_GRAPH {
            self.cfg(b);
        }
        self.pairs.run(b, &self.order, &self.rpo, &mut self.pbody);
        let nb = replace(&mut self.pbody, Body::empty());
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
        // The rewrite reads the reverse postorder alone (`cfg`), and every table goes after it.
        if self.kept < K_GRAPH {
            self.cfg(b);
        }
        self.wide.run(b, pk.vector, &self.order, &self.rpo, &mut self.pbody);
        let nb = replace(&mut self.pbody, Body::empty());
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
        // Only loops keep places (`place_of`; `nest`'s blocks: none without a loop), and only a loop of the
        // shape `place_of` takes before its classes (`placeable`) needs them.
        self.tables(pk, b, K_NEST);
        if self.lbs.len() == 0 {
            return false;
        }
        if !self.placeable(b) {
            self.fresh(b);
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
            let loc = b.locs[pi as usize];
            let mut into = NONE;
            if self.gcmp != NONE && pt.op == O_JMP && b.edge_target(pt.a) == h {
                into = self.guard_blocks(b, h, pt, loc, pi);
            }
            let nk = b.add_block(none);
            if into != NONE {
                // The guard's last test into the load.
                b.pool[into as usize] = nk;
            }
            b.begin(nk);
            let sa = b.emit(Inst { op: O_SLOTADDR, ty: T_PTR, aux: 0, a: slot, b: 0, c: 0 }, loc);
            let v = b.emit(Inst { op: O_LOAD, ty: ty, aux: st.aux, a: st.a, b: VNONE, c: st.c }, loc);
            let _ = b.emit(Inst { op: O_STORE, ty: T_NONE, aux: al, a: sa, b: v, c: 0 }, loc);
            let _ = b.emit(pt, loc);
            if b.inl.len() != 0 {
                for _ in 0..4 {
                    b.inl.push(b.inl[pi as usize]);
                }
            }
            if into == NONE {
                b.insts[pi as usize] = jump(b.edge(nk, noargs));
            }
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
                            let it = ast::pick(ty == T_F32, T_I32, T_I64);
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

    // The guard of a place the first pass of loop `h` reaches after tests (`guarded`), on the preheader's jump
    // `pt` (instruction `pi`, location `loc`), which goes to its first block: the header's comparison on the
    // entry values, to the exit with its arguments' entry values when the loop would not run; each check, to
    // its block when the run would leave there. The edge its last test continues on (target to set).
    fn guard_blocks(self: &mut Self, b: &mut Body, h: u32, pt: Inst, loc: u32, pi: u32) u32 {
        let none: []u8 = [];
        let noargs: []Value = [];
        let mut args = Vector::<Value>::with_capacity(b.edge_nargs(pt.a) as usize);
        for k in 0..b.edge_nargs(pt.a) {
            args.push(b.edge_arg(pt.a, k));
        }
        let c = b.insts[self.gcmp as usize];
        let g = b.add_block(none);
        b.insts[pi as usize] = jump(b.edge(g, noargs));
        b.begin(g);
        let n0 = b.insts.len();
        let ca = Opt::entry_of(b, h, args[0..args.len()], c.a);
        let cb = Opt::entry_of(b, h, args[0..args.len()], c.b);
        let cv = b.emit(Inst { op: O_ICMP, ty: c.ty, aux: c.aux, a: ca, b: cb, c: VNONE }, loc);
        self.uargs.truncate(0);
        for k in 0..b.edge_nargs(self.gout) {
            self.uargs.push(Opt::entry_of(b, h, args[0..args.len()], b.edge_arg(self.gout, k)));
        }
        let xe = b.edge(b.edge_target(self.gout), &self.uargs);
        // Each test's edge on: its target set when the next block exists (one test per step).
        let mut on = b.edge(h, noargs);
        let _ = b.emit(
            Inst {
                op: O_BR,
                ty: T_NONE,
                aux: 0,
                a: cv,
                b: ast::pick(self.gstay, on, xe),
                c: ast::pick(self.gstay, xe, on),
            },
            loc,
        );
        let mut q: usize = 0;
        while q < self.gchain.len() {
            let k = b.add_block(none);
            b.pool[on as usize] = k;
            b.begin(k);
            on = b.edge(h, noargs);
            let side = b.edge(self.gchain[q + 1], noargs);
            let stay = (self.gchain[q + 2] & 1) != 0;
            // A comparison of entry values (`entry_cmp`) on them.
            let mut cq = self.gchain[q];
            if (self.gchain[q + 2] & 2) != 0 {
                let t = b.insts[cq as usize];
                let qa = self.entry_again(b, h, args[0..args.len()], t.a, loc);
                let qb = self.entry_again(b, h, args[0..args.len()], t.b, loc);
                cq = b.emit(Inst { op: O_ICMP, ty: t.ty, aux: t.aux, a: qa, b: qb, c: VNONE }, loc);
            }
            let _ = b.emit(
                Inst { op: O_BR, ty: T_NONE, aux: 0, a: cq, b: ast::pick(stay, on, side), c: ast::pick(stay, side, on) },
                loc,
            );
            q += 3;
        }
        if b.inl.len() != 0 {
            for _ in n0..b.insts.len() {
                b.inl.push(b.inl[pi as usize]);
            }
        }
        return on;
    }

    /// Regroup each integer sum of `b` that a chain of additions makes, each used once by the next in its
    /// block (`a + b + c + d`), into a tree of less depth where its leaves allow: on the positions of the
    /// chain's additions, in order, each adds the two partial sums of least depth there (ties: the earliest),
    /// and the last gives the chain's value (the MachineCombiner's reassociation; exact, as an integer sum
    /// wraps). A chain of fewer than 4 leaves or more than 64, or one no regrouping makes shallower, stays.
    pub(package) fn reassociate(self: &mut Self, pk: &Package, b: &mut Body) {
        let ni = b.insts.len();
        fill(&mut self.rcount, ni, 0);
        fill(&mut self.ruser, ni, NONE);
        // Each instruction's uses: its operands and edge arguments (`ops`).
        self.tables(pk, b, K_GRAPH);
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                for q in self.ops_at[i as usize]..self.ops_at[i as usize + 1] {
                    let v = self.ops[q as usize];
                    if v != VNONE && (v & (VPARAM | VFLAG)) == 0 {
                        self.rcount[v as usize] += 1;
                        self.ruser[v as usize] = ast::pick(t.op == O_JMP || t.op == O_BR || t.op == O_SWITCH, NONE, i);
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
                self.kept = K_NONE;
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
    fn place_of(self: &mut Self, pk: &Package, b: &Body, h: u32) u32 {
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
                ) != 0 && tbaa(s) != 0 && tbaa(t) != tbaa(s) || o != NONE && self.aobj[cand as usize] != NONE && o != self.aobj[cand as usize] || tt == ty && self.below_place(
                    b,
                    h,
                    s,
                    t,
                );
                if !apart {
                    return NONE;
                }
            }
        }
        self.gcmp = NONE;
        if !read {
            return NONE;
        }
        if !self.safe_load(pk, b, Inst { op: O_LOAD, ty: ty, aux: s.aux, a: s.a, b: VNONE, c: s.c }) && !self.guarded(
            b,
            h,
            s,
        ) {
            return NONE;
        }
        return cand;
    }

    // Whether access `t` of loop `h` and the place of store `s` (`place_of`) are elements of one array,
    // `base + j * size` and `base + i * size` at one offset, with `j` the header parameter the header's
    // exit test keeps below `i` (`for j in 0..i`, a triangular solve's `x[i] -= l[i][j] * x[j]`), both in
    // bounds: other elements in every iteration.
    fn below_place(self: &Self, b: &Body, h: u32, s: Inst, t: Inst) bool {
        if (s.a & (VPARAM | VFLAG)) != 0 || (t.a & (VPARAM | VFLAG)) != 0 || s.a == VNONE || t.a == VNONE || s.c != t.c {
            return false;
        }
        let (sa, ta) = (b.insts[s.a as usize], b.insts[t.a as usize]);
        // In bounds of one object, two indexes apart are two addresses apart.
        if sa.op != O_PTRADD || ta.op != O_PTRADD || sa.a != ta.a || (sa.aux & PTR_SCALE) != (ta.aux & PTR_SCALE) || sa.c != ta.c || (sa.aux & PTR_SCALE) == 0 || (sa.aux & ta.aux & PTR_INBOUNDS) == 0 {
            return false;
        }
        let hb = b.blocks[h as usize];
        let q = ta.b;
        if (q & VPARAM) == 0 || (q & ~VPARAM) < hb.param_start || (q & ~VPARAM) >= hb.param_start + hb.param_len as u32 {
            return false;
        }
        let th = term(b, h);
        if th.op != O_BR || (th.a & (VPARAM | VFLAG)) != 0 || th.a == VNONE {
            return false;
        }
        let c = b.insts[th.a as usize];
        let taken = self.in_loop(h, b.edge_target(th.b));
        if c.op != O_ICMP || taken == self.in_loop(h, b.edge_target(th.c)) {
            return false;
        }
        // `q <u n` on the edge into the loop.
        let n = if taken && c.aux == C_ULT && c.a == q || !taken && c.aux == C_UGE && c.a == q {
            c.b
        } else if taken && c.aux == C_UGT && c.b == q || !taken && c.aux == C_ULE && c.b == q {
            c.a
        } else {
            VNONE
        };
        return n != VNONE && n == sa.b;
    }

    // Whether a loop of `b` has the shape `place_of` takes, its tests that read no alias class: an innermost
    // loop with a preheader whose blocks end in jumps and branches and hold no call nor other write but
    // loads and stores, a non-volatile store through an address from outside the loop, and a load of the
    // same address and offset. The tables of K_NEST.
    fn placeable(self: &Self, b: &Body) bool {
        for h in 0..b.blocks.len() as u32 {
            if self.inner[h as usize] != h || self.preh[h as usize] == NONE {
                continue;
            }
            let r = self.lb_at[h as usize];
            let mut ok = true;
            for q in (r >> 32) as u32..r as u32 {
                let x = self.lbs[q as usize] as usize;
                let bk = b.blocks[x];
                let te = b.insts[(bk.start + bk.len - 1) as usize].op;
                ok = ok && self.inner[x] == h && (te == O_JMP || te == O_BR);
                for i in bk.start..bk.start + bk.len {
                    let t = b.insts[i as usize];
                    ok = ok && (t.op == O_LOAD || t.op == O_STORE || !writes_memory(t) && t.op != O_VAARG);
                }
            }
            if !ok {
                continue;
            }
            for q in (r >> 32) as u32..r as u32 {
                let bk = b.blocks[self.lbs[q as usize] as usize];
                for i in bk.start..bk.start + bk.len {
                    let s = b.insts[i as usize];
                    if s.op != O_STORE || (s.aux & MEM_VOLATILE) != 0 || !self.outside(s.a, h) {
                        continue;
                    }
                    for q2 in (r >> 32) as u32..r as u32 {
                        let lk = b.blocks[self.lbs[q2 as usize] as usize];
                        for j in lk.start..lk.start + lk.len {
                            let t = b.insts[j as usize];
                            if t.op == O_LOAD && t.a == s.a && t.c == s.c {
                                return true;
                            }
                        }
                    }
                }
            }
        }
        return false;
    }

    // Whether store `i` of the body writes a `static mut`: a writable data object the package defines
    // (`aobj`), also a thread-local one: a loop that calls nothing has no suspension point, so it runs on one
    // thread and the address from before it is its copy's.
    // Whether loop `h`'s first pass reaches an access of place `s` (its address and offset) before anything
    // but pure instructions, given tests the code before the loop can make: none when the header holds the
    // access (a rotated loop: entering it runs the header); else a header that is one comparison of its
    // parameters and values from outside and a branch (in and out of the loop, the exit's arguments the same
    // kinds), then blocks to the access whose branches test a value from outside, or compare entry values
    // (`entry_cmp`: a check of the counter, made again on them), with one side leaving to a block that ends
    // in a trap or a panic and reads only values from outside. Those tests (`gcmp`,
    // `gchain`), on the entry values, guard the place's load before the loop: the header's sends the run to
    // the exit, nothing loaded; a check's to its block, as the first pass would.
    fn guarded(self: &mut Self, b: &Body, h: u32, s: Inst) bool {
        self.gchain.truncate(0);
        let hb = b.blocks[h as usize];
        for i in hb.start..hb.start + hb.len {
            let t = b.insts[i as usize];
            if (t.op == O_LOAD || t.op == O_STORE) && t.a == s.a && t.c == s.c {
                return true;
            }
        }
        if hb.len != 2 {
            return false;
        }
        let c = b.insts[hb.start as usize];
        let tm = b.insts[(hb.start + 1) as usize];
        if c.op != O_ICMP || tm.op != O_BR || tm.a != hb.start || !self.entry_val(b, h, c.a) || !self.entry_val(
            b,
            h,
            c.b,
        ) {
            return false;
        }
        let bt = self.in_loop(h, b.edge_target(tm.b));
        let ct = self.in_loop(h, b.edge_target(tm.c));
        if bt == ct {
            return false;
        }
        let (into, out) = if bt {
            (tm.b, tm.c)
        } else {
            (tm.c, tm.b)
        };
        if b.edge_nargs(into) != 0 {
            return false;
        }
        for k in 0..b.edge_nargs(out) {
            if !self.entry_val(b, h, b.edge_arg(out, k)) {
                return false;
            }
        }
        let mut x = b.edge_target(into);
        // One block per step.
        for _ in 0..b.blocks.len() {
            let bk = b.blocks[x as usize];
            for i in bk.start..bk.start + bk.len - 1 {
                let t = b.insts[i as usize];
                if (t.op == O_LOAD || t.op == O_STORE) && t.a == s.a && t.c == s.c {
                    self.gcmp = hb.start;
                    self.gout = out;
                    self.gstay = bt;
                    return true;
                }
                if writes_memory(t) || t.op == O_VAARG {
                    return false;
                }
            }
            let e = b.insts[(bk.start + bk.len - 1) as usize];
            // A test of a value from outside, or a comparison of entry values (a check of the counter), which
            // the guard makes again on them.
            let again = e.op == O_BR && !self.outside(e.a, h) && self.entry_cmp(b, h, e.a);
            if e.op != O_BR || !self.outside(e.a, h) && !again || b.edge_nargs(e.b) != 0 || b.edge_nargs(e.c) != 0 {
                return false;
            }
            let (on, side, stay) = if self.in_loop(h, b.edge_target(e.b)) && self.ends_run(b, h, b.edge_target(e.c)) {
                (e.b, e.c, true)
            } else if self.in_loop(h, b.edge_target(e.c)) && self.ends_run(b, h, b.edge_target(e.b)) {
                (e.c, e.b, false)
            } else {
                return false;
            };
            self.gchain.push(e.a);
            self.gchain.push(b.edge_target(side));
            self.gchain.push(stay as u32 | again as u32 << 1);
            x = b.edge_target(on);
        }
        return false;
    }

    // Whether `v` is a scalar integer comparison of `entry_expr` values (`guarded`): its value on loop `h`'s
    // first pass is the comparison of their values from the entry values.
    fn entry_cmp(self: &Self, b: &Body, h: u32, v: Value) bool {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE {
            return false;
        }
        let t = b.insts[v as usize];
        return t.op == O_ICMP && !is_vec(t.ty) && self.entry_expr(b, h, t.a, ENTRY_DEPTH) && self.entry_expr(
            b,
            h,
            t.b,
            ENTRY_DEPTH,
        );
    }

    // Whether `v` is a value `entry_val` takes, or a scalar integer sum, difference or product of such, up
    // to `depth` operations deep (`i * n + j`, an index the loop checks): `entry_again` computes it from the
    // entry values. None traps.
    fn entry_expr(self: &Self, b: &Body, h: u32, v: Value, depth: u32) bool {
        if self.entry_val(b, h, v) {
            return true;
        }
        if depth == 0 || (v & (VPARAM | VFLAG)) != 0 || v == VNONE {
            return false;
        }
        let t = b.insts[v as usize];
        return (t.op == O_ADD || t.op == O_SUB || t.op == O_MUL) && is_int(t.ty) && !is_vec(t.ty) && t.ty != T_I128 && self.entry_expr(
            b,
            h,
            t.a,
            depth - 1,
        ) && self.entry_expr(b, h, t.b, depth - 1);
    }

    // `entry_expr` value `v` of loop `h` computed again in the block at hand from the entry values `args`
    // (`entry_of`), at location `loc`.
    fn entry_again(self: &Self, b: &mut Body, h: u32, args: []Value, v: Value, loc: u32) Value {
        if self.entry_val(b, h, v) {
            return Opt::entry_of(b, h, args, v);
        }
        let t = b.insts[v as usize];
        let x = self.entry_again(b, h, args, t.a, loc);
        let y = self.entry_again(b, h, args, t.b, loc);
        return b.emit(Inst { op: t.op, ty: t.ty, aux: 0, a: x, b: y, c: VNONE }, loc);
    }

    // Whether `v` is a parameter of loop header `h` or a value from outside the loop: on the entry edge, the
    // edge's argument or itself (`entry_of`).
    fn entry_val(self: &Self, b: &Body, h: u32, v: Value) bool {
        let hb = b.blocks[h as usize];
        return (v & VPARAM) != 0 && (v & ~VPARAM) >= hb.param_start && (v & ~VPARAM) < hb.param_start + hb.param_len as u32 || self.outside(
            v,
            h,
        );
    }

    // `v` on the edge into header `h` whose arguments `args` are: a parameter's argument, else `v`.
    fn entry_of(b: &Body, h: u32, args: []Value, v: Value) Value {
        let hb = b.blocks[h as usize];
        if (v & VPARAM) != 0 && (v & ~VPARAM) >= hb.param_start && (v & ~VPARAM) < hb.param_start + hb.param_len as u32 {
            return args[((v & ~VPARAM) - hb.param_start) as usize];
        }
        return v;
    }

    // Whether block `x`, out of loop `h`, ends the run (a trap or a panic) and reads only values from outside
    // the loop, with no parameter: a guard may jump to it before the loop.
    fn ends_run(self: &Self, b: &Body, h: u32, x: u32) bool {
        let bk = b.blocks[x as usize];
        if self.in_loop(h, x) || bk.param_len != 0 || bk.len == 0 {
            return false;
        }
        let e = b.insts[(bk.start + bk.len - 1) as usize].op;
        if e != O_UNREACHABLE && e != O_PANIC {
            return false;
        }
        let mut ops = Vector::<Value>::new();
        for i in bk.start..bk.start + bk.len {
            lv::uses(b, b.insts[i as usize], &mut ops);
            for q in 0..ops.len() {
                if !self.outside(ops[q], h) {
                    return false;
                }
            }
        }
        return true;
    }

    // Whether access `i` is of a read-only data definition of the package (`aobj`), which no write touches.
    fn rodata(self: &Self, pk: &Package, i: u32) bool {
        let o = self.aobj[i as usize];
        if o == NONE || (o & (lu::OBJ_SLOT | lu::OBJ_PRIVATE | lu::OBJ_FRESH)) != 0 {
            return false;
        }
        let y = pk.syms[o as usize];
        return y.kind == SK_DATA && y.def != NONE && pk.data[y.def as usize].readonly;
    }

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
    // outside keeps none. The tables up to `nest` stay (`enter_tables`); with `undo`, those before it too,
    // for `unpreheaders`. Whether any.
    fn preheaders(self: &mut Self, b: &mut Body, undo: bool) bool {
        let nb = b.blocks.len();
        let mut any = false;
        fill(&mut self.pnew, nb, false);
        self.pundo.truncate(0);
        self.phd.truncate(0);
        self.saved_on = false;
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
            self.ptypes.truncate(0);
            self.pargs.truncate(0);
            if n == 1 {
                for q in 0..b.edge_nargs(one) {
                    self.pargs.push(b.edge_arg(one, q));
                }
            } else {
                for q in hb.param_start..hb.param_start + hb.param_len as u32 {
                    self.ptypes.push(b.params[q as usize]);
                }
            }
            let loc = b.locs[hb.start as usize];
            let x = b.add_block(&self.ptypes);
            for q in 0..self.ptypes.len() as u32 {
                self.pargs.push(b.param(x, q));
            }
            b.begin(x);
            self.pnew.push(true);
            self.phd.push(h);
            let into = b.edge(h, &self.pargs);
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
            if undo {
                self.save_tables();
            }
            self.enter_tables(b, nb);
        }
        return any;
    }

    // The operand tables (`operands`) of `b` from those of its first instructions: the instructions
    // `lsort` lists (ascending; a repeat is redone once) and those past the old tables decoded, the
    // others' entries moved. None of the decoded ones is or was a call: `rcall` stands.
    fn splice_ops(self: &mut Self, b: &Body) {
        let oat = replace(&mut self.ops_at, replace(&mut self.xat, Vector::<u32>::new()));
        let oarg = replace(&mut self.ops_arg, replace(&mut self.xarg, Vector::<u32>::new()));
        let oops = replace(&mut self.ops, replace(&mut self.xops, Vector::<Value>::new()));
        let odst = replace(&mut self.ops_dst, replace(&mut self.xdst, Vector::<u32>::new()));
        self.ops_at.truncate(0);
        self.ops_arg.truncate(0);
        self.ops.truncate(0);
        self.ops_dst.truncate(0);
        self.counted = false;
        let ni0 = oat.len() - 1;
        let mut c: usize = 0;
        let mut i: usize = 0;
        // Each step moves a span and redoes one listed instruction, or moves the rest.
        for _ in 0..self.lsort.len() + 1 {
            let next = if c < self.lsort.len() {
                self.lsort[c] as usize
            } else {
                ni0
            };
            let a0 = oat[i] as usize;
            let a1 = oat[next] as usize;
            // The span moves down when a terminator before it lost its edges' arguments (`redirect`).
            let d = self.ops.len() as i64 - oat[i] as i64;
            for j in i..next {
                self.ops_at.push((oat[j] as i64 + d) as u32);
                self.ops_arg.push((oarg[j] as i64 + d) as u32);
            }
            self.ops.extend_from_slice(oops[a0..a1]);
            self.ops_dst.extend_from_slice(odst[a0..a1]);
            if next == ni0 {
                break;
            }
            self.operands_of(b, next);
            while c < self.lsort.len() && self.lsort[c] as usize == next {
                c += 1;
            }
            i = next + 1;
        }
        for j in ni0..b.insts.len() {
            self.operands_of(b, j);
        }
        self.ops_at.push(self.ops.len() as u32);
        self.xat = oat;
        self.xarg = oarg;
        self.xops = oops;
        self.xdst = odst;
        self.splices += 1;
    }

    // The tables up to `nest` (`kept` = K_NEST) for the blocks `preheaders` added to a body of `nb0`
    // blocks (block `nb0 + q` enters header `phd[q]` from outside its loop), as `graph`, `dominators` and
    // `nest` compute them: the depth-first search enters each new block where it entered its header, just
    // before the header; the new block's dominator is its header's, and it dominates its header; it is in
    // each loop around its header's loop and in no other, and heads none.
    fn enter_tables(self: &mut Self, b: &Body, nb0: usize) {
        let nb = b.blocks.len();
        let m = nb - nb0;
        // The successors: a rewritten terminator keeps its edges' order (`redirect`); a new block jumps.
        for q in 0..self.pundo.len() {
            let i = self.pundo[q].0;
            let k = self.blk_of[i as usize] as usize;
            b.succ_edges(b.insts[i as usize], &mut self.edges);
            let s0 = self.succ_at[k] as usize;
            assert(s0 + self.edges.len() == self.succ_at[k + 1] as usize, "opt: a preheader keeps the edge count");
            for e in 0..self.edges.len() {
                self.succs[s0 + e] = b.edge_target(self.edges[e]);
            }
        }
        for q in 0..m {
            self.succs.push(self.phd[q]);
            self.succ_at.push(self.succs.len() as u32);
        }
        // The reverse postorder, each new block before its header.
        fill(&mut self.mark, nb0, NONE);
        for q in 0..m {
            self.mark[self.phd[q] as usize] = (nb0 + q) as u32;
        }
        self.work.truncate(0);
        for i in 0..self.order.len() {
            let k = self.order[i];
            if self.mark[k as usize] != NONE {
                self.work.push(self.mark[k as usize]);
            }
            self.work.push(k);
        }
        let fresh = replace(&mut self.work, Vector::<u32>::new());
        self.work = replace(&mut self.order, fresh);
        fill(&mut self.rpo, nb, NONE);
        for i in 0..self.order.len() {
            self.rpo[self.order[i] as usize] = i as u32;
        }
        self.pred_lists(nb);
        // The blocks of the new parameters and instructions, which come last in block order.
        for x in nb0..nb {
            let bk = b.blocks[x];
            for _ in 0..bk.param_len {
                self.pblock.push(x as u32);
            }
            for _ in 0..bk.len {
                self.blk_of.push(x as u32);
            }
        }
        assert(
            self.blk_of.len() == b.insts.len() && self.pblock.len() == b.params.len(),
            "opt: the preheaders' blocks come last",
        );
        // The operands: the rewritten terminators' and the new jumps' again (no call among them: `rcall`
        // stays), the others' moved.
        self.lsort.truncate(0);
        for q in 0..self.pundo.len() {
            self.lsort.push(self.pundo[q].0);
        }
        self.lsort.sort();
        self.splice_ops(b);
        // The dominators.
        for q in 0..m {
            self.idom.push(self.idom[self.phd[q] as usize]);
        }
        for q in 0..m {
            self.idom[self.phd[q] as usize] = (nb0 + q) as u32;
        }
        self.dom_tree(nb);
        // The loops: each new block in its header's enclosing loops, after their blocks (it has the
        // greatest number), in block order.
        self.stack.truncate(0);
        for q in 0..m {
            let h = self.phd[q] as usize;
            self.inner.push(self.lparent[h]);
            self.lparent.push(NONE);
            self.preh.push(NONE);
            self.lb_at.push(0);
            self.preh[h] = (nb0 + q) as u32;
            let mut l = self.lparent[h];
            // Each step leaves one loop.
            while l != NONE {
                self.stack.push(self.rpo[l as usize] as u64 << 32 | (nb0 + q) as u64);
                l = self.lparent[l as usize];
            }
        }
        self.stack.sort();
        let old = replace(&mut self.lbs, replace(&mut self.work, Vector::<u32>::new()));
        self.lbs.truncate(0);
        let mut p: usize = 0;
        for i in 0..self.order.len() {
            let k = self.order[i] as usize;
            if self.inner[k] != k as u32 {
                continue;
            }
            let r = self.lb_at[k];
            let s0 = self.lbs.len() as u64;
            self.lbs.extend_from_slice(old[(r >> 32) as usize..(r as u32) as usize]);
            while p < self.stack.len() && (self.stack[p] >> 32) as usize == i {
                self.lbs.push(self.stack[p] as u32);
                p += 1;
            }
            self.lb_at[k] = s0 << 32 | self.lbs.len() as u64;
        }
        assert(p == self.stack.len(), "opt: each preheader's loops are headers");
        self.work = old;
        self.kept = K_NEST;
    }

    // Copy the tables up to `nest` that `enter_tables` rewrites (`unpreheaders` takes them back): the operand
    // lists stay in the spares of the splice it makes (`splice_ops`), and the instructions' and parameters'
    // blocks only grow.
    fn save_tables(self: &mut Self) {
        if self.saved.len() == 0 {
            for _ in 0..15 {
                self.saved.push(Vector::<u32>::new());
            }
        }
        self.saved.index_mut(0).truncate(0);
        self.saved.index_mut(0).extend_copy(&self.succ_at);
        self.saved.index_mut(1).truncate(0);
        self.saved.index_mut(1).extend_copy(&self.succs);
        self.saved.index_mut(2).truncate(0);
        self.saved.index_mut(2).extend_copy(&self.rpo);
        self.saved.index_mut(3).truncate(0);
        self.saved.index_mut(3).extend_copy(&self.order);
        self.saved.index_mut(4).truncate(0);
        self.saved.index_mut(4).extend_copy(&self.pred_at);
        self.saved.index_mut(5).truncate(0);
        self.saved.index_mut(5).extend_copy(&self.preds);
        self.saved.index_mut(6).truncate(0);
        self.saved.index_mut(6).extend_copy(&self.idom);
        self.saved.index_mut(7).truncate(0);
        self.saved.index_mut(7).extend_copy(&self.kid_at);
        self.saved.index_mut(8).truncate(0);
        self.saved.index_mut(8).extend_copy(&self.kids);
        self.saved.index_mut(9).truncate(0);
        self.saved.index_mut(9).extend_copy(&self.dpre);
        self.saved.index_mut(10).truncate(0);
        self.saved.index_mut(10).extend_copy(&self.dpost);
        self.saved.index_mut(11).truncate(0);
        self.saved.index_mut(11).extend_copy(&self.inner);
        self.saved.index_mut(12).truncate(0);
        self.saved.index_mut(12).extend_copy(&self.lparent);
        self.saved.index_mut(13).truncate(0);
        self.saved.index_mut(13).extend_copy(&self.preh);
        self.saved.index_mut(14).truncate(0);
        self.saved.index_mut(14).extend_copy(&self.lbs);
        self.saved_lb.truncate(0);
        self.saved_lb.extend_copy(&self.lb_at);
        self.saved_ni = self.blk_of.len() as u32;
        self.saved_np = self.pblock.len() as u32;
        self.saved_splice = self.splices + 1;
        self.saved_on = true;
    }

    // The tables `save_tables` copied, back in place (the copies keep the current ones' buffers).
    fn restore_tables(self: &mut Self) {
        let t0 = replace(&mut self.succ_at, Vector::<u32>::new());
        self.succ_at = replace(self.saved.index_mut(0), t0);
        let t1 = replace(&mut self.succs, Vector::<u32>::new());
        self.succs = replace(self.saved.index_mut(1), t1);
        let t2 = replace(&mut self.rpo, Vector::<u32>::new());
        self.rpo = replace(self.saved.index_mut(2), t2);
        let t3 = replace(&mut self.order, Vector::<u32>::new());
        self.order = replace(self.saved.index_mut(3), t3);
        let t4 = replace(&mut self.pred_at, Vector::<u32>::new());
        self.pred_at = replace(self.saved.index_mut(4), t4);
        let t5 = replace(&mut self.preds, Vector::<u32>::new());
        self.preds = replace(self.saved.index_mut(5), t5);
        let t6 = replace(&mut self.idom, Vector::<u32>::new());
        self.idom = replace(self.saved.index_mut(6), t6);
        let t7 = replace(&mut self.kid_at, Vector::<u32>::new());
        self.kid_at = replace(self.saved.index_mut(7), t7);
        let t8 = replace(&mut self.kids, Vector::<u32>::new());
        self.kids = replace(self.saved.index_mut(8), t8);
        let t9 = replace(&mut self.dpre, Vector::<u32>::new());
        self.dpre = replace(self.saved.index_mut(9), t9);
        let t10 = replace(&mut self.dpost, Vector::<u32>::new());
        self.dpost = replace(self.saved.index_mut(10), t10);
        let t11 = replace(&mut self.inner, Vector::<u32>::new());
        self.inner = replace(self.saved.index_mut(11), t11);
        let t12 = replace(&mut self.lparent, Vector::<u32>::new());
        self.lparent = replace(self.saved.index_mut(12), t12);
        let t13 = replace(&mut self.preh, Vector::<u32>::new());
        self.preh = replace(self.saved.index_mut(13), t13);
        let t14 = replace(&mut self.lbs, Vector::<u32>::new());
        self.lbs = replace(self.saved.index_mut(14), t14);
        let tl = replace(&mut self.lb_at, Vector::<u64>::new());
        self.lb_at = replace(&mut self.saved_lb, tl);
        assert(self.splices == self.saved_splice, "opt: the spares hold the operand lists before the preheaders");
        let ta = replace(&mut self.ops_at, Vector::<u32>::new());
        self.ops_at = replace(&mut self.xat, ta);
        let tg = replace(&mut self.ops_arg, Vector::<u32>::new());
        self.ops_arg = replace(&mut self.xarg, tg);
        let tv = replace(&mut self.ops, Vector::<Value>::new());
        self.ops = replace(&mut self.xops, tv);
        let td = replace(&mut self.ops_dst, Vector::<u32>::new());
        self.ops_dst = replace(&mut self.xdst, td);
        self.blk_of.truncate(self.saved_ni as usize);
        self.pblock.truncate(self.saved_np as usize);
        self.saved_on = false;
        self.kept = K_NEST;
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
        if self.saved_on {
            self.restore_tables();
        } else {
            self.kept = K_NONE;
        }
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
        self.cfg(b);
        self.pred_lists(b.blocks.len());
        self.block_map(b);
        self.operands(b);
    }

    // `graph`'s successors (`succ_at`, `succs`) and reverse postorder (`rpo`, `order`).
    fn cfg(self: &mut Self, b: &Body) {
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
    }

    // The predecessors among the reached blocks (`rpo`), in block order, from the successors (`graph`): a
    // block the rewrites left behind (a branch folded, an edge threaded) enters nothing.
    fn pred_lists(self: &mut Self, nb: usize) {
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
        self.counted = false;
        for i in 0..ni {
            self.operands_of(b, i);
        }
        self.ops_at.push(self.ops.len() as u32);
    }

    // Per instruction of `b` the operand tables cover, how many instructions read it, up to 2 (`icount`),
    // and whether an `or` reads it (`in_or`); nothing when they are those of these tables already. The
    // walk asks at its first use: the instructions it appended since have no entries, and an instruction's
    // readers come after it in the walk's order, so when the walk asks about it, it rewrote none of them.
    fn readers(self: &mut Self, b: &Body) {
        if self.counted {
            return;
        }
        self.counted = true;
        let ni = self.ops_at.len() - 1;
        fill(&mut self.icount, ni, 0);
        fill(&mut self.in_or, ni, false);
        for i in 0..ni {
            let is_or = b.insts[i].op == O_OR;
            for u in self.ops_at[i]..self.ops_at[i + 1] {
                // VNONE has the VPARAM bit too.
                let v = self.ops[u as usize];
                if (v & VPARAM) != 0 {
                    continue;
                }
                let x = (v & ~VFLAG) as usize;
                if self.icount[x] < 2 {
                    self.icount[x] += 1;
                }
                if is_or {
                    self.in_or[x] = true;
                }
            }
        }
    }

    // Instruction `i`'s entries of `operands`, appended.
    fn operands_of(self: &mut Self, b: &Body, i: usize) {
        let t = b.insts[i];
        self.rcall = self.rcall || (t.op == O_CALL || t.op == O_CALLIND) && (b.pool[t.b as usize + 2] & AGG) != 0 && b.pool[(b.pool[t.b as usize + 2] & ~AGG) as usize] <= 16;
        self.ops_at.push(self.ops.len() as u32);
        lv::uses_into(b, t, &mut self.ops);
        self.ops_dst.resize_default(self.ops.len());
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
                        dom_meet(&self.idom, &self.rpo, d, q)
                    };
                }
                if d != self.idom[k] {
                    self.idom[k] = d;
                    changed = true;
                }
            }
        }
        self.dom_tree(nb);
    }

    // The dominator tree of `idom` (`dominators`): each block's children in reverse postorder, and the
    // tree's preorder and postorder numbers.
    fn dom_tree(self: &mut Self, nb: usize) {
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

    // The alias class of every address value: CL_NOALIAS + k for one that comes from exclusive reference
    // parameter k (`Body.refs`, or the aggregate result's pointer) through address arithmetic, selects and block parameters, CL_OTHER for one
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
        self.obits = 0;
        self.imem.truncate(0);
        let e = b.blocks[0];
        self.cnext = e.param_len;
        let mut seeds: u64 = 0;
        for k in 0..b.refs.len() {
            if (b.refs[k] & REF_NOALIAS) != 0 && k < (CL_FROZEN - CL_NOALIAS) as usize && k < e.param_len as usize {
                seeds |= 1u64 << k as u64;
            }
        }
        // The pointer to an aggregate result, the parameter after the signature's: the caller passes memory
        // no other pointer of the call reaches (a slot of its own, its own result, an exclusive parameter's
        // referent no other argument reaches: `result_into`), as C callers do (an `sret` is `noalias`).
        let np = b.pool[b.sig as usize];
        if (b.pool[b.sig as usize + 2] & AGG) != 0 && np < (CL_FROZEN - CL_NOALIAS) as u32 && np < e.param_len as u32 {
            seeds |= 1u64 << np as u64;
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
        if seeds != 0 {
            self.cf_work.truncate(0);
            for o in 0..self.order.len() {
                let bk = b.blocks[self.order[o] as usize];
                for i in bk.start..bk.start + bk.len {
                    let op = b.insts[i as usize].op;
                    if op == O_PTRADD || op == O_SELECT {
                        self.cf_work.push(i);
                    }
                }
                let ti = bk.start + bk.len - 1;
                if self.ops_arg[ti as usize] != self.ops_at[ti as usize + 1] {
                    self.cf_work.push(CF_EDGES | ti);
                }
            }
        }
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
                self.obits = (seeds & owned) << 1;
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
        // A root of two classes' scopes (two sites' copies that share one value) ends both: a value has one
        // class, and a copy that passes it on under the other's would let the base escape (`escape_bits`).
        self.sroots.truncate(0);
        for x in 0..b.scopes.len() {
            let r = b.scopes[x].root;
            if self.sgroup[x] != NONE && r != VNONE {
                self.sroots.push(r as u64 << 32 | self.sgroup[x] as u64);
            }
        }
        self.sroots.sort();
        for q in 1..self.sroots.len() {
            let (lo, hi) = (self.sroots[q - 1], self.sroots[q]);
            if lo >> 32 == hi >> 32 && lo != hi {
                out &= ~(1u64 << (lo & 0xFFFFFFFF)) & ~(1u64 << (hi & 0xFFFFFFFF));
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
        let mut any = false;
        for x in 0..b.owned.len() {
            let k = (b.owned[x] >> 32) as u32;
            any = any || k < 64 && (params >> k as u64 & 1) != 0 && !inner(b, k);
        }
        if !any || start >= (CL_FROZEN - CL_NOALIAS) as u32 {
            return 0;
        }
        // Per instruction, the parameter its address arithmetic starts from and the constant offset. Each
        // pass sets one more or ends: at most `ni + 1`. A pass that met no unset arithmetic on unset
        // arithmetic later in the body is the last: a later pass would find the same.
        let ni = b.insts.len();
        fill(&mut self.oder, ni, NONE);
        fill(&mut self.ooffs, ni, OFF_ANY);
        for _ in 0..ni + 1 {
            let mut changed = false;
            let mut ahead = false;
            for i in 0..ni {
                let t = b.insts[i];
                if t.op != O_PTRADD || self.oder[i] != NONE {
                    continue;
                }
                let (k, o) = self.param_at(b, t.a);
                if k == NONE {
                    ahead = ahead || (t.a & (VPARAM | VFLAG)) == 0 && t.a != VNONE && t.a as usize > i && b.insts[t.a as usize].op == O_PTRADD;
                    continue;
                }
                let n = if t.b == VNONE {
                    Option::<u64>::Some(0)
                } else {
                    int_bits(b, t.b)
                };
                self.oder[i] = k;
                self.ooffs[i] = if o == OFF_ANY || n.is_none() {
                    OFF_ANY
                } else {
                    o + n.unwrap() as i64 * scale_of(t) as i64 + (t.c as i32) as i64
                };
                changed = true;
            }
            if !changed || !ahead {
                break;
            }
        }
        // The fields the body loads a pointer from (`okeys`, `parameter << 32 | offset`): only they take
        // class indices, so a body that reaches a few fields of a referent with many keeps a class each.
        self.okeys.truncate(0);
        for i in 0..ni {
            let t = b.insts[i];
            if t.op == O_LOAD && t.ty == T_PTR {
                let (k, o) = self.param_at(b, t.a);
                if k != NONE && o != OFF_ANY {
                    let at = o + (t.c as i32) as i64;
                    if at >= 0 && at <= 0xFFFFFFFF {
                        self.okeys.push(k as u64 << 32 | at as u64);
                    }
                }
            }
        }
        self.okeys.sort();
        fill(&mut self.oparam, CL_MANY as usize, NONE);
        fill(&mut self.ooff, CL_MANY as usize, 0);
        let mut out: u64 = 0;
        let mut next = start;
        for x in 0..b.owned.len() {
            let k = (b.owned[x] >> 32) as u32;
            if next >= (CL_FROZEN - CL_NOALIAS) as u32 {
                break;
            }
            if k < 64 && (params >> k as u64 & 1) != 0 && !inner(b, k) && self.okeys.binary_search(&b.owned[x]).is_ok() {
                self.oparam[next as usize] = k;
                self.ooff[next as usize] = b.owned[x] as u32;
                out |= 1u64 << next as u64;
                next += 1;
            }
        }
        if out == 0 {
            return 0;
        }
        fill(&mut self.oload, ni, NONE);
        // Per parameter, its fields' class indices.
        let mut pmask: [u64; 64] = [0u64; 64];
        for idx in 0..(CL_FROZEN - CL_NOALIAS) as usize {
            if (out >> idx as u64 & 1) != 0 {
                pmask[self.oparam[idx] as usize] |= 1u64 << idx as u64;
            }
        }
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
                // A direct call's argument reaches the fields its span covers (`owned_args`); a callee that
                // lets it escape takes the parameter's class, and its fields' with it (`classes`).
                if !addr && t.op != O_CALL {
                    lost |= 1u64 << k as u64;
                    continue;
                }
                if !addr {
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
                if o == OFF_ANY {
                    if ty == T_PTR || is_vec(ty) {
                        gone |= pmask[k as usize];
                    }
                    continue;
                }
                let at = o + (t.c as i32) as i64;
                let n = type_bytes(ty, 8) as i64;
                // Its parameter's fields in rising index order: the last field a pointer load reads wins.
                let mut m = pmask[k as usize];
                // Each step clears one bit: at most 64 steps.
                while m != 0 {
                    let idx = m.trailing_zeros();
                    m &= m - 1;
                    let f = self.ooff[idx] as i64;
                    if at == f && t.op == O_LOAD && ty == T_PTR {
                        self.oload[i] = idx as u32;
                    } else if at < f + 8 && f < at + n {
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

    // The class of instruction `i`'s access through address `a`: its address's; a scope's class outside that
    // scope's copy, its roots' base's (`base_at`); in a scope's copy, the scope's for an offset from the value
    // its roots are offsets from (`sroot`): the copy's access through a root, folded onto that value.
    const fn acc(self: &Self, b: &Body, i: u32, a: Value) u8 {
        let c = self.class(a);
        if c < CL_MANY && (class_bit(c) & self.sbits) != 0 {
            return self.base_at(c, self.member(i), self.sbits);
        }
        let m = self.member(i) & self.sbits;
        if m == 0 {
            return c;
        }
        let (base, _) = address_of(b, a);
        for s in CL_NOALIAS..CL_MANY {
            if (m & class_bit(s)) != 0 && (self.smulti[s as usize] || self.sroot[s as usize] == base) {
                return s;
            }
        }
        return c;
    }

    // Class `c` at an instruction of the scope classes `m` (`member`), of the scope classes `scoped`: past
    // its copy a scope's root is a pointer of its roots' base's class (`cbase`), through nested scopes;
    // CL_MANY when that base is not one class.
    const fn base_at(self: &Self, c: u8, m: u64, scoped: u64) u8 {
        let mut x = c;
        // Each step goes from a scope class to its roots' base; a cycle of roots ends with CL_MANY.
        for _ in 0..CL_MANY {
            if x >= CL_MANY {
                return CL_MANY;
            }
            if (class_bit(x) & scoped) == 0 || (m & class_bit(x)) != 0 {
                return x;
            }
            x = self.cbase[x as usize];
        }
        return CL_MANY;
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
        // Unreached address arithmetic and selects start as CL_OTHER: no reached value reads them, and the
        // settled classes make CL_UNSET CL_OTHER.
        fill(&mut self.icls, b.insts.len(), CL_OTHER);
        for w in 0..self.cf_work.len() {
            let x = self.cf_work[w];
            if (x & CF_EDGES) == 0 {
                self.icls[x as usize] = CL_UNSET;
            }
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
            for w in 0..self.cf_work.len() {
                let x = self.cf_work[w];
                if (x & CF_EDGES) != 0 {
                    // The edges' arguments (`operands`).
                    let ti = (x & ~CF_EDGES) as usize;
                    for u in self.ops_arg[ti]..self.ops_at[ti + 1] {
                        let q = self.ops_dst[u as usize] as usize;
                        let c = join(self.pcls[q], self.class(self.ops[u as usize]));
                        if c != self.pcls[q] && !self.ppin[q] {
                            self.pcls[q] = c;
                            changed = true;
                        }
                    }
                    continue;
                }
                let t = b.insts[x as usize];
                let c = if t.op == O_PTRADD {
                    self.class(t.a)
                } else {
                    join(self.class(t.b), self.class(t.c))
                };
                if c != self.icls[x as usize] && !self.ipin[x as usize] {
                    self.icls[x as usize] = c;
                    changed = true;
                }
            }
            if !changed {
                // A value of no reachable definition is no parameter's. Only the work's values start unset.
                for w in 0..self.cf_work.len() {
                    let x = self.cf_work[w];
                    if (x & CF_EDGES) == 0 && self.icls[x as usize] == CL_UNSET {
                        self.icls[x as usize] = CL_OTHER;
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
        fill(&mut self.sroot, CL_MANY as usize, VNONE);
        fill(&mut self.smulti, CL_MANY as usize, false);
        for x in 0..b.scopes.len() {
            let idx = self.sgroup[x];
            let r = b.scopes[x].root;
            if idx == NONE || (seeds >> idx as u64 & 1) == 0 || r == VNONE || (r & VFLAG) != 0 {
                continue;
            }
            let s = CL_NOALIAS as usize + idx as usize;
            self.cbase[s] = join(self.cbase[s], self.unpinned(b, r, seeds));
            // The value a root is a constant offset from (`acc`), when it is one; two such values, any.
            let (base, _) = address_of(b, r);
            if base != r {
                self.smulti[s] = self.smulti[s] || self.sroot[s] != VNONE && self.sroot[s] != base;
                self.sroot[s] = base;
            }
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
            // A CL_OTHER value adds only bit 0 (`scoped` holds none), which the result drops.
            if op == O_STORE {
                let c = self.class(t.b);
                if c != CL_OTHER {
                    out |= self.escape_bits(c, foreign);
                }
                continue;
            }
            let freed = ast::pick(op == O_RET || op == O_CALL && call_alloc(pk, b, t) == ALLOC_FREE, fresh, 0u64);
            // A call's uses are its arguments.
            let kept = if op == O_CALL {
                ~pk.syms[b.syms[t.a as usize] as usize].esc
            } else {
                0u64
            };
            for u in 0..nu {
                let c = self.class(self.ops[(u0 + u) as usize]);
                // Past its copy, a scope's value is one of its roots' base, which an argument the callee
                // keeps no pointer of lets escape no more than any value of that base's class.
                if c == CL_OTHER || u < 64 && (kept >> u as u64 & 1) != 0 && (class_bit(
                    self.base_at(c, self.member(i as u32), scoped),
                ) & scoped) == 0 {
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

    // The summary of block `k` of `b`, in one scan, pushed to `bw`, `bt`, `bpw`, `bimp` and `bst`, a private
    // slot's writes aside but in `bpw`:
    // - `bw`: the alias classes it writes (`write_bits`);
    // - `bt`: the type tags it writes (bit 0: an untagged write, all of them; `write_tag`);
    // - `bpw`: whether it writes a private slot's memory (`privates`);
    // - `bst`: its plain stores whose class is an exclusive parameter's, and its direct calls with an
    //   argument of an exclusive class, which `fields_apart` checks by their spans (`call_apart`);
    // - `bimp`: the classes its other writes touch (`bw`'s, those stores' and those arguments' aside).
    fn block_writes(self: &mut Self, pk: &Package, b: &Body, k: u32) {
        let bk = b.blocks[k as usize];
        let mut w: u64 = 0;
        let mut tg: u16 = 0;
        let mut pw = false;
        let mut imp: u64 = 0;
        for i in bk.start..bk.start + bk.len {
            let t = b.insts[i as usize];
            let mem = t.op == O_STORE || t.op == O_MEMCPY || t.op == O_MEMSET;
            if self.private(t) {
                pw = pw || mem;
                continue;
            }
            let wr = writes(pk, b, t);
            if wr {
                w |= self.write_bits(pk, b, i);
                let g = write_tag(pk, b, t);
                // A volatile store, like any write but a store or a call, may touch any tag.
                if g < TBAA_TAGS {
                    tg |= if t.op == O_STORE && (t.aux & MEM_VOLATILE) == 0 || t.op == O_CALL {
                        1u16 << g as u16
                    } else {
                        1u16
                    };
                }
            }
            let other = self.sbits & ~self.member(i);
            if mem {
                let c = self.acc(b, i, t.a);
                if t.op == O_STORE && (t.aux & MEM_VOLATILE) == 0 && c >= CL_NOALIAS && c < CL_MANY {
                    self.bst.push(i);
                    imp |= other;
                } else {
                    imp |= class_bit(c) | other;
                }
            } else if wr && t.op == O_CALL {
                imp |= class_bit(CL_OTHER) | other | self.owned_args(pk, b, i, t);
                let mut precise = false;
                for q in 0..t.aux as u32 {
                    // The argument's access class, as `write_bits` takes it (`acc`).
                    let c = self.acc(b, i, b.pool[(t.c + q) as usize]);
                    if c >= CL_NOALIAS && c < CL_FROZEN && (class_bit(c) & self.sbits) == 0 {
                        precise = true;
                    } else {
                        imp |= class_bit(c);
                    }
                }
                if precise {
                    self.bst.push(i);
                }
            } else if wr {
                imp |= class_bit(CL_OTHER) | other | self.arg_bits(pk, b, i, t);
            }
        }
        self.bw.push(w);
        self.bt.push(tg);
        self.bpw.push(pw);
        self.bimp.push(imp);
    }

    // The alias classes write `i` of `b` touches (`class_bit`): a store's, a copy's or a fill's access
    // class (`acc`); CL_OTHER for any other write, which reaches no exclusive parameter's referent; and,
    // outside a scope's copy, the scope's class too. A free writes none.
    fn write_bits(self: &Self, pk: &Package, b: &Body, i: u32) u64 {
        let t = b.insts[i as usize];
        if call_alloc(pk, b, t) == ALLOC_FREE {
            return 0;
        }
        let c = if t.op == O_STORE || t.op == O_MEMCPY || t.op == O_MEMSET {
            self.acc(b, i, t.a)
        } else {
            CL_OTHER
        };
        return class_bit(c) | self.sbits & ~self.member(i) | self.arg_bits(pk, b, i, t);
    }

    // The classes write `i` (`t`) of `b` touches for a read that may lie outside the copies of the scopes it
    // writes through: `write_bits`, and for each scope class it writes, its roots' base's (`under_bits`).
    // A read outside a copy reaches the root's bytes through that class, and the copy's own accesses folded
    // onto the base's address are of it too.
    fn read_bits(self: &Self, pk: &Package, b: &Body, i: u32, t: Inst) u64 {
        let mut out = self.write_bits(pk, b, i);
        if self.sbits == 0 || out == 0 {
            return out;
        }
        if t.op == O_STORE || t.op == O_MEMCPY || t.op == O_MEMSET {
            out |= self.under_bits(self.acc(b, i, t.a));
        } else if t.op == O_CALL || t.op == O_CALLIND {
            for q in 0..t.aux as u32 {
                out |= self.under_bits(self.acc(b, i, b.pool[(t.c + q) as usize]));
            }
        }
        return out;
    }

    // The classes a write through an address of class `c` touches: `c`'s; for a scope's class its roots'
    // base's too, since the bytes the copy writes through a root are the ones the accesses outside it, and
    // its own folded onto the base's address, reach through that class (every class for a root of no
    // known base).
    const fn under_bits(self: &Self, c: u8) u64 {
        let mut x = c;
        let mut out: u64 = 0;
        // Each step goes from a scope class to its roots' base; a cycle of roots ends with every class.
        for _ in 0..CL_MANY {
            if x >= CL_MANY || (class_bit(x) & self.sbits) == 0 {
                return out | class_bit(x);
            }
            out |= class_bit(x);
            x = self.cbase[x as usize];
        }
        return class_bit(CL_MANY);
    }

    // The classes call `t`, instruction `i` of `b`, may write through its arguments (a class a callee does
    // not let escape stays, `escaped`), the owned buffers it reaches through them too (`owned_args`); none
    // for any other instruction.
    fn arg_bits(self: &Self, pk: &Package, b: &Body, i: u32, t: Inst) u64 {
        let mut out: u64 = 0;
        if t.op == O_CALL || t.op == O_CALLIND {
            for q in 0..t.aux as u32 {
                out |= class_bit(self.acc(b, i, b.pool[(t.c + q) as usize]));
            }
            out |= self.owned_args(pk, b, i, t);
        }
        return out;
    }

    // The owned buffers' classes (`obits`) call `t`, instruction `i` of `b`, reaches through an argument
    // into its parameter's referent: each whose field's bytes meet the bytes the callee reaches through that
    // argument (`Sym.span`, at the argument's constant offset), every one of that parameter when the offset
    // or the span is unknown. Only a load of the field reaches the buffer while the reference lives.
    fn owned_args(self: &Self, pk: &Package, b: &Body, i: u32, t: Inst) u64 {
        if self.obits == 0 || t.op != O_CALL && t.op != O_CALLIND {
            return 0;
        }
        let sy = if t.op == O_CALL {
            pk.syms[b.syms[t.a as usize] as usize].span
        } else {
            NONE
        };
        let mut out: u64 = 0;
        for q in 0..t.aux as u32 {
            let v = b.pool[(t.c + q) as usize];
            let c = self.base_at(self.class(v), self.member(i), self.sbits);
            if c < CL_NOALIAS || c >= CL_FROZEN {
                continue;
            }
            let s = if sy != NONE && q as u64 < pk.spans[sy as usize] {
                pk.spans[(sy + 1 + q) as usize]
            } else {
                SPAN_ANY
            };
            if s == SPAN_NONE {
                continue;
            }
            let k = (c - CL_NOALIAS) as u32;
            let (pa, o) = self.param_at(b, v);
            let known = s != SPAN_ANY && pa == k && o != OFF_ANY;
            let mut m = self.obits;
            // Each step clears one bit: at most 64 steps.
            while m != 0 {
                let cb = m.trailing_zeros() as u64;
                m &= m - 1;
                let idx = (cb - 1) as usize;
                if self.oparam[idx] != k {
                    continue;
                }
                let f = self.ooff[idx] as i64;
                if !known || span_lo(s) + o < f + pk.ptr_bytes as i64 && f < span_hi(s) + o {
                    out |= 1u64 << cb;
                }
            }
        }
        return out;
    }

    // Whether load `t` of class bit `cls`, an exclusive parameter's, reads no byte loop
    // `h` writes: every write of that class in the loop is a plain store through the load's address value
    // at a constant range apart from the load's (another field of the parameter's referent), or a call
    // whose arguments of that class reach only bytes apart from the load's (`call_apart`).
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
            let st = b.insts[si as usize];
            if st.op == O_CALL {
                if !self.call_apart(pk, b, si, st, t.a, lo, hi) {
                    return false;
                }
                continue;
            }
            if (class_bit(self.loop_acc(si, h)) & cls) == 0 {
                continue;
            }
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
        self.slot_escapes(b);
        // The classes of the loads' and stores' accesses before the walk forwards their addresses: a
        // parameter an inlined body's accesses go through, a scope's, becomes the caller's pointer.
        fill(&mut self.acls, b.insts.len(), CL_MANY);
        fill(&mut self.aobj, b.insts.len(), NONE);
        frozen(b, &mut self.frz, &mut self.frz_ptr);
        for i in 0..b.insts.len() {
            let op = b.insts[i].op;
            if op == O_LOAD || op == O_STORE {
                self.aobj[i] = self.object(pk, b, b.insts[i].a);
            }
            if op == O_LOAD && (self.frz[i] || self.rodata(pk, i as u32)) {
                self.acls[i] = CL_FROZEN;
            } else if op == O_LOAD || op == O_STORE {
                self.acls[i] = self.acc(b, i as u32, b.insts[i].a);
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
            if self.inner[k] != NONE {
                self.block_writes(pk, b, k as u32);
            } else {
                self.bw.push(0);
                self.bt.push(0);
                self.bpw.push(false);
                self.bimp.push(0);
            }
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
        self.unbiased.clear_keeping(KEEP_SLOTS);
    }

    // The entry parameters that point at a by-value aggregate of at most PSLOT_MAX bytes (the body's own copy)
    // that only loads and stores at constant offsets and copies of a constant size address, and that a store
    // or a copy in a loop writes: each becomes a slot that a new entry block copies the aggregate into and
    // passes to the old one, for that parameter, which promotion then turns into values: a loop a tail
    // recursion made carries them in registers. A parameter of the block the entry jumps to alone (an entry
    // a copy without constant parameters added, `drop_params`) that the jump passes one of them stands for
    // it. Once per body; not when an edge enters the entry. Whether any did.
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
        // The jump that ends the entry when it enters a block no other edge enters: its parameters that
        // receive entry parameters (`fwd`: per entry parameter, that block parameter or VNONE).
        let mut fwd = Vector::<Value>::new();
        fill(&mut fwd, np as usize, VNONE);
        let tm = b.insts[(e.start + e.len - 1) as usize];
        let mut fj = NONE;
        if tm.op == O_JMP {
            let s = b.edge_target(tm.a);
            let mut preds: u32 = 0;
            for k in 0..b.blocks.len() {
                let bk = b.blocks[k];
                if bk.len == 0 {
                    continue;
                }
                b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut self.edges);
                for x in 0..self.edges.len() {
                    preds += (b.edge_target(self.edges[x]) == s) as u32;
                }
            }
            if preds == 1 && s != 0 {
                fj = e.start + e.len - 1;
                for q in 0..b.edge_nargs(tm.a) {
                    let v = b.edge_arg(tm.a, q);
                    if (v & VPARAM) != 0 && (v & ~VPARAM) >= e.param_start && (v & ~VPARAM) < e.param_start + np && fwd[((v & ~VPARAM) - e.param_start) as usize] == VNONE {
                        fwd.set(((v & ~VPARAM) - e.param_start) as usize, b.param(s, q));
                    } else if (v & VPARAM) != 0 && (v & ~VPARAM) >= e.param_start && (v & ~VPARAM) < e.param_start + np {
                        // Passed twice: two names of one aggregate.
                        cand &= ~(1u64 << ((v & ~VPARAM) - e.param_start) as u64);
                    }
                }
            }
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
                let a = ast::pick(t.op == O_STORE || t.op == O_MEMCPY, t.a, VNONE);
                let k = entry_of(e, &fwd, a);
                if k != NONE {
                    looped |= 1u64 << k as u64;
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
                        let v = b.edge_arg(self.edges[x], q);
                        // The entry's jump passing a parameter on to its stand-in is no use of it.
                        if i as u32 != fj || entry_of(e, &fwd, v) == NONE || fwd[entry_of(e, &fwd, v) as usize] != b.param(
                            b.edge_target(self.edges[x]),
                            q,
                        ) {
                            self.fuses.push(v);
                        }
                    }
                }
            }
            for u in 0..self.fuses.len() {
                let v = self.fuses[u];
                let k = entry_of(e, &fwd, v);
                if k == NONE {
                    continue;
                }
                let ok = t.op == O_LOAD && t.a == v || t.op == O_STORE && t.a == v && t.b != v || t.op == O_MEMCPY && t.a == v != (t.b == v) && int_bits(
                    b,
                    t.c,
                ).is_some();
                if !ok {
                    cand &= ~(1u64 << k as u64);
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
        let it = ast::pick(pk.ptr_bytes == 8, T_I64, T_I32);
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
    // pass in registers (but `aggregs`), that only loads outside cold blocks read: their loads may move to the entry's
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
    // instructions that touch no memory and loads of the body's own slots) to the address of an aggregate result the
    // target returns in registers (`Package.ret_regs`, `ret_part`): each 8-byte chunk (of 1, 2, 4 or 8 bytes) whose every leaf byte (of the result's
    // layout; the others are padding) two or more of the run write, each byte once, one of them with an
    // integer, is one store of their values joined (bits of a float as an integer, a fill's bytes as a
    // constant, each shifted to its offset, padding 0). The targets return such a chunk in one integer
    // register, which the code generator moves the store's value into (`ret_stores`). Whether it did.
    fn ret_chunks(self: &mut Self, pk: &Package, b: &mut Body, blk: u32, i: u32) bool {
        let rt = b.pool[b.sig as usize + 2];
        if b.sig == NONE || (rt & AGG) == 0 || b.pool[(rt & ~AGG) as usize] > pk.ret_regs {
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
            let ct = int_type(cs);
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
                            Inst { op: O_BITCAST, ty: int_type(sz), aux: 0, a: x, b: VNONE, c: VNONE },
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
    // register (an aggregate of at most `aggregs` bytes), which the code generator takes for the chunk's load (`place::parts_taken`). The
    // parameter's bytes are a copy nothing writes: one load at the entry's start serves each part
    // (`aggload`). Whether it did.
    fn agg_chunk(self: &mut Self, pk: &Package, b: &mut Body, blk: u32, i: u32, u: Inst, k: u32) bool {
        let lay = (b.pool[(b.sig + 3 + k) as usize] & ~AGG) as usize;
        let size = b.pool[lay];
        if size > self.aggregs {
            return false;
        }
        let c = u.c / 8;
        let cs = (size - 8 * c).min(8);
        let s = type_bytes(u.ty, pk.ptr_bytes);
        let o = u.c - 8 * c;
        if k >= 32 || u.c >= 16 || (self.aggint >> (2 * k + c) as u64 & 1) == 0 || (cs & cs - 1) != 0 || s >= cs || o + s > cs || is_vec(
            u.ty,
        ) || u.ty == T_PTR {
            return false;
        }
        let ct = int_type(cs);
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
        let it = int_type(s);
        if s < cs {
            x = self.before(b, blk, i, Inst { op: O_TRUNC, ty: it, aux: 0, a: x, b: VNONE, c: VNONE });
        }
        if is_float(u.ty) {
            x = self.before(b, blk, i, Inst { op: O_BITCAST, ty: u.ty, aux: 0, a: x, b: VNONE, c: VNONE });
        }
        self.repl[i as usize] = x;
        return true;
    }

    // `rslot`: per slot of `b`, the call whose aggregate result the target returns in registers
    // (`Package.ret_regs`) it receives, when that
    // call is the only use of the slot's addresses but loads (not volatile) of them; NONE else. `rload`
    // emptied.
    fn result_slots(self: &mut Self, pk: &Package, b: &Body) {
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
                    let call = (t.op == O_CALL || t.op == O_CALLIND) && (b.pool[t.b as usize + 2] & AGG) != 0 && b.pool[(b.pool[t.b as usize + 2] & ~AGG) as usize] <= pk.ret_regs && b.pool[(t.c + b.pool[t.b as usize]) as usize] == v;
                    let mut once = true;
                    for r in 0..nu {
                        once = once && (r == q || self.ops[(u0 + r) as usize] != v);
                    }
                    self.rslot[s] = ast::pick(call && once && self.rslot[s] == NONE, i, bad);
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
        let ct = int_type(cs);
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
            x = self.before(b, blk, i, Inst { op: O_TRUNC, ty: int_type(sz), aux: 0, a: x, b: VNONE, c: VNONE });
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
        self.made.clear_keeping(KEEP_SLOTS);
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
        self.pure.clear_keeping(KEEP_SLOTS);
        self.mem.clear_keeping(KEEP_SLOTS);
        self.cond.clear_keeping(KEEP_SLOTS);
        self.rel.clear_keeping(KEEP_SLOTS);
        self.ub.clear_keeping(KEEP_SLOTS);
        self.eqs.clear_keeping(KEEP_SLOTS);
        self.log.truncate(0);
        self.places.truncate(0);
        fill(&mut self.bwrites, nb, 0);
        fill(&mut self.rmark, nb, NONE);
        fill(&mut self.jat, nb, NONE);
        fill(&mut self.jcnt, nb, 0);
        self.jfacts.truncate(0);
        self.aggregs = pk.arg_copy.min(16);
        self.aggp = self.agg_params(b);
        self.aggload = [NONE; 64];
        self.result_slots(pk, b);
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
        self.rewrote = false;
        let mut changed = self.param_cycles(b);
        // Preorder over the dominator tree: depth << 33 | block << 1 enters a block, n << 33 | 1 closes its
        // scope at log length n.
        self.stack.truncate(0);
        self.stack.push(0);
        // Each block is entered and left once.
        while self.stack.len() != 0 {
            let x = self.stack.pop().unwrap();
            if (x & 1) != 0 {
                self.unwind((x >> 33) as usize);
                continue;
            }
            let k = (x >> 1 & 0xFFFFFFFF) as usize;
            let dep = (x >> 33) as usize;
            self.stack.push(self.log.len() as u64 << 33 | 1);
            // The places its dominator knew last; those of a state no longer current are not found.
            self.recent.truncate(0);
            for r in 0..RECENT_MAX {
                let at = if k == 0 {
                    NONE
                } else {
                    self.end_recent[(dep - 1) * RECENT_MAX + r]
                };
                if at == NONE {
                    break;
                }
                self.recent.push(at);
            }
            if k != 0 && self.pred_at[k + 1] - self.pred_at[k] == 1 && self.preds[self.pred_at[k] as usize] == self.idom[k] {
                let d = (dep - 1) * TBAA_TAGS;
                for g in 0..TBAA_TAGS {
                    unsafe self.tstate[g] = self.end_state[d + g];
                }
                self.pstate = self.end_pstate[dep - 1];
                // Its parameters are its one edge's arguments.
                changed = self.forward_params(b, k as u32) || changed;
                // Its one edge decides its dominator's branch condition here and below.
                let t = term(b, self.idom[k]);
                if t.op == O_BR && b.edge_target(t.b) != b.edge_target(t.c) && int_bits(b, t.a).is_none() {
                    let taken: u32 = ast::pick(b.edge_target(t.b) == k as u32, 1, 0);
                    self.enter(LOG_COND, t.a, taken);
                    self.cond_parts(pk, b, t.a, taken != 0, MIN_DEPTH);
                }
            } else if k != 0 {
                // Several edges enter: the tags no block between its dominator and it writes keep the
                // dominator's state; the others, and the untagged accesses when any is written, a new one.
                changed = self.same_args(b, k as u32) || changed;
                self.join_in(pk, b, k as u32);
                let w = self.between_writes(k as u32);
                states += 1;
                self.pstate = states;
                let d = (dep - 1) * TBAA_TAGS;
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
                changed = self.offset_params(b, k as u32) || changed;
                changed = self.offset_test(pk, b, k as u32) || changed;
                self.param_bounds(pk, b, k as u32);
            }
            self.pend.truncate(0);
            let mut called = false;
            for i in bk.start..bk.start + bk.len {
                // A write starts a new state for its tag's accesses and the untagged ones; an untagged
                // write, for all.
                let t = b.insts[i as usize];
                let g = write_tag(pk, b, t);
                let pbefore = self.pstate;
                // An access of a private slot's memory has states of its own: no other access touches it.
                let private = self.private(t);
                self.prior = if private {
                    pbefore
                } else if g < TBAA_TAGS {
                    unsafe self.tstate[g]
                } else {
                    self.tstate[0]
                };
                self.pprior = pbefore;
                self.tprior = self.tstate[0];
                let wr = g < TBAA_TAGS && writes(pk, b, t);
                if wr {
                    states += 1;
                    if private {
                        self.pstate = states;
                    } else if g == 0 || (t.aux & MEM_VOLATILE) != 0 {
                        self.tbefore = self.tstate;
                        self.tstate = [states; TBAA_TAGS];
                    } else {
                        self.tbefore = self.tstate;
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
                    if u.op == O_SELECT && self.repl[i as usize] == VNONE && self.select_loads(pk, b, k as u32, i) {
                        changed = true;
                    }
                    if u.op == O_SELECT && self.repl[i as usize] == VNONE && is_int(u.ty) && u.ty != T_PTR && u.ty != T_I128 {
                        changed = self.select_step(b, k as u32, i) || changed;
                    }
                    // A select on a condition the branches before the block decide is that side.
                    if b.insts[i as usize].op == O_SELECT && self.repl[i as usize] == VNONE {
                        let d = self.cond_at(b, k as u32, u.a, THREAD_DEPTH);
                        if d != 0 {
                            self.repl[i as usize] = ast::pick(d == 1, u.b, u.c);
                            changed = true;
                        }
                    }
                    // A comparison the branches before the block decide, returned: that constant.
                    if u.op == O_RET && is_op(b, u.a, O_ICMP) {
                        let d = self.cond_at(b, k as u32, u.a, THREAD_DEPTH);
                        if d != 0 {
                            let c = self.constant(b, b.type_of(u.a), ast::pick(d == 1, 1u64, 0u64));
                            b.insts.index_mut(i as usize).a = c;
                            changed = true;
                        }
                    }
                    if u.op == O_BR && self.repl[i as usize] == VNONE && u.b != u.c {
                        changed = self.edge_selects(b, i) || changed;
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
                        if !private {
                            self.tstate = self.tbefore;
                        }
                        self.pstate = pbefore;
                        self.unstored = self.unstored || self.inner[k] != NONE;
                    } else if !private && wr {
                        self.carry(pk, b, i);
                    }
                    if self.repl[i as usize] == VNONE {
                        changed = self.overwrite(pk, b, i) || changed;
                    }
                } else {
                    changed = true;
                }
            }
            if self.end_pstate.len() == dep {
                self.end_state.resize_default((dep + 1) * TBAA_TAGS);
                self.end_recent.resize_default((dep + 1) * RECENT_MAX);
                self.end_pstate.push(0);
            }
            for g in 0..TBAA_TAGS {
                self.end_state[dep * TBAA_TAGS + g] = unsafe self.tstate[g];
            }
            for r in 0..RECENT_MAX {
                self.end_recent[dep * RECENT_MAX + r] = if r < self.recent.len() {
                    self.recent[r]
                } else {
                    NONE
                };
            }
            self.end_pstate[dep] = self.pstate;
            // The children that join edges into parameters pop last, in reverse postorder: such a join comes after
            // the blocks before it (`join_in`).
            let (k0, k1) = (self.kid_at[k], self.kid_at[k + 1]);
            for late in 0..2u32 {
                for c in 0..k1 - k0 {
                    let x = self.kids[ast::pick(late == 0, k1 - 1 - c, k0 + c) as usize];
                    let np = self.pred_at[x as usize + 1] - self.pred_at[x as usize];
                    let join = b.blocks[x as usize].param_len != 0 && np >= 2 && np <= JOIN_PREDS && self.inner[x as usize] != x;
                    if join == (late == 0) {
                        self.stack.push((dep + 1) as u64 << 33 | x as u64 << 1);
                    }
                }
            }
        }
        return changed || self.rewrote;
    }

    // Instruction `i`, which stays, in the walk's order within its block: a store drops each earlier one
    // of `pend` it writes all bytes of through the same address (no instruction between reads memory or
    // leaves the block), then joins `pend`; a fill of at most FILL_MAX bytes joins an empty `pend`, and goes
    // once the stores through its address after it wrote each of its bytes (`fillc`); a call keeps the
    // stores it cannot read: the ones of a class it does not reach, and, for a call that comes back (no
    // `FX_STALL`), the ones whose bytes it does not read (`call_apart`); any other instruction but a pure one
    // that cannot trap empties `pend`. Whether it dropped any.
    fn overwrite(self: &mut Self, pk: &Package, b: &Body, i: u32) bool {
        let t = b.insts[i as usize];
        if pure_op(t.op) && !tls_addr(pk, b, t) && (t.op < O_SDIV || t.op > O_UREM) {
            return false;
        }
        if t.op == O_CALL || t.op == O_CALLIND {
            // A call that comes back (no `FX_STALL`: a panic may unwind to code that reads those bytes) keeps
            // the stores into an exclusive parameter's referent whose class it does not reach (`carry`'s
            // test: no pointer it holds points there), and those of bytes it does not read (`call_apart`).
            let wb = self.write_bits(pk, b, i) | self.sbits;
            let back = t.op == O_CALL && (pk.syms[b.syms[t.a as usize] as usize].fx & FX_STALL) == 0;
            let mut x: usize = 0;
            // Each step keeps or drops one entry.
            while x < self.pend.len() {
                let j = self.pend[x];
                let s = b.insts[j as usize];
                if s.op == O_MEMSET {
                    let _ = self.pend.swap_remove(x);
                    continue;
                }
                let c = self.acc(b, j, s.a);
                let lo = (s.c as i32) as i64;
                if back && (c >= CL_NOALIAS && c < CL_FROZEN && (class_bit(c) & wb) == 0 || self.call_apart(
                    pk,
                    b,
                    i,
                    t,
                    self.val(s.a),
                    lo,
                    lo + type_bytes(b.type_of(s.b), pk.ptr_bytes) as i64,
                )) {
                    x += 1;
                } else {
                    let _ = self.pend.swap_remove(x);
                }
            }
            return false;
        }
        let n = if t.op == O_MEMSET && (t.aux & MEM_VOLATILE) == 0 {
            int_bits(b, t.c).unwrap_or(0)
        } else {
            0
        };
        if n != 0 && n <= FILL_MAX as u64 {
            self.pend.truncate(0);
            self.pend.push(i);
            fill(&mut self.fillc, (n as usize + 63) / 64, 0);
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
            if s.op == O_MEMSET {
                // The fill's bytes this store writes; all of them: it goes.
                let fl = int_bits(b, s.c).unwrap_or(0) as i64;
                if self.repl[j as usize] != VNONE || self.val(s.a) != a {
                    x += 1;
                    continue;
                }
                // Each step marks one byte, at most FILL_MAX.
                for q in lo.max(0)..hi.min(fl) {
                    self.fillc[(q / 64) as usize] |= 1u64 << (q % 64) as u64;
                }
                let mut all = true;
                for q in 0..fl {
                    all = all && (self.fillc[(q / 64) as usize] >> (q % 64) as u64 & 1) != 0;
                }
                if all {
                    self.repl[j as usize] = DROPPED;
                    dropped = true;
                    let _ = self.pend.swap_remove(x);
                } else {
                    x += 1;
                }
                continue;
            }
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
            // The fill stays: the cap bounds the stores. A fill joins an empty `pend`, so it is the only one.
            let mut fp = NONE;
            for x in 0..self.pend.len() {
                if b.insts[self.pend[x] as usize].op == O_MEMSET {
                    fp = self.pend[x];
                }
            }
            self.pend.truncate(0);
            if fp != NONE {
                self.pend.push(fp);
            }
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

    // The scoped table `LOG_*` `t` names.
    fn table(self: &mut Self, t: u8) &mut Map<u64, u32> {
        return if t == LOG_PURE {
            &mut self.pure
        } else if t == LOG_MEM {
            &mut self.mem
        } else if t == LOG_COND {
            &mut self.cond
        } else if t == LOG_REL {
            &mut self.rel
        } else if t == LOG_EQ {
            &mut self.eqs
        } else {
            &mut self.ub
        };
    }
    fn unwind(self: &mut Self, to: usize) {
        // Each entry undoes one insertion.
        while self.log.len() > to {
            let (table, key, prev) = self.log.pop().unwrap();
            let m = self.table(table);
            if prev == NONE {
                let _ = m.remove(&key);
            } else {
                m.insert(key, prev);
            }
        }
    }

    fn enter(self: &mut Self, table: u8, key: u64, v: u32) {
        let m = self.table(table);
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
                v = self.side_select(pk, b, k, i, b.params[(jb.param_start + q) as usize], t.a, x, y);
            }
            if only {
                self.prepl[(jb.param_start + q) as usize] = v;
            }
            args.push(v);
        }
        return b.edge(j, &args);
    }

    // Branch `t`, instruction `i` ending block `k`, whose false side enters a block `x` of no parameters that
    // `k` alone enters along an edge of no arguments, whose code but constants is one instruction `speculated`
    // allows, and which branches to `t`'s true side along an edge of the same arguments: one branch on the `or`
    // of the two conditions, `x`'s code at the end of `k` (`speculate`), then the same along `x`'s false side
    // (LLVM's FoldBranchToCommonDest). A chain of `==` tests of one value is then an `or` tree (`bit_set`).
    // `x`, which no edge enters, jumps to its false side, so the walk's facts and parameters below it hold.
    // The branch; `t` when none merges.
    fn common_true(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32, t0: Inst) Inst {
        let mut t = t0;
        let mut from = k;
        let ty = b.type_of(t.a);
        // Each step merges one more block of the chain.
        for _ in 0..b.blocks.len() {
            let x = b.edge_target(t.c);
            let xb = b.blocks[x as usize];
            if x == k || x == b.edge_target(t.b) || b.edge_nargs(t.c) != 0 || xb.param_len != 0 || self.pred_at[x as usize + 1] - self.pred_at[x as usize] != 1 || self.preds[self.pred_at[x as usize] as usize] != from || (xb.flags & ~b.blocks[k as usize].flags & BLOCK_RARE) != 0 {
                break;
            }
            let u = term(b, x);
            if u.op != O_BR || b.edge_target(u.b) != b.edge_target(t.b) || b.edge_target(u.c) == b.edge_target(t.b) || self.speculated(
                pk,
                b,
                k,
                x,
            ) > 1 {
                break;
            }
            let mut same = true;
            for q in 0..b.edge_nargs(t.b) {
                same = same && self.val(b.edge_arg(u.b, q)) == b.edge_arg(t.b, q);
            }
            let c = self.val(u.a);
            if !same || is_vec(ty) || b.type_of(c) != ty {
                break;
            }
            self.speculate(b, k, x);
            for q in 0..b.edge_nargs(u.c) {
                let at = (u.c + 2 + q) as usize;
                b.pool[at] = self.val(b.pool[at]);
            }
            let mut args = Vector::<Value>::with_capacity(b.edge_nargs(u.c) as usize);
            for q in 0..b.edge_nargs(u.c) {
                args.push(b.edge_arg(u.c, q));
            }
            let e = b.edge(b.edge_target(u.c), &args);
            b.insts[(xb.start + xb.len - 1) as usize] = jump(e);
            let v = self.placed(b, k, i, Inst { op: O_OR, ty: ty, aux: 0, a: t.a, b: c, c: VNONE }, false);
            let r = simplify(pk, b, v);
            t = Inst { op: O_BR, ty: t.ty, aux: t.aux, a: ast::pick(r != VNONE, r, v), b: t.b, c: u.c };
            from = x;
        }
        return t;
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
        return self.side_select(pk, b, k, i, ty, t.a, x, y);
    }

    // The select of `x` and `y` of type `ty` on condition `c`, with instruction `i`'s location, at the end of
    // block `k` (`hoisted`): its operands are final, so it is simplified now, as no later walk may see it
    // (the rewalk's own). The value it is.
    fn side_select(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32, ty: u8, c: Value, x: Value, y: Value) Value {
        let v = b.push_at(Inst { op: O_SELECT, ty: ty, aux: 0, a: c, b: x, c: y }, i);
        self.repl.push(VNONE);
        self.frepl.push(VNONE);
        self.moved.push(true);
        self.blk_of.push(k);
        self.hoisted.push(k as u64 << 32 | v as u64);
        let r = simplify(pk, b, v);
        return ast::pick(r != VNONE, r, v);
    }

    // Branch `t`, instruction `i` ending block `k`, whose sides each enter a block of no parameters that `k`
    // alone enters along an edge of no arguments, the two the same instructions but for 1 to MAX_SELECTS
    // operands from outside both (integers of up to 64 bits, pointers or scalar floats): the first side, its
    // differing operands the selects on the condition at the end of `k` (`side_select`), as LLVM's
    // SimplifyCFG sinks the code two predecessors share. A choice of two aggregates copies once. The edge
    // `k` then jumps along; NONE when not.
    fn twin_sides(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32, t: Inst) u32 {
        let s0 = b.edge_target(t.b);
        let s1 = b.edge_target(t.c);
        if s0 == s1 || s0 == k || s1 == k || b.edge_nargs(t.b) != 0 || b.edge_nargs(t.c) != 0 {
            return NONE;
        }
        let x = b.blocks[s0 as usize];
        let y = b.blocks[s1 as usize];
        let rare = (x.flags | y.flags) & ~b.blocks[k as usize].flags & BLOCK_RARE;
        let one0 = self.pred_at[s0 as usize + 1] - self.pred_at[s0 as usize] == 1;
        let one1 = self.pred_at[s1 as usize + 1] - self.pred_at[s1 as usize] == 1;
        if rare != 0 || !one0 || !one1 || x.len != y.len || x.len > TWIN_MAX || x.param_len != 0 || y.param_len != 0 {
            return NONE;
        }
        // Each difference: the first side's instruction << 2 | its operand (0 to 2).
        let mut diffs = StaticVector::<u32, 2>::new();
        for j in 0..x.len {
            let s = b.insts[(x.start + j) as usize];
            let u = b.insts[(y.start + j) as usize];
            if s.op != u.op || s.ty != u.ty || s.aux != u.aux {
                return NONE;
            }
            let f = op_info(s.op).form;
            if f == F_JMP {
                if b.edge_target(s.a) != b.edge_target(u.a) {
                    return NONE;
                }
                for q in 0..b.edge_nargs(s.a) {
                    if !twin_val(x, y, b.edge_arg(s.a, q), b.edge_arg(u.a, q)) {
                        return NONE;
                    }
                }
                continue;
            }
            if f > F_STORE && f != F_OVF && f != F_RET {
                return NONE;
            }
            for q in 0..3u32 {
                let (v, w, val) = if q == 0 {
                    (s.a, u.a, lv::operand_a(f))
                } else if q == 1 {
                    (s.b, u.b, lv::operand_b(f))
                } else {
                    (s.c, u.c, lv::operand_c(f))
                };
                if !val && v == w || val && twin_val(x, y, v, w) {
                    continue;
                }
                let ty = if val && v != VNONE && w != VNONE && b.type_of(v) == b.type_of(w) {
                    b.type_of(v)
                } else {
                    T_NONE
                };
                let sel = is_int(ty) && ty != T_I128 || ty == T_PTR || ty == T_F32 || ty == T_F64;
                if !sel || in_block(b, v & ~VFLAG, s0) || in_block(b, w & ~VFLAG, s1) || diffs.len() as u32 == MAX_SELECTS || f == F_RET {
                    return NONE;
                }
                diffs.push(j << 2 | q);
            }
        }
        if diffs.len() == 0 {
            return NONE;
        }
        for d in 0..diffs.len() {
            let at = (x.start + (diffs[d] >> 2)) as usize;
            let q = diffs[d] & 3;
            let s = b.insts[at];
            let u = b.insts[(y.start + (diffs[d] >> 2)) as usize];
            let (v, w) = if q == 0 {
                (s.a, u.a)
            } else if q == 1 {
                (s.b, u.b)
            } else {
                (s.c, u.c)
            };
            let c = self.side_select(pk, b, k, i, b.type_of(v), t.a, self.val(v), self.val(w));
            if q == 0 {
                b.insts.index_mut(at).a = c;
            } else if q == 1 {
                b.insts.index_mut(at).b = c;
            } else {
                b.insts.index_mut(at).c = c;
            }
        }
        self.selected = true;
        return t.b;
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

    // Branch `t` ending block `k`, whose sides each enter a block without parameters that `k` alone enters:
    // each pure instruction that cannot trap of the first side (of its first COMMON_MAX) whose operands
    // come from `k` or a block dominating it, the second side computing it too (the same operation of the
    // same operands), moves to the end of `k`, where it enters the numbering's scope, so the second's is it
    // (LLVM's SimplifyCFG hoists what both sides of a branch start with, GVNHoist any of it). `x += 1` on
    // both sides then passes one value.
    fn hoist_common(self: &mut Self, pk: &Package, b: &mut Body, k: u32, t: Inst) {
        let s0 = b.edge_target(t.b);
        let s1 = b.edge_target(t.c);
        if s0 == s1 || s0 == k || s1 == k || b.edge_nargs(t.b) != 0 || b.edge_nargs(t.c) != 0 {
            return;
        }
        let x = b.blocks[s0 as usize];
        let y = b.blocks[s1 as usize];
        if x.param_len != 0 || y.param_len != 0 || self.pred_at[s0 as usize + 1] - self.pred_at[s0 as usize] != 1 || self.pred_at[s1 as usize + 1] - self.pred_at[s1 as usize] != 1 {
            return;
        }
        for i in x.start..x.start + (x.len - 1).min(COMMON_MAX) {
            let mut u = b.insts[i as usize];
            if self.moved[i as usize] || !pure_op(u.op) || u.op == O_ICONST || u.op == O_FCONST || u.op == O_WCONST || is_vec(
                u.ty,
            ) {
                continue;
            }
            let f = op_info(u.op).form;
            if f != F_UN && f != F_BIN && f != F_CMP && f != F_TRI && f != F_PTRADD {
                continue;
            }
            if lv::operand_a(f) {
                u.a = self.val(u.a);
            }
            if lv::operand_b(f) {
                u.b = self.val(u.b);
            }
            if lv::operand_c(f) {
                u.c = self.val(u.c);
            }
            if lv::operand_a(f) && !self.avail(u.a, k) || lv::operand_b(f) && !self.avail(u.b, k) || lv::operand_c(f) && !self.avail(
                u.c,
                k,
            ) || !speculable(pk, b, u) {
                continue;
            }
            let mut twin = false;
            for j in y.start..y.start + (y.len - 1).min(COMMON_MAX) {
                let mut w = b.insts[j as usize];
                if self.moved[j as usize] || w.op != u.op || w.ty != u.ty || w.aux != u.aux {
                    continue;
                }
                if lv::operand_a(f) {
                    w.a = self.val(w.a);
                }
                if lv::operand_b(f) {
                    w.b = self.val(w.b);
                }
                if lv::operand_c(f) {
                    w.c = self.val(w.c);
                }
                if w.a == u.a && w.b == u.b && w.c == u.c {
                    twin = true;
                    break;
                }
            }
            if !twin {
                continue;
            }
            b.insts[i as usize] = u;
            self.moved[i as usize] = true;
            self.blk_of[i as usize] = k;
            self.hoisted.push(k as u64 << 32 | i as u64);
            // In `k`'s scope now: the second side's numbers to it in this walk (no loop hoisting: its
            // operands may move later in the walk).
            let h = value_hash(b, u);
            self.enter(LOG_PURE, h, i);
        }
    }

    // Whether value `v` (VNONE: none) is defined in block `k` or one dominating it.
    fn avail(self: &Self, v: Value, k: u32) bool {
        if v == VNONE {
            return true;
        }
        let d = self.def_blk(v);
        return d != NONE && (d == k || self.dominates(d, k));
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
            b.insts[x as usize] = unguarded(t);
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

    // Comparison `c` as `x <s y` and whether `c` is its negation; `(VNONE, VNONE, _)` when `c` is no signed
    // order comparison of scalars (`as_ult`'s signed twin).
    const fn as_slt(b: &Body, c: Value) (Value, Value, bool) {
        if (c & (VPARAM | VFLAG)) != 0 || c == VNONE {
            return (VNONE, VNONE, false);
        }
        let t = b.insts[c as usize];
        if t.op != O_ICMP || is_vec(t.ty) || t.aux < C_SLT || t.aux > C_SGE {
            return (VNONE, VNONE, false);
        }
        return if t.aux == C_SLT {
            (t.a, t.b, false)
        } else if t.aux == C_SGE {
            (t.a, t.b, true)
        } else if t.aux == C_SGT {
            (t.b, t.a, false)
        } else {
            (t.b, t.a, true)
        };
    }

    // Whether integer `v` is at least 0 as a signed value here: its unsigned bound clears the sign bit.
    fn nonneg(self: &Self, pk: &Package, b: &Body, v: Value) bool {
        let ty = b.type_of(v);
        if !is_int(ty) || ty == T_I128 {
            return false;
        }
        let hi = self.ubound(pk, b, v, UB_DEPTH);
        return hi.is_some() && hi.unwrap() <= width_mask(ty, pk.ptr_bytes) >> 1;
    }

    // Condition `c`, `holds` on the edge into the scope (`order_facts`): each comparison of an `and` that holds
    // and of an `or` that fails holds or fails with it, `depth` deep.
    fn cond_parts(self: &mut Self, pk: &Package, b: &Body, c: Value, holds: bool, depth: u32) {
        if depth != 0 && (c & (VPARAM | VFLAG)) == 0 && c != VNONE && b.insts[c as usize].ty == T_I8 {
            let t = b.insts[c as usize];
            if t.op == O_AND && holds || t.op == O_OR && !holds {
                // Each part is decided as the whole (an overflow flag `o` of `o || p > n` fails).
                self.enter(LOG_COND, t.a, holds as u32);
                self.enter(LOG_COND, t.b, holds as u32);
                self.cond_parts(pk, b, t.a, holds, depth - 1);
                self.cond_parts(pk, b, t.b, holds, depth - 1);
                return;
            }
        }
        self.order_facts(pk, b, c, holds);
    }

    // Condition `c`, `holds` on the edge into the scope: `x <u y` decided, and with it `x <u u` for each value
    // `u` that `y` is at most (`upper_parts`).
    fn order_facts(self: &mut Self, pk: &Package, b: &Body, c: Value, holds: bool) {
        // An equality that holds here: its sides are one value below, each at most the other, and one
        // with a constant bounds the other from both sides.
        if (c & (VPARAM | VFLAG)) == 0 && b.insts[c as usize].op == O_ICMP && !is_vec(b.insts[c as usize].ty) {
            let t = b.insts[c as usize];
            if t.aux == C_EQ && holds || t.aux == C_NE && !holds {
                self.enter(LOG_EQ, eq_key(t.a, t.b), 1);
                if (t.a & VFLAG) == 0 && (t.b & VFLAG) == 0 && b.type_of(t.a) != T_I128 {
                    if int_bits(b, t.b).is_some() && int_bits(b, t.a).is_none() {
                        self.enter(LOG_UB, t.a, t.b << 1);
                        self.enter(LOG_UB, LB_KEY | t.a as u64, t.b << 1);
                        self.equal_const(pk, b, t.a, t.b);
                    } else if int_bits(b, t.a).is_none() {
                        self.note_le(t.a, t.b);
                        self.note_le(t.b, t.a);
                    }
                }
            }
            // An inequality that holds: a constant side moves the other's bound that equals it by one; two values
            // note each other (`NE_KEY`) for a later equality with a constant (`equal_const`).
            if (t.aux == C_NE && holds || t.aux == C_EQ && !holds) && (t.a & VFLAG) == 0 && (t.b & VFLAG) == 0 && is_int(
                b.type_of(t.a),
            ) && b.type_of(t.a) != T_I128 && int_bits(b, t.a).is_none() {
                if int_bits(b, t.b).is_some() {
                    self.not_bound(pk, b, t.a, int_bits(b, t.b).unwrap());
                } else {
                    self.enter(LOG_UB, NE_KEY | t.a as u64, t.b);
                    self.enter(LOG_UB, NE_KEY | t.b as u64, t.a);
                }
            }
            // `x != 0`: `x` is at least 1 (`lbound`), and so is `a` where `x` is `a >> k` (`i / 2 != 0`).
            if (t.aux == C_NE && holds || t.aux == C_EQ && !holds) && int_bits(b, t.b) == Some(0u64) && (t.a & VFLAG) == 0 {
                self.enter(LOG_UB, LB_KEY | t.a as u64, t.b << 1 | 1);
                if is_op(b, t.a, O_LSHR) && (b.insts[t.a as usize].a & VFLAG) == 0 {
                    self.enter(LOG_UB, LB_KEY | b.insts[t.a as usize].a as u64, t.b << 1 | 1);
                }
            }
        }
        let (mut x, mut y, mut neg) = Opt::as_ult(b, c);
        if x == VNONE {
            // `x <s y` with `x` at least 0 is `x <u y`; `x >=s y` with `y` at least 0 is `x >=u y`.
            let (sx, sy, sneg) = Opt::as_slt(b, c);
            // A constant side bounds the other as a signed value (`srange`), and both values of a maximum
            // bounded from above or of a minimum from below (`while i >= 0 && j >= 0` as `min(i, j) >= 0`).
            if sx != VNONE && (sx & VFLAG) == 0 && (sy & VFLAG) == 0 {
                let slt = holds != sneg;
                let ax = extreme_arms(b, sx, slt);
                let ay = extreme_arms(b, sy, !slt);
                let vs: [Value; 6] = [sx, ax.0, ax.1, sy, ay.0, ay.1];
                for j in 0..6usize {
                    let v = vs[j];
                    if v != VNONE && j < 3 && int_bits(b, sy).is_some() {
                        self.note_signed(pk, b, v, !slt, sy, ast::pick(slt, -1i32, 0i32));
                    }
                    if v != VNONE && j >= 3 && int_bits(b, sx).is_some() {
                        self.note_signed(pk, b, v, slt, sx, ast::pick(slt, 1i32, 0i32));
                    }
                }
                // A counter down from a value before its loop at least 0 here (`shv_le`).
                for j in 0..6usize {
                    if vs[j] != VNONE {
                        self.shv_le(pk, b, vs[j]);
                    }
                }
                // Two values: the smaller's bound from below bounds the larger, the larger's from above the
                // smaller, one more apart where strict (`i <s len - 2` with `i >= 0`: `len - 2 >= 1`).
                if int_bits(b, sx).is_none() && int_bits(b, sy).is_none() && type_bits(b.type_of(sx), pk.ptr_bytes) <= 64 {
                    let (lo, hi) = ast::pick(slt, (sx, sy), (sy, sx));
                    let d: i32 = ast::pick(slt, 1i32, 0i32);
                    let fl = switch self.ub.get(&(SLO_KEY | lo as u64)) {
                        Some(f) => *f,
                        None => NONE,
                    };
                    let fh = switch self.ub.get(&(SHI_KEY | hi as u64)) {
                        Some(f) => *f,
                        None => NONE,
                    };
                    if fl != NONE {
                        let (fc, fa) = (fl >> 2, (fl & 3) as i32 - 1);
                        if fa + d <= 2 {
                            self.note_signed(pk, b, hi, true, fc, fa + d);
                        }
                    }
                    if fh != NONE {
                        let (fc, fa) = (fh >> 2, (fh & 3) as i32 - 1);
                        if fa - d >= -1 {
                            self.note_signed(pk, b, lo, false, fc, fa - d);
                        }
                    }
                }
            }
            if sx == VNONE || (sx & VFLAG) != 0 || (sy & VFLAG) != 0 || !self.nonneg(
                pk,
                b,
                ast::pick(holds != sneg, sx, sy),
            ) {
                return;
            }
            x = sx;
            y = sy;
            neg = sneg;
        }
        let lt = holds != neg;
        self.enter(LOG_REL, rel_key(x, y), lt as u32);
        if lt {
            self.upper_parts(pk, b, x, y, MIN_DEPTH);
            // Both values of a maximum `select(u <u w, w, u)` are below what it is below (two tests
            // `i <u n && j <u n` merged into one).
            if (x & (VPARAM | VFLAG)) == 0 && is_op(b, x, O_SELECT) && !is_vec(b.type_of(x)) {
                let t = b.insts[x as usize];
                let (u, w, neg) = Opt::as_ult(b, t.a);
                if u != VNONE && (u == t.c && w == t.b && !neg || u == t.b && w == t.c && neg) {
                    self.enter(LOG_REL, rel_key(t.b, y), 1);
                    self.enter(LOG_REL, rel_key(t.c, y), 1);
                }
            }
        }
        if (x & VFLAG) == 0 && (y & VFLAG) == 0 && int_bits(b, x).is_none() && int_bits(b, y).is_none() {
            if lt {
                // Above a value, `y` is nonzero (`lbound`).
                self.enter(LOG_UB, NZ_KEY | y as u64, 1);
                self.note_le(x, y);
            } else {
                self.note_le(y, x);
            }
        }
        // A constant side bounds the other: `x <u k`, or `y <=u k` when `k <u y` fails; from below `k <u y`,
        // or `x >=u k` when `x <u k` fails (`lbound`).
        if lt && int_bits(b, y).is_some() && (x & VFLAG) == 0 {
            self.enter(LOG_UB, x, y << 1 | 1);
        } else if !lt && int_bits(b, x).is_some() && (y & VFLAG) == 0 {
            self.enter(LOG_UB, y, x << 1);
        }
        if lt && int_bits(b, x).is_some() && (y & VFLAG) == 0 {
            self.enter(LOG_UB, LB_KEY | y as u64, x << 1 | 1);
        } else if !lt && int_bits(b, y).is_some() && (x & VFLAG) == 0 {
            self.enter(LOG_UB, LB_KEY | x as u64, y << 1);
        }
    }

    // `x == c` (`c` a constant value) holds: each value the facts keep `x` at most (`note_le`) is at least `c`,
    // and equal to it where it is at most `x` too (`i == j`, then `i == 5`); a value the facts keep other than `x`
    // (`NE_KEY`) has its bound at `c` moved by one (`not_bound`).
    fn equal_const(self: &mut Self, pk: &Package, b: &Body, x: Value, c: Value) {
        let m = width_mask(b.type_of(x), pk.ptr_bytes);
        let cv = int_bits(b, c).unwrap() & m;
        for key in [UP_KEY, UP2_KEY] {
            let f = switch self.ub.get(&(key | x as u64)) {
                Some(f) => *f,
                None => VNONE,
            };
            if f == VNONE || f == x || (f & VFLAG) != 0 || int_bits(b, f).is_some() || b.type_of(f) != b.type_of(x) {
                continue;
            }
            if self.lbound(pk, b, f, 0).unwrap_or(0) < cv {
                self.enter(LOG_UB, LB_KEY | f as u64, c << 1);
            }
            let back = self.known_le(f, x);
            if back && self.ub.get(&(f as u64)).is_none() {
                self.enter(LOG_UB, f, c << 1);
            }
        }
        // As a signed value too: a counter down from a value before its loop then stays at most it unsigned
        // (`shv_le`: `a[i]` after a loop down to `i == 0` from `len - 1`).
        if type_bits(b.type_of(x), pk.ptr_bytes) <= 64 {
            self.note_signed(pk, b, x, true, c, 0);
            self.note_signed(pk, b, x, false, c, 0);
            self.shv_le(pk, b, x);
        }
        let y = switch self.ub.get(&(NE_KEY | x as u64)) {
            Some(f) => *f,
            None => VNONE,
        };
        if y != VNONE && b.type_of(y) == b.type_of(x) {
            self.not_bound(pk, b, y, cv);
        }
    }

    // `x != k` holds: a least value `k` of `x` becomes `k + 1`, a greatest `k - 1` (where the body holds that
    // constant: `known_const`).
    fn not_bound(self: &mut Self, pk: &Package, b: &Body, x: Value, k: u64) {
        let ty = b.type_of(x);
        let m = width_mask(ty, pk.ptr_bytes);
        let kv = k & m;
        if self.lbound(pk, b, x, UB_DEPTH) == Some(kv) && kv < m {
            let c = self.known_const(b, ty, kv + 1);
            if c != NONE {
                self.enter(LOG_UB, LB_KEY | x as u64, c << 1);
            }
        }
        if self.ubound(pk, b, x, UB_DEPTH) == Some(kv) && kv > 0 {
            let c = self.known_const(b, ty, kv - 1);
            if c != NONE {
                self.enter(LOG_UB, x, c << 1);
            }
        }
    }

    // The signed range `(lo, hi)` of integer `v` (of at most 64 bits) here, `depth` operations deep: a
    // constant's; the signed bounds the branches in scope and the loop counters set (`SLO_KEY`, `SHI_KEY`:
    // `order_facts`, `signed_counter`); a sum or difference with a constant, a product by a constant of at
    // least 0, an extension, when neither end leaves the type. None when nothing bounds it.
    fn srange(self: &Self, pk: &Package, b: &Body, v: Value, depth: u32) Option<(i64, i64)> {
        if v == VNONE || (v & VFLAG) != 0 || is_vec(b.type_of(v)) {
            return None;
        }
        let w = type_bits(b.type_of(v), pk.ptr_bytes);
        if w == 0 || w > 64 {
            return None;
        }
        let tmax = (width_mask(b.type_of(v), pk.ptr_bytes) >> 1) as i64;
        let tmin = -tmax - 1;
        let k = int_bits(b, v);
        if k.is_some() {
            let c = sign_extend(k.unwrap(), w);
            return Some((c, c));
        }
        let mut lo = tmin;
        let mut hi = tmax;
        let mut known = false;
        if let Some(f) = self.ub.get(&(SLO_KEY | v as u64)) {
            lo = lo.max(clamp_i64(signed_bound(b, *f, w), tmin, tmax));
            known = true;
        }
        if let Some(f) = self.ub.get(&(SHI_KEY | v as u64)) {
            hi = hi.min(clamp_i64(signed_bound(b, *f, w), tmin, tmax));
            known = true;
        }
        // A bounded load's or view length's bound below the sign bit (`load_bound`, `view_len_max`).
        if (v & VPARAM) == 0 {
            let t = b.insts[v as usize];
            let m = width_mask(t.ty, pk.ptr_bytes);
            let mut r = load_bound(t, m);
            if r.is_none() {
                r = view_len_max(b, t, pk.ptr_bytes);
            }
            if r.is_some() && r.unwrap() <= tmax as u64 {
                lo = lo.max(0);
                hi = hi.min(r.unwrap() as i64);
                known = true;
            }
        }
        // At least 0: the unsigned least value the branches set is a signed one too (`len != 0`: `len - 1 >= 0`).
        if known && lo >= 0 {
            if let Some(f) = self.ub.get(&(LB_KEY | v as u64)) {
                let c = int_bits(b, *f >> 1).unwrap() & width_mask(b.type_of(v), pk.ptr_bytes);
                let c1 = c + (*f & 1) as u64;
                if c1 <= tmax as u64 && c1 as i64 > lo {
                    lo = c1 as i64;
                }
            }
        }
        // A select: the larger of each end of a maximum's values, the smaller of a minimum's, else the union.
        if depth != 0 && (v & VPARAM) == 0 && is_op(b, v, O_SELECT) {
            let t = b.insts[v as usize];
            let (xa, _) = extreme_arms(b, v, true);
            let (na, _) = extreme_arms(b, v, false);
            let ra = self.srange(pk, b, t.b, depth - 1);
            let rb = self.srange(pk, b, t.c, depth - 1);
            let (al, ah) = switch ra {
                Some(r) => r,
                None => (tmin, tmax),
            };
            let (bl, bh) = switch rb {
                Some(r) => r,
                None => (tmin, tmax),
            };
            let (sl, sh) = if xa != VNONE {
                (al.max(bl), ah.max(bh))
            } else if na != VNONE {
                (al.min(bl), ah.min(bh))
            } else {
                (al.min(bl), ah.max(bh))
            };
            if sl > tmin || sh < tmax {
                lo = lo.max(sl);
                hi = hi.min(sh);
                known = true;
            }
        }
        if depth != 0 && (v & VPARAM) == 0 {
            let t = b.insts[v as usize];
            let arith = t.op == O_ADD || t.op == O_SUB || t.op == O_MUL;
            let kb = if arith {
                int_bits(b, t.b)
            } else {
                Option::<u64>::None
            };
            let mut r = Option::<(i128, i128)>::None;
            if arith && kb.is_some() {
                let c = sign_extend(kb.unwrap(), w) as i128;
                if let Some(a) = self.srange(pk, b, t.a, depth - 1) {
                    let (l, h) = (a.0 as i128, a.1 as i128);
                    if t.op == O_ADD {
                        r = Some((l + c, h + c));
                    } else if t.op == O_SUB {
                        r = Some((l - c, h - c));
                    } else if c >= 0 {
                        r = Some((l * c, h * c));
                    }
                }
            } else if t.op == O_SEXT || t.op == O_ZEXT {
                if let Some(a) = self.srange(pk, b, t.a, depth - 1) {
                    if t.op == O_SEXT || a.0 >= 0 {
                        r = Some((a.0 as i128, a.1 as i128));
                    }
                }
            }
            if r.is_some() && r.unwrap().0 >= tmin && r.unwrap().1 <= tmax {
                lo = lo.max(r.unwrap().0 as i64);
                hi = hi.min(r.unwrap().1 as i64);
                known = true;
            }
        }
        return ast::pick(known, Some((lo, hi)), Option::<(i64, i64)>::None);
    }

    // Record signed bound `c + adj` (`c` a constant value, `adj` -1, 0 or 1) of `x` from below (`low`) or
    // above, where it is tighter than the one in scope.
    fn note_signed(self: &mut Self, pk: &Package, b: &Body, x: Value, low: bool, c: Value, adj: i32) {
        if (x & VFLAG) != 0 || int_bits(b, x).is_some() || is_vec(b.type_of(x)) || type_bits(b.type_of(x), pk.ptr_bytes) > 64 {
            return;
        }
        let w = type_bits(b.type_of(x), pk.ptr_bytes);
        let key = ast::pick(low, SLO_KEY, SHI_KEY) | x as u64;
        let f = c << 2 | (adj + 1) as u32;
        if let Some(o) = self.ub.get(&key) {
            let (ov, nv) = (signed_bound(b, *o, w), signed_bound(b, f, w));
            if low && ov >= nv || !low && ov <= nv {
                return;
            }
        }
        self.enter(LOG_UB, key, f);
    }

    // The least unsigned value `v` takes here: a constant's, a bound the branches in scope set
    // (`order_facts`), or one a subtraction of a constant (`a + k` as `a - d`, which does not wrap when
    // `a`'s bound is at least `d`) or a zero extension keeps, `depth` instructions deep; None when unknown.
    fn lbound(self: &Self, pk: &Package, b: &Body, v: Value, depth: u32) Option<u64> {
        if v == VNONE || (v & VFLAG) != 0 {
            return None;
        }
        let m = width_mask(b.type_of(v), pk.ptr_bytes);
        let k = int_bits(b, v);
        if k.is_some() {
            return Some(k.unwrap() & m);
        }
        let mut best = Option::<u64>::None;
        if let Some(f) = self.ub.get(&(LB_KEY | v as u64)) {
            let c = int_bits(b, *f >> 1).unwrap() & width_mask(b.type_of(*f >> 1), pk.ptr_bytes);
            // Above the type's greatest value: the block does not run.
            best = Some(
                if (*f & 1) == 0 || c == m {
                    c
                } else {
                    c + 1
                },
            );
        }
        if (best.is_none() || best.unwrap() == 0) && self.ub.get(&(NZ_KEY | v as u64)).is_some() {
            best = Some(1);
        }
        // A signed range at or above 0 bounds the unsigned value from below too.
        if let Some(sr) = self.srange(pk, b, v, depth) {
            if sr.0 >= 0 && (best.is_none() || sr.0 as u64 > best.unwrap()) {
                best = Some(sr.0 as u64);
            }
        }
        if (v & VPARAM) != 0 || depth == 0 {
            return best;
        }
        let t = b.insts[v as usize];
        if (t.op == O_ADD || t.op == O_SUB) && !is_vec(t.ty) && t.ty != T_I128 && int_bits(b, t.b).is_some() {
            let kb = int_bits(b, t.b).unwrap() & m;
            let d = if t.op == O_SUB {
                kb
            } else {
                (m - kb).wrapping_add(1) & m
            };
            let x = self.lbound(pk, b, t.a, depth - 1);
            if x.is_some() && x.unwrap() >= d {
                let r = x.unwrap() - d;
                return Some(
                    if best.is_some() {
                        r.max(best.unwrap())
                    } else {
                        r
                    },
                );
            }
        }
        // A zero extension keeps its operand's bound; an `or` is at least either operand.
        if t.op == O_ZEXT && !is_vec(t.ty) {
            let x = self.lbound(pk, b, t.a, depth - 1);
            if x.is_some() && (best.is_none() || x.unwrap() > best.unwrap()) {
                return x;
            }
        }
        if t.op == O_OR && !is_vec(t.ty) && t.ty != T_I128 {
            for v2 in [t.a, t.b] {
                let x = self.lbound(pk, b, v2, depth - 1);
                if x.is_some() && (best.is_none() || x.unwrap() > best.unwrap()) {
                    best = x;
                }
            }
        }
        return best;
    }

    // The greatest unsigned value `v` takes here: a constant's, a bound the branches in scope set
    // (`order_facts`) or that of a value they keep `v` at most (`note_le`), a `bool`, bounded load's
    // (`load_bound`) or view length's (`view_len_max`), or one an `and` with a constant, a right shift, a
    // remainder or quotient by a constant, a zero extension, or a shift, product by a constant or sum that
    // cannot wrap keeps, `depth` instructions deep; None when unknown.
    fn ubound(self: &Self, pk: &Package, b: &Body, v: Value, depth: u32) Option<u64> {
        if v == VNONE || (v & VFLAG) != 0 {
            return None;
        }
        let k = int_bits(b, v);
        if k.is_some() {
            return Some(k.unwrap() & width_mask(b.type_of(v), pk.ptr_bytes));
        }
        let mut best = Option::<u64>::None;
        if let Some(f) = self.ub.get(&(v as u64)) {
            let c = int_bits(b, *f >> 1).unwrap() & width_mask(b.type_of(*f >> 1), pk.ptr_bytes);
            best = if (*f & 1) == 0 {
                Some(c)
            } else if c == 0 {
                // No value is below 0: the block does not run.
                Some(0)
            } else {
                Some(c - 1)
            };
        }
        // A value at least 0 as a signed one (`param_bounds`) clears its sign bit.
        if self.ub.get(&(NN_KEY | v as u64)).is_some() {
            let h = width_mask(b.type_of(v), pk.ptr_bytes) >> 1;
            if best.is_none() || h < best.unwrap() {
                best = Some(h);
            }
        }
        // At most the bound of a value the branches keep it at most (`note_le`), below it where `v <u f` holds.
        if depth != 0 {
            for key in [UP_KEY, UP2_KEY] {
                if let Some(f) = self.ub.get(&(key | v as u64)) {
                    let mut u = self.ubound(pk, b, *f, depth - 1);
                    if u.is_some() && self.below(v, *f) {
                        u = Some(u.unwrap().max(1) - 1);
                    }
                    if u.is_some() && (best.is_none() || u.unwrap() < best.unwrap()) {
                        best = u;
                    }
                }
            }
        }
        // A signed range at or above 0 is an unsigned one.
        if let Some(sr) = self.srange(pk, b, v, depth) {
            if sr.0 >= 0 && (best.is_none() || sr.1 as u64 < best.unwrap()) {
                best = Some(sr.1 as u64);
            }
        }
        if (v & VPARAM) != 0 {
            return best;
        }
        let t = b.insts[v as usize];
        let m = width_mask(t.ty, pk.ptr_bytes);
        let mut r = load_bound(t, m);
        if r.is_none() {
            r = view_len_max(b, t, pk.ptr_bytes);
        }
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
            let s = int_bits(b, t.b);
            if s.is_some() && (s.unwrap() & m) < type_bits(t.ty, pk.ptr_bytes) as u64 {
                let hi = if x.is_some() {
                    x.unwrap()
                } else {
                    m
                };
                r = Some(hi >> (s.unwrap() & m));
            }
        } else if t.op == O_UREM || t.op == O_UDIV {
            let d = int_bits(b, t.b);
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
        } else if (t.op == O_SHL || t.op == O_MUL || t.op == O_ADD) && !is_vec(t.ty) && t.ty != T_I128 {
            // A shift by a constant, a product or a sum whose bounds' result fits the type does not wrap.
            let x = self.ubound(pk, b, t.a, depth - 1);
            let y = if t.op != O_SHL {
                self.ubound(pk, b, t.b, depth - 1)
            } else {
                int_bits(b, t.b)
            };
            if x.is_some() && y.is_some() {
                let (xv, yv) = (x.unwrap(), y.unwrap() & m);
                if t.op == O_SHL && yv < type_bits(t.ty, pk.ptr_bytes) as u64 && xv <= m >> yv {
                    r = Some(xv << yv);
                } else if t.op == O_MUL && (yv == 0 || xv <= m / yv) {
                    r = Some(xv * yv);
                } else if t.op == O_ADD && xv <= m - yv {
                    r = Some(xv + yv);
                }
            }
        } else if t.op == O_SUB && !is_vec(t.ty) && t.ty != T_I128 && int_bits(b, t.b).is_some() {
            // A difference with a constant at most its operand's least value does not wrap.
            let k = int_bits(b, t.b).unwrap() & m;
            let lo = self.lbound(pk, b, t.a, depth - 1);
            let hi = self.ubound(pk, b, t.a, depth - 1);
            if lo.is_some() && lo.unwrap() >= k && hi.is_some() && hi.unwrap() >= k {
                r = Some(hi.unwrap() - k);
            }
        } else if t.op == O_ICMP && !is_vec(t.ty) {
            // A comparison is 0 or 1.
            r = Some(1);
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
        } else if (t.op == O_CLZ || t.op == O_CTZ) && !is_vec(t.ty) && t.ty != T_I128 {
            // The width, or for an operand of at least `lo` above 0 the zeros above `lo`'s top bit (`clz`),
            // one less than the width (`ctz`).
            let w = type_bits(t.ty, pk.ptr_bytes) as u64;
            let lo = self.lbound(pk, b, t.a, depth - 1);
            r = Some(
                if lo.is_none() || lo.unwrap() == 0 {
                    w
                } else if t.op == O_CTZ {
                    w - 1
                } else {
                    lo.unwrap().leading_zeros() as u64 - (64 - w)
                },
            );
        }
        if r.is_some() && best.is_some() {
            return Some(r.unwrap().min(best.unwrap()));
        }
        return ast::pick(r.is_some(), r, best);
    }

    // Instruction `i`, which the bounds in scope (`ubound`) decide: a remainder or quotient by a constant
    // above its dividend's bound (the dividend, 0), a right shift that leaves nothing, an `and` with a
    // low mask that covers its operand's bound, a low mask less a value within it (an `xor`, in place), an integer comparison with a constant that every value
    // up to the bound answers alike (a signed one when the bound leaves the sign bit clear).
    // Its replacement value (VNONE: none); a constant result rewrites `i` in place.
    fn range_fold(self: &mut Self, pk: &Package, b: &mut Body, i: u32) Value {
        let t = b.insts[i as usize];
        if is_vec(t.ty) || t.ty == T_I128 {
            return VNONE;
        }
        // A low mask less a value its bound keeps within the mask clears the value's bits: their `xor`, which
        // takes the operands in either order.
        if t.op == O_SUB {
            let k = int_bits(b, t.a);
            let m = width_mask(t.ty, pk.ptr_bytes);
            let kv = k.unwrap_or(1) & m;
            if k.is_some() && (kv & kv.wrapping_add(1)) == 0 {
                let x = self.ubound(pk, b, t.b, UB_DEPTH);
                if kv == m || x.is_some() && x.unwrap() <= kv {
                    b.insts[i as usize] = Inst { op: O_XOR, ty: t.ty, aux: 0, a: t.b, b: t.a, c: VNONE };
                }
            }
            return VNONE;
        }
        if t.op == O_UREM || t.op == O_UDIV || t.op == O_LSHR || t.op == O_AND {
            let k = int_bits(b, t.b);
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
            return ast::pick(t.op == O_AND && (c & c.wrapping_add(1)) == 0 && hi <= c, t.a, VNONE);
        }
        if t.op == O_ICMP && t.aux <= C_UGE {
            let k = int_bits(b, t.b);
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

    // The value `p` that `v` is at most by its form, and whether below it: `p - w` where `w <=u p` holds (a
    // constant within `p`'s lower bound, strictly below `p` from 1 on), `p >> c` and `p / c` by a nonzero
    // constant, `p & m`; `(VNONE, false)` else.
    fn at_most_of(self: &Self, pk: &Package, b: &Body, v: Value) (Value, bool) {
        if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
            return (VNONE, false);
        }
        let t = b.insts[v as usize];
        if is_vec(t.ty) || t.ty == T_I128 || (t.a & VFLAG) != 0 {
            return (VNONE, false);
        }
        let m = width_mask(t.ty, pk.ptr_bytes);
        if t.op == O_SUB {
            let k = int_bits(b, t.b);
            if k.is_some() {
                let kv = k.unwrap() & m;
                let lo = self.lbound(pk, b, t.a, UB_DEPTH);
                return ast::pick(lo.is_some() && lo.unwrap() >= kv, (t.a, kv != 0), (VNONE, false));
            }
            let ge = switch self.rel.get(&rel_key(t.a, t.b)) {
                Some(r) => *r == 0,
                None => false,
            };
            return ast::pick(ge, (t.a, false), (VNONE, false));
        }
        if t.op == O_LSHR || t.op == O_UDIV {
            let k = int_bits(b, t.b);
            return ast::pick(k.is_some() && (k.unwrap() & m) != 0, (t.a, false), (VNONE, false));
        }
        return ast::pick(t.op == O_AND, (t.a, false), (VNONE, false));
    }

    // `(k, s)` when `v` is `(k << s) + c` (`k * 2^s`, the value of a checked sum too) with `c` a constant
    // from 1 to `2^s` and `s` the constant shift's value; `(VNONE, VNONE)` else.
    fn chunk_end(self: &Self, pk: &Package, b: &Body, v: Value) (Value, Value) {
        let none = (VNONE, VNONE);
        if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
            return none;
        }
        let t = b.insts[v as usize];
        if t.op != O_ADD && !(t.op == O_ADDO && (t.aux & OV_SIGNED) == 0) || is_vec(t.ty) || (t.a & (VPARAM | VFLAG)) != 0 {
            return none;
        }
        let c = int_bits(b, t.b);
        let sh = b.insts[t.a as usize];
        if c.is_none() || c.unwrap() == 0 || sh.op != O_SHL {
            return none;
        }
        let sv = int_bits(b, sh.b);
        let w = type_bits(t.ty, pk.ptr_bytes) as u64;
        if sv.is_none() || sv.unwrap() == 0 || sv.unwrap() >= w || c.unwrap() > 1u64 << sv.unwrap() {
            return none;
        }
        return (sh.a, sh.b);
    }

    // Whether `x <u y` holds in the scope (`rel`).
    fn below(self: &Self, x: Value, y: Value) bool {
        return switch self.rel.get(&rel_key(x, y)) {
            Some(r) => *r != 0,
            None => false,
        };
    }

    // Whether the product of `w` and `h`, computed in scope, wraps nowhere and is at most `y`: a product
    // whose operands' bounds (`ubound`) multiply within the type, or an unsigned checked one whose flag
    // the branches in scope clear.
    fn product_le(self: &Self, pk: &Package, b: &Body, w: Value, h: Value, y: Value) bool {
        let ty = b.type_of(w);
        let m = width_mask(ty, pk.ptr_bytes);
        for side in 0..2u32 {
            let t = Inst {
                op: O_MUL,
                ty: ty,
                aux: 0,
                a: ast::pick(side == 0, w, h),
                b: ast::pick(side == 0, h, w),
                c: VNONE,
            };
            let z = switch self.pure.get(&value_hash(b, t)) {
                Some(v) => *v,
                None => NONE,
            };
            if z == NONE || !same_value(b, as_plain(b.insts[z as usize]), t) || !self.known_le(z, y) {
                continue;
            }
            let u = b.insts[z as usize];
            if u.op == O_MULO {
                let clear = switch self.cond.get(&((VFLAG | z) as u64)) {
                    Some(f) => *f == 0,
                    None => false,
                };
                if (u.aux & OV_SIGNED) == 0 && clear {
                    return true;
                }
                continue;
            }
            let x = self.ubound(pk, b, w, UB_DEPTH);
            let v = self.ubound(pk, b, h, UB_DEPTH);
            if x.is_some() && v.is_some() && (x.unwrap() == 0 || v.unwrap() <= m / x.unwrap()) {
                return true;
            }
        }
        return false;
    }

    // Whether `u <=u y` holds in the scope: `u` is `y`, the order facts give it, or `y` is a value `u` is at
    // most (`note_le`).
    fn known_le(self: &Self, u: Value, y: Value) bool {
        if u == y {
            return true;
        }
        if let Some(r) = self.rel.get(&rel_key(u, y)) {
            if *r != 0 {
                return true;
            }
        }
        if let Some(r) = self.rel.get(&rel_key(y, u)) {
            if *r == 0 {
                return true;
            }
        }
        for key in [UP_KEY, UP2_KEY] {
            if let Some(f) = self.ub.get(&(key | u as u64)) {
                if *f == y {
                    return true;
                }
            }
        }
        return false;
    }

    // `x <=u w` holds in the scope: `w` is one of the two values `x` is known to be at most (`UP_KEY`,
    // `UP2_KEY`), the newer first, for `upper_parts`.
    fn note_le(self: &mut Self, x: Value, w: Value) {
        let prev = switch self.ub.get(&(UP_KEY | x as u64)) {
            Some(f) => *f,
            None => VNONE,
        };
        if prev == w {
            return;
        }
        if prev != VNONE {
            self.enter(LOG_UB, UP2_KEY | x as u64, prev);
        }
        self.enter(LOG_UB, UP_KEY | x as u64, w);
    }

    // `x <u y` holds: so does `x <u u` for each value `u` that `y` is at most, `depth` steps deep: an operand
    // of minimum `y` (a select of the lesser of two values); `n` of `n - k` where `k <=u n` (a saturating
    // difference, a select of `n - k` where the condition gives `k <=u n` and of 0 where not; a difference
    // of a constant at most `n`'s lower bound, or of a value the branches keep at most `n`); `n` of `n >> c`,
    // `n / c` by a constant below the width, above 0; both operands of `n & m`; `n` and `w` of `w % n` where
    // `n` is at least 1; the values the branches in scope keep `y` at most (`note_le`).
    fn upper_parts(self: &mut Self, pk: &Package, b: &Body, x: Value, y: Value, depth: u32) {
        if depth == 0 || (y & VFLAG) != 0 || y == VNONE {
            return;
        }
        let mut ups: [Value; 4] = [VNONE; 4];
        let mut nu: usize = 0;
        for key in [UP_KEY, UP2_KEY] {
            if let Some(f) = self.ub.get(&(key | y as u64)) {
                ups[nu] = *f;
                nu += 1;
            }
        }
        if (y & VPARAM) == 0 {
            let t = b.insts[y as usize];
            let m = width_mask(t.ty, pk.ptr_bytes);
            if t.op == O_SELECT && !is_vec(t.ty) {
                let (u, w, neg) = Opt::as_ult(b, t.a);
                if u == t.b && w == t.c && !neg || u == t.c && w == t.b && neg {
                    ups[nu] = t.b;
                    ups[nu + 1] = t.c;
                    nu += 2;
                } else if u != VNONE {
                    // The condition holds on the true side; `k <=u n` where it gives `!(n <u k)` or `k <u n`.
                    for side in 0..2u32 {
                        let (d, z) = ast::pick(side == 0, (t.b, t.c), (t.c, t.b));
                        if !is_op(b, d, O_SUB) || int_bits(b, z) != Some(0u64) {
                            continue;
                        }
                        let s = b.insts[d as usize];
                        let on_true = side == 0;
                        if u == s.a && w == s.b && neg == on_true || u == s.b && w == s.a && neg != on_true {
                            ups[nu] = s.a;
                            nu += 1;
                            break;
                        }
                    }
                }
            } else if t.op == O_SUB && !is_vec(t.ty) && t.ty != T_I128 {
                let k = int_bits(b, t.b);
                let lo = self.lbound(pk, b, t.a, UB_DEPTH);
                let below = if k.is_some() {
                    lo.is_some() && lo.unwrap() >= (k.unwrap() & m)
                } else {
                    switch self.rel.get(&rel_key(t.a, t.b)) {
                        Some(r) => *r == 0,
                        None => false,
                    }
                };
                if below {
                    ups[nu] = t.a;
                    nu += 1;
                }
            } else if (t.op == O_LSHR || t.op == O_UDIV) && !is_vec(t.ty) && t.ty != T_I128 {
                let c = int_bits(b, t.b);
                if c.is_some() && (c.unwrap() & m) != 0 && (t.op == O_UDIV || (c.unwrap() & m) < type_bits(
                    t.ty,
                    pk.ptr_bytes,
                ) as u64) {
                    ups[nu] = t.a;
                    nu += 1;
                }
            } else if t.op == O_AND && !is_vec(t.ty) {
                ups[nu] = t.a;
                ups[nu + 1] = t.b;
                nu += 2;
            } else if t.op == O_UREM && !is_vec(t.ty) && t.ty != T_I128 {
                let lo = self.lbound(pk, b, t.b, UB_DEPTH);
                if lo.is_some() && lo.unwrap() != 0 {
                    ups[nu] = t.b;
                    ups[nu + 1] = t.a;
                    nu += 2;
                }
            }
        }
        for q in 0..nu {
            let u = ups[q];
            if u == x {
                continue;
            }
            self.enter(LOG_REL, rel_key(x, u), 1);
            if int_bits(b, u).is_none() {
                self.upper_parts(pk, b, x, u, depth - 1);
            }
        }
    }

    // Loop header `h`'s parameters that stay at most the one value from outside the loop every entry passes
    // (`note_le`): each back edge passes the parameter itself, a select of such values, or a midpoint
    // `lo + ((p - lo) >> c)` (a quotient by at least 2 too) below the parameter `p` where the header's test
    // `lo <u p` holds into the loop (by induction over the iterations; a binary search's `hi`). And a counter
    // `p` from a constant of at least 0 by steps of 1 under the test `p <s n` stays at least 0 (its bound
    // clears the sign bit, `ubound`): the step never passes `n`; under `p <u n`, at least its start (`lbound`,
    // or `p >=u s` for a start `s` that is no constant).
    fn param_bounds(self: &mut Self, pk: &Package, b: &Body, h: u32) {
        let hb = b.blocks[h as usize];
        let th = term(b, h);
        if hb.param_len == 0 || th.op != O_BR || b.edge_target(th.b) == b.edge_target(th.c) {
            return;
        }
        let tin = self.in_loop(h, b.edge_target(th.b));
        let one_in = tin != self.in_loop(h, b.edge_target(th.c));
        let (x, y, neg) = Opt::as_ult(b, th.a);
        let lt = x != VNONE && one_in && tin != neg;
        let (sx, _, sneg) = Opt::as_slt(b, th.a);
        let slt = sx != VNONE && one_in && tin != sneg;
        for q in 0..hb.param_len as u32 {
            let p = VPARAM | hb.param_start + q;
            let mut e = VNONE;
            let mut ok = true;
            // A back edge passes `(lo + p) >> 1` (`half_sum`) below `p` where `lo <u p`: then the start's bound
            // keeps the sum from wrapping.
            let mut halves = false;
            // Every edge in passes a value it proves nonzero (`nonzero_on`): `p` is at least 1.
            let mut nz = true;
            // The header's test keeps `p` nonzero into the loop: `p - 1` on a back edge wraps nowhere.
            let hz = one_in && self.nonzero_on(pk, b, th, tin, p, false);
            let mut up = slt && sx == p;
            // Counting up by `k` where the header's test or each back edge's leaves `p` room for `k` (`p <u y`,
            // `p <=u y` with `y`'s bound low enough: `step_room`): no step wraps, so `p` stays at least its start.
            let mut rise = true;
            let hroom = ast::pick(one_in, self.step_room(pk, b, th.a, tin, p), 0u64);
            // The least value each edge in passes (`edge_floor`): a step down by at most it wraps nowhere.
            let (lbp, lbf) = self.edge_floor(pk, b, h, q, p);
            let mut eo = true;
            for j in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
                let pb = self.preds[j as usize];
                b.succ_edges(term(b, pb), &mut self.edges);
                for d in 0..self.edges.len() {
                    let ed = self.edges[d];
                    if b.edge_target(ed) != h {
                        continue;
                    }
                    let a = b.edge_arg(ed, q);
                    let tp = term(b, pb);
                    nz = nz && (a == p || tp.op == O_BR && b.edge_target(tp.b) != b.edge_target(tp.c) && self.nonzero_on(
                        pk,
                        b,
                        tp,
                        ed == tp.b,
                        a,
                        !self.in_loop(h, pb),
                    ) || tp.op != O_BR && !self.in_loop(h, pb) && self.nonzero_on(pk, b, tp, true, a, true));
                    if !self.in_loop(h, pb) {
                        eo = eo && (e == VNONE || e == a) && self.outside(a, h);
                        ok = ok && (e == VNONE || e == a) && self.outside(a, h);
                        up = up && (e == VNONE || e == a) && int_bits(b, a).is_some() && self.nonneg(pk, b, a);
                        e = a;
                    } else {
                        let lo = ast::pick(lt && y == p, x, VNONE);
                        let (h0, h1) = half_sum(b, a);
                        let half = lo != VNONE && (h0 == lo && h1 == p || h0 == p && h1 == lo);
                        halves = halves || half;
                        ok = ok && (self.below_param(b, a, p, lo, MIN_DEPTH) || minus_one(b, a, p) || half || lbp != 0 && step_of(
                            b,
                            a,
                            p,
                        ) < 0 && (-step_of(b, a, p)) as u64 <= lbp);
                        let k = step_of(b, a, p);
                        up = up && k == 1;
                        let (c, holds) = self.edge_cond(b, pb, ed);
                        let eroom = if c != VNONE {
                            self.step_room(pk, b, c, holds, p)
                        } else {
                            0u64
                        };
                        rise = rise && k > 0 && hroom.max(eroom) >= k as u64;
                    }
                }
            }
            // A step down by 1 counts only where `p` is nonzero.
            let down = !(hz || nz || lbp != 0) && self.steps_down_from(b, h, q, p);
            let eu = self.ubound(pk, b, e, UB_DEPTH);
            let wraps = halves && (eu.is_none() || eu.unwrap() > width_mask(b.type_of(p), pk.ptr_bytes) >> 1);
            if ok && !down && !wraps && e != VNONE && int_bits(b, e).is_none() {
                self.note_le(p, e);
            }
            // A constant start bounds the parameter itself (`j` of `while i < j { j -= 1 }` from `200`).
            if ok && !down && !wraps && e != VNONE && (e & VFLAG) == 0 && int_bits(b, e).is_some() && self.ub.get(
                &(p as u64),
            ).is_none() {
                self.enter(LOG_UB, p, e << 1);
            }
            if nz && e != VNONE {
                self.enter(LOG_UB, NZ_KEY | p as u64, 1);
            }
            if lbp != 0 && self.lbound(pk, b, p, 0).unwrap_or(0) < lbp {
                self.enter(LOG_UB, LB_KEY | p as u64, lbf);
            }

            if up && e != VNONE {
                self.enter(LOG_UB, NN_KEY | p as u64, 1);
            }
            if rise && eo && e != VNONE && (e & VFLAG) == 0 {
                if int_bits(b, e).is_some() {
                    self.enter(LOG_UB, LB_KEY | p as u64, e << 1);
                } else {
                    self.enter(LOG_REL, rel_key(p, e), 0);
                }
            }
        }
        // Below a value from before the loop that every edge in proves its argument below; a second round
        // takes an argument that is a parameter the first round bounded (`j` of `i = j` after `j <u n`).
        let mut done = 0u64;
        for _ in 0..2u32 {
            for q in 0..(hb.param_len as u32).min(64) {
                let p = VPARAM | hb.param_start + q;
                if (done >> q & 1) != 0 {
                    continue;
                }
                let yb = self.edge_bound(pk, b, h, q, p, ast::pick(one_in, th.a, VNONE), tin);
                if yb == VNONE {
                    continue;
                }
                done |= 1u64 << q;
                self.enter(LOG_REL, rel_key(p, yb), 1);
                if int_bits(b, yb).is_some() {
                    self.enter(LOG_UB, p, yb << 1 | 1);
                } else {
                    self.note_le(p, yb);
                }
            }
        }
        // At most such a value where the edges' tests are inclusive (`edge_le`).
        for q in 0..(hb.param_len as u32).min(64) {
            let p = VPARAM | hb.param_start + q;
            if (done >> q & 1) != 0 {
                continue;
            }
            let w = self.edge_le(b, h, q, p);
            if w == VNONE {
                continue;
            }
            if int_bits(b, w).is_none() {
                self.note_le(p, w);
            } else if self.ub.get(&(p as u64)).is_none() {
                self.enter(LOG_UB, p, w << 1);
            }
        }
        // A constant bound one step past a test (`edge_ub`: the count `i + 1` a loop `i < 128` exits with).
        for q in 0..(hb.param_len as u32).min(64) {
            let p = VPARAM | hb.param_start + q;
            if self.ub.get(&(p as u64)).is_some() || !is_int(b.type_of(p)) || b.type_of(p) == T_I128 || is_vec(
                b.type_of(p),
            ) {
                continue;
            }
            let u = self.edge_ub(pk, b, h, q, p, ast::pick(one_in, th.a, VNONE), tin);
            let c = ast::pick(u.is_some(), self.known_const(b, b.type_of(p), u.unwrap_or(0)), NONE);
            if u.is_some() && c != NONE && u.unwrap() < width_mask(b.type_of(p), pk.ptr_bytes) {
                self.enter(LOG_UB, p, c << 1);
            }
        }
        for q in 0..hb.param_len as u32 {
            self.signed_counter(pk, b, h, q, VPARAM | hb.param_start + q, ast::pick(one_in, th.a, VNONE), tin);
        }
    }

    // The greatest value each edge into loop `h` passes for its header parameter `q` (`p`): on an edge from
    // outside the argument's bound (`ubound`); on a back edge `p + k` (`k` above 0) where the edge's test or the
    // header's `hc` (holding into the loop where `tin`) keeps `p` below a constant `c` (`c - 1 + k`) or at most
    // it (`c + k`), else the argument's bound in the header's scope. None when some edge has none, or a sum
    // passes the type.
    fn edge_ub(self: &mut Self, pk: &Package, b: &Body, h: u32, q: u32, p: Value, hc: Value, tin: bool) Option<u64> {
        let m = width_mask(b.type_of(p), pk.ptr_bytes);
        let mut best: u64 = 0;
        for j in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
            let pb = self.preds[j as usize];
            let inl = self.in_loop(h, pb);
            b.succ_edges(term(b, pb), &mut self.edges);
            for d in 0..self.edges.len() {
                let ed = self.edges[d];
                if b.edge_target(ed) != h {
                    continue;
                }
                let a0 = self.val(b.edge_arg(ed, q));
                let a = self.edge_value(b, a0);
                if a == p {
                    continue;
                }
                let k = ast::pick(step_of(b, a, p) != 0, step_of(b, a, p), step_of(b, a0, p));
                let mut u = Option::<u64>::None;
                if inl && k > 0 {
                    let (c, holds) = self.edge_cond(b, pb, ed);
                    for side in 0..2u32 {
                        let (cc, hh) = ast::pick(side == 0, (c, holds), (hc, tin));
                        let (x, y, neg) = Opt::as_ult(b, cc);
                        let lt = x != VNONE && hh != neg;
                        let lim = if lt && x == p && int_bits(b, y).is_some() && (int_bits(b, y).unwrap() & m) != 0 {
                            Some((int_bits(b, y).unwrap() & m) - 1)
                        } else if x != VNONE && !lt && y == p && int_bits(b, x).is_some() {
                            Some(int_bits(b, x).unwrap() & m)
                        } else {
                            Option::<u64>::None
                        };
                        if lim.is_some() && lim.unwrap() <= m - k as u64 && (u.is_none() || lim.unwrap() + k as u64 < u.unwrap()) {
                            u = Some(lim.unwrap() + k as u64);
                        }
                    }
                }
                if u.is_none() {
                    u = self.ubound(pk, b, a, UB_DEPTH);
                }
                if u.is_none() {
                    return None;
                }
                best = best.max(u.unwrap());
            }
        }
        return Some(best);
    }

    // Signed bounds of loop header `h`'s parameter `p` (index `q`): a counter from one start `e` that each back
    // edge steps by one constant `k` (`step_of`), up or down, within a bound `B` (`limit_of`: a constant plus
    // -1, 0 or 1, or a value `n` from before the loop, whose signed range gives `B`: `bound_num`). With the
    // header's test `hc` holding into the loop (`tin`), `p` is within `B` before each step, which then does not
    // wrap (`B + k` stays in the type), and the exit sees up to `k` past it: up, `[e, max(e, B + k)]`. With every
    // back edge's own test, by induction from `e` within `B`: up, `[e, B]`. Down is the mirror. A start `e` from
    // before the loop (no constant): under the header's test, down at most `e` as a signed value (`SHV_KEY`), up
    // at least the start's signed bound from below; under every edge's test against a constant (the entry's
    // too), also within that constant. Up from a constant `e` of at least 0 under every edge's `a <s n`: `p` is
    // below `n` as an unsigned value too, and `n` above `e`.
    fn signed_counter(self: &mut Self, pk: &Package, b: &Body, h: u32, q: u32, p: Value, hc: Value, tin: bool) {
        if is_vec(b.type_of(p)) || type_bits(b.type_of(p), pk.ptr_bytes) > 64 {
            return;
        }
        let mut e = VNONE;
        let mut k: i64 = 0;
        let mut ek = VNONE;
        let mut ea: i32 = 0;
        let mut edges_ok = true;
        for j in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
            let pb = self.preds[j as usize];
            let tp = term(b, pb);
            b.succ_edges(tp, &mut self.edges);
            for d in 0..self.edges.len() {
                let ed = self.edges[d];
                if b.edge_target(ed) != h {
                    continue;
                }
                let a = b.edge_arg(ed, q);
                if !self.in_loop(h, pb) {
                    if (a & VFLAG) != 0 || !self.outside(a, h) || e != VNONE && e != a {
                        return;
                    }
                    e = a;
                    continue;
                }
                let st = step_of(b, a, p);
                if st == 0 || k != 0 && k != st {
                    return;
                }
                k = st;
                let (ec, eh) = self.edge_cond(b, pb, ed);
                let (bk, adj) = if ec != VNONE {
                    Opt::limit_of(b, ec, eh, a, st > 0)
                } else {
                    (VNONE, 0)
                };
                if bk == VNONE || ek != VNONE && (ek != bk || ea != adj) || int_bits(b, bk).is_none() && !self.outside(
                    bk,
                    h,
                ) {
                    edges_ok = false;
                } else {
                    ek = bk;
                    ea = adj;
                }
            }
        }
        if e == VNONE || k == 0 {
            return;
        }
        let up = k > 0;
        let w = type_bits(b.type_of(p), pk.ptr_bytes);
        let tmax64 = (width_mask(b.type_of(p), pk.ptr_bytes) >> 1) as i64;
        let (tmax, tmin) = (tmax64 as i128, (-tmax64 - 1) as i128);
        // Whether one more step from `v` stays in the type.
        let fits = |v: i128| v + k <= tmax && v + k >= tmin;
        let (hk, ha) = if hc != VNONE {
            Opt::limit_of(b, hc, tin, p, up)
        } else {
            (VNONE, 0)
        };
        let hn = self.bound_num(pk, b, h, hk, ha, up);
        if int_bits(b, e).is_none() {
            // A start from before the loop.
            let lo = switch self.ub.get(&(SLO_KEY | e as u64)) {
                Some(f) => *f,
                None => VNONE,
            };
            if hn.is_some() && fits(hn.unwrap()) {
                if !up {
                    self.enter(LOG_UB, SHV_KEY | p as u64, e);
                } else if lo != VNONE {
                    self.enter(LOG_UB, SLO_KEY | p as u64, lo);
                }
                return;
            }
            if !edges_ok || ek == VNONE || int_bits(b, ek).is_none() || self.entry_limit(b, h, e, up) != (ek, ea) {
                return;
            }
            let bv = sign_extend(int_bits(b, ek).unwrap(), w) as i128 + ea;
            if !fits(bv) {
                return;
            }
            self.note_signed(pk, b, p, !up, ek, ea);
            if !up {
                self.enter(LOG_UB, SHV_KEY | p as u64, e);
                self.shv_le(pk, b, p);
            } else if lo != VNONE {
                self.enter(LOG_UB, SLO_KEY | p as u64, lo);
            }
            return;
        }
        let ev = sign_extend(int_bits(b, e).unwrap(), w) as i128;
        if hn.is_some() {
            let hv = hn.unwrap();
            if !fits(hv) {
                return;
            }
            self.note_signed(pk, b, p, up, e, 0);
            // Up to one step past a constant bound; a bound the encoding cannot hold stays unnoted.
            let far = ha as i64 + k;
            if int_bits(b, hk).is_some() {
                if ast::pick(up, ev > hv + k, ev < hv + k) {
                    self.note_signed(pk, b, p, !up, e, 0);
                } else if far >= -1 && far <= 2 {
                    self.note_signed(pk, b, p, !up, hk, far as i32);
                }
            }
            return;
        }
        if !edges_ok || ek == VNONE {
            return;
        }
        let bn = self.bound_num(pk, b, h, ek, ea, up);
        if bn.is_none() {
            return;
        }
        let bv = bn.unwrap();
        if int_bits(b, ek).is_some() {
            if fits(bv) && ast::pick(up, ev <= bv, ev >= bv) {
                self.note_signed(pk, b, p, up, e, 0);
                self.note_signed(pk, b, p, !up, ek, ea);
            }
            return;
        }
        if !fits(ast::pick(up == ev > bv, ev, bv)) {
            return;
        }
        self.note_signed(pk, b, p, up, e, 0);
        let nlo = switch self.srange(pk, b, ek, UB_DEPTH) {
            Some(r) => r.0 as i128,
            None => tmin,
        };
        if up && ev >= 0 && ea == -1 && (nlo > ev || self.entry_limit(b, h, e, true) == (ek, -1)) {
            self.enter(LOG_REL, rel_key(p, ek), 1);
            self.note_le(p, ek);
            self.note_signed(pk, b, ek, true, e, 1);
        }
    }

    // The signed bound `k + adj` (`limit_of`) as a number for loop header `h`: a constant's; for a value `k` from
    // before the loop, the greatest (`up`) or least value of its signed range (`srange`). None else.
    fn bound_num(self: &Self, pk: &Package, b: &Body, h: u32, k: Value, adj: i32, up: bool) Option<i128> {
        if k == VNONE {
            return None;
        }
        let w = type_bits(b.type_of(k), pk.ptr_bytes);
        if int_bits(b, k).is_some() {
            return Some(sign_extend(int_bits(b, k).unwrap(), w) as i128 + adj);
        }
        if !self.outside(k, h) {
            return None;
        }
        return switch self.srange(pk, b, k, UB_DEPTH) {
            Some(r) => Some(ast::pick(up, r.1, r.0) + adj),
            None => None,
        };
    }

    // The bound (`limit_of`) every edge into loop `h` from outside it gives start `e`; `(VNONE, 0)` when they
    // differ or one gives none.
    fn entry_limit(self: &mut Self, b: &Body, h: u32, e: Value, up: bool) (Value, i32) {
        let mut r = (VNONE, 0i32);
        let mut first = true;
        for j in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
            let pb = self.preds[j as usize];
            if self.in_loop(h, pb) {
                continue;
            }
            let tp = term(b, pb);
            b.succ_edges(tp, &mut self.edges);
            for d in 0..self.edges.len() {
                let ed = self.edges[d];
                if b.edge_target(ed) != h {
                    continue;
                }
                let (ec, eh) = self.edge_cond(b, pb, ed);
                let l = if ec != VNONE {
                    Opt::limit_of(b, ec, eh, e, up)
                } else {
                    (VNONE, 0)
                };
                if l.0 == VNONE || !first && l != r {
                    return (VNONE, 0);
                }
                r = l;
                first = false;
            }
        }
        return r;
    }

    // A counter down from a value before its loop (`SHV_KEY`) that `v` is, at least 0 here, is at most that value
    // as an unsigned one too, and below `n` where that value is `n - 1`.
    fn shv_le(self: &mut Self, pk: &Package, b: &Body, v: Value) {
        let e = switch self.ub.get(&(SHV_KEY | v as u64)) {
            Some(f) => *f,
            None => VNONE,
        };
        let nn = e != VNONE && (switch self.srange(pk, b, v, 0) {
            Some(r) => r.0 >= 0,
            None => false,
        });
        if nn {
            self.note_le(v, e);
            if is_op(b, e, O_SUB) && int_bits(b, b.insts[e as usize].b) == Some(1u64) {
                self.enter(LOG_REL, rel_key(v, b.insts[e as usize].a), 1);
            }
        }
    }

    // At terminator `t` of block `k`, in its scope: for each edge into a join block (no loop header, from 2 to
    // JOIN_PREDS edges in) with parameters, the facts the edge's condition and the scope give each argument,
    // joined with those of the edges into it recorded before (`JoinFact`, `join_arg`). The walk visits a join
    // after its predecessors; it enters what every edge gave (`join_in`: the count a scan loop exits with). An
    // edge of the block's terminator `t0` before the visit that `t` no longer has (a branch it decided) passes
    // nothing, and counts.
    fn join_out(self: &mut Self, pk: &Package, b: &mut Body, k: u32, t0: Inst, t: Inst) {
        let mut eds: [u32; 2] = [NONE; 2];
        let mut ne: usize = 1;
        if t0.op == O_JMP {
            eds[0] = t0.a;
        } else if t0.op == O_BR {
            eds[0] = t0.b;
            eds[1] = t0.c;
            ne = 2;
        } else {
            return;
        }
        let split = t.op == O_BR && b.edge_target(t.b) != b.edge_target(t.c) && int_bits(b, t.a).is_none();
        // An edge `t` has that `t0` had not (a side's edge an if-conversion took over) enters its block from
        // a block its predecessors at the walk's start do not list: that block keeps no facts.
        let mut tes: [u32; 2] = [NONE; 2];
        if t.op == O_JMP {
            tes[0] = t.a;
        } else if t.op == O_BR {
            tes[0] = t.b;
            tes[1] = t.c;
        }
        for d in 0..2usize {
            if tes[d] != NONE && tes[d] != eds[0] && tes[d] != eds[1] {
                self.jat[b.edge_target(tes[d]) as usize] = JOIN_BAD;
            }
        }
        for d in 0..ne {
            let ed = eds[d];
            let j = b.edge_target(ed);
            let np = self.pred_at[j as usize + 1] - self.pred_at[j as usize];
            let jb = b.blocks[j as usize];
            if jb.param_len == 0 || np < 2 || np > JOIN_PREDS || self.inner[j as usize] == j || j == k || self.jat[j as usize] == JOIN_BAD {
                continue;
            }
            // An edge from a block the walk's start did not list (one a rewrite moved here) spoils the count.
            let mut listed = false;
            for x in self.pred_at[j as usize]..self.pred_at[j as usize + 1] {
                listed = listed || self.preds[x as usize] == k;
            }
            if !listed {
                self.jat[j as usize] = JOIN_BAD;
                continue;
            }
            let nq = (jb.param_len as u32).min(JOIN_MAX);
            let live = t.op == O_JMP && t.a == ed || t.op == O_BR && (t.b == ed || t.c == ed);
            if self.jat[j as usize] == NONE {
                self.jat[j as usize] = self.jfacts.len() as u32;
                for _ in 0..nq {
                    self.jfacts.push(
                        JoinFact {
                            lo: u64::MAX,
                            hi: 0,
                            slo: i64::MAX,
                            shi: i64::MIN,
                            sk: true,
                            w: [VNONE; 2],
                            ws: [false; 2],
                            nw: NONE,
                            sw: NONE,
                            dead: false,
                        },
                    );
                }
            }
            if !live {
                self.jcnt[j as usize] += 1;
                continue;
            }
            let mark = self.log.len();
            if split {
                let holds = ed == t.b;
                self.enter(LOG_COND, t.a, holds as u32);
                self.cond_parts(pk, b, t.a, holds, MIN_DEPTH);
            }
            let base = self.jat[j as usize];
            for q in 0..nq {
                let mut f = self.jfacts[(base + q) as usize];
                if !f.dead {
                    let a = self.val(b.edge_arg(ed, q));
                    self.join_arg(pk, b, j, a, &mut f);
                    self.jfacts[(base + q) as usize] = f;
                }
            }
            self.unwind(mark);
            self.jcnt[j as usize] += 1;
        }
    }

    // Fact `f` of a parameter of join block `j` joined with argument `a` of one more edge into it, in that edge's
    // scope: the ranges' union; of the values `f` is at most, those `a` is at most too (`le_of`); the first edge
    // that is no constant 0 gives them: the values from before the join that `a` is at most (`uppers`).
    fn join_arg(self: &Self, pk: &Package, b: &Body, j: u32, a: Value, f: &mut JoinFact) {
        let ty = b.type_of(a);
        if a == VNONE || (a & VFLAG) != 0 || !is_int(ty) || ty == T_I128 || is_vec(ty) {
            f.dead = true;
            return;
        }
        let m = width_mask(ty, pk.ptr_bytes);
        f.hi = f.hi.max(self.ubound(pk, b, a, UB_DEPTH).unwrap_or(m));
        f.lo = f.lo.min(self.lbound(pk, b, a, UB_DEPTH).unwrap_or(0));
        switch self.srange(pk, b, a, UB_DEPTH) {
            Some(r) => {
                f.slo = f.slo.min(r.0);
                f.shi = f.shi.max(r.1);
            },
            None => {
                f.sk = false;
            },
        }
        // At most a value as a signed one: the first edge's `a` or the start a counter down stays at most
        // (`SHV_KEY`), which every later edge's keeps (`sle_of`).
        if f.sw == NONE {
            f.sw = self.sle_first(b, j, a);
        } else if f.sw != VNONE && !self.sle_of(pk, b, a, f.sw) {
            f.sw = VNONE;
        }
        let c = int_bits(b, a);
        if c.is_some() && (c.unwrap() & m) == 0 {
            return;
        }
        if f.nw == NONE {
            f.nw = 0;
            if c.is_some() {
                return;
            }
            let mut us: [(Value, i64); 3] = [(VNONE, 0); 3];
            let n = self.uppers(pk, b, a, &mut us);
            for q in 0..n {
                let (u, d) = us[q];
                let du = self.def_blk(u);
                if d <= 0 && f.nw < 2 && u != VNONE && (u & VFLAG) == 0 && int_bits(b, u).is_none() && du != NONE && du != j && self.dominates(
                    du,
                    j,
                ) {
                    f.w[f.nw as usize] = u;
                    f.ws[f.nw as usize] = d < 0;
                    f.nw += 1;
                }
            }
            return;
        }
        let mut kept: u32 = 0;
        for q in 0..f.nw as usize {
            let w = f.w[q];
            let s = if c.is_some() {
                let lw = self.lbound(pk, b, w, UB_DEPTH);
                if lw.is_none() || lw.unwrap() < (c.unwrap() & m) {
                    0u32
                } else {
                    ast::pick(lw.unwrap() > (c.unwrap() & m), 2u32, 1u32)
                }
            } else {
                self.le_of(pk, b, a, w)
            };
            if s != 0 {
                f.w[kept as usize] = w;
                f.ws[kept as usize] = f.ws[q] && s == 2;
                kept += 1;
            }
        }
        f.nw = kept;
    }

    // A value from before join block `j` that `a` is at most as a signed one: `a` itself, else the value a counter
    // down `a` is stays at most (`SHV_KEY`); VNONE for none.
    fn sle_first(self: &Self, b: &Body, j: u32, a: Value) Value {
        if a == VNONE || (a & VFLAG) != 0 || int_bits(b, a).is_some() {
            return VNONE;
        }
        let da = self.def_blk(a);
        if da != NONE && da != j && self.dominates(da, j) {
            return a;
        }
        return switch self.ub.get(&(SHV_KEY | a as u64)) {
            Some(f) => *f,
            None => VNONE,
        };
    }

    // Whether `a <=s w` holds here: `a` is `w`, a counter down from `w` (`SHV_KEY`), or `p - k` (`k` a constant
    // of at least 0) that does not wrap (`p` at least the type's least value plus `k`) of such a `p`.
    fn sle_of(self: &Self, pk: &Package, b: &Body, a: Value, w: Value) bool {
        if a == w {
            return true;
        }
        let mut p = a;
        if is_op(b, a, O_SUB) && int_bits(b, b.insts[a as usize].b).is_some() && (b.insts[a as usize].a & VFLAG) == 0 {
            let t = b.insts[a as usize];
            let bits = type_bits(t.ty, pk.ptr_bytes);
            let k = sign_extend(int_bits(b, t.b).unwrap(), bits) as i128;
            let tmin = (-((width_mask(t.ty, pk.ptr_bytes) >> 1) as i64) - 1) as i128;
            let lo = switch self.srange(pk, b, t.a, UB_DEPTH) {
                Some(r) => r.0 as i128,
                None => tmin,
            };
            if k >= 0 && lo >= tmin + k {
                p = t.a;
            }
        }
        if p == w {
            return true;
        }
        return switch self.ub.get(&(SHV_KEY | p as u64)) {
            Some(f) => *f == w,
            None => false,
        };
    }

    // Whether `a <=u w` holds here: 2 when `a <u w`, 1 when only `a <=u w` is known, 0 when neither.
    fn le_of(self: &Self, pk: &Package, b: &Body, a: Value, w: Value) u32 {
        if a == w {
            return 1;
        }
        if self.below(a, w) || self.offset_order(pk, b, a, w) == Some(true) {
            return 2;
        }
        return ast::pick(self.known_le(a, w) || self.offset_order(pk, b, w, a) == Some(false), 1u32, 0u32);
    }

    // Block `j`, which several edges enter, with every edge's facts recorded (`join_out`): its parameters take
    // them (a bound needs a constant the body holds: `known_const`).
    fn join_in(self: &mut Self, pk: &Package, b: &Body, j: u32) {
        let base = self.jat[j as usize];
        if base == NONE || base == JOIN_BAD || self.jcnt[j as usize] != self.pred_at[j as usize + 1] - self.pred_at[j as usize] {
            return;
        }
        let jb = b.blocks[j as usize];
        for q in 0..(jb.param_len as u32).min(JOIN_MAX) {
            let f = self.jfacts[(base + q) as usize];
            let p = VPARAM | jb.param_start + q;
            if f.dead || self.val(p) != p {
                continue;
            }
            let ty = b.type_of(p);
            let m = width_mask(ty, pk.ptr_bytes);
            let tmax = (m >> 1) as i64;
            let hc = ast::pick(f.hi < m, self.known_const(b, ty, f.hi), NONE);
            let lc = ast::pick(f.lo > 0, self.known_const(b, ty, f.lo), NONE);
            let sl = ast::pick(f.sk && f.slo > -tmax - 1, self.known_const(b, ty, f.slo as u64 & m), NONE);
            let sh = ast::pick(f.sk && f.shi < tmax, self.known_const(b, ty, f.shi as u64 & m), NONE);
            if hc != NONE && self.ub.get(&(p as u64)).is_none() {
                self.enter(LOG_UB, p, hc << 1);
            }
            if lc != NONE && self.ub.get(&(LB_KEY | p as u64)).is_none() {
                self.enter(LOG_UB, LB_KEY | p as u64, lc << 1);
            }
            if sl != NONE {
                self.note_signed(pk, b, p, true, sl, 0);
            }
            if sh != NONE {
                self.note_signed(pk, b, p, false, sh, 0);
            }
            if f.sw != NONE && f.sw != VNONE {
                self.enter(LOG_UB, SHV_KEY | p as u64, f.sw);
            }
            if f.nw != NONE {
                for i in 0..f.nw as usize {
                    self.note_le(p, f.w[i]);
                    if f.ws[i] {
                        self.enter(LOG_REL, rel_key(p, f.w[i]), 1);
                    }
                }
            }
        }
    }

    // The bound `(k, adj)` (`v` is at most `k + adj` when `up`, at least it else; `k` a constant, or a value
    // the caller checks) that signed condition `c` gives `v` where it is `holds`; `(VNONE, 0)` when none. Of
    // the two sides of an `and`, a constant bound first.
    const fn limit_of(b: &Body, c: Value, holds: bool, v: Value, up: bool) (Value, i32) {
        // Both sides of an `and` that holds hold (`ia >= 0 && ib >= 0`).
        if holds && (c & (VPARAM | VFLAG)) == 0 && c != VNONE && is_op(b, c, O_AND) && !is_vec(b.insts[c as usize].ty) {
            let l = Opt::limit_of(b, b.insts[c as usize].a, true, v, up);
            let r = Opt::limit_of(b, b.insts[c as usize].b, true, v, up);
            return if l.0 != VNONE && (int_bits(b, l.0).is_some() || r.0 == VNONE) {
                l
            } else {
                r
            };
        }
        let (x, y, neg) = Opt::as_slt(b, c);
        if x == VNONE || (x & VFLAG) != 0 || (y & VFLAG) != 0 {
            return (VNONE, 0);
        }
        let lt = holds != neg;
        if up && lt && x == v {
            return (y, -1);
        }
        if up && !lt && y == v {
            return (x, 0);
        }
        if !up && lt && y == v {
            return (x, 1);
        }
        if !up && !lt && x == v {
            return (y, 0);
        }
        return (VNONE, 0);
    }

    // Whether condition `t.a` of branch `t`, holding where `holds` (or terminator `t` none: `out`), keeps `a`
    // nonzero: `a != 0`, `a == 0` failing, `0 <u a`, `a <u 1` failing; with `out` (an edge from outside the
    // loop, whose facts are in scope) also a constant other than 0, or `a`'s lower bound of 1.
    fn nonzero_on(self: &Self, pk: &Package, b: &Body, t: Inst, holds: bool, a: Value, out: bool) bool {
        if a == VNONE || (a & VFLAG) != 0 {
            return false;
        }
        let k = int_bits(b, a);
        if k.is_some() {
            return (k.unwrap() & width_mask(b.type_of(a), pk.ptr_bytes)) != 0;
        }
        if out {
            let lo = self.lbound(pk, b, a, UB_DEPTH);
            if lo.is_some() && lo.unwrap() != 0 {
                return true;
            }
        }
        if t.op != O_BR || (t.a & (VPARAM | VFLAG)) != 0 || t.a == VNONE || b.insts[t.a as usize].op != O_ICMP {
            return false;
        }
        let c = b.insts[t.a as usize];
        let zero = |v: Value| int_bits(b, v) == Option::<u64>::Some(0);
        if (c.aux == C_NE && holds || c.aux == C_EQ && !holds) && (c.a == a && zero(c.b) || c.b == a && zero(c.a)) {
            return true;
        }
        let (x, y, neg) = Opt::as_ult(b, t.a);
        let lt = holds != neg;
        // `x <u a` holding makes `a` at least 1 for any `x` (a counter down to a lower one: `while i < j`).
        return x != VNONE && (lt && y == a || !lt && x == a && int_bits(b, y) == Option::<u64>::Some(1));
    }

    // The value `y` from before loop `h` that each edge into it proves its argument for header parameter `q`
    // (`p`) below (`edge_below`, or on a back edge the header's test `hc`), `y` from such a test; VNONE where
    // there is none (a rotated loop's counter, or one that trails it: `i = j` after `j <u n`).
    fn edge_bound(self: &mut Self, pk: &Package, b: &Body, h: u32, q: u32, p: Value, hc: Value, tin: bool) Value {
        // The header's test `hc` (VNONE: none that leaves the loop) as `x <u w` on the side into the loop
        // (`tin`): every back edge is below that side.
        let (hx, hw, hn) = Opt::as_ult(b, hc);
        let hlt = hc != VNONE && hx != VNONE && tin != hn;
        let mut y = VNONE;
        for pass in 0..2u32 {
            for j in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
                let pb = self.preds[j as usize];
                let tp = term(b, pb);
                b.succ_edges(tp, &mut self.edges);
                for d in 0..self.edges.len() {
                    let ed = self.edges[d];
                    if b.edge_target(ed) != h {
                        continue;
                    }
                    let a = self.edge_value(b, self.val(b.edge_arg(ed, q)));
                    let split = tp.op == O_BR && b.edge_target(tp.b) != b.edge_target(tp.c);
                    if pass == 0 {
                        if y == VNONE && split && self.in_loop(h, pb) {
                            let (x, w, neg) = Opt::as_ult(b, tp.a);
                            if x == a && x != VNONE && ed == tp.b != neg && self.outside(w, h) {
                                y = w;
                            }
                        }
                        if y == VNONE && hlt && hx == a && self.in_loop(h, pb) && self.outside(hw, h) {
                            y = hw;
                        }
                        // A parameter the facts keep below a value it is at most (`note_le`).
                        for key in [UP_KEY, UP2_KEY] {
                            if let Some(f) = self.ub.get(&(key | a as u64)) {
                                if y == VNONE && self.in_loop(h, pb) && self.below(a, *f) && self.outside(*f, h) {
                                    y = *f;
                                }
                            }
                        }
                    } else if !self.edge_below(pk, b, tp, split && ed == tp.b, split, a, y, !self.in_loop(h, pb)) && a != p && !(hlt && hx == a && hw == y && self.in_loop(
                        h,
                        pb,
                    )) {
                        return VNONE;
                    }
                }
            }
            if y == VNONE {
                return VNONE;
            }
        }
        return y;
    }

    // Value `v`, or for a parameter of a block with one edge in, the argument that edge passes (a block
    // the walk has not reached yet forwards it later: `forward_params`), at most THROUGH_MAX steps.
    fn edge_value(self: &Self, b: &Body, v: Value) Value {
        let mut a = v;
        // Each step crosses one edge.
        for _ in 0..THROUGH_MAX {
            if a == VNONE || (a & VPARAM) == 0 || (a & ~VPARAM) as usize >= self.pblock.len() {
                return a;
            }
            let k = self.pblock[(a & ~VPARAM) as usize];
            if k == NONE || k == 0 || self.pred_at[k as usize + 1] - self.pred_at[k as usize] != 1 {
                return a;
            }
            let t = term(b, self.preds[self.pred_at[k as usize] as usize]);
            let e = if t.op == O_JMP {
                t.a
            } else if t.op == O_BR && b.edge_target(t.b) != b.edge_target(t.c) {
                ast::pick(b.edge_target(t.b) == k, t.b, t.c)
            } else {
                return a;
            };
            if b.edge_target(e) != k {
                return a;
            }
            a = self.val(b.edge_arg(e, (a & ~VPARAM) - b.blocks[k as usize].param_start));
        }
        return a;
    }

    // Whether the edge of terminator `t` (a branch with distinct targets where `split`, its condition holding
    // where `holds`) keeps `a <u y`: the condition is `a <u y`, or `x <u y` with `a` 0; or the facts in scope
    // (the header's, which hold on its back edges too) give it.
    fn edge_below(self: &Self, pk: &Package, b: &Body, t: Inst, holds: bool, split: bool, a: Value, y: Value, out: bool) bool {
        if a == VNONE || (a & VFLAG) != 0 {
            return false;
        }
        let k = int_bits(b, a);
        if self.below(a, y) {
            return true;
        }
        if out {
            let ly = self.lbound(pk, b, y, UB_DEPTH);
            if k.is_some() && ly.is_some() && (k.unwrap() & width_mask(b.type_of(a), pk.ptr_bytes)) < ly.unwrap() {
                return true;
            }
        }
        if !split {
            return false;
        }
        let (x, w, neg) = Opt::as_ult(b, t.a);
        if x == VNONE || w != y || holds == neg {
            return false;
        }
        if x == a {
            return true;
        }
        return k.is_some() && (k.unwrap() & width_mask(b.type_of(a), pk.ptr_bytes)) == 0;
    }

    // The value `w` from before loop `h` that each edge into it keeps its argument for header parameter `q`
    // (`p`) at most: on a back edge its test `a <=u w` (or `a <u w`), or the argument is `p`; on an edge from
    // outside the argument is 0, `w`, or a value the facts in scope keep at most `w`. VNONE when none (a
    // rotated loop's `while i <= len - 128`).
    fn edge_le(self: &mut Self, b: &Body, h: u32, q: u32, p: Value) Value {
        let mut w = VNONE;
        for pass in 0..2u32 {
            for j in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
                let pb = self.preds[j as usize];
                let tp = term(b, pb);
                let inl = self.in_loop(h, pb);
                b.succ_edges(tp, &mut self.edges);
                for d in 0..self.edges.len() {
                    let ed = self.edges[d];
                    if b.edge_target(ed) != h {
                        continue;
                    }
                    let a0 = self.val(b.edge_arg(ed, q));
                    let a = self.edge_value(b, a0);
                    let (c, holds) = self.edge_cond(b, pb, ed);
                    let (x, y, neg) = Opt::as_ult(b, c);
                    let lt = x != VNONE && holds != neg;
                    // The value the edge's test keeps `a` (or the argument it forwards) at most: `a <u y` holding, `x <u a`
                    // failing.
                    let tw = if lt && (x == a || x == a0) {
                        y
                    } else if x != VNONE && !lt && (y == a || y == a0) {
                        x
                    } else {
                        VNONE
                    };
                    if pass == 0 {
                        if w == VNONE && inl && tw != VNONE && self.outside(tw, h) {
                            w = tw;
                        }
                    } else if !(a == p || inl && tw == w || !inl && (int_bits(b, a) == Some(0u64) || a == w || tw == w || self.known_le(
                        a,
                        w,
                    ))) {
                        return VNONE;
                    }
                }
            }
            if w == VNONE {
                return VNONE;
            }
        }
        return w;
    }

    // The least unsigned value each edge into loop `h` passes for its header parameter `q` (`p`), with its
    // `LB_KEY` entry: the edge's test `a >=u c` (or `c <u a`), or on an edge from outside a constant or the
    // bound the facts in scope give it (`lbound`'s entry); `(0, 0)` when some edge gives none (a counter down
    // by 2 while `i >= 2`).
    fn edge_floor(self: &mut Self, pk: &Package, b: &Body, h: u32, q: u32, p: Value) (u64, u32) {
        let mut best: (u64, u32) = (u64::MAX, 0);
        for j in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
            let pb = self.preds[j as usize];
            let tp = term(b, pb);
            let inl = self.in_loop(h, pb);
            b.succ_edges(tp, &mut self.edges);
            for d in 0..self.edges.len() {
                let ed = self.edges[d];
                if b.edge_target(ed) != h {
                    continue;
                }
                let a0 = self.val(b.edge_arg(ed, q));
                let a = self.edge_value(b, a0);
                if a == p {
                    continue;
                }
                if a == VNONE || (a & VFLAG) != 0 || !is_int(b.type_of(a)) || b.type_of(a) == T_I128 {
                    return (0, 0);
                }
                let m = width_mask(b.type_of(a), pk.ptr_bytes);
                let (c, holds) = self.edge_cond(b, pb, ed);
                let (x, y, neg) = Opt::as_ult(b, c);
                let lt = x != VNONE && holds != neg;
                let mut f: (u64, u32) = (0, 0);
                if lt && (y == a || y == a0) && int_bits(b, x).is_some() && (int_bits(b, x).unwrap() & m) < m {
                    f = ((int_bits(b, x).unwrap() & m) + 1, x << 1 | 1);
                } else if x != VNONE && !lt && (x == a || x == a0) && int_bits(b, y).is_some() {
                    f = (int_bits(b, y).unwrap() & m, y << 1);
                } else if !inl && int_bits(b, a).is_some() {
                    f = (int_bits(b, a).unwrap() & m, a << 1);
                } else if !inl {
                    if let Some(e) = self.ub.get(&(LB_KEY | a as u64)) {
                        let c = int_bits(b, *e >> 1).unwrap() & m;
                        if (*e & 1) == 0 || c < m {
                            f = (c + (*e & 1) as u64, *e);
                        }
                    }
                }
                if f.0 == 0 {
                    return (0, 0);
                }
                if f.0 < best.0 {
                    best = f;
                }
            }
        }
        return ast::pick(best.0 == u64::MAX, (0u64, 0u32), best);
    }

    // The condition that decides edge `ed` out of block `pb`, and whether it holds there: `pb`'s branch, or for
    // a `pb` that only jumps, the branch of its one predecessor into it (a latch after the test). `(VNONE,
    // false)` for none.
    fn edge_cond(self: &Self, b: &Body, pb: u32, ed: u32) (Value, bool) {
        let tp = term(b, pb);
        if tp.op == O_BR && b.edge_target(tp.b) != b.edge_target(tp.c) {
            return (tp.a, ed == tp.b);
        }
        if tp.op != O_JMP || self.pred_at[pb as usize + 1] - self.pred_at[pb as usize] != 1 {
            return (VNONE, false);
        }
        let tq = term(b, self.preds[self.pred_at[pb as usize] as usize]);
        if tq.op != O_BR || b.edge_target(tq.b) == b.edge_target(tq.c) {
            return (VNONE, false);
        }
        return (tq.a, b.edge_target(tq.b) == pb);
    }

    // The room above `p` (`room`) that condition `c`, where it `holds`, leaves: `p <u y` one more than `y`'s,
    // `p <=u y` `y`'s; 0 for none.
    fn step_room(self: &Self, pk: &Package, b: &Body, c: Value, holds: bool, p: Value) u64 {
        let (x, y, neg) = Opt::as_ult(b, c);
        if x == VNONE || !is_int(b.type_of(p)) || b.type_of(p) == T_I128 {
            return 0;
        }
        let lt = holds != neg;
        let m = width_mask(b.type_of(p), pk.ptr_bytes);
        if lt && x == p {
            return self.room(pk, b, y, ROOM_DEPTH).min(m - 1) + 1;
        }
        return ast::pick(!lt && y == p, self.room(pk, b, x, ROOM_DEPTH), 0u64);
    }

    // Whether a back edge of loop `h` passes `p - 1` as header parameter `q`.
    fn steps_down_from(self: &mut Self, b: &Body, h: u32, q: u32, p: Value) bool {
        for j in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
            let pb = self.preds[j as usize];
            if !self.in_loop(h, pb) {
                continue;
            }
            b.succ_edges(term(b, pb), &mut self.edges);
            for d in 0..self.edges.len() {
                if b.edge_target(self.edges[d]) == h && minus_one(b, b.edge_arg(self.edges[d], q), p) {
                    return true;
                }
            }
        }
        return false;
    }

    // Whether back edge value `a` is at most header parameter `p` (`param_bounds`): `p`, a select of such
    // values, or a midpoint of `lo` (VNONE: none) and `p`, `depth` selects deep.
    fn below_param(self: &Self, b: &Body, a: Value, p: Value, lo: Value, depth: u32) bool {
        if a == p {
            return true;
        }
        if depth == 0 || (a & (VPARAM | VFLAG)) != 0 || a == VNONE {
            return false;
        }
        let t = b.insts[a as usize];
        if t.op == O_SELECT && !is_vec(t.ty) {
            return self.below_param(b, t.b, p, lo, depth - 1) && self.below_param(b, t.c, p, lo, depth - 1);
        }
        return lo != VNONE && midpoint(b, a, lo, p);
    }

    // `val(v)` for a value the maps know; a value the walk added is its own.
    const fn val_known(self: &Self, v: Value) Value {
        if v == VNONE || (v & VPARAM) != 0 && (v & ~VPARAM) as usize >= self.prepl.len() || (v & VPARAM) == 0 && (v & ~VFLAG) as usize >= self.repl.len() {
            return v;
        }
        if (v & VFLAG) != 0 && (v & ~VFLAG) as usize >= self.frepl.len() {
            return v;
        }
        return self.val(v);
    }

    // The low bits of `v` known to be 0 (at most the width), `depth` operations deep: a constant's, a sum's or
    // difference's fewest, a product's or shift's sum, an `and`'s most. Parameter `p` counts `assume`; any
    // other parameter counts its own (`param_zeros`) while `depth` lasts.
    fn low_zeros(self: &Self, b: &Body, v: Value, p: Value, assume: u32, depth: u32) u32 {
        if v == p {
            return assume;
        }
        if v == VNONE || (v & VFLAG) != 0 || is_vec(b.type_of(v)) {
            return 0;
        }
        let w = type_bits(b.type_of(v), 8);
        let k = int_bits(b, v);
        if k.is_some() {
            return ast::pick(k.unwrap() == 0, w, (k.unwrap().trailing_zeros() as u32).min(w));
        }
        if depth == 0 {
            return 0;
        }
        if (v & VPARAM) != 0 {
            return if p == VNONE {
                self.param_zeros(b, v, depth - 1)
            } else {
                0
            };
        }
        let t = b.insts[v as usize];
        if t.op != O_ADD && t.op != O_SUB && t.op != O_AND && t.op != O_MUL && t.op != O_SHL {
            return 0;
        }
        let (x, y) = (self.val_known(t.a), self.val_known(t.b));
        if t.op == O_ADD || t.op == O_SUB {
            return self.low_zeros(b, x, p, assume, depth - 1).min(self.low_zeros(b, y, p, assume, depth - 1));
        }
        if t.op == O_AND {
            return self.low_zeros(b, x, p, assume, depth - 1).max(self.low_zeros(b, y, p, assume, depth - 1));
        }
        if t.op == O_MUL {
            return (self.low_zeros(b, x, p, assume, depth - 1) + self.low_zeros(b, y, p, assume, depth - 1)).min(w);
        }
        if t.op == O_SHL && int_bits(b, y).is_some() && int_bits(b, y).unwrap() < w as u64 {
            return (self.low_zeros(b, x, p, assume, depth - 1) + int_bits(b, y).unwrap() as u32).min(w);
        }
        return 0;
    }

    // The low bits of block parameter `a` known to be 0: the fewest of the values the edges into its block
    // pass, by induction over the iterations (the values that pass `a` itself, its own count assumed, keep
    // at least that count).
    fn param_zeros(self: &Self, b: &Body, a: Value, depth: u32) u32 {
        let k = if (a & ~VPARAM) as usize < self.pblock.len() {
            self.def_blk(a)
        } else {
            NONE
        };
        if k == NONE || k == 0 || k as usize >= self.rpo.len() || k as usize + 1 >= self.pred_at.len() || self.rpo[k as usize] == NONE {
            return 0;
        }
        let np = self.pred_at[k as usize + 1] - self.pred_at[k as usize];
        if np == 0 || np > IMPLY_FAN {
            return 0;
        }
        let q = (a & ~VPARAM) - b.blocks[k as usize].param_start;
        let mut s: u32 = 64;
        for pass in 0..2u32 {
            let assume = s;
            let mut m: u32 = 64;
            for x in self.pred_at[k as usize]..self.pred_at[k as usize + 1] {
                let st = term(b, self.preds[x as usize]);
                for e in 0..edge_count(st) {
                    let ed = edge_of(b, st, e);
                    if b.edge_target(ed) == k {
                        m = m.min(self.low_zeros(b, self.val_known(b.edge_arg(ed, q)), a, assume, depth));
                    }
                }
            }
            if pass == 1 && m < s {
                return 0;
            }
            s = m;
            if s == 0 {
                return 0;
            }
        }
        return s.min(type_bits(b.type_of(a), 8));
    }

    // The value of condition `c` the order facts in scope decide (`order_facts`), if any: `x <u y` itself,
    // or `x <u a + 1` false where `a <u x` holds (`a + 1` does not wrap: an inclusive range's second test,
    // `i + 1 <=u last` after `i <u last`).
    fn order_decided(self: &Self, pk: &Package, b: &Body, c: Value) Option<u64> {
        let (x, y, neg) = Opt::as_ult(b, c);
        if x == VNONE {
            // `v == 0` fails, `v != 0` holds, for a `v` of at least 1 (`lbound`: `y | 1`, a divisor).
            if (c & (VPARAM | VFLAG)) == 0 && c != VNONE && is_op(b, c, O_ICMP) && !is_vec(b.insts[c as usize].ty) {
                let t = b.insts[c as usize];
                let v = ast::pick(
                    int_bits(b, t.b) == Option::<u64>::Some(0),
                    t.a,
                    ast::pick(int_bits(b, t.a) == Option::<u64>::Some(0), t.b, VNONE),
                );
                if (t.aux == C_EQ || t.aux == C_NE) && v != VNONE && (v & VFLAG) == 0 && b.type_of(v) != T_I128 {
                    let lo = self.lbound(pk, b, v, UB_DEPTH);
                    if lo.is_some() && lo.unwrap() != 0 {
                        return Some((t.aux == C_NE) as u64);
                    }
                    // `a - q == 0` fails where `q <u a` holds (`a[i..].len()` below `i <u len`).
                    if is_op(b, v, O_SUB) && self.below(b.insts[v as usize].b, b.insts[v as usize].a) {
                        return Some((t.aux == C_NE) as u64);
                    }
                    // `a + 1 == 0` fails where `a` is below some value (`a[..i + 1]` below `i <u len`).
                    if is_op(b, v, O_ADD) && int_bits(b, b.insts[v as usize].b) == Some(1u64) {
                        let a = b.insts[v as usize].a;
                        for key in [UP_KEY, UP2_KEY] {
                            if let Some(f) = self.ub.get(&(key | a as u64)) {
                                if self.below(a, *f) {
                                    return Some((t.aux == C_NE) as u64);
                                }
                            }
                        }
                    }
                }
            }
            return None;
        }
        if let Some(r) = self.rel.get(&rel_key(x, y)) {
            return Some((*r != 0 != neg) as u64);
        }
        // `y <u x` holding makes `x <u y` fail.
        if self.below(y, x) {
            return Some(neg as u64);
        }
        if is_op(b, y, O_ADD) && int_bits(b, b.insts[y as usize].b) == Some(1u64) {
            if let Some(r) = self.rel.get(&rel_key(b.insts[y as usize].a, x)) {
                if *r != 0 {
                    return Some(neg as u64);
                }
            }
        }
        if b.type_of(x) == T_I128 {
            return None;
        }
        // `n <u (k << s) + c` fails where `k <u n >> s` holds and `c <= 2^s`: `k << s` is at most `n - 2^s`, so
        // the sum does not wrap and is at most `n` (a chunk `a[k * w..k * w + w]` of `a.len() / w` chunks).
        let ch = self.chunk_end(pk, b, y);
        if ch.0 != VNONE {
            let w = Inst { op: O_LSHR, ty: b.type_of(x), aux: 0, a: x, b: ch.1, c: VNONE };
            if let Some(z) = self.pure.get(&value_hash(b, w)) {
                if same_value(b, b.insts[(*z) as usize], w) {
                    if let Some(r) = self.rel.get(&rel_key(ch.0, *z)) {
                        if *r != 0 {
                            return Some(neg as u64);
                        }
                    }
                }
            }
        }
        // A value at most `p` (`p - w` that does not wrap, `p >> c`, `p / c`, `p & m`) is below a `y` that `p` is
        // below; `p - w` for a constant `w` of at least 1, below `p`, below a `y` that `p` is at most (`y` itself
        // for `(y >> 1) - 1`).
        let (p, strict) = self.at_most_of(pk, b, x);
        if p != VNONE {
            let lt = switch self.rel.get(&rel_key(p, y)) {
                Some(r) => *r != 0,
                None => false,
            };
            if lt || strict && (self.known_le(p, y) || self.at_most_of(pk, b, p).0 == y) {
                return Some((!neg) as u64);
            }
        }
        // A value at most `y - k` (itself, or an `and` with it; `k` a constant of at least 1) with `y` at least
        // `k` is below `y` (`h & (len - 1)` where `len != 0`).
        let mut sides: [Value; 3] = [x, VNONE, VNONE];
        if is_op(b, x, O_AND) {
            sides[1] = b.insts[x as usize].a;
            sides[2] = b.insts[x as usize].b;
        }
        for q in 0..3usize {
            let s = sides[q];
            if s != VNONE && is_op(b, s, O_SUB) && b.insts[s as usize].a == y && int_bits(b, b.insts[s as usize].b).is_some() {
                let k = int_bits(b, b.insts[s as usize].b).unwrap() & width_mask(b.type_of(y), pk.ptr_bytes);
                let lo = self.lbound(pk, b, y, UB_DEPTH);
                if k != 0 && lo.is_some() && lo.unwrap() >= k {
                    return Some((!neg) as u64);
                }
            }
        }
        // `x <u (x + 1) >> 1` fails where `x + 1` does not wrap: half of `x + 1` rounded down is at most `x`.
        if is_op(b, y, O_LSHR) && int_bits(b, b.insts[y as usize].b) == Some(1u64) && is_op(
            b,
            b.insts[y as usize].a,
            O_ADD,
        ) {
            let s = b.insts[b.insts[y as usize].a as usize];
            let hx = self.ubound(pk, b, x, UB_DEPTH);
            if s.a == x && int_bits(b, s.b) == Some(1u64) && hx.is_some() && hx.unwrap() < width_mask(
                b.type_of(x),
                pk.ptr_bytes,
            ) {
                return Some(neg as u64);
            }
        }
        // `zext(a - 1) <u y` where `a` is at least 1 and `zext(a) <u y` holds (`x[j - 1]` after `x[j]`).
        if is_op(b, x, O_ZEXT) && is_op(b, b.insts[x as usize].a, O_SUB) {
            let d = b.insts[b.insts[x as usize].a as usize];
            let lo = self.lbound(pk, b, d.a, UB_DEPTH);
            if int_bits(b, d.b) == Some(1u64) && lo.is_some() && lo.unwrap() >= 1 {
                let z = Inst { op: O_ZEXT, ty: b.type_of(x), aux: 0, a: d.a, b: VNONE, c: VNONE };
                if let Some(zv) = self.pure.get(&value_hash(b, z)) {
                    if same_value(b, b.insts[(*zv) as usize], z) && self.below(*zv, y) {
                        return Some((!neg) as u64);
                    }
                }
            }
        }
        // `zext(a) <u y` where `a <u trunc(y)` holds: a truncation is at most its operand (`i < len as u32`).
        if is_op(b, x, O_ZEXT) && (b.insts[x as usize].a & VFLAG) == 0 {
            let a = b.insts[x as usize].a;
            let tr = Inst { op: O_TRUNC, ty: b.type_of(a), aux: 0, a: y, b: VNONE, c: VNONE };
            if let Some(tv) = self.pure.get(&value_hash(b, tr)) {
                if same_value(b, b.insts[(*tv) as usize], tr) && self.below(a, *tv) {
                    return Some((!neg) as u64);
                }
            }
        }
        // `x <u x - w` fails where `w <=u x` (`!(x <u w)`): the difference does not wrap (`s[s.len() - n..]`).
        if is_op(b, y, O_SUB) && b.insts[y as usize].a == x {
            let w = b.insts[y as usize].b;
            let le = switch self.rel.get(&rel_key(x, w)) {
                Some(r) => *r == 0,
                None => false,
            };
            if le || self.below(w, x) {
                return Some(neg as u64);
            }
        }
        // `(y - 1) - p <u y` where `p <u y` holds: `p` is at most `y - 1`, so neither difference wraps (the
        // mirror `a[n - 1 - i]` of a counter below `n / 2`, which the facts carry to `n`: `upper_parts`).
        if is_op(b, x, O_SUB) && !is_vec(b.type_of(x)) {
            let d = b.insts[x as usize];
            if is_op(b, d.a, O_SUB) && b.insts[d.a as usize].a == y && int_bits(b, b.insts[d.a as usize].b) == Some(
                1u64,
            ) {
                if let Some(r) = self.rel.get(&rel_key(d.b, y)) {
                    if *r != 0 {
                        return Some((!neg) as u64);
                    }
                }
            }
        }
        // `a - (a >> c)` (`c` at least 1) or `a - a / k` (`k` at least 2) is at least `a >> c` or `a / k`: a
        // value below that part is below the rest (`split_at(len / 2)`: the right half is no shorter).
        if is_op(b, y, O_SUB) && !is_vec(b.type_of(y)) {
            let d = b.insts[y as usize];
            if half_of(b, d.b, d.a) {
                if let Some(r) = self.rel.get(&rel_key(x, d.b)) {
                    if *r != 0 {
                        return Some((!neg) as u64);
                    }
                }
            }
        }
        // `p + k <u y` where `p <u m`, `p` and `m` are multiples of `2^s` above `k`, and `m <=u y` (`y` itself,
        // `y & mask`): `p` is at most `m - 2^s`, so the sum does not wrap and stays below `m` (a stride
        // `a[i + 3]` of a loop `i += 4` while `i < len & -4`).
        if is_op(b, x, O_ADD) && !is_vec(b.type_of(x)) {
            let ad = b.insts[x as usize];
            let k = int_bits(b, ad.b);
            let w = type_bits(ad.ty, 8);
            if k.is_some() && k.unwrap() != 0 && 64 - k.unwrap().leading_zeros() as u32 < w {
                let s = 64 - k.unwrap().leading_zeros() as u32;
                let p = self.val_known(ad.a);
                if self.low_zeros(b, p, VNONE, 0, UB_DEPTH) >= s {
                    let mut ms: [Value; 3] = [y, VNONE, VNONE];
                    for q in 0..2usize {
                        if let Some(f) = self.ub.get(&(ast::pick(q == 0, UP_KEY, UP2_KEY) | p as u64)) {
                            ms[q + 1] = *f;
                        }
                    }
                    for q in 0..3usize {
                        let m = ms[q];
                        if m == VNONE {
                            continue;
                        }
                        let lt = switch self.rel.get(&rel_key(p, m)) {
                            Some(r) => *r != 0,
                            None => false,
                        };
                        let le = m == y || is_op(b, m, O_AND) && (b.insts[m as usize].a == y || b.insts[m as usize].b == y) || self.known_le(
                            m,
                            y,
                        );
                        if lt && le && self.low_zeros(b, m, VNONE, 0, UB_DEPTH) >= s {
                            return Some((!neg) as u64);
                        }
                    }
                }
            }
        }
        // A value at most the largest of its parts (`max_parts`: `abs_diff`, `saturating_sub`, `midpoint`) is
        // below a `y` every part is below.
        let mut parts: [Value; 2] = [VNONE, VNONE];
        let np = max_parts(b, x, &mut parts);
        if np != 0 {
            let mut all = true;
            for q in 0..np as usize {
                all = all && (switch self.rel.get(&rel_key(unsafe parts[q], y)) {
                    Some(r) => *r != 0,
                    None => false,
                });
            }
            if all {
                return Some((!neg) as u64);
            }
        }
        // A value `w` that `x` is at most (`note_le`) below `y`: `x` is too.
        for key in [UP_KEY, UP2_KEY] {
            if let Some(f) = self.ub.get(&(key | x as u64)) {
                let (pw, sw) = self.at_most_of(pk, b, *f);
                if self.below(*f, y) || pw != VNONE && (self.below(pw, y) || sw && self.known_le(pw, y)) {
                    return Some((!neg) as u64);
                }
            }
        }
        // An extension of `a` where `a <u n` holds is below the same extension of `n`, so below a `y` that one
        // is at most: both extensions keep the unsigned order.
        if is_op(b, x, O_ZEXT) || is_op(b, x, O_SEXT) {
            let e = b.insts[x as usize];
            for key in [UP_KEY, UP2_KEY] {
                if let Some(f) = self.ub.get(&(key | e.a as u64)) {
                    let n = *f;
                    let lt = switch self.rel.get(&rel_key(e.a, n)) {
                        Some(r) => *r != 0,
                        None => false,
                    };
                    let w = Inst { op: e.op, ty: e.ty, aux: 0, a: n, b: VNONE, c: VNONE };
                    if lt {
                        if let Some(z) = self.pure.get(&value_hash(b, w)) {
                            if same_value(b, b.insts[(*z) as usize], w) && self.known_le(*z, y) {
                                return Some((!neg) as u64);
                            }
                        }
                    }
                }
            }
        }
        // A midpoint `lo + ((hi - lo) >> c)` where `lo <u hi` holds is below `hi`, so below a `y` that `hi` is
        // at most.
        if is_op(b, x, O_ADD) {
            let ad = b.insts[x as usize];
            for side in 0..2u32 {
                let l = ast::pick(side == 0, ad.a, ad.b);
                let hi = mid_top(b, x, l);
                let holds = hi != VNONE && (switch self.rel.get(&rel_key(l, hi)) {
                    Some(r) => *r != 0,
                    None => false,
                });
                if holds && self.known_le(hi, y) {
                    return Some((!neg) as u64);
                }
            }
        }
        // `(l + h) >> k` where `l <u h` holds and the bounds keep `l + h` from wrapping is below `h`, so below a
        // `y` that `h` is at most (a binary search's `(lo + hi) / 2`).
        let (l0, l1) = half_sum(b, x);
        if l0 != VNONE && b.type_of(x) != T_I128 {
            let m = width_mask(b.type_of(x), pk.ptr_bytes);
            let u0 = self.ubound(pk, b, l0, UB_DEPTH);
            let u1 = self.ubound(pk, b, l1, UB_DEPTH);
            let fits = u0.is_some() && u1.is_some() && u0.unwrap() <= m - u1.unwrap();
            if fits && (self.below(l0, l1) && self.known_le(l1, y) || self.below(l1, l0) && self.known_le(l0, y)) {
                return Some((!neg) as u64);
            }
        }
        // A row's element `q * w + z <u y` where `z <u w`, `q <u h` and `w * h` wraps nowhere and is at most
        // `y`: `q * w + z` is at most `(h - 1) * w + w - 1 = w * h - 1`, so neither wraps (`a[r * w + x]`).
        if (x & (VPARAM | VFLAG)) == 0 && as_plain(b.insts[x as usize]).op == O_ADD && (b.insts[x as usize].aux & OV_SIGNED) == 0 && !is_vec(
            b.insts[x as usize].ty,
        ) {
            let ad = as_plain(b.insts[x as usize]);
            for side in 0..2u32 {
                let (mv, z) = ast::pick(side == 0, (ad.a, ad.b), (ad.b, ad.a));
                if (mv & (VPARAM | VFLAG)) != 0 || as_plain(b.insts[mv as usize]).op != O_MUL || (b.insts[mv as usize].aux & OV_SIGNED) != 0 {
                    continue;
                }
                let mt = b.insts[mv as usize];
                for fs in 0..2u32 {
                    let (q, w) = ast::pick(fs == 0, (mt.a, mt.b), (mt.b, mt.a));
                    if !self.below(z, w) {
                        continue;
                    }
                    for key in [UP_KEY, UP2_KEY] {
                        if let Some(f) = self.ub.get(&(key | q as u64)) {
                            if self.below(q, *f) && self.product_le(pk, b, w, *f, y) {
                                return Some((!neg) as u64);
                            }
                        }
                    }
                }
            }
        }
        let lo = self.lbound(pk, b, y, UB_DEPTH);
        // `p + k <u y` where `p <u w - k` holds, `w - k` does not wrap (`k <=u w`) and `w <=u y`: nor does
        // `p + k`. `w` is `y`, or a value `y` is at most that is at most `y` (an equal one, `note_le`).
        if is_op(b, x, O_ADD) {
            let ad = b.insts[x as usize];
            let k = int_bits(b, ad.b);
            let m = width_mask(ad.ty, pk.ptr_bytes);
            let mut ws: [Value; 3] = [y, VNONE, VNONE];
            for q in 0..2usize {
                if let Some(f) = self.ub.get(&(ast::pick(q == 0, UP_KEY, UP2_KEY) | y as u64)) {
                    if self.known_le(*f, y) {
                        ws[q + 1] = *f;
                    }
                }
            }
            for q in 0..3usize {
                let w = ws[q];
                if w == VNONE || k.is_none() || (k.unwrap() & m) == 0 {
                    continue;
                }
                let lw = ast::pick(q == 0, lo, self.lbound(pk, b, w, UB_DEPTH));
                if lw.is_none() || lw.unwrap() < (k.unwrap() & m) {
                    continue;
                }
                let s = Inst { op: O_SUB, ty: ad.ty, aux: 0, a: w, b: ad.b, c: VNONE };
                if let Some(z) = self.pure.get(&value_hash(b, s)) {
                    if same_value(b, as_plain(b.insts[(*z) as usize]), s) {
                        if let Some(r) = self.rel.get(&rel_key(ad.a, *z)) {
                            if *r != 0 {
                                return Some((!neg) as u64);
                            }
                        }
                    }
                }
            }
        }
        // Bounds that keep every value of `x` below every value of `y`, or none below; `w % y` is below a `y`
        // of at least 1.
        if lo.is_some() && lo.unwrap() != 0 {
            let hi = self.ubound(pk, b, x, UB_DEPTH);
            if hi.is_some() && hi.unwrap() < lo.unwrap() || is_op(b, x, O_UREM) && b.insts[x as usize].b == y {
                return Some((!neg) as u64);
            }
        }
        let hy = self.ubound(pk, b, y, UB_DEPTH);
        if hy.is_some() {
            let lx = self.lbound(pk, b, x, UB_DEPTH);
            if lx.is_some() && lx.unwrap() >= hy.unwrap() {
                return Some(neg as u64);
            }
        }
        // A signed minimum of two values at least 0 is at most each as an unsigned one: below a `y` one of them is
        // below (`min(max(i, 0), len - 1)`).
        let (ma, mb) = extreme_arms(b, x, false);
        if ma != VNONE && self.srange(pk, b, ma, UB_DEPTH).unwrap_or((-1, 0)).0 >= 0 && self.srange(pk, b, mb, UB_DEPTH).unwrap_or(
            (-1, 0),
        ).0 >= 0 {
            for v in [ma, mb] {
                if self.below(v, y) || self.offset_order(pk, b, v, y) == Some(true) {
                    return Some((!neg) as u64);
                }
            }
        }
        // A select whose every value is below `y` (`v[if c { a } else if d { b } else { e }]` after three checks).
        if self.arms_below(pk, b, x, y, MIN_DEPTH) {
            return Some((!neg) as u64);
        }
        return switch self.offset_order(pk, b, x, y) {
            Some(lt) => Some((lt != neg) as u64),
            None => None,
        };
    }

    // Whether select `x` (selects of selects, `depth` deep) takes only values the order facts keep below `y`, or
    // constants below `y`'s least value.
    fn arms_below(self: &Self, pk: &Package, b: &Body, x: Value, y: Value, depth: u32) bool {
        if depth == 0 || x == VNONE || (x & (VPARAM | VFLAG)) != 0 || !is_op(b, x, O_SELECT) || is_vec(b.type_of(x)) {
            return false;
        }
        let t = b.insts[x as usize];
        let lo = self.lbound(pk, b, y, UB_DEPTH);
        for side in 0..2u32 {
            let a = ast::pick(side == 0, t.b, t.c);
            let k = int_bits(b, a);
            let ok = self.below(a, y) || k.is_some() && lo.is_some() && (k.unwrap() & width_mask(
                b.type_of(a),
                pk.ptr_bytes,
            )) < lo.unwrap() || self.arms_below(pk, b, a, y, depth - 1);
            if !ok {
                return false;
            }
        }
        return true;
    }

    // Whether `x <u y` holds (true) or fails (false) by offsets that do not wrap (`offset_form`): `x` as
    // `xa + dx` and `y` as `ya + dy`, each base at most a value of its own at an offset (`uppers`). `x <u y`
    // holds where an upper value `u + d` of `xa` has `u` equal to `ya` (`d + dx < dy`), below it (`d + dx <= dy`)
    // or at most it (`d + dx < dy`); it fails where an upper value of `ya` meets `xa` the same way (`y <= x`).
    // None when neither (`s[i - 32..i]` under `i <= len`, `a[i + 32]` under `i <= len - 128`).
    fn offset_order(self: &Self, pk: &Package, b: &Body, x: Value, y: Value) Option<bool> {
        let ty = b.type_of(x);
        if !is_int(ty) || ty == T_I128 || is_vec(ty) || (x & VFLAG) != 0 || (y & VFLAG) != 0 {
            return None;
        }
        let (xa, dx) = self.offset_form(pk, b, x);
        let (ya, dy) = self.offset_form(pk, b, y);
        let mut ux: [(Value, i64); 3] = [(VNONE, 0); 3];
        let mut uy: [(Value, i64); 3] = [(VNONE, 0); 3];
        let nx = self.uppers(pk, b, xa, &mut ux);
        let ny = self.uppers(pk, b, ya, &mut uy);
        for side in 0..2u32 {
            // Side 0: `x <= u + d + dx` against `ya + dy`; side 1: `y <= u + d + dy` against `xa + dx`.
            let (us, n, lo, dl, dh) = ast::pick(side == 0, (ux, nx, ya, dy, dx), (uy, ny, xa, dx, dy));
            for q in 0..n {
                let (u, d) = us[q];
                let s: i128 = d + dh;
                let (eq, lt, le) = (u == lo, u != lo && self.below(u, lo), u != lo && self.known_le(u, lo));
                // `x <u y` needs `x <= y - 1`; `y <= x` needs `y <= x`.
                let gap = ast::pick(side == 0, 1i128, 0i128);
                if (eq || le) && s + gap <= dl || lt && s + gap <= dl + 1 {
                    return Some(side == 0);
                }
            }
        }
        return None;
    }

    // Integer `v` as `a + d` (`d` a constant within 2^62 either way) where the sum or difference does not wrap:
    // `a - k` where `a` is at least `k` or the result at most the greatest value less `k`; `a + k` where `a`'s
    // room (`room`) is at least `k` or the result at least `k`. `(v, 0)` else.
    fn offset_form(self: &Self, pk: &Package, b: &Body, v: Value) (Value, i64) {
        if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || is_vec(b.type_of(v)) || b.type_of(v) == T_I128 {
            return (v, 0);
        }
        let t = b.insts[v as usize];
        let unsigned = (t.aux & OV_SIGNED) == 0;
        let sub = t.op == O_SUB || t.op == O_SUBO && unsigned;
        if !sub && t.op != O_ADD && !(t.op == O_ADDO && unsigned) || (t.a & VFLAG) != 0 || int_bits(b, t.a).is_some() {
            return (v, 0);
        }
        let kb = int_bits(b, t.b);
        if kb.is_none() {
            return (v, 0);
        }
        let m = width_mask(t.ty, pk.ptr_bytes);
        let mut k = kb.unwrap() & m;
        let mut down = sub;
        // `a + k` for a `k` past half the type is `a - (2^w - k)`.
        if k > m >> 1 {
            k = m - k + 1;
            down = !down;
        }
        if k == 0 || k > 1u64 << 62 {
            return (v, 0);
        }
        let exact = if down {
            let lo = self.lbound(pk, b, t.a, UB_DEPTH);
            let hi = self.ubound(pk, b, v, UB_DEPTH);
            lo.is_some() && lo.unwrap() >= k || hi.is_some() && hi.unwrap() <= m - k
        } else {
            let lo = self.lbound(pk, b, v, UB_DEPTH);
            self.room(pk, b, t.a, ROOM_DEPTH) >= k || lo.is_some() && lo.unwrap() >= k
        };
        return ast::pick(exact, (t.a, ast::pick(down, -(k as i64), k as i64)), (v, 0i64));
    }

    // The values `(u, d)` with `a <=u u + d` here, `u + d` not wrapping, into `out`: `(a, 0)`, and for each value
    // `f` the facts keep `a` at most (`note_le`) its offset form (`offset_form`), less 1 where `a <u f`. Their
    // count.
    fn uppers(self: &Self, pk: &Package, b: &Body, a: Value, out: &mut [(Value, i64); 3]) usize {
        out[0] = (a, 0);
        let mut n: usize = 1;
        if a == VNONE || (a & VFLAG) != 0 {
            return n;
        }
        for key in [UP_KEY, UP2_KEY] {
            if let Some(f) = self.ub.get(&(key | a as u64)) {
                if *f == a || (*f & VFLAG) != 0 || b.type_of(*f) != b.type_of(a) {
                    continue;
                }
                let (u, d) = self.offset_form(pk, b, *f);
                out[n] = (u, d - self.below(a, *f) as i64);
                n += 1;
            }
        }
        return n;
    }

    // The least distance from integer `v` up to its type's greatest value here, `depth` steps deep (0 when none
    // is known): its bound's (`ubound`); that of a value the facts keep `v` at most (`note_le`), one more where
    // `v` is below it; `k` more than `a`'s for `v` a difference `a - k` that does not wrap.
    fn room(self: &Self, pk: &Package, b: &Body, v: Value, depth: u32) u64 {
        if v == VNONE || (v & VFLAG) != 0 || !is_int(b.type_of(v)) || is_vec(b.type_of(v)) || b.type_of(v) == T_I128 {
            return 0;
        }
        let m = width_mask(b.type_of(v), pk.ptr_bytes);
        let mut best: u64 = 0;
        if let Some(u) = self.ubound(pk, b, v, UB_DEPTH) {
            best = m - u.min(m);
        }
        if depth == 0 {
            return best;
        }
        for key in [UP_KEY, UP2_KEY] {
            if let Some(f) = self.ub.get(&(key | v as u64)) {
                if *f != v && (*f & VFLAG) == 0 && b.type_of(*f) == b.type_of(v) {
                    let r = self.room(pk, b, *f, depth - 1).saturating_add(self.below(v, *f) as u64).min(m);
                    best = best.max(r);
                }
            }
        }
        if (v & VPARAM) == 0 && is_op(b, v, O_SUB) {
            let t = b.insts[v as usize];
            let k = int_bits(b, t.b);
            if k.is_some() && (k.unwrap() & m) <= m >> 1 && (t.a & VFLAG) == 0 {
                let lo = self.lbound(pk, b, t.a, UB_DEPTH);
                if lo.is_some() && lo.unwrap() >= (k.unwrap() & m) {
                    best = best.max(self.room(pk, b, t.a, depth - 1).saturating_add(k.unwrap() & m).min(m));
                }
            }
        }
        return best;
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
        // The entry's parameters take the caller's values: with no other, none is replaced.
        if np == b.blocks[0].param_len as usize {
            return false;
        }
        self.pc_uf.truncate(0);
        for q in 0..np {
            self.pc_uf.push(q as u32);
        }
        fill(&mut self.pc_ext, np, VNONE);
        fill(&mut self.pc_bad, np, false);
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
                                    let (ra, rq) = (set_of(&mut self.pc_uf, ap), set_of(&mut self.pc_uf, pq));
                                    self.pc_uf[ra as usize] = rq;
                                }
                                continue;
                            }
                            let r = set_of(&mut self.pc_uf, pq) as usize;
                            if member && set_of(&mut self.pc_uf, ap) as usize == r {
                                continue;
                            }
                            if self.pc_ext[r] == VNONE {
                                self.pc_ext[r] = a;
                            } else if self.pc_ext[r] != a && !same_iconst(b, self.pc_ext[r], a) {
                                self.pc_bad[r] = true;
                            }
                        }
                    }
                }
            }
        }
        // The entry's parameters take the caller's values.
        let e0 = b.blocks[0];
        for q in e0.param_start..e0.param_start + e0.param_len as u32 {
            let r = set_of(&mut self.pc_uf, q) as usize;
            self.pc_bad[r] = true;
        }
        let mut any = false;
        for q in 0..np as u32 {
            let r = set_of(&mut self.pc_uf, q) as usize;
            let v = self.pc_ext[r];
            if self.pc_bad[r] || v == VNONE || (v & VFLAG) != 0 || self.rpo[self.pblock[q as usize] as usize] == NONE {
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

    // Each parameter of block `k` that every edge in passes one value (`prepl`), the edges of its
    // predecessors at the walk's start. A block a rewrite of this walk gave an edge from another block
    // (`common_true`'s merged branch, JOIN_BAD) has an edge that list misses: none.
    fn same_args(self: &mut Self, b: &Body, k: u32) bool {
        if self.jat[k as usize] == JOIN_BAD {
            return false;
        }
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
        self.tdirty.truncate(0);
        let nb = b.blocks.len();
        fill(&mut self.hdr, nb, false);
        for k in 0..nb {
            for x in self.pred_at[k]..self.pred_at[k + 1] {
                if self.rpo[k] != NONE && self.dominates(k as u32, self.preds[x as usize]) {
                    self.hdr[k] = true;
                }
            }
        }
        // Per parameter and per instruction: how many instructions read it (up to 2; `readers` for an
        // instruction), the last one for a parameter, and the nearest block that dominates every block
        // outside its own that reads it (`preader`, `ireader`: NONE for none, MULTI for a reader no path
        // reaches). An edge's argument is read in its terminator's block; one of the value's own block is
        // read inside it (`through` checks the edge it threads along). The instructions' counts as
        // `readers` makes them, in this walk over the operands when they are not those of the tables.
        let count = !self.counted;
        if count {
            self.counted = true;
            fill(&mut self.icount, b.insts.len(), 0);
            fill(&mut self.in_or, b.insts.len(), false);
        }
        fill(&mut self.pcount, b.params.len(), 0);
        fill(&mut self.puser, b.params.len(), NONE);
        fill(&mut self.preader, b.params.len(), NONE);
        fill(&mut self.ireader, b.insts.len(), NONE);
        for k in 0..nb {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let is_or = count && b.insts[i as usize].op == O_OR;
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
                        if count && self.icount[x] < 2 {
                            self.icount[x] += 1;
                        }
                        if is_or {
                            self.in_or[x] = true;
                        }
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
            // The edges moved, the blocks stand: the successors, the order and the predecessors again, the
            // dominators to come; the operands of the terminators and of `param_cmp`'s rewrites again, the
            // others' moved (`splice_ops`); its constants in no block.
            self.cfg(b);
            self.pred_lists(nb);
            for _ in self.blk_of.len()..b.insts.len() {
                self.blk_of.push(NONE);
            }
            self.lsort.truncate(0);
            for k in 0..nb {
                let bk = b.blocks[k];
                self.lsort.push(bk.start + bk.len - 1);
            }
            self.lsort.extend_copy(&self.tdirty);
            self.lsort.sort();
            self.splice_ops(b);
            self.kept = K_GRAPH;
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
        let k = int_bits(b, t.b);
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
                    let c = int_bits(b, a);
                    let sel = c.is_none() && (a & (VPARAM | VFLAG)) == 0 && b.insts[a as usize].op == O_SELECT && self.icount[a as usize] == 1 && int_bits(
                        b,
                        b.insts[a as usize].b,
                    ).is_some() && int_bits(b, b.insts[a as usize].c).is_some();
                    if c.is_none() && !sel {
                        return false;
                    }
                    if pass == 1 && sel {
                        let st = b.insts[a as usize];
                        let r0 = le::icmp(t.aux, ty, pk.ptr_bytes, int_bits(b, st.b).unwrap(), k.unwrap()) as u64;
                        let r1 = le::icmp(t.aux, ty, pk.ptr_bytes, int_bits(b, st.c).unwrap(), k.unwrap()) as u64;
                        let x0 = self.tconst(b, t.ty, r0);
                        let x1 = self.tconst(b, t.ty, r1);
                        b.insts[a as usize] = Inst { op: O_SELECT, ty: t.ty, aux: 0, a: st.a, b: x0, c: x1 };
                        self.tdirty.push(a);
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
        self.tdirty.push(u);
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
            (p, ast::pick(b.edge_target(pt.b) == k, pt.b, pt.c))
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
                let ed = edge_of(b, st, q);
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
        // The usual case: one dominates the other (the tables of `thread`'s K_DOM).
        if self.dominates(r, k) {
            return r;
        }
        if self.dominates(k, r) {
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
        return ast::pick((v & VFLAG) == 0 && self.made_in(v, j), VNONE, v);
    }

    // Whether instruction `i` is one of block `j`'s; a constant `thread` made (`tconst`) is no block's.
    const fn made_in(self: &Self, i: u32, j: u32) bool {
        return i as usize < self.blk_of.len() && self.blk_of[i as usize] == j;
    }

    // Whether value `a` equals constant `c` where edge `e` of block `k`'s terminator leaves, as the
    // branches before it settle: `k`'s branch on an equality of `a` with a constant (or on an `and` of
    // conditions that holds along the edge, an `or` that does not: `cond_fact`), else what holds where
    // `k` starts (`entry_fact`); None when they do not.
    fn implied(self: &Self, pk: &Package, b: &Body, k: u32, e: u32, a: Value, c: u64, depth: u32) Option<bool> {
        let m = width_mask(b.type_of(a), pk.ptr_bytes);
        let ka = int_bits(b, a);
        if ka.is_some() {
            return Some((ka.unwrap() & m) == (c & m));
        }
        let t = term(b, k);
        if t.op == O_BR && (e == t.b || e == t.c) && !same_edge(b, t.b, t.c) {
            let r = cond_fact(b, t.a, e == t.b, a, c, m, CCMP_DEPTH);
            if r.is_some() {
                return r;
            }
        }
        return self.entry_fact(pk, b, k, a, c, depth);
    }

    // Null test `i` (block `k`) of an element address of a slice parameter (`slice_of`), `p == 0` or
    // `p != 0`, where the branches before `k` make the slice not empty (`len_set_at`): the constant.
    // Whether it did.
    fn null_test(self: &Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if t.aux != C_EQ && t.aux != C_NE || int_bits(b, t.b) != Some(0u64) {
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
                    b: ast::pick(side == 0, d, z),
                    c: ast::pick(side == 0, z, d),
                },
            );
            b.insts[i as usize] = Inst { op: o.op, ty: t.ty, aux: 0, a: a, b: s, c: VNONE };
            return true;
        }
        return false;
    }

    // Select `i` of block `k` between two loads of its block alike (type, offset, flags; not volatile, no
    // bound) that only it reads, with no write from the first to it: one load of the selected address
    // (both ran, so the one left reads nothing new). Whether it did.
    fn select_loads(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if !is_op(b, t.b, O_LOAD) || !is_op(b, t.c, O_LOAD) || t.b == t.c || !self.made_in(t.b, k) || !self.made_in(
            t.c,
            k,
        ) {
            return false;
        }
        let x = b.insts[t.b as usize];
        let y = b.insts[t.c as usize];
        if x.ty != t.ty || y.ty != t.ty || x.aux != y.aux || x.c != y.c || (x.aux & (MEM_VOLATILE | MEM_RANGE)) != 0 || !is_int(
            t.ty,
        ) && t.ty != T_PTR && t.ty != T_F32 && t.ty != T_F64 {
            return false;
        }
        let first = t.b.min(t.c);
        for j in first + 1..i {
            if writes(pk, b, b.insts[j as usize]) {
                return false;
            }
        }
        // Only the select reads them (`readers`, the loads the walk made after the tables by a body scan):
        // else both loads stay with the one added.
        self.readers(b);
        let n0 = self.ops_at.len() as u32 - 1;
        for v in [t.b, t.c] {
            if if v < n0 {
                self.icount[v as usize] != 1
            } else {
                !only_use(b, v, i)
            } {
                return false;
            }
        }
        let s = self.before(b, k, i, Inst { op: O_SELECT, ty: b.type_of(x.a), aux: 0, a: t.a, b: x.a, c: y.a });
        b.insts[i as usize] = Inst { op: O_LOAD, ty: t.ty, aux: x.aux, a: s, b: VNONE, c: x.c };
        return true;
    }

    // Select or `add`, `sub`, `and`, `or`, `xor` `i` of block `k` (in no loop) whose operands are
    // truncations from one wider integer type, or constants, at least one a truncation: the truncation of
    // that operation on the wide values (a constant sign-extended), whose result dies there, where a
    // truncation of a value that stays live takes a copy. Outside loops, so a vector loop keeps its narrow
    // lanes; a select of 32 bits or more, as wasm masks a narrower truncation the narrow select needs not.
    // Whether it did.
    fn wide_trunc(self: &mut Self, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        let sel = t.op == O_SELECT;
        let alu = t.op == O_ADD || t.op == O_SUB || t.op == O_AND || t.op == O_OR || t.op == O_XOR;
        if !sel && !alu || self.inner[k as usize] != NONE || !is_int(t.ty) || t.ty == T_PTR || t.ty == T_I128 || sel && type_bits(
            t.ty,
            8,
        ) < 32 {
            return false;
        }
        let (x, y) = if sel {
            (t.b, t.c)
        } else {
            (t.a, t.b)
        };
        let xy = [x, y];
        let mut wt: u8 = 0;
        for q in 0..2u32 {
            let v = xy[q as usize];
            if is_op(b, v, O_TRUNC) {
                let w = b.type_of(b.insts[v as usize].a);
                if wt != 0 && w != wt || !is_int(w) || w == T_PTR || w == T_I128 {
                    return false;
                }
                wt = w;
            } else if int_bits(b, v).is_none() {
                return false;
            }
        }
        if wt == 0 {
            return false;
        }
        let bits = type_bits(t.ty, 8);
        let mut wide = [VNONE, VNONE];
        for q in 0..2u32 {
            let v = xy[q as usize];
            wide[q as usize] = if is_op(b, v, O_TRUNC) {
                b.insts[v as usize].a
            } else {
                let c = int_bits(b, v).unwrap();
                let s = if bits < 64 && (c >> (bits - 1) as u64 & 1) != 0 {
                    c | u64::MAX << bits as u64
                } else {
                    c
                };
                self.constant(b, wt, s)
            };
        }
        let u = if sel {
            Inst { op: O_SELECT, ty: wt, aux: 0, a: t.a, b: wide[0], c: wide[1] }
        } else {
            Inst { op: t.op, ty: wt, aux: 0, a: wide[0], b: wide[1], c: VNONE }
        };
        let w = self.before(b, k, i, u);
        b.insts[i as usize] = Inst { op: O_TRUNC, ty: t.ty, aux: 0, a: w, b: VNONE, c: VNONE };
        return true;
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

    // The parameters of loop header `k` (at most SAME_MAX) that are an earlier one of its own plus a
    // constant: the edges from outside the loop pass two constants `d` apart, each other edge the sum (or
    // difference) of each with one other operand (`j += 1` on both sides of a branch beside `i += 1`), so
    // by induction the later one is the earlier plus `d` at every iteration, modulo its bits. The later one
    // is that sum, made at the header's start (`prepl`; LLVM's IndVarSimplify rewrites such inductions
    // through the canonical one). Whether any is.
    fn offset_params(self: &mut Self, b: &mut Body, k: u32) bool {
        let kb = b.blocks[k as usize];
        let np = kb.param_len as u32;
        if np < 2 || np > SAME_MAX || self.rpo[k as usize] == NONE || kb.len == 0 {
            return false;
        }
        let mut any = false;
        for q in 1..np {
            let vq = VPARAM | kb.param_start + q;
            let ty = b.params[(kb.param_start + q) as usize];
            if self.prepl[(kb.param_start + q) as usize] != VNONE || !is_int(ty) || ty == T_I128 {
                continue;
            }
            for p0 in 0..q {
                let vp = VPARAM | kb.param_start + p0;
                if b.params[(kb.param_start + p0) as usize] != ty || self.prepl[(kb.param_start + p0) as usize] != VNONE {
                    continue;
                }
                let d = self.args_apart(b, k, p0, q, vp, vq, ty);
                if d == 0 {
                    continue;
                }
                let dc = self.before(b, k, kb.start, iconst(ty, d));
                let v = self.before(b, k, kb.start, Inst { op: O_ADD, ty: ty, aux: 0, a: vp, b: dc, c: 0 });
                self.prepl[(kb.param_start + q) as usize] = v;
                any = true;
                break;
            }
        }
        return any;
    }

    // `offset_params` of block `k`'s parameters `p` and `q` (values `vp`, `vq`, of type `ty`): the
    // constant `q - p` modulo the bits of `ty`, 0 when they are not that apart (or equal).
    fn args_apart(self: &mut Self, b: &Body, k: u32, p: u32, q: u32, vp: Value, vq: Value, ty: u8) u64 {
        let m = mask_of(type_bits(ty, 8));
        let mut d: u64 = 0;
        let mut seen = false;
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
                let a = self.one_arg(b, self.val(b.edge_arg(ed, p)));
                let c = self.one_arg(b, self.val(b.edge_arg(ed, q)));
                let (ka, kc) = (int_bits(b, a), int_bits(b, c));
                if ka.is_some() && kc.is_some() {
                    let dd = kc.unwrap().wrapping_sub(ka.unwrap()) & m;
                    if seen && dd != d {
                        return 0;
                    }
                    d = dd;
                    seen = true;
                    continue;
                }
                if (a & (VPARAM | VFLAG)) != 0 || (c & (VPARAM | VFLAG)) != 0 || a == VNONE || c == VNONE {
                    return 0;
                }
                let ta = b.insts[a as usize];
                let tc = b.insts[c as usize];
                let same_op = ta.op == tc.op && ta.ty == tc.ty && ta.aux == tc.aux && (ta.op == O_ADD || ta.op == O_SUB);
                let steps = same_op && (self.val(ta.a) == vp && self.val(tc.a) == vq && self.val(ta.b) == self.val(tc.b) || ta.op == O_ADD && self.val(
                    ta.b,
                ) == vp && self.val(tc.b) == vq && self.val(ta.a) == self.val(tc.a));
                if !steps {
                    return 0;
                }
            }
        }
        return ast::pick(seen, d, 0u64);
    }

    // Value `v`, or, when `v` is a parameter of a block every edge into which passes it one value (a join
    // of two sides that both step an induction), that value.
    fn one_arg(self: &Self, b: &Body, v: Value) Value {
        if v == VNONE || (v & VPARAM) == 0 || (v & VFLAG) != 0 {
            return v;
        }
        let j = self.pblock[(v & ~VPARAM) as usize];
        let jb = b.blocks[j as usize];
        let q = (v & ~VPARAM) - jb.param_start;
        let mut w = VNONE;
        // Jumps and branches into the block (a switch: `v`).
        for x in self.pred_at[j as usize]..self.pred_at[j as usize + 1] {
            let t = term(b, self.preds[x as usize]);
            let es: [u32; 2] = if t.op == O_JMP {
                [t.a, t.a]
            } else if t.op == O_BR {
                [t.b, t.c]
            } else {
                return v;
            };
            for ed in es {
                if b.edge_target(ed) != j {
                    continue;
                }
                let a = self.val(b.edge_arg(ed, q));
                if a == VNONE || a == v || w != VNONE && a != w {
                    return v;
                }
                w = a;
            }
        }
        return ast::pick(w == VNONE, v, w);
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

    // Branch `i` of `b`: each edge argument that is a select on the branch's condition, or on the opposite
    // comparison, takes the side the edge implies (`select(c, x, y)` passed where `c` holds is `x`); the
    // branch's comparison itself is 1 along the true edge and 0 along the other (when they differ). An edge
    // it changes becomes the branch's own first: terminators may share one. Whether any did.
    fn edge_selects(self: &mut Self, b: &mut Body, i: u32) bool {
        let t = b.insts[i as usize];
        let test = is_op(b, t.a, O_ICMP) && !same_edge(b, t.b, t.c);
        let mut any = false;
        for q in 0..2u32 {
            let mut e = ast::pick(q == 0, t.b, t.c);
            // Where the edge runs, the condition holds (the true edge) or fails.
            let holds = q == 0;
            let mut own = false;
            for k in 0..b.edge_nargs(e) {
                let v = b.edge_arg(e, k);
                let mut w = VNONE;
                if test && v == t.a {
                    w = self.constant(b, b.type_of(v), ast::pick(holds, 1u64, 0u64));
                } else if is_op(b, v, O_SELECT) {
                    let s = b.insts[v as usize];
                    let same = s.a == t.a;
                    let mut opp = false;
                    if !same && is_op(b, s.a, O_ICMP) && is_op(b, t.a, O_ICMP) {
                        let x = b.insts[s.a as usize];
                        let y = b.insts[t.a as usize];
                        opp = x.a == y.a && x.b == y.b && x.aux == opposite(y.aux);
                    }
                    if same || opp {
                        w = ast::pick(same == holds, s.b, s.c);
                    }
                }
                if w == VNONE {
                    continue;
                }
                if !own {
                    e = own_edge(b, i, q);
                    own = true;
                }
                b.pool[(e + 2 + k) as usize] = w;
                any = true;
            }
        }
        return any;
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
                return ast::pick(r == 1 == (b.edge_target(st.b) == k), 1, 2);
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
                let ed = edge_of(b, st, n);
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
            None => self.order_decided(pk, b, s.a),
        };
        if c.is_none() && is_op(b, s.a, O_ICMP) {
            let e = b.insts[s.a as usize];
            let kb = int_bits(b, e.b);
            if (e.aux == C_EQ || e.aux == C_NE) && kb.is_some() && int_bits(b, e.a).is_none() {
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
                    let ed = edge_of(b, st, n);
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
            let ed = edge_of(b, st, n);
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
            return int_bits(b, a);
        }
        if (v & VFLAG) != 0 || self.blk_of[v as usize] != j || depth == 0 {
            return int_bits(b, v);
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
            return int_bits(b, v);
        }
        if t.op == O_SELECT {
            let c = self.decide(pk, b, k, j, e, t.a, cond, holds, depth - 1);
            if c.is_none() {
                return c;
            }
            return self.decide(pk, b, k, j, e, ast::pick(c.unwrap() != 0, t.b, t.c), cond, holds, depth - 1);
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
            return ast::pick(r == VNONE, v, r);
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

    // The integer constant of type `ty` and bits `v` (truncated to it) the dominating blocks hold or the walk
    // made (`constant`); NONE when none: a fact needs no new instruction, which only a changed body places.
    fn known_const(self: &Self, b: &Body, ty: u8, v: u64) Value {
        let t = iconst(ty, v);
        let h = hash(t);
        for m in 0..2u32 {
            let found = switch ast::pick(m == 0, &self.pure, &self.made).get(&h) {
                Some(x) => *x,
                None => NONE,
            };
            if found != NONE && same(b.insts[found as usize], t) {
                return found;
            }
        }
        return NONE;
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

    // Unsigned checked sum or product `i` of block `k` that the bounds in scope keep below the type's
    // greatest value (`ubound`, or a sum with a constant the other operand's `room` holds): a plain one, its
    // flag 0, numbered as one. Whether it is.
    fn checked_range(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if (t.aux & OV_SIGNED) != 0 || is_vec(t.ty) || t.ty == T_I128 || int_bits(b, t.a).is_some() && int_bits(b, t.b).is_some() {
            return false;
        }
        let m = width_mask(t.ty, pk.ptr_bytes);
        let x = self.ubound(pk, b, t.a, UB_DEPTH);
        let y = self.ubound(pk, b, t.b, UB_DEPTH);
        if x.is_none() || y.is_none() || if t.op == O_ADDO {
            x.unwrap() > m - y.unwrap()
        } else {
            y.unwrap() != 0 && x.unwrap() > m / y.unwrap()
        } {
            // A constant added within the other operand's room (`room`: `i + 32` where `i <= len - 128`).
            let (v, k) = ast::pick(int_bits(b, t.b).is_some(), (t.a, int_bits(b, t.b)), (t.b, int_bits(b, t.a)));
            if t.op != O_ADDO || k.is_none() || self.room(pk, b, v, ROOM_DEPTH) < (k.unwrap() & m) {
                return false;
            }
        }
        b.insts[i as usize] = Inst {
            op: ast::pick(t.op == O_ADDO, O_ADD, O_MUL),
            ty: t.ty,
            aux: 0,
            a: t.a,
            b: t.b,
            c: VNONE,
        };
        self.frepl[i as usize] = self.constant(b, T_I8, 0);
        let _ = self.number(pk, b, k, i);
        return true;
    }

    // Checked operation `i` of constants, or of an identity (`x + 0`, `x - 0`, `x * 1`, `x * 0`): its value
    // and flag replaced by the result and a constant flag. Whether it folded.
    fn fold_checked(self: &mut Self, pk: &Package, b: &mut Body, i: u32) bool {
        let t = b.insts[i as usize];
        if is_vec(t.ty) || t.ty == T_I128 {
            return false;
        }
        let ca = int_bits(b, t.a);
        let cb = int_bits(b, t.b);
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
                int_bits(b, t.a)
            } else {
                Option::<u64>::None
            };
            if t.op == O_BR && c.is_none() {
                if let Some(x) = self.cond.get(&(t.a as u64)) {
                    c = Some(*x);
                } else {
                    c = self.order_decided(pk, b, t.a);
                }
            }
            if t.op == O_BR && c.is_some() {
                t = jump(ast::pick(c.unwrap() != 0, t.b, t.c));
            } else if t.op == O_BR {
                // The if-conversions first, which speculate the sides; then sides that differ in operands
                // alone; then a branch to a common true side (`common_true`); else the instructions both
                // sides compute move before the branch (`hoist_common`).
                let e = self.diamond(pk, b, k, i, t);
                if e != NONE {
                    t = jump(e);
                } else {
                    let r = self.ret_diamond(pk, b, k, i, t);
                    if r != NONE {
                        t = Inst { op: O_RET, ty: T_NONE, aux: 0, a: r, b: VNONE, c: VNONE };
                    } else {
                        let e2 = self.twin_sides(pk, b, k, i, t);
                        if e2 != NONE {
                            t = jump(e2);
                        } else {
                            let t2 = self.common_true(pk, b, k, i, t);
                            if t2.a == t.a && t2.b == t.b && t2.c == t.c {
                                self.hoist_common(pk, b, k, t);
                            }
                            t = t2;
                        }
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
            self.join_out(pk, b, k, t0, t);
            b.insts[i as usize] = t;
            return !same(t, t0);
        }
        // A reference is never null (`nonnull`).
        if t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) && (int_bits(b, t.b) == Some(0u64) && nonnull(
            b,
            t.a,
            pk.ptr_bytes,
        ) || int_bits(b, t.a) == Some(0u64) && nonnull(b, t.b, pk.ptr_bytes)) {
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
        let below1 = t.op == O_ICMP && (t.aux == C_ULT || t.aux == C_UGE) && int_bits(b, t.b) == Some(1u64);
        if below1 && (t.a & VFLAG) == 0 && !((t.a & VPARAM) == 0 && (t.a as usize >= self.blk_of.len() || self.blk_of[t.a as usize] == k)) && int_bits(
            b,
            t.a,
        ).is_none() {
            let r = self.entry_fact(pk, b, k, t.a, 0, THREAD_DEPTH);
            if r.is_some() {
                t = iconst(t.ty, (r.unwrap() == (t.aux == C_ULT)) as u64);
            }
        } else if t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) {
            let kb = int_bits(b, t.b);
            let a = ast::pick(kb.is_some(), t.a, t.b);
            let kc = if kb.is_some() {
                kb
            } else {
                int_bits(b, t.a)
            };
            let local = (a & VFLAG) != 0 || (a & VPARAM) == 0 && (a as usize >= self.blk_of.len() || self.blk_of[a as usize] == k);
            if kc.is_some() && int_bits(b, a).is_none() && !local {
                let r = self.entry_fact(pk, b, k, a, kc.unwrap(), THREAD_DEPTH);
                if r.is_some() {
                    t = iconst(t.ty, (r.unwrap() == (t.aux == C_EQ)) as u64);
                }
            } else if kc.is_none() && !local && is_int(b.type_of(t.a)) {
                // Two values from before the block (`a` is the second) that the branches into it settle to
                // constants (`count_fact`): two lengths each tested against 32, then against each other.
                let la = (t.a & VFLAG) != 0 || (t.a & VPARAM) == 0 && (t.a as usize >= self.blk_of.len() || self.blk_of[t.a as usize] == k);
                let x = if la {
                    Option::<u64>::None
                } else {
                    self.count_fact(pk, b, k, t.a)
                };
                if x.is_some() {
                    let y = self.count_fact(pk, b, k, t.b);
                    if y.is_some() {
                        t = iconst(t.ty, (x.unwrap() == y.unwrap() == (t.aux == C_EQ)) as u64);
                    }
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
        // An indexed address from an indexed address with an offset (an element of a row at an offset) the
        // same: the rows' elements at one index are then one address and constant offsets (`lir::slp` packs
        // their loads).
        if (t.op == O_LOAD || t.op == O_STORE || t.op == O_PTRADD && t.b != VNONE) && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_PTRADD && b.insts[t.a as usize].b != VNONE && b.insts[t.a as usize].c != 0 && !self.moved[t.a as usize] && !slot_based(
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
                if t.op == O_PTRADD {
                    // `q` may leave the object: no longer in bounds of its base.
                    t.aux &= ~PTR_INBOUNDS;
                }
            }
        }
        b.insts[i as usize] = t;
        // A copy or a fill of no byte does nothing.
        let size = if t.op == O_MEMCPY || t.op == O_MEMSET {
            int_bits(b, t.c)
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
            let wait = ty != T_NONE && self.wait_copies && (self.slot_copy(b, t.a) || self.slot_copy(b, t.b));
            self.waited = self.waited || wait;
            if ty != T_NONE && !wait {
                let v = self.before(b, k, i, Inst { op: O_LOAD, ty: ty, aux: 0, a: t.b, b: VNONE, c: 0 });
                t = Inst { op: O_STORE, ty: T_NONE, aux: 0, a: t.a, b: v, c: 0 };
                b.insts[i as usize] = t;
            }
        }
        // A fill of 1, 2, 4 or 8 bytes with a constant byte is a store of the integer of those bytes.
        let fill = if t.op == O_MEMSET && (t.aux & MEM_VOLATILE) == 0 {
            int_bits(b, t.b)
        } else {
            Option::<u64>::None
        };
        if size.is_some() && fill.is_some() {
            let n = size.unwrap();
            if n == 1 || n == 2 || n == 4 || n == 8 {
                let ty = int_type(n as u32);
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
                if c.op == O_MEMCPY && c.a == t.b && int_bits(b, c.c) == size && c.b != t.b && apart {
                    t.b = c.b;
                    t.aux |= MEM_OVERLAP;
                    b.insts[i as usize] = t;
                }
            }
            // Keyed by the destination and both states after the copy; not in `recent`, whose places
            // `carry` keeps across writes that do not touch them, as a source's write would.
            self.enter(LOG_MEM, place_hash(t.a, self.pstate, T_NONE, self.tstate[0]), self.places.len() as u32);
            self.places.push(Place { addr: t.a, off: self.pstate, ty: T_NONE, state: self.tstate[0], val: i, mem: 0 });
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
                let kp = int_bits(b, p.b);
                let kt = int_bits(b, t.b);
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
            self.remember(t.a, t.c, b.type_of(t.b), t.b, self.state, self.member(i));
        } else if t.op == O_LOAD && (t.aux & MEM_VOLATILE) == 0 {
            let mut p = self.private_load(pk, b, k, i, t);
            // A load of a copy's bytes whose source no write touches reads the source.
            if p == PRIV_NONE {
                let (a, c) = self.copy_source(pk, b, k, i, t);
                if a != VNONE {
                    t.a = a;
                    t.c = c;
                    b.insts[i as usize] = t;
                    p = self.private_load(pk, b, k, i, t);
                }
            }
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
            // A load of bytes no write touches (a private slot's, a read-only referent's: `frozen`, a view
            // parameter's own words: `view_word`) reads one value in every memory state.
            let word = view_word(b, t);
            let st = ast::pick(
                p == PRIV_KEPT || word || i as usize < self.acls.len() && self.acls[i as usize] == CL_FROZEN,
                KEPT_STATE,
                self.state,
            );
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
            if fold_data(pk, b, i) || fold_ptr(pk, b, i, self.unit) {
                let _ = self.number(pk, b, k, i);
                return true;
            }
            self.remember(t.a, t.c, t.ty, i, st, self.member(i));
            // A load that may fault leaves only the loop whose every entry runs it.
            let safe = self.safe_load(pk, b, t);
            if (safe || self.runs_first(b, k, i)) && self.hoist(pk, b, k, i, true, p == PRIV_KEPT || word, !safe) {
                // Out of a header into its preheader, which always enters it, the load keeps its guard.
                if self.inner[k as usize] != k || self.preh[k as usize] != self.blk_of[i as usize] {
                    b.insts[i as usize] = unguarded(b.insts[i as usize]);
                }
                return true;
            }
            if safe && self.sink_load(pk, b, k, i, t) {
                return true;
            }
        } else if (t.op == O_ADDO || t.op == O_MULO) && self.checked_range(pk, b, k, i) {
            return true;
        } else if (t.op == O_ADDO || t.op == O_SUBO || t.op == O_MULO) && (self.fold_checked(pk, b, i) || self.checked_plain(
            b,
            i,
        )) {
            return true;
        } else if t.op == O_CALL && named_alloc(pk, b, t) == ALLOC_MEMCMP && self.memcmp_eq(pk, b, k, i) {
            return true;
        } else if t.op == O_CALL && self.copysign_bits(pk, b, k, i) {
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
            if t.op == O_TRUNC && is_int(t.ty) && (t.a & (VPARAM | VFLAG)) == 0 && t.a != VNONE {
                let w = b.insts[t.a as usize];
                if w.op >= O_ADD && w.op <= O_XOR && !(w.op >= O_SDIV && w.op <= O_UREM) {
                    let x = ext_from(b, w.a, t.ty);
                    let y = ext_from(b, w.b, t.ty);
                    if x != VNONE && y != VNONE {
                        self.readers(b);
                        if t.a as usize >= self.icount.len() || self.icount[t.a as usize] == 1 {
                            b.insts[i as usize] = Inst { op: w.op, ty: t.ty, aux: 0, a: x, b: y, c: VNONE };
                        }
                    }
                }
            }
            let r = simplify(pk, b, i);
            if r != VNONE {
                self.repl[i as usize] = r;
                return true;
            }
            self.invariant_sum(b, k, i);
            if b.insts[i as usize].op == O_OR && (self.combine_loads(pk, b, k, i) || self.byte_perm(pk, b, i)) {
                return true;
            }
            if b.insts[i as usize].op == O_OR && pk.bitrev && bit_reverse(pk, b, i) {
                let _ = self.number(pk, b, k, i);
                return true;
            }
            if b.insts[i as usize].op == O_SELECT {
                nonzero_arm(b, i);
            }
            if self.wide_trunc(b, k, i) {
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
            // A count whose operand the bounds in scope keep above 0 (`CNT_NONZERO`).
            if (lop == O_CLZ || lop == O_CTZ) && b.insts[i as usize].aux == 0 {
                let lo = self.lbound(pk, b, t.a, UB_DEPTH);
                if lo.is_some() && lo.unwrap() != 0 {
                    b.insts.index_mut(i as usize).aux = CNT_NONZERO;
                }
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
        let k2 = int_bits(b, t.b);
        if x.op != O_ADD && x.op != O_SUB || x.ty != t.ty || k2.is_none() {
            return;
        }
        let k1 = int_bits(b, x.b);
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
        let kv = self.constant(b, t.ty, trunc_bits(s1.wrapping_add(s2), type_bits(t.ty, pk.ptr_bytes)));
        b.insts[i as usize] = Inst { op: O_ADD, ty: t.ty, aux: 0, a: x.a, b: kv, c: VNONE };
    }

    // Address `i` of block `k`, `ptradd p, (x + y) * s + c` (or `x - y`) in a loop that defines `x` but
    // neither `p` nor `y`: in place `ptradd q, x * s + c`, `q = ptradd p, y * s` made in the loop's preheader. The same
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
        if s.op == O_SUB && !self.outside(s.a, h) && self.outside(s.b, h) && int_bits(b, s.b).is_none() {
            // `x - y`: `q = ptradd p, (0 - y) * s`, the same address modulo the pointer's width.
            let p = self.preh[h as usize];
            let at = b.blocks[p as usize].start + b.blocks[p as usize].len - 1;
            let zero = self.constant(b, s.ty, 0);
            let ny = self.placed(b, p, at, Inst { op: O_SUB, ty: s.ty, aux: 0, a: zero, b: s.b, c: VNONE }, false);
            let q = self.placed(
                b,
                p,
                at,
                Inst { op: O_PTRADD, ty: T_PTR, aux: t.aux & PTR_SCALE, a: t.a, b: ny, c: 0 },
                false,
            );
            b.insts[i as usize] = Inst { op: O_PTRADD, ty: T_PTR, aux: t.aux & ~PTR_INBOUNDS, a: q, b: s.a, c: t.c };
            return;
        }
        if s.op != O_ADD {
            return;
        }
        for side in 0..2u32 {
            let (x, y) = if side == 0 {
                (s.a, s.b)
            } else {
                (s.b, s.a)
            };
            if self.outside(x, h) || !self.outside(y, h) || int_bits(b, y).is_some() {
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
        let k = int_bits(b, t.b);
        let bits = type_bits(t.ty, pk.ptr_bytes) as u64;
        let k1 = if x.op == t.op {
            int_bits(b, x.b)
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
        if t.op == O_ASHR || x.op != ast::pick(t.op == O_LSHR, O_SHL, O_LSHR) || k.is_none() || k.unwrap() == 0 || k.unwrap() >= bits || int_bits(
            b,
            x.b,
        ) != k {
            return;
        }
        let ones = trunc_bits(0xFFFFFFFFFFFFFFFF, bits as u32);
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
        let c = int_bits(b, t.b);
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
        let op = ast::pick(t.op == O_MUL, O_SHL, O_LSHR);
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
                let c = int_bits(b, x.b);
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
        let off = ast::pick(fwd, boff, roff);
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
        if is_vec(t.ty) {
            return false;
        }
        let mut x = VNONE;
        let mut vals = StaticVector::<u64, SET_MAX>::new();
        let mut stack = StaticVector::<Value, SET_MAX>::new();
        // The tree's values, one per step, whose readers (`readers`) are checked once its shape is one.
        let mut nodes = StaticVector::<Value, 32>::new();
        stack.push(t.a);
        stack.push(t.b);
        // Each step takes a value off the stack; an `or` puts back two: at most 2 * SET_MAX steps.
        for _ in 0..2 * SET_MAX {
            if stack.len() == 0 {
                break;
            }
            let v = stack.pop().unwrap();
            if (v & (VPARAM | VFLAG)) != 0 {
                return false;
            }
            nodes.push(v);
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
            let c = int_bits(b, u.b);
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
        self.readers(b);
        if i as usize < self.in_or.len() && self.in_or[i as usize] {
            return false;
        }
        for q in 0..nodes.len() {
            let v = nodes[q];
            if v as usize < self.icount.len() && self.icount[v as usize] != 1 {
                return false;
            }
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
        b.insts[i as usize] = Inst { op: O_ICMP, ty: t.ty, aux: ast::pick(neg, C_UGT, C_ULE), a: d, b: span, c: VNONE };
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
        let c = Inst { op: O_ICMP, ty: T_I8, aux: ast::pick(signed, C_SLT, C_ULT), a: pa, b: qa, c: VNONE };
        let h = self.inner[k as usize];
        // Of two bounds from before the loop: in its preheader, where versioning reads a bound from before
        // the loop (`lir::loops`' `checks`).
        let m = if h != NONE && self.preh[h as usize] != NONE && self.outside(pa, h) && self.outside(qa, h) {
            let pb = self.preh[h as usize];
            let at = b.blocks[pb as usize].start + b.blocks[pb as usize].len - 1;
            let lt = self.placed(b, pb, at, c, false);
            self.placed(
                b,
                pb,
                at,
                Inst { op: O_SELECT, ty: ty, aux: 0, a: lt, b: ast::pick(min, pa, qa), c: ast::pick(min, qa, pa) },
                false,
            )
        } else {
            let lt = self.before(b, k, i, c);
            let m = self.before(
                b,
                k,
                i,
                Inst { op: O_SELECT, ty: ty, aux: 0, a: lt, b: ast::pick(min, pa, qa), c: ast::pick(min, qa, pa) },
            );
            // The minimum or maximum, made before `i`, leaves its loop in one more walk.
            self.refold = true;
            m
        };
        b.insts[i as usize] = Inst { op: O_ICMP, ty: t.ty, aux: pc, a: x, b: m, c: VNONE };
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
            // Where `k` leaves: on `c1` true (side 0) or false; `s` alike. The second condition in `k`'s sense,
            // of the values the walk gave its operands: `s` comes after `k`, and the copy, made at the end of
            // `k`, no visit reads (`placed`).
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
                    a: self.val(c2.a),
                    b: self.val(c2.b),
                    c: VNONE,
                },
                false,
            );
            let both = self.placed(
                b,
                k,
                i,
                Inst { op: ast::pick(k_true, O_OR, O_AND), ty: T_I8, aux: 0, a: t.a, b: c2k, c: VNONE },
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
    // is a power of two, in place `popcnt(x) == 1` where the target counts bits in one instruction
    // (`Package.popcnt`), else `(x ^ (x - 1)) >u x - 1`; the `or` of their opposites `!=`, `<=u` (LLVM's
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
            if x != VNONE && d != VNONE && pk.popcnt && b.type_of(x) != T_I128 {
                let ty = b.type_of(x);
                let c = self.before(b, k, i, Inst { op: O_POPCNT, ty: ty, aux: 0, a: x, b: VNONE, c: VNONE });
                let one = self.constant(b, ty, 1);
                b.insts[i as usize] = Inst {
                    op: O_ICMP,
                    ty: t.ty,
                    aux: ast::pick(neg, C_NE, C_EQ),
                    a: c,
                    b: one,
                    c: VNONE,
                };
                return true;
            }
            if x != VNONE && d != VNONE {
                let ty = b.type_of(x);
                let xd = self.before(b, k, i, Inst { op: O_XOR, ty: ty, aux: 0, a: x, b: d, c: VNONE });
                b.insts[i as usize] = Inst {
                    op: O_ICMP,
                    ty: t.ty,
                    aux: ast::pick(neg, C_ULE, C_UGT),
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
        let e = ast::pick(ea.op != O_ICONST, ea, eb);
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
        let kv = int_bits(b, ast::pick(ea.op != O_ICONST, t.b, t.a));
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
        let shl = w.op == O_SHL && int_bits(b, w.b).is_some() && int_bits(b, w.b).unwrap() < type_bits(
            t.ty,
            pk.ptr_bytes,
        ) as u64;
        if (w.op < O_ADD || w.op > O_XOR || w.op >= O_SDIV && w.op <= O_UREM) && !shl || !is_int(w.ty) || w.ty == T_I128 {
            return false;
        }
        let (e, c) = if int_bits(b, w.b).is_some() {
            (w.a, int_bits(b, w.b))
        } else {
            (w.b, int_bits(b, w.a))
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
        let sub_first = w.op == O_SUB && int_bits(b, w.b).is_none();
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
        // The narrow count keeps `CNT_NONZERO` but of the bit above (its narrow operand may be 0).
        let mut aux = t.aux;
        if t.op == O_CTZ && x.op == O_OR {
            aux = 0;
            // The bit right above the narrow value, the other operand a zero extension.
            let (e, c) = if int_bits(b, x.b).is_some() {
                (x.a, int_bits(b, x.b))
            } else {
                (x.b, int_bits(b, x.a))
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
        let n = self.before(b, k, i, Inst { op: t.op, ty: nt, aux: aux, a: x.a, b: VNONE, c: VNONE });
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
        let c = int_bits(b, t.b);
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
        let m = int_bits(b, low.b);
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
            (bias.a & (VPARAM | VFLAG)) == 0 && bias.a != VNONE && b.insts[bias.a as usize].op == O_ASHR && b.insts[bias.a as usize].a == n && int_bits(
                b,
                b.insts[bias.a as usize].b,
            ) == Some(s - 1)
        };
        if int_bits(b, bias.b) != Some(w - s) || !sgn_ok {
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
        if let Some(c) = int_bits(b, v) {
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
                int_bits(b, x.b)
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
                    (int_bits(b, x.a), x.b)
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

    // The return slot (C++'s named return value, LLVM's sret promotion): the body's result pointer (the
    // parameter after the signature's) is read only by one whole copy into it from a slot, right before a
    // return, and that slot's address only addresses loads, stores, copies and fills of a slot no more
    // aligned than the result: the slot is the result's memory, and the copy goes. The caller passes memory
    // no other pointer of the call reaches. Not in a body that may unwind (a `panic`, a call of a body that
    // may not come back, an indirect call), which would leave that memory half written for the code a panic
    // unwinds to (`result_into` passes real objects as results). Whether it did.
    pub(package) fn return_slot(self: &mut Self, pk: &Package, b: &mut Body) bool {
        if b.sig == NONE || (b.pool[b.sig as usize + 2] & AGG) == 0 {
            return false;
        }
        let np = b.pool[b.sig as usize];
        let e = b.blocks[0];
        if e.param_len as u32 <= np {
            return false;
        }
        let rp = VPARAM | e.param_start + np;
        let l = (b.pool[b.sig as usize + 2] & ~AGG) as usize;
        let size = b.pool[l];
        let mut cp = NONE;
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                if t.op == O_PANIC || t.op == O_CALLIND || t.op == O_CALL && (pk.syms[b.syms[t.a as usize] as usize].fx & FX_STALL) != 0 {
                    return false;
                }
                self.fuses.truncate(0);
                lv::uses_into(b, t, &mut self.fuses);
                if is_terminator(t.op) {
                    b.succ_edges(t, &mut self.edges);
                    for g in 0..self.edges.len() {
                        for q in 0..b.edge_nargs(self.edges[g]) {
                            self.fuses.push(b.edge_arg(self.edges[g], q));
                        }
                    }
                }
                for u in 0..self.fuses.len() {
                    if self.fuses[u] != rp {
                        continue;
                    }
                    let last = i + 2 == bk.start + bk.len && b.insts[i as usize + 1].op == O_RET;
                    if cp != NONE || t.op != O_MEMCPY || t.a != rp || t.b == rp || (t.aux & MEM_VOLATILE) != 0 || int_bits(
                        b,
                        t.c,
                    ) != Option::<u64>::Some(size) || !last || !is_op(b, t.b, O_SLOTADDR) {
                        return false;
                    }
                    cp = i;
                }
            }
        }
        if cp == NONE {
            return false;
        }
        let s = b.insts[b.insts[cp as usize].b as usize].a;
        if b.slots[s as usize].size != size || b.slots[s as usize].align_log2 as u32 > b.pool[l + 1] {
            return false;
        }
        // Each use of the slot's address: an access's address, a copy's or fill's memory.
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                self.fuses.truncate(0);
                lv::uses_into(b, t, &mut self.fuses);
                if is_terminator(t.op) {
                    b.succ_edges(t, &mut self.edges);
                    for g in 0..self.edges.len() {
                        for q in 0..b.edge_nargs(self.edges[g]) {
                            self.fuses.push(b.edge_arg(self.edges[g], q));
                        }
                    }
                }
                for u in 0..self.fuses.len() {
                    let v = self.fuses[u];
                    if slot_of(b, v) != s {
                        continue;
                    }
                    let addr = (t.op == O_LOAD || t.op == O_STORE || t.op == O_PTRADD || t.op == O_MEMSET) && v == t.a && t.b != v && (t.op != O_STORE || t.b != v) || t.op == O_MEMCPY && v == t.a != (v == t.b);
                    if !addr || is_terminator(t.op) {
                        return false;
                    }
                }
            }
        }
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            if (t.op == O_LOAD || t.op == O_STORE || t.op == O_PTRADD || t.op == O_MEMSET || t.op == O_MEMCPY) && is_op(
                b,
                t.a,
                O_SLOTADDR,
            ) && b.insts[t.a as usize].a == s {
                b.insts.index_mut(i).a = rp;
            }
            if t.op == O_MEMCPY && is_op(b, t.b, O_SLOTADDR) && b.insts[t.b as usize].a == s {
                b.insts.index_mut(i).b = rp;
            }
        }
        b.insts[cp as usize] = iconst(T_I8, 0);
        self.kept = K_NONE;
        return true;
    }

    // The allocations (`ALLOC_FRESH` by the name, a `realloc` of null alone, at most FRESH_MAX) whose pointer
    // only stores write through, equalities with null test and one free (`ALLOC_FREE`) takes, which every
    // path from the allocation to a return or back to it passes once: they go with their stores and free, and
    // the tests fold as for a block that exists (LLVM InstCombine's removal of unused allocations). The
    // runtime's leak tracker counts such a pair as nothing either. Whether any went.
    pub(package) fn dead_allocs(self: &mut Self, pk: &Package, b: &mut Body) bool {
        self.fresh.truncate(0);
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            if t.op == O_CALL && t.ty == T_PTR && self.fresh.len() < FRESH_MAX && named_alloc(pk, b, t) == ALLOC_FRESH && !grows_block(
                pk,
                b,
                t,
            ) {
                self.fresh.push(i as u32);
            }
        }
        if self.fresh.len() == 0 {
            return false;
        }
        // Each instruction's uses (`ops`), each allocation's block (`blk_of`).
        self.tables(pk, b, K_GRAPH);
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
                for u in self.ops_at[i as usize]..self.ops_at[i as usize + 1] {
                    let v = self.ops[u as usize];
                    if v < lo || v > hi {
                        continue;
                    }
                    for f in 0..self.fresh.len() {
                        if v != self.fresh[f] || !self.fresh_ok[f] {
                            continue;
                        }
                        let ok = t.op == O_STORE && t.a == v && t.b != v && (t.aux & MEM_VOLATILE) == 0 || t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) && (int_bits(
                            b,
                            t.a,
                        ) == Some(0u64) || int_bits(b, t.b) == Some(0u64));
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
        let home = self.blk_of[v as usize];
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
        let op = ast::pick(a.op == O_ADD, O_ADDO, O_SUBO);
        b.insts[s as usize] = Inst { op: op, ty: a.ty, aux: ast::pick(signed, OV_SIGNED, 0), a: a.a, b: a.b, c: VNONE };
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
        let se = ast::pick(stay_t, th.b, th.c);
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
        let bound = ast::pick(c.a == qv, c.b, c.a);
        let down = step == 2 && int_bits(b, bound) == Some(0u64) && (stay_t && c.aux == C_NE || !stay_t && c.aux == C_EQ);
        let up = step == 1 && int_bits(b, q0) == Some(0u64);
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
    // Definition `s` of block `k` moved right before instruction `to`, when an instruction lies between and
    // none of those reads it: else the definition is in place already.
    fn move_before(self: &mut Self, b: &Body, k: u32, s: u32, to: u32) {
        let mut between = false;
        for j in s + 1..to {
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
            if at <= s || at > to || self.blk_of[at as usize] != k {
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
        self.pre.push(to as u64 << 32 | s as u64);
    }
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
        self.move_before(b, k, s, i);
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
        let s = if eq && int_bits(b, ct.b) == Some(0u64) {
            ct.a
        } else if eq && int_bits(b, ct.a) == Some(0u64) {
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
        self.move_before(b, k, s, c);
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
        let on_true = int_bits(b, tc) == Some(0u64);
        let s = if on_true {
            tb
        } else if int_bits(b, tb) == Some(0u64) {
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
        return ast::pick(!ok || !self.at_most(b, a, n, UB_DEPTH), VNONE, s);
    }

    // Whether `a <=u n` always holds: `a` is `n`, 0, an `and` with an operand that is at most `n`, a select
    // of two, or a parameter every edge into its block passes such a value for (up to `depth` deep).
    fn at_most(self: &Self, b: &Body, a: Value, n: Value, depth: u32) bool {
        if a == n || int_bits(b, a) == Some(0u64) {
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
                let ed = edge_of(b, st, e);
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
        return (x.op == O_ADD || x.op == O_SUB) && (int_bits(b, x.b).is_some() || x.op == O_ADD && int_bits(b, x.a).is_some());
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
        if c.op != O_ICMP || int_bits(b, c.b) != Some(0u64) || c.aux != C_SLT && c.aux != C_SGE || b.type_of(c.a) != t.ty {
            return false;
        }
        let x = int_bits(b, t.b);
        let y = int_bits(b, t.c);
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
        let left = int_bits(b, t.b).is_some();
        let s = ast::pick(left, t.a, t.b);
        if !left && int_bits(b, t.a).is_none() || (s & (VPARAM | VFLAG)) != 0 || s == VNONE || b.insts[s as usize].op != O_SELECT || !cmp_arm(
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
        let x = int_bits(b, u.a);
        let y = int_bits(b, u.b);
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

    // Call `i` of block `k` of C's `copysign` or `copysignf`: the magnitude's bits and the sign's bit, in
    // integer operations every target computes in registers and the vectorizer widens.
    fn copysign_bits(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        if t.aux != 2 || t.ty != T_F64 && t.ty != T_F32 {
            return false;
        }
        let s = pk.syms[b.syms[t.a as usize] as usize];
        let n = pk.spell(s.name);
        let want = if t.ty == T_F64 {
            "copysign"
        } else {
            "copysignf"
        };
        if s.kind != SK_FUNC || s.def != NONE || n != want {
            return false;
        }
        let (it, sign) = if t.ty == T_F64 {
            (T_I64, 1u64 << 63)
        } else {
            (T_I32, 1u64 << 31)
        };
        let x = self.val(b.pool[t.c as usize]);
        let y = self.val(b.pool[t.c as usize + 1]);
        let xb = self.made(pk, b, k, i, Inst { op: O_BITCAST, ty: it, aux: 0, a: x, b: VNONE, c: VNONE });
        let yb = self.made(pk, b, k, i, Inst { op: O_BITCAST, ty: it, aux: 0, a: y, b: VNONE, c: VNONE });
        let mag = self.constant(b, it, sign - 1);
        let sgn = self.constant(b, it, sign);
        let xa = self.made(pk, b, k, i, Inst { op: O_AND, ty: it, aux: 0, a: xb, b: mag, c: VNONE });
        let ya = self.made(pk, b, k, i, Inst { op: O_AND, ty: it, aux: 0, a: yb, b: sgn, c: VNONE });
        let o = self.made(pk, b, k, i, Inst { op: O_OR, ty: it, aux: 0, a: xa, b: ya, c: VNONE });
        b.insts[i as usize] = Inst { op: O_BITCAST, ty: t.ty, aux: 0, a: o, b: VNONE, c: VNONE };
        // The next walk hoists what the loop does not change, before the loop transforms read it.
        self.refold = true;
        return true;
    }

    // Call `i` of block `k` of the C library's `memcmp` (by its name: wasm32's C library is the package's own)
    // of a count up to MEMCMP_MAX bytes that is a constant or that a branch into the block settles: loads of
    // both sides, the widest power of two of at most 8 bytes, up to MEMCMP_LOADS each, the last overlapping
    // the one before for a count it does not divide (LLVM ExpandMemCmp). A result whose one reader is an
    // equality with 0 right after is whether a pair differs: then the widest power of two that fits each
    // remaining count, unless that takes more loads than the overlapping ones (5 bytes as 4 and 1, 7 as two
    // overlapping 4), a narrower pair extended to the widest; past 16 bytes, where the target computes
    // 16-byte vectors (`Package.vector`) and chains no conditional comparisons (`Package.ccmp`), the `or` of
    // 16-byte pairs' differences (the last overlapping), its lanes' `or` tested. Another is the order of the
    // first pair that differs, compared as big-endian numbers (`Package.bswap`). A load of read-only data
    // folds to its constant. Whether it did.
    fn memcmp_eq(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        let bk = b.blocks[k as usize];
        if t.aux != 3 || t.ty != T_I32 {
            return false;
        }
        let mut eq = false;
        self.readers(b);
        if i as usize < self.icount.len() && self.icount[i as usize] == 1 && i + 1 < bk.start + bk.len {
            let u = b.insts[i as usize + 1];
            eq = u.op == O_ICMP && (u.aux == C_EQ || u.aux == C_NE) && (u.a == i && int_bits(b, u.b) == Some(0u64) || u.b == i && int_bits(
                b,
                u.a,
            ) == Some(0u64));
        }
        let pa = self.val(b.pool[t.c as usize]);
        let pb = self.val(b.pool[t.c as usize + 1]);
        let nv = self.val(b.pool[t.c as usize + 2]);
        let mut n = int_bits(b, nv);
        if n.is_none() {
            n = self.count_fact(pk, b, k, nv);
        }
        if n.is_none() || n.unwrap() > if eq {
            MEMCMP_EQ_MAX
        } else {
            MEMCMP_MAX
        } {
            return false;
        }
        let c = n.unwrap() as u32;
        if c == 0 {
            b.insts[i as usize] = iconst(T_I32, 0);
            return true;
        }
        if eq && c > 16 && pk.vector >= 16 && !pk.ccmp {
            // The `or` of the 16-byte pairs' differences, the last pair overlapping the one before; whether
            // a lane of it is not 0.
            let vt = vec_type(T_I8, 16);
            let mut d = VNONE;
            for q in 0..(c + 15) / 16 {
                let off = (16 * q).min(c - 16);
                let x = self.made(pk, b, k, i, Inst { op: O_LOAD, ty: vt, aux: 0, a: pa, b: VNONE, c: off });
                let _ = fold_data(pk, b, x);
                let y = self.made(pk, b, k, i, Inst { op: O_LOAD, ty: vt, aux: 0, a: pb, b: VNONE, c: off });
                let _ = fold_data(pk, b, y);
                let z = self.made(pk, b, k, i, Inst { op: O_XOR, ty: vt, aux: 0, a: x, b: y, c: VNONE });
                d = if d == VNONE {
                    z
                } else {
                    self.made(pk, b, k, i, Inst { op: O_OR, ty: vt, aux: 0, a: d, b: z, c: VNONE })
                };
            }
            let one = [d];
            let at = b.pool_list(one[0..1]);
            let rc = (core::OP_SIMD + core::SIMD_REDUCE_OR as u32) as u16;
            let r = self.made(pk, b, k, i, Inst { op: O_VOP, ty: T_I8, aux: rc, a: at, b: 1, c: VNONE });
            let zero = self.constant(b, T_I8, 0);
            let ne = self.made(pk, b, k, i, Inst { op: O_ICMP, ty: T_I8, aux: C_NE, a: r, b: zero, c: VNONE });
            b.insts[i as usize] = Inst { op: O_ZEXT, ty: T_I32, aux: 0, a: ne, b: VNONE, c: VNONE };
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
        if parts > if eq {
            MEMCMP_EQ_LOADS
        } else {
            MEMCMP_LOADS
        } || !eq && w > 1 && !pk.bswap {
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
        let mut la = StaticVector::<Value, 8>::new();
        let mut lb = StaticVector::<Value, 8>::new();
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
                let st = int_type(s);
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
                    let o = Inst { op: ast::pick(rel == C_EQ, O_AND, O_OR), ty: T_I8, aux: 0, a: d, b: z, c: VNONE };
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

    // The constant that value `n` (no instruction of block `k`) equals where `k` starts, by the first
    // equality of `n` with a constant that a branch's condition holds up the chain of one-predecessor
    // blocks into `k` (THREAD_DEPTH of them; `eq_const`, `entry_fact` settles it); None when none does.
    fn count_fact(self: &Self, pk: &Package, b: &Body, k: u32, n: Value) Option<u64> {
        let mut q = k;
        for _ in 0..THREAD_DEPTH {
            if self.pred_at[q as usize + 1] - self.pred_at[q as usize] != 1 {
                return None;
            }
            let src = self.preds[self.pred_at[q as usize] as usize];
            let st = term(b, src);
            if st.op == O_BR && !same_edge(b, st.b, st.c) {
                let c = eq_const(b, st.a, b.edge_target(st.b) == q, n, CCMP_DEPTH);
                if c.is_some() {
                    return if self.entry_fact(pk, b, k, n, c.unwrap(), THREAD_DEPTH) == Some(true) {
                        c
                    } else {
                        None
                    };
                }
            }
            q = src;
        }
        return None;
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
        let v = b.push_at(t, at);
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
        let v = b.push_at(t, at);
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
    // a size stays while the loop vectorizer may take it (`defer_div`); a scalar one stays without
    // `Package.mul_high`. Whether it did.
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
        // A scalar one stays where the backend has no one-instruction high product (wasm32, whose engines
        // divide by a constant themselves).
        if !is_int(lt) || vec && (pk.vec_mulh & type_bytes(lt, pk.ptr_bytes) as u8) == 0 || !vec && !pk.mul_high {
            return false;
        }
        let c = if vec {
            splat_of(b, t.b)
        } else {
            int_bits(b, t.b)
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
            return self.divide_signed(pk, b, k, i, sign_extend(d, bits));
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
            if sign_extend(m, bits) < 0 {
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
        let d = Inst { op: ast::pick(t.op == O_UREM, O_UDIV, O_SDIV), ty: t.ty, aux: t.aux, a: t.a, b: t.b, c: t.c };
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
                // A private copy no write touched since, of a source no write touches, passes its source.
                let size = b.pool[(pt & ~AGG) as usize] as i64;
                let (src, rel, cp) = self.copy_of(b, self.blk_of[i as usize], i, v, 0, size);
                let n = if cp == NONE {
                    Option::<u64>::None
                } else {
                    int_bits(b, b.insts[cp as usize].c)
                };
                if !big && src != VNONE && rel == 0 && b.insts[cp as usize].a == v && n.is_some() && n.unwrap() == size as u64 {
                    b.pool[(t.c + k) as usize] = src;
                    self.rewrote = true;
                }
                continue;
            }
            let c = b.insts[m as usize];
            let n = int_bits(b, c.c);
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
            self.rewrote = true;
        }
        return t;
    }

    // Copy `t`, instruction `i` of block `k`, of a call's whole aggregate result from the slot that call
    // writes it to, right after the call (pure instructions and whole copies between slots that pass the
    // result on between), into an exclusive parameter's referent whose address exists before the call (not
    // one of those pure instructions): the call writes its result there in place of those slots, which
    // nothing else uses, and the copies go. The callee keeps no copy of its result's address (`Sym.esc`) and
    // no other argument reaches that referent, so it neither reads those bytes nor sees them change but
    // through its result; it comes back (no `FX_STALL`), so no panic unwinds to code that reads the bytes it
    // left half written. Whether it did.
    fn result_into(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32, t: Inst) bool {
        let n = int_bits(b, t.c);
        let c = self.acc(b, i, t.a);
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
            if w.op != O_MEMCPY || w.a != src || w.b == src || (w.aux & MEM_VOLATILE) != 0 || int_bits(b, w.c) != n || hops.len() as u32 == RESULT_HOPS {
                break;
            }
            hops.push(j);
            src = w.b;
        }
        let u = b.insts[j as usize];
        let late = (t.a & (VPARAM | VFLAG)) == 0 && self.blk_of[t.a as usize] == k && t.a > j;
        if j == i || u.op != O_CALL || self.repl[j as usize] != VNONE || late {
            return false;
        }
        let np = b.pool[u.b as usize];
        let rt = b.pool[u.b as usize + 2];
        if (rt & AGG) == 0 || u.aux != np + 1 || b.pool[(u.c + np) as usize] != src || np >= 64 || n != Option::<u64>::Some(
            b.pool[(rt & ~AGG) as usize],
        ) || (pk.syms[b.syms[u.a as usize] as usize].esc >> np as u64 & 1) != 0 || (pk.syms[b.syms[u.a as usize] as usize].fx & FX_STALL) != 0 {
            return false;
        }
        for q in 0..np {
            let v = b.pool[(u.c + q) as usize];
            let d = self.acc(b, j, v);
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
            lv::uses_edges(b, w, &mut self.uses);
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
            let d = self.acc(b, i, b.pool[(t.c + q) as usize]);
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
        let frac = ast::pick(t.ty == T_F64, 0xFFFFFFFFFFFFFu64, 0x7FFFFFu64);
        if c.is_none() || (c.unwrap() & frac) != 0 || !regular(t.ty, c.unwrap()) {
            return;
        }
        let one = ast::pick(t.ty == T_F64, 0x3FF0000000000000u64, 0x3F800000u64);
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
        let one = ast::pick(t.ty == T_F64, 0x3FF0000000000000u64, 0x3F800000u64);
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
        return self.add_const(b, t, h);
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
        // Without a slot or an aggregate parameter no value has private memory (`base`).
        let mut mem = b.slots.len() != 0;
        if !mem && b.sig != NONE {
            for p in 0..b.pool[b.sig as usize] {
                mem = mem || (b.pool[(b.sig + 3 + p) as usize] & AGG) != 0;
            }
        }
        let nq = if mem {
            self.order.len()
        } else {
            0
        };
        for q in 0..nq {
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
                        int_bits(b, t.c)
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
                                copy: NONE,
                            },
                        );
                    } else if t.op == O_MEMCPY && t.a == v && t.b != v || t.op == O_MEMSET && t.a == v {
                        let copy = ast::pick(t.op == O_MEMCPY, i, NONE);
                        self.wr.push(SlotWrite { slot: s, off: o, end: end, inst: NONE, blk: k, copy: copy });
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

    // Whether address value `v` points into a slot whose address does not escape (`slot_writes`), which the
    // promotion may take.
    const fn slot_copy(self: &Self, b: &Body, v: Value) bool {
        let s = self.base(b, v);
        return s != NONE && s as usize < b.slots.len() && !self.sesc[s as usize];
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
    // it reads the same value wherever it runs; else the value the stores that write exactly its bytes all
    // store when one of them dominates it (as LLVM's mem2reg promotes an alloca of one store: on any path
    // to the load the last write of those bytes is one of those stores').
    fn private_load(self: &Self, pk: &Package, b: &Body, k: u32, i: u32, t: Inst) Value {
        let s = self.base(b, t.a) as usize;
        if s == NONE as usize || self.sesc[s] || self.wat[s + 1] - self.wat[s] > SLOT_WRITES_MAX {
            return PRIV_NONE;
        }
        let off = self.base_off(t.a) + (t.c as i32) as i64;
        let end = off + type_bytes(t.ty, pk.ptr_bytes) as i64;
        let mut v = VNONE;
        let mut first = false;
        for q in self.wat[s]..self.wat[s + 1] {
            let w = self.wl[q as usize];
            if w.off < end && off < w.end {
                if w.inst == NONE || w.off != off || w.end != end {
                    return PRIV_NONE;
                }
                let st = b.insts[w.inst as usize];
                let x = self.val(st.b);
                if b.type_of(st.b) != t.ty || v != VNONE && x != v {
                    return PRIV_NONE;
                }
                v = x;
                first = first || w.blk == k && w.inst < i || w.blk != k && self.dominates(w.blk, k);
            }
        }
        if v == VNONE {
            return PRIV_KEPT;
        }
        return ast::pick(first, v, PRIV_NONE);
    }

    // The address and offset load `t` (instruction `i` of block `k`) of private memory may read instead
    // (`copy_of`); VNONE for none.
    fn copy_source(self: &Self, pk: &Package, b: &Body, k: u32, i: u32, t: Inst) (Value, u32) {
        let (src, rel, _) = self.copy_of(b, k, i, t.a, t.c as i32, type_bytes(t.ty, pk.ptr_bytes));
        return (src, rel);
    }

    // The bytes `n` at offset `at` past address `a` of private memory hold at instruction `i` of block `k`:
    // when the one write of them is a copy that runs before `i` from private memory no write touches, that
    // copy's source, their offset into it and the copy; VNONE otherwise.
    fn copy_of(self: &Self, b: &Body, k: u32, i: u32, a: Value, at: i64, n: i64) (Value, u32, u32) {
        let s = self.base(b, a) as usize;
        if s == NONE as usize || self.sesc[s] || self.wat[s + 1] - self.wat[s] > SLOT_WRITES_MAX {
            return (VNONE, 0u32, NONE);
        }
        let off = self.base_off(a) + at;
        let end = off + n;
        let mut one = NONE;
        for q in self.wat[s]..self.wat[s + 1] {
            let w = self.wl[q as usize];
            if w.off < end && off < w.end {
                if one != NONE || w.copy == NONE || off < w.off || w.end < end {
                    return (VNONE, 0u32, NONE);
                }
                one = q;
            }
        }
        if one == NONE {
            return (VNONE, 0u32, NONE);
        }
        let w = self.wl[one as usize];
        if w.blk == k && w.copy >= i || w.blk != k && !self.dominates(w.blk, k) {
            return (VNONE, 0u32, NONE);
        }
        let c = b.insts[w.copy as usize];
        let s2 = self.base(b, c.b) as usize;
        if s2 == NONE as usize || self.sesc[s2] || (c.aux & MEM_VOLATILE) != 0 {
            return (VNONE, 0u32, NONE);
        }
        let rel = off - w.off;
        let so = self.base_off(c.b) + rel;
        let se = so + (end - off);
        for q in self.wat[s2]..self.wat[s2 + 1] {
            let x = self.wl[q as usize];
            if x.off < se && so < x.end {
                return (VNONE, 0u32, NONE);
            }
        }
        if rel > 0x7FFFFFFF {
            return (VNONE, 0u32, NONE);
        }
        return (c.b, rel as u32, w.copy);
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
        return ast::pick(seen.count_ones() as u32 == lanes(t.ty), v, VNONE);
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
        if b.slots.len() == 0 {
            return;
        }
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
            return s | ast::pick(self.pesc[s as usize], lu::OBJ_SLOT, lu::OBJ_PRIVATE);
        }
        let mut v = a;
        for _ in 0..FRAME_DEPTH {
            let t = b.insts[v as usize];
            if t.op == O_SYMADDR {
                let s = b.syms[t.a as usize];
                let y = pk.syms[s as usize];
                return ast::pick(y.kind != SK_FUNC && !y.ext, s, NONE);
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

    // The slot address value `v` of `b` derives through pointer sums (`pder`; a value the walk made, through
    // at most 8 sums it made first), NONE for none: a block parameter, or a value of an unreached block.
    const fn der_slot(self: &Self, b: &Body, v: Value) u32 {
        let mut x = v;
        // Each step leaves one pointer sum the walk made.
        for _ in 0..8 {
            if x == VNONE || (x & (VPARAM | VFLAG)) != 0 {
                return NONE;
            }
            if x as usize < self.pder.len() {
                return self.pder[x as usize];
            }
            let t = b.insts[x as usize];
            if t.op == O_SLOTADDR {
                return t.a;
            }
            if t.op != O_PTRADD {
                return NONE;
            }
            x = t.a;
        }
        return NONE;
    }

    // Whether instruction `t` accesses only a private slot's memory (`privates`): a load from one, or a
    // store, copy or fill into one. Inline: the walk and the block summaries call it per instruction.
    @always_inline
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
        return ast::pick(p.addr == addr && p.off == off && p.ty == ty && p.state == state, p.val, VNONE);
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

    fn remember(self: &mut Self, addr: u32, off: u32, ty: u8, v: Value, state: u32, mem: u64) {
        if self.recent.len() == RECENT_MAX {
            let _ = self.recent.remove(0);
        }
        self.recent.push(self.places.len() as u32);
        self.enter(LOG_MEM, place_hash(addr, off, ty, state), self.places.len() as u32);
        self.places.push(Place { addr: addr, off: off, ty: ty, state: state, val: v, mem: mem });
    }

    // Write `i`, which started memory state `states` for the type tags whose state `before` held
    // otherwise: each place of `recent` known in such a state that the write cannot touch holds its value
    // in the new state too. A write cannot touch a place of an alias class it writes none of (`write_bits`,
    // a scope's class aside; a write of a scope's class within its copy, only a place an access of that
    // copy made: outside the copy the root may reach any byte), nor a store bytes of its own address apart
    // from its own, nor a call bytes its arguments reach none of (`call_apart`). A place moves only along
    // the states a load of it reads: the untagged accesses' and its type's tag's; another tag's state may be
    // its number by chance and then miss the writes of the place's own tag. A store of part of an integer
    // constant's place that no write followed keeps the rest (`constant_rest`).
    fn carry(self: &mut Self, pk: &Package, b: &mut Body, i: u32) {
        let t = b.insts[i as usize];
        // A place may be read after the scopes the write is in: their roots' bases' bytes too (`read_bits`).
        let wb = self.read_bits(pk, b, i, t);
        let inside = wb & self.sbits & self.member(i);
        let n = self.recent.len();
        // Each entry is checked once; the carried ones join `recent` after the old ones.
        for r in 0..n {
            let p = self.places[self.recent[r] as usize];
            let mut to = NONE;
            let tags: [usize; 2] = [0, tbaa_of(p.ty) as usize];
            for g in tags {
                if unsafe self.tbefore[g] == p.state && unsafe self.tstate[g] != p.state {
                    to = unsafe self.tstate[g];
                }
            }
            if to == NONE {
                continue;
            }
            let c = self.class(p.addr);
            let other_class = c < CL_MANY && (class_bit(c) & self.sbits) == 0 && (wb & class_bit(c)) == 0 && (inside & ~p.mem) == 0;
            let lo = (p.off as i32) as i64;
            let tlo = (t.c as i32) as i64;
            let other_bytes = t.op == O_STORE && t.a == p.addr && (tlo >= lo + type_bytes(p.ty, pk.ptr_bytes) as i64 || lo >= tlo + type_bytes(
                b.type_of(t.b),
                pk.ptr_bytes,
            ) as i64);
            let hi = lo + type_bytes(p.ty, pk.ptr_bytes) as i64;
            let apart = !other_class && !other_bytes && (t.op == O_CALL && self.call_apart(pk, b, i, t, p.addr, lo, hi) || self.slot_apart(
                pk,
                b,
                i,
                t,
                p.addr,
                lo,
                hi,
            ));
            if (other_class || other_bytes || apart) && self.recall(p.addr, p.off, p.ty, to) == VNONE {
                self.remember(p.addr, p.off, p.ty, p.val, to, p.mem);
            } else if t.op == O_STORE && t.a == p.addr && !other_bytes && self.tbefore[0] == p.state {
                let tn = type_bytes(b.type_of(t.b), pk.ptr_bytes) as i64;
                self.constant_rest(b, p, lo, tlo.max(lo).min(hi));
                self.constant_rest(b, p, (tlo + tn).max(lo).min(hi), hi);
            }
        }
    }

    // Bytes `lo..hi` of place `p` that holds an integer constant, which a store of the bytes next to them
    // just wrote over and no write came between: a place of their own, of the constant's bytes there
    // (little-endian), in the states a load of them reads (a vector's length and capacity, which one store
    // of both set, keep the length when a store sets the capacity). None when they are not 1, 2, 4 or 8.
    fn constant_rest(self: &mut Self, b: &mut Body, p: Place, lo: i64, hi: i64) {
        let n = hi - lo;
        let kv = int_bits(b, p.val);
        if n != 1 && n != 2 && n != 4 && n != 8 || kv.is_none() || !is_int(p.ty) || p.ty == T_PTR || p.ty == T_I128 {
            return;
        }
        let ty = int_type(n as u32);
        let sh = 8 * (lo - (p.off as i32) as i64) as u64;
        let v = self.constant(b, ty, kv.unwrap() >> sh & ~0u64 >> 64 - 8 * n as u64);
        let off = (lo as i32) as u32;
        let tags: [usize; 2] = [0, tbaa_of(ty) as usize];
        for g in tags {
            let st = unsafe self.tstate[g];
            if self.recall(p.addr, off, ty, st) == VNONE {
                self.remember(p.addr, off, ty, v, st, p.mem);
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
    // `sl_at`, `sl_in` for `b`: a slot's address escapes where a value it derives (`pder`) is used other
    // than as a load's or store's address, a copy's or fill's address or a pointer sum's base (a call's
    // argument, a stored value, a block argument, a comparison or a select's operand, a return, a
    // conversion), and stays escaped on every path from there (a forward pass over the blocks: each block's
    // entry set grows at most 64 times).
    fn slot_escapes(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        let ni = b.insts.len();
        fill(&mut self.sl_at, ni, 0);
        fill(&mut self.sl_in, nb, 0);
        // A use that escapes here escapes in `privates` (which also counts volatile accesses): with no slot
        // of those escaped, every set stays empty.
        let mut any = false;
        for s in 0..self.pesc.len().min(64) {
            any = any || self.pesc[s];
        }
        if !any {
            return;
        }
        let mut bout = replace(&mut self.sl_bout, Vector::<u64>::new());
        fill(&mut bout, nb, 0);
        let mut bgen = replace(&mut self.sl_bgen, Vector::<u64>::new());
        fill(&mut bgen, nb, 0);
        for k in 0..nb {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                let mut e: u64 = 0;
                for u in self.ops_at[i as usize]..self.ops_at[i as usize + 1] {
                    let v = self.ops[u as usize];
                    let q = self.der_slot(b, v);
                    if q >= 64 {
                        continue;
                    }
                    let addr = (t.op == O_LOAD || t.op == O_STORE || t.op == O_PTRADD) && u == self.ops_at[i as usize] && v == t.a;
                    let mem = (t.op == O_MEMCPY && u < self.ops_at[i as usize] + 2 || t.op == O_MEMSET && u == self.ops_at[i as usize]) && (v == t.a || v == t.b && t.op == O_MEMCPY);
                    if !addr && !mem {
                        e |= 1u64 << q as u64;
                    }
                }
                bgen[k] |= e;
                self.sl_at[i as usize] = e;
            }
        }
        // A worklist of blocks whose entry set grew (each at most 64 times).
        let mut work = replace(&mut self.sl_work, Vector::<u32>::new());
        work.truncate(0);
        let mut queued = replace(&mut self.sl_queued, Vector::<bool>::new());
        fill(&mut queued, nb, true);
        for k in 0..nb {
            work.push(k as u32);
        }
        while work.len() != 0 {
            let k = work.pop().unwrap() as usize;
            queued[k] = false;
            let out = self.sl_in[k] | bgen[k];
            if out == bout[k] && k != 0 {
                continue;
            }
            bout[k] = out;
            for x in self.succ_at[k]..self.succ_at[k + 1] {
                let s = self.succs[x as usize] as usize;
                if (self.sl_in[s] | out) != self.sl_in[s] {
                    self.sl_in[s] |= out;
                    if !queued[s] {
                        queued[s] = true;
                        work.push(s as u32);
                    }
                }
            }
        }
        // Per instruction, the escapes before it: its block's entry set and those of the instructions before
        // it there.
        for k in 0..nb {
            let bk = b.blocks[k];
            let mut acc = self.sl_in[k];
            for i in bk.start..bk.start + bk.len {
                let e = self.sl_at[i as usize];
                self.sl_at[i as usize] = acc;
                acc |= e;
            }
        }
        self.sl_bout = bout;
        self.sl_bgen = bgen;
        self.sl_work = work;
        self.sl_queued = queued;
    }

    // Whether write `t`, instruction `i` of `b`, a call or a store, touches none of the bytes `[lo, hi)` past
    // address `a` in a slot whose address has not escaped before it (`sl_at`): a store through no value that
    // slot derives; a call none of whose arguments that slot derives, or each at a constant offset from the
    // same address, through which the callee reaches only bytes apart from those (`Sym.span`).
    fn slot_apart(self: &Self, pk: &Package, b: &Body, i: u32, t: Inst, a: Value, lo: i64, hi: i64) bool {
        let q = self.der_slot(b, a);
        if q >= 64 || i as usize >= self.sl_at.len() || (self.sl_at[i as usize] >> q as u64 & 1) != 0 {
            return false;
        }
        if t.op == O_STORE {
            return self.der_slot(b, t.a) != q;
        }
        if t.op != O_CALL {
            return false;
        }
        let sy = pk.syms[b.syms[t.a as usize] as usize];
        let (base, off) = address_of(b, a);
        for k in 0..t.aux as u32 {
            let v = b.pool[(t.c + k) as usize];
            if self.der_slot(b, v) != q {
                continue;
            }
            let (vb, vo) = address_of(b, v);
            let s = if sy.span != NONE && k as u64 < pk.spans[sy.span as usize] {
                pk.spans[(sy.span + 1 + k) as usize]
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

    fn call_apart(self: &Self, pk: &Package, b: &Body, i: u32, t: Inst, a: Value, lo: i64, hi: i64) bool {
        let c = self.class(a);
        if c < CL_NOALIAS || c >= CL_FROZEN || (class_bit(c) & self.sbits) != 0 || (self.owned_args(pk, b, i, t) & class_bit(
            c,
        )) != 0 {
            return false;
        }
        let sy = pk.syms[b.syms[t.a as usize] as usize];
        let (base, off) = address_of(b, a);
        for q in 0..t.aux as u32 {
            let v = b.pool[(t.c + q) as usize];
            if (class_bit(self.acc(b, i, v)) & class_bit(c)) == 0 {
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
        // and keep the others in a register (a 64-bit integer on arm64, a float, a wide constant). A slot's
        // or a symbol's address is one (`live::remat_inst`): an inlined check's panic arguments.
        let tls = tls_addr(pk, b, t);
        let konst = t.op == O_ICONST || t.op == O_FCONST || t.op == O_WCONST || t.op == O_SLOTADDR || t.op == O_SYMADDR && !tls;
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

    // Header `h`'s exit test `q + c <u n`, true on the edge into a body of other blocks, of a counter `q` that
    // starts at a constant and steps by a constant `d`, `c` a nonzero constant whose sum with the start does
    // not wrap, `n` from outside the loop, at most `max - d + 1` (any `n` for a step by 1; else a bound the
    // branches in scope set, `ubound`): `q <u n - min(n, c)`, the difference made in the preheader. Each sum
    // the test reads is below `n + d`, so none wraps and both tests agree; the header then only tests its
    // counter, a counted loop (LLVM's IndVarSimplify). A test `q + c <=u n` likewise, `n` at most `max - d`:
    // `q <u (n >=u c ? n - (c - 1) : 0)`. The sum may be a checked one's (`addo`, unsigned): it wraps
    // nowhere, so its flag is 0 and it is a plain sum. Whether it did.
    fn offset_test(self: &mut Self, pk: &Package, b: &mut Body, h: u32) bool {
        let p = self.preh[h as usize];
        let th = term(b, h);
        if p == NONE || th.op != O_BR || (th.a & (VPARAM | VFLAG)) != 0 || th.a == VNONE || b.edge_target(th.b) == h || b.edge_target(
            th.c,
        ) == h {
            return false;
        }
        // The test holds on the edge into the body: where it fails the loop leaves, so each counter value
        // passed the test before its step.
        if !self.in_loop(h, b.edge_target(th.b)) || self.in_loop(h, b.edge_target(th.c)) {
            return false;
        }
        let c = b.insts[th.a as usize];
        let ule = c.aux == C_ULE;
        if c.op != O_ICMP || c.aux != C_ULT && !ule || (c.a & (VPARAM | VFLAG)) != 0 || c.a == VNONE || !self.outside(
            c.b,
            h,
        ) {
            return false;
        }
        let s = b.insts[c.a as usize];
        let hb = b.blocks[h as usize];
        let checked = s.op == O_ADDO && (s.aux & OV_SIGNED) == 0;
        if s.op != O_ADD && !checked || !is_int(s.ty) || s.ty == T_I128 || (s.a & VPARAM) == 0 || s.a == VNONE || (s.a & ~VPARAM) < hb.param_start || (s.a & ~VPARAM) >= hb.param_start + hb.param_len as u32 {
            return false;
        }
        let off = int_bits(b, s.b);
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
                    let st = int_bits(b, x);
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
                    int_bits(b, u.b).unwrap_or(0) & top
                } else if u.b == s.a {
                    int_bits(b, u.a).unwrap_or(0) & top
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
        let slack = ast::pick(ule, 0u64, 1u64);
        if d == 0 || (d != 1 || ule) && self.ubound(pk, b, n, UB_DEPTH).unwrap_or(top) > top - d + slack {
            return false;
        }
        let n2 = if ule && kc == 1 {
            n
        } else {
            let at = b.blocks[p as usize].start + b.blocks[p as usize].len - 1;
            let kv = self.constant(b, s.ty, kc);
            let zv = self.constant(b, s.ty, 0);
            let ge = self.placed(b, p, at, Inst { op: O_ICMP, ty: T_I8, aux: C_UGE, a: n, b: kv, c: VNONE }, false);
            let kd = ast::pick(ule, self.constant(b, s.ty, kc - 1), kv);
            let dv = self.placed(b, p, at, Inst { op: O_SUB, ty: s.ty, aux: 0, a: n, b: kd, c: VNONE }, false);
            self.placed(b, p, at, Inst { op: O_SELECT, ty: s.ty, aux: 0, a: ge, b: dv, c: zv }, false)
        };
        b.insts[th.a as usize] = Inst { op: O_ICMP, ty: c.ty, aux: C_ULT, a: s.a, b: n2, c: VNONE };
        if checked {
            b.insts[c.a as usize] = Inst { op: O_ADD, ty: s.ty, aux: 0, a: s.a, b: s.b, c: VNONE };
            self.frepl[c.a as usize] = self.constant(b, T_I8, 0);
        }
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

    // Instruction `i` of block `k` in a loop, `(x + a) + b`, `(x + a) - b`, `(x - a) + b` or `(x - a) - b`
    // of plain integers with `x` varying in the loop and `a`, `b` from outside it: `x` plus or minus the one
    // value of `a` and `b` (made before `i`, which a later walk moves out of the loop), so an index
    // `i + m - j - 1` of an inner loop is its counter plus an invariant (LLVM's Reassociate ranks loop
    // invariants together). Exact modulo the type's bits.
    fn invariant_sum(self: &mut Self, b: &mut Body, k: u32, i: u32) {
        let t = b.insts[i as usize];
        let h = self.inner[k as usize];
        if h == NONE || t.op != O_ADD && t.op != O_SUB || t.aux != 0 || !is_int(t.ty) || t.ty == T_I128 || (t.a & (VPARAM | VFLAG)) != 0 || t.a == VNONE || !self.inv_val(
            b,
            t.b,
            h,
            INV_DEPTH,
        ) || self.inv_val(b, t.a, h, INV_DEPTH) {
            return;
        }
        let u = b.insts[t.a as usize];
        if u.op != O_ADD && u.op != O_SUB || u.aux != 0 || u.ty != t.ty {
            return;
        }
        // `u` as `x op a`, `a` from outside, `x` not.
        let (x, a) = if self.inv_val(b, u.b, h, INV_DEPTH) && !self.inv_val(b, u.a, h, INV_DEPTH) {
            (u.a, u.b)
        } else if u.op == O_ADD && self.inv_val(b, u.a, h, INV_DEPTH) && !self.inv_val(b, u.b, h, INV_DEPTH) {
            (u.b, u.a)
        } else {
            (VNONE, VNONE)
        };
        if x == VNONE {
            return;
        }
        // x + a + b = x + (a + b); x + a - b = x + (a - b); x - a + b = x + (b - a); x - a - b = x - (a + b).
        let (op, p, q, top) = if u.op == O_ADD {
            (t.op, a, t.b, O_ADD)
        } else if t.op == O_ADD {
            (O_SUB, t.b, a, O_ADD)
        } else {
            (O_ADD, a, t.b, O_SUB)
        };
        let w = self.before(b, k, i, Inst { op: op, ty: t.ty, aux: 0, a: p, b: q, c: 0 });
        b.insts[i as usize] = Inst { op: top, ty: t.ty, aux: 0, a: x, b: w, c: 0 };
    }

    // Whether `v` is the same in every iteration of loop `h`: defined outside it, or a sum or difference of
    // such values (`invariant_sum`'s, until a walk moves them out), at most `d` deep.
    fn inv_val(self: &Self, b: &Body, v: Value, h: u32, d: u32) bool {
        if self.outside(v, h) {
            return true;
        }
        if d == 0 || (v & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let t = b.insts[v as usize];
        return (t.op == O_ADD || t.op == O_SUB) && self.inv_val(b, t.a, h, d - 1) && self.inv_val(b, t.b, h, d - 1);
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
        let mut nofx = replace(&mut self.nofx, Vector::<bool>::new());
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
        for k in 0..nb {
            if self.nxt[k] != NONE {
                self.done[self.nxt[k] as usize] = true;
            }
        }
        // A reached block one edge enters now that several entered at the walk (the walk's tables, or a
        // block it made): the next walk gives it that edge's arguments and its predecessor's facts
        // (`forward_params`, the memory states). A block that kept its one edge saw them already.
        self.merged = false;
        for k in 1..nb {
            if self.bmap[k] != NONE && self.in_at[k + 1] - self.in_at[k] == 1 && (k + 1 >= self.pred_at.len() || self.pred_at[k + 1] - self.pred_at[k] != 1) {
                self.merged = true;
                break;
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
        if self.pre.len() != 0 {
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
        self.pbody.insts.truncate(0);
        self.pbody.locs.truncate(0);
        self.pbody.inl.truncate(0);
        self.pbody.blocks.truncate(0);
        fill(&mut self.done_pool, b.pool.len(), false);
        let mut np: u32 = 0;
        for k in 0..nb {
            if self.bmap[k] == NONE || self.done[k] {
                continue;
            }
            let bk = b.blocks[k];
            let start = self.pbody.insts.len() as u32;
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
            self.pbody.blocks.push(
                Block {
                    start: start,
                    len: self.pbody.insts.len() as u32 - start,
                    param_start: ps,
                    param_len: (np - ps) as u16,
                    // The blocks of a chain run equally often, as often as control enters its head: the head's
                    // rare marks are the merged block's (a later block's describe an edge into it that is gone).
                    flags: flags & ~BLOCK_RARE | bk.flags & BLOCK_RARE,
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
        // Copied into the body's own buffers, which hold the input and so fit the output: a swap would hand
        // the body this scratch's buffers, sized for the largest body yet, and the scratch would grow anew.
        assign(&mut b.insts, &self.pbody.insts);
        assign(&mut b.locs, &self.pbody.locs);
        if b.inl.len() != 0 {
            assign(&mut b.inl, &self.pbody.inl);
        }
        assign(&mut b.blocks, &self.pbody.blocks);
        assign(&mut b.params, &self.params);
        self.drop_slots(b);
        // Empty, its buffer kept for the next walk's.
        nofx.truncate(0);
        self.nofx = nofx;
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
        if b.slots.len() == 0 {
            return;
        }
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
        lv::uses_edges(b, t, &mut self.uses);
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
        self.pbody.insts.push(t);
        self.pbody.locs.push(b.locs[i as usize]);
        if b.inl.len() != 0 {
            self.pbody.inl.push(b.inl[i as usize]);
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
/// count), and a body inlines only bodies of a lower level, so each body waits for its direct callees of
/// a lower level (`edges`), and for the callees of a lower level its copies brought before it inlines
/// them (`warm_copies`, `await_marked`), each done as in the serial order: the result does not depend on
/// the schedule. A body of a unit `sealed` marks (by unit) inlines into bodies of its unit only.
pub(package) struct Run {
    /// One edge per callee a body waits for: `callee << 32 | caller`, each pair once.
    pub(package) edges: Vector<u64>,
    /// The bodies by level: a serial order every edge runs forward in.
    pub(package) order: Vector<u32>,
    /// Per body, whether its job finished (a held body's: from the start), and the waits for it.
    fin: psync::Mutex<Vector<bool>>,
    fin_cv: psync::Condvar,
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
    always: Vector<bool>, // per body, whether its function is `@always_inline` (`Sym.always`)
    unit: Vector<u32>,
    bunit: Vector<u32>, // per body, its function's `Sym.unit` (NONE: none)
    level: Vector<u32>,
    // Per body, whether a caller may inline it: written by the body's job, read by its callers' jobs.
    ok: UnsafeCell<Vector<u8>>, // per body, its inliner facts (`il::facts`; 0: callers may not inline it)
    // Per body whose loop transforms or packing made vectors, its final form: `bodies` holds the form
    // before them, which callers inline (`job`), until `finish` swaps the two (`take_inlined`). Boxed: few
    // bodies have one, and the table holds a pointer per body.
    finals: UnsafeCell<Vector<Option<Box<Body>>>>,
    inline: bool,
    cf: Config,
    // `SC_LIR_PRINT`: each optimized body whose function's name holds it prints to stderr (a debugging aid).
    print: String,
    // `SC_VEC_REPORT=1`: each loop the vectorizer left prints its location and why (a debugging aid).
    report: bool,
    // Scratch a job takes and gives back: it grows once per worker, not once per body. Under a spin lock
    // (`free_lock`): a job that parked on a lock while it holds a scratch would let its worker start a job
    // that makes another.
    free: UnsafeCell<Vector<Box<Scratch>>>,
    free_lock: UnsafeCell<i32>,
    // The parts of a scratch a large body's job (`SHARE_MIN`) takes for one pass and gives back, under
    // `free_lock`: a pass runs for a part of a job, so fewer of them than scratches grow to a large body's
    // tables, and a small body's passes use the scratch's own. The promoters, the packings' scratch
    // (`Opt::slp`), the loop transforms' (from the first round to the vectorizer's report, with the tables
    // `save_tables` keeps) and the pool compactions' (`Body::compact_pool`).
    proms: UnsafeCell<Vector<pr::Promoter>>,
    slps: UnsafeCell<Vector<sl::Slp>>,
    loops: UnsafeCell<Vector<LoopParts>>,
    pools: UnsafeCell<Vector<PoolScratch>>,
}

// A large body's loop window's scratch (`Run::loops`): the transforms' and the tables `save_tables` keeps.
struct LoopParts {
    unr: lu::LoopOpt,
    saved: Vector<Vector<u32>>,
    saved_lb: Vector<u64>,
}

// The instructions of a body past which its passes take the run's shared parts (`Run::proms`): the
// scratches' own parts grow to smaller bodies' tables only, and a smaller body's pass takes no lock.
const SHARE_MIN: usize = 512;

// The last of pool `v` under spin lock `lock`, None when it is empty.
fn pool_take<T>(lock: &UnsafeCell<i32>, v: &UnsafeCell<Vector<T>>) Option<T> {
    unsafe sc_runtime::sc_rt_spin_lock(lock.get());
    let x = unsafe (*v.get()).pop();
    unsafe sc_runtime::sc_rt_spin_unlock(lock.get());
    return x;
}

// `x` back into pool `v` under spin lock `lock`.
fn pool_give<T>(lock: &UnsafeCell<i32>, v: &UnsafeCell<Vector<T>>, x: T) {
    unsafe sc_runtime::sc_rt_spin_lock(lock.get());
    unsafe (*v.get()).push(x);
    unsafe sc_runtime::sc_rt_spin_unlock(lock.get());
}

// Keep the buffers of `x`, a body a job is done with, as the spare of a rebuild of `sc` whose own are
// smaller (by instructions; the spare it takes the place of goes on to the next): the spares grow to the
// largest body the scratch serves, and the rebuilds stop allocating.
fn recycle(sc: &mut Box<Scratch>, done: Body) {
    let mut x = done;
    if x.insts.capacity() > sc.il.spare.insts.capacity() {
        x = replace(&mut sc.il.spare, x);
    }
    if x.insts.capacity() > sc.o.pbody.insts.capacity() {
        x = replace(&mut sc.o.pbody, x);
    }
    if x.insts.capacity() > sc.o.snap.insts.capacity() {
        let _ = replace(&mut sc.o.snap, x);
    }
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
        // The jobs hold the bodies for the whole phase: in a table of about their count (the merges reserve
        // it, `lir_reserve`), not one that grew by doubling.
        let mut bodies = replace(&mut pk.bodies, Vector::<Body>::new());
        if bodies.capacity() - bodies.len() > bodies.len() / 8 {
            let mut fit = Vector::<Body>::with_capacity(bodies.len());
            while let Some(b) = bodies.pop() {
                fit.push(b);
            }
            fit.reverse();
            bodies = fit;
        }
        let n = bodies.len();
        let held = ast::pick(pk.held.body == NONE, n as u32, pk.held.body);
        let mut cs = Calls {
            at: Vector::<u32>::with_capacity(n + 1),
            callee: Vector::<u32>::new(),
            live: Vector::<bool>::new(),
            arg_at: Vector::<u32>::new(),
            arg: Vector::<u32>::new(),
            bits: Vector::<u64>::new(),
        };
        calls_of(pk, &bodies, held, &mut cs, cf.jobs);
        let mut wargs = Vector::<u64>::new();
        let mut esc = Vector::<u64>::new();
        let mut sp = Vector::<u64>::new();
        let mut sp_at = Vector::<u32>::new();
        let fx = effects(pk, &bodies, &cs, &mut wargs, &mut esc, &mut sp, &mut sp_at, cf.jobs);
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
        let mut always = Vector::<bool>::with_capacity(n);
        always.resize_default(n);
        let mut ok = Vector::<u8>::with_capacity(n);
        ok.resize_default(n);
        let mut unit = Vector::<u32>::with_capacity(n);
        let mut bunit = Vector::<u32>::with_capacity(n);
        for _ in 0..n {
            unit.push(NONE);
            bunit.push(NONE);
        }
        // The inliner's shape test of each body below `held` under its function's symbol (the last one
        // that names it), by chunks of bodies on worker threads.
        let mut owner = Vector::<u32>::new();
        fill(&mut owner, held as usize, NONE);
        for s in 0..p.syms.len() {
            let sy = p.syms[s];
            if sy.kind == SK_FUNC && sy.def != NONE && sy.def < held {
                owner[sy.def as usize] = s as u32;
            }
        }
        let mut sx = ShapeCtx {
            p: p,
            bodies: &bodies,
            owner: owner.as_ptr(),
            held: held as usize,
            shape: shape.as_mut_ptr(),
        };
        par::chunks((held as usize + SHAPE_CHUNK - 1) / SHAPE_CHUNK, cf.jobs, shape_chunk, (&mut sx) as *mut ShapeCtx);
        for s in 0..p.syms.len() {
            let sy = p.syms[s];
            if sy.kind == SK_FUNC && sy.def != NONE {
                bunit[sy.def as usize] = sy.unit;
                always[sy.def as usize] = sy.always;
                if sy.unit < sealed.len() as u32 && sealed[sy.unit as usize] {
                    unit[sy.def as usize] = sy.unit;
                }
            }
        }
        // A held body's facts are the ones its unit's build found.
        for k in held as usize..n {
            let f = hd.flags[k - held as usize];
            shape[k] = (f & HELD_SHAPE) != 0;
            ok[k] = if (f & HELD_OK) != 0 {
                il::facts(&bodies[k], cf.inline)
            } else {
                0u8
            };
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
        // Counted, then listed.
        let mut seen = Vector::<u32>::new();
        let mut edges = Vector::<u64>::new();
        let ne = waits(n, &call_at, &calls, &level, &mut seen, &mut edges, false);
        edges.reserve_exact(ne);
        let _ = waits(n, &call_at, &calls, &level, &mut seen, &mut edges, true);
        let mut fin = Vector::<bool>::with_capacity(n);
        for k in 0..n {
            fin.push(k as u32 >= held);
        }
        let mut finals = Vector::<Option<Box<Body>>>::with_capacity(n);
        for _ in 0..n {
            finals.push(Option::<Box<Body>>::None);
        }
        return Run {
            edges: edges,
            order: order,
            pk: pkp,
            bodies: UnsafeCell::<Vector<Body>>::new(bodies),
            finals: UnsafeCell::<Vector<Option<Box<Body>>>>::new(finals),
            held: held,
            call_at: call_at,
            calls: calls,
            wargs: wargs,
            shape: shape,
            unit: unit,
            always: always,
            bunit: bunit,
            level: level,
            ok: UnsafeCell::<Vector<u8>>::new(ok),
            fin: psync::Mutex::<Vector<bool>>::new(fin),
            fin_cv: psync::Condvar::new(),
            // SC_LIR_INLINE=0 inlines nothing (a debugging aid).
            inline: !stdlib::env_is("SC_LIR_INLINE", "0"),
            cf: cf,
            print: stdlib::get_env("SC_LIR_PRINT").unwrap_or(String::new()),
            report: stdlib::env_is("SC_VEC_REPORT", "1"),
            free: UnsafeCell::<Vector<Box<Scratch>>>::new(Vector::<Box<Scratch>>::new()),
            free_lock: UnsafeCell::<i32>::new(0),
            proms: UnsafeCell::<Vector<pr::Promoter>>::new(Vector::<pr::Promoter>::new()),
            slps: UnsafeCell::<Vector<sl::Slp>>::new(Vector::<sl::Slp>::new()),
            loops: UnsafeCell::<Vector<LoopParts>>::new(Vector::<LoopParts>::new()),
            pools: UnsafeCell::<Vector<PoolScratch>>::new(Vector::<PoolScratch>::new()),
        };
    }

    /// The estimated work of body `j`'s job: its instruction count (0 for a held body, which has none).
    pub(package) fn cost(self: &Self, j: u32) u64 {
        if j >= self.held {
            return 0;
        }
        return (unsafe (*self.bodies.get())[j as usize].insts.len()) as u64;
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
        // A job preempted while it holds a scratch would make its worker's next job take another: one
        // scratch per job in flight, not per worker.
        prt::preempt_mask_enter();
        let mut sc = r.take();
        // The passes work on the body out of the package, which gets it back at the end at about its size
        // (`take_compact`): the rebuilds swap it with the scratch's spares, whose buffers it then keeps
        // (`recycle`).
        let pb = unsafe &mut *(base + j as usize);
        let mut wb = replace(pb, Body::empty());
        let b = &mut wb;
        r.ready(p, j, &mut sc, true, false);
        // The inliner reads the rare blocks, the loop transforms and the code generators too: marked before
        // the inlining (a copy takes its call's marks) and once the transforms made their blocks.
        sc.o.estimate(p, b);
        let inlined = sc.il.run(p, base, r.ok.get_ref(), &r.level, &r.unit, j, r.cf.inline, b);
        // The switches as compares and branches, before the first walk, which simplifies them (a test that
        // returns a value on either side returns a select).
        let lowered = p.switch_tree && sws::lower(b, p.ptr_bytes, p.switch_tables);
        if inlined || lowered {
            sc.o.forget();
        }
        let _ = sc.o.run(p, b, inlined || lowered);
        // The calls a callee's copy brought from a rare block of the callee that the walk left in a warm one
        // (a branch that folds with the caller's values: a vector known empty grows) inline as the caller's
        // own did. Two runs: the first folds the copies' branches and merges their blocks, the second forwards
        // the memory across the merged blocks (an allocation's pointer stored in a slot, read back).
        let warm = r.inline && warm_copies(b, &mut sc.il.only);
        if warm && !r.marked_done(p, j, b, &sc.il.only) {
            // While the job waits, its scratch serves another job, and the job takes one back after.
            let only = replace(&mut sc.il.only, Vector::<bool>::new());
            let (pslots, deferred) = (sc.o.pslots, sc.o.deferred);
            r.give(sc);
            r.await_marked(p, j, b, &only);
            sc = r.take();
            r.ready(p, j, &mut sc, pslots, deferred);
            sc.il.only = only;
        }
        if warm {
            let more = sc.il.run(p, base, r.ok.get_ref(), &r.level, &r.unit, j, r.cf.inline, b);
            sc.il.only.truncate(0);
            if more {
                sc.o.forget();
                let _ = sc.o.run(p, b, true);
                sc.o.forget();
                let _ = sc.o.run(p, b, true);
            }
        }
        // The calls through a method of a constant table the walk read (`fold_ptr`, a known `&dyn`) inline as
        // the direct ones did.
        if r.inline && r.direct_known(p, j, b, &mut sc.il.only) {
            // The memory facts the walk kept know those calls as indirect ones: also when none inlines.
            sc.o.forget();
            let more = sc.il.run(p, base, r.ok.get_ref(), &r.level, &r.unit, j, r.cf.inline, b);
            sc.il.only.truncate(0);
            if more {
                let _ = sc.o.run(p, b, true);
            }
        }
        // Without tables of constants (`Package.switch_tables`), a switch the walk gave arguments (its cases'
        // forwarding blocks merged into its edges) lowers once more.
        if p.switch_tree && !p.switch_tables && sws::lower(b, p.ptr_bytes, false) {
            sc.o.forget();
            let _ = sc.o.run(p, b, true);
        }
        if sc.o.return_slot(p, b) {
            let _ = sc.o.run(p, b, true);
        }
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
        if bu.vector != 0 && sc.o.pointer_counts(p, b) {
            let _ = sc.o.run(p, b, true);
        }
        let snap = r.inline && r.shape[j as usize] && bu.vector != 0 && !packed(b);
        let want = snap && (il::bounded(b, r.cf.inline) || r.always[j as usize]);
        // A straight body (`Opt::straight`) keeps this form until the packing, which copies it: that copy
        // serves.
        let straight = want && sc.o.straight(p, b);
        let mut pre = if want && !straight {
            let mut s = replace(&mut sc.o.snap, Body::empty());
            b.copy_into(&mut s);
            Option::<Body>::Some(s)
        } else {
            Option::<Body>::None
        };
        let own_loops = if sc.o.shares(b) {
            let x = pool_take(&r.free_lock, &r.loops).unwrap_or(
                LoopParts {
                    unr: lu::LoopOpt::new(),
                    saved: Vector::<Vector<u32>>::new(),
                    saved_lb: Vector::<u64>::new(),
                },
            );
            Some(sc.o.swap_loops(x))
        } else {
            Option::<LoopParts>::None
        };
        // A loop a round copied is innermost again for the next one. The rounds' refusals gather per loop.
        sc.o.unr.wide = false;
        sc.o.unr.narrowed = false;
        sc.o.unr.reset_refusals();
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
                    version_checks: u32::MAX,
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
        if let Some(x) = own_loops {
            pool_give(&r.free_lock, &r.loops, sc.o.swap_loops(x));
        }
        // Then the packing of straight-line values into vectors, on the loops' final shape.
        if bu.vector != 0 {
            let form = sc.o.slp(p, b);
            if straight {
                pre = form;
            }
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
        if minmax {
            sc.o.forget();
        }
        if sc.o.dead_allocs(p, b) || placed || minmax {
            let _ = sc.o.run(p, b, true);
        }
        // The loops' counted addresses as pointers their accesses step, on the loops' final shape.
        if p.postinc {
            let _ = sc.o.pointer_ivs(p, b);
        }
        if p.sum_trees {
            sc.o.reassociate(p, b);
        }
        let _ = sc.o.split_exits(p, b);
        let so = &mut sc.o;
        if ret_edges(b, &mut so.mark, &mut so.edges) {
            so.forget();
        }
        sc.o.estimate(p, b);
        if r.print.len() != 0 {
            r.print_body(p, j, b);
        }
        // Its callers copy its pool when they inline it, and the code generators read it: the passes'
        // dead records go.
        let own_cps = if sc.o.shares(b) {
            Some(replace(&mut sc.o.cps, pool_take(&r.free_lock, &r.pools).unwrap_or(PoolScratch::new())))
        } else {
            Option::<PoolScratch>::None
        };
        b.compact_pool(&mut sc.o.cps);
        let mut fits = r.inline && r.shape[j as usize];
        let keep = snap && (packed(b) || rotated);
        switch pre {
            Some(s) => {
                if keep {
                    let fin = replace(b, s);
                    b.compact_pool(&mut sc.o.cps);
                    unsafe *((*r.finals.get()).as_mut_ptr() + j as usize) = Some(Box::new(fin.compact()));
                    recycle(&mut sc, fin);
                } else {
                    recycle(&mut sc, s);
                }
            },
            None => {
                if keep && packed(b) {
                    assert(!straight, "opt: only the packing makes vectors in a straight body");
                    fits = false;
                }
            },
        }
        // An `@always_inline` body inlines whatever its size.
        let facts = if fits && (il::bounded(b, r.cf.inline) || r.always[j as usize]) {
            il::facts(b, r.cf.inline)
        } else {
            0u8
        };
        if let Some(x) = own_cps {
            pool_give(&r.free_lock, &r.pools, replace(&mut sc.o.cps, x));
        }
        *pb = b.take_compact();
        recycle(&mut sc, wb);
        unsafe *((*r.ok.get()).as_mut_ptr() + j as usize) = facts;
        r.give(sc);
        prt::preempt_mask_exit();
        // Its body, facts and final form are written: the bodies waiting to inline it go on.
        let mut g = r.fin.lock();
        g.get_mut()[j as usize] = true;
        r.fin_cv.notify_all();
    }

    // Scratch `sc` set for body `j`: no analyses of another body, `param_slots` still to look at the body
    // (`pslots`), a quotient kept for the loop vectorizer (`deferred`).
    fn ready(self: &Self, p: &Package, j: u32, sc: &mut Box<Scratch>, pslots: bool, deferred: bool) {
        sc.o.forget();
        sc.o.shared = self;
        sc.o.pslots = pslots;
        sc.o.unit = self.bunit[j as usize];
        // Scalar quotients by a constant stay for the loop vectorizer until the loop transforms ran.
        sc.o.defer_div = self.cf.loops.vector != 0 && p.vector != 0 && p.vec_mulh != 0;
        sc.o.deferred = deferred;
    }

    // The body a call of `b` that `only` marks at instruction `i` reaches when its level is lower than body
    // `j`'s (the copies brought those calls; no edge of `j` names their callees), else NONE.
    fn marked_callee(self: &Self, p: &Package, j: u32, b: &Body, only: &Vector<bool>, i: usize) u32 {
        let c = if only[i] {
            call_target(p, b, b.insts[i])
        } else {
            NONE
        };
        return ast::pick(c == NONE || self.level[c as usize] >= self.level[j as usize], NONE, c);
    }

    // Whether the job of each body `marked_callee` names has finished; false while another job holds the
    // lock: the caller holds a scratch, and waits without it (`await_marked`).
    fn marked_done(self: &Self, p: &Package, j: u32, b: &Body, only: &Vector<bool>) bool {
        let held = self.fin.try_lock();
        if held.is_none() {
            return false;
        }
        let g = held.unwrap();
        for i in 0..only.len() {
            let c = self.marked_callee(p, j, b, only, i);
            if c != NONE && !g.get()[c as usize] {
                return false;
            }
        }
        return true;
    }

    // Wait until the job of each body `marked_callee` names has finished. Such a body waits for bodies of
    // lower levels alone, so the wait ends.
    fn await_marked(self: &Self, p: &Package, j: u32, b: &Body, only: &Vector<bool>) {
        let g = self.fin.lock();
        for i in 0..only.len() {
            let c = self.marked_callee(p, j, b, only, i);
            // Each wakeup follows a job's end; the job of `c` ends once.
            while c != NONE && !g.get()[c as usize] {
                self.fin_cv.wait_masked(&g);
            }
        }
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
        switch pool_take(&self.free_lock, &self.free) {
            Some(sc) => {
                return sc;
            },
            None => {},
        }
        return Box::new(Scratch { il: il::Inliner::new(), o: Opt::new() });
    }

    fn give(self: &Self, sc: Box<Scratch>) {
        pool_give(&self.free_lock, &self.free, sc);
    }

    /// Give the bodies back to `pk`, the package `new` took them from, in their final forms, their constant
    /// slots in read-only data (`const_slots`).
    pub(package) fn finish(self: &mut Self, pk: &mut Package) {
        let finals = self.finals.get_mut();
        let bodies = self.bodies.get_mut();
        for j in 0..finals.len() {
            let f = replace(finals.index_mut(j), Option::<Box<Body>>::None);
            if f.is_some() {
                let mut bx = f.unwrap();
                let pre = replace(bodies.index_mut(j), bx.replace(Body::empty()));
                bx.set(pre);
                finals.set(j, Some(bx));
            }
        }
        pk.bodies = replace(bodies, Vector::<Body>::new());
        const_slots(pk, finals, self.cf.jobs);
        symbol_tables(pk, finals);
        // The calls through a method a constant table holds (`fold_ptr`): the jobs, which ran at once, did
        // not read another body's signature.
        direct_calls(pk);
    }

    /// After `finish`, the form of body `k` its callers inlined, moved out: the one before the loop
    /// transforms and the packing when those made vectors or rotated its loops, else `pk`'s, which the
    /// caller gives back (true). Each body once.
    pub(package) fn take_inlined(self: &mut Self, pk: &mut Package, k: u32) (Body, bool) {
        let f = replace(self.finals.get_mut().index_mut(k as usize), Option::<Box<Body>>::None);
        if f.is_some() {
            let mut bx = f.unwrap();
            return (bx.replace(Body::empty()), false);
        }
        let b = replace(pk.bodies.index_mut(k as usize), Body::empty());
        assert(b.lines.len() != 0, "hold: a body taken twice");
        return (b, true);
    }

    /// Whether body `k` passed the inliner's shape test, and whether its callers may inline it (after its
    /// job).
    pub(package) const fn shape_of(self: &Self, k: u32) bool {
        return self.shape[k as usize];
    }

    pub(package) const fn inlinable(self: &Self, k: u32) bool {
        return (self.ok.get_ref()[k as usize] & il::IL_OK) != 0;
    }

    /// The parameters whose memory a call of body `k` may write (`FX_ARG`), a bit each.
    pub(package) const fn wargs_of(self: &Self, k: u32) u64 {
        return self.wargs[k as usize];
    }

    /// The direct calls of body `k` before optimization, as bodies in instruction order, then the functions
    /// of the read-only tables it names.
    pub(package) const fn calls_of(self: &Self, k: u32) Slice<u32> {
        return self.calls[self.call_at[k as usize] as usize..self.call_at[k as usize + 1] as usize];
    }

    // Each indirect call of body `j` (`b`) through the address of a function `j` waits for (`edges`: one
    // `calls_of(j)` lists, of a lower level, so its job is done) whose signature the call fits: a direct call,
    // marked in `only` (per instruction). Whether any.
    fn direct_known(self: &Self, p: &Package, j: u32, b: &mut Body, only: &mut Vector<bool>) bool {
        let base = unsafe (*self.bodies.get()).as_ptr();
        let cs = self.calls_of(j);
        let mut any = false;
        fill(only, b.insts.len(), false);
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            if t.op != O_CALLIND || (t.a & (VPARAM | VFLAG)) != 0 || b.insts[t.a as usize].op != O_SYMADDR || b.insts[t.a as usize].b != 0 {
                continue;
            }
            let s = b.insts[t.a as usize].a;
            let c = p.syms[b.syms[s as usize] as usize].def;
            if p.syms[b.syms[s as usize] as usize].kind != SK_FUNC || c == NONE || self.level[c as usize] >= self.level[j as usize] || !cs.contains(
                &c,
            ) || !lv::call_fits(unsafe &*(base + c as usize), b, t.b) {
                continue;
            }
            b.insts[i].op = O_CALL;
            b.insts[i].a = s;
            only[i] = true;
            any = true;
        }
        if !any {
            only.truncate(0);
        }
        return any;
    }
}

// Each direct call of `b` that an inlined copy brought (`Body.inl`) in a block that is not rare, marked in
// `only` (per instruction). Whether any.
fn warm_copies(b: &Body, only: &mut Vector<bool>) bool {
    fill(only, b.insts.len(), false);
    let mut any = false;
    if b.inl.len() != 0 {
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            if (bk.flags & BLOCK_RARE) != 0 {
                continue;
            }
            for i in bk.start..bk.start + bk.len {
                if b.insts[i as usize].op == O_CALL && b.inl[i as usize] != 0 {
                    only[i as usize] = true;
                    any = true;
                }
            }
        }
    }
    if !any {
        only.truncate(0);
    }
    return any;
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

/// `Run::new`, every job in `order` on this thread, then `finish`: every pass on this thread, whatever
/// `cf.jobs`.
pub(package) fn optimize(pk: &mut Package, sealed: &Vector<bool>, cf: Config) {
    let mut one = cf;
    one.jobs = 1;
    let mut r = Run::new(pk, sealed, one);
    for k in 0..r.order.len() {
        r.job(r.order[k]);
    }
    r.finish(pk);
}

// Each switch of the optimized bodies that selects symbol addresses (`sws::symbol_table`) reads them from
// a read-only table of its own (LLVM's switch to lookup table): a load in place of a branch per case. A
// body that took one is optimized again, which removes the cases' blocks. Its form before, the one its
// callers inlined, stays in `pre` (`Run::take_inlined`) unless an earlier one does.
fn symbol_tables(pk: &mut Package, pre: &mut Vector<Option<Box<Body>>>) {
    let held = pk.held_bodies();
    let owner = pk.body_owners();
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
            if !took && pre.at(j).is_none() {
                pre.set(j, Some(Box::new(pk.bodies[j].compact())));
            }
            sws::use_symbol_table(pk.bodies.index_mut(j), k as u32, &st, d, ptr);
            took = true;
        }
        if took {
            let mut b = replace(pk.bodies.index_mut(j), Body::empty());
            o.forget();
            o.unit = pk.syms[owner[j] as usize].unit;
            let _ = o.run(pk, &mut b, true);
            let _ = ret_edges(&mut b, &mut o.mark, &mut o.edges);
            o.estimate(pk, &mut b);
            pk.bodies[j] = b;
        }
    }
}

// At most CONST_SLOT_BYTES bytes of a slot go to read-only data (`const_slots`).
const CONST_SLOT_BYTES: u32 = 4096;
// `const_slots`' offset of an address the slot gives at a variable place.
const OFF_VAR: u64 = 0xFFFFFFFFFFFFFFFE;

// Place each slot of the optimized bodies that only constants of disjoint bytes are stored into, and whose
// address only those stores and loads read (through offsets and indices), or a direct call as an aggregate
// argument its callee only reads (`Sym.wargs`, `Sym.esc`), in read-only data of its own: the code loads from it
// rather than store the constants at each call (a constant local array; LLVM promotes such an alloca to a
// constant global). A stored constant may be a symbol's address (`image`): a relocation. A byte no store
// writes is 0, which a read of it before any store, undefined, may give. The stores and the values only
// they read become unused constants. A body's form before, the one its callers inlined, stays in `pre`
// (`Run::take_inlined`) unless an earlier one does: a unit that inlines it from a record then makes the data its
// own.
fn const_slots(pk: &mut Package, pre: &mut Vector<Option<Box<Body>>>, jobs: u32) {
    let held = pk.held_bodies();
    let owner = pk.body_owners();
    // Which bodies have a slot to place, by chunks on worker threads: the scan reads the package alone. The
    // few that do are scanned again below, in order, as they change the package.
    let mut cand = Vector::<bool>::new();
    fill(&mut cand, held, false);
    let nc = (held + CS_CHUNK - 1) / CS_CHUNK;
    let mut cx = CsCtx { pk: pk, owner: owner.as_ptr(), cand: cand.as_mut_ptr(), held: held };
    par::chunks(nc, jobs, cs_chunk, (&mut cx) as *mut CsCtx);
    let mut cs = ConstSlot::new();
    for k in 0..held {
        if !cand[k] || !cs.scan(pk, &pk.bodies[k]) {
            continue;
        }
        cs.work.truncate(0);
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
            if !pk.add_data(d, sl.size, sl.align_log2, true, &cs.bytes, &cs.relocs) {
                continue;
            }
            if pre.at(k).is_none() {
                pre.set(k, Some(Box::new(pk.bodies[k].compact())));
            }
            let b = pk.bodies.index_mut(k);
            let r = b.ref_sym(d);
            for i in 0..b.insts.len() {
                let t = b.insts[i];
                if t.op == O_SLOTADDR && t.a == s as u32 {
                    b.insts[i] = Inst { op: O_SYMADDR, ty: T_PTR, aux: 0, a: r, b: 0, c: VNONE };
                } else if t.op == O_STORE && cs.slot[i] == s as u32 {
                    b.insts[i] = iconst(T_I8, 0);
                    cs.work.push(t.b);
                }
            }
            b.slots.index_mut(s).size = 0;
            b.slots.index_mut(s).align_log2 = 0;
        }
        if cs.work.len() != 0 {
            cs.drop_unused(pk.bodies.index_mut(k));
        }
    }
}

// The bodies of a `const_slots` scan chunk.
const CS_CHUNK: usize = 256;

// What the scan chunks read, and per body whether it has a slot to place, each written by its chunk alone.
struct CsCtx {
    pk: *const Package,
    owner: *const u32,
    cand: *mut bool,
    held: usize,
}

fn cs_chunk(ctx: *mut void, c: usize) {
    let x = unsafe &*(ctx as *const CsCtx);
    let pk = unsafe &*x.pk;
    let mut cs = ConstSlot::new();
    for k in c * CS_CHUNK..(c * CS_CHUNK + CS_CHUNK).min(x.held) {
        unsafe x.cand[k] = unsafe x.owner[k] != NONE && pk.bodies[k].slots.len() != 0 && cs.scan(pk, &pk.bodies[k]);
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
    relocs: Vector<Reloc>, // the slot at hand's relocations
    cnt: Vector<u32>, // `drop_unused`: per instruction, its reads
    work: Vector<u32>, // the values the removed stores wrote
}

extend ConstSlot {
    fn new() ConstSlot {
        return ConstSlot {
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
            relocs: Vector::<Reloc>::new(),
            cnt: Vector::<u32>::new(),
            work: Vector::<u32>::new(),
        };
    }

    // The slots of `b` and the addresses they give, each instruction read a few times: whether a slot is
    // stored into with constants and read by loads alone or as a call's aggregate its callee only reads
    // (`Sym.wargs`, `Sym.esc`; not `bad`).
    fn scan(self: &mut Self, pk: &Package, b: &Body) bool {
        let n = b.insts.len();
        // A slot read at constant offsets alone became values (`lir::promote`): a table has an index, and a
        // call's argument stays a slot (taken as indexed here). Most bodies have no constant store into a
        // slot nor an indexed slot address: one look at each instruction tells; the slots' addresses and the
        // offsets kept for the passes below.
        let mut cstore = false;
        let mut indexed = false;
        let ptr = pk.ptr_bytes;
        self.adds.truncate(0);
        for i in 0..n {
            let t = b.insts[i];
            if t.op == O_STORE {
                cstore = cstore || self.known(b, t.b, ptr) && (t.a & (VPARAM | VFLAG)) == 0 && (b.insts[t.a as usize].op == O_SLOTADDR || b.insts[t.a as usize].op == O_PTRADD);
            } else if t.op == O_SLOTADDR || t.op == O_PTRADD {
                indexed = indexed || t.op == O_PTRADD && t.b != VNONE && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_SLOTADDR;
                self.adds.push(i as u32);
            } else if t.op == O_CALL {
                for k in 0..t.aux {
                    let v = b.pool[(t.c + k) as usize];
                    indexed = indexed || (v & (VPARAM | VFLAG)) == 0 && v != VNONE && b.insts[v as usize].op == O_SLOTADDR;
                }
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
            if t.op == O_CALL {
                // A whole slot as a fixed aggregate argument of a callee that neither writes its memory nor
                // keeps nor compares its address (`Sym.wargs`, `Sym.esc`: a replayed unit's record holds
                // them too), which the call passes as its address (`by_address`): a read.
                let sy = pk.syms[b.syms[t.a as usize] as usize];
                let ro = ~(sy.wargs | sy.esc);
                let nf = b.pool[t.b as usize + 1] & ~SIG_VARIADIC;
                for k in 0..t.aux {
                    let v = b.pool[(t.c + k) as usize];
                    if self.gives(v) && !(k < nf && k < 64 && (ro >> k as u64 & 1) != 0 && self.off[v as usize] == 0 && (b.pool[(t.b + 3 + k) as usize] & AGG) != 0 && self.by_address(
                        pk,
                        b,
                        v,
                    )) {
                        self.bad[self.slot[v as usize] as usize] = true;
                    }
                }
                continue;
            }
            lv::uses(b, t, &mut self.us);
            // A load's or an offset's address, a store's address (of a constant at a known offset, not
            // volatile): kept; any other read of a slot's address makes the slot stay.
            let mut keep = VNONE;
            if t.op == O_LOAD && (t.aux & MEM_VOLATILE) == 0 || t.op == O_PTRADD {
                keep = t.a;
            } else if t.op == O_STORE && (t.aux & MEM_VOLATILE) == 0 && self.gives(t.a) && self.off[t.a as usize] != OFF_VAR && self.known(
                b,
                t.b,
                ptr,
            ) {
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
        self.relocs.truncate(0);
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
            let ty = b.insts[t.b as usize].ty;
            if !(is_int(ty) && ty != T_I128 || ty == T_F32 || ty == T_F64 || ty == T_PTR) {
                return false;
            }
            let w = type_bytes(ty, ptr) as u64;
            let at = self.off[i].wrapping_add(((t.c as i32) as i64) as u64);
            if at >= size as u64 || at + w > size as u64 {
                return false;
            }
            let mut bits: u64 = 0;
            let mut sym = NONE;
            let mut add: i64 = 0;
            if !self.image(b, t.b, ptr, 0, &mut bits, &mut sym, &mut add) {
                return false;
            }
            if sym != NONE {
                self.relocs.push(Reloc { offset: at as u32, sym: sym, addend: add });
            }
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

    // Whether a call passes the slot whose address `v` is as that address, not as its bytes in registers
    // or on the stack: every one on wasm32 (`Package.arg_copy` 0), elsewhere one larger than both
    // `arg_copy` and two pointers.
    fn by_address(self: &Self, pk: &Package, b: &Body, v: Value) bool {
        let size = b.slots[self.slot[v as usize] as usize].size;
        return pk.arg_copy == 0 || size > pk.arg_copy && size > 2 * pk.ptr_bytes;
    }

    // Whether a store of value `v` writes known bytes (`image`).
    fn known(self: &Self, b: &Body, v: Value, ptr: u32) bool {
        let mut bits: u64 = 0;
        let mut sym = NONE;
        let mut add: i64 = 0;
        return self.image(b, v, ptr, 0, &mut bits, &mut sym, &mut add);
    }

    // The bytes value `v` holds (`bits`), `depth` of at most 3 steps down: a constant; a symbol's address
    // (bits 0, the relocation of `sym` plus `add` at its first byte), that address as an integer of its
    // width, zero-extended, or the `or` of one of those and a constant clear over the address's bytes.
    // Whether they are known.
    fn image(self: &Self, b: &Body, v: Value, ptr: u32, depth: u32, bits: &mut u64, sym: &mut u32, add: &mut i64) bool {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || depth > 3 {
            return false;
        }
        let t = b.insts[v as usize];
        if t.op == O_ICONST || t.op == O_FCONST {
            *bits = t.b as u64 << 32 | t.a as u64;
            return true;
        }
        if t.op == O_SYMADDR {
            *bits = 0;
            *sym = b.syms[t.a as usize];
            *add = t.b as i32;
            return true;
        }
        if t.op == O_PTRTOINT && type_bytes(t.ty, ptr) == ptr || t.op == O_ZEXT {
            if !self.image(b, t.a, ptr, depth + 1, bits, sym, add) {
                return false;
            }
            let w = type_bytes(b.insts[t.a as usize].ty, ptr);
            if w < 8 {
                *bits = *bits & (1u64 << 8 * w as u64) - 1;
            }
            return true;
        }
        if t.op == O_OR {
            let mut x: u64 = 0;
            let mut y: u64 = 0;
            let mut sx = NONE;
            let mut sy = NONE;
            if !self.image(b, t.a, ptr, depth + 1, &mut x, &mut sx, add) || !self.image(
                b,
                t.b,
                ptr,
                depth + 1,
                &mut y,
                &mut sy,
                add,
            ) || sx != NONE && sy != NONE {
                return false;
            }
            let m = if ptr >= 8 {
                u64::MAX
            } else {
                (1u64 << 8 * ptr as u64) - 1
            };
            if sx != NONE && (y & m) != 0 || sy != NONE && (x & m) != 0 {
                return false;
            }
            *bits = x | y;
            *sym = ast::pick(sx != NONE, sx, sy);
            return true;
        }
        return false;
    }

    // The values the removed stores wrote (`work`) that nothing else reads become unused constants, and so
    // do the values only those read, down their chains.
    fn drop_unused(self: &mut Self, b: &mut Body) {
        let n = b.insts.len();
        fill(&mut self.cnt, n, 0);
        for i in 0..n {
            let t = b.insts[i];
            if t.op >= O_JMP && t.op <= O_SWITCH {
                b.succ_edges(t, &mut self.es);
                for q in 0..self.es.len() {
                    for x in 0..b.edge_nargs(self.es[q]) {
                        let v = b.edge_arg(self.es[q], x);
                        if (v & (VPARAM | VFLAG)) == 0 && v != VNONE {
                            self.cnt[v as usize] += 1;
                        }
                    }
                }
            }
            lv::uses(b, t, &mut self.us);
            for q in 0..self.us.len() {
                let v = self.us[q];
                if (v & (VPARAM | VFLAG)) == 0 && v != VNONE {
                    self.cnt[v as usize] += 1;
                }
            }
        }
        // Each value enters the list once: when its reads reach 0.
        while self.work.len() != 0 {
            let v = self.work.pop().unwrap();
            if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || self.cnt[v as usize] != 0 {
                continue;
            }
            let t = b.insts[v as usize];
            if t.op != O_OR && t.op != O_ZEXT && t.op != O_PTRTOINT && t.op != O_SYMADDR {
                continue;
            }
            b.insts[v as usize] = iconst(T_I8, 0);
            if t.op != O_SYMADDR {
                self.read_less(t.a);
            }
            if t.op == O_OR {
                self.read_less(t.b);
            }
        }
    }

    // One read of value `v` less (`drop_unused`): listed when none is left.
    fn read_less(self: &mut Self, v: Value) {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE {
            return;
        }
        self.cnt[v as usize] -= 1;
        if self.cnt[v as usize] == 0 {
            self.work.push(v);
        }
    }
}

// The direct calls of the bodies (`Run::new`): per body, its range of `callee` (in instruction order, then the
// functions of the read-only tables it names; a held body's from its record). Per call, whether `effects`
// counts it (`live`: one of a body below `held` outside a block that ends the program), and its range of
// `arg` and `bits`: for each of its first 64
// arguments, `q | root << 8` and the parameters the root takes (`root`).
struct Calls {
    pub(package) at: Vector<u32>,
    pub(package) callee: Vector<u32>,
    pub(package) live: Vector<bool>,
    pub(package) arg_at: Vector<u32>,
    pub(package) arg: Vector<u32>,
    pub(package) bits: Vector<u64>,
}

// `Calls` of `bodies`: the bodies below `held` by chunks on worker threads unless `jobs` is 1, then in
// body order into lists of their exact sizes.
fn calls_of(p: &Package, bodies: &Vector<Body>, held: u32, cs: &mut Calls, jobs: u32) {
    let hd = &p.held;
    let mut bounds = Vector::<u32>::new();
    chunk_bounds(bodies, held as usize, &mut bounds);
    let mut chunks = Vector::<CallChunk>::with_capacity(bounds.len());
    for c in 0..bounds.len() {
        let lo = if c == 0 {
            0usize
        } else {
            bounds[c - 1] as usize
        };
        chunks.push(CallChunk::new(lo, bounds[c] as usize));
    }
    let mut cx = CallCtx { p: p, bodies: bodies, chunks: chunks.as_mut_ptr() };
    par::chunks(chunks.len(), jobs, call_chunk, (&mut cx) as *mut CallCtx);
    // The lists at once, at their sizes: a held body's calls, then the chunks'.
    let (mut nc, mut na) = (1usize, 1usize);
    for k in held as usize..bodies.len() {
        let h = k - held as usize;
        nc += (hd.at[h + 1] - hd.at[h]) as usize;
    }
    for c in 0..chunks.len() {
        nc += chunks[c].c.callee.len();
        na += chunks[c].c.arg.len();
    }
    cs.callee.reserve_exact(nc);
    cs.live.reserve_exact(nc);
    cs.arg_at.reserve_exact(nc);
    cs.arg.reserve_exact(na);
    cs.bits.reserve_exact(na);
    let mut c: usize = 0;
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
        while k >= chunks[c].hi {
            c += 1;
        }
        let ch = &chunks[c];
        let i = k - ch.lo;
        let (c0, c1) = (ch.c.at[i] as usize, ch.c.at[i + 1] as usize);
        let (a0, a1) = (ch.aat[i], ch.aat[i + 1]);
        let base = cs.arg.len() as u32;
        cs.callee.extend_from_slice(ch.c.callee[c0..c1]);
        cs.live.extend_from_slice(ch.c.live[c0..c1]);
        for x in c0..c1 {
            cs.arg_at.push(ch.c.arg_at[x] - a0 + base);
        }
        cs.arg.extend_from_slice(ch.c.arg[a0 as usize..a1 as usize]);
        cs.bits.extend_from_slice(ch.c.bits[a0 as usize..a1 as usize]);
    }
    cs.at.push(cs.callee.len() as u32);
    cs.arg_at.push(cs.arg.len() as u32);
}

// One chunk of `calls_of`: bodies `lo..hi`, their calls as `Calls` gives them (`c.at` per body), each body's
// first argument (`aat`).
struct CallChunk {
    lo: usize,
    hi: usize,
    c: Calls,
    aat: Vector<u32>,
}

extend CallChunk {
    fn new(lo: usize, hi: usize) CallChunk {
        return CallChunk {
            lo: lo,
            hi: hi,
            c: Calls {
                at: Vector::<u32>::with_capacity(hi - lo + 1),
                callee: Vector::<u32>::new(),
                live: Vector::<bool>::new(),
                arg_at: Vector::<u32>::new(),
                arg: Vector::<u32>::new(),
                bits: Vector::<u64>::new(),
            },
            aat: Vector::<u32>::with_capacity(hi - lo + 1),
        };
    }
}

// The package and bodies the chunks read, and the chunks, each written by its own task alone.
struct CallCtx {
    p: *const Package,
    bodies: *const Vector<Body>,
    chunks: *mut CallChunk,
}

fn call_chunk(ctx: *mut void, ci: usize) {
    let x = unsafe &*(ctx as *const CallCtx);
    let p = unsafe &*x.p;
    let bodies = unsafe &*x.bodies;
    let ch = unsafe &mut *(x.chunks + ci);
    let cs = &mut ch.c;
    let mut ends = Vector::<bool>::new();
    for k in ch.lo..ch.hi {
        cs.at.push(cs.callee.len() as u32);
        ch.aat.push(cs.arg.len() as u32);
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
        // The functions of the read-only tables it names (a conformance's methods), which `effects` does
        // not count: a call through one becomes direct when the walk reads the table (`fold_ptr`), and the
        // body waits for them to inline it (`Run::direct_known`).
        for x in 0..b.syms.len() {
            let sy = p.syms[b.syms[x] as usize];
            if sy.kind != SK_DATA || sy.def == NONE || !p.data[sy.def as usize].readonly {
                continue;
            }
            let d = p.data[sy.def as usize];
            for r in d.relocs..d.relocs + d.nrelocs {
                let f = p.syms[p.relocs[r as usize].sym as usize];
                if f.kind == SK_FUNC && f.def != NONE {
                    cs.callee.push(f.def);
                    cs.live.push(false);
                    cs.arg_at.push(cs.arg.len() as u32);
                }
            }
        }
    }
    cs.at.push(cs.callee.len() as u32);
    ch.aat.push(cs.arg.len() as u32);
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
    jobs: u32,
) Vector<u8> {
    let n = bodies.len();
    let held = ast::pick(p.held.body == NONE, n, p.held.body as usize);
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
    // The bodies' own facts by chunks of about equal instructions, on worker threads (`par::chunks`), then
    // in body order: each chunk's lists are what the bodies append in order.
    let mut bounds = Vector::<u32>::new();
    chunk_bounds(bodies, held, &mut bounds);
    let mut chunks = Vector::<FxChunk>::with_capacity(bounds.len());
    for c in 0..bounds.len() {
        let lo = if c == 0 {
            0usize
        } else {
            bounds[c - 1] as usize
        };
        chunks.push(FxChunk::new(lo, bounds[c] as usize));
    }
    let mut cx = FxCtx { p: p, bodies: bodies, chunks: chunks.as_mut_ptr() };
    par::chunks(chunks.len(), jobs, fx_chunk, (&mut cx) as *mut FxCtx);
    let mut c: usize = 0;
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
        while k >= chunks[c].hi {
            c += 1;
        }
        let ch = &chunks[c];
        let i = k - ch.lo;
        fx.push(ch.fx[i]);
        wargs.push(ch.w[i]);
        at.push(pass.len() as u32);
        pass.extend_from_slice(ch.pass[ch.at[i] as usize..ch.at[i + 1] as usize]);
        poff.extend_from_slice(ch.poff[ch.at[i] as usize..ch.at[i + 1] as usize]);
        sp.extend_from_slice(ch.sp[ch.sp_at[i] as usize..ch.sp_at[i + 1] as usize]);
        esc.push(ch.esc[i]);
    }
    sp_at.push(sp.len() as u32);
    at.push(pass.len() as u32);
    // Per body, the bodies below `held` whose flags read its own: their live calls of it (`rc`), their
    // passes to its parameters (`rp`).
    let mut rc_at = Vector::<u32>::new();
    let mut rc = Vector::<u32>::new();
    let mut rp_at = Vector::<u32>::new();
    let mut rp = Vector::<u32>::new();
    fill(&mut rc_at, n + 1, 0);
    fill(&mut rp_at, n + 1, 0);
    for k in 0..held {
        for x in cs.at[k]..cs.at[k + 1] {
            if cs.live[x as usize] {
                rc_at[cs.callee[x as usize] as usize + 1] += 1;
            }
        }
        for x in at[k]..at[k + 1] {
            rp_at[(pass[x as usize] >> 32) as usize + 1] += 1;
        }
    }
    for c in 0..n {
        rc_at[c + 1] += rc_at[c];
        rp_at[c + 1] += rp_at[c];
    }
    fill(&mut rc, rc_at[n] as usize, 0);
    fill(&mut rp, rp_at[n] as usize, 0);
    let mut put = Vector::<u32>::new();
    put.extend_copy(&rc_at);
    let mut putp = Vector::<u32>::new();
    putp.extend_copy(&rp_at);
    for k in 0..held {
        for x in cs.at[k]..cs.at[k + 1] {
            if cs.live[x as usize] {
                let c = cs.callee[x as usize] as usize;
                rc[put[c] as usize] = k as u32;
                put[c] += 1;
            }
        }
        for x in at[k]..at[k + 1] {
            let c = (pass[x as usize] >> 32) as usize;
            rp[putp[c] as usize] = k as u32;
            putp[c] += 1;
        }
    }
    // The least fixed point by a worklist of the bodies whose callees' flags grew; the flags only grow, so
    // the result does not depend on the order.
    let mut queued = Vector::<bool>::new();
    fill(&mut queued, n, false);
    let mut work = Vector::<u32>::with_capacity(held);
    for k in 0..held {
        queued[held - 1 - k] = true;
        work.push((held - 1 - k) as u32);
    }
    // Each evaluation that changes a body adds one of its 3 flags, 64 written or 64 escaping parameters,
    // and queues each body that reads it once.
    let bound = held + 131 * (rc.len() + rp.len()) + 1;
    for _ in 0..bound {
        if work.len() == 0 {
            stalls(&mut fx, cs, &rc_at, &rc, held);
            spans(sp, sp_at, esc, &pass, &poff, &at, held);
            return fx;
        }
        let k = work.pop().unwrap() as usize;
        queued[k] = false;
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
            for y in rc_at[k]..rc_at[k + 1] {
                let d = rc[y as usize] as usize;
                if !queued[d] {
                    queued[d] = true;
                    work.push(d as u32);
                }
            }
            for y in rp_at[k]..rp_at[k + 1] {
                let d = rp[y as usize] as usize;
                if !queued[d] {
                    queued[d] = true;
                    work.push(d as u32);
                }
            }
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
// that come back are those whose own code does and each of whose calls' bodies does, from none up. Per
// body its live calls of bodies not known to come back (`left`); one that comes back takes one from each
// call of it (`rc[rc_at[c]..rc_at[c + 1]]`, a caller per live call).
fn stalls(fx: &mut Vector<u8>, cs: &Calls, rc_at: &Vector<u32>, rc: &Vector<u32>, held: usize) {
    let n = fx.len();
    let mut back = Vector::<bool>::with_capacity(n);
    for k in 0..n {
        back.push(k >= held && (fx[k] & FX_STALL) == 0);
    }
    let mut left = Vector::<u32>::new();
    fill(&mut left, held, 0);
    let mut work = Vector::<u32>::with_capacity(held);
    for k in 0..held {
        for x in cs.at[k]..cs.at[k + 1] {
            if cs.live[x as usize] && !back[cs.callee[x as usize] as usize] {
                left[k] += 1;
            }
        }
        if left[k] == 0 && (fx[k] & FX_STALL) == 0 {
            back[k] = true;
            work.push(k as u32);
        }
    }
    // Each body comes back once, and its callers' counts drop once per call.
    for _ in 0..held + 1 {
        if work.len() == 0 {
            break;
        }
        let c = work.pop().unwrap() as usize;
        for y in rc_at[c]..rc_at[c + 1] {
            let k = rc[y as usize] as usize;
            if back[k] || (fx[k] & FX_STALL) != 0 {
                continue;
            }
            left[k] -= 1;
            if left[k] == 0 {
                back[k] = true;
                work.push(k as u32);
            }
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
fn own_effects(p: &Package, b: &Body, w: &mut u64, fs: &mut FxScratch) u8 {
    let mut f: u8 = ast::pick(has_cycle(b, fs), FX_STALL, 0);
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

// The chunks the per-body passes of `Run::new` split the bodies into (`chunk_bounds`): a fixed count, so the
// chunks do not depend on the workers.
const BODY_CHUNKS: u64 = 64;

// Into `out`, the end of each chunk of bodies `0..held` of about equal instructions (`BODY_CHUNKS`).
fn chunk_bounds(bodies: &Vector<Body>, held: usize, out: &mut Vector<u32>) {
    out.truncate(0);
    let mut tot: u64 = 0;
    for k in 0..held {
        tot += bodies[k].insts.len() as u64;
    }
    let mut acc: u64 = 0;
    for k in 0..held {
        acc += bodies[k].insts.len() as u64;
        if k + 1 == held || acc * BODY_CHUNKS >= tot * (out.len() as u64 + 1) {
            out.push(k as u32 + 1);
        }
    }
}

// One chunk of `effects`' own facts: bodies `lo..hi`, per body its flags, written parameters and escaping
// parameters, and its passes (`pass`, `poff` from `at[i]`) and spans (`sp` from `sp_at[i]`), as `effects`
// appends them.
struct FxChunk {
    lo: usize,
    hi: usize,
    fx: Vector<u8>,
    w: Vector<u64>,
    esc: Vector<u64>,
    pass: Vector<u64>,
    poff: Vector<i64>,
    at: Vector<u32>,
    sp: Vector<u64>,
    sp_at: Vector<u32>,
}

extend FxChunk {
    fn new(lo: usize, hi: usize) FxChunk {
        return FxChunk {
            lo: lo,
            hi: hi,
            fx: Vector::<u8>::with_capacity(hi - lo),
            w: Vector::<u64>::with_capacity(hi - lo),
            esc: Vector::<u64>::with_capacity(hi - lo),
            pass: Vector::<u64>::new(),
            poff: Vector::<i64>::new(),
            at: Vector::<u32>::with_capacity(hi - lo + 1),
            sp: Vector::<u64>::new(),
            sp_at: Vector::<u32>::with_capacity(hi - lo + 1),
        };
    }
}

// The package and bodies the chunks read, and the chunks, each written by its own task alone.
struct FxCtx {
    p: *const Package,
    bodies: *const Vector<Body>,
    chunks: *mut FxChunk,
}

fn fx_chunk(ctx: *mut void, c: usize) {
    let x = unsafe &*(ctx as *const FxCtx);
    let p = unsafe &*x.p;
    let bodies = unsafe &*x.bodies;
    let ch = unsafe &mut *(x.chunks + c);
    let mut fs = FxScratch::new();
    for k in ch.lo..ch.hi {
        ch.sp_at.push(ch.sp.len() as u32);
        let mut w: u64 = 0;
        ch.fx.push(own_effects(p, &bodies[k], &mut w, &mut fs));
        ch.w.push(w);
        ch.at.push(ch.pass.len() as u32);
        let np = (bodies[k].blocks[0].param_len as u64).min(64);
        ch.esc.push(
            own_escapes(p, &bodies[k], &mut ch.pass, &mut ch.poff, &mut ch.sp, &mut fs) | if np < 64 {
                ~0u64 << np
            } else {
                0u64
            },
        );
    }
    ch.sp_at.push(ch.sp.len() as u32);
    ch.at.push(ch.pass.len() as u32);
}

// The bodies of a `Run::new` shape test chunk.
const SHAPE_CHUNK: usize = 256;

// What the shape test chunks read (per body its function's symbol, NONE for none), and per body its
// result, each written by its chunk alone.
struct ShapeCtx {
    p: *const Package,
    bodies: *const Vector<Body>,
    owner: *const u32,
    held: usize,
    shape: *mut bool,
}

fn shape_chunk(ctx: *mut void, c: usize) {
    let x = unsafe &*(ctx as *const ShapeCtx);
    let p = unsafe &*x.p;
    let bodies = unsafe &*x.bodies;
    for k in c * SHAPE_CHUNK..(c * SHAPE_CHUNK + SHAPE_CHUNK).min(x.held) {
        let s = unsafe x.owner[k];
        if s != NONE {
            unsafe x.shape[k] = il::shape_ok(p, s, &bodies[k]);
        }
    }
}

// `effects`'s scratch, reused from body to body.
struct FxScratch {
    state: Vector<u8>, // `has_cycle`
    path: Vector<u64>,
    es: Vector<u32>,
    der: Vector<u32>, // `own_escapes`
    doff: Vector<i64>,
    uses: Vector<Value>,
    edges: Vector<u32>,
}

extend FxScratch {
    fn new() FxScratch {
        return FxScratch {
            state: Vector::<u8>::new(),
            path: Vector::<u64>::new(),
            es: Vector::<u32>::new(),
            der: Vector::<u32>::new(),
            doff: Vector::<i64>::new(),
            uses: Vector::<Value>::new(),
            edges: Vector::<u32>::new(),
        };
    }
}

// Whether a block of `b` reaches itself (a loop): a depth-first walk that meets a block on its path.
fn has_cycle(b: &Body, fs: &mut FxScratch) bool {
    let nb = b.blocks.len();
    // Per block: 0 unseen, 1 on the walk's path, 2 done.
    fill(&mut fs.state, nb, 0);
    // The path: a block and its next edge to take, each block on it once.
    fs.path.truncate(0);
    fs.state[0] = 1;
    fs.path.push(0);
    // Each step takes an edge or leaves a block: at most the edges and blocks.
    while fs.path.len() != 0 {
        let top = fs.path[fs.path.len() - 1];
        let k = (top & 0xFFFFFFFF) as u32;
        let e = (top >> 32) as u32;
        let bk = b.blocks[k as usize];
        b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut fs.es);
        if e as usize >= fs.es.len() {
            fs.state[k as usize] = 2;
            let _ = fs.path.pop();
            continue;
        }
        let at = fs.path.len() - 1;
        fs.path[at] = e as u64 + 1 << 32 | k as u64;
        let s = b.edge_target(fs.es[e as usize]);
        if fs.state[s as usize] == 1 {
            return true;
        }
        if fs.state[s as usize] == 0 {
            fs.state[s as usize] = 1;
            fs.path.push(s);
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
fn own_escapes(
    p: &Package,
    b: &Body,
    pass: &mut Vector<u64>,
    poff: &mut Vector<i64>,
    span: &mut Vector<u64>,
    fs: &mut FxScratch,
) u64 {
    let ni = b.insts.len();
    // Per instruction, the parameter its value is address arithmetic on (NONE: none) and the constant
    // offset (`doff`, OFF_ANY: not constant or past SPAN_MAX). Each pass sets at least one more or ends: at
    // most `ni + 1`.
    fill(&mut fs.der, ni, NONE);
    fill(&mut fs.doff, ni, OFF_ANY);
    for _ in 0..ni + 1 {
        let mut changed = false;
        for i in 0..ni {
            let t = b.insts[i];
            if t.op == O_PTRADD && fs.der[i] == NONE {
                let k = param_of(b, &fs.der, t.a);
                if k != NONE {
                    fs.der[i] = k;
                    let o = off_of(&fs.doff, t.a);
                    let n = if t.b == VNONE {
                        Option::<u64>::Some(0)
                    } else {
                        int_bits(b, t.b)
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
                            fs.doff[i] = d;
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
                    let x = param_of(b, &fs.der, b.pool[(t.c + q) as usize]);
                    if x == NONE {
                        continue;
                    }
                    if q < 64 {
                        pass.push(c as u64 << 32 | q as u64 << 8 | x as u64);
                        poff.push(off_of(&fs.doff, b.pool[(t.c + q) as usize]));
                    } else {
                        out |= 1u64 << x as u64;
                    }
                }
                continue;
            }
            lv::uses(b, t, &mut fs.uses);
            if is_terminator(t.op) {
                b.succ_edges(t, &mut fs.edges);
                for d in 0..fs.edges.len() {
                    for a in 0..b.edge_nargs(fs.edges[d]) {
                        fs.uses.push(b.edge_arg(fs.edges[d], a));
                    }
                }
            }
            for u in 0..fs.uses.len() {
                let v = fs.uses[u];
                let x = param_of(b, &fs.der, v);
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
                let o = off_of(&fs.doff, v);
                let (lo, n) = if t.op == O_LOAD {
                    ((t.c as i32) as i64, type_bytes(t.ty, p.ptr_bytes) as i64)
                } else if t.op == O_STORE {
                    ((t.c as i32) as i64, type_bytes(b.type_of(t.b), p.ptr_bytes) as i64)
                } else {
                    let c = int_bits(b, t.c);
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
// `root`'s work list: each of its at most FRAME_DEPTH steps takes one value and puts back at most two.
const ROOT_WORK: usize = FRAME_DEPTH as usize + 1;

fn root(b: &Body, v: Value, w: &mut u64) u8 {
    let mut work = StaticVector::<Value, ROOT_WORK>::new();
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
    return ast::pick(sy.kind == SK_FUNC && sy.def != NONE, sy.def, NONE);
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
    // The unsigned minimum of two values is at most each (`umin_of`): `min(x, y) <= y`, `y < min(x, y)`.
    if t.aux == C_ULE && umin_of(b, t.a, t.b) || t.aux == C_UGE && umin_of(b, t.b, t.a) {
        return Some(true);
    }
    if t.aux == C_UGT && umin_of(b, t.a, t.b) || t.aux == C_ULT && umin_of(b, t.b, t.a) {
        return Some(false);
    }
    let ty = b.type_of(t.a);
    let ka = int_bits(b, t.a);
    let kb = int_bits(b, t.b);
    if !is_int(ty) || ty == T_I128 || ka.is_some() == kb.is_some() {
        return None;
    }
    let all = mask_of(type_bits(ty, ptr));
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

// Whether value `v` of `b` is the unsigned minimum of `w` and another value: `select(x <u y, x, y)` (or
// `<=u`) with `w` one of `x` and `y`.
const fn umin_of(b: &Body, v: Value, w: Value) bool {
    if (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_SELECT {
        return false;
    }
    let s = b.insts[v as usize];
    if (s.a & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let c = b.insts[s.a as usize];
    return c.op == O_ICMP && (c.aux == C_ULT || c.aux == C_ULE) && c.a == s.b && c.b == s.c && (w == s.b || w == s.c);
}

// The largest length load `t` of `b` (pointers `ptr` bytes) reads when it reads a view parameter's length
// (`REF_INNER`, its element's bytes in REF_BYTES): no object is larger than `isize::MAX` bytes. None else.
const fn view_len_max(b: &Body, t: Inst, ptr: u32) Option<u64> {
    if t.op != O_LOAD || t.c != ptr || !is_int(t.ty) || type_bytes(t.ty, ptr) != ptr || (t.aux & MEM_VOLATILE) != 0 {
        return None;
    }
    let q = entry_param(b, t.a);
    if q == NONE || q as usize >= b.refs.len() || (b.refs[q as usize] & REF_INNER) == 0 || (b.refs[q as usize] & REF_BYTES) == 0 {
        return None;
    }
    return Some((mask_of(type_bits(t.ty, ptr)) >> 1) / (b.refs[q as usize] & REF_BYTES) as u64);
}

// The largest unsigned value integer `v` of `b` (pointers `ptr` bytes) can hold, from its form up to `depth`
// instructions deep: a constant, a mask, a zero extension, a select, a bit count, a quotient or a remainder,
// a right shift, a view parameter's length; else its type's largest.
const fn umax_of(b: &Body, v: Value, ptr: u32, depth: u32) u64 {
    let all = mask_of(type_bits(b.type_of(v), ptr));
    let k = int_bits(b, v);
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
        return ast::pick(x < y, x, y);
    }
    if t.op == O_ZEXT {
        return umax_of(b, t.a, ptr, depth - 1);
    }
    if t.op == O_SELECT {
        let x = umax_of(b, t.b, ptr, depth - 1);
        let y = umax_of(b, t.c, ptr, depth - 1);
        return ast::pick(x > y, x, y);
    }
    if t.op == O_CLZ || t.op == O_CTZ || t.op == O_POPCNT {
        return type_bits(b.type_of(t.a), ptr);
    }
    if t.op == O_UDIV || t.op == O_LSHR {
        let x = umax_of(b, t.a, ptr, depth - 1);
        let s = int_bits(b, t.b);
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
    if let Some(n) = view_len_max(b, t, ptr) {
        return n;
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
    let n = int_bits(b, s.c);
    let f = int_bits(b, s.b);
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
    if t.op != O_ICMP || t.aux != ast::pick(eq, C_EQ, C_NE) || !is_int(ty) || ty == T_PTR || ty == T_I128 || int_bits(
        b,
        t.b,
    ) != Some(0u64) {
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
    if t.op != O_ICMP || t.aux != ast::pick(ne, C_NE, C_EQ) || int_bits(b, t.b) != Some(0u64) || !is_op(b, t.a, O_AND) {
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
    return ast::pick(
        s.a == x && (s.op == O_ADD && int_bits(b, s.b) == Some(ones) || s.op == O_SUB && int_bits(b, s.b) == Some(1u64)),
        d,
        VNONE,
    );
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
    return ast::pick(
        (s & VPARAM) == 0 || s == VNONE || (s & ~VPARAM) < e || ((s & ~VPARAM) - e) as usize >= b.refs.len() || (b.refs[((s & ~VPARAM) - e) as usize] & REF_INNER) == 0,
        VNONE,
        s,
    );
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
    return cc == C_ULT && len(k.b) || cc == C_UGT && len(k.a) || cc == C_NE && (len(k.a) && int_bits(b, k.b) == Some(
        0u64,
    ) || len(k.b) && int_bits(b, k.a) == Some(0u64));
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
            let k = int_bits(b, t.b);
            return t.a == x && k.is_some() && (k.unwrap() == 0 && (t.aux == C_EQ || t.aux == C_ULE) || k.unwrap() == 1 && t.aux == C_ULT);
        }
        if t.op == O_SUB && int_bits(b, t.a) == Some(0u64) {
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
        let x = int_bits(b, t.a);
        if x.is_none() {
            return VNONE;
        }
        let bits = type_bits(b.type_of(t.a), 8);
        let l = if t.op == O_SEXT {
            sign_extend(x.unwrap(), bits) as u64
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
            return ast::pick(
                zero && (t.op == O_ADD || t.op == O_SUB || t.op == O_OR || t.op == O_XOR || t.op == O_SHL || t.op == O_LSHR || t.op == O_ASHR) || yl == 1 && yh == 0 && t.op == O_MUL,
                t.a,
                VNONE,
            );
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
    return ast::pick((t.op == O_ZEXT || t.op == O_SEXT) && b.type_of(t.a) == ty, t.a, VNONE);
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
    let code = (core::OP_SIMD + ast::pick(max, core::SIMD_MAX, core::SIMD_MIN) as u32) as u16 | ast::pick(
        signed,
        VOP_SIGNED,
        0,
    );
    let ops = [t.b, t.c];
    let at = b.pool_list(ops[0..2]);
    b.insts[i as usize] = Inst { op: O_VOP, ty: t.ty, aux: code, a: at, b: 2, c: VNONE };
    return true;
}

// Vector instruction `i` of `b` (integer lanes), in place: a sum with a negation a difference, a
// difference with one a sum; a sum, difference, product, `and`, `or` or `xor` of two constants
// (`vec_words`) a wide constant, lane by lane, wrapping.
fn simplify_vec(b: &mut Body, i: u32) {
    let t = b.insts[i as usize];
    let lt = lane_type(t.ty);
    if !is_int(lt) {
        return;
    }
    if (t.op == O_ADD || t.op == O_SUB) && is_op(b, t.b, O_NEG) {
        let o = ast::pick(t.op == O_ADD, O_SUB, O_ADD);
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
    let lanewise = t.op == O_ADD || t.op == O_SUB || t.op == O_MUL || t.op == O_AND || t.op == O_OR || t.op == O_XOR;
    if lanewise && nb % 8 == 0 && vec_words(b, t.a, t.ty, &mut x) && vec_words(b, t.b, t.ty, &mut y) {
        let at = b.words.len() as u32;
        let bits = 8 * type_bytes(lt, 8);
        let m = if bits == 64 {
            ~0u64
        } else {
            (1u64 << bits as u64) - 1
        };
        for q in 0..nb / 8 {
            let mut w: u64 = 0;
            // Each step computes one lane of the word.
            for l in 0..64 / bits {
                let sh = (l * bits) as u64;
                let (p, r) = (x[q as usize] >> sh & m, y[q as usize] >> sh & m);
                let v = if t.op == O_ADD {
                    p.wrapping_add(r)
                } else if t.op == O_SUB {
                    p.wrapping_sub(r)
                } else if t.op == O_MUL {
                    p.wrapping_mul(r)
                } else if t.op == O_AND {
                    p & r
                } else if t.op == O_OR {
                    p | r
                } else {
                    p ^ r
                };
                w |= (v & m) << sh;
            }
            b.words.push(w);
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
        let c = int_bits(b, t.a);
        return c.is_some() && trunc_bits(c.unwrap(), bits) == k;
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
    let c = int_bits(b, t.a);
    if c.is_none() {
        return false;
    }
    let bits = 8 * type_bytes(lane_type(vt), 8);
    let mut w: u64 = 0;
    for l in 0..64 / bits {
        w |= trunc_bits(c.unwrap(), bits) << (l * bits) as u64;
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
        let c = int_bits(b, t.a);
        if c.is_some() {
            let bits = type_bits(t.ty, ptr);
            let x = trunc_bits(c.unwrap(), bits);
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
    if t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) && int_bits(b, t.b) == Some(0u64) && is_op(b, t.a, O_SELECT) {
        let s = b.insts[t.a as usize];
        let (p, when) = if int_bits(b, s.b) == Some(0u64) {
            (s.c, false)
        } else if int_bits(b, s.c) == Some(0u64) {
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
        let h = self_bound(b, t);
        if h.is_some() {
            b.insts[i as usize] = h.unwrap();
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
        let c = int_bits(b, t.a);
        if c.is_some() {
            return ast::pick(c.unwrap() != 0, t.b, t.c);
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
            let not = c.op == O_XOR && int_bits(b, c.b) == Some(1u64) && zero_one(b, c.a, ZO_DEPTH);
            if not || c.op == O_ICMP && (c.aux == C_EQ || c.aux == C_NE) && int_bits(b, c.b) == Some(0u64) && zero_one(
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
        let x = int_bits(b, t.b);
        let y = int_bits(b, t.c);
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
                op: ast::pick(wide, O_ZEXT, O_TRUNC),
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
            let op = ast::pick(t.c == t.a, O_AND, O_OR);
            let f = ast::pick(t.c == t.a, t.b, t.c);
            b.insts[i as usize] = Inst { op: op, ty: t.ty, aux: 0, a: t.a, b: f, c: VNONE };
            return VNONE;
        }
        // A choice between the two sides of an equality on it is one side: `x != y ? x : y` is `x`.
        if (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_ICMP {
            let ci = b.insts[t.a as usize];
            if (ci.aux == C_EQ || ci.aux == C_NE) && (t.b == ci.a && t.c == ci.b || t.b == ci.b && t.c == ci.a) {
                return ast::pick(ci.aux == C_NE, t.b, t.c);
            }
        }
        return ast::pick(t.b == t.c, t.b, VNONE);
    }
    if t.op == O_PTRADD {
        // A slot's address keeps its index: a constant offset past the slot in a path that never runs
        // would fail the verifier's check of slot accesses.
        let ix = int_bits(b, t.b);
        if ix.is_some() && !slot_based(b, t.a) {
            // In 128 bits: a constant index times the scale may not fit 64.
            let off = (t.c as i32) as i128 + sign_extend(ix.unwrap(), type_bits(b.type_of(t.b), ptr)) as i128 * scale_of(
                t,
            );
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
                int_bits(b, b.insts[x.a as usize].b)
            } else {
                Option::<u64>::None
            };
            let k = if x.op == O_ADD || x.op == O_SUB {
                int_bits(b, x.b)
            } else if low.is_some() && low.unwrap() < 64 && int_bits(b, x.b).is_some() && int_bits(b, x.b).unwrap() < 1u64 << low.unwrap() {
                int_bits(b, x.b)
            } else {
                Option::<u64>::None
            };
            if k.is_some() {
                let kv = sign_extend(k.unwrap(), ptr * 8);
                // In 128 bits: the constant times the scale may not fit 64.
                let d = if x.op == O_SUB {
                    0i128 - kv
                } else {
                    kv as i128
                };
                let off = (t.c as i32) as i128 + d * scale_of(t);
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
                int_bits(b, x2.b)
            } else if x2.op == O_SHL && (x2.b & (VPARAM | VFLAG)) == 0 && b.insts[x2.b as usize].op == O_ICONST && int_bits(
                b,
                x2.b,
            ).unwrap() < 16 {
                Option::<u64>::Some(1u64 << int_bits(b, x2.b).unwrap())
            } else {
                Option::<u64>::None
            };
            if f.is_some() && f.unwrap() != 0 && f.unwrap() <= PTR_SCALE as u64 && scale_of(t) as u64 * f.unwrap() <= PTR_SCALE as u64 {
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
        // The address a reference takes of a pointer (`PTR_NONNULL`, `&*p`) says the pointer is not null
        // where it is made: it stays unless the pointer says so too (`nonnull`).
        let fact = (t.aux & PTR_NONNULL) != 0 && !nonnull(b, t.a, pk.ptr_bytes);
        return ast::pick(t.b == VNONE && t.c == 0 && !fact, t.a, VNONE);
    }
    if t.op == O_ICMP {
        let ca = int_bits(b, t.a);
        let cb = int_bits(b, t.b);
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
            let kk = int_bits(b, c.b).unwrap();
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
            if int_bits(b, c.b).unwrap() == 0 && (c.aux == C_ULT || c.aux == C_UGE) {
                b.insts[i as usize] = iconst(t.ty, (c.aux == C_UGE) as u64);
                return VNONE;
            }
            if int_bits(b, c.b).unwrap() == 0 && (c.aux == C_UGT || c.aux == C_ULE) {
                c.aux = ast::pick(c.aux == C_UGT, C_NE, C_EQ);
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
        let one: u64 = ast::pick(t.ty == T_F32, 0x3F800000, 0x3FF0000000000000);
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
                op: ast::pick(wider, O_TRUNC, w.op),
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
        let x = int_bits(b, t.a);
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
    if (op == O_ADD || op == O_MUL || op == O_AND || op == O_OR || op == O_XOR) && int_bits(b, t.a).is_some() && int_bits(
        b,
        t.b,
    ).is_none() {
        let x = t.a;
        t.a = t.b;
        t.b = x;
        b.insts[i as usize] = t;
    }
    let ca = int_bits(b, t.a);
    let cb = if op == O_NEG || op == O_NOT {
        Option::<u64>::Some(0)
    } else {
        int_bits(b, t.b)
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
    let ones = trunc_bits(0xFFFFFFFFFFFFFFFF, type_bits(t.ty, ptr));
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
            let o = ast::pick(op == O_ADD, O_SUB, O_ADD);
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
            let k = int_bits(b, y);
            b.insts[i as usize] = if k.is_some() {
                iconst(t.ty, trunc_bits(k.unwrap().wrapping_neg(), type_bits(t.ty, ptr)))
            } else {
                Inst { op: O_NEG, ty: t.ty, aux: 0, a: y, b: VNONE, c: VNONE }
            };
            return VNONE;
        }
    }
    return cancel(b, t);
}

// The operand a sum or difference `t` leaves when one of its terms cancels: `(x + y) - x` is `y`,
// `(x - y) + y` is `x`, also of the wrapped value of a checked sum or difference; VNONE when none does.
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
    let (aa, as_) = (a.op == O_ADD || a.op == O_ADDO, a.op == O_SUB || a.op == O_SUBO);
    if t.op == O_SUB && aa {
        if same_term(b, a.a, t.b) {
            return a.b;
        }
        if same_term(b, a.b, t.b) {
            return a.a;
        }
    }
    if t.op == O_ADD && as_ && same_term(b, a.b, t.b) {
        return a.a;
    }
    return ast::pick(t.op == O_ADD && (c.op == O_SUB || c.op == O_SUBO) && same_term(b, c.b, t.a), c.a, VNONE);
}

// Whether `h` is at most half of `a`: `a >> c` for a constant `c` from 1 below the width, or `a / k` for
// a constant `k` of at least 2. Then `a - h` does not wrap and is at least `h`.
fn half_of(b: &Body, h: Value, a: Value) bool {
    if !is_op(b, h, O_LSHR) && !is_op(b, h, O_UDIV) {
        return false;
    }
    let t = b.insts[h as usize];
    let k = int_bits(b, t.b);
    let w = type_bits(t.ty, 8) as u64;
    return t.a == a && k.is_some() && !is_vec(t.ty) && (t.op == O_LSHR && k.unwrap() != 0 && k.unwrap() < w || t.op == O_UDIV && k.unwrap() >= 2);
}

// The values `x` is at most the largest of, by its form, in `out` (their count; 0: none known): a select
// whose arms are each 0, a value, or a difference `p - q` the arm's condition keeps from wrapping (`q <=u
// p`, so at most `p`: `abs_diff`, `saturating_sub`); a midpoint `(a & b) + ((a ^ b) >> 1)`, at most the
// larger of `a` and `b` (`midpoint`).
fn max_parts(b: &Body, x: Value, out: &mut [Value; 2]) u32 {
    if x == VNONE || (x & (VPARAM | VFLAG)) != 0 || is_vec(b.type_of(x)) {
        return 0;
    }
    let t = b.insts[x as usize];
    if t.op == O_ADD && is_op(b, t.a, O_AND) && is_op(b, t.b, O_LSHR) && int_bits(b, b.insts[t.b as usize].b) == Some(
        1u64,
    ) {
        let n = b.insts[t.a as usize];
        let s = b.insts[t.b as usize].a;
        if !is_op(b, s, O_XOR) {
            return 0;
        }
        let xo = b.insts[s as usize];
        if xo.a == n.a && xo.b == n.b || xo.a == n.b && xo.b == n.a {
            out[0] = n.a;
            out[1] = n.b;
            return 2;
        }
        return 0;
    }
    if t.op != O_SELECT {
        return 0;
    }
    let mut k: u32 = 0;
    for side in 0..2u32 {
        let v = ast::pick(side == 0, t.b, t.c);
        if int_bits(b, v) == Some(0u64) {
            continue; // 0 is at most any part
        }
        unsafe out[k as usize] = arm_top(b, t.a, v, side == 0);
        k += 1;
    }
    return k;
}

// The value select arm `v` is at most where condition `c` is `holds`: a difference `p - q` the condition
// keeps from wrapping (`q <=u p`): `p`; any other value: itself.
fn arm_top(b: &Body, c: Value, v: Value, holds: bool) Value {
    if !is_op(b, v, O_SUB) {
        return v;
    }
    let d = b.insts[v as usize];
    let (lo, hi, neg) = Opt::as_ult(b, c);
    if lo == VNONE {
        return v;
    }
    // `lo <u hi` holds on this arm, or `hi <=u lo` does.
    let lt = holds != neg;
    if lt && d.a == hi && d.b == lo || !lt && d.a == lo && d.b == hi {
        return d.a;
    }
    return v;
}

// `hi` when `a` is a midpoint `lo + ((hi - lo) >> c)` (`c` a constant from 1 below the width, or a quotient
// by a constant of at least 2), which is below `hi` wherever `lo <u hi` holds: `hi - lo` does not wrap and
// its part less than itself added to `lo` stays below `hi`; VNONE else.
fn mid_top(b: &Body, a: Value, lo: Value) Value {
    if !is_op(b, a, O_ADD) || is_vec(b.insts[a as usize].ty) {
        return VNONE;
    }
    let t = b.insts[a as usize];
    let s = ast::pick(t.a == lo, t.b, ast::pick(t.b == lo, t.a, VNONE));
    if s == VNONE || !is_op(b, s, O_LSHR) && !is_op(b, s, O_UDIV) {
        return VNONE;
    }
    let st = b.insts[s as usize];
    let k = int_bits(b, st.b);
    let w = type_bits(st.ty, 8) as u64;
    if k.is_none() || st.op == O_LSHR && (k.unwrap() == 0 || k.unwrap() >= w) || st.op == O_UDIV && k.unwrap() < 2 || !is_op(
        b,
        st.a,
        O_SUB,
    ) {
        return VNONE;
    }
    let d = b.insts[st.a as usize];
    return ast::pick(d.b == lo, d.a, VNONE);
}

// `(x, y)` when `a` is `(x + y) >> k` (`k` from 1) or `(x + y) / k` (`k` from 2), a midpoint where the
// sum does not wrap; `(VNONE, VNONE)` else.
fn half_sum(b: &Body, a: Value) (Value, Value) {
    let none = (VNONE, VNONE);
    if !is_op(b, a, O_LSHR) && !is_op(b, a, O_UDIV) || is_vec(b.insts[a as usize].ty) {
        return none;
    }
    let st = b.insts[a as usize];
    let k = int_bits(b, st.b);
    let w = type_bits(st.ty, 8) as u64;
    if k.is_none() || st.op == O_LSHR && (k.unwrap() == 0 || k.unwrap() >= w) || st.op == O_UDIV && k.unwrap() < 2 || !is_op(
        b,
        st.a,
        O_ADD,
    ) {
        return none;
    }
    let d = b.insts[st.a as usize];
    return (d.a, d.b);
}

// Whether `a` is a midpoint of `lo` and `hi` (`mid_top`).
fn midpoint(b: &Body, a: Value, lo: Value, hi: Value) bool {
    return hi != VNONE && mid_top(b, a, lo) == hi;
}

// Whether terms `x` and `y` of one sum are one value: the same, or equal constants not yet numbered one.
fn same_term(b: &Body, x: Value, y: Value) bool {
    if x == y {
        return true;
    }
    let k = int_bits(b, x);
    return k.is_some() && k == int_bits(b, y);
}

// Whether float bits `r` of type `ty` are a normal number: neither zero, subnormal, infinite nor NaN.
fn regular(ty: u8, r: u64) bool {
    let e = if ty == T_F64 {
        r >> 52 & 0x7FF
    } else {
        r >> 23 & 0xFF
    };
    let top = ast::pick(ty == T_F64, 0x7FFu64, 0xFFu64);
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
        x = ast::pick(d == 1, s.b, s.c);
    }
    return x;
}

// Whether comparison `t` with value `v` in place of its non-constant side (`left`: its first) folds into
// constants and comparisons (`Opt::icmp_select`): `v` is a constant, a three-way comparison, or a select of
// such values, `depth` selects deep.
fn cmp_arm(pk: &Package, b: &Body, t: Inst, left: bool, v: Value, depth: u32) bool {
    if int_bits(b, v).is_some() {
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
    let xu = trunc_bits(x, bits);
    let yu = trunc_bits(y, bits);
    let xs = sign_extend(x, bits);
    let ys = sign_extend(y, bits);
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
    let (v, k, code) = if int_bits(b, t.b).is_some() {
        (t.a, int_bits(b, t.b).unwrap(), t.aux)
    } else if int_bits(b, t.a).is_some() {
        (t.b, int_bits(b, t.a).unwrap(), mirror(t.aux))
    } else {
        return None;
    };
    let (x, y, signed) = three_way(b, v);
    if x == VNONE {
        return None;
    }
    let bits = type_bits(b.type_of(v), ptr);
    let m = width_mask(b.type_of(v), ptr);
    let ks = sign_extend(k, bits);
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
    let base = ast::pick(signed, C_SLT, C_ULT);
    let codes: [u16; 6] = [C_EQ, C_NE, base, base + 1, base + 2, base + 3];
    for q in 0..6 {
        if outcomes(codes[q]) == holds {
            return Some(Inst { op: O_ICMP, ty: t.ty, aux: codes[q], a: x, b: y, c: VNONE });
        }
    }
    return None;
}

// `at_most` follows at most AM_DEPTH operations.
const AM_DEPTH: u32 = 4;

// Whether integer value `v` of `b` is at most `x` (unsigned) by its form alone: `x` itself, or a right
// shift, a quotient, a remainder of such a value, an `and` with one, a minimum with one operand such a
// value (a select of the lesser of two values), a select of two such values, `depth` operations deep.
fn at_most(b: &Body, v: Value, x: Value, depth: u32) bool {
    if v == x {
        return true;
    }
    if depth == 0 || v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let t = b.insts[v as usize];
    if t.op == O_LSHR || t.op == O_UDIV || t.op == O_UREM {
        return at_most(b, t.a, x, depth - 1);
    }
    if t.op == O_AND {
        return at_most(b, t.a, x, depth - 1) || at_most(b, t.b, x, depth - 1);
    }
    if t.op != O_SELECT {
        return false;
    }
    let (u, w, neg) = Opt::as_ult(b, t.a);
    if u == t.b && w == t.c && !neg || u == t.c && w == t.b && neg {
        return at_most(b, t.b, x, depth - 1) || at_most(b, t.c, x, depth - 1);
    }
    return at_most(b, t.b, x, depth - 1) && at_most(b, t.c, x, depth - 1);
}

// Unsigned comparison `t` of a value with one its form keeps at most it (`at_most`): `x >> 1 >u x` and
// `x <u x / d` are false, `x & m <=u x` and `x >=u x % m` hold. None when the forms do not decide it.
fn self_bound(b: &Body, t: Inst) Option<Inst> {
    if t.aux < C_ULT || t.aux > C_UGE || is_vec(b.type_of(t.a)) {
        return None;
    }
    if at_most(b, t.a, t.b, AM_DEPTH) && (t.aux == C_ULE || t.aux == C_UGT) {
        return Some(iconst(t.ty, (t.aux == C_ULE) as u64));
    }
    if at_most(b, t.b, t.a, AM_DEPTH) && (t.aux == C_UGE || t.aux == C_ULT) {
        return Some(iconst(t.ty, (t.aux == C_UGE) as u64));
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
        return ~int_bits(b, v).unwrap() & m;
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
        let c = int_bits(b, t.b);
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
    if t.op == O_AND && int_bits(b, t.b).is_some() {
        return (t.a, int_bits(b, t.b).unwrap() & m);
    }
    let c = if t.op == O_SHL || t.op == O_LSHR {
        int_bits(b, t.b)
    } else {
        Option::<u64>::None
    };
    if c.is_some() && c.unwrap() < bits && (t.a & (VPARAM | VFLAG)) == 0 {
        let s = c.unwrap();
        let u = b.insts[t.a as usize];
        let back = ast::pick(t.op == O_SHL, O_LSHR, O_SHL);
        // `x >> s << s` and `x << s >> s`.
        if u.op == back && int_bits(b, u.b) == c && u.ty == ty {
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
                return (x, width_mask(int_type(n), ptr) << s & m);
            }
        }
        return (VNONE, 0);
    }
    let (x, lo, n) = piece_of(b, v, ptr);
    if x != VNONE && lo == 0 && b.type_of(x) == ty {
        return (x, width_mask(int_type(n), ptr));
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
    return ast::pick(mask == width_mask(t.ty, ptr), src, VNONE);
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
    let c = int_bits(b, t.b);
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
        return ast::pick((~z & m & ~dm) == 0, u.a, VNONE);
    }
    // `x << c >> c` and `x >> c << c`, which the `and` that follows folds when `x`'s other bits are 0.
    if (u.op == O_LSHR || u.op == O_SHL) && (u.a & (VPARAM | VFLAG)) == 0 {
        let w = b.insts[u.a as usize];
        let inner = ast::pick(u.op == O_LSHR, O_SHL, O_LSHR);
        if w.op == inner && w.ty == u.ty && int_bits(b, w.b) == c {
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

// `Opt::entry_expr` follows at most ENTRY_DEPTH operations.
const ENTRY_DEPTH: u32 = 3;

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
        return zero_one(b, t.a, depth - 1) && (zero_one(b, t.b, depth - 1) || t.op == O_XOR && int_bits(b, t.b) == Option::<
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
// constant it reads (a 16-byte vector's where the target computes them in registers, `Package.vector`).
// Whether instruction `i` folded.
fn fold_data(pk: &Package, b: &mut Body, i: u32) bool {
    let t = b.insts[i as usize];
    let vec = is_vec(t.ty) && type_bytes(t.ty, 8) == 16 && pk.vector >= 16;
    if (t.a & (VPARAM | VFLAG)) != 0 || is_vec(t.ty) && !vec || t.ty == T_PTR || t.ty == T_I128 || b.insts[t.a as usize].op != O_SYMADDR {
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
    if vec {
        let w = b.words.len() as u32;
        for h in 0..2i64 {
            let mut v: u64 = 0;
            for q in 0..8i64 {
                let at = off + 8 * h + q;
                if at < d.nbytes as i64 {
                    v |= pk.bytes[(d.bytes as i64 + at) as usize] as u64 << (8 * q) as u64;
                }
            }
            b.words.push(v);
        }
        b.insts[i as usize] = Inst { op: O_WCONST, ty: t.ty, aux: 0, a: w, b: 2, c: VNONE };
        return true;
    }
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

// Whether allocation call `t` (`ALLOC_FRESH`) is a `realloc` of a block that may exist (its pointer not the
// null constant), which frees that block: `dead_allocs` keeps it.
fn grows_block(pk: &Package, b: &Body, t: Inst) bool {
    let name = pk.spell(pk.syms[b.syms[t.a as usize] as usize].name);
    return name.ends_with("realloc") && int_bits(b, b.pool[t.c as usize]) != Some(0u64);
}

// The `Sym.alloc` of call `t`'s function by its name alone, whether the package defines it or not
// (`dead_allocs`, `memcmp_eq`): ALLOC_NONE for another instruction.
fn named_alloc(pk: &Package, b: &Body, t: Inst) u8 {
    return if t.op == O_CALL {
        pk.syms[b.syms[t.a as usize] as usize].alloc
    } else {
        ALLOC_NONE
    };
}

// The `Sym.alloc` of the function call `t` calls, ALLOC_NONE for any other instruction and for a function
// the package defines: its own code (wasm's C library, the runtime's leak tracker) reads what it writes.
fn call_alloc(pk: &Package, b: &Body, t: Inst) u8 {
    if t.op != O_CALL {
        return ALLOC_NONE;
    }
    let s = pk.syms[b.syms[t.a as usize] as usize];
    return ast::pick(s.def == NONE, s.alloc, ALLOC_NONE);
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
// counts as none. `fp` holds, per instruction, whether its value points into such a referent.
fn frozen(b: &Body, out: &mut Vector<bool>, fp: &mut Vector<bool>) {
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
    fill(fp, ni, false);
    for i in 0..ni {
        let t = b.insts[i];
        let base = ast::pick(t.op == O_LOAD || t.op == O_PTRADD, t.a, VNONE);
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

// Whether load `t` reads a view parameter's own words (its element pointer or length) through the
// parameter: the body does not rebind the view (`REF_INNER`, `Lower::view_ref`), and no other pointer
// reaches the parameter's bytes, so they hold one value for the whole call. Checked at the load's
// visit, where its address is current: an inlined copy's accesses reach the parameter only once the
// walk forwarded the copy's entry parameters, after `frozen` ran.
const fn view_word(b: &Body, t: Inst) bool {
    return t.op == O_LOAD && (t.aux & MEM_VOLATILE) == 0 && inner(b, entry_param(b, t.a));
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
// `Opt::cf_work`: an entry that is a terminator whose edges pass values (else address arithmetic or a select).
const CF_EDGES: u32 = 1u32 << 31;

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
            t[k as usize] = op >= O_ICONST && op <= O_INTTOPTR || op == O_PTRADD || op == O_SELECT || op == O_FMA || op == O_MULHU || op == O_MULHS || op == O_BSWAP || op == O_BITREV || op >= O_CLZ && op <= O_POPCNT || op == O_SPLAT || op == O_VCMP || op == O_VSEL || op == O_VUNZIP || op == O_HTOF || op == O_FTOH || op == O_FSQRT || op == O_VZIPLO || op == O_VZIPHI || op == O_VEXTRACT || op == O_VINSERT || op == O_VSUMW || op == O_VMULW;
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
        let c = int_bits(b, t.b);
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

// `v` within `[lo, hi]`.
fn clamp_i64(v: i128, lo: i64, hi: i64) i64 {
    if v < lo {
        return lo;
    }
    return ast::pick(v > hi, hi, v as i64);
}

// The signed bound a `SLO_KEY` or `SHI_KEY` entry `f` gives for a value of `w` bits: its constant plus its offset.
fn signed_bound(b: &Body, f: u32, w: u32) i128 {
    return sign_extend(int_bits(b, f >> 2).unwrap(), w) as i128 + (f & 3) - 1;
}

// The two values `s` is the signed maximum (`max`) or minimum of, as a select (a bound on `s` from above, or
// below, bounds both); `(VNONE, VNONE)` else.
fn extreme_arms(b: &Body, s: Value, max: bool) (Value, Value) {
    if (s & (VPARAM | VFLAG)) != 0 || s == VNONE || !is_op(b, s, O_SELECT) || is_vec(b.insts[s as usize].ty) {
        return (VNONE, VNONE);
    }
    let t = b.insts[s as usize];
    let (x, y, neg) = Opt::as_slt(b, t.a);
    // The select takes `x` when `x <s y` (`neg`: when it fails), so its true arm is the smaller.
    let small_first = t.b == x && t.c == y && !neg || t.b == y && t.c == x && neg;
    let large_first = t.b == y && t.c == x && !neg || t.b == x && t.c == y && neg;
    return if x != VNONE && ast::pick(max, large_first, small_first) {
        (x, y)
    } else {
        (VNONE, VNONE)
    };
}

// The constant step `k` (within 2^32 either way) of `a` as `p + k` or `p - (-k)`, as a signed value of the
// type; 0 for none.
fn step_of(b: &Body, a: Value, p: Value) i64 {
    if a == VNONE || (a & (VPARAM | VFLAG)) != 0 || is_vec(b.insts[a as usize].ty) || b.insts[a as usize].ty == T_I128 {
        return 0;
    }
    let t = b.insts[a as usize];
    if t.a != p || t.op != O_ADD && t.op != O_SUB {
        return 0;
    }
    let k = int_bits(b, t.b);
    if k.is_none() {
        return 0;
    }
    let s = sign_extend(k.unwrap(), type_bits(t.ty, 8));
    if s > 1i64 << 32 || s < -(1i64 << 32) {
        return 0;
    }
    return ast::pick(t.op == O_ADD, s, -s);
}

// Whether `a` is `p - 1` (or `p + ~0`).
fn minus_one(b: &Body, a: Value, p: Value) bool {
    if a == VNONE || (a & (VPARAM | VFLAG)) != 0 || b.insts[a as usize].a != p || is_vec(b.insts[a as usize].ty) || b.insts[a as usize].ty == T_I128 {
        return false;
    }
    let t = b.insts[a as usize];
    let k = int_bits(b, t.b);
    let m = mask_of(type_bits(t.ty, 8));
    return k.is_some() && (t.op == O_SUB && (k.unwrap() & m) == 1 || t.op == O_ADD && (k.unwrap() & m) == m);
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
    let (m, code) = if int_bits(b, t.b) == Some(0u64) {
        (t.a, t.aux)
    } else if int_bits(b, t.a) == Some(0u64) {
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
        int_bits(b, t.b)
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
    let v = ast::pick(left, t.a, t.b);
    let ty = b.type_of(t.a);
    let k = int_bits(b, v);
    if k.is_some() {
        let o = if left {
            int_bits(b, t.b).unwrap()
        } else {
            int_bits(b, t.a).unwrap()
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
            int_bits(b, t.b)
        } else {
            int_bits(b, t.a)
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
        let s = int_bits(b, b.insts[x as usize].b);
        let xn = type_bytes(b.type_of(x), ptr) as u64;
        if s.is_some() && s.unwrap() % 8 == 0 && s.unwrap() / 8 + n as u64 <= xn {
            return (b.insts[x as usize].a, (s.unwrap() / 8) as u32, n);
        }
        return (VNONE, 0, 0);
    }
    return (x, 0, n);
}

// Select `i` of `b` on `x == 0` (or `x != 0`) whose arm for `x != 0` is a count of `x` only it reads: the
// count is `CNT_NONZERO` (its value for 0 is never taken).
fn nonzero_arm(b: &mut Body, i: u32) {
    let t = b.insts[i as usize];
    if !is_op(b, t.a, O_ICMP) {
        return;
    }
    let c = b.insts[t.a as usize];
    if c.aux != C_EQ && c.aux != C_NE || int_bits(b, c.b) != Some(0u64) {
        return;
    }
    let arm = ast::pick(c.aux == C_EQ, t.c, t.b);
    if !is_op(b, arm, O_CLZ) && !is_op(b, arm, O_CTZ) || b.insts[arm as usize].a != c.a || b.insts[arm as usize].aux != 0 || !only_use(
        b,
        arm,
        i,
    ) {
        return;
    }
    b.insts.index_mut(arm as usize).aux = CNT_NONZERO;
}

// Whether instruction `at` of `b` is the one use of value `v`: no other instruction or edge reads it.
fn only_use(b: &Body, v: Value, at: u32) bool {
    let mut us = Vector::<Value>::new();
    let mut es = Vector::<u32>::new();
    for j in 0..b.insts.len() as u32 {
        let t = b.insts[j as usize];
        if j != at {
            lv::uses(b, t, &mut us);
            for q in 0..us.len() {
                if us[q] == v {
                    return false;
                }
            }
        }
        if t.op == O_JMP || t.op == O_BR || t.op == O_SWITCH {
            b.succ_edges(t, &mut es);
            for e in 0..es.len() {
                for q in 0..b.edge_nargs(es[e]) {
                    if b.edge_arg(es[e], q) == v {
                        return false;
                    }
                }
            }
        }
    }
    return true;
}

// Edge `q` (0: the true one, 1: the false one) of branch `i` of `b` as a copy only the branch passes:
// its index.
fn own_edge(b: &mut Body, i: u32, q: u32) u32 {
    let t = b.insts[i as usize];
    let e = ast::pick(q == 0, t.b, t.c);
    let mut args = Vector::<Value>::with_capacity(b.edge_nargs(e) as usize);
    for k in 0..b.edge_nargs(e) {
        args.push(b.edge_arg(e, k));
    }
    let n = b.edge(b.edge_target(e), &args);
    if q == 0 {
        b.insts.index_mut(i as usize).b = n;
    } else {
        b.insts.index_mut(i as usize).c = n;
    }
    return n;
}

// The edge branch `t` takes when its condition is `c`.
const fn side(t: Inst, c: u64) u32 {
    return ast::pick(c != 0, t.b, t.c);
}

// The bits of a value of type `ty`.
const fn width_mask(ty: u8, ptr: u32) u64 {
    return mask_of(type_bits(ty, ptr));
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
        let c = ast::pick(side == 0, o.a, o.b);
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
    let (x, k, cond) = if int_bits(b, c.b).is_some() {
        (c.a, int_bits(b, c.b).unwrap(), c.aux)
    } else if int_bits(b, c.a).is_some() {
        (c.b, int_bits(b, c.a).unwrap(), mirror(c.aux))
    } else {
        return none;
    };
    if int_bits(b, x).is_some() {
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
    return ast::pick(t.b == e, t.c, t.b);
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
    let held = pk.held_bodies();
    let ns = pk.syms.len();
    // Per body below `held`, its function's symbol; per symbol, the parameters every call passes one
    // constant (`mask`, after `seen`), those constants (`vals`, by `symbol << 6 | parameter`), and the
    // calls from other bodies.
    let owner = pk.body_owners();
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
        y.always = f.always;
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
    pk.bodies.reserve_exact(made.len());
    for j in 0..made.len() {
        pk.syms.index_mut(made_sym[j] as usize).def = pk.bodies.len() as u32;
        pk.bodies.push(replace(made.index_mut(j), Body::empty()));
    }
    while let Some(b) = hb.pop() {
        pk.bodies.push(b);
    }
}

// The entry parameter of entry block `e` that value `v` is, or stands for (`fwd`, `param_slots`); NONE for
// another value.
fn entry_of(e: Block, fwd: &Vector<Value>, v: Value) u32 {
    if v == VNONE || (v & VPARAM) == 0 {
        return NONE;
    }
    if (v & ~VPARAM) >= e.param_start && (v & ~VPARAM) < e.param_start + fwd.len() as u32 {
        return (v & ~VPARAM) - e.param_start;
    }
    for k in 0..fwd.len() {
        if fwd[k] == v {
            return k as u32;
        }
    }
    return NONE;
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

// The edges of the bodies' job graph (`Run::edges`), pushed onto `edges` when `list`; their count. A caller
// waits for each distinct direct callee of a lower level (`seen`: the last caller that listed it).
fn waits(
    n: usize,
    call_at: &Vector<u32>,
    calls: &Vector<u32>,
    level: &Vector<u32>,
    seen: &mut Vector<u32>,
    edges: &mut Vector<u64>,
    list: bool,
) usize {
    fill(seen, n, NONE);
    let mut ne: usize = 0;
    for k in 0..n {
        for q in call_at[k]..call_at[k + 1] {
            let c = calls[q as usize];
            if level[c as usize] < level[k] && seen[c as usize] != k as u32 {
                seen[c as usize] = k as u32;
                ne += 1;
                if list {
                    edges.push(c as u64 << 32 | k as u64);
                }
            }
        }
    }
    return ne;
}

// At most RET_EDGES branch edges of a body return through blocks of their own (`ret_edges`).
const RET_EDGES: u32 = 8;

// Give each edge of a branch of `b` that passes arguments to a block that only returns a block of its own
// that returns the value (`ret_through`), up to RET_EDGES and but one edge into each such block (which stays
// reachable): the native code returns at once rather than move the arguments and jump (LLVM's tail
// duplication of return blocks; the walk makes a jump's own return). Whether any. `into` and `es` are
// scratch.
fn ret_edges(b: &mut Body, into: &mut Vector<u32>, es: &mut Vector<u32>) bool {
    let nb = b.blocks.len();
    // Per block, the edges into it.
    fill(into, nb, 0);
    for k in 0..nb {
        let bk = b.blocks[k];
        if bk.len != 0 {
            b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], es);
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
            let e = ast::pick(side == 0, t.b, t.c);
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
    let c = int_bits(b, t.b);
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
        let k = int_bits(b, t.b);
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

// Whether value `a` equals constant `c` (`m` its type's mask) where condition `v` is `want` (true: not 0):
// an equality or inequality of `a` with a constant settles it, as each operand of an `and` that holds and
// of an `or` that does not, `depth` levels down. None when they do not.
fn cond_fact(b: &Body, v: Value, want: bool, a: Value, c: u64, m: u64, depth: u32) Option<bool> {
    if depth == 0 || v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
        return None;
    }
    let t = b.insts[v as usize];
    if t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) {
        let k2: Option<u64> = if t.a == a {
            int_bits(b, t.b)
        } else if t.b == a {
            int_bits(b, t.a)
        } else {
            None
        };
        if k2.is_none() {
            return None;
        }
        let same = (k2.unwrap() & m) == (c & m);
        // `a == k2` holds, or `a != k2`.
        if t.aux == C_EQ == want {
            return Some(same);
        }
        return if same {
            Some(false)
        } else {
            None
        };
    }
    if t.ty == T_I8 && (t.op == O_AND && want || t.op == O_OR && !want) {
        let r = cond_fact(b, t.a, want, a, c, m, depth - 1);
        return if r.is_some() {
            r
        } else {
            cond_fact(b, t.b, want, a, c, m, depth - 1)
        };
    }
    return None;
}

// The constant that value `n` equals where condition `v` is `want` (`cond_fact`'s conditions), if one does.
fn eq_const(b: &Body, v: Value, want: bool, n: Value, depth: u32) Option<u64> {
    if depth == 0 || v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
        return None;
    }
    let t = b.insts[v as usize];
    if t.op == O_ICMP && t.aux == C_EQ == want && (t.aux == C_EQ || t.aux == C_NE) {
        return if t.a == n {
            int_bits(b, t.b)
        } else if t.b == n {
            int_bits(b, t.a)
        } else {
            None
        };
    }
    if t.ty == T_I8 && (t.op == O_AND && want || t.op == O_OR && !want) {
        let r = eq_const(b, t.a, want, n, depth - 1);
        return if r.is_some() {
            r
        } else {
            eq_const(b, t.b, want, n, depth - 1)
        };
    }
    return None;
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

// The operation's word is mixed before the first operand joins it: else two instructions whose words and
// first operands differ in the same bits (`shl` and `lshr` of two parameters one apart, by one constant)
// hash alike, and in the value numbering the newer shadows the older.
const fn hash(t: Inst) u64 {
    return mix(mix(mix(mix(t.op as u64 | t.ty as u64 << 8 | t.aux as u64 << 16, 0), t.a), t.b), t.c);
}

const fn place_hash(addr: u32, off: u32, ty: u8, state: u32) u64 {
    return mix(mix(addr as u64 | ty as u64 << 32, off), state);
}
