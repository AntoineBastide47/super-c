// The x86-64 instruction encoder: one function per instruction form, each appending its bytes to a code
// buffer. Registers are numbers: rax 0, rcx 1, rdx 2, rbx 3, rsp 4, rbp 5, rsi 6, rdi 7, r8..r15 8..15;
// xmm0..xmm15 are 0..15 in the vector forms. `sz` is an operand size in bytes: 1, 2, 4 or 8. A memory
// operand is a base register (or RIP), an optional index scaled by 1, 2, 4 or 8, and a 32-bit
// displacement; a RIP-relative one leaves its displacement for a relocation (`Mem::rip`, `RIP_AT`).

/// Relocation kinds (`codegen::obj::ORel.kind`): a 32-bit PC-relative field (its addend counts from the
/// field: -4 and less), a call through the PLT, the address slot of a symbol in the GOT (relaxable), the
/// thread-local general-dynamic descriptor, a 64-bit absolute address, (COFF) a 32-bit offset from
/// the start of the target's section (a thread-local's offset in the thread's block), and (ELF) a
/// thread-local's 32-bit offset from the thread pointer (local-exec).
pub(package) const R_PC32: u8 = 1;
pub(package) const R_PLT32: u8 = 2;
pub(package) const R_GOTPCRELX: u8 = 3;
pub(package) const R_REX_GOTPCRELX: u8 = 4;
pub(package) const R_TLSGD: u8 = 5;
pub(package) const R_ABS64: u8 = 6;
pub(package) const R_SECREL: u8 = 7;
pub(package) const R_TPOFF32: u8 = 8;

pub(package) const RAX: u8 = 0;
pub(package) const RCX: u8 = 1;
pub(package) const RDX: u8 = 2;
pub(package) const RBX: u8 = 3;
pub(package) const RSP: u8 = 4;
pub(package) const RBP: u8 = 5;
pub(package) const RSI: u8 = 6;
pub(package) const RDI: u8 = 7;
pub(package) const R8: u8 = 8;
pub(package) const R9: u8 = 9;
pub(package) const R10: u8 = 10;
pub(package) const R11: u8 = 11;
pub(package) const R12: u8 = 12;
pub(package) const R13: u8 = 13;

/// No register (a memory operand without an index), and the RIP base.
pub(package) const NOREG: u8 = 0xFF;
pub(package) const RIP: u8 = 0xFE;
/// The incoming frame as a base: rsp plus a distance the frame's size gives once known. Its operands encode
/// as rsp + a 32-bit displacement, whose positions `Code.in_at` lists for `Code::rebase`.
pub(package) const IN: u8 = 0xF4;

// Condition codes (the low nibble of Jcc, SETcc, CMOVcc).
pub(package) const CC_O: u32 = 0;
pub(package) const CC_NO: u32 = 1;
pub(package) const CC_B: u32 = 2; // below (CF)
pub(package) const CC_AE: u32 = 3;
pub(package) const CC_E: u32 = 4;
pub(package) const CC_NE: u32 = 5;
pub(package) const CC_BE: u32 = 6;
pub(package) const CC_A: u32 = 7;
pub(package) const CC_S: u32 = 8;
pub(package) const CC_NS: u32 = 9;
pub(package) const CC_P: u32 = 10;
pub(package) const CC_NP: u32 = 11;
pub(package) const CC_L: u32 = 12;
pub(package) const CC_GE: u32 = 13;
pub(package) const CC_LE: u32 = 14;
pub(package) const CC_G: u32 = 15;

/// The opposite condition.
pub(package) const fn invert(cc: u32) u32 {
    return cc ^ 1;
}

// ALU operations of the `00..3F` group: the ModRM reg field of `81 /n` and `83 /n`.
pub(package) const ADD: u32 = 0;
pub(package) const OR: u32 = 1;
pub(package) const ADC: u32 = 2;
pub(package) const SBB: u32 = 3;
pub(package) const AND: u32 = 4;
pub(package) const SUB: u32 = 5;
pub(package) const XOR: u32 = 6;
pub(package) const CMP: u32 = 7;

// The `F7` group: the ModRM reg field.
pub(package) const NOT: u32 = 2;
pub(package) const NEG: u32 = 3;
pub(package) const MUL: u32 = 4;
pub(package) const IMUL1: u32 = 5;
pub(package) const DIV: u32 = 6;
pub(package) const IDIV: u32 = 7;

// Shifts: the ModRM reg field of `C1`, `D3`.
pub(package) const ROL: u32 = 0;
pub(package) const ROR: u32 = 1;
pub(package) const SHL: u32 = 4;
pub(package) const SHR: u32 = 5;
pub(package) const SAR: u32 = 7;

/// A memory operand: `base` + `index` << `scale` + `disp`; `base` RIP for a RIP-relative one.
pub(package) struct Mem {
    pub(package) base: u8,
    pub(package) index: u8,
    pub(package) scale: u8,
    pub(package) disp: i32,
}

extend Mem as Copy {}

/// `base` + `disp`.
pub(package) const fn at(base: u8, disp: i32) Mem {
    return Mem { base: base, index: NOREG, scale: 0, disp: disp };
}

/// `base` + `index` << `scale` + `disp`.
pub(package) const fn ix(base: u8, index: u8, scale: u8, disp: i32) Mem {
    return Mem { base: base, index: index, scale: scale, disp: disp };
}

/// RIP-relative, its displacement 0 for a relocation.
pub(package) const fn rip() Mem {
    return Mem { base: RIP, index: NOREG, scale: 0, disp: 0 };
}

/// The code position of the displacement of the last RIP-relative operand an encoder wrote: the
/// caller's relocation goes there. Set by every form that takes a `Mem`. `jumps`: the positions of the
/// 32-bit displacements of the jumps, ascending, for `relax`; `longs`: those of the jumps `relax` keeps
/// long (a table's entries), ascending; `in_at`: the positions of the displacements of
/// the operands based on `IN`; `stack_at`: the first position in an instruction that uses the stack (a
/// memory operand based on rsp, rbp or `IN`, a push, a pop, a call), 0xFFFFFFFF before
/// one.
pub(package) struct Code {
    pub(package) b: Vector<u8>,
    pub(package) rip_at: u32,
    pub(package) jumps: Vector<u32>,
    pub(package) longs: Vector<u32>,
    pub(package) in_at: Vector<u32>,
    pub(package) stack_at: u32,
}

extend Code {
    pub(package) fn new() Code {
        return Code {
            b: Vector::<u8>::new(),
            rip_at: 0,
            jumps: Vector::<u32>::new(),
            longs: Vector::<u32>::new(),
            in_at: Vector::<u32>::new(),
            stack_at: 0xFFFFFFFF,
        };
    }

    /// Empty the code for the next function.
    pub(package) fn clear(self: &mut Self) {
        self.b.truncate(0);
        self.jumps.truncate(0);
        self.longs.truncate(0);
        self.in_at.truncate(0);
        self.stack_at = 0xFFFFFFFF;
    }

    // An instruction that uses the stack is being written (`stack_at`).
    const fn stack_use(self: &mut Self) {
        if self.stack_at == 0xFFFFFFFF {
            self.stack_at = self.len();
        }
    }

    /// Add `d` to the displacement of every operand based on `IN`: the distance from rsp to the incoming
    /// frame, once the frame's size is known.
    pub(package) fn rebase(self: &mut Self, d: i32) {
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

    /// Give every jump whose target an 8-bit displacement reaches its 2-byte form (but `longs`), every target and the
    /// positions `at` (none inside a jump) moved with the code. A shorter jump never lengthens another's
    /// distance, so the passes stop once one shortens none: at most one pass per jump, plus one. Each of
    /// the positions `heads` (ascending, none inside a jump) then starts at a 16-byte boundary of the
    /// function, whose code is `lead` bytes in, behind no-ops: a jump is short only when its displacement
    /// fits with 15 bytes of them before each such position it spans.
    pub(package) fn relax(self: &mut Self, at: &mut Vector<u32>, heads: &Vector<u32>, lead: u32) {
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
        // The jumps kept long: both lists ascend.
        let mut long = Vector::<bool>::new();
        long.resize_default(nj);
        let mut l: usize = 0;
        for k in 0..nj {
            while l < self.longs.len() && self.longs[l] < self.jumps[k] {
                l += 1;
            }
            long[k] = l < self.longs.len() && self.longs[l] == self.jumps[k];
        }
        let mut cut = Vector::<u32>::new();
        cut.resize_default(nj + 1);
        for _ in 0..nj + 1 {
            for k in 0..nj {
                cut[k + 1] = cut[k] + if short[k] {
                    save[k]
                } else {
                    0
                };
            }
            let mut changed = false;
            for k in 0..nj {
                if short[k] || long[k] {
                    continue;
                }
                let d = moved(&op, &cut, to[k]) as i64 - (moved(&op, &cut, op[k]) as i64 + 2);
                // The heads in (lo, hi]: no-ops before one move the jump and its target apart.
                let (lo, hi) = if to[k] > op[k] {
                    (op[k], to[k])
                } else {
                    (to[k], op[k])
                };
                let pad = 15 * (heads_upto(heads, hi + 1) - heads_upto(heads, lo + 1)) as i64;
                if d - pad >= -128 && d + pad <= 127 {
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
                save[k]
            } else {
                0
            };
        }
        // Each head's no-ops (`pads`), in order, from its position past the shorter jumps and the no-ops
        // before it; `pad_at[h]`: the no-ops of the heads before head h.
        let nh = heads.len();
        let mut pad_at = Vector::<u32>::with_capacity(nh + 1);
        pad_at.push(0);
        for h in 0..nh {
            let p = lead + moved(&op, &cut, heads[h]) + pad_at[h];
            pad_at.push(pad_at[h] + (16 - p % 16) % 16);
        }
        let mut nb = Vector::<u8>::with_capacity(self.b.len() - cut[nj] as usize + pad_at[nh] as usize);
        let mut from: u32 = 0;
        let mut h: usize = 0;
        for k in 0..nj {
            for q in from..op[k] {
                while h < nh && heads[h] == q {
                    nops(&mut nb, pad_at[h + 1] - pad_at[h]);
                    h += 1;
                }
                nb.push(self.b[q as usize]);
            }
            while h < nh && heads[h] == op[k] {
                nops(&mut nb, pad_at[h + 1] - pad_at[h]);
                h += 1;
            }
            let jcc = save[k] == 4;
            let cc = if jcc {
                self.b[op[k] as usize + 1] as u32 & 15
            } else {
                0
            };
            let here = nb.len() as i64;
            let tgt = placed(&op, &cut, heads, &pad_at, to[k]) as i64;
            if short[k] {
                nb.push(
                    if jcc {
                        (0x70 + cc) as u8
                    } else {
                        0xEB
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
            while h < nh && heads[h] == q {
                nops(&mut nb, pad_at[h + 1] - pad_at[h]);
                h += 1;
            }
            nb.push(self.b[q as usize]);
        }
        for k in 0..at.len() {
            at[k] = placed(&op, &cut, heads, &pad_at, at[k]);
        }
        self.b = nb;
        self.jumps.truncate(0);
        self.longs.truncate(0);
    }

    pub(package) const fn len(self: &Self) u32 {
        return self.b.len() as u32;
    }

    pub(package) fn byte(self: &mut Self, x: u32) {
        self.b.push((x & 0xFF) as u8);
    }

    pub(package) fn d32(self: &mut Self, x: u32) {
        self.byte(x);
        self.byte(x >> 8);
        self.byte(x >> 16);
        self.byte(x >> 24);
    }

    pub(package) fn d64(self: &mut Self, x: u64) {
        self.d32(x as u32);
        self.d32((x >> 32) as u32);
    }

    /// Overwrite the 32-bit field at `at` with `x`.
    pub(package) const fn patch32(self: &mut Self, at: u32, x: u32) {
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
            m.index as u32 >> 3 & 1
        } else {
            0u32
        };
        let b = if m.base != RIP && m.base != NOREG {
            m.base as u32 >> 3 & 1
        } else {
            0u32
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
        if m.base == RSP || m.base == RBP || m.base == IN {
            self.stack_use();
        }
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
                4u32
            } else {
                m.index as u32 & 7
            };
            self.byte(2 << 6 | rg | 4);
            self.byte(m.scale as u32 << 6 | idx << 3 | 4);
            self.in_at.push(self.len());
            self.d32(m.disp as u32);
            return;
        }
        if m.base == NOREG {
            // No base: a SIB byte with base 101 under mod 00, then a 32-bit displacement.
            self.byte(rg | 4);
            self.byte(m.scale as u32 << 6 | (m.index as u32 & 7) << 3 | 5);
            self.d32(m.disp as u32);
            return;
        }
        let base = m.base as u32 & 7;
        let d8 = m.disp % n8 == 0 && m.disp / n8 >= -128 && m.disp / n8 < 128;
        // rbp and r13 as a base take a displacement even when it is 0.
        let md: u32 = if m.disp == 0 && base != 5 {
            0
        } else if d8 {
            1
        } else {
            2
        };
        if m.index == NOREG && base != 4 {
            self.byte(md << 6 | rg | base);
        } else {
            // A SIB byte: an index, or rsp and r12 as a base (index 100: none).
            let idx = if m.index == NOREG {
                4u32
            } else {
                m.index as u32 & 7
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
    /// is a byte register (`reg` is an opcode digit or a wider register). An SSE operation on xmm16..xmm31
    /// takes its EVEX form (`sse_evex`).
    pub(package) fn rr(self: &mut Self, pfx: u32, op: u32, w: bool, reg: u8, rm: u8, byte: bool) {
        if (reg | rm) >= 16 {
            self.sse_evex(pfx, op, w, reg, rm, rip(), false);
            return;
        }
        if pfx != 0 {
            self.byte(pfx);
        }
        self.rex_rr(w, reg, rm, false, byte);
        self.opc(op);
        self.modrm_rr(reg, rm);
    }

    /// `op reg, [m]` with mandatory prefix `pfx` and REX.W `w`.
    pub(package) fn rm(self: &mut Self, pfx: u32, op: u32, w: bool, reg: u8, m: Mem, byte: bool) {
        if reg >= 16 {
            self.sse_evex(pfx, op, w, reg, 0, m, true);
            return;
        }
        if op == 0xFF && reg == 2 {
            self.stack_use();
        }
        if pfx != 0 {
            self.byte(pfx);
        }
        self.rex_m(w, reg, m, byte);
        self.opc(op);
        self.modrm_m(reg, m);
    }

    // ---- Moves ----

    /// `dst` = `src` (`sz` 4 zero-extends, 8 copies all).
    pub(package) fn mov_rr(self: &mut Self, sz: u32, dst: u8, src: u8) {
        self.rr(0, 0x89, sz == 8, src, dst, false);
    }

    /// `dst` = `v`: a 32-bit immediate zero-extends, a negative 32-bit one sign-extends, else 10 bytes.
    pub(package) fn mov_ri(self: &mut Self, dst: u8, v: u64) {
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
    pub(package) fn load(self: &mut Self, sz: u32, sx: bool, dst: u8, m: Mem) {
        if sz == 1 {
            self.rm(
                0,
                if sx {
                    0x0FBE
                } else {
                    0x0FB6
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
                    0x0FBF
                } else {
                    0x0FB7
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
    pub(package) fn store(self: &mut Self, sz: u32, src: u8, m: Mem) {
        self.osize(sz);
        self.rm(
            0,
            if sz == 1 {
                0x88u32
            } else {
                0x89u32
            },
            sz == 8,
            src,
            m,
            sz == 1,
        );
    }

    /// `sz` bytes of immediate `v` (sign-extended from 32 bits for 8) to `m`.
    pub(package) fn store_i(self: &mut Self, sz: u32, v: i32, m: Mem) {
        self.osize(sz);
        self.rm(
            0,
            if sz == 1 {
                0xC6u32
            } else {
                0xC7u32
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
    pub(package) fn lea(self: &mut Self, dst: u8, m: Mem) {
        self.rm(0, 0x8D, true, dst, m, false);
    }

    /// `dst` = `src`'s low `from` bytes (1, 2 or 4) extended to `to` bytes (4 or 8), signed `sx`.
    pub(package) fn ext(self: &mut Self, from: u32, to: u32, sx: bool, dst: u8, src: u8) {
        if from == 4 {
            if sx {
                self.rr(0, 0x63, true, dst, src, false);
            } else {
                self.mov_rr(4, dst, src);
            }
            return;
        }
        let op = if from == 1 && sx {
            0x0FBEu32
        } else if from == 1 {
            0x0FB6u32
        } else if sx {
            0x0FBFu32
        } else {
            0x0FB7u32
        };
        self.rr(0, op, sx && to == 8, dst, src, from == 1);
    }

    // ---- Integer operations ----

    /// `dst` = `dst` op `src` (`ADD` .. `CMP`).
    pub(package) fn alu_rr(self: &mut Self, op: u32, sz: u32, dst: u8, src: u8) {
        self.osize(sz);
        self.rr_both(
            (op << 3) + if sz == 1 {
                0u32
            } else {
                1u32
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
    pub(package) fn alu_rm(self: &mut Self, op: u32, sz: u32, dst: u8, m: Mem) {
        self.osize(sz);
        self.rm(
            0,
            (op << 3) + if sz == 1 {
                2u32
            } else {
                3u32
            },
            sz == 8,
            dst,
            m,
            sz == 1,
        );
    }

    /// `dst` = `dst` op `k` (a sign-extended 32-bit immediate; 8 bits when it fits).
    pub(package) fn alu_ri(self: &mut Self, op: u32, sz: u32, dst: u8, k: i32) {
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

    /// `[m]` = `k`, `sz` bytes (a 32-bit immediate sign-extended to 8 bytes).
    pub(package) fn mov_mi(self: &mut Self, sz: u32, m: Mem, k: i32) {
        self.osize(sz);
        if sz == 1 {
            self.rm(0, 0xC6, false, 0, m, false);
            self.byte(k as u32);
            return;
        }
        self.rm(0, 0xC7, sz == 8, 0, m, false);
        if sz == 2 {
            self.byte(k as u32);
            self.byte(k as u32 >> 8);
        } else {
            self.d32(k as u32);
        }
    }

    /// `[m]` op= `src`.
    pub(package) fn alu_mr(self: &mut Self, op: u32, sz: u32, m: Mem, src: u8) {
        self.osize(sz);
        self.rm(
            0,
            (op << 3) + if sz == 1 {
                0u32
            } else {
                1u32
            },
            sz == 8,
            src,
            m,
            sz == 1,
        );
    }

    /// `[m]` op= `k` (`CMP` compares).
    pub(package) fn alu_mi(self: &mut Self, op: u32, sz: u32, m: Mem, k: i32) {
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
        if sz == 2 {
            self.byte(k as u32);
            self.byte(k as u32 >> 8);
        } else {
            self.d32(k as u32);
        }
    }

    /// The flags of `a` & `b`.
    pub(package) fn test_rr(self: &mut Self, sz: u32, a: u8, b: u8) {
        self.osize(sz);
        self.rr_both(
            if sz == 1 {
                0x84u32
            } else {
                0x85u32
            },
            sz,
            b,
            a,
        );
    }

    /// The flags of `a` & `k` (`sz` 1: the low byte against 8 bits).
    pub(package) fn test_ri(self: &mut Self, sz: u32, a: u8, k: u32) {
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
    pub(package) fn unary(self: &mut Self, op: u32, sz: u32, r: u8) {
        self.osize(sz);
        self.rr(
            0,
            if sz == 1 {
                0xF6u32
            } else {
                0xF7u32
            },
            sz == 8,
            op as u8,
            r,
            sz == 1,
        );
    }

    /// `dst` = `dst` * `src` (the low `sz` bytes; sz 4 or 8).
    /// `dst` = `dst` << `k` | `src` >> (width - `k`) (SHLD by an immediate).
    pub(package) fn shld_ri(self: &mut Self, sz: u32, dst: u8, src: u8, k: u32) {
        self.osize(sz);
        self.rr(0, 0x0FA4, sz == 8, src, dst, false);
        self.byte(k);
    }

    pub(package) fn imul_rr(self: &mut Self, sz: u32, dst: u8, src: u8) {
        self.osize(sz);
        self.rr(0, 0x0FAF, sz == 8, dst, src, false);
    }

    /// `dst` = `dst` * the memory at `m`.
    pub(package) fn imul_rm(self: &mut Self, sz: u32, dst: u8, m: Mem) {
        self.osize(sz);
        self.rm(0, 0x0FAF, sz == 8, dst, m, false);
    }

    /// `dst` = `src` * `k`.
    pub(package) fn imul_ri(self: &mut Self, sz: u32, dst: u8, src: u8, k: i32) {
        if k >= -128 && k < 128 {
            self.rr(0, 0x6B, sz == 8, dst, src, false);
            self.byte(k as u32);
            return;
        }
        self.rr(0, 0x69, sz == 8, dst, src, false);
        self.d32(k as u32);
    }

    /// Shift `r` by cl (`SHL`, `SHR`, `SAR`, `ROL`, `ROR`).
    pub(package) fn shift_cl(self: &mut Self, op: u32, sz: u32, r: u8) {
        self.osize(sz);
        self.rr(
            0,
            if sz == 1 {
                0xD2u32
            } else {
                0xD3u32
            },
            sz == 8,
            op as u8,
            r,
            sz == 1,
        );
    }

    /// Shift `r` by `k` (below the width).
    pub(package) fn shift_ri(self: &mut Self, op: u32, sz: u32, r: u8, k: u32) {
        self.osize(sz);
        // A shift by 1 has a form without the immediate.
        let one: u32 = if k == 1 {
            0x10
        } else {
            0
        };
        self.rr(
            0,
            if sz == 1 {
                0xC0u32 + one
            } else {
                0xC1u32 + one
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
    pub(package) fn shd_cl(self: &mut Self, left: bool, dst: u8, src: u8) {
        self.rr(
            0,
            if left {
                0x0FA5u32
            } else {
                0x0FADu32
            },
            true,
            src,
            dst,
            false,
        );
    }

    /// rdx:rax = sign extension of rax (`sz` 8: cqo; 4: cdq).
    pub(package) fn cqo(self: &mut Self, sz: u32) {
        if sz == 8 {
            self.byte(0x48);
        }
        self.byte(0x99);
    }

    /// `dst`'s low byte = condition `cc` (the rest kept).
    pub(package) fn setcc(self: &mut Self, cc: u32, dst: u8) {
        self.rr(0, 0x0F90 + cc, false, 0, dst, true);
    }

    /// `dst` = `src` when condition `cc` holds.
    pub(package) fn cmov(self: &mut Self, cc: u32, sz: u32, dst: u8, src: u8) {
        self.rr(0, 0x0F40 + cc, sz == 8, dst, src, false);
    }

    /// bsr (`rev`) or bsf `dst`, `src`: the index of the highest (lowest) set bit; ZF when `src` is 0.
    pub(package) fn bsx(self: &mut Self, rev: bool, sz: u32, dst: u8, src: u8) {
        self.rr(
            0,
            if rev {
                0x0FBDu32
            } else {
                0x0FBCu32
            },
            sz == 8,
            dst,
            src,
            false,
        );
    }

    /// CF = bit `k` (below 64) of `r`.
    pub(package) fn bt_ri(self: &mut Self, r: u8, k: u32) {
        self.rr(0, 0x0FBA, true, 4, r, false);
        self.byte(k);
    }

    /// Reverse the bytes of `r` (4 or 8 bytes).
    pub(package) fn bswap(self: &mut Self, sz: u32, r: u8) {
        self.rex_rr(sz == 8, 0, r, false, false);
        self.byte(0x0F);
        self.byte(0xC8 + (r as u32 & 7));
    }

    /// xchg `r`, `[m]` (locked).
    pub(package) fn xchg_m(self: &mut Self, sz: u32, r: u8, m: Mem) {
        self.osize(sz);
        self.rm(
            0,
            if sz == 1 {
                0x86u32
            } else {
                0x87u32
            },
            sz == 8,
            r,
            m,
            sz == 1,
        );
    }

    /// lock xadd `[m]`, `r`.
    pub(package) fn lock_xadd(self: &mut Self, sz: u32, r: u8, m: Mem) {
        self.osize(sz);
        self.byte(0xF0);
        self.rm(
            0,
            if sz == 1 {
                0x0FC0u32
            } else {
                0x0FC1u32
            },
            sz == 8,
            r,
            m,
            sz == 1,
        );
    }

    /// lock cmpxchg `[m]`, `r` (compares with rax).
    pub(package) fn lock_cmpxchg(self: &mut Self, sz: u32, r: u8, m: Mem) {
        self.osize(sz);
        self.byte(0xF0);
        self.rm(
            0,
            if sz == 1 {
                0x0FB0u32
            } else {
                0x0FB1u32
            },
            sz == 8,
            r,
            m,
            sz == 1,
        );
    }

    pub(package) fn mfence(self: &mut Self) {
        self.byte(0x0F);
        self.byte(0xAE);
        self.byte(0xF0);
    }

    pub(package) fn ud2(self: &mut Self) {
        self.byte(0x0F);
        self.byte(0x0B);
    }

    // ---- Control flow ----

    /// A jump of condition `cc` with a 32-bit displacement; the field's position.
    pub(package) fn jcc32(self: &mut Self, cc: u32) u32 {
        self.byte(0x0F);
        self.byte(0x80 + cc);
        let at = self.len();
        self.jumps.push(at);
        self.d32(0);
        return at;
    }

    /// A jump of condition `cc` to code position `to` (before it): 2 bytes when it reaches.
    pub(package) fn jcc_back(self: &mut Self, cc: u32, to: u32) {
        let d = to as i64 - (self.len() as i64 + 2);
        if d >= -128 {
            self.byte(0x70 + cc);
            self.byte(d as u32);
            return;
        }
        let at = self.jcc32(cc);
        self.patch32(at, (to as i64 - (at as i64 + 4)) as u32);
    }

    /// A jump with a 32-bit displacement that `relax` keeps long; the field's position.
    pub(package) fn jmp32_long(self: &mut Self) u32 {
        let at = self.jmp32();
        self.longs.push(at);
        return at;
    }

    /// A jump with a 32-bit displacement; the field's position.
    pub(package) fn jmp32(self: &mut Self) u32 {
        self.byte(0xE9);
        let at = self.len();
        self.jumps.push(at);
        self.d32(0);
        return at;
    }

    /// Point the 32-bit displacement field at `at` to code position `to`.
    pub(package) const fn land(self: &mut Self, at: u32, to: u32) {
        self.patch32(at, (to as i64 - (at as i64 + 4)) as u32);
    }

    /// A call with a 32-bit displacement (for a relocation); the field's position.
    pub(package) fn call32(self: &mut Self) u32 {
        self.stack_use();
        self.byte(0xE8);
        let at = self.len();
        self.d32(0);
        return at;
    }

    /// A call of the address in `r`.
    pub(package) fn call_r(self: &mut Self, r: u8) {
        self.stack_use();
        self.rr(0, 0xFF, false, 2, r, false);
    }

    pub(package) fn ret(self: &mut Self) {
        self.byte(0xC3);
    }

    pub(package) fn push(self: &mut Self, r: u8) {
        self.stack_use();
        if r >= 8 {
            self.byte(0x41);
        }
        self.byte(0x50 + (r as u32 & 7));
    }

    pub(package) fn pop(self: &mut Self, r: u8) {
        self.stack_use();
        if r >= 8 {
            self.byte(0x41);
        }
        self.byte(0x58 + (r as u32 & 7));
    }

    // ---- SSE ----

    /// An SSE operation `dst` = `dst` op `src` of mandatory prefix `pfx` (0x66, 0xF2, 0xF3 or 0) and
    /// opcode `op` (`0F xx`).
    pub(package) fn sse_rr(self: &mut Self, pfx: u32, op: u32, dst: u8, src: u8) {
        self.rr(pfx, op, false, dst, src, false);
    }

    /// Load `n` bytes (4, 8, 16, or 32 into a ymm register, 64 into a zmm one) at `m` into xmm `dst` (the
    /// bytes above zeroed).
    pub(package) fn vload(self: &mut Self, n: u32, dst: u8, m: Mem) {
        if n == 64 {
            self.zmov(true, dst, m);
        } else if n == 32 {
            self.ymov(true, dst, m);
        } else if n == 4 {
            self.rm(0xF3, 0x0F10, false, dst, m, false);
        } else if n == 8 {
            self.rm(0xF3, 0x0F7E, false, dst, m, false);
        } else {
            self.rm(0xF3, 0x0F6F, false, dst, m, false);
        }
    }

    /// Store the low `n` bytes (4, 8, 16, or 32 of a ymm register, 64 of a zmm one) of xmm `src` to `m`.
    pub(package) fn vstore(self: &mut Self, n: u32, src: u8, m: Mem) {
        if n == 64 {
            self.zmov(false, src, m);
        } else if n == 32 {
            self.ymov(false, src, m);
        } else if n == 4 {
            self.rm(0xF3, 0x0F11, false, src, m, false);
        } else if n == 8 {
            self.rm(0x66, 0x0FD6, false, src, m, false);
        } else {
            self.rm(0xF3, 0x0F7F, false, src, m, false);
        }
    }

    /// A VEX instruction on registers: `dst` (ModRM.reg) = `src1` (VEX.vvvv; 0 for none) op `src2`
    /// (ModRM.rm, an xmm or a general register), its legacy prefix `pfx` (0, 0x66, 0xF3 or 0xF2), opcode map
    /// `mm` (1: 0F, 2: 0F38, 3: 0F3A), opcode `op`, VEX.W `w`, 256 bits when `l`.
    pub(package) fn vex_rr(self: &mut Self, pfx: u32, mm: u32, op: u32, w: bool, l: bool, dst: u8, src1: u8, src2: u8) {
        if (dst | src1 | src2) >= 16 {
            let f = evex_form(pfx, map_op(mm, op), dst, w, false);
            assert(f != EV_NONE, "x64: a VEX operation without an EVEX form on xmm16..xmm31");
            self.evex_r(pfx, mm, op, ev_w(f, w), l as u32, dst, src1, src2);
            return;
        }
        let r = (~(dst as u32) >> 3 & 1) << 7;
        let b = (~(src2 as u32) >> 3 & 1) << 5;
        let tail = (~(src1 as u32) & 15) << 3 | l as u32 << 2 | pp_of(pfx);
        if mm == 1 && !w && b != 0 {
            self.byte(0xC5);
            self.byte(r | tail);
        } else {
            self.byte(0xC4);
            self.byte(r | 1u32 << 6 | b | mm);
            self.byte(w as u32 << 7 | tail);
        }
        self.byte(op);
        self.modrm_rr(dst, src2);
    }

    /// `vex_rr` with its second source at `m` (no alignment needed).
    pub(package) fn vex_rm(self: &mut Self, pfx: u32, mm: u32, op: u32, w: bool, l: bool, dst: u8, src1: u8, m: Mem) {
        if (dst | src1) >= 16 {
            let f = evex_form(pfx, map_op(mm, op), dst, w, true);
            assert(f != EV_NONE, "x64: a VEX operation without an EVEX form on xmm16..xmm31");
            self.evex_m(pfx, mm, op, ev_w(f, w), l as u32, dst, src1, m, ev_n(f, 16u32 << l as u32, w));
            return;
        }
        let r = (~(dst as u32) >> 3 & 1) << 7;
        let x = if m.index != NOREG {
            (~(m.index as u32) >> 3 & 1) << 6
        } else {
            1u32 << 6
        };
        let b = if m.base != RIP && m.base != NOREG {
            (~(m.base as u32) >> 3 & 1) << 5
        } else {
            1u32 << 5
        };
        let tail = (~(src1 as u32) & 15) << 3 | l as u32 << 2 | pp_of(pfx);
        if mm == 1 && !w && x != 0 && b != 0 {
            self.byte(0xC5);
            self.byte(r | tail);
        } else {
            self.byte(0xC4);
            self.byte(r | x | b | mm);
            self.byte(w as u32 << 7 | tail);
        }
        self.byte(op);
        self.modrm_m(dst, m);
    }

    /// An EVEX.512 instruction on registers, as `vex_rr` on zmm registers (or a mask or general register
    /// where the opcode takes one), unmasked; EVEX.W `w`.
    pub(package) fn evex_rr(self: &mut Self, pfx: u32, mm: u32, op: u32, w: bool, dst: u8, src1: u8, src2: u8) {
        self.evex_r(pfx, mm, op, w, 2, dst, src1, src2);
    }

    /// Every bit of the low `n` bytes (16, 32, 64) of xmm `r` set: `vpternlogd r, r, r, 0xFF` (EVEX.66.0F3A.W0
    /// 25), for zmm registers and xmm16..xmm31, which `pcmpeqd` cannot write.
    pub(package) fn vones(self: &mut Self, n: u32, r: u8) {
        self.evex_r(0x66, 3, 0x25, false, n / 32, r, r, r);
        self.byte(0xFF);
    }

    // The EVEX prefix (unmasked, no broadcast or rounding): legacy prefix `pfx`, opcode map `mm`, EVEX.W `w`,
    // vector length `ll` (0: 128 bits, 1: 256, 2: 512), ModRM.reg `reg`, `v` in V'vvvv (0 for none), and the
    // ModRM.rm extension bits `x` and `b` (inverted, as the prefix holds them).
    fn evex_p(self: &mut Self, pfx: u32, mm: u32, w: bool, ll: u32, reg: u8, v: u8, x: u32, b: u32) {
        self.byte(0x62);
        // P0: R X B R' 0 m m m.
        self.byte((~(reg as u32) >> 3 & 1) << 7 | x << 6 | b << 5 | (~(reg as u32) >> 4 & 1) << 4 | mm);
        // P1: W vvvv 1 pp.
        self.byte(w as u32 << 7 | (~(v as u32) & 15) << 3 | 4 | pp_of(pfx));
        // P2: z L'L b V' aaa.
        self.byte(ll << 5 | (~(v as u32) >> 4 & 1) << 3);
    }

    // An EVEX instruction on registers: `reg` (ModRM.reg), `v` (V'vvvv), `rm` (ModRM.rm, an xmm or a general
    // register: EVEX.X holds its fifth bit).
    fn evex_r(self: &mut Self, pfx: u32, mm: u32, op: u32, w: bool, ll: u32, reg: u8, v: u8, rm: u8) {
        self.evex_p(pfx, mm, w, ll, reg, v, ~(rm as u32) >> 4 & 1, ~(rm as u32) >> 3 & 1);
        self.byte(op);
        self.modrm_rr(reg, rm);
    }

    // `evex_r` with ModRM.rm memory operand `m`, its 8-bit displacement counted in `n`-byte units.
    fn evex_m(self: &mut Self, pfx: u32, mm: u32, op: u32, w: bool, ll: u32, reg: u8, v: u8, m: Mem, n: i32) {
        let x = if m.index != NOREG {
            ~(m.index as u32) >> 3 & 1
        } else {
            1u32
        };
        let b = if m.base != RIP && m.base != NOREG {
            ~(m.base as u32) >> 3 & 1
        } else {
            1u32
        };
        self.evex_p(pfx, mm, w, ll, reg, v, x, b);
        self.byte(op);
        self.modrm_n(reg, m, n);
    }

    // `rr` (`rm` when `mem`, at `m`) of an SSE operation with a register of xmm16..xmm31: its EVEX.128 form
    // (`evex_form`), the destination its first source too where the legacy form reads it.
    fn sse_evex(self: &mut Self, pfx: u32, op: u32, w: bool, reg: u8, rm: u8, m: Mem, mem: bool) {
        let f = evex_form(pfx, op, reg, w, mem);
        assert(f != EV_NONE, "x64: an SSE operation without an EVEX form on xmm16..xmm31");
        let sh = f & EV_SHAPE;
        let v = if sh == EV_NDS {
            reg
        } else if sh == EV_NDD || sh == EV_NDM {
            rm
        } else {
            0
        };
        let mm = op >> 8 & 0xFF;
        let map = if mm == 0x0F {
            1u32
        } else if mm == 0x38 {
            2u32
        } else {
            3u32
        };
        if mem {
            self.evex_m(pfx, map, op & 0xFF, ev_w(f, w), 0, reg, v, m, ev_n(f, 16, w));
        } else {
            self.evex_r(pfx, map, op & 0xFF, ev_w(f, w), 0, reg, v, rm);
        }
    }

    /// vzeroupper: the ymm registers' upper halves zeroed, before code of the legacy SSE encoding.
    pub(package) fn vzeroupper(self: &mut Self) {
        self.byte(0xC5);
        self.byte(0xF8);
        self.byte(0x77);
    }

    /// xmm `dst` = xmm `src` (all 16 bytes).
    pub(package) fn vmov(self: &mut Self, dst: u8, src: u8) {
        if dst != src {
            self.rr(0, 0x0F28, false, dst, src, false);
        }
    }

    /// xmm `dst` = the low `sz` bytes (4 or 8) of `src`, the rest zeroed.
    pub(package) fn movd_to_x(self: &mut Self, sz: u32, dst: u8, src: u8) {
        self.rr(0x66, 0x0F6E, sz == 8, dst, src, false);
    }

    /// `dst` = the low `sz` bytes (4 or 8) of xmm `src`.
    pub(package) fn movd_from_x(self: &mut Self, sz: u32, dst: u8, src: u8) {
        self.rr(0x66, 0x0F7E, sz == 8, src, dst, false);
    }

    /// cvtsi2ss or cvtsi2sd (`d`) xmm `dst` = the signed `sz`-byte (4 or 8) integer in `src`.
    pub(package) fn cvtsi2f(self: &mut Self, d: bool, sz: u32, dst: u8, src: u8) {
        self.rr(
            if d {
                0xF2u32
            } else {
                0xF3u32
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
    pub(package) fn cvtf2si(self: &mut Self, d: bool, sz: u32, dst: u8, src: u8) {
        self.rr(
            if d {
                0xF2u32
            } else {
                0xF3u32
            },
            0x0F2C,
            sz == 8,
            dst,
            src,
            false,
        );
    }

    /// vfmadd231sd (`d`) or vfmadd231ss: xmm `dst` = xmm `a` * xmm `b` + xmm `dst` (VEX.LIG.66.0F38 B9).
    pub(package) fn vfma231(self: &mut Self, d: bool, dst: u8, a: u8, b: u8) {
        if (dst | a | b) >= 16 {
            self.evex_r(0x66, 2, 0xB9, d, 0, dst, a, b);
            return;
        }
        self.byte(0xC4);
        self.byte((~(dst as u32) >> 3 & 1) << 7 | 1u32 << 6 | (~(b as u32) >> 3 & 1) << 5 | 2);
        self.byte(
            if d {
                0x80u32
            } else {
                0u32
            } | (~(a as u32) & 15) << 3 | 1,
        );
        self.byte(0xB9);
        self.modrm_rr(dst, b);
    }

    // ---- Wide vector moves (the AVX forms the C ABI needs) ----

    /// vmovdqu of 32 bytes (VEX.256): ymm `r` from (`load`) or to `m`.
    pub(package) fn ymov(self: &mut Self, load: bool, r: u8, m: Mem) {
        if r >= 16 {
            // vmovdqu32 (EVEX.256.F3.0F.W0).
            self.evex_m(
                0xF3,
                1,
                if load {
                    0x6Fu32
                } else {
                    0x7Fu32
                },
                false,
                1,
                r,
                0,
                m,
                32,
            );
            return;
        }
        // Map 0F, prefix F3, L = 1: the two-byte form unless the index or the base needs its REX bit.
        let rb = (~(r as u32) >> 3 & 1) << 7;
        let xb = if m.index != NOREG {
            (~(m.index as u32) >> 3 & 1) << 6
        } else {
            1u32 << 6
        };
        let bb = if m.base != RIP && m.base != NOREG {
            (~(m.base as u32) >> 3 & 1) << 5
        } else {
            1u32 << 5
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
                0x6Fu32
            } else {
                0x7Fu32
            },
        );
        self.modrm_m(r, m);
    }

    /// vmovdqu64 of 64 bytes (EVEX.512): zmm `r` from (`load`) or to `m`. Its 8-bit displacement counts
    /// in 64-byte units.
    pub(package) fn zmov(self: &mut Self, load: bool, r: u8, m: Mem) {
        self.evex_m(
            0xF3,
            1,
            if load {
                0x6Fu32
            } else {
                0x7Fu32
            },
            true,
            2,
            r,
            0,
            m,
            64,
        );
    }
}

// The VEX and EVEX `pp` field of legacy prefix `pfx` (0, 0x66, 0xF3 or 0xF2).
const fn pp_of(pfx: u32) u32 {
    return if pfx == 0x66 {
        1
    } else if pfx == 0xF3 {
        2
    } else if pfx == 0xF2 {
        3
    } else {
        0
    };
}

// `evex_form`: EVEX.W (0, 1, or the operation's REX.W or VEX.W); the legacy form's operand shape (`EV_MOV`:
// no V'vvvv; `EV_NDS`: the destination, ModRM.reg, is the first source too; `EV_NDD`: the destination,
// ModRM.rm, is V'vvvv, ModRM.reg an opcode digit; `EV_NDM`: the destination, ModRM.rm, is the first
// source too); and the unit of the 8-bit displacement (the tuple's N): the vector's bytes, half, a quarter or
// an eighth of them, 1, 2, 4, 8 or 16 bytes, or 4 bytes with W0 and 8 with W1.
const EV_NONE: u32 = 0xFFFFFFFF;
const EV_W0: u32 = 0;
const EV_W1: u32 = 1;
const EV_WW: u32 = 2;
const EV_SHAPE: u32 = 12;
const EV_MOV: u32 = 0;
const EV_NDS: u32 = 4;
const EV_NDD: u32 = 8;
const EV_NDM: u32 = 12;
const EV_FULL: u32 = 0;
const EV_HALF: u32 = 16;
const EV_QUARTER: u32 = 32;
const EV_EIGHTH: u32 = 48;
const EV_N1: u32 = 64;
const EV_N2: u32 = 80;
const EV_N4: u32 = 96;
const EV_N8: u32 = 112;
const EV_N16: u32 = 128;
const EV_NW: u32 = 144;

// The opcode `op` of VEX map `mm` (1: 0F, 2: 0F 38, 3: 0F 3A) as `evex_form` takes it.
const fn map_op(mm: u32, op: u32) u32 {
    return if mm == 1 {
        0x0F00 | op
    } else if mm == 2 {
        0x0F3800 | op
    } else {
        0x0F3A00 | op
    };
}

// EVEX.W of form `f` for an operation of REX.W or VEX.W `w`.
const fn ev_w(f: u32, w: bool) bool {
    return (f & 3) == EV_W1 || (f & 3) == EV_WW && w;
}

// The unit of form `f`'s 8-bit displacement on `vl`-byte vectors, W `w`.
const fn ev_n(f: u32, vl: u32, w: bool) i32 {
    let k = f >> 4;
    return if k < 4 {
        (vl >> k) as i32
    } else if k < 9 {
        1i32 << (k - 4) as i32
    } else if w {
        8
    } else {
        4
    };
}

// The EVEX form of SSE or AVX operation `op` (`0F xx`, `0F 38 xx`, `0F 3A xx`) of legacy prefix (VEX.pp) `pfx`,
// ModRM.reg `dg` (an opcode digit), REX.W or VEX.W `w`, on a memory operand when `mem` (`EV_*`). EV_NONE for
// an operation without one of the same result: comparisons into vectors (EVEX's write mask registers),
// blends on vector masks, mask extractions, `ptest`, horizontal sums, `vperm2i128`.
const fn evex_form(pfx: u32, op: u32, dg: u8, w: bool, mem: bool) u32 {
    let o = op & 0xFF;
    let map = op >> 8;
    let p66 = pfx == 0x66;
    let ss = pfx == 0xF3;
    let sd = pfx == 0xF2;
    let n0 = pfx == 0;
    if map == 0x0F {
        // Floats: single (no prefix, F3) W0, double (66, F2) W1; the scalar ones (F3, F2) read 4 or 8 bytes.
        let fw = if p66 || sd {
            EV_W1
        } else {
            EV_W0
        };
        let fs = if ss {
            EV_N4
        } else if sd {
            EV_N8
        } else {
            EV_FULL
        };
        if o == 0x10 || o == 0x11 {
            return if (ss || sd) && mem {
                fw | fs
            } else if ss || sd {
                fw | fs | if o == 0x10 {
                    EV_NDS
                } else {
                    EV_NDM
                }
            } else {
                fw
            };
        }
        if (o == 0x12 || o == 0x16) && (n0 || p66 && mem) {
            return fw | EV_NDS | if mem {
                EV_N8
            } else {
                EV_FULL
            };
        }
        if o == 0x12 && sd {
            return EV_W1 | EV_N8;
        }
        if (o == 0x12 || o == 0x16) && ss {
            return EV_W0;
        }
        if (o == 0x13 || o == 0x17) && (n0 || p66) {
            return fw | EV_N8;
        }
        if (o == 0x14 || o == 0x15 || o >= 0x54 && o <= 0x57 || o == 0xC6) && (n0 || p66) {
            return fw | EV_NDS;
        }
        if (o == 0x28 || o == 0x29) && (n0 || p66) {
            return fw;
        }
        if o == 0x2A && (ss || sd) {
            return EV_WW | EV_NDS | EV_NW;
        }
        if (o == 0x2C || o == 0x2D) && (ss || sd) {
            return EV_WW | fs;
        }
        if (o == 0x2E || o == 0x2F) && (n0 || p66) {
            return fw | if p66 {
                EV_N8
            } else {
                EV_N4
            };
        }
        if o == 0x51 {
            return fw | fs | if ss || sd {
                EV_NDS
            } else {
                EV_MOV
            };
        }
        if o >= 0x58 && o <= 0x5F && o != 0x5A && o != 0x5B {
            return fw | fs | EV_NDS;
        }
        if o == 0x5A {
            return if n0 {
                EV_W0 | EV_HALF
            } else if p66 {
                EV_W1
            } else {
                fw | fs | EV_NDS
            };
        }
        if o == 0x5B {
            return EV_W0;
        }
        if o == 0xE6 && !n0 {
            return if ss {
                EV_W0 | EV_HALF
            } else {
                EV_W1
            };
        }
        if (o == 0x6E || o == 0x7E) && p66 {
            return EV_WW | EV_NW;
        }
        if o == 0x7E && ss || o == 0xD6 && p66 {
            return EV_W1 | EV_N8;
        }
        if (o == 0x6F || o == 0x7F) && (p66 || ss) {
            return EV_W0;
        }
        if o == 0x70 && !n0 {
            return EV_W0;
        }
        if !p66 {
            return EV_NONE;
        }
        // Shifts by an immediate: `psrlq` and `psllq` (73 /2, /6) take W1.
        if o >= 0x71 && o <= 0x73 && !mem {
            return EV_NDD | if o == 0x73 && (dg == 2 || dg == 6) {
                EV_W1
            } else {
                EV_W0
            };
        }
        if o == 0xC4 {
            return EV_W0 | EV_NDS | EV_N2;
        }
        if o == 0xC5 && !mem {
            return EV_W0;
        }
        // The integer lane operations; those of 64-bit lanes take W1, shifts by a vector read 16 bytes.
        let lane = o >= 0x60 && o <= 0x6D && (o < 0x64 || o > 0x66) || o >= 0xD1 && o <= 0xFE && o != 0xD6 && o != 0xD7 && o != 0xE6 && o != 0xE7 && o != 0xF0 && o != 0xF7;
        if lane {
            let q = o == 0xD4 || o == 0xFB || o == 0xF4 || o == 0x6C || o == 0x6D || o == 0xD3 || o == 0xF3;
            let sh = o == 0xD1 || o == 0xD2 || o == 0xD3 || o == 0xE1 || o == 0xE2 || o == 0xF1 || o == 0xF2 || o == 0xF3;
            return EV_NDS | if q {
                EV_W1
            } else {
                EV_W0
            } | if sh {
                EV_N16
            } else {
                EV_FULL
            };
        }
        return EV_NONE;
    }
    if !p66 {
        return EV_NONE;
    }
    if map == 0x0F38 {
        if o == 0x00 || o == 0x04 || o == 0x0B || o == 0x2B || o >= 0x38 && o <= 0x40 || o == 0x16 || o == 0x36 || o == 0x0C {
            return EV_W0 | EV_NDS;
        }
        if o == 0x28 || o == 0x0D {
            return EV_W1 | EV_NDS;
        }
        if o == 0x1C || o == 0x1D || o == 0x1E {
            return EV_W0;
        }
        // `pmovsx`, `pmovzx`: from half (bw, wd, dq), a quarter (bd, wq) or an eighth (bq) of the vector.
        if o >= 0x20 && o <= 0x25 || o >= 0x30 && o <= 0x35 {
            let k = o & 0xF;
            return if k == 1 || k == 4 {
                EV_QUARTER
            } else if k == 2 {
                EV_EIGHTH
            } else {
                EV_HALF
            };
        }
        if o == 0x13 {
            return EV_W0 | EV_HALF;
        }
        if o == 0x18 || o == 0x58 {
            return EV_W0 | EV_N4;
        }
        if o == 0x19 || o == 0x59 {
            return EV_W1 | EV_N8;
        }
        if o == 0x78 {
            return EV_W0 | EV_N1;
        }
        if o == 0x79 {
            return EV_W0 | EV_N2;
        }
        if o == 0x1A || o == 0x5A {
            return EV_W0 | EV_N16;
        }
        if o == 0x45 || o == 0x47 {
            return EV_WW | EV_NDS;
        }
        if o == 0x46 && !w {
            return EV_W0 | EV_NDS;
        }
        // The fused multiply-adds (96..9F, A6..AF, B6..BF): single or double by W; the scalar ones (odd, 9 and
        // up) read one lane.
        let lo = o & 0xF;
        if o >= 0x96 && o <= 0xBF && lo >= 6 {
            return EV_WW | EV_NDS | if lo >= 9 && (lo & 1) == 1 {
                EV_NW
            } else {
                EV_FULL
            };
        }
        return EV_NONE;
    }
    // 0F 3A: `round` as `vrndscale` (the same immediate's low bits), lane inserts and extracts, AVX2
    // permutations, 128-bit inserts and extracts (`vinsertf32x4`, `vextracti32x4`), `vcvtps2ph`.
    return if o == 0x08 || o == 0x04 {
        EV_W0
    } else if o == 0x09 || o == 0x00 || o == 0x01 || o == 0x05 {
        EV_W1
    } else if o == 0x0A {
        EV_W0 | EV_NDS | EV_N4
    } else if o == 0x0B {
        EV_W1 | EV_NDS | EV_N8
    } else if o == 0x0F {
        EV_W0 | EV_NDS
    } else if o == 0x14 {
        EV_W0 | EV_N1
    } else if o == 0x15 {
        EV_W0 | EV_N2
    } else if o == 0x16 {
        EV_WW | EV_NW
    } else if o == 0x17 {
        EV_W0 | EV_N4
    } else if o == 0x20 {
        EV_W0 | EV_NDS | EV_N1
    } else if o == 0x21 {
        EV_W0 | EV_NDS | EV_N4
    } else if o == 0x22 {
        EV_WW | EV_NDS | EV_NW
    } else if o == 0x18 || o == 0x38 {
        EV_W0 | EV_NDS | EV_N16
    } else if o == 0x19 || o == 0x39 {
        EV_W0 | EV_N16
    } else if o == 0x1D {
        EV_W0 | EV_HALF
    } else {
        EV_NONE
    };
}

// The little-endian 32 bits of `b` at `at`.
const fn read32(b: &Vector<u8>, at: u32) u32 {
    let i = at as usize;
    return b[i] as u32 | b[i + 1] as u32 << 8 | b[i + 2] as u32 << 16 | b[i + 3] as u32 << 24;
}

// The positions of `heads` (ascending) below `x`.
const fn heads_upto(heads: &Vector<u32>, x: u32) u32 {
    let mut lo: usize = 0;
    let mut hi = heads.len();
    while lo < hi {
        let mid = (lo + hi) / 2;
        if heads[mid] < x {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo as u32;
}

// Code position `x` after `relax`: `moved`, past the no-ops before each head at or below it (`pad_at`).
const fn placed(op: &Vector<u32>, cut: &Vector<u32>, heads: &Vector<u32>, pad_at: &Vector<u32>, x: u32) u32 {
    let n = heads_upto(heads, x + 1);
    return moved(op, cut, x) + pad_at[n as usize];
}

// `n` (at most 15) bytes of no-ops: the recommended multi-byte `nop` forms, at most 8 bytes each.
fn nops(out: &mut Vector<u8>, n: u32) {
    let forms: [u64; 9] = [
        0,
        0x90,
        0x9066,
        0x001F0F,
        0x00401F0F,
        0x0000441F0F,
        0x0000441F0F66,
        0x00000000801F0F,
        0x0000000000841F0F,
    ];
    let mut left = n;
    while left > 0 {
        let k = left.min(8);
        for q in 0..k {
            out.push((forms[k as usize] >> 8 * q as u64) as u8);
        }
        left -= k;
    }
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
