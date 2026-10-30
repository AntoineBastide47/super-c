// UTF-8 to UTF-16 and back. `encode` and `encode_into` take well-formed UTF-8 (Unicode Table 3-7) and
// write UTF-16 code units; `decode` takes UTF-16 and appends UTF-8 to a String. Ill-formed input stops the
// conversion with the offset of the first bad sequence, and the output keeps what it held before the call.
// No operating-system access; the result is the same on every target.

/// Why `encode` or `encode_into` stopped.
@derive(Eq, Format)
pub enum EncodeError {
    /// The bytes that start at this byte offset are not well-formed UTF-8.
    InvalidUtf8(usize),
    /// The caller's buffer holds fewer code units than the text needs.
    BufferTooSmall,
}

/// Why `decode` stopped: the code unit at `offset` is a surrogate without its pair.
@derive(Eq, Format)
pub struct DecodeError {
    pub offset: usize,
}

/// Append the UTF-16 code units of `s` to `out`. At most one allocation: `out` reserves `s.len()` units,
/// the most the text can need. On error `out` keeps its previous contents.
pub fn encode<A: Allocator>(s: str, out: &mut Vector<u16, A>) Result<Unit, EncodeError> {
    let start = out.len();
    out.reserve(s.len());
    let mut i: usize = 0;
    // Each pass consumes at least one byte.
    while i < s.len() {
        let (c, n) = scalar_at(s, i);
        if n == 0 {
            out.truncate(start);
            return Err(InvalidUtf8(i));
        }
        if c < 0x10000 {
            out.push(c as u16);
        } else {
            out.push(high_surrogate(c));
            out.push(low_surrogate(c));
        }
        i += n;
    }
    return Ok(Unit {});
}

/// Write the UTF-16 code units of `s` to the start of `out`: the count written. `out.len() >= s.len()`
/// always suffices. On error the units of `out` past the valid prefix are unspecified.
pub const fn encode_into(s: str, out: []mut u16) Result<usize, EncodeError> {
    let mut i: usize = 0;
    let mut k: usize = 0;
    // Each pass consumes at least one byte.
    while i < s.len() {
        let (c, n) = scalar_at(s, i);
        if n == 0 {
            return Err(InvalidUtf8(i));
        }
        if c < 0x10000 {
            if k == out.len() {
                return Err(BufferTooSmall);
            }
            out[k] = c as u16;
            k += 1;
        } else {
            if out.len() - k < 2 {
                return Err(BufferTooSmall);
            }
            out[k] = high_surrogate(c);
            out[k + 1] = low_surrogate(c);
            k += 2;
        }
        i += n;
    }
    return Ok(k);
}

/// Append the UTF-8 form of the UTF-16 code units `units` to `out`. On error `out` keeps its previous
/// contents.
pub fn decode<A: Allocator>(units: []u16, out: &mut String<A>) Result<Unit, DecodeError> {
    let start = out.len();
    out.reserve(units.len());
    let mut i: usize = 0;
    // Each pass consumes one or two units.
    while i < units.len() {
        let u = units[i] as u32;
        if u < 0x80 {
            out.push_byte(u as u8);
            i += 1;
            continue;
        }
        if u < 0xD800 || u > 0xDFFF {
            out.push(u);
            i += 1;
            continue;
        }
        let paired = u <= 0xDBFF && i + 1 < units.len() && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF;
        if !paired {
            out.truncate(start);
            return Err(DecodeError { offset: i });
        }
        out.push(0x10000 + (u - 0xD800 << 10 | units[i + 1] as u32 - 0xDC00));
        i += 2;
    }
    return Ok(Unit {});
}

// The scalar value whose UTF-8 sequence starts at byte `i` of `s`, and the sequence's length: 0 when the
// bytes at `i` are not well-formed (an overlong form, a surrogate, a value above U+10FFFF, a stray
// continuation byte or a truncated sequence). The second byte's range carries the overlong, surrogate and
// U+10FFFF limits; every later byte is a plain continuation.
const fn scalar_at(s: str, i: usize) (u32, usize) {
    let b = s.byte_at(i) as u32;
    if b < 0x80 {
        return (b, 1);
    }
    let mut n: usize = 0;
    let mut lo: u32 = 0x80;
    let mut hi: u32 = 0xBF;
    let mut c: u32 = 0;
    if b >= 0xC2 && b <= 0xDF {
        n = 2;
        c = b & 0x1F;
    } else if b >= 0xE0 && b <= 0xEF {
        n = 3;
        c = b & 0x0F;
        if b == 0xE0 {
            lo = 0xA0;
        } else if b == 0xED {
            hi = 0x9F;
        }
    } else if b >= 0xF0 && b <= 0xF4 {
        n = 4;
        c = b & 0x07;
        if b == 0xF0 {
            lo = 0x90;
        } else if b == 0xF4 {
            hi = 0x8F;
        }
    } else {
        return (0, 0);
    }
    if n > s.len() - i {
        return (0, 0);
    }
    let b1 = s.byte_at(i + 1) as u32;
    if b1 < lo || b1 > hi {
        return (0, 0);
    }
    c = c << 6 | b1 & 0x3F;
    for k in 2..n {
        let bk = s.byte_at(i + k) as u32;
        if (bk & 0xC0) != 0x80 {
            return (0, 0);
        }
        c = c << 6 | bk & 0x3F;
    }
    return (c, n);
}

const fn high_surrogate(c: u32) u16 {
    return (0xD800 | c - 0x10000 >> 10) as u16;
}

const fn low_surrogate(c: u32) u16 {
    return (0xDC00 | c - 0x10000 & 0x3FF) as u16;
}
