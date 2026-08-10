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
    let toks = lx.take_tokens();
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
        "as break case const continue defer do else enum extern false fn for if in let move mut new null return self Self struct static static_assert true type unsafe where while switch interface extend va_start va_arg va_end match protocol augment name _ i32",
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
            TokenType::Static,
            TokenType::StaticAssert,
            TokenType::True,
            TokenType::Type,
            TokenType::Unsafe,
            TokenType::Where,
            TokenType::While,
            TokenType::Switch,
            TokenType::Interface,
            TokenType::Extend,
            TokenType::VaStart,
            TokenType::VaArg,
            TokenType::VaEnd,
            TokenType::Identifier,
            TokenType::Identifier,
            TokenType::Identifier,
            TokenType::Identifier,
            TokenType::Underscore,
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
fn greater_than_tokens() {
    expect_tokens(
        "> >> >= >>= > >",
        [
            TokenType::GreaterThan,
            TokenType::GreaterThan,
            TokenType::GreaterThan,
            TokenType::GreaterThan,
            TokenType::Equal,
            TokenType::GreaterThan,
            TokenType::GreaterThan,
            TokenType::Equal,
            TokenType::GreaterThan,
            TokenType::GreaterThan,
            TokenType::Eof,
        ],
    );
}

@test
fn numeric_errors() {
    expect_error("0b102"); // invalid digit in binary
    expect_error("0xFG"); // invalid digit in hexadecimal
}

@test
fn matchertext_literals() {
    // one token per literal; quotes, backslashes, and nested matchers stay verbatim
    expect_tokens(
        "M\"(a \"b\" c)\" M\"[x \\ y]\" M\"{(a)[b]{c}}\"",
        [TokenType::MatchertextLiteral, TokenType::MatchertextLiteral, TokenType::MatchertextLiteral, TokenType::Eof],
    );
    // `M` stays an ordinary identifier unless a valid delimiter chain + quote follows
    expect_tokens(
        "M Max M(x) M(\"s\")",
        [
            TokenType::Identifier,
            TokenType::Identifier,
            TokenType::Identifier,
            TokenType::LeftParen,
            TokenType::Identifier,
            TokenType::RightParen,
            TokenType::Identifier,
            TokenType::LeftParen,
            TokenType::StringLiteral,
            TokenType::RightParen,
            TokenType::Eof,
        ],
    );
}

@test
fn matchertext_interpolation() {
    // holes lex as ordinary tokens between Begin/Mid/End segments
    expect_tokens(
        "M{}\"(a {x} b)\"",
        [TokenType::MatchertextBegin, TokenType::Identifier, TokenType::MatchertextEnd, TokenType::Eof],
    );
    expect_tokens(
        "M{}\"({a} {b})\"",
        [
            TokenType::MatchertextBegin,
            TokenType::Identifier,
            TokenType::MatchertextMid,
            TokenType::Identifier,
            TokenType::MatchertextEnd,
            TokenType::Eof,
        ],
    );
    // multi-pair delimiter chain: single braces are plain matchers, `{{` opens the hole
    expect_tokens(
        "M{{}}\"({lit} {{x}})\"",
        [TokenType::MatchertextBegin, TokenType::Identifier, TokenType::MatchertextEnd, TokenType::Eof],
    );
    // matchers inside a hole nest without ending it
    expect_tokens(
        "M()\"[f (g(1)) h]\"",
        [
            TokenType::MatchertextBegin,
            TokenType::Identifier,
            TokenType::LeftParen,
            TokenType::IntegerLiteral,
            TokenType::RightParen,
            TokenType::MatchertextEnd,
            TokenType::Eof,
        ],
    );
}

@test
fn matchertext_errors() {
    expect_error("M\"(a ] b)\""); // wrong-kind close inside the template
    expect_error("M\"(never ends"); // unterminated template
    expect_error("M\"(x)y\""); // closing matcher not followed by the quote
    expect_error("M\"x\""); // content does not open with a matcher
    expect_error("M{}\"(hole {)} bad)\""); // unbalanced matcher inside a hole
    expect_error("M{}\"(open {x"); // EOF inside an interpolation hole
}
