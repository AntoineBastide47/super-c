// FFI bindings for <string.h>: raw memory and C-string routines. Import with `import string;` (this is
// the C `string.h` module, distinct from the prelude `String` type, which stays available unqualified).
//
// The raw bindings are unbounded (the length or NUL terminator is the caller's responsibility). The helper
// functions below operate over Super-C slices.

extern "C" {
    // Raw memory (sizes in bytes). `memset`'s fill value is an `int` truncated to `unsigned char`.
    pub fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
    pub fn memmove(dst: *mut void, src: *const void, n: usize) *mut void;
    pub fn memset(dst: *mut void, value: i32, n: usize) *mut void;
    pub fn memcmp(a: *const void, b: *const void, n: usize) i32;
    pub fn memchr(s: *const void, value: i32, n: usize) *mut void;

    // NUL-terminated C strings.
    pub fn strlen(s: *const char) usize;
    pub fn strcmp(a: *const char, b: *const char) i32;
    pub fn strncmp(a: *const char, b: *const char, n: usize) i32;
    pub fn strchr(s: *const char, c: i32) *mut char;
    pub fn strrchr(s: *const char, c: i32) *mut char;
    pub fn strstr(haystack: *const char, needle: *const char) *mut char;
}

pub fn copy(dst: []mut u8, src: []u8) usize {
    let mut n = dst.len();
    if src.len() < n {
        n = src.len();
    }
    if n > 0 {
        memcpy(dst.as_mut_ptr() as *mut void, src.as_ptr() as *const void, n);
    }
    return n;
}

pub fn move_bytes(dst: []mut u8, src: []u8) usize {
    let mut n = dst.len();
    if src.len() < n {
        n = src.len();
    }
    if n > 0 {
        memmove(dst.as_mut_ptr() as *mut void, src.as_ptr() as *const void, n);
    }
    return n;
}

pub fn fill(dst: []mut u8, value: u8) {
    if dst.len() > 0 {
        memset(dst.as_mut_ptr() as *mut void, value as i32, dst.len());
    }
}

pub fn equal(a: []u8, b: []u8) bool {
    if a.len() != b.len() {
        return false;
    }
    if a.len() == 0 {
        return true;
    }
    return memcmp(a.as_ptr() as *const void, b.as_ptr() as *const void, a.len()) == 0;
}
