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
  expect_ok("str ptr field indexes to u8", "fn first(s: str) u8 { return s.ptr[0]; }\n");
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
  expect_ok("pointer offset", "fn f(p: *i32) i32 { let q: *i32 = p + 1; return *q; }\n");
  expect_ok("pointer minus int", "fn f(p: *i32) i32 { let q: *i32 = p - 1; return *q; }\n");
  expect_ok("int plus pointer", "fn f(p: *i32) i32 { let q: *i32 = 1 + p; return *q; }\n");
  expect_ok("pointer difference", "fn f(a: *i32, b: *i32) isize { return a - b; }\n");
  expect_ok("explicit void bare return", "fn f() void { return; }\n");
  expect_ok("range adopts usize bound", "fn f(n: usize) void { for i in 0..n { let x: usize = i; } }\n");
  expect_ok("associated new call", "struct String {}\nextend String { fn new() String { return String {}; } }\nfn f() String { return String::new(); }\n");
  expect_ok(
      "reference coerces to const pointer",
      "fn take(p: *const i32) i32 { return *p; }\n"
      "fn give(x: i32) i32 { return take(&x); }\n");
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
  static const char src[] = "fn f(p: *i32) i32 { let q: *i32 = p + 1; return *q; }\n";
  Ast *a = sc_typecheck("pointer types", src);
  if (!a)
    return;
  const NodeId off = th_nth_kind(a, NODE_BINARY, 0); // p + 1
  const TypeId ot = ast_type(a, off);
  CHECK(ast_type_at(a, ot)->kind == TYPE_POINTER, "pointer offset stays a pointer");
  CHECK(ast_type_at(a, ot)->as.elem == ast_builtin(BT_I32), "pointee is i32");
  const NodeId deref = th_nth_kind(a, NODE_UNARY, 0); // *q
  CHECK(ast_type(a, deref) == ast_builtin(BT_I32), "deref yields the pointee type");
  ast_free(&a);
}

static void test_computed_reference_type(void) {
  // `*p` is unary[0] (in `take`), `&x` is unary[1] (in `give`, parsed second).
  static const char src[] = "fn take(p: *const i32) i32 { return *p; }\n"
                            "fn give(x: i32) i32 { return take(&x); }\n";
  Ast *a = sc_typecheck("reference type", src);
  if (!a)
    return;
  const NodeId addr = th_nth_kind(a, NODE_UNARY, 1); // &x
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
  static const char src[] = "fn main() i32 { let g: str = \"hi\"; let n: usize = g.len; let b: u8 = g.ptr[0]; return 0; }\n";
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
      "fn main() i32 { let mut buf: [char; 8]; memset(&mut buf[0], 0, 8); return 0; }\n");
  expect_error("let mismatch", "fn main() i32 { let b: bool = 1; }\n", "mismatched types");
  expect_error("float literal not assignable to int", "fn main() i32 { let i: i32 = 0.0; }\n", "mismatched types");
  expect_error("f32 is not Eq", "fn needs<T: Eq>(x: T) bool { return true; }\nfn main() i32 { if needs::<f32>(0.0) { return 1; } return 0; }\n",
               "does not satisfy bound 'Eq'");
  expect_error("f32 is not Ord", "fn needs<T: Ord>(x: T) bool { return true; }\nfn main() i32 { if needs::<f32>(0.0) { return 1; } return 0; }\n",
               "does not satisfy bound 'Ord'");
  expect_error("f32 is not Hash",
               "fn needs<T: Hash>(x: T) bool { return true; }\nfn main() i32 { if needs::<f32>(0.0) { return 1; } return 0; }\n",
               "does not satisfy bound 'Hash'");
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
      "pointer plus pointer", "fn f(a: *i32, b: *i32) void { let c = a + b; }\n", "invalid pointer arithmetic");
  expect_error(
      "non-integer pointer offset", "fn f(p: *i32, y: f64) void { let q = p + y; }\n",
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
      "extend S as A { fn a(self: *mut Self) i32 { return self.v; } }\n"
      "extend S as B { fn b(self: *mut Self) i32 { return self.v; } }\n"
      "fn both<T>(x: &mut T) i32 where T: A + B { return x.a() + x.b(); }\n"
      "fn main() i32 { let mut s = S { v: 1 }; return both(&mut s); }\n");
  expect_ok(
      "conditional extension satisfied",
      "interface Free { fn free(self: *mut Self) i32; }\n"
      "struct Res { pub id: i32 }\nextend Res as Free { fn free(self: *mut Self) i32 { return self.id; } }\n"
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
      "extend File as Writer { fn write(self: *mut Self) i32 { return self.count; } }\n"
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
      "extend File as Writer { fn write(self: *mut Self) i32 { return self.count; } }\n"
      "fn f<T: Writer>(w: &mut T) i32 { return w.nope(); }\n"
      "fn main() i32 { let mut x = File { count: 0 }; return f(&mut x); }\n",
      "no field or method 'nope'");
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
      "fn main() i32 { let f: char = '%'; printf(&f, 1, 2, 3); return 0; }\n");
  expect_ok(
      "variadic call with no extra args",
      "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\n"
      "fn main() i32 { let f: char = '%'; printf(&f); return 0; }\n");
  // ... but never fewer than the fixed params, and `...` is meaningless without an extern C body.
  expect_error(
      "variadic call below fixed arity",
      "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\n"
      "fn main() i32 { printf(); return 0; }\n",
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
      "extern \"C\" { fn puts(s: *const char) i32; }\nfn main() i32 { puts(\"hi\"); return 0; }\n");
  expect_ok(
      "string literal -> *const u8 param",
      "extern \"C\" { fn f(s: *const u8) i32; }\nfn main() i32 { return f(\"hi\"); }\n");
  expect_ok(
      "string literal as %s vararg",
      "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\nfn main() i32 { printf(\"%s\", \"hi\"); return 0; }\n");
  expect_ok("string literal stays str by default", "fn main() i32 { let s: str = \"hi\"; return s.len() as i32; }\n");
  expect_error(
      "string literal not a mutable pointer",
      "extern \"C\" { fn f(s: *mut char) i32; }\nfn main() i32 { return f(\"hi\"); }\n", "mismatched types");
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

int main(void) {
  test_ok();
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
  test_interface_bounds();
  if (failures) {
    fprintf(stderr, "%d typechecker test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("typechecker tests passed");
  return 0;
}
