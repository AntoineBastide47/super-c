#include "token.h"

VEC_DEFINE(Token, Token_Vec);

void token_fprint(FILE *out, Token t) {
    fprintf(out, "Token { token_type: %s, span: Span { start: %u, end: %u } }",
            token_type_name(token_type(t)), token_start(t), token_end(t));
}
