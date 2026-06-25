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

static void test_let_owning_mut(void) {
  // A `let` (immutable) binding of a struct that owns a `*mut` is emitted non-const, so its &mut self
  // methods stay callable -- a const binding would make `&b` a `const Box *` and fail to compile.
  sc_run_program(
      "let owning-mut binding calls &mut self",
      PRE "extern \"C\" { fn malloc(n: usize) *mut void; fn free(p: *mut void) void; }\n"
          "struct Box { pub p: *mut u8, }\n"
          "extend Box {\n"
          "  fn make() Box { return Box { p: malloc(1) as *mut u8, }; }\n"
          "  fn set(self: &mut Box, v: u8) { self.p[0] = v; }\n"
          "  fn get(self: &Box) u8 { return self.p[0]; }\n"
          "  fn deinit(self: &mut Box) { free(self.p as *mut void); self.p = null; }\n"
          "}\n"
          "fn main() i32 { let b: Box = Box::make(); b.set(42); let r: u8 = b.get(); b.deinit(); exit(r as i32); }\n",
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

int main(void) {
  test_string_sso();
  test_unions();
  test_closures();
  test_std_types();
  test_generics_over_user_types();
  test_generics();
  test_arithmetic();
  test_control_flow();
  test_recursion();
  test_switch();
  test_if_expression();
  test_array_literals();
  test_tuple_destructure();
  test_enums();
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
