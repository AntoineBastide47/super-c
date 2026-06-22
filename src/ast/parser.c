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
static NodeId parse_expression(Parser *p);
static NodeId parse_type(Parser *p);
static NodeId parse_pattern(Parser *p);

Parser *parser_new(Token_Vec tokens, const char *source, size_t len) {
  Parser *p = calloc(1, sizeof *p);
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
  Ast *ast = p->ast;
  p->ast = NULL;
  return ast;
}

static Token raw_peek(const Parser *p) {
  return p->tokens.data[p->current];
}

static TokenType peek_type(const Parser *p) {
  return p->pending_gt ? GreaterThan : token_type(raw_peek(p));
}

static bool at_end(const Parser *p) {
  return peek_type(p) == Eof;
}

static Token advance(Parser *p) {
  if (p->pending_gt) {
    p->pending_gt--;
    Token source = p->tokens.data[p->current - 1];
    return token_new(GreaterThan, token_end(source) - 1, 1);
  }
  Token t = raw_peek(p);
  if (token_type(t) != Eof)
    p->current++;
  return t;
}

static bool check(const Parser *p, TokenType type) {
  return peek_type(p) == type;
}

static bool match(Parser *p, TokenType type) {
  if (!check(p, type))
    return false;
  advance(p);
  return true;
}

static uint32_t previous_end(const Parser *p) {
  if (p->pending_gt)
    return token_end(p->tokens.data[p->current - 1]) - p->pending_gt;
  return p->current ? token_end(p->tokens.data[p->current - 1]) : 0;
}

static Span node_span(const Parser *p, NodeId id) {
  return id == NODE_NONE ? span_empty() : ast_at_const(p->ast, id)->span;
}

static void error_here(Parser *p, const char *message) {
  Token t = raw_peek(p);
  parser_errorf(p, token_start(t), token_len(t), "%s", message);
}

static bool expect(Parser *p, TokenType type, const char *display) {
  if (match(p, type))
    return true;
  Token t = raw_peek(p);
  parser_errorf(p, token_start(t), token_len(t), "expected %s", display);
  return false;
}

static bool consume_type_gt(Parser *p) {
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
  Token token = raw_peek(p);
  if (!check(p, Identifier) && !check(p, SelfUpper)) {
    error_here(p, "expected identifier");
    if (!at_end(p))
      advance(p);
    return NODE_NONE;
  }
  token = advance(p);
  return ast_add(p->ast, (Node){
      .kind = NODE_IDENTIFIER,
      .span = token_span(token),
      .as.name = {.text = token_span(token)},
  });
}

static NodeId literal(Parser *p) {
  Token token = advance(p);
  return ast_add(p->ast, (Node){
      .kind = NODE_LITERAL,
      .span = token_span(token),
      .as.literal = {.raw = token_span(token), .token_type = token_type(token)},
  });
}

static NodeList parse_comma_types(Parser *p, TokenType close) {
  uint32_t mark = ast_mark(p->ast);
  while (!check(p, close) && !at_end(p)) {
    ast_push(p->ast, parse_type(p));
    if (!match(p, Comma))
      break;
  }
  return ast_commit(p->ast, mark);
}

static NodeList parse_type_args(Parser *p) {
  expect(p, LessThan, "'<'");
  uint32_t mark = ast_mark(p->ast);
  while (!check(p, GreaterThan) && !check(p, RightShift) && !at_end(p)) {
    ast_push(p->ast, parse_type(p));
    if (!match(p, Comma))
      break;
  }
  NodeList args = ast_commit(p->ast, mark);
  consume_type_gt(p);
  return args;
}

static NodeId parse_type_path(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  uint32_t mark = ast_mark(p->ast);
  ast_push(p->ast, identifier(p));
  while (match(p, PathSeparator))
    ast_push(p->ast, identifier(p));
  NodeList parts = ast_commit(p->ast, mark);
  NodeList args = {0};
  if (check(p, LessThan))
    args = parse_type_args(p);
  return ast_add(p->ast, (Node){
      .kind = NODE_TYPE_PATH,
      .span = span_new(start, previous_end(p)),
      .as.type_path = {.parts = parts, .args = args},
  });
}

static TypeQualifier parse_qualifier(Parser *p) {
  if (match(p, Const))
    return TYPE_QUAL_CONST;
  if (match(p, Mut))
    return TYPE_QUAL_MUT;
  return TYPE_QUAL_NONE;
}

static NodeId parse_type(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  if (match(p, Star) || match(p, Ampersand)) {
    TokenType opener = token_type(p->tokens.data[p->current - 1]);
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
    NodeId type = parse_type(p);
    return ast_add(p->ast, (Node){
        .kind = opener == Star ? NODE_POINTER_TYPE : NODE_REFERENCE_TYPE,
        .span = span_new(start, node_span(p, type).end),
        .as.indirect_type = {.type = type, .qualifier = qualifier},
    });
  }
  if (match(p, LeftBracket)) {
    if (match(p, RightBracket)) {
      NodeId element = parse_type(p);
      return ast_add(p->ast, (Node){
          .kind = NODE_SLICE_TYPE,
          .span = span_new(start, node_span(p, element).end),
          .as.indirect_type = {.type = element},
      });
    }
    NodeId element = parse_type(p);
    expect(p, Semicolon, "';'");
    NodeId length = parse_expression(p);
    expect(p, RightBracket, "']'");
    return ast_add(p->ast, (Node){
        .kind = NODE_ARRAY_TYPE,
        .span = span_new(start, previous_end(p)),
        .as.array_type = {.element = element, .length = length},
    });
  }
  if (match(p, Fn)) {
    expect(p, LeftParen, "'('");
    NodeList params = parse_comma_types(p, RightParen);
    expect(p, RightParen, "')'");
    NodeId result = NODE_NONE;
    if (match(p, Arrow))
      result = parse_type(p);
    return ast_add(p->ast, (Node){
        .kind = NODE_FUNCTION_TYPE,
        .span = span_new(start, previous_end(p)),
        .as.function_type = {.params = params, .return_type = result},
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
  uint32_t mark = ast_mark(p->ast);
  ast_push(p->ast, parse_type_path(p));
  while (match(p, Plus))
    ast_push(p->ast, parse_type_path(p));
  return ast_commit(p->ast, mark);
}

static NodeList parse_generics(Parser *p) {
  if (!match(p, LessThan))
    return (NodeList){0};
  uint32_t mark = ast_mark(p->ast);
  while (!check(p, GreaterThan) && !check(p, RightShift) && !at_end(p)) {
    uint32_t start = token_start(raw_peek(p));
    NodeId name = identifier(p);
    NodeList bounds = {0};
    if (match(p, Colon))
      bounds = parse_bounds(p);
    ast_push(p->ast, ast_add(p->ast, (Node){
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
  uint32_t mark = ast_mark(p->ast);
  do {
    uint32_t start = token_start(raw_peek(p));
    NodeId type = parse_type(p);
    expect(p, Colon, "':'");
    NodeList bounds = parse_bounds(p);
    ast_push(p->ast, ast_add(p->ast, (Node){
        .kind = NODE_WHERE_PREDICATE,
        .span = span_new(start, previous_end(p)),
        .as.where_predicate = {.type = type, .bounds = bounds},
    }));
  } while (match(p, Comma) && !check(p, LeftBrace) && !check(p, Semicolon));
  return ast_commit(p->ast, mark);
}

static NodeId parse_parameter(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  NodeId name;
  bool receiver = false;
  if (match(p, SelfLower)) {
    Token token = p->tokens.data[p->current - 1];
    name = ast_add(p->ast, (Node){.kind = NODE_IDENTIFIER, .span = token_span(token), .as.name = {.text = token_span(token)}});
    receiver = true;
  } else {
    name = identifier(p);
  }
  NodeId type = NODE_NONE;
  if (!receiver || match(p, Colon)) {
    if (!receiver)
      expect(p, Colon, "':'");
    type = parse_type(p);
  }
  return ast_add(p->ast, (Node){
      .kind = NODE_PARAMETER,
      .span = span_new(start, type ? node_span(p, type).end : previous_end(p)),
      .as.parameter = {.name = name, .type = type},
  });
}

static NodeList parse_parameters(Parser *p) {
  expect(p, LeftParen, "'('");
  uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightParen) && !at_end(p)) {
    ast_push(p->ast, parse_parameter(p));
    if (!match(p, Comma))
      break;
  }
  expect(p, RightParen, "')'");
  return ast_commit(p->ast, mark);
}

static NodeId parse_function(Parser *p, bool require_body) {
  uint32_t start = token_start(raw_peek(p));
  expect(p, Fn, "'fn'");
  NodeId name = identifier(p);
  NodeList generics = parse_generics(p);
  NodeList params = parse_parameters(p);
  NodeId return_type = NODE_NONE;
  if (match(p, Arrow))
    return_type = parse_type(p);
  NodeList where_clause = parse_where_clause(p);
  NodeId body = NODE_NONE;
  if (check(p, LeftBrace))
    body = parse_block(p);
  else if (require_body)
    error_here(p, "expected function body");
  return ast_add(p->ast, (Node){
      .kind = NODE_FUNCTION,
      .span = span_new(start, body ? node_span(p, body).end : previous_end(p)),
      .as.function = {
          .name = name, .generics = generics, .params = params, .return_type = return_type,
          .where_clause = where_clause, .body = body,
      },
  });
}

static NodeId parse_field(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  NodeId name = identifier(p);
  expect(p, Colon, "':'");
  NodeId type = parse_type(p);
  return ast_add(p->ast, (Node){
      .kind = NODE_FIELD, .span = span_new(start, node_span(p, type).end), .as.field = {.name = name, .type = type},
  });
}

static NodeList parse_fields(Parser *p) {
  uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    ast_push(p->ast, parse_field(p));
    if (!match(p, Comma))
      break;
  }
  return ast_commit(p->ast, mark);
}

static NodeId parse_struct(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  advance(p);
  NodeId name = identifier(p);
  NodeList generics = parse_generics(p);
  expect(p, LeftBrace, "'{'");
  NodeList fields = parse_fields(p);
  expect(p, RightBrace, "'}'");
  return ast_add(p->ast, (Node){
      .kind = NODE_STRUCT, .span = span_new(start, previous_end(p)),
      .as.aggregate = {.name = name, .generics = generics, .members = fields},
  });
}

static NodeId parse_variant(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  NodeId name = identifier(p);
  NodeList payload = {0};
  bool struct_payload = false;
  if (match(p, LeftParen)) {
    payload = parse_comma_types(p, RightParen);
    expect(p, RightParen, "')'");
  } else if (match(p, LeftBrace)) {
    struct_payload = true;
    payload = parse_fields(p);
    expect(p, RightBrace, "'}'");
  }
  return ast_add(p->ast, (Node){
      .kind = NODE_VARIANT, .span = span_new(start, previous_end(p)),
      .as.variant = {.name = name, .payload = payload, .struct_payload = struct_payload},
  });
}

static NodeId parse_enum(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  advance(p);
  NodeId name = identifier(p);
  NodeList generics = parse_generics(p);
  expect(p, LeftBrace, "'{'");
  uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    ast_push(p->ast, parse_variant(p));
    if (!match(p, Comma))
      break;
  }
  NodeList variants = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(p->ast, (Node){
      .kind = NODE_ENUM, .span = span_new(start, previous_end(p)),
      .as.aggregate = {.name = name, .generics = generics, .members = variants},
  });
}

static NodeId parse_type_alias(Parser *p, bool opaque) {
  uint32_t start = token_start(raw_peek(p));
  expect(p, Type, "'type'");
  NodeId name = identifier(p);
  NodeList generics = opaque ? (NodeList){0} : parse_generics(p);
  NodeId type = NODE_NONE;
  if (!opaque || match(p, Equal)) {
    if (!opaque)
      expect(p, Equal, "'='");
    type = parse_type(p);
  }
  expect(p, Semicolon, "';'");
  return ast_add(p->ast, (Node){
      .kind = NODE_TYPE_ALIAS, .span = span_new(start, previous_end(p)),
      .as.type_alias = {.name = name, .generics = generics, .type = type},
  });
}

static NodeId parse_const(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  advance(p);
  NodeId name = identifier(p);
  expect(p, Colon, "':'");
  NodeId type = parse_type(p);
  expect(p, Equal, "'='");
  NodeId value = parse_expression(p);
  expect(p, Semicolon, "';'");
  return ast_add(p->ast, (Node){
      .kind = NODE_CONST, .span = span_new(start, previous_end(p)),
      .as.const_def = {.name = name, .type = type, .value = value},
  });
}

static NodeId parse_interface(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  advance(p);
  NodeId name = identifier(p);
  NodeList generics = parse_generics(p);
  NodeList bounds = {0};
  if (match(p, Colon))
    bounds = parse_bounds(p);
  expect(p, LeftBrace, "'{'");
  uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    if (check(p, Fn)) {
      NodeId fn = parse_function(p, false);
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
  NodeList items = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(p->ast, (Node){
      .kind = NODE_TRAIT, .span = span_new(start, previous_end(p)),
      .as.trait_def = {.name = name, .generics = generics, .bounds = bounds, .items = items},
  });
}

static NodeId parse_extend(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  advance(p);
  NodeList generics = parse_generics(p);
  NodeId target = parse_type(p);
  NodeId trait_type = NODE_NONE;
  if (match(p, As)) {
    trait_type = parse_type(p);
  }
  expect(p, LeftBrace, "'{'");
  uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    if (check(p, Fn))
      ast_push(p->ast, parse_function(p, true));
    else if (check(p, Type))
      ast_push(p->ast, parse_type_alias(p, false));
    else {
      error_here(p, "expected extension item");
      advance(p);
    }
  }
  NodeList items = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(p->ast, (Node){
      .kind = NODE_IMPL, .span = span_new(start, previous_end(p)),
      .as.impl_def = {.generics = generics, .trait_type = trait_type, .target_type = target, .items = items},
  });
}

static NodeId parse_extern(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  advance(p);
  NodeId abi = check(p, StringLiteral) ? literal(p) : NODE_NONE;
  if (!abi)
    error_here(p, "expected ABI string");
  expect(p, LeftBrace, "'{'");
  uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    if (check(p, Fn)) {
      NodeId fn = parse_function(p, false);
      if (ast_at_const(p->ast, fn)->as.function.body != NODE_NONE)
        parser_errorf(p, node_span(p, fn).start, node_span(p, fn).end - node_span(p, fn).start,
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
  NodeList items = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(p->ast, (Node){
      .kind = NODE_EXTERN_BLOCK, .span = span_new(start, previous_end(p)),
      .as.extern_block = {.abi = abi, .items = items},
  });
}

static NodeId parse_item(Parser *p) {
  switch (peek_type(p)) {
    case Fn: return parse_function(p, true);
    case Struct: return parse_struct(p);
    case Enum: return parse_enum(p);
    case Interface: return parse_interface(p);
    case Extend: return parse_extend(p);
    case Type: return parse_type_alias(p, false);
    case Const: return parse_const(p);
    case Extern: return parse_extern(p);
    default:
      error_here(p, "expected top-level item");
      while (!at_end(p) && !check(p, Semicolon))
        advance(p);
      match(p, Semicolon);
      return NODE_NONE;
  }
}

static NodeList parse_arguments(Parser *p) {
  uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightParen) && !at_end(p)) {
    ast_push(p->ast, parse_expression(p));
    if (!match(p, Comma))
      break;
  }
  return ast_commit(p->ast, mark);
}

static NodeId parse_struct_initializer_after(Parser *p, NodeId type, uint32_t start) {
  expect(p, LeftBrace, "'{'");
  uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    uint32_t field_start = token_start(raw_peek(p));
    NodeId name = identifier(p);
    NodeId value = name;
    if (match(p, Colon))
      value = parse_expression(p);
    ast_push(p->ast, ast_add(p->ast, (Node){
        .kind = NODE_FIELD_INITIALIZER,
        .span = span_new(field_start, node_span(p, value).end),
        .as.field_initializer = {.name = name, .value = value},
    }));
    if (!match(p, Comma))
      break;
  }
  NodeList fields = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(p->ast, (Node){
      .kind = NODE_STRUCT_INITIALIZER,
      .span = span_new(start, previous_end(p)),
      .as.struct_initializer = {.type = type, .fields = fields},
  });
}

static NodeId parse_switch(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  advance(p);
  bool old = p->allow_struct_initializer;
  p->allow_struct_initializer = false;
  NodeId value = parse_expression(p);
  p->allow_struct_initializer = old;
  expect(p, LeftBrace, "'{'");
  uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p)) {
    uint32_t arm_start = token_start(raw_peek(p));
    match(p, Case);
    NodeId pattern = parse_pattern(p);
    NodeId guard = NODE_NONE;
    if (match(p, If))
      guard = parse_expression(p);
    expect(p, FatArrow, "'=>'");
    NodeId body = check(p, LeftBrace) ? parse_block(p) : parse_expression(p);
    ast_push(p->ast, ast_add(p->ast, (Node){
        .kind = NODE_MATCH_ARM,
        .span = span_new(arm_start, node_span(p, body).end),
        .as.match_arm = {.pattern = pattern, .guard = guard, .body = body},
    }));
    if (!match(p, Comma) && !check(p, RightBrace))
      error_here(p, "expected ',' or '}' after switch arm");
  }
  NodeList arms = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(p->ast, (Node){
      .kind = NODE_MATCH, .span = span_new(start, previous_end(p)), .as.match_expr = {.value = value, .arms = arms},
  });
}

static bool is_literal_token(TokenType type) {
  return type == IntegerLiteral || type == FloatLiteral || type == CharacterLiteral || type == ByteCharacterLiteral ||
         type == StringLiteral || type == RawStringLiteral || type == True || type == False || type == Null;
}

static NodeId parse_pattern_atom(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  if (is_literal_token(peek_type(p))) {
    NodeId value = literal(p);
    return ast_add(p->ast, (Node){
        .kind = NODE_PATTERN_LITERAL, .span = node_span(p, value), .as.single = {.value = value},
    });
  }
  if (match(p, LeftParen)) {
    NodeId inner = parse_pattern(p);
    expect(p, RightParen, "')'");
    uint32_t mark = ast_mark(p->ast);
    ast_push(p->ast, inner);
    return ast_add(p->ast, (Node){
        .kind = NODE_PATTERN_TUPLE, .span = span_new(start, previous_end(p)),
        .as.pattern = {.children = ast_commit(p->ast, mark)},
    });
  }
  if (check(p, Identifier)) {
    NodeId name = identifier(p);
    const Node *name_node = ast_at_const(p->ast, name);
    Span text = name_node->as.name.text;
    if (text.end - text.start == 1 && p->source[text.start] == '_')
      return ast_add(p->ast, (Node){.kind = NODE_PATTERN_WILDCARD, .span = node_span(p, name)});
    if (match(p, LeftParen)) {
      uint32_t mark = ast_mark(p->ast);
      while (!check(p, RightParen) && !at_end(p)) {
        ast_push(p->ast, parse_pattern(p));
        if (!match(p, Comma))
          break;
      }
      NodeList children = ast_commit(p->ast, mark);
      expect(p, RightParen, "')'");
      return ast_add(p->ast, (Node){
          .kind = NODE_PATTERN_TUPLE, .span = span_new(start, previous_end(p)),
          .as.pattern = {.name = name, .children = children},
      });
    }
    if (match(p, LeftBrace)) {
      uint32_t mark = ast_mark(p->ast);
      while (!check(p, RightBrace) && !at_end(p)) {
        uint32_t field_start = token_start(raw_peek(p));
        NodeId field_name = identifier(p);
        NodeId child = field_name;
        if (match(p, Colon))
          child = parse_pattern(p);
        uint32_t child_mark = ast_mark(p->ast);
        ast_push(p->ast, child);
        ast_push(p->ast, ast_add(p->ast, (Node){
            .kind = NODE_PATTERN_FIELD, .span = span_new(field_start, node_span(p, child).end),
            .as.pattern = {.name = field_name, .children = ast_commit(p->ast, child_mark)},
        }));
        if (!match(p, Comma))
          break;
      }
      NodeList children = ast_commit(p->ast, mark);
      expect(p, RightBrace, "'}'");
      return ast_add(p->ast, (Node){
          .kind = NODE_PATTERN_STRUCT, .span = span_new(start, previous_end(p)),
          .as.pattern = {.name = name, .children = children},
      });
    }
    return ast_add(p->ast, (Node){
        .kind = NODE_PATTERN_NAME, .span = node_span(p, name), .as.pattern = {.name = name},
    });
  }
  error_here(p, "expected pattern");
  if (!at_end(p))
    advance(p);
  return NODE_NONE;
}

static NodeId parse_pattern(Parser *p) {
  NodeId start = parse_pattern_atom(p);
  if (!check(p, Range) && !check(p, RangeInclusive))
    return start;
  TokenType op = token_type(advance(p));
  NodeId end = parse_pattern_atom(p);
  return ast_add(p->ast, (Node){
      .kind = NODE_PATTERN_RANGE,
      .span = span_new(node_span(p, start).start, node_span(p, end).end),
      .as.pattern_range = {.start = start, .end = end, .inclusive = op == RangeInclusive},
  });
}

static NodeId parse_primary(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  TokenType type = peek_type(p);
  if (is_literal_token(type))
    return literal(p);
  if (type == SelfLower) {
    Token token = advance(p);
    return ast_add(p->ast, (Node){.kind = NODE_IDENTIFIER, .span = token_span(token), .as.name = {.text = token_span(token)}});
  }
  if (type == Identifier) {
    NodeId value = identifier(p);
    if (p->allow_struct_initializer && check(p, LeftBrace))
      return parse_struct_initializer_after(p, value, start);
    return value;
  }
  if (match(p, LeftParen)) {
    NodeId value = parse_expression(p);
    expect(p, RightParen, "')'");
    return value;
  }
  if (type == Switch)
    return parse_switch(p);
  if (match(p, New)) {
    NodeId new_type = parse_type(p);
    NodeId initializer = NODE_NONE;
    if (check(p, LeftBrace))
      initializer = parse_struct_initializer_after(p, new_type, node_span(p, new_type).start);
    return ast_add(p->ast, (Node){
        .kind = NODE_NEW, .span = span_new(start, previous_end(p)), .as.new_expr = {.type = new_type, .initializer = initializer},
    });
  }
  error_here(p, "expected expression");
  if (!at_end(p))
    advance(p);
  return NODE_NONE;
}

static NodeId parse_postfix(Parser *p) {
  NodeId expr = parse_primary(p);
  for (;;) {
    uint32_t start = node_span(p, expr).start;
    if (match(p, LeftParen)) {
      NodeList args = parse_arguments(p);
      expect(p, RightParen, "')'");
      expr = ast_add(p->ast, (Node){
          .kind = NODE_CALL, .span = span_new(start, previous_end(p)), .as.call = {.callee = expr, .args = args},
      });
    } else if (match(p, LeftBracket)) {
      NodeId index = parse_expression(p);
      expect(p, RightBracket, "']'");
      expr = ast_add(p->ast, (Node){
          .kind = NODE_INDEX, .span = span_new(start, previous_end(p)), .as.index = {.object = expr, .index = index},
      });
    } else if (check(p, Dot) || check(p, Arrow)) {
      bool pointer = match(p, Arrow);
      if (!pointer)
        advance(p);
      NodeId member = identifier(p);
      expr = ast_add(p->ast, (Node){
          .kind = NODE_MEMBER, .span = span_new(start, node_span(p, member).end),
          .as.member = {.object = expr, .member = member, .pointer = pointer},
      });
    } else if (match(p, PathSeparator)) {
      NodeList types = parse_type_args(p);
      expr = ast_add(p->ast, (Node){
          .kind = NODE_GENERIC_SPECIALIZATION, .span = span_new(start, previous_end(p)),
          .as.specialization = {.expression = expr, .types = types},
      });
    } else if (match(p, As)) {
      NodeId cast_type = parse_type(p);
      expr = ast_add(p->ast, (Node){
          .kind = NODE_CAST, .span = span_new(start, node_span(p, cast_type).end),
          .as.cast = {.expression = expr, .type = cast_type},
      });
    } else if (match(p, Question)) {
      expr = ast_add(p->ast, (Node){
          .kind = NODE_UNARY, .span = span_new(start, previous_end(p)), .as.unary = {.op = Question, .operand = expr},
      });
    } else {
      break;
    }
  }
  return expr;
}

static bool unary_operator(TokenType type) {
  return type == Bang || type == Minus || type == Tilde || type == Star || type == Ampersand || type == Move ||
         type == Unsafe;
}

static NodeId parse_unary(Parser *p) {
  if (!unary_operator(peek_type(p)))
    return parse_postfix(p);
  Token op = advance(p);
  NodeId operand = parse_unary(p);
  return ast_add(p->ast, (Node){
      .kind = NODE_UNARY, .span = span_new(token_start(op), node_span(p, operand).end),
      .as.unary = {.op = token_type(op), .operand = operand},
  });
}

static int precedence(TokenType type) {
  switch (type) {
    case Star: case Slash: case Percent: return 11;
    case Plus: case Minus: return 10;
    case LeftShift: case RightShift: return 9;
    case LessThan: case LessThanEqual: case GreaterThan: case GreaterThanEqual: return 8;
    case EqualEqual: case BangEqual: return 7;
    case Ampersand: return 6;
    case Caret: return 5;
    case Pipe: return 4;
    case AmpersandAmpersand: return 3;
    case PipePipe: return 2;
    case QuestionQuestion: return 1;
    default: return 0;
  }
}

static NodeId parse_binary(Parser *p, int minimum) {
  NodeId left = parse_unary(p);
  for (;;) {
    TokenType op = peek_type(p);
    int prec = precedence(op);
    if (prec < minimum)
      break;
    advance(p);
    NodeId right = parse_binary(p, prec + 1);
    left = ast_add(p->ast, (Node){
        .kind = NODE_BINARY, .span = span_new(node_span(p, left).start, node_span(p, right).end),
        .as.binary = {.op = op, .left = left, .right = right},
    });
  }
  return left;
}

static bool assignment_operator(TokenType type) {
  return type == Equal || type == PlusEqual || type == MinusEqual || type == StarEqual || type == SlashEqual ||
         type == PercentEqual || type == AmpersandEqual || type == PipeEqual || type == CaretEqual ||
         type == LeftShiftEqual || type == RightShiftEqual;
}

static NodeId parse_expression(Parser *p) {
  NodeId left = parse_binary(p, 1);
  if (!assignment_operator(peek_type(p)))
    return left;
  TokenType op = token_type(advance(p));
  NodeId right = parse_expression(p);
  return ast_add(p->ast, (Node){
      .kind = NODE_ASSIGNMENT, .span = span_new(node_span(p, left).start, node_span(p, right).end),
      .as.binary = {.op = op, .left = left, .right = right},
  });
}

static NodeId parse_let(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  advance(p);
  bool is_mutable = match(p, Mut);
  NodeId name = identifier(p);
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
  return ast_add(p->ast, (Node){
      .kind = NODE_LET, .span = span_new(start, previous_end(p)),
      .as.let_stmt = {.name = name, .type = type, .value = value, .is_mutable = is_mutable},
  });
}

static NodeId parse_if(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  advance(p);
  expect(p, LeftParen, "'('");
  NodeId condition = parse_expression(p);
  expect(p, RightParen, "')'");
  NodeId then_branch = parse_block(p);
  NodeId else_branch = NODE_NONE;
  if (match(p, Else))
    else_branch = check(p, If) ? parse_if(p) : parse_block(p);
  return ast_add(p->ast, (Node){
      .kind = NODE_IF, .span = span_new(start, node_span(p, else_branch ? else_branch : then_branch).end),
      .as.if_stmt = {.condition = condition, .then_branch = then_branch, .else_branch = else_branch},
  });
}

static NodeId parse_statement(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  switch (peek_type(p)) {
    case LeftBrace: return parse_block(p);
    case Let: return parse_let(p);
    case Const: return parse_const(p);
    case Return: {
      advance(p);
      NodeId value = check(p, Semicolon) ? NODE_NONE : parse_expression(p);
      expect(p, Semicolon, "';'");
      return ast_add(p->ast, (Node){.kind = NODE_RETURN, .span = span_new(start, previous_end(p)), .as.single = {.value = value}});
    }
    case Break: case Continue: {
      NodeKind kind = check(p, Break) ? NODE_BREAK : NODE_CONTINUE;
      advance(p);
      expect(p, Semicolon, "';'");
      return ast_add(p->ast, (Node){.kind = kind, .span = span_new(start, previous_end(p))});
    }
    case Defer: {
      advance(p);
      NodeId value = check(p, LeftBrace) ? parse_block(p) : parse_expression(p);
      if (ast_at_const(p->ast, value)->kind != NODE_BLOCK)
        expect(p, Semicolon, "';'");
      return ast_add(p->ast, (Node){.kind = NODE_DEFER, .span = span_new(start, previous_end(p)), .as.single = {.value = value}});
    }
    case If: return parse_if(p);
    case While: {
      advance(p);
      expect(p, LeftParen, "'('");
      NodeId condition = parse_expression(p);
      expect(p, RightParen, "')'");
      NodeId body = parse_block(p);
      return ast_add(p->ast, (Node){
          .kind = NODE_WHILE, .span = span_new(start, node_span(p, body).end),
          .as.while_stmt = {.condition = condition, .body = body},
      });
    }
    case For: {
      advance(p);
      NodeId binding = identifier(p);
      expect(p, In, "'in'");
      bool old = p->allow_struct_initializer;
      p->allow_struct_initializer = false;
      NodeId iterable = parse_expression(p);
      p->allow_struct_initializer = old;
      NodeId body = parse_block(p);
      return ast_add(p->ast, (Node){
          .kind = NODE_FOR, .span = span_new(start, node_span(p, body).end),
          .as.for_stmt = {.binding = binding, .iterable = iterable, .body = body},
      });
    }
    default: {
      NodeId expression = parse_expression(p);
      expect(p, Semicolon, "';'");
      return ast_add(p->ast, (Node){
          .kind = NODE_EXPRESSION_STATEMENT, .span = span_new(start, previous_end(p)),
          .as.single = {.value = expression},
      });
    }
  }
}

static NodeId parse_block(Parser *p) {
  uint32_t start = token_start(raw_peek(p));
  expect(p, LeftBrace, "'{'");
  uint32_t mark = ast_mark(p->ast);
  while (!check(p, RightBrace) && !at_end(p))
    ast_push(p->ast, parse_statement(p));
  NodeList statements = ast_commit(p->ast, mark);
  expect(p, RightBrace, "'}'");
  return ast_add(p->ast, (Node){
      .kind = NODE_BLOCK, .span = span_new(start, previous_end(p)), .as.block = {.statements = statements},
  });
}

void parser_build_ast(Parser *p) {
  uint32_t mark = ast_mark(p->ast);
  while (!at_end(p)) {
    size_t before = p->current;
    NodeId item = parse_item(p);
    if (item)
      ast_push(p->ast, item);
    if (p->current == before && !at_end(p))
      advance(p);
  }
  NodeList items = ast_commit(p->ast, mark);
  p->ast->root = ast_add(p->ast, (Node){
      .kind = NODE_PROGRAM, .span = span_new(0, (uint32_t)p->len), .as.program = {.items = items},
  });
  errors_finalize(&p->errors, &p->errors_start, &p->errors_len, p->source, p->len);
}

ERRORS_BODY(Parser, parser, p)
