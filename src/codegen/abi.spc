// The call layout every calling convention fills: where each parameter and the result of a signature
// travel, in registers, on the stack or through memory the caller provides. The code generator moves the
// bytes.
import lir::ir as *;

/// Location kinds.
pub(package) const L_NONE: u8 = 0; // nothing passes (no result)
pub(package) const L_REG: u8 = 1; // in registers: `parts`
pub(package) const L_STACK: u8 = 2; // the value's `size` bytes at stack offset `off`
pub(package) const L_REF_REG: u8 = 3; // a pointer to a copy, in integer register `parts[p0].reg`
pub(package) const L_REF_STACK: u8 = 4; // a pointer to a copy, at stack offset `off`
pub(package) const L_SRET: u8 = 5; // a result through memory the caller passes (x8; SysV: the first argument)

/// A register part of a value: argument register `reg` of its file (the integer one, or the vector one
/// when `v`) holds the `size` bytes at byte `off` of the value.
pub(package) struct Part {
    pub(package) reg: u8,
    pub(package) v: bool,
    pub(package) size: u8,
    pub(package) off: u32,
}

extend Part as Copy {}

/// Where a parameter or the result travels.
pub(package) struct ALoc {
    pub(package) kind: u8,
    pub(package) n: u8, // register parts
    pub(package) p0: u32, // the first part in `CallLayout.parts`
    pub(package) off: u32, // stack offset (L_STACK, L_REF_STACK)
    pub(package) size: u32, // bytes on the stack (L_STACK)
    pub(package) ext: u8, // an argument narrower than 32 bits: 1 zero-extends, 2 sign-extends; else 0
}

extend ALoc as Copy {}

/// The locations of one signature's parameters and result.
pub(package) struct CallLayout {
    pub(package) locs: Vector<ALoc>,
    pub(package) parts: Vector<Part>,
    pub(package) ret: ALoc,
    pub(package) stack_bytes: u32, // the stack argument area, rounded up to 16
    pub(package) named_bytes: u32, // the stack bytes of the fixed parameters (the variadic ones follow, 8-aligned)
    pub(package) named_gp: u8, // SysV, AAPCS64: the integer registers the fixed parameters take (`va_start`)
    pub(package) named_vr: u8, // SysV, AAPCS64: the vector registers the fixed parameters take
    pub(package) vr_used: u8, // SysV: the vector registers every argument takes (`al` at a variadic call)
    pub(package) unknown: bool, // a parameter or the result is an aggregate whose class its layout does not give
}

extend CallLayout {
    /// `o`'s layout, in this one's buffers.
    pub(package) fn copy_from(self: &mut Self, o: &CallLayout) {
        self.locs.truncate(0);
        self.locs.extend_copy(&o.locs);
        self.parts.truncate(0);
        self.parts.extend_copy(&o.parts);
        self.ret = o.ret;
        self.stack_bytes = o.stack_bytes;
        self.named_bytes = o.named_bytes;
        self.named_gp = o.named_gp;
        self.named_vr = o.named_vr;
        self.vr_used = o.vr_used;
        self.unknown = o.unknown;
    }

    pub(package) fn new() CallLayout {
        return CallLayout {
            locs: Vector::<ALoc>::new(),
            parts: Vector::<Part>::new(),
            ret: none(),
            stack_bytes: 0,
            named_bytes: 0,
            named_gp: 0,
            named_vr: 0,
            vr_used: 0,
            unknown: false,
        };
    }
}

/// Whether signature type `pt` of body `b` is an aggregate whose register class its layout does not
/// give: 1 to 64 bytes and no leaves (the lowering keeps none when they are unknown).
pub(package) const fn unknown_class(b: &Body, pt: u32) bool {
    if (pt & AGG) == 0 {
        return false;
    }
    let l = (pt & ~AGG) as usize;
    return b.pool[l] != 0 && b.pool[l] <= 64 && b.pool[l + 2] == 0;
}

pub(package) const fn none() ALoc {
    return ALoc { kind: L_NONE, n: 0, p0: 0, off: 0, size: 0, ext: 0 };
}

/// The layout of a call of an intrinsic of signature `sig` (`target::intrin`): its rows' instructions take
/// the arguments in order, a vector or float in the next vector register (a struct of vectors in as many),
/// an integer or pointer in the next of `gp`, and give a vector or float result in vector register 0,
/// an integer one in `ret_gp`, whatever the platform's convention.
pub(package) fn intrinsic_layout(b: &Body, sig: u32, ptr: u32, gp: []u8, ret_gp: u8, out: &mut CallLayout) {
    out.locs.truncate(0);
    out.parts.truncate(0);
    out.unknown = false;
    out.stack_bytes = 0;
    let np = b.pool[sig as usize];
    let mut ng: u32 = 0;
    let mut nv: u32 = 0;
    for k in 0..np {
        let pt = b.pool[(sig + 3 + k) as usize];
        let mut loc = none();
        loc.kind = L_REG;
        loc.p0 = out.parts.len() as u32;
        if (pt & AGG) != 0 {
            let l = (pt & ~AGG) as usize;
            let nl = b.pool[l + 2];
            for q in 0..nl {
                let lt = b.pool[l + 4 + 2 * q as usize] as u8;
                out.parts.push(
                    Part {
                        reg: nv as u8,
                        v: true,
                        size: type_bytes(lt, ptr) as u8,
                        off: b.pool[l + 3 + 2 * q as usize],
                    },
                );
                nv += 1;
            }
            out.unknown = out.unknown || nl == 0;
            loc.n = nl as u8;
        } else {
            let t = pt as u8;
            let v = is_vec(t) || is_float(t);
            let r = if v {
                nv as u8
            } else {
                gp[ng as usize]
            };
            out.parts.push(Part { reg: r, v: v, size: type_bytes(t, ptr) as u8, off: 0 });
            if v {
                nv += 1;
            } else {
                ng += 1;
            }
            loc.n = 1;
        }
        out.locs.push(loc);
    }
    let rt = b.pool[sig as usize + 2];
    out.ret = none();
    if (rt & AGG) != 0 {
        // A struct of vectors: vector registers 0 and on.
        let l = (rt & ~AGG) as usize;
        let nl = b.pool[l + 2];
        out.ret.kind = L_REG;
        out.ret.n = nl as u8;
        out.ret.p0 = out.parts.len() as u32;
        for q in 0..nl {
            let lt = b.pool[l + 4 + 2 * q as usize] as u8;
            out.parts.push(
                Part { reg: q as u8, v: true, size: type_bytes(lt, ptr) as u8, off: b.pool[l + 3 + 2 * q as usize] },
            );
        }
        out.unknown = out.unknown || nl == 0;
    } else if rt != T_NONE as u32 {
        let t = rt as u8;
        let v = is_vec(t) || is_float(t);
        out.ret.kind = L_REG;
        out.ret.n = 1;
        out.ret.p0 = out.parts.len() as u32;
        out.parts.push(
            Part {
                reg: if v {
                    0
                } else {
                    ret_gp
                },
                v: v,
                size: type_bytes(t, ptr) as u8,
                off: 0,
            },
        );
    }
}
