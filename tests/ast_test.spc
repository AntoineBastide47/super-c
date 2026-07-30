// Self-hosted port of tests/ast_test.c: the node arena, the scratch-stack NodeList builder, and the type
// interner of ast::ast. Part of the selfhost/tests suite.
import ast::ast as *;

@test
fn arena() {
    let mut a = Ast::new(8);
    assert_eq(a.nodes.len(), 1); // node 0 is pre-seeded
    assert(a.at_const(NODE_NONE).kind == NodeKind::NODE_NONE_KIND, "node 0 is NODE_NONE_KIND");
    let n1 = a.add(Node { kind: NodeKind::NODE_IDENTIFIER });
    let n2 = a.add(Node { kind: NodeKind::NODE_LITERAL });
    assert(n1 == 1 && n2 == 2, "add returns increasing ids");
    assert(a.at_const(n2).kind == NodeKind::NODE_LITERAL, "node payload stored");
}

@test
fn scratch_lists() {
    let mut a = Ast::new(8);
    let id0 = a.add(Node { kind: NodeKind::NODE_NONE_KIND });
    let id1 = a.add(Node { kind: NodeKind::NODE_NONE_KIND });
    let id2 = a.add(Node { kind: NodeKind::NODE_NONE_KIND });
    let id3 = a.add(Node { kind: NodeKind::NODE_NONE_KIND });
    // Nested mark/commit: an inner list completes while the outer is still being built.
    let outer = a.mark();
    a.push(id0);
    a.push(id1);
    let inner = a.mark();
    a.push(id2);
    a.push(id3);
    let li = a.commit(inner);
    assert_eq(li.len, 2);
    assert(unsafe a.list(li)[0] == id2 && unsafe a.list(li)[1] == id3, "inner list contents");
    let lo = a.commit(outer);
    assert_eq(lo.len, 2);
    assert(unsafe a.list(lo)[0] == id0 && unsafe a.list(lo)[1] == id1, "outer list contents");
    assert_eq(a.scratch.len(), 0); // scratch fully drained after commits
}

@test
fn interner() {
    let mut a = Ast::new(8);
    let _ = a.add(Node { kind: NodeKind::NODE_IDENTIFIER });
    a.init_types();
    assert_eq(sizeof(Ty), 16); // the concreteness cache occupies padding, not a larger Ty
    assert(a.type_at(TYPE_NONE).kind == TypeKind::TYPE_ERROR, "slot 0 is TYPE_ERROR");
    assert_eq(Ast::builtin(BuiltinType::BT_I32), BuiltinType::BT_I32 as TypeId + 1);
    assert(a.type_at(Ast::builtin(BuiltinType::BT_I32)).kind == TypeKind::TYPE_BUILTIN, "builtin slot kind");
    let pc = Ty {
        kind: TypeKind::TYPE_POINTER,
        qualifier: TypeQualifier::TYPE_QUAL_CONST as u8,
        module: 0,
        as_data: TyAs { elem: Ast::builtin(BuiltinType::BT_I32) },
    };
    let pm = Ty {
        kind: TypeKind::TYPE_POINTER,
        qualifier: TypeQualifier::TYPE_QUAL_MUT as u8,
        module: 0,
        as_data: TyAs { elem: Ast::builtin(BuiltinType::BT_I32) },
    };
    let a1 = a.intern_type(pc);
    let a2 = a.intern_type(pc);
    let b1 = a.intern_type(pm);
    let g = a.intern_type(Ty { kind: TypeKind::TYPE_GENERIC, module: 0, as_data: TyAs { decl: 1 } });
    let pg = a.intern_type(Ty { kind: TypeKind::TYPE_POINTER, as_data: TyAs { elem: g } });
    assert(a1 == a2, "identical Ty interns to one id");
    assert(a1 != b1, "differing qualifier interns distinctly");
    assert(a.type_concrete(a1) && !a.type_concrete(g) && !a.type_concrete(pg), "concreteness is cached recursively");
}
