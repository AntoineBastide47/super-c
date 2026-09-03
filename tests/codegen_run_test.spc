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
        "extern \"C\" { fn free(pt: *mut void) void; }\nstruct Box { pub v: i32, }\nfn main() i32 { let b: *Box = new Box { v: 9, }; let r = unsafe b.v; unsafe free(b as *mut void); unsafe exit(r); }\n",
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
        "fn hold<T>(v: T) T {\n    let f = fn() T { return v; };\n    return f();\n}\nfn main() i32 { return hold(7) - 7; }\n",
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
        "struct Words([]i32);\nfn main() i32 { let a: [i32; 3] = [4, 5, 6]; let w = Words(a[0..3]); return w.0.len() as i32 - 3; }\n",
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
