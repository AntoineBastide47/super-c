#ifndef TYPECHECKER_H
#define TYPECHECKER_H

#include "ast/ast.h"
#include "utils/errors.h"

typedef struct TypeChecker TypeChecker;

TypeChecker *typechecker_new(Ast *ast, const char *source, const size_t len);
void typechecker_free(TypeChecker **t);

void typechecker_check(TypeChecker *t);
Ast *typechecker_take_ast(TypeChecker *t);

ERRORS_API(TypeChecker, typechecker, t)

#endif // TYPECHECKER_H
