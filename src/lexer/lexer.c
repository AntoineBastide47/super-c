#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "lexer.h"
#include "token_type.h"

#define EOF_CH 0u

// clang-format off
#define ID 1
static const uint8_t is_id_part[256] = {
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,
    0,0,0,0,0,0,0,
    ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,
    0,0,0,0,ID,0,
    ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,ID,
    0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
};
#undef ID
// clang-format on

struct Lexer {
    const uint8_t *bytes;
    size_t len;
    size_t start;
    size_t current;

    Token_Vec tokens;
    ERRORS_VARIABLES;
};

typedef struct {
    Token *begin;
    Token *out;
    Token *end;
} TokenWriter;

Lexer *lexer_new(const char *source, const size_t len) {
  Lexer *l = calloc(1, sizeof *l);
  if (!l) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }

  l->bytes = (const uint8_t *)source;
  l->len = len;
  l->tokens = Token_Vec_init();
  ERRORS_INIT(l);
  return l;
}

void lexer_free(Lexer **l) {
  if (*l == NULL)
    return;

  VEC_DEINIT((*l)->tokens)
  ERRORS_DEINIT(l);
  free(*l);
  *l = NULL;
}

ALWAYS_INLINE bool is_eof(const Lexer *l) {
  return l->current >= l->len;
}

// Returns the scalar and writes its byte length. A zero length means invalid
// UTF-8. ASCII is handled by the caller.
static uint32_t decode_at_b(const Lexer *l, const uint8_t b, const size_t current, size_t *size) {
  uint32_t cp;
  uint32_t minimum;
  size_t width;

  if (b >= 0xC2 && b <= 0xDF) {
    width = 2;
    minimum = 0x80;
    cp = b & 0x1F;
  } else if (b >= 0xE0 && b <= 0xEF) {
    width = 3;
    minimum = 0x800;
    cp = b & 0x0F;
  } else if (b >= 0xF0 && b <= 0xF4) {
    width = 4;
    minimum = 0x10000;
    cp = b & 0x07;
  } else {
    *size = 0;
    return 0;
  }

  if (current + width > l->len) {
    *size = 0;
    return 0;
  }

  for (size_t i = 1; i < width; i++) {
    const uint8_t continuation = l->bytes[current + i];
    if ((continuation & 0xC0) != 0x80) {
      *size = 0;
      return 0;
    }
    cp = (cp << 6) | (continuation & 0x3F);
  }

  if (cp < minimum || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
    *size = 0;
    return 0;
  }

  *size = width;
  return cp;
}

static bool token_writer_grow(Lexer *l, TokenWriter *w) {
  const size_t used = w->begin == NULL ? 0 : (size_t)(w->out - w->begin);
  l->tokens.len = used;

  if (!Token_Vec_reserve(&l->tokens, used + 1))
    return false;

  w->begin = l->tokens.data;
  w->out = w->begin + used;
  w->end = w->begin + l->tokens.cap;
  return true;
}

ALWAYS_INLINE void token_writer_push(Lexer *l, TokenWriter *w, const Token token) {
  if (UNLIKELY(w->out == w->end) && !token_writer_grow(l, w)) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }
  *w->out++ = token;
}

ALWAYS_INLINE void add_token(Lexer *l, TokenWriter *w, const TokenType token_type) {
  token_writer_push(l, w, token_new(token_type, (uint32_t)l->start, (uint32_t)(l->current - l->start)));
}

ALWAYS_INLINE uint8_t peek_byte(const Lexer *l) {
  return is_eof(l) ? EOF_CH : l->bytes[l->current];
}

ALWAYS_INLINE uint8_t peek_byte_n(const Lexer *l, const size_t n) {
  return l->current + n >= l->len ? EOF_CH : l->bytes[l->current + n];
}

ALWAYS_INLINE bool match_byte(Lexer *l, const uint8_t expected) {
  if (peek_byte(l) != expected)
    return false;
  l->current++;
  return true;
}

COLD void lexer_error(Lexer *l, const char *message) {
  lexer_errorf(l, (uint32_t)l->start, (uint32_t)(l->current - l->start), "%s", message);
}

COLD void lexer_error_at(Lexer *l, size_t at, size_t len, const char *message) {
  lexer_errorf(l, (uint32_t)at, (uint32_t)len, "%s", message);
}

ALWAYS_INLINE bool is_dec(uint8_t b) {
  return b >= '0' && b <= '9';
}

ALWAYS_INLINE bool is_hex(uint8_t b) {
  return is_dec(b) || (b >= 'A' && b <= 'F') || (b >= 'a' && b <= 'f');
}

ALWAYS_INLINE bool is_oct(uint8_t b) {
  return b >= '0' && b <= '7';
}

ALWAYS_INLINE bool is_bin(uint8_t b) {
  return b == '0' || b == '1';
}

ALWAYS_INLINE int hex_value(uint8_t b) {
  if (b <= '9')
    return b - '0';
  if (b <= 'F')
    return b - 'A' + 10;
  return b - 'a' + 10;
}

static const uint8_t kw_first[256] = {
    ['a'] = 1, ['b'] = 1, ['c'] = 1, ['d'] = 1, ['e'] = 1, ['f'] = 1, ['i'] = 1, ['l'] = 1,
    ['m'] = 1, ['n'] = 1, ['r'] = 1, ['s'] = 1, ['t'] = 1, ['u'] = 1, ['w'] = 1, ['S'] = 1,
};

static TokenType keywords(const uint8_t *lexeme, size_t len) {
  if (!kw_first[lexeme[0]])
    return Identifier;

  switch (len) {
    case 2:
      switch (lexeme[0]) {
        case 'a':
          return lexeme[1] == 's' ? As : Identifier;
        case 'f':
          return lexeme[1] == 'n' ? Fn : Identifier;
        case 'i':
          if (lexeme[1] == 'f')
            return If;
          if (lexeme[1] == 'n')
            return In;
          return Identifier;
        default:
          return Identifier;
      }
    case 3:
      switch (lexeme[0]) {
        case 'f':
          return memcmp(lexeme, "for", 3) == 0 ? For : Identifier;
        case 'l':
          return memcmp(lexeme, "let", 3) == 0 ? Let : Identifier;
        case 'm':
          return memcmp(lexeme, "mut", 3) == 0 ? Mut : Identifier;
        case 'n':
          return memcmp(lexeme, "new", 3) == 0 ? New : Identifier;
        default:
          return Identifier;
      }
    case 4:
      switch (lexeme[0]) {
        case 'c':
          return memcmp(lexeme, "case", 4) == 0 ? Case : Identifier;
        case 'e':
          if (memcmp(lexeme, "else", 4) == 0)
            return Else;
          if (memcmp(lexeme, "enum", 4) == 0)
            return Enum;
          return Identifier;
        case 'i':
          return memcmp(lexeme, "impl", 4) == 0 ? Impl : Identifier;
        case 'm':
          return memcmp(lexeme, "move", 4) == 0 ? Move : Identifier;
        case 'n':
          return memcmp(lexeme, "null", 4) == 0 ? Null : Identifier;
        case 's':
          return memcmp(lexeme, "self", 4) == 0 ? SelfLower : Identifier;
        case 'S':
          return memcmp(lexeme, "Self", 4) == 0 ? SelfUpper : Identifier;
        case 't':
          if (memcmp(lexeme, "true", 4) == 0)
            return True;
          if (memcmp(lexeme, "type", 4) == 0)
            return Type;
          return Identifier;
        default:
          return Identifier;
      }
    case 5:
      switch (lexeme[0]) {
        case 'b':
          return memcmp(lexeme, "break", 5) == 0 ? Break : Identifier;
        case 'c':
          return memcmp(lexeme, "const", 5) == 0 ? Const : Identifier;
        case 'd':
          return memcmp(lexeme, "defer", 5) == 0 ? Defer : Identifier;
        case 'f':
          return memcmp(lexeme, "false", 5) == 0 ? False : Identifier;
        case 'm':
          return memcmp(lexeme, "match", 5) == 0 ? Match : Identifier;
        case 't':
          return memcmp(lexeme, "trait", 5) == 0 ? Trait : Identifier;
        case 'w':
          if (memcmp(lexeme, "where", 5) == 0)
            return Where;
          if (memcmp(lexeme, "while", 5) == 0)
            return While;
          return Identifier;
        default:
          return Identifier;
      }
    case 6:
      switch (lexeme[0]) {
        case 'e':
          return memcmp(lexeme, "extern", 6) == 0 ? Extern : Identifier;
        case 'r':
          return memcmp(lexeme, "return", 6) == 0 ? Return : Identifier;
        case 's':
          return memcmp(lexeme, "struct", 6) == 0 ? Struct : Identifier;
        case 'u':
          return memcmp(lexeme, "unsafe", 6) == 0 ? Unsafe : Identifier;
        default:
          return Identifier;
      }
    case 8:
      return memcmp(lexeme, "continue", 8) == 0 ? Continue : Identifier;
    default:
      return Identifier;
  }
}

static void identifier(Lexer *l, TokenWriter *w) {
  size_t i = l->current;
  const size_t len = l->len;
  const uint8_t *bytes = l->bytes;

  while (i < len && is_id_part[bytes[i]])
    i++;

  l->current = i;
  const size_t identifier_len = i - l->start;
  add_token(l, w, identifier_len > 8 ? Identifier : keywords(bytes + l->start, identifier_len));
}

static bool validate_utf8_at(Lexer *l, size_t *i) {
  size_t size = 0;
  decode_at_b(l, l->bytes[*i], *i, &size);
  if (UNLIKELY(size == 0)) {
    lexer_error_at(l, *i, 1, "source is not valid UTF-8");
    (*i)++;
    return false;
  }
  *i += size;
  return true;
}

static void whitespace(Lexer *l) {
  size_t i = l->current;
  const size_t len = l->len;
  const uint8_t *bytes = l->bytes;

  while (i < len) {
    switch (bytes[i]) {
      case ' ':
      case '\t':
      case '\n':
      case '\v':
      case '\f':
        i++;
        break;
      case '\r':
        i++;
        if (i < len && bytes[i] == '\n')
          i++;
        break;
      default:
        l->current = i;
        return;
    }
  }

  l->current = i;
}

static void line_comment(Lexer *l) {
  size_t i = l->current;
  const size_t len = l->len;
  const uint8_t *bytes = l->bytes;

  while (i < len) {
    const uint8_t b = bytes[i];
    if (b == '\n' || b == '\r')
      break;
    if (UNLIKELY(b == 0)) {
      lexer_error_at(l, i++, 1, "NUL byte is not allowed in comments");
    } else if (UNLIKELY(b >= 0x80)) {
      validate_utf8_at(l, &i);
    } else {
      i++;
    }
  }

  l->current = i;
}

static void block_comment(Lexer *l) {
  size_t i = l->current;
  const size_t len = l->len;
  const uint8_t *bytes = l->bytes;
  size_t depth = 1;

  while (i < len) {
    const uint8_t b = bytes[i];
    if (b == '/' && i + 1 < len && bytes[i + 1] == '*') {
      depth++;
      i += 2;
    } else if (b == '*' && i + 1 < len && bytes[i + 1] == '/') {
      i += 2;
      if (--depth == 0) {
        l->current = i;
        return;
      }
    } else if (UNLIKELY(b == 0)) {
      lexer_error_at(l, i++, 1, "NUL byte is not allowed in comments");
    } else if (UNLIKELY(b >= 0x80)) {
      validate_utf8_at(l, &i);
    } else {
      i++;
    }
  }

  l->current = i;
  lexer_error_at(l, l->start, 2, "unterminated block comment");
}

// Consumes an escape after its backslash. UINT32_MAX means malformed.
static uint32_t escape(Lexer *l, bool byte_character) {
  if (is_eof(l)) {
    lexer_error_at(l, l->current, 0, "unterminated escape sequence");
    return UINT32_MAX;
  }

  const size_t at = l->current - 1;
  const uint8_t escaped = l->bytes[l->current++];
  switch (escaped) {
    case 'n':
      return '\n';
    case 'r':
      return '\r';
    case 't':
      return '\t';
    case '\\':
      return '\\';
    case '\'':
      return '\'';
    case '"':
      if (!byte_character)
        return '"';
      break;
    case '0':
      return 0;
    case 'x':
      if (l->current + 2 <= l->len && is_hex(l->bytes[l->current]) && is_hex(l->bytes[l->current + 1])) {
        const uint32_t value = (uint32_t)((hex_value(l->bytes[l->current]) << 4) | hex_value(l->bytes[l->current + 1]));
        l->current += 2;
        return value;
      }
      lexer_error_at(l, at, l->current - at, "\\x escape requires exactly two hexadecimal digits");
      while (l->current < l->len && l->current < at + 4 && is_hex(l->bytes[l->current]))
        l->current++;
      return UINT32_MAX;
    case 'u': {
      if (byte_character) {
        if (match_byte(l, '{')) {
          while (is_hex(peek_byte(l)))
            l->current++;
          match_byte(l, '}');
        }
        lexer_error_at(l, at, l->current - at, "Unicode escapes are not allowed in byte character literals");
        return UINT32_MAX;
      }
      if (!match_byte(l, '{')) {
        lexer_error_at(l, at, l->current - at, "Unicode escape must use \\u{...} syntax");
        return UINT32_MAX;
      }

      uint32_t value = 0;
      size_t digits = 0;
      while (is_hex(peek_byte(l))) {
        if (digits < 6)
          value = (value << 4) | (uint32_t)hex_value(peek_byte(l));
        digits++;
        l->current++;
      }
      if (digits == 0 || digits > 6 || !match_byte(l, '}')) {
        lexer_error_at(l, at, l->current - at, "Unicode escape requires 1 to 6 hexadecimal digits");
        return UINT32_MAX;
      }
      if (value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) {
        lexer_error_at(l, at, l->current - at, "Unicode escape is not a valid Unicode scalar value");
        return UINT32_MAX;
      }
      return value;
    }
  }

  lexer_error_at(l, at, l->current - at, "unknown escape sequence");
  return UINT32_MAX;
}

static void string(Lexer *l, TokenWriter *w) {
  size_t i = l->current;
  const size_t len = l->len;
  const uint8_t *bytes = l->bytes;

  while (i < len) {
    const uint8_t b = bytes[i++];
    if (b == '"') {
      l->current = i;
      add_token(l, w, StringLiteral);
      return;
    }
    if (b == '\\') {
      l->current = i;
      escape(l, false);
      i = l->current;
    } else if (b == '\n' || b == '\r') {
      l->current = i - 1;
      lexer_error(l, "unterminated string literal");
      while (l->current < len) {
        const uint8_t recovery = bytes[l->current++];
        if (recovery == '"')
          break;
      }
      return;
    } else if (UNLIKELY(b == 0)) {
      lexer_error_at(l, i - 1, 1, "NUL byte is not allowed in string literals");
    } else if (UNLIKELY(b >= 0x80)) {
      i--;
      validate_utf8_at(l, &i);
    }
  }

  l->current = i;
  lexer_error(l, "unterminated string literal");
}

static void character(Lexer *l, TokenWriter *w, bool byte_character) {
  size_t count = 0;
  bool malformed = false;
  bool invalid_byte = false;

  while (!is_eof(l)) {
    const uint8_t b = l->bytes[l->current++];
    if (b == '\'') {
      if (!malformed && count != 1)
        lexer_error(
            l, byte_character ? "byte character literal must contain exactly one byte"
                              : "character literal must contain exactly one Unicode scalar value");
      else if (invalid_byte)
        lexer_error(l, "byte character literal may contain only ASCII or a \\xNN escape");
      add_token(l, w, byte_character ? ByteCharacterLiteral : CharacterLiteral);
      return;
    }
    if (b == '\n' || b == '\r') {
      l->current--;
      lexer_error(l, "unterminated character literal");
      return;
    }
    if (UNLIKELY(b == 0)) {
      lexer_error_at(l, l->current - 1, 1, "NUL byte is not allowed in character literals");
      count++;
    } else if (b == '\\') {
      if (escape(l, byte_character) == UINT32_MAX)
        malformed = true;
      else
        count++;
    } else if (LIKELY(b < 0x80)) {
      count++;
    } else {
      size_t size = 0;
      decode_at_b(l, b, l->current - 1, &size);
      if (UNLIKELY(size == 0)) {
        lexer_error_at(l, l->current - 1, 1, "source is not valid UTF-8");
        malformed = true;
      } else {
        l->current += size - 1;
        count++;
        invalid_byte = byte_character;
      }
    }
  }

  lexer_error(l, "unterminated character literal");
}

static bool raw_string_ahead(const Lexer *l, size_t *hashes) {
  size_t i = l->current;
  while (i < l->len && l->bytes[i] == '#')
    i++;
  if (i >= l->len || l->bytes[i] != '"')
    return false;
  *hashes = i - l->current;
  return true;
}

static void raw_string(Lexer *l, TokenWriter *w, size_t hashes) {
  if (hashes > 255)
    lexer_error_at(l, l->start, hashes + 1, "raw string delimiter contains more than 255 '#' characters");

  size_t i = l->current + hashes + 1;
  const size_t len = l->len;
  const uint8_t *bytes = l->bytes;

  while (i < len) {
    const uint8_t b = bytes[i];
    if (b == '"') {
      size_t close = i + 1;
      size_t matched = 0;
      while (matched < hashes && close < len && bytes[close] == '#') {
        close++;
        matched++;
      }
      if (matched == hashes) {
        l->current = close;
        add_token(l, w, RawStringLiteral);
        return;
      }
      i++;
    } else if (UNLIKELY(b == 0)) {
      lexer_error_at(l, i++, 1, "NUL byte is not allowed in raw string literals");
    } else if (UNLIKELY(b >= 0x80)) {
      validate_utf8_at(l, &i);
    } else {
      i++;
    }
  }

  l->current = i;
  lexer_error(l, "unterminated raw string literal");
}

#define DIGITS(l, is_digit, component_start, error_at)                                                                 \
  do {                                                                                                                 \
    size_t i = (l)->current;                                                                                           \
    const size_t len = (l)->len;                                                                                       \
    const uint8_t *bytes = (l)->bytes;                                                                                 \
    while (i < len) {                                                                                                  \
      const uint8_t b = bytes[i];                                                                                      \
      if (is_digit(b)) {                                                                                               \
        i++;                                                                                                           \
      } else if (b == '_') {                                                                                           \
        const bool prev = i > (component_start) && is_digit(bytes[i - 1]);                                             \
        const bool next = i + 1 < len && is_digit(bytes[i + 1]);                                                       \
        if ((!prev || !next) && *(error_at) == SIZE_MAX)                                                               \
          *(error_at) = i;                                                                                             \
        i++;                                                                                                           \
      } else {                                                                                                         \
        break;                                                                                                         \
      }                                                                                                                \
    }                                                                                                                  \
    (l)->current = i;                                                                                                  \
  } while (0)

static void number(Lexer *l, TokenWriter *w) {
  size_t error_at = SIZE_MAX;
  const char *error = NULL;
  bool is_float = false;

  if (l->bytes[l->start] == '0') {
    unsigned radix = 10;
    bool (*digit)(uint8_t) = is_dec;
    switch (peek_byte(l)) {
      case 'x':
      case 'X':
        radix = 16;
        digit = is_hex;
        break;
      case 'o':
      case 'O':
        radix = 8;
        digit = is_oct;
        break;
      case 'b':
      case 'B':
        radix = 2;
        digit = is_bin;
        break;
      default:
        break;
    }

    if (radix != 10) {
      l->current++;
      const size_t component_start = l->current;
      bool saw_digit = false;
      size_t i = l->current;
      while (i < l->len && is_id_part[l->bytes[i]]) {
        const uint8_t b = l->bytes[i];
        if (digit(b)) {
          saw_digit = true;
        } else if (b == '_') {
          const bool prev = i > component_start && digit(l->bytes[i - 1]);
          const bool next = i + 1 < l->len && digit(l->bytes[i + 1]);
          if ((!prev || !next) && error_at == SIZE_MAX) {
            error_at = i;
            error = "invalid numeric separator";
          }
        } else if (error_at == SIZE_MAX) {
          error_at = i;
          error = radix == 2   ? "invalid digit in binary literal"
                  : radix == 8 ? "invalid digit in octal literal"
                               : "invalid digit in hexadecimal literal";
        }
        i++;
      }
      l->current = i;

      if (!saw_digit && error_at == SIZE_MAX) {
        error_at = component_start;
        error = "radix prefix must be followed by at least one digit";
      }
      if (peek_byte(l) == '.') {
        if (error_at == SIZE_MAX) {
          error_at = l->current;
          error = "hexadecimal, octal, and binary floating-point literals are not supported";
        }
        l->current++;
        while (!is_eof(l)) {
          const uint8_t b = peek_byte(l);
          if (!is_id_part[b] && b != '.' && b != '+' && b != '-')
            break;
          l->current++;
        }
      }

      if (error_at != SIZE_MAX)
        lexer_error_at(l, error_at, 1, error);
      else
        add_token(l, w, IntegerLiteral);
      return;
    }
  }

  const size_t integer_start = l->current;
  DIGITS(l, is_dec, integer_start - 1, &error_at);
  if (error_at != SIZE_MAX)
    error = "invalid numeric separator";

  if (peek_byte(l) == '.' && peek_byte_n(l, 1) != '.') {
    is_float = true;
    l->current++;
    const size_t fraction_start = l->current;
    DIGITS(l, is_dec, fraction_start, &error_at);
    if (error_at != SIZE_MAX && error == NULL)
      error = "invalid numeric separator";
  }

  if (peek_byte(l) == 'e' || peek_byte(l) == 'E') {
    is_float = true;
    l->current++;
    if (peek_byte(l) == '+' || peek_byte(l) == '-')
      l->current++;
    const size_t exponent_start = l->current;
    DIGITS(l, is_dec, exponent_start, &error_at);
    if (l->current == exponent_start && error_at == SIZE_MAX) {
      error_at = exponent_start;
      error = "exponent requires at least one decimal digit";
    } else if (error_at != SIZE_MAX && error == NULL) {
      error = "invalid numeric separator";
    }
  }

  if (is_id_part[peek_byte(l)]) {
    if (error_at == SIZE_MAX) {
      error_at = l->current;
      error = "invalid suffix or trailing identifier characters after numeric literal";
    }
    while (is_id_part[peek_byte(l)])
      l->current++;
  }

  if (error_at != SIZE_MAX)
    lexer_error_at(l, error_at, 1, error);
  else
    add_token(l, w, is_float ? FloatLiteral : IntegerLiteral);
}

static void leading_dot_number(Lexer *l) {
  while (is_id_part[peek_byte(l)] || peek_byte(l) == '.')
    l->current++;
  lexer_error(l, "floating-point literals require a digit before the decimal point");
}

static void scan_token(Lexer *l, TokenWriter *w) {
  const uint8_t c = l->bytes[l->current];
  if (LIKELY(c < 0x80))
    l->current++;

#define EMIT(type)                                                                                                     \
  do {                                                                                                                 \
    add_token(l, w, type);                                                                                             \
    return;                                                                                                            \
  } while (0)

  switch (c) {
    case ' ':
    case '\t':
    case '\v':
    case '\f':
    case '\n':
    case '\r':
      whitespace(l);
      return;

    case '{':
      EMIT(LeftBrace);
    case '}':
      EMIT(RightBrace);
    case '(':
      EMIT(LeftParen);
    case ')':
      EMIT(RightParen);
    case '[':
      EMIT(LeftBracket);
    case ']':
      EMIT(RightBracket);
    case ',':
      EMIT(Comma);
    case ';':
      EMIT(Semicolon);
    case ':':
      EMIT(match_byte(l, ':') ? PathSeparator : Colon);

    case '~':
      EMIT(Tilde);
    case '%':
      EMIT(match_byte(l, '=') ? PercentEqual : Percent);
    case '^':
      EMIT(match_byte(l, '=') ? CaretEqual : Caret);
    case '+':
      EMIT(match_byte(l, '=') ? PlusEqual : Plus);
    case '-':
      if (match_byte(l, '>'))
        EMIT(Arrow);
      EMIT(match_byte(l, '=') ? MinusEqual : Minus);
    case '*':
      EMIT(match_byte(l, '=') ? StarEqual : Star);
    case '=':
      if (match_byte(l, '='))
        EMIT(EqualEqual);
      EMIT(match_byte(l, '>') ? FatArrow : Equal);
    case '!':
      EMIT(match_byte(l, '=') ? BangEqual : Bang);
    case '<':
      if (match_byte(l, '<'))
        EMIT(match_byte(l, '=') ? LeftShiftEqual : LeftShift);
      EMIT(match_byte(l, '=') ? LessThanEqual : LessThan);
    case '>':
      if (match_byte(l, '>'))
        EMIT(match_byte(l, '=') ? RightShiftEqual : RightShift);
      EMIT(match_byte(l, '=') ? GreaterThanEqual : GreaterThan);
    case '&':
      if (match_byte(l, '&'))
        EMIT(AmpersandAmpersand);
      EMIT(match_byte(l, '=') ? AmpersandEqual : Ampersand);
    case '|':
      if (match_byte(l, '|'))
        EMIT(PipePipe);
      EMIT(match_byte(l, '=') ? PipeEqual : Pipe);
    case '?':
      EMIT(match_byte(l, '?') ? QuestionQuestion : Question);
    case '/':
      if (match_byte(l, '/')) {
        line_comment(l);
      } else if (match_byte(l, '*')) {
        block_comment(l);
      } else {
        EMIT(match_byte(l, '=') ? SlashEqual : Slash);
      }
      return;

    case '.':
      if (is_dec(peek_byte(l))) {
        leading_dot_number(l);
      } else if (match_byte(l, '.')) {
        EMIT(match_byte(l, '=') ? RangeInclusive : Range);
      } else {
        EMIT(Dot);
      }
      return;

    case '"':
      string(l, w);
      return;
    case '\'':
      character(l, w, false);
      return;

    case '0':
    case '1':
    case '2':
    case '3':
    case '4':
    case '5':
    case '6':
    case '7':
    case '8':
    case '9':
      number(l, w);
      return;

    case 'r': {
      size_t hashes;
      if (raw_string_ahead(l, &hashes)) {
        raw_string(l, w, hashes);
        return;
      }
      identifier(l, w);
      return;
    }
    case 'b':
      if (peek_byte(l) == '\'') {
        l->current++;
        character(l, w, true);
      } else if (peek_byte(l) == '"') {
        l->current++;
        while (!is_eof(l) && peek_byte(l) != '"' && peek_byte(l) != '\n' && peek_byte(l) != '\r')
          l->current++;
        match_byte(l, '"');
        lexer_error(l, "byte string literals are not supported");
      } else {
        identifier(l, w);
      }
      return;

    case 'a':
    case 'c':
    case 'd':
    case 'e':
    case 'f':
    case 'g':
    case 'h':
    case 'i':
    case 'j':
    case 'k':
    case 'l':
    case 'm':
    case 'n':
    case 'o':
    case 'p':
    case 'q':
    case 's':
    case 't':
    case 'u':
    case 'v':
    case 'w':
    case 'x':
    case 'y':
    case 'z':
    case 'A':
    case 'B':
    case 'C':
    case 'D':
    case 'E':
    case 'F':
    case 'G':
    case 'H':
    case 'I':
    case 'J':
    case 'K':
    case 'L':
    case 'M':
    case 'N':
    case 'O':
    case 'P':
    case 'Q':
    case 'R':
    case 'S':
    case 'T':
    case 'U':
    case 'V':
    case 'W':
    case 'X':
    case 'Y':
    case 'Z':
    case '_':
      identifier(l, w);
      return;

    case '#':
      lexer_error_at(l, l->start, 1, "'#' is not valid in Super-C source; Super-C has no preprocessor");
      return;
    case '@':
      lexer_error_at(l, l->start, 1, "'@' is reserved for future attribute syntax");
      return;
    case '$':
      lexer_error_at(l, l->start, 1, "'$' is reserved");
      return;
    case '`':
      lexer_error_at(l, l->start, 1, "'`' is reserved");
      return;
    case 0:
      lexer_error_at(l, l->start, 1, "NUL byte is not allowed in source");
      return;

    default:
      if (c >= 0x80) {
        size_t size = 0;
        const uint32_t cp = decode_at_b(l, c, l->current, &size);
        if (size == 0) {
          lexer_error_at(l, l->start, 1, "source is not valid UTF-8");
          l->current++;
        } else {
          l->current += size;
          if (cp == 0xFEFF)
            lexer_error_at(l, l->start, size, "UTF-8 BOM is allowed only at the start of a file");
          else
            lexer_error_at(l, l->start, size, "identifiers may contain only ASCII letters, digits, and '_'");
        }
      } else {
        lexer_errorf(l, (uint32_t)l->start, 1, "unexpected character '%c'", c);
      }
      return;
  }

#undef EMIT
}

void lexer_scan_tokens(Lexer *l) {
  const size_t len = l->len;
  Token_Vec_reserve(&l->tokens, len / 5);

  TokenWriter w = {
      .begin = l->tokens.data,
      .out = l->tokens.data == NULL ? NULL : l->tokens.data + l->tokens.len,
      .end = l->tokens.data == NULL ? NULL : l->tokens.data + l->tokens.cap,
  };

  if (l->current == 0 && len >= 3 && l->bytes[0] == 0xEF && l->bytes[1] == 0xBB && l->bytes[2] == 0xBF)
    l->current = 3;

  while (l->current < len) {
    l->start = l->current;
    scan_token(l, &w);
  }

  token_writer_push(l, &w, token_new(Eof, (uint32_t)len, 0));
  l->tokens.len = w.begin == NULL ? 0 : (size_t)(w.out - w.begin);
  errors_finalize(&l->errors, &l->errors_start, &l->errors_len, l->bytes, len);
}

Token_Vec lexer_take_tokens(Lexer *l) {
  Token_Vec out = l->tokens;
  l->tokens = Token_Vec_init();
  return out;
}

ERRORS_BODY(Lexer, lexer, l)
