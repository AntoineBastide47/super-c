// Self-hosted port of tests/parser_test.c: parser AST-shape coverage (item/statement counts, operator
// precedence/associativity, the generic `>>` token split, the struct-initializer flag, closures,
// ranges, pub/union/attrs flags, error recovery, and depth caps) via tests::harness.
import ast::ast as *;
import lexer::token_type as *;
import tests::harness as h;

// Program item `i` (mirror of parser_test.c's `item`): the i-th node in the program's item list.
const fn item_id(a: &Ast, i: u32) NodeId {
    let items = a.at_const(a.root).as_data.program.items;
    return unsafe a.list(items)[i as usize];
}

const fn item(a: &Ast, i: u32) &Node {
    let items = a.at_const(a.root).as_data.program.items;
    let ids = a.list(items);
    return a.at_const(unsafe ids[i as usize]);
}

@test
fn items_and_types() {
    let src = "struct Pair<T> { left: T, right: T, }\nenum Result<T, E> { Ok(T), Err { error: E }, }\ntype Callback = fn(*const u8, []u8, [u8; 16]) (int, Error);\nconst LIMIT: usize = 16;\nextern \"C\" { type CFile; fn fclose(file: *mut CFile) int; }\n";
    let c = h::parse_ast(src);
    assert(c.errors == 0, "items and types parses");
    let root = c.ast.root;
    assert(c.ast.at_const(root).kind == NodeKind::NODE_PROGRAM, "items and types: expected program root");
    assert(c.ast.at_const(root).as_data.program.items.len == 5, "items and types: expected 5 items");
    assert(item(&c.ast, 0).kind == NodeKind::NODE_STRUCT, "items and types: item 0 should be struct");
    assert(item(&c.ast, 1).kind == NodeKind::NODE_ENUM, "items and types: item 1 should be enum");
    assert(item(&c.ast, 2).kind == NodeKind::NODE_TYPE_ALIAS, "items and types: item 2 should be type alias");
    let cb_id = item(&c.ast, 2).as_data.type_alias.ty;
    assert(
        c.ast.at_const(cb_id).kind == NodeKind::NODE_FUNCTION_TYPE,
        "items and types: callback should be a function type",
    );
    assert(
        c.ast.at_const(cb_id).as_data.function_type.returns.len == 2,
        "items and types: callback should have two returns",
    );
    assert(item(&c.ast, 3).kind == NodeKind::NODE_CONST, "items and types: item 3 should be const");
    assert(item(&c.ast, 4).kind == NodeKind::NODE_EXTERN_BLOCK, "items and types: item 4 should be extern");
}

@test
fn associated_new_name() {
    let src = "struct String {}\nextend String { fn new() String { return String {}; } }\n";
    let c = h::parse_ast(src);
    assert(c.errors == 0, "associated new name parses");
    assert(item(&c.ast, 1).kind == NodeKind::NODE_EXTEND, "associated new name: item 1 should be an extension");
    let ext_items = item(&c.ast, 1).as_data.extend_def.items;
    let ids = c.ast.list(ext_items);
    let method_id = unsafe ids[0];
    assert(
        c.ast.at_const(method_id).kind == NodeKind::NODE_FUNCTION,
        "associated new name: extension item should be a function",
    );
    let name_id = c.ast.at_const(method_id).as_data.function.name;
    assert(
        h::ident_is(&c.ast, src.ptr() as *const char, name_id, "new".ptr() as *const char),
        "associated new name: method should be named new",
    );
}

@test
fn functions_and_expressions() {
    let src = "fn transform<T: Copy>(input: Result<Vec<T>, Error>, out: *mut T) int where T: Copy + Free {\n  let mut value: int = 1 + 2 * 3;\n  let item = input.unwrap()[0] as int;\n  if (item >= value && value != 0) { value += item; } else { value = 0; }\n  while (value > 0) { value -= 1; }\n  for entry in input { defer consume(move entry); }\n  return value;\n}\n";
    let c = h::parse_ast(src);
    assert(c.errors == 0, "functions and expressions parses");
    assert(item(&c.ast, 0).kind == NodeKind::NODE_FUNCTION, "functions and expressions: expected function");
    assert(item(&c.ast, 0).as_data.function.generics.len == 1, "functions and expressions: expected one generic");
    assert(item(&c.ast, 0).as_data.function.params.len == 2, "functions and expressions: expected two parameters");
    assert(item(&c.ast, 0).as_data.function.returns.len == 1, "functions and expressions: expected one return");
    assert(
        item(&c.ast, 0).as_data.function.where_clause.len == 1,
        "functions and expressions: expected one where predicate",
    );
    let body_id = item(&c.ast, 0).as_data.function.body;
    assert(c.ast.at_const(body_id).kind == NodeKind::NODE_BLOCK, "functions and expressions: expected function block");
    assert(
        c.ast.at_const(body_id).as_data.block.statements.len == 6,
        "functions and expressions: expected 6 statements",
    );
}

@test
fn traits_impls_match_and_new() {
    let src = "interface Factory<T> { type Output; fn make(value: T) Self::Output; }\nextend<T> Box<T> as Factory<T> {\n  type Output = Box<T>;\n  fn make(value: T) Box<T> { return new Box<T> { value: value }; }\n}\nfn classify(c: u8) int {\n  return switch c { case '0'..='9' => 1, Value(x) if x > 0 => x, _ => 0, };\n}\n";
    let c = h::parse_ast(src);
    assert(c.errors == 0, "interfaces extensions switch and new parses");
    let root = c.ast.root;
    assert(
        c.ast.at_const(root).as_data.program.items.len == 3,
        "interfaces extensions switch and new: expected 3 items",
    );
    assert(item(&c.ast, 0).kind == NodeKind::NODE_INTERFACE, "expected interface");
    assert(item(&c.ast, 1).kind == NodeKind::NODE_EXTEND, "expected extension");
    assert(item(&c.ast, 2).kind == NodeKind::NODE_FUNCTION, "expected function");
}

// `unsafe extend`: an item-scope `unsafe` that commits to an extend rather than a function, on the one
// token after it (LL(1)). The flag rides the extend, not the items inside it -- what is being asserted is
// the conformance. Nothing requires the marker yet; this pins that it parses and survives.
@test
fn unsafe_extend() {
    let src = "unsafe extend<T> Box<T> as Sync {}\nextend Vector<i32> as Sync {}\nunsafe fn f() {}\n";
    let c = h::parse_ast(src);
    assert(c.errors == 0, "unsafe extend parses");
    assert(item(&c.ast, 0).kind == NodeKind::NODE_EXTEND, "expected an extend");
    assert(item(&c.ast, 0).as_data.extend_def.is_unsafe, "expected the extend to be marked unsafe");
    assert(!item(&c.ast, 1).as_data.extend_def.is_unsafe, "a plain extend stays unmarked");
    assert(item(&c.ast, 2).as_data.function.is_unsafe, "unsafe fn still parses after the new branch");
    let bad = h::parse_ast("unsafe struct S {}\n");
    assert(bad.errors > 0, "unsafe on a non-fn, non-extend item is rejected");
}

@test
fn grouped_parameters_and_returns() {
    let src = "fn slice(self: *mut Self, start, end, len: isize) *mut Self {}\nfn divmod(a, b: int) (int, int) { return a / b, a % b; }\nfn open(path: str) (file: File, err: IOError) {}\nfn log(message: str) {}\nfn risky(ptr: *mut int) { unsafe { consume(ptr); } unsafe consume(ptr); }\n";
    let c = h::parse_ast(src);
    assert(c.errors == 0, "grouped parameters and returns parses");
    let root = c.ast.root;
    assert(c.ast.at_const(root).as_data.program.items.len == 5, "grouped parameters and returns: expected 5 functions");

    assert(
        item(&c.ast, 0).as_data.function.params.len == 4,
        "grouped parameters and returns: expected 4 slice parameters",
    );
    assert(
        item(&c.ast, 0).as_data.function.returns.len == 1,
        "grouped parameters and returns: expected one slice return",
    );

    assert(
        item(&c.ast, 1).as_data.function.params.len == 2,
        "grouped parameters and returns: expected 2 divmod parameters",
    );
    assert(
        item(&c.ast, 1).as_data.function.returns.len == 2,
        "grouped parameters and returns: expected 2 divmod returns",
    );
    let divmod_body_id = item(&c.ast, 1).as_data.function.body;
    let dbstmts = c.ast.at_const(divmod_body_id).as_data.block.statements;
    let dstmts = c.ast.list(dbstmts);
    let ret_id = unsafe dstmts[0];
    assert(
        c.ast.at_const(ret_id).kind == NodeKind::NODE_RETURN,
        "grouped parameters and returns: expected return statement",
    );
    assert(
        c.ast.at_const(ret_id).as_data.return_stmt.values.len == 2,
        "grouped parameters and returns: expected 2 return values",
    );

    assert(
        item(&c.ast, 2).as_data.function.returns.len == 2,
        "grouped parameters and returns: expected 2 named returns",
    );
    let open_rets = item(&c.ast, 2).as_data.function.returns;
    let open_returns = c.ast.list(open_rets);
    let or0 = unsafe open_returns[0];
    let or1 = unsafe open_returns[1];
    assert(c.ast.at_const(or0).kind == NodeKind::NODE_PARAMETER, "expected named return parameter");
    assert(c.ast.at_const(or1).kind == NodeKind::NODE_PARAMETER, "expected named return parameter");

    assert(item(&c.ast, 3).as_data.function.returns.len == 0, "grouped parameters and returns: expected no log return");

    let risky_body_id = item(&c.ast, 4).as_data.function.body;
    assert(
        c.ast.at_const(risky_body_id).as_data.block.statements.len == 2,
        "grouped parameters and returns: expected 2 unsafe statements",
    );
}

// Precedence: `*` binds tighter than `+`; `-` is left-associative.
@test
fn precedence() {
    {
        let c = h::parse_ast("fn f() i32 { return 1 + 2 * 3; }\n");
        assert(c.errors == 0, "precedence parses");
        let body_id = item(&c.ast, 0).as_data.function.body;
        let bstmts = c.ast.at_const(body_id).as_data.block.statements;
        let stmts = c.ast.list(bstmts);
        let ret_id = unsafe stmts[0];
        let rvals = c.ast.at_const(ret_id).as_data.return_stmt.values;
        let vals = c.ast.list(rvals);
        let top_id = unsafe vals[0];
        assert(
            c.ast.at_const(top_id).kind == NodeKind::NODE_BINARY && c.ast.at_const(top_id).as_data.binary.op == TokenType::Plus,
            "top operator is +",
        );
        let right_id = c.ast.at_const(top_id).as_data.binary.right;
        let left_id = c.ast.at_const(top_id).as_data.binary.left;
        assert(c.ast.at_const(right_id).as_data.binary.op == TokenType::Star, "* is the right child (binds tighter)");
        assert(c.ast.at_const(left_id).kind == NodeKind::NODE_LITERAL, "left operand is the literal 1");
    }
    {
        let c = h::parse_ast("fn f() i32 { return 1 - 2 - 3; }\n");
        assert(c.errors == 0, "associativity parses");
        let body_id = item(&c.ast, 0).as_data.function.body;
        let bstmts = c.ast.at_const(body_id).as_data.block.statements;
        let stmts = c.ast.list(bstmts);
        let ret_id = unsafe stmts[0];
        let rvals = c.ast.at_const(ret_id).as_data.return_stmt.values;
        let vals = c.ast.list(rvals);
        let top_id = unsafe vals[0];
        assert(
            c.ast.at_const(top_id).kind == NodeKind::NODE_BINARY && c.ast.at_const(top_id).as_data.binary.op == TokenType::Minus,
            "top operator is -",
        );
        let left_id = c.ast.at_const(top_id).as_data.binary.left;
        assert(c.ast.at_const(left_id).as_data.binary.op == TokenType::Minus, "- is left-associative (left child is -)");
    }
}

// Every `>` is already an individual token, so nested generic closers need no parser state.
@test
fn nested_generic_closers() {
    let c = h::parse_ast("type Nested = Vec<Vec<i32>>;\n");
    assert(c.errors == 0, "generic >> split parses");
    let outer_id = item(&c.ast, 0).as_data.type_alias.ty;
    assert(
        c.ast.at_const(outer_id).kind == NodeKind::NODE_TYPE_PATH && c.ast.at_const(outer_id).as_data.type_path.args.len == 1,
        "outer Vec has one type argument",
    );
    let outer_args = c.ast.at_const(outer_id).as_data.type_path.args;
    let args = c.ast.list(outer_args);
    let inner_id = unsafe args[0];
    assert(
        c.ast.at_const(inner_id).kind == NodeKind::NODE_TYPE_PATH && c.ast.at_const(inner_id).as_data.type_path.args.len == 1,
        "inner Vec<i32> parsed from individual '>' tokens",
    );
}

@test
fn rebuilt_greater_operators() {
    let c = h::parse_ast(
        "fn f(a: i32, b: i32, c: i32) { let ge = a > = b; let shr = a > > b; a > > = b; let x = a > b >> c; let y = a >> b > c; a | b >>= c; }\n",
    );
    assert(c.errors == 0, "left-factored greater-than operators parse");
    let ge = h::nth_kind(&c.ast, NodeKind::NODE_BINARY, 0);
    let shr = h::nth_kind(&c.ast, NodeKind::NODE_BINARY, 1);
    let assign = h::nth_kind(&c.ast, NodeKind::NODE_ASSIGNMENT, 0);
    assert(c.ast.at_const(ge).as_data.binary.op == TokenType::GreaterThanEqual, "'>=' is rebuilt");
    assert(c.ast.at_const(shr).as_data.binary.op == TokenType::RightShift, "'>>' is rebuilt");
    assert(c.ast.at_const(assign).as_data.binary.op == TokenType::RightShiftEqual, "'>>=' is rebuilt");
    let gt_shift = h::nth_kind(&c.ast, NodeKind::NODE_BINARY, 3);
    let shift_gt = h::nth_kind(&c.ast, NodeKind::NODE_BINARY, 5);
    assert(c.ast.at_const(gt_shift).as_data.binary.op == TokenType::GreaterThan, "shift binds inside relational RHS");
    assert(c.ast.at_const(shift_gt).as_data.binary.op == TokenType::GreaterThan, "shift binds inside relational LHS");
    let compound = h::nth_kind(&c.ast, NodeKind::NODE_ASSIGNMENT, 1);
    let compound_left = c.ast.at_const(compound).as_data.binary.left;
    assert(
        c.ast.at_const(compound_left).as_data.binary.op == TokenType::Pipe,
        "binary expression folds before shift assignment",
    );
}

// The condition-expression grammar excludes a bare struct initializer, while delimited child
// expressions use the full expression grammar.
@test
fn condition_expression_grammar() {
    {
        let c = h::parse_ast("struct Foo { x: i32, }\nfn f() { let p: Foo = Foo { x: 1, }; }\n");
        assert(c.errors == 0, "struct init value parses");
        let let_id = h::nth_kind(&c.ast, NodeKind::NODE_LET, 0);
        let val_id = c.ast.at_const(let_id).as_data.let_stmt.value;
        assert(c.ast.at_const(val_id).kind == NodeKind::NODE_STRUCT_INITIALIZER, "Foo {} is a struct initializer");
    }
    {
        let c = h::parse_ast("fn g() { if cond { } }\n");
        assert(c.errors == 0, "condition is not struct init parses");
        let iff_id = h::nth_kind(&c.ast, NodeKind::NODE_IF, 0);
        let cond_id = c.ast.at_const(iff_id).as_data.if_stmt.condition;
        let then_id = c.ast.at_const(iff_id).as_data.if_stmt.then_branch;
        assert(c.ast.at_const(cond_id).kind == NodeKind::NODE_IDENTIFIER, "`if cond {}` keeps cond as the value");
        assert(c.ast.at_const(then_id).kind == NodeKind::NODE_BLOCK, "the `{}` is the then-branch");
    }
    assert(
        !h::parse_has_error(
            "struct Foo { x: i32 }\nfn pred(x: Foo) bool { return true; }\nfn g() { if pred(Foo { x: 1 }) { } }\n",
        ),
        "a delimited call argument in a condition accepts a struct initializer",
    );
    assert(
        !h::parse_has_error("struct Foo { x: i32 }\nfn g() { if (Foo { x: 1 }) { } }\n"),
        "a parenthesized condition accepts a struct initializer",
    );
    assert(
        !h::parse_has_error(
            "struct Foo { x: i32 }\nfn values(x: Foo) [Foo; 1] { return [x]; }\nfn g() { for x in values(Foo { x: 1 }) { } }\n",
        ),
        "a delimited call argument in a for iterable accepts a struct initializer",
    );
}

@test
fn soft_keyword_names() {
    let c = h::parse_ast(
        "struct static { va_arg: i32 }\nfn static_assert() {}\nfn f(static_assert: i32) i32 { let va_arg = static_assert; return va_arg; }\n",
    );
    assert(c.errors == 0, "soft keywords remain valid in unambiguous name positions");
    assert(item(&c.ast, 0).kind == NodeKind::NODE_STRUCT, "soft-keyword struct name parses");
    assert(item(&c.ast, 1).kind == NodeKind::NODE_FUNCTION, "soft-keyword function name parses");
}

@test
fn closures() {
    // Compact `|x: i32| expr` -> a NODE_CLOSURE with an expression body; the `|` is not bitwise-or.
    {
        let c = h::parse_ast("fn f() i32 { let g = |x: i32| x + 1; return g(0); }\n");
        assert(c.errors == 0, "compact closure parses");
        let let_id = h::nth_kind(&c.ast, NodeKind::NODE_LET, 0);
        let clo_id = c.ast.at_const(let_id).as_data.let_stmt.value;
        assert(c.ast.at_const(clo_id).kind == NodeKind::NODE_CLOSURE, "`|x| e` parses to a closure");
        assert(c.ast.at_const(clo_id).as_data.closure.expr_body, "compact closure has an expression body");
        assert(c.ast.at_const(clo_id).as_data.closure.params.len == 1, "the closure has one parameter");
    }
    // Anonymous `fn(..) Ret { .. }` -> a NODE_CLOSURE with a block body and an explicit return type.
    {
        let c = h::parse_ast("fn f() i32 { let h = fn(x: i32) i32 { return x * 2; }; return h(0); }\n");
        assert(c.errors == 0, "anonymous fn parses");
        let let_id = h::nth_kind(&c.ast, NodeKind::NODE_LET, 0);
        let clo_id = c.ast.at_const(let_id).as_data.let_stmt.value;
        assert(c.ast.at_const(clo_id).kind == NodeKind::NODE_CLOSURE, "`fn(..) .. {}` parses to a closure");
        assert(!c.ast.at_const(clo_id).as_data.closure.expr_body, "anonymous fn has a block body");
        assert(c.ast.at_const(clo_id).as_data.closure.returns.len == 1, "anonymous fn keeps its explicit return type");
    }
    // Infix `|` is still bitwise-or, not a closure.
    {
        let c = h::parse_ast("fn f() i32 { return 1 | 2; }\n");
        assert(c.errors == 0, "bitwise or parses");
        assert(h::nth_kind(&c.ast, NodeKind::NODE_CLOSURE, 0) == NODE_NONE, "`a | b` is not a closure");
        assert(h::nth_kind(&c.ast, NodeKind::NODE_BINARY, 0) != NODE_NONE, "`a | b` is a binary expression");
    }
    // `F: fn(i32) i32` -- a callable bound is a NODE_FUNCTION_TYPE in the generic param's bound list.
    {
        let c = h::parse_ast("fn apply<F: fn(i32) i32 + Eq>(x: i32, f: F) i32 { return f(x); }\n");
        assert(c.errors == 0, "fn-type bound parses");
        let gp_id = h::nth_kind(&c.ast, NodeKind::NODE_GENERIC_PARAM, 0);
        let bounds = c.ast.at_const(gp_id).as_data.generic_param.bounds;
        assert(bounds.len == 2, "both bounds collected");
        let bids = c.ast.list(bounds);
        let b0 = unsafe bids[0];
        let b1 = unsafe bids[1];
        assert(c.ast.at_const(b0).kind == NodeKind::NODE_FUNCTION_TYPE, "`fn(..) ..` parses as a bound");
        assert(c.ast.at_const(b0).as_data.function_type.params.len == 1, "the bound keeps its signature");
        assert(c.ast.at_const(b1).kind == NodeKind::NODE_TYPE_PATH, "an interface bound still follows `+`");
    }
    // The same form parses in a where clause.
    {
        let c = h::parse_ast("fn apply<F>(x: i32, f: F) i32 where F: fn(i32) i32 { return f(x); }\n");
        assert(c.errors == 0, "fn-type bound in where parses");
        let wp_id = h::nth_kind(&c.ast, NodeKind::NODE_WHERE_PREDICATE, 0);
        let wbounds = c.ast.at_const(wp_id).as_data.where_predicate.bounds;
        let wbids = c.ast.list(wbounds);
        let wb0 = unsafe wbids[0];
        assert(
            wbounds.len == 1 && c.ast.at_const(wb0).kind == NodeKind::NODE_FUNCTION_TYPE,
            "`where F: fn(..) ..` parses",
        );
        assert(!c.ast.at_const(wb0).as_data.function_type.is_move, "a plain fn bound is not `move`");
    }
    // `fn move(..) ..`: the ownership-marked bound.
    {
        let c = h::parse_ast("fn run<F: fn move(i32) i32>(x: i32, f: F) i32 { return f(x); }\n");
        assert(c.errors == 0, "fn move bound parses");
        let gp_id = h::nth_kind(&c.ast, NodeKind::NODE_GENERIC_PARAM, 0);
        let gbounds = c.ast.at_const(gp_id).as_data.generic_param.bounds;
        let gbids = c.ast.list(gbounds);
        let gb0 = unsafe gbids[0];
        assert(
            gbounds.len == 1 && c.ast.at_const(gb0).kind == NodeKind::NODE_FUNCTION_TYPE && c.ast.at_const(gb0).as_data.function_type.is_move,
            "`fn move(..) ..` parses with the move flag",
        );
    }
    // `&dyn I` / `&mut dyn I` fold into ONE NODE_DYN_TYPE; the qualifier carries the flavor.
    {
        let c = h::parse_ast("fn f(a: &dyn Shape, b: &mut dyn Shape, c: Box<dyn Shape>) {}\n");
        assert(c.errors == 0, "dyn types parses");
        let d0 = h::nth_kind(&c.ast, NodeKind::NODE_DYN_TYPE, 0);
        let d1 = h::nth_kind(&c.ast, NodeKind::NODE_DYN_TYPE, 1);
        let d2 = h::nth_kind(&c.ast, NodeKind::NODE_DYN_TYPE, 2);
        assert(
            d0 != NODE_NONE && c.ast.at_const(d0).as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_CONST,
            "`&dyn I` is one DYN_TYPE node (const flavor)",
        );
        assert(
            d1 != NODE_NONE && c.ast.at_const(d1).as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_MUT,
            "`&mut dyn I` carries the mut flavor",
        );
        assert(
            d2 != NODE_NONE && c.ast.at_const(d2).as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_NONE,
            "`Box<dyn I>`'s argument parses with the owned flavor",
        );
        assert(h::nth_kind(&c.ast, NodeKind::NODE_REFERENCE_TYPE, 0) == NODE_NONE, "no reference node wraps a dyn type");
    }
    // `&dyn fn(i32) i32`: a `dyn` over a function type (the anonymous one-method interface).
    {
        let c = h::parse_ast("fn f(cb: &dyn fn(i32) i32) i32 { return cb(1); }\n");
        assert(c.errors == 0, "dyn fn type parses");
        let d0 = h::nth_kind(&c.ast, NodeKind::NODE_DYN_TYPE, 0);
        let inner_ty = c.ast.at_const(d0).as_data.indirect_type.ty;
        assert(
            d0 != NODE_NONE && c.ast.at_const(inner_ty).kind == NodeKind::NODE_FUNCTION_TYPE,
            "`&dyn fn(..) ..` parses as DYN_TYPE over FUNCTION_TYPE",
        );
    }
}

@test
fn error_recovery() {
    // Two malformed lets produce multiple errors (>= 2), proving resync.
    let c = h::parse_ast("fn f() { let x: i32 = ; let y: i32 = ; }\n");
    assert(c.errors >= 2, "two malformed lets produce multiple errors, proving resync");
}

@test
fn bare_conditions_and_ranges() {
    let src = "fn f() {\n  if x { }\n  while y { }\n  for i in 0..10 { }\n  for i in 1..=5 { }\n  for i in ..4 { }\n  for i in 6.. { }\n}\n";
    let c = h::parse_ast(src);
    assert(c.errors == 0, "bare conditions and ranges parses");
    let body_id = item(&c.ast, 0).as_data.function.body;
    let bstmts = c.ast.at_const(body_id).as_data.block.statements;
    let stmts = c.ast.list(bstmts);
    assert(bstmts.len == 6, "bare conditions: expected 6 statements");
    let s0 = unsafe stmts[0];
    let s1 = unsafe stmts[1];
    assert(c.ast.at_const(s0).kind == NodeKind::NODE_IF, "bare 'if' parses to NODE_IF");
    assert(c.ast.at_const(s1).kind == NodeKind::NODE_WHILE, "bare 'while' parses to NODE_WHILE");

    let s2 = unsafe stmts[2];
    let it2 = c.ast.at_const(s2).as_data.for_stmt.iterable;
    assert(c.ast.at_const(it2).kind == NodeKind::NODE_RANGE, "0..10 iterable is NODE_RANGE");
    assert(
        c.ast.at_const(it2).as_data.pattern_range.start != NODE_NONE && c.ast.at_const(it2).as_data.pattern_range.end != NODE_NONE && !c.ast.at_const(
            it2,
        ).as_data.pattern_range.inclusive,
        "0..10 is an exclusive range with both bounds",
    );
    let s3 = unsafe stmts[3];
    let it3 = c.ast.at_const(s3).as_data.for_stmt.iterable;
    assert(c.ast.at_const(it3).as_data.pattern_range.inclusive, "1..=5 is inclusive");
    let s4 = unsafe stmts[4];
    let it4 = c.ast.at_const(s4).as_data.for_stmt.iterable;
    assert(
        c.ast.at_const(it4).as_data.pattern_range.start == NODE_NONE && c.ast.at_const(it4).as_data.pattern_range.end != NODE_NONE,
        "..4 has no start",
    );
    let s5 = unsafe stmts[5];
    let it5 = c.ast.at_const(s5).as_data.for_stmt.iterable;
    assert(
        c.ast.at_const(it5).as_data.pattern_range.start != NODE_NONE && c.ast.at_const(it5).as_data.pattern_range.end == NODE_NONE,
        "6.. has no end",
    );

    assert(h::parse_has_error("fn f() { for i in .. { } }\n"), "bare '..' range is rejected");
    assert(h::parse_has_error("fn f() { for i in 0..= { } }\n"), "inclusive range without an end is rejected");
}

// The postfix `?` early-return operator parses to a NODE_UNARY whose op is the `?` token.
@test
fn question_operator_parse() {
    let c = h::parse_ast("fn f() { let x = g()?; }\n");
    assert(c.errors == 0, "question operator parses");
    let body_id = item(&c.ast, 0).as_data.function.body;
    let bstmts = c.ast.at_const(body_id).as_data.block.statements;
    let stmts = c.ast.list(bstmts);
    let let_id = unsafe stmts[0];
    let val_id = c.ast.at_const(let_id).as_data.let_stmt.value;
    assert(
        c.ast.at_const(val_id).kind == NodeKind::NODE_UNARY && c.ast.at_const(val_id).as_data.unary.op == TokenType::Question,
        "g()? parses to a NODE_UNARY with op '?'",
    );
    let operand_id = c.ast.at_const(val_id).as_data.unary.operand;
    assert(c.ast.at_const(operand_id).kind == NodeKind::NODE_CALL, "the `?` operand is the call g()");
}

// A `lo..hi` in expression position parses to a NODE_RANGE value, bounds + inclusive flag preserved.
@test
fn range_value_expression() {
    let src = "fn f() {\n  let a = 1..5;\n  let b = 0..=9;\n}\n";
    let c = h::parse_ast(src);
    assert(c.errors == 0, "range value expression parses");
    let body_id = item(&c.ast, 0).as_data.function.body;
    let bstmts = c.ast.at_const(body_id).as_data.block.statements;
    let stmts = c.ast.list(bstmts);
    let s0 = unsafe stmts[0];
    let av_id = c.ast.at_const(s0).as_data.let_stmt.value;
    assert(c.ast.at_const(av_id).kind == NodeKind::NODE_RANGE, "let a = 1..5 -> NODE_RANGE value");
    assert(
        c.ast.at_const(av_id).as_data.pattern_range.start != NODE_NONE && c.ast.at_const(av_id).as_data.pattern_range.end != NODE_NONE && !c.ast.at_const(
            av_id,
        ).as_data.pattern_range.inclusive,
        "1..5 has both bounds, exclusive",
    );
    let s1 = unsafe stmts[1];
    let bv_id = c.ast.at_const(s1).as_data.let_stmt.value;
    assert(
        c.ast.at_const(bv_id).kind == NodeKind::NODE_RANGE && c.ast.at_const(bv_id).as_data.pattern_range.inclusive,
        "0..=9 is an inclusive NODE_RANGE value",
    );
}

@test
fn switch_pattern_ranges() {
    let src = "fn f(n: i32) i32 {\n  return switch n {\n    10..20 => 1,\n    20..=30 => 2,\n    ..5 => 3,\n    99.. => 4,\n    _ => 0,\n  };\n}\n";
    let c = h::parse_ast(src);
    assert(c.errors == 0, "switch pattern ranges parses");
    let body_id = item(&c.ast, 0).as_data.function.body;
    let bstmts = c.ast.at_const(body_id).as_data.block.statements;
    let bs = c.ast.list(bstmts);
    let ret_id = unsafe bs[0];
    let rvals = c.ast.at_const(ret_id).as_data.return_stmt.values;
    let rv = c.ast.list(rvals);
    let sw_id = unsafe rv[0];
    assert(c.ast.at_const(sw_id).kind == NodeKind::NODE_MATCH, "switch parses to NODE_MATCH");
    let arms_list = c.ast.at_const(sw_id).as_data.match_expr.arms;
    assert(arms_list.len == 5, "switch: expected 5 arms");
    let arms = c.ast.list(arms_list);
    let a0 = unsafe arms[0];
    let p0 = c.ast.at_const(a0).as_data.match_arm.pattern;
    assert(
        c.ast.at_const(p0).kind == NodeKind::NODE_PATTERN_RANGE && !c.ast.at_const(p0).as_data.pattern_range.inclusive,
        "10..20 is an exclusive pattern range",
    );
    assert(
        c.ast.at_const(p0).as_data.pattern_range.start != NODE_NONE && c.ast.at_const(p0).as_data.pattern_range.end != NODE_NONE,
        "10..20 has both bounds",
    );
    let a1 = unsafe arms[1];
    let p1 = c.ast.at_const(a1).as_data.match_arm.pattern;
    assert(
        c.ast.at_const(p1).kind == NodeKind::NODE_PATTERN_RANGE && c.ast.at_const(p1).as_data.pattern_range.inclusive,
        "20..=30 is inclusive",
    );
    let a2 = unsafe arms[2];
    let p2 = c.ast.at_const(a2).as_data.match_arm.pattern;
    assert(
        c.ast.at_const(p2).as_data.pattern_range.start == NODE_NONE && c.ast.at_const(p2).as_data.pattern_range.end != NODE_NONE,
        "..5 has no start",
    );
    let a3 = unsafe arms[3];
    let p3 = c.ast.at_const(a3).as_data.match_arm.pattern;
    assert(
        c.ast.at_const(p3).as_data.pattern_range.start != NODE_NONE && c.ast.at_const(p3).as_data.pattern_range.end == NODE_NONE,
        "99.. has no end",
    );
    let a4 = unsafe arms[4];
    let p4 = c.ast.at_const(a4).as_data.match_arm.pattern;
    assert(c.ast.at_const(p4).kind == NodeKind::NODE_PATTERN_WILDCARD, "_ is a wildcard");

    assert(h::parse_has_error("fn f(n: i32) i32 { return switch n { .. => 1, }; }\n"), "bare '..' pattern is rejected");
    assert(
        h::parse_has_error("fn f(n: i32) i32 { return switch n { 0..= => 1, }; }\n"),
        "inclusive pattern without an end is rejected",
    );
}

// `pub` sets is_public on structs, functions, methods, and fields; its absence leaves them private.
@test
fn pub_modifiers() {
    let src = "pub struct S { pub x: i32, y: i32, }\nextend S { pub fn shown() {} fn hidden() {} }\npub fn f() {}\nfn g() {}\npub enum E { A, B }\nenum F { C }\npub const K: i32 = 1;\nconst L: i32 = 2;\npub type Ta = i32;\ntype Tb = i32;\n";
    let c = h::parse_ast(src);
    assert(c.errors == 0, "pub modifiers parses");
    assert(
        item(&c.ast, 0).kind == NodeKind::NODE_STRUCT && item(&c.ast, 0).as_data.aggregate.is_public,
        "pub struct is public",
    );
    let members = item(&c.ast, 0).as_data.aggregate.members;
    let fields = c.ast.list(members);
    let f0 = unsafe fields[0];
    let f1 = unsafe fields[1];
    assert(c.ast.at_const(f0).as_data.field.is_public, "pub field x is public");
    assert(!c.ast.at_const(f1).as_data.field.is_public, "non-pub field y is private");
    let ext_items = item(&c.ast, 1).as_data.extend_def.items;
    let methods = c.ast.list(ext_items);
    let m0 = unsafe methods[0];
    let m1 = unsafe methods[1];
    assert(c.ast.at_const(m0).as_data.function.is_public, "pub method is public");
    assert(!c.ast.at_const(m1).as_data.function.is_public, "non-pub method is private");
    assert(item(&c.ast, 2).as_data.function.is_public, "pub fn is public");
    assert(!item(&c.ast, 3).as_data.function.is_public, "non-pub fn is private");
    assert(
        item(&c.ast, 4).kind == NodeKind::NODE_ENUM && item(&c.ast, 4).as_data.aggregate.is_public,
        "pub enum is public",
    );
    assert(
        item(&c.ast, 5).kind == NodeKind::NODE_ENUM && !item(&c.ast, 5).as_data.aggregate.is_public,
        "non-pub enum is private",
    );
    assert(
        item(&c.ast, 6).kind == NodeKind::NODE_CONST && item(&c.ast, 6).as_data.const_def.is_public,
        "pub const is public",
    );
    assert(
        item(&c.ast, 7).kind == NodeKind::NODE_CONST && !item(&c.ast, 7).as_data.const_def.is_public,
        "non-pub const is private",
    );
    assert(
        item(&c.ast, 8).kind == NodeKind::NODE_TYPE_ALIAS && item(&c.ast, 8).as_data.type_alias.is_public,
        "pub type is public",
    );
    assert(
        item(&c.ast, 9).kind == NodeKind::NODE_TYPE_ALIAS && !item(&c.ast, 9).as_data.type_alias.is_public,
        "non-pub type is private",
    );
    assert(h::parse_has_error("pub let x: i32 = 1;\n"), "pub before a non-item is rejected");
}

// An untagged `union` parses like a struct (NODE_STRUCT) but is flagged is_union.
// (named `unions`, not `union`, since `union` is a reserved keyword.)
@test
fn unions() {
    {
        let c = h::parse_ast("pub union Bits { pub i: u32, bytes: [u8; 4], }\n");
        assert(c.errors == 0, "union decl parses");
        assert(item(&c.ast, 0).kind == NodeKind::NODE_STRUCT, "union parses as a NODE_STRUCT");
        assert(item(&c.ast, 0).as_data.aggregate.is_union, "union is flagged is_union");
        assert(item(&c.ast, 0).as_data.aggregate.is_public, "pub union is public");
        let members = item(&c.ast, 0).as_data.aggregate.members;
        let fields = c.ast.list(members);
        let f0 = unsafe fields[0];
        let f1 = unsafe fields[1];
        assert(c.ast.at_const(f0).as_data.field.is_public, "pub union field is public");
        assert(!c.ast.at_const(f1).as_data.field.is_public, "non-pub union field is private");
    }
    // A plain struct is not flagged is_union.
    {
        let c = h::parse_ast("struct S { x: i32, }\n");
        assert(c.errors == 0, "struct not union parses");
        assert(!item(&c.ast, 0).as_data.aggregate.is_union, "a struct is not is_union");
    }
}

// `@c.*` attributes parse into the Ast's attribute table; malformed ones are rejected.
@test
fn attributes() {
    let c = h::parse_ast("@c.packed\nstruct H { x: u32, }\n@c.noreturn\n@c.export(\"sym\")\nfn die() {}\n");
    assert(c.errors == 0, "attributes parses");
    assert(c.ast.attrs.len() == 3, "three attributes recorded");
    assert(item(&c.ast, 0).kind == NodeKind::NODE_STRUCT, "attributed struct parses");
    assert(item(&c.ast, 1).kind == NodeKind::NODE_FUNCTION, "attributed fn parses");
    assert(h::parse_has_error("@c.frobnicate\nfn m() {}\n"), "unknown attribute rejected");
    assert(h::parse_has_error("@rust.inline\nfn m() {}\n"), "unknown namespace rejected");
    assert(h::parse_has_error("@c.align\nstruct S { x: i32 }\n"), "align without an argument rejected");
    assert(h::parse_has_error("@c.gnu.attribute(\"hot\")\nfn m() {}\n"), "target-specific namespace rejected");
    assert(h::parse_has_error("@c.inline(3)\nfn m() {}\n"), "no-arg attribute given an argument rejected");
    {
        let recovered = h::parse_ast("@unknown(foo(bar))\nfn m() {}\n");
        assert(recovered.errors != 0, "unknown generic attribute rejected");
        assert(
            recovered.ast.at_const(recovered.ast.root).as_data.program.items.len == 1,
            "balanced unknown attribute arguments do not consume the following item",
        );
    }
}

// Regressions for parser bugs from the cross-stage hunt.
@test
fn bug_regressions() {
    // P1: a comparison after a cast must parse as `(a as i32) < b`, not be eaten as generic type args.
    assert(!h::parse_has_error("fn f(a: i32, b: i32) bool { return a as i32 < b; }\n"), "`a as i32 < b` should parse");
    // P2: deeply nested blocks must hit the depth guard and diagnose, not overflow the stack.
    {
        let mut s = String::new();
        s.push_str("fn main() i32 {");
        let mut i = 0;
        while i < 700 {
            s.push_str("{");
            i = i + 1;
        }
        s.push_str(" return 0; ");
        i = 0;
        while i < 700 {
            s.push_str("}");
            i = i + 1;
        }
        s.push_str("}");
        assert(h::parse_has_error(s.as_str()), "deeply nested blocks should diagnose, not crash");
    }
}

// Pathological FLAT expressions are diagnosed, not stack-overflowed: a left-deep binary chain and a
// right-recursive `=` chain, both capped like parenthesized nesting.
@test
fn pathological_depth() {
    {
        let mut s = String::new();
        s.push_str("fn f() i32 { return 1");
        let mut i = 0;
        while i < 8000 {
            s.push_str(" + 1");
            i = i + 1;
        }
        s.push_str("; }\n");
        assert(h::parse_has_error(s.as_str()), "over-long binary chain is rejected");
    }
    {
        let mut s = String::new();
        s.push_str("fn f() { let mut a: i32 = 0; ");
        let mut i = 0;
        while i < 1000 {
            s.push_str("a = ");
            i = i + 1;
        }
        s.push_str("1; }\n");
        assert(h::parse_has_error(s.as_str()), "over-deep assignment chain is rejected");
    }
}

// Lifetime syntax (`'a`). The lexer already emits `'name` as a Label (loop labels share the surface
// form), so every slot below is a single-token `check(Label)` decision -- the grammar stays LL(1).
// Lifetime params are parsed into a SEPARATE `lifetimes` list so `generics` stays mono-relevant only
// (lifetimes are erased before monomorphization).
@test
fn lifetimes() {
    let src = "struct Ref<'a> { pub p: &'a i32 }\nfn borrow<'a>(x: &'a i32) &'a i32 { return x; }\nfn two<'a, 'b: 'a, T>(x: &'a T, y: &'b mut T) &'a T where T: 'a { return x; }\nfn none(x: &i32) &i32 { return x; }\n";
    let c = h::parse_ast(src);
    assert(c.errors == 0, "lifetime syntax parses");
    assert(c.ast.at_const(c.ast.root).as_data.program.items.len == 4, "lifetimes: expected 4 items");

    // struct Ref<'a>: the lifetime lands in `lifetimes`, NOT in `generics`
    let agg = item(&c.ast, 0).as_data.aggregate;
    let agg_lts = c.ast.lifetimes_of(item_id(&c.ast, 0));
    assert(agg_lts.len == 1, "struct lifetime param recorded");
    assert(agg.generics.len == 0, "struct lifetime is NOT a generic param (erasure is structural)");
    let ltp = c.ast.at_const(unsafe c.ast.list(agg_lts)[0]);
    assert(ltp.as_data.generic_param.is_lifetime, "param flagged is_lifetime");

    // the field's `&'a i32` carries the annotation on the reference type node
    let fields = agg.members;
    let fty = c.ast.at_const(unsafe c.ast.list(fields)[0]).as_data.field.ty;
    assert(c.ast.at_const(fty).kind == NodeKind::NODE_REFERENCE_TYPE, "field is a reference type");
    assert(c.ast.at_const(fty).as_data.indirect_type.lifetime != NODE_NONE, "&'a T records its lifetime");

    // fn borrow<'a>(..) -> &'a i32
    let f1 = item(&c.ast, 1).as_data.function;
    assert(c.ast.lifetimes_of(item_id(&c.ast, 1)).len == 1, "fn lifetime param recorded");
    assert(f1.generics.len == 0, "fn lifetime is not a generic param");

    // fn two<'a, 'b: 'a, T>: two lifetimes (one with an outlives bound) + one real type param
    let f2 = item(&c.ast, 2).as_data.function;
    let f2_lts = c.ast.lifetimes_of(item_id(&c.ast, 2));
    assert(f2_lts.len == 2, "two lifetime params");
    assert(f2.generics.len == 1, "T stays the only generic param");
    let lt_b = c.ast.at_const(unsafe c.ast.list(f2_lts)[1]);
    assert(lt_b.as_data.generic_param.bounds.len == 1, "'b: 'a outlives bound recorded");
    assert(f2.where_clause.len == 1, "where T: 'a recorded");

    // an elided reference keeps lifetime == NODE_NONE
    let f3 = item(&c.ast, 3).as_data.function;
    let p0 = c.ast.at_const(unsafe c.ast.list(f3.params)[0]).as_data.parameter.ty;
    assert(c.ast.at_const(p0).as_data.indirect_type.lifetime == NODE_NONE, "elided reference has no lifetime");

    // lifetime ARGUMENTS at a use site, and lifetimes-before-types is enforced
    assert(
        !h::parse_has_error(
            "struct S<'a> { pub p: &'a i32 }\nfn f() i32 { let v = 1; let s = S::<'a> { p: &v }; return *s.p; }\n",
        ),
        "lifetime argument parses",
    );
    assert(h::parse_has_error("fn f<T, 'a>(x: &'a T) {}\n"), "lifetime params must precede type params");
}

// The grammar batch: a higher-ranked bound `for<'a>` and a lifetime-parameterised associated type.
// Both store their lifetimes in the same side table as a declared `<'a>`, and both wrap them in
// NODE_GENERIC_PARAM so every consumer -- side table, checker, formatter -- sees one shape.
@test
fn hrtb_and_gat() {
    let src = "fn apply<F: for<'a> fn(&'a i32) i32>(f: F) i32 { return 0; }\ninterface Lend { type Item<'a>; }\n";
    let c = h::parse_ast(src);
    assert(c.errors == 0, "for<'a> and type Item<'a> parse");

    // the bound's lifetimes hang off the BOUND node, not the enclosing function
    let fnd = item(&c.ast, 0).as_data.function;
    let gp = c.ast.at_const(unsafe c.ast.list(fnd.generics)[0]).as_data.generic_param;
    let bound = unsafe c.ast.list(gp.bounds)[0];
    let hr = c.ast.lifetimes_of(bound);
    assert(hr.len == 1, "higher-ranked lifetime recorded on the bound");
    assert(c.ast.at_const(unsafe c.ast.list(hr)[0]).as_data.generic_param.is_lifetime, "hrtb param flagged is_lifetime");
    assert(c.ast.lifetimes_of(item_id(&c.ast, 0)).len == 0, "the function itself declares no lifetime");

    // the associated type carries its own lifetime param
    let items = item(&c.ast, 1).as_data.interface_def.items;
    let assoc = unsafe c.ast.list(items)[0];
    assert(c.ast.at_const(assoc).kind == NodeKind::NODE_TYPE_ALIAS, "assoc type is a type alias");
    assert(c.ast.lifetimes_of(assoc).len == 1, "GAT lifetime param recorded");
}
