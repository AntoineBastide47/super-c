#ifndef LEXER_H
#define LEXER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "token.h"
#include "types/vector.h"
#include "utils/errors.h"

typedef struct Lexer Lexer;

Lexer *lexer_new(const char *source, const size_t len);
void lexer_set_file(Lexer *l, const char *file); // path shown in diagnostics (NULL = none)
void lexer_free(Lexer **l);

void lexer_scan_tokens(Lexer *l);
Token_Vec lexer_take_tokens(Lexer *l);

ERRORS_API(Lexer, lexer, l)

#endif // LEXER_H
