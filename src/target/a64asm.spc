// The arm64 assembler and disassembler for one instruction in GNU syntax, both from the instruction
// table (`a64tab`). The assembler tries each row of the mnemonic in table order and takes the first
// whose operands parse and encode; an operand that names a symbol or a label leaves its field 0 and
// records a fixup the caller resolves. The disassembler prints the first row a word matches.
import target::a64 as a;
import target::a64tab as t;

/// A symbol or label an instruction names: the relocation kind (`a::R_*`, or a `FX_*` kind only a
/// local label resolves), the name as written and the addend.
pub struct Fix {
    pub kind: u8,
    pub name: String,
    pub addend: i64,
}

pub const FX_NONE: u8 = 0;
/// A conditional branch, compare and branch, or test and branch: a label of the same section only.
pub const FX_B19: u8 = 100;
pub const FX_B14: u8 = 101;
pub const FX_ADR: u8 = 102;

extend Fix {
    pub fn new() Fix {
        return Fix { kind: FX_NONE, name: String::new(), addend: 0 };
    }
}

const COND_NAMES: [str<'static>; 16] = [
    "eq",
    "ne",
    "hs",
    "lo",
    "mi",
    "pl",
    "vs",
    "vc",
    "hi",
    "ls",
    "ge",
    "lt",
    "gt",
    "le",
    "al",
    "nv",
];
const SHIFT_NAMES: [str<'static>; 4] = ["lsl", "lsr", "asr", "ror"];
const EXT_NAMES: [str<'static>; 8] = ["uxtb", "uxth", "uxtw", "uxtx", "sxtb", "sxth", "sxtw", "sxtx"];
const ARR_NAMES: [str<'static>; 8] = ["8b", "16b", "4h", "8h", "2s", "4s", "1d", "2d"];
const ELEM: [str<'static>; 5] = ["b", "h", "s", "d", "q"];
const ZR_SP: [str<'static>; 4] = ["wzr", "xzr", "wsp", "sp"];

/// The name of condition `c`.
pub const fn cond_name(c: u32) str<'static> {
    let n: []str<'static> = COND_NAMES;
    return n[c as usize & 15];
}

// System registers by name: o0:op1:CRn:CRm:op2 (o0 is op0 - 2).
struct SysReg {
    pub name: str<'static>,
    pub enc: u32,
}

const fn sr(op0: u32, op1: u32, crn: u32, crm: u32, op2: u32) u32 {
    return op0 - 2 << 14 | op1 << 11 | crn << 7 | crm << 3 | op2;
}

const SYSREGS: [SysReg; 13] = [
    SysReg { name: "nzcv", enc: sr(3, 3, 4, 2, 0) },
    SysReg { name: "daif", enc: sr(3, 3, 4, 2, 1) },
    SysReg { name: "svcr", enc: sr(3, 3, 4, 2, 2) },
    SysReg { name: "fpcr", enc: sr(3, 3, 4, 4, 0) },
    SysReg { name: "fpsr", enc: sr(3, 3, 4, 4, 1) },
    SysReg { name: "tpidr_el0", enc: sr(3, 3, 13, 0, 2) },
    SysReg { name: "tpidrro_el0", enc: sr(3, 3, 13, 0, 3) },
    SysReg { name: "tpidr2_el0", enc: sr(3, 3, 13, 0, 5) },
    SysReg { name: "cntfrq_el0", enc: sr(3, 3, 14, 0, 0) },
    SysReg { name: "cntpct_el0", enc: sr(3, 3, 14, 0, 1) },
    SysReg { name: "cntvct_el0", enc: sr(3, 3, 14, 0, 2) },
    SysReg { name: "ctr_el0", enc: sr(3, 3, 0, 0, 1) },
    SysReg { name: "dczid_el0", enc: sr(3, 3, 0, 0, 7) },
];

// Barrier options by name (the CRm field).
struct Named {
    pub name: str<'static>,
    pub v: u32,
}

const BARRIERS: [Named; 12] = [
    Named { name: "sy", v: 15 },
    Named { name: "st", v: 14 },
    Named { name: "ld", v: 13 },
    Named { name: "ish", v: 11 },
    Named { name: "ishst", v: 10 },
    Named { name: "ishld", v: 9 },
    Named { name: "nsh", v: 7 },
    Named { name: "nshst", v: 6 },
    Named { name: "nshld", v: 5 },
    Named { name: "osh", v: 3 },
    Named { name: "oshst", v: 2 },
    Named { name: "oshld", v: 1 },
];

// SVE predicate patterns.
const PATTERNS: [Named; 17] = [
    Named { name: "pow2", v: 0 },
    Named { name: "vl1", v: 1 },
    Named { name: "vl2", v: 2 },
    Named { name: "vl3", v: 3 },
    Named { name: "vl4", v: 4 },
    Named { name: "vl5", v: 5 },
    Named { name: "vl6", v: 6 },
    Named { name: "vl7", v: 7 },
    Named { name: "vl8", v: 8 },
    Named { name: "vl16", v: 9 },
    Named { name: "vl32", v: 10 },
    Named { name: "vl64", v: 11 },
    Named { name: "vl128", v: 12 },
    Named { name: "vl256", v: 13 },
    Named { name: "mul4", v: 29 },
    Named { name: "mul3", v: 30 },
    Named { name: "all", v: 31 },
];

// ---- Lexing ----

const fn lower(c: u8) u8 {
    if c >= b'A' && c <= b'Z' {
        return c + 32;
    }
    return c;
}

// Whether `s` equals `w` with ASCII case ignored.
const fn eq_nocase(s: str, w: str) bool {
    if s.len() != w.len() {
        return false;
    }
    for i in 0..s.len() {
        if lower(s.byte_at(i)) != lower(w.byte_at(i)) {
            return false;
        }
    }
    return true;
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

// Whether the next byte after spaces is `c`.
const fn peek(s: str, i: usize, c: u8) bool {
    let mut j = i;
    ws(s, &mut j);
    return j < s.len() && s.byte_at(j) == c;
}

// The identifier at `*i` after spaces (letters, digits, `_`, `.`, `$`), empty when none.
const fn word<'a>(s: str<'a>, i: &mut usize) str<'a> {
    ws(s, i);
    let st = *i;
    while *i < s.len() && is_ident(s.byte_at(*i), *i == st) {
        *i += 1;
    }
    return s.slice(st, *i);
}

// A number at `*i` after spaces: optional `#`, sign, decimal, `0x` hexadecimal or `0b` binary.
const fn number(s: str, i: &mut usize, out: &mut i64) bool {
    let mut j = *i;
    ws(s, &mut j);
    if j < s.len() && s.byte_at(j) == b'#' {
        j += 1;
    }
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
    } else if j + 1 < s.len() && s.byte_at(j) == b'0' && lower(s.byte_at(j + 1)) == b'b' && j + 2 < s.len() && (s.byte_at(
        j + 2,
    ) == b'0' || s.byte_at(j + 2) == b'1') {
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
        v = v * radix + d;
        j += 1;
    }
    if j == st || j < s.len() && is_ident(s.byte_at(j), false) {
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

// ---- Registers ----

// The register named `w`: its letter (lowercase: x w b h s d q v z p), its number (31 for xzr, wzr,
// sp and wsp; 32 + n for pn<n>), and whether it is sp or wsp; letter 0 when `w` names none.
const fn reg_name(w: str, l: &mut u8, n: &mut i64, sp: &mut bool) {
    *l = 0;
    *sp = false;
    if eq_nocase(w, "sp") || eq_nocase(w, "wsp") {
        *l = if w.len() == 2 {
            b'x';
        } else {
            b'w';
        };
        *n = 31;
        *sp = true;
        return;
    }
    if eq_nocase(w, "xzr") || eq_nocase(w, "wzr") {
        *l = lower(w.byte_at(0));
        *n = 31;
        return;
    }
    if eq_nocase(w, "fp") || eq_nocase(w, "lr") {
        *l = b'x';
        *n = if lower(w.byte_at(0)) == b'f' {
            29i64;
        } else {
            30i64;
        };
        return;
    }
    if w.len() < 2 {
        return;
    }
    let c = lower(w.byte_at(0));
    let mut st: usize = 1;
    let mut pn = false;
    if c == b'p' && lower(w.byte_at(1)) == b'n' {
        st = 2;
        pn = true;
    }
    if c != b'x' && c != b'w' && c != b'b' && c != b'h' && c != b's' && c != b'd' && c != b'q' && c != b'v' && c != b'z' && c != b'p' {
        return;
    }
    let mut v: i64 = 0;
    if st >= w.len() || w.len() - st > 2 {
        return;
    }
    for k in st..w.len() {
        let d = w.byte_at(k);
        if d < b'0' || d > b'9' {
            return;
        }
        v = v * 10 + (d - b'0') as i64;
    }
    let max: i64 = if c == b'x' || c == b'w' {
        30;
    } else if c == b'p' && !pn {
        15;
    } else {
        31;
    };
    if v > max || pn && (v < 8 || v > 15) {
        return;
    }
    *l = c;
    *n = if pn {
        32 + v;
    } else {
        v;
    };
}

// A register token at `*i`: its name, then an optional `.T` suffix (`arr`: the arrangement or element
// code: 0..7 the vector arrangements, 10 + log2 bytes an element) and an optional `/z` or `/m` (`pq`
// 1 or 2).
struct Reg {
    pub l: u8,
    pub n: i64,
    pub sp: bool,
    pub arr: i32,
    pub pq: u8,
}

fn reg(s: str, i: &mut usize, r: &mut Reg) bool {
    let mut j = *i;
    let w = word(s, &mut j);
    // `word` stops at no dot only when the token holds none: split the suffix off.
    let dot = w.find_byte(b'.');
    let name = if dot >= 0 {
        w.slice(0, dot as usize);
    } else {
        w;
    };
    let mut l: u8 = 0;
    let mut n: i64 = 0;
    let mut sp = false;
    reg_name(name, &mut l, &mut n, &mut sp);
    if l == 0 {
        return false;
    }
    r.l = l;
    r.n = n;
    r.sp = sp;
    r.arr = -1;
    r.pq = 0;
    if dot >= 0 {
        let sfx = w.slice(dot as usize + 1, w.len());
        let ar: []str<'static> = ARR_NAMES;
        let el: []str<'static> = ELEM;
        for k in 0..ar.len() {
            if eq_nocase(sfx, ar[k]) {
                r.arr = k as i32;
            }
        }
        for k in 0..el.len() {
            if eq_nocase(sfx, el[k]) {
                r.arr = 10 + k as i32;
            }
        }
        if r.arr < 0 {
            return false;
        }
    }
    if j < s.len() && s.byte_at(j) == b'/' && j + 1 < s.len() {
        let c = lower(s.byte_at(j + 1));
        if c == b'z' || c == b'm' {
            r.pq = if c == b'z' {
                1u8;
            } else {
                2u8;
            };
            j += 2;
        }
    }
    *i = j;
    return true;
}

// ---- Parsing operands ----

// What the sized operands say about the variant: the general register width (0 w, 1 x), the float
// register size (log2 of bytes), the vector arrangement, the SVE element; -1 when no operand says.
struct Facts {
    pub gw: i32,
    pub fs: i32,
    pub arr: i32,
    pub ze: i32,
    pub rmx: i32, // the width K::RMX's register has
    pub rtb: i32, // the width K::RTB's register has
    pub felem: i32, // the element K::FELEM's register has
}

// Set fact `f` to `v`; false when it holds another value.
const fn agree(f: &mut i32, v: i32) bool {
    if *f >= 0 && *f != v {
        return false;
    }
    *f = v;
    return true;
}

// The letter of float size `fs` (log2 of bytes).
const fn fs_of(l: u8) i32 {
    return switch l {
        b'b' => 0,
        b'h' => 1,
        b's' => 2,
        b'd' => 3,
        b'q' => 4,
        _ => -1,
    };
}

// Parse a register of class `c` into `*v`.
fn parse_reg(s: str, i: &mut usize, c: u8, v: &mut i64, f: &mut Facts) bool {
    let mut r = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
    if !reg(s, i, &mut r) || r.pq != 0 {
        return false;
    }
    *v = r.n;
    let g = r.l == b'x' || r.l == b'w';
    let gx: i32 = if r.l == b'x' {
        1;
    } else {
        0;
    };
    return switch c {
        t::C::R => g && !r.sp && r.arr < 0 && agree(&mut f.gw, gx),
        t::C::RS => g && (r.sp || r.n != 31) && r.arr < 0 && agree(&mut f.gw, gx),
        t::C::W => r.l == b'w' && !r.sp && r.arr < 0,
        t::C::X => r.l == b'x' && !r.sp && r.arr < 0,
        t::C::XS => r.l == b'x' && (r.sp || r.n != 31) && r.arr < 0,
        t::C::F => fs_of(r.l) >= 0 && r.arr < 0 && agree(&mut f.fs, fs_of(r.l)),
        t::C::FS => r.l == b's' && r.arr < 0,
        t::C::FD => r.l == b'd' && r.arr < 0,
        t::C::FH => r.l == b'h' && r.arr < 0,
        t::C::FQ => r.l == b'q' && r.arr < 0,
        t::C::FB => r.l == b'b' && r.arr < 0,
        t::C::V => r.l == b'v' && r.arr >= 0 && r.arr < 8 && agree(&mut f.arr, r.arr),
        t::C::Z => r.l == b'z' && r.arr >= 10 && r.arr <= 13 && agree(&mut f.ze, r.arr - 10),
        t::C::ZB => r.l == b'z' && r.arr == 10,
        t::C::ZS => r.l == b'z' && r.arr == 12,
        t::C::ZD => r.l == b'z' && r.arr == 13,
        _ => c >= t::C::V8B && c <= t::C::V2D && r.l == b'v' && r.arr == (c - t::C::V8B) as i32,
    };
}

// A vector register's element `Vn.T[i]` of lane letter `want` at `*i`: the register and the index.
fn parse_elem(s: str, i: &mut usize, want: u8, n: &mut i64, idx: &mut i64) bool {
    let mut r = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
    let mut j = *i;
    if !reg(s, &mut j, &mut r) || r.l != b'v' || r.arr != 10 + fs_of(want) {
        return false;
    }
    *n = r.n;
    if !eat(s, &mut j, b'[') || !number(s, &mut j, idx) || !eat(s, &mut j, b']') {
        return false;
    }
    *i = j;
    return true;
}

// A register list `{ Vt.T, .. }` of `n` registers, arrangement `arr` (an `ARR_NAMES` index, or `10 +` a
// lane letter's size for a single lane), consecutive modulo 32, at `*i`: its first register.
fn parse_list(s: str, i: &mut usize, n: u32, arr: i32, first: &mut i64) bool {
    let mut j = *i;
    if !eat(s, &mut j, b'{') {
        return false;
    }
    for q in 0..n {
        if q > 0 && !eat(s, &mut j, b',') {
            return false;
        }
        let mut r = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
        ws(s, &mut j);
        if !reg(s, &mut j, &mut r) || r.l != b'v' || r.arr != arr {
            return false;
        }
        if q == 0 {
            *first = r.n;
        } else if r.n != (*first + q as i64) % 32 {
            return false;
        }
    }
    if !eat(s, &mut j, b'}') {
        return false;
    }
    *i = j;
    return true;
}

// A symbol reference with its relocation specifier at `*i`: `:spec:name`, `name@SPEC`, `name`, each
// with an optional `+ n` or `- n`; `kind` gets the relocation the operand role `role` and the
// specifier select (FX_NONE for a plain name), `name` and `addend` the rest.
fn sym_ref(s: str, i: &mut usize, role: u8, fx: &mut Fix) bool {
    let mut j = *i;
    ws(s, &mut j);
    if j < s.len() && s.byte_at(j) == b'#' {
        j += 1;
    }
    let mut spec = "";
    if j < s.len() && s.byte_at(j) == b':' {
        let st = j + 1;
        let mut e = st;
        while e < s.len() && s.byte_at(e) != b':' {
            e += 1;
        }
        if e >= s.len() {
            return false;
        }
        spec = s.slice(st, e);
        j = e + 1;
    }
    let ns = j;
    // A numeric local label: `1f`, `1b`.
    while j < s.len() && s.byte_at(j) >= b'0' && s.byte_at(j) <= b'9' {
        j += 1;
    }
    if j > ns && j < s.len() && (lower(s.byte_at(j)) == b'f' || lower(s.byte_at(j)) == b'b') && (j + 1 >= s.len() || !is_ident(
        s.byte_at(j + 1),
        false,
    )) {
        j += 1;
    } else {
        j = ns;
        let mut k = j;
        let w = word(s, &mut k);
        if w.len() == 0 || !is_ident(w.byte_at(0), true) {
            return false;
        }
        j = k;
    }
    let name = s.slice(ns, j);
    if j < s.len() && s.byte_at(j) == b'@' {
        let mut k = j + 1;
        let w = word(s, &mut k);
        spec = w;
        j = k;
    }
    let mut add: i64 = 0;
    let mut k = j;
    ws(s, &mut k);
    if k < s.len() && (s.byte_at(k) == b'+' || s.byte_at(k) == b'-') {
        let neg = s.byte_at(k) == b'-';
        k += 1;
        if !number(s, &mut k, &mut add) {
            return false;
        }
        if neg {
            add = -add;
        }
        j = k;
    }
    let kind = reloc_kind(role, spec);
    if kind == 0xFF {
        return false;
    }
    fx.kind = kind;
    fx.name = String::from_str(name);
    fx.addend = add;
    *i = j;
    return true;
}

// Operand roles a symbol reference takes.
struct Role {}

extend Role {
    pub const BRANCH: u8 = 1; // b, bl
    pub const B19: u8 = 2;
    pub const B14: u8 = 3;
    pub const ADR: u8 = 4;
    pub const ADRP: u8 = 5;
    pub const LO12: u8 = 6; // add #imm
    pub const LDST: u8 = 7; // a load or store offset
}

// The relocation of a reference in role `role` with specifier `spec` (empty: none), 0xFF when the pair
// has none.
const fn reloc_kind(role: u8, spec: str) u8 {
    let none = spec.len() == 0;
    return switch role {
        Role::BRANCH => if none {
            a::R_BRANCH26;
        } else {
            0xFFu8;
        },
        Role::B19 => if none {
            FX_B19;
        } else {
            0xFFu8;
        },
        Role::B14 => if none {
            FX_B14;
        } else {
            0xFFu8;
        },
        Role::ADR => if none {
            FX_ADR;
        } else {
            0xFFu8;
        },
        Role::ADRP => if none || eq_nocase(spec, "page") || eq_nocase(spec, "pg_hi21") {
            a::R_PAGE21;
        } else if eq_nocase(spec, "gotpage") || eq_nocase(spec, "got") {
            a::R_GOT_PAGE21;
        } else if eq_nocase(spec, "tlvppage") {
            a::R_TLV_PAGE21;
        } else if eq_nocase(spec, "tlsdesc") {
            a::R_TLSDESC_PAGE21;
        } else {
            0xFFu8;
        },
        Role::LO12 => if eq_nocase(spec, "pageoff") || eq_nocase(spec, "lo12") {
            a::R_PAGEOFF12;
        } else if eq_nocase(spec, "tlsdesc_lo12") {
            a::R_TLSDESC_ADD;
        } else {
            0xFFu8;
        },
        Role::LDST => if eq_nocase(spec, "pageoff") || eq_nocase(spec, "lo12") {
            a::R_PAGEOFF12;
        } else if eq_nocase(spec, "gotpageoff") || eq_nocase(spec, "got_lo12") {
            a::R_GOT_PAGEOFF12;
        } else if eq_nocase(spec, "tlvppageoff") {
            a::R_TLV_PAGEOFF12;
        } else if eq_nocase(spec, "tlsdesc_lo12") {
            a::R_TLSDESC_LD64;
        } else {
            0xFFu8;
        },
        _ => 0xFFu8,
    };
}

// A label operand: a number (a byte offset from the instruction) or a reference in role `role`.
fn label(s: str, i: &mut usize, role: u8, v: &mut i64, fx: &mut Fix) bool {
    let mut j = *i;
    if peek(s, j, b'#') && number(s, &mut j, v) {
        *i = j;
        return true;
    }
    // `.+n`, `.-n`: n bytes from the instruction.
    ws(s, &mut j);
    if j + 1 < s.len() && s.byte_at(j) == b'.' && (s.byte_at(j + 1) == b'+' || s.byte_at(j + 1) == b'-') {
        j += 1;
        if number(s, &mut j, v) {
            *i = j;
            return true;
        }
    }
    *v = 0;
    return sym_ref(s, i, role, fx);
}

// An optional `, <shift> #n` (`ext`: the extend names too) after the operands parsed so far.
fn shift_opt(s: str, i: &mut usize, names: []str<'static>, ty: &mut i64, amt: &mut i64, need_amt: bool) bool {
    let mut j = *i;
    if !eat(s, &mut j, b',') {
        return true;
    }
    let w = word(s, &mut j);
    for k in 0..names.len() {
        if eq_nocase(w, names[k]) {
            *ty = k as i64;
            *amt = 0;
            let mut j2 = j;
            if number(s, &mut j2, amt) {
                j = j2;
            } else if need_amt {
                return false;
            }
            *i = j;
            return true;
        }
    }
    return false;
}

// The named value of `w` in `t`, -1 when none.
const fn named(t: []Named, w: str) i64 {
    for k in 0..t.len() {
        if eq_nocase(w, t[k].name) {
            return t[k].v;
        }
    }
    return -1;
}

// `[base` with base an x register or sp: the base number.
fn mem_open(s: str, i: &mut usize, base: &mut i64) bool {
    if !eat(s, i, b'[') {
        return false;
    }
    let mut r = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
    if !reg(s, i, &mut r) || r.l != b'x' || r.n == 31 && !r.sp || r.arr >= 0 {
        return false;
    }
    *base = r.n;
    return true;
}

// The float value of FMOV immediate `imm8` as an f64.
pub const fn fp8_value(imm8: u32) f64 {
    let sign = imm8 >> 7 & 1;
    let b = imm8 >> 6 & 1;
    let exp = ((b ^ 1) << 2 | imm8 >> 4 & 3) as i32 - 3;
    let frac = (16 + (imm8 & 15)) as f64 / 16.0;
    let mut v = frac;
    if exp > 0 {
        for _ in 0..exp {
            v *= 2.0;
        }
    } else {
        for _ in 0..-exp {
            v /= 2.0;
        }
    }
    if sign != 0 {
        return -v;
    }
    return v;
}

// A float literal at `*i` (`#1.5`, `#-0.25`, `#2`): its value.
fn float_lit(s: str, i: &mut usize, out: &mut f64) bool {
    let mut j = *i;
    ws(s, &mut j);
    if j < s.len() && s.byte_at(j) == b'#' {
        j += 1;
    }
    let st = j;
    while j < s.len() && (s.byte_at(j) >= b'0' && s.byte_at(j) <= b'9' || s.byte_at(j) == b'.' || s.byte_at(j) == b'-' || s.byte_at(
        j,
    ) == b'+' || lower(s.byte_at(j)) == b'e') {
        j += 1;
    }
    switch s.slice(st, j).parse_f64() {
        Some(f) => {
            *out = f;
            *i = j;
            return true;
        },
        None => {
            return false;
        },
    };
}

// Parse operand kind `k` of row `r` at `*i` into `v[at..]`.
fn parse_kind(r: t::Row, k: u8, s: str, i: &mut usize, v: &mut t::Vals, at: usize, f: &mut Facts, fx: &mut Fix) bool {
    if t::is_reg(k) {
        return parse_reg(s, i, t::reg_class(k), &mut v[at], f);
    }
    switch k {
        t::K::AIMM => {
            v[at + 1] = 0;
            let mut j = *i;
            if number(s, &mut j, &mut v[at]) {
                *i = j;
                // An immediate that takes the shifted field: a multiple of 4096 past 12 bits.
                if v[at] > 4095 && (v[at] & 0xFFF) == 0 {
                    v[at] >>= 12;
                    v[at + 1] = 1;
                }
                let mut ty: i64 = 0;
                let mut amt: i64 = 0;
                let lsl: []str<'static> = ["lsl"];
                if !shift_opt(s, i, lsl, &mut ty, &mut amt, true) {
                    return false;
                }
                if amt == 12 {
                    v[at + 1] = 1;
                } else if amt != 0 {
                    return false;
                }
                return true;
            }
            v[at] = 0;
            return sym_ref(s, i, Role::LO12, fx);
        },
        t::K::LIMM | t::K::LIMMV => {
            let mut x: i64 = 0;
            if !number(s, i, &mut x) {
                return false;
            }
            let wide = f.gw == 1;
            let u = if wide {
                x as u64;
            } else {
                x as u64 & 0xFFFFFFFF;
            };
            if !wide && (x < -(1i64 << 31) || x >= 1i64 << 32) {
                return false;
            }
            let nrs = a::logical_imm(u, wide);
            if nrs == 0xFFFFFFFF {
                return false;
            }
            v[at] = nrs;
            return true;
        },
        t::K::MOVW => {
            if !number(s, i, &mut v[at]) {
                return false;
            }
            let mut ty: i64 = 0;
            let mut amt: i64 = 0;
            let lsl: []str<'static> = ["lsl"];
            if !shift_opt(s, i, lsl, &mut ty, &mut amt, true) || amt % 16 != 0 {
                return false;
            }
            v[at + 1] = amt / 16;
            return true;
        },
        t::K::MOVZV | t::K::MOVNV | t::K::IMMR | t::K::IMMS | t::K::SHL | t::K::SHR | t::K::NZCV | t::K::IMM5 | t::K::IMM16 | t::K::UDF16 | t::K::TBIT | t::K::SIMM6 => {
            return number(s, i, &mut v[at]);
        },
        t::K::BFX | t::K::BFIZ => {
            return number(s, i, &mut v[at]) && eat(s, i, b',') && number(s, i, &mut v[at + 1]);
        },
        t::K::LSH | t::K::ASH => {
            let mut ty: i64 = 0;
            let mut amt: i64 = 0;
            let sh: []str<'static> = SHIFT_NAMES;
            let ok = shift_opt(s, i, sh, &mut ty, &mut amt, true);
            v[at] = ty;
            v[at + 1] = amt;
            return ok;
        },
        t::K::EXT => {
            // `lsl #n` or nothing (10): the extend of the operation's own width, which `fix_kinds` sets.
            let mut opt: i64 = 10;
            let mut amt: i64 = 0;
            let ex: []str<'static> = EXT_NAMES;
            let mut j = *i;
            if !shift_opt(s, &mut j, ex, &mut opt, &mut amt, false) {
                let lsl: []str<'static> = ["lsl"];
                let mut ty: i64 = 0;
                if !shift_opt(s, i, lsl, &mut ty, &mut amt, true) {
                    return false;
                }
                opt = 10;
            } else {
                *i = j;
            }
            v[at] = opt;
            v[at + 1] = amt;
            return true;
        },
        t::K::RMX => {
            let mut r0 = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
            if !reg(s, i, &mut r0) || r0.sp || r0.arr >= 0 || r0.l != b'x' && r0.l != b'w' {
                return false;
            }
            v[at] = r0.n;
            f.rmx = if r0.l == b'x' {
                1;
            } else {
                0;
            };
            return true;
        },
        t::K::COND | t::K::CONDI => {
            let w = word(s, i);
            let c = cond_of(w);
            v[at] = c;
            return c >= 0;
        },
        t::K::CONDM => {
            return true;
        },
        t::K::FPIMM => {
            let mut fv: f64 = 0.0;
            if !float_lit(s, i, &mut fv) {
                return false;
            }
            let d = f.fs == 3;
            let bits = if d {
                fv.to_bits();
            } else {
                (fv as f32).to_bits() as u64;
            };
            let m = a::fp_imm8(d, bits);
            if m == 0xFFFFFFFF || (fv as f32) as f64 != fv && !d {
                return false;
            }
            v[at] = m;
            return true;
        },
        t::K::FZERO => {
            let mut fv: f64 = 1.0;
            v[at] = 0;
            return float_lit(s, i, &mut fv) && fv == 0.0;
        },
        t::K::L26 => {
            return label(s, i, Role::BRANCH, &mut v[at], fx);
        },
        t::K::L19 => {
            return label(s, i, Role::B19, &mut v[at], fx);
        },
        t::K::L14 => {
            return label(s, i, Role::B14, &mut v[at], fx);
        },
        t::K::ADR => {
            return label(s, i, Role::ADR, &mut v[at], fx);
        },
        t::K::ADRP => {
            return label(s, i, Role::ADRP, &mut v[at], fx);
        },
        t::K::RTB => {
            let mut r0 = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
            if !reg(s, i, &mut r0) || r0.sp || r0.arr >= 0 || r0.l != b'x' && r0.l != b'w' {
                return false;
            }
            v[at] = r0.n;
            f.rtb = if r0.l == b'x' {
                1;
            } else {
                0;
            };
            return true;
        },
        t::K::MU12 | t::K::MS9 | t::K::MP7 => {
            if !mem_open(s, i, &mut v[at]) {
                return false;
            }
            v[at + 1] = 0;
            if eat(s, i, b',') {
                let mut j = *i;
                if !number(s, &mut j, &mut v[at + 1]) {
                    if k != t::K::MU12 {
                        return false;
                    }
                    if !sym_ref(s, i, Role::LDST, fx) {
                        return false;
                    }
                } else {
                    *i = j;
                }
            }
            return eat(s, i, b']') && !peek(s, *i, b'!');
        },
        t::K::MPRE9 | t::K::MPRE7 => {
            return mem_open(s, i, &mut v[at]) && eat(s, i, b',') && number(s, i, &mut v[at + 1]) && eat(s, i, b']') && eat(
                s,
                i,
                b'!',
            );
        },
        t::K::MPOST9 | t::K::MPOST7 => {
            return mem_open(s, i, &mut v[at]) && eat(s, i, b']') && eat(s, i, b',') && number(s, i, &mut v[at + 1]);
        },
        t::K::MREG => {
            if !mem_open(s, i, &mut v[at]) || !eat(s, i, b',') {
                return false;
            }
            let mut r0 = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
            if !reg(s, i, &mut r0) || r0.sp || r0.arr >= 0 || r0.l != b'x' && r0.l != b'w' {
                return false;
            }
            v[at + 1] = r0.n;
            let mut opt: i64 = -1;
            let mut amt: i64 = -1;
            let ex: []str<'static> = EXT_NAMES;
            if !shift_opt(s, i, ex, &mut opt, &mut amt, false) {
                let lsl: []str<'static> = ["lsl"];
                let mut ty: i64 = 0;
                amt = -1;
                if !shift_opt(s, i, lsl, &mut ty, &mut amt, true) {
                    return false;
                }
                opt = 3;
            }
            if opt < 0 {
                opt = 3;
            }
            // The register's width: x with lsl and sxtx, w with uxtw and sxtw.
            if (opt == 3 || opt == 7) != (r0.l == b'x') {
                return false;
            }
            v[at + 2] = opt;
            // The amount, when written, is 0 or the access size; the caller checks it (`shift`).
            v[at + 3] = amt;
            return eat(s, i, b']');
        },
        t::K::M0 => {
            if !mem_open(s, i, &mut v[at]) {
                return false;
            }
            if eat(s, i, b',') {
                let mut z: i64 = 1;
                if !number(s, i, &mut z) || z != 0 {
                    return false;
                }
            }
            return eat(s, i, b']');
        },
        t::K::SYSREG => {
            let w = word(s, i);
            let e = sysreg_of(w);
            v[at] = e;
            return e >= 0;
        },
        t::K::BARRIER | t::K::ISB => {
            let mut j = *i;
            let w = word(s, &mut j);
            let b: []Named = BARRIERS;
            let n = named(b, w);
            if n >= 0 {
                v[at] = n;
                *i = j;
                return true;
            }
            if k == t::K::ISB && !peek(s, *i, b'#') {
                v[at] = 15;
                return true;
            }
            return number(s, i, &mut v[at]);
        },
        t::K::XLR => {
            let mut j = *i;
            ws(s, &mut j);
            if j >= s.len() {
                v[at] = 30;
                return true;
            }
            return parse_reg(s, i, t::C::X, &mut v[at], f);
        },
        t::K::RNM => {
            return parse_reg(s, i, t::C::R, &mut v[at], f);
        },
        t::K::VNM => {
            return parse_reg(s, i, t::C::V, &mut v[at], f);
        },
        t::K::ELB | t::K::ELH | t::K::ELS | t::K::ELD => {
            let el: []str<'static> = ELEM;
            let sz = switch k {
                t::K::ELB => 0usize,
                t::K::ELH => 1usize,
                t::K::ELS => 2usize,
                _ => 3usize,
            };
            ws(s, i);
            let mut n: i64 = 0;
            let mut ix: i64 = 0;
            if !parse_elem(s, i, el[sz].byte_at(0), &mut n, &mut ix) {
                return false;
            }
            v[at] = n;
            v[at + 1] = ix;
            return true;
        },
        t::K::EDD | t::K::EN4D => {
            ws(s, i);
            let mut n: i64 = 0;
            let mut ix: i64 = 0;
            if !parse_elem(s, i, b'd', &mut n, &mut ix) {
                return false;
            }
            v[at] = n;
            v[at + 1] = ix;
            return true;
        },
        t::K::LNB | t::K::LNH | t::K::LNS | t::K::LND => {
            let sz = switch k {
                t::K::LNB => 0i32,
                t::K::LNH => 1i32,
                t::K::LNS => 2i32,
                _ => 3i32,
            };
            ws(s, i);
            if !parse_list(s, i, 1, 10 + sz, &mut v[at]) {
                return false;
            }
            return eat(s, i, b'[') && number(s, i, &mut v[at + 1]) && eat(s, i, b']');
        },
        t::K::L2B | t::K::L3B | t::K::L4B => {
            ws(s, i);
            return parse_list(s, i, k - t::K::L2B + 2, 1, &mut v[at]);
        },
        t::K::T1B | t::K::T2B | t::K::T3B | t::K::T4B => {
            ws(s, i);
            return parse_list(s, i, k - t::K::T1B + 1, 1, &mut v[at]);
        },
        t::K::IMM4X | t::K::SHL8 | t::K::SHL16 | t::K::SHL32 | t::K::IMM6X => {
            return number(s, i, &mut v[at]);
        },
        t::K::FELEM => {
            let mut r0 = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
            if !reg(s, i, &mut r0) || r0.arr >= 0 || fs_of(r0.l) < 0 {
                return false;
            }
            v[at] = r0.n;
            f.felem = fs_of(r0.l);
            return true;
        },
        t::K::PG | t::K::PGZ | t::K::PGM | t::K::PMM => {
            let mut r0 = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
            let want: u8 = switch k {
                t::K::PGZ => 1u8,
                t::K::PGM | t::K::PMM => 2u8,
                _ => 0u8,
            };
            if !reg(s, i, &mut r0) || r0.l != b'p' || r0.n > 7 || r0.arr >= 0 || r0.pq != want {
                return false;
            }
            v[at] = r0.n;
            return true;
        },
        t::K::PD | t::K::PND => {
            let mut r0 = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
            if !reg(s, i, &mut r0) || r0.l != b'p' || r0.pq != 0 || r0.arr < 10 || r0.arr > 13 {
                return false;
            }
            if k == t::K::PND != r0.n >= 32 {
                return false;
            }
            v[at] = if r0.n >= 32 {
                r0.n - 32;
            } else {
                r0.n;
            };
            return agree(&mut f.ze, r0.arr - 10);
        },
        t::K::PNGZ | t::K::PNG => {
            let mut r0 = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
            let want: u8 = if k == t::K::PNGZ {
                1u8;
            } else {
                0u8;
            };
            if !reg(s, i, &mut r0) || r0.l != b'p' || r0.n < 32 || r0.arr >= 0 || r0.pq != want {
                return false;
            }
            v[at] = r0.n - 32;
            return true;
        },
        t::K::ZL1 | t::K::ZL2 | t::K::ZL4 => {
            if !eat(s, i, b'{') {
                return false;
            }
            let mut r0 = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
            if !reg(s, i, &mut r0) || r0.l != b'z' || r0.arr < 10 || r0.arr > 13 || !agree(&mut f.ze, r0.arr - 10) {
                return false;
            }
            v[at] = r0.n;
            let n: i64 = switch k {
                t::K::ZL2 => 2i64,
                t::K::ZL4 => 4i64,
                _ => 1i64,
            };
            if n > 1 {
                let mut r1 = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
                if eat(s, i, b'-') {
                    if !reg(s, i, &mut r1) || r1.l != b'z' || r1.arr != r0.arr || r1.n != r0.n + n - 1 {
                        return false;
                    }
                } else {
                    for m in 1..n {
                        if !eat(s, i, b',') || !reg(s, i, &mut r1) || r1.l != b'z' || r1.arr != r0.arr || r1.n != r0.n + m {
                            return false;
                        }
                    }
                }
            }
            return eat(s, i, b'}');
        },
        t::K::ZAT => {
            let mut j = *i;
            let w = word(s, &mut j);
            let mut tile: i64 = 0;
            let mut el: i32 = 0;
            if !za_tile(w, &mut tile, &mut el, false) || !agree(&mut f.ze, el) {
                return false;
            }
            v[at] = tile;
            *i = j;
            return true;
        },
        t::K::ZASL => {
            if !eat(s, i, b'{') {
                return false;
            }
            let w = word(s, i);
            let mut tile: i64 = 0;
            let mut el: i32 = 0;
            if !za_tile(w, &mut tile, &mut el, true) || !agree(&mut f.ze, el) {
                return false;
            }
            v[at] = tile & 15;
            v[at + 1] = tile >> 4;
            if !eat(s, i, b'[') {
                return false;
            }
            let mut r0 = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
            if !reg(s, i, &mut r0) || r0.l != b'w' || r0.n < 12 || r0.n > 15 {
                return false;
            }
            v[at + 2] = r0.n - 12;
            return eat(s, i, b',') && number(s, i, &mut v[at + 3]) && eat(s, i, b']') && eat(s, i, b'}');
        },
        t::K::ZAARR => {
            let w = word(s, i);
            if !eq_nocase(w, "za") || !eat(s, i, b'[') {
                return false;
            }
            let mut r0 = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
            if !reg(s, i, &mut r0) || r0.l != b'w' || r0.n < 12 || r0.n > 15 {
                return false;
            }
            v[at] = r0.n - 12;
            return eat(s, i, b',') && number(s, i, &mut v[at + 1]) && eat(s, i, b']');
        },
        t::K::MZA => {
            if !mem_open(s, i, &mut v[at]) {
                return false;
            }
            if eat(s, i, b',') {
                // The offset repeats the array's (K::ZAARR, before this operand).
                let mut n: i64 = 0;
                if !number(s, i, &mut n) || n != v[at - 1] || !eat(s, i, b',') || !eq_nocase(word(s, i), "mul") || !eq_nocase(
                    word(s, i),
                    "vl",
                ) {
                    return false;
                }
            } else if v[at - 1] != 0 {
                return false;
            }
            return eat(s, i, b']');
        },
        t::K::ZAMASK => {
            if !eat(s, i, b'{') {
                return false;
            }
            let mut m: i64 = 0;
            if !peek(s, *i, b'}') {
                let mut first = true;
                while first || eat(s, i, b',') {
                    first = false;
                    let w = word(s, i);
                    if eq_nocase(w, "za") {
                        m |= 0xFF;
                        continue;
                    }
                    let mut tile: i64 = 0;
                    let mut el: i32 = 0;
                    if !za_tile(w, &mut tile, &mut el, false) {
                        return false;
                    }
                    m |= (switch el {
                        0 => 0xFFi64,
                        1 => 0x55i64 << tile,
                        2 => 0x11i64 << tile,
                        _ => 1i64 << tile,
                    });
                }
            }
            v[at] = m;
            return eat(s, i, b'}');
        },
        t::K::PAT => {
            v[at] = 31;
            let mut j = *i;
            if !eat(s, &mut j, b',') {
                return true;
            }
            let mut j2 = j;
            let w = word(s, &mut j2);
            if eq_nocase(w, "mul") {
                return true;
            }
            let p: []Named = PATTERNS;
            let n = named(p, w);
            if n >= 0 {
                v[at] = n;
                *i = j2;
                return true;
            }
            if !number(s, &mut j, &mut v[at]) {
                return false;
            }
            *i = j;
            return true;
        },
        t::K::MULVL => {
            v[at] = 1;
            let mut j = *i;
            if !eat(s, &mut j, b',') || !eq_nocase(word(s, &mut j), "mul") {
                return true;
            }
            if !number(s, &mut j, &mut v[at]) {
                return false;
            }
            *i = j;
            return true;
        },
        t::K::MSV => {
            if !mem_open(s, i, &mut v[at]) {
                return false;
            }
            v[at + 1] = 0;
            if eat(s, i, b',') {
                if !number(s, i, &mut v[at + 1]) || !eat(s, i, b',') || !eq_nocase(word(s, i), "mul") || !eq_nocase(
                    word(s, i),
                    "vl",
                ) {
                    return false;
                }
            }
            return eat(s, i, b']');
        },
        t::K::MSVR => {
            if !mem_open(s, i, &mut v[at]) {
                return false;
            }
            v[at + 1] = 31;
            if eat(s, i, b',') {
                let mut r0 = Reg { l: 0, n: 0, sp: false, arr: -1, pq: 0 };
                if !reg(s, i, &mut r0) || r0.l != b'x' || r0.sp || r0.n == 31 || r0.arr >= 0 {
                    return false;
                }
                v[at + 1] = r0.n;
                let e = t::fixed_q(r, 0) as i64;
                if e != 0 {
                    let lsl: []str<'static> = ["lsl"];
                    let mut ty: i64 = 0;
                    let mut amt: i64 = -1;
                    if !shift_opt(s, i, lsl, &mut ty, &mut amt, true) || amt != e {
                        return false;
                    }
                }
            }
            return eat(s, i, b']');
        },
        t::K::VLX => {
            let w = word(s, i);
            v[at] = if eq_nocase(w, "vlx2") {
                0i64;
            } else if eq_nocase(w, "vlx4") {
                1i64;
            } else {
                -1i64;
            };
            return v[at] >= 0;
        },
        t::K::SMSM | t::K::SMZA => {
            v[at] = 0;
            return eq_nocase(
                word(s, i),
                if k == t::K::SMSM {
                    "sm";
                } else {
                    "za";
                },
            );
        },
        _ => {
            return false;
        },
    };
}

// The condition named `w` (`cs` and `cc` too), -1 when none.
const fn cond_of(w: str) i64 {
    if eq_nocase(w, "cs") {
        return 2;
    }
    if eq_nocase(w, "cc") {
        return 3;
    }
    let n: []str<'static> = COND_NAMES;
    for k in 0..n.len() {
        if eq_nocase(w, n[k]) {
            return k as i64;
        }
    }
    return -1;
}

// The encoding of system register `w`: a name or `s<op0>_<op1>_c<n>_c<m>_<op2>`; -1 when none.
fn sysreg_of(w: str) i64 {
    let t0: []SysReg = SYSREGS;
    for k in 0..t0.len() {
        if eq_nocase(w, t0[k].name) {
            return t0[k].enc;
        }
    }
    if w.len() < 10 || lower(w.byte_at(0)) != b's' {
        return -1;
    }
    let mut parts: [i64; 5] = [0, 0, 0, 0, 0];
    let mut p: usize = 0;
    let mut j: usize = 1;
    while j < w.len() && p < 5 {
        if lower(w.byte_at(j)) == b'c' {
            j += 1;
        }
        let st = j;
        let mut n: i64 = 0;
        while j < w.len() && w.byte_at(j) >= b'0' && w.byte_at(j) <= b'9' {
            n = n * 10 + (w.byte_at(j) - b'0') as i64;
            j += 1;
        }
        if j == st {
            return -1;
        }
        unsafe parts[p] = n; // p < 5: the loop's bound
        p += 1;
        if j < w.len() {
            if w.byte_at(j) != b'_' {
                return -1;
            }
            j += 1;
        }
    }
    if p != 5 || j != w.len() || parts[0] < 2 || parts[0] > 3 || parts[1] > 7 || parts[2] > 15 || parts[3] > 15 || parts[4] > 7 {
        return -1;
    }
    return sr(parts[0] as u32, parts[1] as u32, parts[2] as u32, parts[3] as u32, parts[4] as u32);
}

// A ZA tile name `za<n>.<T>` (`slice`: `za<n>h.<T>` or `za<n>v.<T>`, the direction in bit 4 of
// `tile`): the tile and its element (log2 of bytes).
fn za_tile(w: str, tile: &mut i64, el: &mut i32, slice: bool) bool {
    if w.len() < 5 || !eq_nocase(w.slice(0, 2), "za") {
        return false;
    }
    let mut j: usize = 2;
    let mut n: i64 = 0;
    let st = j;
    while j < w.len() && w.byte_at(j) >= b'0' && w.byte_at(j) <= b'9' {
        n = n * 10 + (w.byte_at(j) - b'0') as i64;
        j += 1;
    }
    if j == st || j >= w.len() {
        return false;
    }
    let mut vert: i64 = 0;
    if slice {
        let c = lower(w.byte_at(j));
        if c != b'h' && c != b'v' {
            return false;
        }
        vert = if c == b'v' {
            1i64;
        } else {
            0i64;
        };
        j += 1;
    }
    if j + 2 != w.len() || w.byte_at(j) != b'.' {
        return false;
    }
    let e = fs_of(lower(w.byte_at(j + 1)));
    if e < 0 || e > 3 || n >= 1i64 << e as i64 {
        return false;
    }
    *tile = n | vert << 4;
    *el = e;
    return true;
}

// The variant of row `r` the facts give; 0xFF when they give none of its values.
const fn q_of(r: t::Row, f: &Facts) u32 {
    let ftq = switch f.fs {
        2 => 0i32,
        3 => 1i32,
        1 => 3i32,
        _ => -1i32,
    };
    let q: i32 = switch r.q {
        t::Q::NONE => 0,
        t::Q::SF | t::Q::SFN | t::Q::B30 | t::Q::S22 => f.gw,
        t::Q::FT => ftq,
        t::Q::CVT => if f.gw < 0 || ftq < 0 {
            -1;
        } else {
            f.gw | ftq << 1;
        },
        t::Q::V => f.arr,
        t::Q::VF => switch f.arr {
            4 => 0,
            5 => 1,
            7 => 3,
            _ => -1,
        },
        t::Q::VB => if f.arr == 0 || f.arr == 1 {
            f.arr;
        } else {
            -1;
        },
        t::Q::Z => f.ze,
        t::Q::FLS => f.fs,
        t::Q::FP => if f.fs >= 2 {
            f.fs - 2;
        } else {
            -1;
        },
        t::Q::ZE => if f.ze < 0 || f.ze == t::fixed_q(r, 0) as i32 {
            t::fixed_q(r, 0) as i32;
        } else {
            -1;
        },
        _ => -1,
    };
    if q < 0 || q > 7 {
        return 0xFF;
    }
    return q as u32;
}

/// Assemble the instruction `text` (mnemonic and operands, no label or comment) into `out`; `fx` gets
/// the symbol it names, if any. False with `err` set when it does not assemble.
pub fn assemble(text: str, out: &mut u32, fx: &mut Fix, err: &mut String) bool {
    let mut i: usize = 0;
    let mn0 = word(text, &mut i);
    let mut mn = String::from_str(mn0);
    mn.to_ascii_lower();
    let mut cond: i64 = -1;
    if mn.starts_with("b.") {
        cond = cond_of(mn.as_str().slice(2, mn.len()));
        if cond < 0 {
            err.format_into("unknown condition in '{}'", mn0);
            return false;
        }
        mn.truncate(2);
    }
    let rows: []t::Row = t::ROWS;
    let mut seen = false;
    for ri in 0..rows.len() {
        let r = rows[ri];
        if !mn.eq_str(r.mn) {
            continue;
        }
        seen = true;
        let mut v = t::Vals::new();
        let mut f = Facts { gw: -1, fs: -1, arr: -1, ze: -1, rmx: -1, rtb: -1, felem: -1 };
        let mut j = i;
        let mut at: usize = 0;
        let mut ok = true;
        let mut nt: u32 = 0;
        fx.kind = FX_NONE;
        fx.name.clear();
        fx.addend = 0;
        for oi in 0..6u32 {
            let k = t::kind_at(r.ops, oi);
            if k == 0 {
                break;
            }
            if k == t::K::CONDM {
                v[at] = cond;
                at += 1;
                continue;
            }
            // Kinds that start with their own comma or may be absent.
            let own = k == t::K::LSH || k == t::K::ASH || k == t::K::EXT || k == t::K::PAT || k == t::K::MULVL;
            if nt > 0 && !own {
                if !eat(text, &mut j, b',') {
                    ok = false;
                    break;
                }
            }
            if !parse_kind(r, k, text, &mut j, &mut v, at, &mut f, fx) {
                ok = false;
                break;
            }
            nt += 1;
            at += t::slots(k) as usize;
        }
        ws(text, &mut j);
        if !ok || j != text.len() {
            continue;
        }
        let q = q_of(r, &f);
        if q == 0xFF {
            continue;
        }
        if !fix_kinds(r, q, &mut v, &f) {
            continue;
        }
        if t::encode(r, q, &v, out) {
            return true;
        }
    }
    if seen {
        err.format_into("no form of '{}' takes the operands '{}'", mn0, text.slice(i, text.len()).trim());
    } else {
        err.format_into("unknown instruction '{}'", mn0);
    }
    return false;
}

// Settle what one operand's value depends on another's: an extend's default option and its register
// width, a register offset's amount, a test bit's register width, an across-lanes result size.
fn fix_kinds(r: t::Row, q: u32, v: &mut t::Vals, f: &Facts) bool {
    let x = t::is64(r.q, q);
    let mut at: usize = 0;
    for oi in 0..6u32 {
        let k = t::kind_at(r.ops, oi);
        if k == 0 {
            break;
        }
        if k == t::K::EXT {
            // `lsl` or nothing: uxtx (uxtw for a 32-bit form), which the register's width must match.
            if v[at] == 10 {
                v[at] = if x {
                    3i64;
                } else {
                    2i64;
                };
            }
            let wide = (v[at] & 3) == 3;
            if f.rmx >= 0 && f.rmx == 1 != wide {
                return false;
            }
        }
        if k == t::K::MREG {
            // The S bit: an amount written that is the access size (also `#0` of a byte access).
            let sc = t::ldst_scale(r.bits | t::qbits(r.q, q)) as i64;
            let amt = v[at + 3];
            if amt >= 0 && amt != sc && amt != 0 {
                return false;
            }
            v[at + 3] = if amt == sc {
                1i64;
            } else {
                0i64;
            };
        }
        if k == t::K::TBIT && f.rtb >= 0 && f.rtb == 1 != v[at] >= 32 && f.rtb == 0 {
            return false;
        }
        if k == t::K::FELEM && f.felem != (q >> 1) as i32 {
            return false;
        }
        at += t::slots(k) as usize;
    }
    return true;
}

// ---- Printing ----

// The name of register `n` of class `c` under row `r`'s variant `q`.
fn reg_text(o: &mut String, c: u8, n: i64, r: t::Row, q: u32) {
    let x = t::is64(r.q, q);
    switch c {
        t::C::R | t::C::RS | t::C::W | t::C::X | t::C::XS => {
            let wide = c == t::C::X || c == t::C::XS || (c == t::C::R || c == t::C::RS) && x;
            let sp = c == t::C::RS || c == t::C::XS;
            gpr_text(o, n, wide, sp);
        },
        t::C::F | t::C::FS | t::C::FD | t::C::FH | t::C::FQ | t::C::FB => {
            let fs = switch c {
                t::C::FS => 2u32,
                t::C::FD => 3u32,
                t::C::FH => 1u32,
                t::C::FQ => 4u32,
                t::C::FB => 0u32,
                _ => t::fsize(r.q, q),
            };
            let el: []str<'static> = ELEM;
            o.push_str(el[fs as usize]);
            o.push_i64(n);
        },
        t::C::V => {
            let ar: []str<'static> = ARR_NAMES;
            let arr = if r.q == t::Q::VF {
                q + 4;
            } else {
                q;
            };
            o.format_into("v{}.{}", n, ar[arr as usize]);
        },
        t::C::V8B | t::C::V16B | t::C::V4H | t::C::V8H | t::C::V2S | t::C::V4S | t::C::V1D | t::C::V2D => {
            let ar: []str<'static> = ARR_NAMES;
            o.format_into("v{}.{}", n, ar[(c - t::C::V8B) as usize]);
        },
        _ => {
            let e = switch c {
                t::C::ZB => 0u32,
                t::C::ZS => 2u32,
                t::C::ZD => 3u32,
                _ => t::fixed_q(r, q),
            };
            let el: []str<'static> = ELEM;
            o.format_into("z{}.{}", n, el[e as usize]);
        },
    };
}

fn gpr_text(o: &mut String, n: i64, wide: bool, sp: bool) {
    if n == 31 {
        let t0: []str<'static> = ZR_SP;
        o.push_str(t0[wide as usize + 2 * sp as usize]);
        return;
    }
    o.push_byte(
        if wide {
            b'x';
        } else {
            b'w';
        },
    );
    o.push_i64(n);
}

// `#v` in decimal below 4096 in magnitude, else in hexadecimal.
fn imm_text(o: &mut String, v: i64) {
    o.push_byte(b'#');
    if v > -4096 && v < 4096 {
        o.push_i64(v);
        return;
    }
    if v < 0 {
        o.push_str("-0x");
        o.push_hex((v as u64).wrapping_neg(), false);
        return;
    }
    o.push_str("0x");
    o.push_hex(v as u64, false);
}

// A byte offset from the instruction: `#n`.
fn off_text(o: &mut String, v: i64) {
    o.format_into("#{}", v);
}

/// Disassemble word `w` into `out` (mnemonic and operands); false (and `.inst 0x..`) when no row
/// matches.
pub fn disassemble(w: u32, out: &mut String) bool {
    let mut ri: u32 = 0;
    let mut q: u32 = 0;
    let mut v = t::Vals::new();
    if !t::decode(w, &mut ri, &mut q, &mut v) {
        out.push_str(".inst 0x");
        out.push_hex(w, false);
        return false;
    }
    let rows: []t::Row = t::ROWS;
    print_row(rows[ri as usize], q, &v, out);
    return true;
}

/// The text of row `r` with variant `q` and operand values `v`.
pub fn print_row(r: t::Row, q: u32, v: &t::Vals, o: &mut String) {
    o.push_str(r.mn);
    let x = t::is64(r.q, q);
    let mut at: usize = 0;
    let mut first = true;
    // Whether an sp-capable operand is sp (an extend then prints as lsl).
    let mut has_sp = false;
    for oi in 0..6u32 {
        let k = t::kind_at(r.ops, oi);
        if k == 0 {
            break;
        }
        if t::is_reg(k) && (t::reg_class(k) == t::C::RS || t::reg_class(k) == t::C::XS) && v[at] == 31 {
            has_sp = true;
        }
        at += t::slots(k) as usize;
    }
    at = 0;
    for oi in 0..6u32 {
        let k = t::kind_at(r.ops, oi);
        if k == 0 {
            break;
        }
        let n = t::slots(k) as usize;
        if k == t::K::CONDM {
            o.push_str(cond_name(v[at] as u32));
            at += n;
            continue;
        }
        let mut s = String::new();
        print_kind(r, q, x, k, v, at, has_sp, &mut s);
        at += n;
        if s.len() == 0 {
            continue;
        }
        let tail = s.byte(0) == b',';
        if tail {
            o.push_string(&s);
            continue;
        }
        o.push_str(
            if first {
                " ";
            } else {
                ", ";
            },
        );
        first = false;
        o.push_string(&s);
    }
}

fn print_kind(r: t::Row, q: u32, x: bool, k: u8, v: &t::Vals, at: usize, has_sp: bool, o: &mut String) {
    let a = v[at];
    if t::is_reg(k) {
        reg_text(o, t::reg_class(k), a, r, q);
        return;
    }
    switch k {
        t::K::AIMM => {
            imm_text(o, a);
            if v[at + 1] != 0 {
                o.push_str(", lsl #12");
            }
        },
        t::K::LIMM | t::K::LIMMV => {
            let u = t::bitmask_value(a as u32, x).unwrap_or(0);
            o.push_str("#0x");
            o.push_hex(u, false);
        },
        t::K::MOVW => {
            o.format_into("#0x{}", hex(a as u64));
            if v[at + 1] != 0 {
                o.format_into(", lsl #{}", v[at + 1] * 16);
            }
        },
        t::K::MOVZV | t::K::MOVNV => imm_text(o, a),
        t::K::IMMR | t::K::IMMS | t::K::SHL | t::K::SHR | t::K::NZCV | t::K::IMM5 | t::K::TBIT | t::K::SIMM6 => {
            o.format_into("#{}", a);
        },
        t::K::IMM16 | t::K::UDF16 => {
            o.format_into("#0x{}", hex(a as u64));
        },
        t::K::BFX | t::K::BFIZ => {
            o.format_into("#{}, #{}", a, v[at + 1]);
        },
        t::K::LSH | t::K::ASH => {
            if a != 0 || v[at + 1] != 0 {
                let sh: []str<'static> = SHIFT_NAMES;
                o.format_into(", {} #{}", sh[a as usize], v[at + 1]);
            }
        },
        t::K::EXT => {
            let lslopt: i64 = if x {
                3;
            } else {
                2;
            };
            if has_sp && a == lslopt {
                if v[at + 1] != 0 {
                    o.format_into(", lsl #{}", v[at + 1]);
                }
            } else {
                let ex: []str<'static> = EXT_NAMES;
                o.format_into(", {}", ex[a as usize]);
                if v[at + 1] != 0 {
                    o.format_into(" #{}", v[at + 1]);
                }
            }
        },
        t::K::RMX => {
            // The extend option follows: x for uxtx and sxtx.
            let opt = v[at + 1];
            gpr_text(o, a, (opt & 3) == 3, false);
        },
        t::K::COND | t::K::CONDI => o.push_str(cond_name(a as u32)),
        t::K::FPIMM => {
            o.push_byte(b'#');
            o.push_f64_prec(fp8_value(a as u32), 8);
        },
        t::K::FZERO => o.push_str("#0.0"),
        t::K::L26 | t::K::L19 | t::K::L14 | t::K::ADR | t::K::ADRP => off_text(o, a),
        t::K::RTB => {
            // The tested bit follows.
            gpr_text(o, a, v[at + 1] >= 32, false);
        },
        t::K::MU12 | t::K::MS9 | t::K::MP7 => {
            o.push_byte(b'[');
            gpr_text(o, a, true, true);
            if v[at + 1] != 0 {
                o.format_into(", #{}", v[at + 1]);
            }
            o.push_byte(b']');
        },
        t::K::MPRE9 | t::K::MPRE7 => {
            o.push_byte(b'[');
            gpr_text(o, a, true, true);
            o.format_into(", #{}]!", v[at + 1]);
        },
        t::K::MPOST9 | t::K::MPOST7 => {
            o.push_byte(b'[');
            gpr_text(o, a, true, true);
            o.format_into("], #{}", v[at + 1]);
        },
        t::K::MREG => {
            o.push_byte(b'[');
            gpr_text(o, a, true, true);
            o.push_str(", ");
            let opt = v[at + 2];
            gpr_text(o, v[at + 1], (opt & 3) == 3, false);
            let sc = t::ldst_scale(r.bits | t::qbits(r.q, q));
            let amt: u32 = if v[at + 3] != 0 {
                sc;
            } else {
                0u32;
            };
            if opt == 3 {
                if v[at + 3] != 0 {
                    o.format_into(", lsl #{}", amt);
                }
            } else {
                let ex: []str<'static> = EXT_NAMES;
                o.format_into(", {}", ex[opt as usize]);
                if v[at + 3] != 0 {
                    o.format_into(" #{}", amt);
                }
            }
            o.push_byte(b']');
        },
        t::K::M0 => {
            o.push_byte(b'[');
            gpr_text(o, a, true, true);
            o.push_byte(b']');
        },
        t::K::SYSREG => {
            let t0: []SysReg = SYSREGS;
            for i in 0..t0.len() {
                if t0[i].enc as i64 == a {
                    o.push_str(t0[i].name);
                    return;
                }
            }
            let e = a as u32;
            o.format_into("s{}_{}_c{}_c{}_{}", (e >> 14) + 2, e >> 11 & 7, e >> 7 & 15, e >> 3 & 15, e & 7);
        },
        t::K::BARRIER | t::K::ISB => {
            if k == t::K::ISB && a == 15 {
                return;
            }
            let b: []Named = BARRIERS;
            for i in 0..b.len() {
                if b[i].v as i64 == a {
                    o.push_str(b[i].name);
                    return;
                }
            }
            o.format_into("#{}", a);
        },
        t::K::XLR => {
            if a != 30 {
                gpr_text(o, a, true, false);
            }
        },
        t::K::RNM => {
            gpr_text(o, a, x, false);
        },
        t::K::VNM => reg_text(o, t::C::V, a, r, q),
        t::K::FELEM => {
            let el: []str<'static> = ELEM;
            o.format_into("{}{}", el[(q >> 1) as usize], a);
        },
        t::K::PG => o.format_into("p{}", a),
        t::K::PGZ => o.format_into("p{}/z", a),
        t::K::PGM | t::K::PMM => o.format_into("p{}/m", a),
        t::K::PD => {
            let el: []str<'static> = ELEM;
            o.format_into("p{}.{}", a, el[q as usize]);
        },
        t::K::PND => {
            let el: []str<'static> = ELEM;
            o.format_into("pn{}.{}", a, el[q as usize]);
        },
        t::K::PNGZ => o.format_into("pn{}/z", a),
        t::K::PNG => o.format_into("pn{}", a),
        t::K::ZL1 | t::K::ZL2 | t::K::ZL4 => {
            let el: []str<'static> = ELEM;
            let e = el[t::fixed_q(r, q) as usize];
            let n: i64 = switch k {
                t::K::ZL2 => 2i64,
                t::K::ZL4 => 4i64,
                _ => 1i64,
            };
            if n == 1 {
                o.format_into("{{z{}.{}}}", a, e);
            } else {
                o.format_into("{{z{}.{}-z{}.{}}}", a, e, a + n - 1, e);
            }
        },
        t::K::ZAT => {
            let el: []str<'static> = ELEM;
            o.format_into("za{}.{}", a, el[t::fixed_q(r, q) as usize]);
        },
        t::K::ZASL => {
            let el: []str<'static> = ELEM;
            o.format_into(
                "{{za{}{}.{}[w{}, {}]}}",
                a,
                if v[at + 1] != 0 {
                    "v";
                } else {
                    "h";
                },
                el[t::fixed_q(r, q) as usize],
                v[at + 2] + 12,
                v[at + 3],
            );
        },
        t::K::ZAARR => o.format_into("za[w{}, {}]", a + 12, v[at + 1]),
        t::K::MZA => {
            o.push_byte(b'[');
            gpr_text(o, a, true, true);
            if v[at - 1] != 0 {
                o.format_into(", #{}, mul vl", v[at - 1]);
            }
            o.push_byte(b']');
        },
        t::K::ZAMASK => {
            if a == 0xFF {
                o.push_str("{za}");
                return;
            }
            o.push_byte(b'{');
            let mut first = true;
            for b in 0..8i64 {
                if (a >> b & 1) != 0 {
                    if !first {
                        o.push_str(", ");
                    }
                    first = false;
                    o.format_into("za{}.d", b);
                }
            }
            o.push_byte(b'}');
        },
        t::K::PAT => {
            // `all` is written when a multiplier follows it (K::MULVL, the next value).
            let mul = t::kind_at(r.ops, 2) == t::K::MULVL && v[at + 1] != 1;
            if a != 31 || mul {
                let p: []Named = PATTERNS;
                for i in 0..p.len() {
                    if p[i].v as i64 == a {
                        o.format_into(", {}", p[i].name);
                        return;
                    }
                }
                o.format_into(", #{}", a);
            }
        },
        t::K::MULVL => {
            if a != 1 {
                o.format_into(", mul #{}", a);
            }
        },
        t::K::MSV => {
            o.push_byte(b'[');
            gpr_text(o, a, true, true);
            if v[at + 1] != 0 {
                o.format_into(", #{}, mul vl", v[at + 1]);
            }
            o.push_byte(b']');
        },
        t::K::MSVR => {
            o.push_byte(b'[');
            gpr_text(o, a, true, true);
            if v[at + 1] != 31 {
                o.push_str(", ");
                gpr_text(o, v[at + 1], true, false);
                let e = t::fixed_q(r, q);
                if e != 0 {
                    o.format_into(", lsl #{}", e);
                }
            }
            o.push_byte(b']');
        },
        t::K::VLX => o.push_str(
            if a != 0 {
                "vlx4";
            } else {
                "vlx2";
            },
        ),
        t::K::SMSM => o.push_str("sm"),
        t::K::SMZA => o.push_str("za"),
        t::K::ELB | t::K::ELH | t::K::ELS | t::K::ELD | t::K::EDD | t::K::EN4D => {
            let el = switch k {
                t::K::ELB => "b",
                t::K::ELH => "h",
                t::K::ELS => "s",
                _ => "d",
            };
            o.format_into("v{}.{}[{}]", a, el, v[at + 1]);
        },
        t::K::LNB | t::K::LNH | t::K::LNS | t::K::LND => {
            let el = switch k {
                t::K::LNB => "b",
                t::K::LNH => "h",
                t::K::LNS => "s",
                _ => "d",
            };
            o.format_into("{{ v{}.{} }}[{}]", a, el, v[at + 1]);
        },
        t::K::L2B | t::K::L3B | t::K::L4B | t::K::T1B | t::K::T2B | t::K::T3B | t::K::T4B => {
            let n = if k >= t::K::T1B {
                k - t::K::T1B + 1;
            } else {
                k - t::K::L2B + 2;
            };
            o.push_str("{ ");
            for q in 0..n {
                if q > 0 {
                    o.push_str(", ");
                }
                o.format_into("v{}.16b", (a + q as i64) % 32);
            }
            o.push_str(" }");
        },
        t::K::IMM4X | t::K::SHL8 | t::K::SHL16 | t::K::SHL32 | t::K::IMM6X => o.format_into("#{}", a),
        _ => {},
    };
}

fn hex(v: u64) String {
    let mut s = String::new();
    s.push_hex(v, false);
    return s;
}
