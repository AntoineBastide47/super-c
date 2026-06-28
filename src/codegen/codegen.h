#ifndef CODEGEN_H
#define CODEGEN_H

#include <stdio.h>

#include "ast/ast.h"
#include "utils/errors.h"

typedef struct Codegen Codegen;
typedef struct Package Package; // module/loader.h

// `package` enables per-module symbol mangling and cross-module references. Output is always a build tree
// (one .h + .c per module); a lone user module (+ prelude) is emitted unmangled.
Codegen *codegen_new(Ast *ast, const char *source, const size_t len, const Package *package);
void codegen_free(Codegen **c);

void codegen_emit(Codegen *c, FILE *out);          // the module's .c
void codegen_emit_header(Codegen *c, FILE *out);   // the module's .h
void codegen_set_multifile(Codegen *c, bool on);   // force header+.c-with-includes output (the build/ tree)
Ast *codegen_take_ast(Codegen *c);

// The full C standard library include block the generated runtime pulls in, each header guarded by
// __has_include so a platform missing an optional/C23 header (threads.h, uchar.h, stdbit.h, ...) just
// skips it. Written to the shared super_rt.h every emitted module includes.
extern const char *const SUPER_RT_INCLUDES;

ERRORS_API(Codegen, codegen, c)

#endif // CODEGEN_H
