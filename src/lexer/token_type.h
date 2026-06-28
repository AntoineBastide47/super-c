#ifndef TOKEN_TYPE_H
#define TOKEN_TYPE_H

#include <stdint.h>

// Discriminants are packed into a token's high byte. Keep this enum in sync
// with TOKEN_TYPE_NAMES in token_type.c.
typedef enum TokenType {
  // Names
  Identifier,

  // Reserved words
  As,
  Import,
  Break,
  Case,
  Const,
  Continue,
  Defer,
  Do,
  Else,
  Enum,
  Extern,
  False,
  Fn,
  For,
  If,
  Extend,
  In,
  Let,
  Switch,
  Move,
  Mut,
  New,
  Null,
  Pub,
  Sizeof,
  Alignof,
  Return,
  SelfLower,
  SelfUpper,
  Struct,
  Interface,
  True,
  Type,
  Union,
  Unsafe,
  Where,
  While,

  // Literals
  IntegerLiteral,
  FloatLiteral,
  CharacterLiteral,
  ByteCharacterLiteral,
  StringLiteral,
  RawStringLiteral,

  // Delimiters and punctuation
  LeftBrace, // {
  RightBrace, // }
  LeftParen, // (
  RightParen, // )
  LeftBracket, // [
  RightBracket, // ]
  Comma, // ,
  Semicolon, // ;
  Colon, // :
  Dot, // .
  At, // @ (introduces an attribute)

  // Operators
  Plus, // +
  Minus, // -
  Star, // *
  Slash, // /
  Percent, // %
  Tilde, // ~
  Bang, // !
  Question, // ?
  QuestionQuestion, // ??

  EqualEqual, // ==
  BangEqual, // !=
  LessThan, // <
  LessThanEqual, // <=
  GreaterThan, // >
  GreaterThanEqual, // >=

  Ampersand, // &
  Pipe, // |
  Caret, // ^
  AmpersandAmpersand, // &&
  PipePipe, // ||
  LeftShift, // <<
  RightShift, // >>

  Equal, // =
  PlusEqual, // +=
  MinusEqual, // -=
  StarEqual, // *=
  SlashEqual, // /=
  PercentEqual, // %=
  AmpersandEqual, // &=
  PipeEqual, // |=
  CaretEqual, // ^=
  LeftShiftEqual, // <<=
  RightShiftEqual, // >>=

  Range, // ..
  RangeInclusive, // ..=
  Ellipsis, // ... (C variadic marker in an extern parameter list)
  PathSeparator, // ::
  Arrow, // ->
  FatArrow, // =>

  Eof,
} TokenType;

const char *token_type_name(const TokenType t);

#endif // TOKEN_TYPE_H
