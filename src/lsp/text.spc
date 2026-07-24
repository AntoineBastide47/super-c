// Text position mapping and URI conversion for the LSP. The compiler speaks byte offsets; LSP positions
// are (line, character) with character counted in UTF-16 code units -- the walk below converts between
// them (1 unit for BMP scalars, 2 for the 4-byte astral plane).

/// An LSP position: 0-based line, `character` counted in UTF-16 code units (not bytes).
pub struct Pos {
    pub line: u32,
    pub character: u32,
}

/// Byte offset of each line start (line 0 starts at 0; a new line after every '\n').
pub fn line_starts(src: str) Vector<u32> {
    let mut ls = Vector::<u32>::new();
    ls.push(0);
    for i in 0..src.len() {
        if src[i] == b'\n' {
            ls.push((i + 1) as u32);
        }
    }
    return ls;
}

/// UTF-16 code units in src[start..end] (clamped to the source).
pub fn utf16_len(src: str, start: u32, end: u32) u32 {
    let mut e = end as usize;
    if e > src.len() {
        e = src.len();
    }
    let mut n: u32 = 0;
    let mut i = start as usize;
    while i < e {
        let b = src[i];
        if b < 0x80 {
            n += 1;
            i += 1;
        } else if b < 0xC0 {
            i += 1; // stray continuation byte: zero width
        } else if b < 0xE0 {
            n += 1;
            i += 2;
        } else if b < 0xF0 {
            n += 1;
            i += 3;
        } else {
            n += 2; // astral plane: a UTF-16 surrogate pair
            i += 4;
        }
    }
    return n;
}

/// Byte offset -> LSP position (clamped to the source end).
pub fn offset_to_pos(src: str, ls: &Vector<u32>, off: u32) Pos {
    let mut o = off;
    if o as usize > src.len() {
        o = src.len() as u32;
    }
    // largest line start <= o (ls is never empty: line 0 is always pushed)
    let mut lo: usize = 0;
    let mut hi = ls.len();
    while hi - lo > 1 {
        let mid = lo + (hi - lo) / 2;
        if *ls.at(mid) <= o {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return Pos { line: lo as u32, character: utf16_len(src, *ls.at(lo), o) };
}

/// LSP position -> byte offset. Clamps: an out-of-range line maps to the last line start, an
/// out-of-range character to the line end. A character landing inside a surrogate pair stops before it.
pub fn pos_to_offset(src: str, ls: &Vector<u32>, line: u32, character: u32) u32 {
    let mut li = line as usize;
    if li >= ls.len() {
        li = ls.len() - 1;
    }
    let mut i = (*ls.at(li)) as usize;
    let mut left = character;
    while left > 0 && i < src.len() {
        let b = src[i];
        if b == b'\n' || b == b'\r' {
            break;
        }
        if b < 0x80 {
            i += 1;
            left -= 1;
        } else if b < 0xC0 {
            i += 1;
        } else if b < 0xE0 {
            i += 2;
            left -= 1;
        } else if b < 0xF0 {
            i += 3;
            left -= 1;
        } else {
            if left < 2 {
                break;
            }
            i += 4;
            left -= 2;
        }
    }
    if i > src.len() {
        i = src.len();
    }
    return i as u32;
}

const fn hex_val(b: u8) i32 {
    if b >= b'0' && b <= b'9' {
        return b - b'0';
    }
    if b >= b'a' && b <= b'f' {
        return (b - b'a') as i32 + 10;
    }
    if b >= b'A' && b <= b'F' {
        return (b - b'A') as i32 + 10;
    }
    return -1;
}

/// file:// URI -> filesystem path (strips the scheme + authority, percent-decodes).
pub fn uri_to_path(uri: str) String {
    let mut out = String::with_capacity(uri.len());
    let mut i: usize = 0;
    if uri.starts_with("file://") {
        i = 7;
        // skip the (usually empty) authority up to the path's leading '/'
        while i < uri.len() && uri[i] != b'/' {
            i += 1;
        }
    }
    while i < uri.len() {
        let b = uri[i];
        if b == b'%' && i + 2 < uri.len() {
            let h = hex_val(uri[i + 1]);
            let l = hex_val(uri[i + 2]);
            if h >= 0 && l >= 0 {
                out.push_byte((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push_byte(b);
        i += 1;
    }
    return out;
}

/// Absolute filesystem path -> file:// URI (unreserved bytes kept, the rest percent-encoded).
pub fn path_to_uri(path: str) String {
    let mut out = String::with_capacity(path.len() + 8);
    out.push_str("file://");
    for i in 0..path.len() {
        let b = path[i];
        let keep = b >= b'a' && b <= b'z' || b >= b'A' && b <= b'Z' || b >= b'0' && b <= b'9' || b == b'/' || b == b'-' || b == b'.' || b == b'_' || b == b'~';
        if keep {
            out.push_byte(b);
        } else {
            out.push_byte(b'%');
            out.push_byte("0123456789ABCDEF"[(b >> 4) as usize]);
            out.push_byte("0123456789ABCDEF"[(b & 15) as usize]);
        }
    }
    return out;
}
