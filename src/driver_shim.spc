// The compiler's own process glue, the parts that are no portable operating-system facility (those are in
// std::platform): the build target of the running compiler, the argv[0] a WASI module is known by, the
// process-tree jobserver (byte-range locks on one shared slot file) and the crash trace printed on SIGABRT.
// POSIX (macOS, iOS, Linux, Android) goes through libc, Windows through the Win32 API, and wasm through
// wasi-libc, which has neither locks nor signals: there the jobserver is off and the trace is a no-op.
import errno;
import fcntl;
import signal;
import stdio;
import stdlib;
import string as cstring;
import unistd;

// ---- C bindings: POSIX ------------------------------------------------------------------------------

@platform(macos | ios | linux | android)
extern "C" "stdlib.h" {
    fn mkstemp(template: *mut char) i32;
    fn setenv(name: *const char, value: *const char, overwrite: i32) i32;
}

@platform(macos | ios | linux | android)
extern "C" "unistd.h" {
    fn unlink(path: *const char) i32;
}

@platform(macos | ios)
extern "C" "fcntl.h" {
    struct flock {
        pub l_start: i64,
        pub l_len: i64,
        pub l_pid: i32,
        pub l_type: i16,
        pub l_whence: i16,
    }
}
@platform(linux | android)
extern "C" "fcntl.h" {
    struct flock {
        pub l_type: i16,
        pub l_whence: i16,
        pub l_start: i64,
        pub l_len: i64,
        pub l_pid: i32,
    }
}
@platform(macos | ios | linux | android)
extern "C" "fcntl.h" {
    const F_SETLK: i32;
    const F_WRLCK: i32;
    const F_UNLCK: i32;
}

@platform(macos | ios | linux | android)
extern "C" "errno.h" {
    const EINTR: i32;
    const EACCES: i32;
    const EAGAIN: i32;
}

@platform(macos | ios | linux | android)
extern "C" "execinfo.h" {
    fn backtrace(frames: *mut *mut void, size: i32) i32;
    fn backtrace_symbols_fd(frames: *const *mut void, size: i32, fd: i32) void;
}

// ---- C bindings: Windows ----------------------------------------------------------------------------

@platform(windows)
extern "C" "windows.h" {
    // `Offset` and `OffsetHigh` are the members of an anonymous union that overlays `Pointer`.
    @import("OVERLAPPED")
    struct OVERLAPPED {
        pub Internal: usize,
        pub InternalHigh: usize,
        pub Offset: u32,
        pub OffsetHigh: u32,
        pub hEvent: *mut void,
    }
    fn CreateFileA(
        path: *const char,
        access: u32,
        share: u32,
        security: *mut void,
        disposition: u32,
        flags: u32,
        template: *mut void,
    ) *mut void;
    fn CloseHandle(h: *mut void) i32;
    fn GetModuleHandleA(name: *const char) *mut void;
    fn GetTempPathA(size: u32, buf: *mut char) u32;
    fn GetCurrentProcessId() u32;
    fn GetTickCount64() u64;
    fn SetEnvironmentVariableA(name: *const char, value: *const char) i32;
    fn LockFileEx(h: *mut void, flags: u32, reserved: u32, low: u32, high: u32, ov: *mut OVERLAPPED) i32;
    fn UnlockFileEx(h: *mut void, reserved: u32, low: u32, high: u32, ov: *mut OVERLAPPED) i32;
    fn GetLastError() u32;
    fn RtlCaptureStackBackTrace(skip: u32, n: u32, frames: *mut *mut void, hash: *mut void) u16;

    const INVALID_HANDLE_VALUE: *mut void;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    const FILE_ATTRIBUTE_TEMPORARY: u32 = 0x100;
    const FILE_FLAG_DELETE_ON_CLOSE: u32 = 0x04000000;
    const FILE_SHARE_READ: u32 = 1;
    const FILE_SHARE_WRITE: u32 = 2;
    const FILE_SHARE_DELETE: u32 = 4;
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const CREATE_NEW: u32 = 1;
    const OPEN_EXISTING: u32 = 3;
    const LOCKFILE_FAIL_IMMEDIATELY: u32 = 1;
    const LOCKFILE_EXCLUSIVE_LOCK: u32 = 2;
    const ERROR_LOCK_VIOLATION: u32 = 33;
    const MAX_PATH: u32 = 260;
}

// ---- Build target -----------------------------------------------------------------------------------

/// Platform index of the build: 0 windows, 1 macos (and ios), 2 linux, 3 wasm, 5 android (the default
/// --target).
pub unsafe const fn sc_host_platform() i32 {
    return switch PLATFORM {
        Windows => 0,
        MacOS | IOS => 1,
        Linux => 2,
        Wasm => 3,
        Android => 5,
    };
}

/// Instruction set of the build: 0 x86_64, 1 aarch64, 2 wasm32 (the default --arch).
pub unsafe const fn sc_host_arch() i32 {
    return switch ARCH {
        X86_64 => 0,
        AArch64 => 1,
        Wasm32 => 2,
    };
}

// ---- argv[0] ----------------------------------------------------------------------------------------

// The host's argv[0]: WASI has no other name for the running module.
@platform(wasm)
static mut ARGV0: *const char = null;

/// Record the process's argv[0], which must outlive every `argv0_path` call: under WASI, where the
/// module has no other name, an absolute argv[0] is the path `argv0_path` reports.
@platform(wasm)
pub unsafe fn sc_set_argv0(argv0: *const char) {
    unsafe ARGV0 = argv0;
}
/// Record the process's argv[0], which must outlive every `argv0_path` call: under WASI, where the
/// module has no other name, an absolute argv[0] is the path `argv0_path` reports.
@platform(!wasm)
pub unsafe const fn sc_set_argv0(_argv0: *const char) {}

/// The path of the running module under WASI: an absolute argv[0] names the module file through a
/// preopened root (`wasmtime run --dir=/ --argv0 <abs path>`); a relative one resolves against the
/// guest's cwd, not the host's, so it gives the empty string, as does any other target.
@platform(wasm)
pub fn argv0_path() String {
    let a = unsafe ARGV0;
    if a == null || unsafe a[0] != '/' {
        return String::new();
    }
    return unsafe String::from_cstr(a);
}
/// The path of the running module under WASI: an absolute argv[0] names the module file through a
/// preopened root (`wasmtime run --dir=/ --argv0 <abs path>`); a relative one resolves against the
/// guest's cwd, not the host's, so it gives the empty string, as does any other target.
@platform(!wasm)
pub fn argv0_path() String {
    return String::new();
}

// ---- Process-tree jobserver ------------------------------------------------------------------------

// The process-tree jobserver: `capacity` slots for the whole tree, one of them implicit to the process
// that made it. Each other slot is one byte of a slot file, held by a byte-range lock: fcntl F_SETLK
// (POSIX) or LockFileEx (Windows). The system drops a process's locks when it ends, by an exit, an abort
// or a kill, so a slot is never lost, and a forked child does not inherit its parent's POSIX locks.
// SC_JOBSERVER names the file to every process of the tree: "<slots>,<fd>" on POSIX, the inherited
// descriptor of the unlinked file; "<slots>,<path>" on Windows, a temporary file the system deletes when
// its last handle closes.
const JS_MAX: i32 = 1024;
static mut JS_CLAIMED: i32 = 0;
static mut JS_RELEASE_REGISTERED: bool = false;
static mut JS_LOADED: bool = false;
static mut JS_SLOTS: i32 = 0;
static mut JS_OWN: [bool; JS_MAX as usize] = [false; JS_MAX as usize]; // the slot bytes this process holds
@platform(windows)
static mut JS_FILE: *mut void = null;
@platform(macos | ios | linux | android)
static mut JS_FD: i32 = -1;

// A decimal integer at `s[*i]` as `sscanf`'s `%d` reads it: leading white space, an optional sign, at
// least one digit. Advances `*i` past it; None when there is no digit or the value leaves i32.
@platform(!wasm)
const fn scan_int(s: str, i: &mut usize) Option<i32> {
    while *i < s.len() && (s.byte_at(*i) == b' ' || s.byte_at(*i) >= b'\t' && s.byte_at(*i) <= b'\r') {
        *i += 1;
    }
    let neg = *i < s.len() && s.byte_at(*i) == b'-';
    if *i < s.len() && (s.byte_at(*i) == b'-' || s.byte_at(*i) == b'+') {
        *i += 1;
    }
    let start = *i;
    let mut v: i64 = 0;
    while *i < s.len() && s.byte_at(*i) >= b'0' && s.byte_at(*i) <= b'9' {
        v = v * 10 + (s.byte_at(*i) - b'0') as i64;
        if v > i32::MAX as i64 + 1 {
            return Option::None;
        }
        *i += 1;
    }
    if *i == start {
        return Option::None;
    }
    if neg {
        v = -v;
    }
    if v > i32::MAX as i64 {
        return Option::None;
    }
    return Option::Some(v as i32);
}

// The slots beside the implicit one that a budget of `capacity` workers gives, at most JS_MAX.
@platform(!wasm)
const fn js_extra_slots(capacity: i32) i32 {
    if capacity < 1 {
        return 0;
    }
    return (capacity - 1).min(JS_MAX);
}

@platform(windows)
unsafe fn jobserver_load() bool {
    if unsafe JS_LOADED {
        return true;
    }
    let v = stdlib::getenv("SC_JOBSERVER");
    if v == null {
        return false;
    }
    let s = unsafe str::from_cstr(v);
    let mut i: usize = 0;
    let mut n: i32 = 0;
    if let Some(x) = scan_int(s, &mut i) {
        n = x;
    } else {
        return false;
    }
    if i >= s.len() || s.byte_at(i) != b',' || n < 0 || n > JS_MAX {
        return false;
    }
    let share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
    let rw = GENERIC_READ | GENERIC_WRITE;
    let h = unsafe CreateFileA(&v[i + 1], rw, share, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if h == INVALID_HANDLE_VALUE {
        return false;
    }
    unsafe JS_FILE = h;
    unsafe JS_SLOTS = n;
    unsafe JS_LOADED = true;
    return true;
}

/// Create the process-tree jobserver when none exists. Returns 1 when a shared budget is active.
@platform(windows)
pub unsafe fn sc_jobserver_init(capacity: i32) i32 {
    if unsafe jobserver_load() {
        return 1;
    }
    let n = js_extra_slots(capacity);
    let mut dir: [char; 260] = [0 as char; 260];
    let dl = unsafe GetTempPathA(MAX_PATH, &mut dir[0]);
    if dl == 0 || dl >= MAX_PATH {
        return 0;
    }
    let mut path = String::from_str(str::from_cbuf(dir));
    path.format_into("super-c-jobs-{}-{}", unsafe GetCurrentProcessId(), unsafe GetTickCount64());
    let share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
    let rw = GENERIC_READ | GENERIC_WRITE;
    let temp = FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE;
    let h = unsafe CreateFileA(path.cstr(), rw, share, null, CREATE_NEW, temp, null);
    if h == INVALID_HANDLE_VALUE {
        return 0;
    }
    let mut text = String::new();
    text.format_into("{},{}", n, path.as_str());
    if unsafe SetEnvironmentVariableA("SC_JOBSERVER".ptr() as *const char, text.cstr()) == 0 {
        unsafe CloseHandle(h);
        return 0;
    }
    unsafe JS_FILE = h;
    unsafe JS_SLOTS = n;
    unsafe JS_LOADED = true;
    return 1;
}

// Lock (`lock`) or unlock slot byte `i`: 1 done, 0 another process holds it, -1 an error.
@platform(windows)
unsafe fn jobserver_lock(i: i32, lock: bool) i32 {
    let mut ov = unsafe zeroed::<OVERLAPPED>();
    ov.Offset = i as u32;
    if !lock {
        if unsafe UnlockFileEx(JS_FILE, 0, 1, 0, &mut ov) != 0 {
            return 1;
        }
        return -1;
    }
    if unsafe LockFileEx(JS_FILE, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &mut ov) != 0 {
        return 1;
    }
    if unsafe GetLastError() == ERROR_LOCK_VIOLATION {
        return 0;
    }
    return -1;
}

@platform(macos | ios | linux | android)
unsafe fn jobserver_load() bool {
    if unsafe JS_LOADED {
        return true;
    }
    let v = stdlib::getenv("SC_JOBSERVER");
    if v == null {
        return false;
    }
    // "<slots>,<fd>" and nothing after it.
    let s = unsafe str::from_cstr(v);
    let mut i: usize = 0;
    let mut n: i32 = 0;
    let mut fd: i32 = 0;
    if let Some(x) = scan_int(s, &mut i) {
        n = x;
    } else {
        return false;
    }
    if i >= s.len() || s.byte_at(i) != b',' {
        return false;
    }
    i += 1;
    if let Some(x) = scan_int(s, &mut i) {
        fd = x;
    } else {
        return false;
    }
    if i != s.len() || n < 0 || n > JS_MAX || fd < 0 {
        return false;
    }
    if unsafe fcntl::fcntl(fd, fcntl::F_GETFD) < 0 {
        return false;
    }
    unsafe JS_FD = fd;
    unsafe JS_SLOTS = n;
    unsafe JS_LOADED = true;
    return true;
}

/// Create the process-tree jobserver when none exists. Returns 1 when a shared budget is active.
@platform(macos | ios | linux | android)
pub unsafe fn sc_jobserver_init(capacity: i32) i32 {
    if unsafe jobserver_load() {
        return 1;
    }
    let n = js_extra_slots(capacity);
    let dir = stdlib::getenv("TMPDIR");
    let mut path = if dir != null && unsafe dir[0] != 0 as char {
        unsafe String::from_cstr(dir);
    } else {
        String::from_str("/tmp");
    };
    path.push_str("/super-c-jobs-XXXXXX");
    if path.len() >= 1024 {
        return 0;
    }
    // No FD_CLOEXEC: every process the tree starts inherits the descriptor.
    let fd = unsafe mkstemp(path.cstr() as *mut char);
    if fd < 0 {
        return 0;
    }
    if unsafe unlink(path.cstr()) != 0 {
        unsafe unistd::close(fd);
        return 0;
    }
    let mut text = String::new();
    text.format_into("{},{}", n, fd);
    if unsafe setenv("SC_JOBSERVER".ptr() as *const char, text.cstr(), 1) != 0 {
        unsafe unistd::close(fd);
        return 0;
    }
    unsafe JS_FD = fd;
    unsafe JS_SLOTS = n;
    unsafe JS_LOADED = true;
    return 1;
}

// Lock (`lock`) or unlock slot byte `i`: 1 done, 0 another process holds it, -1 an error.
@platform(macos | ios | linux | android)
unsafe fn jobserver_lock(i: i32, lock: bool) i32 {
    let mut fl = unsafe zeroed::<flock>();
    fl.l_type = if lock {
        F_WRLCK as i16;
    } else {
        F_UNLCK as i16;
    };
    fl.l_whence = stdio::SEEK_SET as i16;
    fl.l_start = i;
    fl.l_len = 1;
    // Bounded by the signals that interrupt the call.
    loop {
        if unsafe fcntl::fcntl(JS_FD, F_SETLK, &mut fl) == 0 {
            return 1;
        }
        let e = errno::errno();
        if e != EINTR {
            if lock && (e == EACCES || e == EAGAIN) {
                return 0;
            }
            return -1;
        }
    }
}

/// Create the process-tree jobserver when none exists. Returns 1 when a shared budget is active.
@platform(wasm)
pub unsafe fn sc_jobserver_init(_capacity: i32) i32 {
    return 0;
}

@platform(wasm)
unsafe fn jobserver_load() bool {
    return false;
}

@platform(wasm)
unsafe fn jobserver_lock(_i: i32, _lock: bool) i32 {
    return -1;
}

// Take a free slot: true, or false when every slot is held. A lock error is fatal: the tree's budget is gone.
unsafe fn jobserver_try_acquire() bool {
    if !unsafe jobserver_load() {
        return false;
    }
    for i in 0..unsafe JS_SLOTS {
        if unsafe JS_OWN[i as usize] {
            continue;
        }
        let r = unsafe jobserver_lock(i, true);
        if r < 0 {
            stdlib::abort();
        }
        if r == 1 {
            unsafe JS_OWN[i as usize] = true;
            return true;
        }
    }
    return false;
}

// Give back one held slot: true, or false when this process holds none.
unsafe fn jobserver_release() bool {
    if !unsafe jobserver_load() {
        return false;
    }
    for i in 0..unsafe JS_SLOTS {
        if unsafe JS_OWN[i as usize] {
            if unsafe jobserver_lock(i, false) != 1 {
                stdlib::abort();
            }
            unsafe JS_OWN[i as usize] = false;
            return true;
        }
    }
    return false;
}

/// Return all extra worker slots before this process waits on child work.
pub unsafe fn sc_jobserver_release_claim() {
    while unsafe JS_CLAIMED > 1 {
        if !unsafe jobserver_release() {
            stdlib::abort();
        }
        unsafe JS_CLAIMED -= 1;
    }
    unsafe JS_CLAIMED = 0;
}

fn release_claim_at_exit() {
    unsafe sc_jobserver_release_claim();
}

/// Reserve up to `wanted` worker slots, including this process's inherited slot.
pub unsafe fn sc_jobserver_claim(wanted: i32) i32 {
    let want = wanted.max(1);
    if !unsafe jobserver_load() {
        return want;
    }
    if unsafe JS_CLAIMED != 0 {
        return unsafe JS_CLAIMED;
    }
    unsafe JS_CLAIMED = 1;
    while unsafe JS_CLAIMED < want && unsafe jobserver_try_acquire() {
        unsafe JS_CLAIMED += 1;
    }
    if !unsafe JS_RELEASE_REGISTERED {
        if unsafe stdlib::atexit(release_claim_at_exit) != 0 {
            stdlib::abort();
        }
        unsafe JS_RELEASE_REGISTERED = true;
    }
    return unsafe JS_CLAIMED;
}

// ---- Crash trace -----------------------------------------------------------------------------------

// Every panic ends in abort(), which raises SIGABRT before the process dies: a handler is the one place a
// stack survives to be printed. POSIX prints symbolized frames; Windows has no DWARF-aware symbolizer at
// run time, so it prints each return address as an offset from the PE base (stable under ASLR) for
// addr2line against the same binary.
@platform(macos | ios | linux | android)
fn trace_abort(_sig: i32) {
    let mut bt: [*mut void; 32] = [null as *mut void; 32];
    let n = unsafe backtrace(&mut bt[0], 32);
    unsafe backtrace_symbols_fd(&bt[0], n, 2);
}
@platform(windows)
fn trace_abort(_sig: i32) {
    let mut bt: [*mut void; 32] = [null as *mut void; 32];
    let n = unsafe RtlCaptureStackBackTrace(0, 32, &mut bt[0], null);
    let base = unsafe GetModuleHandleA(null);
    unsafe stdio::fprintf(stdio::stderr(), "trace: base %p\n".ptr() as *const char, base);
    for i in 0..n as usize {
        let off = ((unsafe bt[i]) as usize).wrapping_sub(base as usize) as u64;
        unsafe stdio::fprintf(stdio::stderr(), "trace: +0x%llx\n".ptr() as *const char, off);
    }
    unsafe stdio::fflush(stdio::stderr());
}

/// Install the crash handler that prints a backtrace on SIGABRT: every panic aborts, and would die
/// silent otherwise. A no-op under WASI, which has neither signals nor a backtrace.
@platform(!wasm)
pub unsafe fn sc_trace_install() {
    unsafe signal::signal(signal::SIGABRT, trace_abort);
}
/// Install the crash handler that prints a backtrace on SIGABRT: every panic aborts, and would die
/// silent otherwise. A no-op under WASI, which has neither signals nor a backtrace.
@platform(wasm)
pub unsafe fn sc_trace_install() {}
