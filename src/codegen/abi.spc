// The call layout every calling convention fills: where each parameter and the result of a signature
// travel, in registers, on the stack or through memory the caller provides. The code generator moves the
// bytes.
import lir::ir as *;
import ast::ast as ast;

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
    /// The bytes of the widest vector one register takes whole (`whole_vreg`): 16, or for an x86-64
    /// intrinsic's layout the register bytes of the body that calls it (32 with AVX2, 64 with AVX-512).
    pub(package) wide: u32,
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
        self.wide = o.wide;
    }

    /// Whether location `loc` takes a vector of type `t`, of 8 or 16 bytes or of a wider register's
    /// (`wide`), whole in one vector register.
    pub(package) const fn whole_vreg(self: &Self, loc: ALoc, t: u8) bool {
        let n = type_bytes(t, 8);
        if loc.kind != L_REG || loc.n != 1 || !is_vec(t) || n != 8 && n != 16 && !(n > 16 && n <= self.wide) {
            return false;
        }
        let pa = self.parts[loc.p0 as usize];
        return pa.v && pa.size as u32 == type_bytes(t, 8);
    }

    /// The count of the parts the arguments take: the result's follow them (`intrinsic_layout`).
    pub(package) const fn nargs(self: &Self) usize {
        return ast::pick(self.ret.kind == L_REG, self.ret.p0 as usize, self.parts.len());
    }

    /// Whether location `loc` of an intrinsic's layout is an integer argument in a register outside
    /// `clob`, the registers the intrinsic's instructions write: they read the argument as an immediate, no
    /// register takes it.
    pub(package) const fn imm_arg(self: &Self, loc: ALoc, clob: u64) bool {
        return loc.kind == L_REG && loc.n == 1 && !self.parts[loc.p0 as usize].v && (clob >> self.parts[loc.p0 as usize].reg as u64 & 1) == 0;
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
            wide: 16,
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
/// an integer or pointer in the next of `gp` (a 16-byte integer, or a struct's integer lane, 8 bytes per
/// register), and give a result the same way from vector register 0 and the first of `ret_gp`, whatever
/// the platform's convention.
pub(package) fn intrinsic_layout(b: &Body, sig: u32, ptr: u32, gp: []u8, ret_gp: []u8, out: &mut CallLayout) {
    out.locs.truncate(0);
    out.parts.truncate(0);
    out.unknown = false;
    out.stack_bytes = 0;
    out.wide = 16;
    let np = b.pool[sig as usize];
    let mut ng: u32 = 0;
    let mut nv: u32 = 0;
    for k in 0..np {
        let mut loc = none();
        intrinsic_place(b, b.pool[(sig + 3 + k) as usize], ptr, gp, &mut ng, &mut nv, &mut loc, out);
        out.locs.push(loc);
    }
    let rt = b.pool[sig as usize + 2];
    out.ret = none();
    if rt != T_NONE as u32 {
        let mut loc = none();
        let (mut rg, mut rv): (u32, u32) = (0, 0);
        intrinsic_place(b, rt, ptr, ret_gp, &mut rg, &mut rv, &mut loc, out);
        out.ret = loc;
    }
}

// Signature entry `pt` of an intrinsic in registers: each vector or float lane in the next vector register
// (`*nv`), each integer 8 bytes at a time in the next of `gp` (`*ng`); its parts onto `out.parts`.
fn intrinsic_place(
    b: &Body,
    pt: u32,
    ptr: u32,
    gp: []u8,
    ng: &mut u32,
    nv: &mut u32,
    loc: &mut ALoc,
    out: &mut CallLayout,
) {
    loc.kind = L_REG;
    loc.p0 = out.parts.len() as u32;
    if (pt & AGG) != 0 {
        let l = (pt & ~AGG) as usize;
        let nl = b.pool[l + 2];
        for q in 0..nl {
            intrinsic_part(b.pool[l + 4 + 2 * q as usize] as u8, b.pool[l + 3 + 2 * q as usize], ptr, gp, ng, nv, out);
        }
        out.unknown = out.unknown || nl == 0;
    } else {
        intrinsic_part(pt as u8, 0, ptr, gp, ng, nv, out);
    }
    loc.n = (out.parts.len() as u32 - loc.p0) as u8;
}

// A value of type `t` at offset `off`: one vector register, or general registers of 8 bytes each.
fn intrinsic_part(t: u8, off: u32, ptr: u32, gp: []u8, ng: &mut u32, nv: &mut u32, out: &mut CallLayout) {
    let size = type_bytes(t, ptr);
    if is_vec(t) || is_float(t) {
        out.parts.push(Part { reg: (*nv) as u8, v: true, size: size as u8, off: off });
        *nv += 1;
        return;
    }
    let mut k: u32 = 0;
    while k < size {
        out.parts.push(Part { reg: gp[(*ng) as usize], v: false, size: (size - k).min(8) as u8, off: off + k });
        *ng += 1;
        k += 8;
    }
}

/// `x` rounded up to a multiple of `a` (a power of two).
pub(package) const fn align_up(x: u32, a: u32) u32 {
    return x + a - 1 & ~(a - 1);
}

/// The size and alignment of signature entry `pt` of `b` (`AGG` and a layout, or a scalar type).
pub(package) const fn size_align(b: &Body, pt: u32, ptr: u32) (u32, u32) {
    if (pt & AGG) != 0 {
        let l = (pt & ~AGG) as usize;
        return (b.pool[l], 1u32 << b.pool[l + 1]);
    }
    return (type_bytes(pt as u8, ptr), type_align(pt as u8, ptr));
}

/// The number of fixed parameters of a signature whose fixed word is `fixed` and that has `np`.
pub(package) const fn nfixed(fixed: u32, np: u32) u32 {
    return if (fixed & SIG_VARIADIC) != 0 {
        fixed & ~SIG_VARIADIC
    } else {
        np
    };
}
