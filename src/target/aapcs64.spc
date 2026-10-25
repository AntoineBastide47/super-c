// The AAPCS64 calling convention over LIR signatures, with Apple's variant (`apple`): stack arguments
// packed at their natural alignment (an aggregate's size still rounds up to 8 bytes, a homogeneous float
// aggregate's does not), an i128 or 16-byte-aligned aggregate starting at an odd x register, every
// variadic argument on the stack in 8-byte slots, the caller extending arguments narrower than 32 bits.
// A vector is an 8- or 16-byte vector register's value when the C side passes vectors in registers, else
// the array of its lanes C declares (`Package.vec_regs`). A location says where each part of a value
// travels; the code generator moves the bytes.
import lir::ir as *;
import codegen::abi as *;

const fn align_up(x: u32, a: u32) u32 {
    return x + a - 1 & ~(a - 1);
}

// The homogeneous aggregate element of layout `l` of `b`: its type when 1 to 4 leaves of one float type
// or one 8- or 16-byte vector type tile the layout, else T_NONE.
const fn homogeneous(b: &Body, l: u32, ptr: u32) u8 {
    let size = b.pool[l as usize];
    let n = b.pool[l as usize + 2];
    if n == 0 || n > 4 {
        return T_NONE;
    }
    let t = b.pool[l as usize + 4] as u8;
    let es = type_bytes(t, ptr);
    if !(is_float(t) || is_vec(t) && (es == 8 || es == 16)) || es * n != size {
        return T_NONE;
    }
    for k in 0..n {
        if b.pool[(l + 4 + 2 * k) as usize] as u8 != t || b.pool[(l + 3 + 2 * k) as usize] != es * k {
            return T_NONE;
        }
    }
    return t;
}

/// The layout of signature `sig` of body `b` (`ptr`-byte pointers) under the Apple variant when `apple`;
/// `vregs` is the package's `vec_regs`.
pub fn classify(b: &Body, sig: u32, ptr: u32, apple: bool, vregs: u32, out: &mut CallLayout) {
    out.locs.truncate(0);
    out.parts.truncate(0);
    let np = b.pool[sig as usize];
    out.unknown = unknown_class(b, b.pool[sig as usize + 2]);
    for k in 0..np {
        out.unknown = out.unknown || unknown_class(b, b.pool[(sig + 3 + k) as usize]);
    }
    let fixed = b.pool[sig as usize + 1];
    let nfixed = ast_nfixed(fixed, np);
    let mut ngrn: u32 = 0;
    let mut nsrn: u32 = 0;
    let mut nsaa: u32 = 0;
    for k in 0..np {
        let pt = b.pool[(sig + 3 + k) as usize];
        let variadic = k >= nfixed;
        if variadic && k == nfixed {
            out.named_bytes = nsaa;
            out.named_gp = ngrn as u8;
            out.named_vr = nsrn as u8;
        }
        let mut loc = none();
        loc.p0 = out.parts.len() as u32;
        if variadic && apple {
            // Every variadic argument on the stack in 8-byte slots; one above 16 bytes by reference.
            let (size, al) = size_align(b, pt, ptr);
            if size > 16 && (pt & AGG) != 0 {
                nsaa = align_up(nsaa, 8);
                loc.kind = L_REF_STACK;
                loc.off = nsaa;
                nsaa += 8;
            } else {
                nsaa = align_up(
                    nsaa,
                    if al > 8 {
                        al;
                    } else {
                        8;
                    },
                );
                loc.kind = L_STACK;
                loc.off = nsaa;
                loc.size = size;
                nsaa += align_up(size, 8);
            }
            out.locs.push(loc);
            continue;
        }
        place(b, pt, ptr, apple, vregs, &mut ngrn, &mut nsrn, &mut nsaa, &mut loc, &mut out.parts);
        out.locs.push(loc);
    }
    if nfixed == np {
        out.named_bytes = nsaa;
        out.named_gp = ngrn as u8;
        out.named_vr = nsrn as u8;
    }
    out.stack_bytes = align_up(nsaa, 16);
    // The result.
    let rt = b.pool[sig as usize + 2];
    let mut r = none();
    r.p0 = out.parts.len() as u32;
    if rt != T_NONE as u32 {
        let mut g: u32 = 0;
        let mut s: u32 = 0;
        let mut a: u32 = 0;
        place(b, rt, ptr, apple, vregs, &mut g, &mut s, &mut a, &mut r, &mut out.parts);
        if r.kind != L_REG {
            // Too large for registers: the caller passes the memory in x8.
            out.parts.truncate(r.p0 as usize);
            r = none();
            r.kind = L_SRET;
        }
        r.ext = 0;
    }
    out.ret = r;
}

/// How a variadic argument of machine type `t` passes under the standard convention, which places it
/// as a fixed one: in vector registers (`vr`) or integer ones, `n` registers holding `es` bytes of the
/// value each, or a pointer to a copy in one integer register (`byref`).
pub fn va_place(b: &Body, t: u8, ptr: u32, vregs: u32) (bool, u32, u32, bool) {
    let mut g: u32 = 0;
    let mut s: u32 = 0;
    let mut a: u32 = 0;
    let mut loc = none();
    let mut parts = Vector::<Part>::new();
    place(b, t, ptr, false, vregs, &mut g, &mut s, &mut a, &mut loc, &mut parts);
    if loc.kind == L_REF_REG {
        return false, 1, 8, true;
    }
    let p = parts[0];
    let es: u32 = if p.v {
        p.size;
    } else {
        8;
    };
    return p.v, loc.n, es, false;
}

// The fixed-parameter count of a signature's second word.
const fn ast_nfixed(fixed: u32, np: u32) u32 {
    if (fixed & SIG_VARIADIC) != 0 {
        return fixed & ~SIG_VARIADIC;
    }
    return np;
}

// The size and alignment of signature type `pt`.
fn size_align(b: &Body, pt: u32, ptr: u32) (u32, u32) {
    if (pt & AGG) != 0 {
        let l = (pt & ~AGG) as usize;
        return b.pool[l], 1u32 << b.pool[l + 1];
    }
    let t = pt as u8;
    return type_bytes(t, ptr), type_align(t, ptr);
}

// Place one fixed argument (or the result) of signature type `pt`.
fn place(
    b: &Body,
    pt: u32,
    ptr: u32,
    apple: bool,
    vregs: u32,
    ngrn: &mut u32,
    nsrn: &mut u32,
    nsaa: &mut u32,
    loc: &mut ALoc,
    parts: &mut Vector<Part>,
) {
    let (size, al) = size_align(b, pt, ptr);
    let t = pt as u8;
    // A vector C holds as an array of its lanes passes as that aggregate.
    let lanes_c = (pt & AGG) == 0 && is_vec(t) && vregs == 0;
    let agg = (pt & AGG) != 0 || lanes_c;
    // A homogeneous aggregate: one float or vector register per element.
    let mut hom = T_NONE;
    if (pt & AGG) != 0 {
        hom = homogeneous(b, pt & ~AGG, ptr);
    } else if lanes_c {
        if is_float(lane_type(t)) && lanes(t) <= 4 {
            hom = lane_type(t);
        }
    } else if is_float(t) || is_vec(t) && (size == 8 || size == 16) {
        hom = t;
    }
    if hom != T_NONE {
        let es = type_bytes(hom, ptr);
        let n = size / es;
        if *nsrn + n <= 8 {
            loc.kind = L_REG;
            loc.n = n as u8;
            for k in 0..n {
                parts.push(Part { reg: (*nsrn + k) as u8, v: true, size: es as u8, off: k * es });
            }
            *nsrn += n;
            return;
        }
        *nsrn = 8;
        // On the stack at the element's alignment; Apple packs it, AAPCS64 rounds it to 8 bytes.
        let a = if apple {
            al;
        } else if al > 8 {
            al;
        } else {
            8;
        };
        *nsaa = align_up(*nsaa, a);
        loc.kind = L_STACK;
        loc.off = *nsaa;
        loc.size = size;
        *nsaa += if apple {
            size;
        } else {
            align_up(size, 8);
        };
        return;
    }
    if size > 16 {
        // By reference: a pointer to a copy, as an integer argument.
        if *ngrn < 8 {
            loc.kind = L_REF_REG;
            loc.n = 1;
            parts.push(Part { reg: (*ngrn) as u8, v: false, size: 8, off: 0 });
            *ngrn += 1;
        } else {
            *nsaa = align_up(*nsaa, 8);
            loc.kind = L_REF_STACK;
            loc.off = *nsaa;
            *nsaa += 8;
        }
        return;
    }
    // Integers and small aggregates in x registers, 8 bytes each.
    let n = (size + 7) / 8;
    if al == 16 && !apple && (*ngrn & 1) != 0 {
        *ngrn += 1;
    }
    if *ngrn + n <= 8 {
        loc.kind = L_REG;
        loc.n = n as u8;
        for k in 0..n {
            let s = if size - 8 * k < 8 {
                size - 8 * k;
            } else {
                8;
            };
            parts.push(Part { reg: (*ngrn + k) as u8, v: false, size: s as u8, off: 8 * k });
        }
        *ngrn += n;
        if !agg && !is_vec(t) && size < 4 {
            loc.ext = if (pt & SIG_SEXT) != 0 {
                2;
            } else {
                1;
            };
        }
        return;
    }
    *ngrn = 8;
    // A scalar packs at its own size under Apple; an aggregate rounds up to 8 bytes.
    let a = if (agg || !apple) && al < 8 {
        8;
    } else {
        al;
    };
    *nsaa = align_up(*nsaa, a);
    loc.kind = L_STACK;
    loc.off = *nsaa;
    loc.size = size;
    *nsaa += if agg || !apple {
        align_up(size, 8);
    } else {
        size;
    };
}
