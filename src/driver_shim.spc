// Platform glue shared by the driver (main), the loader, the build engine and the language server:
// directory entries, file kinds, identity and times, paths, the running executable, processes (spawn,
// wait, kill), file locks, the process-tree jobserver, the environment and the crash trace. POSIX
// (macOS, iOS, Linux, Android) goes through libc, Windows through the Win32 API and its C runtime,
// and wasm through wasi-libc, where every process call fails: WASI has no processes.
import errno;
import fcntl;
import signal;
import stdio;
import stdlib;
import string as cstring;
import unistd;

// ---- C bindings: every platform but Windows --------------------------------------------------------

@platform(macos | ios)
type mode_t = u16;
@platform(linux | android | wasm)
type mode_t = u32;

@platform(!windows)
extern "C" "time.h" {
    struct timespec {
        pub tv_sec: i64,
        pub tv_nsec: stdlib::c_long,
    }
    fn clock_gettime(clock: i32, ts: *mut timespec) i32;
    const CLOCK_MONOTONIC: i32;
}

// `struct stat` as the build's feature level (`_POSIX_C_SOURCE=200809L`) declares it: Darwin then names
// the times `st_mtime` and `st_mtimensec`.
@platform(macos | ios)
extern "C" "sys/stat.h" {
    struct stat {
        pub st_dev: i32,
        pub st_mode: u16,
        pub st_nlink: u16,
        pub st_ino: u64,
        pub st_uid: u32,
        pub st_gid: u32,
        pub st_rdev: i32,
        pub st_atime: i64,
        pub st_atimensec: stdlib::c_long,
        pub st_mtime: i64,
        pub st_mtimensec: stdlib::c_long,
        pub st_ctime: i64,
        pub st_ctimensec: stdlib::c_long,
        pub st_birthtime: i64,
        pub st_birthtimensec: stdlib::c_long,
        pub st_size: i64,
        pub st_blocks: i64,
        pub st_blksize: i32,
        pub st_flags: u32,
        pub st_gen: u32,
        pub st_lspare: i32,
        pub st_qspare: [i64; 2],
    }
}
@platform(linux | android)
@arch(x86_64)
extern "C" "sys/stat.h" {
    struct stat {
        pub st_dev: u64,
        pub st_ino: u64,
        pub st_nlink: u64,
        pub st_mode: u32,
        pub st_uid: u32,
        pub st_gid: u32,
        @import("__pad0")
        pub pad0: i32,
        pub st_rdev: u64,
        pub st_size: i64,
        pub st_blksize: i64,
        pub st_blocks: i64,
        pub st_atim: timespec,
        pub st_mtim: timespec,
        pub st_ctim: timespec,
        @import("__glibc_reserved")
        pub reserved: [i64; 3],
    }
}
@platform(linux | android)
@arch(aarch64)
extern "C" "sys/stat.h" {
    struct stat {
        pub st_dev: u64,
        pub st_ino: u64,
        pub st_mode: u32,
        pub st_nlink: u32,
        pub st_uid: u32,
        pub st_gid: u32,
        pub st_rdev: u64,
        @import("__pad1")
        pub pad1: u64,
        pub st_size: i64,
        pub st_blksize: i32,
        @import("__pad2")
        pub pad2: i32,
        pub st_blocks: i64,
        pub st_atim: timespec,
        pub st_mtim: timespec,
        pub st_ctim: timespec,
        @import("__glibc_reserved")
        pub reserved: [i32; 2],
    }
}
@platform(wasm)
extern "C" "sys/stat.h" {
    struct stat {
        pub st_dev: u64,
        pub st_ino: u64,
        pub st_nlink: u64,
        pub st_mode: u32,
        pub st_uid: u32,
        pub st_gid: u32,
        @import("__pad0")
        pub pad0: u32,
        pub st_rdev: u64,
        pub st_size: i64,
        pub st_blksize: stdlib::c_long,
        pub st_blocks: i64,
        pub st_atim: timespec,
        pub st_mtim: timespec,
        pub st_ctim: timespec,
        @import("__reserved")
        pub reserved: [i64; 3],
    }
}

@platform(!windows)
extern "C" "sys/stat.h" {
    fn stat(path: *const char, buf: *mut stat) i32;
    fn lstat(path: *const char, buf: *mut stat) i32;
    fn mkdir(path: *const char, mode: mode_t) i32;
    fn chmod(path: *const char, mode: mode_t) i32;
    fn utimensat(dirfd: i32, path: *const char, times: *const timespec, flags: i32) i32;
    fn fstat(fd: i32, buf: *mut stat) i32;
    const S_IFMT: u32;
    const S_IFDIR: u32;
    const S_IFREG: u32;
}

@platform(!windows)
extern "C" "unistd.h" {
    fn readlink(path: *const char, buf: *mut char, size: usize) isize;
    fn rmdir(path: *const char) i32;
    fn unlink(path: *const char) i32;
    fn link(from: *const char, to: *const char) i32;
}

@platform(!windows)
extern "C" "stdlib.h" {
    fn mkstemp(template: *mut char) i32;
    fn setenv(name: *const char, value: *const char, overwrite: i32) i32;
    fn unsetenv(name: *const char) i32;
}

@platform(!windows)
extern "C" "stdio.h" {
    fn fileno(f: *mut stdio::FILE) i32;
}

@platform(!windows)
extern "C" "fcntl.h" {
    const AT_FDCWD: i32;
}

@platform(!windows)
extern "C" "errno.h" {
    const EINTR: i32;
}

// ---- C bindings: directory streams -----------------------------------------------------------------

@platform(macos | ios)
extern "C" "dirent.h" {
    struct dirent {
        pub d_ino: u64,
        pub d_seekoff: u64,
        pub d_reclen: u16,
        pub d_namlen: u16,
        pub d_type: u8,
        pub d_name: [char; 1024],
    }
}
@platform(linux | android)
extern "C" "dirent.h" {
    struct dirent {
        pub d_ino: u64,
        pub d_off: i64,
        pub d_reclen: u16,
        pub d_type: u8,
        pub d_name: [char; 256],
    }
}
// The build's feature level hides `DT_UNKNOWN` and `DT_DIR` on Darwin and glibc; both define them as
// these values, which their kernels' directory entries carry.
@platform(macos | ios | linux | android)
const DT_UNKNOWN: u8 = 0;
@platform(macos | ios | linux | android)
const DT_DIR: u8 = 4;
@platform(wasm)
extern "C" "dirent.h" {
    struct dirent {
        pub d_ino: u64,
        pub d_type: u8,
        pub d_name: [char; 0],
    }
    const DT_UNKNOWN: u8 = 0;
    const DT_DIR: u8 = 3;
}
@platform(windows)
extern "C" "dirent.h" {
    struct dirent {
        pub d_ino: i32,
        pub d_reclen: u16,
        pub d_namlen: u16,
        pub d_name: [char; 260],
    }
}
extern "C" "dirent.h" {
    type DIR;
    fn opendir(path: *const char) *mut DIR;
    fn readdir(dir: *mut DIR) *mut dirent;
    fn closedir(dir: *mut DIR) i32;
}

// ---- C bindings: POSIX systems with processes ------------------------------------------------------

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

extern "C" "errno.h" {
    const ENOENT: i32;
    const ENOTDIR: i32;
}

@platform(macos | ios | linux | android)
extern "C" "errno.h" {
    const EPERM: i32;
    const EACCES: i32;
    const EAGAIN: i32;
}

@platform(macos | ios | linux | android)
extern "C" "time.h" {
    fn nanosleep(req: *const timespec, rem: *mut timespec) i32;
}

@platform(macos | ios)
type nfds_t = u32;
@platform(linux | android)
type nfds_t = stdlib::c_ulong;

@platform(macos | ios | linux | android)
extern "C" "poll.h" {
    struct pollfd {
        pub fd: i32,
        pub events: i16,
        pub revents: i16,
    }
    fn poll(fds: *mut pollfd, n: nfds_t, timeout: i32) i32;
    const POLLIN: i16;
}

@platform(macos | ios | linux | android)
extern "C" "signal.h" {
    fn kill(pid: i32, sig: i32) i32;
    const SIGKILL: i32;
}

@platform(macos | ios | linux | android)
extern "C" "string.h" {
    fn strsignal(sig: i32) *mut char;
}

@platform(macos | ios | linux | android)
extern "C" "sys/wait.h" {
    fn waitpid(pid: i32, status: *mut i32, options: i32) i32;
    const WNOHANG: i32;
}

// `struct rusage` as the build's feature level declares it: Darwin then folds the counters into
// `ru_opaque`, whose first word is `ru_maxrss` (bytes); glibc keeps the names (KiB).
@platform(macos | ios)
extern "C" "sys/resource.h" {
    struct timeval {
        pub tv_sec: stdlib::c_long,
        pub tv_usec: i32,
    }
    struct rusage {
        pub ru_utime: timeval,
        pub ru_stime: timeval,
        pub ru_opaque: [stdlib::c_long; 14],
    }
}
@platform(linux | android)
extern "C" "sys/resource.h" {
    struct timeval {
        pub tv_sec: i64,
        pub tv_usec: stdlib::c_long,
    }
    struct rusage {
        pub ru_utime: timeval,
        pub ru_stime: timeval,
        pub ru_maxrss: stdlib::c_long,
        pub ru_ixrss: stdlib::c_long,
        pub ru_idrss: stdlib::c_long,
        pub ru_isrss: stdlib::c_long,
        pub ru_minflt: stdlib::c_long,
        pub ru_majflt: stdlib::c_long,
        pub ru_nswap: stdlib::c_long,
        pub ru_inblock: stdlib::c_long,
        pub ru_oublock: stdlib::c_long,
        pub ru_msgsnd: stdlib::c_long,
        pub ru_msgrcv: stdlib::c_long,
        pub ru_nsignals: stdlib::c_long,
        pub ru_nvcsw: stdlib::c_long,
        pub ru_nivcsw: stdlib::c_long,
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

@platform(macos | ios | linux | android)
extern "C" "execinfo.h" {
    fn backtrace(frames: *mut *mut void, size: i32) i32;
    fn backtrace_symbols_fd(frames: *const *mut void, size: i32, fd: i32) void;
}

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
@platform(macos | ios)
extern "C" "crt_externs.h" {
    fn _NSGetEnviron() *mut *mut *mut char;
}

@platform(linux | android)
extern "C" "unistd.h" {
    fn sysconf(name: i32) stdlib::c_long;
    const _SC_NPROCESSORS_ONLN: i32;
}

@platform(macos | ios)
extern "C" "mach-o/dyld.h" {
    fn _NSGetExecutablePath(buf: *mut char, size: *mut u32) i32;
}

// `<sys/sysctl.h>` does not compile at the build's feature level on Darwin: a block without a header
// declares `sysctlbyname`.
@platform(macos | ios)
extern "C" {
    fn sysctlbyname(name: *const char, oldp: *mut void, oldlenp: *mut usize, newp: *mut void, newlen: usize) i32;
}

@platform(!windows)
extern "C" "stdlib.h" {
    @import("realpath")
    fn c_realpath(path: *const char, resolved: *mut char) *mut char;
}

// ---- C bindings: Windows ---------------------------------------------------------------------------

@platform(windows)
extern "C" "windows.h" {
    @import("FILETIME")
    struct FILETIME {
        pub dwLowDateTime: u32,
        pub dwHighDateTime: u32,
    }
    @import("BY_HANDLE_FILE_INFORMATION")
    struct BY_HANDLE_FILE_INFORMATION {
        pub dwFileAttributes: u32,
        pub ftCreationTime: FILETIME,
        pub ftLastAccessTime: FILETIME,
        pub ftLastWriteTime: FILETIME,
        pub dwVolumeSerialNumber: u32,
        pub nFileSizeHigh: u32,
        pub nFileSizeLow: u32,
        pub nNumberOfLinks: u32,
        pub nFileIndexHigh: u32,
        pub nFileIndexLow: u32,
    }
    @import("WIN32_FILE_ATTRIBUTE_DATA")
    struct WIN32_FILE_ATTRIBUTE_DATA {
        pub dwFileAttributes: u32,
        pub ftCreationTime: FILETIME,
        pub ftLastAccessTime: FILETIME,
        pub ftLastWriteTime: FILETIME,
        pub nFileSizeHigh: u32,
        pub nFileSizeLow: u32,
    }
    // `Offset` and `OffsetHigh` are the members of an anonymous union that overlays `Pointer`.
    @import("OVERLAPPED")
    struct OVERLAPPED {
        pub Internal: usize,
        pub InternalHigh: usize,
        pub Offset: u32,
        pub OffsetHigh: u32,
        pub hEvent: *mut void,
    }
    @import("SECURITY_ATTRIBUTES")
    struct SECURITY_ATTRIBUTES {
        pub nLength: u32,
        pub lpSecurityDescriptor: *mut void,
        pub bInheritHandle: i32,
    }
    @import("STARTUPINFOA")
    struct STARTUPINFOA {
        pub cb: u32,
        pub lpReserved: *mut char,
        pub lpDesktop: *mut char,
        pub lpTitle: *mut char,
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

    // A `DWORD *` parameter is `*mut void`: DWORD is C `unsigned long`, which no Super-C type spells, and
    // a call converts its argument through `void *`.
    fn GetFileAttributesA(path: *const char) u32;
    fn GetFileAttributesExA(path: *const char, level: i32, info: *mut WIN32_FILE_ATTRIBUTE_DATA) i32;
    fn CreateFileA(
        path: *const char,
        access: u32,
        share: u32,
        security: *mut SECURITY_ATTRIBUTES,
        disposition: u32,
        flags: u32,
        template: *mut void,
    ) *mut void;
    fn GetFileInformationByHandle(h: *mut void, info: *mut BY_HANDLE_FILE_INFORMATION) i32;
    fn CloseHandle(h: *mut void) i32;
    fn GetModuleFileNameA(module: *mut void, buf: *mut char, size: u32) u32;
    fn GetModuleHandleA(name: *const char) *mut void;
    fn OpenProcess(access: u32, inherit: i32, pid: u32) *mut void;
    fn GetExitCodeProcess(h: *mut void, code: *mut void) i32;
    fn GetFileType(h: *mut void) u32;
    fn PeekNamedPipe(h: *mut void, buf: *mut void, size: u32, read: *mut void, avail: *mut void, left: *mut void) i32;
    fn WaitForSingleObject(h: *mut void, ms: u32) u32;
    fn WaitForMultipleObjects(n: u32, handles: *const *mut void, all: i32, ms: u32) u32;
    fn GetTempPathA(size: u32, buf: *mut char) u32;
    fn GetCurrentProcessId() u32;
    fn GetCurrentProcess() *mut void;
    fn GetTickCount64() u64;
    fn SetEnvironmentVariableA(name: *const char, value: *const char) i32;
    fn LockFileEx(h: *mut void, flags: u32, reserved: u32, low: u32, high: u32, ov: *mut OVERLAPPED) i32;
    fn UnlockFileEx(h: *mut void, reserved: u32, low: u32, high: u32, ov: *mut OVERLAPPED) i32;
    fn GetLastError() u32;
    fn Sleep(ms: u32) void;
    fn CreateProcessA(
        app: *const char,
        cmd: *mut char,
        process_security: *mut SECURITY_ATTRIBUTES,
        thread_security: *mut SECURITY_ATTRIBUTES,
        inherit: i32,
        flags: u32,
        env: *mut void,
        cwd: *const char,
        si: *mut STARTUPINFOA,
        pi: *mut PROCESS_INFORMATION,
    ) i32;
    fn GetStdHandle(which: u32) *mut void;
    fn TerminateProcess(h: *mut void, code: u32) i32;
    fn CreateHardLinkA(link: *const char, existing: *const char, security: *mut SECURITY_ATTRIBUTES) i32;
    fn MoveFileExA(from: *const char, to: *const char, flags: u32) i32;
    fn DuplicateHandle(
        src_process: *mut void,
        src: *mut void,
        dst_process: *mut void,
        dst: *mut *mut void,
        access: u32,
        inherit: i32,
        options: u32,
    ) i32;
    fn RtlCaptureStackBackTrace(skip: u32, n: u32, frames: *mut *mut void, hash: *mut void) u16;

    const INVALID_HANDLE_VALUE: *mut void;
    const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    const FILE_ATTRIBUTE_TEMPORARY: u32 = 0x100;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
    const FILE_FLAG_DELETE_ON_CLOSE: u32 = 0x04000000;
    const FILE_SHARE_READ: u32 = 1;
    const FILE_SHARE_WRITE: u32 = 2;
    const FILE_SHARE_DELETE: u32 = 4;
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const FILE_APPEND_DATA: u32 = 4;
    const SYNCHRONIZE: u32 = 0x00100000;
    const CREATE_NEW: u32 = 1;
    const CREATE_ALWAYS: u32 = 2;
    const OPEN_EXISTING: u32 = 3;
    const OPEN_ALWAYS: u32 = 4;
    const GetFileExInfoStandard: i32 = 0;
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const STILL_ACTIVE: u32 = 0x103;
    const FILE_TYPE_PIPE: u32 = 3;
    const WAIT_OBJECT_0: u32 = 0;
    const INFINITE: u32 = 0xFFFFFFFF;
    const MAXIMUM_WAIT_OBJECTS: u32 = 64;
    const LOCKFILE_FAIL_IMMEDIATELY: u32 = 1;
    const LOCKFILE_EXCLUSIVE_LOCK: u32 = 2;
    const ERROR_LOCK_VIOLATION: u32 = 33;
    const MAX_PATH: u32 = 260;
    const STARTF_USESTDHANDLES: u32 = 0x100;
    const STD_INPUT_HANDLE: u32 = 0xFFFFFFF6;
    const MOVEFILE_REPLACE_EXISTING: u32 = 1;
    const DUPLICATE_SAME_ACCESS: u32 = 2;
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

@platform(windows)
extern "C" "sys/stat.h" {
    struct _stat64 {
        pub st_dev: u32,
        pub st_ino: u16,
        pub st_mode: u16,
        pub st_nlink: i16,
        pub st_uid: i16,
        pub st_gid: i16,
        pub st_rdev: u32,
        pub st_size: i64,
        pub st_atime: i64,
        pub st_mtime: i64,
        pub st_ctime: i64,
    }
    fn _stat64(path: *const char, buf: *mut _stat64) i32;
    fn _fstat64(fd: i32, buf: *mut _stat64) i32;
    const _S_IFMT: u32 = 0xF000;
    const _S_IFDIR: u32 = 0x4000;
    const _S_IFREG: u32 = 0x8000;
    const _S_IREAD: i32 = 0x100;
    const _S_IWRITE: i32 = 0x80;
}

@platform(windows)
extern "C" "io.h" {
    fn _access(path: *const char, mode: i32) i32;
    fn _open(path: *const char, flags: i32, ...) i32;
    fn _read(fd: i32, buf: *mut void, n: u32) i32;
    fn _write(fd: i32, buf: *const void, n: u32) i32;
    fn _close(fd: i32) i32;
    fn _get_osfhandle(fd: i32) isize;
    fn _unlink(path: *const char) i32;
    fn _chmod(path: *const char, mode: i32) i32;
}

@platform(windows)
extern "C" "fcntl.h" {
    const _O_RDONLY: i32;
    const _O_WRONLY: i32;
    const _O_CREAT: i32;
    const _O_TRUNC: i32;
    const _O_BINARY: i32;
}

@platform(windows)
extern "C" "direct.h" {
    fn _chdir(path: *const char) i32;
    fn _mkdir(path: *const char) i32;
    fn _rmdir(path: *const char) i32;
}

@platform(windows)
extern "C" "stdlib.h" {
    fn _fullpath(abs: *mut char, rel: *const char, max: usize) *mut char;
    fn _putenv_s(name: *const char, value: *const char) i32;
}

@platform(windows)
extern "C" "stdio.h" {
    fn _fileno(f: *mut stdio::FILE) i32;
}

@platform(windows)
extern "C" "process.h" {
    fn _getpid() i32;
}

@platform(windows)
extern "C" "sys/utime.h" {
    // `struct _utimbuf *`: null sets both times to now.
    fn _utime(path: *const char, times: *mut void) i32;
}

// ---- Directory entries and file kinds --------------------------------------------------------------

/// Name of a `sc_readdir` entry; borrows the entry, invalidated by the next read on the same stream.
pub unsafe fn sc_dirent_name(entry: *mut void) *const char {
    return (unsafe &(*(entry as *mut dirent)).d_name) as *const char;
}

/// 1 directory, 0 other file kind, -1 when `path` cannot be stat'd.
@platform(!windows)
pub unsafe fn sc_stat_isdir(path: *const char) i32 {
    let mut st = unsafe zeroed::<stat>();
    if unsafe stat(path, &mut st) != 0 {
        return -1;
    }
    return is_dir_mode(st.st_mode) as i32;
}
/// 1 directory, 0 other file kind, -1 when `path` cannot be stat'd.
@platform(windows)
pub unsafe fn sc_stat_isdir(path: *const char) i32 {
    let mut st = unsafe zeroed::<_stat64>();
    if unsafe _stat64(path, &mut st) != 0 {
        return -1;
    }
    let mode: u32 = st.st_mode;
    return ((mode & _S_IFMT) == _S_IFDIR) as i32;
}

@platform(!windows)
fn is_dir_mode(mode: u32) bool {
    return (mode & S_IFMT) == S_IFDIR;
}

/// Like `sc_stat_isdir` without following links: 1 real directory (safe to descend), 2 a Windows directory
/// link or junction (rmdir it, never descend), 0 anything else (a POSIX symlink: unlink removes the link),
/// -1 when `path` does not exist.
@platform(!windows)
pub unsafe fn sc_lstat_isdir(path: *const char) i32 {
    let mut st = unsafe zeroed::<stat>();
    if unsafe lstat(path, &mut st) != 0 {
        return -1;
    }
    return is_dir_mode(st.st_mode) as i32;
}
/// Like `sc_stat_isdir` without following links: 1 real directory (safe to descend), 2 a Windows directory
/// link or junction (rmdir it, never descend), 0 anything else (a POSIX symlink: unlink removes the link),
/// -1 when `path` does not exist.
@platform(windows)
pub unsafe fn sc_lstat_isdir(path: *const char) i32 {
    let a = unsafe GetFileAttributesA(path);
    if a == INVALID_FILE_ATTRIBUTES {
        return -1;
    }
    if (a & FILE_ATTRIBUTE_DIRECTORY) == 0 {
        return 0;
    }
    if (a & FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
        return 2;
    }
    return 1;
}

/// The d_type of a `sc_readdir` entry: 1 dir, 0 non-dir, -1 unknown (caller must stat; always -1 on Windows).
@platform(!windows)
pub unsafe fn sc_dirent_isdir(entry: *mut void) i32 {
    let t = unsafe (*(entry as *mut dirent)).d_type;
    if t == DT_DIR {
        return 1;
    }
    if t == DT_UNKNOWN {
        return -1;
    }
    return 0;
}
/// The d_type of a `sc_readdir` entry: 1 dir, 0 non-dir, -1 unknown (caller must stat; always -1 on Windows).
@platform(windows)
pub unsafe fn sc_dirent_isdir(_entry: *mut void) i32 {
    return -1; // mingw's `struct dirent` has no `d_type`
}

/// Open a directory stream for sc_readdir; null on failure.
pub unsafe fn sc_opendir(path: *const char) *mut void {
    return unsafe opendir(path);
}
/// Next entry of the stream (including `.` and `..`), or null at the end.
pub unsafe fn sc_readdir(dir: *mut void) *mut void {
    return unsafe readdir(dir as *mut DIR);
}
/// Close a stream from sc_opendir; 0 on success.
pub unsafe fn sc_closedir(dir: *mut void) i32 {
    return unsafe closedir(dir as *mut DIR);
}
/// 1 when errno says a path does not exist (ENOENT, ENOTDIR): what a failed `sc_opendir` means.
pub unsafe fn sc_errno_absent() i32 {
    let e = errno::errno();
    return (e == ENOENT || e == ENOTDIR) as i32;
}

// ---- File identity, paths and the executable -------------------------------------------------------

/// 1 iff both paths resolve to the same physical file, 0 if distinct, -1 if either cannot be stat'd.
@platform(!windows)
pub unsafe fn sc_same_file(a: *const char, b: *const char) i32 {
    let mut sa = unsafe zeroed::<stat>();
    let mut sb = unsafe zeroed::<stat>();
    if unsafe stat(a, &mut sa) != 0 || unsafe stat(b, &mut sb) != 0 {
        return -1;
    }
    return (sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino) as i32;
}
/// 1 iff both paths resolve to the same physical file, 0 if distinct, -1 if either cannot be stat'd.
@platform(windows)
pub unsafe fn sc_same_file(a: *const char, b: *const char) i32 {
    // mingw's stat() leaves st_ino 0, so the POSIX test would match any two files of one volume: the
    // Win32 identity is the volume serial and the 64-bit file index.
    let mut ia = unsafe zeroed::<BY_HANDLE_FILE_INFORMATION>();
    let mut ib = unsafe zeroed::<BY_HANDLE_FILE_INFORMATION>();
    if !unsafe file_info(a, &mut ia) || !unsafe file_info(b, &mut ib) {
        return -1;
    }
    let same = ia.dwVolumeSerialNumber == ib.dwVolumeSerialNumber && ia.nFileIndexHigh == ib.nFileIndexHigh && ia.nFileIndexLow == ib.nFileIndexLow;
    return same as i32;
}

// The Win32 identity and link count of the file `path`, through a handle that also opens a directory.
@platform(windows)
unsafe fn file_info(path: *const char, out: &mut BY_HANDLE_FILE_INFORMATION) bool {
    let share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
    let h = unsafe CreateFileA(path, 0, share, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
    if h == INVALID_HANDLE_VALUE {
        return false;
    }
    let ok = unsafe GetFileInformationByHandle(h, out) != 0;
    unsafe CloseHandle(h);
    return ok;
}

const PATH_BUF: usize = 4096;

/// Absolute path of `path` written into `resolved` ('\' normalized to '/' on Windows); null on failure.
/// Safety: `resolved` must hold at least 4096 bytes.
@platform(!windows)
pub unsafe fn sc_realpath(path: *const char, resolved: *mut char) *mut char {
    return unsafe c_realpath(path, resolved);
}
/// Absolute path of `path` written into `resolved` ('\' normalized to '/' on Windows); null on failure.
/// Safety: `resolved` must hold at least 4096 bytes.
@platform(windows)
pub unsafe fn sc_realpath(path: *const char, resolved: *mut char) *mut char {
    if unsafe _access(path, 0) != 0 {
        return null;
    }
    let r = unsafe _fullpath(resolved, path, PATH_BUF);
    if r != null {
        unsafe slashes_forward(resolved);
    }
    return r;
}

// Rewrite every '\' of the C string `p` as '/'.
@platform(windows)
unsafe fn slashes_forward(p: *mut char) {
    let n = unsafe cstring::strlen(p);
    for i in 0..n {
        if unsafe p[i] == '\\' {
            unsafe p[i] = '/';
        }
    }
}

/// The text of symbolic link `path` into `buf` (NUL-terminated, at most `size - 1` bytes): its length,
/// -1 when `path` is no link or on Windows and WASI. The link need not resolve.
@platform(macos | ios | linux | android)
pub unsafe fn sc_readlink(path: *const char, buf: *mut char, size: u32) i32 {
    if size == 0 {
        return -1;
    }
    let n = unsafe readlink(path, buf, (size - 1) as usize);
    if n < 0 {
        return -1;
    }
    unsafe buf[n as usize] = 0 as char;
    return n as i32;
}
/// The text of symbolic link `path` into `buf` (NUL-terminated, at most `size - 1` bytes): its length,
/// -1 when `path` is no link or on Windows and WASI. The link need not resolve.
@platform(windows | wasm)
pub unsafe fn sc_readlink(_path: *const char, _buf: *mut char, _size: u32) i32 {
    return -1;
}

// The host's argv[0]: WASI has no other name for the running module.
@platform(wasm)
static mut ARGV0: *const char = null;

/// Record the process's argv[0], which must outlive every `sc_exe_path` call: under WASI, where
/// the module has no other name, an absolute argv[0] is the path `sc_exe_path` reports.
@platform(wasm)
pub unsafe fn sc_set_argv0(argv0: *const char) {
    unsafe ARGV0 = argv0;
}
/// Record the process's argv[0], which must outlive every `sc_exe_path` call: under WASI, where
/// the module has no other name, an absolute argv[0] is the path `sc_exe_path` reports.
@platform(!wasm)
pub unsafe fn sc_set_argv0(_argv0: *const char) {}

/// Running executable's path into `buf`: 0 on success, nonzero on failure or truncation.
@platform(windows)
pub unsafe fn sc_exe_path(buf: *mut char, size: u32) i32 {
    let n = unsafe GetModuleFileNameA(null, buf, size);
    if n == 0 || n >= size {
        return -1;
    }
    unsafe slashes_forward(buf);
    return 0;
}
/// Running executable's path into `buf`: 0 on success, nonzero on failure or truncation.
@platform(macos | ios)
pub unsafe fn sc_exe_path(buf: *mut char, size: u32) i32 {
    let mut sz = size;
    return unsafe _NSGetExecutablePath(buf, &mut sz);
}
/// Running executable's path into `buf`: 0 on success, nonzero on failure or truncation.
@platform(linux | android)
pub unsafe fn sc_exe_path(buf: *mut char, size: u32) i32 {
    // readlink does not terminate and truncates silently: a result that fills `buf` may be cut short.
    let n = unsafe readlink("/proc/self/exe".ptr() as *const char, buf, size as usize);
    if n <= 0 || n as usize >= size as usize {
        return -1;
    }
    unsafe buf[n as usize] = 0 as char;
    return 0;
}
/// Running executable's path into `buf`: 0 on success, nonzero on failure or truncation.
@platform(wasm)
pub unsafe fn sc_exe_path(buf: *mut char, size: u32) i32 {
    // An absolute argv[0] names the module file through a preopened root (`wasmtime run --dir=/
    // --argv0 <abs path>`); a relative one resolves against the guest's cwd, not the host's.
    let a = unsafe ARGV0;
    if a == null || unsafe a[0] != '/' {
        return -1;
    }
    let n = unsafe cstring::strlen(a);
    if n >= size as usize {
        return -1;
    }
    unsafe cstring::memcpy(buf, a, n + 1);
    return 0;
}

// ---- Process ids and liveness ----------------------------------------------------------------------

/// This process's id.
@platform(windows)
pub unsafe fn sc_getpid() i32 {
    return unsafe _getpid();
}
/// This process's id.
@platform(wasm)
pub unsafe fn sc_getpid() i32 {
    return 1; // WASI has no pids; a constant keeps pid-suffixed temp names stable
}
/// This process's id.
@platform(macos | ios | linux | android)
pub unsafe fn sc_getpid() i32 {
    return unistd::getpid();
}

/// 1 while process `pid` is alive, 0 once it is gone (parent-death detection for the LSP).
@platform(windows)
pub unsafe fn sc_process_alive(pid: i64) i32 {
    if pid <= 0 {
        return 0;
    }
    let h = unsafe OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid as u32);
    if h == null {
        return 0;
    }
    let mut code: u32 = 0;
    let alive = unsafe GetExitCodeProcess(h, &mut code) != 0 && code == STILL_ACTIVE;
    unsafe CloseHandle(h);
    return alive as i32;
}
/// 1 while process `pid` is alive, 0 once it is gone (parent-death detection for the LSP).
@platform(wasm)
pub unsafe fn sc_process_alive(pid: i64) i32 {
    return (pid > 0) as i32; // WASI has no pids to probe
}
/// 1 while process `pid` is alive, 0 once it is gone (parent-death detection for the LSP).
@platform(macos | ios | linux | android)
pub unsafe fn sc_process_alive(pid: i64) i32 {
    if pid <= 0 {
        return 0;
    }
    return (unsafe kill(pid as i32, 0) == 0 || errno::errno() == EPERM) as i32;
}

// ---- Raw descriptor reads --------------------------------------------------------------------------

// Open `path` to read: a descriptor, or -1.
@platform(windows)
unsafe fn fd_open_read(path: *const char) i32 {
    return unsafe _open(path, _O_RDONLY | _O_BINARY);
}
@platform(!windows)
unsafe fn fd_open_read(path: *const char) i32 {
    return unsafe fcntl::open(path, fcntl::O_RDONLY | fcntl::O_CLOEXEC);
}

// Create or truncate `path` to write: a descriptor, or -1.
@platform(windows)
unsafe fn fd_open_write(path: *const char) i32 {
    return unsafe _open(path, _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY, _S_IREAD | _S_IWRITE);
}
@platform(!windows)
unsafe fn fd_open_write(path: *const char) i32 {
    return unsafe fcntl::open(path, fcntl::O_WRONLY | fcntl::O_CREAT | fcntl::O_TRUNC | fcntl::O_CLOEXEC, 0o644);
}

// Whether descriptor `fd` is a regular file: its size into `size` and its `sc_mtime` value into `mtime`.
@platform(windows)
unsafe fn fd_regular(fd: i32, size: *mut i64, mtime: *mut i64) bool {
    let mut st = unsafe zeroed::<_stat64>();
    if unsafe _fstat64(fd, &mut st) != 0 {
        return false;
    }
    let mode: u32 = st.st_mode;
    if (mode & _S_IFMT) != _S_IFREG {
        return false;
    }
    unsafe *size = st.st_size;
    unsafe *mtime = st.st_mtime;
    return true;
}
@platform(!windows)
unsafe fn fd_regular(fd: i32, size: *mut i64, mtime: *mut i64) bool {
    let mut st = unsafe zeroed::<stat>();
    if unsafe fstat(fd, &mut st) != 0 {
        return false;
    }
    let mode: u32 = st.st_mode;
    if (mode & S_IFMT) != S_IFREG {
        return false;
    }
    let (s, _) = mtime_of(&st);
    unsafe *size = st.st_size;
    unsafe *mtime = s;
    return true;
}

// One read of at most `n` bytes of descriptor `fd` into `buf`: the count, 0 at the end, -1 on error.
@platform(windows)
unsafe fn fd_read(fd: i32, buf: *mut void, n: usize) i64 {
    return unsafe _read(fd, buf, n.min(1 << 30) as u32);
}
@platform(!windows)
unsafe fn fd_read(fd: i32, buf: *mut void, n: usize) i64 {
    // Bounded by the signals that interrupt the read.
    loop {
        let r = unsafe unistd::read(fd, buf, n);
        if r >= 0 || errno::errno() != EINTR {
            return r as i64;
        }
    }
}

// One write of at most 1 GiB of the `n` bytes at `buf` to descriptor `fd`: the count, or -1 on error.
@platform(windows)
unsafe fn fd_write(fd: i32, buf: *const void, n: usize) i64 {
    return unsafe _write(fd, buf, n.min(1 << 30) as u32);
}
@platform(!windows)
unsafe fn fd_write(fd: i32, buf: *const void, n: usize) i64 {
    // Bounded by the signals that interrupt the write.
    loop {
        let r = unsafe unistd::write(fd, buf, n.min(1 << 30));
        if r >= 0 || errno::errno() != EINTR {
            return r as i64;
        }
    }
}

// Close descriptor `fd`: 0, or -1 on error.
@platform(windows)
unsafe fn fd_close(fd: i32) i32 {
    return unsafe _close(fd);
}
@platform(!windows)
unsafe fn fd_close(fd: i32) i32 {
    return unsafe unistd::close(fd);
}

/// Open `path` to read it whole: its descriptor, with the file's size in `size` and its `sc_mtime`
/// value in `mtime`, from one fstat; -1 when it does not open or is no regular file.
pub unsafe fn sc_file_open(path: *const char, size: *mut i64, mtime: *mut i64) i32 {
    let fd = unsafe fd_open_read(path);
    if fd < 0 {
        return -1;
    }
    if !unsafe fd_regular(fd, size, mtime) {
        unsafe fd_close(fd);
        return -1;
    }
    return fd;
}

/// Read up to `n` bytes of descriptor `fd` into `buf`, then close it: the count read (fewer when the
/// file ends first), or -1 on a read or close error.
pub unsafe fn sc_file_read_close(fd: i32, buf: *mut void, n: usize) i64 {
    let mut got: usize = 0;
    let mut bad = false;
    // Every pass reads at least one byte or ends the loop, so it runs at most n times.
    while got < n {
        let r = unsafe fd_read(fd, unsafe (buf as *mut u8 + got), n - got);
        if r <= 0 {
            bad = r < 0;
            break;
        }
        got += r as usize;
    }
    if unsafe fd_close(fd) != 0 || bad {
        return -1;
    }
    return got as i64;
}

// Whether the regular file open as `fd` holds exactly the `n` bytes at `p`. It compares through a
// 16 KiB stack buffer: the emitter can call `sc_publish` on a coroutine stack.
unsafe fn fd_holds(fd: i32, p: *const u8, n: usize) bool {
    let mut size: i64 = 0;
    let mut mt: i64 = 0;
    if !unsafe fd_regular(fd, &mut size, &mut mt) || size as u64 != n as u64 {
        return false;
    }
    let mut buf: [u8; 16384] = [0; 16384];
    let mut off: usize = 0;
    // Every pass but the last reads at least one byte and stays within `n`, so it runs at most n + 1 times.
    loop {
        let r = unsafe fd_read(fd, &mut buf[0], 16384);
        if r <= 0 {
            return r == 0 && off == n;
        }
        let k = r as usize;
        if off + k > n || unsafe cstring::memcmp(&buf[0], unsafe (p + off), k) != 0 {
            return false;
        }
        off += k;
    }
}

/// Make file `path` hold exactly the `n` bytes at `p`, creating missing parent directories: a file that
/// already holds them is not written, so it keeps its mtime. 1 when the file was written (one write
/// call, no stdio buffer), 0 when it already held the bytes, -1 when it could not be opened, written
/// or closed in full.
pub unsafe fn sc_publish(path: *const char, p: *const u8, n: usize) i32 {
    let mut fd = unsafe fd_open_read(path);
    if fd >= 0 {
        let same = unsafe fd_holds(fd, p, n);
        unsafe fd_close(fd);
        if same {
            return 0;
        }
    }
    fd = unsafe fd_open_write(path);
    if fd < 0 && errno::errno() == ENOENT {
        // The parent directories exist for all but the first file written into each.
        let s = unsafe str::from_cstr(path);
        let mut k = s.len();
        while k > 0 && s[k - 1] != b'/' && s[k - 1] != b'\\' {
            k -= 1;
        }
        if k <= 1 {
            return -1;
        }
        let mut dir = String::from_str(s.slice(0, k - 1));
        unsafe sc_mkdir_p(dir.cstr());
        fd = unsafe fd_open_write(path);
    }
    if fd < 0 {
        return -1;
    }
    let mut off: usize = 0;
    // Every pass writes at least one byte or ends the loop, so it runs at most n times.
    while off < n {
        let w = unsafe fd_write(fd, unsafe (p + off), n - off);
        if w <= 0 {
            break;
        }
        off += w as usize;
    }
    if unsafe fd_close(fd) == 0 && off == n {
        return 1;
    }
    return -1;
}

/// Bytes of stream `f`'s descriptor into `buf` (at most `n`), past the stdio buffer: what one read
/// returns (a pipe hands over what has arrived), 0 at end of stream, -1 on error.
@platform(windows)
pub unsafe fn sc_file_read(f: *mut void, buf: *mut void, n: usize) i64 {
    let want = n.min(1 << 30) as u32;
    return unsafe _read(_fileno(f as *mut stdio::FILE), buf, want);
}
/// Bytes of stream `f`'s descriptor into `buf` (at most `n`), past the stdio buffer: what one read
/// returns (a pipe hands over what has arrived), 0 at end of stream, -1 on error.
@platform(!windows)
pub unsafe fn sc_file_read(f: *mut void, buf: *mut void, n: usize) i64 {
    let fd = unsafe fileno(f as *mut stdio::FILE);
    // Bounded by the signals that interrupt the read.
    loop {
        let r = unsafe unistd::read(fd, buf, n);
        if r >= 0 || errno::errno() != EINTR {
            return r as i64;
        }
    }
}

/// 1 when a read on stream `f`'s descriptor returns at once (bytes waiting or end of stream), else 0.
@platform(windows)
pub unsafe fn sc_file_pending(f: *mut void) i32 {
    let h = (unsafe _get_osfhandle(_fileno(f as *mut stdio::FILE))) as *mut void;
    if h == INVALID_HANDLE_VALUE {
        return 0;
    }
    if unsafe GetFileType(h) == FILE_TYPE_PIPE {
        let mut avail: u32 = 0;
        if unsafe PeekNamedPipe(h, null, 0, null, &mut avail, null) == 0 {
            return 1; // a broken pipe: the read reports it
        }
        return (avail > 0) as i32;
    }
    return (unsafe WaitForSingleObject(h, 0) == WAIT_OBJECT_0) as i32;
}
/// 1 when a read on stream `f`'s descriptor returns at once (bytes waiting or end of stream), else 0.
@platform(wasm)
pub unsafe fn sc_file_pending(_f: *mut void) i32 {
    return 0;
}
/// 1 when a read on stream `f`'s descriptor returns at once (bytes waiting or end of stream), else 0.
@platform(macos | ios | linux | android)
pub unsafe fn sc_file_pending(f: *mut void) i32 {
    let mut pfd = pollfd { fd: unsafe fileno(f as *mut stdio::FILE), events: POLLIN, revents: 0 };
    // Data, end of stream or an error: the read returns at once.
    return (unsafe poll(&mut pfd, 1, 0) > 0) as i32;
}

// ---- Build target and limits -----------------------------------------------------------------------

/// Platform index of the build: 0 windows, 1 macos (and ios), 2 linux, 3 wasm, 5 android (the default
/// --target).
pub unsafe fn sc_host_platform() i32 {
    return switch PLATFORM {
        Windows => 0,
        MacOS | IOS => 1,
        Linux => 2,
        Wasm => 3,
        Android => 5,
    };
}

/// Instruction set of the build: 0 x86_64, 1 aarch64, 2 wasm32 (the default --arch).
pub unsafe fn sc_host_arch() i32 {
    return switch ARCH {
        X86_64 => 0,
        AArch64 => 1,
        Wasm32 => 2,
    };
}

/// Raise this process's soft limit of open descriptors to `need`, within the hard limit: 0, or -1 when
/// the hard limit is lower or the call fails; 0 where no such limit exists (Windows, WASI).
@platform(macos | ios | linux | android)
pub unsafe fn sc_raise_open_files(need: u64) i32 {
    let mut r = rlimit { rlim_cur: 0, rlim_max: 0 };
    if unsafe getrlimit(RLIMIT_NOFILE, &mut r) != 0 {
        return -1;
    }
    if r.rlim_cur != RLIM_INFINITY && r.rlim_cur < need {
        if r.rlim_max != RLIM_INFINITY && r.rlim_max < need {
            return -1;
        }
        r.rlim_cur = need;
        if unsafe setrlimit(RLIMIT_NOFILE, &r) != 0 {
            return -1;
        }
    }
    return 0;
}
/// Raise this process's soft limit of open descriptors to `need`, within the hard limit: 0, or -1 when
/// the hard limit is lower or the call fails; 0 where no such limit exists (Windows, WASI).
@platform(windows | wasm)
pub unsafe fn sc_raise_open_files(_need: u64) i32 {
    return 0;
}

// ---- File system -----------------------------------------------------------------------------------

/// chdir(2): 0 on success, -1 on failure.
@platform(windows)
pub unsafe fn sc_chdir(path: *const char) i32 {
    return unsafe _chdir(path);
}
/// chdir(2): 0 on success, -1 on failure.
@platform(!windows)
pub unsafe fn sc_chdir(path: *const char) i32 {
    return unsafe unistd::chdir(path);
}

/// Create one directory: 0 on success, -1 on failure (including an existing path).
@platform(windows)
pub unsafe fn sc_mkdir(path: *const char) i32 {
    return unsafe _mkdir(path);
}
/// Create one directory: 0 on success, -1 on failure (including an existing path).
@platform(!windows)
pub unsafe fn sc_mkdir(path: *const char) i32 {
    return unsafe mkdir(path, 0o775);
}

/// Remove an EMPTY directory: 0 on success, -1 otherwise.
@platform(windows)
pub unsafe fn sc_rmdir(path: *const char) i32 {
    return unsafe _rmdir(path);
}
/// Remove an EMPTY directory: 0 on success, -1 otherwise.
@platform(!windows)
pub unsafe fn sc_rmdir(path: *const char) i32 {
    return unsafe rmdir(path);
}

/// Delete a file: 0 on success, -1 on failure.
@platform(windows)
pub unsafe fn sc_unlink(path: *const char) i32 {
    return unsafe _unlink(path);
}
/// Delete a file: 0 on success, -1 on failure.
@platform(!windows)
pub unsafe fn sc_unlink(path: *const char) i32 {
    return unsafe unlink(path);
}

/// Make `path` owner-readable and writable (0644) so unlink can remove it (git creates its objects
/// read-only, and Windows refuses to unlink a read-only file); 0 on success.
@platform(windows)
pub unsafe fn sc_chmod_rw(path: *const char) i32 {
    return unsafe _chmod(path, _S_IREAD | _S_IWRITE);
}
/// Make `path` owner-readable and writable (0644) so unlink can remove it (git creates its objects
/// read-only, and Windows refuses to unlink a read-only file); 0 on success.
@platform(!windows)
pub unsafe fn sc_chmod_rw(path: *const char) i32 {
    return unsafe chmod(path, 0o644);
}

/// Make `path` executable (0755); a no-op on Windows, which goes by extension.
@platform(windows)
pub unsafe fn sc_chmod_exec(_path: *const char) i32 {
    return 0;
}
/// Make `path` executable (0755); a no-op on Windows, which goes by extension.
@platform(!windows)
pub unsafe fn sc_chmod_exec(path: *const char) i32 {
    return unsafe chmod(path, 0o755);
}

/// Modification time in seconds; 0 when the file does not exist (the build engine's staleness sentinel).
@platform(windows)
pub unsafe fn sc_mtime(path: *const char) i64 {
    let mut st = unsafe zeroed::<_stat64>();
    if unsafe _stat64(path, &mut st) != 0 {
        return 0;
    }
    return st.st_mtime;
}
/// Modification time in seconds; 0 when the file does not exist (the build engine's staleness sentinel).
@platform(!windows)
pub unsafe fn sc_mtime(path: *const char) i64 {
    let mut st = unsafe zeroed::<stat>();
    if unsafe stat(path, &mut st) != 0 {
        return 0;
    }
    let (s, _) = mtime_of(&st);
    return s;
}

// The modification time of `st`: seconds and nanoseconds.
@platform(macos | ios)
fn mtime_of(st: &stat) (i64, i64) {
    return st.st_mtime, st.st_mtimensec as i64;
}
// The modification time of `st`: seconds and nanoseconds.
@platform(linux | android | wasm)
fn mtime_of(st: &stat) (i64, i64) {
    return st.st_mtim.tv_sec, st.st_mtim.tv_nsec as i64;
}

/// Modification time in nanoseconds (100 ns steps on Windows); 0 when the file does not exist.
@platform(windows)
pub unsafe fn sc_mtime_ns(path: *const char) i64 {
    let mut d = unsafe zeroed::<WIN32_FILE_ATTRIBUTE_DATA>();
    if unsafe GetFileAttributesExA(path, GetFileExInfoStandard, &mut d) == 0 {
        return 0;
    }
    // FILETIME counts 100 ns ticks from 1601; the offset moves the origin to 1970.
    let t = d.ftLastWriteTime.dwHighDateTime as u64 << 32 | d.ftLastWriteTime.dwLowDateTime as u64;
    return t.wrapping_sub(116444736000000000) as i64 * 100;
}
/// Modification time in nanoseconds (100 ns steps on Windows); 0 when the file does not exist.
@platform(!windows)
pub unsafe fn sc_mtime_ns(path: *const char) i64 {
    let mut st = unsafe zeroed::<stat>();
    if unsafe stat(path, &mut st) != 0 {
        return 0;
    }
    let (s, ns) = mtime_of(&st);
    return s * 1000000000 + ns;
}

/// Set the modification time of `path` to now; 0 on success.
@platform(windows)
pub unsafe fn sc_touch(path: *const char) i32 {
    return unsafe _utime(path, null);
}
/// Set the modification time of `path` to now; 0 on success.
@platform(!windows)
pub unsafe fn sc_touch(path: *const char) i32 {
    return unsafe utimensat(AT_FDCWD, path, null, 0);
}

/// rename() that also replaces an existing destination on Windows, including one that is a RUNNING
/// executable, which Windows will not delete but will let us rename aside (parked as `<to>.old`).
@platform(windows)
pub unsafe fn sc_rename(from: *const char, to: *const char) i32 {
    if unsafe MoveFileExA(from, to, MOVEFILE_REPLACE_EXISTING) != 0 {
        return 0;
    }
    // `to` may be a running image: the compiler replacing itself. Windows refuses to delete or overwrite
    // one but lets it be renamed, because the mapped section holds the file object, not the path. The
    // parked image cannot be deleted while it runs; the next call sweeps it.
    let mut side = unsafe String::from_cstr(to);
    side.push_str(".old");
    if side.len() >= PATH_BUF {
        return -1;
    }
    unsafe _unlink(side.cstr());
    if unsafe MoveFileExA(to, side.cstr(), MOVEFILE_REPLACE_EXISTING) == 0 {
        return -1;
    }
    if unsafe MoveFileExA(from, to, MOVEFILE_REPLACE_EXISTING) != 0 {
        return 0;
    }
    unsafe MoveFileExA(side.cstr(), to, MOVEFILE_REPLACE_EXISTING); // the name must not stay empty
    return -1;
}
/// rename() that also replaces an existing destination on Windows, including one that is a RUNNING
/// executable, which Windows will not delete but will let us rename aside (parked as `<to>.old`).
@platform(!windows)
pub unsafe fn sc_rename(from: *const char, to: *const char) i32 {
    return unsafe stdio::rename(from, to);
}

/// Give the file `from` the second name `to` (a hard link): 0 on success, -1 when the file system
/// or the platform refuses (another volume, a link count limit).
@platform(windows)
pub unsafe fn sc_link(from: *const char, to: *const char) i32 {
    if unsafe CreateHardLinkA(to, from, null) != 0 {
        return 0;
    }
    return -1;
}
/// Give the file `from` the second name `to` (a hard link): 0 on success, -1 when the file system
/// or the platform refuses (another volume, a link count limit).
@platform(!windows)
pub unsafe fn sc_link(from: *const char, to: *const char) i32 {
    return unsafe link(from, to);
}

/// The number of names of the file `path` (its hard links), with its identity on its volume (POSIX
/// inode, Win32 file index) in `id`; -1 when it cannot be read.
@platform(windows)
pub unsafe fn sc_file_links(path: *const char, id: *mut u64) i32 {
    let mut fi = unsafe zeroed::<BY_HANDLE_FILE_INFORMATION>();
    if !unsafe file_info(path, &mut fi) {
        return -1;
    }
    unsafe *id = fi.nFileIndexHigh as u64 << 32 | fi.nFileIndexLow as u64;
    return fi.nNumberOfLinks as i32;
}
/// The number of names of the file `path` (its hard links), with its identity on its volume (POSIX
/// inode, Win32 file index) in `id`; -1 when it cannot be read.
@platform(!windows)
pub unsafe fn sc_file_links(path: *const char, id: *mut u64) i32 {
    let mut st = unsafe zeroed::<stat>();
    if unsafe stat(path, &mut st) != 0 {
        return -1;
    }
    unsafe *id = st.st_ino;
    let links: u64 = st.st_nlink;
    return links as i32;
}

/// `mkdir -p`: create every missing component of `path`. 0 on success.
pub unsafe fn sc_mkdir_p(path: *const char) i32 {
    let n = unsafe cstring::strlen(path);
    if n == 0 || n >= PATH_BUF {
        return -1;
    }
    let mut buf: [char; PATH_BUF] = [0 as char; PATH_BUF];
    unsafe cstring::memcpy(&mut buf[0], path, n + 1);
    for i in 1..n {
        let sep = unsafe buf[i];
        if sep == '/' || sep == '\\' {
            unsafe buf[i] = 0 as char;
            if unsafe sc_stat_isdir(&buf[0]) != 1 {
                unsafe sc_mkdir(&buf[0]);
            }
            unsafe buf[i] = sep;
        }
    }
    if unsafe sc_stat_isdir(&buf[0]) == 1 {
        return 0;
    }
    unsafe sc_mkdir(&buf[0]);
    if unsafe sc_stat_isdir(&buf[0]) == 1 {
        return 0;
    }
    return -1;
}

/// `rm -rf`: delete `path` and anything under it; a link is removed, never followed. 0 once it is gone.
/// A child whose path does not fit 4096 bytes stays (a cut path names another file), so the result
/// reports the directory left behind.
pub unsafe fn sc_rm_rf(path: *const char) i32 {
    let kind = unsafe sc_lstat_isdir(path);
    if kind == 1 {
        let d = unsafe sc_opendir(path);
        if d != null {
            let base = unsafe str::from_cstr(path);
            let mut child = String::new();
            // Bounded by the entries of the directory.
            loop {
                let e = unsafe sc_readdir(d);
                if e == null {
                    break;
                }
                let nm = unsafe str::from_cstr(sc_dirent_name(e));
                if nm == "." || nm == ".." {
                    continue;
                }
                child.clear();
                child.push_str(base);
                child.push_byte(b'/');
                child.push_str(nm);
                if child.len() >= PATH_BUF {
                    continue;
                }
                unsafe sc_rm_rf(child.cstr());
            }
            unsafe sc_closedir(d);
        }
        unsafe sc_rmdir(path);
    } else if kind == 2 {
        unsafe sc_rmdir(path); // a Windows directory link or junction: rmdir removes the link alone
    } else if kind == 0 {
        unsafe sc_unlink(path);
    }
    if unsafe sc_lstat_isdir(path) == -1 {
        return 0;
    }
    return -1;
}

static mut TMPDIR: [char; PATH_BUF] = [0 as char; PATH_BUF];

/// The system temp directory, without a trailing separator, in a buffer that lives as long as the process.
@platform(windows)
pub unsafe fn sc_tmpdir() *const char {
    let buf = (unsafe &mut TMPDIR[0]) as *mut char;
    if unsafe buf[0] != 0 as char {
        return buf;
    }
    let mut n = (unsafe GetTempPathA(PATH_BUF as u32, buf)) as usize;
    if n == 0 || n >= PATH_BUF {
        unsafe buf[0] = '.';
        unsafe buf[1] = 0 as char;
        return buf;
    }
    // No trailing separator: callers join with '/'.
    while n > 1 && (unsafe buf[n - 1] == '\\' || unsafe buf[n - 1] == '/') {
        n -= 1;
        unsafe buf[n] = 0 as char;
    }
    // Forward slashes, like sc_realpath: a path that reaches a JSON string or a C string literal must not
    // carry backslashes, which are escapes in both.
    unsafe slashes_forward(buf);
    return buf;
}
/// The system temp directory, without a trailing separator, in a buffer that lives as long as the process.
@platform(!windows)
pub unsafe fn sc_tmpdir() *const char {
    let buf = (unsafe &mut TMPDIR[0]) as *mut char;
    if unsafe buf[0] != 0 as char {
        return buf;
    }
    let mut t = stdlib::getenv("TMPDIR");
    if t == null || unsafe t[0] == 0 as char {
        t = "/tmp".ptr() as *const char;
    }
    let mut n = unsafe cstring::strlen(t).min(PATH_BUF - 1);
    unsafe cstring::memcpy(buf, t, n);
    unsafe buf[n] = 0 as char;
    while n > 1 && unsafe buf[n - 1] == '/' {
        n -= 1;
        unsafe buf[n] = 0 as char;
    }
    return buf;
}

// ---- Time, cores and memory ------------------------------------------------------------------------

/// Monotonic milliseconds (never wall clock).
@platform(windows)
pub unsafe fn sc_ticks_ms() i64 {
    return (unsafe GetTickCount64()) as i64;
}
/// Monotonic milliseconds (never wall clock).
@platform(!windows)
pub unsafe fn sc_ticks_ms() i64 {
    let mut ts = timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe clock_gettime(CLOCK_MONOTONIC, &mut ts);
    return ts.tv_sec * 1000 + ts.tv_nsec as i64 / 1000000;
}

/// Online core count; 4 when it cannot be determined.
@platform(windows)
pub unsafe fn sc_ncpu() i32 {
    let n = stdlib::getenv("NUMBER_OF_PROCESSORS");
    let v = if n == null {
        0;
    } else {
        unsafe stdlib::atoi(n);
    };
    if v > 0 {
        return v;
    }
    return 4;
}
/// Online core count; 4 when it cannot be determined.
@platform(macos | ios)
pub unsafe fn sc_ncpu() i32 {
    let mut v: i32 = 0;
    let mut len: usize = sizeof(i32);
    let rc = unsafe sysctlbyname("hw.ncpu".ptr() as *const char, (&mut v) as *mut i32, &mut len, null, 0);
    if rc != 0 || v < 1 {
        return 4;
    }
    return v;
}
/// Online core count; 4 when it cannot be determined.
@platform(wasm)
pub unsafe fn sc_ncpu() i32 {
    return 1; // one thread of execution: the parallel frontiers must resolve to the serial path
}
/// Online core count; 4 when it cannot be determined.
@platform(linux | android)
pub unsafe fn sc_ncpu() i32 {
    let n = unsafe sysconf(_SC_NPROCESSORS_ONLN);
    if n > 0 {
        return n as i32;
    }
    return 4;
}

/// Peak resident set size of this process in bytes; 0 when the platform cannot report it.
@platform(windows)
pub unsafe fn sc_peak_rss() i64 {
    let mut pmc = unsafe zeroed::<PROCESS_MEMORY_COUNTERS>();
    if unsafe K32GetProcessMemoryInfo(GetCurrentProcess(), &mut pmc, sizeof(PROCESS_MEMORY_COUNTERS) as u32) == 0 {
        return 0;
    }
    return pmc.PeakWorkingSetSize as i64;
}
/// Peak resident set size of this process in bytes; 0 when the platform cannot report it.
@platform(wasm)
pub unsafe fn sc_peak_rss() i64 {
    return 0;
}
/// Peak resident set size of this process in bytes; 0 when the platform cannot report it.
@platform(macos | ios)
pub unsafe fn sc_peak_rss() i64 {
    let mut ru = unsafe zeroed::<rusage>();
    if unsafe getrusage(RUSAGE_SELF, &mut ru) != 0 {
        return 0;
    }
    return ru.ru_opaque[0] as i64; // ru_maxrss, in bytes
}
/// Peak resident set size of this process in bytes; 0 when the platform cannot report it.
@platform(linux | android)
pub unsafe fn sc_peak_rss() i64 {
    let mut ru = unsafe zeroed::<rusage>();
    if unsafe getrusage(RUSAGE_SELF, &mut ru) != 0 {
        return 0;
    }
    return ru.ru_maxrss as i64 * 1024; // KiB
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
fn scan_int(s: str, i: &mut usize) Option<i32> {
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
fn js_extra_slots(capacity: i32) i32 {
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

// ---- Build-tree lock -------------------------------------------------------------------------------

/// Exclusive lock on file `path` (created when missing), waiting at most `wait_ms`: the handle that
/// holds it, -1 when another process still holds it, -2 on an error. The OS releases it when the
/// process ends; no child inherits it.
@platform(windows)
pub unsafe fn sc_tree_lock(path: *const char, wait_ms: i64) i64 {
    let until = unsafe sc_ticks_ms() + wait_ms;
    let share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
    let rw = GENERIC_READ | GENERIC_WRITE;
    let h = unsafe CreateFileA(path, rw, share, null, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if h == INVALID_HANDLE_VALUE {
        return -2;
    }
    // Bounded by `wait_ms`: each failed try sleeps 100 ms.
    loop {
        let mut ov = unsafe zeroed::<OVERLAPPED>();
        if unsafe LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &mut ov) != 0 {
            return (h as usize) as i64;
        }
        if unsafe GetLastError() != ERROR_LOCK_VIOLATION {
            unsafe CloseHandle(h);
            return -2;
        }
        if unsafe sc_ticks_ms() >= until {
            unsafe CloseHandle(h);
            return -1;
        }
        unsafe Sleep(100);
    }
}
/// Exclusive lock on file `path` (created when missing), waiting at most `wait_ms`: the handle that
/// holds it, -1 when another process still holds it, -2 on an error. The OS releases it when the
/// process ends; no child inherits it.
@platform(macos | ios | linux | android)
pub unsafe fn sc_tree_lock(path: *const char, wait_ms: i64) i64 {
    let until = unsafe sc_ticks_ms() + wait_ms;
    let fd = unsafe fcntl::open(path, fcntl::O_RDWR | fcntl::O_CREAT | fcntl::O_CLOEXEC, 0o644);
    if fd < 0 {
        return -2;
    }
    // Bounded by `wait_ms`: each failed try sleeps 100 ms.
    loop {
        // A POSIX record lock on the whole file: held by this process until it closes `fd` or ends.
        let mut fl = unsafe zeroed::<flock>();
        fl.l_type = F_WRLCK as i16;
        fl.l_whence = stdio::SEEK_SET as i16;
        if unsafe fcntl::fcntl(fd, F_SETLK, &mut fl) == 0 {
            return fd;
        }
        let e = errno::errno();
        if e != EACCES && e != EAGAIN && e != EINTR {
            unsafe unistd::close(fd);
            return -2;
        }
        if unsafe sc_ticks_ms() >= until {
            unsafe unistd::close(fd);
            return -1;
        }
        let ts = timespec { tv_sec: 0, tv_nsec: 100000000 };
        unsafe nanosleep(&ts, null);
    }
}
/// Exclusive lock on file `path` (created when missing), waiting at most `wait_ms`: the handle that
/// holds it, -1 when another process still holds it, -2 on an error. The OS releases it when the
/// process ends; no child inherits it.
@platform(wasm)
pub unsafe fn sc_tree_lock(_path: *const char, _wait_ms: i64) i64 {
    return 0; // no file locks: a WASI compiler runs as the transpiler of an engine that holds the lock
}

/// Release a `sc_tree_lock` handle.
@platform(windows)
pub unsafe fn sc_tree_unlock(h: i64) {
    unsafe CloseHandle((h as usize) as *mut void);
}
/// Release a `sc_tree_lock` handle.
@platform(macos | ios | linux | android)
pub unsafe fn sc_tree_unlock(h: i64) {
    unsafe unistd::close(h as i32);
}
/// Release a `sc_tree_lock` handle.
@platform(wasm)
pub unsafe fn sc_tree_unlock(_h: i64) {}

// ---- Process spawning and waiting ------------------------------------------------------------------

// The wait status of Darwin's and Linux's <sys/wait.h>, whose WIFEXITED, WEXITSTATUS and WTERMSIG are
// macros: the low 7 bits are the signal that ended the child (0: it exited, 0x7f: it stopped), bits 8 to
// 15 its exit code. A child a signal ended gives 1.
@platform(macos | ios | linux | android)
fn exit_code_of(st: i32) i32 {
    if (st & 0x7f) == 0 {
        return st >> 8 & 0xff;
    }
    return 1;
}

// The signal that ended a child of wait status `st`, or 0 when it did not end by a signal.
@platform(macos | ios | linux | android)
fn term_signal_of(st: i32) i32 {
    let sig = st & 0x7f;
    if sig == 0x7f {
        return 0;
    }
    return sig;
}

// The environment array a spawned child gets: this process's.
@platform(macos | ios)
unsafe fn environ() *const *mut char {
    return unsafe *_NSGetEnviron();
}
@platform(linux | android)
unsafe fn environ() *const *mut char {
    return unsafe c_environ;
}

/// Start argv[0..] (NULL-terminated pointer array) WITHOUT a shell: the program `file` names (a
/// path), or argv[0] PATH-searched when `file` is null. argv[0] reaches the child as written, every
/// later entry verbatim, spaces, quotes, and non-ASCII bytes included.
/// A non-null `out_path` truncate-redirects the child's stdout+stderr into it; null inherits.
/// Returns a pid/handle for sc_wait_any/sc_try_wait/sc_waitpid, or -1 on spawn failure.
pub unsafe fn sc_spawn_argv(file: *const char, argv: *const *const char, out_path: *const char) i64 {
    return unsafe spawn_in(file, argv, out_path, null);
}

/// `sc_spawn_argv` of argv[0] with the child's working directory set to `cwd` (null: this process's);
/// -1 also where the C library has no way to set it at spawn.
pub unsafe fn sc_spawn_argv_in(argv: *const *const char, out_path: *const char, cwd: *const char) i64 {
    return unsafe spawn_in(null, argv, out_path, cwd);
}

// `sc_spawn_argv` of `file` (null: argv[0] PATH-searched) in directory `cwd` (null: this process's).
@platform(wasm)
unsafe fn spawn_in(_file: *const char, _argv: *const *const char, _out_path: *const char, _cwd: *const char) i64 {
    return -1;
}
// `sc_spawn_argv` of `file` (null: argv[0] PATH-searched) in directory `cwd` (null: this process's).
@platform(macos | ios | linux | android)
unsafe fn spawn_in(file: *const char, argv: *const *const char, out_path: *const char, cwd: *const char) i64 {
    let mut fa = unsafe zeroed::<posix_spawn_file_actions_t>();
    let use_fa = out_path != null || cwd != null;
    if use_fa {
        unsafe posix_spawn_file_actions_init(&mut fa);
    }
    if out_path != null {
        let flags = fcntl::O_WRONLY | fcntl::O_CREAT | fcntl::O_TRUNC;
        unsafe posix_spawn_file_actions_addopen(&mut fa, 1, out_path, flags, 0o644);
        unsafe posix_spawn_file_actions_adddup2(&mut fa, 1, 2);
    }
    if cwd != null && unsafe add_chdir(&mut fa, cwd) != 0 {
        unsafe posix_spawn_file_actions_destroy(&mut fa);
        return -1;
    }
    let mut pid: i32 = 0;
    let pfa: *const posix_spawn_file_actions_t = if use_fa {
        &fa;
    } else {
        null;
    };
    // posix_spawnp makes a whole spawn attempt per PATH entry: a program found once starts by its path.
    // A path that does not start (a PATH match that is not executable) falls back to the search.
    let mut rc: i32 = -1;
    if file != null {
        rc = unsafe posix_spawn(&mut pid, file, pfa, null, argv as *const *mut char, environ());
    }
    if rc != 0 {
        rc = unsafe posix_spawnp(&mut pid, argv[0], pfa, null, argv as *const *mut char, environ());
    }
    if use_fa {
        unsafe posix_spawn_file_actions_destroy(&mut fa);
    }
    if rc != 0 {
        return -1;
    }
    return pid;
}
// `sc_spawn_argv` of `file` (null: argv[0] PATH-searched) in directory `cwd` (null: this process's).
@platform(windows)
unsafe fn spawn_in(file: *const char, argv: *const *const char, out_path: *const char, cwd: *const char) i64 {
    let mut line = String::new();
    let mut i: usize = 0;
    // Bounded by the null entry that ends `argv`.
    while unsafe argv[i] != null {
        if i != 0 {
            line.push_byte(b' ');
        }
        win_quote_into(&mut line, unsafe str::from_cstr(argv[i]));
        i += 1;
    }
    let mut si = unsafe zeroed::<STARTUPINFOA>();
    si.cb = sizeof(STARTUPINFOA) as u32;
    let mut pi = unsafe zeroed::<PROCESS_INFORMATION>();
    let mut h = INVALID_HANDLE_VALUE;
    if out_path != null {
        let mut sa = unsafe zeroed::<SECURITY_ATTRIBUTES>();
        sa.nLength = sizeof(SECURITY_ATTRIBUTES) as u32;
        sa.bInheritHandle = 1;
        h = unsafe CreateFileA(
            out_path,
            GENERIC_WRITE,
            FILE_SHARE_READ,
            &mut sa,
            CREATE_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if h == INVALID_HANDLE_VALUE {
            return -1;
        }
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = unsafe GetStdHandle(STD_INPUT_HANDLE);
        si.hStdOutput = h;
        si.hStdError = h;
    }
    let ok = unsafe CreateProcessA(file, line.cstr() as *mut char, null, null, 1, 0, null, cwd, &mut si, &mut pi) != 0;
    if h != INVALID_HANDLE_VALUE {
        unsafe CloseHandle(h);
    }
    if !ok {
        return -1;
    }
    unsafe CloseHandle(pi.hThread);
    return (pi.hProcess as usize) as i64;
}

// Add the working directory `cwd` to the spawn actions `fa`: 0, or nonzero when the call fails or the C
// library has no such action (bionic, iOS).
@platform(macos | linux)
unsafe fn add_chdir(fa: &mut posix_spawn_file_actions_t, cwd: *const char) i32 {
    return unsafe posix_spawn_file_actions_addchdir_np(fa, cwd);
}
@platform(ios | android)
unsafe fn add_chdir(_fa: &mut posix_spawn_file_actions_t, _cwd: *const char) i32 {
    return -1;
}

// Append argument `a` to a CreateProcess command line as the MSVCRT parsing rules read it back: quoted
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

/// Spawn through sc_spawn_argv and wait: the child's exit code, or -1 on spawn/wait failure. A child a
/// signal ended returns 1 and is named on stderr with the signal.
@platform(macos | ios | linux | android)
pub unsafe fn sc_exec_argv(file: *const char, argv: *const *const char, out_path: *const char) i32 {
    let pid = unsafe sc_spawn_argv(file, argv, out_path);
    if pid < 0 {
        return -1;
    }
    let mut st: i32 = 0;
    // Bounded by the signals that interrupt the wait.
    while unsafe waitpid(pid as i32, &mut st, 0) < 0 {
        if errno::errno() != EINTR {
            return -1;
        }
    }
    let sig = term_signal_of(st);
    if sig != 0 {
        unsafe stdio::fprintf(
            stdio::stderr(),
            "super-c: '%s' was terminated by signal %d (%s)\n".ptr() as *const char,
            argv[0],
            sig,
            strsignal(sig),
        );
        return 1;
    }
    return exit_code_of(st);
}
/// Spawn through sc_spawn_argv and wait: the child's exit code, or -1 on spawn/wait failure. A child a
/// signal ended returns 1 and is named on stderr with the signal.
@platform(windows | wasm)
pub unsafe fn sc_exec_argv(file: *const char, argv: *const *const char, out_path: *const char) i32 {
    let pid = unsafe sc_spawn_argv(file, argv, out_path);
    if pid < 0 {
        return -1;
    }
    let mut code: i32 = 1;
    if unsafe sc_waitpid(pid, &mut code) != 0 {
        return -1;
    }
    return code;
}

/// Block until any of the `n` children exits: returns its index into `pids` and stores its exit
/// code in `code`; -1 on wait error.
@platform(macos | ios | linux | android)
pub unsafe fn sc_wait_any(pids: *const i64, n: i32, code: *mut i32) i32 {
    // Bounded by this process's children: an unrelated one (none are expected while the compile runs) is
    // reaped and the wait goes on; with none left the wait fails.
    loop {
        let mut st: i32 = 0;
        let p = unsafe waitpid(-1, &mut st, 0);
        if p < 0 {
            return -1;
        }
        for i in 0..n {
            if p as i64 == unsafe pids[i as usize] {
                unsafe *code = exit_code_of(st);
                return i;
            }
        }
    }
}
/// Block until any of the `n` children exits: returns its index into `pids` and stores its exit
/// code in `code`; -1 on wait error.
@platform(windows)
pub unsafe fn sc_wait_any(pids: *const i64, n: i32, code: *mut i32) i32 {
    return unsafe wait_handles(pids, n, code, INFINITE);
}
/// Block until any of the `n` children exits: returns its index into `pids` and stores its exit
/// code in `code`; -1 on wait error.
@platform(wasm)
pub unsafe fn sc_wait_any(_pids: *const i64, _n: i32, _code: *mut i32) i32 {
    return -1;
}

// Wait up to `ms` for any of the first MAXIMUM_WAIT_OBJECTS process handles of `pids`: the index of one
// that ended, with its exit code in `code` and its handle closed; -1 on timeout or error.
@platform(windows)
unsafe fn wait_handles(pids: *const i64, n: i32, code: *mut i32, ms: u32) i32 {
    let mut hs: [*mut void; 64] = [null as *mut void; 64];
    let cnt = (n.max(0) as u32).min(MAXIMUM_WAIT_OBJECTS);
    for i in 0..cnt as usize {
        unsafe hs[i] = (pids[i] as usize) as *mut void;
    }
    let w = unsafe WaitForMultipleObjects(cnt, &hs[0], 0, ms);
    if w >= cnt {
        return -1;
    }
    let mut ec: u32 = 1;
    unsafe GetExitCodeProcess(hs[w as usize], &mut ec);
    unsafe CloseHandle(hs[w as usize]);
    unsafe *code = ec as i32;
    return w as i32;
}

/// Non-blocking `sc_wait_any`: index of an already-exited child, or -1 when none has exited yet.
/// Never reaps a pid outside `pids`, so it is safe while the parallel emit workers are alive.
@platform(macos | ios | linux | android)
pub unsafe fn sc_try_wait(pids: *const i64, n: i32, code: *mut i32) i32 {
    for i in 0..n {
        let mut st: i32 = 0;
        let pid = (unsafe pids[i as usize]) as i32;
        if unsafe waitpid(pid, &mut st, WNOHANG) == pid {
            unsafe *code = exit_code_of(st);
            return i;
        }
    }
    return -1;
}
/// Non-blocking `sc_wait_any`: index of an already-exited child, or -1 when none has exited yet.
/// Never reaps a pid outside `pids`, so it is safe while the parallel emit workers are alive.
@platform(windows)
pub unsafe fn sc_try_wait(pids: *const i64, n: i32, code: *mut i32) i32 {
    return unsafe wait_handles(pids, n, code, 0);
}
/// Non-blocking `sc_wait_any`: index of an already-exited child, or -1 when none has exited yet.
/// Never reaps a pid outside `pids`, so it is safe while the parallel emit workers are alive.
@platform(wasm)
pub unsafe fn sc_try_wait(_pids: *const i64, _n: i32, _code: *mut i32) i32 {
    return -1;
}

/// End child `pid` (an `sc_spawn_argv` id) at once, as an outside kill does; 0 when sent, -1 on
/// error. The caller still waits for it.
@platform(macos | ios | linux | android)
pub unsafe fn sc_kill(pid: i64) i32 {
    if unsafe kill(pid as i32, SIGKILL) == 0 {
        return 0;
    }
    return -1;
}
/// End child `pid` (an `sc_spawn_argv` id) at once, as an outside kill does; 0 when sent, -1 on
/// error. The caller still waits for it.
@platform(windows)
pub unsafe fn sc_kill(pid: i64) i32 {
    if unsafe TerminateProcess((pid as usize) as *mut void, 137) != 0 {
        return 0;
    }
    return -1;
}
/// End child `pid` (an `sc_spawn_argv` id) at once, as an outside kill does; 0 when sent, -1 on
/// error. The caller still waits for it.
@platform(wasm)
pub unsafe fn sc_kill(_pid: i64) i32 {
    return -1;
}

/// Wait for ONE specific child; its exit code via `code`. 0 on success, -1 on error. Never reaps
/// another child.
@platform(macos | ios | linux | android)
pub unsafe fn sc_waitpid(pid: i64, code: *mut i32) i32 {
    let mut st: i32 = 0;
    // Bounded by the signals that interrupt the wait.
    while unsafe waitpid(pid as i32, &mut st, 0) < 0 {
        if errno::errno() != EINTR {
            return -1;
        }
    }
    unsafe *code = exit_code_of(st);
    return 0;
}
/// Wait for ONE specific child; its exit code via `code`. 0 on success, -1 on error. Never reaps
/// another child.
@platform(windows)
pub unsafe fn sc_waitpid(pid: i64, code: *mut i32) i32 {
    let h = (pid as usize) as *mut void;
    if unsafe WaitForSingleObject(h, INFINITE) != WAIT_OBJECT_0 {
        return -1;
    }
    let mut ec: u32 = 1;
    unsafe GetExitCodeProcess(h, &mut ec);
    unsafe CloseHandle(h);
    unsafe *code = ec as i32;
    return 0;
}
/// Wait for ONE specific child; its exit code via `code`. 0 on success, -1 on error. Never reaps
/// another child.
@platform(wasm)
pub unsafe fn sc_waitpid(_pid: i64, _code: *mut i32) i32 {
    return -1;
}

// ---- Environment and command runners ---------------------------------------------------------------

/// Set `name`=`value` in this process's environment, overwriting any existing value.
@platform(windows)
pub unsafe fn sc_setenv(name: *const char, value: *const char) i32 {
    return unsafe _putenv_s(name, value);
}
/// Set `name`=`value` in this process's environment, overwriting any existing value.
@platform(!windows)
pub unsafe fn sc_setenv(name: *const char, value: *const char) i32 {
    return unsafe setenv(name, value, 1);
}

/// Remove `name` from this process's environment: a switch read as "set" must not survive as an
/// empty value.
@platform(windows)
pub unsafe fn sc_unsetenv(name: *const char) i32 {
    return unsafe _putenv_s(name, "".ptr() as *const char);
}
/// Remove `name` from this process's environment: a switch read as "set" must not survive as an
/// empty value.
@platform(!windows)
pub unsafe fn sc_unsetenv(name: *const char) i32 {
    return unsafe unsetenv(name);
}

// One NAME=VALUE assignment applied around a child: the value before it (`had` false: unset) comes back
// after the child ends, so the parent's environment is unchanged.
@platform(!wasm)
struct EnvSave {
    pub name: String,
    pub old: String,
    pub had: bool,
}

@platform(!wasm)
const ENV_MAX: usize = 8;
@platform(!wasm)
const ENV_NAME_MAX: usize = 63;

// Undo `saves` in reverse, so a name assigned twice gets back its value from before the first assignment.
@platform(!wasm)
fn env_restore(saves: &mut Vector<EnvSave>) {
    while let Some(mut s) = saves.pop() {
        if s.had {
            unsafe sc_setenv(s.name.cstr(), s.old.cstr());
        } else {
            unsafe sc_unsetenv(s.name.cstr());
        }
    }
}

// Apply every NAME=VALUE of `env` (space separated; a VALUE in double quotes may hold spaces), recorded
// in `saves`: false with none left applied when one is malformed or there are more than ENV_MAX, so a
// child never runs with part of the environment its caller asked for.
@platform(!wasm)
fn env_apply(env: str, saves: &mut Vector<EnvSave>) bool {
    let n = env.len();
    let mut p: usize = 0;
    // Bounded: each assignment consumes at least its '='.
    loop {
        while p < n && (env.byte_at(p) == b' ' || env.byte_at(p) == b'\t') {
            p += 1;
        }
        if p == n {
            return true;
        }
        let mut eq = p;
        while eq < n && env.byte_at(eq) != b'=' && env.byte_at(eq) != b' ' && env.byte_at(eq) != b'\t' {
            eq += 1;
        }
        if eq == n || env.byte_at(eq) != b'=' || saves.len() == ENV_MAX {
            break;
        }
        let mut v0 = eq + 1;
        let mut v1 = v0;
        let mut end = v0;
        if v0 < n && env.byte_at(v0) == b'"' {
            v0 += 1;
            v1 = v0;
            while v1 < n && env.byte_at(v1) != b'"' {
                v1 += 1;
            }
            if v1 == n {
                break;
            }
            end = v1 + 1;
        } else {
            while v1 < n && env.byte_at(v1) != b' ' && env.byte_at(v1) != b'\t' {
                v1 += 1;
            }
            end = v1;
        }
        if end < n && env.byte_at(end) != b' ' && env.byte_at(end) != b'\t' {
            break;
        }
        let nl = eq - p;
        if nl == 0 || nl > ENV_NAME_MAX {
            break;
        }
        let mut name = String::from_str(env.slice(p, eq));
        let prev = stdlib::getenv(name.as_str());
        let had = prev != null;
        let old = if had {
            unsafe String::from_cstr(prev);
        } else {
            String::new();
        };
        let mut val = String::from_str(env.slice(v0, v1));
        unsafe sc_setenv(name.cstr(), val.cstr());
        saves.push(EnvSave { name: name, old: old, had: had });
        p = end;
    }
    env_restore(saves);
    return false;
}

/// Run `cmd` to completion and return its exit code (-1 if it could not start). The portable stand-in
/// for `system()` plus shell redirection; the test harnesses use it so their command strings hold no
/// shell syntax, which is what makes the suite run on Windows as well.
/// `in_path` null reads nothing; `out_path` null discards stdout; `err_path` null merges stderr into
/// stdout; `env` is space-separated `NAME=VALUE` (a value in double quotes may hold spaces) applied
/// to the child only (at most 8; -1 without a start when it does not apply whole). POSIX runs `cmd`
/// through /bin/sh and Windows hands the line to CreateProcess, so a command means the same on both
/// only with double quotes and no operators.
@platform(macos | ios | linux | android)
pub unsafe fn sc_run(
    cmd: *const char,
    in_path: *const char,
    out_path: *const char,
    err_path: *const char,
    env: *const char,
) i32 {
    let mut saves = Vector::<EnvSave>::new();
    if env != null && !env_apply(unsafe str::from_cstr(env), &mut saves) {
        return -1;
    }
    let mut fa = unsafe zeroed::<posix_spawn_file_actions_t>();
    unsafe posix_spawn_file_actions_init(&mut fa);
    let inp = if in_path != null {
        in_path;
    } else {
        "/dev/null".ptr() as *const char;
    };
    unsafe posix_spawn_file_actions_addopen(&mut fa, 0, inp, fcntl::O_RDONLY, 0);
    // O_APPEND: the command may start processes of its own that inherit this descriptor, and appending
    // keeps their writes from depending on a shared offset. O_TRUNC still clears the file at open.
    let outp = if out_path != null {
        out_path;
    } else {
        "/dev/null".ptr() as *const char;
    };
    let wflags = fcntl::O_WRONLY | fcntl::O_CREAT | fcntl::O_TRUNC | fcntl::O_APPEND;
    unsafe posix_spawn_file_actions_addopen(&mut fa, 1, outp, wflags, 0o644);
    if err_path != null {
        unsafe posix_spawn_file_actions_addopen(&mut fa, 2, err_path, wflags, 0o644);
    } else {
        unsafe posix_spawn_file_actions_adddup2(&mut fa, 1, 2); // 2>&1
    }
    let rc = unsafe sh_run(cmd, &fa);
    unsafe posix_spawn_file_actions_destroy(&mut fa);
    env_restore(&mut saves);
    return rc;
}

/// `sc_run` for a program whose output belongs on our own stdout/stderr (it inherits them instead of
/// being redirected); returns its exit code, or -1 if it could not start. Always use this, never
/// `system()`, to run a binary at a path we built: on Windows `system()` is cmd.exe, which drops the
/// outer quotes of its `/c` line and then splits the program name at the first '/'.
@platform(macos | ios | linux | android)
pub unsafe fn sc_exec(cmd: *const char) i32 {
    return unsafe sh_run(cmd, null);
}

// Run `cmd` through `/bin/sh -c` with the file actions `fa` (null: none) and wait: its exit code, or -1
// when it could not start or did not exit.
@platform(macos | ios | linux | android)
unsafe fn sh_run(cmd: *const char, fa: *const posix_spawn_file_actions_t) i32 {
    let argv: [*const char; 4] = ["sh".ptr() as *const char, "-c".ptr() as *const char, cmd, null];
    let mut pid: i32 = 0;
    let args = ((&argv[0]) as *const *const char) as *const *mut char;
    if unsafe posix_spawn(&mut pid, "/bin/sh".ptr() as *const char, fa, null, args, environ()) != 0 {
        return -1;
    }
    let mut st: i32 = 0;
    let mut w = unsafe waitpid(pid, &mut st, 0);
    // Bounded by the signals that interrupt the wait.
    while w < 0 && errno::errno() == EINTR {
        w = unsafe waitpid(pid, &mut st, 0);
    }
    if w != pid || (st & 0x7f) != 0 {
        return -1;
    }
    return exit_code_of(st);
}

// An inheritable handle on `path` for a child's standard stream (null: the null device). An output is
// APPEND-ONLY: the command may start processes that inherit the handle, so several write at once, and
// FILE_APPEND_DATA puts each write at the end whatever any writer thinks the position is. Creation still
// truncates, so a capture never shows a previous run; that needs write access, hence the two opens.
@platform(windows)
unsafe fn open_for_child(path: *const char, write: bool) *mut void {
    let mut sa = unsafe zeroed::<SECURITY_ATTRIBUTES>();
    sa.nLength = sizeof(SECURITY_ATTRIBUTES) as u32;
    sa.bInheritHandle = 1;
    let name = if path != null {
        path;
    } else {
        "NUL".ptr() as *const char;
    };
    let share = FILE_SHARE_READ | FILE_SHARE_WRITE;
    if !write {
        return unsafe CreateFileA(name, GENERIC_READ, share, &mut sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    }
    let trunc = unsafe CreateFileA(name, GENERIC_WRITE, share, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if trunc != INVALID_HANDLE_VALUE {
        unsafe CloseHandle(trunc);
    }
    let append = FILE_APPEND_DATA | SYNCHRONIZE;
    return unsafe CreateFileA(name, append, share, &mut sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
}

// Run the command line `cmd` with startup info `si` and wait: its exit code, or -1 when it could not start.
@platform(windows)
unsafe fn win_run(cmd: *const char, si: &mut STARTUPINFOA) i32 {
    let mut line = unsafe String::from_cstr(cmd);
    let mut pi = unsafe zeroed::<PROCESS_INFORMATION>();
    if unsafe CreateProcessA(null, line.cstr() as *mut char, null, null, 1, 0, null, null, si, &mut pi) == 0 {
        return -1;
    }
    unsafe WaitForSingleObject(pi.hProcess, INFINITE);
    let mut code: u32 = 1;
    unsafe GetExitCodeProcess(pi.hProcess, &mut code);
    unsafe CloseHandle(pi.hThread);
    unsafe CloseHandle(pi.hProcess);
    return code as i32;
}

/// Run `cmd` to completion and return its exit code (-1 if it could not start). The portable stand-in
/// for `system()` plus shell redirection; the test harnesses use it so their command strings hold no
/// shell syntax, which is what makes the suite run on Windows as well.
/// `in_path` null reads nothing; `out_path` null discards stdout; `err_path` null merges stderr into
/// stdout; `env` is space-separated `NAME=VALUE` (a value in double quotes may hold spaces) applied
/// to the child only (at most 8; -1 without a start when it does not apply whole). POSIX runs `cmd`
/// through /bin/sh and Windows hands the line to CreateProcess, so a command means the same on both
/// only with double quotes and no operators.
@platform(windows)
pub unsafe fn sc_run(
    cmd: *const char,
    in_path: *const char,
    out_path: *const char,
    err_path: *const char,
    env: *const char,
) i32 {
    let mut saves = Vector::<EnvSave>::new();
    if env != null && !env_apply(unsafe str::from_cstr(env), &mut saves) {
        return -1;
    }
    let hin = unsafe open_for_child(in_path, false);
    let hout = unsafe open_for_child(out_path, true);
    let mut herr = INVALID_HANDLE_VALUE;
    if err_path != null {
        herr = unsafe open_for_child(err_path, true);
    } else {
        // Merge stderr into stdout.
        let me = unsafe GetCurrentProcess();
        unsafe DuplicateHandle(me, hout, me, &mut herr, 0, 1, DUPLICATE_SAME_ACCESS);
    }
    let mut si = unsafe zeroed::<STARTUPINFOA>();
    si.cb = sizeof(STARTUPINFOA) as u32;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = hin;
    si.hStdOutput = hout;
    si.hStdError = herr;
    let rc = unsafe win_run(cmd, &mut si);
    if hin != INVALID_HANDLE_VALUE {
        unsafe CloseHandle(hin);
    }
    if hout != INVALID_HANDLE_VALUE {
        unsafe CloseHandle(hout);
    }
    if herr != INVALID_HANDLE_VALUE {
        unsafe CloseHandle(herr);
    }
    env_restore(&mut saves);
    return rc;
}

/// `sc_run` for a program whose output belongs on our own stdout/stderr (it inherits them instead of
/// being redirected); returns its exit code, or -1 if it could not start. Always use this, never
/// `system()`, to run a binary at a path we built: on Windows `system()` is cmd.exe, which drops the
/// outer quotes of its `/c` line and then splits the program name at the first '/'.
@platform(windows)
pub unsafe fn sc_exec(cmd: *const char) i32 {
    let mut si = unsafe zeroed::<STARTUPINFOA>();
    si.cb = sizeof(STARTUPINFOA) as u32; // no STARTF_USESTDHANDLES: the child writes to our console
    return unsafe win_run(cmd, &mut si);
}

/// Run `cmd` to completion and return its exit code: always -1 under WASI, which has no processes.
@platform(wasm)
pub unsafe fn sc_run(
    _cmd: *const char,
    _in_path: *const char,
    _out_path: *const char,
    _err_path: *const char,
    _env: *const char,
) i32 {
    return -1;
}

/// Run `cmd` with our own standard streams: always -1 under WASI, which has no processes.
@platform(wasm)
pub unsafe fn sc_exec(_cmd: *const char) i32 {
    return -1;
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
