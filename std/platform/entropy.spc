// Operating-system entropy of std::platform: bytes from the system's cryptographically secure generator,
// for keys, nonces and hash seeds. There is no fallback: a target without such a source fails, it never
// returns predictable bytes. Unstable, internal to std and the compiler.
import std::platform::error;

@platform(linux | android)
extern "C" "sys/random.h" {
    fn getrandom(buf: *mut void, n: usize, flags: u32) isize;
}

@platform(macos | ios)
extern "C" {
    fn arc4random_buf(buf: *mut void, n: usize);
}

@platform(windows)
extern "C" "windows.h" {}

// BCRYPT_USE_SYSTEM_PREFERRED_RNG: no algorithm handle, the system's default generator.
@platform(windows)
@link("bcrypt")
extern "C" "bcrypt.h" {
    fn BCryptGenRandom(alg: *mut void, buf: *mut u8, n: u32, flags: u32) i32;
    const BCRYPT_USE_SYSTEM_PREFERRED_RNG: u32 = 2;
}

@platform(wasm)
extern "C" "wasi/api.h" {
    @import("__wasi_random_get")
    fn wasi_random_get(buf: *mut u8, n: usize) u16;
}

/// Fill all of `buf` with bytes of the operating system's cryptographic generator: `getrandom` (Linux,
/// Android), `arc4random_buf` (macOS, iOS), `BCryptGenRandom` (Windows) or WASI `random_get`. On error the
/// contents of `buf` are unspecified and must not be used.
@platform(linux | android)
pub fn fill(buf: []mut u8) Result<Unit, IoError> {
    let mut off: usize = 0;
    // Each pass fills at least one byte or retries an interrupted call; getrandom blocks only until the
    // pool is first seeded.
    while off < buf.len() {
        let r = unsafe getrandom(unsafe (buf.as_mut_ptr() + off), buf.len() - off, 0);
        if r < 0 {
            if error::interrupted() {
                continue;
            }
            return Result::<Unit, IoError>::Err(error::last_error(IoOp::Entropy));
        }
        off += r as usize;
    }
    return Result::<Unit, IoError>::Ok(Unit {});
}
/// Fill all of `buf` with bytes of the operating system's cryptographic generator: `getrandom` (Linux,
/// Android), `arc4random_buf` (macOS, iOS), `BCryptGenRandom` (Windows) or WASI `random_get`. On error the
/// contents of `buf` are unspecified and must not be used.
@platform(macos | ios)
pub fn fill(buf: []mut u8) Result<Unit, IoError> {
    // arc4random_buf cannot fail: the kernel seeds it.
    unsafe arc4random_buf(buf.as_mut_ptr(), buf.len());
    return Result::<Unit, IoError>::Ok(Unit {});
}
/// Fill all of `buf` with bytes of the operating system's cryptographic generator: `getrandom` (Linux,
/// Android), `arc4random_buf` (macOS, iOS), `BCryptGenRandom` (Windows) or WASI `random_get`. On error the
/// contents of `buf` are unspecified and must not be used.
@platform(windows)
pub fn fill(buf: []mut u8) Result<Unit, IoError> {
    let mut off: usize = 0;
    // Each pass fills up to 1 GiB: the call counts in a u32.
    while off < buf.len() {
        let n = (buf.len() - off).min(1 << 30);
        let st = unsafe BCryptGenRandom(
            null,
            unsafe (buf.as_mut_ptr() + off),
            n as u32,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        );
        if st != 0 {
            return Result::<Unit, IoError>::Err(IoError { kind: IoErrorKind::Other, code: st, op: IoOp::Entropy });
        }
        off += n;
    }
    return Result::<Unit, IoError>::Ok(Unit {});
}
/// Fill all of `buf` with bytes of the operating system's cryptographic generator: `getrandom` (Linux,
/// Android), `arc4random_buf` (macOS, iOS), `BCryptGenRandom` (Windows) or WASI `random_get`. On error the
/// contents of `buf` are unspecified and must not be used.
@platform(wasm)
pub fn fill(buf: []mut u8) Result<Unit, IoError> {
    let e = unsafe wasi_random_get(buf.as_mut_ptr(), buf.len());
    if e != 0 {
        return Result::<Unit, IoError>::Err(error::code_error(e, IoOp::Entropy));
    }
    return Result::<Unit, IoError>::Ok(Unit {});
}
