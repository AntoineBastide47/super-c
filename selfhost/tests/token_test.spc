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
