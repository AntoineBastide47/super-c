// The Microsoft x64 calling convention, as mingw-w64 gcc applies it: each argument takes one 8-byte
// position; the first four go in rcx, rdx, r8, r9, or xmm0..xmm3 for a float, by position; the rest go
// on the stack past the callee's 32-byte home area. An aggregate of 1, 2, 4 or 8 bytes passes as an
// integer of its size; any other aggregate, an i128 and a vector past 8 bytes pass as a pointer to a
// copy the caller makes. A variadic float goes in both its vector and its integer register. A result of
// 1, 2, 4 or 8 bytes returns in rax, a float in xmm0; any other result goes through memory whose
// address the caller passes as the first argument and the callee returns in rax. C holds an i128 and
// every vector in a struct (`Int__128`, `mangle::vec_def`), so they follow the aggregate rules (the
// runtime's own `__int128` calls are `x64gen::rt_call128_win`'s).
//
// Super-C's own convention (`sc`), for a call of a function no C code reaches by name, differs in one
// rule: an aggregate of 9 to 16 bytes whose last 8 or fewer bytes pass as an integer (a slice, a `str`)
// passes in two integer registers, by position, when two remain, and returns in rax and rdx, as System V
// passes it. `thunks` gives C a Microsoft x64 entry to each such function whose address the program
// takes.
import lir::ir as *;
import codegen::abi as *;
import ast::ast as ast;

/// Integer argument register of position `k` (0 to 3): rcx, rdx, r8, r9.
pub(package) const fn gp_arg(k: u32) u8 {
    return (0x09080201u32 >> 8 * k & 0xFF) as u8;
}

// Whether `n` bytes pass in one integer register.
const fn reg_size(n: u32) bool {
    return n == 1 || n == 2 || n == 4 || n == 8;
}

// Whether an aggregate of `n` bytes passes in two integer registers under Super-C's own convention.
const fn pair_size(n: u32) bool {
    return n > 8 && n <= 16 && reg_size(n - 8);
}

/// Whether signature `sig` of body `b` passes or returns an aggregate in two registers under Super-C's own
/// convention, where Microsoft x64 passes a pointer to a copy.
pub(package) const fn pairs_in(b: &Body, sig: u32) bool {
    if (b.pool[sig as usize + 1] & SIG_VARIADIC) != 0 {
        return false;
    }
    let np = b.pool[sig as usize];
    for k in 0..np + 1 {
        let pt = b.pool[(sig + 2 + k) as usize];
        if (pt & AGG) != 0 && pair_size(b.pool[(pt & ~AGG) as usize]) {
            return true;
        }
    }
    return false;
}

/// The layout of signature `sig` of body `b` (`ptr`-byte pointers), by Super-C's own convention when `sc`.
/// C passes every vector as a struct, so the package's `vec_regs` changes nothing.
pub(package) fn classify(b: &Body, sig: u32, ptr: u32, sc: bool, out: &mut CallLayout) {
    out.locs.truncate(0);
    out.parts.truncate(0);
    let np = b.pool[sig as usize];
    // An aggregate passes by its size alone: its leaves never matter.
    out.unknown = false;
    let fixed = b.pool[sig as usize + 1];
    let nfixed = nfixed(fixed, np);
    let two = sc && (fixed & SIG_VARIADIC) == 0;
    // The position of the next argument.
    let mut at: u32 = 0;
    let rt = b.pool[sig as usize + 2];
    let mut r = none();
    if rt != T_NONE as u32 {
        let n = size_align(b, rt, ptr).0;
        let t = rt as u8;
        r.p0 = out.parts.len() as u32;
        if (rt & AGG) == 0 && is_float(t) {
            r.kind = L_REG;
            r.n = 1;
            out.parts.push(Part { reg: 0, v: true, size: n as u8, off: 0 });
        } else if reg_size(n) {
            r.kind = L_REG;
            r.n = 1;
            out.parts.push(Part { reg: 0, v: false, size: n as u8, off: 0 });
        } else if two && (rt & AGG) != 0 && pair_size(n) {
            // rax, then rdx.
            r.kind = L_REG;
            r.n = 2;
            out.parts.push(Part { reg: 0, v: false, size: 8, off: 0 });
            out.parts.push(Part { reg: 2, v: false, size: (n - 8) as u8, off: 8 });
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
        let n = size_align(b, pt, ptr).0;
        let agg = (pt & AGG) != 0;
        let mut loc = none();
        loc.p0 = out.parts.len() as u32;
        // By value in an integer register's width, a float, or by reference.
        let byref = if agg {
            !reg_size(n)
        } else {
            t == T_I128 || is_vec(t) && !reg_size(n)
        };
        let flt = !agg && is_float(t);
        if two && agg && pair_size(n) && at + 1 < 4 {
            loc.kind = L_REG;
            loc.n = 2;
            out.parts.push(Part { reg: gp_arg(at), v: false, size: 8, off: 0 });
            out.parts.push(Part { reg: gp_arg(at + 1), v: false, size: (n - 8) as u8, off: 8 });
            at += 2;
            out.locs.push(loc);
            continue;
        }
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
                            at as u8
                        } else {
                            gp_arg(at)
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
                    loc.ext = ast::pick((pt & SIG_SEXT) != 0, 2, 1);
                }
            }
        } else {
            loc.kind = ast::pick(byref, L_REF_STACK, L_STACK);
            loc.off = 32 + 8 * (at - 4);
            loc.size = ast::pick(byref, 8, n);
        }
        at += 1;
        out.locs.push(loc);
    }
    if nfixed == np {
        out.named_bytes = 8 * at;
    }
    // Every call reserves the callee's home area.
    let stack = if at > 4 {
        32 + 8 * (at - 4)
    } else {
        32
    };
    out.stack_bytes = stack + 15 & ~15u32;
    out.ret = r;
}

// A copy of signature `sig` of body `src` in body `dst`'s pool, with its layouts: its index there.
fn copy_sig(src: &Body, sig: u32, dst: &mut Body) u32 {
    let np = src.pool[sig as usize];
    let mut ts = Vector::<u32>::with_capacity(np as usize + 1);
    let mut leaves = Vector::<(u32, u8)>::new();
    for k in 0..np + 1 {
        let pt = src.pool[(sig + 2 + k) as usize];
        if (pt & AGG) == 0 {
            ts.push(pt);
            continue;
        }
        let l = (pt & ~AGG) as usize;
        leaves.truncate(0);
        for q in 0..src.pool[l + 2] as usize {
            leaves.push((src.pool[l + 3 + 2 * q], src.pool[l + 4 + 2 * q] as u8));
        }
        ts.push(AGG | dst.layout(src.pool[l], src.pool[l + 1], leaves[0..leaves.len()]));
    }
    let fixed = src.pool[sig as usize + 1];
    return dst.signature(ts[1..ts.len()], fixed & ~SIG_VARIADIC, (fixed & SIG_VARIADIC) != 0, ts[0]);
}

/// Microsoft x64 entries to the functions of package `p` whose address its bodies and data take and that
/// take Super-C's own convention, which C does not know (`pairs_in`; `x64gen::Gen::sc_conv`): each such
/// address is the address of a local thunk of the object that takes it (its unit's own symbols or the
/// rest, `Sym.own`), which passes its arguments on to the function (a call through the address may reach
/// C code too, so it takes C's convention). Held
/// bodies and data are a cached unit's, whose object has its own thunks. False, with the reason in `err`,
/// when the package records no signature of such a function.
pub(package) fn thunks(p: &mut Package, err: &mut String) bool {
    let nb = p.held_bodies();
    let nd = if p.held.data == NONE {
        p.data.len()
    } else {
        p.held.data as usize
    };
    // Each body's and data definition's object: 2 × its unit, + 1 when not of the unit's own symbols
    // (`driver::emit::native_plan`'s parts); NONE for no unit.
    let mut bpart = Vector::<u32>::with_capacity(p.bodies.len());
    for _ in 0..p.bodies.len() {
        bpart.push(NONE);
    }
    let mut dpart = Vector::<u32>::with_capacity(p.data.len());
    for _ in 0..p.data.len() {
        dpart.push(NONE);
    }
    for s in 0..p.syms.len() {
        let y = p.syms[s];
        if y.def == NONE || y.unit == NONE {
            continue;
        }
        let part = 2 * y.unit + (!y.own) as u32;
        if y.kind == SK_FUNC {
            bpart[y.def as usize] = part;
        } else {
            dpart[y.def as usize] = part;
        }
    }
    // Per object << 32 | function, its thunk.
    let mut made = Map::<u64, u32>::new();
    for k in 0..nb {
        for i in 0..p.bodies[k].insts.len() {
            let t = p.bodies[k].insts[i];
            if t.op != O_SYMADDR {
                continue;
            }
            let s = p.bodies[k].syms[t.a as usize];
            if !needs_thunk(p, s) {
                continue;
            }
            let th = thunk(p, s, bpart[k], &mut made, err);
            if th == NONE {
                return false;
            }
            let b = p.bodies.index_mut(k);
            let r = b.ref_sym(th);
            b.insts.index_mut(i).a = r;
        }
    }
    for d in 0..nd {
        let dd = p.data[d];
        for q in dd.relocs..dd.relocs + dd.nrelocs {
            let s = p.relocs[q as usize].sym;
            if !needs_thunk(p, s) {
                continue;
            }
            let th = thunk(p, s, dpart[d], &mut made, err);
            if th == NONE {
                return false;
            }
            p.relocs.index_mut(q as usize).sym = th;
        }
    }
    return true;
}

// Whether package symbol `s` is a function of Super-C's own convention whose signature C passes otherwise.
const fn needs_thunk(p: &Package, s: u32) bool {
    let y = p.syms[s as usize];
    if y.kind != SK_FUNC || y.ext || y.used {
        return false;
    }
    let (k, sig) = sig_of(p, s);
    return k != NONE && pairs_in(body_at(p, k), sig);
}

// Body `k` of `p`'s bodies, then of its `decls`.
const fn body_at<'a>(p: &'a Package, k: u32) &'a Body {
    if k >= p.bodies.len() as u32 {
        return &p.decls[(k - p.bodies.len() as u32) as usize];
    }
    return &p.bodies[k as usize];
}

// The body that holds the signature of function symbol `s` of `p` (its definition, else `decls[sig]` as
// `bodies.len() + sig`) and that signature; NONE when neither.
const fn sig_of(p: &Package, s: u32) (u32, u32) {
    let y = p.syms[s as usize];
    if y.def != NONE {
        return (y.def, p.bodies[y.def as usize].sig);
    }
    if y.sig != NONE {
        return (p.bodies.len() as u32 + y.sig, p.decls[y.sig as usize].sig);
    }
    return (NONE, NONE);
}

// The thunk of object `o` to function `s` (`thunks`), made when new (`made`); NONE, with the reason in
// `err`, when `p` records no signature of `s`.
fn thunk(p: &mut Package, s: u32, o: u32, made: &mut Map<u64, u32>, err: &mut String) u32 {
    let key = o as u64 << 32 | s as u64;
    if let Some(th) = made.get(&key) {
        return *th;
    }
    let (sb, sig) = sig_of(p, s);
    if sb == NONE {
        err.format_into("no signature of '{}' for its Microsoft x64 entry", p.spell(p.syms[s as usize].name));
        return NONE;
    }
    let mut b = Body::new();
    let ns = copy_sig(body_at(p, sb), sig, &mut b);
    // The parameters: an aggregate's address, and the result's last when it is an aggregate.
    let np = b.pool[ns as usize];
    let rt = b.pool[ns as usize + 2];
    let mut types = Vector::<u8>::new();
    for k in 0..np {
        let pt = b.pool[(ns + 3 + k) as usize];
        types.push(
            if (pt & AGG) != 0 {
                T_PTR
            } else {
                pt as u8
            },
        );
    }
    if (rt & AGG) != 0 {
        types.push(T_PTR);
    }
    let _ = b.add_block(types[0..types.len()]);
    b.begin(0);
    let mut args = Vector::<u32>::new();
    for k in 0..types.len() {
        args.push(VPARAM | k as u32);
    }
    let al = b.pool_list(args[0..args.len()]);
    let fs = b.ref_sym(s);
    let rty = if (rt & AGG) != 0 {
        T_NONE
    } else {
        rt as u8
    };
    let v = b.emit(Inst { op: O_CALL, ty: rty, aux: types.len() as u16, a: fs, b: ns, c: al }, 0);
    let _ = b.emit(Inst { op: O_RET, ty: T_NONE, aux: 0, a: ast::pick(rty == T_NONE, VNONE, v), b: VNONE, c: VNONE }, 0);
    b.sig = ns;
    // An object's number tells its thunks apart (a package of no unit has one each).
    let mut name = format("{}.msabi", p.spell(p.syms[s as usize].name));
    if o != NONE {
        name.format_into("{}", o);
    }
    let th = p.add_symbol(&name, SK_FUNC, SL_LOCAL);
    if th == NONE || !p.define(th, &b) {
        err.format_into("the symbol '{}' exists", name.as_str());
        return NONE;
    }
    let y = p.syms.index_mut(th as usize);
    if o != NONE {
        y.unit = o / 2;
        y.own = o % 2 == 0;
    }
    // C's convention (`x64gen::Gen::sc_conv`).
    y.used = true;
    made.insert(key, th);
    return th;
}
