// Token is a packed u64, not a struct: bits 0-31 = start byte offset, 32-55 = length, 56-63 =
// TokenType. No text is stored -- a token's span indexes the source buffer. Invariants: a lexeme is
// < 2^24 bytes long and TokenType fits in 8 bits.
import lexer::token_type as *;

pub struct Span {
    pub start: u32,
    pub end: u32,
}

extend Span {
    pub const fn new(start: u32, end: u32) Span {
        return Span { start: start, end: end };
    }

    pub const fn empty() Span {
        return Span { start: 0, end: 0 };
    }
}

pub type Token = u64;

extend Token {
    /// Packs (kind, start, len). `len` must be < 2^24: it is stored in 24 bits, and a larger value
    /// would bleed into the kind bits (len() masks on read; new() does not).
    pub const fn new(kind: TokenType, start: u32, len: u32) Token {
        return start as u64 | len as u64 << 32 | kind as u64 << 56;
    }

    pub const fn start(self: Self) u32 {
        return self as u32;
    }

    pub const fn len(self: Self) u32 {
        return (self >> 32 & 0xFFFFFF) as u32;
    }

    pub const fn end(self: Self) u32 {
        return self.start() + self.len();
    }

    pub const fn kind(self: Self) TokenType {
        return (self >> 56) as TokenType;
    }

    pub const fn span(self: Self) Span {
        return Span::new(self.start(), self.end());
    }
}
