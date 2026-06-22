const EOF_CH: u8 = 0;
const INVALID_SCALAR: u32 = 4_294_967_295;

enum TokenType {
    Identifier,
    TokenAs,
    TokenBreak,
    TokenCase,
    TokenConst,
    TokenContinue,
    TokenDefer,
    TokenElse,
    TokenEnum,
    TokenExtern,
    TokenFalse,
    TokenFn,
    TokenFor,
    TokenIf,
    TokenExtend,
    TokenIn,
    TokenLet,
    TokenSwitch,
    TokenMove,
    TokenMut,
    TokenNew,
    TokenNull,
    TokenReturn,
    SelfLower,
    SelfUpper,
    TokenStruct,
    TokenInterface,
    TokenTrue,
    TokenType,
    TokenUnsafe,
    TokenWhere,
    TokenWhile,
    IntegerLiteral,
    FloatLiteral,
    CharacterLiteral,
    ByteCharacterLiteral,
    StringLiteral,
    RawStringLiteral,
    LeftBrace,
    RightBrace,
    LeftParen,
    RightParen,
    LeftBracket,
    RightBracket,
    Comma,
    Semicolon,
    Colon,
    Dot,
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Tilde,
    Bang,
    Question,
    QuestionQuestion,
    EqualEqual,
    BangEqual,
    LessThan,
    LessThanEqual,
    GreaterThan,
    GreaterThanEqual,
    Ampersand,
    Pipe,
    Caret,
    AmpersandAmpersand,
    PipePipe,
    LeftShift,
    RightShift,
    Equal,
    PlusEqual,
    MinusEqual,
    StarEqual,
    SlashEqual,
    PercentEqual,
    AmpersandEqual,
    PipeEqual,
    CaretEqual,
    LeftShiftEqual,
    RightShiftEqual,
    Range,
    RangeInclusive,
    PathSeparator,
    Arrow,
    FatArrow,
    Eof,
}

struct Token {
    kind: TokenType,
    start: u32,
    len: u32,
}

struct TokenVec {
    data: *mut Token,
    len: usize,
    cap: usize,
}

struct ErrorVec {
    len: usize,
}

struct Lexer {
    bytes: *const u8,
    len: usize,
    start: usize,
    current: usize,
    tokens: TokenVec,
    errors: ErrorVec,
}

struct TokenWriter {
    begin: *mut Token,
    out: *mut Token,
    end: *mut Token,
}

fn lexer_new(source: *const char, len: usize) *mut Lexer {
    let l = new Lexer {
        bytes: source as *const u8,
        len: len,
        start: 0,
        current: 0,
        tokens: new TokenVec { data: null, len: 0, cap: 0 },
        errors: new ErrorVec { len: 0 },
    };
    return l;
}

fn lexer_free(l: *mut Lexer) {
    if (l == null) {
        return;
    }
    free(l->tokens.data);
    free(l);
}

fn is_eof(l: *const Lexer) bool {
    return l->current >= l->len;
}

fn decode_at_b(l: *const Lexer, b: u8, current: usize, size: *mut usize) u32 {
    let mut cp: u32;
    let mut minimum: u32;
    let mut width: usize;

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

    let mut i: usize = 1;
    while (i < width) {
        let continuation = l->bytes[current + i];
        if ((continuation & 0xC0) != 0x80) {
            *size = 0;
            return 0;
        }
        cp = (cp << 6) | (continuation & 0x3F);
        i += 1;
    }

    if (cp < minimum || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
        *size = 0;
        return 0;
    }

    *size = width;
    return cp;
}

fn token_writer_grow(l: *mut Lexer, w: *mut TokenWriter) bool {
    let used = token_writer_used(w);
    l->tokens.len = used;
    if (!token_vec_reserve(&l->tokens, used + 1)) {
        return false;
    }
    w->begin = l->tokens.data;
    w->out = l->tokens.data + used;
    w->end = l->tokens.data + l->tokens.cap;
    return true;
}

fn token_writer_push(l: *mut Lexer, w: *mut TokenWriter, token: Token) {
    if (w->out == w->end && !token_writer_grow(l, w)) {
        abort();
    }
    write_token(w->out, token);
    w->out = w->out + 1;
}

fn add_token(l: *mut Lexer, w: *mut TokenWriter, kind: TokenType) {
    let token = new Token {
        kind: kind,
        start: l->start as u32,
        len: (l->current - l->start) as u32,
    };
    token_writer_push(l, w, token);
}

fn peek_byte(l: *const Lexer) u8 {
    if (is_eof(l)) {
        return EOF_CH;
    }
    return l->bytes[l->current];
}

fn peek_byte_n(l: *const Lexer, n: usize) u8 {
    if (l->current + n >= l->len) {
        return EOF_CH;
    }
    return l->bytes[l->current + n];
}

fn match_byte(l: *mut Lexer, expected: u8) bool {
    if (peek_byte(l) != expected) {
        return false;
    }
    l->current += 1;
    return true;
}

fn lexer_error(l: *mut Lexer, message: str) {
    lexer_error_at(l, l->start, l->current - l->start, message);
}

fn lexer_error_at(l: *mut Lexer, at: usize, len: usize, message: str) {
    push_error(&l->errors, at, len, message);
}

fn is_identifier_part(b: u8) bool {
    return (b >= b'a' && b <= b'z') ||
           (b >= b'A' && b <= b'Z') ||
           (b >= b'0' && b <= b'9') ||
           b == b'_';
}

fn is_dec(b: u8) bool {
    return b >= b'0' && b <= b'9';
}

fn is_hex(b: u8) bool {
    return is_dec(b) ||
           (b >= b'A' && b <= b'F') ||
           (b >= b'a' && b <= b'f');
}

fn is_oct(b: u8) bool {
    return b >= b'0' && b <= b'7';
}

fn is_bin(b: u8) bool {
    return b == b'0' || b == b'1';
}

fn hex_value(b: u8) int {
    if (b <= b'9') {
        return b - b'0';
    }
    if (b <= b'F') {
        return b - b'A' + 10;
    }
    return b - b'a' + 10;
}

fn keywords(lexeme: *const u8, len: usize) TokenType {
    if (len == 2) {
        if (lexeme[0] == b'a' && lexeme[1] == b's') { return TokenType.TokenAs; }
        if (lexeme[0] == b'f' && lexeme[1] == b'n') { return TokenType.TokenFn; }
        if (lexeme[0] == b'i' && lexeme[1] == b'f') { return TokenType.TokenIf; }
        if (lexeme[0] == b'i' && lexeme[1] == b'n') { return TokenType.TokenIn; }
    }
    if (len == 3) {
        if (equal_bytes(lexeme, "for", 3)) { return TokenType.TokenFor; }
        if (equal_bytes(lexeme, "let", 3)) { return TokenType.TokenLet; }
        if (equal_bytes(lexeme, "mut", 3)) { return TokenType.TokenMut; }
        if (equal_bytes(lexeme, "new", 3)) { return TokenType.TokenNew; }
    }
    if (len == 4) {
        if (equal_bytes(lexeme, "case", 4)) { return TokenType.TokenCase; }
        if (equal_bytes(lexeme, "else", 4)) { return TokenType.TokenElse; }
        if (equal_bytes(lexeme, "enum", 4)) { return TokenType.TokenEnum; }
        if (equal_bytes(lexeme, "move", 4)) { return TokenType.TokenMove; }
        if (equal_bytes(lexeme, "null", 4)) { return TokenType.TokenNull; }
        if (equal_bytes(lexeme, "self", 4)) { return TokenType.SelfLower; }
        if (equal_bytes(lexeme, "Self", 4)) { return TokenType.SelfUpper; }
        if (equal_bytes(lexeme, "true", 4)) { return TokenType.TokenTrue; }
        if (equal_bytes(lexeme, "type", 4)) { return TokenType.TokenType; }
    }
    if (len == 5) {
        if (equal_bytes(lexeme, "break", 5)) { return TokenType.TokenBreak; }
        if (equal_bytes(lexeme, "const", 5)) { return TokenType.TokenConst; }
        if (equal_bytes(lexeme, "defer", 5)) { return TokenType.TokenDefer; }
        if (equal_bytes(lexeme, "false", 5)) { return TokenType.TokenFalse; }
        if (equal_bytes(lexeme, "where", 5)) { return TokenType.TokenWhere; }
        if (equal_bytes(lexeme, "while", 5)) { return TokenType.TokenWhile; }
    }
    if (len == 6) {
        if (equal_bytes(lexeme, "extend", 6)) { return TokenType.TokenExtend; }
        if (equal_bytes(lexeme, "extern", 6)) { return TokenType.TokenExtern; }
        if (equal_bytes(lexeme, "return", 6)) { return TokenType.TokenReturn; }
        if (equal_bytes(lexeme, "struct", 6)) { return TokenType.TokenStruct; }
        if (equal_bytes(lexeme, "switch", 6)) { return TokenType.TokenSwitch; }
        if (equal_bytes(lexeme, "unsafe", 6)) { return TokenType.TokenUnsafe; }
    }
    if (len == 8 && equal_bytes(lexeme, "continue", 8)) {
        return TokenType.TokenContinue;
    }
    if (len == 9 && equal_bytes(lexeme, "interface", 9)) {
        return TokenType.TokenInterface;
    }
    return TokenType.Identifier;
}

fn identifier(l: *mut Lexer, w: *mut TokenWriter) {
    let mut i = l->current;
    while (i < l->len && is_identifier_part(l->bytes[i])) {
        i += 1;
    }
    l->current = i;
    let identifier_len = i - l->start;
    if (identifier_len > 9) {
        add_token(l, w, TokenType.Identifier);
    } else {
        add_token(l, w, keywords(l->bytes + l->start, identifier_len));
    }
}

fn validate_utf8_at(l: *mut Lexer, i: *mut usize) bool {
    let mut size: usize = 0;
    decode_at_b(l, l->bytes[*i], *i, &size);
    if (size == 0) {
        lexer_error_at(l, *i, 1, "source is not valid UTF-8");
        *i += 1;
        return false;
    }
    *i += size;
    return true;
}

fn whitespace(l: *mut Lexer) {
    let mut i = l->current;
    while (i < l->len) {
        let b = l->bytes[i];
        if (b == b' ' || b == b'\t' || b == b'\n' || b == b'\r') {
            i += 1;
        } else {
            l->current = i;
            return;
        }
    }
    l->current = i;
}

fn line_comment(l: *mut Lexer) {
    let mut i = l->current;
    while (i < l->len) {
        let b = l->bytes[i];
        if (b == b'\n' || b == b'\r') {
            break;
        }
        if (b == 0) {
            lexer_error_at(l, i, 1, "NUL byte is not allowed in comments");
            i += 1;
        } else if (b >= 0x80) {
            validate_utf8_at(l, &i);
        } else {
            i += 1;
        }
    }
    l->current = i;
}

fn block_comment(l: *mut Lexer) {
    let mut i = l->current;
    let mut depth: usize = 1;
    while (i < l->len) {
        let b = l->bytes[i];
        if (b == b'/' && i + 1 < l->len && l->bytes[i + 1] == b'*') {
            depth += 1;
            i += 2;
        } else if (b == b'*' && i + 1 < l->len && l->bytes[i + 1] == b'/') {
            i += 2;
            depth -= 1;
            if (depth == 0) {
                l->current = i;
                return;
            }
        } else if (b == 0) {
            lexer_error_at(l, i, 1, "NUL byte is not allowed in comments");
            i += 1;
        } else if (b >= 0x80) {
            validate_utf8_at(l, &i);
        } else {
            i += 1;
        }
    }
    l->current = i;
    lexer_error_at(l, l->start, 2, "unterminated block comment");
}

fn escape(l: *mut Lexer, byte_character: bool) u32 {
    if (is_eof(l)) {
        lexer_error_at(l, l->current, 0, "unterminated escape sequence");
        return INVALID_SCALAR;
    }

    let at = l->current - 1;
    let escaped = l->bytes[l->current];
    l->current += 1;

    if (escaped == b'n') { return b'\n'; }
    if (escaped == b'r') { return b'\r'; }
    if (escaped == b't') { return b'\t'; }
    if (escaped == b'\\') { return b'\\'; }
    if (escaped == b'\'') { return b'\''; }
    if (escaped == b'"' && !byte_character) { return b'"'; }
    if (escaped == b'0') { return 0; }

    if (escaped == b'x') {
        if (l->current + 2 <= l->len &&
            is_hex(l->bytes[l->current]) &&
            is_hex(l->bytes[l->current + 1])) {
            let value = (hex_value(l->bytes[l->current]) << 4) |
                        hex_value(l->bytes[l->current + 1]);
            l->current += 2;
            return value as u32;
        }
        lexer_error_at(l, at, l->current - at, "\\x escape requires exactly two hexadecimal digits");
        return INVALID_SCALAR;
    }

    if (escaped == b'u') {
        if (byte_character) {
            lexer_error_at(l, at, l->current - at, "Unicode escapes are not allowed in byte character literals");
            return INVALID_SCALAR;
        }
        if (!match_byte(l, b'{')) {
            lexer_error_at(l, at, l->current - at, "Unicode escape must use \\u{...} syntax");
            return INVALID_SCALAR;
        }
        let mut value: u32 = 0;
        let mut digits: usize = 0;
        while (is_hex(peek_byte(l))) {
            value = (value << 4) | (hex_value(peek_byte(l)) as u32);
            digits += 1;
            l->current += 1;
        }
        if (digits == 0 || digits > 6 || !match_byte(l, b'}')) {
            lexer_error_at(l, at, l->current - at, "Unicode escape requires 1 to 6 hexadecimal digits");
            return INVALID_SCALAR;
        }
        if (value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) {
            lexer_error_at(l, at, l->current - at, "Unicode escape is not a valid Unicode scalar value");
            return INVALID_SCALAR;
        }
        return value;
    }

    lexer_error_at(l, at, l->current - at, "unknown escape sequence");
    return INVALID_SCALAR;
}

fn string(l: *mut Lexer, w: *mut TokenWriter) {
    let mut i = l->current;
    while (i < l->len) {
        let b = l->bytes[i];
        i += 1;
        if (b == b'"') {
            l->current = i;
            add_token(l, w, TokenType.StringLiteral);
            return;
        }
        if (b == b'\\') {
            l->current = i;
            escape(l, false);
            i = l->current;
        } else if (b == b'\n' || b == b'\r') {
            l->current = i - 1;
            lexer_error(l, "unterminated string literal");
            return;
        } else if (b == 0) {
            lexer_error_at(l, i - 1, 1, "NUL byte is not allowed in string literals");
        } else if (b >= 0x80) {
            i -= 1;
            validate_utf8_at(l, &i);
        }
    }
    l->current = i;
    lexer_error(l, "unterminated string literal");
}

fn character(l: *mut Lexer, w: *mut TokenWriter, byte_character: bool) {
    let mut count: usize = 0;
    let mut malformed = false;
    while (!is_eof(l)) {
        let b = l->bytes[l->current];
        l->current += 1;
        if (b == b'\'') {
            if (!malformed && count != 1) {
                lexer_error(l, "character literal must contain exactly one value");
            }
            if (byte_character) {
                add_token(l, w, TokenType.ByteCharacterLiteral);
            } else {
                add_token(l, w, TokenType.CharacterLiteral);
            }
            return;
        }
        if (b == b'\n' || b == b'\r') {
            lexer_error(l, "unterminated character literal");
            return;
        }
        if (b == b'\\') {
            if (escape(l, byte_character) == INVALID_SCALAR) {
                malformed = true;
            } else {
                count += 1;
            }
        } else {
            count += 1;
        }
    }
    lexer_error(l, "unterminated character literal");
}

fn raw_string_ahead(l: *const Lexer, hashes: *mut usize) bool {
    let mut i = l->current;
    while (i < l->len && l->bytes[i] == b'#') {
        i += 1;
    }
    if (i >= l->len || l->bytes[i] != b'"') {
        return false;
    }
    *hashes = i - l->current;
    return true;
}

fn raw_string(l: *mut Lexer, w: *mut TokenWriter, hashes: usize) {
    if (hashes > 255) {
        lexer_error_at(l, l->start, hashes + 1, "raw string delimiter contains more than 255 hashes");
    }
    let mut i = l->current + hashes + 1;
    while (i < l->len) {
        let b = l->bytes[i];
        if (b == b'"' && raw_string_closes(l, i, hashes)) {
            l->current = i + hashes + 1;
            add_token(l, w, TokenType.RawStringLiteral);
            return;
        }
        if (b == 0) {
            lexer_error_at(l, i, 1, "NUL byte is not allowed in raw string literals");
        }
        i += 1;
    }
    l->current = i;
    lexer_error(l, "unterminated raw string literal");
}

fn scan_digits(l: *mut Lexer, component_start: usize, radix: u8, error_at: *mut usize) {
    let mut i = l->current;
    while (i < l->len) {
        let b = l->bytes[i];
        if (is_radix_digit(b, radix)) {
            i += 1;
        } else if (b == b'_') {
            let prev = i > component_start && is_radix_digit(l->bytes[i - 1], radix);
            let next = i + 1 < l->len && is_radix_digit(l->bytes[i + 1], radix);
            if ((!prev || !next) && *error_at == INVALID_SCALAR) {
                *error_at = i;
            }
            i += 1;
        } else {
            break;
        }
    }
    l->current = i;
}

fn number(l: *mut Lexer, w: *mut TokenWriter) {
    let mut error_at: usize = INVALID_SCALAR;
    let mut is_float = false;

    if (l->bytes[l->start] == b'0') {
        let mut radix: u8 = 10;
        if (peek_byte(l) == b'x' || peek_byte(l) == b'X') { radix = 16; }
        if (peek_byte(l) == b'o' || peek_byte(l) == b'O') { radix = 8; }
        if (peek_byte(l) == b'b' || peek_byte(l) == b'B') { radix = 2; }

        if (radix != 10) {
            l->current += 1;
            let component_start = l->current;
            scan_digits(l, component_start, radix, &error_at);
            if (l->current == component_start) {
                lexer_error_at(l, component_start, 1, "radix prefix requires a digit");
            } else if (error_at != INVALID_SCALAR) {
                lexer_error_at(l, error_at, 1, "invalid digit or separator");
            } else {
                add_token(l, w, TokenType.IntegerLiteral);
            }
            return;
        }
    }

    let integer_start = l->current;
    scan_digits(l, integer_start - 1, 10, &error_at);

    if (peek_byte(l) == b'.' && peek_byte_n(l, 1) != b'.') {
        is_float = true;
        l->current += 1;
        scan_digits(l, l->current, 10, &error_at);
    }

    if (peek_byte(l) == b'e' || peek_byte(l) == b'E') {
        is_float = true;
        l->current += 1;
        if (peek_byte(l) == b'+' || peek_byte(l) == b'-') {
            l->current += 1;
        }
        let exponent_start = l->current;
        scan_digits(l, exponent_start, 10, &error_at);
        if (l->current == exponent_start) {
            lexer_error_at(l, exponent_start, 1, "exponent requires a decimal digit");
            return;
        }
    }

    if (error_at != INVALID_SCALAR) {
        lexer_error_at(l, error_at, 1, "invalid numeric separator");
    } else if (is_float) {
        add_token(l, w, TokenType.FloatLiteral);
    } else {
        add_token(l, w, TokenType.IntegerLiteral);
    }
}

fn leading_dot_number(l: *mut Lexer) {
    while (is_identifier_part(peek_byte(l)) || peek_byte(l) == b'.') {
        l->current += 1;
    }
    lexer_error(l, "floating-point literals require a digit before the decimal point");
}

fn scan_token(l: *mut Lexer, w: *mut TokenWriter) {
    let c = l->bytes[l->current];
    if (c < 0x80) {
        l->current += 1;
    }

    if (c == b' ' || c == b'\t' || c == b'\n' || c == b'\r') {
        whitespace(l);
        return;
    }
    if (c == b'{') { add_token(l, w, TokenType.LeftBrace); return; }
    if (c == b'}') { add_token(l, w, TokenType.RightBrace); return; }
    if (c == b'(') { add_token(l, w, TokenType.LeftParen); return; }
    if (c == b')') { add_token(l, w, TokenType.RightParen); return; }
    if (c == b'[') { add_token(l, w, TokenType.LeftBracket); return; }
    if (c == b']') { add_token(l, w, TokenType.RightBracket); return; }
    if (c == b',') { add_token(l, w, TokenType.Comma); return; }
    if (c == b';') { add_token(l, w, TokenType.Semicolon); return; }
    if (c == b':') {
        if (match_byte(l, b':')) { add_token(l, w, TokenType.PathSeparator); }
        else { add_token(l, w, TokenType.Colon); }
        return;
    }
    if (c == b'+') {
        if (match_byte(l, b'=')) { add_token(l, w, TokenType.PlusEqual); }
        else { add_token(l, w, TokenType.Plus); }
        return;
    }
    if (c == b'-') {
        if (match_byte(l, b'>')) { add_token(l, w, TokenType.Arrow); }
        else if (match_byte(l, b'=')) { add_token(l, w, TokenType.MinusEqual); }
        else { add_token(l, w, TokenType.Minus); }
        return;
    }
    if (c == b'*') {
        if (match_byte(l, b'=')) { add_token(l, w, TokenType.StarEqual); }
        else { add_token(l, w, TokenType.Star); }
        return;
    }
    if (c == b'/') {
        if (match_byte(l, b'/')) { line_comment(l); }
        else if (match_byte(l, b'*')) { block_comment(l); }
        else if (match_byte(l, b'=')) { add_token(l, w, TokenType.SlashEqual); }
        else { add_token(l, w, TokenType.Slash); }
        return;
    }
    if (c == b'=') {
        if (match_byte(l, b'=')) { add_token(l, w, TokenType.EqualEqual); }
        else if (match_byte(l, b'>')) { add_token(l, w, TokenType.FatArrow); }
        else { add_token(l, w, TokenType.Equal); }
        return;
    }
    if (c == b'!') {
        if (match_byte(l, b'=')) { add_token(l, w, TokenType.BangEqual); }
        else { add_token(l, w, TokenType.Bang); }
        return;
    }
    if (c == b'<') {
        if (match_byte(l, b'<')) {
            if (match_byte(l, b'=')) { add_token(l, w, TokenType.LeftShiftEqual); }
            else { add_token(l, w, TokenType.LeftShift); }
        } else if (match_byte(l, b'=')) {
            add_token(l, w, TokenType.LessThanEqual);
        } else {
            add_token(l, w, TokenType.LessThan);
        }
        return;
    }
    if (c == b'>') {
        if (match_byte(l, b'>')) {
            if (match_byte(l, b'=')) { add_token(l, w, TokenType.RightShiftEqual); }
            else { add_token(l, w, TokenType.RightShift); }
        } else if (match_byte(l, b'=')) {
            add_token(l, w, TokenType.GreaterThanEqual);
        } else {
            add_token(l, w, TokenType.GreaterThan);
        }
        return;
    }
    if (c == b'.') {
        if (is_dec(peek_byte(l))) {
            leading_dot_number(l);
        } else if (match_byte(l, b'.')) {
            if (match_byte(l, b'=')) { add_token(l, w, TokenType.RangeInclusive); }
            else { add_token(l, w, TokenType.Range); }
        } else {
            add_token(l, w, TokenType.Dot);
        }
        return;
    }
    if (c == b'"') { string(l, w); return; }
    if (c == b'\'') { character(l, w, false); return; }
    if (is_dec(c)) { number(l, w); return; }

    if (c == b'r') {
        let mut hashes: usize = 0;
        if (raw_string_ahead(l, &hashes)) {
            raw_string(l, w, hashes);
        } else {
            identifier(l, w);
        }
        return;
    }
    if (c == b'b' && peek_byte(l) == b'\'') {
        l->current += 1;
        character(l, w, true);
        return;
    }
    if (is_identifier_part(c)) {
        identifier(l, w);
        return;
    }
    if (c == 0) {
        lexer_error_at(l, l->start, 1, "NUL byte is not allowed in source");
        return;
    }
    if (c >= 0x80) {
        let mut size: usize = 0;
        decode_at_b(l, c, l->current, &size);
        if (size == 0) {
            lexer_error_at(l, l->start, 1, "source is not valid UTF-8");
            l->current += 1;
        } else {
            l->current += size;
            lexer_error_at(l, l->start, size, "identifiers may contain only ASCII");
        }
        return;
    }
    lexer_error_at(l, l->start, 1, "unexpected character");
}

fn lexer_scan_tokens(l: *mut Lexer) {
    token_vec_reserve(&l->tokens, l->len / 5);
    let mut w = new TokenWriter {
        begin: l->tokens.data,
        out: l->tokens.data,
        end: l->tokens.data + l->tokens.cap,
    };

    if (l->current == 0 &&
        l->len >= 3 &&
        l->bytes[0] == 0xEF &&
        l->bytes[1] == 0xBB &&
        l->bytes[2] == 0xBF) {
        l->current = 3;
    }

    while (l->current < l->len) {
        l->start = l->current;
        scan_token(l, &w);
    }

    let eof = new Token {
        kind: TokenType.Eof,
        start: l->len as u32,
        len: 0,
    };
    token_writer_push(l, &w, eof);
    l->tokens.len = token_writer_used(&w);
}

fn lexer_take_tokens(l: *mut Lexer) TokenVec {
    let out = move l->tokens;
    l->tokens = new TokenVec { data: null, len: 0, cap: 0 };
    return out;
}
