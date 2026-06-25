#include "token_type.h"

static const char *const TOKEN_TYPE_NAMES[] = {
    "Identifier",

    "As",
    "Import",
    "Break",
    "Case",
    "Const",
    "Continue",
    "Defer",
    "Else",
    "Enum",
    "Extern",
    "False",
    "Fn",
    "For",
    "If",
    "Extend",
    "In",
    "Let",
    "Switch",
    "Move",
    "Mut",
    "New",
    "Null",
    "Pub",
    "Sizeof",
    "Return",
    "SelfLower",
    "SelfUpper",
    "Struct",
    "Interface",
    "True",
    "Type",
    "Union",
    "Unsafe",
    "Where",
    "While",

    "IntegerLiteral",
    "FloatLiteral",
    "CharacterLiteral",
    "ByteCharacterLiteral",
    "StringLiteral",
    "RawStringLiteral",

    "LeftBrace",
    "RightBrace",
    "LeftParen",
    "RightParen",
    "LeftBracket",
    "RightBracket",
    "Comma",
    "Semicolon",
    "Colon",
    "Dot",

    "Plus",
    "Minus",
    "Star",
    "Slash",
    "Percent",
    "Tilde",
    "Bang",
    "Question",
    "QuestionQuestion",

    "EqualEqual",
    "BangEqual",
    "LessThan",
    "LessThanEqual",
    "GreaterThan",
    "GreaterThanEqual",

    "Ampersand",
    "Pipe",
    "Caret",
    "AmpersandAmpersand",
    "PipePipe",
    "LeftShift",
    "RightShift",

    "Equal",
    "PlusEqual",
    "MinusEqual",
    "StarEqual",
    "SlashEqual",
    "PercentEqual",
    "AmpersandEqual",
    "PipeEqual",
    "CaretEqual",
    "LeftShiftEqual",
    "RightShiftEqual",

    "Range",
    "RangeInclusive",
    "PathSeparator",
    "Arrow",
    "FatArrow",

    "Eof",
};

_Static_assert(
    sizeof TOKEN_TYPE_NAMES / sizeof TOKEN_TYPE_NAMES[0] == Eof + 1, "TokenType and TOKEN_TYPE_NAMES are out of sync");
_Static_assert(Eof < 256, "TokenType must fit in the token's high byte");

const char *token_type_name(const TokenType t) {
  const unsigned index = (unsigned)t;
  if (index >= sizeof TOKEN_TYPE_NAMES / sizeof TOKEN_TYPE_NAMES[0])
    return "InvalidTokenType";
  return TOKEN_TYPE_NAMES[index];
}
