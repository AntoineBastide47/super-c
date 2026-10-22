// Self-hosted port of tests/codegen_run_test.c (behavioral end-to-end: each snippet is transpiled, cc-
// compiled, linked and RUN, and its result checked). Programs signal their result via `exit(code)`; the
// harness's compile_and_run builds them through `super-c build` and captures the exit code. This seeds the
// suite with the pure-computation families; the remaining families (slices, strings, closures, generics,
// I/O via putchar) extend it the same way with run_exit / h::expect_run.
import tests::harness as h;
import tests::cli_harness as cli;

const PRE: str = "extern \"C\" { @c.noreturn fn exit(code: i32) void; fn putchar(c: i32) i32; }\n";

// Splice PRE ahead of `body`, build+run the program, and assert it exits with `code`.
fn run_exit(label: str, body: str, code: i32) {
    let mut src = String::from_str(PRE);
    src.push_str(body);
    h::expect_exit(label, src.as_str(), code);
}

// `run_exit` as a case of batch `b`.
fn exit_case(b: &mut h::ExitBatch, label: str, body: str, code: i32) {
    let mut src = String::from_str(PRE);
    src.push_str(body);
    b.add(label, src.as_str(), code);
}

fn operator_overload_lowering(b: &mut h::ExitBatch) {
    // Compound assignment on an operator-overloaded struct lowers through the method (C cannot += structs).
    exit_case(
        b,
        "struct compound assignment",
        "struct P { pub x: i32, }\nextend P { pub fn add(self: &P, o: &P) P { return P { x: self.x + o.x }; } pub fn mul(self: &P, o: &P) P { return P { x: self.x * o.x }; } }\nfn main() i32 { let mut a = P { x: 2 }; let b = P { x: 3 }; a += b; a *= b; unsafe exit(a.x); }\n",
        15,
    );
    // Bitwise and shift operators dispatch the same way. A shift's right operand is a COUNT, so it is
    // passed BY VALUE where `&` passes its operand by reference: the two are lowered differently.
    exit_case(
        b,
        "bitwise and shift overloads",
        "struct M { pub b: u32, }\nextend M { pub fn bit_and(self: &M, o: &M) M { return M { b: self.b & o.b }; } pub fn bit_or(self: &M, o: &M) M { return M { b: self.b | o.b }; } pub fn bit_xor(self: &M, o: &M) M { return M { b: self.b ^ o.b }; } pub fn bit_not(self: &M) M { return M { b: ~self.b }; } pub fn shl(self: &M, n: usize) M { return M { b: self.b << n as u32 }; } pub fn shr(self: &M, n: usize) M { return M { b: self.b >> n as u32 }; } }\nfn main() i32 {\n    let a = M { b: 0b1100 };\n    let b = M { b: 0b1010 };\n    let mut acc = a;\n    acc &= b;\n    acc |= M { b: 1 };\n    acc ^= M { b: 2 };\n    acc <<= 2;\n    acc >>= 1;\n    let n = (~a).b & 0xF;\n    unsafe exit(((a & b).b + (a | b).b + (a ^ b).b + (a << 1).b + (a >> 2).b + acc.b + n) as i32);\n}\n",
        80,
    );
    // String patterns in switch compare through str's eq, incl. inside an enum payload.
    exit_case(
        b,
        "string switch patterns",
        "fn pick(s: str) i32 { return switch s { \"build\" => 1, \"fmt\" => 2, _ => 3, }; }\nfn pay(o: Option<str>) i32 { return switch o { Some(\"x\") => 10, Some(_) => 20, None => 30, }; }\nfn main() i32 { unsafe exit(pick(\"build\") + pick(\"fmt\") * 2 + pick(\"?\") * 3 + pay(Option::<str>::Some(\"x\")) + pay(Option::<str>::Some(\"y\")) + pay(Option::<str>::None)); }\n",
        74,
    );
    // String range patterns test through str's cmp (lexicographic buckets).
    exit_case(
        b,
        "string range patterns",
        "fn bucket(s: str) i32 { return switch s { \"a\"..\"m\" => 1, \"m\"..\"z\" => 2, _ => 3, }; }\nfn main() i32 { unsafe exit(bucket(\"apple\") + bucket(\"pear\") * 2 + bucket(\"~t\") * 3); }\n",
        14,
    );
}

fn user_index_on_concrete_structs(b: &mut h::ExitBatch) {
    // A struct's own `index`/`index_mut` (a plain extend or a generic conformance) is called for a
    // read, a store, a compound store and `&mut v[i]`, at run time and in a constant.
    exit_case(
        b,
        "user index and index_mut",
        "struct W { pub e: [i32; 3] }\nextend W {\n    pub fn index(self: &W, i: usize) &i32 { return &unsafe self.e[i]; }\n    pub fn index_mut(self: &mut W, i: usize) &mut i32 { return &mut unsafe self.e[i]; }\n}\nstruct V<T, const N: usize> { pub e: [T; N] }\nextend<T: Copy, const N: usize> V<T, N> as Index<T, []T> {\n    pub fn index(self: &V<T, N>, i: usize) &T { if i >= N { panic(\"oob\"); } return &unsafe self.e[i]; }\n    pub fn index_range(self: &V<T, N>, r: Range<usize>) []T { return unsafe Slice::<T> { ptr: (&self.e[0] as *const T) + r.start, len: r.end - r.start }; }\n}\nextend<T: Copy, const N: usize> V<T, N> as IndexMut<T, []mut T> {\n    pub fn index_mut(self: &mut V<T, N>, i: usize) &mut T { if i >= N { panic(\"oob\"); } return &mut unsafe self.e[i]; }\n    pub fn index_range_mut(self: &mut V<T, N>, r: Range<usize>) []mut T { return unsafe SliceMut::<T> { ptr: (&mut self.e[0] as *mut T) + r.start, len: r.end - r.start }; }\n}\nfn k() i32 {\n    let mut v = V::<i32, 2> { e: [1, 2] };\n    v[1] = 7;\n    return v[1];\n}\nconst K: i32 = k();\nfn main() i32 {\n    let mut w = W { e: [1, 2, 3] };\n    w[1] = 9;\n    w[0] += 4;\n    let r = &mut w[2];\n    *r = 10;\n    let mut v = V::<i32, 3> { e: [1, 2, 3] };\n    v[2] = w[0] + w[1];\n    v[0] *= 3;\n    unsafe exit(w[0] + w[1] + w[2] + v[0] + v[2] + K);\n}\n",
        48,
    );
}

fn user_index_range_on_concrete_structs(b: &mut h::ExitBatch) {
    // `v[lo..hi]` on a struct calls its `index_range` with the bounds in a `Range<usize>` (a missing
    // start is 0, a missing end its `len()`), `&mut v[lo..hi]` its `index_range_mut`, in a generic
    // body, at run time and in a constant.
    exit_case(
        b,
        "user index_range and index_range_mut",
        "struct V<const N: usize> { pub e: [i32; N] }\nextend<const N: usize> V<N> { pub fn len(self: &V<N>) usize { return N; } }\nextend<const N: usize> V<N> as Index<i32, []i32> {\n    pub fn index(self: &V<N>, i: usize) &i32 { return &unsafe self.e[i]; }\n    pub fn index_range(self: &V<N>, r: Range<usize>) []i32 {\n        let hi = r.end + (r.inclusive as usize);\n        if r.start > hi || hi > N { panic(\"oob\"); }\n        return unsafe Slice::<i32> { ptr: (&self.e[0] as *const i32) + r.start, len: hi - r.start };\n    }\n}\nextend<const N: usize> V<N> as IndexMut<i32, []mut i32> {\n    pub fn index_mut(self: &mut V<N>, i: usize) &mut i32 { return &mut unsafe self.e[i]; }\n    pub fn index_range_mut(self: &mut V<N>, r: Range<usize>) []mut i32 {\n        let hi = r.end + (r.inclusive as usize);\n        if r.start > hi || hi > N { panic(\"oob\"); }\n        return unsafe SliceMut::<i32> { ptr: (&mut self.e[0] as *mut i32) + r.start, len: hi - r.start };\n    }\n}\nfn sum(s: []i32) i32 { let mut t = 0; for x in s { t += x; } return t; }\nfn tail<const N: usize>(v: &V<N>, k: usize) []i32 { return v[k..]; }\nfn ts() i32 { let v = V::<4> { e: [1, 2, 3, 4] }; return sum(v[1..]); }\nconst TS: i32 = ts();\nfn main() i32 {\n    let mut v = V::<4> { e: [1, 2, 3, 4] };\n    let w = &mut v[2..];\n    w[0] = 7;\n    unsafe exit(sum(v[1..3]) + sum(v[..=1]) * 10 + sum(tail(&v, 3)) + TS);\n}\n",
        52,
    );
}

// Of two conformances to one operator interface, the one whose extend bounds the operand's instance
// does not satisfy (`V<T: Int, N>` for `V<bool, 2>`) is no candidate.
fn operator_candidates_respect_extend_bounds(b: &mut h::ExitBatch) {
    b.add(
        "bounded and concrete BitAnd",
        M"(interface Int: Copy {}
extend i32 as Int {}
struct V<T, const N: usize> { pub e: [T; N] }
extend<const N: usize> V<bool, N> as BitAnd {
    type Output = V<bool, N>;
    pub fn bit_and(self: &V<bool, N>, o: &V<bool, N>) V<bool, N> {
        let mut r = *self;
        for i in 0..N { unsafe { r.e[i] = self.e[i] && o.e[i]; } }
        return r;
    }
}
extend<T: Int, const N: usize> V<T, N> as BitAnd {
    type Output = V<T, N>;
    pub fn bit_and(self: &V<T, N>, o: &V<T, N>) V<T, N> { return *self; }
}
fn main() i32 {
    let c = V::<bool, 2> { e: [true, false] } & V::<bool, 2> { e: [true, true] };
    let d = V::<i32, 2> { e: [3, 4] } & V::<i32, 2> { e: [1, 1] };
    return c.e[0] as i32 + c.e[1] as i32 * 2 + d.e[1];
}
)",
        5,
    );
}

// Two generic conformances of one type to one interface whose arguments both fit (`i32 as Count<T>`
// with `T: Num`, `i32 as Count<W<T>>`): the bound check, the dispatch at run time and in a constant
// all take the one whose bounds hold; and two generic conformances whose interface-solved parameters
// have disjoint bounds (`T as Mix<U>` with `U: Fl`, `T as Mix<bool>`) do not conflict.
fn conformance_chosen_by_bounds(b: &mut h::ExitBatch) {
    b.add(
        "Count<f32> and Count<W<f32>> on i32",
        M"(interface Num: Copy {}
extend f32 as Num {}
struct W<T: Num> { pub v: T }
interface Count<G>: Copy { fn count(self: Self) i32; }
extend<T: Num> i32 as Count<T> { pub fn count(self: i32) i32 { return self; } }
extend<T: Num> i32 as Count<W<T>> { pub fn count(self: i32) i32 { return self + 1; } }
fn steps<G, U: Count<G>>(x: G, n: U) i32 { let _ = x; return n.count(); }
const A: i32 = steps(1.0f32, 3);
const B: i32 = steps(W::<f32> { v: 1.0 }, 3);
fn main() i32 { let n: i32 = 3; return steps(1.0f32, n) + steps(W::<f32> { v: 1.0 }, n) * 10 + A + B * 2; }
)",
        54,
    );
    b.add(
        "Mix<U: Fl> and Mix<bool>",
        M"(interface Fl: Copy { fn lerp(a: Self, b: Self, t: Self) Self; }
extend f32 as Fl { pub fn lerp(a: f32, b: f32, t: f32) f32 { return a + (b - a) * t; } }
interface Mix<A>: Copy { fn mix(self: Self, y: Self, a: A) Self; }
extend<U: Fl> f32 as Mix<U> { pub fn mix(self: f32, y: f32, a: U) f32 { let _ = a; return self + y; } }
extend f32 as Mix<bool> { pub fn mix(self: f32, y: f32, a: bool) f32 { return if a { y; } else { self; }; } }
fn mix<G: Mix<A>, A>(x: G, y: G, a: A) G { return x.mix(y, a); }
fn gen<T: Fl>(x: f32, t: T) f32 { return mix(x, 2.0, t); }
fn main() i32 { return (mix(1.0f32, 6.0f32, true) + gen(1.0, 0.5f32)) as i32; }
)",
        9,
    );
}

// Through a generic type named without arguments (`V::new(..)`), the argument count picks among
// associated functions of disjoint extends, and the instance follows from the chosen one.
fn argument_count_picks_an_associated_function(b: &mut h::ExitBatch) {
    b.add(
        "V::new with 2 and 3 arguments",
        "struct V<T, const N: usize> { pub e: [T; N] }\nextend<T: Copy> V<T, 2> { pub fn new(x: T, y: T) V<T, 2> { return V::<T, 2> { e: [x, y] }; } }\nextend<T: Copy> V<T, 3> { pub fn new(x: T, y: T, z: T) V<T, 3> { return V::<T, 3> { e: [x, y, z] }; } }\nfn main() i32 { let a = V::new(1, 2); let b = V::new(1, 2, 3); return a.e[1] + b.e[2] * 10; }\n",
        32,
    );
}

fn operators_of_generic_shapes(b: &mut h::ExitBatch) {
    // An overloaded operator from an extend whose parameter only the interface solves (`K`), a
    // scalar-on-the-left operator through a type parameter's generic conformance, and more than eight
    // same-named operator methods on one type.
    exit_case(
        b,
        "keyed operators and a generic conformance through a type parameter",
        "struct M<const C: usize, const R: usize> { pub v: [[i32; R]; C] }\nextend<const C: usize, const R: usize, const K: usize> M<C, R> as Mul<M<K, C>> {\n    type Output = M<K, R>;\n    pub fn mul(self: &M<C, R>, b: &M<K, C>) M<K, R> {\n        let mut m = M::<K, R> { v: [[0; R]; K] };\n        for k in 0..K { for r in 0..R { for i in 0..C { unsafe { m.v[k][r] = m.v[k][r] + self.v[i][r] * b.v[k][i]; } } } }\n        return m;\n    }\n}\nextend<const C: usize, const R: usize> M<C, R> as Mul<i32> {\n    type Output = M<C, R>;\n    pub fn mul(self: &M<C, R>, s: &i32) M<C, R> {\n        let mut m = *self;\n        for k in 0..C { for r in 0..R { unsafe { m.v[k][r] = self.v[k][r] * *s; } } }\n        return m;\n    }\n}\nextend<const C: usize, const R: usize> M<C, R> as Mul<bool> {\n    type Output = M<C, R>;\n    pub fn mul(self: &M<C, R>, s: &bool) M<C, R> { return *self; }\n}\nstruct D { pub x: i32 }\nextend D as Div<i8> { type Output = i32; pub fn div(self: &D, o: &i8) i32 { return 1; } }\nextend D as Div<i16> { type Output = i32; pub fn div(self: &D, o: &i16) i32 { return 2; } }\nextend D as Div<i32> { type Output = i32; pub fn div(self: &D, o: &i32) i32 { return self.x / *o; } }\nextend D as Div<i64> { type Output = i32; pub fn div(self: &D, o: &i64) i32 { return 4; } }\nextend D as Div<u8> { type Output = i32; pub fn div(self: &D, o: &u8) i32 { return 5; } }\nextend D as Div<u16> { type Output = i32; pub fn div(self: &D, o: &u16) i32 { return 6; } }\nextend D as Div<u32> { type Output = i32; pub fn div(self: &D, o: &u32) i32 { return 7; } }\nextend D as Div<u64> { type Output = i32; pub fn div(self: &D, o: &u64) i32 { return 8; } }\nextend D as Div<f32> { type Output = i32; pub fn div(self: &D, o: &f32) i32 { return 9; } }\nextend D as Div<f64> { type Output = i32; pub fn div(self: &D, o: &f64) i32 { return 10; } }\ninterface Sc: Copy { fn sub(self: &Self, o: &Self) Self; }\nextend i32 as Sc { pub fn sub(self: &i32, o: &i32) i32 { return *self - *o; } }\nstruct V { pub x: i32 }\nextend<T: Sc> T as Sub<V> { type Output = V; pub fn sub(self: &T, v: &V) V { return V { x: 100 - v.x }; } }\nfn lhs<T: Sc>(t: T, v: V) V { return t - v; }\nfn main() i32 {\n    let a = M::<2, 3> { v: [[1, 2, 3], [4, 5, 6]] };\n    let b = M::<3, 2> { v: [[1, 0], [0, 1], [1, 1]] };\n    let p = a * b * 2;\n    let d = D { x: 12 } / 4;\n    unsafe exit(p.v[2][2] + d + lhs(7, V { x: 90 }).x);\n}\n",
        31,
    );
    // In a generic body, a fixed argument of the right operand's type (`3` in `V<T, 3>`) chooses the
    // conformance whose parameter has it.
    exit_case(
        b,
        "a right operand over a type parameter",
        "struct V<T, const N: usize> { pub e: [T; N] }\nstruct G<T> { pub k: T }\nextend<T: Copy> G<T> as Mul<V<T, 3>> {\n    type Output = i32;\n    pub fn mul(self: &G<T>, v: &V<T, 3>) i32 { return 30; }\n}\nextend<T: Copy> G<T> as Mul<V<T, 4>> {\n    type Output = i32;\n    pub fn mul(self: &G<T>, v: &V<T, 4>) i32 { return 40; }\n}\nfn g<T: Copy>(x: G<T>, t: T) i32 {\n    return x * V::<T, 3> { e: [t, t, t] } + x * V::<T, 4> { e: [t, t, t, t] };\n}\nfn main() i32 {\n    unsafe exit(g(G::<i32> { k: 1 }, 2));\n}\n",
        70,
    );
    // A compound assignment chooses its overload as the plain operator does: `v += 1` takes
    // `Add<i32>`, a by-value shift count stays by value, and an unsuffixed literal takes the
    // conformance's type (`w * 3` with `Mul<u8>`).
    exit_case(
        b,
        "compound assignments and literal right operands",
        "struct V { pub x: i32 }\nextend V as Add { type Output = V; pub fn add(self: &V, o: &V) V { return V { x: self.x + o.x }; } }\nextend V as Add<i32> { type Output = V; pub fn add(self: &V, s: &i32) V { return V { x: self.x + *s }; } }\nextend V as Shl<V> { type Output = V; pub fn shl(self: &V, n: V) V { return V { x: self.x << n.x }; } }\nstruct W { pub x: u8 }\nextend W as Mul { type Output = W; pub fn mul(self: &W, o: &W) W { return W { x: self.x * o.x }; } }\nextend W as Mul<u8> { type Output = W; pub fn mul(self: &W, s: &u8) W { return W { x: self.x * *s }; } }\nfn main() i32 {\n    let mut v = V { x: 1 };\n    v += 1;\n    v += V { x: 1 };\n    v <<= V { x: 2 };\n    let w = W { x: 2 } * 3;\n    let mut u = W { x: 1 };\n    u *= 5;\n    unsafe exit(v.x + w.x as i32 + u.x as i32);\n}\n",
        23,
    );
}

fn escaped_names_stay_distinct(b: &mut h::ExitBatch) {
    // An escaped name gains a `_` (`sqrt` is a <tgmath.h> macro, `int` a keyword, `printf` a library
    // symbol), so a name that already ends in `_` after such a stem gains one too: each pair below
    // links as two symbols.
    exit_case(
        b,
        "escaped and underscored names",
        "fn sqrt(x: i32) i32 { return x + 1; }\nfn sqrt_(x: i32) i32 { return x + 2; }\nfn printf(x: i32) i32 { return x + 3; }\nfn printf_(x: i32) i32 { return x + 4; }\nstruct S { pub v: i32 }\nextend S {\n    pub fn int(self: &S) i32 { return self.v; }\n    pub fn int_(self: &S) i32 { return self.v * 2; }\n}\ninterface Root { fn sqrt_(self: Self) Self; }\nextend f32 as Root { pub fn sqrt_(self: f32) f32 { return self + 1.0; } }\nfn main() i32 {\n    let s = S { v: 5 };\n    unsafe exit(sqrt(0) + sqrt_(0) + printf(0) + printf_(0) + s.int() + s.int_() + (4.0f32.sqrt() + 4.0f32.sqrt_()) as i32);\n}\n",
        32,
    );
}

@test
fn prelude_names_stay_distinct() {
    // A program of one user module spells its symbols without a module prefix, as the prelude does,
    // so a top-level name a prelude item also has (`format`, `likely`, `Global`, `FpClass`) gains a
    // `_`, and so does a name that ends in `_` after such a stem: the program builds and both sides
    // keep their own symbols (std's `likely` and `Global__alloc`, the prelude `FpClass`).
    run_exit(
        "user items named as prelude items",
        "@noinline\nfn format(buf: *mut char, n: usize, fmt: *const char, ...) i32 { unsafe *buf = 0 as char; return n as i32 + (unsafe *fmt == 0 as char) as i32; }\n@noinline\nfn format_(x: i32) i32 { return x + 1; }\n@noinline\nfn likely(c: i32) i32 { return c + 2; }\nstruct Global { pub a: i32 }\nextend Global { @noinline pub fn alloc(self: &Global) i32 { return self.a; } }\nenum FpClass { FP_ZERO, FP_NAN }\n@noinline\nfn pick(n: i32) FpClass { if n > 0 { return FpClass::FP_NAN; } return FpClass::FP_ZERO; }\nfn main() i32 {\n    let mut b: [char; 4] = [1 as char; 4];\n    let mut v = Vector::<i32>::new();\n    v.push(Global { a: 3 }.alloc());\n    let f = switch f16::from_f32(0.0).classify() { FP_ZERO => 16, _ => 0, };\n    let e = switch pick(1) { FP_ZERO => 0, FP_NAN => 8, };\n    println(\"{}\", v[0]);\n    return format(&mut b[0], 4, \"\\0\".ptr() as *const char, 7) + format_(1) + likely(1) + v[0] + e + f;\n}\n",
        37,
    );
}

@test
fn matchertext() {
    // Plain literals decode verbatim (embedded quotes, no escape processing); interpolation
    // desugars through the sugar_fmt_* path; format() accepts a matchertext template with `{}`
    // placeholders; interp segments keep doubled braces (they are matchers, not escapes).
    run_exit(
        "matchertext literals and interpolation",
        "fn main() i32 {\n    let a = M\"(ab\"cd)\";\n    let b = M[]\"(v=[10 + 4] q=[a.len() as i32])\";\n    let mut r = 0;\n    if a.len() == 5 { r += 1; }\n    if a[2] == 34u8 { r += 2; }\n    if b.as_str() == \"v=14 q=5\" { r += 4; }\n    if M\"[mix {a} (b)]\" == \"mix {a} (b)\" { r += 8; }\n    let f = format(M\"(x={} {{lit}})\", 9);\n    if f.as_str() == \"x=9 {lit}\" { r += 16; }\n    const K: str = M\"(k)\";\n    if K == \"k\" { r += 32; }\n    let g = M[]\"(brace {{x}} [1])\";\n    if g.as_str() == \"brace {{x}} 1\" { r += 64; }\n    unsafe exit(r);\n}\n",
        127,
    );
    // The runtime hole guard: a spliced value must itself be matchertext; compliant values
    // (matched matchers) pass, a breakout value panics; format() args stay unchecked.
    run_exit(
        "matchertext hole guard accepts compliant values",
        "fn main() i32 { let ok = \"(a) [b] {c}\"; let s = M{}\"(v={ok})\"; let f = format(\"{}\", \"loose (\"); let mut r = s.len() as i32; if f.len() == 7 { r += 1; } unsafe exit(r); }\n",
        14,
    );
    let bad = h::compile_and_run(
        "fn main() i32 { let evil = \"Eve(\"; let s = M{}\"(Hi {evil})\"; return s.len() as i32; }\n",
    );
    assert(bad.built, "matchertext guard snippet builds");
    assert(
        bad.exit != 0 && cli::contains_str(bad.out, "panic: matchertext interpolation: value is not matchertext"),
        "a non-matchertext hole value must panic, not splice",
    );
}

fn inlined_callee_keeps_its_guarded_drop(b: &mut h::ExitBatch) {
    // `f` is small enough to inline into `main` and carries a flag-guarded drop: the splice must
    // rebase the flag local with the callee's locals, or the guard reads a caller local. Under the
    // leak gate a wrong guard is a leak or a double free, both nonzero exits.
    exit_case(
        b,
        "inlined guarded drop",
        "pub fn take(s: String) { s.free(); }\npub fn f(c: bool) i32 { let s = String::from_str(\"abc\"); if c { take(s); return 1; } return s.len() as i32; }\nfn main() i32 { unsafe exit(f(true) + f(false)); }\n",
        4,
    );
}

fn arithmetic(b: &mut h::ExitBatch) {
    exit_case(b, "precedence", "fn main() i32 { unsafe exit(1 + 2 * 3 - 4 / 2); }\n", 5);
    exit_case(b, "mixed precedence", "fn main() i32 { unsafe exit(17 % 5 + 100 / 7 + 6 & 3); }\n", 2);
    exit_case(
        b,
        "bitwise",
        "fn main() i32 { let a: i32 = 6 & 3; let b: i32 = 6 | 1; let c: i32 = 1 << 4; unsafe exit(a + b + c); }\n",
        25,
    );
    exit_case(b, "right shift", "fn main() i32 { let mut x: i32 = 32; x >>= 2; unsafe exit(x + (16 >> 2)); }\n", 12);
    exit_case(b, "unary neg", "fn main() i32 { let y: i32 = -5; unsafe exit(0 - y); }\n", 5);
    exit_case(b, "unary not", "fn main() i32 { unsafe exit(switch !false { true => 7, _ => 0, }); }\n", 7);
}

fn control_flow(b: &mut h::ExitBatch) {
    exit_case(
        b,
        "while break",
        "fn main() i32 { let mut i: i32 = 0; while true { if i >= 5 { break; } i = i + 1; } unsafe exit(i); }\n",
        5,
    );
    exit_case(
        b,
        "for continue",
        "fn main() i32 { let mut t: i32 = 0; for i in 0..5 { if i == 2 { continue; } t = t + i; } unsafe exit(t); }\n",
        8,
    );
    exit_case(
        b,
        "nested for",
        "fn main() i32 { let mut t: i32 = 0; for i in 0..3 { for j in 0..3 { t = t + 1; } } unsafe exit(t); }\n",
        9,
    );
    exit_case(
        b,
        "do while",
        "fn main() i32 { let mut i: i32 = 0; let mut s: i32 = 0; do { s = s + i; i = i + 1; } while i < 5; unsafe exit(s); }\n",
        10,
    );
    exit_case(
        b,
        "do while runs once",
        "fn main() i32 { let mut n: i32 = 0; do { n = n + 7; } while false; unsafe exit(n); }\n",
        7,
    );
    // A loop over a `static mut` steps it in the body: a `for` header cannot spell the static.
    exit_case(
        b,
        "while over a static",
        "static mut N: i32 = 0;\nfn more() bool { return true; }\nfn drain() { while unsafe N > 1 { if !more() { return; } unsafe N -= 1; } unsafe N = 0; }\nfn main() i32 { unsafe N = 5; drain(); unsafe exit(unsafe N + 3); }\n",
        3,
    );
    // An exit from a range loop inside `loop` reads the index after the C loops close.
    exit_case(
        b,
        "range index read past an infinite loop",
        "fn find(xs: []i32, n: i32) i32 { let mut k: i32 = 0; loop { k += 1; if k > 100 { return -1; } for i in 0..n { if k == xs[i as usize] { return i; } } } }\nfn main() i32 { unsafe exit(find([9, 4, 7], 3)); }\n",
        1,
    );
}

fn float_constants_exact(b: &mut h::ExitBatch) {
    // Folded float consts and static float slots keep every bit: each is compared at run time with
    // the value libc parses (or computes) from the same text, and infinity and NaN stay valid C.
    exit_case(
        b,
        "exact float consts and statics",
        "extern \"C\" { fn strtod(s: *const char, e: *mut *mut char) f64; }\nstruct P { pub a: f64, pub b: f32 }\nconst PI: f64 = 3.14159265358979;\nconst TAU: f64 = PI * 2.0;\nconst F: f32 = 0.1;\nconst PINF: f64 = PI * 1e308;\nconst QNAN: f64 = PINF - PINF;\nstatic mut SP: P = P { a: PI / 7.0, b: 0.1 };\nfn rd(s: str) f64 { return unsafe strtod(s.ptr() as *const char, null); }\nfn main() i32 {\n    let pi = rd(\"3.14159265358979\");\n    let q = QNAN + pi;\n    let mut bad = 0;\n    if PI != pi { bad |= 1; }\n    if TAU != pi * 2.0 { bad |= 2; }\n    if F != rd(\"0.1\") as f32 { bad |= 4; }\n    if PINF <= pi * 1e300 || q == q { bad |= 8; }\n    if unsafe SP.a != pi / 7.0 || unsafe SP.b != rd(\"0.1\") as f32 { bad |= 16; }\n    unsafe exit(bad);\n}\n",
        0,
    );
}

fn switches(b: &mut h::ExitBatch) {
    exit_case(
        b,
        "switch literal + name binding",
        "fn classify(c: i32) i32 { return switch c { 0 => 100, 7 => 7, n => n + 1, }; }\nfn main() i32 { unsafe exit(classify(41)); }\n",
        42,
    );
    exit_case(
        b,
        "switch ranges",
        "fn s(n: i32) i32 { return switch n { 0..10 => 1, 10..=20 => 2, _ => 3, }; }\nfn main() i32 { unsafe exit(s(15)); }\n",
        2,
    );
    exit_case(
        b,
        "switch char range",
        "fn d(c: char) i32 { return switch c { '0'..='9' => 1, _ => 0, }; }\nfn main() i32 { unsafe exit(d('7')); }\n",
        1,
    );
    exit_case(
        b,
        "switch or-pattern",
        "fn k(c: i32) i32 { return switch c { 1 | 2 | 3 => 10, 4..=9 | 20 => 20, _ => 0, }; }\nfn main() i32 { unsafe exit(k(2) + k(20) + k(99)); }\n",
        30,
    );
}

// An explicit discriminant may name an earlier variant of its own enum, a variant of another enum,
// or a constant: the value is the same in a constant, a static_assert, the emitted C enum, a cast and
// a switch, and the next implicit discriminant follows it.
fn enum_discriminant_references(b: &mut h::ExitBatch) {
    exit_case(
        b,
        "discriminants that reference variants and constants",
        M"(enum E { A = 1, D = E::A as i32 + 20, F }
const K: i32 = 5;
enum G { X = K * 2, Y = E::D as i32 + 1, Z }
const CD: i32 = E::D as i32;
static_assert(E::D as i32 == 21);
static_assert(E::F as i32 == 22);
static_assert(G::Z as i32 == 23);
fn pick(e: E) i32 { return switch e { A => 1, D => 2, F => 3 }; }
fn main() i32 {
    let d = E::D;
    let f = E::F;
    let z = G::Z;
    let mut bad = 0;
    if CD != 21 { bad = 1; }
    if d as i32 != 21 { bad = 2; }
    if f as i32 != 22 { bad = 3; }
    if G::X as i32 != 10 { bad = 4; }
    if G::Y as i32 != 22 { bad = 5; }
    if z as i32 != 23 { bad = 6; }
    if pick(d) != 2 || pick(f) != 3 { bad = 7; }
    unsafe exit(bad);
}
)",
        0,
    );
}

// An empty string literal inside a constant aggregate that the engine evaluates (a field names a
// constant) is static data: a pointer to a byte array and length 0.
fn constant_aggregate_holds_empty_string(b: &mut h::ExitBatch) {
    b.add(
        "empty string in an evaluated constant aggregate",
        "struct S { pub a: str<'static>, pub n: u32 }\nconst K: u32 = 0xFF;\nconst T: [S; 2] = [S { a: \"\", n: K }, S { a: \"z\", n: K + 1 }];\nfn main() i32 {\n  let t: []S = T;\n  if t[0].a.len() != 0 || t[0].n != 255 || t[1].a != \"z\" || t[1].n != 256 {\n    return 1;\n  }\n  return 0;\n}\n",
        0,
    );
}

// A reference inside a constant or static to another constant or static is the address of that
// item's emitted storage: a whole item, an element or a field of it, a slice of it, a `str`, a chain
// of references, one returned by a `const fn`, and a `static mut`. A temporary gets its own storage.
const CONST_REFS: str = M"(extern "C" { fn exit(code: i32) void; }
struct R<'a> { pub r: &'a [i32; 2] }
struct P { pub x: i32, pub y: [i32; 3] }
struct N<'a> { pub p: &'a P, pub e: &'a i32, pub s: []'a i32, pub t: &'a str<'a> }
enum E { A(P), B }
const K: [i32; 2] = [5, 6];
const CR: R<'static> = R { r: &K };
const A: i32 = 7;
const QA: &i32 = &A;
const PP: P = P { x: 1, y: [2, 3, 4] };
const B: [i32; 3] = [10, 20, 30];
const CA: &[i32; 3] = &B;
const CC: &&[i32; 3] = &CA;
const T: str = "hello";
const N1: N<'static> = N { p: &PP, e: &PP.y[2], s: B[1..3], t: &T };
const SL: []i32 = K[0..1];
const TMP: &[i32; 2] = &[8, 9];
const P5: &i32 = &5;
const PQ: &&i32 = &&A;
const EV: E = E::A(P { x: 3, y: [4, 5, 6] });
const fn py(e: &E) &i32 {
    return switch e {
        A(p) => &p.y[1],
        B => &K[0],
    };
}
const PY: &i32 = py(&EV);
static mut SM: &[i32; 2] = &K;
static mut CNT: i32 = 1;
static mut PC: *mut i32 = unsafe &mut CNT;
fn main() i32 {
    let mut bad = 0;
    if CR.r[1] != 6 { bad += 1; }
    if *QA != 7 || CC[2] != 30 { bad += 2; }
    if N1.p.y[1] != 3 || *N1.e != 4 || N1.s[1] != 30 || N1.s.len() != 2 || N1.t.len() != 5 { bad += 4; }
    if SL.len() != 1 || SL[0] != 5 || TMP[1] != 9 || *PY != 5 || *P5 != 5 || **PQ != 7 { bad += 8; }
    if unsafe SM[0] != 5 { bad += 16; }
    unsafe *PC = 4;
    if unsafe CNT != 4 { bad += 32; }
    if CR.r as *const [i32; 2] != &K as *const [i32; 2] || SL.as_ptr() != &K[0] as *const i32 { bad += 64; }
    unsafe exit(bad); return 0;
}
)";

fn constant_references_address_items(b: &mut h::ExitBatch) {
    b.add("references to constants and statics inside constants", CONST_REFS, 0);
}

@test
fn constant_references_emit_addresses() {
    let c = h::compile_c(CONST_REFS);
    assert(c.ok(), "the program compiles");
    assert(c.code_has("R CR = { .r = (void *)&K };"), "a reference to a constant addresses its storage");
    assert(c.code_has("int32_t *PC = (void *)&CNT;"), "a reference to a static addresses its storage");
    assert(c.code_has(".e = (void *)&PP.y[2]"), "a field reference addresses the field");
}

// A constant of a generic enum instance is static data like any other aggregate: the standard
// and user enums, nested instances, one inside an array, a struct and a
// `static mut`, one a `const fn` builds, and a zero-sized payload (it has no C member).
@test
fn generic_enum_constants() {
    const SRC: str = M"(struct Z {}
enum E<T> { A(T), B }
struct S { pub o: Option<i32>, pub r: &'static Option<i32> }
const OK: Option<i32> = Option::Some(3);
const NO: Option<i32> = Option::None;
const NN: Option<Option<i32>> = Option::Some(Option::Some(4));
const R: Result<i32, u8> = Result::Err(7u8);
const UE: E<i64> = E::A(9);
const P: &Option<i32> = &OK;
const ARR: [Option<i32>; 2] = [Option::Some(1), Option::None];
const OS: Option<str> = Option::Some("hey");
const SS: S = S { o: Option::Some(6), r: &OK };
const OZ: Option<Z> = Option::Some(Z {});
const fn wrap<T>(x: T) Option<T> { return Option::Some(x); }
const WR: Option<u64> = wrap(11u64);
static mut SO: Option<i32> = Option::Some(5);
fn main() i32 {
    let mut s = 0;
    if let Some(x) = OK { s += x; }
    if let None = NO { s += 1; }
    if let Some(Some(y)) = NN { s += y; }
    if let Err(e) = R { s += e; }
    if let A(z) = UE { s += z as i32; }
    if let Some(x) = *P { s += x; }
    if let Some(x) = ARR[0] { s += x; }
    if let Some(t) = OS { s += t.len() as i32; }
    if let Some(x) = SS.o { s += x; }
    if let Some(x) = *SS.r { s += x; }
    if let Some(_) = OZ { s += 1; }
    if let Some(w) = WR { s += w as i32; }
    if let Some(w) = unsafe SO { s += w; }
    return s - (3 + 1 + 4 + 7 + 9 + 3 + 1 + 3 + 6 + 3 + 1 + 11 + 5);
}
)";
    h::expect_exit("generic enum constants", SRC, 0);
    h::expect_c("a generic enum constant", SRC, "Option__i32 OK = { .tag = Option_Some, .payload.Some = { ._0 = 3 } };");
    h::expect_c("a zero-sized payload takes no initializer", SRC, "Option__Z OZ = { .tag = Option_Some };");
}

// Constants local to different bodies may share a name: each has its own C symbol.
fn local_constants_of_one_name(b: &mut h::ExitBatch) {
    exit_case(
        b,
        "local constants of one name",
        "fn a() str<'static> { const S: str = \"first\"; return S; }\nfn b() str<'static> { const S: str = \"second!\"; return S; }\nfn c() i32 { const N: i32 = 1; return N; }\nfn d() i32 { const N: i32 = 2; return N; }\nfn main() i32 { unsafe exit((a().len() as i32) * 10 + (b().len() as i32) + c() * 20 + d() * 40); }\n",
        157,
    );
}

// C spells a result that is a pointer to an array or to a function around the declarator
// (`T (*f(void))[N]`): function and closure definitions and prototypes, dyn vtable slots and their
// thunks. A dyn call whose result is a reference has no symbol to reserve.
@test
fn results_spelled_around_the_declarator() {
    const SRC: str = M"(const A: [i32; 2] = [1, 2];
const M: [[i32; 2]; 2] = [[3, 4], [5, 6]];
struct S { pub a: [i32; 2] }
interface Get { fn get(self: &Self) &[i32; 2]; }
extend S as Get {
    pub fn get(self: &S) &[i32; 2] { return &self.a; }
}
fn dbl(x: i32) i32 { return x * 2; }
fn pick() fn(i32) i32 { return dbl; }
fn first<'a, T>(x: &'a [T; 2]) &'a [T; 2] { return x; }
fn mat() &'static [[i32; 2]; 2] { return &M; }
fn raw() *const [i32; 2] { return &A; }
fn mk() fn() &'static [i32; 2] { return || &A; }
fn main() i32 {
    let s = S { a: [7, 8] };
    let d: &dyn Get = &s;
    let g = || dbl;
    let c = || &A;
    let h: &dyn fn() &'static [i32; 2] = &|| &A;
    let r = raw();
    let mut sum = d.get()[1] + pick()(3) + g()(4) + c()[1] + h()[0] + first(&A)[1] + mat()[1][0] + mk()()[0];
    sum += unsafe (*r)[1];
    return sum - (8 + 6 + 8 + 2 + 1 + 2 + 5 + 1 + 2);
}
)";
    h::expect_exit("results spelled around the declarator", SRC, 0);
    // A pointer to an array spells its element with no qualifier: C11 converts no `int32_t (*)[2]`
    // into a `const int32_t (*)[2]`.
    h::expect_c("a function returning a pointer to an array", SRC, "int32_t (*mat(void))[2][2] {");
    h::expect_c_absent("the element takes no qualifier", SRC, "const int32_t (*mat(void))");
    h::expect_c("a function returning a function pointer", SRC, "int32_t (*pick(void))(int32_t) {");
    h::expect_c("a dyn slot returning a pointer to an array", SRC, "int32_t (*(*get)(void *self))[2];");
}

// A payload enum honors explicit discriminants: the stored tag, every match, `if let`, the derived
// Eq/Hash/Format/Ord (Ord compares discriminants first), constant evaluation, statics and
// reflection all take the discriminant, negative ones included. Owning payloads free on every path.
@test
fn payload_enum_discriminants() {
    run_exit(
        "payload enum with explicit discriminants",
        M"(const BASE: i32 = 40;
enum Other { X = 7, Y }
@derive(Eq, Hash, Format, Ord)
enum P { A(i32), B = 9, C, D(String), E = BASE + Other::Y as i32, F = -3, G, H { s: String, n: i32 } }
enum Q { A(i64), B = 5, C(i32), D = -7 }
const QS: [Q; 4] = [Q::C(7), Q::B, Q::A(1), Q::D];
static_assert(type_info::<P>().variant("A").unwrap().tag == 0);
static_assert(type_info::<P>().variant("C").unwrap().tag == 10);
static_assert(type_info::<P>().variant("D").unwrap().tag == 11);
static_assert(type_info::<P>().variant("E").unwrap().tag == 48);
static_assert(type_info::<P>().variant("G").unwrap().tag == -2);
static_assert(type_info::<P>().variant("H").unwrap().tag == -1);
const fn code(p: &P) i32 {
    return switch p { A(x) => *x, B => 1, C => 2, D(_) => 3, E => 4, F => 5, G => 6, H { s: _, n } => *n };
}
const fn code_v(p: P) i32 { return code(&p); }
static_assert(code_v(P::A(70)) == 70 && code_v(P::G) == 6 && code_v(P::F) == 5 && code_v(P::E) == 4);
fn tag_of(p: &P) i32 {
    let mut t = 0;
    inline for v in variants(p) {
        if v.is_active {
            t = v.tag;
        }
    }
    return t;
}
fn q_val(q: &Q) i64 { return switch q { A(x) => *x, B => 50, C(y) => *y, D => 70 }; }
fn check(n: usize) i32 {
    let all = [P::A(5), P::B, P::C, P::D(String::from_str("hi")), P::E, P::F, P::G, P::H { s: String::from_str("x"), n: 8 }];
    let want = [5, 1, 2, 3, 4, 5, 6, 8];
    let tags = [0, 9, 10, 11, 48, -3, -2, -1];
    for i in 0..8 {
        if code(unsafe &all[i]) != unsafe want[i] { return 10 + i; }
        if tag_of(unsafe &all[i]) != unsafe tags[i] { return 20 + i; }
        if unsafe all[i] != unsafe all[i] { return 30 + i; }
    }
    let c = P::C;
    if let C = &c {} else { return 40; }
    if let F = &c { return 41; }
    if let D(s) = P::D(String::from_str("abc")) { if s.len() != 3 { return 42; } } else { return 43; }
    if P::B == P::C || P::G != P::G || P::A(1) == P::A(2) || P::A(1) != P::A(1) { return 44; }
    if P::G.hash() != P::G.hash() || P::G.hash() == P::F.hash() { return 45; }
    if format("{} {} {}", P::G, P::A(3), P::D(String::from_str("q"))).as_str() != "G A(3) D(q)" { return 46; }
    if !(P::F < P::G && P::G < P::A(0) && P::A(9) < P::B && P::B < P::E && P::A(1) < P::A(2)) { return 47; }
    if unsafe *(&c as *const P as *const i32) != 10 { return 48; }
    if q_val(unsafe &QS[n]) != 7 || q_val(unsafe &QS[n + 1]) != 50 || q_val(unsafe &QS[n + 2]) != 1 || q_val(unsafe &QS[n + 3]) != 70 { return 49; }
    return 0;
}
fn main(argv: Vector<str>) i32 { return check(argv.len() - 1); }
)",
        0,
    );
    // a negative discriminant of a bare enum is a signed switch case
    run_exit(
        "negative bare enum discriminants in a switch",
        M"(enum N { A = -3, B, C = 7 }
fn f(n: N) i32 { return switch n { A => 1, B => 2, C => 3 }; }
fn main() i32 { return f(N::A) + f(N::B) * 4 + f(N::C) * 16 + N::B as i32 + 2; }
)",
        57,
    );
}

// A char literal has one value in every pass: the UTF-8 spelling, the `\u{..}` escape and the `\x..`
// escape of U+00E9 are all the byte 233, at run time and in constant evaluation.
@test
fn non_ascii_char_literals() {
    run_exit(
        "non-ASCII char literals",
        "const K: u8 = '\\u{e9}' as u8;\nfn main() i32 { let c: char = 'é'; let d: char = '\\u{e9}'; let e: char = '\\xe9'; unsafe exit(if c as u8 == K && d as u8 == K && e as u8 == K { K as i32 - 200; } else { 1; }); }\n",
        33,
    );
}

@test
fn structs_and_methods() {
    run_exit(
        "method dispatch (&self / &mut self)",
        "struct Point { pub x: i32, pub y: i32, }\nextend Point {\n  fn sum(self: &Point) i32 { return unsafe self.x + self.y; }\n  fn shift(self: &mut Point, d: i32) { unsafe self.x = unsafe self.x + d; self.y = self.y + d; }\n}\nfn main() i32 { let mut p: Point = Point { x: 3, y: 4, }; p.shift(10); unsafe exit(p.sum()); }\n",
        27,
    );
    run_exit(
        "nested struct field access",
        "struct Inner { pub v: i32, }\nstruct Outer { pub inner: Inner, }\nfn main() i32 { let o: Outer = Outer { inner: Inner { v: 7, }, }; unsafe exit(o.inner.v); }\n",
        7,
    );
}

@test
fn const_generics() {
    // 1 + 4 + 9 + a.cap()=4 + c.cap()=8.
    run_exit(
        "distinct const-generic instances + value use",
        "struct Buff<T, const N: usize> { pub b: [T; N] }\nextend<T, const N: usize> Buff<T, N> { fn cap(self: &Self) usize { return N; } }\nfn main() i32 {\n  let a = Buff::<i32, 4> { b: [1, 2, 3, 4] };\n  let c = Buff::<i32, 8> { b: [0, 0, 0, 0, 0, 0, 0, 9] };\n  unsafe exit(a.b[0] + a.b[3] + c.b[7] + a.cap() as i32 + c.cap() as i32);\n}\n",
        26,
    );
    // A NAMED const as the argument, not only a literal. The grammar parses every non-literal argument as a
    // type, so this only works if the resolver notices the name is a value and the typechecker then folds
    // it: in a field type and in a turbofish alike, which are separate paths. The `[i64]` elements also
    // pin the contextual typing of an array literal: written as bare integers, they are i32 on their own.
    // 3 + 7 + cap()=4.
    run_exit(
        "a named const as a const-generic argument",
        "const N: usize = 4;\nstruct Holder { pub cells: Buff<i64, N> }\nstruct Buff<T, const M: usize> { pub b: [T; M] }\nextend<T, const M: usize> Buff<T, M> { fn cap(self: &Self) usize { return M; } }\nfn main() i32 {\n  let h = Holder { cells: Buff::<i64, N> { b: [3, 0, 0, 7] } };\n  unsafe exit(h.cells.b[0] as i32 + h.cells.b[3] as i32 + h.cells.cap() as i32);\n}\n",
        14,
    );
    // Radix-prefixed literals in a symbolic field length fold at their own base: 5 + 2 elements.
    // b[4]=5 + c[1]=7 + sizeof=7.
    run_exit(
        "binary and octal literals in a const-generic array length",
        "struct R<const N: usize> { pub b: [u8; N + 0b100], pub c: [u8; N * 0o2] }\nfn main() i32 {\n  let r = R::<1> { b: [1, 2, 3, 4, 5], c: [6, 7] };\n  return unsafe (r.b[4] + r.c[1]) as i32 + sizeof(R<1>) as i32;\n}\n",
        19,
    );
}

// A generic alias expands with its parameters bound to the arguments, and an alias named in its
// body expands first, at any depth: `Q2<i32>` is `Pair<Pair<i32, i32>, Pair<i32, i32>>`.
@test
fn generic_type_aliases() {
    // q.a.a=1 + q.b.b=4 + 3*3 + 7 + 6 + 8 + 11 + 2 + 3.
    run_exit(
        "nested generic aliases substitute at every depth",
        M"(struct Pair<A, B> { pub a: A, pub b: B }
extend<A, B> Pair<A, B> { pub fn mk(a: A, b: B) Pair<A, B> { return Pair::<A, B> { a: a, b: b }; } }
struct Buf<T, const N: usize> { pub d: [T; N] }
type Q1<T> = Pair<T, T>;
type Q2<T> = Q1<Q1<T>>;
type Q3<T> = Q2<Q1<T>>;
type P2<T> = Pair<Q1<T>, Q1<T>>;
type R<T> = Pair<T, i64>;
type RR<T> = R<R<T>>;
type S<A, B> = Q1<Pair<B, A>>;
type D<T = u8> = Q1<T>;
type Arr<T, const N: usize> = Buf<T, N>;
type Arr3<T> = Arr<T, 3>;
struct Holder { pub f: Q2<i32> }
fn first(q: Q2<i32>) i32 { return q.a.a; }
fn mk(x: i32) Q1<i32> { return Q1::<i32> { a: x, b: x + 1 }; }
fn get<U: Copy>(q: Q2<U>) U { return q.b.a; }
static_assert(sizeof(Arr<u8, 5>) == 5, "a const parameter substitutes");
fn main() i32 {
    let q: Q2<i32> = Pair::<Pair<i32, i32>, Pair<i32, i32>> { a: mk(1), b: Pair::<i32, i32> { a: 3, b: 4 } };
    let q2: P2<i32> = q;
    let h = Holder { f: q2 };
    let q3: Q3<i32> = Pair::<Q2<i32>, Q2<i32>> { a: h.f, b: q };
    let r: RR<i32> = Pair::<Pair<i32, i64>, i64> { a: Pair::<i32, i64> { a: 5, b: 6 }, b: 7 };
    let s: S<i32, u8> = Pair::<Pair<u8, i32>, Pair<u8, i32>> { a: Pair::<u8, i32> { a: 8u8, b: 9 }, b: Pair::<u8, i32> { a: 10u8, b: 11 } };
    let d: D = Q1::<u8>::mk(2u8, 2u8);
    let ar: Arr3<i32> = Buf::<i32, 3> { d: [1, 2, 3] };
    let ar2: Arr<i32, 3> = ar;
    return first(h.f) + h.f.b.b + get(q) + q3.b.b.a + q3.a.b.a + r.b as i32 + r.a.b as i32 + s.a.a as i32 + s.b.b + d.a as i32 + (unsafe ar2.d[2]);
}
)",
        1 + 4 + 3 + 3 + 3 + 7 + 6 + 8 + 11 + 2 + 3,
    );
}

@test
fn mut_match_binding() {
    run_exit(
        "mut binding: &mut self method + reassign",
        "struct C { pub n: i32 }\nextend C { fn bump(self: &mut C) { self.n = self.n + 1; } fn get(self: &C) i32 { return self.n; } }\nenum Opt { None, Some(C), }\nfn main() i32 {\n  let o = Opt::Some(C { n: 5 });\n  unsafe exit(switch o { Some(mut c) => { c.bump(); c.bump(); c = C { n: c.get() + 1 }; c.get(); }, None => { 0; }, });\n}\n",
        8,
    );
}

// `[v; N]`: N copies of one value. The count is part of the type, so it must be constant, and a value
// that owns resources cannot be copied into more than one slot; both are rejected rather than emitted. A
// zero fill emits `{0}` so the C does not grow with N.
@test
fn array_repeat_literal() {
    run_exit(
        "repeat literal as a binding, a field and a slice argument",
        "struct Buf { pub b: [u8; 8] }\nfn sum(s: []u8) i32 { let mut t = 0; for i in 0..s.len() { t = t + *s.get(i) as i32; } return t; }\nconst N: usize = 4;\nfn main() i32 {\n  let zeros: [u8; 8] = [0u8; 8];\n  let ones: [i32; 3] = [1; 3];\n  let sized: [u8; 4] = [2u8; N];\n  let b = Buf { b: [9u8; 8] };\n  unsafe exit(sum(zeros) + ones[0] + ones[2] + sum(sized) + sum(b.b) - 40);\n}\n",
        42,
    );
}

// `[v; N]` with a const-generic count is the symbolic array `[T; N]`: each instance folds the count and
// fills its own length. A repeat of an array copies the element array into every slot (C cannot assign
// arrays), at every nesting and past the unrolled small counts.
@test
fn array_repeat_symbolic_count() {
    run_exit(
        "generic fn, generic struct method, Copy value and nested repeats at several counts",
        "struct B<const N: usize> { pub d: [u8; N] }\nextend<const N: usize> B<N> { fn fill(v: u8) B<N> { return B::<N> { d: [v; N] }; } }\nstruct P { pub a: i32, pub b: i32 }\nfn zeros<const N: usize>() [u8; N] { return [0u8; N]; }\nfn rep<T: Copy, const N: usize>(v: T) [T; N] { return [v; N]; }\nfn grid<const N: usize>() [[i32; N]; 2] { return [[1; N]; 2]; }\nfn big<const N: usize>() [[u8; N]; 20] { return [[3u8; N]; 20]; }\nfn main() i32 {\n  let z = zeros::<4>();\n  let r3 = rep::<i32, 3>(7);\n  let r5 = rep::<i32, 5>(2);\n  let p = rep::<P, 2>(P { a: 4, b: 5 });\n  let g = grid::<3>();\n  let w = big::<17>();\n  let x = B::<6>::fill(9);\n  let y = B::<2>::fill(1);\n  let mut s: i32 = 0;\n  for i in 0..4 { s = s + unsafe z[i] as i32; }\n  for i in 0..3 { s = s + unsafe r3[i]; }\n  for i in 0..5 { s = s + unsafe r5[i]; }\n  for i in 0..2 { s = s + unsafe p[i].a + unsafe p[i].b; }\n  for i in 0..2 { for j in 0..3 { s = s + unsafe g[i][j]; } }\n  for i in 0..20 { for j in 0..17 { s = s + unsafe w[i][j] as i32; } }\n  for i in 0..6 { s = s + unsafe x.d[i] as i32; }\n  for i in 0..2 { s = s + unsafe y.d[i] as i32; }\n  unsafe exit(s - 21 - 10 - 18 - 6 - 1020 - 54 - 2 + 42);\n}\n",
        42,
    );
}

// An unsigned literal has its type's width, which decides the width C computes at: a `u32` constant is
// `unsigned`, so `x - 1` wraps at 32 bits (a `long long` spelling lifted it to 64). A float literal next
// to an `f32` operand is a `float`, so `x * 0.1` rounds like `x * 0.1f32` (a `double` spelling computed
// it at double precision).
@test
fn literals_compute_at_their_declared_width() {
    run_exit(
        "u32 wrap and f32 product",
        "static mut X: f32 = 2.433180571;\nfn id32(x: u32) u32 { return x; }\nfn main() i32 {\n  let q = id32(0).wrapping_sub(1) / 2;\n  let a = unsafe X * 0.1;\n  let b = unsafe X * 0.1f32;\n  let mut r = 2;\n  if q == 2147483647 { r += 20; }\n  if a == b { r += 20; }\n  unsafe exit(r);\n}\n",
        42,
    );
}

// An unsuffixed integer literal past i32 takes the first type that holds it (i64, then u64), and of two
// literal operands the narrower takes the wider's type: typed i32, `3000000000` truncated at run time and
// `4000000000 * 2` overflowed. A negated negative constant spells `-(-5.0)`, not the decrement `--5.0`.
@test
fn wide_literals_and_negated_constants() {
    run_exit(
        "literal defaults past i32 and double negation",
        "fn m() i64 { return 4000000000 * 2; }\nfn main() i32 {\n  let x = 3000000000;\n  let y = 1 + 3000000000;\n  let z = 18446744073709551615;\n  let f: f64 = -5.0;\n  let g = -f;\n  let i: i64 = -5;\n  let j = -i;\n  let mut r = 0;\n  if x == 3000000000 && y - x == 1 { r += 10; }\n  if m() == 8000000000 && z == 18446744073709551615 { r += 12; }\n  if g == 5.0 && j == 5 { r += 20; }\n  unsafe exit(r);\n}\n",
        42,
    );
}

// A designated array literal carries only its SPELLED elements; the destination's tail is zero. In a
// struct-literal field the emitted temp is that short array, so the copy into the field must be sized
// by the source: sized by the field, it read past the temp. And the constant evaluator's value for
// the literal kept the short length through field-init and return positions, so a constant index into
// the zero tail was reported as out of bounds.
@test
fn designated_array_literal_short_tail() {
    run_exit(
        "short designated literals in field, binding and return positions; constant reads of the zero tail",
        "struct Env { pub args: [u32; 8], pub n: u8 }\nfn mk() [u32; 8] { return [[0] = 7]; }\nfn main() i32 {\n  let e = Env { args: [[1] = 5], n: 1 };\n  let local: [u32; 8] = [[2] = 3];\n  let r = mk();\n  unsafe exit((e.args[1] + e.args[7] + local[2] + local[7] + r[0] + r[7]) as i32 + 27);\n}\n",
        42,
    );
}

// An array whose element is a POINTER or a FUNCTION POINTER, and an array binding whose type is inferred.
// Three separate defects met here. C cannot initialize an array from an array value, so the compound
// literal every inferred array binding was emitted with (`const T x[N] = (T[N]){..}`) was rejected outright
// `let v = [1, 2];` did not compile at all. The cast for an array of function pointers was built by
// appending `[N]` to the element's spelling, producing `T (*)(..)[N]`: a function returning an array,
// which is not a type. And an immutable binding took its `const` as a prefix, which for these element types
// binds to the POINTEE (or the return type), not to the binding: writing through such a pointer then fails.
@test
fn array_of_pointers_and_functions() {
    run_exit(
        "inferred array bindings, an array of fn pointers, and writing through an array of pointers",
        "fn one() i32 { return 1; }\nfn two() i32 { return 2; }\nfn main() i32 {\n  let inferred = [10, 20];\n  let fs = [one, two];\n  let mut a = 3;\n  let mut b = 4;\n  let ps = [&mut a, &mut b];\n  unsafe { *ps[0] = 5; }\n  unsafe { *ps[1] = 6; }\n  let mut t = 0;\n  for i in 0..2 { let f = unsafe fs[i]; t = t + f(); }\n  unsafe exit(unsafe inferred[0] + unsafe inferred[1] + t + a + b);\n}\n",
        44,
    );
}

// A closure's DECLARED return type has to be resolved like any other type annotation. It was not, so it
// lowered to no type at all for anything that is not a builtin, and a builtin needs no resolution, which
// is exactly why it went unnoticed: `fn() u8` behaved and `fn() SomeStruct` silently had no return type, so
// every signature check against such a closure (a `F: fn() T` bound, above all) compared against nothing
// and rejected it. Covered here through a generic method on a generic struct AND a free generic function,
// which are the two shapes that check the bound.
@test
fn closure_declared_return_type_resolves() {
    run_exit(
        "closure returning a struct satisfies a fn-typed bound",
        "struct Pt { pub x: i32 }\nstruct Holder<T> { pub n: usize }\nextend<T> Holder<T> {\n  pub fn fill<F: fn move() T>(self: &mut Holder<T>, make: F) T { return make(); }\n}\nfn free_mk<T, F: fn move() T>(make: F) T { return make(); }\nfn main() i32 {\n  let mut h = Holder::<Pt> { n: 0 };\n  let a = h.fill(fn() Pt { return Pt { x: 20 }; });\n  let b = free_mk(fn() Pt { return Pt { x: 22 }; });\n  unsafe exit(a.x + b.x);\n}\n",
        42,
    );
}

// An array-typed FIELD coerces to a slice like any other array. It did not: the coercion needs the element
// count, which is read from the declaration the expression names, and that lookup only understood a plain
// identifier, so `f(x.buf)` type-checked and then emitted a raw C array where a slice was expected. Covers
// both directions and a write THROUGH the mutable slice, so the view really is the field's storage.
@test
fn array_field_coerces_to_slice() {
    run_exit(
        "array-typed struct field passed as []T and []mut T",
        "struct B { pub b: [u8; 4], pub n: [i32; 3] }\nfn ro(s: []u8) usize { return s.len(); }\nfn rw(s: []mut u8) usize { s.set(0, 9u8); return s.len(); }\nfn sum(s: []i32) i32 { let mut t = 0; for i in 0..s.len() { t = t + *s.get(i); } return t; }\nfn main() i32 {\n  let mut x = B {};\n  x.n[0] = 40;\n  x.n[1] = 2;\n  let a: [u8; 4] = [1u8, 2u8, 3u8, 4u8];\n  let total = ro(a) + ro(x.b) + rw(x.b) + sum(x.n) as usize;\n  if x.b[0] != 9u8 { unsafe exit(1); }\n  unsafe exit(total as i32 - 12);\n}\n",
        42,
    );
}

// An array coerces to a slice wherever the checker expects one, not only at a call argument or a
// `let`: an aggregate member (struct, tuple struct, tuple, variant payload, array element and repeat,
// generic instance) was stored as a raw array copy into the view struct, so its `len` read 0. The
// view is now explicit in Core IR at every coerced expression; places keep their array type.
@test
fn array_coerces_to_slice_everywhere() {
    run_exit(
        "array into slice-typed aggregate members, field assignment and projections",
        "struct A<'a> { pub s: []'a u8 }\nstruct P<'a> { pub k: i32, pub a: A<'a> }\nstruct T<'a>([]'a u8, i32);\nstruct W { pub arr: [u8; 2] }\nstruct G<T> { pub v: T }\nenum E<'a> { V([]'a u8), N }\nfn chk(s: []u8, a: u8, b: u8) i32 { if s.len() == 2 && s[0] == a && s[1] == b { return 0; } return 1; }\nfn main() i32 {\n  let x: [u8; 2] = [7, 9];\n  let w = W { arr: [5, 6] };\n  let r = &w;\n  let aa: [[u8; 2]; 2] = [[1u8, 2u8], [3u8, 4u8]];\n  let mut bad = chk(A { s: x }.s, 7, 9);\n  bad += chk(P { k: 1, a: A { s: x } }.a.s, 7, 9);\n  let t = T(x, 3);\n  bad += chk(t.0, 7, 9);\n  let tu: ([]u8, i32) = (x, 4);\n  bad += chk(tu.0, 7, 9);\n  let e = E::V(x);\n  switch e { V(s) => { bad += chk(s, 7, 9); }, N => { bad += 100; } };\n  let o: Option<[]u8> = Option::<[]u8>::Some(x);\n  bad += chk(o.unwrap(), 7, 9);\n  let l: [[]u8; 2] = [x, w.arr];\n  bad += chk(l[0], 7, 9) + chk(l[1], 5, 6);\n  let rp: [[]u8; 2] = [x; 2];\n  bad += chk(rp[1], 7, 9);\n  let mut m = A { s: w.arr };\n  bad += chk(m.s, 5, 6);\n  m.s = x;\n  bad += chk(m.s, 7, 9);\n  bad += chk(A { s: r.arr }.s, 5, 6) + chk(A { s: aa[1] }.s, 3, 4);\n  let g = G::<[]u8> { v: w.arr };\n  bad += chk(g.v, 5, 6);\n  unsafe exit(42 + bad);\n}\n",
        42,
    );
    run_exit(
        "array into slice returns, method and closure arguments and generic arguments",
        "struct H { pub k: u8 }\nextend H { fn first(self: &Self, s: []u8) u8 { return s[0] + self.k; } }\nconst K: [u8; 2] = [3, 4];\nfn chk(s: []u8, a: u8, b: u8) i32 { if s.len() == 2 && s[0] == a && s[1] == b { return 0; } return 1; }\nfn view<'a>(x: &'a [u8; 2]) []'a u8 { return *x; }\nfn konst() []'static u8 { return K; }\nfn id<T>(v: T) T { return v; }\nfn main() i32 {\n  let mut y: [u8; 2] = [7, 9];\n  let mut bad = chk(view(&y), 7, 9) + chk(konst(), 3, 4) + chk(id::<[]u8>(y), 7, 9);\n  let h = H { k: 1 };\n  if h.first(y) != 8 { bad += 1; }\n  let f = |s: []u8| s.len();\n  if f(y) != 2 { bad += 1; }\n  {\n    let t: (i32, []mut u8) = (1, y);\n    t.1[1] = 50;\n  }\n  bad += chk(y, 7, 50);\n  unsafe exit(42 + bad);\n}\n",
        42,
    );
    run_exit(
        "array into slice members of constants and statics",
        "struct A<'a> { pub s: []'a u8 }\nconst K: [u8; 2] = [3, 4];\nconst CA: A<'static> = A { s: K };\nstatic mut SA: A<'static> = A { s: K };\nconst CS: []'static u8 = K;\nconst CL: A<'static> = A { s: [5, 6] };\nconst CV: A<'static> = A { s: K[0..2] };\nconst LN: usize = A { s: K }.s.len();\nconst E1: u8 = A { s: K }.s[1];\nfn chk(s: []u8, a: u8, b: u8) i32 { if s.len() == 2 && s[0] == a && s[1] == b { return 0; } return 1; }\nfn main() i32 {\n  let mut bad = chk(CA.s, 3, 4) + chk(unsafe SA.s, 3, 4) + chk(CS, 3, 4) + chk(CL.s, 5, 6) + chk(CV.s, 3, 4);\n  bad += LN as i32 - 2 + E1 as i32 - 4;\n  unsafe exit(42 + bad);\n}\n",
        42,
    );
}

// A closure nested three deep (a closure literal inside a closure literal inside a closure literal)
// compiled to an out-of-bounds node lookup: the instance graph demanded closures two levels down and
// no further, so the innermost never entered its keep and the emitter lowered it from scratch after the
// body arena was released. The graph now expands closures to any depth.
@test
fn closures_nest_to_any_depth() {
    run_exit(
        "a closure three levels deep runs and captures through every level",
        "fn apply<F: fn() i64>(f: F) i64 { return f(); }\nfn main() i32 {\n  let want: i64 = 3;\n  let got = apply(fn() i64 { return apply(fn() i64 { return apply(fn() i64 { return apply(fn() i64 { return want + 39; }); }); }); });\n  unsafe exit(got as i32);\n}\n",
        42,
    );
}

// A `dyn fn` type written in a function body names its signature node, which is the type's
// identity; emission read it after the body syntax was released (an out-of-bounds node read).
// The signature is module syntax now. Covered with a capturing closure, a closure without
// captures (its thunk calls the function, no env), a closure that owns a `String` (the boxed env
// frees it once), a `move` closure, and a `dyn fn` whose parameter is another `dyn fn` (its
// vtable block must follow the parameter's).
@test
fn dyn_fn_types_in_bodies() {
    let r = h::compile_and_run_env(
        M"(fn run(f: &dyn fn(i32) i32, x: i32) i32 {
    return f(x);
}
fn main() i32 {
    let k = 7;
    let b: Box<dyn fn() i32> = || k;
    let g: &dyn fn(i32) i32 = &|x: i32| x + k;
    let plain = |x: i32| x * 2;
    let p: Box<dyn fn(i32) i32> = |x: i32| x + 1;
    let name = String::from_str("a heap string longer than twenty-three bytes");
    let c: Box<dyn fn() usize> = move || name.len();
    let nested: Box<dyn fn(&dyn fn(i32) i32) i32> = |f: &dyn fn(i32) i32| f(2);
    let total = b() + g(1) + run(&plain, 3) + p(4) + c() as i32 + c() as i32 + nested(&plain);
    return total - (7 + 8 + 6 + 5 + 88 + 4);
}
)",
        "SC_LEAK_CHECK=fatal",
    );
    assert(r.built, "dyn fn types in a body build");
    assert_eq(r.exit, 0);
}

@test
fn closure_captures_every_binding_kind() {
    // A closure environment must name EVERY kind of binding it can capture, not only `let`s and parameters:
    // a `for` induction variable, an iterator-`for` binding, an `if let` / switch-arm payload and a
    // struct-pattern shorthand must each emit a NAMED env field (`struct { int32_t; }` does not
    // compile). All five kinds are captured here, so the emitted C proves each field is named.
    run_exit(
        "closure captures for / iterator / if-let / switch-arm / struct-shorthand bindings",
        "fn apply<F: fn() i64>(f: F) i64 { return f(); }\nstruct P { pub a: i64, pub b: i64 }\nenum E { N, V(i64), }\nfn main() i32 {\n  let mut t: i64 = 0;\n  for i in 0..3 { t = t + apply(fn() i64 { return i; }); }\n  let mut v = Vector::<i64>::new();\n  v.push(4);\n  v.push(5);\n  for x in v.iter() { t = t + apply(fn() i64 { return *x; }); }\n  v.free();\n  let e = E::V(10);\n  if let V(n) = e { t = t + apply(fn() i64 { return n; }); }\n  switch e { V(n2) => { t = t + apply(fn() i64 { return n2; }); }, N => {}, };\n  let p = P { a: 6, b: 7 };\n  switch p { P { a, b } => { t = t + apply(fn() i64 { return a + b; }); }, };\n  unsafe exit(t as i32);\n}\n",
        45,
    );
}

// A `[T; N]` parameter is a VALUE: C hands the callee a pointer to the caller's array, so the C parameter is
// `const` (an array read through `&T` is a `const` object in C) and the callee copies the array on entry,
// whether or not it is `mut`: a write by the callee must not reach the caller, and a write to the caller's
// array during the call must not reach the callee. Cases call a function that is not inlined, so the
// parameter's C type is what the call must match.
fn array_param_cases(b: &mut h::ExitBatch) {
    b.add(
        "writing a mut array parameter leaves the caller's array alone",
        "fn f(mut a: [i32; 2]) i32 { a[0] = 9; return a[0]; }\nfn main() i32 {\n    let v: [i32; 2] = [3, 0];\n    let r = f(v);\n    return r - 9 + v[0] - 3;\n}\n",
        0,
    );
    b.add(
        "the copy is per call, not shared",
        "fn bump(mut a: [i32; 1]) i32 { a[0] = a[0] + 1; return a[0]; }\nfn main() i32 {\n    let v: [i32; 1] = [5];\n    return bump(v) + bump(v) - 12;\n}\n",
        0,
    );
    b.add(
        "a non-mut array parameter still reads the caller's elements",
        "fn sum(a: [i32; 3]) i32 { return a[0] + a[1] + a[2]; }\nfn main() i32 {\n    let v: [i32; 3] = [1, 2, 3];\n    return sum(v) - 6;\n}\n",
        0,
    );
    b.add(
        "a closure's mut array parameter leaves the caller's array alone",
        M"(fn main() i32 {
    let v: [i32; 2] = [3, 0];
    let c = fn(mut a: [i32; 2]) i32 { a[0] = 9; return a[0]; };
    return c(v) - 9 + v[0] - 3;
}
)",
        0,
    );
    b.add(
        "a parameter named like the entry copy of an array parameter builds",
        M"(@noinline
fn f(ids: [u8; 4], ids_p: u8, __sc_ap0: u8) u8 { return ids[1] + ids_p + __sc_ap0; }
fn main() i32 { return f([1, 2, 3, 4], 3, 4) as i32 - 9; }
)",
        0,
    );
    b.add(
        "a @blocking extern takes an array parameter",
        M"(extern "C" {
    @blocking
    fn sc_blk_sum(a: [u8; 4], n: usize) u8;
}
@export("sc_blk_sum")
fn impl_sum(a: [u8; 4], n: usize) u8 { return a[0] + a[3] + n as u8; }
struct Row { pub l: [u8; 4] }
fn g(r: &Row) u8 { return unsafe sc_blk_sum(r.l, 1); }
fn main() i32 {
    let r = Row { l: [1, 2, 3, 4] };
    return g(&r) as i32 - 6;
}
)",
        0,
    );
    b.add(
        "a function with &mut and []mut parameters beside an array parameter reads the array as passed",
        M"(struct Row { pub l: [u8; 4] }
@noinline
fn f(ids: [u8; 4], r: &mut Row, v: []mut u8) u8 {
    r.l[0] = 9;
    v[0] = 7;
    return ids[0];
}
fn main() i32 {
    let mut r = Row { l: [1, 2, 3, 4] };
    let mut x: [u8; 1] = [0];
    return f(r.l, &mut r, x) as i32 - 1 + r.l[0] as i32 - 9 + x[0] as i32 - 7;
}
)",
        0,
    );
    b.add(
        "nested array arguments reach a function, a function value, an extern value and a blocking extern",
        M"(extern "C" {
    @blocking
    fn sc_nb(m: [[u8; 2]; 2], n: usize) u8;
    fn sc_nx(m: [[u8; 2]; 2]) u8;
}
@export("sc_nb")
fn impl_nb(m: [[u8; 2]; 2], n: usize) u8 { return m[1][1] + n as u8; }
@export("sc_nx")
fn impl_nx(m: [[u8; 2]; 2]) u8 { return m[1][0]; }
struct Row { pub m: [[u8; 2]; 2] }
@noinline
fn f(m: [[u8; 2]; 2]) u8 { return m[0][1]; }
fn g(r: &Row) u8 {
    let p: fn([[u8; 2]; 2]) u8 = f;
    let q: fn([[u8; 2]; 2]) u8 = unsafe sc_nx;
    return f(r.m) + p(r.m) + unsafe sc_nb(r.m, 1) + unsafe sc_nx(r.m) + q(r.m);
}
fn main() i32 {
    let mut a: [[u8; 2]; 2] = [[1, 2], [3, 4]];
    a[0][0] = 1;
    let r = Row { m: a };
    return g(&r) as i32 - (2 + 2 + 5 + 3 + 3) + f(a) as i32 - 2;
}
)",
        0,
    );
    b.add(
        "a function with a []mut and an array parameter is a function value and an export",
        M"(struct Row { pub l: [u8; 4] }
@export("sc_arrview")
@noinline
fn f(ids: [u8; 4], v: []mut i32) u8 {
    v[0] = 5;
    return ids[2];
}
fn main() i32 {
    let r = Row { l: [1, 2, 3, 4] };
    let p: fn([u8; 4], []mut i32) u8 = f;
    let mut x: [i32; 1] = [0];
    return p(r.l, x) as i32 - 3 + x[0] - 5;
}
)",
        0,
    );
    b.add(
        "an array field read through a shared reference passes to a non-inlined callee",
        M"(struct Row { pub l: [u8; 4] }
@noinline
fn f(ids: [u8; 4], n: usize) u8 {
    let mut s: u8 = 0;
    for i in 0..n { s = s + unsafe ids[i]; }
    return s;
}
fn g(row: &Row) u8 { return f(row.l, 3); }
fn main() i32 {
    let r = Row { l: [1, 2, 3, 4] };
    return g(&r) as i32 - 6;
}
)",
        0,
    );
    b.add(
        "a write through &mut self does not reach an array argument read from self",
        M"(struct Row { pub l: [u8; 4] }
extend Row {
    @noinline
    fn put(self: &mut Row, ids: [u8; 4]) u8 {
        self.l[0] = 9;
        return ids[0];
    }
}
fn main() i32 {
    let mut r = Row { l: [1, 2, 3, 4] };
    return r.put(r.l) as i32 - 1 + r.l[0] as i32 - 9;
}
)",
        0,
    );
    b.add(
        "a write to a static does not reach an array argument read from it",
        M"(static mut G: [u8; 4] = [1, 2, 3, 4];
@noinline
fn f(ids: [u8; 4]) u8 {
    unsafe G[0] = 9;
    return ids[0];
}
fn main() i32 {
    return unsafe f(G) as i32 - 1 + unsafe G[0] as i32 - 9;
}
)",
        0,
    );
    b.add(
        "a function value and a closure take a const array argument",
        M"(struct Row { pub l: [u8; 4] }
@noinline
fn f(ids: [u8; 4]) u8 { return ids[1]; }
fn viaptr(row: &Row) u8 {
    let p: fn([u8; 4]) u8 = f;
    let c = |a: [u8; 4]| a[2];
    return p(row.l) + c(row.l);
}
fn main() i32 {
    let r = Row { l: [1, 2, 3, 4] };
    return viaptr(&r) as i32 - 5;
}
)",
        0,
    );
    b.add(
        "a dyn fn takes a const array argument",
        M"(struct Row { pub l: [u8; 4] }
fn viadyn(row: &Row, d: &dyn fn([u8; 4]) u8) u8 { return d(row.l); }
fn main() i32 {
    let r = Row { l: [1, 2, 3, 4] };
    let d = |a: [u8; 4]| a[3];
    return viadyn(&r, &d) as i32 - 4;
}
)",
        0,
    );
    b.add(
        "nested arrays and arrays of pointers read through a shared reference pass to a non-inlined callee",
        M"(struct Row { pub m: [[u8; 2]; 2], pub p: [*const u8; 2] }
@noinline
fn f(m: [[u8; 2]; 2], p: [*const u8; 2]) u8 { return m[1][1] + unsafe *p[1]; }
fn g(row: &Row) u8 { return f(row.m, row.p); }
fn main() i32 {
    let x: u8 = 5;
    let r = Row { m: [[1, 2], [3, 4]], p: [&x as *const u8, &x as *const u8] };
    return g(&r) as i32 - 9;
}
)",
        0,
    );
}

// `&T` and `&mut T` are DIFFERENT C types (`const T*` vs `T*`), so instances named by them must get
// different symbols: one name for both redefines the struct and conflicts on every method.
@test
fn ref_mutability_mangles_apart() {
    let SRC: str = "fn peek<T>(v: &T) Option<&T> { return Option::<&T>::Some(v); }\nfn peek_mut<T>(v: &mut T) Option<&mut T> { return Option::<&mut T>::Some(v); }\nfn main() i32 {\n    let mut x = 41;\n    let m = peek_mut(&mut x).unwrap();\n    *m = *m + 1;\n    return *peek(&x).unwrap() - 42;\n}\n";
    h::expect_exit("Option<&T> and Option<&mut T> coexist in one program", SRC, 0);
    h::expect_c("the mutable instance takes its own symbol", SRC, "Option__ptrm_i32");
    h::expect_c("the read-only instance keeps the plain one", SRC, "Option__ptr_i32");
}

// `Deref` reaches past method dispatch: the `*` operator, field access, and a `&W` argument arriving
// at a `&Target` parameter all take the same hop `w.method()` already took.
@test
fn deref_beyond_methods() {
    h::expect_exit(
        "the '*' operator uses Deref",
        "struct W { pub v: i32 }\nextend W as Deref<i32> { fn deref(self: &W) &i32 { return &self.v; } }\nfn main() i32 { let w = W { v: 6 }; return *w - 6; }\n",
        0,
    );
    h::expect_exit(
        "a '&W' argument reaches a '&Target' parameter",
        "struct W { pub v: i32 }\nextend W as Deref<i32> { fn deref(self: &W) &i32 { return &self.v; } }\nfn take(x: &i32) i32 { return *x; }\nfn main() i32 { let w = W { v: 6 }; return take(&w) - 6; }\n",
        0,
    );
    h::expect_exit(
        "'*' and fields work through Box",
        "struct P { pub v: i32 }\nfn main() i32 {\n    let b = Box::<i32>::new(5);\n    let p = Box::<P>::new(P { v: 4 });\n    return *b + p.v - 9;\n}\n",
        0,
    );
    h::expect_exit(
        "mutation reaches through deref_mut: field assign, '&mut' borrow, '&mut W' coercion",
        "struct P { pub v: i32 }\nfn bump(t: &mut P) { t.v += 1; }\nfn main() i32 {\n    let mut b = Box::<P>::new(P { v: 1 });\n    b.v = 5;\n    let r = &mut b.v;\n    *r += 1;\n    bump(&mut b);\n    return b.v - 7;\n}\n",
        0,
    );
    h::expect_exit(
        "a method through Deref still resolves",
        "struct P { pub v: i32 }\nextend P { pub fn peek(self: &P) i32 { return self.v; } }\nfn main() i32 {\n    let b = Box::<P>::new(P { v: 5 });\n    return b.peek() - 5;\n}\n",
        0,
    );
}

@test
fn box_set_frees_the_previous_value() {
    let r = h::compile_and_run_env(
        "fn main() i32 {\n    let mut b = Box::<String>::new(String::from_str(\"a string long enough to live on the heap\"));\n    b.set(String::from_str(\"another string long enough for the heap\"));\n    return b.len() as i32;\n}\n",
        "SC_LEAK_CHECK=fatal",
    );
    assert(r.built, "Box::set builds");
    assert_eq(r.exit, 39);
}

// A value of an unbounded type parameter owns: a generic body drops what it leaves behind (a
// parameter it never moves, a local, the value an early return or a `?` skips, the old value `*r = v`
// overwrites), and so do the std bodies built on the rule (`Option::filter` rejecting its payload,
// `Option::unwrap_or`'s unused default, `Map::insert`'s duplicate key). The strings are longer than
// 23 bytes, so each one is a heap block the fatal gate would report.
@test
fn generic_values_left_behind_are_dropped() {
    let r = h::compile_and_run_env(
        "fn heap(tag: str) String {\n    let mut s = String::from_str(\"a heap string longer than twenty-three bytes: \");\n    s.push_str(tag);\n    return s;\n}\nfn drop_it<T>(x: T) {}\nfn local<T>(x: T) i32 {\n    let y = x;\n    return 1;\n}\nfn early<T>(a: T, b: T, first: bool) T {\n    if first {\n        return a;\n    }\n    return b;\n}\nfn set<T>(r: &mut T, v: T) {\n    *r = v;\n}\nfn tried<T>(x: T, o: Option<i32>) Option<i32> {\n    let v = o?;\n    drop_it(x);\n    return Option::<i32>::Some(v);\n}\nfn main() i32 {\n    drop_it(heap(\"param\"));\n    let n = local(heap(\"local\"));\n    let e = early(heap(\"kept\"), heap(\"skipped\"), true);\n    let mut s = heap(\"old\");\n    set(&mut s, heap(\"new\"));\n    let t = tried(heap(\"question\"), Option::<i32>::None);\n    let f = Option::<String>::Some(heap(\"filtered\")).filter(|x: &String| x.len() < 5);\n    let d = Option::<String>::Some(heap(\"some\")).unwrap_or(heap(\"default\"));\n    let mut m = Map::<String, i32>::new();\n    m.insert(heap(\"key\"), 1);\n    m.insert(heap(\"key\"), 2);\n    if n != 1 || !e.ends_with(\"kept\") || !s.ends_with(\"new\") || t.is_some() || f.is_some() || !d.ends_with(\"some\") || m.len() != 1 {\n        return 1;\n    }\n    return 0;\n}\n",
        "SC_LEAK_CHECK=fatal",
    );
    assert(r.built, "generic bodies that leave values behind build");
    assert_eq(r.exit, 0);
}

// A method's `where T: Copy` on its extend's parameter holds in that method only: a sibling method
// still owns and drops its `T`.
@test
fn scoped_where_copy_keeps_sibling_drops() {
    let r = h::compile_and_run_env(
        "struct P<T> { pub n: i32 }\nextend<T> P<T> {\n    fn pad(self: &mut Self, v: T) where T: Copy { let a = v; let b = v; self.n = self.n + 2; }\n    fn keep(self: &mut Self, v: T) { let w = v; self.n = self.n + 1; }\n}\nfn main() i32 {\n    let mut p = P::<i32> { n: 0 };\n    p.pad(3);\n    let mut q = P::<String> { n: 0 };\n    q.keep(String::from_str(\"a heap string longer than twenty-three bytes\"));\n    return p.n + q.n - 3;\n}\n",
        "SC_LEAK_CHECK=fatal",
    );
    assert(r.built, "a scoped where bound builds");
    assert_eq(r.exit, 0);
}

// A generic body is elaborated once, so a drop is scheduled for every instance: the instance whose
// type owns nothing emits no code for it.
@test
fn scalar_instance_drops_nothing() {
    let src = "@c.noinline\nfn drop_it<T>(x: T) {}\nfn main() i32 {\n    drop_it(5i64);\n    drop_it(String::from_str(\"a heap string longer than twenty-three bytes\"));\n    return 0;\n}\n";
    // The owning instance frees its parameter: the run passes the harness's fatal leak gate.
    h::expect_exit("both instances run", src, 0);
    // The scalar instance's body is a bare return, whitespace aside.
    let c = h::compile_c(src);
    assert(c.ok());
    let t = unsafe str::from_cstr(c.code);
    let k = t.find("drop_it__i64(int64_t x) {");
    assert(k >= 0, "the scalar instance is emitted");
    let rest = t.slice(k as usize + 25, t.len());
    let body = rest.slice(0, rest.find("}") as usize).trim();
    assert(body == "return;", "the scalar instance is empty");
}

@test
fn leak_tracker_reports_over_aligned_blocks() {
    // Over-aligned blocks take the platform's aligned allocation, not malloc: the tracker still
    // records them, so a leaked Box and Vector of a 64-aligned type fail the fatal gate.
    let r = h::compile_and_run_env(
        "@c.align(64)\nstruct Big { pub v: i64 }\nfn main() i32 {\n    let b = Box::<Big>::new(Big { v: 3 });\n    let mut v = Vector::<Big>::new();\n    v.push(Big { v: 4 });\n    forget(b);\n    forget(v);\n    return 0;\n}\n",
        "SC_LEAK_CHECK=fatal",
    );
    assert(r.built, "leaked over-aligned blocks build");
    assert_eq(r.exit, 23);
}

// A program a harness helper runs has SC_LEAK_CHECK=fatal unless the test sets SC_LEAK_CHECK, so a leak
// fails the test whatever the suite's own environment.
@test
fn a_harness_run_fails_on_a_leak_without_the_gate() {
    let _env1 = cli::set_env("SC_LEAK_CHECK", "0");
    let r = h::compile_and_run("fn main() i32 {\n    forget(Box::<i64>::new(3));\n    return 0;\n}\n");
    assert(r.built, "the leaking program builds");
    assert_eq(r.exit, 23);
}

@test
fn box_reaches_a_generic_reference_param_unchanged() {
    // A `&Box<String>` argument binds a generic `&T` param to the Box itself: a derived Clone's
    // per-field helper and a plain generic fn both receive the Box, never its pointee.
    let r = h::compile_and_run_env(
        "@derive(Clone)\nstruct S {\n    pub b: Box<String>,\n    pub n: i32,\n}\nfn same<T: Eq>(a: &T, b: &T) bool { return a.eq(b); }\nfn main() i32 {\n    let a = S { b: Box::<String>::new(String::from_str(\"a string long enough to live on the heap\")), n: 3 };\n    let c = a.clone();\n    if !same(&a.b, &c.b) { return 1; }\n    return c.b.len() as i32 + c.n - a.n;\n}\n",
        "SC_LEAK_CHECK=fatal",
    );
    assert(r.built, "derived Clone over a Box field builds");
    assert_eq(r.exit, 40);
}

fn compile_time_layout_and_zero_sized_maps(b: &mut h::ExitBatch) {
    // Nested instances of one generic lay out at compile time (they are no by-value cycle), and a
    // map or box of zero-sized values folds: its storage is the dangling sentinel.
    b.add(
        "nested instances and zero-sized values at compile time",
        "struct W<T> { pub v: T }\nstruct Z {}\nstatic_assert(sizeof(W<W<W<i32>>>) == 4, \"nested instances lay out\");\nconst fn count() usize {\n    let mut m = Map::<u32, Z>::new();\n    for i in 0..40u32 {\n        m.insert(i % 20, Z {});\n    }\n    let mut b = Box::<Z>::new(Z {});\n    b.set(Z {});\n    return m.len();\n}\nstatic_assert(count() == 20, \"a map of zero-sized values folds\");\nfn main() i32 { let w = W::<W<i32>> { v: W::<i32> { v: 5 } }; return w.v.v - 5; }\n",
        0,
    );
}

// A closure inside a generic function is monomorphized WITH that function: one C function per
// instantiation, so its parameter, return and capture types follow the type arguments.
@test
fn closures_in_generic_fns() {
    let mut b = h::ExitBatch::new();
    b.add(
        "a closure over the type parameter, at two instantiations",
        "fn twice<T>(v: T) T {\n    let f = fn(x: T) T { return x; };\n    return f(v);\n}\nfn main() i32 { return twice(3) - 3 + (twice(4i64) as i32) - 4; }\n",
        0,
    );
    b.add(
        "a closure capturing a generic value",
        "fn hold<T: Copy>(v: T) T {\n    let f = fn() T { return v; };\n    return f();\n}\nfn main() i32 { return hold(7) - 7; }\n",
        0,
    );
    b.add(
        "a closure that ignores the type parameter",
        "fn gen<T>(v: T) i32 {\n    let f = fn() i32 { return 1; };\n    return f();\n}\nfn main() i32 { return gen(9) - 1 + gen(true) - 1; }\n",
        0,
    );
    // The one shape still out of reach: the callee's instance would have to be keyed on WHICH
    // instantiation produced the closure, which the closure's type does not record.
    h::expect_err_msg(
        "passing such a closure to another generic function is rejected",
        "fn apply<T, F: fn(T) T>(f: F, v: T) T { return f(v); }\nfn twice<T>(v: T) T { return apply(fn(x: T) T { return x; }, v); }\nfn main() i32 { return twice(3) - 3; }\n",
        "cannot be passed to another generic function",
    );
    b.run();
}

// `From<[]T>` on the containers: an array literal coerces to the slice, so a list of elements builds a
// container through `.into()` or the explicit `from`. The slice BORROWS, so elements are cloned in and
// the source keeps its own: a Free element type must not end up with two owners.
fn container_from_list(b: &mut h::ExitBatch) {
    b.add(
        "a Vector comes from a list of elements",
        "fn main() i32 {\n    let v: Vector<i32> = [1, 2, 3, 4, 5].into();\n    let mut t = 0;\n    for i in 0..v.len() { t = t + *v.at(i); }\n    return t - 15;\n}\n",
        0,
    );
    b.add(
        "the explicit 'from' names the same conversion",
        "fn main() i32 {\n    let v = Vector::<i32>::from([1, 2, 3]);\n    return (v.len() as i32) - 3;\n}\n",
        0,
    );
    b.add(
        "a Set collapses duplicates",
        "fn main() i32 {\n    let s: Set<i32> = [1, 2, 2, 3].into();\n    return (s.len() as i32) - 3;\n}\n",
        0,
    );
    b.add(
        "a Map comes from a list of pairs",
        "fn main() i32 {\n    let m: Map<i32, i32> = [(1, 10), (2, 20)].into();\n    return (m.len() as i32) - 2 + *m.get(&2).unwrap() - 20;\n}\n",
        0,
    );
    b.add(
        "a Free element type is cloned in, not shared",
        "fn main() i32 {\n    let v: Vector<String> = [String::from_str(\"ab\"), String::from_str(\"cde\")].into();\n    return (v.at(0).len() + v.at(1).len()) as i32 - 5;\n}\n",
        0,
    );
}

// A temporary that OWNS memory is freed whichever way it is used. A method call on one already bound
// and freed it; a field read did not, so the owner was dropped on the floor and its allocation leaked.
@test
fn free_temporary_field_read() {
    let mut b = h::ExitBatch::new();
    b.add(
        "a field read from an owning temporary frees it",
        "struct R { pub v: i32, pub buf: Vector<i32> }\nextend R { pub fn get(self: &R) i32 { return self.v; } }\nfn mk() R {\n    let mut b = Vector::<i32>::new();\n    b.push(1);\n    return R { v: 7, buf: b };\n}\nfn main() i32 { return mk().v - 7; }\n",
        0,
    );
    b.add(
        "a method call on one still does",
        "struct R { pub v: i32, pub buf: Vector<i32> }\nextend R { pub fn get(self: &R) i32 { return self.v; } }\nfn mk() R {\n    let mut b = Vector::<i32>::new();\n    b.push(1);\n    return R { v: 7, buf: b };\n}\nfn main() i32 { return mk().get() - 7; }\n",
        0,
    );
    h::expect_c(
        "the temporary is bound around the field read",
        "struct R { pub v: i32, pub buf: Vector<i32> }\nextend R { pub fn get(self: &R) i32 { return self.v; } }\nfn mk() R {\n    let mut b = Vector::<i32>::new();\n    b.push(1);\n    return R { v: 7, buf: b };\n}\nfn main() i32 { return mk().v - 7; }\n",
        "R__free__d(&",
    );
    b.run();
}

// Inline assembly is a pass-through to the C compiler's extended asm: the checker owns the SHAPE (string
// literals, assignable outputs, an `unsafe` context) and never reads the template. `@arch` picks the
// variant for the instruction set being built for.
@test
fn inline_asm() {
    h::expect_exit(
        "assembly runs, and @arch picks the variant",
        "@arch(aarch64)\nfn triple(x: i64) i64 {\n    let mut out: i64 = 0;\n    unsafe { asm(\"add %0, %1, %1, lsl #1\" : \"=r\"(out) : \"r\"(x)); }\n    return out;\n}\n@arch(x86_64)\nfn triple(x: i64) i64 {\n    let mut out: i64 = x;\n    unsafe {\n        asm(\"addq %1, %0\" : \"+r\"(out) : \"r\"(x));\n        asm(\"addq %1, %0\" : \"+r\"(out) : \"r\"(x));\n    }\n    return out;\n}\n@arch(wasm32)\nfn triple(x: i64) i64 { return x * 3; }\nfn main() i32 { unsafe { asm(\"\" : : : \"memory\"); } return (triple(7) - 21) as i32; }\n",
        0,
    );
    h::expect_c(
        "it lowers to volatile extended asm",
        "fn main() i32 {\n    let mut o: i64 = 0;\n    unsafe { asm(\"mov %0, #7\" : \"=r\"(o) : : \"memory\"); }\n    return (o - 7) as i32;\n}\n",
        "__asm__ volatile (\"mov %0, #7\" : \"=r\"(",
    );
    h::expect_err_msg(
        "it needs an unsafe context",
        "fn main() i32 {\n    asm(\"nop\");\n    return 0;\n}\n",
        "inline assembly requires an 'unsafe' block",
    );
    h::expect_err_msg(
        "an output must be assignable",
        "fn main() i32 {\n    let x = 1;\n    unsafe { asm(\"nop\" : \"=r\"(x + 1)); }\n    return 0;\n}\n",
        "asm output must be an assignable place",
    );
    h::expect_err_msg(
        "a constraint must be a literal",
        "fn main() i32 {\n    let c = \"r\";\n    unsafe { asm(\"nop\" : : c(1)); }\n    return 0;\n}\n",
        "asm constraint must be a string literal",
    );
}

// A monomorphized body asks of EVERY identifier whether it is a bound const-generic parameter, and the
// answer must not be read from the current module's node pool with the referenced decl's node id, which
// is only that module's id when the decl is local. A call to any prelude function from inside a generic
// body (`panic` is the one std itself needs) indexed this Ast with the prelude's node id and read past
// the end of it. Any generic fn calling any imported fn is enough.
fn prelude_call_inside_generic_body(b: &mut h::ExitBatch) {
    b.add(
        "a prelude call in a generic body",
        "fn pick<T>(v: T, take: bool) T {\n    if !take { panic(\"no\"); }\n    return v;\n}\nfn main() i32 { return pick(0, true); }\n",
        0,
    );
    b.add(
        "two instantiations of the same body",
        "fn pick<T>(v: T, take: bool) T {\n    if !take { panic(\"no\"); }\n    return v;\n}\nfn main() i32 { return pick(0, true) + pick(0i64, true) as i32; }\n",
        0,
    );
    b.add(
        "a real const-generic parameter still resolves",
        "fn width<const N: usize>(a: &Array<i32, N>) usize {\n    if N == 0 { panic(\"empty\"); }\n    return N;\n}\nfn main() i32 {\n    let mut a = Array::<i32, 3>::new();\n    let r = width(&a) as i32 - 3;\n    a.free();\n    return r;\n}\n",
        0,
    );
}

// The small-string budget is `sizeof(StringLarge) - 1`, so it MUST follow the pointer width: the union's
// last byte carries the discriminant, and it is the top byte of `cap` only while the two layouts are the
// same size. Written out as 23 it was right on a 64-bit target and wrong on wasm32, where the byte fell
// outside `cap` entirely and every heap string read back as inline: printing its own header. Checked
// through the public API, so it holds at whatever width the suite runs on.
fn sso_budget_follows_pointer_width(b: &mut h::ExitBatch) {
    b.add(
        "the inline budget is the heap layout minus its discriminant byte",
        "fn main() i32 {\n    let mut s = String::new();\n    let cap = s.capacity();\n    if cap != sizeof(usize) * 3 - 1 { return 1; }\n    for _i in 0..cap { s.push_byte(b'x'); }\n    if s.capacity() != cap || s.len() != cap { return 2; }\n    s.push_byte(b'y');\n    if s.capacity() <= cap || s.len() != cap + 1 { return 3; }\n    if !s.as_str().ends_with(\"xy\") { return 4; }\n    s.free();\n    return 0;\n}\n",
        0,
    );
}

// A const-generic parameter in an ARRAY LENGTH position, inferred from the argument. The lowered parameter
// type cannot carry the binding (`[T; N]` interns with length 0 while N is unbound), so it is read from the
// parameter's type node, and from the argument literal's own element count, since that literal is typed
// against this very parameter and would otherwise also be length 0. An inferred call must not emit `f__v` with a
// bare `N` left in the C.
fn const_generic_array_length_inferred(b: &mut h::ExitBatch) {
    b.add(
        "inferred from an array literal",
        "fn width<const N: usize>(a: [i32; N]) usize { return N; }\nfn main() i32 { return width([1, 2, 3]) as i32 - 3; }\n",
        0,
    );
    b.add(
        "inferred from a typed local",
        "fn width<const N: usize>(a: [i32; N]) usize { return N; }\nfn main() i32 {\n    let a: [i32; 2] = [1, 2];\n    return width(a) as i32 - 2;\n}\n",
        0,
    );
    b.add(
        "two lengths make two instances",
        "fn width<const N: usize>(a: [i32; N]) usize { return N; }\nfn main() i32 { return (width([1]) + width([1, 2, 3, 4])) as i32 - 5; }\n",
        0,
    );
    b.add(
        "an explicit argument still wins",
        "fn width<const N: usize>(a: [i32; N]) usize { return N; }\nfn main() i32 { return width::<3>([1, 2, 3]) as i32 - 3; }\n",
        0,
    );
}

@test
fn tuple_structs_byte_strings_and_slice_for() {
    let mut b = h::ExitBatch::new();
    // Tuple-struct construction lowers to positional aggregate init; reads spell `._N` in C.
    b.add(
        "tuple struct positional fields",
        "struct Wrap(i32, bool);\nfn main() i32 { let w = Wrap(30, true); let mut r = w.0; if w.1 { r += 5; } return r - 35; }\n",
        0,
    );
    // Generic tuple struct: element types bind under the instance's generic args.
    b.add(
        "generic tuple struct",
        "struct Pair<A, B>(A, B);\nfn main() i32 { let p = Pair::<i32, i32>(9, 4); return p.0 - p.1 - 5; }\n",
        0,
    );
    // `for value in slice` reads the length through the slice's runtime `.len`, not a static count.
    b.add(
        "for value in slice",
        "fn main() i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let mut t = 0;\n    for v in s { t += v; }\n    return t - 10;\n}\n",
        0,
    );
    // Byte-string literal: the `b` prefix is stripped and the bytes re-emit as a valid C string view.
    b.add("byte string literal", "fn main() i32 { let b = b\"AB\"; return (b[0] as i32) + (b[1] as i32) - 131; }\n", 0);
    // Tuple index then method: `0.len` must lex as an index access, not a malformed float.
    b.add(
        "tuple index chained method",
        "struct Words<'a>([]'a i32);\nfn main() i32 { let a: [i32; 3] = [4, 5, 6]; let w = Words(a[0..3]); return w.0.len() as i32 - 3; }\n",
        0,
    );
    // A tuple struct wrapping an owner gets an auto-derived destructor; the leak gate would fail if
    // the field were skipped. The string must be long enough to HEAP-allocate (past SSO), or a leak
    // of the field would be invisible.
    b.add(
        "tuple struct frees its owner",
        "struct Owned(String);\nfn main() i32 { let o = Owned(String::from_str(\"abcdefghijklmnopqrstuvwxyz0123456789\")); return o.0.len() as i32 - 36; }\n",
        0,
    );
    // escape decoding: `\\xNN` is exactly two hex digits (C would read `\\x41B` greedily); `\\u{..}`
    // becomes UTF-8 bytes (C rejects the syntax outright).
    b.add(
        "byte-string escapes decode to bytes",
        "fn main() i32 { let b = b\"\\x41B\"; let u = b\"\\u{41}\"; return (b[0] as i32) + (b[1] as i32) + (u[0] as i32) - 196; }\n",
        0,
    );
    // A tuple-struct constructor folds at compile time (a `const`/`static_assert` requires it).
    b.add(
        "tuple struct const-evaluates",
        "struct Pt(i32, i32);\nconst C: Pt = Pt(20, 22);\nstatic_assert(C.0 + C.1 == 42, \"tuple const eval\");\nfn main() i32 { return C.0 + C.1 - 42; }\n",
        0,
    );
    // zeroed::<TupleStruct>() must allocate one slot per positional member (a field-count of 0 wrote
    // out of bounds and crashed the compiler).
    b.add(
        "zeroed tuple struct",
        "struct Zt(i32, i32);\nconst Z: Zt = unsafe zeroed::<Zt>();\nstatic_assert(Z.0 == 0 && Z.1 == 0, \"zeroed tuple\");\nfn main() i32 { return Z.0 + Z.1; }\n",
        0,
    );
    // A fixed-array tuple member: constructing it needs the array-store path, and coercing `w.0` to a
    // slice needs the positional array-length recovery (both were struct-only).
    b.add(
        "tuple struct fixed-array member coerces to slice",
        "struct Wrap([i32; 3]);\nfn sum(s: []i32) i32 { return s[0] + s[1] + s[2]; }\nfn main() i32 { let w = Wrap([1, 2, 3]); return sum(w.0) - 6; }\n",
        0,
    );
    b.run();
}

@test
fn tuple_struct_reference_field_obeys_lifetimes() {
    // A reference stored in a tuple member is subject to the same stored-borrow rule as a named field.
    h::expect_err_msg(
        "reference tuple member needs a named lifetime",
        "struct RefT(&i32);\nfn main() i32 { return 0; }\n",
        "must name a lifetime",
    );
    // And a borrow of a local must not escape through a tuple constructor.
    h::expect_err_msg(
        "tuple constructor cannot leak a local borrow",
        "struct RefT<'a>(&'a i32);\nfn bad<'a>() RefT<'a> { let x = 5; return RefT::<'a>(&x); }\nfn main() i32 { return 0; }\n",
        "does not outlive",
    );
    // A tuple struct is recognized as Free when a member owns, so moving one member out is rejected
    // exactly as for a named struct (else the destructor double-frees at scope exit).
    h::expect_err_msg(
        "tuple partial move rejected like a named field",
        "struct Two(String, String);\nfn main() i32 { let t = Two(String::from_str(\"aaaaaaaaaaaaaaaaaaaaaaaaaa\"), String::from_str(\"bbbbbbbbbbbbbbbbbbbbbbbbbb\")); let a = t.0; return a.len() as i32; }\n",
        "cannot move a field out of a value implementing Free",
    );
}

fn names_that_are_standard_macros(b: &mut h::ExitBatch) {
    // Fields, payload members, locals, parameters, functions, consts and enum tags spelled like macros
    // of the standard headers every TU includes (complex.h `I`, errno.h `errno` and `EPERM`, stdio.h
    // `EOF` and `stdin`, stddef.h `NULL`, stdlib.h `EXIT_FAILURE`, tgmath.h `log`) get escaped C
    // names; an extern keeps its C name (`sqrt`).
    exit_case(
        b,
        "standard macro names",
        "extern \"C\" { fn sqrt(x: f64) f64; }\nenum P { I(i32), errno(i32), EOF { log: i32, NULL: i32 } }\nenum EXIT { SUCCESS, FAILURE }\nstruct S { pub I: i32, pub errno: i32, pub stdin: i32, pub INFINITY: i32, pub log: fn(i32) i32 }\nfn twice(v: i32) i32 { return v * 2; }\nfn I(errno: i32) i32 { let EOF = errno + 1; let NULL = EOF; return NULL; }\nfn log(x: i32) i32 { return x + 1; }\nconst EPERM: i32 = 3;\nfn main() i32 {\n    let s = S { I: 1, errno: 2, stdin: 3, INFINITY: 4, log: twice };\n    let bool = s.I + s.errno + s.stdin + s.INFINITY;\n    let p = P::EOF { log: 4, NULL: 5 };\n    let q = switch p { I(v) => v, errno(v) => v, EOF { log, NULL } => log + NULL };\n    let z = switch EXIT::FAILURE { SUCCESS => 0, FAILURE => 1 };\n    let r = unsafe sqrt(16.0) as i32;\n    unsafe exit(bool + q + z + I(1) + (s.log)(3) + log(1) + EPERM + r);\n}\n",
        37,
    );
}

fn names_that_c_headers_declare(b: &mut h::ExitBatch) {
    // Root-module items spelled like functions and types the included C headers declare (stdlib.h
    // `malloc`, `abs`, `exit` and `free`, stdio.h `printf` and `FILE`, time.h `tm`) get escaped C
    // names; an extern keeps its C name (`llabs`).
    b.add(
        "C library names",
        "extern \"C\" { fn llabs(x: i64) i64; }\nstruct FILE { pub fd: i32 }\nstruct tm { pub h: i32 }\nfn malloc(n: usize) usize { return n + 1; }\nfn abs(x: i32) i32 { if x < 0 { return 0 - x; } return x; }\nfn printf(x: i32) i32 { return x * 2; }\nfn exit(code: i32) i32 { return code + 3; }\nfn free(f: FILE) i32 { return f.fd; }\nfn time() tm { return tm { h: 7 }; }\nfn main() i32 {\n    let f = FILE { fd: 4 };\n    let l = unsafe llabs(-5) as i32;\n    return malloc(1) as i32 + abs(-3) + printf(5) + exit(1) + free(f) + time().h + l;\n}\n",
        35,
    );
}

// A use that reads an array constant as a slice types the use node as the slice, not the constant:
// the constant keeps its array storage, so an index into it and a slice view of it both work.
fn array_const_read_as_slice_keeps_array_storage(b: &mut h::ExitBatch) {
    b.add(
        "a slice view and an index of one array constant",
        "const NAMES: [str<'static>; 3] = [\"x\", \"yy\", \"zzz\"];\nfn main() i32 {\n    let n: []str = NAMES;\n    return (NAMES[2].len() + n.len()) as i32 - 6;\n}\n",
        0,
    );
}

// A `[]'static str` result views a constant array: it outlives every caller.
fn static_slice_result(b: &mut h::ExitBatch) {
    b.add(
        "a function returns a 'static slice of a constant",
        "const NAMES: [str<'static>; 3] = [\"x\", \"yy\", \"zzz\"];\nfn names() []'static str<'static> { return NAMES; }\nfn main() i32 {\n    let n = names();\n    return (n.len() + n[1].len()) as i32 - 5;\n}\n",
        0,
    );
}

// Runs `src` under the fatal leak gate: it must build and exit with `code`.
fn run_leak_free(label: str, src: str, code: i32) {
    let r = h::compile_and_run_env(src, "SC_LEAK_CHECK=fatal");
    assert(r.built, label);
    assert_eq(r.exit, code);
}

// `?` consumes its carrier: the payload moves out (a Free payload too), the error or None path
// propagates, and every heap block is freed exactly once, including a converted error.
fn question_moves_a_free_payload(b: &mut h::ExitBatch) {
    b.add(
        "? on Option and Result with String payloads",
        M"(fn heap(tag: str) String {
    let mut s = String::from_str("a heap string longer than twenty-three bytes: ");
    s.push_str(tag);
    return s;
}
struct AppErr { pub msg: String }
extend AppErr as From<String> {
    fn from(value: String) AppErr { return AppErr { msg: value }; }
}
fn mk(ok: bool) Option<String> {
    if ok { return Option::<String>::Some(heap("o")); }
    return Option::<String>::None;
}
fn mkr(ok: bool) Result<String, String> {
    if ok { return Result::<String, String>::Ok(heap("ok")); }
    return Result::<String, String>::Err(heap("err"));
}
fn opt(ok: bool) Option<usize> {
    let s = mk(ok)?;
    return Option::<usize>::Some(s.len());
}
fn res(ok: bool) Result<usize, String> {
    let s = mkr(ok)?;
    return Result::<usize, String>::Ok(s.len());
}
fn conv(ok: bool) Result<String, AppErr> {
    let r = mkr(ok);
    let s = r?;
    return Result::<String, AppErr>::Ok(s);
}
fn main() i32 {
    let a = opt(true);
    let b = opt(false);
    let c = res(true);
    let d = res(false);
    let e = conv(true);
    let f = conv(false);
    let fl = switch f {
        Ok(_) => 0,
        Err(x) => x.msg.len(),
    };
    if a.unwrap() != 47 || b.is_some() || c.is_err() || d.is_ok() || e.is_err() || fl != 49 {
        return 1;
    }
    return 0;
})",
        0,
    );
}

// A `for` over an array literal lowers like one over a bound array. By value, the loop consumes the
// array: each element moves into the binding and is freed at the end of its iteration, and `break`,
// `return` and an outer `break` free the elements the loop did not reach.
fn for_over_array_literal(b: &mut h::ExitBatch) {
    b.add(
        "for over Copy and Free array literals",
        M"(fn heap(tag: str) String {
    let mut s = String::from_str("a heap string longer than twenty-three bytes: ");
    s.push_str(tag);
    return s;
}
fn first_longer(limit: usize) usize {
    for s in [heap("a"), heap("bb"), heap("ccc")] {
        if s.len() > limit {
            return s.len();
        }
    }
    return 0;
}
fn main() i32 {
    let mut t: i32 = 0;
    for x in [1, 2, 3] {
        t += x;
    }
    let mut n: usize = 0;
    for s in [heap("a"), heap("bb")] {
        n += s.len();
    }
    let arr = [heap("x"), heap("yy"), heap("zzz")];
    let mut k: usize = 0;
    for s in arr {
        k += 1;
        if s.len() == 48 {
            break;
        }
    }
    let mut c: usize = 0;
    for s in [heap("p"), heap("q"), heap("r")] {
        c += 1;
        if c == 1 {
            continue;
        }
        if s.len() == 0 {
            return 9;
        }
    }
    let mut m: usize = 0;
    'outer: for i in 0..2usize {
        for s in [heap("u"), heap("v")] {
            m += s.len() + i;
            break 'outer;
        }
    }
    if t != 6 || n != 95 || k != 2 || c != 3 || first_longer(47) != 48 || m != 47 {
        return 1;
    }
    return 0;
})",
        0,
    );
}

// A generic body consumes an array of `T` when `T` owns: the instance over `String` frees the elements
// a `break` skips, the one over `i32` frees nothing.
fn for_over_generic_array_consumes_owning_elements(b: &mut h::ExitBatch) {
    b.add(
        "for over [T; 3] with String and i32",
        M"(fn count<T>(xs: [T; 3], stop: usize) usize {
    let mut n: usize = 0;
    for x in xs {
        n += 1;
        if n == stop {
            break;
        }
    }
    return n;
}
fn heap(tag: str) String {
    let mut s = String::from_str("a heap string longer than twenty-three bytes: ");
    s.push_str(tag);
    return s;
}
fn main() i32 {
    let a = count([heap("1"), heap("2"), heap("3")], 2);
    let b = count([1, 2, 3], 5);
    return (a + b) as i32 - 5;
})",
        0,
    );
}

// An array of Free elements frees each element: as a local, a struct field and an enum payload.
fn array_of_free_elements_drops_each(b: &mut h::ExitBatch) {
    b.add(
        "array drops in locals, fields and payloads",
        M"(fn heap(tag: str) String {
    let mut s = String::from_str("a heap string longer than twenty-three bytes: ");
    s.push_str(tag);
    return s;
}
struct Pair { pub names: [String; 2] }
enum E { A([String; 2]), B }
fn main() i32 {
    let arr = [heap("a"), heap("bb")];
    let p = Pair { names: [heap("c"), heap("d")] };
    let e = E::B;
    let z = switch e {
        A(_) => 1,
        B => 0,
    };
    if arr[1].len() != 48 || p.names[0].len() != 47 {
        return 1;
    }
    return z;
})",
        0,
    );
}

// A closure that mutates a capture holds a pointer to the binding (an implicit `&mut`), also through
// an `F: fn(..)` bound; an owning capture it only reads is borrowed when it meets a plain `fn(..)`
// bound. The outer bindings see every change and still own (and free) their values.
fn closures_mutate_and_borrow_captures_through_bounds(b: &mut h::ExitBatch) {
    b.add(
        "mutated and borrowed captures through fn bounds",
        M"(fn heap(tag: str) String {
    let mut s = String::from_str("a heap string longer than twenty-three bytes: ");
    s.push_str(tag);
    return s;
}
fn apply<F: fn(i32)>(f: F) {
    f(1);
    f(2);
}
fn each<F: fn(i32)>(xs: []i32, f: F) {
    for x in xs {
        f(x);
    }
}
fn run<F: fn()>(f: F) {
    f();
}
fn main() i32 {
    let mut s: i32 = 0;
    apply(|x: i32| {
        s += x;
    });
    let arr = [1, 2, 3];
    let mut t: i32 = 0;
    each(arr, |x| t += x);
    let mut v = Vector::<String>::new();
    let tag = heap("t");
    apply(|x: i32| {
        v.push(heap("p"));
        if x == 2 {
            v.push(tag.clone());
        }
    });
    let mut total: usize = 0;
    let mut count: i32 = 0;
    run(|| {
        for e in v.iter() {
            total += e.len();
        }
        let inner = || {
            count += 1;
        };
        run(inner);
    });
    let mut w = heap("w");
    run(|| w.push_str("x"));
    let key = String::from_str("keep");
    let mut names = Vector::<String>::new();
    names.push(String::from_str("keep"));
    names.push(String::from_str("drop"));
    names.retain(|n: &String| n.as_str() == key.as_str());
    if s != 3 || t != 6 || v.len() != 3 || total != 141 || count != 1 || w.len() != 48 || names.len() != 1 || tag.len() != 47 {
        return 1;
    }
    return 0;
})",
        0,
    );
}

// A nested array literal stores each inner array into its slot (C cannot initialize an array from
// a variable), at any depth, with runtime and constant elements, with and without a type
// annotation, and a designated inner literal zero-fills the rest of its slot.
fn nested_array_literals_store_by_slot(b: &mut h::ExitBatch) {
    b.add(
        "nested array literals",
        M"(fn mk(x: i32) [[i32; 1]; 2] {
    return [[x], [x + 1]];
}
fn main() i32 {
    let x: i32 = 5;
    let g: [[i32; 1]; 2] = [[x], [x + 1]];
    let h = mk(x);
    let k = [[[x, 1], [2, x]], [[3, 4], [x, 7]]];
    let mut t: [[i32; 2]; 2] = [[9, 9], [9, 9]];
    t = [[x, x], [1, 2]];
    let v: [[i32; 4]; 2] = [[1, 2, 3, 4], [[1] = x]];
    let mut w: [[i32; 4]; 2] = [[9, 9, 9, 9], [9, 9, 9, 9]];
    w = [[1, 2, 3, 4], [[2] = x]];
    let s = [[String::from_str("a heap string longer than twenty-three bytes")], [String::from_str("x")]];
    let c = k;
    if g[1][0] != 6 || h[0][0] != 5 || k[1][1][0] != 5 || c[0][1][1] != 5 || t[0][1] != 5 || t[1][1] != 2 {
        return 1;
    }
    if v[1][0] != 0 || v[1][1] != 5 || v[1][3] != 0 || w[1][0] != 0 || w[1][2] != 5 || w[1][3] != 0 {
        return 2;
    }
    return s[0][0].len() as i32 + s[1][0].len() as i32 - 45;
}
)",
        0,
    );
}

// Every aggregate that stores a fixed-array value copies it: a variant payload (positional and
// named), a tuple element, a struct field, a closure capture, an array element and a return value,
// also when the source is a by-value array parameter (a pointer in C).
fn array_values_copy_into_aggregates(b: &mut h::ExitBatch) {
    b.add(
        "array payloads, elements, captures and parameters",
        M"(enum E { A([i32; 3]), B { tag: i32, v: [i32; 2] }, C }
struct W { pub a: [i32; 3], pub n: i32 }
@c.export("sc_arr_param")
fn from_param(a: [i32; 3]) i32 {
    let mut b: [i32; 3] = [0, 0, 0];
    b = a;
    let w = W { a: a, n: 1 };
    let e = E::A(a);
    let g = [a, a];
    let t = (a, 1);
    let c = || a[2] * 2;
    let x = switch e { A(v) => v[2], _ => 0 };
    return b[2] + w.a[2] + x + g[1][2] + t.0[2] + c();
}
fn ret(a: [i32; 2]) [i32; 2] {
    return a;
}
fn main() i32 {
    let mut arr: [i32; 3] = [1, 2, 3];
    arr[1] = 7;
    let mut two: [i32; 2] = [4, 5];
    two[0] = 8;
    let e = E::A(arr);
    let f = E::B { tag: 3, v: two };
    let o = Option::<[i32; 2]>::Some(two);
    let c = || two[1] + arr[2];
    let r = ret(two);
    two[1] = 100;
    let s1 = switch e { A(a) => a[1], _ => 0 };
    let s2 = switch f { B { tag, v } => tag + v[0], _ => 0 };
    let s3 = switch o { Some(v) => v[1], None => 0 };
    let names = [String::from_str("a heap string longer than twenty-three bytes"), String::from_str("y")];
    let n = || names[0].len();
    if s1 != 7 || s2 != 11 || s3 != 5 || c() != 8 || r[1] != 5 || n() != 44 {
        return 1;
    }
    return from_param(arr) - 21;
}
)",
        0,
    );
}

// An explicit conditional `Free` extend covers only the instances whose `Free`-bounded arguments
// own memory; any other instance still frees its owning members through the derived destructor:
// at scope exit, inside a container, through a generic `free` and through an explicit `.free()`.
// The user `free` counts its calls: only the two covered instances reach it.
fn uncovered_conditional_free_instances_derive(b: &mut h::ExitBatch) {
    b.add(
        "conditional Free extends and uncovered instances",
        M"(static mut CALLS: i32 = 0;
struct P<T> { pub a: T, pub s: String }
extend<T: Free> P<T> as Free {
    pub fn free(self: &mut P<T>) {
        unsafe CALLS += 1;
        self.a.free();
        self.s.free();
    }
}
enum X<T, E> { A(T), B(E), C }
extend<T: Free, E> X<T, E> as Free {
    pub fn free(self: &mut X<T, E>) {
        unsafe CALLS += 10;
        switch self {
            A(v) => v.free(),
            B(e) => e.free(),
            C => {},
        };
    }
}
fn heap(tag: str) String {
    let mut s = String::from_str("a heap string longer than twenty-three bytes: ");
    s.push_str(tag);
    return s;
}
fn take(p: P<i32>) i32 {
    return p.a;
}
fn drop_it<T: Free>(x: T) {
    x.free();
}
fn main() i32 {
    {
        let p = P::<i32> { a: 1, s: heap("p") };
        let q = P::<String> { a: heap("qa"), s: heap("qs") };
        let x = X::<i32, String>::B(heap("x"));
        let y = X::<String, i32>::A(heap("y"));
        let mut v = Vector::<P<i32>>::new();
        v.push(P::<i32> { a: 2, s: heap("v") });
        let o = Option::<X<i32, String>>::Some(X::<i32, String>::B(heap("o")));
        drop_it(X::<i32, String>::B(heap("g")));
        let z = X::<i32, String>::B(heap("z"));
        z.free();
        if take(p) != 1 || q.a.len() != 48 || v.len() != 1 {
            return 1;
        }
    }
    return unsafe CALLS - 11;
}
)",
        0,
    );
}

// A function whose result is a function pointer names it through a `<fn>_ret` typedef (C spells
// such a result around the declarator), and `&&` in a type or an expression is two references:
// a shared reference to a `&mut` spells its pointer const (`T *const *`), never its pointee.
fn function_pointer_results_and_double_references(b: &mut h::ExitBatch) {
    b.add(
        "function-pointer results and double references",
        M"(fn one() i32 {
    return 1;
}
fn two() i32 {
    return 2;
}
@c.export("sc_pick_fn")
fn pick(b: bool) fn() i32 {
    if b {
        return one;
    }
    return two;
}
fn rr(r: &&i32) i32 {
    return **r;
}
fn rm(r: &&mut i32) i32 {
    return **r;
}
fn main() i32 {
    let a = 3;
    let mut b = 4;
    let both = a > 2 && b > 3;
    let r = &&a;
    let s: &&mut i32 = &&mut b;
    return pick(true)() + pick(false)() * 10 + rr(r) * 100 + rm(s) * 1000 + both as i32 * 10000 - 14321;
}
)",
        0,
    );
}

// A by-value `switch` (and the `if let`, `while let` and `for` patterns built on it) owns its
// scrutinee: at the end of the arm that ran, what the arm's bindings did not move out is freed. An
// enum frees the members of the variant the arm matched; a guard that fails hands its bindings back
// to the scrutinee, so a later arm sees the whole value.
fn switch_frees_unbound_scrutinee_parts(b: &mut h::ExitBatch) {
    b.add(
        "switch arms that bind part of an owned scrutinee",
        M"(fn heap(tag: str) String {
    let mut s = String::from_str("a heap string longer than twenty-three bytes: ");
    s.push_str(tag);
    return s;
}
enum E { A(String, String), B { x: String, y: String }, N(Option<String>, String), C }
enum W { V(String, String) }
struct S { pub a: String, pub b: String, pub n: i32 }
fn mk(k: i32) E {
    if k == 0 { return E::A(heap("a0"), heap("a1")); }
    if k == 1 { return E::B { x: heap("bx"), y: heap("by") }; }
    if k == 2 { return E::N(Option::<String>::Some(heap("n0")), heap("n1")); }
    return E::C;
}
fn arms(k: i32) usize {
    return switch mk(k) {
        A(a, _) => a.len(),
        B { y, .. } => y.len(),
        N(Some(s), _) => s.len(),
        N(None, t) => t.len(),
        C => 0,
    };
}
fn guarded(k: i32, lim: usize) usize {
    return switch mk(k) {
        A(a, _) if a.len() > lim => 1,
        A(_, b) => b.len(),
        B { x, .. } if x.len() > lim => 2,
        _ => 3,
    };
}
fn early(k: i32) usize {
    switch mk(k) {
        A(_, b) => {
            if b.len() > 3 {
                return b.len();
            }
        },
        _ => {},
    };
    return 0;
}
fn main() i32 {
    let o = Option::<String>::Some(heap("o"));
    let r1 = switch o { Some(_) => 1, None => 0 };
    let res = Result::<String, String>::Err(heap("e"));
    let r2 = switch res { Ok(_) => 0, Err(_) => 1 };
    let t = (heap("t0"), heap("t1"));
    let r3 = switch t { (a, _) => a.len() };
    let s = S { a: heap("sa"), b: heap("sb"), n: 4 };
    let r4 = switch s { S { a, .. } => a.len() };
    let mut n: usize = 0;
    for k in 0..4 {
        n += arms(k) + guarded(k, 100) + guarded(k, 1) + early(k);
    }
    let e = mk(0);
    if let A(x, _) = e {
        n += x.len();
    }
    let mut v = Vector::<Option<(String, String)>>::new();
    v.push(Option::<(String, String)>::None);
    v.push(Option::<(String, String)>::Some((heap("p0"), heap("p1"))));
    while let Some(Some((a, _))) = v.pop() {
        n += a.len();
        break;
    }
    let ws = [W::V(heap("w0"), heap("w1"))];
    for V(a, _) in ws {
        n += a.len();
    }
    return r1 + r2 + (r3 + r4 + n) as i32 - 500;
}
)",
        0,
    );
}

// An array literal's expected element type reaches the elements that take their type from the
// context: a generic variant without type arguments, a generic fn named as a value, a closure.
fn array_literal_elements_take_the_expected_type(b: &mut h::ExitBatch) {
    b.add(
        "generic variants in annotated array literals and array or slice arguments",
        M"(fn sum(xs: []Option<i32>) i32 {
    let mut s = 0;
    for x in xs { s += x.unwrap_or(0); }
    return s;
}
fn arr(xs: [Option<i32>; 2]) i32 { return xs[0].unwrap_or(0) + xs[1].unwrap_or(0); }
fn main() i32 {
    let a: [Option<i32>; 2] = [Option::Some(1), Option::None];
    let b = arr([Option::Some(2), Option::None]);
    let c = sum([Option::Some(3), Option::None, Option::Some(4)]);
    let d: []Option<i32> = [Option::None, Option::Some(5)];
    return a[0].unwrap() + b + c + sum(d) - 15;
}
)",
        0,
    );
    b.add(
        "function values in an annotated array literal",
        M"(fn twice(x: i32) i32 { return x * 2; }
fn id<T>(x: T) T { return x; }
fn main() i32 {
    let fs: [fn(i32) i32; 3] = [twice, id, |x| x + 1];
    let mut s = 0;
    for f in fs { s += f(3); }
    return s - 13;
}
)",
        0,
    );
}

// An array literal of untyped elements (`null`) takes its element type from the others or from the
// context: a struct field, a return, an argument, an assignment or an annotation.
@test
fn null_array_elements_take_the_expected_type() {
    run_leak_free(
        "null elements of pointer arrays",
        M"(struct H { pub hs: [*mut i32; 2], pub w: i32 }
fn mk() [*mut i32; 2] { return [null, null]; }
fn nulls(x: [*mut i32; 2]) bool { return x[0] == null && x[1] == null; }
fn main() i32 {
    let mut v = 5;
    let p: *mut i32 = &mut v;
    let h = H { hs: [null, p], w: 0 };
    let a: [*mut i32; 2] = [null, null];
    let b = [null, p];
    let mut k = mk();
    if !nulls(k) { return 3; }
    k = [null, null];
    if !nulls(mk()) || !nulls([null, null]) || !nulls(a) || !nulls(k) { return 1; }
    if b[0] != null || h.hs[0] != null { return 2; }
    return unsafe *h.hs[1] - 5 + h.w;
}
)",
        0,
    );
    h::expect_err_msg(
        "null elements with no expected type",
        "fn main() i32 {\n    let y = [null, null];\n    return 0;\n}\n",
        "cannot infer the element type of an array literal of 'null'; annotate the pointer type",
    );
}

// `[]` takes its element type from an expected array or slice. A zero-length array (a constant, a
// local, a parameter, one read through a reference) viewed as a slice points at the aligned
// zero-size sentinel with length 0: C has no zero-length object to point at.
@test
fn zero_length_array_views() {
    run_leak_free(
        "zero-length arrays as slices",
        M"(const NONE: [i32; 0] = [];
const EMPTY: []i32 = [];
fn view() Slice<'static, i32> { return NONE; }
fn take(a: [i32; 0]) usize { let s: []i32 = a; return s.len(); }
fn main() i32 {
    let e: [i32; 0] = [];
    let t: []i32 = e;
    let u: []i32 = [];
    let r = &NONE;
    let w: []i32 = *r;
    for x in view() { return x; }
    return (view().len() + t.len() + u.len() + take(NONE) + w.len() + EMPTY.len()) as i32;
}
)",
        0,
    );
    h::expect_c(
        "the view of a zero-length constant",
        M"(const NONE: [i32; 0] = [];
fn view() Slice<'static, i32> { return NONE; }
fn main() i32 { return view().len() as i32; }
)",
        ".ptr = ((void *)&__sc_zst_4), .len = 0 }",
    );
}

// A body whose drops need a move flag gets its statement runs rewritten; the emitter reads the
// statement pool as a whole, so the superseded runs must be gone: an array local copied into a
// `for` loop keeps its one C name.
fn flagged_drop_keeps_array_local_names(b: &mut h::ExitBatch) {
    b.add(
        "for over an array local with a conditionally moved element",
        M"(fn heap(tag: str) String {
    let mut s = String::from_str("a heap string longer than twenty-three bytes: ");
    s.push_str(tag);
    return s;
}
fn eat(s: String) usize { return s.len(); }
fn main() i32 {
    let mut n: usize = 0;
    let ws = [heap("a"), heap("b")];
    for w in ws { if n == 0 { n += eat(w); } }
    return n as i32 - 47;
}
)",
        0,
    );
}

// A prototype with an array parameter needs its element type complete (C rejects an array of an
// incomplete type), so the module's prototype header includes the element's definition header.
fn array_parameter_element_is_complete_in_prototype_header(b: &mut h::ExitBatch) {
    b.add(
        "array of str parameter",
        M"(struct Pool<'a> { pub v: Vector<str<'a>> }
fn f(p: &mut Pool, arr: [str; 1]) usize { let _ = p; return arr[0].len(); }
fn main() i32 {
    let mut p = Pool { v: Vector::new() };
    return (f(&mut p, ["ab"]) - 2) as i32;
}
)",
        0,
    );
}

// C rejects an array of an incomplete type, and an aggregate is incomplete inside its own definition:
// a pointer to an array of aggregates is a pointer to the array's wrapper struct (`Node__a2`, defined
// after `Node`), so reads, writes, indexing through it, pointer arithmetic, a function-pointer member
// taking one and the layout check keep the array's type and layout.
fn pointer_to_array_of_enclosing_aggregate(b: &mut h::ExitBatch) {
    b.add(
        "self-referential tree",
        M"(struct Node { pub kids: *mut [Node; 2], pub v: i32 }
fn sum(n: *const Node) i32 {
    let k = unsafe (*n).kids;
    if k == null {
        return unsafe (*n).v;
    }
    return unsafe (*n).v + sum(unsafe &(*k)[0]) + sum(unsafe &(*k)[1]);
}
fn main() i32 {
    let mut leaves: [Node; 2] = [Node { kids: null, v: 1 }, Node { kids: null, v: 2 }];
    let mut mid: [Node; 2] = [Node { kids: &mut leaves, v: 10 }, Node { kids: null, v: 20 }];
    let root = Node { kids: &mut mid, v: 100 };
    if sum(&root) != 133 { return 1; }
    if unsafe (*unsafe (*root.kids)[0].kids)[1].v != 2 { return 2; }
    let mut r2 = root;
    r2.kids = &mut leaves;
    unsafe (*r2.kids)[1].v = 7;
    if leaves[1].v != 7 { return 3; }
    let pk = &r2.kids;
    if unsafe (**pk)[0].v != 1 { return 4; }
    let mut two: [[Node; 2]; 2] = [leaves, mid];
    let p0: *mut [Node; 2] = &mut two[0];
    let r3 = Node { kids: unsafe (p0 + 1), v: 0 };
    if unsafe (*r3.kids)[0].v != 10 { return 5; }
    if unsafe (*(r3.kids - 1))[1].v != 7 { return 6; }
    return 0;
}
)",
        0,
    );
    b.add(
        "mutually recursive aggregates",
        M"(struct A { pub bs: *const [B; 2], pub x: i32 }
struct B { pub a: *mut [A; 3], pub y: i32 }
enum T { Leaf(i32), Pair(*mut [T; 2]) }
struct H { pub hs: [*mut [H; 2]; 2], pub o: Option<*mut [H; 2]>, pub w: i32 }
fn tsum(t: &T) i32 {
    return switch *t {
        Leaf(v) => v,
        Pair(p) => tsum(unsafe &(*p)[0]) + tsum(unsafe &(*p)[1]),
    };
}
fn main() i32 {
    let mut as3: [A; 3] = [A { bs: null, x: 1 }, A { bs: null, x: 2 }, A { bs: null, x: 3 }];
    let bs: [B; 2] = [B { a: &mut as3, y: 5 }, B { a: null, y: 6 }];
    as3[2].bs = &bs;
    if unsafe (*unsafe (*as3[2].bs)[0].a)[2].x != 3 { return 1; }
    if unsafe (*as3[2].bs)[1].y != 6 { return 2; }
    let mut tl: [T; 2] = [T::Leaf(3), T::Leaf(4)];
    let t = T::Pair(&mut tl);
    if tsum(&t) != 7 { return 3; }
    let mut hh: [H; 2] = [
        H { hs: [null, null], o: Option::None, w: 1 },
        H { hs: [null, null], o: Option::None, w: 2 },
    ];
    let h = H { hs: [null, &mut hh], o: Option::Some(&mut hh), w: 0 };
    if unsafe (*h.hs[1])[1].w != 2 { return 4; }
    if unsafe (*h.o.unwrap())[0].w != 1 { return 5; }
    return 0;
}
)",
        0,
    );
    b.add(
        "function-pointer members taking a pointer to an array of the enclosing aggregate",
        M"(struct F { pub f: fn(*mut [F; 2]) i32, pub g: fn(&[F; 2]) i32, pub v: i32 }
fn first(p: *mut [F; 2]) i32 { return unsafe (*p)[0].v; }
fn second(p: &[F; 2]) i32 { return p[1].v; }
fn main() i32 {
    let mut fs: [F; 2] = [F { f: first, g: second, v: 3 }, F { f: first, g: second, v: 4 }];
    let a = (fs[0].f)(&mut fs);
    let b = (fs[1].g)(&fs);
    return a + b - 7;
}
)",
        0,
    );
    // Container storage of arrays of aggregates holds wrapper pointers the same way: indexing and
    // slicing offset it as the array type.
    b.add(
        "container storage",
        M"(struct P { pub x: i32, pub y: i32 }
fn total(s: [][P; 2]) i32 {
    let mut t = 0;
    for pr in s {
        t += pr[0].x + pr[1].y;
    }
    return t;
}
fn main() i32 {
    let mut v = Vector::<[P; 2]>::new();
    v.push([P { x: 1, y: 2 }, P { x: 3, y: 4 }]);
    v.push([P { x: 5, y: 6 }, P { x: 7, y: 8 }]);
    if v[1][0].x != 5 { return 1; }
    v[0][1].y = 40;
    let s = v[0..2];
    if total(s) != 54 { return 2; }
    if s[1..2][0][1].x != 7 { return 3; }
    let b = Box::new([P { x: 9, y: 10 }, P { x: 11, y: 12 }]);
    if (*b)[1].x != 11 { return 4; }
    let mut arr = [P { x: 1, y: 1 }, P { x: 2, y: 2 }];
    let mut w = Vector::<*mut [P; 2]>::new();
    w.push(&mut arr);
    if unsafe (*w[0])[1].y != 2 { return 5; }
    return 0;
}
)",
        0,
    );
}

// A function-pointer type is its signature: substitution reaches its parameters and result, so a
// generic struct's `fn(T) T` field is `fn(i32) i32` in `W<i32>` whichever way the value is written
// (a turbofished generic fn, a closure, a plain fn, a pointer read from another field), inference
// takes the struct's arguments from it, and two spellings of one signature are one type (`Option`,
// `Vector` and array element types included). `dyn fn` signatures substitute the same way.
fn function_types_substitute_structurally(b: &mut h::ExitBatch) {
    b.add(
        "generic struct fields of function type",
        M"(struct W<T> { pub f: fn(T) T }
struct G<T> { pub get: fn(&T) Option<T> }
struct D<T> { pub f: Box<dyn fn(T) T> }
fn id<U>(x: U) U { return x; }
fn inc(x: i32) i32 { return x + 1; }
fn first(v: &i32) Option<i32> { return Option::Some(*v); }
fn apply<T>(w: &W<T>, x: T) T { return (w.f)(x); }
fn wrap<T>(f: fn(T) T) W<T> { return W { f: f }; }
fn run<T>(d: &D<T>, x: T) T { return (d.f)(x); }
fn main() i32 {
    let w1 = W { f: id::<i32> };
    let w2 = W::<i32> { f: id::<i32> };
    let w3 = W { f: |x: i32| x + 1 };
    let w4 = W { f: inc };
    let w5: W<i64> = W { f: id::<i64> };
    if w1.f(3) != 3 || w2.f(4) != 4 || w3.f(5) != 6 || w4.f(6) != 7 || w5.f(7) != 7 { return 1; }
    let g = w3.f;
    if g(1) != 2 { return 2; }
    if apply(&w4, 10) != 11 || apply(&w5, 20) != 20 { return 3; }
    let w6 = wrap(inc);
    if w6.f(0) != 1 { return 4; }
    let gg = G { get: first };
    let k = 9;
    if gg.get(&k).unwrap() != 9 { return 5; }
    let h = id::<i32>;
    if h(8) != 8 { return 6; }
    let d = D::<i32> { f: |x: i32| x * 2 };
    if run(&d, 21) != 42 { return 7; }
    let fs: [fn(i32) i32; 2] = [w1.f, w4.f];
    if fs[1](1) != 2 { return 8; }
    let mut v = Vector::<fn(i32) i32>::new();
    v.push(inc);
    let o: Option<fn(i32) i32> = Option::Some(id::<i32>);
    let p: Option<fn(i32) i32> = o;
    if (*v.at(0))(1) != 2 || p.unwrap()(5) != 5 { return 9; }
    return 0;
}
)",
        0,
    );
    // Generic bodies instantiate their function-pointer types per instance; a signature of more than
    // eight slots continues in a second record; `fn(..) void` is `fn(..)`.
    b.add(
        "function types under instantiation",
        M"(struct W<T> { pub f: fn(T) T }
fn id<U>(x: U) U { return x; }
fn mk<T>() W<T> { return W { f: id::<T> }; }
fn twice<T>(x: T, f: fn(T) T) T { let v = Vector::<fn(T) T>::new(); let _ = v; return f(f(x)); }
fn dbl(x: i64) i64 { return x * 2; }
fn inc(x: i32) i32 { return x + 1; }
fn nine(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32, h: i32, i: i32) i32 { return a + b + c + d + e + f + g + h + i; }
fn nop(x: i32) void { let _ = x; }
struct N { pub f: fn(i32, i32, i32, i32, i32, i32, i32, i32, i32) i32 }
fn gen9<T: Copy>(f: fn(T, T, T, T, T, T, T, T, T) T, x: T) T { return f(x, x, x, x, x, x, x, x, x); }
fn main() i32 {
    let a = mk::<i32>();
    let b = mk::<i64>();
    if a.f(3) != 3 || b.f(4) != 4 { return 1; }
    if twice(3, inc) != 5 || twice(3i64, dbl) != 12 { return 2; }
    let n = N { f: nine };
    if n.f(1, 1, 1, 1, 1, 1, 1, 1, 1) != 9 { return 3; }
    if gen9(nine, 2) != 18 { return 4; }
    let v1: fn(i32) = nop;
    let v2: fn(i32) void = v1;
    v2(1);
    let o: Option<fn(i32)> = Option::Some(v2);
    let _ = o;
    return 0;
}
)",
        0,
    );
}

// A tuple holding a function item takes the fn-pointer type its context names (an array of them has
// its written length), and a field whose type is a function item calls the stored value: nothing is
// passed as a receiver. A function item casts to a function-pointer type of its signature.
fn function_items_in_tuples_and_fields(b: &mut h::ExitBatch) {
    b.add(
        "function items in tuples, arrays and fields",
        M"(struct W<F> { pub f: F }
fn one() i32 { return 1; }
fn two() i32 { return 2; }
fn main() i32 {
    let t: [(i32, fn() i32); 2] = [(1, one), (2, two)];
    let t0 = t[0];
    if sizeof(t) != 2 * sizeof(t0) || t[1].1() != 2 || t[0].1() != 1 || t[1].0 != 2 { return 1; }
    let u = (1, one);
    let w = W { f: two };
    let g = two as fn() i32;
    let v = [(1, one), (2, one)];
    return u.1() + w.f() * 4 + g() * 16 + v[1].1() * 64;
}
)",
        105,
    );
}

// `Box::new(closure)` erases to `Box<dyn fn(..)>` as a boxed value erases to `Box<dyn I>`: the payload
// pointer moves into the fat value and the table frees the captures once. A function item erases to
// `dyn fn` too, owned or borrowed.
fn boxed_closures_erase_to_dyn_fn(b: &mut h::ExitBatch) {
    b.add(
        "Box::new(closure) as Box<dyn fn>",
        M"(fn apply(f: Box<dyn fn(i32) i32>, x: i32) i32 { return f(x); }
fn one() i32 { return 1; }
fn main() i32 {
    let b: Box<dyn fn(i32) i32> = Box::new(|x: i32| x + 1);
    let s = String::from_str("a heap string longer than twenty-three bytes");
    let c: Box<dyn fn(i32) i32> = Box::new(move |x: i32| x + s.len() as i32);
    let k = 5;
    let d = apply(Box::new(|x: i32| x * k), 3);
    let mut n = 0;
    {
        let m: Box<dyn fn()> = Box::new(|| { n += 2; });
        m();
        m();
    }
    let e: Box<dyn fn() i32> = Box::new(one);
    let r: &dyn fn() i32 = &one;
    return b(2) + c(0) - 44 + d - 15 + n - 4 + e() + r() - 2;
}
)",
        3,
    );
}

// Negative const-generic arguments mangle to identifiers (`n` for the minus sign), distinct from the
// positive ones, and i64::MIN is spelled as a C expression.
@test
fn negative_const_generic_arguments() {
    const SRC: str = M"(struct S<const N: i64> { pub x: i32 }
extend<const N: i64> S<N> { fn n(self: &Self) i64 { return N; } }
fn g<const N: i64>() i64 { return N; }
fn u<const N: u64>() u64 { return N; }
fn main() i32 {
    let s = S::<{-3}> { x: 1 };
    let t = S::<3> { x: 2 };
    let m = S::<{-9223372036854775807 - 1}> { x: 3 };
    if s.n() != -3 || t.n() != 3 || g::<{-5}>() != -5 || m.n() != -9223372036854775807 - 1 { return 1; }
    if u::<18446744073709551615>() != 18446744073709551615 { return 2; }
    return s.x + t.x + m.x - 6;
}
)";
    h::expect_exit("negative const arguments", SRC, 0);
    h::expect_c("a negative argument mangles with n", SRC, "S__n3");
}

// A generic extend's associated constant has a value per instance: its initializer may depend on the
// extend's parameters, it folds in constant contexts, and each instance is its own static datum.
@test
fn generic_extend_associated_constants() {
    const SRC: str = M"(struct W<T> { pub x: T }
struct P { pub a: i32, pub b: i32 }
extend<T> W<T> {
    pub const K: i32 = 5;
    pub const S: usize = sizeof(T);
    pub const Z: T = 0 as T;
    pub const PP: P = P { a: sizeof(T) as i32, b: 7 };
    pub const NAME: str = "w";
    pub fn s(self: &Self) usize { return W::<T>::S; }
}
const X: usize = W::<u64>::S;
static_assert(W::<u16>::S == 2);
fn g<U>() usize { return W::<U>::S + W::<W<U>>::S; }
fn main() i32 {
    let w = W::<u32> { x: 1 };
    let p = W::<u16>::PP;
    let r = &W::<u8>::S;
    if W::<u8>::K != 5 || X != 8 || w.s() != 4 || g::<u64>() != 16 || g::<u8>() != 2 { return 1; }
    if W::<i64>::Z != 0 || p.a != 2 || p.b != 7 || W::<u8>::NAME.len() != 1 || *r != 1 { return 2; }
    return 0;
}
)";
    h::expect_exit("generic extend constants", SRC, 0);
    h::expect_c("one datum per instance", SRC, "int32_t W__u8__K = 5;");
    h::expect_err_msg(
        "an instance is required",
        "struct W<T> { pub x: T }\nextend<T> W<T> { pub const K: i32 = 5; }\nfn main() i32 { return W::K; }\n",
        "cannot infer the generic arguments of associated constant 'K'; give explicit type arguments",
    );
    h::expect_err_msg(
        "the extend's bounds hold",
        "struct W<T> { pub x: T }\nextend<T: Copy> W<T> { pub const K: i32 = 5; }\nfn main() i32 { return W::<String>::K; }\n",
        "cannot use 'W<String<Global>>::K': unsatisfied interface bounds",
    );
}

// A u64 const-generic argument above i64::MAX keeps its value: the same instance whatever spells
// it, u64 arithmetic in a closed form, its own symbol, and an argument outside the parameter's
// type is an error.
@test
fn u64_const_generic_arguments() {
    const SRC: str = M"(struct U<const N: u64> { pub x: i32 }
extend<const N: u64> U<N> {
    pub fn n(self: &Self) u64 { return N; }
    pub fn big(self: &Self) bool { return N > 5; }
}
struct I<const N: i64> { pub x: i32 }
const fn half<const N: u64>() u64 { return N / 2; }
fn main() i32 {
    let u: U<18446744073709551615> = U::<{u64::MAX}> { x: 0 };
    let h = U::<{u64::MAX / 2}> { x: 0 };
    let t = U::<{9223372036854775807 + 1}> { x: 0 };
    let i = I::<{-9223372036854775807 - 1}> { x: 0 };
    static_assert(half::<18446744073709551615>() == 9223372036854775807);
    if u.n() != 18446744073709551615 || !u.big() || h.n() != 9223372036854775807 { return 1; }
    if t.n() != 9223372036854775808 { return 2; }
    return u.x + h.x + t.x + i.x;
}
)";
    h::expect_exit("u64 const arguments", SRC, 0);
    h::expect_c("u64::MAX spells its value", SRC, "U__18446744073709551615");
    h::expect_c("2^63 as u64", SRC, "U__9223372036854775808");
    h::expect_c("-2^63 as i64", SRC, "I___n9223372036854775808");
    h::expect_err_msg(
        "a negative u64 argument",
        "struct U<const N: u64> { pub x: i32 }\nfn main() i32 { let u = U::<{0 - 1}> { x: 0 }; return u.x; }\n",
        "const generic argument -1 is out of range for 'u64'",
    );
    h::expect_err_msg(
        "a u64 value for an i64 parameter",
        "struct I<const N: i64> { pub x: i32 }\nfn main() i32 { let i: I<18446744073709551615> = I::<5> { x: 0 }; return i.x; }\n",
        "const generic argument 18446744073709551615 is out of range for 'i64'",
    );
    h::expect_err_msg(
        "a byte parameter",
        "struct B<const N: u8> { pub x: i32 }\nfn main() i32 { let b = B::<300> { x: 0 }; return b.x; }\n",
        "const generic argument 300 is out of range for 'u8'",
    );
}

// An operand the checker widens computes at the result's width: `i32 * i64` does not truncate the
// i64 operand, and a const-generic expression with a constant past 32 bits keeps it.
fn widened_operands_compute_at_the_result_width(b: &mut h::ExitBatch) {
    b.add(
        "mixed-width arithmetic",
        M"(struct B<const M: i64> { pub x: i32 }
extend<const M: i64> B<M> { fn m(self: &Self) i64 { return M; } }
fn h<const K: i64>() i64 { let b = B::<{K + 5000000000}> { x: 1 }; return b.m(); }
fn main() i32 {
    let s: i32 = 1;
    let k: i64 = 5000000000;
    let a = s * k;
    let c: i64 = s + k;
    if a != 5000000000 || c != 5000000001 || h::<3>() != 5000000003 { return 1; }
    return 0;
}
)",
        0,
    );
}

// Const-generic values and forms carry their parameter's integer type: a form computes in its
// parameters' type (a u64 form holds u64 constants and values, an i8 one reaches -128), a narrower
// parameter widens into a wider one's position with one instance whatever spells it, and a large
// scale factor is an ordinary coefficient.
@test
fn typed_const_generic_expressions() {
    const SRC: str = M"(struct U<const N: u64> { pub x: i32 }
extend<const N: u64> U<N> { pub fn n(self: &Self) u64 { return N; } }
struct I<const N: i64> { pub x: i32 }
extend<const N: i64> I<N> { pub fn n(self: &Self) i64 { return N; } }
struct S<const N: i8> { pub x: i32 }
extend<const N: i8> S<N> { pub fn n(self: &Self) i8 { return N; } }
fn dec<const N: u64>() u64 { let u = U::<{N - 1}> { x: 0 }; return u.n(); }
fn rev<const N: u64>() u64 { let u = U::<{u64::MAX - N}> { x: 0 }; return u.n(); }
fn dbl<const N: u64>() u64 { let u = U::<{N * 2}> { x: 0 }; return u.n(); }
fn scale<const N: i64>() i64 { let i = I::<{N * 2000000000}> { x: 0 }; return i.n(); }
fn low<const N: i8>() i8 { let s = S::<{N - 1}> { x: 0 }; return s.n(); }
fn wide<const N: u8>() U<N> { return U::<N> { x: 3 }; }
fn wide1<const N: u8>() u64 { let u = U::<{N + 1}> { x: 0 }; return u.n(); }
fn main() i32 {
    if dec::<18446744073709551615>() != 18446744073709551614 || rev::<1>() != 18446744073709551614 { return 1; }
    if dbl::<4611686018427387904>() != 9223372036854775808 { return 2; }
    if scale::<3>() != 6000000000 || scale::<{-4}>() != -8000000000 { return 3; }
    if low::<{-127}>() != -128 { return 4; }
    let w: U<7> = wide::<7>();
    if w.n() != 7 || wide1::<254>() != 255 { return 5; }
    return w.x - 3;
}
)";
    h::expect_exit("typed const forms", SRC, 0);
    h::expect_c("a u64 form value past i64::MAX", SRC, "U__18446744073709551614");
    h::expect_c("2^63 from a u64 form", SRC, "U__9223372036854775808");
    h::expect_c("an i8 form at its minimum", SRC, "S__n128");
    h::expect_err_msg(
        "a wider parameter in a narrower one's position",
        "struct B<const N: u8> { pub x: i32 }\nfn f<const N: u64>() i32 { let b = B::<N> { x: 0 }; return b.x; }\nfn main() i32 { return f::<1>(); }\n",
        "mismatched types: expected 'u8', found 'u64'",
    );
    h::expect_err_msg(
        "a form's literal outside its type",
        "struct B<const N: u8> { pub x: i32 }\nfn f<const N: u8>() i32 { let b = B::<{N + 300}> { x: 0 }; return b.x; }\nfn main() i32 { return f::<1>(); }\n",
        "integer literal is out of range for 'u8'",
    );
    h::expect_err_msg(
        "a count outside the inferred parameter's type",
        "fn f<const N: u8>(a: [i32; N]) usize { return sizeof(a); }\nfn main() i32 { let a = [0; 300]; return f(a) as i32; }\n",
        "const generic argument 300 is out of range for 'u8'",
    );
    h::expect_err_msg(
        "a value outside the parameter bound through a wider position",
        "struct B<const M: u64> { pub x: i32 }\nfn g<const K: u8>(b: B<K>) i32 { return b.x; }\nfn main() i32 { let b = B::<300> { x: 0 }; return g(b); }\n",
        "const generic argument 300 is out of range for 'u8'",
    );
}

// A const-generic expression is one type however it is spelled (`{N * 2 - N}` is `N`), and every
// step of it computes in its type: between constants the checker decides the step, and a floored
// division that no instantiation makes negative, an exact division and an alias whose steps fit
// are accepted.
@test
fn const_generic_steps_at_compile_time() {
    h::expect_exit(
        "steps that fit",
        M"(struct F<const N: u64> { pub v: i32 }
extend<const N: u64> F<N> { pub fn n(self: &Self) u64 { return N; } }
struct G<const N: i64> { pub v: i32 }
extend<const N: i64> G<N> { pub fn n(self: &Self) i64 { return N; } }
type A<const M: u64> = F<{M * 2 - M}>;
fn same<const N: u64>() F<N> { let x: F<{N * 2 - N}> = F::<N> { v: 5 }; return x; }
fn half<const N: u64>() u64 { let x = F::<{N * 2 - N}> { v: 1 }; return x.n(); }
fn exact<const N: i64>() i64 { let g = G::<{(2 * N - 4) / 2}> { v: 0 }; return g.n(); }
fn floor<const N: i64>() i64 { let g = G::<{(N - 10) / 4}> { v: 0 }; return g.n(); }
fn via<const N: u64>() u64 { let a = A::<N> { v: 0 }; return a.n(); }
fn main() i32 {
    if same::<7>().n() != 7 || half::<9223372036854775807>() != 9223372036854775807 { return 1; }
    if exact::<1>() != -1 || floor::<14>() != 1 || floor::<10>() != 0 { return 2; }
    if via::<9223372036854775807>() != 9223372036854775807 { return 3; }
    let c: A<5> = F::<5> { v: 0 };
    return c.v;
}
)",
        0,
    );
    h::expect_err_msg(
        "a step between constants",
        "struct F<const N: u64> { pub v: i32 }\nconst K: u64 = 18446744073709551615;\nfn main() i32 {\n    let a = F::<{K * 2 - K}> { v: 1 };\n    return a.v;\n}\n",
        "error: const expression {K * 2} overflows u64\n--> <harness>:4:18",
    );
    h::expect_err_msg(
        "an alias step under constant arguments",
        "struct F<const N: u64> { pub v: i32 }\ntype A<const M: u64> = F<{M * 2 - M}>;\nfn main() i32 {\n    let c: A<18446744073709551615> = F::<18446744073709551615> { v: 1 };\n    return c.v;\n}\n",
        "error: const expression {M * 2} overflows u64\n--> <harness>:4:12",
    );
    h::expect_err_msg(
        "an alias scaling a divided argument",
        "struct F<const N: u64> { pub v: i32 }\ntype A<const M: u64> = F<{M * 2 + 1}>;\nfn f<const N: u64>() i32 {\n    let x = A::<{(N + 7) / 8}> { v: 1 };\n    return x.v;\n}\nfn main() i32 {\n    return f::<17>();\n}\n",
        "error: const expression {M * 2} of alias 'A' has no linear form for these arguments\n--> <harness>:4:13",
    );
}

// A local constant of a generic function may use the function's (and its extend's) parameters:
// each instance has its own value, a static datum of its own, in constant contexts too.
@test
fn local_constants_use_generic_parameters() {
    const SRC: str = M"(struct W<T> { pub x: T }
extend<T> W<T> {
    pub fn s(self: &Self) usize { const Z: usize = sizeof(T) * 2; return Z; }
}
fn g<T>() usize { const S: usize = sizeof(T); return S; }
fn h<T, const N: usize>() usize { const K: usize = sizeof(T) * N; const L: usize = 7; let r = &K; return *r + L; }
const fn c<T>() usize { const S: usize = sizeof(T) + 1; return S; }
static_assert(c::<u32>() == 5);
fn main() i32 {
    let w = W::<u16> { x: 1 };
    if g::<u8>() != 1 || g::<u64>() != 8 || h::<u32, 3>() != 19 || w.s() != 4 || c::<u8>() != 2 { return 1; }
    return 0;
}
)";
    h::expect_exit("local constants per instance", SRC, 0);
    h::expect_c("one datum per instance", SRC, "__u64 = 8;");
}

// A builtin limit or an associated constant is a const-generic argument wherever a named constant
// is, unbraced as braced: in a turbofish, in a type, as a default; it spells the instance by its
// value, so every spelling of one value is one type and one symbol, and compile time reads it too.
@test
fn qualified_const_generic_arguments() {
    const SRC: str = M"(struct Foo { pub a: i32 }
extend Foo { pub const K: i64 = 7; }
enum D { X, Y }
extend D { pub const Z: D = D::Y; }
type Big = u64;
struct U<const N: u64 = u64::MAX> { pub x: i32 }
extend<const N: u64> U<N> { pub fn n(self: &Self) u64 { return N; } }
struct I<const N: i64> { pub x: i32 }
extend<const N: i64> I<N> { pub fn n(self: &Self) i64 { return N; } }
struct F<const E: D> { pub x: i32 }
extend<const E: D> F<E> { pub fn n(self: &Self) i32 { return E as i32; } }
fn off<const N: isize>(x: isize) isize { return x + N; }
const fn top<const N: u64>() u64 { return N; }
fn main() i32 {
    let a: U<u64::MAX> = U::<{u64::MAX}> { x: 1 };
    let b: U<18446744073709551615> = a;
    let c: U = b;
    let d: U<Big::MAX> = c;
    let i = I::<i64::MIN> { x: 2 };
    let k = I::<Foo::K> { x: 3 };
    let k2 = I::<{Foo::K * 2}> { x: 4 };
    let f = F::<D::Z> { x: 5 };
    let g = F::<D::X> { x: 6 };
    static_assert(top::<u64::MAX>() == 18446744073709551615 && top::<{u8::MAX}>() == 255);
    if d.n() != 18446744073709551615 || i.n() != -9223372036854775807 - 1 || k.n() != 7 || k2.n() != 14 {
        return 1;
    }
    if f.n() != 1 || g.n() != 0 || off::<isize::MAX>(0) != 9223372036854775807 || off::<isize::MIN>(1) != -9223372036854775807 {
        return 2;
    }
    return d.x + i.x + k.x + k2.x + f.x + g.x - 21;
}
)";
    h::expect_exit("qualified const arguments", SRC, 0);
    h::expect_c("u64::MAX spells its value", SRC, "U__18446744073709551615");
    h::expect_c("i64::MIN spells its value", SRC, "I___n9223372036854775808");
    h::expect_c("an associated constant spells its value", SRC, "I___7");
}

// Compile-time evaluation reads a const-generic parameter in its declared type: signed comparisons,
// division and range patterns on i8, i64 arithmetic past 32 bits, and u64 values past i64::MAX.
fn const_generic_values_in_constant_evaluation(b: &mut h::ExitBatch) {
    b.add(
        "typed const parameters at compile time",
        M"(const fn neg<const N: i8>() bool { return N < 0; }
const fn half<const N: i8>() i8 { return N / 2; }
const fn wide<const N: i64>() i64 { return N * 2; }
const fn top<const N: u64>() bool { return N > 9223372036854775807; }
const fn cls<const N: i8>() i32 { return switch N { -128..=-1 => 1, _ => 0 }; }
static_assert(neg::<{-3}>() && !neg::<3>());
static_assert(half::<{-3}>() == -1);
static_assert(wide::<{-4000000000}>() == -8000000000);
static_assert(top::<18446744073709551615>() && !top::<5>());
static_assert(cls::<{-3}>() == 1 && cls::<3>() == 0);
fn main() i32 { return 0; }
)",
        0,
    );
}

// A constant built by a callee whose result instance is a const expression (`V<{N + M}>`) keeps the
// expression's value as its instance argument, so it is static data of its declared type.
fn constant_of_a_const_expression_instance(b: &mut h::ExitBatch) {
    b.add(
        "a V<{N + M}> constant",
        M"(struct V<const N: usize> { pub e: [i32; N] }
extend<const N: usize> V<N> {
    pub fn concat<const M: usize>(self: V<N>, b: V<M>) V<{N + M}> {
        let mut r = V::<{N + M}> { e: [0; N + M] };
        for i in 0..N { unsafe { r.e[i] = self.e[i]; } }
        for i in 0..M { unsafe { r.e[N + i] = b.e[i]; } }
        return r;
    }
}
const X: V<4> = V::<2> { e: [1, 2] }.concat(V::<2> { e: [3, 4] });
fn main() i32 { return X.e[0] + X.e[3] * 10; }
)",
        41,
    );
}

// A constant folds an operator whose extend has a parameter only its interface solves (`K`): the
// evaluator binds the extend's arguments the operator node names.
fn constant_of_a_keyed_operator(b: &mut h::ExitBatch) {
    b.add(
        "a keyed Mul in a constant",
        M"(struct M<const C: usize> { pub e: [i32; C] }
extend<const C: usize, const K: usize> M<C> as Mul<M<K>> {
    type Output = M<K>;
    pub fn mul(self: &M<C>, b: &M<K>) M<K> {
        let mut r = M::<K> { e: [0; K] };
        for k in 0..K { unsafe { r.e[k] = self.e[0] * b.e[k]; } }
        return r;
    }
}
const P: M<2> = M::<3> { e: [2, 0, 0] } * M::<2> { e: [3, 4] };
static_assert(P.e[1] == 8);
fn main() i32 { return P.e[0] + P.e[1] * 10; }
)",
        86,
    );
}

// A union member read through another scalar member of the same size reinterprets the bits in a
// constant as at run time: `f32_bits`, `f64_bits` and their inverses fold.
fn constant_union_puns(b: &mut h::ExitBatch) {
    b.add(
        "float bit puns in constants",
        M"(union P { pub u: u32, pub i: i32 }
const A: u32 = f32_bits(1.0f32);
const B: u64 = f64_bits(-0.0f64);
const C: f64 = f64_from_bits(0x3FF8000000000000);
const D: u32 = f32_bits(f32_from_bits(0x7F800001));
const E: i32 = P { u: 0xFFFFFFFF }.i;
static_assert(A == 0x3F800000 && B == 0x8000000000000000 && C == 1.5 && D == 0x7F800001 && E == -1);
fn main() i32 {
    let ok = A == f32_bits(1.0f32) && B == f64_bits(-0.0f64) && D == f32_bits(f32_from_bits(0x7F800001));
    return ok as i32 + (C * 2.0) as i32 + E;
}
)",
        3,
    );
}

// A static_assert of a generic function whose condition calls a function evaluates for each
// instance a concrete call makes, whatever else evaluated that function.
@test
fn instance_static_assert_calls_a_function() {
    let mut b = h::ExitBatch::new();
    const SRC: str = "interface Num: Copy { fn is_signed() bool; }\nextend u32 as Num { pub fn is_signed() bool { return false; } }\nextend i32 as Num { pub fn is_signed() bool { return true; } }\nfn only_signed<T: Num>(x: T) T { static_assert(T::is_signed(), \"only signed types\"); return x; }\n";
    b.add("a signed instance", format("{}fn main() i32 {{ return only_signed(3i32); }}\n", SRC).as_str(), 3);
    h::expect_build_err(
        "an unsigned instance",
        format("{}fn main() i32 {{ return only_signed(3u32) as i32; }}\n", SRC).as_str(),
        "static assertion failed: only signed types",
    );
    // std::math's `sign` takes signed inputs only (its static_assert).
    h::expect_build_err(
        "std::math sign of an unsigned value",
        "import std::math::common as *;\nfn main() i32 { return sign(3u32) as i32; }\n",
        "static assertion failed: 'sign' only accepts signed inputs",
    );
    // An instance only another generic body reaches is checked too (the instance graph's check).
    const NESTED: str = "fn outer<T: Num>(x: T) T { return only_signed(x); }\n";
    b.add("a signed nested instance", format("{}{}fn main() i32 {{ return outer(3i32); }}\n", SRC, NESTED).as_str(), 3);
    h::expect_build_err(
        "an unsigned nested instance",
        format("{}{}fn main() i32 {{ return outer(3u32) as i32; }}\n", SRC, NESTED).as_str(),
        "static assertion failed: only signed types",
    );
    // A method of a generic extend with no parameters of its own.
    h::expect_build_err(
        "a method of a generic extend",
        format(
            "{}struct W<T> {{ pub v: T }}\nextend<T: Num> W<T> {{ fn get(self: W<T>) T {{ static_assert(T::is_signed(), \"signed W\"); return self.v; }} }}\nfn main() i32 {{ let w = W::<u32> {{ v: 3 }}; return w.get() as i32; }}\n",
            SRC,
        ).as_str(),
        "static assertion failed: signed W",
    );
    // A blanket conformance's method on an instance receiver binds T to the receiver `G<u8>`, never
    // to the instance's own argument `u8`; the note names the instance with its arguments.
    const BLANKET: str = "interface Lane {}\nstruct G<T> { pub v: T, pub w: T, pub z: T }\nextend<T> G<T> as Lane {}\ninterface Twice { fn twice(self: &Self) i64; }\n";
    const CALL: str = "fn main() i32 { let g = G::<u8> { v: 1, w: 2, z: 3 }; return (g.twice() - 1) as i32; }\n";
    b.add(
        "a blanket conformance's method on an instance",
        format(
            "{}extend<T: Lane> T as Twice {{ fn twice(self: &Self) i64 {{ static_assert(sizeof(T) > 2, \"T is wide\"); return 1; }} }}\n{}",
            BLANKET,
            CALL,
        ).as_str(),
        0,
    );
    h::expect_build_err(
        "a blanket conformance's method failing for an instance",
        format(
            "{}extend<T: Lane> T as Twice {{ fn twice(self: &Self) i64 {{ static_assert(sizeof(T) > 3, \"T is wide\"); return 1; }} }}\n{}",
            BLANKET,
            CALL,
        ).as_str(),
        "in the instantiation where T = G<u8>",
    );
    b.run();
}

// A static_assert in a body that names no generic parameter must fold, as one at item level must: a
// condition over a C call is an error, never dropped.
@test
fn body_static_assert_must_fold() {
    h::expect_build_err(
        "a body static_assert over a C call",
        "extern \"C\" { @unsafe(safe) fn abs(x: i32) i32; }\nfn main() i32 {\n    static_assert(abs(-1) == 2, \"abs\");\n    return 0;\n}\n",
        "static assertion cannot be evaluated: the condition does not fold to a constant",
    );
}

// A method of a generic extend with const parameters of its own binds the extend's parameters from its
// receiver and its own from the call's: `pick::<2, 1, 2>()` on `W<i32, 3>` is I = 2, J = 1, K = 2
// under N = 3, never the call's arguments read as the extend's (T = 2, N = 1, I = 2).
@test
fn instance_static_assert_of_a_method_with_its_own_parameters() {
    const SRC: str = "struct W<T: Copy, const N: usize> { pub e: [T; N] }\nextend<T: Copy, const N: usize> W<T, N> { pub fn pick<const I: usize, const J: usize, const K: usize>(self: W<T, N>) T { static_assert(I < N && J < N && K < N, \"index past the end\"); return unsafe self.e[I]; } }\n";
    h::expect_exit(
        "indexes inside the instance",
        format("{}fn main() i32 {{ let w = W::<i32, 3> {{ e: [1, 2, 3] }}; return w.pick::<2, 1, 2>() - 3; }}\n", SRC).as_str(),
        0,
    );
    h::expect_build_err(
        "an index past the end",
        format("{}fn main() i32 {{ let w = W::<i32, 3> {{ e: [1, 2, 3] }}; return w.pick::<0, 3, 1>(); }}\n", SRC).as_str(),
        "static assertion failed: index past the end",
    );
}

// An interface-qualified call in a generic conformance (`Num::twice(self)`, `Num::make(2)`) folds in
// a constant: a `Self` argument names the implementor, else the `Self` result.
fn constant_of_an_interface_qualified_call(b: &mut h::ExitBatch) {
    b.add(
        "Num::twice(self) and Num::make(2) in constants",
        M"(interface Num: Copy { fn twice(self: Self) Self; fn make(v: i32) Self; }
extend i64 as Num { pub fn twice(self: i64) i64 { return self * 2; } pub fn make(v: i32) i64 { return v; } }
interface Q: Copy { fn q(self: Self) Self; fn m() Self; }
extend<T: Num> T as Q { pub fn q(self: T) T { return Num::twice(self); } pub fn m() T { return Num::make(5); } }
const A: i64 = 21i64.q();
const B: i64 = i64::m();
static_assert(A == 42 && B == 5);
fn main() i32 { let b = i64::m(); return (A + B + b) as i32; }
)",
        52,
    );
    // In a generic conformance, `Twice::twice(x)` on a `T` takes that conformance, as `x.twice()` does.
    b.add(
        "an interface-qualified call through the enclosing generic conformance",
        "interface Lane: Copy {}\nextend i32 as Lane {}\ninterface Twice: Copy { fn twice(self: Self) Self; fn four(self: Self) Self; }\nextend<T: Lane> T as Twice {\n    pub fn twice(self: T) T { return self; }\n    pub fn four(self: T) T { let x = self; return Twice::twice(x); }\n}\nfn main() i32 { return 3.four(); }\n",
        3,
    );
}

// An omitted field of a C object type with a layout and of a union zero-fills, in a static, a
// thread-local, a nested literal, a local and a `zeroed` static: C's static initialization.
fn omitted_c_object_and_union_fields_zero_fill(b: &mut h::ExitBatch) {
    b.add(
        "all-zero members and elements of statics",
        M"(struct In { pub arr: [i32; 2], pub n: i32 }
struct Out { pub i: In, pub r: i32 }
union U { pub i: In, pub r: i32 }
static mut G: Out = Out { i: In { arr: [0, 0], n: 0 }, r: 1 };
static mut H: [In; 3] = [In { arr: [0, 0], n: 0 }, In { arr: [0, 0], n: 2 }, In { arr: [0, 0], n: 3 }];
static mut Z: U = U { i: In { arr: [0, 0], n: 0 } };
fn main() i32 {
    return unsafe (G.r + H[0].n + H[1].n + H[2].n + G.i.n + G.i.arr[1] + Z.i.n) - 6;
}
)",
        0,
    );
    b.add(
        "zero C object",
        M"(extern "C" "pthread.h" {
    @layout(sizeof(usize), sizeof(usize))
    type pthread_t;
}
union U { pub a: u64, pub b: f64 }
struct P { pub t: pthread_t, pub u: U, pub ready: i32 }
struct Q { pub p: P, pub n: i32 }
static mut G: P = P { ready: 2 };
static mut B: Q = Q { n: 1 };
@thread_local
static mut T: P = P { ready: 3 };
static mut Z: pthread_t = unsafe zeroed::<pthread_t>();
const R: i32 = P { ready: 5 }.ready;
fn main() i32 {
    let l = P { ready: 4 };
    let w = (unsafe &Z) as *const usize;
    let s = unsafe (G.ready + B.n + B.p.ready + T.ready + G.u.a as i32 + B.p.u.a as i32 + *w as i32);
    return s + l.ready + l.u.a as i32 + R - 15;
}
)",
        0,
    );
}

// The address of a zero-length array field is its offset inside the value, as a flexible array
// member's: not the zero-size sentinel.
fn zero_length_field_address_is_its_offset(b: &mut h::ExitBatch) {
    b.add(
        "&s.tail",
        M"(struct H { pub n: u32, pub tail: [u8; 0] }
fn main() i32 {
    let mut buf: [u32; 4] = [0u32; 4];
    let h = &mut buf[0] as *mut u32 as *mut H;
    let q = (unsafe &(*h).tail) as *const u8;
    return (q as usize - h as usize) as i32 - 4;
}
)",
        0,
    );
}

// A tuple binding of an `unsafe` multi-value call, also in parentheses: the binding reads through the
// `unsafe` to the call's results, and an owned result moves into its binding without a leak.
fn multi_value_unsafe_call_binds(b: &mut h::ExitBatch) {
    b.add(
        "let (a, b) = unsafe f();",
        M"(unsafe fn two(x: i32) (String, i32) { let mut s = String::new(); s.push_str("ab"); return s, x + 1; }
fn main() i32 {
    let (s, n) = unsafe two(3);
    let (t, m) = (unsafe two(5));
    return (s.len() + t.len()) as i32 + n + m - 14;
}
)",
        0,
    );
}

// `return pair();` forwards a multi-value call's results as the return list: owned results move
// through without a leak, in a generic function and in a constant evaluation.
@test
fn multi_value_call_forwarded_by_return() {
    let mut b = h::ExitBatch::new();
    b.add(
        "return pair();",
        M"(fn pair(n: i32) (String, i32) { let mut s = String::new(); s.push_str("abc"); return s, n; }
fn forward(n: i32) (String, i32) { if n > 10 { return pair(1); } return pair(n); }
fn gen<T: Copy>(t: T) (T, T) { return t, t; }
fn gfwd<T: Copy>(t: T) (T, T) { return gen(t); }
const fn cp() (i32, i32) { return 3, 4; }
const fn cf() (i32, i32) { return cp(); }
const fn sum() i32 { let (a, b) = cf(); return a + b; }
const S: i32 = sum();
fn main() i32 {
    let (s, n) = forward(2);
    let (x, y) = gfwd(5i64);
    return s.len() as i32 + n + (x + y) as i32 + S;
}
)",
        22,
    );
    // Array results fill the carrier by copy, also when forwarded.
    b.add(
        "array results",
        M"(fn pair(k: u32) ([u32; 2], i64, [String; 1]) { let v: [u32; 2] = [1, k]; return v, 7, [String::from_str("xy")]; }
fn fwd() ([u32; 2], i64, [String; 1]) { return pair(4); }
fn main() i32 {
    let (v, n, s) = fwd();
    return (v[0] + v[1]) as i32 + n as i32 + s[0].len() as i32;
}
)",
        14,
    );
    h::expect_err_msg(
        "a forwarded result of another type",
        "fn pair() (i32, i64) { return 1, 2; }\nfn forward() (i32, i32) { return pair(); }\nfn main() i32 { let (a, b) = forward(); return a + b; }\n",
        "result 2 of the forwarded call is 'i64', the function returns 'i32' there",
    );
    b.run();
}

// A by-value builtin method called through a reference receiver (`x.wrapping_sub(1)`, `x: &u32`)
// folds in a constant, reading the referent.
fn constant_of_a_builtin_method_through_a_reference(b: &mut h::ExitBatch) {
    b.add(
        "x.wrapping_sub(1) with x: &u32",
        "fn via_ref(x: &u32) u32 { return x.wrapping_sub(1); }\nconst A: u32 = via_ref(&17);\nstatic_assert(A == 16);\nfn main() i32 { let v: u32 = 5; return (A + via_ref(&v)) as i32; }\n",
        20,
    );
}

// A generic extend's constant a parallel seed task references is defined: the shard's demand reaches
// the master (the fresh build of a program over std::math seeds in parallel).
@test
fn generic_extend_constant_from_a_parallel_seed() {
    let mut b = h::ExitBatch::new();
    b.add(
        "Quat::<f32>::LEN through std::math::all",
        "import std::math::all as *;\nfn main() i32 { return Quat::<f32>::LEN as i32 + vec3::LEN as i32; }\n",
        7,
    );
    b.run();
}

// An array argument for a generic `[]T` parameter binds T from its elements, as the array coerces to
// the slice; also through a nested generic element type.
fn array_argument_infers_a_slice_element(b: &mut h::ExitBatch) {
    b.add(
        "first(a) with a: [i32; 2] and first_w(b) with b: [W<i32>; 2]",
        M"(struct W<T> { pub x: T }
fn first<T: Copy>(v: []T) T { return v[0]; }
fn first_w<T: Copy>(v: []W<T>) T { return v[1].x; }
fn main() i32 {
    let a = [1, 2];
    let b = [W::<i32> { x: 3 }, W::<i32> { x: 4 }];
    return first(a) + first_w(b) - 5;
}
)",
        0,
    );
}

// A call through a bound in a constant runs the conformance of the receiver's own instance when
// extends differ only in const arguments (`extend M<2>` declared before `extend M<3>`), as at run
// time; for a plain and for a generic interface.
fn constant_through_a_bound_picks_the_instance_extend(b: &mut h::ExitBatch) {
    b.add(
        "M<2> and M<3> conformances",
        M"(struct M<const N: usize> { pub x: i32 }
interface Tag: Copy { fn tag(self: Self) i32; }
interface GTag<X>: Copy { fn gtag(self: Self) i32; }
fn tag<G: Tag>(g: G) i32 { return g.tag(); }
fn gtag<X, G: GTag<X>>(g: G) i32 { return g.gtag(); }
extend M<2> as Tag { pub fn tag(self: M<2>) i32 { return 2; } }
extend M<3> as Tag { pub fn tag(self: M<3>) i32 { return 3; } }
extend M<2> as GTag<i32> { pub fn gtag(self: M<2>) i32 { return 20; } }
extend M<3> as GTag<i32> { pub fn gtag(self: M<3>) i32 { return 30; } }
const A: i32 = tag(M::<3> { x: 0 });
const B: i32 = tag(M::<2> { x: 0 });
const C: i32 = gtag(M::<3> { x: 0 });
static_assert(A == 3 && B == 2 && C == 30);
@c.noinline
fn run(m: M<3>) i32 { return tag(m) + gtag(m); }
fn main() i32 { return A + B + C + run(M::<3> { x: 0 }) - 68; }
)",
        0,
    );
}

// A constant evaluates a task-reachable body whose bound operator call carries a cancellation check
// (`W`'s `mul` can accept a cancellation, which marks every interface `mul`): no task exists at
// compile time, so the probe reports none.
fn constant_through_a_cancellation_check(b: &mut h::ExitBatch) {
    b.add(
        "quad<V> under a cancellation probe",
        M"(import std::parallel::runtime as rt;
struct V { pub v: i32 }
struct W { pub v: i32 }
extend V as Mul { type Output = V; pub fn mul(self: &V, o: &V) V { return V { v: self.v * o.v }; } }
extend W as Mul {
    type Output = W;
    pub fn mul(self: &W, o: &W) W { rt::sleep_ns(1); return W { v: self.v * o.v }; }
}
fn quad<T: Mul<Output = T> + Copy>(x: T) T { let y = x * x; return y * y; }
fn checked<T>() { static_assert(quad(V { v: sizeof(T) as i32 }).v == 256); }
const S: V = quad(V { v: 2 });
fn main() i32 {
    launch || { checked::<i32>(); let _ = quad(W { v: 2 }); let _ = quad(V { v: 2 }); };
    rt::shutdown();
    return S.v - 16;
}
)",
        0,
    );
}

// An operator takes the method of its own interface's conformance when another interface of the type
// has a method of the same name: `*self + *o` inside `Other::add` runs `Add::add`, `~*self` `BitNot`'s.
fn operator_takes_its_interface_method(b: &mut h::ExitBatch) {
    b.add(
        "Add::add beside Other::add",
        M"(struct W { pub v: i32 }
interface Other {
    fn add(self: &Self, o: &Self) Self;
    fn bit_not(self: &Self) Self;
}
extend W as Add { type Output = W; pub fn add(self: &W, o: &W) W { return W { v: self.v + o.v }; } }
extend W as BitNot { type Output = W; pub fn bit_not(self: &W) W { return W { v: ~self.v }; } }
extend W as Other {
    pub fn add(self: &W, o: &W) W { return *self + *o; }
    pub fn bit_not(self: &W) W { return ~*self; }
}
fn via<T: Other>(x: T, y: T) T { return x.add(&y); }
fn inv<T: Other>(x: T) T { return x.bit_not(); }
fn main() i32 { return via(W { v: 2 }, W { v: 3 }).v + inv(W { v: 2 }).v - 2; }
)",
        0,
    );
}

// A method of `P<A, B>` calling, through a bound, the generic method of another instance of `P` with
// arguments over its own parameters: the arguments are the caller's (A = 3), not the callee's (A = 7).
fn bound_call_arguments_resolve_in_the_caller(b: &mut h::ExitBatch) {
    b.add(
        "P<3, 4>::cast::<P<7, 8>> calling P<7, 8>::from_p::<3, 4>",
        M"(struct P<const A: usize, const B: usize> { pub v: u64 }
interface Conv {
    fn from_p<const X: usize, const Y: usize>(p: P<X, Y>) Self;
    fn cast<U: Conv>(self: Self) U;
}
extend<const A: usize, const B: usize> P<A, B> as Conv {
    pub fn from_p<const A2: usize, const B2: usize>(p: P<A2, B2>) P<A, B> {
        return P::<A, B> { v: p.v + A2 as u64 * 100 + B2 as u64 * 10000 + A as u64 * 1000000 };
    }
    pub fn cast<U: Conv>(self: P<A, B>) U { return U::from_p(self); }
}
fn main() i32 {
    let y: P<7, 8> = P::<3, 4> { v: 5 }.cast::<P<7, 8>>();
    return (y.v - 7040305) as i32;
}
)",
        0,
    );
}

// A generic function passing an instance over its own parameters (`W<T, 2>`) to a bound-generic
// function folds in a constant: the argument grounds through the caller's frame.
fn constant_through_nested_generic_calls(b: &mut h::ExitBatch) {
    b.add(
        "outer<T>(W<T, 2>) calling twice<G: Dbl>",
        M"(interface Dbl: Copy { fn dbl(self: Self) Self; }
extend f32 as Dbl { pub fn dbl(self: f32) f32 { return self * 2.0; } }
struct W<T: Dbl, const N: usize> { pub e: [T; N] }
extend<T: Dbl, const N: usize> W<T, N> as Dbl {
    pub fn dbl(self: W<T, N>) W<T, N> {
        let mut r = self;
        for i in 0..N { unsafe { r.e[i] = self.e[i].dbl(); } }
        return r;
    }
}
fn twice<G: Dbl>(x: G) G { return x.dbl(); }
fn outer<T: Dbl>(x: W<T, 2>) W<T, 2> { return twice(x); }
const A: W<f32, 2> = outer(W::<f32, 2> { e: [1.0, 2.0] });
static_assert(A.e[1] == 4.0);
fn main() i32 { return A.e[1] as i32; }
)",
        4,
    );
}

// An f32 converts to every integer width saturating (`__sc_f2i_*`): NaN is 0, a value
// past either end is that end, the powers of two at the ends are exact; the run agrees with constants.
fn f32_to_integer_saturates_at_every_width(b: &mut h::ExitBatch) {
    b.add(
        "f32 as i8 .. u64",
        M"(@c.noinline
fn id(x: f32) f32 { return x; }
const NAN: f32 = 0.0f32 / 0.0f32;
static_assert(NAN as i32 == 0 && 3.0e9f32 as i32 == 2147483647 && -3.0e9f32 as i32 == -2147483648);
static_assert(300.0f32 as u8 == 255 && -1.0f32 as u8 == 0 && 255.9f32 as u8 == 255 && 2147483648.0f32 as i32 == 2147483647);
static_assert(4294967296.0f32 as u32 == 4294967295 && 1.0e20f32 as u64 == 18446744073709551615 && -129.0f32 as i8 == -128);
fn main() i32 {
    let n = id(NAN);
    let mut bad = 0;
    if n as i32 != 0 || n as u8 != 0 || n as i64 != 0 || n as u64 != 0 { bad |= 1; }
    if id(3.0e9) as i32 != 2147483647 || id(-3.0e9) as i32 != -2147483648 || id(2147483648.0) as i32 != 2147483647 { bad |= 2; }
    if id(300.0) as u8 != 255 || id(-1.0) as u8 != 0 || id(255.9) as u8 != 255 || id(-0.9) as u8 != 0 { bad |= 4; }
    if id(4294967296.0) as u32 != 4294967295 || id(4294967040.0) as u32 != 4294967040 || id(1.0e20) as u64 != 18446744073709551615 { bad |= 8; }
    if id(-129.0) as i8 != -128 || id(127.5) as i8 != 127 || id(-32769.0) as i16 != -32768 || id(65535.5) as u16 != 65535 { bad |= 16; }
    if id(-4611686018427387904.0) as i64 != -4611686018427387904 || id(1.0e19) as i64 != 9223372036854775807 { bad |= 32; }
    return bad;
}
)",
        0,
    );
}

// `to_int_unchecked` truncates as `as` does for every value that fits, as one C cast; it needs
// `unsafe`, and in a constant NaN or a value that does not fit is an error.
@test
fn float_to_int_unchecked() {
    h::expect_exit(
        "in-range values at run time and in constants",
        M"(@c.noinline
fn id(x: f32) f32 { return x; }
@c.noinline
fn idd(x: f64) f64 { return x; }
const C: u8 = unsafe 200.9f32.to_int_unchecked::<u8>();
const D: i64 = unsafe (-3.7f64).to_int_unchecked::<i64>();
static_assert(C == 200 && D == -3);
fn main() i32 {
    let mut bad = 0;
    if unsafe id(255.5).to_int_unchecked::<u8>() != 255 || unsafe id(-128.9).to_int_unchecked::<i8>() != -128 { bad |= 1; }
    if unsafe id(4294967040.0).to_int_unchecked::<u32>() != 4294967040 || unsafe id(-0.9).to_int_unchecked::<u16>() != 0 { bad |= 2; }
    if unsafe idd(-9.2e18).to_int_unchecked::<i64>() != -9200000000000000000 || unsafe idd(1.8e19).to_int_unchecked::<u64>() != 18000000000000000000 { bad |= 4; }
    return bad;
}
)",
        0,
    );
    h::expect_build_err(
        "a call outside unsafe",
        "fn main() i32 { let x: f32 = 3.5; return x.to_int_unchecked::<i32>(); }\n",
        "calling an unsafe function requires an 'unsafe' block",
    );
    h::expect_build_err(
        "a constant out of range",
        "const E: u8 = unsafe 256.0f32.to_int_unchecked::<u8>();\nfn main() i32 { return E as i32; }\n",
        "`to_int_unchecked` of NaN or of a value outside the integer type",
    );
    h::expect_build_err(
        "a NaN constant",
        "const F: i32 = unsafe (0.0f64 / 0.0).to_int_unchecked::<i32>();\nfn main() i32 { return F; }\n",
        "`to_int_unchecked` of NaN or of a value outside the integer type",
    );
}

// A default method a generic conformance inherits folds in a constant, its `Self` the instance.
fn constant_of_an_inherited_default_on_an_instance(b: &mut h::ExitBatch) {
    b.add(
        "an inherited default on W<i32> in a constant",
        M"(interface Len: Copy { fn len2(self: Self) f64; fn len(self: Self) f64 { return self.len2() + 1.0; } }
struct W<T> { pub x: f64, pub t: T }
extend<T: Copy> W<T> as Len { pub fn len2(self: W<T>) f64 { return self.x; } }
const B: f64 = W::<i32> { x: 4.0, t: 0 }.len();
static_assert(B == 5.0);
fn main() i32 { return B as i32; }
)",
        5,
    );
}

// The same default called on `W<N>` inside a generic function folds in a constant: `Self` binds to
// the receiver grounded through the caller's frame (`W<3>`), not to `W<N>`, whose `N` the callee's
// frame does not bind.
fn constant_of_an_inherited_default_in_a_generic_function(b: &mut h::ExitBatch) {
    b.add(
        "an inherited default on W<N> in a generic function, in a constant",
        M"(interface Measure: Copy { fn base(self: Self) f64; fn twice(self: Self) f64 { return self.base() * 2.0; } }
struct W<const N: usize> { pub v: f64 }
extend<const N: usize> W<N> as Measure { pub fn base(self: W<N>) f64 { return self.v + N as f64; } }
fn twice_generic<const N: usize>(w: W<N>) f64 { return w.twice(); }
const G: f64 = twice_generic(W::<3> { v: 1.5 });
static_assert(G == 9.0);
fn main() i32 { return G as i32 + twice_generic(W::<2> { v: 0.5 }) as i32; }
)",
        14,
    );
}

// `assert` fails through one call of the runtime's cold, out-of-line `__sc_assert_fail`: the caller
// keeps no printing code, so a helper that asserts inlines as one that panics does, and the report
// keeps its form (the expression, the message, the location).
@test
fn assert_fails_out_of_line() {
    let src = M"(fn check(a: f32, m: bool) {
    if m {
        assert(a >= 0.0, "below 0");
    } else {
        assert(a <= 1.0);
    }
}
fn main(args: Vector<str>) i32 {
    let m = args.len() > 1 && args[1] == "m";
    let a: f32 = if m { -1.0; } else if args.len() > 1 { 2.0; } else { 0.5; };
    check(a, m);
    return 0;
}
)";
    let c = h::compile_c(src);
    assert(c.ok(), "the program compiles");
    assert(
        c.code_has("__sc_assert_fail(\"assertion failed: `a >= 0.0`: \", __scm.ptr, __scm.len, \"\\n  at "),
        "the message form",
    );
    assert(c.code_has("__sc_assert_fail(\"assertion failed: `a <= 1.0`\", 0, 0, \"\\n  at "), "the plain form");
    assert(!c.code_has("fprintf(stderr, \"assertion failed"), "no printing code in the caller");
    let b = h::diff_build(src, []);
    assert(b.built, b.diag.as_str());
    assert_eq(h::diff_run(&b, "").exit, 0);
    let rm = h::diff_run(&b, "m");
    assert(
        rm.exit != 0 && rm.err.contains("assertion failed: `a >= 0.0`: below 0\n  at ") && rm.err.contains(
            "main.spc:3\n",
        ),
        rm.err.as_str(),
    );
    let rp = h::diff_run(&b, "p");
    assert(
        rp.exit != 0 && rp.err.contains("assertion failed: `a <= 1.0`\n  at ") && rp.err.contains("main.spc:5\n"),
        rp.err.as_str(),
    );
}

// `*b` on a `mut` Box binding is a place through `deref_mut`: assignable, indexable for a write, and a
// `&mut` source, also nested (`(*m)[i][j]` of a boxed std::math matrix). On an immutable binding each
// stays an error.
@test
fn box_deref_place_writes() {
    h::expect_exit(
        "writes through *b",
        M"(import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
fn main() i32 {
    let mut b = Box::new([1, 2, 3, 4]);
    let r = &mut *b;
    r[1] = 7;
    (*b)[3] = 9;
    let ok1 = (*b)[1] == 7 && (*b)[3] == 9;
    *b = [5, 6, 7, 8];
    let mut m = Box::new(Mat::<f64, 256, 256>::zero());
    for i in 0usize..256 {
        (*m)[i][i] = 1.0;
    }
    (*m)[3][7] = 2.5;
    let ok2 = (*m)[3][7] == 2.5 && (*m)[255][255] == 1.0 && (*m)[1][0] == 0.0;
    return if ok1 && ok2 && (*b)[2] == 7 { 0; } else { 1; };
}
)",
        0,
    );
    h::expect_build_err(
        "an immutable binding",
        "fn main() i32 { let b = Box::new([1, 2]); *b = [3, 4]; return (*b)[0]; }\n",
        "cannot assign to this expression",
    );
    h::expect_build_err(
        "&mut of an immutable binding",
        "fn main() i32 { let b = Box::new([1, 2]); let r = &mut *b; r[0] = 5; return (*b)[0]; }\n",
        "cannot take '&mut' of an immutable binding",
    );
}

// Constant evaluation reclaims a call's objects (its frame, argument copies and cells) when nothing older
// holds one: a 32x32 product makes about 65 000 scalar calls through `Scalar` and stays within the
// memory budget; a callee that grows a vector its caller holds keeps what it stores.
@test
fn constant_evaluation_reclaims_dead_call_objects() {
    let mut b = h::ExitBatch::new();
    b.add(
        "a 32x32 product and 20 000 pushes through a callee in constants",
        M"(import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
struct H {
    pub v: Vector<i64>,
    b.run();
}
fn put(h: &mut H, n: i64) i64 {
    h.v.push(n);
    return n;
}
fn pushes() i64 {
    let mut h = H { v: Vector::<i64>::new() };
    let mut s: i64 = 0;
    for i in 0..20000i64 {
        s += put(&mut h, i);
    }
    let mut t: i64 = 0;
    for i in 0..h.v.len() {
        t += h.v[i];
    }
    return s - t + h.v.len() as i64;
}
const P: Mat<f32, 32, 32> = Mat::<f32, 32, 32>::identity() * Mat::<f32, 32, 32>::identity();
const N: i64 = pushes();
static_assert(N == 20000);
fn main() i32 {
    return P[31][31] as i32 + P[0][1] as i32 + (N - 20000) as i32 - 1;
}
)",
        0,
    );
}

// Two conformances apply to `W<bool>` structurally (`W<T: Num>` and `W<bool>`) and only the bounds tell
// them apart: the bound check, the method call, a bound call, `dyn`, an inherited default and the
// constant evaluator take `W<bool>`'s in either declaration order.
fn conformance_choice_ignores_declaration_order(b: &mut h::ExitBatch) {
    let head = "interface Num: Copy { fn val(self: Self) u64; }\nextend i32 as Num { pub fn val(self: i32) u64 { return self as u64; } }\ninterface Key { fn key(self: &Self) u64; fn twice(self: &Self) u64 { return self.key() * 2; } }\nstruct W<T: Copy> { pub e: T }\n";
    let generic = "extend<T: Num> W<T> as Key { pub fn key(self: &W<T>) u64 { return self.e.val(); } }\n";
    let concrete = "extend W<bool> as Key { pub fn key(self: &W<bool>) u64 { return self.e as u64 + 10; } }\n";
    let tail = M"(fn through<K: Key>(k: &K) u64 { return k.key(); }
const A: u64 = through(&W::<bool> { e: true });
const B: u64 = W::<bool> { e: true }.key();
const C: u64 = W::<bool> { e: true }.twice();
static_assert(A == 11 && B == 11 && C == 22);
fn main() i32 {
    let a = W::<i32> { e: 7 };
    let b = W::<bool> { e: true };
    let d: &dyn Key = &b;
    let ok = through(&a) == 7 && through(&b) == 11 && b.key() == 11 && d.key() == 11 && b.twice() == 22 && a.twice() == 14;
    return if ok { 0; } else { 1; };
}
)";
    b.add("the generic conformance first", format("{}{}{}{}", head, generic, concrete, tail).as_str(), 0);
    b.add("the concrete conformance first", format("{}{}{}{}", head, concrete, generic, tail).as_str(), 0);
}

// `M::<4>::from(m)`: the qualifying instance, not the first argument, binds the extend of an
// associated function with its own const parameter, in a constant and at run time, whatever its
// result type.
fn qualified_associated_calls_of_generic_extends(b: &mut h::ExitBatch) {
    b.add(
        "M::<4>::from(M::<2>) and M::<4>::cnt(M::<2>)",
        M"(struct M<const N: usize> { pub e: [i32; N] }
extend<const N: usize> M<N> {
    pub fn from<const N2: usize>(m: M<N2>) M<N> {
        let mut r = M::<N> { e: [7; N] };
        for i in 0..N { if i < N2 { unsafe { r.e[i] = m.e[i]; } } }
        return r;
    }
    pub fn cnt<const N2: usize>(m: M<N2>) usize { return N * 10 + N2 + (m.e[0] as usize) * 0; }
}
const X: M<4> = M::<4>::from(M::<2> { e: [1, 2] });
const C: usize = M::<4>::cnt(M::<2> { e: [1, 2] });
static_assert(X.e[1] == 2 && X.e[3] == 7 && C == 42);
fn main() i32 {
    let y = M::<3>::from(M::<2> { e: [1, 2] });
    return X.e[3] + y.e[2] * 10 + (M::<4>::cnt(M::<2> { e: [1, 2] }) - C) as i32;
}
)",
        77,
    );
}

// An associated type read through a bound (`G::B`) takes the type's own conformance over a generic
// one declared first (`extend<T: Num> T as I<T>`), which applies only where no own one does.
fn projection_prefers_the_own_conformance(b: &mut h::ExitBatch) {
    b.add(
        "G::B with a blanket conformance declared first",
        M"(interface Num: Copy {}
extend i32 as Num {}
struct W { pub v: i64 }
interface I<E>: Copy { type B; fn get(self: Self, e: E) Self::B; }
extend<T: Num> T as I<T> { type B = bool; pub fn get(self: T, e: T) bool { return true; } }
extend W as I<W> { type B = i64; pub fn get(self: W, e: W) i64 { return self.v + e.v; } }
fn pick<E, G: I<E>>(x: G, e: E) G::B { return x.get(e); }
fn main() i32 {
    let w = W { v: 20 };
    let r: i64 = pick(w, w);
    return r as i32 + pick(1, 2) as i32;
}
)",
        41,
    );
    // A generic conformance's method matches a signature naming `&mut Self::Out` through its own
    // `type Out`.
    b.add(
        "&mut Self::Out in a generic conformance",
        "interface Shape { type Out; fn set(o: &mut Self::Out, v: i32); }\ninterface Num: Copy {}\nextend i64 as Num {}\nextend<T: Num> T as Shape { type Out = i32; pub fn set(o: &mut i32, v: i32) { *o = v; } }\nfn put<S: Shape>(o: &mut S::Out, v: i32) { S::set(o, v); }\nfn main() i32 { let mut x: i32 = 1; put::<i64>(&mut x, 5); return x; }\n",
        5,
    );
}

// A range pattern whose bound is past i64 (a u64 value above i64::MAX) is no compiler crash.
fn u64_range_pattern_bounds_past_i64(b: &mut h::ExitBatch) {
    b.add(
        "u64 range bounds",
        M"(const fn hi(n: u64) i32 { return switch n { 9223372036854775808..=18446744073709551615 => 1, _ => 0 }; }
static_assert(hi(18446744073709551615) == 1 && hi(5) == 0);
fn main() i32 { return 0; }
)",
        0,
    );
}

// A call returning an array, viewed as a slice by its context, keeps its array result: the view
// borrows the call's temporary, which lives (and frees its elements) to the end of the block.
fn call_results_viewed_as_slices(b: &mut h::ExitBatch) {
    b.add(
        "array call results as slices",
        M"(fn mk() [i32; 2] { return [3, 4]; }
fn gen<T: Default + Copy>() [T; 2] { return [T::default(); 2]; }
fn mks() [String; 2] { return [String::from_str("a heap string longer than twenty-three bytes"), String::new()]; }
fn main(args: Vector<str>) i32 {
    let v: []i32 = mk();
    let w: []i64;
    w = gen::<i64>();
    let s: []String = mks();
    return v[1] + w.len() as i32 + s[0].len() as i32 - 50 + args.len() as i32 - 1;
}
)",
        0,
    );
}

// A Box made with a non-Global allocator erases to Box<dyn I>: the table frees the payload through
// that allocator, rebuilt by its Default, never through Global.
fn boxed_dyn_frees_through_its_allocator(b: &mut h::ExitBatch) {
    b.add(
        "Box<T, A> as Box<dyn I>",
        M"(extern "C" { fn malloc(n: usize) *mut void; fn realloc(p: *mut void, n: usize) *mut void; fn free(p: *mut void) void; }
static mut LIVE: i32 = 0;
static mut DEFAULTS: i32 = 0;
struct Tagged { pub tag: u64 }
extend Tagged as Copy {}
extend Tagged as Allocator {
    unsafe fn alloc(self: &mut Tagged, n: usize, align: usize) *mut void { unsafe { LIVE += 1; } return unsafe malloc(n); }
    unsafe fn realloc(self: &mut Tagged, p: *mut void, old_n: usize, n: usize, align: usize) *mut void { return unsafe realloc(p, n); }
    unsafe fn dealloc(self: &mut Tagged, p: *mut void, n: usize, align: usize) { if self.tag == 7 { unsafe { LIVE -= 1; } } unsafe free(p); }
}
extend Tagged as Default { fn default() Tagged { unsafe { DEFAULTS += 1; } return Tagged { tag: 7 }; } }
interface Shape { fn area(self: &Self) i32; }
struct Sq { pub s: i32, pub name: String }
extend Sq as Shape { fn area(self: &Sq) i32 { return self.s * self.s + self.name.len() as i32; } }
fn main() i32 {
    let mut a = 0;
    {
        let b = Box::<Sq, Tagged>::new_in(Tagged { tag: 7 }, Sq { s: 3, name: String::from_str("a heap string longer than twenty-three bytes") });
        let d: Box<dyn Shape> = b;
        a = d.area();
        let c: Box<dyn Shape> = Box::new(Sq { s: 1, name: String::new() });
        a += c.area();
    }
    return a - 54 + unsafe LIVE * 100 + (unsafe DEFAULTS - 1) * 10;
}
)",
        0,
    );
}

// Several conformances of one generic interface: every erasure runs the conformance whose arguments
// are the dyn type's (`&dyn`, `&mut dyn`, `Box<dyn>`, a parameter, a result, a struct field, container
// elements, const arguments, a generic target, a coercion inside a generic function), including a
// default method one conformance inherits while the other defines it.
fn dyn_runs_the_conformance_with_its_arguments(b: &mut h::ExitBatch) {
    b.add(
        "dyn over several conformances of one generic interface",
        M"(interface I<T> {
    fn put(self: &Self, x: T) i32;
    fn tag(self: &Self) i32 { return 7; }
}
interface M<T> { fn bump(self: &mut Self, x: T) i32; }
interface C<const N: usize> { fn n(self: &Self) usize; }
struct P { pub a: i32 }
extend P as I<i32> { pub fn put(self: &P, x: i32) i32 { return x + self.a; } }
extend P as I<bool> {
    pub fn put(self: &P, x: bool) i32 { if x { return 100; } return 200; }
    pub fn tag(self: &P) i32 { return 8; }
}
extend P as M<i32> { pub fn bump(self: &mut P, x: i32) i32 { self.a = self.a + x; return self.a; } }
extend P as M<bool> { pub fn bump(self: &mut P, x: bool) i32 { if x { self.a = self.a * 2; } return self.a; } }
extend P as C<2> { pub fn n(self: &P) usize { return 2; } }
extend P as C<3> { pub fn n(self: &P) usize { return 3; } }
struct W<T> { pub v: T }
extend<T> W<T> as I<T> { pub fn put(self: &W<T>, x: T) i32 { return 50; } }
extend W<i32> as I<bool> { pub fn put(self: &W<i32>, x: bool) i32 { return 60; } }
struct Holder<'a> { pub d: &'a dyn I<bool> }
fn call_b(d: &dyn I<bool>) i32 { return d.put(false); }
fn ret_i(p: &P) &dyn I<i32> { return p; }
fn gen<T>(w: &W<T>, x: T) i32 {
    let d: &dyn I<T> = w;
    return d.put(x);
}
fn main() i32 {
    let mut p = P { a: 1 };
    let d: &dyn I<bool> = &p;
    let e: &dyn I<i32> = &p;
    if d.put(true) != 100 || e.put(10) != 11 { return 1; }
    if d.tag() != 8 || e.tag() != 7 { return 2; }
    if call_b(&p) != 200 || ret_i(&p).put(5) != 6 { return 3; }
    let h = Holder { d: &p };
    if h.d.put(true) != 100 { return 4; }
    let c2: &dyn C<2> = &p;
    let c3: &dyn C<3> = &p;
    if c2.n() != 2 || c3.n() != 3 { return 5; }
    let bx: Box<dyn I<bool>> = Box::new(P { a: 4 });
    if bx.put(false) != 200 || bx.tag() != 8 { return 6; }
    let mut v = Vector::<Box<dyn I<i32>>>::new();
    v.push(Box::new(P { a: 5 }));
    v.push(Box::new(W::<i32> { v: 1 }));
    if (*v.at(0)).put(1) != 6 || (*v.at(1)).put(1) != 50 { return 7; }
    let w = W::<i32> { v: 3 };
    let wb: &dyn I<bool> = &w;
    if wb.put(true) != 60 || gen(&w, 4) != 50 { return 8; }
    {
        let m: &mut dyn M<bool> = &mut p;
        if m.bump(true) != 2 { return 9; }
    }
    let m2: &mut dyn M<i32> = &mut p;
    if m2.bump(3) != 5 { return 10; }
    return 0;
}
)",
        0,
    );
}

// One source type erased both borrowed and owned to one interface: each erasure has its own table,
// so the owned one frees its payload whichever erasure the emitter met first.
fn borrowed_and_owned_erasures_of_one_pair(b: &mut h::ExitBatch) {
    b.add(
        "&dyn then Box<dyn> of one type",
        M"(interface K { fn k(self: &Self) i32; }
struct P { pub a: i32, pub s: String }
extend P as K { pub fn k(self: &P) i32 { return self.a + self.s.len() as i32; } }
fn main() i32 {
    let p = P { a: 1, s: String::new() };
    let r: &dyn K = &p;
    let b: Box<dyn K> = Box::new(P { a: 2, s: String::from_str("a heap string longer than twenty-three bytes") });
    return r.k() + b.k() - 47;
}
)",
        0,
    );
}

// Method calls on several conformances of one generic interface pick the candidate the argument's
// type selects, also when that type is known only once the argument is checked.
fn conformance_selected_by_checked_argument(b: &mut h::ExitBatch) {
    exit_case(
        b,
        "an argument typed by checking it selects the conformance",
        M"(interface I<T> { fn put(self: &Self, x: T) i32; }
struct P { pub a: i32, pub b: bool }
extend P as I<i32> { pub fn put(self: &P, x: i32) i32 { return x + self.a; } }
extend P as I<bool> { pub fn put(self: &P, x: bool) i32 { if x { return 100; } return 200; } }
extend P { pub fn me(self: &P) &P { return self; } }
fn main() i32 {
    let p = P { a: 1, b: false };
    let r = p.put(p.a) + p.put(true) * 10 + p.me().put(p.b) * 100 + p.put(p.me().a + 1) * 10000;
    if r == 2 + 1000 + 20000 + 30000 {
        unsafe exit(0);
    }
    return 1;
}
)",
        0,
    );
}

// A call without arguments on several conformances that each define the method runs the one whose
// result is the expected type: a method call, a path call, an associated function, through auto-deref,
// on a builtin receiver, through a type parameter's bounds, through dyn, and a function value by its
// expected function type.
fn conformance_selected_by_expected_result(b: &mut h::ExitBatch) {
    exit_case(
        b,
        "the expected result selects among the receiver's own methods",
        M"(interface Conv<T> { fn conv(self: &Self) T; fn mk() T; }
struct X { pub v: i32 }
extend X as Conv<i32> { pub fn conv(self: &X) i32 { return self.v; } pub fn mk() i32 { return 2; } }
extend X as Conv<bool> { pub fn conv(self: &X) bool { return self.v == 1; } pub fn mk() bool { return true; } }
struct W { pub x: X }
extend W as Deref<X> { pub fn deref(self: &W) &X { return &self.x; } }
extend i32 as Conv<i64> { pub fn conv(self: &i32) i64 { return 30; } pub fn mk() i64 { return 40; } }
extend i32 as Conv<u8> { pub fn conv(self: &i32) u8 { return 50; } pub fn mk() u8 { return 60; } }
fn g<U: Conv<i32> + Conv<bool>>(u: &U) i32 {
    let a: i32 = u.conv();
    let b: bool = u.conv();
    let c: i32 = U::mk();
    let d: bool = U::conv(u);
    return a + c + if b && d { 100; } else { 0; };
}
fn h(d: &dyn Conv<bool>) bool { return d.conv(); }
fn main() i32 {
    let x = X { v: 1 };
    let w = W { x: X { v: 3 } };
    let n: i32 = 7;
    let a: i32 = x.conv();
    let b: bool = x.conv();
    let c: i32 = X::conv(&w.x);
    let m: i32 = X::mk();
    let mb: bool = X::mk();
    let wa: i32 = w.conv();
    let wb: bool = w.conv();
    let na: i64 = n.conv();
    let nb: u8 = n.conv();
    let nm: u8 = i32::mk();
    let f: fn(&X) bool = X::conv;
    let flags = b && mb && !wb && f(&x) && h(&x);
    if a == 1 && c == 3 && m == 2 && wa == 3 && na == 30 && nb == 50 && nm == 60 && flags && g(&x) == 103 {
        unsafe exit(0);
    }
    return 1;
}
)",
        0,
    );
    exit_case(
        b,
        "the arguments select among a type parameter's bounds",
        M"(interface Put<T> { fn put(self: &Self, x: T) i32; }
struct P { pub a: i32 }
extend P as Put<i32> { pub fn put(self: &P, x: i32) i32 { return x; } }
extend P as Put<bool> { pub fn put(self: &P, x: bool) i32 { return 100; } }
fn g<U: Put<i32> + Put<bool>>(u: &U) i32 { return u.put(3) + u.put(true) + U::put(u, false); }
fn main() i32 {
    let p = P { a: 1 };
    if g(&p) == 203 {
        unsafe exit(0);
    }
    return 1;
}
)",
        0,
    );
}

// A call through a bound on a generic interface runs the conformance with the bound's arguments, in
// every instance and at compile time: its own method or the default it inherits, through `where`
// clauses, superinterfaces, extend parameters, an interface's own default bodies and associated
// functions (`T::mk(true)`, `T::from(x)`).
fn bound_calls_run_the_conformance_with_its_arguments(b: &mut h::ExitBatch) {
    b.add(
        "bound dispatch over several conformances of one generic interface",
        M"(interface I<A> {
    fn put(self: &Self, a: A) i32;
    fn tag(self: &Self) i32 { return 87; }
    fn twice(self: &Self, a: A) i32 { return self.put(a) * 2 + self.tag(); }
}
interface J<B>: I<B> { fn j(self: &Self) i32; }
interface Mk<A> { fn mk(a: A) Self; }
struct P { pub x: i32 }
extend P as I<i32> {
    pub const fn put(self: &P, a: i32) i32 { return a + self.x; }
}
extend P as I<bool> {
    pub const fn put(self: &P, a: bool) i32 { if a { return 10; } return 20; }
    pub const fn tag(self: &P) i32 { return 88; }
}
extend P as J<bool> { pub fn j(self: &P) i32 { return 5; } }
extend P as Mk<i32> { pub fn mk(a: i32) P { return P { x: a }; } }
extend P as Mk<bool> { pub fn mk(a: bool) P { if a { return P { x: 100 }; } return P { x: 200 }; } }
extend P as From<i64> { pub fn from(v: i64) P { return P { x: v as i32 }; } }
const fn gb<T: I<bool>>(t: &T) i32 { return t.put(true); }
const fn gi<T: I<i32>>(t: &T) i32 { return t.tag(); }
const fn gw<T>(t: &T) i32 where T: I<bool> { return t.twice(false); }
const fn gv<T: I<i32>>(t: &T) i32 { return t.twice(5); }
fn ga<A, T: I<A>>(t: &T, a: A) i32 { return t.put(a); }
fn gs<T: J<bool>>(t: &T) i32 { return t.put(false) + t.j() + t.tag(); }
fn gm<T: Mk<bool>>() T { return T::mk(true); }
fn conv<T: From<i64>>(v: i64) T { return T::from(v); }
fn fwd<U: I<bool>>(u: &U) i32 { return gb(u); }
struct W<T> { pub t: T }
extend<T: I<bool>> W<T> { pub fn run(self: &W<T>) i32 { return self.t.put(false); } }
struct V<T: I<i32>> { pub t: T }
extend<T: I<i32>> V<T> { pub fn run(self: &V<T>) i32 { return self.t.twice(3); } }
const P0: P = P { x: 1 };
const CB: i32 = gb(&P0);
const CI: i32 = gi(&P0);
const CW: i32 = gw(&P0);
const CV: i32 = gv(&P0);
fn main() i32 {
    let p = P { x: 1 };
    if gb(&p) != 10 || gi(&p) != 87 || gw(&p) != 128 || gv(&p) != 99 { return 1; }
    if CB != 10 || CI != 87 || CW != 128 || CV != 99 { return 2; }
    if ga(&p, 4) != 5 || ga(&p, true) != 10 || gs(&p) != 113 || fwd(&p) != 10 { return 3; }
    if gm::<P>().x != 100 { return 4; }
    let c: P = conv(7);
    if c.x != 7 { return 5; }
    let w = W { t: P { x: 2 } };
    let v = V { t: P { x: 2 } };
    if w.run() != 20 || v.run() != 97 { return 6; }
    let d: &dyn I<bool> = &p;
    let e: &dyn I<i32> = &p;
    if d.twice(true) != 108 || e.twice(1) != 91 { return 7; }
    return 0;
}
)",
        0,
    );
}

// Function pointers and `dyn fn` values with several results return the result pack the functions
// with those results return: calls through them, fields and containers of them, results of functions
// and closures (capturing ones through `dyn fn` and bounds) coerced to them, owning results included.
fn several_result_fn_values(b: &mut h::ExitBatch) {
    b.add(
        "fn pointers and dyn fn values with several results",
        M"(fn two(x: i32) (i32, i32) { return x, x + 1; }
fn swap(x: i32) (i32, i32) { return x + 1, x; }
fn named(n: i32) (String, i32) {
    let mut s = String::new();
    for _ in 0..n { s.push_str("ab"); }
    return s, n;
}
fn gen<T: Copy>(x: T) (T, T) { return x, x; }
struct Z {}
fn unit(x: i32) (i32, Z, i32) { return x, Z {}, x * 2; }
struct H { pub f: fn(i32) (i32, i32) }
fn apply(f: fn(i32) (i32, i32), x: i32) i32 {
    let (a, b) = f(x);
    return a * 10 + b;
}
fn pick_fn(first: bool) fn(i32) (i32, i32) {
    if first { return two; }
    return swap;
}
fn call_dyn(d: &dyn fn(i32) (i32, i32), x: i32) i32 {
    let (a, b) = d(x);
    return a * 10 + b;
}
fn ap<F: fn(i32) (i32, i32)>(f: F) i32 {
    let (a, b) = f(2);
    return a * 10 + b;
}
fn ap_move<F: fn move(i32) (String, i32)>(f: F) i32 {
    let (s, n) = f(2);
    return s.len() as i32 + n;
}
fn main() i32 {
    let f: fn(i32) (i32, i32) = two;
    let (a, b) = f(3);
    if a * 10 + b != 34 || apply(swap, 3) != 43 || apply(pick_fn(true), 1) != 12 { return 1; }
    let h = H { f: swap };
    let (c, d) = (h.f)(5);
    if c * 10 + d != 65 { return 2; }
    let mut v = Vector::<fn(i32) (i32, i32)>::new();
    v.push(two);
    v.push(swap);
    let mut s = 0;
    for i in 0..v.len() {
        let g = *v.at(i);
        let (x, y) = g(2);
        s = s * 100 + x * 10 + y;
    }
    if s != 2332 { return 3; }
    let cl: fn(i32) (i32, i32) = fn(x: i32) (i32, i32) { return x * 2, x * 3; };
    if apply(cl, 2) != 46 { return 4; }
    let k = 7;
    let bx: Box<dyn fn(i32) (i32, i32)> = Box::new(fn(x: i32) (i32, i32) { return x + k, x - k; });
    let (p, q) = bx(10);
    if p * 100 + q != 1703 || call_dyn(&two, 4) != 45 { return 5; }
    let r: &dyn fn(i32) (i32, i32) = &swap;
    if call_dyn(r, 4) != 54 { return 6; }
    let nf: fn(i32) (String, i32) = named;
    let (st, n) = nf(3);
    if st.len() as i32 + n != 9 { return 7; }
    let gf: fn(i64) (i64, i64) = gen::<i64>;
    let (g1, g2) = gf(8);
    if g1 + g2 != 16 { return 8; }
    let owned = String::from_str("owned capture that is long enough to live on the heap");
    let bo: Box<dyn fn(i32) (String, i32)> = Box::new(move fn(x: i32) (String, i32) { return owned.clone(), x; });
    let (os, on) = bo(1);
    if os.len() as i32 + on != 54 { return 9; }
    let c2 = fn(x: i32) (i32, i32) { return x + k, k; };
    let (e1, e2) = c2(1);
    if e1 != 8 || e2 != 7 || ap(two) != 23 || ap(c2) != 97 { return 10; }
    let big = String::from_str("a heap string longer than twenty-three bytes");
    if ap_move(move fn(x: i32) (String, i32) { return big.clone(), x; }) != 46 { return 11; }
    let uf: fn(i32) (i32, Z, i32) = unit;
    let (u1, _, u2) = uf(4);
    if u1 + u2 != 12 { return 12; }
    return 0;
}
)",
        0,
    );
}

// A fixed array result returns in its carrier struct (C returns no array): function pointers, closures,
// `dyn fn` values and dyn interface methods with one spell the carrier the functions return.
fn array_result_fn_values(b: &mut h::ExitBatch) {
    b.add(
        "fn values and dyn methods with a fixed array result",
        M"(fn arr(x: i32) [i32; 2] {
    return [x, x + 1];
}
fn arr3(x: i64) [i64; 3] {
    return [x, x, x];
}
interface G {
    fn get(self: &Self) [i32; 2];
}
struct P {
    pub a: i32,
}
extend P as G {
    pub fn get(self: &P) [i32; 2] {
        return [self.a, self.a * 3];
    }
}
fn via(f: fn(i32) [i32; 2]) i32 {
    let a = f(3);
    return a[0] + a[1];
}
fn main() i32 {
    let f: fn(i32) [i32; 2] = arr;
    let a = f(3);
    if a[0] + a[1] != 7 || via(arr) != 7 {
        return 1;
    }
    let k = 1;
    let c = fn(x: i32) [i32; 2] { return [x, x + k]; };
    let b = c(3);
    if b[0] + b[1] != 7 || via(fn(x: i32) [i32; 2] { return [x, x]; }) != 6 {
        return 2;
    }
    let bx: Box<dyn fn(i32) [i32; 2]> = Box::new(fn(x: i32) [i32; 2] { return [x + k, x]; });
    let d = bx(1);
    if d[0] + d[1] != 3 {
        return 3;
    }
    let p = P { a: 2 };
    let g: &dyn G = &p;
    let e = g.get();
    if e[0] + e[1] != 8 {
        return 4;
    }
    let mut w: [i64; 3] = [0, 0, 0];
    let h: fn(i64) [i64; 3] = arr3;
    w = h(5);
    if w[2] != 5 {
        return 5;
    }
    return 0;
}
)",
        0,
    );
}

// Operators through bounds dispatch to the conformance the bound's arguments select, in every
// instance and at compile time: binary, compound, unary, shift and index forms; `T::Output` and
// `Self::Output` resolve per instance (a generic extend's `Vector<T>`, a `String`, a fixed array
// of them in a default body, through a superinterface), and a binding (`Output = T`) makes it `T`.
fn operators_and_associated_types_through_bounds(b: &mut h::ExitBatch) {
    b.add(
        "operators and associated types through bounds",
        M"(struct M { pub v: i32 }
extend M as Add {
    type Output = M;
    pub const fn add(self: &Self, other: &M) M { return M { v: self.v + other.v }; }
}
extend M as Add<i32> {
    type Output = i64;
    pub const fn add(self: &Self, other: &i32) i64 { return self.v as i64 + *other as i64; }
}
extend M as Shl<u32> {
    type Output = M;
    pub fn shl(self: &Self, amount: u32) M { return M { v: self.v << amount as i32 }; }
}
extend M as BitNot {
    type Output = M;
    pub fn bit_not(self: &Self) M { return M { v: ~self.v }; }
}
struct W<T> { pub v: T }
extend<T: Copy> W<T> as Mul<i32> {
    type Output = Vector<T>;
    pub fn mul(self: &Self, other: &i32) Vector<T> {
        let mut out = Vector::<T>::new();
        for _ in 0..*other { out.push(self.v); }
        return out;
    }
}
struct N { pub s: String }
extend N as Add {
    type Output = String;
    pub fn add(self: &Self, other: &N) String {
        let mut r = self.s.clone();
        r.push_str(other.s.as_str());
        return r;
    }
}
interface Make<A> {
    type Out;
    fn make(self: &Self, a: A) Self::Out;
    fn make2(self: &Self, a: A, b: A) [Self::Out; 2] { return [self.make(a), self.make(b)]; }
}
interface Named: Make<i32> { fn name(self: &Self) str; }
struct K { pub base: i32 }
extend K as Make<i32> {
    type Out = String;
    pub fn make(self: &Self, a: i32) String {
        let mut s = String::new();
        s.format_into("{}", self.base + a);
        return s;
    }
}

extend K as Make<bool> {
    type Out = bool;
    pub fn make(self: &Self, a: bool) bool { return !a; }
}
extend K as Named { pub fn name(self: &Self) str { return "k"; } }
struct B { pub d: [String; 2] }
extend B as Index<String, []String> {
    pub fn index(self: &Self, i: usize) &String { return unsafe &self.d[i]; }
    pub fn index_range(self: &Self, r: Range<usize>) []String { return unsafe self.d[r.start..r.end]; }
}
extend B as IndexMut<String, []mut String> {
    pub fn index_mut(self: &mut Self, i: usize) &mut String { return unsafe &mut self.d[i]; }
    pub fn index_range_mut(self: &mut Self, r: Range<usize>) []mut String { panic("unused"); }
}
fn acc<T: Add<Output = T>>(t: T, u: T) T {
    let mut x = t;
    x += u;
    return x + u;
}
fn sh<T>(t: T) T where T: Shl<u32, Output = T> + BitNot<Output = T> {
    let mut x = t;
    x <<= 2;
    return ~x;
}
const fn wide<T: Add<i32>>(t: T) T::Output { return t + 1; }
const fn sum<T: Add>(a: T, b: T) T::Output { return a + b; }
fn rep<T: Mul<i32>>(t: T, n: i32) T::Output { return t * n; }
fn cat<T: Add>(a: &T, b: &T) T::Output { return *a + *b; }
fn nest<T: Mul<i32>>(t: T) Vector<T::Output> {
    let mut v = Vector::<T::Output>::new();
    v.push(t * 2);
    return v;
}
fn both<T: Make<i32>>(t: &T) [T::Out; 2] { return t.make2(1, 2); }
fn flip<T: Make<bool>>(t: &T) T::Out { return t.make(true); }
fn via<T: Named>(t: &T) T::Out { return t.make(40); }
fn put<T: IndexMut<String, []mut String> + Index<String, []String>>(t: &mut T, i: usize) usize {
    t[i] = String::from_str("xyz");
    let r = &mut t[i];
    r.push_str("!");
    return t[i].len();
}
const WIDE: i64 = wide(M { v: 9 });
const SUM: M = sum(M { v: 2 }, M { v: 5 });
fn main() i32 {
    if acc(M { v: 3 }, M { v: 4 }).v != 11 || sh(M { v: 1 }).v != -5 || wide(M { v: 9 }) != 10 {
        return 1;
    }
    static_assert(WIDE == 10 && SUM.v == 7);
    let v = rep(W { v: 7u8 }, 3);
    if v.len() != 3 || v[2] != 7 {
        return 2;
    }
    let s = cat(&N { s: String::from_str("ab") }, &N { s: String::from_str("cd") });
    if s.as_str() != "abcd" {
        return 3;
    }
    let w = nest(W { v: 1i64 });
    if w.len() != 1 || w[0].len() != 2 {
        return 4;
    }
    let k = K { base: 10 };
    let p = both(&k);
    if p[0].as_str() != "11" || p[1].as_str() != "12" || flip(&k) || via(&k).as_str() != "50" {
        return 5;
    }
    let mut b = B { d: [String::from_str("a"), String::from_str("b")] };
    if put(&mut b, 1) != 4 || b.d[1].as_str() != "xyz!" || b.d[0].as_str() != "a" {
        return 6;
    }
    return 0;
}
)",
        0,
    );
}

// A by-reference operator operand of a narrower numeric type (a literal, an `i32` local) is widened to
// the parameter's element type before it is borrowed: the method reads a full `i64`.
fn operator_operand_widens_before_its_borrow(b: &mut h::ExitBatch) {
    b.add(
        "operator operand widens before its borrow",
        M"(struct G { pub v: i64 }
extend G as Add<i64> {
    type Output = i64;
    pub fn add(self: &G, other: &i64) i64 { return self.v + *other; }
}
fn main() i32 {
    let h = G { v: 1 };
    let x: i32 = -2;
    let s = h + 3000000000;
    let t = h + 2;
    let u = h + x;
    return (s + t + u - 3000000003) as i32;
}
)",
        0,
    );
}

// An interface's associated function called through a type parameter (`T::count()`) runs the
// conformance the parameter names, whatever its result or first argument, also at compile time
// and for a generic extend.
fn associated_functions_through_bounds(b: &mut h::ExitBatch) {
    b.add(
        "associated functions through bounds",
        M"(interface I<A> {
    fn count() usize;
    fn make() Self;
    fn from_a(a: A) Self;
}
struct P { pub v: i32 }
extend P as I<i32> {
    pub const fn count() usize { return 7; }
    pub fn make() P { return P { v: 1 }; }
    pub fn from_a(a: i32) P { return P { v: a }; }
}
extend P as I<bool> {
    pub const fn count() usize { return 9; }
    pub fn make() P { return P { v: 2 }; }
    pub fn from_a(a: bool) P {
        if a {
            return P { v: 5 };
        }
        return P { v: 6 };
    }
}
struct W<T> { pub v: T }
extend<T> W<T> as I<u8> {
    pub const fn count() usize { return sizeof(T); }
    pub fn make() W<T> { return W { v: unsafe zeroed::<T>() }; }
    pub fn from_a(a: u8) W<T> { return W { v: unsafe zeroed::<T>() }; }
}
const fn g<T: I<bool>>() usize { return T::count(); }
const fn h<T: I<i32>>() usize { return T::count() * 3; }
const fn g2<T: I<u8>>() usize { return T::count() * 3; }
fn fa<T: I<bool>>(b: bool) T { return T::from_a(b); }
fn mk<T: I<i32>>() T { return T::make(); }
const G: usize = g::<P>();
const H: usize = h::<P>();
const WC: usize = g2::<W<u64>>();
fn main() i32 {
    static_assert(G == 9 && H == 21 && WC == 24);
    let p: P = fa(true);
    let q: P = mk();
    if g::<P>() != 9 || h::<P>() != 21 || g2::<W<u16>>() != 6 || p.v != 5 || q.v != 1 {
        return 1;
    }
    return 0;
}
)",
        0,
    );
}

// Interfaces whose methods return several results or a fixed array are dyn-compatible: `&dyn`,
// `&mut dyn` and `Box<dyn>` calls destructure the slot's carrier, inherited defaults and overrides
// both dispatch, a generic interface reads its dyn arguments, and owned results are freed once.
fn dyn_methods_with_several_results(b: &mut h::ExitBatch) {
    b.add(
        "dyn methods with several results",
        M"(interface Shape {
    fn dims(self: &Self) (i32, String);
    fn corners(self: &Self) [i32; 2];
    fn grow(self: &mut Self, by: i32) (i32, i32);
    fn label(self: &Self) (String, i32) {
        let (w, n) = self.dims();
        let mut s = String::from_str("shape:");
        s.push_string(&n);
        return s, w * 10;
    }
    fn pair(self: &Self) [String; 2] {
        return [String::from_str("a"), String::from_str("b")];
    }
}
struct Rect { pub w: i32, pub h: i32 }
extend Rect as Shape {
    pub fn dims(self: &Self) (i32, String) { return self.w * self.h, String::from_str("rect"); }
    pub fn corners(self: &Self) [i32; 2] { return [self.w, self.h]; }
    pub fn grow(self: &mut Self, by: i32) (i32, i32) {
        self.w += by;
        self.h += by;
        return self.w, self.h;
    }
    pub fn pair(self: &Self) [String; 2] { return [String::from_str("r"), String::from_str("q")]; }
}
struct Dot { pub r: i32 }
extend Dot as Shape {
    pub fn dims(self: &Self) (i32, String) { return self.r, String::from_str("dot"); }
    pub fn corners(self: &Self) [i32; 2] { return [0, 0]; }
    pub fn grow(self: &mut Self, by: i32) (i32, i32) {
        self.r += by;
        return self.r, 0;
    }
    pub fn label(self: &Self) (String, i32) { return String::from_str("dot!"), 1; }
}
interface Src<A> {
    fn get(self: &Self) (A, String);
    fn both(self: &Self) [A; 2] {
        let (a, s) = self.get();
        let (b, t) = self.get();
        return [a, b];
    }
}
struct K { pub v: i32 }
extend K as Src<i32> {
    pub fn get(self: &Self) (i32, String) { return self.v, String::from_str("k"); }
}
extend K as Src<bool> {
    pub fn get(self: &Self) (bool, String) { return self.v > 0, String::from_str("kb"); }
}
fn show(s: &dyn Shape) i32 {
    let (a, n) = s.dims();
    let c = s.corners();
    let (l, k) = s.label();
    let p = s.pair();
    return a + c[0] + c[1] + n.len() as i32 + l.len() as i32 + k + p[0].len() as i32;
}
fn bump(s: &mut dyn Shape) i32 {
    let (x, y) = s.grow(2);
    return x + y;
}
fn use_i(s: &dyn Src<i32>) i32 {
    let (a, t) = s.get();
    let p = s.both();
    return a + p[1] + t.len() as i32;
}
fn use_b(s: &dyn Src<bool>) bool {
    let (a, t) = s.get();
    return a && t.as_str() == "kb";
}
fn main() i32 {
    let mut r = Rect { w: 2, h: 3 };
    let d = Dot { r: 5 };
    if show(&r) != 6 + 5 + 4 + 10 + 60 + 1 || show(&d) != 5 + 0 + 3 + 4 + 1 + 1 {
        return 1;
    }
    if bump(&mut r) != 9 {
        return 2;
    }
    let mut v = Vector::<Box<dyn Shape>>::new();
    v.push(Box::<Rect>::new(Rect { w: 1, h: 1 }));
    v.push(Box::<Dot>::new(Dot { r: 9 }));
    let mut t = 0;
    for i in 0..v.len() {
        let (a, n) = v[i].dims();
        let (l, k) = v.at(i).label();
        t = t + a + k + n.len() as i32 + l.len() as i32;
    }
    if t != 1 + 10 + 4 + 10 + 9 + 1 + 3 + 4 {
        return 3;
    }
    let mut b: Box<dyn Shape> = Box::<Dot>::new(Dot { r: 1 });
    let (g, h) = b.grow(4);
    let k = K { v: 4 };
    if g != 5 || h != 0 || use_i(&k) != 9 || !use_b(&k) {
        return 4;
    }
    return 0;
}
)",
        0,
    );
}

// A generic argument a bound alone decides: the one fitting conformance.
fn inference_from_the_one_fitting_conformance(b: &mut h::ExitBatch) {
    b.add(
        "bound inference",
        M"(interface I<A> { fn get(self: &Self) A; }
struct P { pub v: i32 }
extend P as I<i32> { pub fn get(self: &Self) i32 { return self.v; } }
extend P as I<bool> { pub fn get(self: &Self) bool { return self.v > 0; } }
struct Q { pub v: i32 }
extend Q as I<u8> { pub fn get(self: &Self) u8 { return self.v as u8; } }
fn f<A, T: I<A>>(t: T) A { return t.get(); }
fn g<A, T: I<A>>(t: T, a: A) A { return a; }
fn outer<U: I<bool>>(u: U) bool { let r = f(u); return r; }
fn main() i32 {
    let q = f(Q { v: 3 });
    let x: bool = f(P { v: 3 });
    let y = g(P { v: 1 }, 5);
    if q != 3u8 || !x || y != 5 || !outer(P { v: 2 }) {
        return 1;
    }
    return 0;
}
)",
        0,
    );
}

// An inherited default of a generic interface called on a concrete receiver runs under the
// conformance the call's arguments select (`Self::Out` included), as a call through a bound does.
fn inherited_default_of_a_generic_interface(b: &mut h::ExitBatch) {
    b.add(
        "inherited default on a concrete receiver",
        M"(interface Make<A> {
    type Out;
    fn make(self: &Self, a: A) Self::Out;
    fn make2(self: &Self, a: A, b: A) [Self::Out; 2] { return [self.make(a), self.make(b)]; }
    fn sum(self: &Self, a: A, b: A) i32 { return 2; }
}
struct K { pub base: i32 }
extend K as Make<i32> {
    type Out = String;
    pub fn make(self: &Self, a: i32) String {
        let mut s = String::new();
        s.format_into("{}", self.base + a);
        return s;
    }
    pub fn sum(self: &Self, a: i32, b: i32) i32 { return a + b; }
}
extend K as Make<bool> {
    type Out = bool;
    pub fn make(self: &Self, a: bool) bool { return !a; }
}
fn one() i32 { return 1; }
fn yes() bool { return true; }
fn main() i32 {
    let k = K { base: 10 };
    let x = 3;
    let p = k.make2(1, 2);
    let q = k.make2(true, false);
    let r = k.make2(x, one());
    let s = k.make2(yes(), !yes());
    if p[0].as_str() != "11" || p[1].as_str() != "12" || q[0] || !q[1] || r[0].as_str() != "13" || s[0] {
        return 1;
    }
    if k.sum(x, 4) != 7 {
        return 2;
    }
    return 0;
}
)",
        0,
    );
}

// A receiver that overrides a default in one conformance and inherits it in another: the call's
// arguments choose among both, and the chosen conformance's body runs directly, through a path,
// through auto-deref, through a bound, through dyn and at compile time.
fn override_and_inherited_default_compete_by_arguments(b: &mut h::ExitBatch) {
    b.add(
        "an override and an inherited default",
        M"(interface Make<A> {
    fn make(self: &Self, a: A) String;
    fn sum(self: &Self, a: A, b: A) String {
        let mut s = self.make(a);
        s.push_str(self.make(b).as_str());
        return s;
    }
}
struct K { pub base: i32 }
extend K as Make<i32> {
    pub fn make(self: &Self, a: i32) String {
        let mut s = String::new();
        s.format_into("{}", self.base + a);
        return s;
    }
    pub fn sum(self: &Self, a: i32, b: i32) String {
        let mut s = String::new();
        s.format_into("{}", a + b);
        return s;
    }
}
extend K as Make<bool> {
    pub fn make(self: &Self, a: bool) String {
        return String::from_str(if a { "t"; } else { "f"; });
    }
}
const fn tf(t: bool) i32 {
    let k = K { base: 1 };
    return if k.sum(t, !t).as_str() == "tf" { 1; } else { 2; };
}
const C: i32 = tf(true);
fn via<T: Make<bool>>(t: &T) String { return t.sum(false, true); }
fn dy(d: &dyn Make<bool>) String { return d.sum(true, true); }
fn main() i32 {
    let k = K { base: 10 };
    let b = Box::<K>::new(K { base: 20 });
    let x = true;
    if k.sum(true, false).as_str() != "tf" || k.sum(x, x).as_str() != "tt" || k.sum(3, 4).as_str() != "7" {
        return 1;
    }
    if K::sum(&k, false, false).as_str() != "ff" || K::sum(&k, 1, 2).as_str() != "3" {
        return 2;
    }
    if b.sum(false, true).as_str() != "ft" || b.sum(5, 5).as_str() != "10" {
        return 3;
    }
    if via(&k).as_str() != "ft" || dy(&k).as_str() != "tt" || C != 1 || tf(false) != 2 {
        return 4;
    }
    return 0;
}
)",
        0,
    );
}

// `Self::` in an expression names the implementing type as `TypeName::` does: associated functions,
// constants, turbofish, struct literals, generic extends, builtin targets and interface defaults
// (the implementor, also when the default runs through a path).
fn self_path_names_the_implementing_type(b: &mut h::ExitBatch) {
    b.add(
        "Self paths",
        M"(interface Cnt {
    fn count() i32;
    fn twice() i32 { return Self::count() * 2; }
    fn pair(v: i32) (i32, i32) { return v + Self::count(), v; }
}
struct P { pub v: i32 }
extend P {
    pub const K: i32 = 7;
    pub fn new() P { return Self { v: Self::K + Self::seven() }; }
    fn seven() i32 { return 7; }
    fn id<T>(x: T) T { return x; }
    pub fn g() i64 { return Self::id::<i64>(3); }
}
extend P as Cnt { pub fn count() i32 { return 5; } }
struct W<T> { pub v: T, pub n: i32 }
extend<T: Copy> W<T> {
    pub const N: i32 = 4;
    pub fn with(v: T) W<T> { return Self::build(v, Self::N); }
    fn build(v: T, n: i32) W<T> { return Self { v: v, n: n }; }
    fn conv<U>(u: U) U { return u; }
    pub fn double(self: &Self) i32 { return Self::conv::<i32>(self.n) * 2; }
}
extend W<i32> as Cnt { pub fn count() i32 { return 11; } }
extend i32 {
    fn one() i32 { return 1; }
    pub fn plus_one(self: i32) i32 { return self + Self::one(); }
}
fn tw<T: Cnt>() i32 { return T::twice(); }
const T2: i32 = P::twice();
fn main() i32 {
    let w = W::<u8>::with(3u8);
    let (a, b) = W::<i32>::pair(7);
    if P::new().v != 14 || P::g() != 3 || P::twice() != 10 || tw::<P>() != 10 || T2 != 10 {
        return 1;
    }
    if w.n != 4 || w.v != 3u8 || w.double() != 8 || W::<u8>::conv::<i64>(6) != 6 || a != 18 || b != 7 {
        return 2;
    }
    if 5.plus_one() != 6 || W::<i32>::twice() != 22 {
        return 3;
    }
    return 0;
}
)",
        0,
    );
}

// A superinterface with arguments (`B: A<i32>`) erases through dyn: the vtable holds its methods for
// those arguments, calls run the conformance with them (an override or a default), and a dyn value
// upcasts to the superinterface, borrowed or owned.
fn dyn_generic_superinterface(b: &mut h::ExitBatch) {
    b.add(
        "dyn with a generic superinterface",
        M"(interface A<T> {
    fn get(self: &Self) T;
    fn pair(self: &Self) (T, T) { return self.get(), self.get(); }
    fn twice(self: &Self) i32 { return 2; }
}
interface B<T>: A<T> {
    fn name(self: &Self) String;
}
interface C: B<bool> {
    fn c(self: &Self) i32;
}
interface N {
    fn n(self: &Self) i32;
}
interface M: N {
    fn m(self: &Self) i32 { return 10 * self.n(); }
}
struct S { pub v: i32 }
extend S as A<i32> { pub fn get(self: &Self) i32 { return self.v; } }
extend S as A<bool> {
    pub fn get(self: &Self) bool { return self.v > 0; }
    pub fn twice(self: &Self) i32 { return 99; }
}
extend S as B<i32> { pub fn name(self: &Self) String { return String::from_str("Bi"); } }
extend S as B<bool> { pub fn name(self: &Self) String { return String::from_str("Bb"); } }
extend S as C { pub fn c(self: &Self) i32 { return 5; } }
extend S as N { pub fn n(self: &Self) i32 { return self.v; } }
extend S as M {}
fn bi(b: &dyn B<i32>) i32 {
    let (x, y) = b.pair();
    return x + y + b.name().len() as i32 + b.twice();
}
fn up_c(c: Box<dyn C>) Box<dyn A<bool>> { return c; }
fn up_m(m: &dyn M) &dyn N { return m; }
fn main() i32 {
    let s = S { v: 3 };
    let c: &dyn C = &s;
    let bb: &dyn B<bool> = c;
    let ab: &dyn A<bool> = c;
    let (p, q) = bb.pair();
    if bi(&s) != 10 || !c.get() || c.name().as_str() != "Bb" || !p || !q || !ab.get() || c.twice() != 99 || c.c() != 5 {
        return 1;
    }
    let ua = up_c(Box::<S>::new(S { v: -1 }));
    let mut t = S { v: 9 };
    let mb: &mut dyn B<i32> = &mut t;
    let ma: &mut dyn A<i32> = mb;
    if ua.get() || ua.twice() != 99 || ma.get() != 9 {
        return 2;
    }
    if up_m(&s).n() != 3 || (&s as &dyn M).m() != 30 {
        return 3;
    }
    return 0;
}
)",
        0,
    );
}

// A generic interface method runs its implementation's instance for the call's arguments through a
// bound (method and path form, inferred or turbofished), from a default body, on a generic
// conformance, and at compile time; owning results are freed once.
fn generic_interface_methods_run(b: &mut h::ExitBatch) {
    b.add(
        "generic interface methods",
        M"(interface Num {
    fn of(v: i32) Self;
    fn get(self: &Self) i64;
}
struct B { pub v: i64 }
extend B as Num {
    fn of(v: i32) B { return B { v: v }; }
    fn get(self: &Self) i64 { return self.v; }
}
struct Name { pub s: String }
extend Name as Num {
    fn of(v: i32) Name {
        let mut s = String::new();
        s.push_i64(v);
        return Name { s: s };
    }
    fn get(self: &Self) i64 { return self.s.len() as i64; }
}
interface Conv {
    fn conv<U: Num>(self: &Self, n: i32) U;
    fn twice<V: Num>(self: &Self) i64 { return self.conv::<V>(1).get() + self.conv::<V>(2).get(); }
}
struct C { pub k: i32 }
extend C as Conv {
    fn conv<U: Num>(self: &Self, n: i32) U { return U::of(n + self.k); }
}
struct G<T> { pub t: T }
extend<T: Num> G<T> as Conv {
    fn conv<W: Num>(self: &Self, n: i32) W { return W::of(n + self.t.get() as i32); }
}
fn via<T: Conv>(t: &T) i64 { return t.conv::<B>(3).get() + T::conv::<Name>(t, 1000).get(); }
fn named<T: Conv>(t: &T) i64 { let x: Name = t.conv(12345); return x.get() + t.twice::<Name>(); }
const K1: i64 = via(&C { k: 1 });
const K2: i64 = C { k: 1 }.twice::<B>();
fn main() i32 {
    let c = C { k: 1 };
    let g = G::<B> { t: B { v: 10 } };
    let n: Name = c.conv::<Name>(99999);
    if via(&c) != 8 || via(&g) != 17 { return 1; }
    if named(&c) != 7 || named(&g) != 9 { return 2; }
    if c.twice::<B>() + g.twice::<B>() != 28 || n.get() != 6 { return 3; }
    if K1 != 8 || K2 != 5 { return 4; }
    return 0;
}
)",
        0,
    );
}

// A const-generic argument takes an associated constant of one of several disjoint extends when the
// parameter's type chooses it or the instance is written (braced or bare), and a generic extend's
// constant for the written instance.
fn const_argument_selects_an_extend(b: &mut h::ExitBatch) {
    b.add(
        "associated constants as const arguments",
        M"(struct W<T> { pub v: T }
extend W<u8> { pub const K: u64 = 3; }
extend W<i32> { pub const K: u32 = 5; }
struct G<T> { pub v: T }
extend<T> G<T> { pub const S: u64 = sizeof(T) as u64 * 2; }
struct F<const N: u64> { pub x: i32 }
extend<const N: u64> F<N> { pub fn n(self: &Self) u64 { return N; } }
fn main() i32 {
    let a = F::<W::K> { x: 1 };
    let b: F<{W::<i32>::K + 1}> = F { x: 2 };
    let c = F::<{G::<u16>::S * W::<u8>::K}> { x: 0 };
    let d: F<W::<u8>::K> = F { x: 3 };
    let e = F::<W::<i32>::K> { x: 4 };
    return (a.n() + b.n() + c.n() + d.n() + e.n()) as i32 - 29;
}
)",
        0,
    );
}

// The methods and constants of a user extend of a builtin type run at compile time: a receiver the
// call borrows (a local, a temporary, a `&mut self` that writes it back), an interface default, a
// bound call, and a qualified constant, from array lengths the type check folds and from constants.
fn builtin_extend_methods_fold_at_compile_time(b: &mut h::ExitBatch) {
    b.add(
        "builtin extend methods in constant evaluation",
        M"(interface I {
    fn get(self: &Self) usize;
    fn twice(self: &Self) usize { return self.get() * 2; }
}
extend u8 as I {
    fn get(self: &u8) usize { return *self as usize + 1; }
}
extend u8 {
    pub const K: usize = 5;
    fn bump(self: &mut u8) { *self = *self + 1; }
}
fn f1() usize {
    let mut x: u8 = 3;
    x.bump();
    return x.twice();
}
fn f2<T: I>(t: &T) usize { return t.get(); }
const A: usize = f1();
const B: usize = (6u8).get();
fn main() i32 {
    let a: [u8; f1()] = [0u8; 10];
    let b: [u8; f2(&6u8)] = [0u8; 7];
    let d: [u8; u8::K] = [0u8; 5];
    if sizeof(a) != 10 || sizeof(b) != 7 || sizeof(d) != 5 { return 1; }
    if A != 10 || B != 7 { return 2; }
    return 0;
}
)",
        0,
    );
}

// A method call on the result of a turbofished method call takes none of that call's arguments.
fn method_on_a_turbofished_call(b: &mut h::ExitBatch) {
    b.add(
        "a call on a turbofished call's result",
        "struct N { pub s: String }\nextend N { pub fn get(self: &Self) i64 { return self.s.len() as i64; } }\nstruct X { pub k: i32 }\nextend X { pub fn m<U>(self: &Self, u: U) N { return N { s: String::from_str(\"abc\") }; } }\nfn main() i32 { let x = X { k: 1 }; return x.m::<u8>(1).get() as i32 - 3; }\n",
        0,
    );
}

// An ordered comparison of raw pointers to two objects compiles and orders them; a bare `*T` takes `&T`.
fn pointer_order_across_objects(b: &mut h::ExitBatch) {
    exit_case(
        b,
        "pointer order across objects",
        "fn lt(p: *i32, q: *i32) bool { return p < q; }\nfn main() i32 { let x = 1; let y = 2; let a = [3, 4]; let mut r = 0; if lt(&a[0], &a[1]) { r += 1; } if lt(&x, &y) != lt(&y, &x) { r += 2; } unsafe exit(r); }\n",
        3,
    );
}

// Operation OP (0 load, 1 store, 2 read-modify-write, 3 compare-exchange success, 4 compare-exchange
// failure, 5 fence, 6 bool load, 7 compare-exchange with success order SO) with memory-order code MO.
const ATOMIC_ORDERS: str = M"(import atomic;
import stdlib;

fn arg(name: str) i32 {
    return unsafe stdlib::atoi(stdlib::getenv(name));
}

fn main() i32 {
    let op = arg("OP");
    let mo = arg("MO");
    let mut x: i32 = 5;
    let b = false;
    if op == 0 {
        return unsafe atomic::load_i32(&x, mo) - 5;
    } else if op == 1 {
        unsafe atomic::store_i32(&mut x, 6, mo);
        return x - 6;
    } else if op == 2 {
        return unsafe atomic::add_i32(&mut x, 1, mo) + x - 11;
    } else if op == 3 {
        if unsafe atomic::cas_i32(&mut x, 5, 7, false, mo, 0) {
            return x - 7;
        }
    } else if op == 4 {
        if unsafe atomic::cas_i32(&mut x, 5, 7, false, 4, mo) {
            return x - 7;
        }
    } else if op == 5 {
        atomic::fence(mo);
        return 0;
    } else if op == 6 {
        return unsafe atomic::load_bool(&b, mo) as i32;
    } else if op == 7 {
        let so = arg("SO");
        let hit = unsafe atomic::cas_i32(&mut x, 5, 7, false, so, mo);
        let miss = unsafe atomic::cas_i32(&mut x, 5, 9, true, so, mo);
        if hit && !miss && x == 7 {
            return 0;
        }
    }
    return 1;
}
)";

// Every memory-order code an operation cannot take traps with "invalid memory order"; every code it
// takes runs; a failure order stronger than the success order strengthens the success order.
@test
fn atomic_memory_orders_are_checked() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", ATOMIC_ORDERS);
    let root = p.dir();
    let mut args = String::new();
    args.format_into("build \"{}/main.spc\" -o \"{}/bin\"", root, root);
    assert(p.run_raw(args.as_str()).ok());
    // Per operation, its valid codes, then (OP=7) each failure order stronger than its success order:
    // Relaxed + Acquire, Release + Acquire, and each weaker success with SeqCst.
    let valid: []str = [
        "OP=0 MO=0 ",
        "OP=0 MO=1 ",
        "OP=0 MO=4 ",
        "OP=1 MO=0 ",
        "OP=1 MO=2 ",
        "OP=1 MO=4 ",
        "OP=2 MO=0 ",
        "OP=2 MO=1 ",
        "OP=2 MO=2 ",
        "OP=2 MO=3 ",
        "OP=2 MO=4 ",
        "OP=3 MO=0 ",
        "OP=3 MO=1 ",
        "OP=3 MO=2 ",
        "OP=3 MO=3 ",
        "OP=3 MO=4 ",
        "OP=4 MO=0 ",
        "OP=4 MO=1 ",
        "OP=4 MO=4 ",
        "OP=5 MO=0 ",
        "OP=5 MO=1 ",
        "OP=5 MO=2 ",
        "OP=5 MO=3 ",
        "OP=5 MO=4 ",
        "OP=6 MO=0 ",
        "OP=6 MO=1 ",
        "OP=6 MO=4 ",
        "OP=7 SO=0 MO=1 ",
        "OP=7 SO=2 MO=1 ",
        "OP=7 SO=0 MO=4 ",
        "OP=7 SO=1 MO=4 ",
        "OP=7 SO=2 MO=4 ",
        "OP=7 SO=3 MO=4 ",
    ];
    // The codes between 0 and 4 each operation cannot take, one past the end, and a negative one.
    let invalid: []str = [
        "OP=0 MO=2 ",
        "OP=0 MO=3 ",
        "OP=0 MO=5 ",
        "OP=0 MO=-1 ",
        "OP=1 MO=1 ",
        "OP=1 MO=3 ",
        "OP=1 MO=5 ",
        "OP=1 MO=-1 ",
        "OP=2 MO=5 ",
        "OP=2 MO=-1 ",
        "OP=3 MO=5 ",
        "OP=3 MO=-1 ",
        "OP=4 MO=2 ",
        "OP=4 MO=3 ",
        "OP=4 MO=5 ",
        "OP=4 MO=-1 ",
        "OP=5 MO=5 ",
        "OP=5 MO=-1 ",
        "OP=6 MO=2 ",
        "OP=6 MO=3 ",
        "OP=6 MO=5 ",
        "OP=6 MO=-1 ",
    ];
    for i in 0..valid.len() {
        assert(p.run_bin_env(valid[i]).ok());
    }
    for i in 0..invalid.len() {
        let r = p.run_bin_env(invalid[i]);
        assert(r.exit != 0 && r.out_shows("invalid memory order"));
    }
}

// `memmove` copies overlapping ranges in both directions as if through a temporary buffer.
fn memmove_overlap_both_directions(b: &mut h::ExitBatch) {
    exit_case(
        b,
        "memmove overlap",
        "extern \"C\" { fn memmove(d: *mut void, s: *const void, n: usize) *mut void; }\nfn main() i32 {\n    let mut a: [u8; 8] = [1, 2, 3, 4, 5, 6, 7, 8];\n    let p = &mut a[0] as *mut u8;\n    unsafe memmove(unsafe (p + 2), p, 5);\n    let mut b: [u8; 8] = [1, 2, 3, 4, 5, 6, 7, 8];\n    let q = &mut b[0] as *mut u8;\n    unsafe memmove(q, unsafe (q + 2), 5);\n    let wa: [u8; 8] = [1, 2, 1, 2, 3, 4, 5, 8];\n    let wb: [u8; 8] = [3, 4, 5, 6, 7, 6, 7, 8];\n    let mut r = 0;\n    for i in 0..8 {\n        unsafe {\n            if a[i] != wa[i] {\n                r |= 1;\n            }\n            if b[i] != wb[i] {\n                r |= 2;\n            }\n        }\n    }\n    unsafe exit(r);\n}\n",
        0,
    );
}

// `Self` in a generic extend of another module is the instance it is called through.
@test
fn a_foreign_generic_self_result_is_the_instance() {
    let p = cli::proj_new();
    p.mkfile(
        "w.spc",
        "pub struct W<const K: usize> {\n    pub x: u8,\n}\nextend<const K: usize> W<K> {\n    pub fn make() Self {\n        return W::<K> { x: K as u8 };\n    }\n}\n",
    );
    p.mkfile(
        "main.spc",
        "import w;\nfn main() i32 {\n    let v: w::W<4> = w::W::<4>::make();\n    return v.x as i32 - 4;\n}\n",
    );
    assert(p.compile("main.spc").ok(), "transpiles");
    assert(p.cc_build("").ok(), "builds");
    assert(p.run_bin() == 0, "the instance's value");
}

// A reference to an array parameter is the array's address: the C parameter is a pointer, so `&a`
// would be the pointer's address.
fn a_reference_to_an_array_parameter_reads_it(b: &mut h::ExitBatch) {
    b.add(
        "array parameter reference",
        "fn first(a: [i32; 4]) i32 {\n    let r = &a;\n    return r[0] + r[3];\n}\nfn main() i32 {\n    return first([7, 0, 0, 2]) - 9;\n}\n",
        0,
    );
}

// A generic extend's method as a value (`W::<i64>::get`, `Simd::<f32, 4>::sqrt`): the qualifier's
// instance binds the extend, so the value is that instance's function.
fn a_generic_method_value_is_its_instance(b: &mut h::ExitBatch) {
    b.add(
        "generic method values",
        "struct W<T> {\n    pub v: T,\n}\n\nextend<T: Copy> W<T> {\n    pub fn make(v: T) Self {\n        return W::<T> { v: v };\n    }\n\n    pub fn get(self: &Self) T {\n        return self.v;\n    }\n\n    pub fn pair(self: Self, o: Self) (T, T) {\n        return self.v, o.v;\n    }\n}\n\nfn main() i32 {\n    let mk = W::<i64>::make;\n    let g = W::<i64>::get;\n    let sq = Simd::<f32, 4>::sqrt;\n    let ad = Simd::<i8, 4>::abs_diff;\n    let w = mk(5);\n    let (x, y) = w.pair(mk(2));\n    let r = sq(Simd::<f32, 4>::splat(16.0));\n    let d = ad(Simd::<i8, 4>::splat(-100), Simd::<i8, 4>::splat(100));\n    return (g(&w) + x + y) as i32 + r[0] as i32 + d[0] as i32 - 216;\n}\n",
        0,
    );
}

// The checked views over program-owned bytes: `str::from_cbuf` stops at the first NUL or at the
// buffer's end, `String::push_bytes` appends a `[]u8`, and the integer out-parameters take `&mut`.
fn checked_byte_views(b: &mut h::ExitBatch) {
    exit_case(
        b,
        "from_cbuf, push_bytes and &mut out-parameters",
        M"(fn main() i32 {
    let a: [char; 6] = ['a', 'b', 0 as char, 'c', 'd', 'e'];
    let b: [char; 3] = ['x', 'y', 'z'];
    let s = str::from_cbuf(a);
    let t = str::from_cbuf(b);
    let mut out = String::new();
    let bytes: [u8; 2] = [104, 105];
    out.push_bytes(bytes);
    let x = u128::from_u64(7);
    let two = u128::from_u64(2);
    let mut r = u128::zero();
    let q = x.divmod(&two, &mut r);
    if s != "ab" || t != "xyz" || out.as_str() != "hi" || q.to_u64() != 3 || r.to_u64() != 1 {
        unsafe exit(1);
    }
    return 0;
}
)",
        0,
    );
}

// A generic tuple struct's constructor infers its type arguments from its elements, or takes the
// expected instance, as a generic enum variant does.
fn tuple_struct_constructor_inference(b: &mut h::ExitBatch) {
    b.add(
        "generic tuple-struct constructors",
        M"(struct Q<T>(T);
struct P<A, B>(A, B);
fn take(q: Q<i64>) i64 { return q.0; }
fn main() i32 {
    let a = Q(5);
    let c: Q<i64> = Q(7);
    let d = take(Q(9));
    let e = P(1u8, Q(true));
    let s = Q(String::from_str("xy"));
    if a.0 != 5 || c.0 != 7 || d != 9 || e.0 != 1 || !e.1 .0 {
        return 1;
    }
    return s.0.len() as i32 - 2;
}
)",
        0,
    );
}

// A capturing closure stored in a generic struct's field embeds its environment there: a mutated
// capture is a pointer, a moved one its value, and the layout model agrees with the C layout.
fn closure_in_generic_struct_field(b: &mut h::ExitBatch) {
    b.add(
        "closures in struct fields",
        M"(struct Q<F: fn() i32> { pub v: i64, pub f: F }
struct M<F: fn(i32)> { pub f: F }
fn main() i32 {
    let s = String::from_str("abc");
    let q = Q { v: 5, f: || s.len() as i32 };
    let mut n: i64 = 0;
    let mut m = M { f: |x: i32| { n += x as i64; } };
    (m.f)(3);
    (m.f)(4);
    return (q.f)() + q.v as i32 + n as i32 - 15;
}
)",
        0,
    );
}

// `zeroed` of an array is a byte fill, and a generic aggregate zeroes at compile time too.
fn zeroed_arrays_and_generic_aggregates(b: &mut h::ExitBatch) {
    b.add(
        "zeroed arrays",
        M"(fn mk() [u32; 5] {
    let a = unsafe zeroed::<[u32; 5]>();
    return a;
}
struct W<T> { pub a: [T; 3] }
const fn mkw<T>() W<T> {
    return unsafe zeroed::<W<T>>();
}
const V: W<u32> = mkw::<u32>();
const A: Array<u32, 4> = Array::<u32, 4>::new();
fn main() i32 {
    let w = mk();
    return w[4] as i32 + V.a[2] as i32 + A.len() as i32 - 4;
}
)",
        0,
    );
}

// Programs the checker accepts compile: an `Option<Box<dyn fn>>` frees its payload through the
// vtable's drop slot, a field reached through `&mut &mut H` dereferences twice, and an argument of
// an associated type that is a reference passes the reference.
fn dyn_drop_double_deref_and_assoc_arguments(b: &mut h::ExitBatch) {
    b.add(
        "an Option<Box<dyn fn>> drop",
        "fn mk(k: i32) Box<dyn fn() i32> {\n    return Box::new(move || k);\n}\nfn main() i32 {\n    let mut c: Option<Box<dyn fn() i32>> = Option::<Box<dyn fn() i32>>::None;\n    c = Option::<Box<dyn fn() i32>>::Some(mk(52));\n    let f = c.unwrap();\n    return f() - 52;\n}\n",
        0,
    );
    b.add(
        "a field through &mut &mut",
        "struct H<'a> { pub r: &'a i32 }\nconst K: i32 = 7;\nconst Z: i32 = 0;\nfn main() i32 {\n    let mut h = H { r: &Z };\n    let mut m = &mut h;\n    let mm = &mut m;\n    mm.r = &K;\n    return *h.r - 7;\n}\n",
        0,
    );
    b.add(
        "a reference argument of an associated type",
        "interface Producer { type Output; }\nstruct P {}\nextend P as Producer { type Output = &'static Box<i32>; }\nfn take<T: Producer>(x: T::Output) i32 { let _ = x; return 52; }\nfn main() i32 {\n    let v = Box::<i32>::new(52);\n    let r: &Box<i32> = &v;\n    return take::<P>(r) - 52;\n}\n",
        0,
    );
}

// `*b` on a Box is a mutable place through `deref_mut` when the binding is mutable: an assignment
// and a `&mut *b` both write the boxed value.
fn box_deref_mut_places(b: &mut h::ExitBatch) {
    b.add(
        "*b = v and &mut *b",
        "fn main() i32 {\n    let mut b = Box::<i32>::new(52);\n    *b = 1;\n    let x = &mut *b;\n    *x += 2;\n    return *b - 3;\n}\n",
        0,
    );
}

// A variadic argument arrives promoted (`float` as `double`, a narrow integer as `int`): `va_arg`
// reads the promoted type and converts, directly and through a generic.
fn va_arg_reads_promoted_types(b: &mut h::ExitBatch) {
    b.add(
        "va_arg of f32 and u8",
        "fn take_f32(n: i32, ...) f32 {\n    let ap: va_list;\n    va_start(ap, n);\n    let v = unsafe va_arg(ap, f32);\n    va_end(ap);\n    return v;\n}\nfn take_g<T>(n: i32, ...) T {\n    let ap: va_list;\n    va_start(ap, n);\n    let v = unsafe va_arg(ap, T);\n    va_end(ap);\n    return v;\n}\nfn main() i32 {\n    let a = take_f32(1, 3.25f32);\n    let b = take_g::<f32>(1, 3.25f32);\n    let c = take_g::<u8>(1, 200u8);\n    if a != 3.25 || b != 3.25 || c != 200 {\n        return 1;\n    }\n    return 0;\n}\n",
        0,
    );
}

// The exit-code cases of the provider functions above, one program per group (`h::ExitBatch`):
// a group builds once where each case built alone.
@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    operator_overload_lowering(&mut b);
    user_index_on_concrete_structs(&mut b);
    user_index_range_on_concrete_structs(&mut b);
    operator_candidates_respect_extend_bounds(&mut b);
    conformance_chosen_by_bounds(&mut b);
    argument_count_picks_an_associated_function(&mut b);
    operators_of_generic_shapes(&mut b);
    escaped_names_stay_distinct(&mut b);
    inlined_callee_keeps_its_guarded_drop(&mut b);
    b.run();
}

@test
fn exit_cases_01() {
    let mut b = h::ExitBatch::new();
    arithmetic(&mut b);
    control_flow(&mut b);
    float_constants_exact(&mut b);
    switches(&mut b);
    enum_discriminant_references(&mut b);
    constant_aggregate_holds_empty_string(&mut b);
    local_constants_of_one_name(&mut b);
    compile_time_layout_and_zero_sized_maps(&mut b);
    constant_references_address_items(&mut b);
    b.run();
}

@test
fn exit_cases_02() {
    let mut b = h::ExitBatch::new();
    container_from_list(&mut b);
    prelude_call_inside_generic_body(&mut b);
    sso_budget_follows_pointer_width(&mut b);
    const_generic_array_length_inferred(&mut b);
    names_that_are_standard_macros(&mut b);
    names_that_c_headers_declare(&mut b);
    array_const_read_as_slice_keeps_array_storage(&mut b);
    static_slice_result(&mut b);
    question_moves_a_free_payload(&mut b);
    for_over_array_literal(&mut b);
    b.run();
}

@test
fn exit_cases_03() {
    let mut b = h::ExitBatch::new();
    for_over_generic_array_consumes_owning_elements(&mut b);
    array_of_free_elements_drops_each(&mut b);
    closures_mutate_and_borrow_captures_through_bounds(&mut b);
    nested_array_literals_store_by_slot(&mut b);
    array_values_copy_into_aggregates(&mut b);
    uncovered_conditional_free_instances_derive(&mut b);
    function_pointer_results_and_double_references(&mut b);
    switch_frees_unbound_scrutinee_parts(&mut b);
    array_literal_elements_take_the_expected_type(&mut b);
    flagged_drop_keeps_array_local_names(&mut b);
    array_parameter_element_is_complete_in_prototype_header(&mut b);
    pointer_to_array_of_enclosing_aggregate(&mut b);
    b.run();
}

@test
fn exit_cases_04() {
    let mut b = h::ExitBatch::new();
    function_types_substitute_structurally(&mut b);
    function_items_in_tuples_and_fields(&mut b);
    boxed_closures_erase_to_dyn_fn(&mut b);
    widened_operands_compute_at_the_result_width(&mut b);
    const_generic_values_in_constant_evaluation(&mut b);
    constant_of_a_const_expression_instance(&mut b);
    constant_of_a_keyed_operator(&mut b);
    constant_union_puns(&mut b);
    constant_of_an_interface_qualified_call(&mut b);
    constant_of_a_builtin_method_through_a_reference(&mut b);
    array_argument_infers_a_slice_element(&mut b);
    constant_through_a_bound_picks_the_instance_extend(&mut b);
    constant_through_a_cancellation_check(&mut b);
    operator_takes_its_interface_method(&mut b);
    b.run();
}

@test
fn exit_cases_05() {
    let mut b = h::ExitBatch::new();
    bound_call_arguments_resolve_in_the_caller(&mut b);
    constant_through_nested_generic_calls(&mut b);
    f32_to_integer_saturates_at_every_width(&mut b);
    constant_of_an_inherited_default_on_an_instance(&mut b);
    constant_of_an_inherited_default_in_a_generic_function(&mut b);
    conformance_choice_ignores_declaration_order(&mut b);
    qualified_associated_calls_of_generic_extends(&mut b);
    projection_prefers_the_own_conformance(&mut b);
    u64_range_pattern_bounds_past_i64(&mut b);
    call_results_viewed_as_slices(&mut b);
    boxed_dyn_frees_through_its_allocator(&mut b);
    dyn_runs_the_conformance_with_its_arguments(&mut b);
    borrowed_and_owned_erasures_of_one_pair(&mut b);
    b.run();
}

@test
fn exit_cases_06() {
    let mut b = h::ExitBatch::new();
    conformance_selected_by_checked_argument(&mut b);
    conformance_selected_by_expected_result(&mut b);
    bound_calls_run_the_conformance_with_its_arguments(&mut b);
    several_result_fn_values(&mut b);
    array_result_fn_values(&mut b);
    operators_and_associated_types_through_bounds(&mut b);
    operator_operand_widens_before_its_borrow(&mut b);
    associated_functions_through_bounds(&mut b);
    dyn_methods_with_several_results(&mut b);
    inference_from_the_one_fitting_conformance(&mut b);
    inherited_default_of_a_generic_interface(&mut b);
    override_and_inherited_default_compete_by_arguments(&mut b);
    b.run();
}

@test
fn exit_cases_07() {
    let mut b = h::ExitBatch::new();
    self_path_names_the_implementing_type(&mut b);
    dyn_generic_superinterface(&mut b);
    generic_interface_methods_run(&mut b);
    const_argument_selects_an_extend(&mut b);
    builtin_extend_methods_fold_at_compile_time(&mut b);
    method_on_a_turbofished_call(&mut b);
    pointer_order_across_objects(&mut b);
    memmove_overlap_both_directions(&mut b);
    a_reference_to_an_array_parameter_reads_it(&mut b);
    a_generic_method_value_is_its_instance(&mut b);
    checked_byte_views(&mut b);
    tuple_struct_constructor_inference(&mut b);
    closure_in_generic_struct_field(&mut b);
    zeroed_arrays_and_generic_aggregates(&mut b);
    b.run();
}

// An `&dyn I`, `&mut dyn I` or `Box<dyn I>` element of an aggregate literal erases against the type
// the context writes, as a `let`, argument or field does: array and repeat literals, nested arrays, a
// slice parameter, tuples and arrays of tuples. Tuple arguments take their elements' types from the
// parameter. A borrowed `&dyn I` is never freed, wherever it sits; a boxed array frees its elements.
fn dyn_erasure_in_aggregate_literals(b: &mut h::ExitBatch) {
    const PRE: str = M"(interface Sh { fn area(self: &Self) i32; }
struct Row { pub w: i32 }
extend Row as Sh { fn area(self: &Self) i32 { return self.w; } }
fn sum2(a: [&dyn Sh; 2]) i32 { return a[0].area() + a[1].area(); }
fn take(s: []&dyn Sh) i32 { return s[0].area() + s[1].area(); }
struct H<'a> { pub a: [&'a dyn Sh; 2] }
struct M { pub k: i32 }
extend M { fn take(self: &M, t: (&dyn Sh, i32)) i32 { return t.0.area() + t.1 + self.k; } }
struct S<'a> { pub t: (&'a dyn Sh, i32), pub n: ((&'a dyn Sh, i32), i64) }
fn g<T>(t: T) T { return t; }
fn tk(t: (&dyn Sh, i32)) i32 { return t.0.area() + t.1; }
fn nest(t: ((&dyn Sh, i32), i64)) i64 { return (t.0).0.area() as i64 + t.1; }
fn ap(t: (fn(i32) i32, i32)) i32 { return (t.0)(t.1); }
fn f(t: (i64, u8)) i64 { return t.0 + t.1 as i64; }
)";
    let bodies: [](str, str) = [
        (
            "array literal",
            "let r = Row { w: 1 }; let r2 = Row { w: 2 }; let ds: [&dyn Sh; 2] = [&r, &r2]; return ds[0].area() + ds[1].area() - 3;"
        ),
        ("repeat literal", "let r = Row { w: 1 }; let ds: [&dyn Sh; 3] = [&r; 3]; return ds[2].area() - 1;"),
        (
            "nested array literals",
            "let r = Row { w: 1 }; let r2 = Row { w: 2 }; let ds: [[&dyn Sh; 2]; 2] = [[&r, &r2], [&r2, &r]]; return ds[0][1].area() + ds[1][1].area() - 3;"
        ),
        (
            "slice of dyn",
            "let r = Row { w: 1 }; let r2 = Row { w: 2 }; let ds: []&dyn Sh = [&r, &r2]; return take(ds) - 3;"
        ),
        ("array argument", "let r = Row { w: 1 }; let r2 = Row { w: 2 }; return sum2([&r, &r2]) - 3;"),
        ("slice argument", "let r = Row { w: 1 }; let r2 = Row { w: 2 }; return take([&r, &r2]) - 3;"),
        (
            "mutable dyn elements",
            "let mut m = Row { w: 3 }; let ds: [&mut dyn Sh; 1] = [&mut m]; return ds[0].area() - 3;"
        ),
        (
            "boxed dyn elements",
            "let ds: [Box<dyn Sh>; 2] = [Box::new(Row { w: 1 }), Box::new(Row { w: 2 })]; return ds[0].area() + ds[1].area() - 3;"
        ),
        ("tuple literal", "let r = Row { w: 1 }; let t: (&dyn Sh, i32) = (&r, 5); return t.0.area() + t.1 - 6;"),
        (
            "array inside a tuple",
            "let r = Row { w: 1 }; let r2 = Row { w: 2 }; let t: ([&dyn Sh; 2], i32) = ([&r, &r2], 1); return t.0[0].area() + t.0[1].area() - 3;"
        ),
        (
            "array of tuples",
            "let r = Row { w: 1 }; let r2 = Row { w: 2 }; let ds: [(&dyn Sh, i32); 2] = [(&r, 1), (&r2, 2)]; return ds[0].0.area() + ds[1].0.area() - 3;"
        ),
        (
            "vector of borrowed dyn",
            "let r = Row { w: 1 }; let mut v: Vector<&dyn Sh> = Vector::new(); v.push(&r); return v.at(0).area() - 1;"
        ),
        (
            "borrowed dyn in an array element of a vector",
            "let r = Row { w: 1 }; let r2 = Row { w: 2 }; let mut v: Vector<[&dyn Sh; 2]> = Vector::new(); v.push([&r, &r2]); return v.at(0)[1].area() - 2;"
        ),
        (
            "borrowed dyn in a tuple element of a vector",
            "let r = Row { w: 1 }; let mut v: Vector<(&dyn Sh, i32)> = Vector::new(); v.push((&r, 2)); return v.at(0).0.area() + v.at(0).1 - 3;"
        ),
        (
            "borrowed dyn in a boxed tuple",
            "let r = Row { w: 1 }; let t: (&dyn Sh, i32) = (&r, 2); let b: Box<(&dyn Sh, i32)> = Box::new(t); return (*b).0.area() + (*b).1 - 3;"
        ),
        (
            "borrowed dyn in a struct held by a vector",
            "let r = Row { w: 1 }; let r2 = Row { w: 2 }; let mut v: Vector<H> = Vector::new(); v.push(H { a: [&r, &r2] }); return v.at(0).a[1].area() - 2;"
        ),
        (
            "borrowed dyn in a struct held by a box",
            "let r = Row { w: 1 }; let r2 = Row { w: 2 }; let b: Box<H> = Box::new(H { a: [&r, &r2] }); return b.a[0].area() - 1;"
        ),
        (
            "boxed closure capturing a borrowed dyn",
            "let r = Row { w: 1 }; let d: &dyn Sh = &r; let f: Box<dyn fn() i32> = Box::new(move || d.area()); return f() - 1;"
        ),
        (
            "boxed borrowed dyn",
            "let r = Row { w: 1 }; let d: &dyn Sh = &r; let b: Box<&dyn Sh> = Box::new(d); let e: &dyn Sh = *b; return e.area() - 1;"
        ),
        (
            "owned dyn in a box and a vector",
            "let b: Box<dyn Sh> = Box::new(Row { w: 4 }); let mut v: Vector<Box<dyn Sh>> = Vector::new(); v.push(Box::new(Row { w: 4 })); return b.area() + v.at(0).area() - 8;"
        ),
        (
            "box of an array of strings",
            "let a = [String::from_str(\"a\"), String::from_str(\"b\")]; let b = Box::new(a); return (*b)[1].len() as i32 - 1;"
        ),
        (
            "box of an array of boxed dyn",
            "let a: [Box<dyn Sh>; 1] = [Box::new(Row { w: 1 })]; let b = Box::new(a); return (*b)[0].area() - 1;"
        ),
        (
            "box of nested arrays of strings",
            "let a = [[String::from_str(\"a\")], [String::from_str(\"b\")]]; let b = Box::new(a); return (*b)[1][0].len() as i32 - 1;"
        ),
        ("tuple argument", "let r = Row { w: 1 }; return tk((&r, 1)) - 2;"),
        ("tuple method argument", "let r = Row { w: 1 }; let m = M { k: 10 }; return m.take((&r, 2)) - 13;"),
        (
            "tuple pushed to a vector",
            "let r = Row { w: 1 }; let mut v: Vector<(&dyn Sh, i32)> = Vector::new(); v.push((&r, 2)); return v.at(0).1 - 2;"
        ),
        ("nested tuple argument", "let r = Row { w: 1 }; return nest(((&r, 2), 5)) as i32 - 6;"),
        ("tuple with a closure argument", "return ap((|x: i32| x + 1, 2)) - 3;"),
        ("tuple of literals widens to the parameter", "return f((1, 2)) as i32 - 3;"),
        (
            "tuple in a struct literal field",
            "let r = Row { w: 1 }; let s = S { t: (&r, 2), n: ((&r, 3), 4) }; return s.t.0.area() + s.t.1 + (s.n.0).1 - 6;"
        ),
        (
            "tuple through a turbofished call",
            "let r = Row { w: 1 }; let t = g::<(&dyn Sh, i32)>((&r, 2)); return t.1 - 2;"
        ),
    ];
    for i in 0..bodies.len() {
        let mut src = String::from_str(PRE);
        src.push_str("fn main() i32 { ");
        src.push_str(bodies[i].1);
        src.push_str(" }\n");
        b.add(bodies[i].0, src.as_str(), 0);
    }
}

// A binding never takes a spelling the generated C owns: a name with `__` (drop glue, vtables, closure
// environments, the runtime), `_` and an uppercase letter, or a standard type name the body spells.
fn bindings_avoid_generated_spellings(b: &mut h::ExitBatch) {
    b.add(
        "a local named like an array drop index",
        "fn main() i32 { let __sc_i0 = [String::from_str(\"a\")]; return __sc_i0[0].len() as i32 - 1; }\n",
        0,
    );
    b.add(
        "parameters named like generated ones beside an array parameter",
        "fn f(__sc_ap1: i32, __sc_sp1: i32, a: [String; 1]) i32 { return __sc_ap1 + __sc_sp1 + a[0].len() as i32 - 3; }\nfn main() i32 { return f(1, 1, [String::from_str(\"a\")]); }\n",
        0,
    );
    b.add(
        "locals named like the string type and its element type",
        "fn n(s: str) usize { return s.len(); }\nfn main() i32 { let str = 1; let uint8_t = 2; return str + uint8_t + n(\"abc\") as i32 - 6; }\n",
        0,
    );
    b.add(
        "locals named like drop glue and a vtable",
        "interface Sh { fn area(self: &Self) i32; }\nstruct Row { pub w: i32 }\nextend Row as Sh { fn area(self: &Self) i32 { return self.w; } }\nfn main() i32 { let String__free = 1; let Row__Sh__vtbl = 2; let s = String::from_str(\"abc\"); let r = Row { w: 1 }; let d: &dyn Sh = &r; return String__free + Row__Sh__vtbl + s.len() as i32 + d.area() - 7; }\n",
        0,
    );
    b.add(
        "a closure parameter named like the environment",
        "fn main() i32 { let k = 2; let c = |__env: i32| __env + k; return c(1) - 3; }\n",
        0,
    );
    b.add(
        "a local named like the environment beside a capturing closure",
        "fn main() i32 { let __env = 1; let k = 2; let c = || k + 1; return __env + c() - 4; }\n",
        0,
    );
    b.add(
        "locals named like predefined macros",
        "fn main() i32 { let __APPLE__ = 1; let _WIN32 = 2; let __GNUC__ = 3; let __func__ = 4; return __APPLE__ + _WIN32 + __GNUC__ + __func__ - 10; }\n",
        0,
    );
}

@test
fn exit_cases_08() {
    let mut b = h::ExitBatch::new();
    dyn_drop_double_deref_and_assoc_arguments(&mut b);
    box_deref_mut_places(&mut b);
    va_arg_reads_promoted_types(&mut b);
    omitted_c_object_and_union_fields_zero_fill(&mut b);
    zero_length_field_address_is_its_offset(&mut b);
    multi_value_unsafe_call_binds(&mut b);
    array_param_cases(&mut b);
    dyn_erasure_in_aggregate_literals(&mut b);
    bindings_avoid_generated_spellings(&mut b);
    b.run();
}

// A tuple argument fails like the same value in a `let`: a literal out of range, an arity mismatch, an
// element of the wrong type. An array converts to a slice by view only: `as` does not spell it.
@test
fn tuple_arguments_and_array_casts_are_checked() {
    const PRE: str = M"(interface Sh { fn area(self: &Self) i32; }
struct Row { pub w: i32 }
extend Row as Sh { fn area(self: &Self) i32 { return self.w; } }
fn tk(t: (&dyn Sh, i32)) i32 { return t.0.area() + t.1; }
fn f(t: (i64, u8)) i64 { return t.0 + t.1 as i64; }
)";
    let mut src = String::from_str(PRE);
    src.push_str("fn main() i32 { return f((1, 300)) as i32; }\n");
    h::expect_err_msg(
        "a tuple literal out of range for its parameter",
        src.as_str(),
        "integer literal is out of range for 'u8'",
    );
    src = String::from_str(PRE);
    src.push_str("fn main() i32 { let r = Row { w: 1 }; return tk((&r, 1, 2)); }\n");
    h::expect_err_msg("a tuple of the wrong arity", src.as_str(), "mismatched types");
    src = String::from_str(PRE);
    src.push_str("fn main() i32 { return tk((1, 2)); }\n");
    h::expect_err_msg("a tuple element of the wrong type", src.as_str(), "mismatched types");
    src = String::from_str(PRE);
    src.push_str(
        "fn main() i32 { let r = Row { w: 1 }; let r2 = Row { w: 2 }; let a = [&r, &r2]; let s = a as []&dyn Sh; return s[0].area(); }\n",
    );
    h::expect_err_msg("an array cast to a slice of dyn", src.as_str(), "invalid cast from '[&Row; 2]'");
    h::expect_err_msg(
        "an array cast to a slice",
        "fn main() i32 { let a = [1, 2]; let s = a as []i32; return s[1]; }\n",
        "invalid cast from '[i32; 2]'",
    );
}
