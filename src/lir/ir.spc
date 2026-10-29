// LIR: the machine-level IR every native backend starts from. SSA with block parameters (no phi), machine
// types only, and above the C ABI: an aggregate is memory, and a call carries its signature in C terms for
// the calling convention to place later. A body is dense: 16-byte instructions in one array, blocks as
// ranges of it, operand lists, edges, signatures and layouts in one u32 pool, wide constants and switch
// cases in one u64 pool, and one location index per instruction. A body names no compiler type and holds
// no pointer: its symbols and messages index its package's tables through the body's own `syms` and
// `msgs`, so moving a body between packages rewrites only those two tables.
import ast::ast as ast;
import utils::names as nm;

/// A value: the index of the instruction that defines it, `VFLAG | i` for the overflow flag of checked
/// operation `i` (`O_ADDO`, `O_SUBO`, `O_MULO`: an `i8`, 1 on overflow), or `VPARAM | k` for block
/// parameter `k` of the body (blocks number their parameters in order).
pub(package) type Value = u32;
pub(package) const VNONE: Value = 0xFFFFFFFF;
pub(package) const VPARAM: Value = 0x80000000;
pub(package) const VFLAG: Value = 0x40000000;

// ---- Types ------------------------------------------------------------------------------------------

/// A machine type, one byte. Integers carry no sign: the operation does. A pointer is the data model's
/// width. A vector is `T_VEC | elem << 3 | log2(lanes)`, `elem` an `ELEM_*`, 2 to 64 lanes.
pub(package) const T_NONE: u8 = 0;
pub(package) const T_I8: u8 = 1;
pub(package) const T_I16: u8 = 2;
pub(package) const T_I32: u8 = 3;
pub(package) const T_I64: u8 = 4;
pub(package) const T_I128: u8 = 5;
pub(package) const T_F32: u8 = 6;
pub(package) const T_F64: u8 = 7;
pub(package) const T_PTR: u8 = 8;
pub(package) const T_VEC: u8 = 0x40;
pub(package) const ELEM_I8: u8 = 0;
pub(package) const ELEM_I16: u8 = 1;
pub(package) const ELEM_I32: u8 = 2;
pub(package) const ELEM_I64: u8 = 3;
pub(package) const ELEM_F32: u8 = 4;
pub(package) const ELEM_F64: u8 = 5;

/// The vector of `lanes` (a power of two, 2 to 64) lanes of scalar type `t` (an integer up to 64 bits or
/// a float).
pub(package) const fn vec_type(t: u8, lanes: u32) u8 {
    let e = if t == T_F32 {
        ELEM_F32;
    } else if t == T_F64 {
        ELEM_F64;
    } else {
        t - T_I8;
    };
    return T_VEC | e << 3 | lanes.trailing_zeros() as u8;
}

pub(package) const fn is_vec(t: u8) bool {
    return (t & T_VEC) != 0;
}

pub(package) const fn is_int(t: u8) bool {
    return t >= T_I8 && t <= T_I128;
}

pub(package) const fn is_float(t: u8) bool {
    return t == T_F32 || t == T_F64;
}

/// The lane count of vector type `t`.
pub(package) const fn lanes(t: u8) u32 {
    return 1u32 << (t & 7) as u32;
}

/// The scalar type of a lane of vector type `t`.
pub(package) const fn lane_type(t: u8) u8 {
    let e = t >> 3 & 7;
    if e == ELEM_F32 {
        return T_F32;
    }
    if e == ELEM_F64 {
        return T_F64;
    }
    return T_I8 + e;
}

/// The size of type `t` in bytes, with pointers of `ptr` bytes.
/// The alignment of type `t` in memory: its size, a vector's capped at 16 bytes (the C layout on every
/// target).
pub(package) const fn type_align(t: u8, ptr: u32) u32 {
    let n = type_bytes(t, ptr);
    if is_vec(t) && n > 16 {
        return 16;
    }
    return n;
}

pub(package) const fn type_bytes(t: u8, ptr: u32) u32 {
    if is_vec(t) {
        return type_bytes(lane_type(t), ptr) * lanes(t);
    }
    if t == T_PTR {
        return ptr;
    }
    if t == T_F32 {
        return 4;
    }
    if t == T_F64 {
        return 8;
    }
    if t == T_NONE {
        return 0;
    }
    return 1u32 << (t - T_I8) as u32;
}

/// The width of integer, float or pointer type `t` in bits.
pub(package) const fn type_bits(t: u8, ptr: u32) u32 {
    return type_bytes(t, ptr) * 8;
}

// ---- Opcodes ------------------------------------------------------------------------------------------

// Operand forms: which of `aux`, `a`, `b` and `c` an opcode reads, and how.
pub(package) const F_NONE: u8 = 0; // no operand
pub(package) const F_IMM: u8 = 1; // a = low 32 bits, b = high 32 bits of the constant
pub(package) const F_WIDE: u8 = 2; // a = first word in `words`, b = word count
pub(package) const F_SYM: u8 = 3; // a = body symbol, b = byte addend (i32)
pub(package) const F_SLOT: u8 = 4; // a = slot
pub(package) const F_UN: u8 = 5; // a = value
pub(package) const F_BIN: u8 = 6; // a, b = values
pub(package) const F_CMP: u8 = 7; // aux = condition, a, b = values
pub(package) const F_TRI: u8 = 8; // a, b, c = values
pub(package) const F_PTRADD: u8 = 9; // a = base, b = index value or VNONE, aux = scale, c = byte offset (i32)
pub(package) const F_LOAD: u8 = 10; // a = address, c = byte offset (i32), aux = MEM_* flags
pub(package) const F_STORE: u8 = 11; // a = address, b = value, c = byte offset (i32), aux = MEM_* flags
pub(package) const F_CALL: u8 = 12; // a = body symbol, b = signature (pool), c = arguments (pool), aux = count
pub(package) const F_CALLIND: u8 = 13; // a = callee value, b, c and aux as F_CALL
pub(package) const F_VOP: u8 = 14; // aux = VOP code | VOP_* flags, a = operands (pool), b = count, c = lanes (pool) or VNONE
pub(package) const F_JMP: u8 = 15; // a = edge (pool)
pub(package) const F_BR: u8 = 16; // a = condition, b = edge taken when it is not 0, c = the other edge
pub(package) const F_SWITCH: u8 = 17; // a = value, b = first case (words), c = edge list (pool: one per case, then the default's), aux = case count
pub(package) const F_RET: u8 = 18; // a = value or VNONE
pub(package) const F_PANIC: u8 = 19; // a = body message, b = a lane mask or VNONE: `lane <its lowest set bit>: ` leads the message
pub(package) const F_OVF: u8 = 20; // aux = OV_SIGNED or 0, a, b = values; two results: the wrapped value, then its flag
pub(package) const F_ASM: u8 = 21; // a = values (pool), b = count, c = the statement's record (pool, `asm_*`)
pub(package) const F_SYS: u8 = 22; // aux = SYS_* code, a, b, c = values or VNONE (`sys_arity`)

pub(package) const O_ICONST: u8 = 1;
pub(package) const O_FCONST: u8 = 2;
pub(package) const O_WCONST: u8 = 3;
pub(package) const O_SYMADDR: u8 = 4;
pub(package) const O_SLOTADDR: u8 = 5;
pub(package) const O_ADD: u8 = 6;
pub(package) const O_SUB: u8 = 7;
pub(package) const O_MUL: u8 = 8;
pub(package) const O_SDIV: u8 = 9;
pub(package) const O_UDIV: u8 = 10;
pub(package) const O_SREM: u8 = 11;
pub(package) const O_UREM: u8 = 12;
pub(package) const O_AND: u8 = 13;
pub(package) const O_OR: u8 = 14;
pub(package) const O_XOR: u8 = 15;
pub(package) const O_SHL: u8 = 16;
pub(package) const O_LSHR: u8 = 17;
pub(package) const O_ASHR: u8 = 18;
pub(package) const O_NEG: u8 = 19;
pub(package) const O_NOT: u8 = 20;
pub(package) const O_ADDO: u8 = 21;
pub(package) const O_SUBO: u8 = 22;
pub(package) const O_MULO: u8 = 23;
pub(package) const O_ICMP: u8 = 24;
pub(package) const O_FCMP: u8 = 25;
pub(package) const O_FADD: u8 = 26;
pub(package) const O_FSUB: u8 = 27;
pub(package) const O_FMUL: u8 = 28;
pub(package) const O_FDIV: u8 = 29;
pub(package) const O_FNEG: u8 = 30;
pub(package) const O_SEXT: u8 = 31;
pub(package) const O_ZEXT: u8 = 32;
pub(package) const O_TRUNC: u8 = 33;
pub(package) const O_FPEXT: u8 = 34;
pub(package) const O_FPTRUNC: u8 = 35;
pub(package) const O_FPTOSI: u8 = 36;
pub(package) const O_FPTOUI: u8 = 37;
pub(package) const O_SITOFP: u8 = 38;
pub(package) const O_UITOFP: u8 = 39;
pub(package) const O_BITCAST: u8 = 40;
pub(package) const O_PTRTOINT: u8 = 41;
pub(package) const O_INTTOPTR: u8 = 42;
pub(package) const O_PTRADD: u8 = 43;
pub(package) const O_LOAD: u8 = 44;
pub(package) const O_STORE: u8 = 45;
pub(package) const O_MEMCPY: u8 = 46;
pub(package) const O_MEMSET: u8 = 47;
pub(package) const O_ALOAD: u8 = 48;
pub(package) const O_ASTORE: u8 = 49;
pub(package) const O_ARMW: u8 = 50;
pub(package) const O_ACAS: u8 = 51;
pub(package) const O_FENCE: u8 = 52;
pub(package) const O_SELECT: u8 = 53;
pub(package) const O_RETADDR: u8 = 54;
pub(package) const O_CALL: u8 = 55;
pub(package) const O_CALLIND: u8 = 56;
pub(package) const O_VOP: u8 = 57;
pub(package) const O_VASTART: u8 = 58;
pub(package) const O_VAARG: u8 = 59;
pub(package) const O_VAEND: u8 = 60;
pub(package) const O_JMP: u8 = 61;
pub(package) const O_BR: u8 = 62;
pub(package) const O_SWITCH: u8 = 63;
pub(package) const O_RET: u8 = 64;
pub(package) const O_PANIC: u8 = 65;
pub(package) const O_UNREACHABLE: u8 = 66;
/// Bit counts of an integer: leading zeros, trailing zeros (each the width for 0), set bits.
pub(package) const O_CLZ: u8 = 67;
pub(package) const O_CTZ: u8 = 68;
pub(package) const O_POPCNT: u8 = 69;
/// Inline assembly: the outputs' addresses then the inputs' values; the record at `c` holds the
/// template, the output, input and clobber counts, the output constraints, the output types, the input
/// constraints and the clobbers (text as body messages). Each output is stored to its address after
/// the instructions run (read from it first for a `+` constraint).
pub(package) const O_ASM: u8 = 70;
/// Fused multiply-add of floats: `a * b + c` with one rounding (`-ffp-contract=fast` makes it).
pub(package) const O_FMA: u8 = 71;
/// A processor or runtime operation no other opcode expresses (`SYS_*`): what inline assembly did, in a
/// form every backend lowers for its target.
pub(package) const O_SYS: u8 = 72;
/// The high half of the unsigned product of two integers of up to 64 bits: `(a * b) >> bits`, the product
/// exact (division by a constant, `lir::opt`).
pub(package) const O_MULHU: u8 = 73;
/// A vector whose every lane is scalar `a` (of the lane type).
pub(package) const O_SPLAT: u8 = 74;
pub(package) const OP_COUNT: u8 = 75;

/// One opcode: its text name and its operand form.
pub(package) struct OpInfo {
    pub(package) name: str<'static>,
    pub(package) form: u8,
}

pub(package) const OPS: [OpInfo; 75] = [
    OpInfo { name: "", form: F_NONE },
    OpInfo { name: "iconst", form: F_IMM },
    OpInfo { name: "fconst", form: F_IMM },
    OpInfo { name: "wconst", form: F_WIDE },
    OpInfo { name: "symaddr", form: F_SYM },
    OpInfo { name: "slotaddr", form: F_SLOT },
    OpInfo { name: "add", form: F_BIN },
    OpInfo { name: "sub", form: F_BIN },
    OpInfo { name: "mul", form: F_BIN },
    OpInfo { name: "sdiv", form: F_BIN },
    OpInfo { name: "udiv", form: F_BIN },
    OpInfo { name: "srem", form: F_BIN },
    OpInfo { name: "urem", form: F_BIN },
    OpInfo { name: "and", form: F_BIN },
    OpInfo { name: "or", form: F_BIN },
    OpInfo { name: "xor", form: F_BIN },
    OpInfo { name: "shl", form: F_BIN },
    OpInfo { name: "lshr", form: F_BIN },
    OpInfo { name: "ashr", form: F_BIN },
    OpInfo { name: "neg", form: F_UN },
    OpInfo { name: "not", form: F_UN },
    OpInfo { name: "addo", form: F_OVF },
    OpInfo { name: "subo", form: F_OVF },
    OpInfo { name: "mulo", form: F_OVF },
    OpInfo { name: "icmp", form: F_CMP },
    OpInfo { name: "fcmp", form: F_CMP },
    OpInfo { name: "fadd", form: F_BIN },
    OpInfo { name: "fsub", form: F_BIN },
    OpInfo { name: "fmul", form: F_BIN },
    OpInfo { name: "fdiv", form: F_BIN },
    OpInfo { name: "fneg", form: F_UN },
    OpInfo { name: "sext", form: F_UN },
    OpInfo { name: "zext", form: F_UN },
    OpInfo { name: "trunc", form: F_UN },
    OpInfo { name: "fpext", form: F_UN },
    OpInfo { name: "fptrunc", form: F_UN },
    OpInfo { name: "fptosi", form: F_UN },
    OpInfo { name: "fptoui", form: F_UN },
    OpInfo { name: "sitofp", form: F_UN },
    OpInfo { name: "uitofp", form: F_UN },
    OpInfo { name: "bitcast", form: F_UN },
    OpInfo { name: "ptrtoint", form: F_UN },
    OpInfo { name: "inttoptr", form: F_UN },
    OpInfo { name: "ptradd", form: F_PTRADD },
    OpInfo { name: "load", form: F_LOAD },
    OpInfo { name: "store", form: F_STORE },
    OpInfo { name: "memcpy", form: F_TRI },
    OpInfo { name: "memset", form: F_TRI },
    OpInfo { name: "aload", form: F_LOAD },
    OpInfo { name: "astore", form: F_STORE },
    OpInfo { name: "armw", form: F_STORE },
    OpInfo { name: "acas", form: F_TRI },
    OpInfo { name: "fence", form: F_NONE },
    OpInfo { name: "select", form: F_TRI },
    OpInfo { name: "retaddr", form: F_NONE },
    OpInfo { name: "call", form: F_CALL },
    OpInfo { name: "call.ind", form: F_CALLIND },
    OpInfo { name: "vop", form: F_VOP },
    OpInfo { name: "vastart", form: F_UN },
    OpInfo { name: "vaarg", form: F_UN },
    OpInfo { name: "vaend", form: F_UN },
    OpInfo { name: "jmp", form: F_JMP },
    OpInfo { name: "br", form: F_BR },
    OpInfo { name: "switch", form: F_SWITCH },
    OpInfo { name: "ret", form: F_RET },
    OpInfo { name: "panic", form: F_PANIC },
    OpInfo { name: "unreachable", form: F_NONE },
    OpInfo { name: "clz", form: F_UN },
    OpInfo { name: "ctz", form: F_UN },
    OpInfo { name: "popcnt", form: F_UN },
    OpInfo { name: "asm", form: F_ASM },
    OpInfo { name: "fma", form: F_TRI },
    OpInfo { name: "sys", form: F_SYS },
    OpInfo { name: "mulhu", form: F_BIN },
    OpInfo { name: "splat", form: F_UN },
];

/// An `O_ASM` record at pool index `r` of `b`: its output, input and clobber counts.
pub(package) const fn asm_nout(b: &Body, r: u32) u32 {
    return b.pool[(r + 1) as usize];
}

pub(package) const fn asm_nin(b: &Body, r: u32) u32 {
    return b.pool[(r + 2) as usize];
}

pub(package) const fn asm_nclob(b: &Body, r: u32) u32 {
    return b.pool[(r + 3) as usize];
}

/// The template's body message.
pub(package) const fn asm_template(b: &Body, r: u32) u32 {
    return b.pool[r as usize];
}

/// Output `k`'s constraint message and machine type.
pub(package) const fn asm_out_con(b: &Body, r: u32, k: u32) u32 {
    return b.pool[(r + 4 + k) as usize];
}

pub(package) const fn asm_out_ty(b: &Body, r: u32, k: u32) u8 {
    return b.pool[(r + 4 + asm_nout(b, r) + k) as usize] as u8;
}

/// Input `k`'s constraint message.
pub(package) const fn asm_in_con(b: &Body, r: u32, k: u32) u32 {
    return b.pool[(r + 4 + 2 * asm_nout(b, r) + k) as usize];
}

/// Clobber `k`'s message.
pub(package) const fn asm_clob(b: &Body, r: u32, k: u32) u32 {
    return b.pool[(r + 4 + 2 * asm_nout(b, r) + asm_nin(b, r) + k) as usize];
}

/// The row of opcode `op`.
pub(package) const fn op_info(op: u8) OpInfo {
    let t: []OpInfo = OPS;
    return t[op as usize];
}

/// Whether `op` ends a block.
pub(package) const fn is_terminator(op: u8) bool {
    return op >= O_JMP && op <= O_UNREACHABLE;
}

/// Comparison conditions (`O_ICMP`, `O_FCMP`). A float condition is ordered (false when an operand is
/// NaN) unless its name starts with `u`.
pub(package) const C_EQ: u16 = 0;
pub(package) const C_NE: u16 = 1;
pub(package) const C_SLT: u16 = 2;
pub(package) const C_SLE: u16 = 3;
pub(package) const C_SGT: u16 = 4;
pub(package) const C_SGE: u16 = 5;
pub(package) const C_ULT: u16 = 6;
pub(package) const C_ULE: u16 = 7;
pub(package) const C_UGT: u16 = 8;
pub(package) const C_UGE: u16 = 9;
pub(package) const C_OEQ: u16 = 10;
pub(package) const C_ONE: u16 = 11;
pub(package) const C_OLT: u16 = 12;
pub(package) const C_OLE: u16 = 13;
pub(package) const C_OGT: u16 = 14;
pub(package) const C_OGE: u16 = 15;
pub(package) const C_UEQ: u16 = 16;
pub(package) const C_UNE: u16 = 17;
pub(package) const C_UNO: u16 = 18;
pub(package) const C_COUNT: u16 = 19;

pub(package) const COND_NAMES: [str<'static>; 19] = [
    "eq",
    "ne",
    "slt",
    "sle",
    "sgt",
    "sge",
    "ult",
    "ule",
    "ugt",
    "uge",
    "oeq",
    "one",
    "olt",
    "ole",
    "ogt",
    "oge",
    "ueq",
    "une",
    "uno",
];

/// `O_ADDO`, `O_SUBO`, `O_MULO`: the operands are signed (else unsigned). The operation's value is
/// the wrapped result; `VFLAG |` its index is 1 when the exact result does not fit.
pub(package) const OV_SIGNED: u16 = 1;
/// `O_FPTOSI`, `O_FPTOUI`: no saturation; the value must be a number in the result's range.
pub(package) const CV_UNCHECKED: u16 = 1;
/// `O_PTRADD`'s `aux` is the scale; `O_LOAD`, `O_STORE`: log2 of the alignment in bits 0 to 3, then
/// MEM_VOLATILE, then the type tag in bits 8 to 11 (`MEM_TBAA`).
pub(package) const MEM_VOLATILE: u16 = 16;
/// The type tag of a load or store (`-fstrict-aliasing`): 0 for an access that may touch any object,
/// else `tbaa_of` its type, which the lowering gives an access of a typed place outside a union. Two
/// accesses with different tags, neither 0, touch different objects.
pub(package) const MEM_TBAA_SHIFT: u16 = 8;
pub(package) const MEM_TBAA: u16 = 0xF00;
/// The values of the tag field (in use: 0 and the scalar types T_I16 to T_PTR).
pub(package) const TBAA_TAGS: usize = 16;

/// The type tag of an access of type `ty`: its lane's scalar type, 0 for bytes (which may view any object).
pub(package) const fn tbaa_of(ty: u8) u16 {
    let t = if is_vec(ty) {
        lane_type(ty);
    } else {
        ty;
    };
    return if t == T_I8 {
        0u16;
    } else {
        t;
    };
}

/// The type tag of load or store `t` (`MEM_TBAA`).
pub(package) const fn tbaa(t: Inst) usize {
    return ((t.aux & MEM_TBAA) >> MEM_TBAA_SHIFT) as usize;
}
/// `O_LOAD`: the value read is 0 or 1 (a `bool`).
pub(package) const MEM_BOOL: u16 = 32;
/// `O_MEMCPY`: the regions may overlap (memmove).
pub(package) const MEM_OVERLAP: u16 = 1;
/// A logical right shift (`lshr`) that shifts out only zero bits (the text's `lshr.exact`): its operand's
/// integer values are multiples of 2^amount, so it divides a polynomial (`lir::loops`' final values).
pub(package) const SH_EXACT: u16 = 1;

/// Atomic memory orders (`aux` bits 0 to 2 of the atomic opcodes; `O_ACAS`: the failure order in bits
/// 3 to 5, then ACAS_WEAK; `O_ARMW`: the operation in bits 4 to 7).
pub(package) const MO_RELAXED: u16 = 0;
pub(package) const MO_ACQUIRE: u16 = 1;
pub(package) const MO_RELEASE: u16 = 2;
pub(package) const MO_ACQ_REL: u16 = 3;
pub(package) const MO_SEQ_CST: u16 = 4;
pub(package) const ACAS_WEAK: u16 = 64;
pub(package) const RMW_XCHG: u16 = 0;
pub(package) const RMW_ADD: u16 = 1;
pub(package) const RMW_SUB: u16 = 2;
pub(package) const RMW_AND: u16 = 3;
pub(package) const RMW_OR: u16 = 4;
pub(package) const RMW_XOR: u16 = 5;
pub(package) const ORDER_NAMES: [str<'static>; 5] = ["relaxed", "acquire", "release", "acq_rel", "seq_cst"];
pub(package) const RMW_NAMES: [str<'static>; 6] = ["xchg", "add", "sub", "and", "or", "xor"];

/// The text of condition `c`.
// The integer comparison code of `b op a` for `a op` = `c`: `<` and `>`, `<=` and `>=`, signed and unsigned;
// `==` and `!=` stay.
pub(package) const fn mirror(c: u16) u16 {
    if c < C_SLT {
        return c;
    }
    return if (c - C_SLT) % 4 < 2 {
        c + 2;
    } else {
        c - 2;
    };
}

// The integer comparison code that holds exactly when `c` does not: `==` and `!=`, `<` and `>=`, `<=` and
// `>`, signed and unsigned.
pub(package) const fn opposite(c: u16) u16 {
    return if c <= C_NE {
        c ^ 1;
    } else if c <= C_SGE {
        C_SLT + C_SGE - c;
    } else {
        C_ULT + C_UGE - c;
    };
}

pub(package) const fn cond_name(c: u16) str<'static> {
    let t: []str<'static> = COND_NAMES;
    return t[c as usize];
}

/// The text of memory order `o`.
pub(package) const fn order_name(o: u16) str<'static> {
    let t: []str<'static> = ORDER_NAMES;
    return t[o as usize];
}

/// `O_SYS` operations. None is pure: each stays where it is, in order with every memory access.
/// A spin-wait hint: `pause` (x86-64), `isb` (arm64), none (wasm).
pub(package) const SYS_SPIN: u16 = 0;
/// A compiler barrier: no instruction.
pub(package) const SYS_BARRIER: u16 = 1;
/// A compiler barrier that also reads `a`, which escapes.
pub(package) const SYS_KEEP: u16 = 2;
/// i64: the cycle counter (`rdtsc`, `cntvct_el0`).
pub(package) const SYS_CYCLES: u16 = 3;
/// The floating-point control state stored at `a`: MXCSR, then the x87 control word at 4 (x86-64); FPCR
/// (arm64).
pub(package) const SYS_FPSAVE: u16 = 4;
/// i64: the 8 bytes at offset `a` of the gs segment (x86-64).
pub(package) const SYS_GSLOAD: u16 = 5;
/// `b` stored at offset `a` of the gs segment (x86-64).
pub(package) const SYS_GSSTORE: u16 = 6;
/// CPUID leaf `b`, subleaf `c`: EAX, EBX, ECX and EDX stored at `a` (x86-64).
pub(package) const SYS_CPUID: u16 = 7;
/// i64: XGETBV of extended control register `a`, EDX:EAX (x86-64).
pub(package) const SYS_XGETBV: u16 = 8;
/// i64: the streaming vector length in bytes, RDSVL (arm64 with SME).
pub(package) const SYS_SVL: u16 = 9;
/// The whole body of a naked function `(save_sp, to_sp)`: save the callee-saved state on the running
/// stack, store its address at `save_sp`, resume the state at `to_sp` (`target::ctxswitch`).
pub(package) const SYS_CTXSWAP: u16 = 10;
/// The whole body of a naked function: where a forged context first resumes; it calls the body it
/// carries with its argument (`target::ctxswitch`).
pub(package) const SYS_CTXENTRY: u16 = 11;
pub(package) const SYS_COUNT: u16 = 12;

const SYS_NAMES: [(str<'static>, u8); 12] = [
    ("spin", 0),
    ("barrier", 0),
    ("keep", 1),
    ("cycles", 0),
    ("fpsave", 1),
    ("gsload", 1),
    ("gsstore", 2),
    ("cpuid", 3),
    ("xgetbv", 1),
    ("svl", 0),
    ("ctxswap", 2),
    ("ctxentry", 0),
];

/// The text of `O_SYS` operation `s`.
pub(package) const fn sys_name(s: u16) str<'static> {
    let t: [](str<'static>, u8) = SYS_NAMES;
    return t[s as usize].0;
}

/// The value operands `O_SYS` operation `s` takes (`a`, then `b`, then `c`).
pub(package) const fn sys_arity(s: u16) u32 {
    let t: [](str<'static>, u8) = SYS_NAMES;
    return t[s as usize].1;
}

/// The text of read-modify-write operation `r`.
pub(package) const fn rmw_name(r: u16) str<'static> {
    let t: []str<'static> = RMW_NAMES;
    return t[r as usize];
}

/// `O_VOP`: the code is a portable vector operation (`ir::core::OP_*`: the operators, the cast, the
/// `SIMD_*` operations from `OP_SIMD`, the lane-mask forms) in bits 0 to 7; the lanes are signed
/// integers (else unsigned, or floats). A `SIMD_*` operation of no result type writes memory: a
/// store through its operand 0, else its result at the address its last operand holds.
pub(package) const VOP_SIGNED: u16 = 256;
/// A conversion's result lanes are signed; for a `SIMD_*` operation, the result's lanes (for
/// `cast_changed`, its cast result operand's).
pub(package) const VOP_DSIGNED: u16 = 512;
/// A float to integer conversion that does not saturate: the lanes are not NaN and fit.
pub(package) const VOP_UNCHECKED: u16 = 1024;
/// The operation code of a `vop` (an `ir::core::OP_*` code).
pub(package) const VOP_CODE: u16 = 255;

// ---- Records ------------------------------------------------------------------------------------------

/// One instruction: 16 bytes.
pub(package) struct Inst {
    pub(package) op: u8,
    pub(package) ty: u8, // the result type, T_NONE without a result
    pub(package) aux: u16,
    pub(package) a: u32,
    pub(package) b: u32,
    pub(package) c: u32,
}
static_assert(sizeof(Inst) == 16, "an instruction is 16 bytes");

/// Block `i` is `insts[start .. start + len]`; its last instruction is its terminator. Its parameters
/// are values `VPARAM | param_start + k`, their types `params[param_start + k]`.
pub(package) struct Block {
    pub(package) start: u32,
    pub(package) len: u32,
    pub(package) param_start: u32,
    pub(package) param_len: u16,
    pub(package) flags: u16, // BLOCK_*
}

/// The block holds only a failure path (a panic or a trap).
pub(package) const BLOCK_COLD: u16 = 1;
/// The loop this block heads runs what a vector copy of it left (`lir::loops`): it does not vectorize.
pub(package) const BLOCK_NOVEC: u16 = 2;

/// A stack slot: `size` bytes aligned to `1 << align_log2`.
pub(package) struct Slot {
    pub(package) size: u32,
    pub(package) align_log2: u8,
}

/// A source location: a package file and a 1-based line and column.
pub(package) struct Loc {
    pub(package) file: u32,
    pub(package) line: u32,
    pub(package) col: u32,
}

/// Symbol kinds.
pub(package) const SK_FUNC: u8 = 0;
pub(package) const SK_DATA: u8 = 1;
/// Thread-local data: its address is the running thread's copy.
pub(package) const SK_TLS: u8 = 2;
/// Symbol linkage: visible to every object, or to its own only.
pub(package) const SL_GLOBAL: u8 = 0;
pub(package) const SL_LOCAL: u8 = 1;

/// A symbol: a name, a kind and a linkage, and its definition (`bodies` or `data` index), NONE for a
/// symbol another object defines (an extern C name).
pub(package) struct Sym {
    pub(package) name: u32, // a string id
    pub(package) kind: u8,
    pub(package) linkage: u8,
    pub(package) def: u32,
    /// The compilation unit (a module) whose object defines it, NONE when no unit claims it: the
    /// native backends' object per module reads it; the text form does not carry it.
    pub(package) unit: u32,
    /// The object section that holds it (a string id: the object format's own spelling,
    /// `@unsafe(link_section)`), NONE for its kind's section.
    pub(package) sect: u32,
    /// The linker keeps it though nothing refers to it (`@used`, a named section).
    pub(package) used: bool,
    /// A function the optimizer never inlines (`@noinline`).
    pub(package) noinline: bool,
    /// Defined by its unit's own items, not added by the build (an instance, glue, data): a cached
    /// emission of the unit holds it. The text form does not carry it.
    pub(package) own: bool,
    /// A C library's symbol (an extern declaration's): it may be in a shared library, so code takes its
    /// address through the linker's address slot. Every other symbol is in the program's image.
    pub(package) ext: bool,
    /// A function's signature as its definition has it (`Package.decls`), NONE when unrecorded: the
    /// lowering records it where it takes the function's address, for a backend that types that
    /// address (wasm) when the package holds no body of the function. The text form does not carry it.
    pub(package) sig: u32,
    /// The memory outside its own frame a call of it may read or write (`FX_*`): `lir::opt::Run::new`
    /// infers it for a function with a body; both for any other. The text form does not carry it.
    pub(package) fx: u8,
    /// What a call of it does to memory by its name (`alloc_of`): ALLOC_FRESH, ALLOC_FREE or ALLOC_NONE.
    pub(package) alloc: u8,
}

pub(package) const NONE: u32 = 0xFFFFFFFF;
/// `Sym.alloc`: a C library or runtime allocation, which returns a block no other pointer reaches and
/// writes no memory the program reads but `errno` (an `i32`); a C library or runtime free, which writes no
/// memory the program may read. Only for a call from outside it: a package that defines the function
/// (wasm's C library, the runtime's leak tracker) treats it as any other (`lir::opt`'s `call_alloc`).
pub(package) const ALLOC_NONE: u8 = 0;
pub(package) const ALLOC_FRESH: u8 = 1;
pub(package) const ALLOC_FREE: u8 = 2;

/// The `Sym.alloc` of the function named `name0` (`__sc_x_<c name>` is a C library name's alias).
pub(package) const fn alloc_of(name0: str) u8 {
    let name = if name0.starts_with("__sc_x_") {
        name0.slice(7, name0.len());
    } else {
        name0;
    };
    if name == "malloc" || name == "calloc" || name == "realloc" || name == "aligned_alloc" || name == "_aligned_malloc" || name == "sc_lk_malloc" || name == "sc_lk_calloc" || name == "sc_lk_realloc" || name == "sc_lk_aligned_alloc" {
        return ALLOC_FRESH;
    }
    if name == "free" || name == "_aligned_free" || name == "sc_lk_free" || name == "sc_lk_aligned_free" {
        return ALLOC_FREE;
    }
    return ALLOC_NONE;
}
/// `Sym.fx`: a call may read memory; a call may write memory; a call may write the memory its pointer
/// arguments address (and no other).
pub(package) const FX_READ: u8 = 1;
pub(package) const FX_WRITE: u8 = 2;
pub(package) const FX_ARG: u8 = 4;

/// `Package.protect`: no body has a stack canary, the bodies with a slot of at least 8 bytes, with any
/// slot, every body.
pub(package) const PROTECT_NONE: u8 = 0;
pub(package) const PROTECT_LARGE: u8 = 1;
pub(package) const PROTECT_SLOTS: u8 = 2;
pub(package) const PROTECT_ALL: u8 = 3;

/// `Package.fmath`: reassociation, reciprocals, no NaN or infinity, no signed zero, contraction into
/// fused multiply-adds.
pub(package) const FM_ASSOC: u8 = 1;
pub(package) const FM_RECIP: u8 = 2;
pub(package) const FM_FINITE: u8 = 4;
pub(package) const FM_NSZ: u8 = 8;
pub(package) const FM_CONTRACT: u8 = 16;

/// Whether body `b` of a package whose `protect` is `p` has a stack canary.
pub(package) fn protected(p: u8, b: &Body) bool {
    if p == PROTECT_ALL {
        return true;
    }
    for k in 0..b.slots.len() {
        if p == PROTECT_SLOTS || p == PROTECT_LARGE && b.slots[k].size >= 8 {
            return true;
        }
    }
    return false;
}

/// Initialized data: `size` bytes aligned to `1 << align_log2`, the first `nbytes` from `bytes`
/// (`Package.bytes`), the rest zero, then `nrelocs` relocations from `relocs`.
pub(package) struct DataDef {
    pub(package) size: u32,
    pub(package) align_log2: u8,
    pub(package) readonly: bool,
    pub(package) bytes: u32,
    pub(package) nbytes: u32,
    pub(package) relocs: u32,
    pub(package) nrelocs: u32,
}

/// A pointer-sized field at `offset` of a data symbol that holds the address of `sym` plus `addend`.
pub(package) struct Reloc {
    pub(package) offset: u32,
    pub(package) sym: u32,
    pub(package) addend: i64,
}

// Signature and layout records in a body's pool. A signature is: parameter count, fixed-parameter count
// (with SIG_VARIADIC for a variadic one: a call's signature lists the variadic arguments' types after the
// fixed ones, a definition's lists none), the result, then the parameters. A parameter or result is a
// type code (T_NONE: no result), or AGG | layout pool index for an aggregate passed through memory. A
// layout is: size, log2 of the alignment, leaf count, then per leaf its offset and type: the scalars the
// calling convention classifies.
pub(package) const AGG: u32 = 0x80000000;
/// An `i8` or `i16` parameter or result that is signed: the calling convention sign-extends it, else
/// zero-extends it.
pub(package) const SIG_SEXT: u32 = 0x40000000;
pub(package) const SIG_VARIADIC: u32 = 0x80000000;
/// `Body.refs`: the bytes, the exclusive flag, and REF_INNER for an aggregate parameter (a by-value
/// `[]mut T`) whose pointer at offset 0, rather than the parameter, is the exclusive one.
pub(package) const REF_BYTES: u32 = 0x3FFFFFFF;
pub(package) const REF_INNER: u32 = 0x40000000;
pub(package) const REF_NOALIAS: u32 = 0x80000000;

/// Alias classes (`lir::opt::Opt::classes`): no exclusive parameter's referent, exclusive parameter k's
/// (CL_NOALIAS + k), any. Two accesses of different classes, neither CL_MANY, touch different bytes.
pub(package) const CL_OTHER: u8 = 0;
pub(package) const CL_NOALIAS: u8 = 1;
pub(package) const CL_MANY: u8 = 64;

/// A body: its instructions and every table they index. `syms` and `msgs` map the body's symbol and
/// message numbers to its package's.
pub(package) struct Body {
    pub(package) insts: Vector<Inst>,
    pub(package) locs: Vector<u32>, // per instruction, an index into `lines`; 0 = no location
    pub(package) blocks: Vector<Block>, // block 0 is the entry
    pub(package) params: Vector<u8>,
    pub(package) pool: Vector<u32>,
    pub(package) words: Vector<u64>,
    pub(package) slots: Vector<Slot>,
    pub(package) syms: Vector<u32>,
    pub(package) msgs: Vector<u32>,
    pub(package) lines: Vector<Loc>, // entry 0 is "no location"
    /// Per instruction, the `lines` index of the call in this body it was inlined from (the outermost
    /// one), 0 for the body's own instruction; empty when nothing was inlined.
    pub(package) inl: Vector<u32>,
    pub(package) sig: u32, // the body's own signature (pool); NONE until set
    /// Per signature parameter, what a reference parameter points to for the whole call: the bytes a
    /// load may read (`REF_BYTES`), with REF_NOALIAS when no pointer that does not come from the
    /// parameter reaches them (a `&mut`); 0 for any other parameter. Empty when no parameter is a
    /// reference.
    pub(package) refs: Vector<u32>,
    /// Per signature parameter of the first 64, whether it holds 0 or 1 (a `bool`), a bit each.
    pub(package) bools: u64,
    /// The scopes of the inlined calls' exclusive parameters (`Scope`); empty when there is none.
    pub(package) scopes: Vector<Scope>,
    /// A naked function (`@unsafe(naked)`): its machine code is its `O_ASM` templates alone, in order,
    /// without a prologue or an epilogue.
    pub(package) naked: bool,
    cur: u32, // the block `emit` appends to
}

/// A scope of an inlined call (`Body.scopes`): within the copy of the call whose instructions have
/// `inl` value `site` (a `lines` entry of that call alone), `root` is the only path to the referent of
/// the callee's exclusive parameter `group` (`REF_NOALIAS`): an access of the copy through it and one of
/// the copy through any other pointer touch different bytes, as the language makes the parameter the
/// only path to its referent during the call. The roots of one site and group are one pointer (a view's
/// element pointer, loaded more than once).
pub(package) struct Scope {
    pub(package) site: u32,
    pub(package) group: u32,
    pub(package) root: Value,
}

// An exact-capacity copy of `v`.
fn exact<T: Copy>(v: &Vector<T>) Vector<T> {
    let mut out = Vector::<T>::with_capacity(v.len());
    out.extend_copy(v);
    return out;
}

extend Inst as Copy {}
extend Block as Copy {}
extend Slot as Copy {}
extend Loc as Copy {}
extend Scope as Copy {}
extend Sym as Copy {}
extend DataDef as Copy {}
extend Reloc as Copy {}

extend Body {
    pub(package) fn new() Body {
        let mut b = Body {
            insts: Vector::<Inst>::new(),
            locs: Vector::<u32>::new(),
            blocks: Vector::<Block>::new(),
            params: Vector::<u8>::new(),
            pool: Vector::<u32>::new(),
            words: Vector::<u64>::new(),
            slots: Vector::<Slot>::new(),
            syms: Vector::<u32>::new(),
            msgs: Vector::<u32>::new(),
            lines: Vector::<Loc>::new(),
            inl: Vector::<u32>::new(),
            sig: NONE,
            refs: Vector::<u32>::new(),
            bools: 0,
            scopes: Vector::<Scope>::new(),
            naked: false,
            cur: 0,
        };
        b.lines.push(Loc { file: 0, line: 0, col: 0 });
        return b;
    }

    /// Empty the body for the next one, keeping every table's capacity.
    pub(package) fn clear(self: &mut Self) {
        self.insts.truncate(0);
        self.locs.truncate(0);
        self.blocks.truncate(0);
        self.params.truncate(0);
        self.pool.truncate(0);
        self.words.truncate(0);
        self.slots.truncate(0);
        self.syms.truncate(0);
        self.msgs.truncate(0);
        self.lines.truncate(1);
        self.inl.truncate(0);
        self.sig = NONE;
        self.refs.truncate(0);
        self.bools = 0;
        self.scopes.truncate(0);
        self.naked = false;
        self.cur = 0;
    }

    /// An exact-size copy: one allocation per non-empty table and no growth slack.
    pub(package) fn compact(self: &Self) Body {
        return Body {
            insts: exact(&self.insts),
            locs: exact(&self.locs),
            blocks: exact(&self.blocks),
            params: exact(&self.params),
            pool: exact(&self.pool),
            words: exact(&self.words),
            slots: exact(&self.slots),
            syms: exact(&self.syms),
            msgs: exact(&self.msgs),
            lines: exact(&self.lines),
            inl: exact(&self.inl),
            sig: self.sig,
            refs: exact(&self.refs),
            bools: self.bools,
            scopes: exact(&self.scopes),
            naked: self.naked,
            cur: 0,
        };
    }

    // ---- Building ----

    /// A new block with parameters of `types`; its instructions follow until its terminator.
    pub(package) fn add_block(self: &mut Self, types: []u8) u32 {
        self.blocks.push(
            Block {
                start: self.insts.len() as u32,
                len: 0,
                param_start: self.params.len() as u32,
                param_len: types.len() as u16,
                flags: 0,
            },
        );
        for i in 0..types.len() {
            self.params.push(types[i]);
        }
        return self.blocks.len() as u32 - 1;
    }

    /// Block `k`'s parameter `i` as a value.
    pub(package) const fn param(self: &Self, k: u32, i: u32) Value {
        return VPARAM | self.blocks[k as usize].param_start + i;
    }

    /// Start appending to block `k`: its instructions begin at the next instruction. Blocks are filled
    /// one at a time, each up to its terminator, in any order.
    pub(package) fn begin(self: &mut Self, k: u32) {
        let blk = self.blocks.index_mut(k as usize);
        blk.start = self.insts.len() as u32;
        blk.len = 0;
        self.cur = k;
    }

    /// The block begun last.
    pub(package) const fn current(self: &Self) u32 {
        return self.cur;
    }

    /// Remove the last instruction of the block begun last.
    pub(package) fn pop(self: &mut Self) {
        let _ = self.insts.pop();
        let _ = self.locs.pop();
        self.blocks.index_mut(self.cur as usize).len -= 1;
    }

    /// Append instruction `i` at location `loc` (a `lines` index) to the block begun last; its value.
    pub(package) fn emit(self: &mut Self, i: Inst, loc: u32) Value {
        self.insts.push(i);
        self.locs.push(loc);
        self.blocks.index_mut(self.cur as usize).len += 1;
        return self.insts.len() as u32 - 1;
    }

    /// The `lines` index of `l`, added when the last entry is another location.
    pub(package) fn loc(self: &mut Self, l: Loc) u32 {
        if l.line == 0 {
            return 0;
        }
        let k = self.lines.len() - 1;
        let last = self.lines[k];
        if k != 0 && last.file == l.file && last.line == l.line && last.col == l.col {
            return k as u32;
        }
        self.lines.push(l);
        return self.lines.len() as u32 - 1;
    }

    /// Append the values `vs` to the pool; the index of the first.
    pub(package) fn pool_list(self: &mut Self, vs: []u32) u32 {
        let at = self.pool.len() as u32;
        for i in 0..vs.len() {
            self.pool.push(vs[i]);
        }
        return at;
    }

    /// An edge to block `target` passing `args`, in the pool.
    pub(package) fn edge(self: &mut Self, target: u32, args: []Value) u32 {
        let at = self.pool.len() as u32;
        self.pool.push(target);
        self.pool.push(args.len() as u32);
        for i in 0..args.len() {
            self.pool.push(args[i]);
        }
        return at;
    }

    /// A signature: `params` (each a type code or AGG | layout), the first `nfixed` fixed and the rest
    /// variadic arguments when `variadic`, and the result `ret` (T_NONE for none).
    pub(package) fn signature(self: &mut Self, params: []u32, nfixed: u32, variadic: bool, ret: u32) u32 {
        let at = self.pool.len() as u32;
        self.pool.push(params.len() as u32);
        self.pool.push(nfixed | ast::pick(variadic, SIG_VARIADIC, 0));
        self.pool.push(ret);
        for i in 0..params.len() {
            self.pool.push(params[i]);
        }
        return at;
    }

    /// A layout of `size` bytes aligned to `1 << align_log2` with scalar leaves (offset, type) `leaves`.
    pub(package) fn layout(self: &mut Self, size: u32, align_log2: u32, leaves: [](u32, u8)) u32 {
        let at = self.pool.len() as u32;
        self.pool.push(size);
        self.pool.push(align_log2);
        self.pool.push(leaves.len() as u32);
        for i in 0..leaves.len() {
            self.pool.push(leaves[i].0);
            self.pool.push(leaves[i].1);
        }
        return at;
    }

    /// A slot of `size` bytes aligned to `1 << align_log2`.
    pub(package) fn slot(self: &mut Self, size: u32, align_log2: u8) u32 {
        self.slots.push(Slot { size: size, align_log2: align_log2 });
        return self.slots.len() as u32 - 1;
    }

    // ---- Reading ----

    /// The type of value `v`.
    pub(package) const fn type_of(self: &Self, v: Value) u8 {
        if (v & VPARAM) != 0 {
            return self.params[(v & ~VPARAM) as usize];
        }
        if (v & VFLAG) != 0 {
            return T_I8;
        }
        return self.insts[v as usize].ty;
    }

    /// Edge `e`'s target block.
    pub(package) const fn edge_target(self: &Self, e: u32) u32 {
        return self.pool[e as usize];
    }

    /// Edge `e`'s argument count.
    pub(package) const fn edge_nargs(self: &Self, e: u32) u32 {
        return self.pool[e as usize + 1];
    }

    /// Edge `e`'s argument `i`.
    pub(package) const fn edge_arg(self: &Self, e: u32, i: u32) Value {
        return self.pool[(e + 2 + i) as usize];
    }

    /// The successor edges of terminator `t` into `out`.
    pub(package) fn succ_edges(self: &Self, t: Inst, out: &mut Vector<u32>) {
        out.truncate(0);
        if t.op == O_JMP {
            out.push(t.a);
        } else if t.op == O_BR {
            out.push(t.b);
            out.push(t.c);
        } else if t.op == O_SWITCH {
            for k in 0..t.aux as u32 + 1 {
                out.push(self.switch_edge(t, k));
            }
        }
    }

    /// Edge `k` of switch `t`: case `k`'s, the default's at `k == aux`.
    pub(package) const fn switch_edge(self: &Self, t: Inst, k: u32) u32 {
        return self.pool[(t.c + k) as usize];
    }
}

extend Body {
    /// The body's number for package symbol `s`, added when new.
    pub(package) fn ref_sym(self: &mut Self, s: u32) u32 {
        for i in 0..self.syms.len() {
            if self.syms[i] == s {
                return i as u32;
            }
        }
        self.syms.push(s);
        return self.syms.len() as u32 - 1;
    }

    /// The body's number for package message `m`, added when new.
    pub(package) fn ref_msg(self: &mut Self, m: u32) u32 {
        for i in 0..self.msgs.len() {
            if self.msgs[i] == m {
                return i as u32;
            }
        }
        self.msgs.push(m);
        return self.msgs.len() as u32 - 1;
    }
}

// ---- Packages -----------------------------------------------------------------------------------------

/// What bodies share: the spellings, the files, the symbols, the panic messages, the data and the
/// bodies themselves. A tool adds to it with the calls the lowering uses, so a function with no source
/// is the same as a lowered one.
pub(package) struct Package {
    pub(package) ptr_bytes: u32, // the data model's pointer size
    /// The widest vector the C side passes in one vector register (16, 32 or 64), or 0 when C holds a
    /// vector as an array of its lanes: the calling conventions follow it (`mangle::vec_def`).
    pub(package) vec_regs: u32,
    /// Position-independent code for a shared library: a reference to a global symbol goes through the
    /// global offset table, as the symbol may resolve outside the library.
    pub(package) pic: bool,
    /// On ELF, a call of a C library's function (`Sym.ext`) goes through its global offset table slot,
    /// not a procedure linkage table stub (`-fno-plt`).
    pub(package) no_plt: bool,
    /// The objects carry debug information: line tables from the locations of the bodies, their file
    /// names relative to directory `comp_dir`.
    pub(package) debug: bool,
    pub(package) comp_dir: String,
    /// Bodies address their frames through the stack pointer, without a frame pointer, where they can.
    pub(package) omit_fp: bool,
    /// The bodies with a stack canary (`PROTECT_*`).
    pub(package) protect: u8,
    /// The bytes of a vector the native backend computes in one register (`target::table::Isa`), 0 for
    /// none: the loop vectorizer's vectors (`lir::loops`).
    pub(package) vector: u32,
    /// Whether the native backend computes `O_MULHU` of 64-bit integers in one instruction
    /// (`target::table::Isa`): the optimizer then divides by a 64-bit constant with a product.
    pub(package) mul_high: bool,
    /// The float rewrites the build allows (`FM_*`, `-ffast-math` and its parts), and whether the
    /// processor has a scalar fused multiply-add (`O_FMA` for contraction).
    pub(package) fmath: u8,
    pub(package) fma: bool,
    /// The object sections split at their symbols, so the link can drop what nothing reaches
    /// (`codegen::obj::SPLIT_*`, `-ffunction-sections` and `-fdata-sections`); Mach-O splits at the link
    /// instead.
    pub(package) split: u8,
    pub(package) names: nm::Names, // file paths, symbol names and messages
    pub(package) files: Vector<u32>, // file id -> name id
    pub(package) syms: Vector<Sym>,
    pub(package) msgs: Vector<u32>, // message id -> name id
    pub(package) data: Vector<DataDef>,
    pub(package) bytes: Vector<u8>,
    pub(package) relocs: Vector<Reloc>,
    pub(package) bodies: Vector<Body>,
    /// The signatures `Sym.sig` records, each the `sig` of a body that has no instructions.
    pub(package) decls: Vector<Body>,
    pub(package) held: Held,
    // Per name id, its file, symbol and message ids plus 1 (0: none).
    file_of: Vector<u32>,
    sym_of: Vector<u32>,
    msg_of: Vector<u32>,
}

/// A cached unit's part in the optimization of the others (`lir::hold`): bodies and data definitions,
/// after the package's own, that the optimizer reads but neither optimizes nor emits.
pub(package) struct Held {
    /// The first held body and data definition, NONE when nothing is held; the package's bytes and
    /// relocations before the held data.
    pub(package) body: u32,
    pub(package) data: u32,
    pub(package) bytes: u32,
    pub(package) relocs: u32,
    /// Per held body: its symbol, its walk facts (`HELD_SHAPE`, `HELD_OK`), its effects (`Sym.fx`) and
    /// the parameters whose memory it may write (a bit each), and its direct calls before optimization
    /// (`calls[at[k]..at[k + 1]]`: symbols, in instruction order).
    pub(package) syms: Vector<u32>,
    pub(package) flags: Vector<u8>,
    pub(package) fx: Vector<u8>,
    pub(package) wargs: Vector<u64>,
    pub(package) at: Vector<u32>,
    pub(package) calls: Vector<u32>,
    /// Per held data definition, its symbol.
    pub(package) dsyms: Vector<u32>,
}

/// `Held.flags`: the inliner's shape test passed (`lir::inline::shape_ok`); its callers may inline the
/// optimized body.
pub(package) const HELD_SHAPE: u8 = 1;
pub(package) const HELD_OK: u8 = 2;

extend Held {
    pub(package) fn new() Held {
        return Held {
            body: NONE,
            data: NONE,
            bytes: 0,
            relocs: 0,
            syms: Vector::<u32>::new(),
            flags: Vector::<u8>::new(),
            fx: Vector::<u8>::new(),
            wargs: Vector::<u64>::new(),
            at: Vector::<u32>::new(),
            calls: Vector::<u32>::new(),
            dsyms: Vector::<u32>::new(),
        };
    }
}

extend Package {
    /// An empty package for a data model with `ptr_bytes`-byte pointers.
    pub(package) fn new(ptr_bytes: u32) Package {
        return Package {
            ptr_bytes: ptr_bytes,
            vec_regs: 16,
            vector: 16,
            mul_high: true,
            pic: false,
            no_plt: false,
            debug: false,
            comp_dir: String::new(),
            omit_fp: false,
            protect: PROTECT_NONE,
            fmath: 0,
            fma: false,
            names: nm::Names::with_capacity(1 << 14, 1 << 10),
            files: Vector::<u32>::new(),
            syms: Vector::<Sym>::new(),
            msgs: Vector::<u32>::new(),
            data: Vector::<DataDef>::new(),
            bytes: Vector::<u8>::new(),
            relocs: Vector::<Reloc>::new(),
            bodies: Vector::<Body>::new(),
            decls: Vector::<Body>::new(),
            held: Held::new(),
            file_of: Vector::<u32>::new(),
            sym_of: Vector::<u32>::new(),
            msg_of: Vector::<u32>::new(),
        };
    }

    // The id of spelling `s`, with the per-name tables grown to cover it.
    fn name(self: &mut Self, s: str) u32 {
        let id = self.names.intern(s);
        while self.sym_of.len() <= id as usize {
            self.file_of.push(0);
            self.sym_of.push(0);
            self.msg_of.push(0);
        }
        return id;
    }

    /// The spelling of name `id`.
    pub(package) const fn spell(self: &Self, id: u32) str {
        return self.names.spell(id);
    }

    /// The id of file `path`, added when new: the file of the locations a tool gives its own input.
    pub(package) fn add_file(self: &mut Self, path: str) u32 {
        let n = self.name(path);
        if self.file_of[n as usize] == 0 {
            self.files.push(n);
            self.file_of[n as usize] = self.files.len() as u32;
        }
        return self.file_of[n as usize] - 1;
    }

    /// The symbol named `name`, or NONE.
    pub(package) const fn find_symbol(self: &Self, name: str) u32 {
        let n = self.names.find(name);
        if n < 0 || n as usize >= self.sym_of.len() || self.sym_of[n as usize] == 0 {
            return NONE;
        }
        return self.sym_of[n as usize] - 1;
    }

    /// A new symbol `name` of `kind` (`SK_*`) and `linkage` (`SL_*`), not yet defined; NONE when the
    /// name exists: a tool's symbol never merges with another.
    pub(package) fn add_symbol(self: &mut Self, name: str, kind: u8, linkage: u8) u32 {
        let n = self.name(name);
        if self.sym_of[n as usize] != 0 {
            return NONE;
        }
        self.syms.push(
            Sym {
                name: n,
                kind: kind,
                linkage: linkage,
                def: NONE,
                unit: NONE,
                sect: NONE,
                used: false,
                noinline: false,
                fx: FX_READ | FX_WRITE,
                alloc: if kind == SK_FUNC {
                    alloc_of(name);
                } else {
                    ALLOC_NONE;
                },
                own: false,
                ext: false,
                sig: NONE,
            },
        );
        self.sym_of[n as usize] = self.syms.len() as u32;
        return self.syms.len() as u32 - 1;
    }

    /// The symbol `name`, added as an undefined global of `kind` when new: a reference.
    pub(package) fn symbol(self: &mut Self, name: str, kind: u8) u32 {
        let s = self.find_symbol(name);
        if s != NONE {
            return s;
        }
        return self.add_symbol(name, kind, SL_GLOBAL);
    }

    /// Symbol `s` lives in the object section `spec` (its format's spelling) and is kept.
    pub(package) fn set_section(self: &mut Self, s: u32, spec: str) {
        let n = self.name(spec);
        let y = self.syms.index_mut(s as usize);
        y.sect = n;
        y.used = true;
    }

    /// The id of panic message `text`, interned.
    pub(package) fn add_message(self: &mut Self, text: str) u32 {
        let n = self.name(text);
        if self.msg_of[n as usize] == 0 {
            self.msgs.push(n);
            self.msg_of[n as usize] = self.msgs.len() as u32;
        }
        return self.msg_of[n as usize] - 1;
    }

    /// Define data symbol `sym`: `size` bytes aligned to `1 << align_log2`, starting with `init` (the
    /// rest zero), with the pointer fields `relocs` (offsets inside `size`). False when `sym` is no
    /// undefined data symbol or the bytes do not fit.
    pub(package) fn add_data(
        self: &mut Self,
        sym: u32,
        size: u32,
        align_log2: u8,
        readonly: bool,
        init: []u8,
        relocs: []Reloc,
    ) bool {
        if sym as usize >= self.syms.len() || self.syms[sym as usize].kind == SK_FUNC || self.syms[sym as usize].def != NONE || init.len() > size as usize {
            return false;
        }
        for i in 0..relocs.len() {
            if relocs[i].offset as u64 + self.ptr_bytes as u64 > size as u64 || relocs[i].sym as usize >= self.syms.len() {
                return false;
            }
        }
        self.data.push(
            DataDef {
                size: size,
                align_log2: align_log2,
                readonly: readonly,
                bytes: self.bytes.len() as u32,
                nbytes: init.len() as u32,
                relocs: self.relocs.len() as u32,
                nrelocs: relocs.len() as u32,
            },
        );
        for i in 0..init.len() {
            self.bytes.push(init[i]);
        }
        for i in 0..relocs.len() {
            self.relocs.push(relocs[i]);
        }
        self.syms.index_mut(sym as usize).def = self.data.len() as u32 - 1;
        return true;
    }

    /// Define function symbol `sym` as a compact copy of `body`. The caller verifies the body first
    /// (`lir::verify::check`); false when `sym` is no undefined function symbol.
    pub(package) fn define(self: &mut Self, sym: u32, body: &Body) bool {
        if sym as usize >= self.syms.len() || self.syms[sym as usize].kind != SK_FUNC || self.syms[sym as usize].def != NONE {
            return false;
        }
        self.bodies.push(body.compact());
        self.syms.index_mut(sym as usize).def = self.bodies.len() as u32 - 1;
        return true;
    }

    /// Remove the held bodies and data definitions (`Held`): their symbols are undefined again.
    pub(package) fn drop_held(self: &mut Self) {
        if self.held.body == NONE {
            return;
        }
        for k in 0..self.held.syms.len() {
            self.syms.index_mut(self.held.syms[k] as usize).def = NONE;
        }
        for k in 0..self.held.dsyms.len() {
            self.syms.index_mut(self.held.dsyms[k] as usize).def = NONE;
        }
        self.bodies.truncate(self.held.body as usize);
        self.data.truncate(self.held.data as usize);
        self.bytes.truncate(self.held.bytes as usize);
        self.relocs.truncate(self.held.relocs as usize);
        self.held = Held::new();
    }

    /// Data definition `d`'s initial bytes.
    pub(package) const fn data_bytes(self: &Self, d: &DataDef) Slice<u8> {
        return self.bytes[d.bytes as usize..(d.bytes + d.nbytes) as usize];
    }

    /// Move every symbol, message, file, data definition and body of `other` into this package. One name
    /// is one symbol; a name both define keeps this package's definition (an emission two emitters
    /// repeat). False, with this package incomplete, when the data models differ.
    pub(package) fn absorb(self: &mut Self, other: &Package) bool {
        if other.ptr_bytes != self.ptr_bytes {
            return false;
        }
        let mut fmap = Vector::<u32>::with_capacity(other.files.len());
        for i in 0..other.files.len() {
            fmap.push(self.add_file(other.spell(other.files[i])));
        }
        let mut mmap = Vector::<u32>::with_capacity(other.msgs.len());
        for i in 0..other.msgs.len() {
            mmap.push(self.add_message(other.spell(other.msgs[i])));
        }
        let mut smap = Vector::<u32>::with_capacity(other.syms.len());
        let mut fresh = Vector::<bool>::with_capacity(other.syms.len());
        for i in 0..other.syms.len() {
            let os = other.syms[i];
            let s = self.symbol(other.spell(os.name), os.kind);
            fresh.push(self.syms[s as usize].def == NONE);
            smap.push(s);
            if os.ext {
                self.syms.index_mut(s as usize).ext = true;
            }
            if os.sig != NONE && self.syms[s as usize].sig == NONE {
                self.decls.push(other.decls[os.sig as usize].compact());
                self.syms.index_mut(s as usize).sig = self.decls.len() as u32 - 1;
            }
        }
        for i in 0..other.syms.len() {
            let os = other.syms[i];
            if os.def == NONE || !fresh[i] {
                continue;
            }
            let s = smap[i];
            self.syms.index_mut(s as usize).linkage = os.linkage;
            self.syms.index_mut(s as usize).unit = os.unit;
            self.syms.index_mut(s as usize).used = os.used;
            self.syms.index_mut(s as usize).noinline = os.noinline;
            self.syms.index_mut(s as usize).own = os.own;
            if os.sect != NONE {
                self.syms.index_mut(s as usize).sect = self.name(other.spell(os.sect));
            }
            if os.kind == SK_FUNC {
                let mut b = other.bodies[os.def as usize].compact();
                for k in 0..b.syms.len() {
                    b.syms[k] = smap[b.syms[k] as usize];
                }
                for k in 0..b.msgs.len() {
                    b.msgs[k] = mmap[b.msgs[k] as usize];
                }
                for k in 1..b.lines.len() {
                    b.lines.index_mut(k).file = fmap[b.lines[k].file as usize];
                }
                self.bodies.push(b);
                self.syms.index_mut(s as usize).def = self.bodies.len() as u32 - 1;
            } else {
                let d = other.data[os.def as usize];
                let mut rs = Vector::<Reloc>::with_capacity(d.nrelocs as usize);
                for k in 0..d.nrelocs {
                    let r = other.relocs[(d.relocs + k) as usize];
                    rs.push(Reloc { offset: r.offset, sym: smap[r.sym as usize], addend: r.addend });
                }
                if !self.add_data(s, d.size, d.align_log2, d.readonly, other.data_bytes(&d), rs[0..rs.len()]) {
                    return false;
                }
            }
        }
        return true;
    }
}
