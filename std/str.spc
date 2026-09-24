// The `str` module: the borrowed UTF-8 view that is the type of every string literal. This module is
// auto-imported as the prelude, so `str` is in scope unqualified everywhere.
//
// `str` is a non-owning (ptr, len) view: it never allocates, resizes, or mutates the bytes it points
// at, so its whole API returns either sub-views (`str`) or scalar values. Owning/mutating operations
// live on `String`. The `(ptr, len)` fields are PRIVATE: read them through the `.ptr()` / `.len()`
// accessors, and build a view from raw parts with `str::from_raw(ptr, len)` (the only way to make one).
//
// Borrowed iterators (`bytes`, `chars`, `split`, `lines`) live at the bottom of this module as small
// cursor structs implementing `Iterator`, so `for b in s.bytes() { .. }` works.
// `is_valid_utf8` is structural only: it does not reject overlong encodings or surrogate-range scalars.

extern "C" {
    fn memcmp(a: *const void, b: *const void, n: usize) i32;
}

/// A borrowed view over UTF-8 bytes: the type of a string literal. Non-owning: the bytes outlive it.
pub struct str<'a> {
    ptr: *const u8, // start of the bytes
    len: usize, // number of bytes
}

extend str {
    /// Construct a view over `len` bytes at `ptr`. The building block for the rest of std and for callers
    /// bridging from a raw C buffer: the fields are private, so this is the only way to make a `str`.
    pub const fn from_raw<'a>(ptr: *const u8, len: usize) str<'a> {
        return str { ptr: ptr, len: len };
    }

    /// View a NUL-terminated C string as a `str` (length found by scanning to the NUL). Zero-copy:
    /// the returned view borrows `s`. The bridge for callers holding a raw `*const char`.
    pub const fn from_cstr<'a>(s: *const char) str<'a> {
        let mut n: usize = 0;
        while unsafe s[n] != 0 as char {
            n += 1;
        }
        return str::from_raw(s as *const u8, n);
    }

    // --- length & raw access -------------------------------------------------------------------.

    /// Number of bytes in the view. `s.len()` is the accessor for the private `len` field.
    pub const fn len(self: &str) usize {
        return self.len;
    }

    /// True when the view has no bytes.
    pub const fn is_empty(self: &str) bool {
        return self.len == 0;
    }

    /// A read-only pointer to the first byte (the view's backing storage; not NUL-terminated).
    pub const fn ptr(self: &str) *const u8 {
        return self.ptr;
    }

    /// The byte at `index`. Panics unless `index < len`.
    pub const fn byte_at(self: &str, index: usize) u8 {
        if index >= self.len {
            panic("str::byte_at: index out of bounds");
        }
        return unsafe self.ptr[index];
    }

    /// The sub-view of bytes [start, end): allocation-free, it borrows `self`'s bytes. Panics unless
    /// `start <= end <= len`; the caller keeps `start`/`end` on UTF-8 boundaries.
    pub const fn slice(self: &str, start: usize, end: usize) str {
        if start > end || end > self.len {
            panic("str::slice: range out of bounds");
        }
        return str { ptr: unsafe (self.ptr + start), len: end - start };
    }

    // --- search --------------------------------------------------------------------------------.

    /// True when the bytes begin with `prefix`.
    pub const fn starts_with(self: &str, prefix: str) bool {
        if prefix.len > self.len {
            return false;
        }
        if prefix.len == 0 {
            return true;
        }
        return unsafe memcmp(self.ptr, prefix.ptr, prefix.len) == 0;
    }

    /// True when the bytes end with `suffix`.
    pub const fn ends_with(self: &str, suffix: str) bool {
        if suffix.len > self.len {
            return false;
        }
        if suffix.len == 0 {
            return true;
        }
        return unsafe memcmp(unsafe (self.ptr + (self.len - suffix.len)), suffix.ptr, suffix.len) == 0;
    }

    /// First index of byte `byte`, or -1 if absent.
    pub const fn find_byte(self: &str, byte: u8) isize {
        for i in 0..self.len {
            if unsafe self.ptr[i] == byte {
                return i as isize;
            }
        }
        return -1;
    }

    /// First byte index where `needle` occurs, or -1 if absent (naive O(n*m) window scan).
    pub const fn find(self: &str, needle: str) isize {
        if needle.len == 0 {
            return 0;
        }
        if needle.len > self.len {
            return -1;
        }
        let last = self.len - needle.len;
        for i in 0..=last {
            if unsafe memcmp(unsafe (self.ptr + i), needle.ptr, needle.len) == 0 {
                return i as isize;
            }
        }
        return -1;
    }

    /// True when `needle` occurs as a substring.
    pub const fn contains(self: &str, needle: str) bool {
        return self.find(needle) >= 0;
    }

    // --- trim (returns sub-views; no allocation) -----------------------------------------------.

    /// The view with leading ASCII whitespace (space, tab, newline, carriage return) removed.
    pub const fn trim_start(self: &str) str {
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

    /// The view with trailing ASCII whitespace removed.
    pub const fn trim_end(self: &str) str {
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

    /// The view with ASCII whitespace removed from both ends.
    pub const fn trim(self: &str) str {
        let t = self.trim_start();
        return t.trim_end();
    }

    // --- UTF-8 queries -------------------------------------------------------------------------.

    /// Number of UTF-8 scalar values: every byte that is not a 0b10xxxxxx continuation starts one.
    /// (Assumes valid UTF-8; pair with `is_valid_utf8` if the source is untrusted.)
    pub const fn char_count(self: &str) usize {
        let mut count: usize = 0;
        for i in 0..self.len {
            if (unsafe self.ptr[i] & 0xC0) != 0x80 {
                count = count + 1;
            }
        }
        return count;
    }

    /// True if the bytes are structurally well-formed UTF-8: every leading byte announces a 1-4 byte
    /// sequence that fits and whose tail bytes are all 0b10xxxxxx continuations. (Structural only:
    /// it does not reject overlong encodings or surrogate-range scalars.)
    pub const fn is_valid_utf8(self: &str) bool {
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
                // 0b10xxxxxx as a leader, or a 5+ byte form.
                return false;
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

    /// Allocate an owning String holding a copy of this view's bytes.
    pub fn to_string(self: &str) String {
        let mut out = String::with_capacity(self.len);
        out.push_bytes(self.ptr, self.len);
        return out;
    }
}

// Standard-interface conformances. `eq`/`cmp` take `other: &str` (the `&Self` convention), so `str` works
// behind `T: Eq`/`T: Ord` bounds and the `==`/`<` operators dispatch to it.
extend str as Eq {
    pub const fn eq(self: &str, other: &str) bool {
        if self.len != other.len {
            return false;
        }
        if self.len == 0 {
            return true;
        }
        return unsafe memcmp(self.ptr, other.ptr, self.len) == 0;
    }
}

extend str as Ord {
    /// Lexicographic byte comparison: <0 if self < other, 0 if equal, >0 if self > other. Shorter strings
    /// sort before longer ones sharing their prefix.
    pub const fn cmp(self: &str, other: &str) i32 {
        let mut n = self.len;
        if other.len < n {
            n = other.len;
        }
        if n > 0 {
            let c = unsafe memcmp(self.ptr, other.ptr, n);
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
    /// 64-bit FNV-1a over the bytes (matching String::hash, so a `str` and an equal `String` hash alike).
    pub const fn hash(self: &str) u64 {
        let mut h: u64 = 0xcbf29ce484222325;
        for i in 0..self.len {
            h = (h ^ (unsafe self.ptr[i]) as u64) * 0x100000001b3;
        }
        return h;
    }
}

extend str as Default {
    /// The empty view (a null, zero-length `str`).
    pub const fn default() str<'static> {
        return str { ptr: null, len: 0 };
    }
}

// Index conformance: `s[i]` borrows the byte at `i`; `s[lo..hi]`; any range form, `..=` including the
// end byte, an open end meaning `len()`: is the sub-view `slice(lo, hi)`. Byte-addressed: bounds past
// `len` panic, and the caller keeps them on UTF-8 boundaries, exactly like `byte_at`/`slice`.
// No IndexMut: a `str` is a read-only view.
extend str as Index<u8, str> {
    pub const fn index(self: &str, i: usize) &u8 {
        if i >= self.len() {
            panic("str[i]: index out of bounds");
        }
        return &unsafe self.ptr[i];
    }
    pub const fn index_range(self: &str, r: Range<usize>) str {
        if r.inclusive && r.end >= self.len() {
            panic("str[a..b]: range out of bounds");
        }
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > self.len() {
            panic("str[a..b]: range out of bounds");
        }
        return self.slice(r.start, hi);
    }
}

// --- iterators -----------------------------------------------------------------------------------
// Borrowing cursors over a `str`. Each holds a copy of the (ptr, len) view, so the borrowed bytes must
// outlive the iterator (the same borrowing contract as `Vector::iter`). Bind the source first: iterating a
// TEMPORARY (`for c in make_string().chars() { .. }`) reads freed memory once the temporary is dropped at
// the end of the construction expression: bind it to a `let` whose scope covers the loop. They live in
// this module (alongside `str`), so no prelude header cycle arises.

/// Iterator over the bytes of a `str`.
pub struct Bytes<'a> {
    pub s: str<'a>,
    pub i: usize,
}
/// Iterator over the Unicode scalars of a `str` (assumes valid UTF-8).
pub struct Chars<'a> {
    pub s: str<'a>,
    pub i: usize,
}
/// Iterator over the pieces of a `str` between occurrences of a separator; an empty input yields one
/// empty piece.
pub struct Split<'a> {
    pub s: str<'a>,
    pub i: usize,
    pub sep: str<'a>,
}
/// Iterator over the lines of a `str` without their terminators (`\n` or `\r\n`).
pub struct Lines<'a> {
    pub s: str<'a>,
    pub i: usize,
}

extend str {
    /// Iterate the raw bytes (`u8`).
    pub const fn bytes(self: &str) Bytes {
        return Bytes { s: self.slice(0, self.len), i: 0 };
    }

    /// Iterate Unicode scalar values (`u32` code points), decoding UTF-8. Assumes valid UTF-8; a
    /// malformed leading byte yields U+FFFD and advances one byte.
    pub const fn chars(self: &str) Chars {
        return Chars { s: self.slice(0, self.len), i: 0 };
    }

    /// Iterate the sub-views separated by `sep`. An empty `sep` yields the whole view once; adjacent or
    /// edge separators produce empty views.
    pub const fn split(self: &str, sep: str) Split {
        return Split { s: self.slice(0, self.len), i: 0, sep: sep };
    }

    /// Iterate lines split on '\n', dropping a trailing '\r' (so "\r\n" works). A final newline does not
    /// yield a trailing empty line.
    pub const fn lines(self: &str) Lines {
        return Lines { s: self.slice(0, self.len), i: 0 };
    }

    // --- string -> number parsing ----------------------------------------------------------------
    // Whole-string parses: the entire view must be `[+|-]digits` (no surrounding whitespace; trim
    // first). Radix forms accept 2..=36 with case-insensitive digits. Empty input, a stray sign,
    // an invalid digit, or overflow all yield `None`.

    /// Parse an unsigned integer in `radix` (2..=36) with an optional leading `+`; None on an empty string,
    /// a bad digit, or overflow.
    pub const fn parse_u64_radix(self: &str, radix: u32) Option<u64> {
        let mut start: usize = 0;
        if self.len > 0 && self.byte_at(0) == b'+' {
            start = 1;
        }
        return __str_digits_u64(self, radix, start);
    }

    /// Parse a signed integer in `radix` (2..=36) with an optional sign; None on an empty string, a bad
    /// digit, or overflow.
    pub const fn parse_i64_radix(self: &str, radix: u32) Option<i64> {
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
                // |i64::MIN| = 2^63 is spellable only with the sign; unsigned negate avoids overflow.
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

    /// `parse_u64_radix(10)`.
    pub const fn parse_u64(self: &str) Option<u64> {
        return self.parse_u64_radix(10);
    }
    /// `parse_i64_radix(10)`.
    pub const fn parse_i64(self: &str) Option<i64> {
        return self.parse_i64_radix(10);
    }
    /// Decimal parse into usize; None on overflow for the target width.
    pub const fn parse_usize(self: &str) Option<usize> {
        return switch self.parse_u64() {
            Some(v) => Option::<usize>::Some(v as usize),
            None => Option::<usize>::None,
        };
    }
    /// Decimal parse into isize; None on overflow for the target width.
    pub const fn parse_isize(self: &str) Option<isize> {
        return switch self.parse_i64() {
            Some(v) => Option::<isize>::Some(v as isize),
            None => Option::<isize>::None,
        };
    }
    /// Decimal parse; None when the value does not fit.
    pub const fn parse_u32(self: &str) Option<u32> {
        return switch self.parse_u64() {
            Some(v) => switch v <= 0xFFFF_FFFFu64 {
                true => Option::<u32>::Some(v as u32),
                false => Option::<u32>::None,
            },
            None => Option::<u32>::None,
        };
    }
    /// Decimal parse; None when the value does not fit.
    pub const fn parse_u16(self: &str) Option<u16> {
        return switch self.parse_u64() {
            Some(v) => switch v <= 65535 {
                true => Option::<u16>::Some(v as u16),
                false => Option::<u16>::None,
            },
            None => Option::<u16>::None,
        };
    }
    /// Decimal parse; None when the value does not fit.
    pub const fn parse_u8(self: &str) Option<u8> {
        return switch self.parse_u64() {
            Some(v) => switch v <= 255 {
                true => Option::<u8>::Some(v as u8),
                false => Option::<u8>::None,
            },
            None => Option::<u8>::None,
        };
    }
    /// Decimal parse; None when the value does not fit.
    pub const fn parse_i32(self: &str) Option<i32> {
        return switch self.parse_i64() {
            Some(v) => switch v >= -2_147_483_648 && v <= 2_147_483_647 {
                true => Option::<i32>::Some(v as i32),
                false => Option::<i32>::None,
            },
            None => Option::<i32>::None,
        };
    }
    /// Decimal parse; None when the value does not fit.
    pub const fn parse_i16(self: &str) Option<i16> {
        return switch self.parse_i64() {
            Some(v) => switch v >= -32_768 && v <= 32_767 {
                true => Option::<i16>::Some(v as i16),
                false => Option::<i16>::None,
            },
            None => Option::<i16>::None,
        };
    }
    /// Decimal parse; None when the value does not fit.
    pub const fn parse_i8(self: &str) Option<i8> {
        return switch self.parse_i64() {
            Some(v) => switch v >= -128 && v <= 127 {
                true => Option::<i8>::Some(v as i8),
                false => Option::<i8>::None,
            },
            None => Option::<i8>::None,
        };
    }

    /// Decimal float: `[+|-] digits [. digits] [(e|E) [+|-] digits]`, correctly rounded (to nearest,
    /// ties to even), so it agrees with the C compiler's reading of the same literal. Up to 19
    /// significant digits and a power of ten within 10^22 take one exact IEEE operation; anything else
    /// takes exact decimal arithmetic (`DecDigits`).
    pub const fn parse_f64(self: &str) Option<f64> {
        let mut dec = DecDigits { d: Array::<u8, 800>::new(), nd: 0, dp: 0, trunc: false };
        let mut neg = false;
        if !self.parse_decimal(&mut dec, &mut neg) {
            return Option::<f64>::None;
        }
        let mut v: f64 = 0.0;
        let mut exact = false;
        if dec.nd <= 19 {
            let mut mant: u64 = 0;
            for k in 0..dec.nd {
                mant = mant * 10 + dec.d[k] as u64;
            }
            let e10 = dec.dp - dec.nd as i64;
            if mant <= 1u64 << 53 && e10 >= -22 && e10 <= 22 {
                // Both operands are exact (every power of ten up to 10^22 is a double), so the one
                // multiply or divide is the only rounding.
                let mut p: f64 = 1.0;
                let mut k: i64 = 0;
                while k < e10 || k < 0 - e10 {
                    p = p * 10.0;
                    k += 1;
                }
                v = if e10 < 0 {
                    mant as f64 / p;
                } else {
                    mant as f64 * p;
                };
                exact = true;
            }
        }
        if !exact {
            v = StrF64Bits { u: dec.to_bits(52, 11) }.f;
        }
        if neg {
            v = -v;
        }
        return Option::<f64>::Some(v);
    }

    /// The f32 twin of `parse_f64`, rounded once from the decimal text (a detour through f64 would
    /// round twice).
    pub const fn parse_f32(self: &str) Option<f32> {
        let mut dec = DecDigits { d: Array::<u8, 800>::new(), nd: 0, dp: 0, trunc: false };
        let mut neg = false;
        if !self.parse_decimal(&mut dec, &mut neg) {
            return Option::<f32>::None;
        }
        let mut v: f32 = 0.0;
        let mut exact = false;
        if dec.nd <= 19 {
            let mut mant: u64 = 0;
            for k in 0..dec.nd {
                mant = mant * 10 + dec.d[k] as u64;
            }
            let e10 = dec.dp - dec.nd as i64;
            if mant <= 1u64 << 24 && e10 >= -10 && e10 <= 10 {
                // Every power of ten up to 10^10 is exact in f32.
                let mut p: f32 = 1.0;
                let mut k: i64 = 0;
                while k < e10 || k < 0 - e10 {
                    p = p * 10.0;
                    k += 1;
                }
                v = if e10 < 0 {
                    mant as f32 / p;
                } else {
                    mant as f32 * p;
                };
                exact = true;
            }
        }
        if !exact {
            v = StrF32Bits { u: dec.to_bits(23, 8) as u32 }.f;
        }
        if neg {
            v = -v;
        }
        return Option::<f32>::Some(v);
    }

    // The float grammar of `parse_f64` read into `dec` (trailing zeros trimmed) and `neg`; false when the
    // text does not match it.
    const fn parse_decimal(self: &str, dec: &mut DecDigits, neg: &mut bool) bool {
        let n = self.len;
        if n == 0 {
            return false;
        }
        let mut i: usize = 0;
        let b0 = self.byte_at(0);
        *neg = b0 == b'-';
        if *neg || b0 == b'+' {
            i = 1;
        }
        let mut any = false;
        let mut seen_dot = false;
        while i < n {
            let b = self.byte_at(i);
            if b == b'.' && !seen_dot {
                seen_dot = true;
                dec.dp = dec.nd as i64;
                i += 1;
                continue;
            }
            if b < b'0' || b > b'9' {
                break;
            }
            any = true;
            if b == b'0' && dec.nd == 0 {
                // A leading zero only moves the point (it matters after the dot).
                dec.dp -= 1;
            } else if dec.nd < DEC_DIGITS {
                dec.d[dec.nd] = b - b'0';
                dec.nd += 1;
            } else if b != b'0' {
                dec.trunc = true;
            }
            i += 1;
        }
        if !any {
            return false;
        }
        if !seen_dot {
            dec.dp = dec.nd as i64;
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
                return false;
            }
            if eneg {
                dec.dp -= e;
            } else {
                dec.dp += e;
            }
        }
        if i != n {
            return false;
        }
        dec.trim();
        return true;
    }
}

union StrF64Bits {
    pub u: u64,
    pub f: f64,
}

union StrF32Bits {
    pub u: u32,
    pub f: f32,
}

// Digits kept exactly by the decimal slow path. 800 covers every digit that can decide the rounding of
// an f64 (the longest exact binary fraction has 767 significant digits); digits past it only set `trunc`,
// which still settles an apparent tie upward.
const DEC_DIGITS: usize = 800;

// For a decimal point at dp (value below 10^dp), a power of two that keeps the value at least 1/2 after
// dividing by it (from Go's strconv, like the algorithm below).
const DEC_POW2: [i64; 9] = [1, 3, 6, 9, 13, 16, 19, 23, 26];

// Exact decimal arithmetic for correctly rounded float parsing: the simple decimal conversion algorithm
// of Go's strconv. The value is 0.d[0]d[1]..d[nd-1] * 10^dp with digit values 0..=9 and no leading or
// trailing zero digit; nd == 0 is zero. It is scaled by exact powers of two into [1/2, 1), then shifted
// by the significand width, and the integer part is rounded to nearest even.
// (Fields `pub` only so the parser methods on `str` reach them; the type itself is module-private.)
struct DecDigits {
    pub d: Array<u8, 800>,
    pub nd: usize,
    pub dp: i64,
    pub trunc: bool, // nonzero digits were dropped past DEC_DIGITS
}

extend DecDigits {
    const fn trim(self: &mut DecDigits) {
        while self.nd > 0 && self.d[self.nd - 1] == 0 {
            self.nd -= 1;
        }
        if self.nd == 0 {
            self.dp = 0;
        }
    }

    // Divide by 2^k, 1 <= k <= 60 (so n * 10 below stays within 64 bits). Requires a nonzero value.
    const fn shr(self: &mut DecDigits, k: u64) {
        let mut r: usize = 0;
        let mut w: usize = 0;
        let mut n: u64 = 0;
        // Enough leading digits to produce the first output digit.
        while n >> k == 0 {
            if r >= self.nd {
                while n >> k == 0 {
                    n = n * 10;
                    r += 1;
                }
                break;
            }
            n = n * 10 + self.d[r] as u64;
            r += 1;
        }
        self.dp -= r as i64 - 1;
        let mask = (1u64 << k) - 1;
        while r < self.nd {
            let c = self.d[r] as u64;
            self.d[w] = (n >> k) as u8;
            w += 1;
            n = (n & mask) * 10 + c;
            r += 1;
        }
        while n > 0 {
            let dig = n >> k;
            n = n & mask;
            if w < DEC_DIGITS {
                self.d[w] = dig as u8;
                w += 1;
            } else if dig > 0 {
                self.trunc = true;
            }
            n = n * 10;
        }
        self.nd = w;
        self.trim();
    }

    // Multiply by 2^k, 1 <= k <= 60: the carry stays below 2^60, so n stays within 64 bits. The product
    // is written least significant digit first from the end of `out` (at most 19 digits longer).
    const fn shl(self: &mut DecDigits, k: u64) {
        let mut out = Array::<u8, 820>::new();
        let mut w: usize = 820;
        let mut n: u64 = 0;
        let mut r = self.nd;
        while r > 0 {
            r -= 1;
            n = n + (self.d[r] as u64 << k);
            w -= 1;
            out[w] = (n % 10) as u8;
            n = n / 10;
        }
        while n > 0 {
            w -= 1;
            out[w] = (n % 10) as u8;
            n = n / 10;
        }
        let cnt = 820 - w;
        self.dp += (cnt - self.nd) as i64;
        let mut keep = cnt;
        if keep > DEC_DIGITS {
            keep = DEC_DIGITS;
        }
        for j in 0..cnt {
            if j < keep {
                self.d[j] = out[w + j];
            } else if out[w + j] != 0 {
                self.trunc = true;
            }
        }
        self.nd = keep;
        self.trim();
    }

    // Multiply by 2^k (k > 0) or divide by 2^-k (k < 0), in steps of at most 60 bits.
    const fn shift(self: &mut DecDigits, k: i64) {
        if self.nd == 0 {
            return;
        }
        let mut kk = k;
        while kk > 60 {
            self.shl(60);
            kk -= 60;
        }
        while kk < -60 {
            self.shr(60);
            kk += 60;
        }
        if kk > 0 {
            self.shl(kk as u64);
        } else if kk < 0 {
            self.shr((0 - kk) as u64);
        }
    }

    // Whether cutting the digits at index i rounds up: past the half, or exactly at it with an odd digit
    // before the cut or dropped nonzero digits after it.
    const fn round_up_at(self: &DecDigits, i: i64) bool {
        if i < 0 || i >= self.nd as i64 {
            return false;
        }
        let u = i as usize;
        if self.d[u] == 5 && u + 1 == self.nd {
            if self.trunc {
                return true;
            }
            return u > 0 && self.d[u - 1] % 2 == 1;
        }
        return self.d[u] >= 5;
    }

    // The integer part, rounded to nearest even. The caller keeps it below 2^64.
    const fn rounded_integer(self: &DecDigits) u64 {
        let mut n: u64 = 0;
        let mut i: i64 = 0;
        while i < self.dp {
            n = n * 10;
            if i < self.nd as i64 {
                n = n + self.d[i as usize] as u64;
            }
            i += 1;
        }
        if self.round_up_at(self.dp) {
            n += 1;
        }
        return n;
    }

    // The IEEE binary encoding (sign bit clear) with `mbits` stored fraction bits and `ebits` exponent
    // bits, correctly rounded; infinity past the largest finite value. Consumes the digits.
    const fn to_bits(self: &mut DecDigits, mbits: u64, ebits: u64) u64 {
        let bias: i64 = 1 - (1i64 << (ebits - 1) as i64);
        let emask = (1u64 << ebits) - 1;
        let inf = emask << mbits;
        if self.nd == 0 || self.dp < -330 {
            return 0;
        }
        if self.dp > 310 {
            return inf;
        }
        // Scale into [1/2, 1), tracking the binary exponent.
        let mut exp: i64 = 0;
        while self.dp > 0 {
            let n: i64 = if self.dp >= 9 {
                27;
            } else {
                unsafe DEC_POW2[self.dp as usize];
            };
            self.shift(0 - n);
            exp += n;
        }
        while self.dp < 0 || self.dp == 0 && self.d[0] < 5 {
            let n: i64 = if 0 - self.dp >= 9 {
                27;
            } else {
                unsafe DEC_POW2[(0 - self.dp) as usize];
            };
            self.shift(n);
            exp -= n;
        }
        // [1/2, 1) is [1, 2) one exponent down.
        exp -= 1;
        if exp < bias + 1 {
            // Subnormal: denormalize to the minimum exponent.
            let n = bias + 1 - exp;
            self.shift(0 - n);
            exp += n;
        }
        if exp - bias >= emask as i64 {
            return inf;
        }
        self.shift(1 + mbits as i64);
        let mut mant = self.rounded_integer();
        if mant == 2u64 << mbits {
            // Rounding carried into a new bit.
            mant = mant >> 1;
            exp += 1;
            if exp - bias >= emask as i64 {
                return inf;
            }
        }
        if (mant & 1u64 << mbits) == 0 {
            // No implicit bit: a subnormal, encoded with a zero exponent field.
            exp = bias;
        }
        return mant & (1u64 << mbits) - 1 | ((exp - bias) as u64 & emask) << mbits;
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
            d = b - b'0';
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
            // Would overflow u64.
            return Option::<u64>::None;
        }
        acc = acc * r + dv;
        i += 1;
    }
    return Option::<u64>::Some(acc);
}

extend Bytes as Iterator<u8> {
    pub const fn next(self: &mut Bytes) Option<u8> {
        if self.i >= self.s.len() {
            return Option::<u8>::None;
        }
        let b = self.s.byte_at(self.i);
        self.i = self.i + 1;
        return Option::<u8>::Some(b);
    }
}

extend Chars as Iterator<u32> {
    pub const fn next(self: &mut Chars) Option<u32> {
        if self.i >= self.s.len() {
            return Option::<u32>::None;
        }
        let b0 = self.s.byte_at(self.i);
        let mut cp: u32 = 0;
        let mut n: usize = 1;
        if b0 < 0x80 {
            cp = b0;
            n = 1;
        } else if (b0 & 0xE0) == 0xC0 {
            cp = b0 & 0x1F;
            n = 2;
        } else if (b0 & 0xF0) == 0xE0 {
            cp = b0 & 0x0F;
            n = 3;
        } else if (b0 & 0xF8) == 0xF0 {
            cp = b0 & 0x07;
            n = 4;
        } else {
            self.i = self.i + 1;
            // A continuation byte or 5+ byte leader: not a valid start.
            return Option::<u32>::Some(0xFFFD);
        }
        if self.i + n > self.s.len() {
            // Truncated sequence at the end of the view.
            self.i = self.i + 1;
            return Option::<u32>::Some(0xFFFD);
        }
        let mut k: usize = 1;
        while k < n {
            let cb = self.s.byte_at(self.i + k);
            if (cb & 0xC0) != 0x80 {
                // A non-continuation byte where one is required: malformed.
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
    pub const fn next(self: &mut Split) Option<str> {
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
    pub const fn next(self: &mut Lines) Option<str> {
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

// `{}` formats a str natively; the INTERFACE fact exists for `V: Format` bounds (reflection).
extend str as Format {
    pub fn fmt(self: &str) String {
        return format("{}", *self);
    }
}
