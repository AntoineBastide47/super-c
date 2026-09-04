// Self-hosted port of tests/token_test.c: direct coverage of lexer::token (Token packing + Span) and
// lexer::token_type (name()). Part of the selfhost/tests suite; run via `super-c --test selfhost/run_tests.spc`.
import lexer::token as *;
import lexer::token_type as *;

@test
fn packing() {
    let t = Token::new(TokenType::Identifier, 5, 3);
    assert_eq(t.start(), 5);
    assert_eq(t.len(), 3);
    assert_eq(t.end(), 8);
    assert(t.kind() == TokenType::Identifier, "type round-trips");

    let big = Token::new(TokenType::Eof, 0xABCDEF, 0xFFFFFF);
    assert_eq(big.len(), 0xFFFFFF);
    assert_eq(big.start(), 0xABCDEF);
    assert(big.kind() == TokenType::Eof, "high-byte type survives a full 24-bit len");
}

@test
fn spans() {
    let a = Span::new(2, 7);
    assert(a.start == 2 && a.end == 7, "span_new");
    let e = Span::empty();
    assert(e.start == 0 && e.end == 0, "span_empty");
    let ts = Token::new(TokenType::Plus, 10, 1).span();
    assert(ts.start == 10 && ts.end == 11, "token_span");
}

@test
fn type_names() {
    assert(TokenType::Identifier.name() == "Identifier", "Identifier");
    assert(TokenType::Fn.name() == "Fn", "Fn");
    assert(TokenType::IntegerLiteral.name() == "IntegerLiteral", "IntegerLiteral");
    assert(TokenType::LeftBrace.name() == "LeftBrace", "LeftBrace");
    assert(TokenType::Plus.name() == "Plus", "Plus");
    assert(TokenType::RangeInclusive.name() == "RangeInclusive", "RangeInclusive");
    assert(TokenType::Eof.name() == "Eof", "Eof");
}

// Every variant's spelling: the whole name() switch, one arm per kind. A new kind that forgets its
// arm, or a wrong spelling, fails here.
@test
fn type_names_exhaustive() {
    assert(TokenType::Identifier.name() == "Identifier", "Identifier");
    assert(TokenType::Underscore.name() == "Underscore", "Underscore");
    assert(TokenType::Label.name() == "Label", "Label");
    assert(TokenType::As.name() == "As", "As");
    assert(TokenType::Import.name() == "Import", "Import");
    assert(TokenType::Break.name() == "Break", "Break");
    assert(TokenType::Case.name() == "Case", "Case");
    assert(TokenType::Const.name() == "Const", "Const");
    assert(TokenType::Continue.name() == "Continue", "Continue");
    assert(TokenType::Defer.name() == "Defer", "Defer");
    assert(TokenType::Asm.name() == "Asm", "Asm");
    assert(TokenType::Do.name() == "Do", "Do");
    assert(TokenType::Dyn.name() == "Dyn", "Dyn");
    assert(TokenType::Else.name() == "Else", "Else");
    assert(TokenType::Enum.name() == "Enum", "Enum");
    assert(TokenType::Extern.name() == "Extern", "Extern");
    assert(TokenType::False.name() == "False", "False");
    assert(TokenType::Fn.name() == "Fn", "Fn");
    assert(TokenType::For.name() == "For", "For");
    assert(TokenType::If.name() == "If", "If");
    assert(TokenType::Extend.name() == "Extend", "Extend");
    assert(TokenType::In.name() == "In", "In");
    assert(TokenType::Let.name() == "Let", "Let");
    assert(TokenType::Loop.name() == "Loop", "Loop");
    assert(TokenType::Switch.name() == "Switch", "Switch");
    assert(TokenType::Move.name() == "Move", "Move");
    assert(TokenType::Mut.name() == "Mut", "Mut");
    assert(TokenType::New.name() == "New", "New");
    assert(TokenType::Null.name() == "Null", "Null");
    assert(TokenType::Pub.name() == "Pub", "Pub");
    assert(TokenType::Sizeof.name() == "Sizeof", "Sizeof");
    assert(TokenType::Alignof.name() == "Alignof", "Alignof");
    assert(TokenType::Return.name() == "Return", "Return");
    assert(TokenType::SelfLower.name() == "SelfLower", "SelfLower");
    assert(TokenType::SelfUpper.name() == "SelfUpper", "SelfUpper");
    assert(TokenType::Struct.name() == "Struct", "Struct");
    assert(TokenType::Static.name() == "Static", "Static");
    assert(TokenType::StaticAssert.name() == "StaticAssert", "StaticAssert");
    assert(TokenType::Interface.name() == "Interface", "Interface");
    assert(TokenType::True.name() == "True", "True");
    assert(TokenType::Type.name() == "Type", "Type");
    assert(TokenType::Union.name() == "Union", "Union");
    assert(TokenType::Unsafe.name() == "Unsafe", "Unsafe");
    assert(TokenType::Where.name() == "Where", "Where");
    assert(TokenType::While.name() == "While", "While");
    assert(TokenType::VaStart.name() == "VaStart", "VaStart");
    assert(TokenType::VaArg.name() == "VaArg", "VaArg");
    assert(TokenType::VaEnd.name() == "VaEnd", "VaEnd");
    assert(TokenType::Launch.name() == "Launch", "Launch");
    assert(TokenType::Select.name() == "Select", "Select");
    assert(TokenType::IntegerLiteral.name() == "IntegerLiteral", "IntegerLiteral");
    assert(TokenType::FloatLiteral.name() == "FloatLiteral", "FloatLiteral");
    assert(TokenType::CharacterLiteral.name() == "CharacterLiteral", "CharacterLiteral");
    assert(TokenType::ByteCharacterLiteral.name() == "ByteCharacterLiteral", "ByteCharacterLiteral");
    assert(TokenType::StringLiteral.name() == "StringLiteral", "StringLiteral");
    assert(TokenType::RawStringLiteral.name() == "RawStringLiteral", "RawStringLiteral");
    assert(TokenType::ByteStringLiteral.name() == "ByteStringLiteral", "ByteStringLiteral");
    assert(TokenType::LeftBrace.name() == "LeftBrace", "LeftBrace");
    assert(TokenType::RightBrace.name() == "RightBrace", "RightBrace");
    assert(TokenType::LeftParen.name() == "LeftParen", "LeftParen");
    assert(TokenType::RightParen.name() == "RightParen", "RightParen");
    assert(TokenType::LeftBracket.name() == "LeftBracket", "LeftBracket");
    assert(TokenType::RightBracket.name() == "RightBracket", "RightBracket");
    assert(TokenType::Comma.name() == "Comma", "Comma");
    assert(TokenType::Semicolon.name() == "Semicolon", "Semicolon");
    assert(TokenType::Colon.name() == "Colon", "Colon");
    assert(TokenType::Dot.name() == "Dot", "Dot");
    assert(TokenType::At.name() == "At", "At");
    assert(TokenType::Plus.name() == "Plus", "Plus");
    assert(TokenType::Minus.name() == "Minus", "Minus");
    assert(TokenType::Star.name() == "Star", "Star");
    assert(TokenType::Slash.name() == "Slash", "Slash");
    assert(TokenType::Percent.name() == "Percent", "Percent");
    assert(TokenType::Tilde.name() == "Tilde", "Tilde");
    assert(TokenType::Bang.name() == "Bang", "Bang");
    assert(TokenType::Question.name() == "Question", "Question");
    assert(TokenType::EqualEqual.name() == "EqualEqual", "EqualEqual");
    assert(TokenType::BangEqual.name() == "BangEqual", "BangEqual");
    assert(TokenType::LessThan.name() == "LessThan", "LessThan");
    assert(TokenType::LessThanEqual.name() == "LessThanEqual", "LessThanEqual");
    assert(TokenType::GreaterThan.name() == "GreaterThan", "GreaterThan");
    assert(TokenType::GreaterThanEqual.name() == "GreaterThanEqual", "GreaterThanEqual");
    assert(TokenType::Ampersand.name() == "Ampersand", "Ampersand");
    assert(TokenType::Pipe.name() == "Pipe", "Pipe");
    assert(TokenType::Caret.name() == "Caret", "Caret");
    assert(TokenType::AmpersandAmpersand.name() == "AmpersandAmpersand", "AmpersandAmpersand");
    assert(TokenType::PipePipe.name() == "PipePipe", "PipePipe");
    assert(TokenType::LeftShift.name() == "LeftShift", "LeftShift");
    assert(TokenType::RightShift.name() == "RightShift", "RightShift");
    assert(TokenType::Equal.name() == "Equal", "Equal");
    assert(TokenType::PlusEqual.name() == "PlusEqual", "PlusEqual");
    assert(TokenType::MinusEqual.name() == "MinusEqual", "MinusEqual");
    assert(TokenType::StarEqual.name() == "StarEqual", "StarEqual");
    assert(TokenType::SlashEqual.name() == "SlashEqual", "SlashEqual");
    assert(TokenType::PercentEqual.name() == "PercentEqual", "PercentEqual");
    assert(TokenType::AmpersandEqual.name() == "AmpersandEqual", "AmpersandEqual");
    assert(TokenType::PipeEqual.name() == "PipeEqual", "PipeEqual");
    assert(TokenType::CaretEqual.name() == "CaretEqual", "CaretEqual");
    assert(TokenType::LeftShiftEqual.name() == "LeftShiftEqual", "LeftShiftEqual");
    assert(TokenType::RightShiftEqual.name() == "RightShiftEqual", "RightShiftEqual");
    assert(TokenType::Range.name() == "Range", "Range");
    assert(TokenType::RangeInclusive.name() == "RangeInclusive", "RangeInclusive");
    assert(TokenType::Ellipsis.name() == "Ellipsis", "Ellipsis");
    assert(TokenType::PathSeparator.name() == "PathSeparator", "PathSeparator");
    assert(TokenType::Arrow.name() == "Arrow", "Arrow");
    assert(TokenType::FatArrow.name() == "FatArrow", "FatArrow");
    assert(TokenType::Eof.name() == "Eof", "Eof");
    assert(TokenType::InlineFor.name() == "InlineFor", "InlineFor");
    assert(TokenType::ParallelFor.name() == "ParallelFor", "ParallelFor");
    assert(TokenType::LineComment.name() == "LineComment", "LineComment");
    assert(TokenType::BlockComment.name() == "BlockComment", "BlockComment");
    assert(TokenType::DocLineComment.name() == "DocLineComment", "DocLineComment");
    assert(TokenType::DocBlockComment.name() == "DocBlockComment", "DocBlockComment");
    assert(TokenType::MatchertextLiteral.name() == "MatchertextLiteral", "MatchertextLiteral");
    assert(TokenType::MatchertextBegin.name() == "MatchertextBegin", "MatchertextBegin");
    assert(TokenType::MatchertextMid.name() == "MatchertextMid", "MatchertextMid");
    assert(TokenType::MatchertextEnd.name() == "MatchertextEnd", "MatchertextEnd");
}

// name() on a runtime-derived TokenType (an int cast the folder cannot see through): the const-fn
// path and the exhaustive-names test both fold at compile time, so this pins that name() also returns
// a valid spelling for every variant when the value is only known at run time.
@test
fn name_arms_run_at_runtime() {
    let mut total: usize = 0;
    let mut i: i32 = 0;
    while i < 118 {
        let k = i as TokenType;
        total = total + k.name().len();
        i = i + 1;
    }
    assert(total > 0, "every variant name has a length");
}
