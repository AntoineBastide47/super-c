#ifndef CODEGEN_H
#define CODEGEN_H

#include <stdio.h>

#include "ast/ast.h"
#include "utils/errors.h"

typedef struct Codegen Codegen;

Codegen *codegen_new(Ast *ast, const char *source, const size_t len);
void codegen_free(Codegen **c);

void codegen_emit(Codegen *c, FILE *out);
Ast *codegen_take_ast(Codegen *c);

ERRORS_API(Codegen, codegen, c)

#endif // CODEGEN_H
