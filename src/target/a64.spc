// The arm64 instruction encoder: one function per instruction form, each returning the 32-bit word.
// Registers are numbers: x0 to x30 (31 is sp or the zero register, as the form reads it) and v0 to v31.
// `sf` selects the 64-bit form. Every immediate is the caller's to range-check (`*_fits` helpers).

/// Relocation kinds (`codegen::obj::ORel.kind`).
pub(package) const R_BRANCH26: u8 = 1; // B or BL to a symbol
pub(package) const R_PAGE21: u8 = 2; // ADRP of a symbol's page
pub(package) const R_PAGEOFF12: u8 = 3; // the low 12 bits of its address in an ADD or a load or store
pub(package) const R_GOT_PAGE21: u8 = 4; // ADRP of the page of a symbol's address slot
pub(package) const R_GOT_PAGEOFF12: u8 = 5; // the LDR of that slot
pub(package) const R_TLV_PAGE21: u8 = 6; // ADRP of the page of a thread-local variable's descriptor
pub(package) const R_TLV_PAGEOFF12: u8 = 7; // the LDR of the descriptor's address
pub(package) const R_ABS64: u8 = 8; // a 64-bit address in data
pub(package) const R_TLSDESC_PAGE21: u8 = 9; // ADRP of the page of a thread-local variable's ELF descriptor
pub(package) const R_TLSDESC_LD64: u8 = 10; // the LDR of the descriptor's function
pub(package) const R_TLSDESC_ADD: u8 = 11; // the ADD of the descriptor's page offset
pub(package) const R_TLSDESC_CALL: u8 = 12; // the BLR of the descriptor's function

/// The zero register (or sp in the forms that read it).
pub(package) const ZR: u32 = 31;
pub(package) const SP: u32 = 31;
pub(package) const FP: u32 = 29;
pub(package) const LR: u32 = 30;
pub(package) const IP0: u32 = 16;
pub(package) const IP1: u32 = 17;

/// Condition codes.
pub(package) const EQ: u32 = 0;
pub(package) const NE: u32 = 1;
pub(package) const HS: u32 = 2;
pub(package) const LO: u32 = 3;
pub(package) const MI: u32 = 4;
pub(package) const PL: u32 = 5;
pub(package) const VS: u32 = 6;
pub(package) const VC: u32 = 7;
pub(package) const HI: u32 = 8;
pub(package) const LS: u32 = 9;
pub(package) const GE: u32 = 10;
pub(package) const LT: u32 = 11;
pub(package) const GT: u32 = 12;
pub(package) const LE: u32 = 13;
pub(package) const AL: u32 = 14;

/// The condition that holds when `c` does not.
pub(package) const fn invert(c: u32) u32 {
    return c ^ 1;
}

const fn sfb(sf: bool) u32 {
    return on(sf, 0x80000000);
}

// `v` when `c`, else 0.
pub(package) const fn on(c: bool, v: u32) u32 {
    if c {
        return v;
    }
    return 0;
}

// ---- Data processing, immediate ----

/// ADD, ADDS, SUB, SUBS (immediate): `op` 0 add, 1 sub; `s` sets the flags; `imm` 12 bits, shifted
/// left by 12 when `sh`.
pub(package) const fn addsub_imm(sf: bool, op: u32, s: bool, rd: u32, rn: u32, imm: u32, sh: bool) u32 {
    return sfb(sf) | op << 30 | on(s, 1u32 << 29) | 0x11000000 | on(sh, 1u32 << 22) | (imm & 0xFFF) << 10 | rn << 5 | rd;
}

pub(package) const fn add_imm(sf: bool, rd: u32, rn: u32, imm: u32) u32 {
    return addsub_imm(sf, 0, false, rd, rn, imm, false);
}

pub(package) const fn sub_imm(sf: bool, rd: u32, rn: u32, imm: u32) u32 {
    return addsub_imm(sf, 1, false, rd, rn, imm, false);
}

/// CMP (immediate).
pub(package) const fn cmp_imm(sf: bool, rn: u32, imm: u32) u32 {
    return addsub_imm(sf, 1, true, ZR, rn, imm, false);
}

/// CMN (immediate).
pub(package) const fn cmn_imm(sf: bool, rn: u32, imm: u32) u32 {
    return addsub_imm(sf, 0, true, ZR, rn, imm, false);
}

/// Logical (immediate): `opc` 0 AND, 1 ORR, 2 EOR, 3 ANDS; `nrs` the N:immr:imms field `logical_imm`
/// encodes.
pub(package) const fn logic_imm(sf: bool, opc: u32, rd: u32, rn: u32, nrs: u32) u32 {
    return sfb(sf) | opc << 29 | 0x12000000 | nrs << 10 | rn << 5 | rd;
}

/// MOVN, MOVZ, MOVK: `opc` 0, 2, 3; `hw` the 16-bit chunk the immediate lands in.
pub(package) const fn movw(sf: bool, opc: u32, rd: u32, imm16: u32, hw: u32) u32 {
    return sfb(sf) | opc << 29 | 0x12800000 | hw << 21 | (imm16 & 0xFFFF) << 5 | rd;
}

/// SBFM, BFM, UBFM: `opc` 0, 1, 2.
pub(package) const fn bitfield(sf: bool, opc: u32, rd: u32, rn: u32, immr: u32, imms: u32) u32 {
    let n = if sf {
        0x00400000u32;
    } else {
        0u32;
    };
    return sfb(sf) | opc << 29 | 0x13000000 | n | immr << 16 | imms << 10 | rn << 5 | rd;
}

/// LSL (immediate) by `s`, below the width.
pub(package) const fn lsl_imm(sf: bool, rd: u32, rn: u32, s: u32) u32 {
    let w: u32 = if sf {
        64u32;
    } else {
        32u32;
    };
    return bitfield(sf, 2, rd, rn, (w - s) % w, w - 1 - s);
}

/// LSR (immediate).
pub(package) const fn lsr_imm(sf: bool, rd: u32, rn: u32, s: u32) u32 {
    return bitfield(
        sf,
        2,
        rd,
        rn,
        s,
        if sf {
            63u32;
        } else {
            31u32;
        },
    );
}

/// ASR (immediate).
pub(package) const fn asr_imm(sf: bool, rd: u32, rn: u32, s: u32) u32 {
    return bitfield(
        sf,
        0,
        rd,
        rn,
        s,
        if sf {
            63u32;
        } else {
            31u32;
        },
    );
}

/// Sign-extend the low `bits` (8, 16, 32) of `rn` into `rd`.
pub(package) const fn sxt(sf: bool, rd: u32, rn: u32, bits: u32) u32 {
    return bitfield(sf, 0, rd, rn, 0, bits - 1);
}

/// Zero-extend the low `bits` (8, 16) of `rn` into `rd` (the 32-bit form clears the upper half).
pub(package) const fn uxt(rd: u32, rn: u32, bits: u32) u32 {
    return bitfield(false, 2, rd, rn, 0, bits - 1);
}

/// ADR (`page` false) or ADRP: the 21-bit signed offset in bytes or pages.
pub(package) const fn adr(page: bool, rd: u32, imm21: i32) u32 {
    let u = imm21 as u32;
    let op = if page {
        0x90000000u32;
    } else {
        0x10000000u32;
    };
    return op | (u & 3) << 29 | (u >> 2 & 0x7FFFF) << 5 | rd;
}

// ---- Data processing, register ----

/// Logical (shifted register): `opc` 0 AND, 1 ORR, 2 EOR, 3 ANDS; `n` inverts `rm` (BIC, ORN, EON,
/// BICS); `shift` 0 LSL, 1 LSR, 2 ASR, 3 ROR.
pub(package) const fn logic_reg(sf: bool, opc: u32, n: bool, rd: u32, rn: u32, rm: u32, shift: u32, amt: u32) u32 {
    let nb = if n {
        0x00200000u32;
    } else {
        0u32;
    };
    return sfb(sf) | opc << 29 | 0x0A000000 | shift << 22 | nb | rm << 16 | amt << 10 | rn << 5 | rd;
}

/// MOV (register): ORR from the zero register.
pub(package) const fn mov_reg(sf: bool, rd: u32, rm: u32) u32 {
    return logic_reg(sf, 1, false, rd, ZR, rm, 0, 0);
}

/// MOV to or from sp: ADD (immediate) of 0.
pub(package) const fn mov_sp(rd: u32, rn: u32) u32 {
    return add_imm(true, rd, rn, 0);
}

/// ADD, ADDS, SUB, SUBS (shifted register); register 31 is the zero register.
pub(package) const fn addsub_reg(sf: bool, op: u32, s: bool, rd: u32, rn: u32, rm: u32, shift: u32, amt: u32) u32 {
    return sfb(sf) | op << 30 | on(s, 1u32 << 29) | 0x0B000000 | shift << 22 | rm << 16 | amt << 10 | rn << 5 | rd;
}

/// ADD, ADDS, SUB, SUBS (extended register): `rn` may be sp; `opt` the extension of `rm` (0 UXTB to
/// 3 UXTX, 4 SXTB to 7 SXTX), shifted left by `amt` (0 to 4).
pub(package) const fn addsub_ext(sf: bool, op: u32, s: bool, rd: u32, rn: u32, rm: u32, opt: u32, amt: u32) u32 {
    return sfb(sf) | op << 30 | on(s, 1u32 << 29) | 0x0B200000 | rm << 16 | opt << 13 | amt << 10 | rn << 5 | rd;
}

/// ADC, ADCS, SBC, SBCS: `op` 0 add, 1 subtract.
pub(package) const fn adc(sf: bool, op: u32, s: bool, rd: u32, rn: u32, rm: u32) u32 {
    return sfb(sf) | op << 30 | on(s, 1u32 << 29) | 0x1A000000 | rm << 16 | rn << 5 | rd;
}

/// CSEL (`op` 0, `o2` 0), CSINC (0, 1), CSINV (1, 0), CSNEG (1, 1): `rd` = cond ? rn : f(rm).
pub(package) const fn csel(sf: bool, op: u32, o2: u32, rd: u32, rn: u32, rm: u32, cond: u32) u32 {
    return sfb(sf) | op << 30 | 0x1A800000 | rm << 16 | cond << 12 | o2 << 10 | rn << 5 | rd;
}

/// CSET: 1 when `cond` holds, else 0.
pub(package) const fn cset(sf: bool, rd: u32, cond: u32) u32 {
    return csel(sf, 0, 1, rd, ZR, ZR, invert(cond));
}

/// Two-source operations: `opc` 2 UDIV, 3 SDIV, 8 LSLV, 9 LSRV, 10 ASRV, 11 RORV.
pub(package) const fn dp2(sf: bool, opc: u32, rd: u32, rn: u32, rm: u32) u32 {
    return sfb(sf) | 0x1AC00000 | rm << 16 | opc << 10 | rn << 5 | rd;
}

pub(package) const DP2_UDIV: u32 = 2;
pub(package) const DP2_SDIV: u32 = 3;
pub(package) const DP2_LSLV: u32 = 8;
pub(package) const DP2_LSRV: u32 = 9;
pub(package) const DP2_ASRV: u32 = 10;
pub(package) const DP2_RORV: u32 = 11;

/// One-source operations: `opc` 0 RBIT, 1 REV16, 2 REV (32) or REV32 (64), 3 REV (64), 4 CLZ, 5 CLS.
pub(package) const fn dp1(sf: bool, opc: u32, rd: u32, rn: u32) u32 {
    return sfb(sf) | 0x5AC00000 | opc << 10 | rn << 5 | rd;
}

pub(package) const DP1_RBIT: u32 = 0;
pub(package) const DP1_REV16: u32 = 1;
pub(package) const DP1_REV32: u32 = 2;
pub(package) const DP1_REV64: u32 = 3;
pub(package) const DP1_CLZ: u32 = 4;

/// MADD (`sub` false) or MSUB: `rd` = ra +- rn * rm.
pub(package) const fn madd(sf: bool, sub: bool, rd: u32, rn: u32, rm: u32, ra: u32) u32 {
    let o = if sub {
        0x8000u32;
    } else {
        0u32;
    };
    return sfb(sf) | 0x1B000000 | rm << 16 | o | ra << 10 | rn << 5 | rd;
}

pub(package) const fn mul(sf: bool, rd: u32, rn: u32, rm: u32) u32 {
    return madd(sf, false, rd, rn, rm, ZR);
}

/// SMULL (`signed`) or UMULL: the 64-bit product of two 32-bit registers.
pub(package) const fn mull(signed: bool, rd: u32, rn: u32, rm: u32) u32 {
    let b = if signed {
        0x9B200000u32;
    } else {
        0x9BA00000u32;
    };
    return b | rm << 16 | ZR << 10 | rn << 5 | rd;
}

/// SMULH (`signed`) or UMULH: the high 64 bits of the 128-bit product.
pub(package) const fn mulh(signed: bool, rd: u32, rn: u32, rm: u32) u32 {
    let b = if signed {
        0x9B400000u32;
    } else {
        0x9BC00000u32;
    };
    return b | rm << 16 | ZR << 10 | rn << 5 | rd;
}

// ---- Loads and stores ----

// Memory access kinds: the size (0 byte to 3 doubleword, 4 quadword of a v register), the register
// file and the extension of a load.
pub(package) const M_B: u32 = 0; // LDRB / STRB
pub(package) const M_H: u32 = 1;
pub(package) const M_W: u32 = 2;
pub(package) const M_X: u32 = 3;
pub(package) const M_SB: u32 = 4; // LDRSB into x
pub(package) const M_SH: u32 = 5;
pub(package) const M_SW: u32 = 6;
pub(package) const M_VB: u32 = 7; // v register, byte
pub(package) const M_VH: u32 = 8;
pub(package) const M_VS: u32 = 9;
pub(package) const M_VD: u32 = 10;
pub(package) const M_VQ: u32 = 11;

/// `mov vd, vn` of a whole vector register (`orr vd, vn, vn`): its 16 bytes (`q`), else its low 8.
pub(package) const fn vmov(q: bool, d: u32, n: u32) u32 {
    return 0x0EA01C00 | on(q, 1u32 << 30) | n << 16 | n << 5 | d;
}

/// The log2 of the bytes access `m` moves.
pub(package) const fn msize(m: u32) u32 {
    if m <= M_X {
        return m;
    }
    if m <= M_SW {
        return m - M_SB;
    }
    return m - M_VB;
}

// The opcode bits of access `m` (`load`), with size, V and opc, for the unscaled form.
const fn mbits(m: u32, load: bool) u32 {
    let ld = if load {
        1u32;
    } else {
        0u32;
    };
    if m <= M_X {
        return m << 30 | 0x38000000 | ld << 22;
    }
    if m <= M_SW {
        // opc 10: sign-extend into a 64-bit register.
        return m - M_SB << 30 | 0x38000000 | 2u32 << 22;
    }
    if m == M_VQ {
        return 0x3C000000 | (2u32 | ld) << 22;
    }
    return m - M_VB << 30 | 0x3C000000 | ld << 22;
}

/// LDR/STR (unsigned immediate): `off` in bytes, a multiple of the size below 4096 times it.
pub(package) const fn ldst_uimm(m: u32, load: bool, rt: u32, rn: u32, off: u32) u32 {
    return mbits(m, load) | 0x01000000 | off >> msize(m) << 10 | rn << 5 | rt;
}

/// LDUR/STUR: `off` in -256 to 255.
pub(package) const fn ldst_unscaled(m: u32, load: bool, rt: u32, rn: u32, off: i32) u32 {
    return mbits(m, load) | (off as u32 & 0x1FF) << 12 | rn << 5 | rt;
}

/// LDR/STR (register): the address is rn + rm (64-bit), shifted by the size when `scaled`.
pub(package) const fn ldst_reg(m: u32, load: bool, rt: u32, rn: u32, rm: u32, scaled: bool) u32 {
    let s = if scaled {
        0x1000u32;
    } else {
        0u32;
    };
    return mbits(m, load) | 0x00200800 | rm << 16 | 3u32 << 13 | s | rn << 5 | rt;
}

/// Whether byte offset `off` fits access `m`'s unsigned scaled immediate.
pub(package) const fn uimm_fits(m: u32, off: i64) bool {
    let s = msize(m);
    return off >= 0 && (off & (1i64 << s as i64) - 1) == 0 && off >> s as i64 < 4096;
}

/// LDP/STP: `m` M_W, M_X, M_VS, M_VD or M_VQ; `mode` 1 post-index, 2 signed offset, 3 pre-index; `off` in
/// bytes, a multiple of the size within 7 signed bits of it.
pub(package) const fn ldstp(m: u32, load: bool, mode: u32, rt: u32, rt2: u32, rn: u32, off: i32) u32 {
    let ld = if load {
        0x00400000u32;
    } else {
        0u32;
    };
    let base = if m == M_W {
        0x28000000u32;
    } else if m == M_X {
        0xA8000000u32;
    } else if m == M_VS {
        0x2C000000u32;
    } else if m == M_VD {
        0x6C000000u32;
    } else {
        0xAC000000u32;
    };
    let imm = (off >> msize(m) as i32) as u32 & 0x7F;
    return base | mode << 23 | ld | imm << 15 | rt2 << 10 | rn << 5 | rt;
}

// ---- Branches ----

pub(package) const fn b(off: i32) u32 {
    return 0x14000000 | (off >> 2) as u32 & 0x3FFFFFF;
}

pub(package) const fn bl(off: i32) u32 {
    return 0x94000000 | (off >> 2) as u32 & 0x3FFFFFF;
}

pub(package) const fn bcond(cond: u32, off: i32) u32 {
    return 0x54000000 | ((off >> 2) as u32 & 0x7FFFF) << 5 | cond;
}

/// CBZ (`nz` false) or CBNZ.
pub(package) const fn cbz(sf: bool, nz: bool, rt: u32, off: i32) u32 {
    let o = if nz {
        0x35000000u32;
    } else {
        0x34000000u32;
    };
    return sfb(sf) | o | ((off >> 2) as u32 & 0x7FFFF) << 5 | rt;
}

/// TBZ (`nz` false) or TBNZ on bit `bit`.
pub(package) const fn tbz(nz: bool, rt: u32, bit: u32, off: i32) u32 {
    let o = if nz {
        0x37000000u32;
    } else {
        0x36000000u32;
    };
    return bit >> 5 << 31 | o | (bit & 31) << 19 | ((off >> 2) as u32 & 0x3FFF) << 5 | rt;
}

pub(package) const fn blr(rn: u32) u32 {
    return 0xD63F0000 | rn << 5;
}

/// ISB SY: the spin hint (`yield` is a no-op on Apple cores).
pub(package) const ISB: u32 = 0xD5033FDF;

/// MRS of CNTVCT_EL0, the virtual counter, into `rt`.
pub(package) const fn mrs_cntvct(rt: u32) u32 {
    return 0xD53BE040 | rt;
}

/// MRS of FPCR, the floating-point control register, into `rt`.
pub(package) const fn mrs_fpcr(rt: u32) u32 {
    return 0xD53B4400 | rt;
}

/// RDSVL `rd`, #1: the streaming vector length in bytes (SME).
pub(package) const fn rdsvl1(rd: u32) u32 {
    return 0x04BF5820 | rd;
}

/// MRS of TPIDR_EL0, the thread pointer, into `rt`.
pub(package) const fn mrs_tp(rt: u32) u32 {
    return 0xD53BD040 | rt;
}

pub(package) const RET: u32 = 0xD65F03C0;
pub(package) const NOP: u32 = 0xD503201F;
pub(package) const DMB_ISH: u32 = 0xD5033BBF;

pub(package) const fn brk(imm: u32) u32 {
    return 0xD4200000 | (imm & 0xFFFF) << 5;
}

/// Patch the displacement of branch `w` (B, BL, B.cond, CBZ, CBNZ, TBZ, TBNZ) to `off` bytes.
pub(package) const fn repatch(w: u32, off: i32) u32 {
    if (w & 0x7C000000) == 0x14000000 {
        return w & 0xFC000000 | (off >> 2) as u32 & 0x3FFFFFF;
    }
    if (w & 0x7E000000) == 0x36000000 {
        return w & 0xFFF8001F | ((off >> 2) as u32 & 0x3FFF) << 5;
    }
    return w & 0xFF00001F | ((off >> 2) as u32 & 0x7FFFF) << 5;
}

/// Whether a branch of `w`'s kind reaches `off` bytes.
pub(package) const fn reaches(w: u32, off: i64) bool {
    if (w & 0x7C000000) == 0x14000000 {
        return off >= -(1i64 << 27) && off < 1i64 << 27;
    }
    if (w & 0x7E000000) == 0x36000000 {
        return off >= -(1i64 << 15) && off < 1i64 << 15;
    }
    return off >= -(1i64 << 20) && off < 1i64 << 20;
}

// ---- Floating point and vector ----

// `d` selects double precision.
const fn ftype(d: bool) u32 {
    return if d {
        0x00400000u32;
    } else {
        0u32;
    };
}

/// FMOV (register).
pub(package) const fn fmov(d: bool, rd: u32, rn: u32) u32 {
    return 0x1E204000 | ftype(d) | rn << 5 | rd;
}

/// FMOV between an x or w register and a v register: `to_v` moves into the v register.
pub(package) const fn fmov_gv(d: bool, to_v: bool, rd: u32, rn: u32) u32 {
    let base = if d {
        0x9E660000u32;
    } else {
        0x1E260000u32;
    };
    let t = if to_v {
        0x10000u32;
    } else {
        0u32;
    };
    return base | t | rn << 5 | rd;
}

/// Two-operand float arithmetic: `opc` 0 FMUL, 1 FDIV, 2 FADD, 3 FSUB, 4 FMAX, 5 FMIN, 6 FMAXNM,
/// 7 FMINNM.
pub(package) const fn fp2(d: bool, opc: u32, rd: u32, rn: u32, rm: u32) u32 {
    return 0x1E200800 | ftype(d) | rm << 16 | opc << 12 | rn << 5 | rd;
}

pub(package) const FP_MUL: u32 = 0;
pub(package) const FP_DIV: u32 = 1;
pub(package) const FP_ADD: u32 = 2;
pub(package) const FP_SUB: u32 = 3;
pub(package) const FP_MAX: u32 = 4;
pub(package) const FP_MIN: u32 = 5;
pub(package) const FP_MAXNM: u32 = 6;
pub(package) const FP_MINNM: u32 = 7;

/// One-operand float operations: `opc` 1 FABS, 2 FNEG, 3 FSQRT, 8 FRINTN, 9 FRINTP, 10 FRINTM,
/// 11 FRINTZ, 12 FRINTA, 14 FRINTX, 15 FRINTI.
pub(package) const fn fp1(d: bool, opc: u32, rd: u32, rn: u32) u32 {
    return 0x1E204000 | ftype(d) | opc << 15 | rn << 5 | rd;
}

pub(package) const FP_ABS: u32 = 1;
pub(package) const FP_NEG: u32 = 2;
pub(package) const FP_SQRT: u32 = 3;
pub(package) const FP_RINTN: u32 = 8;
pub(package) const FP_RINTP: u32 = 9;
pub(package) const FP_RINTM: u32 = 10;
pub(package) const FP_RINTZ: u32 = 11;
pub(package) const FP_RINTA: u32 = 12;
pub(package) const FP_RINTX: u32 = 14;

/// FCVT: single to double (`to_d`) or double to single.
pub(package) const fn fcvt(to_d: bool, rd: u32, rn: u32) u32 {
    return if to_d {
        0x1E22C000 | rn << 5 | rd;
    } else {
        0x1E624000 | rn << 5 | rd;
    };
}

/// FCMP `rn`, `rm`.
pub(package) const fn fcmp(d: bool, rn: u32, rm: u32) u32 {
    return 0x1E202000 | ftype(d) | rm << 16 | rn << 5;
}

/// FCSEL: `rd` = cond ? rn : rm.
pub(package) const fn fcsel(d: bool, rd: u32, rn: u32, rm: u32, cond: u32) u32 {
    return 0x1E200C00 | ftype(d) | rm << 16 | cond << 12 | rn << 5 | rd;
}

/// FMADD (`sub` false) or FMSUB: `rd` = ra +- rn * rm.
pub(package) const fn fmadd(d: bool, sub: bool, rd: u32, rn: u32, rm: u32, ra: u32) u32 {
    let o = if sub {
        0x8000u32;
    } else {
        0u32;
    };
    return 0x1F000000 | ftype(d) | rm << 16 | o | ra << 10 | rn << 5 | rd;
}

/// SCVTF (`signed`) or UCVTF: integer register `rn` (64-bit when `sf`) to float `rd`.
pub(package) const fn cvtf(sf: bool, d: bool, signed: bool, rd: u32, rn: u32) u32 {
    let o = if signed {
        0x1E220000u32;
    } else {
        0x1E230000u32;
    };
    return sfb(sf) | o | ftype(d) | rn << 5 | rd;
}

/// FCVTZS (`signed`) or FCVTZU: float `rn` to integer `rd` (64-bit when `sf`), toward zero, saturating,
/// NaN to 0.
pub(package) const fn fcvtz(sf: bool, d: bool, signed: bool, rd: u32, rn: u32) u32 {
    let o = if signed {
        0x1E380000u32;
    } else {
        0x1E390000u32;
    };
    return sfb(sf) | o | ftype(d) | rn << 5 | rd;
}

/// Advanced SIMD three-same: lanes of `size` (0 bytes .. 3 doublewords; a float operation's `size` holds
/// its own bits), 16 bytes when `q`, else 8.
pub(package) const fn v3(q: bool, u: bool, size: u32, opcode: u32, rd: u32, rn: u32, rm: u32) u32 {
    return 0x0E200400 | on(q, 1u32 << 30) | on(u, 1u32 << 29) | size << 22 | rm << 16 | opcode << 11 | rn << 5 | rd;
}

/// Three-same operations as (U << 5 | opcode); the size field picks the lanes, or for AND/BIC/ORR/EOR the
/// operation (`V3_AND` with size 0, BIC 1, ORR 2; `V3_EOR` with size 0).
pub(package) const V3_ADD: u32 = 0x10;
pub(package) const V3_SUB: u32 = 0x30;
pub(package) const V3_MUL: u32 = 0x13;
pub(package) const V3_SMAX: u32 = 0x0C;
pub(package) const V3_UMAX: u32 = 0x2C;
pub(package) const V3_SMIN: u32 = 0x0D;
pub(package) const V3_UMIN: u32 = 0x2D;
pub(package) const V3_AND: u32 = 0x03;
pub(package) const V3_EOR: u32 = 0x23;
/// Float three-same (size bit 1 adds to the opcode below where marked; bit 0 is the double flag).
pub(package) const V3_FADD: u32 = 0x1A; // size 0|sz
pub(package) const V3_FSUB: u32 = 0x1A; // size 2|sz
pub(package) const V3_FMUL: u32 = 0x3B; // size 0|sz
pub(package) const V3_FDIV: u32 = 0x3F; // size 0|sz
pub(package) const V3_FMLA: u32 = 0x19; // size 0|sz
pub(package) const V3_FMAXNM: u32 = 0x18; // size 0|sz
pub(package) const V3_FMINNM: u32 = 0x18; // size 2|sz
pub(package) const V3_FMAX: u32 = 0x1E; // size 0|sz
pub(package) const V3_FMIN: u32 = 0x1E; // size 2|sz

/// A three-same operation `op` (`V3_*`).
pub(package) const fn v3op(q: bool, op: u32, size: u32, rd: u32, rn: u32, rm: u32) u32 {
    return v3(q, op >> 5 != 0, size, op & 31, rd, rn, rm);
}

/// Advanced SIMD two-register miscellaneous: as `v3` with (U << 5 | opcode) `op`.
pub(package) const fn v2op(q: bool, op: u32, size: u32, rd: u32, rn: u32) u32 {
    return 0x0E200800 | on(q, 1u32 << 30) | on(op >> 5 != 0, 1u32 << 29) | size << 22 | (op & 31) << 12 | rn << 5 | rd;
}

pub(package) const V2_NEG: u32 = 0x2B;
pub(package) const V2_ABS: u32 = 0x0B;
pub(package) const V2_NOT: u32 = 0x25; // size 0
pub(package) const V2_FNEG: u32 = 0x2F; // size 2|sz
pub(package) const V2_FABS: u32 = 0x0F; // size 2|sz
pub(package) const V2_FSQRT: u32 = 0x3F; // size 2|sz
pub(package) const V2_FRINTN: u32 = 0x18; // size 0|sz
pub(package) const V2_FRINTM: u32 = 0x19; // size 0|sz
pub(package) const V2_FRINTP: u32 = 0x18; // size 2|sz
pub(package) const V2_FRINTZ: u32 = 0x19; // size 2|sz
pub(package) const V2_CNT: u32 = 0x05; // size 0

/// CNT (8 bytes): the population count of each byte.
pub(package) const fn cnt8b(rd: u32, rn: u32) u32 {
    return 0x0E205800 | rn << 5 | rd;
}

/// ADDV (8 bytes): the sum of the bytes into byte 0.
pub(package) const fn addv8b(rd: u32, rn: u32) u32 {
    return 0x0E31B800 | rn << 5 | rd;
}

// ---- Atomics ----

/// LDAR (`load`) or STLR of access size `size` (0 to 3).
pub(package) const fn ldar(size: u32, load: bool, rt: u32, rn: u32) u32 {
    let b = if load {
        0x08DFFC00u32;
    } else {
        0x089FFC00u32;
    };
    return size << 30 | b | rn << 5 | rt;
}

/// The LSE atomic memory operations: `opc` 0 LDADD, 1 LDCLR, 2 LDEOR, 3 LDSET, 8 SWP; `a` acquire,
/// `r` release.
pub(package) const fn lse(size: u32, opc: u32, a: bool, r: bool, rs: u32, rt: u32, rn: u32) u32 {
    let ab = if a {
        0x00800000u32;
    } else {
        0u32;
    };
    let rb = if r {
        0x00400000u32;
    } else {
        0u32;
    };
    return size << 30 | 0x38200000 | ab | rb | rs << 16 | opc >> 3 << 15 | (opc & 7) << 12 | rn << 5 | rt;
}

pub(package) const LSE_ADD: u32 = 0;
pub(package) const LSE_CLR: u32 = 1;
pub(package) const LSE_EOR: u32 = 2;
pub(package) const LSE_SET: u32 = 3;
pub(package) const LSE_SWP: u32 = 8;

/// CAS: compare `rs` with memory at `rn`, store `rt` when equal; `rs` receives the old value.
pub(package) const fn cas(size: u32, a: bool, r: bool, rs: u32, rt: u32, rn: u32) u32 {
    let ab = if a {
        0x00400000u32;
    } else {
        0u32;
    };
    let rb = if r {
        0x8000u32;
    } else {
        0u32;
    };
    return size << 30 | 0x08A07C00 | ab | rb | rs << 16 | rn << 5 | rt;
}

// ---- Immediates ----

/// The N:immr:imms field of 64-bit (`sf`) or 32-bit logical immediate `v`, or NONE (0xFFFFFFFF) when
/// `v` is no repeated rotated run of ones (all zeros and all ones are none).
pub(package) const fn logical_imm(v0: u64, sf: bool) u32 {
    let mut v = v0;
    if !sf {
        v &= 0xFFFFFFFF;
        v |= v << 32;
    }
    if v == 0 || v == 0xFFFFFFFFFFFFFFFFu64 {
        return 0xFFFFFFFF;
    }
    // The smallest element size whose copies make `v`.
    let mut size: u64 = 64;
    for _ in 0..5 {
        let half = size / 2;
        let mask = (1u64 << half) - 1;
        if (v & mask) != (v >> half & mask) {
            break;
        }
        size = half;
    }
    let mask = if size == 64 {
        0xFFFFFFFFFFFFFFFFu64;
    } else {
        (1u64 << size) - 1;
    };
    let e = v & mask;
    // A run of `ones` ones rotated right by `rot` within the element.
    let mut rot: u64 = 0;
    let mut ones: u64 = 0;
    if shifted_mask(e) {
        rot = e.trailing_zeros() as u64;
        ones = (~(e >> rot)).trailing_zeros() as u64;
    } else {
        let f = e | ~mask;
        if !shifted_mask(~f) {
            return 0xFFFFFFFF;
        }
        let clo = (~f).leading_zeros() as u64;
        rot = 64 - clo;
        ones = clo + (~f).trailing_zeros() as u64 - (64 - size);
    }
    let immr = size - rot & size - 1;
    let mut nimms = ~(size - 1) << 1;
    nimms |= ones - 1;
    let n = nimms >> 6 & 1 ^ 1;
    return (n << 12 | immr << 6 | nimms & 0x3F) as u32;
}

// Whether `v` is one contiguous run of ones (not empty).
const fn shifted_mask(v: u64) bool {
    if v == 0 {
        return false;
    }
    let x = v | v - 1;
    return (x & x.wrapping_add(1)) == 0;
}

/// The 8-bit FMOV immediate of float bits `bits` (`d` double), or NONE when it has none.
pub(package) const fn fp_imm8(d: bool, bits: u64) u32 {
    if d {
        // aBbb bbbb bbcd efgh 0..0 (48 zero bits).
        if (bits & 0xFFFFFFFFFFFF) != 0 {
            return 0xFFFFFFFF;
        }
        let b6 = bits >> 54 & 0xFF;
        if b6 != 0x00 && b6 != 0xFF {
            return 0xFFFFFFFF;
        }
        let b62 = bits >> 62 & 1;
        if (b6 & 1) == b62 {
            return 0xFFFFFFFF;
        }
        return ((bits >> 63 & 1) << 7 | (b6 & 1) << 6 | bits >> 48 & 0x3F) as u32;
    }
    // aBbb bbbc defg h000 0..0 (19 zero bits).
    if (bits & 0x7FFFF) != 0 || bits >> 32 != 0 {
        return 0xFFFFFFFF;
    }
    let b5 = bits >> 25 & 0x1F;
    if b5 != 0 && b5 != 0x1F {
        return 0xFFFFFFFF;
    }
    let b30 = bits >> 30 & 1;
    if (b5 & 1) == b30 {
        return 0xFFFFFFFF;
    }
    return ((bits >> 31 & 1) << 7 | (b5 & 1) << 6 | bits >> 19 & 0x3F) as u32;
}

/// FMOV (immediate) of `imm8` (`fp_imm8`).
pub(package) const fn fmov_imm(d: bool, rd: u32, imm8: u32) u32 {
    return 0x1E201000 | ftype(d) | imm8 << 13 | rd;
}
