// The desugar pass: lowers "sugar keyword" marker nodes into core-language nodes, after resolve and before
// typecheck. A sugar node is produced only by the parser, printed only by the formatter, and eliminated
// here -- typecheck, borrowck, consteval, codegen and lint never see one. Adding a sugar keyword is then a
// lexer token, a parser marker, one lowering entry here, and a formatter arm; the rest of the compiler stays
// unaware of it.
//
// The reusable primitive is `lower_to_core_call`: a marker built as a call to a placeholder callee is turned
// into a real `NODE_CALL` by seeding the callee's resolution to a std shim (found by module path + name) and
// flipping the kind. Everything downstream then treats it as an ordinary generic call, so bound checking
// (e.g. `F: fn move() + Send`), monomorphization and emission all come for free.

import ast::ast as *;
import module::loader as loader;

/// Lower every sugar-keyword marker in `ast` to its core form. `package` resolves the std shims each marker
/// targets; a null package (or an unresolved shim) leaves the node untouched, so a later pass reports it.
pub fn desugar_ast(ast: &mut Ast, package: *const loader::Package) {
    if package == null {
        return;
    }
    let n = ast.nodes.len();
    for i in 0..n {
        if ast.at_const(i as NodeId).kind == NodeKind::NODE_LAUNCH {
            lower_to_core_call(ast, package, i as NodeId, "std::parallel::runtime", "submit");
        }
    }
}

/// Turn a marker node (SingleData wrapping a `NODE_CALL` with a placeholder callee) into a plain
/// expression-statement call targeting `module_path::fn_name`: seed the inner call's callee resolution to
/// that decl, then flip the marker to NODE_EXPRESSION_STATEMENT (same SingleData layout). Reusable by any
/// sugar keyword that lowers to a single std call in statement position.
fn lower_to_core_call(ast: &mut Ast, package: *const loader::Package, id: NodeId, module_path: str, fn_name: str) {
    let inner = ast.at_const(id).as_data.single.value;
    let callee = ast.at_const(inner).as_data.call.callee;
    let pkg = unsafe &*package;
    let mid = pkg.find(module_path);
    if mid < 0 {
        return; // shim module not loaded (the conditional load in the loader should have pulled it in)
    }
    let hit = pkg.glob_lookup(mid as ModuleId, fn_name, false);
    if hit.node == NODE_NONE {
        return;
    }
    ast.resolutions[callee as usize] = DefId { module: hit.mid, node: hit.node };
    ast.at(id).kind = NodeKind::NODE_EXPRESSION_STATEMENT;
}
