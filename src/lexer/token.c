#include "token.h"

VEC_DEFINE(Token, Token_Vec);

COLD_EXPORT void token_fprint(FILE *out, const Token t) {
  fprintf(
      out, "Token { token_type: %s, span: Span { start: %u, end: %u } }", token_type_name(token_type(t)),
      token_start(t), token_end(t));
}
