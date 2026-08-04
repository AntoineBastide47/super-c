// FFI bindings for <stdlib.h>: allocation, process control, environment, numeric parsing, randomness,
// and sort/search. Import with `import stdlib;`. Raw `pub` bindings expose the C API directly; the safe
// wrappers add null checks and `String`/`Option` ergonomics where they help. Calling the raw bindings
// requires `unsafe`; the safe wrappers do not.

extern "C" {
    // Allocation. Sizes in bytes; all may return null on failure.
    pub fn malloc(size: usize) *mut void;
    pub fn calloc(count: usize, size: usize) *mut void;
    pub fn realloc(ptr: *mut void, size: usize) *mut void;
    pub fn free(ptr: *mut void) void;

    // Process control. `exit`/`abort` do not return; `atexit` registers a callback (0 on success).
    pub fn exit(code: i32) void;
    pub fn abort() void;
    pub fn atexit(handler: fn() void) i32;
    @c.import("getenv")
    fn c_getenv(name: *const char) *const char;

    // Numeric parsing. `ato*` return 0 on a bad parse; `strto*` report where parsing stopped via endptr.
    pub fn atoi(s: *const char) i32;
    pub fn atol(s: *const char) i64;
    pub fn atof(s: *const char) f64;
    pub fn strtol(s: *const char, endptr: *mut void, base: i32) i64;
    pub fn strtoul(s: *const char, endptr: *mut void, base: i32) u64;
    pub fn strtod(s: *const char, endptr: *mut void) f64;

    // Randomness. `rand` yields 0..=RAND_MAX; seed it with `srand`.
    pub fn rand() i32;
    pub fn srand(seed: u32) void;

    // Sort and binary search over an array of `count` elements of `size` bytes, ordered by `cmp`.
    pub fn qsort(base: *mut void, count: usize, size: usize, cmp: fn(*const void, *const void) i32) void;
    pub fn bsearch(
        key: *const void,
        base: *const void,
        count: usize,
        size: usize,
        cmp: fn(*const void, *const void) i32,
    ) *mut void;

    // Integer absolute value.
    pub fn abs(n: i32) i32;
    pub fn labs(n: i64) i64;
}

// A sandboxed iOS app has no shell to reach, and the SDK says so with __API_UNAVAILABLE: naming `system`
// there does not merely fail at run time, it fails to COMPILE -- which took down every iOS build that
// reached this module, including every one that only wanted `malloc`. Gated off, so it is the call that is
// missing rather than the whole module.
@platform(!ios)
extern "C" {
    @c.import("system")
    fn c_system(command: *const char) i32;
}

// --- safe wrappers ----------------------------------------------------------------------------------

// The value of environment variable `name`, or `None` if unset (a fresh owned copy -- the C buffer is not
// retained).
pub fn get_env(name: &mut String) Option<String> {
    let p = unsafe c_getenv(name.cstr());
    if p == null {
        return Option::<String>::None;
    }
    return Option::<String>::Some(String::from_cstr(p));
}

// The raw value of environment variable `name` (`null` if unset). Borrows libc's buffer -- copy it if you
// need it past the next environment change. `name` is NUL-terminated into a temporary before the call.
pub fn getenv(name: str) *const char {
    let mut n = String::from_str(name);
    return unsafe c_getenv(n.cstr());
}

// Run `command` through the shell (NUL-terminated into a temporary), returning its raw `wait`-style status.
@platform(!ios)
pub fn system(command: str) i32 {
    let mut c = String::from_str(command);
    return unsafe c_system(c.cstr());
}

// Parse a base-10 integer, ignoring leading whitespace and trailing junk (0 on a non-numeric string).
pub fn parse_int(s: &mut String) i64 {
    return unsafe atol(s.cstr());
}

// Parse a floating-point value (0.0 on a non-numeric string).
pub fn parse_float(s: &mut String) f64 {
    return unsafe atof(s.cstr());
}
