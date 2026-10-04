// Loop model: indexed loops over a Vector and a slice of it, with affine and strided indexes, guards
// and sub-slices, for the bounds-check elimination differential: the program must give the same
// output with BCE on and with every check kept (`SC_BCE=0`). A check that BCE removes but that can
// fail shows as a missing trap, a sanitizer report or a different value.
import tests::gen::driver as *;
import tests::harness as h;

const S_FOR: u8 = 0; // for i in LO..HI
const S_FOR_INCL: u8 = 1; // for i in LO..=HI
const S_STEP: u8 = 2; // while i < HI, i += STEP
const S_GUARD: u8 = 3; // if k + C < X.len() (or <=) read X[k + C2]
const S_DOWN: u8 = 4; // while i > LO, i -= 1 first
const S_SUB: u8 = 5; // a sub-slice X[LO..HI], read with the index form
const KINDS_N: u64 = 6;

// A loop bound: a literal, an opaque value, the length, the length minus c, or half the length.
const B_LIT: u8 = 0;
const B_OPAQUE: u8 = 1;
const B_LEN: u8 = 2;
const B_LEN_MINUS: u8 = 3;
const B_HALF: u8 = 4;

/// One statement: its kind, the indexed container (0 the Vector `v`, 1 the slice `s`), the bounds,
/// the step and the index `mul * i + off`.
@derive(Clone)
pub struct Stmt {
    pub kind: u8,
    pub x: u8,
    pub lo_kind: u8,
    pub lo: u64,
    pub hi_kind: u8,
    pub hi: u64,
    pub step: u64,
    pub mul: u64,
    pub off: i64,
    pub le: bool, // S_GUARD compares with <=
}

/// The loop model: a Vector of `n` elements, the slice `v[slo..shi]`, and the statements.
@derive(Clone)
pub struct LoopModel {
    pub n: u64,
    pub slo: u64,
    pub shi: u64,
    pub stmts: Vector<Stmt>,
    pub stmts_max: u64,
}

/// A model of 1 to `stmts_max` statements.
pub fn loop_model(stmts_max: u64) LoopModel {
    return LoopModel { n: 0, slo: 0, shi: 0, stmts: Vector::<Stmt>::new(), stmts_max: stmts_max };
}

fn container(x: u8) str<'static> {
    if x == 0 {
        return "v";
    }
    return "s";
}

fn render_bound(kind: u8, c: u64, x: str, out: &mut String) {
    if kind == B_LIT {
        out.push_u64(c);
    } else if kind == B_OPAQUE {
        out.format_into("opr::<usize>({})", c);
    } else if kind == B_LEN {
        out.format_into("{}.len()", x);
    } else if kind == B_LEN_MINUS {
        out.format_into("{}.len() - {}", x, c);
    } else {
        out.format_into("{}.len() / 2", x);
    }
}

// `mul * var + off`, without the factors that are 1 or 0.
fn render_index(var: str, mul: u64, off: i64, out: &mut String) {
    if mul != 1 {
        out.format_into("{} * ", mul);
    }
    out.push_str(var);
    if off > 0 {
        out.format_into(" + {}", off);
    } else if off < 0 {
        out.format_into(" - {}", -off);
    }
}

fn gen_stmt(rng: &mut Rng) Stmt {
    let mut st = Stmt {
        kind: rng.below(KINDS_N) as u8,
        x: rng.below(2) as u8,
        lo_kind: B_LIT,
        lo: rng.below(3),
        hi_kind: (1 + rng.below(4)) as u8,
        hi: rng.below(4),
        step: 1 + rng.below(4),
        mul: 1,
        off: 0,
        le: rng.one_in(3),
    };
    if rng.one_in(3) {
        st.lo_kind = B_OPAQUE;
    }
    if rng.one_in(2) {
        st.mul = 1 + rng.below(3);
    }
    if rng.one_in(2) {
        st.off = rng.below(5) as i64 - 2;
    }
    return st;
}

extend Stmt {
    fn render(self: &Stmt, out: &mut String) {
        let x = container(self.x);
        let mut lo = String::new();
        render_bound(self.lo_kind, self.lo, x, &mut lo);
        let mut hi = String::new();
        render_bound(self.hi_kind, self.hi, x, &mut hi);
        let mut idx = String::new();
        render_index("i", self.mul, self.off, &mut idx);
        if self.kind == S_FOR || self.kind == S_FOR_INCL {
            let dots = if self.kind == S_FOR {
                "..";
            } else {
                "..=";
            };
            out.format_into("    for i in {}{}{} {{\n", lo.as_str(), dots, hi.as_str());
            out.format_into("        acc = acc.wrapping_add({}[{}]);\n    }}\n", x, idx.as_str());
        } else if self.kind == S_STEP {
            out.format_into(
                "    {{\n        let mut i: usize = {};\n        while i < {} {{\n",
                lo.as_str(),
                hi.as_str(),
            );
            out.format_into("            acc = acc.wrapping_add({}[{}]);\n", x, idx.as_str());
            out.format_into("            i += {};\n        }}\n    }}\n", self.step);
        } else if self.kind == S_GUARD {
            let mut read = String::new();
            render_index("k", 1, self.off + self.lo as i64, &mut read);
            let cmp = if self.le {
                "<=";
            } else {
                "<";
            };
            out.format_into("    {{\n        let k = opr::<usize>({});\n", self.hi);
            out.format_into("        if k + {} {} {}.len() {{\n", self.lo, cmp, x);
            out.format_into("            acc = acc.wrapping_add({}[{}]);\n        }}\n    }}\n", x, read.as_str());
        } else if self.kind == S_DOWN {
            out.format_into(
                "    {{\n        let mut i: usize = {};\n        while i > {} {{\n",
                hi.as_str(),
                lo.as_str(),
            );
            out.format_into(
                "            i -= 1;\n            acc = acc.wrapping_add({}[{}]);\n        }}\n    }}\n",
                x,
                idx.as_str(),
            );
        } else {
            out.format_into("    {{\n        let t: []i64 = {}[{}..{}];\n", x, lo.as_str(), hi.as_str());
            out.format_into(
                "        for i in 0..t.len() {{\n            acc = acc.wrapping_add(t[{}]);\n",
                idx.as_str(),
            );
            out.push_str("        }\n    }\n");
        }
        out.push_str("    println(\"{}\", acc);\n");
    }
}

extend LoopModel {
    fn program(self: &LoopModel) String {
        let mut s = String::from_str("static mut SINK: usize = 0;\n@c.noinline\nfn opr<T>(x: T) T {\n");
        s.push_str("    unsafe SINK += 1;\n    return x;\n}\n");
        s.push_str("fn main() i32 {\n    let mut v = Vector::<i64>::new();\n");
        s.format_into("    for k in 0..opr::<usize>({}) {{\n        v.push(k as i64 * 3 + 1);\n    }}\n", self.n);
        s.format_into("    let s: []i64 = v[opr::<usize>({})..opr::<usize>({})];\n", self.slo, self.shi);
        s.push_str("    let mut acc: i64 = 0;\n");
        for i in 0..self.stmts.len() {
            self.stmts.at(i).render(&mut s);
        }
        s.push_str("    return 0;\n}\n");
        return s;
    }
}

extend LoopModel as Model {
    pub fn name(self: &Self) str<'static> {
        return "loops";
    }

    pub fn generate(self: &mut Self, rng: &mut Rng) {
        self.n = rng.below(21);
        self.slo = rng.below(self.n / 2 + 1);
        self.shi = self.slo + rng.below(self.n - self.slo + 1);
        self.stmts.clear();
        let count = 1 + rng.below(self.stmts_max);
        for _ in 0..count {
            self.stmts.push(gen_stmt(rng));
        }
    }

    pub fn oracles(self: &Self) usize {
        return 1;
    }

    pub fn check(self: &Self, k: usize) String {
        assert(k == 0);
        let src = self.program();
        return h::same_output(src.as_str(), [], ["SC_BCE=0"], [""]);
    }

    pub fn render(self: &Self, k: usize) String {
        assert(k == 0);
        return self.program();
    }

    // Keep only statement j, drop statement j, then per statement: the index `i`, the lower bound 0,
    // the upper bound the length, the step 1, the guard `<`.
    pub fn candidates(self: &Self) usize {
        return 7 * self.stmts.len();
    }

    pub fn reduce(self: &mut Self, i: usize) bool {
        let n = self.stmts.len();
        if i < 2 * n {
            if n == 1 {
                return false;
            }
            if i < n {
                let keep = self.stmts.at(i).clone();
                self.stmts.clear();
                self.stmts.push(keep);
            } else {
                let _ = self.stmts.remove(i - n);
            }
            return true;
        }
        let j = (i - 2 * n) / 5;
        let form = (i - 2 * n) % 5;
        let mut st = self.stmts.at(j).clone();
        let mut changed = false;
        if form == 0 && (st.mul != 1 || st.off != 0) {
            st.mul = 1;
            st.off = 0;
            changed = true;
        } else if form == 1 && (st.lo_kind != B_LIT || st.lo != 0) {
            st.lo_kind = B_LIT;
            st.lo = 0;
            changed = true;
        } else if form == 2 && st.hi_kind != B_LEN {
            st.hi_kind = B_LEN;
            changed = true;
        } else if form == 3 && st.step != 1 {
            st.step = 1;
            changed = true;
        } else if form == 4 && st.le {
            st.le = false;
            changed = true;
        }
        self.stmts[j] = st;
        return changed;
    }
}
