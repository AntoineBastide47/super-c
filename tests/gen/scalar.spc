// Scalar model: integer and float expressions over every builtin width, with inputs biased to the
// boundaries (MIN, MIN + 1, -1, 0, 1, MAX - 1, MAX, NaN, infinities, subnormals, values next to the
// conversion bounds), shift counts from -1 to the width + 1, and casts. Oracle 0 compares each case as
// a constant and at run time; oracle 1 compares the `dev` and `release` profiles on a program whose
// result is the same under both rules: the `release` side uses the plain operators, which wrap there,
// and the `dev` side the `wrapping_*` methods.
import tests::gen::driver as *;
import tests::harness as h;

const OP_LEAF: u8 = 0;
const OP_NEG: u8 = 1;
const OP_NOT: u8 = 2;
const OP_ADD: u8 = 3;
const OP_SUB: u8 = 4;
const OP_MUL: u8 = 5;
const OP_DIV: u8 = 6;
const OP_REM: u8 = 7;
const OP_AND: u8 = 8;
const OP_OR: u8 = 9;
const OP_XOR: u8 = 10;
const OP_SHL: u8 = 11;
const OP_SHR: u8 = 12;
const OP_CAST: u8 = 13;

// Types are indices: 0..=4 signed (i8, i16, i32, i64, isize), 5..=9 unsigned, 10 f32, 11 f64.
const TYPES_N: u64 = 12;

/// One expression node; `a` and `b` index the operands in the model's node arena.
@derive(Clone)
pub struct Node {
    pub op: u8,
    pub ty: u8,
    pub a: u32,
    pub b: u32,
    pub lit: String, // a leaf's literal text
}

/// The scalar model: one expression tree per case in a flat node arena.
@derive(Clone)
pub struct ScalarModel {
    pub nodes: Vector<Node>,
    pub roots: Vector<u32>,
    pub cases_max: u64,
    pub depth_max: u64,
    pub opts: Vector<String>, // extra build options of every oracle (a planted defect)
}

/// A model of 1 to `cases_max` cases, each at most `depth_max` operators deep.
pub fn scalar_model(cases_max: u64, depth_max: u64) ScalarModel {
    return ScalarModel {
        nodes: Vector::<Node>::new(),
        roots: Vector::<u32>::new(),
        cases_max: cases_max,
        depth_max: depth_max,
        opts: Vector::<String>::new(),
    };
}

fn type_name(t: u8) str<'static> {
    return switch t {
        0 => "i8",
        1 => "i16",
        2 => "i32",
        3 => "i64",
        4 => "isize",
        5 => "u8",
        6 => "u16",
        7 => "u32",
        8 => "u64",
        9 => "usize",
        10 => "f32",
        _ => "f64",
    };
}

// Bit width; isize and usize count as 64 bits, the widest target.
fn type_bits(t: u8) u64 {
    return switch t {
        0 | 5 => 8,
        1 | 6 => 16,
        2 | 7 | 10 => 32,
        _ => 64,
    };
}

// The bits a literal of `t` may use on every target: isize and usize have 32 on wasm32.
fn literal_bits(t: u8) u64 {
    if t == 4 || t == 9 {
        return 32;
    }
    return type_bits(t);
}

const fn is_float(t: u8) bool {
    return t >= 10;
}

const fn is_signed(t: u8) bool {
    return t <= 4;
}

// A decimal integer of type `t`, uniform over its literal range.
fn random_int(rng: &mut Rng, t: u8) String {
    let bits = literal_bits(t);
    let mut s = String::new();
    let mut u = rng.next();
    if bits < 64 {
        u = u % (1u64 << bits);
    }
    if !is_signed(t) {
        s.push_u64(u);
    } else if bits == 64 {
        s.push_i64(u as i64);
    } else {
        s.push_i64(u as i64 - (1i64 << (bits - 1) as i64));
    }
    return s;
}

// An integer literal biased to the boundaries of `t`.
fn int_literal(rng: &mut Rng, t: u8) String {
    let name = type_name(t);
    let bits = literal_bits(t);
    let r = rng.below(12);
    let mut s = String::new();
    if r == 0 {
        s.format_into("{}::MIN", name);
    } else if r == 1 {
        s.format_into("{}::MIN + 1", name);
    } else if r == 2 {
        s.push_str(
            if is_signed(t) {
                "-1";
            } else {
                "2";
            },
        );
    } else if r == 3 {
        s.push_str("0");
    } else if r == 4 {
        s.push_str("1");
    } else if r == 5 {
        s.format_into("{}::MAX - 1", name);
    } else if r == 6 {
        s.format_into("{}::MAX", name);
    } else if r == 7 {
        s.push_u64(rng.below(100));
    } else if r == 8 {
        // 2^k - 1, 2^k or 2^k + 1, below the sign bit
        let p = 1u64 << rng.below(bits - 1);
        s.push_u64(p - 1 + rng.below(3));
    } else if r == 9 && bits == 64 {
        // next to 2^53, where an int-to-f64 cast starts to round
        s.push_u64(9007199254740992 - 1 + rng.below(3));
    } else if r == 9 && bits == 32 {
        // next to 2^24, where an int-to-f32 cast starts to round
        s.push_u64(16777216 - 1 + rng.below(3));
    } else {
        s = random_int(rng, t);
    }
    return s;
}

// A float literal of type `t`: specials, subnormals, values next to the integer conversion bounds,
// or a random decimal.
fn float_literal(rng: &mut Rng, t: u8) String {
    let both: []str = [
        "0.0",
        "-0.0",
        "1.0",
        "-1.0",
        "0.5",
        "-0.5",
        "0.1",
        "1.0 / 0.0",
        "-1.0 / 0.0",
        "0.0 / 0.0",
        "1.401298464324817e-45",
        "1.1754943508222875e-38",
        "3.4028234663852886e38",
        "-3.4028234663852886e38",
        "127.5",
        "128.0",
        "-128.5",
        "-129.0",
        "255.5",
        "256.0",
        "32767.5",
        "-32769.0",
        "65535.5",
        "65536.0",
        "16777217.0",
        "2147483520.0",
        "2147483648.0",
        "-2147483648.0",
        "4294967296.0",
        "9223372036854775808.0",
        "-9223372036854775808.0",
        "18446744073709551616.0",
    ];
    let wide: []str = [
        "4.9e-324",
        "2.225073858507201e-308",
        "2.2250738585072014e-308",
        "1.7976931348623157e308",
        "-1.7976931348623157e308",
        "2147483647.0",
        "2147483647.5",
        "-2147483648.5",
        "-2147483649.0",
        "4294967295.5",
        "9007199254740993.0",
        "9223372036854774784.0",
        "18446744073709549568.0",
        "3.4028235677973366e38",
        "0.49999999999999994",
    ];
    let r = rng.below(8);
    if r < 4 {
        return String::from_str(both[rng.below(both.len() as u64) as usize]);
    }
    if r < 6 && t == 11 {
        return String::from_str(wide[rng.below(wide.len() as u64) as usize]);
    }
    // d.ddd..e<x>, inside the type's finite range
    let mut s = String::new();
    if rng.one_in(2) {
        s.push_byte(b'-');
    }
    s.push_u64(1 + rng.below(9));
    s.push_byte(b'.');
    let digits = 1 + rng.below(16);
    for _ in 0..digits {
        s.push_u64(rng.below(10));
    }
    if t == 10 {
        s.format_into("e{}", rng.below(82) as i64 - 44);
    } else {
        s.format_into("e{}", rng.below(628) as i64 - 320);
    }
    return s;
}

// A shift count for type `t`: in range most of the time, else -1 (signed), the width or the width + 1.
fn shift_count(rng: &mut Rng, t: u8) String {
    let w = type_bits(t);
    let r = rng.below(6);
    let mut s = String::new();
    if r == 0 {
        s.push_u64(w - 1);
    } else if r == 1 {
        s.push_u64(w);
    } else if r == 2 {
        s.push_u64(w + 1);
    } else if r == 3 && is_signed(t) {
        s.push_str("-1");
    } else {
        s.push_u64(rng.below(w));
    }
    return s;
}

// The method name of an overflowing operator: `add`, `sub` or `mul`.
fn op_name(op: u8) str<'static> {
    if op == OP_ADD {
        return "add";
    }
    if op == OP_SUB {
        return "sub";
    }
    assert(op == OP_MUL);
    return "mul";
}

// The symbol of a unary or binary operator.
fn op_symbol(op: u8) str<'static> {
    let symbols: []str<'static> = ["", "-", "~", "+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>"];
    assert(op != OP_LEAF && op < OP_CAST);
    return symbols[op as usize];
}

const fn leaf(t: u8, lit: String) Node {
    return Node { op: OP_LEAF, ty: t, a: 0, b: 0, lit: lit };
}

const fn unary(op: u8) bool {
    return op == OP_NEG || op == OP_NOT || op == OP_CAST;
}

extend ScalarModel {
    fn push_node(self: &mut ScalarModel, n: Node) u32 {
        self.nodes.push(n);
        return (self.nodes.len() - 1) as u32;
    }

    // Draw an expression of type `t` at most `depth` operators deep; its root index.
    fn gen_expr(self: &mut ScalarModel, rng: &mut Rng, t: u8, depth: u64) u32 {
        if depth == 0 || rng.one_in(4) {
            if is_float(t) {
                return self.push_node(leaf(t, float_literal(rng, t)));
            }
            return self.push_node(leaf(t, int_literal(rng, t)));
        }
        let mut op = OP_CAST;
        if is_float(t) {
            let ops: []u8 = [OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_REM, OP_NEG, OP_CAST];
            op = ops[rng.below(ops.len() as u64) as usize];
        } else {
            let ops: []u8 = [
                OP_ADD,
                OP_SUB,
                OP_MUL,
                OP_DIV,
                OP_REM,
                OP_AND,
                OP_OR,
                OP_XOR,
                OP_SHL,
                OP_SHR,
                OP_NEG,
                OP_NOT,
                OP_CAST,
            ];
            op = ops[rng.below(ops.len() as u64) as usize];
            if op == OP_NEG && !is_signed(t) {
                op = OP_NOT;
            }
        }
        let mut n = Node { op: op, ty: t, a: 0, b: 0, lit: String::new() };
        if op == OP_CAST {
            n.a = self.gen_expr(rng, rng.below(TYPES_N) as u8, depth - 1);
        } else {
            n.a = self.gen_expr(rng, t, depth - 1);
        }
        if op == OP_SHL || op == OP_SHR {
            n.b = self.push_node(leaf(t, shift_count(rng, t)));
        } else if !unary(op) {
            n.b = self.gen_expr(rng, t, depth - 1);
        }
        return self.push_node(n);
    }

    fn render_node(self: &ScalarModel, i: u32, wrapping: bool, out: &mut String) {
        let n = self.nodes.at(i as usize);
        let name = type_name(n.ty);
        if n.op == OP_LEAF {
            out.format_into("opq::<{}>({})", name, n.lit.as_str());
            return;
        }
        if n.op == OP_CAST {
            out.push_byte(b'(');
            self.render_node(n.a, wrapping, out);
            out.format_into(" as {})", name);
            return;
        }
        let wrap = wrapping && !is_float(n.ty);
        if n.op == OP_NEG && wrap {
            self.render_node(n.a, wrapping, out);
            out.push_str(".wrapping_neg()");
            return;
        }
        if n.op == OP_NEG || n.op == OP_NOT {
            out.push_str(
                if n.op == OP_NEG {
                    "(-";
                } else {
                    "(~";
                },
            );
            self.render_node(n.a, wrapping, out);
            out.push_byte(b')');
            return;
        }
        if wrap && (n.op == OP_ADD || n.op == OP_SUB || n.op == OP_MUL) {
            self.render_node(n.a, wrapping, out);
            out.format_into(".wrapping_{}(", op_name(n.op));
            self.render_node(n.b, wrapping, out);
            out.push_byte(b')');
            return;
        }
        out.push_byte(b'(');
        self.render_node(n.a, wrapping, out);
        out.format_into(" {} ", op_symbol(n.op));
        self.render_node(n.b, wrapping, out);
        out.push_byte(b')');
    }

    // The nodes reachable from the cases, in preorder.
    fn reachable(self: &ScalarModel) Vector<u32> {
        let mut order = Vector::<u32>::new();
        let mut stack = Vector::<u32>::new();
        for c in 0..self.roots.len() {
            stack.push(*self.roots.at(self.roots.len() - 1 - c));
        }
        while let Some(i) = stack.pop() {
            assert(order.len() < self.nodes.len()); // the cases are disjoint trees
            order.push(i);
            let n = self.nodes.at(i as usize);
            if n.op == OP_LEAF {
                continue;
            }
            if !unary(n.op) {
                stack.push(n.b);
            }
            stack.push(n.a);
        }
        return order;
    }

    fn exprs(self: &ScalarModel, wrapping: bool) Vector<String> {
        let mut v = Vector::<String>::new();
        for c in 0..self.roots.len() {
            let mut s = String::new();
            self.render_node(*self.roots.at(c), wrapping, &mut s);
            v.push(s);
        }
        return v;
    }

    fn types(self: &ScalarModel) Vector<str<'static>> {
        let mut v = Vector::<str<'static>>::new();
        for c in 0..self.roots.len() {
            v.push(type_name(self.nodes.at((*self.roots.at(c)) as usize).ty));
        }
        return v;
    }

    // Oracle 1's program: case `k` runs with `prog k`. Under `release` each case is the plain
    // expression, under any other profile the wrapping one, both through the opaque `opr`.
    fn profile_program(self: &ScalarModel) String {
        let plain = self.exprs(false);
        let wrapping = self.exprs(true);
        let tys = self.types();
        let mut s = String::from_str("static mut SINK: usize = 0;\n@c.noinline\nfn opr<T>(x: T) T {\n");
        s.push_str("    unsafe SINK += 1;\n    return x;\n}\n");
        s.push_str(
            "union F64 {\n    pub f: f64,\n    pub u: u64,\n}\nunion F32 {\n    pub f: f32,\n    pub u: u32,\n}\n",
        );
        s.push_str("fn show_f64(v: f64) {\n    if v.is_nan() {\n        println(\"nan\");\n    } else {\n");
        s.push_str("        println(\"{}\", F64 { f: v }.u);\n    }\n}\n");
        s.push_str("fn show_f32(v: f32) {\n    if v.is_nan() {\n        println(\"nan\");\n    } else {\n");
        s.push_str("        println(\"{}\", F32 { f: v }.u);\n    }\n}\n");
        for k in 0..plain.len() {
            let p = plain.at(k).replace("opq::", "opr::");
            let w = wrapping.at(k).replace("opq::", "opr::");
            s.format_into("@c.noinline\nfn case{}() {} {{\n    return if PROFILE == \"release\" {{\n", k, *tys.at(k));
            s.format_into("        {};\n    }} else {{\n        {};\n    }};\n}}\n", p.as_str(), w.as_str());
        }
        s.push_str("fn main(args: Vector<str>) i32 {\n    let k = args.at(1).parse_i64().unwrap();\n");
        for k in 0..plain.len() {
            let t = *tys.at(k);
            if t == "f64" || t == "f32" {
                s.format_into("    if k == {} {{\n        show_{}(case{}());\n    }}\n", k, t, k);
            } else {
                s.format_into("    if k == {} {{\n        println(\"{{}}\", case{}());\n    }}\n", k, k);
            }
        }
        s.push_str("    return 0;\n}\n");
        return s;
    }

    // The model's planted options after `first` (none when empty).
    fn opts_with<'a>(self: &'a ScalarModel, first: str<'static>) Vector<str<'a>> {
        let mut v = Vector::<str>::new();
        if first.len() != 0 {
            v.push(first);
        }
        for i in 0..self.opts.len() {
            v.push(self.opts.at(i).as_str());
        }
        return v;
    }
}

extend ScalarModel as Model {
    pub fn name(self: &Self) str<'static> {
        return "scalar";
    }

    pub fn generate(self: &mut Self, rng: &mut Rng) {
        self.nodes.clear();
        self.roots.clear();
        let cases = 1 + rng.below(self.cases_max);
        for _ in 0..cases {
            let t = rng.below(TYPES_N) as u8;
            let d = 1 + rng.below(self.depth_max);
            let r = self.gen_expr(rng, t, d);
            self.roots.push(r);
        }
    }

    pub fn oracles(self: &Self) usize {
        return 2;
    }

    pub fn check(self: &Self, k: usize) String {
        if k == 0 {
            let ex = self.exprs(false);
            let mut ev = Vector::<str>::new();
            for i in 0..ex.len() {
                ev.push(ex.at(i).as_str());
            }
            let tys = self.types();
            let o = self.opts_with("");
            return h::const_runtime_parity("", ev[0..ev.len()], tys[0..tys.len()], o[0..o.len()]);
        }
        let src = self.profile_program();
        let mut runs = Vector::<String>::new();
        for c in 0..self.roots.len() {
            let mut a = String::new();
            a.push_u64(c as u64);
            runs.push(a);
        }
        let mut rv = Vector::<str>::new();
        for i in 0..runs.len() {
            rv.push(runs.at(i).as_str());
        }
        let dev = self.opts_with("--profile=dev");
        let rel = self.opts_with("--profile=release");
        return h::same_output(src.as_str(), dev[0..dev.len()], rel[0..rel.len()], rv[0..rv.len()]);
    }

    pub fn render(self: &Self, k: usize) String {
        if k == 0 {
            let ex = self.exprs(false);
            let mut ev = Vector::<str>::new();
            for i in 0..ex.len() {
                ev.push(ex.at(i).as_str());
            }
            let tys = self.types();
            return h::parity_program("", ev[0..ev.len()], tys[0..tys.len()]);
        }
        return self.profile_program();
    }

    // Keep only case c, drop case c, then for each reachable node (preorder): replace it by its first
    // operand, by its second operand (both where the type is the same), or by the leaf 1.
    pub fn candidates(self: &Self) usize {
        return 2 * self.roots.len() + 3 * self.reachable().len();
    }

    pub fn reduce(self: &mut Self, i: usize) bool {
        let cases = self.roots.len();
        if i < 2 * cases {
            if cases == 1 {
                return false;
            }
            if i < cases {
                let keep = *self.roots.at(i);
                self.roots.clear();
                self.roots.push(keep);
            } else {
                let _ = self.roots.remove(i - cases);
            }
            return true;
        }
        let order = self.reachable();
        let j = (i - 2 * cases) / 3;
        let form = (i - 2 * cases) % 3;
        let at = (*order.at(j)) as usize;
        let n = self.nodes.at(at).clone();
        if form == 2 {
            if n.op == OP_LEAF && (n.lit.as_str() == "1" || n.lit.as_str() == "1.0") {
                return false;
            }
            let one = if is_float(n.ty) {
                "1.0";
            } else {
                "1";
            };
            self.nodes[at] = leaf(n.ty, String::from_str(one));
            return true;
        }
        if n.op == OP_LEAF || form == 1 && unary(n.op) {
            return false;
        }
        let c = if form == 0 {
            n.a;
        } else {
            n.b;
        };
        let child = self.nodes.at(c as usize).clone();
        if child.ty != n.ty {
            return false;
        }
        self.nodes[at] = child;
        return true;
    }
}
