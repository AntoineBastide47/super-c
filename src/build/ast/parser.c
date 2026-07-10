#include "../ast/parser.h"
#include "../stdlib.h"
#include "../string.h"
#include "../lexer/token.h"
#include "../lexer/token_type.h"
#include "../ast/ast.h"
#include "../utils/errors.h"
#include "../__std/core.h"
#include "../__std/interfaces.h"
#include "../__std/map.h"
#include "../__std/option.h"
#include "../__std/range.h"
#include "../__std/result.h"
#include "../__std/slice.h"
#include "../__std/str.h"
#include "../__std/string.h"
#include "../__std/vector.h"

_Static_assert(sizeof(ast__parser__Parser) == 664 && _Alignof(ast__parser__Parser) == 8, "super-c layout model mismatch: ast__parser__Parser");

static __attribute__((unused)) void ast__parser__Parser__skip_attr_args(ast__parser__Parser *const self);

ast__parser__Parser ast__parser__Parser__new(Vector__u64__Global tokens, str const source) {
  const size_t token_count = Vector__u64__Global__len(&tokens);
  return (ast__parser__Parser){ .source = str__ptr(&source), .len = str__len(&source), .tokens = tokens, .current = 0ULL, .pending_gt = 0U, .depth = 0U, .allow_struct_initializer = true, .ast = ast__ast__Ast__new(token_count), .file = NULL, .errors = utils__errors__Errors__new(), .bootstrap_tags = false };
}

void ast__parser__Parser__set_file(ast__parser__Parser *const self, const char *const file) {
  (self->file = file);
}

void ast__parser__Parser__set_bootstrap_tags(ast__parser__Parser *const self, bool const v) {
  (self->bootstrap_tags = v);
}

static __attribute__((unused)) void ast__parser__Parser__skip_attr_args(ast__parser__Parser *const self) {
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
    int32_t depth = 1;
    while ((depth > 0) && (!ast__parser__Parser__at_end(self))) {
      if (ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftParen)) {
        (depth = ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      } else if (ast__parser__Parser__check(self, lexer__token_type__TokenType_RightParen)) {
        (depth = ({ int32_t __sc_r; if (__builtin_sub_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      }
      ast__parser__Parser__advance(self);
    }
  }
}

ast__ast__Ast ast__parser__Parser__take_ast(ast__parser__Parser *const self) {
  ast__ast__Ast out = self->ast;
  (self->ast = ast__ast__Ast__new(0ULL));
  return out;
}

lexer__token__Token ast__parser__Parser__raw_peek(const ast__parser__Parser *const self) {
  return (*({ __auto_type __sc0 = &self->tokens; Vector__u64__Global__index(__sc0, self->current); }));
}

lexer__token_type__TokenType ast__parser__Parser__peek_type(const ast__parser__Parser *const self) {
  if (self->pending_gt != 0U) {
    return lexer__token_type__TokenType_GreaterThan;
  }
  return lexer__token__Token__kind(ast__parser__Parser__raw_peek(self));
}

bool ast__parser__Parser__at_end(const ast__parser__Parser *const self) {
  return (ast__parser__Parser__peek_type(self) == lexer__token_type__TokenType_Eof);
}

lexer__token__Token ast__parser__Parser__advance(ast__parser__Parser *const self) {
  if (self->pending_gt != 0U) {
    (self->pending_gt = (self->pending_gt - 1U));
    const uint64_t source = (*({ __auto_type __sc1 = &self->tokens; Vector__u64__Global__index(__sc1, (self->current - 1ULL)); }));
    return lexer__token__Token__new(lexer__token_type__TokenType_GreaterThan, (lexer__token__Token__end(source) - 1U), 1U);
  }
  const uint64_t t = ast__parser__Parser__raw_peek(self);
  if (lexer__token__Token__kind(t) != lexer__token_type__TokenType_Eof) {
    (self->current = (self->current + 1ULL));
  }
  return t;
}

bool ast__parser__Parser__check(const ast__parser__Parser *const self, lexer__token_type__TokenType const kind) {
  return (ast__parser__Parser__peek_type(self) == kind);
}

bool ast__parser__Parser__text_is(const ast__parser__Parser *const self, lexer__token__Token const t, str const s) {
  const size_t sl = str__len(&s);
  return ((((size_t)lexer__token__Token__len(t)) == sl) && (memcmp((self->source + ((size_t)lexer__token__Token__start(t))), str__ptr(&s), sl) == 0));
}

bool ast__parser__Parser__peek_ident_is(const ast__parser__Parser *const self, str const kw) {
  const uint64_t t = ast__parser__Parser__raw_peek(self);
  if (lexer__token__Token__kind(t) != lexer__token_type__TokenType_Identifier) {
    return false;
  }
  return ast__parser__Parser__text_is(self, t, kw);
}

bool ast__parser__Parser__match(ast__parser__Parser *const self, lexer__token_type__TokenType const kind) {
  if (!ast__parser__Parser__check(self, kind)) {
    return false;
  }
  ast__parser__Parser__advance(self);
  return true;
}

uint32_t ast__parser__Parser__previous_end(const ast__parser__Parser *const self) {
  if (self->pending_gt != 0U) {
    return (lexer__token__Token__end((*({ __auto_type __sc2 = &self->tokens; Vector__u64__Global__index(__sc2, (self->current - 1ULL)); }))) - self->pending_gt);
  }
  if (self->current != 0ULL) {
    return lexer__token__Token__end((*({ __auto_type __sc3 = &self->tokens; Vector__u64__Global__index(__sc3, (self->current - 1ULL)); })));
  }
  return 0U;
}

lexer__token__Span ast__parser__Parser__node_span(const ast__parser__Parser *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return lexer__token__Span__empty();
  }
  return ast__ast__Ast__at_const(&self->ast, id)->span;
}

__attribute__((cold, noinline)) void ast__parser__Parser__error_here(ast__parser__Parser *const self, str const message) {
  const uint64_t t = ast__parser__Parser__raw_peek(self);
  utils__errors__Errors__emit(&self->errors, lexer__token__Token__start(t), lexer__token__Token__len(t), String__Global__from_str(message));
}

bool ast__parser__Parser__expect(ast__parser__Parser *const self, lexer__token_type__TokenType const kind, str const display) {
  if (ast__parser__Parser__match(self, kind)) {
    return true;
  }
  const uint64_t t = ast__parser__Parser__raw_peek(self);
  utils__errors__Errors__emit(&self->errors, lexer__token__Token__start(t), lexer__token__Token__len(t), ({ String__Global __sc4 = String__Global__new();
String__Global__push_str(&__sc4, (str){ .ptr = (const uint8_t*)"expected ", .len = sizeof("expected ") - 1 });
String__Global__push_str(&__sc4, display);
__sc4; }));
  return false;
}

bool ast__parser__Parser__consume_type_gt(ast__parser__Parser *const self) {
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_GreaterThan)) {
    return true;
  }
  if ((self->pending_gt == 0U) && ast__parser__Parser__check(self, lexer__token_type__TokenType_RightShift)) {
    ast__parser__Parser__advance(self);
    (self->pending_gt = 1U);
    return true;
  }
  return ast__parser__Parser__expect(self, lexer__token_type__TokenType_GreaterThan, (str){ (const uint8_t *)"'>'", sizeof("'>'") - 1 });
}

bool ast__parser__Parser__is_type_start(lexer__token_type__TokenType const kind) {
  return ((((((kind == lexer__token_type__TokenType_Identifier) || (kind == lexer__token_type__TokenType_SelfUpper)) || (kind == lexer__token_type__TokenType_Star)) || (kind == lexer__token_type__TokenType_Ampersand)) || (kind == lexer__token_type__TokenType_LeftBracket)) || (kind == lexer__token_type__TokenType_Fn));
}

uint32_t ast__parser__Parser__identifier(ast__parser__Parser *const self) {
  if ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_Identifier)) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_SelfUpper))) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected identifier", sizeof("expected identifier") - 1 });
    if (!ast__parser__Parser__at_end(self)) {
      ast__parser__Parser__advance(self);
    }
    return ast__ast__NODE_NONE;
  }
  const uint64_t token = ast__parser__Parser__advance(self);
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_IDENTIFIER, .span = lexer__token__Token__span(token), .as_data = (ast__ast__NodeAs){ .name = (ast__ast__NameData){ .text = lexer__token__Token__span(token), .is_mutable = false } } });
}

uint32_t ast__parser__Parser__callable_name(ast__parser__Parser *const self) {
  if (((!ast__parser__Parser__check(self, lexer__token_type__TokenType_Identifier)) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_SelfUpper))) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_New))) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected identifier", sizeof("expected identifier") - 1 });
    if (!ast__parser__Parser__at_end(self)) {
      ast__parser__Parser__advance(self);
    }
    return ast__ast__NODE_NONE;
  }
  const uint64_t token = ast__parser__Parser__advance(self);
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_IDENTIFIER, .span = lexer__token__Token__span(token), .as_data = (ast__ast__NodeAs){ .name = (ast__ast__NameData){ .text = lexer__token__Token__span(token), .is_mutable = false } } });
}

uint32_t ast__parser__Parser__literal(ast__parser__Parser *const self) {
  const uint64_t token = ast__parser__Parser__advance(self);
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_LITERAL, .span = lexer__token__Token__span(token), .as_data = (ast__ast__NodeAs){ .literal = (ast__ast__LiteralData){ .raw = lexer__token__Token__span(token), .token_type = lexer__token__Token__kind(token) } } });
}

ast__ast__NodeList ast__parser__Parser__parse_comma_types(ast__parser__Parser *const self, lexer__token_type__TokenType const close) {
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while ((!ast__parser__Parser__check(self, close)) && (!ast__parser__Parser__at_end(self))) {
    const uint32_t ty = ast__parser__Parser__parse_type(self);
    ast__ast__Ast__push(&self->ast, ty);
    if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
      break;
    }
  }
  return ast__ast__Ast__commit(&self->ast, mark);
}

ast__ast__NodeList ast__parser__Parser__parse_type_args(ast__parser__Parser *const self) {
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_LessThan, (str){ (const uint8_t *)"'<'", sizeof("'<'") - 1 });
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while (((!ast__parser__Parser__check(self, lexer__token_type__TokenType_GreaterThan)) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightShift))) && (!ast__parser__Parser__at_end(self))) {
    const uint32_t arg = ({
      uint32_t __sc5;
      if (ast__parser__Parser__check(self, lexer__token_type__TokenType_IntegerLiteral)) {
        __sc5 = ast__parser__Parser__literal(self);
      } else {
        __sc5 = ast__parser__Parser__parse_type(self);
      }
      __sc5;
    });
    ast__ast__Ast__push(&self->ast, arg);
    if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
      break;
    }
  }
  const ast__ast__NodeList args = ast__ast__Ast__commit(&self->ast, mark);
  ast__parser__Parser__consume_type_gt(self);
  return args;
}

uint32_t ast__parser__Parser__parse_type_path_after(ast__parser__Parser *const self, uint32_t const head, uint32_t const start) {
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  ast__ast__Ast__push(&self->ast, head);
  while (ast__parser__Parser__match(self, lexer__token_type__TokenType_PathSeparator)) {
    ast__ast__Ast__push(&self->ast, ast__parser__Parser__identifier(self));
  }
  const ast__ast__NodeList parts = ast__ast__Ast__commit(&self->ast, mark);
  const ast__ast__NodeList args = ({
    ast__ast__NodeList __sc6;
    if (ast__parser__Parser__check(self, lexer__token_type__TokenType_LessThan)) {
      __sc6 = ast__parser__Parser__parse_type_args(self);
    } else {
      __sc6 = (ast__ast__NodeList){ .start = 0U, .len = 0U };
    }
    __sc6;
  });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_TYPE_PATH, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .type_path = (ast__ast__TypePathData){ .parts = parts, .args = args } } });
}

uint32_t ast__parser__Parser__parse_type_path(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  const uint32_t head = ast__parser__Parser__identifier(self);
  return ast__parser__Parser__parse_type_path_after(self, head, start);
}

uint32_t ast__parser__Parser__parse_cast_type(ast__parser__Parser *const self) {
  if ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_Identifier)) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_SelfUpper))) {
    return ast__parser__Parser__parse_type(self);
  }
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  ast__ast__Ast__push(&self->ast, ast__parser__Parser__identifier(self));
  while (ast__parser__Parser__match(self, lexer__token_type__TokenType_PathSeparator)) {
    ast__ast__Ast__push(&self->ast, ast__parser__Parser__identifier(self));
  }
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_TYPE_PATH, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .type_path = (ast__ast__TypePathData){ .parts = ast__ast__Ast__commit(&self->ast, mark), .args = (ast__ast__NodeList){ .start = 0U, .len = 0U } } } });
}

ast__ast__TypeQualifier ast__parser__Parser__parse_qualifier(ast__parser__Parser *const self) {
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Const)) {
    return ast__ast__TypeQualifier_TYPE_QUAL_CONST;
  }
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Mut)) {
    return ast__ast__TypeQualifier_TYPE_QUAL_MUT;
  }
  return ast__ast__TypeQualifier_TYPE_QUAL_NONE;
}

uint32_t ast__parser__Parser__parse_type(ast__parser__Parser *const self) {
  if (self->depth >= ast__parser__PARSE_MAX_DEPTH) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"type nested too deeply", sizeof("type nested too deeply") - 1 });
    if (!ast__parser__Parser__at_end(self)) {
      ast__parser__Parser__advance(self);
    }
    return ast__ast__NODE_NONE;
  }
  (self->depth = (self->depth + 1U));
  const uint32_t t = ast__parser__Parser__parse_type_inner(self);
  (self->depth = (self->depth - 1U));
  return t;
}

uint32_t ast__parser__Parser__parse_type_inner(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Star) || ast__parser__Parser__match(self, lexer__token_type__TokenType_Ampersand)) {
    const lexer__token_type__TokenType opener = lexer__token__Token__kind((*({ __auto_type __sc7 = &self->tokens; Vector__u64__Global__index(__sc7, (self->current - 1ULL)); })));
    ast__ast__TypeQualifier qualifier;
    if (opener == lexer__token_type__TokenType_Star) {
      (qualifier = ast__parser__Parser__parse_qualifier(self));
    } else if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Mut)) {
      (qualifier = ast__ast__TypeQualifier_TYPE_QUAL_MUT);
    } else {
      (qualifier = ast__ast__TypeQualifier_TYPE_QUAL_NONE);
      if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Const)) {
        ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"references use '&T' or '&mut T', not '&const T'", sizeof("references use '&T' or '&mut T', not '&const T'") - 1 });
        ast__parser__Parser__advance(self);
      }
    }
    if ((opener == lexer__token_type__TokenType_Ampersand) && ast__parser__Parser__match(self, lexer__token_type__TokenType_Dyn)) {
      const uint32_t inner = ast__parser__Parser__parse_type(self);
      return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_DYN_TYPE, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, inner).end), .as_data = (ast__ast__NodeAs){ .indirect_type = (ast__ast__IndirectTypeData){ .ty = inner, .qualifier = ({
        ast__ast__TypeQualifier __sc8;
        if (qualifier == ast__ast__TypeQualifier_TYPE_QUAL_MUT) {
          __sc8 = ast__ast__TypeQualifier_TYPE_QUAL_MUT;
        } else {
          __sc8 = ast__ast__TypeQualifier_TYPE_QUAL_CONST;
        }
        __sc8;
      }) } } });
    }
    const uint32_t ty = ast__parser__Parser__parse_type(self);
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ({
      ast__ast__NodeKind __sc9;
      if (opener == lexer__token_type__TokenType_Star) {
        __sc9 = ast__ast__NodeKind_NODE_POINTER_TYPE;
      } else {
        __sc9 = ast__ast__NodeKind_NODE_REFERENCE_TYPE;
      }
      __sc9;
    }), .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, ty).end), .as_data = (ast__ast__NodeAs){ .indirect_type = (ast__ast__IndirectTypeData){ .ty = ty, .qualifier = qualifier } } });
  }
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftBracket)) {
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_RightBracket)) {
      const ast__ast__TypeQualifier qualifier = ({
        ast__ast__TypeQualifier __sc10;
        if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Mut)) {
          __sc10 = ast__ast__TypeQualifier_TYPE_QUAL_MUT;
        } else {
          __sc10 = ast__ast__TypeQualifier_TYPE_QUAL_NONE;
        }
        __sc10;
      });
      const uint32_t element = ast__parser__Parser__parse_type(self);
      return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_SLICE_TYPE, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, element).end), .as_data = (ast__ast__NodeAs){ .indirect_type = (ast__ast__IndirectTypeData){ .ty = element, .qualifier = qualifier } } });
    }
    const uint32_t element = ast__parser__Parser__parse_type(self);
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
    const uint32_t length = ast__parser__Parser__parse_expression(self);
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightBracket, (str){ (const uint8_t *)"']'", sizeof("']'") - 1 });
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_ARRAY_TYPE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .array_type = (ast__ast__ArrayTypeData){ .element = element, .length = length } } });
  }
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Fn)) {
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_LeftParen, (str){ (const uint8_t *)"'('", sizeof("'('") - 1 });
    const ast__ast__NodeList params = ast__parser__Parser__parse_comma_types(self, lexer__token_type__TokenType_RightParen);
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
    const ast__ast__NodeList returns = ast__parser__Parser__parse_function_returns(self);
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_FUNCTION_TYPE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .function_type = (ast__ast__FunctionTypeData){ .params = params, .returns = returns, .is_move = false } } });
  }
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
    const ast__ast__NodeList elems = ast__parser__Parser__parse_comma_types(self, lexer__token_type__TokenType_RightParen);
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
    if (elems.len < 2U) {
      utils__errors__Errors__emit(&self->errors, start, (ast__parser__Parser__previous_end(self) - start), ({ String__Global __sc11 = String__Global__new();
String__Global__push_str(&__sc11, (str){ .ptr = (const uint8_t*)"a tuple type needs at least 2 elements", .len = sizeof("a tuple type needs at least 2 elements") - 1 });
__sc11; }));
    }
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_TUPLE_TYPE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .array_literal = (ast__ast__ArrayLiteralData){ .elements = elems } } });
  }
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Dyn)) {
    const uint32_t inner = ast__parser__Parser__parse_type(self);
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_DYN_TYPE, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, inner).end), .as_data = (ast__ast__NodeAs){ .indirect_type = (ast__ast__IndirectTypeData){ .ty = inner, .qualifier = ast__ast__TypeQualifier_TYPE_QUAL_NONE } } });
  }
  if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Identifier) || ast__parser__Parser__check(self, lexer__token_type__TokenType_SelfUpper)) {
    return ast__parser__Parser__parse_type_path(self);
  }
  ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected type", sizeof("expected type") - 1 });
  if (!ast__parser__Parser__at_end(self)) {
    ast__parser__Parser__advance(self);
  }
  return ast__ast__NODE_NONE;
}

uint32_t ast__parser__Parser__parse_bound(ast__parser__Parser *const self) {
  if (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Fn)) {
    return ast__parser__Parser__parse_type_path(self);
  }
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  const bool is_move = ast__parser__Parser__match(self, lexer__token_type__TokenType_Move);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_LeftParen, (str){ (const uint8_t *)"'('", sizeof("'('") - 1 });
  const ast__ast__NodeList params = ast__parser__Parser__parse_comma_types(self, lexer__token_type__TokenType_RightParen);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
  const ast__ast__NodeList returns = ast__parser__Parser__parse_function_returns(self);
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_FUNCTION_TYPE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .function_type = (ast__ast__FunctionTypeData){ .params = params, .returns = returns, .is_move = is_move } } });
}

ast__ast__NodeList ast__parser__Parser__parse_bounds(ast__parser__Parser *const self) {
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_bound(self));
  while (ast__parser__Parser__match(self, lexer__token_type__TokenType_Plus)) {
    ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_bound(self));
  }
  return ast__ast__Ast__commit(&self->ast, mark);
}

ast__ast__NodeList ast__parser__Parser__parse_generics(ast__parser__Parser *const self) {
  if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_LessThan)) {
    return (ast__ast__NodeList){ .start = 0U, .len = 0U };
  }
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while (((!ast__parser__Parser__check(self, lexer__token_type__TokenType_GreaterThan)) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightShift))) && (!ast__parser__Parser__at_end(self))) {
    const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
    const bool is_const = ast__parser__Parser__match(self, lexer__token_type__TokenType_Const);
    const uint32_t name = ast__parser__Parser__identifier(self);
    ast__ast__NodeList bounds = (ast__ast__NodeList){ .start = 0U, .len = 0U };
    uint32_t const_type = ast__ast__NODE_NONE;
    if (is_const) {
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_Colon, (str){ (const uint8_t *)"':'", sizeof("':'") - 1 });
      (const_type = ast__parser__Parser__parse_type(self));
    } else if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Colon)) {
      (bounds = ast__parser__Parser__parse_bounds(self));
    }
    const uint32_t default_type = ({
      uint32_t __sc12;
      if ((!is_const) && ast__parser__Parser__match(self, lexer__token_type__TokenType_Equal)) {
        __sc12 = ast__parser__Parser__parse_type(self);
      } else {
        __sc12 = ast__ast__NODE_NONE;
      }
      __sc12;
    });
    ast__ast__Ast__push(&self->ast, ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_GENERIC_PARAM, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .generic_param = (ast__ast__GenericParamData){ .name = name, .bounds = bounds, .default_type = default_type, .is_const = is_const, .const_type = const_type } } }));
    if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
      break;
    }
  }
  ast__parser__Parser__consume_type_gt(self);
  return ast__ast__Ast__commit(&self->ast, mark);
}

ast__ast__NodeList ast__parser__Parser__parse_where_clause(ast__parser__Parser *const self) {
  if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Where)) {
    return (ast__ast__NodeList){ .start = 0U, .len = 0U };
  }
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while (true) {
    const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
    const uint32_t ty = ast__parser__Parser__parse_type(self);
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_Colon, (str){ (const uint8_t *)"':'", sizeof("':'") - 1 });
    const ast__ast__NodeList bounds = ast__parser__Parser__parse_bounds(self);
    ast__ast__Ast__push(&self->ast, ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_WHERE_PREDICATE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .where_predicate = (ast__ast__WherePredicateData){ .ty = ty, .bounds = bounds } } }));
    if (((!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) || ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftBrace)) || ast__parser__Parser__check(self, lexer__token_type__TokenType_Semicolon)) {
      break;
    }
  }
  return ast__ast__Ast__commit(&self->ast, mark);
}

uint32_t ast__parser__Parser__parse_parameter_name(ast__parser__Parser *const self) {
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_SelfLower)) {
    const uint64_t token = (*({ __auto_type __sc13 = &self->tokens; Vector__u64__Global__index(__sc13, (self->current - 1ULL)); }));
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_IDENTIFIER, .span = lexer__token__Token__span(token), .as_data = (ast__ast__NodeAs){ .name = (ast__ast__NameData){ .text = lexer__token__Token__span(token), .is_mutable = false } } });
  }
  const bool is_mut = ast__parser__Parser__match(self, lexer__token_type__TokenType_Mut);
  const uint32_t id = ast__parser__Parser__identifier(self);
  if (is_mut && (id != ast__ast__NODE_NONE)) {
    (ast__ast__Ast__at(&self->ast, id)->as_data.name.is_mutable = true);
  }
  return id;
}

ast__ast__NodeList ast__parser__Parser__parse_parameters(ast__parser__Parser *const self, bool *const out_variadic) {
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_LeftParen, (str){ (const uint8_t *)"'('", sizeof("'('") - 1 });
  const uint32_t params_mark = ast__ast__Ast__mark(&self->ast);
  while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightParen)) && (!ast__parser__Parser__at_end(self))) {
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Ellipsis)) {
      ((*out_variadic) = true);
      break;
    }
    const uint32_t names_mark = ast__ast__Ast__mark(&self->ast);
    ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_parameter_name(self));
    while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_Colon)) && (!ast__parser__Parser__at_end(self))) {
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_Comma, (str){ (const uint8_t *)"','", sizeof("','") - 1 });
      if (ast__parser__Parser__check(self, lexer__token_type__TokenType_RightParen)) {
        break;
      }
      ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_parameter_name(self));
    }
    const ast__ast__NodeList names = ast__ast__Ast__commit(&self->ast, names_mark);
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_Colon, (str){ (const uint8_t *)"':'", sizeof("':'") - 1 });
    const uint32_t ty = ast__parser__Parser__parse_type(self);
    for (uint32_t i = 0U; i < names.len; i++) {
      const uint32_t name = (*Vector__u32__Global__at(&self->ast.children, ((size_t)(names.start + i))));
      const uint32_t span_start = ast__parser__Parser__node_span(self, name).start;
      const uint32_t span_end = ast__parser__Parser__node_span(self, ty).end;
      const bool is_mutable = ast__ast__Ast__at_const(&self->ast, name)->as_data.name.is_mutable;
      const uint32_t param = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PARAMETER, .span = lexer__token__Span__new(span_start, span_end), .as_data = (ast__ast__NodeAs){ .parameter = (ast__ast__ParameterData){ .name = name, .ty = ty, .is_mutable = is_mutable } } });
      ast__ast__Ast__push(&self->ast, param);
    }
    if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
      break;
    }
  }
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
  return ast__ast__Ast__commit(&self->ast, params_mark);
}

ast__ast__NodeList ast__parser__Parser__parse_function_returns(ast__parser__Parser *const self) {
  if ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftParen)) && (!ast__parser__Parser__is_type_start(ast__parser__Parser__peek_type(self)))) {
    return (ast__ast__NodeList){ .start = 0U, .len = 0U };
  }
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
    ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_type(self));
    return ast__ast__Ast__commit(&self->ast, mark);
  }
  while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightParen)) && (!ast__parser__Parser__at_end(self))) {
    if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Identifier)) {
      const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
      const uint32_t head = ast__parser__Parser__identifier(self);
      if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Colon)) {
        const uint32_t ty = ast__parser__Parser__parse_type(self);
        ast__ast__Ast__push(&self->ast, ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PARAMETER, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, ty).end), .as_data = (ast__ast__NodeAs){ .parameter = (ast__ast__ParameterData){ .name = head, .ty = ty, .is_mutable = false } } }));
      } else {
        const uint32_t tp = ast__parser__Parser__parse_type_path_after(self, head, start);
        ast__ast__Ast__push(&self->ast, tp);
      }
    } else {
      ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_type(self));
    }
    if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
      break;
    }
  }
  const ast__ast__NodeList returns = ast__ast__Ast__commit(&self->ast, mark);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
  if ((returns.len == 1U) && (ast__ast__Ast__at_const(&self->ast, ast__ast__Ast__list(&self->ast, returns)[0])->kind != ast__ast__NodeKind_NODE_PARAMETER)) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"a single unnamed return type must not be parenthesized", sizeof("a single unnamed return type must not be parenthesized") - 1 });
  }
  return returns;
}

uint32_t ast__parser__Parser__parse_function(ast__parser__Parser *const self, bool const require_body) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Fn, (str){ (const uint8_t *)"'fn'", sizeof("'fn'") - 1 });
  const uint32_t name = ast__parser__Parser__callable_name(self);
  const ast__ast__NodeList generics = ast__parser__Parser__parse_generics(self);
  bool is_variadic = false;
  const ast__ast__NodeList params = ast__parser__Parser__parse_parameters(self, (&is_variadic));
  const ast__ast__NodeList returns = ast__parser__Parser__parse_function_returns(self);
  const ast__ast__NodeList where_clause = ast__parser__Parser__parse_where_clause(self);
  uint32_t body = ast__ast__NODE_NONE;
  if (ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftBrace)) {
    (body = ast__parser__Parser__parse_block(self));
  } else if (require_body) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected function body", sizeof("expected function body") - 1 });
  }
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_FUNCTION, .span = lexer__token__Span__new(start, ({
    uint32_t __sc14;
    if (body != ast__ast__NODE_NONE) {
      __sc14 = ast__parser__Parser__node_span(self, body).end;
    } else {
      __sc14 = ast__parser__Parser__previous_end(self);
    }
    __sc14;
  })), .as_data = (ast__ast__NodeAs){ .function = (ast__ast__FunctionData){ .name = name, .generics = generics, .params = params, .returns = returns, .where_clause = where_clause, .body = body, .is_public = false, .is_extern = false, .is_variadic = is_variadic } } });
}

uint32_t ast__parser__Parser__parse_field(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  const bool is_public = ast__parser__Parser__match(self, lexer__token_type__TokenType_Pub);
  const uint32_t name = ast__parser__Parser__identifier(self);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Colon, (str){ (const uint8_t *)"':'", sizeof("':'") - 1 });
  const uint32_t ty = ast__parser__Parser__parse_type(self);
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_FIELD, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, ty).end), .as_data = (ast__ast__NodeAs){ .field = (ast__ast__FieldData){ .name = name, .ty = ty, .value = ast__ast__NODE_NONE, .is_public = is_public } } });
}

ast__ast__NodeList ast__parser__Parser__parse_fields(ast__parser__Parser *const self) {
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightBrace)) && (!ast__parser__Parser__at_end(self))) {
    ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_field(self));
    if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
      break;
    }
  }
  return ast__ast__Ast__commit(&self->ast, mark);
}

uint32_t ast__parser__Parser__parse_struct(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  const uint32_t name = ast__parser__Parser__identifier(self);
  const ast__ast__NodeList generics = ast__parser__Parser__parse_generics(self);
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Semicolon)) {
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_STRUCT, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .aggregate = (ast__ast__AggregateData){ .name = name, .generics = generics, .members = (ast__ast__NodeList){ .start = 0U, .len = 0U }, .is_public = false, .is_union = false, .is_tuple = false } } });
  }
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
    const ast__ast__NodeList types = ast__parser__Parser__parse_comma_types(self, lexer__token_type__TokenType_RightParen);
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_STRUCT, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .aggregate = (ast__ast__AggregateData){ .name = name, .generics = generics, .members = types, .is_public = false, .is_union = false, .is_tuple = true } } });
  }
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_LeftBrace, (str){ (const uint8_t *)"'{'", sizeof("'{'") - 1 });
  const ast__ast__NodeList fields = ast__parser__Parser__parse_fields(self);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightBrace, (str){ (const uint8_t *)"'}'", sizeof("'}'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_STRUCT, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .aggregate = (ast__ast__AggregateData){ .name = name, .generics = generics, .members = fields, .is_public = false, .is_union = false, .is_tuple = false } } });
}

uint32_t ast__parser__Parser__parse_variant(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  const uint32_t name = ast__parser__Parser__identifier(self);
  ast__ast__NodeList payload = (ast__ast__NodeList){ .start = 0U, .len = 0U };
  bool struct_payload = false;
  uint32_t value = ast__ast__NODE_NONE;
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
    (payload = ast__parser__Parser__parse_comma_types(self, lexer__token_type__TokenType_RightParen));
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
  } else if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftBrace)) {
    (struct_payload = true);
    (payload = ast__parser__Parser__parse_fields(self));
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightBrace, (str){ (const uint8_t *)"'}'", sizeof("'}'") - 1 });
  } else if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Equal)) {
    (value = ast__parser__Parser__parse_expression(self));
  }
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_VARIANT, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .variant = (ast__ast__VariantData){ .name = name, .payload = payload, .struct_payload = struct_payload, .value = value } } });
}

uint32_t ast__parser__Parser__parse_enum(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  const uint32_t name = ast__parser__Parser__identifier(self);
  const ast__ast__NodeList generics = ast__parser__Parser__parse_generics(self);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_LeftBrace, (str){ (const uint8_t *)"'{'", sizeof("'{'") - 1 });
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightBrace)) && (!ast__parser__Parser__at_end(self))) {
    ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_variant(self));
    if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
      break;
    }
  }
  const ast__ast__NodeList variants = ast__ast__Ast__commit(&self->ast, mark);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightBrace, (str){ (const uint8_t *)"'}'", sizeof("'}'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_ENUM, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .aggregate = (ast__ast__AggregateData){ .name = name, .generics = generics, .members = variants, .is_public = false, .is_union = false, .is_tuple = false } } });
}

uint32_t ast__parser__Parser__parse_type_alias(ast__parser__Parser *const self, bool const opaque) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Type, (str){ (const uint8_t *)"'type'", sizeof("'type'") - 1 });
  const uint32_t name = ast__parser__Parser__identifier(self);
  const ast__ast__NodeList generics = ({
    ast__ast__NodeList __sc15;
    if (opaque) {
      __sc15 = (ast__ast__NodeList){ .start = 0U, .len = 0U };
    } else {
      __sc15 = ast__parser__Parser__parse_generics(self);
    }
    __sc15;
  });
  uint32_t ty = ast__ast__NODE_NONE;
  if ((!opaque) || ast__parser__Parser__match(self, lexer__token_type__TokenType_Equal)) {
    if (!opaque) {
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_Equal, (str){ (const uint8_t *)"'='", sizeof("'='") - 1 });
    }
    (ty = ast__parser__Parser__parse_type(self));
  }
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_TYPE_ALIAS, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .type_alias = (ast__ast__TypeAliasData){ .name = name, .generics = generics, .ty = ty, .is_public = false } } });
}

uint32_t ast__parser__Parser__parse_const(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  const uint32_t name = ast__parser__Parser__identifier(self);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Colon, (str){ (const uint8_t *)"':'", sizeof("':'") - 1 });
  const uint32_t ty = ast__parser__Parser__parse_type(self);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Equal, (str){ (const uint8_t *)"'='", sizeof("'='") - 1 });
  const uint32_t value = ast__parser__Parser__parse_expression(self);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_CONST, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .const_def = (ast__ast__ConstData){ .name = name, .ty = ty, .value = value, .is_public = false, .is_extern = false, .is_static_mut = false } } });
}

uint32_t ast__parser__Parser__parse_static(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Mut)) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected 'mut' after 'static' (immutable module-level data is a 'const')", sizeof("expected 'mut' after 'static' (immutable module-level data is a 'const')") - 1 });
  }
  const uint32_t name = ast__parser__Parser__identifier(self);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Colon, (str){ (const uint8_t *)"':'", sizeof("':'") - 1 });
  const uint32_t ty = ast__parser__Parser__parse_type(self);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Equal, (str){ (const uint8_t *)"'='", sizeof("'='") - 1 });
  const uint32_t value = ast__parser__Parser__parse_expression(self);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_CONST, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .const_def = (ast__ast__ConstData){ .name = name, .ty = ty, .value = value, .is_public = false, .is_extern = false, .is_static_mut = true } } });
}

uint32_t ast__parser__Parser__parse_static_assert(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_LeftParen, (str){ (const uint8_t *)"'('", sizeof("'('") - 1 });
  const uint32_t cond = ast__parser__Parser__parse_expression(self);
  uint32_t msg = ast__ast__NODE_NONE;
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
    if (ast__parser__Parser__check(self, lexer__token_type__TokenType_StringLiteral)) {
      (msg = ast__parser__Parser__literal(self));
    } else {
      ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"static_assert message must be a string literal", sizeof("static_assert message must be a string literal") - 1 });
    }
  }
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_STATIC_ASSERT, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .binary = (ast__ast__BinaryData){ .op = lexer__token_type__TokenType_Equal, .left = cond, .right = msg } } });
}

uint32_t ast__parser__Parser__parse_interface(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  const uint32_t name = ast__parser__Parser__identifier(self);
  const ast__ast__NodeList generics = ast__parser__Parser__parse_generics(self);
  const ast__ast__NodeList bounds = ({
    ast__ast__NodeList __sc16;
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Colon)) {
      __sc16 = ast__parser__Parser__parse_bounds(self);
    } else {
      __sc16 = (ast__ast__NodeList){ .start = 0U, .len = 0U };
    }
    __sc16;
  });
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_LeftBrace, (str){ (const uint8_t *)"'{'", sizeof("'{'") - 1 });
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightBrace)) && (!ast__parser__Parser__at_end(self))) {
    if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Fn)) {
      const uint32_t f = ast__parser__Parser__parse_function(self, false);
      if (ast__ast__Ast__at_const(&self->ast, f)->as_data.function.body == ast__ast__NODE_NONE) {
        ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
      }
      ast__ast__Ast__push(&self->ast, f);
    } else if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Type)) {
      const uint32_t ta = ast__parser__Parser__parse_type_alias(self, true);
      ast__ast__Ast__push(&self->ast, ta);
    } else {
      ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected interface item", sizeof("expected interface item") - 1 });
      ast__parser__Parser__advance(self);
    }
  }
  const ast__ast__NodeList items = ast__ast__Ast__commit(&self->ast, mark);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightBrace, (str){ (const uint8_t *)"'}'", sizeof("'}'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_INTERFACE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .interface_def = (ast__ast__InterfaceData){ .name = name, .generics = generics, .bounds = bounds, .items = items, .is_public = false } } });
}

uint32_t ast__parser__Parser__parse_extend(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  const ast__ast__NodeList generics = ast__parser__Parser__parse_generics(self);
  const uint32_t target = ast__parser__Parser__parse_type(self);
  const uint32_t interface_type = ({
    uint32_t __sc17;
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_As)) {
      __sc17 = ast__parser__Parser__parse_type(self);
    } else {
      __sc17 = ast__ast__NODE_NONE;
    }
    __sc17;
  });
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_LeftBrace, (str){ (const uint8_t *)"'{'", sizeof("'{'") - 1 });
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightBrace)) && (!ast__parser__Parser__at_end(self))) {
    Vector__ast__ast__Attr__Global attrs = ast__parser__Parser__parse_attributes(self, 16ULL);
    const bool is_public = ast__parser__Parser__match(self, lexer__token_type__TokenType_Pub);
    if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Fn)) {
      const uint32_t f = ast__parser__Parser__parse_function(self, true);
      (ast__ast__Ast__at(&self->ast, f)->as_data.function.is_public = is_public);
      ast__parser__Parser__add_attrs_to(self, (&attrs), f);
      ast__ast__Ast__push(&self->ast, f);
    } else if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Type) && (!is_public)) {
      const uint32_t ta = ast__parser__Parser__parse_type_alias(self, false);
      ast__ast__Ast__push(&self->ast, ta);
    } else if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Const)) {
      const uint32_t cn = ast__parser__Parser__parse_const(self);
      (ast__ast__Ast__at(&self->ast, cn)->as_data.const_def.is_public = is_public);
      ast__ast__Ast__push(&self->ast, cn);
    } else {
      ast__parser__Parser__error_here(self, ({
        str __sc18;
        if (is_public) {
          __sc18 = (str){ (const uint8_t *)"'pub' may only be applied to a function or const here", sizeof("'pub' may only be applied to a function or const here") - 1 };
        } else {
          __sc18 = (str){ (const uint8_t *)"expected extension item", sizeof("expected extension item") - 1 };
        }
        __sc18;
      }));
      ast__parser__Parser__advance(self);
    }
    Vector__ast__ast__Attr__Global__free(&attrs);
  }
  const ast__ast__NodeList items = ast__ast__Ast__commit(&self->ast, mark);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightBrace, (str){ (const uint8_t *)"'}'", sizeof("'}'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_EXTEND, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .extend_def = (ast__ast__ExtendData){ .generics = generics, .interface_type = interface_type, .target_type = target, .items = items } } });
}

uint32_t ast__parser__Parser__parse_extern(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  const uint32_t abi = ({
    uint32_t __sc19;
    if (ast__parser__Parser__check(self, lexer__token_type__TokenType_StringLiteral)) {
      __sc19 = ast__parser__Parser__literal(self);
    } else {
      __sc19 = ast__ast__NODE_NONE;
    }
    __sc19;
  });
  if (abi == ast__ast__NODE_NONE) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected ABI string", sizeof("expected ABI string") - 1 });
  }
  const uint32_t header = ({
    uint32_t __sc20;
    if (ast__parser__Parser__check(self, lexer__token_type__TokenType_StringLiteral)) {
      __sc20 = ast__parser__Parser__literal(self);
    } else {
      __sc20 = ast__ast__NODE_NONE;
    }
    __sc20;
  });
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_LeftBrace, (str){ (const uint8_t *)"'{'", sizeof("'{'") - 1 });
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightBrace)) && (!ast__parser__Parser__at_end(self))) {
    Vector__ast__ast__Attr__Global attrs = ast__parser__Parser__parse_attributes(self, 16ULL);
    const bool is_public = ast__parser__Parser__match(self, lexer__token_type__TokenType_Pub);
    if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Fn)) {
      const uint32_t f = ast__parser__Parser__parse_function(self, false);
      if (ast__ast__Ast__at_const(&self->ast, f)->as_data.function.body != ast__ast__NODE_NONE) {
        const lexer__token__Span sp = ast__parser__Parser__node_span(self, f);
        utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc21 = String__Global__new();
String__Global__push_str(&__sc21, (str){ .ptr = (const uint8_t*)"extern function declarations cannot have a body", .len = sizeof("extern function declarations cannot have a body") - 1 });
__sc21; }));
      }
      (ast__ast__Ast__at(&self->ast, f)->as_data.function.is_public = is_public);
      (ast__ast__Ast__at(&self->ast, f)->as_data.function.is_extern = true);
      ast__parser__Parser__add_attrs_to(self, (&attrs), f);
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
      ast__ast__Ast__push(&self->ast, f);
    } else if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Type)) {
      const uint32_t ta = ast__parser__Parser__parse_type_alias(self, true);
      (ast__ast__Ast__at(&self->ast, ta)->as_data.type_alias.is_public = is_public);
      ast__ast__Ast__push(&self->ast, ta);
    } else if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Const)) {
      const uint32_t cstart = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
      ast__parser__Parser__advance(self);
      const uint32_t cname = ast__parser__Parser__identifier(self);
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_Colon, (str){ (const uint8_t *)"':'", sizeof("':'") - 1 });
      const uint32_t ctype = ast__parser__Parser__parse_type(self);
      if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Equal)) {
        ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"extern const declarations cannot have an initializer", sizeof("extern const declarations cannot have an initializer") - 1 });
      }
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
      const uint32_t cnode = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_CONST, .span = lexer__token__Span__new(cstart, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .const_def = (ast__ast__ConstData){ .name = cname, .ty = ctype, .value = ast__ast__NODE_NONE, .is_public = is_public, .is_extern = true, .is_static_mut = false } } });
      ast__parser__Parser__add_attrs_to(self, (&attrs), cnode);
      ast__ast__Ast__push(&self->ast, cnode);
    } else {
      ast__parser__Parser__error_here(self, ({
        str __sc22;
        if (is_public) {
          __sc22 = (str){ (const uint8_t *)"'pub' may only be applied to an extern function, type, or const", sizeof("'pub' may only be applied to an extern function, type, or const") - 1 };
        } else {
          __sc22 = (str){ (const uint8_t *)"expected extern item", sizeof("expected extern item") - 1 };
        }
        __sc22;
      }));
      ast__parser__Parser__advance(self);
    }
    Vector__ast__ast__Attr__Global__free(&attrs);
  }
  const ast__ast__NodeList items = ast__ast__Ast__commit(&self->ast, mark);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightBrace, (str){ (const uint8_t *)"'}'", sizeof("'}'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_EXTERN_BLOCK, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .extern_block = (ast__ast__ExternBlockData){ .abi = abi, .header = header, .items = items } } });
}

uint32_t ast__parser__Parser__parse_item(ast__parser__Parser *const self) {
  Vector__ast__ast__Attr__Global attrs = ast__parser__Parser__parse_attributes(self, 16ULL);
  if (ast__parser__Parser__peek_ident_is(self, (str){ (const uint8_t *)"static_assert", sizeof("static_assert") - 1 })) {
    const uint32_t id = ast__parser__Parser__parse_static_assert(self);
    {
      __auto_type __sc23 = id;
      Vector__ast__ast__Attr__Global__free(&attrs);
      return __sc23;
    }
  }
  const bool is_public = ast__parser__Parser__match(self, lexer__token_type__TokenType_Pub);
  if (ast__parser__Parser__peek_ident_is(self, (str){ (const uint8_t *)"static", sizeof("static") - 1 })) {
    const uint32_t sid = ast__parser__Parser__parse_static(self);
    if (sid != ast__ast__NODE_NONE) {
      (ast__ast__Ast__at(&self->ast, sid)->as_data.const_def.is_public = is_public);
    }
    ast__parser__Parser__add_attrs_to(self, (&attrs), sid);
    {
      __auto_type __sc24 = sid;
      Vector__ast__ast__Attr__Global__free(&attrs);
      return __sc24;
    }
  }
  if (((((((is_public && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Fn))) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Struct))) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Union))) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Enum))) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Const))) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Type))) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Interface))) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"'pub' may only be applied to a struct, union, enum, function, const, static, interface, or type", sizeof("'pub' may only be applied to a struct, union, enum, function, const, static, interface, or type") - 1 });
  }
  uint32_t id = ast__ast__NODE_NONE;
  {
    const lexer__token_type__TokenType __sc25 = ast__parser__Parser__peek_type(self);
    if (__sc25 == lexer__token_type__TokenType_Fn) {
      {
        (id = ast__parser__Parser__parse_function(self, true));
        (ast__ast__Ast__at(&self->ast, id)->as_data.function.is_public = is_public);
      }
    }
    else if (__sc25 == lexer__token_type__TokenType_Struct) {
      {
        (id = ast__parser__Parser__parse_struct(self));
        (ast__ast__Ast__at(&self->ast, id)->as_data.aggregate.is_public = is_public);
      }
    }
    else if (__sc25 == lexer__token_type__TokenType_Union) {
      {
        (id = ast__parser__Parser__parse_struct(self));
        (ast__ast__Ast__at(&self->ast, id)->as_data.aggregate.is_public = is_public);
        (ast__ast__Ast__at(&self->ast, id)->as_data.aggregate.is_union = true);
      }
    }
    else if (__sc25 == lexer__token_type__TokenType_Enum) {
      {
        (id = ast__parser__Parser__parse_enum(self));
        (ast__ast__Ast__at(&self->ast, id)->as_data.aggregate.is_public = is_public);
      }
    }
    else if (__sc25 == lexer__token_type__TokenType_Interface) {
      {
        (id = ast__parser__Parser__parse_interface(self));
        (ast__ast__Ast__at(&self->ast, id)->as_data.interface_def.is_public = is_public);
      }
    }
    else if (__sc25 == lexer__token_type__TokenType_Extend) {
      {
        (id = ast__parser__Parser__parse_extend(self));
      }
    }
    else if (__sc25 == lexer__token_type__TokenType_Type) {
      {
        (id = ast__parser__Parser__parse_type_alias(self, false));
        (ast__ast__Ast__at(&self->ast, id)->as_data.type_alias.is_public = is_public);
      }
    }
    else if (__sc25 == lexer__token_type__TokenType_Const) {
      {
        (id = ast__parser__Parser__parse_const(self));
        (ast__ast__Ast__at(&self->ast, id)->as_data.const_def.is_public = is_public);
      }
    }
    else if (__sc25 == lexer__token_type__TokenType_Extern) {
      {
        (id = ast__parser__Parser__parse_extern(self));
      }
    }
    else if (__sc25 == lexer__token_type__TokenType_Import) {
      {
        (id = ast__parser__Parser__parse_import(self));
      }
    }
    else if (1) {
      {
        ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected top-level item", sizeof("expected top-level item") - 1 });
        while ((!ast__parser__Parser__at_end(self)) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Semicolon))) {
          ast__parser__Parser__advance(self);
        }
        ast__parser__Parser__match(self, lexer__token_type__TokenType_Semicolon);
        {
          __auto_type __sc26 = ast__ast__NODE_NONE;
          Vector__ast__ast__Attr__Global__free(&attrs);
          return __sc26;
        }
      }
    }
  }
  ast__parser__Parser__validate_item_attrs(self, (&attrs), id);
  ast__parser__Parser__add_attrs_to(self, (&attrs), id);
  {
    __auto_type __sc27 = id;
    Vector__ast__ast__Attr__Global__free(&attrs);
    return __sc27;
  }
}

ast__ast__NodeList ast__parser__Parser__parse_arguments(ast__parser__Parser *const self) {
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightParen)) && (!ast__parser__Parser__at_end(self))) {
    ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_expression(self));
    if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
      break;
    }
  }
  return ast__ast__Ast__commit(&self->ast, mark);
}

uint32_t ast__parser__Parser__parse_struct_initializer_after(ast__parser__Parser *const self, uint32_t const ty, uint32_t const start) {
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_LeftBrace, (str){ (const uint8_t *)"'{'", sizeof("'{'") - 1 });
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightBrace)) && (!ast__parser__Parser__at_end(self))) {
    const uint32_t field_start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
    const uint32_t name = ast__parser__Parser__identifier(self);
    uint32_t value = name;
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Colon)) {
      (value = ast__parser__Parser__parse_expression(self));
    }
    ast__ast__Ast__push(&self->ast, ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_FIELD_INITIALIZER, .span = lexer__token__Span__new(field_start, ast__parser__Parser__node_span(self, value).end), .as_data = (ast__ast__NodeAs){ .field_initializer = (ast__ast__FieldInitializerData){ .name = name, .value = value } } }));
    if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
      break;
    }
  }
  const ast__ast__NodeList fields = ast__ast__Ast__commit(&self->ast, mark);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightBrace, (str){ (const uint8_t *)"'}'", sizeof("'}'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_STRUCT_INITIALIZER, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .struct_initializer = (ast__ast__StructInitializerData){ .ty = ty, .fields = fields } } });
}

uint32_t ast__parser__Parser__parse_pattern_alts(ast__parser__Parser *const self, uint32_t const arm_start) {
  uint32_t pattern = ast__parser__Parser__parse_pattern(self);
  if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Pipe)) {
    const uint32_t alt_mark = ast__ast__Ast__mark(&self->ast);
    ast__ast__Ast__push(&self->ast, pattern);
    while (ast__parser__Parser__match(self, lexer__token_type__TokenType_Pipe)) {
      ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_pattern(self));
    }
    const ast__ast__NodeList alts = ast__ast__Ast__commit(&self->ast, alt_mark);
    (pattern = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PATTERN_OR, .span = lexer__token__Span__new(arm_start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .pattern = (ast__ast__PatternData){ .name = ast__ast__NODE_NONE, .children = alts } } }));
  }
  return pattern;
}

uint32_t ast__parser__Parser__parse_switch(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  const bool old = self->allow_struct_initializer;
  (self->allow_struct_initializer = false);
  const uint32_t value = ast__parser__Parser__parse_expression(self);
  (self->allow_struct_initializer = old);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_LeftBrace, (str){ (const uint8_t *)"'{'", sizeof("'{'") - 1 });
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightBrace)) && (!ast__parser__Parser__at_end(self))) {
    const uint32_t arm_start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
    ast__parser__Parser__match(self, lexer__token_type__TokenType_Case);
    const uint32_t pattern = ast__parser__Parser__parse_pattern_alts(self, arm_start);
    const uint32_t guard = ({
      uint32_t __sc28;
      if (ast__parser__Parser__match(self, lexer__token_type__TokenType_If)) {
        __sc28 = ast__parser__Parser__parse_expression(self);
      } else {
        __sc28 = ast__ast__NODE_NONE;
      }
      __sc28;
    });
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_FatArrow, (str){ (const uint8_t *)"'=>'", sizeof("'=>'") - 1 });
    const uint32_t body = ({
      uint32_t __sc29;
      if (ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftBrace)) {
        __sc29 = ast__parser__Parser__parse_block(self);
      } else {
        __sc29 = ast__parser__Parser__parse_expression(self);
      }
      __sc29;
    });
    ast__ast__Ast__push(&self->ast, ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_MATCH_ARM, .span = lexer__token__Span__new(arm_start, ast__parser__Parser__node_span(self, body).end), .as_data = (ast__ast__NodeAs){ .match_arm = (ast__ast__MatchArmData){ .pattern = pattern, .guard = guard, .body = body } } }));
    if ((!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightBrace))) {
      ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected ',' or '}' after switch arm", sizeof("expected ',' or '}' after switch arm") - 1 });
    }
  }
  const ast__ast__NodeList arms = ast__ast__Ast__commit(&self->ast, mark);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightBrace, (str){ (const uint8_t *)"'}'", sizeof("'}'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_MATCH, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .match_expr = (ast__ast__MatchData){ .value = value, .arms = arms } } });
}

uint32_t ast__parser__Parser__parse_pattern_atom(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Minus)) {
    if (!ast__parser__Parser__is_literal_token(ast__parser__Parser__peek_type(self))) {
      ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected literal", sizeof("expected literal") - 1 });
      if (!ast__parser__Parser__at_end(self)) {
        ast__parser__Parser__advance(self);
      }
      return ast__ast__NODE_NONE;
    }
    const uint32_t value = ast__parser__Parser__literal(self);
    const uint32_t neg = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_UNARY, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, value).end), .as_data = (ast__ast__NodeAs){ .unary = (ast__ast__UnaryData){ .op = lexer__token_type__TokenType_Minus, .operand = value, .qualifier = ast__ast__TypeQualifier_TYPE_QUAL_NONE } } });
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PATTERN_LITERAL, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, value).end), .as_data = (ast__ast__NodeAs){ .single = (ast__ast__SingleData){ .value = neg } } });
  }
  if (ast__parser__Parser__is_literal_token(ast__parser__Parser__peek_type(self))) {
    const uint32_t value = ast__parser__Parser__literal(self);
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PATTERN_LITERAL, .span = ast__parser__Parser__node_span(self, value), .as_data = (ast__ast__NodeAs){ .single = (ast__ast__SingleData){ .value = value } } });
  }
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
    const uint32_t inner = ast__parser__Parser__parse_pattern(self);
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
    const uint32_t mark = ast__ast__Ast__mark(&self->ast);
    ast__ast__Ast__push(&self->ast, inner);
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PATTERN_TUPLE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .pattern = (ast__ast__PatternData){ .name = ast__ast__NODE_NONE, .children = ast__ast__Ast__commit(&self->ast, mark) } } });
  }
  if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Mut) || ast__parser__Parser__check(self, lexer__token_type__TokenType_Identifier)) {
    const bool is_mut = ast__parser__Parser__match(self, lexer__token_type__TokenType_Mut);
    const uint32_t name = ast__parser__Parser__identifier(self);
    if (name == ast__ast__NODE_NONE) {
      return ast__ast__NODE_NONE;
    }
    if (is_mut) {
      (ast__ast__Ast__at(&self->ast, name)->as_data.name.is_mutable = true);
    }
    const lexer__token__Span text = ast__ast__Ast__at_const(&self->ast, name)->as_data.name.text;
    if (((text.end - text.start) == 1U) && (self->source[((size_t)text.start)] == 95U)) {
      return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PATTERN_WILDCARD, .span = ast__parser__Parser__node_span(self, name) });
    }
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
      const uint32_t mark = ast__ast__Ast__mark(&self->ast);
      while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightParen)) && (!ast__parser__Parser__at_end(self))) {
        if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Range)) {
          const uint64_t rt = ast__parser__Parser__advance(self);
          ast__ast__Ast__push(&self->ast, ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PATTERN_WILDCARD, .span = lexer__token__Token__span(rt) }));
          break;
        }
        ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_pattern(self));
        if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
          break;
        }
      }
      const ast__ast__NodeList children = ast__ast__Ast__commit(&self->ast, mark);
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
      return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PATTERN_TUPLE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .pattern = (ast__ast__PatternData){ .name = name, .children = children } } });
    }
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftBrace)) {
      const uint32_t mark = ast__ast__Ast__mark(&self->ast);
      while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightBrace)) && (!ast__parser__Parser__at_end(self))) {
        if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Range)) {
          break;
        }
        const uint32_t field_start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
        const uint32_t field_name = ast__parser__Parser__identifier(self);
        uint32_t child = field_name;
        if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Colon)) {
          (child = ast__parser__Parser__parse_pattern(self));
        }
        const uint32_t child_mark = ast__ast__Ast__mark(&self->ast);
        ast__ast__Ast__push(&self->ast, child);
        ast__ast__Ast__push(&self->ast, ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PATTERN_FIELD, .span = lexer__token__Span__new(field_start, ast__parser__Parser__node_span(self, child).end), .as_data = (ast__ast__NodeAs){ .pattern = (ast__ast__PatternData){ .name = field_name, .children = ast__ast__Ast__commit(&self->ast, child_mark) } } }));
        if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
          break;
        }
      }
      const ast__ast__NodeList children = ast__ast__Ast__commit(&self->ast, mark);
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightBrace, (str){ (const uint8_t *)"'}'", sizeof("'}'") - 1 });
      return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PATTERN_STRUCT, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .pattern = (ast__ast__PatternData){ .name = name, .children = children } } });
    }
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_At)) {
      const uint32_t sub = ast__parser__Parser__parse_pattern(self);
      const uint32_t submark = ast__ast__Ast__mark(&self->ast);
      ast__ast__Ast__push(&self->ast, sub);
      return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PATTERN_NAME, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .pattern = (ast__ast__PatternData){ .name = name, .children = ast__ast__Ast__commit(&self->ast, submark) } } });
    }
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PATTERN_NAME, .span = ast__parser__Parser__node_span(self, name), .as_data = (ast__ast__NodeAs){ .pattern = (ast__ast__PatternData){ .name = name, .children = (ast__ast__NodeList){ .start = 0U, .len = 0U } } } });
  }
  ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected pattern", sizeof("expected pattern") - 1 });
  if (!ast__parser__Parser__at_end(self)) {
    ast__parser__Parser__advance(self);
  }
  return ast__ast__NODE_NONE;
}

uint32_t ast__parser__Parser__parse_pattern(ast__parser__Parser *const self) {
  return ast__parser__Parser__parse_range(self, ast__parser__RangeContext_RANGE_PATTERN);
}

uint32_t ast__parser__Parser__parse_array_element(ast__parser__Parser *const self) {
  if (!ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftBracket)) {
    return ast__parser__Parser__parse_expression(self);
  }
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  const uint32_t group = ast__parser__Parser__parse_array_literal(self);
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Equal)) {
    const ast__ast__NodeList elements = ast__ast__Ast__at_const(&self->ast, group)->as_data.array_literal.elements;
    uint32_t index = ({
      uint32_t __sc30;
      if (elements.len == 1U) {
        __sc30 = ast__ast__Ast__list(&self->ast, elements)[0];
      } else {
        __sc30 = ast__ast__NODE_NONE;
      }
      __sc30;
    });
    if ((index != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&self->ast, index)->kind == ast__ast__NodeKind_NODE_FIELD_INITIALIZER)) {
      (index = ast__ast__NODE_NONE);
    }
    if (index == ast__ast__NODE_NONE) {
      utils__errors__Errors__emit(&self->errors, start, (ast__parser__Parser__previous_end(self) - start), ({ String__Global __sc31 = String__Global__new();
String__Global__push_str(&__sc31, (str){ .ptr = (const uint8_t*)"a designated element needs a single index expression", .len = sizeof("a designated element needs a single index expression") - 1 });
__sc31; }));
    }
    const uint32_t value = ast__parser__Parser__parse_expression(self);
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_FIELD_INITIALIZER, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, value).end), .as_data = (ast__ast__NodeAs){ .field_initializer = (ast__ast__FieldInitializerData){ .name = index, .value = value } } });
  }
  const uint32_t p = ast__parser__Parser__parse_postfix_after(self, group);
  const uint32_t b = ast__parser__Parser__parse_binary_after(self, p, 1);
  return ast__parser__Parser__parse_expression_after(self, b);
}

uint32_t ast__parser__Parser__parse_array_literal(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightBracket)) && (!ast__parser__Parser__at_end(self))) {
    ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_array_element(self));
    if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
      break;
    }
  }
  const ast__ast__NodeList elements = ast__ast__Ast__commit(&self->ast, mark);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightBracket, (str){ (const uint8_t *)"']'", sizeof("']'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_ARRAY_LITERAL, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .array_literal = (ast__ast__ArrayLiteralData){ .elements = elements } } });
}

uint32_t ast__parser__Parser__parse_primary(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  const lexer__token_type__TokenType kind = ast__parser__Parser__peek_type(self);
  if (ast__parser__Parser__is_literal_token(kind)) {
    return ast__parser__Parser__literal(self);
  }
  if (kind == lexer__token_type__TokenType_SelfLower) {
    const uint64_t token = ast__parser__Parser__advance(self);
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_IDENTIFIER, .span = lexer__token__Token__span(token), .as_data = (ast__ast__NodeAs){ .name = (ast__ast__NameData){ .text = lexer__token__Token__span(token), .is_mutable = false } } });
  }
  if (kind == lexer__token_type__TokenType_Identifier) {
    const int32_t va = ({
      int32_t __sc32;
      if (ast__parser__Parser__peek_ident_is(self, (str){ (const uint8_t *)"va_start", sizeof("va_start") - 1 })) {
        __sc32 = 0;
      } else if (ast__parser__Parser__peek_ident_is(self, (str){ (const uint8_t *)"va_arg", sizeof("va_arg") - 1 })) {
        __sc32 = 1;
      } else if (ast__parser__Parser__peek_ident_is(self, (str){ (const uint8_t *)"va_end", sizeof("va_end") - 1 })) {
        __sc32 = 2;
      } else {
        __sc32 = -1;
      }
      __sc32;
    });
    const uint32_t value = ast__parser__Parser__identifier(self);
    if ((va >= 0) && ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
      const uint32_t ap = ast__parser__Parser__parse_expression(self);
      uint32_t extra = ast__ast__NODE_NONE;
      if (va == 1) {
        ast__parser__Parser__expect(self, lexer__token_type__TokenType_Comma, (str){ (const uint8_t *)"','", sizeof("','") - 1 });
        (extra = ast__parser__Parser__parse_type(self));
      } else if (va == 0) {
        ast__parser__Parser__expect(self, lexer__token_type__TokenType_Comma, (str){ (const uint8_t *)"','", sizeof("','") - 1 });
        (extra = ast__parser__Parser__parse_expression(self));
      }
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
      return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_VA_EXPR, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .va_op = (ast__ast__VaOpData){ .op = ((uint8_t)va), .ap = ap, .extra = extra } } });
    }
    if (self->allow_struct_initializer && ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftBrace)) {
      return ast__parser__Parser__parse_struct_initializer_after(self, value, start);
    }
    return value;
  }
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
    const bool old = self->allow_struct_initializer;
    (self->allow_struct_initializer = true);
    const uint32_t value = ast__parser__Parser__parse_expression(self);
    if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Comma)) {
      const uint32_t mark = ast__ast__Ast__mark(&self->ast);
      ast__ast__Ast__push(&self->ast, value);
      while ((ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightParen))) && (!ast__parser__Parser__at_end(self))) {
        ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_expression(self));
      }
      const ast__ast__NodeList elems = ast__ast__Ast__commit(&self->ast, mark);
      (self->allow_struct_initializer = old);
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
      return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_TUPLE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .array_literal = (ast__ast__ArrayLiteralData){ .elements = elems } } });
    }
    (self->allow_struct_initializer = old);
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
    return value;
  }
  if (kind == lexer__token_type__TokenType_Switch) {
    return ast__parser__Parser__parse_switch(self);
  }
  if (kind == lexer__token_type__TokenType_If) {
    return ast__parser__Parser__parse_if(self);
  }
  if (kind == lexer__token_type__TokenType_Loop) {
    ast__parser__Parser__advance(self);
    const uint32_t body = ast__parser__Parser__parse_block(self);
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_WHILE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .while_stmt = (ast__ast__WhileData){ .condition = ast__ast__NODE_NONE, .body = body, .is_do = false, .label = lexer__token__Span__empty() } } });
  }
  if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Sizeof) || ast__parser__Parser__check(self, lexer__token_type__TokenType_Alignof)) {
    const bool is_align = ast__parser__Parser__check(self, lexer__token_type__TokenType_Alignof);
    ast__parser__Parser__advance(self);
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_LeftParen, (str){ (const uint8_t *)"'('", sizeof("'('") - 1 });
    const uint32_t ty = ast__parser__Parser__parse_type(self);
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ({
      ast__ast__NodeKind __sc33;
      if (is_align) {
        __sc33 = ast__ast__NodeKind_NODE_ALIGNOF;
      } else {
        __sc33 = ast__ast__NodeKind_NODE_SIZEOF;
      }
      __sc33;
    }), .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .single = (ast__ast__SingleData){ .value = ty } } });
  }
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_New)) {
    const uint32_t new_type = ast__parser__Parser__parse_type(self);
    uint32_t initializer = ast__ast__NODE_NONE;
    if (ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftBrace)) {
      (initializer = ast__parser__Parser__parse_struct_initializer_after(self, new_type, ast__parser__Parser__node_span(self, new_type).start));
    } else if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
      (initializer = ast__parser__Parser__parse_expression(self));
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
    }
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_NEW, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .new_expr = (ast__ast__NewData){ .ty = new_type, .initializer = initializer } } });
  }
  if (ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftBracket)) {
    return ast__parser__Parser__parse_array_literal(self);
  }
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Fn)) {
    bool variadic = false;
    const ast__ast__NodeList params = ast__parser__Parser__parse_parameters(self, (&variadic));
    if (variadic) {
      ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"anonymous functions cannot be variadic", sizeof("anonymous functions cannot be variadic") - 1 });
    }
    const ast__ast__NodeList returns = ast__parser__Parser__parse_function_returns(self);
    const uint32_t body = ast__parser__Parser__parse_block(self);
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_CLOSURE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .closure = (ast__ast__ClosureData){ .params = params, .returns = returns, .body = body, .expr_body = false, .captures = (ast__ast__NodeList){ .start = 0U, .len = 0U }, .mut_caps = 0U } } });
  }
  if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Pipe) || ast__parser__Parser__check(self, lexer__token_type__TokenType_PipePipe)) {
    const bool empty = ast__parser__Parser__match(self, lexer__token_type__TokenType_PipePipe);
    if (!empty) {
      ast__parser__Parser__advance(self);
    }
    const uint32_t mark = ast__ast__Ast__mark(&self->ast);
    if (!empty) {
      while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_Pipe)) && (!ast__parser__Parser__at_end(self))) {
        const uint32_t pstart = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
        const uint32_t name = ast__parser__Parser__identifier(self);
        uint32_t ty = ast__ast__NODE_NONE;
        if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Colon)) {
          (ty = ast__parser__Parser__parse_type(self));
        }
        ast__ast__Ast__push(&self->ast, ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PARAMETER, .span = lexer__token__Span__new(pstart, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .parameter = (ast__ast__ParameterData){ .name = name, .ty = ty, .is_mutable = false } } }));
        if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
          break;
        }
      }
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_Pipe, (str){ (const uint8_t *)"'|'", sizeof("'|'") - 1 });
    }
    const ast__ast__NodeList params = ast__ast__Ast__commit(&self->ast, mark);
    if (ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftBrace)) {
      const uint32_t block = ast__parser__Parser__parse_block(self);
      return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_CLOSURE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .closure = (ast__ast__ClosureData){ .params = params, .returns = (ast__ast__NodeList){ .start = 0U, .len = 0U }, .body = block, .expr_body = false, .captures = (ast__ast__NodeList){ .start = 0U, .len = 0U }, .mut_caps = 0U } } });
    }
    const uint32_t body = ast__parser__Parser__parse_expression(self);
    return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_CLOSURE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .closure = (ast__ast__ClosureData){ .params = params, .returns = (ast__ast__NodeList){ .start = 0U, .len = 0U }, .body = body, .expr_body = true, .captures = (ast__ast__NodeList){ .start = 0U, .len = 0U }, .mut_caps = 0U } } });
  }
  ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected expression", sizeof("expected expression") - 1 });
  if (!ast__parser__Parser__at_end(self)) {
    ast__parser__Parser__advance(self);
  }
  return ast__ast__NODE_NONE;
}

uint32_t ast__parser__Parser__path_chain_to_type_path(ast__parser__Parser *const self, uint32_t const chain, uint32_t const start) {
  uint32_t segs[16] = { 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U };
  uint32_t n = 0U;
  uint32_t cur = chain;
  while (true) {
    const ast__ast__Node *const cn = ast__ast__Ast__at_const(&self->ast, cur);
    if (n < 16U) {
      (segs[__sc_bounds(n, 16)] = cn->as_data.member.member);
      (n = (n + 1U));
    }
    const uint32_t o = cn->as_data.member.object;
    if (ast__ast__Ast__at_const(&self->ast, o)->kind != ast__ast__NodeKind_NODE_MEMBER) {
      if (n < 16U) {
        (segs[__sc_bounds(n, 16)] = o);
        (n = (n + 1U));
      }
      break;
    }
    (cur = o);
  }
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while (n > 0U) {
    (n = (n - 1U));
    ast__ast__Ast__push(&self->ast, segs[__sc_bounds(n, 16)]);
  }
  const ast__ast__NodeList parts = ast__ast__Ast__commit(&self->ast, mark);
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_TYPE_PATH, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .type_path = (ast__ast__TypePathData){ .parts = parts, .args = (ast__ast__NodeList){ .start = 0U, .len = 0U } } } });
}

uint32_t ast__parser__Parser__parse_postfix_after(ast__parser__Parser *const self, uint32_t expr) {
  while (true) {
    const uint32_t start = ast__parser__Parser__node_span(self, expr).start;
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
      const ast__ast__NodeList args = ast__parser__Parser__parse_arguments(self);
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
      (expr = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_CALL, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .call = (ast__ast__CallData){ .callee = expr, .args = args } } }));
    } else if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftBracket)) {
      const uint32_t index = ast__parser__Parser__parse_range(self, ast__parser__RangeContext_RANGE_EXPR);
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightBracket, (str){ (const uint8_t *)"']'", sizeof("']'") - 1 });
      (expr = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_INDEX, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .index = (ast__ast__IndexData){ .object = expr, .index = index } } }));
    } else if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Dot) || ast__parser__Parser__check(self, lexer__token_type__TokenType_Arrow)) {
      const bool pointer = ast__parser__Parser__match(self, lexer__token_type__TokenType_Arrow);
      if (!pointer) {
        ast__parser__Parser__advance(self);
      }
      const uint32_t member = ({
        uint32_t __sc34;
        if (ast__parser__Parser__check(self, lexer__token_type__TokenType_IntegerLiteral)) {
          const uint64_t tok = ast__parser__Parser__advance(self);
          __sc34 = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_IDENTIFIER, .span = lexer__token__Token__span(tok), .as_data = (ast__ast__NodeAs){ .name = (ast__ast__NameData){ .text = lexer__token__Token__span(tok), .is_mutable = false } } });
        } else if (ast__parser__Parser__check(self, lexer__token_type__TokenType_FloatLiteral)) {
          ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"nested tuple access needs parentheses: write '(t.0).1'", sizeof("nested tuple access needs parentheses: write '(t.0).1'") - 1 });
          ast__parser__Parser__advance(self);
          __sc34 = ast__ast__NODE_NONE;
        } else {
          __sc34 = ast__parser__Parser__callable_name(self);
        }
        __sc34;
      });
      (expr = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_MEMBER, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, member).end), .as_data = (ast__ast__NodeAs){ .member = (ast__ast__MemberData){ .object = expr, .member = member, .pointer = pointer, .path = false } } }));
    } else if (ast__parser__Parser__match(self, lexer__token_type__TokenType_PathSeparator)) {
      if (ast__parser__Parser__check(self, lexer__token_type__TokenType_LessThan)) {
        const ast__ast__NodeList types = ast__parser__Parser__parse_type_args(self);
        const uint32_t inner = expr;
        (expr = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_GENERIC_SPECIALIZATION, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .specialization = (ast__ast__SpecializationData){ .expression = inner, .types = types } } }));
        if (self->allow_struct_initializer && ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftBrace)) {
          uint32_t tp;
          if (ast__ast__Ast__at_const(&self->ast, inner)->kind == ast__ast__NodeKind_NODE_MEMBER) {
            (tp = ast__parser__Parser__path_chain_to_type_path(self, inner, start));
          } else {
            const uint32_t mark = ast__ast__Ast__mark(&self->ast);
            ast__ast__Ast__push(&self->ast, inner);
            (tp = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_TYPE_PATH, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .type_path = (ast__ast__TypePathData){ .parts = ast__ast__Ast__commit(&self->ast, mark), .args = (ast__ast__NodeList){ .start = 0U, .len = 0U } } } }));
          }
          (ast__ast__Ast__at(&self->ast, tp)->as_data.type_path.args = types);
          return ast__parser__Parser__parse_struct_initializer_after(self, tp, start);
        }
      } else {
        const uint32_t member = ast__parser__Parser__callable_name(self);
        (expr = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_MEMBER, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, member).end), .as_data = (ast__ast__NodeAs){ .member = (ast__ast__MemberData){ .object = expr, .member = member, .pointer = false, .path = true } } }));
        if (self->allow_struct_initializer && ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftBrace)) {
          const uint32_t tp = ast__parser__Parser__path_chain_to_type_path(self, expr, start);
          return ast__parser__Parser__parse_struct_initializer_after(self, tp, start);
        }
      }
    } else if (ast__parser__Parser__match(self, lexer__token_type__TokenType_As)) {
      const uint32_t cast_type = ast__parser__Parser__parse_cast_type(self);
      (expr = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_CAST, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, cast_type).end), .as_data = (ast__ast__NodeAs){ .cast = (ast__ast__CastData){ .expression = expr, .ty = cast_type } } }));
    } else if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Question)) {
      (expr = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_UNARY, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .unary = (ast__ast__UnaryData){ .op = lexer__token_type__TokenType_Question, .operand = expr, .qualifier = ast__ast__TypeQualifier_TYPE_QUAL_NONE } } }));
    } else {
      break;
    }
  }
  return expr;
}

uint32_t ast__parser__Parser__parse_postfix(ast__parser__Parser *const self) {
  return ast__parser__Parser__parse_postfix_after(self, ast__parser__Parser__parse_primary(self));
}

uint32_t ast__parser__Parser__parse_unary(ast__parser__Parser *const self) {
  if (self->depth >= ast__parser__PARSE_MAX_DEPTH) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expression nested too deeply", sizeof("expression nested too deeply") - 1 });
    return ast__ast__NODE_NONE;
  }
  (self->depth = (self->depth + 1U));
  const uint32_t result = ({
    uint32_t __sc35;
    if (!ast__parser__Parser__unary_operator(ast__parser__Parser__peek_type(self))) {
      __sc35 = ast__parser__Parser__parse_postfix(self);
    } else {
      const uint64_t op = ast__parser__Parser__advance(self);
      const ast__ast__TypeQualifier qualifier = ({
        ast__ast__TypeQualifier __sc36;
        if ((lexer__token__Token__kind(op) == lexer__token_type__TokenType_Ampersand) && ast__parser__Parser__match(self, lexer__token_type__TokenType_Mut)) {
          __sc36 = ast__ast__TypeQualifier_TYPE_QUAL_MUT;
        } else {
          __sc36 = ast__ast__TypeQualifier_TYPE_QUAL_NONE;
        }
        __sc36;
      });
      const uint32_t operand = ({
        uint32_t __sc37;
        if ((lexer__token__Token__kind(op) == lexer__token_type__TokenType_Unsafe) && ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftBrace)) {
          __sc37 = ast__parser__Parser__parse_block(self);
        } else {
          __sc37 = ast__parser__Parser__parse_unary(self);
        }
        __sc37;
      });
      __sc35 = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_UNARY, .span = lexer__token__Span__new(lexer__token__Token__start(op), ast__parser__Parser__node_span(self, operand).end), .as_data = (ast__ast__NodeAs){ .unary = (ast__ast__UnaryData){ .op = lexer__token__Token__kind(op), .operand = operand, .qualifier = qualifier } } });
    }
    __sc35;
  });
  (self->depth = (self->depth - 1U));
  return result;
}

uint32_t ast__parser__Parser__parse_binary_after(ast__parser__Parser *const self, uint32_t left, int32_t const minimum) {
  uint32_t chain = 0U;
  while (true) {
    const lexer__token_type__TokenType op = ast__parser__Parser__peek_type(self);
    const int32_t prec = ast__parser__Parser__precedence(op);
    if (prec < minimum) {
      break;
    }
    (chain = (chain + 1U));
    if (chain > 4096U) {
      ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expression nested too deeply", sizeof("expression nested too deeply") - 1 });
      return left;
    }
    ast__parser__Parser__advance(self);
    const uint32_t right = ast__parser__Parser__parse_binary(self, ({ int32_t __sc_r; if (__builtin_add_overflow(prec, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    (left = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_BINARY, .span = lexer__token__Span__new(ast__parser__Parser__node_span(self, left).start, ast__parser__Parser__node_span(self, right).end), .as_data = (ast__ast__NodeAs){ .binary = (ast__ast__BinaryData){ .op = op, .left = left, .right = right } } }));
  }
  return left;
}

uint32_t ast__parser__Parser__parse_binary(ast__parser__Parser *const self, int32_t const minimum) {
  return ast__parser__Parser__parse_binary_after(self, ast__parser__Parser__parse_unary(self), minimum);
}

uint32_t ast__parser__Parser__parse_expression_after(ast__parser__Parser *const self, uint32_t const left) {
  if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Range) || ast__parser__Parser__check(self, lexer__token_type__TokenType_RangeInclusive)) {
    return ast__parser__Parser__parse_range_value(self, left);
  }
  if (!ast__parser__Parser__assignment_operator(ast__parser__Parser__peek_type(self))) {
    return left;
  }
  if (self->depth >= ast__parser__PARSE_MAX_DEPTH) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expression nested too deeply", sizeof("expression nested too deeply") - 1 });
    return left;
  }
  (self->depth = (self->depth + 1U));
  const lexer__token_type__TokenType op = lexer__token__Token__kind(ast__parser__Parser__advance(self));
  const uint32_t right = ast__parser__Parser__parse_expression(self);
  (self->depth = (self->depth - 1U));
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_ASSIGNMENT, .span = lexer__token__Span__new(ast__parser__Parser__node_span(self, left).start, ast__parser__Parser__node_span(self, right).end), .as_data = (ast__ast__NodeAs){ .binary = (ast__ast__BinaryData){ .op = op, .left = left, .right = right } } });
}

uint32_t ast__parser__Parser__parse_expression(ast__parser__Parser *const self) {
  if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Range) || ast__parser__Parser__check(self, lexer__token_type__TokenType_RangeInclusive)) {
    return ast__parser__Parser__parse_range_value(self, ast__ast__NODE_NONE);
  }
  return ast__parser__Parser__parse_expression_after(self, ast__parser__Parser__parse_binary(self, 1));
}

uint32_t ast__parser__Parser__parse_range_bound(ast__parser__Parser *const self, ast__parser__RangeContext const context) {
  if (context == ast__parser__RangeContext_RANGE_PATTERN) {
    return ast__parser__Parser__parse_pattern_atom(self);
  }
  return ast__parser__Parser__parse_expression(self);
}

bool ast__parser__Parser__starts_range_bound(const ast__parser__Parser *const self, ast__parser__RangeContext const context) {
  const lexer__token_type__TokenType t = ast__parser__Parser__peek_type(self);
  if (context == ast__parser__RangeContext_RANGE_PATTERN) {
    return (((ast__parser__Parser__is_literal_token(t) || (t == lexer__token_type__TokenType_Identifier)) || (t == lexer__token_type__TokenType_LeftParen)) || (t == lexer__token_type__TokenType_Minus));
  }
  return ((((((((ast__parser__Parser__is_literal_token(t) || (t == lexer__token_type__TokenType_Identifier)) || (t == lexer__token_type__TokenType_LeftParen)) || (t == lexer__token_type__TokenType_SelfLower)) || (t == lexer__token_type__TokenType_New)) || (t == lexer__token_type__TokenType_Switch)) || (t == lexer__token_type__TokenType_Sizeof)) || (t == lexer__token_type__TokenType_Alignof)) || ast__parser__Parser__unary_operator(t));
}

uint32_t ast__parser__Parser__parse_range(ast__parser__Parser *const self, ast__parser__RangeContext const context) {
  const bool open_start = (ast__parser__Parser__check(self, lexer__token_type__TokenType_Range) || ast__parser__Parser__check(self, lexer__token_type__TokenType_RangeInclusive));
  const uint32_t start_node = ({
    uint32_t __sc38;
    if (open_start) {
      __sc38 = ast__ast__NODE_NONE;
    } else {
      __sc38 = ast__parser__Parser__parse_range_bound(self, context);
    }
    __sc38;
  });
  if ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_Range)) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_RangeInclusive))) {
    return start_node;
  }
  const uint32_t op_start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  const bool inclusive = (lexer__token__Token__kind(ast__parser__Parser__advance(self)) == lexer__token_type__TokenType_RangeInclusive);
  const uint32_t end = ({
    uint32_t __sc39;
    if (ast__parser__Parser__starts_range_bound(self, context)) {
      __sc39 = ast__parser__Parser__parse_range_bound(self, context);
    } else {
      __sc39 = ast__ast__NODE_NONE;
    }
    __sc39;
  });
  if ((start_node == ast__ast__NODE_NONE) && (end == ast__ast__NODE_NONE)) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"a range needs a start and/or an end", sizeof("a range needs a start and/or an end") - 1 });
  } else if (inclusive && (end == ast__ast__NODE_NONE)) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"an inclusive range '..=' needs an end", sizeof("an inclusive range '..=' needs an end") - 1 });
  }
  const uint32_t lo = ({
    uint32_t __sc40;
    if (start_node != ast__ast__NODE_NONE) {
      __sc40 = ast__parser__Parser__node_span(self, start_node).start;
    } else {
      __sc40 = op_start;
    }
    __sc40;
  });
  const uint32_t hi = ({
    uint32_t __sc41;
    if (end != ast__ast__NODE_NONE) {
      __sc41 = ast__parser__Parser__node_span(self, end).end;
    } else {
      __sc41 = ast__parser__Parser__previous_end(self);
    }
    __sc41;
  });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ({
    ast__ast__NodeKind __sc42;
    if (context == ast__parser__RangeContext_RANGE_PATTERN) {
      __sc42 = ast__ast__NodeKind_NODE_PATTERN_RANGE;
    } else {
      __sc42 = ast__ast__NodeKind_NODE_RANGE;
    }
    __sc42;
  }), .span = lexer__token__Span__new(lo, hi), .as_data = (ast__ast__NodeAs){ .pattern_range = (ast__ast__PatternRangeData){ .start = start_node, .end = end, .inclusive = inclusive } } });
}

uint32_t ast__parser__Parser__parse_range_value(ast__parser__Parser *const self, uint32_t const start_node) {
  const uint32_t op_start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  const bool inclusive = (lexer__token__Token__kind(ast__parser__Parser__advance(self)) == lexer__token_type__TokenType_RangeInclusive);
  const uint32_t end = ({
    uint32_t __sc43;
    if (ast__parser__Parser__starts_range_bound(self, ast__parser__RangeContext_RANGE_EXPR)) {
      __sc43 = ast__parser__Parser__parse_binary(self, 1);
    } else {
      __sc43 = ast__ast__NODE_NONE;
    }
    __sc43;
  });
  if ((start_node == ast__ast__NODE_NONE) && (end == ast__ast__NODE_NONE)) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"a range needs a start and/or an end", sizeof("a range needs a start and/or an end") - 1 });
  } else if (inclusive && (end == ast__ast__NODE_NONE)) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"an inclusive range '..=' needs an end", sizeof("an inclusive range '..=' needs an end") - 1 });
  }
  const uint32_t lo = ({
    uint32_t __sc44;
    if (start_node != ast__ast__NODE_NONE) {
      __sc44 = ast__parser__Parser__node_span(self, start_node).start;
    } else {
      __sc44 = op_start;
    }
    __sc44;
  });
  const uint32_t hi = ({
    uint32_t __sc45;
    if (end != ast__ast__NODE_NONE) {
      __sc45 = ast__parser__Parser__node_span(self, end).end;
    } else {
      __sc45 = ast__parser__Parser__previous_end(self);
    }
    __sc45;
  });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_RANGE, .span = lexer__token__Span__new(lo, hi), .as_data = (ast__ast__NodeAs){ .pattern_range = (ast__ast__PatternRangeData){ .start = start_node, .end = end, .inclusive = inclusive } } });
}

uint32_t ast__parser__Parser__parse_let(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  const bool is_mutable = ast__parser__Parser__match(self, lexer__token_type__TokenType_Mut);
  const uint32_t name = ({
    uint32_t __sc46;
    if (ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftParen)) {
      const uint32_t tstart = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
      ast__parser__Parser__advance(self);
      const uint32_t mark = ast__ast__Ast__mark(&self->ast);
      while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightParen)) && (!ast__parser__Parser__at_end(self))) {
        ast__ast__Ast__push(&self->ast, ast__parser__Parser__identifier(self));
        if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
          break;
        }
      }
      const ast__ast__NodeList children = ast__ast__Ast__commit(&self->ast, mark);
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
      __sc46 = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PATTERN_TUPLE, .span = lexer__token__Span__new(tstart, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .pattern = (ast__ast__PatternData){ .name = ast__ast__NODE_NONE, .children = children } } });
    } else {
      __sc46 = ast__parser__Parser__identifier(self);
    }
    __sc46;
  });
  uint32_t ty = ast__ast__NODE_NONE;
  uint32_t value = ast__ast__NODE_NONE;
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Colon)) {
    (ty = ast__parser__Parser__parse_type(self));
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Equal)) {
      (value = ast__parser__Parser__parse_expression(self));
    }
  } else if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Equal)) {
    (value = ast__parser__Parser__parse_expression(self));
  } else {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected type annotation or initializer", sizeof("expected type annotation or initializer") - 1 });
  }
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_LET, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .let_stmt = (ast__ast__LetData){ .name = name, .ty = ty, .value = value, .is_mutable = is_mutable } } });
}

uint32_t ast__parser__Parser__desugar_let_match(ast__parser__Parser *const self, uint32_t const start, uint32_t const pattern, uint32_t const value, uint32_t const then_block, uint32_t else_branch) {
  const uint32_t end = ast__parser__Parser__previous_end(self);
  if (else_branch == ast__ast__NODE_NONE) {
    (else_branch = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_BLOCK, .span = lexer__token__Span__new(end, end), .as_data = (ast__ast__NodeAs){ .block = (ast__ast__BlockData){ .statements = (ast__ast__NodeList){ .start = 0U, .len = 0U } } } }));
  }
  const uint32_t wild = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PATTERN_WILDCARD, .span = lexer__token__Span__new(start, start) });
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  ast__ast__Ast__push(&self->ast, ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_MATCH_ARM, .span = ast__parser__Parser__node_span(self, then_block), .as_data = (ast__ast__NodeAs){ .match_arm = (ast__ast__MatchArmData){ .pattern = pattern, .guard = ast__ast__NODE_NONE, .body = then_block } } }));
  ast__ast__Ast__push(&self->ast, ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_MATCH_ARM, .span = ast__parser__Parser__node_span(self, else_branch), .as_data = (ast__ast__NodeAs){ .match_arm = (ast__ast__MatchArmData){ .pattern = wild, .guard = ast__ast__NODE_NONE, .body = else_branch } } }));
  const ast__ast__NodeList arms = ast__ast__Ast__commit(&self->ast, mark);
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_MATCH, .span = lexer__token__Span__new(start, end), .as_data = (ast__ast__NodeAs){ .match_expr = (ast__ast__MatchData){ .value = value, .arms = arms } } });
}

uint32_t ast__parser__Parser__parse_if(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Let)) {
    ast__parser__Parser__advance(self);
    const uint32_t pattern = ast__parser__Parser__parse_pattern_alts(self, start);
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_Equal, (str){ (const uint8_t *)"'='", sizeof("'='") - 1 });
    const bool old = self->allow_struct_initializer;
    (self->allow_struct_initializer = false);
    const uint32_t value = ast__parser__Parser__parse_expression(self);
    (self->allow_struct_initializer = old);
    const uint32_t then_branch = ast__parser__Parser__parse_block(self);
    uint32_t else_branch = ast__ast__NODE_NONE;
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Else)) {
      if (ast__parser__Parser__check(self, lexer__token_type__TokenType_If)) {
        (else_branch = ast__parser__Parser__parse_if(self));
      } else {
        (else_branch = ast__parser__Parser__parse_block(self));
      }
    }
    return ast__parser__Parser__desugar_let_match(self, start, pattern, value, then_branch, else_branch);
  }
  const bool old = self->allow_struct_initializer;
  (self->allow_struct_initializer = false);
  const uint32_t condition = ast__parser__Parser__parse_expression(self);
  (self->allow_struct_initializer = old);
  const uint32_t then_branch = ast__parser__Parser__parse_block(self);
  uint32_t else_branch = ast__ast__NODE_NONE;
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Else)) {
    if (ast__parser__Parser__check(self, lexer__token_type__TokenType_If)) {
      (else_branch = ast__parser__Parser__parse_if(self));
    } else {
      (else_branch = ast__parser__Parser__parse_block(self));
    }
  }
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_IF, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, ({
    uint32_t __sc47;
    if (else_branch != ast__ast__NODE_NONE) {
      __sc47 = else_branch;
    } else {
      __sc47 = then_branch;
    }
    __sc47;
  })).end), .as_data = (ast__ast__NodeAs){ .if_stmt = (ast__ast__IfData){ .condition = condition, .then_branch = then_branch, .else_branch = else_branch } } });
}

uint32_t ast__parser__Parser__parse_loop_stmt(ast__parser__Parser *const self, uint32_t const start, lexer__token__Span const label) {
  uint32_t result = ast__ast__NODE_NONE;
  {
    const lexer__token_type__TokenType __sc48 = ast__parser__Parser__peek_type(self);
    if (__sc48 == lexer__token_type__TokenType_While) {
      {
        ast__parser__Parser__advance(self);
        if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Let)) {
          ast__parser__Parser__advance(self);
          const uint32_t pattern = ast__parser__Parser__parse_pattern_alts(self, start);
          ast__parser__Parser__expect(self, lexer__token_type__TokenType_Equal, (str){ (const uint8_t *)"'='", sizeof("'='") - 1 });
          const bool old = self->allow_struct_initializer;
          (self->allow_struct_initializer = false);
          const uint32_t value = ast__parser__Parser__parse_expression(self);
          (self->allow_struct_initializer = old);
          const uint32_t body = ast__parser__Parser__parse_block(self);
          const uint32_t end = ast__parser__Parser__previous_end(self);
          const uint32_t brk = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_BREAK, .span = lexer__token__Span__new(end, end) });
          const uint32_t bmark = ast__ast__Ast__mark(&self->ast);
          ast__ast__Ast__push(&self->ast, brk);
          const uint32_t brk_block = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_BLOCK, .span = lexer__token__Span__new(end, end), .as_data = (ast__ast__NodeAs){ .block = (ast__ast__BlockData){ .statements = ast__ast__Ast__commit(&self->ast, bmark) } } });
          const uint32_t m = ast__parser__Parser__desugar_let_match(self, start, pattern, value, body, brk_block);
          const uint32_t ms = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT, .span = ast__parser__Parser__node_span(self, m), .as_data = (ast__ast__NodeAs){ .single = (ast__ast__SingleData){ .value = m } } });
          const uint32_t lmark = ast__ast__Ast__mark(&self->ast);
          ast__ast__Ast__push(&self->ast, ms);
          const uint32_t lbody = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_BLOCK, .span = lexer__token__Span__new(start, end), .as_data = (ast__ast__NodeAs){ .block = (ast__ast__BlockData){ .statements = ast__ast__Ast__commit(&self->ast, lmark) } } });
          (result = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_WHILE, .span = lexer__token__Span__new(start, end), .as_data = (ast__ast__NodeAs){ .while_stmt = (ast__ast__WhileData){ .condition = ast__ast__NODE_NONE, .body = lbody, .is_do = false, .label = label } } }));
        } else {
          const bool old = self->allow_struct_initializer;
          (self->allow_struct_initializer = false);
          const uint32_t condition = ast__parser__Parser__parse_expression(self);
          (self->allow_struct_initializer = old);
          const uint32_t body = ast__parser__Parser__parse_block(self);
          (result = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_WHILE, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, body).end), .as_data = (ast__ast__NodeAs){ .while_stmt = (ast__ast__WhileData){ .condition = condition, .body = body, .is_do = false, .label = label } } }));
        }
      }
    }
    else if (__sc48 == lexer__token_type__TokenType_Do) {
      {
        ast__parser__Parser__advance(self);
        const uint32_t body = ast__parser__Parser__parse_block(self);
        ast__parser__Parser__expect(self, lexer__token_type__TokenType_While, (str){ (const uint8_t *)"'while'", sizeof("'while'") - 1 });
        const bool old = self->allow_struct_initializer;
        (self->allow_struct_initializer = false);
        const uint32_t condition = ast__parser__Parser__parse_expression(self);
        (self->allow_struct_initializer = old);
        ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
        (result = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_WHILE, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .while_stmt = (ast__ast__WhileData){ .condition = condition, .body = body, .is_do = true, .label = label } } }));
      }
    }
    else if (__sc48 == lexer__token_type__TokenType_For) {
      {
        ast__parser__Parser__advance(self);
        const uint32_t binding = ast__parser__Parser__identifier(self);
        ast__parser__Parser__expect(self, lexer__token_type__TokenType_In, (str){ (const uint8_t *)"'in'", sizeof("'in'") - 1 });
        const bool old = self->allow_struct_initializer;
        (self->allow_struct_initializer = false);
        const uint32_t iterable = ast__parser__Parser__parse_range(self, ast__parser__RangeContext_RANGE_FOR);
        (self->allow_struct_initializer = old);
        const uint32_t body = ast__parser__Parser__parse_block(self);
        (result = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_FOR, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, body).end), .as_data = (ast__ast__NodeAs){ .for_stmt = (ast__ast__ForData){ .binding = binding, .iterable = iterable, .body = body, .label = label } } }));
      }
    }
    else if (1) {
      {
        ast__parser__Parser__advance(self);
        const uint32_t body = ast__parser__Parser__parse_block(self);
        (result = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_WHILE, .span = lexer__token__Span__new(start, ast__parser__Parser__node_span(self, body).end), .as_data = (ast__ast__NodeAs){ .while_stmt = (ast__ast__WhileData){ .condition = ast__ast__NODE_NONE, .body = body, .is_do = false, .label = label } } }));
      }
    }
  }
  return result;
}

uint32_t ast__parser__Parser__parse_statement(ast__parser__Parser *const self) {
  if (self->depth >= ast__parser__PARSE_MAX_DEPTH) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"statement nested too deeply", sizeof("statement nested too deeply") - 1 });
    if (!ast__parser__Parser__at_end(self)) {
      ast__parser__Parser__advance(self);
    }
    return ast__ast__NODE_NONE;
  }
  (self->depth = (self->depth + 1U));
  const uint32_t s = ast__parser__Parser__parse_statement_inner(self);
  (self->depth = (self->depth - 1U));
  return s;
}

uint32_t ast__parser__Parser__parse_statement_inner(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  if (ast__parser__Parser__peek_ident_is(self, (str){ (const uint8_t *)"static_assert", sizeof("static_assert") - 1 })) {
    return ast__parser__Parser__parse_static_assert(self);
  }
  uint32_t result = ast__ast__NODE_NONE;
  {
    const lexer__token_type__TokenType __sc49 = ast__parser__Parser__peek_type(self);
    if (__sc49 == lexer__token_type__TokenType_LeftBrace) {
      {
        (result = ast__parser__Parser__parse_block(self));
      }
    }
    else if (__sc49 == lexer__token_type__TokenType_Let) {
      {
        (result = ast__parser__Parser__parse_let(self));
      }
    }
    else if (__sc49 == lexer__token_type__TokenType_Const) {
      {
        (result = ast__parser__Parser__parse_const(self));
      }
    }
    else if (__sc49 == lexer__token_type__TokenType_Return) {
      {
        ast__parser__Parser__advance(self);
        const uint32_t mark = ast__ast__Ast__mark(&self->ast);
        if (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Semicolon)) {
          while (true) {
            ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_expression(self));
            if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Comma)) {
              break;
            }
          }
        }
        const ast__ast__NodeList values = ast__ast__Ast__commit(&self->ast, mark);
        ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
        (result = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_RETURN, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .return_stmt = (ast__ast__ReturnData){ .values = values } } }));
      }
    }
    else if ((__sc49 == lexer__token_type__TokenType_Break) || (__sc49 == lexer__token_type__TokenType_Continue)) {
      {
        const ast__ast__NodeKind kind = ({
          ast__ast__NodeKind __sc50;
          if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Break)) {
            __sc50 = ast__ast__NodeKind_NODE_BREAK;
          } else {
            __sc50 = ast__ast__NodeKind_NODE_CONTINUE;
          }
          __sc50;
        });
        ast__parser__Parser__advance(self);
        lexer__token__Span label = lexer__token__Span__empty();
        if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Label)) {
          const uint64_t lt = ast__parser__Parser__raw_peek(self);
          (label = lexer__token__Token__span(lt));
          ast__parser__Parser__advance(self);
        }
        uint32_t value = ast__ast__NODE_NONE;
        if ((kind == ast__ast__NodeKind_NODE_BREAK) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Semicolon))) {
          (value = ast__parser__Parser__parse_expression(self));
        }
        ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
        (result = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = kind, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .flow = (ast__ast__FlowData){ .value = value, .label = label } } }));
      }
    }
    else if (__sc49 == lexer__token_type__TokenType_Defer) {
      {
        ast__parser__Parser__advance(self);
        const uint32_t value = ({
          uint32_t __sc51;
          if (ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftBrace)) {
            __sc51 = ast__parser__Parser__parse_block(self);
          } else {
            __sc51 = ast__parser__Parser__parse_expression(self);
          }
          __sc51;
        });
        if (ast__ast__Ast__at_const(&self->ast, value)->kind != ast__ast__NodeKind_NODE_BLOCK) {
          ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
        }
        (result = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_DEFER, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .single = (ast__ast__SingleData){ .value = value } } }));
      }
    }
    else if (__sc49 == lexer__token_type__TokenType_If) {
      {
        const uint32_t f = ast__parser__Parser__parse_if(self);
        if ((f != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&self->ast, f)->kind == ast__ast__NodeKind_NODE_MATCH)) {
          (result = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT, .span = ast__parser__Parser__node_span(self, f), .as_data = (ast__ast__NodeAs){ .single = (ast__ast__SingleData){ .value = f } } }));
        } else {
          (result = f);
        }
      }
    }
    else if (__sc49 == lexer__token_type__TokenType_Label) {
      {
        const lexer__token__Span label = lexer__token__Token__span(ast__parser__Parser__raw_peek(self));
        ast__parser__Parser__advance(self);
        ast__parser__Parser__expect(self, lexer__token_type__TokenType_Colon, (str){ (const uint8_t *)"':'", sizeof("':'") - 1 });
        if ((((!ast__parser__Parser__check(self, lexer__token_type__TokenType_While)) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Do))) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_For))) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Loop))) {
          ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"a label must be followed by 'loop', 'while', 'do', or 'for'", sizeof("a label must be followed by 'loop', 'while', 'do', or 'for'") - 1 });
          (result = ast__ast__NODE_NONE);
        } else {
          (result = ast__parser__Parser__parse_loop_stmt(self, start, label));
        }
      }
    }
    else if ((__sc49 == lexer__token_type__TokenType_While) || (__sc49 == lexer__token_type__TokenType_Do) || (__sc49 == lexer__token_type__TokenType_For) || (__sc49 == lexer__token_type__TokenType_Loop)) {
      {
        (result = ast__parser__Parser__parse_loop_stmt(self, start, lexer__token__Span__empty()));
      }
    }
    else if (__sc49 == lexer__token_type__TokenType_Unsafe) {
      {
        const uint32_t expression = ast__parser__Parser__parse_expression(self);
        const ast__ast__Node *const node = ast__ast__Ast__at_const(&self->ast, expression);
        const bool block = (((node->kind == ast__ast__NodeKind_NODE_UNARY) && (node->as_data.unary.op == lexer__token_type__TokenType_Unsafe)) && (ast__ast__Ast__at_const(&self->ast, node->as_data.unary.operand)->kind == ast__ast__NodeKind_NODE_BLOCK));
        if (!block) {
          ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
        }
        (result = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .single = (ast__ast__SingleData){ .value = expression } } }));
      }
    }
    else if (1) {
      {
        const uint32_t expression = ast__parser__Parser__parse_expression(self);
        ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
        (result = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .single = (ast__ast__SingleData){ .value = expression } } }));
      }
    }
  }
  return result;
}

uint32_t ast__parser__Parser__parse_block(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_LeftBrace, (str){ (const uint8_t *)"'{'", sizeof("'{'") - 1 });
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightBrace)) && (!ast__parser__Parser__at_end(self))) {
    ast__ast__Ast__push(&self->ast, ast__parser__Parser__parse_statement(self));
  }
  const ast__ast__NodeList statements = ast__ast__Ast__commit(&self->ast, mark);
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightBrace, (str){ (const uint8_t *)"'}'", sizeof("'}'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_BLOCK, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .block = (ast__ast__BlockData){ .statements = statements } } });
}

int32_t ast__parser__Parser__attr_kind_of(const ast__parser__Parser *const self, lexer__token__Token const name, bool *const wants_str, bool *const wants_int) {
  ((*wants_str) = false);
  ((*wants_int) = false);
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"inline", sizeof("inline") - 1 })) {
    return 0;
  }
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"always_inline", sizeof("always_inline") - 1 })) {
    return 1;
  }
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"noinline", sizeof("noinline") - 1 })) {
    return 2;
  }
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"cold", sizeof("cold") - 1 })) {
    return 17;
  }
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"noreturn", sizeof("noreturn") - 1 })) {
    return 3;
  }
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"packed", sizeof("packed") - 1 })) {
    return 5;
  }
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"used", sizeof("used") - 1 })) {
    return 9;
  }
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"unused", sizeof("unused") - 1 })) {
    return 10;
  }
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"align", sizeof("align") - 1 })) {
    ((*wants_int) = true);
    return 4;
  }
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"export", sizeof("export") - 1 })) {
    ((*wants_str) = true);
    return 6;
  }
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"import", sizeof("import") - 1 })) {
    ((*wants_str) = true);
    return 7;
  }
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"section", sizeof("section") - 1 })) {
    ((*wants_str) = true);
    return 8;
  }
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"source", sizeof("source") - 1 })) {
    ((*wants_str) = true);
    return 15;
  }
  if (ast__parser__Parser__text_is(self, name, (str){ (const uint8_t *)"link", sizeof("link") - 1 })) {
    ((*wants_str) = true);
    return 16;
  }
  return -1;
}

bool ast__parser__Parser__parse_attribute(ast__parser__Parser *const self, ast__ast__Attr *const out) {
  ast__parser__Parser__advance(self);
  if (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Identifier)) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected an attribute path after '@'", sizeof("expected an attribute path after '@'") - 1 });
    return false;
  }
  const uint64_t ns = ast__parser__Parser__advance(self);
  if (ast__parser__Parser__text_is(self, ns, (str){ (const uint8_t *)"emit_macro", sizeof("emit_macro") - 1 }) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Dot))) {
    ((*out) = (ast__ast__Attr){ .owner = ast__ast__NODE_NONE, .kind = 11U, .arg = 0U, .str_span = lexer__token__Span__empty() });
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
      utils__errors__Errors__emit(&self->errors, lexer__token__Token__start(ns), lexer__token__Token__len(ns), ({ String__Global __sc52 = String__Global__new();
String__Global__push_str(&__sc52, (str){ .ptr = (const uint8_t*)"attribute '@emit_macro' takes no arguments", .len = sizeof("attribute '@emit_macro' takes no arguments") - 1 });
__sc52; }));
      while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightParen)) && (!ast__parser__Parser__at_end(self))) {
        ast__parser__Parser__advance(self);
      }
      ast__parser__Parser__match(self, lexer__token_type__TokenType_RightParen);
    }
    return true;
  }
  const int32_t tk = ({
    int32_t __sc53;
    if (ast__parser__Parser__text_is(self, ns, (str){ (const uint8_t *)"test", sizeof("test") - 1 })) {
      __sc53 = 12;
    } else if (ast__parser__Parser__text_is(self, ns, (str){ (const uint8_t *)"test_init", sizeof("test_init") - 1 })) {
      __sc53 = 13;
    } else if (ast__parser__Parser__text_is(self, ns, (str){ (const uint8_t *)"test_free", sizeof("test_free") - 1 })) {
      __sc53 = 14;
    } else {
      __sc53 = -1;
    }
    __sc53;
  });
  if ((tk >= 0) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Dot))) {
    ((*out) = (ast__ast__Attr){ .owner = ast__ast__NODE_NONE, .kind = ((uint8_t)tk), .arg = 0U, .str_span = lexer__token__Span__empty() });
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
      const uint64_t a = ast__parser__Parser__raw_peek(self);
      const bool ok = (ast__parser__Parser__check(self, lexer__token_type__TokenType_Identifier) && ({
        bool __sc54;
        if (tk == 12) {
          __sc54 = ast__parser__Parser__text_is(self, a, (str){ (const uint8_t *)"should_panic", sizeof("should_panic") - 1 });
        } else {
          __sc54 = ast__parser__Parser__text_is(self, a, (str){ (const uint8_t *)"global", sizeof("global") - 1 });
        }
        __sc54;
      }));
      if (ok) {
        (out->arg = 1U);
        ast__parser__Parser__advance(self);
      } else {
        utils__errors__Errors__emit(&self->errors, lexer__token__Token__start(a), ({
          uint32_t __sc55;
          if (lexer__token__Token__len(a) != 0U) {
            __sc55 = lexer__token__Token__len(a);
          } else {
            __sc55 = 1U;
          }
          __sc55;
        }), String__Global__from_str(({
          str __sc56;
          if (tk == 12) {
            __sc56 = (str){ (const uint8_t *)"attribute '@test' accepts only '(should_panic)'", sizeof("attribute '@test' accepts only '(should_panic)'") - 1 };
          } else {
            __sc56 = (str){ (const uint8_t *)"'@test_init' / '@test_free' accept only '(global)'", sizeof("'@test_init' / '@test_free' accept only '(global)'") - 1 };
          }
          __sc56;
        })));
        while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightParen)) && (!ast__parser__Parser__at_end(self))) {
          ast__parser__Parser__advance(self);
        }
      }
      ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
    }
    return true;
  }
  if (ast__parser__Parser__text_is(self, ns, (str){ (const uint8_t *)"platform", sizeof("platform") - 1 }) && (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Dot))) {
    ((*out) = (ast__ast__Attr){ .owner = ast__ast__NODE_NONE, .kind = 18U, .arg = 0U, .str_span = lexer__token__Span__empty() });
    if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen)) {
      utils__errors__Errors__emit(&self->errors, lexer__token__Token__start(ns), lexer__token__Token__len(ns), ({ String__Global __sc57 = String__Global__new();
String__Global__push_str(&__sc57, (str){ .ptr = (const uint8_t*)"attribute '@platform' requires a platform list, e.g. '@platform(windows)' or '@platform(linux | macos)'", .len = sizeof("attribute '@platform' requires a platform list, e.g. '@platform(windows)' or '@platform(linux | macos)'") - 1 });
__sc57; }));
      return true;
    }
    uint32_t mask = 0U;
    bool ok = true;
    for (;;) {
      const bool neg = ast__parser__Parser__match(self, lexer__token_type__TokenType_Bang);
      if (!ast__parser__Parser__check(self, lexer__token_type__TokenType_Identifier)) {
        ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected a platform name: windows, macos, or linux", sizeof("expected a platform name: windows, macos, or linux") - 1 });
        (ok = false);
        break;
      }
      const uint64_t p = ast__parser__Parser__advance(self);
      const uint32_t bit = ({
        uint32_t __sc58;
        if (ast__parser__Parser__text_is(self, p, (str){ (const uint8_t *)"windows", sizeof("windows") - 1 })) {
          __sc58 = 1U;
        } else if (ast__parser__Parser__text_is(self, p, (str){ (const uint8_t *)"macos", sizeof("macos") - 1 })) {
          __sc58 = 2U;
        } else if (ast__parser__Parser__text_is(self, p, (str){ (const uint8_t *)"linux", sizeof("linux") - 1 })) {
          __sc58 = 4U;
        } else {
          __sc58 = 0U;
        }
        __sc58;
      });
      if (bit == 0U) {
        utils__errors__Errors__emit(&self->errors, lexer__token__Token__start(p), lexer__token__Token__len(p), ({ String__Global __sc59 = String__Global__new();
String__Global__push_str(&__sc59, (str){ .ptr = (const uint8_t*)"unknown platform '", .len = sizeof("unknown platform '") - 1 });
String__Global__push_str(&__sc59, utils__errors__span_str(self->source, lexer__token__Token__start(p), lexer__token__Token__end(p)));
String__Global__push_str(&__sc59, (str){ .ptr = (const uint8_t*)"'; expected windows, macos, or linux", .len = sizeof("'; expected windows, macos, or linux") - 1 });
__sc59; }));
        (ok = false);
        break;
      }
      const uint32_t term = ({
        uint32_t __sc60;
        if (neg) {
          __sc60 = (bit ^ 7U);
        } else {
          __sc60 = bit;
        }
        __sc60;
      });
      (mask = (mask | term));
      if (!ast__parser__Parser__match(self, lexer__token_type__TokenType_Pipe)) {
        break;
      }
    }
    if (!ok) {
      while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightParen)) && (!ast__parser__Parser__at_end(self))) {
        ast__parser__Parser__advance(self);
      }
    }
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
    (out->arg = mask);
    return true;
  }
  if (!ast__parser__Parser__text_is(self, ns, (str){ (const uint8_t *)"c", sizeof("c") - 1 })) {
    while (ast__parser__Parser__match(self, lexer__token_type__TokenType_Dot)) {
      if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Identifier)) {
        ast__parser__Parser__advance(self);
      } else {
        break;
      }
    }
    ast__parser__Parser__skip_attr_args(self);
    if (!self->bootstrap_tags) {
      utils__errors__Errors__emit(&self->errors, lexer__token__Token__start(ns), lexer__token__Token__len(ns), ({ String__Global __sc61 = String__Global__new();
String__Global__push_str(&__sc61, (str){ .ptr = (const uint8_t*)"unknown attribute '@", .len = sizeof("unknown attribute '@") - 1 });
String__Global__push_str(&__sc61, utils__errors__span_str(self->source, lexer__token__Token__start(ns), lexer__token__Token__end(ns)));
String__Global__push_str(&__sc61, (str){ .ptr = (const uint8_t*)"'; pass --bootstrap-tags to accept unknown attributes", .len = sizeof("'; pass --bootstrap-tags to accept unknown attributes") - 1 });
__sc61; }));
    }
    return false;
  }
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Dot, (str){ (const uint8_t *)"'.'", sizeof("'.'") - 1 });
  if ((((ast__parser__Parser__at_end(self) || ast__parser__Parser__check(self, lexer__token_type__TokenType_LeftParen)) || ast__parser__Parser__check(self, lexer__token_type__TokenType_RightParen)) || ast__parser__Parser__check(self, lexer__token_type__TokenType_Semicolon)) || ast__parser__Parser__check(self, lexer__token_type__TokenType_Dot)) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected an attribute name after '@c.'", sizeof("expected an attribute name after '@c.'") - 1 });
    return false;
  }
  const uint64_t name = ast__parser__Parser__advance(self);
  if (ast__parser__Parser__check(self, lexer__token_type__TokenType_Dot)) {
    ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"target-specific attribute namespaces (e.g. '@c.gnu.*') are not supported", sizeof("target-specific attribute namespaces (e.g. '@c.gnu.*') are not supported") - 1 });
  }
  bool wants_str = false;
  bool wants_int = false;
  const int32_t kind = ast__parser__Parser__attr_kind_of(self, name, (&wants_str), (&wants_int));
  if (kind < 0) {
    ast__parser__Parser__skip_attr_args(self);
    if (!self->bootstrap_tags) {
      utils__errors__Errors__emit(&self->errors, lexer__token__Token__start(name), lexer__token__Token__len(name), ({ String__Global __sc62 = String__Global__new();
String__Global__push_str(&__sc62, (str){ .ptr = (const uint8_t*)"unknown attribute '@c.", .len = sizeof("unknown attribute '@c.") - 1 });
String__Global__push_str(&__sc62, utils__errors__span_str(self->source, lexer__token__Token__start(name), lexer__token__Token__end(name)));
String__Global__push_str(&__sc62, (str){ .ptr = (const uint8_t*)"'; pass --bootstrap-tags to accept unknown attributes", .len = sizeof("'; pass --bootstrap-tags to accept unknown attributes") - 1 });
__sc62; }));
      utils__errors__Errors__note(&self->errors, ({ String__Global __sc63 = String__Global__new();
String__Global__push_str(&__sc63, (str){ .ptr = (const uint8_t*)"supported '@c' attributes include export, import, noreturn, always_inline, cold, used, unused, section, packed, and align", .len = sizeof("supported '@c' attributes include export, import, noreturn, always_inline, cold, used, unused, section, packed, and align") - 1 });
__sc63; }));
    }
    return false;
  }
  ((*out) = (ast__ast__Attr){ .owner = ast__ast__NODE_NONE, .kind = ((uint8_t)kind), .arg = 0U, .str_span = lexer__token__Span__empty() });
  const bool has_args = ast__parser__Parser__match(self, lexer__token_type__TokenType_LeftParen);
  if (wants_str || wants_int) {
    if (!has_args) {
      utils__errors__Errors__emit(&self->errors, lexer__token__Token__start(name), lexer__token__Token__len(name), ({ String__Global __sc64 = String__Global__new();
String__Global__push_str(&__sc64, (str){ .ptr = (const uint8_t*)"attribute '@c.", .len = sizeof("attribute '@c.") - 1 });
String__Global__push_str(&__sc64, utils__errors__span_str(self->source, lexer__token__Token__start(name), lexer__token__Token__end(name)));
String__Global__push_str(&__sc64, (str){ .ptr = (const uint8_t*)"' requires an argument", .len = sizeof("' requires an argument") - 1 });
__sc64; }));
      return true;
    }
    if (wants_int) {
      if (!ast__parser__Parser__check(self, lexer__token_type__TokenType_IntegerLiteral)) {
        ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected an integer argument", sizeof("expected an integer argument") - 1 });
      } else {
        const uint64_t lit = ast__parser__Parser__raw_peek(self);
        char buf[24] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        size_t k = 0ULL;
        uint32_t i = lexer__token__Token__start(lit);
        while ((i < lexer__token__Token__end(lit)) && ((k + 1ULL) < 24ULL)) {
          const uint8_t ch = self->source[((size_t)i)];
          if (ch != 95U) {
            (buf[__sc_bounds(k, 24)] = ((char)ch));
            (k = (k + 1ULL));
          }
          (i = (i + 1U));
        }
        (buf[__sc_bounds(k, 24)] = 0);
        (out->arg = ((uint32_t)strtoul(((const char *)(&buf[0])), NULL, 0)));
      }
      ast__parser__Parser__advance(self);
    } else {
      if (!ast__parser__Parser__check(self, lexer__token_type__TokenType_StringLiteral)) {
        ast__parser__Parser__error_here(self, (str){ (const uint8_t *)"expected a string argument", sizeof("expected a string argument") - 1 });
      } else {
        const uint64_t lit = ast__parser__Parser__raw_peek(self);
        (out->str_span = lexer__token__Span__new((lexer__token__Token__start(lit) + 1U), (lexer__token__Token__end(lit) - 1U)));
      }
      ast__parser__Parser__advance(self);
    }
    ast__parser__Parser__expect(self, lexer__token_type__TokenType_RightParen, (str){ (const uint8_t *)"')'", sizeof("')'") - 1 });
  } else if (has_args) {
    utils__errors__Errors__emit(&self->errors, lexer__token__Token__start(name), lexer__token__Token__len(name), ({ String__Global __sc65 = String__Global__new();
String__Global__push_str(&__sc65, (str){ .ptr = (const uint8_t*)"attribute '@c.", .len = sizeof("attribute '@c.") - 1 });
String__Global__push_str(&__sc65, utils__errors__span_str(self->source, lexer__token__Token__start(name), lexer__token__Token__end(name)));
String__Global__push_str(&__sc65, (str){ .ptr = (const uint8_t*)"' takes no arguments", .len = sizeof("' takes no arguments") - 1 });
__sc65; }));
    while ((!ast__parser__Parser__check(self, lexer__token_type__TokenType_RightParen)) && (!ast__parser__Parser__at_end(self))) {
      ast__parser__Parser__advance(self);
    }
    ast__parser__Parser__match(self, lexer__token_type__TokenType_RightParen);
  }
  return true;
}

Vector__ast__ast__Attr__Global ast__parser__Parser__parse_attributes(ast__parser__Parser *const self, size_t const cap) {
  Vector__ast__ast__Attr__Global attrs = Vector__ast__ast__Attr__Global__new();
  Vector__ast__ast__Attr__Global__reserve(&attrs, cap);
  while (ast__parser__Parser__check(self, lexer__token_type__TokenType_At)) {
    ast__ast__Attr attr = (ast__ast__Attr){ .owner = ast__ast__NODE_NONE, .kind = 0U, .arg = 0U, .str_span = lexer__token__Span__empty() };
    if (ast__parser__Parser__parse_attribute(self, (&attr)) && (Vector__ast__ast__Attr__Global__len(&attrs) < cap)) {
      Vector__ast__ast__Attr__Global__push(&attrs, attr);
    }
  }
  return attrs;
}

void ast__parser__Parser__add_attrs_to(ast__parser__Parser *const self, Vector__ast__ast__Attr__Global *const attrs, uint32_t const owner) {
  for (size_t i = 0ULL; i < Vector__ast__ast__Attr__Global__len(attrs); i++) {
    ast__ast__Attr attr = (*({ __auto_type __sc66 = attrs; Vector__ast__ast__Attr__Global__index(__sc66, i); }));
    (attr.owner = owner);
    ast__ast__Ast__add_attr(&self->ast, attr);
  }
}

void ast__parser__Parser__validate_item_attrs(ast__parser__Parser *const self, Vector__ast__ast__Attr__Global *const attrs, uint32_t const owner) {
  for (size_t i = 0ULL; i < Vector__ast__ast__Attr__Global__len(attrs); i++) {
    const ast__ast__Attr *const attr = Vector__ast__ast__Attr__Global__at(attrs, i);
    lexer__token__Span sp = lexer__token__Span__empty();
    bool valid_test = false;
    bool generic_aggregate = false;
    if (owner != ast__ast__NODE_NONE) {
      const ast__ast__Node *const d = ast__ast__Ast__at_const(&self->ast, owner);
      (sp = d->span);
      (valid_test = ((d->kind == ast__ast__NodeKind_NODE_FUNCTION) && (d->as_data.function.generics.len == 0U)));
      (generic_aggregate = (((d->kind == ast__ast__NodeKind_NODE_STRUCT) || (d->kind == ast__ast__NodeKind_NODE_ENUM)) && (d->as_data.aggregate.generics.len != 0U)));
    }
    if ((((attr->kind == 12U) || (attr->kind == 13U)) || (attr->kind == 14U)) && (!valid_test)) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc67 = String__Global__new();
String__Global__push_str(&__sc67, (str){ .ptr = (const uint8_t*)"'@test' / '@test_init' / '@test_free' may only be applied to a non-generic function", .len = sizeof("'@test' / '@test_init' / '@test_free' may only be applied to a non-generic function") - 1 });
__sc67; }));
    }
    if (((attr->kind == 15U) || (attr->kind == 16U)) && ((owner == ast__ast__NODE_NONE) || (ast__ast__Ast__at_const(&self->ast, owner)->kind != ast__ast__NodeKind_NODE_EXTERN_BLOCK))) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc68 = String__Global__new();
String__Global__push_str(&__sc68, (str){ .ptr = (const uint8_t*)"'@c.source' / '@c.link' may only be applied to an 'extern \"C\"' block", .len = sizeof("'@c.source' / '@c.link' may only be applied to an 'extern \"C\"' block") - 1 });
__sc68; }));
    }
    if ((attr->kind == 11U) && (!generic_aggregate)) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc69 = String__Global__new();
String__Global__push_str(&__sc69, (str){ .ptr = (const uint8_t*)"'@emit_macro' may only be applied to a generic struct or enum", .len = sizeof("'@emit_macro' may only be applied to a generic struct or enum") - 1 });
__sc69; }));
      utils__errors__Errors__note(&self->errors, ({ String__Global __sc70 = String__Global__new();
String__Global__push_str(&__sc70, (str){ .ptr = (const uint8_t*)"write it before a declaration like 'struct Box<T> { ... }' or 'enum Option<T> { ... }'", .len = sizeof("write it before a declaration like 'struct Box<T> { ... }' or 'enum Option<T> { ... }'") - 1 });
__sc70; }));
    }
    if (((attr->kind == 18U) && (owner != ast__ast__NODE_NONE)) && (ast__ast__Ast__at_const(&self->ast, owner)->kind == ast__ast__NodeKind_NODE_IMPORT)) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc71 = String__Global__new();
String__Global__push_str(&__sc71, (str){ .ptr = (const uint8_t*)"'@platform' cannot gate an 'import'; gate the declarations instead", .len = sizeof("'@platform' cannot gate an 'import'; gate the declarations instead") - 1 });
__sc71; }));
    }
  }
}

uint32_t ast__parser__Parser__parse_import(ast__parser__Parser *const self) {
  const uint32_t start = lexer__token__Token__start(ast__parser__Parser__raw_peek(self));
  ast__parser__Parser__advance(self);
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  const uint32_t first = ast__parser__Parser__identifier(self);
  ast__ast__Ast__push(&self->ast, first);
  while (ast__parser__Parser__match(self, lexer__token_type__TokenType_PathSeparator)) {
    ast__ast__Ast__push(&self->ast, ast__parser__Parser__identifier(self));
  }
  const ast__ast__NodeList path = ast__ast__Ast__commit(&self->ast, mark);
  uint32_t alias = ast__ast__NODE_NONE;
  bool glob = false;
  if (ast__parser__Parser__match(self, lexer__token_type__TokenType_As)) {
    if (ast__parser__Parser__match(self, lexer__token_type__TokenType_Star)) {
      (glob = true);
    } else {
      (alias = ast__parser__Parser__identifier(self));
    }
  }
  ast__parser__Parser__expect(self, lexer__token_type__TokenType_Semicolon, (str){ (const uint8_t *)"';'", sizeof("';'") - 1 });
  return ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_IMPORT, .span = lexer__token__Span__new(start, ast__parser__Parser__previous_end(self)), .as_data = (ast__ast__NodeAs){ .import_decl = (ast__ast__ImportData){ .path = path, .alias = alias, .glob = glob } } });
}

bool ast__parser__Parser__is_literal_token(lexer__token_type__TokenType const kind) {
  return ((((((((((kind == lexer__token_type__TokenType_IntegerLiteral) || (kind == lexer__token_type__TokenType_FloatLiteral)) || (kind == lexer__token_type__TokenType_CharacterLiteral)) || (kind == lexer__token_type__TokenType_ByteCharacterLiteral)) || (kind == lexer__token_type__TokenType_StringLiteral)) || (kind == lexer__token_type__TokenType_RawStringLiteral)) || (kind == lexer__token_type__TokenType_ByteStringLiteral)) || (kind == lexer__token_type__TokenType_True)) || (kind == lexer__token_type__TokenType_False)) || (kind == lexer__token_type__TokenType_Null));
}

bool ast__parser__Parser__unary_operator(lexer__token_type__TokenType const kind) {
  return (((((((kind == lexer__token_type__TokenType_Bang) || (kind == lexer__token_type__TokenType_Tilde)) || (kind == lexer__token_type__TokenType_Minus)) || (kind == lexer__token_type__TokenType_Star)) || (kind == lexer__token_type__TokenType_Ampersand)) || (kind == lexer__token_type__TokenType_Move)) || (kind == lexer__token_type__TokenType_Unsafe));
}

int32_t ast__parser__Parser__precedence(lexer__token_type__TokenType const kind) {
  {
    const lexer__token_type__TokenType __sc72 = kind;
    if ((__sc72 == lexer__token_type__TokenType_Star) || (__sc72 == lexer__token_type__TokenType_Slash) || (__sc72 == lexer__token_type__TokenType_Percent)) {
      return 11;
    }
    else if ((__sc72 == lexer__token_type__TokenType_Plus) || (__sc72 == lexer__token_type__TokenType_Minus)) {
      return 10;
    }
    else if ((__sc72 == lexer__token_type__TokenType_LeftShift) || (__sc72 == lexer__token_type__TokenType_RightShift)) {
      return 9;
    }
    else if ((__sc72 == lexer__token_type__TokenType_LessThan) || (__sc72 == lexer__token_type__TokenType_LessThanEqual) || (__sc72 == lexer__token_type__TokenType_GreaterThan) || (__sc72 == lexer__token_type__TokenType_GreaterThanEqual)) {
      return 8;
    }
    else if ((__sc72 == lexer__token_type__TokenType_EqualEqual) || (__sc72 == lexer__token_type__TokenType_BangEqual)) {
      return 7;
    }
    else if (__sc72 == lexer__token_type__TokenType_Ampersand) {
      return 6;
    }
    else if (__sc72 == lexer__token_type__TokenType_Caret) {
      return 5;
    }
    else if (__sc72 == lexer__token_type__TokenType_Pipe) {
      return 4;
    }
    else if (__sc72 == lexer__token_type__TokenType_AmpersandAmpersand) {
      return 3;
    }
    else if (__sc72 == lexer__token_type__TokenType_PipePipe) {
      return 2;
    }
    else if (1) {
      return 0;
    }
    else { __builtin_unreachable(); }
  }
}

bool ast__parser__Parser__assignment_operator(lexer__token_type__TokenType const kind) {
  return (((((((((((kind == lexer__token_type__TokenType_Equal) || (kind == lexer__token_type__TokenType_PlusEqual)) || (kind == lexer__token_type__TokenType_MinusEqual)) || (kind == lexer__token_type__TokenType_StarEqual)) || (kind == lexer__token_type__TokenType_SlashEqual)) || (kind == lexer__token_type__TokenType_PercentEqual)) || (kind == lexer__token_type__TokenType_AmpersandEqual)) || (kind == lexer__token_type__TokenType_PipeEqual)) || (kind == lexer__token_type__TokenType_CaretEqual)) || (kind == lexer__token_type__TokenType_LeftShiftEqual)) || (kind == lexer__token_type__TokenType_RightShiftEqual));
}

void ast__parser__Parser__build_ast(ast__parser__Parser *const self) {
  const uint32_t mark = ast__ast__Ast__mark(&self->ast);
  while (!ast__parser__Parser__at_end(self)) {
    const size_t before = self->current;
    const uint32_t item = ast__parser__Parser__parse_item(self);
    if (item != ast__ast__NODE_NONE) {
      ast__ast__Ast__push(&self->ast, item);
    }
    if ((self->current == before) && (!ast__parser__Parser__at_end(self))) {
      ast__parser__Parser__advance(self);
    }
  }
  const ast__ast__NodeList items = ast__ast__Ast__commit(&self->ast, mark);
  (self->ast.root = ast__ast__Ast__add(&self->ast, (ast__ast__Node){ .kind = ast__ast__NodeKind_NODE_PROGRAM, .span = lexer__token__Span__new(0U, ((uint32_t)self->len)), .as_data = (ast__ast__NodeAs){ .program = (ast__ast__ProgramData){ .items = items } } }));
  utils__errors__Errors__finalize(&self->errors, self->source, self->len, self->file);
}

bool ast__parser__Parser__has_errors(const ast__parser__Parser *const self) {
  return utils__errors__Errors__has_errors(&self->errors);
}

void ast__parser__Parser__log_errors(const ast__parser__Parser *const self) {
  utils__errors__Errors__log(&self->errors);
}

void ast__parser__Parser__free(ast__parser__Parser *const self) {
  Vector__u64__Global__free(&self->tokens);
  ast__ast__Ast__free(&self->ast);
  utils__errors__Errors__free(&self->errors);
}

