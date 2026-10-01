// Self-hosted port of tests/codegen_run_test.c (behavioral end-to-end: each snippet is transpiled, cc-
// compiled, linked and RUN, and its result checked). Programs signal their result via `exit(code)`; the
// harness's compile_and_run builds them through `super-c build` and captures the exit code. This seeds the
// suite with the pure-computation families; the remaining families (slices, strings, closures, generics,
// I/O via putchar) extend it the same way with run_exit / h::expect_run.
import tests::harness as h;
import stdio;
import string as cstring;

const PRE: str = "extern \"C\" { fn exit(code: i32) void; fn putchar(c: i32) i32; }\n";

struct Buf4096 {
    pub b: [char; 4096],
}

// Splice PRE ahead of `body`, build+run the program, and assert it exits with `code`.
fn run_exit(label: str, body: str, code: i32) {
    let mut buf = Buf4096 {};
    unsafe stdio::snprintf(
        &mut buf.b[0],
        4096,
        "%s%s".ptr() as *const char,
        PRE.ptr() as *const char,
        body.ptr() as *const char,
    );
    let src = str::from_raw((&buf.b[0]) as *const u8, unsafe cstring::strlen(&buf.b[0]));
    h::expect_exit(label, src, code);
}

@test
fn operator_overload_lowering() {
    // Compound assignment on an operator-overloaded struct lowers through the method (C cannot += structs).
    run_exit(
        "struct compound assignment",
        "struct P { pub x: i32, }\nextend P { pub fn add(self: &P, o: &P) P { return P { x: self.x + o.x }; } pub fn mul(self: &P, o: &P) P { return P { x: self.x * o.x }; } }\nfn main() i32 { let mut a = P { x: 2 }; let b = P { x: 3 }; a += b; a *= b; unsafe exit(a.x); }\n",
        15,
    );
    // Bitwise and shift operators dispatch the same way. A shift's right operand is a COUNT, so it is
    // passed BY VALUE where `&` passes its operand by reference: the two are lowered differently.
    run_exit(
        "bitwise and shift overloads",
        "struct M { pub b: u32, }\nextend M { pub fn bit_and(self: &M, o: &M) M { return M { b: self.b & o.b }; } pub fn bit_or(self: &M, o: &M) M { return M { b: self.b | o.b }; } pub fn bit_xor(self: &M, o: &M) M { return M { b: self.b ^ o.b }; } pub fn bit_not(self: &M) M { return M { b: ~self.b }; } pub fn shl(self: &M, n: usize) M { return M { b: self.b << n as u32 }; } pub fn shr(self: &M, n: usize) M { return M { b: self.b >> n as u32 }; } }\nfn main() i32 {\n    let a = M { b: 0b1100 };\n    let b = M { b: 0b1010 };\n    let mut acc = a;\n    acc &= b;\n    acc |= M { b: 1 };\n    acc ^= M { b: 2 };\n    acc <<= 2;\n    acc >>= 1;\n    let n = (~a).b & 0xF;\n    unsafe exit(((a & b).b + (a | b).b + (a ^ b).b + (a << 1).b + (a >> 2).b + acc.b + n) as i32);\n}\n",
        80,
    );
    // String patterns in switch compare through str's eq, incl. inside an enum payload.
    run_exit(
        "string switch patterns",
        "fn pick(s: str) i32 { return switch s { \"build\" => 1, \"fmt\" => 2, _ => 3, }; }\nfn pay(o: Option<str>) i32 { return switch o { Some(\"x\") => 10, Some(_) => 20, None => 30, }; }\nfn main() i32 { unsafe exit(pick(\"build\") + pick(\"fmt\") * 2 + pick(\"?\") * 3 + pay(Option::<str>::Some(\"x\")) + pay(Option::<str>::Some(\"y\")) + pay(Option::<str>::None)); }\n",
        74,
    );
    // String range patterns test through str's cmp (lexicographic buckets).
    run_exit(
        "string range patterns",
        "fn bucket(s: str) i32 { return switch s { \"a\"..\"m\" => 1, \"m\"..\"z\" => 2, _ => 3, }; }\nfn main() i32 { unsafe exit(bucket(\"apple\") + bucket(\"pear\") * 2 + bucket(\"~t\") * 3); }\n",
        14,
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
    assert(bad.exit != 0, "a non-matchertext hole value must panic, not splice");
}

@test
fn inlined_callee_keeps_its_guarded_drop() {
    // `f` is small enough to inline into `main` and carries a flag-guarded drop: the splice must
    // rebase the flag local with the callee's locals, or the guard reads a caller local. Under the
    // leak gate a wrong guard is a leak or a double free, both nonzero exits.
    run_exit(
        "inlined guarded drop",
        "pub fn take(s: String) { s.free(); }\npub fn f(c: bool) i32 { let s = String::from_str(\"abc\"); if c { take(s); return 1; } return s.len() as i32; }\nfn main() i32 { unsafe exit(f(true) + f(false)); }\n",
        4,
    );
}

@test
fn arithmetic() {
    run_exit("precedence", "fn main() i32 { unsafe exit(1 + 2 * 3 - 4 / 2); }\n", 5);
    run_exit("mixed precedence", "fn main() i32 { unsafe exit(17 % 5 + 100 / 7 + 6 & 3); }\n", 2);
    run_exit(
        "bitwise",
        "fn main() i32 { let a: i32 = 6 & 3; let b: i32 = 6 | 1; let c: i32 = 1 << 4; unsafe exit(a + b + c); }\n",
        25,
    );
    run_exit("right shift", "fn main() i32 { let mut x: i32 = 32; x >>= 2; unsafe exit(x + (16 >> 2)); }\n", 12);
    run_exit("unary neg", "fn main() i32 { let y: i32 = -5; unsafe exit(0 - y); }\n", 5);
    run_exit("unary not", "fn main() i32 { unsafe exit(switch !false { true => 7, _ => 0, }); }\n", 7);
}

@test
fn control_flow() {
    run_exit(
        "while break",
        "fn main() i32 { let mut i: i32 = 0; while true { if i >= 5 { break; } i = i + 1; } unsafe exit(i); }\n",
        5,
    );
    run_exit(
        "for continue",
        "fn main() i32 { let mut t: i32 = 0; for i in 0..5 { if i == 2 { continue; } t = t + i; } unsafe exit(t); }\n",
        8,
    );
    run_exit(
        "nested for",
        "fn main() i32 { let mut t: i32 = 0; for i in 0..3 { for j in 0..3 { t = t + 1; } } unsafe exit(t); }\n",
        9,
    );
    run_exit(
        "do while",
        "fn main() i32 { let mut i: i32 = 0; let mut s: i32 = 0; do { s = s + i; i = i + 1; } while i < 5; unsafe exit(s); }\n",
        10,
    );
    run_exit(
        "do while runs once",
        "fn main() i32 { let mut n: i32 = 0; do { n = n + 7; } while false; unsafe exit(n); }\n",
        7,
    );
}

@test
fn recursion() {
    // Fib(10)=55, sum 0..9=45.
    run_exit(
        "fib + range sum",
        "fn fib(n: i32) i32 { if n < 2 { return n; } return fib(n - 1) + fib(n - 2); }\nfn main() i32 { let mut s: i32 = 0; for i in 0..10 { s = s + i; } unsafe exit(fib(10) - s); }\n",
        10,
    );
}

@test
fn float_constants_exact() {
    // Folded float consts and static float slots keep every bit: each is compared at run time with
    // the value libc parses (or computes) from the same text, and infinity and NaN stay valid C.
    run_exit(
        "exact float consts and statics",
        "extern \"C\" { fn strtod(s: *const char, e: *mut *mut char) f64; }\nstruct P { pub a: f64, pub b: f32 }\nconst PI: f64 = 3.14159265358979;\nconst TAU: f64 = PI * 2.0;\nconst F: f32 = 0.1;\nconst PINF: f64 = PI * 1e308;\nconst QNAN: f64 = PINF - PINF;\nstatic mut SP: P = P { a: PI / 7.0, b: 0.1 };\nfn rd(s: str) f64 { return unsafe strtod(s.ptr() as *const char, null); }\nfn main() i32 {\n    let pi = rd(\"3.14159265358979\");\n    let q = QNAN + pi;\n    let mut bad = 0;\n    if PI != pi { bad |= 1; }\n    if TAU != pi * 2.0 { bad |= 2; }\n    if F != rd(\"0.1\") as f32 { bad |= 4; }\n    if PINF <= pi * 1e300 || q == q { bad |= 8; }\n    if unsafe SP.a != pi / 7.0 || unsafe SP.b != rd(\"0.1\") as f32 { bad |= 16; }\n    unsafe exit(bad);\n}\n",
        0,
    );
}

@test
fn switches() {
    run_exit(
        "switch literal + name binding",
        "fn classify(c: i32) i32 { return switch c { 0 => 100, 7 => 7, n => n + 1, }; }\nfn main() i32 { unsafe exit(classify(41)); }\n",
        42,
    );
    run_exit(
        "switch ranges",
        "fn s(n: i32) i32 { return switch n { 0..10 => 1, 10..=20 => 2, _ => 3, }; }\nfn main() i32 { unsafe exit(s(15)); }\n",
        2,
    );
    run_exit(
        "switch char range",
        "fn d(c: char) i32 { return switch c { '0'..='9' => 1, _ => 0, }; }\nfn main() i32 { unsafe exit(d('7')); }\n",
        1,
    );
    run_exit(
        "switch or-pattern",
        "fn k(c: i32) i32 { return switch c { 1 | 2 | 3 => 10, 4..=9 | 20 => 20, _ => 0, }; }\nfn main() i32 { unsafe exit(k(2) + k(20) + k(99)); }\n",
        30,
    );
}

// An explicit discriminant may name an earlier variant of its own enum, a variant of another enum,
// or a constant: the value is the same in a constant, a static_assert, the emitted C enum, a cast and
// a switch, and the next implicit discriminant follows it.
@test
fn enum_discriminant_references() {
    run_exit(
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

// A reference inside a constant or static to another constant or static is the address of that
// item's emitted storage: a whole item, an element or a field of it, a slice of it, a `str`, a chain
// of references, one returned by a `const fn`, and a `static mut`. A temporary gets its own storage.
@test
fn constant_references_address_items() {
    const SRC: str = M"(extern "C" { fn exit(code: i32) void; }
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
    unsafe exit(bad);
}
)";
    h::expect_exit("references to constants and statics inside constants", SRC, 0);
    h::expect_c("a reference to a constant addresses its storage", SRC, "R CR = { .r = (void *)&K };");
    h::expect_c("a reference to a static addresses its storage", SRC, "int32_t *PC = (void *)&CNT;");
    h::expect_c("a field reference addresses the field", SRC, ".e = (void *)&PP.y[2]");
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
@test
fn local_constants_of_one_name() {
    run_exit(
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
    run_exit(
        "heap struct via new",
        "extern \"C\" { fn free(pt: *mut void) void; }\nstruct Box { pub v: i32, }\nfn main() i32 { let b: *Box = new Box { v: 9, }; let r = unsafe (*b).v; unsafe free(b as *mut void); unsafe exit(r); }\n",
        9,
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

// A `[T; N]` parameter is a VALUE, but C hands the callee a pointer to the caller's array. A `mut` one
// must therefore be copied into a local on entry, or writes in the callee reach the caller.
@test
fn mut_array_param_is_a_copy() {
    h::expect_exit(
        "writing a mut array parameter leaves the caller's array alone",
        "fn f(mut a: [i32; 2]) i32 { a[0] = 9; return a[0]; }\nfn main() i32 {\n    let v: [i32; 2] = [3, 0];\n    let r = f(v);\n    return r - 9 + v[0] - 3;\n}\n",
        0,
    );
    h::expect_exit(
        "the copy is per call, not shared",
        "fn bump(mut a: [i32; 1]) i32 { a[0] = a[0] + 1; return a[0]; }\nfn main() i32 {\n    let v: [i32; 1] = [5];\n    return bump(v) + bump(v) - 12;\n}\n",
        0,
    );
    h::expect_exit(
        "a non-mut array parameter still reads the caller's elements",
        "fn sum(a: [i32; 3]) i32 { return a[0] + a[1] + a[2]; }\nfn main() i32 {\n    let v: [i32; 3] = [1, 2, 3];\n    return sum(v) - 6;\n}\n",
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
    h::expect_c("the owning instance frees its parameter", src, "String__free(&x);");
    h::expect_c("the scalar instance is empty", src, "drop_it__i64(int64_t x) {\n  return;\n}");
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

@test
fn compile_time_layout_and_zero_sized_maps() {
    // Nested instances of one generic lay out at compile time (they are no by-value cycle), and a
    // map or box of zero-sized values folds: its storage is the dangling sentinel.
    h::expect_exit(
        "nested instances and zero-sized values at compile time",
        "struct W<T> { pub v: T }\nstruct Z {}\nstatic_assert(sizeof(W<W<W<i32>>>) == 4, \"nested instances lay out\");\nconst fn count() usize {\n    let mut m = Map::<u32, Z>::new();\n    for i in 0..40u32 {\n        m.insert(i % 20, Z {});\n    }\n    let mut b = Box::<Z>::new(Z {});\n    b.set(Z {});\n    return m.len();\n}\nstatic_assert(count() == 20, \"a map of zero-sized values folds\");\nfn main() i32 { let w = W::<W<i32>> { v: W::<i32> { v: 5 } }; return w.v.v - 5; }\n",
        0,
    );
}

// A closure inside a generic function is monomorphized WITH that function: one C function per
// instantiation, so its parameter, return and capture types follow the type arguments.
@test
fn closures_in_generic_fns() {
    h::expect_exit(
        "a closure over the type parameter, at two instantiations",
        "fn twice<T>(v: T) T {\n    let f = fn(x: T) T { return x; };\n    return f(v);\n}\nfn main() i32 { return twice(3) - 3 + (twice(4i64) as i32) - 4; }\n",
        0,
    );
    h::expect_exit(
        "a closure capturing a generic value",
        "fn hold<T: Copy>(v: T) T {\n    let f = fn() T { return v; };\n    return f();\n}\nfn main() i32 { return hold(7) - 7; }\n",
        0,
    );
    h::expect_exit(
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
}

// `From<[]T>` on the containers: an array literal coerces to the slice, so a list of elements builds a
// container through `.into()` or the explicit `from`. The slice BORROWS, so elements are cloned in and
// the source keeps its own: a Free element type must not end up with two owners.
@test
fn container_from_list() {
    h::expect_exit(
        "a Vector comes from a list of elements",
        "fn main() i32 {\n    let v: Vector<i32> = [1, 2, 3, 4, 5].into();\n    let mut t = 0;\n    for i in 0..v.len() { t = t + *v.at(i); }\n    return t - 15;\n}\n",
        0,
    );
    h::expect_exit(
        "the explicit 'from' names the same conversion",
        "fn main() i32 {\n    let v = Vector::<i32>::from([1, 2, 3]);\n    return (v.len() as i32) - 3;\n}\n",
        0,
    );
    h::expect_exit(
        "a Set collapses duplicates",
        "fn main() i32 {\n    let s: Set<i32> = [1, 2, 2, 3].into();\n    return (s.len() as i32) - 3;\n}\n",
        0,
    );
    h::expect_exit(
        "a Map comes from a list of pairs",
        "fn main() i32 {\n    let m: Map<i32, i32> = [(1, 10), (2, 20)].into();\n    return (m.len() as i32) - 2 + *m.get(&2).unwrap() - 20;\n}\n",
        0,
    );
    h::expect_exit(
        "a Free element type is cloned in, not shared",
        "fn main() i32 {\n    let v: Vector<String> = [String::from_str(\"ab\"), String::from_str(\"cde\")].into();\n    return (v.at(0).len() + v.at(1).len()) as i32 - 5;\n}\n",
        0,
    );
}

// A temporary that OWNS memory is freed whichever way it is used. A method call on one already bound
// and freed it; a field read did not, so the owner was dropped on the floor and its allocation leaked.
@test
fn free_temporary_field_read() {
    h::expect_exit(
        "a field read from an owning temporary frees it",
        "struct R { pub v: i32, pub buf: Vector<i32> }\nextend R { pub fn get(self: &R) i32 { return self.v; } }\nfn mk() R {\n    let mut b = Vector::<i32>::new();\n    b.push(1);\n    return R { v: 7, buf: b };\n}\nfn main() i32 { return mk().v - 7; }\n",
        0,
    );
    h::expect_exit(
        "a method call on one still does",
        "struct R { pub v: i32, pub buf: Vector<i32> }\nextend R { pub fn get(self: &R) i32 { return self.v; } }\nfn mk() R {\n    let mut b = Vector::<i32>::new();\n    b.push(1);\n    return R { v: 7, buf: b };\n}\nfn main() i32 { return mk().get() - 7; }\n",
        0,
    );
    h::expect_c(
        "the temporary is bound around the field read",
        "struct R { pub v: i32, pub buf: Vector<i32> }\nextend R { pub fn get(self: &R) i32 { return self.v; } }\nfn mk() R {\n    let mut b = Vector::<i32>::new();\n    b.push(1);\n    return R { v: 7, buf: b };\n}\nfn main() i32 { return mk().v - 7; }\n",
        "R__free__d(&",
    );
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
@test
fn prelude_call_inside_generic_body() {
    h::expect_exit(
        "a prelude call in a generic body",
        "fn pick<T>(v: T, take: bool) T {\n    if !take { panic(\"no\"); }\n    return v;\n}\nfn main() i32 { return pick(0, true); }\n",
        0,
    );
    h::expect_exit(
        "two instantiations of the same body",
        "fn pick<T>(v: T, take: bool) T {\n    if !take { panic(\"no\"); }\n    return v;\n}\nfn main() i32 { return pick(0, true) + pick(0i64, true) as i32; }\n",
        0,
    );
    h::expect_exit(
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
@test
fn sso_budget_follows_pointer_width() {
    h::expect_exit(
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
@test
fn const_generic_array_length_inferred() {
    h::expect_exit(
        "inferred from an array literal",
        "fn width<const N: usize>(a: [i32; N]) usize { return N; }\nfn main() i32 { return width([1, 2, 3]) as i32 - 3; }\n",
        0,
    );
    h::expect_exit(
        "inferred from a typed local",
        "fn width<const N: usize>(a: [i32; N]) usize { return N; }\nfn main() i32 {\n    let a: [i32; 2] = [1, 2];\n    return width(a) as i32 - 2;\n}\n",
        0,
    );
    h::expect_exit(
        "two lengths make two instances",
        "fn width<const N: usize>(a: [i32; N]) usize { return N; }\nfn main() i32 { return (width([1]) + width([1, 2, 3, 4])) as i32 - 5; }\n",
        0,
    );
    h::expect_exit(
        "an explicit argument still wins",
        "fn width<const N: usize>(a: [i32; N]) usize { return N; }\nfn main() i32 { return width::<3>([1, 2, 3]) as i32 - 3; }\n",
        0,
    );
}

@test
fn tuple_structs_byte_strings_and_slice_for() {
    // Tuple-struct construction lowers to positional aggregate init; reads spell `._N` in C.
    h::expect_exit(
        "tuple struct positional fields",
        "struct Wrap(i32, bool);\nfn main() i32 { let w = Wrap(30, true); let mut r = w.0; if w.1 { r += 5; } return r - 35; }\n",
        0,
    );
    // Generic tuple struct: element types bind under the instance's generic args.
    h::expect_exit(
        "generic tuple struct",
        "struct Pair<A, B>(A, B);\nfn main() i32 { let p = Pair::<i32, i32>(9, 4); return p.0 - p.1 - 5; }\n",
        0,
    );
    // `for value in slice` reads the length through the slice's runtime `.len`, not a static count.
    h::expect_exit(
        "for value in slice",
        "fn main() i32 {\n    let a: [i32; 4] = [1, 2, 3, 4];\n    let s: []i32 = a[0..4];\n    let mut t = 0;\n    for v in s { t += v; }\n    return t - 10;\n}\n",
        0,
    );
    // Byte-string literal: the `b` prefix is stripped and the bytes re-emit as a valid C string view.
    h::expect_exit(
        "byte string literal",
        "fn main() i32 { let b = b\"AB\"; return (b[0] as i32) + (b[1] as i32) - 131; }\n",
        0,
    );
    // Tuple index then method: `0.len` must lex as an index access, not a malformed float.
    h::expect_exit(
        "tuple index chained method",
        "struct Words<'a>([]'a i32);\nfn main() i32 { let a: [i32; 3] = [4, 5, 6]; let w = Words(a[0..3]); return w.0.len() as i32 - 3; }\n",
        0,
    );
    // A tuple struct wrapping an owner gets an auto-derived destructor; the leak gate would fail if
    // the field were skipped. The string must be long enough to HEAP-allocate (past SSO), or a leak
    // of the field would be invisible.
    h::expect_exit(
        "tuple struct frees its owner",
        "struct Owned(String);\nfn main() i32 { let o = Owned(String::from_str(\"abcdefghijklmnopqrstuvwxyz0123456789\")); return o.0.len() as i32 - 36; }\n",
        0,
    );
    // escape decoding: `\\xNN` is exactly two hex digits (C would read `\\x41B` greedily); `\\u{..}`
    // becomes UTF-8 bytes (C rejects the syntax outright).
    h::expect_exit(
        "byte-string escapes decode to bytes",
        "fn main() i32 { let b = b\"\\x41B\"; let u = b\"\\u{41}\"; return (b[0] as i32) + (b[1] as i32) + (u[0] as i32) - 196; }\n",
        0,
    );
    // A tuple-struct constructor folds at compile time (a `const`/`static_assert` requires it).
    h::expect_exit(
        "tuple struct const-evaluates",
        "struct Pt(i32, i32);\nconst C: Pt = Pt(20, 22);\nstatic_assert(C.0 + C.1 == 42, \"tuple const eval\");\nfn main() i32 { return C.0 + C.1 - 42; }\n",
        0,
    );
    // zeroed::<TupleStruct>() must allocate one slot per positional member (a field-count of 0 wrote
    // out of bounds and crashed the compiler).
    h::expect_exit(
        "zeroed tuple struct",
        "struct Zt(i32, i32);\nconst Z: Zt = unsafe zeroed::<Zt>();\nstatic_assert(Z.0 == 0 && Z.1 == 0, \"zeroed tuple\");\nfn main() i32 { return Z.0 + Z.1; }\n",
        0,
    );
    // A fixed-array tuple member: constructing it needs the array-store path, and coercing `w.0` to a
    // slice needs the positional array-length recovery (both were struct-only).
    h::expect_exit(
        "tuple struct fixed-array member coerces to slice",
        "struct Wrap([i32; 3]);\nfn sum(s: []i32) i32 { return s[0] + s[1] + s[2]; }\nfn main() i32 { let w = Wrap([1, 2, 3]); return sum(w.0) - 6; }\n",
        0,
    );
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

@test
fn names_that_are_standard_macros() {
    // Fields, payload members, locals, parameters, functions, consts and enum tags spelled like macros
    // of the standard headers every TU includes (complex.h `I`, errno.h `errno` and `EPERM`, stdio.h
    // `EOF` and `stdin`, stddef.h `NULL`, stdlib.h `EXIT_FAILURE`, tgmath.h `log`) get escaped C
    // names; an extern keeps its C name (`sqrt`).
    run_exit(
        "standard macro names",
        "extern \"C\" { fn sqrt(x: f64) f64; }\nenum P { I(i32), errno(i32), EOF { log: i32, NULL: i32 } }\nenum EXIT { SUCCESS, FAILURE }\nstruct S { pub I: i32, pub errno: i32, pub stdin: i32, pub INFINITY: i32, pub log: fn(i32) i32 }\nfn twice(v: i32) i32 { return v * 2; }\nfn I(errno: i32) i32 { let EOF = errno + 1; let NULL = EOF; return NULL; }\nfn log(x: i32) i32 { return x + 1; }\nconst EPERM: i32 = 3;\nfn main() i32 {\n    let s = S { I: 1, errno: 2, stdin: 3, INFINITY: 4, log: twice };\n    let bool = s.I + s.errno + s.stdin + s.INFINITY;\n    let p = P::EOF { log: 4, NULL: 5 };\n    let q = switch p { I(v) => v, errno(v) => v, EOF { log, NULL } => log + NULL };\n    let z = switch EXIT::FAILURE { SUCCESS => 0, FAILURE => 1 };\n    let r = unsafe sqrt(16.0) as i32;\n    unsafe exit(bool + q + z + I(1) + (s.log)(3) + log(1) + EPERM + r);\n}\n",
        37,
    );
}

@test
fn names_that_c_headers_declare() {
    // Root-module items spelled like functions and types the included C headers declare (stdlib.h
    // `malloc`, `abs`, `exit` and `free`, stdio.h `printf` and `FILE`, time.h `tm`) get escaped C
    // names; an extern keeps its C name (`labs`).
    h::expect_exit(
        "C library names",
        "extern \"C\" { fn labs(x: i64) i64; }\nstruct FILE { pub fd: i32 }\nstruct tm { pub h: i32 }\nfn malloc(n: usize) usize { return n + 1; }\nfn abs(x: i32) i32 { if x < 0 { return 0 - x; } return x; }\nfn printf(x: i32) i32 { return x * 2; }\nfn exit(code: i32) i32 { return code + 3; }\nfn free(f: FILE) i32 { return f.fd; }\nfn time() tm { return tm { h: 7 }; }\nfn main() i32 {\n    let f = FILE { fd: 4 };\n    let l = unsafe labs(-5) as i32;\n    return malloc(1) as i32 + abs(-3) + printf(5) + exit(1) + free(f) + time().h + l;\n}\n",
        35,
    );
}

// A use that reads an array constant as a slice types the use node as the slice, not the constant:
// the constant keeps its array storage, so an index into it and a slice view of it both work.
@test
fn array_const_read_as_slice_keeps_array_storage() {
    h::expect_exit(
        "a slice view and an index of one array constant",
        "const NAMES: [str<'static>; 3] = [\"x\", \"yy\", \"zzz\"];\nfn main() i32 {\n    let n: []str = NAMES;\n    return (NAMES[2].len() + n.len()) as i32 - 6;\n}\n",
        0,
    );
}

// A `[]'static str` result views a constant array: it outlives every caller.
@test
fn static_slice_result() {
    h::expect_exit(
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
@test
fn question_moves_a_free_payload() {
    run_leak_free(
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
@test
fn for_over_array_literal() {
    run_leak_free(
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
@test
fn for_over_generic_array_consumes_owning_elements() {
    run_leak_free(
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
@test
fn array_of_free_elements_drops_each() {
    run_leak_free(
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
@test
fn closures_mutate_and_borrow_captures_through_bounds() {
    run_leak_free(
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
@test
fn nested_array_literals_store_by_slot() {
    run_leak_free(
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
@test
fn array_values_copy_into_aggregates() {
    run_leak_free(
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
@test
fn uncovered_conditional_free_instances_derive() {
    run_leak_free(
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
@test
fn function_pointer_results_and_double_references() {
    run_leak_free(
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
@test
fn switch_frees_unbound_scrutinee_parts() {
    run_leak_free(
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
@test
fn array_literal_elements_take_the_expected_type() {
    run_leak_free(
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
    run_leak_free(
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
@test
fn flagged_drop_keeps_array_local_names() {
    run_leak_free(
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
@test
fn array_parameter_element_is_complete_in_prototype_header() {
    h::expect_exit(
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
@test
fn pointer_to_array_of_enclosing_aggregate() {
    h::expect_exit(
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
    h::expect_exit(
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
    h::expect_exit(
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
    run_leak_free(
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
@test
fn function_types_substitute_structurally() {
    run_leak_free(
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
    run_leak_free(
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
@test
fn function_items_in_tuples_and_fields() {
    h::expect_exit(
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
@test
fn boxed_closures_erase_to_dyn_fn() {
    run_leak_free(
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
@test
fn widened_operands_compute_at_the_result_width() {
    h::expect_exit(
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
@test
fn const_generic_values_in_constant_evaluation() {
    h::expect_exit(
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

// A range pattern whose bound is past i64 (a u64 value above i64::MAX) is no compiler crash.
@test
fn u64_range_pattern_bounds_past_i64() {
    h::expect_exit(
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
@test
fn call_results_viewed_as_slices() {
    run_leak_free(
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
@test
fn boxed_dyn_frees_through_its_allocator() {
    run_leak_free(
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
@test
fn dyn_runs_the_conformance_with_its_arguments() {
    run_leak_free(
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
@test
fn borrowed_and_owned_erasures_of_one_pair() {
    run_leak_free(
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
@test
fn conformance_selected_by_checked_argument() {
    run_exit(
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
@test
fn conformance_selected_by_expected_result() {
    run_exit(
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
    run_exit(
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
@test
fn bound_calls_run_the_conformance_with_its_arguments() {
    run_leak_free(
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
@test
fn several_result_fn_values() {
    run_leak_free(
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
@test
fn array_result_fn_values() {
    run_leak_free(
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
@test
fn operators_and_associated_types_through_bounds() {
    run_leak_free(
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
@test
fn operator_operand_widens_before_its_borrow() {
    run_leak_free(
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
@test
fn associated_functions_through_bounds() {
    run_leak_free(
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
@test
fn dyn_methods_with_several_results() {
    run_leak_free(
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
@test
fn inference_from_the_one_fitting_conformance() {
    run_leak_free(
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
@test
fn inherited_default_of_a_generic_interface() {
    run_leak_free(
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
@test
fn override_and_inherited_default_compete_by_arguments() {
    run_leak_free(
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
@test
fn self_path_names_the_implementing_type() {
    run_leak_free(
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
@test
fn dyn_generic_superinterface() {
    run_leak_free(
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
@test
fn generic_interface_methods_run() {
    run_leak_free(
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
@test
fn const_argument_selects_an_extend() {
    run_leak_free(
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
@test
fn builtin_extend_methods_fold_at_compile_time() {
    run_leak_free(
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
@test
fn method_on_a_turbofished_call() {
    run_leak_free(
        "a call on a turbofished call's result",
        "struct N { pub s: String }\nextend N { pub fn get(self: &Self) i64 { return self.s.len() as i64; } }\nstruct X { pub k: i32 }\nextend X { pub fn m<U>(self: &Self, u: U) N { return N { s: String::from_str(\"abc\") }; } }\nfn main() i32 { let x = X { k: 1 }; return x.m::<u8>(1).get() as i32 - 3; }\n",
        0,
    );
}
