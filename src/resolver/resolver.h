#ifndef RESOLVER_H
#define RESOLVER_H

#include <stddef.h>

#include "ast/ast.h"
#include "utils/errors.h"

typedef struct Resolver Resolver;

Resolver *resolver_new(Ast *ast, const char *source, const size_t len);
void resolver_free(Resolver **r);

void resolver_resolve(Resolver *r);
Ast *resolver_take_ast(Resolver *r);

ERRORS_API(Resolver, resolver, r)

#endif // RESOLVER_H
