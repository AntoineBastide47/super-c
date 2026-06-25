#include "parser.h"

#include <stdlib.h>

struct Parser {
    const uint8_t *source;
    size_t len;
    Token_Vec tokens;
    size_t current;
    unsigned pending_gt;
    bool allow_struct_initializer;
    Ast *ast;
    ERRORS_VARIABLES;
};

static NodeId parse_item(Parser *p);
static NodeId parse_statement(Parser *p);
static NodeId parse_block(Parser *p);
static NodeId parse_if(Parser *p);
static NodeId parse_expression(Parser *p);
static NodeId parse_type(Parser *p);
static NodeId parse_pattern(Parser *p);
static NodeList parse_function_returns(Parser *p);

// One range grammar shared by `for` iterables and `switch` patterns (so they can never drift).
typedef enum { RANGE_FOR, RANGE_PATTERN } RangeContext;
static NodeId parse_range(Parser *p, const RangeContext context);

Parser *parser_new(Token_Vec tokens, const char *source, const size_t len) {
  Parser *const p = calloc(1, sizeof *p);
  if (!p) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }
  p->source = (const uint8_t *)source;
  p->len = len;
  p->tokens = tokens;
  p->ast = ast_new(tokens.len);
  p->allow_struct_initializer = true;
  ERRORS_INIT(p);
  return p;
}

void parser_free(Parser **p) {
  if (!p || !*p)
    return;
  VEC_DEINIT((*p)->tokens);
  ast_free(&(*p)->ast);
  ERRORS_DEINIT(p);
  free(*p);
  *p = NULL;
}

Ast *parser_take_ast(Parser *p) {
  Ast *const ast = p->ast;
  p->ast = NULL;
  return ast;
}

ALWAYS_INLINE Token raw_peek(const Parser *p) {
  return p->tokens.data[p->current];
}

ALWAYS_INLINE TokenType peek_type(const Parser *p) {
  return p->pending_gt ? GreaterThan : token_type(raw_peek(p));
}

ALWAYS_INLINE bool at_end(const Parser *p) {
  return peek_type(p) == Eof;
}

ALWAYS_INLINE Token advance(Parser *p) {
  if (p->pending_gt) {
    p->pending_gt--;
    const Token source = p->tokens.data[p->current - 1];
    return token_new(GreaterThan, token_end(source) - 1, 1);
  }
  const Token t = raw_peek(p);
  if (token_type(t) != Eof)
    p->current++;
  return t;
}

ALWAYS_INLINE bool check(const Parser *p, const TokenType type) {
  return peek_type(p) == type;
}

ALWAYS_INLINE bool check_next(const Parser *p, const TokenType type) {
  return !p->pending_gt && token_type(p->tokens.data[p->current + 1]) == type;
}

ALWAYS_INLINE bool match(Parser *p, const TokenType type) {
  if (!check(p, type))
    return false;
  advance(p);
  return true;
}

ALWAYS_INLINE uint32_t previous_end(const Parser *p) {
  if (p->pending_gt)
    return token_end(p->tokens.data[p->current - 1]) - p->pending_gt;
  return p->current ? token_end(p->tokens.data[p->current - 1]) : 0;
}

ALWAYS_INLINE Span node_span(const Parser *p, const NodeId id) {
  return id == NODE_NONE ? span_empty() : ast_at_const(p->ast, id)->span;
}

ALWAYS_INLINE bool is_type_start(const TokenType type) {
  return type == Identifier || type == SelfUpper || type == Star || type == Ampersand || type == LeftBracket ||
         type == Fn;
}

COLD void error_here(Parser *p, const char *message) {
  const Token t = raw_peek(p);
  parser_errorf(p, token_start(t), token_len(t), "%s", message);
}

ALWAYS_INLINE bool expect(Parser *p, const TokenType type, const char *display) {
  if (match(p, type))
    return true;
  const Token t = raw_peek(p);
  parser_errorf(p, token_start(t), token_len(t), "expected %s", display);
  return false;
}

ALWAYS_INLINE bool consume_type_gt(Parser *p) {
  if (match(p, GreaterThan))
    return true;
  if (!p->pending_gt && check(p, RightShift)) {
    advance(p);
    p->pending_gt = 1;
    return true;
  }
  return expect(p, GreaterThan, "'>'");
}

static NodeId identifier(Parser *p) {
  if (!check(p, Identifier) && !check(p, SelfUpper)) {
    error_here(p, "expected identifier");
    if (!at_end(p))
      advance(p);
    return NODE_NONE;
  }
  const Token token = advance(p);
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_IDENTIFIER,
                  .span = token_span(token),
                  .as.name = {.text = token_span(token)},
              });
}

static NodeId callable_name(Parser *p) {
  if (!check(p, Identifier) && !check(p, SelfUpper) && !check(p, New)) {
    error_here(p, "expected identifier");
    if (!at_end(p))
      advance(p);
    return NODE_NONE;
  }
  const Token token = advance(p);
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_IDENTIFIER,
                  .span = token_span(token),
                  .as.name = {.text = token_span(token)},
              });
}

static NodeId literal(Parser *p) {
  const Token token = advance(p);
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_LITERAL,
                  .span = token_span(token),
                  .as.literal = {.raw = token_span(token), .token_type = token_type(token)},
              });
}

static NodeList parse_comma_types(Parser *p, const TokenType close) {
  const uint32_t mark = ast_mark(p->ast);
  while (!check(p, close) && !at_end(p)) {
    ast_push(p->ast, parse_type(p));
    if (!match(p, Comma))
      break;
  }
  return ast_commit(p->ast, mark);
}

static NodeList parse_type_args(Parser *p) {
  expect(p, LessThan, "'<'");
  const uint32_t mark = ast_mark(p->ast);
  while (!check(p, GreaterThan) && !check(p, RightShift) && !at_end(p)) {
    ast_push(p->ast, parse_type(p));
    if (!match(p, Comma))
      break;
  }
  const NodeList args = ast_commit(p->ast, mark);
  consume_type_gt(p);
  return args;
}

static NodeId parse_type_path(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  const uint32_t mark = ast_mark(p->ast);
  ast_push(p->ast, identifier(p));
  while (match(p, PathSeparator))
    ast_push(p->ast, identifier(p));
  const NodeList parts = ast_commit(p->ast, mark);
  const NodeList args = check(p, LessThan) ? parse_type_args(p) : (NodeList){0};
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_TYPE_PATH,
                  .span = span_new(start, previous_end(p)),
                  .as.type_path = {.parts = parts, .args = args},
              });
}

ALWAYS_INLINE TypeQualifier parse_qualifier(Parser *p) {
  if (match(p, Const))
    return TYPE_QUAL_CONST;
  if (match(p, Mut))
    return TYPE_QUAL_MUT;
  return TYPE_QUAL_NONE;
}

static NodeId parse_type(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  if (match(p, Star) || match(p, Ampersand)) {
    const TokenType opener = token_type(p->tokens.data[p->current - 1]);
    TypeQualifier qualifier;
    if (opener == Star) {
      qualifier = parse_qualifier(p);
    } else if (match(p, Mut)) {
      qualifier = TYPE_QUAL_MUT;
    } else {
      qualifier = TYPE_QUAL_NONE;
      if (check(p, Const)) {
        error_here(p, "references use '&T' or '&mut T', not '&const T'");
        advance(p);
      }
    }
    const NodeId type = parse_type(p);
    return ast_add(
        p->ast, (Node){
                    .kind = opener == Star ? NODE_POINTER_TYPE : NODE_REFERENCE_TYPE,
                    .span = span_new(start, node_span(p, type).end),
                    .as.indirect_type = {.type = type, .qualifier = qualifier},
                });
  }
  if (match(p, LeftBracket)) {
    if (match(p, RightBracket)) {
      const NodeId element = parse_type(p);
      return ast_add(
          p->ast, (Node){
                      .kind = NODE_SLICE_TYPE,
                      .span = span_new(start, node_span(p, element).end),
                      .as.indirect_type = {.type = element},
                  });
    }
    const NodeId element = parse_type(p);
    expect(p, Semicolon, "';'");
    const NodeId length = parse_expression(p);
    expect(p, RightBracket, "']'");
    return ast_add(
        p->ast, (Node){
                    .kind = NODE_ARRAY_TYPE,
                    .span = span_new(start, previous_end(p)),
                    .as.array_type = {.element = element, .length = length},
                });
  }
  if (match(p, Fn)) {
    expect(p, LeftParen, "'('");
    const NodeList params = parse_comma_types(p, RightParen);
    expect(p, RightParen, "')'");
    const NodeList returns = parse_function_returns(p);
    return ast_add(
        p->ast, (Node){
                    .kind = NODE_FUNCTION_TYPE,
                    .span = span_new(start, previous_end(p)),
                    .as.function_type = {.params = params, .returns = returns},
                });
  }
  if (check(p, Identifier) || check(p, SelfUpper))
    return parse_type_path(p);
  error_here(p, "expected type");
  if (!at_end(p))
    advance(p);
  return NODE_NONE;
}

static NodeList parse_bounds(Parser *p) {
  const uint32_t mark = ast_mark(p->ast);
  ast_push(p->ast, parse_type_path(p));
  while (match(p, Plus))
    ast_push(p->ast, parse_type_path(p));
  return ast_commit(p->ast, mark);
}

static NodeList parse_generics(Parser *p) {
  if (!match(p, LessThan))
    return (NodeList){0};
  const uint32_t mark = ast_mark(p->ast);
  while (!check(p, GreaterThan) && !check(p, RightShift) && !at_end(p)) {
    const uint32_t start = token_start(raw_peek(p));
    const NodeId name = identifier(p);
    const NodeList bounds = match(p, Colon) ? parse_bounds(p) : (NodeList){0};
    ast_push(
        p->ast, ast_add(
                    p->ast, (Node){
                                .kind = NODE_GENERIC_PARAM,
                                .span = span_new(start, previous_end(p)),
                                .as.generic_param = {.name = name, .bounds = bounds},
                            }));
    if (!match(p, Comma))
      break;
  }
  consume_type_gt(p);
  return ast_commit(p->ast, mark);
}

static NodeList parse_where_clause(Parser *p) {
  if (!match(p, Where))
    return (NodeList){0};
  const uint32_t mark = ast_mark(p->ast);
  do {
    const uint32_t start = token_start(raw_peek(p));
    const NodeId type = parse_type(p);
    expect(p, Colon, "':'");
    const NodeList bounds = parse_bounds(p);
    ast_push(
        p->ast, ast_add(
                    p->ast, (Node){
                                .kind = NODE_WHERE_PREDICATE,
                                .span = span_new(start, previous_end(p)),
                                .as.where_predicate = {.type = type, .bounds = bounds},
                            }));
  } while (match(p, Comma) && !check(p, LeftBrace) && !check(p, Semicolon));
  return ast_commit(p->ast, mark);
}

static NodeId parse_parameter_name(Parser *p) {
  if (match(p, SelfLower)) {
    const Token token = p->tokens.data[p->current - 1];
    return ast_add(
        p->ast, (Node){.kind = NODE_IDENTIFIER, .span = token_span(token), .as.name = {.text = token_span(token)}});
  }
  return identifier(p);
}

static NodeList parse_parameters(Parser *p) {
  expect(p, LeftParen, "'('");
  const uint32_t params_mark = ast_mark(p->ast);
  while (!check(p, RightParen) && !at_end(p)) {
    const uint32_t names_mark = ast_mark(p->ast);
    ast_push(p->ast, parse_parameter_name(p));
    while (!check(p, Colon) && !at_end(p)) {
      expect(p, Comma, "','");
      if (check(p, RightParen))
        break;
      ast_push(p->ast, parse_parameter_name(p));
    }
    const NodeList names = ast_commit(p->ast, names_mark);
    expect(p, Colon, "':'");
    const NodeId type = parse_type(p);
    const NodeId *const name_ids = ast_list(p->ast, names);
    for (uint32_t i = 0; i < names.len; i++) {
      const NodeId name = name_ids[i];
      ast_push(
          p->ast, ast_add(
                      p->ast, (Node){
                                  .kind = NODE_PARAMETER,
                                  .span = span_new(node_span(p, name).start, node_span(p, type).end),
                                  .as.parameter = {.name = name, .type = type},
                              }));
    }
    if (!match(p, Comma))
      break;
  }
  expect(p, RightParen, "')'");
  return ast_commit(p->ast, params_mark);
}

static NodeList parse_function_returns(Parser *p) {
  if (!check(p, LeftParen) && !is_type_start(peek_type(p)))
    return (NodeList){0};

  const uint32_t mark = ast_mark(p->ast);
  if (!match(p, LeftParen)) {
    ast_push(p->ast, parse_type(p));
    return ast_commit(p->ast, mark);
  }

  while (!check(p, RightParen) && !at_end(p)) {
    if (check(p, Identifier) && check_next(p, Colon)) {
      const NodeId name = identifier(p);
      expect(p, Colon, "':'");
      const NodeId type = parse_type(p);
      ast_push(
          p->ast, ast_add(
                      p->ast, (Node){
                                  .kind = NODE_PARAMETER,
                                  .span = span_new(node_span(p, name).start, node_span(p, type).end),
                                  .as.parameter = {.name = name, .type = type},
                              }));
    } else {
      ast_push(p->ast, parse_type(p));
    }
    if (!match(p, Comma))
      break;
  }
  const NodeList returns = ast_commit(p->ast, mark);
  expect(p, RightParen, "')'");
  if (returns.len == 1 && ast_at_const(p->ast, ast_list(p->ast, returns)[0])->kind != NODE_PARAMETER)
    error_here(p, "a single unnamed return type must not be parenthesized");
  return returns;
}

static NodeId parse_function(Parser *p, const bool require_body) {
  const uint32_t start = token_start(raw_peek(p));
  expect(p, Fn, "'fn'");
  const NodeId name = callable_name(p);
  const NodeList generics = parse_generics(p);
  const NodeList params = parse_parameters(p);
  const NodeList returns = parse_function_returns(p);
  const NodeList where_clause = parse_where_clause(p);
  NodeId body = NODE_NONE;
  if (check(p, LeftBrace))
    body = parse_block(p);
  else if (require_body)
    error_here(p, "expected function body");
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_FUNCTION,
                  .span = span_new(start, body ? node_span(p, body).end : previous_end(p)),
                  .as.function =
                      {
                          .name = name,
                          .generics = generics,
                          .params = params,
                          .returns = returns,
                          .where_clause = where_clause,
                          .body = body,
                      },
              });
}

static NodeId parse_field(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  const bool is_public = match(p, Pub); // `pub name: T` makes the field readable outside the struct
  const NodeId name = identifier(p);
  expect(p, Colon, "':'");
  const NodeId type = parse_type(p);
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_FIELD,
                  .span = span_new(start, node_span(p, type).end),
                  .as.field = {.name = name, .type = type, .is_public = is_public},
              });
}

static NodeList parse_fields(Parser *p) {
  const uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    ast_push(p->ast, parse_field(p));
    if (!match(p, Comma))
      break;
  }
  return ast_commit(p->ast, mark);
}

static NodeId parse_struct(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  advance(p);
  const NodeId name = identifier(p);
  const NodeList generics = parse_generics(p);
  expect(p, LeftBrace, "'{'");
  const NodeList fields = parse_fields(p);
  expect(p, RightBrace, "'}'");
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_STRUCT,
                  .span = span_new(start, previous_end(p)),
                  .as.aggregate = {.name = name, .generics = generics, .members = fields},
              });
}

static NodeId parse_variant(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  const NodeId name = identifier(p);
  NodeList payload = {0};
  bool struct_payload = false;
  NodeId value = NODE_NONE;
  if (match(p, LeftParen)) {
    payload = parse_comma_types(p, RightParen);
    expect(p, RightParen, "')'");
  } else if (match(p, LeftBrace)) {
    struct_payload = true;
    payload = parse_fields(p);
    expect(p, RightBrace, "'}'");
  } else if (match(p, Equal)) { // explicit discriminant `Variant = <int>` (one-token lookahead)
    value = parse_expression(p);
  }
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_VARIANT,
                  .span = span_new(start, previous_end(p)),
                  .as.variant = {.name = name, .payload = payload, .struct_payload = struct_payload, .value = value},
              });
}

static NodeId parse_enum(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  advance(p);
  const NodeId name = identifier(p);
  const NodeList generics = parse_generics(p);
  expect(p, LeftBrace, "'{'");
  const uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    ast_push(p->ast, parse_variant(p));
    if (!match(p, Comma))
      break;
  }
  const NodeList variants = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_ENUM,
                  .span = span_new(start, previous_end(p)),
                  .as.aggregate = {.name = name, .generics = generics, .members = variants},
              });
}

static NodeId parse_type_alias(Parser *p, const bool opaque) {
  const uint32_t start = token_start(raw_peek(p));
  expect(p, Type, "'type'");
  const NodeId name = identifier(p);
  const NodeList generics = opaque ? (NodeList){0} : parse_generics(p);
  NodeId type = NODE_NONE;
  if (!opaque || match(p, Equal)) {
    if (!opaque)
      expect(p, Equal, "'='");
    type = parse_type(p);
  }
  expect(p, Semicolon, "';'");
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_TYPE_ALIAS,
                  .span = span_new(start, previous_end(p)),
                  .as.type_alias = {.name = name, .generics = generics, .type = type},
              });
}

static NodeId parse_const(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  advance(p);
  const NodeId name = identifier(p);
  expect(p, Colon, "':'");
  const NodeId type = parse_type(p);
  expect(p, Equal, "'='");
  const NodeId value = parse_expression(p);
  expect(p, Semicolon, "';'");
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_CONST,
                  .span = span_new(start, previous_end(p)),
                  .as.const_def = {.name = name, .type = type, .value = value},
              });
}

static NodeId parse_interface(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  advance(p);
  const NodeId name = identifier(p);
  const NodeList generics = parse_generics(p);
  const NodeList bounds = match(p, Colon) ? parse_bounds(p) : (NodeList){0};
  expect(p, LeftBrace, "'{'");
  const uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    if (check(p, Fn)) {
      const NodeId fn = parse_function(p, false);
      if (ast_at_const(p->ast, fn)->as.function.body == NODE_NONE)
        expect(p, Semicolon, "';'");
      ast_push(p->ast, fn);
    } else if (check(p, Type)) {
      ast_push(p->ast, parse_type_alias(p, true));
    } else {
      error_here(p, "expected interface item");
      advance(p);
    }
  }
  const NodeList items = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_TRAIT,
                  .span = span_new(start, previous_end(p)),
                  .as.trait_def = {.name = name, .generics = generics, .bounds = bounds, .items = items},
              });
}

static NodeId parse_extend(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  advance(p);
  const NodeList generics = parse_generics(p);
  const NodeId target = parse_type(p);
  const NodeId trait_type = match(p, As) ? parse_type(p) : NODE_NONE;
  expect(p, LeftBrace, "'{'");
  const uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    const bool is_public = match(p, Pub); // `pub fn` on a method
    if (check(p, Fn)) {
      const NodeId fn = parse_function(p, true);
      ast_at(p->ast, fn)->as.function.is_public = is_public;
      ast_push(p->ast, fn);
    } else if (check(p, Type) && !is_public) {
      ast_push(p->ast, parse_type_alias(p, false));
    } else {
      error_here(p, is_public ? "'pub' may only be applied to a function here" : "expected extension item");
      advance(p);
    }
  }
  const NodeList items = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(
      p->ast,
      (Node){
          .kind = NODE_IMPL,
          .span = span_new(start, previous_end(p)),
          .as.impl_def = {.generics = generics, .trait_type = trait_type, .target_type = target, .items = items},
      });
}

static NodeId parse_extern(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  advance(p);
  const NodeId abi = check(p, StringLiteral) ? literal(p) : NODE_NONE;
  if (!abi)
    error_here(p, "expected ABI string");
  expect(p, LeftBrace, "'{'");
  const uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    if (check(p, Fn)) {
      const NodeId fn = parse_function(p, false);
      if (ast_at_const(p->ast, fn)->as.function.body != NODE_NONE)
        parser_errorf(
            p, node_span(p, fn).start, node_span(p, fn).end - node_span(p, fn).start,
            "extern function declarations cannot have a body");
      expect(p, Semicolon, "';'");
      ast_push(p->ast, fn);
    } else if (check(p, Type)) {
      ast_push(p->ast, parse_type_alias(p, true));
    } else {
      error_here(p, "expected extern item");
      advance(p);
    }
  }
  const NodeList items = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_EXTERN_BLOCK,
                  .span = span_new(start, previous_end(p)),
                  .as.extern_block = {.abi = abi, .items = items},
              });
}

// `import <ident> (:: <ident>)* [as <ident>] ;` -- top-level, LL(1) (the `import` keyword is the
// one-token decision; the optional `as` is decided by a single lookahead).
static NodeId parse_import(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  advance(p);
  const uint32_t mark = ast_mark(p->ast);
  ast_push(p->ast, identifier(p));
  while (match(p, PathSeparator))
    ast_push(p->ast, identifier(p));
  const NodeList path = ast_commit(p->ast, mark);
  // `as <name>` aliases the module; `as *` is a glob (its public items become unqualified). LL(1): one
  // token of lookahead after `as` distinguishes `*` from an identifier.
  NodeId alias = NODE_NONE;
  bool glob = false;
  if (match(p, As)) {
    if (match(p, Star))
      glob = true;
    else
      alias = identifier(p);
  }
  expect(p, Semicolon, "';'");
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_IMPORT,
                  .span = span_new(start, previous_end(p)),
                  .as.import_decl = {.path = path, .alias = alias, .glob = glob},
              });
}

static NodeId parse_item(Parser *p) {
  // `pub` (LL(1): one-token lookahead) may prefix a struct, enum, function, const, or type alias.
  const bool is_public = match(p, Pub);
  if (is_public && !check(p, Fn) && !check(p, Struct) && !check(p, Enum) && !check(p, Const) && !check(p, Type))
    error_here(p, "'pub' may only be applied to a struct, enum, function, const, or type");
  switch (peek_type(p)) {
    case Fn: {
      const NodeId f = parse_function(p, true);
      ast_at(p->ast, f)->as.function.is_public = is_public;
      return f;
    }
    case Struct: {
      const NodeId s = parse_struct(p);
      ast_at(p->ast, s)->as.aggregate.is_public = is_public;
      return s;
    }
    case Enum: {
      const NodeId e = parse_enum(p);
      ast_at(p->ast, e)->as.aggregate.is_public = is_public;
      return e;
    }
    case Interface:
      return parse_interface(p);
    case Extend:
      return parse_extend(p);
    case Type: {
      const NodeId ta = parse_type_alias(p, false);
      ast_at(p->ast, ta)->as.type_alias.is_public = is_public;
      return ta;
    }
    case Const: {
      const NodeId cn = parse_const(p);
      ast_at(p->ast, cn)->as.const_def.is_public = is_public;
      return cn;
    }
    case Extern:
      return parse_extern(p);
    case Import:
      return parse_import(p);
    default:
      error_here(p, "expected top-level item");
      while (!at_end(p) && !check(p, Semicolon))
        advance(p);
      match(p, Semicolon);
      return NODE_NONE;
  }
}

static NodeList parse_arguments(Parser *p) {
  const uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightParen) && !at_end(p)) {
    ast_push(p->ast, parse_expression(p));
    if (!match(p, Comma))
      break;
  }
  return ast_commit(p->ast, mark);
}

static NodeId parse_struct_initializer_after(Parser *p, const NodeId type, const uint32_t start) {
  expect(p, LeftBrace, "'{'");
  const uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    const uint32_t field_start = token_start(raw_peek(p));
    const NodeId name = identifier(p);
    NodeId value = name;
    if (match(p, Colon))
      value = parse_expression(p);
    ast_push(
        p->ast, ast_add(
                    p->ast, (Node){
                                .kind = NODE_FIELD_INITIALIZER,
                                .span = span_new(field_start, node_span(p, value).end),
                                .as.field_initializer = {.name = name, .value = value},
                            }));
    if (!match(p, Comma))
      break;
  }
  const NodeList fields = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_STRUCT_INITIALIZER,
                  .span = span_new(start, previous_end(p)),
                  .as.struct_initializer = {.type = type, .fields = fields},
              });
}

static NodeId parse_switch(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  advance(p);
  const bool old = p->allow_struct_initializer;
  p->allow_struct_initializer = false;
  const NodeId value = parse_expression(p);
  p->allow_struct_initializer = old;
  expect(p, LeftBrace, "'{'");
  const uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    const uint32_t arm_start = token_start(raw_peek(p));
    match(p, Case);
    const NodeId pattern = parse_pattern(p);
    const NodeId guard = match(p, If) ? parse_expression(p) : NODE_NONE;
    expect(p, FatArrow, "'=>'");
    const NodeId body = check(p, LeftBrace) ? parse_block(p) : parse_expression(p);
    ast_push(
        p->ast, ast_add(
                    p->ast, (Node){
                                .kind = NODE_MATCH_ARM,
                                .span = span_new(arm_start, node_span(p, body).end),
                                .as.match_arm = {.pattern = pattern, .guard = guard, .body = body},
                            }));
    if (!match(p, Comma) && !check(p, RightBrace))
      error_here(p, "expected ',' or '}' after switch arm");
  }
  const NodeList arms = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_MATCH,
                  .span = span_new(start, previous_end(p)),
                  .as.match_expr = {.value = value, .arms = arms},
              });
}

ALWAYS_INLINE bool is_literal_token(const TokenType type) {
  return type == IntegerLiteral || type == FloatLiteral || type == CharacterLiteral || type == ByteCharacterLiteral ||
         type == StringLiteral || type == RawStringLiteral || type == True || type == False || type == Null;
}

static NodeId parse_pattern_atom(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  if (is_literal_token(peek_type(p))) {
    const NodeId value = literal(p);
    return ast_add(
        p->ast, (Node){
                    .kind = NODE_PATTERN_LITERAL,
                    .span = node_span(p, value),
                    .as.single = {.value = value},
                });
  }
  if (match(p, LeftParen)) {
    const NodeId inner = parse_pattern(p);
    expect(p, RightParen, "')'");
    const uint32_t mark = ast_mark(p->ast);
    ast_push(p->ast, inner);
    return ast_add(
        p->ast, (Node){
                    .kind = NODE_PATTERN_TUPLE,
                    .span = span_new(start, previous_end(p)),
                    .as.pattern = {.children = ast_commit(p->ast, mark)},
                });
  }
  if (check(p, Identifier)) {
    const NodeId name = identifier(p);
    const Node *const name_node = ast_at_const(p->ast, name);
    const Span text = name_node->as.name.text;
    if (text.end - text.start == 1 && p->source[text.start] == '_')
      return ast_add(p->ast, (Node){.kind = NODE_PATTERN_WILDCARD, .span = node_span(p, name)});
    if (match(p, LeftParen)) {
      const uint32_t mark = ast_mark(p->ast);
      while (!check(p, RightParen) && !at_end(p)) {
        ast_push(p->ast, parse_pattern(p));
        if (!match(p, Comma))
          break;
      }
      const NodeList children = ast_commit(p->ast, mark);
      expect(p, RightParen, "')'");
      return ast_add(
          p->ast, (Node){
                      .kind = NODE_PATTERN_TUPLE,
                      .span = span_new(start, previous_end(p)),
                      .as.pattern = {.name = name, .children = children},
                  });
    }
    if (match(p, LeftBrace)) {
      const uint32_t mark = ast_mark(p->ast);
      while (!check(p, RightBrace) && !at_end(p)) {
        const uint32_t field_start = token_start(raw_peek(p));
        const NodeId field_name = identifier(p);
        NodeId child = field_name;
        if (match(p, Colon))
          child = parse_pattern(p);
        const uint32_t child_mark = ast_mark(p->ast);
        ast_push(p->ast, child);
        ast_push(
            p->ast, ast_add(
                        p->ast, (Node){
                                    .kind = NODE_PATTERN_FIELD,
                                    .span = span_new(field_start, node_span(p, child).end),
                                    .as.pattern = {.name = field_name, .children = ast_commit(p->ast, child_mark)},
                                }));
        if (!match(p, Comma))
          break;
      }
      const NodeList children = ast_commit(p->ast, mark);
      expect(p, RightBrace, "'}'");
      return ast_add(
          p->ast, (Node){
                      .kind = NODE_PATTERN_STRUCT,
                      .span = span_new(start, previous_end(p)),
                      .as.pattern = {.name = name, .children = children},
                  });
    }
    return ast_add(
        p->ast, (Node){
                    .kind = NODE_PATTERN_NAME,
                    .span = node_span(p, name),
                    .as.pattern = {.name = name},
                });
  }
  error_here(p, "expected pattern");
  if (!at_end(p))
    advance(p);
  return NODE_NONE;
}

static NodeId parse_pattern(Parser *p) {
  return parse_range(p, RANGE_PATTERN);
}

static NodeId parse_primary(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  const TokenType type = peek_type(p);
  if (is_literal_token(type))
    return literal(p);
  if (type == SelfLower) {
    const Token token = advance(p);
    return ast_add(
        p->ast, (Node){.kind = NODE_IDENTIFIER, .span = token_span(token), .as.name = {.text = token_span(token)}});
  }
  if (type == Identifier) {
    const NodeId value = identifier(p);
    if (p->allow_struct_initializer && check(p, LeftBrace))
      return parse_struct_initializer_after(p, value, start);
    return value;
  }
  if (match(p, LeftParen)) {
    const bool old = p->allow_struct_initializer; // parens are the escape hatch: re-enable struct literals inside
    p->allow_struct_initializer = true;
    const NodeId value = parse_expression(p);
    p->allow_struct_initializer = old;
    expect(p, RightParen, "')'");
    return value;
  }
  if (type == Switch)
    return parse_switch(p);
  if (type == If) // `if cond { a; } else { b; }` as a value (one-token lookahead, LL(1))
    return parse_if(p);
  if (match(p, Sizeof)) { // `sizeof(T)` -> usize byte size of a type
    expect(p, LeftParen, "'('");
    const NodeId ty = parse_type(p);
    expect(p, RightParen, "')'");
    return ast_add(
        p->ast, (Node){
                    .kind = NODE_SIZEOF,
                    .span = span_new(start, previous_end(p)),
                    .as.single = {.value = ty},
                });
  }
  if (match(p, New)) {
    const NodeId new_type = parse_type(p);
    NodeId initializer = NODE_NONE;
    if (check(p, LeftBrace)) // `new T { .. }` struct initializer
      initializer = parse_struct_initializer_after(p, new_type, node_span(p, new_type).start);
    else if (match(p, LeftParen)) { // `new T(expr)` scalar initializer (one-token lookahead, LL(1))
      initializer = parse_expression(p);
      expect(p, RightParen, "')'");
    }
    return ast_add(
        p->ast, (Node){
                    .kind = NODE_NEW,
                    .span = span_new(start, previous_end(p)),
                    .as.new_expr = {.type = new_type, .initializer = initializer},
                });
  }
  if (match(p, LeftBracket)) { // `[e0, e1, ...]` array literal (postfix `[` indexing lives in parse_postfix)
    const uint32_t mark = ast_mark(p->ast);
    while (!check(p, RightBracket) && !at_end(p)) {
      ast_push(p->ast, parse_expression(p));
      if (!match(p, Comma))
        break;
    }
    const NodeList elements = ast_commit(p->ast, mark);
    expect(p, RightBracket, "']'");
    return ast_add(
        p->ast, (Node){
                    .kind = NODE_ARRAY_LITERAL,
                    .span = span_new(start, previous_end(p)),
                    .as.array_literal = {.elements = elements},
                });
  }
  error_here(p, "expected expression");
  if (!at_end(p))
    advance(p);
  return NODE_NONE;
}

// Rebuild a just-parsed `a::b::C` value path (a NODE_MEMBER chain) as a NODE_TYPE_PATH, so a qualified
// struct construction `a::b::C { .. }` reuses the same type-path resolution as `a::b::C` in type position.
static NodeId path_chain_to_type_path(Parser *p, const NodeId chain, const uint32_t start) {
  NodeId segs[16];
  uint32_t n = 0;
  for (NodeId cur = chain;;) { // collect segment name nodes outermost..base
    const Node *const cn = ast_at(p->ast, cur);
    if (n < 16)
      segs[n++] = cn->as.member.member;
    const NodeId o = cn->as.member.object;
    if (ast_at(p->ast, o)->kind != NODE_MEMBER) {
      if (n < 16)
        segs[n++] = o; // the base identifier
      break;
    }
    cur = o;
  }
  const uint32_t mark = ast_mark(p->ast);
  for (uint32_t i = n; i-- > 0;) // push base..outermost so parts read left-to-right
    ast_push(p->ast, segs[i]);
  const NodeList parts = ast_commit(p->ast, mark);
  return ast_add(p->ast, (Node){
                             .kind = NODE_TYPE_PATH,
                             .span = span_new(start, previous_end(p)),
                             .as.type_path = {.parts = parts, .args = {0}},
                         });
}

static NodeId parse_postfix(Parser *p) {
  NodeId expr = parse_primary(p);
  for (;;) {
    const uint32_t start = node_span(p, expr).start;
    if (match(p, LeftParen)) {
      const NodeList args = parse_arguments(p);
      expect(p, RightParen, "')'");
      expr = ast_add(
          p->ast, (Node){
                      .kind = NODE_CALL,
                      .span = span_new(start, previous_end(p)),
                      .as.call = {.callee = expr, .args = args},
                  });
    } else if (match(p, LeftBracket)) {
      const NodeId index = parse_expression(p);
      expect(p, RightBracket, "']'");
      expr = ast_add(
          p->ast, (Node){
                      .kind = NODE_INDEX,
                      .span = span_new(start, previous_end(p)),
                      .as.index = {.object = expr, .index = index},
                  });
    } else if (check(p, Dot) || check(p, Arrow)) {
      const bool pointer = match(p, Arrow);
      if (!pointer)
        advance(p);
      const NodeId member = callable_name(p);
      expr = ast_add(
          p->ast, (Node){
                      .kind = NODE_MEMBER,
                      .span = span_new(start, node_span(p, member).end),
                      .as.member = {.object = expr, .member = member, .pointer = pointer},
                  });
    } else if (match(p, PathSeparator)) {
      if (check(p, LessThan)) { // `expr::<T, ...>` turbofish
        const NodeList types = parse_type_args(p);
        const NodeId inner = expr;
        expr = ast_add(
            p->ast, (Node){
                        .kind = NODE_GENERIC_SPECIALIZATION,
                        .span = span_new(start, previous_end(p)),
                        .as.specialization = {.expression = inner, .types = types},
                    });
        if (p->allow_struct_initializer && check(p, LeftBrace)) { // `T::<A..> { .. }` generic construction
          NodeId tp;
          if (ast_at(p->ast, inner)->kind == NODE_MEMBER) {
            tp = path_chain_to_type_path(p, inner, start);
          } else { // bare type name base
            const uint32_t mark = ast_mark(p->ast);
            ast_push(p->ast, inner);
            tp = ast_add(p->ast, (Node){
                                     .kind = NODE_TYPE_PATH,
                                     .span = span_new(start, previous_end(p)),
                                     .as.type_path = {.parts = ast_commit(p->ast, mark)},
                                 });
          }
          ast_at(p->ast, tp)->as.type_path.args = types;
          return parse_struct_initializer_after(p, tp, start);
        }
      } else { // `Enum::Variant` path access (one-token lookahead keeps this LL(1))
        const NodeId member = callable_name(p);
        expr = ast_add(
            p->ast, (Node){
                        .kind = NODE_MEMBER,
                        .span = span_new(start, node_span(p, member).end),
                        .as.member = {.object = expr, .member = member, .path = true},
                    });
        if (p->allow_struct_initializer && check(p, LeftBrace)) // `a::b::C { .. }` qualified construction
          return parse_struct_initializer_after(p, path_chain_to_type_path(p, expr, start), start);
      }
    } else if (match(p, As)) {
      const NodeId cast_type = parse_type(p);
      expr = ast_add(
          p->ast, (Node){
                      .kind = NODE_CAST,
                      .span = span_new(start, node_span(p, cast_type).end),
                      .as.cast = {.expression = expr, .type = cast_type},
                  });
    } else {
      break;
    }
  }
  return expr;
}

ALWAYS_INLINE bool unary_operator(const TokenType type) {
  return type == Bang || type == Minus || type == Star || type == Ampersand || type == Move || type == Unsafe;
}

static NodeId parse_unary(Parser *p) {
  if (!unary_operator(peek_type(p)))
    return parse_postfix(p);
  const Token op = advance(p);
  // `&mut expr` is a mutable address-of (one-token lookahead after `&`, so still LL(1)).
  const TypeQualifier qualifier = token_type(op) == Ampersand && match(p, Mut) ? TYPE_QUAL_MUT : TYPE_QUAL_NONE;
  const NodeId operand = token_type(op) == Unsafe && check(p, LeftBrace) ? parse_block(p) : parse_unary(p);
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_UNARY,
                  .span = span_new(token_start(op), node_span(p, operand).end),
                  .as.unary = {.op = token_type(op), .operand = operand, .qualifier = qualifier},
              });
}

ALWAYS_INLINE int precedence(const TokenType type) {
  switch (type) {
    case Star:
    case Slash:
    case Percent:
      return 11;
    case Plus:
    case Minus:
      return 10;
    case LeftShift:
    case RightShift:
      return 9;
    case LessThan:
    case LessThanEqual:
    case GreaterThan:
    case GreaterThanEqual:
      return 8;
    case EqualEqual:
    case BangEqual:
      return 7;
    case Ampersand:
      return 6;
    case Caret:
      return 5;
    case Pipe:
      return 4;
    case AmpersandAmpersand:
      return 3;
    case PipePipe:
      return 2;
    default:
      return 0;
  }
}

static NodeId parse_binary(Parser *p, const int minimum) {
  NodeId left = parse_unary(p);
  for (;;) {
    const TokenType op = peek_type(p);
    const int prec = precedence(op);
    if (prec < minimum)
      break;
    advance(p);
    const NodeId right = parse_binary(p, prec + 1);
    left = ast_add(
        p->ast, (Node){
                    .kind = NODE_BINARY,
                    .span = span_new(node_span(p, left).start, node_span(p, right).end),
                    .as.binary = {.op = op, .left = left, .right = right},
                });
  }
  return left;
}

ALWAYS_INLINE bool assignment_operator(const TokenType type) {
  return type == Equal || type == PlusEqual || type == MinusEqual || type == StarEqual || type == SlashEqual ||
         type == PercentEqual;
}

static NodeId parse_expression(Parser *p) {
  const NodeId left = parse_binary(p, 1);
  if (!assignment_operator(peek_type(p)))
    return left;
  const TokenType op = token_type(advance(p));
  const NodeId right = parse_expression(p);
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_ASSIGNMENT,
                  .span = span_new(node_span(p, left).start, node_span(p, right).end),
                  .as.binary = {.op = op, .left = left, .right = right},
              });
}

// A range bound: an expression in a `for`, a pattern atom in a `switch`.
static NodeId parse_range_bound(Parser *p, const RangeContext context) {
  return context == RANGE_PATTERN ? parse_pattern_atom(p) : parse_expression(p);
}

// Whether the current token can begin a bound (FIRST set). Used to spot a missing end: anything
// that can't start a bound (`{`, `=>`, `)`, `,`, `}`, a guard `if`, ...) closes a half-open range.
static bool starts_range_bound(Parser *p, const RangeContext context) {
  const TokenType t = peek_type(p);
  if (context == RANGE_PATTERN)
    return is_literal_token(t) || t == Identifier || t == LeftParen;
  return is_literal_token(t) || t == Identifier || t == LeftParen || t == SelfLower || t == New || t == Switch ||
         t == Sizeof || unary_operator(t);
}

// `(start)?..(=)?(end)?` with at least one bound. Without a `..` it returns the lone start, so a
// plain `for` iterable / `switch` pattern flows straight through. NODE_RANGE vs NODE_PATTERN_RANGE
// is the only thing the context changes; both reuse the `pattern_range` payload.
static NodeId parse_range(Parser *p, const RangeContext context) {
  const bool open_start = check(p, Range) || check(p, RangeInclusive);
  const NodeId start = open_start ? NODE_NONE : parse_range_bound(p, context);
  if (!check(p, Range) && !check(p, RangeInclusive))
    return start; // not a range
  const uint32_t op_start = token_start(raw_peek(p));
  const bool inclusive = token_type(advance(p)) == RangeInclusive;
  const NodeId end = starts_range_bound(p, context) ? parse_range_bound(p, context) : NODE_NONE;
  if (start == NODE_NONE && end == NODE_NONE)
    error_here(p, "a range needs a start and/or an end");
  else if (inclusive && end == NODE_NONE)
    error_here(p, "an inclusive range '..=' needs an end");
  const uint32_t lo = start != NODE_NONE ? node_span(p, start).start : op_start;
  const uint32_t hi = end != NODE_NONE ? node_span(p, end).end : previous_end(p);
  return ast_add(
      p->ast, (Node){
                  .kind = context == RANGE_PATTERN ? NODE_PATTERN_RANGE : NODE_RANGE,
                  .span = span_new(lo, hi),
                  .as.pattern_range = {.start = start, .end = end, .inclusive = inclusive},
              });
}

static NodeId parse_let(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  advance(p);
  const bool is_mutable = match(p, Mut);
  // `let (a, b, ..) = call` destructures a multi-value return; a `(` after `let` is unambiguous
  // (a single binding is always a bare identifier), keeping this LL(1).
  NodeId name;
  if (check(p, LeftParen)) {
    const uint32_t tstart = token_start(raw_peek(p));
    advance(p);
    const uint32_t mark = ast_mark(p->ast);
    while (!check(p, RightParen) && !at_end(p)) {
      ast_push(p->ast, identifier(p));
      if (!match(p, Comma))
        break;
    }
    const NodeList children = ast_commit(p->ast, mark);
    expect(p, RightParen, "')'");
    name = ast_add(
        p->ast, (Node){
                    .kind = NODE_PATTERN_TUPLE,
                    .span = span_new(tstart, previous_end(p)),
                    .as.pattern = {.name = NODE_NONE, .children = children},
                });
  } else {
    name = identifier(p);
  }
  NodeId type = NODE_NONE;
  NodeId value = NODE_NONE;
  if (match(p, Colon)) {
    type = parse_type(p);
    if (match(p, Equal))
      value = parse_expression(p);
  } else if (match(p, Equal)) {
    value = parse_expression(p);
  } else {
    error_here(p, "expected type annotation or initializer");
  }
  expect(p, Semicolon, "';'");
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_LET,
                  .span = span_new(start, previous_end(p)),
                  .as.let_stmt = {.name = name, .type = type, .value = value, .is_mutable = is_mutable},
              });
}

static NodeId parse_if(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  advance(p);
  const bool old = p->allow_struct_initializer; // a bare `{` after the condition is the block, never a struct literal
  p->allow_struct_initializer = false;
  const NodeId condition = parse_expression(p);
  p->allow_struct_initializer = old;
  const NodeId then_branch = parse_block(p);
  const NodeId else_branch = match(p, Else) ? (check(p, If) ? parse_if(p) : parse_block(p)) : NODE_NONE;
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_IF,
                  .span = span_new(start, node_span(p, else_branch ? else_branch : then_branch).end),
                  .as.if_stmt = {.condition = condition, .then_branch = then_branch, .else_branch = else_branch},
              });
}

static NodeId parse_statement(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  switch (peek_type(p)) {
    case LeftBrace:
      return parse_block(p);
    case Let:
      return parse_let(p);
    case Const:
      return parse_const(p);
    case Return: {
      advance(p);
      const uint32_t mark = ast_mark(p->ast);
      if (!check(p, Semicolon)) {
        do {
          ast_push(p->ast, parse_expression(p));
        } while (match(p, Comma));
      }
      const NodeList values = ast_commit(p->ast, mark);
      expect(p, Semicolon, "';'");
      return ast_add(
          p->ast, (Node){
                      .kind = NODE_RETURN,
                      .span = span_new(start, previous_end(p)),
                      .as.return_stmt = {.values = values},
                  });
    }
    case Break:
    case Continue: {
      const NodeKind kind = check(p, Break) ? NODE_BREAK : NODE_CONTINUE;
      advance(p);
      expect(p, Semicolon, "';'");
      return ast_add(p->ast, (Node){.kind = kind, .span = span_new(start, previous_end(p))});
    }
    case Defer: {
      advance(p);
      const NodeId value = check(p, LeftBrace) ? parse_block(p) : parse_expression(p);
      if (ast_at_const(p->ast, value)->kind != NODE_BLOCK)
        expect(p, Semicolon, "';'");
      return ast_add(
          p->ast, (Node){.kind = NODE_DEFER, .span = span_new(start, previous_end(p)), .as.single = {.value = value}});
    }
    case If:
      return parse_if(p);
    case While: {
      advance(p);
      const bool old = p->allow_struct_initializer; // see parse_if: condition cannot end in a struct literal
      p->allow_struct_initializer = false;
      const NodeId condition = parse_expression(p);
      p->allow_struct_initializer = old;
      const NodeId body = parse_block(p);
      return ast_add(
          p->ast, (Node){
                      .kind = NODE_WHILE,
                      .span = span_new(start, node_span(p, body).end),
                      .as.while_stmt = {.condition = condition, .body = body},
                  });
    }
    case For: {
      advance(p);
      const NodeId binding = identifier(p);
      expect(p, In, "'in'");
      const bool old = p->allow_struct_initializer;
      p->allow_struct_initializer = false;
      const NodeId iterable = parse_range(p, RANGE_FOR); // a range `(start)?..(=)?(end)?` or a plain collection
      p->allow_struct_initializer = old;
      const NodeId body = parse_block(p);
      return ast_add(
          p->ast, (Node){
                      .kind = NODE_FOR,
                      .span = span_new(start, node_span(p, body).end),
                      .as.for_stmt = {.binding = binding, .iterable = iterable, .body = body},
                  });
    }
    case Unsafe: {
      const NodeId expression = parse_expression(p);
      const Node *const node = ast_at_const(p->ast, expression);
      const bool block = node->kind == NODE_UNARY && node->as.unary.op == Unsafe &&
                         ast_at_const(p->ast, node->as.unary.operand)->kind == NODE_BLOCK;
      if (!block)
        expect(p, Semicolon, "';'");
      return ast_add(
          p->ast, (Node){
                      .kind = NODE_EXPRESSION_STATEMENT,
                      .span = span_new(start, previous_end(p)),
                      .as.single = {.value = expression},
                  });
    }
    default: {
      const NodeId expression = parse_expression(p);
      expect(p, Semicolon, "';'");
      return ast_add(
          p->ast, (Node){
                      .kind = NODE_EXPRESSION_STATEMENT,
                      .span = span_new(start, previous_end(p)),
                      .as.single = {.value = expression},
                  });
    }
  }
}

static NodeId parse_block(Parser *p) {
  const uint32_t start = token_start(raw_peek(p));
  expect(p, LeftBrace, "'{'");
  const uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p))
    ast_push(p->ast, parse_statement(p));
  const NodeList statements = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(
      p->ast, (Node){
                  .kind = NODE_BLOCK,
                  .span = span_new(start, previous_end(p)),
                  .as.block = {.statements = statements},
              });
}

void parser_build_ast(Parser *p) {
  const uint32_t mark = ast_mark(p->ast);
  while (!at_end(p)) {
    const size_t before = p->current;
    const NodeId item = parse_item(p);
    if (item)
      ast_push(p->ast, item);
    if (p->current == before && !at_end(p))
      advance(p);
  }
  const NodeList items = ast_commit(p->ast, mark);
  p->ast->root = ast_add(
      p->ast, (Node){
                  .kind = NODE_PROGRAM,
                  .span = span_new(0, (uint32_t)p->len),
                  .as.program = {.items = items},
              });
  errors_finalize(&p->errors, &p->errors_start, &p->errors_len, p->source, p->len);
}

ERRORS_BODY(Parser, parser, p)
