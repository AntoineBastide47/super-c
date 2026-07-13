// Self-hosted port of tests/lexer_test.c: drives lexer::Lexer over source and checks the token-type stream
// (keywords, tuple-access `.digit` vs float, and error diagnostics). Part of the selfhost/tests suite.
import lexer::token as *;
import lexer::token_type as *;
import lexer::lexer as *;

fn expect_tokens(src: str, expected: []TokenType) {
    let mut s = String::from_str(src);
    let mut lx = Lexer::new(&mut s, "");
    lx.scan_tokens();
    assert(!lx.has_errors(), "unexpected lexer error");
    let mut toks = lx.take_tokens();
    assert_eq(toks.len(), expected.len());
    let n = if toks.len() < expected.len() {
        toks.len();
    } else {
        expected.len();
    };
    for i in 0..n {
        assert(toks[i].kind() == expected[i], "token type mismatch");
    }
}

fn expect_error(src: str) {
    let mut s = String::from_str(src);
    let mut lx = Lexer::new(&mut s, "");
    lx.scan_tokens();
    assert(lx.has_errors(), "expected a lexer error");
    let mut _toks = lx.take_tokens(); // drained so RAII frees the tokens
}

@test
fn keywords() {
    expect_tokens(
        "as break case const continue defer do else enum extern false fn for if in let move mut new null return self Self struct true type unsafe where while switch interface extend match protocol augment name _ i32",
        [
            TokenType::As,
            TokenType::Break,
            TokenType::Case,
            TokenType::Const,
            TokenType::Continue,
            TokenType::Defer,
            TokenType::Do,
            TokenType::Else,
            TokenType::Enum,
            TokenType::Extern,
            TokenType::False,
            TokenType::Fn,
            TokenType::For,
            TokenType::If,
            TokenType::In,
            TokenType::Let,
            TokenType::Move,
            TokenType::Mut,
            TokenType::New,
            TokenType::Null,
            TokenType::Return,
            TokenType::SelfLower,
            TokenType::SelfUpper,
            TokenType::Struct,
            TokenType::True,
            TokenType::Type,
            TokenType::Unsafe,
            TokenType::Where,
            TokenType::While,
            TokenType::Switch,
            TokenType::Interface,
            TokenType::Extend,
            TokenType::Identifier,
            TokenType::Identifier,
            TokenType::Identifier,
            TokenType::Identifier,
            TokenType::Identifier,
            TokenType::Identifier,
            TokenType::Eof,
        ],
    );
}

// `.` before a digit is a plain Dot (tuple element access `t.0`); `0.5` after an expression dot is a float.
@test
fn dot_digit() {
    expect_tokens(
        "t.0 t.0.5",
        [
            TokenType::Identifier,
            TokenType::Dot,
            TokenType::IntegerLiteral,
            TokenType::Identifier,
            TokenType::Dot,
            TokenType::FloatLiteral,
            TokenType::Eof,
        ],
    );
}

@test
fn numeric_errors() {
    expect_error("0b102"); // invalid digit in binary
    expect_error("0xFG"); // invalid digit in hexadecimal
}
