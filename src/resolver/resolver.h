#ifndef RESOLVER_H
#define RESOLVER_H

#include <stddef.h>

#include "ast/ast.h"
#include "utils/errors.h"

typedef struct Resolver Resolver;
typedef struct Package Package; // module/loader.h; NULL for the single-file / REPL path

// `package` lets the resolver resolve `import`ed module-qualified names across modules; pass NULL when
// compiling a lone source with no imports (the REPL and unit tests).
Resolver *resolver_new(Ast *ast, const char *source, const size_t len, const Package *package);
void resolver_free(Resolver **r);

void resolver_resolve(Resolver *r);
Ast *resolver_take_ast(Resolver *r);

ERRORS_API(Resolver, resolver, r)

#endif // RESOLVER_H
