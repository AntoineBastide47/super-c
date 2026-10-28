// The wasm assembler and disassembler for one instruction in LLVM's assembly syntax, both from the
// instruction table (`wasmtab`). A symbol an instruction names leaves its field 0 in a padded 5-byte
// LEB and records a fixup the caller resolves: the module assembler (`assembler`) gives each its
// relocation.
import target::wasm as w;
import target::wasmtab as t;

/// A symbol an instruction names: the relocation kind (`w::R_*`; for `R_TYPE_INDEX_LEB` the name is a
/// signature, `(i32, i64) -> (f32)`), the name, the addend and the field's offset from the
/// instruction's start.
pub(package) struct Fix {
    pub(package) kind: u8,
    pub(package) name: String,
    pub(package) addend: i64,
    pub(package) at: u32,
}

// ---- Lexing ----

const fn is_ident(c: u8, first: bool) bool {
    return c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c == b'_' || c == b'.' || c == b'$' || c == b'@' || !first && c >= b'0' && c <= b'9';
}

const fn ws(s: str, i: &mut usize) {
    while *i < s.len() && (s.byte_at(*i) == b' ' || s.byte_at(*i) == b'\t') {
        *i += 1;
    }
}

const fn eat(s: str, i: &mut usize, c: u8) bool {
    let mut j = *i;
    ws(s, &mut j);
    if j < s.len() && s.byte_at(j) == c {
        *i = j + 1;
        return true;
    }
    return false;
}

const fn word<'a>(s: str<'a>, i: &mut usize) str<'a> {
    ws(s, i);
    let st = *i;
    while *i < s.len() && is_ident(s.byte_at(*i), *i == st) {
        *i += 1;
    }
    return s.slice(st, *i);
}

const fn lower(c: u8) u8 {
    if c >= b'A' && c <= b'Z' {
        return c + 32;
    }
    return c;
}

// A signed integer at `*i`: decimal or `0x` hexadecimal, its magnitude to 64 bits.
const fn int(s: str, i: &mut usize, out: &mut i64) bool {
    let mut j = *i;
    ws(s, &mut j);
    let mut neg = false;
    if j < s.len() && (s.byte_at(j) == b'-' || s.byte_at(j) == b'+') {
        neg = s.byte_at(j) == b'-';
        j += 1;
    }
    let mut radix: u64 = 10;
    if j + 1 < s.len() && s.byte_at(j) == b'0' && lower(s.byte_at(j + 1)) == b'x' {
        radix = 16;
        j += 2;
    }
    let st = j;
    let mut v: u64 = 0;
    while j < s.len() {
        let c = lower(s.byte_at(j));
        let d: u64 = if c >= b'0' && c <= b'9' {
            c - b'0';
        } else if c >= b'a' && c <= b'f' {
            c - b'a' + 10;
        } else {
            99u64;
        };
        if d >= radix {
            break;
        }
        v = v.wrapping_mul(radix).wrapping_add(d);
        j += 1;
    }
    if j == st || j < s.len() && (is_ident(s.byte_at(j), false) || s.byte_at(j) == b'.') {
        return false;
    }
    *out = if neg {
        (v as i64).wrapping_neg();
    } else {
        v as i64;
    };
    *i = j;
    return true;
}

// ---- Floats ----

/// The bits of the float at `*i` (`f64`, else `f32`): decimal, `0x` hexadecimal with a binary `p`
/// exponent, `infinity`, `inf`, `nan` and `nan:0x<payload>`, each signed; rounded to nearest, ties to
/// even.
pub(package) fn float_bits(s: str, i: &mut usize, f64: bool, out: &mut u64) bool {
    let mut j = *i;
    ws(s, &mut j);
    let st = j;
    let mut neg = false;
    if j < s.len() && (s.byte_at(j) == b'-' || s.byte_at(j) == b'+') {
        neg = s.byte_at(j) == b'-';
        j += 1;
    }
    let mb: u32 = if f64 {
        52;
    } else {
        23;
    };
    let eb: u32 = if f64 {
        11;
    } else {
        8;
    };
    let sign: u64 = neg as u64 << mb + eb;
    let emax: u64 = (1u64 << eb) - 1;
    let rest = s.slice(j, s.len());
    if rest.starts_with("infinity") || rest.starts_with("inf") {
        *out = sign | emax << mb;
        *i = j + if rest.starts_with("infinity") {
            8usize;
        } else {
            3usize;
        };
        return true;
    }
    if rest.starts_with("nan") {
        j += 3;
        let mut payload: u64 = 1u64 << mb - 1;
        if j < s.len() && s.byte_at(j) == b':' {
            j += 1;
            let mut p: i64 = 0;
            if !int(s, &mut j, &mut p) || p <= 0 || p as u64 >= 1u64 << mb {
                return false;
            }
            payload = p as u64;
        }
        *out = sign | emax << mb | payload;
        *i = j;
        return true;
    }
    if !(j + 1 < s.len() && s.byte_at(j) == b'0' && lower(s.byte_at(j + 1)) == b'x') {
        // Decimal: up to the end of the number.
        let mut e = j;
        while e < s.len() && (s.byte_at(e) >= b'0' && s.byte_at(e) <= b'9' || s.byte_at(e) == b'.' || lower(
            s.byte_at(e),
        ) == b'e' || (s.byte_at(e) == b'-' || s.byte_at(e) == b'+') && e > j && lower(s.byte_at(e - 1)) == b'e') {
            e += 1;
        }
        let txt = s.slice(st, e);
        if f64 {
            switch txt.parse_f64() {
                Some(v) => {
                    *out = v.to_bits();
                },
                None => {
                    return false;
                },
            };
        } else {
            switch txt.parse_f32() {
                Some(v) => {
                    *out = v.to_bits();
                },
                None => {
                    return false;
                },
            };
        }
        *i = e;
        return true;
    }
    // Hexadecimal: the digits into a 64-bit mantissa (a dropped nonzero digit sets the sticky bit),
    // then a binary exponent.
    j += 2;
    let mut m: u64 = 0;
    let mut e2: i64 = 0;
    let mut seen = false;
    let mut point = false;
    let mut sticky = false;
    while j < s.len() {
        let c = lower(s.byte_at(j));
        if c == b'.' && !point {
            point = true;
            j += 1;
            continue;
        }
        let d: u64 = if c >= b'0' && c <= b'9' {
            c - b'0';
        } else if c >= b'a' && c <= b'f' {
            c - b'a' + 10;
        } else {
            break;
        };
        seen = true;
        if m >> 60 == 0 {
            m = m << 4 | d;
            if point {
                e2 -= 4;
            }
        } else {
            sticky = sticky || d != 0;
            if !point {
                e2 += 4;
            }
        }
        j += 1;
    }
    if !seen {
        return false;
    }
    if j < s.len() && lower(s.byte_at(j)) == b'p' {
        j += 1;
        let mut x: i64 = 0;
        if !int(s, &mut j, &mut x) || x < -100000 || x > 100000 {
            return false;
        }
        e2 += x;
    }
    *out = sign | round_bits(m, e2, sticky, mb, eb);
    *i = j;
    return true;
}

// The magnitude bits of m * 2^e2 (`sticky`: a nonzero tail below m) in the format of `mb` mantissa
// and `eb` exponent bits, rounded to nearest, ties to even.
const fn round_bits(m0: u64, e0: i64, sticky0: bool, mb: u32, eb: u32) u64 {
    if m0 == 0 {
        return 0;
    }
    let bias: i64 = (1i64 << eb - 1) - 1;
    // Normalize: the leading 1 at bit 63.
    let lz = m0.leading_zeros();
    let m = m0 << lz as u64;
    // The value is m * 2^(e0 - lz), with m in [2^63, 2^64): its exponent is e0 - lz + 63.
    let mut exp = e0 - lz as i64 + 63;
    // Keep mb + 1 bits; a subnormal keeps fewer.
    let mut keep: i64 = mb as i64 + 1;
    if exp < 1 - bias {
        keep -= 1 - bias - exp;
        exp = 1 - bias;
    }
    if keep <= 0 {
        // Below half the smallest subnormal rounds to 0; exactly half to 0 (even); above to it.
        let half = keep == 0 && (m > 1u64 << 63 || sticky0);
        return if half {
            1u64;
        } else {
            0u64;
        };
    }
    let drop = 64 - keep as u32;
    let mut q = m >> drop;
    let rem = m & (1u64 << drop) - 1;
    let halfway = 1u64 << drop - 1;
    if rem > halfway || rem == halfway && (sticky0 || (q & 1) != 0) {
        q += 1;
        if q >> keep as u32 != 0 {
            q >>= 1;
            exp += 1;
        }
    }
    if q >> mb == 0 {
        // A subnormal: the exponent field 0.
        return q;
    }
    let field = exp + bias;
    if field >= (1i64 << eb) - 1 {
        return (1u64 << eb) - 1 << mb;
    }
    return field as u64 << mb | q & (1u64 << mb) - 1;
}

/// The text of float bits `v` (`f64`, else `f32`): `infinity`, `nan`, `nan:0x<payload>`, or exact
/// hexadecimal `0x1.<digits>p<exp>` (a subnormal normalized), each signed.
pub(package) fn float_text(o: &mut String, v: u64, f64: bool) {
    let mb: u32 = if f64 {
        52;
    } else {
        23;
    };
    let eb: u32 = if f64 {
        11;
    } else {
        8;
    };
    let bias: i64 = (1i64 << eb - 1) - 1;
    if (v >> mb + eb & 1) != 0 {
        o.push_byte(b'-');
    }
    let ef = (v >> mb & (1u64 << eb) - 1) as i64;
    let mut m = v & (1u64 << mb) - 1;
    if ef == (1i64 << eb) - 1 {
        if m == 0 {
            o.push_str("infinity");
        } else if m == 1u64 << mb - 1 {
            o.push_str("nan");
        } else {
            o.push_str("nan:0x");
            o.push_hex(m, false);
        }
        return;
    }
    if ef == 0 && m == 0 {
        o.push_str("0x0p0");
        return;
    }
    let mut e = ef - bias;
    if ef == 0 {
        // Subnormal: shift the leading 1 up to the implicit bit.
        e = 1 - bias;
        while m >> mb == 0 {
            m <<= 1;
            e -= 1;
        }
        m &= (1u64 << mb) - 1;
    }
    o.push_str("0x1");
    if m != 0 {
        // The fraction as hex digits: mb bits padded to a whole digit, the trailing zeros dropped.
        let digits = (mb + 3) / 4;
        let mut f = m << digits * 4 - mb;
        let mut n = digits;
        while (f & 0xF) == 0 {
            f >>= 4;
            n -= 1;
        }
        o.push_byte(b'.');
        let mut k = n;
        while k > 0 {
            k -= 1;
            let d = (f >> 4 * k & 0xF) as u8;
            o.push_byte(
                if d < 10 {
                    b'0' + d;
                } else {
                    b'a' + d - 10;
                },
            );
        }
    }
    o.format_into("p{}", e);
}

// ---- Instructions ----

// The value type `w` names, 0 for none.
const fn val_type(w: str) u8 {
    return switch w {
        "i32" => w::I32,
        "i64" => w::I64,
        "f32" => w::F32,
        "f64" => w::F64,
        "v128" => w::V128,
        "funcref" => w::FUNCREF,
        _ => 0u8,
    };
}

/// The name of value type `t`.
pub(package) const fn type_name(t: u8) str<'static> {
    return switch t {
        w::I32 => "i32",
        w::I64 => "i64",
        w::F32 => "f32",
        w::F64 => "f64",
        w::V128 => "v128",
        _ => "funcref",
    };
}

/// A signature at `*i`: `(t, ...) -> (t, ...)`, its normalized text into `out` and its encoding (the
/// parameters' count and types, then the results') into `enc`.
pub(package) fn signature(s: str, i: &mut usize, out: &mut String, enc: &mut Vector<u8>) bool {
    out.clear();
    enc.truncate(0);
    for part in 0..2u32 {
        if part == 1 {
            ws(s, i);
            if !s.slice(*i, s.len()).starts_with("->") {
                return false;
            }
            *i += 2;
            out.push_str(" -> ");
        }
        if !eat(s, i, b'(') {
            return false;
        }
        out.push_byte(b'(');
        let mut tys = Vector::<u8>::new();
        if !eat(s, i, b')') {
            loop {
                let ty = val_type(word(s, i));
                if ty == 0 || ty == w::FUNCREF {
                    return false;
                }
                if tys.len() != 0 {
                    out.push_str(", ");
                }
                out.push_str(type_name(ty));
                tys.push(ty);
                if eat(s, i, b')') {
                    break;
                }
                if !eat(s, i, b',') {
                    return false;
                }
            }
        }
        out.push_byte(b')');
        w::uleb(enc, tys.len() as u64);
        enc.extend_copy(&tys);
    }
    return true;
}

// A symbol and an optional `+`/`-` addend at `*i`.
fn sym_ref(s: str, i: &mut usize, name: &mut String, addend: &mut i64) bool {
    let mut j = *i;
    let w0 = word(s, &mut j);
    if w0.len() == 0 || !is_ident(w0.byte_at(0), true) || w0.byte_at(0) == b'.' && w0.len() == 1 {
        return false;
    }
    name.clear();
    name.push_str(w0);
    *addend = 0;
    let mut k = j;
    ws(s, &mut k);
    if k < s.len() && (s.byte_at(k) == b'+' || s.byte_at(k) == b'-') {
        let neg = s.byte_at(k) == b'-';
        k += 1;
        let mut v: i64 = 0;
        if !int(s, &mut k, &mut v) {
            return false;
        }
        *addend = if neg {
            -v;
        } else {
            v;
        };
        j = k;
    }
    *i = j;
    return true;
}

/// Assemble instruction `text` onto `out`; the symbols it names into `fx` (their fields 0). False with
/// `err` set when no row takes it.
pub(package) fn assemble(text: str, out: &mut Vector<u8>, fx: &mut Vector<Fix>, err: &mut String) bool {
    let mut i: usize = 0;
    let mn = word(text, &mut i);
    let rows: []t::Row = t::ROWS;
    let mut ri: usize = 0;
    while ri < rows.len() && rows[ri].mn != mn {
        ri += 1;
    }
    if ri == rows.len() {
        err.format_into("unknown instruction '{}'", mn);
        return false;
    }
    let r = rows[ri];
    let mut n = t::Ins::new(ri as u32);
    let mut sym = String::new();
    let mut add: i64 = 0;
    let mut k1: u8 = 0xFF; // the relocation of field `a` (or a memarg's offset), when a symbol
    let mut ok = true;
    switch r.imm {
        t::K::NONE => {},
        t::K::BT => {
            let mut j = i;
            let wd = word(text, &mut j);
            n.a = 0x40;
            if wd.len() != 0 {
                n.a = val_type(wd);
                i = j;
                ok = n.a != 0;
            }
        },
        t::K::LABEL | t::K::LOCAL | t::K::SEG | t::K::LANE => {
            ok = int(text, &mut i, &mut n.a);
        },
        t::K::FUNC | t::K::GLOBAL => {
            if !int(text, &mut i, &mut n.a) {
                ok = sym_ref(text, &mut i, &mut sym, &mut add) && add == 0;
                k1 = if r.imm == t::K::FUNC {
                    w::R_FUNCTION_INDEX_LEB;
                } else {
                    w::R_GLOBAL_INDEX_LEB;
                };
                n.wide |= 1;
            }
        },
        t::K::CALLI => {
            // [table,] signature: the type and the table by relocation.
            let mut j = i;
            let mut tab = String::from_str("__indirect_function_table");
            let mut ta: i64 = 0;
            if sym_ref(text, &mut j, &mut sym, &mut ta) && eat(text, &mut j, b',') {
                tab = sym.clone();
                i = j;
            }
            let mut enc = Vector::<u8>::new();
            ok = signature(text, &mut i, &mut sym, &mut enc);
            n.wide = 3;
            fx.push(Fix { kind: w::R_TYPE_INDEX_LEB, name: sym.clone(), addend: 0, at: 0 });
            fx.push(Fix { kind: w::R_TABLE_NUMBER_LEB, name: tab, addend: 0, at: 0 });
        },
        t::K::BRTABLE => {
            ok = eat(text, &mut i, b'{');
            while ok {
                let mut v: i64 = 0;
                ok = int(text, &mut i, &mut v) && v >= 0 && v <= 0xFFFFFFFF;
                n.targets.push(v as u32);
                if eat(text, &mut i, b'}') {
                    break;
                }
                ok = ok && eat(text, &mut i, b',');
            }
        },
        t::K::MEM | t::K::MEMLANE => {
            n.a = r.al;
            let mut j = i;
            ws(text, &mut j);
            if j < text.len() && text.byte_at(j) != b':' && text.byte_at(j) != b',' {
                if !int(text, &mut i, &mut n.b) {
                    ok = sym_ref(text, &mut i, &mut sym, &mut add);
                    k1 = w::R_MEMORY_ADDR_LEB;
                    n.wide |= 2;
                }
            }
            ws(text, &mut i);
            if ok && text.slice(i, text.len()).starts_with(":p2align=") {
                i += 9;
                ok = int(text, &mut i, &mut n.a);
            }
            if ok && r.imm == t::K::MEMLANE {
                let mut l: i64 = 0;
                ok = eat(text, &mut i, b',') && int(text, &mut i, &mut l) && l >= 0;
                n.lo = l as u64;
            }
        },
        t::K::I32 | t::K::I64 => {
            if !int(text, &mut i, &mut n.a) {
                ok = r.imm == t::K::I32 && sym_ref(text, &mut i, &mut sym, &mut add);
                k1 = w::R_MEMORY_ADDR_SLEB;
                n.wide |= 1;
            } else if r.imm == t::K::I32 && n.a > 0x7FFFFFFF && n.a <= 0xFFFFFFFF {
                n.a -= 0x100000000; // an unsigned spelling of a 32-bit constant
            }
        },
        t::K::F32 | t::K::F64 => {
            let mut bits: u64 = 0;
            ok = float_bits(text, &mut i, r.imm == t::K::F64, &mut bits);
            n.a = bits as i64;
        },
        t::K::MEMIDX => {
            let mut v: i64 = 0;
            let mut j = i;
            if int(text, &mut j, &mut v) {
                ok = v == 0;
                i = j;
            }
        },
        t::K::MEMIDX2 => {
            let mut v: i64 = 0;
            let mut j = i;
            if int(text, &mut j, &mut v) {
                let mut v2: i64 = 0;
                ok = v == 0 && eat(text, &mut j, b',') && int(text, &mut j, &mut v2) && v2 == 0;
                i = j;
            }
        },
        t::K::V128 | t::K::SHUF => {
            ok = v128_lanes(text, &mut i, r.imm == t::K::SHUF, &mut n.lo, &mut n.hi);
        },
        t::K::SEGMEM => {
            let mut v: i64 = 0;
            ok = int(text, &mut i, &mut n.a) && eat(text, &mut i, b',') && int(text, &mut i, &mut v) && v == 0;
        },
        _ => {
            ok = false;
        },
    };
    ws(text, &mut i);
    if !ok || i != text.len() {
        err.format_into("bad operands in '{}'", text);
        return false;
    }
    let st = out.len();
    let mut f = t::Field { at: 0, wide: false };
    let mut f2 = t::Field { at: 0, wide: false };
    if !t::encode(&n, out, &mut f, &mut f2) {
        out.truncate(st);
        err.format_into("an operand out of range in '{}'", text);
        return false;
    }
    if r.imm == t::K::CALLI {
        let nf = fx.len();
        fx.index_mut(nf - 2).at = f.at;
        fx.index_mut(nf - 1).at = f2.at;
    } else if k1 != 0xFF {
        fx.push(Fix { kind: k1, name: sym, addend: add, at: f.at });
    }
    return true;
}

// The 16 bytes of `v128.const` (16, 8, 4 or 2 integer lanes, or 4 or 2 float lanes) or of a shuffle (16
// lane indices) at `*i`.
fn v128_lanes(s: str, i: &mut usize, shuf: bool, lo: &mut u64, hi: &mut u64) bool {
    let mut vals = Vector::<u64>::new();
    let mut flt = false;
    let mut j = *i;
    loop {
        let mut v: i64 = 0;
        let mut k = j;
        if int(s, &mut k, &mut v) {
            vals.push(v as u64);
        } else {
            // A float lane: its kind is fixed by the lane count, so the text is kept for later.
            flt = true;
            let mut bits: u64 = 0;
            if !float_bits(s, &mut k, true, &mut bits) {
                return false;
            }
            vals.push(bits);
        }
        j = k;
        if !eat(s, &mut j, b',') {
            break;
        }
        if vals.len() >= 16 {
            return false;
        }
    }
    let n = vals.len();
    if shuf && n != 16 || n != 16 && n != 8 && n != 4 && n != 2 || flt && n != 4 && n != 2 {
        return false;
    }
    if flt && n == 4 {
        // Float lanes of four: re-read as f32.
        vals.truncate(0);
        let mut k = *i;
        loop {
            let mut bits: u64 = 0;
            if !float_bits(s, &mut k, false, &mut bits) {
                return false;
            }
            vals.push(bits);
            if !eat(s, &mut k, b',') {
                break;
            }
        }
    }
    let lb = (16 / n) as u32 * 8;
    *lo = 0;
    *hi = 0;
    for k in 0..n {
        let x = if lb == 64 {
            vals[k];
        } else {
            vals[k] & (1u64 << lb) - 1;
        };
        let bit = k as u32 * lb;
        if bit < 64 {
            *lo |= x << bit;
        } else {
            *hi |= x << bit - 64;
        }
    }
    *i = j;
    return true;
}

/// Disassemble the instruction at `b[at..end]` onto `out`: its length, 0 when the table decodes none.
pub(package) fn disassemble(b: []u8, at: usize, end: usize, out: &mut String) u32 {
    let mut n = t::Ins::new(0);
    let len = t::decode(b, at, end, &mut n);
    if len != 0 {
        print_ins(&n, out);
    }
    return len;
}

/// Print instruction `n`.
pub(package) fn print_ins(n: &t::Ins, o: &mut String) {
    let rows: []t::Row = t::ROWS;
    let r = rows[n.row as usize];
    o.push_str(r.mn);
    switch r.imm {
        t::K::NONE | t::K::MEMIDX => {
            if r.imm == t::K::MEMIDX {
                o.push_str(" 0");
            }
        },
        t::K::BT => {
            if n.a != 0x40 {
                o.push_byte(b' ');
                o.push_str(type_name(n.a as u8));
            }
        },
        t::K::BRTABLE => {
            o.push_str(" {");
            for k in 0..n.targets.len() {
                if k != 0 {
                    o.push_str(", ");
                }
                o.push_u64(n.targets[k]);
            }
            o.push_byte(b'}');
        },
        t::K::CALLI => {
            o.format_into(" {}, {}", n.a, n.b);
        },
        t::K::MEM | t::K::MEMLANE => {
            o.format_into(" {}", n.b);
            if n.a != r.al as i64 {
                o.format_into(":p2align={}", n.a);
            }
            if r.imm == t::K::MEMLANE {
                o.format_into(", {}", n.lo);
            }
        },
        t::K::F32 | t::K::F64 => {
            o.push_byte(b' ');
            float_text(o, n.a as u64, r.imm == t::K::F64);
        },
        t::K::MEMIDX2 => {
            o.push_str(" 0, 0");
        },
        t::K::V128 | t::K::SHUF => {
            let lb: u32 = if r.imm == t::K::SHUF {
                8;
            } else {
                32;
            };
            let cnt = 128 / lb;
            for k in 0..cnt {
                o.push_str(
                    if k == 0 {
                        " ";
                    } else {
                        ", ";
                    },
                );
                let bit = k * lb;
                let x = if bit < 64 {
                    n.lo >> bit;
                } else {
                    n.hi >> bit - 64;
                };
                o.push_u64(x & (1u64 << lb) - 1);
            }
        },
        t::K::SEGMEM => {
            o.format_into(" {}, 0", n.a);
        },
        _ => {
            o.format_into(" {}", n.a);
        },
    };
}
