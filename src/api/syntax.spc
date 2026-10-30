// Source-preserving syntax views: one file's text parsed by the compiler's own lexer and parser alone, as a
// tree of nodes over byte ranges, with every token of the text (comments included) in order. Parsing needs no
// project and always completes: an invalid file is a tree with errors. A token the tree drops (a parenthesis,
// a comment) stays in the token list and inside its node's range. A tree is owned; its views borrow it.
// Also here: checked text edits over a session, a builder for generated source, and the formatter.
import lexer::lexer as lex;
import lexer::token as tok;
import lexer::token_type as tt;
import ast::ast as *;
import ast::parser as par;
import utils::errors as diag;
import driver::util as dutil;
import api::errors as *;
import api::source as *;
import api::session as ses;

/// Bytes `[start, end)` of a text.
pub struct TextRange {
    pub start: u32,
    pub end: u32,
}

extend TextRange as Copy {}

/// What a node is. `Error` is a node the parser could not make sense of.
@derive(Eq, Format)
pub enum SyntaxKind {
    Error,
    Program,
    Identifier,
    Literal,
    Function,
    Parameter,
    Struct,
    Field,
    Enum,
    Variant,
    Interface,
    Extend,
    TypeAlias,
    Const,
    StaticAssert,
    ExternBlock,
    Import,
    GenericParam,
    WherePredicate,
    TypePath,
    PointerType,
    ReferenceType,
    SliceType,
    ArrayType,
    FunctionType,
    DynType,
    Block,
    Let,
    Return,
    Break,
    Continue,
    Defer,
    Asm,
    If,
    While,
    For,
    ExpressionStatement,
    Unary,
    Binary,
    Assignment,
    Call,
    Closure,
    Index,
    Member,
    Cast,
    GenericSpecialization,
    Match,
    MatchArm,
    Sizeof,
    Alignof,
    VaExpr,
    ArrayLiteral,
    StructInitializer,
    FieldInitializer,
    PatternWildcard,
    PatternLiteral,
    PatternName,
    PatternTuple,
    PatternStruct,
    PatternField,
    PatternRange,
    PatternOr,
    Range,
    Tuple,
    TupleType,
    Lifetime,
    Launch,
    Select,
    SelectArm,
    InlineFor,
    ParallelFor,
    Interpolation,
}

/// What a token is.
@derive(Eq, Format)
pub enum TokenKind {
    Ident,
    Keyword, // reserved words, `true`, `false`, `null`, `_`
    Label, // a lifetime or a loop label: `'a`
    Int,
    Float,
    Char,
    String, // every string form, matchertext included
    Punct,
    Comment,
    DocComment,
}

/// A lexer or parser error at a range of the text.
pub struct SyntaxError {
    pub range: TextRange,
    pub message: String,
}

const NONE: u32 = 0xFFFFFFFF;

/// One file's parse.
pub struct SyntaxTree {
    path: String,
    pub(module) text: String, // padded with lexer::SOURCE_PAD NULs past its length
    pub(module) tokens: Vector<tok::Token>, // every token, comments included, in order; no end-of-file token
    pub(module) ast: Ast,
    pub(module) nodes: Vector<NodeId>, // in preorder: a node, then its subtree
    pub(module) ends: Vector<u32>, // per preorder index: one past its last descendant
    pub(module) parents: Vector<u32>, // per preorder index: its parent's, NONE for the root
    pos: Vector<u32>, // per dense AST index (`Ast::dense`): its preorder index
    pub(module) errors: Vector<SyntaxError>,
}

// Copy the records of `e` into `out` as syntax errors: the message and its first note line.
fn take_errors(e: &diag::Errors, out: &mut Vector<SyntaxError>) {
    for k in 0..e.errors.len() {
        let d = e.errors.at(k);
        let mut m = String::from_str(d.msg.as_str());
        if d.note_head != diag::NOTE_NONE {
            m.push_str("\n= note: ");
            m.push_str(e.note_pool.at(d.note_head as usize).text.as_str());
        }
        out.push(SyntaxError { range: TextRange { start: d.start, end: d.start + d.len }, message: m });
    }
}

const fn is_comment(k: tt::TokenType) bool {
    return k == tt::TokenType::LineComment || k == tt::TokenType::BlockComment || k == tt::TokenType::DocLineComment || k == tt::TokenType::DocBlockComment;
}

extend SyntaxTree {
    /// The parse of `text`, the contents of file `path` (the name errors carry).
    pub fn parse(path: str, text: str) SyntaxTree {
        let mut src = String::with_capacity(text.len() + lex::SOURCE_PAD);
        src.push_str(text);
        src.pad_nul(lex::SOURCE_PAD);
        let mut errors = Vector::<SyntaxError>::new();
        let mut all = Vector::<tok::Token>::new();
        {
            let mut lx = lex::Lexer::new(&mut src, path);
            lx.keep_trivia = true;
            lx.scan_tokens();
            take_errors(&lx.errors, &mut errors);
            all = lx.take_tokens();
        }
        let mut sig = Vector::<tok::Token>::with_capacity(all.len());
        let mut toks = Vector::<tok::Token>::with_capacity(all.len());
        for i in 0..all.len() {
            let t = all[i];
            if !is_comment(t.kind()) {
                sig.push(t);
            }
            if t.kind() != tt::TokenType::Eof {
                toks.push(t);
            }
        }
        let mut ps = par::Parser::new(sig, src.as_str(), path);
        // The tree holds what the text says: no extend the parser would synthesize for `@derive`.
        ps.expand_derive = false;
        ps.build_ast();
        take_errors(&ps.errors, &mut errors);
        let ast = ps.take_ast();
        let mut t = SyntaxTree { path: String::from_str(path), text: src, tokens: toks, ast: ast, errors: errors };
        t.shape();
        return t;
    }

    // The preorder, parents and subtree ends: the tree the node ranges nest into. A node contains the nodes
    // whose ranges lie inside its own; the parser makes a child before its parent, so of two equal ranges
    // the later node (a module-arena node before a body-arena one) is the parent.
    fn shape(self: &mut Self) {
        let n = self.ast.nnodes();
        let mut ids = Vector::<NodeId>::with_capacity(n);
        for k in 1..n {
            ids.push(self.ast.nth_id(k));
        }
        let len = self.text.len() as u32;
        let a = &self.ast;
        ids.sort_by(|x: &NodeId, y: &NodeId| node_order(a, len, *x, *y));
        self.pos.resize_default(n);
        self.parents.reserve(ids.len());
        self.ends.resize_default(ids.len());
        let mut stack = Vector::<u32>::new();
        for i in 0..ids.len() {
            let r = node_range(a, len, ids[i]);
            while stack.len() != 0 {
                let top = stack[stack.len() - 1];
                let tr = node_range(a, len, ids[top as usize]);
                if tr.start <= r.start && r.end <= tr.end {
                    break;
                }
                self.ends[top as usize] = i as u32;
                let _ = stack.pop();
            }
            self.parents.push(
                if stack.len() == 0 {
                    NONE;
                } else {
                    stack[stack.len() - 1];
                },
            );
            stack.push(i as u32);
            self.pos[a.dense(ids[i])] = i as u32;
        }
        for k in 0..stack.len() {
            self.ends[stack[k] as usize] = ids.len() as u32;
        }
        self.nodes = ids;
    }

    /// The file name the tree was parsed under.
    pub fn path(self: &Self) str {
        return self.path.as_str();
    }

    /// The parsed text.
    pub fn text(self: &Self) str {
        return self.text.as_str();
    }

    /// The root: the whole file.
    pub fn root(self: &Self) Node {
        return Node { t: self, i: 0 };
    }

    /// The node of identity `id` (`Node::id`), or None.
    pub fn node(self: &Self, id: u32) Option<Node> {
        if id as usize >= self.nodes.len() {
            return Option::<Node>::None;
        }
        return Option::<Node>::Some(Node { t: self, i: id });
    }

    /// The lexer and parser errors, in the order they were found.
    pub fn errors(self: &Self) Slice<SyntaxError> {
        return self.errors.as_slice();
    }

    /// Whether the text lexes and parses without an error.
    pub fn is_valid(self: &Self) bool {
        return self.errors.len() == 0;
    }

    /// Every token, comments included, in text order.
    pub fn tokens(self: &Self) Tokens {
        return Tokens { t: self, at: 0, end: self.tokens.len() as u32 };
    }

    /// The token that holds byte `off`, or None in whitespace.
    pub fn token_at(self: &Self, off: u32) Option<Token> {
        let k = self.first_token_from(off);
        if k < self.tokens.len() && self.tokens[k].start() <= off && off < self.tokens[k].end() {
            return Option::<Token>::Some(Token { t: self, i: k as u32 });
        }
        return Option::<Token>::None;
    }

    // The first token that ends after `off`.
    fn first_token_from(self: &Self, off: u32) usize {
        let mut lo: usize = 0;
        let mut hi = self.tokens.len();
        while lo < hi {
            let mid = (lo + hi) / 2;
            if self.tokens[mid].end() <= off {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    /// The innermost node whose range holds byte `off`; the root when no other does.
    pub fn node_at(self: &Self, off: u32) Node {
        let mut cur: u32 = 0;
        // Each step descends one level.
        for _ in 0..self.nodes.len() {
            let mut next = NONE;
            let mut c = cur + 1;
            while c < self.ends[cur as usize] {
                let r = self.range_of(c);
                if r.start <= off && off < r.end {
                    next = c;
                    break;
                }
                c = self.ends[c as usize];
            }
            if next == NONE {
                break;
            }
            cur = next;
        }
        return Node { t: self, i: cur };
    }

    fn range_of(self: &Self, i: u32) TextRange {
        return node_range(&self.ast, self.text.len() as u32, self.nodes[i as usize]);
    }

    // The view of AST node `id`, or None for NODE_NONE.
    fn view(self: &Self, id: NodeId) Option<Node> {
        if id == NODE_NONE {
            return Option::<Node>::None;
        }
        return Option::<Node>::Some(Node { t: self, i: self.pos[self.ast.dense(id)] });
    }
}

// A node's range: its span inside the text (a node the parser made while it recovered from an error may
// hold a span past the text or an inverted one), the whole text for the program.
fn node_range(a: &Ast, len: u32, id: NodeId) TextRange {
    let n = a.at_const(id);
    if n.kind == NodeKind::NODE_PROGRAM {
        return TextRange { start: 0, end: len };
    }
    let s = n.span.start.min(len);
    return TextRange { start: s, end: n.span.end.min(len).max(s) };
}

// Preorder: by start, the longer range first, then the later-made node first.
fn node_order(a: &Ast, len: u32, x: NodeId, y: NodeId) i32 {
    let rx = node_range(a, len, x);
    let ry = node_range(a, len, y);
    if rx.start != ry.start {
        return if rx.start < ry.start {
            -1;
        } else {
            1;
        };
    }
    if rx.end != ry.end {
        return if rx.end > ry.end {
            -1;
        } else {
            1;
        };
    }
    let bx = Ast::in_body(x);
    let by = Ast::in_body(y);
    if bx != by {
        return if by {
            -1;
        } else {
            1;
        };
    }
    return if x > y {
        -1;
    } else if x < y {
        1;
    } else {
        0;
    };
}

/// A node of a tree.
pub struct Node<'t> {
    pub(module) t: &'t SyntaxTree,
    pub(module) i: u32,
}

extend<'t> Node<'t> as Copy {}

extend<'t> Node<'t> {
    fn ast_node(self: &Self) &'t ast::Node {
        return self.t.ast.at_const(self.t.nodes[self.i as usize]);
    }

    // The payload the node keeps outside itself (`ast::Ast::ext`).
    fn ast_ext(self: &Self) &'t ast::NodeExt {
        return self.t.ast.ext(self.t.nodes[self.i as usize]);
    }

    /// What it is.
    pub fn kind(self: &Self) SyntaxKind {
        return kind_of(self.ast_node().kind);
    }

    /// Its byte range: its first token's start to its last token's end (the whole text for the root).
    pub fn range(self: &Self) TextRange {
        return self.t.range_of(self.i);
    }

    /// Its text.
    pub fn text(self: &Self) str<'t> {
        let r = self.range();
        return self.t.text.as_str().slice(r.start as usize, r.end as usize);
    }

    /// The node it is part of; None for the root.
    pub fn parent(self: &Self) Option<Node<'t>> {
        let p = self.t.parents[self.i as usize];
        if p == NONE {
            return Option::<Node<'t>>::None;
        }
        return Option::<Node<'t>>::Some(Node { t: self.t, i: p });
    }

    /// Its direct children, in text order.
    pub fn children(self: &Self) Children<'t> {
        return Children { t: self.t, at: self.i + 1, end: self.t.ends[self.i as usize] };
    }

    /// Every node inside it, in preorder (text order, an outer node before the nodes it holds).
    pub fn descendants(self: &Self) Descendants<'t> {
        return Descendants { t: self.t, at: self.i + 1, end: self.t.ends[self.i as usize] };
    }

    /// The tokens inside its range, comments included.
    pub fn tokens(self: &Self) Tokens<'t> {
        let r = self.range();
        let mut k = self.t.first_token_from(r.start);
        while k < self.t.tokens.len() && self.t.tokens[k].start() < r.start {
            k += 1;
        }
        let mut e = k;
        while e < self.t.tokens.len() && self.t.tokens[e].end() <= r.end {
            e += 1;
        }
        return Tokens { t: self.t, at: k as u32, end: e as u32 };
    }

    /// Its name, for a declaration, parameter, field or variant: the name node.
    pub fn name(self: &Self) Option<Node<'t>> {
        let n = self.ast_node();
        let id = switch n.kind {
            NODE_FUNCTION => self.ast_ext().function.name,
            NODE_STRUCT | NODE_ENUM => self.ast_ext().aggregate.name,
            NODE_PARAMETER => n.as_data.parameter.name,
            NODE_FIELD => n.as_data.field.name,
            NODE_VARIANT => n.as_data.variant.name,
            NODE_INTERFACE => self.ast_ext().interface_def.name,
            NODE_TYPE_ALIAS => n.as_data.type_alias.name,
            NODE_CONST => n.as_data.const_def.name,
            NODE_LET => n.as_data.let_stmt.name,
            _ => NODE_NONE,
        };
        return self.t.view(id);
    }

    /// Its identity in its tree (`SyntaxTree::node`): a number, valid while the tree lives.
    pub fn id(self: &Self) u32 {
        return self.i;
    }

    /// The function view of a `Function` node.
    pub fn as_fn(self: &Self) Option<FnSyntax<'t>> {
        if self.ast_node().kind != NodeKind::NODE_FUNCTION {
            return Option::<FnSyntax<'t>>::None;
        }
        return Option::<FnSyntax<'t>>::Some(FnSyntax { n: *self });
    }

    /// The aggregate view of a `Struct` or `Enum` node.
    pub fn as_aggregate(self: &Self) Option<AggregateSyntax<'t>> {
        let k = self.ast_node().kind;
        if k != NodeKind::NODE_STRUCT && k != NodeKind::NODE_ENUM {
            return Option::<AggregateSyntax<'t>>::None;
        }
        return Option::<AggregateSyntax<'t>>::Some(AggregateSyntax { n: *self });
    }

    /// The import view of an `Import` node.
    pub fn as_import(self: &Self) Option<ImportSyntax<'t>> {
        if self.ast_node().kind != NodeKind::NODE_IMPORT {
            return Option::<ImportSyntax<'t>>::None;
        }
        return Option::<ImportSyntax<'t>>::Some(ImportSyntax { n: *self });
    }

    /// The call view of a `Call` node.
    pub fn as_call(self: &Self) Option<CallSyntax<'t>> {
        if self.ast_node().kind != NodeKind::NODE_CALL {
            return Option::<CallSyntax<'t>>::None;
        }
        return Option::<CallSyntax<'t>>::Some(CallSyntax { n: *self });
    }

    /// The `let` view of a `Let` node.
    pub fn as_let(self: &Self) Option<LetSyntax<'t>> {
        if self.ast_node().kind != NodeKind::NODE_LET {
            return Option::<LetSyntax<'t>>::None;
        }
        return Option::<LetSyntax<'t>>::Some(LetSyntax { n: *self });
    }

    fn list(self: &Self, l: NodeList) NodeIter<'t> {
        return NodeIter { t: self.t, ids: self.t.ast.list(l), at: 0, len: l.len };
    }
}

/// A function: `fn name<generics>(params) returns where .. { body }`.
pub struct FnSyntax<'t> {
    pub(module) n: Node<'t>,
}

extend<'t> FnSyntax<'t> {
    pub fn node(self: &Self) Node<'t> {
        return self.n;
    }

    pub fn name(self: &Self) Option<Node<'t>> {
        return self.n.name();
    }

    /// The generic parameters, lifetimes first as written.
    pub fn generics(self: &Self) NodeIter<'t> {
        return self.n.list(self.n.ast_ext().function.generics);
    }

    /// The parameters (`Parameter` nodes; `name()` and `ty()` read them).
    pub fn params(self: &Self) NodeIter<'t> {
        return self.n.list(self.n.ast_ext().function.params);
    }

    /// The result types: none for `void`, several for a result list.
    pub fn returns(self: &Self) NodeIter<'t> {
        return self.n.list(self.n.ast_ext().function.returns);
    }

    /// The body block; None for a declaration without one.
    pub fn body(self: &Self) Option<Node<'t>> {
        return self.n.t.view(self.n.ast_ext().function.body);
    }
}

extend<'t> Node<'t> {
    /// The written type of a `Parameter`, `Field` or `Let` node.
    pub fn ty(self: &Self) Option<Node<'t>> {
        let n = self.ast_node();
        let id = switch n.kind {
            NODE_PARAMETER => n.as_data.parameter.ty,
            NODE_FIELD => n.as_data.field.ty,
            NODE_LET => n.as_data.let_stmt.ty,
            _ => NODE_NONE,
        };
        return self.t.view(id);
    }
}

/// A struct, union or enum.
pub struct AggregateSyntax<'t> {
    pub(module) n: Node<'t>,
}

extend<'t> AggregateSyntax<'t> {
    pub fn node(self: &Self) Node<'t> {
        return self.n;
    }

    pub fn name(self: &Self) Option<Node<'t>> {
        return self.n.name();
    }

    /// The fields of a struct or union, the variants of an enum.
    pub fn members(self: &Self) NodeIter<'t> {
        return self.n.list(self.n.ast_ext().aggregate.members);
    }

    pub fn is_union(self: &Self) bool {
        return self.n.ast_ext().aggregate.is_union;
    }
}

/// An import: `import a::b as c;` or `import a::b as *;`.
pub struct ImportSyntax<'t> {
    pub(module) n: Node<'t>,
}

extend<'t> ImportSyntax<'t> {
    pub fn node(self: &Self) Node<'t> {
        return self.n;
    }

    /// The path segments (`Identifier` nodes).
    pub fn path(self: &Self) NodeIter<'t> {
        return self.n.list(self.n.ast_node().as_data.import_decl.path);
    }

    /// The `as` name; None without one or for a glob.
    pub fn alias(self: &Self) Option<Node<'t>> {
        return self.n.t.view(self.n.ast_node().as_data.import_decl.alias);
    }

    pub fn is_glob(self: &Self) bool {
        return self.n.ast_node().as_data.import_decl.glob;
    }
}

/// A call: `callee(args)`.
pub struct CallSyntax<'t> {
    pub(module) n: Node<'t>,
}

extend<'t> CallSyntax<'t> {
    pub fn node(self: &Self) Node<'t> {
        return self.n;
    }

    pub fn callee(self: &Self) Option<Node<'t>> {
        return self.n.t.view(self.n.ast_node().as_data.call.callee);
    }

    pub fn args(self: &Self) NodeIter<'t> {
        return self.n.list(self.n.ast_node().as_data.call.args);
    }
}

/// A `let` statement.
pub struct LetSyntax<'t> {
    pub(module) n: Node<'t>,
}

extend<'t> LetSyntax<'t> {
    pub fn node(self: &Self) Node<'t> {
        return self.n;
    }

    /// The bound name or pattern.
    pub fn pattern(self: &Self) Option<Node<'t>> {
        return self.n.name();
    }

    pub fn ty(self: &Self) Option<Node<'t>> {
        return self.n.ty();
    }

    pub fn value(self: &Self) Option<Node<'t>> {
        return self.n.t.view(self.n.ast_node().as_data.let_stmt.value);
    }

    pub fn is_mutable(self: &Self) bool {
        return self.n.ast_node().as_data.let_stmt.is_mutable;
    }
}

/// The nodes of a list a typed view reads (parameters, members, arguments), in order. A list entry the
/// parser left empty is skipped.
pub struct NodeIter<'t> {
    pub(module) t: &'t SyntaxTree,
    pub(module) ids: *const NodeId,
    pub(module) at: u32,
    pub(module) len: u32,
}

extend<'t> NodeIter<'t> as Iterator<Node<'t>> {
    pub fn next(self: &mut Self) Option<Node<'t>> {
        while self.at < self.len {
            let id = unsafe self.ids[self.at as usize];
            self.at += 1;
            if id != NODE_NONE {
                return self.t.view(id);
            }
        }
        return Option::<Node<'t>>::None;
    }

    pub fn size_hint(self: &Self) (usize, Option<usize>) {
        return 0, Option::<usize>::Some((self.len - self.at) as usize);
    }
}

/// The children of a node.
pub struct Children<'t> {
    pub(module) t: &'t SyntaxTree,
    pub(module) at: u32,
    pub(module) end: u32,
}

extend<'t> Children<'t> as Iterator<Node<'t>> {
    pub fn next(self: &mut Self) Option<Node<'t>> {
        if self.at >= self.end {
            return Option::<Node<'t>>::None;
        }
        let i = self.at;
        self.at = self.t.ends[i as usize];
        return Option::<Node<'t>>::Some(Node { t: self.t, i: i });
    }
}

/// The nodes inside a node, in preorder.
pub struct Descendants<'t> {
    pub(module) t: &'t SyntaxTree,
    pub(module) at: u32,
    pub(module) end: u32,
}

extend<'t> Descendants<'t> as Iterator<Node<'t>> {
    pub fn next(self: &mut Self) Option<Node<'t>> {
        if self.at >= self.end {
            return Option::<Node<'t>>::None;
        }
        self.at += 1;
        return Option::<Node<'t>>::Some(Node { t: self.t, i: self.at - 1 });
    }

    pub fn size_hint(self: &Self) (usize, Option<usize>) {
        let n = (self.end - self.at) as usize;
        return n, Option::<usize>::Some(n);
    }
}

/// A token of a tree.
pub struct Token<'t> {
    pub(module) t: &'t SyntaxTree,
    pub(module) i: u32,
}

extend<'t> Token<'t> as Copy {}

extend<'t> Token<'t> {
    pub fn kind(self: &Self) TokenKind {
        return token_kind(self.t.tokens[self.i as usize].kind());
    }

    pub fn range(self: &Self) TextRange {
        let k = self.t.tokens[self.i as usize];
        return TextRange { start: k.start(), end: k.end() };
    }

    pub fn text(self: &Self) str<'t> {
        let k = self.t.tokens[self.i as usize];
        return self.t.text.as_str().slice(k.start() as usize, k.end() as usize);
    }

    /// The innermost node whose range holds it.
    pub fn parent(self: &Self) Node<'t> {
        return self.t.node_at(self.range().start);
    }
}

/// Consecutive tokens of a tree.
pub struct Tokens<'t> {
    pub(module) t: &'t SyntaxTree,
    pub(module) at: u32,
    pub(module) end: u32,
}

extend<'t> Tokens<'t> as Iterator<Token<'t>> {
    pub fn next(self: &mut Self) Option<Token<'t>> {
        if self.at >= self.end {
            return Option::<Token<'t>>::None;
        }
        self.at += 1;
        return Option::<Token<'t>>::Some(Token { t: self.t, i: self.at - 1 });
    }

    pub fn size_hint(self: &Self) (usize, Option<usize>) {
        let n = (self.end - self.at) as usize;
        return n, Option::<usize>::Some(n);
    }
}

/// The syntax kind of AST node kind `k`. Not part of the API.
pub(package) fn kind_of(k: NodeKind) SyntaxKind {
    return switch k {
        NODE_NONE_KIND => SyntaxKind::Error,
        NODE_PROGRAM => SyntaxKind::Program,
        NODE_IDENTIFIER => SyntaxKind::Identifier,
        NODE_LITERAL => SyntaxKind::Literal,
        NODE_FUNCTION => SyntaxKind::Function,
        NODE_PARAMETER => SyntaxKind::Parameter,
        NODE_STRUCT => SyntaxKind::Struct,
        NODE_FIELD => SyntaxKind::Field,
        NODE_ENUM => SyntaxKind::Enum,
        NODE_VARIANT => SyntaxKind::Variant,
        NODE_INTERFACE => SyntaxKind::Interface,
        NODE_EXTEND => SyntaxKind::Extend,
        NODE_TYPE_ALIAS => SyntaxKind::TypeAlias,
        NODE_CONST => SyntaxKind::Const,
        NODE_STATIC_ASSERT => SyntaxKind::StaticAssert,
        NODE_EXTERN_BLOCK => SyntaxKind::ExternBlock,
        NODE_IMPORT => SyntaxKind::Import,
        NODE_GENERIC_PARAM => SyntaxKind::GenericParam,
        NODE_WHERE_PREDICATE => SyntaxKind::WherePredicate,
        NODE_TYPE_PATH => SyntaxKind::TypePath,
        NODE_POINTER_TYPE => SyntaxKind::PointerType,
        NODE_REFERENCE_TYPE => SyntaxKind::ReferenceType,
        NODE_SLICE_TYPE => SyntaxKind::SliceType,
        NODE_ARRAY_TYPE => SyntaxKind::ArrayType,
        NODE_FUNCTION_TYPE => SyntaxKind::FunctionType,
        NODE_DYN_TYPE => SyntaxKind::DynType,
        NODE_BLOCK => SyntaxKind::Block,
        NODE_LET => SyntaxKind::Let,
        NODE_RETURN => SyntaxKind::Return,
        NODE_BREAK => SyntaxKind::Break,
        NODE_CONTINUE => SyntaxKind::Continue,
        NODE_DEFER => SyntaxKind::Defer,
        NODE_ASM => SyntaxKind::Asm,
        NODE_IF => SyntaxKind::If,
        NODE_WHILE => SyntaxKind::While,
        NODE_FOR => SyntaxKind::For,
        NODE_EXPRESSION_STATEMENT => SyntaxKind::ExpressionStatement,
        NODE_UNARY => SyntaxKind::Unary,
        NODE_BINARY => SyntaxKind::Binary,
        NODE_ASSIGNMENT => SyntaxKind::Assignment,
        NODE_CALL => SyntaxKind::Call,
        NODE_CLOSURE => SyntaxKind::Closure,
        NODE_INDEX => SyntaxKind::Index,
        NODE_MEMBER => SyntaxKind::Member,
        NODE_CAST => SyntaxKind::Cast,
        NODE_GENERIC_SPECIALIZATION => SyntaxKind::GenericSpecialization,
        NODE_MATCH => SyntaxKind::Match,
        NODE_MATCH_ARM => SyntaxKind::MatchArm,
        NODE_SIZEOF => SyntaxKind::Sizeof,
        NODE_ALIGNOF => SyntaxKind::Alignof,
        NODE_VA_EXPR => SyntaxKind::VaExpr,
        NODE_ARRAY_LITERAL => SyntaxKind::ArrayLiteral,
        NODE_STRUCT_INITIALIZER => SyntaxKind::StructInitializer,
        NODE_FIELD_INITIALIZER => SyntaxKind::FieldInitializer,
        NODE_PATTERN_WILDCARD => SyntaxKind::PatternWildcard,
        NODE_PATTERN_LITERAL => SyntaxKind::PatternLiteral,
        NODE_PATTERN_NAME => SyntaxKind::PatternName,
        NODE_PATTERN_TUPLE => SyntaxKind::PatternTuple,
        NODE_PATTERN_STRUCT => SyntaxKind::PatternStruct,
        NODE_PATTERN_FIELD => SyntaxKind::PatternField,
        NODE_PATTERN_RANGE => SyntaxKind::PatternRange,
        NODE_PATTERN_OR => SyntaxKind::PatternOr,
        NODE_RANGE => SyntaxKind::Range,
        NODE_TUPLE => SyntaxKind::Tuple,
        NODE_TUPLE_TYPE => SyntaxKind::TupleType,
        NODE_LIFETIME => SyntaxKind::Lifetime,
        NODE_LAUNCH => SyntaxKind::Launch,
        NODE_SELECT => SyntaxKind::Select,
        NODE_SELECT_ARM => SyntaxKind::SelectArm,
        NODE_INLINE_FOR => SyntaxKind::InlineFor,
        NODE_PARALLEL_FOR => SyntaxKind::ParallelFor,
        NODE_INTERP => SyntaxKind::Interpolation,
    };
}

fn token_kind(k: tt::TokenType) TokenKind {
    return switch k {
        Identifier => TokenKind::Ident,
        Label => TokenKind::Label,
        IntegerLiteral => TokenKind::Int,
        FloatLiteral => TokenKind::Float,
        CharacterLiteral | ByteCharacterLiteral => TokenKind::Char,
        StringLiteral | RawStringLiteral | ByteStringLiteral | MatchertextLiteral | MatchertextBegin | MatchertextMid | MatchertextEnd => TokenKind::String,
        LineComment | BlockComment => TokenKind::Comment,
        DocLineComment | DocBlockComment => TokenKind::DocComment,
        As | Import | Break | Case | Const | Continue | Defer | Asm | Do | Dyn | Else | Enum | Extern | False | Fn | For | If | Extend | In | Let | Loop | Switch | Move | Mut | Null | Pub | Sizeof | Alignof | Return | SelfLower | SelfUpper | Struct | Interface | True | Type | Union | Unsafe | Where | While | Underscore | Static | StaticAssert | VaStart | VaArg | VaEnd | Launch | Select | InlineFor | ParallelFor => TokenKind::Keyword,
        _ => TokenKind::Punct,
    };
}

/// The tree of file `path` as session `s` holds it: its buffer's text, else its provider's.
pub fn tree_of(s: &mut ses::Session, path: str) Result<SyntaxTree, ApiError> {
    let t = s.text(path)?;
    if t.is_none() {
        return Result::<SyntaxTree, ApiError>::Err(ApiError::at(Code::InvalidArgument, "no such file", path, 0, 0));
    }
    return Result::<SyntaxTree, ApiError>::Ok(SyntaxTree::parse(path, t.unwrap().as_str()));
}

/// `text`, the contents of file `path`, in the canonical format at line width `width` (120 for `super-c
/// fmt`). `ParseFailed` when it does not lex or parse.
pub fn format_file(path: str, text: str, width: u32) Result<String, ApiError> {
    let src = String::from_str(text);
    let mut out = String::new();
    let mut errs = diag::Errors::new();
    if !dutil::format_quiet(&src, path, width as i32, false, &mut out, &mut errs) {
        let mut e = ApiError::at(Code::ParseFailed, "the text does not format", path, 0, 0);
        if errs.errors.len() != 0 {
            let d = errs.errors.at(0);
            e.message = d.msg.clone();
            e.start = d.start;
            e.end = d.start + d.len;
        }
        return Result::<String, ApiError>::Err(e);
    }
    return Result::<String, ApiError>::Ok(out);
}

/// One replacement in a file: bytes `[start, end)` of its current text become `text`.
pub struct TextEdit {
    pub file: String,
    pub start: u32,
    pub end: u32,
    pub text: String,
}

/// Edits of several files, applied together. `versions` names the file versions (`Session::version`) the
/// edits were made against; a file at another version rejects the whole edit.
pub struct WorkspaceEdit {
    pub edits: Vector<TextEdit>,
    pub versions: Vector<FileVersion>,
}

/// A file and its version.
pub struct FileVersion {
    pub file: String,
    pub version: i64,
}

/// A file's text after an edit.
pub struct EditedFile {
    pub file: String,
    pub text: String,
}

extend WorkspaceEdit {
    pub fn new() WorkspaceEdit {
        return WorkspaceEdit { edits: Vector::<TextEdit>::new(), versions: Vector::<FileVersion>::new() };
    }

    /// Add the replacement of bytes `[start, end)` of `file` by `text`.
    pub fn replace(self: &mut Self, file: str, start: u32, end: u32, text: str) {
        self.edits.push(TextEdit { file: String::from_str(file), start: start, end: end, text: String::from_str(text) });
    }

    /// Require `file` at `version` when the edit applies.
    pub fn expect(self: &mut Self, file: str, version: i64) {
        self.versions.push(FileVersion { file: String::from_str(file), version: version });
    }

    // The changes per file, in first-edit order, checked against the session's texts and versions.
    fn changes(self: &Self, s: &mut ses::Session) Result<Vector<ses::Change>, ApiError> {
        let mut out = Vector::<ses::Change>::new();
        for i in 0..self.edits.len() {
            let e = &self.edits[i];
            let mut k: usize = 0;
            while k < out.len() && out[k].path.as_str() != e.file.as_str() {
                k += 1;
            }
            if k == out.len() {
                let mut v: i64 = -1;
                for j in 0..self.versions.len() {
                    if self.versions[j].file.as_str() == e.file.as_str() {
                        v = self.versions[j].version;
                    }
                }
                out.push(ses::Change { path: e.file.clone(), edits: Vector::<Edit>::new(), expected_version: v });
            }
            out.index_mut(k).edits.push(Edit { start: e.start, end: e.end, text: e.text.clone() });
        }
        for j in 0..self.versions.len() {
            let f = self.versions[j].file.as_str();
            if s.version(f) != self.versions[j].version {
                return Result::<Vector<ses::Change>, ApiError>::Err(
                    ApiError::at(Code::InvalidArgument, "the file is not at the expected version", f, 0, 0),
                );
            }
        }
        return Result::<Vector<ses::Change>, ApiError>::Ok(out);
    }

    /// The texts the edit gives each file it changes, in first-edit order, without applying it: edits sorted
    /// per file, overlaps and stale versions rejected (`InvalidArgument`), and a file that parsed before and
    /// does not parse after rejected (`VerificationFailed`). `apply` applies exactly these texts.
    pub fn preview(self: &Self, s: &mut ses::Session) Result<Vector<EditedFile>, ApiError> {
        let cs = self.changes(s)?;
        let mut out = Vector::<EditedFile>::with_capacity(cs.len());
        for i in 0..cs.len() {
            let path = cs[i].path.as_str();
            let cur = switch s.text(path)? {
                Some(t) => t,
                None => {
                    return Result::<Vector<EditedFile>, ApiError>::Err(
                        ApiError::at(Code::InvalidArgument, "no such file", path, 0, 0),
                    );
                },
            };
            let mut next = String::new();
            if let Err(e) = apply_edits(cur.as_str(), cs[i].edits.as_slice(), &mut next) {
                let mut ee = e;
                ee.file = String::from_str(path);
                return Result::<Vector<EditedFile>, ApiError>::Err(ee);
            }
            let after = SyntaxTree::parse(path, next.as_str());
            if !after.is_valid() && SyntaxTree::parse(path, cur.as_str()).is_valid() {
                let r = after.errors[0].range;
                return Result::<Vector<EditedFile>, ApiError>::Err(
                    ApiError::at(Code::VerificationFailed, after.errors[0].message.as_str(), path, r.start, r.end),
                );
            }
            out.push(EditedFile { file: String::from_str(path), text: next });
        }
        return Result::<Vector<EditedFile>, ApiError>::Ok(out);
    }

    /// Check the edit as `preview` does, then apply it to the session as one change. Returns the session's
    /// new revision.
    pub fn apply(self: &Self, s: &mut ses::Session) Result<u64, ApiError> {
        let files = self.preview(s)?;
        let mut cs = Vector::<ses::Change>::with_capacity(files.len());
        for i in 0..files.len() {
            let mut v: i64 = -1;
            for j in 0..self.versions.len() {
                if self.versions[j].file.as_str() == files[i].file.as_str() {
                    v = self.versions[j].version;
                }
            }
            cs.push(
                ses::Change {
                    path: files[i].file.clone(),
                    edits: Vector::<Edit>::new(),
                    replace: true,
                    text: files[i].text.clone(),
                    expected_version: v,
                },
            );
        }
        return s.apply(cs.as_slice());
    }
}

/// Generated source, line by line, checked by the parser before use. Indentation is four spaces per open
/// block.
pub struct Builder {
    out: String,
    depth: u32,
}

extend Builder {
    pub fn new() Builder {
        return Builder { out: String::new(), depth: 0 };
    }

    /// Add one line at the current indentation.
    pub fn line(self: &mut Self, text: str) {
        for _ in 0..self.depth {
            self.out.push_str("    ");
        }
        self.out.push_str(text);
        self.out.push_byte(b'\n');
    }

    /// Add `head {` and indent the lines after it.
    pub fn open(self: &mut Self, head: str) {
        for _ in 0..self.depth {
            self.out.push_str("    ");
        }
        self.out.push_str(head);
        self.out.push_str(" {\n");
        self.depth += 1;
    }

    /// End the innermost open block with `}`.
    pub fn close(self: &mut Self) {
        if self.depth != 0 {
            self.depth -= 1;
        }
        self.line("}");
    }

    /// The text so far, unchecked.
    pub fn text(self: &Self) str {
        return self.out.as_str();
    }

    /// The text as items of a module, in the canonical format; `ParseFailed` (with the parser's first
    /// error) when it does not parse, or when a block is still open.
    pub fn finish(self: &Self) Result<String, ApiError> {
        if self.depth != 0 {
            return Result::<String, ApiError>::Err(ApiError::new(Code::ParseFailed, "a block is still open"));
        }
        return format_file("<generated>", self.out.as_str(), 120);
    }
}
