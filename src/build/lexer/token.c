#include "../lexer/token.h"
#include "../lexer/token_type.h"
#include "../__std/str.h"
#include "../__std/string.h"

_Static_assert(sizeof(lexer__token__Span) == 8 && _Alignof(lexer__token__Span) == 4, "super-c layout model mismatch: lexer__token__Span");


lexer__token__Span lexer__token__Span__new(uint32_t const start, uint32_t const end) {
  return (lexer__token__Span){ .start = start, .end = end };
}

lexer__token__Span lexer__token__Span__empty(void) {
  return (lexer__token__Span){ .start = 0U, .end = 0U };
}

lexer__token__Token lexer__token__Token__new(lexer__token_type__TokenType const kind, uint32_t const start, uint32_t const len) {
  return ((((uint64_t)start) | ({ uint64_t __sc0 = ((uint64_t)len); int64_t __sc1 = (int64_t)(32ULL); if ((uint64_t)__sc1 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc0 << __sc1)); })) | ({ uint64_t __sc2 = ((uint64_t)kind); int64_t __sc3 = (int64_t)(56ULL); if ((uint64_t)__sc3 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc2 << __sc3)); }));
}

uint32_t lexer__token__Token__start(lexer__token__Token const self) {
  return ((uint32_t)self);
}

uint32_t lexer__token__Token__len(lexer__token__Token const self) {
  return ((uint32_t)(({ uint64_t __sc4 = self; int64_t __sc5 = (int64_t)(32ULL); if ((uint64_t)__sc5 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc4 >> __sc5); }) & 0xFFFFFFULL));
}

uint32_t lexer__token__Token__end(lexer__token__Token const self) {
  return (lexer__token__Token__start(self) + lexer__token__Token__len(self));
}

lexer__token_type__TokenType lexer__token__Token__kind(lexer__token__Token const self) {
  return ((lexer__token_type__TokenType)({ uint64_t __sc6 = self; int64_t __sc7 = (int64_t)(56ULL); if ((uint64_t)__sc7 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc6 >> __sc7); }));
}

lexer__token__Span lexer__token__Token__span(lexer__token__Token const self) {
  return lexer__token__Span__new(lexer__token__Token__start(self), lexer__token__Token__end(self));
}

void lexer__token__Token__fprint(lexer__token__Token const self) {
  ({ String__Global __sc8 = String__Global__new();
String__Global__push_str(&__sc8, (str){ .ptr = (const uint8_t*)"Token { token_type: ", .len = sizeof("Token { token_type: ") - 1 });
String__Global__push_str(&__sc8, lexer__token_type__TokenType__name(lexer__token__Token__kind(self)));
String__Global__push_str(&__sc8, (str){ .ptr = (const uint8_t*)", span: Span { start: ", .len = sizeof(", span: Span { start: ") - 1 });
String__Global__push_u64(&__sc8, (uint64_t)(lexer__token__Token__start(self)));
String__Global__push_str(&__sc8, (str){ .ptr = (const uint8_t*)", end: ", .len = sizeof(", end: ") - 1 });
String__Global__push_u64(&__sc8, (uint64_t)(lexer__token__Token__end(self)));
String__Global__push_str(&__sc8, (str){ .ptr = (const uint8_t*)" } }", .len = sizeof(" } }") - 1 });
String__Global__push_byte(&__sc8, 10);
String__Global__eprint(&__sc8); String__Global__free(&__sc8); });
}

