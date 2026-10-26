// The C compilers' intrinsics the native backends expand in place of a call: the table of each instruction
// set, a row's lookup and the expansion of its constant arguments.
import target::a64intrin as a64i;
import target::x64intrin as x64i;
import target::wasmintrin as wasmi;

/// The instructions of intrinsic `name` on instruction set `isa` (`target::table`'s `ISA_*` name: "aarch64",
/// "x86_64", "wasm32"); empty when the backend has none.
pub fn find(isa: str, name: str) str<'static> {
    let rows: [](str<'static>, str<'static>) = if isa == "aarch64" {
        a64i::ROWS;
    } else if isa == "x86_64" {
        x64i::ROWS;
    } else if isa == "wasm32" {
        wasmi::ROWS;
    } else {
        return "";
    };
    let mut lo: usize = 0;
    let mut hi = rows.len();
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        let k = rows[mid].0;
        if k == name {
            return rows[mid].1;
        }
        if k < name {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return "";
}

/// Row text `text` with each `@k` and `@(k*a+b)` replaced by constant argument `k` (`imm[k]`, `known[k]`) or that
/// multiple of it, onto `out`; false when it names an argument that is no constant.
pub fn expand(text: str, imm: []i64, known: []bool, out: &mut String) bool {
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
            k = (e.byte_at(0) - b'0') as usize;
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
                bt.slice(1, bt.len());
            } else {
                bt;
            }.parse_i64() {
                Some(v) => v,
                None => {
                    return false;
                },
            });
            i += end as usize + 1;
        } else {
            k = (text.byte_at(i + 1) - b'0') as usize;
            i += 2;
        }
        if k >= imm.len() || !known[k] {
            return false;
        }
        out.push_i64(a * imm[k] + b);
    }
    return true;
}
