// Direct coverage of ast/ast.c: the node arena, the scratch-stack NodeList builder, the type
// interner, and the resolution/type side tables. (ast_fprint is NDEBUG-only -> ast_fprint_rtest.c.)

#include "test_harness.h"

static void test_arena(void) {
  Ast *a = ast_new(8);
  CHECK(a->nodes.len == 1, "node 0 is pre-seeded");
  CHECK(ast_at_const(a, NODE_NONE)->kind == NODE_NONE_KIND, "node 0 is NODE_NONE_KIND");

  const NodeId n1 = ast_add(a, (Node){.kind = NODE_IDENTIFIER});
  const NodeId n2 = ast_add(a, (Node){.kind = NODE_LITERAL});
  CHECK(n1 == 1 && n2 == 2, "ast_add returns increasing ids (%u, %u)", n1, n2);
  CHECK(ast_at(a, n2)->kind == NODE_LITERAL, "node payload stored");
  ast_free(&a);
  CHECK(a == NULL, "ast_free nulls the handle");
}

static void test_scratch_lists(void) {
  Ast *a = ast_new(8);
  const NodeId ids[4] = {ast_add(a, (Node){0}), ast_add(a, (Node){0}), ast_add(a, (Node){0}), ast_add(a, (Node){0})};

  // Nested mark/commit: an inner list completes while the outer is still being built.
  const uint32_t outer = ast_mark(a);
  ast_push(a, ids[0]);
  ast_push(a, ids[1]);
  const uint32_t inner = ast_mark(a);
  ast_push(a, ids[2]);
  ast_push(a, ids[3]);
  const NodeList li = ast_commit(a, inner);
  CHECK(li.len == 2, "inner list has 2 entries");
  CHECK(ast_list(a, li)[0] == ids[2] && ast_list(a, li)[1] == ids[3], "inner list contents");
  const NodeList lo = ast_commit(a, outer);
  CHECK(lo.len == 2, "outer list has 2 entries (scratch popped to its mark)");
  CHECK(ast_list(a, lo)[0] == ids[0] && ast_list(a, lo)[1] == ids[1], "outer list contents");
  CHECK(a->scratch.len == 0, "scratch fully drained after commits");
  ast_free(&a);
}

static void test_interner(void) {
  Ast *a = ast_new(8);
  ast_add(a, (Node){.kind = NODE_IDENTIFIER});
  ast_init_types(a);

  CHECK(ast_type_at(a, TYPE_NONE)->kind == TYPE_ERROR, "slot 0 is TYPE_ERROR");
  CHECK(ast_builtin(BT_I32) == (TypeId)BT_I32 + 1, "builtin id is index+1");
  CHECK(ast_type_at(a, ast_builtin(BT_I32))->kind == TYPE_BUILTIN, "builtin slot kind");
  CHECK(ast_type_at(a, ast_builtin(BT_I32))->as.builtin == BT_I32, "builtin slot payload");

  const Ty pc = {.kind = TYPE_POINTER, .qualifier = TYPE_QUAL_CONST, .as.elem = ast_builtin(BT_I32)};
  const Ty pm = {.kind = TYPE_POINTER, .qualifier = TYPE_QUAL_MUT, .as.elem = ast_builtin(BT_I32)};
  const TypeId a1 = ast_intern_type(a, pc);
  const TypeId a2 = ast_intern_type(a, pc);
  const TypeId b1 = ast_intern_type(a, pm);
  CHECK(a1 == a2, "identical Ty interns to one id");
  CHECK(a1 != b1, "differing qualifier interns distinctly");
  CHECK(a1 > BT_COUNT, "fresh type lands past the builtins");

  const Ty bool_ty = {.kind = TYPE_BUILTIN, .as.builtin = BT_BOOL};
  CHECK(ast_intern_type(a, bool_ty) == ast_builtin(BT_BOOL), "interning a builtin returns its seeded id");
  ast_free(&a);
}

static void test_side_tables(void) {
  Ast *a = ast_new(8);
  const NodeId ref = ast_add(a, (Node){.kind = NODE_IDENTIFIER});
  const NodeId decl = ast_add(a, (Node){.kind = NODE_LET});

  ast_init_resolutions(a);
  CHECK(a->resolutions.len == a->nodes.len, "resolutions sized to node count");
  CHECK(ast_resolution(a, ref) == NODE_NONE, "resolutions zero-filled");
  ast_set_resolution(a, ref, decl);
  CHECK(ast_resolution(a, ref) == decl, "resolution round-trip");

  ast_init_types(a);
  CHECK(a->types.len == a->nodes.len, "types sized to node count");
  CHECK(ast_type(a, ref) == TYPE_NONE, "types zero-filled");
  ast_set_type(a, ref, ast_builtin(BT_U8));
  CHECK(ast_type(a, ref) == ast_builtin(BT_U8), "type round-trip");

  ast_init_types(a); // idempotent re-seed must not corrupt the pool
  CHECK(ast_type_at(a, ast_builtin(BT_U8))->as.builtin == BT_U8, "builtins intact after re-seed");
  CHECK(ast_type(a, ref) == TYPE_NONE, "re-seed clears the type table");
  ast_free(&a);
}

int main(void) {
  test_arena();
  test_scratch_lists();
  test_interner();
  test_side_tables();
  if (failures) {
    fprintf(stderr, "%d ast test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("ast tests passed");
  return 0;
}
