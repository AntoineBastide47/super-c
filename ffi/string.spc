// FFI bindings for <string.h>: raw memory and C-string routines. Import with `import string;` (this is
// the C `string.h` module, distinct from the prelude `String` type, which stays available unqualified).
//
// The raw bindings are unbounded (the length or NUL terminator is the caller's responsibility). The helper
// functions below operate over Super-C slices. Calling the raw bindings requires `unsafe`; the slice
// helpers do not.

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
    pub fn memchr(s: *const void, value: i32, n: usize) *mut void;

    /// NUL-terminated C strings.
    pub fn strlen(s: *const char) usize;
    /// Compare NUL-terminated strings; negative, zero, or positive.
    pub fn strcmp(a: *const char, b: *const char) i32;
    /// strcmp over at most `n` bytes.
    pub fn strncmp(a: *const char, b: *const char, n: usize) i32;
    /// First occurrence of `c` (or the terminator when `c` is 0), or null.
    pub fn strchr(s: *const char, c: i32) *mut char;
    /// Last occurrence of `c`, or null.
    pub fn strrchr(s: *const char, c: i32) *mut char;
    /// First occurrence of `needle`, or null.
    pub fn strstr(haystack: *const char, needle: *const char) *mut char;
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
