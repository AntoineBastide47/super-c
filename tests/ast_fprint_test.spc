// Self-hosted port of tests/ast_fprint_rtest.c: coverage of the AST pretty-printer (src/ast/ast.c's
// ast_fprint, an NDEBUG debug dump). The printer is ported here (its only consumer is this test -- a debug
// tool, kept out of the core ast.spc so the compiler's own build is untouched) and driven over a parsed
// function, asserting the dump names each node kind, renders identifier text from the source span, prints
// the operator name for binary nodes, and prints node spans as [start..end].
import tests::harness as h;
import ast::ast as ast;
import lexer::token_type as tt;
import stdio;
import stdlib;
import string as cstring;

// `tmpfile` (an anonymous, auto-removed temp stream) rides in <stdio.h>, always in super_rt.
extern "C" {
    fn tmpfile() *mut stdio::FILE;
}

// The display name for a node kind (mirrors ast.c's kind_name names[]).
fn kind_name(k: ast::NodeKind) str<'static> {
    return switch k {
        NODE_NONE_KIND => "None",
        NODE_PROGRAM => "Program",
        NODE_IDENTIFIER => "Identifier",
        NODE_LITERAL => "Literal",
        NODE_FUNCTION => "Function",
        NODE_PARAMETER => "Parameter",
        NODE_STRUCT => "Struct",
        NODE_FIELD => "Field",
        NODE_ENUM => "Enum",
        NODE_VARIANT => "Variant",
        NODE_INTERFACE => "Interface",
        NODE_EXTEND => "Extend",
        NODE_TYPE_ALIAS => "TypeAlias",
        NODE_CONST => "Const",
        NODE_STATIC_ASSERT => "StaticAssert",
        NODE_EXTERN_BLOCK => "ExternBlock",
        NODE_IMPORT => "Import",
        NODE_GENERIC_PARAM => "GenericParam",
        NODE_WHERE_PREDICATE => "WherePredicate",
        NODE_TYPE_PATH => "TypePath",
        NODE_POINTER_TYPE => "PointerType",
        NODE_REFERENCE_TYPE => "ReferenceType",
        NODE_SLICE_TYPE => "SliceType",
        NODE_ARRAY_TYPE => "ArrayType",
        NODE_FUNCTION_TYPE => "FunctionType",
        NODE_DYN_TYPE => "DynType",
        NODE_BLOCK => "Block",
        NODE_LET => "Let",
        NODE_RETURN => "Return",
        NODE_BREAK => "Break",
        NODE_CONTINUE => "Continue",
        NODE_DEFER => "Defer",
        NODE_IF => "If",
        NODE_WHILE => "While",
        NODE_FOR => "For",
        NODE_EXPRESSION_STATEMENT => "ExpressionStatement",
        NODE_UNARY => "Unary",
        NODE_BINARY => "Binary",
        NODE_ASSIGNMENT => "Assignment",
        NODE_CALL => "Call",
        NODE_CLOSURE => "Closure",
        NODE_INDEX => "Index",
        NODE_MEMBER => "Member",
        NODE_CAST => "Cast",
        NODE_GENERIC_SPECIALIZATION => "GenericSpecialization",
        NODE_MATCH => "Match",
        NODE_MATCH_ARM => "MatchArm",
        NODE_NEW => "New",
        NODE_SIZEOF => "Sizeof",
        NODE_ALIGNOF => "Alignof",
        NODE_VA_EXPR => "VaExpr",
        NODE_ARRAY_LITERAL => "ArrayLiteral",
        NODE_STRUCT_INITIALIZER => "StructInitializer",
        NODE_FIELD_INITIALIZER => "FieldInitializer",
        NODE_PATTERN_WILDCARD => "PatternWildcard",
        NODE_PATTERN_LITERAL => "PatternLiteral",
        NODE_PATTERN_NAME => "PatternName",
        NODE_PATTERN_TUPLE => "PatternTuple",
        NODE_PATTERN_STRUCT => "PatternStruct",
        NODE_PATTERN_FIELD => "PatternField",
        NODE_PATTERN_RANGE => "PatternRange",
        NODE_PATTERN_OR => "PatternOr",
        NODE_RANGE => "Range",
        NODE_TUPLE => "Tuple",
        NODE_TUPLE_TYPE => "TupleType",
        _ => "Invalid",
    };
}

fn indent(out: *mut stdio::FILE, depth: u32) {
    for i in 0..depth {
        unsafe stdio::fputs("  ".ptr() as *const char, out);
    }
}

fn print_list(out: *mut stdio::FILE, a: &ast::Ast, list: ast::NodeList, source: *const char, depth: u32) {
    let ids = a.list(list);
    for i in 0..list.len {
        print_node(out, a, unsafe ids[i as usize], source, depth);
    }
}

fn print_child(out: *mut stdio::FILE, a: &ast::Ast, id: ast::NodeId, source: *const char, depth: u32) {
    if id != ast::NODE_NONE {
        print_node(out, a, id, source, depth);
    }
}

fn print_node(out: *mut stdio::FILE, a: &ast::Ast, id: ast::NodeId, source: *const char, depth: u32) {
    let n = *a.at_const(id);
    indent(out, depth);
    unsafe stdio::fprintf(out, "%s".ptr() as *const char, kind_name(n.kind).ptr() as *const char);
    if n.kind == ast::NodeKind::NODE_IDENTIFIER {
        let t = n.as_data.name.text;
        unsafe stdio::fprintf(
            out,
            " `%.*s`".ptr() as *const char,
            (t.end - t.start) as i32,
            unsafe (source + t.start as usize),
        );
    } else if n.kind == ast::NodeKind::NODE_LITERAL {
        let r = n.as_data.literal.raw;
        unsafe stdio::fprintf(
            out,
            " %.*s".ptr() as *const char,
            (r.end - r.start) as i32,
            unsafe (source + r.start as usize),
        );
    } else if n.kind == ast::NodeKind::NODE_UNARY {
        unsafe stdio::fprintf(out, " %s".ptr() as *const char, n.as_data.unary.op.name().ptr() as *const char);
    } else if n.kind == ast::NodeKind::NODE_BINARY || n.kind == ast::NodeKind::NODE_ASSIGNMENT {
        unsafe stdio::fprintf(out, " %s".ptr() as *const char, n.as_data.binary.op.name().ptr() as *const char);
    }
    unsafe stdio::fprintf(out, " [%u..%u]\n".ptr() as *const char, n.span.start, n.span.end);
    let d = depth + 1;
    switch n.kind {
        NODE_PROGRAM => {
            print_list(out, a, n.as_data.program.items, source, d);
        },
        NODE_FUNCTION => {
            print_child(out, a, n.as_data.function.name, source, d);
            print_list(out, a, n.as_data.function.generics, source, d);
            print_list(out, a, n.as_data.function.params, source, d);
            print_list(out, a, n.as_data.function.returns, source, d);
            print_list(out, a, n.as_data.function.where_clause, source, d);
            print_child(out, a, n.as_data.function.body, source, d);
        },
        NODE_PARAMETER => {
            print_child(out, a, n.as_data.parameter.name, source, d);
            print_child(out, a, n.as_data.parameter.ty, source, d);
        },
        NODE_FIELD => {
            print_child(out, a, n.as_data.field.name, source, d);
            print_child(out, a, n.as_data.field.ty, source, d);
            print_child(out, a, n.as_data.field.value, source, d);
        },
        NODE_STRUCT | NODE_ENUM => {
            print_child(out, a, n.as_data.aggregate.name, source, d);
            print_list(out, a, n.as_data.aggregate.generics, source, d);
            print_list(out, a, n.as_data.aggregate.members, source, d);
        },
        NODE_VARIANT => {
            print_child(out, a, n.as_data.variant.name, source, d);
            print_list(out, a, n.as_data.variant.payload, source, d);
        },
        NODE_INTERFACE => {
            print_child(out, a, n.as_data.interface_def.name, source, d);
            print_list(out, a, n.as_data.interface_def.generics, source, d);
            print_list(out, a, n.as_data.interface_def.bounds, source, d);
            print_list(out, a, n.as_data.interface_def.items, source, d);
        },
        NODE_EXTEND => {
            print_list(out, a, n.as_data.extend_def.generics, source, d);
            print_child(out, a, n.as_data.extend_def.interface_type, source, d);
            print_child(out, a, n.as_data.extend_def.target_type, source, d);
            print_list(out, a, n.as_data.extend_def.items, source, d);
        },
        NODE_TYPE_ALIAS => {
            print_child(out, a, n.as_data.type_alias.name, source, d);
            print_list(out, a, n.as_data.type_alias.generics, source, d);
            print_child(out, a, n.as_data.type_alias.ty, source, d);
        },
        NODE_CONST => {
            print_child(out, a, n.as_data.const_def.name, source, d);
            print_child(out, a, n.as_data.const_def.ty, source, d);
            print_child(out, a, n.as_data.const_def.value, source, d);
        },
        NODE_EXTERN_BLOCK => {
            print_child(out, a, n.as_data.extern_block.abi, source, d);
            print_list(out, a, n.as_data.extern_block.items, source, d);
        },
        NODE_IMPORT => {
            print_list(out, a, n.as_data.import_decl.path, source, d);
            print_child(out, a, n.as_data.import_decl.alias, source, d);
        },
        NODE_GENERIC_PARAM => {
            print_child(out, a, n.as_data.generic_param.name, source, d);
            print_list(out, a, n.as_data.generic_param.bounds, source, d);
            print_child(out, a, n.as_data.generic_param.default_type, source, d);
        },
        NODE_WHERE_PREDICATE => {
            print_child(out, a, n.as_data.where_predicate.ty, source, d);
            print_list(out, a, n.as_data.where_predicate.bounds, source, d);
        },
        NODE_TYPE_PATH => {
            print_list(out, a, n.as_data.type_path.parts, source, d);
            print_list(out, a, n.as_data.type_path.args, source, d);
        },
        NODE_POINTER_TYPE | NODE_REFERENCE_TYPE | NODE_SLICE_TYPE | NODE_DYN_TYPE => {
            print_child(out, a, n.as_data.indirect_type.ty, source, d);
        },
        NODE_ARRAY_TYPE => {
            print_child(out, a, n.as_data.array_type.element, source, d);
            print_child(out, a, n.as_data.array_type.length, source, d);
        },
        NODE_FUNCTION_TYPE => {
            print_list(out, a, n.as_data.function_type.params, source, d);
            print_list(out, a, n.as_data.function_type.returns, source, d);
        },
        NODE_BLOCK => {
            print_list(out, a, n.as_data.block.statements, source, d);
        },
        NODE_LET => {
            print_child(out, a, n.as_data.let_stmt.name, source, d);
            print_child(out, a, n.as_data.let_stmt.ty, source, d);
            print_child(out, a, n.as_data.let_stmt.value, source, d);
        },
        NODE_RETURN => {
            print_list(out, a, n.as_data.return_stmt.values, source, d);
        },
        NODE_DEFER | NODE_EXPRESSION_STATEMENT => {
            print_child(out, a, n.as_data.single.value, source, d);
        },
        NODE_IF => {
            print_child(out, a, n.as_data.if_stmt.condition, source, d);
            print_child(out, a, n.as_data.if_stmt.then_branch, source, d);
            print_child(out, a, n.as_data.if_stmt.else_branch, source, d);
        },
        NODE_WHILE => {
            print_child(out, a, n.as_data.while_stmt.condition, source, d);
            print_child(out, a, n.as_data.while_stmt.body, source, d);
        },
        NODE_FOR => {
            print_child(out, a, n.as_data.for_stmt.binding, source, d);
            print_child(out, a, n.as_data.for_stmt.iterable, source, d);
            print_child(out, a, n.as_data.for_stmt.body, source, d);
        },
        NODE_UNARY => {
            print_child(out, a, n.as_data.unary.operand, source, d);
        },
        NODE_BINARY | NODE_ASSIGNMENT | NODE_STATIC_ASSERT => {
            print_child(out, a, n.as_data.binary.left, source, d);
            print_child(out, a, n.as_data.binary.right, source, d);
        },
        NODE_CALL => {
            print_child(out, a, n.as_data.call.callee, source, d);
            print_list(out, a, n.as_data.call.args, source, d);
        },
        NODE_CLOSURE => {
            print_list(out, a, n.as_data.closure.params, source, d);
            print_list(out, a, n.as_data.closure.returns, source, d);
            print_child(out, a, n.as_data.closure.body, source, d);
        },
        NODE_INDEX => {
            print_child(out, a, n.as_data.index.object, source, d);
            print_child(out, a, n.as_data.index.index, source, d);
        },
        NODE_MEMBER => {
            print_child(out, a, n.as_data.member.object, source, d);
            print_child(out, a, n.as_data.member.member, source, d);
        },
        NODE_CAST => {
            print_child(out, a, n.as_data.cast.expression, source, d);
            print_child(out, a, n.as_data.cast.ty, source, d);
        },
        NODE_GENERIC_SPECIALIZATION => {
            print_child(out, a, n.as_data.specialization.expression, source, d);
            print_list(out, a, n.as_data.specialization.types, source, d);
        },
        NODE_MATCH => {
            print_child(out, a, n.as_data.match_expr.value, source, d);
            print_list(out, a, n.as_data.match_expr.arms, source, d);
        },
        NODE_MATCH_ARM => {
            print_child(out, a, n.as_data.match_arm.pattern, source, d);
            print_child(out, a, n.as_data.match_arm.guard, source, d);
            print_child(out, a, n.as_data.match_arm.body, source, d);
        },
        NODE_NEW => {
            print_child(out, a, n.as_data.new_expr.ty, source, d);
            print_child(out, a, n.as_data.new_expr.initializer, source, d);
        },
        NODE_VA_EXPR => {
            print_child(out, a, n.as_data.va_op.ap, source, d);
            print_child(out, a, n.as_data.va_op.extra, source, d);
        },
        NODE_ARRAY_LITERAL | NODE_TUPLE | NODE_TUPLE_TYPE => {
            print_list(out, a, n.as_data.array_literal.elements, source, d);
        },
        NODE_STRUCT_INITIALIZER => {
            print_child(out, a, n.as_data.struct_initializer.ty, source, d);
            print_list(out, a, n.as_data.struct_initializer.fields, source, d);
        },
        NODE_FIELD_INITIALIZER => {
            print_child(out, a, n.as_data.field_initializer.name, source, d);
            print_child(out, a, n.as_data.field_initializer.value, source, d);
        },
        NODE_PATTERN_NAME | NODE_PATTERN_TUPLE | NODE_PATTERN_STRUCT | NODE_PATTERN_FIELD | NODE_PATTERN_OR => {
            print_child(out, a, n.as_data.pattern.name, source, d);
            print_list(out, a, n.as_data.pattern.children, source, d);
        },
        NODE_PATTERN_RANGE | NODE_RANGE => {
            print_child(out, a, n.as_data.pattern_range.start, source, d);
            print_child(out, a, n.as_data.pattern_range.end, source, d);
        },
        _ => {},
    };
}

// Dump the AST rooted at `a.root` to `out` (the analog of ast.c's ast_fprint).
fn ast_fprint(out: *mut stdio::FILE, a: &ast::Ast, source: *const char) {
    if a.root != ast::NODE_NONE {
        print_node(out, a, a.root, source, 0);
    }
}

// Read a whole stream into a fresh NUL-terminated heap buffer (caller frees).
fn read_stream(f: *mut stdio::FILE) *mut char {
    unsafe stdio::fflush(f);
    let _ = unsafe stdio::fseek(f, 0, stdio::SEEK_END);
    let sz = unsafe stdio::ftell(f);
    if sz < 0 {
        return null;
    }
    unsafe stdio::rewind(f);
    let buf = (unsafe stdlib::malloc(sz as usize + 1)) as *mut char;
    if buf == null {
        return null;
    }
    let got = unsafe stdio::fread(buf, 1, sz as usize, f);
    unsafe buf[got] = 0 as char;
    return buf;
}

fn has(buf: *mut char, needle: str) bool {
    return unsafe cstring::strstr(buf, needle.ptr() as *const char) != null;
}

@test
fn dump() {
    let src = "fn add(a: i32, b: i32) i32 { return a + b; }\n";
    let pr = h::parse_ast(src);
    assert(pr.errors == 0, "clean parse");
    let f = unsafe tmpfile();
    assert(f != null, "tmpfile");
    ast_fprint(f, &pr.ast, src.ptr() as *const char);
    let buf = read_stream(f);
    unsafe stdio::fclose(f);
    assert(buf != null, "captured dump");
    assert(has(buf, "Program"), "dump names the program");
    assert(has(buf, "Function"), "dump names the function");
    assert(has(buf, "Identifier `add`"), "identifier text rendered from the source span");
    assert(has(buf, "Identifier `a`"), "parameter identifier rendered");
    assert(has(buf, "Parameter"), "dump names parameters");
    assert(has(buf, "Return"), "dump names the return");
    assert(has(buf, "Binary Plus"), "operator name printed for binary nodes");
    assert(has(buf, ".."), "node spans printed as [start..end]");
    unsafe stdlib::free(buf);
}
