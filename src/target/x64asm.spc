// The x86-64 assembler and disassembler for one instruction in AT&T syntax, both from the instruction
// table (`x64tab`). The assembler tries each row of the mnemonic in table order and takes the first
// whose operands match and encode; an operand that names a symbol leaves its field 0 and records a
// fixup the caller resolves. The disassembler prints the row `x64tab::decode` finds.
import target::x64 as x;
import target::x64tab as t;

/// A symbol an instruction names: the relocation kind (`x::R_*`), the name as written, the field's
/// offset from the instruction's start, and the addend as `x64gen` gives its relocations (relative to
/// the field: the bytes to the instruction's end subtracted).
pub struct Fix {
    pub kind: u8,
    pub name: String,
    pub at: u32,
    pub addend: i64,
}

pub const FX_NONE: u8 = 0;

/// No resolved branch target: `assemble`'s `tgt` when the caller knows none.
pub const NOTGT: i64 = 0x7FFFFFFFFFFFFFFF;

extend Fix {
    pub fn new() Fix {
        return Fix { kind: FX_NONE, name: String::new(), at: 0, addend: 0 };
    }
}

const R64: [str<'static>; 16] = [
    "rax",
    "rcx",
    "rdx",
    "rbx",
    "rsp",
    "rbp",
    "rsi",
    "rdi",
    "r8",
    "r9",
    "r10",
    "r11",
    "r12",
    "r13",
    "r14",
    "r15",
];
const R32: [str<'static>; 16] = [
    "eax",
    "ecx",
    "edx",
    "ebx",
    "esp",
    "ebp",
    "esi",
    "edi",
    "r8d",
    "r9d",
    "r10d",
    "r11d",
    "r12d",
    "r13d",
    "r14d",
    "r15d",
];
const R16: [str<'static>; 16] = [
    "ax",
    "cx",
    "dx",
    "bx",
    "sp",
    "bp",
    "si",
    "di",
    "r8w",
    "r9w",
    "r10w",
    "r11w",
    "r12w",
    "r13w",
    "r14w",
    "r15w",
];
const R8: [str<'static>; 20] = [
    "al",
    "cl",
    "dl",
    "bl",
    "spl",
    "bpl",
    "sil",
    "dil",
    "r8b",
    "r9b",
    "r10b",
    "r11b",
    "r12b",
    "r13b",
    "r14b",
    "r15b",
    "ah",
    "ch",
    "dh",
    "bh",
];
const CC_NAMES: [str<'static>; 16] = [
    "o",
    "no",
    "b",
    "ae",
    "e",
    "ne",
    "be",
    "a",
    "s",
    "ns",
    "p",
    "np",
    "l",
    "ge",
    "le",
    "g",
];

// Other spellings of the conditions.
struct Alias {
    pub name: str<'static>,
    pub cc: u8,
}

const CC_ALIASES: [Alias; 14] = [
    Alias { name: "c", cc: 2 },
    Alias { name: "nae", cc: 2 },
    Alias { name: "nb", cc: 3 },
    Alias { name: "nc", cc: 3 },
    Alias { name: "z", cc: 4 },
    Alias { name: "nz", cc: 5 },
    Alias { name: "na", cc: 6 },
    Alias { name: "nbe", cc: 7 },
    Alias { name: "pe", cc: 10 },
    Alias { name: "po", cc: 11 },
    Alias { name: "nge", cc: 12 },
    Alias { name: "nl", cc: 13 },
    Alias { name: "ng", cc: 14 },
    Alias { name: "nle", cc: 15 },
];

/// The name of condition `c`.
pub const fn cond_name(c: u8) str<'static> {
    let n: []str<'static> = CC_NAMES;
    return n[c as usize];
}

// The condition `w` names, -1 for none.
const fn cond_of(w: str) i32 {
    let n: []str<'static> = CC_NAMES;
    for i in 0..n.len() {
        if n[i] == w {
            return i as i32;
        }
    }
    let a: []Alias = CC_ALIASES;
    for i in 0..a.len() {
        if a[i].name == w {
            return a[i].cc;
        }
    }
    return -1;
}

// ---- Lexing ----

const fn lower(c: u8) u8 {
    if c >= b'A' && c <= b'Z' {
        return c + 32;
    }
    return c;
}

const fn is_ident(c: u8, first: bool) bool {
    return c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c == b'_' || c == b'.' || c == b'$' || !first && c >= b'0' && c <= b'9';
}

// Skip spaces and tabs at `*i`.
const fn ws(s: str, i: &mut usize) {
    while *i < s.len() && (s.byte_at(*i) == b' ' || s.byte_at(*i) == b'\t') {
        *i += 1;
    }
}

// Consume byte `c` after spaces; false when it is not next.
const fn eat(s: str, i: &mut usize, c: u8) bool {
    let mut j = *i;
    ws(s, &mut j);
    if j < s.len() && s.byte_at(j) == c {
        *i = j + 1;
        return true;
    }
    return false;
}

// The identifier at `*i` after spaces, empty when none.
const fn word<'a>(s: str<'a>, i: &mut usize) str<'a> {
    ws(s, i);
    let st = *i;
    while *i < s.len() && is_ident(s.byte_at(*i), *i == st) {
        *i += 1;
    }
    return s.slice(st, *i);
}

// An unsigned number at `*i`: decimal, `0x` hexadecimal or `0b` binary.
const fn unsigned(s: str, i: &mut usize, out: &mut i64) bool {
    let mut j = *i;
    let mut radix: u64 = 10;
    if j + 1 < s.len() && s.byte_at(j) == b'0' && lower(s.byte_at(j + 1)) == b'x' {
        radix = 16;
        j += 2;
    } else if j + 2 < s.len() && s.byte_at(j) == b'0' && lower(s.byte_at(j + 1)) == b'b' && (s.byte_at(j + 2) == b'0' || s.byte_at(
        j + 2,
    ) == b'1') {
        radix = 2;
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
    if j == st || j < s.len() && is_ident(s.byte_at(j), false) {
        return false;
    }
    *out = v as i64;
    *i = j;
    return true;
}

// ---- Operands ----

// Operand forms.
struct P {}

extend P {
    pub const REG: u8 = 1;
    pub const MEM: u8 = 2; // memory, or a bare expression (a branch target)
    pub const IMM: u8 = 3;
}

// Register classes.
struct C {}

extend C {
    pub const GP: u8 = 1;
    pub const X: u8 = 2;
    pub const Y: u8 = 3;
    pub const Z: u8 = 4;
    pub const K: u8 = 5;
}

// A parsed operand.
struct Opd {
    pub p: u8,
    pub cls: u8,
    pub size: u8, // a general register's size in bytes
    pub r: u8,
    pub star: bool, // `*`: an indirect branch target
    pub bare: bool, // memory without a parenthesized base: an absolute address or a branch target
    pub dot: bool, // a bare `.`-relative expression
    pub sym: bool, // the displacement or target names a symbol (the instruction's `Fix`)
    pub seg: u8,
    pub vsib: u8, // the class of a vector index (`C::X` .. `C::Z`), 0 for none
    pub m: x::Mem,
    pub v: i64,
}

extend Opd as Copy {}

extend Opd {
    const fn new() Opd {
        return Opd {
            p: 0,
            cls: 0,
            size: 0,
            r: 0,
            star: false,
            bare: false,
            dot: false,
            sym: false,
            seg: 0,
            vsib: 0,
            m: x::at(t::NOREG, 0),
            v: 0,
        };
    }
}

// The register named `w` (lowercase, without `%`): its class, size and number; false for none.
fn reg_name(w: str, o: &mut Opd) bool {
    let mut size: u8 = 8;
    while size != 0 {
        for i in 0..20usize {
            if gp_name(i, size) == w && w.len() != 0 {
                o.p = P::REG;
                o.cls = C::GP;
                o.size = size;
                o.r = if i >= 16 {
                    t::AH + (i - 16) as u8;
                } else {
                    i as u8;
                };
                return true;
            }
        }
        size /= 2;
    }
    if w.len() == 2 && w.byte_at(0) == b'k' && w.byte_at(1) >= b'0' && w.byte_at(1) <= b'7' {
        o.p = P::REG;
        o.cls = C::K;
        o.r = w.byte_at(1) - b'0';
        return true;
    }
    let c = if w.starts_with("xmm") {
        C::X;
    } else if w.starts_with("ymm") {
        C::Y;
    } else if w.starts_with("zmm") {
        C::Z;
    } else {
        0u8;
    };
    if c == 0 || w.len() < 4 || w.len() > 5 {
        return false;
    }
    let mut j: usize = 3;
    let mut n: i64 = 0;
    if !unsigned(w, &mut j, &mut n) || j != w.len() || n > 15 || w.len() == 5 && w.byte_at(3) == b'0' {
        return false;
    }
    o.p = P::REG;
    o.cls = c;
    o.r = n as u8;
    return true;
}

// The segment prefix byte of register name `w`, 0 for none.
const fn seg_of(w: str) u8 {
    return switch w {
        "es" => 0x26u8,
        "cs" => 0x2Eu8,
        "ss" => 0x36u8,
        "ds" => 0x3Eu8,
        "fs" => 0x64u8,
        "gs" => 0x65u8,
        _ => 0u8,
    };
}

// `%name` at `*i` (after spaces): the name, lowercase.
fn percent_name(s: str, i: &mut usize, out: &mut String) bool {
    let mut j = *i;
    ws(s, &mut j);
    if j >= s.len() || s.byte_at(j) != b'%' {
        return false;
    }
    j += 1;
    let st = j;
    while j < s.len() && (is_ident(s.byte_at(j), false) && s.byte_at(j) != b'.' && s.byte_at(j) != b'$') {
        j += 1;
    }
    if j == st {
        return false;
    }
    out.clear();
    out.push_str(s.slice(st, j));
    out.to_ascii_lower();
    *i = j;
    return true;
}

// A displacement expression at `*i`: a number, `.`, or a symbol (with an `@` specifier), then
// optional `+` or `-` terms of numbers. `o.dot` for `.`, `o.sym` with `fx` for a symbol.
fn expr(s: str, i: &mut usize, o: &mut Opd, fx: &mut Fix, spec: &mut String) bool {
    let mut j = *i;
    ws(s, &mut j);
    let mut v: i64 = 0;
    let mut first = true;
    loop {
        ws(s, &mut j);
        let mut neg = false;
        if j < s.len() && (s.byte_at(j) == b'-' || s.byte_at(j) == b'+') {
            neg = s.byte_at(j) == b'-';
            j += 1;
            ws(s, &mut j);
        } else if !first {
            break;
        }
        if j >= s.len() {
            return false;
        }
        let c = s.byte_at(j);
        let mut n: i64 = 0;
        if c >= b'0' && c <= b'9' {
            // A numeric local label (`1f`, `1b`) or a number.
            let mut k = j;
            while k < s.len() && s.byte_at(k) >= b'0' && s.byte_at(k) <= b'9' {
                k += 1;
            }
            if first && !neg && k < s.len() && (lower(s.byte_at(k)) == b'f' || lower(s.byte_at(k)) == b'b') && (k + 1 >= s.len() || !is_ident(
                s.byte_at(k + 1),
                false,
            )) {
                o.sym = true;
                fx.name = String::from_str(s.slice(j, k + 1));
                j = k + 1;
            } else {
                if !unsigned(s, &mut j, &mut n) {
                    return false;
                }
                v = if neg {
                    v.wrapping_sub(n);
                } else {
                    v.wrapping_add(n);
                };
            }
        } else if first && !neg && c == b'.' && (j + 1 >= s.len() || !is_ident(s.byte_at(j + 1), false)) {
            o.dot = true;
            j += 1;
        } else if first && !neg && is_ident(c, true) {
            let w = word(s, &mut j);
            o.sym = true;
            fx.name = String::from_str(w);
            if j < s.len() && s.byte_at(j) == b'@' {
                j += 1;
                let sp = word(s, &mut j);
                spec.clear();
                spec.push_str(sp);
                spec.to_ascii_lower();
            }
        } else {
            return false;
        }
        first = false;
    }
    o.v = v;
    *i = j;
    return true;
}

// One operand at `*i`.
fn operand(s: str, i: &mut usize, o: &mut Opd, fx: &mut Fix, spec: &mut String) bool {
    *o = Opd::new();
    o.star = eat(s, i, b'*');
    let mut nm = String::new();
    if eat(s, i, b'$') {
        o.p = P::IMM;
        let mut e = Opd::new();
        if !expr(s, i, &mut e, fx, spec) || e.dot || e.sym {
            return false;
        }
        o.v = e.v;
        return true;
    }
    let save = *i;
    if percent_name(s, i, &mut nm) {
        let sg = seg_of(nm.as_str());
        if sg != 0 && eat(s, i, b':') {
            o.seg = sg;
        } else {
            return reg_name(nm.as_str(), o);
        }
    } else {
        *i = save;
    }
    // Memory: [disp](base, index, scale), or a bare expression.
    o.p = P::MEM;
    let mut j = *i;
    ws(s, &mut j);
    if j < s.len() && s.byte_at(j) != b'(' {
        if !expr(s, &mut j, o, fx, spec) {
            return false;
        }
    }
    o.m.disp = o.v as i32;
    if o.v != o.m.disp as i64 && !(o.v >= 0 && o.v <= 0xFFFFFFFF) {
        return false;
    }
    if !eat(s, &mut j, b'(') {
        o.bare = true;
        *i = j;
        return true;
    }
    if o.dot {
        return false;
    }
    let mut r = Opd::new();
    if percent_name(s, &mut j, &mut nm) {
        if nm.eq_str("rip") {
            o.m.base = x::RIP;
        } else if !reg_name(nm.as_str(), &mut r) || r.cls != C::GP || r.size != 8 {
            return false;
        } else {
            o.m.base = r.r;
        }
    }
    if eat(s, &mut j, b',') {
        if !percent_name(s, &mut j, &mut nm) || !reg_name(nm.as_str(), &mut r) || o.m.base == x::RIP {
            return false;
        }
        // A general index, or a vector one (VSIB).
        if r.cls == C::X || r.cls == C::Y || r.cls == C::Z {
            o.vsib = r.cls;
        } else if r.cls != C::GP || r.size != 8 || r.r == x::RSP {
            return false;
        }
        o.m.index = r.r;
        if eat(s, &mut j, b',') {
            ws(s, &mut j);
            let mut sc: i64 = 0;
            if !unsigned(s, &mut j, &mut sc) {
                return false;
            }
            o.m.scale = (switch sc {
                1 => 0u8,
                2 => 1u8,
                4 => 2u8,
                8 => 3u8,
                _ => 9u8,
            });
            if o.m.scale > 3 {
                return false;
            }
        }
    }
    if !eat(s, &mut j, b')') {
        return false;
    }
    *i = j;
    return true;
}

// The mnemonic forms of row `r` that `mn` spells: its size suffix (0: none) and condition.
fn spells(r: t::Row, mn: str, sz: &mut u8, cc: &mut u8) bool {
    *sz = 0;
    *cc = 0;
    if !mn.starts_with(r.mn) {
        return false;
    }
    let rest = mn.slice(r.mn.len(), mn.len());
    let sfx = (r.fl & t::F_NOSFX) == 0;
    if (r.fl & t::F_CC) != 0 {
        let c = cond_of(rest);
        if c >= 0 {
            *cc = c as u8;
            return true;
        }
        if !sfx || rest.len() < 2 {
            return false;
        }
        let c2 = cond_of(rest.slice(0, rest.len() - 1));
        if c2 < 0 {
            return false;
        }
        *cc = c2 as u8;
        *sz = suffix(rest.byte_at(rest.len() - 1));
        return *sz != 0;
    }
    if rest.len() == 0 {
        return true;
    }
    if !sfx || rest.len() != 1 {
        return false;
    }
    *sz = suffix(rest.byte_at(0));
    return *sz != 0;
}

const fn suffix(c: u8) u8 {
    return switch c {
        b'b' => 1u8,
        b'w' => 2u8,
        b'l' => 4u8,
        b'q' => 8u8,
        _ => 0u8,
    };
}

// Whether operand `o` fits kind `k`; a general register's size goes to `*sz` (0 until one sets it).
fn fits(k: u8, o: &Opd, sz: &mut u8) bool {
    let gp = o.p == P::REG && o.cls == C::GP && !o.star;
    let mem = o.p == P::MEM && !o.bare && !o.star && o.vsib == 0;
    if o.star && k != t::K::IND || o.p == P::MEM && o.bare && k != t::K::REL8 && k != t::K::REL32 && !(o.seg != 0 || !o.dot && !o.sym) {
        return false;
    }
    let absmem = o.p == P::MEM && o.bare && !o.dot && !o.sym && !o.star;
    let anymem = mem || absmem;
    let vreg = o.p == P::REG && !o.star;
    return switch k {
        t::K::R | t::K::O => gp && sized(o.size, sz),
        t::K::ACC => gp && o.r == 0 && sized(o.size, sz),
        t::K::RM => anymem || gp && sized(o.size, sz),
        t::K::M => anymem,
        t::K::RM8 => anymem || gp && o.size == 1,
        t::K::RM16 => anymem || gp && o.size == 2,
        t::K::RM32 => anymem || gp && o.size == 4,
        t::K::R32 => gp && o.size == 4,
        t::K::X | t::K::XR | t::K::XV | t::K::XI4 => vreg && o.cls == C::X,
        t::K::XM => anymem || vreg && o.cls == C::X,
        t::K::X0 => vreg && o.cls == C::X && o.r == 0,
        t::K::Y | t::K::YR | t::K::YV | t::K::YI4 => vreg && o.cls == C::Y,
        t::K::YM => anymem || vreg && o.cls == C::Y,
        t::K::Z | t::K::ZR | t::K::ZV => vreg && o.cls == C::Z,
        t::K::ZM => anymem || vreg && o.cls == C::Z,
        t::K::KR | t::K::KRM | t::K::KV => vreg && o.cls == C::K,
        t::K::R64 | t::K::RR64 => gp && o.size == 8,
        t::K::RR32 => gp && o.size == 4,
        t::K::RM64 => anymem || gp && o.size == 8,
        t::K::VSX => o.p == P::MEM && !o.bare && !o.star && o.vsib == C::X,
        t::K::VSY => o.p == P::MEM && !o.bare && !o.star && o.vsib == C::Y,
        t::K::VSZ => o.p == P::MEM && !o.bare && !o.star && o.vsib == C::Z,
        t::K::I8 | t::K::IS8 | t::K::IZ | t::K::I64 => o.p == P::IMM,
        t::K::CL => gp && o.size == 1 && o.r == 1,
        t::K::ONE => o.p == P::IMM && o.v == 1,
        t::K::REL8 | t::K::REL32 => o.p == P::MEM && o.bare && o.seg == 0 && !o.star && (o.dot || o.sym),
        t::K::IND => o.star && (o.p == P::REG && o.cls == C::GP && o.size == 8 || o.p == P::MEM && (!o.bare || !o.dot && !o.sym)),
        _ => false,
    };
}

// Whether general register size `s` agrees with the size so far, `*sz` (0: none yet); it becomes it.
fn sized(s: u8, sz: &mut u8) bool {
    if *sz != 0 && *sz != s {
        return false;
    }
    *sz = s;
    return true;
}

// The relocation kind of a symbol in a branch target (`rel`) or a RIP-relative operand with specifier
// `spec` (empty: none), 0xFF for none.
fn reloc_kind(rel: bool, spec: str, rex: bool) u8 {
    if rel {
        return if spec.len() == 0 || spec == "plt" {
            x::R_PLT32;
        } else {
            0xFFu8;
        };
    }
    return switch spec {
        "" => x::R_PC32,
        "gotpcrel" => if rex {
            x::R_REX_GOTPCRELX;
        } else {
            x::R_GOTPCRELX;
        },
        "tlsgd" => x::R_TLSGD,
        _ => 0xFFu8,
    };
}

/// Assemble the instruction `text` (AT&T syntax) onto `out`; `tgt` is the offset from the
/// instruction's start of the branch target it names (`NOTGT` when the caller knows none: the symbol
/// becomes `fx`). False with `err` set when no row takes it.
pub fn assemble(text: str, tgt: i64, out: &mut Vector<u8>, fx: &mut Fix, err: &mut String) bool {
    let mut i: usize = 0;
    let mut lock = false;
    let mut d16: u8 = 0;
    let mut rexw = false;
    let mut disp: u8 = 0;
    let mut kmask: u8 = 0;
    let mut zero = false;
    let mut mn = String::new();
    // Prefixes, then the mnemonic.
    loop {
        ws(text, &mut i);
        if i < text.len() && text.byte_at(i) == b'{' {
            let st = i;
            while i < text.len() && text.byte_at(i) != b'}' {
                i += 1;
            }
            let pf = text.slice(
                st,
                if i < text.len() {
                    i + 1;
                } else {
                    i;
                },
            );
            i += 1;
            if pf == "{disp8}" {
                disp = 8;
            } else if pf == "{disp32}" {
                disp = 32;
            } else {
                err.format_into("unknown pseudo prefix '{}'", pf);
                return false;
            }
            continue;
        }
        let w = word(text, &mut i);
        mn.clear();
        mn.push_str(w);
        mn.to_ascii_lower();
        if mn.eq_str("lock") {
            lock = true;
        } else if mn.eq_str("data16") {
            d16 += 1;
        } else if mn.eq_str("rex64") {
            rexw = true;
        } else {
            break;
        }
    }
    if mn.len() == 0 {
        // Prefixes alone: their bytes.
        ws(text, &mut i);
        if i != text.len() || disp != 0 {
            err.format_into("expected an instruction in '{}'", text);
            return false;
        }
        if lock {
            out.push(0xF0);
        }
        for _ in 0..d16 {
            out.push(0x66);
        }
        if rexw {
            out.push(0x48);
        }
        return true;
    }
    // Operands, in Intel order.
    let mut ops = Vector::<Opd>::new();
    let mut spec = String::new();
    fx.kind = FX_NONE;
    fx.name.clear();
    fx.at = 0;
    fx.addend = 0;
    ws(text, &mut i);
    if i < text.len() {
        loop {
            let mut o = Opd::new();
            if !operand(text, &mut i, &mut o, fx, &mut spec) {
                err.format_into("bad operand in '{}'", text);
                return false;
            }
            ops.push(o);
            if !eat(text, &mut i, b',') {
                break;
            }
        }
        // An EVEX mask `{%kN}` and zeroing `{z}`.
        while eat(text, &mut i, b'{') {
            let mut d = String::new();
            let mut ko = Opd::new();
            if percent_name(text, &mut i, &mut d) && reg_name(d.as_str(), &mut ko) && ko.cls == C::K && ko.r != 0 && kmask == 0 {
                kmask = ko.r;
            } else if eat(text, &mut i, b'z') && !zero {
                zero = true;
            } else {
                err.format_into("bad operand in '{}'", text);
                return false;
            }
            if !eat(text, &mut i, b'}') {
                err.format_into("bad operand in '{}'", text);
                return false;
            }
        }
        ws(text, &mut i);
        if i != text.len() || ops.len() > 4 {
            err.format_into("bad operands in '{}'", text);
            return false;
        }
    }
    ops.reverse();
    let nsym = fx.name.len() != 0;
    let rows: []t::Row = t::ROWS;
    let mut seen = false;
    let mut buf = Vector::<u8>::with_capacity(16);
    for ri in 0..rows.len() {
        let r = rows[ri];
        let mut sfx: u8 = 0;
        let mut cc: u8 = 0;
        if !spells(r, mn.as_str(), &mut sfx, &mut cc) {
            continue;
        }
        seen = true;
        let mut nk: usize = 0;
        while nk < 4 && t::kind_at(r.ops, nk as u32) != 0 {
            nk += 1;
        }
        // `shl %eax` is `shl $1, %eax`.
        let implicit_one = nk == ops.len() + 1 && t::kind_at(r.ops, (nk - 1) as u32) == t::K::ONE;
        if nk != ops.len() && !implicit_one {
            continue;
        }
        let mut sz: u8 = 0;
        let mut ok = true;
        let mut n = t::Ins::new(ri as u32);
        for k in 0..ops.len() {
            let kd = t::kind_at(r.ops, k as u32);
            let o = ops[k];
            if !fits(kd, &o, &mut sz) {
                ok = false;
                break;
            }
            if o.p == P::REG {
                n.set_reg(k as u32, o.r);
            } else if o.p == P::MEM && kd != t::K::REL8 && kd != t::K::REL32 {
                n.mem_at = k as u8;
                n.m = o.m;
                n.seg = o.seg;
            } else {
                n.imm = o.v;
            }
        }
        if !ok {
            continue;
        }
        if sfx != 0 {
            if sz != 0 && sz != sfx {
                continue;
            }
            sz = sfx;
        }
        if r.sz == 0 {
            if sz != 0 && sfx != 0 {
                continue;
            }
            sz = 0;
        } else if sz == 0 {
            if r.sz == t::SB || r.sz == t::SW || r.sz == t::SL || r.sz == t::SQ {
                sz = r.sz;
            } else if (r.fl & t::F_D64) != 0 {
                sz = 8;
            } else {
                continue;
            }
        }
        if implicit_one {
            n.imm = 1;
        }
        n.sz = sz;
        n.cc = cc;
        n.lock = lock;
        n.data16 = d16;
        n.rexw = rexw;
        n.disp = disp;
        n.kmask = kmask;
        n.zero = zero;
        let kl = t::kind_at(r.ops, 0);
        let rel = kl == t::K::REL8 || kl == t::K::REL32;
        if rel {
            let o = ops[0];
            if o.sym && tgt != NOTGT {
                n.imm = tgt + o.v;
            } else if o.sym {
                n.disp = 32;
                n.imm = 0;
            }
        }
        buf.truncate(0);
        let mut e = t::Enc::new();
        if !t::encode(&n, &mut buf, &mut e) {
            continue;
        }
        if nsym && !(rel && tgt != NOTGT) {
            // The symbol's field: a branch offset or a RIP displacement.
            let rex = n.sz == 8 && (r.fl & t::F_D64) == 0 || n.rexw || buf.len() > 0 && (buf[0] & 0xF0) == 0x40;
            let kind = reloc_kind(rel, spec.as_str(), rex);
            if kind == 0xFF || e.field == t::NOFIELD || !rel && n.m.base != x::RIP {
                err.format_into("a symbol where '{}' takes none", text);
                return false;
            }
            for b in 0..4u32 {
                buf.set((e.field + b) as usize, 0);
            }
            fx.kind = kind;
            fx.at = e.field;
            let user = if rel {
                ops[0].v;
            } else {
                n.m.disp as i64;
            };
            fx.addend = user + e.field as i64 - e.len as i64;
        }
        out.extend_copy(&buf);
        return true;
    }
    if seen {
        err.format_into("no form of '{}' takes the operands in '{}'", mn.as_str(), text);
    } else {
        err.format_into("unknown instruction '{}'", mn.as_str());
    }
    return false;
}

// ---- Printing ----

// The name of general register `i` (16 + n for ah..bh) of `size` bytes, empty past the last.
fn gp_name(i: usize, size: u8) str<'static> {
    let n8: []str<'static> = R8;
    let n16: []str<'static> = R16;
    let n32: []str<'static> = R32;
    let n64: []str<'static> = R64;
    if size == 1 {
        return if i < n8.len() {
            n8[i];
        } else {
            "";
        };
    }
    if i >= 16 {
        return "";
    }
    return switch size {
        2 => n16[i],
        4 => n32[i],
        _ => n64[i],
    };
}

// The name of general register `g` of `size` bytes.
fn gp_text(o: &mut String, g: u8, size: u8) {
    o.push_byte(b'%');
    o.push_str(
        gp_name(
            if g >= t::AH {
                (g - t::AH + 16) as usize;
            } else {
                g as usize;
            },
            size,
        ),
    );
}

// Memory operand `m` with segment prefix `seg`; `vs` is a vector index's width in bytes (0: none).
fn mem_text(o: &mut String, m: x::Mem, seg: u8, vs: u32) {
    if seg != 0 {
        o.push_str(
            switch seg {
                0x26 => "%es:",
                0x2E => "%cs:",
                0x36 => "%ss:",
                0x3E => "%ds:",
                0x64 => "%fs:",
                _ => "%gs:",
            },
        );
    }
    if m.base == t::NOREG && m.index == t::NOREG {
        o.push_i64(m.disp);
        return;
    }
    if m.disp != 0 {
        o.push_i64(m.disp);
    }
    o.push_byte(b'(');
    if m.base == x::RIP {
        o.push_str("%rip");
    } else if m.base != t::NOREG {
        gp_text(o, m.base, 8);
    }
    if m.index != t::NOREG {
        o.push_str(",");
        if vs != 0 {
            vec_text(o, m.index, vs);
        } else {
            gp_text(o, m.index, 8);
        }
        o.format_into(",{}", 1u32 << m.scale);
    }
    o.push_byte(b')');
}

// Vector register `n` of `vs` bytes.
fn vec_text(o: &mut String, n: u8, vs: u32) {
    o.format_into(
        "%{}mm{}",
        switch vs {
            16 => "x",
            32 => "y",
            _ => "z",
        },
        n,
    );
}

/// Disassemble the instruction at `b[at..]` onto `out`: its length, 0 when the table decodes none.
pub fn disassemble(b: []u8, at: usize, out: &mut String) u32 {
    let mut n = t::Ins::new(0);
    let len = t::decode(b, at, &mut n);
    if len != 0 {
        print_ins(&n, out);
    }
    return len;
}

/// Print instruction `n` in AT&T syntax.
pub fn print_ins(n: &t::Ins, o: &mut String) {
    let rows: []t::Row = t::ROWS;
    let r = rows[n.row as usize];
    if n.lock {
        o.push_str("lock ");
    }
    for _ in 0..n.data16 {
        o.push_str("data16 ");
    }
    if n.rexw {
        o.push_str("rex64 ");
    }
    if n.disp == 8 {
        o.push_str("{disp8} ");
    } else if n.disp == 32 {
        o.push_str("{disp32} ");
    }
    o.push_str(r.mn);
    if (r.fl & t::F_CC) != 0 {
        o.push_str(cond_name(n.cc));
    }
    if (r.fl & t::F_NOSFX) == 0 && n.sz != 0 {
        o.push_byte(
            switch n.sz {
                1 => b'b',
                2 => b'w',
                4 => b'l',
                _ => b'q',
            },
        );
    }
    let mut nk: u32 = 0;
    while nk < 4 && t::kind_at(r.ops, nk) != 0 {
        nk += 1;
    }
    // AT&T order: the last Intel operand first.
    let mut first = true;
    let mut k = nk;
    while k > 0 {
        k -= 1;
        let kd = t::kind_at(r.ops, k);
        o.push_str(
            if first {
                " ";
            } else {
                ", ";
            },
        );
        first = false;
        if kd == t::K::IND {
            o.push_byte(b'*');
        }
        if n.mem_at as u32 == k {
            mem_text(
                o,
                n.m,
                n.seg,
                if t::is_vsib(kd) {
                    t::vec_size(kd);
                } else {
                    0u32;
                },
            );
            continue;
        }
        let gs = t::gp_size(kd, n.sz);
        if gs != 0 {
            gp_text(o, n.reg(k), gs);
            continue;
        }
        let vs = t::vec_size(kd);
        if vs != 0 {
            vec_text(o, n.reg(k), vs);
            continue;
        }
        if t::is_kreg(kd) {
            o.format_into("%k{}", n.reg(k));
            continue;
        }
        if kd == t::K::ONE {
            o.push_str("$1");
        } else if kd == t::K::REL8 || kd == t::K::REL32 {
            o.push_str(
                if n.imm < 0 {
                    ".-";
                } else {
                    ".+";
                },
            );
            o.push_u64(
                if n.imm < 0 {
                    (n.imm as u64).wrapping_neg();
                } else {
                    n.imm as u64;
                },
            );
        } else {
            o.push_byte(b'$');
            o.push_i64(n.imm);
        }
    }
    if n.kmask != 0 {
        o.format_into(" {{%k{}}}", n.kmask);
    }
    if n.zero {
        o.push_str(" {z}");
    }
}
