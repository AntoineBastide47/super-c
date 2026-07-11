import lexer::token_type as *;

pub struct Span {
    pub start: u32,
    pub end: u32,
}

extend Span {
    pub fn new(start: u32, end: u32) Span {
        return Span { start: start, end: end };
    }

    pub fn empty() Span {
        return Span { start: 0, end: 0 };
    }
}

pub type Token = u64;

extend Token {
    pub fn new(kind: TokenType, start: u32, len: u32) Token {
        return start as u64 | len as u64 << 32 | kind as u64 << 56;
    }

    pub fn start(self: Self) u32 {
        return self as u32;
    }

    pub fn len(self: Self) u32 {
        return (self >> 32 & 0xFFFFFF) as u32;
    }

    pub fn end(self: Self) u32 {
        return self.start() + self.len();
    }

    pub fn kind(self: Self) TokenType {
        return (self >> 56) as TokenType;
    }

    pub fn span(self: Self) Span {
        return Span::new(self.start(), self.end());
    }

    pub fn fprint(self: Self) void {
        eprintln(
            "Token {{ token_type: {}, span: Span {{ start: {}, end: {} }} }}",
            self.kind().name(),
            self.start(),
            self.end(),
        );
    }
}
