// The environment of std::platform: read, set and remove one variable, and a snapshot of every variable.
// A value read is a copy, so a later `set` cannot change it under the reader. POSIX names the C library's
// environment, which a concurrent `setenv` makes unsafe to read: `set` and `unset` are `unsafe` for that.
// Windows goes through the C runtime for writes (`_wputenv_s`, which also updates the process environment
// Win32 reads) so C code that calls `getenv` sees them. Unstable, internal to std and the compiler.
import std::platform::error;
import std::platform::path;
import string as cstring;

@platform(!windows)
extern "C" "stdlib.h" {
    fn setenv(name: *const char, value: *const char, overwrite: i32) i32;
    fn unsetenv(name: *const char) i32;
    @import("getenv")
    fn c_getenv(name: *const char) *const char;
}

@platform(macos | ios)
extern "C" "crt_externs.h" {
    fn _NSGetEnviron() *mut *mut *mut char;
}
@platform(linux)
extern "C" "unistd.h" {
    @import("__environ")
    static mut c_environ: *mut *mut char;
}
@platform(android)
extern "C" "unistd.h" {
    @import("environ")
    static mut c_environ: *mut *mut char;
}
@platform(wasm)
extern "C" "wasi/libc-environ.h" {
    fn __wasilibc_get_environ() *mut *mut char;
}

@platform(windows)
extern "C" "windows.h" {
    fn GetEnvironmentVariableW(name: *const u16, buf: *mut u16, size: u32) u32;
    fn GetEnvironmentStringsW() *mut u16;
    fn FreeEnvironmentStringsW(block: *mut u16) i32;
    fn GetLastError() u32;
    fn SetLastError(code: u32);
    const ERROR_ENVVAR_NOT_FOUND: u32 = 203;
}

@platform(windows)
extern "C" "stdlib.h" {
    fn _wputenv_s(name: *const u16, value: *const u16) i32;
}

/// Every variable of the environment at one moment, in one buffer: `NAME=VALUE` entries, each ended by
/// a NUL byte.
pub struct Vars {
    text: String,
}

/// The entries of a `Vars`, in the environment's order.
pub struct VarIter<'a> {
    text: str<'a>,
    pos: usize,
}

/// The value of variable `name`, or None when it is not set. InvalidInput for an empty name or one with
/// '=' or NUL; InvalidData on Windows for a value that is not valid UTF-16.
@platform(!windows)
pub fn get(name: str) Result<Option<String>, IoError> {
    let np = check_name(name, IoOp::GetEnv)?;
    let v = unsafe c_getenv(np.ptr());
    if v == null {
        return Result::<Option<String>, IoError>::Ok(Option::<String>::None);
    }
    return Result::<Option<String>, IoError>::Ok(Option::<String>::Some(unsafe String::from_cstr(v)));
}
/// The value of variable `name`, or None when it is not set. InvalidInput for an empty name or one with
/// '=' or NUL; InvalidData on Windows for a value that is not valid UTF-16.
@platform(windows)
pub fn get(name: str) Result<Option<String>, IoError> {
    let np = check_name(name, IoOp::GetEnv)?;
    let mut small: [u16; 512] = [0; 512];
    let mut big = Vector::<u16>::new();
    let mut cap: u32 = 512;
    let mut buf: *mut u16 = &mut small[0];
    // At most two passes: the second has the size the first reported, unless the variable grew between.
    for _ in 0..4 {
        unsafe SetLastError(0);
        let n = unsafe GetEnvironmentVariableW(np.ptr(), buf, cap);
        if n == 0 {
            let e = unsafe GetLastError();
            if e == ERROR_ENVVAR_NOT_FOUND {
                return Result::<Option<String>, IoError>::Ok(Option::<String>::None);
            }
            if e != 0 {
                return Result::<Option<String>, IoError>::Err(error::code_error(e as i32, IoOp::GetEnv));
            }
        }
        if n < cap {
            let mut out = String::new();
            path::push_wide(&mut out, unsafe Slice::<u16> { ptr: buf, len: n as usize }, false, IoOp::GetEnv)?;
            return Result::<Option<String>, IoError>::Ok(Option::<String>::Some(out));
        }
        big.clear();
        big.resize_default(n as usize);
        cap = n;
        buf = big.index_range_mut(0..n as usize).as_mut_ptr();
    }
    return Result::<Option<String>, IoError>::Err(IoError::new(IoErrorKind::Other, IoOp::GetEnv));
}

/// Set variable `name` to `value`, replacing any value. InvalidInput for an empty name or one with '=',
/// or a NUL in either. On Windows an empty value removes the variable, as the C runtime does.
/// Safety: no other thread reads or writes the environment while the call runs.
@platform(!windows)
pub unsafe fn set(name: str, value: str) Result<Unit, IoError> {
    let n = check_name(name, IoOp::SetEnv)?;
    let v = path::native(value, IoOp::SetEnv)?;
    if unsafe setenv(n.ptr(), v.ptr(), 1) != 0 {
        return Result::<Unit, IoError>::Err(error::last_error(IoOp::SetEnv));
    }
    return Result::<Unit, IoError>::Ok(Unit {});
}
/// Set variable `name` to `value`, replacing any value. InvalidInput for an empty name or one with '=',
/// or a NUL in either. On Windows an empty value removes the variable, as the C runtime does.
/// Safety: no other thread reads or writes the environment while the call runs.
@platform(windows)
pub unsafe fn set(name: str, value: str) Result<Unit, IoError> {
    let n = check_name(name, IoOp::SetEnv)?;
    let v = path::native(value, IoOp::SetEnv)?;
    return crt_result(unsafe _wputenv_s(n.ptr(), v.ptr()), IoOp::SetEnv);
}

/// Remove variable `name`; removing an unset variable succeeds. InvalidInput for an empty name or one with
/// '=' or NUL.
/// Safety: no other thread reads or writes the environment while the call runs.
@platform(!windows)
pub unsafe fn unset(name: str) Result<Unit, IoError> {
    let n = check_name(name, IoOp::UnsetEnv)?;
    if unsafe unsetenv(n.ptr()) != 0 {
        return Result::<Unit, IoError>::Err(error::last_error(IoOp::UnsetEnv));
    }
    return Result::<Unit, IoError>::Ok(Unit {});
}
/// Remove variable `name`; removing an unset variable succeeds. InvalidInput for an empty name or one with
/// '=' or NUL.
/// Safety: no other thread reads or writes the environment while the call runs.
@platform(windows)
pub unsafe fn unset(name: str) Result<Unit, IoError> {
    let n = check_name(name, IoOp::UnsetEnv)?;
    let empty: [u16; 1] = [0];
    return crt_result(unsafe _wputenv_s(n.ptr(), &empty[0]), IoOp::UnsetEnv);
}

/// A copy of every variable: one allocation that grows geometrically, none per variable.
@platform(!windows)
pub fn vars() Result<Vars, IoError> {
    let mut text = String::new();
    let mut p = unsafe environ();
    // Bounded by the null entry that ends the array.
    while p != null && unsafe *p != null {
        let e = unsafe *p;
        text.push_bytes(unsafe Slice::<u8> { ptr: e as *const u8, len: cstring::strlen(e) });
        text.push_byte(0);
        p = unsafe (p + 1);
    }
    return Result::<Vars, IoError>::Ok(Vars::adopt(text));
}
/// A copy of every variable: one allocation that grows geometrically, none per variable.
@platform(windows)
pub fn vars() Result<Vars, IoError> {
    let block = unsafe GetEnvironmentStringsW();
    if block == null {
        return Result::<Vars, IoError>::Err(error::last_error(IoOp::GetEnv));
    }
    let mut text = String::new();
    let mut p: *const u16 = block;
    let mut bad = false;
    // Bounded by the empty entry that ends the block.
    while unsafe *p != 0 {
        let entry = unsafe path::wide_view(p);
        bad = bad || path::push_wide(&mut text, entry, false, IoOp::GetEnv).is_err();
        text.push_byte(0);
        p = unsafe (p + entry.len() + 1);
    }
    unsafe FreeEnvironmentStringsW(block);
    if bad {
        return Result::<Vars, IoError>::Err(IoError::new(IoErrorKind::InvalidData, IoOp::GetEnv));
    }
    return Result::<Vars, IoError>::Ok(Vars::adopt(text));
}

/// The C library's environment array, ended by a null entry: what a spawned child inherits.
/// Safety: no other thread writes the environment while the caller reads the array.
@platform(macos | ios)
pub unsafe fn environ() *const *mut char {
    return unsafe *_NSGetEnviron();
}
/// The C library's environment array, ended by a null entry: what a spawned child inherits.
/// Safety: no other thread writes the environment while the caller reads the array.
@platform(linux | android)
pub unsafe fn environ() *const *mut char {
    return unsafe c_environ;
}
/// The C library's environment array, ended by a null entry: what a spawned child inherits.
/// Safety: no other thread writes the environment while the caller reads the array.
@platform(wasm)
pub unsafe fn environ() *const *mut char {
    return unsafe __wasilibc_get_environ();
}

// The native form of variable name `name`: InvalidInput when it is empty or holds '=' or NUL.
fn check_name(name: str, op: IoOp) Result<path::NativePath, IoError> {
    if name.len() == 0 || name.find_byte(b'=') >= 0 {
        return Result::<path::NativePath, IoError>::Err(IoError::new(IoErrorKind::InvalidInput, op));
    }
    return path::native(name, op);
}

// The result of a C runtime call that returns an errno value (`errno_t`): EINVAL is InvalidInput, any
// other failure (ENOMEM) OutOfMemory.
@platform(windows)
fn crt_result(rc: i32, op: IoOp) Result<Unit, IoError> {
    if rc == 0 {
        return Result::<Unit, IoError>::Ok(Unit {});
    }
    let kind = if rc == 22 {
        IoErrorKind::InvalidInput;
    } else {
        IoErrorKind::OutOfMemory;
    };
    return Result::<Unit, IoError>::Err(IoError { kind: kind, code: rc, op: op });
}

extend Vars {
    const fn adopt(text: String) Vars {
        return Vars { text: text };
    }
    /// The entries, as (name, value) views into the snapshot.
    pub const fn iter(self: &Vars) VarIter {
        return VarIter::start(self.text.as_str());
    }
}

extend<'a> VarIter<'a> {
    const fn start(text: str<'a>) VarIter<'a> {
        return VarIter::<'a> { text: text, pos: 0 };
    }
    /// The next (name, value) pair; None after the last. The name ends at the first '=' after its first
    /// byte (a Windows drive variable such as `=C:` keeps its leading '='); an entry without '=' has an
    /// empty value.
    pub fn next(self: &mut VarIter<'a>) Option<(str<'a>, str<'a>)> {
        if self.pos >= self.text.len() {
            return Option::<(str<'a>, str<'a>)>::None;
        }
        let start = self.pos;
        let mut end = start;
        // Bounded by the snapshot's length.
        while self.text.byte_at(end) != 0 {
            end += 1;
        }
        self.pos = end + 1;
        let mut eq = start + 1;
        while eq < end && self.text.byte_at(eq) != b'=' {
            eq += 1;
        }
        let name = self.text.slice(start, eq.min(end));
        let value = if eq < end {
            self.text.slice(eq + 1, end);
        } else {
            "";
        };
        return Option::<(str<'a>, str<'a>)>::Some((name, value));
    }
}
