// The C compilers' intrinsics the native backends expand in place of a call: the table of each instruction
// set, a row's lookup, the expansion of its constant arguments, and the vector registers an expansion
// names and writes, which a backend renames to where its arguments are.
import lir::ir as *;
import target::a64intrin as a64i;
import target::x64intrin as x64i;
import target::wasmintrin as wasmi;
import ast::ast as ast;

/// The instructions of intrinsic `name` on instruction set `isa` (`target::table`'s `ISA_*` name: "aarch64",
/// "x86_64", "wasm32"); empty when the backend has none, or when the intrinsic needs no instruction (`has`).
pub(package) const fn find(isa: str, name: str) str<'static> {
    let (_k, t) = row(isa, name);
    return t;
}

/// Whether intrinsic `name` of `isa` is an operation on secrets: a row whose instructions are all in
/// `ops` (`target::table::Isa::const_time`: an x86-64 VEX form as its legacy mnemonic), or an empty row
/// (no instruction). False for no row.
pub(package) const fn constant_time(isa: str, ops: str, name: str) bool {
    let (k, text) = row(isa, name);
    if !k {
        return false;
    }
    let x86 = isa == "x86_64";
    let mut at: usize = 0;
    while at < text.len() {
        let mut end = at;
        while end < text.len() && text.byte_at(end) != b'\n' && text.byte_at(end) != b';' {
            end += 1;
        }
        let ins = text.slice(at, end).trim();
        at = end + 1;
        let mut m: usize = 0;
        while m < ins.len() && ins.byte_at(m) != b' ' && ins.byte_at(m) != b'\t' {
            m += 1;
        }
        let mn = ins.slice(0, m);
        if mn.len() != 0 && !listed(ops, mn) && !(x86 && mn.starts_with("v") && listed(ops, mn.slice(1, mn.len()))) {
            return false;
        }
    }
    return true;
}

// Whether `w` is a word of the space-separated list `ops`.
const fn listed(ops: str, w: str) bool {
    let mut a: usize = 0;
    for i in 0..ops.len() + 1 {
        if i < ops.len() && ops.byte_at(i) != b' ' {
            continue;
        }
        if i - a == w.len() && ops.slice(a, i) == w {
            return true;
        }
        a = i + 1;
    }
    return false;
}

/// Whether `isa` has intrinsic `name`: an empty row (`_mm_castps_si128`, `vget_low_f32`) reinterprets its
/// argument's bytes, which the lowering does without a call.
pub(package) const fn has(isa: str, name: str) bool {
    let (k, _t) = row(isa, name);
    return k;
}

/// Per symbol of body `b` of package `p`, the instructions of the intrinsic it names on `isa` (`find`, a
/// `__sc_x_` prefix aside), into `out`; empty for a function the package defines or no intrinsic.
pub(package) fn of_symbols(p: &Package, b: &Body, isa: str, out: &mut Vector<str<'static>>) {
    out.truncate(0);
    for s in 0..b.syms.len() {
        let ps = p.syms[b.syms[s] as usize];
        if ps.def != NONE {
            out.push("");
            continue;
        }
        let nm = p.spell(ps.name);
        out.push(
            find(
                isa,
                if nm.starts_with("__sc_x_") {
                    nm.slice(7, nm.len())
                } else {
                    nm
                },
            ),
        );
    }
}

/// `of_symbols` for x86-64 with SSE4.1: the C library's exact roundings (`x64i::SSE41_ROWS`) too.
pub(package) const fn x64_sse41(p: &Package, b: &Body, out: &mut Vector<str<'static>>) {
    let rows: [](str<'static>, str<'static>) = x64i::SSE41_ROWS;
    for s in 0..b.syms.len() {
        let ps = p.syms[b.syms[s] as usize];
        if ps.def != NONE {
            continue;
        }
        let nm = p.spell(ps.name);
        for k in 0..rows.len() {
            if rows[k].0 == nm {
                out[s] = rows[k].1;
            }
        }
    }
}

// The row of intrinsic `name` of `isa`: whether there is one, and its instructions.
const fn row(isa: str, name: str) (bool, str<'static>) {
    let rows: [](str<'static>, str<'static>) = if isa == "aarch64" {
        a64i::ROWS
    } else if isa == "x86_64" {
        x64i::ROWS
    } else if isa == "wasm32" {
        wasmi::ROWS
    } else {
        return (false, "");
    };
    let mut lo: usize = 0;
    let mut hi = rows.len();
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        let k = rows[mid].0;
        if k == name {
            return (true, rows[mid].1);
        }
        if k < name {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return (false, "");
}

/// Row text `text` with each `@k` and `@(k*a+b)` replaced by constant argument `k` (`imm[k]`, `known[k]`) or that
/// multiple of it, onto `out`; false when it names an argument that is no constant.
pub(package) fn expand(text: str, imm: []i64, known: []bool, out: &mut String) bool {
    let mut i: usize = 0;
    while i < text.len() {
        let c = text.byte_at(i);
        if c != b'@' || i + 1 >= text.len() {
            out.push_byte(c);
            i += 1;
            continue;
        }
        // `@k` or `@(k*a+b)`, a signed `a` and `b`.
        let mut k: usize = 0;
        let mut a: i64 = 1;
        let mut b: i64 = 0;
        if text.byte_at(i + 1) == b'(' {
            let end = text.slice(i, text.len()).find(")");
            if end < 0 {
                return false;
            }
            let e = text.slice(i + 2, i + end as usize);
            let star = e.find("*");
            if star < 0 {
                return false;
            }
            k = (switch e.slice(0, star as usize).parse_i64() {
                Some(v) => v as usize,
                None => {
                    return false;
                },
            });
            let rest = e.slice(star as usize + 1, e.len());
            // The sign of `b` is the last `+` or `-` past `a`'s own sign.
            let mut s = rest.len();
            while s > 1 && rest.byte_at(s - 1) != b'+' && rest.byte_at(s - 1) != b'-' {
                s -= 1;
            }
            if s <= 1 {
                return false;
            }
            a = (switch rest.slice(0, s - 1).parse_i64() {
                Some(v) => v,
                None => {
                    return false;
                },
            });
            let bt = rest.slice(s - 1, rest.len());
            b = (switch if bt.starts_with("+") {
                bt.slice(1, bt.len())
            } else {
                bt
            }.parse_i64() {
                Some(v) => v,
                None => {
                    return false;
                },
            });
            i += end as usize + 1;
        } else {
            i += 1;
            while i < text.len() && text.byte_at(i) >= b'0' && text.byte_at(i) <= b'9' {
                k = k * 10 + (text.byte_at(i) - b'0') as usize;
                i += 1;
            }
        }
        if k >= imm.len() || !known[k] {
            return false;
        }
        out.push_i64(a * imm[k] + b);
    }
    return true;
}

/// The vector register a template names at byte `i` of `text` (arm64 `isa`: `v`, `q`, `d`, `s`, `h` or
/// `b` and its number; else x86-64's `%xmm`, `%ymm` or `%zmm` and its number): its number and its
/// spelling's length, the number 99 for none.
pub(package) const fn vreg_at(a64: bool, text: str, i: usize) (u32, usize) {
    let n = text.len();
    let mut j = i;
    if a64 {
        let c = text.byte_at(i);
        if c != b'v' && c != b'q' && c != b'd' && c != b's' && c != b'h' && c != b'b' {
            return (99, 0);
        }
        if i > 0 && word_byte(text.byte_at(i - 1)) {
            return (99, 0);
        }
        j += 1;
    } else {
        if i + 4 > n || text.byte_at(i) != b'%' || text.byte_at(i + 2) != b'm' || text.byte_at(i + 3) != b'm' {
            return (99, 0);
        }
        let c = text.byte_at(i + 1);
        if c != b'x' && c != b'y' && c != b'z' {
            return (99, 0);
        }
        j += 4;
    }
    let d0 = j;
    let mut r: u32 = 0;
    // At most two digits.
    while j < n && j < d0 + 2 && text.byte_at(j) >= b'0' && text.byte_at(j) <= b'9' {
        r = r * 10 + (text.byte_at(j) - b'0') as u32;
        j += 1;
    }
    if j == d0 || r > 31 || j < n && word_byte(text.byte_at(j)) {
        return (99, 0);
    }
    return (r, j - i);
}

/// Whether template `text` names vector register `r` (`vreg_at`).
pub(package) const fn vnames(a64: bool, text: str, r: u32) bool {
    for i in 0..text.len() {
        let (k, _l) = vreg_at(a64, text, i);
        if k == r {
            return true;
        }
    }
    return false;
}

/// Whether x86-64 template `text` reads `%xmm0` as a fixed operand, which no other register can take: a
/// legacy (not VEX) instruction of three operands whose first is `%xmm0` (`blendvps`, `blendvpd`,
/// `pblendvb`, `sha256rnds2`). `r` is 0 for that.
pub(package) const fn vfixed(text: str, r: u32) bool {
    if r != 0 {
        return false;
    }
    let mut at: usize = 0;
    while at < text.len() {
        let mut end = at;
        while end < text.len() && text.byte_at(end) != b'\n' && text.byte_at(end) != b';' {
            end += 1;
        }
        let ins = text.slice(at, end).trim();
        at = end + 1;
        let sp = ins.find(" ");
        if ins.starts_with("v") || sp < 0 {
            continue;
        }
        let ops = ins.slice(sp as usize, ins.len()).trim();
        let mut commas: u32 = 0;
        for j in 0..ops.len() {
            commas += (ops.byte_at(j) == b',') as u32;
        }
        let (k, l) = vreg_at(false, ops, 0);
        if k == 0 && l == 5 && commas == 2 {
            return true;
        }
    }
    return false;
}

/// Whether arm64 template `text` names vector register `r` in a register list of two or more
/// (`{ v0.16b, v1.16b }`), whose registers must be consecutive: the generators keep it.
pub(package) const fn vlisted(text: str, r: u32) bool {
    let mut depth: i32 = 0;
    let mut found = false;
    let mut commas = 0u32;
    for i in 0..text.len() {
        let c = text.byte_at(i);
        if c == b'{' {
            depth += 1;
            found = false;
            commas = 0;
        } else if c == b'}' {
            depth -= 1;
            if found && commas != 0 {
                return true;
            }
        } else if depth > 0 && c == b',' {
            commas += 1;
        } else if depth > 0 {
            let (k, _l) = vreg_at(true, text, i);
            found = found || k == r;
        }
    }
    return false;
}

/// Whether template `text` may write vector register `r`. Per instruction: an arm64 one its first operand
/// (all of a register list), a load, swap or compare-and-swap (`ld*`, `swp*`, `cas*`) every operand; an
/// x86-64 one its last operand, an exchange or a gather (`xchg`, `xadd`, `gather`) every operand. An arm64
/// store (`st*`) writes no vector register. A compare counts as a write: the answer errs on the side of a
/// write.
pub(package) const fn vwrites(a64: bool, text: str, r: u32) bool {
    let mut at: usize = 0;
    // Each step takes one instruction (a line or a `;`-separated part).
    while at < text.len() {
        let mut end = at;
        while end < text.len() && text.byte_at(end) != b'\n' && text.byte_at(end) != b';' {
            end += 1;
        }
        let ins = text.slice(at, end);
        at = end + 1;
        let mut m: usize = 0;
        while m < ins.len() && ins.byte_at(m) == b' ' {
            m += 1;
        }
        let ms = m;
        while m < ins.len() && ins.byte_at(m) != b' ' {
            m += 1;
        }
        let mn = ins.slice(ms, m);
        if a64 && mn.starts_with("st") {
            continue;
        }
        let all = if a64 {
            mn.starts_with("ld") || mn.starts_with("swp") || mn.starts_with("cas")
        } else {
            mn.contains("xchg") || mn.contains("xadd") || mn.contains("gather")
        };
        // The written operand's bytes: the first or the last at bracket depth 0.
        let mut ws = m;
        let mut we = ins.len();
        if !all {
            let mut depth: i32 = 0;
            let mut first_end = ins.len();
            let mut last_start = m;
            for j in m..ins.len() {
                let c = ins.byte_at(j);
                if c == b'{' || c == b'[' || c == b'(' {
                    depth += 1;
                } else if c == b'}' || c == b']' || c == b')' {
                    depth -= 1;
                } else if c == b',' && depth == 0 {
                    if first_end == ins.len() {
                        first_end = j;
                    }
                    last_start = j + 1;
                }
            }
            if a64 {
                we = first_end;
            } else {
                ws = last_start;
            }
        }
        for j in ws..we {
            let (k, _l) = vreg_at(a64, ins, j);
            if k == r {
                return true;
            }
        }
    }
    return false;
}

/// Template `text` with each spelling of vector register `from[j]` (`vreg_at`) spelled as register
/// `to[j]`, onto `out`; outside the destination operand of a one-instruction template (`vsplit_dest`),
/// register `src.0` as `src.1` instead (99: none).
pub(package) fn vrename(a64: bool, text: str, from: []u32, to: []u32, src: (u32, u32), out: &mut String) {
    let (ds, de) = if src.0 == 99 {
        (0usize, 0usize)
    } else {
        dest_span(a64, text)
    };
    let mut i: usize = 0;
    while i < text.len() {
        let (k, l) = vreg_at(a64, text, i);
        let mut q = from.len();
        let mut r: u32 = 99;
        if l != 0 && k == src.0 && (i < ds || i >= de) {
            r = src.1;
        } else if l != 0 {
            for j in 0..from.len() {
                if from[j] == k {
                    q = j;
                }
            }
            if q != from.len() {
                r = to[q];
            }
        }
        if r == 99 {
            out.push_byte(text.byte_at(i));
            i += 1;
            continue;
        }
        // The spelling's letters, then the new number.
        let letters = ast::pick(a64, 1usize, 4usize);
        out.push_str(text.slice(i, i + letters));
        out.push_u64(r);
        i += l;
    }
}

// The bytes of the destination operand of one-instruction template `text`: arm64's first operand (to its
// first comma outside brackets), x86-64's last (from its last such comma).
const fn dest_span(a64: bool, text: str) (usize, usize) {
    let mut depth: i32 = 0;
    let mut first = text.len();
    let mut last = text.len();
    for j in 0..text.len() {
        let c = text.byte_at(j);
        if c == b'{' || c == b'[' || c == b'(' {
            depth += 1;
        } else if c == b'}' || c == b']' || c == b')' {
            depth -= 1;
        } else if c == b',' && depth == 0 {
            if first == text.len() {
                first = j;
            }
            last = j;
        }
    }
    return ast::pick(a64, (0usize, first), (last, text.len()));
}

// The arm64 vector instructions that read their destination register: accumulations, bit selects,
// inserts, table extensions, narrowings into the high half, the cryptographic rounds.
const READS_DEST: [str; 63] = [
    "bsl",
    "bit",
    "bif",
    "mla",
    "mls",
    "fmla",
    "fmls",
    "fmlal",
    "fmlal2",
    "fmlsl",
    "fmlsl2",
    "sdot",
    "udot",
    "usdot",
    "sudot",
    "bfdot",
    "bfmmla",
    "smmla",
    "ummla",
    "usmmla",
    "saba",
    "uaba",
    "sabal",
    "sabal2",
    "uabal",
    "uabal2",
    "sadalp",
    "uadalp",
    "smlal",
    "smlal2",
    "umlal",
    "umlal2",
    "smlsl",
    "smlsl2",
    "umlsl",
    "umlsl2",
    "sqdmlal",
    "sqdmlal2",
    "sqdmlsl",
    "sqdmlsl2",
    "sqrdmlah",
    "sqrdmlsh",
    "ssra",
    "usra",
    "srsra",
    "ursra",
    "sri",
    "sli",
    "tbx",
    "ins",
    "fcmla",
    "aese",
    "aesd",
    "sha1c",
    "sha1m",
    "sha1p",
    "sha1su0",
    "sha1su1",
    "sha256h",
    "sha256h2",
    "sha256su0",
    "sha256su1",
    "sm4e",
];

// The x86-64 three-operand (VEX) vector instructions that read their destination register: the fused
// multiply-adds, the dot products, the two-table permutations, the gathers and scatters, the funnel shifts
// by vector amounts.
const READS_DEST_X64: [str; 13] = [
    "vfmadd",
    "vfmsub",
    "vfnmadd",
    "vfnmsub",
    "vpdp",
    "vpermi2",
    "vpermt2",
    "vpgather",
    "vgather",
    "vpscatter",
    "vscatter",
    "vpshldv",
    "vpshrdv",
];

/// Whether template `text` is one instruction that writes vector register `r` whole as its destination
/// (arm64's first operand: no lane, no list; x86-64's last, of a three-operand `v` form without masking),
/// does not read its destination (`READS_DEST`, an arm64 narrowing into the high half: a mnemonic of `hn2`
/// or `n2`; `READS_DEST_X64`), and names `r` again as a source: its sources may then read `r`'s value from
/// another register, its destination left as it is (`vrename`'s `src`).
pub(package) const fn vsplit_dest(a64: bool, text: str, r: u32) bool {
    for j in 0..text.len() {
        let c = text.byte_at(j);
        if c == b'\n' || c == b';' || !a64 && c == b'{' {
            return false;
        }
    }
    let mut m: usize = 0;
    while m < text.len() && text.byte_at(m) == b' ' {
        m += 1;
    }
    let ms = m;
    while m < text.len() && text.byte_at(m) != b' ' {
        m += 1;
    }
    let mn = text.slice(ms, m);
    if a64 {
        if mn.ends_with("n2") || mn.starts_with("ld") {
            return false;
        }
        for k in 0..63usize {
            if mn == unsafe READS_DEST[k] {
                return false;
            }
        }
    } else {
        if !mn.starts_with("v") {
            return false;
        }
        for k in 0..13usize {
            if mn.starts_with(unsafe READS_DEST_X64[k]) {
                return false;
            }
        }
    }
    let (ds, de) = dest_span(a64, text);
    if a64 && de == text.len() || !a64 && ds == text.len() {
        return false;
    }
    // The destination: register `r` alone.
    let mut d0 = ast::pick(a64, m, ds + 1);
    while d0 < de && text.byte_at(d0) == b' ' {
        d0 += 1;
    }
    let (k, l) = vreg_at(a64, text, d0);
    if l == 0 || k != r {
        return false;
    }
    for j in d0..de {
        let c = text.byte_at(j);
        if c == b'[' || c == b'{' || c == b'(' {
            return false;
        }
    }
    for j in m..text.len() {
        if j >= ds && j < de {
            continue;
        }
        let (k2, l2) = vreg_at(a64, text, j);
        if l2 != 0 && k2 == r {
            return true;
        }
    }
    return false;
}

// Whether byte `c` continues a word: a letter, a digit or `_`.
const fn word_byte(c: u8) bool {
    return c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9' || c == b'_';
}

/// `mem_form`: no plain memory access, a load of the vector its pointer argument addresses, a store of
/// its second argument at its first.
pub(package) const MF_NONE: u8 = 0;
pub(package) const MF_LOAD: u8 = 1;
pub(package) const MF_STORE: u8 = 2;

/// The lane bytes of an x86 vector its scalar arguments give, the first the lowest lane, for a `setr`
/// intrinsic of more arguments than the templates' registers (`_mm_setr_epi8`, `_mm256_setr_epi16`: no
/// row covers one); 0 for another name or instruction set `isa`.
pub(package) fn lane_form(isa: str, name: str) u32 {
    if isa != "x86_64" {
        return 0;
    }
    let pre: []str = ["_mm_setr_", "_mm256_setr_", "_mm512_setr_"];
    for p in 0..pre.len() {
        if name.starts_with(pre[p]) {
            return switch name.slice(pre[p].len(), name.len()) {
                "epi8" => 1,
                "epi16" => 2,
                "epi32" => 4,
                "epi64x" => 8,
                _ => 0,
            };
        }
    }
    return 0;
}

// The mnemonics, or for x86-64 their prefixes, of instructions that access no memory operand but change or
// read machine state beyond their operands: time stamps, random numbers, fences, system registers, hints,
// traps, the stack, the implicit memory of `maskmovdqu`, the x87 and MMX state, cache maintenance, the
// tile registers and their configuration (AMX).
const IMPURE_X64: [str; 36] = [
    "rdtsc",
    "rdrand",
    "rdseed",
    "rdpid",
    "rdpmc",
    "rdfsbase",
    "rdgsbase",
    "wrfsbase",
    "wrgsbase",
    "cpuid",
    "xgetbv",
    "xsetbv",
    "lfence",
    "mfence",
    "sfence",
    "pause",
    "serialize",
    "xbegin",
    "xend",
    "xabort",
    "xtest",
    "maskmov",
    "push",
    "pop",
    "ud2",
    "vzero",
    "emms",
    "femms",
    "monitor",
    "mwait",
    "umonitor",
    "tpause",
    "tile",
    "ldtilecfg",
    "sttilecfg",
    "tdp",
];
const IMPURE_A64: [str; 21] = [
    "mrs",
    "msr",
    "rndr",
    "rndrrs",
    "dmb",
    "dsb",
    "isb",
    "yield",
    "wfe",
    "wfi",
    "sev",
    "sevl",
    "hint",
    "svc",
    "brk",
    "clrex",
    "dc",
    "ic",
    "tlbi",
    "sys",
    "udf",
];

/// Whether intrinsic `name` of `isa` computes its result from its arguments alone: its instructions have no
/// memory operand (x86-64's `(`, arm64's `[`, no wasm load, store, atomic or memory operation) and are none
/// of `IMPURE_X64` or `IMPURE_A64`. The floating-point environment counts as no state, as C compilers count
/// it without `#pragma STDC FENV_ACCESS`. A call of one is a value the optimizer numbers and hoists.
pub(package) const fn pure(isa: str, name0: str) bool {
    let name = if name0.starts_with("__sc_x_") {
        name0.slice(7, name0.len())
    } else {
        name0
    };
    let t = find(isa, name);
    let x64 = isa == "x86_64";
    let a64 = isa == "aarch64";
    if t.len() == 0 || x64 && t.contains("(") || a64 && t.contains("[") {
        return false;
    }
    if !x64 && !a64 && (t.contains("load") || t.contains("store") || t.contains("atomic") || t.contains("memory")) {
        return false;
    }
    let mut i: usize = 0;
    while i < t.len() {
        // Instruction by instruction: its mnemonic.
        while i < t.len() && (t.byte_at(i) == b' ' || t.byte_at(i) == b'\n' || t.byte_at(i) == b';' || t.byte_at(i) == b'\t') {
            i += 1;
        }
        let ms = i;
        while i < t.len() && word_byte(t.byte_at(i)) {
            i += 1;
        }
        let mn = t.slice(ms, i);
        if x64 {
            for k in 0..36usize {
                if mn.starts_with(unsafe IMPURE_X64[k]) {
                    return false;
                }
            }
        } else if a64 {
            for k in 0..21usize {
                if mn == unsafe IMPURE_A64[k] {
                    return false;
                }
            }
        }
        while i < t.len() && t.byte_at(i) != b'\n' && t.byte_at(i) != b';' {
            i += 1;
        }
    }
    return true;
}

/// The lanes intrinsic `name` fills with its one scalar argument: their bytes and whether they hold floats
/// (`_mm_set1_epi32`: (4, false), its x86 vector type of 8-byte lanes notwithstanding); (0, false) for the
/// lanes of its result type (`vdupq_n_u8`, `vmov_n_f32`, `wasm_i32x4_splat`), (0, true) for another name.
/// The lowering makes it a `splat`.
pub(package) const fn splat_form(name: str) (u32, bool) {
    let pre: []str = ["_mm_set1_", "_mm256_set1_", "_mm512_set1_"];
    for p in 0..pre.len() {
        if name.starts_with(pre[p]) {
            return switch name.slice(pre[p].len(), name.len()) {
                "epi8" => (1u32, false),
                "epi16" => (2u32, false),
                "epi32" => (4u32, false),
                "epi64x" | "epi64" => (8u32, false),
                "ps" => (4u32, true),
                "pd" => (8u32, true),
                _ => (0u32, true),
            };
        }
    }
    let lanes = name.starts_with("vdup_n_") || name.starts_with("vdupq_n_") || name.starts_with("vmov_n_") || name.starts_with(
        "vmovq_n_",
    ) || name.starts_with("wasm_") && name.ends_with("_splat");
    return (0u32, !lanes);
}

/// Whether intrinsic `name` reads one lane of a vector at an index its second argument gives
/// (`vget_lane_f32`, `vgetq_lane_s64`): the lowering makes it a lane read (`vextract`) for a constant index.
pub(package) const fn lane_read(name: str) bool {
    return name.starts_with("vget_lane_") || name.starts_with("vgetq_lane_");
}

/// Whether intrinsic `name` only loads or stores one whole vector at its pointer argument, of any
/// alignment (`vld1q_f32`, `_mm_loadu_ps`, `_mm256_store_si256`, `wasm_v128_load`): the lowering makes it
/// a plain load or store the optimizer sees through. An aligned form's alignment is a precondition, so an
/// unaligned access computes the same.
pub(package) const fn mem_form(name: str) u8 {
    if name == "wasm_v128_load" {
        return MF_LOAD;
    }
    if name == "wasm_v128_store" {
        return MF_STORE;
    }
    let neon: []str = ["vld1q_", "vld1_", "vst1q_", "vst1_"];
    for k in 0..neon.len() {
        if name.starts_with(neon[k]) {
            let lanes: []str = [
                "s8",
                "s16",
                "s32",
                "s64",
                "u8",
                "u16",
                "u32",
                "u64",
                "f16",
                "f32",
                "f64",
                "p8",
                "p16",
                "p64",
                "bf16",
            ];
            let rest = name.slice(neon[k].len(), name.len());
            for j in 0..lanes.len() {
                if rest == lanes[j] {
                    return ast::pick(k < 2, MF_LOAD, MF_STORE);
                }
            }
            return MF_NONE;
        }
    }
    // `_mm`, `_mm256` or `_mm512`, then the operation, then the type.
    let pre: []str = ["_mm_", "_mm256_", "_mm512_"];
    let ops: []str = ["loadu_", "load_", "lddqu_", "storeu_", "store_"];
    let tys: []str = ["ps", "pd", "si128", "si256", "si512"];
    for p in 0..pre.len() {
        if !name.starts_with(pre[p]) {
            continue;
        }
        let r1 = name.slice(pre[p].len(), name.len());
        for o in 0..ops.len() {
            if !r1.starts_with(ops[o]) {
                continue;
            }
            let r2 = r1.slice(ops[o].len(), r1.len());
            // The integer type names the width: si128 with `_mm`, si256 with `_mm256`, si512 with `_mm512`.
            if r2 == "ps" || r2 == "pd" || r2 == tys[p + 2] {
                return ast::pick(o < 3, MF_LOAD, MF_STORE);
            }
        }
    }
    return MF_NONE;
}
