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

// --test mode: the driver's per-module test plan slice. Codegen appends one NON-static wrapper
// `void __sc_test_w_<module>_<node>(void *genv)` per @test fn (setup -> test -> teardown -> RAII free of
// the fixture), plus the global-env `__sc_test_genv_init/_free` pair in the module that declares it.
// Wrappers live in the same TU as the (possibly static) test fns, so private tests need no linkage change.
typedef struct {
    NodeId fn;     // the @test function/method
    uint8_t wants; // bit0 = takes the fixture (module fixture, or the extend target as `self`), bit1 = global env
    DefId suite;   // a METHOD test's extend-target fixture type ({0, NODE_NONE} = a free-fn test)
    bool suite_is_enum;
    NodeId suite_init, suite_free; // the type's @test_init/@test_free methods (same module; NODE_NONE = none)
} CgTestCase;
typedef struct {
    bool enabled;              // also gates the @test-fn emission itself (skipped entirely when false)
    const CgTestCase *cases;   // this module's @test fns/methods
    uint32_t ncases;
    NodeId fx_init, fx_free;   // this module's free-fn fixture pair (NODE_NONE if absent)
    DefId fx_type;             // the module fixture's struct/enum decl ({0, NODE_NONE} if absent)
    bool fx_is_enum;
    NodeId genv_init, genv_free; // set ONLY in the module declaring @test_init(global)
    DefId genv_type;             // the global env's struct/enum decl (every module that has genv tests)
    bool genv_is_enum;
} CgTestInfo;
void codegen_set_test_info(Codegen *c, const CgTestInfo *ti);

// The full C standard library include block the generated runtime pulls in, each header guarded by
// __has_include so a platform missing an optional/C23 header (threads.h, uchar.h, stdbit.h, ...) just
// skips it. Written to the shared super_rt.h every emitted module includes.
extern const char *const SUPER_RT_INCLUDES;

ERRORS_API(Codegen, codegen, c)

#endif // CODEGEN_H
