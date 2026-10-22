// Processes of std::platform: start a program with exact argument bytes and no shell, wait for it (one
// child, any of several, or without blocking), end it, and the facts of the running process: its id, its
// executable, its working directory, its peak memory and its open-file limit; plus pipes. POSIX starts
// children with posix_spawn, Windows with CreateProcessW over a command line quoted for the C runtime's
// parser. WASI has no processes: `spawn`, `pipe` and the process queries are Unsupported there.
// Unstable, internal to std and the compiler.
import errno;
import fcntl;
import string as cstring;
import unistd;
import std::platform::env;
import std::platform::error;
import std::platform::fs;
import std::platform::path;
import std::text::utf16;

// ---- C bindings: POSIX ------------------------------------------------------------------------------

@platform(macos | ios)
type mode_t = u16;
@platform(linux | android)
type mode_t = u32;

// glibc's file actions are a structure; Darwin's and bionic's a pointer to one.
@platform(macos | ios | android)
extern "C" "spawn.h" {
    @layout(sizeof(usize), sizeof(usize))
    type posix_spawn_file_actions_t;
}
@platform(linux)
extern "C" "spawn.h" {
    @layout(80, 8)
    type posix_spawn_file_actions_t;
}
@platform(macos | ios | linux | android)
extern "C" "spawn.h" {
    type posix_spawnattr_t;
    fn posix_spawn(
        pid: *mut i32,
        path: *const char,
        actions: *const posix_spawn_file_actions_t,
        attr: *const posix_spawnattr_t,
        argv: *const *mut char,
        envp: *const *mut char,
    ) i32;
    fn posix_spawnp(
        pid: *mut i32,
        file: *const char,
        actions: *const posix_spawn_file_actions_t,
        attr: *const posix_spawnattr_t,
        argv: *const *mut char,
        envp: *const *mut char,
    ) i32;
    fn posix_spawn_file_actions_init(fa: *mut posix_spawn_file_actions_t) i32;
    fn posix_spawn_file_actions_destroy(fa: *mut posix_spawn_file_actions_t) i32;
    fn posix_spawn_file_actions_addopen(
        fa: *mut posix_spawn_file_actions_t,
        fd: i32,
        path: *const char,
        oflag: i32,
        mode: mode_t,
    ) i32;
    fn posix_spawn_file_actions_adddup2(fa: *mut posix_spawn_file_actions_t, fd: i32, newfd: i32) i32;
}

// The chdir file action of Darwin and glibc, which `<spawn.h>` declares only above the build's feature
// level: a block without a header declares it. macOS 26 deprecates the name for the POSIX 2024 one,
// which older systems lack.
@platform(macos | linux)
extern "C" {
    fn posix_spawn_file_actions_addchdir_np(fa: *mut posix_spawn_file_actions_t, path: *const char) i32;
}

@platform(macos | ios | linux | android)
extern "C" "sys/wait.h" {
    fn waitpid(pid: i32, status: *mut i32, options: i32) i32;
    const WNOHANG: i32;
}

@platform(macos | ios | linux | android)
extern "C" "signal.h" {
    @import("kill")
    fn c_kill(pid: i32, sig: i32) i32;
    const SIGKILL: i32;
}

@platform(macos | ios | linux | android)
extern "C" "errno.h" {
    const EPERM: i32;
    const ESRCH: i32;
}

@platform(!windows)
extern "C" "errno.h" {
    const ERANGE: i32;
}

// `struct rusage` as the build's feature level declares it: Darwin then folds the counters into
// `ru_opaque`, whose first word is `ru_maxrss` (bytes); glibc keeps the names (KiB).
@platform(macos | ios)
extern "C" "sys/resource.h" {
    struct timeval {
        pub tv_sec: isize,
        pub tv_usec: i32,
    }
    struct rusage {
        pub ru_utime: timeval,
        pub ru_stime: timeval,
        pub ru_opaque: [isize; 14],
    }
}
@platform(linux | android)
extern "C" "sys/resource.h" {
    struct timeval {
        pub tv_sec: i64,
        pub tv_usec: isize,
    }
    struct rusage {
        pub ru_utime: timeval,
        pub ru_stime: timeval,
        pub ru_maxrss: isize,
        pub ru_ixrss: isize,
        pub ru_idrss: isize,
        pub ru_isrss: isize,
        pub ru_minflt: isize,
        pub ru_majflt: isize,
        pub ru_nswap: isize,
        pub ru_inblock: isize,
        pub ru_oublock: isize,
        pub ru_msgsnd: isize,
        pub ru_msgrcv: isize,
        pub ru_nsignals: isize,
        pub ru_nvcsw: isize,
        pub ru_nivcsw: isize,
    }
}
@platform(macos | ios | linux | android)
extern "C" "sys/resource.h" {
    struct rlimit {
        pub rlim_cur: u64,
        pub rlim_max: u64,
    }
    fn getrusage(who: i32, usage: *mut rusage) i32;
    fn getrlimit(resource: i32, rl: *mut rlimit) i32;
    fn setrlimit(resource: i32, rl: *const rlimit) i32;
    const RUSAGE_SELF: i32;
    const RLIMIT_NOFILE: i32;
    const RLIM_INFINITY: u64;
}

@platform(macos | ios)
extern "C" "mach-o/dyld.h" {
    fn _NSGetExecutablePath(buf: *mut char, size: *mut u32) i32;
}

@platform(linux | android)
extern "C" "unistd.h" {
    fn pipe2(fds: *mut i32, flags: i32) i32;
}

// ---- C bindings: Windows ----------------------------------------------------------------------------

@platform(windows)
extern "C" "windows.h" {
    @import("SECURITY_ATTRIBUTES")
    struct SECURITY_ATTRIBUTES {
        pub nLength: u32,
        pub lpSecurityDescriptor: *mut void,
        pub bInheritHandle: i32,
    }
    @import("STARTUPINFOW")
    struct STARTUPINFOW {
        pub cb: u32,
        pub lpReserved: *mut u16,
        pub lpDesktop: *mut u16,
        pub lpTitle: *mut u16,
        pub dwX: u32,
        pub dwY: u32,
        pub dwXSize: u32,
        pub dwYSize: u32,
        pub dwXCountChars: u32,
        pub dwYCountChars: u32,
        pub dwFillAttribute: u32,
        pub dwFlags: u32,
        pub wShowWindow: u16,
        pub cbReserved2: u16,
        pub lpReserved2: *mut u8,
        pub hStdInput: *mut void,
        pub hStdOutput: *mut void,
        pub hStdError: *mut void,
    }
    @import("PROCESS_INFORMATION")
    struct PROCESS_INFORMATION {
        pub hProcess: *mut void,
        pub hThread: *mut void,
        pub dwProcessId: u32,
        pub dwThreadId: u32,
    }

    // A `DWORD *` parameter is `*mut void`: DWORD is C `unsigned long`, which no Super-C type spells.
    fn CreateProcessW(
        app: *const u16,
        cmd: *mut u16,
        process_security: *mut SECURITY_ATTRIBUTES,
        thread_security: *mut SECURITY_ATTRIBUTES,
        inherit: i32,
        flags: u32,
        env: *mut void,
        cwd: *const u16,
        si: *mut STARTUPINFOW,
        pi: *mut PROCESS_INFORMATION,
    ) i32;
    fn CreateFileW(
        path: *const u16,
        access: u32,
        share: u32,
        security: *mut SECURITY_ATTRIBUTES,
        disposition: u32,
        flags: u32,
        template: *mut void,
    ) *mut void;
    fn CreatePipe(read: *mut *mut void, write: *mut *mut void, security: *mut SECURITY_ATTRIBUTES, size: u32) i32;
    fn DuplicateHandle(
        src_process: *mut void,
        src: *mut void,
        dst_process: *mut void,
        dst: *mut *mut void,
        access: u32,
        inherit: i32,
        options: u32,
    ) i32;
    fn CloseHandle(h: *mut void) i32;
    fn GetStdHandle(which: u32) *mut void;
    fn GetCurrentProcess() *mut void;
    fn GetCurrentProcessId() u32;
    fn OpenProcess(access: u32, inherit: i32, pid: u32) *mut void;
    fn GetExitCodeProcess(h: *mut void, code: *mut void) i32;
    fn TerminateProcess(h: *mut void, code: u32) i32;
    fn WaitForSingleObject(h: *mut void, ms: u32) u32;
    fn WaitForMultipleObjects(n: u32, handles: *const *mut void, all: i32, ms: u32) u32;
    fn GetModuleFileNameW(module: *mut void, buf: *mut u16, size: u32) u32;
    fn GetCurrentDirectoryW(size: u32, buf: *mut u16) u32;
    fn SetCurrentDirectoryW(path: *const u16) i32;
    fn GetLastError() u32;

    const INVALID_HANDLE_VALUE: *mut void;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    const FILE_SHARE_READ: u32 = 1;
    const FILE_SHARE_WRITE: u32 = 2;
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const FILE_APPEND_DATA: u32 = 4;
    const SYNCHRONIZE: u32 = 0x00100000;
    const CREATE_ALWAYS: u32 = 2;
    const OPEN_EXISTING: u32 = 3;
    const STARTF_USESTDHANDLES: u32 = 0x100;
    const STD_INPUT_HANDLE: u32 = 0xFFFFFFF6;
    const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5;
    const STD_ERROR_HANDLE: u32 = 0xFFFFFFF4;
    const DUPLICATE_SAME_ACCESS: u32 = 2;
    const CREATE_UNICODE_ENVIRONMENT: u32 = 0x400;
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const STILL_ACTIVE: u32 = 0x103;
    const INFINITE: u32 = 0xFFFFFFFF;
    const WAIT_OBJECT_0: u32 = 0;
    const WAIT_TIMEOUT: u32 = 258;
    const MAXIMUM_WAIT_OBJECTS: u32 = 64;
    const ERROR_ACCESS_DENIED: u32 = 5;
    const ERROR_INVALID_PARAMETER: u32 = 87;
    const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
}

// From PSAPI version 2 on, `GetProcessMemoryInfo` names `K32GetProcessMemoryInfo`, which kernel32
// exports: no psapi library is linked.
@platform(windows)
extern "C" "psapi.h" {
    @import("PROCESS_MEMORY_COUNTERS")
    struct PROCESS_MEMORY_COUNTERS {
        pub cb: u32,
        pub PageFaultCount: u32,
        pub PeakWorkingSetSize: usize,
        pub WorkingSetSize: usize,
        pub QuotaPeakPagedPoolUsage: usize,
        pub QuotaPagedPoolUsage: usize,
        pub QuotaPeakNonPagedPoolUsage: usize,
        pub QuotaNonPagedPoolUsage: usize,
        pub PagefileUsage: usize,
        pub PeakPagefileUsage: usize,
    }
    fn K32GetProcessMemoryInfo(process: *mut void, pmc: *mut PROCESS_MEMORY_COUNTERS, cb: u32) i32;
}

// ---- Types ------------------------------------------------------------------------------------------

/// How a child process ended.
pub enum ExitStatus {
    /// It exited with this code (the low 8 bits on POSIX; the whole 32-bit code on Windows).
    Code(i32),
    /// A signal ended it (POSIX only).
    Signal(i32),
}

/// Where a child's standard stream goes.
pub enum Redirect<'a> {
    /// The stream this process has.
    Inherit,
    /// The null device: reads see the end at once, writes vanish.
    Null,
    /// A file: read for standard input; for output created or truncated, then opened to append, so
    /// processes the child starts and that share the stream never overwrite each other.
    Path(str<'a>),
    /// An open file or pipe end of this process, which the child gets a copy of.
    Handle(&'a fs::File),
    /// For standard error only: the same target as standard output (`2>&1`).
    Stdout,
}

/// What `spawn` starts.
pub struct Command<'a> {
    /// The arguments; `argv[0]` names the program, searched in PATH when it holds no separator (on
    /// Windows the system's search, which also tries `.exe`). It reaches the child as written.
    pub argv: Slice<'a, str<'a>>,
    /// The file to run instead of looking up `argv[0]`; when it does not start, POSIX falls back to the
    /// lookup of `argv[0]`.
    pub program: Option<str<'a>>,
    /// The child's whole environment as `NAME=VALUE` entries; None passes this process's.
    pub env: Option<Slice<'a, str<'a>>>,
    /// The child's working directory; None keeps this process's. Unsupported on iOS and Android.
    pub cwd: Option<str<'a>>,
    /// Windows only: the command line the child receives, as written, in place of the one quoted from
    /// `argv` (which may then be empty); its first word names the program, searched as for `argv[0]`.
    /// Unsupported on the other targets.
    pub command_line: Option<str<'a>>,
    pub stdin: Redirect<'a>,
    pub stdout: Redirect<'a>,
    pub stderr: Redirect<'a>,
}

/// A started child process. Dropping it neither waits for nor ends the child; wait for every child, or
/// it stays a zombie until this process ends (POSIX).
@no_const
pub struct Child {
    raw: ChildRaw,
    pid: u32,
    status: Option<ExitStatus>, // set once a wait reaped it
}

// What names a child to the system: its pid on POSIX (and WASI, where none exists), its process handle
// on Windows.
@platform(!windows)
type ChildRaw = i32;
@platform(windows)
type ChildRaw = *mut void;

// ---- Spawning ---------------------------------------------------------------------------------------

/// Start `cmd`. InvalidInput for an empty `argv`, a NUL byte in an argument, an environment entry or a
/// path, or `Redirect::Stdout` on standard input or output; NotFound when the program does not exist.
@platform(macos | ios | linux | android)
pub fn spawn(cmd: Command) Result<Child, IoError> {
    if cmd.command_line.is_some() {
        return Result::<Child, IoError>::Err(error::unsupported(IoOp::Spawn));
    }
    if cmd.argv.len() == 0 || stdout_misused(&cmd) {
        return invalid::<Child>(IoOp::Spawn);
    }
    // Every string of argv and envp in one buffer, then the pointer arrays: offsets first, since the
    // buffer moves while it grows.
    let mut text = String::new();
    let mut offs = Vector::<usize>::new();
    if !pack(&mut text, &mut offs, cmd.argv) {
        return invalid::<Child>(IoOp::Spawn);
    }
    let nargs = offs.len();
    if let Some(env) = cmd.env {
        if !pack(&mut text, &mut offs, env) {
            return invalid::<Child>(IoOp::Spawn);
        }
    }
    let base = text.as_ptr() as *mut char;
    let mut ptrs = Vector::<*mut char>::with_capacity(offs.len() + 2);
    for i in 0..nargs {
        ptrs.push(unsafe (base + *offs.at(i)));
    }
    ptrs.push(null);
    for i in nargs..offs.len() {
        ptrs.push(unsafe (base + *offs.at(i)));
    }
    ptrs.push(null);
    let argv = ptrs.as_ptr();
    let envp: *const *mut char = if cmd.env.is_some() {
        unsafe (argv + nargs + 1);
    } else {
        unsafe env::environ();
    };
    let mut fa = unsafe zeroed::<posix_spawn_file_actions_t>();
    unsafe posix_spawn_file_actions_init(&mut fa);
    let r = spawn_with(&cmd, &mut fa, argv, envp);
    unsafe posix_spawn_file_actions_destroy(&mut fa);
    return r;
}
/// Start `cmd`. InvalidInput for an empty `argv`, a NUL byte in an argument, an environment entry or a
/// path, or `Redirect::Stdout` on standard input or output; NotFound when the program does not exist.
@platform(windows)
pub fn spawn(cmd: Command) Result<Child, IoError> {
    if cmd.argv.len() == 0 && cmd.command_line.is_none() || stdout_misused(&cmd) {
        return invalid::<Child>(IoOp::Spawn);
    }
    let mut line = String::new();
    if let Some(l) = cmd.command_line {
        line.push_str(l);
    } else {
        for i in 0..cmd.argv.len() {
            if i != 0 {
                line.push_byte(b' ');
            }
            win_quote_into(&mut line, cmd.argv[i]);
        }
    }
    let wline = path::native(line.as_str(), IoOp::Spawn)?;
    let mut block = Vector::<u16>::new();
    let mut flags: u32 = 0;
    if let Some(env) = cmd.env {
        flags = CREATE_UNICODE_ENVIRONMENT;
        for e in env {
            if e.find_byte(0) >= 0 || utf16::encode(e, &mut block).is_err() {
                return invalid::<Child>(IoOp::Spawn);
            }
            block.push(0);
        }
        if block.len() == 0 {
            block.push(0);
        }
        block.push(0);
    }
    let program = if let Some(p) = cmd.program {
        Option::<path::NativePath>::Some(path::native(p, IoOp::Spawn)?);
    } else {
        Option::<path::NativePath>::None;
    };
    let cwd = if let Some(d) = cmd.cwd {
        Option::<path::NativePath>::Some(path::native(d, IoOp::Spawn)?);
    } else {
        Option::<path::NativePath>::None;
    };
    let mut si = unsafe zeroed::<STARTUPINFOW>();
    si.cb = sizeof(STARTUPINFOW) as u32;
    let mut owned = StdHandles::empty();
    let redirected = !cmd.stdin.is_inherit() || !cmd.stdout.is_inherit() || !cmd.stderr.is_inherit();
    if redirected {
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = owned.take(child_handle(&cmd.stdin, STD_INPUT_HANDLE, false)?);
        si.hStdOutput = owned.take(child_handle(&cmd.stdout, STD_OUTPUT_HANDLE, true)?);
        si.hStdError = if cmd.stderr.is_stdout() {
            si.hStdOutput;
        } else {
            owned.take(child_handle(&cmd.stderr, STD_ERROR_HANDLE, true)?);
        };
    }
    let app: *const u16 = if let Some(p) = &program {
        p.ptr();
    } else {
        null;
    };
    let dir: *const u16 = if let Some(d) = &cwd {
        d.ptr();
    } else {
        null;
    };
    let envp: *mut void = if cmd.env.is_some() {
        block.index_range_mut(0..block.len()).as_mut_ptr();
    } else {
        null;
    };
    let mut pi = unsafe zeroed::<PROCESS_INFORMATION>();
    let ok = unsafe CreateProcessW(app, wline.ptr() as *mut u16, null, null, 1, flags, envp, dir, &mut si, &mut pi) != 0;
    if !ok {
        return fail::<Child>(IoOp::Spawn);
    }
    unsafe CloseHandle(pi.hThread);
    return Result::<Child, IoError>::Ok(Child::adopt(pi.hProcess, pi.dwProcessId));
}
/// Start `cmd`. Unsupported: WASI has no processes.
@platform(wasm)
pub fn spawn(_cmd: Command) Result<Child, IoError> {
    return Result::<Child, IoError>::Err(error::unsupported(IoOp::Spawn));
}

@platform(!wasm)
const fn stdout_misused(cmd: &Command) bool {
    return cmd.stdin.is_stdout() || cmd.stdout.is_stdout();
}

// Append each of `items` to `text` with a NUL, recording its offset: false when one holds a NUL.
@platform(macos | ios | linux | android)
fn pack(text: &mut String, offs: &mut Vector<usize>, items: []str) bool {
    for s in items {
        if s.find_byte(0) >= 0 {
            return false;
        }
        offs.push(text.len());
        text.push_str(s);
        text.push_byte(0);
    }
    return true;
}

// Fill the file actions `fa` from `cmd` and start it with `argv` and `envp`.
@platform(macos | ios | linux | android)
fn spawn_with(cmd: &Command, fa: &mut posix_spawn_file_actions_t, argv: *const *mut char, envp: *const *mut char) Result<
    Child,
    IoError
> {
    // The native paths live until the spawn: the file actions keep pointers to them.
    let p0 = add_redirect(fa, &cmd.stdin, 0)?;
    let p1 = add_redirect(fa, &cmd.stdout, 1)?;
    let p2 = add_redirect(fa, &cmd.stderr, 2)?;
    let mut dir = Option::<path::NativePath>::None;
    if let Some(d) = cmd.cwd {
        let nd = path::native(d, IoOp::Spawn)?;
        add_chdir(fa, nd.ptr())?;
        dir = Option::<path::NativePath>::Some(nd);
    }
    let mut pid: i32 = 0;
    // posix_spawnp makes a whole spawn attempt per PATH entry: a program found once starts by its path.
    // A path that does not start falls back to the search.
    let mut rc: i32 = -1;
    if let Some(p) = cmd.program {
        let np = path::native(p, IoOp::Spawn)?;
        rc = unsafe posix_spawn(&mut pid, np.ptr(), fa, null, argv, envp);
    }
    if rc != 0 {
        rc = unsafe posix_spawnp(&mut pid, unsafe *argv, fa, null, argv, envp);
    }
    let _ = (p0, p1, p2, dir);
    if rc != 0 {
        return Result::<Child, IoError>::Err(error::code_error(rc, IoOp::Spawn));
    }
    return Result::<Child, IoError>::Ok(Child::adopt(pid, pid as u32));
}

// Add the file action of redirect `r` for descriptor `fd`: the native path it opens, which must live until
// the spawn, when it opens one.
@platform(macos | ios | linux | android)
fn add_redirect(fa: &mut posix_spawn_file_actions_t, r: &Redirect, fd: i32) Result<Option<path::NativePath>, IoError> {
    let none = Option::<path::NativePath>::None;
    let wflags = fcntl::O_WRONLY | fcntl::O_CREAT | fcntl::O_TRUNC | fcntl::O_APPEND;
    let rc = switch *r {
        Inherit => 0,
        Null => {
            let flags = if fd == 0 {
                fcntl::O_RDONLY;
            } else {
                fcntl::O_WRONLY;
            };
            unsafe posix_spawn_file_actions_addopen(fa, fd, "/dev/null".ptr() as *const char, flags, 0);
        },
        Path(p) => {
            let np = path::native(p, IoOp::Spawn)?;
            let flags = if fd == 0 {
                fcntl::O_RDONLY;
            } else {
                wflags;
            };
            let rc = unsafe posix_spawn_file_actions_addopen(fa, fd, np.ptr(), flags, 0o644);
            if rc != 0 {
                return Result::<Option<path::NativePath>, IoError>::Err(error::code_error(rc, IoOp::Spawn));
            }
            return Result::<Option<path::NativePath>, IoError>::Ok(Option::<path::NativePath>::Some(np));
        },
        Handle(f) => unsafe posix_spawn_file_actions_adddup2(fa, f.raw(), fd),
        Stdout => unsafe posix_spawn_file_actions_adddup2(fa, 1, 2),
    };
    if rc != 0 {
        return Result::<Option<path::NativePath>, IoError>::Err(error::code_error(rc, IoOp::Spawn));
    }
    return Result::<Option<path::NativePath>, IoError>::Ok(none);
}

// Add the working directory `cwd` to the spawn actions: Unsupported where the C library has no such
// action (bionic, iOS).
@platform(macos | linux)
fn add_chdir(fa: &mut posix_spawn_file_actions_t, cwd: *const char) Result<Unit, IoError> {
    let rc = unsafe posix_spawn_file_actions_addchdir_np(fa, cwd);
    if rc != 0 {
        return Result::<Unit, IoError>::Err(error::code_error(rc, IoOp::Spawn));
    }
    return Result::<Unit, IoError>::Ok(Unit {});
}
@platform(ios | android)
fn add_chdir(_fa: &mut posix_spawn_file_actions_t, _cwd: *const char) Result<Unit, IoError> {
    return Result::<Unit, IoError>::Err(error::unsupported(IoOp::Spawn));
}

// The handles a Windows spawn opened for its child: closed once CreateProcessW has copied them.
@platform(windows)
struct StdHandles {
    pub hs: [*mut void; 3],
    pub n: usize,
}

@platform(windows)
extend StdHandles {
    pub fn empty() StdHandles {
        return StdHandles { hs: [null as *mut void; 3], n: 0 };
    }
    // Keep `h` (owned, or `(h, false)` borrowed) for the child: its value.
    pub fn take(self: &mut StdHandles, h: (*mut void, bool)) *mut void {
        let (v, own) = h;
        if own {
            unsafe self.hs[self.n] = v;
            self.n += 1;
        }
        return v;
    }
}

@platform(windows)
extend StdHandles as Free {
    pub fn free(self: &mut StdHandles) {
        for i in 0..self.n {
            unsafe CloseHandle(unsafe self.hs[i]);
        }
    }
}

// The inheritable handle redirect `r` gives the child's stream `which` (an output when `write`), and
// whether the spawn owns it. An output file is created or truncated first, then opened again to append:
// FILE_APPEND_DATA puts each write at the end whatever position another writer has.
@platform(windows)
fn child_handle(r: &Redirect, which: u32, write: bool) Result<(*mut void, bool), IoError> {
    let mut sa = SECURITY_ATTRIBUTES {
        nLength: sizeof(SECURITY_ATTRIBUTES) as u32,
        lpSecurityDescriptor: null,
        bInheritHandle: 1,
    };
    let share = FILE_SHARE_READ | FILE_SHARE_WRITE;
    switch *r {
        Inherit => {
            return Result::<(*mut void, bool), IoError>::Ok((unsafe GetStdHandle(which), false));
        },
        Handle(f) => {
            let me = unsafe GetCurrentProcess();
            let mut h: *mut void = null;
            if unsafe DuplicateHandle(me, f.raw(), me, &mut h, 0, 1, DUPLICATE_SAME_ACCESS) == 0 {
                return fail::<(*mut void, bool)>(IoOp::Spawn);
            }
            return Result::<(*mut void, bool), IoError>::Ok((h, true));
        },
        Stdout => {
            return invalid::<(*mut void, bool)>(IoOp::Spawn);
        },
        _ => {},
    };
    let name = if let Path(p) = *r {
        p;
    } else {
        "NUL";
    };
    let np = path::native(name, IoOp::Spawn)?;
    let mut h = INVALID_HANDLE_VALUE;
    if !write {
        h = unsafe CreateFileW(np.ptr(), GENERIC_READ, share, &mut sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    } else {
        let trunc = unsafe CreateFileW(np.ptr(), GENERIC_WRITE, share, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        if trunc == INVALID_HANDLE_VALUE {
            return fail::<(*mut void, bool)>(IoOp::Spawn);
        }
        unsafe CloseHandle(trunc);
        let append = FILE_APPEND_DATA | SYNCHRONIZE;
        h = unsafe CreateFileW(np.ptr(), append, share, &mut sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    }
    if h == INVALID_HANDLE_VALUE {
        return fail::<(*mut void, bool)>(IoOp::Spawn);
    }
    return Result::<(*mut void, bool), IoError>::Ok((h, true));
}

// Append argument `a` to a CreateProcess command line as the C runtime's parser reads it back: quoted
// when it holds a space, a tab or a quote, or is empty; inside quotes, N backslashes before a '"' become
// 2N+1, and trailing backslashes double so the closing quote survives.
@platform(windows)
fn win_quote_into(w: &mut String, a: str) {
    let mut plain = a.len() != 0;
    for i in 0..a.len() {
        let c = a.byte_at(i);
        if c == b' ' || c == b'\t' || c == b'"' {
            plain = false;
        }
    }
    if plain {
        w.push_str(a);
        return;
    }
    w.push_byte(b'"');
    let mut bs: usize = 0;
    for i in 0..a.len() {
        let c = a.byte_at(i);
        if c == b'\\' {
            bs += 1;
            w.push_byte(b'\\');
        } else if c == b'"' {
            for _ in 0..bs + 1 {
                w.push_byte(b'\\');
            }
            bs = 0;
            w.push_byte(b'"');
        } else {
            bs = 0;
            w.push_byte(c);
        }
    }
    for _ in 0..bs {
        w.push_byte(b'\\');
    }
    w.push_byte(b'"');
}

// ---- Waiting ----------------------------------------------------------------------------------------

/// Block until one of `children` that has not been waited for ends: its index and status. Children
/// already reaped are skipped. POSIX reaps through `waitpid(-1)`, so a child of this process outside
/// `children` that ends meanwhile is reaped and lost; InvalidInput when no child is left to wait for.
@platform(macos | ios | linux | android)
pub fn wait_any(children: []mut Child) Result<(usize, ExitStatus), IoError> {
    if first_live(children) == children.len() {
        return invalid::<(usize, ExitStatus)>(IoOp::Wait);
    }
    // Bounded by this process's children: each pass reaps one.
    loop {
        let mut st: i32 = 0;
        let p = unsafe waitpid(-1, &mut st, 0);
        if p < 0 {
            if error::interrupted() {
                continue;
            }
            return fail::<(usize, ExitStatus)>(IoOp::Wait);
        }
        for i in 0..children.len() {
            if let Some(s) = children[i].reap_if(p, st) {
                return Result::<(usize, ExitStatus), IoError>::Ok((i, s));
            }
        }
    }
}
/// Block until one of `children` that has not been waited for ends: its index and status. Children
/// already reaped are skipped. POSIX reaps through `waitpid(-1)`, so a child of this process outside
/// `children` that ends meanwhile is reaped and lost; InvalidInput when no child is left to wait for.
@platform(windows)
pub fn wait_any(children: []mut Child) Result<(usize, ExitStatus), IoError> {
    if first_live(children) == children.len() {
        return invalid::<(usize, ExitStatus)>(IoOp::Wait);
    }
    // WaitForMultipleObjects takes 64 handles: more children are polled in groups, with a 10 ms wait on
    // the first group between rounds. Ends when one child ends.
    loop {
        let first_ms = if children.len() <= 64 {
            INFINITE;
        } else {
            0;
        };
        if let Some(r) = wait_group(children, 0, first_ms)? {
            return Result::<(usize, ExitStatus), IoError>::Ok(r);
        }
        let mut from: usize = 64;
        while from < children.len() {
            if let Some(r) = wait_group(children, from, 0)? {
                return Result::<(usize, ExitStatus), IoError>::Ok(r);
            }
            from += 64;
        }
        if let Some(r) = wait_group(children, 0, 10)? {
            return Result::<(usize, ExitStatus), IoError>::Ok(r);
        }
    }
}
/// Block until one of `children` ends. Unsupported: WASI has no processes.
@platform(wasm)
pub fn wait_any(_children: []mut Child) Result<(usize, ExitStatus), IoError> {
    return Result::<(usize, ExitStatus), IoError>::Err(error::unsupported(IoOp::Wait));
}

/// One of `children` that has already ended, with its status, without blocking; None when every one
/// still runs. Never reaps a process outside `children`.
pub fn try_wait_any(children: []mut Child) Result<Option<(usize, ExitStatus)>, IoError> {
    for i in 0..children.len() {
        if children[i].reaped() {
            continue;
        }
        if let Some(s) = children[i].try_wait()? {
            return Result::<Option<(usize, ExitStatus)>, IoError>::Ok(Option::<(usize, ExitStatus)>::Some((i, s)));
        }
    }
    return Result::<Option<(usize, ExitStatus)>, IoError>::Ok(Option::<(usize, ExitStatus)>::None);
}

@platform(!wasm)
fn first_live(children: []mut Child) usize {
    for i in 0..children.len() {
        if !children[i].reaped() {
            return i;
        }
    }
    return children.len();
}

// Wait up to `ms` for any live child of the 64 from `from`: its index and status, None on timeout.
@platform(windows)
fn wait_group(children: []mut Child, from: usize, ms: u32) Result<Option<(usize, ExitStatus)>, IoError> {
    let mut hs: [*mut void; 64] = [null as *mut void; 64];
    let mut at: [usize; 64] = [0; 64];
    let mut n: usize = 0;
    let end = (from + 64).min(children.len());
    for i in from..end {
        if !children[i].reaped() {
            unsafe hs[n] = children[i].raw_handle();
            unsafe at[n] = i;
            n += 1;
        }
    }
    if n == 0 {
        return Result::<Option<(usize, ExitStatus)>, IoError>::Ok(Option::<(usize, ExitStatus)>::None);
    }
    let w = unsafe WaitForMultipleObjects(n as u32, &hs[0], 0, ms);
    if w == WAIT_TIMEOUT {
        return Result::<Option<(usize, ExitStatus)>, IoError>::Ok(Option::<(usize, ExitStatus)>::None);
    }
    if w >= n as u32 {
        return fail::<Option<(usize, ExitStatus)>>(IoOp::Wait);
    }
    let i = unsafe at[w as usize];
    let s = children[i].exit_code()?;
    return Result::<Option<(usize, ExitStatus)>, IoError>::Ok(Option::<(usize, ExitStatus)>::Some((i, s)));
}

// The status `waitpid` reported as `st`: the low 7 bits are the signal that ended the child (0: it
// exited, 0x7f: it stopped), bits 8 to 15 its exit code.
@platform(macos | ios | linux | android)
const fn status_of(st: i32) ExitStatus {
    if (st & 0x7f) == 0 {
        return ExitStatus::Code(st >> 8 & 0xff);
    }
    return ExitStatus::Signal(st & 0x7f);
}

// ---- The running process ----------------------------------------------------------------------------

/// This process's id. Unsupported on WASI, which has no process ids.
@platform(!wasm)
pub fn pid() Result<u32, IoError> {
    return Result::<u32, IoError>::Ok(os_pid());
}
/// This process's id. Unsupported on WASI, which has no process ids.
@platform(wasm)
pub fn pid() Result<u32, IoError> {
    return Result::<u32, IoError>::Err(error::unsupported(IoOp::ProcessId));
}

@platform(macos | ios | linux | android)
fn os_pid() u32 {
    return unistd::getpid() as u32;
}
@platform(windows)
fn os_pid() u32 {
    return unsafe GetCurrentProcessId();
}

/// Whether process `pid` exists (a zombie counts until it is reaped). InvalidInput for pid 0, which
/// names no process. Unsupported on WASI.
@platform(macos | ios | linux | android)
pub fn is_alive(pid: u32) Result<bool, IoError> {
    if pid == 0 || pid > i32::MAX as u32 {
        return invalid::<bool>(IoOp::Signal);
    }
    if unsafe c_kill(pid as i32, 0) == 0 {
        return Result::<bool, IoError>::Ok(true);
    }
    let e = errno::errno();
    if e == EPERM {
        return Result::<bool, IoError>::Ok(true); // it exists, owned by another user
    }
    if e == ESRCH {
        return Result::<bool, IoError>::Ok(false);
    }
    return fail::<bool>(IoOp::Signal);
}
/// Whether process `pid` exists (a zombie counts until it is reaped). InvalidInput for pid 0, which
/// names no process. Unsupported on WASI.
@platform(windows)
pub fn is_alive(pid: u32) Result<bool, IoError> {
    if pid == 0 {
        return invalid::<bool>(IoOp::Signal);
    }
    let h = unsafe OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
    if h == null {
        let e = unsafe GetLastError();
        if e == ERROR_INVALID_PARAMETER {
            return Result::<bool, IoError>::Ok(false);
        }
        if e == ERROR_ACCESS_DENIED {
            return Result::<bool, IoError>::Ok(true);
        }
        return Result::<bool, IoError>::Err(error::code_error(e as i32, IoOp::Signal));
    }
    let mut code: u32 = 0;
    let ok = unsafe GetExitCodeProcess(h, &mut code) != 0;
    unsafe CloseHandle(h);
    if !ok {
        return fail::<bool>(IoOp::Signal);
    }
    return Result::<bool, IoError>::Ok(code == STILL_ACTIVE);
}
/// Whether process `pid` exists. Unsupported: WASI has no processes.
@platform(wasm)
pub fn is_alive(_pid: u32) Result<bool, IoError> {
    return Result::<bool, IoError>::Err(error::unsupported(IoOp::Signal));
}

/// The path of the running executable ('/' separators on Windows). Unsupported on WASI, where a module
/// has no path of its own.
@platform(macos | ios)
pub fn exe_path() Result<String, IoError> {
    let mut size: u32 = 1024;
    // At most two passes: the second has the size the first reported.
    for _ in 0..3 {
        let mut out = String::with_capacity(size as usize);
        let mut sz = size;
        if unsafe _NSGetExecutablePath(out.spare_mut(size as usize) as *mut char, &mut sz) == 0 {
            out.advance_len(unsafe cstring::strlen(out.as_ptr() as *const char));
            return Result::<String, IoError>::Ok(out);
        }
        size = sz;
    }
    return Result::<String, IoError>::Err(IoError::new(IoErrorKind::Other, IoOp::ExePath));
}
/// The path of the running executable ('/' separators on Windows). Unsupported on WASI, where a module
/// has no path of its own.
@platform(linux | android)
pub fn exe_path() Result<String, IoError> {
    return fs::readlink("/proc/self/exe");
}
/// The path of the running executable ('/' separators on Windows). Unsupported on WASI, where a module
/// has no path of its own.
@platform(windows)
pub fn exe_path() Result<String, IoError> {
    let mut buf = Vector::<u16>::new();
    let mut cap: u32 = 512;
    // The size doubles each pass, up to the 32767 units of the longest Windows path.
    while cap <= 65536 {
        buf.clear();
        buf.resize_default(cap as usize);
        let n = unsafe GetModuleFileNameW(null, buf.index_range_mut(0..cap as usize).as_mut_ptr(), cap);
        if n == 0 {
            return fail::<String>(IoOp::ExePath);
        }
        if n < cap {
            let mut out = String::new();
            path::push_wide(&mut out, buf[0..n as usize], true, IoOp::ExePath)?;
            return Result::<String, IoError>::Ok(out);
        }
        cap = cap * 2;
    }
    return Result::<String, IoError>::Err(IoError::new(IoErrorKind::LimitExceeded, IoOp::ExePath));
}
/// The path of the running executable. Unsupported on WASI, where a module has no path of its own.
@platform(wasm)
pub fn exe_path() Result<String, IoError> {
    return Result::<String, IoError>::Err(error::unsupported(IoOp::ExePath));
}

/// The working directory ('/' separators on Windows).
@platform(!windows)
pub fn current_dir() Result<String, IoError> {
    let mut cap: usize = 1024;
    // The size doubles each pass, up to 1 MiB.
    while cap <= 1 << 20 {
        let mut out = String::with_capacity(cap);
        if unsafe unistd::getcwd(out.spare_mut(cap) as *mut char, cap) != null {
            out.advance_len(unsafe cstring::strlen(out.as_ptr() as *const char));
            return Result::<String, IoError>::Ok(out);
        }
        if errno::errno() != ERANGE {
            return fail::<String>(IoOp::CurrentDir);
        }
        cap = cap * 2;
    }
    return Result::<String, IoError>::Err(IoError::new(IoErrorKind::LimitExceeded, IoOp::CurrentDir));
}
/// The working directory ('/' separators on Windows).
@platform(windows)
pub fn current_dir() Result<String, IoError> {
    let mut buf = Vector::<u16>::new();
    let mut cap: u32 = 512;
    // At most two passes: the second has the size the first reported.
    for _ in 0..3 {
        buf.clear();
        buf.resize_default(cap as usize);
        let n = unsafe GetCurrentDirectoryW(cap, buf.index_range_mut(0..cap as usize).as_mut_ptr());
        if n == 0 {
            return fail::<String>(IoOp::CurrentDir);
        }
        if n < cap {
            let mut out = String::new();
            path::push_wide(&mut out, buf[0..n as usize], true, IoOp::CurrentDir)?;
            return Result::<String, IoError>::Ok(out);
        }
        cap = n;
    }
    return Result::<String, IoError>::Err(IoError::new(IoErrorKind::Other, IoOp::CurrentDir));
}

/// Make `path` the working directory of the whole process (every thread).
@platform(!windows)
pub fn set_current_dir(path: str) Result<Unit, IoError> {
    let np = path::native(path, IoOp::SetCurrentDir)?;
    if unsafe unistd::chdir(np.ptr()) != 0 {
        return fail::<Unit>(IoOp::SetCurrentDir);
    }
    return Result::<Unit, IoError>::Ok(Unit {});
}
/// Make `path` the working directory of the whole process (every thread).
@platform(windows)
pub fn set_current_dir(path: str) Result<Unit, IoError> {
    let np = path::native(path, IoOp::SetCurrentDir)?;
    if unsafe SetCurrentDirectoryW(np.ptr()) == 0 {
        return fail::<Unit>(IoOp::SetCurrentDir);
    }
    return Result::<Unit, IoError>::Ok(Unit {});
}

/// A new pipe: its read end and its write end. Bytes written to the second come out of the first;
/// neither end is inherited by children unless passed as a `Redirect::Handle`. Unsupported on WASI.
@platform(linux | android)
pub fn pipe() Result<(fs::File, fs::File), IoError> {
    let mut fds: [i32; 2] = [-1, -1];
    if unsafe pipe2(&mut fds[0], fcntl::O_CLOEXEC) != 0 {
        return fail::<(fs::File, fs::File)>(IoOp::Pipe);
    }
    return Result::<(fs::File, fs::File), IoError>::Ok(
        (unsafe fs::File::from_raw(fds[0]), unsafe fs::File::from_raw(fds[1])),
    );
}
/// A new pipe: its read end and its write end. Bytes written to the second come out of the first;
/// neither end is inherited by children unless passed as a `Redirect::Handle`. Unsupported on WASI.
@platform(macos | ios)
pub fn pipe() Result<(fs::File, fs::File), IoError> {
    let mut fds: [i32; 2] = [-1, -1];
    // Darwin has no pipe2: a child another thread spawns between the two calls inherits the ends.
    if unsafe unistd::pipe(&mut fds[0]) != 0 {
        return fail::<(fs::File, fs::File)>(IoOp::Pipe);
    }
    let p = (unsafe fs::File::from_raw(fds[0]), unsafe fs::File::from_raw(fds[1]));
    for fd in fds {
        if unsafe fcntl::fcntl(fd, fcntl::F_SETFD, fcntl::FD_CLOEXEC) != 0 {
            return fail::<(fs::File, fs::File)>(IoOp::Pipe);
        }
    }
    return Result::<(fs::File, fs::File), IoError>::Ok(p);
}
/// A new pipe: its read end and its write end. Bytes written to the second come out of the first;
/// neither end is inherited by children unless passed as a `Redirect::Handle`. Unsupported on WASI.
@platform(windows)
pub fn pipe() Result<(fs::File, fs::File), IoError> {
    let mut r: *mut void = null;
    let mut w: *mut void = null;
    if unsafe CreatePipe(&mut r, &mut w, null, 0) == 0 {
        return fail::<(fs::File, fs::File)>(IoOp::Pipe);
    }
    return Result::<(fs::File, fs::File), IoError>::Ok((unsafe fs::File::from_raw(r), unsafe fs::File::from_raw(w)));
}
/// A new pipe: its read end and its write end. Unsupported: WASI has no pipes.
@platform(wasm)
pub fn pipe() Result<(fs::File, fs::File), IoError> {
    return Result::<(fs::File, fs::File), IoError>::Err(error::unsupported(IoOp::Pipe));
}

/// The largest resident set this process has had, in bytes. Unsupported on WASI.
@platform(macos | ios)
pub fn peak_rss() Result<u64, IoError> {
    let mut ru = unsafe zeroed::<rusage>();
    if unsafe getrusage(RUSAGE_SELF, &mut ru) != 0 {
        return fail::<u64>(IoOp::ResourceUsage);
    }
    return Result::<u64, IoError>::Ok(ru.ru_opaque[0] as u64); // ru_maxrss, in bytes
}
/// The largest resident set this process has had, in bytes. Unsupported on WASI.
@platform(linux | android)
pub fn peak_rss() Result<u64, IoError> {
    let mut ru = unsafe zeroed::<rusage>();
    if unsafe getrusage(RUSAGE_SELF, &mut ru) != 0 {
        return fail::<u64>(IoOp::ResourceUsage);
    }
    return Result::<u64, IoError>::Ok(ru.ru_maxrss as u64 * 1024); // KiB
}
/// The largest resident set this process has had, in bytes. Unsupported on WASI.
@platform(windows)
pub fn peak_rss() Result<u64, IoError> {
    let mut pmc = unsafe zeroed::<PROCESS_MEMORY_COUNTERS>();
    if unsafe K32GetProcessMemoryInfo(GetCurrentProcess(), &mut pmc, sizeof(PROCESS_MEMORY_COUNTERS) as u32) == 0 {
        return fail::<u64>(IoOp::ResourceUsage);
    }
    return Result::<u64, IoError>::Ok(pmc.PeakWorkingSetSize as u64);
}
/// The largest resident set this process has had, in bytes. Unsupported on WASI.
@platform(wasm)
pub fn peak_rss() Result<u64, IoError> {
    return Result::<u64, IoError>::Err(error::unsupported(IoOp::ResourceUsage));
}

/// Raise this process's limit of open descriptors to at least `need`, within the hard limit:
/// LimitExceeded when the hard limit is lower. Windows has no such limit on handles: it succeeds there.
/// Unsupported on WASI.
@platform(macos | ios | linux | android)
pub fn raise_open_file_limit(need: u64) Result<Unit, IoError> {
    let mut r = rlimit { rlim_cur: 0, rlim_max: 0 };
    if unsafe getrlimit(RLIMIT_NOFILE, &mut r) != 0 {
        return fail::<Unit>(IoOp::SetLimit);
    }
    if r.rlim_cur != RLIM_INFINITY && r.rlim_cur < need {
        if r.rlim_max != RLIM_INFINITY && r.rlim_max < need {
            return Result::<Unit, IoError>::Err(IoError::new(IoErrorKind::LimitExceeded, IoOp::SetLimit));
        }
        r.rlim_cur = need;
        if unsafe setrlimit(RLIMIT_NOFILE, &r) != 0 {
            return fail::<Unit>(IoOp::SetLimit);
        }
    }
    return Result::<Unit, IoError>::Ok(Unit {});
}
/// Raise this process's limit of open descriptors to at least `need`, within the hard limit:
/// LimitExceeded when the hard limit is lower. Windows has no such limit on handles: it succeeds there.
/// Unsupported on WASI.
@platform(windows)
pub fn raise_open_file_limit(_need: u64) Result<Unit, IoError> {
    return Result::<Unit, IoError>::Ok(Unit {});
}
/// Raise this process's limit of open descriptors. Unsupported on WASI, which sets no such limit a module
/// can change.
@platform(wasm)
pub fn raise_open_file_limit(_need: u64) Result<Unit, IoError> {
    return Result::<Unit, IoError>::Err(error::unsupported(IoOp::SetLimit));
}

// ---- Helpers ----------------------------------------------------------------------------------------

fn fail<T>(op: IoOp) Result<T, IoError> {
    return Result::<T, IoError>::Err(error::last_error(op));
}

@platform(!wasm)
const fn invalid<T>(op: IoOp) Result<T, IoError> {
    return Result::<T, IoError>::Err(IoError::new(IoErrorKind::InvalidInput, op));
}

extend<'a> Redirect<'a> {
    @platform(windows)
    fn is_inherit(self: &Redirect<'a>) bool {
        return switch *self {
            Inherit => true,
            _ => false,
        };
    }
    @platform(!wasm)
    const fn is_stdout(self: &Redirect<'a>) bool {
        return switch *self {
            Stdout => true,
            _ => false,
        };
    }
}

extend<'a> Command<'a> {
    /// Run `argv` with this process's environment, working directory and standard streams.
    pub const fn new(argv: Slice<'a, str<'a>>) Command<'a> {
        return Command::<'a> {
            argv: argv,
            program: Option::<str<'a>>::None,
            env: Option::<Slice<'a, str<'a>>>::None,
            cwd: Option::<str<'a>>::None,
            command_line: Option::<str<'a>>::None,
            stdin: Redirect::<'a>::Inherit,
            stdout: Redirect::<'a>::Inherit,
            stderr: Redirect::<'a>::Inherit,
        };
    }
}

extend Child {
    @platform(!wasm)
    fn adopt(raw: ChildRaw, pid: u32) Child {
        return Child { raw: raw, pid: pid, status: Option::<ExitStatus>::None };
    }

    /// The child's process id.
    pub fn id(self: &Child) u32 {
        return self.pid;
    }

    fn reaped(self: &Child) bool {
        return self.status.is_some();
    }

    // Record wait status `st` when this live child is process `pid`: its status.
    @platform(macos | ios | linux | android)
    fn reap_if(self: &mut Child, pid: i32, st: i32) Option<ExitStatus> {
        if self.status.is_some() || self.raw != pid {
            return Option::<ExitStatus>::None;
        }
        self.status = Option::<ExitStatus>::Some(status_of(st));
        return self.status;
    }

    /// Block until the child ends: its status. A second wait returns the same status.
    @platform(macos | ios | linux | android)
    pub fn wait(self: &mut Child) Result<ExitStatus, IoError> {
        if let Some(s) = self.status {
            return Result::<ExitStatus, IoError>::Ok(s);
        }
        let mut st: i32 = 0;
        // Bounded by the signals that interrupt the wait.
        while unsafe waitpid(self.raw, &mut st, 0) < 0 {
            if !error::interrupted() {
                return fail::<ExitStatus>(IoOp::Wait);
            }
        }
        let s = status_of(st);
        self.status = Option::<ExitStatus>::Some(s);
        return Result::<ExitStatus, IoError>::Ok(s);
    }
    /// Block until the child ends: its status. A second wait returns the same status.
    @platform(windows)
    pub fn wait(self: &mut Child) Result<ExitStatus, IoError> {
        if let Some(s) = self.status {
            return Result::<ExitStatus, IoError>::Ok(s);
        }
        if unsafe WaitForSingleObject(self.raw, INFINITE) != WAIT_OBJECT_0 {
            return fail::<ExitStatus>(IoOp::Wait);
        }
        return self.exit_code();
    }
    /// Block until the child ends. Unsupported: WASI has no processes.
    @platform(wasm)
    pub fn wait(self: &mut Child) Result<ExitStatus, IoError> {
        return Result::<ExitStatus, IoError>::Err(error::unsupported(IoOp::Wait));
    }

    /// The child's status when it has ended, else None, without blocking.
    @platform(macos | ios | linux | android)
    pub fn try_wait(self: &mut Child) Result<Option<ExitStatus>, IoError> {
        if self.status.is_some() {
            return Result::<Option<ExitStatus>, IoError>::Ok(self.status);
        }
        let mut st: i32 = 0;
        // Bounded by the signals that interrupt the wait.
        loop {
            let r = unsafe waitpid(self.raw, &mut st, WNOHANG);
            if r == self.raw {
                self.status = Option::<ExitStatus>::Some(status_of(st));
                return Result::<Option<ExitStatus>, IoError>::Ok(self.status);
            }
            if r == 0 {
                return Result::<Option<ExitStatus>, IoError>::Ok(Option::<ExitStatus>::None);
            }
            if !error::interrupted() {
                return fail::<Option<ExitStatus>>(IoOp::Wait);
            }
        }
    }
    /// The child's status when it has ended, else None, without blocking.
    @platform(windows)
    pub fn try_wait(self: &mut Child) Result<Option<ExitStatus>, IoError> {
        if self.status.is_some() {
            return Result::<Option<ExitStatus>, IoError>::Ok(self.status);
        }
        let w = unsafe WaitForSingleObject(self.raw, 0);
        if w == WAIT_TIMEOUT {
            return Result::<Option<ExitStatus>, IoError>::Ok(Option::<ExitStatus>::None);
        }
        if w != WAIT_OBJECT_0 {
            return fail::<Option<ExitStatus>>(IoOp::Wait);
        }
        let s = self.exit_code()?;
        return Result::<Option<ExitStatus>, IoError>::Ok(Option::<ExitStatus>::Some(s));
    }
    /// The child's status when it has ended. Unsupported: WASI has no processes.
    @platform(wasm)
    pub fn try_wait(self: &mut Child) Result<Option<ExitStatus>, IoError> {
        return Result::<Option<ExitStatus>, IoError>::Err(error::unsupported(IoOp::Wait));
    }

    @platform(windows)
    fn raw_handle(self: &Child) *mut void {
        return self.raw;
    }

    // The exit code of the ended child, recorded.
    @platform(windows)
    fn exit_code(self: &mut Child) Result<ExitStatus, IoError> {
        let mut code: u32 = 1;
        if unsafe GetExitCodeProcess(self.raw, &mut code) == 0 {
            return fail::<ExitStatus>(IoOp::Wait);
        }
        let s = ExitStatus::Code(code as i32);
        self.status = Option::<ExitStatus>::Some(s);
        return Result::<ExitStatus, IoError>::Ok(s);
    }

    /// End the child at once (SIGKILL; TerminateProcess with exit code 137 on Windows). It must still be
    /// waited for. Succeeds without effect once the child was reaped.
    @platform(macos | ios | linux | android)
    pub fn kill(self: &mut Child) Result<Unit, IoError> {
        if self.status.is_none() && unsafe c_kill(self.raw, SIGKILL) != 0 {
            return fail::<Unit>(IoOp::Kill);
        }
        return Result::<Unit, IoError>::Ok(Unit {});
    }
    /// End the child at once (SIGKILL; TerminateProcess with exit code 137 on Windows). It must still be
    /// waited for. Succeeds without effect once the child was reaped.
    @platform(windows)
    pub fn kill(self: &mut Child) Result<Unit, IoError> {
        if self.status.is_none() && unsafe TerminateProcess(self.raw, 137) == 0 {
            // A process that already ended refuses with access denied.
            if unsafe WaitForSingleObject(self.raw, 0) != WAIT_OBJECT_0 {
                return fail::<Unit>(IoOp::Kill);
            }
        }
        return Result::<Unit, IoError>::Ok(Unit {});
    }
    /// End the child at once. Unsupported: WASI has no processes.
    @platform(wasm)
    pub fn kill(self: &mut Child) Result<Unit, IoError> {
        return Result::<Unit, IoError>::Err(error::unsupported(IoOp::Kill));
    }
}

@platform(windows)
extend Child as Free {
    pub fn free(self: &mut Child) {
        unsafe CloseHandle(self.raw);
    }
}

extend ExitStatus as Eq {}

extend ExitStatus as Format {}
