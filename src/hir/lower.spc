// The AST-to-HIR lowering stage: runs per module after resolution, before typecheck. The tree the
// checker (and everything after it) consumes is the HIR: the resolved arena with every sugar-keyword
// marker lowered to core-language nodes. A sugar node is produced only by the parser, seen otherwise
// only by the formatter and the resolver (whose lint passes run before this stage), and eliminated
// here -- typecheck, borrowck, const-eval and codegen never see one. Adding a sugar keyword is then a
// lexer token, a parser marker, one lowering entry here, and a formatter arm; the rest of the
// compiler stays unaware of it.
//
// Batch builds lower by MOVE: the parse arena becomes the HIR in place (releasing the syntax tree at
// zero cost -- nothing after this stage reads pre-lowering syntax; the formatter parses its own).
// Under SC_KEEP_SYNTAX=1 the module keeps a pristine pre-lowering snapshot in `Module.syntax`, the
// retention the incremental-query work builds on. Generated nodes get fresh ids appended to the HIR
// arena; their spans borrow source text that already exists (a keyword's own bytes), so diagnostics
// and origin mapping stay exact.
//
// Two primitives do the work. `lower_to_core_call` turns a marker built as a call to a placeholder callee
// into a real `NODE_CALL` by seeding the callee's resolution to a std shim (a resolved SugarItem value
// from the package index -- no name lookup happens here) and flipping the kind -- everything downstream
// then treats it as an ordinary generic call, so bound checking, monomorphization and emission all come
// for free. `lower_select` goes further and BUILDS nodes: because resolve has already run, every
// identifier it creates has its resolution seeded by hand (a std shim, or the synthetic local it
// declares), and it never invents a name that is not already in the source text.

import ast::ast as *;
import lexer::token as tok;
import lexer::token_type as tt;
import module::loader as loader;
import stdlib;

/// Lower module `i` to HIR. Runs the sugar lowering over the module's resolved arena in place (the
/// Ast never leaves its slot, so shim lookups that land back on this module read the live tree).
/// Called unconditionally after resolve -- resolve errors leave markers unresolved, which the
/// lowering already skips.
pub fn lower_module(p: &mut loader::Package, i: usize) {
    if stdlib::getenv("SC_KEEP_SYNTAX") != null {
        p.modules[i].syntax.free();
        p.modules[i].syntax = syntax_snapshot(&p.modules[i].ast);
    }
    if p.modules[i].ast.sugar_marks == 0 {
        return; // no markers parsed: the arena already is the HIR
    }
    p.ensure_index(); // the SugarItem table below answers from it
    let aptr = (&mut p.modules[i].ast) as *mut Ast;
    desugar_ast(unsafe &mut *aptr, p);
}

// A pristine pre-lowering copy of the pure syntax arenas (no semantic tables: those belong to the HIR).
fn syntax_snapshot(a: &Ast) Ast {
    let mut s = Ast::new(0);
    s.root = a.root;
    s.module = a.module;
    s.sugar_marks = a.sugar_marks;
    s.nodes.clear();
    s.nodes.reserve(a.nodes.len());
    for i in 0..a.nodes.len() {
        s.nodes.push(*a.nodes.at(i));
    }
    s.children.reserve(a.children.len());
    for i in 0..a.children.len() {
        s.children.push(a.children[i]);
    }
    for i in 0..a.attrs.len() {
        s.attrs.push(*a.attrs.at(i));
    }
    for i in 0..a.metas.len() {
        s.metas.push(*a.metas.at(i));
    }
    for i in 0..a.lifetime_decls.len() {
        s.lifetime_decls.push(*a.lifetime_decls.at(i));
    }
    return s;
}

/// Lower every sugar-keyword marker in `ast` to its core form. `package` resolves the std shims each marker
/// targets; a null package (or an unresolved shim) leaves the node untouched, so a later pass reports it.
fn desugar_ast(ast: &mut Ast, package: *const loader::Package) {
    if package == null {
        return;
    }
    // Nodes appended below hold no markers, so the pre-loop count is the whole search space. A nested
    // `select` has a LOWER id than the one containing it (the parser adds a parent after its children), so
    // it is lowered first and the outer lowering just moves the finished block.
    let n = ast.nodes.len();
    for i in 0..n {
        let kind = ast.at_const(i as NodeId).kind;
        if kind == NodeKind::NODE_LAUNCH {
            lower_to_core_call(ast, unsafe (&*package).sugar_item(loader::SugarItem::SI_SUBMIT), i as NodeId);
        } else if kind == NodeKind::NODE_SELECT {
            lower_select(ast, package, i as NodeId);
        } else if kind == NodeKind::NODE_PARALLEL_FOR {
            lower_parallel_for(ast, package, i as NodeId);
        }
    }
}

/// Turn a marker node (SingleData wrapping a `NODE_CALL` with a placeholder callee) into a plain
/// expression-statement call targeting the resolved shim `def`: seed the inner call's callee resolution,
/// then flip the marker to NODE_EXPRESSION_STATEMENT (same SingleData layout). Reusable by any sugar
/// keyword that lowers to a single std call in statement position. A NODE_NONE def (shim module not
/// loaded) leaves the marker untouched, so a later pass reports it.
fn lower_to_core_call(ast: &mut Ast, def: DefId, id: NodeId) {
    if def.node == NODE_NONE {
        return;
    }
    let inner = ast.at_const(id).as_data.single.value;
    let callee = ast.at_const(inner).as_data.call.callee;
    ast.set_resolution_def(callee, def);
    ast.at(id).kind = NodeKind::NODE_EXPRESSION_STATEMENT;
}

// --- select ----------------------------------------------------------------------------------------

// `select { v = jobs.recv() => B0  out.send(x) => B1  timeout(d) => B2 }` becomes
//
//     {
//         let mut select = sugar_new();
//         sugar_arm_recv(&mut select, &jobs);
//         sugar_arm_send(&mut select, &out);
//         sugar_wait_timeout(&mut select, d);
//         if sugar_won(&mut select) { let v = sugar_recv(&jobs); B0 }
//         else if sugar_won(&mut select) { sugar_send(&out, x); B1 }
//         else B2
//     }
//
// Every callee is a free function in std::parallel::selector, so the only name this pass invents is the
// selector local -- and it borrows the `select` keyword's own span for that, which is text that exists and
// which no user code can reference (it is a keyword). `sugar_won` walks the arms in registration order, so
// the if-chain needs no integer literals; the channel expression is CLONED for its second use rather than
// shared, and the sent value is evaluated inside the winning branch, not before the wait.
fn lower_select(ast: &mut Ast, package: *const loader::Package, id: NodeId) {
    let pkg = unsafe &*package;
    let f_new = pkg.sugar_item(loader::SugarItem::SI_SEL_NEW);
    let f_arm_recv = pkg.sugar_item(loader::SugarItem::SI_SEL_ARM_RECV);
    let f_arm_send = pkg.sugar_item(loader::SugarItem::SI_SEL_ARM_SEND);
    let f_wait = pkg.sugar_item(loader::SugarItem::SI_SEL_WAIT);
    let f_wait_to = pkg.sugar_item(loader::SugarItem::SI_SEL_WAIT_TIMEOUT);
    let f_poll = pkg.sugar_item(loader::SugarItem::SI_SEL_POLL);
    let f_won = pkg.sugar_item(loader::SugarItem::SI_SEL_WON);
    let f_recv = pkg.sugar_item(loader::SugarItem::SI_SEL_RECV);
    let f_send = pkg.sugar_item(loader::SugarItem::SI_SEL_SEND);
    if f_new.node == NODE_NONE || f_arm_recv.node == NODE_NONE || f_arm_send.node == NODE_NONE || f_wait.node == NODE_NONE || f_wait_to.node == NODE_NONE || f_poll.node == NODE_NONE || f_won.node == NODE_NONE || f_recv.node == NODE_NONE || f_send.node == NODE_NONE {
        return;
    }
    let span = ast.at_const(id).span;
    let kw = tok::Span::new(span.start, span.start + 6); // the `select` keyword itself: the local's name
    let arms = ast.at_const(id).as_data.block.statements;

    // let mut select = sugar_new();
    let selname = add_node(ast, ident_node(kw));
    let selinit = call_shim(ast, f_new, kw, NODE_NONE, NODE_NONE);
    let letsel = add_node(
        ast,
        Node {
            kind: NodeKind::NODE_LET,
            span: kw,
            as_data: NodeAs { let_stmt: LetData { name: selname, ty: NODE_NONE, value: selinit, is_mutable: true } },
        },
    );
    let mark = ast.mark();
    ast.push(letsel);
    // One registration per channel arm, in source order -- which is the order `sugar_won` reports them in.
    let mut timeout_body = NODE_NONE;
    let mut timeout_dur = NODE_NONE;
    let mut has_default = false;
    for i in 0..arms.len {
        let a = unsafe ast.list(arms)[i as usize];
        let ad = ast.at_const(a).as_data.select_arm;
        let asp = ast.at_const(a).span;
        if ad.kind == SelectArmKind::SELECT_TIMEOUT {
            timeout_body = ad.body;
            timeout_dur = ad.op;
        } else if ad.kind == SelectArmKind::SELECT_DEFAULT {
            timeout_body = ad.body;
            has_default = true;
        } else {
            let f = if ad.kind == SelectArmKind::SELECT_RECV {
                f_arm_recv;
            } else {
                f_arm_send;
            };
            let call = call_shim(ast, f, asp, sel_ref(ast, kw, letsel), ref_of(ast, ad.op, false));
            ast.push(expr_stmt(ast, call, asp));
        }
    }
    // The wait itself: bounded by a deadline, not at all, or not a wait (a `default` arm means never block).
    let waitcall = if has_default {
        call_shim(ast, f_poll, kw, sel_ref(ast, kw, letsel), NODE_NONE);
    } else if timeout_dur != NODE_NONE {
        call_shim(ast, f_wait_to, kw, sel_ref(ast, kw, letsel), timeout_dur);
    } else {
        call_shim(ast, f_wait, kw, sel_ref(ast, kw, letsel), NODE_NONE);
    };
    ast.push(expr_stmt(ast, waitcall, kw));

    // The if-chain, built back to front so each arm's else is the chain below it.
    let mut chain = timeout_body;
    let mut k = arms.len;
    while k > 0 {
        k = k - 1;
        let a = unsafe ast.list(arms)[k as usize];
        let ad = ast.at_const(a).as_data.select_arm;
        if ad.kind == SelectArmKind::SELECT_TIMEOUT || ad.kind == SelectArmKind::SELECT_DEFAULT {
            continue;
        }
        let asp = ast.at_const(a).span;
        // The operation runs only in the branch that won it: a `Some`/`Sent` result means it went through,
        // and the value of a lost race comes back in the binding rather than vanishing.
        let takef = if ad.kind == SelectArmKind::SELECT_RECV {
            f_recv;
        } else {
            f_send;
        };
        let take = call_shim(ast, takef, asp, ref_of(ast, clone_place(ast, ad.op), false), ad.value);
        let stmt = if ad.binding != NODE_NONE {
            ast.at(ad.binding).as_data.let_stmt.value = take;
            ad.binding;
        } else {
            expr_stmt(ast, take, asp);
        };
        let bmark = ast.mark();
        ast.push(stmt);
        ast.push(ad.body);
        let then = block_of(ast, ast.commit(bmark), asp);
        chain = add_node(
            ast,
            Node {
                kind: NodeKind::NODE_IF,
                span: asp,
                as_data: NodeAs {
                    if_stmt: IfData {
                        condition: call_shim(ast, f_won, asp, sel_ref(ast, kw, letsel), NODE_NONE),
                        then_branch: then,
                        else_branch: chain,
                    },
                },
            },
        );
    }
    if chain != NODE_NONE {
        ast.push(chain);
    }
    let stmts = ast.commit(mark);
    ast.at(id).kind = NodeKind::NODE_BLOCK;
    ast.at(id).as_data.block.statements = stmts;
}

// `parallel for i in a..b { B }` becomes `std::parallel::data::range(a..b, fn(i) { B });` -- the
// closure already exists (the parser built it as the marker's body so resolve filled its captures);
// all that is left is the call around it and the marker flip to an expression statement.
fn lower_parallel_for(ast: &mut Ast, package: *const loader::Package, id: NodeId) {
    let pkg = unsafe &*package;
    let f = pkg.sugar_item(loader::SugarItem::SI_PAR_RANGE);
    if f.node == NODE_NONE {
        return;
    }
    let fr = ast.at_const(id).as_data.for_stmt;
    let span = ast.at_const(id).span;
    let kw = tok::Span::new(span.start, span.start + 8); // the `parallel` keyword's own text
    let call = call_shim(ast, f, kw, fr.iterable, fr.body);
    ast.at(id).kind = NodeKind::NODE_EXPRESSION_STATEMENT;
    ast.at(id).as_data = NodeAs { single: SingleData { value: call } };
}

// Every node this pass builds goes through here: the resolution side table was sized at resolve time, so it
// has to grow in lockstep or seeding a new node's resolution would run off the end.
fn add_node(ast: &mut Ast, n: Node) NodeId {
    let id = ast.add(n);
    ast.grow_resolutions();
    return id;
}

const fn ident_node(span: tok::Span) Node {
    return Node {
        kind: NodeKind::NODE_IDENTIFIER,
        span: span,
        as_data: NodeAs { name: NameData { text: span, is_mutable: false } },
    };
}

// `&mut select`, resolved to the synthetic local.
fn sel_ref(ast: &mut Ast, kw: tok::Span, letsel: NodeId) NodeId {
    let use_id = add_node(ast, ident_node(kw));
    ast.set_resolution(use_id, letsel);
    return ref_of(ast, use_id, true);
}

fn ref_of(ast: &mut Ast, operand: NodeId, mutable: bool) NodeId {
    return add_node(
        ast,
        Node {
            kind: NodeKind::NODE_UNARY,
            span: ast.at_const(operand).span,
            as_data: NodeAs {
                unary: UnaryData {
                    op: tt::TokenType::Ampersand,
                    operand: operand,
                    qualifier: if mutable {
                        TypeQualifier::TYPE_QUAL_MUT;
                    } else {
                        TypeQualifier::TYPE_QUAL_NONE;
                    },
                },
            },
        },
    );
}

// A call to a std shim: the callee is a fresh identifier whose TEXT is never read, because its resolution
// is seeded here (the same trick `lower_to_core_call` uses).
fn call_shim(ast: &mut Ast, def: DefId, span: tok::Span, a0: NodeId, a1: NodeId) NodeId {
    let callee = add_node(ast, ident_node(span));
    ast.set_resolution_def(callee, def);
    let mark = ast.mark();
    if a0 != NODE_NONE {
        ast.push(a0);
    }
    if a1 != NODE_NONE {
        ast.push(a1);
    }
    let args = ast.commit(mark);
    return add_node(
        ast,
        Node {
            kind: NodeKind::NODE_CALL,
            span: span,
            as_data: NodeAs { call: CallData { callee: callee, args: args } },
        },
    );
}

fn expr_stmt(ast: &mut Ast, value: NodeId, span: tok::Span) NodeId {
    return add_node(
        ast,
        Node {
            kind: NodeKind::NODE_EXPRESSION_STATEMENT,
            span: span,
            as_data: NodeAs { single: SingleData { value: value } },
        },
    );
}

fn block_of(ast: &mut Ast, statements: NodeList, span: tok::Span) NodeId {
    return add_node(
        ast,
        Node { kind: NodeKind::NODE_BLOCK, span: span, as_data: NodeAs { block: BlockData { statements: statements } } },
    );
}

// A second copy of the arm's channel expression, for the take that follows the wait. Sharing one node
// between two parents would make it two nodes' worth of analysis on one id; the parser has already limited
// the shape to a name or a field path, so the copy is shallow and side-effect-free.
fn clone_place(ast: &mut Ast, id: NodeId) NodeId {
    let n = *ast.at_const(id);
    let copy = if n.kind == NodeKind::NODE_MEMBER {
        let md = n.as_data.member;
        let obj = clone_place(ast, md.object);
        add_node(
            ast,
            Node {
                kind: NodeKind::NODE_MEMBER,
                span: n.span,
                as_data: NodeAs {
                    member: MemberData { object: obj, member: md.member, pointer: md.pointer, path: md.path },
                },
            },
        );
    } else {
        add_node(ast, n);
    };
    ast.set_resolution_def(copy, ast.resolution_def(id));
    return copy;
}
