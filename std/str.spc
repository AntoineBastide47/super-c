// The `str` module: the borrowed UTF-8 view that is the type of every string literal. This module is
// auto-imported as the prelude, so `str` is in scope unqualified everywhere.
//
// `str` is a non-owning (ptr, len) view: it never allocates, resizes, or mutates the bytes it points
// at, so its whole API returns either sub-views (`str`) or scalar values. Owning/mutating operations
// live on `String`. The `(ptr, len)` fields are PRIVATE -- read them through the `.ptr()` / `.len()`
// accessors, and build a view from raw parts with `str::from_raw(ptr, len)` (the only way to make one).
//
// Borrowed iterators (`bytes`, `chars`, `split`, `lines`) live at the bottom of this module as small
// cursor structs implementing `Iterator`, so `for b in s.bytes() { .. }` works.
// `is_valid_utf8` is structural only: it does not reject overlong encodings or surrogate-range scalars.

extern "C" {
    fn memcmp(a: *const void, b: *const void, n: usize) i32;
}

// A borrowed view over UTF-8 bytes -- the type of a string literal. Non-owning: the bytes outlive it.
pub struct str {
    ptr: *const u8, // start of the bytes
    len: usize, // number of bytes
}

extend str {
    // Construct a view over `len` bytes at `ptr`. The building block for the rest of std and for callers
    // bridging from a raw C buffer -- the fields are private, so this is the only way to make a `str`.
    pub fn from_raw(ptr: *const u8, len: usize) str {
        return str { ptr: ptr, len: len };
    }

    // View a NUL-terminated C string as a `str` (length found by scanning to the NUL). Zero-copy:
    // the returned view borrows `s`. The bridge for callers holding a raw `*const char`.
    pub fn from_cstr(s: *const char) str {
        let mut n: usize = 0;
        while unsafe s[n] != 0 as char {
            n += 1;
        }
        return str::from_raw(s as *const u8, n);
    }

    // --- length & raw access -------------------------------------------------------------------

    // Number of bytes in the view. `s.len()` is the accessor for the private `len` field.
    pub fn len(self: &str) usize {
        return self.len;
    }

    pub fn is_empty(self: &str) bool {
        return self.len == 0;
    }

    // A read-only pointer to the first byte (the view's backing storage; not NUL-terminated).
    pub fn ptr(self: &str) *const u8 {
        return self.ptr;
    }

    // The byte at `index` (0 <= index < len). No bounds check -- the caller owns the index.
    pub fn byte_at(self: &str, index: usize) u8 {
        return unsafe self.ptr[index];
    }

    // The sub-view of bytes [start, end) -- allocation-free, it borrows `self`'s bytes. The caller
    // keeps `start`/`end` on UTF-8 boundaries (and within bounds).
    pub fn slice(self: &str, start: usize, end: usize) str {
        return str { ptr: unsafe (self.ptr + start), len: end - start };
    }

    // --- search --------------------------------------------------------------------------------

    pub fn starts_with(self: &str, prefix: str) bool {
        if prefix.len > self.len {
            return false;
        }
        if prefix.len == 0 {
            return true;
        }
        return unsafe memcmp(self.ptr as *const void, prefix.ptr as *const void, prefix.len) == 0;
    }

    pub fn ends_with(self: &str, suffix: str) bool {
        if suffix.len > self.len {
            return false;
        }
        if suffix.len == 0 {
            return true;
        }
        return unsafe memcmp(
            (unsafe (self.ptr + (self.len - suffix.len))) as *const void,
            suffix.ptr as *const void,
            suffix.len,
        ) == 0;
    }

    // First index of byte `byte`, or -1 if absent.
    pub fn find_byte(self: &str, byte: u8) isize {
        for i in 0..self.len {
            if unsafe self.ptr[i] == byte {
                return i as isize;
            }
        }
        return -1;
    }

    // First byte index where `needle` occurs, or -1 if absent (naive O(n*m) window scan).
    pub fn find(self: &str, needle: str) isize {
        if needle.len == 0 {
            return 0;
        }
        if needle.len > self.len {
            return -1;
        }
        let last = self.len - needle.len;
        for i in 0..=last {
            if unsafe memcmp((unsafe (self.ptr + i)) as *const void, needle.ptr as *const void, needle.len) == 0 {
                return i as isize;
            }
        }
        return -1;
    }

    pub fn contains(self: &str, needle: str) bool {
        return self.find(needle) >= 0;
    }

    // --- trim (returns sub-views; no allocation) -----------------------------------------------

    // The view with leading ASCII whitespace (space, tab, newline, carriage return) removed.
    pub fn trim_start(self: &str) str {
        let mut start: usize = 0;
        while start < self.len {
            let b = unsafe self.ptr[start];
            if b != 32 && b != 9 && b != 10 && b != 13 {
                break;
            }
            start = start + 1;
        }
        return str { ptr: unsafe (self.ptr + start), len: self.len - start };
    }

    // The view with trailing ASCII whitespace removed.
    pub fn trim_end(self: &str) str {
        let mut end = self.len;
        while end > 0 {
            let b = unsafe self.ptr[end - 1];
            if b != 32 && b != 9 && b != 10 && b != 13 {
                break;
            }
            end = end - 1;
        }
        return str { ptr: self.ptr, len: end };
    }

    // The view with ASCII whitespace removed from both ends.
    pub fn trim(self: &str) str {
        let t = self.trim_start();
        return t.trim_end();
    }

    // --- UTF-8 queries -------------------------------------------------------------------------

    // Number of UTF-8 scalar values: every byte that is not a 0b10xxxxxx continuation starts one.
    // (Assumes valid UTF-8; pair with `is_valid_utf8` if the source is untrusted.)
    pub fn char_count(self: &str) usize {
        let mut count: usize = 0;
        for i in 0..self.len {
            if (unsafe self.ptr[i] & 0xC0) != 0x80 {
                count = count + 1;
            }
        }
        return count;
    }

    // True if the bytes are structurally well-formed UTF-8: every leading byte announces a 1-4 byte
    // sequence that fits and whose tail bytes are all 0b10xxxxxx continuations. (Structural only --
    // it does not reject overlong encodings or surrogate-range scalars.)
    pub fn is_valid_utf8(self: &str) bool {
        let mut i: usize = 0;
        while i < self.len {
            let b = unsafe self.ptr[i];
            let mut n: usize = 0;
            if b < 0x80 {
                n = 1;
            } else if (b & 0xE0) == 0xC0 {
                n = 2;
            } else if (b & 0xF0) == 0xE0 {
                n = 3;
            } else if (b & 0xF8) == 0xF0 {
                n = 4;
            } else {
                return false; // 0b10xxxxxx as a leader, or a 5+ byte form
            }
            if i + n > self.len {
                return false;
            }
            for k in 1..n {
                if (unsafe self.ptr[i + k] & 0xC0) != 0x80 {
                    return false;
                }
            }
            i = i + n;
        }
        return true;
    }

    // Allocate an owning String holding a copy of this view's bytes.
    pub fn to_string(self: &str) String {
        let mut out = String::with_capacity(self.len);
        out.push_bytes(self.ptr, self.len);
        return out;
    }
}

// Standard-interface conformances. `eq`/`cmp` take `other: &str` (the `&Self` convention), so `str` works
// behind `T: Eq`/`T: Ord` bounds and the `==`/`<` operators dispatch to it.
extend str as Eq {
    pub fn eq(self: &str, other: &str) bool {
        if self.len != other.len {
            return false;
        }
        if self.len == 0 {
            return true;
        }
        return unsafe memcmp(self.ptr as *const void, other.ptr as *const void, self.len) == 0;
    }
}

extend str as Ord {
    // Lexicographic byte comparison: <0 if self < other, 0 if equal, >0 if self > other. Shorter strings
    // sort before longer ones sharing their prefix.
    pub fn cmp(self: &str, other: &str) i32 {
        let mut n = self.len;
        if other.len < n {
            n = other.len;
        }
        if n > 0 {
            let c = unsafe memcmp(self.ptr as *const void, other.ptr as *const void, n);
            if c != 0 {
                return c;
            }
        }
        if self.len < other.len {
            return -1;
        }
        if self.len > other.len {
            return 1;
        }
        return 0;
    }
}

extend str as Hash {
    // 64-bit FNV-1a over the bytes (matching String::hash, so a `str` and an equal `String` hash alike).
    pub fn hash(self: &str) u64 {
        let mut h: u64 = 0xcbf29ce484222325;
        for i in 0..self.len {
            h = (h ^ unsafe self.ptr[i] as u64) * 0x100000001b3;
        }
        return h;
    }
}

extend str as Default {
    // The empty view (a null, zero-length `str`).
    pub fn default() str {
        return str { ptr: null, len: 0 };
    }
}

// Index conformance: `s[i]` borrows the byte at `i`; `s[lo..hi]` -- any range form, `..=` including the
// end byte, an open end meaning `len()` -- is the sub-view `slice(lo, hi)`. Byte-addressed and unchecked:
// the caller keeps the bounds within `len` and on UTF-8 boundaries, exactly like `byte_at`/`slice`.
// No IndexMut: a `str` is a read-only view.
extend str as Index<u8, str> {
    pub fn index(self: &str, i: usize) &u8 {
        return &unsafe self.ptr[i];
    }
    pub fn index_range(self: &str, r: Range<usize>) str {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        return self.slice(r.start, hi);
    }
}

// --- iterators -----------------------------------------------------------------------------------
// Borrowing cursors over a `str`. Each holds a copy of the (ptr, len) view, so the borrowed bytes must
// outlive the iterator (the same borrowing contract as `Vector::iter`). Bind the source first: iterating a
// TEMPORARY (`for c in make_string().chars() { .. }`) reads freed memory once the temporary is dropped at
// the end of the construction expression -- bind it to a `let` whose scope covers the loop. They live in
// this module (alongside `str`), so no prelude header cycle arises.

pub struct Bytes {
    pub s: str,
    pub i: usize,
}
pub struct Chars {
    pub s: str,
    pub i: usize,
}
pub struct Split {
    pub s: str,
    pub i: usize,
    pub sep: str,
}
pub struct Lines {
    pub s: str,
    pub i: usize,
}

extend str {
    // Iterate the raw bytes (`u8`).
    pub fn bytes(self: &str) Bytes {
        return Bytes { s: self.slice(0, self.len), i: 0 };
    }

    // Iterate Unicode scalar values (`u32` code points), decoding UTF-8. Assumes valid UTF-8; a
    // malformed leading byte yields U+FFFD and advances one byte.
    pub fn chars(self: &str) Chars {
        return Chars { s: self.slice(0, self.len), i: 0 };
    }

    // Iterate the sub-views separated by `sep`. An empty `sep` yields the whole view once; adjacent or
    // edge separators produce empty views.
    pub fn split(self: &str, sep: str) Split {
        return Split { s: self.slice(0, self.len), i: 0, sep: sep };
    }

    // Iterate lines split on '\n', dropping a trailing '\r' (so "\r\n" works). A final newline does not
    // yield a trailing empty line.
    pub fn lines(self: &str) Lines {
        return Lines { s: self.slice(0, self.len), i: 0 };
    }

    // --- string -> number parsing ----------------------------------------------------------------
    // Whole-string parses: the entire view must be `[+|-]digits` (no surrounding whitespace; trim
    // first). Radix forms accept 2..=36 with case-insensitive digits. Empty input, a stray sign,
    // an invalid digit, or overflow all yield `None`.

    pub fn parse_u64_radix(self: &str, radix: u32) Option<u64> {
        let mut start: usize = 0;
        if self.len > 0 && self.byte_at(0) == b'+' {
            start = 1;
        }
        return __str_digits_u64(self, radix, start);
    }

    pub fn parse_i64_radix(self: &str, radix: u32) Option<i64> {
        if self.len == 0 {
            return Option::<i64>::None;
        }
        let b0 = self.byte_at(0);
        let neg = b0 == b'-';
        let mut start: usize = 0;
        if neg || b0 == b'+' {
            start = 1;
        }
        return switch __str_digits_u64(self, radix, start) {
            Some(v) => switch neg {
                // |i64::MIN| = 2^63 is spellable only with the sign; unsigned negate avoids overflow
                true => switch v <= 0x8000_0000_0000_0000u64 {
                    true => Option::<i64>::Some((0 - v) as i64),
                    false => Option::<i64>::None,
                },
                false => switch v <= 0x7FFF_FFFF_FFFF_FFFFu64 {
                    true => Option::<i64>::Some(v as i64),
                    false => Option::<i64>::None,
                },
            },
            None => Option::<i64>::None,
        };
    }

    pub fn parse_u64(self: &str) Option<u64> {
        return self.parse_u64_radix(10);
    }
    pub fn parse_i64(self: &str) Option<i64> {
        return self.parse_i64_radix(10);
    }
    pub fn parse_usize(self: &str) Option<usize> {
        return switch self.parse_u64() {
            Some(v) => Option::<usize>::Some(v as usize),
            None => Option::<usize>::None,
        };
    }
    pub fn parse_isize(self: &str) Option<isize> {
        return switch self.parse_i64() {
            Some(v) => Option::<isize>::Some(v as isize),
            None => Option::<isize>::None,
        };
    }
    pub fn parse_u32(self: &str) Option<u32> {
        return switch self.parse_u64() {
            Some(v) => switch v <= 0xFFFF_FFFFu64 {
                true => Option::<u32>::Some(v as u32),
                false => Option::<u32>::None,
            },
            None => Option::<u32>::None,
        };
    }
    pub fn parse_u16(self: &str) Option<u16> {
        return switch self.parse_u64() {
            Some(v) => switch v <= 65535 {
                true => Option::<u16>::Some(v as u16),
                false => Option::<u16>::None,
            },
            None => Option::<u16>::None,
        };
    }
    pub fn parse_u8(self: &str) Option<u8> {
        return switch self.parse_u64() {
            Some(v) => switch v <= 255 {
                true => Option::<u8>::Some(v as u8),
                false => Option::<u8>::None,
            },
            None => Option::<u8>::None,
        };
    }
    pub fn parse_i32(self: &str) Option<i32> {
        return switch self.parse_i64() {
            Some(v) => switch v >= -2_147_483_648 && v <= 2_147_483_647 {
                true => Option::<i32>::Some(v as i32),
                false => Option::<i32>::None,
            },
            None => Option::<i32>::None,
        };
    }
    pub fn parse_i16(self: &str) Option<i16> {
        return switch self.parse_i64() {
            Some(v) => switch v >= -32_768 && v <= 32_767 {
                true => Option::<i16>::Some(v as i16),
                false => Option::<i16>::None,
            },
            None => Option::<i16>::None,
        };
    }
    pub fn parse_i8(self: &str) Option<i8> {
        return switch self.parse_i64() {
            Some(v) => switch v >= -128 && v <= 127 {
                true => Option::<i8>::Some(v as i8),
                false => Option::<i8>::None,
            },
            None => Option::<i8>::None,
        };
    }

    // Decimal float: `[+|-] digits [. digits] [(e|E) [+|-] digits]`. Computed as an integer mantissa
    // scaled by a power of ten -- exact for the common cases; the last ulp is not guaranteed for
    // extreme magnitudes.
    pub fn parse_f64(self: &str) Option<f64> {
        let n = self.len;
        if n == 0 {
            return Option::<f64>::None;
        }
        let mut i: usize = 0;
        let b0 = self.byte_at(0);
        let neg = b0 == b'-';
        if neg || b0 == b'+' {
            i = 1;
        }
        let mut mant: u64 = 0;
        let mut exp10: i64 = 0;
        let mut any = false;
        while i < n {
            let b = self.byte_at(i);
            if b < b'0' || b > b'9' {
                break;
            }
            any = true;
            if mant <= 1_844_674_407_370_955_160u64 {
                mant = mant * 10 + (b - b'0') as u64;
            } else {
                exp10 += 1; // mantissa saturated: keep the scale, drop precision
            }
            i += 1;
        }
        if i < n && self.byte_at(i) == b'.' {
            i += 1;
            while i < n {
                let b = self.byte_at(i);
                if b < b'0' || b > b'9' {
                    break;
                }
                any = true;
                if mant <= 1_844_674_407_370_955_160u64 {
                    mant = mant * 10 + (b - b'0') as u64;
                    exp10 -= 1;
                }
                i += 1;
            }
        }
        if !any {
            return Option::<f64>::None;
        }
        if i < n && (self.byte_at(i) == b'e' || self.byte_at(i) == b'E') {
            i += 1;
            let mut eneg = false;
            if i < n && (self.byte_at(i) == b'+' || self.byte_at(i) == b'-') {
                eneg = self.byte_at(i) == b'-';
                i += 1;
            }
            let mut e: i64 = 0;
            let mut eany = false;
            while i < n {
                let b = self.byte_at(i);
                if b < b'0' || b > b'9' {
                    break;
                }
                eany = true;
                if e < 10_000 {
                    e = e * 10 + (b - b'0') as i64;
                }
                i += 1;
            }
            if !eany {
                return Option::<f64>::None;
            }
            exp10 += (switch eneg {
                true => 0 - e,
                false => e,
            });
        }
        if i != n {
            return Option::<f64>::None;
        }
        let mut v = mant as f64;
        let mut e = exp10;
        while e > 0 {
            v = v * 10.0;
            e -= 1;
        }
        while e < 0 {
            v = v / 10.0;
            e += 1;
        }
        if neg {
            v = 0.0 - v;
        }
        return Option::<f64>::Some(v);
    }

    pub fn parse_f32(self: &str) Option<f32> {
        return switch self.parse_f64() {
            Some(v) => Option::<f32>::Some(v as f32),
            None => Option::<f32>::None,
        };
    }
}

// Digits of `s` in `[start, s.len)` in `radix`, all consumed exactly.
// `None` on radix outside 2..=36, empty digit run, an invalid digit, or u64 overflow.
fn __str_digits_u64(s: &str, radix: u32, start: usize) Option<u64> {
    if radix < 2 || radix > 36 || start >= s.len() {
        return Option::<u64>::None;
    }
    let r = radix as u64;
    let mut acc: u64 = 0;
    let mut i = start;
    while i < s.len() {
        let b = s.byte_at(i);
        let mut d: u32 = 99;
        if b >= b'0' && b <= b'9' {
            d = (b - b'0') as u32;
        } else if b >= b'a' && b <= b'z' {
            d = (b - b'a') as u32 + 10;
        } else if b >= b'A' && b <= b'Z' {
            d = (b - b'A') as u32 + 10;
        }
        if d >= radix {
            return Option::<u64>::None;
        }
        let dv = d as u64;
        if acc > (0xFFFF_FFFF_FFFF_FFFFu64 - dv) / r {
            return Option::<u64>::None; // would overflow u64
        }
        acc = acc * r + dv;
        i += 1;
    }
    return Option::<u64>::Some(acc);
}

extend Bytes as Iterator<u8> {
    pub fn next(self: &mut Bytes) Option<u8> {
        if self.i >= self.s.len() {
            return Option::<u8>::None;
        }
        let b = self.s.byte_at(self.i);
        self.i = self.i + 1;
        return Option::<u8>::Some(b);
    }
}

extend Chars as Iterator<u32> {
    pub fn next(self: &mut Chars) Option<u32> {
        if self.i >= self.s.len() {
            return Option::<u32>::None;
        }
        let b0 = self.s.byte_at(self.i);
        let mut cp: u32 = 0;
        let mut n: usize = 1;
        if b0 < 0x80 {
            cp = b0 as u32;
            n = 1;
        } else if (b0 & 0xE0) == 0xC0 {
            cp = (b0 & 0x1F) as u32;
            n = 2;
        } else if (b0 & 0xF0) == 0xE0 {
            cp = (b0 & 0x0F) as u32;
            n = 3;
        } else if (b0 & 0xF8) == 0xF0 {
            cp = (b0 & 0x07) as u32;
            n = 4;
        } else {
            self.i = self.i + 1;
            return Option::<u32>::Some(0xFFFD); // a continuation byte or 5+ byte leader: not a valid start
        }
        if self.i + n > self.s.len() {
            self.i = self.i + 1; // truncated sequence at the end of the view
            return Option::<u32>::Some(0xFFFD);
        }
        let mut k: usize = 1;
        while k < n {
            let cb = self.s.byte_at(self.i + k);
            if (cb & 0xC0) != 0x80 {
                // a non-continuation byte where one is required -> malformed
                self.i = self.i + 1;
                return Option::<u32>::Some(0xFFFD);
            }
            cp = cp << 6 | (cb & 0x3F) as u32;
            k = k + 1;
        }
        self.i = self.i + n;
        return Option::<u32>::Some(cp);
    }
}

extend Split as Iterator<str> {
    pub fn next(self: &mut Split) Option<str> {
        if self.i > self.s.len() {
            return Option::<str>::None;
        }
        if self.sep.len() == 0 {
            let whole = self.s.slice(self.i, self.s.len());
            self.i = self.s.len() + 1;
            return Option::<str>::Some(whole);
        }
        let rest = self.s.slice(self.i, self.s.len());
        let pos = rest.find(self.sep);
        if pos < 0 {
            let tail = self.s.slice(self.i, self.s.len());
            self.i = self.s.len() + 1;
            return Option::<str>::Some(tail);
        }
        let j = self.i + pos as usize;
        let piece = self.s.slice(self.i, j);
        self.i = j + self.sep.len();
        return Option::<str>::Some(piece);
    }
}

extend Lines as Iterator<str> {
    pub fn next(self: &mut Lines) Option<str> {
        if self.i >= self.s.len() {
            return Option::<str>::None;
        }
        let start = self.i;
        let mut j = self.i;
        while j < self.s.len() && self.s.byte_at(j) != 10 {
            j = j + 1;
        }
        let mut end = j;
        if end > start && self.s.byte_at(end - 1) == 13 {
            end = end - 1;
        }
        let piece = self.s.slice(start, end);
        self.i = j + 1;
        return Option::<str>::Some(piece);
    }
}
