// Token is a packed u64, not a struct: bits 0-31 = start byte offset, 32-55 = length, 56-63 =
// TokenType. No text is stored; a token's span indexes the source buffer. Invariants: a lexeme is
// < 2^24 bytes long and TokenType fits in 8 bits.
import lexer::token_type as *;
import utils::persist as *;

// `@derive(Copy)` restates the derivation for the bootstrap compiler, which checks a `Copy` bound against
// written conformances only.
/// Half-open byte range [start, end) into a source buffer.
@derive(Copy)
pub(package) struct Span {
    pub(package) start: u32,
    pub(package) end: u32,
}

extend Span as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &Span, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut Span, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend Span {
    /// The range [start, end); no ordering check.
    pub(package) const fn new(start: u32, end: u32) Span {
        return Span { start: start, end: end };
    }

    /// The zero-length range at offset 0.
    pub(package) const fn empty() Span {
        return Span { start: 0, end: 0 };
    }
}

pub(package) type Token = u64;

/// The longest lexeme a Token can hold (24-bit length field).
pub(package) const TOKEN_MAX_LEN: usize = 0xFFFFFF;

extend Token {
    /// Packs (kind, start, len). `len` must be at most TOKEN_MAX_LEN: it is stored in 24 bits, and a
    /// larger value would bleed into the kind bits (len() masks on read; new() does not). The lexer
    /// rejects longer lexemes.
    pub(package) const fn new(kind: TokenType, start: u32, len: u32) Token {
        return start as u64 | len as u64 << 32 | kind as u64 << 56;
    }

    /// Byte offset of the lexeme's first byte.
    pub(package) const fn start(self: Self) u32 {
        return self as u32;
    }

    /// Lexeme length in bytes (24-bit field).
    pub(package) const fn len(self: Self) u32 {
        return (self >> 32 & 0xFFFFFF) as u32;
    }

    /// Byte offset one past the lexeme's last byte.
    pub(package) const fn end(self: Self) u32 {
        return self.start() + self.len();
    }

    /// The token kind stored in the top 8 bits.
    pub(package) const fn kind(self: Self) TokenType {
        return (self >> 56) as TokenType;
    }

    /// The lexeme's [start, end) range.
    pub(package) const fn span(self: Self) Span {
        return Span::new(self.start(), self.end());
    }
}

/// The scalar value of the `'x'` or `b'x'` literal spelled at `sp` in `src`: one UTF-8 sequence or one
/// escape (`\n \r \t \\ \' \" \0 \xHH \u{H..}`). Every pass that needs a literal's value calls this, so
/// the checker, pattern analysis, lowering and CTFE agree. None: the spelling is malformed (the lexer
/// already reported it).
pub(package) const fn char_literal_value(src: str, sp: Span) Option<i64> {
    if sp.end < sp.start + 3 || sp.end as usize > src.len() {
        return None;
    }
    let mut i = sp.start as usize + 1;
    if src[sp.start as usize] == b'b' {
        i += 1;
    }
    let end = sp.end as usize - 1; // the closing quote
    if i >= end {
        return None;
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
            return None;
        }
        for k in i + 1..end {
            v = v << 6 | (src[k] & 0x3Fu8) as i64;
        }
        return Some(v);
    }
    if i + 1 >= end {
        return None;
    }
    let e = src[i + 1];
    let mut from = i + 2;
    let mut to = end;
    if e == b'x' {
        if to != from + 2 {
            return None;
        }
    } else if e == b'u' {
        if to < from + 3 || src[from] != b'{' || src[to - 1] != b'}' {
            return None;
        }
        from += 1;
        to -= 1;
    } else {
        if from != end {
            return None;
        }
        if e == b'n' {
            return Some(10);
        }
        if e == b'r' {
            return Some(13);
        }
        if e == b't' {
            return Some(9);
        }
        if e == b'0' {
            return Some(0);
        }
        if e == b'\\' || e == b'\'' || e == b'"' {
            return Some(e);
        }
        return None;
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
            return None;
        }
        v = v << 4 | d;
    }
    return Some(v);
}

const fn hexv(b: u8) u32 {
    if b >= 48 && b <= 57 {
        return b - 48;
    }
    if b >= 97 && b <= 102 {
        return b - 97 + 10;
    }
    if b >= 65 && b <= 70 {
        return b - 65 + 10;
    }
    return 0;
}

// Codepoint `cp` as UTF-8.
fn push_utf8(cp: u32, dst: &mut String) {
    if cp < 0x80 {
        dst.push_byte(cp as u8);
    } else if cp < 0x800 {
        dst.push_byte((0xC0 | cp >> 6) as u8);
        dst.push_byte((0x80 | cp & 0x3F) as u8);
    } else if cp < 0x10000 {
        dst.push_byte((0xE0 | cp >> 12) as u8);
        dst.push_byte((0x80 | cp >> 6 & 0x3F) as u8);
        dst.push_byte((0x80 | cp & 0x3F) as u8);
    } else {
        dst.push_byte((0xF0 | cp >> 18) as u8);
        dst.push_byte((0x80 | cp >> 12 & 0x3F) as u8);
        dst.push_byte((0x80 | cp >> 6 & 0x3F) as u8);
        dst.push_byte((0x80 | cp & 0x3F) as u8);
    }
}

/// The bytes of a Super-C quoted or byte-string body (escapes intact) onto `dst`: each escape decodes
/// to its byte(s) (`\xNN` is EXACTLY two hex digits, `\u{H..}` a codepoint as UTF-8).
pub(package) fn str_decode(raw: str, dst: &mut String) {
    let mut i: usize = 0;
    while i < raw.len() {
        let b = raw.byte_at(i);
        if b != 92 || i + 1 >= raw.len() {
            dst.push_byte(b);
            i += 1;
            continue;
        }
        let e = raw.byte_at(i + 1);
        i += 2;
        if e == b'n' {
            dst.push_byte(10);
        } else if e == b'r' {
            dst.push_byte(13);
        } else if e == b't' {
            dst.push_byte(9);
        } else if e == b'0' {
            dst.push_byte(0);
        } else if e == b'x' && i + 1 < raw.len() {
            dst.push_byte((hexv(raw.byte_at(i)) << 4 | hexv(raw.byte_at(i + 1))) as u8);
            i += 2;
        } else if e == b'u' && i < raw.len() && raw.byte_at(i) == b'{' {
            i += 1;
            let mut cp: u32 = 0;
            while i < raw.len() && raw.byte_at(i) != b'}' {
                cp = cp << 4 | hexv(raw.byte_at(i));
                i += 1;
            }
            if i < raw.len() {
                i += 1;
            }
            push_utf8(cp, dst);
        } else {
            // `\\`, `\"`, `\'`: the escaped byte itself.
            dst.push_byte(e);
        }
    }
}
