// Parser coverage. Beyond item/statement counts, this asserts tree *shape*: operator precedence
// and associativity, the `>>` token split inside nested generics, the struct-initializer
// ambiguity flag (`Foo {}` as a value vs `if cond {}` as a condition), and multi-error recovery.

#include "test_harness.h"

static bool parse_has_error(const char *source) {
  char first[256];
  return sc_stage_errors("rejection", source, ST_PARSE, first, sizeof first) >= 1;
}

// program item `i`.
static const Node *item(const Ast *a, const uint32_t i) {
  return ast_at_const(a, ast_list(a, ast_at_const(a, a->root)->as.program.items)[i]);
}

static void test_items_and_types(void) {
  static const char source[] = "struct Pair<T> { left: T, right: T, }\n"
                               "enum Result<T, E> { Ok(T), Err { error: E }, }\n"
                               "type Callback = fn(*const u8, []u8, [u8; 16]) (int, Error);\n"
                               "const LIMIT: usize = 16;\n"
                               "extern \"C\" { type CFile; fn fclose(file: *mut CFile) int; }\n";
  Ast *ast = sc_parse("items and types", source);
  if (!ast)
    return;
  const Node *root = ast_at_const(ast, ast->root);
  CHECK(root->kind == NODE_PROGRAM, "items and types: expected program root");
  CHECK(root->as.program.items.len == 5, "items and types: expected 5 items, got %u", root->as.program.items.len);
  CHECK(item(ast, 0)->kind == NODE_STRUCT, "items and types: item 0 should be struct");
  CHECK(item(ast, 1)->kind == NODE_ENUM, "items and types: item 1 should be enum");
  CHECK(item(ast, 2)->kind == NODE_TYPE_ALIAS, "items and types: item 2 should be type alias");
  const Node *callback = ast_at_const(ast, item(ast, 2)->as.type_alias.type);
  CHECK(callback->kind == NODE_FUNCTION_TYPE, "items and types: callback should be a function type");
  CHECK(callback->as.function_type.returns.len == 2, "items and types: callback should have two returns");
  CHECK(item(ast, 3)->kind == NODE_CONST, "items and types: item 3 should be const");
  CHECK(item(ast, 4)->kind == NODE_EXTERN_BLOCK, "items and types: item 4 should be extern");
  ast_free(&ast);
}

static void test_associated_new_name(void) {
  Ast *ast = sc_parse("associated new name", "struct String {}\nextend String { fn new() String { return String {}; } }\n");
  if (!ast)
    return;
  const Node *ext = item(ast, 1);
  CHECK(ext->kind == NODE_EXTEND, "associated new name: item 1 should be an extension");
  const NodeId method_id = ast_list(ast, ext->as.extend_def.items)[0];
  const Node *method = ast_at_const(ast, method_id);
  CHECK(method->kind == NODE_FUNCTION, "associated new name: extension item should be a function");
  CHECK(th_ident_is(ast, "struct String {}\nextend String { fn new() String { return String {}; } }\n", method->as.function.name, "new"),
        "associated new name: method should be named new");
  ast_free(&ast);
}

static void test_functions_and_expressions(void) {
  static const char source[] =
      "fn transform<T: Copy>(input: Result<Vec<T>, Error>, out: *mut T) int where T: Copy + Free {\n"
      "  let mut value: int = 1 + 2 * 3;\n"
      "  let item = input.unwrap()[0] as int;\n"
      "  if (item >= value && value != 0) { value += item; } else { value = 0; }\n"
      "  while (value > 0) { value -= 1; }\n"
      "  for entry in input { defer consume(move entry); }\n"
      "  return value;\n"
      "}\n";
  Ast *ast = sc_parse("functions and expressions", source);
  if (!ast)
    return;
  const Node *fn = item(ast, 0);
  CHECK(fn->kind == NODE_FUNCTION, "functions and expressions: expected function");
  CHECK(fn->as.function.generics.len == 1, "functions and expressions: expected one generic");
  CHECK(fn->as.function.params.len == 2, "functions and expressions: expected two parameters");
  CHECK(fn->as.function.returns.len == 1, "functions and expressions: expected one return");
  CHECK(fn->as.function.where_clause.len == 1, "functions and expressions: expected one where predicate");
  const Node *body = ast_at_const(ast, fn->as.function.body);
  CHECK(body->kind == NODE_BLOCK, "functions and expressions: expected function block");
  CHECK(
      body->as.block.statements.len == 6, "functions and expressions: expected 6 statements, got %u",
      body->as.block.statements.len);
  ast_free(&ast);
}

static void test_traits_impls_match_and_new(void) {
  static const char source[] = "interface Factory<T> { type Output; fn make(value: T) Self::Output; }\n"
                               "extend<T> Box<T> as Factory<T> {\n"
                               "  type Output = Box<T>;\n"
                               "  fn make(value: T) Box<T> { return new Box<T> { value: value }; }\n"
                               "}\n"
                               "fn classify(c: u8) int {\n"
                               "  return switch c { case '0'..='9' => 1, Value(x) if x > 0 => x, _ => 0, };\n"
                               "}\n";
  Ast *ast = sc_parse("interfaces extensions switch and new", source);
  if (!ast)
    return;
  const Node *root = ast_at_const(ast, ast->root);
  CHECK(root->as.program.items.len == 3, "interfaces extensions switch and new: expected 3 items");
  CHECK(item(ast, 0)->kind == NODE_INTERFACE, "expected interface");
  CHECK(item(ast, 1)->kind == NODE_EXTEND, "expected extension");
  CHECK(item(ast, 2)->kind == NODE_FUNCTION, "expected function");
  ast_free(&ast);
}

static void test_grouped_parameters_and_returns(void) {
  static const char source[] = "fn slice(self: *mut Self, start, end, len: isize) *mut Self {}\n"
                               "fn divmod(a, b: int) (int, int) { return a / b, a % b; }\n"
                               "fn open(path: str) (file: File, err: IOError) {}\n"
                               "fn log(message: str) {}\n"
                               "fn risky(ptr: *mut int) { unsafe { consume(ptr); } unsafe consume(ptr); }\n";
  Ast *ast = sc_parse("grouped parameters and returns", source);
  if (!ast)
    return;
  const Node *root = ast_at_const(ast, ast->root);
  CHECK(root->as.program.items.len == 5, "grouped parameters and returns: expected 5 functions");

  CHECK(item(ast, 0)->as.function.params.len == 4, "grouped parameters and returns: expected 4 slice parameters");
  CHECK(item(ast, 0)->as.function.returns.len == 1, "grouped parameters and returns: expected one slice return");

  const Node *divmod = item(ast, 1);
  CHECK(divmod->as.function.params.len == 2, "grouped parameters and returns: expected 2 divmod parameters");
  CHECK(divmod->as.function.returns.len == 2, "grouped parameters and returns: expected 2 divmod returns");
  const Node *divmod_body = ast_at_const(ast, divmod->as.function.body);
  const Node *return_stmt = ast_at_const(ast, ast_list(ast, divmod_body->as.block.statements)[0]);
  CHECK(return_stmt->kind == NODE_RETURN, "grouped parameters and returns: expected return statement");
  CHECK(return_stmt->as.return_stmt.values.len == 2, "grouped parameters and returns: expected 2 return values");

  const Node *open = item(ast, 2);
  CHECK(open->as.function.returns.len == 2, "grouped parameters and returns: expected 2 named returns");
  const NodeId *open_returns = ast_list(ast, open->as.function.returns);
  CHECK(ast_at_const(ast, open_returns[0])->kind == NODE_PARAMETER, "expected named return parameter");
  CHECK(ast_at_const(ast, open_returns[1])->kind == NODE_PARAMETER, "expected named return parameter");

  CHECK(item(ast, 3)->as.function.returns.len == 0, "grouped parameters and returns: expected no log return");

  const Node *risky_body = ast_at_const(ast, item(ast, 4)->as.function.body);
  CHECK(risky_body->as.block.statements.len == 2, "grouped parameters and returns: expected 2 unsafe statements");
  ast_free(&ast);
}

// Precedence: `*` binds tighter than `+`; `-` is left-associative.
static void test_precedence(void) {
  Ast *a = sc_parse("precedence", "fn f() i32 { return 1 + 2 * 3; }\n");
  if (a) {
    const Node *body = ast_at_const(a, item(a, 0)->as.function.body);
    const Node *ret = ast_at_const(a, ast_list(a, body->as.block.statements)[0]);
    const Node *top = ast_at_const(a, ast_list(a, ret->as.return_stmt.values)[0]);
    CHECK(top->kind == NODE_BINARY && top->as.binary.op == Plus, "top operator is +");
    CHECK(ast_at_const(a, top->as.binary.right)->as.binary.op == Star, "* is the right child (binds tighter)");
    CHECK(ast_at_const(a, top->as.binary.left)->kind == NODE_LITERAL, "left operand is the literal 1");
    ast_free(&a);
  }

  Ast *b = sc_parse("associativity", "fn f() i32 { return 1 - 2 - 3; }\n");
  if (b) {
    const Node *body = ast_at_const(b, item(b, 0)->as.function.body);
    const Node *ret = ast_at_const(b, ast_list(b, body->as.block.statements)[0]);
    const Node *top = ast_at_const(b, ast_list(b, ret->as.return_stmt.values)[0]);
    CHECK(top->kind == NODE_BINARY && top->as.binary.op == Minus, "top operator is -");
    CHECK(ast_at_const(b, top->as.binary.left)->as.binary.op == Minus, "- is left-associative (left child is -)");
    ast_free(&b);
  }
}

// `Vec<Vec<i32>>` requires splitting the `>>` token into two closing `>`s.
static void test_generic_shift_split(void) {
  Ast *a = sc_parse("generic >> split", "type Nested = Vec<Vec<i32>>;\n");
  if (!a)
    return;
  const Node *outer = ast_at_const(a, item(a, 0)->as.type_alias.type);
  CHECK(outer->kind == NODE_TYPE_PATH && outer->as.type_path.args.len == 1, "outer Vec has one type argument");
  const Node *inner = ast_at_const(a, ast_list(a, outer->as.type_path.args)[0]);
  CHECK(inner->kind == NODE_TYPE_PATH && inner->as.type_path.args.len == 1, "inner Vec<i32> parsed (>> was split)");
  ast_free(&a);
}

// The struct-initializer flag: `Foo {}` is a value, but in a condition the `{` opens the block.
static void test_struct_initializer_flag(void) {
  Ast *a = sc_parse("struct init value", "struct Foo { x: i32, }\nfn f() void { let p: Foo = Foo { x: 1, }; }\n");
  if (a) {
    const Node *let = ast_at_const(a, th_nth_kind(a, NODE_LET, 0));
    CHECK(ast_at_const(a, let->as.let_stmt.value)->kind == NODE_STRUCT_INITIALIZER, "Foo {} is a struct initializer");
    ast_free(&a);
  }
  Ast *b = sc_parse("condition is not struct init", "fn g() void { if cond { } }\n");
  if (b) {
    const Node *iff = ast_at_const(b, th_nth_kind(b, NODE_IF, 0));
    CHECK(ast_at_const(b, iff->as.if_stmt.condition)->kind == NODE_IDENTIFIER, "`if cond {}` keeps cond as the value");
    CHECK(ast_at_const(b, iff->as.if_stmt.then_branch)->kind == NODE_BLOCK, "the `{}` is the then-branch");
    ast_free(&b);
  }
}

static void test_closures(void) {
  // Compact `|x: i32| expr` -> a NODE_CLOSURE with an expression body; the `|` is not parsed as bitwise-or.
  Ast *a = sc_parse("compact closure", "fn f() i32 { let g = |x: i32| x + 1; return g(0); }\n");
  if (a) {
    const Node *let = ast_at_const(a, th_nth_kind(a, NODE_LET, 0));
    const Node *clo = ast_at_const(a, let->as.let_stmt.value);
    CHECK(clo->kind == NODE_CLOSURE, "`|x| e` parses to a closure");
    CHECK(clo->as.closure.expr_body, "compact closure has an expression body");
    CHECK(clo->as.closure.params.len == 1, "the closure has one parameter");
    ast_free(&a);
  }
  // Anonymous `fn(..) Ret { .. }` -> a NODE_CLOSURE with a block body and an explicit return type.
  Ast *b = sc_parse("anonymous fn", "fn f() i32 { let h = fn(x: i32) i32 { return x * 2; }; return h(0); }\n");
  if (b) {
    const Node *let = ast_at_const(b, th_nth_kind(b, NODE_LET, 0));
    const Node *clo = ast_at_const(b, let->as.let_stmt.value);
    CHECK(clo->kind == NODE_CLOSURE, "`fn(..) .. {}` parses to a closure");
    CHECK(!clo->as.closure.expr_body, "anonymous fn has a block body");
    CHECK(clo->as.closure.returns.len == 1, "anonymous fn keeps its explicit return type");
    ast_free(&b);
  }
  // Infix `|` is still bitwise-or, not a closure.
  Ast *c = sc_parse("bitwise or stays binary", "fn f() i32 { return 1 | 2; }\n");
  if (c) {
    CHECK(th_nth_kind(c, NODE_CLOSURE, 0) == NODE_NONE, "`a | b` is not a closure");
    CHECK(th_nth_kind(c, NODE_BINARY, 0) != NODE_NONE, "`a | b` is a binary expression");
    ast_free(&c);
  }
  // `F: fn(i32) i32` -- a callable bound is a NODE_FUNCTION_TYPE in the generic param's bound list
  // (one-token LL(1) decision on `fn`); the same form parses in a where clause.
  Ast *d = sc_parse("fn-type bound", "fn apply<F: fn(i32) i32 + Eq>(x: i32, f: F) i32 { return f(x); }\n");
  if (d) {
    const Node *gp = ast_at_const(d, th_nth_kind(d, NODE_GENERIC_PARAM, 0));
    CHECK(gp->as.generic_param.bounds.len == 2, "both bounds collected");
    const NodeId *bids = ast_list(d, gp->as.generic_param.bounds);
    CHECK(ast_at_const(d, bids[0])->kind == NODE_FUNCTION_TYPE, "`fn(..) ..` parses as a bound");
    CHECK(ast_at_const(d, bids[0])->as.function_type.params.len == 1, "the bound keeps its signature");
    CHECK(ast_at_const(d, bids[1])->kind == NODE_TYPE_PATH, "an interface bound still follows `+`");
    ast_free(&d);
  }
  Ast *e = sc_parse("fn-type bound in where", "fn apply<F>(x: i32, f: F) i32 where F: fn(i32) i32 { return f(x); }\n");
  if (e) {
    const Node *wp = ast_at_const(e, th_nth_kind(e, NODE_WHERE_PREDICATE, 0));
    const NodeId *bids = ast_list(e, wp->as.where_predicate.bounds);
    CHECK(wp->as.where_predicate.bounds.len == 1 && ast_at_const(e, bids[0])->kind == NODE_FUNCTION_TYPE,
          "`where F: fn(..) ..` parses");
    CHECK(!ast_at_const(e, bids[0])->as.function_type.is_move, "a plain fn bound is not `move`");
    ast_free(&e);
  }
  // `fn move(..) ..`: the ownership-marked bound (accepts closures that own captured Free values).
  Ast *g = sc_parse("fn move bound", "fn run<F: fn move(i32) i32>(x: i32, f: F) i32 { return f(x); }\n");
  if (g) {
    const Node *gp = ast_at_const(g, th_nth_kind(g, NODE_GENERIC_PARAM, 0));
    const NodeId *bids = ast_list(g, gp->as.generic_param.bounds);
    CHECK(gp->as.generic_param.bounds.len == 1 && ast_at_const(g, bids[0])->kind == NODE_FUNCTION_TYPE &&
              ast_at_const(g, bids[0])->as.function_type.is_move,
          "`fn move(..) ..` parses with the move flag");
    ast_free(&g);
  }
  // `&dyn I` / `&mut dyn I` fold into ONE NODE_DYN_TYPE (never a reference wrapping it); the
  // qualifier carries the flavor. A `dyn` inside generic args parses with qualifier NONE (owned).
  Ast *h = sc_parse("dyn types", "fn f(a: &dyn Shape, b: &mut dyn Shape, c: Box<dyn Shape>) void {}\n");
  if (h) {
    const NodeId d0 = th_nth_kind(h, NODE_DYN_TYPE, 0), d1 = th_nth_kind(h, NODE_DYN_TYPE, 1),
                 d2 = th_nth_kind(h, NODE_DYN_TYPE, 2);
    CHECK(d0 != NODE_NONE && ast_at_const(h, d0)->as.indirect_type.qualifier == TYPE_QUAL_CONST,
          "`&dyn I` is one DYN_TYPE node (const flavor)");
    CHECK(d1 != NODE_NONE && ast_at_const(h, d1)->as.indirect_type.qualifier == TYPE_QUAL_MUT,
          "`&mut dyn I` carries the mut flavor");
    CHECK(d2 != NODE_NONE && ast_at_const(h, d2)->as.indirect_type.qualifier == TYPE_QUAL_NONE,
          "`Box<dyn I>`'s argument parses with the owned flavor");
    CHECK(th_nth_kind(h, NODE_REFERENCE_TYPE, 0) == NODE_NONE, "no reference node wraps a dyn type");
    ast_free(&h);
  }
}

static void test_error_recovery(void) {
  char first[256];
  const size_t n =
      sc_stage_errors("recovery", "fn f() void { let x: i32 = ; let y: i32 = ; }\n", ST_PARSE, first, sizeof first);
  CHECK(n >= 2, "two malformed lets produce multiple errors (got %zu), proving resync", n);
}

static void test_bare_conditions_and_ranges(void) {
  static const char source[] = "fn f() void {\n"
                               "  if x { }\n"
                               "  while y { }\n"
                               "  for i in 0..10 { }\n"
                               "  for i in 1..=5 { }\n"
                               "  for i in ..4 { }\n"
                               "  for i in 6.. { }\n"
                               "}\n";
  Ast *ast = sc_parse("bare conditions and ranges", source);
  if (!ast)
    return;
  const Node *body = ast_at_const(ast, item(ast, 0)->as.function.body);
  const NodeId *stmts = ast_list(ast, body->as.block.statements);
  CHECK(body->as.block.statements.len == 6, "bare conditions: expected 6 statements");
  CHECK(ast_at_const(ast, stmts[0])->kind == NODE_IF, "bare 'if' parses to NODE_IF");
  CHECK(ast_at_const(ast, stmts[1])->kind == NODE_WHILE, "bare 'while' parses to NODE_WHILE");

  const Node *r1 = ast_at_const(ast, ast_at_const(ast, stmts[2])->as.for_stmt.iterable);
  CHECK(r1->kind == NODE_RANGE, "0..10 iterable is NODE_RANGE");
  CHECK(
      r1->as.pattern_range.start != NODE_NONE && r1->as.pattern_range.end != NODE_NONE && !r1->as.pattern_range.inclusive,
      "0..10 is an exclusive range with both bounds");
  CHECK(ast_at_const(ast, ast_at_const(ast, stmts[3])->as.for_stmt.iterable)->as.pattern_range.inclusive,
        "1..=5 is inclusive");
  const Node *r3 = ast_at_const(ast, ast_at_const(ast, stmts[4])->as.for_stmt.iterable);
  CHECK(r3->as.pattern_range.start == NODE_NONE && r3->as.pattern_range.end != NODE_NONE, "..4 has no start");
  const Node *r4 = ast_at_const(ast, ast_at_const(ast, stmts[5])->as.for_stmt.iterable);
  CHECK(r4->as.pattern_range.start != NODE_NONE && r4->as.pattern_range.end == NODE_NONE, "6.. has no end");
  ast_free(&ast);

  CHECK(parse_has_error("fn f() void { for i in .. { } }\n"), "bare '..' range is rejected");
  CHECK(parse_has_error("fn f() void { for i in 0..= { } }\n"), "inclusive range without an end is rejected");
}

// The postfix `?` early-return operator parses to a NODE_UNARY whose op is the `?` token, applied to the
// preceding postfix expression (so `f()?` is `(f())?`).
static void test_question_operator_parse(void) {
  Ast *ast = sc_parse("question operator", "fn f() void { let x = g()?; }\n");
  if (!ast)
    return;
  const Node *body = ast_at_const(ast, item(ast, 0)->as.function.body);
  const Node *let = ast_at_const(ast, ast_list(ast, body->as.block.statements)[0]);
  const Node *val = ast_at_const(ast, let->as.let_stmt.value);
  CHECK(val->kind == NODE_UNARY && val->as.unary.op == Question, "g()? parses to a NODE_UNARY with op '?'");
  CHECK(ast_at_const(ast, val->as.unary.operand)->kind == NODE_CALL, "the `?` operand is the call g()");
  ast_free(&ast);
}

// A `lo..hi` in expression position (a `let` initializer here) parses to a NODE_RANGE value -- the same
// node the for/index forms use -- with both bounds and the inclusive flag preserved. One token of
// lookahead (`..`/`..=` after the start) decides it, so the grammar stays LL(1).
static void test_range_value_expression(void) {
  static const char source[] = "fn f() void {\n"
                               "  let a = 1..5;\n"
                               "  let b = 0..=9;\n"
                               "}\n";
  Ast *ast = sc_parse("range value expression", source);
  if (!ast)
    return;
  const Node *body = ast_at_const(ast, item(ast, 0)->as.function.body);
  const NodeId *stmts = ast_list(ast, body->as.block.statements);
  const Node *a = ast_at_const(ast, ast_at_const(ast, stmts[0])->as.let_stmt.value);
  CHECK(a->kind == NODE_RANGE, "let a = 1..5 -> NODE_RANGE value");
  CHECK(a->as.pattern_range.start != NODE_NONE && a->as.pattern_range.end != NODE_NONE && !a->as.pattern_range.inclusive,
        "1..5 has both bounds, exclusive");
  const Node *b = ast_at_const(ast, ast_at_const(ast, stmts[1])->as.let_stmt.value);
  CHECK(b->kind == NODE_RANGE && b->as.pattern_range.inclusive, "0..=9 is an inclusive NODE_RANGE value");
  ast_free(&ast);
}

static void test_switch_pattern_ranges(void) {
  static const char source[] = "fn f(n: i32) i32 {\n"
                               "  return switch n {\n"
                               "    10..20 => 1,\n"
                               "    20..=30 => 2,\n"
                               "    ..5 => 3,\n"
                               "    99.. => 4,\n"
                               "    _ => 0,\n"
                               "  };\n"
                               "}\n";
  Ast *ast = sc_parse("switch pattern ranges", source);
  if (!ast)
    return;
  const Node *body = ast_at_const(ast, item(ast, 0)->as.function.body);
  const Node *ret = ast_at_const(ast, ast_list(ast, body->as.block.statements)[0]);
  const Node *sw = ast_at_const(ast, ast_list(ast, ret->as.return_stmt.values)[0]);
  CHECK(sw->kind == NODE_MATCH, "switch parses to NODE_MATCH");
  const NodeId *arms = ast_list(ast, sw->as.match_expr.arms);
  CHECK(sw->as.match_expr.arms.len == 5, "switch: expected 5 arms");
#define PAT(i) ast_at_const(ast, ast_at_const(ast, arms[i])->as.match_arm.pattern)
  CHECK(PAT(0)->kind == NODE_PATTERN_RANGE && !PAT(0)->as.pattern_range.inclusive, "10..20 is an exclusive pattern range");
  CHECK(PAT(0)->as.pattern_range.start != NODE_NONE && PAT(0)->as.pattern_range.end != NODE_NONE, "10..20 has both bounds");
  CHECK(PAT(1)->kind == NODE_PATTERN_RANGE && PAT(1)->as.pattern_range.inclusive, "20..=30 is inclusive");
  CHECK(PAT(2)->as.pattern_range.start == NODE_NONE && PAT(2)->as.pattern_range.end != NODE_NONE, "..5 has no start");
  CHECK(PAT(3)->as.pattern_range.start != NODE_NONE && PAT(3)->as.pattern_range.end == NODE_NONE, "99.. has no end");
  CHECK(PAT(4)->kind == NODE_PATTERN_WILDCARD, "_ is a wildcard");
#undef PAT
  ast_free(&ast);

  CHECK(parse_has_error("fn f(n: i32) i32 { return switch n { .. => 1, }; }\n"), "bare '..' pattern is rejected");
  CHECK(parse_has_error("fn f(n: i32) i32 { return switch n { 0..= => 1, }; }\n"), "inclusive pattern without an end is rejected");
}

// `pub` sets is_public on structs, functions, methods, and fields; its absence leaves them private.
static void test_pub_modifiers(void) {
  Ast *a = sc_parse(
      "pub modifiers",
      "pub struct S { pub x: i32, y: i32, }\n"
      "extend S { pub fn shown() {} fn hidden() {} }\n"
      "pub fn f() {}\nfn g() {}\n"
      "pub enum E { A, B }\nenum F { C }\n"
      "pub const K: i32 = 1;\nconst L: i32 = 2;\n"
      "pub type Ta = i32;\ntype Tb = i32;\n");
  if (!a)
    return;
  const Node *s = item(a, 0);
  CHECK(s->kind == NODE_STRUCT && s->as.aggregate.is_public, "pub struct is public");
  const NodeId *fields = ast_list(a, s->as.aggregate.members);
  CHECK(ast_at_const(a, fields[0])->as.field.is_public, "pub field x is public");
  CHECK(!ast_at_const(a, fields[1])->as.field.is_public, "non-pub field y is private");
  const NodeId *methods = ast_list(a, item(a, 1)->as.extend_def.items);
  CHECK(ast_at_const(a, methods[0])->as.function.is_public, "pub method is public");
  CHECK(!ast_at_const(a, methods[1])->as.function.is_public, "non-pub method is private");
  CHECK(item(a, 2)->as.function.is_public, "pub fn is public");
  CHECK(!item(a, 3)->as.function.is_public, "non-pub fn is private");
  CHECK(item(a, 4)->kind == NODE_ENUM && item(a, 4)->as.aggregate.is_public, "pub enum is public");
  CHECK(item(a, 5)->kind == NODE_ENUM && !item(a, 5)->as.aggregate.is_public, "non-pub enum is private");
  CHECK(item(a, 6)->kind == NODE_CONST && item(a, 6)->as.const_def.is_public, "pub const is public");
  CHECK(item(a, 7)->kind == NODE_CONST && !item(a, 7)->as.const_def.is_public, "non-pub const is private");
  CHECK(item(a, 8)->kind == NODE_TYPE_ALIAS && item(a, 8)->as.type_alias.is_public, "pub type is public");
  CHECK(item(a, 9)->kind == NODE_TYPE_ALIAS && !item(a, 9)->as.type_alias.is_public, "non-pub type is private");
  ast_free(&a);
  CHECK(parse_has_error("pub let x: i32 = 1;\n"), "pub before a non-item is rejected");
}

// An untagged `union` parses like a struct (NODE_STRUCT with fields) but is flagged is_union; `pub` and
// per-field `pub` apply as for a struct.
static void test_union(void) {
  Ast *a = sc_parse("union decl", "pub union Bits { pub i: u32, bytes: [u8; 4], }\n");
  if (!a)
    return;
  const Node *u = item(a, 0);
  CHECK(u->kind == NODE_STRUCT, "union parses as a NODE_STRUCT");
  CHECK(u->as.aggregate.is_union, "union is flagged is_union");
  CHECK(u->as.aggregate.is_public, "pub union is public");
  const NodeId *fields = ast_list(a, u->as.aggregate.members);
  CHECK(ast_at_const(a, fields[0])->as.field.is_public, "pub union field is public");
  CHECK(!ast_at_const(a, fields[1])->as.field.is_public, "non-pub union field is private");
  ast_free(&a);
  // A plain struct is not flagged is_union.
  Ast *b = sc_parse("struct not union", "struct S { x: i32, }\n");
  if (b) {
    CHECK(!item(b, 0)->as.aggregate.is_union, "a struct is not is_union");
    ast_free(&b);
  }
}

// `@c.*` attributes parse into the Ast's attribute table; malformed ones are rejected with a diagnostic.
static void test_attributes(void) {
  Ast *a = sc_parse(
      "attributes",
      "@c.packed\nstruct H { x: u32, }\n"
      "@c.noreturn\n@c.export(\"sym\")\nfn die() void {}\n");
  if (a) {
    CHECK(a->attrs.len == 3, "three attributes recorded");
    CHECK(item(a, 0)->kind == NODE_STRUCT, "attributed struct parses");
    CHECK(item(a, 1)->kind == NODE_FUNCTION, "attributed fn parses");
    ast_free(&a);
  }
  CHECK(parse_has_error("@c.frobnicate\nfn m() {}\n"), "unknown attribute rejected");
  CHECK(parse_has_error("@rust.inline\nfn m() {}\n"), "unknown namespace rejected");
  CHECK(parse_has_error("@c.align\nstruct S { x: i32 }\n"), "align without an argument rejected");
  CHECK(parse_has_error("@c.gnu.attribute(\"hot\")\nfn m() {}\n"), "target-specific namespace rejected");
  CHECK(parse_has_error("@c.inline(3)\nfn m() {}\n"), "no-arg attribute given an argument rejected");
}

// Regressions for parser bugs from the cross-stage hunt.
static void test_bug_regressions(void) {
  // P1: a comparison after a cast must parse as `(a as i32) < b`, not be eaten as generic type args.
  CHECK(!parse_has_error("fn f(a: i32, b: i32) bool { return a as i32 < b; }\n"), "`a as i32 < b` should parse");
  // P2: deeply nested blocks must hit the depth guard and diagnose, not overflow the stack. > PARSE_MAX_DEPTH.
  {
    static char src[2048];
    size_t at = 0;
    for (const char *p = "fn main() i32 {"; *p; p++)
      src[at++] = *p;
    for (int i = 0; i < 700; i++)
      src[at++] = '{';
    for (const char *p = " return 0; "; *p; p++)
      src[at++] = *p;
    for (int i = 0; i < 700; i++)
      src[at++] = '}';
    src[at++] = '}';
    src[at] = '\0';
    CHECK(parse_has_error(src), "deeply nested blocks should diagnose, not crash");
  }
}

int main(void) {
  test_bug_regressions();
  test_items_and_types();
  test_attributes();
  test_union();
  test_pub_modifiers();
  test_associated_new_name();
  test_functions_and_expressions();
  test_traits_impls_match_and_new();
  test_grouped_parameters_and_returns();
  test_precedence();
  test_generic_shift_split();
  test_struct_initializer_flag();
  test_closures();
  test_error_recovery();
  test_bare_conditions_and_ranges();
  test_range_value_expression();
  test_question_operator_parse();
  test_switch_pattern_ranges();
  if (failures) {
    fprintf(stderr, "%d parser test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("parser tests passed");
  return 0;
}
