import string as cstring;
import lexer::token as *;
import lexer::token_type as *;
import utils::errors as diag;

pub const EOF_CH: u8 = 0;
pub const UINT32_MAX: u32 = 0xFFFFFFFFu32;
pub const USIZE_MAX: usize = 0xFFFFFFFFFFFFFFFFu64 as usize;

// Read-ahead sentinel padding a lexed source buffer MUST carry past its logical end (all NUL): the loader
// pads every module source (String::pad_nul) so the lexer's scan loops (identifier/whitespace) can drop
// their per-byte bounds check and rely on the trailing NUL to terminate. Only 1 byte is strictly required.
pub const SOURCE_PAD: usize = 8;

// Per-byte character-class flags, indexed by byte value (see build_char_class). Held BY VALUE in each Lexer
// so there is no global mutable state (the compiler lexes many sources, possibly concurrently in-process).
pub const CC_ID_START: u8 = 1u8;
pub const CC_ID_PART: u8 = 2u8;
pub const CC_DIGIT: u8 = 4u8;
pub const CC_HEX: u8 = 8u8;
pub const CC_WS: u8 = 16u8;
pub type CharClass = Array<u8, 256>;

fn build_char_class() CharClass {
    let mut c = CharClass {};
    let mut i: usize = 0;
    while i < 256 {
        let b = i as u8;
        let is_lower = b >= b'a' && b <= b'z';
        let is_upper = b >= b'A' && b <= b'Z';
        let is_digit = b >= b'0' && b <= b'9';
        let mut fl: u8 = 0u8;
        if b == b'_' || is_lower || is_upper {
            fl = fl | CC_ID_START | CC_ID_PART;
        }
        if is_digit {
            fl = fl | CC_ID_PART | CC_DIGIT | CC_HEX;
        }
        if b >= b'a' && b <= b'f' || b >= b'A' && b <= b'F' {
            fl = fl | CC_HEX;
        }
        if b == b' ' || b == b'\t' || b == b'\n' || b == b'\x0b' || b == b'\x0c' || b == b'\r' {
            fl = fl | CC_WS;
        }
        c[i] = fl;
        i = i + 1;
    }
    return c;
}

pub struct Lexer {
    pub bytes: str,
    pub start: usize,
    pub current: usize,
    pub file: str,
    pub tokens: Vector<Token>,
    pub errors: diag::Errors,
    pub class: CharClass,
    pub keep_trivia: bool, // emit comment tokens (the formatter); off for the parser path
}

extend Lexer {
    // Creates a new Lexer instance used to lex the given source file's content
    pub fn new(source: &mut String, file: str) Lexer {
        source.pad_nul(SOURCE_PAD);
        return Lexer {
            bytes: source.as_str(),
            start: 0,
            current: 0,
            file: file,
            tokens: Vector::<Token>::new(),
            errors: diag::Errors::new(),
            class: build_char_class(),
            keep_trivia: false,
        };
    }
}

extend Lexer as Free {
    pub fn free(self: &mut Self) {
        self.tokens.free();
        self.errors.free();
    }
}

fn is_eof(l: &Lexer) bool {
    return l.current >= l.bytes.len();
}

fn is_id_start(b: u8) bool {
    return b == '_' || b >= b'a' && b <= b'z' || b >= b'A' && b <= b'Z';
}

fn is_id_part_byte(b: u8) bool {
    return is_id_start(b) || b >= b'0' && b <= b'9';
}

fn is_dec(b: u8) bool {
    return b >= b'0' && b <= b'9';
}
fn is_hex(b: u8) bool {
    return is_dec(b) || b >= b'A' && b <= b'F' || b >= b'a' && b <= b'f';
}
fn is_oct(b: u8) bool {
    return b >= b'0' && b <= b'7';
}
fn is_bin(b: u8) bool {
    return b == b'0' || b == b'1';
}

fn hex_value(b: u8) i32 {
    if b <= b'9' {
        return b - b'0';
    }
    if b <= b'F' {
        return b - b'A' + 10;
    }
    return b - b'a' + 10;
}

fn add_token(l: &mut Lexer, token_type: TokenType) {
    l.tokens.push(Token::new(token_type, l.start as u32, (l.current - l.start) as u32));
}

fn add_match(l: &mut Lexer, expected: u8, matched: TokenType, unmatched: TokenType) {
    let kind = if match_byte(l, expected) {
        matched;
    } else {
        unmatched;
    };
    add_token(l, kind);
}

fn peek_byte(l: &Lexer) u8 {
    if is_eof(l) {
        return EOF_CH;
    }
    return l.bytes.byte_at(l.current);
}

fn peek_next(l: &Lexer) u8 {
    if l.current + 1 >= l.bytes.len() {
        return EOF_CH;
    }
    return l.bytes.byte_at(l.current + 1);
}

fn match_byte(l: &mut Lexer, expected: u8) bool {
    if peek_byte(l) != expected {
        return false;
    }
    l.current = l.current + 1;
    return true;
}

@c.cold
fn lexer_error(l: &mut Lexer, message: str) {
    l.errors.emit(l.start as u32, (l.current - l.start) as u32, String::from_str(message));
}

@c.cold
fn lexer_error_at(l: &mut Lexer, at: usize, len: usize, message: str) {
    l.errors.emit(at as u32, len as u32, String::from_str(message));
}

fn decode_at_b(l: &Lexer, b: u8, current: usize, size: &mut usize) u32 {
    let mut minimum: u32 = 0x10000;
    let mut width: usize = 4;
    if b <= 0xDFu8 {
        minimum = 0x80;
        width = 2;
    } else if b <= 0xEFu8 {
        minimum = 0x800;
        width = 3;
    }
    let mut cp: u32 = 0;
    if b >= 0xC2u8 && b <= 0xDFu8 {
        cp = b & 0x1Fu8;
    } else if b >= 0xE0u8 && b <= 0xEFu8 {
        cp = b & 0x0Fu8;
    } else if b >= 0xF0u8 && b <= 0xF4u8 {
        cp = b & 0x07u8;
    } else {
        *size = 0;
        return 0;
    }
    if current + width > l.bytes.len() {
        *size = 0;
        return 0;
    }
    for i in 1..width {
        let continuation = l.bytes.byte_at(current + i);
        if (continuation & 0xC0u8) != 0x80u8 {
            *size = 0;
            return 0;
        }
        cp = cp << 6 | (continuation & 0x3Fu8) as u32;
    }
    if cp < minimum || cp > 0x10FFFF || cp >= 0xD800 && cp <= 0xDFFF {
        *size = 0;
        return 0;
    }
    *size = width;
    return cp;
}

fn memeq(p: *const u8, text: str) bool {
    return unsafe cstring::memcmp(p, text.ptr(), text.len()) == 0;
}

fn keywords(lexeme: *const u8, len: usize) TokenType {
    let first = unsafe lexeme[0];
    switch len {
        2 => {
            if first == b'a' && memeq(lexeme, "as") {
                return TokenType::As;
            }
            if first == b'd' && memeq(lexeme, "do") {
                return TokenType::Do;
            }
            if first == b'f' && memeq(lexeme, "fn") {
                return TokenType::Fn;
            }
            if first == b'i' && memeq(lexeme, "if") {
                return TokenType::If;
            }
            if first == b'i' && memeq(lexeme, "in") {
                return TokenType::In;
            }
        },
        3 => {
            if first == b'd' && memeq(lexeme, "dyn") {
                return TokenType::Dyn;
            }
            if first == b'f' && memeq(lexeme, "for") {
                return TokenType::For;
            }
            if first == b'l' && memeq(lexeme, "let") {
                return TokenType::Let;
            }
            if first == b'm' && memeq(lexeme, "mut") {
                return TokenType::Mut;
            }
            if first == b'n' && memeq(lexeme, "new") {
                return TokenType::New;
            }
            if first == b'p' && memeq(lexeme, "pub") {
                return TokenType::Pub;
            }
        },
        4 => {
            if first == b'c' && memeq(lexeme, "case") {
                return TokenType::Case;
            }
            if first == b'e' && memeq(lexeme, "else") {
                return TokenType::Else;
            }
            if first == b'e' && memeq(lexeme, "enum") {
                return TokenType::Enum;
            }
            if first == b'l' && memeq(lexeme, "loop") {
                return TokenType::Loop;
            }
            if first == b'm' && memeq(lexeme, "move") {
                return TokenType::Move;
            }
            if first == b'n' && memeq(lexeme, "null") {
                return TokenType::Null;
            }
            if first == b's' && memeq(lexeme, "self") {
                return TokenType::SelfLower;
            }
            if first == b'S' && memeq(lexeme, "Self") {
                return TokenType::SelfUpper;
            }
            if first == b't' && memeq(lexeme, "true") {
                return TokenType::True;
            }
            if first == b't' && memeq(lexeme, "type") {
                return TokenType::Type;
            }
        },
        5 => {
            if first == b'b' && memeq(lexeme, "break") {
                return TokenType::Break;
            }
            if first == b'c' && memeq(lexeme, "const") {
                return TokenType::Const;
            }
            if first == b'd' && memeq(lexeme, "defer") {
                return TokenType::Defer;
            }
            if first == b'f' && memeq(lexeme, "false") {
                return TokenType::False;
            }
            if first == b'u' && memeq(lexeme, "union") {
                return TokenType::Union;
            }
            if first == b'w' && memeq(lexeme, "where") {
                return TokenType::Where;
            }
            if first == b'w' && memeq(lexeme, "while") {
                return TokenType::While;
            }
        },
        6 => {
            if first == b'e' && memeq(lexeme, "extend") {
                return TokenType::Extend;
            }
            if first == b'e' && memeq(lexeme, "extern") {
                return TokenType::Extern;
            }
            if first == b'i' && memeq(lexeme, "import") {
                return TokenType::Import;
            }
            if first == b'r' && memeq(lexeme, "return") {
                return TokenType::Return;
            }
            if first == b's' && memeq(lexeme, "struct") {
                return TokenType::Struct;
            }
            if first == b's' && memeq(lexeme, "static") {
                return TokenType::Static;
            }
            if first == b's' && memeq(lexeme, "switch") {
                return TokenType::Switch;
            }
            if first == b's' && memeq(lexeme, "sizeof") {
                return TokenType::Sizeof;
            }
            if first == b'u' && memeq(lexeme, "unsafe") {
                return TokenType::Unsafe;
            }
            if first == b'v' && memeq(lexeme, "va_arg") {
                return TokenType::VaArg;
            }
            if first == b'v' && memeq(lexeme, "va_end") {
                return TokenType::VaEnd;
            }
        },
        7 => {
            if memeq(lexeme, "alignof") {
                return TokenType::Alignof;
            }
        },
        8 => {
            if memeq(lexeme, "continue") {
                return TokenType::Continue;
            }
            if memeq(lexeme, "va_start") {
                return TokenType::VaStart;
            }
        },
        9 => {
            if memeq(lexeme, "interface") {
                return TokenType::Interface;
            }
        },
        13 => {
            if memeq(lexeme, "static_assert") {
                return TokenType::StaticAssert;
            }
        },
        _ => {},
    };
    return TokenType::Identifier;
}

fn identifier(l: &mut Lexer) {
    // Scan the [_A-Za-z0-9] run via the class table. No bounds check: the trailing-NUL sentinel (SOURCE_PAD)
    // is not id-part, so the run stops at (or before) len -- exactly the old boundary.
    let mut i = l.current;
    while (l.class[l.bytes.byte_at(i) as usize] & CC_ID_PART) != 0u8 {
        i = i + 1;
    }
    l.current = i;
    let identifier_len = i - l.start;
    if identifier_len == 1 && l.bytes.byte_at(l.start) == b'_' {
        add_token(l, TokenType::Underscore);
        return;
    }
    let mut kind = TokenType::Identifier;
    if 2 <= identifier_len && identifier_len <= 13 {
        kind = keywords(unsafe (l.bytes.ptr() + l.start), identifier_len);
    }
    add_token(l, kind);
}

fn validate_utf8_at(l: &mut Lexer, i: &mut usize) bool {
    let mut size: usize = 0;
    decode_at_b(l, l.bytes.byte_at(*i), *i, &mut size);
    if size == 0 {
        lexer_error_at(l, *i, 1, "source is not valid UTF-8");
        *i = *i + 1;
        return false;
    }
    *i = *i + size;
    return true;
}

fn whitespace(l: &mut Lexer) {
    // Skip a maximal run of whitespace bytes via the class table. No bounds check: the trailing-NUL sentinel
    // is not WS, so the run stops at (or before) len. '\r' and '\n' are both WS, so advancing one byte at a
    // time is identical to the old explicit CRLF handling.
    let mut i = l.current;
    while (l.class[l.bytes.byte_at(i) as usize] & CC_WS) != 0u8 {
        i = i + 1;
    }
    l.current = i;
}

fn line_comment(l: &mut Lexer) {
    let mut i = l.current;
    while i < l.bytes.len() {
        let b = l.bytes.byte_at(i);
        if b == b'\n' || b == b'\r' {
            break;
        }
        if b == b'\0' {
            lexer_error_at(l, i, 1, "NUL byte is not allowed in comments");
            i = i + 1;
        } else if b >= 0x80u8 {
            validate_utf8_at(l, &mut i);
        } else {
            i = i + 1;
        }
    }
    l.current = i;
}

fn block_comment(l: &mut Lexer) {
    let mut i = l.current;
    let mut depth: usize = 1;
    while i < l.bytes.len() {
        let b = l.bytes.byte_at(i);
        if b == b'/' && i + 1 < l.bytes.len() && l.bytes.byte_at(i + 1) == b'*' {
            depth = depth + 1;
            i = i + 2;
        } else if b == b'*' && i + 1 < l.bytes.len() && l.bytes.byte_at(i + 1) == b'/' {
            i = i + 2;
            depth = depth - 1;
            if depth == 0 {
                l.current = i;
                return;
            }
        } else if b == b'\0' {
            lexer_error_at(l, i, 1, "NUL byte is not allowed in comments");
            i = i + 1;
        } else if b >= 0x80u8 {
            validate_utf8_at(l, &mut i);
        } else {
            i = i + 1;
        }
    }
    l.current = i;
    let start = l.start;
    lexer_error_at(l, start, 2, "unterminated block comment");
}

fn escape(l: &mut Lexer, byte_character: bool) u32 {
    if is_eof(l) {
        let current = l.current;
        lexer_error_at(l, current, 0, "unterminated escape sequence");
        return UINT32_MAX;
    }
    let at = l.current - 1;
    let escaped = l.bytes.byte_at(l.current);
    l.current = l.current + 1;
    if escaped == b'n' {
        return 10;
    }
    if escaped == b'r' {
        return 13;
    }
    if escaped == b't' {
        return 9;
    }
    if escaped == b'\\' {
        return '\\';
    }
    if escaped == b'\'' {
        return '\'';
    }
    if escaped == b'"' && !byte_character {
        return '"';
    }
    if escaped == b'0' {
        return 0;
    }
    if escaped == b'x' {
        if l.current + 2 <= l.bytes.len() && is_hex(l.bytes.byte_at(l.current)) && is_hex(
            l.bytes.byte_at(l.current + 1),
        ) {
            let value = (hex_value(l.bytes.byte_at(l.current)) << 4 | hex_value(l.bytes.byte_at(l.current + 1))) as u32;
            l.current = l.current + 2;
            return value;
        }
        let err_len = l.current - at;
        lexer_error_at(l, at, err_len, "\\x escape requires exactly two hexadecimal digits");
        while l.current < l.bytes.len() && l.current < at + 4 && is_hex(l.bytes.byte_at(l.current)) {
            l.current = l.current + 1;
        }
        return UINT32_MAX;
    }
    if escaped == b'u' {
        if byte_character {
            if match_byte(l, b'{') {
                while is_hex(peek_byte(l)) {
                    l.current = l.current + 1;
                }
                match_byte(l, b'}');
            }
            let err_len = l.current - at;
            lexer_error_at(l, at, err_len, "Unicode escapes are not allowed in byte character literals");
            return UINT32_MAX;
        }
        if !match_byte(l, b'{') {
            let err_len = l.current - at;
            lexer_error_at(l, at, err_len, "Unicode escape must use \\u{...} syntax");
            return UINT32_MAX;
        }
        let mut value: u32 = 0;
        let mut digits: usize = 0;
        while is_hex(peek_byte(l)) {
            if digits < 6 {
                value = value << 4 | hex_value(peek_byte(l)) as u32;
            }
            digits = digits + 1;
            l.current = l.current + 1;
        }
        if digits == 0 || digits > 6 || !match_byte(l, b'}') {
            let err_len = l.current - at;
            lexer_error_at(l, at, err_len, "Unicode escape requires 1 to 6 hexadecimal digits");
            return UINT32_MAX;
        }
        if value > 0x10FFFF || value >= 0xD800 && value <= 0xDFFF {
            let err_len = l.current - at;
            lexer_error_at(l, at, err_len, "Unicode escape is not a valid Unicode scalar value");
            return UINT32_MAX;
        }
        return value;
    }
    let err_len = l.current - at;
    lexer_error_at(l, at, err_len, "unknown escape sequence");
    return UINT32_MAX;
}

fn string_lit(l: &mut Lexer, kind: TokenType) {
    let mut i = l.current;
    while i < l.bytes.len() {
        let b = l.bytes.byte_at(i);
        i = i + 1;
        if b == b'"' {
            l.current = i;
            add_token(l, kind);
            return;
        }
        if b == b'\\' {
            l.current = i;
            escape(l, false);
            i = l.current;
        } else if b == b'\n' || b == b'\r' {
            l.current = i - 1;
            lexer_error(l, "unterminated string literal");
            while l.current < l.bytes.len() {
                let recovery = l.bytes.byte_at(l.current);
                l.current = l.current + 1;
                if recovery == b'"' {
                    break;
                }
            }
            return;
        } else if b == b'\0' {
            lexer_error_at(l, i - 1, 1, "NUL byte is not allowed in string literals");
        } else if b >= 0x80u8 {
            i = i - 1;
            validate_utf8_at(l, &mut i);
        }
    }
    l.current = i;
    lexer_error(l, "unterminated string literal");
}

fn label_ahead(l: &Lexer) bool {
    let mut i = l.current;
    let mut b: u8 = 0;
    if i < l.bytes.len() {
        b = l.bytes.byte_at(i);
    }
    if !is_id_start(b) {
        return false;
    }
    while i < l.bytes.len() && is_id_part_byte(l.bytes.byte_at(i)) {
        i = i + 1;
    }
    return i >= l.bytes.len() || l.bytes.byte_at(i) != b'\'';
}

fn character(l: &mut Lexer, byte_character: bool) {
    let mut count: usize = 0;
    let mut malformed = false;
    let mut invalid_byte = false;
    while !is_eof(l) {
        let b = l.bytes.byte_at(l.current);
        l.current = l.current + 1;
        if b == b'\'' {
            if !malformed && count != 1 {
                if byte_character {
                    lexer_error(l, "byte character literal must contain exactly one byte");
                } else {
                    lexer_error(l, "character literal must contain exactly one Unicode scalar value");
                }
            } else if invalid_byte {
                lexer_error(l, "byte character literal may contain only ASCII or a \\xNN escape");
            }
            if byte_character {
                add_token(l, TokenType::ByteCharacterLiteral);
            } else {
                add_token(l, TokenType::CharacterLiteral);
            }
            return;
        }
        if b == b'\n' || b == b'\r' {
            l.current = l.current - 1;
            lexer_error(l, "unterminated character literal");
            return;
        }
        if b == b'\0' {
            let at = l.current - 1;
            lexer_error_at(l, at, 1, "NUL byte is not allowed in character literals");
            count = count + 1;
        } else if b == b'\\' {
            if escape(l, byte_character) == UINT32_MAX {
                malformed = true;
            } else {
                count = count + 1;
            }
        } else if b < 0x80u8 {
            count = count + 1;
        } else {
            let mut size: usize = 0;
            decode_at_b(l, b, l.current - 1, &mut size);
            if size == 0 {
                let at = l.current - 1;
                lexer_error_at(l, at, 1, "source is not valid UTF-8");
                malformed = true;
            } else {
                l.current = l.current + size - 1;
                count = count + 1;
                invalid_byte = byte_character;
            }
        }
    }
    lexer_error(l, "unterminated character literal");
}

fn raw_string_ahead(l: &Lexer, hashes: *mut usize) bool {
    let mut i = l.current;
    while i < l.bytes.len() && l.bytes.byte_at(i) == b'#' {
        i = i + 1;
    }
    if i >= l.bytes.len() || l.bytes.byte_at(i) != b'"' {
        return false;
    }
    unsafe *hashes = i - l.current;
    return true;
}

fn raw_string(l: &mut Lexer, hashes: usize) {
    if hashes > 255 {
        let start = l.start;
        lexer_error_at(l, start, hashes + 1, "raw string delimiter contains more than 255 '#' characters");
    }
    let mut i = l.current + hashes + 1;
    while i < l.bytes.len() {
        let b = l.bytes.byte_at(i);
        if b == b'"' {
            let mut close = i + 1;
            let mut matched: usize = 0;
            while matched < hashes && close < l.bytes.len() && l.bytes.byte_at(close) == b'#' {
                close = close + 1;
                matched = matched + 1;
            }
            if matched == hashes {
                l.current = close;
                add_token(l, TokenType::RawStringLiteral);
                return;
            }
            i = i + 1;
        } else if b == b'\0' {
            lexer_error_at(l, i, 1, "NUL byte is not allowed in raw string literals");
            i = i + 1;
        } else if b >= 0x80u8 {
            validate_utf8_at(l, &mut i);
        } else {
            i = i + 1;
        }
    }
    l.current = i;
    lexer_error(l, "unterminated raw string literal");
}

fn digits(l: &mut Lexer, component_start: usize, error_at: *mut usize, pred: fn(u8) bool) {
    let mut i = l.current;
    while i < l.bytes.len() {
        let b = l.bytes.byte_at(i);
        if pred(b) {
            i = i + 1;
        } else if b == b'_' {
            let prev = i > component_start && pred(l.bytes.byte_at(i - 1));
            let next = i + 1 < l.bytes.len() && pred(l.bytes.byte_at(i + 1));
            if (!prev || !next) && unsafe *error_at == USIZE_MAX {
                unsafe *error_at = i;
            }
            i = i + 1;
        } else {
            break;
        }
    }
    l.current = i;
}

fn num_suffix_kind(p: *const u8, n: usize) i32 {
    if n == 3 && (memeq(p, "f32") || memeq(p, "f64")) {
        return 1;
    }
    if n == 2 && (memeq(p, "i8") || memeq(p, "u8")) || n == 3 && (memeq(p, "i16") || memeq(p, "i32") || memeq(p, "i64") || memeq(
        p,
        "u16",
    ) || memeq(p, "u32") || memeq(p, "u64")) || n == 5 && (memeq(p, "isize") || memeq(p, "usize")) {
        return 0;
    }
    return -1;
}

fn number(l: &mut Lexer) {
    let mut error_at = USIZE_MAX;
    let mut error: str = "";
    let mut is_float = false;
    if l.bytes.byte_at(l.start) == b'0' {
        let mut radix: u32 = 10;
        let mut digit: fn(u8) bool = is_dec;
        let prefix = peek_byte(l);
        if prefix == b'x' || prefix == b'X' {
            radix = 16;
            digit = is_hex;
        } else if prefix == b'o' || prefix == b'O' {
            radix = 8;
            digit = is_oct;
        } else if prefix == b'b' || prefix == b'B' {
            radix = 2;
            digit = is_bin;
        }
        if radix != 10 {
            l.current = l.current + 1;
            let component_start = l.current;
            let mut saw_digit = false;
            let mut i = l.current;
            while i < l.bytes.len() && is_id_part_byte(l.bytes.byte_at(i)) {
                let b = l.bytes.byte_at(i);
                if digit(b) {
                    saw_digit = true;
                } else if b == b'_' {
                    let prev = i > component_start && digit(l.bytes.byte_at(i - 1));
                    let next = i + 1 < l.bytes.len() && digit(l.bytes.byte_at(i + 1));
                    if (!prev || !next) && error_at == USIZE_MAX {
                        error_at = i;
                        error = "invalid numeric separator";
                    }
                } else {
                    if radix == 16 && saw_digit && (b == b'p' || b == b'P') {
                        break;
                    }
                    let mut j = i;
                    while j < l.bytes.len() && is_id_part_byte(l.bytes.byte_at(j)) {
                        j = j + 1;
                    }
                    if saw_digit && num_suffix_kind(unsafe (l.bytes.ptr() + i), j - i) == 0 {
                        i = j;
                        break;
                    }
                    if error_at == USIZE_MAX {
                        error_at = i;
                        if radix == 2 {
                            error = "invalid digit in binary literal";
                        } else if radix == 8 {
                            error = "invalid digit in octal literal";
                        } else {
                            error = "invalid digit in hexadecimal literal";
                        }
                    }
                }
                i = i + 1;
            }
            l.current = i;
            if !saw_digit && error_at == USIZE_MAX {
                error_at = component_start;
                error = "radix prefix must be followed by at least one digit";
            }
            let mut hex_float = false;
            if radix == 16 && error_at == USIZE_MAX && peek_byte(l) == b'.' && is_hex(peek_next(l)) {
                hex_float = true;
                l.current = l.current + 1;
                while is_hex(peek_byte(l)) {
                    l.current = l.current + 1;
                }
            }
            if radix == 16 && error_at == USIZE_MAX && (peek_byte(l) == b'p' || peek_byte(l) == b'P') {
                hex_float = true;
                l.current = l.current + 1;
                if peek_byte(l) == b'+' || peek_byte(l) == b'-' {
                    l.current = l.current + 1;
                }
                let exp_start = l.current;
                while is_dec(peek_byte(l)) {
                    l.current = l.current + 1;
                }
                if l.current == exp_start {
                    error_at = exp_start;
                    error = "hexadecimal float exponent requires at least one decimal digit";
                } else if is_id_part_byte(peek_byte(l)) {
                    let sfx = l.current;
                    while is_id_part_byte(peek_byte(l)) {
                        l.current = l.current + 1;
                    }
                    if num_suffix_kind(unsafe (l.bytes.ptr() + sfx), l.current - sfx) != 1 {
                        error_at = sfx;
                        error = "a hexadecimal float takes only an 'f32' or 'f64' suffix";
                    }
                }
            } else if hex_float && error_at == USIZE_MAX {
                error_at = l.current;
                error = "a hexadecimal float requires a binary exponent ('p'), e.g. 0x1.8p3";
            }
            if !hex_float && peek_byte(l) == b'.' {
                if error_at == USIZE_MAX {
                    error_at = l.current;
                    if radix == 16 {
                        error = "a hexadecimal float needs a fraction digit and a binary exponent: 0x1.8p3";
                    } else {
                        error = "octal and binary floating-point literals are not supported";
                    }
                }
                l.current = l.current + 1;
                while !is_eof(l) {
                    let b = peek_byte(l);
                    if !is_id_part_byte(b) && b != b'.' && b != b'+' && b != b'-' {
                        break;
                    }
                    l.current = l.current + 1;
                }
            }
            if error_at != USIZE_MAX {
                lexer_error_at(l, error_at, 1, error);
            } else {
                if hex_float {
                    add_token(l, TokenType::FloatLiteral);
                } else {
                    add_token(l, TokenType::IntegerLiteral);
                }
            }
            return;
        }
    }
    let integer_start = l.current;
    digits(l, integer_start - 1, &mut error_at, is_dec);
    if error_at != USIZE_MAX {
        error = "invalid numeric separator";
    }
    if peek_byte(l) == b'.' && peek_next(l) != b'.' {
        is_float = true;
        l.current = l.current + 1;
        let fraction_start = l.current;
        digits(l, fraction_start, &mut error_at, is_dec);
        if error_at != USIZE_MAX && error.len() == 0 {
            error = "invalid numeric separator";
        }
    }
    if peek_byte(l) == b'e' || peek_byte(l) == b'E' {
        is_float = true;
        l.current = l.current + 1;
        if peek_byte(l) == b'+' || peek_byte(l) == b'-' {
            l.current = l.current + 1;
        }
        let exponent_start = l.current;
        digits(l, exponent_start, &mut error_at, is_dec);
        if l.current == exponent_start && error_at == USIZE_MAX {
            error_at = exponent_start;
            error = "exponent requires at least one decimal digit";
        } else if error_at != USIZE_MAX && error.len() == 0 {
            error = "invalid numeric separator";
        }
    }
    if is_id_part_byte(peek_byte(l)) {
        let sfx_start = l.current;
        while is_id_part_byte(peek_byte(l)) {
            l.current = l.current + 1;
        }
        let k = num_suffix_kind(unsafe (l.bytes.ptr() + sfx_start), l.current - sfx_start);
        if k < 0 {
            if error_at == USIZE_MAX {
                error_at = sfx_start;
                error = "invalid suffix or trailing identifier characters after numeric literal";
            }
        } else if is_float && k == 0 {
            if error_at == USIZE_MAX {
                error_at = sfx_start;
                error = "a float literal cannot take an integer suffix";
            }
        } else if k == 1 {
            is_float = true;
        }
    }
    if error_at != USIZE_MAX {
        lexer_error_at(l, error_at, 1, error);
    } else {
        if is_float {
            add_token(l, TokenType::FloatLiteral);
        } else {
            add_token(l, TokenType::IntegerLiteral);
        }
    }
}

fn scan_token(l: &mut Lexer) {
    let c = l.bytes.byte_at(l.current);
    if c < 0x80u8 {
        l.current = l.current + 1;
    }
    switch c {
        b' ' | b'\t' | b'\x0b' | b'\x0c' | b'\n' | b'\r' => {
            whitespace(l);
            return;
        },
        '{' => {
            add_token(l, TokenType::LeftBrace);
            return;
        },
        '}' => {
            add_token(l, TokenType::RightBrace);
            return;
        },
        '(' => {
            add_token(l, TokenType::LeftParen);
            return;
        },
        ')' => {
            add_token(l, TokenType::RightParen);
            return;
        },
        '[' => {
            add_token(l, TokenType::LeftBracket);
            return;
        },
        ']' => {
            add_token(l, TokenType::RightBracket);
            return;
        },
        ',' => {
            add_token(l, TokenType::Comma);
            return;
        },
        ';' => {
            add_token(l, TokenType::Semicolon);
            return;
        },
        ':' => {
            if match_byte(l, b':') {
                add_token(l, TokenType::PathSeparator);
            } else {
                add_token(l, TokenType::Colon);
            }
            return;
        },
        '~' => {
            add_token(l, TokenType::Tilde);
            return;
        },
        '%' => {
            add_match(l, b'=', TokenType::PercentEqual, TokenType::Percent);
            return;
        },
        '^' => {
            add_match(l, b'=', TokenType::CaretEqual, TokenType::Caret);
            return;
        },
        '+' => {
            add_match(l, b'=', TokenType::PlusEqual, TokenType::Plus);
            return;
        },
        '-' => {
            if match_byte(l, b'>') {
                add_token(l, TokenType::Arrow);
                return;
            }
            add_match(l, b'=', TokenType::MinusEqual, TokenType::Minus);
            return;
        },
        '*' => {
            add_match(l, b'=', TokenType::StarEqual, TokenType::Star);
            return;
        },
        '=' => {
            if match_byte(l, b'=') {
                add_token(l, TokenType::EqualEqual);
                return;
            }
            add_match(l, b'>', TokenType::FatArrow, TokenType::Equal);
            return;
        },
        '!' => {
            add_match(l, b'=', TokenType::BangEqual, TokenType::Bang);
            return;
        },
        '<' => {
            if match_byte(l, b'<') {
                add_match(l, b'=', TokenType::LeftShiftEqual, TokenType::LeftShift);
                return;
            }
            add_match(l, b'=', TokenType::LessThanEqual, TokenType::LessThan);
            return;
        },
        '>' => {
            add_token(l, TokenType::GreaterThan);
            return;
        },
        '&' => {
            if match_byte(l, b'&') {
                add_token(l, TokenType::AmpersandAmpersand);
                return;
            }
            add_match(l, b'=', TokenType::AmpersandEqual, TokenType::Ampersand);
            return;
        },
        '|' => {
            if match_byte(l, b'|') {
                add_token(l, TokenType::PipePipe);
                return;
            }
            add_match(l, b'=', TokenType::PipeEqual, TokenType::Pipe);
            return;
        },
        '?' => {
            add_token(l, TokenType::Question);
            return;
        },
        '/' => {
            if match_byte(l, b'/') {
                line_comment(l);
                if l.keep_trivia {
                    // `///...` is a doc comment; `//...` a plain one. The 3rd byte decides.
                    let doc = l.current - l.start > 2 && l.bytes.byte_at(l.start + 2) == b'/';
                    if doc {
                        add_token(l, TokenType::DocLineComment);
                    } else {
                        add_token(l, TokenType::LineComment);
                    }
                }
            } else if match_byte(l, b'*') {
                block_comment(l);
                if l.keep_trivia {
                    let doc = l.current - l.start > 4 && l.bytes.byte_at(l.start + 2) == b'*';
                    if doc {
                        add_token(l, TokenType::DocBlockComment);
                    } else {
                        add_token(l, TokenType::BlockComment);
                    }
                }
            } else {
                add_match(l, b'=', TokenType::SlashEqual, TokenType::Slash);
            }
            return;
        },
        '.' => {
            if match_byte(l, b'.') {
                if match_byte(l, b'.') {
                    add_token(l, TokenType::Ellipsis);
                } else if match_byte(l, b'=') {
                    add_token(l, TokenType::RangeInclusive);
                } else {
                    add_token(l, TokenType::Range);
                }
            } else {
                add_token(l, TokenType::Dot);
            }
            return;
        },
        '"' => {
            string_lit(l, TokenType::StringLiteral);
            return;
        },
        '\'' => {
            if label_ahead(l) {
                while is_id_part_byte(peek_byte(l)) {
                    l.current = l.current + 1;
                }
                add_token(l, TokenType::Label);
                return;
            }
            character(l, false);
            return;
        },
        '0'..='9' => {
            number(l);
            return;
        },
        'r' => {
            let mut hashes: usize = 0;
            if raw_string_ahead(l, &mut hashes) {
                raw_string(l, hashes);
                return;
            }
            identifier(l);
            return;
        },
        'b' => {
            if peek_byte(l) == b'\'' {
                l.current = l.current + 1;
                character(l, true);
            } else if peek_byte(l) == b'"' {
                l.current = l.current + 1;
                string_lit(l, TokenType::ByteStringLiteral);
            } else {
                identifier(l);
            }
            return;
        },
        '#' => {
            let start = l.start;
            lexer_error_at(l, start, 1, "'#' is not valid in Super-C source; Super-C has no preprocessor");
            return;
        },
        '@' => {
            add_token(l, TokenType::At);
            return;
        },
        '$' => {
            let start = l.start;
            lexer_error_at(l, start, 1, "'$' is reserved");
            return;
        },
        '`' => {
            let start = l.start;
            lexer_error_at(l, start, 1, "'`' is reserved");
            return;
        },
        b'\0' => {
            let start = l.start;
            lexer_error_at(l, start, 1, "NUL byte is not allowed in source");
            return;
        },
        'a'..='z' | 'A'..='Z' | '_' => {
            identifier(l);
            return;
        },
        _ => {
            if c >= 0x80u8 {
                let mut size: usize = 0;
                let cp = decode_at_b(l, c, l.current, &mut size);
                if size == 0 {
                    let start = l.start;
                    lexer_error_at(l, start, 1, "source is not valid UTF-8");
                    l.current = l.current + 1;
                } else {
                    l.current = l.current + size;
                    let start = l.start;
                    if cp == 0xFEFF {
                        lexer_error_at(l, start, size, "UTF-8 BOM is allowed only at the start of a file");
                    } else {
                        lexer_error_at(l, start, size, "identifiers may contain only ASCII letters, digits, and '_'");
                    }
                }
            } else {
                let start = l.start as u32;
                l.errors.emit(start, 1, format("unexpected character '{}'", c as char));
            }
        },
    };
}

extend Lexer {
    pub fn scan_tokens(self: &mut Self) {
        self.tokens.reserve(self.bytes.len() / 5);
        if self.current == 0 && self.bytes.len() >= 3 && self.bytes.byte_at(0) == 0xEFu8 && self.bytes.byte_at(1) == 0xBBu8 && self.bytes.byte_at(
            2,
        ) == 0xBFu8 {
            self.current = 3;
        }
        while self.current < self.bytes.len() {
            self.start = self.current;
            scan_token(self);
        }
        self.tokens.push(Token::new(TokenType::Eof, self.bytes.len() as u32, 0));
        self.errors.finalize(self.bytes, self.file);
    }

    pub fn take_tokens(self: &mut Self) Vector<Token> {
        let out = self.tokens;
        self.tokens = Vector::<Token>::new();
        return out;
    }

    pub fn has_errors(self: &Self) bool {
        return self.errors.has_errors();
    }
    pub fn log_errors(self: &Self) {
        self.errors.log();
    }
}
