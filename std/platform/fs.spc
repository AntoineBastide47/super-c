// Files and directories of std::platform: `open` gives a `File` that owns its native handle (a descriptor,
// or a Win32 HANDLE) and closes it when dropped; path operations take `str` paths and convert them to the
// native form inside (UTF-16 on Windows). Every call returns a `Result` with an `IoError`; an interrupted
// call runs again inside. POSIX (macOS, iOS, Linux, Android) goes through libc, Windows through the Win32
// API, WASI through std::rt::libc, which has no permission bits and no file locks: those calls are
// Unsupported there. Unstable, internal to std and the compiler.
//
// Time of check to time of use: a path names whatever file is there at the moment of each call. A `stat`
// followed by an `open`, or a `read_dir` followed by an operation on an entry, can see two different
// files when another process renames, removes or replaces one in between, and a symbolic link swapped in
// redirects any call that follows links. Decide on a handle (`File::metadata`) when that matters.
import errno;
import fcntl;
import sc_io;
import stdio;
import stdlib;
import string as cstring;
import unistd;
import std::platform::clock;
import std::platform::error;
import std::platform::path;

// ---- C bindings: POSIX and WASI ---------------------------------------------------------------------

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
    @import("stat")
    fn c_stat(path: *const char, buf: *mut stat) i32;
    @import("lstat")
    fn c_lstat(path: *const char, buf: *mut stat) i32;
    fn fstat(fd: i32, buf: *mut stat) i32;
    @import("mkdir")
    fn c_mkdir(path: *const char, mode: mode_t) i32;
    fn utimensat(dirfd: i32, path: *const char, times: *const timespec, flags: i32) i32;
    const S_IFMT: u32;
    const S_IFDIR: u32;
    const S_IFREG: u32;
    const S_IFLNK: u32;
    const UTIME_NOW: stdlib::c_long;
    const UTIME_OMIT: stdlib::c_long;
}

@platform(macos | ios | linux | android)
extern "C" "sys/stat.h" {
    @import("chmod")
    fn c_chmod(path: *const char, mode: mode_t) i32;
}

@platform(!windows)
extern "C" "unistd.h" {
    @import("readlink")
    fn c_readlink(path: *const char, buf: *mut char, size: usize) isize;
    @import("rmdir")
    fn c_rmdir(path: *const char) i32;
    @import("unlink")
    fn c_unlink(path: *const char) i32;
    @import("link")
    fn c_link(from: *const char, to: *const char) i32;
    @import("symlink")
    fn c_symlink(target: *const char, link: *const char) i32;
    fn lseek(fd: i32, offset: i64, whence: i32) i64;
    const SEEK_CUR: i32;
    const SEEK_END: i32;
}

@platform(!windows)
extern "C" "stdlib.h" {
    @import("realpath")
    fn c_realpath(path: *const char, resolved: *mut char) *mut char;
    @import("getenv")
    fn c_getenv(name: *const char) *const char;
}

@platform(!windows)
extern "C" "fcntl.h" {
    const AT_FDCWD: i32;
}

// The length of `dirent.d_name`, per platform: the directory reader views the name through a pointer
// to that array.
@platform(macos | ios)
const D_NAME_LEN: usize = 1024;
@platform(linux | android)
const D_NAME_LEN: usize = 256;
@platform(wasm)
const D_NAME_LEN: usize = 0;
@platform(macos | ios)
extern "C" "dirent.h" {
    struct dirent {
        pub d_ino: u64,
        pub d_seekoff: u64,
        pub d_reclen: u16,
        pub d_namlen: u16,
        pub d_type: u8,
        pub d_name: [char; D_NAME_LEN],
    }
}
@platform(linux | android)
extern "C" "dirent.h" {
    struct dirent {
        pub d_ino: u64,
        pub d_off: i64,
        pub d_reclen: u16,
        pub d_type: u8,
        pub d_name: [char; D_NAME_LEN],
    }
}
// The build's feature level hides the DT_* names on Darwin and glibc; both define them as these values,
// which their kernels' directory entries carry.
@platform(macos | ios | linux | android)
const DT_DIR: u8 = 4;
@platform(macos | ios | linux | android)
const DT_REG: u8 = 8;
@platform(macos | ios | linux | android)
const DT_LNK: u8 = 10;
@platform(wasm)
extern "C" "dirent.h" {
    struct dirent {
        pub d_ino: u64,
        pub d_type: u8,
        pub d_name: [char; D_NAME_LEN],
    }
    const DT_DIR: u8 = 3;
    const DT_REG: u8 = 4;
    const DT_LNK: u8 = 7;
}
@platform(!windows)
extern "C" "dirent.h" {
    type DIR;
    fn opendir(path: *const char) *mut DIR;
    fn readdir(dir: *mut DIR) *mut dirent;
    fn closedir(dir: *mut DIR) i32;
}
@platform(!windows)
const DT_UNKNOWN: u8 = 0;

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

// ---- C bindings: Windows ----------------------------------------------------------------------------

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
    @import("FILE_ATTRIBUTE_TAG_INFO")
    struct FILE_ATTRIBUTE_TAG_INFO {
        pub FileAttributes: u32,
        pub ReparseTag: u32,
    }
    @import("WIN32_FIND_DATAW")
    struct WIN32_FIND_DATAW {
        pub dwFileAttributes: u32,
        pub ftCreationTime: FILETIME,
        pub ftLastAccessTime: FILETIME,
        pub ftLastWriteTime: FILETIME,
        pub nFileSizeHigh: u32,
        pub nFileSizeLow: u32,
        pub dwReserved0: u32,
        pub dwReserved1: u32,
        pub cFileName: [u16; 260],
        pub cAlternateFileName: [u16; 14],
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
    @import("LARGE_INTEGER")
    union LARGE_INTEGER {
        @import("QuadPart")
        pub quad: i64,
    }

    // A `DWORD *` parameter is `*mut void`: DWORD is C `unsigned long`, which no Super-C type spells, and a
    // call converts its argument through `void *`.
    fn CreateFileW(
        path: *const u16,
        access: u32,
        share: u32,
        security: *mut void,
        disposition: u32,
        flags: u32,
        template: *mut void,
    ) *mut void;
    fn ReadFile(h: *mut void, buf: *mut void, n: u32, done: *mut void, ov: *mut OVERLAPPED) i32;
    fn WriteFile(h: *mut void, buf: *const void, n: u32, done: *mut void, ov: *mut OVERLAPPED) i32;
    fn SetFilePointerEx(h: *mut void, distance: LARGE_INTEGER, pos: *mut LARGE_INTEGER, method: u32) i32;
    fn FlushFileBuffers(h: *mut void) i32;
    fn GetFileInformationByHandle(h: *mut void, info: *mut BY_HANDLE_FILE_INFORMATION) i32;
    fn GetFileInformationByHandleEx(h: *mut void, class: i32, info: *mut void, size: u32) i32;
    fn CloseHandle(h: *mut void) i32;
    fn CreateDirectoryW(path: *const u16, security: *mut void) i32;
    fn RemoveDirectoryW(path: *const u16) i32;
    fn DeleteFileW(path: *const u16) i32;
    fn MoveFileExW(from: *const u16, to: *const u16, flags: u32) i32;
    fn CreateHardLinkW(link: *const u16, existing: *const u16, security: *mut void) i32;
    fn CreateSymbolicLinkW(link: *const u16, target: *const u16, flags: u32) u8;
    fn GetFileAttributesW(path: *const u16) u32;
    fn SetFileAttributesW(path: *const u16, attributes: u32) i32;
    fn GetFinalPathNameByHandleW(h: *mut void, buf: *mut u16, size: u32, flags: u32) u32;
    fn GetLongPathNameW(short: *const u16, long: *mut u16, size: u32) u32;
    fn SetFileTime(h: *mut void, created: *const FILETIME, accessed: *const FILETIME, written: *const FILETIME) i32;
    fn GetSystemTimeAsFileTime(ft: *mut FILETIME);
    fn LockFileEx(h: *mut void, flags: u32, reserved: u32, low: u32, high: u32, ov: *mut OVERLAPPED) i32;
    fn UnlockFileEx(h: *mut void, reserved: u32, low: u32, high: u32, ov: *mut OVERLAPPED) i32;
    fn FindFirstFileW(path: *const u16, data: *mut WIN32_FIND_DATAW) *mut void;
    fn FindNextFileW(h: *mut void, data: *mut WIN32_FIND_DATAW) i32;
    fn FindClose(h: *mut void) i32;
    fn DeviceIoControl(
        h: *mut void,
        code: u32,
        inbuf: *mut void,
        insize: u32,
        outbuf: *mut void,
        outsize: u32,
        returned: *mut void,
        ov: *mut OVERLAPPED,
    ) i32;
    fn GetTempPathW(size: u32, buf: *mut u16) u32;
    fn GetFileType(h: *mut void) u32;
    fn PeekNamedPipe(h: *mut void, buf: *mut void, size: u32, read: *mut void, avail: *mut void, left: *mut void) i32;
    fn WaitForSingleObject(h: *mut void, ms: u32) u32;
    fn GetStdHandle(which: u32) *mut void;
    fn GetLastError() u32;
    fn Sleep(ms: u32);

    const INVALID_HANDLE_VALUE: *mut void;
    const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
    const FILE_ATTRIBUTE_READONLY: u32 = 0x1;
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x00200000;
    const FILE_SHARE_READ: u32 = 1;
    const FILE_SHARE_WRITE: u32 = 2;
    const FILE_SHARE_DELETE: u32 = 4;
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const FILE_APPEND_DATA: u32 = 4;
    const FILE_WRITE_ATTRIBUTES: u32 = 0x100;
    const SYNCHRONIZE: u32 = 0x00100000;
    const CREATE_NEW: u32 = 1;
    const CREATE_ALWAYS: u32 = 2;
    const OPEN_EXISTING: u32 = 3;
    const OPEN_ALWAYS: u32 = 4;
    const TRUNCATE_EXISTING: u32 = 5;
    const FILE_BEGIN: u32 = 0;
    const FILE_CURRENT: u32 = 1;
    const FILE_END: u32 = 2;
    const MOVEFILE_REPLACE_EXISTING: u32 = 1;
    const SYMBOLIC_LINK_FLAG_DIRECTORY: u32 = 1;
    const SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE: u32 = 2;
    const LOCKFILE_FAIL_IMMEDIATELY: u32 = 1;
    const LOCKFILE_EXCLUSIVE_LOCK: u32 = 2;
    const FILE_TYPE_PIPE: u32 = 3;
    const WAIT_OBJECT_0: u32 = 0;
    const STD_INPUT_HANDLE: u32 = 0xFFFFFFF6;
    const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5;
    const STD_ERROR_HANDLE: u32 = 0xFFFFFFF4;
    const ERROR_FILE_NOT_FOUND: u32 = 2;
    const ERROR_ACCESS_DENIED: u32 = 5;
    const ERROR_HANDLE_EOF: u32 = 38;
    const ERROR_BROKEN_PIPE: u32 = 109;
    const ERROR_NO_MORE_FILES: u32 = 18;
    const ERROR_LOCK_VIOLATION: u32 = 33;
    const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA0000003;
    const IO_REPARSE_TAG_SYMLINK: u32 = 0xA000000C;
    const FSCTL_GET_REPARSE_POINT: u32 = 0x000900A8;
}

// `FileAttributeTagInfo` of FILE_INFO_BY_HANDLE_CLASS.
@platform(windows)
const FILE_ATTRIBUTE_TAG_INFO_CLASS: i32 = 9;

// ---- Types ------------------------------------------------------------------------------------------

/// The native handle a `File` owns: a descriptor on POSIX and WASI, a HANDLE on Windows.
@platform(!windows)
pub type RawHandle = i32;
/// The native handle a `File` owns: a descriptor on POSIX and WASI, a HANDLE on Windows.
@platform(windows)
pub type RawHandle = *mut void;

/// How `open` opens a file. Every field defaults to false (zero): `OpenOptions { read: true }` reads an
/// existing file. `mode` is the POSIX permission bits of a file `open` creates, before the umask; 0 means
/// 0o666. Windows and WASI ignore `mode`.
pub struct OpenOptions {
    pub read: bool,
    pub write: bool,
    pub append: bool, // every write goes to the end of the file
    pub truncate: bool,
    pub create: bool,
    pub create_new: bool, // create, and fail with AlreadyExists when the file exists
    pub mode: u32,
}

/// An open file, directory or pipe end. Dropping it closes the handle, which also releases its lock.
@no_const
pub struct File {
    raw: RawHandle,
}

/// Where `File::seek` counts from.
pub enum SeekFrom {
    Start(u64),
    Current(i64),
    End(i64),
}

/// The kind of a file system entry.
@derive(Eq, Format)
pub enum FileKind {
    File,
    Dir,
    Symlink,
    /// Windows only: a symbolic link or junction to a directory, which `rmdir` removes without touching its
    /// target. POSIX and WASI report every link as `Symlink`.
    DirSymlink,
    Other,
}

/// What `stat`, `lstat` and `File::metadata` report. Times are nanoseconds since the Unix epoch (UTC), in
/// 100 ns steps on Windows. `dev` and `ino` name the file: two paths with equal pairs are one file (the
/// volume serial number and file index on Windows).
pub struct Metadata {
    pub kind: FileKind,
    pub size: u64,
    /// POSIX permission bits (`0o7777` mask); on Windows 0o444 for a read-only file, else 0o666.
    pub permissions: u32,
    pub modified_ns: i64,
    pub accessed_ns: i64,
    /// None where the file system records no creation time (Linux `stat`, WASI).
    pub created_ns: Option<i64>,
    pub dev: u64,
    pub ino: u64,
    pub links: u64,
}

/// A time `set_times` gives a file.
@derive(Eq)
pub enum FileTime {
    Now,
    Keep,
    At(i64), // nanoseconds since the Unix epoch
}

/// One of the process's standard streams.
@derive(Eq)
pub enum StdStream {
    Input,
    Output,
    Error,
}

/// An open directory: its entries one by one, without `.` and `..`. Closed when dropped.
@no_const
pub struct ReadDir {
    state: DirState,
}

@platform(!windows)
struct DirState {
    pub dir: *mut DIR,
}
@platform(windows)
struct DirState {
    pub find: *mut void, // INVALID_HANDLE_VALUE for an empty listing
    pub data: WIN32_FIND_DATAW,
    pub pending: bool, // `data` holds an entry `next` has not returned yet
    pub name: String, // the UTF-8 name of the last entry: one buffer for the whole listing
}

/// One entry of a `ReadDir`, valid until the next call of `next`.
pub struct DirEntry<'a> {
    pub name: str<'a>,
    /// None when the directory listing does not say (some POSIX file systems): `lstat` the entry.
    pub kind: Option<FileKind>,
}

// ---- Opening and the File handle --------------------------------------------------------------------

/// Open `path` as `opts` says. The handle is not inherited by child processes.
@platform(!windows)
pub fn open(path: str, opts: OpenOptions) Result<File, IoError> {
    let np = path::native(path, IoOp::Open)?;
    let mut flags = if opts.read && (opts.write || opts.append) {
        fcntl::O_RDWR;
    } else if opts.write || opts.append {
        fcntl::O_WRONLY;
    } else {
        fcntl::O_RDONLY;
    };
    if opts.append {
        flags = flags | fcntl::O_APPEND;
    }
    if opts.truncate {
        flags = flags | fcntl::O_TRUNC;
    }
    if opts.create_new {
        flags = flags | fcntl::O_CREAT | fcntl::O_EXCL;
    } else if opts.create {
        flags = flags | fcntl::O_CREAT;
    }
    let mode = if opts.mode == 0 {
        0o666;
    } else {
        opts.mode;
    };
    // Bounded by the signals that interrupt the open (of a FIFO, a slow device).
    loop {
        let fd = unsafe fcntl::open(np.ptr(), flags | fcntl::O_CLOEXEC, mode);
        if fd >= 0 {
            return Result::<File, IoError>::Ok(File::adopt(fd));
        }
        if !error::interrupted() {
            return fail::<File>(IoOp::Open);
        }
    }
}
/// Open `path` as `opts` says. The handle is not inherited by child processes.
@platform(windows)
pub fn open(path: str, opts: OpenOptions) Result<File, IoError> {
    let np = path::native(path, IoOp::Open)?;
    let mut access: u32 = 0;
    if opts.read {
        access = access | GENERIC_READ;
    }
    // FILE_WRITE_DATA (in GENERIC_WRITE) would turn appends into writes at the file position.
    if opts.append {
        access = access | FILE_APPEND_DATA | FILE_WRITE_ATTRIBUTES | SYNCHRONIZE;
    } else if opts.write {
        access = access | GENERIC_WRITE;
    }
    let disposition = if opts.create_new {
        CREATE_NEW;
    } else if opts.create && opts.truncate {
        CREATE_ALWAYS;
    } else if opts.create {
        OPEN_ALWAYS;
    } else if opts.truncate {
        TRUNCATE_EXISTING;
    } else {
        OPEN_EXISTING;
    };
    // Backup semantics opens a directory too, as POSIX `open` does for reading.
    let h = unsafe CreateFileW(np.ptr(), access, SHARE_ALL, null, disposition, FILE_FLAG_BACKUP_SEMANTICS, null);
    if h == INVALID_HANDLE_VALUE {
        return fail::<File>(IoOp::Open);
    }
    return Result::<File, IoError>::Ok(File::adopt(h));
}

@platform(windows)
const SHARE_ALL: u32 = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;

/// The native handle of standard stream `s`, owned by the process: wrap it with `File::from_raw` only to
/// release it again with `File::into_raw`. NotFound on Windows when the process has no such stream.
@platform(!windows)
pub const fn std_handle(s: StdStream) Result<RawHandle, IoError> {
    return Result::<RawHandle, IoError>::Ok(
        switch s {
            Input => 0,
            Output => 1,
            Error => 2,
        },
    );
}
/// The native handle of standard stream `s`, owned by the process: wrap it with `File::from_raw` only to
/// release it again with `File::into_raw`. NotFound on Windows when the process has no such stream.
@platform(windows)
pub fn std_handle(s: StdStream) Result<RawHandle, IoError> {
    let which = switch s {
        Input => STD_INPUT_HANDLE,
        Output => STD_OUTPUT_HANDLE,
        Error => STD_ERROR_HANDLE,
    };
    let h = unsafe GetStdHandle(which);
    if h == INVALID_HANDLE_VALUE {
        return fail::<RawHandle>(IoOp::Open);
    }
    if h == null {
        return Result::<RawHandle, IoError>::Err(IoError::new(IoErrorKind::NotFound, IoOp::Open));
    }
    return Result::<RawHandle, IoError>::Ok(h);
}

// ---- Metadata ---------------------------------------------------------------------------------------

/// The metadata of the file `path` names, following symbolic links.
@platform(!windows)
pub fn stat(path: str) Result<Metadata, IoError> {
    let np = path::native(path, IoOp::Stat)?;
    let mut st = unsafe zeroed::<stat>();
    if unsafe c_stat(np.ptr(), &mut st) != 0 {
        return fail::<Metadata>(IoOp::Stat);
    }
    return Result::<Metadata, IoError>::Ok(metadata_of(&st));
}
/// The metadata of the file `path` names, following symbolic links.
@platform(windows)
pub fn stat(path: str) Result<Metadata, IoError> {
    return stat_windows(path, false);
}

/// The metadata of `path` itself: a symbolic link reports as one, not as its target.
@platform(!windows)
pub fn lstat(path: str) Result<Metadata, IoError> {
    let np = path::native(path, IoOp::Stat)?;
    let mut st = unsafe zeroed::<stat>();
    if unsafe c_lstat(np.ptr(), &mut st) != 0 {
        return fail::<Metadata>(IoOp::Stat);
    }
    return Result::<Metadata, IoError>::Ok(metadata_of(&st));
}
/// The metadata of `path` itself: a symbolic link reports as one, not as its target.
@platform(windows)
pub fn lstat(path: str) Result<Metadata, IoError> {
    return stat_windows(path, true);
}

// Windows `stat` (`link` false) or `lstat`: one handle that asks for no access, so no sharing mode of
// another opener refuses it, and a directory opens too.
@platform(windows)
fn stat_windows(path: str, link: bool) Result<Metadata, IoError> {
    let np = path::native(path, IoOp::Stat)?;
    let mut flags = FILE_FLAG_BACKUP_SEMANTICS;
    if link {
        flags = flags | FILE_FLAG_OPEN_REPARSE_POINT;
    }
    let h = unsafe CreateFileW(np.ptr(), 0, SHARE_ALL, null, OPEN_EXISTING, flags, null);
    if h == INVALID_HANDLE_VALUE {
        return fail::<Metadata>(IoOp::Stat);
    }
    let f = File::adopt(h);
    return f.metadata();
}

@platform(!windows)
const fn metadata_of(st: &stat) Metadata {
    let mode: u32 = st.st_mode;
    let fmt = mode & S_IFMT;
    let kind = if fmt == S_IFREG {
        FileKind::File;
    } else if fmt == S_IFDIR {
        FileKind::Dir;
    } else if fmt == S_IFLNK {
        FileKind::Symlink;
    } else {
        FileKind::Other;
    };
    let (m, a, c) = times_of(st);
    let dev: u64 = (st.st_dev as i64) as u64;
    let links: u64 = st.st_nlink;
    return Metadata {
        kind: kind,
        size: st.st_size as u64,
        permissions: mode & 0o7777,
        modified_ns: m,
        accessed_ns: a,
        created_ns: c,
        dev: dev,
        ino: st.st_ino,
        links: links,
    };
}

// The modification, access and creation times of `st`.
@platform(macos | ios)
const fn times_of(st: &stat) (i64, i64, Option<i64>) {
    return ns_of(st.st_mtime, st.st_mtimensec as i64), ns_of(st.st_atime, st.st_atimensec as i64), Option::<i64>::Some(
        ns_of(st.st_birthtime, st.st_birthtimensec as i64),
    );
}
@platform(linux | android | wasm)
fn times_of(st: &stat) (i64, i64, Option<i64>) {
    return ns_of(st.st_mtim.tv_sec, st.st_mtim.tv_nsec as i64), ns_of(st.st_atim.tv_sec, st.st_atim.tv_nsec as i64), Option::<
        i64
    >::None;
}

@platform(!windows)
const fn ns_of(s: i64, ns: i64) i64 {
    return s * 1000000000 + ns;
}

@platform(windows)
fn ft_ns(ft: FILETIME) i64 {
    return clock::filetime_unix_ns(ft.dwHighDateTime as u64 << 32 | ft.dwLowDateTime as u64);
}

@platform(windows)
fn kind_of_attributes(attributes: u32, tag: u32) FileKind {
    let dir = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 && (tag == IO_REPARSE_TAG_SYMLINK || tag == IO_REPARSE_TAG_MOUNT_POINT) {
        if dir {
            return FileKind::DirSymlink;
        }
        return FileKind::Symlink;
    }
    if dir {
        return FileKind::Dir;
    }
    return FileKind::File;
}

// ---- Directories ------------------------------------------------------------------------------------

/// Open directory `path` for listing.
@platform(!windows)
pub fn read_dir(path: str) Result<ReadDir, IoError> {
    let np = path::native(path, IoOp::ReadDir)?;
    let d = unsafe opendir(np.ptr());
    if d == null {
        return fail::<ReadDir>(IoOp::ReadDir);
    }
    return Result::<ReadDir, IoError>::Ok(ReadDir::adopt(DirState { dir: d }));
}
/// Open directory `path` for listing.
@platform(windows)
pub fn read_dir(path: str) Result<ReadDir, IoError> {
    let mut pattern = String::with_capacity(path.len() + 2);
    pattern.push_str(path);
    if pattern.len() == 0 || !path::is_separator(pattern.byte(pattern.len() - 1)) {
        pattern.push_byte(b'\\');
    }
    pattern.push_byte(b'*');
    let np = path::native(pattern.as_str(), IoOp::ReadDir)?;
    let mut st = DirState {
        find: INVALID_HANDLE_VALUE,
        data: unsafe zeroed::<WIN32_FIND_DATAW>(),
        pending: false,
        name: String::new(),
    };
    st.find = unsafe FindFirstFileW(np.ptr(), &mut st.data);
    if st.find == INVALID_HANDLE_VALUE {
        // An existing directory with no entry at all (a drive root) is an empty listing.
        if unsafe GetLastError() != ERROR_FILE_NOT_FOUND {
            return fail::<ReadDir>(IoOp::ReadDir);
        }
    } else {
        st.pending = true;
    }
    return Result::<ReadDir, IoError>::Ok(ReadDir::adopt(st));
}

/// Create directory `path` (mode 0o775 before the umask on POSIX). AlreadyExists when anything is there.
@platform(!windows)
pub fn mkdir(path: str) Result<Unit, IoError> {
    let np = path::native(path, IoOp::CreateDir)?;
    if unsafe c_mkdir(np.ptr(), 0o775) != 0 {
        return fail::<Unit>(IoOp::CreateDir);
    }
    return done();
}
/// Create directory `path` (mode 0o775 before the umask on POSIX). AlreadyExists when anything is there.
@platform(windows)
pub fn mkdir(path: str) Result<Unit, IoError> {
    let np = path::native(path, IoOp::CreateDir)?;
    if unsafe CreateDirectoryW(np.ptr(), null) == 0 {
        return fail::<Unit>(IoOp::CreateDir);
    }
    return done();
}

/// Create directory `path` and every missing parent (`mkdir -p`). Succeeds when `path` already is a
/// directory, also when another process creates it at the same time; AlreadyExists when it is another
/// kind of file.
pub fn mkdir_all(path: str) Result<Unit, IoError> {
    let r = mkdir(path);
    if r.is_ok() {
        return r;
    }
    let e = r.unwrap_err();
    if e.kind == IoErrorKind::AlreadyExists || e.kind == IoErrorKind::PermissionDenied {
        // An existing directory answers either way: a read-only parent refuses with PermissionDenied
        // before it looks at the name.
        if let Ok(m) = stat(path) {
            if m.kind == FileKind::Dir {
                return done();
            }
        }
        return Result::<Unit, IoError>::Err(e);
    }
    let cut = parent_len(path);
    if e.kind != IoErrorKind::NotFound || cut == 0 {
        return Result::<Unit, IoError>::Err(e);
    }
    // Each level shortens the path by at least one component.
    mkdir_all(path.slice(0, cut))?;
    let again = mkdir(path);
    if again.is_err() && stat(path).map(|m: Metadata| m.kind == FileKind::Dir).unwrap_or(false) {
        return done();
    }
    return again;
}

// The length of the parent of `p` (trailing separators and the last component cut, then the separators
// before it); 0 when `p` has no parent to create.
const fn parent_len(p: str) usize {
    let mut k = p.len();
    while k > 0 && path::is_separator(p.byte_at(k - 1)) {
        k -= 1;
    }
    while k > 0 && !path::is_separator(p.byte_at(k - 1)) {
        k -= 1;
    }
    while k > 1 && path::is_separator(p.byte_at(k - 1)) {
        k -= 1;
    }
    if k == 1 && path::is_separator(p.byte_at(0)) {
        return 0; // the root
    }
    return k;
}

/// Remove the empty directory `path` (on Windows also a directory symbolic link or junction).
@platform(!windows)
pub fn rmdir(path: str) Result<Unit, IoError> {
    let np = path::native(path, IoOp::RemoveDir)?;
    if unsafe c_rmdir(np.ptr()) != 0 {
        return fail::<Unit>(IoOp::RemoveDir);
    }
    return done();
}
/// Remove the empty directory `path` (on Windows also a directory symbolic link or junction).
@platform(windows)
pub fn rmdir(path: str) Result<Unit, IoError> {
    let np = path::native(path, IoOp::RemoveDir)?;
    if unsafe RemoveDirectoryW(np.ptr()) == 0 {
        return fail::<Unit>(IoOp::RemoveDir);
    }
    return done();
}

/// Remove the name `path` of a file or a symbolic link (never its target). Windows refuses a read-only
/// file: PermissionDenied (`remove_all` clears the flag first).
@platform(!windows)
pub fn unlink(path: str) Result<Unit, IoError> {
    let np = path::native(path, IoOp::Unlink)?;
    if unsafe c_unlink(np.ptr()) != 0 {
        return fail::<Unit>(IoOp::Unlink);
    }
    return done();
}
/// Remove the name `path` of a file or a symbolic link (never its target). Windows refuses a read-only
/// file: PermissionDenied (`remove_all` clears the flag first).
@platform(windows)
pub fn unlink(path: str) Result<Unit, IoError> {
    let np = path::native(path, IoOp::Unlink)?;
    if unsafe DeleteFileW(np.ptr()) == 0 {
        return fail::<Unit>(IoOp::Unlink);
    }
    return done();
}

/// Remove `path` and everything under it (`rm -rf`): a symbolic link or junction is removed, never
/// followed, and a read-only file is made writable first on Windows. A missing `path` succeeds. The walk
/// goes on past a failure and returns the first one. Another process that creates entries in the tree
/// while it runs can leave some behind (a failed `rmdir`).
pub fn remove_all(path: str) Result<Unit, IoError> {
    let m = lstat(path);
    if m.is_err() {
        let e = m.unwrap_err();
        if e.kind == IoErrorKind::NotFound {
            return done();
        }
        return Result::<Unit, IoError>::Err(e);
    }
    let mut buf = String::from_str(path);
    return remove_tree(&mut buf, Option::<FileKind>::Some(m.unwrap().kind));
}

// Remove the tree at `p` (restored on return) of kind `kind` (None: lstat it). Recursion depth is the
// tree's depth: each level holds one open directory.
fn remove_tree(p: &mut String, kind: Option<FileKind>) Result<Unit, IoError> {
    let k = if let Some(x) = kind {
        x;
    } else {
        let m = lstat(p.as_str());
        if m.is_err() {
            return Result::<Unit, IoError>::Err(m.unwrap_err());
        }
        m.unwrap().kind;
    };
    if k != FileKind::Dir {
        if k == FileKind::DirSymlink {
            return remove_writable(p.as_str(), true);
        }
        return remove_writable(p.as_str(), false);
    }
    let mut first = Result::<Unit, IoError>::Ok(Unit {});
    let base = p.len();
    {
        let opened = read_dir(p.as_str());
        if opened.is_err() {
            return Result::<Unit, IoError>::Err(opened.unwrap_err());
        }
        let mut d = opened.unwrap();
        // Bounded by the entries of the directory.
        loop {
            let mut child_kind = Option::<FileKind>::None;
            {
                let next = d.next();
                if next.is_none() {
                    break;
                }
                let r = next.unwrap();
                if r.is_err() {
                    if first.is_ok() {
                        first = Result::<Unit, IoError>::Err(r.unwrap_err());
                    }
                    break;
                }
                let e = r.unwrap();
                p.push_byte(b'/');
                p.push_str(e.name);
                child_kind = e.kind;
            }
            let r = remove_tree(p, child_kind);
            if r.is_err() && first.is_ok() {
                first = r;
            }
            p.truncate(base);
        }
    }
    let r = remove_writable(p.as_str(), true);
    if first.is_ok() {
        return r;
    }
    return first;
}

// Remove the file (`dir` false) or empty directory `p`; on Windows a read-only one loses its read-only
// flag and is removed again.
@platform(!windows)
fn remove_writable(p: str, dir: bool) Result<Unit, IoError> {
    if dir {
        return rmdir(p);
    }
    return unlink(p);
}
@platform(windows)
fn remove_writable(p: str, dir: bool) Result<Unit, IoError> {
    let mut r = if dir {
        rmdir(p);
    } else {
        unlink(p);
    };
    if r.is_ok() || r.unwrap_err().code != ERROR_ACCESS_DENIED as i32 {
        return r;
    }
    let np = path::native(p, IoOp::Unlink)?;
    let a = unsafe GetFileAttributesW(np.ptr());
    if a == INVALID_FILE_ATTRIBUTES || (a & FILE_ATTRIBUTE_READONLY) == 0 {
        return r;
    }
    if unsafe SetFileAttributesW(np.ptr(), a & ~FILE_ATTRIBUTE_READONLY) == 0 {
        return r;
    }
    r = if dir {
        rmdir(p);
    } else {
        unlink(p);
    };
    return r;
}

// ---- Names and links --------------------------------------------------------------------------------

/// Rename `from` to `to`, replacing a file at `to`. On Windows a `to` that is a running executable, which
/// Windows will not replace, is renamed aside to `<to>.old` first (removed by the next such rename that
/// finds it free), so a program can replace itself.
@platform(!windows)
pub fn rename(from: str, to: str) Result<Unit, IoError> {
    let a = path::native(from, IoOp::Rename)?;
    let b = path::native(to, IoOp::Rename)?;
    if unsafe stdio::rename(a.ptr(), b.ptr()) != 0 {
        return fail::<Unit>(IoOp::Rename);
    }
    return done();
}
/// Rename `from` to `to`, replacing a file at `to`. On Windows a `to` that is a running executable, which
/// Windows will not replace, is renamed aside to `<to>.old` first (removed by the next such rename that
/// finds it free), so a program can replace itself.
@platform(windows)
pub fn rename(from: str, to: str) Result<Unit, IoError> {
    let a = path::native(from, IoOp::Rename)?;
    let b = path::native(to, IoOp::Rename)?;
    if unsafe MoveFileExW(a.ptr(), b.ptr(), MOVEFILE_REPLACE_EXISTING) != 0 {
        return done();
    }
    let e = error::last_error(IoOp::Rename);
    // Windows refuses to delete or overwrite a running image but lets it be renamed: the mapped section
    // holds the file object, not the name.
    let mut side = String::from_str(to);
    side.push_str(".old");
    let s = path::native(side.as_str(), IoOp::Rename)?;
    unsafe DeleteFileW(s.ptr());
    if unsafe MoveFileExW(b.ptr(), s.ptr(), MOVEFILE_REPLACE_EXISTING) == 0 {
        return Result::<Unit, IoError>::Err(e);
    }
    if unsafe MoveFileExW(a.ptr(), b.ptr(), MOVEFILE_REPLACE_EXISTING) != 0 {
        return done();
    }
    let e2 = error::last_error(IoOp::Rename);
    unsafe MoveFileExW(s.ptr(), b.ptr(), MOVEFILE_REPLACE_EXISTING); // the name must not stay empty
    return Result::<Unit, IoError>::Err(e2);
}

/// Give the file `from` the second name `to` (a hard link).
@platform(!windows)
pub fn link(from: str, to: str) Result<Unit, IoError> {
    let a = path::native(from, IoOp::Link)?;
    let b = path::native(to, IoOp::Link)?;
    if unsafe c_link(a.ptr(), b.ptr()) != 0 {
        return fail::<Unit>(IoOp::Link);
    }
    return done();
}
/// Give the file `from` the second name `to` (a hard link).
@platform(windows)
pub fn link(from: str, to: str) Result<Unit, IoError> {
    let a = path::native(from, IoOp::Link)?;
    let b = path::native(to, IoOp::Link)?;
    if unsafe CreateHardLinkW(b.ptr(), a.ptr(), null) == 0 {
        return fail::<Unit>(IoOp::Link);
    }
    return done();
}

/// Create the symbolic link `link` whose text is `target`. On Windows a link to an existing directory is
/// a directory link, and creating one needs developer mode or the symbolic-link privilege
/// (PermissionDenied otherwise).
@platform(!windows)
pub fn symlink(target: str, link: str) Result<Unit, IoError> {
    let a = path::native(target, IoOp::Symlink)?;
    let b = path::native(link, IoOp::Symlink)?;
    if unsafe c_symlink(a.ptr(), b.ptr()) != 0 {
        return fail::<Unit>(IoOp::Symlink);
    }
    return done();
}
/// Create the symbolic link `link` whose text is `target`. On Windows a link to an existing directory is
/// a directory link, and creating one needs developer mode or the symbolic-link privilege
/// (PermissionDenied otherwise).
@platform(windows)
pub fn symlink(target: str, link: str) Result<Unit, IoError> {
    let a = path::native(target, IoOp::Symlink)?;
    let b = path::native(link, IoOp::Symlink)?;
    // A relative target names a path from the link's directory: resolve it there to find its kind.
    let mut flags = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
    let mut probe = String::new();
    if !path::is_absolute(target) {
        probe.push_str(link.slice(0, parent_len(link)));
        if probe.len() != 0 {
            probe.push_byte(b'/');
        }
    }
    probe.push_str(target);
    if let Ok(m) = stat(probe.as_str()) {
        if m.kind == FileKind::Dir {
            flags = flags | SYMBOLIC_LINK_FLAG_DIRECTORY;
        }
    }
    if unsafe CreateSymbolicLinkW(b.ptr(), a.ptr(), flags) == 0 {
        return fail::<Unit>(IoOp::Symlink);
    }
    return done();
}

/// The text of symbolic link `path` (the link need not resolve). InvalidInput when `path` is no link.
@platform(!windows)
pub fn readlink(path: str) Result<String, IoError> {
    let np = path::native(path, IoOp::ReadLink)?;
    let mut small: [char; 1024] = [0 as char; 1024];
    let n = unsafe c_readlink(np.ptr(), &mut small[0], 1024);
    if n < 0 {
        return fail::<String>(IoOp::ReadLink);
    }
    if n as usize < 1024 {
        let mut out = String::new();
        out.push_bytes(unsafe Slice::<u8> { ptr: ((&small[0]) as *const char) as *const u8, len: n as usize });
        return Result::<String, IoError>::Ok(out);
    }
    // A text that fills the buffer may be cut: read it again into a buffer that doubles each pass, up to
    // a size no file system allows.
    let mut cap: usize = 4096;
    while cap <= 1 << 20 {
        let mut out = String::with_capacity(cap);
        let m = unsafe c_readlink(np.ptr(), out.spare_mut(cap) as *mut char, cap);
        if m < 0 {
            return fail::<String>(IoOp::ReadLink);
        }
        if m as usize < cap {
            out.advance_len(m as usize);
            return Result::<String, IoError>::Ok(out);
        }
        cap = cap * 2;
    }
    return Result::<String, IoError>::Err(IoError::new(IoErrorKind::LimitExceeded, IoOp::ReadLink));
}
/// The text of symbolic link `path` (the link need not resolve). InvalidInput when `path` is no link.
@platform(windows)
pub fn readlink(path: str) Result<String, IoError> {
    let np = path::native(path, IoOp::ReadLink)?;
    let flags = FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT;
    let h = unsafe CreateFileW(np.ptr(), 0, SHARE_ALL, null, OPEN_EXISTING, flags, null);
    if h == INVALID_HANDLE_VALUE {
        return fail::<String>(IoOp::ReadLink);
    }
    let f = File::adopt(h);
    // MAXIMUM_REPARSE_DATA_BUFFER_SIZE: the largest reparse data a file holds.
    let mut buf = Vector::<u8>::new();
    buf.resize_default(16384);
    let mut got: u32 = 0;
    let p = buf.index_range_mut(0..16384).as_mut_ptr();
    if unsafe DeviceIoControl(f.raw(), FSCTL_GET_REPARSE_POINT, null, 0, p, 16384, &mut got, null) == 0 {
        return fail::<String>(IoOp::ReadLink);
    }
    return reparse_text(buf[0..got as usize]);
}

// The link text of REPARSE_DATA_BUFFER `b`: the print name, else the substitute name without its NT
// prefix `\??\`. A symbolic link's path buffer starts at byte 20, after its flags; a junction's at 16.
@platform(windows)
fn reparse_text(b: []u8) Result<String, IoError> {
    let bad = Result::<String, IoError>::Err(IoError::new(IoErrorKind::InvalidInput, IoOp::ReadLink));
    if b.len() < 16 {
        return bad;
    }
    let tag = le32(b, 0);
    let names: usize = if tag == IO_REPARSE_TAG_SYMLINK {
        20;
    } else if tag == IO_REPARSE_TAG_MOUNT_POINT {
        16;
    } else {
        return bad;
    };
    let mut off = le16(b, 12) as usize; // the print name
    let mut len = le16(b, 14) as usize;
    let mut strip: usize = 0;
    if len == 0 {
        off = le16(b, 8) as usize; // the substitute name
        len = le16(b, 10) as usize;
        if len >= 8 && le16(b, names + off) == b'\\' as u16 && le16(b, names + off + 2) == b'?' as u16 {
            strip = 8;
        }
    }
    if names + off + len > b.len() || len % 2 != 0 {
        return bad;
    }
    let mut units = Vector::<u16>::with_capacity(len / 2);
    let mut i = strip;
    while i < len {
        units.push(le16(b, names + off + i));
        i += 2;
    }
    let mut out = String::new();
    path::push_wide(&mut out, units[0..units.len()], false, IoOp::ReadLink)?;
    return Result::<String, IoError>::Ok(out);
}

@platform(windows)
fn le16(b: []u8, i: usize) u16 {
    return b[i] as u16 | b[i + 1] as u16 << 8;
}

@platform(windows)
fn le32(b: []u8, i: usize) u32 {
    return le16(b, i) as u32 | le16(b, i + 2) as u32 << 16;
}

/// The absolute path of `path`, which must exist. POSIX and WASI resolve every symbolic link and `..`;
/// Windows makes the path absolute and normal (`..` folded) without resolving links, with '/' separators.
@platform(!windows)
pub fn realpath(path: str) Result<String, IoError> {
    let np = path::native(path, IoOp::RealPath)?;
    // PATH_MAX of Linux; Darwin's is 1024.
    let mut out = String::with_capacity(4096);
    let r = unsafe c_realpath(np.ptr(), out.spare_mut(4096) as *mut char);
    if r == null {
        return fail::<String>(IoOp::RealPath);
    }
    out.advance_len(unsafe cstring::strlen(r));
    return Result::<String, IoError>::Ok(out);
}
/// The absolute path of `path`, which must exist, with every symbolic link and `..` resolved. Windows gives
/// the final path of the file it opens, in long names, with '/' separators and without the `\\?\` prefix:
/// `C:/dir/file`, or `//server/share/file` for a share.
@platform(windows)
pub fn realpath(path: str) Result<String, IoError> {
    let np = path::native(path, IoOp::RealPath)?;
    // No access: the handle only names the file, a directory too, the links followed.
    let h = unsafe CreateFileW(np.ptr(), 0, SHARE_ALL, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
    if h == INVALID_HANDLE_VALUE {
        return fail::<String>(IoOp::RealPath);
    }
    let f = File::adopt(h);
    let mut buf = Vector::<u16>::new();
    let mut cap: u32 = 512;
    // At most two passes: the second has the size the first reported.
    for _ in 0..3 {
        buf.clear();
        buf.resize_default(cap as usize);
        let n = unsafe GetFinalPathNameByHandleW(f.raw(), buf.index_range_mut(0..cap as usize).as_mut_ptr(), cap, 0);
        if n == 0 {
            return fail::<String>(IoOp::RealPath);
        }
        if n < cap {
            let w = buf[0..n as usize];
            let mut out = String::new();
            if wide_prefix(w, "\\\\?\\UNC\\") {
                out.push_str("//");
                path::push_wide(&mut out, w[8..w.len()], true, IoOp::RealPath)?;
            } else if wide_prefix(w, "\\\\?\\") {
                path::push_wide(&mut out, w[4..w.len()], true, IoOp::RealPath)?;
            } else {
                path::push_wide(&mut out, w, true, IoOp::RealPath)?;
            }
            return Result::<String, IoError>::Ok(out);
        }
        cap = n;
    }
    return Result::<String, IoError>::Err(IoError::new(IoErrorKind::Other, IoOp::RealPath));
}

// Whether the wide string `w` starts with the ASCII text `p`.
@platform(windows)
const fn wide_prefix(w: []u16, p: str) bool {
    if w.len() < p.len() {
        return false;
    }
    for i in 0..p.len() {
        if w[i] != p.byte_at(i) as u16 {
            return false;
        }
    }
    return true;
}

// ---- Permissions and times --------------------------------------------------------------------------

/// Set the POSIX permission bits of `path` (`mode & 0o7777`), following links. Windows keeps only the
/// owner's write bit: without it the file becomes read-only. Unsupported on WASI.
@platform(macos | ios | linux | android)
pub fn set_permissions(path: str, mode: u32) Result<Unit, IoError> {
    let np = path::native(path, IoOp::SetPermissions)?;
    if unsafe c_chmod(np.ptr(), (mode & 0o7777) as mode_t) != 0 {
        return fail::<Unit>(IoOp::SetPermissions);
    }
    return done();
}
/// Set the POSIX permission bits of `path` (`mode & 0o7777`), following links. Windows keeps only the
/// owner's write bit: without it the file becomes read-only. Unsupported on WASI.
@platform(windows)
pub fn set_permissions(path: str, mode: u32) Result<Unit, IoError> {
    let np = path::native(path, IoOp::SetPermissions)?;
    let a = unsafe GetFileAttributesW(np.ptr());
    if a == INVALID_FILE_ATTRIBUTES {
        return fail::<Unit>(IoOp::SetPermissions);
    }
    let b = if (mode & 0o200) == 0 {
        a | FILE_ATTRIBUTE_READONLY;
    } else {
        a & ~FILE_ATTRIBUTE_READONLY;
    };
    if b != a && unsafe SetFileAttributesW(np.ptr(), b) == 0 {
        return fail::<Unit>(IoOp::SetPermissions);
    }
    return done();
}
/// Set the POSIX permission bits of `path` (`mode & 0o7777`), following links. Windows keeps only the
/// owner's write bit: without it the file becomes read-only. Unsupported on WASI.
@platform(wasm)
pub fn set_permissions(_path: str, _mode: u32) Result<Unit, IoError> {
    return Result::<Unit, IoError>::Err(error::unsupported(IoOp::SetPermissions));
}

/// Set the access and modification times of `path`, following links (`touch`: both `FileTime::Now`).
@platform(!windows)
pub fn set_times(path: str, accessed: FileTime, modified: FileTime) Result<Unit, IoError> {
    let np = path::native(path, IoOp::SetTimes)?;
    let ts: [timespec; 2] = [timespec_of(accessed), timespec_of(modified)];
    if unsafe utimensat(AT_FDCWD, np.ptr(), &ts[0], 0) != 0 {
        return fail::<Unit>(IoOp::SetTimes);
    }
    return done();
}
/// Set the access and modification times of `path`, following links (`touch`: both `FileTime::Now`).
@platform(windows)
pub fn set_times(path: str, accessed: FileTime, modified: FileTime) Result<Unit, IoError> {
    let np = path::native(path, IoOp::SetTimes)?;
    let h = unsafe CreateFileW(
        np.ptr(),
        FILE_WRITE_ATTRIBUTES,
        SHARE_ALL,
        null,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if h == INVALID_HANDLE_VALUE {
        return fail::<Unit>(IoOp::SetTimes);
    }
    let f = File::adopt(h);
    let mut now = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
    unsafe GetSystemTimeAsFileTime(&mut now);
    let a = filetime_of(accessed, now);
    let m = filetime_of(modified, now);
    let pa: *const FILETIME = if accessed == FileTime::Keep {
        null;
    } else {
        &a;
    };
    let pm: *const FILETIME = if modified == FileTime::Keep {
        null;
    } else {
        &m;
    };
    if unsafe SetFileTime(f.raw(), null, pa, pm) == 0 {
        return fail::<Unit>(IoOp::SetTimes);
    }
    return done();
}

@platform(!windows)
const fn timespec_of(t: FileTime) timespec {
    return switch t {
        Now => timespec { tv_sec: 0, tv_nsec: UTIME_NOW },
        Keep => timespec { tv_sec: 0, tv_nsec: UTIME_OMIT },
        At(ns) => {
            let (sec, sub) = split_ns(ns);
            timespec { tv_sec: sec, tv_nsec: sub as stdlib::c_long };
        },
    };
}

// `ns` as whole seconds (rounded down) and the nanoseconds past them.
@platform(!windows)
const fn split_ns(ns: i64) (i64, i64) {
    let sec = ns / 1000000000;
    let sub = ns % 1000000000;
    if sub < 0 {
        return sec - 1, sub + 1000000000;
    }
    return sec, sub;
}

@platform(windows)
fn filetime_of(t: FileTime, now: FILETIME) FILETIME {
    return switch t {
        At(ns) => {
            let ticks = if ns < 0 && ns % 100 != 0 {
                ns / 100 - 1;
            } else {
                ns / 100;
            };
            let v = (ticks + 116444736000000000) as u64;
            FILETIME { dwLowDateTime: v as u32, dwHighDateTime: (v >> 32) as u32 };
        },
        _ => now,
    };
}

// ---- Whole files and the temporary directory --------------------------------------------------------

/// Make file `path` hold exactly `bytes`, creating missing parent directories: true when it was written,
/// false when it already held them, so it keeps its modification time. The comparison reads through a
/// 16 KiB stack buffer (no allocation); the write truncates the file and writes it in place, so a reader
/// at the same time can see it partly written.
pub fn publish(path: str, bytes: []u8) Result<bool, IoError> {
    if let Ok(mut f) = open(path, OpenOptions { read: true }) {
        if f.holds(bytes)? {
            return Result::<bool, IoError>::Ok(false);
        }
    }
    let w = OpenOptions { write: true, create: true, truncate: true };
    let first = open(path, w);
    let mut f = if first.is_ok() {
        first.unwrap();
    } else {
        // The parent directories exist for all but the first file written into each.
        let e = first.unwrap_err();
        let cut = parent_len(path);
        if e.kind != IoErrorKind::NotFound || cut == 0 {
            return Result::<bool, IoError>::Err(e);
        }
        mkdir_all(path.slice(0, cut))?;
        open(path, w)?;
    };
    f.write_all(bytes)?;
    f.close()?;
    return Result::<bool, IoError>::Ok(true);
}

/// The system's directory for temporary files, without a trailing separator: TMPDIR, else /tmp, on POSIX
/// and WASI; GetTempPathW (TMP, TEMP, USERPROFILE, the Windows directory) with '/' separators on Windows.
@platform(!windows)
pub fn temp_dir() Result<String, IoError> {
    let t = unsafe c_getenv("TMPDIR".ptr() as *const char);
    let mut out = if t == null || unsafe *t == 0 as char {
        String::from_str("/tmp");
    } else {
        unsafe String::from_cstr(t);
    };
    while out.len() > 1 && out.byte(out.len() - 1) == b'/' {
        out.truncate(out.len() - 1);
    }
    return Result::<String, IoError>::Ok(out);
}
/// The system's directory for temporary files, without a trailing separator: TMPDIR, else /tmp, on POSIX
/// and WASI; GetTempPathW (TMP, TEMP, USERPROFILE, the Windows directory) in long names (an 8.3 short name
/// such as `RUNNER~1` spelled out, as `realpath` spells it) with '/' separators on Windows.
@platform(windows)
pub fn temp_dir() Result<String, IoError> {
    // MAX_PATH + 1: the most GetTempPathW returns.
    let mut short: [u16; 261] = [0; 261];
    let s = unsafe GetTempPathW(261, &mut short[0]);
    if s == 0 || s > 261 {
        return fail::<String>(IoOp::TempDir);
    }
    // The longest path Windows takes, 32767 units and the NUL.
    let mut buf = Vector::<u16>::new();
    buf.resize_default(32768);
    let n = unsafe GetLongPathNameW(&short[0], buf.index_range_mut(0..32768).as_mut_ptr(), 32768);
    if n == 0 || n >= 32768 {
        return fail::<String>(IoOp::TempDir);
    }
    let mut out = String::new();
    path::push_wide(&mut out, buf[0..n as usize], true, IoOp::TempDir)?;
    while out.len() > 1 && out.byte(out.len() - 1) == b'/' {
        out.truncate(out.len() - 1);
    }
    return Result::<String, IoError>::Ok(out);
}

// ---- Helpers ----------------------------------------------------------------------------------------

const fn done() Result<Unit, IoError> {
    return Result::<Unit, IoError>::Ok(Unit {});
}

fn fail<T>(op: IoOp) Result<T, IoError> {
    return Result::<T, IoError>::Err(error::last_error(op));
}

// ---- File -------------------------------------------------------------------------------------------

extend File {
    fn adopt(raw: RawHandle) File {
        return File { raw: raw };
    }

    /// Take ownership of the open native handle `raw`: the File closes it.
    /// Safety: `raw` is open, and nothing else closes it or wraps it in another File.
    pub unsafe fn from_raw(raw: RawHandle) File {
        return File::adopt(raw);
    }
    /// Give up the handle without closing it.
    pub fn into_raw(self: File) RawHandle {
        let r = self.raw;
        forget(self);
        return r;
    }
    /// The handle, still owned by the File.
    pub fn raw(self: &File) RawHandle {
        return self.raw;
    }

    /// Close the file and report a failure of the close itself (a write-back error of some file
    /// systems), which dropping the File ignores.
    @platform(!windows)
    pub fn close(self: File) Result<Unit, IoError> {
        let r = self.into_raw();
        if unsafe unistd::close(r) != 0 {
            return fail::<Unit>(IoOp::Close);
        }
        return done();
    }
    /// Close the file and report a failure of the close itself (a write-back error of some file
    /// systems), which dropping the File ignores.
    @platform(windows)
    pub fn close(self: File) Result<Unit, IoError> {
        let r = self.into_raw();
        if unsafe CloseHandle(r) == 0 {
            return fail::<Unit>(IoOp::Close);
        }
        return done();
    }

    /// Read until `buf` is full or the stream ends: the count read. A failure after a partial read is
    /// returned, and the bytes read before it are lost.
    pub fn read_full(self: &mut File, mut buf: []mut u8) Result<usize, IoError> {
        let mut got: usize = 0;
        // Each pass reads at least one byte or ends the loop.
        while got < buf.len() {
            let n = self.read(buf.index_range_mut(got..buf.len()))?;
            if n == 0 {
                break;
            }
            got += n;
        }
        return Result::<usize, IoError>::Ok(got);
    }

    /// Write all of `bytes`. A write that accepts no byte is an error (Other).
    pub fn write_all(self: &mut File, bytes: []u8) Result<Unit, IoError> {
        let mut off: usize = 0;
        // Each pass writes at least one byte or returns.
        while off < bytes.len() {
            let n = self.write(bytes[off..bytes.len()])?;
            if n == 0 {
                return Result::<Unit, IoError>::Err(IoError::new(IoErrorKind::Other, IoOp::Write));
            }
            off += n;
        }
        return done();
    }

    // Whether the rest of the file, from its current position, is exactly `want`, read through a
    // 16 KiB stack buffer.
    fn holds(self: &mut File, want: []u8) Result<bool, IoError> {
        let m = self.metadata()?;
        if m.kind != FileKind::File || m.size != want.len() as u64 {
            return Result::<bool, IoError>::Ok(false);
        }
        let mut buf: [u8; 16384] = [0; 16384];
        let mut off: usize = 0;
        // Every pass but the last reads at least one byte and stays within `want`.
        loop {
            let n = self.read(buf)?;
            if n == 0 {
                return Result::<bool, IoError>::Ok(off == want.len());
            }
            if n > want.len() - off || unsafe cstring::memcmp(&buf[0], unsafe (want.ptr + off), n) != 0 {
                return Result::<bool, IoError>::Ok(false);
            }
            off += n;
        }
    }

    /// Move the position: the new position from the start of the file.
    @platform(!windows)
    pub fn seek(self: &mut File, to: SeekFrom) Result<u64, IoError> {
        let (off, whence) = switch to {
            Start(n) => (n as i64, stdio::SEEK_SET),
            Current(n) => (n, SEEK_CUR),
            End(n) => (n, SEEK_END),
        };
        let r = unsafe lseek(self.raw, off, whence);
        if r < 0 {
            return fail::<u64>(IoOp::Seek);
        }
        return Result::<u64, IoError>::Ok(r as u64);
    }
    /// Move the position: the new position from the start of the file.
    @platform(windows)
    pub fn seek(self: &mut File, to: SeekFrom) Result<u64, IoError> {
        let (off, method) = switch to {
            Start(n) => (n as i64, FILE_BEGIN),
            Current(n) => (n, FILE_CURRENT),
            End(n) => (n, FILE_END),
        };
        let mut pos = LARGE_INTEGER { quad: 0 };
        if unsafe SetFilePointerEx(self.raw, LARGE_INTEGER { quad: off }, &mut pos, method) == 0 {
            return fail::<u64>(IoOp::Seek);
        }
        return Result::<u64, IoError>::Ok(pos.quad as u64);
    }

    /// Write the file's data and metadata through to the device, and wait for it.
    @platform(!windows)
    pub fn sync(self: &mut File) Result<Unit, IoError> {
        if unsafe unistd::fsync(self.raw) != 0 {
            return fail::<Unit>(IoOp::Sync);
        }
        return done();
    }
    /// Write the file's data and metadata through to the device, and wait for it.
    @platform(windows)
    pub fn sync(self: &mut File) Result<Unit, IoError> {
        if unsafe FlushFileBuffers(self.raw) == 0 {
            return fail::<Unit>(IoOp::Sync);
        }
        return done();
    }

    /// The metadata of the open file.
    @platform(!windows)
    pub fn metadata(self: &File) Result<Metadata, IoError> {
        let mut st = unsafe zeroed::<stat>();
        if unsafe fstat(self.raw, &mut st) != 0 {
            return fail::<Metadata>(IoOp::Stat);
        }
        return Result::<Metadata, IoError>::Ok(metadata_of(&st));
    }
    /// The metadata of the open file.
    @platform(windows)
    pub fn metadata(self: &File) Result<Metadata, IoError> {
        let mut fi = unsafe zeroed::<BY_HANDLE_FILE_INFORMATION>();
        if unsafe GetFileInformationByHandle(self.raw, &mut fi) == 0 {
            return fail::<Metadata>(IoOp::Stat);
        }
        let mut tag: u32 = 0;
        if (fi.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
            let mut ti = FILE_ATTRIBUTE_TAG_INFO { FileAttributes: 0, ReparseTag: 0 };
            let size = sizeof(FILE_ATTRIBUTE_TAG_INFO) as u32;
            if unsafe GetFileInformationByHandleEx(self.raw, FILE_ATTRIBUTE_TAG_INFO_CLASS, &mut ti, size) == 0 {
                return fail::<Metadata>(IoOp::Stat);
            }
            tag = ti.ReparseTag;
        }
        let perms: u32 = if (fi.dwFileAttributes & FILE_ATTRIBUTE_READONLY) != 0 {
            0o444;
        } else {
            0o666;
        };
        return Result::<Metadata, IoError>::Ok(
            Metadata {
                kind: kind_of_attributes(fi.dwFileAttributes, tag),
                size: fi.nFileSizeHigh as u64 << 32 | fi.nFileSizeLow as u64,
                permissions: perms,
                modified_ns: ft_ns(fi.ftLastWriteTime),
                accessed_ns: ft_ns(fi.ftLastAccessTime),
                created_ns: Option::<i64>::Some(ft_ns(fi.ftCreationTime)),
                dev: fi.dwVolumeSerialNumber,
                ino: fi.nFileIndexHigh as u64 << 32 | fi.nFileIndexLow as u64,
                links: fi.nNumberOfLinks,
            },
        );
    }

    /// Take the exclusive lock of the file (other processes only: a POSIX record lock on the whole file,
    /// a lock of its first byte on Windows), trying again every 100 ms for up to `timeout_ns`; 0 tries
    /// once. TimedOut while another process still holds it. Closing the file releases the lock; on POSIX
    /// so does closing any other descriptor of the same file in this process. Unsupported on WASI.
    pub fn lock_exclusive(self: &mut File, timeout_ns: u64) Result<Unit, IoError> {
        let until = clock::monotonic_ns().saturating_add(timeout_ns);
        // Bounded by `timeout_ns`: each failed try sleeps 100 ms.
        loop {
            if self.try_lock()? {
                return done();
            }
            if clock::monotonic_ns() >= until {
                return Result::<Unit, IoError>::Err(IoError::new(IoErrorKind::TimedOut, IoOp::Lock));
            }
            clock::sleep_ns(100000000);
        }
    }

    // One attempt at the exclusive lock: false when another process holds it.
    @platform(macos | ios | linux | android)
    fn try_lock(self: &mut File) Result<bool, IoError> {
        let mut fl = unsafe zeroed::<flock>();
        fl.l_type = F_WRLCK as i16;
        fl.l_whence = stdio::SEEK_SET as i16;
        // Bounded by the signals that interrupt the call.
        loop {
            if unsafe fcntl::fcntl(self.raw, F_SETLK, &mut fl) == 0 {
                return Result::<bool, IoError>::Ok(true);
            }
            if !error::interrupted() {
                break;
            }
        }
        let e = error::last_error(IoOp::Lock);
        if e.kind == IoErrorKind::WouldBlock || e.kind == IoErrorKind::PermissionDenied {
            return Result::<bool, IoError>::Ok(false); // EAGAIN or EACCES: another process holds it
        }
        return Result::<bool, IoError>::Err(e);
    }
    @platform(windows)
    fn try_lock(self: &mut File) Result<bool, IoError> {
        let mut ov = unsafe zeroed::<OVERLAPPED>();
        if unsafe LockFileEx(self.raw, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &mut ov) != 0 {
            return Result::<bool, IoError>::Ok(true);
        }
        if unsafe GetLastError() == ERROR_LOCK_VIOLATION {
            return Result::<bool, IoError>::Ok(false);
        }
        return fail::<bool>(IoOp::Lock);
    }
    @platform(wasm)
    fn try_lock(self: &mut File) Result<bool, IoError> {
        return Result::<bool, IoError>::Err(error::unsupported(IoOp::Lock));
    }

    /// Release the lock `lock_exclusive` took. Unsupported on WASI.
    @platform(macos | ios | linux | android)
    pub fn unlock(self: &mut File) Result<Unit, IoError> {
        let mut fl = unsafe zeroed::<flock>();
        fl.l_type = F_UNLCK as i16;
        fl.l_whence = stdio::SEEK_SET as i16;
        if unsafe fcntl::fcntl(self.raw, F_SETLK, &mut fl) != 0 {
            return fail::<Unit>(IoOp::Unlock);
        }
        return done();
    }
    /// Release the lock `lock_exclusive` took. Unsupported on WASI.
    @platform(windows)
    pub fn unlock(self: &mut File) Result<Unit, IoError> {
        let mut ov = unsafe zeroed::<OVERLAPPED>();
        if unsafe UnlockFileEx(self.raw, 0, 1, 0, &mut ov) == 0 {
            return fail::<Unit>(IoOp::Unlock);
        }
        return done();
    }
    /// Release the lock `lock_exclusive` took. Unsupported on WASI.
    @platform(wasm)
    pub fn unlock(self: &mut File) Result<Unit, IoError> {
        return Result::<Unit, IoError>::Err(error::unsupported(IoOp::Unlock));
    }

    /// Whether a read returns at once: bytes are waiting, or the stream ended or failed.
    @platform(!windows)
    pub fn pending(self: &File) Result<bool, IoError> {
        let r = unsafe sc_io::sc_io_wait_fd(self.raw, 0, 0);
        if r < 0 {
            return fail::<bool>(IoOp::Poll);
        }
        return Result::<bool, IoError>::Ok(r > 0);
    }
    /// Whether a read returns at once: bytes are waiting, or the stream ended or failed.
    @platform(windows)
    pub fn pending(self: &File) Result<bool, IoError> {
        if unsafe GetFileType(self.raw) == FILE_TYPE_PIPE {
            let mut avail: u32 = 0;
            if unsafe PeekNamedPipe(self.raw, null, 0, null, &mut avail, null) == 0 {
                return Result::<bool, IoError>::Ok(true); // a broken pipe: the read reports it
            }
            return Result::<bool, IoError>::Ok(avail > 0);
        }
        return Result::<bool, IoError>::Ok(unsafe WaitForSingleObject(self.raw, 0) == WAIT_OBJECT_0);
    }
}

extend File as Reader {
    /// One read of at most `buf.len()` bytes (at most 1 GiB): the count, 0 at the end of the stream. A
    /// pipe whose writers all closed reads as its end.
    @platform(!windows)
    pub fn read(self: &mut File, buf: []mut u8) Result<usize, IoError> {
        // Bounded by the signals that interrupt the read.
        loop {
            let n = unsafe unistd::read(self.raw, buf.as_mut_ptr(), buf.len().min(1 << 30));
            if n >= 0 {
                return Result::<usize, IoError>::Ok(n as usize);
            }
            if !error::interrupted() {
                return fail::<usize>(IoOp::Read);
            }
        }
    }
    /// One read of at most `buf.len()` bytes (at most 1 GiB): the count, 0 at the end of the stream. A
    /// pipe whose writers all closed reads as its end.
    @platform(windows)
    pub fn read(self: &mut File, buf: []mut u8) Result<usize, IoError> {
        let mut got: u32 = 0;
        let n = buf.len().min(1 << 30) as u32;
        if unsafe ReadFile(self.raw, buf.as_mut_ptr(), n, &mut got, null) == 0 {
            let e = unsafe GetLastError();
            if e == ERROR_BROKEN_PIPE || e == ERROR_HANDLE_EOF {
                return Result::<usize, IoError>::Ok(0);
            }
            return Result::<usize, IoError>::Err(error::code_error(e as i32, IoOp::Read));
        }
        return Result::<usize, IoError>::Ok(got as usize);
    }
}

extend File as Writer {
    /// One write of at most `bytes.len()` bytes (at most 1 GiB): the count accepted, which may be fewer.
    /// A failure after a partial write shows on the next call.
    @platform(!windows)
    pub fn write(self: &mut File, bytes: []u8) Result<usize, IoError> {
        // Bounded by the signals that interrupt the write.
        loop {
            let n = unsafe unistd::write(self.raw, bytes.ptr, bytes.len().min(1 << 30));
            if n >= 0 {
                return Result::<usize, IoError>::Ok(n as usize);
            }
            if !error::interrupted() {
                return fail::<usize>(IoOp::Write);
            }
        }
    }
    /// One write of at most `bytes.len()` bytes (at most 1 GiB): the count accepted, which may be fewer.
    /// A failure after a partial write shows on the next call.
    @platform(windows)
    pub fn write(self: &mut File, bytes: []u8) Result<usize, IoError> {
        let mut put: u32 = 0;
        let n = bytes.len().min(1 << 30) as u32;
        if unsafe WriteFile(self.raw, bytes.ptr, n, &mut put, null) == 0 {
            return fail::<usize>(IoOp::Write);
        }
        return Result::<usize, IoError>::Ok(put as usize);
    }
}

extend File as Free {
    @platform(!windows)
    pub fn free(self: &mut File) {
        let _ = unsafe unistd::close(self.raw);
    }
    @platform(windows)
    pub fn free(self: &mut File) {
        let _ = unsafe CloseHandle(self.raw);
    }
}

// ---- ReadDir ----------------------------------------------------------------------------------------

extend ReadDir {
    fn adopt(state: DirState) ReadDir {
        return ReadDir { state: state };
    }

    /// The next entry, or None after the last. An entry another process adds or removes during the
    /// listing may or may not appear.
    @platform(!windows)
    pub fn next(self: &mut ReadDir) Option<Result<DirEntry, IoError>> {
        // Bounded by the entries of the directory: `.` and `..` are skipped.
        loop {
            errno::set_errno(0);
            let e = unsafe readdir(self.state.dir);
            if e == null {
                if errno::errno() != 0 {
                    return Option::<Result<DirEntry, IoError>>::Some(fail::<DirEntry>(IoOp::ReadDir));
                }
                return Option::<Result<DirEntry, IoError>>::None;
            }
            let p = ((unsafe &(*e).d_name) as *const [char; D_NAME_LEN]) as *const u8;
            let name = unsafe str::from_raw(p, cstring::strlen(p as *const char));
            if name == "." || name == ".." {
                continue;
            }
            let t = unsafe (*e).d_type;
            let kind = if t == DT_UNKNOWN {
                Option::<FileKind>::None;
            } else if t == DT_DIR {
                Option::<FileKind>::Some(FileKind::Dir);
            } else if t == DT_REG {
                Option::<FileKind>::Some(FileKind::File);
            } else if t == DT_LNK {
                Option::<FileKind>::Some(FileKind::Symlink);
            } else {
                Option::<FileKind>::Some(FileKind::Other);
            };
            return Option::<Result<DirEntry, IoError>>::Some(
                Result::<DirEntry, IoError>::Ok(DirEntry { name: name, kind: kind }),
            );
        }
    }
    /// The next entry, or None after the last. An entry another process adds or removes during the
    /// listing may or may not appear.
    @platform(windows)
    pub fn next(self: &mut ReadDir) Option<Result<DirEntry, IoError>> {
        // Bounded by the entries of the directory: `.` and `..` are skipped.
        loop {
            if !self.state.pending {
                if self.state.find == INVALID_HANDLE_VALUE {
                    return Option::<Result<DirEntry, IoError>>::None;
                }
                if unsafe FindNextFileW(self.state.find, &mut self.state.data) == 0 {
                    if unsafe GetLastError() == ERROR_NO_MORE_FILES {
                        return Option::<Result<DirEntry, IoError>>::None;
                    }
                    return Option::<Result<DirEntry, IoError>>::Some(fail::<DirEntry>(IoOp::ReadDir));
                }
            }
            self.state.pending = false;
            let units = unsafe path::wide_view(&self.state.data.cFileName[0]);
            let dots = units.len() == 1 && units[0] == 0x2E || units.len() == 2 && units[0] == 0x2E && units[1] == 0x2E;
            if dots {
                continue;
            }
            self.state.name.clear();
            if let Err(e) = path::push_wide(&mut self.state.name, units, false, IoOp::ReadDir) {
                return Option::<Result<DirEntry, IoError>>::Some(Result::<DirEntry, IoError>::Err(e));
            }
            // A reparse point's tag is in dwReserved0.
            let kind = kind_of_attributes(self.state.data.dwFileAttributes, self.state.data.dwReserved0);
            let entry = DirEntry { name: self.state.name.as_str(), kind: Option::<FileKind>::Some(kind) };
            return Option::<Result<DirEntry, IoError>>::Some(Result::<DirEntry, IoError>::Ok(entry));
        }
    }
}

extend ReadDir as Free {
    @platform(!windows)
    pub fn free(self: &mut ReadDir) {
        let _ = unsafe closedir(self.state.dir);
    }
    @platform(windows)
    pub fn free(self: &mut ReadDir) {
        if self.state.find != INVALID_HANDLE_VALUE {
            let _ = unsafe FindClose(self.state.find);
        }
        self.state.name.free();
    }
}

extend Metadata {
    /// Whether both describe one file: equal device and file number.
    pub const fn same_file(self: &Metadata, other: &Metadata) bool {
        return self.dev == other.dev && self.ino == other.ino;
    }
}
