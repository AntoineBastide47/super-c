#ifndef PARSER_H
#define PARSER_H

#include "utils/errors.h"
#include "types/vector.h"
#include "lexer/token.h"
#include "ast.h"

typedef struct Parser Parser;

Parser *parser_new(Token_Vec tokens, const char *source, const size_t len);
void parser_free(Parser **p);

void parser_build_ast(Parser *p);
Ast *parser_take_ast(Parser *p);

ERRORS_API(Parser, parser, p);

#endif // PARSER_H