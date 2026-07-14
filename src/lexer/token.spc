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
