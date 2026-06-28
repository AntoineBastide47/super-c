// The `str` module: the borrowed UTF-8 view that is the type of every string literal. This module is
// auto-imported as the prelude, so `str` is in scope unqualified everywhere.
//
// `str` is a non-owning (ptr, len) view: it never allocates, resizes, or mutates the bytes it points
// at, so its whole API returns either sub-views (`str`) or scalar values. Owning/mutating operations
// live on `String`. The two fields are public -- a `str` is a plain fat pointer -- so `s.ptr` / `s.len`
// are usable directly; the `len()` / `is_empty()` / `ptr()` methods exist for API parity with `String`.
//
// Out of scope until the language grows cycle-free prelude iterators: `split`, `lines`, and `chars`.
// `is_valid_utf8` is structural only: it does not reject overlong encodings or surrogate-range scalars.

extern "C" {
    fn memcmp(a: *const void, b: *const void, n: usize) i32;
}

// A borrowed view over UTF-8 bytes -- the type of a string literal. Non-owning: the bytes outlive it.
pub struct str {
    pub ptr: *const u8, // start of the bytes
    pub len: usize,     // number of bytes
}

extend str {
    // --- length & raw access -------------------------------------------------------------------

    // Number of bytes in the view. `s.len()` (this method) and the public `s.len` field are the same
    // value; the method exists so `str` and `String` share one `.len()` surface.
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
        return self.ptr[index];
    }

    // The sub-view of bytes [start, end) -- allocation-free, it borrows `self`'s bytes. The caller
    // keeps `start`/`end` on UTF-8 boundaries (and within bounds).
    pub fn slice(self: &str, start: usize, end: usize) str {
        return str { ptr: self.ptr + start, len: end - start, };
    }

    // --- search --------------------------------------------------------------------------------

    pub fn starts_with(self: &str, prefix: str) bool {
        if prefix.len > self.len {
            return false;
        }
        if prefix.len == 0 {
            return true;
        }
        return memcmp(self.ptr as *const void, prefix.ptr as *const void, prefix.len) == 0;
    }

    pub fn ends_with(self: &str, suffix: str) bool {
        if suffix.len > self.len {
            return false;
        }
        if suffix.len == 0 {
            return true;
        }
        return memcmp((self.ptr + (self.len - suffix.len)) as *const void, suffix.ptr as *const void, suffix.len) == 0;
    }

    // First index of byte `byte`, or -1 if absent.
    pub fn find_byte(self: &str, byte: u8) isize {
        for i in 0..self.len {
            if self.ptr[i] == byte {
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
            if memcmp((self.ptr + i) as *const void, needle.ptr as *const void, needle.len) == 0 {
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
            let b = self.ptr[start];
            if b != 32 && b != 9 && b != 10 && b != 13 {
                break;
            }
            start = start + 1;
        }
        return str { ptr: self.ptr + start, len: self.len - start, };
    }

    // The view with trailing ASCII whitespace removed.
    pub fn trim_end(self: &str) str {
        let mut end = self.len;
        while end > 0 {
            let b = self.ptr[end - 1];
            if b != 32 && b != 9 && b != 10 && b != 13 {
                break;
            }
            end = end - 1;
        }
        return str { ptr: self.ptr, len: end, };
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
            if (self.ptr[i] & 0xC0) != 0x80 {
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
            let b = self.ptr[i];
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
                if (self.ptr[i + k] & 0xC0) != 0x80 {
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
        return memcmp(self.ptr as *const void, other.ptr as *const void, self.len) == 0;
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
            let c = memcmp(self.ptr as *const void, other.ptr as *const void, n);
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
        let mut i: usize = 0;
        while i < self.len {
            h = (h ^ (self.ptr[i] as u64)) * 0x100000001b3;
            i = i + 1;
        }
        return h;
    }
}

extend str as Default {
    // The empty view (a null, zero-length `str`).
    pub fn default() str {
        return str { ptr: null, len: 0, };
    }
}
