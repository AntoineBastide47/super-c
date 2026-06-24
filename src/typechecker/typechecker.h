#ifndef TYPECHECKER_H
#define TYPECHECKER_H

#include "ast/ast.h"
#include "utils/errors.h"

typedef struct TypeChecker TypeChecker;
typedef struct Package Package; // module/loader.h; NULL for the single-file / REPL path

// `package` lets the checker follow imported decls into their origin module's Ast; pass NULL when
// compiling a lone source with no imports (the REPL and unit tests).
TypeChecker *typechecker_new(Ast *ast, const char *source, const size_t len, const Package *package);
void typechecker_free(TypeChecker **t);

void typechecker_check(TypeChecker *t);
Ast *typechecker_take_ast(TypeChecker *t);

ERRORS_API(TypeChecker, typechecker, t)

#endif // TYPECHECKER_H
