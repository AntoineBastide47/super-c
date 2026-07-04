// Type-checker coverage. Beyond the original pass/fail checks, this asserts the *computed* type
// stored on representative expression nodes (ast_type): comparisons yield bool, arithmetic keeps
// the operand type, pointer offset stays a pointer, deref yields the pointee, address-of yields a
// reference, and a bare literal adapts to its annotated type.

#include "test_harness.h"

static void expect_ok(const char *name, const char *source) {
  Ast *ast = sc_typecheck(name, source);
  if (ast)
    ast_free(&ast);
}

static void expect_error(const char *name, const char *source, const char *needle) {
  char first[256];
  const size_t n = sc_stage_errors(name, source, ST_TYPECHECK, first, sizeof first);
  CHECK(n >= 1, "%s: expected a type error", name);
  if (n)
    CHECK(strstr(first, needle) != NULL, "%s: first error missing '%s':\n%s", name, needle, first);
}

static void test_ok(void) {
  expect_ok(
      "field access",
      "struct P { pub x: i32, }\n"
      "fn main() i32 { let p: P = P { x: 1, }; let y: i32 = p.x; }\n");
  expect_ok(
      "method call binds self",
      "struct P { pub x: i32, }\n"
      "extend P { fn get(self: P) i32 { return self.x; } }\n"
      "fn main() i32 { let p: P = P { x: 1, }; let y: i32 = p.get(); }\n");
  expect_ok("entry point fn main() i32", "fn main() i32 { return 0; }\n");
  expect_ok("string literal is str", "fn main() i32 { let s: str = \"hi\"; let n: usize = s.len; }\n");
  expect_ok("str ptr field indexes to u8", "fn first(s: str) u8 { return unsafe s.ptr[0]; }\n");
  expect_ok(
      "private field reachable via self",
      "struct S { v: i32, }\nextend S { fn get(self: &S) i32 { return self.v; } }\n");
  expect_ok(
      "private field constructible inside extend",
      "struct S { v: i32, }\nextend S { fn make() S { return S { v: 1, }; } }\n");
  expect_ok("pub field readable from outside", "struct S { pub v: i32, }\nfn f(s: S) i32 { return s.v; }\n");
  expect_ok(
      "field and same-named method coexist", // `s.len` is the field, `s.len()` is the method
      "struct S { pub len: i32, }\nextend S { pub fn len(self: &S) i32 { return self.len; } }\n"
      "fn use(s: S) i32 { return s.len + s.len(); }\n");
  expect_ok("literal coercion", "fn main() i32 { let x: u8 = 5; }\n");
  expect_ok("inferred binding", "fn main() i32 { let x = 1; let y: i32 = x; }\n");
  expect_ok("int literal initializes a float", "fn main() i32 { let f: f64 = 0; let g: f32 = 5; let h: f64 = -3; }\n");
  expect_ok("builtin Copy bound", "fn id<T: Copy>(x: T) T { return x; }\nfn main() i32 { return id::<i32>(0); }\n");
  expect_ok("complex Clone Default Copy bounds",
            "fn id<T: Copy>(x: T) T { return x; }\nfn clone_of<T: Clone>(x: &T) T { return x.clone(); }\n"
            "fn zero<T: Default>() T { return T::default(); }\n"
            "fn main() i32 { let z: c64 = 1.0; let a = id::<c64>(z); let b = clone_of::<c64>(&a); let c = zero::<c64>(); return 0; }\n");
  expect_ok("builtin inherent scalar methods",
            "fn main() i32 { let x: i32 = -5; let y: u32 = 8; let z: i32 = 9; let a = x.abs() + x.signum() + z.clamp(0, 7);\n"
            "let f: f64 = 9.0; let g: f64 = -2.5; let h: f32 = 4.0; let r: f32 = h.sqrt();\n"
            "if !y.is_power_of_two() { return 1; } if !(f.sqrt() + g.abs()).is_finite() { return 2; } return a + r as i32; }\n");
  expect_ok(
      "char literal coerces to any int slot",
      "fn take(b: u8) u8 { return b; }\n"
      "fn main() i32 { let x: u8 = 'l'; let y: u32 = 'A'; let z: u8 = take('z'); }\n");
  expect_ok(
      "call argument types",
      "fn add(a: i32, b: i32) i32 { return a; }\n"
      "fn main() i32 { let z: i32 = add(1, 2); }\n");
  expect_ok("bool condition", "fn main() i32 { if (true) { } }\n");
  expect_ok(
      "switch name binding",
      "fn classify(c: u8) i32 { return switch c { 0 => 1, n => 2, _ => 0, }; }\n");
  expect_ok(
      "struct pattern field",
      "struct P { pub x: i32, }\n"
      "fn f(p: P) i32 { return switch p { P { x: v } => v, }; }\n");
  expect_ok("pointer offset", "fn f(p: *i32) i32 { let q: *i32 = unsafe (p + 1); return unsafe *q; }\n");
  expect_ok("pointer minus int", "fn f(p: *i32) i32 { let q: *i32 = unsafe (p - 1); return unsafe *q; }\n");
  expect_ok("int plus pointer", "fn f(p: *i32) i32 { let q: *i32 = unsafe (1 + p); return unsafe *q; }\n");
  expect_ok("pointer difference", "fn f(a: *i32, b: *i32) isize { return unsafe (a - b); }\n");
  expect_ok("explicit void bare return", "fn f() void { return; }\n");
  expect_ok("range adopts usize bound", "fn f(n: usize) void { for i in 0..n { let x: usize = i; } }\n");
  expect_ok("associated new call", "struct String {}\nextend String { fn new() String { return String {}; } }\nfn f() String { return String::new(); }\n");
  expect_ok(
      "reference coerces to const pointer",
      "fn take(p: *const i32) i32 { return unsafe *p; }\n"
      "fn give(x: i32) i32 { return take(&x); }\n");
  // Pointer ERASURE is implicit (`*mut T` -> `*mut void`, const-respecting); INVENTION
  // (`*mut void` -> `*mut T`) still needs an explicit `as` cast.
  expect_ok(
      "pointer erases to void pointer",
      "fn take(p: *mut void) void {}\nfn cview(p: *const void) void {}\n"
      "fn f(x: *mut i32, c: *const i32) { take(x); cview(x); cview(c); }\n");
  expect_error(
      "const pointer does not erase to mut void",
      "fn take(p: *mut void) void {}\nfn f(c: *const i32) { take(c); }\n", "mismatched types");
  expect_error(
      "void pointer does not invent a type implicitly",
      "fn f(p: *mut void) *mut i32 { return p; }\n", "mismatched types");
}

static void test_computed_scalar_types(void) {
  // `a < b` is bool; `a + b` keeps i32.
  static const char src[] = "fn f(a: i32, b: i32) bool { let c: bool = a < b; let d: i32 = a + b; return c; }\n";
  Ast *a = sc_typecheck("scalar types", src);
  if (!a)
    return;
  const NodeId lt = th_nth_kind(a, NODE_BINARY, 0); // a < b (parsed first)
  const NodeId add = th_nth_kind(a, NODE_BINARY, 1); // a + b
  CHECK(ast_type(a, lt) == ast_builtin(BT_BOOL), "comparison is bool");
  CHECK(ast_type(a, add) == ast_builtin(BT_I32), "i32 + i32 is i32");
  ast_free(&a);
}

static void test_computed_pointer_types(void) {
  static const char src[] = "fn f(p: *i32) i32 { let q: *i32 = unsafe (p + 1); return unsafe *q; }\n";
  Ast *a = sc_typecheck("pointer types", src);
  if (!a)
    return;
  const NodeId off = th_nth_kind(a, NODE_BINARY, 0); // p + 1
  const TypeId ot = ast_type(a, off);
  CHECK(ast_type_at(a, ot)->kind == TYPE_POINTER, "pointer offset stays a pointer");
  CHECK(ast_type_at(a, ot)->as.elem == ast_builtin(BT_I32), "pointee is i32");
  const NodeId deref = th_nth_kind(a, NODE_UNARY, 1); // *q (unary 0 is the first `unsafe` wrapper)
  CHECK(ast_type(a, deref) == ast_builtin(BT_I32), "deref yields the pointee type");
  ast_free(&a);
}

static void test_computed_reference_type(void) {
  // `*p` is unary[0] (in `take`), `&x` is unary[1] (in `give`, parsed second).
  static const char src[] = "fn take(p: *const i32) i32 { return unsafe *p; }\n"
                            "fn give(x: i32) i32 { return take(&x); }\n";
  Ast *a = sc_typecheck("reference type", src);
  if (!a)
    return;
  const NodeId addr = th_nth_kind(a, NODE_UNARY, 2); // &x (unary 0/1 are `*p` and its `unsafe` wrapper)
  CHECK(ast_type_at(a, ast_type(a, addr))->kind == TYPE_REFERENCE, "address-of yields a reference");
  ast_free(&a);
}

// Each literal carries its intrinsic type; an integer literal stays i32 and merely *adapts* (via
// compatibility) into a narrower annotated type, rather than being retyped on the node.
static void test_literal_types(void) {
  static const char src[] = "fn main() i32 { let i = 5; let c = 'a'; let b = true; let f = 0.0; }\n";
  Ast *a = sc_typecheck("literal types", src);
  if (!a)
    return;
  CHECK(ast_type(a, th_nth_kind(a, NODE_LITERAL, 0)) == ast_builtin(BT_I32), "integer literal is i32");
  CHECK(ast_type(a, th_nth_kind(a, NODE_LITERAL, 1)) == ast_builtin(BT_CHAR), "char literal is char");
  CHECK(ast_type(a, th_nth_kind(a, NODE_LITERAL, 2)) == ast_builtin(BT_BOOL), "bool literal is bool");
  CHECK(ast_type(a, th_nth_kind(a, NODE_LITERAL, 3)) == ast_builtin(BT_F32), "float literal defaults to f32");
  ast_free(&a);
}

// An un-annotated `let`/`let mut` takes the initializer's computed type (not just literals).
static void test_inferred_let_types(void) {
  static const char src[] = "fn f(n: usize) usize { let m = n + 1; let mut k = m; k = k + n; return k; }\n";
  Ast *a = sc_typecheck("inferred let", src);
  if (!a)
    return;
  CHECK(ast_type(a, th_nth_kind(a, NODE_LET, 0)) == ast_builtin(BT_USIZE), "let m = n + 1 infers usize");
  CHECK(ast_type(a, th_nth_kind(a, NODE_LET, 1)) == ast_builtin(BT_USIZE), "let mut k = m infers usize");
  ast_free(&a);
}

// A string literal is a `str` view; `.len` is usize and `.ptr` is `*const u8` (indexes to u8).
static void test_str_member_types(void) {
  // The string literal is created first, so it is NODE_LITERAL[0]; the member accesses follow in
  // source order: g.len is NODE_MEMBER[0], g.ptr is NODE_MEMBER[1].
  static const char src[] = "fn main() i32 { let g: str = \"hi\"; let n: usize = g.len; let b: u8 = unsafe g.ptr[0]; return 0; }\n";
  Ast *a = sc_typecheck("str member types", src);
  if (!a)
    return;
  // `str` is no longer a builtin -- a string literal is the std prelude's `str` struct (its `.len`/`.ptr`
  // field types below confirm the shape).
  CHECK(ast_type_at(a, ast_type(a, th_nth_kind(a, NODE_LITERAL, 0)))->kind == TYPE_STRUCT, "string literal is str");
  const NodeId len_access = th_nth_kind(a, NODE_MEMBER, 0); // g.len
  CHECK(ast_type(a, len_access) == ast_builtin(BT_USIZE), "str.len is usize");
  const NodeId ptr_access = th_nth_kind(a, NODE_MEMBER, 1); // g.ptr
  const Ty *const pt = ast_type_at(a, ast_type(a, ptr_access));
  CHECK(pt->kind == TYPE_POINTER && pt->as.elem == ast_builtin(BT_U8), "str.ptr is *const u8");
  CHECK(pt->qualifier == TYPE_QUAL_CONST, "str.ptr is const-qualified");
  ast_free(&a);
}

static void test_errors(void) {
  // move analysis: using a Free value after it has been moved is rejected (a plain non-Free value still copies).
  expect_error(
      "use after move",
      "interface Free { fn free(self: &mut Self); }\n"
      "struct R { pub t: i32 }\nextend R as Free { fn free(self: &mut Self) {} }\n"
      "fn main() i32 { let a = R { t: 1 }; let b = a; return a.t; }\n",
      "use of moved value");
  // D#10 flow-sensitive moves: a value moved in only ONE arm is "maybe moved" afterward -> a later use errors.
#define MOVE_PRE                                                                                                        \
  "interface Free { fn free(self: &mut Self); }\n"                                                                      \
  "struct R { pub t: i32 }\nextend R as Free { fn free(self: &mut Self) {} }\nfn take(r: R) void {}\n"
  expect_error(
      "use after conditional move",
      MOVE_PRE "fn main() i32 { let a = R { t: 1 }; if true { take(a); } return a.t; }\n", "use of moved value");
  expect_error(
      "use after move on both branches",
      MOVE_PRE "fn main() i32 { let a = R { t: 1 }; if true { take(a); } else { take(a); } return a.t; }\n",
      "use of moved value");
  // ...but an alternative arm may use a value a sibling arm moved: the else here doesn't see the then's move.
  expect_ok(
      "sibling-branch move does not taint the other arm",
      MOVE_PRE "fn main() i32 { let a = R { t: 1 }; if false { take(a); } else { return a.t; } return 0; }\n");
  // explicitly `free()`-ing a value consumes it: a later use is a use-after-free (distinct from a move).
  expect_error("use after explicit free",
               MOVE_PRE "fn main() i32 { let mut a = R { t: 1 }; a.free(); return a.t; }\n", "use after free");
  // a method whose `self` is taken BY VALUE consumes its receiver (Rust's `Option::unwrap_or(self, ..)`).
  expect_error(
      "use after by-value-self method call",
      MOVE_PRE "extend R { fn consume(self: R) i32 { return self.t; } }\n"
               "fn main() i32 { let a = R { t: 1 }; let x = a.consume(); return a.t; }\n",
      "use of moved value");
  // ...but a `&self` method only borrows -- the receiver stays usable afterward.
  expect_ok(
      "by-ref-self method call does not consume the receiver",
      MOVE_PRE "extend R { fn peek(self: &R) i32 { return self.t; } }\n"
               "fn main() i32 { let a = R { t: 1 }; let x = a.peek(); return a.t + x; }\n");
#undef MOVE_PRE
  // D#11 definite initialization: a deferred binding read before assignment, or initialized on only some paths.
  expect_error("read of uninitialized binding", "fn main() i32 { let mut x: i32; return x; }\n",
               "use of possibly uninitialized value");
  expect_error("read of conditionally-initialized binding",
               "fn main() i32 { let mut x: i32; if true { x = 5; } return x; }\n",
               "use of possibly uninitialized value");
  expect_error("value read of uninitialized array element",
               "fn main() i32 { let mut a: [i32; 4]; return a[0]; }\n", "use of possibly uninitialized value");
  expect_error( // a Free binding is freed at scope exit, so it cannot be left to deferred initialization
      "deferred-init Free binding",
      "interface Free { fn free(self: &mut Self); }\nstruct R { pub t: i32 }\n"
      "extend R as Free { fn free(self: &mut Self) {} }\nfn main() i32 { let mut x: R; x = R { t: 1 }; return 0; }\n",
      "must be initialized when declared");
  expect_ok("definitely initialized before read", "fn main() i32 { let mut x: i32; x = 7; return x; }\n");
  expect_ok("initialized on every branch before read",
            "fn main() i32 { let mut x: i32; if true { x = 5; } else { x = 6; } return x; }\n");
  expect_ok( // taking the address of an uninitialized buffer is an out-parameter, not a read
      "address of uninitialized buffer is not a read",
      "extern \"C\" { fn memset(p: *mut char, c: i32, n: usize) i32; }\n"
      "fn main() i32 { let mut buf: [char; 8]; unsafe memset(&mut buf[0], 0, 8); return 0; }\n");
  expect_error("let mismatch", "fn main() i32 { let b: bool = 1; }\n", "mismatched types");
  expect_error("float literal not assignable to int", "fn main() i32 { let i: i32 = 0.0; }\n", "mismatched types");
  // Floats satisfy Eq/Ord/Hash through the IEEE-754 TOTAL order (std/core.spc total_cmp bit trick);
  // complex numbers still have no order at all.
  expect_ok("f32 is Eq/Ord/Hash via total order",
            "fn needs<T: Eq>(x: T) bool { return true; }\nfn ord<T: Ord>(x: T) bool { return true; }\n"
            "fn h<T: Hash>(x: T) bool { return true; }\n"
            "fn main() i32 { if needs::<f32>(0.0) && ord::<f32>(0.0) && h::<f32>(0.0) { return 1; } return 0; }\n");
  expect_error("c64 is not Ord", "fn ord<T: Ord>(x: T) bool { return true; }\nfn main() i32 { if ord::<c64>(0.0 as c64) { return 1; } return 0; }\n",
               "does not satisfy bound 'Ord'");
  expect_error( // only char *literals* coerce; a char value needs an explicit conversion
      "non-literal char not assignable to u8", "fn f(c: char) u8 { return c; }\n", "mismatched types");
  expect_error(
      "argument type", "fn g(a: bool) void {}\nfn main() i32 { g(1); }\n", "mismatched types");
  expect_error("argument count", "fn g(a: i32) void {}\nfn main() i32 { g(1, 2); }\n", "expected 1 argument");
  // operator overloading: `+` / `[]` on a struct without the required method is rejected.
  expect_error("arithmetic operator without method",
               "struct P { pub x: i32 }\nfn main() i32 { let a = P { x: 1 }; let b = P { x: 2 }; let c = a + b; return 0; }\n",
               "has no 'add' method");
  expect_error("index operator without method",
               "struct P { pub x: i32 }\nfn main() i32 { let a = P { x: 1 }; return a[0]; }\n", "has no 'index' method");
  // the `?` operator requires an Option/Result operand and a matching function return type.
  expect_error("? in a non-Option/Result function",
               "fn f() i32 { let o = Option::<i32>::some(1); let v = o?; return v; }\n",
               "requires the function to return an Option");
  expect_error("? on a non-Option/Result operand",
               "fn f() Option<i32> { let x = 5; let v = x?; return Option::<i32>::some(v); }\n",
               "requires an Option or Result operand");
  expect_error(
      "unknown field", "struct P { pub x: i32, }\nfn main() i32 { let p: P = P { x: 1, }; p.y; }\n",
      "no field or method 'y'");
  expect_error(
      "unknown str field", "fn f(s: str) i32 { return s.bogus as i32; }\n", "no field or method 'bogus'");
  // A non-pub field is private outside its struct's own extend: neither readable nor initializable.
  expect_error(
      "private field read outside", "struct S { v: i32, }\nfn f(s: S) i32 { return s.v; }\n", "field 'v' is private");
  expect_error(
      "private field init outside",
      "struct S { v: i32, }\nfn main() i32 { let s: S = S { v: 1, }; return 0; }\n", "field 'v' is private");
  expect_error(
      "private field of another struct inside extend",
      "struct A { v: i32, }\nstruct B {}\nextend B { fn peek(a: A) i32 { return a.v; } }\n", "field 'v' is private");
  expect_error("non-bool condition", "fn main() i32 { if (1) { } }\n", "must be 'bool'");
  expect_error("assign immutable", "fn main() i32 { let x: i32 = 1; x = 2; }\n", "cannot assign");
  expect_error( // a non-`mut` match payload binding is immutable
      "assign immutable match binding",
      "enum Opt { None, Some(i32), }\n"
      "fn main() i32 { let o = Opt::Some(1); return switch o { Some(x) => { x = 2; x; }, None => { 0; }, }; }\n",
      "cannot assign");
  expect_ok( // `Some(mut x)` makes the payload binding assignable
      "mut match binding is assignable",
      "enum Opt { None, Some(i32), }\n"
      "fn main() i32 { let o = Opt::Some(1); return switch o { Some(mut x) => { x = 2; x; }, None => { 0; }, }; }\n");
  // A `let` of a `*mut`-owning struct is an immutable *binding*: no rebinding, and no `&mut self` calls.
  // Binding mutability is `let mut`, NOT a property of the type owning a writable pointer internally.
  expect_error(
      "owning-type let still not reassignable",
      "struct Buf { pub p: *mut u8, }\nfn f(b: Buf, c: Buf) { let x: Buf = b; x = c; }\n", "cannot assign");
  expect_error(
      "&mut self on immutable let rejected",
      "struct Buf { pub p: *mut u8, }\nextend Buf { fn clear(self: &mut Buf) { self.p = null; } }\n"
      "fn f(b: Buf) { let x: Buf = b; x.clear(); }\n",
      "cannot call a '&mut self' method on an immutable binding");
  expect_ok(
      "&mut self on let mut allowed",
      "struct Buf { pub p: *mut u8, }\nextend Buf { fn clear(self: &mut Buf) { self.p = null; } }\n"
      "fn f(b: Buf) { let mut x: Buf = b; x.clear(); }\n");
  expect_ok( // &mut self through a &mut parameter is fine (mutable indirection), no `mut` binding needed
      "&mut self through &mut param",
      "struct Buf { pub p: *mut u8, }\nextend Buf { fn clear(self: &mut Buf) { self.p = null; } }\n"
      "fn f(b: &mut Buf) { b.clear(); }\n");
  expect_error( // taking `&mut` of an immutable binding would hand out write access to it
      "&mut of immutable binding rejected",
      "fn use_p(p: &mut i32) {}\nfn f() { let x: i32 = 1; use_p(&mut x); }\n", "cannot take '&mut'");
  expect_ok("&mut of let mut allowed", "fn use_p(p: &mut i32) {}\nfn f() { let mut x: i32 = 1; use_p(&mut x); }\n");
  // Escape analysis (v1): a returned address of a local/parameter dangles past the call.
  expect_error("return &local", "fn bad() *const i32 { let x: i32 = 10; return &x; }\n", "does not outlive the call");
  expect_error("return &mut local", "fn bad() *mut i32 { let mut x: i32 = 10; return &mut x; }\n",
               "does not outlive the call");
  expect_error("return &param", "fn bad(x: i32) *const i32 { return &x; }\n", "function parameter");
  expect_error("return (&local) as usize", "fn bad() usize { let x: i32 = 10; return ((&x) as usize); }\n",
               "does not outlive the call");
  expect_ok("return &global const is fine", "const G: i32 = 7;\nfn ok() &i32 { return &G; }\n");
  expect_ok("return a deref'd pointer param is fine", "fn ok(p: &i32) i32 { return *p; }\n");
  expect_ok( // &x.field / &arr[i] are place expressions, not bare local slots -- not flagged (may be through a ptr)
      "address of a field through a reference param is fine",
      "struct P { pub x: i32 }\nfn ok(p: &P) &i32 { return &p.x; }\n");
  expect_error("return mismatch", "fn f() i32 { return true; }\n", "mismatched types");
  expect_error("index non-array", "fn main() i32 { let x: i32 = 1; let y: i32 = x[0]; }\n", "cannot index");
  expect_error(
      "unknown init field", "struct P { pub x: i32, }\nfn main() i32 { let p: P = P { y: 1, }; }\n", "no field 'y'");
  expect_error(
      "pointer plus pointer", "fn f(a: *i32, b: *i32) void { let c = unsafe (a + b); }\n", "invalid pointer arithmetic");
  expect_error(
      "non-integer pointer offset", "fn f(p: *i32, y: f64) void { let q = unsafe (p + y); }\n",
      "pointer arithmetic requires an integer offset");
  expect_error(
      "const pointer does not coerce to reference",
      "fn take(r: &i32) i32 { return *r; }\n"
      "fn give(p: *const i32) i32 { return take(p); }\n",
      "mismatched types");
  // The entry point must be exactly `fn main() i32` (it lowers to C's `int main(void)`).
  expect_error("main returning void", "fn main() void { }\n", "'main' must be declared 'fn main() i32'");
  expect_error("main with no return type", "fn main() { return; }\n", "'main' must be declared 'fn main() i32'");
  expect_error(
      "main with a wrong return type", "fn main() bool { return true; }\n", "'main' must be declared 'fn main() i32'");
  expect_error(
      "main with parameters", "fn main(x: i32) i32 { return 0; }\n", "'main' must be declared 'fn main() i32'");
}

// Interface bounds are enforced by the semantic phase: a type argument must implement (via `extend T as
// Iface`) every interface its parameter is bound to -- inline (`<T: I>`), via a `where` clause, or through
// a conditional extension. An `extend T as I` must also provide every method the interface requires, and a
// bounded value may call its interface's methods.
static void test_interface_bounds(void) {
  // Satisfied bounds typecheck.
  expect_ok(
      "bound satisfied + method dispatch",
      "interface Writer { fn write(self: *mut Self, n: i32) i32; }\n"
      "struct File { pub count: i32 }\n"
      "extend File as Writer { fn write(self: *mut Self, n: i32) i32 { return n; } }\n"
      "fn use_w<T: Writer>(w: &mut T, n: i32) i32 { return w.write(n); }\n"
      "fn main() i32 { let mut f = File { count: 0 }; return use_w(&mut f, 1); }\n");
  expect_ok(
      "where clause + multi-bound satisfied",
      "interface A { fn a(self: *mut Self) i32; }\ninterface B { fn b(self: *mut Self) i32; }\n"
      "struct S { pub v: i32 }\n"
      "extend S as A { fn a(self: *mut Self) i32 { return unsafe self.v; } }\n"
      "extend S as B { fn b(self: *mut Self) i32 { return unsafe self.v; } }\n"
      "fn both<T>(x: &mut T) i32 where T: A + B { return x.a() + x.b(); }\n"
      "fn main() i32 { let mut s = S { v: 1 }; return both(&mut s); }\n");
  expect_ok(
      "conditional extension satisfied",
      "interface Free { fn free(self: *mut Self) i32; }\n"
      "struct Res { pub id: i32 }\nextend Res as Free { fn free(self: *mut Self) i32 { return unsafe self.id; } }\n"
      "struct Box<T> { pub inner: T }\n"
      "extend<T: Free> Box<T> as Free { fn free(self: &mut Box<T>) i32 { return self.inner.free(); } }\n"
      "fn dispose<U: Free>(x: &mut U) i32 { return x.free(); }\n"
      "fn main() i32 { let mut b = Box::<Res> { inner: Res { id: 1 } }; return dispose(&mut b); }\n");

  // Violations are rejected.
  expect_error(
      "bound not satisfied (turbofish)",
      "interface Writer { fn write(self: *mut Self, n: i32) i32; }\n"
      "struct Plain { pub x: i32 }\n"
      "fn use_w<T: Writer>(w: &mut T, n: i32) i32 { return w.write(n); }\n"
      "fn main() i32 { let mut p = Plain { x: 0 }; return use_w::<Plain>(&mut p, 1); }\n",
      "does not satisfy bound 'Writer'");
  expect_error(
      "extend missing a required method",
      "interface Writer { fn write(self: *mut Self) i32; fn flush(self: *mut Self) i32; }\n"
      "struct File { pub count: i32 }\n"
      "extend File as Writer { fn write(self: *mut Self) i32 { return unsafe self.count; } }\n"
      "fn main() i32 { return 0; }\n",
      "missing method 'flush'");
  expect_error(
      "where clause not satisfied",
      "interface Writer { fn write(self: *mut Self, n: i32) i32; }\n"
      "struct Plain { pub x: i32 }\n"
      "fn use_w<T>(w: &mut T, n: i32) i32 where T: Writer { return w.write(n); }\n"
      "fn main() i32 { let mut p = Plain { x: 0 }; return use_w::<Plain>(&mut p, 1); }\n",
      "does not satisfy bound 'Writer'");
  expect_error(
      "conditional extension: inner type lacks the bound",
      "interface Free { fn free(self: *mut Self) i32; }\nstruct Plain { pub n: i32 }\n"
      "struct Box<T> { pub inner: T }\n"
      "extend<T: Free> Box<T> as Free { fn free(self: &mut Box<T>) i32 { return self.inner.free(); } }\n"
      "fn dispose<U: Free>(x: &mut U) i32 { return x.free(); }\n"
      "fn main() i32 { let mut b = Box::<Plain> { inner: Plain { n: 1 } }; return dispose(&mut b); }\n",
      "does not satisfy bound 'Free'");
  expect_error(
      "method not declared by any bound",
      "interface Writer { fn write(self: *mut Self) i32; }\nstruct File { pub count: i32 }\n"
      "extend File as Writer { fn write(self: *mut Self) i32 { return unsafe self.count; } }\n"
      "fn f<T: Writer>(w: &mut T) i32 { return w.nope(); }\n"
      "fn main() i32 { let mut x = File { count: 0 }; return f(&mut x); }\n",
      "no field or method 'nope'");

  // Conditional extend/interface bounds must be checked at every method-selection surface.
  expect_error(
      "conditional prelude associated default rejects unsatisfied key/value",
      "struct B { pub x: i32 }\n"
      "fn main() i32 { let xxx: Map<B, B> = Map::<B, B>::default(); return 0; }\n",
      "unsatisfied interface bounds");
  expect_error(
      "conditional prelude interface associated default rejects expected type",
      "struct B { pub x: i32 }\n"
      "fn main() i32 { let xxx: Map<B, B> = Default::default(); return 0; }\n",
      "unsatisfied interface bounds");
  expect_error(
      "conditional inherent method rejects unsatisfied receiver",
      "interface Marker { fn mark(self: &Self) i32; }\n"
      "struct Wrap<T> { pub v: T }\n"
      "extend<T: Marker> Wrap<T> { fn marked(self: &Self) i32 { return self.v.mark(); } }\n"
      "struct Plain { pub n: i32 }\n"
      "fn main() i32 { let w = Wrap::<Plain> { v: Plain { n: 1 } }; return w.marked(); }\n",
      "unsatisfied interface bounds");
  expect_error(
      "conditional associated method rejects unsatisfied target",
      "interface Marker { fn mark(self: &Self) i32; }\n"
      "struct Wrap<T> { pub v: T }\n"
      "extend<T: Marker> Wrap<T> { fn make(v: T) Wrap<T> { return Wrap::<T> { v: v }; } }\n"
      "struct Plain { pub n: i32 }\n"
      "fn main() i32 { let w = Wrap::<Plain>::make(Plain { n: 1 }); return 0; }\n",
      "unsatisfied interface bounds");
  expect_error(
      "conditional operator method rejects unsatisfied operands",
      "interface Marker { fn mark(self: &Self) i32; }\n"
      "struct Wrap<T> { pub v: T }\n"
      "extend<T: Marker> Wrap<T> { fn add(self: &Self, other: &Self) Wrap<T> { return Wrap::<T> { v: self.v }; } }\n"
      "struct Plain { pub n: i32 }\n"
      "fn main() i32 { let w = Wrap::<Plain> { v: Plain { n: 1 } }; let z = w + w; return 0; }\n",
      "unsatisfied interface bounds");
  expect_error(
      "conditional index method rejects unsatisfied receiver",
      "interface Marker { fn mark(self: &Self) i32; }\n"
      "struct Wrap<T> { pub v: T }\n"
      "extend<T: Marker> Wrap<T> { fn index(self: &Self, i: usize) i32 { return self.v.mark(); } }\n"
      "struct Plain { pub n: i32 }\n"
      "fn main() i32 { let w = Wrap::<Plain> { v: Plain { n: 1 } }; return w[0]; }\n",
      "unsatisfied interface bounds");

  // Interface conformance must compare full signatures, not just method names.
  expect_error(
      "interface method return signature mismatch",
      "interface I { fn f(self: &Self) i32; }\n"
      "struct S { pub x: i32 }\n"
      "extend S as I { fn f(self: &Self) bool { return true; } }\n"
      "fn main() i32 { return 0; }\n",
      "does not match interface signature");
  expect_error(
      "interface method arity signature mismatch",
      "interface I { fn f(self: &Self, x: i32) i32; }\n"
      "struct S { pub x: i32 }\n"
      "extend S as I { fn f(self: &Self) i32 { return 0; } }\n"
      "fn main() i32 { return 0; }\n",
      "does not match interface signature");

  // Subinterfaces require their superinterfaces, and expose inherited methods through bounds.
  expect_error(
      "subinterface extend requires explicit superinterface satisfaction",
      "interface EqLike { fn eq(self: &Self, other: &Self) bool; }\n"
      "interface OrdLike: EqLike { fn cmp(self: &Self, other: &Self) i32; }\n"
      "struct S { pub x: i32 }\n"
      "extend S as OrdLike {\n"
      "  fn eq(self: &Self, other: &Self) bool { return self.x == other.x; }\n"
      "  fn cmp(self: &Self, other: &Self) i32 { return self.x - other.x; }\n"
      "}\n"
      "fn main() i32 { return 0; }\n",
      "required superinterface");
  expect_ok(
      "superinterface method visible through subinterface bound",
      "interface EqLike { fn eq(self: &Self, other: &Self) bool; }\n"
      "interface OrdLike: EqLike { fn cmp(self: &Self, other: &Self) i32; }\n"
      "fn same<T: OrdLike>(x: &T) bool { return x.eq(x); }\n"
      "struct S { pub x: i32 }\n"
      "extend S as EqLike { fn eq(self: &Self, other: &Self) bool { return self.x == other.x; } }\n"
      "extend S as OrdLike { fn cmp(self: &Self, other: &Self) i32 { return self.x - other.x; } }\n"
      "fn main() i32 { let s = S { x: 1 }; if same(&s) { return 0; } return 1; }\n");
  expect_ok(
      "generic interface argument substituted in bound method return",
      "interface Getter<U> { fn get(self: &Self) U; }\n"
      "struct S { pub x: i32 }\n"
      "extend S as Getter<i32> { fn get(self: &Self) i32 { return self.x; } }\n"
      "fn need<T: Getter<i32>>(x: &T) i32 { return x.get(); }\n"
      "fn main() i32 { let s = S { x: 7 }; return need(&s); }\n");
}

static void test_slices(void) {
  // `[]T` is the prelude Slice<T>: `.len` field, element indexing, and methods all resolve.
  expect_ok("slice len + index read", "fn f(s: []i32) i32 { let n: usize = s.len; return s[0]; }\n");
  expect_ok("slice method resolves", "fn f(s: []i32) usize { return s.len(); }\n");
  // An array coerces to a read-only slice; a mutable array coerces to a writable `[]mut T`.
  expect_ok(
      "array coerces to []T", "fn take(s: []i32) i32 { return s[0]; }\n"
      "fn main() i32 { let a: [i32; 2] = [1, 2]; return take(a); }\n");
  expect_ok(
      "mutable array coerces to []mut T", "fn fill(s: []mut i32) { s[0] = 9; }\n"
      "fn main() i32 { let mut a: [i32; 2] = [0, 0]; fill(a); return a[0]; }\n");
  expect_ok("[]mut element is assignable", "fn fill(s: []mut i32) { s[0] = 9; }\n");
  // A read-only `[]T` element cannot be assigned; an immutable array cannot become `[]mut T`.
  expect_error("write to read-only slice", "fn f(s: []i32) { s[0] = 1; }\n", "cannot assign");
  expect_error(
      "immutable array not []mut", "fn take(s: []mut i32) {}\n"
      "fn main() i32 { let a: [i32; 2] = [1, 2]; take(a); return 0; }\n",
      "mismatched types");
}

static void test_ffi(void) {
  // A C-variadic binding accepts its fixed params plus any number (incl. zero) of trailing args.
  expect_ok(
      "variadic call with extra args",
      "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\n"
      "fn main() i32 { let f: char = '%'; unsafe printf(&f, 1, 2, 3); return 0; }\n");
  expect_ok(
      "variadic call with no extra args",
      "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\n"
      "fn main() i32 { let f: char = '%'; unsafe printf(&f); return 0; }\n");
  // ... but never fewer than the fixed params, and `...` is meaningless without an extern C body.
  expect_error(
      "variadic call below fixed arity",
      "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\n"
      "fn main() i32 { unsafe printf(); return 0; }\n",
      "at least 1 argument");
  // A Super-C-defined variadic function is allowed (it reads args via va_start/va_arg), but needs at
  // least one fixed parameter for va_start to anchor on.
  expect_ok(
      "defined variadic ok",
      "fn s(n: i32, ...) i32 { let mut ap: va_list; va_start(ap, n); let v: i32 = va_arg(ap, i32); va_end(ap); return v; }\n");
  expect_error(
      "variadic needs a fixed param", "fn f(...) i32 { return 0; }\n", "at least one fixed parameter");
  expect_error(
      "va_arg needs a va_list", "fn f(n: i32) i32 { return va_arg(n, i32); }\n", "expected a 'va_list'");

  // `c32`/`c64` complex builtins: real literals coerce in, native arithmetic, casts up to complex --
  // but a complex has no conversion back to a real/int scalar (use creal/cimag).
  expect_ok("real literal initializes complex", "fn main() i32 { let z: c64 = 3.0; let w: c32 = 1; return 0; }\n");
  expect_ok(
      "complex arithmetic + real cast in",
      "fn main() i32 { let a: c64 = 2.0; let b: c64 = a + 1.0; let c: c64 = (3.0 as c64) * b; return 0; }\n");
  expect_ok("c64 <-> c32 casts", "fn main() i32 { let a: c64 = 1.0; let b: c32 = a as c32; let c: c64 = b as c64; return 0; }\n");
  expect_error("complex to int cast rejected", "fn main() i32 { let z: c64 = 1.0; return z as i32; }\n", "invalid cast");

  // A string literal coerces to a `*const char` / `*const u8` C-string slot (fixed param and variadic
  // arg), but still defaults to the `str` view elsewhere -- it does NOT become a mutable/non-const pointer.
  expect_ok(
      "string literal -> *const char param",
      "extern \"C\" { fn puts(s: *const char) i32; }\nfn main() i32 { unsafe puts(\"hi\"); return 0; }\n");
  expect_ok(
      "string literal -> *const u8 param",
      "extern \"C\" { fn f(s: *const u8) i32; }\nfn main() i32 { return unsafe f(\"hi\"); }\n");
  expect_ok(
      "string literal as %s vararg",
      "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\nfn main() i32 { unsafe printf(\"%s\", \"hi\"); return 0; }\n");
  expect_ok("string literal stays str by default", "fn main() i32 { let s: str = \"hi\"; return s.len() as i32; }\n");
  expect_error(
      "string literal not a mutable pointer",
      "extern \"C\" { fn f(s: *mut char) i32; }\nfn main() i32 { return unsafe f(\"hi\"); }\n", "mismatched types");
}

static void test_static_assert(void) {
  expect_ok("static_assert item", "static_assert(1 == 1, \"ok\");\nfn main() i32 { return 0; }\n");
  expect_ok("static_assert no message", "fn main() i32 { static_assert(2 > 1); return 0; }\n");
  expect_ok("static_assert over sizeof", "struct S { a: i64, }\nstatic_assert(sizeof(S) == 8);\nfn main() i32 { return 0; }\n");
  expect_error("static_assert needs bool", "static_assert(5, \"nope\");\nfn main() i32 { return 0; }\n", "must be 'bool'");
  expect_error(
      "static_assert message must be a literal",
      "fn main() i32 { let m: i32 = 0; static_assert(true, m); return 0; }\n", "string literal");
}

// Regressions for bugs found by the cross-stage hunt: each asserts the fix and would fail if it regressed.
static void test_bug_regressions(void) {
  // T1: an operator overload must type-check its right operand against the method's parameter.
  expect_error("op rhs type-checked",
               "struct A { pub x: i32 }\n"
               "extend A { fn add(self: &A, o: &A) A { return A { x: self.x + o.x }; } }\n"
               "fn main() i32 { let a = A { x: 1 }; let p = a + 5; return p.x; }\n",
               "mismatched types");
  // T2: using an operator on an unbounded generic param requires the matching bound (`T: Add`).
  expect_error("unbounded generic operator",
               "fn add2<T>(a: T, b: T) T { return a + b; }\n"
               "fn main() i32 { let n: i32 = add2::<i32>(1, 2); return n; }\n",
               "no 'add' method for this operator");
  // T3: a write through a shared `&T` is rejected even when the binding is `let mut`.
  expect_error("write through shared ref",
               "struct S { pub x: i32 }\n"
               "fn main() i32 { let s = S { x: 1 }; let mut r: &S = &s; r.x = 99; return s.x; }\n",
               "cannot assign");
  // T4: returning the address of a local array element dangles (escape analysis covers &local[i]).
  expect_error("escape of &local index",
               "fn dangle() &i32 { let a: [i32; 3] = [1, 2, 3]; return &a[1]; }\n"
               "fn main() i32 { return *dangle(); }\n",
               "does not outlive");
  // T5: `&mut T` is accepted where `&T` is expected (a reborrow; the stronger borrow covers the weaker).
  expect_ok("mut ref coerces to shared ref",
            "fn read(r: &i32) i32 { return *r; }\n"
            "fn main() i32 { let mut x = 5; return read(&mut x); }\n");
  // L1: a `char` literal whose scalar exceeds one byte is rejected (not silently truncated).
  expect_error("char over one byte",
               "fn main() i32 { let c = '\\u{1F600}'; return c as i32; }\n",
               "does not fit in 'char'");
  // L3: an integer literal larger than 64 bits is rejected with a clean diagnostic.
  expect_error("oversized integer literal",
               "fn main() i32 { let x = 0x1FFFFFFFFFFFFFFFF; return 0; }\n",
               "too large to fit in a 64-bit integer");
  // C2: a fixed-size array cannot be a generic type argument (the interned Ty carries no length).
  expect_error("array as generic argument",
               "struct Wrap<T> { pub v: T }\n"
               "fn main() i32 { let w = Wrap::<[i32; 3]> { v: [1, 2, 3] }; return w.v[0]; }\n",
               "cannot be a generic type argument");
}

// Every switch must cover its scrutinee: enums by variant (or `_`), bool by true+false, anything
// else by an irrefutable arm. Guarded arms cover nothing; or-patterns cover per alternative.
static void test_switch_exhaustiveness(void) {
#define ENUM3 "enum E { A, B, C }\n"
  expect_error("switch missing a variant", ENUM3 "fn f(e: E) i32 { return switch e { A => 1, B => 2 }; }\n",
               "missing variant 'C'");
  expect_error(
      "literal payload does not cover its variant",
      "fn f(o: Option<i32>) i32 { return switch o { Some(5) => 1, None => 0 }; }\n", "missing variant 'Some'");
  expect_error(
      "guarded arm covers nothing",
      "fn f(o: Option<i32>) i32 { return switch o { Some(x) if x > 0 => x, None => 0 }; }\n",
      "missing variant 'Some'");
  expect_error("int switch needs a catch-all", "fn f(n: i32) i32 { return switch n { 1 => 1, 2 => 2 }; }\n",
               "not exhaustive");
  expect_error("bool switch needs both literals", "fn f(b: bool) i32 { return switch b { true => 1 }; }\n",
               "not exhaustive");
  expect_ok("all variants cover the enum", ENUM3 "fn f(e: E) i32 { return switch e { A => 1, B => 2, C => 3 }; }\n");
  expect_ok("or-pattern covers per alternative", ENUM3 "fn f(e: E) i32 { return switch e { A | B => 1, C => 3 }; }\n");
  expect_ok(
      "payload binding covers its variant",
      "fn f(o: Option<i32>) i32 { return switch o { Some(x) => x, None => 0 }; }\n");
  expect_ok("true and false cover bool", "fn f(b: bool) i32 { return switch b { true => 1, false => 0 }; }\n");
  expect_ok("binding arm is a catch-all", "fn f(n: i32) i32 { return switch n { 0..10 => 1, x => x }; }\n");
#undef ENUM3
}

// `panic(..)` (any `@c.noreturn` call) types as `never`, which unifies with every type: a
// diverging switch/if arm coexists with value-producing siblings, and `return panic(..)` fits
// any declared return type.
static void test_never_type(void) {
  expect_ok(
      "panicking switch arm unifies",
      "fn f(o: Option<i32>) i32 { return switch o { Some(v) => v, None => panic(\"none\") }; }\n");
  expect_ok(
      "panicking else branch unifies",
      "fn f(n: i32) i32 { let d = if n > 0 { n; } else { panic(\"neg\"); }; return d; }\n");
  expect_ok("return panic fits any return type", "fn f() i32 { return panic(\"boom\"); }\n");
  expect_ok(
      "user noreturn fn also diverges",
      "extern \"C\" { fn abort() void; }\n"
      "@c.noreturn\nfn die() void { unsafe abort(); }\n"
      "fn f(o: Option<i32>) i32 { return switch o { Some(v) => v, None => die() }; }\n");
  expect_error(
      "non-noreturn void arm still mismatches",
      "fn nop() void {}\n"
      "fn f(o: Option<i32>) i32 { return switch o { Some(v) => v, None => nop() }; }\n",
      "mismatched types");
}

// `(A, B)` lowers to the prelude Tuple<n> struct: literals, `.N` element places, destructuring
// lets, and literal elements adapting to an annotated tuple type.
static void test_tuples(void) {
  expect_ok("tuple literal and access", "fn f() i32 { let t = (1, true); return t.0 + (t.1 as i32); }\n");
  expect_ok("tuple destructure", "fn f() i32 { let (a, b) = (1, 2); return a + b; }\n");
  expect_ok("tuple type annotation adapts literals", "fn f() u8 { let t: (u8, u8) = (1, 2); return t.0 + t.1; }\n");
  expect_ok("tuple param and generic arg", "fn g(p: (i32, bool)) i32 { return p.0; }\n"
            "fn f() i32 { let mut v = Vector::<(i32, bool)>::new(); v.free(); return g((5, false)); }\n");
  expect_error("tuple arity capped at 4", "fn f() i32 { let t = (1, 2, 3, 4, 5); return 0; }\n",
               "tuple arity is limited to 4");
  expect_error("tuple index out of range", "fn f() i32 { let t = (1, 2); return t.9; }\n", "no field or method '9'");
  expect_error(
      "tuple binding needs a tuple or multi-return",
      "fn f() i32 { let (a, b) = 5; return a + b; }\n", "tuple binding requires");
}

// Raw-pointer operations and extern "C" calls are only legal inside `unsafe { .. }` / `unsafe expr`:
// the compiler cannot vouch for them, so the marker is mandatory. References stay safe.
static void test_unsafe_enforcement(void) {
#define EXTC "extern \"C\" { fn exit(code: i32) void; }\n"
  expect_error("extern call needs unsafe", EXTC "fn main() i32 { exit(0); return 0; }\n",
               "calling an extern \"C\" function requires an 'unsafe' block");
  expect_error("raw deref needs unsafe", "fn f(p: *i32) i32 { return *p; }\n",
               "dereferencing a raw pointer requires an 'unsafe' block");
  expect_error("raw index needs unsafe", "fn f(p: *i32) i32 { return p[1]; }\n",
               "indexing a raw pointer requires an 'unsafe' block");
  expect_error("pointer arithmetic needs unsafe", "fn f(p: *i32) *i32 { return p + 1; }\n",
               "raw pointer arithmetic requires an 'unsafe' block");
  expect_error(
      "field through raw pointer needs unsafe",
      "struct S { pub v: i32 }\nfn f(p: *mut S) i32 { return p.v; }\n",
      "accessing a field through a raw pointer requires an 'unsafe' block");
  expect_ok("unsafe block covers the operation", EXTC "fn main() i32 { unsafe { exit(0); } return 0; }\n");
  expect_ok("unsafe prefix covers the expression", EXTC "fn main() i32 { unsafe exit(0); return 0; }\n");
  expect_ok("unsafe deref index arith",
            "fn f(p: *mut i32) i32 { unsafe *p = 1; let x = unsafe p[0]; let q = unsafe (p + 1); return x + unsafe *q; }\n");
  expect_ok("unsafe assignment through wrapper is a place",
            "struct S { pub v: i32 }\nfn f(p: *mut S) { unsafe p.v = 3; }\n");
  expect_ok("reference operations stay safe",
            "fn f(r: &mut i32) i32 { *r = 2; return *r; }\n");
  expect_ok("pointer comparison stays safe", "fn f(a: *i32, b: *i32) bool { return a == b; }\n");
#undef EXTC
}

// Capturing closures + `F: fn(..) ..` bounds: what must check, and every capture restriction.
static void test_closures(void) {
  expect_ok(
      "fn bound callable and satisfied",
      "fn apply<F: fn(i32) i32>(x: i32, f: F) i32 { return f(x); }\n"
      "fn inc(x: i32) i32 { return x + 1; }\n"
      "fn main() i32 { let b = 1; return apply(1, inc) + apply(1, |x: i32| x + b); }\n");
  expect_ok(
      "where-clause fn bound callable",
      "fn apply<F>(x: i32, f: F) i32 where F: fn(i32) i32 { return f(x); }\n"
      "fn main() i32 { return apply(1, |x: i32| x + 1); }\n");
  expect_error(
      "fn bound signature mismatch",
      "fn apply<F: fn(i32) i32>(x: i32, f: F) i32 { return f(x); }\n"
      "fn main() i32 { return apply(1, |x: bool| x); }\n",
      "does not satisfy bound");
  expect_error(
      "capturing closure into a bare fn param",
      "fn apply(f: fn(i32) i32, x: i32) i32 { return f(x); }\n"
      "fn main() i32 { let b = 1; return apply(|x: i32| x + b, 1); }\n",
      "a capturing closure cannot be passed as a bare 'fn' pointer");
  expect_error(
      "capturing closure into a bare fn let",
      "fn main() i32 { let b = 1; let f: fn(i32) i32 = |x: i32| x + b; return f(1); }\n",
      "mismatch");
  // Mutating a capture is legal when the OUTER binding is `mut` (the capture becomes an implicit
  // `&mut`, so the write is outer-visible); an immutable outer binding keeps its normal errors.
  expect_ok(
      "mutating a mut capture",
      "fn main() i32 { let mut n = 1; let f = fn(x: i32) i32 { n += x; return n; }; return f(1); }\n");
  expect_error(
      "assignment to an immutable capture",
      "fn main() i32 { let n = 1; let f = fn(x: i32) i32 { n = x; return n; }; return f(1); }\n",
      "cannot assign");
  expect_error(
      "&mut of an immutable capture",
      "fn bump(r: &mut i32) { *r += 1; }\n"
      "fn main() i32 { let n = 1; let f = fn(x: i32) i32 { bump(&mut n); return x; }; return f(1); }\n",
      "cannot take '&mut' of an immutable binding");
  expect_error(
      "&mut self method on an immutable capture",
      "struct Counter { pub n: i32 }\n"
      "extend Counter { fn bump(self: &mut Counter) { self.n += 1; } }\n"
      "fn main() i32 {\n"
      "  let c: Counter = Counter { n: 0 };\n"
      "  let f = fn(x: i32) i32 { c.bump(); return x; };\n"
      "  return f(1);\n"
      "}\n",
      "cannot call a '&mut self' method on an immutable binding");
  // Capturing a Free value by copy MOVES it into the env (the closure value owns and frees it):
  // the outer binding is spent, and the env's value cannot be moved back out.
  expect_ok(
      "owning capture reads its value",
      "fn main() i32 {\n"
      "  let s: String = String::from_str(\"hi\");\n"
      "  let f = |x: i32| x + s.len() as i32;\n"
      "  return f(1) + f(2);\n" // calls only borrow the env: twice is fine
      "}\n");
  expect_error(
      "outer use after an owning capture",
      "fn main() i32 {\n"
      "  let s: String = String::from_str(\"hi\");\n"
      "  let f = |x: i32| x + s.len() as i32;\n"
      "  return f(1) + s.len() as i32;\n"
      "}\n",
      "use of moved value");
  expect_error(
      "moving a capture out of the closure",
      "fn eat(s: String) i32 { return s.len() as i32; }\n"
      "fn main() i32 {\n"
      "  let s: String = String::from_str(\"hi\");\n"
      "  let f = |x: i32| x + eat(s);\n"
      "  return f(1);\n"
      "}\n",
      "cannot move a captured value out of a closure");
  expect_error(
      "owning closure needs a fn move bound",
      "fn apply<F: fn(i32) i32>(x: i32, f: F) i32 { return f(x); }\n"
      "fn main() i32 {\n"
      "  let s: String = String::from_str(\"hi\");\n"
      "  return apply(1, |x: i32| x + s.len() as i32);\n"
      "}\n",
      "does not satisfy bound");
  expect_ok(
      "owning closure through a fn move bound",
      "fn apply<F: fn move(i32) i32>(x: i32, f: F) i32 { return f(x) + f(x); }\n"
      "fn main() i32 {\n"
      "  let s: String = String::from_str(\"hi\");\n"
      "  return apply(1, |x: i32| x + s.len() as i32);\n"
      "}\n");
  expect_error(
      "fn move param cannot be passed twice",
      "fn use_once<F: fn move(i32) i32>(f: F) i32 { return f(1); }\n"
      "fn both<F: fn move(i32) i32>(f: F) i32 { return use_once(f) + use_once(f); }\n"
      "fn main() i32 { return both(|x: i32| x + 1); }\n",
      "use of moved value");
  expect_error(
      "capturing a fixed-size array",
      "fn main() i32 { let a: [i32; 2] = [1, 2]; let f = |x: i32| x + a[0]; return f(1); }\n",
      "closure cannot capture a fixed-size array");
}

// Explicit `.free()` is a CONSUMING destructor call: it works on an immutable owned binding (exactly
// like the scope-exit auto-free), while ordinary `&mut self` methods still require `mut`.
static void test_explicit_free_mutability(void) {
  expect_ok(
      "free on an immutable owned binding",
      "fn main() i32 { let v: Vector<i32> = Vector::<i32>::with_capacity(8); v.free(); return 0; }\n");
  expect_error(
      "use after an explicit free still flagged",
      "fn main() i32 { let v: Vector<i32> = Vector::<i32>::new(); v.free(); return v.len() as i32; }\n",
      "use after free");
  expect_error(
      "other &mut self methods still need mut",
      "fn main() i32 { let v: Vector<i32> = Vector::<i32>::new(); v.push(1); return 0; }\n",
      "cannot call a '&mut self' method on an immutable binding");
}

// `&dyn I` / `&mut dyn I` trait objects: erasure coercion, vtable dispatch, dyn-compatibility rules.
#define DYN_PRELUDE \
  "interface Shape { fn area(self: &Self) f64; fn scale(self: &mut Self, k: f64); fn tag(self: &Self) i32 { return 7; } }\n" \
  "struct Circle { pub r: f64 }\n" \
  "extend Circle as Shape {\n" \
  "  pub fn area(self: &Circle) f64 { return self.r; }\n" \
  "  pub fn scale(self: &mut Circle, k: f64) { self.r = k; }\n" \
  "}\n"

// Numeric literal suffixes pin their type; implicit widening is lossless-only (same-signedness wider,
// unsigned into wider signed, f32->f64) -- narrowing / sign changes / usize stay explicit `as` casts.
static void test_numeric_suffixes_widening(void) {
  expect_ok("suffixed literals + lossless widening",
            "fn take(x: i64) i64 { return x; }\n"
            "fn main() i32 {\n"
            "  let a = 200u8; let b = 0xFFu64; let c = 1f32; let d = 0b1010i64; let e = 5usize;\n"
            "  let s: i16 = 3; let w: i32 = s; let u: u8 = 7; let x: u32 = u; let y: i64 = u;\n"
            "  let f: f32 = 1.5; let g: f64 = f;\n"
            "  let m = w + y; let r = take(w);\n"
            "  return 0;\n"
            "}\n");
  expect_error("narrowing stays explicit", "fn main() i32 { let x: i32 = 5i64; return 0; }\n", "mismatched types");
  expect_error("same-width sign change stays explicit", "fn main() i32 { let x: u32 = 5i32; return 0; }\n",
               "mismatched types");
  expect_error("suffixed literal does not adapt down", "fn main() i32 { let x: u8 = 5u16; return 0; }\n",
               "mismatched types");
  expect_error("f64 literal never narrows", "fn main() i32 { let x: f32 = 1.5f64; return 0; }\n", "mismatched types");
  expect_error("usize widening stays explicit", "fn main() i32 { let x: usize = 5u32; return 0; }\n",
               "mismatched types");
  expect_error("suffix range check", "fn main() i32 { let x = 300i8; return 0; }\n",
               "does not fit in its suffixed type");
}

// Assert builtins: read (never move) their arguments, require agreeing comparable types, a bool
// condition, and a str message.
// Auto-deref: method lookup follows `deref`/`deref_mut` hops (wrapper methods win, `&mut self`
// targets require `deref_mut` AND a mutable binding, cycles and by-value aggregate targets error).
static void test_deref(void) {
  expect_ok("methods resolve through Box's deref/deref_mut",
            "fn main() i32 {\n"
            "  let mut b: Box<String> = Box::<String>::new(String::from_str(\"hi\"));\n"
            "  b.push_str(\" there\");\n"
            "  let n = b.len();\n"
            "  return n as i32;\n"
            "}\n");
  expect_ok("by-value builtin method through a plain wrapper's deref",
            "struct V { pub n: i32 }\n"
            "extend V { pub fn deref(self: &V) &i32 { return &self.n; } }\n"
            "fn main() i32 { let v = V { n: 0 - 4 }; return v.abs(); }\n");
  expect_error("&mut self through deref needs a mut binding",
               "fn main() i32 {\n"
               "  let b: Box<String> = Box::<String>::new(String::new());\n"
               "  b.push_str(\"x\");\n"
               "  return 0;\n"
               "}\n",
               "cannot call a '&mut self' method on an immutable binding");
  expect_error("deref without deref_mut cannot reach &mut self methods",
               "struct W { pub s: String }\n"
               "extend W { pub fn deref(self: &W) &String { return &self.s; } }\n"
               "fn main() i32 { let mut w = W { s: String::new() }; w.push_str(\"x\"); return 0; }\n",
               "it has 'deref' but no 'deref_mut'");
  expect_error("cyclic deref chains are rejected",
               "struct A { pub x: i32 }\nstruct B { pub y: i32 }\n"
               "extend A { pub fn deref(self: &A) &B { unsafe { let p = null as *const B; return &*p; } } }\n"
               "extend B { pub fn deref(self: &B) &A { unsafe { let p = null as *const A; return &*p; } } }\n"
               "fn main() i32 { let a = A { x: 1 }; a.missing(); return 0; }\n",
               "cyclic deref chain");
  expect_error("a by-value aggregate method never auto-derefs",
               "struct Inner { pub k: i32 }\n"
               "extend Inner { pub fn consume(self: Inner) i32 { return self.k; } }\n"
               "struct W { pub inner: Inner }\n"
               "extend W { pub fn deref(self: &W) &Inner { return &self.inner; } }\n"
               "fn main() i32 { let w = W { inner: Inner { k: 1 } }; return w.consume(); }\n",
               "cannot call a by-value 'self' method through auto-deref");
}

static void test_assert_builtins(void) {
  expect_ok("assert args are borrowed, not moved",
            "fn main() i32 {\n"
            "  let s = String::from_str(\"hi\");\n"
            "  assert_eq(s.len(), 2);\n"
            "  assert_ne(s.as_str(), \"bye\");\n"
            "  assert(s.len() > 0, \"still usable\");\n"
            "  return s.len() as i32 - 2;\n" // s alive after the asserts
            "}\n");
  expect_error("assert_eq needs agreeing types", "fn main() i32 { assert_eq(1, \"one\"); return 0; }\n",
               "mismatched types");
  expect_error("assert condition must be bool", "fn main() i32 { assert(1); return 0; }\n", "must be 'bool'");
  expect_error("assert message must be str", "fn main() i32 { assert(true, 5); return 0; }\n", "must be a 'str'");
  expect_error("non-comparable types are rejected",
               "struct P { pub x: i32 }\nfn main() i32 { assert_eq(P { x: 1 }, P { x: 1 }); return 0; }\n",
               "cannot compare");
}

// Test-attributed functions are invisible to non-test code (they are not emitted outside --test):
// calls, fn-value references, and suite-method calls are all rejected; test->test calls are fine.
static void test_visibility_of_test_fns(void) {
  expect_error("non-test code cannot call a @test fn",
               "@test\nfn a() { }\nfn b() { a(); }\nfn main() i32 { b(); return 0; }\n",
               "can only be called from other test functions");
  expect_error("non-test code cannot take a @test fn as a value",
               "@test\nfn a() { }\nfn main() i32 { let f = a; f(); return 0; }\n",
               "can only be called from other test functions");
  expect_error("non-test code cannot call a suite test method",
               "struct S { pub x: i32 }\n"
               "extend S {\n"
               "  @test_init fn setup() S { return S { x: 1 }; }\n"
               "  @test fn t(self: &S) { }\n"
               "}\n"
               "fn main() i32 { let s = S { x: 2 }; s.t(); return 0; }\n",
               "can only be called from other test functions");
  expect_ok("a test may call another test (and its fixtures)",
            "@test\nfn helper() { }\n@test\nfn uses_helper() { helper(); }\nfn main() i32 { return 0; }\n");
}

// `Interface::assoc()` resolved by the expected type, on GENERIC targets: let annotation, return
// position, function/method argument (the receiver instance binds the extend's generics), and struct
// field. With no expected type the call is uninferable and must say so.
static void test_iface_assoc_generic_targets(void) {
  static const char *const GEN =
      "struct Pair<T> { pub a: T, pub b: T }\n"
      "extend<T: Default> Pair<T> as Default {\n"
      "  fn default() Pair<T> { return Pair::<T> { a: T::default(), b: T::default() }; }\n"
      "}\n";
  char src[2048];
  snprintf(src, sizeof src, "%s%s", GEN,
           "struct Holder { pub p: Pair<i32> }\n"
           "fn ret_pos() Pair<i32> { return Default::default(); }\n"
           "fn take(p: Pair<i32>) i32 { return p.a; }\n"
           "fn main() i32 {\n"
           "  let ann: Pair<i32> = Default::default();\n"
           "  let x = take(Default::default());\n"
           "  let mut v = Vector::<Pair<i32>>::new();\n"
           "  v.push(Default::default());\n"
           "  let h = Holder { p: Default::default() };\n"
           "  return ret_pos().b + ann.a + x + h.p.a + v.len() as i32 - 1;\n"
           "}\n");
  expect_ok("Interface::assoc() infers generic targets from every expected-type position", src);
  snprintf(src, sizeof src, "%s%s", GEN, "fn main() i32 { let x = Default::default(); return 0; }\n");
  expect_error("Interface::assoc() with no expected type is uninferable", src,
               "cannot infer the implementing type");
}

// Labeled break/continue target resolution + `loop`-expression value typing rules.
static void test_labeled_loops(void) {
  expect_ok("labels + loop expression typecheck",
            "fn main() i32 {\n"
            "  'a: for i in 0..3 { for j in 0..3 { if j > i { continue 'a; } if i * j == 2 { break 'a; } } }\n"
            "  let v = loop { break 5; };\n"
            "  return v;\n"
            "}\n");
  expect_error("break outside a loop", "fn main() i32 { break; return 0; }\n", "outside of a loop");
  expect_error("unknown label", "fn main() i32 { 'a: for i in 0..3 { break 'b; } return 0; }\n",
               "no enclosing loop is labeled");
  expect_error("value break needs a loop expression", "fn main() i32 { while true { break 5; } return 0; }\n",
               "can only carry a value inside a 'loop' expression");
  expect_error("bare break mixed into a value loop",
               "fn main() i32 { let v = loop { break 1; break; }; return v; }\n",
               "must carry a value");
  expect_error("break values must agree",
               "fn main() i32 { let mut i = 0; let v = loop { i += 1; if i == 1 { break \"s\"; } break 1; }; return 0; }\n",
               "mismatched types");
  expect_error("a closure body cannot break an outer loop",
               "fn main() i32 { for i in 0..3 { let f = fn() void { break; }; f(); } return 0; }\n",
               "outside of a loop");
}

// `?` error conversion: differing Result error types are accepted exactly when the caller's error
// type provides From<callee's error>; otherwise the mismatch stays an error (with the From hint).
static void test_question_error_conversion(void) {
  expect_ok("? converts through From",
            "struct IoErr { pub code: i32 }\nstruct AppErr { pub code: i32 }\n"
            "extend AppErr as From<IoErr> { fn from(value: IoErr) AppErr { return AppErr { code: value.code }; } }\n"
            "fn io() Result<i32, IoErr> { return Result::<i32, IoErr>::Ok(1); }\n"
            "fn run() Result<i32, AppErr> { let v = io()?; return Result::<i32, AppErr>::Ok(v); }\n"
            "fn main() i32 { return 0; }\n");
  expect_error("? without a From conversion still mismatches",
               "struct IoErr { pub code: i32 }\nstruct AppErr { pub code: i32 }\n"
               "fn io() Result<i32, IoErr> { return Result::<i32, IoErr>::Ok(1); }\n"
               "fn run() Result<i32, AppErr> { let v = io()?; return Result::<i32, AppErr>::Ok(v); }\n"
               "fn main() i32 { return 0; }\n",
               "does not match the function's error type");
}

// `static mut` module globals: assignable and mutably borrowable; plain consts stay immutable; `mut`
// is mandatory; owning (Free) types are rejected (no scope would ever run their destructor).
static void test_static_mut(void) {
  expect_ok("static mut is assignable and borrowable",
            "static mut counter: i32 = 10;\n"
            "fn bump() { counter += 5; }\n"
            "fn main() i32 { counter = counter + 1; bump(); let r = &mut counter; *r += 1; return counter; }\n");
  expect_error("a const is not assignable", "const K: i32 = 5;\nfn main() i32 { K = 6; return 0; }\n",
               "cannot assign");
  expect_error("static requires mut", "static counter: i32 = 0;\nfn main() i32 { return 0; }\n",
               "expected 'mut' after 'static'");
  expect_error("static mut rejects owning types",
               "static mut v: Vector<i32> = Vector::<i32>::new();\nfn main() i32 { return 0; }\n",
               "cannot hold an owning");
}

static void test_dyn(void) {
  expect_ok(
      "dyn coercion + vtable dispatch",
      DYN_PRELUDE
      "fn total(a: &dyn Shape) f64 { return a.area(); }\n"
      "fn main() i32 { let c = Circle { r: 1.0 }; let d: &dyn Shape = &c; let t = total(&c) + d.area() + d.tag() as f64; return 0; }\n");
  expect_ok(
      "&mut dyn allows &mut self methods",
      DYN_PRELUDE
      "fn main() i32 { let mut c = Circle { r: 1.0 }; let m: &mut dyn Shape = &mut c; m.scale(2.0); return 0; }\n");
  expect_ok(
      "&mut dyn weakens to &dyn",
      DYN_PRELUDE
      "fn view(a: &dyn Shape) f64 { return a.area(); }\n"
      "fn main() i32 { let mut c = Circle { r: 1.0 }; let m: &mut dyn Shape = &mut c; return view(m) as i32; }\n");
  expect_error(
      "&mut self method through &dyn",
      DYN_PRELUDE "fn main() i32 { let c = Circle { r: 1.0 }; let d: &dyn Shape = &c; d.scale(2.0); return 0; }\n",
      "cannot call a '&mut self' method through '&dyn'");
  expect_error(
      "bare interface is not a type",
      DYN_PRELUDE "fn main() i32 { let c = Circle { r: 1.0 }; let w: Shape = c; return 0; }\n",
      "an interface is not a type");
  expect_error(
      "erasing a non-conforming type",
      DYN_PRELUDE "struct Plain { pub x: i32 }\n"
                  "fn main() i32 { let p = Plain { x: 1 }; let d: &dyn Shape = &p; return 0; }\n",
      "mismatched types");
  expect_error(
      "&mut dyn needs a &mut source",
      DYN_PRELUDE "fn main() i32 { let c = Circle { r: 1.0 }; let m: &mut dyn Shape = &c; return 0; }\n",
      "mismatched types");
  expect_error(
      "Self outside the receiver is not dyn-compatible",
      "interface Cloney { fn duplicate(self: &Self) Self; }\n"
      "struct S { pub v: i32 }\nextend S as Cloney { pub fn duplicate(self: &S) S { return S { v: self.v }; } }\n"
      "fn main() i32 { let s = S { v: 1 }; let d: &dyn Cloney = &s; return 0; }\n",
      "not dyn-compatible");
  expect_error(
      "by-value self is not dyn-compatible",
      "interface Sink { fn consume(self: Self) i32; }\n"
      "struct S { pub v: i32 }\nextend S as Sink { pub fn consume(self: S) i32 { return self.v; } }\n"
      "fn main() i32 { let s = S { v: 1 }; let d: &dyn Sink = &s; return 0; }\n",
      "not dyn-compatible");
  expect_error(
      "a generic interface is not dyn-compatible",
      "interface Producer<T> { fn make(self: &Self) i32; }\n"
      "struct S { pub v: i32 }\n"
      "fn f(d: &dyn Producer) i32 { return 0; }\n"
      "fn main() i32 { return 0; }\n",
      "not dyn-compatible");
  expect_error(
      "erasing a generic type parameter",
      DYN_PRELUDE "fn f<T: Shape>(x: &T) f64 { let d: &dyn Shape = x; return d.area(); }\n"
                  "fn main() i32 { let c = Circle { r: 1.0 }; return f(&c) as i32; }\n",
      "cannot erase a generic type parameter");
  // Owned trait objects.
  expect_ok(
      "Box<dyn> erasure, dispatch, reborrow, explicit free",
      DYN_PRELUDE
      "fn view(a: &dyn Shape) f64 { return a.area(); }\n"
      "fn main() i32 { let mut b: Box<dyn Shape> = Box::<Circle>::new(Circle { r: 1.0 });\n"
      "  b.scale(2.0); let v = view(&b); b.free(); return v as i32; }\n");
  expect_error(
      "use after freeing an owned dyn",
      DYN_PRELUDE "fn main() i32 { let mut b: Box<dyn Shape> = Box::<Circle>::new(Circle { r: 1.0 });\n"
                  "  b.free(); return b.area() as i32; }\n",
      "use of moved value");
  expect_error(
      "&mut self through an immutable owned dyn binding",
      DYN_PRELUDE "fn main() i32 { let b: Box<dyn Shape> = Box::<Circle>::new(Circle { r: 1.0 });\n"
                  "  b.scale(2.0); return 0; }\n",
      "cannot call a '&mut self' method on an immutable binding");
  expect_error(
      "bare dyn as a non-Box generic argument",
      DYN_PRELUDE "fn main() i32 { let v: Vector<dyn Shape> = Vector::<dyn Shape>::new(); return 0; }\n",
      "can only be the generic argument of 'Box'");
  // `dyn fn` closures.
  expect_ok(
      "dyn fn: named fn, borrowed closure, owned box; structural instance unification",
      "fn double_it(x: i32) i32 { return x * 2; }\n"
      "fn run(f: &dyn fn(i32) i32, x: i32) i32 { return f(x); }\n"
      "fn main() i32 {\n"
      "  let d: &dyn fn(i32) i32 = double_it;\n"
      "  let k = 3; let f = |x: i32| x + k;\n"
      "  let b: Box<dyn fn(i32) i32> = |x: i32| x + k;\n"
      // the annotation and the turbofish are DIFFERENT nodes: they must intern to one identity
      "  let mut v: Vector<Box<dyn fn(i32) i32>> = Vector::<Box<dyn fn(i32) i32>>::new();\n"
      "  v.push(double_it);\n"
      "  return d(1) + run(&f, 2) + b(3); }\n");
  expect_error(
      "a capturing closure by value needs a borrow for &dyn fn",
      "fn take(f: &dyn fn(i32) i32) i32 { return f(1); }\n"
      "fn main() i32 { let k = 5; let f = |x: i32| x + k; return take(f); }\n",
      "must be borrowed");
  expect_error(
      "a runtime fn pointer cannot erase",
      "fn main() i32 { let p: fn(i32) i32 = |x: i32| x; let d: &dyn fn(i32) i32 = p; return 0; }\n",
      "wrap it in a closure");
  expect_error(
      "no &mut dyn fn flavor",
      "fn main() i32 { let k = 1; let f = |x: i32| x + k; let m: &mut dyn fn(i32) i32 = &f; return 0; }\n",
      "shared view");
  expect_error(
      "dyn fn signature mismatch",
      "fn main() i32 { let k = 1; let f = |x: i32| x + k; let w: &dyn fn(i32) bool = &f; return 0; }\n",
      "mismatched types");
}

int main(void) {
  test_ok();
  test_bug_regressions();
  test_ffi();
  test_static_assert();
  test_slices();
  test_computed_scalar_types();
  test_computed_pointer_types();
  test_computed_reference_type();
  test_literal_types();
  test_inferred_let_types();
  test_str_member_types();
  test_errors();
  test_switch_exhaustiveness();
  test_unsafe_enforcement();
  test_never_type();
  test_tuples();
  test_interface_bounds();
  test_closures();
  test_explicit_free_mutability();
  test_dyn();
  test_numeric_suffixes_widening();
  test_static_mut();
  test_question_error_conversion();
  test_labeled_loops();
  test_deref();
  test_assert_builtins();
  test_visibility_of_test_fns();
  test_iface_assoc_generic_targets();
  if (failures) {
    fprintf(stderr, "%d typechecker test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("typechecker tests passed");
  return 0;
}
