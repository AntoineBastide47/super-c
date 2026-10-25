// The basic C ABI of wasm32 (the tool conventions' BasicCABI.md) over a LIR signature: how each parameter
// and the result pass as wasm values. A scalar passes as its wasm type (i8 and i16 as i32, extended as
// `SIG_SEXT` says), i128 as two i64, an aggregate with one scalar leaf at offset 0 of its own size and
// alignment as that scalar, an empty aggregate not at all, any other aggregate through a pointer to a
// caller's copy. An i128 result and a result in memory return through a pointer prepended to the
// parameters. Variadic arguments go in a buffer of the caller's, whose pointer is the last parameter. A
// vector is an aggregate of its lanes, but a 16-byte one passes as v128 where C holds vectors in vector
// registers (`vregs`, the package's `vec_regs`).
import lir::ir as *;
import target::wasm as w;

/// How one value passes.
pub(package) const P_SKIP: u8 = 0; // nothing: an empty aggregate, or no result
pub(package) const P_DIRECT: u8 = 1; // one wasm value of LIR scalar type `ty`
pub(package) const P_I128: u8 = 2; // two i64, the low half first
pub(package) const P_REF: u8 = 3; // a pointer to the bytes (a parameter), or the prepended pointer (the result)
pub(package) const P_V128: u8 = 4; // one v128

/// The passing of one parameter or the result: its kind, its LIR scalar type (P_DIRECT: the value's, or
/// an aggregate's leaf), and whether the scalar is an aggregate's leaf (it moves through memory).
pub(package) struct Pass {
    pub(package) kind: u8,
    pub(package) ty: u8,
    pub(package) leaf: bool,
    pub(package) sext: bool, // an i8 or i16 that extends signed
}

extend Pass as Copy {}

/// A signature's passing: per LIR parameter, then the result.
pub(package) struct WSig {
    pub(package) params: Vector<Pass>,
    pub(package) ret: Pass,
    pub(package) nfixed: u32, // the fixed parameters; the rest are variadic
    pub(package) variadic: bool,
    pub(package) unknown: bool, // an aggregate whose leaves its layout does not give
}

extend WSig {
    pub(package) fn new() WSig {
        return WSig {
            params: Vector::<Pass>::new(),
            ret: Pass { kind: P_SKIP, ty: T_NONE, leaf: false, sext: false },
            nfixed: 0,
            variadic: false,
            unknown: false,
        };
    }

    /// Whether the result returns through a prepended pointer.
    pub(package) const fn sret(self: &Self) bool {
        return self.ret.kind == P_REF || self.ret.kind == P_I128;
    }
}

/// The wasm value type of LIR scalar type `t` (pointers are 32-bit).
pub(package) const fn wtype(t: u8) u8 {
    if t == T_I64 {
        return w::I64;
    }
    if t == T_F32 {
        return w::F32;
    }
    if t == T_F64 {
        return w::F64;
    }
    return w::I32;
}

/// The passing of signature `sig` of body `b` into `out`.
pub(package) fn classify(b: &Body, sig: u32, vregs: u32, out: &mut WSig) {
    let np = b.pool[sig as usize];
    let nf = b.pool[sig as usize + 1];
    out.params.truncate(0);
    out.unknown = false;
    out.variadic = (nf & SIG_VARIADIC) != 0;
    out.nfixed = nf & ~SIG_VARIADIC;
    for k in 0..np {
        let pt = b.pool[(sig + 3 + k) as usize];
        out.params.push(pass(b, pt, vregs, &mut out.unknown));
    }
    let rt = b.pool[sig as usize + 2];
    out.ret = if rt == T_NONE as u32 {
        Pass { kind: P_SKIP, ty: T_NONE, leaf: false, sext: false };
    } else {
        pass(b, rt, vregs, &mut out.unknown);
    };
    // A result that is not one wasm value returns through memory.
    if out.ret.kind == P_I128 || out.ret.kind == P_DIRECT && out.ret.leaf && out.ret.ty == T_I128 {
        out.ret.kind = P_I128;
    }
}

// The passing of signature type `pt`.
fn pass(b: &Body, pt: u32, vregs: u32, unknown: &mut bool) Pass {
    if (pt & AGG) == 0 {
        let t = pt as u8;
        if t == T_I128 {
            return Pass { kind: P_I128, ty: t, leaf: false, sext: false };
        }
        if is_vec(t) {
            let n = type_bytes(t, 4);
            if vregs >= 16 && n == 16 {
                return Pass { kind: P_V128, ty: t, leaf: false, sext: false };
            }
            return Pass { kind: P_REF, ty: t, leaf: false, sext: false };
        }
        return Pass { kind: P_DIRECT, ty: t, leaf: false, sext: (pt & SIG_SEXT) != 0 };
    }
    let l = (pt & ~AGG) as usize;
    let size = b.pool[l];
    let al = b.pool[l + 1];
    let nleaf = b.pool[l + 2];
    if size == 0 {
        return Pass { kind: P_SKIP, ty: T_NONE, leaf: false, sext: false };
    }
    if nleaf == 0 && size <= 64 {
        *unknown = true;
        return Pass { kind: P_REF, ty: T_NONE, leaf: false, sext: false };
    }
    if nleaf == 1 {
        let off = b.pool[l + 3];
        let t = b.pool[l + 4] as u8;
        if off == 0 && !is_vec(t) && type_bytes(t, 4) == size && 1u32 << al <= type_align(t, 4) {
            let k = if t == T_I128 {
                P_I128;
            } else {
                P_DIRECT;
            };
            return Pass { kind: k, ty: t, leaf: true, sext: false };
        }
    }
    return Pass { kind: P_REF, ty: T_NONE, leaf: false, sext: false };
}

/// The wasm function type of `s` (its parameters, then its results) into `out`.
pub(package) fn encode(s: &WSig, out: &mut Vector<u8>) {
    out.truncate(0);
    let mut ps = Vector::<u8>::new();
    if s.sret() {
        ps.push(w::I32);
    }
    for k in 0..s.nfixed as usize {
        let p = s.params[k];
        if p.kind == P_DIRECT {
            ps.push(wtype(p.ty));
        } else if p.kind == P_I128 {
            ps.push(w::I64);
            ps.push(w::I64);
        } else if p.kind == P_REF {
            ps.push(w::I32);
        } else if p.kind == P_V128 {
            ps.push(w::V128);
        }
    }
    if s.variadic {
        ps.push(w::I32);
    }
    w::uleb(out, ps.len() as u64);
    out.extend_copy(&ps);
    if s.ret.kind == P_DIRECT {
        out.push(1);
        out.push(wtype(s.ret.ty));
    } else if s.ret.kind == P_V128 {
        out.push(1);
        out.push(w::V128);
    } else {
        out.push(0);
    }
}

/// The bytes and alignment variadic argument of LIR type `pt` takes in the buffer: a scalar its own (at
/// least 4), an aggregate passed through a pointer the pointer's.
pub(package) fn va_slot(b: &Body, pt: u32, vregs: u32) (u32, u32) {
    let mut unk = false;
    let p = pass(b, pt, vregs, &mut unk);
    if p.kind == P_DIRECT || p.kind == P_I128 {
        let n = type_bytes(p.ty, 4);
        let a = type_align(p.ty, 4);
        return ast_max(n, 4), ast_max(a, 4);
    }
    if p.kind == P_V128 {
        return 16, 16;
    }
    return 4, 4;
}

const fn ast_max(a: u32, b: u32) u32 {
    if a > b {
        return a;
    }
    return b;
}
