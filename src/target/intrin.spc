// The C compilers' intrinsics the native backends expand in place of a call: the table of each instruction
// set, a row's lookup, the expansion of its constant arguments, and the vector registers an expansion
// names and writes, which a backend renames to where its arguments are.
import target::a64intrin as a64i;
import target::x64intrin as x64i;
import target::wasmintrin as wasmi;

/// The instructions of intrinsic `name` on instruction set `isa` (`target::table`'s `ISA_*` name: "aarch64",
/// "x86_64", "wasm32"); empty when the backend has none, or when the intrinsic needs no instruction (`has`).
pub(package) const fn find(isa: str, name: str) str<'static> {
    let (_k, t) = row(isa, name);
    return t;
}

/// Whether `isa` has intrinsic `name`: an empty row (`_mm_castps_si128`, `vget_low_f32`) reinterprets its
/// argument's bytes, which the lowering does without a call.
pub(package) const fn has(isa: str, name: str) bool {
    let (k, _t) = row(isa, name);
    return k;
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

/// Whether arm64 template `text` names vector register `r` in a register list (`{ v0.16b, v1.16b }`),
/// whose registers must be consecutive: the generators keep it.
pub(package) const fn vlisted(text: str, r: u32) bool {
    let mut depth: i32 = 0;
    for i in 0..text.len() {
        let c = text.byte_at(i);
        if c == b'{' {
            depth += 1;
        } else if c == b'}' {
            depth -= 1;
        } else if depth > 0 {
            let (k, _l) = vreg_at(true, text, i);
            if k == r {
                return true;
            }
        }
    }
    return false;
}

/// Whether template `text` may write vector register `r`. Per instruction: an arm64 one its first operand
/// (all of a register list), a load, swap or compare-and-swap (`ld*`, `swp*`, `cas*`) every operand; an
/// x86-64 one its last operand, an exchange or a gather (`xchg`, `xadd`, `gather`) every operand. A store
/// or a compare counts as a write: the answer errs on the side of a write.
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
/// `to[j]`, onto `out`.
pub(package) fn vrename(a64: bool, text: str, from: []u32, to: []u32, out: &mut String) {
    let mut i: usize = 0;
    while i < text.len() {
        let (k, l) = vreg_at(a64, text, i);
        let mut q = from.len();
        if l != 0 {
            for j in 0..from.len() {
                if from[j] == k {
                    q = j;
                }
            }
        }
        if q == from.len() {
            out.push_byte(text.byte_at(i));
            i += 1;
            continue;
        }
        // The spelling's letters, then the new number.
        let letters = if a64 {
            1usize
        } else {
            4usize
        };
        out.push_str(text.slice(i, i + letters));
        out.push_u64(to[q]);
        i += l;
    }
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
                    return if k < 2 {
                        MF_LOAD
                    } else {
                        MF_STORE
                    };
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
                return if o < 3 {
                    MF_LOAD
                } else {
                    MF_STORE
                };
            }
        }
    }
    return MF_NONE;
}
