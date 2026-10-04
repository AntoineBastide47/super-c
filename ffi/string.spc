// FFI bindings for <string.h>: raw memory and C-string routines. Import with `import string;` (this is
// the C `string.h` module, distinct from the prelude `String` type, which stays available unqualified).
//
// The raw bindings are unbounded (the length or NUL terminator is the caller's responsibility). The helper
// functions below operate over Super-C slices. Calling the raw bindings requires `unsafe`; the slice
// helpers do not. `strlen`, `memchr`, `strchr`, `strrchr` and `strstr` carry their compile-time models
// (`@unsafe(const)`); `memcmp`, `memcpy` and `memset` are evaluated by the compiler itself.

extern "C" {
    /// Raw memory (sizes in bytes). `memset`'s fill value is an `int` truncated to `unsigned char`.
    pub fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
    /// Copy `n` bytes, overlap-safe; returns `dst`.
    pub fn memmove(dst: *mut void, src: *const void, n: usize) *mut void;
    /// Fill `n` bytes with the low byte of `value`; returns `dst`.
    pub fn memset(dst: *mut void, value: i32, n: usize) *mut void;
    /// Compare `n` bytes; negative, zero, or positive by the first differing byte.
    pub fn memcmp(a: *const void, b: *const void, n: usize) i32;
    /// First occurrence of the low byte of `value` in `n` bytes, or null.
    @unsafe(const)
    pub fn memchr(s: *const void, value: i32, n: usize) *mut void {
        let p = s as *const u8;
        let b = value as u8;
        for i in 0..n {
            if unsafe p[i] == b {
                return (unsafe (p + i)) as *mut void;
            }
        }
        return null;
    }

    /// NUL-terminated C strings.
    @unsafe(const)
    pub fn strlen(s: *const char) usize {
        let mut n: usize = 0;
        while (unsafe s[n]) as u8 != 0 {
            n += 1;
        }
        return n;
    }
    /// Compare NUL-terminated strings; negative, zero, or positive.
    pub fn strcmp(a: *const char, b: *const char) i32;
    /// strcmp over at most `n` bytes.
    pub fn strncmp(a: *const char, b: *const char, n: usize) i32;
    /// First occurrence of `c` (or the terminator when `c` is 0), or null.
    @unsafe(const)
    pub fn strchr(s: *const char, c: i32) *mut char {
        let want = c as u8;
        let mut i: usize = 0;
        loop {
            let ch = (unsafe s[i]) as u8;
            if ch == want {
                return (unsafe (s + i)) as *mut char;
            }
            if ch == 0 {
                return null;
            }
            i += 1;
        }
    }
    /// Last occurrence of `c`, or null.
    @unsafe(const)
    pub fn strrchr(s: *const char, c: i32) *mut char {
        let want = c as u8;
        let mut last: *const char = null;
        let mut i: usize = 0;
        loop {
            let ch = (unsafe s[i]) as u8;
            if ch == want {
                last = unsafe (s + i);
            }
            if ch == 0 {
                return last as *mut char;
            }
            i += 1;
        }
    }
    /// First occurrence of `needle`, or null.
    @unsafe(const)
    pub fn strstr(haystack: *const char, needle: *const char) *mut char {
        let mut i: usize = 0;
        loop {
            let mut j: usize = 0;
            while (unsafe needle[j]) as u8 != 0 && unsafe haystack[i + j] == unsafe needle[j] {
                j += 1;
            }
            if (unsafe needle[j]) as u8 == 0 {
                return (unsafe (haystack + i)) as *mut char;
            }
            if (unsafe haystack[i]) as u8 == 0 {
                return null;
            }
            i += 1;
        }
    }
}

/// Copy `min(dst.len, src.len)` bytes (non-overlapping) and return the count.
pub const fn copy(dst: []mut u8, src: []u8) usize {
    let mut n = dst.len();
    if src.len() < n {
        n = src.len();
    }
    if n > 0 {
        unsafe memcpy(dst.as_mut_ptr(), src.as_ptr(), n);
    }
    return n;
}

/// Copy `min(dst.len, src.len)` bytes, overlap-safe, and return the count.
pub fn move_bytes(dst: []mut u8, src: []u8) usize {
    let mut n = dst.len();
    if src.len() < n {
        n = src.len();
    }
    if n > 0 {
        unsafe memmove(dst.as_mut_ptr(), src.as_ptr(), n);
    }
    return n;
}

/// Set every byte of `dst` to `value`.
pub const fn fill(dst: []mut u8, value: u8) {
    if dst.len() > 0 {
        unsafe memset(dst.as_mut_ptr(), value, dst.len());
    }
}

/// True when both slices have the same length and bytes.
pub const fn equal(a: []u8, b: []u8) bool {
    if a.len() != b.len() {
        return false;
    }
    if a.len() == 0 {
        return true;
    }
    return unsafe memcmp(a.as_ptr(), b.as_ptr(), a.len()) == 0;
}
