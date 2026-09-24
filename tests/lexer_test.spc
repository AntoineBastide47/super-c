// Self-hosted port of tests/lexer_test.c: drives lexer::Lexer over source and checks the token-type stream
// (keywords, tuple-access `.digit` vs float, and error diagnostics). Part of the selfhost/tests suite.
import lexer::token as *;
import lexer::token_type as *;
import lexer::lexer as *;
import tests::harness as h;

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
    // Invalid digit in binary.
    expect_error("0b102");
    // Invalid digit in hexadecimal.
    expect_error("0xFG");
}

// A radix literal keeps a '.' only as a fraction (a digit, or a hex run with a 'p' exponent, follows);
// any other '.' is a range or a member access, as after a decimal literal.
@test
fn radix_literal_dots() {
    expect_tokens("0x0..0x4", [TokenType::IntegerLiteral, TokenType::Range, TokenType::IntegerLiteral, TokenType::Eof]);
    expect_tokens(
        "0b1..=0b10",
        [TokenType::IntegerLiteral, TokenType::RangeInclusive, TokenType::IntegerLiteral, TokenType::Eof],
    );
    expect_tokens(
        "0xFF.dbl()",
        [
            TokenType::IntegerLiteral,
            TokenType::Dot,
            TokenType::Identifier,
            TokenType::LeftParen,
            TokenType::RightParen,
            TokenType::Eof,
        ],
    );
    expect_tokens("0xFFu32.x", [TokenType::IntegerLiteral, TokenType::Dot, TokenType::Identifier, TokenType::Eof]);
    expect_tokens("0o7.x", [TokenType::IntegerLiteral, TokenType::Dot, TokenType::Identifier, TokenType::Eof]);
    expect_tokens("0x1.8p3", [TokenType::FloatLiteral, TokenType::Eof]);
    expect_tokens("0x1.ap-2", [TokenType::FloatLiteral, TokenType::Eof]);
    expect_error("0x1.8");
    expect_error("0b1.1");
}

// A Token stores its length in 24 bits: a longer lexeme is diagnosed, never packed into the kind bits.
@test
fn token_length_limit() {
    let mut s = String::with_capacity(TOKEN_MAX_LEN + 3);
    s.push_str("\"");
    for _ in 0..TOKEN_MAX_LEN {
        s.push_str("a");
    }
    s.push_str("\"");
    expect_error(s.as_str());
}

@test
fn matchertext_literals() {
    // One token per literal; quotes, backslashes, and nested matchers stay verbatim.
    expect_tokens(
        "M\"(a \"b\" c)\" M\"[x \\ y]\" M\"{(a)[b]{c}}\"",
        [TokenType::MatchertextLiteral, TokenType::MatchertextLiteral, TokenType::MatchertextLiteral, TokenType::Eof],
    );
    // `M` stays an ordinary identifier unless a valid delimiter chain + quote follows.
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
    // Holes lex as ordinary tokens between Begin/Mid/End segments.
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
    // Multi-pair delimiter chain: single braces are plain matchers, `{{` opens the hole.
    expect_tokens(
        "M{{}}\"({lit} {{x}})\"",
        [TokenType::MatchertextBegin, TokenType::Identifier, TokenType::MatchertextEnd, TokenType::Eof],
    );
    // Matchers inside a hole nest without ending it.
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
    // Wrong-kind close inside the template.
    expect_error("M\"(a ] b)\"");
    // Unterminated template.
    expect_error("M\"(never ends");
    // Closing matcher not followed by the quote.
    expect_error("M\"(x)y\"");
    // Content does not open with a matcher.
    expect_error("M\"x\"");
    // Unbalanced matcher inside a hole.
    expect_error("M{}\"(hole {)} bad)\"");
    // EOF inside an interpolation hole.
    expect_error("M{}\"(open {x");
    // A delimiter chain longer than 255 matcher pairs.
    let mut d = String::from_str("M");
    for _ in 0..256 {
        d.push_str("(");
    }
    for _ in 0..256 {
        d.push_str(")");
    }
    d.push_str("\"(x)\"");
    expect_error(d.as_str());
}

// Every lexer diagnostic, by message: the harness stops at the lex stage and reports the first one.
@test
fn diagnostics_by_message() {
    h::expect_err_msg(
        "preprocessor",
        "#define X 1\nfn main() i32 { return 0; }\n",
        "'#' is not valid in Super-C source; Super-C has no preprocessor",
    );
    h::expect_err_msg("dollar", "fn main() i32 { $ return 0; }\n", "'$' is reserved");
    h::expect_err_msg("backtick", "fn main() i32 { ` return 0; }\n", "'`' is reserved");
    h::expect_err_msg(
        "nul in char",
        "fn main() i32 { let c = '\x00'; return 0; }\n",
        "NUL byte is not allowed in character literals",
    );
    h::expect_err_msg(
        "nul in comment",
        "// a\x00b\nfn main() i32 { return 0; }\n",
        "NUL byte is not allowed in comments",
    );
    h::expect_err_msg(
        "nul in matchertext",
        "fn main() i32 { let s = M\"(a\x00b)\"; return 0; }\n",
        "NUL byte is not allowed in matchertext literals",
    );
    h::expect_err_msg("nul in source", "fn\x00main() i32 { return 0; }\n", "NUL byte is not allowed in source");
    h::expect_err_msg(
        "late BOM",
        "fn main() i32 { return 0; }\n\xEF\xBB\xBF",
        "UTF-8 BOM is allowed only at the start of a file",
    );
    h::expect_err_msg(
        "surrogate escape",
        "fn main() i32 { let c = '\\u{D800}'; return 0; }\n",
        "Unicode escape is not a valid Unicode scalar value",
    );
    h::expect_err_msg(
        "bare \\u",
        "fn main() i32 { let c = '\\u0041'; return 0; }\n",
        "Unicode escape must use \\u{...} syntax",
    );
    h::expect_err_msg(
        "empty \\u{}",
        "fn main() i32 { let c = '\\u{}'; return 0; }\n",
        "Unicode escape requires 1 to 6 hexadecimal digits",
    );
    h::expect_err_msg(
        "seven-digit \\u{}",
        "fn main() i32 { let c = '\\u{1234567}'; return 0; }\n",
        "Unicode escape requires 1 to 6 hexadecimal digits",
    );
    h::expect_err_msg(
        "\\u in byte char",
        "fn main() i32 { let c = b'\\u{41}'; return 0; }\n",
        "Unicode escapes are not allowed in byte character literals",
    );
    h::expect_err_msg(
        "short \\x",
        "fn main() i32 { let c = '\\xG1'; return 0; }\n",
        "\\x escape requires exactly two hexadecimal digits",
    );
    h::expect_err_msg(
        "non-ASCII byte char",
        "fn main() i32 { let c = b'\xC3\xA9'; return 0; }\n",
        "byte character literal may contain only ASCII or a \\xNN escape",
    );
    h::expect_err_msg(
        "two-byte byte char",
        "fn main() i32 { let c = b'ab'; return 0; }\n",
        "byte character literal must contain exactly one byte",
    );
    h::expect_err_msg(
        "two-scalar char",
        "fn main() i32 { let c = 'ab'; return 0; }\n",
        "character literal must contain exactly one Unicode scalar value",
    );
    h::expect_err_msg(
        "non-ASCII identifier",
        "fn main() i32 { let caf\xC3\xA9 = 1; return 0; }\n",
        "identifiers may contain only ASCII letters, digits, and '_'",
    );
    h::expect_err_msg(
        "undelimited matchertext",
        "fn main() i32 { let s = M\"abc\"; return 0; }\n",
        "matchertext content must be delimited by '(', '[', or '{' inside the quotes",
    );
    h::expect_err_msg(
        "matchertext tail",
        "fn main() i32 { let s = M\"(abc)x\"; return 0; }\n",
        "matchertext literal must end with '\"' right after the closing matcher",
    );
    h::expect_err_msg("invalid UTF-8", "fn main() i32 { \xFF return 0; }\n", "source is not valid UTF-8");
    h::expect_err_msg(
        "unbalanced hole",
        "fn main() i32 { let s = M{}\"(a{)}b)\"; return 0; }\n",
        "unbalanced matcher in matchertext interpolation hole",
    );
    h::expect_err_msg("stray backslash", "fn main() i32 { \\ return 0; }\n", "unexpected character '\\'");
    h::expect_err_msg("unknown escape", "fn main() i32 { let s = \"\\q\"; return 0; }\n", "unknown escape sequence");
    h::expect_err_msg("open block comment", "/* abc\nfn main() i32 { return 0; }\n", "unterminated block comment");
    h::expect_err_msg(
        "open char literal",
        "fn f(x: &'5 i32) {}\nfn main() i32 { return 0; }\n",
        "unterminated character literal",
    );
    h::expect_err_msg("open escape", "fn main() i32 { let s = \"\\", "unterminated escape sequence");
    h::expect_err_msg("open matchertext", "fn main() i32 { let s = M\"(abc", "unterminated matchertext literal");
    h::expect_err_msg(
        "open hole",
        "fn main() i32 { let s = M{}\"(a{b",
        "unterminated matchertext literal (unclosed interpolation hole)",
    );
    h::expect_err_msg("open string", "fn main() i32 { let s = \"abc; return 0; }\n", "unterminated string literal");
}
