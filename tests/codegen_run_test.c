// End-to-end soundness: each program is transpiled, the generated C is compiled warning-clean
// under -Werror -fsanitize=undefined,address, then executed; the process exit code (and stdout
// where relevant) is asserted. This proves the emitted C is correct, not merely plausible -- the
// gap the substring-only codegen_test.c cannot close.
//
// Scope note: enum/tuple values still lack full construction syntax (covered structurally in
// codegen_test.c), but arrays and slices are now behaviorally exercised here -- `[]T`/`[]mut T` lower
// to the prelude Slice<T>/SliceMut<T> views, constructible by array->slice coercion (see test_slices).

#include "test_harness.h"

// Each test_* below is an independent end-to-end program (its own transpile + external cc compile/link/run,
// the dominant cost), so they fan out across cores -- same structure as raii_gen_test. This is sound because
// the compiler keeps no global mutable state, the harness routes cc through popen and publishes cache objects
// atomically, and CHECK bumps `failures` atomically under OpenMP. Without OpenMP the macro vanishes (serial).
#ifdef _OPENMP
#  include <omp.h>
#  define SC_PARALLEL_FOR _Pragma("omp parallel for schedule(dynamic)")
#else
#  define SC_PARALLEL_FOR
#endif

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

// Inside a generic `extend<T> Wrap<T>`, `self: &Self` is the full target type `Wrap<T>` (not the argless
// struct), so a method returning a `T` field unifies with its `T` return type -- no need to spell out
// `self: &Wrap<T>`.
static void test_generic_self_receiver(void) {
  sc_run_program(
      "generic method: &Self returns a T field",
      PRE "struct Wrap<T> { pub a: T, pub b: T }\n"
          "extend<T> Wrap<T> {\n"
          "  fn first(self: &Self) T { return self.a; }\n"
          "  fn swap(self: &Self) Wrap<T> { return Wrap::<T> { a: self.b, b: self.a }; }\n"
          "}\n"
          "fn main() i32 { let w = Wrap::<i32> { a: 30, b: 12 }; let s = w.swap(); exit(w.first() + s.first()); }\n",
      42, ""); // 30 + 12
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
          "  v.free(); exit(r); }\n",
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
          "  v.free(); w.free(); exit(acc); }\n",
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
          "  b.free(); b2.free(); exit(acc); }\n",
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
          "  acc = acc + *m.get(&ka).unwrap_or(&0);\n"           // 10  (get borrows -> &i32)
          "  acc = acc + *m.get(&kk).unwrap_or(&0);\n"           // 39 -> 49
          "  if m.contains_key(&kb) { acc = acc + 100; }\n"      // 149
          "  m.remove(&kb);\n"
          "  if m.get(&kb).is_none() { acc = acc + 1000; }\n"    // 1149
          "  let total = acc; m.free(); exit(total - 1100); }\n", // 49
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
          "  s.print(); s.free();\n"
          "  exit(0); }\n",
      0, "hi world n=42 pi=2.5 ok=true brace={}\n<42>");
  // Hex format specs: `{:x}` lowercase, `{:X}` uppercase, signed (leading '-'), unsigned, and a wide value.
  sc_run_program(
      "hex format specs {:x}/{:X} signed + unsigned + String::from_hex",
      PRE "fn main() i32 {\n"
          "  println(\"dec={} x={:x} X={:X} u={:x} neg={:x}\", 255, 255, 255, 4096 as u32, -255);\n"
          "  let s = String::from_hex(3735928559, false); s.print();\n" // 0xdeadbeef
          "  putchar(10); exit(0); }\n",
      0, "dec=255 x=ff X=FF u=1000 neg=-ff\ndeadbeef\n");
  // A `String` argument over a CUSTOM allocator interpolates correctly: the builder is a `String<Global>`, but
  // the argument's bytes are pushed through its own allocator-agnostic `str` view (`as_str`), so a heap
  // `String<MyAlloc>` is rendered, not skipped. (Earlier the interpolation assumed `String<Global>`.)
  sc_run_program(
      "format interpolates a custom-allocator String argument",
      PRE "extern \"C\" { fn malloc(n: usize) *mut void; fn realloc(p: *mut void, n: usize) *mut void; fn free(p: *mut void) void; }\n"
          "struct Mallocator {}\n"
          "extend Mallocator as Allocator {\n"
          "  fn alloc(self: &mut Mallocator, n: usize, align: usize) *mut void { return malloc(n); }\n"
          "  fn realloc(self: &mut Mallocator, p: *mut void, o: usize, n: usize, align: usize) *mut void { return realloc(p, n); }\n"
          "  fn dealloc(self: &mut Mallocator, p: *mut void, n: usize, align: usize) void { free(p); }\n"
          "}\n"
          "extend Mallocator as Default { fn default() Mallocator { return Mallocator {}; } }\n"
          "fn label() String<Mallocator> { return String::<Mallocator>::from_str(\"a custom-allocated heap label beyond SSO\"); }\n"
          "fn main() i32 {\n"
          "  let mut out = format(\"[{}] #{}\", label(), 7);\n"  // label() is a temporary String<Mallocator>
          "  out.println(); out.free(); exit(0); }\n",
      0, "[a custom-allocated heap label beyond SSO] #7\n");
}

// Bounds checks: an in-bounds array/slice index reads correctly through `__sc_bounds`; a constant
// out-of-range index on a fixed array is a COMPILE-TIME error. (Runtime out-of-range aborts -- verified
// manually; a signal exit can't be asserted through the clean-exit harness.)
static void test_bounds_checks(void) {
  sc_run_program( // in-bounds array index with a dynamic index still reads the right element
      "bounds-checked array index (in bounds)",
      PRE "fn main() i32 { let a: [i32; 3] = [10, 20, 30]; let i: usize = 2; exit(a[i]); }\n", 30, "");
  sc_run_program( // array element is still an lvalue after bounds-checking the index
      "bounds-checked array index is assignable",
      PRE "fn main() i32 { let mut a: [i32; 3] = [1, 2, 3]; let i: usize = 1; a[i] = 41; exit(a[i] + 1); }\n", 42, "");
  sc_run_program( // a slice carries a runtime length; in-bounds index reads correctly
      "bounds-checked slice index (in bounds)",
      PRE "fn main() i32 { let a: [i32; 3] = [7, 8, 9]; let s: []i32 = a[0..3]; let i: usize = 1; exit(s[i] + 34); }\n",
      42, "");
  char first[256];
  const size_t n = sc_stage_errors("const out-of-bounds array index is a compile error",
                                   PRE "fn main() i32 { let a: [i32; 3] = [1, 2, 3]; exit(a[5]); }\n", ST_CODEGEN,
                                   first, sizeof first);
  CHECK(n >= 1, "const OOB index: expected a codegen error");
  if (n)
    CHECK(strstr(first, "out of bounds") != NULL, "const OOB index: message missing 'out of bounds':\n%s", first);
}

// Checked arithmetic: signed +/-/* trap on overflow and integer /,% trap on divide-by-zero at runtime;
// UNSIGNED WRAPS; a constant overflow / divide-by-zero is a COMPILE-TIME error. (Runtime traps abort --
// verified manually; a signal exit isn't assertable through the clean-exit harness.)
static void test_checked_arith(void) {
  sc_run_program( // ordinary in-range signed arithmetic is unchanged
      "checked arithmetic computes normally in range",
      PRE "fn main() i32 { let a: i32 = 40; let b: i32 = 2; exit(a + b); }\n", 42, "");
  sc_run_program( // unsigned overflow wraps (two's complement) -- the prelude's hashing relies on this
      "unsigned arithmetic wraps (no trap)",
      PRE "fn main() i32 { let a: u32 = 4294967295; let b: u32 = 3; let c: u32 = a + b; exit(c as i32); }\n", 2, "");
  char first[256];
  size_t n = sc_stage_errors("constant signed overflow is a compile error",
                             "const X: i32 = 2147483647 + 1;\nfn main() i32 { return 0; }\n", ST_CODEGEN, first,
                             sizeof first);
  CHECK(n >= 1, "const overflow: expected a codegen error");
  if (n)
    CHECK(strstr(first, "overflow") != NULL, "const overflow: message missing 'overflow':\n%s", first);
  n = sc_stage_errors("constant divide-by-zero is a compile error",
                      "const X: i32 = 5 / 0;\nfn main() i32 { return 0; }\n", ST_CODEGEN, first, sizeof first);
  CHECK(n >= 1, "const div-by-zero: expected a codegen error");
  if (n)
    CHECK(strstr(first, "division by zero") != NULL, "const div0: message missing 'division by zero':\n%s", first);
}

// Default generic arguments: an under-applied generic (`Pair<bool>`) fills its trailing params from their
// declared `= <type>` defaults, so `Pair<bool>` == `Pair<bool, i32>` everywhere -- type annotations
// (resolve_type), turbofish + method monomorphization (NODE_GENERIC_SPECIALIZATION), and defaults that
// reference an earlier param (`B = A`, substituted) all build the same complete instance.
// Builtins are nominal types: the core prelude conforms every scalar to Hash/Eq/Ord/Clone/Default via
// `extend`, and user code may `extend i32 { .. }` with its own methods. Covers direct dispatch (i32__eq),
// dispatch through a generic bound (key.hash() in Map, a.cmp() under T: Ord), and the associated function
// path (T::default() -> i32__default_).
static void test_builtin_conformances(void) {
  sc_run_program( // a user extension method on a builtin -> i32__doubled
      "extend i32 with a method",
      PRE "extend i32 { fn doubled(self: i32) i32 { return self * 2; } }\n"
          "fn main() i32 { let x: i32 = 21; exit(x.doubled()); }\n",
      42, "");
  sc_run_program( // Map<i32, V>: builtin keys satisfy Hash + Eq
      "Map over builtin keys (Hash + Eq)",
      PRE "fn main() i32 {\n"
          "  let mut m = Map::<i32, i32>::new();\n"
          "  m.insert(7, 40);\n"
          "  m.insert(8, 2);\n"
          "  let mut r: i32 = 0;\n"
          "  if m.contains_key(&7) { r = r + 40; }\n"
          "  if m.contains_key(&8) { r = r + 2; }\n"
          "  if m.contains_key(&9) { r = r + 100; }\n"
          "  exit(r);\n"
          "}\n",
      42, "");
  sc_run_program( // direct conformance methods on a builtin value
      "builtin eq/hash/clone dispatch",
      PRE "fn main() i32 {\n"
          "  let a: i32 = 21;\n"
          "  let b = a.clone();\n"
          "  let mut r: i32 = 0;\n"
          "  if a.eq(&b) { r = r + 21; }\n"
          "  r = r + (b.hash() as i32);\n" // hash(21) == 21
          "  exit(r);\n"
          "}\n",
      42, "");
  sc_run_program( // Ord on a builtin reached through a generic bound -> i32__cmp
      "builtin Ord through a generic bound",
      PRE "fn max_of<T: Ord>(a: T, b: T) T { if a.cmp(&b) < 0 { return b; } return a; }\n"
          "fn main() i32 { exit(max_of::<i32>(13, 42)); }\n",
      42, "");
  sc_run_program( // associated function on a builtin reached through a bound -> i32__default_
      "builtin Default through T::default()",
      PRE "fn zero<T: Default>() T { return T::default(); }\n"
          "fn main() i32 { exit(zero::<i32>() + 42); }\n",
      42, "");
  sc_run_program( // Copy is a marker interface, but generic bound checking still needs builtin conformance
      "builtin Copy through a generic bound",
      PRE "fn id<T: Copy>(x: T) T { return x; }\n"
          "fn main() i32 { exit(id::<i32>(42)); }\n",
      42, "");
  sc_run_program( // direct complex value methods avoid total Eq/Ord/Hash while still proving value semantics
      "complex Clone Default Copy direct methods",
      PRE "extern \"C\" { fn csqrt(z: c64) c64; fn cabs(z: c64) f64; }\n"
          "fn main() i32 { let i: c64 = csqrt(-1.0); let z: c64 = 3.0 + 4.0 * i; let b = z.clone();\n"
          "  let c: c64 = 0.0; exit((cabs(b) + cabs(c)) as i32 + 37); }\n",
      42, "");
  sc_run_program(
      "builtin inherent scalar methods",
      PRE "fn main() i32 {\n"
          "  let x: i32 = -5; let hi: i32 = 9; let a = x.abs() + x.signum() + hi.clamp(0, 7);\n"
          "  let y: u32 = 8; if !y.is_power_of_two() { exit(1); }\n"
          "  let f: f64 = 9.0; let g: f64 = -2.5; let h: f64 = 8.0;\n"
          "  let p: f32 = 0.0; let q: f32 = 4.0; let s: f32 = p.sin(); let r: f32 = q.sqrt();\n"
          "  let n: f64 = (0.0 as f64) / (0.0 as f64); if !n.is_nan() { exit(2); }\n"
          "  let c: f64 = f.sqrt() + g.abs() + h.log2(); let d: f32 = s + r;\n"
          "  exit(a + c as i32 + d as i32);\n"
          "}\n",
      21, "");
}

static void test_default_generic_args(void) {
  sc_run_program( // type-annotation path fills B=i32
      "default generic arg via type annotation",
      PRE "struct Pair<A, B = i32> { pub a: A, pub b: B }\n"
          "fn main() i32 { let p: Pair<bool> = Pair::<bool> { a: true, b: 42 }; exit(p.b); }\n",
      42, "");
  sc_run_program( // turbofish + a method monomorphized over the default-filled instance
      "default generic arg through a monomorphized method",
      PRE "struct Pair<A, B = i32> { pub a: A, pub b: B }\n"
          "extend<A, B> Pair<A, B> { fn second(self: &Self) B { return self.b; } }\n"
          "fn main() i32 { let p = Pair::<bool> { a: false, b: 42 }; exit(p.second()); }\n",
      42, "");
  sc_run_program( // a default that names an earlier param: `B = A` binds to the supplied A
      "default generic arg referencing an earlier param",
      PRE "struct Dup<A, B = A> { pub a: A, pub b: B }\n"
          "fn main() i32 { let d = Dup::<i32> { a: 19, b: 23 }; exit(d.a + d.b); }\n",
      42, "");
}

// Allocator-typed ownership: a user allocator chosen via turbofish (`Box::<T, A>` / `Vector::<T, A>`) threads
// through allocation, growth (realloc) and auto-Free, distinct from the default `Global` path -- the allocator
// is part of the type, stored in the container and called with self + size/align. Both allocate real memory,
// so this also proves ASan-clean release through the right `dealloc`. (`A` is zero-sized here: no space cost.)
static void test_custom_allocator(void) {
  sc_run_program(
      "custom allocator threads through Box + Vector; Global default alongside",
      PRE "extern \"C\" { fn malloc(size: usize) *mut void; fn realloc(p: *mut void, size: usize) *mut void; fn free(p: *mut void) void; }\n"
          "struct Mallocator {}\n"
          "extend Mallocator as Allocator {\n"
          "  fn alloc(self: &mut Mallocator, size: usize, align: usize) *mut void { return malloc(size); }\n"
          "  fn realloc(self: &mut Mallocator, p: *mut void, old_size: usize, new_size: usize, align: usize) *mut void { return realloc(p, new_size); }\n"
          "  fn dealloc(self: &mut Mallocator, p: *mut void, size: usize, align: usize) void { free(p); }\n"
          "}\n"
          "extend Mallocator as Default { fn default() Mallocator { return Mallocator {}; } }\n"
          "fn main() i32 {\n"
          "  let mut b = Box::<i32, Mallocator>::new(40); b.set(2);\n"     // custom-allocated box
          "  let g = Box::<i32>::new(0);\n"                                 // Global-allocated box (the default)
          "  let mut v = Vector::<i32, Mallocator>::new();\n"
          "  let mut i: i32 = 0; while i < 20 { v.push(i); i = i + 1; }\n"  // forces growth through Mallocator::realloc
          "  let last = v.pop().unwrap_or(0);\n"                            // 19
          "  exit(*b.get() + *g.get() + last + 21); }\n",                   // 2 + 0 + 19 + 21 = 42
      42, "");
  // String is allocator-typed too (SSO: short strings stay inline; long ones allocate through `A`). A custom
  // allocator selected by turbofish drives the heap variant; the allocator is stored beside the SSO union.
  sc_run_program(
      "custom allocator on a heap (non-SSO) String, with auto-Free",
      PRE "extern \"C\" { fn malloc(n: usize) *mut void; fn realloc(p: *mut void, n: usize) *mut void; fn free(p: *mut void) void; }\n"
          "struct Mallocator {}\n"
          "extend Mallocator as Allocator {\n"
          "  fn alloc(self: &mut Mallocator, n: usize, align: usize) *mut void { return malloc(n); }\n"
          "  fn realloc(self: &mut Mallocator, p: *mut void, old_n: usize, n: usize, align: usize) *mut void { return realloc(p, n); }\n"
          "  fn dealloc(self: &mut Mallocator, p: *mut void, n: usize, align: usize) void { free(p); }\n"
          "}\n"
          "extend Mallocator as Default { fn default() Mallocator { return Mallocator {}; } }\n"
          "fn run() i32 {\n"
          "  let mut s = String::<Mallocator>::from_str(\"a long heap string beyond the 23-byte SSO inline buffer\");\n"
          "  s.push_str(\" + more\");\n"           // grows the heap buffer through Mallocator::realloc
          "  let n = s.len() as i32;\n"            // 55 + 7 = 62
          "  s.free();\n"                          // released through Mallocator::dealloc
          "  return n - 20; }\n"                   // 42
          "fn main() i32 { exit(run()); }\n",
      42, "");
  // A default-allocator (`Global`) String alongside an SSO-short String: short stays inline (no alloc), long
  // allocates; both auto-Free. Confirms the SSO discriminant survives the union becoming a generic instance.
  sc_run_program(
      "Global String SSO short vs heap, both auto-Free",
      PRE "fn run() i32 {\n"
          "  let short = String::from_str(\"hi\");\n"                                  // inline, no allocation
          "  let long = String::from_str(\"a heap-backed string that exceeds the small buffer length\");\n"
          "  return (short.len() + long.len()) as i32 - 17; }\n"                       // 2 + 57 - 17 = 42
          "fn main() i32 { exit(run()); }\n",
      42, "");
}

// A STATEFUL allocator: a bump arena owns one buffer; a small Copy handle (`ArenaRef`, just a pointer) is
// stored in each container and bumps the shared arena's offset -- so the allocator carries per-instance state
// (distinct from the zero-sized `Global`). It uses `align` (rounds the bump pointer) and `old_size` (the
// realloc copy), and its `dealloc` is a no-op because the arena reclaims everything at once. Exercised across
// Vector (forces realloc growth), Box, Map, Set and a heap String through `new_in`/`from_str_in` -- the String
// stores the handle outside its SSO union and grows through it -- then released en masse. ASan-clean.
static void test_stateful_allocator(void) {
  sc_run_program(
      "stateful bump-arena allocator stored in Vector/Box/Map/Set (sized + aligned)",
      PRE "extern \"C\" { fn malloc(n: usize) *mut void; fn free(p: *mut void) void; fn memcpy(d: *mut void, s: *const void, n: usize) *mut void; }\n"
          "struct Arena { pub buf: *mut u8, pub off: usize, pub cap: usize, }\n"
          "extend Arena {\n"
          "  fn make(cap: usize) Arena { return Arena { buf: malloc(cap) as *mut u8, off: 0, cap: cap, }; }\n"
          "  fn handle(self: &mut Arena) ArenaRef { return ArenaRef { a: self, }; }\n"
          "  fn used(self: &Arena) usize { return self.off; }\n"
          "  fn free(self: &mut Arena) { free(self.buf as *mut void); self.buf = null; self.off = 0; self.cap = 0; }\n"
          "}\n"
          "struct ArenaRef { pub a: *mut Arena, }\n"
          "extend ArenaRef as Allocator {\n"
          "  fn alloc(self: &mut ArenaRef, size: usize, align: usize) *mut void {\n"
          "    let mut off = self.a[0].off; let rem = off % align;\n"
          "    if rem != 0 { off = off + (align - rem); }\n"                          // align the bump pointer
          "    let p = ((self.a[0].buf as usize) + off) as *mut void;\n"
          "    self.a[0].off = off + size; return p;\n"
          "  }\n"
          "  fn realloc(self: &mut ArenaRef, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {\n"
          "    let np = self.alloc(new_size, align);\n"
          "    if ptr != null { if old_size > 0 { memcpy(np, ptr as *const void, old_size); } }\n" // copy old_size bytes
          "    return np;\n"
          "  }\n"
          "  fn dealloc(self: &mut ArenaRef, ptr: *mut void, size: usize, align: usize) void { }\n" // reclaimed en masse
          "}\n"
          "fn main() i32 {\n"
          "  let mut arena = Arena::make(8192);\n"
          "  let h = arena.handle();\n"
          "  let mut v = Vector::<i32, ArenaRef>::new_in(h);\n"
          "  let mut i = 0; while i < 50 { v.push(i); i = i + 1; }\n"                  // realloc growth via the arena
          "  let mut b = Box::<i64, ArenaRef>::new_in(h, 1000);\n"
          "  let mut m = Map::<i32, i32, ArenaRef>::new_in(h); m.insert(7, 70); m.insert(8, 80);\n"
          "  let mut s = Set::<i32, ArenaRef>::new_in(h); s.insert(9); s.insert(9); s.insert(10);\n"
          "  let mut str1 = String::<ArenaRef>::from_str_in(h, \"an arena-backed heap string beyond the inline budget\");\n"
          "  str1.push_str(\" grown through the stored handle\");\n"                    // realloc via the stored arena handle
          "  let str_ok = str1.eq_str(\"an arena-backed heap string beyond the inline budget grown through the stored handle\");\n"
          "  let mut sum: i64 = *b.get();\n"
          "  let mut k: usize = 0; while k < 50 { sum = sum + ((*v.at(k)) as i64); k = k + 1; }\n" // 0..49 -> 1225
          "  sum = sum + ((*m.get(&7).unwrap_or(&0)) as i64) + (s.len() as i64);\n"    // +70 +2
          "  v.free(); b.free(); m.free(); s.free(); str1.free();\n"                  // dealloc is a no-op
          "  let touched = arena.used() > 0; arena.free();\n"                          // whole arena freed at once
          "  if touched && str_ok { exit((sum - 2255) as i32); }\n"                   // 1000+1225+70+2 = 2297 -> 42
          "  exit(1); }\n",
      42, "");
}

// Set<T, A = Global>: a hash set. Insert dedups (per Eq), `contains` borrows a lookup key, `remove` reports
// presence, `len`/`is_empty` track size. Over a Free element (String) the duplicate is freed on insert, the
// stored key is freed on remove, and scope-exit auto-Free deep-frees the rest -- all exactly-once, ASan-clean.
static void test_set(void) {
  sc_run_program(
      "Set<i32>: insert dedup, contains, remove, len",
      PRE "fn main() i32 {\n"
          "  let mut s = Set::<i32>::new();\n"
          "  s.insert(1); s.insert(2); s.insert(2); s.insert(3);\n"  // dedup -> {1,2,3}
          "  let mut acc = s.len() as i32;\n"                         // 3
          "  if s.contains(&2) { acc = acc + 10; }\n"                 // 13
          "  if s.remove(&2) { acc = acc + 100; }\n"                  // 113
          "  if !s.contains(&2) { acc = acc + 1000; }\n"             // 1113
          "  acc = acc + (s.len() as i32);\n"                         // +2 = 1115
          "  s.free();\n"
          "  exit(acc - 1073); }\n",                                  // 1115 - 1073 = 42
      42, "");
  sc_run_program(
      "Set<String>: dedup frees the duplicate, deep auto-Free",
      PRE "fn main() i32 {\n"
          "  let mut s = Set::<String>::new();\n"
          "  s.insert(String::from_str(\"alpha heap key beyond the inline buffer length\"));\n"
          "  s.insert(String::from_str(\"beta heap key beyond the inline buffer length too\"));\n"
          "  s.insert(String::from_str(\"alpha heap key beyond the inline buffer length\"));\n" // dup -> freed
          "  let mut acc = s.len() as i32;\n"                         // 2 (alpha, beta)
          "  let mut k = String::from_str(\"beta heap key beyond the inline buffer length too\");\n"
          "  if s.contains(&k) { acc = acc + 40; }\n"                 // 42
          "  k.free(); s.free();\n"                                   // s.free() deep-frees the remaining keys
          "  exit(acc); }\n",
      42, "");
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

// Multiple `From` extends on one type: each `from`/`into` is disambiguated by source type, so the C symbols
// (Celsius__from__i32, Celsius__from__u8) do not collide and each call routes to the right one.
static void test_multi_from(void) {
  sc_run_program(
      "two From extends: Type::from(x) and x.into() route by source type",
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

// D#12: a generic instance held BY VALUE inside another (`Option<Vector<i32>>` -- Option's payload is a
// Vector<i32>, not a pointer to one) needs the inner specialization defined before the outer in the
// single-TU output. The emitter topologically orders specializations so this compiles in the REPL/test path
// too (it always worked in the multi-file build via per-module headers).
static void test_nested_generic_by_value(void) {
  sc_run_program(
      "nested generic instance by value (single-TU ordering)",
      PRE "fn main() i32 { let mut v = Vector::<i32>::new(); v.push(40); v.push(2);\n"
          "  let o: Option<Vector<i32>> = Option::<Vector<i32>>::some(v);\n"
          "  let mut w = o.unwrap_or(Vector::<i32>::new());\n"
          "  let mut acc = 0; for x in w.iter() { acc = acc + *x; } w.free(); exit(acc); }\n", // iter borrows -> &i32
      42, "");
  // Option<String> holds a String by value: the String struct must precede Option__String in the output.
  sc_run_program(
      "Option<prelude struct> by value (single-TU ordering)",
      PRE "fn main() i32 { let s = String::from(\"hi\");\n"
          "  let o: Option<String> = Option::<String>::some(s);\n"
          "  let mut w = o.unwrap_or(String::from(\"\"));\n"
          "  let n = w.len() as i32; w.free(); exit(n); }\n",
      2, "");
  // case (c): a user concrete struct holding a generic instance BY VALUE.
  sc_run_program(
      "concrete struct holds generic instance by value (single-TU ordering)",
      PRE "struct Holder { pub o: Option<i32> }\n"
          "fn main() i32 { let h = Holder { o: Option::<i32>::some(42) }; exit(h.o.unwrap_or(0)); }\n",
      42, "");
}

// The std/ generic container types (Option, Result, Box, Vector) exercised end-to-end: they are prelude
// modules, so this proves cross-module generic instances + methods + sizeof + rvalue-receiver chaining.
static void test_std_types(void) {
  // sizeof(T) lowers to C's sizeof and is usize-typed (the byte sizes back the heap containers).
  sc_run_program("sizeof", PRE "fn main() i32 { exit(((sizeof(i32) + sizeof(u8)) as i32) * 8 + 2); }\n", 42, ""); // (4+1)*8+2
  // Standard-interface conformances on prelude types: String Eq/Ord/Clone/Default/From, Vector/Option
  // Default, dispatched through a generic `T: Ord` bound and the expected-type `Default::default()`.
  sc_run_program(
      "std interface conformances",
      PRE "fn pick<T: Ord>(a: T, b: T) T { if a.cmp(&b) >= 0 { return a; } return b; }\n"
          "fn main() i32 { let mut x: String = String::from(\"apple\"); let mut y: String = String::from(\"banana\");\n"
          "  let mut acc = 0; if x.cmp(&y) < 0 { acc = acc + 1; } if x.eq(&y) { acc = acc + 1000; }\n"
          "  let mut big = pick::<String>(x.clone(), y.clone()); big.print();\n"
          "  let mut d: String = Default::default(); if d.len() == 0 { acc = acc + 10; }\n"
          "  let mut v: Vector<i32> = Default::default(); v.push(7); acc = acc + (v.len() as i32) * 100;\n"
          "  let o: Option<i32> = Default::default(); acc = acc + o.unwrap_or(0); v.free(); x.free(); y.free(); big.free(); d.free(); exit(acc); }\n",
      111, "banana"); // 1 + 10 + 100
  // Vector is iterable via `.iter()` (VecIter implements Iterator), driving the for-loop desugar.
  sc_run_program(
      "std Vector for-loop via .iter()",
      PRE "fn main() i32 { let mut v = Vector::<i32>::new(); v.push(10); v.push(20); v.push(12);\n"
          "  let mut sum = 0; for x in v.iter() { sum = sum + *x; } v.free(); exit(sum); }\n", // iter borrows -> &i32
      42, "");
  // String numeric formatting: from_i64 / from_u64 / push_i64 / push_f64.
  sc_run_program(
      "std String int/float to-string",
      PRE "fn main() i32 { let mut a = String::from_i64(-12345); a.print(); putchar(32);\n"
          "  let mut s = String::from_str(\"x=\"); s.push_i64(42); s.push_byte(32); s.push_f64(3.5); s.println();\n"
          "  let n = a.len(); a.free(); s.free(); exit(n as i32); }\n",
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
          "  let r: i32 = *b.get() + old; b.free(); exit(r); }\n", // get borrows -> &i32
      42, ""); // 2 + 40
  sc_run_program(
      "std Vector push/pop/get",
      PRE "fn main() i32 { let mut v: Vector<i32> = Vector::<i32>::new();\n"
          "  for i in 0..10 { v.push(i * 3); }\n"                              // [0,3,..,27], len 10
          "  let r: i32 = *v.at(2) + v.pop().unwrap_or(0) + *v.get(50).unwrap_or(&9);\n" // 6 + 27 + 9 (peeks borrow)
          "  v.free(); exit(r); }\n",
      42, "");
  sc_run_program(
      "std Vector capacity/set/first/last",
      PRE "fn main() i32 { let mut v: Vector<i32> = Vector::<i32>::with_capacity(4);\n"
          "  v.push(1); v.push(2); v.push(3);\n"
          "  v.set(0, 12); v.set(1, 18); v.set(2, 12);\n"
          "  let r: i32 = *v.first().unwrap_or(&0) + *v.at(1) + *v.last().unwrap_or(&0);\n" // 12 + 18 + 12 (peeks borrow)
          "  v.free(); exit(r); }\n",
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
      PRE "fn dbl(x: &i32) i32 { return *x * 2; }\n"
          "fn even(x: &i32) bool { return *x % 2 == 0; }\n"
          "fn main() i32 { let mut v: Vector<i32> = Vector::<i32>::new();\n"
          "  v.push(1); v.push(2); v.push(3); v.push(4);\n"     // [1,2,3,4]
          "  v.insert(0, 9);\n"                                  // [9,1,2,3,4]
          "  let r0: i32 = v.remove(1).unwrap_or(0);\n"          // removes 1 -> [9,2,3,4]; r0=1
          "  let sr: i32 = v.swap_remove(0).unwrap_or(0);\n"     // removes 9 -> [4,2,3]; sr=9
          "  v.reverse();\n"                                     // [3,2,4]
          "  let fd: i32 = *v.find(even).unwrap_or(&0);\n"       // 2 (find borrows -> &i32)
          "  v.retain(even);\n"                                  // [2,4]
          "  let mut m: Vector<i32> = v.map(dbl);\n"             // [4,8]
          "  let r: i32 = r0 + sr + fd + *m.at(0) + *m.at(1) + (v.len() as i32);\n" // 1+9+2+4+8+2 = 26 (at borrows)
          "  v.free(); m.free(); exit(r + 16); }\n",             // 26 + 16
      42, "");
  // Box higher-order map (allocates a fresh box of the mapped type).
  sc_run_program(
      "std Box map",
      PRE "fn dbl(x: i32) i32 { return x * 2; }\n"
          "fn main() i32 { let b: Box<i32> = Box::<i32>::new(21);\n"
          "  let mut c: Box<i32> = b.map(dbl);\n"
          "  let r: i32 = *c.get(); c.free(); exit(r); }\n", // get borrows -> &i32
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
          "  let fd: i32 = *vec.find(|x: &i32| *x > 2).unwrap_or(&0);\n" // 3 (find borrows -> &i32)
          "  let mut d: Vector<i32> = vec.map(|x: &i32| *x * 2);\n"    // [2,4,6,8]
          "  let s: i32 = *d.at(0) + *d.at(2) + *d.at(3);\n"        // 2+6+8 = 16 (at borrows)
          "  vec.free(); d.free();\n"
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
          "  s.free(); exit(c); }\n",
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
          "  let r: i32 = s.len() as i32 + 37; s.free(); exit(r); }\n",            // 5 + 37
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
      PRE "interface Free { fn free(self: *mut Self) i32; }\n"
          "struct Res { pub id: i32 }\nextend Res as Free { fn free(self: *mut Self) i32 { return self.id; } }\n"
          "struct Box<T> { pub inner: T }\n"
          "extend<T: Free> Box<T> as Free { fn free(self: &mut Box<T>) i32 { return self.inner.free(); } }\n"
          "fn dispose<U: Free>(x: &mut U) i32 { return x.free(); }\n"
          "fn main() i32 { let mut b = Box::<Res> { inner: Res { id: 99 } }; exit(dispose(&mut b)); }\n",
      99, "");
  sc_run_program(
      "interface: Self-returning method",
      PRE "interface Clone { fn dup(self: *mut Self) Self; }\n"
          "struct P { pub x: i32 }\nextend P as Clone { fn dup(self: *mut Self) Self { return P { x: self.x }; } }\n"
          "fn copy_of<T: Clone>(w: &mut T) T { return w.dup(); }\n"
          "fn main() i32 { let mut p = P { x: 7 }; let q = copy_of(&mut p); exit(q.x); }\n",
      7, "");
  // static (no-self) interface method on a type parameter: `T::default()` dispatches to the concrete extend.
  sc_run_program(
      "interface: static method on a type param",
      PRE "interface Default { fn default() Self; }\n"
          "struct Q { pub x: i32 }\nextend Q as Default { fn default() Q { return Q { x: 7 }; } }\n"
          "fn make<T: Default>() T { return T::default(); }\n"
          "fn main() i32 { let q = make::<Q>(); exit(q.x); }\n",
      7, "");
  // `Interface::assoc()` resolved by the expected (annotation) type: `Default::default()` -> `R__default`.
  sc_run_program(
      "interface: Interface::assoc() resolved by expected type",
      PRE "interface Default { fn default() Self; }\n"
          "struct R { pub x: i32, pub y: i32 }\nextend R as Default { fn default() R { return R { x: 5, y: 9 }; } }\n"
          "fn main() i32 { let r: R = Default::default(); exit(r.x + r.y); }\n",
      14, "");
  // `.into()` desugars to the target type's `From` extend, picked via the expected (annotation) type.
  sc_run_program(
      "interface: .into() via From",
      PRE "interface From<T> { fn from(value: T) Self; }\n"
          "struct C { pub d: i32 }\nstruct F { pub d: i32 }\n"
          "extend F as From<C> { fn from(value: C) F { return F { d: value.d * 9 / 5 + 32 }; } }\n"
          "fn main() i32 { let c = C { d: 100 }; let f: F = c.into(); exit(f.d); }\n",
      212, "");
  // `.try_into()` desugars to the target type's `TryFrom` extend (result is a `Result<U, E>`).
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
  // interface DEFAULT methods: extend provides `eq`/`cmp`; `ne` (from Eq) and `lt`/`ge` (from Ord) are inherited.
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

// E#15 operator overloading: `+ - * / %` on a struct/instance operand dispatch to its add/sub/mul/div/rem
// method (result = the method's return), and `obj[i]` to its `index` method. A bare method of the right
// name is enough (no interface conformance required); builtin numeric/array indexing is untouched.
static void test_operator_overloading(void) {
  sc_run_program(
      "operator overload: arithmetic + index on a struct",
      PRE "struct Point { pub x: i32, pub y: i32 }\n"
          "extend Point {\n"
          "  fn add(self: &Self, o: &Self) Point { return Point { x: self.x + o.x, y: self.y + o.y }; }\n"
          "  fn sub(self: &Self, o: &Self) Point { return Point { x: self.x - o.x, y: self.y - o.y }; }\n"
          "  fn index(self: &Self, i: usize) i32 { if i == 0 { return self.x; } return self.y; }\n"
          "}\n"
          "fn main() i32 { let a = Point { x: 10, y: 20 }; let b = Point { x: 3, y: 4 };\n"
          "  let c = (a + b) - Point { x: 1, y: 2 };\n" // {12, 22}
          "  exit(c[0] + c[1]); }\n",                    // 34
      34, "");
  // a generic-instance operand dispatches the same way (the extend's generics substitute into the result).
  sc_run_program(
      "operator overload: index on a generic instance",
      PRE "struct Wrap<T> { pub a: T, pub b: T }\n"
          "extend<T> Wrap<T> { fn index(self: &Self, i: usize) T { if i == 0 { return self.a; } return self.b; } }\n"
          "fn main() i32 { let w = Wrap::<i32> { a: 30, b: 12 }; exit(w[0] + w[1]); }\n", // 42
      42, "");
  // builtin numeric arithmetic and array indexing are unaffected by the overload path.
  sc_run_program(
      "operator overload: builtins untouched",
      PRE "fn main() i32 { let arr = [40, 2]; exit(arr[0] + arr[1] + (10 * 0)); }\n", 42, "");
}

// The Index / IndexMut interfaces: `obj[i]` through a reference-returning `index` is the element PLACE
// (read via auto-deref, written -- plain and compound -- through `index_mut`), and `obj[lo..hi]` in every
// range form (closed, inclusive `..=`, open start, open end via `len()`) dispatches to `index_range` with
// the bounds packed into a `Range<usize>`. Covers a user conformance and the std ones (Vector, str, String).
static void test_index_interface(void) {
  sc_run_program(
      "Index/IndexMut: user type, places + every range form",
      PRE "struct Buf { pub data: [i32; 8], pub n: usize }\n"
          "extend Buf { pub fn len(self: &Buf) usize { return self.n; } }\n"
          "extend Buf as Index<i32, []i32> {\n"
          "  pub fn index(self: &Buf, i: usize) &i32 { return &self.data[i]; }\n"
          "  pub fn index_range(self: &Buf, r: Range<usize>) []i32 {\n"
          "    let hi = if r.inclusive { r.end + 1; } else { r.end; };\n"
          "    return self.data[r.start..hi];\n"
          "  }\n"
          "}\n"
          "extend Buf as IndexMut<i32, []mut i32> {\n"
          "  pub fn index_mut(self: &mut Buf, i: usize) &mut i32 { return &mut self.data[i]; }\n"
          "  pub fn index_range_mut(self: &mut Buf, r: Range<usize>) []mut i32 {\n"
          "    let hi = if r.inclusive { r.end + 1; } else { r.end; };\n"
          "    return SliceMut::<i32> { ptr: ((&mut self.data[0]) as *mut i32) + r.start, len: hi - r.start, };\n"
          "  }\n"
          "}\n"
          "fn main() i32 {\n"
          "  let mut b = Buf { data: [10, 20, 30, 40, 50, 60, 70, 80], n: 8 };\n"
          "  b[2] = 5; b[3] += 2;\n"                                          // write + compound -> 5, 42
          "  let s1 = b[1..4]; let s2 = b[..2]; let s3 = b[6..]; let s4 = b[5..=6];\n"
          "  let mut w = b.index_range_mut(Range::<usize> { start: 0, end: 1, inclusive: false });\n"
          "  w.set(0, 3);\n"                                                  // mut view writes back
          "  exit(b[0] + s1.get(1) + s2.len() as i32 + s3.get(1) + s4.get(0)); }\n", // 3+5+2+80+60 = 150
      150, "");
  sc_run_program(
      "Index/IndexMut: Vector places and range views",
      PRE "fn main() i32 {\n"
          "  let mut v = Vector::<i32>::new();\n"
          "  let mut i = 0; while i < 8 { v.push(i * 10); i = i + 1; }\n"
          "  v[0] = 7; v[1] += 3;\n"                                          // 7, 13
          "  let a = v[2..5]; let b = v[..3]; let c = v[6..]; let d = v[4..=6];\n"
          "  exit(v[0] + v[1] + a.get(0) + b.len() as i32 + c.get(1) + d.get(2)); }\n", // 7+13+20+3+70+60 = 173
      173, "");
  sc_run_program(
      "Index: str and String byte places + str sub-views",
      PRE "fn main() i32 {\n"
          "  let s = \"hello world\";\n"
          "  let hello = s[..5]; let world = s[6..]; let ell = s[1..=3];\n"
          "  let owned = \"abcdef\".to_string();\n"
          "  let mid = owned[1..4];\n"
          "  let mut acc = 0;\n"
          "  if hello.eq(&\"hello\") { acc = acc + 1; }\n"
          "  if world.eq(&\"world\") { acc = acc + 10; }\n"
          "  if ell.eq(&\"ell\") { acc = acc + 100; }\n"
          "  if mid.eq(&\"bcd\") { acc = acc + 1000; }\n"
          "  if s[4] == 111 { acc = acc + 10000; }\n"      // 'o'
          "  if owned[2] == 99 { acc = acc + 100000; }\n"  // 'c'
          "  exit(acc / 1361); }\n",                       // 111111 / 1361 = 81 (all six hit)
      81, "");
  // A plain `=` over a Free element frees the replaced value before the store (like Vector::set).
  // Only the replacement's free prints: `exit()` terminates before main's scope-exit RAII runs.
  sc_run_program(
      "IndexMut: plain = frees the replaced Free element",
      PRE "struct R { pub id: i32 }\n"
          "extend R as Free { fn free(self: &mut R) { putchar(48 + self.id); } }\n"
          "fn main() i32 {\n"
          "  let mut v = Vector::<R>::new();\n"
          "  v.push(R { id: 1 });\n"
          "  v[0] = R { id: 2 };\n" // frees id 1 here, before the store
          "  exit(0); }\n",
      0, "1");
}

// E#14 `?` early-return operator: `expr?` unwraps Some/Ok, or returns None/Err (carrying the error) from
// the enclosing function -- running its pending defers first, like a `return`.
static void test_question_operator(void) {
  sc_run_program(
      "? unwraps Some and propagates None",
      PRE "fn checked(n: i32) Option<i32> { let o = Option::<i32>::some(n); let v = o?; return Option::<i32>::some(v + 1); }\n"
          "fn first(o: Option<i32>) Option<i32> { let v = o?; return Option::<i32>::some(v); }\n"
          "fn main() i32 { let a = switch checked(41) { Some(v) => v, None => 0, };\n" // 42
          "  let b = switch first(Option::<i32>::none()) { Some(_) => 1, None => 100, }; exit(a + b - 100); }\n", // 42
      42, "");
  sc_run_program(
      "? unwraps Ok and propagates Err",
      PRE "fn rdiv(a: i32, b: i32) Result<i32, i32> { if b == 0 { return Result::<i32, i32>::err(9); }\n"
          "  return Result::<i32, i32>::ok(a / b); }\n"
          "fn calc() Result<i32, i32> { let x = rdiv(84, 2)?; let y = rdiv(x, 0)?; return Result::<i32, i32>::ok(y); }\n"
          "fn main() i32 { exit(switch calc() { Ok(v) => v, Err(e) => 33 + e, }); }\n", // rdiv(x,0) -> Err(9) -> 42
      42, "");
  sc_run_program(
      "? runs pending defers on the early return",
      PRE "fn g() Option<i32> { defer putchar('D'); let v = Option::<i32>::none()?; putchar('Z'); return Option::<i32>::some(v); }\n"
          "fn main() i32 { let r = switch g() { Some(_) => 1, None => 2, }; putchar(10); exit(r - 2); }\n",
      0, "D\n"); // 'D' from the defer, never 'Z'; g() returns None -> r == 2 -> exit 0
}

static void test_free_raii(void) {
#define FREE_PRE                                                                                                        \
  PRE "interface Free { fn free(self: &mut Self); }\n"                                                                  \
      "struct R { pub tag: i32 }\n"                                                                                     \
      "extend R as Free { fn free(self: &mut Self) { putchar(self.tag); } }\n"
  // RAII: locals are freed at scope exit in reverse construction order.
  sc_run_program(
      "free: reverse-order scope-exit cleanup",
      FREE_PRE "fn run() void { let a = R { tag: 65 }; let b = R { tag: 66 }; putchar(88); }\n"
               "fn main() i32 { run(); exit(0); }\n",
      0, "XBA"); // X, then free b (B) then a (A)
  // a moved binding is not freed at the source scope (no double-free); the new owner frees it.
  sc_run_program(
      "free: moved value is not auto-freed",
      FREE_PRE "fn run() void { let a = R { tag: 65 }; let b = a; putchar(88); }\n"
               "fn main() i32 { run(); exit(0); }\n",
      0, "XA"); // only b (holding tag 65 = A) frees; a was moved
  // a by-value Free parameter is owned by the callee, which frees it; the caller does not re-free.
  sc_run_program(
      "free: by-value parameter ownership transfer",
      FREE_PRE "fn consume(r: R) void { putchar(67); }\n"
               "fn run() void { let a = R { tag: 65 }; consume(a); putchar(88); }\n"
               "fn main() i32 { run(); exit(0); }\n",
      0, "CAX"); // consume prints C then frees its param (A); then X; a was moved, run frees nothing
  // RAII and defer share one reverse-order cleanup sequence.
  sc_run_program(
      "free: interleaves with defer",
      FREE_PRE "fn run() void { let a = R { tag: 65 }; defer putchar(68); let b = R { tag: 66 }; putchar(88); }\n"
               "fn main() i32 { run(); exit(0); }\n",
      0, "XBDA"); // X, then reverse of [free a, defer D, free b]: b(B), D, a(A)
#undef FREE_PRE
}

// D#10: a binding moved on only SOME control-flow paths gets a runtime free flag, so it is freed EXACTLY
// once -- skipped on the path that moved it out, run on the path that did not (no leak, no double-free).
static void test_conditional_move_free(void) {
#define CM_PRE                                                                                                          \
  PRE "interface Free { fn free(self: &mut Self); }\n"                                                                  \
      "struct R { pub tag: i32 }\n"                                                                                     \
      "extend R as Free { fn free(self: &mut Self) { putchar(self.tag); } }\n"                                          \
      "fn consume(r: R) void { }\n"
  // moved in the then-branch only: when taken, consume frees it; when not, the scope-exit free runs.
  sc_run_program(
      "free: conditional move, branch taken",
      CM_PRE "fn run(c: bool) void { let a = R { tag: 65 }; if c { consume(a); } }\n"
             "fn main() i32 { run(true); run(false); exit(0); }\n",
      0, "AA"); // taken: consume frees A; not taken: auto-free A -> one A per call, never zero or two
  // moved on BOTH arms: the flag is set on either path, so the scope-exit free is always skipped (consume owns it).
  sc_run_program(
      "free: moved on both branches",
      CM_PRE "fn run(c: bool) void { let a = R { tag: 65 }; if c { consume(a); } else { consume(a); } }\n"
             "fn main() i32 { run(true); run(false); exit(0); }\n",
      0, "AA"); // each call: exactly one free (inside consume), none leaked, none double
  // a fresh flag per loop iteration: moved only when i==1, freed otherwise -> three frees total.
  sc_run_program(
      "free: conditional move inside a loop",
      CM_PRE "fn main() i32 { let mut i = 0; while i < 3 { let a = R { tag: 65 }; if i == 1 { consume(a); } i = i + 1; } exit(0); }\n",
      0, "AAA");
#undef CM_PRE
}

// A#1: Free-RAII on a GENERIC container. A `Box<T>` conditionally conforming to Free (`extend<T: Free>
// Box<T> as Free`) auto-frees at scope exit, recursively freeing its element; moving it into a consumer
// suppresses the source's free; a conditional move is flag-guarded so it frees exactly once on each path.
// This is the compiler machinery a full prelude container migration to auto-Free rests on.
static void test_container_free_raii(void) {
#define BOX_PRE                                                                                                         \
  PRE "interface Free { fn free(self: &mut Self); }\n"                                                                  \
      "struct Leaf { pub id: i32 }\n"                                                                                   \
      "extend Leaf as Free { fn free(self: &mut Self) { putchar(self.id); } }\n"                                        \
      "struct Box<T> { pub inner: T }\n"                                                                                \
      "extend<T: Free> Box<T> as Free { fn free(self: &mut Box<T>) { self.inner.free(); } }\n"                          \
      "fn take(b: Box<Leaf>) void { }\n"
  sc_run_program("container RAII: scope-exit recursive auto-free",
                 BOX_PRE "fn run() void { let a = Box::<Leaf> { inner: Leaf { id: 65 } }; putchar(88); }\n"
                         "fn main() i32 { run(); exit(0); }\n",
                 0, "XA"); // X, then free a -> its inner Leaf (A)
  sc_run_program("container RAII: move into consumer suppresses source free",
                 BOX_PRE "fn run() void { let a = Box::<Leaf> { inner: Leaf { id: 65 } }; take(a); putchar(88); }\n"
                         "fn main() i32 { run(); exit(0); }\n",
                 0, "AX"); // take frees a (A), then X; the source is not re-freed
  sc_run_program("container RAII: conditional move frees once per path",
                 BOX_PRE "fn run(c: bool) void { let a = Box::<Leaf> { inner: Leaf { id: 65 } }; if c { take(a); } }\n"
                         "fn main() i32 { run(true); run(false); exit(0); }\n",
                 0, "AA"); // taken: consumer frees; not taken: scope-exit frees -- one A each call
  // a CONDITIONAL explicit `a.free()` consumes the receiver: the flag is set around the call (the receiver
  // is taken by address, so it cannot be wrapped as a comma-expr), and the scope-exit auto-free is guarded.
  sc_run_program("container RAII: conditional explicit free is not double-freed",
                 BOX_PRE "fn run(c: bool) void { let mut a = Box::<Leaf> { inner: Leaf { id: 65 } }; if c { a.free(); } }\n"
                         "fn main() i32 { run(true); run(false); exit(0); }\n",
                 0, "AA"); // taken: explicit free (A), auto-free suppressed; not taken: auto-free (A)
#undef BOX_PRE
}

// `.free()` is the Free intrinsic: callable on ANY type, it runs the type's Free extend or is a no-op
// when the type isn't Free -- resolved per monomorphization. This is what lets generic code (and a generic
// container's element teardown) free uniformly without a `T: Free` bound.
static void test_free_intrinsic(void) {
#define FI_PRE                                                                                                         \
  PRE "interface Free { fn free(self: &mut Self); }\n"                                                                \
      "struct Leaf { pub id: i32 }\n"                                                                                  \
      "extend Leaf as Free { fn free(self: &mut Self) { putchar(self.id); } }\n"
  sc_run_program("free intrinsic: Free type frees, non-Free is a no-op (via a generic)",
                 FI_PRE "fn dispose<T>(mut x: T) void { x.free(); }\n"
                        "fn main() i32 { dispose::<Leaf>(Leaf { id: 65 }); dispose::<i32>(7); putchar(10); exit(0); }\n",
                 0, "A\n"); // Leaf freed once (A, explicit free consumes -> no double auto-free); i32 free is a no-op
#undef FI_PRE
}

// The std prelude containers (Vector/Box/Map) are auto-`Free` and deep-free their heap-owning elements,
// while the peek accessors borrow (`&T` / `Option<&T>`) -- so an element peeked while the container is
// still alive is freed exactly once at scope exit: no double-free, no use-after-free (the harness builds
// with -fsanitize=address). RAII fires only on scope exit, so the work RETURNS (calling exit() would skip
// cleanup and defeat the check). Strings are >23 bytes to force a heap buffer ASan can track.
static void test_std_container_auto_free(void) {
  // Vector<String>: borrow-peek via at / iter / get, then the vector deep-auto-frees every String + buffer.
  sc_run_program(
      "auto-Free Vector<String> with borrow peeks (no manual free)",
      PRE "fn run() i32 {\n"
          "  let mut v = Vector::<String>::new();\n"
          "  v.push(String::from_str(\"this string is long enough to live on the heap\"));\n"
          "  v.push(String::from_str(\"and so is this second heap-allocated string too!\"));\n"
          "  let mut acc = 0;\n"
          "  if v.at(0).len() > 23 { acc = acc + 10; }\n"               // borrow &String, still v-owned
          "  for s in v.iter() { if s.len() > 23 { acc = acc + 1; } }\n" // s: &String -> 12
          "  if v.get(1).is_some() { acc = acc + 30; }\n"               // 42
          "  return acc;\n"                                             // v auto-frees (deep) -- ASan-checked
          "}\n"
          "fn main() i32 { exit(run()); }\n",
      42, "");
  // Box<String> auto-frees the boxed heap String; Map<String,i32> deep-frees its String keys. `get` borrows.
  sc_run_program(
      "auto-Free Box<String> + Map<String,i32> (deep, no manual free)",
      PRE "fn run() i32 {\n"
          "  let b = Box::<String>::new(String::from_str(\"a boxed heap string beyond the small buffer\"));\n"
          "  let mut acc = 0;\n"
          "  if b.get().len() > 23 { acc = acc + 6; }\n"                // borrow &String
          "  let mut m = Map::<String, i32>::new();\n"
          "  m.insert(String::from_str(\"a sufficiently long heap key for the map\"), 36);\n"
          "  let key = String::from_str(\"a sufficiently long heap key for the map\");\n"
          "  acc = acc + *m.get(&key).unwrap_or(&0);\n"                 // 36 -> 42 (get borrows -> &i32)
          "  return acc;\n"                                            // key, b, m all auto-free (deep)
          "}\n"
          "fn main() i32 { exit(run()); }\n",
      42, "");
  // USER-defined Free element types deep-free through the cross-module macro path too (output proves each is
  // freed EXACTLY once: a missing char = leak, a doubled char = double-free). Covers Vector/Box deep-free
  // and a combinator free (Option::and) over a user Free type -- the `.free()` intrinsic pastes the arg's
  // `__free` in the macro template (a guarded no-op stub backs non-Free args).
  sc_run_program(
      "user Free element deep-frees via macro path, exactly once",
      PRE "struct Tr { pub id: i32 }\n"
          "extend Tr as Free { fn free(self: &mut Tr) { putchar(self.id); } }\n"
          "fn run() void {\n"
          "  let mut v = Vector::<Tr>::new(); v.push(Tr { id: 66 }); v.push(Tr { id: 67 });\n" // B C at scope exit
          "  let bx = Box::<Tr>::new(Tr { id: 68 });\n"                                         // D at scope exit
          "  let freed = Option::<Tr>::Some(Tr { id: 65 }).and(Option::<i32>::Some(0));\n"    // A now (and)
          "  if freed.is_none() { putchar(63); }\n"            // not reached
          "}\n"
          "fn main() i32 { run(); putchar(10); exit(0); }\n",
      0, "ADBC\n"); // A (and, eager), then scope exit LIFO: D (bx), then B C (vector elements)
  // The remover path: pop MOVES the String out of the vector (so the vector no longer frees it); the
  // moved-out value is the sole owner. The remaining element still deep-auto-frees -- each heap buffer once.
  sc_run_program(
      "auto-Free Vector<String> pop moves ownership out",
      PRE "fn run() i32 {\n"
          "  let mut v = Vector::<String>::new();\n"
          "  v.push(String::from_str(\"first long heap string for the move-out test\"));\n"
          "  v.push(String::from_str(\"second long heap string for the move-out test\"));\n"
          "  let mut popped = v.pop().unwrap_or(String::new());\n"      // 2nd String moves out of v
          "  let n = popped.len() as i32;\n"
          "  popped.free();\n"                                         // free the moved-out String explicitly
          "  if n > 23 { return 42; }\n"
          "  return 0;\n"                                              // v auto-frees its remaining String
          "}\n"
          "fn main() i32 { exit(run()); }\n",
      42, "");
}

// `switch` binding modes (Rust match ergonomics): matching a `&`/`&mut` scrutinee binds each payload BY
// REFERENCE (peek / mutate the payload in place); matching an owned value MOVES the payload out and
// consumes the scrutinee. This is what lets Option/Result be auto-`Free` -- their payload is reached only
// through `switch`, so move-mode extraction + ref-mode deep-free are both expressible and sound.
static void test_switch_binding_modes(void) {
  // &mut scrutinee -> `&mut` payload binding: mutate the enum's payload in place through the borrow.
  sc_run_program(
      "switch &mut binds payload by &mut (mutate in place)",
      PRE "fn main() i32 { let mut o = Option::<i32>::Some(41);\n"
          "  let r = switch &mut o { Some(v) => *v = *v + 1, None => 0 };\n" // mutate o's payload in place
          "  exit(o.unwrap_or(0) + r - 84); }\n",                            // o is now Some(42); r == 42
      0, "");
  // & scrutinee -> `&` payload binding: borrow a heap payload and call a method on it without consuming.
  sc_run_program(
      "switch & binds payload by & (peek without consuming)",
      PRE "fn peek_len(o: &Option<String>) i32 { return switch o { Some(s) => s.len() as i32, None => -1 }; }\n"
          "fn run() i32 { let o = Option::<String>::Some(String::from_str(\"a heap string long enough to allocate\"));\n"
          "  let a = peek_len(&o); let b = peek_len(&o);\n"   // peeked twice -- o still owns its String
          "  if a != b { return 1; }\n"
          "  return 0; }\n"                                    // o auto-frees its String once at scope exit
          "fn main() i32 { exit(run()); }\n",
      0, "");
  // Owned scrutinee -> move mode: `unwrap_or` consumes the Option and moves the String out; the Option is
  // not double-freed. Option<String> freed WITHOUT extraction deep-auto-frees its payload.
  sc_run_program(
      "Option<String> auto-Free: deep-free on free + move-out via unwrap_or",
      PRE "fn run() i32 {\n"
          "  let held = Option::<String>::Some(String::from_str(\"freed without extraction -- deep auto-freed\"));\n"
          "  if held.is_none() { return 1; }\n"               // held auto-frees its String at scope exit
          "  let o = Option::<String>::Some(String::from_str(\"extracted heap string moved out by unwrap_or\"));\n"
          "  let mut s = o.unwrap_or(String::from_str(\"a heap-backed default long enough to allocate now\"));\n"
          "  return (s.len() > 23) as i32 - 1; }\n"           // s auto-frees; o consumed (no double free)
          "fn main() i32 { exit(run()); }\n",
      0, "");
  // Result<String, i32> is auto-`Free` whenever the Ok type is (the Err arm frees through the intrinsic).
  sc_run_program(
      "Result<String,i32> auto-Free on free (Ok payload deep-freed)",
      PRE "fn run() i32 {\n"
          "  let r = Result::<String, i32>::Ok(String::from_str(\"a result-carried heap string of real length\"));\n"
          "  if r.is_err() { return 1; }\n"                   // r auto-frees its Ok String at scope exit
          "  return 0; }\n"
          "fn main() i32 { exit(run()); }\n",
      0, "");
  // A combinator that FREES a payload frees it (no leak) without double-freeing (ASan): `Option::and` on
  // the Some path discards `self`'s heap String and returns `other`; `Result::get_err` discards the Ok
  // String. The prelude frees the discarded payload explicitly per arm (sound under flow-sensitive `freed`).
  sc_run_program(
      "owned-switch frees the discarded payload (and / get_err), no double-free",
      PRE "fn run() i32 {\n"
          "  let a = Option::<String>::Some(String::from_str(\"self payload discarded by and, freed here ok\"));\n"
          "  let b = a.and(Option::<i32>::Some(7));\n"        // a's String freed; b is Some(7)
          "  if b.unwrap_or(0) != 7 { return 1; }\n"
          "  let r = Result::<String, i32>::Ok(String::from_str(\"ok payload discarded by get_err here now\"));\n"
          "  let e = r.get_err();\n"                          // r's Ok String freed; e is None
          "  if e.is_some() { return 2; }\n"
          "  return 0; }\n"
          "fn main() i32 { exit(run()); }\n",
      0, "");
  // Void block arms (a `;`-terminated assignment block is `void`, like `{}`): mutate in place via &mut.
  sc_run_program(
      "void block switch arms (assignment block is void)",
      PRE "fn main() i32 { let mut o = Option::<i32>::Some(20);\n"
          "  switch &mut o { Some(v) => { *v = *v + 22; }, None => {}, };\n" // both arms void
          "  exit(o.unwrap_or(0)); }\n",
      42, "");
}

// RAII move/free edge cases (output proves each value is freed EXACTLY once -- a missing char is a leak, a
// doubled char a double-free; the harness also builds with -fsanitize=address).
static void test_raii_move_edges(void) {
#define TR_PRE                                                                                                          \
  PRE "struct Tr { pub id: i32 }\n"                                                                                    \
      "extend Tr as Free { fn free(self: &mut Tr) { putchar(self.id); } }\n"
  // Free elaboration: a move-mode `switch` payload bound but only READ (not moved out) is freed at arm exit.
  sc_run_program(
      "switch free-elaboration: borrowed-not-moved payload freed once",
      TR_PRE "fn run() i32 { let o = Option::<Tr>::Some(Tr { id: 65 });\n"
             "  let r = switch o { Some(v) => v.id, None => 0, };\n" // v read, not moved -> freed: 'A'
             "  return r - 65; }\n"
             "fn main() i32 { let r = run(); putchar(10); exit(r); }\n",
      0, "A\n");
  // 3 deeply nested move-mode switches: the deepest payload is read (not moved) -> freed at the deep arm.
  sc_run_program(
      "deeply nested switch free-elaboration (3 levels)",
      TR_PRE "fn run() i32 {\n"
             "  let d = Option::<Option<Result<Tr, i32>>>::Some(Option::<Result<Tr, i32>>::Some(Result::<Tr, i32>::Ok(Tr { id: 90 })));\n"
             "  let r = switch d { Some(a) => switch a { Some(b) => switch b { Ok(v) => v.id, Err(_) => 0, }, None => 0, }, None => 0, };\n"
             "  return r - 90; }\n" // v read at depth 3, not moved -> freed: 'Z'
             "fn main() i32 { let r = run(); putchar(10); exit(r); }\n",
      0, "Z\n");
  // Reassigning a Free binding frees the OLD value first; the new value frees at scope exit.
  sc_run_program(
      "reassigning a Free binding frees the old value once",
      TR_PRE "fn run() void { let mut t = Tr { id: 65 }; t = Tr { id: 66 }; }\n" // old 'A' on reassign, new 'B' at exit
             "fn main() i32 { run(); putchar(10); exit(0); }\n",
      0, "AB\n");
  // A discarded Free temporary (a method result used inline) is freed after the statement.
  sc_run_program(
      "discarded Free temporary is freed",
      TR_PRE "fn mk(id: i32) Tr { return Tr { id: id }; }\n"
             "extend Tr { fn tag(self: &Tr) i32 { return self.id; } }\n"
             "fn run() i32 { let r = mk(65).tag(); return r - 65; }\n" // the mk(65) temp is freed after the call: 'A'
             "fn main() i32 { let r = run(); putchar(10); exit(r); }\n",
      0, "A\n");
#undef TR_PRE
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

// Regressions for codegen/runtime bugs from the cross-stage hunt. Generated C is compiled under
// -Werror -fsanitize=address,undefined, so a double-free / use-after-free / bad-C regression fails here.
static void test_bug_regressions(void) {
  // C1: a partial move of a Free field must not double-free the owner at scope exit.
  sc_run_program("partial field move, no double-free",
      PRE "struct H { pub name: String, pub n: i32 }\n"
          "extend H as Free { fn free(self: &mut H) { self.name.free(); } }\n"
          "fn main() i32 {\n"
          "  let h = H { name: String::from_str(\"a heap name long enough to allocate now\"), n: 7 };\n"
          "  let nm = h.name;\n"
          "  if nm.len() < 10 { return 1; }\n"
          "  return 0; }\n",
      0, "");
  // C3: a struct array field initialized from a non-literal lowers via memcpy, not an illegal C array init.
  sc_run_program("struct array field from variable",
      PRE "struct Q { pub v: [i32; 3] }\n"
          "fn main() i32 { let local: [i32; 3] = [1, 2, 3]; let q = Q { v: local }; return q.v[2] - 3; }\n",
      0, "");
  // C4 regression: a value-block tail that builds a Free value (get_ok -> Option<String>) is RETURNED, not
  // freed as a discarded temporary. This is the exact std `result.c` void-return that slipped before.
  sc_run_program("free value-block tail is returned",
      PRE "fn main() i32 {\n"
          "  let r = Result::<String, i32>::Ok(String::from_str(\"ok payload long enough to heap-allocate\"));\n"
          "  let o = r.get_ok();\n"
          "  if o.unwrap_or(String::new()).len() < 10 { return 1; }\n"
          "  return 0; }\n",
      0, "");
  // C4: a genuinely discarded owning temporary is freed -- its Free prints 'A', proving the cleanup ran.
  sc_run_program("discarded owning temporary freed",
      PRE "struct T { pub tag: i32 }\n"
          "extend T as Free { fn free(self: &mut T) { putchar(self.tag); } }\n"
          "fn make(t: i32) T { return T { tag: t }; }\n"
          "fn main() i32 { make(65); return 0; }\n",
      0, "A");
  // C5: tuple-destructured owning bindings are freed once; a moved-out element is not double-freed.
  // 'A' is freed inside consume (a moved in), 'B' at main's scope exit -- each exactly once, no double-free.
  sc_run_program("tuple-let elements freed once",
      PRE "struct T { pub tag: i32 }\n"
          "extend T as Free { fn free(self: &mut T) { putchar(self.tag); } }\n"
          "fn pair() (T, T) { return T { tag: 65 }, T { tag: 66 }; }\n"
          "fn consume(t: T) i32 { return t.tag; }\n"
          "fn main() i32 { let (a, b) = pair(); if consume(a) != 65 { return 1; } if b.tag != 66 { return 2; } return 0; }\n",
      0, "AB");
  // L2: a byte literal is u8 -- `b'\xFF' as i32` is 255, not the signed C char's -1.
  sc_run_program("byte literal high bit", PRE "fn main() i32 { if b'\\xFF' as i32 != 255 { return 1; } return 0; }\n", 0, "");
  // L1a: a non-ASCII char that fits in one byte compiles and carries its codepoint.
  sc_run_program("non-ascii char in one byte", PRE "fn main() i32 { if '\\u{E9}' as u8 != 233 { return 1; } return 0; }\n", 0, "");
  // T5 (runtime): `&mut x` flows into a `&i32` parameter.
  sc_run_program("mut ref as shared ref runs",
      PRE "fn read(r: &i32) i32 { return *r; }\n"
          "fn main() i32 { let mut x = 5; if read(&mut x) != 5 { return 1; } return 0; }\n",
      0, "");
  // P1: `a as i32 < b` parses as `(a as i32) < b`.
  sc_run_program("comparison after cast",
      PRE "fn main() i32 { let a: i32 = 5; let b: i32 = 3; if a as i32 < b { return 1; } return 0; }\n", 0, "");
  // R2: or-pattern payload bindings are usable in the arm body.
  sc_run_program("or-pattern binding usable",
      PRE "fn pick(r: Result<i32, i32>) i32 { return switch r { Ok(v) | Err(v) => v, }; }\n"
          "fn main() i32 { if pick(Result::<i32, i32>::Ok(42)) != 42 { return 1; } return 0; }\n",
      0, "");
  // Type-emission ordering: a struct embedding a generic instance over a user type BY VALUE needs that
  // instance's full body emitted first. `Bag` embeds `Vector<Item>` (re-homed here, generic owner is std) and
  // `Maybe` embeds `Option<Pt>` which itself embeds `Pt` by value -- so both the struct->instance and the
  // instance->user-type layout edges must be ordered, or the generated C is an incomplete-type error (caught
  // by the harness's -Werror compile). Pre-fix: `Bag`/`Maybe` were emitted before the instances they contain.
  sc_run_program("by-value instance field ordered before its struct",
      PRE "struct Item { pub v: i32 }\n"
          "struct Bag { pub items: Vector<Item> }\n"
          "extend Bag as Free { fn free(self: &mut Bag) { self.items.free(); } }\n"
          "struct Pt { pub x: i32 }\n"
          "struct Maybe { pub slot: Option<Pt> }\n"
          "fn main() i32 {\n"
          "  let mut b = Bag { items: Vector::<Item>::new() };\n"
          "  b.items.push(Item { v: 42 });\n"
          "  if b.items.len() != 1 { return 1; }\n"
          "  let m = Maybe { slot: Option::<Pt>::Some(Pt { x: 42 }) };\n"
          "  if !m.slot.is_some() { return 2; }\n"
          "  return 0; }\n",
      0, "");
}

int main(void) {
  // The independent units, fanned out across cores by the parallel-for; schedule(dynamic) balances the tail.
  static void (*const tests[])(void) = {
      test_bug_regressions,    test_attributes,           test_free_raii,
      test_conditional_move_free, test_container_free_raii, test_free_intrinsic,
      test_std_container_auto_free, test_switch_binding_modes, test_raii_move_edges,
      test_defer,              test_static_assert,        test_interfaces,
      test_operator_overloading, test_index_interface, test_question_operator,  test_string_sso,
      test_unions,             test_closures,             test_std_types,
      test_nested_generic_by_value, test_generics_over_user_types, test_container_conformances,
      test_str_conformances,   test_format_printing,      test_bounds_checks,
      test_checked_arith,      test_builtin_conformances, test_default_generic_args,
      test_custom_allocator,   test_stateful_allocator,   test_set,
      test_map,                test_multi_from,           test_generics,
      test_arithmetic,         test_control_flow,         test_recursion,
      test_switch,             test_if_expression,        test_array_literals,
      test_slices,             test_range_slicing,        test_range_value,
      test_opaque_extern,      test_variadics,            test_complex,
      test_atomics,            test_tuple_destructure,    test_enums,
      test_mut_match_binding,  test_structs_and_methods,  test_let_owning_mut,
      test_field_vs_method,    test_generic_self_receiver, test_pointers,
      test_str,                test_misc,
  };
  const int nt = (int)(sizeof tests / sizeof *tests);
  SC_PARALLEL_FOR
  for (int i = 0; i < nt; i++)
    tests[i]();
  if (failures) {
    fprintf(stderr, "%d codegen-run test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("codegen-run tests passed");
  return 0;
}
