// End-to-end soundness: each program is transpiled, the generated C is compiled warning-clean
// under -Werror -fsanitize=undefined,address, then executed; the process exit code (and stdout
// where relevant) is asserted. This proves the emitted C is correct, not merely plausible -- the
// gap the substring-only codegen_test.c cannot close.
//
// Scope note: the language currently has no surface syntax to *construct* enum, array, slice or
// tuple values (see the suite's findings), so those are covered structurally in codegen_test.c
// rather than behaviorally here.

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
}

static void test_structs_and_methods(void) {
  sc_run_program(
      "method dispatch (&self / &mut self)",
      PRE "struct Point { x: i32, y: i32, }\n"
          "extend Point {\n"
          "  fn sum(self: &Point) i32 { return self.x + self.y; }\n"
          "  fn shift(self: &mut Point, d: i32) void { self.x = self.x + d; self.y = self.y + d; }\n"
          "}\n"
          "fn main() i32 { let mut p: Point = Point { x: 3, y: 4, }; p.shift(10); exit(p.sum()); }\n",
      27, "");
  sc_run_program(
      "nested struct field access",
      PRE "struct Inner { v: i32, }\n"
          "struct Outer { inner: Inner, }\n"
          "fn main() i32 { let o: Outer = Outer { inner: Inner { v: 7, }, }; exit(o.inner.v); }\n",
      7, "");
  sc_run_program(
      "heap struct via new",
      PRE "struct Box { v: i32, }\n"
          "fn main() i32 { let b: *Box = new Box { v: 9, }; exit(b.v); }\n",
      9, "");
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

int main(void) {
  test_arithmetic();
  test_control_flow();
  test_recursion();
  test_switch();
  test_if_expression();
  test_array_literals();
  test_tuple_destructure();
  test_enums();
  test_structs_and_methods();
  test_pointers();
  test_misc();
  if (failures) {
    fprintf(stderr, "%d codegen-run test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("codegen-run tests passed");
  return 0;
}
