// Context-free LL(1) recursive-descent parser: token stream -> one Ast per module. Every fork is
// decided on a single peeked token, no backtracking; the `_after` seams re-enter with an
// already-parsed prefix instead of peeking further (left-factoring, not lookahead). Paren-free
// if/while/switch conditions use a cover grammar -- the ExpressionGrammar argument selects the
// EXPR_CONDITION family, where `Ident {` is a body block not a struct literal -- threaded purely
// structurally (reset to EXPR_FULL inside every delimiter), so it expands to a context-free grammar
// and consults no semantic state. Errors emit and recover locally (skip to a sync token, yield
// NODE_NONE), so parsing always completes and build_ast always produces a NODE_PROGRAM root.
// PARSE_MAX_DEPTH bounds recursion on types, statements, and expressions.
import string as cstring;
import stdlib;
import lexer::token as *;
import lexer::token_type as *;
import ast::ast as *;
import utils::errors as diag;

pub const PARSE_MAX_DEPTH: u32 = 256;

pub enum RangeContext {
    RANGE_FOR,
    RANGE_PATTERN,
    RANGE_EXPR,
}

// EXPR_CONDITION is the paren-free if/while/switch grammar: there `Ident {` is NOT a struct
// initializer -- the '{' belongs to the body block. Delimited subexpressions re-select EXPR_FULL.
enum ExpressionGrammar {
    EXPR_FULL,
    EXPR_CONDITION,
}

// Attribute arguments are captured as a raw token RANGE (arg_start..arg_end), never parsed here:
// each attribute interprets its own slice, so new attr forms need no grammar changes.
struct AttrSyntax {
    pub namespace: Token,
    pub name: Token,
    pub parts: u32,
    pub has_args: bool,
    pub arg_start: usize,
    pub arg_end: usize,
}

// The lexer only ever emits single '>' tokens (so nested generics can close); the parser glues
// '>>', '>=', '>>=' back together. shift_assignment reports a '>>=' discovered deep in the binary
// chain so the expression level can finish it as an assignment.
struct BinaryParse {
    pub expression: NodeId,
    pub shift_assignment: bool,
}

pub struct Parser<'a> {
    pub source: str<'a>,
    pub tokens: Vector<Token>,
    pub current: usize,
    pub depth: u32,
    pub ast: Ast,
    pub file: str<'a>,
    pub errors: diag::Errors,
    pub bootstrap_tags: bool, // accept unknown @attributes without error (bootstrap across a new tag)
    // Named-return context of the function body being parsed (the signature's NODE_PARAMETER return
    // entries): a bare `return;` inside it desugars to returning these bindings. Cleared for closure
    // bodies (closures have their own return list and no named-return support).
    pub nrets: Vector<NodeId>,
    // `@derive(I, ..)` pending on the next item: the interface type nodes parsed from the attribute's
    // token range, expanded into empty `extend T as I {}` siblings when the struct/enum arrives.
    // `expand_derive` is off for the FORMATTER only -- it prints the attribute text verbatim and must
    // not see the synthesized extends.
    pub derive_ifaces: Vector<NodeId>,
    pub derive_start: u32,
    pub derive_end: u32,
    pub expand_derive: bool,
    // `@reflect(key = value, ..)` entries pending on the next declaration; flushed with the owner
    // by add_attrs_to (struct/enum/field/variant only -- anything else is an error).
    pub pending_metas: Vector<MetaAttr>,
}

extend Parser {
    pub fn new<'a>(tokens: Vector<Token>, source: str<'a>, file: str<'a>) Parser<'a> {
        let token_count = tokens.len();
        return Parser {
            source: source,
            tokens: tokens,
            current: 0,
            depth: 0,
            ast: Ast::new(token_count),
            file: file,
            errors: diag::Errors::new(),
            bootstrap_tags: false,
            nrets: Vector::<NodeId>::new(),
            derive_ifaces: Vector::<NodeId>::new(),
            derive_start: 0,
            derive_end: 0,
            expand_derive: true,
            pending_metas: Vector::<MetaAttr>::new(),
        };
    }

    pub const fn set_bootstrap_tags(self: &mut Self, v: bool) {
        self.bootstrap_tags = v;
    }

    pub fn take_tokens(self: &mut Self) Vector<Token> {
        let t = replace(&mut self.tokens, Vector::<Token>::new());
        return t;
    }

    pub fn take_ast(self: &mut Self) Ast {
        let out = replace(&mut self.ast, Ast::new(0));
        return out;
    }

    pub const fn raw_peek(self: &Self) Token {
        return self.tokens[self.current];
    }

    pub const fn peek_type(self: &Self) TokenType {
        return self.raw_peek().kind();
    }

    pub const fn at_end(self: &Self) bool {
        return self.peek_type() == TokenType::Eof;
    }

    pub const fn advance(self: &mut Self) Token {
        let t = self.raw_peek();
        if t.kind() != TokenType::Eof {
            self.current = self.current + 1;
        }
        return t;
    }

    pub const fn check(self: &Self, kind: TokenType) bool {
        return self.peek_type() == kind;
    }

    pub const fn text_is(self: &Self, t: Token, s: str) bool {
        let sl = s.len();
        return t.len() as usize == sl && unsafe cstring::memcmp(
            unsafe (self.source.ptr() + t.start() as usize),
            s.ptr(),
            sl,
        ) == 0;
    }

    pub const fn match(self: &mut Self, kind: TokenType) bool {
        if !self.check(kind) {
            return false;
        }
        self.advance();
        return true;
    }

    pub const fn previous_end(self: &Self) u32 {
        if self.current != 0 {
            return self.tokens[self.current - 1].end();
        }
        return 0;
    }

    pub const fn node_span(self: &Self, id: NodeId) Span {
        if id == NODE_NONE {
            return Span::empty();
        }
        return self.ast.at_const(id).span;
    }

    @c.cold
    pub fn error_here(self: &mut Self, message: str) {
        let t = self.raw_peek();
        self.errors.emit(t.start(), t.len(), String::from_str(message));
    }

    @c.cold
    fn expect_fail(self: &mut Self, display: str) bool {
        let t = self.raw_peek();
        self.errors.emit(t.start(), t.len(), format("expected {}", display));
        return false;
    }

    pub fn expect(self: &mut Self, kind: TokenType, display: str) bool {
        if self.match(kind) {
            return true;
        }
        return self.expect_fail(display);
    }

    pub fn consume_type_gt(self: &mut Self) bool {
        return self.expect(TokenType::GreaterThan, "'>'");
    }

    pub const fn is_type_start(kind: TokenType) bool {
        return Parser::is_identifier_token(kind) || kind == TokenType::SelfUpper || kind == TokenType::Star || kind == TokenType::Ampersand || kind == TokenType::LeftBracket || kind == TokenType::Fn;
    }

    pub const fn is_identifier_token(kind: TokenType) bool {
        return kind == TokenType::Identifier || kind == TokenType::Underscore || kind == TokenType::Static || kind == TokenType::StaticAssert || kind == TokenType::VaStart || kind == TokenType::VaArg || kind == TokenType::VaEnd;
    }

    @c.always_inline
    pub fn identifier(self: &mut Self) NodeId {
        if !Parser::is_identifier_token(self.peek_type()) && !self.check(TokenType::SelfUpper) {
            self.error_here("expected identifier");
            if !self.at_end() {
                self.advance();
            }
            return NODE_NONE;
        }
        let token = self.advance();
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_IDENTIFIER,
                span: token.span(),
                as_data: NodeAs { name: NameData { text: token.span(), is_mutable: false } },
            },
        );
    }

    // A lifetime name (`'a`). The lexer already emits `'name` as a `Label` (loop labels share the
    // surface syntax and `label_ahead` already separates `'a` from the char literal `'a'`), so a
    // `Label` appearing in a type / generic-param / generic-arg / bound slot IS a lifetime -- a
    // `Label` can begin none of those otherwise, which keeps every use site single-token LL(1).
    pub fn parse_lifetime(self: &mut Self) NodeId {
        if !self.check(TokenType::Label) {
            self.error_here("expected a lifetime");
            return NODE_NONE;
        }
        let token = self.advance();
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_LIFETIME,
                span: token.span(),
                as_data: NodeAs { name: NameData { text: token.span(), is_mutable: false } },
            },
        );
    }

    // The outlives bounds of a LIFETIME param: `'a: 'b + 'c`. These can only ever be lifetimes, so
    // after a `+` we parse one unconditionally -- no lookahead past the `+` is needed (a type
    // param's mixed `T: 'a + Iface` list goes through parse_bounds/parse_bound instead).
    pub fn parse_lifetime_bounds(self: &mut Self) NodeList {
        let mark = self.ast.mark();
        self.ast.push(self.parse_lifetime());
        while self.match(TokenType::Plus) {
            self.ast.push(self.parse_lifetime());
        }
        return self.ast.commit(mark);
    }

    @c.always_inline
    pub fn callable_name(self: &mut Self) NodeId {
        if !Parser::is_identifier_token(self.peek_type()) && !self.check(TokenType::SelfUpper) && !self.check(
            TokenType::New,
        ) {
            self.error_here("expected identifier");
            if !self.at_end() {
                self.advance();
            }
            return NODE_NONE;
        }
        let token = self.advance();
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_IDENTIFIER,
                span: token.span(),
                as_data: NodeAs { name: NameData { text: token.span(), is_mutable: false } },
            },
        );
    }

    pub fn literal(self: &mut Self) NodeId {
        let token = self.advance();
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_LITERAL,
                span: token.span(),
                as_data: NodeAs { literal: LiteralData { raw: token.span(), token_type: token.kind(), seg: false } },
            },
        );
    }

    // A non-empty verbatim segment of an interpolating matchertext literal, as a seg literal (the
    // raw span IS the content; nothing to strip at decode time).
    fn push_mt_seg(self: &mut Self, from: u32, to: u32) {
        if to <= from {
            return;
        }
        let n = self.ast.add(
            Node {
                kind: NodeKind::NODE_LITERAL,
                span: Span::new(from, to),
                as_data: NodeAs {
                    literal: LiteralData {
                        raw: Span::new(from, to),
                        token_type: TokenType::MatchertextLiteral,
                        seg: true,
                    },
                },
            },
        );
        self.ast.push(n);
    }

    // `M{}"(a {hole} b)"`: a MatchertextBegin token, hole expressions lexed as ordinary tokens,
    // MatchertextMid segments between holes, a MatchertextEnd closing. Children alternate verbatim
    // segment literals and hole expressions (empty segments are dropped).
    fn parse_matchertext_interp(self: &mut Self) NodeId {
        let begin = self.advance();
        let start = begin.start();
        // the delimiter chain sits between the `M` and the `"`, openers then closers
        let mut q = start + 1;
        while self.source[q as usize] != b'"' {
            q = q + 1;
        }
        let dn = (q - start - 1) / 2;
        let mark = self.ast.mark();
        self.push_mt_seg(q + 2, begin.end() - dn);
        loop {
            if self.check(TokenType::MatchertextMid) || self.check(TokenType::MatchertextEnd) {
                let t = self.raw_peek();
                self.errors.emit(t.start(), t.len(), format("matchertext interpolation hole is empty"));
            } else {
                let e = self.parse_expression();
                self.ast.push(e);
            }
            if self.check(TokenType::MatchertextMid) {
                let t = self.advance();
                self.push_mt_seg(t.start() + dn, t.end() - dn);
                continue;
            }
            if self.check(TokenType::MatchertextEnd) {
                let t = self.advance();
                self.push_mt_seg(t.start() + dn, t.end() - 2);
                break;
            }
            let t = self.raw_peek();
            self.errors.emit(t.start(), t.len(), format("expected the rest of the matchertext literal"));
            break;
        }
        let kids = self.ast.commit(mark);
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_INTERP,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { block: BlockData { statements: kids } },
            },
        );
    }

    pub fn parse_comma_types(self: &mut Self, close: TokenType) NodeList {
        let mark = self.ast.mark();
        while !self.check(close) && !self.at_end() {
            let ty = self.parse_type();
            self.ast.push(ty);
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        return self.ast.commit(mark);
    }

    pub fn parse_type_args(self: &mut Self) NodeList {
        self.expect(TokenType::LessThan, "'<'");
        let mark = self.ast.mark();
        while !self.check(TokenType::GreaterThan) && !self.at_end() {
            // A leading lifetime is a lifetime ARGUMENT (`Foo<'a, T>`); a bare integer literal is a
            // const-generic value (e.g. `Buff<i32, 4>`). Both are single-token decisions. This is the
            // shared reader for type paths AND expression turbofish, so one arm covers `Foo::<'a, T>`.
            // A braced argument is a const-generic EXPRESSION (`UInt<{BITS * 2}>`). Braces because a bare
            // expression is not decidable from one token here -- `A<B * 2>` cannot be told from a type
            // until well past the `<` -- and the grammar stays LL(1) by asking for them.
            let arg = if self.check(TokenType::Label) {
                self.parse_lifetime();
            } else if self.check(TokenType::IntegerLiteral) {
                self.literal();
            } else if self.check(TokenType::LeftBrace) {
                self.advance();
                let e = self.parse_expression();
                self.expect(TokenType::RightBrace, "'}'");
                e;
            } else {
                self.parse_type();
            };
            self.ast.push(arg);
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        let args = self.ast.commit(mark);
        self.consume_type_gt();
        return args;
    }

    pub fn parse_type_path_after(self: &mut Self, head: NodeId, start: u32) NodeId {
        let mark = self.ast.mark();
        self.ast.push(head);
        while self.match(TokenType::PathSeparator) {
            self.ast.push(self.identifier());
        }
        let parts = self.ast.commit(mark);
        let args = if self.check(TokenType::LessThan) {
            self.parse_type_args();
        } else {
            NodeList { start: 0, len: 0 };
        };
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_TYPE_PATH,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { type_path: TypePathData { parts: parts, args: args } },
            },
        );
    }

    pub fn parse_type_path(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        let head = self.identifier();
        return self.parse_type_path_after(head, start);
    }

    // Cast targets take no generic args: '<' after 'x as T' must remain the comparison operator.
    pub fn parse_cast_type(self: &mut Self) NodeId {
        if !Parser::is_identifier_token(self.peek_type()) && !self.check(TokenType::SelfUpper) {
            return self.parse_type();
        }
        let start = self.raw_peek().start();
        let mark = self.ast.mark();
        self.ast.push(self.identifier());
        while self.match(TokenType::PathSeparator) {
            self.ast.push(self.identifier());
        }
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_TYPE_PATH,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs {
                    type_path: TypePathData { parts: self.ast.commit(mark), args: NodeList { start: 0, len: 0 } },
                },
            },
        );
    }

    pub const fn parse_qualifier(self: &mut Self) TypeQualifier {
        if self.match(TokenType::Const) {
            return TypeQualifier::TYPE_QUAL_CONST;
        }
        if self.match(TokenType::Mut) {
            return TypeQualifier::TYPE_QUAL_MUT;
        }
        return TypeQualifier::TYPE_QUAL_NONE;
    }

    pub fn parse_type(self: &mut Self) NodeId {
        if self.depth >= PARSE_MAX_DEPTH {
            self.error_here("type nested too deeply");
            if !self.at_end() {
                self.advance();
            }
            return NODE_NONE;
        }
        self.depth = self.depth + 1;
        let t = self.parse_type_inner();
        self.depth = self.depth - 1;
        return t;
    }

    pub fn parse_type_inner(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        if self.match(TokenType::Star) || self.match(TokenType::Ampersand) {
            let opener = self.tokens[self.current - 1].kind();
            // `&'a T` / `&'a mut T`: the lifetime binds immediately after `&`, before `mut`/`dyn`.
            // Single-token peek; pointers never carry one.
            let mut life = NODE_NONE;
            if opener == TokenType::Ampersand && self.check(TokenType::Label) {
                life = self.parse_lifetime();
            }
            let mut qualifier: TypeQualifier;
            if opener == TokenType::Star {
                qualifier = self.parse_qualifier();
            } else if self.match(TokenType::Mut) {
                qualifier = TypeQualifier::TYPE_QUAL_MUT;
            } else {
                qualifier = TypeQualifier::TYPE_QUAL_NONE;
                if self.check(TokenType::Const) {
                    self.error_here("references use '&T' or '&mut T', not '&const T'");
                    self.advance();
                }
            }
            if opener == TokenType::Ampersand && self.match(TokenType::Dyn) {
                let inner = self.parse_type();
                return self.ast.add(
                    Node {
                        kind: NodeKind::NODE_DYN_TYPE,
                        span: Span::new(start, self.node_span(inner).end),
                        as_data: NodeAs {
                            indirect_type: IndirectTypeData {
                                ty: inner,
                                qualifier: if qualifier == TypeQualifier::TYPE_QUAL_MUT {
                                    TypeQualifier::TYPE_QUAL_MUT;
                                } else {
                                    TypeQualifier::TYPE_QUAL_CONST;
                                },
                                lifetime: life,
                            },
                        },
                    },
                );
            }
            let ty = self.parse_type();
            return self.ast.add(
                Node {
                    kind: if opener == TokenType::Star {
                        NodeKind::NODE_POINTER_TYPE;
                    } else {
                        NodeKind::NODE_REFERENCE_TYPE;
                    },
                    span: Span::new(start, self.node_span(ty).end),
                    as_data: NodeAs { indirect_type: IndirectTypeData { ty: ty, qualifier: qualifier, lifetime: life } },
                },
            );
        }
        if self.match(TokenType::LeftBracket) {
            if self.match(TokenType::RightBracket) {
                let qualifier = if self.match(TokenType::Mut) {
                    TypeQualifier::TYPE_QUAL_MUT;
                } else {
                    TypeQualifier::TYPE_QUAL_NONE;
                };
                let element = self.parse_type();
                return self.ast.add(
                    Node {
                        kind: NodeKind::NODE_SLICE_TYPE,
                        span: Span::new(start, self.node_span(element).end),
                        as_data: NodeAs { indirect_type: IndirectTypeData { ty: element, qualifier: qualifier } },
                    },
                );
            }
            let element = self.parse_type();
            self.expect(TokenType::Semicolon, "';'");
            let length = self.parse_expression();
            self.expect(TokenType::RightBracket, "']'");
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_ARRAY_TYPE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { array_type: ArrayTypeData { element: element, length: length } },
                },
            );
        }
        if self.match(TokenType::Fn) {
            self.expect(TokenType::LeftParen, "'('");
            let params = self.parse_comma_types(TokenType::RightParen);
            self.expect(TokenType::RightParen, "')'");
            let returns = self.parse_function_returns();
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_FUNCTION_TYPE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs {
                        function_type: FunctionTypeData { params: params, returns: returns, is_move: false },
                    },
                },
            );
        }
        if self.match(TokenType::LeftParen) {
            let elems = self.parse_comma_types(TokenType::RightParen);
            self.expect(TokenType::RightParen, "')'");
            if elems.len < 2 {
                self.errors.emit(start, self.previous_end() - start, format("a tuple type needs at least 2 elements"));
            }
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_TUPLE_TYPE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { array_literal: ArrayLiteralData { elements: elems, repeat: false } },
                },
            );
        }
        if self.match(TokenType::Dyn) {
            let inner = self.parse_type();
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_DYN_TYPE,
                    span: Span::new(start, self.node_span(inner).end),
                    as_data: NodeAs {
                        indirect_type: IndirectTypeData { ty: inner, qualifier: TypeQualifier::TYPE_QUAL_NONE },
                    },
                },
            );
        }
        if Parser::is_identifier_token(self.peek_type()) || self.check(TokenType::SelfUpper) {
            return self.parse_type_path();
        }
        self.error_here("expected type");
        if !self.at_end() {
            self.advance();
        }
        return NODE_NONE;
    }

    // `for<'a, 'b>` -- the HIGHER-RANKED prefix of a bound. These lifetimes are bound by the BOUND
    // rather than the enclosing item: the value must satisfy it for EVERY choice of them, which is what
    // lets a closure bound accept a reference of any lifetime instead of one fixed at instantiation.
    // LL(1): `for` cannot otherwise begin a bound or a type, so a single-token peek decides.
    pub fn parse_hrtb(self: &mut Self) NodeList {
        if !self.match(TokenType::For) {
            return NodeList { start: 0, len: 0 };
        }
        self.expect(TokenType::LessThan, "'<'");
        let mark = self.ast.mark();
        while self.check(TokenType::Label) && !self.at_end() {
            // Wrapped as NODE_GENERIC_PARAM, exactly as parse_generics_split produces for a declared
            // `<'a>`, so every consumer of a lifetime list (the side table, tc_lt_name, the formatter)
            // sees one shape. A bare NODE_LIFETIME here is read through the wrong union member.
            let lstart = self.previous_end();
            let lt = self.parse_lifetime();
            self.ast.push(
                self.ast.add(
                    Node {
                        kind: NodeKind::NODE_GENERIC_PARAM,
                        span: Span::new(lstart, self.previous_end()),
                        as_data: NodeAs {
                            generic_param: GenericParamData {
                                name: lt,
                                bounds: NodeList { start: 0, len: 0 },
                                default_type: NODE_NONE,
                                is_const: false,
                                const_type: NODE_NONE,
                                is_lifetime: true,
                            },
                        },
                    },
                ),
            );
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        self.expect(TokenType::GreaterThan, "'>'");
        return self.ast.commit(mark);
    }

    pub fn parse_bound(self: &mut Self) NodeId {
        // `T: 'a` -- a lifetime bound among a type param's mixed bounds. Single-token peek.
        if self.check(TokenType::Label) {
            return self.parse_lifetime();
        }
        let hr = self.parse_hrtb();
        if !self.check(TokenType::Fn) {
            let tp = self.parse_type_path();
            if hr.len != 0 {
                self.ast.set_lifetimes(tp, hr);
            }
            return tp;
        }
        let start = self.raw_peek().start();
        self.advance();
        let is_move = self.match(TokenType::Move);
        self.expect(TokenType::LeftParen, "'('");
        let params = self.parse_comma_types(TokenType::RightParen);
        self.expect(TokenType::RightParen, "')'");
        let returns = self.parse_function_returns();
        let fnty = self.ast.add(
            Node {
                kind: NodeKind::NODE_FUNCTION_TYPE,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs {
                    function_type: FunctionTypeData { params: params, returns: returns, is_move: is_move },
                },
            },
        );
        if hr.len != 0 {
            self.ast.set_lifetimes(fnty, hr);
        }
        return fnty;
    }

    pub fn parse_bounds(self: &mut Self) NodeList {
        let mark = self.ast.mark();
        self.ast.push(self.parse_bound());
        while self.match(TokenType::Plus) {
            self.ast.push(self.parse_bound());
        }
        return self.ast.commit(mark);
    }

    // Parses `<'a, 'b: 'a, T, const N: usize>`. LIFETIME params must come FIRST (as in Rust) and are
    // returned SEPARATELY through `out_lifetimes`: keeping them out of the `generics` list is what
    // makes lifetime erasure structural -- every consumer that pairs `generics` with instance args
    // stays correct by construction instead of having to remember to skip lifetimes.
    pub fn parse_generics_split(self: &mut Self, out_lifetimes: &mut NodeList) NodeList {
        if !self.match(TokenType::LessThan) {
            return NodeList { start: 0, len: 0 };
        }
        // leading run of lifetime params -> its own contiguous list
        let lmark = self.ast.mark();
        while self.check(TokenType::Label) && !self.at_end() {
            let start = self.raw_peek().start();
            let lt = self.parse_lifetime();
            let mut lbounds = NodeList { start: 0, len: 0 };
            if self.match(TokenType::Colon) {
                lbounds = self.parse_lifetime_bounds();
            }
            self.ast.push(
                self.ast.add(
                    Node {
                        kind: NodeKind::NODE_GENERIC_PARAM,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs {
                            generic_param: GenericParamData {
                                name: lt,
                                bounds: lbounds,
                                default_type: NODE_NONE,
                                is_const: false,
                                const_type: NODE_NONE,
                                is_lifetime: true,
                            },
                        },
                    },
                ),
            );
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        *out_lifetimes = self.ast.commit(lmark);
        let mark = self.ast.mark();
        while !self.check(TokenType::GreaterThan) && !self.at_end() {
            let start = self.raw_peek().start();
            if self.check(TokenType::Label) {
                self.error_here("lifetime parameters must come before type parameters");
                self.advance();
                continue;
            }
            let is_const = self.match(TokenType::Const);
            let name = self.identifier();
            let mut bounds = NodeList { start: 0, len: 0 };
            let mut const_type = NODE_NONE;
            if is_const {
                self.expect(TokenType::Colon, "':'");
                const_type = self.parse_type();
            } else if self.match(TokenType::Colon) {
                bounds = self.parse_bounds();
            }
            // A const parameter's default is written as a value, but every value that can default one --
            // a literal, a named constant -- parses as a type, so one parse serves both kinds.
            let default_type = if self.match(TokenType::Equal) {
                self.parse_type();
            } else {
                NODE_NONE;
            };
            self.ast.push(
                self.ast.add(
                    Node {
                        kind: NodeKind::NODE_GENERIC_PARAM,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs {
                            generic_param: GenericParamData {
                                name: name,
                                bounds: bounds,
                                default_type: default_type,
                                is_const: is_const,
                                const_type: const_type,
                                is_lifetime: false,
                            },
                        },
                    },
                ),
            );
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        self.consume_type_gt();
        return self.ast.commit(mark);
    }

    pub fn parse_where_clause(self: &mut Self) NodeList {
        if !self.match(TokenType::Where) {
            return NodeList { start: 0, len: 0 };
        }
        let mark = self.ast.mark();
        while true {
            let start = self.raw_peek().start();
            // `where 'a: 'b` -- a lifetime on the LHS; bounds are then lifetimes only.
            let lhs_is_lifetime = self.check(TokenType::Label);
            let ty = if lhs_is_lifetime {
                self.parse_lifetime();
            } else {
                self.parse_type();
            };
            self.expect(TokenType::Colon, "':'");
            let bounds = if lhs_is_lifetime {
                self.parse_lifetime_bounds();
            } else {
                self.parse_bounds();
            };
            self.ast.push(
                self.ast.add(
                    Node {
                        kind: NodeKind::NODE_WHERE_PREDICATE,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { where_predicate: WherePredicateData { ty: ty, bounds: bounds } },
                    },
                ),
            );
            if !self.match(TokenType::Comma) || self.check(TokenType::LeftBrace) || self.check(TokenType::Semicolon) {
                break;
            }
        }
        return self.ast.commit(mark);
    }

    pub fn parse_parameter_name(self: &mut Self) NodeId {
        if self.match(TokenType::SelfLower) {
            let token = self.tokens[self.current - 1];
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_IDENTIFIER,
                    span: token.span(),
                    as_data: NodeAs { name: NameData { text: token.span(), is_mutable: false } },
                },
            );
        }
        let is_mut = self.match(TokenType::Mut);
        let id = self.identifier();
        if is_mut && id != NODE_NONE {
            self.ast.at(id).as_data.name.is_mutable = true;
        }
        return id;
    }

    pub fn parse_parameters(self: &mut Self, out_variadic: &mut bool) NodeList {
        self.expect(TokenType::LeftParen, "'('");
        let params_mark = self.ast.mark();
        while !self.check(TokenType::RightParen) && !self.at_end() {
            if self.match(TokenType::Ellipsis) {
                *out_variadic = true;
                break;
            }
            let names_mark = self.ast.mark();
            self.ast.push(self.parse_parameter_name());
            while !self.check(TokenType::Colon) && !self.at_end() {
                self.expect(TokenType::Comma, "','");
                if self.check(TokenType::RightParen) {
                    break;
                }
                self.ast.push(self.parse_parameter_name());
            }
            let names = self.ast.commit(names_mark);
            self.expect(TokenType::Colon, "':'");
            let ty = self.parse_type();
            for i in 0..names.len {
                let name = *self.ast.children.at((names.start + i) as usize);
                let span_start = self.node_span(name).start;
                let span_end = self.node_span(ty).end;
                let is_mutable = self.ast.at_const(name).as_data.name.is_mutable;
                let param = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_PARAMETER,
                        span: Span::new(span_start, span_end),
                        as_data: NodeAs { parameter: ParameterData { name: name, ty: ty, is_mutable: is_mutable } },
                    },
                );
                self.ast.push(param);
            }
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        self.expect(TokenType::RightParen, "')'");
        return self.ast.commit(params_mark);
    }

    pub fn parse_function_returns(self: &mut Self) NodeList {
        if !self.check(TokenType::LeftParen) && !Parser::is_type_start(self.peek_type()) {
            return NodeList { start: 0, len: 0 };
        }
        let mark = self.ast.mark();
        if !self.match(TokenType::LeftParen) {
            self.ast.push(self.parse_type());
            return self.ast.commit(mark);
        }
        while !self.check(TokenType::RightParen) && !self.at_end() {
            if Parser::is_identifier_token(self.peek_type()) {
                let start = self.raw_peek().start();
                let head = self.identifier();
                if self.match(TokenType::Colon) {
                    let ty = self.parse_type();
                    self.ast.push(
                        self.ast.add(
                            Node {
                                kind: NodeKind::NODE_PARAMETER,
                                span: Span::new(start, self.node_span(ty).end),
                                as_data: NodeAs { parameter: ParameterData { name: head, ty: ty, is_mutable: false } },
                            },
                        ),
                    );
                } else {
                    let tp = self.parse_type_path_after(head, start);
                    self.ast.push(tp);
                }
            } else {
                self.ast.push(self.parse_type());
            }
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        let returns = self.ast.commit(mark);
        self.expect(TokenType::RightParen, "')'");
        if returns.len == 1 && self.ast.at_const(unsafe self.ast.list(returns)[0]).kind != NodeKind::NODE_PARAMETER {
            self.error_here("a single unnamed return type must not be parenthesized");
        }
        return returns;
    }

    pub fn parse_function(self: &mut Self, require_body: bool) NodeId {
        let start = self.raw_peek().start();
        self.expect(TokenType::Fn, "'fn'");
        let name = self.callable_name();
        let mut lifetimes = NodeList { start: 0, len: 0 };
        let generics = self.parse_generics_split(&mut lifetimes);
        let mut is_variadic = false;
        let params = self.parse_parameters(&mut is_variadic);
        let returns = self.parse_function_returns();
        let where_clause = self.parse_where_clause();
        // Go-style named returns: `(ret: bool)` binds `ret` in the body as an implicitly declared
        // `let mut ret: bool;` (definite assignment enforced by the usual uninitialized tracking),
        // and a bare `return;` returns the named bindings. All-or-none named.
        let mut nnamed: u32 = 0;
        for i in 0..returns.len {
            if self.ast.at_const(unsafe self.ast.list(returns)[i as usize]).kind == NodeKind::NODE_PARAMETER {
                nnamed += 1;
            }
        }
        if nnamed != 0 && nnamed != returns.len {
            self.error_here("either all return values are named or none");
        }
        let outer_nrets = replace(&mut self.nrets, Vector::<NodeId>::new());
        if nnamed != 0 && nnamed == returns.len {
            for i in 0..returns.len {
                self.nrets.push(unsafe self.ast.list(returns)[i as usize]);
            }
        }
        let mut body = NODE_NONE;
        if self.check(TokenType::LeftBrace) {
            body = self.parse_block();
        } else if require_body {
            self.error_here("expected function body");
        }
        if self.nrets.len() != 0 && body != NODE_NONE {
            self.bind_named_returns(body);
        }
        self.nrets = outer_nrets;
        let __decl = self.ast.add(
            Node {
                kind: NodeKind::NODE_FUNCTION,
                span: Span::new(
                    start,
                    if body != NODE_NONE {
                        self.node_span(body).end;
                    } else {
                        self.previous_end();
                    },
                ),
                as_data: NodeAs {
                    function: FunctionData {
                        name: name,
                        generics: generics,
                        params: params,
                        returns: returns,
                        where_clause: where_clause,
                        body: body,
                        is_public: false,
                        is_extern: false,
                        is_variadic: is_variadic,
                        is_const: false,
                        is_unsafe: false,
                    },
                },
            },
        );
        self.ast.set_lifetimes(__decl, lifetimes);
        return __decl;
    }

    /// Re-parse ONE function body in place (the LSP's incremental body path): the parser holds the
    /// module's EXISTING arena and a token stream over the module's NEW source; `at` indexes the
    /// body's '{' token. Appends the new block's nodes (every old node id stays valid), rebuilding
    /// the named-return context from the fn's own (id-stable) returns list, and returns the block id
    /// (NODE_NONE + a recorded error on a malformed body). The caller re-points the fn's body.
    pub fn reparse_fn_body(self: &mut Self, at: usize, fnid: NodeId) NodeId {
        self.current = at;
        let returns = self.ast.at_const(fnid).as_data.function.returns;
        let mut nnamed: u32 = 0;
        for i in 0..returns.len {
            if self.ast.at_const(unsafe self.ast.list(returns)[i as usize]).kind == NodeKind::NODE_PARAMETER {
                nnamed += 1;
            }
        }
        let outer_nrets = replace(&mut self.nrets, Vector::<NodeId>::new());
        if nnamed != 0 && nnamed == returns.len {
            for i in 0..returns.len {
                self.nrets.push(unsafe self.ast.list(returns)[i as usize]);
            }
        }
        let mut body = NODE_NONE;
        if self.check(TokenType::LeftBrace) {
            body = self.parse_block();
        } else {
            self.error_here("expected function body");
        }
        if self.nrets.len() != 0 && body != NODE_NONE {
            self.bind_named_returns(body);
        }
        self.nrets = outer_nrets;
        return body;
    }

    // Prepend one synthetic `let mut <name>: <ty>;` per named return to `body`'s statements. The
    // let/name spans are the SIGNATURE spans (before the block starts): downstream stages treat them
    // as ordinary uninitialized bindings, and the formatter skips pre-block statements when printing.
    fn bind_named_returns(self: &mut Self, body: NodeId) {
        let stmts = self.ast.at_const(body).as_data.block.statements;
        let mark = self.ast.mark();
        for i in 0..self.nrets.len() {
            let r = *self.nrets.at(i);
            let pd = self.ast.at_const(r).as_data.parameter;
            let ntext = self.ast.at_const(pd.name).as_data.name.text;
            let nspan = self.ast.at_const(pd.name).span;
            let nm = self.ast.add(
                Node {
                    kind: NodeKind::NODE_IDENTIFIER,
                    span: nspan,
                    as_data: NodeAs { name: NameData { text: ntext, is_mutable: false } },
                },
            );
            let rspan = self.ast.at_const(r).span;
            self.ast.push(
                self.ast.add(
                    Node {
                        kind: NodeKind::NODE_LET,
                        span: rspan,
                        as_data: NodeAs {
                            let_stmt: LetData { name: nm, ty: pd.ty, value: NODE_NONE, is_mutable: true },
                        },
                    },
                ),
            );
        }
        for i in 0..stmts.len {
            self.ast.push(unsafe self.ast.list(stmts)[i as usize]);
        }
        let ns = self.ast.commit(mark);
        self.ast.at(body).as_data.block.statements = ns;
    }

    pub fn parse_field(self: &mut Self) NodeId {
        let mut fattrs = self.parse_attributes(4);
        self.reject_derive_here();
        // span starts AFTER the attributes: the formatter prints them as leading trivia from the
        // inter-field gap, so the field's own span must not swallow them
        let start = self.raw_peek().start();
        let is_public = self.match(TokenType::Pub);
        let name = self.identifier();
        self.expect(TokenType::Colon, "':'");
        let ty = self.parse_type();
        let fid = self.ast.add(
            Node {
                kind: NodeKind::NODE_FIELD,
                span: Span::new(start, self.node_span(ty).end),
                as_data: NodeAs { field: FieldData { name: name, ty: ty, value: NODE_NONE, is_public: is_public } },
            },
        );
        if fattrs.len() > 0 {
            let sp0 = self.ast.at_const(fid).span;
            self.errors.emit(sp0.start, sp0.end - sp0.start, format("only '@reflect' applies to a field declaration"));
        }
        self.add_attrs_to(&mut fattrs, fid);
        return fid;
    }

    pub fn parse_fields(self: &mut Self) NodeList {
        let mark = self.ast.mark();
        while !self.check(TokenType::RightBrace) && !self.at_end() {
            self.ast.push(self.parse_field());
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        return self.ast.commit(mark);
    }

    pub fn parse_struct(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let name = self.identifier();
        let mut lifetimes = NodeList { start: 0, len: 0 };
        let generics = self.parse_generics_split(&mut lifetimes);
        if self.match(TokenType::Semicolon) {
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_STRUCT,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs {
                        aggregate: AggregateData {
                            name: name,
                            generics: generics,
                            members: NodeList { start: 0, len: 0 },
                            is_public: false,
                            is_union: false,
                            is_tuple: false,
                            is_extern: false,
                        },
                    },
                },
            );
        }
        if self.match(TokenType::LeftParen) {
            let types = self.parse_comma_types(TokenType::RightParen);
            self.expect(TokenType::RightParen, "')'");
            self.expect(TokenType::Semicolon, "';'");
            let __tdecl = self.ast.add(
                Node {
                    kind: NodeKind::NODE_STRUCT,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs {
                        aggregate: AggregateData {
                            name: name,
                            generics: generics,
                            members: types,
                            is_public: false,
                            is_union: false,
                            is_tuple: true,
                            is_extern: false,
                        },
                    },
                },
            );
            self.ast.set_lifetimes(__tdecl, lifetimes);
            return __tdecl;
        }
        self.expect(TokenType::LeftBrace, "'{'");
        let fields = self.parse_fields();
        self.expect(TokenType::RightBrace, "'}'");
        let __decl = self.ast.add(
            Node {
                kind: NodeKind::NODE_STRUCT,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs {
                    aggregate: AggregateData {
                        name: name,
                        generics: generics,
                        members: fields,
                        is_public: false,
                        is_union: false,
                        is_tuple: false,
                        is_extern: false,
                    },
                },
            },
        );
        self.ast.set_lifetimes(__decl, lifetimes);
        return __decl;
    }

    pub fn parse_variant(self: &mut Self) NodeId {
        let mut vattrs = self.parse_attributes(4);
        self.reject_derive_here();
        let start = self.raw_peek().start();
        let saved_metas = replace(&mut self.pending_metas, Vector::<MetaAttr>::new());
        let name = self.identifier();
        let mut payload = NodeList { start: 0, len: 0 };
        let mut struct_payload = false;
        let mut value = NODE_NONE;
        if self.match(TokenType::LeftParen) {
            payload = self.parse_comma_types(TokenType::RightParen);
            self.expect(TokenType::RightParen, "')'");
        } else if self.match(TokenType::LeftBrace) {
            struct_payload = true;
            payload = self.parse_fields();
            self.expect(TokenType::RightBrace, "'}'");
        } else if self.match(TokenType::Equal) {
            value = self.parse_expression();
        }
        let vid = self.ast.add(
            Node {
                kind: NodeKind::NODE_VARIANT,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs {
                    variant: VariantData { name: name, payload: payload, struct_payload: struct_payload, value: value },
                },
            },
        );
        if vattrs.len() > 0 {
            let sp0 = self.ast.at_const(vid).span;
            self.errors.emit(sp0.start, sp0.end - sp0.start, format("only '@reflect' applies to a variant declaration"));
        }
        self.pending_metas.free();
        self.pending_metas = saved_metas;
        self.add_attrs_to(&mut vattrs, vid);
        return vid;
    }

    pub fn parse_enum(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let name = self.identifier();
        let mut lifetimes = NodeList { start: 0, len: 0 };
        let generics = self.parse_generics_split(&mut lifetimes);
        self.expect(TokenType::LeftBrace, "'{'");
        let mark = self.ast.mark();
        while !self.check(TokenType::RightBrace) && !self.at_end() {
            self.ast.push(self.parse_variant());
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        let variants = self.ast.commit(mark);
        self.expect(TokenType::RightBrace, "'}'");
        let __decl = self.ast.add(
            Node {
                kind: NodeKind::NODE_ENUM,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs {
                    aggregate: AggregateData {
                        name: name,
                        generics: generics,
                        members: variants,
                        is_public: false,
                        is_union: false,
                        is_tuple: false,
                        is_extern: false,
                    },
                },
            },
        );
        self.ast.set_lifetimes(__decl, lifetimes);
        return __decl;
    }

    pub fn parse_type_alias(self: &mut Self, opaque: bool) NodeId {
        let start = self.raw_peek().start();
        self.expect(TokenType::Type, "'type'");
        let name = self.identifier();
        // A type alias -- including an ASSOCIATED type in an interface -- may be parameterised by a
        // lifetime (`type Item<'a>;`). That is what a lending iterator needs: each item borrows the
        // iterator for a lifetime the impl chooses per call rather than one fixed by the interface.
        // Parsed on BOTH paths: an interface's associated type takes the `opaque` route (no `= type`),
        // and that is exactly where a GAT is declared. With no `<` this reads nothing, so an opaque FFI
        // type is unaffected.
        let mut lifetimes = NodeList { start: 0, len: 0 };
        let generics = self.parse_generics_split(&mut lifetimes);
        let mut ty = NODE_NONE;
        if !opaque || self.match(TokenType::Equal) {
            if !opaque {
                self.expect(TokenType::Equal, "'='");
            }
            ty = self.parse_type();
        }
        self.expect(TokenType::Semicolon, "';'");
        let alias = self.ast.add(
            Node {
                kind: NodeKind::NODE_TYPE_ALIAS,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs {
                    type_alias: TypeAliasData { name: name, generics: generics, ty: ty, is_public: false },
                },
            },
        );
        self.ast.set_lifetimes(alias, lifetimes);
        return alias;
    }

    pub fn parse_const(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        if self.check(TokenType::Fn) {
            self.error_here("'const fn' is only allowed at item scope");
        }
        return self.parse_const_after(start);
    }

    // `unsafe` peeked at item scope: `unsafe fn`, `unsafe const fn`, or `unsafe extend`. A function's calls
    // then require an unsafe context (the same contract as extern "C" fns); an extend's CONFORMANCE is the
    // unsafe part -- it asserts a property the compiler cannot derive, so the author carries the proof.
    // LL(1): each step decides on one token (`fn` | `const` | `extend`, then `fn`). `const unsafe fn` parses
    // too, via parse_const_or_fn; the formatter prints the canonical `unsafe const` order.
    pub fn parse_unsafe_fn(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        if self.check(TokenType::Extend) {
            let e = self.parse_extend();
            if e != NODE_NONE {
                self.ast.at(e).as_data.extend_def.is_unsafe = true;
                self.ast.at(e).span.start = start;
            }
            return e;
        }
        let is_const = self.match(TokenType::Const);
        if !self.check(TokenType::Fn) {
            self.error_here("expected 'fn', 'const fn' or 'extend' after 'unsafe' at item scope");
            return NODE_NONE;
        }
        let f = self.parse_function(true);
        self.ast.at(f).as_data.function.is_unsafe = true;
        if is_const {
            self.ast.at(f).as_data.function.is_const = true;
        }
        self.ast.at(f).span.start = start;
        return f;
    }

    // `const` already consumed: a single-token branch decides const fn / const unsafe fn / const
    // declaration (LL(1): `fn` | `unsafe` | identifier, then `unsafe` commits to `fn`).
    pub fn parse_const_or_fn(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        if self.check(TokenType::Fn) {
            let f = self.parse_function(true);
            self.ast.at(f).as_data.function.is_const = true;
            self.ast.at(f).span.start = start;
            return f;
        }
        if self.check(TokenType::Unsafe) {
            self.advance();
            if !self.check(TokenType::Fn) {
                self.error_here("expected 'fn' after 'const unsafe'");
                return NODE_NONE;
            }
            let f = self.parse_function(true);
            self.ast.at(f).as_data.function.is_const = true;
            self.ast.at(f).as_data.function.is_unsafe = true;
            self.ast.at(f).span.start = start;
            return f;
        }
        return self.parse_const_after(start);
    }

    fn parse_const_after(self: &mut Self, start: u32) NodeId {
        let name = self.identifier();
        self.expect(TokenType::Colon, "':'");
        let ty = self.parse_type();
        self.expect(TokenType::Equal, "'='");
        let value = self.parse_expression();
        self.expect(TokenType::Semicolon, "';'");
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_CONST,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs {
                    const_def: ConstData {
                        name: name,
                        ty: ty,
                        value: value,
                        is_public: false,
                        is_extern: false,
                        is_static_mut: false,
                    },
                },
            },
        );
    }

    pub fn parse_static(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        if !self.match(TokenType::Mut) {
            self.error_here("expected 'mut' after 'static' (immutable module-level data is a 'const')");
        }
        let name = self.identifier();
        self.expect(TokenType::Colon, "':'");
        let ty = self.parse_type();
        self.expect(TokenType::Equal, "'='");
        let value = self.parse_expression();
        self.expect(TokenType::Semicolon, "';'");
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_CONST,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs {
                    const_def: ConstData {
                        name: name,
                        ty: ty,
                        value: value,
                        is_public: false,
                        is_extern: false,
                        is_static_mut: true,
                    },
                },
            },
        );
    }

    pub fn parse_static_assert(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        self.expect(TokenType::LeftParen, "'('");
        let cond = self.parse_expression();
        let mut msg = NODE_NONE;
        if self.match(TokenType::Comma) {
            if self.check(TokenType::StringLiteral) {
                msg = self.literal();
            } else {
                self.error_here("static_assert message must be a string literal");
            }
        }
        self.expect(TokenType::RightParen, "')'");
        self.expect(TokenType::Semicolon, "';'");
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_STATIC_ASSERT,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { binary: BinaryData { op: TokenType::Equal, left: cond, right: msg } },
            },
        );
    }

    pub fn parse_interface(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let name = self.identifier();
        let mut lifetimes = NodeList { start: 0, len: 0 };
        let generics = self.parse_generics_split(&mut lifetimes);
        let bounds = if self.match(TokenType::Colon) {
            self.parse_bounds();
        } else {
            NodeList { start: 0, len: 0 };
        };
        self.expect(TokenType::LeftBrace, "'{'");
        let mark = self.ast.mark();
        while !self.check(TokenType::RightBrace) && !self.at_end() {
            if self.check(TokenType::Fn) {
                let f = self.parse_function(false);
                if self.ast.at_const(f).as_data.function.body == NODE_NONE {
                    self.expect(TokenType::Semicolon, "';'");
                }
                self.ast.push(f);
            } else if self.check(TokenType::Unsafe) {
                // `unsafe fn` / `unsafe const fn` in an interface: the REQUIREMENT is unsafe, so every implementation
                // must be too (`check_method_qualifiers`), and so is every call through the bound. An interface whose contract the
                // compiler cannot check (a raw pointer that must stay valid, a lock the caller must already
                // hold) has nowhere else to say so. LL(1): one token after `unsafe`, then one after `const`.
                let ustart = self.raw_peek().start();
                self.advance();
                let uconst = self.match(TokenType::Const);
                if !self.check(TokenType::Fn) {
                    self.error_here("expected 'fn' or 'const fn' after 'unsafe' in an interface");
                } else {
                    let f = self.parse_function(false);
                    self.ast.at(f).as_data.function.is_unsafe = true;
                    if uconst {
                        self.ast.at(f).as_data.function.is_const = true;
                    }
                    self.ast.at(f).span.start = ustart;
                    if self.ast.at_const(f).as_data.function.body == NODE_NONE {
                        self.expect(TokenType::Semicolon, "';'");
                    }
                    self.ast.push(f);
                }
            } else if self.check(TokenType::Const) {
                let cstart = self.raw_peek().start();
                self.advance();
                if !self.check(TokenType::Fn) {
                    self.error_here("expected 'fn' after 'const' in an interface");
                } else {
                    let f = self.parse_function(false);
                    self.ast.at(f).as_data.function.is_const = true;
                    self.ast.at(f).span.start = cstart;
                    if self.ast.at_const(f).as_data.function.body == NODE_NONE {
                        self.expect(TokenType::Semicolon, "';'");
                    }
                    self.ast.push(f);
                }
            } else if self.check(TokenType::Type) {
                let ta = self.parse_type_alias(true);
                self.ast.push(ta);
            } else {
                self.error_here("expected interface item");
                self.advance();
            }
        }
        let items = self.ast.commit(mark);
        self.expect(TokenType::RightBrace, "'}'");
        let __decl = self.ast.add(
            Node {
                kind: NodeKind::NODE_INTERFACE,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs {
                    interface_def: InterfaceData {
                        name: name,
                        generics: generics,
                        bounds: bounds,
                        items: items,
                        is_public: false,
                    },
                },
            },
        );
        self.ast.set_lifetimes(__decl, lifetimes);
        return __decl;
    }

    pub fn parse_extend(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let mut lifetimes = NodeList { start: 0, len: 0 };
        let generics = self.parse_generics_split(&mut lifetimes);
        let target = self.parse_type();
        let interface_type = if self.match(TokenType::As) {
            self.parse_type();
        } else {
            NODE_NONE;
        };
        self.expect(TokenType::LeftBrace, "'{'");
        let mark = self.ast.mark();
        while !self.check(TokenType::RightBrace) && !self.at_end() {
            let mut attrs = self.parse_attributes(16);
            self.reject_derive_here();
            let is_public = self.match(TokenType::Pub);
            if self.check(TokenType::Fn) {
                let f = self.parse_function(true);
                self.ast.at(f).as_data.function.is_public = is_public;
                self.add_attrs_to(&mut attrs, f);
                self.ast.push(f);
            } else if self.check(TokenType::Unsafe) {
                let f = self.parse_unsafe_fn();
                if f != NODE_NONE {
                    self.ast.at(f).as_data.function.is_public = is_public;
                    self.add_attrs_to(&mut attrs, f);
                    self.ast.push(f);
                }
            } else if self.check(TokenType::Type) && !is_public {
                let ta = self.parse_type_alias(false);
                self.ast.push(ta);
            } else if self.check(TokenType::Const) {
                let cn = self.parse_const_or_fn();
                if cn != NODE_NONE {
                    if self.ast.at_const(cn).kind == NodeKind::NODE_FUNCTION {
                        self.ast.at(cn).as_data.function.is_public = is_public;
                        self.add_attrs_to(&mut attrs, cn);
                    } else {
                        self.ast.at(cn).as_data.const_def.is_public = is_public;
                    }
                    self.ast.push(cn);
                }
            } else {
                self.error_here(
                    if is_public {
                        "'pub' may only be applied to a function or const here";
                    } else {
                        "expected extension item";
                    },
                );
                self.advance();
            }
        }
        let items = self.ast.commit(mark);
        self.expect(TokenType::RightBrace, "'}'");
        let __decl = self.ast.add(
            Node {
                kind: NodeKind::NODE_EXTEND,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs {
                    extend_def: ExtendData {
                        generics: generics,
                        interface_type: interface_type,
                        target_type: target,
                        items: items,
                        is_unsafe: false, // set by parse_unsafe_fn when an `unsafe` preceded this
                    },
                },
            },
        );
        self.ast.set_lifetimes(__decl, lifetimes);
        return __decl;
    }

    pub fn parse_extern(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let abi = if self.check(TokenType::StringLiteral) {
            self.literal();
        } else {
            NODE_NONE;
        };
        if abi == NODE_NONE {
            self.error_here("expected ABI string");
        }
        let header = if self.check(TokenType::StringLiteral) {
            self.literal();
        } else {
            NODE_NONE;
        };
        self.expect(TokenType::LeftBrace, "'{'");
        let mark = self.ast.mark();
        while !self.check(TokenType::RightBrace) && !self.at_end() {
            let mut attrs = self.parse_attributes(16);
            self.reject_derive_here();
            let is_public = self.match(TokenType::Pub);
            if self.check(TokenType::Fn) {
                let f = self.parse_function(false);
                if self.ast.at_const(f).as_data.function.body != NODE_NONE {
                    let sp = self.node_span(f);
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("extern function declarations cannot have a body"),
                    );
                }
                self.ast.at(f).as_data.function.is_public = is_public;
                self.ast.at(f).as_data.function.is_extern = true;
                self.add_attrs_to(&mut attrs, f);
                self.expect(TokenType::Semicolon, "';'");
                self.ast.push(f);
            } else if self.check(TokenType::Enum) {
                // Same contract as an extern struct: C declares the enum, this only names its constants.
                let ed = self.parse_enum();
                if ed != NODE_NONE {
                    self.ast.at(ed).as_data.aggregate.is_public = is_public;
                    self.ast.at(ed).as_data.aggregate.is_extern = true;
                    self.add_attrs_to(&mut attrs, ed);
                    self.ast.push(ed);
                }
            } else if self.check(TokenType::Struct) || self.check(TokenType::Union) {
                // The HEADER defines this type; the members only state its layout so field access and
                // sizeof work. Codegen emits no definition and spells it the way C does, which is what
                // makes the binding's type the same type the bound functions take.
                let is_union = self.check(TokenType::Union);
                let sd = self.parse_struct(); // one shape; `union` only sets the flag below
                if sd != NODE_NONE {
                    self.ast.at(sd).as_data.aggregate.is_union = is_union;
                    if self.ast.at_const(sd).as_data.aggregate.generics.len != 0 {
                        let sp = self.node_span(sd);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("an extern type cannot be generic: C has no such declaration to match"),
                        );
                    }
                    self.ast.at(sd).as_data.aggregate.is_public = is_public;
                    self.ast.at(sd).as_data.aggregate.is_extern = true;
                    self.add_attrs_to(&mut attrs, sd);
                    self.ast.push(sd);
                }
            } else if self.check(TokenType::Type) {
                let ta = self.parse_type_alias(true);
                self.ast.at(ta).as_data.type_alias.is_public = is_public;
                // Attached, not dropped: `@c.import` on an opaque handle is what pins its C spelling.
                self.add_attrs_to(&mut attrs, ta);
                self.ast.push(ta);
            } else if self.check(TokenType::Const) {
                let cstart = self.raw_peek().start();
                self.advance();
                if self.check(TokenType::Fn) {
                    self.error_here("an extern function cannot be 'const'");
                }
                let cname = self.identifier();
                self.expect(TokenType::Colon, "':'");
                let ctype = self.parse_type();
                if self.check(TokenType::Equal) {
                    self.error_here("extern const declarations cannot have an initializer");
                }
                self.expect(TokenType::Semicolon, "';'");
                let cnode = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_CONST,
                        span: Span::new(cstart, self.previous_end()),
                        as_data: NodeAs {
                            const_def: ConstData {
                                name: cname,
                                ty: ctype,
                                value: NODE_NONE,
                                is_public: is_public,
                                is_extern: true,
                                is_static_mut: false,
                            },
                        },
                    },
                );
                self.add_attrs_to(&mut attrs, cnode);
                self.ast.push(cnode);
            } else if self.check(TokenType::Static) {
                // A writable C global: `static mut` DECLARES what the header defines, so it takes no
                // initializer and codegen emits no definition -- only the accesses, which carry
                // `static mut`'s unsafe rules across the FFI unchanged.
                let sstart = self.raw_peek().start();
                self.advance();
                if !self.match(TokenType::Mut) {
                    self.error_here("expected 'mut' after 'static' (a read-only C global is an extern 'const')");
                }
                let sname = self.identifier();
                self.expect(TokenType::Colon, "':'");
                let stype = self.parse_type();
                if self.check(TokenType::Equal) {
                    self.error_here("an extern static takes no initializer: the C side defines it");
                }
                self.expect(TokenType::Semicolon, "';'");
                let snode = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_CONST,
                        span: Span::new(sstart, self.previous_end()),
                        as_data: NodeAs {
                            const_def: ConstData {
                                name: sname,
                                ty: stype,
                                value: NODE_NONE,
                                is_public: is_public,
                                is_extern: true,
                                is_static_mut: true,
                            },
                        },
                    },
                );
                self.add_attrs_to(&mut attrs, snode);
                self.ast.push(snode);
            } else {
                self.error_here(
                    if is_public {
                        "'pub' may only be applied to an extern function, type, struct, union, enum, const, or static";
                    } else {
                        "expected extern item";
                    },
                );
                self.advance();
            }
        }
        let items = self.ast.commit(mark);
        self.expect(TokenType::RightBrace, "'}'");
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_EXTERN_BLOCK,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { extern_block: ExternBlockData { abi: abi, header: header, items: items } },
            },
        );
    }

    pub fn parse_item(self: &mut Self) NodeId {
        let mut attrs = self.parse_attributes(16);
        if self.check(TokenType::StaticAssert) {
            self.reject_derive_here();
            let id = self.parse_static_assert();
            // Attached, not dropped: a `static_assert` about a LAYOUT is exactly the item that has to be
            // gated per target, and silently discarding `@platform`/`@arch` here fired the assert on the
            // targets it was written to exclude.
            self.add_attrs_to(&mut attrs, id);
            return id;
        }
        let is_public = self.match(TokenType::Pub);
        if self.check(TokenType::Static) {
            self.reject_derive_here();
            let sid = self.parse_static();
            if sid != NODE_NONE {
                self.ast.at(sid).as_data.const_def.is_public = is_public;
            }
            self.add_attrs_to(&mut attrs, sid);
            return sid;
        }
        // The item's own `@reflect` entries and `@derive` list survive the nested attribute scans
        // inside its braces (fields and variants run parse_attributes too, whose stray guards would
        // eat them).
        let saved_metas = replace(&mut self.pending_metas, Vector::<MetaAttr>::new());
        let saved_derives = replace(&mut self.derive_ifaces, Vector::<NodeId>::new());
        let saved_dstart = self.derive_start;
        let saved_dend = self.derive_end;
        if is_public && !self.check(TokenType::Fn) && !self.check(TokenType::Struct) && !self.check(TokenType::Union) && !self.check(
            TokenType::Enum,
        ) && !self.check(TokenType::Const) && !self.check(TokenType::Type) && !self.check(TokenType::Interface) && !self.check(
            TokenType::Unsafe,
        ) {
            self.error_here(
                "'pub' may only be applied to a struct, union, enum, function, const, static, interface, or type",
            );
        }
        let mut id = NODE_NONE;
        switch self.peek_type() {
            Fn => {
                id = self.parse_function(true);
                self.ast.at(id).as_data.function.is_public = is_public;
            },
            Unsafe => {
                id = self.parse_unsafe_fn();
                if id != NODE_NONE {
                    self.ast.at(id).as_data.function.is_public = is_public;
                }
            },
            Struct => {
                id = self.parse_struct();
                self.ast.at(id).as_data.aggregate.is_public = is_public;
            },
            Union => {
                id = self.parse_struct();
                self.ast.at(id).as_data.aggregate.is_public = is_public;
                self.ast.at(id).as_data.aggregate.is_union = true;
            },
            Enum => {
                id = self.parse_enum();
                self.ast.at(id).as_data.aggregate.is_public = is_public;
            },
            Interface => {
                id = self.parse_interface();
                self.ast.at(id).as_data.interface_def.is_public = is_public;
            },
            Extend => {
                id = self.parse_extend();
            },
            Type => {
                id = self.parse_type_alias(false);
                self.ast.at(id).as_data.type_alias.is_public = is_public;
            },
            Const => {
                id = self.parse_const_or_fn();
                if id != NODE_NONE {
                    if self.ast.at_const(id).kind == NodeKind::NODE_FUNCTION {
                        self.ast.at(id).as_data.function.is_public = is_public;
                    } else {
                        self.ast.at(id).as_data.const_def.is_public = is_public;
                    }
                }
            },
            Extern => {
                id = self.parse_extern();
            },
            Import => {
                id = self.parse_import();
            },
            _ => {
                self.error_here("expected top-level item");
                while !self.at_end() && !self.check(TokenType::Semicolon) {
                    self.advance();
                }
                self.match(TokenType::Semicolon);
                return NODE_NONE;
            },
        };
        self.pending_metas.free();
        self.pending_metas = saved_metas;
        self.derive_ifaces.free();
        self.derive_ifaces = saved_derives;
        self.derive_start = saved_dstart;
        self.derive_end = saved_dend;
        self.validate_item_attrs(&mut attrs, id);
        self.add_attrs_to(&mut attrs, id);
        if self.derive_ifaces.len() > 0 {
            self.expand_derives(id, &attrs);
        }
        return id;
    }

    // A pending `@derive` reached a position that cannot take it: report and drop it.
    fn reject_derive_here(self: &mut Self) {
        if self.derive_ifaces.len() > 0 {
            self.errors.emit(
                self.derive_start,
                self.derive_end - self.derive_start,
                format("'@derive' may only be applied to a struct, union, or enum declaration"),
            );
            self.derive_ifaces.clear();
        }
    }

    fn make_name(self: &mut Self, sp: Span) NodeId {
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_IDENTIFIER,
                span: sp,
                as_data: NodeAs { name: NameData { text: sp, is_mutable: false } },
            },
        );
    }

    // A bare `Name` type path whose text is `sp` -- the synthesized reference resolves by name like
    // written source.
    fn make_simple_type(self: &mut Self, sp: Span) NodeId {
        let mark = self.ast.mark();
        self.ast.push(self.make_name(sp));
        let parts = self.ast.commit(mark);
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_TYPE_PATH,
                span: sp,
                as_data: NodeAs { type_path: TypePathData { parts: parts, args: NodeList { start: 0, len: 0 } } },
            },
        );
    }

    // `@derive(I, ..)` on the just-parsed aggregate: one empty `extend<G..> T<G..> as I {}` sibling
    // per interface, pushed onto the open top-level item list ahead of the declaration. The extend
    // REUSES the declaration's generic-param nodes (same names, same bounds -> a conditional
    // conformance when the params are bounded); the target's arguments are fresh name references so
    // each scope resolves its own. The declaration's `@platform`/`@arch` gates are copied onto the
    // extends so a gated type never leaves an unfiltered conformance behind.
    fn expand_derives(self: &mut Self, decl: NodeId, attrs: &Vector<Attr>) {
        if decl == NODE_NONE || self.ast.at_const(decl).kind != NodeKind::NODE_STRUCT && self.ast.at_const(decl).kind != NodeKind::NODE_ENUM {
            self.reject_derive_here();
            return;
        }
        if self.ast.lifetimes_of(decl).len != 0 {
            self.errors.emit(
                self.derive_start,
                self.derive_end - self.derive_start,
                format(
                    "'@derive' cannot synthesize a conformance for a lifetime-parameterized type; write the 'extend' explicitly",
                ),
            );
            self.derive_ifaces.clear();
            return;
        }
        let agg = self.ast.at_const(decl).as_data.aggregate;
        let nsp = self.ast.at_const(agg.name).as_data.name.text;
        // Copied out first: node building below grows the arenas a `list` pointer indexes into.
        let mut gid_copy = Vector::<NodeId>::new();
        let mut gsp_copy = Vector::<Span>::new();
        for g in 0..agg.generics.len {
            let gid = unsafe self.ast.list(agg.generics)[g as usize];
            gid_copy.push(gid);
            gsp_copy.push(self.ast.at_const(self.ast.at_const(gid).as_data.generic_param.name).as_data.name.text);
        }
        for i in 0..self.derive_ifaces.len() {
            let iface = *self.derive_ifaces.at(i);
            let pmark = self.ast.mark();
            self.ast.push(self.make_name(nsp));
            let parts = self.ast.commit(pmark);
            let amark = self.ast.mark();
            for g in 0..gsp_copy.len() {
                self.ast.push(self.make_simple_type(gsp_copy[g]));
            }
            let targs = self.ast.commit(amark);
            let target = self.ast.add(
                Node {
                    kind: NodeKind::NODE_TYPE_PATH,
                    span: nsp,
                    as_data: NodeAs { type_path: TypePathData { parts: parts, args: targs } },
                },
            );
            let gmark = self.ast.mark();
            for g in 0..gid_copy.len() {
                self.ast.push(gid_copy[g]);
            }
            let egen = self.ast.commit(gmark);
            let ext = self.ast.add(
                Node {
                    kind: NodeKind::NODE_EXTEND,
                    span: Span::new(self.derive_start, self.derive_end),
                    as_data: NodeAs {
                        extend_def: ExtendData {
                            generics: egen,
                            interface_type: iface,
                            target_type: target,
                            items: NodeList { start: 0, len: 0 },
                            is_unsafe: false,
                        },
                    },
                },
            );
            for a in 0..attrs.len() {
                let at = *attrs.at(a);
                if at.kind == AttrKind::ATTR_PLATFORM as u8 || at.kind == AttrKind::ATTR_ARCH as u8 {
                    self.ast.add_attr(Attr { owner: ext, kind: at.kind, arg: at.arg, str_span: at.str_span });
                }
            }
            self.ast.push(ext);
        }
        self.derive_ifaces.clear();
    }

    pub fn parse_arguments(self: &mut Self) NodeList {
        let mark = self.ast.mark();
        while !self.check(TokenType::RightParen) && !self.at_end() {
            self.ast.push(self.parse_expression());
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        return self.ast.commit(mark);
    }

    pub fn parse_struct_initializer_after(self: &mut Self, ty: NodeId, start: u32) NodeId {
        self.expect(TokenType::LeftBrace, "'{'");
        let mark = self.ast.mark();
        while !self.check(TokenType::RightBrace) && !self.at_end() {
            let field_start = self.raw_peek().start();
            let name = self.identifier();
            let mut value = name;
            if self.match(TokenType::Colon) {
                value = self.parse_expression();
            }
            self.ast.push(
                self.ast.add(
                    Node {
                        kind: NodeKind::NODE_FIELD_INITIALIZER,
                        span: Span::new(field_start, self.node_span(value).end),
                        as_data: NodeAs { field_initializer: FieldInitializerData { name: name, value: value } },
                    },
                ),
            );
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        let fields = self.ast.commit(mark);
        self.expect(TokenType::RightBrace, "'}'");
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_STRUCT_INITIALIZER,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { struct_initializer: StructInitializerData { ty: ty, fields: fields } },
            },
        );
    }

    pub fn parse_pattern_alts(self: &mut Self, arm_start: u32) NodeId {
        let mut pattern = self.parse_pattern();
        if self.check(TokenType::Pipe) {
            let alt_mark = self.ast.mark();
            self.ast.push(pattern);
            while self.match(TokenType::Pipe) {
                self.ast.push(self.parse_pattern());
            }
            let alts = self.ast.commit(alt_mark);
            pattern = self.ast.add(
                Node {
                    kind: NodeKind::NODE_PATTERN_OR,
                    span: Span::new(arm_start, self.previous_end()),
                    as_data: NodeAs { pattern: PatternData { name: NODE_NONE, children: alts } },
                },
            );
        }
        return pattern;
    }

    pub fn parse_switch(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let value = self.parse_condition_expression();
        self.expect(TokenType::LeftBrace, "'{'");
        let mark = self.ast.mark();
        while !self.check(TokenType::RightBrace) && !self.at_end() {
            let arm_start = self.raw_peek().start();
            self.match(TokenType::Case);
            let pattern = self.parse_pattern_alts(arm_start);
            let guard = if self.match(TokenType::If) {
                self.parse_expression();
            } else {
                NODE_NONE;
            };
            self.expect(TokenType::FatArrow, "'=>'");
            let body = if self.check(TokenType::LeftBrace) {
                self.parse_block();
            } else {
                self.parse_expression();
            };
            self.ast.push(
                self.ast.add(
                    Node {
                        kind: NodeKind::NODE_MATCH_ARM,
                        span: Span::new(arm_start, self.node_span(body).end),
                        as_data: NodeAs { match_arm: MatchArmData { pattern: pattern, guard: guard, body: body } },
                    },
                ),
            );
            if !self.match(TokenType::Comma) && !self.check(TokenType::RightBrace) {
                self.error_here("expected ',' or '}' after switch arm");
            }
        }
        let arms = self.ast.commit(mark);
        self.expect(TokenType::RightBrace, "'}'");
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_MATCH,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { match_expr: MatchData { value: value, arms: arms } },
            },
        );
    }

    pub fn parse_pattern_atom(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        if self.match(TokenType::Minus) {
            if !Parser::is_literal_token(self.peek_type()) {
                self.error_here("expected literal");
                if !self.at_end() {
                    self.advance();
                }
                return NODE_NONE;
            }
            let value = self.literal();
            let neg = self.ast.add(
                Node {
                    kind: NodeKind::NODE_UNARY,
                    span: Span::new(start, self.node_span(value).end),
                    as_data: NodeAs {
                        unary: UnaryData {
                            op: TokenType::Minus,
                            operand: value,
                            qualifier: TypeQualifier::TYPE_QUAL_NONE,
                        },
                    },
                },
            );
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_PATTERN_LITERAL,
                    span: Span::new(start, self.node_span(value).end),
                    as_data: NodeAs { single: SingleData { value: neg } },
                },
            );
        }
        if Parser::is_literal_token(self.peek_type()) {
            let value = self.literal();
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_PATTERN_LITERAL,
                    span: self.node_span(value),
                    as_data: NodeAs { single: SingleData { value: value } },
                },
            );
        }
        if self.match(TokenType::LeftParen) {
            let inner = self.parse_pattern();
            self.expect(TokenType::RightParen, "')'");
            let mark = self.ast.mark();
            self.ast.push(inner);
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_PATTERN_TUPLE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { pattern: PatternData { name: NODE_NONE, children: self.ast.commit(mark) } },
                },
            );
        }
        if self.check(TokenType::Underscore) {
            let token = self.advance();
            return self.ast.add(Node { kind: NodeKind::NODE_PATTERN_WILDCARD, span: token.span() });
        }
        if self.check(TokenType::Mut) || Parser::is_identifier_token(self.peek_type()) {
            let is_mut = self.match(TokenType::Mut);
            let name = self.identifier();
            if name == NODE_NONE {
                return NODE_NONE;
            }
            if is_mut {
                self.ast.at(name).as_data.name.is_mutable = true;
            }
            if self.match(TokenType::LeftParen) {
                let mark = self.ast.mark();
                while !self.check(TokenType::RightParen) && !self.at_end() {
                    if self.check(TokenType::Range) {
                        let rt = self.advance();
                        self.ast.push(self.ast.add(Node { kind: NodeKind::NODE_PATTERN_WILDCARD, span: rt.span() }));
                        break;
                    }
                    self.ast.push(self.parse_pattern());
                    if !self.match(TokenType::Comma) {
                        break;
                    }
                }
                let children = self.ast.commit(mark);
                self.expect(TokenType::RightParen, "')'");
                return self.ast.add(
                    Node {
                        kind: NodeKind::NODE_PATTERN_TUPLE,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { pattern: PatternData { name: name, children: children } },
                    },
                );
            }
            if self.match(TokenType::LeftBrace) {
                let mark = self.ast.mark();
                while !self.check(TokenType::RightBrace) && !self.at_end() {
                    if self.match(TokenType::Range) {
                        break;
                    }
                    let field_start = self.raw_peek().start();
                    let field_name = self.identifier();
                    let mut child = field_name;
                    if self.match(TokenType::Colon) {
                        child = self.parse_pattern();
                    }
                    let child_mark = self.ast.mark();
                    self.ast.push(child);
                    self.ast.push(
                        self.ast.add(
                            Node {
                                kind: NodeKind::NODE_PATTERN_FIELD,
                                span: Span::new(field_start, self.node_span(child).end),
                                as_data: NodeAs {
                                    pattern: PatternData { name: field_name, children: self.ast.commit(child_mark) },
                                },
                            },
                        ),
                    );
                    if !self.match(TokenType::Comma) {
                        break;
                    }
                }
                let children = self.ast.commit(mark);
                self.expect(TokenType::RightBrace, "'}'");
                return self.ast.add(
                    Node {
                        kind: NodeKind::NODE_PATTERN_STRUCT,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { pattern: PatternData { name: name, children: children } },
                    },
                );
            }
            if self.match(TokenType::At) {
                let sub = self.parse_pattern();
                let submark = self.ast.mark();
                self.ast.push(sub);
                return self.ast.add(
                    Node {
                        kind: NodeKind::NODE_PATTERN_NAME,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { pattern: PatternData { name: name, children: self.ast.commit(submark) } },
                    },
                );
            }
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_PATTERN_NAME,
                    // From `start`, not the identifier's own span: a `mut` binding is part of the
                    // pattern's text, and the formatter prints patterns from their span -- an
                    // identifier-only span silently REWROTE `Some(mut x)` to `Some(x)`.
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { pattern: PatternData { name: name, children: NodeList { start: 0, len: 0 } } },
                },
            );
        }
        self.error_here("expected pattern");
        if !self.at_end() {
            self.advance();
        }
        return NODE_NONE;
    }

    pub fn parse_pattern(self: &mut Self) NodeId {
        return self.parse_range(RangeContext::RANGE_PATTERN);
    }

    pub fn parse_array_element(self: &mut Self) NodeId {
        if !self.check(TokenType::LeftBracket) {
            return self.parse_expression();
        }
        let start = self.raw_peek().start();
        let group = self.parse_array_literal();
        if self.match(TokenType::Equal) {
            let elements = self.ast.at_const(group).as_data.array_literal.elements;
            let mut index = if elements.len == 1 {
                unsafe self.ast.list(elements)[0];
            } else {
                NODE_NONE;
            };
            if index != NODE_NONE && self.ast.at_const(index).kind == NodeKind::NODE_FIELD_INITIALIZER {
                index = NODE_NONE;
            }
            if index == NODE_NONE {
                self.errors.emit(
                    start,
                    self.previous_end() - start,
                    format("a designated element needs a single index expression"),
                );
            }
            let value = self.parse_expression();
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_FIELD_INITIALIZER,
                    span: Span::new(start, self.node_span(value).end),
                    as_data: NodeAs { field_initializer: FieldInitializerData { name: index, value: value } },
                },
            );
        }
        let p = self.parse_postfix_after(group);
        return self.parse_expression_from_mode(p, ExpressionGrammar::EXPR_FULL);
    }

    pub fn parse_array_literal(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let mark = self.ast.mark();
        let mut repeat = false;
        while !self.check(TokenType::RightBracket) && !self.at_end() {
            self.ast.push(self.parse_array_element());
            // `[v; N]` -- N copies of one value. LL(1): the `;` is what distinguishes it, and it can only
            // appear after the first element.
            if self.ast.mark() == mark + 1 && self.match(TokenType::Semicolon) {
                self.ast.push(self.parse_expression());
                repeat = true;
                break;
            }
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        let elements = self.ast.commit(mark);
        self.expect(TokenType::RightBracket, "']'");
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_ARRAY_LITERAL,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { array_literal: ArrayLiteralData { elements: elements, repeat: repeat } },
            },
        );
    }

    // Expression and ConditionExpression share their implementation; delimited children always
    // select the full Expression grammar.
    fn parse_primary_mode(self: &mut Self, grammar: ExpressionGrammar) NodeId {
        let start = self.raw_peek().start();
        let kind = self.peek_type();
        if Parser::is_literal_token(kind) {
            return self.literal();
        }
        if kind == TokenType::MatchertextBegin {
            return self.parse_matchertext_interp();
        }
        if kind == TokenType::SelfLower {
            let token = self.advance();
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_IDENTIFIER,
                    span: token.span(),
                    as_data: NodeAs { name: NameData { text: token.span(), is_mutable: false } },
                },
            );
        }
        if kind == TokenType::VaStart || kind == TokenType::VaArg || kind == TokenType::VaEnd {
            let va = if kind == TokenType::VaStart {
                VA_START;
            } else if kind == TokenType::VaArg {
                VA_ARG;
            } else {
                VA_END;
            };
            let value = self.identifier();
            if !self.match(TokenType::LeftParen) {
                if grammar == ExpressionGrammar::EXPR_FULL && self.check(TokenType::LeftBrace) {
                    return self.parse_struct_initializer_after(value, start);
                }
                return value;
            }
            let ap = self.parse_expression();
            let mut extra = NODE_NONE;
            if va == VA_ARG {
                self.expect(TokenType::Comma, "','");
                extra = self.parse_type();
            } else if va == VA_START {
                self.expect(TokenType::Comma, "','");
                extra = self.parse_expression();
            }
            self.expect(TokenType::RightParen, "')'");
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_VA_EXPR,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { va_op: VaOpData { op: va, ap: ap, extra: extra } },
                },
            );
        }
        if Parser::is_identifier_token(kind) {
            let value = self.identifier();
            if grammar == ExpressionGrammar::EXPR_FULL && self.check(TokenType::LeftBrace) {
                return self.parse_struct_initializer_after(value, start);
            }
            return value;
        }
        if self.match(TokenType::LeftParen) {
            let value = self.parse_expression();
            if self.check(TokenType::Comma) {
                let mark = self.ast.mark();
                self.ast.push(value);
                while self.match(TokenType::Comma) && !self.check(TokenType::RightParen) && !self.at_end() {
                    self.ast.push(self.parse_expression());
                }
                let elems = self.ast.commit(mark);
                self.expect(TokenType::RightParen, "')'");
                return self.ast.add(
                    Node {
                        kind: NodeKind::NODE_TUPLE,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { array_literal: ArrayLiteralData { elements: elems, repeat: false } },
                    },
                );
            }
            self.expect(TokenType::RightParen, "')'");
            return value;
        }
        if kind == TokenType::Switch {
            return self.parse_switch();
        }
        if kind == TokenType::If {
            return self.parse_if();
        }
        if kind == TokenType::Loop {
            self.advance();
            let body = self.parse_block();
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_WHILE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs {
                        while_stmt: WhileData { condition: NODE_NONE, body: body, is_do: false, label: Span::empty() },
                    },
                },
            );
        }
        if self.check(TokenType::Sizeof) || self.check(TokenType::Alignof) {
            let is_align = self.check(TokenType::Alignof);
            self.advance();
            self.expect(TokenType::LeftParen, "'('");
            let ty = self.parse_type();
            self.expect(TokenType::RightParen, "')'");
            return self.ast.add(
                Node {
                    kind: if is_align {
                        NodeKind::NODE_ALIGNOF;
                    } else {
                        NodeKind::NODE_SIZEOF;
                    },
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { single: SingleData { value: ty } },
                },
            );
        }
        if self.match(TokenType::New) {
            let new_type = self.parse_type();
            let mut initializer = NODE_NONE;
            if self.check(TokenType::LeftBrace) {
                initializer = self.parse_struct_initializer_after(new_type, self.node_span(new_type).start);
            } else if self.match(TokenType::LeftParen) {
                initializer = self.parse_expression();
                self.expect(TokenType::RightParen, "')'");
            }
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_NEW,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { new_expr: NewData { ty: new_type, initializer: initializer } },
                },
            );
        }
        if self.check(TokenType::LeftBracket) {
            return self.parse_array_literal();
        }
        if self.match(TokenType::Fn) {
            let mut variadic = false;
            let params = self.parse_parameters(&mut variadic);
            if variadic {
                self.error_here("anonymous functions cannot be variadic");
            }
            let returns = self.parse_function_returns();
            let outer_nrets = replace(&mut self.nrets, Vector::<NodeId>::new());
            let body = self.parse_block();
            self.nrets = outer_nrets;
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_CLOSURE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs {
                        closure: ClosureData {
                            params: params,
                            returns: returns,
                            body: body,
                            expr_body: false,
                            captures: NodeList { start: 0, len: 0 },
                            mut_caps: 0,
                        },
                    },
                },
            );
        }
        if self.check(TokenType::Pipe) || self.check(TokenType::PipePipe) {
            let empty = self.match(TokenType::PipePipe);
            if !empty {
                self.advance();
            }
            let mark = self.ast.mark();
            if !empty {
                while !self.check(TokenType::Pipe) && !self.at_end() {
                    let pstart = self.raw_peek().start();
                    let name = self.identifier();
                    let mut ty = NODE_NONE;
                    if self.match(TokenType::Colon) {
                        ty = self.parse_type();
                    }
                    self.ast.push(
                        self.ast.add(
                            Node {
                                kind: NodeKind::NODE_PARAMETER,
                                span: Span::new(pstart, self.previous_end()),
                                as_data: NodeAs { parameter: ParameterData { name: name, ty: ty, is_mutable: false } },
                            },
                        ),
                    );
                    if !self.match(TokenType::Comma) {
                        break;
                    }
                }
                self.expect(TokenType::Pipe, "'|'");
            }
            let params = self.ast.commit(mark);
            if self.check(TokenType::LeftBrace) {
                let outer_nrets = replace(&mut self.nrets, Vector::<NodeId>::new());
                let block = self.parse_block();
                self.nrets = outer_nrets;
                return self.ast.add(
                    Node {
                        kind: NodeKind::NODE_CLOSURE,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs {
                            closure: ClosureData {
                                params: params,
                                returns: NodeList { start: 0, len: 0 },
                                body: block,
                                expr_body: false,
                                captures: NodeList { start: 0, len: 0 },
                                mut_caps: 0,
                            },
                        },
                    },
                );
            }
            let body = self.parse_expression();
            return self.ast.add(
                Node {
                    kind: NodeKind::NODE_CLOSURE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs {
                        closure: ClosureData {
                            params: params,
                            returns: NodeList { start: 0, len: 0 },
                            body: body,
                            expr_body: true,
                            captures: NodeList { start: 0, len: 0 },
                            mut_caps: 0,
                        },
                    },
                },
            );
        }
        self.error_here("expected expression");
        if !self.at_end() {
            self.advance();
        }
        return NODE_NONE;
    }

    pub fn path_chain_to_type_path(self: &mut Self, chain: NodeId, start: u32) NodeId {
        // fixed 16-segment cap: a deeper member chain silently loses its leftmost segments
        let mut segs: [NodeId; 16] = [
            0u32,
            0u32,
            0u32,
            0u32,
            0u32,
            0u32,
            0u32,
            0u32,
            0u32,
            0u32,
            0u32,
            0u32,
            0u32,
            0u32,
            0u32,
            0u32,
        ];
        let mut n: u32 = 0;
        let mut cur = chain;
        while true {
            let cn = self.ast.at_const(cur);
            if n < 16 {
                unsafe segs[n] = cn.as_data.member.member;
                n = n + 1;
            }
            let o = cn.as_data.member.object;
            if self.ast.at_const(o).kind != NodeKind::NODE_MEMBER {
                if n < 16 {
                    unsafe segs[n] = o;
                    n = n + 1;
                }
                break;
            }
            cur = o;
        }
        let mark = self.ast.mark();
        while n > 0 {
            n = n - 1;
            self.ast.push(unsafe segs[n]);
        }
        let parts = self.ast.commit(mark);
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_TYPE_PATH,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { type_path: TypePathData { parts: parts, args: NodeList { start: 0, len: 0 } } },
            },
        );
    }

    fn parse_postfix_after_mode(self: &mut Self, mut expr: NodeId, grammar: ExpressionGrammar) NodeId {
        while true {
            let start = self.node_span(expr).start;
            if self.match(TokenType::LeftParen) {
                let args = self.parse_arguments();
                self.expect(TokenType::RightParen, "')'");
                expr = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_CALL,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { call: CallData { callee: expr, args: args } },
                    },
                );
            } else if self.match(TokenType::LeftBracket) {
                let index = self.parse_range(RangeContext::RANGE_EXPR);
                self.expect(TokenType::RightBracket, "']'");
                expr = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_INDEX,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { index: IndexData { object: expr, index: index } },
                    },
                );
            } else if self.check(TokenType::Dot) || self.check(TokenType::Arrow) {
                let pointer = self.match(TokenType::Arrow);
                if !pointer {
                    self.advance();
                }
                let member = if self.check(TokenType::IntegerLiteral) {
                    let tok = self.advance();
                    self.ast.add(
                        Node {
                            kind: NodeKind::NODE_IDENTIFIER,
                            span: tok.span(),
                            as_data: NodeAs { name: NameData { text: tok.span(), is_mutable: false } },
                        },
                    );
                } else if self.check(TokenType::FloatLiteral) {
                    self.error_here("nested tuple access needs parentheses: write '(t.0).1'");
                    self.advance();
                    NODE_NONE;
                } else {
                    self.callable_name();
                };
                expr = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_MEMBER,
                        span: Span::new(start, self.node_span(member).end),
                        as_data: NodeAs {
                            member: MemberData { object: expr, member: member, pointer: pointer, path: false },
                        },
                    },
                );
            } else if self.match(TokenType::PathSeparator) {
                if self.check(TokenType::LessThan) {
                    let types = self.parse_type_args();
                    let inner = expr;
                    expr = self.ast.add(
                        Node {
                            kind: NodeKind::NODE_GENERIC_SPECIALIZATION,
                            span: Span::new(start, self.previous_end()),
                            as_data: NodeAs { specialization: SpecializationData { expression: inner, types: types } },
                        },
                    );
                    if grammar == ExpressionGrammar::EXPR_FULL && self.check(TokenType::LeftBrace) {
                        let mut tp: NodeId;
                        if self.ast.at_const(inner).kind == NodeKind::NODE_MEMBER {
                            tp = self.path_chain_to_type_path(inner, start);
                        } else {
                            let mark = self.ast.mark();
                            self.ast.push(inner);
                            tp = self.ast.add(
                                Node {
                                    kind: NodeKind::NODE_TYPE_PATH,
                                    span: Span::new(start, self.previous_end()),
                                    as_data: NodeAs {
                                        type_path: TypePathData {
                                            parts: self.ast.commit(mark),
                                            args: NodeList { start: 0, len: 0 },
                                        },
                                    },
                                },
                            );
                        }
                        self.ast.at(tp).as_data.type_path.args = types;
                        return self.parse_struct_initializer_after(tp, start);
                    }
                } else {
                    let member = self.callable_name();
                    expr = self.ast.add(
                        Node {
                            kind: NodeKind::NODE_MEMBER,
                            span: Span::new(start, self.node_span(member).end),
                            as_data: NodeAs {
                                member: MemberData { object: expr, member: member, pointer: false, path: true },
                            },
                        },
                    );
                    if grammar == ExpressionGrammar::EXPR_FULL && self.check(TokenType::LeftBrace) {
                        let tp = self.path_chain_to_type_path(expr, start);
                        return self.parse_struct_initializer_after(tp, start);
                    }
                }
            } else if self.match(TokenType::Question) {
                expr = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_UNARY,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs {
                            unary: UnaryData {
                                op: TokenType::Question,
                                operand: expr,
                                qualifier: TypeQualifier::TYPE_QUAL_NONE,
                            },
                        },
                    },
                );
            } else {
                break;
            }
        }
        return expr;
    }

    pub fn parse_postfix_after(self: &mut Self, expr: NodeId) NodeId {
        return self.parse_postfix_after_mode(expr, ExpressionGrammar::EXPR_FULL);
    }

    fn parse_postfix_mode(self: &mut Self, grammar: ExpressionGrammar) NodeId {
        return self.parse_postfix_after_mode(self.parse_primary_mode(grammar), grammar);
    }

    fn parse_unary_mode(self: &mut Self, grammar: ExpressionGrammar) NodeId {
        if self.depth >= PARSE_MAX_DEPTH {
            self.error_here("expression nested too deeply");
            return NODE_NONE;
        }
        self.depth = self.depth + 1;
        let result = if !Parser::unary_operator(self.peek_type()) {
            self.parse_postfix_mode(grammar);
        } else {
            let op = self.advance();
            let qualifier = if op.kind() == TokenType::Ampersand && self.match(TokenType::Mut) {
                TypeQualifier::TYPE_QUAL_MUT;
            } else {
                TypeQualifier::TYPE_QUAL_NONE;
            };
            let operand = if op.kind() == TokenType::Unsafe && self.check(TokenType::LeftBrace) {
                self.parse_block();
            } else {
                self.parse_unary_mode(grammar);
            };
            self.ast.add(
                Node {
                    kind: NodeKind::NODE_UNARY,
                    span: Span::new(op.start(), self.node_span(operand).end),
                    as_data: NodeAs { unary: UnaryData { op: op.kind(), operand: operand, qualifier: qualifier } },
                },
            );
        };
        self.depth = self.depth - 1;
        return result;
    }

    pub fn parse_unary(self: &mut Self) NodeId {
        return self.parse_unary_mode(ExpressionGrammar::EXPR_FULL);
    }

    @c.always_inline
    fn add_binary(self: &mut Self, left: NodeId, op: TokenType, right: NodeId) NodeId {
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_BINARY,
                span: Span::new(self.node_span(left).start, self.node_span(right).end),
                as_data: NodeAs { binary: BinaryData { op: op, left: left, right: right } },
            },
        );
    }

    // `as` binds looser than every prefix operator (`*x as T` is `(*x) as T`) and tighter than
    // any binary operator; left-associative chains (`x as A as B`) stay flat here.
    fn parse_cast_after(self: &mut Self, mut expr: NodeId) NodeId {
        while self.match(TokenType::As) {
            let cast_type = self.parse_cast_type();
            expr = self.ast.add(
                Node {
                    kind: NodeKind::NODE_CAST,
                    span: Span::new(self.node_span(expr).start, self.node_span(cast_type).end),
                    as_data: NodeAs { cast: CastData { expression: expr, ty: cast_type } },
                },
            );
        }
        return expr;
    }

    fn parse_cast_mode(self: &mut Self, grammar: ExpressionGrammar) NodeId {
        return self.parse_cast_after(self.parse_unary_mode(grammar));
    }

    // Shift and relational operators share a leading `>` token. Parsing both precedence levels
    // together lets each production consume that token before selecting its tail with one lookahead.
    fn parse_shift_relational_from_mode(self: &mut Self, left: NodeId, grammar: ExpressionGrammar) BinaryParse {
        let mut expression = self.parse_binary_level_from_mode(left, 10, grammar).expression;
        let mut relation_left = NODE_NONE;
        let mut relation_op = TokenType::Eof;
        let mut chain: u32 = 0;
        while true {
            let mut op = self.peek_type();
            let mut shift = op == TokenType::LeftShift;
            if op != TokenType::GreaterThan && !shift && op != TokenType::LessThan && op != TokenType::LessThanEqual {
                break;
            }
            chain = chain + 1;
            if chain > 4096 {
                self.error_here("expression nested too deeply");
                break;
            }
            if op == TokenType::GreaterThan {
                self.advance();
                if self.match(TokenType::GreaterThan) {
                    if self.match(TokenType::Equal) {
                        if relation_left != NODE_NONE {
                            expression = self.add_binary(relation_left, relation_op, expression);
                        }
                        return BinaryParse { expression: expression, shift_assignment: true };
                    }
                    op = TokenType::RightShift;
                    shift = true;
                } else {
                    op = if self.match(TokenType::Equal) {
                        TokenType::GreaterThanEqual;
                    } else {
                        TokenType::GreaterThan;
                    };
                }
            } else {
                self.advance();
            }
            if shift {
                let right = self.parse_binary_level_mode(10, grammar).expression;
                expression = self.add_binary(expression, op, right);
            } else {
                if relation_left != NODE_NONE {
                    expression = self.add_binary(relation_left, relation_op, expression);
                }
                relation_left = expression;
                relation_op = op;
                expression = self.parse_binary_level_mode(10, grammar).expression;
            }
        }
        if relation_left != NODE_NONE {
            expression = self.add_binary(relation_left, relation_op, expression);
        }
        return BinaryParse { expression: expression, shift_assignment: false };
    }

    fn parse_binary_level_from_mode(self: &mut Self, left: NodeId, level: i32, grammar: ExpressionGrammar) BinaryParse {
        if level > 11 {
            return BinaryParse { expression: left, shift_assignment: false };
        }
        if level == 8 {
            return self.parse_shift_relational_from_mode(left, grammar);
        }
        let next = if level == 7 {
            8;
        } else {
            level + 1;
        };
        let mut parsed = self.parse_binary_level_from_mode(left, next, grammar);
        if parsed.shift_assignment {
            return parsed;
        }
        let mut chain: u32 = 0;
        while Parser::precedence(self.peek_type()) == level {
            chain = chain + 1;
            if chain > 4096 {
                self.error_here("expression nested too deeply");
                break;
            }
            let op = self.advance().kind();
            let right = self.parse_binary_level_mode(next, grammar);
            parsed.expression = self.add_binary(parsed.expression, op, right.expression);
            if right.shift_assignment {
                parsed.shift_assignment = true;
                break;
            }
        }
        return parsed;
    }

    fn parse_binary_level_mode(self: &mut Self, level: i32, grammar: ExpressionGrammar) BinaryParse {
        return self.parse_binary_level_from_mode(self.parse_cast_mode(grammar), level, grammar);
    }

    fn parse_binary_from_mode(self: &mut Self, left: NodeId, grammar: ExpressionGrammar) BinaryParse {
        return self.parse_binary_level_from_mode(left, 1, grammar);
    }

    fn parse_binary_mode(self: &mut Self, grammar: ExpressionGrammar) BinaryParse {
        return self.parse_binary_level_mode(1, grammar);
    }

    fn parse_expression_from_mode(self: &mut Self, first: NodeId, grammar: ExpressionGrammar) NodeId {
        let parsed = self.parse_binary_from_mode(first, grammar);
        let left = parsed.expression;
        if self.check(TokenType::Range) || self.check(TokenType::RangeInclusive) {
            return self.parse_range_value_mode(left, grammar);
        }
        let op = if parsed.shift_assignment {
            TokenType::RightShiftEqual;
        } else {
            self.peek_type();
        };
        if !Parser::assignment_operator(op) {
            return left;
        }
        if self.depth >= PARSE_MAX_DEPTH {
            self.error_here("expression nested too deeply");
            return left;
        }
        self.depth = self.depth + 1;
        if !parsed.shift_assignment {
            self.advance();
        }
        let right = self.parse_expression_mode(grammar);
        self.depth = self.depth - 1;
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_ASSIGNMENT,
                span: Span::new(self.node_span(left).start, self.node_span(right).end),
                as_data: NodeAs { binary: BinaryData { op: op, left: left, right: right } },
            },
        );
    }

    fn parse_expression_mode(self: &mut Self, grammar: ExpressionGrammar) NodeId {
        if self.check(TokenType::Range) || self.check(TokenType::RangeInclusive) {
            return self.parse_range_value_mode(NODE_NONE, grammar);
        }
        return self.parse_expression_from_mode(self.parse_cast_mode(grammar), grammar);
    }

    pub fn parse_expression(self: &mut Self) NodeId {
        return self.parse_expression_mode(ExpressionGrammar::EXPR_FULL);
    }

    pub fn parse_condition_expression(self: &mut Self) NodeId {
        return self.parse_expression_mode(ExpressionGrammar::EXPR_CONDITION);
    }

    fn parse_range_bound_mode(self: &mut Self, context: RangeContext, grammar: ExpressionGrammar) NodeId {
        if context == RangeContext::RANGE_PATTERN {
            return self.parse_pattern_atom();
        }
        return self.parse_expression_mode(grammar);
    }

    pub const fn starts_range_bound(self: &Self, context: RangeContext) bool {
        let t = self.peek_type();
        if context == RangeContext::RANGE_PATTERN {
            return Parser::is_literal_token(t) || Parser::is_identifier_token(t) || t == TokenType::LeftParen || t == TokenType::Minus;
        }
        return Parser::is_literal_token(t) || Parser::is_identifier_token(t) || t == TokenType::LeftParen || t == TokenType::SelfLower || t == TokenType::New || t == TokenType::Switch || t == TokenType::Sizeof || t == TokenType::Alignof || t == TokenType::MatchertextBegin || Parser::unary_operator(
            t,
        );
    }

    fn parse_range_mode(self: &mut Self, context: RangeContext, grammar: ExpressionGrammar) NodeId {
        let open_start = self.check(TokenType::Range) || self.check(TokenType::RangeInclusive);
        let start_node = if open_start {
            NODE_NONE;
        } else {
            self.parse_range_bound_mode(context, grammar);
        };
        if !self.check(TokenType::Range) && !self.check(TokenType::RangeInclusive) {
            return start_node;
        }
        let op_start = self.raw_peek().start();
        let inclusive = self.advance().kind() == TokenType::RangeInclusive;
        let end = if self.starts_range_bound(context) {
            self.parse_range_bound_mode(context, grammar);
        } else {
            NODE_NONE;
        };
        if start_node == NODE_NONE && end == NODE_NONE {
            self.error_here("a range needs a start and/or an end");
        } else if inclusive && end == NODE_NONE {
            self.error_here("an inclusive range '..=' needs an end");
        }
        let lo = if start_node != NODE_NONE {
            self.node_span(start_node).start;
        } else {
            op_start;
        };
        let hi = if end != NODE_NONE {
            self.node_span(end).end;
        } else {
            self.previous_end();
        };
        return self.ast.add(
            Node {
                kind: if context == RangeContext::RANGE_PATTERN {
                    NodeKind::NODE_PATTERN_RANGE;
                } else {
                    NodeKind::NODE_RANGE;
                },
                span: Span::new(lo, hi),
                as_data: NodeAs {
                    pattern_range: PatternRangeData { start: start_node, end: end, inclusive: inclusive },
                },
            },
        );
    }

    pub fn parse_range(self: &mut Self, context: RangeContext) NodeId {
        return self.parse_range_mode(context, ExpressionGrammar::EXPR_FULL);
    }

    fn parse_range_value_mode(self: &mut Self, start_node: NodeId, grammar: ExpressionGrammar) NodeId {
        let op_start = self.raw_peek().start();
        let inclusive = self.advance().kind() == TokenType::RangeInclusive;
        let end = if self.starts_range_bound(RangeContext::RANGE_EXPR) {
            self.parse_binary_mode(grammar).expression;
        } else {
            NODE_NONE;
        };
        if start_node == NODE_NONE && end == NODE_NONE {
            self.error_here("a range needs a start and/or an end");
        } else if inclusive && end == NODE_NONE {
            self.error_here("an inclusive range '..=' needs an end");
        }
        let lo = if start_node != NODE_NONE {
            self.node_span(start_node).start;
        } else {
            op_start;
        };
        let hi = if end != NODE_NONE {
            self.node_span(end).end;
        } else {
            self.previous_end();
        };
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_RANGE,
                span: Span::new(lo, hi),
                as_data: NodeAs {
                    pattern_range: PatternRangeData { start: start_node, end: end, inclusive: inclusive },
                },
            },
        );
    }

    pub fn parse_let(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let is_mutable = self.match(TokenType::Mut);
        let name = if self.check(TokenType::LeftParen) {
            let tstart = self.raw_peek().start();
            self.advance();
            let mark = self.ast.mark();
            while !self.check(TokenType::RightParen) && !self.at_end() {
                self.ast.push(self.identifier());
                if !self.match(TokenType::Comma) {
                    break;
                }
            }
            let children = self.ast.commit(mark);
            self.expect(TokenType::RightParen, "')'");
            self.ast.add(
                Node {
                    kind: NodeKind::NODE_PATTERN_TUPLE,
                    span: Span::new(tstart, self.previous_end()),
                    as_data: NodeAs { pattern: PatternData { name: NODE_NONE, children: children } },
                },
            );
        } else {
            self.identifier();
        };
        let mut ty = NODE_NONE;
        let mut value = NODE_NONE;
        if self.match(TokenType::Colon) {
            ty = self.parse_type();
            if self.match(TokenType::Equal) {
                value = self.parse_expression();
            }
        } else if self.match(TokenType::Equal) {
            value = self.parse_expression();
        } else {
            self.error_here("expected type annotation or initializer");
        }
        self.expect(TokenType::Semicolon, "';'");
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_LET,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { let_stmt: LetData { name: name, ty: ty, value: value, is_mutable: is_mutable } },
            },
        );
    }

    pub fn desugar_let_match(
        self: &mut Self,
        start: u32,
        pattern: NodeId,
        value: NodeId,
        then_block: NodeId,
        mut else_branch: NodeId,
    ) NodeId {
        let end = self.previous_end();
        if else_branch == NODE_NONE {
            else_branch = self.ast.add(
                Node {
                    kind: NodeKind::NODE_BLOCK,
                    span: Span::new(end, end),
                    as_data: NodeAs { block: BlockData { statements: NodeList { start: 0, len: 0 } } },
                },
            );
        }
        let wild = self.ast.add(Node { kind: NodeKind::NODE_PATTERN_WILDCARD, span: Span::new(start, start) });
        let mark = self.ast.mark();
        self.ast.push(
            self.ast.add(
                Node {
                    kind: NodeKind::NODE_MATCH_ARM,
                    span: self.node_span(then_block),
                    as_data: NodeAs { match_arm: MatchArmData { pattern: pattern, guard: NODE_NONE, body: then_block } },
                },
            ),
        );
        self.ast.push(
            self.ast.add(
                Node {
                    kind: NodeKind::NODE_MATCH_ARM,
                    span: self.node_span(else_branch),
                    as_data: NodeAs { match_arm: MatchArmData { pattern: wild, guard: NODE_NONE, body: else_branch } },
                },
            ),
        );
        let arms = self.ast.commit(mark);
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_MATCH,
                span: Span::new(start, end),
                as_data: NodeAs { match_expr: MatchData { value: value, arms: arms } },
            },
        );
    }

    pub fn parse_if(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        if self.check(TokenType::Let) {
            self.advance();
            let pattern = self.parse_pattern_alts(start);
            self.expect(TokenType::Equal, "'='");
            let value = self.parse_condition_expression();
            let then_branch = self.parse_block();
            let mut else_branch = NODE_NONE;
            if self.match(TokenType::Else) {
                if self.check(TokenType::If) {
                    else_branch = self.parse_if();
                } else {
                    else_branch = self.parse_block();
                }
            }
            return self.desugar_let_match(start, pattern, value, then_branch, else_branch);
        }
        let condition = self.parse_condition_expression();
        let then_branch = self.parse_block();
        let mut else_branch = NODE_NONE;
        if self.match(TokenType::Else) {
            if self.check(TokenType::If) {
                else_branch = self.parse_if();
            } else {
                else_branch = self.parse_block();
            }
        }
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_IF,
                span: Span::new(
                    start,
                    self.node_span(
                        if else_branch != NODE_NONE {
                            else_branch;
                        } else {
                            then_branch;
                        },
                    ).end,
                ),
                as_data: NodeAs {
                    if_stmt: IfData { condition: condition, then_branch: then_branch, else_branch: else_branch },
                },
            },
        );
    }

    pub fn parse_loop_stmt(self: &mut Self, start: u32, label: Span) NodeId {
        let mut result = NODE_NONE;
        switch self.peek_type() {
            While => {
                self.advance();
                // while-let desugars to: loop { match value { pattern => body, _ => break } }
                if self.check(TokenType::Let) {
                    self.advance();
                    let pattern = self.parse_pattern_alts(start);
                    self.expect(TokenType::Equal, "'='");
                    let value = self.parse_condition_expression();
                    let body = self.parse_block();
                    let end = self.previous_end();
                    let brk = self.ast.add(Node { kind: NodeKind::NODE_BREAK, span: Span::new(end, end) });
                    let bmark = self.ast.mark();
                    self.ast.push(brk);
                    let brk_block = self.ast.add(
                        Node {
                            kind: NodeKind::NODE_BLOCK,
                            span: Span::new(end, end),
                            as_data: NodeAs { block: BlockData { statements: self.ast.commit(bmark) } },
                        },
                    );
                    let m = self.desugar_let_match(start, pattern, value, body, brk_block);
                    let ms = self.ast.add(
                        Node {
                            kind: NodeKind::NODE_EXPRESSION_STATEMENT,
                            span: self.node_span(m),
                            as_data: NodeAs { single: SingleData { value: m } },
                        },
                    );
                    let lmark = self.ast.mark();
                    self.ast.push(ms);
                    let lbody = self.ast.add(
                        Node {
                            kind: NodeKind::NODE_BLOCK,
                            span: Span::new(start, end),
                            as_data: NodeAs { block: BlockData { statements: self.ast.commit(lmark) } },
                        },
                    );
                    result = self.ast.add(
                        Node {
                            kind: NodeKind::NODE_WHILE,
                            span: Span::new(start, end),
                            as_data: NodeAs {
                                while_stmt: WhileData { condition: NODE_NONE, body: lbody, is_do: false, label: label },
                            },
                        },
                    );
                } else {
                    let condition = self.parse_condition_expression();
                    let body = self.parse_block();
                    result = self.ast.add(
                        Node {
                            kind: NodeKind::NODE_WHILE,
                            span: Span::new(start, self.node_span(body).end),
                            as_data: NodeAs {
                                while_stmt: WhileData { condition: condition, body: body, is_do: false, label: label },
                            },
                        },
                    );
                }
            },
            Do => {
                self.advance();
                let body = self.parse_block();
                self.expect(TokenType::While, "'while'");
                let condition = self.parse_expression();
                self.expect(TokenType::Semicolon, "';'");
                result = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_WHILE,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs {
                            while_stmt: WhileData { condition: condition, body: body, is_do: true, label: label },
                        },
                    },
                );
            },
            For | InlineFor | ParallelFor => {
                let mut kind = NodeKind::NODE_FOR;
                if self.check(TokenType::InlineFor) {
                    kind = NodeKind::NODE_INLINE_FOR;
                } else if self.check(TokenType::ParallelFor) {
                    kind = NodeKind::NODE_PARALLEL_FOR;
                    self.ast.sugar_marks += 1;
                }
                self.advance();
                if kind != NodeKind::NODE_FOR {
                    // The modifier token spans only `inline`/`parallel`; the `for` itself follows.
                    // (A label cannot reach here: the Label arm admits only while/do/for/loop.)
                    self.expect(TokenType::For, "'for'");
                }
                let binding = self.identifier();
                self.expect(TokenType::In, "'in'");
                let iterable = self.parse_range_mode(RangeContext::RANGE_FOR, ExpressionGrammar::EXPR_CONDITION);
                let mut body = self.parse_block();
                if kind == NodeKind::NODE_PARALLEL_FOR {
                    // The body IS a closure over the binding: built here so resolve treats it as one
                    // and fills its captures; desugar then only wraps it in the std range() call.
                    let pmark = self.ast.mark();
                    self.ast.push(
                        self.ast.add(
                            Node {
                                kind: NodeKind::NODE_PARAMETER,
                                span: self.node_span(binding),
                                as_data: NodeAs {
                                    parameter: ParameterData { name: binding, ty: NODE_NONE, is_mutable: false },
                                },
                            },
                        ),
                    );
                    let params = self.ast.commit(pmark);
                    body = self.ast.add(
                        Node {
                            kind: NodeKind::NODE_CLOSURE,
                            span: Span::new(start, self.node_span(body).end),
                            as_data: NodeAs {
                                closure: ClosureData {
                                    params: params,
                                    returns: NodeList { start: 0, len: 0 },
                                    body: body,
                                    expr_body: false,
                                    captures: NodeList { start: 0, len: 0 },
                                    mut_caps: 0,
                                },
                            },
                        },
                    );
                }
                result = self.ast.add(
                    Node {
                        kind: kind,
                        span: Span::new(start, self.node_span(body).end),
                        as_data: NodeAs {
                            for_stmt: ForData { binding: binding, iterable: iterable, body: body, label: label },
                        },
                    },
                );
            },
            _ => {
                self.advance();
                let body = self.parse_block();
                result = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_WHILE,
                        span: Span::new(start, self.node_span(body).end),
                        as_data: NodeAs {
                            while_stmt: WhileData { condition: NODE_NONE, body: body, is_do: false, label: label },
                        },
                    },
                );
            },
        };
        return result;
    }

    pub fn parse_statement(self: &mut Self) NodeId {
        if self.depth >= PARSE_MAX_DEPTH {
            self.error_here("statement nested too deeply");
            if !self.at_end() {
                self.advance();
            }
            return NODE_NONE;
        }
        self.depth = self.depth + 1;
        let s = self.parse_statement_inner();
        self.depth = self.depth - 1;
        return s;
    }

    pub fn parse_statement_inner(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        if self.check(TokenType::StaticAssert) {
            return self.parse_static_assert();
        }
        let mut result = NODE_NONE;
        switch self.peek_type() {
            LeftBrace => {
                result = self.parse_block();
            },
            Let => {
                result = self.parse_let();
            },
            Const => {
                result = self.parse_const();
            },
            Return => {
                self.advance();
                let mark = self.ast.mark();
                if !self.check(TokenType::Semicolon) {
                    while true {
                        self.ast.push(self.parse_expression());
                        if !self.match(TokenType::Comma) {
                            break;
                        }
                    }
                } else if self.nrets.len() != 0 {
                    // bare `return;` in a named-return fn: return the named bindings (the synthetic
                    // identifiers keep the signature spans, so the formatter prints `return;` back)
                    for i in 0..self.nrets.len() {
                        let r = *self.nrets.at(i);
                        let pd = self.ast.at_const(r).as_data.parameter;
                        let ntext = self.ast.at_const(pd.name).as_data.name.text;
                        let nspan = self.ast.at_const(pd.name).span;
                        self.ast.push(
                            self.ast.add(
                                Node {
                                    kind: NodeKind::NODE_IDENTIFIER,
                                    span: nspan,
                                    as_data: NodeAs { name: NameData { text: ntext, is_mutable: false } },
                                },
                            ),
                        );
                    }
                }
                let values = self.ast.commit(mark);
                self.expect(TokenType::Semicolon, "';'");
                result = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_RETURN,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { return_stmt: ReturnData { values: values } },
                    },
                );
            },
            Break | Continue => {
                let kind = if self.check(TokenType::Break) {
                    NodeKind::NODE_BREAK;
                } else {
                    NodeKind::NODE_CONTINUE;
                };
                self.advance();
                let mut label = Span::empty();
                if self.check(TokenType::Label) {
                    let lt = self.raw_peek();
                    label = lt.span();
                    self.advance();
                }
                let mut value = NODE_NONE;
                if kind == NodeKind::NODE_BREAK && !self.check(TokenType::Semicolon) {
                    value = self.parse_expression();
                }
                self.expect(TokenType::Semicolon, "';'");
                result = self.ast.add(
                    Node {
                        kind: kind,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { flow: FlowData { value: value, label: label } },
                    },
                );
            },
            Defer => {
                self.advance();
                let is_block = self.check(TokenType::LeftBrace);
                let value = if is_block {
                    self.parse_block();
                } else {
                    self.parse_expression();
                };
                if !is_block {
                    self.expect(TokenType::Semicolon, "';'");
                }
                result = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_DEFER,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { single: SingleData { value: value } },
                    },
                );
            },
            Asm => {
                result = self.parse_asm();
            },
            Launch => {
                // Sugar keyword: `launch <closure>;`. Built as an expression-statement marker wrapping a call
                // to a placeholder callee (its name is never read). The HIR lowering seeds the callee's
                // resolution to the runtime shim and flips NODE_LAUNCH to NODE_EXPRESSION_STATEMENT before
                // typecheck, so downstream it is an ordinary `submit(<closure>);` statement.
                let kwspan = self.raw_peek().span();
                self.advance();
                let operand = self.parse_expression();
                self.expect(TokenType::Semicolon, "';'");
                let callee = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_IDENTIFIER,
                        span: kwspan,
                        as_data: NodeAs { name: NameData { text: kwspan, is_mutable: false } },
                    },
                );
                let mark = self.ast.mark();
                self.ast.push(operand);
                let args = self.ast.commit(mark);
                let inner = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_CALL,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { call: CallData { callee: callee, args: args } },
                    },
                );
                self.ast.sugar_marks += 1;
                result = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_LAUNCH,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { single: SingleData { value: inner } },
                    },
                );
            },
            Select => {
                result = self.parse_select();
            },
            If => {
                let f = self.parse_if();
                // if-let desugars to a match EXPRESSION; wrap it so it statement-positions
                if f != NODE_NONE && self.ast.at_const(f).kind == NodeKind::NODE_MATCH {
                    result = self.ast.add(
                        Node {
                            kind: NodeKind::NODE_EXPRESSION_STATEMENT,
                            span: self.node_span(f),
                            as_data: NodeAs { single: SingleData { value: f } },
                        },
                    );
                } else {
                    result = f;
                }
            },
            Label => {
                let label = self.raw_peek().span();
                self.advance();
                self.expect(TokenType::Colon, "':'");
                if !self.check(TokenType::While) && !self.check(TokenType::Do) && !self.check(TokenType::For) && !self.check(
                    TokenType::Loop,
                ) {
                    self.error_here("a label must be followed by 'loop', 'while', 'do', or 'for'");
                    result = NODE_NONE;
                } else {
                    result = self.parse_loop_stmt(start, label);
                }
            },
            While | Do | For | Loop | InlineFor | ParallelFor => {
                result = self.parse_loop_stmt(start, Span::empty());
            },
            Unsafe => {
                let op = self.advance();
                let is_block = self.check(TokenType::LeftBrace);
                let operand = if is_block {
                    self.parse_block();
                } else {
                    self.parse_unary();
                };
                let unary = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_UNARY,
                        span: Span::new(start, self.node_span(operand).end),
                        as_data: NodeAs {
                            unary: UnaryData {
                                op: op.kind(),
                                operand: operand,
                                qualifier: TypeQualifier::TYPE_QUAL_NONE,
                            },
                        },
                    },
                );
                let cast = self.parse_cast_after(unary);
                let expression = self.parse_expression_from_mode(cast, ExpressionGrammar::EXPR_FULL);
                // a bare 'unsafe { ... }' statement needs no ';'; if the block turned out to be only
                // the prefix of a larger expression, the statement does
                if !is_block || expression != unary {
                    self.expect(TokenType::Semicolon, "';'");
                }
                result = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_EXPRESSION_STATEMENT,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { single: SingleData { value: expression } },
                    },
                );
            },
            _ => {
                let expression = self.parse_expression();
                self.expect(TokenType::Semicolon, "';'");
                result = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_EXPRESSION_STATEMENT,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { single: SingleData { value: expression } },
                    },
                );
            },
        };
        return result;
    }

    // `select { <arm>* }` -- wait on several channel operations at once. Each arm is
    //     [<name> '='] <operation> '=>' <block>
    // with <operation> one of `ch.recv()`, `ch.send(v)`, `timeout(d)` or `default`. Single-token LL(1): the
    // arm's expression is parsed by the ordinary expression grammar (which already folds `name = ..` into an
    // assignment), and the binding falls out of that node rather than out of lookahead.
    fn parse_select(self: &mut Self) NodeId {
        let kw = self.raw_peek().span();
        self.advance();
        self.expect(TokenType::LeftBrace, "'{'");
        let mark = self.ast.mark();
        let mut timeouts = 0;
        let mut defaults = 0;
        let mut channels = 0;
        while !self.check(TokenType::RightBrace) && !self.at_end() {
            let before = self.current;
            let arm = self.parse_select_arm();
            if arm != NODE_NONE {
                let k = self.ast.at_const(arm).as_data.select_arm.kind;
                if k == SelectArmKind::SELECT_TIMEOUT {
                    timeouts = timeouts + 1;
                } else if k == SelectArmKind::SELECT_DEFAULT {
                    defaults = defaults + 1;
                } else {
                    channels = channels + 1;
                }
                self.ast.push(arm);
            }
            if self.current == before {
                self.advance(); // progress guarantee: a failed arm that consumed nothing must not loop
            }
        }
        let arms = self.ast.commit(mark);
        self.expect(TokenType::RightBrace, "'}'");
        if channels == 0 {
            self.errors.emit(
                kw.start,
                kw.end - kw.start,
                String::from_str("'select' needs at least one 'ch.recv()' or 'ch.send(v)' arm"),
            );
        }
        if timeouts > 1 || defaults > 1 {
            self.errors.emit(
                kw.start,
                kw.end - kw.start,
                String::from_str("'select' allows at most one 'timeout' and one 'default' arm"),
            );
        }
        if timeouts != 0 && defaults != 0 {
            // `default` means "never wait", which makes any deadline unreachable.
            self.errors.emit(
                kw.start,
                kw.end - kw.start,
                String::from_str("'select' cannot have both a 'timeout' and a 'default' arm"),
            );
        }
        self.ast.sugar_marks += 1;
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_SELECT,
                span: Span::new(kw.start, self.previous_end()),
                as_data: NodeAs { block: BlockData { statements: arms } },
            },
        );
    }

    // One `select` arm. The operation call is taken APART here -- `ch.recv()` keeps only `ch` -- so the
    // resolver never meets the `recv`/`send`/`timeout` names, which are syntax, not values.
    fn parse_select_arm(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        let mut expr = self.parse_expression();
        let mut binding = NODE_NONE;
        let mut bad = false;
        if expr != NODE_NONE && self.ast.at_const(expr).kind == NodeKind::NODE_ASSIGNMENT && self.ast.at_const(expr).as_data.binary.op == TokenType::Equal {
            let name = self.ast.at_const(expr).as_data.binary.left;
            if self.ast.at_const(name).kind != NodeKind::NODE_IDENTIFIER {
                self.error_here("a 'select' arm binds a plain name");
                bad = true;
            } else {
                // A value-less `let`: the resolver declares it (so the body can use the name) and the
                // desugar fills in the operation as its initializer.
                binding = self.ast.add(
                    Node {
                        kind: NodeKind::NODE_LET,
                        span: self.node_span(name),
                        as_data: NodeAs {
                            let_stmt: LetData { name: name, ty: NODE_NONE, value: NODE_NONE, is_mutable: false },
                        },
                    },
                );
            }
            expr = self.ast.at_const(expr).as_data.binary.right;
        }
        let mut kind = SelectArmKind::SELECT_DEFAULT;
        let mut op = NODE_NONE;
        let mut value = NODE_NONE;
        let ek = if expr == NODE_NONE {
            NodeKind::NODE_NONE_KIND;
        } else {
            self.ast.at_const(expr).kind;
        };
        if ek == NodeKind::NODE_IDENTIFIER && self.span_text_is(self.ast.at_const(expr).as_data.name.text, "default") {
            kind = SelectArmKind::SELECT_DEFAULT;
        } else if ek == NodeKind::NODE_CALL {
            let cd = self.ast.at_const(expr).as_data.call;
            let ck = self.ast.at_const(cd.callee).kind;
            let cn = if ck == NodeKind::NODE_IDENTIFIER {
                self.ast.at_const(cd.callee).as_data.name.text;
            } else {
                Span::empty();
            };
            if ck == NodeKind::NODE_IDENTIFIER && self.span_text_is(cn, "timeout") {
                kind = SelectArmKind::SELECT_TIMEOUT;
                if cd.args.len != 1 {
                    self.error_here("'timeout' takes one duration");
                    bad = true;
                } else {
                    op = unsafe self.ast.list(cd.args)[0];
                }
            } else if ck == NodeKind::NODE_MEMBER {
                let md = self.ast.at_const(cd.callee).as_data.member;
                let mname = self.ast.at_const(md.member).as_data.name.text;
                if self.span_text_is(mname, "recv") && cd.args.len == 0 {
                    kind = SelectArmKind::SELECT_RECV;
                    op = md.object;
                } else if self.span_text_is(mname, "send") && cd.args.len == 1 {
                    kind = SelectArmKind::SELECT_SEND;
                    op = md.object;
                    value = unsafe self.ast.list(cd.args)[0];
                } else {
                    self.error_here("a 'select' arm operation is 'ch.recv()', 'ch.send(v)', 'timeout(d)' or 'default'");
                    bad = true;
                }
            } else {
                self.error_here("a 'select' arm operation is 'ch.recv()', 'ch.send(v)', 'timeout(d)' or 'default'");
                bad = true;
            }
        } else {
            self.error_here("a 'select' arm operation is 'ch.recv()', 'ch.send(v)', 'timeout(d)' or 'default'");
            bad = true;
        }
        if !bad && binding != NODE_NONE && (kind == SelectArmKind::SELECT_TIMEOUT || kind == SelectArmKind::SELECT_DEFAULT) {
            self.error_here("a 'timeout' or 'default' arm binds nothing");
            bad = true;
        }
        // The channel is named twice by the lowering (arm it, then take from it), so it has to be a place
        // whose evaluation means the same both times. Anything else: bind it to a local first.
        if !bad && (kind == SelectArmKind::SELECT_RECV || kind == SelectArmKind::SELECT_SEND) && !self.is_select_place(
            op,
        ) {
            self.error_here("a 'select' arm's channel must be a name or a field path");
            bad = true;
        }
        // Consume the rest of the arm even after an error, so the next arm still parses.
        self.expect(TokenType::FatArrow, "'=>'");
        let body = self.parse_block();
        if bad {
            return NODE_NONE;
        }
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_SELECT_ARM,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs {
                    select_arm: SelectArmData { binding: binding, op: op, value: value, body: body, kind: kind },
                },
            },
        );
    }

    const fn is_select_place(self: &Self, id: NodeId) bool {
        let k = self.ast.at_const(id).kind;
        if k == NodeKind::NODE_IDENTIFIER {
            return true;
        }
        if k == NodeKind::NODE_MEMBER {
            return self.is_select_place(self.ast.at_const(id).as_data.member.object);
        }
        return false;
    }

    const fn span_text_is(self: &Self, sp: Span, s: str) bool {
        return self.text_is(Token::new(TokenType::Identifier, sp.start, sp.end - sp.start), s);
    }

    pub fn parse_block(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.expect(TokenType::LeftBrace, "'{'");
        let mark = self.ast.mark();
        while !self.check(TokenType::RightBrace) && !self.at_end() {
            self.ast.push(self.parse_statement());
        }
        let statements = self.ast.commit(mark);
        self.expect(TokenType::RightBrace, "'}'");
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_BLOCK,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { block: BlockData { statements: statements } },
            },
        );
    }

    pub const fn attr_kind_of(self: &Self, name: Token, wants_str: &mut bool, wants_int: &mut bool) i32 {
        *wants_str = false;
        *wants_int = false;
        if self.text_is(name, "inline") {
            return AttrKind::ATTR_INLINE as i32;
        }
        if self.text_is(name, "always_inline") {
            return AttrKind::ATTR_ALWAYS_INLINE as i32;
        }
        if self.text_is(name, "noinline") {
            return AttrKind::ATTR_NOINLINE as i32;
        }
        if self.text_is(name, "cold") {
            return AttrKind::ATTR_COLD as i32;
        }
        if self.text_is(name, "noreturn") {
            return AttrKind::ATTR_NORETURN as i32;
        }
        if self.text_is(name, "packed") {
            return AttrKind::ATTR_PACKED as i32;
        }
        if self.text_is(name, "used") {
            return AttrKind::ATTR_USED as i32;
        }
        if self.text_is(name, "unused") {
            return AttrKind::ATTR_UNUSED as i32;
        }
        if self.text_is(name, "align") {
            *wants_int = true;
            return AttrKind::ATTR_ALIGN as i32;
        }
        if self.text_is(name, "export") {
            *wants_str = true;
            return AttrKind::ATTR_EXPORT as i32;
        }
        if self.text_is(name, "import") {
            *wants_str = true;
            return AttrKind::ATTR_IMPORT as i32;
        }
        if self.text_is(name, "section") {
            *wants_str = true;
            return AttrKind::ATTR_SECTION as i32;
        }
        if self.text_is(name, "source") {
            *wants_str = true;
            return AttrKind::ATTR_C_SOURCE as i32;
        }
        if self.text_is(name, "link") {
            *wants_str = true;
            return AttrKind::ATTR_C_LINK as i32;
        }
        return -1;
    }

    fn parse_attribute_syntax(self: &mut Self) AttrSyntax {
        self.advance();
        let empty = Token::new(TokenType::Eof, self.previous_end(), 0);
        if !Parser::is_identifier_token(self.peek_type()) {
            self.error_here("expected an attribute path after '@'");
            return AttrSyntax {
                namespace: empty,
                name: empty,
                parts: 0,
                has_args: false,
                arg_start: self.current,
                arg_end: self.current,
            };
        }
        let namespace = self.advance();
        let mut name = namespace;
        let mut parts: u32 = 1;
        while self.match(TokenType::Dot) {
            if !Parser::is_identifier_token(self.peek_type()) && !self.check(TokenType::Import) {
                self.error_here("expected an attribute name after '.'");
                break;
            }
            name = self.advance();
            parts = parts + 1;
        }
        let has_args = self.match(TokenType::LeftParen);
        let arg_start = self.current;
        if has_args {
            let mut depth: u32 = 1;
            while depth > 0 && !self.at_end() {
                if self.check(TokenType::LeftParen) {
                    depth = depth + 1;
                } else if self.check(TokenType::RightParen) {
                    depth = depth - 1;
                    if depth == 0 {
                        break;
                    }
                }
                self.advance();
            }
        }
        let arg_end = self.current;
        if has_args {
            self.expect(TokenType::RightParen, "')'");
        }
        return AttrSyntax {
            namespace: namespace,
            name: name,
            parts: parts,
            has_args: has_args,
            arg_start: arg_start,
            arg_end: arg_end,
        };
    }

    const fn attr_arg(self: &Self, syntax: &AttrSyntax, offset: usize) Token {
        return self.tokens[syntax.arg_start + offset];
    }

    const fn attr_arg_count(syntax: &AttrSyntax) usize {
        return syntax.arg_end - syntax.arg_start;
    }

    fn parse_attr_int(self: &Self, lit: Token) u32 {
        let mut buf: [char; 24] = [
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
            0 as char,
        ];
        let mut k: usize = 0;
        let mut i = lit.start();
        while i < lit.end() && k + 1 < sizeof([char; 24]) {
            let ch = self.source[i as usize];
            if ch != b'_' {
                unsafe buf[k] = ch as char;
                k = k + 1;
            }
            i = i + 1;
        }
        unsafe buf[k] = 0 as char;
        return (unsafe stdlib::strtoul(&buf[0], null, 0)) as u32;
    }

    // `@arch` is `@platform`'s sibling on the instruction-set axis; the list grammar is identical, so
    // both go through one parser with the axis's names supplied by the caller.
    fn parse_platform_attr(self: &mut Self, syntax: &AttrSyntax, out: &mut Attr) {
        self.parse_axis_attr(syntax, out, false);
    }

    fn parse_arch_attr(self: &mut Self, syntax: &AttrSyntax, out: &mut Attr) {
        self.parse_axis_attr(syntax, out, true);
    }

    fn parse_axis_attr(self: &mut Self, syntax: &AttrSyntax, out: &mut Attr, is_arch: bool) {
        if !syntax.has_args {
            let msg = if is_arch {
                String::from_str(
                    "attribute '@arch' requires an architecture list, e.g. '@arch(x86_64)' or '@arch(x86_64 | aarch64)'",
                );
            } else {
                String::from_str(
                    "attribute '@platform' requires a platform list, e.g. '@platform(windows)' or '@platform(linux | macos)'",
                );
            };
            self.errors.emit(syntax.namespace.start(), syntax.namespace.len(), msg);
            return;
        }
        let count = Parser::attr_arg_count(syntax);
        let mut i: usize = 0;
        let mut mask: u32 = 0;
        let mut valid = count != 0;
        while valid && i < count {
            let neg = self.attr_arg(syntax, i).kind() == TokenType::Bang;
            if neg {
                i = i + 1;
            }
            if i >= count || self.attr_arg(syntax, i).kind() != TokenType::Identifier {
                valid = false;
                break;
            }
            let p = self.attr_arg(syntax, i);
            let mut bit: u32 = 0;
            if is_arch {
                bit = if self.text_is(p, "x86_64") {
                    1u32;
                } else if self.text_is(p, "aarch64") {
                    2u32;
                } else if self.text_is(p, "wasm32") {
                    4u32;
                } else {
                    0u32;
                };
            } else {
                bit = if self.text_is(p, "windows") {
                    1u32;
                } else if self.text_is(p, "macos") {
                    2u32;
                } else if self.text_is(p, "linux") {
                    4u32;
                } else if self.text_is(p, "wasm") {
                    8u32;
                } else if self.text_is(p, "ios") {
                    16u32;
                } else if self.text_is(p, "android") {
                    32u32;
                } else {
                    0u32;
                };
            }
            if bit == 0 {
                if is_arch {
                    self.errors.emit(
                        p.start(),
                        p.len(),
                        format(
                            "unknown architecture '{}'; expected x86_64, aarch64, or wasm32",
                            diag::span_str(self.source, p.start(), p.end()),
                        ),
                    );
                } else {
                    self.errors.emit(
                        p.start(),
                        p.len(),
                        format(
                            "unknown platform '{}'; expected windows, macos, linux, wasm, ios, or android",
                            diag::span_str(self.source, p.start(), p.end()),
                        ),
                    );
                }
                return;
            }
            // `!x` is every OTHER platform: the complement over the whole set, which grows with it.
            let all = if is_arch {
                7u32;
            } else {
                63u32;
            };
            mask = mask | if neg {
                bit ^ all;
            } else {
                bit;
            };
            i = i + 1;
            if i < count {
                if self.attr_arg(syntax, i).kind() != TokenType::Pipe {
                    valid = false;
                    break;
                }
                i = i + 1;
            }
        }
        if !valid {
            let t = if i < count {
                self.attr_arg(syntax, i);
            } else {
                syntax.name;
            };
            if is_arch {
                self.errors.emit(
                    t.start(),
                    t.len(),
                    format("expected an architecture name: x86_64, aarch64, or wasm32"),
                );
            } else {
                self.errors.emit(
                    t.start(),
                    t.len(),
                    format("expected a platform name: windows, macos, linux, wasm, ios, or android"),
                );
            }
            return;
        }
        out.arg = mask;
    }

    // `asm("template" : outs : ins : clobbers);` -- GCC extended assembly, passed through verbatim.
    // Every section is optional from the left, exactly as in C. Operands are `"constraint"(expr)` and are
    // stored as flat constraint/expression pairs; clobbers are bare string literals.
    fn parse_asm(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance(); // `asm`
        self.expect(TokenType::LeftParen, "'('");
        let template = self.parse_asm_string("an asm template");
        let mut outs = NodeList { start: 0, len: 0 };
        let mut ins = NodeList { start: 0, len: 0 };
        let mut clob = NodeList { start: 0, len: 0 };
        if self.match(TokenType::Colon) {
            outs = self.parse_asm_operands();
            if self.match(TokenType::Colon) {
                ins = self.parse_asm_operands();
                if self.match(TokenType::Colon) {
                    clob = self.parse_asm_clobbers();
                }
            }
        }
        self.expect(TokenType::RightParen, "')'");
        self.expect(TokenType::Semicolon, "';'");
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_ASM,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { asm_stmt: AsmData { template: template, outputs: outs, inputs: ins, clobbers: clob } },
            },
        );
    }

    fn parse_asm_operands(self: &mut Self) NodeList {
        let mark = self.ast.mark();
        while !self.check(TokenType::Colon) && !self.check(TokenType::RightParen) && !self.at_end() {
            // The constraint is a bare string literal, NOT an expression: `"=r"(out)` would otherwise
            // parse as a call of the string.
            let c = self.parse_asm_string("an asm constraint");
            self.expect(TokenType::LeftParen, "'('");
            let e = self.parse_expression();
            self.expect(TokenType::RightParen, "')'");
            self.ast.push(c);
            self.ast.push(e);
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        return self.ast.commit(mark);
    }

    fn parse_asm_clobbers(self: &mut Self) NodeList {
        let mark = self.ast.mark();
        while !self.check(TokenType::RightParen) && !self.at_end() {
            self.ast.push(self.parse_asm_string("an asm clobber"));
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        return self.ast.commit(mark);
    }

    // A string literal in operand position. Parsed directly so a following '(' stays the operand's,
    // not a call's.
    fn parse_asm_string(self: &mut Self, what: str) NodeId {
        if self.check(TokenType::StringLiteral) || self.check(TokenType::MatchertextLiteral) {
            return self.literal();
        }
        let t = self.raw_peek();
        self.errors.emit(t.start(), t.len(), format("{} must be a string literal", what));
        self.advance();
        return NODE_NONE;
    }

    pub fn parse_attribute(self: &mut Self, out: &mut Attr) bool {
        let syntax = self.parse_attribute_syntax();
        if syntax.parts == 0 {
            return false;
        }
        let ns = syntax.namespace;
        let argc = Parser::attr_arg_count(&syntax);
        if syntax.parts == 1 && self.text_is(ns, "emit_macro") {
            *out = Attr { owner: NODE_NONE, kind: AttrKind::ATTR_EMIT_MACRO as u8, arg: 0, str_span: Span::empty() };
            if syntax.has_args {
                self.errors.emit(ns.start(), ns.len(), format("attribute '@emit_macro' takes no arguments"));
            }
            return true;
        }
        if syntax.parts == 1 && self.text_is(ns, "bench") {
            // `arg` is 1 when the benchmark reports for itself: `@bench(log_results = false)` suppresses the
            // line the runner would otherwise print, for a benchmark whose output IS its own table.
            *out = Attr { owner: NODE_NONE, kind: AttrKind::ATTR_BENCH as u8, arg: 0, str_span: Span::empty() };
            if syntax.has_args {
                let named = argc == 3 && self.attr_arg(&syntax, 0).kind() == TokenType::Identifier && self.text_is(
                    self.attr_arg(&syntax, 0),
                    "log_results",
                ) && self.attr_arg(&syntax, 1).kind() == TokenType::Equal;
                let val = self.attr_arg(&syntax, 2).kind();
                if named && (val == TokenType::True || val == TokenType::False) {
                    out.arg = if val == TokenType::False {
                        1;
                    } else {
                        0;
                    };
                } else {
                    self.errors.emit(
                        ns.start(),
                        ns.len(),
                        format("attribute '@bench' accepts only '(log_results = true)' or '(log_results = false)'"),
                    );
                }
            }
            return true;
        }
        let test_kind = if self.text_is(ns, "test") {
            AttrKind::ATTR_TEST as i32;
        } else if self.text_is(ns, "test_init") {
            AttrKind::ATTR_TEST_INIT as i32;
        } else if self.text_is(ns, "test_free") {
            AttrKind::ATTR_TEST_FREE as i32;
        } else {
            -1;
        };
        if syntax.parts == 1 && test_kind >= 0 {
            *out = Attr { owner: NODE_NONE, kind: test_kind as u8, arg: 0, str_span: Span::empty() };
            if syntax.has_args {
                let valid = argc == 1 && self.attr_arg(&syntax, 0).kind() == TokenType::Identifier && if test_kind == AttrKind::ATTR_TEST as i32 {
                    self.text_is(self.attr_arg(&syntax, 0), "should_panic");
                } else {
                    self.text_is(self.attr_arg(&syntax, 0), "global");
                };
                if valid {
                    out.arg = 1;
                } else {
                    self.errors.emit(
                        ns.start(),
                        ns.len(),
                        String::from_str(
                            if test_kind == AttrKind::ATTR_TEST as i32 {
                                "attribute '@test' accepts only '(should_panic)'";
                            } else {
                                "'@test_init' / '@test_free' accept only '(global)'";
                            },
                        ),
                    );
                }
            }
            return true;
        }
        if syntax.parts == 1 && self.text_is(ns, "blocking") {
            *out = Attr { owner: NODE_NONE, kind: AttrKind::ATTR_BLOCKING as u8, arg: 0, str_span: Span::empty() };
            if syntax.has_args {
                self.errors.emit(ns.start(), ns.len(), format("attribute '@blocking' takes no arguments"));
            }
            return true;
        }
        if syntax.parts == 1 && self.text_is(ns, "no_const") {
            *out = Attr { owner: NODE_NONE, kind: AttrKind::ATTR_NO_CONST as u8, arg: 0, str_span: Span::empty() };
            if syntax.has_args {
                self.errors.emit(ns.start(), ns.len(), format("attribute '@no_const' takes no arguments"));
            }
            return true;
        }
        if syntax.parts == 1 && self.text_is(ns, "derive") {
            // Sugar, fully expanded at parse: each listed interface becomes an empty
            // `extend T as I {}` sibling of the next struct/union/enum, which then INHERITS the
            // interface's default bodies. No Attr record survives -- the extends are the record.
            if !syntax.has_args || Parser::attr_arg_count(&syntax) == 0 {
                self.errors.emit(
                    ns.start(),
                    ns.len(),
                    format(
                        "attribute '@derive' requires an interface list, e.g. '@derive(Format)' or '@derive(Format, Hash)'",
                    ),
                );
                return false;
            }
            self.derive_start = ns.start();
            self.derive_end = self.previous_end();
            if self.expand_derive {
                // Re-parse the captured token range as types: `current` rewinds into the argument
                // slice and is restored, so `@derive(Conv<i32>)` gets a real generic type node.
                let save = self.current;
                self.current = syntax.arg_start;
                while self.current < syntax.arg_end {
                    let t = self.parse_type_path();
                    if t != NODE_NONE {
                        self.derive_ifaces.push(t);
                    }
                    if self.current < syntax.arg_end && !self.match(TokenType::Comma) {
                        let bad = self.raw_peek();
                        self.errors.emit(
                            bad.start(),
                            bad.len(),
                            format("expected ',' between '@derive' interface names"),
                        );
                        break;
                    }
                }
                self.current = save;
            }
            return false;
        }
        if syntax.parts == 1 && self.text_is(ns, "reflect") {
            // User metadata for the reflection descriptor: `@reflect(hidden)`,
            // `@reflect(label = "Speed", max = 100)`. Keys with no value read as `true`. Stored in
            // the metas side table; no Attr record survives.
            if !syntax.has_args || Parser::attr_arg_count(&syntax) == 0 {
                self.errors.emit(
                    ns.start(),
                    ns.len(),
                    format(
                        "attribute '@reflect' requires entries, e.g. '@reflect(hidden)' or '@reflect(label = \"x\", max = 100)'",
                    ),
                );
                return false;
            }
            let count = Parser::attr_arg_count(&syntax);
            let mut i: usize = 0;
            while i < count {
                let k = self.attr_arg(&syntax, i);
                if k.kind() != TokenType::Identifier {
                    self.errors.emit(k.start(), k.len(), format("expected a '@reflect' key name"));
                    break;
                }
                let mut ma = MetaAttr { owner: NODE_NONE, vkind: 0, ival: 1, key: k.span(), vspan: Span::empty() };
                i = i + 1;
                if i < count && self.attr_arg(&syntax, i).kind() == TokenType::Equal {
                    i = i + 1;
                    let mut vok = i < count;
                    if vok {
                        let v = self.attr_arg(&syntax, i);
                        if v.kind() == TokenType::True {
                            ma.ival = 1;
                        } else if v.kind() == TokenType::False {
                            ma.ival = 0;
                        } else if v.kind() == TokenType::IntegerLiteral {
                            ma.vkind = 1;
                            ma.ival = self.parse_attr_int(v);
                        } else if v.kind() == TokenType::StringLiteral {
                            ma.vkind = 2;
                            ma.vspan = Span::new(v.start() + 1, v.end() - 1);
                        } else {
                            vok = false;
                        }
                    }
                    if !vok {
                        let at = if i < count {
                            self.attr_arg(&syntax, i);
                        } else {
                            syntax.name;
                        };
                        self.errors.emit(
                            at.start(),
                            at.len(),
                            format("a '@reflect' value is an integer, a string, 'true', or 'false'"),
                        );
                        break;
                    }
                    i = i + 1;
                }
                self.pending_metas.push(ma);
                if i < count {
                    if self.attr_arg(&syntax, i).kind() != TokenType::Comma {
                        let at = self.attr_arg(&syntax, i);
                        self.errors.emit(at.start(), at.len(), format("expected ',' between '@reflect' entries"));
                        break;
                    }
                    i = i + 1;
                }
            }
            return false;
        }
        if syntax.parts == 1 && self.text_is(ns, "platform") {
            *out = Attr { owner: NODE_NONE, kind: AttrKind::ATTR_PLATFORM as u8, arg: 0, str_span: Span::empty() };
            self.parse_platform_attr(&syntax, out);
            return true;
        }
        if syntax.parts == 1 && self.text_is(ns, "arch") {
            *out = Attr { owner: NODE_NONE, kind: AttrKind::ATTR_ARCH as u8, arg: 0, str_span: Span::empty() };
            self.parse_arch_attr(&syntax, out);
            return true;
        }
        if self.text_is(ns, "fmt") {
            if syntax.parts == 2 && self.text_is(syntax.name, "skip") {
                *out = Attr { owner: NODE_NONE, kind: AttrKind::ATTR_FMT_SKIP as u8, arg: 0, str_span: Span::empty() };
                if syntax.has_args {
                    self.errors.emit(ns.start(), ns.len(), format("attribute '@fmt.skip' takes no arguments"));
                }
                return true;
            }
            self.errors.emit(
                syntax.name.start(),
                syntax.name.len(),
                format("unknown attribute; the 'fmt' namespace supports only '@fmt.skip'"),
            );
            return false;
        }
        if !self.text_is(ns, "c") {
            if !self.bootstrap_tags {
                self.errors.emit(
                    ns.start(),
                    ns.len(),
                    format(
                        "unknown attribute '@{}'; pass --bootstrap-tags to accept unknown attributes",
                        diag::span_str(self.source, ns.start(), ns.end()),
                    ),
                );
            }
            return false;
        }
        if syntax.parts != 2 {
            self.errors.emit(
                syntax.name.start(),
                syntax.name.len(),
                String::from_str(
                    if syntax.parts < 2 {
                        "expected an attribute name after '@c.'";
                    } else {
                        "target-specific attribute namespaces (e.g. '@c.gnu.*') are not supported";
                    },
                ),
            );
            return false;
        }
        let mut wants_str = false;
        let mut wants_int = false;
        let kind = self.attr_kind_of(syntax.name, &mut wants_str, &mut wants_int);
        if kind < 0 {
            if !self.bootstrap_tags {
                self.errors.emit(
                    syntax.name.start(),
                    syntax.name.len(),
                    format(
                        "unknown attribute '@c.{}'; pass --bootstrap-tags to accept unknown attributes",
                        diag::span_str(self.source, syntax.name.start(), syntax.name.end()),
                    ),
                );
                self.errors.note(
                    format(
                        "supported '@c' attributes include export, import, noreturn, always_inline, cold, used, unused, section, packed, and align",
                    ),
                );
            }
            return false;
        }
        *out = Attr { owner: NODE_NONE, kind: kind as u8, arg: 0, str_span: Span::empty() };
        if wants_str || wants_int {
            if !syntax.has_args {
                self.errors.emit(
                    syntax.name.start(),
                    syntax.name.len(),
                    format(
                        "attribute '@c.{}' requires an argument",
                        diag::span_str(self.source, syntax.name.start(), syntax.name.end()),
                    ),
                );
            } else if argc != 1 || wants_int && self.attr_arg(&syntax, 0).kind() != TokenType::IntegerLiteral || wants_str && self.attr_arg(
                &syntax,
                0,
            ).kind() != TokenType::StringLiteral {
                let t = if argc != 0 {
                    self.attr_arg(&syntax, 0);
                } else {
                    syntax.name;
                };
                self.errors.emit(
                    t.start(),
                    t.len(),
                    String::from_str(
                        if wants_int {
                            "expected an integer argument";
                        } else {
                            "expected a string argument";
                        },
                    ),
                );
            } else {
                let arg = self.attr_arg(&syntax, 0);
                if wants_int {
                    out.arg = self.parse_attr_int(arg);
                } else {
                    out.str_span = Span::new(arg.start() + 1, arg.end() - 1);
                }
            }
        } else if syntax.has_args {
            self.errors.emit(
                syntax.name.start(),
                syntax.name.len(),
                format(
                    "attribute '@c.{}' takes no arguments",
                    diag::span_str(self.source, syntax.name.start(), syntax.name.end()),
                ),
            );
        }
        return true;
    }

    pub fn parse_attributes(self: &mut Self, cap: usize) Vector<Attr> {
        // A stray pending `@reflect` (its position never reached add_attrs_to) is an error, not a
        // silent transfer to whatever declaration comes next.
        if self.pending_metas.len() > 0 {
            self.flush_metas_to(NODE_NONE);
        }
        let mut attrs = Vector::<Attr>::new();
        if !self.check(TokenType::At) {
            return attrs;
        }
        attrs.reserve(cap);
        while self.check(TokenType::At) {
            let mut attr = Attr { owner: NODE_NONE, kind: 0, arg: 0, str_span: Span::empty() };
            if self.parse_attribute(&mut attr) && attrs.len() < cap {
                attrs.push(attr);
            }
        }
        return attrs;
    }

    pub fn add_attrs_to(self: &mut Self, attrs: &mut Vector<Attr>, owner: NodeId) {
        for i in 0..attrs.len() {
            let mut attr = attrs[i];
            attr.owner = owner;
            self.ast.add_attr(attr);
        }
        self.flush_metas_to(owner);
    }

    // Attach pending `@reflect` entries to their declaration -- or reject the position.
    fn flush_metas_to(self: &mut Self, owner: NodeId) {
        if self.pending_metas.len() == 0 {
            return;
        }
        let mut ok = owner != NODE_NONE;
        if ok {
            let k = self.ast.at_const(owner).kind;
            ok = k == NodeKind::NODE_STRUCT || k == NodeKind::NODE_ENUM || k == NodeKind::NODE_FIELD || k == NodeKind::NODE_VARIANT || k == NodeKind::NODE_FUNCTION;
        }
        for i in 0..self.pending_metas.len() {
            let mut ma = *self.pending_metas.at(i);
            if !ok {
                self.errors.emit(
                    ma.key.start,
                    ma.key.end - ma.key.start,
                    format("'@reflect' applies to a struct, enum, field, variant, or function declaration"),
                );
                break;
            }
            ma.owner = owner;
            self.ast.add_meta(ma);
        }
        self.pending_metas.clear();
    }

    pub fn validate_item_attrs(self: &mut Self, attrs: &mut Vector<Attr>, owner: NodeId) {
        for i in 0..attrs.len() {
            let attr = attrs.at(i);
            let mut sp = Span::empty();
            let mut valid_test = false;
            let mut generic_aggregate = false;
            if owner != NODE_NONE {
                let d = self.ast.at_const(owner);
                sp = d.span;
                valid_test = d.kind == NodeKind::NODE_FUNCTION && d.as_data.function.generics.len == 0;
                generic_aggregate = (d.kind == NodeKind::NODE_STRUCT || d.kind == NodeKind::NODE_ENUM) && d.as_data.aggregate.generics.len != 0;
            }
            if attr.kind == AttrKind::ATTR_BENCH as u8 && !valid_test {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("'@bench' may only be applied to a non-generic function"),
                );
            }
            if (attr.kind == AttrKind::ATTR_TEST as u8 || attr.kind == AttrKind::ATTR_TEST_INIT as u8 || attr.kind == AttrKind::ATTR_TEST_FREE as u8) && !valid_test {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("'@test' / '@test_init' / '@test_free' may only be applied to a non-generic function"),
                );
            }
            if (attr.kind == AttrKind::ATTR_C_SOURCE as u8 || attr.kind == AttrKind::ATTR_C_LINK as u8) && (owner == NODE_NONE || self.ast.at_const(
                owner,
            ).kind != NodeKind::NODE_EXTERN_BLOCK) {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("'@c.source' / '@c.link' may only be applied to an 'extern \"C\"' block"),
                );
            }
            if attr.kind == AttrKind::ATTR_NO_CONST as u8 && (owner == NODE_NONE || self.ast.at_const(owner).kind != NodeKind::NODE_STRUCT && self.ast.at_const(
                owner,
            ).kind != NodeKind::NODE_ENUM) {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("'@no_const' may only be applied to a struct, union, or enum declaration"),
                );
            }
            if attr.kind == AttrKind::ATTR_EMIT_MACRO as u8 && !generic_aggregate {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("'@emit_macro' may only be applied to a generic struct or enum"),
                );
                self.errors.note(
                    format("write it before a declaration like 'struct Box<T> {{ ... }}' or 'enum Option<T> {{ ... }}'"),
                );
            }
        }
    }

    pub fn parse_import(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let mark = self.ast.mark();
        let first = self.identifier();
        self.ast.push(first);
        while self.match(TokenType::PathSeparator) {
            self.ast.push(self.identifier());
        }
        let path = self.ast.commit(mark);
        let mut alias = NODE_NONE;
        let mut glob = false;
        if self.match(TokenType::As) {
            if self.match(TokenType::Star) {
                glob = true;
            } else {
                alias = self.identifier();
            }
        }
        self.expect(TokenType::Semicolon, "';'");
        return self.ast.add(
            Node {
                kind: NodeKind::NODE_IMPORT,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { import_decl: ImportData { path: path, alias: alias, glob: glob } },
            },
        );
    }

    pub const fn is_literal_token(kind: TokenType) bool {
        return kind == TokenType::IntegerLiteral || kind == TokenType::FloatLiteral || kind == TokenType::CharacterLiteral || kind == TokenType::ByteCharacterLiteral || kind == TokenType::StringLiteral || kind == TokenType::MatchertextLiteral || kind == TokenType::ByteStringLiteral || kind == TokenType::True || kind == TokenType::False || kind == TokenType::Null;
    }

    pub const fn unary_operator(kind: TokenType) bool {
        return kind == TokenType::Bang || kind == TokenType::Tilde || kind == TokenType::Minus || kind == TokenType::Star || kind == TokenType::Ampersand || kind == TokenType::Move || kind == TokenType::Unsafe;
    }

    pub const fn precedence(kind: TokenType) i32 {
        return switch kind {
            Star | Slash | Percent => 11,
            Plus | Minus => 10,
            LeftShift | RightShift => 9,
            LessThan | LessThanEqual | GreaterThan | GreaterThanEqual => 8,
            EqualEqual | BangEqual => 7,
            Ampersand => 6,
            Caret => 5,
            Pipe => 4,
            AmpersandAmpersand => 3,
            PipePipe => 2,
            _ => 0,
        };
    }

    pub const fn assignment_operator(kind: TokenType) bool {
        return kind == TokenType::Equal || kind == TokenType::PlusEqual || kind == TokenType::MinusEqual || kind == TokenType::StarEqual || kind == TokenType::SlashEqual || kind == TokenType::PercentEqual || kind == TokenType::AmpersandEqual || kind == TokenType::PipeEqual || kind == TokenType::CaretEqual || kind == TokenType::LeftShiftEqual || kind == TokenType::RightShiftEqual;
    }

    pub fn build_ast(self: &mut Self) {
        let mark = self.ast.mark();
        while !self.at_end() {
            let before = self.current;
            let item = self.parse_item();
            if item != NODE_NONE {
                self.ast.push(item);
            }
            // progress guarantee: a failed item that consumed nothing must not loop forever
            if self.current == before && !self.at_end() {
                self.advance();
            }
        }
        let items = self.ast.commit(mark);
        self.ast.root = self.ast.add(
            Node {
                kind: NodeKind::NODE_PROGRAM,
                span: Span::new(0, self.source.len() as u32),
                as_data: NodeAs { program: ProgramData { items: items } },
            },
        );
        self.errors.finalize(self.source, self.file);
    }

    pub const fn has_errors(self: &Self) bool {
        return self.errors.has_errors();
    }
    pub fn log_errors(self: &Self) {
        self.errors.log();
    }
}

extend Parser as Free {
    pub fn free(self: &mut Self) {
        self.tokens.free();
        self.ast.free();
        self.errors.free();
        self.nrets.free();
        self.derive_ifaces.free();
        self.pending_metas.free();
    }
}
