#ifndef TOKEN_H
#define TOKEN_H

#include <stdint.h>
#include <stdio.h>

#include "token_type.h"
#include "types/vector.h"
#include "utils/attributes.h"

typedef struct Span {
    uint32_t start;
    uint32_t end;
} Span;

ALWAYS_INLINE Span span_new(const uint32_t start, const uint32_t end) {
  return (Span){start, end};
}

ALWAYS_INLINE Span span_empty(void) {
  return (Span){0, 0};
}

// A token packed into a single u64: start (low 32 bits) | len (24 bits) |
// token type (high 8 bits). No lexeme is stored; slices come from the source.
typedef uint64_t Token;

VEC_DECLARE(Token, Token_Vec);

ALWAYS_INLINE Token token_new(const TokenType token_type, const uint32_t start, const uint32_t len) {
  return (uint64_t)start | ((uint64_t)len << 32) | ((uint64_t)token_type << 56);
}

ALWAYS_INLINE uint32_t token_start(const Token t) {
  return (uint32_t)t;
}

ALWAYS_INLINE uint32_t token_len(const Token t) {
  return (uint32_t)((t >> 32) & 0xFFFFFF);
}

ALWAYS_INLINE uint32_t token_end(const Token t) {
  return token_start(t) + token_len(t);
}

ALWAYS_INLINE TokenType token_type(const Token t) {
  return (TokenType)(uint8_t)(t >> 56);
}

ALWAYS_INLINE Span token_span(const Token t) {
  return span_new(token_start(t), token_end(t));
}

// Debug representation, e.g.
//   Token { token_type: Identifier, span: Span { start: 0, end: 5 } }
COLD_EXPORT void token_fprint(FILE *out, const Token t);

#endif // TOKEN_H
