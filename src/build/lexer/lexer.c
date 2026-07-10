#include "../lexer/lexer.h"
#include "../string.h"
#include "../lexer/token.h"
#include "../lexer/token_type.h"
#include "../utils/errors.h"
#include "../__std/core.h"
#include "../__std/interfaces.h"
#include "../__std/option.h"
#include "../__std/range.h"
#include "../__std/result.h"
#include "../__std/slice.h"
#include "../__std/str.h"
#include "../__std/string.h"
#include "../__std/vector.h"

_Static_assert(sizeof(lexer__lexer__CharClass) == 256 && _Alignof(lexer__lexer__CharClass) == 1, "super-c layout model mismatch: lexer__lexer__CharClass");
_Static_assert(sizeof(lexer__lexer__Lexer) == 416 && _Alignof(lexer__lexer__Lexer) == 8, "super-c layout model mismatch: lexer__lexer__Lexer");

static __attribute__((unused)) lexer__lexer__CharClass lexer__lexer__build_char_class(void);
static __attribute__((unused)) bool lexer__lexer__is_eof(const lexer__lexer__Lexer *const l);
static __attribute__((unused)) bool lexer__lexer__is_id_start(uint8_t const b);
static __attribute__((unused)) bool lexer__lexer__is_id_part_byte(uint8_t const b);
static __attribute__((unused)) bool lexer__lexer__is_dec(uint8_t const b);
static __attribute__((unused)) bool lexer__lexer__is_hex(uint8_t const b);
static __attribute__((unused)) bool lexer__lexer__is_oct(uint8_t const b);
static __attribute__((unused)) bool lexer__lexer__is_bin(uint8_t const b);
static __attribute__((unused)) int32_t lexer__lexer__hex_value(uint8_t const b);
static __attribute__((unused)) void lexer__lexer__add_token(lexer__lexer__Lexer *const l, lexer__token_type__TokenType const token_type);
static __attribute__((unused)) void lexer__lexer__add_match(lexer__lexer__Lexer *const l, uint8_t const expected, lexer__token_type__TokenType const matched, lexer__token_type__TokenType const unmatched);
static __attribute__((unused)) uint8_t lexer__lexer__peek_byte(const lexer__lexer__Lexer *const l);
static __attribute__((unused)) uint8_t lexer__lexer__peek_byte_n(const lexer__lexer__Lexer *const l, size_t const n);
static __attribute__((unused)) bool lexer__lexer__match_byte(lexer__lexer__Lexer *const l, uint8_t const expected);
static __attribute__((cold, noinline, unused)) void lexer__lexer__lexer_error(lexer__lexer__Lexer *const l, str const message);
static __attribute__((cold, noinline, unused)) void lexer__lexer__lexer_error_at(lexer__lexer__Lexer *const l, size_t const at, size_t const len, str const message);
static __attribute__((unused)) uint32_t lexer__lexer__decode_at_b(const lexer__lexer__Lexer *const l, uint8_t const b, size_t const current, size_t *const size);
static __attribute__((unused)) bool lexer__lexer__memeq(const uint8_t *const p, str const text);
static __attribute__((unused)) lexer__token_type__TokenType lexer__lexer__keywords(const uint8_t *const lexeme, size_t const len);
static __attribute__((unused)) void lexer__lexer__identifier(lexer__lexer__Lexer *const l);
static __attribute__((unused)) bool lexer__lexer__validate_utf8_at(lexer__lexer__Lexer *const l, size_t *const i);
static __attribute__((unused)) void lexer__lexer__whitespace(lexer__lexer__Lexer *const l);
static __attribute__((unused)) void lexer__lexer__line_comment(lexer__lexer__Lexer *const l);
static __attribute__((unused)) void lexer__lexer__block_comment(lexer__lexer__Lexer *const l);
static __attribute__((unused)) uint32_t lexer__lexer__escape(lexer__lexer__Lexer *const l, bool const byte_character);
static __attribute__((unused)) void lexer__lexer__string_lit(lexer__lexer__Lexer *const l, lexer__token_type__TokenType const kind);
static __attribute__((unused)) bool lexer__lexer__label_ahead(const lexer__lexer__Lexer *const l);
static __attribute__((unused)) void lexer__lexer__character(lexer__lexer__Lexer *const l, bool const byte_character);
static __attribute__((unused)) bool lexer__lexer__raw_string_ahead(const lexer__lexer__Lexer *const l, size_t *const hashes);
static __attribute__((unused)) void lexer__lexer__raw_string(lexer__lexer__Lexer *const l, size_t const hashes);
static __attribute__((unused)) int32_t lexer__lexer__num_suffix_kind(const uint8_t *const p, size_t const n);
static __attribute__((unused)) void lexer__lexer__number(lexer__lexer__Lexer *const l);
static __attribute__((unused)) void lexer__lexer__scan_token(lexer__lexer__Lexer *const l);
static __attribute__((unused)) void lexer__lexer__digits__cb_lexer__lexer__is_dec(lexer__lexer__Lexer *const l, size_t const component_start, size_t *const error_at);

static __attribute__((unused)) void lexer__lexer__digits__cb_lexer__lexer__is_dec(lexer__lexer__Lexer *const l, size_t const component_start, size_t *const error_at) {
  size_t i = l->current;
  while (i < l->len) {
    const uint8_t b = l->bytes[i];
    if (lexer__lexer__is_dec(b)) {
      (i = (i + 1ULL));
    } else if (b == 95U) {
      const bool prev = ((i > component_start) && lexer__lexer__is_dec(l->bytes[(i - 1ULL)]));
      const bool next = (((i + 1ULL) < l->len) && lexer__lexer__is_dec(l->bytes[(i + 1ULL)]));
      if (((!prev) || (!next)) && ((*error_at) == lexer__lexer__USIZE_MAX)) {
        ((*error_at) = i);
      }
      (i = (i + 1ULL));
    } else {
      break;
    }
  }
  (l->current = i);
}

static __attribute__((unused)) lexer__lexer__CharClass lexer__lexer__build_char_class(void) {
  lexer__lexer__CharClass c = (lexer__lexer__CharClass){0};
  size_t i = 0ULL;
  while (i < 256ULL) {
    const uint8_t b = ((uint8_t)i);
    const bool is_lower = ((b >= (uint8_t)'a') && (b <= (uint8_t)'z'));
    const bool is_upper = ((b >= (uint8_t)'A') && (b <= (uint8_t)'Z'));
    const bool is_digit = ((b >= (uint8_t)'0') && (b <= (uint8_t)'9'));
    uint8_t fl = 0U;
    if (((b == (uint8_t)'_') || is_lower) || is_upper) {
      (fl = ((fl | lexer__lexer__CC_ID_START) | lexer__lexer__CC_ID_PART));
    }
    if (is_digit) {
      (fl = (((fl | lexer__lexer__CC_ID_PART) | lexer__lexer__CC_DIGIT) | lexer__lexer__CC_HEX));
    }
    if (((b >= (uint8_t)'a') && (b <= (uint8_t)'f')) || ((b >= (uint8_t)'A') && (b <= (uint8_t)'F'))) {
      (fl = (fl | lexer__lexer__CC_HEX));
    }
    if ((((((b == (uint8_t)' ') || (b == (uint8_t)'\t')) || (b == (uint8_t)'\n')) || (b == (uint8_t)'\x0b')) || (b == (uint8_t)'\x0c')) || (b == (uint8_t)'\r')) {
      (fl = (fl | lexer__lexer__CC_WS));
    }
    {
      (c.f[i] = fl);
    }
    (i = (i + 1ULL));
  }
  return c;
}

lexer__lexer__Lexer lexer__lexer__Lexer__new(String__Global *const source) {
  String__Global__pad_nul(source, lexer__lexer__SOURCE_PAD);
  const str s = String__Global__as_str(source);
  return (lexer__lexer__Lexer){ .bytes = str__ptr(&s), .len = str__len(&s), .start = 0ULL, .current = 0ULL, .file = NULL, .tokens = Vector__u64__Global__new(), .errors = utils__errors__Errors__new(), .class = lexer__lexer__build_char_class() };
}

void lexer__lexer__Lexer__set_file(lexer__lexer__Lexer *const self, const char *const file) {
  (self->file = file);
}

void lexer__lexer__Lexer__free(lexer__lexer__Lexer *const self) {
  Vector__u64__Global__free(&self->tokens);
  utils__errors__Errors__free(&self->errors);
}

static __attribute__((unused)) bool lexer__lexer__is_eof(const lexer__lexer__Lexer *const l) {
  return (l->current >= l->len);
}

static __attribute__((unused)) bool lexer__lexer__is_id_start(uint8_t const b) {
  return (((b == '_') || ((b >= 97U) && (b <= 122U))) || ((b >= 65U) && (b <= 90U)));
}

static __attribute__((unused)) bool lexer__lexer__is_id_part_byte(uint8_t const b) {
  return (lexer__lexer__is_id_start(b) || ((b >= 48U) && (b <= 57U)));
}

static __attribute__((unused)) bool lexer__lexer__is_dec(uint8_t const b) {
  return ((b >= 48U) && (b <= 57U));
}

static __attribute__((unused)) bool lexer__lexer__is_hex(uint8_t const b) {
  return ((lexer__lexer__is_dec(b) || ((b >= 65U) && (b <= 70U))) || ((b >= 97U) && (b <= 102U)));
}

static __attribute__((unused)) bool lexer__lexer__is_oct(uint8_t const b) {
  return ((b >= 48U) && (b <= 55U));
}

static __attribute__((unused)) bool lexer__lexer__is_bin(uint8_t const b) {
  return ((b == 48U) || (b == 49U));
}

static __attribute__((unused)) int32_t lexer__lexer__hex_value(uint8_t const b) {
  if (b <= 57U) {
    return ((int32_t)((uint8_t)((uint32_t)b - (uint32_t)48U)));
  }
  if (b <= 70U) {
    return ((int32_t)((uint8_t)((uint32_t)((uint8_t)((uint32_t)b - (uint32_t)65U)) + (uint32_t)10U)));
  }
  return ((int32_t)((uint8_t)((uint32_t)((uint8_t)((uint32_t)b - (uint32_t)97U)) + (uint32_t)10U)));
}

static __attribute__((unused)) void lexer__lexer__add_token(lexer__lexer__Lexer *const l, lexer__token_type__TokenType const token_type) {
  Vector__u64__Global__push(&l->tokens, lexer__token__Token__new(token_type, ((uint32_t)l->start), ((uint32_t)(l->current - l->start))));
}

static __attribute__((unused)) void lexer__lexer__add_match(lexer__lexer__Lexer *const l, uint8_t const expected, lexer__token_type__TokenType const matched, lexer__token_type__TokenType const unmatched) {
  const lexer__token_type__TokenType kind = ({
    lexer__token_type__TokenType __sc0;
    if (lexer__lexer__match_byte((&(*l)), expected)) {
      __sc0 = matched;
    } else {
      __sc0 = unmatched;
    }
    __sc0;
  });
  lexer__lexer__add_token((&(*l)), kind);
}

static __attribute__((unused)) uint8_t lexer__lexer__peek_byte(const lexer__lexer__Lexer *const l) {
  if (lexer__lexer__is_eof((&(*l)))) {
    return lexer__lexer__EOF_CH;
  }
  return l->bytes[l->current];
}

static __attribute__((unused)) uint8_t lexer__lexer__peek_byte_n(const lexer__lexer__Lexer *const l, size_t const n) {
  if ((l->current + n) >= l->len) {
    return lexer__lexer__EOF_CH;
  }
  return l->bytes[(l->current + n)];
}

static __attribute__((unused)) bool lexer__lexer__match_byte(lexer__lexer__Lexer *const l, uint8_t const expected) {
  if (lexer__lexer__peek_byte((&(*l))) != expected) {
    return false;
  }
  (l->current = (l->current + 1ULL));
  return true;
}

static __attribute__((cold, noinline, unused)) void lexer__lexer__lexer_error(lexer__lexer__Lexer *const l, str const message) {
  utils__errors__Errors__emit(&l->errors, ((uint32_t)l->start), ((uint32_t)(l->current - l->start)), String__Global__from_str(message));
}

static __attribute__((cold, noinline, unused)) void lexer__lexer__lexer_error_at(lexer__lexer__Lexer *const l, size_t const at, size_t const len, str const message) {
  utils__errors__Errors__emit(&l->errors, ((uint32_t)at), ((uint32_t)len), String__Global__from_str(message));
}

static __attribute__((unused)) uint32_t lexer__lexer__decode_at_b(const lexer__lexer__Lexer *const l, uint8_t const b, size_t const current, size_t *const size) {
  uint32_t minimum = 0x10000U;
  size_t width = 4ULL;
  if (b <= 0xDFU) {
    (minimum = 0x80U);
    (width = 2ULL);
  } else if (b <= 0xEFU) {
    (minimum = 0x800U);
    (width = 3ULL);
  }
  uint32_t cp = 0U;
  if ((b >= 0xC2U) && (b <= 0xDFU)) {
    (cp = ((uint32_t)(b & 0x1FU)));
  } else if ((b >= 0xE0U) && (b <= 0xEFU)) {
    (cp = ((uint32_t)(b & 0x0FU)));
  } else if ((b >= 0xF0U) && (b <= 0xF4U)) {
    (cp = ((uint32_t)(b & 0x07U)));
  } else {
    ((*size) = 0ULL);
    return 0U;
  }
  if ((current + width) > l->len) {
    ((*size) = 0ULL);
    return 0U;
  }
  for (size_t i = 1ULL; i < width; i++) {
    const uint8_t continuation = l->bytes[(current + i)];
    if ((continuation & 0xC0U) != 0x80U) {
      ((*size) = 0ULL);
      return 0U;
    }
    (cp = (({ uint32_t __sc1 = cp; int64_t __sc2 = (int64_t)(6U); if ((uint64_t)__sc2 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc1 << __sc2)); }) | ((uint32_t)(continuation & 0x3FU))));
  }
  if (((cp < minimum) || (cp > 0x10FFFFU)) || ((cp >= 0xD800U) && (cp <= 0xDFFFU))) {
    ((*size) = 0ULL);
    return 0U;
  }
  ((*size) = width);
  return cp;
}

static __attribute__((unused)) bool lexer__lexer__memeq(const uint8_t *const p, str const text) {
  return (memcmp(p, str__ptr(&text), str__len(&text)) == 0);
}

static __attribute__((unused)) lexer__token_type__TokenType lexer__lexer__keywords(const uint8_t *const lexeme, size_t const len) {
  const uint8_t first = lexeme[0];
  {
    const size_t __sc3 = len;
    if (__sc3 == 2) {
      {
        if ((first == 97U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"as", sizeof("as") - 1 })) {
          return lexer__token_type__TokenType_As;
        }
        if ((first == 100U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"do", sizeof("do") - 1 })) {
          return lexer__token_type__TokenType_Do;
        }
        if ((first == 102U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"fn", sizeof("fn") - 1 })) {
          return lexer__token_type__TokenType_Fn;
        }
        if ((first == 105U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"if", sizeof("if") - 1 })) {
          return lexer__token_type__TokenType_If;
        }
        if ((first == 105U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"in", sizeof("in") - 1 })) {
          return lexer__token_type__TokenType_In;
        }
      }
    }
    else if (__sc3 == 3) {
      {
        if ((first == 100U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"dyn", sizeof("dyn") - 1 })) {
          return lexer__token_type__TokenType_Dyn;
        }
        if ((first == 102U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"for", sizeof("for") - 1 })) {
          return lexer__token_type__TokenType_For;
        }
        if ((first == 108U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"let", sizeof("let") - 1 })) {
          return lexer__token_type__TokenType_Let;
        }
        if ((first == 109U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"mut", sizeof("mut") - 1 })) {
          return lexer__token_type__TokenType_Mut;
        }
        if ((first == 110U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"new", sizeof("new") - 1 })) {
          return lexer__token_type__TokenType_New;
        }
        if ((first == 112U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"pub", sizeof("pub") - 1 })) {
          return lexer__token_type__TokenType_Pub;
        }
      }
    }
    else if (__sc3 == 4) {
      {
        if ((first == 99U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"case", sizeof("case") - 1 })) {
          return lexer__token_type__TokenType_Case;
        }
        if ((first == 101U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"else", sizeof("else") - 1 })) {
          return lexer__token_type__TokenType_Else;
        }
        if ((first == 101U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"enum", sizeof("enum") - 1 })) {
          return lexer__token_type__TokenType_Enum;
        }
        if ((first == 108U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"loop", sizeof("loop") - 1 })) {
          return lexer__token_type__TokenType_Loop;
        }
        if ((first == 109U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"move", sizeof("move") - 1 })) {
          return lexer__token_type__TokenType_Move;
        }
        if ((first == 110U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"null", sizeof("null") - 1 })) {
          return lexer__token_type__TokenType_Null;
        }
        if ((first == 115U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"self", sizeof("self") - 1 })) {
          return lexer__token_type__TokenType_SelfLower;
        }
        if ((first == 83U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"Self", sizeof("Self") - 1 })) {
          return lexer__token_type__TokenType_SelfUpper;
        }
        if ((first == 116U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"true", sizeof("true") - 1 })) {
          return lexer__token_type__TokenType_True;
        }
        if ((first == 116U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"type", sizeof("type") - 1 })) {
          return lexer__token_type__TokenType_Type;
        }
      }
    }
    else if (__sc3 == 5) {
      {
        if ((first == 98U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"break", sizeof("break") - 1 })) {
          return lexer__token_type__TokenType_Break;
        }
        if ((first == 99U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"const", sizeof("const") - 1 })) {
          return lexer__token_type__TokenType_Const;
        }
        if ((first == 100U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"defer", sizeof("defer") - 1 })) {
          return lexer__token_type__TokenType_Defer;
        }
        if ((first == 102U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"false", sizeof("false") - 1 })) {
          return lexer__token_type__TokenType_False;
        }
        if ((first == 117U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"union", sizeof("union") - 1 })) {
          return lexer__token_type__TokenType_Union;
        }
        if ((first == 119U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"where", sizeof("where") - 1 })) {
          return lexer__token_type__TokenType_Where;
        }
        if ((first == 119U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"while", sizeof("while") - 1 })) {
          return lexer__token_type__TokenType_While;
        }
      }
    }
    else if (__sc3 == 6) {
      {
        if ((first == 101U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"extend", sizeof("extend") - 1 })) {
          return lexer__token_type__TokenType_Extend;
        }
        if ((first == 101U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"extern", sizeof("extern") - 1 })) {
          return lexer__token_type__TokenType_Extern;
        }
        if ((first == 105U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"import", sizeof("import") - 1 })) {
          return lexer__token_type__TokenType_Import;
        }
        if ((first == 114U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"return", sizeof("return") - 1 })) {
          return lexer__token_type__TokenType_Return;
        }
        if ((first == 115U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"struct", sizeof("struct") - 1 })) {
          return lexer__token_type__TokenType_Struct;
        }
        if ((first == 115U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"switch", sizeof("switch") - 1 })) {
          return lexer__token_type__TokenType_Switch;
        }
        if ((first == 115U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"sizeof", sizeof("sizeof") - 1 })) {
          return lexer__token_type__TokenType_Sizeof;
        }
        if ((first == 117U) && lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"unsafe", sizeof("unsafe") - 1 })) {
          return lexer__token_type__TokenType_Unsafe;
        }
      }
    }
    else if (__sc3 == 7) {
      {
        if (lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"alignof", sizeof("alignof") - 1 })) {
          return lexer__token_type__TokenType_Alignof;
        }
      }
    }
    else if (__sc3 == 8) {
      {
        if (lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"continue", sizeof("continue") - 1 })) {
          return lexer__token_type__TokenType_Continue;
        }
      }
    }
    else if (__sc3 == 9) {
      {
        if (lexer__lexer__memeq(lexeme, (str){ (const uint8_t *)"interface", sizeof("interface") - 1 })) {
          return lexer__token_type__TokenType_Interface;
        }
      }
    }
    else if (1) {
      {
      }
    }
  }
  return lexer__token_type__TokenType_Identifier;
}

static __attribute__((unused)) void lexer__lexer__identifier(lexer__lexer__Lexer *const l) {
  size_t i = l->current;
  while ((l->class.f[((size_t)l->bytes[i])] & lexer__lexer__CC_ID_PART) != 0U) {
    (i = (i + 1ULL));
  }
  (l->current = i);
  const size_t identifier_len = (i - l->start);
  lexer__token_type__TokenType kind = lexer__token_type__TokenType_Identifier;
  if (identifier_len <= 9ULL) {
    (kind = lexer__lexer__keywords((l->bytes + l->start), identifier_len));
  }
  lexer__lexer__add_token((&(*l)), kind);
}

static __attribute__((unused)) bool lexer__lexer__validate_utf8_at(lexer__lexer__Lexer *const l, size_t *const i) {
  size_t size = 0ULL;
  lexer__lexer__decode_at_b((&(*l)), l->bytes[(*i)], (*i), (&size));
  if (size == 0ULL) {
    lexer__lexer__lexer_error_at((&(*l)), (*i), 1ULL, (str){ (const uint8_t *)"source is not valid UTF-8", sizeof("source is not valid UTF-8") - 1 });
    ((*i) = ((*i) + 1ULL));
    return false;
  }
  ((*i) = ((*i) + size));
  return true;
}

static __attribute__((unused)) void lexer__lexer__whitespace(lexer__lexer__Lexer *const l) {
  size_t i = l->current;
  while ((l->class.f[((size_t)l->bytes[i])] & lexer__lexer__CC_WS) != 0U) {
    (i = (i + 1ULL));
  }
  (l->current = i);
}

static __attribute__((unused)) void lexer__lexer__line_comment(lexer__lexer__Lexer *const l) {
  size_t i = l->current;
  while (i < l->len) {
    const uint8_t b = l->bytes[i];
    if ((b == (uint8_t)'\n') || (b == (uint8_t)'\r')) {
      break;
    }
    if (b == (uint8_t)'\0') {
      lexer__lexer__lexer_error_at((&(*l)), i, 1ULL, (str){ (const uint8_t *)"NUL byte is not allowed in comments", sizeof("NUL byte is not allowed in comments") - 1 });
      (i = (i + 1ULL));
    } else if (b >= 0x80U) {
      lexer__lexer__validate_utf8_at((&(*l)), (&i));
    } else {
      (i = (i + 1ULL));
    }
  }
  (l->current = i);
}

static __attribute__((unused)) void lexer__lexer__block_comment(lexer__lexer__Lexer *const l) {
  size_t i = l->current;
  size_t depth = 1ULL;
  while (i < l->len) {
    const uint8_t b = l->bytes[i];
    if (((b == 47U) && ((i + 1ULL) < l->len)) && (l->bytes[(i + 1ULL)] == 42U)) {
      (depth = (depth + 1ULL));
      (i = (i + 2ULL));
    } else if (((b == 42U) && ((i + 1ULL) < l->len)) && (l->bytes[(i + 1ULL)] == 47U)) {
      (i = (i + 2ULL));
      (depth = (depth - 1ULL));
      if (depth == 0ULL) {
        (l->current = i);
        return;
      }
    } else if (b == (uint8_t)'\0') {
      lexer__lexer__lexer_error_at((&(*l)), i, 1ULL, (str){ (const uint8_t *)"NUL byte is not allowed in comments", sizeof("NUL byte is not allowed in comments") - 1 });
      (i = (i + 1ULL));
    } else if (b >= 0x80U) {
      lexer__lexer__validate_utf8_at((&(*l)), (&i));
    } else {
      (i = (i + 1ULL));
    }
  }
  (l->current = i);
  const size_t start = l->start;
  lexer__lexer__lexer_error_at((&(*l)), start, 2ULL, (str){ (const uint8_t *)"unterminated block comment", sizeof("unterminated block comment") - 1 });
}

static __attribute__((unused)) uint32_t lexer__lexer__escape(lexer__lexer__Lexer *const l, bool const byte_character) {
  if (lexer__lexer__is_eof((&(*l)))) {
    const size_t current = l->current;
    lexer__lexer__lexer_error_at((&(*l)), current, 0ULL, (str){ (const uint8_t *)"unterminated escape sequence", sizeof("unterminated escape sequence") - 1 });
    return lexer__lexer__UINT32_MAX;
  }
  const size_t at = (l->current - 1ULL);
  const uint8_t escaped = l->bytes[l->current];
  (l->current = (l->current + 1ULL));
  if (escaped == 110U) {
    return 10U;
  }
  if (escaped == 114U) {
    return 13U;
  }
  if (escaped == 116U) {
    return 9U;
  }
  if (escaped == 92U) {
    return 92U;
  }
  if (escaped == 39U) {
    return 39U;
  }
  if ((escaped == 34U) && (!byte_character)) {
    return 34U;
  }
  if (escaped == 48U) {
    return 0U;
  }
  if (escaped == 120U) {
    if ((((l->current + 2ULL) <= l->len) && lexer__lexer__is_hex(l->bytes[l->current])) && lexer__lexer__is_hex(l->bytes[(l->current + 1ULL)])) {
      const uint32_t value = ((uint32_t)(({ int32_t __sc4 = lexer__lexer__hex_value(l->bytes[l->current]); int64_t __sc5 = (int64_t)(4); if ((uint64_t)__sc5 >= 32) { __sc_panic("shift out of range"); } (int32_t)((uint32_t)((uint32_t)__sc4 << __sc5)); }) | lexer__lexer__hex_value(l->bytes[(l->current + 1ULL)])));
      (l->current = (l->current + 2ULL));
      return value;
    }
    const size_t err_len = (l->current - at);
    lexer__lexer__lexer_error_at((&(*l)), at, err_len, (str){ (const uint8_t *)"\\x escape requires exactly two hexadecimal digits", sizeof("\\x escape requires exactly two hexadecimal digits") - 1 });
    while (((l->current < l->len) && (l->current < (at + 4ULL))) && lexer__lexer__is_hex(l->bytes[l->current])) {
      (l->current = (l->current + 1ULL));
    }
    return lexer__lexer__UINT32_MAX;
  }
  if (escaped == 117U) {
    if (byte_character) {
      if (lexer__lexer__match_byte((&(*l)), 123U)) {
        while (lexer__lexer__is_hex(lexer__lexer__peek_byte((&(*l))))) {
          (l->current = (l->current + 1ULL));
        }
        lexer__lexer__match_byte((&(*l)), 125U);
      }
      const size_t err_len = (l->current - at);
      lexer__lexer__lexer_error_at((&(*l)), at, err_len, (str){ (const uint8_t *)"Unicode escapes are not allowed in byte character literals", sizeof("Unicode escapes are not allowed in byte character literals") - 1 });
      return lexer__lexer__UINT32_MAX;
    }
    if (!lexer__lexer__match_byte((&(*l)), 123U)) {
      const size_t err_len = (l->current - at);
      lexer__lexer__lexer_error_at((&(*l)), at, err_len, (str){ (const uint8_t *)"Unicode escape must use \\u{...} syntax", sizeof("Unicode escape must use \\u{...} syntax") - 1 });
      return lexer__lexer__UINT32_MAX;
    }
    uint32_t value = 0U;
    size_t digits = 0ULL;
    while (lexer__lexer__is_hex(lexer__lexer__peek_byte((&(*l))))) {
      if (digits < 6ULL) {
        (value = (({ uint32_t __sc6 = value; int64_t __sc7 = (int64_t)(4U); if ((uint64_t)__sc7 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc6 << __sc7)); }) | ((uint32_t)lexer__lexer__hex_value(lexer__lexer__peek_byte((&(*l)))))));
      }
      (digits = (digits + 1ULL));
      (l->current = (l->current + 1ULL));
    }
    if (((digits == 0ULL) || (digits > 6ULL)) || (!lexer__lexer__match_byte((&(*l)), 125U))) {
      const size_t err_len = (l->current - at);
      lexer__lexer__lexer_error_at((&(*l)), at, err_len, (str){ (const uint8_t *)"Unicode escape requires 1 to 6 hexadecimal digits", sizeof("Unicode escape requires 1 to 6 hexadecimal digits") - 1 });
      return lexer__lexer__UINT32_MAX;
    }
    if ((value > 0x10FFFFU) || ((value >= 0xD800U) && (value <= 0xDFFFU))) {
      const size_t err_len = (l->current - at);
      lexer__lexer__lexer_error_at((&(*l)), at, err_len, (str){ (const uint8_t *)"Unicode escape is not a valid Unicode scalar value", sizeof("Unicode escape is not a valid Unicode scalar value") - 1 });
      return lexer__lexer__UINT32_MAX;
    }
    return value;
  }
  const size_t err_len = (l->current - at);
  lexer__lexer__lexer_error_at((&(*l)), at, err_len, (str){ (const uint8_t *)"unknown escape sequence", sizeof("unknown escape sequence") - 1 });
  return lexer__lexer__UINT32_MAX;
}

static __attribute__((unused)) void lexer__lexer__string_lit(lexer__lexer__Lexer *const l, lexer__token_type__TokenType const kind) {
  size_t i = l->current;
  while (i < l->len) {
    const uint8_t b = l->bytes[i];
    (i = (i + 1ULL));
    if (b == 34U) {
      (l->current = i);
      lexer__lexer__add_token((&(*l)), kind);
      return;
    }
    if (b == 92U) {
      (l->current = i);
      lexer__lexer__escape((&(*l)), false);
      (i = l->current);
    } else if ((b == (uint8_t)'\n') || (b == (uint8_t)'\r')) {
      (l->current = (i - 1ULL));
      lexer__lexer__lexer_error((&(*l)), (str){ (const uint8_t *)"unterminated string literal", sizeof("unterminated string literal") - 1 });
      while (l->current < l->len) {
        const uint8_t recovery = l->bytes[l->current];
        (l->current = (l->current + 1ULL));
        if (recovery == 34U) {
          break;
        }
      }
      return;
    } else if (b == (uint8_t)'\0') {
      lexer__lexer__lexer_error_at((&(*l)), (i - 1ULL), 1ULL, (str){ (const uint8_t *)"NUL byte is not allowed in string literals", sizeof("NUL byte is not allowed in string literals") - 1 });
    } else if (b >= 0x80U) {
      (i = (i - 1ULL));
      lexer__lexer__validate_utf8_at((&(*l)), (&i));
    }
  }
  (l->current = i);
  lexer__lexer__lexer_error((&(*l)), (str){ (const uint8_t *)"unterminated string literal", sizeof("unterminated string literal") - 1 });
}

static __attribute__((unused)) bool lexer__lexer__label_ahead(const lexer__lexer__Lexer *const l) {
  size_t i = l->current;
  uint8_t b = 0U;
  if (i < l->len) {
    (b = l->bytes[i]);
  }
  if (!lexer__lexer__is_id_start(b)) {
    return false;
  }
  while ((i < l->len) && lexer__lexer__is_id_part_byte(l->bytes[i])) {
    (i = (i + 1ULL));
  }
  return ((i >= l->len) || (l->bytes[i] != 39U));
}

static __attribute__((unused)) void lexer__lexer__character(lexer__lexer__Lexer *const l, bool const byte_character) {
  size_t count = 0ULL;
  bool malformed = false;
  bool invalid_byte = false;
  while (!lexer__lexer__is_eof((&(*l)))) {
    const uint8_t b = l->bytes[l->current];
    (l->current = (l->current + 1ULL));
    if (b == 39U) {
      if ((!malformed) && (count != 1ULL)) {
        if (byte_character) {
          lexer__lexer__lexer_error((&(*l)), (str){ (const uint8_t *)"byte character literal must contain exactly one byte", sizeof("byte character literal must contain exactly one byte") - 1 });
        } else {
          lexer__lexer__lexer_error((&(*l)), (str){ (const uint8_t *)"character literal must contain exactly one Unicode scalar value", sizeof("character literal must contain exactly one Unicode scalar value") - 1 });
        }
      } else if (invalid_byte) {
        lexer__lexer__lexer_error((&(*l)), (str){ (const uint8_t *)"byte character literal may contain only ASCII or a \\xNN escape", sizeof("byte character literal may contain only ASCII or a \\xNN escape") - 1 });
      }
      if (byte_character) {
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_ByteCharacterLiteral);
      } else {
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_CharacterLiteral);
      }
      return;
    }
    if ((b == (uint8_t)'\n') || (b == (uint8_t)'\r')) {
      (l->current = (l->current - 1ULL));
      lexer__lexer__lexer_error((&(*l)), (str){ (const uint8_t *)"unterminated character literal", sizeof("unterminated character literal") - 1 });
      return;
    }
    if (b == (uint8_t)'\0') {
      const size_t at = (l->current - 1ULL);
      lexer__lexer__lexer_error_at((&(*l)), at, 1ULL, (str){ (const uint8_t *)"NUL byte is not allowed in character literals", sizeof("NUL byte is not allowed in character literals") - 1 });
      (count = (count + 1ULL));
    } else if (b == 92U) {
      if (lexer__lexer__escape((&(*l)), byte_character) == lexer__lexer__UINT32_MAX) {
        (malformed = true);
      } else {
        (count = (count + 1ULL));
      }
    } else if (b < 0x80U) {
      (count = (count + 1ULL));
    } else {
      size_t size = 0ULL;
      lexer__lexer__decode_at_b((&(*l)), b, (l->current - 1ULL), (&size));
      if (size == 0ULL) {
        const size_t at = (l->current - 1ULL);
        lexer__lexer__lexer_error_at((&(*l)), at, 1ULL, (str){ (const uint8_t *)"source is not valid UTF-8", sizeof("source is not valid UTF-8") - 1 });
        (malformed = true);
      } else {
        (l->current = ((l->current + size) - 1ULL));
        (count = (count + 1ULL));
        (invalid_byte = byte_character);
      }
    }
  }
  lexer__lexer__lexer_error((&(*l)), (str){ (const uint8_t *)"unterminated character literal", sizeof("unterminated character literal") - 1 });
}

static __attribute__((unused)) bool lexer__lexer__raw_string_ahead(const lexer__lexer__Lexer *const l, size_t *const hashes) {
  size_t i = l->current;
  while ((i < l->len) && (l->bytes[i] == 35U)) {
    (i = (i + 1ULL));
  }
  if ((i >= l->len) || (l->bytes[i] != 34U)) {
    return false;
  }
  ((*hashes) = (i - l->current));
  return true;
}

static __attribute__((unused)) void lexer__lexer__raw_string(lexer__lexer__Lexer *const l, size_t const hashes) {
  if (hashes > 255ULL) {
    const size_t start = l->start;
    lexer__lexer__lexer_error_at((&(*l)), start, (hashes + 1ULL), (str){ (const uint8_t *)"raw string delimiter contains more than 255 '#' characters", sizeof("raw string delimiter contains more than 255 '#' characters") - 1 });
  }
  size_t i = ((l->current + hashes) + 1ULL);
  while (i < l->len) {
    const uint8_t b = l->bytes[i];
    if (b == 34U) {
      size_t close = (i + 1ULL);
      size_t matched = 0ULL;
      while (((matched < hashes) && (close < l->len)) && (l->bytes[close] == 35U)) {
        (close = (close + 1ULL));
        (matched = (matched + 1ULL));
      }
      if (matched == hashes) {
        (l->current = close);
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_RawStringLiteral);
        return;
      }
      (i = (i + 1ULL));
    } else if (b == (uint8_t)'\0') {
      lexer__lexer__lexer_error_at((&(*l)), i, 1ULL, (str){ (const uint8_t *)"NUL byte is not allowed in raw string literals", sizeof("NUL byte is not allowed in raw string literals") - 1 });
      (i = (i + 1ULL));
    } else if (b >= 0x80U) {
      lexer__lexer__validate_utf8_at((&(*l)), (&i));
    } else {
      (i = (i + 1ULL));
    }
  }
  (l->current = i);
  lexer__lexer__lexer_error((&(*l)), (str){ (const uint8_t *)"unterminated raw string literal", sizeof("unterminated raw string literal") - 1 });
}

static __attribute__((unused)) int32_t lexer__lexer__num_suffix_kind(const uint8_t *const p, size_t const n) {
  if ((n == 3ULL) && (lexer__lexer__memeq(p, (str){ (const uint8_t *)"f32", sizeof("f32") - 1 }) || lexer__lexer__memeq(p, (str){ (const uint8_t *)"f64", sizeof("f64") - 1 }))) {
    return 1;
  }
  if ((((n == 2ULL) && (lexer__lexer__memeq(p, (str){ (const uint8_t *)"i8", sizeof("i8") - 1 }) || lexer__lexer__memeq(p, (str){ (const uint8_t *)"u8", sizeof("u8") - 1 }))) || ((n == 3ULL) && (((((lexer__lexer__memeq(p, (str){ (const uint8_t *)"i16", sizeof("i16") - 1 }) || lexer__lexer__memeq(p, (str){ (const uint8_t *)"i32", sizeof("i32") - 1 })) || lexer__lexer__memeq(p, (str){ (const uint8_t *)"i64", sizeof("i64") - 1 })) || lexer__lexer__memeq(p, (str){ (const uint8_t *)"u16", sizeof("u16") - 1 })) || lexer__lexer__memeq(p, (str){ (const uint8_t *)"u32", sizeof("u32") - 1 })) || lexer__lexer__memeq(p, (str){ (const uint8_t *)"u64", sizeof("u64") - 1 })))) || ((n == 5ULL) && (lexer__lexer__memeq(p, (str){ (const uint8_t *)"isize", sizeof("isize") - 1 }) || lexer__lexer__memeq(p, (str){ (const uint8_t *)"usize", sizeof("usize") - 1 })))) {
    return 0;
  }
  return -1;
}

static __attribute__((unused)) void lexer__lexer__number(lexer__lexer__Lexer *const l) {
  size_t error_at = lexer__lexer__USIZE_MAX;
  str error = (str){ (const uint8_t *)"", sizeof("") - 1 };
  bool is_float = false;
  if (l->bytes[l->start] == 48U) {
    uint32_t radix = 10U;
    bool (*digit)(uint8_t) = lexer__lexer__is_dec;
    const uint8_t prefix = lexer__lexer__peek_byte((&(*l)));
    if ((prefix == 120U) || (prefix == 88U)) {
      (radix = 16U);
      (digit = lexer__lexer__is_hex);
    } else if ((prefix == 111U) || (prefix == 79U)) {
      (radix = 8U);
      (digit = lexer__lexer__is_oct);
    } else if ((prefix == 98U) || (prefix == 66U)) {
      (radix = 2U);
      (digit = lexer__lexer__is_bin);
    }
    if (radix != 10U) {
      (l->current = (l->current + 1ULL));
      const size_t component_start = l->current;
      bool saw_digit = false;
      size_t i = l->current;
      while ((i < l->len) && lexer__lexer__is_id_part_byte(l->bytes[i])) {
        const uint8_t b = l->bytes[i];
        if (digit(b)) {
          (saw_digit = true);
        } else if (b == 95U) {
          const bool prev = ((i > component_start) && digit(l->bytes[(i - 1ULL)]));
          const bool next = (((i + 1ULL) < l->len) && digit(l->bytes[(i + 1ULL)]));
          if (((!prev) || (!next)) && (error_at == lexer__lexer__USIZE_MAX)) {
            (error_at = i);
            (error = (str){ (const uint8_t *)"invalid numeric separator", sizeof("invalid numeric separator") - 1 });
          }
        } else {
          if (((radix == 16U) && saw_digit) && ((b == 112U) || (b == 80U))) {
            break;
          }
          size_t j = i;
          while ((j < l->len) && lexer__lexer__is_id_part_byte(l->bytes[j])) {
            (j = (j + 1ULL));
          }
          if (saw_digit && (lexer__lexer__num_suffix_kind((l->bytes + i), (j - i)) == 0)) {
            (i = j);
            break;
          }
          if (error_at == lexer__lexer__USIZE_MAX) {
            (error_at = i);
            if (radix == 2U) {
              (error = (str){ (const uint8_t *)"invalid digit in binary literal", sizeof("invalid digit in binary literal") - 1 });
            } else if (radix == 8U) {
              (error = (str){ (const uint8_t *)"invalid digit in octal literal", sizeof("invalid digit in octal literal") - 1 });
            } else {
              (error = (str){ (const uint8_t *)"invalid digit in hexadecimal literal", sizeof("invalid digit in hexadecimal literal") - 1 });
            }
          }
        }
        (i = (i + 1ULL));
      }
      (l->current = i);
      if ((!saw_digit) && (error_at == lexer__lexer__USIZE_MAX)) {
        (error_at = component_start);
        (error = (str){ (const uint8_t *)"radix prefix must be followed by at least one digit", sizeof("radix prefix must be followed by at least one digit") - 1 });
      }
      bool hex_float = false;
      if ((((radix == 16U) && (error_at == lexer__lexer__USIZE_MAX)) && (lexer__lexer__peek_byte((&(*l))) == 46U)) && lexer__lexer__is_hex(lexer__lexer__peek_byte_n((&(*l)), 1ULL))) {
        (hex_float = true);
        (l->current = (l->current + 1ULL));
        while (lexer__lexer__is_hex(lexer__lexer__peek_byte((&(*l))))) {
          (l->current = (l->current + 1ULL));
        }
      }
      if (((radix == 16U) && (error_at == lexer__lexer__USIZE_MAX)) && ((lexer__lexer__peek_byte((&(*l))) == 112U) || (lexer__lexer__peek_byte((&(*l))) == 80U))) {
        (hex_float = true);
        (l->current = (l->current + 1ULL));
        if ((lexer__lexer__peek_byte((&(*l))) == 43U) || (lexer__lexer__peek_byte((&(*l))) == 45U)) {
          (l->current = (l->current + 1ULL));
        }
        const size_t exp_start = l->current;
        while (lexer__lexer__is_dec(lexer__lexer__peek_byte((&(*l))))) {
          (l->current = (l->current + 1ULL));
        }
        if (l->current == exp_start) {
          (error_at = exp_start);
          (error = (str){ (const uint8_t *)"hexadecimal float exponent requires at least one decimal digit", sizeof("hexadecimal float exponent requires at least one decimal digit") - 1 });
        } else if (lexer__lexer__is_id_part_byte(lexer__lexer__peek_byte((&(*l))))) {
          const size_t sfx = l->current;
          while (lexer__lexer__is_id_part_byte(lexer__lexer__peek_byte((&(*l))))) {
            (l->current = (l->current + 1ULL));
          }
          if (lexer__lexer__num_suffix_kind((l->bytes + sfx), (l->current - sfx)) != 1) {
            (error_at = sfx);
            (error = (str){ (const uint8_t *)"a hexadecimal float takes only an 'f32' or 'f64' suffix", sizeof("a hexadecimal float takes only an 'f32' or 'f64' suffix") - 1 });
          }
        }
      } else if (hex_float && (error_at == lexer__lexer__USIZE_MAX)) {
        (error_at = l->current);
        (error = (str){ (const uint8_t *)"a hexadecimal float requires a binary exponent ('p'), e.g. 0x1.8p3", sizeof("a hexadecimal float requires a binary exponent ('p'), e.g. 0x1.8p3") - 1 });
      }
      if ((!hex_float) && (lexer__lexer__peek_byte((&(*l))) == 46U)) {
        if (error_at == lexer__lexer__USIZE_MAX) {
          (error_at = l->current);
          if (radix == 16U) {
            (error = (str){ (const uint8_t *)"a hexadecimal float needs a fraction digit and a binary exponent: 0x1.8p3", sizeof("a hexadecimal float needs a fraction digit and a binary exponent: 0x1.8p3") - 1 });
          } else {
            (error = (str){ (const uint8_t *)"octal and binary floating-point literals are not supported", sizeof("octal and binary floating-point literals are not supported") - 1 });
          }
        }
        (l->current = (l->current + 1ULL));
        while (!lexer__lexer__is_eof((&(*l)))) {
          const uint8_t b = lexer__lexer__peek_byte((&(*l)));
          if ((((!lexer__lexer__is_id_part_byte(b)) && (b != 46U)) && (b != 43U)) && (b != 45U)) {
            break;
          }
          (l->current = (l->current + 1ULL));
        }
      }
      if (error_at != lexer__lexer__USIZE_MAX) {
        lexer__lexer__lexer_error_at((&(*l)), error_at, 1ULL, error);
      } else {
        if (hex_float) {
          lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_FloatLiteral);
        } else {
          lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_IntegerLiteral);
        }
      }
      return;
    }
  }
  const size_t integer_start = l->current;
  lexer__lexer__digits__cb_lexer__lexer__is_dec((&(*l)), (integer_start - 1ULL), (&error_at));
  if (error_at != lexer__lexer__USIZE_MAX) {
    (error = (str){ (const uint8_t *)"invalid numeric separator", sizeof("invalid numeric separator") - 1 });
  }
  if ((lexer__lexer__peek_byte((&(*l))) == 46U) && (lexer__lexer__peek_byte_n((&(*l)), 1ULL) != 46U)) {
    (is_float = true);
    (l->current = (l->current + 1ULL));
    const size_t fraction_start = l->current;
    lexer__lexer__digits__cb_lexer__lexer__is_dec((&(*l)), fraction_start, (&error_at));
    if ((error_at != lexer__lexer__USIZE_MAX) && (str__len(&error) == 0ULL)) {
      (error = (str){ (const uint8_t *)"invalid numeric separator", sizeof("invalid numeric separator") - 1 });
    }
  }
  if ((lexer__lexer__peek_byte((&(*l))) == 101U) || (lexer__lexer__peek_byte((&(*l))) == 69U)) {
    (is_float = true);
    (l->current = (l->current + 1ULL));
    if ((lexer__lexer__peek_byte((&(*l))) == 43U) || (lexer__lexer__peek_byte((&(*l))) == 45U)) {
      (l->current = (l->current + 1ULL));
    }
    const size_t exponent_start = l->current;
    lexer__lexer__digits__cb_lexer__lexer__is_dec((&(*l)), exponent_start, (&error_at));
    if ((l->current == exponent_start) && (error_at == lexer__lexer__USIZE_MAX)) {
      (error_at = exponent_start);
      (error = (str){ (const uint8_t *)"exponent requires at least one decimal digit", sizeof("exponent requires at least one decimal digit") - 1 });
    } else if ((error_at != lexer__lexer__USIZE_MAX) && (str__len(&error) == 0ULL)) {
      (error = (str){ (const uint8_t *)"invalid numeric separator", sizeof("invalid numeric separator") - 1 });
    }
  }
  if (lexer__lexer__is_id_part_byte(lexer__lexer__peek_byte((&(*l))))) {
    const size_t sfx_start = l->current;
    while (lexer__lexer__is_id_part_byte(lexer__lexer__peek_byte((&(*l))))) {
      (l->current = (l->current + 1ULL));
    }
    const int32_t k = lexer__lexer__num_suffix_kind((l->bytes + sfx_start), (l->current - sfx_start));
    if (k < 0) {
      if (error_at == lexer__lexer__USIZE_MAX) {
        (error_at = sfx_start);
        (error = (str){ (const uint8_t *)"invalid suffix or trailing identifier characters after numeric literal", sizeof("invalid suffix or trailing identifier characters after numeric literal") - 1 });
      }
    } else if (is_float && (k == 0)) {
      if (error_at == lexer__lexer__USIZE_MAX) {
        (error_at = sfx_start);
        (error = (str){ (const uint8_t *)"a float literal cannot take an integer suffix", sizeof("a float literal cannot take an integer suffix") - 1 });
      }
    } else if (k == 1) {
      (is_float = true);
    }
  }
  if (error_at != lexer__lexer__USIZE_MAX) {
    lexer__lexer__lexer_error_at((&(*l)), error_at, 1ULL, error);
  } else {
    if (is_float) {
      lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_FloatLiteral);
    } else {
      lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_IntegerLiteral);
    }
  }
}

static __attribute__((unused)) void lexer__lexer__scan_token(lexer__lexer__Lexer *const l) {
  const uint8_t c = l->bytes[l->current];
  if (c < 0x80U) {
    (l->current = (l->current + 1ULL));
  }
  {
    const uint8_t __sc8 = c;
    if ((__sc8 == (uint8_t)' ') || (__sc8 == (uint8_t)'\t') || (__sc8 == (uint8_t)'\x0b') || (__sc8 == (uint8_t)'\x0c') || (__sc8 == (uint8_t)'\n') || (__sc8 == (uint8_t)'\r')) {
      {
        lexer__lexer__whitespace((&(*l)));
        return;
      }
    }
    else if (__sc8 == '{') {
      {
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_LeftBrace);
        return;
      }
    }
    else if (__sc8 == '}') {
      {
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_RightBrace);
        return;
      }
    }
    else if (__sc8 == '(') {
      {
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_LeftParen);
        return;
      }
    }
    else if (__sc8 == ')') {
      {
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_RightParen);
        return;
      }
    }
    else if (__sc8 == '[') {
      {
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_LeftBracket);
        return;
      }
    }
    else if (__sc8 == ']') {
      {
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_RightBracket);
        return;
      }
    }
    else if (__sc8 == ',') {
      {
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_Comma);
        return;
      }
    }
    else if (__sc8 == ';') {
      {
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_Semicolon);
        return;
      }
    }
    else if (__sc8 == ':') {
      {
        if (lexer__lexer__match_byte((&(*l)), 58U)) {
          lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_PathSeparator);
        } else {
          lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_Colon);
        }
        return;
      }
    }
    else if (__sc8 == '~') {
      {
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_Tilde);
        return;
      }
    }
    else if (__sc8 == '%') {
      {
        lexer__lexer__add_match((&(*l)), 61U, lexer__token_type__TokenType_PercentEqual, lexer__token_type__TokenType_Percent);
        return;
      }
    }
    else if (__sc8 == '^') {
      {
        lexer__lexer__add_match((&(*l)), 61U, lexer__token_type__TokenType_CaretEqual, lexer__token_type__TokenType_Caret);
        return;
      }
    }
    else if (__sc8 == '+') {
      {
        lexer__lexer__add_match((&(*l)), 61U, lexer__token_type__TokenType_PlusEqual, lexer__token_type__TokenType_Plus);
        return;
      }
    }
    else if (__sc8 == '-') {
      {
        if (lexer__lexer__match_byte((&(*l)), 62U)) {
          lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_Arrow);
          return;
        }
        lexer__lexer__add_match((&(*l)), 61U, lexer__token_type__TokenType_MinusEqual, lexer__token_type__TokenType_Minus);
        return;
      }
    }
    else if (__sc8 == '*') {
      {
        lexer__lexer__add_match((&(*l)), 61U, lexer__token_type__TokenType_StarEqual, lexer__token_type__TokenType_Star);
        return;
      }
    }
    else if (__sc8 == '=') {
      {
        if (lexer__lexer__match_byte((&(*l)), 61U)) {
          lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_EqualEqual);
          return;
        }
        lexer__lexer__add_match((&(*l)), 62U, lexer__token_type__TokenType_FatArrow, lexer__token_type__TokenType_Equal);
        return;
      }
    }
    else if (__sc8 == '!') {
      {
        lexer__lexer__add_match((&(*l)), 61U, lexer__token_type__TokenType_BangEqual, lexer__token_type__TokenType_Bang);
        return;
      }
    }
    else if (__sc8 == '<') {
      {
        if (lexer__lexer__match_byte((&(*l)), 60U)) {
          lexer__lexer__add_match((&(*l)), 61U, lexer__token_type__TokenType_LeftShiftEqual, lexer__token_type__TokenType_LeftShift);
          return;
        }
        lexer__lexer__add_match((&(*l)), 61U, lexer__token_type__TokenType_LessThanEqual, lexer__token_type__TokenType_LessThan);
        return;
      }
    }
    else if (__sc8 == '>') {
      {
        if (lexer__lexer__match_byte((&(*l)), 62U)) {
          lexer__lexer__add_match((&(*l)), 61U, lexer__token_type__TokenType_RightShiftEqual, lexer__token_type__TokenType_RightShift);
          return;
        }
        lexer__lexer__add_match((&(*l)), 61U, lexer__token_type__TokenType_GreaterThanEqual, lexer__token_type__TokenType_GreaterThan);
        return;
      }
    }
    else if (__sc8 == '&') {
      {
        if (lexer__lexer__match_byte((&(*l)), 38U)) {
          lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_AmpersandAmpersand);
          return;
        }
        lexer__lexer__add_match((&(*l)), 61U, lexer__token_type__TokenType_AmpersandEqual, lexer__token_type__TokenType_Ampersand);
        return;
      }
    }
    else if (__sc8 == '|') {
      {
        if (lexer__lexer__match_byte((&(*l)), 124U)) {
          lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_PipePipe);
          return;
        }
        lexer__lexer__add_match((&(*l)), 61U, lexer__token_type__TokenType_PipeEqual, lexer__token_type__TokenType_Pipe);
        return;
      }
    }
    else if (__sc8 == '?') {
      {
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_Question);
        return;
      }
    }
    else if (__sc8 == '/') {
      {
        if (lexer__lexer__match_byte((&(*l)), 47U)) {
          lexer__lexer__line_comment((&(*l)));
        } else if (lexer__lexer__match_byte((&(*l)), 42U)) {
          lexer__lexer__block_comment((&(*l)));
        } else {
          lexer__lexer__add_match((&(*l)), 61U, lexer__token_type__TokenType_SlashEqual, lexer__token_type__TokenType_Slash);
        }
        return;
      }
    }
    else if (__sc8 == '.') {
      {
        if (lexer__lexer__match_byte((&(*l)), 46U)) {
          if (lexer__lexer__match_byte((&(*l)), 46U)) {
            lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_Ellipsis);
          } else if (lexer__lexer__match_byte((&(*l)), 61U)) {
            lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_RangeInclusive);
          } else {
            lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_Range);
          }
        } else {
          lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_Dot);
        }
        return;
      }
    }
    else if (__sc8 == '"') {
      {
        lexer__lexer__string_lit((&(*l)), lexer__token_type__TokenType_StringLiteral);
        return;
      }
    }
    else if (__sc8 == '\'') {
      {
        if (lexer__lexer__label_ahead((&(*l)))) {
          while (lexer__lexer__is_id_part_byte(lexer__lexer__peek_byte((&(*l))))) {
            (l->current = (l->current + 1ULL));
          }
          lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_Label);
          return;
        }
        lexer__lexer__character((&(*l)), false);
        return;
      }
    }
    else if (__sc8 >= '0' && __sc8 <= '9') {
      {
        lexer__lexer__number((&(*l)));
        return;
      }
    }
    else if (__sc8 == 'r') {
      {
        size_t hashes = 0ULL;
        if (lexer__lexer__raw_string_ahead((&(*l)), (&hashes))) {
          lexer__lexer__raw_string((&(*l)), hashes);
          return;
        }
        lexer__lexer__identifier((&(*l)));
        return;
      }
    }
    else if (__sc8 == 'b') {
      {
        if (lexer__lexer__peek_byte((&(*l))) == 39U) {
          (l->current = (l->current + 1ULL));
          lexer__lexer__character((&(*l)), true);
        } else if (lexer__lexer__peek_byte((&(*l))) == 34U) {
          (l->current = (l->current + 1ULL));
          lexer__lexer__string_lit((&(*l)), lexer__token_type__TokenType_ByteStringLiteral);
        } else {
          lexer__lexer__identifier((&(*l)));
        }
        return;
      }
    }
    else if (__sc8 == '#') {
      {
        const size_t start = l->start;
        lexer__lexer__lexer_error_at((&(*l)), start, 1ULL, (str){ (const uint8_t *)"'#' is not valid in Super-C source; Super-C has no preprocessor", sizeof("'#' is not valid in Super-C source; Super-C has no preprocessor") - 1 });
        return;
      }
    }
    else if (__sc8 == '@') {
      {
        lexer__lexer__add_token((&(*l)), lexer__token_type__TokenType_At);
        return;
      }
    }
    else if (__sc8 == '$') {
      {
        const size_t start = l->start;
        lexer__lexer__lexer_error_at((&(*l)), start, 1ULL, (str){ (const uint8_t *)"'$' is reserved", sizeof("'$' is reserved") - 1 });
        return;
      }
    }
    else if (__sc8 == '`') {
      {
        const size_t start = l->start;
        lexer__lexer__lexer_error_at((&(*l)), start, 1ULL, (str){ (const uint8_t *)"'`' is reserved", sizeof("'`' is reserved") - 1 });
        return;
      }
    }
    else if (__sc8 == (uint8_t)'\0') {
      {
        const size_t start = l->start;
        lexer__lexer__lexer_error_at((&(*l)), start, 1ULL, (str){ (const uint8_t *)"NUL byte is not allowed in source", sizeof("NUL byte is not allowed in source") - 1 });
        return;
      }
    }
    else if ((__sc8 >= 'a' && __sc8 <= 'z') || (__sc8 >= 'A' && __sc8 <= 'Z') || (__sc8 == '_')) {
      {
        lexer__lexer__identifier((&(*l)));
        return;
      }
    }
    else if (1) {
      {
        if (c >= 0x80U) {
          size_t size = 0ULL;
          const uint32_t cp = lexer__lexer__decode_at_b((&(*l)), c, l->current, (&size));
          if (size == 0ULL) {
            const size_t start = l->start;
            lexer__lexer__lexer_error_at((&(*l)), start, 1ULL, (str){ (const uint8_t *)"source is not valid UTF-8", sizeof("source is not valid UTF-8") - 1 });
            (l->current = (l->current + 1ULL));
          } else {
            (l->current = (l->current + size));
            const size_t start = l->start;
            if (cp == 0xFEFFU) {
              lexer__lexer__lexer_error_at((&(*l)), start, size, (str){ (const uint8_t *)"UTF-8 BOM is allowed only at the start of a file", sizeof("UTF-8 BOM is allowed only at the start of a file") - 1 });
            } else {
              lexer__lexer__lexer_error_at((&(*l)), start, size, (str){ (const uint8_t *)"identifiers may contain only ASCII letters, digits, and '_'", sizeof("identifiers may contain only ASCII letters, digits, and '_'") - 1 });
            }
          }
        } else {
          const uint32_t start = ((uint32_t)l->start);
          utils__errors__Errors__emit(&l->errors, start, 1U, ({ String__Global __sc9 = String__Global__new();
String__Global__push_str(&__sc9, (str){ .ptr = (const uint8_t*)"unexpected character '", .len = sizeof("unexpected character '") - 1 });
String__Global__push_byte(&__sc9, (uint8_t)(((char)c)));
String__Global__push_str(&__sc9, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc9; }));
        }
      }
    }
  }
}

void lexer__lexer__Lexer__scan_tokens(lexer__lexer__Lexer *const self) {
  Vector__u64__Global__reserve(&self->tokens, ({ size_t __sc10 = self->len; size_t __sc11 = 5ULL; if (__sc11 == 0) { __sc_panic("divide by zero"); } (__sc10 / __sc11); }));
  if (((((self->current == 0ULL) && (self->len >= 3ULL)) && (self->bytes[0] == 0xEFU)) && (self->bytes[1] == 0xBBU)) && (self->bytes[2] == 0xBFU)) {
    (self->current = 3ULL);
  }
  while (self->current < self->len) {
    (self->start = self->current);
    lexer__lexer__scan_token((&(*self)));
  }
  Vector__u64__Global__push(&self->tokens, lexer__token__Token__new(lexer__token_type__TokenType_Eof, ((uint32_t)self->len), 0U));
  utils__errors__Errors__finalize(&self->errors, self->bytes, self->len, self->file);
}

Vector__u64__Global lexer__lexer__Lexer__take_tokens(lexer__lexer__Lexer *const self) {
  Vector__u64__Global out = self->tokens;
  (self->tokens = Vector__u64__Global__new());
  return out;
}

bool lexer__lexer__Lexer__has_errors(const lexer__lexer__Lexer *const self) {
  return utils__errors__Errors__has_errors(&self->errors);
}

void lexer__lexer__Lexer__log_errors(const lexer__lexer__Lexer *const self) {
  utils__errors__Errors__log(&self->errors);
}

