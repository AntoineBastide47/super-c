// The x86-64 instruction encoder: one function per instruction form, each appending its bytes to a code
// buffer. Registers are numbers: rax 0, rcx 1, rdx 2, rbx 3, rsp 4, rbp 5, rsi 6, rdi 7, r8..r15 8..15;
// xmm0..xmm15 are 0..15 in the vector forms. `sz` is an operand size in bytes: 1, 2, 4 or 8. A memory
// operand is a base register (or RIP), an optional index scaled by 1, 2, 4 or 8, and a 32-bit
// displacement; a RIP-relative one leaves its displacement for a relocation (`Mem::rip`, `RIP_AT`).

/// Relocation kinds (`codegen::obj::ORel.kind`): a 32-bit PC-relative field (its addend counts from the
/// field: -4 and less), a call through the PLT, the address slot of a symbol in the GOT (relaxable), the
/// thread-local general-dynamic descriptor, a 64-bit absolute address, and (COFF) a 32-bit offset from
/// the start of the target's section (a thread-local's offset in the thread's block).
pub const R_PC32: u8 = 1;
pub const R_PLT32: u8 = 2;
pub const R_GOTPCRELX: u8 = 3;
pub const R_REX_GOTPCRELX: u8 = 4;
pub const R_TLSGD: u8 = 5;
pub const R_ABS64: u8 = 6;
pub const R_SECREL: u8 = 7;

pub const RAX: u8 = 0;
pub const RCX: u8 = 1;
pub const RDX: u8 = 2;
pub const RBX: u8 = 3;
pub const RSP: u8 = 4;
pub const RBP: u8 = 5;
pub const RSI: u8 = 6;
pub const RDI: u8 = 7;
pub const R8: u8 = 8;
pub const R9: u8 = 9;
pub const R10: u8 = 10;
pub const R11: u8 = 11;
pub const R12: u8 = 12;
pub const R13: u8 = 13;

/// No register (a memory operand without an index), and the RIP base.
pub const NOREG: u8 = 0xFF;
pub const RIP: u8 = 0xFE;
/// The incoming frame as a base: rsp plus a distance the frame's size gives once known. Its operands encode
/// as rsp + a 32-bit displacement, whose positions `Code.in_at` lists for `Code::rebase`.
pub const IN: u8 = 0xF4;

// Condition codes (the low nibble of Jcc, SETcc, CMOVcc).
pub const CC_O: u32 = 0;
pub const CC_NO: u32 = 1;
pub const CC_B: u32 = 2; // below (CF)
pub const CC_AE: u32 = 3;
pub const CC_E: u32 = 4;
pub const CC_NE: u32 = 5;
pub const CC_BE: u32 = 6;
pub const CC_A: u32 = 7;
pub const CC_S: u32 = 8;
pub const CC_NS: u32 = 9;
pub const CC_P: u32 = 10;
pub const CC_NP: u32 = 11;
pub const CC_L: u32 = 12;
pub const CC_GE: u32 = 13;
pub const CC_LE: u32 = 14;
pub const CC_G: u32 = 15;

/// The opposite condition.
pub const fn invert(cc: u32) u32 {
    return cc ^ 1;
}

// ALU operations of the `00..3F` group: the ModRM reg field of `81 /n` and `83 /n`.
pub const ADD: u32 = 0;
pub const OR: u32 = 1;
pub const ADC: u32 = 2;
pub const SBB: u32 = 3;
pub const AND: u32 = 4;
pub const SUB: u32 = 5;
pub const XOR: u32 = 6;
pub const CMP: u32 = 7;

// The `F7` group: the ModRM reg field.
pub const NOT: u32 = 2;
pub const NEG: u32 = 3;
pub const MUL: u32 = 4;
pub const IMUL1: u32 = 5;
pub const DIV: u32 = 6;
pub const IDIV: u32 = 7;

// Shifts: the ModRM reg field of `C1`, `D3`.
pub const ROL: u32 = 0;
pub const ROR: u32 = 1;
pub const SHL: u32 = 4;
pub const SHR: u32 = 5;
pub const SAR: u32 = 7;

/// A memory operand: `base` + `index` << `scale` + `disp`; `base` RIP for a RIP-relative one.
pub struct Mem {
    pub base: u8,
    pub index: u8,
    pub scale: u8,
    pub disp: i32,
}

extend Mem as Copy {}

/// `base` + `disp`.
pub const fn at(base: u8, disp: i32) Mem {
    return Mem { base: base, index: NOREG, scale: 0, disp: disp };
}

/// `base` + `index` << `scale` + `disp`.
pub const fn ix(base: u8, index: u8, scale: u8, disp: i32) Mem {
    return Mem { base: base, index: index, scale: scale, disp: disp };
}

/// RIP-relative, its displacement 0 for a relocation.
pub const fn rip() Mem {
    return Mem { base: RIP, index: NOREG, scale: 0, disp: 0 };
}

/// The code position of the displacement of the last RIP-relative operand an encoder wrote: the
/// caller's relocation goes there. Set by every form that takes a `Mem`. `jumps`: the positions of the
/// 32-bit displacements of the jumps, ascending, for `relax`; `in_at`: the positions of the displacements of
/// the operands based on `IN`.
pub struct Code {
    pub b: Vector<u8>,
    pub rip_at: u32,
    pub jumps: Vector<u32>,
    pub in_at: Vector<u32>,
}

extend Code {
    pub fn new() Code {
        return Code { b: Vector::<u8>::new(), rip_at: 0, jumps: Vector::<u32>::new(), in_at: Vector::<u32>::new() };
    }

    /// Empty the code for the next function.
    pub fn clear(self: &mut Self) {
        self.b.truncate(0);
        self.jumps.truncate(0);
        self.in_at.truncate(0);
    }

    /// Add `d` to the displacement of every operand based on `IN`: the distance from rsp to the incoming
    /// frame, once the frame's size is known.
    pub fn rebase(self: &mut Self, d: i32) {
        for k in 0..self.in_at.len() {
            let at = self.in_at[k] as usize;
            let mut v: u32 = 0;
            for q in 0..4usize {
                v |= self.b[at + q] as u32 << 8 * q as u32;
            }
            v = (v as i32 + d) as u32;
            for q in 0..4usize {
                self.b[at + q] = (v >> 8 * q as u32) as u8;
            }
        }
    }

    /// Give every jump whose target an 8-bit displacement reaches its 2-byte form, every target and the
    /// positions `at` (none inside a jump) moved with the code. A shorter jump never lengthens another's
    /// distance, so the passes stop once one shortens none: at most one pass per jump, plus one.
    pub fn relax(self: &mut Self, at: &mut Vector<u32>) {
        let nj = self.jumps.len();
        if nj == 0 {
            return;
        }
        // Per jump: its first byte, its target, its saving when short (4 for a `jcc`, 3 for a `jmp`).
        let mut op = Vector::<u32>::with_capacity(nj);
        let mut to = Vector::<u32>::with_capacity(nj);
        let mut save = Vector::<u32>::with_capacity(nj);
        for k in 0..nj {
            let d = self.jumps[k];
            let jcc = self.b[d as usize - 1] != 0xE9;
            op.push(d - 1 - jcc as u32);
            to.push((d as i64 + 4 + (read32(&self.b, d) as i32) as i64) as u32);
            save.push(3 + jcc as u32);
        }
        // `cut[k]`: the bytes the short jumps before jump k save; `cut[nj]` all of them.
        let mut short = Vector::<bool>::new();
        short.resize_default(nj);
        let mut cut = Vector::<u32>::new();
        cut.resize_default(nj + 1);
        for _ in 0..nj + 1 {
            for k in 0..nj {
                cut[k + 1] = cut[k] + if short[k] {
                    save[k];
                } else {
                    0;
                };
            }
            let mut changed = false;
            for k in 0..nj {
                if short[k] {
                    continue;
                }
                let d = moved(&op, &cut, to[k]) as i64 - (moved(&op, &cut, op[k]) as i64 + 2);
                if d >= -128 && d <= 127 {
                    short[k] = true;
                    changed = true;
                }
            }
            if !changed {
                break;
            }
        }
        for k in 0..nj {
            cut[k + 1] = cut[k] + if short[k] {
                save[k];
            } else {
                0;
            };
        }
        let mut nb = Vector::<u8>::with_capacity(self.b.len() - cut[nj] as usize);
        let mut from: u32 = 0;
        for k in 0..nj {
            for q in from..op[k] {
                nb.push(self.b[q as usize]);
            }
            let jcc = save[k] == 4;
            let cc = if jcc {
                self.b[op[k] as usize + 1] as u32 & 15;
            } else {
                0;
            };
            let here = nb.len() as i64;
            let tgt = moved(&op, &cut, to[k]) as i64;
            if short[k] {
                nb.push(
                    if jcc {
                        (0x70 + cc) as u8;
                    } else {
                        0xEB;
                    },
                );
                nb.push((tgt - (here + 2)) as u8);
            } else {
                if jcc {
                    nb.push(0x0F);
                    nb.push((0x80 + cc) as u8);
                } else {
                    nb.push(0xE9);
                }
                let d = (tgt - (nb.len() as i64 + 4)) as u32;
                for q in 0..4u32 {
                    nb.push((d >> 8 * q & 0xFF) as u8);
                }
            }
            from = op[k] + save[k] + 2;
        }
        for q in from..self.b.len() as u32 {
            nb.push(self.b[q as usize]);
        }
        for k in 0..at.len() {
            at[k] = moved(&op, &cut, at[k]);
        }
        self.b = nb;
        self.jumps.truncate(0);
    }

    pub const fn len(self: &Self) u32 {
        return self.b.len() as u32;
    }

    pub fn byte(self: &mut Self, x: u32) {
        self.b.push((x & 0xFF) as u8);
    }

    pub fn d32(self: &mut Self, x: u32) {
        self.byte(x);
        self.byte(x >> 8);
        self.byte(x >> 16);
        self.byte(x >> 24);
    }

    pub fn d64(self: &mut Self, x: u64) {
        self.d32(x as u32);
        self.d32((x >> 32) as u32);
    }

    /// Overwrite the 32-bit field at `at` with `x`.
    pub const fn patch32(self: &mut Self, at: u32, x: u32) {
        for k in 0..4u32 {
            self.b[(at + k) as usize] = (x >> 8 * k & 0xFF) as u8;
        }
    }

    // ---- Prefixes, ModRM, SIB ----

    // The operand-size prefix of a 2-byte operation.
    fn osize(self: &mut Self, sz: u32) {
        if sz == 2 {
            self.byte(0x66);
        }
    }

    // REX for a register-direct form: `reg` in ModRM.reg, `rm` in ModRM.rm. A byte operation on spl, bpl,
    // sil or dil needs one even with no bit (`byte`).
    fn rex_rr(self: &mut Self, w: bool, reg: u8, rm: u8, breg: bool, brm: bool) {
        let r = w as u32 << 3 | (reg as u32 >> 3 & 1) << 2 | rm as u32 >> 3 & 1;
        if r != 0 || breg && reg >= 4 && reg < 8 || brm && rm >= 4 && rm < 8 {
            self.byte(0x40 | r);
        }
    }

    // REX for a memory form.
    fn rex_m(self: &mut Self, w: bool, reg: u8, m: Mem, byte: bool) {
        let x = if m.index != NOREG {
            m.index as u32 >> 3 & 1;
        } else {
            0u32;
        };
        let b = if m.base != RIP && m.base != NOREG {
            m.base as u32 >> 3 & 1;
        } else {
            0u32;
        };
        let r = w as u32 << 3 | (reg as u32 >> 3 & 1) << 2 | x << 1 | b;
        if r != 0 || byte && reg >= 4 && reg < 8 {
            self.byte(0x40 | r);
        }
    }

    // An opcode of 1, 2 or 3 bytes (`0F xx`, `0F 38 xx`, `0F 3A xx`).
    fn opc(self: &mut Self, op: u32) {
        if op > 0xFFFF {
            self.byte(op >> 16);
        }
        if op > 0xFF {
            self.byte(op >> 8);
        }
        self.byte(op);
    }

    // ModRM of a register-direct form.
    fn modrm_rr(self: &mut Self, reg: u8, rm: u8) {
        self.byte(0xC0 | (reg as u32 & 7) << 3 | rm as u32 & 7);
    }

    // ModRM, SIB and displacement of memory operand `m`. A RIP displacement counts from the instruction's
    // end, which the relocation's addend covers.
    fn modrm_m(self: &mut Self, reg: u8, m: Mem) {
        self.modrm_n(reg, m, 1);
    }

    // `modrm_m` with 8-bit displacements counted in `n8`-byte units (EVEX's compressed displacement).
    fn modrm_n(self: &mut Self, reg: u8, m: Mem, n8: i32) {
        let rg = (reg as u32 & 7) << 3;
        if m.base == RIP {
            self.byte(rg | 5);
            self.rip_at = self.len();
            self.d32(m.disp as u32);
            return;
        }
        if m.base == IN {
            // rsp with a SIB byte and a 32-bit displacement, which `rebase` adjusts.
            let idx = if m.index == NOREG {
                4u32;
            } else {
                m.index as u32 & 7;
            };
            self.byte(2 << 6 | rg | 4);
            self.byte(m.scale as u32 << 6 | idx << 3 | 4);
            self.in_at.push(self.len());
            self.d32(m.disp as u32);
            return;
        }
        let base = m.base as u32 & 7;
        let d8 = m.disp % n8 == 0 && m.disp / n8 >= -128 && m.disp / n8 < 128;
        // rbp and r13 as a base take a displacement even when it is 0.
        let md: u32 = if m.disp == 0 && base != 5 {
            0;
        } else if d8 {
            1;
        } else {
            2;
        };
        if m.index == NOREG && base != 4 {
            self.byte(md << 6 | rg | base);
        } else {
            // A SIB byte: an index, or rsp and r12 as a base (index 100: none).
            let idx = if m.index == NOREG {
                4u32;
            } else {
                m.index as u32 & 7;
            };
            self.byte(md << 6 | rg | 4);
            self.byte(m.scale as u32 << 6 | idx << 3 | base);
        }
        if md == 1 {
            self.byte((m.disp / n8) as u32);
        } else if md == 2 {
            self.d32(m.disp as u32);
        }
    }

    /// `op reg, rm` (register direct) with mandatory prefix `pfx` (0: none) and REX.W `w`; `byte` when `rm`
    /// is a byte register (`reg` is an opcode digit or a wider register).
    pub fn rr(self: &mut Self, pfx: u32, op: u32, w: bool, reg: u8, rm: u8, byte: bool) {
        if pfx != 0 {
            self.byte(pfx);
        }
        self.rex_rr(w, reg, rm, false, byte);
        self.opc(op);
        self.modrm_rr(reg, rm);
    }

    /// `op reg, [m]` with mandatory prefix `pfx` and REX.W `w`.
    pub fn rm(self: &mut Self, pfx: u32, op: u32, w: bool, reg: u8, m: Mem, byte: bool) {
        if pfx != 0 {
            self.byte(pfx);
        }
        self.rex_m(w, reg, m, byte);
        self.opc(op);
        self.modrm_m(reg, m);
    }

    // ---- Moves ----

    /// `dst` = `src` (`sz` 4 zero-extends, 8 copies all).
    pub fn mov_rr(self: &mut Self, sz: u32, dst: u8, src: u8) {
        self.rr(0, 0x89, sz == 8, src, dst, false);
    }

    /// `dst` = `v`: a 32-bit immediate zero-extends, a negative 32-bit one sign-extends, else 10 bytes.
    pub fn mov_ri(self: &mut Self, dst: u8, v: u64) {
        if v <= 0xFFFFFFFF {
            if dst >= 8 {
                self.byte(0x41);
            }
            self.byte(0xB8 + (dst as u32 & 7));
            self.d32(v as u32);
            return;
        }
        if v >= 0xFFFFFFFF80000000 {
            self.rex_rr(true, 0, dst, false, false);
            self.byte(0xC7);
            self.modrm_rr(0, dst);
            self.d32(v as u32);
            return;
        }
        self.byte(0x48 | dst as u32 >> 3 & 1);
        self.byte(0xB8 + (dst as u32 & 7));
        self.d64(v);
    }

    /// `dst` = the `sz` bytes at `m`, zero-extended (`sx`: sign-extended) to 64 bits; 4 bytes
    /// zero-extend unless `sx`.
    pub fn load(self: &mut Self, sz: u32, sx: bool, dst: u8, m: Mem) {
        if sz == 1 {
            self.rm(
                0,
                if sx {
                    0x0FBE;
                } else {
                    0x0FB6;
                },
                sx,
                dst,
                m,
                false,
            );
        } else if sz == 2 {
            self.rm(
                0,
                if sx {
                    0x0FBF;
                } else {
                    0x0FB7;
                },
                sx,
                dst,
                m,
                false,
            );
        } else if sz == 4 && sx {
            self.rm(0, 0x63, true, dst, m, false);
        } else {
            self.rm(0, 0x8B, sz == 8, dst, m, false);
        }
    }

    /// The low `sz` bytes of `src` to `m`.
    pub fn store(self: &mut Self, sz: u32, src: u8, m: Mem) {
        self.osize(sz);
        self.rm(
            0,
            if sz == 1 {
                0x88u32;
            } else {
                0x89u32;
            },
            sz == 8,
            src,
            m,
            sz == 1,
        );
    }

    /// `sz` bytes of immediate `v` (sign-extended from 32 bits for 8) to `m`.
    pub fn store_i(self: &mut Self, sz: u32, v: i32, m: Mem) {
        self.osize(sz);
        self.rm(
            0,
            if sz == 1 {
                0xC6u32;
            } else {
                0xC7u32;
            },
            sz == 8,
            0,
            m,
            false,
        );
        if sz == 1 {
            self.byte(v as u32);
        } else if sz == 2 {
            self.byte(v as u32);
            self.byte(v as u32 >> 8);
        } else {
            self.d32(v as u32);
        }
    }

    /// `dst` = the address of `m`.
    pub fn lea(self: &mut Self, dst: u8, m: Mem) {
        self.rm(0, 0x8D, true, dst, m, false);
    }

    /// `dst` = `src`'s low `from` bytes (1, 2 or 4) extended to `to` bytes (4 or 8), signed `sx`.
    pub fn ext(self: &mut Self, from: u32, to: u32, sx: bool, dst: u8, src: u8) {
        if from == 4 {
            if sx {
                self.rr(0, 0x63, true, dst, src, false);
            } else {
                self.mov_rr(4, dst, src);
            }
            return;
        }
        let op = if from == 1 && sx {
            0x0FBEu32;
        } else if from == 1 {
            0x0FB6u32;
        } else if sx {
            0x0FBFu32;
        } else {
            0x0FB7u32;
        };
        self.rr(0, op, sx && to == 8, dst, src, from == 1);
    }

    // ---- Integer operations ----

    /// `dst` = `dst` op `src` (`ADD` .. `CMP`).
    pub fn alu_rr(self: &mut Self, op: u32, sz: u32, dst: u8, src: u8) {
        self.osize(sz);
        self.rr_both(
            (op << 3) + if sz == 1 {
                0u32;
            } else {
                1u32;
            },
            sz,
            src,
            dst,
        );
    }

    // `op r/m, reg` of `sz` bytes where both registers are operands of that size: a byte register
    // past bl needs a REX.
    fn rr_both(self: &mut Self, op: u32, sz: u32, reg: u8, rm: u8) {
        self.rex_rr(sz == 8, reg, rm, sz == 1, sz == 1);
        self.opc(op);
        self.modrm_rr(reg, rm);
    }

    /// `dst` = `dst` op `[m]`.
    pub fn alu_rm(self: &mut Self, op: u32, sz: u32, dst: u8, m: Mem) {
        self.osize(sz);
        self.rm(
            0,
            (op << 3) + if sz == 1 {
                2u32;
            } else {
                3u32;
            },
            sz == 8,
            dst,
            m,
            sz == 1,
        );
    }

    /// `dst` = `dst` op `k` (a sign-extended 32-bit immediate; 8 bits when it fits).
    pub fn alu_ri(self: &mut Self, op: u32, sz: u32, dst: u8, k: i32) {
        self.osize(sz);
        // The accumulator has forms without ModRM (`op` * 8 + 4 and + 5).
        if sz == 1 {
            if dst == RAX {
                self.byte(op * 8 + 4);
            } else {
                self.rr(0, 0x80, false, op as u8, dst, true);
            }
            self.byte(k as u32);
            return;
        }
        if k >= -128 && k < 128 {
            self.rr(0, 0x83, sz == 8, op as u8, dst, false);
            self.byte(k as u32);
            return;
        }
        if dst == RAX {
            if sz == 8 {
                self.byte(0x48);
            }
            self.byte(op * 8 + 5);
        } else {
            self.rr(0, 0x81, sz == 8, op as u8, dst, false);
        }
        if sz == 2 {
            self.byte(k as u32);
            self.byte(k as u32 >> 8);
        } else {
            self.d32(k as u32);
        }
    }

    /// `[m]` op= `k` (`CMP` compares).
    pub fn alu_mi(self: &mut Self, op: u32, sz: u32, m: Mem, k: i32) {
        self.osize(sz);
        if sz == 1 {
            self.rm(0, 0x80, false, op as u8, m, false);
            self.byte(k as u32);
            return;
        }
        if k >= -128 && k < 128 {
            self.rm(0, 0x83, sz == 8, op as u8, m, false);
            self.byte(k as u32);
            return;
        }
        self.rm(0, 0x81, sz == 8, op as u8, m, false);
        self.d32(k as u32);
    }

    /// The flags of `a` & `b`.
    pub fn test_rr(self: &mut Self, sz: u32, a: u8, b: u8) {
        self.osize(sz);
        self.rr_both(
            if sz == 1 {
                0x84u32;
            } else {
                0x85u32;
            },
            sz,
            b,
            a,
        );
    }

    /// The flags of `a` & `k` (`sz` 1: the low byte against 8 bits).
    pub fn test_ri(self: &mut Self, sz: u32, a: u8, k: u32) {
        // The accumulator has forms without ModRM (A8, A9).
        if sz == 1 {
            if a == RAX {
                self.byte(0xA8);
            } else {
                self.rr(0, 0xF6, false, 0, a, true);
            }
            self.byte(k);
            return;
        }
        if a == RAX {
            if sz == 8 {
                self.byte(0x48);
            }
            self.byte(0xA9);
        } else {
            self.rr(0, 0xF7, sz == 8, 0, a, false);
        }
        self.d32(k);
    }

    /// An `F7` group operation on `r` (`NOT`, `NEG`, `MUL`, `IMUL1`, `DIV`, `IDIV`).
    pub fn unary(self: &mut Self, op: u32, sz: u32, r: u8) {
        self.osize(sz);
        self.rr(
            0,
            if sz == 1 {
                0xF6u32;
            } else {
                0xF7u32;
            },
            sz == 8,
            op as u8,
            r,
            sz == 1,
        );
    }

    /// `dst` = `dst` * `src` (the low `sz` bytes; sz 4 or 8).
    pub fn imul_rr(self: &mut Self, sz: u32, dst: u8, src: u8) {
        self.osize(sz);
        self.rr(0, 0x0FAF, sz == 8, dst, src, false);
    }

    /// `dst` = `src` * `k`.
    pub fn imul_ri(self: &mut Self, sz: u32, dst: u8, src: u8, k: i32) {
        if k >= -128 && k < 128 {
            self.rr(0, 0x6B, sz == 8, dst, src, false);
            self.byte(k as u32);
            return;
        }
        self.rr(0, 0x69, sz == 8, dst, src, false);
        self.d32(k as u32);
    }

    /// Shift `r` by cl (`SHL`, `SHR`, `SAR`, `ROL`, `ROR`).
    pub fn shift_cl(self: &mut Self, op: u32, sz: u32, r: u8) {
        self.osize(sz);
        self.rr(
            0,
            if sz == 1 {
                0xD2u32;
            } else {
                0xD3u32;
            },
            sz == 8,
            op as u8,
            r,
            sz == 1,
        );
    }

    /// Shift `r` by `k` (below the width).
    pub fn shift_ri(self: &mut Self, op: u32, sz: u32, r: u8, k: u32) {
        self.osize(sz);
        // A shift by 1 has a form without the immediate.
        let one: u32 = if k == 1 {
            0x10;
        } else {
            0;
        };
        self.rr(
            0,
            if sz == 1 {
                0xC0u32 + one;
            } else {
                0xC1u32 + one;
            },
            sz == 8,
            op as u8,
            r,
            sz == 1,
        );
        if k != 1 {
            self.byte(k);
        }
    }

    /// shld (`left`) or shrd `dst`, `src`, cl: 64 bits.
    pub fn shd_cl(self: &mut Self, left: bool, dst: u8, src: u8) {
        self.rr(
            0,
            if left {
                0x0FA5u32;
            } else {
                0x0FADu32;
            },
            true,
            src,
            dst,
            false,
        );
    }

    /// rdx:rax = sign extension of rax (`sz` 8: cqo; 4: cdq).
    pub fn cqo(self: &mut Self, sz: u32) {
        if sz == 8 {
            self.byte(0x48);
        }
        self.byte(0x99);
    }

    /// `dst`'s low byte = condition `cc` (the rest kept).
    pub fn setcc(self: &mut Self, cc: u32, dst: u8) {
        self.rr(0, 0x0F90 + cc, false, 0, dst, true);
    }

    /// `dst` = `src` when condition `cc` holds.
    pub fn cmov(self: &mut Self, cc: u32, sz: u32, dst: u8, src: u8) {
        self.rr(0, 0x0F40 + cc, sz == 8, dst, src, false);
    }

    /// bsr (`rev`) or bsf `dst`, `src`: the index of the highest (lowest) set bit; ZF when `src` is 0.
    pub fn bsx(self: &mut Self, rev: bool, sz: u32, dst: u8, src: u8) {
        self.rr(
            0,
            if rev {
                0x0FBDu32;
            } else {
                0x0FBCu32;
            },
            sz == 8,
            dst,
            src,
            false,
        );
    }

    /// CF = bit `k` (below 64) of `r`.
    pub fn bt_ri(self: &mut Self, r: u8, k: u32) {
        self.rr(0, 0x0FBA, true, 4, r, false);
        self.byte(k);
    }

    /// Reverse the bytes of `r` (4 or 8 bytes).
    pub fn bswap(self: &mut Self, sz: u32, r: u8) {
        self.rex_rr(sz == 8, 0, r, false, false);
        self.byte(0x0F);
        self.byte(0xC8 + (r as u32 & 7));
    }

    /// xchg `r`, `[m]` (locked).
    pub fn xchg_m(self: &mut Self, sz: u32, r: u8, m: Mem) {
        self.osize(sz);
        self.rm(
            0,
            if sz == 1 {
                0x86u32;
            } else {
                0x87u32;
            },
            sz == 8,
            r,
            m,
            sz == 1,
        );
    }

    /// lock xadd `[m]`, `r`.
    pub fn lock_xadd(self: &mut Self, sz: u32, r: u8, m: Mem) {
        self.osize(sz);
        self.byte(0xF0);
        self.rm(
            0,
            if sz == 1 {
                0x0FC0u32;
            } else {
                0x0FC1u32;
            },
            sz == 8,
            r,
            m,
            sz == 1,
        );
    }

    /// lock cmpxchg `[m]`, `r` (compares with rax).
    pub fn lock_cmpxchg(self: &mut Self, sz: u32, r: u8, m: Mem) {
        self.osize(sz);
        self.byte(0xF0);
        self.rm(
            0,
            if sz == 1 {
                0x0FB0u32;
            } else {
                0x0FB1u32;
            },
            sz == 8,
            r,
            m,
            sz == 1,
        );
    }

    pub fn mfence(self: &mut Self) {
        self.byte(0x0F);
        self.byte(0xAE);
        self.byte(0xF0);
    }

    pub fn ud2(self: &mut Self) {
        self.byte(0x0F);
        self.byte(0x0B);
    }

    // ---- Control flow ----

    /// A jump of condition `cc` with a 32-bit displacement; the field's position.
    pub fn jcc32(self: &mut Self, cc: u32) u32 {
        self.byte(0x0F);
        self.byte(0x80 + cc);
        let at = self.len();
        self.jumps.push(at);
        self.d32(0);
        return at;
    }

    /// A jump of condition `cc` to code position `to` (before it): 2 bytes when it reaches.
    pub fn jcc_back(self: &mut Self, cc: u32, to: u32) {
        let d = to as i64 - (self.len() as i64 + 2);
        if d >= -128 {
            self.byte(0x70 + cc);
            self.byte(d as u32);
            return;
        }
        let at = self.jcc32(cc);
        self.patch32(at, (to as i64 - (at as i64 + 4)) as u32);
    }

    /// A jump with a 32-bit displacement; the field's position.
    pub fn jmp32(self: &mut Self) u32 {
        self.byte(0xE9);
        let at = self.len();
        self.jumps.push(at);
        self.d32(0);
        return at;
    }

    /// Point the 32-bit displacement field at `at` to code position `to`.
    pub const fn land(self: &mut Self, at: u32, to: u32) {
        self.patch32(at, (to as i64 - (at as i64 + 4)) as u32);
    }

    /// A call with a 32-bit displacement (for a relocation); the field's position.
    pub fn call32(self: &mut Self) u32 {
        self.byte(0xE8);
        let at = self.len();
        self.d32(0);
        return at;
    }

    /// A call of the address in `r`.
    pub fn call_r(self: &mut Self, r: u8) {
        self.rr(0, 0xFF, false, 2, r, false);
    }

    pub fn ret(self: &mut Self) {
        self.byte(0xC3);
    }

    pub fn push(self: &mut Self, r: u8) {
        if r >= 8 {
            self.byte(0x41);
        }
        self.byte(0x50 + (r as u32 & 7));
    }

    pub fn pop(self: &mut Self, r: u8) {
        if r >= 8 {
            self.byte(0x41);
        }
        self.byte(0x58 + (r as u32 & 7));
    }

    // ---- SSE ----

    /// An SSE operation `dst` = `dst` op `src` of mandatory prefix `pfx` (0x66, 0xF2, 0xF3 or 0) and
    /// opcode `op` (`0F xx`).
    pub fn sse_rr(self: &mut Self, pfx: u32, op: u32, dst: u8, src: u8) {
        self.rr(pfx, op, false, dst, src, false);
    }

    /// Load `n` bytes (4, 8 or 16) at `m` into xmm `dst` (the bytes above zeroed).
    pub fn vload(self: &mut Self, n: u32, dst: u8, m: Mem) {
        if n == 4 {
            self.rm(0xF3, 0x0F10, false, dst, m, false);
        } else if n == 8 {
            self.rm(0xF3, 0x0F7E, false, dst, m, false);
        } else {
            self.rm(0xF3, 0x0F6F, false, dst, m, false);
        }
    }

    /// Store the low `n` bytes (4, 8 or 16) of xmm `src` to `m`.
    pub fn vstore(self: &mut Self, n: u32, src: u8, m: Mem) {
        if n == 4 {
            self.rm(0xF3, 0x0F11, false, src, m, false);
        } else if n == 8 {
            self.rm(0x66, 0x0FD6, false, src, m, false);
        } else {
            self.rm(0xF3, 0x0F7F, false, src, m, false);
        }
    }

    /// xmm `dst` = xmm `src` (all 16 bytes).
    pub fn vmov(self: &mut Self, dst: u8, src: u8) {
        if dst != src {
            self.rr(0, 0x0F28, false, dst, src, false);
        }
    }

    /// xmm `dst` = the low `sz` bytes (4 or 8) of `src`, the rest zeroed.
    pub fn movd_to_x(self: &mut Self, sz: u32, dst: u8, src: u8) {
        self.rr(0x66, 0x0F6E, sz == 8, dst, src, false);
    }

    /// `dst` = the low `sz` bytes (4 or 8) of xmm `src`.
    pub fn movd_from_x(self: &mut Self, sz: u32, dst: u8, src: u8) {
        self.rr(0x66, 0x0F7E, sz == 8, src, dst, false);
    }

    /// cvtsi2ss or cvtsi2sd (`d`) xmm `dst` = the signed `sz`-byte (4 or 8) integer in `src`.
    pub fn cvtsi2f(self: &mut Self, d: bool, sz: u32, dst: u8, src: u8) {
        self.rr(
            if d {
                0xF2u32;
            } else {
                0xF3u32;
            },
            0x0F2A,
            sz == 8,
            dst,
            src,
            false,
        );
    }

    /// cvttss2si or cvttsd2si (`d`): `dst` = xmm `src` truncated to a signed `sz`-byte integer
    /// (0x80..0 when out of range or NaN).
    pub fn cvtf2si(self: &mut Self, d: bool, sz: u32, dst: u8, src: u8) {
        self.rr(
            if d {
                0xF2u32;
            } else {
                0xF3u32;
            },
            0x0F2C,
            sz == 8,
            dst,
            src,
            false,
        );
    }

    // ---- Wide vector moves (the AVX forms the C ABI needs) ----

    /// vmovdqu of 32 bytes (VEX.256): ymm `r` from (`load`) or to `m`.
    pub fn ymov(self: &mut Self, load: bool, r: u8, m: Mem) {
        // Map 0F, prefix F3, L = 1: the two-byte form unless the index or the base needs its REX bit.
        let rb = (~(r as u32) >> 3 & 1) << 7;
        let xb = if m.index != NOREG {
            (~(m.index as u32) >> 3 & 1) << 6;
        } else {
            1u32 << 6;
        };
        let bb = if m.base != RIP && m.base != NOREG {
            (~(m.base as u32) >> 3 & 1) << 5;
        } else {
            1u32 << 5;
        };
        if (xb | bb) == 0x60 {
            self.byte(0xC5);
            self.byte(rb | 0x78 | 4 | 2);
        } else {
            self.byte(0xC4);
            self.byte(rb | xb | bb | 1);
            self.byte(0x78 | 4 | 2);
        }
        self.byte(
            if load {
                0x6Fu32;
            } else {
                0x7Fu32;
            },
        );
        self.modrm_m(r, m);
    }

    /// vmovdqu64 of 64 bytes (EVEX.512): zmm `r` from (`load`) or to `m`. Its 8-bit displacement counts
    /// in 64-byte units.
    pub fn zmov(self: &mut Self, load: bool, r: u8, m: Mem) {
        let rr = (~(r as u32) >> 3 & 1) << 7;
        let xx = if m.index != NOREG {
            (~(m.index as u32) >> 3 & 1) << 6;
        } else {
            1u32 << 6;
        };
        let bb = if m.base != RIP && m.base != NOREG {
            (~(m.base as u32) >> 3 & 1) << 5;
        } else {
            1u32 << 5;
        };
        self.byte(0x62);
        // P0: R X B R' 0 0 m m (map 0F); R' set (inverted) for registers below 16.
        self.byte(rr | xx | bb | 1u32 << 4 | 1);
        // P1: W vvvv 1 pp (W1, vvvv unused, pp = F3).
        self.byte(0x80 | 0x78 | 4 | 2);
        // P2: z L'L b V' aaa (512 bits, V' set).
        self.byte(2u32 << 5 | 1u32 << 3);
        self.byte(
            if load {
                0x6Fu32;
            } else {
                0x7Fu32;
            },
        );
        self.modrm_n(r, m, 64);
    }
}

// The little-endian 32 bits of `b` at `at`.
const fn read32(b: &Vector<u8>, at: u32) u32 {
    let i = at as usize;
    return b[i] as u32 | b[i + 1] as u32 << 8 | b[i + 2] as u32 << 16 | b[i + 3] as u32 << 24;
}

// Code position `x` after `relax` shortens the jumps whose first bytes `op` (ascending) lie before it, by
// `cut` (`cut[k]`: the bytes the jumps before jump k save).
const fn moved(op: &Vector<u32>, cut: &Vector<u32>, x: u32) u32 {
    // The jumps before `x`: the first index whose first byte is at or past it.
    let mut lo: usize = 0;
    let mut hi = op.len();
    while lo < hi {
        let mid = (lo + hi) / 2;
        if op[mid] < x {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return x - cut[lo];
}
