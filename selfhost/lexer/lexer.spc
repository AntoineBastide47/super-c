import string as cstring;
import lexer::token as *;
import lexer::token_type as *;
import utils::errors as diag;

pub const EOF_CH: u8 = 0;
pub const UINT32_MAX: u32 = 0xFFFFFFFFu32;
pub const USIZE_MAX: usize = 0xFFFFFFFFFFFFFFFFu64 as usize;

pub struct Lexer {
    pub bytes: *const u8,
    pub len: usize,
    pub start: usize,
    pub current: usize,
    pub file: *const char,
    pub tokens: Vector<Token>,
    pub errors: diag::Errors,
}

extend Lexer {
    pub fn new(source: *const char, len: usize) Lexer {
        return Lexer {
            bytes: source as *const u8,
            len: len,
            start: 0,
            current: 0,
            file: null,
            tokens: Vector::<Token>::new(),
            errors: diag::Errors::new(),
        };
    }

    pub fn set_file(self: &mut Self, file: *const char) void { self.file = file; }
}

extend Lexer as Free {
    pub fn free(self: &mut Self) void {
        self.tokens.free();
        self.errors.free();
    }
}

fn is_eof(l: &Lexer) bool { return l.current >= l.len; }

fn is_id_start(b: u8) bool {
    return b == '_' || (b >= 'a' as u8 && b <= 'z' as u8) || (b >= 'A' as u8 && b <= 'Z' as u8);
}

fn is_id_part_byte(b: u8) bool {
    return is_id_start(b) || (b >= '0' as u8 && b <= '9' as u8);
}

fn is_dec(b: u8) bool { return b >= '0' as u8 && b <= '9' as u8; }
fn is_hex(b: u8) bool {
    return is_dec(b) || (b >= 'A' as u8 && b <= 'F' as u8) || (b >= 'a' as u8 && b <= 'f' as u8);
}
fn is_oct(b: u8) bool { return b >= '0' as u8 && b <= '7' as u8; }
fn is_bin(b: u8) bool { return b == '0' as u8 || b == '1' as u8; }

fn hex_value(b: u8) i32 {
    if b <= '9' as u8 { return (b - ('0' as u8)) as i32; }
    if b <= 'F' as u8 { return (b - ('A' as u8) + 10) as i32; }
    return (b - ('a' as u8) + 10) as i32;
}

fn add_token(l: &mut Lexer, token_type: TokenType) void {
    l.tokens.push(Token::new(token_type, l.start as u32, (l.current - l.start) as u32));
}

fn add_match(l: &mut Lexer, expected: u8, matched: TokenType, unmatched: TokenType) void {
    let kind = if match_byte(&mut *l, expected) { matched; } else { unmatched; };
    add_token(&mut *l, kind);
}

fn peek_byte(l: &Lexer) u8 {
    if is_eof(&*l) { return EOF_CH; }
    return unsafe l.bytes[l.current];
}

fn peek_byte_n(l: &Lexer, n: usize) u8 {
    if l.current + n >= l.len { return EOF_CH; }
    return unsafe l.bytes[l.current + n];
}

fn match_byte(l: &mut Lexer, expected: u8) bool {
    if peek_byte(&*l) != expected { return false; }
    l.current = l.current + 1;
    return true;
}

fn lexer_error(l: &mut Lexer, message: *const char) void {
    l.errors.emitf(l.start as u32, (l.current - l.start) as u32, "%s".ptr as *const char, message);
}

fn lexer_error_at(l: &mut Lexer, at: usize, len: usize, message: *const char) void {
    l.errors.emitf(at as u32, len as u32, "%s".ptr as *const char, message);
}

fn lexer_errorf(l: &mut Lexer, at: u32, len: u32, fmt: *const char, ...) void {
    let mut args: va_list;
    va_start(args, fmt);
    l.errors.vemitf(at, len, fmt, args);
    va_end(args);
}

fn decode_at_b(l: &Lexer, b: u8, current: usize, size: *mut usize) u32 {
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
    if b >= 0xC2u8 && b <= 0xDFu8 { cp = (b & 0x1Fu8) as u32; }
    else if b >= 0xE0u8 && b <= 0xEFu8 { cp = (b & 0x0Fu8) as u32; }
    else if b >= 0xF0u8 && b <= 0xF4u8 { cp = (b & 0x07u8) as u32; }
    else {
        unsafe *size = 0;
        return 0;
    }
    if current + width > l.len {
        unsafe *size = 0;
        return 0;
    }
    for i in 1..width {
        let continuation = unsafe l.bytes[current + i];
        if (continuation & 0xC0u8) != 0x80u8 {
            unsafe *size = 0;
            return 0;
        }
        cp = (cp << 6) | ((continuation & 0x3Fu8) as u32);
    }
    if cp < minimum || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) {
        unsafe *size = 0;
        return 0;
    }
    unsafe *size = width;
    return cp;
}

fn memeq(p: *const u8, text: str) bool {
    return unsafe cstring::memcmp(p, text.ptr, text.len) == 0;
}

fn keywords(lexeme: *const u8, len: usize) TokenType {
    let first = unsafe lexeme[0];
    switch len {
        2 => {
            if first == 'a' as u8 && memeq(lexeme, "as") { return TokenType::As; }
            if first == 'd' as u8 && memeq(lexeme, "do") { return TokenType::Do; }
            if first == 'f' as u8 && memeq(lexeme, "fn") { return TokenType::Fn; }
            if first == 'i' as u8 && memeq(lexeme, "if") { return TokenType::If; }
            if first == 'i' as u8 && memeq(lexeme, "in") { return TokenType::In; }
        },
        3 => {
            if first == 'd' as u8 && memeq(lexeme, "dyn") { return TokenType::Dyn; }
            if first == 'f' as u8 && memeq(lexeme, "for") { return TokenType::For; }
            if first == 'l' as u8 && memeq(lexeme, "let") { return TokenType::Let; }
            if first == 'm' as u8 && memeq(lexeme, "mut") { return TokenType::Mut; }
            if first == 'n' as u8 && memeq(lexeme, "new") { return TokenType::New; }
            if first == 'p' as u8 && memeq(lexeme, "pub") { return TokenType::Pub; }
        },
        4 => {
            if first == 'c' as u8 && memeq(lexeme, "case") { return TokenType::Case; }
            if first == 'e' as u8 && memeq(lexeme, "else") { return TokenType::Else; }
            if first == 'e' as u8 && memeq(lexeme, "enum") { return TokenType::Enum; }
            if first == 'l' as u8 && memeq(lexeme, "loop") { return TokenType::Loop; }
            if first == 'm' as u8 && memeq(lexeme, "move") { return TokenType::Move; }
            if first == 'n' as u8 && memeq(lexeme, "null") { return TokenType::Null; }
            if first == 's' as u8 && memeq(lexeme, "self") { return TokenType::SelfLower; }
            if first == 'S' as u8 && memeq(lexeme, "Self") { return TokenType::SelfUpper; }
            if first == 't' as u8 && memeq(lexeme, "true") { return TokenType::True; }
            if first == 't' as u8 && memeq(lexeme, "type") { return TokenType::Type; }
        },
        5 => {
            if first == 'b' as u8 && memeq(lexeme, "break") { return TokenType::Break; }
            if first == 'c' as u8 && memeq(lexeme, "const") { return TokenType::Const; }
            if first == 'd' as u8 && memeq(lexeme, "defer") { return TokenType::Defer; }
            if first == 'f' as u8 && memeq(lexeme, "false") { return TokenType::False; }
            if first == 'u' as u8 && memeq(lexeme, "union") { return TokenType::Union; }
            if first == 'w' as u8 && memeq(lexeme, "where") { return TokenType::Where; }
            if first == 'w' as u8 && memeq(lexeme, "while") { return TokenType::While; }
        },
        6 => {
            if first == 'e' as u8 && memeq(lexeme, "extend") { return TokenType::Extend; }
            if first == 'e' as u8 && memeq(lexeme, "extern") { return TokenType::Extern; }
            if first == 'i' as u8 && memeq(lexeme, "import") { return TokenType::Import; }
            if first == 'r' as u8 && memeq(lexeme, "return") { return TokenType::Return; }
            if first == 's' as u8 && memeq(lexeme, "struct") { return TokenType::Struct; }
            if first == 's' as u8 && memeq(lexeme, "switch") { return TokenType::Switch; }
            if first == 's' as u8 && memeq(lexeme, "sizeof") { return TokenType::Sizeof; }
            if first == 'u' as u8 && memeq(lexeme, "unsafe") { return TokenType::Unsafe; }
        },
        7 => { if memeq(lexeme, "alignof") { return TokenType::Alignof; } },
        8 => { if memeq(lexeme, "continue") { return TokenType::Continue; } },
        9 => { if memeq(lexeme, "interface") { return TokenType::Interface; } },
        _ => {},
    };
    return TokenType::Identifier;
}

fn identifier(l: &mut Lexer) void {
    let mut i = l.current;
    while i < l.len && is_id_part_byte(unsafe l.bytes[i]) { i = i + 1; }
    l.current = i;
    let identifier_len = i - l.start;
    let mut kind = TokenType::Identifier;
    if identifier_len <= 9 { kind = keywords(unsafe (l.bytes + l.start), identifier_len); }
    add_token(&mut *l, kind);
}

fn validate_utf8_at(l: &mut Lexer, i: *mut usize) bool {
    let mut size: usize = 0;
    decode_at_b(&*l, unsafe l.bytes[unsafe *i], unsafe *i, &mut size);
    if size == 0 {
        lexer_error_at(&mut *l, unsafe *i, 1, "source is not valid UTF-8".ptr as *const char);
        unsafe *i = unsafe *i + 1;
        return false;
    }
    unsafe *i = unsafe *i + size;
    return true;
}

fn whitespace(l: &mut Lexer) void {
    let mut i = l.current;
    while i < l.len {
        let b = unsafe l.bytes[i];
        if b == 32 || b == 9 || b == 10 || b == 11 || b == 12 {
            i = i + 1;
        } else if b == 13 {
            i = i + 1;
            if i < l.len && unsafe l.bytes[i] == 10 { i = i + 1; }
        } else {
            l.current = i;
            return;
        }
    }
    l.current = i;
}

fn line_comment(l: &mut Lexer) void {
    let mut i = l.current;
    while i < l.len {
        let b = unsafe l.bytes[i];
        if b == 10 || b == 13 { break; }
        if b == 0 {
            lexer_error_at(&mut *l, i, 1, "NUL byte is not allowed in comments".ptr as *const char);
            i = i + 1;
        } else if b >= 0x80u8 { validate_utf8_at(&mut *l, &mut i); }
        else { i = i + 1; }
    }
    l.current = i;
}

fn block_comment(l: &mut Lexer) void {
    let mut i = l.current;
    let mut depth: usize = 1;
    while i < l.len {
        let b = unsafe l.bytes[i];
        if b == '/' as u8 && i + 1 < l.len && unsafe l.bytes[i + 1] == '*' as u8 {
            depth = depth + 1;
            i = i + 2;
        } else if b == '*' as u8 && i + 1 < l.len && unsafe l.bytes[i + 1] == '/' as u8 {
            i = i + 2;
            depth = depth - 1;
            if depth == 0 {
                l.current = i;
                return;
            }
        } else if b == 0 {
            lexer_error_at(&mut *l, i, 1, "NUL byte is not allowed in comments".ptr as *const char);
            i = i + 1;
        } else if b >= 0x80u8 { validate_utf8_at(&mut *l, &mut i); }
        else { i = i + 1; }
    }
    l.current = i;
    let start = l.start;
    lexer_error_at(&mut *l, start, 2, "unterminated block comment".ptr as *const char);
}

fn escape(l: &mut Lexer, byte_character: bool) u32 {
    if is_eof(&*l) {
        let current = l.current;
        lexer_error_at(&mut *l, current, 0, "unterminated escape sequence".ptr as *const char);
        return UINT32_MAX;
    }
    let at = l.current - 1;
    let escaped = unsafe l.bytes[l.current];
    l.current = l.current + 1;
    if escaped == 'n' as u8 { return 10; }
    if escaped == 'r' as u8 { return 13; }
    if escaped == 't' as u8 { return 9; }
    if escaped == '\\' as u8 { return '\\' as u32; }
    if escaped == '\'' as u8 { return '\'' as u32; }
    if escaped == '"' as u8 && !byte_character { return '"' as u32; }
    if escaped == '0' as u8 { return 0; }
    if escaped == 'x' as u8 {
        if l.current + 2 <= l.len && is_hex(unsafe l.bytes[l.current]) && is_hex(unsafe l.bytes[l.current + 1]) {
            let value = ((hex_value(unsafe l.bytes[l.current]) << 4) | hex_value(unsafe l.bytes[l.current + 1])) as u32;
            l.current = l.current + 2;
            return value;
        }
        let err_len = l.current - at;
        lexer_error_at(&mut *l, at, err_len, "\\x escape requires exactly two hexadecimal digits".ptr as *const char);
        while l.current < l.len && l.current < at + 4 && is_hex(unsafe l.bytes[l.current]) { l.current = l.current + 1; }
        return UINT32_MAX;
    }
    if escaped == 'u' as u8 {
        if byte_character {
            if match_byte(&mut *l, '{' as u8) {
                while is_hex(peek_byte(&*l)) { l.current = l.current + 1; }
                match_byte(&mut *l, '}' as u8);
            }
            let err_len = l.current - at;
            lexer_error_at(&mut *l, at, err_len, "Unicode escapes are not allowed in byte character literals".ptr as *const char);
            return UINT32_MAX;
        }
        if !match_byte(&mut *l, '{' as u8) {
            let err_len = l.current - at;
            lexer_error_at(&mut *l, at, err_len, "Unicode escape must use \\u{...} syntax".ptr as *const char);
            return UINT32_MAX;
        }
        let mut value: u32 = 0;
        let mut digits: usize = 0;
        while is_hex(peek_byte(&*l)) {
            if digits < 6 { value = (value << 4) | (hex_value(peek_byte(&*l)) as u32); }
            digits = digits + 1;
            l.current = l.current + 1;
        }
        if digits == 0 || digits > 6 || !match_byte(&mut *l, '}' as u8) {
            let err_len = l.current - at;
            lexer_error_at(&mut *l, at, err_len, "Unicode escape requires 1 to 6 hexadecimal digits".ptr as *const char);
            return UINT32_MAX;
        }
        if value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF) {
            let err_len = l.current - at;
            lexer_error_at(&mut *l, at, err_len, "Unicode escape is not a valid Unicode scalar value".ptr as *const char);
            return UINT32_MAX;
        }
        return value;
    }
    let err_len = l.current - at;
    lexer_error_at(&mut *l, at, err_len, "unknown escape sequence".ptr as *const char);
    return UINT32_MAX;
}

fn string_lit(l: &mut Lexer, kind: TokenType) void {
    let mut i = l.current;
    while i < l.len {
        let b = unsafe l.bytes[i];
        i = i + 1;
        if b == '"' as u8 {
            l.current = i;
            add_token(&mut *l, kind);
            return;
        }
        if b == '\\' as u8 {
            l.current = i;
            escape(&mut *l, false);
            i = l.current;
        } else if b == 10 || b == 13 {
            l.current = i - 1;
            lexer_error(&mut *l, "unterminated string literal".ptr as *const char);
            while l.current < l.len {
                let recovery = unsafe l.bytes[l.current];
                l.current = l.current + 1;
                if recovery == '"' as u8 { break; }
            }
            return;
        } else if b == 0 {
            lexer_error_at(&mut *l, i - 1, 1, "NUL byte is not allowed in string literals".ptr as *const char);
        } else if b >= 0x80u8 {
            i = i - 1;
            validate_utf8_at(&mut *l, &mut i);
        }
    }
    l.current = i;
    lexer_error(&mut *l, "unterminated string literal".ptr as *const char);
}

fn label_ahead(l: &Lexer) bool {
    let mut i = l.current;
    let mut b: u8 = 0;
    if i < l.len { b = unsafe l.bytes[i]; }
    if !is_id_start(b) { return false; }
    while i < l.len && is_id_part_byte(unsafe l.bytes[i]) { i = i + 1; }
    return i >= l.len || unsafe l.bytes[i] != '\'' as u8;
}

fn character(l: &mut Lexer, byte_character: bool) void {
    let mut count: usize = 0;
    let mut malformed = false;
    let mut invalid_byte = false;
    while !is_eof(&*l) {
        let b = unsafe l.bytes[l.current];
        l.current = l.current + 1;
        if b == '\'' as u8 {
            if !malformed && count != 1 {
                if byte_character { lexer_error(&mut *l, "byte character literal must contain exactly one byte".ptr as *const char); }
                else { lexer_error(&mut *l, "character literal must contain exactly one Unicode scalar value".ptr as *const char); }
            } else if invalid_byte {
                lexer_error(&mut *l, "byte character literal may contain only ASCII or a \\xNN escape".ptr as *const char);
            }
            if byte_character { add_token(&mut *l, TokenType::ByteCharacterLiteral); }
            else { add_token(&mut *l, TokenType::CharacterLiteral); }
            return;
        }
        if b == 10 || b == 13 {
            l.current = l.current - 1;
            lexer_error(&mut *l, "unterminated character literal".ptr as *const char);
            return;
        }
        if b == 0 {
            let at = l.current - 1;
            lexer_error_at(&mut *l, at, 1, "NUL byte is not allowed in character literals".ptr as *const char);
            count = count + 1;
        } else if b == '\\' as u8 {
            if escape(&mut *l, byte_character) == UINT32_MAX { malformed = true; }
            else { count = count + 1; }
        } else if b < 0x80u8 {
            count = count + 1;
        } else {
            let mut size: usize = 0;
            decode_at_b(&*l, b, l.current - 1, &mut size);
            if size == 0 {
                let at = l.current - 1;
                lexer_error_at(&mut *l, at, 1, "source is not valid UTF-8".ptr as *const char);
                malformed = true;
            } else {
                l.current = l.current + size - 1;
                count = count + 1;
                invalid_byte = byte_character;
            }
        }
    }
    lexer_error(&mut *l, "unterminated character literal".ptr as *const char);
}

fn raw_string_ahead(l: &Lexer, hashes: *mut usize) bool {
    let mut i = l.current;
    while i < l.len && unsafe l.bytes[i] == '#' as u8 { i = i + 1; }
    if i >= l.len || unsafe l.bytes[i] != '"' as u8 { return false; }
    unsafe *hashes = i - l.current;
    return true;
}

fn raw_string(l: &mut Lexer, hashes: usize) void {
    if hashes > 255 {
        let start = l.start;
        lexer_error_at(&mut *l, start, hashes + 1, "raw string delimiter contains more than 255 '#' characters".ptr as *const char);
    }
    let mut i = l.current + hashes + 1;
    while i < l.len {
        let b = unsafe l.bytes[i];
        if b == '"' as u8 {
            let mut close = i + 1;
            let mut matched: usize = 0;
            while matched < hashes && close < l.len && unsafe l.bytes[close] == '#' as u8 {
                close = close + 1;
                matched = matched + 1;
            }
            if matched == hashes {
                l.current = close;
                add_token(&mut *l, TokenType::RawStringLiteral);
                return;
            }
            i = i + 1;
        } else if b == 0 {
            lexer_error_at(&mut *l, i, 1, "NUL byte is not allowed in raw string literals".ptr as *const char);
            i = i + 1;
        } else if b >= 0x80u8 { validate_utf8_at(&mut *l, &mut i); }
        else { i = i + 1; }
    }
    l.current = i;
    lexer_error(&mut *l, "unterminated raw string literal".ptr as *const char);
}

fn digits(l: &mut Lexer, component_start: usize, error_at: *mut usize, pred: fn(u8) bool) void {
    let mut i = l.current;
    while i < l.len {
        let b = unsafe l.bytes[i];
        if pred(b) { i = i + 1; }
        else if b == '_' as u8 {
            let prev = i > component_start && pred(unsafe l.bytes[i - 1]);
            let next = i + 1 < l.len && pred(unsafe l.bytes[i + 1]);
            if (!prev || !next) && unsafe *error_at == USIZE_MAX { unsafe *error_at = i; }
            i = i + 1;
        } else { break; }
    }
    l.current = i;
}

fn num_suffix_kind(p: *const u8, n: usize) i32 {
    if n == 3 && (memeq(p, "f32") || memeq(p, "f64")) { return 1; }
    if (n == 2 && (memeq(p, "i8") || memeq(p, "u8"))) ||
       (n == 3 && (memeq(p, "i16") || memeq(p, "i32") || memeq(p, "i64") || memeq(p, "u16") || memeq(p, "u32") || memeq(p, "u64"))) ||
       (n == 5 && (memeq(p, "isize") || memeq(p, "usize"))) {
        return 0;
    }
    return -1;
}

fn number(l: &mut Lexer) void {
    let mut error_at = USIZE_MAX;
    let mut error = null as *const char;
    let mut is_float = false;
    if unsafe l.bytes[l.start] == '0' as u8 {
        let mut radix: u32 = 10;
        let mut digit: fn(u8) bool = is_dec;
        let prefix = peek_byte(&*l);
        if prefix == 'x' as u8 || prefix == 'X' as u8 {
            radix = 16;
            digit = is_hex;
        } else if prefix == 'o' as u8 || prefix == 'O' as u8 {
            radix = 8;
            digit = is_oct;
        } else if prefix == 'b' as u8 || prefix == 'B' as u8 {
            radix = 2;
            digit = is_bin;
        }
        if radix != 10 {
            l.current = l.current + 1;
            let component_start = l.current;
            let mut saw_digit = false;
            let mut i = l.current;
            while i < l.len && is_id_part_byte(unsafe l.bytes[i]) {
                let b = unsafe l.bytes[i];
                if digit(b) { saw_digit = true; }
                else if b == '_' as u8 {
                    let prev = i > component_start && digit(unsafe l.bytes[i - 1]);
                    let next = i + 1 < l.len && digit(unsafe l.bytes[i + 1]);
                    if (!prev || !next) && error_at == USIZE_MAX {
                        error_at = i;
                        error = "invalid numeric separator".ptr as *const char;
                    }
                } else {
                    if radix == 16 && saw_digit && (b == 'p' as u8 || b == 'P' as u8) { break; }
                    let mut j = i;
                    while j < l.len && is_id_part_byte(unsafe l.bytes[j]) { j = j + 1; }
                    if saw_digit && num_suffix_kind(unsafe (l.bytes + i), j - i) == 0 {
                        i = j;
                        break;
                    }
                    if error_at == USIZE_MAX {
                        error_at = i;
                        if radix == 2 { error = "invalid digit in binary literal".ptr as *const char; }
                        else if radix == 8 { error = "invalid digit in octal literal".ptr as *const char; }
                        else { error = "invalid digit in hexadecimal literal".ptr as *const char; }
                    }
                }
                i = i + 1;
            }
            l.current = i;
            if !saw_digit && error_at == USIZE_MAX {
                error_at = component_start;
                error = "radix prefix must be followed by at least one digit".ptr as *const char;
            }
            let mut hex_float = false;
            if radix == 16 && error_at == USIZE_MAX && peek_byte(&*l) == '.' as u8 && is_hex(peek_byte_n(&*l, 1)) {
                hex_float = true;
                l.current = l.current + 1;
                while is_hex(peek_byte(&*l)) { l.current = l.current + 1; }
            }
            if radix == 16 && error_at == USIZE_MAX && (peek_byte(&*l) == 'p' as u8 || peek_byte(&*l) == 'P' as u8) {
                hex_float = true;
                l.current = l.current + 1;
                if peek_byte(&*l) == '+' as u8 || peek_byte(&*l) == '-' as u8 { l.current = l.current + 1; }
                let exp_start = l.current;
                while is_dec(peek_byte(&*l)) { l.current = l.current + 1; }
                if l.current == exp_start {
                    error_at = exp_start;
                    error = "hexadecimal float exponent requires at least one decimal digit".ptr as *const char;
                } else if is_id_part_byte(peek_byte(&*l)) {
                    let sfx = l.current;
                    while is_id_part_byte(peek_byte(&*l)) { l.current = l.current + 1; }
                    if num_suffix_kind(unsafe (l.bytes + sfx), l.current - sfx) != 1 {
                        error_at = sfx;
                        error = "a hexadecimal float takes only an 'f32' or 'f64' suffix".ptr as *const char;
                    }
                }
            } else if hex_float && error_at == USIZE_MAX {
                error_at = l.current;
                error = "a hexadecimal float requires a binary exponent ('p'), e.g. 0x1.8p3".ptr as *const char;
            }
            if !hex_float && peek_byte(&*l) == '.' as u8 {
                if error_at == USIZE_MAX {
                    error_at = l.current;
                    if radix == 16 { error = "a hexadecimal float needs a fraction digit and a binary exponent: 0x1.8p3".ptr as *const char; }
                    else { error = "octal and binary floating-point literals are not supported".ptr as *const char; }
                }
                l.current = l.current + 1;
                while !is_eof(&*l) {
                    let b = peek_byte(&*l);
                    if !is_id_part_byte(b) && b != '.' as u8 && b != '+' as u8 && b != '-' as u8 { break; }
                    l.current = l.current + 1;
                }
            }
            if error_at != USIZE_MAX { lexer_error_at(&mut *l, error_at, 1, error); }
            else {
                if hex_float { add_token(&mut *l, TokenType::FloatLiteral); }
                else { add_token(&mut *l, TokenType::IntegerLiteral); }
            }
            return;
        }
    }
    let integer_start = l.current;
    digits(&mut *l, integer_start - 1, &mut error_at, is_dec);
    if error_at != USIZE_MAX { error = "invalid numeric separator".ptr as *const char; }
    if peek_byte(&*l) == '.' as u8 && peek_byte_n(&*l, 1) != '.' as u8 {
        is_float = true;
        l.current = l.current + 1;
        let fraction_start = l.current;
        digits(&mut *l, fraction_start, &mut error_at, is_dec);
        if error_at != USIZE_MAX && error == null { error = "invalid numeric separator".ptr as *const char; }
    }
    if peek_byte(&*l) == 'e' as u8 || peek_byte(&*l) == 'E' as u8 {
        is_float = true;
        l.current = l.current + 1;
        if peek_byte(&*l) == '+' as u8 || peek_byte(&*l) == '-' as u8 { l.current = l.current + 1; }
        let exponent_start = l.current;
        digits(&mut *l, exponent_start, &mut error_at, is_dec);
        if l.current == exponent_start && error_at == USIZE_MAX {
            error_at = exponent_start;
            error = "exponent requires at least one decimal digit".ptr as *const char;
        } else if error_at != USIZE_MAX && error == null {
            error = "invalid numeric separator".ptr as *const char;
        }
    }
    if is_id_part_byte(peek_byte(&*l)) {
        let sfx_start = l.current;
        while is_id_part_byte(peek_byte(&*l)) { l.current = l.current + 1; }
        let k = num_suffix_kind(unsafe (l.bytes + sfx_start), l.current - sfx_start);
        if k < 0 {
            if error_at == USIZE_MAX {
                error_at = sfx_start;
                error = "invalid suffix or trailing identifier characters after numeric literal".ptr as *const char;
            }
        } else if is_float && k == 0 {
            if error_at == USIZE_MAX {
                error_at = sfx_start;
                error = "a float literal cannot take an integer suffix".ptr as *const char;
            }
        } else if k == 1 { is_float = true; }
    }
    if error_at != USIZE_MAX { lexer_error_at(&mut *l, error_at, 1, error); }
    else {
        if is_float { add_token(&mut *l, TokenType::FloatLiteral); }
        else { add_token(&mut *l, TokenType::IntegerLiteral); }
    }
}

fn scan_token(l: &mut Lexer) void {
    let c = unsafe l.bytes[l.current];
    if c < 0x80u8 { l.current = l.current + 1; }
    switch c {
        32 | 9 | 11 | 12 | 10 | 13 => { whitespace(&mut *l); return; },
        '{' => { add_token(&mut *l, TokenType::LeftBrace); return; },
        '}' => { add_token(&mut *l, TokenType::RightBrace); return; },
        '(' => { add_token(&mut *l, TokenType::LeftParen); return; },
        ')' => { add_token(&mut *l, TokenType::RightParen); return; },
        '[' => { add_token(&mut *l, TokenType::LeftBracket); return; },
        ']' => { add_token(&mut *l, TokenType::RightBracket); return; },
        ',' => { add_token(&mut *l, TokenType::Comma); return; },
        ';' => { add_token(&mut *l, TokenType::Semicolon); return; },
        ':' => {
            if match_byte(&mut *l, ':' as u8) { add_token(&mut *l, TokenType::PathSeparator); } else { add_token(&mut *l, TokenType::Colon); }
            return;
        },
        '~' => { add_token(&mut *l, TokenType::Tilde); return; },
        '%' => { add_match(&mut *l, '=' as u8, TokenType::PercentEqual, TokenType::Percent); return; },
        '^' => { add_match(&mut *l, '=' as u8, TokenType::CaretEqual, TokenType::Caret); return; },
        '+' => { add_match(&mut *l, '=' as u8, TokenType::PlusEqual, TokenType::Plus); return; },
        '-' => {
            if match_byte(&mut *l, '>' as u8) { add_token(&mut *l, TokenType::Arrow); return; }
            add_match(&mut *l, '=' as u8, TokenType::MinusEqual, TokenType::Minus);
            return;
        },
        '*' => { add_match(&mut *l, '=' as u8, TokenType::StarEqual, TokenType::Star); return; },
        '=' => {
            if match_byte(&mut *l, '=' as u8) { add_token(&mut *l, TokenType::EqualEqual); return; }
            add_match(&mut *l, '>' as u8, TokenType::FatArrow, TokenType::Equal);
            return;
        },
        '!' => { add_match(&mut *l, '=' as u8, TokenType::BangEqual, TokenType::Bang); return; },
        '<' => {
            if match_byte(&mut *l, '<' as u8) {
                add_match(&mut *l, '=' as u8, TokenType::LeftShiftEqual, TokenType::LeftShift);
                return;
            }
            add_match(&mut *l, '=' as u8, TokenType::LessThanEqual, TokenType::LessThan);
            return;
        },
        '>' => {
            if match_byte(&mut *l, '>' as u8) {
                add_match(&mut *l, '=' as u8, TokenType::RightShiftEqual, TokenType::RightShift);
                return;
            }
            add_match(&mut *l, '=' as u8, TokenType::GreaterThanEqual, TokenType::GreaterThan);
            return;
        },
        '&' => {
            if match_byte(&mut *l, '&' as u8) { add_token(&mut *l, TokenType::AmpersandAmpersand); return; }
            add_match(&mut *l, '=' as u8, TokenType::AmpersandEqual, TokenType::Ampersand);
            return;
        },
        '|' => {
            if match_byte(&mut *l, '|' as u8) { add_token(&mut *l, TokenType::PipePipe); return; }
            add_match(&mut *l, '=' as u8, TokenType::PipeEqual, TokenType::Pipe);
            return;
        },
        '?' => { add_token(&mut *l, TokenType::Question); return; },
        '/' => {
            if match_byte(&mut *l, '/' as u8) { line_comment(&mut *l); }
            else if match_byte(&mut *l, '*' as u8) { block_comment(&mut *l); }
            else { add_match(&mut *l, '=' as u8, TokenType::SlashEqual, TokenType::Slash); }
            return;
        },
        '.' => {
            if match_byte(&mut *l, '.' as u8) {
                if match_byte(&mut *l, '.' as u8) { add_token(&mut *l, TokenType::Ellipsis); }
                else if match_byte(&mut *l, '=' as u8) { add_token(&mut *l, TokenType::RangeInclusive); }
                else { add_token(&mut *l, TokenType::Range); }
            } else { add_token(&mut *l, TokenType::Dot); }
            return;
        },
        '"' => { string_lit(&mut *l, TokenType::StringLiteral); return; },
        '\'' => {
            if label_ahead(&*l) {
                while is_id_part_byte(peek_byte(&*l)) { l.current = l.current + 1; }
                add_token(&mut *l, TokenType::Label);
                return;
            }
            character(&mut *l, false);
            return;
        },
        '0'..='9' => { number(&mut *l); return; },
        'r' => {
            let mut hashes: usize = 0;
            if raw_string_ahead(&*l, &mut hashes) { raw_string(&mut *l, hashes); return; }
            identifier(&mut *l);
            return;
        },
        'b' => {
            if peek_byte(&*l) == '\'' as u8 {
                l.current = l.current + 1;
                character(&mut *l, true);
            } else if peek_byte(&*l) == '"' as u8 {
                l.current = l.current + 1;
                string_lit(&mut *l, TokenType::ByteStringLiteral);
            } else { identifier(&mut *l); }
            return;
        },
        '#' => { let start = l.start; lexer_error_at(&mut *l, start, 1, "'#' is not valid in Super-C source; Super-C has no preprocessor".ptr as *const char); return; },
        '@' => { add_token(&mut *l, TokenType::At); return; },
        '$' => { let start = l.start; lexer_error_at(&mut *l, start, 1, "'$' is reserved".ptr as *const char); return; },
        '`' => { let start = l.start; lexer_error_at(&mut *l, start, 1, "'`' is reserved".ptr as *const char); return; },
        0 => { let start = l.start; lexer_error_at(&mut *l, start, 1, "NUL byte is not allowed in source".ptr as *const char); return; },
        'a'..='z' | 'A'..='Z' | '_' => { identifier(&mut *l); return; },
        _ => {
            if c >= 0x80u8 {
                let mut size: usize = 0;
                let cp = decode_at_b(&*l, c, l.current, &mut size);
                if size == 0 {
                    let start = l.start;
                    lexer_error_at(&mut *l, start, 1, "source is not valid UTF-8".ptr as *const char);
                    l.current = l.current + 1;
                } else {
                    l.current = l.current + size;
                    let start = l.start;
                    if cp == 0xFEFF { lexer_error_at(&mut *l, start, size, "UTF-8 BOM is allowed only at the start of a file".ptr as *const char); }
                    else { lexer_error_at(&mut *l, start, size, "identifiers may contain only ASCII letters, digits, and '_'".ptr as *const char); }
                }
            } else {
                let start = l.start as u32;
                lexer_errorf(&mut *l, start, 1, "unexpected character '%c'".ptr as *const char, c as i32);
            }
        }
    };
}

extend Lexer {
    pub fn scan_tokens(self: &mut Self) void {
        self.tokens.reserve(self.len / 5);
        if self.current == 0 && self.len >= 3 && unsafe self.bytes[0] == 0xEFu8 && unsafe self.bytes[1] == 0xBBu8 && unsafe self.bytes[2] == 0xBFu8 {
            self.current = 3;
        }
        while self.current < self.len {
            self.start = self.current;
            scan_token(&mut *self);
        }
        self.tokens.push(Token::new(TokenType::Eof, self.len as u32, 0));
        self.errors.finalize(self.bytes, self.len, self.file);
    }

    pub fn take_tokens(self: &mut Self) Vector<Token> {
        let out = self.tokens;
        self.tokens = Vector::<Token>::new();
        return out;
    }

    pub fn has_errors(self: &Self) bool { return self.errors.has_errors(); }
    pub fn log_errors(self: &Self) void { self.errors.log(); }
}
