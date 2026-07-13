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
    run_exit(
        "fib + range sum",
        "fn fib(n: i32) i32 { if n < 2 { return n; } return fib(n - 1) + fib(n - 2); }\nfn main() i32 { let mut s: i32 = 0; for i in 0..10 { s = s + i; } unsafe exit(fib(10) - s); }\n",
        10,
    ); // fib(10)=55, sum 0..9=45
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
        "struct Box { pub v: i32, }\nfn main() i32 { let b: *Box = new Box { v: 9, }; unsafe exit(b.v); }\n",
        9,
    );
}

@test
fn const_generics() {
    run_exit(
        "distinct const-generic instances + value use",
        "struct Buff<T, const N: usize> { pub b: [T; N] }\nextend<T, const N: usize> Buff<T, N> { fn cap(self: &Self) usize { return N; } }\nfn main() i32 {\n  let a = Buff::<i32, 4> { b: [1, 2, 3, 4] };\n  let c = Buff::<i32, 8> { b: [0, 0, 0, 0, 0, 0, 0, 9] };\n  unsafe exit(a.b[0] + a.b[3] + c.b[7] + a.cap() as i32 + c.cap() as i32);\n}\n",
        26,
    ); // 1 + 4 + 9 + a.cap()=4 + c.cap()=8
}

@test
fn mut_match_binding() {
    run_exit(
        "mut binding: &mut self method + reassign",
        "struct C { pub n: i32 }\nextend C { fn bump(self: &mut C) { self.n = self.n + 1; } fn get(self: &C) i32 { return self.n; } }\nenum Opt { None, Some(C), }\nfn main() i32 {\n  let o = Opt::Some(C { n: 5 });\n  unsafe exit(switch o { Some(mut c) => { c.bump(); c.bump(); c = C { n: c.get() + 1 }; c.get(); }, None => { 0; }, });\n}\n",
        8,
    );
}
