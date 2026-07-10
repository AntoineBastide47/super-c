#include "../lexer/token_type.h"
#include "../__std/str.h"


str lexer__token_type__TokenType__name(lexer__token_type__TokenType const self) {
  {
    const lexer__token_type__TokenType __sc0 = self;
    if (__sc0 == lexer__token_type__TokenType_Identifier) {
      return (str){ (const uint8_t *)"Identifier", sizeof("Identifier") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Label) {
      return (str){ (const uint8_t *)"Label", sizeof("Label") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_As) {
      return (str){ (const uint8_t *)"As", sizeof("As") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Import) {
      return (str){ (const uint8_t *)"Import", sizeof("Import") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Break) {
      return (str){ (const uint8_t *)"Break", sizeof("Break") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Case) {
      return (str){ (const uint8_t *)"Case", sizeof("Case") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Const) {
      return (str){ (const uint8_t *)"Const", sizeof("Const") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Continue) {
      return (str){ (const uint8_t *)"Continue", sizeof("Continue") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Defer) {
      return (str){ (const uint8_t *)"Defer", sizeof("Defer") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Do) {
      return (str){ (const uint8_t *)"Do", sizeof("Do") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Dyn) {
      return (str){ (const uint8_t *)"Dyn", sizeof("Dyn") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Else) {
      return (str){ (const uint8_t *)"Else", sizeof("Else") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Enum) {
      return (str){ (const uint8_t *)"Enum", sizeof("Enum") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Extern) {
      return (str){ (const uint8_t *)"Extern", sizeof("Extern") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_False) {
      return (str){ (const uint8_t *)"False", sizeof("False") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Fn) {
      return (str){ (const uint8_t *)"Fn", sizeof("Fn") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_For) {
      return (str){ (const uint8_t *)"For", sizeof("For") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_If) {
      return (str){ (const uint8_t *)"If", sizeof("If") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Extend) {
      return (str){ (const uint8_t *)"Extend", sizeof("Extend") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_In) {
      return (str){ (const uint8_t *)"In", sizeof("In") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Let) {
      return (str){ (const uint8_t *)"Let", sizeof("Let") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Loop) {
      return (str){ (const uint8_t *)"Loop", sizeof("Loop") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Switch) {
      return (str){ (const uint8_t *)"Switch", sizeof("Switch") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Move) {
      return (str){ (const uint8_t *)"Move", sizeof("Move") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Mut) {
      return (str){ (const uint8_t *)"Mut", sizeof("Mut") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_New) {
      return (str){ (const uint8_t *)"New", sizeof("New") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Null) {
      return (str){ (const uint8_t *)"Null", sizeof("Null") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Pub) {
      return (str){ (const uint8_t *)"Pub", sizeof("Pub") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Sizeof) {
      return (str){ (const uint8_t *)"Sizeof", sizeof("Sizeof") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Alignof) {
      return (str){ (const uint8_t *)"Alignof", sizeof("Alignof") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Return) {
      return (str){ (const uint8_t *)"Return", sizeof("Return") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_SelfLower) {
      return (str){ (const uint8_t *)"SelfLower", sizeof("SelfLower") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_SelfUpper) {
      return (str){ (const uint8_t *)"SelfUpper", sizeof("SelfUpper") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Struct) {
      return (str){ (const uint8_t *)"Struct", sizeof("Struct") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Interface) {
      return (str){ (const uint8_t *)"Interface", sizeof("Interface") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_True) {
      return (str){ (const uint8_t *)"True", sizeof("True") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Type) {
      return (str){ (const uint8_t *)"Type", sizeof("Type") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Union) {
      return (str){ (const uint8_t *)"Union", sizeof("Union") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Unsafe) {
      return (str){ (const uint8_t *)"Unsafe", sizeof("Unsafe") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Where) {
      return (str){ (const uint8_t *)"Where", sizeof("Where") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_While) {
      return (str){ (const uint8_t *)"While", sizeof("While") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_IntegerLiteral) {
      return (str){ (const uint8_t *)"IntegerLiteral", sizeof("IntegerLiteral") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_FloatLiteral) {
      return (str){ (const uint8_t *)"FloatLiteral", sizeof("FloatLiteral") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_CharacterLiteral) {
      return (str){ (const uint8_t *)"CharacterLiteral", sizeof("CharacterLiteral") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_ByteCharacterLiteral) {
      return (str){ (const uint8_t *)"ByteCharacterLiteral", sizeof("ByteCharacterLiteral") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_StringLiteral) {
      return (str){ (const uint8_t *)"StringLiteral", sizeof("StringLiteral") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_RawStringLiteral) {
      return (str){ (const uint8_t *)"RawStringLiteral", sizeof("RawStringLiteral") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_ByteStringLiteral) {
      return (str){ (const uint8_t *)"ByteStringLiteral", sizeof("ByteStringLiteral") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_LeftBrace) {
      return (str){ (const uint8_t *)"LeftBrace", sizeof("LeftBrace") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_RightBrace) {
      return (str){ (const uint8_t *)"RightBrace", sizeof("RightBrace") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_LeftParen) {
      return (str){ (const uint8_t *)"LeftParen", sizeof("LeftParen") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_RightParen) {
      return (str){ (const uint8_t *)"RightParen", sizeof("RightParen") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_LeftBracket) {
      return (str){ (const uint8_t *)"LeftBracket", sizeof("LeftBracket") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_RightBracket) {
      return (str){ (const uint8_t *)"RightBracket", sizeof("RightBracket") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Comma) {
      return (str){ (const uint8_t *)"Comma", sizeof("Comma") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Semicolon) {
      return (str){ (const uint8_t *)"Semicolon", sizeof("Semicolon") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Colon) {
      return (str){ (const uint8_t *)"Colon", sizeof("Colon") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Dot) {
      return (str){ (const uint8_t *)"Dot", sizeof("Dot") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_At) {
      return (str){ (const uint8_t *)"At", sizeof("At") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Plus) {
      return (str){ (const uint8_t *)"Plus", sizeof("Plus") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Minus) {
      return (str){ (const uint8_t *)"Minus", sizeof("Minus") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Star) {
      return (str){ (const uint8_t *)"Star", sizeof("Star") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Slash) {
      return (str){ (const uint8_t *)"Slash", sizeof("Slash") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Percent) {
      return (str){ (const uint8_t *)"Percent", sizeof("Percent") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Tilde) {
      return (str){ (const uint8_t *)"Tilde", sizeof("Tilde") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Bang) {
      return (str){ (const uint8_t *)"Bang", sizeof("Bang") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Question) {
      return (str){ (const uint8_t *)"Question", sizeof("Question") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_EqualEqual) {
      return (str){ (const uint8_t *)"EqualEqual", sizeof("EqualEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_BangEqual) {
      return (str){ (const uint8_t *)"BangEqual", sizeof("BangEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_LessThan) {
      return (str){ (const uint8_t *)"LessThan", sizeof("LessThan") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_LessThanEqual) {
      return (str){ (const uint8_t *)"LessThanEqual", sizeof("LessThanEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_GreaterThan) {
      return (str){ (const uint8_t *)"GreaterThan", sizeof("GreaterThan") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_GreaterThanEqual) {
      return (str){ (const uint8_t *)"GreaterThanEqual", sizeof("GreaterThanEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Ampersand) {
      return (str){ (const uint8_t *)"Ampersand", sizeof("Ampersand") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Pipe) {
      return (str){ (const uint8_t *)"Pipe", sizeof("Pipe") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Caret) {
      return (str){ (const uint8_t *)"Caret", sizeof("Caret") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_AmpersandAmpersand) {
      return (str){ (const uint8_t *)"AmpersandAmpersand", sizeof("AmpersandAmpersand") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_PipePipe) {
      return (str){ (const uint8_t *)"PipePipe", sizeof("PipePipe") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_LeftShift) {
      return (str){ (const uint8_t *)"LeftShift", sizeof("LeftShift") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_RightShift) {
      return (str){ (const uint8_t *)"RightShift", sizeof("RightShift") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Equal) {
      return (str){ (const uint8_t *)"Equal", sizeof("Equal") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_PlusEqual) {
      return (str){ (const uint8_t *)"PlusEqual", sizeof("PlusEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_MinusEqual) {
      return (str){ (const uint8_t *)"MinusEqual", sizeof("MinusEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_StarEqual) {
      return (str){ (const uint8_t *)"StarEqual", sizeof("StarEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_SlashEqual) {
      return (str){ (const uint8_t *)"SlashEqual", sizeof("SlashEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_PercentEqual) {
      return (str){ (const uint8_t *)"PercentEqual", sizeof("PercentEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_AmpersandEqual) {
      return (str){ (const uint8_t *)"AmpersandEqual", sizeof("AmpersandEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_PipeEqual) {
      return (str){ (const uint8_t *)"PipeEqual", sizeof("PipeEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_CaretEqual) {
      return (str){ (const uint8_t *)"CaretEqual", sizeof("CaretEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_LeftShiftEqual) {
      return (str){ (const uint8_t *)"LeftShiftEqual", sizeof("LeftShiftEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_RightShiftEqual) {
      return (str){ (const uint8_t *)"RightShiftEqual", sizeof("RightShiftEqual") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Range) {
      return (str){ (const uint8_t *)"Range", sizeof("Range") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_RangeInclusive) {
      return (str){ (const uint8_t *)"RangeInclusive", sizeof("RangeInclusive") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Ellipsis) {
      return (str){ (const uint8_t *)"Ellipsis", sizeof("Ellipsis") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_PathSeparator) {
      return (str){ (const uint8_t *)"PathSeparator", sizeof("PathSeparator") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Arrow) {
      return (str){ (const uint8_t *)"Arrow", sizeof("Arrow") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_FatArrow) {
      return (str){ (const uint8_t *)"FatArrow", sizeof("FatArrow") - 1 };
    }
    else if (__sc0 == lexer__token_type__TokenType_Eof) {
      return (str){ (const uint8_t *)"Eof", sizeof("Eof") - 1 };
    }
    else { __builtin_unreachable(); }
  }
}

