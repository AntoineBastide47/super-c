// Token is a packed u64, not a struct: bits 0-31 = start byte offset, 32-55 = length, 56-63 =
// TokenType. No text is stored; a token's span indexes the source buffer. Invariants: a lexeme is
// < 2^24 bytes long and TokenType fits in 8 bits.
import lexer::token_type as *;

/// Half-open byte range [start, end) into a source buffer.
pub struct Span {
    pub start: u32,
    pub end: u32,
}

// Restated derived conformance for the bootstrap compiler (see ir::core `exact`).
extend Span as Copy {}

extend Span {
    /// The range [start, end); no ordering check.
    pub const fn new(start: u32, end: u32) Span {
        return Span { start: start, end: end };
    }

    /// The zero-length range at offset 0.
    pub const fn empty() Span {
        return Span { start: 0, end: 0 };
    }
}

pub type Token = u64;

/// The longest lexeme a Token can hold (24-bit length field).
pub const TOKEN_MAX_LEN: usize = 0xFFFFFF;

extend Token {
    /// Packs (kind, start, len). `len` must be at most TOKEN_MAX_LEN: it is stored in 24 bits, and a
    /// larger value would bleed into the kind bits (len() masks on read; new() does not). The lexer
    /// rejects longer lexemes.
    pub const fn new(kind: TokenType, start: u32, len: u32) Token {
        return start as u64 | len as u64 << 32 | kind as u64 << 56;
    }

    /// Byte offset of the lexeme's first byte.
    pub const fn start(self: Self) u32 {
        return self as u32;
    }

    /// Lexeme length in bytes (24-bit field).
    pub const fn len(self: Self) u32 {
        return (self >> 32 & 0xFFFFFF) as u32;
    }

    /// Byte offset one past the lexeme's last byte.
    pub const fn end(self: Self) u32 {
        return self.start() + self.len();
    }

    /// The token kind stored in the top 8 bits.
    pub const fn kind(self: Self) TokenType {
        return (self >> 56) as TokenType;
    }

    /// The lexeme's [start, end) range.
    pub const fn span(self: Self) Span {
        return Span::new(self.start(), self.end());
    }
}

/// The scalar value of the `'x'` or `b'x'` literal spelled at `sp` in `src`: one UTF-8 sequence or one
/// escape (`\n \r \t \\ \' \" \0 \xHH \u{H..}`). Every pass that needs a literal's value calls this, so
/// the checker, pattern analysis, lowering and CTFE agree. None: the spelling is malformed (the lexer
/// already reported it).
pub fn char_literal_value(src: str, sp: Span) Option<i64> {
    if sp.end < sp.start + 3 || sp.end as usize > src.len() {
        return Option::<i64>::None;
    }
    let mut i = sp.start as usize + 1;
    if src[sp.start as usize] == b'b' {
        i += 1;
    }
    let end = sp.end as usize - 1; // the closing quote
    if i >= end {
        return Option::<i64>::None;
    }
    let b = src[i];
    if b != b'\\' {
        let mut n: usize = 4;
        let mut v = (b & 0x07u8) as i64;
        if b < 0x80u8 {
            n = 1;
            v = b;
        } else if b < 0xE0u8 {
            n = 2;
            v = b & 0x1Fu8;
        } else if b < 0xF0u8 {
            n = 3;
            v = b & 0x0Fu8;
        }
        if i + n != end {
            return Option::<i64>::None;
        }
        for k in i + 1..end {
            v = v << 6 | (src[k] & 0x3Fu8) as i64;
        }
        return Option::<i64>::Some(v);
    }
    if i + 1 >= end {
        return Option::<i64>::None;
    }
    let e = src[i + 1];
    let mut from = i + 2;
    let mut to = end;
    if e == b'x' {
        if to != from + 2 {
            return Option::<i64>::None;
        }
    } else if e == b'u' {
        if to < from + 3 || src[from] != b'{' || src[to - 1] != b'}' {
            return Option::<i64>::None;
        }
        from += 1;
        to -= 1;
    } else {
        if from != end {
            return Option::<i64>::None;
        }
        if e == b'n' {
            return Option::<i64>::Some(10);
        }
        if e == b'r' {
            return Option::<i64>::Some(13);
        }
        if e == b't' {
            return Option::<i64>::Some(9);
        }
        if e == b'0' {
            return Option::<i64>::Some(0);
        }
        if e == b'\\' || e == b'\'' || e == b'"' {
            return Option::<i64>::Some(e);
        }
        return Option::<i64>::None;
    }
    let mut v: i64 = 0;
    for k in from..to {
        let c = src[k];
        let mut d: i64 = 16;
        if c >= b'0' && c <= b'9' {
            d = c - b'0';
        } else if c >= b'a' && c <= b'f' {
            d = (c - b'a') as i64 + 10;
        } else if c >= b'A' && c <= b'F' {
            d = (c - b'A') as i64 + 10;
        }
        if d == 16 {
            return Option::<i64>::None;
        }
        v = v << 4 | d;
    }
    return Option::<i64>::Some(v);
}
