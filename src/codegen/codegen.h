#ifndef CODEGEN_H
#define CODEGEN_H

#include <stdio.h>

#include "ast/ast.h"
#include "utils/errors.h"

typedef struct Codegen Codegen;
typedef struct Package Package; // module/loader.h; NULL (or a 1-module package) = single-file output

// `package` enables per-module symbol mangling and cross-module references. With NULL or a single-module
// package, output is a single self-contained .c exactly as before.
Codegen *codegen_new(Ast *ast, const char *source, const size_t len, const Package *package);
void codegen_free(Codegen **c);

void codegen_emit(Codegen *c, FILE *out);          // the module's .c
void codegen_emit_header(Codegen *c, FILE *out);   // the module's .h (multi-file output)
void codegen_emit_unit(Codegen **cs, size_t n, FILE *out); // many modules -> one self-contained .c
void codegen_set_multifile(Codegen *c, bool on);   // force header+.c-with-includes output (CLI build/ tree)
Ast *codegen_take_ast(Codegen *c);

// The full C standard library include block the generated runtime pulls in, each header guarded by
// __has_include so a platform missing an optional/C23 header (threads.h, uchar.h, stdbit.h, ...) just
// skips it. Shared by super_rt.h (multi-module) and the single self-contained .c output.
extern const char *const SUPER_RT_INCLUDES;

ERRORS_API(Codegen, codegen, c)

#endif // CODEGEN_H
