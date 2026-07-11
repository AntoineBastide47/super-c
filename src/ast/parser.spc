import string as cstring;
import stdlib;
import lexer::token as *;
import lexer::token_type as *;
import ast::ast as *;
import utils::errors as diag;

pub const PARSE_MAX_DEPTH: u32 = 256;

pub enum RangeContext { RANGE_FOR, RANGE_PATTERN, RANGE_EXPR }

pub struct Parser {
    pub source: *const u8,
    pub len: usize,
    pub tokens: Vector<Token>,
    pub current: usize,
    pub pending_gt: u32,
    pub depth: u32,
    pub allow_struct_initializer: bool,
    pub ast: Ast,
    pub file: *const char,
    pub errors: diag::Errors,
    pub bootstrap_tags: bool, // accept unknown @attributes without error (bootstrap across a new tag)
}

extend Parser {
    pub fn new(tokens: Vector<Token>, source: str) Parser {
        let token_count = tokens.len();
        return Parser {
            source: source.ptr(),
            len: source.len(),
            tokens: tokens,
            current: 0,
            pending_gt: 0,
            depth: 0,
            allow_struct_initializer: true,
            ast: Ast::new(token_count),
            file: null,
            errors: diag::Errors::new(),
            bootstrap_tags: false,
        };
    }

    pub fn set_file(self: &mut Self, file: *const char) void {
        self.file = file;
    }
    pub fn set_bootstrap_tags(self: &mut Self, v: bool) void {
        self.bootstrap_tags = v;
    }

    // Consume a balanced `(...)` if the attribute has an argument list -- lets the parser skip past the
    // args of an attribute whose shape it does not recognize (generic/unknown-tag handling).
    fn skip_attr_args(self: &mut Self) void {
        if self.match(TokenType::LeftParen) {
            let mut depth = 1;
            while depth > 0 && !self.at_end() {
                if self.check(TokenType::LeftParen) {
                    depth = depth + 1;
                }
                else if self.check(TokenType::RightParen) {
                    depth = depth - 1;
                }
                self.advance();
            }
        }
    }

    pub fn take_ast(self: &mut Self) Ast {
        let out = self.ast;
        self.ast = Ast::new(0);
        return out;
    }

    pub fn raw_peek(self: &Self) Token {
        return self.tokens[self.current];
    }

    pub fn peek_type(self: &Self) TokenType {
        if self.pending_gt != 0 {
            return TokenType::GreaterThan;
        }
        return self.raw_peek().kind();
    }

    pub fn at_end(self: &Self) bool {
        return self.peek_type() == TokenType::Eof;
    }

    pub fn advance(self: &mut Self) Token {
        if self.pending_gt != 0 {
            self.pending_gt = self.pending_gt - 1;
            let source = self.tokens[self.current - 1];
            return Token::new(TokenType::GreaterThan, source.end() - 1, 1);
        }
        let t = self.raw_peek();
        if t.kind() != TokenType::Eof {
            self.current = self.current + 1;
        }
        return t;
    }

    pub fn check(self: &Self, kind: TokenType) bool {
        return self.peek_type() == kind;
    }

    pub fn text_is(self: &Self, t: Token, s: str) bool {
        let sl = s.len();
        return (t.len() as usize) == sl && unsafe cstring::memcmp((unsafe (self.source + (t.start() as usize))), s.ptr(), sl) == 0;
    }

    pub fn peek_ident_is(self: &Self, kw: str) bool {
        let t = self.raw_peek();
        if t.kind() != TokenType::Identifier {
            return false;
        }
        return self.text_is(t, kw);
    }

    pub fn match(self: &mut Self, kind: TokenType) bool {
        if !self.check(kind) {
            return false;
        }
        self.advance();
        return true;
    }

    pub fn previous_end(self: &Self) u32 {
        if self.pending_gt != 0 {
            return self.tokens[self.current - 1].end() - self.pending_gt;
        }
        if self.current != 0 {
            return self.tokens[self.current - 1].end();
        }
        return 0;
    }

    pub fn node_span(self: &Self, id: NodeId) Span {
        if id == NODE_NONE {
            return Span::empty();
        }
        return self.ast.at_const(id).span;
    }

    @c.cold
    pub fn error_here(self: &mut Self, message: str) void {
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
        if self.match(TokenType::GreaterThan) {
            return true;
        }
        if self.pending_gt == 0 && self.check(TokenType::RightShift) {
            self.advance();
            self.pending_gt = 1;
            return true;
        }
        return self.expect(TokenType::GreaterThan, "'>'");
    }

    pub fn is_type_start(kind: TokenType) bool {
        return kind == TokenType::Identifier || kind == TokenType::SelfUpper || kind == TokenType::Star || kind == TokenType::Ampersand || kind == TokenType::LeftBracket || kind == TokenType::Fn;
    }

    pub fn identifier(self: &mut Self) NodeId {
        if !self.check(TokenType::Identifier) && !self.check(TokenType::SelfUpper) {
            self.error_here("expected identifier");
            if !self.at_end() {
                self.advance();
            }
            return NODE_NONE;
        }
        let token = self.advance();
        return self.ast.add(Node {
                kind: NodeKind::NODE_IDENTIFIER,
                span: token.span(),
                as_data: NodeAs { name: NameData { text: token.span(), is_mutable: false } },
            });
    }

    pub fn callable_name(self: &mut Self) NodeId {
        if !self.check(TokenType::Identifier) && !self.check(TokenType::SelfUpper) && !self.check(TokenType::New) {
            self.error_here("expected identifier");
            if !self.at_end() {
                self.advance();
            }
            return NODE_NONE;
        }
        let token = self.advance();
        return self.ast.add(Node {
                kind: NodeKind::NODE_IDENTIFIER,
                span: token.span(),
                as_data: NodeAs { name: NameData { text: token.span(), is_mutable: false } },
            });
    }

    pub fn literal(self: &mut Self) NodeId {
        let token = self.advance();
        return self.ast.add(Node {
                kind: NodeKind::NODE_LITERAL,
                span: token.span(),
                as_data: NodeAs { literal: LiteralData { raw: token.span(), token_type: token.kind() } },
            });
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
        while !self.check(TokenType::GreaterThan) && !self.check(TokenType::RightShift) && !self.at_end() {
            // A bare integer literal in argument position is a const-generic value (e.g. `Buff<i32, 4>`).
            let arg = if self.check(TokenType::IntegerLiteral) { self.literal(); } else { self.parse_type(); };
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
        let args = if self.check(TokenType::LessThan) { self.parse_type_args(); } else { NodeList { start: 0, len: 0 }; };
        return self.ast.add(Node {
                kind: NodeKind::NODE_TYPE_PATH,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { type_path: TypePathData { parts: parts, args: args } },
            });
    }

    pub fn parse_type_path(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        let head = self.identifier();
        return self.parse_type_path_after(head, start);
    }

    pub fn parse_cast_type(self: &mut Self) NodeId {
        if !self.check(TokenType::Identifier) && !self.check(TokenType::SelfUpper) {
            return self.parse_type();
        }
        let start = self.raw_peek().start();
        let mark = self.ast.mark();
        self.ast.push(self.identifier());
        while self.match(TokenType::PathSeparator) {
            self.ast.push(self.identifier());
        }
        return self.ast.add(Node {
                kind: NodeKind::NODE_TYPE_PATH,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { type_path: TypePathData { parts: self.ast.commit(mark), args: NodeList { start: 0, len: 0 } } },
            });
    }

    pub fn parse_qualifier(self: &mut Self) TypeQualifier {
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
                return self.ast.add(Node {
                        kind: NodeKind::NODE_DYN_TYPE,
                        span: Span::new(start, self.node_span(inner).end),
                        as_data: NodeAs { indirect_type: IndirectTypeData { ty: inner, qualifier: if qualifier == TypeQualifier::TYPE_QUAL_MUT { TypeQualifier::TYPE_QUAL_MUT; } else { TypeQualifier::TYPE_QUAL_CONST; } } },
                    });
            }
            let ty = self.parse_type();
            return self.ast.add(Node {
                    kind: if opener == TokenType::Star { NodeKind::NODE_POINTER_TYPE; } else { NodeKind::NODE_REFERENCE_TYPE; },
                    span: Span::new(start, self.node_span(ty).end),
                    as_data: NodeAs { indirect_type: IndirectTypeData { ty: ty, qualifier: qualifier } },
                });
        }
        if self.match(TokenType::LeftBracket) {
            if self.match(TokenType::RightBracket) {
                let qualifier = if self.match(TokenType::Mut) { TypeQualifier::TYPE_QUAL_MUT; } else { TypeQualifier::TYPE_QUAL_NONE; };
                let element = self.parse_type();
                return self.ast.add(Node {
                        kind: NodeKind::NODE_SLICE_TYPE,
                        span: Span::new(start, self.node_span(element).end),
                        as_data: NodeAs { indirect_type: IndirectTypeData { ty: element, qualifier: qualifier } },
                    });
            }
            let element = self.parse_type();
            self.expect(TokenType::Semicolon, "';'");
            let length = self.parse_expression();
            self.expect(TokenType::RightBracket, "']'");
            return self.ast.add(Node {
                    kind: NodeKind::NODE_ARRAY_TYPE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { array_type: ArrayTypeData { element: element, length: length } },
                });
        }
        if self.match(TokenType::Fn) {
            self.expect(TokenType::LeftParen, "'('");
            let params = self.parse_comma_types(TokenType::RightParen);
            self.expect(TokenType::RightParen, "')'");
            let returns = self.parse_function_returns();
            return self.ast.add(Node {
                    kind: NodeKind::NODE_FUNCTION_TYPE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { function_type: FunctionTypeData { params: params, returns: returns, is_move: false } },
                });
        }
        if self.match(TokenType::LeftParen) {
            let elems = self.parse_comma_types(TokenType::RightParen);
            self.expect(TokenType::RightParen, "')'");
            if elems.len < 2 {
                self.errors.emit(start, self.previous_end() - start, format("a tuple type needs at least 2 elements"));
            }
            return self.ast.add(Node {
                    kind: NodeKind::NODE_TUPLE_TYPE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { array_literal: ArrayLiteralData { elements: elems } },
                });
        }
        if self.match(TokenType::Dyn) {
            let inner = self.parse_type();
            return self.ast.add(Node {
                    kind: NodeKind::NODE_DYN_TYPE,
                    span: Span::new(start, self.node_span(inner).end),
                    as_data: NodeAs { indirect_type: IndirectTypeData { ty: inner, qualifier: TypeQualifier::TYPE_QUAL_NONE } },
                });
        }
        if self.check(TokenType::Identifier) || self.check(TokenType::SelfUpper) {
            return self.parse_type_path();
        }
        self.error_here("expected type");
        if !self.at_end() {
            self.advance();
        }
        return NODE_NONE;
    }

    pub fn parse_bound(self: &mut Self) NodeId {
        if !self.check(TokenType::Fn) {
            return self.parse_type_path();
        }
        let start = self.raw_peek().start();
        self.advance();
        let is_move = self.match(TokenType::Move);
        self.expect(TokenType::LeftParen, "'('");
        let params = self.parse_comma_types(TokenType::RightParen);
        self.expect(TokenType::RightParen, "')'");
        let returns = self.parse_function_returns();
        return self.ast.add(Node {
                kind: NodeKind::NODE_FUNCTION_TYPE,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { function_type: FunctionTypeData { params: params, returns: returns, is_move: is_move } },
            });
    }

    pub fn parse_bounds(self: &mut Self) NodeList {
        let mark = self.ast.mark();
        self.ast.push(self.parse_bound());
        while self.match(TokenType::Plus) {
            self.ast.push(self.parse_bound());
        }
        return self.ast.commit(mark);
    }

    pub fn parse_generics(self: &mut Self) NodeList {
        if !self.match(TokenType::LessThan) {
            return NodeList { start: 0, len: 0 };
        }
        let mark = self.ast.mark();
        while !self.check(TokenType::GreaterThan) && !self.check(TokenType::RightShift) && !self.at_end() {
            let start = self.raw_peek().start();
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
            let default_type = if !is_const && self.match(TokenType::Equal) { self.parse_type(); } else { NODE_NONE; };
            self.ast.push(self.ast.add(Node {
                    kind: NodeKind::NODE_GENERIC_PARAM,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { generic_param: GenericParamData { name: name, bounds: bounds, default_type: default_type, is_const: is_const, const_type: const_type } },
                }));
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
            let ty = self.parse_type();
            self.expect(TokenType::Colon, "':'");
            let bounds = self.parse_bounds();
            self.ast.push(self.ast.add(Node {
                    kind: NodeKind::NODE_WHERE_PREDICATE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { where_predicate: WherePredicateData { ty: ty, bounds: bounds } },
                }));
            if !self.match(TokenType::Comma) || self.check(TokenType::LeftBrace) || self.check(TokenType::Semicolon) {
                break;
            }
        }
        return self.ast.commit(mark);
    }

    pub fn parse_parameter_name(self: &mut Self) NodeId {
        if self.match(TokenType::SelfLower) {
            let token = self.tokens[self.current - 1];
            return self.ast.add(Node {
                    kind: NodeKind::NODE_IDENTIFIER,
                    span: token.span(),
                    as_data: NodeAs { name: NameData { text: token.span(), is_mutable: false } },
                });
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
                let param = self.ast.add(Node {
                        kind: NodeKind::NODE_PARAMETER,
                        span: Span::new(span_start, span_end),
                        as_data: NodeAs { parameter: ParameterData { name: name, ty: ty, is_mutable: is_mutable } },
                    });
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
            if self.check(TokenType::Identifier) {
                let start = self.raw_peek().start();
                let head = self.identifier();
                if self.match(TokenType::Colon) {
                    let ty = self.parse_type();
                    self.ast.push(self.ast.add(Node {
                            kind: NodeKind::NODE_PARAMETER,
                            span: Span::new(start, self.node_span(ty).end),
                            as_data: NodeAs { parameter: ParameterData { name: head, ty: ty, is_mutable: false } },
                        }));
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
        let generics = self.parse_generics();
        let mut is_variadic = false;
        let params = self.parse_parameters(&mut is_variadic);
        let returns = self.parse_function_returns();
        let where_clause = self.parse_where_clause();
        let mut body = NODE_NONE;
        if self.check(TokenType::LeftBrace) {
            body = self.parse_block();
        }
        else if require_body {
            self.error_here("expected function body");
        }
        return self.ast.add(Node {
                kind: NodeKind::NODE_FUNCTION,
                span: Span::new(start, if body != NODE_NONE { self.node_span(body).end; } else { self.previous_end(); }),
                as_data: NodeAs { function: FunctionData {
                        name: name,
                        generics: generics,
                        params: params,
                        returns: returns,
                        where_clause: where_clause,
                        body: body,
                        is_public: false,
                        is_extern: false,
                        is_variadic: is_variadic,
                    } },
            });
    }

    pub fn parse_field(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        let is_public = self.match(TokenType::Pub);
        let name = self.identifier();
        self.expect(TokenType::Colon, "':'");
        let ty = self.parse_type();
        return self.ast.add(Node {
                kind: NodeKind::NODE_FIELD,
                span: Span::new(start, self.node_span(ty).end),
                as_data: NodeAs { field: FieldData { name: name, ty: ty, value: NODE_NONE, is_public: is_public } },
            });
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
        let generics = self.parse_generics();
        if self.match(TokenType::Semicolon) {
            return self.ast.add(Node {
                    kind: NodeKind::NODE_STRUCT,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { aggregate: AggregateData { name: name, generics: generics, members: NodeList { start: 0, len: 0 }, is_public: false, is_union: false, is_tuple: false } },
                });
        }
        if self.match(TokenType::LeftParen) {
            let types = self.parse_comma_types(TokenType::RightParen);
            self.expect(TokenType::RightParen, "')'");
            self.expect(TokenType::Semicolon, "';'");
            return self.ast.add(Node {
                    kind: NodeKind::NODE_STRUCT,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { aggregate: AggregateData { name: name, generics: generics, members: types, is_public: false, is_union: false, is_tuple: true } },
                });
        }
        self.expect(TokenType::LeftBrace, "'{'");
        let fields = self.parse_fields();
        self.expect(TokenType::RightBrace, "'}'");
        return self.ast.add(Node {
                kind: NodeKind::NODE_STRUCT,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { aggregate: AggregateData { name: name, generics: generics, members: fields, is_public: false, is_union: false, is_tuple: false } },
            });
    }

    pub fn parse_variant(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
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
        return self.ast.add(Node {
                kind: NodeKind::NODE_VARIANT,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { variant: VariantData { name: name, payload: payload, struct_payload: struct_payload, value: value } },
            });
    }

    pub fn parse_enum(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let name = self.identifier();
        let generics = self.parse_generics();
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
        return self.ast.add(Node {
                kind: NodeKind::NODE_ENUM,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { aggregate: AggregateData { name: name, generics: generics, members: variants, is_public: false, is_union: false, is_tuple: false } },
            });
    }

    pub fn parse_type_alias(self: &mut Self, opaque: bool) NodeId {
        let start = self.raw_peek().start();
        self.expect(TokenType::Type, "'type'");
        let name = self.identifier();
        let generics = if opaque { NodeList { start: 0, len: 0 }; } else { self.parse_generics(); };
        let mut ty = NODE_NONE;
        if !opaque || self.match(TokenType::Equal) {
            if !opaque {
                self.expect(TokenType::Equal, "'='");
            }
            ty = self.parse_type();
        }
        self.expect(TokenType::Semicolon, "';'");
        return self.ast.add(Node {
                kind: NodeKind::NODE_TYPE_ALIAS,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { type_alias: TypeAliasData { name: name, generics: generics, ty: ty, is_public: false } },
            });
    }

    pub fn parse_const(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let name = self.identifier();
        self.expect(TokenType::Colon, "':'");
        let ty = self.parse_type();
        self.expect(TokenType::Equal, "'='");
        let value = self.parse_expression();
        self.expect(TokenType::Semicolon, "';'");
        return self.ast.add(Node {
                kind: NodeKind::NODE_CONST,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { const_def: ConstData { name: name, ty: ty, value: value, is_public: false, is_extern: false, is_static_mut: false } },
            });
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
        return self.ast.add(Node {
                kind: NodeKind::NODE_CONST,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { const_def: ConstData { name: name, ty: ty, value: value, is_public: false, is_extern: false, is_static_mut: true } },
            });
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
            }
            else {
                self.error_here("static_assert message must be a string literal");
            }
        }
        self.expect(TokenType::RightParen, "')'");
        self.expect(TokenType::Semicolon, "';'");
        return self.ast.add(Node {
                kind: NodeKind::NODE_STATIC_ASSERT,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { binary: BinaryData { op: TokenType::Equal, left: cond, right: msg } },
            });
    }

    pub fn parse_interface(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let name = self.identifier();
        let generics = self.parse_generics();
        let bounds = if self.match(TokenType::Colon) { self.parse_bounds(); } else { NodeList { start: 0, len: 0 }; };
        self.expect(TokenType::LeftBrace, "'{'");
        let mark = self.ast.mark();
        while !self.check(TokenType::RightBrace) && !self.at_end() {
            if self.check(TokenType::Fn) {
                let f = self.parse_function(false);
                if self.ast.at_const(f).as_data.function.body == NODE_NONE {
                    self.expect(TokenType::Semicolon, "';'");
                }
                self.ast.push(f);
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
        return self.ast.add(Node {
                kind: NodeKind::NODE_INTERFACE,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { interface_def: InterfaceData { name: name, generics: generics, bounds: bounds, items: items, is_public: false } },
            });
    }

    pub fn parse_extend(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let generics = self.parse_generics();
        let target = self.parse_type();
        let interface_type = if self.match(TokenType::As) { self.parse_type(); } else { NODE_NONE; };
        self.expect(TokenType::LeftBrace, "'{'");
        let mark = self.ast.mark();
        while !self.check(TokenType::RightBrace) && !self.at_end() {
            let mut attrs = self.parse_attributes(16);
            let is_public = self.match(TokenType::Pub);
            if self.check(TokenType::Fn) {
                let f = self.parse_function(true);
                self.ast.at(f).as_data.function.is_public = is_public;
                self.add_attrs_to(&mut attrs, f);
                self.ast.push(f);
            } else if self.check(TokenType::Type) && !is_public {
                let ta = self.parse_type_alias(false);
                self.ast.push(ta);
            } else if self.check(TokenType::Const) {
                let cn = self.parse_const();
                self.ast.at(cn).as_data.const_def.is_public = is_public;
                self.ast.push(cn);
            } else {
                self.error_here(if is_public { "'pub' may only be applied to a function or const here"; } else { "expected extension item"; });
                self.advance();
            }
        }
        let items = self.ast.commit(mark);
        self.expect(TokenType::RightBrace, "'}'");
        return self.ast.add(Node {
                kind: NodeKind::NODE_EXTEND,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { extend_def: ExtendData { generics: generics, interface_type: interface_type, target_type: target, items: items } },
            });
    }

    pub fn parse_extern(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let abi = if self.check(TokenType::StringLiteral) { self.literal(); } else { NODE_NONE; };
        if abi == NODE_NONE {
            self.error_here("expected ABI string");
        }
        let header = if self.check(TokenType::StringLiteral) { self.literal(); } else { NODE_NONE; };
        self.expect(TokenType::LeftBrace, "'{'");
        let mark = self.ast.mark();
        while !self.check(TokenType::RightBrace) && !self.at_end() {
            let mut attrs = self.parse_attributes(16);
            let is_public = self.match(TokenType::Pub);
            if self.check(TokenType::Fn) {
                let f = self.parse_function(false);
                if self.ast.at_const(f).as_data.function.body != NODE_NONE {
                    let sp = self.node_span(f);
                    self.errors.emit(sp.start, sp.end - sp.start, format("extern function declarations cannot have a body"));
                }
                self.ast.at(f).as_data.function.is_public = is_public;
                self.ast.at(f).as_data.function.is_extern = true;
                self.add_attrs_to(&mut attrs, f);
                self.expect(TokenType::Semicolon, "';'");
                self.ast.push(f);
            } else if self.check(TokenType::Type) {
                let ta = self.parse_type_alias(true);
                self.ast.at(ta).as_data.type_alias.is_public = is_public;
                self.ast.push(ta);
            } else if self.check(TokenType::Const) {
                let cstart = self.raw_peek().start();
                self.advance();
                let cname = self.identifier();
                self.expect(TokenType::Colon, "':'");
                let ctype = self.parse_type();
                if self.check(TokenType::Equal) {
                    self.error_here("extern const declarations cannot have an initializer");
                }
                self.expect(TokenType::Semicolon, "';'");
                let cnode = self.ast.add(Node {
                        kind: NodeKind::NODE_CONST,
                        span: Span::new(cstart, self.previous_end()),
                        as_data: NodeAs { const_def: ConstData { name: cname, ty: ctype, value: NODE_NONE, is_public: is_public, is_extern: true, is_static_mut: false } },
                    });
                self.add_attrs_to(&mut attrs, cnode);
                self.ast.push(cnode);
            } else {
                self.error_here(if is_public { "'pub' may only be applied to an extern function, type, or const"; } else { "expected extern item"; });
                self.advance();
            }
        }
        let items = self.ast.commit(mark);
        self.expect(TokenType::RightBrace, "'}'");
        return self.ast.add(Node {
                kind: NodeKind::NODE_EXTERN_BLOCK,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { extern_block: ExternBlockData { abi: abi, header: header, items: items } },
            });
    }

    pub fn parse_item(self: &mut Self) NodeId {
        let mut attrs = self.parse_attributes(16);
        if self.peek_ident_is("static_assert") {
            let id = self.parse_static_assert();
            return id;
        }
        let is_public = self.match(TokenType::Pub);
        if self.peek_ident_is("static") {
            let sid = self.parse_static();
            if sid != NODE_NONE {
                self.ast.at(sid).as_data.const_def.is_public = is_public;
            }
            self.add_attrs_to(&mut attrs, sid);
            return sid;
        }
        if is_public && !self.check(TokenType::Fn) && !self.check(TokenType::Struct) && !self.check(TokenType::Union) && !self.check(TokenType::Enum) && !self.check(TokenType::Const) &&
        !self.check(TokenType::Type) && !self.check(TokenType::Interface) {
            self.error_here("'pub' may only be applied to a struct, union, enum, function, const, static, interface, or type");
        }
        let mut id = NODE_NONE;
        switch self.peek_type() {
            Fn => {
                id = self.parse_function(true);
                self.ast.at(id).as_data.function.is_public = is_public;
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
            Extend => { id = self.parse_extend(); },
            Type => {
                id = self.parse_type_alias(false);
                self.ast.at(id).as_data.type_alias.is_public = is_public;
            },
            Const => {
                id = self.parse_const();
                self.ast.at(id).as_data.const_def.is_public = is_public;
            },
            Extern => { id = self.parse_extern(); },
            Import => { id = self.parse_import(); },
            _ => {
                self.error_here("expected top-level item");
                while !self.at_end() && !self.check(TokenType::Semicolon) {
                    self.advance();
                }
                self.match(TokenType::Semicolon);
                return NODE_NONE;
            },
        };
        self.validate_item_attrs(&mut attrs, id);
        self.add_attrs_to(&mut attrs, id);
        return id;
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
            self.ast.push(self.ast.add(Node {
                    kind: NodeKind::NODE_FIELD_INITIALIZER,
                    span: Span::new(field_start, self.node_span(value).end),
                    as_data: NodeAs { field_initializer: FieldInitializerData { name: name, value: value } },
                }));
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        let fields = self.ast.commit(mark);
        self.expect(TokenType::RightBrace, "'}'");
        return self.ast.add(Node {
                kind: NodeKind::NODE_STRUCT_INITIALIZER,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { struct_initializer: StructInitializerData { ty: ty, fields: fields } },
            });
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
            pattern = self.ast.add(Node {
                    kind: NodeKind::NODE_PATTERN_OR,
                    span: Span::new(arm_start, self.previous_end()),
                    as_data: NodeAs { pattern: PatternData { name: NODE_NONE, children: alts } },
                });
        }
        return pattern;
    }

    pub fn parse_switch(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let old = self.allow_struct_initializer;
        self.allow_struct_initializer = false;
        let value = self.parse_expression();
        self.allow_struct_initializer = old;
        self.expect(TokenType::LeftBrace, "'{'");
        let mark = self.ast.mark();
        while !self.check(TokenType::RightBrace) && !self.at_end() {
            let arm_start = self.raw_peek().start();
            self.match(TokenType::Case);
            let pattern = self.parse_pattern_alts(arm_start);
            let guard = if self.match(TokenType::If) { self.parse_expression(); } else { NODE_NONE; };
            self.expect(TokenType::FatArrow, "'=>'");
            let body = if self.check(TokenType::LeftBrace) { self.parse_block(); } else { self.parse_expression(); };
            self.ast.push(self.ast.add(Node {
                    kind: NodeKind::NODE_MATCH_ARM,
                    span: Span::new(arm_start, self.node_span(body).end),
                    as_data: NodeAs { match_arm: MatchArmData { pattern: pattern, guard: guard, body: body } },
                }));
            if !self.match(TokenType::Comma) && !self.check(TokenType::RightBrace) {
                self.error_here("expected ',' or '}' after switch arm");
            }
        }
        let arms = self.ast.commit(mark);
        self.expect(TokenType::RightBrace, "'}'");
        return self.ast.add(Node {
                kind: NodeKind::NODE_MATCH,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { match_expr: MatchData { value: value, arms: arms } },
            });
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
            let neg = self.ast.add(Node {
                    kind: NodeKind::NODE_UNARY,
                    span: Span::new(start, self.node_span(value).end),
                    as_data: NodeAs { unary: UnaryData { op: TokenType::Minus, operand: value, qualifier: TypeQualifier::TYPE_QUAL_NONE } },
                });
            return self.ast.add(Node {
                    kind: NodeKind::NODE_PATTERN_LITERAL,
                    span: Span::new(start, self.node_span(value).end),
                    as_data: NodeAs { single: SingleData { value: neg } },
                });
        }
        if Parser::is_literal_token(self.peek_type()) {
            let value = self.literal();
            return self.ast.add(Node {
                    kind: NodeKind::NODE_PATTERN_LITERAL,
                    span: self.node_span(value),
                    as_data: NodeAs { single: SingleData { value: value } },
                });
        }
        if self.match(TokenType::LeftParen) {
            let inner = self.parse_pattern();
            self.expect(TokenType::RightParen, "')'");
            let mark = self.ast.mark();
            self.ast.push(inner);
            return self.ast.add(Node {
                    kind: NodeKind::NODE_PATTERN_TUPLE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { pattern: PatternData { name: NODE_NONE, children: self.ast.commit(mark) } },
                });
        }
        if self.check(TokenType::Mut) || self.check(TokenType::Identifier) {
            let is_mut = self.match(TokenType::Mut);
            let name = self.identifier();
            if name == NODE_NONE {
                return NODE_NONE;
            }
            if is_mut {
                self.ast.at(name).as_data.name.is_mutable = true;
            }
            let text = self.ast.at_const(name).as_data.name.text;
            if text.end - text.start == 1 && unsafe self.source[text.start as usize] == '_' as u8 {
                return self.ast.add(Node { kind: NodeKind::NODE_PATTERN_WILDCARD, span: self.node_span(name) });
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
                return self.ast.add(Node {
                        kind: NodeKind::NODE_PATTERN_TUPLE,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { pattern: PatternData { name: name, children: children } },
                    });
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
                    self.ast.push(self.ast.add(Node {
                            kind: NodeKind::NODE_PATTERN_FIELD,
                            span: Span::new(field_start, self.node_span(child).end),
                            as_data: NodeAs { pattern: PatternData { name: field_name, children: self.ast.commit(child_mark) } },
                        }));
                    if !self.match(TokenType::Comma) {
                        break;
                    }
                }
                let children = self.ast.commit(mark);
                self.expect(TokenType::RightBrace, "'}'");
                return self.ast.add(Node {
                        kind: NodeKind::NODE_PATTERN_STRUCT,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { pattern: PatternData { name: name, children: children } },
                    });
            }
            if self.match(TokenType::At) {
                let sub = self.parse_pattern();
                let submark = self.ast.mark();
                self.ast.push(sub);
                return self.ast.add(Node {
                        kind: NodeKind::NODE_PATTERN_NAME,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { pattern: PatternData { name: name, children: self.ast.commit(submark) } },
                    });
            }
            return self.ast.add(Node {
                    kind: NodeKind::NODE_PATTERN_NAME,
                    span: self.node_span(name),
                    as_data: NodeAs { pattern: PatternData { name: name, children: NodeList { start: 0, len: 0 } } },
                });
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
            let mut index = if elements.len == 1 { unsafe self.ast.list(elements)[0]; } else { NODE_NONE; };
            if index != NODE_NONE && self.ast.at_const(index).kind == NodeKind::NODE_FIELD_INITIALIZER {
                index = NODE_NONE;
            }
            if index == NODE_NONE {
                self.errors.emit(start, self.previous_end() - start, format("a designated element needs a single index expression"));
            }
            let value = self.parse_expression();
            return self.ast.add(Node {
                    kind: NodeKind::NODE_FIELD_INITIALIZER,
                    span: Span::new(start, self.node_span(value).end),
                    as_data: NodeAs { field_initializer: FieldInitializerData { name: index, value: value } },
                });
        }
        let p = self.parse_postfix_after(group);
        let b = self.parse_binary_after(p, 1);
        return self.parse_expression_after(b);
    }

    pub fn parse_array_literal(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        let mark = self.ast.mark();
        while !self.check(TokenType::RightBracket) && !self.at_end() {
            self.ast.push(self.parse_array_element());
            if !self.match(TokenType::Comma) {
                break;
            }
        }
        let elements = self.ast.commit(mark);
        self.expect(TokenType::RightBracket, "']'");
        return self.ast.add(Node {
                kind: NodeKind::NODE_ARRAY_LITERAL,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { array_literal: ArrayLiteralData { elements: elements } },
            });
    }

    pub fn parse_primary(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        let kind = self.peek_type();
        if Parser::is_literal_token(kind) {
            return self.literal();
        }
        if kind == TokenType::SelfLower {
            let token = self.advance();
            return self.ast.add(Node {
                    kind: NodeKind::NODE_IDENTIFIER,
                    span: token.span(),
                    as_data: NodeAs { name: NameData { text: token.span(), is_mutable: false } },
                });
        }
        if kind == TokenType::Identifier {
            let t = self.raw_peek();
            let may_va = t.len() >= 6 && t.len() <= 8 && unsafe self.source[t.start() as usize] == 'v' as u8;
            let va = if may_va && self.text_is(t, "va_start") {
                VA_START as i32;
            } else if may_va && self.text_is(t, "va_arg") {
                VA_ARG as i32;
            } else if may_va && self.text_is(t, "va_end") {
                VA_END as i32;
            } else {
                -1;
            };
            let value = self.identifier();
            if va >= 0 && self.match(TokenType::LeftParen) {
                let ap = self.parse_expression();
                let mut extra = NODE_NONE;
                if va == VA_ARG as i32 {
                    self.expect(TokenType::Comma, "','");
                    extra = self.parse_type();
                } else if va == VA_START as i32 {
                    self.expect(TokenType::Comma, "','");
                    extra = self.parse_expression();
                }
                self.expect(TokenType::RightParen, "')'");
                return self.ast.add(Node {
                        kind: NodeKind::NODE_VA_EXPR,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { va_op: VaOpData { op: va as u8, ap: ap, extra: extra } },
                    });
            }
            if self.allow_struct_initializer && self.check(TokenType::LeftBrace) {
                return self.parse_struct_initializer_after(value, start);
            }
            return value;
        }
        if self.match(TokenType::LeftParen) {
            let old = self.allow_struct_initializer;
            self.allow_struct_initializer = true;
            let value = self.parse_expression();
            if self.check(TokenType::Comma) {
                let mark = self.ast.mark();
                self.ast.push(value);
                while self.match(TokenType::Comma) && !self.check(TokenType::RightParen) && !self.at_end() {
                    self.ast.push(self.parse_expression());
                }
                let elems = self.ast.commit(mark);
                self.allow_struct_initializer = old;
                self.expect(TokenType::RightParen, "')'");
                return self.ast.add(Node {
                        kind: NodeKind::NODE_TUPLE,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { array_literal: ArrayLiteralData { elements: elems } },
                    });
            }
            self.allow_struct_initializer = old;
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
            return self.ast.add(Node {
                    kind: NodeKind::NODE_WHILE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { while_stmt: WhileData { condition: NODE_NONE, body: body, is_do: false, label: Span::empty() } },
                });
        }
        if self.check(TokenType::Sizeof) || self.check(TokenType::Alignof) {
            let is_align = self.check(TokenType::Alignof);
            self.advance();
            self.expect(TokenType::LeftParen, "'('");
            let ty = self.parse_type();
            self.expect(TokenType::RightParen, "')'");
            return self.ast.add(Node {
                    kind: if is_align { NodeKind::NODE_ALIGNOF; } else { NodeKind::NODE_SIZEOF; },
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { single: SingleData { value: ty } },
                });
        }
        if self.match(TokenType::New) {
            let new_type = self.parse_type();
            let mut initializer = NODE_NONE;
            if self.check(TokenType::LeftBrace) {
                initializer = self.parse_struct_initializer_after(new_type, self.node_span(new_type).start);
            }
            else if self.match(TokenType::LeftParen) {
                initializer = self.parse_expression();
                self.expect(TokenType::RightParen, "')'");
            }
            return self.ast.add(Node {
                    kind: NodeKind::NODE_NEW,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { new_expr: NewData { ty: new_type, initializer: initializer } },
                });
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
            let body = self.parse_block();
            return self.ast.add(Node {
                    kind: NodeKind::NODE_CLOSURE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { closure: ClosureData { params: params, returns: returns, body: body, expr_body: false, captures: NodeList { start: 0, len: 0 }, mut_caps: 0 } },
                });
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
                    self.ast.push(self.ast.add(Node {
                            kind: NodeKind::NODE_PARAMETER,
                            span: Span::new(pstart, self.previous_end()),
                            as_data: NodeAs { parameter: ParameterData { name: name, ty: ty, is_mutable: false } },
                        }));
                    if !self.match(TokenType::Comma) {
                        break;
                    }
                }
                self.expect(TokenType::Pipe, "'|'");
            }
            let params = self.ast.commit(mark);
            if self.check(TokenType::LeftBrace) {
                let block = self.parse_block();
                return self.ast.add(Node {
                        kind: NodeKind::NODE_CLOSURE,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { closure: ClosureData { params: params, returns: NodeList { start: 0, len: 0 }, body: block, expr_body: false, captures: NodeList { start: 0, len: 0 }, mut_caps: 0 } },
                    });
            }
            let body = self.parse_expression();
            return self.ast.add(Node {
                    kind: NodeKind::NODE_CLOSURE,
                    span: Span::new(start, self.previous_end()),
                    as_data: NodeAs { closure: ClosureData { params: params, returns: NodeList { start: 0, len: 0 }, body: body, expr_body: true, captures: NodeList { start: 0, len: 0 }, mut_caps: 0 } },
                });
        }
        self.error_here("expected expression");
        if !self.at_end() {
            self.advance();
        }
        return NODE_NONE;
    }

    pub fn path_chain_to_type_path(self: &mut Self, chain: NodeId, start: u32) NodeId {
        let mut segs: [NodeId; 16] = [0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32];
        let mut n: u32 = 0;
        let mut cur = chain;
        while true {
            let cn = self.ast.at_const(cur);
            if n < 16 {
                segs[n] = cn.as_data.member.member;
                n = n + 1;
            }
            let o = cn.as_data.member.object;
            if self.ast.at_const(o).kind != NodeKind::NODE_MEMBER {
                if n < 16 {
                    segs[n] = o;
                    n = n + 1;
                }
                break;
            }
            cur = o;
        }
        let mark = self.ast.mark();
        while n > 0 {
            n = n - 1;
            self.ast.push(segs[n]);
        }
        let parts = self.ast.commit(mark);
        return self.ast.add(Node {
                kind: NodeKind::NODE_TYPE_PATH,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { type_path: TypePathData { parts: parts, args: NodeList { start: 0, len: 0 } } },
            });
    }

    pub fn parse_postfix_after(self: &mut Self, mut expr: NodeId) NodeId {
        while true {
            let start = self.node_span(expr).start;
            if self.match(TokenType::LeftParen) {
                let args = self.parse_arguments();
                self.expect(TokenType::RightParen, "')'");
                expr = self.ast.add(Node {
                        kind: NodeKind::NODE_CALL,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { call: CallData { callee: expr, args: args } },
                    });
            } else if self.match(TokenType::LeftBracket) {
                let index = self.parse_range(RangeContext::RANGE_EXPR);
                self.expect(TokenType::RightBracket, "']'");
                expr = self.ast.add(Node {
                        kind: NodeKind::NODE_INDEX,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { index: IndexData { object: expr, index: index } },
                    });
            } else if self.check(TokenType::Dot) || self.check(TokenType::Arrow) {
                let pointer = self.match(TokenType::Arrow);
                if !pointer {
                    self.advance();
                }
                let member = if self.check(TokenType::IntegerLiteral) {
                    let tok = self.advance();
                    self.ast.add(Node {
                            kind: NodeKind::NODE_IDENTIFIER,
                            span: tok.span(),
                            as_data: NodeAs { name: NameData { text: tok.span(), is_mutable: false } },
                        });
                } else if self.check(TokenType::FloatLiteral) {
                    self.error_here("nested tuple access needs parentheses: write '(t.0).1'");
                    self.advance();
                    NODE_NONE;
                } else {
                    self.callable_name();
                };
                expr = self.ast.add(Node {
                        kind: NodeKind::NODE_MEMBER,
                        span: Span::new(start, self.node_span(member).end),
                        as_data: NodeAs { member: MemberData { object: expr, member: member, pointer: pointer, path: false } },
                    });
            } else if self.match(TokenType::PathSeparator) {
                if self.check(TokenType::LessThan) {
                    let types = self.parse_type_args();
                    let inner = expr;
                    expr = self.ast.add(Node {
                            kind: NodeKind::NODE_GENERIC_SPECIALIZATION,
                            span: Span::new(start, self.previous_end()),
                            as_data: NodeAs { specialization: SpecializationData { expression: inner, types: types } },
                        });
                    if self.allow_struct_initializer && self.check(TokenType::LeftBrace) {
                        let mut tp: NodeId;
                        if self.ast.at_const(inner).kind == NodeKind::NODE_MEMBER {
                            tp = self.path_chain_to_type_path(inner, start);
                        } else {
                            let mark = self.ast.mark();
                            self.ast.push(inner);
                            tp = self.ast.add(Node {
                                    kind: NodeKind::NODE_TYPE_PATH,
                                    span: Span::new(start, self.previous_end()),
                                    as_data: NodeAs { type_path: TypePathData { parts: self.ast.commit(mark), args: NodeList { start: 0, len: 0 } } },
                                });
                        }
                        self.ast.at(tp).as_data.type_path.args = types;
                        return self.parse_struct_initializer_after(tp, start);
                    }
                } else {
                    let member = self.callable_name();
                    expr = self.ast.add(Node {
                            kind: NodeKind::NODE_MEMBER,
                            span: Span::new(start, self.node_span(member).end),
                            as_data: NodeAs { member: MemberData { object: expr, member: member, pointer: false, path: true } },
                        });
                    if self.allow_struct_initializer && self.check(TokenType::LeftBrace) {
                        let tp = self.path_chain_to_type_path(expr, start);
                        return self.parse_struct_initializer_after(tp, start);
                    }
                }
            } else if self.match(TokenType::As) {
                let cast_type = self.parse_cast_type();
                expr = self.ast.add(Node {
                        kind: NodeKind::NODE_CAST,
                        span: Span::new(start, self.node_span(cast_type).end),
                        as_data: NodeAs { cast: CastData { expression: expr, ty: cast_type } },
                    });
            } else if self.match(TokenType::Question) {
                expr = self.ast.add(Node {
                        kind: NodeKind::NODE_UNARY,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { unary: UnaryData { op: TokenType::Question, operand: expr, qualifier: TypeQualifier::TYPE_QUAL_NONE } },
                    });
            } else {
                break;
            }
        }
        return expr;
    }

    pub fn parse_postfix(self: &mut Self) NodeId {
        return self.parse_postfix_after(self.parse_primary());
    }

    pub fn parse_unary(self: &mut Self) NodeId {
        if self.depth >= PARSE_MAX_DEPTH {
            self.error_here("expression nested too deeply");
            return NODE_NONE;
        }
        self.depth = self.depth + 1;
        let result = if !Parser::unary_operator(self.peek_type()) {
            self.parse_postfix();
        } else {
            let op = self.advance();
            let qualifier = if op.kind() == TokenType::Ampersand && self.match(TokenType::Mut) { TypeQualifier::TYPE_QUAL_MUT; } else { TypeQualifier::TYPE_QUAL_NONE; };
            let operand = if op.kind() == TokenType::Unsafe && self.check(TokenType::LeftBrace) { self.parse_block(); } else { self.parse_unary(); };
            self.ast.add(Node {
                    kind: NodeKind::NODE_UNARY,
                    span: Span::new(op.start(), self.node_span(operand).end),
                    as_data: NodeAs { unary: UnaryData { op: op.kind(), operand: operand, qualifier: qualifier } },
                });
        };
        self.depth = self.depth - 1;
        return result;
    }

    pub fn parse_binary_after(self: &mut Self, mut left: NodeId, minimum: i32) NodeId {
        let mut chain: u32 = 0;
        while true {
            let op = self.peek_type();
            let prec = Parser::precedence(op);
            if prec < minimum {
                break;
            }
            chain = chain + 1;
            if chain > 4096 {
                self.error_here("expression nested too deeply");
                return left;
            }
            self.advance();
            let right = self.parse_binary(prec + 1);
            left = self.ast.add(Node {
                    kind: NodeKind::NODE_BINARY,
                    span: Span::new(self.node_span(left).start, self.node_span(right).end),
                    as_data: NodeAs { binary: BinaryData { op: op, left: left, right: right } },
                });
        }
        return left;
    }

    pub fn parse_binary(self: &mut Self, minimum: i32) NodeId {
        return self.parse_binary_after(self.parse_unary(), minimum);
    }

    pub fn parse_expression_after(self: &mut Self, left: NodeId) NodeId {
        if self.check(TokenType::Range) || self.check(TokenType::RangeInclusive) {
            return self.parse_range_value(left);
        }
        if !Parser::assignment_operator(self.peek_type()) {
            return left;
        }
        if self.depth >= PARSE_MAX_DEPTH {
            self.error_here("expression nested too deeply");
            return left;
        }
        self.depth = self.depth + 1;
        let op = self.advance().kind();
        let right = self.parse_expression();
        self.depth = self.depth - 1;
        return self.ast.add(Node {
                kind: NodeKind::NODE_ASSIGNMENT,
                span: Span::new(self.node_span(left).start, self.node_span(right).end),
                as_data: NodeAs { binary: BinaryData { op: op, left: left, right: right } },
            });
    }

    pub fn parse_expression(self: &mut Self) NodeId {
        if self.check(TokenType::Range) || self.check(TokenType::RangeInclusive) {
            return self.parse_range_value(NODE_NONE);
        }
        return self.parse_expression_after(self.parse_binary(1));
    }

    pub fn parse_range_bound(self: &mut Self, context: RangeContext) NodeId {
        if context == RangeContext::RANGE_PATTERN {
            return self.parse_pattern_atom();
        }
        return self.parse_expression();
    }

    pub fn starts_range_bound(self: &Self, context: RangeContext) bool {
        let t = self.peek_type();
        if context == RangeContext::RANGE_PATTERN {
            return Parser::is_literal_token(t) || t == TokenType::Identifier || t == TokenType::LeftParen || t == TokenType::Minus;
        }
        return Parser::is_literal_token(t) || t == TokenType::Identifier || t == TokenType::LeftParen || t == TokenType::SelfLower || t == TokenType::New || t == TokenType::Switch ||
        t == TokenType::Sizeof || t == TokenType::Alignof || Parser::unary_operator(t);
    }

    pub fn parse_range(self: &mut Self, context: RangeContext) NodeId {
        let open_start = self.check(TokenType::Range) || self.check(TokenType::RangeInclusive);
        let start_node = if open_start { NODE_NONE; } else { self.parse_range_bound(context); };
        if !self.check(TokenType::Range) && !self.check(TokenType::RangeInclusive) {
            return start_node;
        }
        let op_start = self.raw_peek().start();
        let inclusive = self.advance().kind() == TokenType::RangeInclusive;
        let end = if self.starts_range_bound(context) { self.parse_range_bound(context); } else { NODE_NONE; };
        if start_node == NODE_NONE && end == NODE_NONE {
            self.error_here("a range needs a start and/or an end");
        }
        else if inclusive && end == NODE_NONE {
            self.error_here("an inclusive range '..=' needs an end");
        }
        let lo = if start_node != NODE_NONE { self.node_span(start_node).start; } else { op_start; };
        let hi = if end != NODE_NONE { self.node_span(end).end; } else { self.previous_end(); };
        return self.ast.add(Node {
                kind: if context == RangeContext::RANGE_PATTERN { NodeKind::NODE_PATTERN_RANGE; } else { NodeKind::NODE_RANGE; },
                span: Span::new(lo, hi),
                as_data: NodeAs { pattern_range: PatternRangeData { start: start_node, end: end, inclusive: inclusive } },
            });
    }

    pub fn parse_range_value(self: &mut Self, start_node: NodeId) NodeId {
        let op_start = self.raw_peek().start();
        let inclusive = self.advance().kind() == TokenType::RangeInclusive;
        let end = if self.starts_range_bound(RangeContext::RANGE_EXPR) { self.parse_binary(1); } else { NODE_NONE; };
        if start_node == NODE_NONE && end == NODE_NONE {
            self.error_here("a range needs a start and/or an end");
        }
        else if inclusive && end == NODE_NONE {
            self.error_here("an inclusive range '..=' needs an end");
        }
        let lo = if start_node != NODE_NONE { self.node_span(start_node).start; } else { op_start; };
        let hi = if end != NODE_NONE { self.node_span(end).end; } else { self.previous_end(); };
        return self.ast.add(Node {
                kind: NodeKind::NODE_RANGE,
                span: Span::new(lo, hi),
                as_data: NodeAs { pattern_range: PatternRangeData { start: start_node, end: end, inclusive: inclusive } },
            });
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
            self.ast.add(Node {
                    kind: NodeKind::NODE_PATTERN_TUPLE,
                    span: Span::new(tstart, self.previous_end()),
                    as_data: NodeAs { pattern: PatternData { name: NODE_NONE, children: children } },
                });
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
        return self.ast.add(Node {
                kind: NodeKind::NODE_LET,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { let_stmt: LetData { name: name, ty: ty, value: value, is_mutable: is_mutable } },
            });
    }

    pub fn desugar_let_match(self: &mut Self, start: u32, pattern: NodeId, value: NodeId, then_block: NodeId, mut else_branch: NodeId) NodeId {
        let end = self.previous_end();
        if else_branch == NODE_NONE {
            else_branch = self.ast.add(Node { kind: NodeKind::NODE_BLOCK, span: Span::new(end, end), as_data: NodeAs { block: BlockData { statements: NodeList { start: 0, len: 0 } } } });
        }
        let wild = self.ast.add(Node { kind: NodeKind::NODE_PATTERN_WILDCARD, span: Span::new(start, start) });
        let mark = self.ast.mark();
        self.ast.push(self.ast.add(Node {
                kind: NodeKind::NODE_MATCH_ARM,
                span: self.node_span(then_block),
                as_data: NodeAs { match_arm: MatchArmData { pattern: pattern, guard: NODE_NONE, body: then_block } },
            }));
        self.ast.push(self.ast.add(Node {
                kind: NodeKind::NODE_MATCH_ARM,
                span: self.node_span(else_branch),
                as_data: NodeAs { match_arm: MatchArmData { pattern: wild, guard: NODE_NONE, body: else_branch } },
            }));
        let arms = self.ast.commit(mark);
        return self.ast.add(Node {
                kind: NodeKind::NODE_MATCH,
                span: Span::new(start, end),
                as_data: NodeAs { match_expr: MatchData { value: value, arms: arms } },
            });
    }

    pub fn parse_if(self: &mut Self) NodeId {
        let start = self.raw_peek().start();
        self.advance();
        if self.check(TokenType::Let) {
            self.advance();
            let pattern = self.parse_pattern_alts(start);
            self.expect(TokenType::Equal, "'='");
            let old = self.allow_struct_initializer;
            self.allow_struct_initializer = false;
            let value = self.parse_expression();
            self.allow_struct_initializer = old;
            let then_branch = self.parse_block();
            let mut else_branch = NODE_NONE;
            if self.match(TokenType::Else) {
                if self.check(TokenType::If) {
                    else_branch = self.parse_if();
                }
                else {
                    else_branch = self.parse_block();
                }
            }
            return self.desugar_let_match(start, pattern, value, then_branch, else_branch);
        }
        let old = self.allow_struct_initializer;
        self.allow_struct_initializer = false;
        let condition = self.parse_expression();
        self.allow_struct_initializer = old;
        let then_branch = self.parse_block();
        let mut else_branch = NODE_NONE;
        if self.match(TokenType::Else) {
            if self.check(TokenType::If) {
                else_branch = self.parse_if();
            }
            else {
                else_branch = self.parse_block();
            }
        }
        return self.ast.add(Node {
                kind: NodeKind::NODE_IF,
                span: Span::new(start, self.node_span(if else_branch != NODE_NONE { else_branch; } else { then_branch; }).end),
                as_data: NodeAs { if_stmt: IfData { condition: condition, then_branch: then_branch, else_branch: else_branch } },
            });
    }

    pub fn parse_loop_stmt(self: &mut Self, start: u32, label: Span) NodeId {
        let mut result = NODE_NONE;
        switch self.peek_type() {
            While => {
                self.advance();
                if self.check(TokenType::Let) {
                    self.advance();
                    let pattern = self.parse_pattern_alts(start);
                    self.expect(TokenType::Equal, "'='");
                    let old = self.allow_struct_initializer;
                    self.allow_struct_initializer = false;
                    let value = self.parse_expression();
                    self.allow_struct_initializer = old;
                    let body = self.parse_block();
                    let end = self.previous_end();
                    let brk = self.ast.add(Node { kind: NodeKind::NODE_BREAK, span: Span::new(end, end) });
                    let bmark = self.ast.mark();
                    self.ast.push(brk);
                    let brk_block = self.ast.add(Node {
                            kind: NodeKind::NODE_BLOCK,
                            span: Span::new(end, end),
                            as_data: NodeAs { block: BlockData { statements: self.ast.commit(bmark) } },
                        });
                    let m = self.desugar_let_match(start, pattern, value, body, brk_block);
                    let ms = self.ast.add(Node { kind: NodeKind::NODE_EXPRESSION_STATEMENT, span: self.node_span(m), as_data: NodeAs { single: SingleData { value: m } } });
                    let lmark = self.ast.mark();
                    self.ast.push(ms);
                    let lbody = self.ast.add(Node {
                            kind: NodeKind::NODE_BLOCK,
                            span: Span::new(start, end),
                            as_data: NodeAs { block: BlockData { statements: self.ast.commit(lmark) } },
                        });
                    result = self.ast.add(Node {
                            kind: NodeKind::NODE_WHILE,
                            span: Span::new(start, end),
                            as_data: NodeAs { while_stmt: WhileData { condition: NODE_NONE, body: lbody, is_do: false, label: label } },
                        });
                } else {
                    let old = self.allow_struct_initializer;
                    self.allow_struct_initializer = false;
                    let condition = self.parse_expression();
                    self.allow_struct_initializer = old;
                    let body = self.parse_block();
                    result = self.ast.add(Node {
                            kind: NodeKind::NODE_WHILE,
                            span: Span::new(start, self.node_span(body).end),
                            as_data: NodeAs { while_stmt: WhileData { condition: condition, body: body, is_do: false, label: label } },
                        });
                }
            },
            Do => {
                self.advance();
                let body = self.parse_block();
                self.expect(TokenType::While, "'while'");
                let old = self.allow_struct_initializer;
                self.allow_struct_initializer = false;
                let condition = self.parse_expression();
                self.allow_struct_initializer = old;
                self.expect(TokenType::Semicolon, "';'");
                result = self.ast.add(Node {
                        kind: NodeKind::NODE_WHILE,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { while_stmt: WhileData { condition: condition, body: body, is_do: true, label: label } },
                    });
            },
            For => {
                self.advance();
                let binding = self.identifier();
                self.expect(TokenType::In, "'in'");
                let old = self.allow_struct_initializer;
                self.allow_struct_initializer = false;
                let iterable = self.parse_range(RangeContext::RANGE_FOR);
                self.allow_struct_initializer = old;
                let body = self.parse_block();
                result = self.ast.add(Node {
                        kind: NodeKind::NODE_FOR,
                        span: Span::new(start, self.node_span(body).end),
                        as_data: NodeAs { for_stmt: ForData { binding: binding, iterable: iterable, body: body, label: label } },
                    });
            },
            _ => {
                self.advance();
                let body = self.parse_block();
                result = self.ast.add(Node {
                        kind: NodeKind::NODE_WHILE,
                        span: Span::new(start, self.node_span(body).end),
                        as_data: NodeAs { while_stmt: WhileData { condition: NODE_NONE, body: body, is_do: false, label: label } },
                    });
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
        if self.peek_ident_is("static_assert") {
            return self.parse_static_assert();
        }
        let mut result = NODE_NONE;
        switch self.peek_type() {
            LeftBrace => { result = self.parse_block(); },
            Let => { result = self.parse_let(); },
            Const => { result = self.parse_const(); },
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
                }
                let values = self.ast.commit(mark);
                self.expect(TokenType::Semicolon, "';'");
                result = self.ast.add(Node {
                        kind: NodeKind::NODE_RETURN,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { return_stmt: ReturnData { values: values } },
                    });
            },
            Break | Continue => {
                let kind = if self.check(TokenType::Break) { NodeKind::NODE_BREAK; } else { NodeKind::NODE_CONTINUE; };
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
                result = self.ast.add(Node {
                        kind: kind,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { flow: FlowData { value: value, label: label } },
                    });
            },
            Defer => {
                self.advance();
                let value = if self.check(TokenType::LeftBrace) { self.parse_block(); } else { self.parse_expression(); };
                if self.ast.at_const(value).kind != NodeKind::NODE_BLOCK {
                    self.expect(TokenType::Semicolon, "';'");
                }
                result = self.ast.add(Node {
                        kind: NodeKind::NODE_DEFER,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { single: SingleData { value: value } },
                    });
            },
            If => {
                let f = self.parse_if();
                if f != NODE_NONE && self.ast.at_const(f).kind == NodeKind::NODE_MATCH {
                    result = self.ast.add(Node { kind: NodeKind::NODE_EXPRESSION_STATEMENT, span: self.node_span(f), as_data: NodeAs { single: SingleData { value: f } } });
                } else {
                    result = f;
                }
            },
            Label => {
                let label = self.raw_peek().span();
                self.advance();
                self.expect(TokenType::Colon, "':'");
                if !self.check(TokenType::While) && !self.check(TokenType::Do) && !self.check(TokenType::For) && !self.check(TokenType::Loop) {
                    self.error_here("a label must be followed by 'loop', 'while', 'do', or 'for'");
                    result = NODE_NONE;
                } else {
                    result = self.parse_loop_stmt(start, label);
                }
            },
            While | Do | For | Loop => { result = self.parse_loop_stmt(start, Span::empty()); },
            Unsafe => {
                let expression = self.parse_expression();
                let node = self.ast.at_const(expression);
                let block = node.kind == NodeKind::NODE_UNARY && node.as_data.unary.op == TokenType::Unsafe && self.ast.at_const(node.as_data.unary.operand).kind == NodeKind::NODE_BLOCK;
                if !block {
                    self.expect(TokenType::Semicolon, "';'");
                }
                result = self.ast.add(Node {
                        kind: NodeKind::NODE_EXPRESSION_STATEMENT,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { single: SingleData { value: expression } },
                    });
            },
            _ => {
                let expression = self.parse_expression();
                self.expect(TokenType::Semicolon, "';'");
                result = self.ast.add(Node {
                        kind: NodeKind::NODE_EXPRESSION_STATEMENT,
                        span: Span::new(start, self.previous_end()),
                        as_data: NodeAs { single: SingleData { value: expression } },
                    });
            },
        };
        return result;
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
        return self.ast.add(Node {
                kind: NodeKind::NODE_BLOCK,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { block: BlockData { statements: statements } },
            });
    }

    pub fn attr_kind_of(self: &Self, name: Token, wants_str: &mut bool, wants_int: &mut bool) i32 {
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

    pub fn parse_attribute(self: &mut Self, out: &mut Attr) bool {
        self.advance();
        if !self.check(TokenType::Identifier) {
            self.error_here("expected an attribute path after '@'");
            return false;
        }
        let ns = self.advance();
        if self.text_is(ns, "emit_macro") && !self.check(TokenType::Dot) {
            *out = Attr { owner: NODE_NONE, kind: AttrKind::ATTR_EMIT_MACRO as u8, arg: 0, str_span: Span::empty() };
            if self.match(TokenType::LeftParen) {
                self.errors.emit(ns.start(), ns.len(), format("attribute '@emit_macro' takes no arguments"));
                while !self.check(TokenType::RightParen) && !self.at_end() {
                    self.advance();
                }
                self.match(TokenType::RightParen);
            }
            return true;
        }
        let tk = if self.text_is(ns, "test") {
            AttrKind::ATTR_TEST as i32;
        } else if self.text_is(ns, "test_init") {
            AttrKind::ATTR_TEST_INIT as i32;
        } else if self.text_is(ns, "test_free") {
            AttrKind::ATTR_TEST_FREE as i32;
        } else {
            -1;
        };
        if tk >= 0 && !self.check(TokenType::Dot) {
            *out = Attr { owner: NODE_NONE, kind: tk as u8, arg: 0, str_span: Span::empty() };
            if self.match(TokenType::LeftParen) {
                let a = self.raw_peek();
                let ok = self.check(TokenType::Identifier) && if tk == AttrKind::ATTR_TEST as i32 {
                    self.text_is(a, "should_panic");
                } else {
                    self.text_is(a, "global");
                };
                if ok {
                    out.arg = 1;
                    self.advance();
                } else {
                    self.errors.emit(a.start(), if a.len() != 0 { a.len(); } else { 1u32; }, String::from_str(if tk == AttrKind::ATTR_TEST as i32 {
                            "attribute '@test' accepts only '(should_panic)'";
                        } else {
                            "'@test_init' / '@test_free' accept only '(global)'";
                        }));
                    while !self.check(TokenType::RightParen) && !self.at_end() {
                        self.advance();
                    }
                }
                self.expect(TokenType::RightParen, "')'");
            }
            return true;
        }
        if self.text_is(ns, "platform") && !self.check(TokenType::Dot) {
            *out = Attr { owner: NODE_NONE, kind: AttrKind::ATTR_PLATFORM as u8, arg: 0, str_span: Span::empty() };
            if !self.match(TokenType::LeftParen) {
                self.errors.emit(ns.start(), ns.len(), format("attribute '@platform' requires a platform list, e.g. '@platform(windows)' or '@platform(linux | macos)'"));
                return true;
            }
            let mut mask: u32 = 0;
            let mut ok = true;
            loop {
                let neg = self.match(TokenType::Bang);
                if !self.check(TokenType::Identifier) {
                    self.error_here("expected a platform name: windows, macos, or linux");
                    ok = false;
                    break;
                }
                let p = self.advance();
                let bit = if self.text_is(p, "windows") { 1u32; } else if self.text_is(p, "macos") { 2u32; } else if self.text_is(p, "linux") { 4u32; } else { 0u32; };
                if bit == 0 {
                    self.errors.emit(p.start(), p.len(), format("unknown platform '{}'; expected windows, macos, or linux", diag::span_str(self.source, p.start(), p.end())));
                    ok = false;
                    break;
                }
                let term = if neg { bit ^ 7u32; } else { bit; };
                mask = mask | term;
                if !self.match(TokenType::Pipe) {
                    break;
                }
            }
            if !ok {
                while !self.check(TokenType::RightParen) && !self.at_end() {
                    self.advance();
                }
            }
            self.expect(TokenType::RightParen, "')'");
            out.arg = mask;
            return true;
        }
        if !self.text_is(ns, "c") {
            // Unknown attribute: the parser always accepts @path(args) generically; recognition is a
            // semantic concern. Skip any .subpath and a balanced arg list. Unknown is an error unless
            // --bootstrap-tags (which lets an older compiler build source that uses a tag it ignores).
            while self.match(TokenType::Dot) {
                if self.check(TokenType::Identifier) {
                    self.advance();
                } else {
                    break;
                }
            }
            self.skip_attr_args();
            if !self.bootstrap_tags {
                self.errors.emit(ns.start(), ns.len(), format("unknown attribute '@{}'; pass --bootstrap-tags to accept unknown attributes", diag::span_str(self.source, ns.start(), ns.end())));
            }
            return false;
        }
        self.expect(TokenType::Dot, "'.'");
        if self.at_end() || self.check(TokenType::LeftParen) || self.check(TokenType::RightParen) || self.check(TokenType::Semicolon) || self.check(TokenType::Dot) {
            self.error_here("expected an attribute name after '@c.'");
            return false;
        }
        let name = self.advance();
        if self.check(TokenType::Dot) {
            self.error_here("target-specific attribute namespaces (e.g. '@c.gnu.*') are not supported");
        }
        let mut wants_str = false;
        let mut wants_int = false;
        let kind = self.attr_kind_of(name, &mut wants_str, &mut wants_int);
        if kind < 0 {
            self.skip_attr_args(); // accept the tag generically; recognition is semantic
            if !self.bootstrap_tags {
                self.errors.emit(name.start(), name.len(), format("unknown attribute '@c.{}'; pass --bootstrap-tags to accept unknown attributes", diag::span_str(self.source, name.start(), name.end())));
                self.errors.note(format("supported '@c' attributes include export, import, noreturn, always_inline, cold, used, unused, section, packed, and align"));
            }
            return false;
        }
        * out = Attr { owner: NODE_NONE, kind: kind as u8, arg: 0, str_span: Span::empty() };
        let has_args = self.match(TokenType::LeftParen);
        if wants_str || wants_int {
            if !has_args {
                self.errors.emit(name.start(), name.len(), format("attribute '@c.{}' requires an argument", diag::span_str(self.source, name.start(), name.end())));
                return true;
            }
            if wants_int {
                if !self.check(TokenType::IntegerLiteral) {
                    self.error_here("expected an integer argument");
                } else {
                    let lit = self.raw_peek();
                    let mut buf: [char; 24] = [
                        0 as char, 0 as char, 0 as char, 0 as char, 0 as char, 0 as char,
                        0 as char, 0 as char, 0 as char, 0 as char, 0 as char, 0 as char,
                        0 as char, 0 as char, 0 as char, 0 as char, 0 as char, 0 as char,
                        0 as char, 0 as char, 0 as char, 0 as char, 0 as char, 0 as char,
                    ];
                    let mut k: usize = 0;
                    let mut i = lit.start();
                    while i < lit.end() && k + 1 < sizeof([char; 24]) {
                        let ch = unsafe self.source[i as usize];
                        if ch != '_' as u8 {
                            buf[k] = ch as char;
                            k = k + 1;
                        }
                        i = i + 1;
                    }
                    buf[k] = 0 as char;
                    out.arg = unsafe stdlib::strtoul((&buf[0]) as *const char, null, 0) as u32;
                }
                self.advance();
            } else {
                if !self.check(TokenType::StringLiteral) {
                    self.error_here("expected a string argument");
                } else {
                    let lit = self.raw_peek();
                    out.str_span = Span::new(lit.start() + 1, lit.end() - 1);
                }
                self.advance();
            }
            self.expect(TokenType::RightParen, "')'");
        } else if has_args {
            self.errors.emit(name.start(), name.len(), format("attribute '@c.{}' takes no arguments", diag::span_str(self.source, name.start(), name.end())));
            while !self.check(TokenType::RightParen) && !self.at_end() {
                self.advance();
            }
            self.match(TokenType::RightParen);
        }
        return true;
    }

    pub fn parse_attributes(self: &mut Self, cap: usize) Vector<Attr> {
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

    pub fn add_attrs_to(self: &mut Self, attrs: &mut Vector<Attr>, owner: NodeId) void {
        for i in 0..attrs.len() {
            let mut attr = attrs[i];
            attr.owner = owner;
            self.ast.add_attr(attr);
        }
    }

    pub fn validate_item_attrs(self: &mut Self, attrs: &mut Vector<Attr>, owner: NodeId) void {
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
            if (attr.kind == AttrKind::ATTR_TEST as u8 || attr.kind == AttrKind::ATTR_TEST_INIT as u8 || attr.kind == AttrKind::ATTR_TEST_FREE as u8) && !valid_test {
                self.errors.emit(sp.start, sp.end - sp.start, format("'@test' / '@test_init' / '@test_free' may only be applied to a non-generic function"));
            }
            if (attr.kind == AttrKind::ATTR_C_SOURCE as u8 || attr.kind == AttrKind::ATTR_C_LINK as u8) && (owner == NODE_NONE || self.ast.at_const(owner).kind != NodeKind::NODE_EXTERN_BLOCK) {
                self.errors.emit(sp.start, sp.end - sp.start, format("'@c.source' / '@c.link' may only be applied to an 'extern \"C\"' block"));
            }
            if attr.kind == AttrKind::ATTR_EMIT_MACRO as u8 && !generic_aggregate {
                self.errors.emit(sp.start, sp.end - sp.start, format("'@emit_macro' may only be applied to a generic struct or enum"));
                self.errors.note(format("write it before a declaration like 'struct Box<T> {{ ... }}' or 'enum Option<T> {{ ... }}'"));
            }
            if attr.kind == AttrKind::ATTR_PLATFORM as u8 && owner != NODE_NONE && self.ast.at_const(owner).kind == NodeKind::NODE_IMPORT {
                self.errors.emit(sp.start, sp.end - sp.start, format("'@platform' cannot gate an 'import'; gate the declarations instead"));
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
            }
            else {
                alias = self.identifier();
            }
        }
        self.expect(TokenType::Semicolon, "';'");
        return self.ast.add(Node {
                kind: NodeKind::NODE_IMPORT,
                span: Span::new(start, self.previous_end()),
                as_data: NodeAs { import_decl: ImportData { path: path, alias: alias, glob: glob } },
            });
    }

    pub fn is_literal_token(kind: TokenType) bool {
        return kind == TokenType::IntegerLiteral || kind == TokenType::FloatLiteral || kind == TokenType::CharacterLiteral || kind == TokenType::ByteCharacterLiteral ||
        kind == TokenType::StringLiteral || kind == TokenType::RawStringLiteral || kind == TokenType::ByteStringLiteral || kind == TokenType::True ||
        kind == TokenType::False || kind == TokenType::Null;
    }

    pub fn unary_operator(kind: TokenType) bool {
        return kind == TokenType::Bang || kind == TokenType::Tilde || kind == TokenType::Minus || kind == TokenType::Star || kind == TokenType::Ampersand || kind == TokenType::Move ||
        kind == TokenType::Unsafe;
    }

    pub fn precedence(kind: TokenType) i32 {
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

    pub fn assignment_operator(kind: TokenType) bool {
        return kind == TokenType::Equal || kind == TokenType::PlusEqual || kind == TokenType::MinusEqual || kind == TokenType::StarEqual || kind == TokenType::SlashEqual ||
        kind == TokenType::PercentEqual || kind == TokenType::AmpersandEqual || kind == TokenType::PipeEqual || kind == TokenType::CaretEqual ||
        kind == TokenType::LeftShiftEqual || kind == TokenType::RightShiftEqual;
    }

    pub fn build_ast(self: &mut Self) void {
        let mark = self.ast.mark();
        while !self.at_end() {
            let before = self.current;
            let item = self.parse_item();
            if item != NODE_NONE {
                self.ast.push(item);
            }
            if self.current == before && !self.at_end() {
                self.advance();
            }
        }
        let items = self.ast.commit(mark);
        self.ast.root = self.ast.add(Node {
                kind: NodeKind::NODE_PROGRAM,
                span: Span::new(0, self.len as u32),
                as_data: NodeAs { program: ProgramData { items: items } },
            });
        self.errors.finalize(self.source, self.len, self.file);
    }

    pub fn has_errors(self: &Self) bool {
        return self.errors.has_errors();
    }
    pub fn log_errors(self: &Self) void {
        self.errors.log();
    }
}

extend Parser as Free {
    pub fn free(self: &mut Self) void {
        self.tokens.free();
        self.ast.free();
        self.errors.free();
    }
}
