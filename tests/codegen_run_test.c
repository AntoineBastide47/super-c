// End-to-end soundness: each program is transpiled, the generated C is compiled warning-clean
// under -Werror -fsanitize=undefined,address, then executed; the process exit code (and stdout
// where relevant) is asserted. This proves the emitted C is correct, not merely plausible -- the
// gap the substring-only codegen_test.c cannot close.
//
// Scope note: enum/tuple values still lack full construction syntax (covered structurally in
// codegen_test.c), but arrays and slices are now behaviorally exercised here -- `[]T`/`[]mut T` lower
// to the prelude Slice<T>/SliceMut<T> views, constructible by array->slice coercion (see test_slices).

#include "test_harness.h"

#define PRE "extern \"C\" { fn exit(code: i32) void; fn putchar(c: i32) i32; }\n"

static void test_arithmetic(void) {
  sc_run_program("precedence", PRE "fn main() i32 { exit(1 + 2 * 3 - 4 / 2); }\n", 5, "");
  sc_run_program("mixed precedence", PRE "fn main() i32 { exit(17 % 5 + 100 / 7 + 6 & 3); }\n", 2, "");
  sc_run_program(
      "bitwise",
      PRE "fn main() i32 { let a: i32 = 6 & 3; let b: i32 = 6 | 1; let c: i32 = 1 << 4; exit(a + b + c); }\n", 25, "");
  sc_run_program("unary neg", PRE "fn main() i32 { let y: i32 = -5; exit(0 - y); }\n", 5, "");
  sc_run_program("unary not", PRE "fn main() i32 { exit(switch !false { true => 7, _ => 0, }); }\n", 7, "");
}

static void test_control_flow(void) {
  sc_run_program(
      "while break",
      PRE "fn main() i32 { let mut i: i32 = 0; while true { if i >= 5 { break; } i = i + 1; } exit(i); }\n", 5, "");
  sc_run_program(
      "for continue",
      PRE "fn main() i32 { let mut t: i32 = 0; for i in 0..5 { if i == 2 { continue; } t = t + i; } exit(t); }\n", 8,
      "");
  sc_run_program(
      "nested for",
      PRE "fn main() i32 { let mut t: i32 = 0; for i in 0..3 { for j in 0..3 { t = t + 1; } } exit(t); }\n", 9, "");
  sc_run_program( // body runs once before the test: sum 0+1+2+3+4 = 10
      "do while",
      PRE "fn main() i32 { let mut i: i32 = 0; let mut s: i32 = 0; do { s = s + i; i = i + 1; } while i < 5; exit(s); }\n",
      10, "");
  sc_run_program( // do-while body always runs at least once even when the condition is false up front
      "do while runs once",
      PRE "fn main() i32 { let mut n: i32 = 0; do { n = n + 7; } while false; exit(n); }\n", 7, "");
}

static void test_recursion(void) {
  sc_run_program(
      "fib + range sum",
      PRE "fn fib(n: i32) i32 { if n < 2 { return n; } return fib(n - 1) + fib(n - 2); }\n"
          "fn main() i32 { let mut s: i32 = 0; for i in 0..10 { s = s + i; } exit(fib(10) - s); }\n",
      10, ""); // fib(10)=55, sum 0..9=45
}

static void test_switch(void) {
  sc_run_program(
      "switch literal + name binding",
      PRE "fn classify(c: i32) i32 { return switch c { 0 => 100, 7 => 7, n => n + 1, }; }\n"
          "fn main() i32 { exit(classify(41)); }\n",
      42, "");
  sc_run_program(
      "switch ranges",
      PRE "fn s(n: i32) i32 { return switch n { 0..10 => 1, 10..=20 => 2, _ => 3, }; }\n"
          "fn main() i32 { exit(s(15)); }\n",
      2, "");
  sc_run_program(
      "switch char range",
      PRE "fn d(c: char) i32 { return switch c { '0'..='9' => 1, _ => 0, }; }\n"
          "fn main() i32 { exit(d('7')); }\n",
      1, "");
  sc_run_program( // or-pattern: literals + a range alternative all map to one arm
      "switch or-pattern",
      PRE "fn k(c: i32) i32 { return switch c { 1 | 2 | 3 => 10, 4..=9 | 20 => 20, _ => 0, }; }\n"
          "fn main() i32 { exit(k(2) + k(20) + k(99)); }\n",
      30, ""); // 10 + 20 + 0
}

static void test_structs_and_methods(void) {
  sc_run_program(
      "method dispatch (&self / &mut self)",
      PRE "struct Point { pub x: i32, pub y: i32, }\n"
          "extend Point {\n"
          "  fn sum(self: &Point) i32 { return self.x + self.y; }\n"
          "  fn shift(self: &mut Point, d: i32) void { self.x = self.x + d; self.y = self.y + d; }\n"
          "}\n"
          "fn main() i32 { let mut p: Point = Point { x: 3, y: 4, }; p.shift(10); exit(p.sum()); }\n",
      27, "");
  sc_run_program(
      "nested struct field access",
      PRE "struct Inner { pub v: i32, }\n"
          "struct Outer { pub inner: Inner, }\n"
          "fn main() i32 { let o: Outer = Outer { inner: Inner { v: 7, }, }; exit(o.inner.v); }\n",
      7, "");
  sc_run_program(
      "heap struct via new",
      PRE "struct Box { pub v: i32, }\n"
          "fn main() i32 { let b: *Box = new Box { v: 9, }; exit(b.v); }\n",
      9, "");
}

// A `mut` payload binding (`Some(mut x) =>`) is emitted non-const, so `&mut self` methods and
// reassignment work on it -- the gap that blocked the stdio::File switch pattern.
static void test_mut_match_binding(void) {
  sc_run_program(
      "mut binding: &mut self method + reassign",
      PRE "struct C { pub n: i32 }\n"
          "extend C { fn bump(self: &mut C) { self.n = self.n + 1; } fn get(self: &C) i32 { return self.n; } }\n"
          "enum Opt { None, Some(C), }\n"
          "fn main() i32 {\n"
          "  let o = Opt::Some(C { n: 5 });\n"
          "  exit(switch o { Some(mut c) => { c.bump(); c.bump(); c = C { n: c.get() + 1 }; c.get(); }, None => { 0; }, });\n"
          "}\n", // 5 -> bump,bump = 7 -> reassign to 8
      8, NULL);
}

static void test_enums(void) {
  // payload-less enum: matching a bare variant name now tests the tag (it used to always take
  // the first arm and miscompile to `if (1)` + an unused binding).
  sc_run_program(
      "plain enum match",
      PRE "enum Color { Red, Green, Blue, }\n"
          "fn code(c: Color) i32 { return switch c { Red => 1, Green => 2, Blue => 3, }; }\n"
          "fn main() i32 { exit(code(Color::Blue)); }\n",
      3, "");
  // tagged enum: Enum::Variant(args) construction + payload binding in the match.
  sc_run_program(
      "tagged enum construct + match",
      PRE "enum Shape { Dot, Circle(i32), Rect(i32, i32), }\n"
          "fn area(s: Shape) i32 { return switch s { Dot => 0, Circle(r) => r * r, Rect(w, h) => w * h, }; }\n"
          "fn main() i32 { exit(area(Shape::Circle(5)) + area(Shape::Rect(3, 4))); }\n",
      37, ""); // 25 + 12
  // a unit variant of a tagged enum, used as a value.
  sc_run_program(
      "tagged enum unit variant value",
      PRE "enum Opt { None, Some(i32), }\n"
          "fn unwrap(o: Opt) i32 { return switch o { None => 0, Some(v) => v, }; }\n"
          "fn main() i32 { let a: Opt = Opt::None; let b: Opt = Opt::Some(9); exit(unwrap(a) + unwrap(b)); }\n",
      9, "");
  // explicit discriminants on a plain enum, read back via an enum->int cast.
  sc_run_program(
      "explicit discriminants",
      PRE "enum Code { Ok = 0, NotFound = 404, }\nfn main() i32 { exit(Code::NotFound as i32 - 397); }\n", 7, "");
}

static void test_if_expression(void) {
  // if/else-if/else chain as a value: each arm's tail expression yields the block value.
  sc_run_program(
      "if expression chain",
      PRE "fn classify(n: i32) i32 {\n"
          "  let label: i32 = if n > 10 { 100; } else if n > 5 { 50; } else { 1; };\n"
          "  return label + (if n > 0 { 7; } else { 0; });\n"
          "}\n"
          "fn main() i32 { exit(classify(8)); }\n",
      57, ""); // n=8 -> 50 + 7
  // an if-expression directly in a call argument / return position.
  sc_run_program(
      "if expression in return",
      PRE "fn pick(b: bool) i32 { return if b { 9; } else { 4; }; }\n"
          "fn main() i32 { exit(pick(true) + pick(false)); }\n",
      13, "");
}

static void test_tuple_destructure(void) {
  // `let (q, r) = f()` binds each name to the matching return value of a multi-value call.
  sc_run_program(
      "tuple destructure",
      PRE "fn divmod(a: i32, b: i32) (i32, i32) { return a / b, a % b; }\n"
          "fn main() i32 { let (q, r) = divmod(17, 5); exit(q * 10 + r); }\n",
      32, ""); // 3*10 + 2
  // a mutable tuple binding can be reassigned.
  sc_run_program(
      "mutable tuple destructure",
      PRE "fn divmod(a: i32, b: i32) (i32, i32) { return a / b, a % b; }\n"
          "fn main() i32 { let mut (a, b) = divmod(100, 7); a = a + 1; exit(a + b); }\n",
      17, ""); // (14+1) + 2
}

// `[]T`/`[]mut T` lower to the prelude Slice<T>/SliceMut<T> fat pointers: methods, indexing, iteration,
// and array->slice coercion (identifier, literal, mutable) all execute against real backing storage.
static void test_slices(void) {
  // array identifier coerces to `[]i32`; summed via for-loop iteration.
  sc_run_program(
      "slice for-loop + array coercion",
      PRE "fn sum(s: []i32) i32 { let mut t = 0; for x in s { t = t + x; } return t; }\n"
          "fn main() i32 { let a: [i32; 4] = [1, 2, 3, 4]; exit(sum(a)); }\n",
      10, NULL);
  // array literal coerces to `[]i32`; `.len()`, `.get()`, `.first()`, `.last()` methods.
  sc_run_program(
      "slice methods + literal coercion",
      PRE "fn f(s: []i32) i32 { return (s.len() as i32) + s.get(1) + s.first() + s.last(); }\n"
          "fn main() i32 { exit(f([10, 20, 30])); }\n", // 3 + 20 + 10 + 30
      63, NULL);
  // `[]mut i32` writes through the view; the mutation is visible in the backing array.
  sc_run_program(
      "mut slice writes back to array",
      PRE "fn dbl(s: []mut i32) { let mut i: usize = 0; while i < s.len { s[i] = s[i] * 2; i = i + 1; } }\n"
          "fn main() i32 { let mut a: [i32; 3] = [3, 4, 5]; dbl(a); exit(a[0] + a[1] + a[2]); }\n", // (6+8+10)
      24, NULL);
}

// `a[lo..hi]` slices an array (or another slice) into a `[]T` view: half-open `lo..hi`, open ends
// `..hi`/`lo..`, and inclusive `lo..=hi`. Open-ended upper bound uses the array's length (from the
// annotation, or counted from an inferred-length literal). Slicing a slice indexes through its `.ptr`.
#define RSUM "fn sum(s: []i32) i32 { let mut t = 0; for x in s { t = t + x; } return t; }\n"
static void test_range_slicing(void) {
  sc_run_program("range half-open a[1..4]",
                 PRE RSUM "fn main() i32 { let a = [10,20,30,40,50]; exit(sum(a[1..4])); }\n", 90, NULL);
  sc_run_program("range open-start a[..2]",
                 PRE RSUM "fn main() i32 { let a = [10,20,30,40,50]; exit(sum(a[..2])); }\n", 30, NULL);
  sc_run_program("range open-end (inferred len) a[3..]",
                 PRE RSUM "fn main() i32 { let a = [10,20,30,40,50]; exit(sum(a[3..])); }\n", 90, NULL);
  sc_run_program("range open-end (annotated len) a[2..]",
                 PRE RSUM "fn main() i32 { let a: [i32; 5] = [10,20,30,40,50]; exit(sum(a[2..])); }\n", 120, NULL);
  sc_run_program("range inclusive a[0..=2]",
                 PRE RSUM "fn main() i32 { let a = [10,20,30,40,50]; exit(sum(a[0..=2])); }\n", 60, NULL);
  sc_run_program("slice of a slice mid[1..3]",
                 PRE RSUM "fn main() i32 { let a = [10,20,30,40,50]; let mid = a[1..4]; exit(sum(mid[1..3])); }\n",
                 70, NULL);
}

// `lo..hi` in value position is a first-class `Range<T>` (a `for` iterable / `switch` pattern / `a[..]`
// subscript stays structural and never builds one): bind it, read `.start`/`.end`, pass it to a fn, and
// `for x in r` counts start..end (half-open) or start..=end (inclusive).
static void test_range_value(void) {
  sc_run_program("range value: fields", PRE "fn main() i32 { let r = 1..5; exit(r.start + r.end); }\n", 6, NULL);
  sc_run_program("range value: iterate half-open",
                 PRE "fn main() i32 { let r = 1..5; let mut s = 0; for x in r { s = s + x; } exit(s); }\n", 10,
                 NULL); // 1+2+3+4
  sc_run_program("range value: iterate inclusive",
                 PRE "fn main() i32 { let r = 0..=4; let mut s = 0; for x in r { s = s + x; } exit(s); }\n", 10,
                 NULL); // 0+1+2+3+4
  sc_run_program("range value: passed to a fn",
                 PRE "fn span(r: Range<i32>) i32 { return r.end - r.start; }\n"
                     "fn main() i32 { let r = 3..10; exit(span(r)); }\n",
                 7, NULL);
  sc_run_program("literal range for-loop still counts (no Range value built)",
                 PRE "fn main() i32 { let mut s = 0; for i in 0..=5 { s = s + i; } exit(s); }\n", 15, NULL);
}

// Opaque `extern "C"` handles are real, sized C types (named by the auto-included header), usable by value
// -- as a local, a by-value parameter, and a by-value return -- not just behind a pointer.
static void test_opaque_extern(void) {
  sc_run_program(
      "opaque handle by value",
      "extern \"C\" { type clock_t; fn clock() clock_t; }\n"
      "fn pass(c: clock_t) clock_t { return c; }\n"
      "fn main() i32 { let t: clock_t = clock(); pass(t); return 7; }\n",
      7, NULL);
}

// A C-variadic binding (`fn printf(fmt, ...)`) takes its fixed params plus any number of trailing args;
// the call passes them all through verbatim. String literals coerce to bare C strings in the fixed
// `*const char` fmt AND in `%s` vararg slots, so `printf("%s=%d\n", "x", 42)` -> "x=42\n" links + runs.
static void test_variadics(void) {
  sc_run_program(
      "variadic printf with string-literal fmt + %s arg",
      "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\n"
      "fn main() i32 { printf(\"%s=%d\\n\", \"x\", 42); return 0; }\n",
      0, "x=42\n");
  // A Super-C-defined variadic function reading its args with va_start/va_arg/va_end.
  sc_run_program(
      "defined variadic with va_arg",
      "fn sum(count: i32, ...) i32 {\n"
      "  let mut ap: va_list; va_start(ap, count);\n"
      "  let mut total: i32 = 0; let mut i: i32 = 0;\n"
      "  while i < count { total = total + va_arg(ap, i32); i = i + 1; }\n"
      "  va_end(ap); return total;\n"
      "}\n"
      "fn main() i32 { return sum(4, 10, 20, 30, 40) - 100; }\n",
      0, "");
  // forwarding a va_list to a C function (vsnprintf) -- the self-host diagnostics path.
  sc_run_program(
      "va_list forwarded to vsnprintf",
      "extern \"C\" {\n"
      "  fn vsnprintf(buf: *mut char, n: usize, fmt: *const char, ap: va_list) i32;\n"
      "  fn puts(s: *const char) i32;\n"
      "}\n"
      "fn say(fmt: *const char, ...) void {\n"
      "  let mut buf: [char; 64]; let mut ap: va_list;\n"
      "  va_start(ap, fmt); vsnprintf(&mut buf[0], 64, fmt, ap); va_end(ap);\n"
      "  puts(&buf[0]);\n"
      "}\n"
      "fn main() i32 { say(\"n=%d\", 7); return 0; }\n",
      0, "n=7\n");
}

// The `c32`/`c64` builtins are real C `_Complex`: held by value, arithmetic via native operators, real
// literals coerce in, and complex.h functions bind via FFI. csqrt(-1) = i; |3 + 4i| = 5.
static void test_complex(void) {
  sc_run_program(
      "complex arithmetic + complex.h FFI",
      PRE "extern \"C\" { fn csqrt(z: c64) c64; fn creal(z: c64) f64; fn cimag(z: c64) f64; fn cabs(z: c64) f64; }\n"
          "fn main() i32 { let i: c64 = csqrt(-1.0); let z: c64 = 3.0 + 4.0 * i;\n"
          "  exit((creal(z) as i32) + (cimag(z) as i32) + (cabs(z) as i32)); }\n", // 3 + 4 + 5
      12, NULL);
}

// Sequentially-consistent atomics from the compiler runtime (`__sc_atomic_*`, lowered to `__atomic_*`),
// bound as ordinary extern fns: store/add(returns prior)/cas/load/fence over a plain `i32` cell.
static void test_atomics(void) {
  sc_run_program(
      "atomic store/add/cas/load/fence",
      PRE "extern \"C\" {\n"
          "  fn __sc_atomic_store_i32(p: *mut i32, v: i32);\n"
          "  fn __sc_atomic_load_i32(p: *const i32) i32;\n"
          "  fn __sc_atomic_add_i32(p: *mut i32, v: i32) i32;\n"
          "  fn __sc_atomic_cas_i32(p: *mut i32, e: i32, d: i32) bool;\n"
          "  fn __sc_atomic_fence();\n}\n"
          "fn main() i32 { let mut x: i32 = 0; __sc_atomic_store_i32(&mut x, 40);\n"
          "  let p: i32 = __sc_atomic_add_i32(&mut x, 2); __sc_atomic_fence();\n"
          "  let ok: bool = __sc_atomic_cas_i32(&mut x, 42, 6);\n"
          "  exit(p + __sc_atomic_load_i32(&x) + (ok as i32)); }\n", // 40 + 6 + 1
      47, NULL);
}

static void test_array_literals(void) {
  // array literal as a let initializer (brace list) and iterated with a for-loop.
  sc_run_program(
      "array literal let + for",
      PRE "fn main() i32 {\n"
          "  let a: [i32; 4] = [10, 20, 30, 40];\n"
          "  let mut total: i32 = 0;\n"
          "  for x in a { total = total + x; }\n"
          "  exit(total);\n"
          "}\n",
      100, "");
  // array literal in argument position (compound literal) + indexing.
  sc_run_program(
      "array literal as argument",
      PRE "fn third(a: [i32; 3]) i32 { return a[2]; }\n"
          "fn main() i32 { exit(third([7, 8, 9])); }\n",
      9, "");
  // designated (sparse) initializers, including a char index and a mixed positional+designated list.
  sc_run_program(
      "designated array init",
      PRE "fn main() i32 {\n"
          "  let t: [i32; 8] = [[1] = 10, [3] = 30, [7] = 70];\n"
          "  let k: [i32; 128] = [['a'] = 5];\n"
          "  let m: [i32; 4] = [1, [3] = 9];\n"
          "  exit(t[1] + t[3] + t[7] + k['a'] + m[0] + m[3]);\n" // 10+30+70+5+1+9 = 125
          "}\n",
      125, "");
  // a block-local `const` table lowers to `static const` -- the Super-C stand-in for a C function-local static.
  sc_run_program(
      "function-local const table",
      PRE "fn lut(i: i32) i32 { const T: [i32; 5] = [2, 3, 5, 7, 11]; return T[i]; }\n"
          "fn main() i32 { exit(lut(0) + lut(4)); }\n", // 2 + 11
      13, "");
}

static void test_pointers(void) {
  sc_run_program(
      "shared reference deref",
      PRE "fn deref(p: *const i32) i32 { return *p; }\n"
          "fn main() i32 { let x: i32 = 42; exit(deref(&x)); }\n",
      42, "");
  // new T(init): heap-allocate a scalar, mutate through *mut, read back; plus enum->ptr cast.
  sc_run_program(
      "new scalar init + *mut mutate",
      PRE "fn main() i32 {\n"
          "  let p: *mut i32 = new i32(7);\n"
          "  *p = *p + 3;\n"
          "  let q: *i32 = new i32(50);\n"
          "  exit(*p + *q);\n"
          "}\n",
      60, "");
  // &mut yields a mutable pointer the callee can write through.
  sc_run_program(
      "&mut address-of writes back",
      PRE "fn bump(p: *mut i32) void { *p = *p + 1; }\n"
          "fn main() i32 { let mut x: i32 = 41; bump(&mut x); exit(x); }\n",
      42, "");
}

static void test_misc(void) {
  sc_run_program("integer cast truncation", PRE "fn main() i32 { let x: i64 = 300; exit(x as u8 as i32); }\n", 44, "");
  sc_run_program(
      "keyword-mangled identifiers",
      PRE "fn main() i32 {\n"
          "  let register: i32 = 5; let switch_v: i32 = 3;\n"
          "  let mut volatile: i32 = register * switch_v; volatile = volatile + 1; exit(volatile);\n"
          "}\n",
      16, "");
  sc_run_program(
      "global const + forward-declared fn",
      PRE "const N: i32 = 35;\nfn main() i32 { exit(N + g()); }\nfn g() i32 { return 7; }\n", 42, "");
  sc_run_program(
      "putchar to stdout", PRE "fn main() i32 { for c in 0..2 { putchar(65 + c); } putchar(10); exit(0); }\n", 0,
      "AB\n");
}

static void test_let_owning_mut(void) {
  // A `let mut` binding is emitted non-const, so `&mut self` methods are callable on it. (`let` without
  // `mut` is immutable: the typechecker rejects `&mut self` on it -- binding mutability is explicit.)
  sc_run_program(
      "let mut binding calls &mut self",
      PRE "extern \"C\" { fn malloc(n: usize) *mut void; fn free(p: *mut void) void; }\n"
          "struct Box { pub p: *mut u8, }\n"
          "extend Box {\n"
          "  fn make() Box { return Box { p: malloc(1) as *mut u8, }; }\n"
          "  fn set(self: &mut Box, v: u8) { self.p[0] = v; }\n"
          "  fn get(self: &Box) u8 { return self.p[0]; }\n"
          "  fn deinit(self: &mut Box) { free(self.p as *mut void); self.p = null; }\n"
          "}\n"
          "fn main() i32 { let mut b: Box = Box::make(); b.set(42); let r: u8 = b.get(); b.deinit(); exit(r as i32); }\n",
      42, "");
}

static void test_field_vs_method(void) {
  // `s.len` (field read) and `s.len()` (method call) are distinct even when they share a name:
  // a bare member access resolves field-first, a call callee resolves method-first.
  sc_run_program(
      "field vs same-named method",
      PRE "struct S { pub len: i32, }\n"
          "extend S { pub fn new(n: i32) S { return S { len: n, }; } pub fn len(self: &S) i32 { return self.len * 10; } }\n"
          "fn main() i32 { let s: S = S::new(5); exit(s.len + s.len()); }\n",
      55, ""); // field 5 + method (5*10)
}

static void test_str(void) {
  // A string literal is a `str` view: `.len` is the byte count, `.ptr` indexes the UTF-8 bytes.
  sc_run_program(
      "str len + byte indexing",
      PRE "fn first(s: str) i32 { return s.ptr[0] as i32; }\n"
          "fn main() i32 { let g: str = \"ABC\"; exit(first(g) + g.len as i32); }\n",
      68, ""); // 'A'=65 + len 3
  // Multi-byte UTF-8: `.len` counts bytes, and the raw bytes round-trip to stdout unchanged.
  sc_run_program(
      "str utf8 bytes to stdout",
      PRE "fn main() i32 { let s: str = \"é!\"; for i in 0..s.len { putchar(s.ptr[i] as i32); } exit(s.len as i32); }\n",
      3, "\xc3\xa9!"); // é is 2 UTF-8 bytes, '!' is 1 -> 3 bytes
  // An empty literal has length 0 (the for-loop body never runs).
  sc_run_program(
      "empty str", PRE "fn main() i32 { let s: str = \"\"; for i in 0..s.len { putchar(63); } exit(s.len as i32); }\n", 0,
      "");
}

// A7: a prelude generic instantiated over a USER struct held by value -- the instance is re-homed to the
// user code and built from the generic's macros (an owner-emitted concrete struct would carry an
// incomplete-type field). Covers the re-homed struct + non-generic method (Option::unwrap_or), a
// sibling-referencing monomorphic method (Vector::pop -> Option<P>), and a cross-pool generic method
// (Option::map<U>). These all compile -Werror clean and run.
static void test_generics_over_user_types(void) {
  sc_run_program(
      "Option over a user struct by value",
      PRE "struct P { pub a: i32 }\n"
          "fn main() i32 { let o: Option<P> = Option::<P>::some(P { a: 40 });\n"
          "  let n: Option<P> = Option::<P>::none();\n"
          "  exit(o.unwrap_or(P { a: 0 }).a + n.unwrap_or(P { a: 2 }).a); }\n", // 40 + 2
      42, "");
  sc_run_program(
      "Vector over a user struct: pop -> Option<P>",
      PRE "struct P { pub a: i32 }\n"
          "fn main() i32 { let mut v: Vector<P> = Vector::<P>::new();\n"
          "  v.push(P { a: 5 }); v.push(P { a: 40 });\n"
          "  let r: i32 = v.pop().unwrap_or(P { a: 0 }).a + v.pop().unwrap_or(P { a: 0 }).a - 3;\n" // 40 + 5 - 3
          "  v.drop(); exit(r); }\n",
      42, "");
  sc_run_program(
      "Option::map<U> over a user struct (cross-pool)",
      PRE "struct P { pub a: i32 }\n"
          "fn geta(p: P) i32 { return p.a; }\n"
          "fn dup(p: P) P { return P { a: p.a + 1 }; }\n"
          "fn main() i32 { let s: Option<P> = Option::<P>::some(P { a: 41 });\n"
          "  let chained: i32 = s.map(dup).map(geta).unwrap_or(0);\n" // (41+1) -> 42
          "  exit(chained); }\n",
      42, "");
}

// Conditional container conformances: Vector/Option/Box/Result are Clone/Eq/Hash when their element is.
// Each dispatches to the element's bound method through the cross-module placement macros (Phase 1).
static void test_container_conformances(void) {
  sc_run_program(
      "Vector<P> Clone + Eq + Hash (element-wise via the bound)",
      PRE "struct P { pub a: i32 }\n"
          "extend P as Clone { fn clone(self: &Self) P { return P { a: self.a }; } }\n"
          "extend P as Eq { fn eq(self: &Self, other: &Self) bool { return self.a == other.a; } }\n"
          "extend P as Hash { fn hash(self: &Self) u64 { return self.a as u64; } }\n"
          "fn main() i32 { let mut v = Vector::<P>::new(); v.push(P{a:3}); v.push(P{a:4});\n"
          "  let mut w = v.clone();\n"
          "  let mut acc = 0;\n"
          "  if v.eq(&w) { acc = acc + 6; }\n"               // 6
          "  if v.hash() == w.hash() { acc = acc + 36; }\n"  // 42
          "  v.drop(); w.drop(); exit(acc); }\n",
      42, "");
  sc_run_program(
      "Option<P> and Box<P> Clone + Eq",
      PRE "struct P { pub a: i32 }\n"
          "extend P as Clone { fn clone(self: &Self) P { return P { a: self.a }; } }\n"
          "extend P as Eq { fn eq(self: &Self, other: &Self) bool { return self.a == other.a; } }\n"
          "fn main() i32 { let o = Option::<P>::Some(P{a:20});\n"
          "  let o2 = o.clone();\n"
          "  let mut b = Box::<P>::new(P{a:22});\n"
          "  let mut b2 = b.clone();\n"
          "  let mut acc = 0;\n"
          "  if o.eq(&o2) { acc = acc + 20; }\n"
          "  if b.eq(&b2) { acc = acc + 22; }\n" // 42
          "  b.drop(); b2.drop(); exit(acc); }\n",
      42, "");
}

// Map<K, V> (open-addressing hash map): insert/overwrite/get/contains/remove over String keys, across
// several reallocations. Exercises the K: Hash + Eq bound dispatch (String__hash / String__eq).
static void test_map(void) {
  sc_run_program(
      "Map<String,i32> insert/get/remove/grow",
      PRE "fn main() i32 {\n"
          "  let mut m = Map::<String, i32>::new();\n"
          "  let mut i = 0; while i < 40 { m.insert(String::from_str(\"k\"), i); i = i + 1; }\n" // overwrite + grows
          "  m.insert(String::from_str(\"a\"), 10); m.insert(String::from_str(\"b\"), 20);\n"
          "  let ka = String::from_str(\"a\"); let kb = String::from_str(\"b\"); let kk = String::from_str(\"k\");\n"
          "  let mut acc = 0;\n"
          "  acc = acc + m.get(&ka).unwrap_or(0);\n"             // 10
          "  acc = acc + m.get(&kk).unwrap_or(0);\n"             // 39 -> 49
          "  if m.contains_key(&kb) { acc = acc + 100; }\n"      // 149
          "  m.remove(&kb);\n"
          "  if m.get(&kb).is_none() { acc = acc + 1000; }\n"    // 1149
          "  let total = acc; m.drop(); exit(total - 1100); }\n", // 49
      49, "");
}

// format/print/println builtins: a string literal with `{}` placeholders filled by the trailing args,
// appended by type (int/float/bool/char/str/String). `{{`/`}}` are literal braces; a Format value is passed
// as its `.fmt()` String. `format` returns the String; `println` adds a newline.
static void test_format_printing(void) {
  sc_run_program(
      "println with mixed argument types and brace escapes",
      PRE "fn main() i32 {\n"
          "  let name = \"world\"; let n: i32 = 42;\n"
          "  println(\"hi {} n={} pi={} ok={} brace={{}}\", name, n, 2.5, true);\n"
          "  let mut s = format(\"<{}>\", n);\n"
          "  s.print(); s.drop();\n"
          "  exit(0); }\n",
      0, "hi world n=42 pi=2.5 ok=true brace={}\n<42>");
}

// `str` conforms to Eq/Ord/Hash/Default with the `&Self` convention: `==`/`!=` dispatch to its `eq` (this
// also covers the former `str == str` miscompile, where `eq` took `other` by value), `T: Ord` reaches `cmp`.
static void test_str_conformances(void) {
  sc_run_program(
      "str Eq/Ord/Hash/Default behind operators and bounds",
      PRE "fn lt<T: Ord>(a: &T, b: &T) bool { return a.cmp(b) < 0; }\n"
          "fn main() i32 { let a = \"apple\"; let b = \"apple\"; let c = \"banana\";\n"
          "  let mut acc = 0;\n"
          "  if a == b { acc = acc + 1; }\n"            // eq via ==
          "  if a != c { acc = acc + 2; }\n"            // 3
          "  if lt(&a, &c) { acc = acc + 4; }\n"        // 7: str behind T: Ord
          "  if a.hash() == b.hash() { acc = acc + 8; }\n" // 15
          "  let d: str = Default::default(); if d.is_empty() { acc = acc + 16; }\n" // 31
          "  exit(acc); }\n",
      31, "");
}

// Multiple `From` impls on one type: each `from`/`into` is disambiguated by source type, so the C symbols
// (Celsius__from__i32, Celsius__from__u8) do not collide and each call routes to the right one.
static void test_multi_from(void) {
  sc_run_program(
      "two From impls: Type::from(x) and x.into() route by source type",
      PRE "struct Celsius { pub v: i32 }\n"
          "extend Celsius as From<u8> { fn from(value: u8) Celsius { return Celsius { v: value as i32 }; } }\n"
          "extend Celsius as From<i32> { fn from(value: i32) Celsius { return Celsius { v: value }; } }\n"
          "fn main() i32 { let a: Celsius = Celsius::from(40);\n" // i32 overload
          "  let b: u8 = 1; let c: Celsius = b.into();\n"         // u8 overload via .into()
          "  exit(a.v + c.v); }\n",                               // 41
      41, "");
}

static void test_generics(void) {
  // A generic function is monomorphized: turbofish picks the instantiation, and distinct type args
  // produce distinct specializations.
  sc_run_program(
      "generic turbofish",
      PRE "fn id<T>(x: T) T { return x; }\n"
          "fn main() i32 { let a: i32 = id::<i32>(40); let b: bool = id::<bool>(true); if b { exit(a + 2); } exit(0); }\n",
      42, "");
  // Type args are inferred from the call arguments (no turbofish), incl. through a reference parameter.
  sc_run_program(
      "generic inference",
      PRE "fn id<T>(x: T) T { return x; }\n"
          "fn deref<T>(p: &T) T { return *p; }\n"
          "fn main() i32 { let x: i32 = 37; exit(id(5) + deref(&x)); }\n",
      42, ""); // 5 + 37
  // A generic struct is monomorphized: distinct type args -> distinct C structs; construct + field access.
  sc_run_program(
      "generic struct construct + field",
      PRE "struct Pair<T> { pub a: T, pub b: i32 }\n"
          "fn main() i32 { let p: Pair<i32> = Pair::<i32> { a: 20, b: 5 };\n"
          "  let q: Pair<bool> = Pair::<bool> { a: true, b: 17 };\n"
          "  exit(if q.a { p.a + p.b + q.b; } else { 0; }); }\n",
      42, ""); // 20 + 5 + 17
  // A generic function over a generic struct: the type arg flows through Box<T> and is inferred.
  sc_run_program(
      "generic fn over generic struct",
      PRE "struct Box<T> { pub v: T }\n"
          "fn unwrap<T>(b: Box<T>) T { return b.v; }\n"
          "fn main() i32 { exit(unwrap(Box::<i32> { v: 42 })); }\n",
      42, "");
  // A generic enum is monomorphized: turbofish construction picks the instance; a payload variant
  // carries the concrete arg; bare variant patterns match against the instance.
  sc_run_program(
      "generic enum construct + match",
      PRE "enum Opt<T> { Some(T), None }\n"
          "fn main() i32 { let a: Opt<i32> = Opt::<i32>::Some(40);\n"
          "  let b: Opt<i32> = Opt::<i32>::None;\n"
          "  let x: i32 = switch a { Some(v) => v + 2, None => 0, };\n"
          "  exit(x + switch b { Some(_) => 99, None => 0, }); }\n",
      42, ""); // 42 + 0
  // Distinct type args -> distinct enum instances; a two-parameter enum (Result) mangles both args.
  sc_run_program(
      "generic enum multi-instance + two params",
      PRE "enum Opt<T> { Some(T), None }\n"
          "enum Res<T, E> { Ok(T), Err(E) }\n"
          "fn main() i32 { let a: Opt<i32> = Opt::<i32>::Some(20);\n"
          "  let b: Opt<bool> = Opt::<bool>::Some(true);\n"
          "  let c: Res<i32, bool> = Res::<i32, bool>::Ok(17);\n"
          "  let bv: i32 = switch b { Some(t) => if t { 5; } else { 0; }, None => 0, };\n"
          "  exit(switch a { Some(v) => v, None => 0, } + bv + switch c { Ok(n) => n, Err(_) => 0, }); }\n",
      42, ""); // 20 + 5 + 17
  // A generic function over a generic enum: the type arg is inferred through Opt<T>, and the variant
  // pattern binding is specialized in the monomorphized copy.
  sc_run_program(
      "generic fn over generic enum",
      PRE "enum Opt<T> { Some(T), None }\n"
          "fn unwrap_or<T>(o: Opt<T>, d: T) T { return switch o { Some(v) => v, None => d, }; }\n"
          "fn main() i32 { let a: Opt<i32> = Opt::<i32>::Some(42);\n"
          "  let b: Opt<i32> = Opt::<i32>::None;\n"
          "  exit(unwrap_or(a, 0) - unwrap_or(b, 0)); }\n",
      42, "");
}

// The std/ generic container types (Option, Result, Box, Vector) exercised end-to-end: they are prelude
// modules, so this proves cross-module generic instances + methods + sizeof + rvalue-receiver chaining.
static void test_std_types(void) {
  // sizeof(T) lowers to C's sizeof and is usize-typed (the byte sizes back the heap containers).
  sc_run_program("sizeof", PRE "fn main() i32 { exit(((sizeof(i32) + sizeof(u8)) as i32) * 8 + 2); }\n", 42, ""); // (4+1)*8+2
  // Standard-interface conformances on prelude types: String Eq/Ord/Clone/Default/From, Vector/Option
  // Default, dispatched through a generic `T: Ord` bound and the expected-type `Default::default()`.
  // (Vector<i32> here, not Vector<String>: a by-value Option<prelude-type> field is only orderable in the
  // multi-file build, not this single-TU harness path.)
  sc_run_program(
      "std interface conformances",
      PRE "fn pick<T: Ord>(a: T, b: T) T { if a.cmp(&b) >= 0 { return a; } return b; }\n"
          "fn main() i32 { let mut x: String = String::from(\"apple\"); let mut y: String = String::from(\"banana\");\n"
          "  let mut acc = 0; if x.cmp(&y) < 0 { acc = acc + 1; } if x.eq(&y) { acc = acc + 1000; }\n"
          "  let mut big = pick::<String>(x.clone(), y.clone()); big.print();\n"
          "  let mut d: String = Default::default(); if d.len() == 0 { acc = acc + 10; }\n"
          "  let mut v: Vector<i32> = Default::default(); v.push(7); acc = acc + (v.len() as i32) * 100;\n"
          "  let o: Option<i32> = Default::default(); acc = acc + o.unwrap_or(0); v.drop(); x.drop(); y.drop(); big.drop(); d.drop(); exit(acc); }\n",
      111, "banana"); // 1 + 10 + 100
  // Vector is iterable via `.iter()` (VecIter implements Iterator), driving the for-loop desugar.
  sc_run_program(
      "std Vector for-loop via .iter()",
      PRE "fn main() i32 { let mut v = Vector::<i32>::new(); v.push(10); v.push(20); v.push(12);\n"
          "  let mut sum = 0; for x in v.iter() { sum = sum + x; } v.drop(); exit(sum); }\n",
      42, "");
  // String numeric formatting: from_i64 / from_u64 / push_i64 / push_f64.
  sc_run_program(
      "std String int/float to-string",
      PRE "fn main() i32 { let mut a = String::from_i64(-12345); a.print(); putchar(32);\n"
          "  let mut s = String::from_str(\"x=\"); s.push_i64(42); s.push_byte(32); s.push_f64(3.5); s.println();\n"
          "  let n = a.len(); a.drop(); s.drop(); exit(n as i32); }\n",
      6, "-12345 x=42 3.5\n");
  sc_run_program(
      "std Option",
      PRE "fn main() i32 { let a: Option<i32> = Option::<i32>::some(40);\n"
          "  let b: Option<i32> = Option::<i32>::none();\n"
          "  exit(a.unwrap_or(0) + b.unwrap_or(2)); }\n",
      42, ""); // 40 + 2
  sc_run_program(
      "std Result",
      PRE "fn main() i32 { let r: Result<i32, bool> = Result::<i32, bool>::ok(40);\n"
          "  let e: Result<i32, bool> = Result::<i32, bool>::err(true);\n"
          "  exit(r.unwrap_or(0) + e.unwrap_or(2)); }\n",
      42, ""); // 40 + 2
  sc_run_program(
      "std Box",
      PRE "fn main() i32 { let mut b: Box<i32> = Box::<i32>::new(40);\n"
          "  let old: i32 = b.replace(2);\n"
          "  let r: i32 = b.get() + old; b.drop(); exit(r); }\n",
      42, ""); // 2 + 40
  sc_run_program(
      "std Vector push/pop/get",
      PRE "fn main() i32 { let mut v: Vector<i32> = Vector::<i32>::new();\n"
          "  for i in 0..10 { v.push(i * 3); }\n"                              // [0,3,..,27], len 10
          "  let r: i32 = v.at(2) + v.pop().unwrap_or(0) + v.get(50).unwrap_or(9);\n" // 6 + 27 + 9
          "  v.drop(); exit(r); }\n",
      42, "");
  sc_run_program(
      "std Vector capacity/set/first/last",
      PRE "fn main() i32 { let mut v: Vector<i32> = Vector::<i32>::with_capacity(4);\n"
          "  v.push(1); v.push(2); v.push(3);\n"
          "  v.set(0, 12); v.set(1, 18); v.set(2, 12);\n"
          "  let r: i32 = v.first().unwrap_or(0) + v.at(1) + v.last().unwrap_or(0);\n" // 12 + 18 + 12
          "  v.drop(); exit(r); }\n",
      42, "");
  // Function pointers as first-class values: pass a named fn where a `fn(..) ..` param is expected.
  sc_run_program(
      "fn pointers",
      PRE "fn dbl(x: i32) i32 { return x * 2; }\n"
          "fn apply(f: fn(i32) i32, v: i32) i32 { return f(v); }\n"
          "fn main() i32 { exit(apply(dbl, 21)); }\n",
      42, "");
  // Higher-order Option methods (method-own generic `U`, type-changing) -- inferred, owner-emitted.
  sc_run_program(
      "std Option map/and_then/filter",
      PRE "fn dbl(x: i32) i32 { return x * 2; }\n"
          "fn even(x: i32) bool { return x % 2 == 0; }\n"
          "fn half(x: i32) Option<i32> { return Option::<i32>::Some(x / 2); }\n"
          "fn main() i32 { let a: Option<i32> = Option::<i32>::Some(10);\n"
          "  let m: i32 = a.map(dbl).unwrap_or(0);\n"            // 20
          "  let t: i32 = a.and_then(half).unwrap_or(0);\n"      // 5
          "  let f: i32 = a.filter(even).unwrap_or(0);\n"        // 10
          "  let mo: i32 = a.map_or(0, dbl);\n"                  // 20
          "  exit(m + t + f - mo + 27); }\n",                    // 20+5+10-20+27
      42, "");
  // Higher-order Result methods + Result<->Option conversion.
  sc_run_program(
      "std Result map/and_then/get_ok",
      PRE "fn inc(x: i32) i32 { return x + 1; }\n"
          "fn chk(x: i32) Result<i32, bool> { return Result::<i32, bool>::Ok(x + 8); }\n"
          "fn main() i32 { let r: Result<i32, bool> = Result::<i32, bool>::Ok(7);\n"
          "  let m: i32 = r.map(inc).unwrap_or(0);\n"            // 8
          "  let a: i32 = r.and_then(chk).unwrap_or(0);\n"       // 15
          "  let g: i32 = r.get_ok().unwrap_or(0);\n"            // 7
          "  exit(m + a + g + 12); }\n",                         // 8+15+7+12
      42, "");
  // Vector insert/remove/swap_remove/reverse/find/retain/map.
  sc_run_program(
      "std Vector mutators + map/find",
      PRE "fn dbl(x: i32) i32 { return x * 2; }\n"
          "fn even(x: i32) bool { return x % 2 == 0; }\n"
          "fn main() i32 { let mut v: Vector<i32> = Vector::<i32>::new();\n"
          "  v.push(1); v.push(2); v.push(3); v.push(4);\n"     // [1,2,3,4]
          "  v.insert(0, 9);\n"                                  // [9,1,2,3,4]
          "  let r0: i32 = v.remove(1).unwrap_or(0);\n"          // removes 1 -> [9,2,3,4]; r0=1
          "  let sr: i32 = v.swap_remove(0).unwrap_or(0);\n"     // removes 9 -> [4,2,3]; sr=9
          "  v.reverse();\n"                                     // [3,2,4]
          "  let fd: i32 = v.find(even).unwrap_or(0);\n"         // 2
          "  v.retain(even);\n"                                  // [2,4]
          "  let mut m: Vector<i32> = v.map(dbl);\n"             // [4,8]
          "  let r: i32 = r0 + sr + fd + m.at(0) + m.at(1) + (v.len() as i32);\n" // 1+9+2+4+8+2 = 26
          "  v.drop(); m.drop(); exit(r + 16); }\n",             // 26 + 16
      42, "");
  // Box higher-order map (allocates a fresh box of the mapped type).
  sc_run_program(
      "std Box map",
      PRE "fn dbl(x: i32) i32 { return x * 2; }\n"
          "fn main() i32 { let b: Box<i32> = Box::<i32>::new(21);\n"
          "  let mut c: Box<i32> = b.map(dbl);\n"
          "  let r: i32 = c.get(); c.drop(); exit(r); }\n",
      42, "");
}

// Closures / anonymous functions (non-capturing): compact `|x: T| expr`, anonymous `fn(..) .. { .. }`,
// as fn-pointer arguments, let-bound + directly called, and driving the generic std higher-order methods.
static void test_closures(void) {
  // Both forms passed where a `fn(i32) i32` pointer is expected.
  sc_run_program(
      "closure as fn-pointer arg",
      PRE "fn apply(f: fn(i32) i32, x: i32) i32 { return f(x); }\n"
          "fn main() i32 {\n"
          "  let a: i32 = apply(|x: i32| x + 1, 20);\n"               // 21
          "  let b: i32 = apply(fn(x: i32) i32 { return x * 2; }, 10);\n" // 20
          "  let c: i32 = apply(|x: i32| x - 1, 2);\n"               // 1
          "  exit(a + b + c); }\n",                                  // 42
      42, "");
  // Let-bound closures, then invoked directly through the binding.
  sc_run_program(
      "closure let + direct call",
      PRE "fn main() i32 {\n"
          "  let g = |x: i32| x * 3;\n"
          "  let h = fn(n: i32) i32 { return n + 5; };\n"
          "  exit(g(9) + h(10)); }\n",                               // 27 + 15 = 42
      42, "");
  // A void anonymous fn used for a side effect; exact stdout asserted.
  sc_run_program(
      "closure void side-effect",
      PRE "fn run(f: fn(i32) void, n: i32) void { f(n); }\n"
          "fn main() i32 { run(fn(c: i32) { putchar(c); }, 65); exit(0); }\n",
      0, "A");
  // Closures driving the monomorphized generic higher-order std methods (return type inferred per closure).
  sc_run_program(
      "closures into std HOFs",
      PRE "fn main() i32 {\n"
          "  let o: Option<i32> = Option::<i32>::Some(20);\n"
          "  let v1: i32 = o.map(|x: i32| x + 1).unwrap_or(0);\n"    // 21
          "  let mut vec: Vector<i32> = Vector::<i32>::new();\n"
          "  vec.push(1); vec.push(2); vec.push(3); vec.push(4);\n"
          "  let fd: i32 = vec.find(|x: i32| x > 2).unwrap_or(0);\n" // 3
          "  let mut d: Vector<i32> = vec.map(|x: i32| x * 2);\n"    // [2,4,6,8]
          "  let s: i32 = d.at(0) + d.at(2) + d.at(3);\n"           // 2+6+8 = 16
          "  vec.drop(); d.drop();\n"
          "  exit(v1 + fd + s + 2); }\n",                            // 21+3+16+2 = 42
      42, "");
}

// Untagged unions: fields overlap in memory (a C `union`), so writing one field and reading another is
// type punning. Also a value type -- methods, &mut self, and an independent by-value copy.
static void test_unions(void) {
  // Little-endian: the low byte of 0x44434241 is 0x41 ('A'=65), the high byte 0x44 ('D'=68).
  sc_run_program(
      "union type punning",
      PRE "union Bits { pub i: u32, pub bytes: [u8; 4] }\n"
          "fn main() i32 { let u: Bits = Bits { i: 0x44434241 };\n"
          "  exit(u.bytes[0] as i32 + u.bytes[3] as i32 - 100); }\n", // 65 + 68 - 100
      33, "");
  sc_run_program(
      "union methods + independent value copy",
      PRE "union Tag { raw: u16, parts: [u8; 2] }\n"
          "extend Tag { fn make(v: u16) Tag { return Tag { raw: v }; }\n"
          "  fn lo(self: &Tag) u8 { return self.parts[0]; }\n"
          "  fn set(self: &mut Tag, v: u16) { self.raw = v; } }\n"
          "fn main() i32 { let mut t: Tag = Tag::make(0x0121);\n" // lo byte 0x21 = 33
          "  let copy: Tag = t; t.set(0xFFFF);\n"                  // mutate original; copy is unaffected
          "  exit(copy.lo() as i32); }\n",
      33, "");
}

// The std String's small-string optimization: short strings live inline (capacity 23, no allocation),
// crossing 23 bytes transitions to the heap with content intact, and shrink_to_fit moves a short heap
// string back inline. Exercised end-to-end through the prelude String.
static void test_string_sso(void) {
  sc_run_program(
      "string SSO: short stays inline",
      PRE "fn main() i32 { let mut s: String = String::from_str(\"hi\");\n"
          "  s.push_str(\", world\");\n"                         // 9 bytes, still inline
          "  if !s.eq_str(\"hi, world\") { exit(1); }\n"
          "  let c: i32 = s.capacity() as i32;\n"                // 23: inline budget, never allocated
          "  s.drop(); exit(c); }\n",
      23, "");
  sc_run_program(
      "string SSO: heap transition + shrink back",
      PRE "fn main() i32 { let mut s: String = String::new();\n"
          "  let mut k: usize = 0; while k < 40 { s.push_byte(65); k = k + 1; }\n" // 'A'x40 -> heap
          "  if s.len() != 40 { exit(1); }\n"
          "  if s.capacity() < 40 { exit(2); }\n"                                  // grew onto the heap
          "  let mut j: usize = 0; while j < 40 { if s.byte(j) != 65 { exit(3); } j = j + 1; }\n" // bytes survived
          "  s.truncate(5); s.shrink_to_fit();\n"
          "  if s.capacity() != 23 { exit(4); }\n"                                 // moved back inline
          "  let r: i32 = s.len() as i32 + 37; s.drop(); exit(r); }\n",            // 5 + 37
      42, "");
}

// Interfaces end-to-end: a bounded generic dispatches `w.write()` to the concrete `extend T as Iface`
// method once monomorphized (inferred and turbofish), through `where` clauses, multiple bounds, conditional
// extensions, and `Self`-returning methods -- each compiled warning-clean and run.
static void test_interfaces(void) {
  sc_run_program(
      "interface bound: dispatch, inference + turbofish",
      PRE "interface Writer { fn write(self: *mut Self, n: i32) i32; }\n"
          "struct File { pub count: i32 }\n"
          "extend File as Writer { fn write(self: *mut Self, n: i32) i32 { self.count = self.count + n; return self.count; } }\n"
          "fn use_w<T: Writer>(w: &mut T, n: i32) i32 { return w.write(n); }\n"
          "fn main() i32 { let mut f = File { count: 0 };\n"
          "  let a = use_w(&mut f, 42); exit(a + use_w::<File>(&mut f, 8)); }\n", // 42 + 50
      92, "");
  sc_run_program(
      "interface: where clause + multiple bounds",
      PRE "interface A { fn a(self: *mut Self) i32; }\ninterface B { fn b(self: *mut Self) i32; }\n"
          "struct S { pub v: i32 }\n"
          "extend S as A { fn a(self: *mut Self) i32 { return self.v; } }\n"
          "extend S as B { fn b(self: *mut Self) i32 { return self.v + 1; } }\n"
          "fn both<T>(x: &mut T) i32 where T: A + B { return x.a() + x.b(); }\n"
          "fn main() i32 { let mut s = S { v: 10 }; exit(both(&mut s)); }\n", // 10 + 11
      21, "");
  sc_run_program(
      "interface: conditional extension dispatches through inner type",
      PRE "interface Drop { fn drop(self: *mut Self) i32; }\n"
          "struct Res { pub id: i32 }\nextend Res as Drop { fn drop(self: *mut Self) i32 { return self.id; } }\n"
          "struct Box<T> { pub inner: T }\n"
          "extend<T: Drop> Box<T> as Drop { fn drop(self: &mut Box<T>) i32 { return self.inner.drop(); } }\n"
          "fn dispose<U: Drop>(x: &mut U) i32 { return x.drop(); }\n"
          "fn main() i32 { let mut b = Box::<Res> { inner: Res { id: 99 } }; exit(dispose(&mut b)); }\n",
      99, "");
  sc_run_program(
      "interface: Self-returning method",
      PRE "interface Clone { fn dup(self: *mut Self) Self; }\n"
          "struct P { pub x: i32 }\nextend P as Clone { fn dup(self: *mut Self) Self { return P { x: self.x }; } }\n"
          "fn copy_of<T: Clone>(w: &mut T) T { return w.dup(); }\n"
          "fn main() i32 { let mut p = P { x: 7 }; let q = copy_of(&mut p); exit(q.x); }\n",
      7, "");
  // static (no-self) interface method on a type parameter: `T::default()` dispatches to the concrete impl.
  sc_run_program(
      "interface: static method on a type param",
      PRE "interface Default { fn default() Self; }\n"
          "struct Q { pub x: i32 }\nextend Q as Default { fn default() Q { return Q { x: 7 }; } }\n"
          "fn make<T: Default>() T { return T::default(); }\n"
          "fn main() i32 { let q = make::<Q>(); exit(q.x); }\n",
      7, "");
  // `Trait::assoc()` resolved by the expected (annotation) type: `Default::default()` -> `R__default`.
  sc_run_program(
      "interface: Trait::assoc() resolved by expected type",
      PRE "interface Default { fn default() Self; }\n"
          "struct R { pub x: i32, pub y: i32 }\nextend R as Default { fn default() R { return R { x: 5, y: 9 }; } }\n"
          "fn main() i32 { let r: R = Default::default(); exit(r.x + r.y); }\n",
      14, "");
  // `.into()` desugars to the target type's `From` impl, picked via the expected (annotation) type.
  sc_run_program(
      "interface: .into() via From",
      PRE "interface From<T> { fn from(value: T) Self; }\n"
          "struct C { pub d: i32 }\nstruct F { pub d: i32 }\n"
          "extend F as From<C> { fn from(value: C) F { return F { d: value.d * 9 / 5 + 32 }; } }\n"
          "fn main() i32 { let c = C { d: 100 }; let f: F = c.into(); exit(f.d); }\n",
      212, "");
  // `.try_into()` desugars to the target type's `TryFrom` impl (result is a `Result<U, E>`).
  sc_run_program(
      "interface: .try_into() via TryFrom",
      PRE "interface TryFrom<T> { fn try_from(value: T) Result<Self, i32>; }\n"
          "struct Sm { pub v: i32 }\n"
          "extend Sm as TryFrom<i32> { fn try_from(value: i32) Result<Sm, i32> {\n"
          "  if value > 255 { return Result::<Sm, i32>::err(1); } return Result::<Sm, i32>::ok(Sm { v: value }); } }\n"
          "fn main() i32 { let r: Result<Sm, i32> = (200).try_into(); let s = r.unwrap_or(Sm { v: 0 }); exit(s.v); }\n",
      200, "");
  // operator overloading: `==`/`!=` dispatch to `eq`, `<`/`<=`/`>`/`>=` to `cmp` (on a struct + a generic bound).
  sc_run_program(
      "interface: comparison operator overloading",
      PRE "interface Eq { fn eq(self: &Self, other: &Self) bool; }\n"
          "interface Ord: Eq { fn cmp(self: &Self, other: &Self) i32; }\n"
          "struct P { pub n: i32 }\n"
          "extend P as Eq { fn eq(self: &Self, o: &Self) bool { return self.n == o.n; } }\n"
          "extend P as Ord { fn cmp(self: &Self, o: &Self) i32 { return self.n - o.n; } }\n"
          "fn least<T: Ord>(a: T, b: T) T { if a < b { return a; } return b; }\n"
          "fn main() i32 { let a = P { n: 3 }; let b = P { n: 7 }; let mut acc = 0;\n"
          "  if a != b { acc = acc + 1; } if a < b { acc = acc + 10; } if b >= a { acc = acc + 100; }\n"
          "  if a == b { acc = acc + 1000; } exit(acc + least::<P>(a, b).n); }\n",
      114, ""); // 1 + 10 + 100 + 3
  // Iterator protocol: `for x in it` lowers to a loop over `it.next()` until None.
  sc_run_program(
      "interface: for-loop over an Iterator",
      PRE "interface Iterator<T> { fn next(self: &mut Self) Option<T>; }\n"
          "struct Counter { pub cur: i32, pub end: i32 }\n"
          "extend Counter as Iterator<i32> { fn next(self: &mut Self) Option<i32> {\n"
          "  if self.cur >= self.end { return Option::<i32>::none(); }\n"
          "  let v = self.cur; self.cur = self.cur + 1; return Option::<i32>::some(v); } }\n"
          "fn main() i32 { let mut sum = 0; let c = Counter { cur: 1, end: 6 }; for x in c { sum = sum + x; } exit(sum); }\n",
      15, ""); // 1+2+3+4+5
  // interface DEFAULT methods: impl provides `eq`/`cmp`; `ne` (from Eq) and `lt`/`ge` (from Ord) are inherited.
  sc_run_program(
      "interface: inherited default methods",
      PRE "interface Eq { fn eq(self: &Self, other: &Self) bool; fn ne(self: &Self, other: &Self) bool { return !self.eq(other); } }\n"
          "interface Ord: Eq { fn cmp(self: &Self, other: &Self) i32;\n"
          "  fn lt(self: &Self, other: &Self) bool { return self.cmp(other) < 0; }\n"
          "  fn ge(self: &Self, other: &Self) bool { return self.cmp(other) >= 0; } }\n"
          "struct V { pub n: i32 }\n"
          "extend V as Eq { fn eq(self: &Self, other: &Self) bool { return self.n == other.n; } }\n"
          "extend V as Ord { fn cmp(self: &Self, other: &Self) i32 { return self.n - other.n; } }\n"
          "fn main() i32 { let a = V { n: 3 }; let b = V { n: 7 }; let mut acc = 0;\n"
          "  if a.lt(&b) { acc = acc + 1; } if a.ge(&b) { acc = acc + 10; } if a.ne(&b) { acc = acc + 100; } exit(acc); }\n",
      101, "");
}

static void test_drop_raii(void) {
#define DROP_PRE                                                                                                        \
  PRE "interface Drop { fn drop(self: &mut Self); }\n"                                                                  \
      "struct R { pub tag: i32 }\n"                                                                                     \
      "extend R as Drop { fn drop(self: &mut Self) { putchar(self.tag); } }\n"
  // RAII: locals are dropped at scope exit in reverse construction order.
  sc_run_program(
      "drop: reverse-order scope-exit cleanup",
      DROP_PRE "fn run() void { let a = R { tag: 65 }; let b = R { tag: 66 }; putchar(88); }\n"
               "fn main() i32 { run(); exit(0); }\n",
      0, "XBA"); // X, then drop b (B) then a (A)
  // a moved binding is not dropped at the source scope (no double-free); the new owner drops it.
  sc_run_program(
      "drop: moved value is not auto-dropped",
      DROP_PRE "fn run() void { let a = R { tag: 65 }; let b = a; putchar(88); }\n"
               "fn main() i32 { run(); exit(0); }\n",
      0, "XA"); // only b (holding tag 65 = A) drops; a was moved
  // a by-value Drop parameter is owned by the callee, which drops it; the caller does not re-drop.
  sc_run_program(
      "drop: by-value parameter ownership transfer",
      DROP_PRE "fn consume(r: R) void { putchar(67); }\n"
               "fn run() void { let a = R { tag: 65 }; consume(a); putchar(88); }\n"
               "fn main() i32 { run(); exit(0); }\n",
      0, "CAX"); // consume prints C then drops its param (A); then X; a was moved, run drops nothing
  // RAII and defer share one reverse-order cleanup sequence.
  sc_run_program(
      "drop: interleaves with defer",
      DROP_PRE "fn run() void { let a = R { tag: 65 }; defer putchar(68); let b = R { tag: 66 }; putchar(88); }\n"
               "fn main() i32 { run(); exit(0); }\n",
      0, "XBDA"); // X, then reverse of [drop a, defer D, drop b]: b(B), D, a(A)
#undef DROP_PRE
}

static void test_defer(void) {
  // LIFO execution at scope exit: prints 1 2, then the defers reversed (b a).
  sc_run_program(
      "defer LIFO",
      PRE "fn run() void { putchar('1'); defer putchar('a'); defer putchar('b'); putchar('2'); }\n"
          "fn main() i32 { run(); exit(0); }\n",
      0, "12ba");
  // an early return runs the innermost-out defers first; the value is captured before they run.
  sc_run_program(
      "defer on return captures value first",
      PRE "fn f() i32 { let mut x: i32 = 5; defer x = 99; return x; }\nfn main() i32 { exit(f()); }\n", 5, "");
  // nested-scope defer + return: inner Y runs before outer X.
  sc_run_program(
      "defer nested scope on return",
      PRE "fn g() void { defer putchar('X'); if true { defer putchar('Y'); return; } }\n"
          "fn main() i32 { g(); exit(0); }\n",
      0, "YX");
  // a loop body's defer runs at the end of each iteration, including on `continue`.
  sc_run_program(
      "defer in loop with continue",
      PRE "fn main() i32 { for i in 0..3 { defer putchar('.'); if i == 1 { continue; } putchar(('0' as i32) + i); } exit(0); }\n",
      0, "0..2.");
}

static void test_attributes(void) {
  // @c.always_inline + @c.export compile clean (-Werror) and run; the exported symbol is callable internally.
  sc_run_program(
      "attributes inline + export",
      PRE "@c.always_inline\nfn dbl(x: i32) i32 { return x + x; }\n"
          "@c.export(\"sc_main_value\")\nfn val() i32 { return 21; }\n"
          "fn main() i32 { exit(dbl(val()) - 42); }\n", // 42 - 42
      0, "");
  // @c.import binds a friendly Super-C name to a real libc symbol.
  sc_run_program(
      "attribute import",
      "extern \"C\" { @c.import(\"putchar\") fn emit(c: i32) i32; }\n"
      "fn main() i32 { emit(('A' as i32)); emit(10); return 0; }\n",
      0, "A\n");
}

static void test_static_assert(void) {
  // Passing assertions at item scope (struct layout, arithmetic) and statement scope; the program
  // only compiles (-Werror) if every _Static_assert holds.
  sc_run_program(
      "static_assert",
      PRE "struct Pair { a: i32, b: i32, }\n"
          "static_assert(sizeof(Pair) == 8, \"two i32s\");\n"
          "static_assert(2 * 3 == 6);\n"
          "fn main() i32 { static_assert(sizeof(i64) == 8, \"i64\"); exit(0); }\n",
      0, "");
}

int main(void) {
  test_attributes();
  test_drop_raii();
  test_defer();
  test_static_assert();
  test_interfaces();
  test_string_sso();
  test_unions();
  test_closures();
  test_std_types();
  test_generics_over_user_types();
  test_container_conformances();
  test_str_conformances();
  test_format_printing();
  test_map();
  test_multi_from();
  test_generics();
  test_arithmetic();
  test_control_flow();
  test_recursion();
  test_switch();
  test_if_expression();
  test_array_literals();
  test_slices();
  test_range_slicing();
  test_range_value();
  test_opaque_extern();
  test_variadics();
  test_complex();
  test_atomics();
  test_tuple_destructure();
  test_enums();
  test_mut_match_binding();
  test_structs_and_methods();
  test_let_owning_mut();
  test_field_vs_method();
  test_pointers();
  test_str();
  test_misc();
  if (failures) {
    fprintf(stderr, "%d codegen-run test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("codegen-run tests passed");
  return 0;
}
