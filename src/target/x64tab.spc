// The x86-64 instruction table: one row per instruction form, read by the assembler and the
// disassembler (`x64asm`) and checked against every instruction the code generator's encoder (`x64`)
// emits and every one the intrinsics (`x64intrin`) use. A row is a mnemonic (AT&T, without its size
// suffix), the opcode bytes, a mandatory prefix, the ModRM digit, the operand sizes it takes, flags, the
// VEX or EVEX form, and up to four operand kinds in Intel order (destination first). An instruction is
// a row, an operand size, a condition (for `j<cc>`, `set<cc>`, `cmov<cc>`), an EVEX mask and its
// operands; it encodes to bytes and decodes back.
import target::x64 as x;

pub(package) struct Row {
    pub(package) mn: str<'static>,
    pub(package) op: u32, // 1 to 3 opcode bytes (`0F`, `0F 38`, `0F 3A` escapes included)
    pub(package) pfx: u8, // a mandatory prefix: 0x66, 0xF2, 0xF3, 0 for none
    pub(package) dig: u8, // the ModRM.reg digit, or `D_*`
    pub(package) sz: u8, // the operand sizes it takes: a bit per size (`SB` .. `SQ`), 0 for none
    pub(package) fl: u8, // `F_*`
    pub(package) vx: u16, // the VEX or EVEX form (`VEX`, `EVEX` and their fields), 0 for none
    pub(package) ops: u32, // operand kinds, one byte each from the low byte, 0 ends
}

extend Row as Copy {}

/// ModRM.reg is an operand (a register kind of the reg field), or there is no ModRM.
pub(package) const D_REG: u8 = 0x10;
pub(package) const D_NONE: u8 = 0x20;
/// A ModRM byte the opcode fixes (`0F 01 D0`): `D_FIX | index into FIXED`.
pub(package) const D_FIX: u8 = 0x40;

/// Operand sizes.
pub(package) const SB: u8 = 1;
pub(package) const SW: u8 = 2;
pub(package) const SL: u8 = 4;
pub(package) const SQ: u8 = 8;
pub(package) const SWLQ: u8 = 14;
pub(package) const SLQ: u8 = 12;

/// Flags.
pub(package) const F_D64: u8 = 1; // 64 bits by default (push, pop, call, jmp): no REX.W
pub(package) const F_NOSFX: u8 = 2; // the mnemonic takes no size suffix
pub(package) const F_CC: u8 = 4; // the condition (the mnemonic's tail) adds to the opcode's low nibble
pub(package) const F_OR: u8 = 8; // the register adds to the opcode's low 3 bits (`+r`)
pub(package) const F_LOCK: u8 = 64; // takes a `lock` prefix

/// The VEX and EVEX forms: the prefix, its W and L fields (the map is the opcode's escape, pp the
/// mandatory prefix), the EVEX 8-bit displacement's scale, masking, and the other operand orders LLVM
/// takes for a 2-byte VEX prefix.
pub(package) const VEX: u16 = 1;
pub(package) const EVEX: u16 = 2;
pub(package) const W1: u16 = 4;
/// The 8-bit displacement's scale (N): the vector length shifted right by 0 to 3 (`N0` .. `N3`), or 1,
/// 2, 4, 8, 16, 32 bytes (`N4` .. `N9`).
pub(package) const N1: u16 = 1 << 3;
pub(package) const N2: u16 = 2 << 3;
pub(package) const N3: u16 = 3 << 3;
pub(package) const N4: u16 = 4 << 3;
pub(package) const N5: u16 = 5 << 3;
pub(package) const N6: u16 = 6 << 3;
pub(package) const N7: u16 = 7 << 3;
pub(package) const N8: u16 = 8 << 3;
pub(package) const N9: u16 = 9 << 3;
pub(package) const MK: u16 = 1 << 7; // takes a mask
pub(package) const MZ: u16 = 1 << 8; // takes zeroing under a mask
pub(package) const MR: u16 = 1 << 9; // needs a mask
pub(package) const L1: u16 = 1 << 10; // 256 bits
pub(package) const L2: u16 = 2 << 10; // 512 bits
/// The two sources (vvvv and ModRM.rm) swap when only rm needs REX.B: a 2-byte VEX prefix; `SWPC` for
/// a compare whose predicate (`imm & 7`) is 0, 3, 4 or 7 only.
pub(package) const SWP: u16 = 1 << 12;
pub(package) const SWPC: u16 = 1 << 13;
/// A register-to-register move the next row also encodes, with the operands in the other ModRM fields:
/// that row takes it when this one would need the 3-byte VEX prefix and that one not.
pub(package) const MV: u16 = 1 << 14;

/// Operand kinds.
pub(package) struct K {}

extend K {
    pub(package) const R: u8 = 1; // a general register of the operand size, in ModRM.reg
    pub(package) const RM: u8 = 2; // a general register of the operand size or memory, in ModRM.rm
    pub(package) const M: u8 = 3; // memory, in ModRM.rm
    pub(package) const O: u8 = 4; // a general register of the operand size in the opcode (`+r`)
    pub(package) const RM8: u8 = 5; // a byte register or memory
    pub(package) const RM16: u8 = 6;
    pub(package) const RM32: u8 = 7;
    pub(package) const R32: u8 = 8; // a 32-bit register in ModRM.reg
    pub(package) const X: u8 = 9; // an xmm register in ModRM.reg
    pub(package) const XM: u8 = 10; // an xmm register or memory in ModRM.rm
    pub(package) const XR: u8 = 11; // an xmm register in ModRM.rm
    pub(package) const Y: u8 = 12; // a ymm register in ModRM.reg
    pub(package) const YM: u8 = 13;
    pub(package) const Z: u8 = 14; // a zmm register in ModRM.reg
    pub(package) const ZM: u8 = 15;
    pub(package) const I8: u8 = 16; // an 8-bit immediate
    pub(package) const IS8: u8 = 17; // an 8-bit immediate sign-extended to the operand size
    pub(package) const IZ: u8 = 18; // an immediate of the operand size, 32 bits for 64 (sign-extended)
    pub(package) const I64: u8 = 19; // a 64-bit immediate
    pub(package) const CL: u8 = 20; // `%cl`
    pub(package) const ONE: u8 = 21; // `$1`
    pub(package) const ACC: u8 = 22; // the accumulator of the operand size
    pub(package) const REL8: u8 = 23; // a branch target
    pub(package) const REL32: u8 = 24;
    pub(package) const IND: u8 = 25; // `*` and a 64-bit register or memory: an indirect branch target
    pub(package) const XV: u8 = 26; // an xmm register in VEX.vvvv
    pub(package) const YV: u8 = 27;
    pub(package) const ZV: u8 = 28;
    pub(package) const YR: u8 = 29; // a ymm register in ModRM.rm
    pub(package) const ZR: u8 = 30;
    pub(package) const KR: u8 = 31; // a mask register in ModRM.reg
    pub(package) const KRM: u8 = 32; // a mask register in ModRM.rm
    pub(package) const KV: u8 = 33; // a mask register in VEX.vvvv
    pub(package) const R64: u8 = 34; // a 64-bit register in ModRM.reg
    pub(package) const RR32: u8 = 35; // a 32-bit register in ModRM.rm
    pub(package) const RR64: u8 = 36;
    pub(package) const RM64: u8 = 37; // a 64-bit register or memory
    pub(package) const XI4: u8 = 38; // an xmm register in the immediate's high 4 bits
    pub(package) const YI4: u8 = 39;
    pub(package) const X0: u8 = 40; // `%xmm0`, implied
    pub(package) const VSX: u8 = 41; // memory with an xmm index (VSIB)
    pub(package) const VSY: u8 = 42;
    pub(package) const VSZ: u8 = 43;
}

const fn r(mn: str<'static>, op: u32, pfx: u8, dig: u8, sz: u8, fl: u8, ops: u32) Row {
    return Row { mn: mn, op: op, pfx: pfx, dig: dig, sz: sz, fl: fl, vx: 0, ops: ops };
}

// A VEX or EVEX row.
const fn v(mn: str<'static>, op: u32, pfx: u8, dig: u8, vx: u16, ops: u32) Row {
    return Row { mn: mn, op: op, pfx: pfx, dig: dig, sz: 0, fl: F_NOSFX, vx: vx, ops: ops };
}

pub(package) const fn k1(a: u8) u32 {
    return a;
}

pub(package) const fn k2(a: u8, b: u8) u32 {
    return a as u32 | b as u32 << 8;
}

pub(package) const fn k3(a: u8, b: u8, c: u8) u32 {
    return k2(a, b) | c as u32 << 16;
}

pub(package) const fn k4(a: u8, b: u8, c: u8, d: u8) u32 {
    return k3(a, b, c) | d as u32 << 24;
}

/// Operand kind `i` of `ops`, 0 past the last.
pub(package) const fn kind_at(ops: u32, i: u32) u8 {
    return (ops >> i * 8 & 0xFF) as u8;
}

// The fixed ModRM bytes of the `D_FIX` rows.
const FIXED: [u8; 6] = [0xD0, 0xF9, 0xF0, 0xE8, 0xF8, 0x00];

/// The fixed ModRM byte of a `D_FIX` row.
pub(package) const fn fixed_modrm(dig: u8) u8 {
    let f: []u8 = FIXED;
    return f[(dig & 0xF) as usize];
}

const D: u8 = D_REG;
const N: u8 = D_NONE;

pub(package) const ROWS: [Row; 1037] = [
    r("nop", 0x90, 0, N, 0, F_NOSFX, 0),
    r("add", 0x0, 0, D, SB, F_LOCK, k2(K::RM, K::R)),
    r("add", 0x1, 0, D, SWLQ, F_LOCK, k2(K::RM, K::R)),
    r("add", 0x2, 0, D, SB, 0, k2(K::R, K::RM)),
    r("add", 0x3, 0, D, SWLQ, 0, k2(K::R, K::RM)),
    r("add", 0x83, 0, 0, SWLQ, F_LOCK, k2(K::RM, K::IS8)),
    r("add", 0x4, 0, N, SB, 0, k2(K::ACC, K::I8)),
    r("add", 0x5, 0, N, SWLQ, 0, k2(K::ACC, K::IZ)),
    r("add", 0x80, 0, 0, SB, F_LOCK, k2(K::RM, K::I8)),
    r("add", 0x81, 0, 0, SWLQ, F_LOCK, k2(K::RM, K::IZ)),
    r("or", 0x8, 0, D, SB, F_LOCK, k2(K::RM, K::R)),
    r("or", 0x9, 0, D, SWLQ, F_LOCK, k2(K::RM, K::R)),
    r("or", 0xA, 0, D, SB, 0, k2(K::R, K::RM)),
    r("or", 0xB, 0, D, SWLQ, 0, k2(K::R, K::RM)),
    r("or", 0x83, 0, 1, SWLQ, F_LOCK, k2(K::RM, K::IS8)),
    r("or", 0xC, 0, N, SB, 0, k2(K::ACC, K::I8)),
    r("or", 0xD, 0, N, SWLQ, 0, k2(K::ACC, K::IZ)),
    r("or", 0x80, 0, 1, SB, F_LOCK, k2(K::RM, K::I8)),
    r("or", 0x81, 0, 1, SWLQ, F_LOCK, k2(K::RM, K::IZ)),
    r("adc", 0x10, 0, D, SB, F_LOCK, k2(K::RM, K::R)),
    r("adc", 0x11, 0, D, SWLQ, F_LOCK, k2(K::RM, K::R)),
    r("adc", 0x12, 0, D, SB, 0, k2(K::R, K::RM)),
    r("adc", 0x13, 0, D, SWLQ, 0, k2(K::R, K::RM)),
    r("adc", 0x83, 0, 2, SWLQ, F_LOCK, k2(K::RM, K::IS8)),
    r("adc", 0x14, 0, N, SB, 0, k2(K::ACC, K::I8)),
    r("adc", 0x15, 0, N, SWLQ, 0, k2(K::ACC, K::IZ)),
    r("adc", 0x80, 0, 2, SB, F_LOCK, k2(K::RM, K::I8)),
    r("adc", 0x81, 0, 2, SWLQ, F_LOCK, k2(K::RM, K::IZ)),
    r("sbb", 0x18, 0, D, SB, F_LOCK, k2(K::RM, K::R)),
    r("sbb", 0x19, 0, D, SWLQ, F_LOCK, k2(K::RM, K::R)),
    r("sbb", 0x1A, 0, D, SB, 0, k2(K::R, K::RM)),
    r("sbb", 0x1B, 0, D, SWLQ, 0, k2(K::R, K::RM)),
    r("sbb", 0x83, 0, 3, SWLQ, F_LOCK, k2(K::RM, K::IS8)),
    r("sbb", 0x1C, 0, N, SB, 0, k2(K::ACC, K::I8)),
    r("sbb", 0x1D, 0, N, SWLQ, 0, k2(K::ACC, K::IZ)),
    r("sbb", 0x80, 0, 3, SB, F_LOCK, k2(K::RM, K::I8)),
    r("sbb", 0x81, 0, 3, SWLQ, F_LOCK, k2(K::RM, K::IZ)),
    r("and", 0x20, 0, D, SB, F_LOCK, k2(K::RM, K::R)),
    r("and", 0x21, 0, D, SWLQ, F_LOCK, k2(K::RM, K::R)),
    r("and", 0x22, 0, D, SB, 0, k2(K::R, K::RM)),
    r("and", 0x23, 0, D, SWLQ, 0, k2(K::R, K::RM)),
    r("and", 0x83, 0, 4, SWLQ, F_LOCK, k2(K::RM, K::IS8)),
    r("and", 0x24, 0, N, SB, 0, k2(K::ACC, K::I8)),
    r("and", 0x25, 0, N, SWLQ, 0, k2(K::ACC, K::IZ)),
    r("and", 0x80, 0, 4, SB, F_LOCK, k2(K::RM, K::I8)),
    r("and", 0x81, 0, 4, SWLQ, F_LOCK, k2(K::RM, K::IZ)),
    r("sub", 0x28, 0, D, SB, F_LOCK, k2(K::RM, K::R)),
    r("sub", 0x29, 0, D, SWLQ, F_LOCK, k2(K::RM, K::R)),
    r("sub", 0x2A, 0, D, SB, 0, k2(K::R, K::RM)),
    r("sub", 0x2B, 0, D, SWLQ, 0, k2(K::R, K::RM)),
    r("sub", 0x83, 0, 5, SWLQ, F_LOCK, k2(K::RM, K::IS8)),
    r("sub", 0x2C, 0, N, SB, 0, k2(K::ACC, K::I8)),
    r("sub", 0x2D, 0, N, SWLQ, 0, k2(K::ACC, K::IZ)),
    r("sub", 0x80, 0, 5, SB, F_LOCK, k2(K::RM, K::I8)),
    r("sub", 0x81, 0, 5, SWLQ, F_LOCK, k2(K::RM, K::IZ)),
    r("xor", 0x30, 0, D, SB, F_LOCK, k2(K::RM, K::R)),
    r("xor", 0x31, 0, D, SWLQ, F_LOCK, k2(K::RM, K::R)),
    r("xor", 0x32, 0, D, SB, 0, k2(K::R, K::RM)),
    r("xor", 0x33, 0, D, SWLQ, 0, k2(K::R, K::RM)),
    r("xor", 0x83, 0, 6, SWLQ, F_LOCK, k2(K::RM, K::IS8)),
    r("xor", 0x34, 0, N, SB, 0, k2(K::ACC, K::I8)),
    r("xor", 0x35, 0, N, SWLQ, 0, k2(K::ACC, K::IZ)),
    r("xor", 0x80, 0, 6, SB, F_LOCK, k2(K::RM, K::I8)),
    r("xor", 0x81, 0, 6, SWLQ, F_LOCK, k2(K::RM, K::IZ)),
    r("cmp", 0x38, 0, D, SB, 0, k2(K::RM, K::R)),
    r("cmp", 0x39, 0, D, SWLQ, 0, k2(K::RM, K::R)),
    r("cmp", 0x3A, 0, D, SB, 0, k2(K::R, K::RM)),
    r("cmp", 0x3B, 0, D, SWLQ, 0, k2(K::R, K::RM)),
    r("cmp", 0x83, 0, 7, SWLQ, 0, k2(K::RM, K::IS8)),
    r("cmp", 0x3C, 0, N, SB, 0, k2(K::ACC, K::I8)),
    r("cmp", 0x3D, 0, N, SWLQ, 0, k2(K::ACC, K::IZ)),
    r("cmp", 0x80, 0, 7, SB, 0, k2(K::RM, K::I8)),
    r("cmp", 0x81, 0, 7, SWLQ, 0, k2(K::RM, K::IZ)),
    r("test", 0x84, 0, D, SB, 0, k2(K::RM, K::R)),
    r("test", 0x85, 0, D, SWLQ, 0, k2(K::RM, K::R)),
    r("test", 0xA8, 0, N, SB, 0, k2(K::ACC, K::I8)),
    r("test", 0xA9, 0, N, SWLQ, 0, k2(K::ACC, K::IZ)),
    r("test", 0xF6, 0, 0, SB, 0, k2(K::RM, K::I8)),
    r("test", 0xF7, 0, 0, SWLQ, 0, k2(K::RM, K::IZ)),
    r("mov", 0x88, 0, D, SB, 0, k2(K::RM, K::R)),
    r("mov", 0x89, 0, D, SWLQ, 0, k2(K::RM, K::R)),
    r("mov", 0x8A, 0, D, SB, 0, k2(K::R, K::RM)),
    r("mov", 0x8B, 0, D, SWLQ, 0, k2(K::R, K::RM)),
    r("mov", 0xB0, 0, N, SB, F_OR, k2(K::O, K::I8)),
    r("mov", 0xB8, 0, N, SW | SL, F_OR, k2(K::O, K::IZ)),
    r("mov", 0xC6, 0, 0, SB, 0, k2(K::RM, K::I8)),
    r("mov", 0xC7, 0, 0, SWLQ, 0, k2(K::RM, K::IZ)),
    r("movabs", 0xB8, 0, N, SQ, F_OR, k2(K::O, K::I64)),
    r("mov", 0xB8, 0, N, SQ, F_OR, k2(K::O, K::I64)),
    r("lea", 0x8D, 0, D, SWLQ, 0, k2(K::R, K::M)),
    r("movzb", 0xFB6, 0, D, SWLQ, 0, k2(K::R, K::RM8)),
    r("movzw", 0xFB7, 0, D, SLQ, 0, k2(K::R, K::RM16)),
    r("movsb", 0xFBE, 0, D, SWLQ, 0, k2(K::R, K::RM8)),
    r("movsw", 0xFBF, 0, D, SLQ, 0, k2(K::R, K::RM16)),
    r("movsl", 0x63, 0, D, SQ, 0, k2(K::R, K::RM32)),
    r("inc", 0xFE, 0, 0, SB, F_LOCK, k1(K::RM)),
    r("inc", 0xFF, 0, 0, SWLQ, F_LOCK, k1(K::RM)),
    r("dec", 0xFE, 0, 1, SB, F_LOCK, k1(K::RM)),
    r("dec", 0xFF, 0, 1, SWLQ, F_LOCK, k1(K::RM)),
    r("not", 0xF6, 0, 2, SB, F_LOCK, k1(K::RM)),
    r("not", 0xF7, 0, 2, SWLQ, F_LOCK, k1(K::RM)),
    r("neg", 0xF6, 0, 3, SB, F_LOCK, k1(K::RM)),
    r("neg", 0xF7, 0, 3, SWLQ, F_LOCK, k1(K::RM)),
    r("mul", 0xF6, 0, 4, SB, 0, k1(K::RM)),
    r("mul", 0xF7, 0, 4, SWLQ, 0, k1(K::RM)),
    r("imul", 0xF6, 0, 5, SB, 0, k1(K::RM)),
    r("imul", 0xF7, 0, 5, SWLQ, 0, k1(K::RM)),
    r("div", 0xF6, 0, 6, SB, 0, k1(K::RM)),
    r("div", 0xF7, 0, 6, SWLQ, 0, k1(K::RM)),
    r("idiv", 0xF6, 0, 7, SB, 0, k1(K::RM)),
    r("idiv", 0xF7, 0, 7, SWLQ, 0, k1(K::RM)),
    r("imul", 0xFAF, 0, D, SWLQ, 0, k2(K::R, K::RM)),
    r("imul", 0x6B, 0, D, SWLQ, 0, k3(K::R, K::RM, K::IS8)),
    r("imul", 0x69, 0, D, SWLQ, 0, k3(K::R, K::RM, K::IZ)),
    r("rol", 0xD0, 0, 0, SB, 0, k2(K::RM, K::ONE)),
    r("rol", 0xD1, 0, 0, SWLQ, 0, k2(K::RM, K::ONE)),
    r("rol", 0xD2, 0, 0, SB, 0, k2(K::RM, K::CL)),
    r("rol", 0xD3, 0, 0, SWLQ, 0, k2(K::RM, K::CL)),
    r("rol", 0xC0, 0, 0, SB, 0, k2(K::RM, K::I8)),
    r("rol", 0xC1, 0, 0, SWLQ, 0, k2(K::RM, K::I8)),
    r("ror", 0xD0, 0, 1, SB, 0, k2(K::RM, K::ONE)),
    r("ror", 0xD1, 0, 1, SWLQ, 0, k2(K::RM, K::ONE)),
    r("ror", 0xD2, 0, 1, SB, 0, k2(K::RM, K::CL)),
    r("ror", 0xD3, 0, 1, SWLQ, 0, k2(K::RM, K::CL)),
    r("ror", 0xC0, 0, 1, SB, 0, k2(K::RM, K::I8)),
    r("ror", 0xC1, 0, 1, SWLQ, 0, k2(K::RM, K::I8)),
    r("rcl", 0xD0, 0, 2, SB, 0, k2(K::RM, K::ONE)),
    r("rcl", 0xD1, 0, 2, SWLQ, 0, k2(K::RM, K::ONE)),
    r("rcl", 0xD2, 0, 2, SB, 0, k2(K::RM, K::CL)),
    r("rcl", 0xD3, 0, 2, SWLQ, 0, k2(K::RM, K::CL)),
    r("rcl", 0xC0, 0, 2, SB, 0, k2(K::RM, K::I8)),
    r("rcl", 0xC1, 0, 2, SWLQ, 0, k2(K::RM, K::I8)),
    r("rcr", 0xD0, 0, 3, SB, 0, k2(K::RM, K::ONE)),
    r("rcr", 0xD1, 0, 3, SWLQ, 0, k2(K::RM, K::ONE)),
    r("rcr", 0xD2, 0, 3, SB, 0, k2(K::RM, K::CL)),
    r("rcr", 0xD3, 0, 3, SWLQ, 0, k2(K::RM, K::CL)),
    r("rcr", 0xC0, 0, 3, SB, 0, k2(K::RM, K::I8)),
    r("rcr", 0xC1, 0, 3, SWLQ, 0, k2(K::RM, K::I8)),
    r("shl", 0xD0, 0, 4, SB, 0, k2(K::RM, K::ONE)),
    r("shl", 0xD1, 0, 4, SWLQ, 0, k2(K::RM, K::ONE)),
    r("shl", 0xD2, 0, 4, SB, 0, k2(K::RM, K::CL)),
    r("shl", 0xD3, 0, 4, SWLQ, 0, k2(K::RM, K::CL)),
    r("shl", 0xC0, 0, 4, SB, 0, k2(K::RM, K::I8)),
    r("shl", 0xC1, 0, 4, SWLQ, 0, k2(K::RM, K::I8)),
    r("sal", 0xD0, 0, 4, SB, 0, k2(K::RM, K::ONE)),
    r("sal", 0xD1, 0, 4, SWLQ, 0, k2(K::RM, K::ONE)),
    r("sal", 0xD2, 0, 4, SB, 0, k2(K::RM, K::CL)),
    r("sal", 0xD3, 0, 4, SWLQ, 0, k2(K::RM, K::CL)),
    r("sal", 0xC0, 0, 4, SB, 0, k2(K::RM, K::I8)),
    r("sal", 0xC1, 0, 4, SWLQ, 0, k2(K::RM, K::I8)),
    r("shr", 0xD0, 0, 5, SB, 0, k2(K::RM, K::ONE)),
    r("shr", 0xD1, 0, 5, SWLQ, 0, k2(K::RM, K::ONE)),
    r("shr", 0xD2, 0, 5, SB, 0, k2(K::RM, K::CL)),
    r("shr", 0xD3, 0, 5, SWLQ, 0, k2(K::RM, K::CL)),
    r("shr", 0xC0, 0, 5, SB, 0, k2(K::RM, K::I8)),
    r("shr", 0xC1, 0, 5, SWLQ, 0, k2(K::RM, K::I8)),
    r("sar", 0xD0, 0, 7, SB, 0, k2(K::RM, K::ONE)),
    r("sar", 0xD1, 0, 7, SWLQ, 0, k2(K::RM, K::ONE)),
    r("sar", 0xD2, 0, 7, SB, 0, k2(K::RM, K::CL)),
    r("sar", 0xD3, 0, 7, SWLQ, 0, k2(K::RM, K::CL)),
    r("sar", 0xC0, 0, 7, SB, 0, k2(K::RM, K::I8)),
    r("sar", 0xC1, 0, 7, SWLQ, 0, k2(K::RM, K::I8)),
    r("shld", 0xFA4, 0, D, SWLQ, 0, k3(K::RM, K::R, K::I8)),
    r("shld", 0xFA5, 0, D, SWLQ, 0, k3(K::RM, K::R, K::CL)),
    r("shrd", 0xFAC, 0, D, SWLQ, 0, k3(K::RM, K::R, K::I8)),
    r("shrd", 0xFAD, 0, D, SWLQ, 0, k3(K::RM, K::R, K::CL)),
    r("cwtd", 0x99, 0, N, SW, F_NOSFX, 0),
    r("cltd", 0x99, 0, N, SL, F_NOSFX, 0),
    r("cqto", 0x99, 0, N, SQ, F_NOSFX, 0),
    r("cbtw", 0x98, 0, N, SW, F_NOSFX, 0),
    r("cwtl", 0x98, 0, N, SL, F_NOSFX, 0),
    r("cltq", 0x98, 0, N, SQ, F_NOSFX, 0),
    r("set", 0xF90, 0, 0, SB, F_CC | F_NOSFX, k1(K::RM)),
    r("cmov", 0xF40, 0, D, SWLQ, F_CC, k2(K::R, K::RM)),
    r("j", 0x70, 0, N, 0, F_CC | F_NOSFX, k1(K::REL8)),
    r("j", 0xF80, 0, N, 0, F_CC | F_NOSFX, k1(K::REL32)),
    r("jmp", 0xEB, 0, N, 0, F_NOSFX, k1(K::REL8)),
    r("jmp", 0xE9, 0, N, 0, F_NOSFX, k1(K::REL32)),
    r("jmp", 0xFF, 0, 4, SQ, F_D64, k1(K::IND)),
    r("call", 0xE8, 0, N, 0, F_NOSFX, k1(K::REL32)),
    r("call", 0xFF, 0, 2, SQ, F_D64, k1(K::IND)),
    r("pause", 0x90, 0xF3, N, 0, F_NOSFX, 0),
    r("tzcnt", 0xFBC, 0xF3, D, SWLQ, 0, k2(K::R, K::RM)),
    r("lzcnt", 0xFBD, 0xF3, D, SWLQ, 0, k2(K::R, K::RM)),
    r("popcnt", 0xFB8, 0xF3, D, SWLQ, 0, k2(K::R, K::RM)),
    r("bsf", 0xFBC, 0, D, SWLQ, 0, k2(K::R, K::RM)),
    r("bsr", 0xFBD, 0, D, SWLQ, 0, k2(K::R, K::RM)),
    r("bt", 0xFA3, 0, D, SWLQ, 0, k2(K::RM, K::R)),
    r("bt", 0xFBA, 0, 4, SWLQ, 0, k2(K::RM, K::I8)),
    r("bts", 0xFAB, 0, D, SWLQ, F_LOCK, k2(K::RM, K::R)),
    r("bts", 0xFBA, 0, 5, SWLQ, F_LOCK, k2(K::RM, K::I8)),
    r("btr", 0xFB3, 0, D, SWLQ, F_LOCK, k2(K::RM, K::R)),
    r("btr", 0xFBA, 0, 6, SWLQ, F_LOCK, k2(K::RM, K::I8)),
    r("btc", 0xFBB, 0, D, SWLQ, F_LOCK, k2(K::RM, K::R)),
    r("btc", 0xFBA, 0, 7, SWLQ, F_LOCK, k2(K::RM, K::I8)),
    r("bswap", 0xFC8, 0, N, SLQ, F_OR, k1(K::O)),
    r("xchg", 0x90, 0, N, SWLQ, F_OR, k2(K::O, K::ACC)),
    r("xchg", 0x90, 0, N, SWLQ, F_OR, k2(K::ACC, K::O)),
    r("xchg", 0x86, 0, D, SB, 0, k2(K::R, K::RM)),
    r("xchg", 0x87, 0, D, SWLQ, 0, k2(K::R, K::RM)),
    r("xchg", 0x86, 0, D, SB, F_LOCK, k2(K::RM, K::R)),
    r("xchg", 0x87, 0, D, SWLQ, F_LOCK, k2(K::RM, K::R)),
    r("xadd", 0xFC0, 0, D, SB, F_LOCK, k2(K::RM, K::R)),
    r("xadd", 0xFC1, 0, D, SWLQ, F_LOCK, k2(K::RM, K::R)),
    r("cmpxchg", 0xFB0, 0, D, SB, F_LOCK, k2(K::RM, K::R)),
    r("cmpxchg", 0xFB1, 0, D, SWLQ, F_LOCK, k2(K::RM, K::R)),
    r("push", 0x50, 0, N, SW | SQ, F_D64 | F_OR, k1(K::O)),
    r("push", 0xFF, 0, 6, SW | SQ, F_D64, k1(K::RM)),
    r("push", 0x6A, 0, N, SQ, F_D64, k1(K::IS8)),
    r("push", 0x68, 0, N, SQ, F_D64, k1(K::IZ)),
    r("pop", 0x58, 0, N, SW | SQ, F_D64 | F_OR, k1(K::O)),
    r("pop", 0x8F, 0, 0, SW | SQ, F_D64, k1(K::RM)),
    r("ret", 0xC3, 0, N, SQ, F_D64, 0),
    r("leave", 0xC9, 0, N, SQ, F_D64, 0),
    r("nop", 0xF1F, 0, 0, SW | SL, 0, k1(K::RM)),
    r("int3", 0xCC, 0, N, 0, F_NOSFX, 0),
    r("hlt", 0xF4, 0, N, 0, F_NOSFX, 0),
    r("ud2", 0xF0B, 0, N, 0, F_NOSFX, 0),
    r("cpuid", 0xFA2, 0, N, 0, F_NOSFX, 0),
    r("rdtsc", 0xF31, 0, N, 0, F_NOSFX, 0),
    r("syscall", 0xF05, 0, N, 0, F_NOSFX, 0),
    r("xgetbv", 0xF01, 0, D_FIX | 0, 0, F_NOSFX, 0),
    r("rdtscp", 0xF01, 0, D_FIX | 1, 0, F_NOSFX, 0),
    r("mfence", 0xFAE, 0, D_FIX | 2, 0, F_NOSFX, 0),
    r("lfence", 0xFAE, 0, D_FIX | 3, 0, F_NOSFX, 0),
    r("sfence", 0xFAE, 0, D_FIX | 4, 0, F_NOSFX, 0),
    r("ldmxcsr", 0xFAE, 0, 2, 0, F_NOSFX, k1(K::M)),
    r("stmxcsr", 0xFAE, 0, 3, 0, F_NOSFX, k1(K::M)),
    r("fldcw", 0xD9, 0, 5, 0, F_NOSFX, k1(K::M)),
    r("fnstcw", 0xD9, 0, 7, 0, F_NOSFX, k1(K::M)),
    r("movaps", 0xF28, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("movaps", 0xF29, 0, D, 0, F_NOSFX, k2(K::XM, K::X)),
    r("movups", 0xF10, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("movups", 0xF11, 0, D, 0, F_NOSFX, k2(K::XM, K::X)),
    r("movapd", 0xF28, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("movapd", 0xF29, 0x66, D, 0, F_NOSFX, k2(K::XM, K::X)),
    r("movupd", 0xF10, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("movupd", 0xF11, 0x66, D, 0, F_NOSFX, k2(K::XM, K::X)),
    r("movdqa", 0xF6F, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("movdqa", 0xF7F, 0x66, D, 0, F_NOSFX, k2(K::XM, K::X)),
    r("movdqu", 0xF6F, 0xF3, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("movdqu", 0xF7F, 0xF3, D, 0, F_NOSFX, k2(K::XM, K::X)),
    r("movss", 0xF10, 0xF3, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("movss", 0xF11, 0xF3, D, 0, F_NOSFX, k2(K::XM, K::X)),
    r("movsd", 0xF10, 0xF2, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("movsd", 0xF11, 0xF2, D, 0, F_NOSFX, k2(K::XM, K::X)),
    r("movq", 0xF7E, 0xF3, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("movq", 0xFD6, 0x66, D, 0, F_NOSFX, k2(K::XM, K::X)),
    r("movd", 0xF6E, 0x66, D, SL, F_NOSFX, k2(K::X, K::RM)),
    r("movd", 0xF7E, 0x66, D, SL, F_NOSFX, k2(K::RM, K::X)),
    r("movq", 0xF6E, 0x66, D, SQ, F_NOSFX, k2(K::X, K::RM)),
    r("movq", 0xF7E, 0x66, D, SQ, F_NOSFX, k2(K::RM, K::X)),
    r("addss", 0xF58, 0xF3, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("addsd", 0xF58, 0xF2, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("addps", 0xF58, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("addpd", 0xF58, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("mulss", 0xF59, 0xF3, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("mulsd", 0xF59, 0xF2, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("mulps", 0xF59, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("mulpd", 0xF59, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("subss", 0xF5C, 0xF3, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("subsd", 0xF5C, 0xF2, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("subps", 0xF5C, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("subpd", 0xF5C, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("minss", 0xF5D, 0xF3, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("minsd", 0xF5D, 0xF2, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("minps", 0xF5D, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("minpd", 0xF5D, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("divss", 0xF5E, 0xF3, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("divsd", 0xF5E, 0xF2, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("divps", 0xF5E, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("divpd", 0xF5E, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("maxss", 0xF5F, 0xF3, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("maxsd", 0xF5F, 0xF2, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("maxps", 0xF5F, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("maxpd", 0xF5F, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("sqrtss", 0xF51, 0xF3, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("sqrtsd", 0xF51, 0xF2, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("sqrtps", 0xF51, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("sqrtpd", 0xF51, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("andps", 0xF54, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("andpd", 0xF54, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("andnps", 0xF55, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("andnpd", 0xF55, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("orps", 0xF56, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("orpd", 0xF56, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("xorps", 0xF57, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("xorpd", 0xF57, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("cvtss2sd", 0xF5A, 0xF3, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("cvtsd2ss", 0xF5A, 0xF2, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("cvtps2pd", 0xF5A, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("cvtpd2ps", 0xF5A, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("cvtsi2ss", 0xF2A, 0xF3, D, SLQ, 0, k2(K::X, K::RM)),
    r("cvtsi2sd", 0xF2A, 0xF2, D, SLQ, 0, k2(K::X, K::RM)),
    r("cvttss2si", 0xF2C, 0xF3, D, SLQ, F_NOSFX, k2(K::R, K::XM)),
    r("cvttsd2si", 0xF2C, 0xF2, D, SLQ, F_NOSFX, k2(K::R, K::XM)),
    r("cvtss2si", 0xF2D, 0xF3, D, SLQ, F_NOSFX, k2(K::R, K::XM)),
    r("cvtsd2si", 0xF2D, 0xF2, D, SLQ, F_NOSFX, k2(K::R, K::XM)),
    r("ucomiss", 0xF2E, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("ucomisd", 0xF2E, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("comiss", 0xF2F, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("comisd", 0xF2F, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("movmskps", 0xF50, 0, D, 0, F_NOSFX, k2(K::R32, K::XR)),
    r("movmskpd", 0xF50, 0x66, D, 0, F_NOSFX, k2(K::R32, K::XR)),
    r("pmovmskb", 0xFD7, 0x66, D, 0, F_NOSFX, k2(K::R32, K::XR)),
    r("pxor", 0xFEF, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("por", 0xFEB, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pand", 0xFDB, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pandn", 0xFDF, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("paddb", 0xFFC, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("paddw", 0xFFD, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("paddd", 0xFFE, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("paddq", 0xFD4, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psubb", 0xFF8, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psubw", 0xFF9, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psubd", 0xFFA, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psubq", 0xFFB, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pcmpeqb", 0xF74, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pcmpeqw", 0xF75, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pcmpeqd", 0xF76, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("punpcklqdq", 0xF6C, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("punpckhqdq", 0xF6D, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pshufd", 0xF70, 0x66, D, 0, F_NOSFX, k3(K::X, K::XM, K::I8)),
    // The AVX-512 forms the code generator's 64-byte vectors take beyond the intrinsics' rows below.
    v("vpandd", 0xFDB, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpxord", 0xFEF, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpternlogq", 0xF3A25, 0x66, D, EVEX | W1 | L2 | MK | MZ, k4(K::Z, K::ZV, K::ZM, K::I8)),
    v("vxorps", 0xF57, 0, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vxorpd", 0xF57, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpmovm2b", 0xF3828, 0xF3, D, EVEX | L2, k2(K::Z, K::KRM)),
    v("vpmovm2w", 0xF3828, 0xF3, D, EVEX | W1 | L2, k2(K::Z, K::KRM)),
    v("vpmovm2d", 0xF3838, 0xF3, D, EVEX | L2, k2(K::Z, K::KRM)),
    v("vpmovm2q", 0xF3838, 0xF3, D, EVEX | W1 | L2, k2(K::Z, K::KRM)),
    v("vpbroadcastb", 0xF387A, 0x66, D, EVEX | L2 | MK | MZ, k2(K::Z, K::RR32)),
    v("vpbroadcastw", 0xF387B, 0x66, D, EVEX | L2 | MK | MZ, k2(K::Z, K::RR32)),
    v("vbroadcastss", 0xF3818, 0x66, D, EVEX | L2 | N6 | MK | MZ, k2(K::Z, K::XM)),
    v("vbroadcastsd", 0xF3819, 0x66, D, EVEX | W1 | L2 | N7 | MK | MZ, k2(K::Z, K::XM)),
    v("vshufps", 0xFC6, 0, D, EVEX | L2 | MK | MZ, k4(K::Z, K::ZV, K::ZM, K::I8)),
    v("vpunpcklqdq", 0xF6C, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpacksswb", 0xF63, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpackssdw", 0xF6B, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsllw", 0xF71, 0x66, 6, EVEX | L2 | MK | MZ, k3(K::ZV, K::ZM, K::I8)),
    v("vpsraw", 0xF71, 0x66, 4, EVEX | L2 | MK | MZ, k3(K::ZV, K::ZM, K::I8)),
    v("vpslld", 0xF72, 0x66, 6, EVEX | L2 | MK | MZ, k3(K::ZV, K::ZM, K::I8)),
    v("vpsrad", 0xF72, 0x66, 4, EVEX | L2 | MK | MZ, k3(K::ZV, K::ZM, K::I8)),
    v("vpermq", 0xF3A00, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZM, K::I8)),
    v("vshufi64x2", 0xF3A43, 0x66, D, EVEX | W1 | L2 | MK | MZ, k4(K::Z, K::ZV, K::ZM, K::I8)),
    // SSE, AVX and AVX-512 for the intrinsics, derived from LLVM's encodings.
    r("aesdec", 0xF38DE, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("aesdeclast", 0xF38DF, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("aesenc", 0xF38DC, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("aesenclast", 0xF38DD, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("blendvpd", 0xF3815, 0x66, D, 0, F_NOSFX, k3(K::X, K::XM, K::X0)),
    r("blendvps", 0xF3814, 0x66, D, 0, F_NOSFX, k3(K::X, K::XM, K::X0)),
    r("cmppd", 0xFC2, 0x66, D, 0, F_NOSFX, k3(K::X, K::XM, K::I8)),
    r("cmpps", 0xFC2, 0, D, 0, F_NOSFX, k3(K::X, K::XM, K::I8)),
    r("cvtdq2ps", 0xF5B, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("cvttps2dq", 0xF5B, 0xF3, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("gf2p8affineqb", 0xF3ACE, 0x66, D, 0, F_NOSFX, k3(K::X, K::XM, K::I8)),
    r("gf2p8mulb", 0xF38CF, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    v("kmovd", 0xF92, 0xF2, D, VEX, k2(K::KR, K::RR32)),
    v("kmovd", 0xF93, 0xF2, D, VEX, k2(K::R32, K::KRM)),
    v("kmovq", 0xF92, 0xF2, D, VEX | W1, k2(K::KR, K::RR64)),
    v("kmovq", 0xF93, 0xF2, D, VEX | W1, k2(K::R64, K::KRM)),
    v("kmovw", 0xF92, 0, D, VEX, k2(K::KR, K::RR32)),
    v("kmovw", 0xF93, 0, D, VEX, k2(K::R32, K::KRM)),
    r("movhlps", 0xF12, 0, D, 0, F_NOSFX, k2(K::X, K::XR)),
    r("movlhps", 0xF16, 0, D, 0, F_NOSFX, k2(K::X, K::XR)),
    r("movlps", 0xF13, 0, D, 0, F_NOSFX, k2(K::M, K::X)),
    r("pabsd", 0xF381E, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pabsw", 0xF381D, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("packssdw", 0xF6B, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("packsswb", 0xF63, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("packusdw", 0xF382B, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("packuswb", 0xF67, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("paddsb", 0xFEC, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("paddsw", 0xFED, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("paddusb", 0xFDC, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("paddusw", 0xFDD, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pblendvb", 0xF3810, 0x66, D, 0, F_NOSFX, k3(K::X, K::XM, K::X0)),
    r("pclmulqdq", 0xF3A44, 0x66, D, 0, F_NOSFX, k3(K::X, K::XM, K::I8)),
    r("pcmpeqq", 0xF3829, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pcmpgtb", 0xF64, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pcmpgtd", 0xF66, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pcmpgtq", 0xF3837, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pcmpgtw", 0xF65, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("phminposuw", 0xF3841, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmaddubsw", 0xF3804, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmaddwd", 0xFF5, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmaxsb", 0xF383C, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmaxsd", 0xF383D, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmaxsw", 0xFEE, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmaxub", 0xFDE, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmaxud", 0xF383F, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmaxuw", 0xF383E, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pminsb", 0xF3838, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pminsd", 0xF3839, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pminsw", 0xFEA, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pminub", 0xFDA, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pminud", 0xF383B, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pminuw", 0xF383A, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmovsxbw", 0xF3820, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmovsxdq", 0xF3825, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmovsxwd", 0xF3823, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmovzxbw", 0xF3830, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmovzxdq", 0xF3835, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmovzxwd", 0xF3833, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmulhuw", 0xFE4, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmulhw", 0xFE5, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmulld", 0xF3840, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmullw", 0xFD5, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pmuludq", 0xFF4, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psadbw", 0xFF6, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pshufb", 0xF3800, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pshuflw", 0xF70, 0xF2, D, 0, F_NOSFX, k3(K::X, K::XM, K::I8)),
    r("psignb", 0xF3808, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("pslld", 0xFF2, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psllq", 0xFF3, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psllw", 0xFF1, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psrad", 0xFE2, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psraw", 0xFE1, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psrld", 0xFD2, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psrlq", 0xFD3, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psrlw", 0xFD1, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psubsb", 0xFE8, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psubsw", 0xFE9, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psubusb", 0xFD8, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("psubusw", 0xFD9, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("punpcklbw", 0xF60, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("punpckldq", 0xF62, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("punpcklwd", 0xF61, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("roundpd", 0xF3A09, 0x66, D, 0, F_NOSFX, k3(K::X, K::XM, K::I8)),
    r("roundps", 0xF3A08, 0x66, D, 0, F_NOSFX, k3(K::X, K::XM, K::I8)),
    r("shufps", 0xFC6, 0, D, 0, F_NOSFX, k3(K::X, K::XM, K::I8)),
    r("unpckhpd", 0xF15, 0x66, D, 0, F_NOSFX, k2(K::X, K::XM)),
    r("unpcklps", 0xF14, 0, D, 0, F_NOSFX, k2(K::X, K::XM)),
    v("vaddpd", 0xF58, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vaddpd", 0xF58, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vaddpd", 0xF58, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vaddps", 0xF58, 0, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vaddps", 0xF58, 0, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vaddps", 0xF58, 0, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vaesdec", 0xF38DE, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vaesdec", 0xF38DE, 0x66, D, EVEX | L2, k3(K::Z, K::ZV, K::ZM)),
    v("vaesdeclast", 0xF38DF, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vaesdeclast", 0xF38DF, 0x66, D, EVEX | L2, k3(K::Z, K::ZV, K::ZM)),
    v("vaesenc", 0xF38DC, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vaesenc", 0xF38DC, 0x66, D, EVEX | L2, k3(K::Z, K::ZV, K::ZM)),
    v("vaesenclast", 0xF38DD, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vaesenclast", 0xF38DD, 0x66, D, EVEX | L2, k3(K::Z, K::ZV, K::ZM)),
    v("vandnps", 0xF55, 0, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vandnps", 0xF55, 0, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vandps", 0xF54, 0, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vandps", 0xF54, 0, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vblendvpd", 0xF3A4B, 0x66, D, VEX | L1, k4(K::Y, K::YV, K::YM, K::YI4)),
    v("vblendvps", 0xF3A4A, 0x66, D, VEX | L1, k4(K::Y, K::YV, K::YM, K::YI4)),
    v("vcmppd", 0xFC2, 0x66, D, VEX | L1 | SWPC, k4(K::Y, K::YV, K::YM, K::I8)),
    v("vcmppd", 0xFC2, 0x66, D, EVEX | W1 | MK, k4(K::KR, K::XV, K::XM, K::I8)),
    v("vcmppd", 0xFC2, 0x66, D, EVEX | W1 | L1 | MK, k4(K::KR, K::YV, K::YM, K::I8)),
    v("vcmppd", 0xFC2, 0x66, D, EVEX | W1 | L2 | MK, k4(K::KR, K::ZV, K::ZM, K::I8)),
    v("vcmpps", 0xFC2, 0, D, VEX | L1 | SWPC, k4(K::Y, K::YV, K::YM, K::I8)),
    v("vcmpps", 0xFC2, 0, D, EVEX | MK, k4(K::KR, K::XV, K::XM, K::I8)),
    v("vcmpps", 0xFC2, 0, D, EVEX | L1 | MK, k4(K::KR, K::YV, K::YM, K::I8)),
    v("vcmpps", 0xFC2, 0, D, EVEX | L2 | MK, k4(K::KR, K::ZV, K::ZM, K::I8)),
    v("vcompresspd", 0xF388A, 0x66, D, EVEX | W1 | N1 | MK | MZ, k2(K::XM, K::X)),
    v("vcompresspd", 0xF388A, 0x66, D, EVEX | W1 | L1 | N2 | MK | MZ, k2(K::YM, K::Y)),
    v("vcompresspd", 0xF388A, 0x66, D, EVEX | W1 | L2 | N3 | MK | MZ, k2(K::ZM, K::Z)),
    v("vcompressps", 0xF388A, 0x66, D, EVEX | N2 | MK | MZ, k2(K::XM, K::X)),
    v("vcompressps", 0xF388A, 0x66, D, EVEX | L1 | N3 | MK | MZ, k2(K::YM, K::Y)),
    v("vcompressps", 0xF388A, 0x66, D, EVEX | L2 | N6 | MK | MZ, k2(K::ZM, K::Z)),
    v("vcvtdq2ps", 0xF5B, 0, D, VEX | L1, k2(K::Y, K::YM)),
    v("vcvtdq2ps", 0xF5B, 0, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vcvtdq2ps", 0xF5B, 0, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vcvtpd2ps", 0xF5A, 0x66, D, VEX | L1, k2(K::X, K::YR)),
    v("vcvtpd2ps", 0xF5A, 0x66, D, EVEX | W1 | L1 | MK | MZ, k2(K::X, K::YR)),
    v("vcvtpd2ps", 0xF5A, 0x66, D, EVEX | W1 | L2 | MK | MZ, k2(K::Y, K::ZM)),
    v("vcvtps2pd", 0xF5A, 0, D, VEX | L1, k2(K::Y, K::XM)),
    v("vcvtps2pd", 0xF5A, 0, D, EVEX | L1 | N1 | MK | MZ, k2(K::Y, K::XM)),
    v("vcvtps2pd", 0xF5A, 0, D, EVEX | L2 | N1 | MK | MZ, k2(K::Z, K::YM)),
    v("vcvtqq2pd", 0xFE6, 0xF3, D, EVEX | W1 | MK | MZ, k2(K::X, K::XM)),
    v("vcvtqq2pd", 0xFE6, 0xF3, D, EVEX | W1 | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vcvtqq2pd", 0xFE6, 0xF3, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vcvttps2dq", 0xF5B, 0xF3, D, VEX | L1, k2(K::Y, K::YM)),
    v("vcvttps2dq", 0xF5B, 0xF3, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vcvttps2dq", 0xF5B, 0xF3, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vcvttps2udq", 0xF78, 0, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vcvtudq2ps", 0xF7A, 0xF2, D, EVEX | MK | MZ, k2(K::X, K::XM)),
    v("vcvtudq2ps", 0xF7A, 0xF2, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vcvtudq2ps", 0xF7A, 0xF2, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vcvtuqq2pd", 0xF7A, 0xF3, D, EVEX | W1 | MK | MZ, k2(K::X, K::XM)),
    v("vcvtuqq2pd", 0xF7A, 0xF3, D, EVEX | W1 | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vcvtuqq2pd", 0xF7A, 0xF3, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vdivpd", 0xF5E, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vdivpd", 0xF5E, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vdivpd", 0xF5E, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vdivps", 0xF5E, 0, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vdivps", 0xF5E, 0, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vdivps", 0xF5E, 0, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vexpandpd", 0xF3888, 0x66, D, EVEX | W1 | N1 | MK | MZ, k2(K::X, K::XM)),
    v("vexpandpd", 0xF3888, 0x66, D, EVEX | W1 | L1 | N2 | MK | MZ, k2(K::Y, K::YM)),
    v("vexpandpd", 0xF3888, 0x66, D, EVEX | W1 | L2 | N3 | MK | MZ, k2(K::Z, K::ZM)),
    v("vexpandps", 0xF3888, 0x66, D, EVEX | N2 | MK | MZ, k2(K::X, K::XM)),
    v("vexpandps", 0xF3888, 0x66, D, EVEX | L1 | N3 | MK | MZ, k2(K::Y, K::YM)),
    v("vexpandps", 0xF3888, 0x66, D, EVEX | L2 | N6 | MK | MZ, k2(K::Z, K::ZM)),
    v("vextractf128", 0xF3A19, 0x66, D, VEX | L1, k3(K::XM, K::Y, K::I8)),
    v("vextractf64x4", 0xF3A1B, 0x66, D, EVEX | W1 | L2 | N1 | MK | MZ, k3(K::YM, K::Z, K::I8)),
    v("vfmadd213pd", 0xF38A8, 0x66, D, VEX | W1, k3(K::X, K::XV, K::XM)),
    v("vfmadd213pd", 0xF38A8, 0x66, D, VEX | W1 | L1, k3(K::Y, K::YV, K::YM)),
    v("vfmadd213pd", 0xF38A8, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vfmadd213pd", 0xF38A8, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vfmadd213pd", 0xF38A8, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vfmadd213ps", 0xF38A8, 0x66, D, VEX, k3(K::X, K::XV, K::XM)),
    v("vfmadd213ps", 0xF38A8, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vfmadd213ps", 0xF38A8, 0x66, D, EVEX | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vfmadd213ps", 0xF38A8, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vfmadd213ps", 0xF38A8, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vgatherqpd", 0xF3893, 0x66, D, VEX | W1, k3(K::X, K::VSX, K::XV)),
    v("vgatherqpd", 0xF3893, 0x66, D, VEX | W1 | L1, k3(K::Y, K::VSY, K::YV)),
    v("vgatherqpd", 0xF3893, 0x66, D, EVEX | W1 | L2 | N3 | MK | MR, k2(K::Z, K::VSZ)),
    v("vgatherqps", 0xF3893, 0x66, D, VEX | L1, k3(K::X, K::VSY, K::XV)),
    v("vgatherqps", 0xF3893, 0x66, D, EVEX | L2 | N6 | MK | MR, k2(K::Y, K::VSZ)),
    v("vinsertf128", 0xF3A18, 0x66, D, VEX | L1, k4(K::Y, K::YV, K::XM, K::I8)),
    v("vinsertf64x4", 0xF3A1A, 0x66, D, EVEX | W1 | L2 | N1 | MK | MZ, k4(K::Z, K::ZV, K::YM, K::I8)),
    v("vinserti64x4", 0xF3A3A, 0x66, D, EVEX | W1 | L2 | N1 | MK | MZ, k4(K::Z, K::ZV, K::YM, K::I8)),
    v("vmaskmovpd", 0xF382D, 0x66, D, VEX, k3(K::X, K::XV, K::M)),
    v("vmaskmovpd", 0xF382F, 0x66, D, VEX, k3(K::M, K::XV, K::X)),
    v("vmaskmovpd", 0xF382D, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::M)),
    v("vmaskmovpd", 0xF382F, 0x66, D, VEX | L1, k3(K::M, K::YV, K::Y)),
    v("vmaskmovps", 0xF382C, 0x66, D, VEX, k3(K::X, K::XV, K::M)),
    v("vmaskmovps", 0xF382E, 0x66, D, VEX, k3(K::M, K::XV, K::X)),
    v("vmaskmovps", 0xF382C, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::M)),
    v("vmaskmovps", 0xF382E, 0x66, D, VEX | L1, k3(K::M, K::YV, K::Y)),
    v("vmaxpd", 0xF5F, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vmaxpd", 0xF5F, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vmaxpd", 0xF5F, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vmaxps", 0xF5F, 0, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vmaxps", 0xF5F, 0, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vmaxps", 0xF5F, 0, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vminmaxpd", 0xF3A52, 0x66, D, EVEX | W1 | MK | MZ, k4(K::X, K::XV, K::XM, K::I8)),
    v("vminmaxpd", 0xF3A52, 0x66, D, EVEX | W1 | L1 | MK | MZ, k4(K::Y, K::YV, K::YM, K::I8)),
    v("vminmaxpd", 0xF3A52, 0x66, D, EVEX | W1 | L2 | MK | MZ, k4(K::Z, K::ZV, K::ZM, K::I8)),
    v("vminmaxps", 0xF3A52, 0x66, D, EVEX | MK | MZ, k4(K::X, K::XV, K::XM, K::I8)),
    v("vminmaxps", 0xF3A52, 0x66, D, EVEX | L1 | MK | MZ, k4(K::Y, K::YV, K::YM, K::I8)),
    v("vminmaxps", 0xF3A52, 0x66, D, EVEX | L2 | MK | MZ, k4(K::Z, K::ZV, K::ZM, K::I8)),
    v("vminpd", 0xF5D, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vminpd", 0xF5D, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vminpd", 0xF5D, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vminps", 0xF5D, 0, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vminps", 0xF5D, 0, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vminps", 0xF5D, 0, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vmovapd", 0xF28, 0x66, D, VEX | MV, k2(K::X, K::XM)),
    v("vmovapd", 0xF29, 0x66, D, VEX, k2(K::XM, K::X)),
    v("vmovapd", 0xF28, 0x66, D, VEX | L1 | MV, k2(K::Y, K::YM)),
    v("vmovapd", 0xF29, 0x66, D, VEX | L1, k2(K::YM, K::Y)),
    v("vmovapd", 0xF28, 0x66, D, EVEX | W1 | MK | MZ, k2(K::X, K::XM)),
    v("vmovapd", 0xF29, 0x66, D, EVEX | W1 | MK, k2(K::XM, K::X)),
    v("vmovapd", 0xF28, 0x66, D, EVEX | W1 | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vmovapd", 0xF29, 0x66, D, EVEX | W1 | L1 | MK, k2(K::YM, K::Y)),
    v("vmovapd", 0xF28, 0x66, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vmovaps", 0xF28, 0, D, VEX | MV, k2(K::X, K::XM)),
    v("vmovaps", 0xF29, 0, D, VEX, k2(K::XM, K::X)),
    v("vmovaps", 0xF28, 0, D, VEX | L1 | MV, k2(K::Y, K::YM)),
    v("vmovaps", 0xF29, 0, D, VEX | L1, k2(K::YM, K::Y)),
    v("vmovaps", 0xF28, 0, D, EVEX | MK | MZ, k2(K::X, K::XM)),
    v("vmovaps", 0xF29, 0, D, EVEX | MK, k2(K::XM, K::X)),
    v("vmovaps", 0xF28, 0, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vmovaps", 0xF29, 0, D, EVEX | L1 | MK, k2(K::YM, K::Y)),
    v("vmovaps", 0xF28, 0, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vmovd", 0xF6E, 0x66, D, VEX, k2(K::X, K::RM32)),
    v("vmovddup", 0xF12, 0xF2, D, VEX, k2(K::X, K::XM)),
    v("vmovddup", 0xF12, 0xF2, D, EVEX | W1 | N1 | MK | MZ, k2(K::X, K::XM)),
    v("vmovdqa", 0xF6F, 0x66, D, VEX | MV, k2(K::X, K::XM)),
    v("vmovdqa", 0xF7F, 0x66, D, VEX, k2(K::XM, K::X)),
    v("vmovdqa", 0xF6F, 0x66, D, VEX | L1 | MV, k2(K::Y, K::YM)),
    v("vmovdqa", 0xF7F, 0x66, D, VEX | L1, k2(K::YM, K::Y)),
    v("vmovdqa32", 0xF6F, 0x66, D, EVEX | MK | MZ, k2(K::X, K::XM)),
    v("vmovdqa32", 0xF6F, 0x66, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vmovdqa32", 0xF6F, 0x66, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vmovdqa64", 0xF6F, 0x66, D, EVEX | W1 | MK | MZ, k2(K::X, K::XM)),
    v("vmovdqa64", 0xF6F, 0x66, D, EVEX | W1 | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vmovdqa64", 0xF6F, 0x66, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vmovdqu", 0xF6F, 0xF3, D, VEX | MV, k2(K::X, K::XM)),
    v("vmovdqu", 0xF7F, 0xF3, D, VEX, k2(K::XM, K::X)),
    v("vmovdqu", 0xF6F, 0xF3, D, VEX | L1 | MV, k2(K::Y, K::YM)),
    v("vmovdqu", 0xF7F, 0xF3, D, VEX | L1, k2(K::YM, K::Y)),
    v("vmovdqu16", 0xF6F, 0xF2, D, EVEX | W1 | MK | MZ, k2(K::X, K::XM)),
    v("vmovdqu16", 0xF7F, 0xF2, D, EVEX | W1 | MK, k2(K::XM, K::X)),
    v("vmovdqu16", 0xF6F, 0xF2, D, EVEX | W1 | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vmovdqu16", 0xF7F, 0xF2, D, EVEX | W1 | L1 | MK, k2(K::YM, K::Y)),
    v("vmovdqu16", 0xF6F, 0xF2, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vmovdqu16", 0xF7F, 0xF2, D, EVEX | W1 | L2 | MK, k2(K::ZM, K::Z)),
    v("vmovdqu32", 0xF6F, 0xF3, D, EVEX | MK | MZ, k2(K::X, K::XM)),
    v("vmovdqu32", 0xF7F, 0xF3, D, EVEX | MK, k2(K::XM, K::X)),
    v("vmovdqu32", 0xF6F, 0xF3, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vmovdqu32", 0xF7F, 0xF3, D, EVEX | L1 | MK, k2(K::YM, K::Y)),
    v("vmovdqu32", 0xF6F, 0xF3, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vmovdqu32", 0xF7F, 0xF3, D, EVEX | L2 | MK, k2(K::ZM, K::Z)),
    v("vmovdqu64", 0xF6F, 0xF3, D, EVEX | W1 | MK | MZ, k2(K::X, K::XM)),
    v("vmovdqu64", 0xF7F, 0xF3, D, EVEX | W1 | MK, k2(K::XM, K::X)),
    v("vmovdqu64", 0xF6F, 0xF3, D, EVEX | W1 | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vmovdqu64", 0xF7F, 0xF3, D, EVEX | W1 | L1 | MK, k2(K::YM, K::Y)),
    v("vmovdqu64", 0xF6F, 0xF3, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vmovdqu64", 0xF7F, 0xF3, D, EVEX | W1 | L2 | MK, k2(K::ZM, K::Z)),
    v("vmovdqu8", 0xF6F, 0xF2, D, EVEX | MK | MZ, k2(K::X, K::XM)),
    v("vmovdqu8", 0xF7F, 0xF2, D, EVEX | MK, k2(K::XM, K::X)),
    v("vmovdqu8", 0xF6F, 0xF2, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vmovdqu8", 0xF7F, 0xF2, D, EVEX | L1 | MK, k2(K::YM, K::Y)),
    v("vmovdqu8", 0xF6F, 0xF2, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vmovdqu8", 0xF7F, 0xF2, D, EVEX | L2 | MK, k2(K::ZM, K::Z)),
    v("vmovmskpd", 0xF50, 0x66, D, VEX | L1, k2(K::R32, K::YR)),
    v("vmovmskps", 0xF50, 0, D, VEX | L1, k2(K::R32, K::YR)),
    v("vmovq", 0xF6E, 0x66, D, VEX | W1, k2(K::X, K::RR64)),
    v("vmovupd", 0xF10, 0x66, D, VEX | MV, k2(K::X, K::XM)),
    v("vmovupd", 0xF11, 0x66, D, VEX, k2(K::XM, K::X)),
    v("vmovupd", 0xF10, 0x66, D, VEX | L1 | MV, k2(K::Y, K::YM)),
    v("vmovupd", 0xF11, 0x66, D, VEX | L1, k2(K::YM, K::Y)),
    v("vmovupd", 0xF10, 0x66, D, EVEX | W1 | MK | MZ, k2(K::X, K::XM)),
    v("vmovupd", 0xF11, 0x66, D, EVEX | W1 | MK, k2(K::XM, K::X)),
    v("vmovupd", 0xF10, 0x66, D, EVEX | W1 | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vmovupd", 0xF11, 0x66, D, EVEX | W1 | L1 | MK, k2(K::YM, K::Y)),
    v("vmovupd", 0xF10, 0x66, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vmovupd", 0xF11, 0x66, D, EVEX | W1 | L2 | MK, k2(K::ZM, K::Z)),
    v("vmovups", 0xF10, 0, D, VEX | MV, k2(K::X, K::XM)),
    v("vmovups", 0xF11, 0, D, VEX, k2(K::XM, K::X)),
    v("vmovups", 0xF10, 0, D, VEX | L1 | MV, k2(K::Y, K::YM)),
    v("vmovups", 0xF11, 0, D, VEX | L1, k2(K::YM, K::Y)),
    v("vmovups", 0xF10, 0, D, EVEX | MK | MZ, k2(K::X, K::XM)),
    v("vmovups", 0xF11, 0, D, EVEX | MK, k2(K::XM, K::X)),
    v("vmovups", 0xF10, 0, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vmovups", 0xF11, 0, D, EVEX | L1 | MK, k2(K::YM, K::Y)),
    v("vmovups", 0xF10, 0, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vmovups", 0xF11, 0, D, EVEX | L2 | MK, k2(K::ZM, K::Z)),
    v("vmulpd", 0xF59, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vmulpd", 0xF59, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vmulpd", 0xF59, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vmulps", 0xF59, 0, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vmulps", 0xF59, 0, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vmulps", 0xF59, 0, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vorps", 0xF56, 0, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vorps", 0xF56, 0, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpabsd", 0xF381E, 0x66, D, VEX | L1, k2(K::Y, K::YM)),
    v("vpabsd", 0xF381E, 0x66, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vpabsd", 0xF381E, 0x66, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpabsq", 0xF381F, 0x66, D, EVEX | W1 | MK | MZ, k2(K::X, K::XM)),
    v("vpabsq", 0xF381F, 0x66, D, EVEX | W1 | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vpabsq", 0xF381F, 0x66, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpabsw", 0xF381D, 0x66, D, VEX | L1, k2(K::Y, K::YM)),
    v("vpabsw", 0xF381D, 0x66, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vpabsw", 0xF381D, 0x66, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpaddb", 0xFFC, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpaddb", 0xFFC, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpaddb", 0xFFC, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpaddd", 0xFFE, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpaddd", 0xFFE, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpaddd", 0xFFE, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpaddq", 0xFD4, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpaddq", 0xFD4, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpaddq", 0xFD4, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpaddsb", 0xFEC, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpaddsb", 0xFEC, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpaddsb", 0xFEC, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpaddsw", 0xFED, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpaddsw", 0xFED, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpaddsw", 0xFED, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpaddusb", 0xFDC, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpaddusb", 0xFDC, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpaddusb", 0xFDC, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpaddusw", 0xFDD, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpaddusw", 0xFDD, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpaddusw", 0xFDD, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpaddw", 0xFFD, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpaddw", 0xFFD, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpaddw", 0xFFD, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpandnq", 0xFDF, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpandq", 0xFDB, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpblendvb", 0xF3A4C, 0x66, D, VEX | L1, k4(K::Y, K::YV, K::YM, K::YI4)),
    v("vpbroadcastb", 0xF3878, 0x66, D, VEX | L1, k2(K::Y, K::XM)),
    v("vpbroadcastb", 0xF3878, 0x66, D, EVEX | L1 | N4 | MK | MZ, k2(K::Y, K::XM)),
    v("vpbroadcastd", 0xF387C, 0x66, D, EVEX | L2 | MK | MZ, k2(K::Z, K::RR32)),
    v("vpbroadcastq", 0xF387C, 0x66, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::RR64)),
    v("vpbroadcastw", 0xF3879, 0x66, D, VEX | L1, k2(K::Y, K::XM)),
    v("vpbroadcastw", 0xF3879, 0x66, D, EVEX | L1 | N5 | MK | MZ, k2(K::Y, K::XM)),
    v("vpcmpb", 0xF3A3F, 0x66, D, EVEX | MK, k4(K::KR, K::XV, K::XM, K::I8)),
    v("vpcmpb", 0xF3A3F, 0x66, D, EVEX | L1 | MK, k4(K::KR, K::YV, K::YM, K::I8)),
    v("vpcmpb", 0xF3A3F, 0x66, D, EVEX | L2 | MK, k4(K::KR, K::ZV, K::ZM, K::I8)),
    v("vpcmpd", 0xF3A1F, 0x66, D, EVEX | MK, k4(K::KR, K::XV, K::XM, K::I8)),
    v("vpcmpd", 0xF3A1F, 0x66, D, EVEX | L1 | MK, k4(K::KR, K::YV, K::YM, K::I8)),
    v("vpcmpd", 0xF3A1F, 0x66, D, EVEX | L2 | MK, k4(K::KR, K::ZV, K::ZM, K::I8)),
    v("vpcmpeqb", 0xF74, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpcmpeqd", 0xF76, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpcmpeqq", 0xF3829, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpcmpeqw", 0xF75, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpcmpgtb", 0xF64, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpcmpgtd", 0xF66, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpcmpgtq", 0xF3837, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpcmpgtw", 0xF65, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpcmpq", 0xF3A1F, 0x66, D, EVEX | W1 | MK, k4(K::KR, K::XV, K::XM, K::I8)),
    v("vpcmpq", 0xF3A1F, 0x66, D, EVEX | W1 | L1 | MK, k4(K::KR, K::YV, K::YM, K::I8)),
    v("vpcmpq", 0xF3A1F, 0x66, D, EVEX | W1 | L2 | MK, k4(K::KR, K::ZV, K::ZM, K::I8)),
    v("vpcmpub", 0xF3A3E, 0x66, D, EVEX | MK, k4(K::KR, K::XV, K::XM, K::I8)),
    v("vpcmpub", 0xF3A3E, 0x66, D, EVEX | L1 | MK, k4(K::KR, K::YV, K::YM, K::I8)),
    v("vpcmpub", 0xF3A3E, 0x66, D, EVEX | L2 | MK, k4(K::KR, K::ZV, K::ZM, K::I8)),
    v("vpcmpud", 0xF3A1E, 0x66, D, EVEX | MK, k4(K::KR, K::XV, K::XM, K::I8)),
    v("vpcmpud", 0xF3A1E, 0x66, D, EVEX | L1 | MK, k4(K::KR, K::YV, K::YM, K::I8)),
    v("vpcmpud", 0xF3A1E, 0x66, D, EVEX | L2 | MK, k4(K::KR, K::ZV, K::ZM, K::I8)),
    v("vpcmpuq", 0xF3A1E, 0x66, D, EVEX | W1 | MK, k4(K::KR, K::XV, K::XM, K::I8)),
    v("vpcmpuq", 0xF3A1E, 0x66, D, EVEX | W1 | L1 | MK, k4(K::KR, K::YV, K::YM, K::I8)),
    v("vpcmpuq", 0xF3A1E, 0x66, D, EVEX | W1 | L2 | MK, k4(K::KR, K::ZV, K::ZM, K::I8)),
    v("vpcmpuw", 0xF3A3E, 0x66, D, EVEX | W1 | MK, k4(K::KR, K::XV, K::XM, K::I8)),
    v("vpcmpuw", 0xF3A3E, 0x66, D, EVEX | W1 | L1 | MK, k4(K::KR, K::YV, K::YM, K::I8)),
    v("vpcmpuw", 0xF3A3E, 0x66, D, EVEX | W1 | L2 | MK, k4(K::KR, K::ZV, K::ZM, K::I8)),
    v("vpcmpw", 0xF3A3F, 0x66, D, EVEX | W1 | MK, k4(K::KR, K::XV, K::XM, K::I8)),
    v("vpcmpw", 0xF3A3F, 0x66, D, EVEX | W1 | L1 | MK, k4(K::KR, K::YV, K::YM, K::I8)),
    v("vpcmpw", 0xF3A3F, 0x66, D, EVEX | W1 | L2 | MK, k4(K::KR, K::ZV, K::ZM, K::I8)),
    v("vpcompressb", 0xF3863, 0x66, D, EVEX | N4 | MK | MZ, k2(K::XM, K::X)),
    v("vpcompressb", 0xF3863, 0x66, D, EVEX | L1 | N4 | MK | MZ, k2(K::YM, K::Y)),
    v("vpcompressb", 0xF3863, 0x66, D, EVEX | L2 | N4 | MK | MZ, k2(K::ZM, K::Z)),
    v("vpcompressd", 0xF388B, 0x66, D, EVEX | N2 | MK | MZ, k2(K::XM, K::X)),
    v("vpcompressd", 0xF388B, 0x66, D, EVEX | L1 | N3 | MK | MZ, k2(K::YM, K::Y)),
    v("vpcompressd", 0xF388B, 0x66, D, EVEX | L2 | N6 | MK | MZ, k2(K::ZM, K::Z)),
    v("vpcompressq", 0xF388B, 0x66, D, EVEX | W1 | N1 | MK | MZ, k2(K::XM, K::X)),
    v("vpcompressq", 0xF388B, 0x66, D, EVEX | W1 | L1 | N2 | MK | MZ, k2(K::YM, K::Y)),
    v("vpcompressq", 0xF388B, 0x66, D, EVEX | W1 | L2 | N3 | MK | MZ, k2(K::ZM, K::Z)),
    v("vpcompressw", 0xF3863, 0x66, D, EVEX | W1 | N3 | MK | MZ, k2(K::XM, K::X)),
    v("vpcompressw", 0xF3863, 0x66, D, EVEX | W1 | L1 | N5 | MK | MZ, k2(K::YM, K::Y)),
    v("vpcompressw", 0xF3863, 0x66, D, EVEX | W1 | L2 | N5 | MK | MZ, k2(K::ZM, K::Z)),
    v("vpconflictd", 0xF38C4, 0x66, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpconflictq", 0xF38C4, 0x66, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpdpbusd", 0xF3850, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpdpwssd", 0xF3852, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpermps", 0xF3816, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpermps", 0xF3816, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpermt2b", 0xF387D, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpermt2d", 0xF387E, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpermt2q", 0xF387E, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpermt2w", 0xF387D, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpexpandb", 0xF3862, 0x66, D, EVEX | N4 | MK | MZ, k2(K::X, K::XM)),
    v("vpexpandb", 0xF3862, 0x66, D, EVEX | L1 | N4 | MK | MZ, k2(K::Y, K::YM)),
    v("vpexpandb", 0xF3862, 0x66, D, EVEX | L2 | N4 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpexpandd", 0xF3889, 0x66, D, EVEX | N2 | MK | MZ, k2(K::X, K::XM)),
    v("vpexpandd", 0xF3889, 0x66, D, EVEX | L1 | N3 | MK | MZ, k2(K::Y, K::YM)),
    v("vpexpandd", 0xF3889, 0x66, D, EVEX | L2 | N6 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpexpandq", 0xF3889, 0x66, D, EVEX | W1 | N1 | MK | MZ, k2(K::X, K::XM)),
    v("vpexpandq", 0xF3889, 0x66, D, EVEX | W1 | L1 | N2 | MK | MZ, k2(K::Y, K::YM)),
    v("vpexpandq", 0xF3889, 0x66, D, EVEX | W1 | L2 | N3 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpexpandw", 0xF3862, 0x66, D, EVEX | W1 | N3 | MK | MZ, k2(K::X, K::XM)),
    v("vpexpandw", 0xF3862, 0x66, D, EVEX | W1 | L1 | N5 | MK | MZ, k2(K::Y, K::YM)),
    v("vpexpandw", 0xF3862, 0x66, D, EVEX | W1 | L2 | N5 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpgatherqd", 0xF3891, 0x66, D, VEX | L1, k3(K::X, K::VSY, K::XV)),
    v("vpgatherqd", 0xF3891, 0x66, D, EVEX | L2 | N6 | MK | MR, k2(K::Y, K::VSZ)),
    v("vpgatherqq", 0xF3891, 0x66, D, VEX | W1, k3(K::X, K::VSX, K::XV)),
    v("vpgatherqq", 0xF3891, 0x66, D, VEX | W1 | L1, k3(K::Y, K::VSY, K::YV)),
    v("vpgatherqq", 0xF3891, 0x66, D, EVEX | W1 | L2 | N3 | MK | MR, k2(K::Z, K::VSZ)),
    v("vpinsrd", 0xF3A22, 0x66, D, VEX, k4(K::X, K::XV, K::RM32, K::I8)),
    v("vplzcntd", 0xF3844, 0x66, D, EVEX | MK | MZ, k2(K::X, K::XM)),
    v("vplzcntd", 0xF3844, 0x66, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vplzcntd", 0xF3844, 0x66, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vplzcntq", 0xF3844, 0x66, D, EVEX | W1 | MK | MZ, k2(K::X, K::XM)),
    v("vplzcntq", 0xF3844, 0x66, D, EVEX | W1 | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vplzcntq", 0xF3844, 0x66, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpmaskmovd", 0xF388C, 0x66, D, VEX, k3(K::X, K::XV, K::M)),
    v("vpmaskmovd", 0xF388E, 0x66, D, VEX, k3(K::M, K::XV, K::X)),
    v("vpmaskmovd", 0xF388C, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::M)),
    v("vpmaskmovd", 0xF388E, 0x66, D, VEX | L1, k3(K::M, K::YV, K::Y)),
    v("vpmaskmovq", 0xF388C, 0x66, D, VEX | W1, k3(K::X, K::XV, K::M)),
    v("vpmaskmovq", 0xF388E, 0x66, D, VEX | W1, k3(K::M, K::XV, K::X)),
    v("vpmaskmovq", 0xF388C, 0x66, D, VEX | W1 | L1, k3(K::Y, K::YV, K::M)),
    v("vpmaskmovq", 0xF388E, 0x66, D, VEX | W1 | L1, k3(K::M, K::YV, K::Y)),
    v("vpmaxsb", 0xF383C, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpmaxsb", 0xF383C, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmaxsb", 0xF383C, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpmaxsd", 0xF383D, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpmaxsd", 0xF383D, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmaxsd", 0xF383D, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpmaxsq", 0xF383D, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpmaxsq", 0xF383D, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmaxsq", 0xF383D, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpmaxsw", 0xFEE, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpmaxsw", 0xFEE, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmaxsw", 0xFEE, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpmaxub", 0xFDE, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpmaxub", 0xFDE, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmaxub", 0xFDE, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpmaxud", 0xF383F, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpmaxud", 0xF383F, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmaxud", 0xF383F, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpmaxuq", 0xF383F, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpmaxuq", 0xF383F, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmaxuq", 0xF383F, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpmaxuw", 0xF383E, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpmaxuw", 0xF383E, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmaxuw", 0xF383E, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpminsb", 0xF3838, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpminsb", 0xF3838, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpminsb", 0xF3838, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpminsd", 0xF3839, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpminsd", 0xF3839, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpminsd", 0xF3839, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpminsq", 0xF3839, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpminsq", 0xF3839, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpminsq", 0xF3839, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpminsw", 0xFEA, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpminsw", 0xFEA, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpminsw", 0xFEA, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpminub", 0xFDA, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpminub", 0xFDA, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpminub", 0xFDA, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpminud", 0xF383B, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpminud", 0xF383B, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpminud", 0xF383B, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpminuq", 0xF383B, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpminuq", 0xF383B, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpminuq", 0xF383B, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpminuw", 0xF383A, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpminuw", 0xF383A, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpminuw", 0xF383A, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpmovdb", 0xF3831, 0xF3, D, EVEX | L2 | N2 | MK | MZ, k2(K::XM, K::Z)),
    v("vpmovdw", 0xF3833, 0xF3, D, EVEX | L2 | N1 | MK | MZ, k2(K::YM, K::Z)),
    v("vpmovmskb", 0xFD7, 0x66, D, VEX | L1, k2(K::R32, K::YR)),
    v("vpmovqb", 0xF3832, 0xF3, D, EVEX | L2 | N3 | MK | MZ, k2(K::XM, K::Z)),
    v("vpmovqd", 0xF3835, 0xF3, D, EVEX | L2 | N1 | MK | MZ, k2(K::YM, K::Z)),
    v("vpmovqw", 0xF3834, 0xF3, D, EVEX | L2 | N2 | MK | MZ, k2(K::XM, K::Z)),
    v("vpmovsdb", 0xF3821, 0xF3, D, EVEX | L2 | N2 | MK | MZ, k2(K::XM, K::Z)),
    v("vpmovsdw", 0xF3823, 0xF3, D, EVEX | L2 | N1 | MK | MZ, k2(K::YM, K::Z)),
    v("vpmovsqb", 0xF3822, 0xF3, D, EVEX | L2 | N3 | MK | MZ, k2(K::XM, K::Z)),
    v("vpmovsqd", 0xF3825, 0xF3, D, EVEX | L2 | N1 | MK | MZ, k2(K::YM, K::Z)),
    v("vpmovsqw", 0xF3824, 0xF3, D, EVEX | L2 | N2 | MK | MZ, k2(K::XM, K::Z)),
    v("vpmovswb", 0xF3820, 0xF3, D, EVEX | L2 | N1 | MK | MZ, k2(K::YM, K::Z)),
    v("vpmovsxbd", 0xF3821, 0x66, D, VEX | L1, k2(K::Y, K::XM)),
    v("vpmovsxbd", 0xF3821, 0x66, D, EVEX | L1 | N2 | MK | MZ, k2(K::Y, K::XM)),
    v("vpmovsxbd", 0xF3821, 0x66, D, EVEX | L2 | N2 | MK | MZ, k2(K::Z, K::XM)),
    v("vpmovsxbq", 0xF3822, 0x66, D, EVEX | L2 | N3 | MK | MZ, k2(K::Z, K::XM)),
    v("vpmovsxbw", 0xF3820, 0x66, D, VEX | L1, k2(K::Y, K::XM)),
    v("vpmovsxbw", 0xF3820, 0x66, D, EVEX | L1 | N1 | MK | MZ, k2(K::Y, K::XM)),
    v("vpmovsxbw", 0xF3820, 0x66, D, EVEX | L2 | N1 | MK | MZ, k2(K::Z, K::YM)),
    v("vpmovsxdq", 0xF3825, 0x66, D, VEX | L1, k2(K::Y, K::XM)),
    v("vpmovsxdq", 0xF3825, 0x66, D, EVEX | L1 | N1 | MK | MZ, k2(K::Y, K::XM)),
    v("vpmovsxdq", 0xF3825, 0x66, D, EVEX | L2 | N1 | MK | MZ, k2(K::Z, K::YM)),
    v("vpmovsxwd", 0xF3823, 0x66, D, VEX | L1, k2(K::Y, K::XM)),
    v("vpmovsxwd", 0xF3823, 0x66, D, EVEX | L1 | N1 | MK | MZ, k2(K::Y, K::XM)),
    v("vpmovsxwd", 0xF3823, 0x66, D, EVEX | L2 | N1 | MK | MZ, k2(K::Z, K::YM)),
    v("vpmovsxwq", 0xF3824, 0x66, D, VEX | L1, k2(K::Y, K::XM)),
    v("vpmovsxwq", 0xF3824, 0x66, D, EVEX | L1 | N2 | MK | MZ, k2(K::Y, K::XM)),
    v("vpmovsxwq", 0xF3824, 0x66, D, EVEX | L2 | N2 | MK | MZ, k2(K::Z, K::XM)),
    v("vpmovusdb", 0xF3811, 0xF3, D, EVEX | L2 | N2 | MK | MZ, k2(K::XM, K::Z)),
    v("vpmovusdw", 0xF3813, 0xF3, D, EVEX | L2 | N1 | MK | MZ, k2(K::YM, K::Z)),
    v("vpmovusqb", 0xF3812, 0xF3, D, EVEX | L2 | N3 | MK | MZ, k2(K::XM, K::Z)),
    v("vpmovusqd", 0xF3815, 0xF3, D, EVEX | L2 | N1 | MK | MZ, k2(K::YM, K::Z)),
    v("vpmovusqw", 0xF3814, 0xF3, D, EVEX | L2 | N2 | MK | MZ, k2(K::XM, K::Z)),
    v("vpmovuswb", 0xF3810, 0xF3, D, EVEX | L2 | N1 | MK | MZ, k2(K::YM, K::Z)),
    v("vpmovwb", 0xF3830, 0xF3, D, EVEX | L2 | N1 | MK | MZ, k2(K::YM, K::Z)),
    v("vpmovzxbd", 0xF3831, 0x66, D, VEX | L1, k2(K::Y, K::XM)),
    v("vpmovzxbd", 0xF3831, 0x66, D, EVEX | L1 | N2 | MK | MZ, k2(K::Y, K::XM)),
    v("vpmovzxbd", 0xF3831, 0x66, D, EVEX | L2 | N2 | MK | MZ, k2(K::Z, K::XM)),
    v("vpmovzxbq", 0xF3832, 0x66, D, EVEX | L2 | N3 | MK | MZ, k2(K::Z, K::XM)),
    v("vpmovzxbw", 0xF3830, 0x66, D, VEX | L1, k2(K::Y, K::XM)),
    v("vpmovzxbw", 0xF3830, 0x66, D, EVEX | L1 | N1 | MK | MZ, k2(K::Y, K::XM)),
    v("vpmovzxbw", 0xF3830, 0x66, D, EVEX | L2 | N1 | MK | MZ, k2(K::Z, K::YM)),
    v("vpmovzxdq", 0xF3835, 0x66, D, VEX | L1, k2(K::Y, K::XM)),
    v("vpmovzxdq", 0xF3835, 0x66, D, EVEX | L1 | N1 | MK | MZ, k2(K::Y, K::XM)),
    v("vpmovzxdq", 0xF3835, 0x66, D, EVEX | L2 | N1 | MK | MZ, k2(K::Z, K::YM)),
    v("vpmovzxwd", 0xF3833, 0x66, D, VEX | L1, k2(K::Y, K::XM)),
    v("vpmovzxwd", 0xF3833, 0x66, D, EVEX | L1 | N1 | MK | MZ, k2(K::Y, K::XM)),
    v("vpmovzxwd", 0xF3833, 0x66, D, EVEX | L2 | N1 | MK | MZ, k2(K::Z, K::YM)),
    v("vpmovzxwq", 0xF3834, 0x66, D, VEX | L1, k2(K::Y, K::XM)),
    v("vpmovzxwq", 0xF3834, 0x66, D, EVEX | L1 | N2 | MK | MZ, k2(K::Y, K::XM)),
    v("vpmovzxwq", 0xF3834, 0x66, D, EVEX | L2 | N2 | MK | MZ, k2(K::Z, K::XM)),
    v("vpmulhuw", 0xFE4, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpmulhuw", 0xFE4, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmulhw", 0xFE5, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpmulhw", 0xFE5, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmulld", 0xF3840, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpmulld", 0xF3840, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmulld", 0xF3840, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpmullq", 0xF3840, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpmullq", 0xF3840, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmullq", 0xF3840, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpmullw", 0xFD5, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpmullw", 0xFD5, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmullw", 0xFD5, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpmuludq", 0xFF4, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpmuludq", 0xFF4, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpmuludq", 0xFF4, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpopcntb", 0xF3854, 0x66, D, EVEX | MK | MZ, k2(K::X, K::XM)),
    v("vpopcntb", 0xF3854, 0x66, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vpopcntb", 0xF3854, 0x66, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpopcntd", 0xF3855, 0x66, D, EVEX | MK | MZ, k2(K::X, K::XM)),
    v("vpopcntd", 0xF3855, 0x66, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vpopcntd", 0xF3855, 0x66, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpopcntq", 0xF3855, 0x66, D, EVEX | W1 | MK | MZ, k2(K::X, K::XM)),
    v("vpopcntq", 0xF3855, 0x66, D, EVEX | W1 | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vpopcntq", 0xF3855, 0x66, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpopcntw", 0xF3854, 0x66, D, EVEX | W1 | MK | MZ, k2(K::X, K::XM)),
    v("vpopcntw", 0xF3854, 0x66, D, EVEX | W1 | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vpopcntw", 0xF3854, 0x66, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vpord", 0xFEB, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vporq", 0xFEB, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vprolvd", 0xF3815, 0x66, D, EVEX | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vprolvd", 0xF3815, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vprolvd", 0xF3815, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vprolvq", 0xF3815, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vprolvq", 0xF3815, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vprolvq", 0xF3815, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vprorvd", 0xF3814, 0x66, D, EVEX | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vprorvd", 0xF3814, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vprorvd", 0xF3814, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vprorvq", 0xF3814, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vprorvq", 0xF3814, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vprorvq", 0xF3814, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsadbw", 0xFF6, 0x66, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vpscatterqd", 0xF38A1, 0x66, D, EVEX | L2 | N6 | MK | MR, k2(K::VSZ, K::Y)),
    v("vpscatterqq", 0xF38A1, 0x66, D, EVEX | W1 | L2 | N3 | MK | MR, k2(K::VSZ, K::Z)),
    v("vpshufb", 0xF3800, 0x66, D, VEX, k3(K::X, K::XV, K::XM)),
    v("vpshufb", 0xF3800, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpshufb", 0xF3800, 0x66, D, EVEX | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpshufb", 0xF3800, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpshufd", 0xF70, 0x66, D, VEX, k3(K::X, K::XM, K::I8)),
    v("vpshufd", 0xF70, 0x66, D, EVEX | MK | MZ, k3(K::X, K::XM, K::I8)),
    v("vpshuflw", 0xF70, 0xF2, D, VEX, k3(K::X, K::XM, K::I8)),
    v("vpshuflw", 0xF70, 0xF2, D, EVEX | MK | MZ, k3(K::X, K::XM, K::I8)),
    v("vpsignb", 0xF3808, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpslld", 0xFF2, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::XM)),
    v("vpslld", 0xFF2, 0x66, D, EVEX | L1 | N1 | MK | MZ, k3(K::Y, K::YV, K::XM)),
    v("vpslld", 0xFF2, 0x66, D, EVEX | L2 | N2 | MK | MZ, k3(K::Z, K::ZV, K::XM)),
    v("vpsllq", 0xFF3, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::XM)),
    v("vpsllq", 0xFF3, 0x66, D, EVEX | W1 | L1 | N1 | MK | MZ, k3(K::Y, K::YV, K::XM)),
    v("vpsllq", 0xFF3, 0x66, D, EVEX | W1 | L2 | N2 | MK | MZ, k3(K::Z, K::ZV, K::XM)),
    v("vpsllvd", 0xF3847, 0x66, D, VEX, k3(K::X, K::XV, K::XM)),
    v("vpsllvd", 0xF3847, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpsllvd", 0xF3847, 0x66, D, EVEX | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpsllvd", 0xF3847, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsllvd", 0xF3847, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsllvq", 0xF3847, 0x66, D, VEX | W1, k3(K::X, K::XV, K::XM)),
    v("vpsllvq", 0xF3847, 0x66, D, VEX | W1 | L1, k3(K::Y, K::YV, K::YM)),
    v("vpsllvq", 0xF3847, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpsllvq", 0xF3847, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsllvq", 0xF3847, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsllvw", 0xF3812, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpsllvw", 0xF3812, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsllvw", 0xF3812, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsllw", 0xFF1, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::XM)),
    v("vpsllw", 0xFF1, 0x66, D, EVEX | L1 | N1 | MK | MZ, k3(K::Y, K::YV, K::XM)),
    v("vpsllw", 0xFF1, 0x66, D, EVEX | L2 | N2 | MK | MZ, k3(K::Z, K::ZV, K::XM)),
    v("vpsrad", 0xFE2, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::XM)),
    v("vpsrad", 0xFE2, 0x66, D, EVEX | L1 | N1 | MK | MZ, k3(K::Y, K::YV, K::XM)),
    v("vpsrad", 0xFE2, 0x66, D, EVEX | L2 | N2 | MK | MZ, k3(K::Z, K::ZV, K::XM)),
    v("vpsraq", 0xFE2, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpsraq", 0xFE2, 0x66, D, EVEX | W1 | L1 | N1 | MK | MZ, k3(K::Y, K::YV, K::XM)),
    v("vpsraq", 0xFE2, 0x66, D, EVEX | W1 | L2 | N2 | MK | MZ, k3(K::Z, K::ZV, K::XM)),
    v("vpsravd", 0xF3846, 0x66, D, VEX, k3(K::X, K::XV, K::XM)),
    v("vpsravd", 0xF3846, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpsravd", 0xF3846, 0x66, D, EVEX | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpsravd", 0xF3846, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsravd", 0xF3846, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsravq", 0xF3846, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpsravq", 0xF3846, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsravq", 0xF3846, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsravw", 0xF3811, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpsravw", 0xF3811, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsravw", 0xF3811, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsraw", 0xFE1, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::XM)),
    v("vpsraw", 0xFE1, 0x66, D, EVEX | L1 | N1 | MK | MZ, k3(K::Y, K::YV, K::XM)),
    v("vpsraw", 0xFE1, 0x66, D, EVEX | L2 | N2 | MK | MZ, k3(K::Z, K::ZV, K::XM)),
    v("vpsrld", 0xFD2, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::XM)),
    v("vpsrld", 0xFD2, 0x66, D, EVEX | L1 | N1 | MK | MZ, k3(K::Y, K::YV, K::XM)),
    v("vpsrld", 0xFD2, 0x66, D, EVEX | L2 | N2 | MK | MZ, k3(K::Z, K::ZV, K::XM)),
    v("vpsrlq", 0xFD3, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::XM)),
    v("vpsrlq", 0xFD3, 0x66, D, EVEX | W1 | L1 | N1 | MK | MZ, k3(K::Y, K::YV, K::XM)),
    v("vpsrlq", 0xFD3, 0x66, D, EVEX | W1 | L2 | N2 | MK | MZ, k3(K::Z, K::ZV, K::XM)),
    v("vpsrlvd", 0xF3845, 0x66, D, VEX, k3(K::X, K::XV, K::XM)),
    v("vpsrlvd", 0xF3845, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpsrlvd", 0xF3845, 0x66, D, EVEX | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpsrlvd", 0xF3845, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsrlvd", 0xF3845, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsrlvq", 0xF3845, 0x66, D, VEX | W1, k3(K::X, K::XV, K::XM)),
    v("vpsrlvq", 0xF3845, 0x66, D, VEX | W1 | L1, k3(K::Y, K::YV, K::YM)),
    v("vpsrlvq", 0xF3845, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpsrlvq", 0xF3845, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsrlvq", 0xF3845, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsrlvw", 0xF3810, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpsrlvw", 0xF3810, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsrlvw", 0xF3810, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsrlw", 0xFD1, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::XM)),
    v("vpsrlw", 0xFD1, 0x66, D, EVEX | L1 | N1 | MK | MZ, k3(K::Y, K::YV, K::XM)),
    v("vpsrlw", 0xFD1, 0x66, D, EVEX | L2 | N2 | MK | MZ, k3(K::Z, K::ZV, K::XM)),
    v("vpsubb", 0xFF8, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpsubb", 0xFF8, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsubb", 0xFF8, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsubd", 0xFFA, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpsubd", 0xFFA, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsubd", 0xFFA, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsubq", 0xFFB, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpsubq", 0xFFB, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsubq", 0xFFB, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsubsb", 0xFE8, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpsubsb", 0xFE8, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsubsb", 0xFE8, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsubsw", 0xFE9, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpsubsw", 0xFE9, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsubsw", 0xFE9, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsubusb", 0xFD8, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpsubusb", 0xFD8, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsubusb", 0xFD8, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsubusw", 0xFD9, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpsubusw", 0xFD9, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsubusw", 0xFD9, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpsubw", 0xFF9, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vpsubw", 0xFF9, 0x66, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vpsubw", 0xFF9, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vpternlogd", 0xF3A25, 0x66, D, EVEX | L2 | MK | MZ, k4(K::Z, K::ZV, K::ZM, K::I8)),
    v("vpunpcklqdq", 0xF6C, 0x66, D, VEX, k3(K::X, K::XV, K::XM)),
    v("vpunpcklqdq", 0xF6C, 0x66, D, EVEX | W1 | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vpxor", 0xFEF, 0x66, D, VEX | SWP, k3(K::X, K::XV, K::XM)),
    v("vpxorq", 0xFEF, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vrndscalepd", 0xF3A09, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZM, K::I8)),
    v("vrndscaleps", 0xF3A08, 0x66, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZM, K::I8)),
    v("vroundpd", 0xF3A09, 0x66, D, VEX | L1, k3(K::Y, K::YM, K::I8)),
    v("vroundps", 0xF3A08, 0x66, D, VEX | L1, k3(K::Y, K::YM, K::I8)),
    v("vscatterqpd", 0xF38A3, 0x66, D, EVEX | W1 | L2 | N3 | MK | MR, k2(K::VSZ, K::Z)),
    v("vscatterqps", 0xF38A3, 0x66, D, EVEX | L2 | N6 | MK | MR, k2(K::VSZ, K::Y)),
    v("vshufps", 0xFC6, 0, D, VEX, k4(K::X, K::XV, K::XM, K::I8)),
    v("vshufps", 0xFC6, 0, D, EVEX | MK | MZ, k4(K::X, K::XV, K::XM, K::I8)),
    v("vsqrtpd", 0xF51, 0x66, D, VEX | L1, k2(K::Y, K::YM)),
    v("vsqrtpd", 0xF51, 0x66, D, EVEX | W1 | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vsqrtpd", 0xF51, 0x66, D, EVEX | W1 | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vsqrtps", 0xF51, 0, D, VEX | L1, k2(K::Y, K::YM)),
    v("vsqrtps", 0xF51, 0, D, EVEX | L1 | MK | MZ, k2(K::Y, K::YM)),
    v("vsqrtps", 0xF51, 0, D, EVEX | L2 | MK | MZ, k2(K::Z, K::ZM)),
    v("vsubpd", 0xF5C, 0x66, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vsubpd", 0xF5C, 0x66, D, EVEX | W1 | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vsubpd", 0xF5C, 0x66, D, EVEX | W1 | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vsubps", 0xF5C, 0, D, VEX | L1, k3(K::Y, K::YV, K::YM)),
    v("vsubps", 0xF5C, 0, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vsubps", 0xF5C, 0, D, EVEX | L2 | MK | MZ, k3(K::Z, K::ZV, K::ZM)),
    v("vxorps", 0xF57, 0, D, VEX | SWP, k3(K::X, K::XV, K::XM)),
    v("vxorps", 0xF57, 0, D, VEX | L1 | SWP, k3(K::Y, K::YV, K::YM)),
    v("vxorps", 0xF57, 0, D, EVEX | MK | MZ, k3(K::X, K::XV, K::XM)),
    v("vxorps", 0xF57, 0, D, EVEX | L1 | MK | MZ, k3(K::Y, K::YV, K::YM)),
    v("vzeroupper", 0xF77, 0, N, VEX, 0),
];

// ---- Instructions ----

/// No register.
pub(package) const NOREG: u8 = x::NOREG;
/// ah, ch, dh, bh: 16 + their encoding (4 to 7). An instruction with a REX prefix cannot name them.
pub(package) const AH: u8 = 20;

/// An instruction in Intel operand order: its row, operand size (1, 2, 4 or 8 bytes; 0 for a row
/// without one), condition (`x::CC_*`, for an `F_CC` row), prefixes, the EVEX mask register (0 for
/// none) and zeroing, a register per operand position (a byte each in `regs`; ACC and CL hold theirs),
/// the memory operand at position `mem_at` (`NOMEM` for none; a VSIB operand's index is a vector
/// register), and the immediate or the branch target's offset from the instruction's start.
pub(package) struct Ins {
    pub(package) row: u32,
    pub(package) sz: u8,
    pub(package) cc: u8,
    pub(package) lock: bool,
    pub(package) data16: u8, // 0x66 prefixes past the one the operand size needs (`data16`)
    pub(package) rexw: bool, // REX.W where the operand size does not need it (`rex64`)
    pub(package) disp: u8, // a displacement or branch offset of this many bits where another would do: 0 (the shortest), 8 or 32
    pub(package) seg: u8, // a segment override prefix byte, 0 for none
    pub(package) kmask: u8,
    pub(package) zero: bool,
    pub(package) regs: u32,
    pub(package) mem_at: u8,
    pub(package) m: x::Mem,
    pub(package) imm: i64,
}

extend Ins as Copy {}

pub(package) const NOMEM: u8 = 0xFF;

extend Ins {
    pub(package) const fn new(row: u32) Ins {
        return Ins {
            row: row,
            sz: 0,
            cc: 0,
            lock: false,
            data16: 0,
            rexw: false,
            disp: 0,
            seg: 0,
            kmask: 0,
            zero: false,
            regs: 0,
            mem_at: NOMEM,
            m: x::at(NOREG, 0),
            imm: 0,
        };
    }

    /// The register at operand position `i`.
    pub(package) const fn reg(self: &Self, i: u32) u8 {
        return (self.regs >> i * 8 & 0xFF) as u8;
    }

    pub(package) const fn set_reg(self: &mut Self, i: u32, r: u8) {
        self.regs = self.regs & ~(0xFFu32 << i * 8) | r as u32 << i * 8;
    }
}

/// Where an encoding's 32-bit RIP displacement or branch offset lies from the instruction's start
/// (`NOFIELD` for none), and the instruction's length.
pub(package) struct Enc {
    pub(package) field: u32,
    pub(package) len: u32,
}

pub(package) const NOFIELD: u32 = 0xFFFFFFFF;

extend Enc {
    pub(package) const fn new() Enc {
        return Enc { field: NOFIELD, len: 0 };
    }
}

/// The size in bytes of the general register an operand of kind `k` names at operand size `sz`, 0 for
/// a kind that names none.
pub(package) const fn gp_size(k: u8, sz: u8) u8 {
    return switch k {
        K::R | K::RM | K::O | K::ACC => sz,
        K::RM8 | K::CL => 1u8,
        K::RM16 => 2u8,
        K::RM32 | K::R32 | K::RR32 => 4u8,
        K::IND | K::R64 | K::RR64 | K::RM64 => 8u8,
        _ => 0u8,
    };
}

/// Whether kind `k` is in ModRM.reg.
pub(package) const fn in_reg(k: u8) bool {
    return k == K::R || k == K::R32 || k == K::R64 || k == K::X || k == K::Y || k == K::Z || k == K::KR;
}

/// Whether kind `k` is in ModRM.rm.
pub(package) const fn in_rm(k: u8) bool {
    return switch k {
        K::RM | K::M | K::RM8 | K::RM16 | K::RM32 | K::RM64 | K::RR32 | K::RR64 | K::XM | K::XR | K::YM | K::YR | K::ZM | K::ZR | K::KRM | K::IND | K::VSX | K::VSY | K::VSZ => true,
        _ => false,
    };
}

/// Whether kind `k` is in ModRM.rm and memory only.
pub(package) const fn mem_only(k: u8) bool {
    return k == K::M || k == K::VSX || k == K::VSY || k == K::VSZ;
}

/// Whether kind `k` is in ModRM.rm and a register only.
pub(package) const fn reg_only(k: u8) bool {
    return k == K::XR || k == K::YR || k == K::ZR || k == K::KRM || k == K::RR32 || k == K::RR64;
}

/// Whether kind `k` is in VEX.vvvv.
pub(package) const fn in_vvvv(k: u8) bool {
    return k == K::XV || k == K::YV || k == K::ZV || k == K::KV;
}

/// Whether kind `k` names a mask register.
pub(package) const fn is_kreg(k: u8) bool {
    return k == K::KR || k == K::KRM || k == K::KV;
}

/// The vector register width in bytes kind `k` names (a VSIB operand's index), 0 for none.
pub(package) const fn vec_size(k: u8) u32 {
    return switch k {
        K::X | K::XM | K::XR | K::XV | K::XI4 | K::X0 | K::VSX => 16u32,
        K::Y | K::YM | K::YR | K::YV | K::YI4 | K::VSY => 32u32,
        K::Z | K::ZM | K::ZR | K::ZV | K::VSZ => 64u32,
        _ => 0u32,
    };
}

/// Whether kind `k` is a VSIB memory operand.
pub(package) const fn is_vsib(k: u8) bool {
    return k == K::VSX || k == K::VSY || k == K::VSZ;
}

// The VEX and EVEX map of opcode `op` (its escape bytes).
const fn map_of(op: u32) u32 {
    return switch op >> 8 {
        0x0F38 => 2u32,
        0x0F3A => 3u32,
        _ => 1u32,
    };
}

// The EVEX 8-bit displacement's scale of row form `vx`.
const fn disp8_scale(vx: u16) i32 {
    let c = vx as i32 >> 3 & 15;
    if c < 4 {
        return 16i32 << (vx as i32 >> 10 & 3) >> c;
    }
    return 1i32 << c - 4;
}

// Whether the swap of `SWPC` applies to predicate `imm`.
const fn swaps_pred(imm: i64) bool {
    let p = imm & 7;
    return p == 0 || p == 3 || p == 4 || p == 7;
}

/// Whether kind `k` is an immediate.
pub(package) const fn is_imm(k: u8) bool {
    return k == K::I8 || k == K::IS8 || k == K::IZ || k == K::I64;
}

const fn within(v: i64, lo: i64, hi: i64) bool {
    return v >= lo && v <= hi;
}

// Bit 3 of register `g`: its REX bit.
const fn hi(g: u8) u32 {
    return g as u32 >> 3 & 1;
}

// VEX.pp of mandatory prefix `p`.
const fn pp_of(p: u8) u32 {
    return switch p {
        0x66 => 1u32,
        0xF3 => 2u32,
        0xF2 => 3u32,
        _ => 0u32,
    };
}

// `n` little-endian bytes of `v` onto `out`.
fn put(out: &mut Vector<u8>, v: u64, n: u32) {
    for i in 0..n {
        out.push((v >> 8 * i & 0xFF) as u8);
    }
}

// Whether `v` is an `sz`-byte operand value (signed or unsigned) whose truncation sign-extends from 8
// bits; `t` gets that byte.
const fn sext8(v: i64, sz: u8, t: &mut i64) bool {
    if sz < 8 {
        let bits = sz as u32 * 8;
        if !within(v, -(1i64 << bits - 1), (1i64 << bits) - 1) {
            return false;
        }
        let s = 64 - bits;
        *t = v << s >> s;
    } else {
        *t = v;
    }
    return within(*t, -128, 127);
}

// ModRM, SIB and displacement of memory operand `m` with ModRM.reg `rg`; 8-bit displacements count in
// `n8`-byte units; `disp` forces a width; `vsib`: the index is a vector register, which it needs.
fn modrm_mem(out: &mut Vector<u8>, rg: u32, m: x::Mem, n8: i32, disp: u8, vsib: bool, st: usize, e: &mut Enc) bool {
    let r3 = (rg & 7) << 3;
    if m.index == x::RSP && !vsib || m.scale > 3 || vsib && (m.index == NOREG || m.index > 15 || m.base == x::RIP) {
        return false;
    }
    if m.base == x::RIP {
        if m.index != NOREG || disp == 8 {
            return false;
        }
        out.push((r3 | 5) as u8);
        e.field = (out.len() - st) as u32;
        put(out, m.disp as u32, 4);
        return true;
    }
    let idx = if m.index == NOREG {
        4u32;
    } else {
        m.index as u32 & 7;
    };
    if m.base == NOREG {
        if disp == 8 {
            return false;
        }
        out.push((r3 | 4) as u8);
        out.push((m.scale as u32 << 6 | idx << 3 | 5) as u8);
        put(out, m.disp as u32, 4);
        return true;
    }
    let base = m.base as u32 & 7;
    let fits8 = m.disp % n8 == 0 && m.disp / n8 >= -128 && m.disp / n8 < 128;
    let md: u32 = if disp == 32 {
        2;
    } else if disp == 8 {
        if !fits8 {
            return false;
        }
        1;
    } else if m.disp == 0 && base != 5 {
        0;
    } else if fits8 {
        1;
    } else {
        2;
    };
    if m.index == NOREG && base != 4 {
        out.push((md << 6 | r3 | base) as u8);
    } else {
        out.push((md << 6 | r3 | 4) as u8);
        out.push((m.scale as u32 << 6 | idx << 3 | base) as u8);
    }
    if md == 1 {
        out.push((m.disp / n8) as u8);
    } else if md == 2 {
        put(out, m.disp as u32, 4);
    }
    return true;
}

/// Append the encoding of `n` to `out`; false when its row does not take its operands.
pub(package) fn encode(n: &Ins, out: &mut Vector<u8>, e: &mut Enc) bool {
    let rows: []Row = ROWS;
    let r = rows[n.row as usize];
    let st = out.len();
    e.field = NOFIELD;
    if r.sz == 0 && n.sz != 0 || r.sz != 0 && (n.sz == 0 || n.sz > 8 || (r.sz & n.sz) == 0) || n.cc > 15 {
        return false;
    }
    let ve = r.vx & 3;
    if ve != EVEX && (n.kmask != 0 || n.zero) || ve != 0 && (n.rexw || n.data16 != 0) {
        return false;
    }
    let mut regf: u8 = NOREG;
    let mut rmr: u8 = NOREG;
    let mut vvr: u8 = 0;
    let mut is4: u8 = NOREG;
    let mut mem = false;
    let mut vsib = false;
    let mut orr: u8 = NOREG;
    let mut immk: u8 = 0;
    let mut relk: u8 = 0;
    let mut want_rex = false;
    let mut no_rex = false;
    for i in 0..4u32 {
        let k = kind_at(r.ops, i);
        if k == 0 {
            break;
        }
        let g = n.reg(i);
        let is_mem = n.mem_at as u32 == i;
        if is_mem && !in_rm(k) || mem_only(k) && !is_mem || reg_only(k) && is_mem {
            return false;
        }
        if in_reg(k) {
            regf = g;
        } else if in_rm(k) {
            if is_mem {
                mem = true;
                vsib = is_vsib(k);
            } else {
                rmr = g;
            }
        } else if in_vvvv(k) {
            vvr = g;
        } else if k == K::XI4 || k == K::YI4 {
            is4 = g;
        } else if k == K::O {
            orr = g;
        } else if is_imm(k) {
            immk = k;
        } else if k == K::REL8 || k == K::REL32 {
            relk = k;
        }
        let gs = gp_size(k, n.sz);
        if is_mem || k == K::ACC || k == K::CL {
            continue;
        }
        if gs != 0 {
            if g > AH + 3 || g >= 16 && (gs != 1 || g < AH) {
                return false;
            }
            if gs == 1 && g >= 4 && g < 8 {
                want_rex = true;
            }
            if g >= AH {
                no_rex = true;
            }
        } else if is_kreg(k) && g > 7 || vec_size(k) != 0 && g > 15 || k == K::X0 && g != 0 {
            return false;
        }
    }
    if n.mem_at != NOMEM && !mem || (n.seg != 0 || n.lock) && !mem || n.lock && (r.fl & F_LOCK) == 0 {
        return false;
    }
    // `xchg %eax, %eax` zero-extends: 0x90 is `nop`.
    if (r.fl & F_OR) != 0 && r.op == 0x90 && orr == 0 && n.sz == 4 {
        return false;
    }
    // The sources swap when that gives the 2-byte VEX prefix.
    if (r.vx & (SWP | SWPC)) != 0 && !mem && hi(rmr) == 1 && hi(vvr) == 0 && ((r.vx & SWPC) == 0 || swaps_pred(n.imm)) {
        let t0 = rmr;
        rmr = vvr;
        vvr = t0;
    }
    let mut rex: u32 = 0;
    if n.sz == 8 && (r.fl & F_D64) == 0 || n.rexw {
        rex |= 8;
    }
    if regf != NOREG {
        rex |= hi(regf) << 2;
    }
    if mem {
        if n.m.index != NOREG {
            rex |= hi(n.m.index) << 1;
        }
        if n.m.base != x::RIP && n.m.base != NOREG {
            rex |= hi(n.m.base);
        }
    } else if rmr != NOREG {
        rex |= hi(rmr);
    }
    if orr != NOREG {
        rex |= hi(orr);
    }
    // The prefixes in the order GNU as and LLVM give them.
    if n.seg != 0 {
        out.push(n.seg);
    }
    for _ in 0..n.data16 {
        out.push(0x66);
    }
    if n.sz == 2 && r.pfx != 0x66 {
        out.push(0x66);
    }
    if n.lock {
        out.push(0xF0);
    }
    let mut n8: i32 = 1;
    if ve != 0 {
        let pp = pp_of(r.pfx);
        let mp = map_of(r.op);
        let w = r.vx as u32 >> 2 & 1;
        let l = r.vx as u32 >> 10 & 3;
        let rr = ~rex >> 2 & 1;
        let xx = ~rex >> 1 & 1;
        let bb = ~rex & 1;
        let vv = ~(vvr as u32) & 15;
        if (r.vx & MV) != 0 && !mem && bb == 0 && rr == 1 {
            return false;
        }
        if ve == VEX {
            if xx == 1 && bb == 1 && w == 0 && mp == 1 {
                out.push(0xC5);
                out.push((rr << 7 | vv << 3 | l << 2 | pp) as u8);
            } else {
                out.push(0xC4);
                out.push((rr << 7 | xx << 6 | bb << 5 | mp) as u8);
                out.push((w << 7 | vv << 3 | l << 2 | pp) as u8);
            }
        } else {
            // A mask where the row takes one, zeroing under one and into a register.
            if n.kmask > 7 || n.kmask != 0 && (r.vx & MK) == 0 || n.kmask == 0 && (r.vx & MR) != 0 || n.zero && ((r.vx & MZ) == 0 || n.kmask == 0 || n.mem_at == 0) {
                return false;
            }
            out.push(0x62);
            out.push((rr << 7 | xx << 6 | bb << 5 | 1u32 << 4 | mp) as u8);
            out.push((w << 7 | vv << 3 | 4 | pp) as u8);
            out.push((n.zero as u32 << 7 | l << 5 | 1u32 << 3 | n.kmask as u32) as u8);
            n8 = disp8_scale(r.vx);
        }
        out.push((r.op & 0xFF) as u8);
    } else {
        if r.pfx != 0 {
            out.push(r.pfx);
        }
        if rex != 0 || want_rex {
            if no_rex {
                return false;
            }
            out.push((0x40 | rex) as u8);
        }
        let mut op = r.op;
        if (r.fl & F_OR) != 0 {
            op += orr as u32 & 7;
        }
        if (r.fl & F_CC) != 0 {
            op += n.cc;
        }
        if op > 0xFFFF {
            out.push((op >> 16) as u8);
        }
        if op > 0xFF {
            out.push((op >> 8 & 0xFF) as u8);
        }
        out.push((op & 0xFF) as u8);
    }
    if r.dig != D_NONE {
        if (r.dig & D_FIX) != 0 {
            out.push(fixed_modrm(r.dig));
        } else {
            let rg: u32 = if r.dig == D_REG {
                regf as u32 & 7;
            } else {
                r.dig;
            };
            if mem {
                if !modrm_mem(out, rg, n.m, n8, n.disp, vsib, st, e) {
                    return false;
                }
            } else {
                out.push((0xC0 | rg << 3 | rmr as u32 & 7) as u8);
            }
        }
    }
    let v = n.imm;
    if immk == K::I8 {
        if !within(v, -128, 255) {
            return false;
        }
        out.push((v & 0xFF) as u8);
    } else if immk == K::IS8 {
        let mut t: i64 = 0;
        if !sext8(v, n.sz, &mut t) {
            return false;
        }
        out.push((t & 0xFF) as u8);
    } else if immk == K::IZ {
        let ok = switch n.sz {
            2 => within(v, -0x8000, 0xFFFF),
            8 => within(v, -0x80000000, 0x7FFFFFFF),
            _ => within(v, -0x80000000, 0xFFFFFFFF),
        };
        if !ok {
            return false;
        }
        put(
            out,
            v as u64,
            if n.sz == 2 {
                2u32;
            } else {
                4u32;
            },
        );
    } else if immk == K::I64 {
        put(out, v as u64, 8);
    }
    if is4 != NOREG {
        out.push(is4 << 4);
    }
    if relk != 0 {
        let here = (out.len() - st) as i64;
        if relk == K::REL8 {
            let d = v - (here + 1);
            if n.disp == 32 || !within(d, -128, 127) {
                return false;
            }
            out.push((d & 0xFF) as u8);
        } else {
            let d = v - (here + 4);
            if !within(d, -0x80000000, 0x7FFFFFFF) {
                return false;
            }
            e.field = here as u32;
            put(out, d as u64, 4);
        }
    }
    e.len = (out.len() - st) as u32;
    return true;
}

// The little-endian `n`-byte value at `b[at..]`, sign-extended when `signed`.
const fn get(b: []u8, at: usize, n: u32, signed: bool) i64 {
    let mut v: u64 = 0;
    for i in 0..n {
        v |= b[at + i as usize] as u64 << 8 * i;
    }
    if !signed || n == 8 {
        return v as i64;
    }
    let s = 64 - 8 * n;
    return (v << s) as i64 >> s;
}

/// Decode the instruction at `b[at..]` into `n`: its length, 0 when no row encodes those bytes in the
/// form the assembler gives them.
pub(package) fn decode(b: []u8, at: usize, n: &mut Ins) u32 {
    let end = if b.len() < at + 15 {
        b.len();
    } else {
        at + 15;
    };
    let mut p = at;
    let mut lock = false;
    let mut seg: u8 = 0;
    let mut c66: u8 = 0;
    let mut rep: u8 = 0;
    // Legacy prefixes: at most 15 bytes in all.
    while p < end {
        let c = b[p];
        if c == 0xF0 && !lock {
            lock = true;
        } else if c == 0x66 {
            c66 += 1;
        } else if (c == 0xF2 || c == 0xF3) && rep == 0 {
            rep = c;
        } else if (c == 0x2E || c == 0x3E || c == 0x26 || c == 0x36 || c == 0x64 || c == 0x65) && seg == 0 {
            seg = c;
        } else {
            break;
        }
        p += 1;
    }
    let mut rex: u32 = 0;
    let mut has_rex = false;
    if p < end && (b[p] & 0xF0) == 0x40 {
        rex = b[p] as u32 & 0xF;
        has_rex = true;
        p += 1;
    }
    // The VEX or EVEX fields: the form, map, pp, W, L, vvvv (the register), mask and zeroing.
    let mut vex: u16 = 0;
    let mut vmap: u32 = 0;
    let mut vpp: u32 = 0;
    let mut vw: u32 = 0;
    let mut vl: u32 = 0;
    let mut vvv: u8 = 0;
    let mut vk: u8 = 0;
    let mut vz = false;
    if !has_rex && p < end && (b[p] == 0xC4 || b[p] == 0xC5 || b[p] == 0x62) {
        if rep != 0 || c66 != 0 || lock {
            return 0;
        }
        let c = b[p];
        if c == 0xC5 {
            if p + 1 >= end {
                return 0;
            }
            let b1 = b[p + 1] as u32;
            rex = (~b1 >> 7 & 1) << 2;
            vvv = (~b1 >> 3 & 15) as u8;
            vl = b1 >> 2 & 1;
            vpp = b1 & 3;
            vmap = 1;
            vex = VEX;
            p += 2;
        } else if c == 0xC4 {
            if p + 2 >= end {
                return 0;
            }
            let b1 = b[p + 1] as u32;
            let b2 = b[p + 2] as u32;
            vmap = b1 & 31;
            rex = (~b1 >> 7 & 1) << 2 | (~b1 >> 6 & 1) << 1 | ~b1 >> 5 & 1;
            vw = b2 >> 7;
            vvv = (~b2 >> 3 & 15) as u8;
            vl = b2 >> 2 & 1;
            vpp = b2 & 3;
            vex = VEX;
            p += 3;
        } else {
            if p + 3 >= end {
                return 0;
            }
            let p0 = b[p + 1] as u32;
            let p1 = b[p + 2] as u32;
            let p2 = b[p + 3] as u32;
            // No register past 15 (R' and V' set), no broadcast or rounding, a vector length to 512.
            if (p0 >> 4 & 1) != 1 || (p0 & 8) != 0 || (p1 >> 2 & 1) != 1 || (p2 >> 3 & 3) != 1 || (p2 >> 5 & 3) > 2 {
                return 0;
            }
            vmap = p0 & 7;
            rex = (~p0 >> 7 & 1) << 2 | (~p0 >> 6 & 1) << 1 | ~p0 >> 5 & 1;
            vw = p1 >> 7;
            vvv = (~p1 >> 3 & 15) as u8;
            vpp = p1 & 3;
            vz = p2 >> 7 != 0;
            vl = p2 >> 5 & 3;
            vk = (p2 & 7) as u8;
            vex = EVEX;
            p += 4;
        }
        if vmap < 1 || vmap > 3 {
            return 0;
        }
    }
    if p >= end {
        return 0;
    }
    let mut op = b[p] as u32;
    let mut olen: usize = 1;
    if vex != 0 {
        op |= (switch vmap {
            1 => 0x0F00u32,
            2 => 0x0F3800u32,
            _ => 0x0F3A00u32,
        });
    } else if op == 0x0F {
        if p + 1 >= end {
            return 0;
        }
        let o1 = b[p + 1] as u32;
        if o1 == 0x38 || o1 == 0x3A {
            if p + 2 >= end {
                return 0;
            }
            op = 0x0F0000 | o1 << 8 | b[p + 2] as u32;
            olen = 3;
        } else {
            op = 0x0F00 | o1;
            olen = 2;
        }
    }
    p += olen;
    let rows: []Row = ROWS;
    for ri in 0..rows.len() {
        let r = rows[ri];
        if (r.vx & 3) != vex {
            continue;
        }
        let mask: u32 = if (r.fl & F_OR) != 0 {
            ~7u32;
        } else if (r.fl & F_CC) != 0 {
            ~15u32;
        } else {
            ~0u32;
        };
        if (op & mask) != r.op {
            continue;
        }
        let mut x66 = c66;
        if vex != 0 {
            if pp_of(r.pfx) != vpp || (r.vx as u32 >> 2 & 1) != vw || (r.vx as u32 >> 10 & 3) != vl {
                continue;
            }
            if vk != 0 && (r.vx & MK) == 0 || vk == 0 && (r.vx & MR) != 0 || vz && ((r.vx & MZ) == 0 || vk == 0) {
                continue;
            }
        } else if r.pfx == 0x66 {
            if x66 == 0 || rep != 0 {
                continue;
            }
            x66 -= 1;
        } else if r.pfx != rep {
            continue;
        }
        let w = (rex & 8) != 0;
        let mut sz: u8 = 0;
        let mut rexw = w;
        if r.sz == SB {
            sz = 1;
        } else if r.sz != 0 && (r.fl & F_D64) != 0 {
            sz = 8;
            if x66 > 0 {
                sz = 2;
                x66 -= 1;
            }
        } else if r.sz != 0 {
            rexw = false;
            if w {
                sz = 8;
            } else if x66 > 0 {
                sz = 2;
                x66 -= 1;
            } else {
                sz = 4;
            }
        }
        if r.sz != 0 && (r.sz & sz) == 0 || lock && (r.fl & F_LOCK) == 0 {
            continue;
        }
        let mut q = p;
        let mut modrm: u32 = 0;
        if r.dig != D_NONE {
            if q >= end {
                continue;
            }
            modrm = b[q];
            q += 1;
            if (r.dig & D_FIX) != 0 {
                if modrm != fixed_modrm(r.dig) as u32 {
                    continue;
                }
            } else if r.dig < 8 && (modrm >> 3 & 7) != r.dig as u32 {
                continue;
            }
        }
        let regform = modrm >> 6 == 3;
        let mut v = Ins::new(ri as u32);
        v.sz = sz;
        v.lock = lock;
        v.data16 = x66;
        v.rexw = rexw;
        v.seg = seg;
        v.kmask = vk;
        v.zero = vz;
        if (r.fl & F_CC) != 0 {
            v.cc = (op & 15) as u8;
        }
        let mut ok = true;
        let mut immk: u8 = 0;
        let mut relk: u8 = 0;
        let mut is4: i32 = -1;
        let mut has_vvvv = false;
        let mut vsib = false;
        for i in 0..4u32 {
            let k = kind_at(r.ops, i);
            if k == 0 {
                break;
            }
            let mut g: u8 = 0;
            if in_reg(k) {
                g = (modrm >> 3 & 7 | (rex >> 2 & 1) << 3) as u8;
            } else if in_rm(k) {
                if regform {
                    g = (modrm & 7 | (rex & 1) << 3) as u8;
                    ok = ok && !mem_only(k);
                } else {
                    v.mem_at = i as u8;
                    vsib = is_vsib(k);
                    ok = ok && !reg_only(k);
                }
            } else if in_vvvv(k) {
                g = vvv;
                has_vvvv = true;
            } else if k == K::XI4 || k == K::YI4 {
                is4 = i as i32;
            } else if k == K::O {
                g = (op & 7 | (rex & 1) << 3) as u8;
            } else if k == K::CL {
                g = 1;
            } else if is_imm(k) {
                immk = k;
            } else if k == K::REL8 || k == K::REL32 {
                relk = k;
            }
            if gp_size(k, sz) == 1 && !has_rex && g >= 4 && g < 8 && v.mem_at as u32 != i && k != K::CL {
                g += 16;
            }
            v.set_reg(i, g);
        }
        if !ok || seg != 0 && v.mem_at == NOMEM || !has_vvvv && vvv != 0 {
            continue;
        }
        // The memory operand.
        if v.mem_at != NOMEM {
            let md = modrm >> 6;
            let rm = modrm & 7;
            let mut m = x::at(NOREG, 0);
            if rm == 4 {
                if q >= end {
                    continue;
                }
                let sib = b[q] as u32;
                q += 1;
                let ix = sib >> 3 & 7 | (rex >> 1 & 1) << 3;
                m.index = if ix == 4 && !vsib {
                    NOREG;
                } else {
                    ix as u8;
                };
                m.scale = (sib >> 6) as u8;
                m.base = if (sib & 7) == 5 && md == 0 {
                    NOREG;
                } else {
                    (sib & 7 | (rex & 1) << 3) as u8;
                };
            } else if rm == 5 && md == 0 {
                m.base = x::RIP;
            } else {
                m.base = (rm | (rex & 1) << 3) as u8;
            }
            let dn: usize = if md == 1 {
                1;
            } else if md == 2 || m.base == x::RIP || m.base == NOREG {
                4;
            } else {
                0;
            };
            if q + dn > end {
                continue;
            }
            if dn != 0 {
                m.disp = get(b, q, dn as u32, true) as i32;
                if md == 1 && vex == EVEX {
                    m.disp *= disp8_scale(r.vx);
                }
            }
            q += dn;
            v.m = m;
        }
        let isz: usize = switch immk {
            K::I8 | K::IS8 => 1usize,
            K::IZ => if sz == 2 {
                2usize;
            } else {
                4usize;
            },
            K::I64 => 8usize,
            _ => 0usize,
        };
        let rsz: usize = if relk == K::REL8 {
            1;
        } else if relk == K::REL32 {
            4;
        } else {
            0;
        };
        let i4: usize = if is4 >= 0 {
            1;
        } else {
            0;
        };
        if q + isz + i4 + rsz > end {
            continue;
        }
        if immk != 0 {
            v.imm = get(b, q, isz as u32, immk != K::I8);
        }
        q += isz;
        if is4 >= 0 {
            v.set_reg(is4 as u32, b[q] >> 4);
        }
        q += i4;
        if relk != 0 {
            v.imm = get(b, q, rsz as u32, true) + (q + rsz - at) as i64;
        }
        q += rsz;
        let len = (q - at) as u32;
        // The form the assembler gives these operands must be these bytes: the shortest displacement,
        // else a forced one.
        let mut same = false;
        let mut tmp = Vector::<u8>::with_capacity(16);
        let mut e = Enc::new();
        for f in 0..3u32 {
            v.disp = (switch f {
                0 => 0u8,
                1 => 8u8,
                _ => 32u8,
            });
            tmp.truncate(0);
            if encode(&v, &mut tmp, &mut e) && tmp.len() == len as usize && tmp.as_slice() == b[at..q] {
                same = true;
                break;
            }
        }
        if !same {
            continue;
        }
        // A 32-bit branch the 8-bit form reaches.
        if relk == K::REL32 && r.mn != "call" && within(v.imm - 2, -128, 127) {
            v.disp = 32;
        }
        *n = v;
        return len;
    }
    return 0;
}
