// The Microsoft x64 calling convention, as mingw-w64 gcc applies it: each argument takes one 8-byte
// position; the first four go in rcx, rdx, r8, r9, or xmm0..xmm3 for a float, by position; the rest go
// on the stack past the callee's 32-byte home area. An aggregate of 1, 2, 4 or 8 bytes passes as an
// integer of its size; any other aggregate, an i128 and a vector past 8 bytes pass as a pointer to a
// copy the caller makes. A variadic float goes in both its vector and its integer register. A result of
// 1, 2, 4 or 8 bytes returns in rax, a float in xmm0, an i128 and a 16-byte vector register in xmm0
// (gcc's choice); any other result goes through memory whose address the caller passes as the first
// argument and the callee returns in rax.
import lir::ir as *;
import codegen::abi as *;

/// Integer argument register of position `k` (0 to 3): rcx, rdx, r8, r9.
pub const fn gp_arg(k: u32) u8 {
    return (0x09080201u32 >> 8 * k & 0xFF) as u8;
}

// Whether `n` bytes pass in one integer register.
const fn reg_size(n: u32) bool {
    return n == 1 || n == 2 || n == 4 || n == 8;
}

// The size of signature type `pt`.
fn size_of(b: &Body, pt: u32, ptr: u32) u32 {
    if (pt & AGG) != 0 {
        return b.pool[(pt & ~AGG) as usize];
    }
    return type_bytes(pt as u8, ptr);
}

/// The layout of signature `sig` of body `b` (`ptr`-byte pointers, `vregs` the package's `vec_regs`: 0
/// when C holds a vector as an array of its lanes, an aggregate then).
pub fn classify(b: &Body, sig: u32, ptr: u32, vregs: u32, out: &mut CallLayout) {
    out.locs.truncate(0);
    out.parts.truncate(0);
    let np = b.pool[sig as usize];
    out.unknown = unknown_class(b, b.pool[sig as usize + 2]);
    for k in 0..np {
        out.unknown = out.unknown || unknown_class(b, b.pool[(sig + 3 + k) as usize]);
    }
    let fixed = b.pool[sig as usize + 1];
    let nfixed = if (fixed & SIG_VARIADIC) != 0 {
        fixed & ~SIG_VARIADIC;
    } else {
        np;
    };
    // The position of the next argument.
    let mut at: u32 = 0;
    let rt = b.pool[sig as usize + 2];
    let mut r = none();
    if rt != T_NONE as u32 {
        let n = size_of(b, rt, ptr);
        let t = rt as u8;
        let agg = (rt & AGG) != 0 || is_vec(t) && vregs == 0;
        r.p0 = out.parts.len() as u32;
        if !agg && (is_float(t) || t == T_I128 || is_vec(t) && n == 16) {
            r.kind = L_REG;
            r.n = 1;
            out.parts.push(Part { reg: 0, v: true, size: n as u8, off: 0 });
        } else if reg_size(n) && (agg || !is_vec(t) || n <= 8) {
            r.kind = L_REG;
            r.n = 1;
            out.parts.push(Part { reg: 0, v: false, size: n as u8, off: 0 });
        } else {
            r.kind = L_SRET;
            at = 1;
        }
    }
    for k in 0..np {
        if k == nfixed {
            out.named_bytes = 8 * at;
        }
        let pt = b.pool[(sig + 3 + k) as usize];
        let t = pt as u8;
        let n = size_of(b, pt, ptr);
        let agg = (pt & AGG) != 0;
        let mut loc = none();
        loc.p0 = out.parts.len() as u32;
        // By value in an integer register's width, a float, or by reference.
        let byref = if agg {
            !reg_size(n);
        } else {
            t == T_I128 || is_vec(t) && !reg_size(n);
        };
        let flt = !agg && is_float(t);
        if at < 4 {
            if byref {
                loc.kind = L_REF_REG;
                loc.n = 1;
                out.parts.push(Part { reg: gp_arg(at), v: false, size: 8, off: 0 });
            } else {
                loc.kind = L_REG;
                loc.n = 1;
                out.parts.push(
                    Part {
                        reg: if flt {
                            at as u8;
                        } else {
                            gp_arg(at);
                        },
                        v: flt,
                        size: n as u8,
                        off: 0,
                    },
                );
                if flt && k >= nfixed {
                    // A variadic float also in its integer register, which `va_arg` reads.
                    loc.n = 2;
                    out.parts.push(Part { reg: gp_arg(at), v: false, size: n as u8, off: 0 });
                }
                if !agg && !is_vec(t) && !flt && n < 4 {
                    loc.ext = if (pt & SIG_SEXT) != 0 {
                        2;
                    } else {
                        1;
                    };
                }
            }
        } else {
            loc.kind = if byref {
                L_REF_STACK;
            } else {
                L_STACK;
            };
            loc.off = 32 + 8 * (at - 4);
            loc.size = if byref {
                8;
            } else {
                n;
            };
        }
        at += 1;
        out.locs.push(loc);
    }
    if nfixed == np {
        out.named_bytes = 8 * at;
    }
    // Every call reserves the callee's home area.
    let stack = if at > 4 {
        32 + 8 * (at - 4);
    } else {
        32;
    };
    out.stack_bytes = stack + 15 & ~15u32;
    out.ret = r;
}
