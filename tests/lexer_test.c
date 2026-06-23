#include "test_harness.h"

#include "lexer/token_type.h"

static void expect_tokens(const char *name, const char *source, const TokenType *expected, size_t expected_len) {
  Lexer *lexer = lexer_new(source, strlen(source));
  lexer_scan_tokens(lexer);

  if (lexer_has_errors(lexer)) {
    String_Vec errors = lexer_take_errors(lexer);
    CHECK(false, "%s: unexpected error: %s", name, errors.data[0]);
    free_errors(&errors);
  }

  Token_Vec tokens = lexer_take_tokens(lexer);
  CHECK(tokens.len == expected_len, "%s: expected %zu tokens, got %zu", name, expected_len, tokens.len);
  const size_t count = tokens.len < expected_len ? tokens.len : expected_len;
  for (size_t i = 0; i < count; i++) {
    const TokenType actual = token_type(tokens.data[i]);
    CHECK(
        actual == expected[i], "%s: token %zu: expected %s, got %s", name, i, token_type_name(expected[i]),
        token_type_name(actual));
  }

  VEC_DEINIT(tokens);
  lexer_free(&lexer);
}

static void expect_error_bytes(const char *name, const char *source, size_t len, const char *message) {
  Lexer *lexer = lexer_new(source, len);
  lexer_scan_tokens(lexer);
  CHECK(lexer_has_errors(lexer), "%s: expected an error", name);
  if (lexer_has_errors(lexer)) {
    String_Vec errors = lexer_take_errors(lexer);
    CHECK(errors.len == 1, "%s: expected one error, got %zu", name, errors.len);
    if (errors.len > 0)
      CHECK(
          strstr(errors.data[0], message) != NULL, "%s: expected error containing %s, got %s", name, message,
          errors.data[0]);
    free_errors(&errors);
  }
  Token_Vec tokens = lexer_take_tokens(lexer);
  VEC_DEINIT(tokens);
  lexer_free(&lexer);
}

static void expect_error(const char *name, const char *source, const char *message) {
  expect_error_bytes(name, source, strlen(source), message);
}

static void test_keywords(void) {
  static const TokenType expected[] = {
      As,        Break, Case, Const, Continue, Defer, Else, Enum, Extern, False, Fn, For, If, In, Let,
      Move,      Mut,   New,  Null,  Return, SelfLower, SelfUpper, Struct, True, Type, Unsafe, Where, While,
      Switch,    Interface, Extend, Identifier, Identifier, Identifier, Identifier, Identifier, Identifier, Eof,
  };
  expect_tokens(
      "keywords",
      "as break case const continue defer else enum extern false fn for if in let move mut "
      "new null return self Self struct true type unsafe where while switch interface extend "
      "match trait impl name _ i32",
      expected, sizeof expected / sizeof expected[0]);
}

static void test_operators(void) {
  static const TokenType expected[] = {
      LeftBrace,
      RightBrace,
      LeftParen,
      RightParen,
      LeftBracket,
      RightBracket,
      Comma,
      Semicolon,
      Colon,
      Dot,
      Plus,
      Minus,
      Star,
      Slash,
      Percent,
      Tilde,
      Bang,
      Question,
      QuestionQuestion,
      EqualEqual,
      BangEqual,
      LessThan,
      LessThanEqual,
      GreaterThan,
      GreaterThanEqual,
      Ampersand,
      Pipe,
      Caret,
      AmpersandAmpersand,
      PipePipe,
      LeftShift,
      RightShift,
      Equal,
      PlusEqual,
      MinusEqual,
      StarEqual,
      SlashEqual,
      PercentEqual,
      AmpersandEqual,
      PipeEqual,
      CaretEqual,
      LeftShiftEqual,
      RightShiftEqual,
      Range,
      RangeInclusive,
      PathSeparator,
      Arrow,
      FatArrow,
      Eof,
  };
  expect_tokens(
      "operators",
      "{}()[],;:. + - * / % ~ ! ? ?? == != < <= > >= & | ^ && || << >> = += -= *= /= %= &= |= ^= "
      "<<= >>= .. ..= :: -> =>",
      expected, sizeof expected / sizeof expected[0]);
}

static void test_literals(void) {
  static const TokenType expected[] = {
      IntegerLiteral,   IntegerLiteral,       IntegerLiteral,   IntegerLiteral,   IntegerLiteral,   FloatLiteral,
      FloatLiteral,     FloatLiteral,         FloatLiteral,     StringLiteral,    StringLiteral,    CharacterLiteral,
      CharacterLiteral, ByteCharacterLiteral, RawStringLiteral, RawStringLiteral, RawStringLiteral, Eof,
  };
  expect_tokens(
      "literals",
      "0 0123 1_000 0xCAFE_BABE 0b1010_0110 "
      "1. 0.5 1e-3 1.0e+10 "
      "\"hello\\n\" \"\\xFF\\u{1F600}\" 'λ' '\\xFF' b'\\xFF' "
      "r\"raw\" r#\"raw \" quote\"# r##\"line\n\"# inside\"##",
      expected, sizeof expected / sizeof expected[0]);
}

static void test_ranges(void) {
  static const TokenType expected[] = {
      IntegerLiteral, Range, IntegerLiteral, IntegerLiteral, RangeInclusive, IntegerLiteral, Eof,
  };
  expect_tokens("ranges", "0..9 0..=9", expected, sizeof expected / sizeof expected[0]);
}

static void test_comments(void) {
  static const TokenType skipped[] = {Let, Identifier, Equal, IntegerLiteral, Semicolon, Eof};
  expect_tokens(
      "comments skipped", "/* outer /* inner */ done */ let x = 1; // end", skipped,
      sizeof skipped / sizeof skipped[0]);
}

static void test_errors(void) {
  expect_error("leading dot float", ".5", "require a digit before");
  expect_error("binary digit", "0b102", "invalid digit in binary");
  expect_error("hex digit", "0xFG", "invalid digit in hexadecimal");
  expect_error("octal digit", "0o789", "invalid digit in octal");
  expect_error("numeric suffix", "123abc", "invalid suffix");
  expect_error("double separator", "1__0", "invalid numeric separator");
  expect_error("prefix separator", "0x_FF", "invalid numeric separator");
  expect_error("fraction separator", "1._0", "invalid numeric separator");
  expect_error("exponent separator", "1e+_3", "invalid numeric separator");
  expect_error("hex float", "0x1.8p+2", "floating-point literals are not supported");
  expect_error("unknown escape", "\"\\q\"", "unknown escape");
  expect_error("short hex escape", "\"\\xF\"", "exactly two");
  expect_error("surrogate escape", "\"\\u{D800}\"", "not a valid Unicode scalar");
  expect_error("multichar", "'ab'", "exactly one Unicode scalar");
  expect_error("byte unicode", "b'λ'", "only ASCII");
  expect_error("byte unicode escape", "b'\\u{41}'", "Unicode escapes are not allowed");
  expect_error("normal newline", "\"a\nb\"", "unterminated string");
  expect_error("unterminated comment", "/* outer /* inner */", "unterminated block comment");
  expect_error("unicode identifier", "λ", "identifiers may contain only ASCII");
  expect_error("reserved hash", "#define", "no preprocessor");
  expect_error("reserved at", "@inline", "reserved for future attribute");
  expect_error("byte string", "b\"abc\"", "byte string literals are not supported");

  const char nul_source[] = {'a', 0, 'b'};
  expect_error_bytes("embedded NUL", nul_source, sizeof nul_source, "NUL byte is not allowed");

  const char invalid_utf8_source[] = {(char)0xC0, (char)0xAF};
  Lexer *lexer = lexer_new(invalid_utf8_source, sizeof invalid_utf8_source);
  lexer_scan_tokens(lexer);
  CHECK(lexer_has_errors(lexer), "invalid UTF-8: expected errors");
  Token_Vec tokens = lexer_take_tokens(lexer);
  VEC_DEINIT(tokens);
  lexer_free(&lexer);
}

static void test_bom(void) {
  static const char source[] = "\xEF\xBB\xBFlet x = 1;";
  static const TokenType expected[] = {Let, Identifier, Equal, IntegerLiteral, Semicolon, Eof};
  expect_tokens("leading BOM", source, expected, sizeof expected / sizeof expected[0]);
  expect_error("interior BOM", "let \xEF\xBB\xBFx = 1;", "BOM is allowed only");
}

static void test_raw_delimiter_limit(void) {
  const size_t hashes = 256;
  const size_t len = 1 + hashes + 1 + 1 + 1 + hashes;
  char *source = malloc(len + 1);
  size_t at = 0;
  source[at++] = 'r';
  memset(source + at, '#', hashes);
  at += hashes;
  source[at++] = '"';
  source[at++] = 'x';
  source[at++] = '"';
  memset(source + at, '#', hashes);
  at += hashes;
  source[at] = '\0';

  expect_error_bytes("raw delimiter limit", source, at, "more than 255");
  free(source);
}

// Token spans are byte ranges into the source; assert exact start/end across a small program.
static void test_spans(void) {
  static const char src[] = "let x = 10;";
  Lexer *lexer = lexer_new(src, strlen(src));
  lexer_scan_tokens(lexer);
  CHECK(!lexer_has_errors(lexer), "spans: unexpected error");
  Token_Vec t = lexer_take_tokens(lexer);
  // Let[0,3) Identifier[4,5) Equal[6,7) IntegerLiteral[8,10) Semicolon[10,11) Eof[11,11)
  CHECK(t.len == 6, "spans: expected 6 tokens, got %zu", t.len);
  if (t.len == 6) {
    CHECK(token_start(t.data[0]) == 0 && token_end(t.data[0]) == 3, "Let span [0,3)");
    CHECK(token_start(t.data[1]) == 4 && token_end(t.data[1]) == 5, "Identifier span [4,5)");
    CHECK(token_start(t.data[3]) == 8 && token_end(t.data[3]) == 10, "IntegerLiteral span [8,10)");
    CHECK(token_start(t.data[4]) == 10 && token_end(t.data[4]) == 11, "Semicolon span [10,11)");
    CHECK(token_type(t.data[5]) == Eof && token_start(t.data[5]) == 11, "EOF sits at end of input");
  }
  VEC_DEINIT(t);
  lexer_free(&lexer);
}

// The lexer recovers and keeps scanning, collecting more than one diagnostic.
static void test_multiple_errors(void) {
  static const char src[] = "@ @ @"; // three reserved-'@' errors
  Lexer *lexer = lexer_new(src, strlen(src));
  lexer_scan_tokens(lexer);
  CHECK(lexer_has_errors(lexer), "expected errors");
  String_Vec e = lexer_take_errors(lexer);
  CHECK(e.len >= 2, "lexer recovers and collects multiple errors (got %zu)", e.len);
  free_errors(&e);
  Token_Vec t = lexer_take_tokens(lexer);
  VEC_DEINIT(t);
  lexer_free(&lexer);
}

int main(void) {
  test_keywords();
  test_operators();
  test_literals();
  test_ranges();
  test_comments();
  test_spans();
  test_multiple_errors();
  test_errors();
  test_bom();
  test_raw_delimiter_limit();

  if (failures != 0) {
    fprintf(stderr, "%d lexer test(s) failed\n", failures);
    return 1;
  }
  puts("lexer tests passed");
  return 0;
}
