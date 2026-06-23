// Direct coverage of lexer/token.{h,c} (u64 bit-packing + Span helpers + token_fprint) and
// lexer/token_type.c (token_type_name, including the out-of-range guard).

#include "test_harness.h"

#include "lexer/token_type.h"

static void test_packing(void) {
  const Token t = token_new(Identifier, 5, 3);
  CHECK_EQ_U32(token_start(t), 5);
  CHECK_EQ_U32(token_len(t), 3);
  CHECK_EQ_U32(token_end(t), 8);
  CHECK(token_type(t) == Identifier, "type round-trips");

  // len occupies 24 bits; the high byte holds the type without bleeding into len/start.
  const Token big = token_new(Eof, 0xABCDEFu, 0xFFFFFFu);
  CHECK_EQ_U32(token_len(big), 0xFFFFFFu);
  CHECK_EQ_U32(token_start(big), 0xABCDEFu);
  CHECK(token_type(big) == Eof, "high-byte type survives a full 24-bit len");
}

static void test_spans(void) {
  const Span a = span_new(2, 7);
  CHECK(a.start == 2 && a.end == 7, "span_new");
  const Span e = span_empty();
  CHECK(e.start == 0 && e.end == 0, "span_empty");
  const Span ts = token_span(token_new(Plus, 10, 1));
  CHECK(ts.start == 10 && ts.end == 11, "token_span");
}

static void test_fprint(void) {
  char *buf = NULL;
  size_t size = 0;
  FILE *f = open_memstream(&buf, &size);
  token_fprint(f, token_new(Identifier, 0, 5));
  fclose(f);
  CHECK_STR_EQ(buf, "Token { token_type: Identifier, span: Span { start: 0, end: 5 } }");
  free(buf);
}

static void test_type_names(void) {
  CHECK_STR_EQ(token_type_name(Identifier), "Identifier");
  CHECK_STR_EQ(token_type_name(Fn), "Fn");
  CHECK_STR_EQ(token_type_name(IntegerLiteral), "IntegerLiteral");
  CHECK_STR_EQ(token_type_name(LeftBrace), "LeftBrace");
  CHECK_STR_EQ(token_type_name(Plus), "Plus");
  CHECK_STR_EQ(token_type_name(RangeInclusive), "RangeInclusive");
  CHECK_STR_EQ(token_type_name(Eof), "Eof");
  CHECK_STR_EQ(token_type_name((TokenType)(Eof + 1)), "InvalidTokenType");
  CHECK_STR_EQ(token_type_name((TokenType)255), "InvalidTokenType");
}

int main(void) {
  test_packing();
  test_spans();
  test_fprint();
  test_type_names();
  if (failures) {
    fprintf(stderr, "%d token test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("token tests passed");
  return 0;
}
