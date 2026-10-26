// The arm64 instruction table: one row per instruction form, read by the code generator's encoder
// (`a64`), the assembler and the disassembler (`a64asm`). A row is a mnemonic, the fixed bits, a
// variant field and up to six operand kinds. The variant field (`Q::*`) holds the register width or
// lane arrangement the operands share (`w` or `x`, `s` or `d`, `.4s`), and a kind places one operand
// in its bits (`K::*`). The bits no operand or variant takes are the row's mask: a word is the row's
// when its masked bits equal the row's and every operand decodes. Aliases (`mov` for `orr` from the
// zero register) come before their base forms, so the disassembler prints the preferred name.

/// A row: `mn`, the fixed bits, the variant kind (`Q::*`) and the variant values it takes (a bit per
/// value), the operand kinds (one byte each from the low byte, 0 ends), and an alias condition
/// (`FL_*`).
pub struct Row {
    pub mn: str<'static>,
    pub bits: u32,
    pub q: u8,
    pub qok: u8,
    pub ops: u64,
    pub fl: u8,
}

extend Row as Copy {}

/// The operand values one instruction holds, in the order its kinds consume them.
pub const NV: usize = 8;

pub struct Vals {
    v: [i64; NV],
}

extend Vals {
    pub const fn new() Vals {
        return Vals { v: [0, 0, 0, 0, 0, 0, 0, 0] };
    }

    pub fn index(self: &Self, i: usize) &i64 {
        assert(i < NV, "an operand value past the last");
        return unsafe &self.v[i];
    }

    pub fn index_mut(self: &mut Self, i: usize) &mut i64 {
        assert(i < NV, "an operand value past the last");
        return unsafe &mut self.v[i];
    }
}

// ---- Variant kinds ----

/// Variant kinds.
pub struct Q {}

extend Q {
    pub const NONE: u8 = 0;
    pub const SF: u8 = 1;
    pub const SFN: u8 = 2;
    pub const FT: u8 = 3;
    pub const CVT: u8 = 4;
    pub const V: u8 = 5;
    pub const VF: u8 = 6;
    pub const VB: u8 = 7;
    pub const Z: u8 = 8;
    pub const B30: u8 = 9;
    pub const S22: u8 = 10;
    pub const FLS: u8 = 11;
    pub const FP: u8 = 12;
    pub const ZE: u8 = 13;
}

// Bit sets of variant values.
pub const QW: u8 = 1;
pub const QX: u8 = 2;
pub const QWX: u8 = 3;
pub const QSD: u8 = 3; // Q::FT: s and d
pub const QALL: u8 = 0x0F; // Q::Z: every element
pub const QV_NO1D: u8 = 0xBF; // Q::V: every arrangement but 1d
pub const QV_NOD: u8 = 0x3F; // Q::V: no 64-bit lanes
pub const QVF_ALL: u8 = 0x0B; // Q::VF: 2s 4s 2d

// ---- Operand kinds ----

/// Register classes: a register kind is `class * 4 + field + 1`, its field `(k - 1) % 4` (bits 0, 5,
/// 10, 16).
pub struct C {}

extend C {
    pub const R: u8 = 0; // w or x by the variant; 31 is the zero register
    pub const RS: u8 = 1; // w or x by the variant; 31 is sp
    pub const W: u8 = 2;
    pub const X: u8 = 3;
    pub const XS: u8 = 4; // x; 31 is sp
    pub const F: u8 = 5; // b h s d q by the variant
    pub const FS: u8 = 6;
    pub const FD: u8 = 7;
    pub const FH: u8 = 8;
    pub const FQ: u8 = 9;
    pub const FB: u8 = 10;
    pub const V: u8 = 11; // a vector register with the variant's arrangement
    pub const Z: u8 = 12; // an SVE register with the variant's element
    pub const ZB: u8 = 13;
    pub const ZS: u8 = 14;
    pub const ZD: u8 = 15;
    // A vector register of one fixed arrangement, whatever the variant: the arrangement `class - V8B`
    // (8b 16b 4h 8h 2s 4s 1d 2d).
    pub const V8B: u8 = 16;
    pub const V16B: u8 = 17;
    pub const V4H: u8 = 18;
    pub const V8H: u8 = 19;
    pub const V2S: u8 = 20;
    pub const V4S: u8 = 21;
    pub const V1D: u8 = 22;
    pub const V2D: u8 = 23;
}

/// Operand kinds: the register kinds 1 to 64 and 161 to 192 (the fixed arrangements), then the special
/// ones (the comment gives the values each consumes).
pub struct K {}

extend K {
    pub const RD: u8 = 1;
    pub const RN: u8 = 2;
    pub const RA: u8 = 3;
    pub const RM: u8 = 4;
    pub const RDS: u8 = 5;
    pub const RNS: u8 = 6;
    pub const WD: u8 = 9;
    pub const WN: u8 = 10;
    pub const WA: u8 = 11;
    pub const WM: u8 = 12;
    pub const XD: u8 = 13;
    pub const XN: u8 = 14;
    pub const XA: u8 = 15;
    pub const XM: u8 = 16;
    pub const XDS: u8 = 17;
    pub const XNS: u8 = 18;
    pub const XMS: u8 = 20;
    pub const FD: u8 = 21;
    pub const FN: u8 = 22;
    pub const FA: u8 = 23;
    pub const FM: u8 = 24;
    pub const SD: u8 = 25;
    pub const SN: u8 = 26;
    pub const DD: u8 = 29;
    pub const DN: u8 = 30;
    pub const HD: u8 = 33;
    pub const QD: u8 = 37;
    pub const QN: u8 = 38;
    pub const HN: u8 = 34;
    pub const VD: u8 = 45;
    pub const VN: u8 = 46;
    pub const VM: u8 = 48;
    pub const ZD: u8 = 49;
    pub const ZN: u8 = 50;
    pub const ZM: u8 = 52;
    pub const ZBN: u8 = 54;
    pub const ZBM: u8 = 56;
    pub const AIMM: u8 = 70; // imm12 at 10, shift bit 22: (imm, sh)
    pub const LIMM: u8 = 71; // N:immr:imms at 10: (field)
    pub const LIMMV: u8 = 72; // `mov` of a bitmask immediate movz and movn cannot make: (field)
    pub const MOVW: u8 = 73; // imm16 at 5, hw at 21: (imm16, hw)
    pub const MOVZV: u8 = 74; // `mov` of movz: (value)
    pub const MOVNV: u8 = 75; // `mov` of movn: (value)
    pub const IMMR: u8 = 76; // 6 bits at 16
    pub const IMMS: u8 = 77; // 6 bits at 10
    pub const SHL: u8 = 78; // `lsl` of ubfm: (shift)
    pub const SHR: u8 = 79; // `lsr`, `asr` of ubfm, sbfm: (shift)
    pub const BFX: u8 = 80; // the extract forms: (lsb, width)
    pub const BFIZ: u8 = 81; // the insert forms: (lsb, width)
    pub const LSH: u8 = 82; // shift type at 22, amount at 10, any type: (type, amount)
    pub const ASH: u8 = 83; // as K::LSH without ror
    pub const EXT: u8 = 84; // extend option at 13, amount at 10: (option, amount)
    pub const RMX: u8 = 85; // Rm at 16, w or x by the extend option
    pub const COND: u8 = 86; // at 12
    pub const CONDI: u8 = 87; // at 12, inverted; not al or nv
    pub const CONDM: u8 = 88; // at 0, in the mnemonic (`b.eq`)
    pub const NZCV: u8 = 89; // at 0
    pub const IMM5: u8 = 90; // at 16
    pub const IMM16: u8 = 91; // at 5
    pub const UDF16: u8 = 92; // at 0
    pub const FPIMM: u8 = 93; // imm8 at 13
    pub const FZERO: u8 = 94; // `#0.0`, no bits
    pub const L26: u8 = 95; // a byte offset, words at 0
    pub const L19: u8 = 96; // a byte offset, words at 5
    pub const L14: u8 = 97; // a byte offset, words at 5
    pub const ADR: u8 = 98; // a byte offset: immlo at 29, immhi at 5
    pub const ADRP: u8 = 99; // a byte offset in pages (a multiple of 4096)
    pub const TBIT: u8 = 100; // bit 5 at 31, bits 4:0 at 19
    pub const RTB: u8 = 101; // Rt at 0, w or x by the tested bit
    pub const MU12: u8 = 102; // [base{, #off}] scaled unsigned: (base, off)
    pub const MS9: u8 = 103; // [base{, #off}] unscaled: (base, off)
    pub const MPRE9: u8 = 104; // [base, #off]!: (base, off)
    pub const MPOST9: u8 = 105; // [base], #off: (base, off)
    pub const MREG: u8 = 106; // [base, rm{, ext #s}]: (base, rm, option, s)
    pub const MP7: u8 = 107; // pair [base{, #off}]: (base, off)
    pub const MPRE7: u8 = 108;
    pub const MPOST7: u8 = 109;
    pub const M0: u8 = 110; // [base]: (base)
    pub const SYSREG: u8 = 111; // o0:op1:CRn:CRm:op2 at 5
    pub const BARRIER: u8 = 112; // CRm at 8
    pub const ISB: u8 = 113; // CRm at 8, sy (15) when absent
    pub const XLR: u8 = 114; // Rn at 5, x30 when absent
    pub const RNM: u8 = 115; // Rn at 5 and Rm at 16, equal
    pub const VNM: u8 = 116; // Vn at 5 and Vm at 16, equal
    pub const FELEM: u8 = 117; // Rd at 0, a scalar of the arrangement's lane size
    pub const PG: u8 = 118; // Pg at 10 (p0 to p7)
    pub const PGZ: u8 = 119; // Pg/z at 10
    pub const PGM: u8 = 120; // Pg/m at 10
    pub const PMM: u8 = 121; // Pm/m at 13
    pub const PD: u8 = 122; // Pd.T at 0
    pub const PND: u8 = 123; // pn8 to pn15 .T at 0
    pub const PNGZ: u8 = 124; // pn8 to pn15 /z at 10
    pub const PNG: u8 = 125; // pn8 to pn15 at 10
    pub const ZL1: u8 = 126; // {zt.T} at 0
    pub const ZL2: u8 = 127; // {zt.T-zt+1.T}, zt / 2 at 1
    pub const ZL4: u8 = 128; // {zt.T-zt+3.T}, zt / 4 at 2
    pub const ZAT: u8 = 129; // za<n>.T at 0
    pub const ZASL: u8 = 130; // {za<n>h.T[w12+rs, off]}: (tile, vertical, rs, off)
    pub const ZAARR: u8 = 131; // za[w12+rv, off]: (rv, off), off at 0
    pub const MZA: u8 = 132; // [base{, #off, mul vl}], off the K::ZAARR one: (base)
    pub const ZAMASK: u8 = 133; // {za<n>.d, ..} as a tile mask at 0
    pub const PAT: u8 = 134; // the predicate pattern at 5, all (31) when absent
    pub const MULVL: u8 = 135; // mul #n, imm4 = n - 1 at 16, 1 when absent
    pub const SIMM6: u8 = 136; // at 5
    pub const MSV: u8 = 137; // [base{, #n, mul vl}], simm4 at 16: (base, n)
    pub const MSVR: u8 = 138; // [base{, rm, lsl #esize}], Rm at 16 (xzr when absent): (base, rm)
    pub const VLX: u8 = 139; // vlx2 or vlx4 at 13
    pub const SMSM: u8 = 140; // `sm`, no bits
    pub const SMZA: u8 = 141; // `za`, no bits
    pub const ELB: u8 = 143; // Vn.b[i]: Rn at 5, the index in imm5 at 16: (reg, index)
    pub const ELH: u8 = 144;
    pub const ELS: u8 = 145;
    pub const ELD: u8 = 146;
    pub const EDD: u8 = 147; // Vd.d[i]: Rd at 0, the index in imm5 at 16: (reg, index)
    pub const EN4D: u8 = 148; // Vn.d[j]: Rn at 5, the index in imm4 at 11: (reg, index)
    pub const LNB: u8 = 149; // { Vt.b }[i]: Rt at 0, the index in Q:S:size: (reg, index)
    pub const LNH: u8 = 150;
    pub const LNS: u8 = 151;
    pub const LND: u8 = 152;
    pub const L2B: u8 = 153; // { Vt.16b, .. }: 2, 3 or 4 registers from Rt at 0
    pub const L3B: u8 = 154;
    pub const L4B: u8 = 155;
    pub const T1B: u8 = 156; // { Vn.16b, .. }: 1 to 4 registers from Rn at 5
    pub const T2B: u8 = 157;
    pub const T3B: u8 = 158;
    pub const T4B: u8 = 159;
    pub const IMM4X: u8 = 160; // at 11
    // 161 to 192: the fixed-arrangement registers.
    pub const V8BD: u8 = 161;
    pub const V8BN: u8 = 162;
    pub const V8BM: u8 = 164;
    pub const V16BD: u8 = 165;
    pub const V16BN: u8 = 166;
    pub const V16BA: u8 = 167;
    pub const V16BM: u8 = 168;
    pub const V4HD: u8 = 169;
    pub const V4HN: u8 = 170;
    pub const V4HM: u8 = 172;
    pub const V8HD: u8 = 173;
    pub const V8HN: u8 = 174;
    pub const V8HM: u8 = 176;
    pub const V2SD: u8 = 177;
    pub const V2SN: u8 = 178;
    pub const V2SM: u8 = 180;
    pub const V4SD: u8 = 181;
    pub const V4SN: u8 = 182;
    pub const V4SM: u8 = 184;
    pub const V2DD: u8 = 189;
    pub const V2DN: u8 = 190;
    pub const V2DM: u8 = 192;
    pub const SHL8: u8 = 193; // a left shift below 8, 16 or 32 at 16 (immh:immb past the row's)
    pub const SHL16: u8 = 194;
    pub const SHL32: u8 = 195;
    pub const IMM6X: u8 = 196; // at 10
    pub const COUNT: u8 = 197;
}

// Register kinds 1 to 64: a class (`(k - 1) / 4`) and a field (`(k - 1) % 4`: bits 0, 5, 10, 16).

// Special kinds; the comment gives the values each consumes.

// Alias conditions a row adds to its bits and operands.
pub const FL_SPMOV: u8 = 1; // `mov` to or from sp: Rd or Rn is 31

// ---- Row builders ----

const fn r(mn: str<'static>, bits: u32, q: u8, qok: u8, ops: u64) Row {
    return Row { mn: mn, bits: bits, q: q, qok: qok, ops: ops, fl: 0 };
}

const fn rf(mn: str<'static>, bits: u32, q: u8, qok: u8, ops: u64, fl: u8) Row {
    return Row { mn: mn, bits: bits, q: q, qok: qok, ops: ops, fl: fl };
}

pub const fn k1(a: u8) u64 {
    return a;
}

pub const fn k2(a: u8, b: u8) u64 {
    return a as u64 | b as u64 << 8;
}

pub const fn k3(a: u8, b: u8, c: u8) u64 {
    return k2(a, b) | c as u64 << 16;
}

pub const fn k4(a: u8, b: u8, c: u8, d: u8) u64 {
    return k3(a, b, c) | d as u64 << 24;
}

pub const fn k5(a: u8, b: u8, c: u8, d: u8, e: u8) u64 {
    return k4(a, b, c, d) | e as u64 << 32;
}

/// Operand kind `i` of `ops`, 0 past the last.
pub const fn kind_at(ops: u64, i: u32) u8 {
    return (ops >> (i * 8) as u64 & 0xFF) as u8;
}

// ---- The table ----

pub const ROWS: [Row; 651] = [
    // Add and subtract, immediate.
    rf("mov", 0x11000000, Q::SF, QWX, k2(K::RDS, K::RNS), FL_SPMOV),
    r("cmp", 0x7100001F, Q::SF, QWX, k2(K::RNS, K::AIMM)),
    r("cmn", 0x3100001F, Q::SF, QWX, k2(K::RNS, K::AIMM)),
    r("add", 0x11000000, Q::SF, QWX, k3(K::RDS, K::RNS, K::AIMM)),
    r("adds", 0x31000000, Q::SF, QWX, k3(K::RD, K::RNS, K::AIMM)),
    r("sub", 0x51000000, Q::SF, QWX, k3(K::RDS, K::RNS, K::AIMM)),
    r("subs", 0x71000000, Q::SF, QWX, k3(K::RD, K::RNS, K::AIMM)),
    // Logical, immediate.
    r("tst", 0x7200001F, Q::SFN, QWX, k2(K::RN, K::LIMM)),
    r("and", 0x12000000, Q::SFN, QWX, k3(K::RDS, K::RN, K::LIMM)),
    r("orr", 0x32000000, Q::SFN, QWX, k3(K::RDS, K::RN, K::LIMM)),
    r("eor", 0x52000000, Q::SFN, QWX, k3(K::RDS, K::RN, K::LIMM)),
    r("ands", 0x72000000, Q::SFN, QWX, k3(K::RD, K::RN, K::LIMM)),
    // Move wide.
    r("mov", 0x52800000, Q::SF, QWX, k2(K::RD, K::MOVZV)),
    r("mov", 0x12800000, Q::SF, QWX, k2(K::RD, K::MOVNV)),
    r("mov", 0x320003E0, Q::SFN, QWX, k2(K::RDS, K::LIMMV)),
    r("movn", 0x12800000, Q::SF, QWX, k2(K::RD, K::MOVW)),
    r("movz", 0x52800000, Q::SF, QWX, k2(K::RD, K::MOVW)),
    r("movk", 0x72800000, Q::SF, QWX, k2(K::RD, K::MOVW)),
    // Bitfield.
    r("asr", 0x13007C00, Q::SFN, QWX, k3(K::RD, K::RN, K::SHR)),
    r("sxtb", 0x13001C00, Q::SFN, QWX, k2(K::RD, K::WN)),
    r("sxth", 0x13003C00, Q::SFN, QWX, k2(K::RD, K::WN)),
    r("sxtw", 0x93407C00, Q::NONE, 0, k2(K::XD, K::WN)),
    r("sbfiz", 0x13000000, Q::SFN, QWX, k3(K::RD, K::RN, K::BFIZ)),
    r("sbfx", 0x13000000, Q::SFN, QWX, k3(K::RD, K::RN, K::BFX)),
    r("sbfm", 0x13000000, Q::SFN, QWX, k4(K::RD, K::RN, K::IMMR, K::IMMS)),
    r("bfi", 0x33000000, Q::SFN, QWX, k3(K::RD, K::RN, K::BFIZ)),
    r("bfxil", 0x33000000, Q::SFN, QWX, k3(K::RD, K::RN, K::BFX)),
    r("bfm", 0x33000000, Q::SFN, QWX, k4(K::RD, K::RN, K::IMMR, K::IMMS)),
    r("lsr", 0x53007C00, Q::SFN, QWX, k3(K::RD, K::RN, K::SHR)),
    r("lsl", 0x53000000, Q::SFN, QWX, k3(K::RD, K::RN, K::SHL)),
    r("uxtb", 0x53001C00, Q::NONE, 0, k2(K::WD, K::WN)),
    r("uxth", 0x53003C00, Q::NONE, 0, k2(K::WD, K::WN)),
    r("ubfiz", 0x53000000, Q::SFN, QWX, k3(K::RD, K::RN, K::BFIZ)),
    r("ubfx", 0x53000000, Q::SFN, QWX, k3(K::RD, K::RN, K::BFX)),
    r("ubfm", 0x53000000, Q::SFN, QWX, k4(K::RD, K::RN, K::IMMR, K::IMMS)),
    // PC-relative addresses.
    r("adr", 0x10000000, Q::NONE, 0, k2(K::XD, K::ADR)),
    r("adrp", 0x90000000, Q::NONE, 0, k2(K::XD, K::ADRP)),
    // Logical, shifted register.
    r("mov", 0x2A0003E0, Q::SF, QWX, k2(K::RD, K::RM)),
    r("mvn", 0x2A2003E0, Q::SF, QWX, k3(K::RD, K::RM, K::LSH)),
    r("tst", 0x6A00001F, Q::SF, QWX, k3(K::RN, K::RM, K::LSH)),
    r("and", 0x0A000000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::LSH)),
    r("bic", 0x0A200000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::LSH)),
    r("orr", 0x2A000000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::LSH)),
    r("orn", 0x2A200000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::LSH)),
    r("eor", 0x4A000000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::LSH)),
    r("eon", 0x4A200000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::LSH)),
    r("ands", 0x6A000000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::LSH)),
    r("bics", 0x6A200000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::LSH)),
    // Add and subtract, shifted register.
    r("cmp", 0x6B00001F, Q::SF, QWX, k3(K::RN, K::RM, K::ASH)),
    r("cmn", 0x2B00001F, Q::SF, QWX, k3(K::RN, K::RM, K::ASH)),
    r("neg", 0x4B0003E0, Q::SF, QWX, k3(K::RD, K::RM, K::ASH)),
    r("negs", 0x6B0003E0, Q::SF, QWX, k3(K::RD, K::RM, K::ASH)),
    r("add", 0x0B000000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::ASH)),
    r("adds", 0x2B000000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::ASH)),
    r("sub", 0x4B000000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::ASH)),
    r("subs", 0x6B000000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::ASH)),
    // Add and subtract, extended register.
    r("cmp", 0x6B20001F, Q::SF, QWX, k3(K::RNS, K::RMX, K::EXT)),
    r("cmn", 0x2B20001F, Q::SF, QWX, k3(K::RNS, K::RMX, K::EXT)),
    r("add", 0x0B200000, Q::SF, QWX, k4(K::RDS, K::RNS, K::RMX, K::EXT)),
    r("adds", 0x2B200000, Q::SF, QWX, k4(K::RD, K::RNS, K::RMX, K::EXT)),
    r("sub", 0x4B200000, Q::SF, QWX, k4(K::RDS, K::RNS, K::RMX, K::EXT)),
    r("subs", 0x6B200000, Q::SF, QWX, k4(K::RD, K::RNS, K::RMX, K::EXT)),
    // Add and subtract with carry.
    r("ngc", 0x5A0003E0, Q::SF, QWX, k2(K::RD, K::RM)),
    r("ngcs", 0x7A0003E0, Q::SF, QWX, k2(K::RD, K::RM)),
    r("adc", 0x1A000000, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("adcs", 0x3A000000, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("sbc", 0x5A000000, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("sbcs", 0x7A000000, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    // Conditional compare.
    r("ccmn", 0x3A400000, Q::SF, QWX, k4(K::RN, K::RM, K::NZCV, K::COND)),
    r("ccmp", 0x7A400000, Q::SF, QWX, k4(K::RN, K::RM, K::NZCV, K::COND)),
    r("ccmn", 0x3A400800, Q::SF, QWX, k4(K::RN, K::IMM5, K::NZCV, K::COND)),
    r("ccmp", 0x7A400800, Q::SF, QWX, k4(K::RN, K::IMM5, K::NZCV, K::COND)),
    // Conditional select.
    r("cset", 0x1A9F07E0, Q::SF, QWX, k2(K::RD, K::CONDI)),
    r("csetm", 0x5A9F03E0, Q::SF, QWX, k2(K::RD, K::CONDI)),
    r("cinc", 0x1A800400, Q::SF, QWX, k3(K::RD, K::RNM, K::CONDI)),
    r("cinv", 0x5A800000, Q::SF, QWX, k3(K::RD, K::RNM, K::CONDI)),
    r("cneg", 0x5A800400, Q::SF, QWX, k3(K::RD, K::RNM, K::CONDI)),
    r("csel", 0x1A800000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::COND)),
    r("csinc", 0x1A800400, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::COND)),
    r("csinv", 0x5A800000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::COND)),
    r("csneg", 0x5A800400, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::COND)),
    // Data processing, two sources.
    r("udiv", 0x1AC00800, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("sdiv", 0x1AC00C00, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("lsl", 0x1AC02000, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("lsr", 0x1AC02400, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("asr", 0x1AC02800, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("ror", 0x1AC02C00, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("lslv", 0x1AC02000, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("lsrv", 0x1AC02400, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("asrv", 0x1AC02800, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("rorv", 0x1AC02C00, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    // Data processing, one source.
    r("rbit", 0x5AC00000, Q::SF, QWX, k2(K::RD, K::RN)),
    r("rev16", 0x5AC00400, Q::SF, QWX, k2(K::RD, K::RN)),
    r("rev", 0x5AC00800, Q::NONE, 0, k2(K::WD, K::WN)),
    r("rev32", 0xDAC00800, Q::NONE, 0, k2(K::XD, K::XN)),
    r("rev", 0xDAC00C00, Q::NONE, 0, k2(K::XD, K::XN)),
    r("clz", 0x5AC01000, Q::SF, QWX, k2(K::RD, K::RN)),
    r("cls", 0x5AC01400, Q::SF, QWX, k2(K::RD, K::RN)),
    // Data processing, three sources.
    r("mul", 0x1B007C00, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("mneg", 0x1B00FC00, Q::SF, QWX, k3(K::RD, K::RN, K::RM)),
    r("madd", 0x1B000000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::RA)),
    r("msub", 0x1B008000, Q::SF, QWX, k4(K::RD, K::RN, K::RM, K::RA)),
    r("smull", 0x9B207C00, Q::NONE, 0, k3(K::XD, K::WN, K::WM)),
    r("umull", 0x9BA07C00, Q::NONE, 0, k3(K::XD, K::WN, K::WM)),
    r("smnegl", 0x9B20FC00, Q::NONE, 0, k3(K::XD, K::WN, K::WM)),
    r("umnegl", 0x9BA0FC00, Q::NONE, 0, k3(K::XD, K::WN, K::WM)),
    r("smaddl", 0x9B200000, Q::NONE, 0, k4(K::XD, K::WN, K::WM, K::XA)),
    r("umaddl", 0x9BA00000, Q::NONE, 0, k4(K::XD, K::WN, K::WM, K::XA)),
    r("smsubl", 0x9B208000, Q::NONE, 0, k4(K::XD, K::WN, K::WM, K::XA)),
    r("umsubl", 0x9BA08000, Q::NONE, 0, k4(K::XD, K::WN, K::WM, K::XA)),
    r("smulh", 0x9B407C00, Q::NONE, 0, k3(K::XD, K::XN, K::XM)),
    r("umulh", 0x9BC07C00, Q::NONE, 0, k3(K::XD, K::XN, K::XM)),
    // Loads and stores, unsigned scaled offset.
    r("strb", 0x39000000, Q::NONE, 0, k2(K::WD, K::MU12)),
    r("ldrb", 0x39400000, Q::NONE, 0, k2(K::WD, K::MU12)),
    r("ldrsb", 0x39800000, Q::S22, QWX, k2(K::RD, K::MU12)),
    r("strh", 0x79000000, Q::NONE, 0, k2(K::WD, K::MU12)),
    r("ldrh", 0x79400000, Q::NONE, 0, k2(K::WD, K::MU12)),
    r("ldrsh", 0x79800000, Q::S22, QWX, k2(K::RD, K::MU12)),
    r("str", 0xB9000000, Q::B30, QWX, k2(K::RD, K::MU12)),
    r("ldr", 0xB9400000, Q::B30, QWX, k2(K::RD, K::MU12)),
    r("ldrsw", 0xB9800000, Q::NONE, 0, k2(K::XD, K::MU12)),
    r("str", 0x3D000000, Q::FLS, 0x1F, k2(K::FD, K::MU12)),
    r("ldr", 0x3D400000, Q::FLS, 0x1F, k2(K::FD, K::MU12)),
    // Loads and stores, unscaled offset.
    r("sturb", 0x38000000, Q::NONE, 0, k2(K::WD, K::MS9)),
    r("ldurb", 0x38400000, Q::NONE, 0, k2(K::WD, K::MS9)),
    r("ldursb", 0x38800000, Q::S22, QWX, k2(K::RD, K::MS9)),
    r("sturh", 0x78000000, Q::NONE, 0, k2(K::WD, K::MS9)),
    r("ldurh", 0x78400000, Q::NONE, 0, k2(K::WD, K::MS9)),
    r("ldursh", 0x78800000, Q::S22, QWX, k2(K::RD, K::MS9)),
    r("stur", 0xB8000000, Q::B30, QWX, k2(K::RD, K::MS9)),
    r("ldur", 0xB8400000, Q::B30, QWX, k2(K::RD, K::MS9)),
    r("ldursw", 0xB8800000, Q::NONE, 0, k2(K::XD, K::MS9)),
    r("stur", 0x3C000000, Q::FLS, 0x1F, k2(K::FD, K::MS9)),
    r("ldur", 0x3C400000, Q::FLS, 0x1F, k2(K::FD, K::MS9)),
    // Loads and stores, pre-index.
    r("strb", 0x38000C00, Q::NONE, 0, k2(K::WD, K::MPRE9)),
    r("ldrb", 0x38400C00, Q::NONE, 0, k2(K::WD, K::MPRE9)),
    r("ldrsb", 0x38800C00, Q::S22, QWX, k2(K::RD, K::MPRE9)),
    r("strh", 0x78000C00, Q::NONE, 0, k2(K::WD, K::MPRE9)),
    r("ldrh", 0x78400C00, Q::NONE, 0, k2(K::WD, K::MPRE9)),
    r("ldrsh", 0x78800C00, Q::S22, QWX, k2(K::RD, K::MPRE9)),
    r("str", 0xB8000C00, Q::B30, QWX, k2(K::RD, K::MPRE9)),
    r("ldr", 0xB8400C00, Q::B30, QWX, k2(K::RD, K::MPRE9)),
    r("ldrsw", 0xB8800C00, Q::NONE, 0, k2(K::XD, K::MPRE9)),
    r("str", 0x3C000C00, Q::FLS, 0x1F, k2(K::FD, K::MPRE9)),
    r("ldr", 0x3C400C00, Q::FLS, 0x1F, k2(K::FD, K::MPRE9)),
    // Loads and stores, post-index.
    r("strb", 0x38000400, Q::NONE, 0, k2(K::WD, K::MPOST9)),
    r("ldrb", 0x38400400, Q::NONE, 0, k2(K::WD, K::MPOST9)),
    r("ldrsb", 0x38800400, Q::S22, QWX, k2(K::RD, K::MPOST9)),
    r("strh", 0x78000400, Q::NONE, 0, k2(K::WD, K::MPOST9)),
    r("ldrh", 0x78400400, Q::NONE, 0, k2(K::WD, K::MPOST9)),
    r("ldrsh", 0x78800400, Q::S22, QWX, k2(K::RD, K::MPOST9)),
    r("str", 0xB8000400, Q::B30, QWX, k2(K::RD, K::MPOST9)),
    r("ldr", 0xB8400400, Q::B30, QWX, k2(K::RD, K::MPOST9)),
    r("ldrsw", 0xB8800400, Q::NONE, 0, k2(K::XD, K::MPOST9)),
    r("str", 0x3C000400, Q::FLS, 0x1F, k2(K::FD, K::MPOST9)),
    r("ldr", 0x3C400400, Q::FLS, 0x1F, k2(K::FD, K::MPOST9)),
    // Loads and stores, register offset.
    r("strb", 0x38200800, Q::NONE, 0, k2(K::WD, K::MREG)),
    r("ldrb", 0x38600800, Q::NONE, 0, k2(K::WD, K::MREG)),
    r("ldrsb", 0x38A00800, Q::S22, QWX, k2(K::RD, K::MREG)),
    r("strh", 0x78200800, Q::NONE, 0, k2(K::WD, K::MREG)),
    r("ldrh", 0x78600800, Q::NONE, 0, k2(K::WD, K::MREG)),
    r("ldrsh", 0x78A00800, Q::S22, QWX, k2(K::RD, K::MREG)),
    r("str", 0xB8200800, Q::B30, QWX, k2(K::RD, K::MREG)),
    r("ldr", 0xB8600800, Q::B30, QWX, k2(K::RD, K::MREG)),
    r("ldrsw", 0xB8A00800, Q::NONE, 0, k2(K::XD, K::MREG)),
    r("str", 0x3C200800, Q::FLS, 0x1F, k2(K::FD, K::MREG)),
    r("ldr", 0x3C600800, Q::FLS, 0x1F, k2(K::FD, K::MREG)),
    // Load and store pairs.
    r("stp", 0x29000000, Q::SF, QWX, k3(K::RD, K::RA, K::MP7)),
    r("ldp", 0x29400000, Q::SF, QWX, k3(K::RD, K::RA, K::MP7)),
    r("stp", 0x29800000, Q::SF, QWX, k3(K::RD, K::RA, K::MPRE7)),
    r("ldp", 0x29C00000, Q::SF, QWX, k3(K::RD, K::RA, K::MPRE7)),
    r("stp", 0x28800000, Q::SF, QWX, k3(K::RD, K::RA, K::MPOST7)),
    r("ldp", 0x28C00000, Q::SF, QWX, k3(K::RD, K::RA, K::MPOST7)),
    r("ldpsw", 0x69400000, Q::NONE, 0, k3(K::XD, K::XA, K::MP7)),
    r("stp", 0x2D000000, Q::FP, 7, k3(K::FD, K::FA, K::MP7)),
    r("ldp", 0x2D400000, Q::FP, 7, k3(K::FD, K::FA, K::MP7)),
    r("stp", 0x2D800000, Q::FP, 7, k3(K::FD, K::FA, K::MPRE7)),
    r("ldp", 0x2DC00000, Q::FP, 7, k3(K::FD, K::FA, K::MPRE7)),
    r("stp", 0x2C800000, Q::FP, 7, k3(K::FD, K::FA, K::MPOST7)),
    r("ldp", 0x2CC00000, Q::FP, 7, k3(K::FD, K::FA, K::MPOST7)),
    // Load-acquire, store-release, exclusives.
    r("ldarb", 0x08DFFC00, Q::NONE, 0, k2(K::WD, K::M0)),
    r("ldarh", 0x48DFFC00, Q::NONE, 0, k2(K::WD, K::M0)),
    r("ldar", 0x88DFFC00, Q::B30, QWX, k2(K::RD, K::M0)),
    r("stlrb", 0x089FFC00, Q::NONE, 0, k2(K::WD, K::M0)),
    r("stlrh", 0x489FFC00, Q::NONE, 0, k2(K::WD, K::M0)),
    r("stlr", 0x889FFC00, Q::B30, QWX, k2(K::RD, K::M0)),
    r("ldxr", 0x885F7C00, Q::B30, QWX, k2(K::RD, K::M0)),
    r("ldaxr", 0x885FFC00, Q::B30, QWX, k2(K::RD, K::M0)),
    r("stxr", 0x88007C00, Q::B30, QWX, k3(K::WM, K::RD, K::M0)),
    r("stlxr", 0x8800FC00, Q::B30, QWX, k3(K::WM, K::RD, K::M0)),
    // Atomic memory operations (LSE): the store aliases of a load whose register is the zero register,
    // without acquire.
    r("staddb", 0x3820001F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("staddlb", 0x3860001F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("staddh", 0x7820001F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("staddlh", 0x7860001F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("stadd", 0xB820001F, Q::B30, QWX, k2(K::RM, K::M0)),
    r("staddl", 0xB860001F, Q::B30, QWX, k2(K::RM, K::M0)),
    r("stclrb", 0x3820101F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("stclrlb", 0x3860101F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("stclrh", 0x7820101F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("stclrlh", 0x7860101F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("stclr", 0xB820101F, Q::B30, QWX, k2(K::RM, K::M0)),
    r("stclrl", 0xB860101F, Q::B30, QWX, k2(K::RM, K::M0)),
    r("steorb", 0x3820201F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("steorlb", 0x3860201F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("steorh", 0x7820201F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("steorlh", 0x7860201F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("steor", 0xB820201F, Q::B30, QWX, k2(K::RM, K::M0)),
    r("steorl", 0xB860201F, Q::B30, QWX, k2(K::RM, K::M0)),
    r("stsetb", 0x3820301F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("stsetlb", 0x3860301F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("stseth", 0x7820301F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("stsetlh", 0x7860301F, Q::NONE, 0, k2(K::WM, K::M0)),
    r("stset", 0xB820301F, Q::B30, QWX, k2(K::RM, K::M0)),
    r("stsetl", 0xB860301F, Q::B30, QWX, k2(K::RM, K::M0)),
    r("ldaddb", 0x38200000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldaddab", 0x38A00000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldaddlb", 0x38600000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldaddalb", 0x38E00000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldaddh", 0x78200000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldaddah", 0x78A00000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldaddlh", 0x78600000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldaddalh", 0x78E00000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldadd", 0xB8200000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldadda", 0xB8A00000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldaddl", 0xB8600000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldaddal", 0xB8E00000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldclrb", 0x38201000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldclrab", 0x38A01000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldclrlb", 0x38601000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldclralb", 0x38E01000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldclrh", 0x78201000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldclrah", 0x78A01000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldclrlh", 0x78601000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldclralh", 0x78E01000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldclr", 0xB8201000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldclra", 0xB8A01000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldclrl", 0xB8601000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldclral", 0xB8E01000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldeorb", 0x38202000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldeorab", 0x38A02000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldeorlb", 0x38602000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldeoralb", 0x38E02000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldeorh", 0x78202000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldeorah", 0x78A02000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldeorlh", 0x78602000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldeoralh", 0x78E02000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldeor", 0xB8202000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldeora", 0xB8A02000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldeorl", 0xB8602000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldeoral", 0xB8E02000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldsetb", 0x38203000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldsetab", 0x38A03000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldsetlb", 0x38603000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldsetalb", 0x38E03000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldseth", 0x78203000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldsetah", 0x78A03000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldsetlh", 0x78603000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldsetalh", 0x78E03000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("ldset", 0xB8203000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldseta", 0xB8A03000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldsetl", 0xB8603000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("ldsetal", 0xB8E03000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("swpb", 0x38208000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("swpab", 0x38A08000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("swplb", 0x38608000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("swpalb", 0x38E08000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("swph", 0x78208000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("swpah", 0x78A08000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("swplh", 0x78608000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("swpalh", 0x78E08000, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("swp", 0xB8208000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("swpa", 0xB8A08000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("swpl", 0xB8608000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("swpal", 0xB8E08000, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("casb", 0x08A07C00, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("casab", 0x08E07C00, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("caslb", 0x08A0FC00, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("casalb", 0x08E0FC00, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("cash", 0x48A07C00, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("casah", 0x48E07C00, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("caslh", 0x48A0FC00, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("casalh", 0x48E0FC00, Q::NONE, 0, k3(K::WM, K::WD, K::M0)),
    r("cas", 0x88A07C00, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("casa", 0x88E07C00, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("casl", 0x88A0FC00, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    r("casal", 0x88E0FC00, Q::B30, QWX, k3(K::RM, K::RD, K::M0)),
    // Branches.
    r("b", 0x14000000, Q::NONE, 0, k1(K::L26)),
    r("bl", 0x94000000, Q::NONE, 0, k1(K::L26)),
    r("b.", 0x54000000, Q::NONE, 0, k2(K::CONDM, K::L19)),
    r("cbz", 0x34000000, Q::SF, QWX, k2(K::RD, K::L19)),
    r("cbnz", 0x35000000, Q::SF, QWX, k2(K::RD, K::L19)),
    r("tbz", 0x36000000, Q::NONE, 0, k3(K::RTB, K::TBIT, K::L14)),
    r("tbnz", 0x37000000, Q::NONE, 0, k3(K::RTB, K::TBIT, K::L14)),
    r("br", 0xD61F0000, Q::NONE, 0, k1(K::XN)),
    r("blr", 0xD63F0000, Q::NONE, 0, k1(K::XN)),
    r("ret", 0xD65F0000, Q::NONE, 0, k1(K::XLR)),
    // System.
    r("nop", 0xD503201F, Q::NONE, 0, 0),
    r("yield", 0xD503203F, Q::NONE, 0, 0),
    r("wfe", 0xD503205F, Q::NONE, 0, 0),
    r("wfi", 0xD503207F, Q::NONE, 0, 0),
    r("sev", 0xD503209F, Q::NONE, 0, 0),
    r("sevl", 0xD50320BF, Q::NONE, 0, 0),
    r("dsb", 0xD503309F, Q::NONE, 0, k1(K::BARRIER)),
    r("dmb", 0xD50330BF, Q::NONE, 0, k1(K::BARRIER)),
    r("isb", 0xD50330DF, Q::NONE, 0, k1(K::ISB)),
    r("smstart", 0xD503477F, Q::NONE, 0, 0),
    r("smstop", 0xD503467F, Q::NONE, 0, 0),
    r("smstart", 0xD503437F, Q::NONE, 0, k1(K::SMSM)),
    r("smstop", 0xD503427F, Q::NONE, 0, k1(K::SMSM)),
    r("smstart", 0xD503457F, Q::NONE, 0, k1(K::SMZA)),
    r("smstop", 0xD503447F, Q::NONE, 0, k1(K::SMZA)),
    r("mrs", 0xD5300000, Q::NONE, 0, k2(K::XD, K::SYSREG)),
    r("msr", 0xD5100000, Q::NONE, 0, k2(K::SYSREG, K::XD)),
    r("svc", 0xD4000001, Q::NONE, 0, k1(K::IMM16)),
    r("brk", 0xD4200000, Q::NONE, 0, k1(K::IMM16)),
    r("hlt", 0xD4400000, Q::NONE, 0, k1(K::IMM16)),
    r("udf", 0x00000000, Q::NONE, 0, k1(K::UDF16)),
    // Floating point.
    r("fmov", 0x1E204000, Q::FT, QSD, k2(K::FD, K::FN)),
    r("fmov", 0x1E270000, Q::NONE, 0, k2(K::SD, K::WN)),
    r("fmov", 0x1E260000, Q::NONE, 0, k2(K::WD, K::SN)),
    r("fmov", 0x9E670000, Q::NONE, 0, k2(K::DD, K::XN)),
    r("fmov", 0x9E660000, Q::NONE, 0, k2(K::XD, K::DN)),
    r("fmov", 0x1E201000, Q::FT, QSD, k2(K::FD, K::FPIMM)),
    r("fmul", 0x1E200800, Q::FT, QSD, k3(K::FD, K::FN, K::FM)),
    r("fdiv", 0x1E201800, Q::FT, QSD, k3(K::FD, K::FN, K::FM)),
    r("fadd", 0x1E202800, Q::FT, QSD, k3(K::FD, K::FN, K::FM)),
    r("fsub", 0x1E203800, Q::FT, QSD, k3(K::FD, K::FN, K::FM)),
    r("fmax", 0x1E204800, Q::FT, QSD, k3(K::FD, K::FN, K::FM)),
    r("fmin", 0x1E205800, Q::FT, QSD, k3(K::FD, K::FN, K::FM)),
    r("fmaxnm", 0x1E206800, Q::FT, QSD, k3(K::FD, K::FN, K::FM)),
    r("fminnm", 0x1E207800, Q::FT, QSD, k3(K::FD, K::FN, K::FM)),
    r("fnmul", 0x1E208800, Q::FT, QSD, k3(K::FD, K::FN, K::FM)),
    r("fabs", 0x1E20C000, Q::FT, QSD, k2(K::FD, K::FN)),
    r("fneg", 0x1E214000, Q::FT, QSD, k2(K::FD, K::FN)),
    r("fsqrt", 0x1E21C000, Q::FT, QSD, k2(K::FD, K::FN)),
    r("frintn", 0x1E244000, Q::FT, QSD, k2(K::FD, K::FN)),
    r("frintp", 0x1E24C000, Q::FT, QSD, k2(K::FD, K::FN)),
    r("frintm", 0x1E254000, Q::FT, QSD, k2(K::FD, K::FN)),
    r("frintz", 0x1E25C000, Q::FT, QSD, k2(K::FD, K::FN)),
    r("frinta", 0x1E264000, Q::FT, QSD, k2(K::FD, K::FN)),
    r("frintx", 0x1E274000, Q::FT, QSD, k2(K::FD, K::FN)),
    r("frinti", 0x1E27C000, Q::FT, QSD, k2(K::FD, K::FN)),
    r("fcvt", 0x1E22C000, Q::NONE, 0, k2(K::DD, K::SN)),
    r("fcvt", 0x1E624000, Q::NONE, 0, k2(K::SD, K::DN)),
    r("fcvt", 0x1E23C000, Q::NONE, 0, k2(K::HD, K::SN)),
    r("fcvt", 0x1E63C000, Q::NONE, 0, k2(K::HD, K::DN)),
    r("fcvt", 0x1EE24000, Q::NONE, 0, k2(K::SD, K::HN)),
    r("fcvt", 0x1EE2C000, Q::NONE, 0, k2(K::DD, K::HN)),
    r("fcmp", 0x1E202008, Q::FT, QSD, k2(K::FN, K::FZERO)),
    r("fcmpe", 0x1E202018, Q::FT, QSD, k2(K::FN, K::FZERO)),
    r("fcmp", 0x1E202000, Q::FT, QSD, k2(K::FN, K::FM)),
    r("fcmpe", 0x1E202010, Q::FT, QSD, k2(K::FN, K::FM)),
    r("fcsel", 0x1E200C00, Q::FT, QSD, k4(K::FD, K::FN, K::FM, K::COND)),
    r("fmadd", 0x1F000000, Q::FT, QSD, k4(K::FD, K::FN, K::FM, K::FA)),
    r("fmsub", 0x1F008000, Q::FT, QSD, k4(K::FD, K::FN, K::FM, K::FA)),
    r("fnmadd", 0x1F200000, Q::FT, QSD, k4(K::FD, K::FN, K::FM, K::FA)),
    r("fnmsub", 0x1F208000, Q::FT, QSD, k4(K::FD, K::FN, K::FM, K::FA)),
    r("scvtf", 0x1E220000, Q::CVT, 0x0F, k2(K::FD, K::RN)),
    r("ucvtf", 0x1E230000, Q::CVT, 0x0F, k2(K::FD, K::RN)),
    r("fcvtns", 0x1E200000, Q::CVT, 0x0F, k2(K::RD, K::FN)),
    r("fcvtnu", 0x1E210000, Q::CVT, 0x0F, k2(K::RD, K::FN)),
    r("fcvtas", 0x1E240000, Q::CVT, 0x0F, k2(K::RD, K::FN)),
    r("fcvtau", 0x1E250000, Q::CVT, 0x0F, k2(K::RD, K::FN)),
    r("fcvtps", 0x1E280000, Q::CVT, 0x0F, k2(K::RD, K::FN)),
    r("fcvtpu", 0x1E290000, Q::CVT, 0x0F, k2(K::RD, K::FN)),
    r("fcvtms", 0x1E300000, Q::CVT, 0x0F, k2(K::RD, K::FN)),
    r("fcvtmu", 0x1E310000, Q::CVT, 0x0F, k2(K::RD, K::FN)),
    r("fcvtzs", 0x1E380000, Q::CVT, 0x0F, k2(K::RD, K::FN)),
    r("fcvtzu", 0x1E390000, Q::CVT, 0x0F, k2(K::RD, K::FN)),
    // Advanced SIMD, three registers of the same arrangement.
    r("add", 0x0E208400, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("sub", 0x2E208400, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("mul", 0x0E209C00, Q::V, QV_NOD, k3(K::VD, K::VN, K::VM)),
    r("smax", 0x0E206400, Q::V, QV_NOD, k3(K::VD, K::VN, K::VM)),
    r("umax", 0x2E206400, Q::V, QV_NOD, k3(K::VD, K::VN, K::VM)),
    r("smin", 0x0E206C00, Q::V, QV_NOD, k3(K::VD, K::VN, K::VM)),
    r("umin", 0x2E206C00, Q::V, QV_NOD, k3(K::VD, K::VN, K::VM)),
    r("cmeq", 0x2E208C00, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("cmtst", 0x0E208C00, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("cmgt", 0x0E203400, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("cmge", 0x0E203C00, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("cmhi", 0x2E203400, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("cmhs", 0x2E203C00, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("sshl", 0x0E204400, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("ushl", 0x2E204400, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("mov", 0x0EA01C00, Q::VB, QWX, k2(K::VD, K::VNM)),
    r("and", 0x0E201C00, Q::VB, QWX, k3(K::VD, K::VN, K::VM)),
    r("bic", 0x0E601C00, Q::VB, QWX, k3(K::VD, K::VN, K::VM)),
    r("orr", 0x0EA01C00, Q::VB, QWX, k3(K::VD, K::VN, K::VM)),
    r("orn", 0x0EE01C00, Q::VB, QWX, k3(K::VD, K::VN, K::VM)),
    r("eor", 0x2E201C00, Q::VB, QWX, k3(K::VD, K::VN, K::VM)),
    r("bsl", 0x2E601C00, Q::VB, QWX, k3(K::VD, K::VN, K::VM)),
    r("bit", 0x2EA01C00, Q::VB, QWX, k3(K::VD, K::VN, K::VM)),
    r("bif", 0x2EE01C00, Q::VB, QWX, k3(K::VD, K::VN, K::VM)),
    r("fadd", 0x0E20D400, Q::VF, QVF_ALL, k3(K::VD, K::VN, K::VM)),
    r("fsub", 0x0EA0D400, Q::VF, QVF_ALL, k3(K::VD, K::VN, K::VM)),
    r("fmul", 0x2E20DC00, Q::VF, QVF_ALL, k3(K::VD, K::VN, K::VM)),
    r("fdiv", 0x2E20FC00, Q::VF, QVF_ALL, k3(K::VD, K::VN, K::VM)),
    r("fmla", 0x0E20CC00, Q::VF, QVF_ALL, k3(K::VD, K::VN, K::VM)),
    r("fmls", 0x0EA0CC00, Q::VF, QVF_ALL, k3(K::VD, K::VN, K::VM)),
    r("fmaxnm", 0x0E20C400, Q::VF, QVF_ALL, k3(K::VD, K::VN, K::VM)),
    r("fminnm", 0x0EA0C400, Q::VF, QVF_ALL, k3(K::VD, K::VN, K::VM)),
    r("fmax", 0x0E20F400, Q::VF, QVF_ALL, k3(K::VD, K::VN, K::VM)),
    r("fmin", 0x0EA0F400, Q::VF, QVF_ALL, k3(K::VD, K::VN, K::VM)),
    r("fcmeq", 0x0E20E400, Q::VF, QVF_ALL, k3(K::VD, K::VN, K::VM)),
    r("fcmge", 0x2E20E400, Q::VF, QVF_ALL, k3(K::VD, K::VN, K::VM)),
    r("fcmgt", 0x2EA0E400, Q::VF, QVF_ALL, k3(K::VD, K::VN, K::VM)),
    // Advanced SIMD, two registers.
    r("rev64", 0x0E200800, Q::V, QV_NOD, k2(K::VD, K::VN)),
    r("rev32", 0x2E200800, Q::V, 0x0F, k2(K::VD, K::VN)),
    r("rev16", 0x0E201800, Q::V, 0x03, k2(K::VD, K::VN)),
    r("cnt", 0x0E205800, Q::VB, QWX, k2(K::VD, K::VN)),
    r("mvn", 0x2E205800, Q::VB, QWX, k2(K::VD, K::VN)),
    r("abs", 0x0E20B800, Q::V, QV_NO1D, k2(K::VD, K::VN)),
    r("neg", 0x2E20B800, Q::V, QV_NO1D, k2(K::VD, K::VN)),
    r("fabs", 0x0EA0F800, Q::VF, QVF_ALL, k2(K::VD, K::VN)),
    r("fneg", 0x2EA0F800, Q::VF, QVF_ALL, k2(K::VD, K::VN)),
    r("fsqrt", 0x2EA1F800, Q::VF, QVF_ALL, k2(K::VD, K::VN)),
    r("frintn", 0x0E218800, Q::VF, QVF_ALL, k2(K::VD, K::VN)),
    r("frintm", 0x0E219800, Q::VF, QVF_ALL, k2(K::VD, K::VN)),
    r("frintp", 0x0EA18800, Q::VF, QVF_ALL, k2(K::VD, K::VN)),
    r("frintz", 0x0EA19800, Q::VF, QVF_ALL, k2(K::VD, K::VN)),
    r("addv", 0x0E31B800, Q::V, 0x2F, k2(K::FELEM, K::VN)),
    // Advanced SIMD for the intrinsics (`target::intrin`).
    r("sqadd", 0x0E200C00, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("uqadd", 0x2E200C00, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("sqsub", 0x0E202C00, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("uqsub", 0x2E202C00, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("sabd", 0x0E207400, Q::V, QV_NOD, k3(K::VD, K::VN, K::VM)),
    r("uabd", 0x2E207400, Q::V, QV_NOD, k3(K::VD, K::VN, K::VM)),
    r("addp", 0x0E20BC00, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("smaxp", 0x0E20A400, Q::V, QV_NOD, k3(K::VD, K::VN, K::VM)),
    r("umaxp", 0x2E20A400, Q::V, QV_NOD, k3(K::VD, K::VN, K::VM)),
    r("sminp", 0x0E20AC00, Q::V, QV_NOD, k3(K::VD, K::VN, K::VM)),
    r("uminp", 0x2E20AC00, Q::V, QV_NOD, k3(K::VD, K::VN, K::VM)),
    r("sqrdmlah", 0x2E008400, Q::V, 0x3C, k3(K::VD, K::VN, K::VM)),
    r("sqrdmlsh", 0x2E008C00, Q::V, 0x3C, k3(K::VD, K::VN, K::VM)),
    r("uzp1", 0x0E001800, Q::V, QV_NO1D, k3(K::VD, K::VN, K::VM)),
    r("clz", 0x2E204800, Q::V, QV_NOD, k2(K::VD, K::VN)),
    r("rbit", 0x2E605800, Q::VB, QWX, k2(K::VD, K::VN)),
    r("scvtf", 0x0E21D800, Q::VF, QVF_ALL, k2(K::VD, K::VN)),
    r("ucvtf", 0x2E21D800, Q::VF, QVF_ALL, k2(K::VD, K::VN)),
    r("fcvtzs", 0x0EA1B800, Q::VF, QVF_ALL, k2(K::VD, K::VN)),
    r("fcvtzu", 0x2EA1B800, Q::VF, QVF_ALL, k2(K::VD, K::VN)),
    r("smaxv", 0x0E30A800, Q::V, 0x2F, k2(K::FELEM, K::VN)),
    r("umaxv", 0x2E30A800, Q::V, 0x2F, k2(K::FELEM, K::VN)),
    r("sminv", 0x0E31A800, Q::V, 0x2F, k2(K::FELEM, K::VN)),
    r("uminv", 0x2E31A800, Q::V, 0x2F, k2(K::FELEM, K::VN)),
    r("fmaxnmv", 0x6E30C800, Q::NONE, 0, k2(K::SD, K::V4SN)),
    r("fmaxv", 0x6E30F800, Q::NONE, 0, k2(K::SD, K::V4SN)),
    r("fminnmv", 0x6EB0C800, Q::NONE, 0, k2(K::SD, K::V4SN)),
    r("fminv", 0x6EB0F800, Q::NONE, 0, k2(K::SD, K::V4SN)),
    r("addp", 0x5EF1B800, Q::NONE, 0, k2(K::DD, K::V2DN)),
    r("fmaxnmp", 0x7E30C800, Q::NONE, 0, k2(K::SD, K::V2SN)),
    r("fmaxnmp", 0x7E70C800, Q::NONE, 0, k2(K::DD, K::V2DN)),
    r("fmaxp", 0x7E30F800, Q::NONE, 0, k2(K::SD, K::V2SN)),
    r("fmaxp", 0x7E70F800, Q::NONE, 0, k2(K::DD, K::V2DN)),
    r("fminnmp", 0x7EB0C800, Q::NONE, 0, k2(K::SD, K::V2SN)),
    r("fminnmp", 0x7EF0C800, Q::NONE, 0, k2(K::DD, K::V2DN)),
    r("fminp", 0x7EB0F800, Q::NONE, 0, k2(K::SD, K::V2SN)),
    r("fminp", 0x7EF0F800, Q::NONE, 0, k2(K::DD, K::V2DN)),
    r("smull", 0x0E20C000, Q::NONE, 0, k3(K::V8HD, K::V8BN, K::V8BM)),
    r("smull", 0x0E60C000, Q::NONE, 0, k3(K::V4SD, K::V4HN, K::V4HM)),
    r("smull", 0x0EA0C000, Q::NONE, 0, k3(K::V2DD, K::V2SN, K::V2SM)),
    r("smull2", 0x4E20C000, Q::NONE, 0, k3(K::V8HD, K::V16BN, K::V16BM)),
    r("smull2", 0x4E60C000, Q::NONE, 0, k3(K::V4SD, K::V8HN, K::V8HM)),
    r("smull2", 0x4EA0C000, Q::NONE, 0, k3(K::V2DD, K::V4SN, K::V4SM)),
    r("umull", 0x2E20C000, Q::NONE, 0, k3(K::V8HD, K::V8BN, K::V8BM)),
    r("umull", 0x2E60C000, Q::NONE, 0, k3(K::V4SD, K::V4HN, K::V4HM)),
    r("umull", 0x2EA0C000, Q::NONE, 0, k3(K::V2DD, K::V2SN, K::V2SM)),
    r("umull2", 0x6E20C000, Q::NONE, 0, k3(K::V8HD, K::V16BN, K::V16BM)),
    r("umull2", 0x6E60C000, Q::NONE, 0, k3(K::V4SD, K::V8HN, K::V8HM)),
    r("umull2", 0x6EA0C000, Q::NONE, 0, k3(K::V2DD, K::V4SN, K::V4SM)),
    r("xtn", 0x0E212800, Q::NONE, 0, k2(K::V8BD, K::V8HN)),
    r("xtn", 0x0E612800, Q::NONE, 0, k2(K::V4HD, K::V4SN)),
    r("xtn", 0x0EA12800, Q::NONE, 0, k2(K::V2SD, K::V2DN)),
    r("xtn2", 0x4E212800, Q::NONE, 0, k2(K::V16BD, K::V8HN)),
    r("xtn2", 0x4E612800, Q::NONE, 0, k2(K::V8HD, K::V4SN)),
    r("xtn2", 0x4EA12800, Q::NONE, 0, k2(K::V4SD, K::V2DN)),
    r("sqxtn", 0x0E214800, Q::NONE, 0, k2(K::V8BD, K::V8HN)),
    r("sqxtn", 0x0E614800, Q::NONE, 0, k2(K::V4HD, K::V4SN)),
    r("sqxtn", 0x0EA14800, Q::NONE, 0, k2(K::V2SD, K::V2DN)),
    r("sqxtn2", 0x4E214800, Q::NONE, 0, k2(K::V16BD, K::V8HN)),
    r("sqxtn2", 0x4E614800, Q::NONE, 0, k2(K::V8HD, K::V4SN)),
    r("sqxtn2", 0x4EA14800, Q::NONE, 0, k2(K::V4SD, K::V2DN)),
    r("uqxtn", 0x2E214800, Q::NONE, 0, k2(K::V8BD, K::V8HN)),
    r("uqxtn", 0x2E614800, Q::NONE, 0, k2(K::V4HD, K::V4SN)),
    r("uqxtn", 0x2EA14800, Q::NONE, 0, k2(K::V2SD, K::V2DN)),
    r("uqxtn2", 0x6E214800, Q::NONE, 0, k2(K::V16BD, K::V8HN)),
    r("uqxtn2", 0x6E614800, Q::NONE, 0, k2(K::V8HD, K::V4SN)),
    r("uqxtn2", 0x6EA14800, Q::NONE, 0, k2(K::V4SD, K::V2DN)),
    r("sqxtun", 0x2E212800, Q::NONE, 0, k2(K::V8BD, K::V8HN)),
    r("sqxtun", 0x2E612800, Q::NONE, 0, k2(K::V4HD, K::V4SN)),
    r("sqxtun", 0x2EA12800, Q::NONE, 0, k2(K::V2SD, K::V2DN)),
    r("sqxtun2", 0x6E212800, Q::NONE, 0, k2(K::V16BD, K::V8HN)),
    r("sqxtun2", 0x6E612800, Q::NONE, 0, k2(K::V8HD, K::V4SN)),
    r("sqxtun2", 0x6EA12800, Q::NONE, 0, k2(K::V4SD, K::V2DN)),
    r("saddlp", 0x0E202800, Q::NONE, 0, k2(K::V4HD, K::V8BN)),
    r("saddlp", 0x4E202800, Q::NONE, 0, k2(K::V8HD, K::V16BN)),
    r("saddlp", 0x0E602800, Q::NONE, 0, k2(K::V2SD, K::V4HN)),
    r("saddlp", 0x4E602800, Q::NONE, 0, k2(K::V4SD, K::V8HN)),
    r("saddlp", 0x4EA02800, Q::NONE, 0, k2(K::V2DD, K::V4SN)),
    r("uaddlp", 0x2E202800, Q::NONE, 0, k2(K::V4HD, K::V8BN)),
    r("uaddlp", 0x6E202800, Q::NONE, 0, k2(K::V8HD, K::V16BN)),
    r("uaddlp", 0x2E602800, Q::NONE, 0, k2(K::V2SD, K::V4HN)),
    r("uaddlp", 0x6E602800, Q::NONE, 0, k2(K::V4SD, K::V8HN)),
    r("uaddlp", 0x6EA02800, Q::NONE, 0, k2(K::V2DD, K::V4SN)),
    r("sadalp", 0x0E206800, Q::NONE, 0, k2(K::V4HD, K::V8BN)),
    r("sadalp", 0x4E206800, Q::NONE, 0, k2(K::V8HD, K::V16BN)),
    r("sadalp", 0x0E606800, Q::NONE, 0, k2(K::V2SD, K::V4HN)),
    r("sadalp", 0x4E606800, Q::NONE, 0, k2(K::V4SD, K::V8HN)),
    r("sadalp", 0x4EA06800, Q::NONE, 0, k2(K::V2DD, K::V4SN)),
    r("uadalp", 0x2E206800, Q::NONE, 0, k2(K::V4HD, K::V8BN)),
    r("uadalp", 0x6E206800, Q::NONE, 0, k2(K::V8HD, K::V16BN)),
    r("uadalp", 0x2E606800, Q::NONE, 0, k2(K::V2SD, K::V4HN)),
    r("uadalp", 0x6E606800, Q::NONE, 0, k2(K::V4SD, K::V8HN)),
    r("uadalp", 0x6EA06800, Q::NONE, 0, k2(K::V2DD, K::V4SN)),
    r("fcvtl", 0x0E617800, Q::NONE, 0, k2(K::V2DD, K::V2SN)),
    r("fcvtl2", 0x4E617800, Q::NONE, 0, k2(K::V2DD, K::V4SN)),
    r("fcvtn", 0x0E616800, Q::NONE, 0, k2(K::V2SD, K::V2DN)),
    r("fcvtn2", 0x4E616800, Q::NONE, 0, k2(K::V4SD, K::V2DN)),
    r("sshll", 0x0F08A400, Q::NONE, 0, k3(K::V8HD, K::V8BN, K::SHL8)),
    r("sshll", 0x0F10A400, Q::NONE, 0, k3(K::V4SD, K::V4HN, K::SHL16)),
    r("sshll", 0x0F20A400, Q::NONE, 0, k3(K::V2DD, K::V2SN, K::SHL32)),
    r("sshll2", 0x4F08A400, Q::NONE, 0, k3(K::V8HD, K::V16BN, K::SHL8)),
    r("sshll2", 0x4F10A400, Q::NONE, 0, k3(K::V4SD, K::V8HN, K::SHL16)),
    r("sshll2", 0x4F20A400, Q::NONE, 0, k3(K::V2DD, K::V4SN, K::SHL32)),
    r("ushll", 0x2F08A400, Q::NONE, 0, k3(K::V8HD, K::V8BN, K::SHL8)),
    r("ushll", 0x2F10A400, Q::NONE, 0, k3(K::V4SD, K::V4HN, K::SHL16)),
    r("ushll", 0x2F20A400, Q::NONE, 0, k3(K::V2DD, K::V2SN, K::SHL32)),
    r("ushll2", 0x6F08A400, Q::NONE, 0, k3(K::V8HD, K::V16BN, K::SHL8)),
    r("ushll2", 0x6F10A400, Q::NONE, 0, k3(K::V4SD, K::V8HN, K::SHL16)),
    r("ushll2", 0x6F20A400, Q::NONE, 0, k3(K::V2DD, K::V4SN, K::SHL32)),
    r("dup", 0x0E010C00, Q::NONE, 0, k2(K::V8BD, K::WN)),
    r("dup", 0x4E010C00, Q::NONE, 0, k2(K::V16BD, K::WN)),
    r("dup", 0x0E020C00, Q::NONE, 0, k2(K::V4HD, K::WN)),
    r("dup", 0x4E020C00, Q::NONE, 0, k2(K::V8HD, K::WN)),
    r("dup", 0x0E040C00, Q::NONE, 0, k2(K::V2SD, K::WN)),
    r("dup", 0x4E040C00, Q::NONE, 0, k2(K::V4SD, K::WN)),
    r("dup", 0x4E080C00, Q::NONE, 0, k2(K::V2DD, K::XN)),
    r("dup", 0x0E000400, Q::NONE, 0, k2(K::V8BD, K::ELB)),
    r("dup", 0x4E000400, Q::NONE, 0, k2(K::V16BD, K::ELB)),
    r("dup", 0x0E000400, Q::NONE, 0, k2(K::V4HD, K::ELH)),
    r("dup", 0x4E000400, Q::NONE, 0, k2(K::V8HD, K::ELH)),
    r("dup", 0x0E000400, Q::NONE, 0, k2(K::V2SD, K::ELS)),
    r("dup", 0x4E000400, Q::NONE, 0, k2(K::V4SD, K::ELS)),
    r("dup", 0x4E000400, Q::NONE, 0, k2(K::V2DD, K::ELD)),
    r("mov", 0x5E000400, Q::NONE, 0, k2(K::HD, K::ELH)),
    r("mov", 0x5E000400, Q::NONE, 0, k2(K::SD, K::ELS)),
    r("mov", 0x5E000400, Q::NONE, 0, k2(K::DD, K::ELD)),
    r("umov", 0x0E003C00, Q::NONE, 0, k2(K::WD, K::ELB)),
    r("umov", 0x0E003C00, Q::NONE, 0, k2(K::WD, K::ELH)),
    r("mov", 0x0E003C00, Q::NONE, 0, k2(K::WD, K::ELS)),
    r("mov", 0x4E003C00, Q::NONE, 0, k2(K::XD, K::ELD)),
    r("mov", 0x6E000400, Q::NONE, 0, k2(K::EDD, K::EN4D)),
    r("tbl", 0x0E000000, Q::VB, QWX, k3(K::VD, K::T1B, K::VM)),
    r("tbx", 0x0E001000, Q::VB, QWX, k3(K::VD, K::T1B, K::VM)),
    r("tbl", 0x0E002000, Q::VB, QWX, k3(K::VD, K::T2B, K::VM)),
    r("tbx", 0x0E003000, Q::VB, QWX, k3(K::VD, K::T2B, K::VM)),
    r("tbl", 0x0E004000, Q::VB, QWX, k3(K::VD, K::T3B, K::VM)),
    r("tbx", 0x0E005000, Q::VB, QWX, k3(K::VD, K::T3B, K::VM)),
    r("tbl", 0x0E006000, Q::VB, QWX, k3(K::VD, K::T4B, K::VM)),
    r("tbx", 0x0E007000, Q::VB, QWX, k3(K::VD, K::T4B, K::VM)),
    r("ext", 0x2E000000, Q::VB, QWX, k4(K::VD, K::VN, K::VM, K::IMM4X)),
    r("ld1", 0x4C40A000, Q::NONE, 0, k2(K::L2B, K::M0)),
    r("ld1", 0x4C406000, Q::NONE, 0, k2(K::L3B, K::M0)),
    r("ld1", 0x4C402000, Q::NONE, 0, k2(K::L4B, K::M0)),
    r("st1", 0x4C00A000, Q::NONE, 0, k2(K::L2B, K::M0)),
    r("st1", 0x4C006000, Q::NONE, 0, k2(K::L3B, K::M0)),
    r("st1", 0x4C002000, Q::NONE, 0, k2(K::L4B, K::M0)),
    r("ld1", 0x0D400000, Q::NONE, 0, k2(K::LNB, K::M0)),
    r("ld1", 0x0D404000, Q::NONE, 0, k2(K::LNH, K::M0)),
    r("ld1", 0x0D408000, Q::NONE, 0, k2(K::LNS, K::M0)),
    r("ld1", 0x0D408400, Q::NONE, 0, k2(K::LND, K::M0)),
    r("st1", 0x0D000000, Q::NONE, 0, k2(K::LNB, K::M0)),
    r("st1", 0x0D004000, Q::NONE, 0, k2(K::LNH, K::M0)),
    r("st1", 0x0D008000, Q::NONE, 0, k2(K::LNS, K::M0)),
    r("st1", 0x0D008400, Q::NONE, 0, k2(K::LND, K::M0)),
    r("aese", 0x4E284800, Q::NONE, 0, k2(K::V16BD, K::V16BN)),
    r("aesd", 0x4E285800, Q::NONE, 0, k2(K::V16BD, K::V16BN)),
    r("aesmc", 0x4E286800, Q::NONE, 0, k2(K::V16BD, K::V16BN)),
    r("aesimc", 0x4E287800, Q::NONE, 0, k2(K::V16BD, K::V16BN)),
    r("sha256h", 0x5E004000, Q::NONE, 0, k3(K::QD, K::QN, K::V4SM)),
    r("sha256h2", 0x5E005000, Q::NONE, 0, k3(K::QD, K::QN, K::V4SM)),
    r("sha256su0", 0x5E282800, Q::NONE, 0, k2(K::V4SD, K::V4SN)),
    r("sha256su1", 0x5E006000, Q::NONE, 0, k3(K::V4SD, K::V4SN, K::V4SM)),
    r("eor3", 0xCE000000, Q::NONE, 0, k4(K::V16BD, K::V16BN, K::V16BM, K::V16BA)),
    r("bcax", 0xCE200000, Q::NONE, 0, k4(K::V16BD, K::V16BN, K::V16BM, K::V16BA)),
    r("rax1", 0xCE608C00, Q::NONE, 0, k3(K::V2DD, K::V2DN, K::V2DM)),
    r("xar", 0xCE800000, Q::NONE, 0, k4(K::V2DD, K::V2DN, K::V2DM, K::IMM6X)),
    r("sdot", 0x4E809400, Q::NONE, 0, k3(K::V4SD, K::V16BN, K::V16BM)),
    r("udot", 0x6E809400, Q::NONE, 0, k3(K::V4SD, K::V16BN, K::V16BM)),
    r("smmla", 0x4E80A400, Q::NONE, 0, k3(K::V4SD, K::V16BN, K::V16BM)),
    r("ummla", 0x6E80A400, Q::NONE, 0, k3(K::V4SD, K::V16BN, K::V16BM)),
    r("usmmla", 0x4E80AC00, Q::NONE, 0, k3(K::V4SD, K::V16BN, K::V16BM)),
    r("crc32b", 0x1AC04000, Q::NONE, 0, k3(K::WD, K::WN, K::WM)),
    r("crc32h", 0x1AC04400, Q::NONE, 0, k3(K::WD, K::WN, K::WM)),
    r("crc32w", 0x1AC04800, Q::NONE, 0, k3(K::WD, K::WN, K::WM)),
    r("crc32x", 0x9AC04C00, Q::NONE, 0, k3(K::WD, K::WN, K::XM)),
    r("crc32cb", 0x1AC05000, Q::NONE, 0, k3(K::WD, K::WN, K::WM)),
    r("crc32ch", 0x1AC05400, Q::NONE, 0, k3(K::WD, K::WN, K::WM)),
    r("crc32cw", 0x1AC05800, Q::NONE, 0, k3(K::WD, K::WN, K::WM)),
    r("crc32cx", 0x9AC05C00, Q::NONE, 0, k3(K::WD, K::WN, K::XM)),
    // SVE.
    r("ptrue", 0x2518E000, Q::Z, QALL, k2(K::PD, K::PAT)),
    r("ptrue", 0x25207810, Q::Z, QALL, k1(K::PND)),
    r("whilelo", 0x25201C00, Q::Z, QALL, k3(K::PD, K::XN, K::XM)),
    r("whilelo", 0x25204C10, Q::Z, QALL, k4(K::PND, K::XN, K::XM, K::VLX)),
    r("cntb", 0x0420E000, Q::NONE, 0, k3(K::XD, K::PAT, K::MULVL)),
    r("cnth", 0x0460E000, Q::NONE, 0, k3(K::XD, K::PAT, K::MULVL)),
    r("cntw", 0x04A0E000, Q::NONE, 0, k3(K::XD, K::PAT, K::MULVL)),
    r("cntd", 0x04E0E000, Q::NONE, 0, k3(K::XD, K::PAT, K::MULVL)),
    r("rdsvl", 0x04BF5800, Q::NONE, 0, k2(K::XD, K::SIMM6)),
    r("addsvl", 0x04205800, Q::NONE, 0, k3(K::XDS, K::XMS, K::SIMM6)),
    r("ld1b", 0xA400A000, Q::ZE, 1, k3(K::ZL1, K::PGZ, K::MSV)),
    r("ld1w", 0xA540A000, Q::ZE, 4, k3(K::ZL1, K::PGZ, K::MSV)),
    r("ld1d", 0xA5E0A000, Q::ZE, 8, k3(K::ZL1, K::PGZ, K::MSV)),
    r("ld1b", 0xA4004000, Q::ZE, 1, k3(K::ZL1, K::PGZ, K::MSVR)),
    r("ld1w", 0xA5404000, Q::ZE, 4, k3(K::ZL1, K::PGZ, K::MSVR)),
    r("ld1d", 0xA5E04000, Q::ZE, 8, k3(K::ZL1, K::PGZ, K::MSVR)),
    r("st1b", 0xE400E000, Q::ZE, 1, k3(K::ZL1, K::PG, K::MSV)),
    r("st1w", 0xE540E000, Q::ZE, 4, k3(K::ZL1, K::PG, K::MSV)),
    r("st1d", 0xE5E0E000, Q::ZE, 8, k3(K::ZL1, K::PG, K::MSV)),
    r("st1b", 0xE4004000, Q::ZE, 1, k3(K::ZL1, K::PG, K::MSVR)),
    r("st1w", 0xE5404000, Q::ZE, 4, k3(K::ZL1, K::PG, K::MSVR)),
    r("st1d", 0xE5E04000, Q::ZE, 8, k3(K::ZL1, K::PG, K::MSVR)),
    // SME2 multi-vector loads and stores (a predicate-as-counter governs).
    r("ld1b", 0xA0400000, Q::ZE, 1, k3(K::ZL2, K::PNGZ, K::MSV)),
    r("ld1b", 0xA0408000, Q::ZE, 1, k3(K::ZL4, K::PNGZ, K::MSV)),
    r("ld1w", 0xA0404000, Q::ZE, 4, k3(K::ZL2, K::PNGZ, K::MSV)),
    r("ld1w", 0xA040C000, Q::ZE, 4, k3(K::ZL4, K::PNGZ, K::MSV)),
    r("ld1d", 0xA0406000, Q::ZE, 8, k3(K::ZL2, K::PNGZ, K::MSV)),
    r("ld1d", 0xA040E000, Q::ZE, 8, k3(K::ZL4, K::PNGZ, K::MSV)),
    r("st1b", 0xA0600000, Q::ZE, 1, k3(K::ZL2, K::PNG, K::MSV)),
    r("st1b", 0xA0608000, Q::ZE, 1, k3(K::ZL4, K::PNG, K::MSV)),
    r("st1w", 0xA0604000, Q::ZE, 4, k3(K::ZL2, K::PNG, K::MSV)),
    r("st1w", 0xA060C000, Q::ZE, 4, k3(K::ZL4, K::PNG, K::MSV)),
    r("st1d", 0xA0606000, Q::ZE, 8, k3(K::ZL2, K::PNG, K::MSV)),
    r("st1d", 0xA060E000, Q::ZE, 8, k3(K::ZL4, K::PNG, K::MSV)),
    // SME: ZA tile slices, the ZA array, outer products.
    r("ld1b", 0xE0000000, Q::ZE, 1, k3(K::ZASL, K::PGZ, K::MSVR)),
    r("ld1h", 0xE0400000, Q::ZE, 2, k3(K::ZASL, K::PGZ, K::MSVR)),
    r("ld1w", 0xE0800000, Q::ZE, 4, k3(K::ZASL, K::PGZ, K::MSVR)),
    r("ld1d", 0xE0C00000, Q::ZE, 8, k3(K::ZASL, K::PGZ, K::MSVR)),
    r("st1b", 0xE0200000, Q::ZE, 1, k3(K::ZASL, K::PG, K::MSVR)),
    r("st1h", 0xE0600000, Q::ZE, 2, k3(K::ZASL, K::PG, K::MSVR)),
    r("st1w", 0xE0A00000, Q::ZE, 4, k3(K::ZASL, K::PG, K::MSVR)),
    r("st1d", 0xE0E00000, Q::ZE, 8, k3(K::ZASL, K::PG, K::MSVR)),
    r("ldr", 0xE1000000, Q::NONE, 0, k2(K::ZAARR, K::MZA)),
    r("str", 0xE1200000, Q::NONE, 0, k2(K::ZAARR, K::MZA)),
    r("zero", 0xC0080000, Q::NONE, 0, k1(K::ZAMASK)),
    r("fmopa", 0x80800000, Q::ZE, 4, k5(K::ZAT, K::PGM, K::PMM, K::ZN, K::ZM)),
    r("fmops", 0x80800010, Q::ZE, 4, k5(K::ZAT, K::PGM, K::PMM, K::ZN, K::ZM)),
    r("fmopa", 0x80C00000, Q::ZE, 8, k5(K::ZAT, K::PGM, K::PMM, K::ZN, K::ZM)),
    r("fmops", 0x80C00010, Q::ZE, 8, k5(K::ZAT, K::PGM, K::PMM, K::ZN, K::ZM)),
    r("smopa", 0xA0800000, Q::ZE, 4, k5(K::ZAT, K::PGM, K::PMM, K::ZBN, K::ZBM)),
    r("umopa", 0xA1A00000, Q::ZE, 4, k5(K::ZAT, K::PGM, K::PMM, K::ZBN, K::ZBM)),
];

// ---- Variants ----

/// The bits variant `q` of kind `qk` sets.
pub const fn qbits(qk: u8, q: u32) u32 {
    return switch qk {
        Q::SF => q << 31,
        Q::SFN => q << 31 | q << 22,
        Q::FT | Q::Z => q << 22,
        Q::CVT => (q & 1) << 31 | q >> 1 << 22,
        Q::V | Q::VF => (q & 1) << 30 | q >> 1 << 22,
        Q::VB | Q::B30 => q << 30,
        Q::S22 => 1 - q << 22,
        Q::FLS => if q == 4 {
            1u32 << 23;
        } else {
            q << 30;
        },
        Q::FP => q << 30,
        _ => 0,
    };
}

// The bits variant kind `qk` takes.
const fn qmask(qk: u8) u32 {
    return switch qk {
        Q::SF => 1u32 << 31,
        Q::SFN => 1u32 << 31 | 1u32 << 22,
        Q::FT | Q::Z => 3u32 << 22,
        Q::CVT => 1u32 << 31 | 3u32 << 22,
        Q::V => 1u32 << 30 | 3u32 << 22,
        Q::VF => 1u32 << 30 | 1u32 << 22,
        Q::VB | Q::B30 => 1u32 << 30,
        Q::S22 => 1u32 << 22,
        Q::FLS => 3u32 << 30 | 1u32 << 23,
        Q::FP => 3u32 << 30,
        _ => 0,
    };
}

// The variant of word `w` under row `r`, 0xFF when the bits hold none of the row's.
const fn qof(r: Row, w: u32) u32 {
    let qk = r.q;
    let q = switch qk {
        Q::SF => w >> 31,
        Q::SFN => if w >> 31 == (w >> 22 & 1) {
            w >> 31;
        } else {
            0xFFu32;
        },
        Q::FT | Q::Z => w >> 22 & 3,
        Q::CVT => w >> 31 | (w >> 22 & 3) << 1,
        Q::V => w >> 30 & 1 | (w >> 22 & 3) << 1,
        Q::VF => w >> 30 & 1 | (w >> 22 & 1) << 1,
        Q::VB | Q::B30 => w >> 30 & 1,
        Q::S22 => 1 - (w >> 22 & 1),
        Q::FLS => if (w >> 23 & 1) == 0 {
            w >> 30;
        } else if w >> 30 == 0 {
            4u32;
        } else {
            0xFFu32;
        },
        Q::FP => w >> 30,
        Q::ZE => (r.qok as u32).trailing_zeros() as u32,
        _ => 0,
    };
    if qk != Q::NONE && (q >= 8 || (r.qok as u32 >> q & 1) == 0) {
        return 0xFF;
    }
    return q;
}

/// The variant of row `r`: its one value when the mnemonic fixes it (`Q::ZE`), else `q`.
pub const fn fixed_q(r: Row, q: u32) u32 {
    if r.q == Q::ZE {
        return (r.qok as u32).trailing_zeros() as u32;
    }
    return q;
}

/// Whether variant `q` of kind `qk` names 64-bit general registers.
pub const fn is64(qk: u8, q: u32) bool {
    return switch qk {
        Q::SF | Q::SFN | Q::B30 | Q::S22 => q == 1,
        Q::CVT => (q & 1) == 1,
        _ => false,
    };
}

/// The log2 of the bytes of the float register variant `q` of kind `qk` names: 0 b, 1 h, 2 s, 3 d,
/// 4 q.
pub const fn fsize(qk: u8, q: u32) u32 {
    let ft = if qk == Q::CVT {
        q >> 1;
    } else {
        q;
    };
    return switch qk {
        Q::FT | Q::CVT => switch ft {
            0 => 2u32,
            1 => 3u32,
            _ => 1u32,
        },
        Q::FLS => q,
        Q::FP => q + 2,
        _ => 0,
    };
}

// ---- Operand kinds ----

/// Whether `k` is a register kind (1 to 64, 161 to 192).
pub const fn is_reg(k: u8) bool {
    return k >= 1 && k <= 64 || k >= 161 && k <= 192;
}

/// The class of register kind `k` (`C_*`).
pub const fn reg_class(k: u8) u8 {
    if k > 64 {
        return C::V8B + (k - 161) / 4;
    }
    return (k - 1) / 4;
}

/// The bit position of register kind `k`'s field.
pub const fn reg_pos(k: u8) u32 {
    return switch k - 1 & 3 {
        0 => 0u32,
        1 => 5u32,
        2 => 10u32,
        _ => 16u32,
    };
}

/// The values kind `k` consumes.
pub const fn slots(k: u8) u32 {
    return switch k {
        K::AIMM | K::MOVW | K::BFX | K::BFIZ | K::LSH | K::ASH | K::EXT | K::MU12 | K::MS9 | K::MPRE9 | K::MPOST9 | K::MP7 | K::MPRE7 | K::MPOST7 | K::ZAARR | K::MSV | K::MSVR | K::ELB | K::ELH | K::ELS | K::ELD | K::EDD | K::EN4D | K::LNB | K::LNH | K::LNS | K::LND => 2u32,
        K::MREG | K::ZASL => 4u32,
        _ => 1u32,
    };
}

// The log2 of the lane bytes of an element kind (`K::ELB` .. `K::ELD`, `K::LNB` .. `K::LND`).
const fn el_size(k: u8) u32 {
    return switch k {
        K::ELB | K::LNB => 0u32,
        K::ELH | K::LNH => 1u32,
        K::ELS | K::LNS => 2u32,
        _ => 3u32,
    };
}

// The bits a lane index `i` of lane log2 size `sz` takes in a single-structure load or store
// (Q:S:size).
const fn lane_bits(i: u32, sz: u32) u32 {
    let sb = i << sz;
    return (sb >> 3 & 1) << 30 | (sb >> 2 & 1) << 12 | (sb & 3) << 10;
}

// The bits kind `k` takes in a row of variant `q`.
const fn kmask(k: u8, q: u32) u32 {
    if is_reg(k) {
        return 31u32 << reg_pos(k);
    }
    return switch k {
        K::AIMM => 0xFFFu32 << 10 | 1u32 << 22,
        K::LIMM | K::LIMMV => 0x1FFFu32 << 10,
        K::MOVW | K::MOVZV | K::MOVNV => 0xFFFFu32 << 5 | 3u32 << 21,
        K::IMMR => 0x3Fu32 << 16,
        K::IMMS => 0x3Fu32 << 10,
        K::SHL | K::SHR | K::BFX | K::BFIZ => 0x3Fu32 << 16 | 0x3Fu32 << 10,
        K::LSH | K::ASH => 3u32 << 22 | 0x3Fu32 << 10,
        K::EXT => 7u32 << 13 | 7u32 << 10,
        K::RMX | K::IMM5 => 31u32 << 16,
        K::COND | K::CONDI => 15u32 << 12,
        K::CONDM | K::NZCV | K::PD => 15u32,
        K::IMM16 => 0xFFFFu32 << 5,
        K::UDF16 => 0xFFFFu32,
        K::FPIMM => 0xFFu32 << 13,
        K::L26 => 0x3FFFFFFu32,
        K::L19 => 0x7FFFFu32 << 5,
        K::L14 => 0x3FFFu32 << 5,
        K::ADR | K::ADRP => 3u32 << 29 | 0x7FFFFu32 << 5,
        K::TBIT => 1u32 << 31 | 31u32 << 19,
        K::RTB | K::FELEM | K::ZL1 => 31u32,
        K::MU12 => 31u32 << 5 | 0xFFFu32 << 10,
        K::MS9 | K::MPRE9 | K::MPOST9 => 31u32 << 5 | 0x1FFu32 << 12,
        K::MREG => 31u32 << 5 | 31u32 << 16 | 7u32 << 13 | 1u32 << 12,
        K::MP7 | K::MPRE7 | K::MPOST7 => 31u32 << 5 | 0x7Fu32 << 15,
        K::M0 | K::MZA | K::XLR => 31u32 << 5,
        K::SYSREG => 0x7FFFu32 << 5,
        K::BARRIER | K::ISB => 15u32 << 8,
        K::RNM | K::VNM => 31u32 << 5 | 31u32 << 16,
        K::PG | K::PGZ | K::PGM | K::PNGZ | K::PNG => 7u32 << 10,
        K::PMM => 7u32 << 13,
        K::PND => 7u32,
        K::ZL2 => 15u32 << 1,
        K::ZL4 => 7u32 << 2,
        K::ZAT => (1u32 << q) - 1,
        K::ZASL => 15u32 | 1u32 << 15 | 3u32 << 13,
        K::ZAARR => 3u32 << 13 | 15u32,
        K::ZAMASK => 0xFFu32,
        K::PAT => 31u32 << 5,
        K::MULVL => 15u32 << 16,
        K::SIMM6 => 0x3Fu32 << 5,
        K::MSV => 31u32 << 5 | 15u32 << 16,
        K::MSVR => 31u32 << 5 | 31u32 << 16,
        K::VLX => 1u32 << 13,
        K::ELB | K::ELH | K::ELS | K::ELD => 31u32 << 5 | 31u32 << 16,
        K::EDD => 31u32 | 31u32 << 16,
        K::EN4D => 31u32 << 5 | 15u32 << 11,
        K::LNB => 31u32 | 1u32 << 30 | 1u32 << 12 | 3u32 << 10,
        K::LNH => 31u32 | 1u32 << 30 | 1u32 << 12 | 1u32 << 11,
        K::LNS => 31u32 | 1u32 << 30 | 1u32 << 12,
        K::LND => 31u32 | 1u32 << 30,
        K::L2B | K::L3B | K::L4B => 31u32,
        K::T1B | K::T2B | K::T3B | K::T4B => 31u32 << 5,
        K::IMM4X => 15u32 << 11,
        K::SHL8 => 7u32 << 16,
        K::SHL16 => 15u32 << 16,
        K::SHL32 => 31u32 << 16,
        K::IMM6X => 0x3Fu32 << 10,
        _ => 0,
    };
}

/// The bits a word must match to be row `r`'s.
pub const fn mask(r: Row) u32 {
    let q = fixed_q(r, 0);
    let mut m = qmask(r.q);
    for i in 0..6u32 {
        let k = kind_at(r.ops, i);
        if k == 0 {
            break;
        }
        m |= kmask(k, q);
    }
    return ~m;
}

/// The log2 of the bytes a load or store word `w` moves.
pub const fn ldst_scale(w: u32) u32 {
    let size = w >> 30;
    if (w >> 26 & 1) != 0 && size == 0 && (w >> 23 & 1) != 0 {
        return 4;
    }
    return size;
}

// The log2 of the bytes of one register of pair word `w`.
const fn pair_scale(w: u32) u32 {
    if (w >> 26 & 1) != 0 {
        return 2 + (w >> 30);
    }
    return 2 + (w >> 31);
}

/// The vectors row `r`'s register list holds (its address immediate counts in them), 1 for a single
/// one.
pub const fn group(r: Row) i64 {
    for i in 0..6u32 {
        let k = kind_at(r.ops, i);
        if k == K::ZL2 {
            return 2;
        }
        if k == K::ZL4 {
            return 4;
        }
    }
    return 1;
}

// `v` sign-extended from `n` bits.
const fn sext(v: u32, n: u32) i64 {
    let s = 64 - n as i64;
    return v as i64 << s >> s;
}

// Whether `v` is in [lo, hi].
const fn within(v: i64, lo: i64, hi: i64) bool {
    return v >= lo && v <= hi;
}

/// The value of logical immediate field `nrs` for a 64-bit (`x`) or 32-bit register, None when the
/// field encodes none.
pub const fn bitmask_value(nrs: u32, x: bool) Option<u64> {
    let n = nrs >> 12 & 1;
    let immr = nrs >> 6 & 0x3F;
    let imms = nrs & 0x3F;
    if !x && n != 0 {
        return Option::None;
    }
    let combined = n << 6 | ~imms & 0x3F;
    if combined < 2 {
        return Option::None;
    }
    let len = 31 - combined.leading_zeros() as u32;
    let esize = 1u32 << len;
    let levels = esize - 1;
    let s = imms & levels;
    let rr = immr & levels;
    if s == levels {
        return Option::None;
    }
    let ones = (1u64 << (s + 1) as u64) - 1;
    let emask = if esize == 64 {
        0xFFFFFFFFFFFFFFFFu64;
    } else {
        (1u64 << esize as u64) - 1;
    };
    let mut e = ones;
    if rr != 0 {
        e = (ones >> rr as u64 | ones << (esize - rr) as u64) & emask;
    }
    let width: u32 = if x {
        64;
    } else {
        32;
    };
    let mut v: u64 = 0;
    let mut at: u32 = 0;
    while at < width {
        v |= e << at as u64;
        at += esize;
    }
    return Option::Some(v);
}

/// The bits of a 64-bit (`x`) or 32-bit register.
pub const fn wmask(x: bool) u64 {
    if x {
        return 0xFFFFFFFFFFFFFFFFu64;
    }
    return 0xFFFFFFFFu64;
}

/// The chunk `hw` with `u == imm16 << 16 * hw` in a 64-bit (`x`) or 32-bit register, 4 when there is
/// none.
pub const fn wide_chunk(u: u64, x: bool) u32 {
    let n: u32 = if x {
        4;
    } else {
        2;
    };
    for hw in 0..n {
        let sh = (hw * 16) as u64;
        if (u >> sh & 0xFFFF) << sh == u {
            return hw;
        }
    }
    return 4;
}

// The bits immediate `v` of a 64-bit (`x`) or 32-bit operation sets: a 32-bit one in [-2^31, 2^32),
// else 2^32.
const fn imm_bits(v: i64, x: bool) u64 {
    if x {
        return v as u64;
    }
    if v < -(1i64 << 31) || v >= 1i64 << 32 {
        return 1u64 << 32;
    }
    return v as u64 & 0xFFFFFFFF;
}

/// Encode row `r` with variant `q0` and operand values `v` into `out`; false when a value does not fit.
pub fn encode(r: Row, q0: u32, v: &Vals, out: &mut u32) bool {
    let q = fixed_q(r, q0);
    if r.q != Q::NONE && (q >= 8 || (r.qok as u32 >> q & 1) == 0) {
        return false;
    }
    let x = is64(r.q, q);
    let wbits: i64 = if x {
        64;
    } else {
        32;
    };
    let mut w = r.bits | qbits(r.q, q);
    let mut at: usize = 0;
    for i in 0..6u32 {
        let k = kind_at(r.ops, i);
        if k == 0 {
            break;
        }
        let a = v[at];
        let b = if at + 1 < NV {
            v[at + 1];
        } else {
            0i64;
        };
        if is_reg(k) {
            if !within(a, 0, 31) {
                return false;
            }
            w |= a as u32 << reg_pos(k);
            at += 1;
            continue;
        }
        let mut ok = true;
        switch k {
            K::AIMM => {
                w |= (a as u32 & 0xFFF) << 10 | (b as u32 & 1) << 22;
                ok = within(a, 0, 4095) && within(b, 0, 1);
            },
            K::LIMM | K::LIMMV => {
                w |= (a as u32 & 0x1FFF) << 10;
                ok = within(a, 0, 0x1FFF) && (switch bitmask_value(a as u32, x) {
                    Some(u) => k == K::LIMM || wide_chunk(u, x) == 4 && wide_chunk(~u & wmask(x), x) == 4,
                    None => false,
                });
            },
            K::MOVW => {
                w |= (a as u32 & 0xFFFF) << 5 | (b as u32 & 3) << 21;
                ok = within(a, 0, 0xFFFF) && within(b, 0, wbits / 16 - 1);
            },
            K::MOVZV | K::MOVNV => {
                let mut u = imm_bits(a, x);
                ok = u <= wmask(x);
                if k == K::MOVNV {
                    u = ~u & wmask(x);
                }
                let hw = wide_chunk(u, x);
                let imm = (u >> (hw * 16 & 63) as u64 & 0xFFFF) as u32;
                w |= imm << 5 | (hw & 3) << 21;
                ok = ok && hw < 4 && (k == K::MOVZV || x || imm != 0xFFFF);
            },
            K::IMMR => {
                w |= (a as u32 & 0x3F) << 16;
                ok = within(a, 0, wbits - 1);
            },
            K::IMMS => {
                w |= (a as u32 & 0x3F) << 10;
                ok = within(a, 0, wbits - 1);
            },
            K::SHL => {
                w |= (((wbits - a) % wbits) as u32 & 0x3F) << 16 | ((wbits - 1 - a) as u32 & 0x3F) << 10;
                ok = within(a, 1, wbits - 1);
            },
            K::SHR => {
                w |= (a as u32 & 0x3F) << 16 | (wbits - 1) as u32 << 10;
                ok = within(a, 0, wbits - 1);
            },
            K::BFX => {
                w |= (a as u32 & 0x3F) << 16 | ((a + b - 1) as u32 & 0x3F) << 10;
                ok = within(a, 0, wbits - 1) && within(b, 1, wbits - a);
            },
            K::BFIZ => {
                w |= (((wbits - a) % wbits) as u32 & 0x3F) << 16 | ((b - 1) as u32 & 0x3F) << 10;
                ok = within(a, 1, wbits - 1) && within(b, 1, wbits - a);
            },
            K::LSH | K::ASH => {
                w |= (a as u32 & 3) << 22 | (b as u32 & 0x3F) << 10;
                ok = within(a, 0, 3) && (k == K::LSH || a != 3) && within(b, 0, wbits - 1);
            },
            K::EXT => {
                w |= (a as u32 & 7) << 13 | (b as u32 & 7) << 10;
                ok = within(a, 0, 7) && within(b, 0, 4);
            },
            K::RMX | K::IMM5 => {
                w |= (a as u32 & 31) << 16;
                ok = within(a, 0, 31);
            },
            K::COND => {
                w |= (a as u32 & 15) << 12;
                ok = within(a, 0, 15);
            },
            K::CONDI => {
                w |= ((a as u32 ^ 1) & 15) << 12;
                ok = within(a, 0, 13);
            },
            K::CONDM | K::NZCV | K::PD => {
                w |= a as u32 & 15;
                ok = within(a, 0, 15);
            },
            K::IMM16 => {
                w |= (a as u32 & 0xFFFF) << 5;
                ok = within(a, 0, 0xFFFF);
            },
            K::UDF16 => {
                w |= a as u32 & 0xFFFF;
                ok = within(a, 0, 0xFFFF);
            },
            K::FPIMM => {
                w |= (a as u32 & 0xFF) << 13;
                ok = within(a, 0, 0xFF);
            },
            K::FZERO | K::SMSM | K::SMZA => {
                ok = a == 0;
            },
            K::L26 => {
                w |= (a >> 2) as u32 & 0x3FFFFFF;
                ok = (a & 3) == 0 && within(a, -(1i64 << 27), (1i64 << 27) - 4);
            },
            K::L19 => {
                w |= ((a >> 2) as u32 & 0x7FFFF) << 5;
                ok = (a & 3) == 0 && within(a, -(1i64 << 20), (1i64 << 20) - 4);
            },
            K::L14 => {
                w |= ((a >> 2) as u32 & 0x3FFF) << 5;
                ok = (a & 3) == 0 && within(a, -(1i64 << 15), (1i64 << 15) - 4);
            },
            K::ADR => {
                let u = a as u32;
                w |= (u & 3) << 29 | (u >> 2 & 0x7FFFF) << 5;
                ok = within(a, -(1i64 << 20), (1i64 << 20) - 1);
            },
            K::ADRP => {
                let u = (a >> 12) as u32;
                w |= (u & 3) << 29 | (u >> 2 & 0x7FFFF) << 5;
                ok = (a & 0xFFF) == 0 && within(a >> 12, -(1i64 << 20), (1i64 << 20) - 1);
            },
            K::TBIT => {
                w |= (a as u32 >> 5 & 1) << 31 | (a as u32 & 31) << 19;
                ok = within(a, 0, 63);
            },
            K::RTB | K::FELEM | K::ZL1 => {
                w |= a as u32 & 31;
                ok = within(a, 0, 31);
            },
            K::MU12 => {
                let s = ldst_scale(w) as i64;
                w |= (a as u32 & 31) << 5 | ((b >> s) as u32 & 0xFFF) << 10;
                ok = within(a, 0, 31) && b >= 0 && (b & (1i64 << s) - 1) == 0 && b >> s < 4096;
            },
            K::MS9 | K::MPRE9 | K::MPOST9 => {
                w |= (a as u32 & 31) << 5 | (b as u32 & 0x1FF) << 12;
                ok = within(a, 0, 31) && within(b, -256, 255);
            },
            K::MREG => {
                let opt = v[at + 2];
                let s = v[at + 3];
                w |= (a as u32 & 31) << 5 | (b as u32 & 31) << 16 | (opt as u32 & 7) << 13 | (s as u32 & 1) << 12;
                ok = within(a, 0, 31) && within(b, 0, 31) && (opt == 2 || opt == 3 || opt == 6 || opt == 7) && within(
                    s,
                    0,
                    1,
                );
            },
            K::MP7 | K::MPRE7 | K::MPOST7 => {
                let s = pair_scale(w) as i64;
                w |= (a as u32 & 31) << 5 | ((b >> s) as u32 & 0x7F) << 15;
                ok = within(a, 0, 31) && (b & (1i64 << s) - 1) == 0 && within(b >> s, -64, 63);
            },
            K::M0 | K::MZA | K::XLR => {
                w |= (a as u32 & 31) << 5;
                ok = within(a, 0, 31);
            },
            K::SYSREG => {
                w |= (a as u32 & 0x7FFF) << 5;
                ok = within(a, 0x4000, 0x7FFF);
            },
            K::BARRIER | K::ISB => {
                w |= (a as u32 & 15) << 8;
                ok = within(a, 0, 15);
            },
            K::RNM | K::VNM => {
                w |= (a as u32 & 31) << 5 | (a as u32 & 31) << 16;
                ok = within(a, 0, 31);
            },
            K::PG | K::PGZ | K::PGM => {
                w |= (a as u32 & 7) << 10;
                ok = within(a, 0, 7);
            },
            K::PMM => {
                w |= (a as u32 & 7) << 13;
                ok = within(a, 0, 7);
            },
            K::PND => {
                w |= (a - 8) as u32 & 7;
                ok = within(a, 8, 15);
            },
            K::PNGZ | K::PNG => {
                w |= ((a - 8) as u32 & 7) << 10;
                ok = within(a, 8, 15);
            },
            K::ZL2 => {
                w |= (a as u32 >> 1 & 15) << 1;
                ok = within(a, 0, 30) && (a & 1) == 0;
            },
            K::ZL4 => {
                w |= (a as u32 >> 2 & 7) << 2;
                ok = within(a, 0, 28) && (a & 3) == 0;
            },
            K::ZAT => {
                w |= a as u32 & (1u32 << q) - 1;
                ok = within(a, 0, (1i64 << q as i64) - 1);
            },
            K::ZASL => {
                let rs = v[at + 2];
                let off = v[at + 3];
                let ob = 4 - q;
                w |= (a as u32 & 15) << ob & 15 | off as u32 & 15 | (b as u32 & 1) << 15 | (rs as u32 & 3) << 13;
                ok = within(a, 0, (1i64 << q as i64) - 1) && within(off, 0, (1i64 << ob as i64) - 1) && within(b, 0, 1) && within(
                    rs,
                    0,
                    3,
                );
            },
            K::ZAARR => {
                w |= (a as u32 & 3) << 13 | b as u32 & 15;
                ok = within(a, 0, 3) && within(b, 0, 15);
            },
            K::ZAMASK => {
                w |= a as u32 & 0xFF;
                ok = within(a, 1, 0xFF);
            },
            K::PAT => {
                w |= (a as u32 & 31) << 5;
                ok = within(a, 0, 31);
            },
            K::MULVL => {
                w |= ((a - 1) as u32 & 15) << 16;
                ok = within(a, 1, 16);
            },
            K::SIMM6 => {
                w |= (a as u32 & 0x3F) << 5;
                ok = within(a, -32, 31);
            },
            K::MSV => {
                let g = group(r);
                w |= (a as u32 & 31) << 5 | ((b / g) as u32 & 15) << 16;
                ok = within(a, 0, 31) && b % g == 0 && within(b / g, -8, 7);
            },
            K::MSVR => {
                w |= (a as u32 & 31) << 5 | (b as u32 & 31) << 16;
                ok = within(a, 0, 31) && within(b, 0, 31);
            },
            K::VLX => {
                w |= (a as u32 & 1) << 13;
                ok = within(a, 0, 1);
            },
            K::ELB | K::ELH | K::ELS | K::ELD => {
                let sz = el_size(k);
                w |= (a as u32 & 31) << 5 | (b as u32 << sz + 1 | 1u32 << sz) << 16;
                ok = within(a, 0, 31) && within(b, 0, (16i64 >> sz as i64) - 1);
            },
            K::EDD => {
                w |= a as u32 & 31 | (b as u32 << 4 | 8) << 16;
                ok = within(a, 0, 31) && within(b, 0, 1);
            },
            K::EN4D => {
                w |= (a as u32 & 31) << 5 | b as u32 << 3 << 11;
                ok = within(a, 0, 31) && within(b, 0, 1);
            },
            K::LNB | K::LNH | K::LNS | K::LND => {
                let sz = el_size(k);
                w |= a as u32 & 31 | lane_bits(b as u32, sz);
                ok = within(a, 0, 31) && within(b, 0, (16i64 >> sz as i64) - 1);
            },
            K::L2B | K::L3B | K::L4B => {
                w |= a as u32 & 31;
                ok = within(a, 0, 31);
            },
            K::T1B | K::T2B | K::T3B | K::T4B => {
                w |= (a as u32 & 31) << 5;
                ok = within(a, 0, 31);
            },
            K::IMM4X => {
                w |= (a as u32 & 15) << 11;
                ok = within(a, 0, 15);
            },
            K::SHL8 | K::SHL16 | K::SHL32 => {
                w |= a as u32 << 16;
                ok = within(a, 0, (8i64 << (k - K::SHL8) as i64) - 1);
            },
            K::IMM6X => {
                w |= (a as u32 & 0x3F) << 10;
                ok = within(a, 0, 63);
            },
            _ => {
                ok = false;
            },
        };
        if !ok {
            return false;
        }
        at += slots(k) as usize;
    }
    if (r.fl & FL_SPMOV) != 0 && v[0] != 31 && v[1] != 31 {
        return false;
    }
    *out = w;
    return true;
}

/// Decode word `w` as row `r` into its variant and operand values; false when it is not the row's.
pub fn decode_row(r: Row, w: u32, qo: &mut u32, v: &mut Vals) bool {
    if (w & mask(r)) != r.bits {
        return false;
    }
    let q = qof(r, w);
    if q == 0xFF {
        return false;
    }
    let x = is64(r.q, q);
    let wbits: i64 = if x {
        64;
    } else {
        32;
    };
    let immr = (w >> 16 & 0x3F) as i64;
    let imms = (w >> 10 & 0x3F) as i64;
    let mut at: usize = 0;
    for i in 0..6u32 {
        let k = kind_at(r.ops, i);
        if k == 0 {
            break;
        }
        if is_reg(k) {
            v[at] = w >> reg_pos(k) & 31;
            at += 1;
            continue;
        }
        let mut ok = true;
        switch k {
            K::AIMM => {
                v[at] = w >> 10 & 0xFFF;
                v[at + 1] = w >> 22 & 1;
            },
            K::LIMM | K::LIMMV => {
                let f = w >> 10 & 0x1FFF;
                v[at] = f;
                ok = (switch bitmask_value(f, x) {
                    Some(u) => k == K::LIMM || wide_chunk(u, x) == 4 && wide_chunk(~u & wmask(x), x) == 4,
                    None => false,
                });
            },
            K::MOVW => {
                v[at] = w >> 5 & 0xFFFF;
                v[at + 1] = w >> 21 & 3;
                ok = x || (w >> 22 & 1) == 0;
            },
            K::MOVZV | K::MOVNV => {
                let imm = (w >> 5 & 0xFFFF) as u64;
                let hw = (w >> 21 & 3) as u64;
                let mut u = imm << hw * 16;
                if k == K::MOVNV {
                    u = ~u & wmask(x);
                }
                v[at] = if x {
                    u as i64;
                } else {
                    (u as u32) as i32;
                };
                ok = (imm != 0 || hw == 0) && (x || hw < 2) && (k == K::MOVZV || x || imm != 0xFFFF);
            },
            K::IMMR => {
                v[at] = immr;
                ok = immr < wbits;
            },
            K::IMMS => {
                v[at] = imms;
                ok = imms < wbits;
            },
            K::SHL => {
                v[at] = wbits - immr;
                ok = imms != wbits - 1 && imms + 1 == immr;
            },
            K::SHR => {
                v[at] = immr;
                ok = imms == wbits - 1 && immr < wbits;
            },
            K::BFX => {
                v[at] = immr;
                v[at + 1] = imms - immr + 1;
                ok = imms >= immr && imms < wbits;
            },
            K::BFIZ => {
                v[at] = wbits - immr;
                v[at + 1] = imms + 1;
                ok = imms < immr && immr < wbits;
            },
            K::LSH | K::ASH => {
                v[at] = w >> 22 & 3;
                v[at + 1] = imms;
                ok = (k == K::LSH || v[at] != 3) && imms < wbits;
            },
            K::EXT => {
                v[at] = w >> 13 & 7;
                v[at + 1] = w >> 10 & 7;
                ok = v[at + 1] <= 4;
            },
            K::RMX | K::IMM5 => {
                v[at] = w >> 16 & 31;
            },
            K::COND => {
                v[at] = w >> 12 & 15;
            },
            K::CONDI => {
                let c = w >> 12 & 15;
                v[at] = c ^ 1;
                ok = c < 14;
            },
            K::CONDM | K::NZCV | K::PD => {
                v[at] = w & 15;
            },
            K::IMM16 => {
                v[at] = w >> 5 & 0xFFFF;
            },
            K::UDF16 => {
                v[at] = w & 0xFFFF;
            },
            K::FPIMM => {
                v[at] = w >> 13 & 0xFF;
            },
            K::FZERO | K::SMSM | K::SMZA => {
                v[at] = 0;
            },
            K::L26 => {
                v[at] = sext(w & 0x3FFFFFF, 26) << 2;
            },
            K::L19 => {
                v[at] = sext(w >> 5 & 0x7FFFF, 19) << 2;
            },
            K::L14 => {
                v[at] = sext(w >> 5 & 0x3FFF, 14) << 2;
            },
            K::ADR => {
                v[at] = sext((w >> 5 & 0x7FFFF) << 2 | w >> 29 & 3, 21);
            },
            K::ADRP => {
                v[at] = sext((w >> 5 & 0x7FFFF) << 2 | w >> 29 & 3, 21) << 12;
            },
            K::TBIT => {
                v[at] = w >> 31 << 5 | w >> 19 & 31;
            },
            K::RTB | K::FELEM | K::ZL1 => {
                v[at] = w & 31;
            },
            K::MU12 => {
                v[at] = w >> 5 & 31;
                v[at + 1] = (w >> 10 & 0xFFF) as i64 << ldst_scale(w) as i64;
            },
            K::MS9 | K::MPRE9 | K::MPOST9 => {
                v[at] = w >> 5 & 31;
                v[at + 1] = sext(w >> 12 & 0x1FF, 9);
            },
            K::MREG => {
                v[at] = w >> 5 & 31;
                v[at + 1] = w >> 16 & 31;
                v[at + 2] = w >> 13 & 7;
                v[at + 3] = w >> 12 & 1;
                let o = v[at + 2];
                ok = o == 2 || o == 3 || o == 6 || o == 7;
            },
            K::MP7 | K::MPRE7 | K::MPOST7 => {
                v[at] = w >> 5 & 31;
                v[at + 1] = sext(w >> 15 & 0x7F, 7) << pair_scale(w) as i64;
            },
            K::M0 | K::MZA | K::XLR => {
                v[at] = w >> 5 & 31;
            },
            K::SYSREG => {
                v[at] = w >> 5 & 0x7FFF;
                ok = v[at] >= 0x4000;
            },
            K::BARRIER | K::ISB => {
                v[at] = w >> 8 & 15;
            },
            K::RNM | K::VNM => {
                v[at] = w >> 5 & 31;
                ok = (w >> 5 & 31) == (w >> 16 & 31);
            },
            K::PG | K::PGZ | K::PGM => {
                v[at] = w >> 10 & 7;
            },
            K::PMM => {
                v[at] = w >> 13 & 7;
            },
            K::PND => {
                v[at] = (w & 7) as i64 + 8;
            },
            K::PNGZ | K::PNG => {
                v[at] = (w >> 10 & 7) as i64 + 8;
            },
            K::ZL2 => {
                v[at] = (w >> 1 & 15) as i64 * 2;
            },
            K::ZL4 => {
                v[at] = (w >> 2 & 7) as i64 * 4;
            },
            K::ZAT => {
                v[at] = w & (1u32 << q) - 1;
            },
            K::ZASL => {
                let ob = 4 - q;
                v[at] = (w & 15) as i64 >> ob as i64;
                v[at + 1] = w >> 15 & 1;
                v[at + 2] = w >> 13 & 3;
                v[at + 3] = w & (1u32 << ob) - 1;
            },
            K::ZAARR => {
                v[at] = w >> 13 & 3;
                v[at + 1] = w & 15;
            },
            K::ZAMASK => {
                v[at] = w & 0xFF;
                ok = v[at] != 0;
            },
            K::PAT => {
                v[at] = w >> 5 & 31;
            },
            K::MULVL => {
                v[at] = (w >> 16 & 15) as i64 + 1;
            },
            K::SIMM6 => {
                v[at] = sext(w >> 5 & 0x3F, 6);
            },
            K::MSV => {
                v[at] = w >> 5 & 31;
                v[at + 1] = sext(w >> 16 & 15, 4) * group(r);
            },
            K::MSVR => {
                v[at] = w >> 5 & 31;
                v[at + 1] = w >> 16 & 31;
            },
            K::VLX => {
                v[at] = w >> 13 & 1;
            },
            K::ELB | K::ELH | K::ELS | K::ELD => {
                let sz = el_size(k);
                let i5 = w >> 16 & 31;
                v[at] = w >> 5 & 31;
                v[at + 1] = i5 >> sz + 1;
                ok = (i5 & (2u32 << sz) - 1) == 1u32 << sz;
            },
            K::EDD => {
                let i5 = w >> 16 & 31;
                v[at] = w & 31;
                v[at + 1] = i5 >> 4;
                ok = (i5 & 15) == 8;
            },
            K::EN4D => {
                let i4 = w >> 11 & 15;
                v[at] = w >> 5 & 31;
                v[at + 1] = i4 >> 3;
                ok = (i4 & 7) == 0;
            },
            K::LNB | K::LNH | K::LNS | K::LND => {
                let sz = el_size(k);
                let sb = (w >> 30 & 1) << 3 | (w >> 12 & 1) << 2 | w >> 10 & 3;
                v[at] = w & 31;
                v[at + 1] = sb >> sz;
            },
            K::L2B | K::L3B | K::L4B => {
                v[at] = w & 31;
            },
            K::T1B | K::T2B | K::T3B | K::T4B => {
                v[at] = w >> 5 & 31;
            },
            K::IMM4X => {
                v[at] = w >> 11 & 15;
            },
            K::SHL8 | K::SHL16 | K::SHL32 => {
                v[at] = (w >> 16) as i64 & (8i64 << (k - K::SHL8) as i64) - 1;
            },
            K::IMM6X => {
                v[at] = w >> 10 & 0x3F;
            },
            _ => {
                ok = false;
            },
        };
        if !ok {
            return false;
        }
        at += slots(k) as usize;
    }
    if (r.fl & FL_SPMOV) != 0 && v[0] != 31 && v[1] != 31 {
        return false;
    }
    *qo = q;
    return true;
}

/// Decode word `w`: the index of the first row it matches, the variant and the operand values; false
/// when no row matches.
pub fn decode(w: u32, ri: &mut u32, q: &mut u32, v: &mut Vals) bool {
    let t: []Row = ROWS;
    for i in 0..t.len() {
        if decode_row(t[i], w, q, v) {
            *ri = i as u32;
            return true;
        }
    }
    return false;
}
