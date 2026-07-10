#ifndef SUPER___STD__INTERFACES_H
#define SUPER___STD__INTERFACES_H

#include "../super_rt.h"
typedef struct lexer__lexer__Lexer lexer__lexer__Lexer;
typedef struct utils__errors__Errors utils__errors__Errors;
typedef struct ast__parser__Parser ast__parser__Parser;
typedef struct typechecker__typechecker__TypeChecker typechecker__typechecker__TypeChecker;
typedef struct codegen__codegen__Codegen codegen__codegen__Codegen;

typedef struct Global Global;

struct Global {
};

void *Global__alloc(Global *const self, size_t const size, size_t const align);
void *Global__realloc(Global *const self, void *const ptr, size_t const old_size, size_t const new_size, size_t const align);
void Global__dealloc(Global *const self, void *const ptr, size_t const size, size_t const align);
Global Global__default_(void);


#endif
