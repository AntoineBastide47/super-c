// Byte-driven scanner: a NUL-padded source String in (see SOURCE_PAD), a Vector<Token> out. Tokens
// carry only (kind, start, len) spans indexing the source; no text is copied. Every error is
// recovered from, so the scan always completes; keep_trivia additionally emits comment tokens for
// the formatter path (the parser never sees trivia).
import string as cstring;
import lexer::token as *;
import lexer::token_type as *;
import utils::errors as diag;

/// The NUL byte the scan loops treat as end of input.
pub const EOF_CH: u8 = 0;
/// Sentinel for "none" in u32 positions and scalar values.
pub const UINT32_MAX: u32 = 0xFFFFFFFFu32;
/// Sentinel for "none" in usize positions.
pub const USIZE_MAX: usize = 0xFFFFFFFFFFFFFFFFu64 as usize;

/// Read-ahead sentinel padding a lexed source buffer MUST carry past its logical end (all NUL): the loader
/// pads every module source (String::pad_nul) so the lexer's scan loops drop their per-byte bounds check
/// and rely on the trailing NUL to terminate. Fixed lookahead reads at most 4 bytes past the end.
pub const SOURCE_PAD: usize = 8;

/// Per-byte character-class flags, indexed by byte value (see build_char_class). Held BY VALUE in each Lexer
/// so there is no global mutable state (the compiler lexes many sources, possibly concurrently in-process).
pub const CC_ID_START: u8 = 1;
pub const CC_ID_PART: u8 = 2;
pub const CC_DIGIT: u8 = 4;
pub const CC_HEX: u8 = 8;
pub const CC_WS: u8 = 16;
pub type CharClass = Array<u8, 256>;

const fn build_char_class() CharClass {
    let mut c = CharClass {};
    for b in 0..255u8 {
        let mut fl = 0u8;
        if b == b'_' || b >= b'a' && b <= b'z' || b >= b'A' && b <= b'Z' {
            fl = fl | CC_ID_START | CC_ID_PART;
        }
        if b >= b'0' && b <= b'9' {
            fl = fl | CC_ID_PART | CC_DIGIT | CC_HEX;
        }
        if b >= b'a' && b <= b'f' || b >= b'A' && b <= b'F' {
            fl = fl | CC_HEX;
        }
        if b == b' ' || b == b'\t' || b == b'\n' || b == b'\x0b' || b == b'\x0c' || b == b'\r' {
            fl = fl | CC_WS;
        }
        c[b as usize] = fl;
    }
    return c;
}

/// One in-flight matchertext literal whose template is paused at an interpolation hole. The
/// delimiter chain is not copied: `dpos`/`d_len` index its openers in the source. `base` is where
/// this literal's open matchers start in `mt_stack`; `hole_depth` counts matcher tokens open in
/// the current hole so the closing delimiter sequence is only recognized at hole level.
pub struct MtFrame {
    pub dpos: u32,
    pub d_len: u8,
    pub base: u32,
    pub hole_depth: u32,
}

/// Scanner state over one padded source buffer; `tokens` and `errors` accumulate until taken.
pub struct Lexer<'a> {
    pub bytes: str<'a>,
    pub start: usize,
    pub current: usize,
    pub file: str<'a>,
    pub tokens: Vector<Token>,
    pub errors: diag::Errors,
    pub class: CharClass,
    pub keep_trivia: bool, // emit comment tokens (the formatter); off for the parser path
    pub mt: Vector<MtFrame>, // matchertext literals paused at an interpolation hole, innermost last
    pub mt_stack: Vector<u8>, // open matchers of ALL paused templates (frames slice it via `base`)
}

const fn is_id_start(b: u8) bool {
    return b == '_' || b >= b'a' && b <= b'z' || b >= b'A' && b <= b'Z';
}

const fn is_id_part_byte(b: u8) bool {
    return is_id_start(b) || b >= b'0' && b <= b'9';
}

const fn is_dec(b: u8) bool {
    return b >= b'0' && b <= b'9';
}

const fn is_hex(b: u8) bool {
    return is_dec(b) || b >= b'A' && b <= b'F' || b >= b'a' && b <= b'f';
}

const fn is_oct(b: u8) bool {
    return b >= b'0' && b <= b'7';
}

const fn is_bin(b: u8) bool {
    return b == b'0' || b == b'1';
}

const fn hex_value(b: u8) i32 {
    if b <= b'9' {
        return b - b'0';
    }
    if b <= b'F' {
        return b - b'A' + 10;
    }
    return b - b'a' + 10;
}

const fn memeq(p: *const u8, text: str) bool {
    return unsafe cstring::memcmp(p, text.ptr(), text.len()) == 0;
}

// Keyword lookup bucketed by identifier length, then filtered on the first byte, so a miss costs at
// most a few same-length memcmps. Safety: `lexeme` must point at >= `len` readable bytes; every
// memeq compares exactly its bucket's length, never past it.
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
            if first == b'a' && memeq(lexeme, "asm") {
                return TokenType::Asm;
            }
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
            if first == b'l' && memeq(lexeme, "launch") {
                return TokenType::Launch;
            }
            if first == b'r' && memeq(lexeme, "return") {
                return TokenType::Return;
            }
            if first == b's' && memeq(lexeme, "select") {
                return TokenType::Select;
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

const fn is_mt_open(b: u8) bool {
    return b == b'(' || b == b'[' || b == b'{';
}
const fn is_mt_close(b: u8) bool {
    return b == b')' || b == b']' || b == b'}';
}
const fn mt_closer(b: u8) u8 {
    if b == b'(' {
        return b')';
    }
    if b == b'[' {
        return b']';
    }
    return b'}';
}

// 1 = float suffix (f32/f64), 0 = integer suffix, -1 = not a numeric suffix.
@c.always_inline
const fn num_suffix_kind(p: *const u8, n: usize) i32 {
    if n == 3 && (memeq(p, "f32") || memeq(p, "f64")) {
        return 1;
    }
    if n == 2 && (memeq(p, "i8") || memeq(p, "u8")) || n == 3 && (memeq(p, "i16") || memeq(p, "i32") || memeq(p, "i64") || memeq(
        p,
        "u16",
    ) || memeq(p, "u32") || memeq(p, "u64")) || n == 5 && (memeq(p, "isize") || memeq(p, "usize")) {
        return 0;
    }
    // Any other `[iu]<digits>` names a LIBRARY width -- `5i128`, `0xFFu256`, `7u100` -- which the
    // lexer cannot resolve: the typechecker knows the prelude's UInt<N>/Int<N> and validates the
    // width and the value there. The lexer only accepts the shape.
    if n >= 2 && (unsafe p[0] == b'i' || unsafe p[0] == b'u') {
        let mut digits_only = true;
        for j in 1..n {
            if unsafe p[j] < b'0' || unsafe p[j] > b'9' {
                digits_only = false;
            }
        }
        if digits_only {
            return 0;
        }
    }
    return -1;
}

extend Lexer {
    /// Pads `source` with trailing NULs IN PLACE (the sentinel the scan loops rely on; see
    /// SOURCE_PAD) and borrows it for the Lexer's lifetime.
    pub fn new<'a>(source: &'a mut String, file: str<'a>) Lexer<'a> {
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
            mt: Vector::<MtFrame>::new(),
            mt_stack: Vector::<u8>::new(),
        };
    }

    const fn is_eof(self: &Self) bool {
        return self.current >= self.bytes.len();
    }

    fn add_token(self: &mut Self, token_type: TokenType) {
        self.tokens.push(Token::new(token_type, self.start as u32, (self.current - self.start) as u32));
    }

    fn add_match(self: &mut Self, expected: u8, matched: TokenType, unmatched: TokenType) {
        let kind = if self.match_byte(expected) {
            matched;
        } else {
            unmatched;
        };
        self.add_token(kind);
    }

    const fn peek_byte(self: &Self) u8 {
        return self.bytes.byte_at(self.current);
    }

    const fn peek_next(self: &Self) u8 {
        return self.bytes.byte_at(self.current + 1);
    }

    const fn match_byte(self: &mut Self, expected: u8) bool {
        if self.peek_byte() != expected {
            return false;
        }
        self.current += 1;
        return true;
    }

    @c.cold
    fn error(self: &mut Self, message: str) {
        self.errors.emit(self.start as u32, (self.current - self.start) as u32, String::from_str(message));
    }

    @c.cold
    fn error_at(self: &mut Self, at: usize, len: usize, message: str) {
        self.errors.emit(at as u32, len as u32, String::from_str(message));
    }

    // Decodes one UTF-8 scalar starting at `current` (first byte `b`). Any malformed sequence sets
    // *size to 0 and returns 0 UNDIAGNOSED; the caller owns the error report.
    @c.cold
    fn decode_at_b(self: &Self, b: u8, current: usize, size: &mut usize) u32 {
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
        for i in 1..width {
            let continuation = self.bytes.byte_at(current + i);
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

    @c.always_inline
    fn identifier(self: &mut Self) {
        let mut i = self.current;
        while (self.class[self.bytes.byte_at(i) as usize] & CC_ID_PART) != 0u8 {
            i += 1;
        }
        self.current = i;

        let identifier_len = i - self.start;
        if identifier_len == 1 && self.bytes.byte_at(self.start) == b'_' {
            self.add_token(TokenType::Underscore);
            return;
        }

        let mut kind = TokenType::Identifier;
        if 2 <= identifier_len && identifier_len <= 9 || identifier_len == 13 {
            kind = keywords(unsafe (self.bytes.ptr() + self.start), identifier_len);
        }

        // Contextual for-modifiers: `inline`/`parallel` fuse to a modifier token ONLY when the next word
        // is `for` since they cannot be plain keywords (std::parallel is a module path). The peek crosses
        // whitespace but not comments; the token itself spans only the modifier word, so the `for` that
        // follows lexes normally and the grammar stays LL(1).
        if kind == TokenType::Identifier && (identifier_len == 6 || identifier_len == 8) {
            let p = unsafe (self.bytes.ptr() + self.start);
            let inl = identifier_len == 6 && memeq(p, "inline");
            if inl || identifier_len == 8 && memeq(p, "parallel") {
                let mut j = i;
                while (self.class[self.bytes.byte_at(j) as usize] & CC_WS) != 0u8 {
                    j += 1;
                }
                let p = unsafe (self.bytes.ptr() + j);
                if memeq(p, "for") && (self.class[self.bytes.byte_at(j + 3) as usize] & CC_ID_PART) == 0u8 {
                    kind = if inl {
                        TokenType::InlineFor;
                    } else {
                        TokenType::ParallelFor;
                    };
                }
            }
        }

        self.add_token(kind);
    }

    @c.cold
    fn validate_utf8_at(self: &mut Self, i: &mut usize) bool {
        let mut size: usize = 0;
        self.decode_at_b(self.bytes.byte_at(*i), *i, &mut size);
        if size == 0 {
            self.error_at(*i, 1, "source is not valid UTF-8");
            *i += 1;
            return false;
        }
        *i += size;
        return true;
    }

    fn whitespace(self: &mut Self) {
        let mut i = self.current;
        while (self.class[self.bytes.byte_at(i) as usize] & CC_WS) != 0u8 {
            i += 1;
        }
        self.current = i;
    }

    fn line_comment(self: &mut Self) {
        let mut i = self.current;
        loop {
            let b = self.bytes.byte_at(i);
            if b == b'\n' || b == b'\r' {
                break;
            }
            if b == b'\0' {
                if i >= self.bytes.len() {
                    break;
                }
                self.error_at(i, 1, "NUL byte is not allowed in comments");
                i += 1;
            } else if b >= 0x80u8 {
                self.validate_utf8_at(&mut i);
            } else {
                i += 1;
            }
        }
        self.current = i;
    }

    fn block_comment(self: &mut Self) {
        let mut i = self.current;
        let mut depth: usize = 1;
        loop {
            let b = self.bytes.byte_at(i);
            if b == b'/' && self.bytes.byte_at(i + 1) == b'*' {
                depth = depth + 1;
                i += 2;
            } else if b == b'*' && self.bytes.byte_at(i + 1) == b'/' {
                i += 2;
                depth -= 1;
                if depth == 0 {
                    self.current = i;
                    return;
                }
            } else if b == b'\0' {
                if i >= self.bytes.len() {
                    break;
                }
                self.error_at(i, 1, "NUL byte is not allowed in comments");
                i += 1;
            } else if b >= 0x80u8 {
                self.validate_utf8_at(&mut i);
            } else {
                i += 1;
            }
        }
        self.current = i;
        self.error_at(self.start, 2, "unterminated block comment");
    }

    // Scans one escape sequence (the '\' already consumed) and returns its scalar value. UINT32_MAX =
    // malformed, ALREADY diagnosed here; callers must not double-report, only mark the literal bad.
    fn escape(self: &mut Self, byte_character: bool) u32 {
        if self.is_eof() {
            self.error_at(self.current, 0, "unterminated escape sequence");
            return UINT32_MAX;
        }

        let at = self.current - 1;
        let escaped = self.bytes.byte_at(self.current);
        self.current += 1;

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
            if is_hex(self.bytes.byte_at(self.current)) && is_hex(self.bytes.byte_at(self.current + 1)) {
                let value = (hex_value(self.bytes.byte_at(self.current)) << 4 | hex_value(
                    self.bytes.byte_at(self.current + 1),
                )) as u32;
                self.current += 2;
                return value;
            }

            self.error_at(at, self.current - at, "\\x escape requires exactly two hexadecimal digits");
            while self.current < at + 4 && is_hex(self.bytes.byte_at(self.current)) {
                self.current += 1;
            }
            return UINT32_MAX;
        }
        if escaped == b'u' {
            if byte_character {
                if self.match_byte(b'{') {
                    while is_hex(self.peek_byte()) {
                        self.current += 1;
                    }
                    self.match_byte(b'}');
                }
                self.error_at(at, self.current - at, "Unicode escapes are not allowed in byte character literals");
                return UINT32_MAX;
            }
            if !self.match_byte(b'{') {
                self.error_at(at, self.current - at, "Unicode escape must use \\u{...} syntax");
                return UINT32_MAX;
            }
            let mut value: u32 = 0;
            let mut digits: usize = 0;
            while is_hex(self.peek_byte()) {
                if digits < 6 {
                    value = value << 4 | hex_value(self.peek_byte()) as u32;
                }
                digits += 1;
                self.current += 1;
            }
            if digits == 0 || digits > 6 || !self.match_byte(b'}') {
                self.error_at(at, self.current - at, "Unicode escape requires 1 to 6 hexadecimal digits");
                return UINT32_MAX;
            }
            if value > 0x10FFFF || value >= 0xD800 && value <= 0xDFFF {
                self.error_at(at, self.current - at, "Unicode escape is not a valid Unicode scalar value");
                return UINT32_MAX;
            }
            return value;
        }
        self.error_at(at, self.current - at, "unknown escape sequence");
        return UINT32_MAX;
    }

    @c.always_inline
    fn string_lit(self: &mut Self, kind: TokenType) {
        let mut i = self.current;
        loop {
            let b = self.bytes.byte_at(i);
            i += 1;
            if b == b'"' {
                self.current = i;
                self.add_token(kind);
                return;
            }

            if b == b'\\' {
                self.current = i;
                self.escape(false);
                i = self.current;
            } else if b == b'\n' || b == b'\r' {
                self.current = i - 1;
                self.error("unterminated string literal");
                // Resync past the next '"' (or EOF) so the rest of the line cannot cascade errors.
                while self.current < self.bytes.len() {
                    let recovery = self.bytes.byte_at(self.current);
                    self.current += 1;
                    if recovery == b'"' {
                        break;
                    }
                }
                return;
            } else if b == b'\0' {
                if i > self.bytes.len() {
                    self.current = i - 1;
                    self.error("unterminated string literal");
                    return;
                }
                self.error_at(i - 1, 1, "NUL byte is not allowed in string literals");
            } else if b >= 0x80u8 {
                i -= 1;
                self.validate_utf8_at(&mut i);
            }
        }
    }

    // After a '\'': true when an identifier run follows WITHOUT a closing '\'', so a label/lifetime
    // token, not a character literal ('a vs 'a'). The parser's lifetime grammar relies on this split.
    fn label_ahead(self: &Self) bool {
        let mut i = self.current;
        let mut b: u8 = 0;
        if i < self.bytes.len() {
            b = self.bytes.byte_at(i);
        }
        if !is_id_start(b) {
            return false;
        }
        while i < self.bytes.len() && is_id_part_byte(self.bytes.byte_at(i)) {
            i += 1;
        }
        return i >= self.bytes.len() || self.bytes.byte_at(i) != b'\'';
    }

    fn character(self: &mut Self, byte_character: bool) {
        let mut count: usize = 0;
        let mut malformed = false; // an inner error was already diagnosed; suppresses the count check at the close
        let mut invalid_byte = false; // b'..' held a multi-byte scalar; diagnosed only at the closing quote
        while !self.is_eof() {
            let b = self.bytes.byte_at(self.current);
            self.current += 1;
            if b == b'\'' {
                if !malformed && count != 1 {
                    if byte_character {
                        self.error("byte character literal must contain exactly one byte");
                    } else {
                        self.error("character literal must contain exactly one Unicode scalar value");
                    }
                } else if invalid_byte {
                    self.error("byte character literal may contain only ASCII or a \\xNN escape");
                }
                if byte_character {
                    self.add_token(TokenType::ByteCharacterLiteral);
                } else {
                    self.add_token(TokenType::CharacterLiteral);
                }
                return;
            }

            if b == b'\n' || b == b'\r' {
                self.current -= 1;
                self.error("unterminated character literal");
                return;
            }

            if b == b'\0' {
                self.error_at(self.current - 1, 1, "NUL byte is not allowed in character literals");
                count += 1;
            } else if b == b'\\' {
                if self.escape(byte_character) == UINT32_MAX {
                    malformed = true;
                } else {
                    count += 1;
                }
            } else if b < 0x80u8 {
                count += 1;
            } else {
                let mut size: usize = 0;
                self.decode_at_b(b, self.current - 1, &mut size);
                if size == 0 {
                    self.error_at(self.current - 1, 1, "source is not valid UTF-8");
                    malformed = true;
                } else {
                    self.current += size - 1;
                    count += 1;
                    invalid_byte = byte_character;
                }
            }
        }
        self.error("unterminated character literal");
    }

    // `M` (already consumed) starts a matchertext literal only when a VALID delimiter chain
    // (strictly nested pairs, possibly empty) followed by a `"` is ahead. Anything else leaves `M` an
    // ordinary identifier, so existing code like a call `M("x")` or a struct literal `M{}` is
    // untouched: those never abut a quote through a well-nested chain.
    fn matchertext_ahead(self: &Self) bool {
        let mut i = self.current;
        let mut dn: usize = 0;
        while i < self.bytes.len() && is_mt_open(self.bytes.byte_at(i)) {
            i += 1;
            dn = dn + 1;
        }
        let mut k = dn;
        while k > 0 {
            k = k - 1;
            if i >= self.bytes.len() || self.bytes.byte_at(i) != mt_closer(self.bytes.byte_at(self.current + k)) {
                return false;
            }
            i += 1;
        }
        return i < self.bytes.len() && self.bytes.byte_at(i) == b'"';
    }

    // Does src[at..at+dn] spell the hole delimiter sequence? Openers as written for the open side;
    // their closers in reverse for the close side.
    const fn mt_seq_at(self: &Self, at: usize, dpos: usize, dn: usize, close: bool) bool {
        let mut k: usize = 0;
        while k < dn {
            if at + k >= self.bytes.len() {
                return false;
            }
            let idx = if close {
                dn - 1 - k;
            } else {
                k;
            };
            let d = self.bytes.byte_at(dpos + idx);
            let want = if close {
                mt_closer(d);
            } else {
                d;
            };
            if self.bytes.byte_at(at + k) != want {
                return false;
            }
            k = k + 1;
        }
        return true;
    }

    // Scans a matchertext template from `current` until the literal ends (closer of the outermost
    // matcher, then `"`) or an interpolation hole opens (the frame's delimiter sequence). `first` is
    // true from the literal head: it selects MatchertextLiteral/Begin over End/Mid. On a hole the
    // frame stays on `self.mt` and the main loop lexes the hole as ordinary tokens.
    fn mt_scan_template(self: &mut Self, first: bool) {
        let fi = self.mt.len() - 1;
        let dpos = self.mt[fi].dpos as usize;
        let dn = self.mt[fi].d_len as usize;
        let base = self.mt[fi].base as usize;
        let mut i = self.current;
        while i < self.bytes.len() {
            let b = self.bytes.byte_at(i);
            if b == b'\0' {
                self.error_at(i, 1, "NUL byte is not allowed in matchertext literals");
                i += 1;
            } else if b >= 0x80u8 {
                self.validate_utf8_at(&mut i);
            } else if is_mt_open(b) {
                if dn > 0 && self.mt_seq_at(i, dpos, dn, false) {
                    self.current = i + dn;
                    self.add_token(
                        if first {
                            TokenType::MatchertextBegin;
                        } else {
                            TokenType::MatchertextMid;
                        },
                    );
                    self.mt[fi].hole_depth = 0;
                    return;
                }
                self.mt_stack.push(b);
                i += 1;
            } else if is_mt_close(b) {
                if self.mt_stack.len() == base + 1 {
                    if b == mt_closer(self.mt_stack[base]) {
                        self.current = i + 1;
                        if i + 1 < self.bytes.len() && self.bytes.byte_at(i + 1) == b'"' {
                            self.current = i + 2;
                        } else {
                            self.error("matchertext literal must end with '\"' right after the closing matcher");
                        }
                        self.add_token(
                            if first {
                                TokenType::MatchertextLiteral;
                            } else {
                                TokenType::MatchertextEnd;
                            },
                        );
                        let _ = self.mt_stack.pop();
                        let _ = self.mt.pop();
                        return;
                    }
                    self.error_at(i, 1, "mismatched matchers in matchertext literal");
                    i += 1;
                } else {
                    let o = self.mt_stack[self.mt_stack.len() - 1];
                    let _ = self.mt_stack.pop();
                    if b != mt_closer(o) {
                        self.error_at(i, 1, "mismatched matchers in matchertext literal");
                    }
                    i += 1;
                }
            } else {
                i += 1;
            }
        }
        self.current = i;
        self.error("unterminated matchertext literal");
        while self.mt_stack.len() > base {
            let _ = self.mt_stack.pop();
        }
        let _ = self.mt.pop();
    }

    // `M` consumed, a matcher-run + `"` ahead: validate the delimiter chain (strictly nested pairs),
    // require an opening matcher right after the `"`, then scan the template. Malformed heads resync
    // as an ordinary string literal so one bad literal yields one diagnostic.
    fn matchertext(self: &mut Self) {
        let dpos = self.current;
        let mut i = self.current;
        let mut dn: usize = 0;
        while is_mt_open(self.bytes.byte_at(i)) {
            i += 1;
            dn = dn + 1;
        }
        let mut k = dn;
        let mut ok = dn <= 255;
        while ok && k > 0 {
            k = k - 1;
            if self.bytes.byte_at(i) != mt_closer(self.bytes.byte_at(dpos + k)) {
                ok = false;
            }
            i += 1;
        }
        if !ok || self.bytes.byte_at(i) != b'"' {
            while i < self.bytes.len() && self.bytes.byte_at(i) != b'"' {
                i += 1;
            }
            self.error_at(
                self.start,
                i - self.start,
                "matchertext interpolation delimiter must be strictly nested matcher pairs, like `M{}\"(...)\"` or `M([{}])\"(...)\"`",
            );
            self.current = i + 1;
            self.string_lit(TokenType::StringLiteral);
            return;
        }
        i += 1;
        let o = self.bytes.byte_at(i);
        if !is_mt_open(o) {
            self.error_at(i, 1, "matchertext content must be delimited by '(', '[', or '{' inside the quotes");
            self.current = i;
            self.string_lit(TokenType::StringLiteral);
            return;
        }
        self.mt.push(MtFrame { dpos: dpos as u32, d_len: dn as u8, base: self.mt_stack.len() as u32, hole_depth: 0 });
        self.mt_stack.push(o);
        self.current = i + 1;
        self.mt_scan_template(true);
    }

    // Matcher-token hooks for interpolation holes: while the innermost frame is paused in a hole,
    // open matchers deepen it and a close matcher at hole level must spell the closing delimiter
    // sequence, which resumes the paused template.
    const fn mt_hole_open(self: &mut Self) {
        let fi = self.mt.len() - 1;
        self.mt[fi].hole_depth = self.mt[fi].hole_depth + 1;
    }

    // True when the closer resumed the template (the segment token has been added).
    fn mt_hole_close(self: &mut Self) bool {
        let fi = self.mt.len() - 1;
        if self.mt[fi].hole_depth > 0 {
            self.mt[fi].hole_depth = self.mt[fi].hole_depth - 1;
            return false;
        }
        if self.mt_seq_at(self.start, self.mt[fi].dpos as usize, self.mt[fi].d_len as usize, true) {
            self.current = self.start + self.mt[fi].d_len as usize;
            self.mt_scan_template(false);
            return true;
        }
        self.error_at(self.start, 1, "unbalanced matcher in matchertext interpolation hole");
        return false;
    }

    // Scans a digit run allowing '_' only BETWEEN digits; the first bad separator position latches into
    // *error_at (USIZE_MAX = none yet) while scanning continues, so the run is consumed whole.
    fn digits(self: &mut Self, component_start: usize, error_at: *mut usize, pred: fn(u8) bool) {
        let mut i = self.current;
        while i < self.bytes.len() {
            let b = self.bytes.byte_at(i);
            if pred(b) {
                i += 1;
            } else if b == b'_' {
                let prev = i > component_start && pred(self.bytes.byte_at(i - 1));
                let next = i + 1 < self.bytes.len() && pred(self.bytes.byte_at(i + 1));
                if (!prev || !next) && unsafe *error_at == USIZE_MAX {
                    unsafe *error_at = i;
                }
                i += 1;
            } else {
                break;
            }
        }
        self.current = i;
    }

    fn number(self: &mut Self) {
        // First error wins: error_at/error latch once (USIZE_MAX = none), but scanning continues so the
        // whole literal is consumed and exactly one diagnostic covers it.
        let mut error_at = USIZE_MAX;
        let mut error: str = "";
        let mut is_float = false;
        // Radix-prefixed scan (0x/0o/0b): the full id-part run is consumed so bad digits and suffixes
        // stay inside one token.
        if self.bytes.byte_at(self.start) == b'0' {
            let mut radix: u32 = 10;
            let mut digit: fn(u8) bool = is_dec;
            let prefix = self.peek_byte();
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
                self.current += 1;
                let component_start = self.current;
                let mut saw_digit = false;
                let mut i = self.current;
                while i < self.bytes.len() && is_id_part_byte(self.bytes.byte_at(i)) {
                    let b = self.bytes.byte_at(i);
                    if digit(b) {
                        saw_digit = true;
                    } else if b == b'_' {
                        let prev = i > component_start && digit(self.bytes.byte_at(i - 1));
                        let next = i + 1 < self.bytes.len() && digit(self.bytes.byte_at(i + 1));
                        if (!prev || !next) && error_at == USIZE_MAX {
                            error_at = i;
                            error = "invalid numeric separator";
                        }
                    } else {
                        if radix == 16 && saw_digit && (b == b'p' || b == b'P') {
                            break;
                        }
                        let mut j = i;
                        while j < self.bytes.len() && is_id_part_byte(self.bytes.byte_at(j)) {
                            j = j + 1;
                        }
                        if saw_digit && num_suffix_kind(unsafe (self.bytes.ptr() + i), j - i) == 0 {
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
                    i += 1;
                }
                self.current = i;
                if !saw_digit && error_at == USIZE_MAX {
                    error_at = component_start;
                    error = "radix prefix must be followed by at least one digit";
                }
                // Hex float: '.' commits only when a hex digit follows; the 'p' exponent is mandatory
                // (a fraction without one is diagnosed below).
                let mut hex_float = false;
                if radix == 16 && error_at == USIZE_MAX && self.peek_byte() == b'.' && is_hex(self.peek_next()) {
                    hex_float = true;
                    self.current += 1;
                    while is_hex(self.peek_byte()) {
                        self.current += 1;
                    }
                }
                if radix == 16 && error_at == USIZE_MAX && (self.peek_byte() == b'p' || self.peek_byte() == b'P') {
                    hex_float = true;
                    self.current += 1;
                    if self.peek_byte() == b'+' || self.peek_byte() == b'-' {
                        self.current += 1;
                    }
                    let exp_start = self.current;
                    while is_dec(self.peek_byte()) {
                        self.current += 1;
                    }
                    if self.current == exp_start {
                        error_at = exp_start;
                        error = "hexadecimal float exponent requires at least one decimal digit";
                    } else if is_id_part_byte(self.peek_byte()) {
                        let sfx = self.current;
                        while is_id_part_byte(self.peek_byte()) {
                            self.current += 1;
                        }
                        if num_suffix_kind(unsafe (self.bytes.ptr() + sfx), self.current - sfx) != 1 {
                            error_at = sfx;
                            error = "a hexadecimal float takes only an 'f32' or 'f64' suffix";
                        }
                    }
                } else if hex_float && error_at == USIZE_MAX {
                    error_at = self.current;
                    error = "a hexadecimal float requires a binary exponent ('p'), e.g. 0x1.8p3";
                }
                // A '.' after any other radix literal is an error, but the whole float-shaped run is
                // still consumed so it remains a single bad token.
                if !hex_float && self.peek_byte() == b'.' {
                    if error_at == USIZE_MAX {
                        error_at = self.current;
                        if radix == 16 {
                            error = "a hexadecimal float needs a fraction digit and a binary exponent: 0x1.8p3";
                        } else {
                            error = "octal and binary floating-point literals are not supported";
                        }
                    }
                    self.current += 1;
                    while !self.is_eof() {
                        let b = self.peek_byte();
                        if !is_id_part_byte(b) && b != b'.' && b != b'+' && b != b'-' {
                            break;
                        }
                        self.current += 1;
                    }
                }
                if error_at != USIZE_MAX {
                    self.error_at(error_at, 1, error);
                } else {
                    if hex_float {
                        self.add_token(TokenType::FloatLiteral);
                    } else {
                        self.add_token(TokenType::IntegerLiteral);
                    }
                }
                return;
            }
        }
        let integer_start = self.current;
        self.digits(integer_start - 1, &mut error_at, is_dec);
        if error_at != USIZE_MAX {
            error = "invalid numeric separator";
        }
        // Decimal fraction: a digit must follow the '.', else '1..2' is a range and 'x.0.len' is a
        // tuple-index member access (`0.len`), never a fraction.
        if self.peek_byte() == b'.' && is_dec(self.peek_next()) {
            is_float = true;
            self.current += 1;
            let fraction_start = self.current;
            self.digits(fraction_start, &mut error_at, is_dec);
            if error_at != USIZE_MAX && error.len() == 0 {
                error = "invalid numeric separator";
            }
        }
        if self.peek_byte() == b'e' || self.peek_byte() == b'E' {
            is_float = true;
            self.current += 1;
            if self.peek_byte() == b'+' || self.peek_byte() == b'-' {
                self.current += 1;
            }
            let exponent_start = self.current;
            self.digits(exponent_start, &mut error_at, is_dec);
            if self.current == exponent_start && error_at == USIZE_MAX {
                error_at = exponent_start;
                error = "exponent requires at least one decimal digit";
            } else if error_at != USIZE_MAX && error.len() == 0 {
                error = "invalid numeric separator";
            }
        }
        // Suffix: the whole id-part tail is consumed; f32/f64 flips the literal to float.
        if is_id_part_byte(self.peek_byte()) {
            let sfx_start = self.current;
            while is_id_part_byte(self.peek_byte()) {
                self.current += 1;
            }
            let k = num_suffix_kind(unsafe (self.bytes.ptr() + sfx_start), self.current - sfx_start);
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
            self.error_at(error_at, 1, error);
        } else {
            if is_float {
                self.add_token(TokenType::FloatLiteral);
            } else {
                self.add_token(TokenType::IntegerLiteral);
            }
        }
    }

    fn scan_token(self: &mut Self) {
        let c = self.bytes.byte_at(self.current);
        if c < 0x80u8 {
            self.current += 1;
        }
        switch c {
            b' ' | b'\t' | b'\x0b' | b'\x0c' | b'\n' | b'\r' => {
                self.whitespace();
                return;
            },
            '{' => {
                if self.mt.len() != 0 {
                    self.mt_hole_open();
                }
                self.add_token(TokenType::LeftBrace);
                return;
            },
            '}' => {
                if self.mt.len() != 0 && self.mt_hole_close() {
                    return;
                }
                self.add_token(TokenType::RightBrace);
                return;
            },
            '(' => {
                if self.mt.len() != 0 {
                    self.mt_hole_open();
                }
                self.add_token(TokenType::LeftParen);
                return;
            },
            ')' => {
                if self.mt.len() != 0 && self.mt_hole_close() {
                    return;
                }
                self.add_token(TokenType::RightParen);
                return;
            },
            '[' => {
                if self.mt.len() != 0 {
                    self.mt_hole_open();
                }
                self.add_token(TokenType::LeftBracket);
                return;
            },
            ']' => {
                if self.mt.len() != 0 && self.mt_hole_close() {
                    return;
                }
                self.add_token(TokenType::RightBracket);
                return;
            },
            ',' => {
                self.add_token(TokenType::Comma);
                return;
            },
            ';' => {
                self.add_token(TokenType::Semicolon);
                return;
            },
            ':' => {
                if self.match_byte(b':') {
                    self.add_token(TokenType::PathSeparator);
                } else {
                    self.add_token(TokenType::Colon);
                }
                return;
            },
            '~' => {
                self.add_token(TokenType::Tilde);
                return;
            },
            '%' => {
                self.add_match(b'=', TokenType::PercentEqual, TokenType::Percent);
                return;
            },
            '^' => {
                self.add_match(b'=', TokenType::CaretEqual, TokenType::Caret);
                return;
            },
            '+' => {
                self.add_match(b'=', TokenType::PlusEqual, TokenType::Plus);
                return;
            },
            '-' => {
                if self.match_byte(b'>') {
                    self.add_token(TokenType::Arrow);
                    return;
                }
                self.add_match(b'=', TokenType::MinusEqual, TokenType::Minus);
                return;
            },
            '*' => {
                self.add_match(b'=', TokenType::StarEqual, TokenType::Star);
                return;
            },
            '=' => {
                if self.match_byte(b'=') {
                    self.add_token(TokenType::EqualEqual);
                    return;
                }
                self.add_match(b'>', TokenType::FatArrow, TokenType::Equal);
                return;
            },
            '!' => {
                self.add_match(b'=', TokenType::BangEqual, TokenType::Bang);
                return;
            },
            '<' => {
                if self.match_byte(b'<') {
                    self.add_match(b'=', TokenType::LeftShiftEqual, TokenType::LeftShift);
                    return;
                }
                self.add_match(b'=', TokenType::LessThanEqual, TokenType::LessThan);
                return;
            },
            '>' => {
                // Always a single '>': the parser reassembles '>>', '>=', '>>=' itself so that nested
                // generics ('Vec<Vec<T>>') can close.
                self.add_token(TokenType::GreaterThan);
                return;
            },
            '&' => {
                if self.match_byte(b'&') {
                    self.add_token(TokenType::AmpersandAmpersand);
                    return;
                }
                self.add_match(b'=', TokenType::AmpersandEqual, TokenType::Ampersand);
                return;
            },
            '|' => {
                if self.match_byte(b'|') {
                    self.add_token(TokenType::PipePipe);
                    return;
                }
                self.add_match(b'=', TokenType::PipeEqual, TokenType::Pipe);
                return;
            },
            '?' => {
                self.add_token(TokenType::Question);
                return;
            },
            '/' => {
                if self.match_byte(b'/') {
                    self.line_comment();
                    if self.keep_trivia {
                        // `///...` is a doc comment; `//...` a plain one. The 3rd byte decides.
                        let doc = self.current - self.start > 2 && self.bytes.byte_at(self.start + 2) == b'/';
                        if doc {
                            self.add_token(TokenType::DocLineComment);
                        } else {
                            self.add_token(TokenType::LineComment);
                        }
                    }
                } else if self.match_byte(b'*') {
                    self.block_comment();
                    if self.keep_trivia {
                        let doc = self.current - self.start > 4 && self.bytes.byte_at(self.start + 2) == b'*';
                        if doc {
                            self.add_token(TokenType::DocBlockComment);
                        } else {
                            self.add_token(TokenType::BlockComment);
                        }
                    }
                } else {
                    self.add_match(b'=', TokenType::SlashEqual, TokenType::Slash);
                }
                return;
            },
            '.' => {
                if self.match_byte(b'.') {
                    if self.match_byte(b'.') {
                        self.add_token(TokenType::Ellipsis);
                    } else if self.match_byte(b'=') {
                        self.add_token(TokenType::RangeInclusive);
                    } else {
                        self.add_token(TokenType::Range);
                    }
                } else {
                    self.add_token(TokenType::Dot);
                }
                return;
            },
            '"' => {
                self.string_lit(TokenType::StringLiteral);
                return;
            },
            '\'' => {
                if self.label_ahead() {
                    while is_id_part_byte(self.peek_byte()) {
                        self.current += 1;
                    }
                    self.add_token(TokenType::Label);
                    return;
                }
                self.character(false);
                return;
            },
            '0'..='9' => {
                self.number();
                return;
            },
            'M' => {
                if self.matchertext_ahead() {
                    self.matchertext();
                    return;
                }
                self.identifier();
                return;
            },
            'b' => {
                if self.peek_byte() == b'\'' {
                    self.current += 1;
                    self.character(true);
                } else if self.peek_byte() == b'"' {
                    self.current += 1;
                    self.string_lit(TokenType::ByteStringLiteral);
                } else {
                    self.identifier();
                }
                return;
            },
            '#' => {
                self.error_at(self.start, 1, "'#' is not valid in Super-C source; Super-C has no preprocessor");
                return;
            },
            '@' => {
                self.add_token(TokenType::At);
                return;
            },
            '$' => {
                self.error_at(self.start, 1, "'$' is reserved");
                return;
            },
            '`' => {
                self.error_at(self.start, 1, "'`' is reserved");
                return;
            },
            b'\0' => {
                self.error_at(self.start, 1, "NUL byte is not allowed in source");
                return;
            },
            'a'..='z' | 'A'..='Z' | '_' => {
                self.identifier();
                return;
            },
            _ => {
                if c >= 0x80u8 {
                    let mut size: usize = 0;
                    let cp = self.decode_at_b(c, self.current, &mut size);
                    if size == 0 {
                        self.error_at(self.start, 1, "source is not valid UTF-8");
                        self.current += 1;
                    } else {
                        self.current += size;
                        if cp == 0xFEFF {
                            self.error_at(self.start, size, "UTF-8 BOM is allowed only at the start of a file");
                        } else {
                            self.error_at(
                                self.start,
                                size,
                                "identifiers may contain only ASCII letters, digits, and '_'",
                            );
                        }
                    }
                } else {
                    self.errors.emit(self.start as u32, 1, format("unexpected character '{}'", c as char));
                }
            },
        };
    }

    /// Scans the whole source into `tokens`, ending with an Eof token spanning (len, 0). Recovers
    /// from every error (diagnostics accumulate in `errors`; the stream is always complete). A
    /// UTF-8 BOM is consumed only at byte 0; anywhere else it is diagnosed.
    pub fn scan_tokens(self: &mut Self) {
        self.tokens.reserve(self.bytes.len() / 5);
        if self.current == 0 && self.bytes.len() >= 3 && self.bytes.byte_at(0) == 0xEFu8 && self.bytes.byte_at(1) == 0xBBu8 && self.bytes.byte_at(
            2,
        ) == 0xBFu8 {
            self.current = 3;
        }
        while self.current < self.bytes.len() {
            self.start = self.current;
            self.scan_token();
        }
        if self.mt.len() != 0 {
            self.errors.emit(
                self.bytes.len() as u32,
                0,
                String::from_str("unterminated matchertext literal (unclosed interpolation hole)"),
            );
            self.mt.clear();
            self.mt_stack.clear();
        }
        self.tokens.push(Token::new(TokenType::Eof, self.bytes.len() as u32, 0));
        self.errors.finalize(self.bytes, self.file);
    }

    /// Moves the token vector out; the lexer is left holding an empty one.
    pub fn take_tokens(self: &mut Self) Vector<Token> {
        let out = replace(&mut self.tokens, Vector::<Token>::new());
        return out;
    }

    /// True once any scan error is recorded.
    pub const fn has_errors(self: &Self) bool {
        return self.errors.has_errors();
    }
    /// Print the accumulated diagnostics to stderr.
    pub fn log_errors(self: &Self) {
        self.errors.log();
    }
}
