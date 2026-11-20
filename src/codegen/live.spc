// The analysis pass of the native backends (after TPDE, Schwarz, Kamm and Engelke 2025): one walk over a
// LIR body gives the block layout, the loop nesting and each value's live range and use count, which the
// code generation pass reads to allocate registers in one pass.
//
// Layout: reverse postorder, each loop contiguous (a block's key is the list of its loop headers'
// positions, then its own, compared in order), a loop's rare blocks after its warm ones, the other rare
// blocks last. A block is rare when the entry reaches it only through a block marked rare (`BLOCK_RARE`:
// cold or unlikely), so no warm block follows a rare one in dominance. A value's range is the layout
// positions from its definition's block to `end`: its last use, or the last block of the outermost loop
// that holds a use but not the definition (the value must survive the back edge). The CFG is reducible
// (the verifier checks it), so an edge to a block not later in reverse postorder is a back edge.
import lir::ir as *;
import lir::verify as lv;
import ir::core as core;
import ast::ast as ast;

/// `Live::fold_ops`: an integer comparison whose every use is a `select`'s or a `br`'s condition (each
/// compares again instead of testing a boolean set from the flags); an `and` whose every use compares it
/// with 0 for equality (`tst`); a product one `add` or `sub` takes (`madd`, `msub`); a logical shift right
/// by a constant one `and` with a mask of low bits takes (`ubfx`); the two shifts of a rotation and the
/// arithmetic of its second amount (`rotate_of`), of 32 or 64 bits, with FOLD_ROT_NARROW of 8 and 16 too
/// (`rol`, `ror`); the shift left by 1 to 3 and the inner sum one sum takes as an address (`lea_of`); an
/// `and` or `or` of flags that are comparisons each with this one use, or such `and`s and `or`s, compared
/// one after the other (`conj`: arm64's `ccmp`); a mask of a 32- or 64-bit shift's amount to the low bits
/// of the width, which the shift takes modulo its width anyway (`shift_amount`); a `select`'s side that is
/// the other side plus 1, negated or inverted (`cs_kind`: arm64's `csinc`, `csneg`, `csinv`); two
/// extensions of the same kind from 32 bits, or one and a constant within the extension's range, that a
/// 64-bit product alone reads (`mull_ext`: arm64's `umull`, `smull`); a shift by a constant that a 32- or 64-bit sum, difference or bitwise operation
/// alone reads as an operand it may take shifted (`shop_side`: arm64's shifted register operand); a
/// scalar float comparison only selects and branches read, of one condition (`FOLD_FCMP`; not `one`,
/// `ueq`).
pub(package) const FOLD_CMP: u64 = 1;
pub(package) const FOLD_TST: u64 = 2;
pub(package) const FOLD_MADD: u64 = 4;
pub(package) const FOLD_UBFX: u64 = 8;
pub(package) const FOLD_ROT: u64 = 16;
pub(package) const FOLD_ROT_NARROW: u64 = 32;
pub(package) const FOLD_LEA: u64 = 64;
pub(package) const FOLD_CCMP: u64 = 128;
pub(package) const FOLD_SHAMT: u64 = 256;
pub(package) const FOLD_CSEL: u64 = 512;
pub(package) const FOLD_MULL: u64 = 1024;
pub(package) const FOLD_SHOP: u64 = 2048;
pub(package) const FOLD_FCMP: u64 = 4096;
pub(package) const FOLD_BLEN: u64 = 8192;
/// A select between a value and that value plus 1, the sum read only there: the sum folds in (wasm32's
/// `x + c`).
pub(package) const FOLD_SINC: u64 = 274877906944;
/// A zero extension of an integer of 32 bits or fewer, or a sign extension of a 32-bit one, to 64 bits that
/// one instruction of its block reads: that instruction extends its operand (wasm32's `i64.extend_i32_*` at
/// the use, no local; a narrow integer's location holds it zero-extended).
pub(package) const FOLD_WIDEN: u64 = 549755813888;
/// A store's value, a select's side or its folded comparison's operand, a narrow integer load that a sign
/// extension or a zero extension to 64 bits reads (one folded into its reader too, `FOLD_WIDEN`: wasm32's
/// extending loads), or an integer operation's
/// second operand when its first stays (a parameter, a constant, a value of more uses; for a commutative one, the
/// second not made right before it, which it reads first), that one instruction of
/// its block makes and only that reads: an integer operation that cannot trap (no division), a bit count,
/// a select or a scalar load,
/// whose
/// operands are parameters, constants, values of more uses or one more level of such values, no
/// instruction between a load and its reader writing memory. The reader computes it where it reads it
/// (wasm32's tree order: no local between).
pub(package) const FOLD_SINK: u64 = 1099511627776;
/// The extension or truncation of an integer that a folded shift count mask (`FOLD_SHAMT`) alone reads: the
/// shift reads the count's low bits from the integer's register (x86-64's `cl`, arm64's register shifts).
pub(package) const FOLD_SHAMT_EXT: u64 = 2199023255552;
/// A store of an integer `add`, `sub`, `and`, `or` or `xor` of a load of the same address (the first
/// operand of a `sub`), each read only there, with no write between the load and the store: both fold into
/// the store, which reads and writes the memory (x86-64's `add [m], r`; `rmw_load`).
pub(package) const FOLD_RMW: u64 = 4398046511104;
/// Under `FOLD_SINK`, vectors of at most 16 bytes move too (a target that holds them in registers).
pub(package) const FOLD_VSINK: u64 = 8796093022208;
pub(package) const FOLD_CARRY: u64 = 16384;
pub(package) const FOLD_FSEL: u64 = 32768;
pub(package) const FOLD_NOT: u64 = 65536;
/// `FOLD_NOT` for `and` alone (x86-64 BMI1's `andn`).
pub(package) const FOLD_ANDN: u64 = 72057594037927936;
/// `x - 1` or `-x` whose every use is an `and` (`xor` for `x - 1`) with `x`, which folds nothing or only
/// equalities with 0 read: it folds into each (x86-64 BMI1's `blsr`, `blsi`, `blsmsk`; `bls_parts`).
pub(package) const FOLD_BLS: u64 = 144115188075855872;
/// A load of 32 or 64 bits that a byte reversal alone reads, with no write of memory between, folds into
/// the reversal; a byte reversal of 16, 32 or 64 bits that a store alone reads, of no folded load, folds
/// into the store (x86-64's `movbe`).
pub(package) const FOLD_MOVBE: u64 = 288230376151711744;
/// A load that de-interleaving shuffles of a group of three alone read (`Live::ld3_field`): each shuffle
/// loads the group itself (arm64's `ld3`).
pub(package) const FOLD_LD3: u64 = 576460752303423488;
/// The mask bits that masked loads and stores through a pointer alone read (`pred_mask`) and what makes
/// them: a lane comparison, which each access makes into a predicate itself (arm64 SVE's CMPHI and the
/// like), or the sum and the AND of a lane mask, each access's predicate the lane mask's (CMPNE). A vector
/// of zeros those loads alone read as their fallback, which their predicated loads give.
pub(package) const FOLD_PRED: u64 = 1152921504606846976;
pub(package) const FOLD_XBFX: u64 = 131072;
pub(package) const FOLD_BFI: u64 = 262144;
/// A load's or store's folded index that is the 64-bit zero or sign extension of a 32-bit value (or of an
/// unsigned 8- or 16-bit entry parameter, under `ext_args`), which only that access reads: the access
/// extends it (arm64 `[xn, wm, uxtw]`).
pub(package) const FOLD_XIDX: u64 = 524288;
/// `FOLD_LDOP`: a single-use scalar float load as the right operand of arithmetic, or an integer load
/// that one comparison or `add`, `sub`, `and`, `or`, `xor` or `mul` reads
/// folds into it, which reads the memory (x86-64's `cmp [m], k`, `add r, [m]`, `imul r, [m]`;
/// `Live::ldop_user`).
pub(package) const FOLD_LDOP: u64 = 1048576;
/// `FOLD_ANY`: an `or` of the lanes of a 16-byte lane mask (`lane_mask`) that equalities with 0 alone
/// read folds into each: they test the lanes' sign bits (x86-64's `pmovmskb` and `test`). `FOLD_ANY_WIDE`:
/// of a 32-byte one too (AVX2's `vpmovmskb`).
pub(package) const FOLD_ANY: u64 = 2097152;
pub(package) const FOLD_ANY_WIDE: u64 = 4194304;
/// `FOLD_VMLA`: a product of integer vectors of 8 or 16 bytes, lanes below 8 bytes, or a widening product
/// (`O_VMULW`) of 16 bytes, with one use, the second operand of a sum or a difference or the first of a sum,
/// folds into it (arm64's MLA and MLS; SMLAL, UMLAL, SMLSL and UMLSL); else a right shift by an immediate
/// (`vshimm`) with one use, an operand of a sum, folds into it (USRA and SSRA).
pub(package) const FOLD_VMLA: u64 = 8388608;
/// `FOLD_VSHIMM`: a vector shift by one constant below its integer lanes' width (`vec_shift_amount`) shifts
/// by an immediate, and a splat or wide constant such shifts alone read as their amount folds into them:
/// 16-byte vectors of 2- to 8-byte lanes, the arithmetic shifts below 8 (SSE2). `FOLD_VSHIMM_WIDE`: 32-byte
/// ones too (AVX2). `FOLD_VSHIMM_ALL`: 8- and 16-byte vectors of any lanes but a lone 8-byte one (Neon).
pub(package) const FOLD_VSHIMM: u64 = 16777216;
pub(package) const FOLD_VSHIMM_WIDE: u64 = 33554432;
pub(package) const FOLD_VSHIMM_ALL: u64 = 67108864;
/// `FOLD_XADDR`: an address `ptradd` of a base and an index scaled by 1, 2, 4 or 8 that only the loads
/// and stores of its block read as their address folds into each, at any offset (x86-64's
/// `[base + index * scale + disp]`).
pub(package) const FOLD_XADDR: u64 = 134217728;
/// `FOLD_BRCONJ`: an `and` or `or` of two integer comparisons of up to 64 bits, each with that one use,
/// whose one use is a `br`: both fold into the branch, which tests the first and jumps, then the second
/// (x86-64's `cmp; jcc; cmp; jcc`).
pub(package) const FOLD_BRCONJ: u64 = 268435456;
/// `FOLD_VWADD`: a 16-byte integer vector `bitcast` of a `vziplo` or `vziphi` of a vector with zeros (its
/// low or high half zero-extended to lanes twice as wide), each with one use, that a vector sum of the
/// wide lanes adds: the sum widens and adds (arm64 `uaddw`, `uaddw2`). Not into a sum that accumulates a
/// product or a shift (`FOLD_VMLA`), whose other operand is its accumulator.
pub(package) const FOLD_VWADD: u64 = 536870912;
/// `FOLD_TRUNC`: a truncation of an integer to 8 or 16 bits that only integer comparisons read folds into
/// each: they extend or test its low bits in the source's register (arm64 `tst`, `uxtb`, `sxth`).
pub(package) const FOLD_TRUNC: u64 = 1073741824;
/// `FOLD_TRUNC_ONCE`: with `FOLD_TRUNC`, only a truncation that one comparison reads folds: the target's
/// comparison extends its operand, which a truncation with a register of its own does once for them all.
pub(package) const FOLD_TRUNC_ONCE: u64 = 4503599627370496;
/// `FOLD_ADC`: the sum `h + zext(c)` (or difference `h - zext(c)`) of a sum (difference) `h` of two values
/// and the carry (borrow) `c` of an unsigned `addo` (`subo`) of the same width, 32 or 64 bits, with only
/// `h` and the extension between them, each of one use and no flag read: `h` and the extension fold into
/// it, the `addo` keeps its carry in the flags, and it adds with it (`adc`, arm64 `sbc` / x86-64 `sbb`).
/// `Live::carry` marks the three parts.
pub(package) const FOLD_ADC: u64 = 2147483648;
/// `FOLD_LANE`: a lane read (`vextract`) of a vector of 8 or 16 bytes, lanes of 4 or 8 bytes, whose one use is
/// a `splat`: the splat broadcasts the lane from the vector's register (arm64 `dup v, v[k]`, x86-64 `pshufd`).
pub(package) const FOLD_LANE: u64 = 4294967296;
/// `FOLD_LANE_MUL`: such a splat of a lane with one use, the second operand of a product of float vectors of 8
/// or 16 bytes, folds into it too: the product multiplies by the lane (arm64 `fmul v, v, v[k]`).
pub(package) const FOLD_LANE_MUL: u64 = 8589934592;
/// `FOLD_ZSHL`: a zero extension of an integer of `k` bits with one use, a left shift by a constant `s`
/// with `k + s` at least the width, folds into it: every bit the extension clears leaves the result, so
/// the shift reads the narrow value's register (`shl_source`). Neither may fold into anything else.
pub(package) const FOLD_ZSHL: u64 = 17179869184;
/// `FOLD_FREE_ZEXT`: a zero extension of an 8- or 16-bit integer to 16 or 32 bits, for a target that keeps
/// every narrow integer zero-extended in a 32-bit location (wasm): each use reads its operand. So does a
/// truncation of such a location to 8 or 16 bits whose operand fits (`fits_low`), or that only select
/// sides read where the condition bounds the operand (`bounded_side`), or only `and`s with another value
/// of its type that is no truncation (zero-extended, it clears the bits above); of a 64-bit integer, for
/// those `and`s, each use reads its operand's low word.
pub(package) const FOLD_FREE_ZEXT: u64 = 68719476736;
/// `FOLD_VSAD`: an unsigned absolute difference of byte vectors (`vop` `SIMD_ABS_DIFF`) that one widening
/// sum into 8-byte lanes (`O_VSUMW`) alone reads folds into it: the sum takes the two vectors (x86-64
/// `psadbw`).
pub(package) const FOLD_VSAD: u64 = 34359738368;
/// `FOLD_LANE_PAIR`: lanes 0 and 1 of one float vector of two lanes (8 or 16 bytes), each read with one use,
/// that a scalar `fadd` adds, fold into it: the sum adds the vector's lanes pairwise (arm64 `faddp`).
pub(package) const FOLD_LANE_PAIR: u64 = 137438953472;
/// `FOLD_LANE0`: lane 0 of a float vector of 8 or 16 bytes, read with one use, an operand of a scalar `fadd`,
/// `fsub`, `fmul` or `fdiv` of the lane's type: the operation reads the vector's register, whose low lane
/// the scalar is (`lane0_of`).
pub(package) const FOLD_LANE0: u64 = 17592186044416;
/// `FOLD_XBFX_EXT`: `FOLD_XBFX` for a field of 8 or 16 bits (32 of a 64-bit value) alone, which a right
/// shift and an extension of its low bits extract (x86-64 `shr`, `movsx`/`movzx`).
pub(package) const FOLD_XBFX_EXT: u64 = 35184372088832;
/// `FOLD_VLDOP`: `FOLD_LDOP` for a load of a 16- or 32-byte vector, the second operand of a lane `fadd`,
/// `fsub`, `fmul`, `fdiv`, `add`, `sub`, `and`, `or` or `xor` of its type (x86-64's VEX forms, which read
/// memory of any alignment: `vaddps x, x, [m]`).
pub(package) const FOLD_VLDOP: u64 = 70368744177664;
/// `FOLD_ANY_BITS`: with `FOLD_ANY`, the `or` of the lanes of any integer vector (not only a lane mask) that
/// equalities with 0 alone read folds into each: they test all its bits (x86-64's SSE4.1 `ptest`).
pub(package) const FOLD_ANY_BITS: u64 = 140737488355328;
/// `FOLD_VCMEM`: a 16-byte vector constant that the instructions of its block alone read, each as the
/// second operand of a lane operation of `FOLD_VLDOP`'s, folds into each: they read it from the constant
/// data, which aligns it (x86-64's `pxor x, [rip + k]`).
pub(package) const FOLD_VCMEM: u64 = 281474976710656;
/// `FOLD_VMUL`: with `FOLD_VLDOP` and `FOLD_VCMEM`, a product of 32-bit lanes is such a lane operation
/// (x86-64's SSE4.1 `pmulld x, [m]`).
pub(package) const FOLD_VMUL: u64 = 562949953421312;
/// `FOLD_ADDSUB`: a lane select of 16-byte float vectors by a constant of all ones in the even lanes alone
/// (`addsub_parts`), of a difference `x - y` and a sum `x + y`, each with that one use: the two fold into
/// it, which subtracts in the even lanes and adds in the odd ones (x86-64's SSE3 `addsubps`, `addsubpd`),
/// and the mask when such selects alone read it. `FOLD_ADDSUB_WIDE`: of 32-byte ones too (AVX).
pub(package) const FOLD_ADDSUB: u64 = 1125899906842624;
/// `FOLD_XUSE`: a zero or sign extension of a 32-bit integer to 64 bits folds into its uses when each is
/// the index of an address computation (`ptradd`) or an operand of an integer comparison with a register
/// (not one an `and` or `or` of flags takes): each use extends the narrow value's register itself (arm64's
/// extended-register `add` and `cmp`, and `[xn, wm, uxtw]` as `FOLD_XIDX`), so an index that is also
/// compared with a length takes no copy.
pub(package) const FOLD_XUSE: u64 = 9007199254740992;
pub(package) const FOLD_ADDSUB_WIDE: u64 = 2251799813685248;
/// `FOLD_VIEW`: an instruction that keeps its operand's bits (a truncation, a cast between a pointer and
/// an integer no wider, a pointer's copy: `ptradd` of nothing, a cast between two vectors of one size)
/// makes no value of its own: it is a view of
/// its operand (`Live::view`), which every read of it reads, at its own type (a target whose registers hold
/// both). The operand lives to the view's last read, in one register for both. So is a zero extension of
/// a load or of a zero extension: the generator keeps the bits above such a value zero in its register
/// and its home (`Live::wide`).
pub(package) const FOLD_VIEW: u64 = 18014398509481984;
/// `FOLD_FJOIN`: an `and` or `or` of flags that is no `FOLD_CCMP` chain, of a comparison (or a chain) it
/// alone uses and a value that is 0 or 1 (`zero_one`): the comparison folds into it (`Live::join_part`),
/// and it takes the value where the flags let the value decide, else 0 (`and`) or 1 (`or`), in one
/// conditional select (arm64 `csel`, `csinc`).
pub(package) const FOLD_FJOIN: u64 = 36028797018963968;
/// `Live::carry`: per instruction, its part of a `FOLD_ADC` sum: none, the `addo` or `subo` whose carry the
/// flags keep, a folded sum or extension, the sum with the carry.
pub(package) const CARRY_NONE: u8 = 0;
pub(package) const CARRY_LO: u8 = 1;
pub(package) const CARRY_PART: u8 = 2;
pub(package) const CARRY_ADC: u8 = 3;
// `lane_mask` follows this many `and`, `or` and `xor` operations.
pub(package) const MASK_DEPTH: u32 = 8;
// `Live::ldop_user` looks this many instructions past a load for its use.
const LDOP_REACH: u32 = 16;
// The instructions from a group's first load to a shuffle of it (`Live::ld3_field`).
const LD3_REACH: u32 = 64;
/// The most calls outside rare blocks whose live values a generator reads (`lives_across` reads every
/// value per call) when it chooses where a body sets its frame up. A body with more sets it up late only
/// when it has at most WARM_SIZE instructions (a try that fails compiles the body again) and the frame's
/// edges run seldom enough (`Live::frame_half`).
pub(package) const WARM_CALLS: u32 = 4;
pub(package) const WARM_SIZE: u32 = 256;

/// `cs_kind`: a `select`'s side as the other side plus 1, negated, inverted; none of these.
pub(package) const CS_NONE: u8 = 0;
pub(package) const CS_INC: u8 = 1;
pub(package) const CS_NEG: u8 = 2;
pub(package) const CS_NOT: u8 = 3;
// A chain of conditional comparisons (`FOLD_CCMP`) holds at most this many comparisons: 8, as clang's
// expansion of a `memcmp` equality of 64 bytes in 8-byte pairs.
const CCMP_MAX: u8 = 8;
// The most folded instructions `uses_at` expands for one use: a longest chain's comparisons and the `and`s
// or `or`s that join them, and a comparison of a test of a field.
const FOLD_DEPTH: u32 = 2 * CCMP_MAX as u32 + 2;
// The levels of values a sunk value moves with (`FOLD_SINK`): its operands, theirs, and so on.
const SINK_DEPTH: u32 = 4;

/// Whether LIR operation `op` keeps its operand's bits: a pointer to or from an integer, a bit cast.
pub(package) const fn free_conv(op: u8) bool {
    return op == O_PTRTOINT || op == O_INTTOPTR || op == O_BITCAST;
}

/// `Live::plan`'s homes per value: no register for the whole range, a callee-saved one, a caller-saved one, a
/// caller-saved one of the vector file's upper registers (x86-64's xmm16..xmm31, which only EVEX encodes).
// `Live::frequencies`: what the entry runs on, a loop header's factor, an ordinary successor's share against a
// rare one's 1, and the most any block runs on (so sums of weights stay far from overflow). The entry's
// count leaves a chain of twenty even branches a share above 0.
const FREQ_ENTRY: u64 = 1u64 << 20;
const FREQ_LOOP: u64 = 8;
const FREQ_SPLIT: u64 = 15;
const FREQ_MAX: u64 = 1u64 << 40;

/// `Live::plan`'s request per value: it may take a callee-saved register, a caller-saved one; it is of the
/// vector file (else the general one); it may take an upper register (every instruction that reads or writes
/// it has an encoding for one).
pub(package) const WANT_CALLEE: u8 = 1;
pub(package) const WANT_SCRATCH: u8 = 2;
pub(package) const WANT_V: u8 = 4;
pub(package) const WANT_UPPER: u8 = 8;
/// It takes a register for its whole range or none: no segment (a constant a generator rebuilds).
pub(package) const WANT_WHOLE: u8 = 16;

/// The registers `Live::plan` gives out at once per file (`x`: general, `v`: vector): callee-saved,
/// caller-saved, and all together; and the vector file's upper registers (`vu`), which `vj` counts too.
pub(package) struct Caps {
    pub(package) xc: u32,
    pub(package) xs: u32,
    pub(package) xj: u32,
    pub(package) vc: u32,
    pub(package) vs: u32,
    pub(package) vj: u32,
    pub(package) vu: u32,
}

extend Caps as Copy {}

/// The analysis of one body. Values index `insts` first, then `params`, then the overflow flags that have
/// a use (`flag_of`).
pub(package) struct Live {
    pub(package) order: Vector<u32>, // the blocks in layout order
    pub(package) pos: Vector<u32>, // per block, its layout position
    pub(package) npred: Vector<u32>, // per block, its predecessor count (an edge each from a block the entry reaches)
    pub(package) inner: Vector<u32>, // per block, the header of its innermost loop, NONE outside loops
    pub(package) lend: Vector<u32>, // per loop header, the layout position of the loop's last block
    pub(package) parent: Vector<u32>, // per loop header, the header of the loop around it, NONE
    pub(package) rare: Vector<bool>, // per block, whether the entry reaches it only through a block marked rare
    /// Per block (empty: none), whether the layout puts it after every other block, in layout order: a
    /// generator's blocks that alone set its frame up, after the code that has none.
    pub(package) after: Vector<bool>,
    pub(package) def_blk: Vector<u32>, // per value, its block
    // Per block, its predecessors that the entry reaches: `preds[pat[k]..pat[k + 1]]` (`loops`).
    pub(package) pat: Vector<u32>,
    pub(package) preds: Vector<u32>,
    // Per instruction of a laid-out block, its uses as `uses_at` gives them: `uv[ua[i]..ua[i] + un[i]]`
    // (`ranges`; `uses_of`).
    ua: Vector<u32>,
    un: Vector<u32>,
    uv: Vector<Value>,
    pub(package) next: Vector<u32>, // per value, its next use's layout ordinal, NONE after the last use
    use_next: Vector<u32>, // per folded operand, the next use of that value
    pub(package) end: Vector<u32>, // per value, the last layout position it is live in
    pub(package) uses: Vector<u32>, // per value, its use count, one more when a loop keeps it past its last use
    pub(package) last: Vector<u32>, // per value, the highest instruction index that uses it (0: none)
    sole: Vector<u32>, // per block parameter, the one instruction that reads it (NONE: none; READERS: more)
    rlast: Vector<u32>, // per value, the last layout position of a block that reads it, NONE: none
    // `folds`: the instructions grouped by opcode, each group in index order (`by_op[op_at[o]..op_at[o + 1]]`),
    // and the instructions of the opcodes a pass reads (`scan_ops`).
    op_at: Vector<u32>,
    by_op: Vector<u32>,
    op_cur: Vector<u32>,
    scan: Vector<u32>,
    // `block_ops`, once per `folds` (`iblk_ok`): per instruction, its block (NONE: none), and whether the
    // blocks hold ascending ranges.
    iblk: Vector<u32>,
    iblk_ok: bool,
    iblk_asc: bool,
    // `entry_partner`'s search, once per loop header (`ep_head`; NONE: none yet): per value index the
    // generation (`ep_gen`) of the last header whose reached blocks read it (`ep_read`), and the blocks seen.
    ep_read: Vector<u32>,
    ep_gen: u32,
    ep_head: u32,
    ep_seen: Vector<bool>,
    // Per block, the first layout position a block it reaches has (`reach_min`; NONE: none laid out), once
    // `ep_min_ok`.
    ep_min: Vector<u32>,
    ep_min_ok: bool,
    // `dead_past` (`pasts`, once `past_ok`): per instruction its bit (NONE: none), for the ones with a
    // caller-saved home or a segment whose range holds a rare block; per layout position, `past_w` words
    // of those bits: the ones live into its block (`past_in`) and the ones it defines (`past_def`).
    past_id: Vector<u32>,
    past_in: Vector<u64>,
    past_def: Vector<u64>,
    past_w: u32,
    past_ok: bool,
    wpos: Vector<u32>, // per block parameter, the last layout position of a block whose edge writes it, NONE: none
    wn: Vector<u32>, // per block parameter, how many edges write it
    pub(package) flag_of: Vector<u32>, // per instruction, the value index of its flag, NONE when none is used
    /// The edges whose moves the generator places in a stub past the last block (`late_edges`): source
    /// block << 32 | edge.
    pub(package) late: Vector<u64>,
    /// The largest access a scaled index addresses (the target's, 0: none); per instruction, whether the
    /// load or store takes its address `ptradd`'s operands (`fold`), and whether the `ptradd` emits nothing
    /// for that (`pfold`; `uses_at`).
    pub(package) fold_max: u32,
    /// With `FOLD_PRED`: every masked access may take an SVE predicate (the body has SVE), not only those
    /// that run where the processor has it (`VOP_PRED`).
    pub(package) pred_all: bool,
    pub(package) fold: Vector<bool>,
    pub(package) pfold: Vector<bool>,
    /// Per instruction, a truncation to 8 or 16 bits that comparisons alone read, more than one, under
    /// `FOLD_TRUNC_ONCE`: it is made extended, so no reader extends it.
    pub(package) xtrunc: Vector<bool>,
    /// Per instruction, the value it is a view of (`FOLD_VIEW`; no view itself), else VNONE; empty when no
    /// instruction is one. A view has the value index of that value (`vix`).
    pub(package) view: Vector<Value>,
    /// Per instruction, whether a zero extension is a view of it; empty when of none.
    pub(package) wide: Vector<bool>,
    pub(package) sunk: Vector<bool>, // per instruction, a store computes it after its address (`FOLD_SINK`)
    pub(package) carry: Vector<u8>, // per instruction, its CARRY_* part of a `FOLD_ADC` sum
    /// Per instruction, the comparisons of the `and` or `or` of flags it is when `FOLD_CCMP` folds them into
    /// conditional comparisons (`folds`), else 0.
    pub(package) conj: Vector<u8>,
    /// Stores whose value a call takes in place of memory (the generator's, before `run`): per
    /// instruction, a relayed store's call, else NONE (empty: none); `relayed`, call << 32 | store for each
    /// store whose value the call reads. A relayed store reads nothing; its call reads those values
    /// (`uses_at`).
    pub(package) relay: Vector<u32>,
    pub(package) relayed: Vector<u64>,
    /// Per instruction, the first of its entries in `relayed`, NONE for none (empty without any): a call's
    /// entries are adjacent (`relayed_of`).
    pub(package) relay_lo: Vector<u32>,
    /// The instructions that fold into their uses (`FOLD_*`, the target's): each use computes the folded
    /// instruction from its operands, which live to it (`uses_at`), and the instruction emits nothing
    /// (`pfold`).
    pub(package) fold_ops: u64,
    /// Whether the result of a `three_op` may take the register of any operand that ends there (`over`):
    /// the target's instructions name their result apart from their operands and its generator reads
    /// every operand before it writes the result (arm64), or its generator writes the result over the
    /// operand that holds the plan's register when the instruction allows (`two`). Not by default.
    pub(package) three: bool,
    /// With `three`: the target's instructions write over an operand (x86-64), so only an operand the
    /// instruction may be written over gives its register (`two_op`: either one of an operation that
    /// commutes, a select's side, a sum of addresses, a load's address).
    pub(package) two: bool,
    /// Per entry parameter (the first 64), whether the aggregate it points to arrives in memory (by reference
    /// or on the stack, as the body's calling convention passes it): its loads read memory, which an operation
    /// may read in their place (`FOLD_LDOP`). None by default.
    pub(package) mem_params: u64,
    /// The size of the largest aggregate result a call of the target returns in registers, which the
    /// generator may take from them (`result_load`); a larger one comes back in memory. All by default.
    pub(package) ret_regs: u32,
    /// Whether the calling convention has the caller extend 8- and 16-bit arguments to 32 bits by their
    /// signedness (Apple arm64), so their registers' low 32 bits are their values extended.
    pub(package) ext_args: bool,
    /// Whether the code generator emits each block where reverse postorder puts it (wasm's structured
    /// code): then no block is rare to the layout, and no range stretches to a rare block placed last.
    pub(package) in_place: bool,
    cnd: Vector<u32>, // `folds`' scratch: per instruction, its uses as a condition
    andu: Vector<u32>, // `folds`' scratch: per instruction, its uses as an operand of a narrow `and`
    xuse: Vector<u8>, // `ext_uses`' scratch
    // `plan`'s scratch: per layout position its first instruction's ordinal; per block its frequency; per
    // value its range's first and last ordinals, its weight and its uses by instructions and edges; the
    // candidates by start, the values holding a register, and the count per file and home.
    base: Vector<u32>,
    freq: Vector<u64>, // per block, `frequencies`
    // `frequencies`: per block, what its entering edges bring; per reverse postorder number, its block; a
    // terminator's edges.
    fmass: Vector<u64>,
    fby: Vector<u32>,
    fedges: Vector<u32>,
    start: Vector<u32>,
    stop: Vector<u32>,
    wt: Vector<u64>,
    au: Vector<u32>,
    cand: Vector<u64>,
    cnt: Vector<u32>,
    /// Register segments (`assign`): a value holds its register over the layout positions `seg_a..=seg_b`,
    /// in the blocks that list it; in the others it is in its stack home. Per layout position, the segments
    /// whose value is in its register in that block: `sin[sin_at[q]..sin_at[q + 1]]`.
    pub(package) seg_x: Vector<u32>,
    pub(package) seg_a: Vector<u32>,
    pub(package) seg_b: Vector<u32>,
    pub(package) sin_at: Vector<u32>,
    pub(package) sin: Vector<u32>,
    /// Per value (empty: no segment), whether it has a segment, whether a block of its range is outside
    /// them all (it then keeps a stack home, written once, where it is defined), and whether its register
    /// is a caller-saved one it holds over all of its live blocks, across calls: each such call saves the
    /// register around itself.
    pub(package) segd: Vector<bool>,
    pub(package) seg_mem: Vector<bool>,
    pub(package) seg_past: Vector<bool>,
    /// Per segment its register (the generator's number), and per layout position the registers that hold
    /// a value of the plan somewhere in its block.
    pub(package) seg_r: Vector<u8>,
    pub(package) bmask: Vector<u64>,
    /// Per layout position, the registers of `bmask` that one value alone holds in the block and no edge
    /// out of the block writes: when that value ends there, a temporary may take its register.
    pub(package) solo: Vector<u64>,
    // `seg_lists`'s scratch: per layout position, the registers more than one value holds or an edge writes.
    multi: Vector<u64>,
    /// Per value (the generator's, before `assign`; empty: none), the register an instruction reads it in
    /// (the result's register for a returned value), REG_NONE for none: the plan gives it that one when it
    /// can.
    pub(package) rhint: Vector<u8>,
    /// Per instruction (the generator's, before `assign`; empty: none), the argument a call writes its
    /// result over (an intrinsic's template that writes the register both arrive in, which the generator
    /// renames when the argument ends there: `over`), NONE for none.
    pub(package) cover: Vector<u32>,
    /// Per value (the generator's, before `assign`; empty: none), the register a load of one part of an
    /// aggregate the body takes in registers finds its value in (`place::parts_taken`), REG_NONE for
    /// another value: the plan leaves it there when it can, as a parameter of the signature (`arr`).
    pub(package) part_in: Vector<u8>,
    /// The `part_in` registers nothing writes before their loads' ranges end (as `assign`'s `quiet`).
    pub(package) part_quiet: u64,
    /// Bit `k` when nothing writes the one register parameter `k` of the signature arrives in, in the
    /// blocks outside `after` (the generator's, as `assign`'s `quiet`): a parameter that holds one
    /// register there and another in the blocks of `after` may stay in it (`frame_put`).
    pub(package) quiet_out: u64,
    // `assign`'s scratch: per value its last segment and per segment the value's one before (`vseg`,
    // `vnext`); per layout position the registers held through the whole
    // block (`thru`), and per position of an instruction's reads and of its result (two per instruction)
    // the registers held there by a value that begins or ends in the block (`part`); the candidate's live
    // blocks (`lblk`, in layout order), with per layout position the stamps of the candidate live into the
    // block (`lin`), out of it (`lout`), read in it (`lrd`), of the segment that keeps it in its register
    // there (`lsel`, a stamp per segment: `sgen`), and the
    // block's entry in `lblk` (`lix`); per entry of `lblk` the positions it holds a register at (`llo`,
    // `lhi`), the registers free for it (`lav`), how often the block loads it without one (`lnow`), and
    // `spans`' groups (`lcomp`, `lgain`, `lcost`, `lbad`), kept blocks (`lkeep`) and best ones (`lbest`);
    // per entry of `su` the block's last instruction that reads the value (`sul`); the registers that save
    // moves (`hq`); per register, the last position a parameter that arrived in it holds it (`arr_hi`).
    vseg: Vector<u32>,
    vnext: Vector<u32>,
    sgen: u32,
    // What a callee-saved register the body does not save yet costs the value that takes it (`assign`):
    // SAVE_COST, less in a body that sets its frame up on the edges into the blocks of `after` alone.
    save: u64,
    thru: Vector<u64>,
    part: Vector<u64>,
    lblk: Vector<u32>,
    lin: Vector<u32>,
    lout: Vector<u32>,
    lrd: Vector<u32>,
    lsel: Vector<u32>,
    lix: Vector<u32>,
    llo: Vector<u32>,
    lhi: Vector<u32>,
    lav: Vector<u64>,
    lnow: Vector<u64>,
    lcomp: Vector<u32>,
    lgain: Vector<u64>,
    lcost: Vector<u64>,
    lbad: Vector<bool>,
    lkeep: Vector<bool>,
    lbest: Vector<bool>,
    sul: Vector<u32>,
    hq: Vector<u64>,
    // `assign`: per value, the weight that orders it: its own (`wt`); a block parameter's is no less than
    // that of the step that replaces it after a call. Per layout position, the blocks with a call before.
    kw: Vector<u64>,
    kc: Vector<u32>,
    arr_of: Vector<u64>, // `assign`: per parameter of the signature, the registers it arrives in (`arr`)
    arr_hi: Vector<u32>,
    // `evict`: per register the last segment that took it and per segment the one before (`rhead`, `rnext`);
    // the holder's blocks that read it and the ones it leaves, by stamp (`emark`, `egen`); the blocks the
    // holder at hand and the best one leave (`ev`, `evb`).
    rhead: Vector<u32>,
    rnext: Vector<u32>,
    emark: Vector<u32>,
    egen: u32,
    ev: Vector<u32>,
    evb: Vector<u32>,
    rsig: Vector<u64>, // `assign`: per register, a hash of the candidate's blocks it is free in
    rtop: Vector<u64>, // `assign`: per register, how often those blocks load the candidate (the most it gains)
    rdone: Vector<u64>, // the hashes of the registers `spans` tried for the candidate
    /// Per layout position (the generator's; empty: no segments), the first and the last instruction of its
    /// block that write the caller-saved homes (a call that returns), NONE for none.
    pub(package) cfirst: Vector<u32>,
    pub(package) clast: Vector<u32>,
    /// Per instruction index and past the last (the generator's; empty: none), the instructions before it
    /// that write the caller-saved homes (`cfirst`): the calls a value lives across are counted from it.
    /// `wcount`: the same for the instructions that write the argument registers (`wfirst`).
    pub(package) ccount: Vector<u32>,
    pub(package) wcount: Vector<u32>,
    /// As `cfirst` and `clast` for the instructions that write an argument register a home could not keep (a
    /// call that returns in a warm block, an intrinsic's too; a system operation; a variadic access; a
    /// thread-local getter): a block without one may hold a value in such a register (`Sets.xw`). Empty: the target has none.
    pub(package) wfirst: Vector<u32>,
    pub(package) wlast: Vector<u32>,
    // `assign`'s scratch: the candidates (`scand`), per candidate its reading blocks' positions
    // (`su[su_at[x]..su_at[x + 1]]`), and per segment the blocks of its span that hold it (`gpool` from
    // `seg_at`).
    scand: Vector<bool>,
    smark: Vector<u32>,
    su_at: Vector<u32>,
    su: Vector<u32>,
    gpool: Vector<bool>,
    seg_at: Vector<u32>,
    kept: Vector<bool>, // per value, whether a loop keeps it past its last use (`run`)
    /// Per layout position, the general registers `assign` may give out at once in that block (`Caps.xj`
    /// everywhere when empty).
    pub(package) jcap: Vector<u32>,
    /// Per layout position, the general caller-saved registers `assign` may give out at once in that block
    /// (`Caps.xs` everywhere when empty).
    pub(package) scap: Vector<u32>,
    pub(package) rpo: Vector<u32>, // per block, its reverse postorder number (NONE: unreachable)
    succ: Vector<u32>,
    stack: Vector<u32>,
    work: Vector<u32>,
    /// Per instruction of the body, its use count: operands, call and vector arguments, edge arguments (`folds`).
    pub(package) count: Vector<u32>,
    keys: Vector<u64>,
    rd: Vector<Value>, // `reads_after`'s scratch
    ru: Vector<Value>, // `ranges`' scratch
}

extend Live {
    pub(package) fn new() Live {
        return Live {
            order: Vector::<u32>::new(),
            pos: Vector::<u32>::new(),
            npred: Vector::<u32>::new(),
            inner: Vector::<u32>::new(),
            lend: Vector::<u32>::new(),
            parent: Vector::<u32>::new(),
            rare: Vector::<bool>::new(),
            after: Vector::<bool>::new(),
            def_blk: Vector::<u32>::new(),
            end: Vector::<u32>::new(),
            uses: Vector::<u32>::new(),
            last: Vector::<u32>::new(),
            wpos: Vector::<u32>::new(),
            wn: Vector::<u32>::new(),
            flag_of: Vector::<u32>::new(),
            late: Vector::<u64>::new(),
            fold_max: 0,
            pred_all: false,
            fold: Vector::<bool>::new(),
            pfold: Vector::<bool>::new(),
            xtrunc: Vector::<bool>::new(),
            view: Vector::<Value>::new(),
            wide: Vector::<bool>::new(),
            sunk: Vector::<bool>::new(),
            carry: Vector::<u8>::new(),
            conj: Vector::<u8>::new(),
            relay: Vector::<u32>::new(),
            relayed: Vector::<u64>::new(),
            relay_lo: Vector::<u32>::new(),
            fold_ops: 0,
            three: false,
            two: false,
            mem_params: 0,
            ret_regs: NONE,
            ext_args: false,
            in_place: false,
            cnd: Vector::<u32>::new(),
            andu: Vector::<u32>::new(),
            xuse: Vector::<u8>::new(),
            base: Vector::<u32>::new(),
            freq: Vector::<u64>::new(),
            start: Vector::<u32>::new(),
            stop: Vector::<u32>::new(),
            wt: Vector::<u64>::new(),
            au: Vector::<u32>::new(),
            cand: Vector::<u64>::new(),
            cnt: Vector::<u32>::new(),
            seg_x: Vector::<u32>::new(),
            seg_a: Vector::<u32>::new(),
            seg_b: Vector::<u32>::new(),
            sin_at: Vector::<u32>::new(),
            sin: Vector::<u32>::new(),
            segd: Vector::<bool>::new(),
            seg_mem: Vector::<bool>::new(),
            seg_past: Vector::<bool>::new(),
            cfirst: Vector::<u32>::new(),
            clast: Vector::<u32>::new(),
            ccount: Vector::<u32>::new(),
            wcount: Vector::<u32>::new(),
            wfirst: Vector::<u32>::new(),
            wlast: Vector::<u32>::new(),
            scand: Vector::<bool>::new(),
            smark: Vector::<u32>::new(),
            su_at: Vector::<u32>::new(),
            su: Vector::<u32>::new(),
            gpool: Vector::<bool>::new(),
            seg_at: Vector::<u32>::new(),
            seg_r: Vector::<u8>::new(),
            bmask: Vector::<u64>::new(),
            solo: Vector::<u64>::new(),
            multi: Vector::<u64>::new(),
            rhint: Vector::<u8>::new(),
            cover: Vector::<u32>::new(),
            part_in: Vector::<u8>::new(),
            part_quiet: 0,
            quiet_out: 0,
            vseg: Vector::<u32>::new(),
            vnext: Vector::<u32>::new(),
            sgen: 0,
            save: SAVE_COST,
            thru: Vector::<u64>::new(),
            part: Vector::<u64>::new(),
            lblk: Vector::<u32>::new(),
            lin: Vector::<u32>::new(),
            lout: Vector::<u32>::new(),
            lrd: Vector::<u32>::new(),
            lsel: Vector::<u32>::new(),
            lix: Vector::<u32>::new(),
            llo: Vector::<u32>::new(),
            lhi: Vector::<u32>::new(),
            lav: Vector::<u64>::new(),
            lnow: Vector::<u64>::new(),
            lcomp: Vector::<u32>::new(),
            lgain: Vector::<u64>::new(),
            lcost: Vector::<u64>::new(),
            lbad: Vector::<bool>::new(),
            lkeep: Vector::<bool>::new(),
            lbest: Vector::<bool>::new(),
            sul: Vector::<u32>::new(),
            hq: Vector::<u64>::new(),
            kw: Vector::<u64>::new(),
            kc: Vector::<u32>::new(),
            arr_of: Vector::<u64>::new(),
            arr_hi: Vector::<u32>::new(),
            rhead: Vector::<u32>::new(),
            rnext: Vector::<u32>::new(),
            emark: Vector::<u32>::new(),
            egen: 0,
            ev: Vector::<u32>::new(),
            evb: Vector::<u32>::new(),
            rsig: Vector::<u64>::new(),
            rtop: Vector::<u64>::new(),
            rdone: Vector::<u64>::new(),
            kept: Vector::<bool>::new(),
            sole: Vector::<u32>::new(),
            rlast: Vector::<u32>::new(),
            op_at: Vector::<u32>::new(),
            by_op: Vector::<u32>::new(),
            op_cur: Vector::<u32>::new(),
            scan: Vector::<u32>::new(),
            iblk: Vector::<u32>::new(),
            iblk_ok: false,
            iblk_asc: false,
            ep_read: Vector::<u32>::new(),
            ep_gen: 0,
            ep_head: NONE,
            ep_seen: Vector::<bool>::new(),
            ep_min: Vector::<u32>::new(),
            ep_min_ok: false,
            past_id: Vector::<u32>::new(),
            past_in: Vector::<u64>::new(),
            past_def: Vector::<u64>::new(),
            past_w: 0,
            past_ok: false,
            jcap: Vector::<u32>::new(),
            scap: Vector::<u32>::new(),
            fmass: Vector::<u64>::new(),
            fby: Vector::<u32>::new(),
            fedges: Vector::<u32>::new(),
            rpo: Vector::<u32>::new(),
            succ: Vector::<u32>::new(),
            stack: Vector::<u32>::new(),
            work: Vector::<u32>::new(),
            count: Vector::<u32>::new(),
            keys: Vector::<u64>::new(),
            rd: Vector::<Value>::new(),
            ru: Vector::<Value>::new(),
            ua: Vector::<u32>::new(),
            pat: Vector::<u32>::new(),
            preds: Vector::<u32>::new(),
            un: Vector::<u32>::new(),
            uv: Vector::<Value>::new(),
            next: Vector::<u32>::new(),
            use_next: Vector::<u32>::new(),
        };
    }

    /// The value index of `v`.
    pub(package) const fn vix(self: &Self, b: &Body, v: Value) u32 {
        if (v & VPARAM) != 0 {
            return b.insts.len() as u32 + (v & ~VPARAM);
        }
        if (v & VFLAG) != 0 {
            return self.flag_of[(v & ~VFLAG) as usize];
        }
        if v as usize < self.view.len() && self.view[v as usize] != VNONE {
            let r = self.view[v as usize];
            return ast::pick((r & VPARAM) != 0, b.insts.len() as u32 + (r & ~VPARAM), r);
        }
        return v;
    }

    /// Whether a zero extension is a view of value index `x` (`wide`): its register and its home hold zeros
    /// above its bits, up to 64.
    pub(package) const fn wide_at(self: &Self, x: u32) bool {
        return x as usize < self.wide.len() && self.wide[x as usize];
    }

    /// Argument `j` of edge `ed` of `b`, as a read of it reads it (`seen`).
    pub(package) const fn arg(self: &Self, b: &Body, ed: u32, j: u32) Value {
        return self.seen(b.edge_arg(ed, j));
    }

    /// The value a read of `v` reads: the one `v` is a view of (`view`), else `v`.
    pub(package) const fn seen(self: &Self, v: Value) Value {
        return if (v & (VPARAM | VFLAG)) == 0 && v as usize < self.view.len() && self.view[v as usize] != VNONE {
            self.view[v as usize]
        } else {
            v
        };
    }

    /// Whether the block at layout position `q` of `b` keeps the register state: its only predecessor is
    /// the block before it in the layout.
    pub(package) const fn continues(self: &Self, b: &Body, q: u32) bool {
        if q == 0 {
            return true;
        }
        let k = self.order[q as usize];
        if self.npred[k as usize] != 1 {
            return false;
        }
        let pb = b.blocks[self.order[q as usize - 1] as usize];
        let t = b.insts[(pb.start + pb.len - 1) as usize];
        let ne = edge_count(t);
        for e in 0..ne {
            if b.edge_target(edge_of(b, t, e)) == k {
                return true;
            }
        }
        return false;
    }

    /// Value index `x`'s uses less the edges that write it (a block parameter's).
    pub(package) const fn reads(self: &Self, x: u32) u32 {
        return self.uses[x as usize] - self.wn[x as usize];
    }

    /// Analyze `b`: `analyze`, then the layout and the live ranges (`relayout`).
    pub(package) fn run(self: &mut Self, b: &Body) {
        self.analyze(b);
        self.relayout(b);
    }

    /// `run` but the layout and the live ranges, which a generator makes once it chose the blocks laid out
    /// last (`after`): the reverse postorder, the rare blocks, the loops, the block frequencies, the folds
    /// and `def_blk`.
    pub(package) fn analyze(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        fill(&mut self.npred, nb, 0);
        fill(&mut self.rpo, nb, NONE);
        fill(&mut self.inner, nb, NONE);
        fill(&mut self.parent, nb, NONE);
        self.reverse_postorder(b);
        for k in 0..nb {
            if self.rpo[k] == NONE {
                continue;
            }
            let t = b.insts[(b.blocks[k].start + b.blocks[k].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                self.npred[b.edge_target(self.succ[e]) as usize] += 1;
            }
        }
        self.rare_blocks(b);
        self.loops(b);
        self.frequencies(b);
        self.folds(b);
        self.def_blocks(b, b.insts.len() + b.params.len());
    }

    // `def_blk` for the `n` value indexes of `b`: each instruction's and block parameter's block (NONE for
    // the others, a used flag's).
    fn def_blocks(self: &mut Self, b: &Body, n: usize) {
        fill(&mut self.def_blk, n, NONE);
        let ni = b.insts.len();
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                self.def_blk[i as usize] = k as u32;
            }
            for q in 0..bk.param_len as u32 {
                self.def_blk[ni + (bk.param_start + q) as usize] = k as u32;
            }
        }
    }

    /// The layout of `b` and the live ranges again, for another `after`: the rest of `run`'s analysis stands.
    pub(package) fn relayout(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        fill(&mut self.lend, nb, 0);
        fill(&mut self.pos, nb, NONE);
        self.layout(b);
        self.late_edges(b);
        self.ranges(b);
    }

    // The edges whose moves wait in a stub past the last block, which then jumps to the target (`late`):
    // each passes only integer and float constants, from a warm block laid out before a loop to a warm block
    // laid out after it that an edge from a block laid out between them, with no loop after that block,
    // reaches too (its parameters take their homes there). The target's parameters then start their ranges
    // after the loop (`plan`) in place of holding registers across it.
    fn late_edges(self: &mut Self, b: &Body) {
        self.late.truncate(0);
        let np = self.order.len();
        // Per layout position, the least last position of a loop whose header is there or later.
        let mut close = Vector::<u32>::with_capacity(np + 1);
        fill(&mut close, np + 1, NONE);
        for q0 in 0..np {
            let q = np - 1 - q0;
            let h = self.order[q];
            close[q] = close[q + 1];
            if self.inner[h as usize] == h {
                close[q] = close[q].min(self.lend[h as usize]);
            }
        }
        for q in 0..np {
            let p = self.order[q];
            if self.rare[p as usize] || close[q + 1] == NONE {
                continue;
            }
            let t = term(b, p);
            let ne = jb_edges(t);
            for e in 0..ne {
                let ed = edge_of(b, t, e);
                let j = b.edge_target(ed);
                let pj = self.pos[j as usize];
                if b.edge_nargs(ed) == 0 || pj == NONE || pj <= q as u32 || self.rare[j as usize] || close[q + 1] >= pj || ne == 2 && b.edge_target(
                    edge_of(b, t, 1 - e),
                ) == j {
                    continue;
                }
                let mut ok = true;
                for a in 0..b.edge_nargs(ed) {
                    let v = b.edge_arg(ed, a);
                    ok = ok && (v & (VPARAM | VFLAG)) == 0 && (b.insts[v as usize].op == O_ICONST || b.insts[v as usize].op == O_FCONST);
                }
                let mut other = false;
                for x in self.pat[j as usize]..self.pat[j as usize + 1] {
                    let pq = self.pos[self.preds[x as usize] as usize];
                    other = other || pq != NONE && pq > q as u32 && pq < pj && close[pq as usize + 1] >= pj;
                }
                if ok && other {
                    self.late.push(p as u64 << 32 | ed as u64);
                }
            }
        }
    }

    /// The target of block `k`'s late edge (`late`), NONE when it has none.
    pub(package) const fn late_target(self: &Self, b: &Body, k: u32) u32 {
        for q in 0..self.late.len() {
            if (self.late[q] >> 32) as u32 == k {
                return b.edge_target(self.late[q] as u32);
            }
        }
        return NONE;
    }

    /// The index in `late` of edge `e` of block `k`'s terminator (blocks may share an edge's record), NONE
    /// when it is not late.
    pub(package) const fn late_index(self: &Self, k: u32, e: u32) u32 {
        let key = k as u64 << 32 | e as u64;
        for q in 0..self.late.len() {
            if self.late[q] == key {
                return q as u32;
            }
        }
        return NONE;
    }

    // `fold`: a load or store of no offset whose address is a `ptradd` with an index, no offset, a scale
    // of 1 or the access's size (up to `fold_max`) and this one use, takes the `ptradd`'s operands as its
    // address (`ldr x0, [x1, x2, lsl #3]`, `mov (%rax,%rcx,8), %rdx`): they live to the access.
    //
    // The other instructions fold as `fold_ops` lets them (`FOLD_*`).
    // Whether index `v` of `b` is the 64-bit extension `FOLD_XIDX` folds into its one access.
    const fn ext_index(self: &Self, b: &Body, v: Value) bool {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || self.count[v as usize] != 1 || self.pfold[v as usize] {
            return false;
        }
        let t = b.insts[v as usize];
        if t.op != O_ZEXT && t.op != O_SEXT || t.ty != T_I64 {
            return false;
        }
        let ft = b.type_of(t.a);
        if ft == T_I32 {
            return true;
        }
        // An unsigned entry parameter of 8 or 16 bits the caller zero-extended.
        if !self.ext_args || t.op != O_ZEXT || ft != T_I8 && ft != T_I16 || (t.a & VPARAM) == 0 {
            return false;
        }
        let k = (t.a & ~VPARAM) as usize;
        let np = b.pool[b.sig as usize] as usize;
        return k < np && b.blocks[0].param_start == 0 && (b.pool[b.sig as usize + 3 + k] & (SIG_SEXT | AGG)) == 0;
    }

    // `FOLD_SINC`: a select of a value and its sum with 1 (either side), that sum read only there, folds the sum
    // in (`inc_side`).
    fn select_incs(self: &mut Self, b: &Body) {
        if (self.fold_ops & FOLD_SINC) == 0 {
            return;
        }
        self.scan_ops([O_SELECT]);
        for q in 0..self.scan.len() {
            let i = self.scan[q] as usize;
            let t = b.insts[i];
            if t.op != O_SELECT || t.ty != T_I32 && t.ty != T_I64 {
                continue;
            }
            let s = inc_side(b, t);
            let x = ast::pick(s == 1, t.b, t.c);
            if s != 0 && self.count[x as usize] == 1 && !self.pfold[x as usize] {
                self.pfold[x as usize] = true;
            }
        }
    }

    // `FOLD_SHAMT`: a 32- or 64-bit shift's count that an `and` with the width's mask (`& 31`, `& 63`) makes,
    // read only there, folds into the shift, which takes the count modulo the width.
    // `FOLD_SINK`: the values stores, selects, extensions and integer operations compute where they read
    // them (`sinkable`): a store's value, a select's sides and its folded comparison's operands, the narrow
    // load an unfolded sign extension or zero extension to 64 bits reads (one extending load), an operation's
    // second operand past a first that stays (which the set and get of `stack_values` cannot keep on the
    // stack: the first operand comes between); a vector shift's count stays (one not the same in every lane
    // makes the shift go through memory).
    fn sinks(self: &mut Self, b: &Body) {
        if (self.fold_ops & FOLD_SINK) == 0 {
            return;
        }
        let mut moved = Vector::<Value>::new();
        let mut us = Vector::<Value>::new();
        for k in 0..b.blocks.len() {
            if self.rpo[k] == NONE {
                continue;
            }
            let bk = b.blocks[k];
            for s in bk.start..bk.start + bk.len {
                let st = b.insts[s as usize];
                moved.truncate(0);
                if st.op == O_STORE {
                    self.sink(b, st.b, bk.start, s, &mut moved);
                } else if (st.op == O_SUB || st.op >= O_SHL && st.op <= O_ASHR || st.op == O_ADD || st.op == O_MUL || st.op >= O_AND && st.op <= O_XOR) && (is_int(
                    st.ty,
                ) || is_vec(st.ty) && (self.fold_ops & FOLD_VSINK) != 0 && (st.op < O_SHL || st.op > O_ASHR)) && st.ty != T_I128 && !self.pfold[s as usize] && self.stays(
                    b,
                    st.a,
                ) {
                    // A shift reads its count past a folded mask (`shift_amount`).
                    let sb = if st.op >= O_SHL && st.op <= O_ASHR {
                        shift_amount(b, &self.pfold, st.b)
                    } else {
                        self.read_of(b, st.b)
                    };
                    self.sink(b, sb, bk.start, s, &mut moved);
                } else if (st.op == O_SEXT || st.op == O_ZEXT && st.ty == T_I64) && !self.pfold[s as usize] && narrow_load(
                    b,
                    st.a,
                ) {
                    self.sink(b, st.a, bk.start, s, &mut moved);
                } else if st.op == O_SELECT && is_int(st.ty) && st.ty != T_I128 {
                    self.sink(b, st.b, bk.start, s, &mut moved);
                    self.sink(b, st.c, bk.start, s, &mut moved);
                    if (st.a & (VPARAM | VFLAG)) == 0 && self.pfold[st.a as usize] && b.insts[st.a as usize].op == O_ICMP {
                        let c = b.insts[st.a as usize];
                        self.sink(b, c.a, bk.start, s, &mut moved);
                        self.sink(b, c.b, bk.start, s, &mut moved);
                    }
                }
                // A narrow load that an extension folded into this reader extends (`FOLD_WIDEN`) moves with it.
                if (self.fold_ops & FOLD_WIDEN) != 0 {
                    each_use(b, st, &mut us);
                    for q in 0..us.len() {
                        let x = us[q];
                        if is_inst(x) && self.pfold[x as usize] && (b.insts[x as usize].op == O_SEXT || b.insts[x as usize].op == O_ZEXT) && narrow_load(
                            b,
                            b.insts[x as usize].a,
                        ) {
                            self.sink(b, b.insts[x as usize].a, bk.start, s, &mut moved);
                        }
                    }
                }
                // The reader's folded instructions stay within FOLD_DEPTH (`uses_at`), else nothing moves.
                if moved.len() != 0 && self.fold_count(b, s, &mut us) > FOLD_DEPTH {
                    for q in 0..moved.len() {
                        self.pfold[moved[q] as usize] = false;
                        self.sunk[moved[q] as usize] = false;
                    }
                }
            }
        }
    }

    // Value `v` and the operands it moves with, when it may move to instruction `s` (`sinkable`): each one in
    // `moved`.
    fn sink(self: &mut Self, b: &Body, v: Value, lo: u32, s: u32, moved: &mut Vector<Value>) {
        if self.sinkable(b, v, lo, s, SINK_DEPTH) {
            self.mark_sunk(b, v, lo, moved);
        }
    }

    // Value `v`, which `sinkable` allows, and the operands it moves with (those not `fixed`, each `sinkable`
    // one level less deep): each one sunk, in `moved`.
    fn mark_sunk(self: &mut Self, b: &Body, v: Value, lo: u32, moved: &mut Vector<Value>) {
        self.pfold[v as usize] = true;
        self.sunk[v as usize] = true;
        moved.push(v);
        let t = b.insts[v as usize];
        // A load's and a pointer sum's last field is an offset, not a value.
        let ob = ast::pick(t.op == O_LOAD, VNONE, t.b);
        let oc = ast::pick(t.op == O_SELECT, t.c, VNONE);
        for o in [t.a, ob, oc] {
            if o != VNONE && !self.fixed(b, o, lo) {
                self.mark_sunk(b, o, lo, moved);
            }
        }
    }

    // The folded instructions `uses_at` expands in instruction `s`'s uses (`us` its scratch), at most one past
    // FOLD_DEPTH.
    fn fold_count(self: &Self, b: &Body, s: u32, us: &mut Vector<Value>) u32 {
        each_use(b, b.insts[s as usize], us);
        let mut n: u32 = 0;
        let mut u: usize = 0;
        // Each step reads one use; a folded one counts and leaves its operands in its place.
        while u < us.len() && n <= FOLD_DEPTH {
            let v = us[u];
            if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || !self.pfold[v as usize] {
                u += 1;
                continue;
            }
            n += 1;
            let p = b.insts[v as usize];
            us.swap_remove(u);
            if p.op == O_SPLAT && is_inst(p.a) && self.pfold[p.a as usize] {
                us.push(p.a);
            } else if p.op == O_VOP {
                for q in 0..p.b {
                    us.push(b.pool[(p.a + q) as usize]);
                }
            } else if p.op != O_SPLAT && p.op != O_WCONST {
                us.push(p.a);
                if p.b != VNONE && p.op != O_LOAD {
                    us.push(p.b);
                }
                if p.op == O_SELECT {
                    us.push(p.c);
                }
            }
        }
        return n;
    }

    // Whether value `v` may move to instruction `s` of the block from `lo` (`FOLD_SINK`): one instruction there
    // that only `s` reads, a load or an operation whose operands are `fixed` or, `depth` above 1, such values
    // one level less deep. A vector of at most 16 bytes moves under `FOLD_VSINK`.
    fn sinkable(self: &Self, b: &Body, v: Value, lo: u32, s: u32, depth: u32) bool {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || v < lo || v >= s || self.count[v as usize] != 1 || self.pfold[v as usize] {
            return false;
        }
        let t = b.insts[v as usize];
        let fl = t.ty == T_F32 || t.ty == T_F64;
        let n = type_bytes(t.ty, 8);
        let vec = is_vec(t.ty) && (self.fold_ops & FOLD_VSINK) != 0 && (n == 4 || n == 8 || n == 16);
        if !is_int(t.ty) && !fl && !vec && !(t.op == O_PTRADD && t.ty == T_PTR) || t.ty == T_I128 {
            return false;
        }
        let deep = depth > 1;
        if t.op == O_LOAD {
            if (t.aux & MEM_VOLATILE) != 0 || !self.fixed(b, t.a, lo) && !(deep && self.sinkable(
                b,
                t.a,
                lo,
                s,
                depth - 1,
            )) {
                return false;
            }
            for j in v + 1..s {
                if writes_memory(b.insts[j as usize]) {
                    return false;
                }
            }
            return true;
        }
        let un = t.op == O_NEG || t.op == O_NOT || t.op >= O_CLZ && t.op <= O_POPCNT || t.op == O_FNEG || t.op == O_FSQRT;
        let sel = t.op == O_SELECT;
        // An integer comparison as a value (0 or 1).
        let cmp = t.op == O_ICMP && (is_int(b.type_of(t.a)) || b.type_of(t.a) == T_PTR) && b.type_of(t.a) != T_I128;
        let fop = t.op >= O_FADD && t.op <= O_FDIV;
        let pa = t.op == O_PTRADD;
        // A float value: a float operation or a select. A vector: lane arithmetic.
        if fl && !fop && !sel && t.op != O_FNEG && t.op != O_FSQRT {
            return false;
        }
        if vec && !fop && t.op != O_FNEG && t.op != O_FSQRT && t.op != O_ADD && t.op != O_SUB && t.op != O_MUL && t.op != O_NEG && t.op != O_NOT && (t.op < O_AND || t.op > O_XOR) {
            return false;
        }
        if !un && !sel && !fop && !pa && !cmp && (t.op < O_ADD || t.op > O_ASHR || t.op >= O_SDIV && t.op <= O_UREM) {
            return false;
        }
        let ok_a = self.fixed(b, t.a, lo) || deep && self.sinkable(b, t.a, lo, s, depth - 1);
        let ok_b = un || pa && t.b == VNONE || self.fixed(b, t.b, lo) || deep && self.sinkable(b, t.b, lo, s, depth - 1);
        return ok_a && ok_b && (!sel || self.fixed(b, t.c, lo) || deep && self.sinkable(b, t.c, lo, s, depth - 1));
    }

    // The value a read of `v` reads: past a folded extension or truncation of one read (each read of it reads
    // its operand: `FOLD_FREE_ZEXT`, `FOLD_WIDEN`).
    const fn read_of(self: &Self, b: &Body, v: Value) Value {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || !self.pfold[v as usize] || self.count[v as usize] != 1 {
            return v;
        }
        let t = b.insts[v as usize];
        return ast::pick(t.op == O_ZEXT || t.op == O_TRUNC, t.a, v);
    }

    // Whether value `v` is where a value moved within the block from `lo` reads it: it `stays`, or another
    // block defines it (in its local).
    const fn fixed(self: &Self, b: &Body, v: Value, lo: u32) bool {
        return self.stays(b, v) || (v & (VPARAM | VFLAG)) == 0 && v != VNONE && v < lo;
    }

    // Whether value `v` is read where it is (`sinkable`): a parameter, a constant or an address, a value of
    // more uses, or a folded one.
    const fn stays(self: &Self, b: &Body, v: Value) bool {
        if (v & VPARAM) != 0 {
            return (v & VFLAG) == 0;
        }
        if v == VNONE || (v & VFLAG) != 0 {
            return false;
        }
        let op = b.insts[v as usize].op;
        return op == O_ICONST || op == O_SYMADDR || op == O_SLOTADDR || self.count[v as usize] > 1 || self.pfold[v as usize];
    }

    // `FOLD_WIDEN`: the extensions of 32-bit integers to 64 bits that one instruction of their own block reads.
    fn widenings(self: &mut Self, b: &Body) {
        if (self.fold_ops & FOLD_WIDEN) == 0 {
            return;
        }
        let mut us = Vector::<Value>::new();
        for k in 0..b.blocks.len() {
            if self.rpo[k] == NONE {
                continue;
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                each_use(b, b.insts[i as usize], &mut us);
                for q in 0..us.len() {
                    let x = us[q];
                    if (x & (VPARAM | VFLAG)) != 0 || x == VNONE || x < bk.start || x >= i || self.count[x as usize] != 1 || self.pfold[x as usize] {
                        continue;
                    }
                    let e = b.insts[x as usize];
                    if e.ty != T_I64 || e.op != O_ZEXT && e.op != O_SEXT {
                        continue;
                    }
                    let ft = b.type_of(e.a);
                    if e.op == O_ZEXT && (ft == T_I8 || ft == T_I16 || ft == T_I32) || ft == T_I32 {
                        self.pfold[x as usize] = true;
                    }
                }
            }
        }
    }

    // `FOLD_SHAMT_EXT`, after every fold but the sinks: the integer it reads is one no other fold takes.
    fn count_exts(self: &mut Self, b: &Body) {
        if (self.fold_ops & FOLD_SHAMT_EXT) == 0 {
            return;
        }
        self.scan_ops([O_SHL, O_LSHR, O_ASHR]);
        for q in 0..self.scan.len() {
            let i = self.scan[q] as usize;
            let t = b.insts[i];
            if t.op < O_SHL || t.op > O_ASHR || !is_int(t.ty) || self.pfold[i] || !is_inst(t.b) || !self.pfold[t.b as usize] || b.insts[t.b as usize].op != O_AND {
                continue;
            }
            let z = b.insts[t.b as usize].a;
            if !is_inst(z) || self.pfold[z as usize] || self.count[z as usize] != 1 {
                continue;
            }
            let e = b.insts[z as usize];
            let sty = b.type_of(e.a);
            if e.op != O_ZEXT && e.op != O_SEXT && e.op != O_TRUNC || !is_int(sty) || sty == T_I128 || is_inst(e.a) && (self.pfold[e.a as usize] || b.insts[e.a as usize].op == O_ICONST) {
                continue;
            }
            self.pfold[z as usize] = true;
        }
    }

    // `by_op` and `op_at` for `b` (`folds`).
    fn group_ops(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        self.iblk_ok = false;
        fill(&mut self.op_at, 257, 0);
        for i in 0..ni {
            self.op_at[b.insts[i].op as usize + 1] += 1;
        }
        for o in 0..256usize {
            self.op_at[o + 1] += self.op_at[o];
        }
        fill(&mut self.op_cur, 256, 0);
        fill(&mut self.by_op, ni, 0);
        for i in 0..ni {
            let o = b.insts[i].op as usize;
            self.by_op[(self.op_at[o] + self.op_cur[o]) as usize] = i as u32;
            self.op_cur[o] += 1;
        }
    }

    // `scan`: the instructions of opcode `op` in the blocks, in block order then instruction order, and `iblk`
    // their blocks. When the blocks hold ascending ranges (a rebuilt body's do), that order is the index
    // order of `by_op`; else a walk of the blocks gives it.
    fn block_ops(self: &mut Self, b: &Body, op: u8) {
        if !self.iblk_ok {
            self.iblk_ok = true;
            fill(&mut self.iblk, b.insts.len(), NONE);
            self.iblk_asc = true;
            for k in 0..b.blocks.len() {
                let bk = b.blocks[k];
                self.iblk_asc = self.iblk_asc && (k == 0 || bk.start >= b.blocks[k - 1].start + b.blocks[k - 1].len);
                for i in bk.start..bk.start + bk.len {
                    self.iblk[i as usize] = k as u32;
                }
            }
        }
        self.scan.truncate(0);
        if self.iblk_asc {
            let o = op as usize;
            for j in self.op_at[o]..self.op_at[o + 1] {
                let i = self.by_op[j as usize];
                if self.iblk[i as usize] != NONE {
                    self.scan.push(i);
                }
            }
            return;
        }
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                if b.insts[i as usize].op == op {
                    self.scan.push(i);
                }
            }
        }
    }

    // `scan`: the instructions of the opcodes `ops` lists (each once), in index order (`by_op`).
    fn scan_ops(self: &mut Self, ops: []u8) {
        self.scan.truncate(0);
        for k in 0..ops.len() {
            let o = ops[k] as usize;
            for j in self.op_at[o]..self.op_at[o + 1] {
                self.scan.push(self.by_op[j as usize]);
            }
        }
        if ops.len() > 1 {
            self.scan.sort();
        }
    }

    fn shift_counts(self: &mut Self, b: &Body) {
        if (self.fold_ops & FOLD_SHAMT) == 0 {
            return;
        }
        self.scan_ops([O_SHL, O_LSHR, O_ASHR]);
        for q in 0..self.scan.len() {
            let i = self.scan[q] as usize;
            let t = b.insts[i];
            let bits = type_bits(t.ty, 8);
            if t.op < O_SHL || t.op > O_ASHR || !is_int(t.ty) || bits != 32 && bits != 64 || self.pfold[i] {
                continue;
            }
            let m = t.b;
            if (m & (VPARAM | VFLAG)) != 0 || m == VNONE || b.insts[m as usize].op != O_AND || self.count[m as usize] != 1 || self.pfold[m as usize] {
                continue;
            }
            // A mask that takes in an operand other than an extension or truncation (`shift_amount` reads past
            // those; `FOLD_UBFX`: `(x >> 50) & 63` one field extract) computes it.
            let z = b.insts[m as usize].a;
            let zop = if is_inst(z) {
                b.insts[z as usize].op
            } else {
                O_ZEXT
            };
            if is_inst(z) && self.pfold[z as usize] && zop != O_ZEXT && zop != O_SEXT && zop != O_TRUNC {
                continue;
            }
            let k = int_const(b, b.insts[m as usize].b);
            if k != u64::MAX && (k & (bits - 1) as u64) == (bits - 1) as u64 {
                self.pfold[m as usize] = true;
            }
        }
    }

    fn folds(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        self.fold.truncate(0);
        self.fold.resize_default(ni);
        self.pfold.truncate(0);
        self.pfold.resize_default(ni);
        self.xtrunc.truncate(0);
        self.xtrunc.resize_default(ni);
        self.sunk.truncate(0);
        self.sunk.resize_default(ni);
        self.view.truncate(0);
        self.wide.truncate(0);
        fill(&mut self.conj, ni, 0);
        fill(&mut self.carry, ni, CARRY_NONE);
        if self.fold_max == 0 && self.fold_ops == 0 {
            return;
        }
        self.group_ops(b);
        // The use count of each instruction, and its uses as a condition.
        fill(&mut self.count, ni, 0);
        fill(&mut self.cnd, ni, 0);
        for i in 0..ni {
            let t = b.insts[i];
            each_use(b, t, &mut self.succ);
            for u in 0..self.succ.len() {
                let v = self.succ[u];
                if (v & (VPARAM | VFLAG)) == 0 {
                    self.count[v as usize] += 1;
                }
            }
            if (t.op == O_SELECT || t.op == O_BR) && (t.a & (VPARAM | VFLAG)) == 0 {
                self.cnd[t.a as usize] += 1;
            }
        }
        self.scan_ops([O_ICMP, O_FCMP]);
        for q in 0..self.scan.len() {
            let i = self.scan[q] as usize;
            let t = b.insts[i];
            let fc = (self.fold_ops & FOLD_FCMP) != 0 && t.op == O_FCMP && !is_vec(b.type_of(t.a)) && t.aux != C_ONE && t.aux != C_UEQ;
            self.pfold[i] = (self.fold_ops & FOLD_CMP) != 0 && (t.op == O_ICMP && b.type_of(t.a) != T_I128 || fc) && self.count[i] != 0 && self.cnd[i] == self.count[i];
        }
        // An `and`'s uses as an equality with 0.
        fill(&mut self.cnd, ni, 0);
        self.scan_ops([O_ICMP]);
        for q in 0..self.scan.len() {
            let i = self.scan[q] as usize;
            let t = b.insts[i];
            if t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) && (t.a & (VPARAM | VFLAG)) == 0 && (b.insts[t.a as usize].op == O_AND || b.insts[t.a as usize].op == O_VOP) && int_const(
                b,
                t.b,
            ) == 0 {
                self.cnd[t.a as usize] += 1;
            }
        }
        self.scan_ops(
            [O_ADD, O_SUB, O_AND, O_OR, O_XOR, O_VOP, O_SPLAT, O_FMUL, O_FADD, O_FSUB, O_FDIV, O_VSUMW, O_VSEL],
        );
        // The masks of the selects `FOLD_ADDSUB` folds into, one entry a select.
        let mut masks = Vector::<Value>::new();
        for q in 0..self.scan.len() {
            let i = self.scan[q] as usize;
            let t = b.insts[i];
            let mut accumulates = false;
            if (self.fold_ops & FOLD_VMLA) != 0 && (t.op == O_ADD || t.op == O_SUB) && is_vec(t.ty) {
                let mut p = self.vmla_mul(b, t);
                if p == VNONE && t.op == O_ADD {
                    p = self.vsra_shift(b, t);
                }
                if p != VNONE {
                    self.pfold[p as usize] = true;
                    accumulates = true;
                }
            }
            if (self.fold_ops & FOLD_LANE) != 0 && t.op == O_SPLAT && is_inst(t.a) && b.insts[t.a as usize].op == O_VEXTRACT && self.count[t.a as usize] == 1 {
                let vt = b.type_of(b.insts[t.a as usize].a);
                let eb = type_bytes(lane_type(vt), 8);
                if (type_bytes(t.ty, 8) == 8 || type_bytes(t.ty, 8) == 16) && (type_bytes(vt, 8) == 8 || type_bytes(
                    vt,
                    8,
                ) == 16) && (eb == 4 || eb == 8) {
                    self.pfold[t.a as usize] = true;
                }
            }
            if (self.fold_ops & FOLD_LANE_MUL) != 0 && t.op == O_FMUL && is_vec(t.ty) && (type_bytes(t.ty, 8) == 8 || type_bytes(
                t.ty,
                8,
            ) == 16) && is_inst(t.b) && b.insts[t.b as usize].op == O_SPLAT && self.count[t.b as usize] == 1 && is_inst(
                b.insts[t.b as usize].a,
            ) && self.pfold[b.insts[t.b as usize].a as usize] {
                self.pfold[t.b as usize] = true;
            }
            if (self.fold_ops & FOLD_LANE_PAIR) != 0 && lane_pair(b, t) && self.count[t.a as usize] == 1 && self.count[t.b as usize] == 1 {
                self.pfold[t.a as usize] = true;
                self.pfold[t.b as usize] = true;
            }
            if (self.fold_ops & FOLD_LANE0) != 0 && (t.op == O_FADD || t.op == O_FSUB || t.op == O_FMUL || t.op == O_FDIV) && !is_vec(
                t.ty,
            ) {
                for side in 0..2u32 {
                    let x = ast::pick(side == 0, t.a, t.b);
                    if lane0_of(b, x) != VNONE && self.count[x as usize] == 1 && !self.pfold[x as usize] && b.insts[x as usize].ty == t.ty {
                        self.pfold[x as usize] = true;
                    }
                }
            }
            if (self.fold_ops & FOLD_ADDSUB) != 0 && t.op == O_VSEL {
                let (d, s) = self.addsub_parts(b, t);
                if d != VNONE {
                    self.pfold[d as usize] = true;
                    self.pfold[s as usize] = true;
                    masks.push(t.a);
                }
            }
            if (self.fold_ops & FOLD_VSAD) != 0 && t.op == O_VSUMW {
                let p = self.vsad_diff(b, t);
                if p != VNONE {
                    self.pfold[p as usize] = true;
                }
            }
            if (self.fold_ops & FOLD_VWADD) != 0 && t.op == O_ADD && is_vec(t.ty) && !accumulates {
                let p = self.vwadd_ext(b, t);
                if p != VNONE {
                    self.pfold[p as usize] = true;
                    self.pfold[b.insts[p as usize].a as usize] = true;
                }
            }
            if !is_int(t.ty) || t.ty == T_I128 {
                continue;
            }
            let bits = type_bits(t.ty, 8);
            if t.op == O_VOP && self.count[i] != 0 && self.cnd[i] == self.count[i] && self.any_fold(b, t) {
                self.pfold[i] = true;
            }
            if t.op == O_AND && (self.fold_ops & FOLD_TST) != 0 && self.count[i] != 0 && self.cnd[i] == self.count[i] {
                // A narrow type's register may hold any bits above it: only a mask within the type tests.
                let m = int_const(b, t.b);
                self.pfold[i] = bits >= 32 || m != u64::MAX && m >> bits as u64 == 0;
            }
            let p = ast::pick(
                t.op == O_SUB || t.op == O_ADD && int_const(b, t.a) == u64::MAX && int_const(b, t.b) == u64::MAX,
                t.b,
                VNONE,
            );
            if (self.fold_ops & FOLD_MADD) != 0 && p != VNONE && (p & (VPARAM | VFLAG)) == 0 && b.insts[p as usize].op == O_MUL && self.count[p as usize] == 1 && int_const(
                b,
                t.a,
            ) == u64::MAX {
                self.pfold[p as usize] = true;
            } else if (self.fold_ops & FOLD_MADD) != 0 && p != VNONE && t.op == O_ADD && is_inst(t.a) && b.insts[t.a as usize].op == O_MUL && self.count[t.a as usize] == 1 {
                // The product as the first addend.
                self.pfold[t.a as usize] = true;
            }
            if (self.fold_ops & FOLD_ROT) != 0 && (bits >= 32 || (self.fold_ops & FOLD_ROT_NARROW) != 0) {
                let rot = rotate_of(b, i as u32);
                let amt = rot.amt;
                if rot.x != VNONE && self.count[t.a as usize] == 1 && self.count[t.b as usize] == 1 {
                    self.pfold[t.a as usize] = true;
                    self.pfold[t.b as usize] = true;
                    // Each amount's extension or truncation with this one use. `inside`: the uses of the
                    // amount the folded instructions make; `open`: the other amount's user folds.
                    let mut inside: u32 = 0;
                    let mut open = false;
                    // The amount operand of the shift that takes `amt` itself, maybe its extension.
                    let mut own = VNONE;
                    for q in 0..2u32 {
                        let sh = ast::pick(q == 0, t.a, t.b);
                        let s = b.insts[sh as usize].b;
                        let ext = amount_of(b, s) != s;
                        if ext && self.count[s as usize] == 1 {
                            self.pfold[s as usize] = true;
                        }
                        if amount_of(b, s) == amt {
                            own = s;
                        }
                        if amount_of(b, s) == amt && (!ext || self.pfold[s as usize]) {
                            inside += 1;
                        }
                        if amount_of(b, s) != amt && (!ext || self.pfold[s as usize]) {
                            open = true;
                        }
                    }
                    if amt != VNONE {
                        // The other amount's `and` and `sub` or `neg`, while each has this one use; then the
                        // amount's own mask to the width, when the rotation alone reads it (a rotation
                        // takes its amount modulo the width).
                        let sa = amount_of(b, b.insts[t.a as usize].b);
                        let mut v = if sa == amt {
                            amount_of(b, b.insts[t.b as usize].b)
                        } else {
                            sa
                        };
                        for _ in 0..2 {
                            if !open || !is_inst(v) || self.count[v as usize] != 1 {
                                break;
                            }
                            let o = b.insts[v as usize].op;
                            if o != O_AND && o != O_SUB && o != O_NEG {
                                break;
                            }
                            self.pfold[v as usize] = true;
                            v = if o == O_SUB {
                                b.insts[v as usize].b
                            } else {
                                b.insts[v as usize].a
                            };
                        }
                        if v == amt {
                            inside += 1;
                        }
                        // The amount's extension, which the other amount's folded chain may read too: folded
                        // when the shift and that chain are its only users.
                        if own != amt && !self.pfold[own as usize] && self.count[own as usize] == 1 + (v == own) as u32 {
                            self.pfold[own as usize] = true;
                            inside += 1;
                        }
                        if is_inst(amt) && b.insts[amt as usize].op == O_AND && int_const(b, b.insts[amt as usize].b) == bits as u64 - 1 && self.count[amt as usize] == inside {
                            self.pfold[amt as usize] = true;
                        }
                    }
                    continue;
                }
            }
            if (self.fold_ops & FOLD_LEA) != 0 && (t.op == O_ADD || t.op == O_SUB || is_sum_or(b, t)) {
                // The shift an index takes, then the inner sum whose operands the address takes.
                let nq: u32 = ast::pick(t.op != O_SUB, 2, 0);
                for q in 0..nq {
                    let v = ast::pick(q == 0, t.b, t.a);
                    if lea_shift(b, v) == 0 || self.pfold[v as usize] || self.count[v as usize] != 1 {
                        continue;
                    }
                    self.pfold[v as usize] = true;
                    if lea_of(b, &self.pfold, i as u32).ok {
                        break;
                    }
                    self.pfold[v as usize] = false;
                }
                for q in 0..2u32 {
                    let v = ast::pick(q == 0, t.a, t.b);
                    if q == 1 && t.op == O_SUB || !is_inst(v) || self.pfold[v as usize] || self.count[v as usize] != 1 || b.insts[v as usize].op != O_ADD || b.insts[v as usize].ty != t.ty {
                        continue;
                    }
                    self.pfold[v as usize] = true;
                    if lea_of(b, &self.pfold, i as u32).ok {
                        break;
                    }
                    self.pfold[v as usize] = false;
                }
            }
            if (self.fold_ops & FOLD_UBFX) != 0 && t.op == O_AND && !self.pfold[i] && (t.a & (VPARAM | VFLAG)) == 0 {
                let s = b.insts[t.a as usize];
                let m = int_const(b, t.b);
                let k = if s.op == O_LSHR {
                    int_const(b, s.b)
                } else {
                    u64::MAX
                };
                // A mask of the low `w` bits under a shift by `k`, both within the width.
                if self.count[t.a as usize] == 1 && m != u64::MAX && m != 0 && (m & m + 1) == 0 && k < bits as u64 {
                    let w = (m + 1).trailing_zeros() as u64;
                    self.pfold[t.a as usize] = self.pfold[t.a as usize] || k + w <= bits as u64;
                }
            }
        }
        // A mask those selects alone read folds too.
        masks.sort();
        let mut k: usize = 0;
        while k < masks.len() {
            let mut e = k + 1;
            while e < masks.len() && masks[e] == masks[k] {
                e += 1;
            }
            if (e - k) as u32 == self.count[masks[k] as usize] {
                self.pfold[masks[k] as usize] = true;
            }
            k = e;
        }
        if (self.fold_ops & FOLD_PRED) != 0 {
            let mut preds = Vector::<Value>::new();
            let mut zeros = Vector::<Value>::new();
            self.scan_ops([O_VOP]);
            for q in 0..self.scan.len() {
                let t = b.insts[self.scan[q] as usize];
                if (self.pred_all || (t.aux & VOP_PRED) != 0) && pred_mask(b, t).1 != VNONE {
                    preds.push(b.pool[(t.a + 1) as usize]);
                    if t.ty != T_NONE && zero_vec(b, b.pool[(t.a + 2) as usize]) {
                        zeros.push(b.pool[(t.a + 2) as usize]);
                    }
                }
            }
            preds.sort();
            let mut k: usize = 0;
            while k < preds.len() {
                let mut e = k + 1;
                while e < preds.len() && preds[e] == preds[k] {
                    e += 1;
                }
                if (e - k) as u32 == self.count[preds[k] as usize] && self.pred_chain(b, preds[k], false) {
                    let _ = self.pred_chain(b, preds[k], true);
                }
                k = e;
            }
            // A zero fallback folds where every load that reads it folds its mask.
            zeros.sort();
            k = 0;
            while k < zeros.len() {
                let mut e = k + 1;
                while e < zeros.len() && zeros[e] == zeros[k] {
                    e += 1;
                }
                self.pfold[zeros[k] as usize] = (e - k) as u32 == self.count[zeros[k] as usize];
                k = e;
            }
        }
        if (self.fold_ops & FOLD_FREE_ZEXT) != 0 {
            // A truncation's uses as a select's side its condition bounds (`bounded_side`).
            fill(&mut self.cnd, ni, 0);
            fill(&mut self.andu, ni, 0);
            self.scan_ops([O_SELECT, O_AND]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                if t.op == O_SELECT && !is_vec(t.ty) {
                    if bounded_side(b, t.a, t.b, true) {
                        self.cnd[t.b as usize] += 1;
                    }
                    if bounded_side(b, t.a, t.c, false) {
                        self.cnd[t.c as usize] += 1;
                    }
                }
                // An `and` of two narrow values clears the bits above in one when the other is no truncation
                // (which may keep them, folded).
                if t.op == O_AND && (t.ty == T_I8 || t.ty == T_I16) && t.a != t.b {
                    for (x, y) in [(t.a, t.b), (t.b, t.a)] {
                        let trunc = (y & (VPARAM | VFLAG)) == 0 && y != VNONE && b.insts[y as usize].op == O_TRUNC;
                        if (x & (VPARAM | VFLAG)) == 0 && x != VNONE && !trunc {
                            self.andu[x as usize] += 1;
                        }
                    }
                }
            }
            self.scan_ops([O_ZEXT, O_TRUNC]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                if t.op != O_ZEXT && t.op != O_TRUNC {
                    continue;
                }
                let ft = b.type_of(t.a);
                if t.op == O_ZEXT && (t.ty == T_I16 || t.ty == T_I32) && (ft == T_I8 || ft == T_I16) && ft != t.ty {
                    self.pfold[i] = true;
                }
                if t.op == O_TRUNC && (t.ty == T_I8 || t.ty == T_I16) && (ft == T_I16 || ft == T_I32) && ft != t.ty {
                    self.pfold[i] = self.count[i] != 0 && (self.cnd[i] == self.count[i] || self.andu[i] == self.count[i] || fits_low(
                        b,
                        t.a,
                        type_mask(t.ty),
                        FITS_DEPTH,
                    ));
                }
                if t.op == O_TRUNC && (t.ty == T_I8 || t.ty == T_I16) && ft == T_I64 {
                    self.pfold[i] = self.count[i] != 0 && self.andu[i] == self.count[i];
                }
            }
        }
        self.select_incs(b);
        self.widenings(b);
        if self.fold_max == 0 {
            self.shift_counts(b);
            self.count_exts(b);
            // Last: the values that stay where they are include every other fold.
            self.sinks(b);
            if (self.fold_ops & FOLD_VIEW) != 0 {
                self.views(b);
            }
            return;
        }
        self.scan_ops([O_LOAD, O_STORE]);
        for q in 0..self.scan.len() {
            let i = self.scan[q] as usize;
            let t = b.insts[i];
            if t.op != O_LOAD && t.op != O_STORE || (t.aux & MEM_VOLATILE) != 0 || t.c != 0 || (t.a & (VPARAM | VFLAG)) != 0 {
                continue;
            }
            let p = b.insts[t.a as usize];
            let ty = if t.op == O_LOAD {
                t.ty
            } else {
                b.type_of(t.b)
            };
            let n = type_bytes(ty, 8); // the targets that fold have 8-byte pointers
            let sc = scale_of(p);
            // A vector of 8 or 16 bytes lives in a register; another is memory.
            let reg = !is_vec(ty) && ty != T_I128 || n == 8 || n == 16;
            self.fold[i] = p.op == O_PTRADD && p.b != VNONE && p.c == 0 && self.count[t.a as usize] == 1 && reg && (sc == 1 || sc == n && n <= self.fold_max);
            if self.fold[i] {
                self.pfold[t.a as usize] = true;
                if (self.fold_ops & FOLD_XIDX) != 0 && self.ext_index(b, p.b) {
                    self.pfold[p.b as usize] = true;
                }
            }
        }
        if (self.fold_ops & FOLD_XADDR) != 0 {
            self.fold_addrs(b);
        }
        // `FOLD_BLEN`: a count of leading zeros of 32 or 64 bits that only `width - clz` reads, the bit
        // length, or `clz ^ (width - 1)`, the top bit's index, folds into it.
        if (self.fold_ops & FOLD_BLEN) != 0 {
            self.scan_ops([O_SUB, O_XOR]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                let w = type_bits(t.ty, 8) as u64;
                let sub = t.op == O_SUB;
                let c = ast::pick(sub, t.b, t.a);
                if !sub && t.op != O_XOR || !is_int(t.ty) || w != 32 && w != 64 || (c & (VPARAM | VFLAG)) != 0 || c == VNONE {
                    continue;
                }
                let ci = b.insts[c as usize];
                let k = int_const(b, ast::pick(sub, t.a, t.b));
                if ci.op == O_CLZ && ci.ty == t.ty && self.count[c as usize] == 1 && !self.pfold[c as usize] && k == if sub {
                    w
                } else {
                    w - 1
                } {
                    self.pfold[c as usize] = true;
                }
            }
        }
        self.shift_counts(b);
        if (self.fold_ops & FOLD_SHOP) != 0 {
            self.scan_ops([O_ADD, O_SUB, O_AND, O_OR, O_XOR]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                let bits = type_bits(t.ty, 8);
                let ops = t.op == O_ADD || t.op == O_SUB || t.op == O_AND || t.op == O_OR || t.op == O_XOR;
                if !ops || !is_int(t.ty) || bits != 32 && bits != 64 || self.pfold[i] || int_const(b, t.a) != u64::MAX || int_const(
                    b,
                    t.b,
                ) != u64::MAX {
                    continue;
                }
                // The other operand in a register: not one another fold computes in this instruction.
                let s = if self.shop_ok(b, t.b, bits) && !(is_inst(t.a) && self.pfold[t.a as usize]) {
                    t.b
                } else if t.op != O_SUB && self.shop_ok(b, t.a, bits) && !(is_inst(t.b) && self.pfold[t.b as usize]) {
                    t.a
                } else {
                    VNONE
                };
                if s != VNONE {
                    self.pfold[s as usize] = true;
                }
            }
        }
        if (self.fold_ops & FOLD_MULL) != 0 {
            self.scan_ops([O_MUL]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                if t.op != O_MUL || t.ty != T_I64 || self.pfold[i] || mull_ext(b, t) == 0 {
                    continue;
                }
                let k = is_const_val(b, t.b);
                if self.count[t.a as usize] == 1 && (k || self.count[t.b as usize] == 1) && !self.pfold[t.a as usize] && !self.pfold[t.b as usize] {
                    self.pfold[t.a as usize] = true;
                    self.pfold[t.b as usize] = !k;
                }
            }
        }
        if (self.fold_ops & FOLD_CSEL) != 0 {
            self.scan_ops([O_SELECT]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                if t.op != O_SELECT || !is_int(t.ty) || t.ty == T_I128 || is_vec(t.ty) {
                    continue;
                }
                // A side that is a value plus 1, negated or inverted (the other side's difference negated too):
                // the select computes it from that value.
                if is_inst(t.b) && self.count[t.b as usize] == 1 && !self.pfold[t.b as usize] && (cs_kind(b, t.b, t.c) != CS_NONE || cs_base(
                    b,
                    t.b,
                ).0 != CS_NONE) {
                    self.pfold[t.b as usize] = true;
                } else if is_inst(t.c) && self.count[t.c as usize] == 1 && !self.pfold[t.c as usize] && (cs_kind(
                    b,
                    t.c,
                    t.b,
                ) != CS_NONE || cs_base(b, t.c).0 != CS_NONE) {
                    self.pfold[t.c as usize] = true;
                }
            }
        }
        if (self.fold_ops & FOLD_BRCONJ) != 0 {
            self.scan_ops([O_BR]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                if t.op != O_BR || !is_inst(t.a) {
                    continue;
                }
                let c = b.insts[t.a as usize];
                if (c.op == O_AND || c.op == O_OR) && c.ty == T_I8 && self.count[t.a as usize] == 1 && !self.pfold[t.a as usize] && c.a != c.b && self.cmp_leaf(
                    b,
                    c.a,
                ) && self.cmp_leaf(b, c.b) {
                    self.pfold[t.a as usize] = true;
                    self.pfold[c.a as usize] = true;
                    self.pfold[c.b as usize] = true;
                }
            }
        }
        if (self.fold_ops & FOLD_CCMP) != 0 {
            self.conj_folds(b);
        }
        // `FOLD_FSEL`: a comparison of scalar floats but `one` and `ueq` (no SSE comparison gives their mask)
        // whose every use is the condition of a select of floats of its type folds into the selects.
        if (self.fold_ops & FOLD_FSEL) != 0 {
            fill(&mut self.cnd, ni, 0);
            self.scan_ops([O_SELECT]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                if t.op == O_SELECT && (t.ty == T_F32 || t.ty == T_F64) && is_inst(t.a) && b.insts[t.a as usize].op == O_FCMP && b.type_of(
                    b.insts[t.a as usize].a,
                ) == t.ty {
                    self.cnd[t.a as usize] += 1;
                }
            }
            self.scan_ops([O_FCMP]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                if t.op == O_FCMP && !is_vec(b.type_of(t.a)) && t.aux != C_ONE && t.aux != C_UEQ && self.count[i] != 0 && self.cnd[i] == self.count[i] {
                    self.pfold[i] = true;
                }
            }
        }
        // `FOLD_NOT`: an inversion (`not`, or `xor` with all ones) whose one use is an `and`, `or` or `xor` of
        // at most 64 bits, whose other operand and the inverted value fold nothing, folds into it (arm64
        // `bic`, `orn`, `eon`: `not_side`).
        if (self.fold_ops & (FOLD_NOT | FOLD_ANDN)) != 0 {
            let all = (self.fold_ops & FOLD_NOT) != 0;
            self.scan_ops([O_AND, O_OR, O_XOR]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                if t.op != O_AND && (t.op != O_OR && t.op != O_XOR || !all) || !is_int(t.ty) || t.ty == T_I128 || self.pfold[i] {
                    continue;
                }
                for side in 0..2 {
                    let (s, o) = if side == 0 {
                        (t.b, t.a)
                    } else {
                        (t.a, t.b)
                    };
                    let x = inversion(b, s);
                    if x != VNONE && self.count[s as usize] == 1 && !self.pfold[s as usize] && !(is_inst(o) && self.pfold[o as usize]) && !(is_inst(
                        x,
                    ) && self.pfold[x as usize]) {
                        self.pfold[s as usize] = true;
                        break;
                    }
                }
            }
        }
        // `FOLD_BLS`: `x - 1` or `-x` whose every use is an `and` (`xor` for `x - 1`) with `x` (`bls_parts`)
        // that folds nothing, or an `and` an equality with 0 alone reads (`FOLD_TST`). `cnd` counts an
        // `and`'s tests first, then each inner value's uses that take it.
        if (self.fold_ops & FOLD_BLS) != 0 {
            fill(&mut self.cnd, ni, 0);
            self.scan_ops([O_ICMP]);
            for q in 0..self.scan.len() {
                let t = b.insts[self.scan[q] as usize];
                if (t.aux == C_EQ || t.aux == C_NE) && is_inst(t.a) && b.insts[t.a as usize].op == O_AND && int_const(
                    b,
                    t.b,
                ) == 0 {
                    self.cnd[t.a as usize] += 1;
                }
            }
            self.scan_ops([O_AND, O_XOR]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                let tested = t.op == O_AND && self.count[i] != 0 && self.cnd[i] == self.count[i];
                let (kind, s, x) = bls_parts(b, t);
                if kind != 0 && (!self.pfold[i] || tested) && !(is_inst(x) && self.pfold[x as usize]) {
                    self.cnd[s as usize] += 1;
                }
            }
            self.scan_ops([O_ADD, O_SUB, O_NEG]);
            for q in 0..self.scan.len() {
                let s = self.scan[q] as usize;
                if self.cnd[s] != 0 && self.cnd[s] == self.count[s] && !self.pfold[s] {
                    self.pfold[s] = true;
                }
            }
        }
        // `FOLD_TRUNC`: a narrow truncation of a value that folds nothing, read by comparisons alone.
        if (self.fold_ops & FOLD_TRUNC) != 0 {
            fill(&mut self.cnd, ni, 0);
            self.scan_ops([O_ICMP]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                if t.op != O_ICMP {
                    continue;
                }
                for s in [t.a, t.b] {
                    if is_inst(s) && b.insts[s as usize].op == O_TRUNC {
                        self.cnd[s as usize] += 1;
                    }
                }
            }
            self.scan_ops([O_TRUNC]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                let bits = type_bits(t.ty, 8);
                if t.op == O_TRUNC && (bits == 8 || bits == 16) && (t.a & VFLAG) == 0 && is_int(b.type_of(t.a)) && b.type_of(
                    t.a,
                ) != T_I128 && self.count[i] != 0 && self.cnd[i] == self.count[i] && !self.pfold[i] && !(is_inst(t.a) && self.pfold[t.a as usize]) {
                    if self.count[i] == 1 || (self.fold_ops & FOLD_TRUNC_ONCE) == 0 {
                        self.pfold[i] = true;
                    } else {
                        self.xtrunc[i] = true;
                    }
                }
            }
        }
        // `FOLD_XBFX`: a left shift by a constant whose one use is a right shift of 32 or 64 bits by at least
        // as much folds into it: a field extracted, sign- or zero-extended (arm64 `sbfx`, `ubfx`).
        let ext_only = (self.fold_ops & FOLD_XBFX) == 0;
        if (self.fold_ops & (FOLD_XBFX | FOLD_XBFX_EXT)) != 0 {
            self.scan_ops([O_LSHR, O_ASHR]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                let bits = type_bits(t.ty, 8);
                if t.op != O_LSHR && t.op != O_ASHR || !is_int(t.ty) || bits != 32 && bits != 64 || self.pfold[i] || !is_inst(
                    t.a,
                ) {
                    continue;
                }
                let s = b.insts[t.a as usize];
                let k = int_const(b, t.b);
                let l = if s.op == O_SHL {
                    int_const(b, s.b)
                } else {
                    u64::MAX
                };
                let w = (bits as u64).wrapping_sub(k);
                let ext = w == 8 || w == 16 || w == 32 && bits == 64;
                if l != u64::MAX && k != u64::MAX && l <= k && k < bits as u64 && (ext || !ext_only) && self.count[t.a as usize] == 1 && !self.pfold[t.a as usize] && !(is_inst(
                    s.a,
                ) && self.pfold[s.a as usize]) {
                    self.pfold[t.a as usize] = true;
                }
            }
        }
        // `FOLD_BFI`: an insertion of a field (`bfi_of`) whose three inner instructions each have this one use
        // folds them (arm64 `bfi`); the shift may be a shifted operand already (`FOLD_SHOP`).
        if (self.fold_ops & FOLD_BFI) != 0 {
            self.scan_ops([O_OR]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let f = bfi_of(b, b.insts[i]);
                if f.x == VNONE || self.pfold[i] {
                    continue;
                }
                let (ka, kb) = (f.keep, f.field);
                let kc = b.insts[kb as usize].a;
                let tr = f.trunc == VNONE || self.count[f.trunc as usize] == 1 && !self.pfold[f.trunc as usize];
                if tr && self.count[ka as usize] == 1 && self.count[kb as usize] == 1 && self.count[kc as usize] == 1 && !self.pfold[ka as usize] && !self.pfold[kc as usize] && !(is_inst(
                    f.x,
                ) && self.pfold[f.x as usize]) && !(is_inst(f.v) && self.pfold[f.v as usize]) {
                    self.pfold[ka as usize] = true;
                    self.pfold[kb as usize] = true;
                    self.pfold[kc as usize] = true;
                    if f.trunc != VNONE {
                        self.pfold[f.trunc as usize] = true;
                    }
                }
            }
        }
        // `FOLD_CARRY`: a select of 32 or 64 bits between a value and that value plus 1 (`CS_INC`, its one
        // use) on a folded integer comparison: the side folds into the select, an add of the condition
        // (`carry_inc`).
        if (self.fold_ops & FOLD_CARRY) != 0 {
            self.scan_ops([O_SELECT]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let s = carry_inc(b, &self.pfold, i as u32);
                if s != VNONE && self.count[s as usize] == 1 {
                    self.pfold[s as usize] = true;
                }
            }
        }
        // `FOLD_RMW` before `FOLD_LDOP`, which would fold the load into the operation alone.
        if (self.fold_ops & FOLD_RMW) != 0 {
            self.block_ops(b, O_STORE);
            for q in 0..self.scan.len() {
                let i = self.scan[q];
                let bk = b.blocks[self.iblk[i as usize] as usize];
                let t = b.insts[i as usize];
                if !is_inst(t.b) || (t.aux & MEM_VOLATILE) != 0 {
                    continue;
                }
                let v = t.b;
                let l = rmw_load(b, &self.pfold, t);
                if l == VNONE || v < bk.start || self.count[v as usize] != 1 || self.count[l as usize] != 1 || l < bk.start {
                    continue;
                }
                let mut clear = true;
                for j in l + 1..i {
                    clear = clear && !writes_mem(b.insts[j as usize]);
                }
                if clear {
                    self.pfold[l as usize] = true;
                    self.pfold[v as usize] = true;
                }
            }
        }
        // `ldop_user` reads loads alone.
        if (self.fold_ops & FOLD_LDOP) != 0 {
            self.block_ops(b, O_LOAD);
            for q in 0..self.scan.len() {
                let i = self.scan[q];
                let bk = b.blocks[self.iblk[i as usize] as usize];
                if self.ldop_user(b, i, bk.start + bk.len) {
                    self.pfold[i as usize] = true;
                }
            }
        }
        // `FOLD_MOVBE`: the loads byte reversals alone read, then the reversals stores alone read.
        if (self.fold_ops & FOLD_MOVBE) != 0 {
            self.block_ops(b, O_BSWAP);
            for q in 0..self.scan.len() {
                let i = self.scan[q];
                let t = b.insts[i as usize];
                let bits = type_bits(t.ty, 8);
                if is_vec(t.ty) || bits != 32 && bits != 64 || self.pfold[i as usize] || !is_inst(t.a) || t.a < b.blocks[self.iblk[i as usize] as usize].start {
                    continue;
                }
                let l = b.insts[t.a as usize];
                if l.op != O_LOAD || l.ty != t.ty || (l.aux & MEM_VOLATILE) != 0 || self.count[t.a as usize] != 1 || self.pfold[t.a as usize] || self.reg_param(
                    b,
                    l.a,
                ) {
                    continue;
                }
                let mut clean = true;
                for j in t.a + 1..i {
                    clean = clean && !writes_mem(b.insts[j as usize]);
                }
                if clean {
                    self.pfold[t.a as usize] = true;
                }
            }
            self.block_ops(b, O_STORE);
            for q in 0..self.scan.len() {
                let i = self.scan[q];
                let st = b.insts[i as usize];
                let v = st.b;
                if !is_inst(v) || self.pfold[v as usize] || self.count[v as usize] != 1 || (st.aux & MEM_VOLATILE) != 0 {
                    continue;
                }
                let r = b.insts[v as usize];
                let bits = type_bits(r.ty, 8);
                if r.op == O_BSWAP && !is_vec(r.ty) && bits >= 16 && bits <= 64 && v >= b.blocks[self.iblk[i as usize] as usize].start && !(is_inst(
                    r.a,
                ) && self.pfold[r.a as usize]) {
                    self.pfold[v as usize] = true;
                }
            }
        }
        if (self.fold_ops & (FOLD_VSHIMM | FOLD_VSHIMM_ALL)) != 0 {
            fill(&mut self.cnd, ni, 0);
            self.scan_ops([O_SHL, O_LSHR, O_ASHR]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                if self.vshimm(b, t) != NONE && t.a != t.b {
                    self.cnd[t.b as usize] += 1;
                }
            }
            self.scan_ops([O_SPLAT, O_WCONST]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let op = b.insts[i].op;
                if (op == O_SPLAT || op == O_WCONST) && self.count[i] != 0 && self.cnd[i] == self.count[i] {
                    self.pfold[i] = true;
                }
            }
        }
        if (self.fold_ops & FOLD_VCMEM) != 0 {
            fill(&mut self.cnd, ni, 0);
            for k in 0..b.blocks.len() {
                let bk = b.blocks[k];
                for i in bk.start..bk.start + bk.len {
                    let t = b.insts[i as usize];
                    if !is_vec(t.ty) || type_bytes(t.ty, 8) != 16 || !self.vop_mem(t, t.ty) || !is_inst(t.b) || t.a == t.b || t.b < bk.start || self.pfold[i as usize] || is_inst(
                        t.a,
                    ) && self.pfold[t.a as usize] {
                        continue;
                    }
                    if b.insts[t.b as usize].op == O_WCONST {
                        self.cnd[t.b as usize] += 1;
                    }
                }
            }
            self.scan_ops([O_WCONST]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                if b.insts[i].op == O_WCONST && type_bytes(b.insts[i].ty, 8) == 16 && self.count[i] != 0 && self.cnd[i] == self.count[i] && !self.pfold[i] {
                    self.pfold[i] = true;
                }
            }
        }
        // Last: its parts fold no other operand.
        if (self.fold_ops & FOLD_ADC) != 0 {
            self.carries(b);
        }
        if (self.fold_ops & FOLD_ZSHL) != 0 {
            self.scan_ops([O_SHL]);
            for q in 0..self.scan.len() {
                let i = self.scan[q] as usize;
                let t = b.insts[i];
                if t.op != O_SHL || !is_int(t.ty) || t.ty == T_I128 || self.pfold[i] || !is_inst(t.a) {
                    continue;
                }
                let s = int_const(b, t.b);
                let z = b.insts[t.a as usize];
                if z.op != O_ZEXT || self.count[t.a as usize] != 1 || self.pfold[t.a as usize] || is_inst(z.a) && self.pfold[z.a as usize] {
                    continue;
                }
                if s != u64::MAX && type_bits(b.type_of(z.a), 8) as u64 + s >= type_bits(t.ty, 8) as u64 && s < type_bits(
                    t.ty,
                    8,
                ) as u64 {
                    self.pfold[t.a as usize] = true;
                }
            }
        }
        if (self.fold_ops & FOLD_XUSE) != 0 {
            self.ext_uses(b);
        }
        self.count_exts(b);
        self.sinks(b);
        if (self.fold_ops & FOLD_VIEW) != 0 {
            self.views(b);
        }
        // `FOLD_LD3` last: a shuffle another fold took loads nothing.
        if (self.fold_ops & FOLD_LD3) != 0 {
            self.block_ops(b, O_VOP);
            for q in 0..self.scan.len() {
                let i = self.scan[q];
                if self.pfold[i as usize] || self.ld3_field(b, i) == NONE {
                    continue;
                }
                let t = b.insts[i as usize];
                for o in 0..3u32 {
                    let v = b.pool[(t.a + o) as usize];
                    if self.pfold[v as usize] {
                        continue;
                    }
                    // Every read of the load is such a shuffle.
                    let mut k: u32 = 0;
                    let end = (b.blocks[self.iblk[v as usize] as usize].start + b.blocks[self.iblk[v as usize] as usize].len).min(
                        v + 1 + LD3_REACH,
                    );
                    for j in v + 1..end {
                        let u = b.insts[j as usize];
                        if u.op == O_VOP && !self.pfold[j as usize] && self.ld3_field(b, j) != NONE {
                            for w in 0..3u32 {
                                k += (b.pool[(u.a + w) as usize] == v) as u32;
                            }
                        }
                    }
                    if k == self.count[v as usize] {
                        self.pfold[v as usize] = true;
                    }
                }
            }
        }
    }

    /// The field (0 to 2) that `vop` shuffle `i` of `b` takes from a group of three, or NONE: its operands
    /// three loads of its type (8 or 16 bytes, lanes below 8 bytes in 8) from one address at offsets `c`,
    /// `c + n`, `c + 2n` (`n` its bytes), its lanes `r`, `r + 3`, `r + 6`, ..; within LD3_REACH of the first
    /// load in its block, no write of memory between (arm64's `ld3` reads the memory at the shuffle).
    pub(package) const fn ld3_field(self: &Self, b: &Body, i: u32) u32 {
        let t = b.insts[i as usize];
        // The block table (`block_ops`) is the analysis's under `FOLD_LD3` alone.
        if !self.iblk_ok || t.op != O_VOP || (t.aux & VOP_CODE) as u32 != core::OP_SIMD + core::SIMD_SHUFFLE as u32 || t.b != 3 || t.c == VNONE || !is_vec(
            t.ty,
        ) {
            return NONE;
        }
        let nb = type_bytes(t.ty, 8);
        let n = lanes(t.ty);
        if nb != 8 && nb != 16 || nb == 8 && n == 1 || b.pool[t.c as usize] != n {
            return NONE;
        }
        let r = b.pool[(t.c + 1) as usize];
        if r > 2 {
            return NONE;
        }
        for m in 0..n {
            if b.pool[(t.c + 1 + m) as usize] != r + 3 * m {
                return NONE;
            }
        }
        let v0 = b.pool[t.a as usize];
        if !is_inst(v0) {
            return NONE;
        }
        let l0 = b.insts[v0 as usize];
        let mut first = v0;
        for o in 0..3u32 {
            let v = b.pool[(t.a + o) as usize];
            if !is_inst(v) || self.iblk[v as usize] != self.iblk[i as usize] {
                return NONE;
            }
            let l = b.insts[v as usize];
            if l.op != O_LOAD || l.ty != t.ty || (l.aux & MEM_VOLATILE) != 0 || l.a != l0.a || l.c as i32 != l0.c as i32 + (o * nb) as i32 {
                return NONE;
            }
            first = first.min(v);
        }
        if i - first > LD3_REACH {
            return NONE;
        }
        for j in first + 1..i {
            if writes_mem(b.insts[j as usize]) {
                return NONE;
            }
        }
        return r;
    }

    // `FOLD_VIEW`, after every other fold: `view` per instruction no fold takes, whose operand is no folded
    // instruction and none a generator recomputes at each use (a constant, an address). A view of a view is
    // a view of that one's value (an operand may come later in the instruction array: a second pass).
    fn views(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        let mut any = false;
        for i in 0..ni {
            let t = b.insts[i];
            let copy = t.op == O_PTRADD && t.b == VNONE && t.c == 0;
            let zx = t.op == O_ZEXT;
            if t.op != O_TRUNC && !free_conv(t.op) && !copy && !zx || t.a == VNONE || (t.a & VFLAG) != 0 || self.pfold[i] || self.xtrunc[i] || self.sunk[i] || self.carry[i] != CARRY_NONE {
                continue;
            }
            let (fb, tb) = (word_bits(b.type_of(t.a)), word_bits(t.ty));
            // A cast between two vectors of one size: the lanes' bits as they are, in the same home.
            let vcast = t.op == O_BITCAST && is_vec(t.ty) && is_vec(b.type_of(t.a)) && type_bytes(t.ty, 8) == type_bytes(
                b.type_of(t.a),
                8,
            );
            if !vcast && (fb == 0 || tb == 0 || tb > fb != zx) {
                continue;
            }
            // A zero extension: of an instruction whose register holds zeros above its bits, a load or
            // a zero extension (a view of such a one, or one made).
            if zx {
                if !is_inst(t.a) {
                    continue;
                }
                let o = b.insts[t.a as usize].op;
                if o != O_LOAD && o != O_ZEXT || self.sunk[t.a as usize] || self.carry[t.a as usize] != CARRY_NONE {
                    continue;
                }
            }
            let r = self.seen(t.a);
            if is_inst(r) {
                let o = b.insts[r as usize].op;
                if self.pfold[r as usize] || o == O_ICONST || o == O_FCONST || o == O_SLOTADDR || o == O_SYMADDR || o == O_WCONST {
                    continue;
                }
            }
            if !any {
                fill(&mut self.view, ni, VNONE);
                any = true;
            }
            self.view[i] = r;
        }
        if !any {
            return;
        }
        for i in 0..ni {
            let mut r = self.view[i];
            // Each step follows one view of the chain: at most `ni`.
            while r != VNONE && self.seen(r) != r {
                r = self.seen(r);
            }
            self.view[i] = r;
            if r != VNONE && b.insts[i].op == O_ZEXT {
                if self.wide.len() == 0 {
                    fill(&mut self.wide, ni, false);
                }
                self.wide[r as usize] = true;
            }
        }
    }

    // `FOLD_XUSE`, after the other folds: `xuse` per extension, 1 while every use seen takes it extended,
    // 2 once one does not; per comparison, 4 when an `and` or `or` reads it.
    fn ext_uses(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        self.scan_ops([O_ZEXT, O_SEXT]);
        if self.scan.len() == 0 {
            return;
        }
        fill(&mut self.xuse, ni, 0);
        let mut any = false;
        for q in 0..self.scan.len() {
            let i = self.scan[q] as usize;
            let t = b.insts[i];
            if (t.op == O_ZEXT || t.op == O_SEXT) && t.ty == T_I64 && b.type_of(t.a) == T_I32 && !self.pfold[i] && self.count[i] != 0 && !(is_inst(
                t.a,
            ) && self.pfold[t.a as usize]) {
                self.xuse[i] = 1;
                any = true;
            }
        }
        if !any {
            return;
        }
        // The comparisons an `and` or `or` reads: one of flags folds them into conditional comparisons,
        // which read their operands' registers.
        for i in 0..ni {
            let t = b.insts[i];
            if t.op != O_AND && t.op != O_OR {
                continue;
            }
            if is_inst(t.a) && b.insts[t.a as usize].op == O_ICMP {
                self.xuse[t.a as usize] = 4;
            }
            if is_inst(t.b) && b.insts[t.b as usize].op == O_ICMP {
                self.xuse[t.b as usize] = 4;
            }
        }
        for i in 0..ni {
            let t = b.insts[i];
            each_use(b, t, &mut self.succ);
            for u in 0..self.succ.len() {
                let v = self.succ[u];
                if !is_inst(v) || self.xuse[v as usize] != 1 {
                    continue;
                }
                // The other operand of a comparison is a register's: no constant, no folded instruction.
                let o = ast::pick(t.a == v, t.b, t.a);
                let cmp = t.op == O_ICMP && self.xuse[i] == 0 && t.a != t.b && o != VNONE && !(is_inst(o) && (b.insts[o as usize].op == O_ICONST || self.pfold[o as usize] || self.xuse[o as usize] != 0));
                let index = t.op == O_PTRADD && t.b == v && t.a != v;
                if !cmp && !index {
                    self.xuse[v as usize] = 2;
                }
            }
        }
        for q in 0..self.scan.len() {
            let i = self.scan[q] as usize;
            if self.xuse[i] == 1 {
                self.pfold[i] = true;
            }
        }
    }

    /// The immediate amount vector shift `t` of `b` takes (`FOLD_VSHIMM`), else NONE.
    pub(package) const fn vshimm(self: &Self, b: &Body, t: Inst) u32 {
        if t.op != O_SHL && t.op != O_LSHR && t.op != O_ASHR || !is_vec(t.ty) {
            return NONE;
        }
        let eb = type_bytes(lane_type(t.ty), 8);
        let nb = type_bytes(t.ty, 8);
        let ok = if (self.fold_ops & FOLD_VSHIMM_ALL) != 0 {
            (nb == 8 || nb == 16) && !(nb == 8 && eb == 8)
        } else {
            (self.fold_ops & FOLD_VSHIMM) != 0 && eb >= 2 && !(t.op == O_ASHR && eb == 8) && (nb == 16 || nb == 32 && (self.fold_ops & FOLD_VSHIMM_WIDE) != 0)
        };
        return if ok {
            vec_shift_amount(b, t)
        } else {
            NONE
        };
    }

    /// `FOLD_LDOP`: whether load `i` of `b` (its block ending before `end`) folds into its one use, a
    /// comparison of its type or an `add`, `sub` (the load second), `and`, `or`, `xor` or `mul` (by no
    /// constant, which `imul`'s immediate form takes) of 32 or 64 bits that folds into nothing, within LDOP_REACH instructions, whose other operand is no folded
    /// instruction, with no write of memory up to where the use is computed (a folded comparison: its
    /// select's or branch's place; not a `FOLD_CARRY` select's unsigned order comparison of 32 or 64 bits,
    /// whose `adc` the generator computes from the operands' registers).
    /// Not a load of an entry parameter's aggregate (the generator takes its registers,
    /// `place::parts_taken`), of the aggregate result (which registers may hold) or of the one of a call right
    /// before (`result_load`), nor one
    /// whose operation's result is stored back in place (the generator's read-modify-write).
    const fn ldop_user(self: &Self, b: &Body, i: u32, end: u32) bool {
        let t = b.insts[i as usize];
        if (self.fold_ops & FOLD_VLDOP) != 0 && t.op == O_LOAD && is_vec(t.ty) {
            return self.vldop_user(b, i, end);
        }
        if t.op != O_LOAD || (t.aux & MEM_VOLATILE) != 0 || !(is_int(t.ty) || is_float(t.ty)) || t.ty == T_I128 || self.count[i as usize] > 2 || self.pfold[i as usize] || self.reg_param(
            b,
            t.a,
        ) || result_load(b, i, self.ret_regs) {
            return false;
        }
        if self.count[i as usize] == 2 {
            return self.wide_load(b, i, end);
        }
        let mut u = i + 1;
        while u < end && u <= i + LDOP_REACH {
            let x = b.insts[u as usize];
            let alu = x.op == O_ADD || x.op == O_SUB || x.op == O_AND || x.op == O_OR || x.op == O_XOR || x.op == O_MUL;
            let fp = is_float(t.ty) && x.op >= O_FADD && x.op <= O_FDIV && x.b == i;
            if fp || !is_float(t.ty) && (x.op == O_ICMP || alu) && (x.a == i || x.b == i) {
                break;
            }
            if writes_mem(x) {
                return false;
            }
            u += 1;
        }
        if u == end || u > i + LDOP_REACH {
            return false;
        }
        let x = b.insts[u as usize];
        let o = ast::pick(x.a == i, x.b, x.a);
        if is_inst(o) && self.pfold[o as usize] || x.op == O_MUL && (is_const_val(b, o) || o == i) {
            return false;
        }
        if is_float(t.ty) {
            return !self.pfold[u as usize];
        }
        if x.op != O_ICMP {
            let st = b.insts[u as usize + 1];
            let back = u == i + 1 && st.op == O_STORE && st.b == u && st.a == t.a && st.c == t.c;
            return !self.pfold[u as usize] && type_bits(t.ty, 8) >= 32 && (x.op != O_SUB || x.b == i) && !back;
        }
        if !self.pfold[u as usize] {
            return true;
        }
        // A folded comparison: its one select or branch, with no write of memory before.
        if self.count[u as usize] != 1 {
            return false;
        }
        for w in u + 1..end {
            let y = b.insts[w as usize];
            if y.op == O_SELECT && y.a == u {
                let side = is_inst(y.b) && self.pfold[y.b as usize] || is_inst(y.c) && self.pfold[y.c as usize];
                let order = x.aux == C_ULT || x.aux == C_UGT || x.aux == C_ULE || x.aux == C_UGE;
                let wide = type_bits(t.ty, 8) >= 32;
                return !(side && order && wide);
            }
            if y.op == O_BR && y.a == u {
                return true;
            }
            if writes_mem(y) {
                return false;
            }
        }
        return false;
    }

    // Whether 64-bit load `i` of `b` (its block ending before `end`), read twice, is an operand of a 64-bit
    // product and its high half alone (x86-64's one `mul` of the memory gives both), within LDOP_REACH
    // instructions with no write of memory from it to them.
    const fn wide_load(self: &Self, b: &Body, i: u32, end: u32) bool {
        if b.insts[i as usize].ty != T_I64 {
            return false;
        }
        let mut lo = false;
        let mut hi = false;
        let mut other = VNONE;
        let mut u = i + 1;
        while u < end && u <= i + LDOP_REACH && !(lo && hi) {
            let x = b.insts[u as usize];
            if writes_mem(x) {
                return false;
            }
            // A product's operands are values; another instruction's fields may be no values (a call's
            // symbol, a load's bound), and a use of `i` there leaves one of the two halves unfound.
            let prod = x.op == O_MUL || x.op == O_MULHU || x.op == O_MULHS;
            if prod && (x.a == i || x.b == i) {
                let o = ast::pick(x.a == i, x.b, x.a);
                if x.ty != T_I64 || o == i || other != VNONE && o != other || is_inst(o) && self.pfold[o as usize] || self.pfold[u as usize] {
                    return false;
                }
                other = o;
                if x.op == O_MUL && !lo {
                    lo = true;
                } else if x.op != O_MUL && !hi {
                    hi = true;
                } else {
                    return false;
                }
            }
            u += 1;
        }
        return lo && hi;
    }

    // Whether instruction `x` is a lane operation of `FOLD_VLDOP` on 16- or 32-byte vectors of type `ty`
    // (a product of 32-bit lanes under `FOLD_VMUL`).
    const fn vop_mem(self: &Self, x: Inst, ty: u8) bool {
        let fl = x.op >= O_FADD && x.op <= O_FDIV && is_float(lane_type(ty));
        let int = (x.op == O_ADD || x.op == O_SUB || x.op == O_AND || x.op == O_OR || x.op == O_XOR) && !is_float(
            lane_type(ty),
        );
        let mul = x.op == O_MUL && (self.fold_ops & FOLD_VMUL) != 0 && is_int(lane_type(ty)) && type_bytes(
            lane_type(ty),
            8,
        ) == 4;
        return (fl || int || mul) && x.ty == ty;
    }

    /// `FOLD_VLDOP`: whether vector load `i` of `b` (its block ending before `end`) folds into its one use,
    /// as `ldop_user`.
    const fn vldop_user(self: &Self, b: &Body, i: u32, end: u32) bool {
        let t = b.insts[i as usize];
        let n = type_bytes(t.ty, 8);
        if (t.aux & MEM_VOLATILE) != 0 || n != 16 && n != 32 || self.count[i as usize] != 1 || self.pfold[i as usize] || self.reg_param(
            b,
            t.a,
        ) || result_load(b, i, self.ret_regs) {
            return false;
        }
        let mut u = i + 1;
        // At most LDOP_REACH steps.
        while u < end && u <= i + LDOP_REACH {
            let x = b.insts[u as usize];
            if x.a == i || x.b == i || x.c == i {
                return self.vop_mem(x, t.ty) && x.b == i && x.a != i && !self.pfold[u as usize] && !(is_inst(x.a) && self.pfold[x.a as usize]);
            }
            if writes_mem(x) {
                return false;
            }
            u += 1;
        }
        return false;
    }

    /// The uses of instruction `i` of a laid-out block, as `uses_at` gives them (`ranges` found them).
    pub(package) const fn uses_of(self: &Self, i: u32) Slice<Value> {
        let a = self.ua[i as usize] as usize;
        return self.uv[a..a + self.un[i as usize] as usize];
    }

    /// Advance the next-use cursors past instruction `i`, once in layout order.
    pub(package) const fn advance(self: &mut Self, b: &Body, i: u32) {
        let a = self.ua[i as usize];
        for u in a..a + self.un[i as usize] {
            let x = self.vix(b, self.uv[u as usize]);
            self.next[x as usize] = self.use_next[u as usize];
        }
    }

    /// The value index of a parameter that a back edge of terminator `t` (of the block at layout position
    /// `pos`) passes value `v` to (an edge into a loop header not later in the layout); NONE for none. A
    /// branch's other edge must leave the loop, and no path from it reads the parameter but through the
    /// header, which defines it again (`reads_before`).
    pub(package) fn back_param(self: &Self, b: &Body, t: Inst, v: Value, pos: u32) u32 {
        let ne = jb_edges(t);
        for e in 0..ne {
            let x = edge_of(b, t, e);
            let tk = b.edge_target(x);
            if self.pos[tk as usize] > pos {
                continue;
            }
            let tb = b.blocks[tk as usize];
            for q in 0..b.edge_nargs(x) {
                if self.arg(b, x, q) != v {
                    continue;
                }
                let px = b.insts.len() as u32 + tb.param_start + q;
                if ne == 2 {
                    let o = self.pos[b.edge_target(edge_of(b, t, 1 - e)) as usize];
                    if self.lend[tk as usize] == NONE || o >= self.pos[tk as usize] && o <= self.lend[tk as usize] || self.end[px as usize] > self.lend[tk as usize] && reads_before(
                        self,
                        b,
                        b.edge_target(edge_of(b, t, 1 - e)),
                        tk,
                        VPARAM | px - b.insts.len() as u32,
                        &self.pos,
                        self.end[px as usize],
                    ) {
                        return NONE;
                    }
                }
                return px;
            }
        }
        return NONE;
    }

    /// The rare blocks of `b` (`rare`) that edges between rare blocks connect to one of `framed` (per block:
    /// it holds a call that needs the frame), the other blocks of `framed`, with each one's outermost loop
    /// (the frame is set up before the loop, not on each turn), and the blocks the entry reaches only
    /// through those: `after`, which the next `run` lays out last.
    pub(package) fn set_after(self: &mut Self, b: &Body, framed: &Vector<bool>) {
        // Per block, its component's root (union by index, paths halved: each step shortens a path).
        let nb = b.blocks.len();
        let mut root = Vector::<u32>::with_capacity(nb);
        for k in 0..nb {
            root.push(k as u32);
        }
        let mut es = Vector::<u32>::new();
        for k in 0..nb {
            if !self.rare[k] {
                continue;
            }
            let bk = b.blocks[k];
            b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut es);
            for e in 0..es.len() {
                let s = b.edge_target(es[e]);
                if self.rare[s as usize] {
                    let x = find_root(&mut root, k as u32);
                    let y = find_root(&mut root, s);
                    if x != y {
                        root[x.max(y) as usize] = x.min(y);
                    }
                }
            }
        }
        let mut fr = Vector::<bool>::new();
        fr.resize_default(nb);
        for k in 0..nb {
            if framed[k] {
                fr[find_root(&mut root, k as u32) as usize] = true;
            }
        }
        // Per loop header, whether its loop is the outermost one of a block of `framed` that is not rare.
        let mut looped = Vector::<bool>::new();
        looped.resize_default(nb);
        for k in 0..nb {
            if framed[k] && !self.rare[k] && self.inner[k] != NONE {
                looped[self.outermost(k as u32) as usize] = true;
            }
        }
        self.after.truncate(0);
        for k in 0..nb {
            self.after.push(
                self.rare[k] && fr[find_root(&mut root, k as u32) as usize] || framed[k] || self.inner[k] != NONE && looped[self.outermost(
                    k as u32,
                ) as usize],
            );
        }
        // The blocks the entry reaches through the others alone (each pushed once).
        let mut seen = Vector::<bool>::new();
        seen.resize_default(nb);
        let mut work = Vector::<u32>::new();
        if nb != 0 && !self.after[0] {
            seen[0] = true;
            work.push(0);
        }
        while let Some(k) = work.pop() {
            let bk = b.blocks[k as usize];
            b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut es);
            for e in 0..es.len() {
                let s = b.edge_target(es[e]) as usize;
                if !seen[s] && !self.after[s] {
                    seen[s] = true;
                    work.push(s as u32);
                }
            }
        }
        for k in 0..nb {
            if self.rpo[k] != NONE && !seen[k] {
                self.after[k] = true;
            }
        }
    }

    // The header of the outermost loop that holds block `k`, which is in a loop.
    const fn outermost(self: &Self, k: u32) u32 {
        let mut h = self.inner[k as usize];
        // Each step leaves one loop: at most the nesting depth.
        while self.parent[h as usize] != NONE {
            h = self.parent[h as usize];
        }
        return h;
    }

    /// How many values of `b` made before call `i` of block `d` (in an earlier block of the layout, or in
    /// `d`) are live past it: in a later block, or read after it in `d`; not one the code makes again where
    /// it is read (`remat_inst`), nor the result's address, whose stores the return's registers take.
    pub(package) fn lives_across(self: &mut Self, p: &Package, b: &Body, d: u32, i: u32) u32 {
        let ni = b.insts.len() as u32;
        let pd = self.pos[d as usize];
        let res = if (b.pool[b.sig as usize + 2] & AGG) != 0 {
            ni + b.blocks[0].param_start + b.pool[b.sig as usize]
        } else {
            NONE
        };
        let mut n: u32 = 0;
        for x in 0..self.end.len() as u32 {
            let k = self.def_blk[x as usize];
            if x == i || x == res || k == NONE || self.pos[k as usize] == NONE || x < ni && remat_inst(p, b, x) {
                continue;
            }
            let before = if k == d {
                x >= ni || x < i
            } else {
                self.pos[k as usize] < pd
            };
            let v = if x < ni {
                x
            } else {
                VPARAM | x - ni
            };
            if before && (self.end[x as usize] > pd || self.end[x as usize] == pd && self.reads_after(b, d, i, v)) {
                n += 1;
            }
        }
        return n;
    }

    /// What the homes saved around a call of block `d` cost a body that sets its frame up in `after`
    /// alone: a store and a load per `per` of the `n` values live past the call (`lives_across`), as often
    /// as `d` runs.
    pub(package) const fn around_cost(self: &Self, d: u32, n: u32, per: u32) u64 {
        return self.freq[d as usize] * 2 * ((n + per - 1) / per) as u64;
    }

    /// How often the edges from the other blocks into the blocks of `after` run (`frequencies`' shares);
    /// FREQ_MAX when the entry is one of those blocks.
    pub(package) fn after_into(self: &mut Self, b: &Body) u64 {
        if self.after[0] {
            return FREQ_MAX;
        }
        return self.after_edges(b, false);
    }

    /// How often the edges out of the blocks of `after` into the others run, as `after_into`: each takes
    /// the frame down and jumps on.
    pub(package) fn after_out(self: &mut Self, b: &Body) u64 {
        return self.after_edges(b, true);
    }

    // The frequency of the edges from the blocks outside `after` into its blocks (`leave`: from its blocks
    // into the others).
    fn after_edges(self: &mut Self, b: &Body, leave: bool) u64 {
        let mut into: u64 = 0;
        for p in 0..b.blocks.len() {
            if self.rpo[p] == NONE || self.after[p] != leave {
                continue;
            }
            let bk = b.blocks[p];
            b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut self.fedges);
            let mut total: u64 = 0;
            for e in 0..self.fedges.len() {
                total += ast::pick(self.rare[b.edge_target(self.fedges[e]) as usize], 1u64, FREQ_SPLIT);
            }
            for e in 0..self.fedges.len() {
                let t = b.edge_target(self.fedges[e]);
                if self.after[t as usize] == leave {
                    continue;
                }
                let mut share = self.freq[p] * ast::pick(self.rare[t as usize], 1u64, FREQ_SPLIT) / total;
                // Each loop the edge leaves: at most the nesting depth.
                let mut h = self.inner[p];
                while h != NONE && !self.in_loop(h, t) {
                    share /= FREQ_LOOP;
                    h = self.parent[h as usize];
                }
                into += share;
            }
        }
        return into;
    }

    /// Whether a frame set up on the edges into the blocks of `after`, which run `into` (`after_into`),
    /// costs less than one at the entry: its save, its restore and the jump out of the stub that holds
    /// them as often as those edges run, plus `around` (the homes saved around the calls outside rare
    /// blocks, `around_cost`), against a save and a restore per entry, and a callee-saved register's when
    /// a home lives past such a call.
    pub(package) const fn frame_pays(self: &Self, into: u64, around: u64) bool {
        return 3 * into + around < ast::pick(around != 0, 4u64, 2u64) * FREQ_ENTRY;
    }

    /// Whether that frame costs less than one at the entry when `n` values live past a call outside rare
    /// blocks, each in a callee-saved register in the blocks of `after` (`per` of them per save): the
    /// frame's save, restore and jump, the registers' saves and restores, and a move per value on the
    /// way in, as often as those edges run, and two jumps and a move per value on each edge back out
    /// (`out`, `after_out`), against the saves and restores per entry.
    pub(package) const fn frame_keeps(self: &Self, into: u64, out: u64, n: u32, per: u32) bool {
        let saves = 2 * ((n + per - 1) / per) as u64;
        return (3 + saves + n as u64) * into + (2 + n as u64) * out < (2 + saves) * FREQ_ENTRY;
    }

    /// Whether `frame_keeps` holds for any count of values: the edges in, and half of the edges back out,
    /// run at most half as often as the entry.
    pub(package) const fn frame_half(self: &Self, into: u64, out: u64) bool {
        return 2 * into + out <= FREQ_ENTRY;
    }

    /// Whether an instruction of block `k` of `b` after instruction `i`, its terminator's edges included,
    /// reads value `v`.
    pub(package) fn reads_after(self: &mut Self, b: &Body, k: u32, i: u32, v: Value) bool {
        let bk = b.blocks[k as usize];
        let mut out = replace(&mut self.rd, Vector::<Value>::new());
        let mut found = false;
        for j in i + 1..bk.start + bk.len {
            self.uses_at(b, j, &mut out);
            for u in 0..out.len() {
                found = found || out[u] == v;
            }
            if found {
                break;
            }
        }
        self.rd = out;
        return found;
    }

    /// Whether instruction `m` of `b`, a reader of block parameter value index `px` of its type, may keep its
    /// value in `px`'s stack slot (the generators' `step_slot`): `m` is the one instruction that reads `px`,
    /// and each loop around `m`'s block holds `px`'s (`m` runs once per value of `px`), so `px` is dead from
    /// `m` on; and an edge of a block in `m`'s range that writes that slot with another value leaves a block
    /// where `m` is dead. Such an edge enters `px`'s block, or a block whose jump passes one of its
    /// parameters to `px` (which may share the slot: `place::back_share`).
    pub(package) fn slot_partner(self: &Self, b: &Body, m: u32, px: u32) bool {
        let d = self.def_blk[m as usize];
        let h = self.def_blk[px as usize];
        if self.sole[px as usize] != m || d == NONE || h == NONE || self.pos[d as usize] == NONE || self.pos[h as usize] == NONE {
            return false;
        }
        let ph = self.pos[h as usize];
        let mut l = self.inner[d as usize];
        // Each step leaves one loop.
        while l != NONE {
            if ph < self.pos[l as usize] || ph > self.lend[l as usize] {
                return false;
            }
            l = self.parent[l as usize];
        }
        let ni = b.insts.len() as u32;
        let q = px - ni - b.blocks[h as usize].param_start;
        let lo = self.pos[d as usize];
        let hi = self.end[m as usize];
        // Per layout position of the range, whether `m` is live into its block: filled for the first edge
        // that needs it.
        let mut live = Vector::<bool>::new();
        for p in lo..hi + 1 {
            let t = term(b, self.order[p as usize]);
            let mut other = false;
            for e in 0..edge_count(t) {
                let ed = edge_of(b, t, e);
                let j = b.edge_target(ed);
                if j == h {
                    other = other || self.arg(b, ed, q) != m;
                    continue;
                }
                let jt = term(b, j);
                if jt.op != O_JMP || b.edge_target(jt.a) != h {
                    continue;
                }
                let jb = b.blocks[j as usize];
                let a = self.arg(b, jt.a, q);
                other = other || (a & VPARAM) != 0 && (a & ~VPARAM) >= jb.param_start && (a & ~VPARAM) < jb.param_start + jb.param_len as u32 && self.arg(
                    b,
                    ed,
                    (a & ~VPARAM) - jb.param_start,
                ) != m;
            }
            if !other {
                continue;
            }
            if live.len() == 0 {
                self.live_into(b, m, d, lo, hi, &mut live);
            }
            // The edges' moves may run before the branch: `m` is dead past every edge.
            for e in 0..edge_count(t) {
                let ed = edge_of(b, t, e);
                let sp = self.pos[b.edge_target(ed) as usize];
                if sp >= lo && sp <= hi && live[(sp - lo) as usize] {
                    return false;
                }
                for a in 0..b.edge_nargs(ed) {
                    if self.arg(b, ed, a) == m {
                        return false;
                    }
                }
            }
        }
        return true;
    }

    /// Whether value index `x` of `b` is live into block `k`: read on a path from `k`'s entry that does not
    /// pass its definition (`live_into` over its range, outside which it is dead).
    pub(package) fn live_in(self: &Self, b: &Body, x: u32, k: u32) bool {
        let d = self.def_blk[x as usize];
        if d == NONE || d == k || self.pos[d as usize] == NONE || self.pos[k as usize] == NONE {
            return false;
        }
        let lo = self.pos[d as usize];
        let hi = self.end[x as usize];
        let p = self.pos[k as usize];
        if p < lo || p > hi {
            return false;
        }
        let ni = b.insts.len() as u32;
        let v = if x < ni {
            x
        } else {
            VPARAM | x - ni
        };
        let mut out = Vector::<bool>::new();
        self.live_into(b, v, d, lo, hi, &mut out);
        return out[(p - lo) as usize];
    }

    // Per layout position `lo..=hi` (the range of instruction `m` of block `d`) into `out`: whether `m` is
    // live into the block there, a backward fixpoint over the range's reads of `m` (it is dead outside the
    // range, and into `d`, which defines it).
    fn live_into(self: &Self, b: &Body, m: u32, d: u32, lo: u32, hi: u32, out: &mut Vector<bool>) {
        let n = (hi - lo + 1) as usize;
        let mut reads = Vector::<bool>::with_capacity(n);
        for p in lo..hi + 1 {
            let bk = b.blocks[self.order[p as usize] as usize];
            let mut r = false;
            for i in bk.start..bk.start + bk.len {
                let us = self.uses_of(i);
                for u in 0..us.len() {
                    r = r || us[u] == m;
                }
            }
            reads.push(r);
        }
        self.live_spread(b, d, lo, hi, &reads, out);
    }

    // Per layout position `lo..=hi` into `out`: whether the value block `d` (at `lo`) defines is live into
    // the block there, given the blocks that read it (`reads`, per position): a backward fixpoint over the
    // range (the value is dead outside it, and into `d`).
    fn live_spread(self: &Self, b: &Body, d: u32, lo: u32, hi: u32, reads: &Vector<bool>, out: &mut Vector<bool>) {
        let n = (hi - lo + 1) as usize;
        fill(out, n, false);
        let mut changed = true;
        let mut passes: usize = 0;
        // Each pass that changes marks one more block: at most `n` of them, and one that settles.
        while changed && passes <= n {
            changed = false;
            passes += 1;
            for k in 0..n {
                let p = hi - k as u32;
                let blk = self.order[p as usize];
                if blk == d || out[n - 1 - k] {
                    continue;
                }
                let mut l = reads[n - 1 - k];
                let t = term(b, blk);
                for e in 0..edge_count(t) {
                    let sp = self.pos[b.edge_target(edge_of(b, t, e)) as usize];
                    l = l || sp >= lo && sp <= hi && out[(sp - lo) as usize];
                }
                if l {
                    out[n - 1 - k] = true;
                    changed = true;
                }
            }
        }
    }

    // `FOLD_XADDR` over `b`: each address `ptradd` that the loads and stores of its block alone read, as
    // their address, folds into them all.
    const fn fold_addrs(self: &mut Self, b: &Body) {
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let p = b.insts[i as usize];
                if p.op != O_PTRADD || p.b == VNONE || p.c != 0 || scale_of(p) != 1 && scale_of(p) != 2 && scale_of(p) != 4 && scale_of(
                    p,
                ) != 8 || self.pfold[i as usize] || self.count[i as usize] == 0 {
                    continue;
                }
                let mut n: u32 = 0;
                for j in i + 1..bk.start + bk.len {
                    if self.addr_of(b, j) == i {
                        n += 1;
                    }
                }
                if n != self.count[i as usize] {
                    continue;
                }
                self.pfold[i as usize] = true;
                for j in i + 1..bk.start + bk.len {
                    if self.addr_of(b, j) == i {
                        self.fold[j as usize] = true;
                    }
                }
            }
        }
    }

    // The address instruction `j` of `b` accesses through when it is a load or store a folded address may
    // serve (`fold`'s rule: not volatile, a value a register holds, the stored value not the address);
    // NONE else.
    const fn addr_of(self: &Self, b: &Body, j: u32) u32 {
        let t = b.insts[j as usize];
        if t.op != O_LOAD && t.op != O_STORE || (t.aux & MEM_VOLATILE) != 0 || (t.a & (VPARAM | VFLAG)) != 0 || t.op == O_STORE && t.b == t.a {
            return NONE;
        }
        let ty = if t.op == O_LOAD {
            t.ty
        } else {
            b.type_of(t.b)
        };
        let n = type_bytes(ty, 8);
        return ast::pick(is_vec(ty) && n != 8 && n != 16 || ty == T_I128, NONE, t.a);
    }

    /// Whether `v` of `b` is a parameter of a block other than the entry that every edge into it passes a
    /// constant: verified LIR holds a narrow constant zero-extended (`verify::fits`), which the backends
    /// write as it is, by an edge's move or from a switch's table (a narrow load), so the parameter's
    /// register holds it so.
    pub(package) const fn zero_param(self: &Self, b: &Body, v: Value) bool {
        if (v & VPARAM) == 0 {
            return false;
        }
        let k = self.def_blk[self.vix(b, v) as usize];
        if k == 0 {
            return false;
        }
        let q = (v & ~VPARAM) - b.blocks[k as usize].param_start;
        for j in self.pat[k as usize]..self.pat[k as usize + 1] {
            let pb = b.blocks[self.preds[j as usize] as usize];
            let t = b.insts[(pb.start + pb.len - 1) as usize];
            let ne = edge_count(t);
            for e in 0..ne {
                let ed = edge_of(b, t, e);
                let mut c: u64 = 0;
                if b.edge_target(ed) == k && !const_of(b, self.arg(b, ed, q), &mut c) {
                    return false;
                }
            }
        }
        return true;
    }

    /// Whether the stores into slot `s` of `b` relay (`relay`): every use of its addresses is such a store
    /// or a call's argument, so no instruction reads or writes its memory.
    pub(package) const fn relays_slot(self: &Self, b: &Body, s: u32) bool {
        for q in 0..self.relayed.len() {
            if b.insts[b.insts[(self.relayed[q] & 0xFFFFFFFF) as usize].a as usize].a == s {
                return true;
            }
        }
        return false;
    }

    /// The values instruction `i` of `b` uses, as `each_use` gives them but for the folded instructions
    /// (`pfold`): a use of one is a use of its operands, and one uses none.
    pub(package) fn uses_at(self: &Self, b: &Body, i: u32, out: &mut Vector<Value>) {
        if self.pfold[i as usize] || self.relay.len() != 0 && self.relay[i as usize] != NONE || self.seen(i) != i {
            out.truncate(0);
            return;
        }
        each_use(b, b.insts[i as usize], out);
        let mut u: usize = 0;
        let mut n: u32 = 0;
        while u < out.len() {
            // A read of a view reads its value, which is no folded instruction.
            let v = self.seen(out[u]);
            out[u] = v;
            if (v & (VPARAM | VFLAG)) != 0 || !self.pfold[v as usize] {
                u += 1;
                continue;
            }
            n += 1;
            assert(n <= FOLD_DEPTH, "live: more folded instructions in one use than FOLD_DEPTH");
            let p = b.insts[v as usize];
            out.swap_remove(u);
            if p.op == O_SPLAT && is_inst(p.a) && self.pfold[p.a as usize] {
                // A lane a product multiplies by (`FOLD_LANE_MUL`): its lane read.
                out.push(p.a);
            } else if p.op == O_SPLAT || p.op == O_WCONST {
                // An immediate shift amount (`FOLD_VSHIMM`): nothing.
            } else if p.op == O_VOP {
                // Its operands in the pool (`FOLD_ANY`'s one).
                for q in 0..p.b {
                    out.push(b.pool[(p.a + q) as usize]);
                }
            } else {
                out.push(p.a);
                // A load's `b` is its bound (`MEM_RANGE`), no operand.
                if p.b != VNONE && p.op != O_LOAD {
                    out.push(p.b);
                }
                // A select moves with its sides (`FOLD_SINK`).
                if p.op == O_SELECT {
                    out.push(p.c);
                }
            }
        }
        let (lo, hi) = self.relayed_of(i);
        for q in lo..hi {
            // A relayed view too is a read of its value.
            out.push(self.seen(b.insts[(self.relayed[q as usize] & 0xFFFFFFFF) as usize].b));
        }
    }

    /// The range of `relayed` that holds call `i`'s stores (`relay_lo`).
    pub(package) const fn relayed_of(self: &Self, i: u32) (u32, u32) {
        if self.relay_lo.len() == 0 || self.relay_lo[i as usize] == NONE {
            return (0, 0);
        }
        let lo = self.relay_lo[i as usize];
        let mut hi = lo;
        while hi as usize < self.relayed.len() && (self.relayed[hi as usize] >> 32) as u32 == i {
            hi += 1;
        }
        return (lo, hi);
    }

    // `FOLD_CCMP`: each `and` or `or` of flags whose operands are comparisons of integers of up to 64 bits
    // with this one use and no folded operand, or such folded `and`s and `or`s, one of the two a
    // comparison, at most CCMP_MAX comparisons in all: its comparisons fold into it (`conj`), and it folds
    // into its users when each is a `select`'s or a `br`'s condition. Instructions come after their
    // operands, so an inner `and` is known before the one that takes it.
    fn conj_folds(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        fill(&mut self.cnd, ni, 0);
        self.scan_ops([O_SELECT, O_BR]);
        for q in 0..self.scan.len() {
            let t = b.insts[self.scan[q] as usize];
            if (t.a & (VPARAM | VFLAG)) == 0 {
                self.cnd[t.a as usize] += 1;
            }
        }
        self.scan_ops([O_AND, O_OR]);
        for q in 0..self.scan.len() {
            let i = self.scan[q] as usize;
            let t = b.insts[i];
            if t.ty != T_I8 || self.pfold[i] || self.count[i] == 0 {
                continue;
            }
            let mut na = self.conj_part(b, t.a);
            let mut nb = self.conj_part(b, t.b);
            let leaf_a = na == 1 && b.insts[t.a as usize].op == O_ICMP;
            let leaf_b = nb == 1 && b.insts[t.b as usize].op == O_ICMP;
            // A comparison of a folded operand (a `tst`) starts the chain, before a comparison the other
            // side is: the generator compares it first (`conj_flags`).
            if na == 0 && leaf_b && self.tst_leaf(b, t.a) {
                na = 1;
            } else if nb == 0 && leaf_a && self.tst_leaf(b, t.b) {
                nb = 1;
            }
            if na == 0 || nb == 0 || !leaf_a && !leaf_b || na + nb > CCMP_MAX {
                // No chain: `FOLD_FJOIN` folds one side's comparisons when the other side is 0 or 1.
                let (p, y) = if na != 0 {
                    (t.a, t.b)
                } else {
                    (t.b, t.a)
                };
                if (self.fold_ops & FOLD_FJOIN) != 0 && na + nb != 0 && zero_one(b, y, ZO_DEPTH) {
                    self.pfold[p as usize] = true;
                }
                continue;
            }
            self.conj[i] = na + nb;
            self.pfold[t.a as usize] = true;
            self.pfold[t.b as usize] = true;
            self.pfold[i] = self.cnd[i] == self.count[i];
        }
    }

    /// The operand whose comparisons `and` or `or` `i` of flags folds (`FOLD_FJOIN`): a comparison or a
    /// chain of them (`conj`); VNONE when it folds none. No other fold leaves a folded comparison under an
    /// `and` or `or` that is neither a chain nor folded itself.
    pub(package) const fn join_part(self: &Self, b: &Body, i: u32) Value {
        let t = b.insts[i as usize];
        if (self.fold_ops & FOLD_FJOIN) == 0 || t.op != O_AND && t.op != O_OR || t.ty != T_I8 || self.pfold[i as usize] || self.conj[i as usize] != 0 {
            return VNONE;
        }
        if self.flag_part(b, t.a) {
            return t.a;
        }
        return ast::pick(self.flag_part(b, t.b), t.b, VNONE);
    }

    // Whether `v` is a folded comparison or chain of them.
    const fn flag_part(self: &Self, b: &Body, v: Value) bool {
        return is_inst(v) && self.pfold[v as usize] && (b.insts[v as usize].op == O_ICMP || self.conj[v as usize] != 0);
    }

    // Whether `v` is an integer comparison of up to 64 bits with one use that folds into nothing
    // (`FOLD_BRCONJ`).
    const fn cmp_leaf(self: &Self, b: &Body, v: Value) bool {
        if !is_inst(v) || b.insts[v as usize].op != O_ICMP || self.count[v as usize] != 1 || self.pfold[v as usize] {
            return false;
        }
        let ty = b.type_of(b.insts[v as usize].a);
        return is_int(ty) && ty != T_I128 || ty == T_PTR;
    }

    // The difference and the sum `FOLD_ADDSUB` folds into lane select `t`: (VNONE, VNONE) when none.
    pub(package) const fn addsub_parts(self: &Self, b: &Body, t: Inst) (Value, Value) {
        let nb = type_bytes(t.ty, 8);
        if t.op != O_VSEL || !is_float(lane_type(t.ty)) || nb != 16 && (nb != 32 || (self.fold_ops & FOLD_ADDSUB_WIDE) == 0) || !is_inst(
            t.a,
        ) || !is_inst(t.b) || !is_inst(t.c) || self.count[t.b as usize] != 1 || self.count[t.c as usize] != 1 {
            return (VNONE, VNONE);
        }
        let d = b.insts[t.b as usize];
        let s = b.insts[t.c as usize];
        let m = b.insts[t.a as usize];
        if d.op != O_FSUB || s.op != O_FADD || d.a != s.a || d.b != s.b || d.ty != t.ty || s.ty != t.ty || m.op != O_WCONST || m.b != nb / 8 {
            return (VNONE, VNONE);
        }
        // The mask's words: each pair of lanes the even one's bits, of 8-byte lanes every other word.
        let eight = type_bytes(lane_type(t.ty), 8) == 8;
        for q in 0..m.b {
            let want = if eight {
                ast::pick(q % 2 == 0, ~0u64, 0u64)
            } else {
                0x00000000FFFFFFFF
            };
            if b.words[(m.a + q) as usize] != want {
                return (VNONE, VNONE);
            }
        }
        return (t.b, t.c);
    }

    // The product `FOLD_VMLA` folds into vector sum or difference `t`: its second operand, else (a sum) its
    // first. VNONE when none.
    pub(package) fn vmla_mul(self: &Self, b: &Body, t: Inst) Value {
        let lt = lane_type(t.ty);
        let nb = type_bytes(t.ty, 8);
        if !is_int(lt) || nb != 8 && nb != 16 {
            return VNONE;
        }
        let narrow = type_bytes(lt, 8) < 8;
        let ok = |v: Value| (v & (VPARAM | VFLAG)) == 0 && v != VNONE && (b.insts[v as usize].op == O_MUL && narrow || b.insts[v as usize].op == O_VMULW && nb == 16) && b.insts[v as usize].ty == t.ty && self.count[v as usize] == 1;
        if ok(t.b) && t.b != t.a {
            return t.b;
        }
        return ast::pick(t.op == O_ADD && ok(t.a) && t.a != t.b, t.a, VNONE);
    }

    // The right shift by an immediate `FOLD_VMLA` folds into vector sum `t` when no product does: its second
    // operand, else its first. VNONE when none.
    pub(package) fn vsra_shift(self: &Self, b: &Body, t: Inst) Value {
        let ok = |v: Value| is_inst(v) && (b.insts[v as usize].op == O_LSHR || b.insts[v as usize].op == O_ASHR) && b.insts[v as usize].ty == t.ty && self.count[v as usize] == 1 && self.vshimm(
            b,
            b.insts[v as usize],
        ) != NONE && self.vshimm(b, b.insts[v as usize]) != 0;
        if ok(t.b) && t.b != t.a {
            return t.b;
        }
        return ast::pick(ok(t.a) && t.a != t.b, t.a, VNONE);
    }

    // The absolute difference `FOLD_VSAD` folds into widening sum `t`: its second operand, an unsigned
    // `SIMD_ABS_DIFF` of two byte vectors of one use, when `t` sums into 8-byte lanes. VNONE when none.
    pub(package) const fn vsad_diff(self: &Self, b: &Body, t: Inst) Value {
        let v = t.b;
        if type_bytes(lane_type(t.ty), 8) != 8 || (v & (VPARAM | VFLAG)) != 0 || v == VNONE || self.count[v as usize] != 1 {
            return VNONE;
        }
        let d = b.insts[v as usize];
        let code = (core::OP_SIMD + core::SIMD_ABS_DIFF as u32) as u16;
        return ast::pick(d.op == O_VOP && d.aux == code && d.b == 2 && type_bytes(lane_type(d.ty), 8) == 1, v, VNONE);
    }

    // The extension `FOLD_VWADD` folds into vector sum `t`: its second operand, else its first. VNONE when
    // none.
    pub(package) const fn vwadd_ext(self: &Self, b: &Body, t: Inst) Value {
        let lt = lane_type(t.ty);
        if !is_int(lt) || type_bytes(lt, 8) < 2 || type_bytes(t.ty, 8) != 16 {
            return VNONE;
        }
        if self.zero_zip(b, lt, t.b) && t.b != t.a {
            return t.b;
        }
        return ast::pick(self.zero_zip(b, lt, t.a) && t.a != t.b, t.a, VNONE);
    }

    // Whether `v`, with one use, is a `bitcast` to lanes of type `lt` of a 16-byte `vziplo` or `vziphi`,
    // with one use, of a vector of half-width lanes with zeros (`FOLD_VWADD`).
    const fn zero_zip(self: &Self, b: &Body, lt: u8, v: Value) bool {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || self.count[v as usize] != 1 || b.insts[v as usize].op != O_BITCAST {
            return false;
        }
        let z = b.insts[v as usize].a;
        if (z & (VPARAM | VFLAG)) != 0 || z == VNONE || self.count[z as usize] != 1 {
            return false;
        }
        let zt = b.insts[z as usize];
        return (zt.op == O_VZIPLO || zt.op == O_VZIPHI) && type_bytes(zt.ty, 8) == 16 && 2 * type_bytes(
            lane_type(zt.ty),
            8,
        ) == type_bytes(lt, 8) && zero_vec(b, zt.b) && zt.a != zt.b;
    }

    // Whether `O_VOP` `t` is an `or` of the lanes of an integer lane mask that `FOLD_ANY` (16 bytes) or
    // `FOLD_ANY_WIDE` (32) folds.
    fn any_fold(self: &Self, b: &Body, t: Inst) bool {
        if (t.aux & VOP_CODE) as u32 != core::OP_SIMD + core::SIMD_REDUCE_OR as u32 || t.b != 1 {
            return false;
        }
        let v = b.pool[t.a as usize];
        let nb = type_bytes(b.type_of(v), 8);
        let f = if nb == 16 {
            FOLD_ANY
        } else if nb == 32 {
            FOLD_ANY_WIDE
        } else {
            0
        };
        return (self.fold_ops & f) != 0 && (lane_mask(b, v, MASK_DEPTH) || (self.fold_ops & FOLD_ANY_BITS) != 0 && is_int(
            lane_type(b.type_of(v)),
        ));
    }

    // Whether the instructions that make mask bits `m` (`pred_mask`: extensions and truncations, then a lane
    // comparison, or the lanes' sum and the AND of a lane mask with their bits) have no other reader than the
    // next of them, and with `mark`, fold them (`FOLD_PRED`), the AND's constant too when it alone reads it.
    const fn pred_chain(self: &mut Self, b: &Body, m: Value, mark: bool) bool {
        let mut x = m;
        // At most 6 extensions and truncations (`pred_mask`), the comparison or the sum and the AND.
        for _ in 0..8 {
            if x != m && self.count[x as usize] != 1 {
                return false;
            }
            if mark {
                self.pfold[x as usize] = true;
            }
            let t = b.insts[x as usize];
            if t.op == O_AND {
                if mark && is_inst(t.b) && self.count[t.b as usize] == 1 {
                    self.pfold[t.b as usize] = true;
                }
                return true;
            }
            if t.op == O_VOP && (t.aux & VOP_CODE) as u32 != core::OP_SIMD + core::SIMD_REDUCE_ADD as u32 {
                return true;
            }
            x = ast::pick(t.op == O_VOP, b.pool[t.a as usize], t.a);
        }
        return false;
    }

    // Whether `v` is an equality with 0 of an `and` `FOLD_TST` folds, which this use alone reads: a chain's
    // first comparison (`conj_folds`).
    const fn tst_leaf(self: &Self, b: &Body, v: Value) bool {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || self.count[v as usize] != 1 || self.pfold[v as usize] {
            return false;
        }
        let t = b.insts[v as usize];
        return t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) && (t.a & (VPARAM | VFLAG)) == 0 && self.pfold[t.a as usize] && b.insts[t.a as usize].op == O_AND;
    }

    // Whether `s` is a shift of `bits` bits by a constant below them, read once and not folded yet: an
    // operand `FOLD_SHOP` folds.
    const fn shop_ok(self: &Self, b: &Body, s: Value, bits: u32) bool {
        if !is_inst(s) || self.pfold[s as usize] || self.count[s as usize] != 1 {
            return false;
        }
        let t = b.insts[s as usize];
        return t.op >= O_SHL && t.op <= O_ASHR && type_bits(t.ty, 8) == bits && int_const(b, t.b) < bits as u64;
    }

    // The comparisons operand `v` of an `and` or `or` brings to a `FOLD_CCMP` chain: 1 for a comparison it
    // alone uses, the chain's count for a chain it alone uses, else 0.
    const fn conj_part(self: &Self, b: &Body, v: Value) u8 {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || self.count[v as usize] != 1 || self.pfold[v as usize] {
            return 0;
        }
        let t = b.insts[v as usize];
        if self.conj[v as usize] != 0 {
            return self.conj[v as usize];
        }
        if t.op != O_ICMP || !is_int(b.type_of(t.a)) || b.type_of(t.a) == T_I128 {
            return 0;
        }
        let folded = (t.a & (VPARAM | VFLAG)) == 0 && self.pfold[t.a as usize] || t.b != VNONE && (t.b & (VPARAM | VFLAG)) == 0 && self.pfold[t.b as usize];
        return ast::pick(folded, 0, 1);
    }

    // `rpo`: the reverse postorder number of each block the entry reaches, by an explicit-stack DFS
    // (`stack` holds block << 1 | finished). A block is visited when popped, so it may be pushed once
    // per edge into it.
    fn reverse_postorder(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        let mut seen = Vector::<bool>::new();
        seen.resize_default(nb);
        self.work.truncate(0); // postorder
        self.stack.truncate(0);
        self.stack.push(0);
        // Each pop finishes a block, visits one, or drops an edge's repeat: at most 2 per block and 1 per edge.
        while self.stack.len() != 0 {
            let x = self.stack.pop().unwrap();
            let k = x >> 1;
            if (x & 1) != 0 {
                self.work.push(k);
                continue;
            }
            if seen[k as usize] {
                continue;
            }
            seen[k as usize] = true;
            self.stack.push(k << 1 | 1);
            let t = b.insts[(b.blocks[k as usize].start + b.blocks[k as usize].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            // Pushed in reverse, so the first successor is visited first.
            let mut e = self.succ.len();
            while e > 0 {
                e -= 1;
                let s = b.edge_target(self.succ[e]);
                if !seen[s as usize] {
                    self.stack.push(s << 1);
                }
            }
        }
        let n = self.work.len() as u32;
        for i in 0..self.work.len() {
            self.rpo[self.work[i] as usize] = n - 1 - i as u32;
        }
    }

    // Natural loops: an edge to a block whose number is not above its source's is a back edge to a loop
    // header; the loop is what reaches a back edge's source without passing the header. Headers are
    // taken innermost first (highest number first), so a block's first loop is its innermost and a
    // header's first enclosing loop its parent.
    fn loops(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        // Predecessor lists (CSR): `pat` holds the starts, `preds` the sources.
        let mut start = replace(&mut self.pat, Vector::<u32>::new());
        start.truncate(0);
        let mut acc: u32 = 0;
        for k in 0..nb {
            start.push(acc);
            acc += self.npred[k];
        }
        start.push(acc);
        let mut fillp = Vector::<u32>::with_capacity(nb);
        fillp.extend_copy(&start);
        let mut preds = replace(&mut self.preds, Vector::<u32>::new());
        fill(&mut preds, acc as usize, 0);
        let mut hdrs = Vector::<u64>::new();
        for k in 0..nb {
            if self.rpo[k] == NONE {
                continue;
            }
            let t = b.insts[(b.blocks[k].start + b.blocks[k].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                let s = b.edge_target(self.succ[e]);
                preds[fillp[s as usize] as usize] = k as u32;
                fillp[s as usize] += 1;
                if self.rpo[s as usize] <= self.rpo[k] {
                    hdrs.push(self.rpo[s as usize] as u64 << 32 | s as u64);
                }
            }
        }
        hdrs.sort();
        hdrs.dedup();
        let mut mark = Vector::<u32>::new();
        fill(&mut mark, nb, NONE);
        let mut i = hdrs.len();
        while i > 0 {
            i -= 1;
            let h = hdrs[i] as u32;
            // The loop of `h`: from the back edges' sources backward to `h`.
            self.stack.truncate(0);
            mark[h as usize] = h;
            for q in start[h as usize]..start[h as usize + 1] {
                let p = preds[q as usize];
                if self.rpo[p as usize] >= self.rpo[h as usize] && mark[p as usize] != h {
                    mark[p as usize] = h;
                    self.stack.push(p);
                }
            }
            if self.inner[h as usize] == NONE {
                self.inner[h as usize] = h;
            }
            // Each block enters the stack once per loop.
            while self.stack.len() != 0 {
                let x = self.stack.pop().unwrap();
                if self.inner[x as usize] == NONE {
                    self.inner[x as usize] = h;
                } else if self.inner[x as usize] == x && self.parent[x as usize] == NONE && x != h {
                    self.parent[x as usize] = h;
                }
                for q in start[x as usize]..start[x as usize + 1] {
                    let p = preds[q as usize];
                    if self.rpo[p as usize] != NONE && mark[p as usize] != h {
                        mark[p as usize] = h;
                        self.stack.push(p);
                    }
                }
            }
        }
        self.pat = start;
        self.preds = preds;
    }

    // `rare`: the reachable blocks the entry reaches only through a block marked rare, that block included;
    // none when the entry is marked or the generator emits the blocks in place (`in_place`).
    fn rare_blocks(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        self.rare.truncate(0);
        let marked = (b.blocks[0].flags & BLOCK_RARE) != 0 || self.in_place;
        for k in 0..nb {
            self.rare.push(self.rpo[k] != NONE && !marked);
        }
        if marked {
            return;
        }
        self.rare[0] = false;
        self.stack.truncate(0);
        self.stack.push(0);
        // Each block enters the stack once.
        while self.stack.len() != 0 {
            let k = self.stack.pop().unwrap();
            let t = b.insts[(b.blocks[k as usize].start + b.blocks[k as usize].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                let s = b.edge_target(self.succ[e]);
                if self.rare[s as usize] && (b.blocks[s as usize].flags & BLOCK_RARE) == 0 {
                    self.rare[s as usize] = false;
                    self.stack.push(s);
                }
            }
        }
    }

    // `order` and `pos`: the reachable warm blocks in reverse postorder, where a loop header brings its
    // whole loop (its members in reverse postorder, nested loops likewise); then the rare blocks.
    fn layout(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        // The warm blocks in reverse postorder.
        self.keys.truncate(0);
        for k in 0..nb {
            if self.rpo[k] != NONE && !self.rare[k] {
                self.keys.push(self.rpo[k] as u64 << 32 | k as u64);
            }
        }
        self.keys.sort();
        // Each loop's members in reverse postorder (CSR by header): `mstart[h]..mstart[h] + mlen[h]`.
        let mut mlen = Vector::<u32>::new();
        fill(&mut mlen, nb, 0);
        for i in 0..self.keys.len() {
            let mut h = self.inner[(self.keys[i] as u32) as usize];
            while h != NONE {
                mlen[h as usize] += 1;
                h = self.parent[h as usize];
            }
        }
        let mut mstart = Vector::<u32>::with_capacity(nb);
        let mut acc: u32 = 0;
        for k in 0..nb {
            mstart.push(acc);
            acc += mlen[k];
            mlen[k] = 0;
        }
        let mut mlist = Vector::<u32>::new();
        mlist.resize_default(acc as usize);
        for i in 0..self.keys.len() {
            let k = self.keys[i] as u32;
            let mut h = self.inner[k as usize];
            while h != NONE {
                mlist[(mstart[h as usize] + mlen[h as usize]) as usize] = k;
                mlen[h as usize] += 1;
                h = self.parent[h as usize];
            }
        }
        // A stack of lists being walked: list (NONE the whole body, else a header) << 32 | next index.
        self.order.truncate(0);
        let mut placed = Vector::<bool>::new();
        placed.resize_default(nb);
        self.stack.truncate(0);
        let mut lists = Vector::<u64>::new();
        lists.push(NONE as u64 << 32);
        // Each step places a block, opens a loop once, or closes a list: at most 3 per block.
        while lists.len() != 0 {
            let top = lists.len() - 1;
            let l = (lists[top] >> 32) as u32;
            let i = lists[top] as u32;
            let n = if l == NONE {
                self.keys.len() as u32
            } else {
                mlen[l as usize]
            };
            if i == n {
                let _ = lists.pop();
                continue;
            }
            lists[top] = lists[top] + 1;
            let k = if l == NONE {
                self.keys[i as usize] as u32
            } else {
                mlist[(mstart[l as usize] + i) as usize]
            };
            if placed[k as usize] {
                continue;
            }
            if self.inner[k as usize] == k && l != k {
                lists.push(k as u64 << 32);
                continue;
            }
            placed[k as usize] = true;
            self.order.push(k);
        }
        self.early_returns(b);
        // The rare blocks in reverse postorder: one inside a loop with a warm header right after the innermost
        // such loop's last warm block (the loop stays contiguous, and the values live at a block it enters
        // live no further), the others last.
        self.loop_ends();
        self.keys.truncate(0);
        for k in 0..nb {
            if self.rare[k] {
                self.keys.push(self.rpo[k] as u64 << 32 | k as u64);
            }
        }
        self.keys.sort();
        let mut tail = Vector::<u64>::new();
        for j in 0..self.keys.len() {
            let h = self.warm_loop(self.keys[j] as u32);
            if h != NONE {
                tail.push(self.lend[h as usize] as u64 << 32 | j as u64);
            }
        }
        tail.sort();
        let warm = self.order.len();
        let mut out = Vector::<u32>::with_capacity(warm + self.keys.len());
        let mut t: usize = 0;
        for i in 0..warm {
            out.push(self.order[i]);
            while t < tail.len() && (tail[t] >> 32) as usize == i {
                out.push(self.keys[(tail[t] as u32) as usize] as u32);
                t += 1;
            }
        }
        for j in 0..self.keys.len() {
            if self.warm_loop(self.keys[j] as u32) == NONE {
                out.push(self.keys[j] as u32);
            }
        }
        // The blocks the generator puts last (`after`), in order.
        if self.after.len() == nb {
            let mut tail = Vector::<u32>::new();
            let mut j: usize = 0;
            for i in 0..out.len() {
                if self.after[out[i] as usize] {
                    tail.push(out[i]);
                } else {
                    out[j] = out[i];
                    j += 1;
                }
            }
            out.truncate(j);
            out.extend_copy(&tail);
        }
        self.order = out;
        for i in 0..self.order.len() {
            self.pos[self.order[i] as usize] = i as u32;
        }
        fill(&mut self.lend, nb, 0);
        self.loop_ends();
    }

    // `order` with each block outside every loop that returns, laid out after a loop, whose one predecessor
    // is before it and passes a value the block reads into a loop's header (`enters_with`), moved right
    // after that predecessor: the value then lives no further than the loop's entry (`entry_partner`).
    fn early_returns(self: &mut Self, b: &Body) {
        let n = self.order.len();
        let nb = b.blocks.len();
        for i in 0..n {
            self.pos[self.order[i] as usize] = i as u32;
        }
        // Per position, the position of the first outermost loop header at or after it (n when none).
        let mut next = Vector::<u32>::with_capacity(n + 1);
        next.resize_default(n + 1);
        next[n] = n as u32;
        for r in 0..n {
            let i = n - 1 - r;
            let h = self.order[i];
            next[i] = if self.inner[h as usize] == h && self.parent[h as usize] == NONE {
                i as u32
            } else {
                next[i + 1]
            };
        }
        // The blocks that move: the position they go before (their last predecessor's next) << 32 | their own.
        let mut mv = Vector::<u64>::new();
        for j in 0..n {
            let k = self.order[j];
            if self.inner[k as usize] != NONE || term(b, k).op != O_RET || self.pat[k as usize] + 1 != self.pat[k as usize + 1] || !self.enters_with(
                b,
                k,
            ) {
                continue;
            }
            let mut last: u32 = 0;
            for q in self.pat[k as usize]..self.pat[k as usize + 1] {
                let pp = self.pos[self.preds[q as usize] as usize];
                last = if pp == NONE {
                    n as u32
                } else {
                    last.max(pp)
                };
            }
            let h = if last < n as u32 {
                next[last as usize + 1]
            } else {
                n as u32
            };
            if h < j as u32 {
                mv.push(last as u64 + 1 << 32 | j as u64);
            }
        }
        fill(&mut self.pos, nb, NONE);
        if mv.len() == 0 {
            return;
        }
        mv.sort();
        let mut out = Vector::<u32>::with_capacity(n);
        let mut m: usize = 0;
        let mut gone = Vector::<bool>::new();
        gone.resize_default(n);
        for q in 0..mv.len() {
            gone[(mv[q] as u32) as usize] = true;
        }
        for i in 0..n {
            while m < mv.len() && (mv[m] >> 32) as usize == i {
                out.push(self.order[(mv[m] as u32) as usize]);
                m += 1;
            }
            if !gone[i] {
                out.push(self.order[i]);
            }
        }
        self.order = out;
    }

    // Whether the one predecessor of block `k` passes a value that `k` reads into a loop's header, and no
    // constant (which that edge would make, a jump then passing `k`).
    fn enters_with(self: &mut Self, b: &Body, k: u32) bool {
        let p = self.preds[self.pat[k as usize] as usize];
        let mut es = Vector::<u32>::new();
        b.succ_edges(term(b, p), &mut es);
        let bk = b.blocks[k as usize];
        for e in 0..es.len() {
            let h = b.edge_target(es[e]);
            if self.inner[h as usize] != h {
                continue;
            }
            for a in 0..b.edge_nargs(es[e]) {
                let v = self.arg(b, es[e], a);
                if (v & (VPARAM | VFLAG)) == 0 && v != VNONE && (b.insts[v as usize].op == O_ICONST || b.insts[v as usize].op == O_FCONST) {
                    return false;
                }
            }
            for a in 0..b.edge_nargs(es[e]) {
                let v = self.arg(b, es[e], a);
                for i in bk.start..bk.start + bk.len {
                    each_use(b, b.insts[i as usize], &mut self.succ);
                    for u in 0..self.succ.len() {
                        if self.succ[u] == v {
                            return true;
                        }
                    }
                }
            }
        }
        return false;
    }

    // The header of the innermost loop with a warm header around block `k`, NONE when none.
    const fn warm_loop(self: &Self, k: u32) u32 {
        let mut h = self.inner[k as usize];
        // Each step leaves one loop.
        while h != NONE && self.rare[h as usize] {
            h = self.parent[h as usize];
        }
        return h;
    }

    // `lend`: each loop's last block in `order`.
    const fn loop_ends(self: &mut Self) {
        for i in 0..self.order.len() {
            let k = self.order[i];
            let mut h = self.inner[k as usize];
            // At most one step per enclosing loop.
            while h != NONE {
                if self.lend[h as usize] < i as u32 {
                    self.lend[h as usize] = i as u32;
                }
                h = self.parent[h as usize];
            }
        }
    }

    // Per value: its block, live range end and use count.
    fn ranges(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        let nv = ni + b.params.len();
        fill(&mut self.flag_of, ni, NONE);
        // The flags with a use get indexes after the parameters; `work` lists their instructions. Only a
        // checked operation has one (`F_OVF`).
        let mut nf: u32 = 0;
        self.work.truncate(0);
        let mut checked = false;
        for k in 0..ni {
            checked = checked || op_info(b.insts[k].op).form == F_OVF;
        }
        let scan = ast::pick(checked, ni, 0);
        for k in 0..scan {
            let t = b.insts[k];
            each_use(b, t, &mut self.succ);
            for u in 0..self.succ.len() {
                let v = self.succ[u];
                if (v & (VPARAM | VFLAG)) == VFLAG && self.flag_of[(v & ~VFLAG) as usize] == NONE {
                    self.flag_of[(v & ~VFLAG) as usize] = nv as u32 + nf;
                    self.work.push(v & ~VFLAG);
                    nf += 1;
                }
            }
        }
        let n = nv + nf as usize;
        self.def_blocks(b, n);
        fill(&mut self.end, n, 0);
        fill(&mut self.uses, n, 0);
        fill(&mut self.last, n, 0);
        fill(&mut self.sole, n, NONE);
        fill(&mut self.rlast, n, NONE);
        fill(&mut self.ep_read, nv, 0);
        self.ep_gen = 0;
        self.ep_head = NONE;
        self.ep_min_ok = false;
        self.past_ok = false;
        fill(&mut self.wpos, n, NONE);
        fill(&mut self.wn, n, 0);
        for f in 0..nf as usize {
            self.def_blk[nv + f] = self.def_blk[self.work[f] as usize];
        }
        for v in 0..n {
            if self.def_blk[v] != NONE && self.pos[self.def_blk[v] as usize] != NONE {
                self.end[v] = self.pos[self.def_blk[v] as usize];
            }
        }
        // The values a loop keeps (`kept`): the back edge, past their last use, reads them again.
        let mut kept = replace(&mut self.kept, Vector::<bool>::new());
        fill(&mut kept, n, false);
        fill(&mut self.ua, ni, 0);
        fill(&mut self.un, ni, 0);
        self.uv.truncate(0);
        let np = self.order.len();
        fill(&mut self.au, n, 0);
        fill(&mut self.wt, n, 0);
        // Each instruction's uses (`uses_at`), into a scratch taken out for the walk.
        let mut us = replace(&mut self.ru, Vector::<u32>::new());
        for p in 0..np {
            let k = self.order[p];
            let bk = b.blocks[k as usize];
            let f = self.freq[k as usize];
            for i in bk.start..bk.start + bk.len {
                self.wt[i as usize] += f;
                self.uses_at(b, i, &mut us);
                self.ua[i as usize] = self.uv.len() as u32;
                self.un[i as usize] = us.len() as u32;
                self.uv.extend_copy(&us);
                for u in 0..us.len() {
                    let x = self.vix(b, us[u]);
                    self.uses[x as usize] += 1;
                    self.wt[x as usize] += f;
                    self.au[x as usize] += 1;
                    if i > self.last[x as usize] {
                        self.last[x as usize] = i;
                    }
                    self.rlast[x as usize] = p as u32;
                    if x as usize >= ni && x as usize < nv && self.sole[x as usize] != i {
                        self.sole[x as usize] = ast::pick(self.sole[x as usize] == NONE, i, READERS);
                    }
                    let mut e = p as u32;
                    // A use in a loop the definition is outside of keeps the value to the loop's end.
                    let dp = self.pos[self.def_blk[x as usize] as usize];
                    let mut h = self.inner[k as usize];
                    while h != NONE && !(self.pos[h as usize] <= dp && dp <= self.lend[h as usize]) {
                        e = self.lend[h as usize];
                        h = self.parent[h as usize];
                        kept[x as usize] = true;
                    }
                    if e > self.end[x as usize] {
                        self.end[x as usize] = e;
                    }
                }
            }
            // An edge writes its target's parameters: one use of each (`each_edge_param`), and they keep
            // their homes to the last edge into them, which a back edge's source writes after the layout
            // passed their block.
            let t = b.insts[(bk.start + bk.len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                let sb = b.blocks[b.edge_target(self.succ[e]) as usize];
                for q in 0..sb.param_len as u32 {
                    let x = ni + (sb.param_start + q) as usize;
                    self.uses[x] += 1;
                    self.wn[x] += 1;
                    self.wt[x] += f;
                    self.au[x] += 1;
                    if self.wpos[x] == NONE || p as u32 > self.wpos[x] {
                        self.wpos[x] = p as u32;
                    }
                    if p as u32 > self.end[x] {
                        self.end[x] = p as u32;
                    }
                }
            }
        }
        self.ru = us;
        self.rare_entries(b, &mut kept);
        fill(&mut self.next, n, NONE);
        fill(&mut self.use_next, self.uv.len(), NONE);
        let mut ordinal = ni as u32;
        for q in 0..self.order.len() {
            let bk = b.blocks[self.order[self.order.len() - 1 - q] as usize];
            for j in 0..bk.len {
                let i = bk.start + bk.len - 1 - j;
                ordinal -= 1;
                let a = self.ua[i as usize];
                let nu = self.un[i as usize];
                for r in 0..nu {
                    let u = (a + nu - 1 - r) as usize;
                    let x = self.vix(b, self.uv[u]) as usize;
                    self.use_next[u] = self.next[x];
                    self.next[x] = ordinal;
                }
            }
        }
        // One more use, which no instruction makes: a kept value lives to the end of its last block.
        for x in 0..n {
            if kept[x] {
                self.uses[x] += 1;
            }
        }
        self.kept = kept;
    }

    // `freq`: per block, how often it runs for one entry into the body (FREQ_ENTRY), a static estimate after
    // LLVM's block frequencies: in reverse postorder, each block passes what it runs on to its successors by
    // forward edges, split by weight (a rare successor 1, any other FREQ_SPLIT); a loop header runs
    // FREQ_LOOP times what its entering edges bring, and an edge that leaves loops brings that much less per
    // loop it leaves, at least 1. A cold block runs never. Back edges bring nothing: the header's factor
    // counts them.
    fn frequencies(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        self.freq.truncate(0);
        self.freq.resize_default(nb);
        fill(&mut self.fmass, nb, 0);
        fill(&mut self.fby, nb, NONE);
        for k in 0..nb {
            if self.rpo[k] != NONE {
                self.fby[self.rpo[k] as usize] = k as u32;
            }
        }
        if nb == 0 {
            return;
        }
        self.fmass[0] = FREQ_ENTRY;
        for r in 0..nb {
            let k = self.fby[r];
            if k == NONE {
                break;
            }
            let bk = b.blocks[k as usize];
            let mut m = self.fmass[k as usize];
            if self.inner[k as usize] == k {
                m = (m * FREQ_LOOP).min(FREQ_MAX);
            }
            if (bk.flags & BLOCK_COLD) != 0 {
                continue;
            }
            self.freq[k as usize] = m;
            b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut self.fedges);
            let mut total: u64 = 0;
            for e in 0..self.fedges.len() {
                let t = b.edge_target(self.fedges[e]);
                total += ast::pick(self.rare[t as usize], 1u64, FREQ_SPLIT);
            }
            for e in 0..self.fedges.len() {
                let t = b.edge_target(self.fedges[e]);
                if self.rpo[t as usize] == NONE || self.rpo[t as usize] <= r as u32 {
                    continue;
                }
                let mut share = m * ast::pick(self.rare[t as usize], 1u64, FREQ_SPLIT) / total;
                // Each loop the edge leaves: at most the nesting depth.
                let mut h = self.inner[k as usize];
                while h != NONE && !self.in_loop(h, t) {
                    share /= FREQ_LOOP;
                    h = self.parent[h as usize];
                }
                // A block that runs passes on at least 1: a share rounded to 0 would make every block
                // after it one that never runs, the loops among them too.
                self.fmass[t as usize] += share.max((m != 0) as u64);
            }
        }
    }

    // Whether block `t` is in the loop headed by `h`: `h` is its innermost loop's header or an enclosing one.
    pub(package) const fn in_loop(self: &Self, h: u32, t: u32) bool {
        let mut l = self.inner[t as usize];
        // Each step leaves one loop: at most the nesting depth.
        while l != NONE {
            if l == h {
                return true;
            }
            l = self.parent[l as usize];
        }
        return false;
    }

    /// The instruction of `b` where value `x`'s range ends in its last block (`end`): its last use, when it
    /// is in that block, a value it is, no loop keeps it past that use (`kept`) and, for a block parameter,
    /// no edge of that block or a later one writes it. NONE else (the range ends with the block).
    pub(package) const fn last_read(self: &Self, b: &Body, x: u32) u32 {
        let ni = b.insts.len() as u32;
        let e = self.end[x as usize];
        let l = self.last[x as usize];
        let read = if x < ni {
            self.uses[x as usize] != 0
        } else {
            x < ni + b.params.len() as u32 && self.uses[x as usize] > self.wn[x as usize] && (self.wpos[x as usize] == NONE || self.wpos[x as usize] < e)
        };
        return ast::pick(read && !self.kept[x as usize] && self.pos[self.def_blk[l as usize] as usize] == e, l, NONE);
    }
}

extend Live {
    /// Per instruction of `b` into `out`: whether it is a float or integer constant a loop block uses that
    /// lives past its block. No instruction takes a float as an immediate, and a wide integer takes several
    /// to build, so recomputing one at each use costs instructions every iteration: a generator asks a
    /// register for its whole range instead (an integer one when building it takes more than one
    /// instruction), and a symbol's address (arm64 builds one with ADRP and ADD; x86-64 one LEA at each
    /// indexed access, which takes no RIP-relative base). After `run`.
    pub(package) fn loop_consts(self: &mut Self, b: &Body, out: &mut Vector<bool>) {
        out.truncate(0);
        out.resize_default(b.insts.len());
        for k in 0..b.blocks.len() {
            if self.inner[k] == NONE || self.pos[k] == NONE {
                continue;
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let a = self.ua[i as usize];
                for u in a..a + self.un[i as usize] {
                    let v = self.uv[u as usize];
                    let op = if (v & (VPARAM | VFLAG)) == 0 {
                        b.insts[v as usize].op
                    } else {
                        O_RET
                    };
                    if op == O_FCONST || op == O_ICONST || op == O_SYMADDR {
                        let d = self.def_blk[v as usize];
                        out[v as usize] = out[v as usize] || self.end[v as usize] > self.pos[d as usize];
                    }
                }
            }
        }
    }

    /// Whether every block segment `s` holds its value through is one of `after`.
    pub(package) const fn seg_framed(self: &Self, s: u32) bool {
        for q in self.seg_a[s as usize]..self.seg_b[s as usize] + 1 {
            if self.holds_at(s, q) && !self.after[self.order[q as usize] as usize] {
                return false;
            }
        }
        return true;
    }

    /// Whether value `x` has a register segment (`segments`).
    pub(package) const fn seg_val(self: &Self, x: u32) bool {
        return x as usize < self.segd.len() && self.segd[x as usize];
    }

    /// The segment that holds value `x` in its register through the block at layout position `q`, NONE
    /// for none: at most one entry per register (`sin`).
    pub(package) const fn seg_of(self: &Self, x: u32, q: u32) u32 {
        if q as usize + 1 >= self.sin_at.len() {
            return NONE;
        }
        for j in self.sin_at[q as usize]..self.sin_at[q as usize + 1] {
            let s = self.sin[j as usize];
            if self.seg_x[s as usize] == x {
                return s;
            }
        }
        return NONE;
    }

    /// Whether `plan` gave no register to a used value that `want` asked one for, in a block the layout
    /// does not put last (`after`).
    pub(package) const fn homeless(self: &Self, want: &Vector<u8>) bool {
        for x in 0..self.end.len() {
            let d = self.def_blk[x];
            // A register in every block the value is live in is a home (`assign`).
            let held = x < self.segd.len() && self.segd[x] && !self.seg_mem[x];
            if (want[x] & (WANT_CALLEE | WANT_SCRATCH)) != 0 && !held && self.au[x] != 0 && d != NONE && self.pos[d as usize] != NONE && !self.after[d as usize] {
                return true;
            }
        }
        return false;
    }

    // `FOLD_ADC`: each sum or difference with a carry or borrow (`carry_of`), its parts marked (`carry`).
    fn carries(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        // A carry comes from a checked sum or difference (`by_op`).
        let ao = O_ADDO as usize;
        let so = O_SUBO as usize;
        if self.op_at[ao + 1] == self.op_at[ao] && self.op_at[so + 1] == self.op_at[so] {
            return;
        }
        // The uses of each instruction's flag.
        fill(&mut self.cnd, ni, 0);
        for i in 0..ni {
            each_use(b, b.insts[i], &mut self.succ);
            for u in 0..self.succ.len() {
                let v = self.succ[u];
                if (v & (VPARAM | VFLAG)) == VFLAG {
                    self.cnd[(v & ~VFLAG) as usize] += 1;
                }
            }
        }
        // `wrapping`'s operations.
        self.scan_ops([O_ADD, O_ADDO, O_SUB, O_SUBO]);
        for q in 0..self.scan.len() {
            let i = self.scan[q];
            let t = b.insts[i as usize];
            let sub = t.op == O_SUB || t.op == O_SUBO;
            if !self.wrapping(b, i, sub) {
                continue;
            }
            for side in 0..2u32 {
                // A difference's borrow is its second operand.
                if sub && side == 0 {
                    continue;
                }
                let (z, h) = if side == 0 {
                    (t.a, t.b)
                } else {
                    (t.b, t.a)
                };
                if !is_inst(z) || !is_inst(h) || self.count[z as usize] != 1 || self.count[h as usize] != 1 || self.pfold[z as usize] || self.pfold[h as usize] || !self.wrapping(
                    b,
                    h,
                    sub,
                ) {
                    continue;
                }
                let zt = b.insts[z as usize];
                if zt.op != O_ZEXT || zt.ty != t.ty || (zt.a & (VPARAM | VFLAG)) != VFLAG {
                    continue;
                }
                let lo = zt.a & ~VFLAG;
                let lt = b.insts[lo as usize];
                let ht = b.insts[h as usize];
                if lt.op != ast::pick(sub, O_SUBO, O_ADDO) || lt.aux == OV_SIGNED || lt.ty != t.ty || self.cnd[lo as usize] != 1 || self.pfold[lo as usize] || is_inst(
                    ht.a,
                ) && self.pfold[ht.a as usize] || is_inst(ht.b) && self.pfold[ht.b as usize] {
                    continue;
                }
                // Only `h` and the extension between the `addo` and the sum: no code between sets the flags.
                let mut ok = lo < z && lo < h && z < i && h < i;
                for j in lo + 1..i {
                    ok = ok && (j == z || j == h);
                }
                if ok {
                    self.pfold[z as usize] = true;
                    self.pfold[h as usize] = true;
                    self.carry[lo as usize] = CARRY_LO;
                    self.carry[z as usize] = CARRY_PART;
                    self.carry[h as usize] = CARRY_PART;
                    self.carry[i as usize] = CARRY_ADC;
                    if (self.fold_ops & FOLD_LDOP) != 0 {
                        self.carry_load(b, lo, lo);
                        self.carry_load(b, h, i);
                    }
                    break;
                }
            }
        }
    }

    // `FOLD_LDOP` for the `add` and `adc` of a sum with a carry (`carries`): an operand of sum or difference
    // `s` (a difference's second) that a load alone gives, of its width, with no write of memory from the load
    // to `at`, where the operation reads it, folds into it.
    const fn carry_load(self: &mut Self, b: &Body, s: u32, at: u32) {
        let t = b.insts[s as usize];
        let sub = t.op == O_SUB || t.op == O_SUBO;
        for side in 0..2u32 {
            let o = ast::pick(side == 0, t.b, t.a);
            if side == 1 && sub || !is_inst(o) || o > s || self.count[o as usize] != 1 || self.pfold[o as usize] {
                continue;
            }
            let l = b.insts[o as usize];
            if l.op != O_LOAD || l.ty != t.ty || (l.aux & MEM_VOLATILE) != 0 || self.reg_param(b, l.a) || result_load(
                b,
                o,
                self.ret_regs,
            ) {
                continue;
            }
            let mut clear = true;
            for j in o + 1..at {
                clear = clear && !writes_mem(b.insts[j as usize]);
            }
            if clear {
                self.pfold[o as usize] = true;
                return;
            }
        }
    }

    // Whether value `v` of `b` is an aggregate parameter that does not arrive in memory (`mem_params`), or
    // the pointer to an aggregate result: its loads may be no memory reads.
    const fn reg_param(self: &Self, b: &Body, v: Value) bool {
        if !agg_param(b, v) {
            return false;
        }
        let q = (v & ~VPARAM) - b.blocks[0].param_start;
        return q >= 64 || (self.mem_params >> q as u64 & 1) == 0;
    }

    // Whether instruction `i` of `b` is a sum (`sub`: difference) of two integers of 32 or 64 bits that
    // wraps: `add`, or `addo` whose flag nothing reads (`cnd`).
    const fn wrapping(self: &Self, b: &Body, i: u32, sub: bool) bool {
        let t = b.insts[i as usize];
        let bits = type_bits(t.ty, 8);
        let (plain, ovf) = if sub {
            (O_SUB, O_SUBO)
        } else {
            (O_ADD, O_ADDO)
        };
        return (t.op == plain || t.op == ovf && self.cnd[i as usize] == 0) && is_int(t.ty) && (bits == 32 || bits == 64);
    }

    // The header parameter of a loop that parameter value `x` of `b`, of a block laid out after the loop,
    // continues: every edge into `x`'s block comes from a block laid out before it, and leaves the loop
    // passing that parameter or the value its back edge passes it, or comes from a block laid out before
    // the loop; the parameter is dead past the loop and of `x`'s type. Its register may then hold `x` too:
    // on the loop's exits it holds the value already, and an edge that skips the loop finds it unused.
    // NONE else.
    const fn exit_partner(self: &Self, b: &Body, x: u32) u32 {
        let ni = b.insts.len() as u32;
        if x < ni || x >= ni + b.params.len() as u32 {
            return NONE;
        }
        let k = self.def_blk[x as usize];
        if k == 0 || k == NONE || self.pos[k as usize] == NONE {
            return NONE;
        }
        let q = x - ni - b.blocks[k as usize].param_start;
        let mut px = NONE;
        let mut h = NONE;
        // Each predecessor's terminator and its edges into the block: a bounded walk of the edge lists.
        for j in self.pat[k as usize]..self.pat[k as usize + 1] {
            let pb = self.preds[j as usize];
            // An edge from a later block would write the register after the range ends.
            if self.pos[pb as usize] != NONE && self.pos[pb as usize] >= self.pos[k as usize] {
                return NONE;
            }
            let hh = self.left(b, pb);
            if self.pos[pb as usize] == NONE || hh == NONE || self.pos[k as usize] <= self.lend[hh as usize] {
                continue;
            }
            let t = term(b, pb);
            let ne = jb_edges(t);
            for e in 0..ne {
                let ed = edge_of(b, t, e);
                if b.edge_target(ed) != k {
                    continue;
                }
                let p = self.exit_value(b, hh, t, ed, q);
                if p == NONE || px != NONE && p != px {
                    return NONE;
                }
                px = p;
                h = hh;
            }
        }
        if px == NONE || b.params[(px - ni) as usize] != b.params[(x - ni) as usize] || self.end[px as usize] > self.lend[h as usize] {
            return NONE;
        }
        // The other edges come from before the loop, or from inside it with the same value.
        for j in self.pat[k as usize]..self.pat[k as usize + 1] {
            let pb = self.preds[j as usize];
            let pp = self.pos[pb as usize];
            if pp == NONE {
                continue;
            }
            let inside = pp >= self.pos[h as usize] && pp <= self.lend[h as usize] || self.left(b, pb) == h;
            if !inside && pp >= self.pos[h as usize] {
                return NONE;
            }
            if inside {
                let t = term(b, pb);
                if t.op != O_JMP && t.op != O_BR {
                    return NONE;
                }
                let ne = edge_count(t);
                for e in 0..ne {
                    let ed = edge_of(b, t, e);
                    if b.edge_target(ed) == k && self.exit_value(b, h, t, ed, q) != px {
                        return NONE;
                    }
                }
            }
        }
        return px;
    }

    // The value index the one edge into loop header parameter `x` from outside its loop passes (once), of
    // `x`'s type, when no block the header reaches reads that value or passes it (it is dead at the header)
    // and the layout puts its uses before the loop (`early_returns`): its register may then hold `x` too,
    // as on the loop's path the value is dead and on the others the loop does not run. NONE else.
    pub(package) fn entry_partner(self: &mut Self, b: &Body, x: u32) u32 {
        let ni = b.insts.len() as u32;
        if x < ni || x >= ni + b.params.len() as u32 {
            return NONE;
        }
        let k = self.def_blk[x as usize];
        if k == NONE || self.inner[k as usize] != k || self.pos[k as usize] == NONE {
            return NONE;
        }
        let q = x - ni - b.blocks[k as usize].param_start;
        let mut y = VNONE;
        for j in self.pat[k as usize]..self.pat[k as usize + 1] {
            let pb = self.preds[j as usize];
            let mut h = self.inner[pb as usize];
            // Each step leaves one loop.
            while h != NONE && h != k {
                h = self.parent[h as usize];
            }
            if h == k {
                continue;
            }
            let t = term(b, pb);
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                let ed = self.succ[e];
                if b.edge_target(ed) != k {
                    continue;
                }
                let v = self.arg(b, ed, q);
                let mut n: u32 = 0;
                for a in 0..b.edge_nargs(ed) {
                    n += (self.arg(b, ed, a) == v) as u32;
                }
                if y != VNONE || n != 1 || (v & VFLAG) != 0 || v == VNONE {
                    return NONE;
                }
                y = v;
            }
        }
        if y == VNONE {
            return NONE;
        }
        let ty = if (y & VPARAM) != 0 {
            b.params[(y & ~VPARAM) as usize]
        } else {
            b.insts[y as usize].ty
        };
        // Its uses are laid out before the loop (a later one would find the register given to another value
        // when the loop's last value that holds it ends).
        if ty != b.params[(x - ni) as usize] || self.end[self.vix(b, y) as usize] >= self.pos[k as usize] {
            return NONE;
        }
        // No block the header reaches reads `y` or passes it: none when every block it reaches lies past
        // `y`'s last use (`ep_min`), else `reads_from`, once per header.
        let yx = self.vix(b, y);
        if !self.ep_min_ok {
            self.reach_min(b);
        }
        if self.ep_min[k as usize] > self.end[yx as usize] {
            return yx;
        }
        if self.ep_head != k {
            self.reads_from(b, k);
        }
        return ast::pick(self.ep_read[yx as usize] == self.ep_gen, NONE, yx);
    }

    /// Whether value index `x` of `b`, in a register by its range at instruction `i` of a rare block or of
    /// a block laid out last (`after`), is
    /// dead past `i`: no instruction after `i` in its block reads it (`uses_at`: an edge's arguments too),
    /// and it is not live into a block the block's edges enter. A range runs to the last block in the
    /// layout that reads the value, through the rare blocks before it that no path joins to a read. Only
    /// of an instruction with a caller-saved home or a segment: a parameter's register may hold the value
    /// an edge passes it (a loop's step), which no read of the parameter shows.
    pub(package) fn dead_past(self: &mut Self, b: &Body, x: u32, i: u32) bool {
        if x as usize >= b.insts.len() {
            return false;
        }
        if !self.past_ok {
            self.pasts(b);
        }
        let id = self.past_id[x as usize];
        if id == NONE {
            return false;
        }
        let bk = b.blocks[self.def_blk[i as usize] as usize];
        for j in i + 1..bk.start + bk.len {
            let a = self.ua[j as usize];
            for u in a..a + self.un[j as usize] {
                if self.uv[u as usize] == x {
                    return false;
                }
            }
        }
        let t = b.insts[(bk.start + bk.len - 1) as usize];
        let w = self.past_w as usize;
        for q in 0..edge_count(t) {
            let p = self.pos[b.edge_target(edge_of(b, t, q)) as usize];
            if p != NONE && (self.past_in[p as usize * w + (id / 64) as usize] >> id % 64 & 1) != 0 {
                return false;
            }
        }
        return true;
    }

    // `past_id`, `past_in` and `past_def` for `b`, after `plan`: the liveness of the instructions a call
    // of a rare block, or of a block laid out last (`after`), may find in a caller-saved register, a
    // backward fixpoint over the laid-out blocks. A block reads a value from before it when an instruction
    // of it uses the value another block defines.
    fn pasts(self: &mut Self, b: &Body) {
        self.past_ok = true;
        let ni = b.insts.len();
        let np = self.order.len();
        fill(&mut self.past_id, ni, NONE);
        // The rare blocks, and the ones laid out last, before each layout position.
        self.work.truncate(0);
        self.work.push(0);
        let aft = self.after.len() != 0;
        for p in 0..np {
            let k = self.order[p] as usize;
            self.work.push(self.work[p] + (self.rare[k] || aft && self.after[k]) as u32);
        }
        let mut n: u32 = 0;
        for x in 0..ni {
            let d = self.def_blk[x];
            if d == NONE || self.pos[d as usize] == NONE {
                continue;
            }
            if self.seg_val(x as u32) && self.work[self.end[x] as usize + 1] != self.work[self.pos[d as usize] as usize] {
                self.past_id[x] = n;
                n += 1;
            }
        }
        let w = (n as usize + 63) / 64;
        self.past_w = w as u32;
        fill(&mut self.past_in, np * w, 0);
        fill(&mut self.past_def, np * w, 0);
        if n == 0 {
            return;
        }
        for p in 0..np {
            let k = self.order[p];
            let bk = b.blocks[k as usize];
            for i in bk.start..bk.start + bk.len {
                let id = self.past_id[i as usize];
                if id != NONE {
                    self.past_def[p * w + (id / 64) as usize] |= 1u64 << id % 64;
                }
                let a = self.ua[i as usize];
                for u in a..a + self.un[i as usize] {
                    let v = self.uv[u as usize];
                    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
                        continue;
                    }
                    let iu = self.past_id[v as usize];
                    if iu != NONE && self.def_blk[v as usize] != k {
                        self.past_in[p * w + (iu / 64) as usize] |= 1u64 << iu % 64;
                    }
                }
            }
        }
        // Each round but the last moves a bit to a block before in the layout or along an edge back: at
        // most a round per block, and one that changes nothing.
        let mut changed = true;
        for _ in 0..np + 1 {
            if !changed {
                break;
            }
            changed = false;
            for q in 0..np {
                let p = np - 1 - q;
                let bk = b.blocks[self.order[p] as usize];
                let t = b.insts[(bk.start + bk.len - 1) as usize];
                for e in 0..edge_count(t) {
                    let sp = self.pos[b.edge_target(edge_of(b, t, e)) as usize];
                    if sp == NONE {
                        continue;
                    }
                    for j in 0..w {
                        let add = self.past_in[sp as usize * w + j] & ~self.past_def[p * w + j] & ~self.past_in[p * w + j];
                        if add != 0 {
                            self.past_in[p * w + j] |= add;
                            changed = true;
                        }
                    }
                }
            }
        }
        assert(!changed, "live: the rare calls' live values do not settle");
    }

    // `ep_min` for `b`: from each laid-out block in layout order, the blocks that reach it and no earlier
    // one take its position, through the predecessors. Each block enters the walk once.
    fn reach_min(self: &mut Self, b: &Body) {
        self.ep_min_ok = true;
        fill(&mut self.ep_min, b.blocks.len(), NONE);
        for p in 0..self.order.len() {
            let d = self.order[p];
            if self.ep_min[d as usize] != NONE {
                continue;
            }
            self.ep_min[d as usize] = p as u32;
            self.stack.truncate(0);
            self.stack.push(d);
            while self.stack.len() != 0 {
                let c = self.stack.pop().unwrap();
                for j in self.pat[c as usize]..self.pat[c as usize + 1] {
                    let a = self.preds[j as usize];
                    if self.ep_min[a as usize] == NONE {
                        self.ep_min[a as usize] = p as u32;
                        self.stack.push(a);
                    }
                }
            }
        }
    }

    // `ep_read`: the values the blocks loop header `k` of `b` reaches read or pass (`uses_at`: edge
    // arguments too), marked with a new generation. Each block enters the walk once.
    fn reads_from(self: &mut Self, b: &Body, k: u32) {
        self.ep_gen += 1;
        self.ep_head = k;
        fill(&mut self.ep_seen, b.blocks.len(), false);
        self.ep_seen[k as usize] = true;
        self.stack.truncate(0);
        self.stack.push(k);
        while self.stack.len() != 0 {
            let c = self.stack.pop().unwrap();
            let bk = b.blocks[c as usize];
            for i in bk.start..bk.start + bk.len {
                let a = self.ua[i as usize];
                for u in a..a + self.un[i as usize] {
                    let v = self.uv[u as usize];
                    if v != VNONE && (v & VFLAG) == 0 {
                        let x = self.vix(b, v);
                        self.ep_read[x as usize] = self.ep_gen;
                    }
                }
            }
            b.succ_edges(term(b, c), &mut self.succ);
            for e in 0..self.succ.len() {
                let s = b.edge_target(self.succ[e]);
                if !self.ep_seen[s as usize] {
                    self.ep_seen[s as usize] = true;
                    self.stack.push(s);
                }
            }
        }
    }

    // The loop block `k` of `b` leaves: its innermost one, or for a lone jump whose one predecessor is in a
    // loop the block is outside of (a split exit edge), that loop. NONE else.
    const fn left(self: &Self, b: &Body, k: u32) u32 {
        let h = self.inner[k as usize];
        if h != NONE {
            return h;
        }
        if b.blocks[k as usize].len != 1 || term(b, k).op != O_JMP || self.pat[k as usize + 1] - self.pat[k as usize] != 1 {
            return NONE;
        }
        let p = self.preds[self.pat[k as usize] as usize];
        let hp = self.inner[p as usize];
        return ast::pick(
            hp == NONE || self.pos[k as usize] == NONE || self.pos[k as usize] >= self.pos[hp as usize] && self.pos[k as usize] <= self.lend[hp as usize],
            NONE,
            hp,
        );
    }

    // The parameter value of loop header `h` that argument `q` of edge `ed` of terminator `t` continues: the
    // one the other edge of `t`, a back edge to `h`, passes it to (that edge's moves before the branch then
    // serve `ed` too), else `header_of_value`.
    const fn exit_value(self: &Self, b: &Body, h: u32, t: Inst, ed: u32, q: u32) u32 {
        let v = self.arg(b, ed, q);
        if t.op == O_BR {
            let o = ast::pick(ed == t.b, t.c, t.b);
            if b.edge_target(o) == h {
                let hb = b.blocks[h as usize];
                for j in 0..hb.param_len as u32 {
                    if self.arg(b, o, j) == v {
                        return b.insts.len() as u32 + hb.param_start + j;
                    }
                }
            }
        }
        return self.header_of_value(b, h, v);
    }

    // The parameter value of loop header `h` that `v` of `b` is: the parameter itself, or the value a back
    // edge of the loop passes it. NONE else.
    const fn header_of_value(self: &Self, b: &Body, h: u32, v: Value) u32 {
        let ni = b.insts.len() as u32;
        let hb = b.blocks[h as usize];
        if v != VNONE && (v & VFLAG) == 0 && (v & VPARAM) != 0 {
            let p = v & ~VPARAM;
            return if p >= hb.param_start && p < hb.param_start + hb.param_len as u32 {
                ni + p
            } else {
                NONE
            };
        }
        for j in self.pat[h as usize]..self.pat[h as usize + 1] {
            let pb = self.preds[j as usize];
            let pp = self.pos[pb as usize];
            if pp == NONE || pp < self.pos[h as usize] || pp > self.lend[h as usize] {
                continue;
            }
            let t = term(b, pb);
            let ne = jb_edges(t);
            for e in 0..ne {
                let ed = edge_of(b, t, e);
                if b.edge_target(ed) != h {
                    continue;
                }
                for q in 0..hb.param_len as u32 {
                    if self.arg(b, ed, q) == v {
                        return ni + hb.param_start + q;
                    }
                }
            }
        }
        return NONE;
    }

    // A block that branches to a block the layout puts before it (a rare block, laid out last, that goes
    // back into the body; a block left for after the return's) runs inside the ranges of the values live
    // at its target: each value whose range holds the position of such a target, past the block it is
    // defined in (an instruction is not live at its own block's entry, a parameter is), lives to that
    // block too, and is kept (its last use does not end it), also when its own use there already ends
    // its range at that block (a loop counter a rare call reads). A range max over the targets' positions
    // (a sparse table of `best`: per position, the last block with an edge back into it) finds the
    // extension of each value.
    fn rare_entries(self: &mut Self, b: &Body, kept: &mut Vector<bool>) {
        let np = self.order.len();
        let mut best = Vector::<u32>::new();
        fill(&mut best, np, 0);
        let mut any = false;
        for p in 0..np {
            let bk = b.blocks[self.order[p] as usize];
            b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut self.succ);
            for e in 0..self.succ.len() {
                let q = self.pos[b.edge_target(self.succ[e]) as usize] as usize;
                if q < p && best[q] < p as u32 {
                    best[q] = p as u32;
                    any = true;
                }
            }
        }
        if !any {
            return;
        }
        // Level j holds the maxima of the 2^j positions from each position.
        let mut levels: usize = 1;
        while 1usize << levels <= np {
            levels += 1;
        }
        let mut sp = Vector::<u32>::with_capacity(levels * np);
        sp.extend_copy(&best);
        for j in 1..levels {
            let h = 1usize << j - 1;
            for i in 0..np {
                let a = sp[(j - 1) * np + i];
                let c = if i + h < np {
                    sp[(j - 1) * np + i + h]
                } else {
                    0u32
                };
                sp.push(ast::pick(a > c, a, c));
            }
        }
        let ni = b.insts.len();
        for x in 0..self.end.len() {
            let d = self.def_blk[x];
            if d == NONE || self.pos[d as usize] == NONE {
                continue;
            }
            let lo = self.pos[d as usize] as usize + (x < ni) as usize;
            // Each step moves the end to a later block: at most one step per block.
            loop {
                let hi = self.end[x] as usize;
                if lo > hi {
                    break;
                }
                let mut j: usize = 0;
                while 2usize << j <= hi - lo + 1 {
                    j += 1;
                }
                let a = sp[j * np + lo];
                let c = sp[j * np + hi + 1 - (1usize << j)];
                let e = ast::pick(a > c, a, c);
                // 0: no edge back into these positions (no edge goes back from the entry, at 0).
                if e < self.end[x] || e == 0 {
                    break;
                }
                kept[x] = true;
                if e == self.end[x] {
                    break;
                }
                self.end[x] = e;
            }
        }
    }
}

// The most a candidate's weight counts in `Live::assign`'s order.
const SEG_WT: u64 = (1u64 << 40) - 1;
// What a load on one of a terminator's several edges weighs against a load in a block (`Live::spans`): the
// edge takes a block of its own, with a jump, that the layout puts out of line. Measured on the compiler's
// build of itself: 2, 3, 5 and 8 each ran fewer instructions in less code than the one before, 5 and 8
// the same count.
const EDGE_BLOCK: u64 = 8;
// What a callee-saved register the body does not save yet costs the value that takes it (`Live::assign`,
// `Live::spans`): two entries, its save and its restore. Measured: at one entry, and at a sixteenth, the
// compiler's build of itself runs 1% fewer cycles, and a wait group's fan-in 2 to 12% more: a body that
// takes the register for a path it seldom runs saves it at every entry (the scheduler's search for work
// saves 6 registers in place of 2).
const SAVE_COST: u64 = 2 * FREQ_ENTRY;
// The most segments of one register `Live::evict` searches for a holder.
const EVICT_SCAN: u32 = 64;
// The most segments one value has (`Live::frame_put`): a register outside the blocks that set the frame
// up, another in them.
const SEG_PARTS: u32 = 2;

extend Live {
    // How often the edges from block `p` into block `k` run: `p`'s frequency by their weight among its
    // edges (`frequencies`).
    fn edge_freq(self: &mut Self, b: &Body, p: u32, k: u32) u64 {
        b.succ_edges(term(b, p), &mut self.fedges);
        let mut total: u64 = 0;
        let mut mine: u64 = 0;
        for e in 0..self.fedges.len() {
            let t = b.edge_target(self.fedges[e]);
            let w = ast::pick(self.rare[t as usize], 1u64, FREQ_SPLIT);
            total += w;
            if t == k {
                mine += w;
            }
        }
        return self.freq[p as usize] * mine / total.max(1);
    }
}

/// The registers `Live::assign` gives out, by class (bit `r`: register `r`, the generator's number): the
/// general callee-saved ones, the caller-saved ones, the argument ones (a value holds one only where
/// nothing writes an argument register: `wfirst`, `wlast`), the vector file's callee-saved and
/// caller-saved ones, and the argument registers of both files outside those classes (`xa`), one of which
/// only the parameter that arrives in it keeps, when the generator finds nothing writes it in the
/// parameter's range; and the vector file's upper registers (`vu`: x86-64's xmm16..xmm31), for the values
/// that ask for one (`WANT_UPPER`). `first`: the registers of those classes the plan gives out before
/// the others of their class (the ones no temporary takes). `pair`: the lower register of each two
/// callee-saved registers the generator saves together (a body that holds a value in one saves both).
pub(package) struct Sets {
    pub(package) xc: u64,
    pub(package) xs: u64,
    pub(package) xw: u64,
    pub(package) vc: u64,
    pub(package) vs: u64,
    pub(package) xa: u64,
    pub(package) vu: u64,
    pub(package) first: u64,
    pub(package) pair: u64,
}

extend Sets as Copy {}

extend Sets {
    // The callee-saved registers a body saves once a value holds `r`: `r`, and the other register of its
    // pair (`pair`).
    const fn saved(self: &Self, r: u8) u64 {
        let bit = 1u64 << r as u64;
        let lo = (bit | bit >> 1) & self.pair;
        return (bit | lo | lo << 1) & (self.xc | self.vc);
    }
}

/// `Live::seg_r`: no register.
pub(package) const REG_NONE: u8 = 0xFF;

extend Live {
    /// Plan the registers: each value `want` asks one for (heaviest first, `frequencies`) takes one
    /// register of `sets` in the blocks where it is live (a backward walk from its reads: `spread`), from
    /// its definition to its last read in each (`ends`). Two values hold one register when they are live
    /// at no common position, so a value takes the register of the value it replaces: a block parameter
    /// that of the argument an edge passes it, a step that of its first operand (`over`), which each
    /// prefers (`hints`), and no move is made. A register is a value's own in the block (`bmask`): no
    /// temporary takes it there. A class holds a value only where nothing writes its registers while the
    /// value lives (`calm`) and the block has room (`addable`: `caps`, `scap`, `jcap`). A value no
    /// register holds everywhere takes the register that gains most over the blocks where it is free
    /// (`spans`): it keeps a stack home, and an edge into such a block from one that does not hold it
    /// loads it; or a caller-saved register over all of its blocks, which each call it lives across saves
    /// around itself, when that costs less than no register (`past_put`). In a body that sets its frame
    /// up in the blocks of `after` alone, a callee-saved register holds a value only in those blocks, and
    /// a value made in another block keeps a register everywhere: one in those blocks, another in the
    /// others, with a move on each edge between the two (`frame_put`). `arr`: per parameter of the
    /// signature (and the result pointer after them), the registers it arrives in, which no other value
    /// takes while it is there; `quiet`: bit `k` when nothing writes the one register parameter `k`
    /// arrives in before its range ends, so it may stay there (`Sets.xa`). The plan is the segments
    /// (`seg_*`, `sin`), one per value (two for one `frame_put` split), with their registers (`seg_r`).
    /// After `run`, before the generator counts the uses down.
    pub(package) fn assign(
        self: &mut Self,
        b: &Body,
        want: &Vector<u8>,
        caps: Caps,
        sets: Sets,
        arr: &Vector<u64>,
        quiet: u64,
    ) {
        self.past_ok = false;
        let n = self.end.len();
        let ni = b.insts.len();
        let nv = ni + b.params.len();
        let np = self.order.len();
        self.seg_x.truncate(0);
        self.seg_a.truncate(0);
        self.seg_b.truncate(0);
        self.seg_r.truncate(0);
        self.seg_at.truncate(0);
        self.gpool.truncate(0);
        self.sin.truncate(0);
        self.sin_at.truncate(0);
        self.segd.truncate(0);
        self.seg_mem.truncate(0);
        self.seg_past.truncate(0);
        fill(&mut self.bmask, np, 0);
        fill(&mut self.solo, np, 0);
        fill(&mut self.base, np + 1, 0);
        for p in 0..np {
            self.base[p + 1] = self.base[p] + b.blocks[self.order[p] as usize].len;
        }
        if np == 0 || n >= 1usize << 24 {
            return;
        }
        fill(&mut self.scand, n, false);
        self.cand.truncate(0);
        // A step that replaces a block parameter (an instruction of a block whose edge passes it to the
        // parameter of that block or of an earlier one, nothing in its block reading the parameter after it)
        // shares the parameter's register. The parameter is ordered no later than the step: the register
        // it takes over all of its range is one the step, which lives to the edge alone, may hold; a step
        // placed first takes one that another value may hold in the parameter's blocks. When a call runs
        // between the parameter's block and the step (in a block laid out from the one to the other, or
        // before the step in its own), the parameter lives across it and the step does not: only a step
        // that may write over the parameter, in the block where the parameter's range ends. Each edge's
        // arguments once.
        self.kw.truncate(0);
        self.kw.extend_copy(&self.wt);
        // `kc`: the blocks with a call before each layout position.
        let calls = self.cfirst.len() == np;
        fill(&mut self.kc, np + 1, 0);
        for p in 0..np {
            self.kc[p + 1] = self.kc[p] + (calls && self.cfirst[p] != NONE) as u32;
        }
        for p in 0..np {
            let k = self.order[p];
            let t = term(b, k);
            for e in 0..edge_count(t) {
                let ed = edge_of(b, t, e);
                let pt = self.pos[b.edge_target(ed) as usize];
                if pt == NONE || pt as usize > p {
                    continue;
                }
                let ps = b.blocks[b.edge_target(ed) as usize].param_start as usize;
                for j in 0..b.edge_nargs(ed) as usize {
                    let a = self.arg(b, ed, j as u32);
                    let y = ni + ps + j;
                    if a == VNONE || (a & (VPARAM | VFLAG)) != 0 || self.def_blk[a as usize] != k || self.kw[y] >= self.wt[a as usize] {
                        continue;
                    }
                    let near = self.kc[p] == self.kc[pt as usize] && (!calls || self.cfirst[p] == NONE || a < self.cfirst[p]);
                    if !near && (self.end[y] != p as u32 || !self.over(b, y as u32, a)) {
                        continue;
                    }
                    if !self.reads_after(b, k, a, VPARAM | (y - ni) as u32) {
                        self.kw[y] = self.wt[a as usize];
                    }
                }
            }
        }
        for x in 0..n {
            let d = self.def_blk[x];
            if (want[x] & (WANT_CALLEE | WANT_SCRATCH)) == 0 || self.au[x] == 0 || d == NONE || self.pos[d as usize] == NONE {
                continue;
            }
            self.scand[x] = true;
            // The heaviest first; of two as heavy, a block parameter before an instruction (the later value
            // first): the values an edge passes it then follow it into its register.
            self.cand.push(SEG_WT - self.kw[x].min(SEG_WT) << 24 | (n - 1 - x) as u64);
        }
        if self.cand.len() == 0 {
            return;
        }
        self.cand.sort();
        let e0 = b.blocks[0].param_start as usize;
        for k in 0..arr.len() {
            let x = ni + e0 + k;
            if arr[k] != 0 && x < nv && self.au[x] != 0 {
                self.scand[x] = true;
            }
        }
        self.read_blocks(b, n);
        fill(&mut self.segd, n, false);
        fill(&mut self.seg_mem, n, false);
        fill(&mut self.seg_past, n, false);
        fill(&mut self.vseg, n, NONE);
        fill(&mut self.thru, np, 0);
        fill(&mut self.part, 2 * self.base[np] as usize, 0);
        fill(&mut self.lin, np, 0);
        fill(&mut self.lout, np, 0);
        fill(&mut self.lrd, np, 0);
        fill(&mut self.lsel, np, 0);
        fill(&mut self.lix, np, 0);
        fill(&mut self.rhead, 64, NONE);
        self.rnext.truncate(0);
        self.vnext.truncate(0);
        self.sgen = 0;
        // A body that sets its frame up on the edges into the blocks of `after` saves a callee-saved
        // register there, as often as those edges run.
        self.save = if self.after.len() != 0 {
            SAVE_COST.min(2 * self.after_into(b))
        } else {
            SAVE_COST
        };
        fill(&mut self.emark, np, 0);
        self.egen = 0;
        // The registers the parameters arrive in, each until its parameter's last read in the entry block.
        self.arr_of.truncate(0);
        self.arr_of.extend_copy(arr);
        fill(&mut self.arr_hi, 64, 0);
        let mut pinm: u64 = 0;
        let mut st: u32 = 0;
        if self.pos[0] == 0 {
            for k in 0..arr.len() {
                let x = ni + e0 + k;
                if arr[k] == 0 || x >= nv || self.au[x] == 0 {
                    continue;
                }
                st += 1;
                self.spread(x, 0, st);
                let hi = self.ends(b, x as u32, 0, 0, st).1;
                let mut m = arr[k];
                // Each step clears one register's bit.
                while m != 0 {
                    let r = m.trailing_zeros();
                    m &= m - 1;
                    self.arr_hi[r] = self.arr_hi[r].max(hi);
                }
                pinm |= arr[k];
            }
        }
        let mut cused: u64 = 0;
        for c in 0..self.cand.len() {
            let x = n - 1 - (self.cand[c] & 0xFFFFFF) as usize;
            let w = want[x];
            st += 1;
            let dp = self.pos[self.def_blk[x] as usize];
            self.spread(x, dp, st);
            let entry = x >= ni && x < nv && self.def_blk[x] == 0 && x - ni - e0 < arr.len();
            let part = x < self.part_in.len() && self.part_in[x] != REG_NONE;
            let own = if entry {
                arr[x - ni - e0]
            } else if part {
                1u64 << self.part_in[x] as u64
            } else {
                0
            };
            // The register it arrives in, outside the classes, when it may keep it.
            let keep = if entry && x - ni - e0 < 64 && (quiet >> (x - ni - e0) as u64 & 1) != 0 && (own & own - 1) == 0 || part && (self.part_quiet & own) != 0 {
                own & sets.xa
            } else {
                0
            };
            let nl = self.lblk.len();
            fill(&mut self.llo, nl, 0);
            fill(&mut self.lhi, nl, 0);
            fill(&mut self.lav, nl, 0);
            fill(&mut self.lnow, nl, 0);
            let mut all: u64 = ~0u64;
            let mut any: u64 = 0;
            // What the value weighs: its reads, and its definition (`wt` counts an instruction's).
            let bare = self.wt[x] + ast::pick(x >= ni, self.freq[self.def_blk[x] as usize], 0u64);
            for i in 0..nl {
                let q = self.lblk[i];
                self.lix[q as usize] = i as u32;
                let (lo, hi) = self.ends(b, x as u32, q, dp, st);
                self.llo[i] = lo;
                self.lhi[i] = hi;
                let a = self.room(b, w, caps, sets, x as u32, q, dp, lo, hi, st, own, pinm, keep, false);
                self.lav[i] = a;
                all &= a;
                any |= a;
                if self.lrd[q as usize] == st {
                    let loads = if q == dp {
                        x >= ni
                    } else {
                        !(self.continues(b, q) && (self.lrd[q as usize - 1] == st || q - 1 == dp && x < ni))
                    };
                    if loads {
                        self.lnow[i] = self.freq[self.order[q as usize] as usize];
                    }
                }
            }
            let cs = sets.xc | sets.vc;
            // A constant a generator rebuilds, a flag and an aggregate's pointer take a register for all of
            // their range or none.
            let whole = (w & WANT_WHOLE) != 0 || x >= nv || x >= ni && agg_param(b, VPARAM | (x - ni) as u32);
            // Its home's store, when it has no register: not a parameter that arrives in memory.
            let stored = !(entry && own == 0);
            // In a body that sets its frame up in the blocks of `after` alone, a value made in another block
            // has no stack home there (`frame_put`); a parameter may hold the register it arrives in over
            // those other blocks (`quiet_out`).
            let bound = self.after.len() != 0 && !self.after[self.def_blk[x] as usize];
            let stay = if bound && entry && x - ni - e0 < 64 && (self.quiet_out >> (x - ni - e0) as u64 & 1) != 0 && (own & own - 1) == 0 {
                own & sets.xa
            } else {
                0
            };
            if any == 0 {
                if !whole && bare >= 2 * FREQ_ENTRY {
                    let r = self.evict(b, want, caps, sets, x as u32, dp, st, own, pinm, keep, bare, 0);
                    if r != REG_NONE {
                        fill(&mut self.lbest, nl, true);
                        cused |= sets.saved(r);
                        self.seg_put(b, x, dp, r);
                    }
                }
                if !self.segd[x] && (bound || !whole) {
                    self.hints(b, x as u32, dp, st, own);
                    if bound {
                        let _ = self.frame_put(
                            b,
                            w,
                            caps,
                            sets,
                            x as u32,
                            dp,
                            st,
                            own,
                            pinm,
                            keep,
                            stay,
                            whole,
                            &mut cused,
                        );
                    } else {
                        self.past_put(b, w, caps, sets, x as u32, dp, st, own, pinm, keep, stored, cused);
                    }
                }
                continue;
            }
            self.hints(b, x as u32, dp, st, own);
            if all != 0 {
                let r = self.pick(all, sets, cused, bare >= self.save, pinm);
                if r != REG_NONE {
                    fill(&mut self.lbest, nl, true);
                    cused |= sets.saved(r);
                    self.seg_put(b, x, dp, r);
                } else if bound {
                    let _ = self.frame_put(b, w, caps, sets, x as u32, dp, st, own, pinm, keep, stay, whole, &mut cused);
                } else if !whole {
                    self.past_put(b, w, caps, sets, x as u32, dp, st, own, pinm, keep, stored, cused);
                }
                continue;
            }
            if bound && self.frame_put(b, w, caps, sets, x as u32, dp, st, own, pinm, keep, stay, whole, &mut cused) || whole {
                continue;
            }
            let mut gain: u64 = 0;
            let mut br = REG_NONE;
            let mut left = any;
            // Per register, a hash of the blocks it is free in: two registers free in the same blocks gain
            // the same, so the second is not tried. And the loads those blocks make (`rtop`): a register
            // gains no more, so one that cannot pass the best so far is not tried.
            fill(&mut self.rsig, 64, 0);
            fill(&mut self.rtop, 64, 0);
            for i in 0..nl {
                let mut m = self.lav[i];
                // Each step clears one register's bit.
                while m != 0 {
                    let r = m.trailing_zeros();
                    m &= m - 1;
                    self.rsig[r] = (self.rsig[r] ^ i as u64 + 1).wrapping_mul(0x9E3779B97F4A7C15);
                    self.rtop[r] += self.lnow[i];
                }
            }
            self.rdone.truncate(0);
            // Each step takes one register out of `left`.
            while left != 0 {
                let r = self.pick(left, sets, cused, true, pinm);
                let bit = 1u64 << r as u64;
                left &= ~bit;
                if self.rtop[r as usize] <= gain {
                    continue;
                }
                let key = self.rsig[r as usize] ^ ((bit & cs & ~cused) != 0) as u64;
                let mut tried = false;
                for j in 0..self.rdone.len() {
                    tried = tried || self.rdone[j] == key;
                }
                if tried {
                    continue;
                }
                self.rdone.push(key);
                let g = self.spans(b, dp, st, r, (bit & cs & ~cused) != 0);
                if g > gain {
                    gain = g;
                    br = r;
                    let k = replace(&mut self.lkeep, Vector::<bool>::new());
                    self.lkeep = replace(&mut self.lbest, k);
                }
            }
            // A register over all of its blocks, from a holder idle there, when that gains more.
            if bare >= 2 * FREQ_ENTRY {
                let r = self.evict(b, want, caps, sets, x as u32, dp, st, own, pinm, keep, bare, gain);
                if r != REG_NONE {
                    fill(&mut self.lbest, nl, true);
                    cused |= sets.saved(r);
                    self.seg_put(b, x, dp, r);
                    continue;
                }
            }
            if br != REG_NONE {
                cused |= sets.saved(br);
                self.seg_put(b, x, dp, br);
                self.seg_mem[x] = true;
            } else {
                self.past_put(b, w, caps, sets, x as u32, dp, st, own, pinm, keep, stored, cused);
            }
        }
        if self.seg_x.len() == 0 {
            self.segd.truncate(0);
            self.seg_mem.truncate(0);
            self.seg_past.truncate(0);
            return;
        }
        self.seg_lists(b);
    }

    // The caller-saved registers candidate `x` may hold over all of its blocks (`lblk`, `llo`, `lhi`) when
    // each call it lives across saves its register around itself (`room` with `past`): an argument
    // register too, where those calls alone write the argument registers.
    fn across(
        self: &mut Self,
        b: &Body,
        w: u8,
        caps: Caps,
        sets: Sets,
        x: u32,
        dp: u32,
        st: u32,
        own: u64,
        pinm: u64,
        keep: u64,
    ) u64 {
        let mut m = sets.xs | sets.vs | sets.xw;
        for i in 0..self.lblk.len() {
            if m == 0 {
                break;
            }
            m &= self.room(b, w, caps, sets, x, self.lblk[i], dp, self.llo[i], self.lhi[i], st, own, pinm, keep, true);
        }
        return m;
    }

    // What the saves around the calls the candidate lives across cost (`across`): a store and a load per
    // call after its definition (or from the block's start) and before its last read in each of its
    // blocks (`ccount`), as often as the block runs.
    const fn saves_cost(self: &Self, b: &Body) u64 {
        let mut cost: u64 = 0;
        for i in 0..self.lblk.len() {
            let q = self.lblk[i];
            let (first, last) = self.crossed(b, q, self.llo[i], self.lhi[i]);
            cost += (self.ccount[last as usize] - self.ccount[first as usize]) as u64 * 2 * self.freq[self.order[q as usize] as usize];
        }
        return cost;
    }

    // The instructions a value that holds the positions `lo..=hi` of the block at layout position `q` lives
    // across: from the one after its definition (or the block's first) up to its last read there, that
    // one not counted (the first, and the one past the last; none: both the same).
    const fn crossed(self: &Self, b: &Body, q: u32, lo: u32, hi: u32) (u32, u32) {
        let start = b.blocks[self.order[q as usize] as usize].start;
        let first = start + ((lo + 1) / 2 - self.base[q as usize]);
        let last = start + (hi / 2 - self.base[q as usize]);
        return (first, last.max(first));
    }

    // Candidate `x`, which no register holds: a caller-saved one over all of its blocks, saved around the
    // calls it lives across (`across`, `seg_past`), when that costs less (`saves_cost`) than no register
    // does: its home's store (`stored`) and a load in each block that reads it (`lnow`). Not when the
    // generator counts no calls (`ccount`).
    fn past_put(
        self: &mut Self,
        b: &Body,
        w: u8,
        caps: Caps,
        sets: Sets,
        x: u32,
        dp: u32,
        st: u32,
        own: u64,
        pinm: u64,
        keep: u64,
        stored: bool,
        cused: u64,
    ) {
        if self.ccount.len() != b.insts.len() + 1 {
            return;
        }
        let nl = self.lblk.len();
        let mut mem = ast::pick(stored, self.freq[self.def_blk[x as usize] as usize], 0u64);
        for i in 0..nl {
            mem += self.lnow[i];
        }
        if self.saves_cost(b) >= mem {
            return;
        }
        let m = self.across(b, w, caps, sets, x, dp, st, own, pinm, keep);
        if m == 0 {
            return;
        }
        let r = self.pick(m, sets, cused, false, pinm);
        fill(&mut self.lbest, nl, true);
        self.seg_put(b, x as usize, dp, r);
        self.seg_past[x as usize] = true;
    }

    // In a body that sets its frame up in the blocks of `after` alone, candidate `x`, made in another block,
    // which no one register holds everywhere (`lav`): it has no stack home in those other blocks, so it
    // takes a caller-saved register over all of its blocks, saved around the calls it lives across
    // (`across`, `seg_past`), or (not when `whole`) one register over its blocks outside `after` and
    // another, which may be a callee-saved one, over those in it, with a move on each edge between the
    // two: the choice that costs less (those saves; those moves and a callee-saved register's first save).
    // The register outside `after` is the one a parameter arrives in (`stay`) when no value holds it
    // there: the entry then moves nothing. Whether it took one.
    fn frame_put(
        self: &mut Self,
        b: &Body,
        w: u8,
        caps: Caps,
        sets: Sets,
        x: u32,
        dp: u32,
        st: u32,
        own: u64,
        pinm: u64,
        keep: u64,
        stay: u64,
        whole: bool,
        cused: &mut u64,
    ) bool {
        let counted = self.ccount.len() == b.insts.len() + 1;
        let m = if counted {
            self.across(b, w, caps, sets, x, dp, st, own, pinm, keep)
        } else {
            0
        };
        let nl = self.lblk.len();
        // The registers free in every block outside `after`, in every block in it, and how often the
        // edges between the two run.
        let mut out: u64 = ~0u64;
        let mut into: u64 = ~0u64;
        let mut moves: u64 = 0;
        for i in 0..nl {
            let q = self.lblk[i];
            let k = self.order[q as usize];
            if self.after[k as usize] {
                into &= self.lav[i];
            } else if stay != 0 {
                out &= self.room(b, w, caps, sets, x, q, dp, self.llo[i], self.lhi[i], st, own, pinm, stay, false);
            } else {
                out &= self.lav[i];
            }
            if q == dp {
                continue;
            }
            for j in self.pat[k as usize]..self.pat[k as usize + 1] {
                let p = self.preds[j as usize];
                if self.pos[p as usize] != NONE && self.after[p as usize] != self.after[k as usize] {
                    moves += self.edge_freq(b, p, k);
                }
            }
        }
        let split = !whole && out != 0 && into != 0 && into != ~0u64;
        let rin = if split {
            self.pick(into, sets, *cused, true, pinm)
        } else {
            REG_NONE
        };
        let fresh = split && (1u64 << rin as u64 & (sets.xc | sets.vc) & ~*cused) != 0;
        // A parameter that takes another register than the one it arrives in moves at the entry.
        let moved = ast::pick(split && (out & stay) != 0, self.freq[self.def_blk[x as usize] as usize], 0u64);
        if m != 0 && (!split || self.saves_cost(b) + moved <= moves + ast::pick(fresh, self.save, 0u64)) {
            let r = self.pick(m, sets, *cused, false, pinm);
            fill(&mut self.lbest, nl, true);
            self.seg_put(b, x as usize, dp, r);
            self.seg_past[x as usize] = true;
            return true;
        }
        if !split {
            return false;
        }
        let rout = if (out & stay) != 0 {
            stay.trailing_zeros() as u8
        } else {
            self.pick(out, sets, *cused, false, pinm)
        };
        fill(&mut self.lbest, nl, false);
        for i in 0..nl {
            self.lbest[i] = !self.after[self.order[self.lblk[i] as usize] as usize];
        }
        self.seg_put(b, x as usize, dp, rout);
        for i in 0..nl {
            self.lbest[i] = !self.lbest[i];
        }
        self.seg_put(b, x as usize, dp, rin);
        *cused |= sets.saved(rin);
        return true;
    }

    // `sin`, `sin_at`: per layout position, the segments that hold their value there (`gpool`).
    fn seg_lists(self: &mut Self, b: &Body) {
        let np = self.order.len();
        let ns = self.seg_x.len();
        let ni = b.insts.len() as u32;
        fill(&mut self.sin_at, np + 1, 0);
        fill(&mut self.multi, np, 0);
        for s in 0..ns {
            let a = self.seg_a[s];
            let bit = 1u64 << self.seg_r[s] as u64;
            for q in a..self.seg_b[s] + 1 {
                if self.gpool[(self.seg_at[s] + q - a) as usize] {
                    self.multi[q as usize] |= self.solo[q as usize] & bit;
                    self.solo[q as usize] |= bit;
                }
            }
            // A block parameter held in its block: the edges into the block write its register.
            let x = self.seg_x[s];
            if x < ni || x >= ni + b.params.len() as u32 {
                continue;
            }
            let k = self.def_blk[x as usize];
            if !self.holds_at(s as u32, self.pos[k as usize]) {
                continue;
            }
            for i in self.pat[k as usize]..self.pat[k as usize + 1] {
                let pp = self.pos[self.preds[i as usize] as usize];
                if pp != NONE {
                    self.multi[pp as usize] |= bit;
                }
            }
        }
        for q in 0..np {
            self.solo[q] &= ~self.multi[q];
        }
        for pass in 0..2u32 {
            if pass == 1 {
                let mut acc: u32 = 0;
                for q in 0..np {
                    let c = self.sin_at[q];
                    self.sin_at[q] = acc;
                    acc += c;
                }
                self.sin_at[np] = acc;
                fill(&mut self.sin, acc as usize, 0);
            }
            for s in 0..ns {
                let a = self.seg_a[s];
                for q in a..self.seg_b[s] + 1 {
                    if !self.gpool[(self.seg_at[s] + q - a) as usize] {
                        continue;
                    }
                    if pass == 1 {
                        self.sin[self.sin_at[q as usize] as usize] = s as u32;
                    }
                    self.sin_at[q as usize] += 1;
                }
            }
        }
        // The second pass left each position's end where its start goes.
        for q0 in 0..np {
            let q = np - 1 - q0;
            self.sin_at[q + 1] = self.sin_at[q];
        }
        self.sin_at[0] = 0;
    }

    // `su`, `sul`: per value of `scand` (of `n`), the layout positions of the blocks that read it, in order,
    // and the last instruction of each that does.
    fn read_blocks(self: &mut Self, b: &Body, n: usize) {
        let np = self.order.len();
        fill(&mut self.su_at, n + 1, 0);
        for pass in 0..2u32 {
            fill(&mut self.smark, n, NONE);
            if pass == 1 {
                let mut acc: u32 = 0;
                for x in 0..n {
                    let c = self.su_at[x];
                    self.su_at[x] = acc;
                    acc += c;
                }
                self.su_at[n] = acc;
                fill(&mut self.su, acc as usize, 0);
                fill(&mut self.sul, acc as usize, 0);
            }
            for p in 0..np {
                let bk = b.blocks[self.order[p] as usize];
                for i in bk.start..bk.start + bk.len {
                    let a = self.ua[i as usize];
                    for u in a..a + self.un[i as usize] {
                        let x = self.vix(b, self.uv[u as usize]) as usize;
                        if x >= n || !self.scand[x] {
                            continue;
                        }
                        if self.smark[x] == p as u32 {
                            if pass == 1 {
                                self.sul[self.su_at[x] as usize - 1] = i;
                            }
                            continue;
                        }
                        self.smark[x] = p as u32;
                        if pass == 1 {
                            self.su[self.su_at[x] as usize] = p as u32;
                            self.sul[self.su_at[x] as usize] = i;
                        }
                        self.su_at[x] += 1;
                    }
                }
            }
        }
        for x0 in 0..n {
            let x = n - 1 - x0;
            self.su_at[x + 1] = self.su_at[x];
        }
        self.su_at[0] = 0;
    }

    // The blocks value `x` (defined in the block at layout position `dp`) is live in, into `lblk` in layout
    // order: `dp`, and each block it is live into (`lin` holds `st` there), a walk back from the blocks
    // that read it (`su`; `lrd`) to `dp`. `lout` holds `st` where it is live out of the block.
    fn spread(self: &mut Self, x: usize, dp: u32, st: u32) {
        self.lblk.truncate(0);
        self.stack.truncate(0);
        for k in self.su_at[x]..self.su_at[x + 1] {
            let q = self.su[k as usize];
            self.lrd[q as usize] = st;
            if q != dp && self.lin[q as usize] != st {
                self.lin[q as usize] = st;
                self.stack.push(q);
                self.lblk.push(q);
            }
        }
        // Each step takes a block that entered the stack once.
        while self.stack.len() != 0 {
            let last = self.stack.len() - 1;
            let q = self.stack[last];
            self.stack.truncate(last);
            let k = self.order[q as usize];
            for i in self.pat[k as usize]..self.pat[k as usize + 1] {
                let pp = self.pos[self.preds[i as usize] as usize];
                if pp == NONE {
                    continue;
                }
                self.lout[pp as usize] = st;
                if pp != dp && self.lin[pp as usize] != st {
                    self.lin[pp as usize] = st;
                    self.stack.push(pp);
                    self.lblk.push(pp);
                }
            }
        }
        self.lblk.push(dp);
        self.lblk.sort();
    }

    /// The last instruction of the block at layout position `q` that reads value `x` (`sul`), NONE for none:
    /// at most 32 halvings.
    pub(package) const fn read_last(self: &Self, x: u32, q: u32) u32 {
        let mut lo = self.su_at[x as usize] as usize;
        let mut hi = self.su_at[x as usize + 1] as usize;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if self.su[mid] < q {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if lo < self.su_at[x as usize + 1] as usize && self.su[lo] == q {
            return self.sul[lo];
        }
        return NONE;
    }

    // The value of value index `x` of `b`; VNONE for a flag.
    const fn val_of(b: &Body, x: u32) Value {
        let ni = b.insts.len() as u32;
        return if x < ni {
            x
        } else if x < ni + b.params.len() as u32 {
            VPARAM | x - ni
        } else {
            VNONE
        };
    }

    // Whether instruction `l` of `b`, the last read of value `x` on its path, may write its result into
    // `x`'s register: a terminator that reads `x` as edge arguments alone (the edge's moves read every
    // argument before they write a parameter) or as a switch's scrutinee, or an instruction every generator
    // emits reading its first operand before it writes its result (`over_inst`), `x` its first operand
    // alone; on a target that reads them all before (`three`), any operand of a `three_op`; on one that
    // writes over an operand (`two`), an operand a `two_op` may be written over; a call's argument the
    // generator writes its result over (`cover`).
    const fn over(self: &Self, b: &Body, x: u32, l: u32) bool {
        let v = Live::val_of(b, x);
        if v == VNONE {
            return false;
        }
        let t = b.insts[l as usize];
        let a = self.ua[l as usize];
        let mut n: u32 = 0;
        for u in a..a + self.un[l as usize] {
            n += (self.uv[u as usize] == v) as u32;
        }
        if is_terminator(t.op) {
            // A switch reads its scrutinee before any of its edges moves.
            let mut m = (t.op == O_SWITCH && self.seen(t.a) == v) as u32;
            for e in 0..edge_count(t) {
                let ed = edge_of(b, t, e);
                for j in 0..b.edge_nargs(ed) {
                    m += (self.arg(b, ed, j) == v) as u32;
                }
            }
            return m == n;
        }
        if t.op == O_CALL && l as usize < self.cover.len() && self.cover[l as usize] != NONE {
            return n == 1 && self.seen(b.pool[(t.c + self.cover[l as usize]) as usize]) == v;
        }
        // BLSR, BLSMSK or BLSI (`FOLD_BLS`) reads its one source, `v` and the folded `v - 1` or `-v`, before
        // it writes its result.
        if self.three && (t.op == O_AND || t.op == O_XOR) {
            let (kind, s, xv) = bls_parts(b, t);
            if kind != 0 && self.pfold[s as usize] && self.seen(xv) == v {
                return true;
            }
        }
        return n == 1 && self.seen(t.a) == v && over_inst(b, t) || self.three && three_op(t) && (!self.two || n == 1 && self.two_op(
            b,
            l,
            v,
        ));
    }

    // Whether a generator whose instructions write over an operand (`two`) may write the result of
    // instruction `l` of `b` over its operand `v`: either operand of an integer or float sum or product
    // or of an `and`, `or` or `xor` (they commute), the first operand of the high part of a sum with a
    // carry (`CARRY_ADC`), a side of a select (the false side of a vector's), the base or the index of a
    // pointer sum (one `lea`), a load's address, an operand of a lanewise vector operation.
    const fn two_op(self: &Self, b: &Body, l: u32, v: Value) bool {
        let t = b.insts[l as usize];
        let o = t.op;
        if o == O_VOP {
            return true;
        }
        let (ta, tb, tc) = (self.seen(t.a), self.seen(t.b), self.seen(t.c));
        if o == O_SELECT {
            return tb == v || tc == v;
        }
        if o == O_VSEL {
            return tc == v;
        }
        if o == O_LOAD {
            return ta == v;
        }
        if self.carry.len() == b.insts.len() && self.carry[l as usize] == CARRY_ADC {
            // The folded high sum is one of the two operands.
            for q in 0..2u32 {
                let h = ast::pick(q == 0, t.a, t.b);
                if h != VNONE && (h & (VPARAM | VFLAG)) == 0 && self.carry[h as usize] == CARRY_PART && b.insts[h as usize].op != O_ZEXT && b.insts[h as usize].a == v {
                    return true;
                }
            }
        }
        let commutes = o == O_ADD || o == O_MUL || o == O_AND || o == O_OR || o == O_XOR || o == O_FADD || o == O_FMUL;
        return (commutes || o == O_PTRADD) && (ta == v || tb == v);
    }

    // The positions value `x` holds a register at in the block at layout position `q` where it is live
    // (`spread`): the first and the last, two per instruction (its reads, then its result). From its
    // definition (a parameter, a flag, a value live into the block: the block's start) to the block's end
    // when it is live out of it, else to its last read: that read's result too, but one `over` permits.
    const fn ends(self: &Self, b: &Body, x: u32, q: u32, dp: u32, st: u32) (u32, u32) {
        let ni = b.insts.len() as u32;
        let bk = b.blocks[self.order[q as usize] as usize];
        let p0 = self.base[q as usize];
        let lo = if q == dp && x < ni {
            2 * (p0 + x - bk.start) + 1
        } else {
            2 * p0
        };
        if self.lout[q as usize] == st {
            return (lo, 2 * self.base[q as usize + 1] - 1);
        }
        let l = self.read_last(x, q);
        if l == NONE {
            return (lo, lo);
        }
        return (lo, 2 * (p0 + l - bk.start) + (!self.over(b, x, l)) as u32);
    }

    // The registers value index `x` of `b` is in before the plan places it: those a parameter of the
    // signature arrives in (`arr_of`), the one a load of a part of one finds its value in (`part_in`); 0
    // for another value.
    const fn arrival(self: &Self, b: &Body, x: u32) u64 {
        let ni = b.insts.len() as u32;
        let e0 = b.blocks[0].param_start;
        if x >= ni + e0 && self.def_blk[x as usize] == 0 && (x - ni - e0) as usize < self.arr_of.len() {
            return self.arr_of[(x - ni - e0) as usize];
        }
        if x as usize < self.part_in.len() && self.part_in[x as usize] != REG_NONE {
            return 1u64 << self.part_in[x as usize] as u64;
        }
        return 0;
    }

    // The segment that holds value `y` in its register through the block at layout position `q` (`vseg`,
    // `vnext`: at most SEG_PARTS per value), NONE for none.
    const fn held(self: &Self, y: u32, q: u32) u32 {
        let mut s = self.vseg[y as usize];
        for _ in 0..SEG_PARTS {
            if s == NONE || self.holds_at(s, q) {
                return s;
            }
            s = self.vnext[s as usize];
        }
        return NONE;
    }

    // Whether nothing writes the caller-saved registers (`wide`: the argument registers) while a value
    // lives over the positions `lo..=hi` (`ends`) of the block at layout position `q`: the block has no such
    // instruction (`cfirst`, `clast`; `wfirst`, `wlast`); or the value is defined at or after its last one;
    // or its last read is before its first one, or is that one (which reads it in a caller-saved register,
    // but not in one that passes an argument).
    const fn calm(self: &Self, b: &Body, q: u32, lo: u32, hi: u32, wide: bool) bool {
        let np = self.order.len();
        if wide && self.wfirst.len() != np {
            return false;
        }
        if !wide && self.cfirst.len() != np {
            return true;
        }
        let (cf, cl) = if wide {
            (self.wfirst[q as usize], self.wlast[q as usize])
        } else {
            (self.cfirst[q as usize], self.clast[q as usize])
        };
        if cf == NONE {
            return true;
        }
        let bk = b.blocks[self.order[q as usize] as usize];
        let pf = self.base[q as usize] + cf - bk.start;
        let pl = self.base[q as usize] + cl - bk.start;
        if (lo & 1) == 1 && lo >> 1 >= pl {
            return true;
        }
        let li = hi >> 1;
        return li < pf || li == pf && !wide;
    }

    // Whether the instructions that write the argument registers while a value lives over the positions
    // `lo..=hi` of the block at layout position `q` (`crossed`) are all calls that write the caller-saved
    // homes (`wcount`, `ccount`): each saves a home it lives across around itself (`past_put`).
    const fn calls_alone(self: &Self, b: &Body, q: u32, lo: u32, hi: u32) bool {
        if self.wcount.len() != self.ccount.len() {
            return false;
        }
        let (first, last) = self.crossed(b, q, lo, hi);
        return self.wcount[last as usize] - self.wcount[first as usize] == self.ccount[last as usize] - self.ccount[first as usize];
    }

    // The registers a value may be the first to hold in the block at layout position `q`, with those it
    // holds already (`bmask`): the caller-saved ones while the block's temporaries have theirs left
    // (`scap`) and the class has not its count (`caps`), all of them while the joint count allows.
    const fn addable(self: &Self, q: u32, caps: Caps, sets: Sets) u64 {
        let np = self.order.len();
        let a = self.bmask[q as usize];
        let nc = (a & sets.xc).count_ones() as u32;
        let ns = (a & sets.xs).count_ones() as u32;
        let nw = (a & (sets.xw | sets.xa)).count_ones() as u32;
        let mut m = a;
        let temps = self.scap.len() != np || ns + nw < self.scap[q as usize];
        // The block's own cap, when the generator gives one, stands for the body's.
        let jc = if self.jcap.len() == np {
            self.jcap[q as usize]
        } else {
            caps.xj
        };
        let joint = nc + ns < jc;
        if temps && joint && ns < caps.xs {
            m |= sets.xs;
        }
        if temps && (self.jcap.len() != np || nc + ns + nw < self.jcap[q as usize]) {
            m |= sets.xw | sets.xa;
        }
        if joint && nc < caps.xc {
            m |= sets.xc;
        }
        let vc = (a & sets.vc).count_ones() as u32;
        let vs = (a & sets.vs).count_ones() as u32;
        let vu = (a & sets.vu).count_ones() as u32;
        if vc + vs + vu < caps.vj {
            if vs < caps.vs {
                m |= sets.vs;
            }
            if vu < caps.vu {
                m |= sets.vu;
            }
            if vc < caps.vc {
                m |= sets.vc;
            }
        }
        return m;
    }

    // The registers value `x` (request `w`) may hold over the positions `lo..=hi` of the block at layout
    // position `q`: of the classes it asks for that are calm there (the caller-saved ones also where a call
    // writes them, when `past`: the call saves the register around itself; the argument ones then where
    // such calls alone write them, `calls_alone`), with room (`addable`), that no value
    // holds at one of those positions (`thru`, `part`), nor a parameter of the signature that arrived
    // there (`pinm`, `arr_hi`; not `own`, the ones `x` arrives in); `keep`, the one it arrives in outside the
    // classes, too. A value live at the terminator leaves
    // the registers of the parameters the terminator's edges write, but of those that take it (the edge
    // then moves nothing, and the register holds one value). A parameter in its own block (`dp`): at the
    // end of each block that enters it the register is free, or holds the argument that edge passes it;
    // no other argument of that terminator is in it, which the moves still read.
    const fn room(
        self: &mut Self,
        b: &Body,
        w: u8,
        caps: Caps,
        sets: Sets,
        x: u32,
        q: u32,
        dp: u32,
        lo: u32,
        hi: u32,
        st: u32,
        own: u64,
        pinm: u64,
        keep: u64,
        past: bool,
    ) u64 {
        let ni = b.insts.len() as u32;
        let n = self.end.len() as u32;
        let k = self.order[q as usize];
        let p0 = 2 * self.base[q as usize];
        let p1 = 2 * self.base[q as usize + 1] - 1;
        // The registers of the parameters the terminator's edges pass `x` to: at the terminator's result
        // they hold `x`'s own value.
        let v = Live::val_of(b, x);
        let mut recv: u64 = 0;
        if hi >= p1 - 1 && v != VNONE && self.lrd[q as usize] == st && self.read_last(x, q) == b.blocks[k as usize].start + b.blocks[k as usize].len - 1 {
            let t = term(b, k);
            for e in 0..edge_count(t) {
                let ed = edge_of(b, t, e);
                let tk = b.edge_target(ed);
                for j in 0..b.edge_nargs(ed) {
                    let y = ni + b.blocks[tk as usize].param_start + j;
                    if self.arg(b, ed, j) != v {
                        continue;
                    }
                    let s = self.held(y, self.pos[tk as usize]);
                    if s != NONE {
                        recv |= 1u64 << self.seg_r[s as usize] as u64;
                    }
                }
            }
        }
        let mut acc = if lo == p0 && hi == p1 && recv == 0 {
            self.bmask[q as usize]
        } else {
            let mut m = self.thru[q as usize];
            for hp in lo..hi.min(p1 - 1) + 1 {
                m |= self.part[hp as usize];
            }
            if lo == p0 && hi == p1 {
                m |= self.bmask[q as usize] & ~recv;
            }
            m
        };
        if hi >= p1 - 1 {
            acc |= self.part[p1 as usize] & ~recv;
        }
        if q == 0 {
            let mut m = pinm & ~own;
            // Each step clears one register's bit.
            while m != 0 {
                let r = m.trailing_zeros();
                m &= m - 1;
                if lo <= self.arr_hi[r] {
                    acc |= 1u64 << r as u64;
                }
            }
        }
        let vf = (w & WANT_V) != 0;
        let (c, s, wd) = if vf {
            (sets.vc, sets.vs, 0u64)
        } else {
            (sets.xc, sets.xs, sets.xw)
        };
        let mut m = keep;
        // A body that sets its frame up in the blocks of `after` alone saves no callee-saved register in the
        // others.
        if (w & WANT_CALLEE) != 0 && (self.after.len() == 0 || self.after[k as usize]) {
            m |= c;
        }
        if (w & WANT_SCRATCH) != 0 {
            if past || self.calm(b, q, lo, hi, false) {
                m |= s;
            }
            if wd != 0 && (self.calm(b, q, lo, hi, true) || past && self.calls_alone(b, q, lo, hi)) {
                m |= wd;
            }
        }
        if vf && (w & WANT_UPPER) != 0 {
            m |= sets.vu;
        }
        m &= ~acc & self.addable(q, caps, sets);
        if x < ni || x >= ni + b.params.len() as u32 || q != dp {
            return m;
        }
        let j = x - ni - b.blocks[k as usize].param_start;
        // The parameter of a loop before the block that every edge into the block continues
        // (`exit_partner`): on each such edge its register holds `x`'s value, or the edge writes that value
        // there.
        let ep = self.exit_partner(b, x);
        let es = if ep != NONE {
            self.held(ep, self.pos[self.def_blk[ep as usize] as usize])
        } else {
            NONE
        };
        let epm = if es != NONE {
            1u64 << self.seg_r[es as usize] as u64
        } else {
            0
        };
        for i in self.pat[k as usize]..self.pat[k as usize + 1] {
            let p = self.preds[i as usize];
            let pp = self.pos[p as usize];
            if pp == NONE {
                continue;
            }
            let t = term(b, p);
            let d = 2 * self.base[pp as usize + 1] - 1;
            // `mine`: the registers of the arguments the edges pass to `x`; `others`: those of the other
            // arguments of the terminator, which its moves read.
            let mut mine = epm;
            let mut others: u64 = 0;
            for e in 0..edge_count(t) {
                let ed = edge_of(b, t, e);
                for ja in 0..b.edge_nargs(ed) {
                    let a = self.arg(b, ed, ja);
                    if a == VNONE {
                        continue;
                    }
                    let ax = self.vix(b, a);
                    if ax >= n {
                        continue;
                    }
                    let mut r: u64 = 0;
                    let s = self.held(ax, pp);
                    if s != NONE {
                        r = 1u64 << self.seg_r[s as usize] as u64;
                    } else if pp == 0 && self.vseg[ax as usize] == NONE {
                        // A parameter of the signature, or a part of one, still in the register it
                        // arrived in.
                        r = self.arrival(b, ax);
                    }
                    if b.edge_target(ed) == k && ja == j {
                        mine |= r;
                    } else {
                        others |= r;
                    }
                }
            }
            // A parameter of the signature that holds its arrival register past the terminator's reads.
            let mut pins: u64 = 0;
            if pp == 0 {
                let mut pm = pinm;
                // Each step clears one register's bit.
                while pm != 0 {
                    let r = pm.trailing_zeros();
                    pm &= pm - 1;
                    if self.arr_hi[r] >= d {
                        pins |= 1u64 << r as u64;
                    }
                }
            }
            m &= ~((self.thru[pp as usize] | self.part[d as usize] | pins) & ~mine | others & ~mine) & self.addable(
                pp,
                caps,
                sets,
            );
        }
        return m;
    }

    // The register an unplaced parameter of the signature, or a part of one, arrives in (`arrival`, one
    // register) that an edge into block `k` passes to its parameter `j`; REG_NONE for none.
    const fn arrives(self: &Self, b: &Body, k: u32, j: u32) u8 {
        let n = self.end.len() as u32;
        for i in self.pat[k as usize]..self.pat[k as usize + 1] {
            let t = term(b, self.preds[i as usize]);
            for e in 0..edge_count(t) {
                let ed = edge_of(b, t, e);
                if b.edge_target(ed) != k || j >= b.edge_nargs(ed) || self.arg(b, ed, j) == VNONE {
                    continue;
                }
                let ax = self.vix(b, self.arg(b, ed, j));
                if ax >= n || self.vseg[ax as usize] != NONE {
                    continue;
                }
                let m = self.arrival(b, ax);
                if m != 0 && (m & m - 1) == 0 {
                    return m.trailing_zeros() as u8;
                }
            }
        }
        return REG_NONE;
    }

    // One more reason of weight `wgt` for the value at hand to take register `r` (`hq`: weight << 8 |
    // register).
    fn hint(self: &mut Self, r: u8, wgt: u64) {
        let g = wgt.min(SEG_WT).max(1) << 8;
        for i in 0..self.hq.len() {
            if (self.hq[i] & 0xFF) as u8 == r {
                self.hq[i] += g;
                return;
            }
        }
        self.hq.push(g | r as u64);
    }

    // `hq`: the registers value `x` (after `spread` and `ends`) shares without a move, each with how often
    // the move it saves would run: those of the arguments the edges into its block pass it (a parameter),
    // of the parameters its reading blocks' edges pass it to, of the operands it may write over
    // (`over`), of the instructions that may write over it, the one it arrives in (`own`) and the one the
    // generator reads it in (`rhint`).
    fn hints(self: &mut Self, b: &Body, x: u32, dp: u32, st: u32, own: u64) {
        self.hq.truncate(0);
        let ni = b.insts.len() as u32;
        let n = self.end.len() as u32;
        let v = Live::val_of(b, x);
        if v == VNONE {
            return;
        }
        if own != 0 && (own & own - 1) == 0 {
            self.hint(own.trailing_zeros() as u8, FREQ_ENTRY);
        }
        // The register the generator reads it in (the result's).
        if self.rhint.len() == n as usize && self.rhint[x as usize] != REG_NONE {
            self.hint(self.rhint[x as usize], self.freq[self.order[dp as usize] as usize] + 1);
        }
        if x >= ni {
            let k = self.order[dp as usize];
            let j = x - ni - b.blocks[k as usize].param_start;
            let ep = self.exit_partner(b, x);
            if ep != NONE {
                let s = self.held(ep, self.pos[self.def_blk[ep as usize] as usize]);
                if s != NONE {
                    self.hint(self.seg_r[s as usize], self.freq[k as usize]);
                }
            }
            for i in self.pat[k as usize]..self.pat[k as usize + 1] {
                let p = self.preds[i as usize];
                let pp = self.pos[p as usize];
                if pp == NONE {
                    continue;
                }
                let t = term(b, p);
                for e in 0..edge_count(t) {
                    let ed = edge_of(b, t, e);
                    if b.edge_target(ed) != k || j >= b.edge_nargs(ed) || self.arg(b, ed, j) == VNONE {
                        continue;
                    }
                    let ax = self.vix(b, self.arg(b, ed, j));
                    if ax >= n {
                        continue;
                    }
                    // No edge runs more often than its target (an edge out of a loop runs less than
                    // `edge_freq` gives it).
                    let f = self.edge_freq(b, p, k).min(self.freq[k as usize]);
                    let s = self.held(ax, pp);
                    if s != NONE {
                        self.hint(self.seg_r[s as usize], f);
                        continue;
                    }
                    // A parameter of the signature, or a part of one, the plan has not placed: the register
                    // it arrives in.
                    if self.vseg[ax as usize] == NONE {
                        let m = self.arrival(b, ax);
                        if m != 0 && (m & m - 1) == 0 {
                            self.hint(m.trailing_zeros() as u8, f);
                        }
                    }
                }
            }
        } else {
            // Each operand it may write over: the instruction's own reads bound the walk.
            for u in self.ua[x as usize]..self.ua[x as usize] + self.un[x as usize] {
                let ax = self.vix(b, self.uv[u as usize]);
                if ax >= n {
                    continue;
                }
                let s = self.held(ax, dp);
                if s != NONE && self.over(b, ax, x) {
                    self.hint(self.seg_r[s as usize], self.freq[self.order[dp as usize] as usize]);
                }
            }
        }
        for u in self.su_at[x as usize]..self.su_at[x as usize + 1] {
            let q = self.su[u as usize];
            let k = self.order[q as usize];
            let l = self.sul[u as usize];
            let t = term(b, k);
            let bk = b.blocks[k as usize];
            if l == bk.start + bk.len - 1 {
                for e in 0..edge_count(t) {
                    let ed = edge_of(b, t, e);
                    let tk = b.edge_target(ed);
                    for j in 0..b.edge_nargs(ed) {
                        let y = ni + b.blocks[tk as usize].param_start + j;
                        if self.arg(b, ed, j) != v || self.pos[tk as usize] == NONE {
                            continue;
                        }
                        let s = self.held(y, self.pos[tk as usize]);
                        if s != NONE {
                            let f = self.edge_freq(b, k, tk).min(self.freq[tk as usize]);
                            self.hint(self.seg_r[s as usize], f);
                        } else if self.vseg[y as usize] == NONE {
                            // That parameter has no register yet: the one a parameter of the signature that
                            // another edge passes it arrives in (the least reason).
                            let c = self.arrives(b, tk, j);
                            if c != REG_NONE {
                                self.hint(c, 1);
                            }
                        }
                    }
                }
            } else if self.lout[q as usize] != st {
                let s = self.held(l, q);
                if s != NONE && self.over(b, x, l) {
                    self.hint(self.seg_r[s as usize], self.freq[k as usize]);
                }
            }
        }
    }

    // The register of `mask` the value at hand takes first: the one that saves most moves (`hq`), else a
    // caller-saved one, an argument one, a callee-saved one the body saves already (`cused`), then, when
    // `pay` (it weighs no less than `save`), another callee-saved one; the lowest of each,
    // one no parameter of the signature arrives in (`pinm`) first: that parameter may keep it. REG_NONE
    // for none.
    const fn pick(self: &Self, mask: u64, sets: Sets, cused: u64, pay: bool, pinm: u64) u8 {
        let mut best: u64 = 0;
        for i in 0..self.hq.len() {
            if (mask >> (self.hq[i] & 0xFF) & 1) != 0 && self.hq[i] > best {
                best = self.hq[i];
            }
        }
        if best != 0 {
            return (best & 0xFF) as u8;
        }
        let s = mask & (sets.xs | sets.vs);
        if (s & ~pinm) != 0 {
            return (s & ~pinm).trailing_zeros() as u8;
        }
        let wd = mask & sets.xw;
        if (wd & ~pinm) != 0 {
            return (wd & ~pinm).trailing_zeros() as u8;
        }
        if (s | wd) != 0 {
            return (s | wd).trailing_zeros() as u8;
        }
        if (mask & sets.vu) != 0 {
            return (mask & sets.vu).trailing_zeros() as u8;
        }
        let c = mask & (sets.xc | sets.vc);
        if (c & cused & sets.first) != 0 {
            return (c & cused & sets.first).trailing_zeros() as u8;
        }
        if (c & cused) != 0 {
            return (c & cused).trailing_zeros() as u8;
        }
        if c == 0 || !pay {
            return REG_NONE;
        }
        return ast::pick((c & sets.first) != 0, (c & sets.first).trailing_zeros() as u8, c.trailing_zeros() as u8);
    }

    // What register `r` gains for the value at hand over the blocks of `lblk` where it may hold it (`lav`), and
    // those blocks into `lkeep`: per group of such blocks that edges join, how often the blocks that load
    // the value without it run (`lnow`), less how often the edges into the group from blocks that do not hold
    // it in `r` run; a group that gains nothing, or that a late edge enters (its stub cannot load), is left
    // out. Less `save` when `fresh` (a callee-saved register the body does not save yet).
    // A register for candidate `x` (weight `bare`) over all of its blocks, which no register is free in
    // (`lav`): one whose holder in each block where it is not free holds it through that block and reads
    // nothing there (a value that lives through a loop it is idle in). The holder leaves those blocks: it
    // keeps a stack home, and each edge from them into a block where it holds the register loads it. Only
    // when `x` gains more than those loads, the holder's store, and `gain` (what a register over a part of
    // `x`'s blocks gains), and when no such edge is a late one (its stub loads nothing). REG_NONE when no
    // holder gives way. At most `EVICT_SCAN` segments per register are searched for the holder.
    fn evict(
        self: &mut Self,
        b: &Body,
        want: &Vector<u8>,
        caps: Caps,
        sets: Sets,
        x: u32,
        dp: u32,
        st: u32,
        own: u64,
        pinm: u64,
        keep: u64,
        bare: u64,
        gain: u64,
    ) u8 {
        let ni = b.insts.len() as u32;
        let nv = ni + b.params.len() as u32;
        let nl = self.lblk.len();
        let mut best = REG_NONE;
        let mut best_s = NONE;
        let mut best_net = gain;
        let mut regs = sets.xc | sets.xs | sets.xw | sets.vc | sets.vs | sets.vu;
        // Each step takes one register out of `regs`.
        while regs != 0 {
            let r = regs.trailing_zeros() as u8;
            let bit = 1u64 << r as u64;
            regs &= ~bit;
            let mut q0 = NONE;
            for i in 0..nl {
                if (self.lav[i] & bit) == 0 {
                    q0 = self.lblk[i];
                    break;
                }
            }
            if q0 == NONE || (self.thru[q0 as usize] & bit) == 0 {
                continue;
            }
            let mut s = self.rhead[r as usize];
            for _ in 0..EVICT_SCAN {
                if s == NONE || self.holds_at(s, q0) {
                    break;
                }
                s = self.rnext[s as usize];
            }
            if s == NONE || !self.holds_at(s, q0) {
                continue;
            }
            let z = self.seg_x[s as usize];
            if (want[z as usize] & WANT_WHOLE) != 0 || z >= nv || z >= ni && agg_param(b, VPARAM | z - ni) {
                continue;
            }
            // The holder's reading blocks and its own: `egen`; the blocks it leaves: `egen + 1`.
            self.egen += 2;
            let g = self.egen;
            for u in self.su_at[z as usize]..self.su_at[z as usize + 1] {
                self.emark[self.su[u as usize] as usize] = g;
            }
            self.emark[self.pos[self.def_blk[z as usize] as usize] as usize] = g;
            self.ev.truncate(0);
            let mut ok = true;
            for i in 0..nl {
                if (self.lav[i] & bit) != 0 {
                    continue;
                }
                let q = self.lblk[i];
                // Not a block whose terminator writes the register (a parameter the holder is passed to).
                if (self.thru[q as usize] & bit) == 0 || self.emark[q as usize] == g || !self.holds_at(s, q) || (self.part[2 * self.base[q as usize + 1] as usize - 1] & bit) != 0 {
                    ok = false;
                    break;
                }
                self.ev.push(q);
            }
            if !ok {
                continue;
            }
            for j in 0..self.ev.len() {
                let q = self.ev[j] as usize;
                self.thru[q] &= ~bit;
                self.bmask[q] &= ~bit;
                self.emark[q] = g + 1;
            }
            // `x` may hold the register there, the holder out; the holder's loads and its store.
            let mut cost = ast::pick(self.seg_mem[z as usize], 0u64, self.freq[self.def_blk[z as usize] as usize]);
            for j in 0..self.ev.len() {
                let q = self.ev[j];
                let i = self.lix[q as usize] as usize;
                ok = ok && (self.room(
                    b,
                    want[x as usize],
                    caps,
                    sets,
                    x,
                    q,
                    dp,
                    self.llo[i],
                    self.lhi[i],
                    st,
                    own,
                    pinm,
                    keep,
                    false,
                ) & bit) != 0;
                let k = self.order[q as usize];
                let t = term(b, k);
                for e in 0..edge_count(t) {
                    let tk = b.edge_target(edge_of(b, t, e));
                    let tp = self.pos[tk as usize];
                    if tp != NONE && self.emark[tp as usize] != g + 1 && self.holds_at(s, tp) {
                        // A late edge's stub loads nothing (`spans`).
                        ok = ok && self.late_target(b, k) != tk;
                        cost += self.freq[k as usize].min(self.freq[tk as usize]) * ast::pick(
                            edge_count(t) > 1,
                            EDGE_BLOCK,
                            1u64,
                        );
                    }
                }
            }
            for j in 0..self.ev.len() {
                self.thru[self.ev[j] as usize] |= bit;
                self.bmask[self.ev[j] as usize] |= bit;
            }
            if ok && bare > cost && bare - cost > best_net {
                best = r;
                best_s = s;
                best_net = bare - cost;
                let k = replace(&mut self.evb, Vector::<u32>::new());
                self.evb = replace(&mut self.ev, k);
            }
        }
        if best == REG_NONE {
            return REG_NONE;
        }
        let bit = 1u64 << best as u64;
        for j in 0..self.evb.len() {
            let q = self.evb[j];
            self.thru[q as usize] &= ~bit;
            self.bmask[q as usize] &= ~bit;
            self.gpool[(self.seg_at[best_s as usize] + q - self.seg_a[best_s as usize]) as usize] = false;
        }
        self.seg_mem[self.seg_x[best_s as usize] as usize] = true;
        return best;
    }

    // Whether segment `s` holds its value in the block at layout position `q`.
    const fn holds_at(self: &Self, s: u32, q: u32) bool {
        return self.seg_a[s as usize] <= q && q <= self.seg_b[s as usize] && self.gpool[(self.seg_at[s as usize] + q - self.seg_a[s as usize]) as usize];
    }

    fn spans(self: &mut Self, b: &Body, dp: u32, st: u32, r: u8, fresh: bool) u64 {
        let nl = self.lblk.len();
        let bit = 1u64 << r as u64;
        fill(&mut self.lcomp, nl, 0);
        fill(&mut self.lgain, nl, 0);
        fill(&mut self.lcost, nl, 0);
        fill(&mut self.lbad, nl, false);
        fill(&mut self.lkeep, nl, false);
        for i in 0..nl {
            self.lcomp[i] = i as u32;
        }
        for i in 0..nl {
            if (self.lav[i] & bit) == 0 {
                continue;
            }
            let t = term(b, self.order[self.lblk[i] as usize]);
            for e in 0..edge_count(t) {
                let sp = self.pos[b.edge_target(edge_of(b, t, e)) as usize];
                if sp == NONE || sp == dp || self.lin[sp as usize] != st || (self.lav[self.lix[sp as usize] as usize] & bit) == 0 {
                    continue;
                }
                let ra = self.group(i as u32);
                let rb = self.group(self.lix[sp as usize]);
                if ra != rb {
                    self.lcomp[ra as usize] = rb;
                }
            }
        }
        for i in 0..nl {
            if (self.lav[i] & bit) == 0 {
                continue;
            }
            let g = self.group(i as u32) as usize;
            let q = self.lblk[i];
            let k = self.order[q as usize];
            self.lgain[g] += self.lnow[i];
            if q == dp {
                continue;
            }
            for j in self.pat[k as usize]..self.pat[k as usize + 1] {
                let p = self.preds[j as usize];
                let pp = self.pos[p as usize];
                if pp == NONE || (pp == dp || self.lin[pp as usize] == st) && (self.lav[self.lix[pp as usize] as usize] & bit) != 0 {
                    continue;
                }
                if self.late_target(b, p) == k {
                    self.lbad[g] = true;
                } else {
                    // The edge loads the value; one of several edges does it in a block of its own, which
                    // jumps on (`EDGE_BLOCK`).
                    self.lcost[g] += self.edge_freq(b, p, k) * ast::pick(edge_count(term(b, p)) > 1, EDGE_BLOCK, 1u64);
                }
            }
        }
        let mut total: u64 = 0;
        for i in 0..nl {
            if (self.lav[i] & bit) == 0 {
                continue;
            }
            let g = self.group(i as u32) as usize;
            if self.lbad[g] || self.lgain[g] <= self.lcost[g] {
                continue;
            }
            self.lkeep[i] = true;
            if g == i {
                total += self.lgain[g] - self.lcost[g];
            }
        }
        if fresh {
            total = total - total.min(self.save);
        }
        return total;
    }

    // The group of `spans` that entry `i` of `lblk` is in (`lcomp`), the paths made shorter: each step goes
    // one entry up.
    const fn group(self: &mut Self, i: u32) u32 {
        let mut j = i;
        while self.lcomp[j as usize] != j {
            let up = self.lcomp[j as usize];
            self.lcomp[j as usize] = self.lcomp[up as usize];
            j = self.lcomp[j as usize];
        }
        return j;
    }

    // Value `x` holds register `r` through the blocks of `lblk` that `lbest` keeps: one more segment of
    // it (`seg_*`, `gpool`, `vseg`, `vnext`), and the positions the register is its own (`thru`, `part`,
    // `bmask`; a parameter's too at the end of each block that enters its own).
    fn seg_put(self: &mut Self, b: &Body, x: usize, dp: u32, r: u8) {
        let ni = b.insts.len();
        let nl = self.lblk.len();
        let bit = 1u64 << r as u64;
        let mut a = NONE;
        let mut bb: u32 = 0;
        self.sgen += 1;
        let st = self.sgen;
        for i in 0..nl {
            if !self.lbest[i] {
                continue;
            }
            let q = self.lblk[i];
            self.lsel[q as usize] = st;
            if a == NONE {
                a = q;
            }
            bb = q;
            if self.llo[i] == 2 * self.base[q as usize] && self.lhi[i] == 2 * self.base[q as usize + 1] - 1 {
                self.thru[q as usize] |= bit;
            } else {
                for hp in self.llo[i]..self.lhi[i] + 1 {
                    self.part[hp as usize] |= bit;
                }
            }
            self.bmask[q as usize] |= bit;
        }
        if a == NONE {
            return;
        }
        self.vnext.push(self.vseg[x]);
        self.vseg[x] = self.seg_x.len() as u32;
        self.rnext.push(self.rhead[r as usize]);
        self.rhead[r as usize] = self.seg_x.len() as u32;
        self.seg_x.push(x as u32);
        self.seg_a.push(a);
        self.seg_b.push(bb);
        self.seg_r.push(r);
        self.seg_at.push(self.gpool.len() as u32);
        for q in a..bb + 1 {
            self.gpool.push(self.lsel[q as usize] == st);
        }
        self.segd[x] = true;
        if x < ni || x >= ni + b.params.len() || self.lsel[dp as usize] != st {
            return;
        }
        let k = self.order[dp as usize];
        for i in self.pat[k as usize]..self.pat[k as usize + 1] {
            let pp = self.pos[self.preds[i as usize] as usize];
            if pp != NONE {
                self.part[2 * self.base[pp as usize + 1] as usize - 1] |= bit;
                self.bmask[pp as usize] |= bit;
            }
        }
    }
}

/// Whether vector operation `t` (`O_VOP`) is a reduction, which computes in place over temporaries
/// (no call).
pub(package) const fn reduces(t: Inst) bool {
    let code = (t.aux & VOP_CODE) as u32;
    return code >= core::OP_SIMD && code < core::OP_CMP_LANES && core::simd_op((code - core::OP_SIMD) as u8).rule == core::SR_REDUCE;
}
/// Whether instruction `t` of `b` uses an address of slot `s` (an operand, an argument or an edge's argument);
/// `us` is scratch.
pub(package) fn reads_slot(b: &Body, t: Inst, s: u32, us: &mut Vector<Value>) bool {
    each_use(b, t, us);
    for q in 0..us.len() {
        let v = us[q];
        if v != VNONE && (v & (VPARAM | VFLAG)) == 0 && b.insts[v as usize].op == O_SLOTADDR && b.insts[v as usize].a == s {
            return true;
        }
    }
    return false;
}

// `reads_before` follows at most BACK_SCAN blocks.
const BACK_SCAN: u32 = 32;

// `Live.sole`: two or more instructions read the parameter.
const READERS: u32 = 0xFFFFFFFE;

/// `op_flags` bits: the body holds an `O_RETADDR`, an `O_VASTART`, an `O_ASM`, an `O_SYS`.
pub(package) const OP_RETADDR: u8 = 1;
pub(package) const OP_VASTART: u8 = 2;
pub(package) const OP_ASM: u8 = 4;
pub(package) const OP_SYS: u8 = 8;

/// Which of the operations `OP_*` names body `b` holds.
pub(package) const fn op_flags(b: &Body) u8 {
    let mut f: u8 = 0;
    for i in 0..b.insts.len() {
        let op = b.insts[i].op;
        if op == O_RETADDR {
            f |= OP_RETADDR;
        } else if op == O_VASTART {
            f |= OP_VASTART;
        } else if op == O_ASM {
            f |= OP_ASM;
        } else if op == O_SYS {
            f |= OP_SYS;
        }
    }
    return f;
}

/// The values instruction `t` of `b` uses into `out`, each use once: its operands, a call's arguments, a
/// vector operation's operands and each edge's arguments.
pub(package) fn each_use(b: &Body, t: Inst, out: &mut Vector<Value>) {
    lv::uses_edges(b, t, out);
    if t.op == O_RET && (b.pool[b.sig as usize + 2] & AGG) != 0 {
        // The return reads the aggregate result's memory, the parameter after the declared ones.
        out.push(VPARAM | b.blocks[0].param_start + b.pool[b.sig as usize]);
    }
}

/// `edge_count` of a jump or a branch `t`, 0 for a switch.
const fn jb_edges(t: Inst) u32 {
    return if t.op == O_SWITCH {
        0
    } else {
        edge_count(t)
    };
}

/// The value indexes of the parameters terminator `t` of `b` writes, one per edge into them, into `out`.
pub(package) fn each_edge_param(b: &Body, t: Inst, out: &mut Vector<u32>) {
    out.truncate(0);
    let ni = b.insts.len() as u32;
    b.succ_edges(t, out);
    let ne = out.len();
    for e in 0..ne {
        let sb = b.blocks[b.edge_target(out[e]) as usize];
        for q in 0..sb.param_len as u32 {
            out.push(ni + sb.param_start + q);
        }
    }
    // The parameters move to the front over the edges.
    let np = out.len() - ne;
    for i in 0..np {
        out[i] = out[ne + i];
    }
    out.truncate(np);
}

// Whether a path from block `from` reads value `v` before it reaches block `stop`: an instruction or an
// edge argument of a block on it; true too past BACK_SCAN blocks. A block laid out past `last` (`pos`),
// the end of `v`'s range, has `v` dead: no such path passes it.
fn reads_before(lv: &Live, b: &Body, from: u32, stop: u32, v: Value, pos: &Vector<u32>, last: u32) bool {
    let mut seen = Vector::<u32>::new();
    let mut work = Vector::<u32>::new();
    let mut us = Vector::<Value>::new();
    let mut es = Vector::<u32>::new();
    work.push(from);
    // Each step visits one block, at most BACK_SCAN.
    while let Some(k) = work.pop() {
        if k == stop || pos[k as usize] == NONE || pos[k as usize] > last || contains_u32(&seen, k) {
            continue;
        }
        if seen.len() as u32 >= BACK_SCAN {
            return true;
        }
        seen.push(k);
        let bk = b.blocks[k as usize];
        for i in bk.start..bk.start + bk.len {
            let t = b.insts[i as usize];
            each_use(b, t, &mut us);
            for u in 0..us.len() {
                if lv.seen(us[u]) == v {
                    return true;
                }
            }
            if is_terminator(t.op) {
                b.succ_edges(t, &mut es);
                for x in 0..es.len() {
                    for q in 0..b.edge_nargs(es[x]) {
                        if lv.arg(b, es[x], q) == v {
                            return true;
                        }
                    }
                    work.push(b.edge_target(es[x]));
                }
            }
        }
    }
    return false;
}

// The root of `k0`'s set in union-find forest `root`, its path halved.
const fn find_root(root: &mut Vector<u32>, k0: u32) u32 {
    let mut k = k0;
    // Each step moves `k` closer to the root: at most `root.len()` steps.
    while root[k as usize] != k {
        root[k as usize] = root[root[k as usize] as usize];
        k = root[k as usize];
    }
    return k;
}

const fn contains_u32(xs: &Vector<u32>, x: u32) bool {
    for k in 0..xs.len() {
        if xs[k] == x {
            return true;
        }
    }
    return false;
}

/// Edge `k` of terminator `t` (`jmp`: 0; `br`: 0 taken, 1 not; `switch`: its cases, then the default).
/// Whether a value of `b` (an instruction or a block parameter) is a vector.
pub(package) const fn has_vectors(b: &Body) bool {
    for i in 0..b.insts.len() {
        if is_vec(b.insts[i].ty) {
            return true;
        }
    }
    for q in 0..b.params.len() {
        if is_vec(b.params[q]) {
            return true;
        }
    }
    return false;
}

/// A rotation (`rotate_of`): value `x` by amount `amt` (VNONE for constant `k`, rotating left), to the
/// right when `right`; `x` VNONE for none. `src` is the shift's own amount operand, `amt` maybe past an
/// extension of it (`rot_amount`). A funnel shift when `y`, the value shifted right, is not `x`: `x << k |
/// y >> (w - k)`, by a constant.
pub(package) struct Rotation {
    pub(package) x: Value,
    pub(package) y: Value,
    pub(package) amt: Value,
    pub(package) src: Value,
    pub(package) k: u32,
    pub(package) right: bool,
}

extend Rotation as Copy {}

/// The rotation `or`, `xor` or `add` `i` of `b` computes: of a shift left and a logical shift right of one
/// value, by constants `k` and `w - k` (0 < k < w, the width), or by `s` and `w - s`, or, for an `or`, by
/// `s` and `(c - s) & (w - 1)` (c a multiple of w) or `-s & (w - 1)`, `s` the amount or the value it masks
/// with `w - 1`, each amount maybe through a zero extension or a truncation (`amount_of`: an amount of
/// another type). A shift past the width is undefined, so `s` is below it: by `w - s`, `s` is not 0 and the
/// shifts' bits are disjoint, so their sum and their `xor` are their `or`; a masked `s` of 0 shifts both
/// by 0, which only the `or` of the value with itself rotates. The amount rotates right when it is the
/// shift right's. Of two values of 32 or 64 bits by constants, a funnel shift.
pub(package) const fn rotate_of(b: &Body, i: u32) Rotation {
    let none = Rotation { x: VNONE, y: VNONE, amt: VNONE, src: VNONE, k: 0, right: false };
    let t = b.insts[i as usize];
    if t.op != O_OR && t.op != O_XOR && t.op != O_ADD || !is_int(t.ty) || t.ty == T_I128 || !is_inst(t.a) || !is_inst(
        t.b,
    ) {
        return none;
    }
    let bits = type_bits(t.ty, 8) as u64;
    let p = b.insts[t.a as usize];
    let q = b.insts[t.b as usize];
    let (l, r) = if p.op == O_SHL && q.op == O_LSHR {
        (p, q)
    } else if p.op == O_LSHR && q.op == O_SHL {
        (q, p)
    } else {
        return none;
    };
    if l.ty != t.ty || r.ty != t.ty || l.a != r.a && bits < 32 {
        return none;
    }
    let kl = int_const(b, l.b);
    let kr = int_const(b, r.b);
    let al = amount_of(b, l.b);
    let ar = amount_of(b, r.b);
    if kl != u64::MAX && kr != u64::MAX {
        if kl > 0 && kl < bits && kl + kr == bits {
            return Rotation { x: l.a, y: r.a, amt: VNONE, src: VNONE, k: kl as u32, right: false };
        }
        return none;
    }
    if l.a != r.a {
        return none;
    }
    let or = t.op == O_OR;
    if negated(b, ar, al, bits, or) {
        return Rotation { x: l.a, y: l.a, amt: al, src: l.b, k: 0, right: false };
    }
    if negated(b, al, ar, bits, or) {
        return Rotation { x: l.a, y: l.a, amt: ar, src: r.b, k: 0, right: true };
    }
    return none;
}

/// What `v` is as a `select`'s side next to side `other` (CS_*): `other + 1`, `-other`, `~other` (an
/// integer of up to 64 bits), which a conditional instruction computes from `other`; else CS_NONE.
/// A field insertion `bfi_of` reads: `keep` (`x & ~(m << s)`), `field` (`(v & m) << s`), `m` the `w` low
/// bits.
pub(package) struct Bfi {
    pub(package) x: Value,
    pub(package) v: Value,
    pub(package) keep: Value,
    pub(package) field: Value,
    pub(package) trunc: Value, // the truncation the kept side extends, else VNONE
    pub(package) s: u32,
    pub(package) w: u32,
}

/// Instruction `t` of `b` as an insertion of `v`'s low `w` bits into `x` at bit `s`: an `or` of 32 or 64
/// bits of `x & ~(m << s)` (or the extension of `x` truncated to the bits below the field when it reaches
/// the top) and `(v & m) << s` (or `v` extended from `w` bits, shifted), `m` the `w` low bits, the field
/// within the width; `x` VNONE when it is not one.
pub(package) const fn bfi_of(b: &Body, t: Inst) Bfi {
    let none = Bfi { x: VNONE, v: VNONE, keep: VNONE, field: VNONE, trunc: VNONE, s: 0, w: 0 };
    let bits = type_bits(t.ty, 8);
    if t.op != O_OR || !is_int(t.ty) || bits != 32 && bits != 64 || !is_inst(t.a) || !is_inst(t.b) {
        return none;
    }
    let all = ast::pick(bits == 64, u64::MAX, 0xFFFFFFFFu64);
    for side in 0..2 {
        let (ka, kb) = if side == 0 {
            (t.a, t.b)
        } else {
            (t.b, t.a)
        };
        let a = b.insts[ka as usize];
        let sh = b.insts[kb as usize];
        if a.op != O_AND && a.op != O_ZEXT || sh.op != O_SHL || !is_inst(sh.a) {
            continue;
        }
        let f = b.insts[sh.a as usize];
        let s = int_const(b, sh.b);
        let m = if f.op == O_AND {
            int_const(b, f.b)
        } else if f.op == O_ZEXT && type_bits(b.type_of(f.a), 8) < 64 {
            (1u64 << type_bits(b.type_of(f.a), 8) as u64) - 1
        } else {
            u64::MAX
        };
        // The kept bits: an `and`'s mask, or those below a truncation's width.
        let (x, k, tr) = if a.op == O_AND {
            (a.a, int_const(b, a.b), VNONE)
        } else if is_inst(a.a) && b.insts[a.a as usize].op == O_TRUNC && type_bits(b.type_of(a.a), 8) < 64 {
            let n = b.insts[a.a as usize];
            (n.a, (1u64 << type_bits(n.ty, 8) as u64) - 1, a.a)
        } else {
            (VNONE, u64::MAX, VNONE)
        };
        if s == u64::MAX || m == u64::MAX || k == u64::MAX || m == 0 || (m & m + 1) != 0 || s >= bits as u64 || type_bits(
            b.type_of(x),
            8,
        ) != bits {
            continue;
        }
        let w = (m + 1).trailing_zeros() as u64;
        if s + w <= bits as u64 && (k & all) == (~(m << s) & all) {
            return Bfi { x: x, v: f.a, keep: ka, field: kb, trunc: tr, s: s as u32, w: w as u32 };
        }
    }
    return none;
}

/// The value instruction `v` of `b` inverts (`not v`, or `xor v` with all ones of its width); VNONE when it
/// is no inversion.
pub(package) const fn inversion(b: &Body, v: Value) Value {
    if !is_inst(v) {
        return VNONE;
    }
    let t = b.insts[v as usize];
    if t.op == O_NOT {
        return t.a;
    }
    let m = if type_bits(t.ty, 8) >= 64 {
        u64::MAX
    } else {
        (1u64 << type_bits(t.ty, 8) as u64) - 1
    };
    return ast::pick(
        t.op == O_XOR && is_int(t.ty) && t.ty != T_I128 && is_const_val(b, t.b) && (const_val(b, t.b) & m) == m,
        t.a,
        VNONE,
    );
}

/// The operand of `and`, `or` or `xor` `t` of `b` that is a folded inversion (`FOLD_NOT`, `folded`); VNONE
/// when none.
pub(package) const fn not_side(b: &Body, folded: &Vector<bool>, t: Inst) Value {
    if t.op != O_AND && t.op != O_OR && t.op != O_XOR {
        return VNONE;
    }
    if is_inst(t.b) && folded[t.b as usize] && inversion(b, t.b) != VNONE {
        return t.b;
    }
    return ast::pick(is_inst(t.a) && folded[t.a as usize] && inversion(b, t.a) != VNONE, t.a, VNONE);
}

/// The BMI1 form of `and` or `xor` `t` of `b` (`FOLD_BLS`): the kind (`x64::BLSR` for `x & (x - 1)`,
/// `x64::BLSMSK` for `x ^ (x - 1)`, `x64::BLSI` for `x & -x`, 0 for none), the operand that is `x - 1` or
/// `-x`, and `x`, an integer of at most 64 bits that is no folded instruction.
pub(package) const fn bls_parts(b: &Body, t: Inst) (u8, Value, Value) {
    if t.op != O_AND && t.op != O_XOR || !is_int(t.ty) || t.ty == T_I128 {
        return (0, VNONE, VNONE);
    }
    let m = if type_bits(t.ty, 8) >= 64 {
        u64::MAX
    } else {
        (1u64 << type_bits(t.ty, 8) as u64) - 1
    };
    for side in 0..2 {
        let (s, x) = if side == 0 {
            (t.b, t.a)
        } else {
            (t.a, t.b)
        };
        if !is_inst(s) {
            continue;
        }
        let d = b.insts[s as usize];
        if d.ty != t.ty {
            continue;
        }
        // `x - 1` as `x + -1` or `x - 1`; `-x` as `neg x` or `0 - x`.
        let dec = d.a == x && (d.op == O_ADD && is_const_val(b, d.b) && (const_val(b, d.b) & m) == m || d.op == O_SUB && is_const_val(
            b,
            d.b,
        ) && (const_val(b, d.b) & m) == 1);
        let neg = d.op == O_NEG && d.a == x || d.op == O_SUB && d.b == x && is_const_val(b, d.a) && (const_val(b, d.a) & m) == 0;
        if dec {
            return (ast::pick(t.op == O_AND, 1u8, 2u8), s, x);
        }
        if neg && t.op == O_AND {
            return (3, s, x);
        }
    }
    return (0, VNONE, VNONE);
}

/// The load store `t` of `b` reads, modifies and writes back (`FOLD_RMW`): its value an integer `add`, `sub`,
/// `and`, `or` or `xor`, not folded, of a load (its first operand for a `sub`) of the store's address and
/// offset, of the operation's type, neither volatile nor bounded, nor folded; the other operand no folded
/// value. VNONE when not.
pub(package) const fn rmw_load(b: &Body, folded: &Vector<bool>, t: Inst) Value {
    let v = t.b;
    if !is_inst(v) {
        return VNONE;
    }
    let o = b.insts[v as usize];
    let alu = o.op == O_ADD || o.op == O_SUB || o.op == O_AND || o.op == O_OR || o.op == O_XOR;
    if !alu || !is_int(o.ty) || o.ty == T_I128 || o.ty == T_PTR {
        return VNONE;
    }
    for q in 0..2u32 {
        let (l, other) = if q == 0 {
            (o.a, o.b)
        } else {
            (o.b, o.a)
        };
        if q == 1 && o.op == O_SUB || !is_inst(l) || l == other || is_inst(other) && folded[other as usize] && !folded[v as usize] {
            continue;
        }
        let x = b.insts[l as usize];
        if x.op == O_LOAD && x.a == t.a && x.c == t.c && x.ty == o.ty && (x.aux & (MEM_VOLATILE | MEM_RANGE)) == 0 && folded[l as usize] == folded[v as usize] {
            return l;
        }
    }
    return VNONE;
}

// Whether instruction `t` may write memory: a store, a call, a block copy or fill, an atomic operation,
// inline assembly, a system call or a variadic access.
const fn writes_mem(t: Inst) bool {
    let op = t.op;
    return op == O_STORE || op == O_CALL || op == O_CALLIND || op == O_MEMCPY || op == O_MEMSET || op >= O_ALOAD && op <= O_FENCE || op == O_ASM || op == O_SYS || op == O_VASTART || op == O_VAARG;
}

// Whether value `v` of `b` is an entry parameter of aggregate type (a pointer to its bytes), or the
// pointer to an aggregate result (the parameter after the signature's).
// Whether load `i` of `b` reads the aggregate result of the call right before it, past loads of that result
// alone, of at most `regs` bytes (`Live::ret_regs`): the generator may take the value from the result's
// register (`place::result_loads`). At most LDOP_REACH steps back.
const fn result_load(b: &Body, i: u32, regs: u32) bool {
    let a = b.insts[i as usize].a;
    let mut k = i;
    while k > 0 && k + LDOP_REACH > i {
        k -= 1;
        let t = b.insts[k as usize];
        if t.op == O_CALL || t.op == O_CALLIND {
            let rt = b.pool[t.b as usize + 2];
            return (rt & AGG) != 0 && b.pool[(rt & ~AGG) as usize] <= regs && b.pool[(t.c + b.pool[t.b as usize]) as usize] == a;
        }
        if t.op != O_LOAD || t.a != a {
            return false;
        }
    }
    return false;
}

const fn agg_param(b: &Body, v: Value) bool {
    if (v & VPARAM) == 0 || v == VNONE || b.sig == NONE {
        return false;
    }
    let e = b.blocks[0];
    let q = (v & ~VPARAM) - e.param_start;
    let np = b.pool[b.sig as usize];
    if (v & ~VPARAM) < e.param_start || q >= e.param_len as u32 {
        return false;
    }
    return q < np && (b.pool[(b.sig + 3 + q) as usize] & AGG) != 0 || q == np && (b.pool[b.sig as usize + 2] & AGG) != 0;
}

/// The side of select `i` of `b` that `FOLD_CARRY` folds (the other side plus 1), when `i` is of 32 or 64
/// bits on a folded (`folded`) integer comparison of at most 64 bits; VNONE else.
pub(package) const fn carry_inc(b: &Body, folded: &Vector<bool>, i: u32) Value {
    let t = b.insts[i as usize];
    if t.op != O_SELECT || !is_int(t.ty) || type_bits(t.ty, 8) < 32 || t.ty == T_I128 || !is_inst(t.a) || !folded[t.a as usize] {
        return VNONE;
    }
    let c = b.insts[t.a as usize];
    if c.op != O_ICMP || type_bits(b.type_of(c.a), 8) > 64 {
        return VNONE;
    }
    if is_inst(t.b) && !folded[t.b as usize] && cs_kind(b, t.b, t.c) == CS_INC {
        return t.b;
    }
    return ast::pick(is_inst(t.c) && !folded[t.c as usize] && cs_kind(b, t.c, t.b) == CS_INC, t.c, VNONE);
}

pub(package) const fn cs_kind(b: &Body, v: Value, other: Value) u8 {
    if other == VNONE {
        return CS_NONE;
    }
    if neg_sub(b, v, other) {
        return CS_NEG;
    }
    let (k, x) = cs_base(b, v);
    return ast::pick(x == other, k, CS_NONE);
}

/// Whether `v` is a load of an integer of 8, 16 or 32 bits.
const fn narrow_load(b: &Body, v: Value) bool {
    if !is_inst(v) {
        return false;
    }
    let t = b.insts[v as usize];
    return t.op == O_LOAD && (t.ty == T_I8 || t.ty == T_I16 || t.ty == T_I32);
}

/// Whether `v` is `y - x` and `other` is `x - y`, of one integer type: `v` negates `other`.
pub(package) const fn neg_sub(b: &Body, v: Value, other: Value) bool {
    if !is_inst(v) || !is_inst(other) {
        return false;
    }
    let s = b.insts[v as usize];
    let o = b.insts[other as usize];
    return s.op == O_SUB && o.op == O_SUB && s.ty == o.ty && is_int(s.ty) && s.ty != T_I128 && s.a == o.b && s.b == o.a;
}

/// `cs_kind` of `v` with the value it adds 1 to, negates or inverts: that kind and value, else
/// (CS_NONE, VNONE).
pub(package) const fn cs_base(b: &Body, v: Value) (u8, Value) {
    if !is_inst(v) {
        return (CS_NONE, VNONE);
    }
    let t = b.insts[v as usize];
    let ops = t.op == O_ADD || t.op == O_SUB || t.op == O_NEG || t.op == O_NOT || t.op == O_XOR;
    if !ops || !is_int(t.ty) || t.ty == T_I128 {
        return (CS_NONE, VNONE);
    }
    let m = if type_bits(t.ty, 8) >= 64 {
        u64::MAX
    } else {
        (1u64 << type_bits(t.ty, 8) as u64) - 1
    };
    let un = t.op == O_NEG || t.op == O_NOT;
    let ka = const_val(b, t.a) & m;
    let kb = if un {
        0
    } else {
        const_val(b, t.b) & m
    };
    let ca = is_const_val(b, t.a);
    let cb = !un && is_const_val(b, t.b);
    if t.op == O_ADD && cb && kb == 1 || t.op == O_SUB && cb && kb == m {
        return (CS_INC, t.a);
    }
    if t.op == O_ADD && ca && ka == 1 {
        return (CS_INC, t.b);
    }
    if t.op == O_NEG {
        return (CS_NEG, t.a);
    }
    if t.op == O_SUB && ca && ka == 0 && !cb {
        return (CS_NEG, t.b);
    }
    if t.op == O_NOT || t.op == O_XOR && cb && kb == m {
        return (CS_NOT, t.a);
    }
    if t.op == O_XOR && ca && ka == m {
        return (CS_NOT, t.b);
    }
    return (CS_NONE, VNONE);
}

// Whether `v` is an integer constant, and its bits.
const fn is_const_val(b: &Body, v: Value) bool {
    return is_inst(v) && b.insts[v as usize].op == O_ICONST;
}

const fn const_val(b: &Body, v: Value) u64 {
    if !is_const_val(b, v) {
        return 0;
    }
    let t = b.insts[v as usize];
    return t.a as u64 | t.b as u64 << 32;
}

/// The operand of 32- or 64-bit sum, difference or bitwise operation `t` that is a folded shift by a
/// constant (`FOLD_SHOP`): `t.b`, else `t.a`; VNONE when neither is.
pub(package) const fn shop_side(b: &Body, pfold: &Vector<bool>, t: Inst) Value {
    let ops = t.op == O_ADD || t.op == O_SUB || t.op == O_AND || t.op == O_OR || t.op == O_XOR;
    if !ops || !is_int(t.ty) || t.ty == T_I128 {
        return VNONE;
    }
    if is_inst(t.b) && pfold[t.b as usize] && b.insts[t.b as usize].op >= O_SHL && b.insts[t.b as usize].op <= O_ASHR {
        return t.b;
    }
    return ast::pick(
        is_inst(t.a) && pfold[t.a as usize] && b.insts[t.a as usize].op >= O_SHL && b.insts[t.a as usize].op <= O_ASHR,
        t.a,
        VNONE,
    );
}

/// The extension (`O_ZEXT`, `O_SEXT`) both operands of 64-bit product `t` are, from 32 bits, two
/// instructions, or its first operand is with the second a constant the extension of its low 32 bits; 0
/// when not.
pub(package) const fn mull_ext(b: &Body, t: Inst) u8 {
    if !is_inst(t.a) || !is_inst(t.b) || t.a == t.b {
        return 0;
    }
    let x = b.insts[t.a as usize];
    let y = b.insts[t.b as usize];
    if is_const_val(b, t.b) && (x.op == O_ZEXT || x.op == O_SEXT) && b.type_of(x.a) == T_I32 {
        let c = const_val(b, t.b);
        let fits = if x.op == O_ZEXT {
            c >> 32 == 0
        } else {
            c as i64 >= -2147483648 && c as i64 < 2147483648
        };
        return ast::pick(fits, x.op, 0u8);
    }
    return ast::pick(
        x.op != y.op || x.op != O_ZEXT && x.op != O_SEXT || b.type_of(x.a) != T_I32 || b.type_of(y.a) != T_I32,
        0,
        x.op,
    );
}

/// The value a left shift with operand `v` shifts: the narrow value when `v` is a zero extension folded
/// into it (`FOLD_ZSHL`), else `v`.
pub(package) const fn shl_source(b: &Body, pfold: &Vector<bool>, v: Value) Value {
    if !is_inst(v) || !pfold[v as usize] || b.insts[v as usize].op != O_ZEXT {
        return v;
    }
    return b.insts[v as usize].a;
}

/// Whether every code generator emits instruction `t` reading its first operand before it writes its result,
/// so that a loop step takes its header parameter's register (`Live::step_partner`): an integer operation
/// but a division, a float `+ - * /`, and on vectors `+ - & | ^` and the float ones.
pub(package) const fn step_op(t: Inst) bool {
    let o = t.op;
    let lanes = o == O_ADD || o == O_SUB || o == O_AND || o == O_OR || o == O_XOR || o >= O_FADD && o <= O_FDIV;
    return lanes || !is_vec(t.ty) && (o == O_MUL || o >= O_SHL && o <= O_ASHR);
}

/// Whether the result of instruction `t` may take the register of its first operand, which it reads last
/// (`Live::over`): a `step_op`, or an integer sum or difference with an overflow flag, which the generators
/// emit as one (the flag is set after).
pub(package) const fn over_op(t: Inst) bool {
    return step_op(t) || !is_vec(t.ty) && (t.op == O_ADDO || t.op == O_SUBO);
}

/// `over_op`, a pointer plus a constant (a pointer's step), a widening sum or dot product over its accumulator
/// (`O_VSUMW`, `O_VDOT`, which read their other operands into temporaries first), or a conversion between integers or pointers of
/// at most 64 bits (an extension, a truncation, a cast), which the generators make from their operand's
/// register in one instruction or none.
pub(package) const fn over_inst(b: &Body, t: Inst) bool {
    if over_op(t) || t.op == O_PTRADD && t.b == VNONE || t.op == O_VSUMW || t.op == O_VDOT {
        return true;
    }
    if t.op != O_ZEXT && t.op != O_SEXT && t.op != O_TRUNC && t.op != O_PTRTOINT && t.op != O_INTTOPTR || t.a == VNONE {
        return false;
    }
    let f = b.type_of(t.a);
    return (is_int(t.ty) || t.ty == T_PTR) && (is_int(f) || f == T_PTR) && type_bits(t.ty, 8) <= 64 && type_bits(f, 8) <= 64;
}

/// Whether a generator that reads every operand before it writes (`Live::three`) emits instruction `t` so:
/// an integer or float operation, a comparison, a conversion, a pointer sum, a load, a select,
/// a lanewise vector operation, comparison or select, a splat, a bit count or reversal, a high product, a
/// fused product and sum, a square root, a widening sum, a dot product.
pub(package) const fn three_op(t: Inst) bool {
    let o = t.op;
    let scalar = o >= O_ADD && o <= O_FNEG || o >= O_SEXT && o <= O_INTTOPTR || o == O_PTRADD || o == O_LOAD || o == O_SELECT;
    let bits = o >= O_CLZ && o <= O_POPCNT || o == O_BSWAP || o == O_BITREV || o == O_MULHU || o == O_MULHS;
    return scalar || bits || o == O_VOP || o == O_FMA || o == O_FSQRT || o == O_SPLAT || o == O_VCMP || o == O_VSEL || o == O_VSUMW || o == O_VDOT;
}

/// For select `t` whose condition is a comparison or a flag (0 or 1, which a sum may add), the side that is
/// the other plus 1 (an `add` of it and constant 1): 1 for its true side, 2 for its false side, 0 when
/// neither is.
pub(package) const fn inc_side(b: &Body, t: Inst) u8 {
    let c = t.a;
    if (c & VPARAM) != 0 || (c & VFLAG) == 0 && b.insts[c as usize].op != O_ICMP {
        return 0;
    }
    for q in 0..2u8 {
        let (s, o) = if q == 0 {
            (t.b, t.c)
        } else {
            (t.c, t.b)
        };
        if (s & (VPARAM | VFLAG)) == 0 && s != VNONE && b.insts[s as usize].op == O_ADD && b.insts[s as usize].a == o && int_const(
            b,
            b.insts[s as usize].b,
        ) == 1 {
            return q + 1;
        }
    }
    return 0;
}

/// The amount a shift with amount operand `v` takes: the operand of `v` when `v` is a mask folded into the
/// shift (`FOLD_SHAMT`), past a folded extension or truncation (`FOLD_SHAMT_EXT`); else `v`.
pub(package) const fn shift_amount(b: &Body, pfold: &Vector<bool>, v: Value) Value {
    if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || !pfold[v as usize] || b.insts[v as usize].op != O_AND {
        return v;
    }
    let z = b.insts[v as usize].a;
    if is_inst(z) && pfold[z as usize] {
        return b.insts[z as usize].a;
    }
    return z;
}

/// The value a generator reads rotation `r`'s amount from (`folded`, the folded instructions): the shift's
/// own amount operand, past a folded extension or truncation and a folded mask to the width (the
/// rotation takes the amount modulo the width), whose operands live to the rotation; an unfolded one
/// lives itself.
pub(package) const fn rot_amount(b: &Body, folded: &Vector<bool>, r: Rotation) Value {
    let mut n = r.src;
    for _ in 0..2 {
        if !is_inst(n) || !folded[n as usize] {
            break;
        }
        n = b.insts[n as usize].a;
    }
    return n;
}

/// Shift amount `v` past one zero extension or truncation: the amount computed in another type, which
/// is below the width wherever the shift is defined.
pub(package) const fn amount_of(b: &Body, v: Value) Value {
    if is_inst(v) && (b.insts[v as usize].op == O_ZEXT || b.insts[v as usize].op == O_TRUNC) {
        return b.insts[v as usize].a;
    }
    return v;
}

// Whether shift amount `v` is `w - s` or, when `masks`, `(c - s) & (w - 1)` (c a multiple of width `w`) or
// `-s & (w - 1)`, for the amount `s` (`rotate_of`).
const fn negated(b: &Body, v: Value, s: Value, w: u64, masks: bool) bool {
    if !is_inst(v) {
        return false;
    }
    let mut u = v;
    let masked = masks && b.insts[u as usize].op == O_AND && int_const(b, b.insts[u as usize].b) == w - 1;
    if masked {
        u = b.insts[u as usize].a;
        if !is_inst(u) {
            return false;
        }
    }
    let p = b.insts[u as usize];
    let c = int_const(b, p.a);
    let n = if p.op == O_SUB && c != u64::MAX && (masked && c % w == 0 || c == w) {
        p.b
    } else if p.op == O_NEG && masked {
        p.a
    } else {
        VNONE
    };
    if n == VNONE {
        return false;
    }
    // `s` itself, or the value it masks to the width, either past an extension or a truncation.
    let m = amount_of(b, n);
    return m == s || is_inst(s) && b.insts[s as usize].op == O_AND && int_const(b, b.insts[s as usize].b) == w - 1 && amount_of(
        b,
        b.insts[s as usize].a,
    ) == m;
}

/// The shift a scaled index of an address takes (`lea_of`): 1 to 3 for a shift left by that constant, else
/// 0.
pub(package) const fn lea_shift(b: &Body, v: Value) u32 {
    if !is_inst(v) || b.insts[v as usize].op != O_SHL {
        return 0;
    }
    let k = int_const(b, b.insts[v as usize].b);
    return if k >= 1 && k <= 3 {
        k as u32
    } else {
        0u32
    };
}

/// An address `lea` computes (`lea_of`): `base` + `index` << `sh` + `disp`, either register VNONE; `ok`
/// false for none.
pub(package) struct Lea {
    pub(package) ok: bool,
    pub(package) base: Value,
    pub(package) index: Value,
    pub(package) sh: u32,
    pub(package) disp: i64,
}

extend Lea as Copy {}

/// The address form in which `lea` computes sum `i` of `b` (`FOLD_LEA`; `folded`, the folded
/// instructions): an `add`, an `or` of disjoint bits (`is_sum_or`), or a `sub` of a constant, of up to
/// two registers, one of them shifted left by
/// 1 to 3 when folded (`lea_shift`), and a displacement that 32 signed bits hold, a folded inner `add`'s
/// operands among its own. An index alone takes a shift of at most 1 (`index + index`): no form here
/// lacks a base.
pub(package) fn lea_of(b: &Body, folded: &Vector<bool>, i: u32) Lea {
    let mut f = Lea { ok: true, base: VNONE, index: VNONE, sh: 0, disp: 0 };
    let t = b.insts[i as usize];
    if t.op != O_ADD && t.op != O_SUB && !is_sum_or(b, t) || !is_int(t.ty) || t.ty == T_I128 || t.op == O_SUB && int_const(
        b,
        t.b,
    ) == u64::MAX {
        f.ok = false;
        return f;
    }
    let bits = type_bits(t.ty, 8);
    for q in 0..2u32 {
        let v = ast::pick(q == 0, t.a, t.b);
        let neg = q == 1 && t.op == O_SUB;
        // A folded inner sum's operands in its place.
        if is_inst(v) && folded[v as usize] && b.insts[v as usize].op == O_ADD {
            lea_term(b, folded, b.insts[v as usize].a, false, bits, &mut f);
            lea_term(b, folded, b.insts[v as usize].b, false, bits, &mut f);
        } else {
            lea_term(b, folded, v, neg, bits, &mut f);
        }
    }
    if f.disp < -2147483648 || f.disp > 2147483647 || f.base == VNONE && (f.index == VNONE || f.sh > 1) {
        f.ok = false;
    }
    return f;
}

// Operand `v` (`bits` wide, negated when `neg`) into address `f` (`lea_of`): a constant into the
// displacement, a folded shift as the index, a register as the base, then as the index; `ok` false when
// it takes none (a folded operand has no register).
const fn lea_term(b: &Body, folded: &Vector<bool>, v: Value, neg: bool, bits: u32, f: &mut Lea) {
    let k = int_const(b, v);
    if k != u64::MAX {
        let s = sext_bits(k, bits);
        f.disp = if neg {
            f.disp - s
        } else {
            f.disp + s
        };
        return;
    }
    let fold = is_inst(v) && folded[v as usize];
    if fold && lea_shift(b, v) != 0 && f.index == VNONE {
        f.index = b.insts[v as usize].a;
        f.sh = lea_shift(b, v);
    } else if fold {
        f.ok = false;
    } else if f.base == VNONE {
        f.base = v;
    } else if f.index == VNONE {
        f.index = v;
    } else {
        f.ok = false;
    }
}

/// Whether `t` of `b` is an `or` of two integers no bit of which both may have (`ones_of`): a sum.
pub(package) fn is_sum_or(b: &Body, t: Inst) bool {
    if t.op != O_OR || !is_int(t.ty) || t.ty == T_I128 || t.ty == T_PTR {
        return false;
    }
    let bits = type_bits(t.ty, 8);
    return (ones_of(b, t.a, bits, ONES_DEPTH) & ones_of(b, t.b, bits, ONES_DEPTH)) == 0;
}

// The bits value `v` of `b` (`bits` wide) may have set, through at most `depth` instructions: a
// constant's, an `and`'s with a constant, a shift's by a constant, a zero extension's; else all.
fn ones_of(b: &Body, v: Value, bits: u32, depth: u32) u64 {
    let all = if bits >= 64 {
        u64::MAX
    } else {
        (1u64 << bits as u64) - 1
    };
    let k = int_const(b, v);
    if k != u64::MAX {
        return k & all;
    }
    if !is_inst(v) || depth == 0 {
        return all;
    }
    let t = b.insts[v as usize];
    if t.op != O_AND && t.op != O_SHL && t.op != O_LSHR && t.op != O_ZEXT {
        return all;
    }
    // `b` is a value of these (a call's is a pool index).
    let c = if t.op == O_ZEXT {
        u64::MAX
    } else {
        int_const(b, t.b)
    };
    if t.op == O_AND {
        let m = if c != u64::MAX {
            c
        } else {
            ones_of(b, t.b, bits, depth - 1)
        };
        return ones_of(b, t.a, bits, depth - 1) & m & all;
    }
    if (t.op == O_SHL || t.op == O_LSHR) && c != u64::MAX && c < bits as u64 {
        let x = ones_of(b, t.a, bits, depth - 1);
        return if t.op == O_SHL {
            x << c & all
        } else {
            x >> c
        };
    }
    if t.op == O_ZEXT && is_int(b.type_of(t.a)) && b.type_of(t.a) != T_I128 {
        return ones_of(b, t.a, type_bits(b.type_of(t.a), 8), depth - 1);
    }
    return all;
}

// `ones_of` looks through at most ONES_DEPTH instructions.
const ONES_DEPTH: u32 = 4;

/// How `t` of `b` moves the lanes of a 16-byte vector or a vector of 8 bytes, a `swizzle` of constant
/// indexes of one operand of its type: PERM_REV8 reverses the lanes within each 8 bytes, PERM_SWAP8 swaps
/// the two 8-byte halves, both reverse them all; 0 for another swizzle or another
/// instruction.
pub(package) const fn lane_perm(b: &Body, t: Inst) u8 {
    if t.op != O_VOP || (t.aux & VOP_CODE) as u32 != core::OP_SIMD + core::SIMD_SWIZZLE as u32 || t.b != 1 || t.c == VNONE {
        return 0;
    }
    let n = lanes(t.ty);
    let nb = type_bytes(t.ty, 8);
    let eb = type_bytes(lane_type(t.ty), 8);
    if n < 2 || nb != 8 && nb != 16 || b.type_of(b.pool[t.a as usize]) != t.ty || b.pool[t.c as usize] != n {
        return 0;
    }
    // Lane `k` from `k ^ s`: `s` the lanes of 8 bytes less one within them, of 8 bytes across them.
    let m = 8 / eb;
    let s = b.pool[(t.c + 1) as usize];
    let rev = m > 1 && (s & m - 1) == m - 1;
    let swap = n > m && (s & ~(m - 1)) == n - m;
    let want = rev as u32 * (m - 1) | swap as u32 * (n - m);
    if !rev && !swap || s != want {
        return 0;
    }
    for k in 0..n {
        if b.pool[(t.c + 1 + k) as usize] != (k ^ s) {
            return 0;
        }
    }
    return rev as u8 * PERM_REV8 | swap as u8 * PERM_SWAP8;
}

/// `lane_perm`: the lanes reversed within each 8 bytes.
pub(package) const PERM_REV8: u8 = 1;
/// `lane_perm`: the two 8-byte halves swapped.
pub(package) const PERM_SWAP8: u8 = 2;

/// The bytes `t` of `b` slides by: a `shuffle` of constant indexes `s`, `s + 1`, .. of two operands of its
/// type, a vector of 8, 16 or 32 bytes, which takes the lanes of the two in a row from lane `s` of the first
/// (arm64's EXT, x86-64's PALIGNR); 0 for another shuffle or another instruction.
pub(package) const fn lane_slide(b: &Body, t: Inst) u32 {
    if t.op != O_VOP || (t.aux & VOP_CODE) as u32 != core::OP_SIMD + core::SIMD_SHUFFLE as u32 || t.b != 2 || t.c == VNONE {
        return 0;
    }
    let n = lanes(t.ty);
    let nb = type_bytes(t.ty, 8);
    if n < 2 || nb != 8 && nb != 16 && nb != 32 || b.pool[t.c as usize] != n {
        return 0;
    }
    if b.type_of(b.pool[t.a as usize]) != t.ty || b.type_of(b.pool[(t.a + 1) as usize]) != t.ty {
        return 0;
    }
    let s = b.pool[(t.c + 1) as usize];
    if s == 0 || s >= n {
        return 0;
    }
    for k in 0..n {
        if b.pool[(t.c + 1 + k) as usize] != s + k {
            return 0;
        }
    }
    return s * (nb / n);
}

/// Whether `t` of `b` is a scalar float `fadd` of lanes 0 and 1 (in either order) of one float vector of two
/// lanes (`FOLD_LANE_PAIR`).
pub(package) const fn lane_pair(b: &Body, t: Inst) bool {
    if t.op != O_FADD || is_vec(t.ty) || !is_inst(t.a) || !is_inst(t.b) {
        return false;
    }
    let x = b.insts[t.a as usize];
    let y = b.insts[t.b as usize];
    return x.op == O_VEXTRACT && y.op == O_VEXTRACT && x.a == y.a && x.aux + y.aux == 1 && lanes(b.type_of(x.a)) == 2 && type_bytes(
        t.ty,
        8,
    ) >= 4;
}

/// Whether scalar float operation `t` reads an operand as lane 0 of a vector in the vector's register
/// (`FOLD_LANE0`, folded per `pfold`).
pub(package) const fn lane0_op(b: &Body, pfold: &Vector<bool>, t: Inst) bool {
    if t.op != O_FADD && t.op != O_FSUB && t.op != O_FMUL && t.op != O_FDIV || is_vec(t.ty) {
        return false;
    }
    return is_inst(t.a) && pfold[t.a as usize] && lane0_of(b, t.a) != VNONE || is_inst(t.b) && pfold[t.b as usize] && lane0_of(
        b,
        t.b,
    ) != VNONE;
}

/// The float vector of 8 or 16 bytes whose lane 0 value `v` reads (`vextract`), VNONE when not one.
pub(package) const fn lane0_of(b: &Body, v: Value) Value {
    if !is_inst(v) {
        return VNONE;
    }
    let t = b.insts[v as usize];
    if t.op != O_VEXTRACT || t.aux != 0 || !is_float(t.ty) {
        return VNONE;
    }
    let vb = type_bytes(b.type_of(t.a), 8);
    return ast::pick(vb == 8 || vb == 16, t.a, VNONE);
}

// Value `v` is an instruction's (no parameter, no flag, not VNONE).
const fn is_inst(v: Value) bool {
    return v != VNONE && (v & (VPARAM | VFLAG)) == 0;
}

// The signed value of the low `bits` of `k`.
const fn sext_bits(k: u64, bits: u32) i64 {
    let s = 64 - bits as u64;
    return (k << s) as i64 >> s as i64;
}

// The bits of a value of type `t` a general register holds whole (an integer of up to 64 bits, a pointer of
// 8 bytes), else 0.
const fn word_bits(t: u8) u32 {
    return ast::pick(t == T_PTR || is_int(t) && t != T_I128, type_bits(t, 8), 0u32);
}

// The bits of integer constant `v`, u64::MAX for a value that is no constant (or that constant).
/// The type of value index `x` of `b`: an instruction's, a block parameter's, else i8.
pub(package) const fn xty(b: &Body, x: u32) u8 {
    let ni = b.insts.len() as u32;
    if x < ni {
        return b.insts[x as usize].ty;
    }
    if x < ni + b.params.len() as u32 {
        return b.params[(x - ni) as usize];
    }
    return T_I8;
}

/// Whether symbol `s` of `b` (of package `p`) is a thread-local variable.
pub(package) const fn tls_sym(p: &Package, b: &Body, s: u32) bool {
    return p.syms[b.syms[s as usize] as usize].kind == SK_TLS;
}

/// Whether `v` of `b` (of package `p`) is an instruction value a generator recomputes at each use.
pub(package) const fn remat_inst(p: &Package, b: &Body, v: Value) bool {
    if (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let t = b.insts[v as usize];
    return t.op == O_ICONST || t.op == O_FCONST || t.op == O_SLOTADDR || t.op == O_SYMADDR && !tls_sym(p, b, t.a);
}

// How deep `fits_low` looks through operations.
const FITS_DEPTH: u32 = 4;

// The mask of integer type `t`'s bits: all of a 64-bit one's.
const fn type_mask(t: u8) u64 {
    let n = type_bits(t, 4);
    return if n >= 64 {
        u64::MAX
    } else {
        (1u64 << n as u64) - 1
    };
}

// Whether every value integer `v` of `b` (of up to 32 bits) takes is at most low-bit mask `m`, as a
// constant, a zero extension, an `and`, a right shift, a remainder or quotient by a constant, or a select
// shows it, `depth` instructions deep.
fn fits_low(b: &Body, v: Value, m: u64, depth: u32) bool {
    let ty = b.type_of(v);
    if type_bits(ty, 4) > 32 {
        return false;
    }
    let tm = type_mask(ty);
    if tm <= m {
        return true;
    }
    if (v & (VPARAM | VFLAG)) != 0 || depth == 0 {
        return false;
    }
    let t = b.insts[v as usize];
    if t.op == O_ICONST {
        return (int_const(b, v) & tm) <= m;
    }
    if t.op == O_ZEXT || t.op == O_UDIV && int_const(b, t.b) != u64::MAX {
        return fits_low(b, t.a, m, depth - 1);
    }
    if t.op == O_AND {
        return fits_low(b, t.a, m, depth - 1) || fits_low(b, t.b, m, depth - 1);
    }
    if t.op == O_SELECT {
        return fits_low(b, t.b, m, depth - 1) && fits_low(b, t.c, m, depth - 1);
    }
    if t.op != O_LSHR && t.op != O_UREM {
        return false;
    }
    let k = int_const(b, t.b);
    if t.op == O_LSHR && k < type_bits(ty, 4) as u64 {
        return tm >> k <= m || fits_low(b, t.a, m, depth - 1);
    }
    return t.op == O_UREM && (k & tm) != 0 && ((k & tm) - 1 <= m || fits_low(b, t.a, m, depth - 1));
}

// Whether `side`, a truncation of a 16- or 32-bit integer to 8 or 16 bits, is the side of a select on
// condition `c` that the select takes only where `c` bounds the truncated value within the narrow type
// (true side `on_true`): the side is that value, whatever the truncation clears.
const fn bounded_side(b: &Body, c: Value, side: Value, on_true: bool) bool {
    if ((c | side) & (VPARAM | VFLAG)) != 0 || b.insts[side as usize].op != O_TRUNC || b.insts[c as usize].op != O_ICMP {
        return false;
    }
    let s = b.insts[side as usize];
    let q = b.insts[c as usize];
    let k = int_const(b, q.b);
    let ft = b.type_of(q.a);
    if q.a != s.a || k == u64::MAX || ft != T_I16 && ft != T_I32 {
        return false;
    }
    let m = type_mask(s.ty);
    let kk = k & type_mask(ft);
    // Taken when the value is at most `m`: true below or at, false above.
    if on_true {
        return q.aux == C_ULT && kk <= m + 1 || q.aux == C_ULE && kk <= m;
    }
    return q.aux == C_UGT && kk <= m || q.aux == C_UGE && kk <= m + 1;
}

/// Whether `v` of `b` is an integer constant; its bits in `out`.
pub(package) const fn const_of(b: &Body, v: Value, out: &mut u64) bool {
    if (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let t = b.insts[v as usize];
    if t.op != O_ICONST {
        return false;
    }
    *out = t.b as u64 << 32 | t.a as u64;
    return true;
}

/// The amount every lane of vector shift `t` of `b` (integer lanes) shifts by, when one constant below the
/// lanes' width: a splat of an integer constant, or a wide constant of equal lanes. NONE when not.
pub(package) const fn vec_shift_amount(b: &Body, t: Inst) u32 {
    let lt = lane_type(t.ty);
    if !is_vec(t.ty) || !is_int(lt) || (t.b & (VPARAM | VFLAG)) != 0 || t.b == VNONE {
        return NONE;
    }
    let a = b.insts[t.b as usize];
    let bits = 8 * type_bytes(lt, 8) as u64;
    let m = if bits == 64 {
        ~0u64
    } else {
        (1u64 << bits) - 1
    };
    let mut k: u64 = 0;
    if a.op == O_SPLAT && const_of(b, a.a, &mut k) {
        k &= m;
    } else if a.op == O_WCONST {
        k = b.words[a.a as usize] & m;
        for q in 0..a.b {
            let x = b.words[(a.a + q) as usize];
            for l in 0..64 / bits {
                if (x >> l * bits & m) != k {
                    return NONE;
                }
            }
        }
    } else {
        return NONE;
    }
    return if k < bits {
        k as u32
    } else {
        NONE
    };
}

/// Whether instruction `i` of `b` (of package `p`, liveness `lv`) leads only to its block's `unreachable`:
/// every instruction after it reads values a generator recomputes. `uses` is scratch.
pub(package) fn dead_end(p: &Package, b: &Body, lv: &Live, i: usize, uses: &mut Vector<Value>) bool {
    let bk = b.blocks[lv.def_blk[i] as usize];
    let end = (bk.start + bk.len - 1) as usize;
    if b.insts[end].op != O_UNREACHABLE {
        return false;
    }
    for j in i + 1..end {
        each_use(b, b.insts[j], uses);
        for u in 0..uses.len() {
            if !remat_inst(p, b, uses[u]) {
                return false;
            }
        }
    }
    return true;
}

const fn int_const(b: &Body, v: Value) u64 {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_ICONST {
        return u64::MAX;
    }
    let t = b.insts[v as usize];
    return t.a as u64 | t.b as u64 << 32;
}
