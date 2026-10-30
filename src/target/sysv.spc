// The System V AMD64 calling convention over LIR signatures (psABI 3.2.3). A value splits into eightbytes,
// each INTEGER (the next of rdi, rsi, rdx, rcx, r8, r9) or SSE (the next of xmm0..xmm7; an SSEUP one
// continues the register before it); a value whose eightbytes do not all fit in the registers left goes
// on the stack whole, and the registers stay for the arguments after it. An aggregate above 16 bytes, an
// unaligned one, or a wide vector the build does not hold in one register is MEMORY: copied onto the stack
// as an argument, through memory the caller passes in rdi as a result (returned in rax). A vector is the
// C vector of the C side when it holds vectors in registers (`Package.vec_regs`): up to 4 bytes INTEGER, 8
// bytes SSE, 16 or more one SSE register; else the array of its lanes. Results come in rax, rdx and xmm0,
// xmm1. Part registers are machine numbers: rax 0, rcx 1, rdx 2, rbx 3, rsp 4, rbp 5, rsi 6, rdi 7, r8..r15
// 8..15, and the xmm index for a vector part.
import lir::ir as *;
import codegen::abi as *;

// Eightbyte classes.
const K_NONE: u8 = 0;
const K_INT: u8 = 1;
const K_SSE: u8 = 2;
const K_SSEUP: u8 = 3;
const K_MEM: u8 = 4;

/// Integer argument register `k` (0 to 5): rdi, rsi, rdx, rcx, r8, r9.
pub(package) const fn gp_arg(k: u32) u8 {
    return (0x090801020607u64 >> (8 * k) as u64 & 0xFF) as u8;
}

// Integer result register `k` (0 or 1): rax, rdx.
const fn gp_ret(k: u32) u8 {
    return (2 * k) as u8;
}

// The class of eightbyte `e` of packed classes `cls` (a byte each).
const fn kof(cls: u64, e: u32) u8 {
    return (cls >> (8 * e) as u64 & 0xFF) as u8;
}

const fn align_up(x: u32, a: u32) u32 {
    return x + a - 1 & ~(a - 1);
}

// The size and alignment of signature type `pt`.
fn size_align(b: &Body, pt: u32, ptr: u32) (u32, u32) {
    if (pt & AGG) != 0 {
        let l = (pt & ~AGG) as usize;
        return (b.pool[l], 1u32 << b.pool[l + 1]);
    }
    let t = pt as u8;
    return (type_bytes(t, ptr), type_align(t, ptr));
}

// The class of a scalar of type `t` (`vregs`: the package's `vec_regs`) at byte `off`: its eightbytes
// merged into `cls`.
fn merge_scalar(t: u8, off: u32, ptr: u32, vregs: u32, cls: &mut u64) {
    let n = type_bytes(t, ptr);
    if is_vec(t) {
        if vregs == 0 {
            // The lanes C declares.
            let lt = lane_type(t);
            let eb = type_bytes(lt, ptr);
            for k in 0..lanes(t) {
                merge_scalar(lt, off + k * eb, ptr, vregs, cls);
            }
            return;
        }
        if n <= 4 {
            merge(cls, off / 8, K_INT);
            return;
        }
        merge(cls, off / 8, K_SSE);
        for k in 1..n / 8 {
            merge(cls, off / 8 + k, K_SSEUP);
        }
        return;
    }
    if is_float(t) {
        merge(cls, off / 8, K_SSE);
        return;
    }
    for k in 0..(n + 7) / 8 {
        merge(cls, (off + 8 * k) / 8, K_INT);
    }
}

// Merge class `k` into eightbyte `e` (psABI 3.2.3, step 4: INTEGER wins over SSE).
const fn merge(cls: &mut u64, e: u32, k: u8) {
    if e >= 8 {
        return;
    }
    let c = kof(*cls, e);
    let m = if c == k || k == K_NONE {
        c
    } else if c == K_NONE {
        k
    } else if c == K_MEM || k == K_MEM {
        K_MEM
    } else if c == K_INT || k == K_INT {
        K_INT
    } else {
        K_SSE
    };
    *cls = *cls & ~(0xFFu64 << (8 * e) as u64) | m as u64 << (8 * e) as u64;
}

// The eightbyte classes of signature type `pt` into `cls`; their count, 0 for MEMORY.
fn classify_type(b: &Body, pt: u32, ptr: u32, vregs: u32, cls: &mut u64) u32 {
    *cls = 0;
    let (size, _) = size_align(b, pt, ptr);
    let n = (size + 7) / 8;
    let t = pt as u8;
    if (pt & AGG) == 0 && is_vec(t) && vregs != 0 && size > 16 {
        // A wide C vector: one register when the build holds it in one, else MEMORY.
        if size > vregs {
            return 0;
        }
        merge_scalar(t, 0, ptr, vregs, cls);
        return n;
    }
    if size > 16 {
        return 0;
    }
    if (pt & AGG) == 0 {
        merge_scalar(t, 0, ptr, vregs, cls);
    } else {
        let l = (pt & ~AGG) as usize;
        let nl = b.pool[l + 2];
        for k in 0..nl {
            let off = b.pool[l + 3 + 2 * k as usize];
            let lt = b.pool[l + 4 + 2 * k as usize] as u8;
            if off % type_align(lt, ptr) != 0 {
                return 0;
            }
            merge_scalar(lt, off, ptr, vregs, cls);
        }
    }
    // Step 5: MEMORY anywhere makes it all MEMORY; an SSEUP after no SSE is SSE.
    for k in 0..n {
        let c = kof(*cls, k);
        if c == K_MEM {
            return 0;
        }
        if c == K_SSEUP && (k == 0 || kof(*cls, k - 1) != K_SSE && kof(*cls, k - 1) != K_SSEUP) {
            *cls = *cls & ~(0xFFu64 << (8 * k) as u64) | K_SSE as u64 << (8 * k) as u64;
        }
    }
    return n;
}

/// The layout of signature `sig` of body `b` (`ptr`-byte pointers, `vregs` the package's `vec_regs`).
pub(package) fn classify(b: &Body, sig: u32, ptr: u32, vregs: u32, out: &mut CallLayout) {
    out.locs.truncate(0);
    out.parts.truncate(0);
    let np = b.pool[sig as usize];
    out.unknown = unknown_class(b, b.pool[sig as usize + 2]);
    for k in 0..np {
        out.unknown = out.unknown || unknown_class(b, b.pool[(sig + 3 + k) as usize]);
    }
    let fixed = b.pool[sig as usize + 1];
    let nfixed = if (fixed & SIG_VARIADIC) != 0 {
        fixed & ~SIG_VARIADIC
    } else {
        np
    };
    let mut cls: u64 = 0;
    let mut gp: u32 = 0;
    let mut vr: u32 = 0;
    let mut stack: u32 = 0;
    // The result first: MEMORY takes rdi.
    let rt = b.pool[sig as usize + 2];
    let mut r = none();
    if rt != T_NONE as u32 {
        let n = classify_type(b, rt, ptr, vregs, &mut cls);
        r.p0 = out.parts.len() as u32;
        if n == 0 {
            r.kind = L_SRET;
            gp = 1;
        } else {
            r.kind = L_REG;
            let mut g: u32 = 0;
            let mut v: u32 = 0;
            put_parts(b, rt, ptr, cls, n, &mut g, &mut v, true, &mut r, &mut out.parts);
        }
    }
    for k in 0..np {
        if k == nfixed {
            out.named_bytes = stack;
            out.named_gp = gp as u8;
            out.named_vr = vr as u8;
        }
        let pt = b.pool[(sig + 3 + k) as usize];
        let (size, al) = size_align(b, pt, ptr);
        let mut loc = none();
        loc.p0 = out.parts.len() as u32;
        let n = classify_type(b, pt, ptr, vregs, &mut cls);
        let mut ng: u32 = 0;
        let mut nv: u32 = 0;
        for e in 0..n {
            if kof(cls, e) == K_INT {
                ng += 1;
            } else if kof(cls, e) == K_SSE {
                nv += 1;
            }
        }
        if n != 0 && gp + ng <= 6 && vr + nv <= 8 {
            loc.kind = L_REG;
            put_parts(b, pt, ptr, cls, n, &mut gp, &mut vr, false, &mut loc, &mut out.parts);
            let t = pt as u8;
            if (pt & AGG) == 0 && !is_vec(t) && !is_float(t) && size < 4 {
                loc.ext = if (pt & SIG_SEXT) != 0 {
                    2
                } else {
                    1
                };
            }
        } else {
            // On the stack, at least eightbyte-aligned.
            let a = if al > 8 {
                al
            } else {
                8
            };
            stack = align_up(stack, a);
            loc.kind = L_STACK;
            loc.off = stack;
            loc.size = size;
            stack += align_up(size, 8);
        }
        out.locs.push(loc);
    }
    if nfixed == np {
        out.named_bytes = stack;
        out.named_gp = gp as u8;
        out.named_vr = vr as u8;
    }
    out.vr_used = vr as u8;
    out.stack_bytes = align_up(stack, 16);
    out.ret = r;
}

// The register parts of a value of `n` eightbytes classed `cls`, from integer register `*gp` and vector
// register `*vr` on (`ret`: the result registers).
fn put_parts(
    b: &Body,
    pt: u32,
    ptr: u32,
    cls: u64,
    n: u32,
    gp: &mut u32,
    vr: &mut u32,
    ret: bool,
    loc: &mut ALoc,
    parts: &mut Vector<Part>,
) {
    let (size, _) = size_align(b, pt, ptr);
    let mut e: u32 = 0;
    // Each step takes one eightbyte, or an SSE one and the SSEUP ones after it: at most `n` steps.
    while e < n {
        let k = kof(cls, e);
        let off = 8 * e;
        if k == K_NONE {
            // Padding only: no register, its bytes undefined.
            e += 1;
            continue;
        }
        if k == K_INT {
            let r = if ret {
                gp_ret(*gp)
            } else {
                gp_arg(*gp)
            };
            let s = if size - off < 8 {
                size - off
            } else {
                8
            };
            parts.push(Part { reg: r, v: false, size: s as u8, off: off });
            *gp += 1;
            e += 1;
            continue;
        }
        let mut w: u32 = 1;
        while e + w < n && kof(cls, e + w) == K_SSEUP {
            w += 1;
        }
        let s = if size - off < 8 * w {
            size - off
        } else {
            8 * w
        };
        parts.push(Part { reg: (*vr) as u8, v: true, size: s as u8, off: off });
        *vr += 1;
        e += w;
    }
    loc.n = (parts.len() as u32 - loc.p0) as u8;
}

/// The save-area registers a variadic argument of type `t` (a scalar or a vector) takes in `va_arg`: `gp`
/// integer ones or `vr` vector ones; false when it is read from the stack only.
pub(package) fn va_regs(t: u8, ptr: u32, vregs: u32, gp: &mut u32, vr: &mut u32) bool {
    let mut cls: u64 = 0;
    let n = type_bytes(t, ptr);
    if n > 16 {
        return false;
    }
    merge_scalar(t, 0, ptr, vregs, &mut cls);
    *gp = 0;
    *vr = 0;
    for e in 0..(n + 7) / 8 {
        if kof(cls, e) == K_INT {
            *gp += 1;
        } else if kof(cls, e) == K_SSE {
            *vr += 1;
        } else if kof(cls, e) != K_SSEUP {
            return false;
        }
    }
    // A value of both kinds does not occur for a scalar; it would take both areas.
    return *gp == 0 || *vr == 0;
}
