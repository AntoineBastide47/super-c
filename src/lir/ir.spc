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
pub(package) const OP_COUNT: u8 = 71;

/// One opcode: its text name and its operand form.
pub(package) struct OpInfo {
    pub(package) name: str<'static>,
    pub(package) form: u8,
}

pub(package) const OPS: [OpInfo; 71] = [
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
/// MEM_VOLATILE.
pub(package) const MEM_VOLATILE: u16 = 16;
/// `O_MEMCPY`: the regions may overlap (memmove).
pub(package) const MEM_OVERLAP: u16 = 1;

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
pub(package) const fn cond_name(c: u16) str<'static> {
    let t: []str<'static> = COND_NAMES;
    return t[c as usize];
}

/// The text of memory order `o`.
pub(package) const fn order_name(o: u16) str<'static> {
    let t: []str<'static> = ORDER_NAMES;
    return t[o as usize];
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
    pub(package) flags: u16, // BLOCK_COLD
}

/// The block holds only a failure path (a panic or a trap).
pub(package) const BLOCK_COLD: u16 = 1;

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
}

pub(package) const NONE: u32 = 0xFFFFFFFF;

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
    /// A naked function (`@unsafe(naked)`): its machine code is its `O_ASM` templates alone, in order,
    /// without a prologue or an epilogue.
    pub(package) naked: bool,
    cur: u32, // the block `emit` appends to
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
    /// The objects carry debug information: line tables from the locations of the bodies, their file
    /// names relative to directory `comp_dir`.
    pub(package) debug: bool,
    pub(package) comp_dir: String,
    pub(package) names: nm::Names, // file paths, symbol names and messages
    pub(package) files: Vector<u32>, // file id -> name id
    pub(package) syms: Vector<Sym>,
    pub(package) msgs: Vector<u32>, // message id -> name id
    pub(package) data: Vector<DataDef>,
    pub(package) bytes: Vector<u8>,
    pub(package) relocs: Vector<Reloc>,
    pub(package) bodies: Vector<Body>,
    // Per name id, its file, symbol and message ids plus 1 (0: none).
    file_of: Vector<u32>,
    sym_of: Vector<u32>,
    msg_of: Vector<u32>,
}

extend Package {
    /// An empty package for a data model with `ptr_bytes`-byte pointers.
    pub(package) fn new(ptr_bytes: u32) Package {
        return Package {
            ptr_bytes: ptr_bytes,
            vec_regs: 16,
            pic: false,
            debug: false,
            comp_dir: String::new(),
            names: nm::Names::with_capacity(1 << 14, 1 << 10),
            files: Vector::<u32>::new(),
            syms: Vector::<Sym>::new(),
            msgs: Vector::<u32>::new(),
            data: Vector::<DataDef>::new(),
            bytes: Vector::<u8>::new(),
            relocs: Vector::<Reloc>::new(),
            bodies: Vector::<Body>::new(),
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
                own: false,
                ext: false,
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

    // ---- Parts: a unit's LIR in the per-TU cache ----

    /// Append to `out` function symbols `roots`, defined, with every definition without a unit they reach
    /// (read-only data, sentinels) and the symbols those name, as `read_part` reads them back: the LIR of a
    /// module's own items, which a cached emission of the module restores.
    pub(package) fn write_part(self: &Self, roots: []u32, out: &mut String) {
        // The part's symbols in discovery order (their part index), and the ones it defines: a worklist
        // that each symbol joins once.
        let mut at = Map::<u32, u32>::new();
        let mut list = Vector::<u32>::new();
        let mut defs = Vector::<u32>::new();
        for i in 0..roots.len() {
            self.part_add(roots[i], true, &mut at, &mut list, &mut defs);
        }
        let mut files = Map::<u32, u32>::new();
        let mut flist = Vector::<u32>::new();
        let mut msgs = Map::<u32, u32>::new();
        let mut mlist = Vector::<u32>::new();
        let mut k: usize = 0;
        while k < defs.len() {
            let y = self.syms[defs[k] as usize];
            if y.kind == SK_FUNC {
                let b = &self.bodies[y.def as usize];
                for j in 0..b.syms.len() {
                    let s = b.syms[j];
                    let y2 = self.syms[s as usize];
                    self.part_add(s, y2.def != NONE && y2.unit == NONE, &mut at, &mut list, &mut defs);
                }
                for j in 1..b.lines.len() {
                    part_id(b.lines[j].file, &mut files, &mut flist);
                }
                for j in 0..b.msgs.len() {
                    part_id(b.msgs[j], &mut msgs, &mut mlist);
                }
            } else {
                let d = self.data[y.def as usize];
                for j in 0..d.nrelocs {
                    let s = self.relocs[(d.relocs + j) as usize].sym;
                    let y2 = self.syms[s as usize];
                    self.part_add(s, y2.def != NONE && y2.unit == NONE, &mut at, &mut list, &mut defs);
                }
            }
            k += 1;
        }
        pw32(out, list.len() as u32);
        for i in 0..list.len() {
            let y = self.syms[list[i] as usize];
            pstr(out, self.spell(y.name));
            out.push_byte(y.kind);
            out.push_byte(y.linkage);
            out.push_byte(
                ast::pick(y.used, 1u8, 0u8) | ast::pick(y.noinline, 2u8, 0u8) | ast::pick(y.own, 4u8, 0u8) | ast::pick(
                    y.ext,
                    8u8,
                    0u8,
                ),
            );
            pw32(out, y.unit);
            pstr(
                out,
                if y.sect == NONE {
                    "";
                } else {
                    self.spell(y.sect);
                },
            );
        }
        pw32(out, flist.len() as u32);
        for i in 0..flist.len() {
            pstr(out, self.spell(self.files[flist[i] as usize]));
        }
        pw32(out, mlist.len() as u32);
        for i in 0..mlist.len() {
            pstr(out, self.spell(self.msgs[mlist[i] as usize]));
        }
        pw32(out, defs.len() as u32);
        for i in 0..defs.len() {
            let y = self.syms[defs[i] as usize];
            pw32(out, *at.get(&defs[i]).unwrap());
            if y.kind == SK_FUNC {
                self.part_body(&self.bodies[y.def as usize], &at, &files, &msgs, out);
            } else {
                let d = self.data[y.def as usize];
                pw32(out, d.size);
                out.push_byte(d.align_log2);
                out.push_byte(ast::pick(d.readonly, 1u8, 0u8));
                pw32(out, d.nbytes);
                for j in 0..d.nbytes {
                    out.push_byte(self.bytes[(d.bytes + j) as usize]);
                }
                pw32(out, d.nrelocs);
                for j in 0..d.nrelocs {
                    let r = self.relocs[(d.relocs + j) as usize];
                    pw32(out, r.offset);
                    pw32(out, *at.get(&r.sym).unwrap());
                    pw64(out, r.addend as u64);
                }
            }
        }
    }

    // Symbol `s` into the part (`write_part`), with its definition when `def`.
    fn part_add(self: &Self, s: u32, def: bool, at: &mut Map<u32, u32>, list: &mut Vector<u32>, defs: &mut Vector<u32>) {
        if at.contains_key(&s) {
            return;
        }
        at.insert(s, list.len() as u32);
        list.push(s);
        if def {
            defs.push(s);
        }
    }

    // Body `b` of a part, its symbols, files and messages as part indices.
    fn part_body(
        self: &Self,
        b: &Body,
        at: &Map<u32, u32>,
        files: &Map<u32, u32>,
        msgs: &Map<u32, u32>,
        out: &mut String,
    ) {
        pw32(out, b.insts.len() as u32);
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            out.push_byte(t.op);
            out.push_byte(t.ty);
            pw32(out, t.aux);
            pw32(out, t.a);
            pw32(out, t.b);
            pw32(out, t.c);
        }
        pvec32(out, &b.locs);
        pw32(out, b.blocks.len() as u32);
        for i in 0..b.blocks.len() {
            let k = b.blocks[i];
            pw32(out, k.start);
            pw32(out, k.len);
            pw32(out, k.param_start);
            pw32(out, k.param_len);
            pw32(out, k.flags);
        }
        pw32(out, b.params.len() as u32);
        for i in 0..b.params.len() {
            out.push_byte(b.params[i]);
        }
        pvec32(out, &b.pool);
        pw32(out, b.words.len() as u32);
        for i in 0..b.words.len() {
            pw64(out, b.words[i]);
        }
        pw32(out, b.slots.len() as u32);
        for i in 0..b.slots.len() {
            pw32(out, b.slots[i].size);
            out.push_byte(b.slots[i].align_log2);
        }
        pw32(out, b.syms.len() as u32);
        for i in 0..b.syms.len() {
            pw32(out, *at.get(&b.syms[i]).unwrap());
        }
        pw32(out, b.msgs.len() as u32);
        for i in 0..b.msgs.len() {
            pw32(out, *msgs.get(&b.msgs[i]).unwrap());
        }
        // Entry 0 is "no location".
        pw32(out, b.lines.len() as u32);
        for i in 1..b.lines.len() {
            let l = b.lines[i];
            pw32(out, *files.get(&l.file).unwrap());
            pw32(out, l.line);
            pw32(out, l.col);
        }
        pvec32(out, &b.inl);
        pw32(out, b.sig);
        out.push_byte(ast::pick(b.naked, 1u8, 0u8));
    }

    /// The package of part `bytes` (`write_part`) for a data model of `ptr_bytes`-byte pointers, None when
    /// the bytes do not read as one.
    pub(package) fn read_part(bytes: str, ptr_bytes: u32) Option<Package> {
        let mut r = PartRd { b: bytes, at: 0, ok: true };
        let mut p = Package::new(ptr_bytes);
        let mut name = String::new();
        let n = r.r32();
        for _ in 0..n {
            name.clear();
            r.rstr(&mut name);
            let kind = r.r8();
            let linkage = r.r8();
            let fl = r.r8();
            let unit = r.r32();
            let s = p.add_symbol(name.as_str(), kind, linkage);
            name.clear();
            r.rstr(&mut name);
            if !r.ok || s == NONE {
                return Option::<Package>::None;
            }
            if name.len() != 0 {
                p.set_section(s, name.as_str());
            }
            let y = p.syms.index_mut(s as usize);
            y.unit = unit;
            y.used = (fl & 1) != 0;
            y.noinline = (fl & 2) != 0;
            y.own = (fl & 4) != 0;
            y.ext = (fl & 8) != 0;
        }
        let nf = r.r32();
        for _ in 0..nf {
            name.clear();
            r.rstr(&mut name);
            let _ = p.add_file(name.as_str());
        }
        let nm = r.r32();
        for _ in 0..nm {
            name.clear();
            r.rstr(&mut name);
            let _ = p.add_message(name.as_str());
        }
        let nd = r.r32();
        let mut b = Body::new();
        for _ in 0..nd {
            let s = r.r32();
            if !r.ok || s as usize >= p.syms.len() {
                return Option::<Package>::None;
            }
            if p.syms[s as usize].kind == SK_FUNC {
                if !r.body(&mut b) || !p.define(s, &b) {
                    return Option::<Package>::None;
                }
                continue;
            }
            let size = r.r32();
            let al = r.r8();
            let ro = r.r8() != 0;
            let nb = r.r32();
            let mut init = Vector::<u8>::new();
            for _ in 0..ast::pick(r.ok && nb <= size, nb, 0u32) {
                init.push(r.r8());
            }
            let nr = r.r32();
            let mut rs = Vector::<Reloc>::new();
            for _ in 0..ast::pick(r.ok && nr <= size, nr, 0u32) {
                let off = r.r32();
                let rsym = r.r32();
                rs.push(Reloc { offset: off, sym: rsym, addend: r.r64() as i64 });
            }
            if !r.ok || init.len() != nb as usize || rs.len() != nr as usize || !p.add_data(
                s,
                size,
                al,
                ro,
                init.as_slice(),
                rs.as_slice(),
            ) {
                return Option::<Package>::None;
            }
        }
        if !r.ok || r.at != r.b.len() {
            return Option::<Package>::None;
        }
        return Option::<Package>::Some(p);
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

// The part index of id `v` (a file or a message), added at the end of `list` when new.
fn part_id(v: u32, ids: &mut Map<u32, u32>, list: &mut Vector<u32>) {
    if !ids.contains_key(&v) {
        ids.insert(v, list.len() as u32);
        list.push(v);
    }
}

// A part's numbers are LEB128: most are small.
fn pw32(o: &mut String, v: u32) {
    pw64(o, v);
}

fn pw64(o: &mut String, v: u64) {
    let mut x = v;
    // At most 10 bytes: 7 bits each.
    for _ in 0..10 {
        if x < 0x80 {
            o.push_byte(x as u8);
            return;
        }
        o.push_byte(x as u8 & 0x7F | 0x80);
        x = x >> 7;
    }
}

fn pstr(o: &mut String, s: str) {
    pw32(o, s.len() as u32);
    o.push_str(s);
}

fn pvec32(o: &mut String, v: &Vector<u32>) {
    pw32(o, v.len() as u32);
    for i in 0..v.len() {
        pw32(o, v[i]);
    }
}

// A reader of a part (`Package::read_part`): `ok` goes false at the first read past the end.
struct PartRd<'a> {
    pub(package) b: str<'a>,
    pub(package) at: usize,
    pub(package) ok: bool,
}

extend<'a> PartRd<'a> {
    const fn r8(self: &mut Self) u8 {
        if !self.ok || self.at >= self.b.len() {
            self.ok = false;
            return 0;
        }
        self.at += 1;
        return self.b.byte_at(self.at - 1);
    }

    const fn r32(self: &mut Self) u32 {
        let v = self.r64();
        if v > 0xFFFFFFFF {
            self.ok = false;
        }
        return v as u32;
    }

    const fn r64(self: &mut Self) u64 {
        let mut v: u64 = 0;
        for k in 0..10u64 {
            let c = self.r8();
            v |= (c & 0x7F) as u64 << 7 * k;
            if (c & 0x80) == 0 {
                return v;
            }
        }
        self.ok = false;
        return 0;
    }

    fn rstr(self: &mut Self, out: &mut String) {
        let n = self.r32() as usize;
        if !self.ok || n > self.b.len() - self.at {
            self.ok = false;
            return;
        }
        out.push_str(self.b.slice(self.at, self.at + n));
        self.at += n;
    }

    // `n` words into `v` (cleared); every count is bounded by the bytes left.
    fn rvec32(self: &mut Self, v: &mut Vector<u32>) {
        v.truncate(0);
        let n = self.r32();
        for _ in 0..ast::pick(self.ok && n as usize <= self.b.len() - self.at, n, 0u32) {
            v.push(self.r32());
        }
    }

    // A body (`Package::part_body`) into `b`, cleared first; false when it does not read.
    fn body(self: &mut Self, b: &mut Body) bool {
        b.clear();
        let left = self.b.len() - self.at;
        let ni = self.r32();
        for _ in 0..ast::pick(ni as usize <= left, ni, 0u32) {
            let op = self.r8();
            let ty = self.r8();
            let aux = self.r32() as u16;
            let a = self.r32();
            let bb = self.r32();
            b.insts.push(Inst { op: op, ty: ty, aux: aux, a: a, b: bb, c: self.r32() });
        }
        self.rvec32(&mut b.locs);
        let nb = self.r32();
        for _ in 0..ast::pick(nb as usize <= left, nb, 0u32) {
            let start = self.r32();
            let len = self.r32();
            let ps = self.r32();
            let pl = self.r32() as u16;
            b.blocks.push(Block { start: start, len: len, param_start: ps, param_len: pl, flags: self.r32() as u16 });
        }
        let np = self.r32();
        for _ in 0..ast::pick(np as usize <= left, np, 0u32) {
            b.params.push(self.r8());
        }
        self.rvec32(&mut b.pool);
        let nw = self.r32();
        for _ in 0..ast::pick(nw as usize <= left, nw, 0u32) {
            b.words.push(self.r64());
        }
        let ns = self.r32();
        for _ in 0..ast::pick(ns as usize <= left, ns, 0u32) {
            let size = self.r32();
            b.slots.push(Slot { size: size, align_log2: self.r8() });
        }
        self.rvec32(&mut b.syms);
        self.rvec32(&mut b.msgs);
        let nl = self.r32();
        for _ in 1..ast::pick(nl as usize <= left && nl != 0, nl, 1u32) {
            let file = self.r32();
            let line = self.r32();
            b.lines.push(Loc { file: file, line: line, col: self.r32() });
        }
        self.rvec32(&mut b.inl);
        b.sig = self.r32();
        b.naked = self.r8() != 0;
        return self.ok && b.insts.len() == ni as usize && b.blocks.len() == nb as usize && b.lines.len() == ast::pick(
            nl == 0,
            1u32,
            nl,
        ) as usize;
    }
}
