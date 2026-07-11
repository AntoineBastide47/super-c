// Self-hosted port of tests/resolver_test.c: name resolution -- forward refs, shadowing, generics/Self,
// loop/match/let scopes; resolution TARGETS (nearest-shadow wins, value/type namespaces independent);
// undefined-name / duplicate-definition diagnostics; and closure capture collection. Drives the real
// resolver in-process through tests/harness (compile / compile_ast).
import ast::ast as *;
import tests::harness as h;

@test
fn resolves() {
    h::expect_resolve_ok(
        "forward references",
        "fn use_it(p: Pair) void { make(p); }\nfn make(p: Pair) void {}\nstruct Pair { left: i32, right: i32, }\n",
    );
    h::expect_resolve_ok(
        "nested shadowing",
        "fn f() void {\n  let x: i32 = 1;\n  { let x: i32 = 2; g(x); }\n  g(x);\n}\nfn g(n: i32) void {}\n",
    );
    h::expect_resolve_ok(
        "generics self and Self",
        "struct Wrap<T> { value: T, }\ninterface Show { fn show(self: u8) void; }\nextend<T> Wrap<T> { fn get(self: Self) T { return self.value; } }\n",
    );
    h::expect_resolve_ok(
        "loop match and let scopes",
        "struct List {}\nfn each(items: List) void { for x in items { take(x); } }\nfn classify(c: u8) i32 { return switch c { 0 => 1, n => n, _ => 0, }; }\nfn take(n: i32) void {}\n",
    );
}

@test
fn errors() {
    h::expect_resolve_err_msg("undefined value", "fn main() i32 { bar(); }\n", "cannot find value 'bar'");
    h::expect_resolve_err_msg("undefined type", "fn f(x: Widget) void {}\n", "cannot find type 'Widget'");
    h::expect_resolve_err_msg("duplicate item", "struct P {}\nstruct P {}\n", "duplicate definition of 'P'");
    h::expect_resolve_err_msg("duplicate parameter", "fn f(a: i32, a: i32) void {}\n", "duplicate definition of 'a'");
    h::expect_resolve_err_msg(
        "duplicate let",
        "fn f() void { let x: i32 = 1; let x: i32 = 2; }\n",
        "duplicate definition of 'x'",
    );
    h::expect_resolve_err_msg(
        "local escapes its block",
        "fn f() void { { let x: i32 = 1; } use_x(x); }\nfn use_x(n: i32) void {}\n",
        "cannot find value 'x'",
    );
    h::expect_resolve_err_msg("Self outside extend", "fn f(x: Self) void {}\n", "'Self' is only valid");
}

// Collect all NODE_IDENTIFIER value-uses named `name` that the resolver bound, in creation order.
fn value_uses(a: &Ast, src: *const char, name: *const char, out: *mut NodeId, cap: usize) usize {
    let mut n: usize = 0;
    let mut id: NodeId = 1;
    while id as usize < a.nodes.len() {
        if h::ident_is(&*a, src, id, name) && a.resolution(id) != NODE_NONE && n < cap {
            unsafe out[n] = id;
            n = n + 1;
        }
        id = id + 1;
    }
    return n;
}

// Two uses of `x` bind to the two different `let x` decls: inner use to the inner let, outer to the outer.
@test
fn nearest_shadow() {
    let src = "fn g(n: i32) void {}\nfn f() void {\n  let x: i32 = 1;\n  { let x: i32 = 2; g(x); }\n  g(x);\n}\n";
    let mut c = h::compile_ast(src, h::STAGE_RESOLVE);
    assert(c.errors == 0, "resolves cleanly");
    let outer_let = h::nth_kind(&c.ast, NodeKind::NODE_LET, 0); // created first
    let inner_let = h::nth_kind(&c.ast, NodeKind::NODE_LET, 1);
    let mut uses: [NodeId; 4] = [0 as NodeId, 0 as NodeId, 0 as NodeId, 0 as NodeId];
    let n = value_uses(&c.ast, src.ptr() as *const char, "x".ptr() as *const char, (&mut uses[0]) as *mut NodeId, 4);
    assert_eq(n, 2);
    assert(c.ast.resolution(uses[0]) == inner_let, "inner g(x) binds to the inner let");
    assert(c.ast.resolution(uses[1]) == outer_let, "outer g(x) binds to the outer let");
    assert(inner_let != outer_let, "the two lets are distinct declarations");
    c.ast.free();
}

// The same spelling in the value and type namespaces resolves to different decls.
@test
fn namespace_separation() {
    let src = "struct Foo {}\nconst Foo: i32 = 5;\nfn main() i32 { let x: Foo = Foo; }\n";
    let mut c = h::compile_ast(src, h::STAGE_RESOLVE);
    assert(c.errors == 0, "resolves cleanly");
    let struct_decl = h::nth_kind(&c.ast, NodeKind::NODE_STRUCT, 0);
    let const_decl = h::nth_kind(&c.ast, NodeKind::NODE_CONST, 0);
    let mut uses: [NodeId; 4] = [0 as NodeId, 0 as NodeId, 0 as NodeId, 0 as NodeId];
    let n = value_uses(&c.ast, src.ptr() as *const char, "Foo".ptr() as *const char, (&mut uses[0]) as *mut NodeId, 4);
    assert_eq(n, 1); // the value use is the let initializer
    assert(c.ast.resolution(uses[0]) == const_decl, "value Foo binds to the const, not the struct");
    // The type use is the `: Foo` annotation, resolved on the NODE_TYPE_PATH.
    let mut type_path: NodeId = NODE_NONE;
    let mut id: NodeId = 1;
    while id as usize < c.ast.nodes.len() {
        if c.ast.at_const(id).kind == NodeKind::NODE_TYPE_PATH && c.ast.resolution(id) != NODE_NONE {
            type_path = id;
        }
        id = id + 1;
    }
    assert(type_path != NODE_NONE && c.ast.resolution(type_path) == struct_decl, "type Foo binds to the struct");
    c.ast.free();
}

// The capture count of each closure, in node order (inner closures complete first).
fn closure_captures(src: str, out: *mut u32, cap: usize) usize {
    let mut c = h::compile_ast(src, h::STAGE_RESOLVE);
    let mut n: usize = 0;
    let mut id: NodeId = 1;
    while id as usize < c.ast.nodes.len() {
        if c.ast.at_const(id).kind == NodeKind::NODE_CLOSURE && n < cap {
            unsafe out[n] = c.ast.at_const(id).as_data.closure.captures.len;
            n = n + 1;
        }
        id = id + 1;
    }
    c.ast.free();
    return n;
}

@test
fn closures() {
    let mut caps: [u32; 4] = [0u32, 0u32, 0u32, 0u32];
    // Params / module-level items are not captures.
    let mut n = closure_captures(
        "const K: i32 = 3;\nfn helper(n: i32) i32 { return n; }\nfn main() i32 { let f = |x: i32| helper(x) + K; return f(1); }\n",
        (&mut caps[0]) as *mut u32,
        4,
    );
    assert(n == 1 && caps[0] == 0, "params/module items are not captures");
    // Referencing an outer local is a capture (deduped: `base` twice is one).
    n = closure_captures(
        "fn main() i32 { let base = 10; let f = |x: i32| x + base + base; return f(1); }\n",
        (&mut caps[0]) as *mut u32,
        4,
    );
    assert(n == 1 && caps[0] == 1, "one deduped capture expected");
    n = closure_captures(
        "fn add(b: i32, c: i32) i32 { let f = |x: i32| x + b + c; return f(1); }\n",
        (&mut caps[0]) as *mut u32,
        4,
    );
    assert(n == 1 && caps[0] == 2, "two captures expected");
    // A nested closure captures through the outer one: both collect it.
    n = closure_captures(
        "fn main() i32 {\n  let base = 10;\n  let outer = fn(x: i32) i32 { let inner = |y: i32| y + base; return inner(x); };\n  return outer(1);\n}\n",
        (&mut caps[0]) as *mut u32,
        4,
    );
    assert(n == 2 && caps[0] == 1 && caps[1] == 1, "both closures capture 'base'");
}
