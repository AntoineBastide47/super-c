// wasm's C library (`loader::Package::rt_libc`): wasm has no system C library, so a wasm build links this
// module and `std::rt::libm` in its place, with no C library of the toolchain (`-nostdlib`). It implements
// every C function and object that the runtime, std, the ffi bindings and the compiler bind for wasm (a test
// checks it: `tests/codegen/wasm_libc_test.spc`), over WASI preview 1, which it imports directly: the entry point,
// the arguments and the environment (`environ`), the allocator with `sbrk`, the string, character and
// conversion functions, buffered stdio with the printf and scanf families, the file system through the
// preopened directories, the clocks and the broken-down time functions, locales, signals as wasi-libc
// emulates them, the single-thread `pthread_self`, and `errno` with its messages. The behavior is
// wasi-libc's (musl and cloudlibc) with its signal emulation, including the exact float formatting and
// parsing; the code is a port, see LICENSE in this directory.
//
// What wasi-libc provides and this module does not: long double conversions (`%Lf` fails in printf and
// scanf: Super-C has no type of its size), and the functions WASI has no call for (`fork`, `execvp`, `pipe`,
// `dup`, `pthread_create`). A program that calls one of those fails to link.
//
// Every definition has the C type its wasi-libc header declares: the emitted C includes those headers. The
// standard streams are objects the headers declare `const`, which a Super-C definition cannot be: the
// runtime header (`src/emit/rt_h.spc`) turns the names `stdin`, `stdout` and `stderr` into calls of
// `sc_stdio_stream`, and `CLOCK_REALTIME` and `CLOCK_MONOTONIC` into tags `clock_gettime` reads. The C units of this module and of
// `std::rt::libm` compile with `-fno-builtin` (`loader::libc_unit`): the C compiler must not turn a copy
// loop in `memcpy` into a call of `memcpy`. The module imports no module, for the same reason as the
// runtime's.

// ---- WASI ------------------------------------------------------------------------------------------------

// The WASI preview 1 calls, imported from module `wasi_snapshot_preview1` under their WASI names. A C
// declaration cannot name an import module, a module-level assembly directive can; the C symbols carry the
// `sc_wasi_` prefix so no C library name is taken. The types are the wasm types of each import.
asm(M"(
.functype sc_wasi_args_get (i32, i32) -> (i32)
.import_module sc_wasi_args_get, wasi_snapshot_preview1
.import_name sc_wasi_args_get, args_get
.functype sc_wasi_args_sizes_get (i32, i32) -> (i32)
.import_module sc_wasi_args_sizes_get, wasi_snapshot_preview1
.import_name sc_wasi_args_sizes_get, args_sizes_get
.functype sc_wasi_environ_get (i32, i32) -> (i32)
.import_module sc_wasi_environ_get, wasi_snapshot_preview1
.import_name sc_wasi_environ_get, environ_get
.functype sc_wasi_environ_sizes_get (i32, i32) -> (i32)
.import_module sc_wasi_environ_sizes_get, wasi_snapshot_preview1
.import_name sc_wasi_environ_sizes_get, environ_sizes_get
.functype sc_wasi_clock_time_get (i32, i64, i32) -> (i32)
.import_module sc_wasi_clock_time_get, wasi_snapshot_preview1
.import_name sc_wasi_clock_time_get, clock_time_get
.functype sc_wasi_fd_close (i32) -> (i32)
.import_module sc_wasi_fd_close, wasi_snapshot_preview1
.import_name sc_wasi_fd_close, fd_close
.functype sc_wasi_fd_fdstat_get (i32, i32) -> (i32)
.import_module sc_wasi_fd_fdstat_get, wasi_snapshot_preview1
.import_name sc_wasi_fd_fdstat_get, fd_fdstat_get
.functype sc_wasi_fd_fdstat_set_flags (i32, i32) -> (i32)
.import_module sc_wasi_fd_fdstat_set_flags, wasi_snapshot_preview1
.import_name sc_wasi_fd_fdstat_set_flags, fd_fdstat_set_flags
.functype sc_wasi_fd_filestat_get (i32, i32) -> (i32)
.import_module sc_wasi_fd_filestat_get, wasi_snapshot_preview1
.import_name sc_wasi_fd_filestat_get, fd_filestat_get
.functype sc_wasi_fd_prestat_get (i32, i32) -> (i32)
.import_module sc_wasi_fd_prestat_get, wasi_snapshot_preview1
.import_name sc_wasi_fd_prestat_get, fd_prestat_get
.functype sc_wasi_fd_prestat_dir_name (i32, i32, i32) -> (i32)
.import_module sc_wasi_fd_prestat_dir_name, wasi_snapshot_preview1
.import_name sc_wasi_fd_prestat_dir_name, fd_prestat_dir_name
.functype sc_wasi_fd_read (i32, i32, i32, i32) -> (i32)
.import_module sc_wasi_fd_read, wasi_snapshot_preview1
.import_name sc_wasi_fd_read, fd_read
.functype sc_wasi_fd_renumber (i32, i32) -> (i32)
.import_module sc_wasi_fd_renumber, wasi_snapshot_preview1
.import_name sc_wasi_fd_renumber, fd_renumber
.functype sc_wasi_fd_readdir (i32, i32, i32, i64, i32) -> (i32)
.import_module sc_wasi_fd_readdir, wasi_snapshot_preview1
.import_name sc_wasi_fd_readdir, fd_readdir
.functype sc_wasi_fd_seek (i32, i64, i32, i32) -> (i32)
.import_module sc_wasi_fd_seek, wasi_snapshot_preview1
.import_name sc_wasi_fd_seek, fd_seek
.functype sc_wasi_fd_sync (i32) -> (i32)
.import_module sc_wasi_fd_sync, wasi_snapshot_preview1
.import_name sc_wasi_fd_sync, fd_sync
.functype sc_wasi_fd_write (i32, i32, i32, i32) -> (i32)
.import_module sc_wasi_fd_write, wasi_snapshot_preview1
.import_name sc_wasi_fd_write, fd_write
.functype sc_wasi_path_create_directory (i32, i32, i32) -> (i32)
.import_module sc_wasi_path_create_directory, wasi_snapshot_preview1
.import_name sc_wasi_path_create_directory, path_create_directory
.functype sc_wasi_path_filestat_get (i32, i32, i32, i32, i32) -> (i32)
.import_module sc_wasi_path_filestat_get, wasi_snapshot_preview1
.import_name sc_wasi_path_filestat_get, path_filestat_get
.functype sc_wasi_path_filestat_set_times (i32, i32, i32, i32, i64, i64, i32) -> (i32)
.import_module sc_wasi_path_filestat_set_times, wasi_snapshot_preview1
.import_name sc_wasi_path_filestat_set_times, path_filestat_set_times
.functype sc_wasi_path_link (i32, i32, i32, i32, i32, i32, i32) -> (i32)
.import_module sc_wasi_path_link, wasi_snapshot_preview1
.import_name sc_wasi_path_link, path_link
.functype sc_wasi_path_symlink (i32, i32, i32, i32, i32) -> (i32)
.import_module sc_wasi_path_symlink, wasi_snapshot_preview1
.import_name sc_wasi_path_symlink, path_symlink
.functype sc_wasi_path_open (i32, i32, i32, i32, i32, i64, i64, i32, i32) -> (i32)
.import_module sc_wasi_path_open, wasi_snapshot_preview1
.import_name sc_wasi_path_open, path_open
.functype sc_wasi_path_readlink (i32, i32, i32, i32, i32, i32) -> (i32)
.import_module sc_wasi_path_readlink, wasi_snapshot_preview1
.import_name sc_wasi_path_readlink, path_readlink
.functype sc_wasi_path_remove_directory (i32, i32, i32) -> (i32)
.import_module sc_wasi_path_remove_directory, wasi_snapshot_preview1
.import_name sc_wasi_path_remove_directory, path_remove_directory
.functype sc_wasi_path_rename (i32, i32, i32, i32, i32, i32) -> (i32)
.import_module sc_wasi_path_rename, wasi_snapshot_preview1
.import_name sc_wasi_path_rename, path_rename
.functype sc_wasi_path_unlink_file (i32, i32, i32) -> (i32)
.import_module sc_wasi_path_unlink_file, wasi_snapshot_preview1
.import_name sc_wasi_path_unlink_file, path_unlink_file
.functype sc_wasi_poll_oneoff (i32, i32, i32, i32) -> (i32)
.import_module sc_wasi_poll_oneoff, wasi_snapshot_preview1
.import_name sc_wasi_poll_oneoff, poll_oneoff
.functype sc_wasi_proc_exit (i32) -> ()
.import_module sc_wasi_proc_exit, wasi_snapshot_preview1
.import_name sc_wasi_proc_exit, proc_exit
.functype sc_wasi_random_get (i32, i32) -> (i32)
.import_module sc_wasi_random_get, wasi_snapshot_preview1
.import_name sc_wasi_random_get, random_get
.functype sc_wasi_sched_yield () -> (i32)
.import_module sc_wasi_sched_yield, wasi_snapshot_preview1
.import_name sc_wasi_sched_yield, sched_yield
.globl sc_wasm_memory_grow
.type sc_wasm_memory_grow,@function
sc_wasm_memory_grow:
.functype sc_wasm_memory_grow (i32) -> (i32)
local.get 0
memory.grow 0
end_function
.globl sc_wasm_memory_size
.type sc_wasm_memory_size,@function
sc_wasm_memory_size:
.functype sc_wasm_memory_size () -> (i32)
memory.size 0
end_function
.globl sc_wasm_trap
.type sc_wasm_trap,@function
sc_wasm_trap:
.functype sc_wasm_trap () -> ()
unreachable
end_function
)");

// The imports and the instructions above, as C sees them; a WASI call returns its errno.
extern "C" {
    fn sc_wasi_args_get(argv: *mut *mut char, buf: *mut char) u16;
    fn sc_wasi_args_sizes_get(argc: *mut usize, size: *mut usize) u16;
    fn sc_wasi_environ_get(env: *mut *mut char, buf: *mut char) u16;
    fn sc_wasi_environ_sizes_get(count: *mut usize, size: *mut usize) u16;
    fn sc_wasi_clock_time_get(id: u32, precision: u64, out: *mut u64) u16;
    fn sc_wasi_fd_close(fd: i32) u16;
    fn sc_wasi_fd_fdstat_get(fd: i32, out: *mut FdStat) u16;
    fn sc_wasi_fd_fdstat_set_flags(fd: i32, flags: u16) u16;
    fn sc_wasi_fd_filestat_get(fd: i32, out: *mut FileStat) u16;
    fn sc_wasi_fd_prestat_get(fd: i32, out: *mut PreStat) u16;
    fn sc_wasi_fd_prestat_dir_name(fd: i32, path: *mut u8, len: usize) u16;
    fn sc_wasi_fd_read(fd: i32, iovs: *const IoVec, n: usize, out: *mut usize) u16;
    fn sc_wasi_fd_renumber(fd: i32, to: i32) u16;
    fn sc_wasi_fd_readdir(fd: i32, buf: *mut u8, len: usize, cookie: u64, out: *mut usize) u16;
    fn sc_wasi_fd_seek(fd: i32, offset: i64, whence: u8, out: *mut u64) u16;
    fn sc_wasi_fd_sync(fd: i32) u16;
    fn sc_wasi_fd_write(fd: i32, iovs: *const IoVec, n: usize, out: *mut usize) u16;
    fn sc_wasi_path_create_directory(fd: i32, path: *const char, len: usize) u16;
    fn sc_wasi_path_filestat_get(fd: i32, flags: u32, path: *const char, len: usize, out: *mut FileStat) u16;
    fn sc_wasi_path_filestat_set_times(
        fd: i32,
        flags: u32,
        path: *const char,
        len: usize,
        atim: u64,
        mtim: u64,
        fst: u16,
    ) u16;
    fn sc_wasi_path_link(fd: i32, flags: u32, path: *const char, len: usize, fd2: i32, path2: *const char, len2: usize) u16;
    fn sc_wasi_path_open(
        fd: i32,
        dirflags: u32,
        path: *const char,
        len: usize,
        oflags: u16,
        base: u64,
        inheriting: u64,
        fdflags: u16,
        out: *mut i32,
    ) u16;
    fn sc_wasi_path_readlink(fd: i32, path: *const char, len: usize, buf: *mut u8, cap: usize, out: *mut usize) u16;
    fn sc_wasi_path_remove_directory(fd: i32, path: *const char, len: usize) u16;
    fn sc_wasi_path_symlink(path: *const char, len: usize, fd: i32, path2: *const char, len2: usize) u16;
    fn sc_wasi_path_rename(fd: i32, path: *const char, len: usize, fd2: i32, path2: *const char, len2: usize) u16;
    fn sc_wasi_path_unlink_file(fd: i32, path: *const char, len: usize) u16;
    fn sc_wasi_poll_oneoff(subs: *const Subscription, events: *mut Event, n: usize, out: *mut usize) u16;
    @noreturn
    fn sc_wasi_proc_exit(code: i32);
    fn sc_wasi_random_get(buf: *mut u8, len: usize) u16;
    fn sc_wasi_sched_yield() u16;
    fn sc_wasm_memory_grow(pages: usize) isize;
    fn sc_wasm_memory_size() usize;
    @noreturn
    fn sc_wasm_trap();
    // The linker's: the first byte past the static data and the stack, and the constructors of the program.
    static mut __heap_base: u8;
    fn __wasm_call_ctors();
    // The program's C `main` (`emit`'s, or the test runner's `__test_main.c`), which the C compiler names
    // so on wasm.
    @import("__main_argc_argv")
    fn c_main(argc: i32, argv: *mut *mut char) i32;
}

// The WASI records the calls above read and write, laid out as `wasi/api.h` lays them out.
struct IoVec {
    pub buf: *const u8,
    pub len: usize,
}

struct FdStat {
    pub filetype: u8,
    pub flags: u16,
    pub rights_base: u64,
    pub rights_inheriting: u64,
}

struct FileStat {
    pub dev: u64,
    pub ino: u64,
    pub filetype: u8,
    pub nlink: u64,
    pub size: u64,
    pub atim: u64,
    pub mtim: u64,
    pub ctim: u64,
}

struct PreStat {
    pub tag: u8,
    pub name_len: u32,
}

// A clock subscription (`__wasi_subscription_t` with `u.tag` CLOCK), or a descriptor one, whose descriptor
// sits where the clock id does.
struct Subscription {
    pub userdata: u64,
    pub tag: u8,
    pub pad: [u8; 7],
    pub id: u32,
    pub timeout: u64,
    pub precision: u64,
    pub flags: u16,
}

struct Event {
    pub userdata: u64,
    pub error: u16,
    pub kind: u8,
    pub nbytes: u64,
    pub rwflags: u16,
}

// WASI errno values (C's errno values on WASI).
const E2BIG: i32 = 1;
const EACCES: i32 = 2;
const EAGAIN: i32 = 6;
const EBADF: i32 = 8;
const EDOM: i32 = 18;
const EEXIST: i32 = 20;
const EINVAL: i32 = 28;
const EIO: i32 = 29;
const EISDIR: i32 = 31;
const ELOOP: i32 = 32;
const EMFILE: i32 = 33;
const ENAMETOOLONG: i32 = 37;
const ENOENT: i32 = 44;
const ENOMEM: i32 = 48;
const ENOSYS: i32 = 52;
const ENOTDIR: i32 = 54;
const ENOTSUP: i32 = 58;
const ENOTTY: i32 = 59;
const EOVERFLOW: i32 = 61;
const EPIPE: i32 = 64;
const ERANGE: i32 = 68;
const ESPIPE: i32 = 70;
const ENOTCAPABLE: i32 = 76;

const FILETYPE_CHARACTER_DEVICE: u8 = 2;
const FILETYPE_DIRECTORY: u8 = 3;
const RIGHTS_FD_DATASYNC: u64 = 1;
const RIGHTS_FD_READ: u64 = 2;
const RIGHTS_FD_SEEK: u64 = 4;
const RIGHTS_FD_TELL: u64 = 32;
const RIGHTS_FD_WRITE: u64 = 64;
const RIGHTS_FD_ALLOCATE: u64 = 256;
const RIGHTS_FD_READDIR: u64 = 16384;
const RIGHTS_FD_FILESTAT_SET_SIZE: u64 = 4194304;
const LOOKUP_SYMLINK_FOLLOW: u32 = 1;
const CLOCK_REALTIME: u32 = 0;
const CLOCK_MONOTONIC: u32 = 1;
const EVENTTYPE_CLOCK: u8 = 0;
const EVENTTYPE_FD_READ: u8 = 1;
const EVENTTYPE_FD_WRITE: u8 = 2;
const EVENT_HANGUP: u16 = 1;

// ---- errno ---------------------------------------------------------------------------------------------

/// The calling thread's last error code (`<errno.h>` declares it a thread-local `int`).
@export("errno")
@thread_local
pub static mut ERRNO: i32 = 0;

fn set_errno(code: i32) {
    unsafe ERRNO = code;
}

// -1 with errno set to WASI error `e` (nonzero).
fn fail(e: u16) i32 {
    set_errno(e);
    return -1;
}

// ---- start -----------------------------------------------------------------------------------------------

// The arguments, kept for `main`, and the environment, an array of `NAME=value` pointers ending in null that
// `setenv` grows (`ENV_CAP` slots): the strings WASI wrote stay where they are, the ones `setenv` makes are
// allocated and owned (`ENV_OWN` marks them).
/// The environment, also as POSIX's `environ`.
@export("environ")
pub static mut ENV: *mut *mut char = null;
static mut ENV_OWN: *mut bool = null;
static mut ENV_LEN: usize = 0;
static mut ENV_CAP: usize = 0;

/// The entry point of the module, which wasm-ld exports: the constructors, the arguments and the
/// environment, `main`, then `exit` with its result.
@export("_start")
pub fn start() {
    // The stack canaries' value, before any function that keeps one returns (this one does not).
    let _ = unsafe sc_wasi_random_get(((&mut STACK_CHK_GUARD) as *mut usize) as *mut u8, sizeof(usize));
    unsafe STACK_CHK_GUARD &= ~0xFFusize;
    unsafe __wasm_call_ctors();
    let mut argc: usize = 0;
    let mut asize: usize = 0;
    if unsafe sc_wasi_args_sizes_get(&mut argc, &mut asize) != 0 {
        unsafe sc_wasi_proc_exit(71);
    }
    let argv = heap_alloc((argc + 1) * sizeof(*mut char)) as *mut *mut char;
    let abuf = heap_alloc(asize + 1) as *mut char;
    if argv == null || abuf == null || unsafe sc_wasi_args_get(argv, abuf) != 0 {
        unsafe sc_wasi_proc_exit(71);
    }
    unsafe argv[argc] = null;
    env_init();
    exit(unsafe c_main(argc as i32, argv));
}

// Read the environment WASI passes into `ENV`.
fn env_init() {
    let mut count: usize = 0;
    let mut size: usize = 0;
    if unsafe sc_wasi_environ_sizes_get(&mut count, &mut size) != 0 {
        unsafe sc_wasi_proc_exit(71);
    }
    let cap = count + 8;
    let env = heap_alloc(cap * sizeof(*mut char)) as *mut *mut char;
    let own = heap_alloc(cap) as *mut bool;
    let buf = heap_alloc(size + 1) as *mut char;
    if env == null || own == null || buf == null || unsafe sc_wasi_environ_get(env, buf) != 0 {
        unsafe sc_wasi_proc_exit(71);
    }
    for i in 0..cap {
        unsafe own[i] = false;
    }
    unsafe env[count] = null;
    unsafe ENV = env;
    unsafe ENV_OWN = own;
    unsafe ENV_LEN = count;
    unsafe ENV_CAP = cap;
}

// ---- exit ------------------------------------------------------------------------------------------------

// The `atexit` handlers, run last registered first: 32 fixed slots (C's minimum), then a heap array that
// grows geometrically.
static mut AT_FIXED: [fn(); 32] = [noop_handler; 32];
static mut AT_HEAP: *mut fn() = null;
static mut AT_LEN: usize = 0;
static mut AT_CAP: usize = 32;

const fn noop_handler() {}

/// Register `f` to run at `exit`; 0, or -1 when no memory is left.
@export("atexit")
pub fn c_atexit(f: fn()) i32 {
    if unsafe AT_LEN == unsafe AT_CAP {
        let cap = unsafe AT_CAP * 2;
        let p = heap_alloc(cap * sizeof(fn())) as *mut fn();
        if p == null {
            return -1;
        }
        for i in 0..unsafe AT_LEN {
            unsafe p[i] = at_slot(i);
        }
        heap_free(unsafe AT_HEAP);
        unsafe AT_HEAP = p;
        unsafe AT_CAP = cap;
    }
    let i = unsafe AT_LEN;
    if unsafe AT_HEAP != null {
        unsafe AT_HEAP[i] = f;
    } else {
        unsafe AT_FIXED[i] = f;
    }
    unsafe AT_LEN = i + 1;
    return 0;
}

fn at_slot(i: usize) fn() {
    if unsafe AT_HEAP != null {
        return unsafe AT_HEAP[i];
    }
    return unsafe AT_FIXED[i];
}

/// Run the `atexit` handlers, flush every stream and end the process with `code`.
@export("exit")
@noreturn
pub fn exit(code: i32) {
    // A handler may register another: each runs once, last first.
    while unsafe AT_LEN > 0 {
        unsafe AT_LEN -= 1;
        let f = at_slot(unsafe AT_LEN);
        f();
    }
    let _ = flush_all();
    unsafe sc_wasi_proc_exit(code);
}

/// End the process with `code` at once: no handlers, no flush.
@export("_Exit")
@noreturn
pub fn exit_now(code: i32) {
    unsafe sc_wasi_proc_exit(code);
}

/// End the process abnormally: a trap, as WASI has no signals.
@export("abort")
@noreturn
pub fn abort() {
    unsafe sc_wasm_trap();
}

/// The value of the stack canaries (`-fstack-protector`): random from the start on, its low byte 0 so a
/// string copy cannot write it, as musl's `__init_ssp` sets it.
@export("__stack_chk_guard")
pub static mut STACK_CHK_GUARD: usize = 0;

/// A function's canary changed before it returned: its stack memory overflowed.
@export("__stack_chk_fail")
@noreturn
pub fn stack_chk_fail() {
    abort();
}

/// The process id: WASI has none, so every process is 42, as wasi-libc's emulation answers.
@export("getpid")
pub const fn getpid() i32 {
    return 42;
}

/// A shell command: WASI has no processes. -1 with ENOSYS, or 0 for a null command (no shell exists).
@export("system")
pub fn system(cmd: *const char) i32 {
    if cmd == null {
        return 0;
    }
    set_errno(ENOSYS);
    return -1;
}

/// Let another thread run: WASI's `sched_yield`.
@export("sched_yield")
pub fn sched_yield() i32 {
    let e = unsafe sc_wasi_sched_yield();
    if e != 0 {
        return fail(e);
    }
    return 0;
}

/// WASI `random_get`, under wasi-libc's name for it (`wasi/api.h`): the WASI error code.
@export("__wasi_random_get")
pub fn wasi_random_get(buf: *mut u8, len: usize) u16 {
    return unsafe sc_wasi_random_get(buf, len);
}

/// WASI `clock_time_get`, under wasi-libc's name for it (`wasi/api.h`): the WASI error code.
@export("__wasi_clock_time_get")
pub fn wasi_clock_time_get(id: u32, precision: u64, out: *mut u64) u16 {
    return unsafe sc_wasi_clock_time_get(id, precision, out);
}

/// Fill `buf` with `len` (at most 256) random bytes; 0, or -1 with errno.
@export("getentropy")
pub fn getentropy(buf: *mut void, len: usize) i32 {
    if len > 256 {
        set_errno(5); // EIO in POSIX's terms; wasi-libc answers EIO
        return -1;
    }
    let e = unsafe sc_wasi_random_get(buf as *mut u8, len);
    if e != 0 {
        return fail(e);
    }
    return 0;
}

// ---- signals -------------------------------------------------------------------------------------------
//
// wasi-libc's emulation (`wasi-emulated-signal`): WASI delivers no signal, so a handler runs only when `raise`
// calls it. A signal with no handler takes its default action: nothing for those POSIX ignores or continues,
// else a message on stderr and `abort`; signal 0 and the real-time signals have none, and trap.

const NSIG: i32 = 65;
const SIGKILL: i32 = 9;
const SIGSTOP: i32 = 19;

// The default action of signals 0 to 31: 0 none, 1 "fatal", 2 "termination", 3 "stop", 4 a trap.
const SIG_DEFAULT: [u8; 32] = [
    4,
    2,
    2,
    1,
    1,
    1,
    1,
    1,
    1,
    2,
    2,
    1,
    2,
    2,
    2,
    2,
    2,
    0,
    0,
    3,
    3,
    3,
    3,
    0,
    1,
    1,
    2,
    2,
    0,
    2,
    2,
    1,
];

// The handler of each signal, as an address: 0 is `SIG_DFL`.
static mut SIG_HANDLERS: [usize; 65] = [0usize; 65];

// musl's descriptions, by signal number.
const SIG_NAMES: [str<'static>; 65] = [
    "Unknown signal",
    "Hangup",
    "Interrupt",
    "Quit",
    "Illegal instruction",
    "Trace/breakpoint trap",
    "Aborted",
    "Bus error",
    "Arithmetic exception",
    "Killed",
    "User defined signal 1",
    "Segmentation fault",
    "User defined signal 2",
    "Broken pipe",
    "Alarm clock",
    "Terminated",
    "Stack fault",
    "Child process status",
    "Continued",
    "Stopped (signal)",
    "Stopped",
    "Stopped (tty input)",
    "Stopped (tty output)",
    "Urgent I/O condition",
    "CPU time limit exceeded",
    "File size limit exceeded",
    "Virtual timer expired",
    "Profiling timer expired",
    "Window changed",
    "I/O possible",
    "Power failure",
    "Bad system call",
    "RT32",
    "RT33",
    "RT34",
    "RT35",
    "RT36",
    "RT37",
    "RT38",
    "RT39",
    "RT40",
    "RT41",
    "RT42",
    "RT43",
    "RT44",
    "RT45",
    "RT46",
    "RT47",
    "RT48",
    "RT49",
    "RT50",
    "RT51",
    "RT52",
    "RT53",
    "RT54",
    "RT55",
    "RT56",
    "RT57",
    "RT58",
    "RT59",
    "RT60",
    "RT61",
    "RT62",
    "RT63",
    "RT64",
];

/// `SIG_IGN`: does nothing.
@export("__SIG_IGN")
pub const fn sig_ign(_sig: i32) {}

/// `SIG_ERR`: a trap, should it ever run.
@export("__SIG_ERR")
@noreturn
pub fn sig_err(_sig: i32) {
    unsafe sc_wasm_trap();
}

/// The description of signal `sig`; "Unknown signal" outside 1 to 64.
@export("strsignal")
pub const fn strsignal(sig: i32) *mut char {
    let i = if (sig as u32).wrapping_sub(1) >= (NSIG - 1) as u32 {
        0usize;
    } else {
        sig as usize;
    };
    return (unsafe SIG_NAMES[i].ptr()) as *mut char;
}

/// Make `func` the handler of `sig`; the previous one, or `SIG_ERR` with EINVAL for a signal out of range,
/// SIGKILL or SIGSTOP.
@export("signal")
pub fn signal(sig: i32, func: fn(i32)) fn(i32) {
    if sig < 0 || sig >= NSIG || sig == SIGKILL || sig == SIGSTOP {
        set_errno(EINVAL);
        return sig_err;
    }
    let old = unsafe SIG_HANDLERS[sig as usize];
    unsafe SIG_HANDLERS[sig as usize] = func as usize;
    return unsafe (old as fn(i32));
}

/// Run the handler of `sig`, or its default action; 0, or -1 with EINVAL for a signal out of range.
@export("raise")
pub fn raise(sig: i32) i32 {
    if sig < 0 || sig >= NSIG {
        set_errno(EINVAL);
        return -1;
    }
    let h = unsafe SIG_HANDLERS[sig as usize];
    if h != 0 {
        let f = unsafe (h as fn(i32));
        f(sig);
        return 0;
    }
    let kind = if sig < 32 {
        unsafe SIG_DEFAULT[sig as usize];
    } else {
        4u8;
    };
    if kind == 0 {
        return 0;
    }
    if kind == 4 {
        unsafe sc_wasm_trap();
    }
    let what = if kind == 1 {
        "Program received fatal signal: ";
    } else if kind == 2 {
        "Program received termination signal: ";
    } else {
        "Program received stop signal: ";
    };
    let e = stdio_stream(2);
    let _ = fputs(what.ptr() as *const char, e);
    let _ = fputs(strsignal(sig), e);
    let _ = fputs("\n".ptr() as *const char, e);
    abort();
}

// ---- threads -------------------------------------------------------------------------------------------
//
// wasm32-wasip1 runs one thread: wasi-libc's single-thread stubs. `pthread_create` and `pthread_join` are
// not defined, as wasi-libc's C library leaves them to `wasi-emulated-pthread`.

extern "C" {
    @import("struct __pthread")
    pub type PThread;
}

// The thread `pthread_self` names: only its address counts.
static mut MAIN_THREAD: u8 = 0;

/// The calling thread, the only one.
@export("pthread_self")
pub fn pthread_self() *mut PThread {
    return ((unsafe &mut MAIN_THREAD) as *mut u8) as *mut PThread;
}

/// Whether `a` and `b` name the same thread.
@export("pthread_equal")
pub const fn pthread_equal(a: *mut PThread, b: *mut PThread) i32 {
    return (a == b) as i32;
}

/// End the calling thread, the only one: the process exits with status 0.
@export("pthread_exit")
@noreturn
pub fn pthread_exit(_result: *mut void) {
    exit(0);
}

// ---- memory ----------------------------------------------------------------------------------------------
//
// The heap is the memory past `__heap_base`, grown by `memory.grow`. Allocation is TLSF (two-level
// segregated fit): every free block sits in the list of its size class, and two bitmaps find the first
// non-empty class that fits in constant time; a freed block merges with its free neighbours at once.
//
// A block starts 4 bytes before a 16-byte boundary: a header word (the block size, a multiple of 16, with
// bit 0 set while the block is in use and bit 1 while the block before it is), then the payload. A free
// block holds its list links after the header and repeats its size in its last word, where the block after
// it finds it to merge. A zero-size block in use ends the heap.

const ALIGN: usize = 16;
const HDR: usize = 4;
const MIN_BLOCK: usize = 16;
const USED: usize = 1;
const PREV_USED: usize = 2;
const SIZE_MASK: usize = ~15usize;
const PAGE: usize = 65536;
// Size classes: below 256 bytes one class per 16 bytes (first level 0); from 256 up, first level
// floor(log2(size)) - 7 and 16 second-level classes per power of two.
const SL_LOG: usize = 4;
const SMALL: usize = 256;
const FL_COUNT: usize = 25;
const SL_COUNT: usize = 16;

static mut FL_MAP: u32 = 0;
static mut SL_MAP: [u32; FL_COUNT] = [0u32; FL_COUNT];
static mut HEADS: [usize; FL_COUNT * SL_COUNT] = [0usize; FL_COUNT * SL_COUNT];
// The end block's address; 0 before the first allocation.
static mut HEAP_END: usize = 0;
// The end of the memory the heap took: past it, `sbrk` may have taken memory the heap must skip.
static mut HEAP_TOP: usize = 0;

const fn word(a: usize) usize {
    return unsafe *(a as *const usize);
}

const fn set_word(a: usize, v: usize) {
    unsafe *(a as *mut usize) = v;
}

const fn bsize(b: usize) usize {
    return word(b) & SIZE_MASK;
}

const fn floor_log2(x: usize) usize {
    return 31 - (x as u32).leading_zeros();
}

// The class (first level, second level) of a free block of `size` bytes.
const fn class_of(size: usize, fl: &mut usize, sl: &mut usize) {
    if size < SMALL {
        *fl = 0;
        *sl = size / 16;
        return;
    }
    let l = floor_log2(size);
    *fl = l - 7;
    *sl = size >> l - SL_LOG & SL_COUNT - 1;
}

fn link_free(b: usize) {
    let mut fl: usize = 0;
    let mut sl: usize = 0;
    class_of(bsize(b), &mut fl, &mut sl);
    let head = unsafe HEADS[fl * SL_COUNT + sl];
    set_word(b + 4, head);
    set_word(b + 8, 0);
    if head != 0 {
        set_word(head + 8, b);
    }
    unsafe HEADS[fl * SL_COUNT + sl] = b;
    unsafe FL_MAP |= 1u32 << fl as u32;
    unsafe SL_MAP[fl] |= 1u32 << sl as u32;
}

fn unlink_free(b: usize) {
    let mut fl: usize = 0;
    let mut sl: usize = 0;
    class_of(bsize(b), &mut fl, &mut sl);
    let next = word(b + 4);
    let prev = word(b + 8);
    if next != 0 {
        set_word(next + 8, prev);
    }
    if prev != 0 {
        set_word(prev + 4, next);
    } else {
        unsafe HEADS[fl * SL_COUNT + sl] = next;
        if next == 0 {
            unsafe SL_MAP[fl] &= ~(1u32 << sl as u32);
            if unsafe SL_MAP[fl] == 0 {
                unsafe FL_MAP &= ~(1u32 << fl as u32);
            }
        }
    }
}

// Mark free block `b` free: its footer, and the next block's PREV_USED bit cleared.
fn put_free(b: usize, size: usize, prev_used: usize) {
    set_word(b, size | prev_used);
    set_word(b + size - 4, size);
    let n = b + size;
    set_word(n, word(n) & ~PREV_USED);
    link_free(b);
}

// A free block of at least `size` bytes, unlinked, or 0.
fn find_free(size: usize) usize {
    // Round up to the next class boundary, so any block of the class found fits.
    let mut s = size;
    if s >= SMALL {
        s += (1usize << floor_log2(s) - SL_LOG) - 1;
    }
    let mut fl: usize = 0;
    let mut sl: usize = 0;
    class_of(s, &mut fl, &mut sl);
    if fl >= FL_COUNT {
        return 0;
    }
    let mut smap = unsafe SL_MAP[fl] & ~0u32 << sl as u32;
    if smap == 0 {
        if fl + 1 >= FL_COUNT {
            return 0;
        }
        let fmap = unsafe FL_MAP & ~0u32 << (fl + 1) as u32;
        if fmap == 0 {
            return 0;
        }
        fl = fmap.trailing_zeros();
        smap = unsafe SL_MAP[fl];
    }
    sl = smap.trailing_zeros();
    let b = unsafe HEADS[fl * SL_COUNT + sl];
    unlink_free(b);
    return b;
}

// Make `b` (a block of at least `size` bytes, out of every list) a used block of `size` bytes: the rest,
// when it can hold a block, becomes a free one.
fn take(b: usize, size: usize) {
    let have = bsize(b);
    let prev = word(b) & PREV_USED;
    if have - size >= MIN_BLOCK {
        set_word(b, size | USED | prev);
        put_free(b + size, have - size, PREV_USED);
    } else {
        set_word(b, have | USED | prev);
        let n = b + have;
        set_word(n, word(n) | PREV_USED);
    }
}

// Set the heap up over the memory between `__heap_base` and the current memory size: the first block starts
// 4 bytes before the first 16-byte boundary past `__heap_base`.
fn init_heap() {
    let base = (unsafe &__heap_base) as usize + HDR + ALIGN - 1 & ~(ALIGN - 1);
    let top = unsafe sc_wasm_memory_size() * PAGE;
    unsafe HEAP_TOP = top;
    unsafe HEAP_END = base - HDR;
    set_word(unsafe HEAP_END, USED | PREV_USED);
    if top >= base + MIN_BLOCK + ALIGN {
        extend_heap(top - HDR);
    }
}

// Grow the heap so a free block of class at least `size`'s exists; whether it grew. The new memory joins
// the free block before the end block, or becomes one: asking for an eighth more than `size` covers the
// rounding up of `find_free`.
fn grow(size: usize) bool {
    let need = size + (size >> 3) + 4 * MIN_BLOCK;
    let pages = (need + PAGE - 1) / PAGE;
    // At least 1 MiB at a time: a page per call would cost a `memory.grow` per allocation.
    let ask = if pages < 16 {
        16usize;
    } else {
        pages;
    };
    let mut old = unsafe sc_wasm_memory_grow(ask);
    if old < 0 && ask != pages {
        old = unsafe sc_wasm_memory_grow(pages);
    }
    if old < 0 {
        return false;
    }
    let start = old as usize * PAGE;
    if start != unsafe HEAP_TOP {
        // `sbrk` took the memory between: the end block becomes a used block over it, never freed, and the
        // heap goes on at the first block of the new memory.
        let e = unsafe HEAP_END;
        let n = start + ALIGN - HDR;
        set_word(e, n - e | USED | word(e) & PREV_USED);
        set_word(n, USED | PREV_USED);
        unsafe HEAP_END = n;
    }
    let top = unsafe sc_wasm_memory_size() * PAGE;
    unsafe HEAP_TOP = top;
    extend_heap(top - HDR);
    return true;
}

// Move the end block to `end` (16-byte aligned minus 4): the space between becomes free, merged with the
// free block before the old end.
fn extend_heap(end: usize) {
    let old = unsafe HEAP_END;
    let mut b = old;
    let mut prev = word(old) & PREV_USED;
    if prev == 0 {
        b = old - word(old - 4);
        unlink_free(b);
        prev = word(b) & PREV_USED;
    }
    let lim = (end + HDR & ~(ALIGN - 1)) - HDR;
    unsafe HEAP_END = lim;
    set_word(lim, USED);
    put_free(b, lim - b, prev);
}

// The block size that holds `n` payload bytes.
const fn block_size(n: usize) usize {
    let s = n + HDR + ALIGN - 1 & ~(ALIGN - 1);
    return if s < MIN_BLOCK {
        MIN_BLOCK;
    } else {
        s;
    };
}

// `n` bytes aligned to 16, or null. The allocator of this module and of `malloc`.
fn heap_alloc(n: usize) *mut void {
    if n > 0x7FFF0000 {
        return null;
    }
    let size = block_size(n);
    if unsafe HEAP_END == 0 {
        init_heap();
    }
    let mut b = find_free(size);
    if b == 0 {
        if !grow(size) {
            return null;
        }
        b = find_free(size);
        if b == 0 {
            return null;
        }
    }
    take(b, size);
    return (b + HDR) as *mut void;
}

fn heap_free(p: *mut void) {
    if p == null {
        return;
    }
    let mut b = p as usize - HDR;
    let mut size = bsize(b);
    let mut prev = word(b) & PREV_USED;
    let n = b + size;
    if (word(n) & USED) == 0 {
        unlink_free(n);
        size += bsize(n);
    }
    if prev == 0 {
        let pb = b - word(b - 4);
        unlink_free(pb);
        size += bsize(pb);
        b = pb;
        prev = word(pb) & PREV_USED;
    }
    put_free(b, size, prev);
}

// Resize block of payload `p` in place to `size` bytes when it or its free successor allow; whether it did.
fn resize_in_place(p: *mut void, size: usize) bool {
    let b = p as usize - HDR;
    let have = bsize(b);
    if size <= have {
        if have - size >= MIN_BLOCK {
            let prev = word(b) & PREV_USED;
            set_word(b, size | USED | prev);
            // The tail merges with a free successor.
            let mut tail = have - size;
            let n = b + have;
            if (word(n) & USED) == 0 {
                unlink_free(n);
                tail += bsize(n);
            }
            put_free(b + size, tail, PREV_USED);
        }
        return true;
    }
    let n = b + have;
    if (word(n) & USED) != 0 || have + bsize(n) < size {
        return false;
    }
    unlink_free(n);
    let total = have + bsize(n);
    let prev = word(b) & PREV_USED;
    set_word(b, total | USED | prev);
    let nn = b + total;
    set_word(nn, word(nn) | PREV_USED);
    take(b, size);
    return true;
}

/// `n` bytes aligned to 16, or null with ENOMEM.
@export("malloc")
pub fn malloc(n: usize) *mut void {
    let p = heap_alloc(n);
    if p == null {
        set_errno(ENOMEM);
    }
    return p;
}

/// Release a block of `malloc`, `calloc`, `realloc` or `aligned_alloc`; null does nothing.
@export("free")
pub fn free(p: *mut void) {
    heap_free(p);
}

/// `count * n` zeroed bytes, or null (also when the product overflows).
@export("calloc")
pub fn calloc(count: usize, n: usize) *mut void {
    if n != 0 && count > 0x7FFF0000 / n {
        set_errno(ENOMEM);
        return null;
    }
    let total = count * n;
    let p = heap_alloc(total);
    if p == null {
        set_errno(ENOMEM);
        return null;
    }
    fill(p as *mut u8, 0, total);
    return p;
}

/// Resize block `p` to `n` bytes, moving it when it cannot grow in place; null leaves `p` alone.
@export("realloc")
pub fn realloc(p: *mut void, n: usize) *mut void {
    if p == null {
        return malloc(n);
    }
    if n > 0x7FFF0000 {
        set_errno(ENOMEM);
        return null;
    }
    if resize_in_place(p, block_size(n)) {
        return p;
    }
    let q = heap_alloc(n);
    if q == null {
        set_errno(ENOMEM);
        return null;
    }
    let have = bsize(p as usize - HDR) - HDR;
    copy(
        q as *mut u8,
        p as *const u8,
        if have < n {
            have;
        } else {
            n;
        },
    );
    heap_free(p);
    return q;
}

/// `n` bytes aligned to `align` (a power of two), or null with EINVAL or ENOMEM.
@export("aligned_alloc")
pub fn aligned_alloc(align: usize, n: usize) *mut void {
    if align == 0 || (align & align - 1) != 0 {
        set_errno(EINVAL);
        return null;
    }
    if align <= ALIGN {
        return malloc(n);
    }
    if align > 0x10000000 || n > 0x7FFF0000 - align {
        set_errno(ENOMEM);
        return null;
    }
    // Room for the alignment and for a free block before the aligned payload.
    let raw = heap_alloc(n + align + MIN_BLOCK);
    if raw == null {
        set_errno(ENOMEM);
        return null;
    }
    let b = raw as usize - HDR;
    let mut p = raw as usize + align - 1 & ~(align - 1);
    if p - raw as usize < MIN_BLOCK && p != raw as usize {
        p += align;
    }
    if p == raw as usize {
        return raw;
    }
    // Split off the bytes before the aligned payload as a free block.
    let nb = p - HDR;
    let lead = nb - b;
    let total = bsize(b);
    let prev = word(b) & PREV_USED;
    set_word(nb, total - lead | USED | PREV_USED);
    set_word(b, lead | USED | prev);
    heap_free(raw);
    let _ = resize_in_place(p as *mut void, block_size(n));
    return p as *mut void;
}

/// POSIX's form of `aligned_alloc`: 0 with the block in `*out`, EINVAL or ENOMEM.
@export("posix_memalign")
pub fn posix_memalign(out: *mut *mut void, align: usize, n: usize) i32 {
    if align < sizeof(*mut void) || (align & align - 1) != 0 {
        return EINVAL;
    }
    let p = aligned_alloc(align, n);
    if p == null {
        return ENOMEM;
    }
    unsafe *out = p;
    return 0;
}

/// Grow linear memory by `inc` bytes, a multiple of the 64 KiB page (0 asks for the end of memory): the
/// start of the new memory, which the heap never uses, or -1 as an address with ENOMEM. A negative or
/// partial-page increment aborts: wasm memory cannot shrink, and wasi-libc's `sbrk` takes whole pages.
@export("sbrk")
pub fn sbrk(inc: isize) *mut void {
    if inc == 0 {
        return (unsafe sc_wasm_memory_size() * PAGE) as *mut void;
    }
    if inc % PAGE as isize != 0 || inc < 0 {
        abort();
    }
    // The heap takes the memory it starts with first, so the new memory stays outside it.
    if unsafe HEAP_END == 0 {
        init_heap();
    }
    let old = unsafe sc_wasm_memory_grow(inc as usize / PAGE);
    if old < 0 {
        set_errno(ENOMEM);
        return (~0usize) as *mut void;
    }
    return (old as usize * PAGE) as *mut void;
}

// ---- strings -------------------------------------------------------------------------------------------

// Copy `n` bytes forward: 8 at a time when both addresses share their alignment mod 8.
const fn copy(d: *mut u8, s: *const u8, n: usize) {
    let mut i: usize = 0;
    if ((d as usize ^ s as usize) & 7) == 0 {
        while i < n && (d as usize + i & 7) != 0 {
            unsafe d[i] = unsafe s[i];
            i += 1;
        }
        while i + 32 <= n {
            let dw = (unsafe (d + i)) as *mut u64;
            let sw = (unsafe (s + i)) as *const u64;
            unsafe dw[0] = unsafe sw[0];
            unsafe dw[1] = unsafe sw[1];
            unsafe dw[2] = unsafe sw[2];
            unsafe dw[3] = unsafe sw[3];
            i += 32;
        }
        while i + 8 <= n {
            unsafe *((unsafe (d + i)) as *mut u64) = unsafe *((unsafe (s + i)) as *const u64);
            i += 8;
        }
    } else if ((d as usize ^ s as usize) & 3) == 0 {
        while i < n && (d as usize + i & 3) != 0 {
            unsafe d[i] = unsafe s[i];
            i += 1;
        }
        while i + 4 <= n {
            unsafe *((unsafe (d + i)) as *mut u32) = unsafe *((unsafe (s + i)) as *const u32);
            i += 4;
        }
    }
    while i < n {
        unsafe d[i] = unsafe s[i];
        i += 1;
    }
}

// Copy `n` bytes backward, for an overlap where the destination is after the source.
const fn copy_back(d: *mut u8, s: *const u8, n: usize) {
    let mut i = n;
    if ((d as usize ^ s as usize) & 7) == 0 {
        while i > 0 && (d as usize + i & 7) != 0 {
            i -= 1;
            unsafe d[i] = unsafe s[i];
        }
        while i >= 8 {
            i -= 8;
            unsafe *((unsafe (d + i)) as *mut u64) = unsafe *((unsafe (s + i)) as *const u64);
        }
    }
    while i > 0 {
        i -= 1;
        unsafe d[i] = unsafe s[i];
    }
}

// Set `n` bytes to `c`: 8 at a time past the alignment.
const fn fill(d: *mut u8, c: u8, n: usize) {
    let mut i: usize = 0;
    while i < n && (d as usize + i & 7) != 0 {
        unsafe d[i] = c;
        i += 1;
    }
    let w = c as u64 * 0x0101010101010101u64;
    while i + 8 <= n {
        unsafe *((unsafe (d + i)) as *mut u64) = w;
        i += 8;
    }
    while i < n {
        unsafe d[i] = c;
        i += 1;
    }
}

/// Copy `n` bytes; the regions must not overlap.
@export("memcpy")
pub const fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void {
    copy(dst as *mut u8, src as *const u8, n);
    return dst;
}

/// Copy `n` bytes; the regions may overlap.
@export("memmove")
pub const fn memmove(dst: *mut void, src: *const void, n: usize) *mut void {
    let d = dst as usize;
    let s = src as usize;
    if d.wrapping_sub(s) >= n {
        // Also when `d < s`: the difference wraps past `n`.
        copy(dst as *mut u8, src as *const u8, n);
    } else {
        copy_back(dst as *mut u8, src as *const u8, n);
    }
    return dst;
}

/// Set `n` bytes to `c` (as an unsigned char).
@export("memset")
pub const fn memset(dst: *mut void, c: i32, n: usize) *mut void {
    fill(dst as *mut u8, c as u8, n);
    return dst;
}

/// Compare `n` bytes as unsigned chars: negative, zero or positive.
@export("memcmp")
pub const fn memcmp(a: *const void, b: *const void, n: usize) i32 {
    let x = a as *const u8;
    let y = b as *const u8;
    for i in 0..n {
        let d = (unsafe x[i]) as i32 - (unsafe y[i]) as i32;
        if d != 0 {
            return d;
        }
    }
    return 0;
}

/// The first of `n` bytes equal to `c` (as an unsigned char), or null.
@export("memchr")
pub const fn memchr(p: *const void, c: i32, n: usize) *mut void {
    let s = p as *const u8;
    let b = c as u8;
    for i in 0..n {
        if unsafe s[i] == b {
            return (unsafe (s + i)) as *mut void;
        }
    }
    return null;
}

/// The length of NUL-terminated `s`.
@export("strlen")
pub const fn strlen(s: *const char) usize {
    let p = s as *const u8;
    let mut i: usize = 0;
    while unsafe p[i] != 0 {
        i += 1;
    }
    return i;
}

/// The length of `s`, at most `max`.
@export("strnlen")
pub const fn strnlen(s: *const char, max: usize) usize {
    let p = s as *const u8;
    let mut i: usize = 0;
    while i < max && unsafe p[i] != 0 {
        i += 1;
    }
    return i;
}

/// Compare NUL-terminated strings as unsigned chars.
@export("strcmp")
pub const fn strcmp(a: *const char, b: *const char) i32 {
    let x = a as *const u8;
    let y = b as *const u8;
    let mut i: usize = 0;
    while unsafe x[i] != 0 && unsafe x[i] == unsafe y[i] {
        i += 1;
    }
    return (unsafe x[i]) as i32 - (unsafe y[i]) as i32;
}

/// Compare at most `n` bytes of NUL-terminated strings.
@export("strncmp")
pub const fn strncmp(a: *const char, b: *const char, n: usize) i32 {
    let x = a as *const u8;
    let y = b as *const u8;
    if n == 0 {
        return 0;
    }
    let mut i: usize = 0;
    while i + 1 < n && unsafe x[i] != 0 && unsafe x[i] == unsafe y[i] {
        i += 1;
    }
    return (unsafe x[i]) as i32 - (unsafe y[i]) as i32;
}

/// The first `c` (as a char) in `s`, its terminator included, or null.
@export("strchr")
pub const fn strchr(s: *const char, c: i32) *mut char {
    let p = s as *const u8;
    let b = c as u8;
    let mut i: usize = 0;
    loop {
        if unsafe p[i] == b {
            return (unsafe (p + i)) as *mut char;
        }
        if unsafe p[i] == 0 {
            return null;
        }
        i += 1;
    }
}

// The first `c` in `s`, or its terminator.
const fn chrnul(s: *const u8, c: u8) *const u8 {
    let mut i: usize = 0;
    while unsafe s[i] != 0 && unsafe s[i] != c {
        i += 1;
    }
    return unsafe (s + i);
}

/// The last `c` (as a char) in `s`, its terminator included, or null.
@export("strrchr")
pub const fn strrchr(s: *const char, c: i32) *mut char {
    let p = s as *const u8;
    let b = c as u8;
    let n = strlen(s);
    let mut i = n + 1;
    while i > 0 {
        i -= 1;
        if unsafe p[i] == b {
            return (unsafe (p + i)) as *mut char;
        }
    }
    return null;
}

/// The first occurrence of `needle` in `hay`, or null; `hay` for an empty needle.
@export("strstr")
pub const fn strstr(hay: *const char, needle: *const char) *mut char {
    let h = hay as *const u8;
    let nd = needle as *const u8;
    let nl = strlen(needle);
    if nl == 0 {
        return hay as *mut char;
    }
    let mut i: usize = 0;
    while unsafe h[i] != 0 {
        if unsafe h[i] == unsafe nd[0] && strncmp(unsafe (hay + i), needle, nl) == 0 {
            return (unsafe (h + i)) as *mut char;
        }
        i += 1;
    }
    return null;
}

/// Copy `src` with its terminator to `dst`; `dst`.
@export("strcpy")
pub const fn strcpy(dst: *mut char, src: *const char) *mut char {
    copy(dst as *mut u8, src as *const u8, strlen(src) + 1);
    return dst;
}

/// A `malloc` copy of `s`, or null.
@export("strdup")
pub fn strdup(s: *const char) *mut char {
    let n = strlen(s);
    let p = malloc(n + 1) as *mut u8;
    if p != null {
        copy(p, s as *const u8, n + 1);
    }
    return p as *mut char;
}

// ---- characters ----------------------------------------------------------------------------------------
// The C locale: ASCII.

/// Whether `c` is a letter.
@export("isalpha")
pub const fn isalpha(c: i32) i32 {
    return ((c as u32 | 32).wrapping_sub(97) < 26) as i32;
}

/// Whether `c` is a decimal digit.
@export("isdigit")
pub const fn isdigit(c: i32) i32 {
    return ((c as u32).wrapping_sub(48) < 10) as i32;
}

/// Whether `c` is a letter or a digit.
@export("isalnum")
pub const fn isalnum(c: i32) i32 {
    return isalpha(c) | isdigit(c);
}

/// Whether `c` is white space: space, \t, \n, \v, \f or \r.
@export("isspace")
pub const fn isspace(c: i32) i32 {
    return (c == 32 || (c as u32).wrapping_sub(9) < 5) as i32;
}

/// Whether `c` is an uppercase letter.
@export("isupper")
pub const fn isupper(c: i32) i32 {
    return ((c as u32).wrapping_sub(65) < 26) as i32;
}

/// Whether `c` is a lowercase letter.
@export("islower")
pub const fn islower(c: i32) i32 {
    return ((c as u32).wrapping_sub(97) < 26) as i32;
}

/// Whether `c` is printable and not a space.
@export("isgraph")
pub const fn isgraph(c: i32) i32 {
    return ((c as u32).wrapping_sub(33) < 94) as i32;
}

/// Whether `c` is printable, the space included.
@export("isprint")
pub const fn isprint(c: i32) i32 {
    return ((c as u32).wrapping_sub(32) < 95) as i32;
}

/// Whether `c` is punctuation: printable, not a space, a letter or a digit.
@export("ispunct")
pub const fn ispunct(c: i32) i32 {
    return (isgraph(c) != 0 && isalnum(c) == 0) as i32;
}

/// Whether `c` is a control character.
@export("iscntrl")
pub const fn iscntrl(c: i32) i32 {
    return (c as u32 < 32 || c == 127) as i32;
}

/// Whether `c` is a space or a tab.
@export("isblank")
pub const fn isblank(c: i32) i32 {
    return (c == 32 || c == 9) as i32;
}

/// Whether `c` is a hexadecimal digit.
@export("isxdigit")
pub const fn isxdigit(c: i32) i32 {
    return (isdigit(c) != 0 || (c as u32 | 32).wrapping_sub(97) < 6) as i32;
}

/// `c` in uppercase when it is a lowercase letter.
@export("toupper")
pub const fn toupper(c: i32) i32 {
    if islower(c) != 0 {
        return c & 0x5f;
    }
    return c;
}

/// `c` in lowercase when it is an uppercase letter.
@export("tolower")
pub const fn tolower(c: i32) i32 {
    if isupper(c) != 0 {
        return c | 32;
    }
    return c;
}

// ---- environment ---------------------------------------------------------------------------------------

// The index in `ENV` of the entry for `name` (its first `nl` bytes), or `ENV_LEN`.
fn env_find(name: *const u8, nl: usize) usize {
    let n = unsafe ENV_LEN;
    for i in 0..n {
        let e = (unsafe ENV[i]) as *const u8;
        let mut k: usize = 0;
        while k < nl && unsafe e[k] == unsafe name[k] {
            k += 1;
        }
        if k == nl && unsafe e[nl] == 61 {
            return i;
        }
    }
    return n;
}

/// The value of environment variable `name`, or null.
@export("getenv")
pub fn getenv(name: *const char) *mut char {
    let nl = strnlen(name, 4096);
    let p = name as *const u8;
    if unsafe ENV == null || nl == 0 || unsafe *chrnul(p, 61) != 0 {
        return null;
    }
    let i = env_find(p, nl);
    if i == unsafe ENV_LEN {
        return null;
    }
    return unsafe (ENV[i] + (nl + 1));
}

/// Set environment variable `name` to `value` (when `overwrite` is nonzero or it is unset); 0, or -1 with
/// EINVAL (an empty name, or one with `=`) or ENOMEM.
@export("setenv")
pub fn setenv(name: *const char, value: *const char, overwrite: i32) i32 {
    let p = name as *const u8;
    let nl = strlen(name);
    if nl == 0 || unsafe *chrnul(p, 61) != 0 {
        set_errno(EINVAL);
        return -1;
    }
    let i = env_find(p, nl);
    if i < unsafe ENV_LEN && overwrite == 0 {
        return 0;
    }
    let vl = strlen(value);
    let e = heap_alloc(nl + vl + 2) as *mut u8;
    if e == null {
        set_errno(ENOMEM);
        return -1;
    }
    copy(e, p, nl);
    unsafe e[nl] = 61;
    copy(unsafe (e + (nl + 1)), value as *const u8, vl + 1);
    if i < unsafe ENV_LEN {
        if unsafe ENV_OWN[i] {
            heap_free(unsafe ENV[i]);
        }
        unsafe ENV[i] = e as *mut char;
        unsafe ENV_OWN[i] = true;
        return 0;
    }
    if unsafe ENV_LEN + 1 >= unsafe ENV_CAP {
        let cap = unsafe ENV_CAP * 2;
        let env = heap_alloc(cap * sizeof(*mut char)) as *mut *mut char;
        let own = heap_alloc(cap) as *mut bool;
        if env == null || own == null {
            heap_free(env);
            heap_free(own);
            heap_free(e);
            set_errno(ENOMEM);
            return -1;
        }
        for k in 0..unsafe ENV_LEN {
            unsafe env[k] = unsafe ENV[k];
            unsafe own[k] = unsafe ENV_OWN[k];
        }
        heap_free(unsafe ENV);
        heap_free(unsafe ENV_OWN);
        unsafe ENV = env;
        unsafe ENV_OWN = own;
        unsafe ENV_CAP = cap;
    }
    let n = unsafe ENV_LEN;
    unsafe ENV[n] = e as *mut char;
    unsafe ENV_OWN[n] = true;
    unsafe ENV[n + 1] = null;
    unsafe ENV_LEN = n + 1;
    return 0;
}

/// Remove environment variable `name`; 0, or -1 with EINVAL.
@export("unsetenv")
pub fn unsetenv(name: *const char) i32 {
    let p = name as *const u8;
    let nl = strlen(name);
    if nl == 0 || unsafe *chrnul(p, 61) != 0 {
        set_errno(EINVAL);
        return -1;
    }
    let i = env_find(p, nl);
    let n = unsafe ENV_LEN;
    if i == n {
        return 0;
    }
    if unsafe ENV_OWN[i] {
        heap_free(unsafe ENV[i]);
    }
    for k in i..n - 1 {
        unsafe ENV[k] = unsafe ENV[k + 1];
        unsafe ENV_OWN[k] = unsafe ENV_OWN[k + 1];
    }
    unsafe ENV[n - 1] = null;
    unsafe ENV_LEN = n - 1;
    return 0;
}

/// The environment as `NAME=value` strings ending in null, for the runtime and the test runner (C's
/// `environ`, which the headers declare as an object this module cannot define).
@export("__wasilibc_get_environ")
pub fn environ() *mut *mut char {
    return unsafe ENV;
}

// ---- integer conversions -------------------------------------------------------------------------------

// What musl's `shgetc` reads, through a cursor: a NUL-terminated string for `strtod` and its kin (`kind` 0),
// where `get` past the terminator keeps answering 0; or, for the scanf family, a string its NUL ends
// (`kind` 1) or a stream (`kind` 2), read up to a limit (`limit`, musl's `shlim`): there `get` answers -1 at
// the end or the limit, and `unget` then does nothing until the next `limit`. `bad` makes the conversion
// consume nothing.
struct Scan {
    pub s: *const u8,
    pub pos: usize,
    pub bad: bool,
    pub kind: u8,
    // The next byte of a scanf string.
    pub at: usize,
    pub st: *mut Stream,
    // The most bytes `get` reads after `limit`: 0 for no limit, and a negative one ends at once, as musl's.
    pub lim: i64,
    pub end: bool,
}

// A cursor of `kind` over string `s` or stream `st`.
const fn scan_of(kind: u8, s: *const u8, st: *mut Stream) Scan {
    return Scan { s: s, pos: 0, bad: false, kind: kind, at: 0, st: st, lim: 0, end: false };
}

extend Scan {
    fn get(self: &mut Scan) i32 {
        if self.kind == 0 {
            let c = (unsafe self.s[self.pos]) as i32;
            self.pos += 1;
            return c;
        }
        if self.end || self.lim != 0 && self.pos as i64 >= self.lim {
            self.end = true;
            return -1;
        }
        let mut c: i32 = 0;
        if self.kind == 1 {
            c = unsafe self.s[self.at];
            if c == 0 {
                self.end = true;
                return -1;
            }
            self.at += 1;
        } else {
            let f = unsafe &mut *self.st;
            // The last bytes read stay in front of the new input, for `unget`.
            if f.rpos == f.rend && !fill_input(
                f,
                if f.rpos < 8 {
                    f.rpos;
                } else {
                    8usize;
                },
            ) {
                self.end = true;
                return -1;
            }
            c = unsafe f.buf[f.rpos];
            f.rpos += 1;
        }
        self.pos += 1;
        return c;
    }

    const fn unget(self: &mut Scan) {
        if self.kind == 0 {
            self.pos -= 1;
            return;
        }
        if self.end {
            return;
        }
        self.pos -= 1;
        if self.kind == 1 {
            self.at -= 1;
        } else {
            unsafe (*self.st).rpos -= 1;
        }
    }

    // musl's `shlim`: count from here, and read at most `n` bytes (0: no limit).
    const fn limit(self: &mut Scan, n: i64) {
        self.lim = n;
        self.pos = 0;
        self.end = false;
        self.bad = false;
    }

    // The bytes the conversion consumed.
    const fn used(self: &Scan) usize {
        return if self.bad {
            0usize;
        } else {
            self.pos;
        };
    }
}

// The digit value of `c` in bases up to 36, or 255.
const fn digit_val(c: i32) u32 {
    let u = c as u32;
    if u.wrapping_sub(48) < 10 {
        return u - 48;
    }
    if (u | 32).wrapping_sub(97) < 26 {
        return (u | 32) - 87;
    }
    return 255;
}

// musl's `__intscan`: an integer in `base` (0: by its prefix) clamped to `lim` (an unsigned type's maximum,
// or a signed type's maximum plus one, whose low bit 0 marks it signed): the value as unsigned, ERANGE on
// overflow. Without `pok` (scanf), a "0x" that no hex digit follows consumes nothing.
fn intscan(f: &mut Scan, base0: u32, lim: u64, pok: bool) u64 {
    let mut base = base0;
    if base > 36 || base == 1 {
        set_errno(EINVAL);
        return 0;
    }
    let mut c = f.get();
    while isspace(c) != 0 {
        c = f.get();
    }
    let mut neg: u64 = 0;
    if c == 43 || c == 45 {
        if c == 45 {
            neg = ~0u64;
        }
        c = f.get();
    }
    if (base == 0 || base == 16) && c == 48 {
        c = f.get();
        if (c | 32) == 120 {
            c = f.get();
            if digit_val(c) >= 16 {
                f.unget();
                if pok {
                    f.unget();
                } else {
                    f.bad = true;
                }
                return 0;
            }
            base = 16;
        } else if base == 0 {
            base = 8;
        }
    } else {
        if base == 0 {
            base = 10;
        }
        if digit_val(c) >= base {
            f.unget();
            f.bad = true;
            set_errno(EINVAL);
            return 0;
        }
    }
    let mut y: u64 = 0;
    let mut over = false;
    while digit_val(c) < base {
        let d = digit_val(c) as u64;
        if !over {
            if y > (~0u64 - d) / base as u64 {
                over = true;
            } else {
                y = y * base as u64 + d;
            }
        }
        c = f.get();
    }
    f.unget();
    if over {
        set_errno(ERANGE);
        y = lim;
        if (lim & 1) != 0 {
            neg = 0;
        }
    }
    if y >= lim {
        if (lim & 1) == 0 && neg == 0 {
            set_errno(ERANGE);
            return lim - 1;
        } else if y > lim {
            set_errno(ERANGE);
            return lim;
        }
    }
    return (y ^ neg).wrapping_sub(neg);
}

fn strtox(s: *const char, end: *mut *mut char, base: i32, lim: u64) u64 {
    let mut f = scan_of(0, s as *const u8, null);
    let y = intscan(&mut f, base as u32, lim, true);
    if end != null {
        unsafe *end = (unsafe (s + f.used())) as *mut char;
    }
    return y;
}

/// `s` as a `long` in `base` (0: by prefix); `*end` past the digits. ERANGE clamps.
@export("strtol")
pub fn strtol(s: *const char, end: *mut *mut char, base: i32) isize {
    return strtox(s, end, base, 0x80000000u64) as isize;
}

/// `s` as an `unsigned long`.
@export("strtoul")
pub fn strtoul(s: *const char, end: *mut *mut char, base: i32) usize {
    return strtox(s, end, base, 0xFFFFFFFFu64) as usize;
}

/// `s` as a `long long`.
@export("strtoll")
pub fn strtoll(s: *const char, end: *mut *mut char, base: i32) i64 {
    return strtox(s, end, base, 0x8000000000000000u64) as i64;
}

/// `s` as an `unsigned long long`.
@export("strtoull")
pub fn strtoull(s: *const char, end: *mut *mut char, base: i32) u64 {
    return strtox(s, end, base, ~0u64);
}

// musl's `atoi` and its kin: optional white space and sign, then decimal digits, accumulated negative so
// the most negative value fits; an overflow wraps.
const fn ato(s: *const char) i64 {
    let p = s as *const u8;
    let mut i: usize = 0;
    while isspace(unsafe p[i]) != 0 {
        i += 1;
    }
    let mut neg = false;
    if unsafe p[i] == 45 {
        neg = true;
        i += 1;
    } else if unsafe p[i] == 43 {
        i += 1;
    }
    let mut n: i64 = 0;
    while isdigit(unsafe p[i]) != 0 {
        n = n.wrapping_mul(10).wrapping_sub(unsafe p[i] - 48);
        i += 1;
    }
    return if neg {
        n;
    } else {
        n.wrapping_neg();
    };
}

/// `s` as an `int` in base 10 (an overflow wraps, as C leaves it undefined).
@export("atoi")
pub const fn atoi(s: *const char) i32 {
    // musl accumulates in `int`: the low 32 bits of the `long long` result are the same.
    return ato(s) as i32;
}

/// `s` as a `long` in base 10.
@export("atol")
pub const fn atol(s: *const char) isize {
    return ato(s) as isize;
}

/// `s` as a `long long` in base 10.
@export("atoll")
pub const fn atoll(s: *const char) i64 {
    return ato(s);
}

/// |x|.
@export("abs")
pub const fn abs(x: i32) i32 {
    return if x < 0 {
        x.wrapping_neg();
    } else {
        x;
    };
}

/// |x| of a `long`.
@export("labs")
pub const fn labs(x: isize) isize {
    return if x < 0 {
        x.wrapping_neg();
    } else {
        x;
    };
}

/// |x| of a `long long`.
@export("llabs")
pub const fn llabs(x: i64) i64 {
    return if x < 0 {
        x.wrapping_neg();
    } else {
        x;
    };
}

extern "C" "stdlib.h" {
    @import("div_t")
    pub struct div_t {
        pub quot: i32,
        pub rem: i32,
    }
    @import("ldiv_t")
    pub struct ldiv_t {
        pub quot: isize,
        pub rem: isize,
    }
    @import("lldiv_t")
    pub struct lldiv_t {
        pub quot: i64,
        pub rem: i64,
    }
}

/// The quotient of `n / d` truncated toward zero, and its remainder.
@export("div")
pub const fn div(n: i32, d: i32) div_t {
    return div_t { quot: n / d, rem: n % d };
}

/// `div` of `long`s.
@export("ldiv")
pub const fn ldiv(n: isize, d: isize) ldiv_t {
    return ldiv_t { quot: n / d, rem: n % d };
}

/// `div` of `long long`s.
@export("lldiv")
pub const fn lldiv(n: i64, d: i64) lldiv_t {
    return lldiv_t { quot: n / d, rem: n % d };
}

// musl's generator: a 64-bit linear congruential state, its top 31 bits per value.
static mut RAND_SEED: u64 = 0;

/// Seed `rand`.
@export("srand")
pub fn srand(s: u32) {
    unsafe RAND_SEED = (s as u64).wrapping_sub(1);
}

/// A value in 0..=2^31 - 1.
@export("rand")
pub fn rand() i32 {
    unsafe RAND_SEED = unsafe RAND_SEED.wrapping_mul(6364136223846793005u64).wrapping_add(1);
    return (unsafe RAND_SEED >> 33) as i32;
}

// ---- time ----------------------------------------------------------------------------------------------

extern "C" "time.h" {
    pub struct timespec {
        pub tv_sec: i64,
        pub tv_nsec: isize,
    }
    // What a `clockid_t` points at. The header's clocks `_CLOCK_REALTIME` and `_CLOCK_MONOTONIC` are
    // `const` objects, which no Super-C definition is: `super_rt.h` spells `CLOCK_REALTIME` and
    // `CLOCK_MONOTONIC` as their WASI clock id plus one, cast to `clockid_t`.
    @import("struct __clockid")
    pub type ClockTag;
    pub struct tm {
        pub tm_sec: i32,
        pub tm_min: i32,
        pub tm_hour: i32,
        pub tm_mday: i32,
        pub tm_mon: i32,
        pub tm_year: i32,
        pub tm_wday: i32,
        pub tm_yday: i32,
        pub tm_isdst: i32,
        @import("__tm_gmtoff")
        pub gmtoff: i32,
        @import("__tm_zone")
        pub zone: *const char,
        @import("__tm_nsec")
        pub nsec: i32,
    }
}

/// The time of clock `clock` (`CLOCK_REALTIME` or `CLOCK_MONOTONIC`) through `tp`; 0, or -1 with errno.
@export("clock_gettime")
pub fn clock_gettime(clock: *const ClockTag, tp: *mut timespec) i32 {
    let mut ts: u64 = 0;
    let e = unsafe sc_wasi_clock_time_get((clock as usize - 1) as u32, 1, &mut ts);
    if e != 0 {
        return fail(e);
    }
    unsafe *tp = timespec { tv_sec: (ts / 1000000000) as i64, tv_nsec: (ts % 1000000000) as isize };
    return 0;
}

/// Seconds since the epoch, also stored through `out` when it is not null.
@export("time")
pub fn time(out: *mut i64) i64 {
    let mut ts: u64 = 0;
    let _ = unsafe sc_wasi_clock_time_get(CLOCK_REALTIME, 1000000000, &mut ts);
    let t = (ts / 1000000000) as i64;
    if out != null {
        unsafe *out = t;
    }
    return t;
}

// The monotonic time `clock` counts from: its first call, as wasi-libc's process-clock emulation does.
static mut CLOCK_START: u64 = 0;

/// The process time in `CLOCKS_PER_SEC` (10^9) units: WASI has no process clock, so the monotonic time
/// since the first call.
@export("clock")
pub fn clock() i64 {
    let mut ts: u64 = 0;
    if unsafe sc_wasi_clock_time_get(CLOCK_MONOTONIC, 0, &mut ts) != 0 {
        return -1;
    }
    if unsafe CLOCK_START == 0 {
        unsafe CLOCK_START = ts;
    }
    return (ts - unsafe CLOCK_START) as i64;
}

/// `a - b` in seconds.
@export("difftime")
pub const fn difftime(a: i64, b: i64) f64 {
    return a as f64 - b as f64;
}

// Wait `ns` nanoseconds on the monotonic clock; the WASI errno.
fn sleep_ns(ns: u64) u16 {
    let sub = Subscription {
        userdata: 0,
        tag: EVENTTYPE_CLOCK,
        pad: [0u8; 7],
        id: CLOCK_MONOTONIC,
        timeout: ns,
        precision: 0,
        flags: 0,
    };
    let mut ev = Event { userdata: 0, error: 0, kind: 0, nbytes: 0, rwflags: 0 };
    let mut n: usize = 0;
    let e = unsafe sc_wasi_poll_oneoff(&sub, &mut ev, 1, &mut n);
    if e != 0 {
        return e;
    }
    return ev.error;
}

/// Sleep for `*req`; 0, or -1 with EINVAL for an invalid time. A sleep is never interrupted.
@export("nanosleep")
pub fn nanosleep(req: *const timespec, _rem: *mut timespec) i32 {
    let s = unsafe (*req).tv_sec;
    let ns = unsafe (*req).tv_nsec;
    if s < 0 || ns < 0 || ns >= 1000000000 {
        set_errno(EINVAL);
        return -1;
    }
    let total = if s as u64 > 18446744072 {
        ~0u64;
    } else {
        s as u64 * 1000000000 + ns as u64;
    };
    if sleep_ns(total) != 0 {
        set_errno(ENOTSUP);
        return -1;
    }
    return 0;
}

/// Sleep `secs` seconds; 0.
@export("sleep")
pub fn sleep(secs: u32) u32 {
    let _ = sleep_ns(secs as u64 * 1000000000);
    return 0;
}

// ---- broken-down time ----------------------------------------------------------------------------------
//
// musl's calendar arithmetic. WASI has no time zone: local time is UTC, as wasi-libc's.

const LEAPOCH: i64 = 946684800 + 86400 * (31 + 29);
const DAYS_PER_400Y: i64 = 365 * 400 + 97;
const DAYS_PER_100Y: i64 = 365 * 100 + 24;
const DAYS_PER_4Y: i64 = 365 * 4 + 1;
const UTC: str<'static> = "UTC";

static mut GM_TM: tm = tm {
    tm_sec: 0,
    tm_min: 0,
    tm_hour: 0,
    tm_mday: 0,
    tm_mon: 0,
    tm_year: 0,
    tm_wday: 0,
    tm_yday: 0,
    tm_isdst: 0,
    gmtoff: 0,
    zone: null,
    nsec: 0,
};
static mut LOCAL_TM: tm = tm {
    tm_sec: 0,
    tm_min: 0,
    tm_hour: 0,
    tm_mday: 0,
    tm_mon: 0,
    tm_year: 0,
    tm_wday: 0,
    tm_yday: 0,
    tm_isdst: 0,
    gmtoff: 0,
    zone: null,
    nsec: 0,
};

// musl's `__secs_to_tm`: the calendar fields of `t` seconds past the epoch; false when the year overflows
// an int.
const fn secs_to_tm(t: i64, out: &mut tm) bool {
    let days_in_month = [31, 30, 31, 30, 31, 31, 30, 31, 30, 31, 31, 29];
    if t < INT_MIN as i64 * 31622400 || t > INT_MAX as i64 * 31622400 {
        return false;
    }
    let secs = t - LEAPOCH;
    let mut days = secs / 86400;
    let mut remsecs = (secs % 86400) as i32;
    if remsecs < 0 {
        remsecs += 86400;
        days -= 1;
    }
    let mut wday = ((3 + days) % 7) as i32;
    if wday < 0 {
        wday += 7;
    }
    let mut qc_cycles = (days / DAYS_PER_400Y) as i32;
    let mut remdays = (days % DAYS_PER_400Y) as i32;
    if remdays < 0 {
        remdays += DAYS_PER_400Y as i32;
        qc_cycles -= 1;
    }
    let mut c_cycles = remdays / DAYS_PER_100Y as i32;
    if c_cycles == 4 {
        c_cycles -= 1;
    }
    remdays -= c_cycles * DAYS_PER_100Y as i32;
    let mut q_cycles = remdays / DAYS_PER_4Y as i32;
    if q_cycles == 25 {
        q_cycles -= 1;
    }
    remdays -= q_cycles * DAYS_PER_4Y as i32;
    let mut remyears = remdays / 365;
    if remyears == 4 {
        remyears -= 1;
    }
    remdays -= remyears * 365;
    let leap = (remyears == 0 && (q_cycles != 0 || c_cycles == 0)) as i32;
    let mut yday = remdays + 31 + 28 + leap;
    if yday >= 365 + leap {
        yday -= 365 + leap;
    }
    let mut years = remyears as i64 + 4 * q_cycles as i64 + 100 * c_cycles as i64 + 400 * qc_cycles as i64;
    let mut months: i32 = 0;
    while unsafe days_in_month[months as usize] <= remdays {
        remdays -= unsafe days_in_month[months as usize];
        months += 1;
    }
    if months >= 10 {
        months -= 12;
        years += 1;
    }
    if years + 100 > INT_MAX as i64 || years + 100 < INT_MIN as i64 {
        return false;
    }
    out.tm_year = (years + 100) as i32;
    out.tm_mon = months + 2;
    out.tm_mday = remdays + 1;
    out.tm_wday = wday;
    out.tm_yday = yday;
    out.tm_hour = remsecs / 3600;
    out.tm_min = remsecs / 60 % 60;
    out.tm_sec = remsecs % 60;
    return true;
}

// musl's `__year_to_secs`: the seconds from the epoch to the start of year `year` (past 1900), and whether
// it is a leap year.
const fn year_to_secs(year: i64, is_leap: &mut bool) i64 {
    if (year as u64).wrapping_sub(2) <= 136 {
        let y = year as i32;
        let mut leaps = y - 68 >> 2;
        if (y - 68 & 3) == 0 {
            leaps -= 1;
            *is_leap = true;
        } else {
            *is_leap = false;
        }
        return 31536000 * (y - 70) as i64 + 86400 * leaps as i64;
    }
    let mut cycles = ((year - 100) / 400) as i32;
    let mut rem = ((year - 100) % 400) as i32;
    if rem < 0 {
        cycles -= 1;
        rem += 400;
    }
    let mut centuries: i32 = 0;
    let mut leaps: i32 = 0;
    if rem == 0 {
        *is_leap = true;
    } else {
        if rem >= 200 {
            if rem >= 300 {
                centuries = 3;
                rem -= 300;
            } else {
                centuries = 2;
                rem -= 200;
            }
        } else if rem >= 100 {
            centuries = 1;
            rem -= 100;
        }
        if rem == 0 {
            *is_leap = false;
        } else {
            leaps = rem / 4;
            rem %= 4;
            *is_leap = rem == 0;
        }
    }
    leaps += 97 * cycles + 24 * centuries - (*is_leap) as i32;
    return (year - 100) * 31536000 + leaps as i64 * 86400 + 946684800 + 86400;
}

// musl's `__tm_to_secs`: the seconds from the epoch to the time `t` names, its fields out of range carried.
const fn tm_to_secs(t: &tm) i64 {
    let mut year = t.tm_year as i64;
    let mut month = t.tm_mon;
    if month >= 12 || month < 0 {
        let mut adj = month / 12;
        month %= 12;
        if month < 0 {
            adj -= 1;
            month += 12;
        }
        year += adj;
    }
    let mut is_leap = false;
    let mut s = year_to_secs(year, &mut is_leap);
    let through = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
    s += (unsafe through[month as usize]) as i64 * 86400;
    if is_leap && month >= 2 {
        s += 86400;
    }
    s += 86400 * (t.tm_mday as i64 - 1);
    s += 3600 * t.tm_hour as i64;
    s += 60 * t.tm_min as i64;
    s += t.tm_sec;
    return s;
}

/// The UTC calendar time of `*t`, in a static `tm`; null with EOVERFLOW when its year overflows an int.
@export("gmtime")
pub fn gmtime(t: *const i64) *mut tm {
    let out = unsafe &mut GM_TM;
    if !secs_to_tm(unsafe *t, out) {
        set_errno(EOVERFLOW);
        return null;
    }
    out.tm_isdst = 0;
    out.gmtoff = 0;
    out.zone = UTC.ptr() as *const char;
    return out;
}

/// The local calendar time of `*t` (UTC: WASI has no time zone), in a static `tm` of its own; null with
/// EOVERFLOW when its year overflows an int.
@export("localtime")
pub fn localtime(t: *const i64) *mut tm {
    let s = unsafe *t;
    if s < INT_MIN as i64 * 31622400 || s > INT_MAX as i64 * 31622400 {
        set_errno(EOVERFLOW);
        return null;
    }
    let out = unsafe &mut LOCAL_TM;
    out.tm_isdst = 0;
    out.gmtoff = 0;
    out.zone = UTC.ptr() as *const char;
    if !secs_to_tm(s, out) {
        set_errno(EOVERFLOW);
        return null;
    }
    return out;
}

/// The seconds since the epoch of local time `*t` (UTC), whose fields it normalizes; -1 with EOVERFLOW
/// when the year overflows an int.
@export("mktime")
pub fn mktime(t: *mut tm) i64 {
    let s = tm_to_secs(unsafe &*t);
    let mut new = tm {
        tm_sec: 0,
        tm_min: 0,
        tm_hour: 0,
        tm_mday: 0,
        tm_mon: 0,
        tm_year: 0,
        tm_wday: 0,
        tm_yday: 0,
        tm_isdst: 0,
        gmtoff: 0,
        zone: UTC.ptr() as *const char,
        nsec: 0,
    };
    if !secs_to_tm(s, &mut new) {
        set_errno(EOVERFLOW);
        return -1;
    }
    unsafe *t = new;
    return s;
}

// musl's `is_leap` of `strftime`: whether year `y` (past 1900) is a leap year.
const fn tm_is_leap(y0: i32) bool {
    let mut y = y0;
    if y > INT_MAX - 1900 {
        y -= 2000;
    }
    y += 1900;
    return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
}

// musl's `week_num`: the ISO 8601 week of `t`.
const fn week_num(t: &tm) i32 {
    let wday = t.tm_wday as u32;
    let yday = t.tm_yday as u32;
    let mut val = (yday.wrapping_add(7).wrapping_sub(wday.wrapping_add(6) % 7) / 7) as i32;
    if wday.wrapping_add(371).wrapping_sub(yday).wrapping_sub(2) % 7 <= 2 {
        val += 1;
    }
    if val == 0 {
        val = 52;
        let dec31 = wday.wrapping_add(7).wrapping_sub(yday).wrapping_sub(1) % 7;
        if dec31 == 4 || dec31 == 5 && tm_is_leap(t.tm_year % 400 - 1) {
            val += 1;
        }
    } else if val == 53 {
        let jan1 = wday.wrapping_add(371).wrapping_sub(yday) % 7;
        if jan1 != 4 && (jan1 != 3 || !tm_is_leap(t.tm_year)) {
            val = 1;
        }
    }
    return val;
}

const DAY_NAMES: [str<'static>; 7] = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTH_NAMES: [str<'static>; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];
const ABDAY_NAMES: [str<'static>; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const ABMON_NAMES: [str<'static>; 12] = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
];

// musl's `__strftime_fmt_1`: conversion `f` of `t` with padding `pad`, its text (in `s` or static) and its
// length in `*l`; null for an unknown conversion or a nested format that did not fit.
fn strftime_one(s: &mut [u8; 100], l: &mut usize, f: u8, t: &tm, pad: u8) *const u8 {
    let mut val: i64 = 0;
    let mut width: i32 = 2;
    let mut def_pad: u8 = 48;
    let mut text: *const u8 = "-".ptr();
    let mut nested: *const u8 = null;
    let mut number = true;
    if f == 97 || f == 65 {
        // a A
        number = false;
        if t.tm_wday as u32 <= 6 {
            text = if f == 97 {
                unsafe ABDAY_NAMES[t.tm_wday as usize].ptr();
            } else {
                unsafe DAY_NAMES[t.tm_wday as usize].ptr();
            };
        }
    } else if f == 104 || f == 98 || f == 66 {
        // h b B
        number = false;
        if t.tm_mon as u32 <= 11 {
            text = if f == 66 {
                unsafe MONTH_NAMES[t.tm_mon as usize].ptr();
            } else {
                unsafe ABMON_NAMES[t.tm_mon as usize].ptr();
            };
        }
    } else if f == 99 {
        nested = "%a %b %e %T %Y".ptr();
    } else if f == 67 {
        val = (1900 + t.tm_year as i64) / 100;
    } else if f == 101 || f == 100 {
        if f == 101 {
            def_pad = 95;
        }
        val = t.tm_mday;
    } else if f == 68 {
        nested = "%m/%d/%y".ptr();
    } else if f == 70 {
        nested = "%Y-%m-%d".ptr();
    } else if f == 103 || f == 71 {
        val = t.tm_year as i64 + 1900;
        if t.tm_yday < 3 && week_num(t) != 1 {
            val -= 1;
        } else if t.tm_yday > 360 && week_num(t) == 1 {
            val += 1;
        }
        if f == 103 {
            val %= 100;
        } else {
            width = 4;
        }
    } else if f == 72 {
        val = t.tm_hour;
    } else if f == 73 {
        val = t.tm_hour;
        if val == 0 {
            val = 12;
        } else if val > 12 {
            val -= 12;
        }
    } else if f == 106 {
        val = t.tm_yday as i64 + 1;
        width = 3;
    } else if f == 109 {
        val = t.tm_mon as i64 + 1;
    } else if f == 77 {
        val = t.tm_min;
    } else if f == 110 {
        *l = 1;
        return "\n".ptr();
    } else if f == 112 {
        number = false;
        text = if t.tm_hour >= 12 {
            "PM".ptr();
        } else {
            "AM".ptr();
        };
    } else if f == 114 {
        nested = "%I:%M:%S %p".ptr();
    } else if f == 82 {
        nested = "%H:%M".ptr();
    } else if f == 115 {
        val = tm_to_secs(t) - t.gmtoff as i64;
        width = 1;
    } else if f == 83 {
        val = t.tm_sec;
    } else if f == 116 {
        *l = 1;
        return "\t".ptr();
    } else if f == 84 {
        nested = "%H:%M:%S".ptr();
    } else if f == 117 {
        val = if t.tm_wday != 0 {
            t.tm_wday;
        } else {
            7i64;
        };
        width = 1;
    } else if f == 85 {
        val = (t.tm_yday as u32).wrapping_add(7).wrapping_sub(t.tm_wday as u32) / 7;
    } else if f == 87 {
        val = (t.tm_yday as u32).wrapping_add(7).wrapping_sub((t.tm_wday as u32).wrapping_add(6) % 7) / 7;
    } else if f == 86 {
        val = week_num(t);
    } else if f == 119 {
        val = t.tm_wday;
        width = 1;
    } else if f == 120 {
        nested = "%m/%d/%y".ptr();
    } else if f == 88 {
        nested = "%H:%M:%S".ptr();
    } else if f == 121 {
        val = (t.tm_year as i64 + 1900) % 100;
        if val < 0 {
            val = 0 - val;
        }
    } else if f == 89 {
        val = t.tm_year as i64 + 1900;
        if val >= 10000 {
            *l = snprintf(((&mut s[0]) as *mut u8) as *mut char, 100, "+%lld".ptr() as *const char, val) as usize;
            return &s[0];
        }
        width = 4;
    } else if f == 122 {
        if t.tm_isdst < 0 {
            *l = 0;
            return "".ptr();
        }
        let off = t.gmtoff / 3600 * 100 + t.gmtoff % 3600 / 60;
        *l = snprintf(((&mut s[0]) as *mut u8) as *mut char, 100, "%+.4d".ptr() as *const char, off) as usize;
        return &s[0];
    } else if f == 90 {
        if t.tm_isdst < 0 {
            *l = 0;
            return "".ptr();
        }
        number = false;
        text = t.zone as *const u8;
    } else if f == 37 {
        *l = 1;
        return "%".ptr();
    } else {
        return null;
    }
    if nested != null {
        *l = strftime_into(&mut s[0], 100, nested, t);
        if *l == 0 {
            return null;
        }
        return &s[0];
    }
    if !number {
        *l = strlen(text as *const char);
        return text;
    }
    let b = ((&mut s[0]) as *mut u8) as *mut char;
    let p = if pad != 0 {
        pad;
    } else {
        def_pad;
    };
    let r = if p == 45 {
        snprintf(b, 100, "%lld".ptr() as *const char, val);
    } else if p == 95 {
        snprintf(b, 100, "%*lld".ptr() as *const char, width, val);
    } else {
        snprintf(b, 100, "%0*lld".ptr() as *const char, width, val);
    };
    *l = r as usize;
    return &s[0];
}

// musl's `__strftime_l`: format `t` by `f` into the `n` bytes at `s`; the length without the NUL, or 0 when
// the text and its NUL do not fit or a conversion is unknown.
fn strftime_into(s: *mut u8, n: usize, f0: *const u8, t: &tm) usize {
    let mut f = f0;
    let mut l: usize = 0;
    let mut buf = [0u8; 100];
    while l < n {
        let c = unsafe f[0];
        if c == 0 {
            unsafe s[l] = 0;
            return l;
        }
        if c != 37 {
            unsafe s[l] = c;
            l += 1;
            f = unsafe (f + 1);
            continue;
        }
        f = unsafe (f + 1);
        let mut pad: u8 = 0;
        if unsafe f[0] == 45 || unsafe f[0] == 95 || unsafe f[0] == 48 {
            pad = unsafe f[0];
            f = unsafe (f + 1);
        }
        let plus = unsafe f[0] == 43;
        if plus {
            f = unsafe (f + 1);
        }
        let mut pe: *mut char = null;
        let mut width = strtoul(f as *const char, &mut pe, 10);
        let p = pe as *const u8;
        let pc = unsafe p[0];
        if pc == 67 || pc == 70 || pc == 71 || pc == 89 {
            if width == 0 && p != f {
                width = 1;
            }
        } else {
            width = 0;
        }
        f = p;
        if unsafe f[0] == 69 || unsafe f[0] == 79 {
            f = unsafe (f + 1);
        }
        let mut k: usize = 0;
        let mut tx = strftime_one(&mut buf, &mut k, unsafe f[0], t, pad);
        if tx == null {
            break;
        }
        if width != 0 {
            // The sign and the leading zeros go, then the digits left decide the '+'.
            if unsafe tx[0] == 43 || unsafe tx[0] == 45 {
                tx = unsafe (tx + 1);
                k -= 1;
            }
            while unsafe tx[0] == 48 && ((unsafe tx[1]) as u32).wrapping_sub(48) < 10 {
                tx = unsafe (tx + 1);
                k -= 1;
            }
            if width < k {
                width = k;
            }
            let mut d: usize = 0;
            while ((unsafe tx[d]) as u32).wrapping_sub(48) < 10 {
                d += 1;
            }
            let lim: usize = if pc == 67 {
                3;
            } else {
                5;
            };
            if t.tm_year < -1900 {
                unsafe s[l] = 45;
                l += 1;
                width -= 1;
            } else if plus && d + (width - k) >= lim {
                unsafe s[l] = 43;
                l += 1;
                width -= 1;
            }
            while width > k && l < n {
                unsafe s[l] = 48;
                l += 1;
                width -= 1;
            }
        }
        if k > n - l {
            k = n - l;
        }
        copy(unsafe (s + l), tx, k);
        l += k;
        f = unsafe (f + 1);
    }
    if n != 0 {
        if l == n {
            l = n - 1;
        }
        unsafe s[l] = 0;
    }
    return 0;
}

/// Format `t` by `f` into the `n` bytes at `s`, as C's `strftime` in the C locale; the length without the
/// NUL, or 0 when it does not fit.
@export("strftime")
pub fn strftime(s: *mut char, n: usize, f: *const char, t: *const tm) usize {
    return strftime_into(s as *mut u8, n, f as *const u8, unsafe &*t);
}

// ---- paths ---------------------------------------------------------------------------------------------
//
// WASI opens paths relative to a directory descriptor: the directories the host preopened (`--dir`), each
// under the path it was given. A path resolves against the working directory (a string: WASI has none),
// then against the preopen whose path is its longest prefix (wasi-libc's `__wasilibc_find_abspath`).

struct Preopen {
    pub prefix: *mut u8,
    pub len: usize,
    pub fd: i32,
}

static mut PRE: *mut Preopen = null;
static mut PRE_LEN: usize = 0;
static mut PRE_DONE: bool = false;
// The working directory: "/" until `chdir`; owned (`CWD_OWN`) after one.
static mut CWD: *mut u8 = null;
static mut CWD_OWN: bool = false;
// The absolute form of the last path resolved, grown geometrically.
static mut ABS_BUF: *mut u8 = null;
static mut ABS_CAP: usize = 0;

// Read the preopened directories once: descriptors 3 up until the first that is not one.
fn preopens_init() {
    if unsafe PRE_DONE {
        return;
    }
    unsafe PRE_DONE = true;
    let mut cap: usize = 0;
    let mut fd: i32 = 3;
    // A process has fewer than 2^31 descriptors: the loop ends at the first one WASI reports bad.
    while fd > 0 {
        let mut ps = PreStat { tag: 0, name_len: 0 };
        let e = unsafe sc_wasi_fd_prestat_get(fd, &mut ps);
        if e == EBADF as u16 {
            break;
        }
        if e != 0 {
            exit_now(71);
        }
        if ps.tag == 0 {
            let nl = ps.name_len as usize;
            let name = heap_alloc(nl + 1) as *mut u8;
            if name == null {
                exit_now(70);
            }
            if unsafe sc_wasi_fd_prestat_dir_name(fd, name, nl) != 0 {
                exit_now(71);
            }
            unsafe name[nl] = 0;
            // Strip the leading "/" and "./" parts, as wasi-libc does.
            let mut k: usize = 0;
            loop {
                if unsafe name[k] == 47 {
                    k += 1;
                } else if unsafe name[k] == 46 && unsafe name[k + 1] == 47 {
                    k += 2;
                } else if unsafe name[k] == 46 && unsafe name[k + 1] == 0 {
                    k += 1;
                } else {
                    break;
                }
            }
            if unsafe PRE_LEN == cap {
                let ncap = if cap == 0 {
                    4usize;
                } else {
                    cap * 2;
                };
                let np = heap_alloc(ncap * sizeof(Preopen)) as *mut Preopen;
                if np == null {
                    exit_now(70);
                }
                for i in 0..unsafe PRE_LEN {
                    unsafe np[i] = unsafe PRE[i];
                }
                heap_free(unsafe PRE);
                unsafe PRE = np;
                cap = ncap;
            }
            unsafe PRE[PRE_LEN] = Preopen { prefix: unsafe (name + k), len: nl - k, fd: fd };
            unsafe PRE_LEN += 1;
        }
        fd += 1;
    }
}

// Whether preopen prefix `pre` (`pl` bytes) is a path prefix of `path` (no leading "/").
const fn prefix_matches(pre: *const u8, pl: usize, path: *const u8) bool {
    if unsafe path[0] != 47 && pl == 0 {
        return true;
    }
    for i in 0..pl {
        if unsafe path[i] != unsafe pre[i] {
            return false;
        }
    }
    let mut i = pl;
    while i > 0 && unsafe pre[i - 1] == 47 {
        i -= 1;
    }
    let last = unsafe path[i];
    return last == 47 || last == 0;
}

// `path` made absolute against the working directory: `path` itself when absolute, else `ABS_BUF`; null
// when no memory is left.
fn make_absolute(path: *const u8) *const u8 {
    if unsafe path[0] == 47 {
        return path;
    }
    let cwd = if unsafe CWD == null {
        "/".ptr();
    } else {
        (unsafe CWD) as *const u8;
    };
    let mut p = path;
    if unsafe p[0] == 0 || unsafe p[0] == 46 && unsafe p[1] == 0 || unsafe p[0] == 46 && unsafe p[1] == 47 && unsafe p[2] == 0 {
        return cwd;
    }
    if unsafe p[0] == 46 && unsafe p[1] == 47 {
        p = unsafe (p + 2);
    }
    let cl = strlen(cwd as *const char);
    let pl = strlen(p as *const char);
    let slash = if unsafe cwd[cl - 1] == 47 {
        0usize;
    } else {
        1usize;
    };
    let need = cl + slash + pl + 1;
    if need > unsafe ABS_CAP {
        let mut cap = if unsafe ABS_CAP == 0 {
            256usize;
        } else {
            unsafe ABS_CAP;
        };
        while cap < need {
            cap *= 2;
        }
        let nb = heap_alloc(cap) as *mut u8;
        if nb == null {
            return null;
        }
        heap_free(unsafe ABS_BUF);
        unsafe ABS_BUF = nb;
        unsafe ABS_CAP = cap;
    }
    let b = unsafe ABS_BUF;
    copy(b, cwd, cl);
    if slash == 1 {
        unsafe b[cl] = 47;
    }
    copy(unsafe (b + (cl + slash)), p, pl + 1);
    return b;
}

// The preopen descriptor that `path` resolves under, with the path relative to it in `*rel` ("." for the
// preopen itself) and the preopen's prefix in `*pre`; -1 with errno when none or out of memory.
fn find_rel(path: *const char, rel: &mut *const u8, pre: &mut *const u8) i32 {
    preopens_init();
    let abs0 = make_absolute(path as *const u8);
    if abs0 == null {
        set_errno(ENOMEM);
        return -1;
    }
    let mut abs = abs0;
    while unsafe abs[0] == 47 {
        abs = unsafe (abs + 1);
    }
    let mut fd: i32 = -1;
    let mut mlen: usize = 0;
    let mut i = unsafe PRE_LEN;
    while i > 0 {
        i -= 1;
        let pr = unsafe PRE[i];
        if (fd == -1 || pr.len > mlen) && prefix_matches(pr.prefix, pr.len, abs) {
            fd = pr.fd;
            mlen = pr.len;
            *pre = pr.prefix;
        }
    }
    if fd == -1 {
        set_errno(ENOENT);
        return -1;
    }
    let mut r = unsafe (abs + mlen);
    while unsafe r[0] == 47 {
        r = unsafe (r + 1);
    }
    if unsafe r[0] == 0 {
        r = ".".ptr();
    }
    *rel = r;
    return fd;
}

// `find_rel` for a path that only needs the descriptor and the relative path; ENOENT when it fails, as
// wasi-libc reports.
fn resolve(path: *const char, rel: &mut *const u8) i32 {
    let mut pre: *const u8 = null;
    let fd = find_rel(path, rel, &mut pre);
    if fd == -1 {
        set_errno(ENOENT);
    }
    return fd;
}

// A copy of `p` (NUL-terminated) on the heap, or null: the second path of a two-path call, which a
// second resolution would overwrite.
fn dup_path(p: *const u8) *mut u8 {
    let n = strlen(p as *const char);
    let d = heap_alloc(n + 1) as *mut u8;
    if d != null {
        copy(d, p, n + 1);
    }
    return d;
}

/// The working directory into `buf` (`size` bytes), or a `malloc` copy when `buf` is null; null with ERANGE
/// when it does not fit.
@export("getcwd")
pub fn getcwd(buf: *mut char, size: usize) *mut char {
    let cwd = if unsafe CWD == null {
        "/".ptr();
    } else {
        (unsafe CWD) as *const u8;
    };
    if buf == null {
        let d = strdup(cwd as *const char);
        if d == null {
            set_errno(ENOMEM);
        }
        return d;
    }
    let n = strlen(cwd as *const char);
    if size < n + 1 {
        set_errno(ERANGE);
        return null;
    }
    copy(buf as *mut u8, cwd, n + 1);
    return buf;
}

/// Change the working directory to `path`, which must be a directory; 0, or -1 with errno.
@export("chdir")
pub fn chdir(path: *const char) i32 {
    let mut rel: *const u8 = null;
    let mut pre: *const u8 = null;
    let fd = find_rel(path, &mut rel, &mut pre);
    if fd == -1 {
        return -1;
    }
    let mut fs = zero_filestat();
    let e = unsafe sc_wasi_path_filestat_get(
        fd,
        LOOKUP_SYMLINK_FOLLOW,
        rel as *const char,
        strlen(rel as *const char),
        &mut fs,
    );
    if e != 0 {
        return fail(e);
    }
    if fs.filetype != FILETYPE_DIRECTORY {
        set_errno(ENOTDIR);
        return -1;
    }
    let pl = strlen(pre as *const char);
    let copy_rel = !(unsafe rel[0] == 46 && unsafe rel[1] == 0);
    let mid = copy_rel && pl != 0;
    let rl = if copy_rel {
        strlen(rel as *const char);
    } else {
        0usize;
    };
    let n = 1 + pl + mid as usize + rl;
    let c = heap_alloc(n + 1) as *mut u8;
    if c == null {
        set_errno(ENOMEM);
        return -1;
    }
    unsafe c[0] = 47;
    copy(unsafe (c + 1), pre, pl);
    if mid {
        unsafe c[1 + pl] = 47;
    }
    copy(unsafe (c + (1 + pl + mid as usize)), rel, rl);
    unsafe c[n] = 0;
    if unsafe CWD_OWN {
        heap_free(unsafe CWD);
    }
    unsafe CWD = c;
    unsafe CWD_OWN = true;
    return 0;
}

// ---- files ---------------------------------------------------------------------------------------------

// The `<fcntl.h>`, `<sys/stat.h>` and `<dirent.h>` values of wasi-libc.
const O_APPEND: i32 = 1;
const O_NONBLOCK: i32 = 4;
const O_CREAT: i32 = 1 << 12;
const O_DIRECTORY: i32 = 2 << 12;
const O_EXCL: i32 = 4 << 12;
const O_TRUNC: i32 = 8 << 12;
const O_NOFOLLOW: i32 = 0x01000000;
const O_EXEC: i32 = 0x02000000;
const O_RDONLY: i32 = 0x04000000;
const O_SEARCH: i32 = 0x08000000;
const O_WRONLY: i32 = 0x10000000;
const O_RDWR: i32 = O_RDONLY | O_WRONLY;
const O_ACCMODE: i32 = O_EXEC | O_RDWR | O_SEARCH;
const AT_SYMLINK_NOFOLLOW: i32 = 1;
const AT_SYMLINK_FOLLOW: i32 = 2;
const S_IFMT: u32 = 0xf000;
const S_IFBLK: u32 = 0x6000;
const S_IFCHR: u32 = 0x2000;
const S_IFDIR: u32 = 0x4000;
const S_IFLNK: u32 = 0xa000;
const S_IFREG: u32 = 0x8000;
const S_IFSOCK: u32 = 0xc000;

extern "C" "sys/stat.h" {
    pub struct stat {
        pub st_dev: u64,
        pub st_ino: u64,
        pub st_nlink: u64,
        pub st_mode: u32,
        pub st_uid: u32,
        pub st_gid: u32,
        pub __pad0: u32,
        pub st_rdev: u64,
        pub st_size: i64,
        pub st_blksize: isize,
        pub st_blocks: i64,
        pub st_atim: timespec,
        pub st_mtim: timespec,
        pub st_ctim: timespec,
        pub __reserved: [i64; 3],
    }
}

const fn zero_filestat() FileStat {
    return FileStat { dev: 0, ino: 0, filetype: 0, nlink: 0, size: 0, atim: 0, mtim: 0, ctim: 0 };
}

const fn ts_of(t: u64) timespec {
    return timespec { tv_sec: (t / 1000000000) as i64, tv_nsec: (t % 1000000000) as isize };
}

// cloudlibc's `to_public_stat`.
const fn put_stat(fs: &FileStat, out: *mut stat) {
    let mode = if fs.filetype == 1 {
        S_IFBLK;
    } else if fs.filetype == 2 {
        S_IFCHR;
    } else if fs.filetype == 3 {
        S_IFDIR;
    } else if fs.filetype == 4 {
        S_IFREG;
    } else if fs.filetype == 5 || fs.filetype == 6 {
        S_IFSOCK;
    } else if fs.filetype == 7 {
        S_IFLNK;
    } else {
        0u32;
    };
    unsafe *out = stat {
        st_dev: fs.dev,
        st_ino: fs.ino,
        st_nlink: fs.nlink,
        st_mode: mode,
        st_uid: 0,
        st_gid: 0,
        __pad0: 0,
        st_rdev: 0,
        st_size: fs.size as i64,
        st_blksize: 0,
        st_blocks: 0,
        st_atim: ts_of(fs.atim),
        st_mtim: ts_of(fs.mtim),
        st_ctim: ts_of(fs.ctim),
        __reserved: [0i64; 3],
    };
}

// cloudlibc's `openat` without a mode: the rights the access mode asks, within what the directory passes on.
fn open_at(dirfd: i32, path: *const u8, oflag: i32) i32 {
    let mut max = ~(RIGHTS_FD_DATASYNC | RIGHTS_FD_READ | RIGHTS_FD_WRITE | RIGHTS_FD_ALLOCATE | RIGHTS_FD_READDIR | RIGHTS_FD_FILESTAT_SET_SIZE);
    let acc = oflag & O_ACCMODE;
    if acc == O_RDONLY || acc == O_WRONLY || acc == O_RDWR {
        if (oflag & O_RDONLY) != 0 {
            max |= RIGHTS_FD_READ | RIGHTS_FD_READDIR;
        }
        if (oflag & O_WRONLY) != 0 {
            max |= RIGHTS_FD_DATASYNC | RIGHTS_FD_WRITE | RIGHTS_FD_ALLOCATE | RIGHTS_FD_FILESTAT_SET_SIZE;
        }
    } else if acc != O_EXEC && acc != O_SEARCH {
        set_errno(EINVAL);
        return -1;
    }
    let mut st = FdStat { filetype: 0, flags: 0, rights_base: 0, rights_inheriting: 0 };
    let e = unsafe sc_wasi_fd_fdstat_get(dirfd, &mut st);
    if e != 0 {
        return fail(e);
    }
    let lookup = if (oflag & O_NOFOLLOW) == 0 {
        LOOKUP_SYMLINK_FOLLOW;
    } else {
        0u32;
    };
    let mut fd: i32 = -1;
    let e2 = unsafe sc_wasi_path_open(
        dirfd,
        lookup,
        path as *const char,
        strlen(path as *const char),
        (oflag >> 12 & 0xfff) as u16,
        max & st.rights_inheriting,
        st.rights_inheriting,
        (oflag & 0xfff) as u16,
        &mut fd,
    );
    if e2 != 0 {
        return fail(e2);
    }
    return fd;
}

/// Open `path` with `oflag` (`O_*`); a descriptor, or -1 with errno. WASI has no permission bits: the
/// mode argument is ignored.
@export("open")
pub fn open(path: *const char, oflag: i32, ...) i32 {
    let mut rel: *const u8 = null;
    let dirfd = resolve(path, &mut rel);
    if dirfd == -1 {
        return -1;
    }
    return open_at(dirfd, rel, oflag);
}

/// Create `path`, or truncate it, for writing: `open` with `O_WRONLY | O_CREAT | O_TRUNC`.
@export("creat")
pub fn creat(path: *const char, mode: u32) i32 {
    return open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
}

/// Close descriptor `fd`; 0, or -1 with errno.
@export("close")
pub fn close(fd: i32) i32 {
    let e = unsafe sc_wasi_fd_close(fd);
    if e != 0 {
        return fail(e);
    }
    return 0;
}

/// Read up to `n` bytes; the count, 0 at end of file, or -1 with errno.
@export("read")
pub fn read(fd: i32, buf: *mut void, n: usize) isize {
    let iov = IoVec { buf: buf as *const u8, len: n };
    let mut got: usize = 0;
    let e = unsafe sc_wasi_fd_read(fd, &iov, 1, &mut got);
    if e != 0 {
        set_errno(
            if e == ENOTCAPABLE as u16 {
                EBADF;
            } else {
                e;
            },
        );
        return -1;
    }
    return got as isize;
}

/// Write up to `n` bytes; the count, or -1 with errno.
@export("write")
pub fn write(fd: i32, buf: *const void, n: usize) isize {
    let iov = IoVec { buf: buf as *const u8, len: n };
    let mut put: usize = 0;
    let e = unsafe sc_wasi_fd_write(fd, &iov, 1, &mut put);
    if e != 0 {
        set_errno(
            if e == ENOTCAPABLE as u16 {
                EBADF;
            } else {
                e;
            },
        );
        return -1;
    }
    return put as isize;
}

/// Move the offset of `fd`; the new offset, or -1 with errno (ESPIPE where it cannot seek).
@export("lseek")
pub fn lseek(fd: i32, offset: i64, whence: i32) i64 {
    return seek(fd, offset, whence);
}

/// The offset of `fd`, or -1 with errno: the header's `lseek` macro calls it for `lseek(fd, 0, SEEK_CUR)`
/// with constant arguments.
@export("__wasilibc_tell")
pub fn wasilibc_tell(fd: i32) i64 {
    return seek(fd, 0, 1);
}

// `lseek`, under a name no header macro rewrites.
fn seek(fd: i32, offset: i64, whence: i32) i64 {
    let mut at: u64 = 0;
    let e = unsafe sc_wasi_fd_seek(fd, offset, whence as u8, &mut at);
    if e != 0 {
        set_errno(
            if e == ENOTCAPABLE as u16 {
                ESPIPE;
            } else {
                e;
            },
        );
        return -1;
    }
    return at as i64;
}

/// Flush `fd` to storage; 0, or -1 with errno.
@export("fsync")
pub fn fsync(fd: i32) i32 {
    let e = unsafe sc_wasi_fd_sync(fd);
    if e != 0 {
        set_errno(
            if e == ENOTCAPABLE as u16 {
                EINVAL;
            } else {
                e;
            },
        );
        return -1;
    }
    return 0;
}

/// Whether `fd` is a terminal: a character device that cannot seek.
@export("isatty")
pub fn isatty(fd: i32) i32 {
    let mut st = FdStat { filetype: 0, flags: 0, rights_base: 0, rights_inheriting: 0 };
    let e = unsafe sc_wasi_fd_fdstat_get(fd, &mut st);
    if e != 0 {
        set_errno(e);
        return 0;
    }
    if st.filetype != FILETYPE_CHARACTER_DEVICE || (st.rights_base & (RIGHTS_FD_SEEK | RIGHTS_FD_TELL)) != 0 {
        set_errno(ENOTTY);
        return 0;
    }
    return 1;
}

/// The status flags (F_GETFL, 3) or set them (F_SETFL, 4); F_GETFD answers FD_CLOEXEC and F_SETFD
/// succeeds, as WASI has no exec.
@export("fcntl")
pub fn fcntl(fd: i32, cmd: i32, ...) i32 {
    if cmd == 1 {
        return 1;
    }
    if cmd == 2 {
        return 0;
    }
    if cmd == 3 {
        let mut st = FdStat { filetype: 0, flags: 0, rights_base: 0, rights_inheriting: 0 };
        let e = unsafe sc_wasi_fd_fdstat_get(fd, &mut st);
        if e != 0 {
            return fail(e);
        }
        let mut fl = st.flags as i32;
        if (st.rights_base & (RIGHTS_FD_READ | RIGHTS_FD_READDIR)) != 0 {
            fl |= if (st.rights_base & RIGHTS_FD_WRITE) != 0 {
                O_RDWR;
            } else {
                O_RDONLY;
            };
        } else if (st.rights_base & RIGHTS_FD_WRITE) != 0 {
            fl |= O_WRONLY;
        } else {
            fl |= O_SEARCH;
        }
        return fl;
    }
    if cmd == 4 {
        let ap: va_list;
        va_start(ap, cmd);
        let flags = unsafe va_arg(ap, i32);
        va_end(ap);
        let e = unsafe sc_wasi_fd_fdstat_set_flags(fd, (flags & 0xfff) as u16);
        if e != 0 {
            return fail(e);
        }
        return 0;
    }
    set_errno(EINVAL);
    return -1;
}

// `stat` and `lstat` over the resolved path.
fn stat_at(path: *const char, out: *mut stat, follow: bool) i32 {
    let mut rel: *const u8 = null;
    let dirfd = resolve(path, &mut rel);
    if dirfd == -1 {
        return -1;
    }
    let mut fs = zero_filestat();
    let e = unsafe sc_wasi_path_filestat_get(
        dirfd,
        if follow {
            LOOKUP_SYMLINK_FOLLOW;
        } else {
            0u32;
        },
        rel as *const char,
        strlen(rel as *const char),
        &mut fs,
    );
    if e != 0 {
        return fail(e);
    }
    put_stat(&fs, out);
    return 0;
}

/// The status of `path`, following a symbolic link; 0, or -1 with errno.
@export("stat")
pub fn c_stat(path: *const char, out: *mut stat) i32 {
    return stat_at(path, out, true);
}

/// The status of `path` itself, a symbolic link included.
@export("lstat")
pub fn lstat(path: *const char, out: *mut stat) i32 {
    return stat_at(path, out, false);
}

/// The status of descriptor `fd`.
@export("fstat")
pub fn fstat(fd: i32, out: *mut stat) i32 {
    let mut fs = zero_filestat();
    let e = unsafe sc_wasi_fd_filestat_get(fd, &mut fs);
    if e != 0 {
        return fail(e);
    }
    put_stat(&fs, out);
    return 0;
}

/// Make directory `path` (WASI has no permission bits: `mode` is ignored); 0, or -1 with errno.
@export("mkdir")
pub fn mkdir(path: *const char, _mode: u32) i32 {
    let mut rel: *const u8 = null;
    let dirfd = resolve(path, &mut rel);
    if dirfd == -1 {
        return -1;
    }
    let e = unsafe sc_wasi_path_create_directory(dirfd, rel as *const char, strlen(rel as *const char));
    if e != 0 {
        return fail(e);
    }
    return 0;
}

/// Remove empty directory `path`.
@export("rmdir")
pub fn rmdir(path: *const char) i32 {
    let mut rel: *const u8 = null;
    let dirfd = resolve(path, &mut rel);
    if dirfd == -1 {
        return -1;
    }
    let e = unsafe sc_wasi_path_remove_directory(dirfd, rel as *const char, strlen(rel as *const char));
    if e != 0 {
        return fail(e);
    }
    return 0;
}

/// Remove file `path`.
@export("unlink")
pub fn unlink(path: *const char) i32 {
    let mut rel: *const u8 = null;
    let dirfd = resolve(path, &mut rel);
    if dirfd == -1 {
        return -1;
    }
    let e = unsafe sc_wasi_path_unlink_file(dirfd, rel as *const char, strlen(rel as *const char));
    if e != 0 {
        return fail(e);
    }
    return 0;
}

/// Remove file or empty directory `path`.
@export("remove")
pub fn remove(path: *const char) i32 {
    let mut rel: *const u8 = null;
    let dirfd = resolve(path, &mut rel);
    if dirfd == -1 {
        return -1;
    }
    let rl = strlen(rel as *const char);
    let e = unsafe sc_wasi_path_unlink_file(dirfd, rel as *const char, rl);
    if e == 0 {
        return 0;
    }
    if e != EISDIR as u16 && e != ENOENT as u16 {
        return fail(e);
    }
    let e2 = unsafe sc_wasi_path_remove_directory(dirfd, rel as *const char, rl);
    if e2 != 0 {
        return fail(
            if e2 == ENOTDIR as u16 {
                ENOENT as u16;
            } else {
                e2;
            },
        );
    }
    return 0;
}

// The two resolutions of a two-path call: the first relative path copied, as the second overwrites the
// shared buffer. -1 with ENOENT when either fails.
fn resolve2(a: *const char, b: *const char, fa: &mut i32, ra: &mut *mut u8, fb: &mut i32, rb: &mut *const u8) bool {
    let mut r: *const u8 = null;
    *fa = resolve(a, &mut r);
    if *fa == -1 {
        return false;
    }
    *ra = dup_path(r);
    if *ra == null {
        set_errno(ENOMEM);
        return false;
    }
    *fb = resolve(b, rb);
    if *fb == -1 {
        heap_free(*ra);
        return false;
    }
    return true;
}

/// Rename `from` to `to`, replacing `to`; 0, or -1 with errno.
@export("rename")
pub fn rename(from: *const char, to: *const char) i32 {
    let mut fa: i32 = -1;
    let mut fb: i32 = -1;
    let mut ra: *mut u8 = null;
    let mut rb: *const u8 = null;
    if !resolve2(from, to, &mut fa, &mut ra, &mut fb, &mut rb) {
        return -1;
    }
    let e = unsafe sc_wasi_path_rename(
        fa,
        ra as *const char,
        strlen(ra as *const char),
        fb,
        rb as *const char,
        strlen(rb as *const char),
    );
    heap_free(ra);
    if e != 0 {
        return fail(e);
    }
    return 0;
}

/// Make `to` a hard link to `from`.
@export("link")
pub fn link(from: *const char, to: *const char) i32 {
    let mut fa: i32 = -1;
    let mut fb: i32 = -1;
    let mut ra: *mut u8 = null;
    let mut rb: *const u8 = null;
    if !resolve2(from, to, &mut fa, &mut ra, &mut fb, &mut rb) {
        return -1;
    }
    let e = unsafe sc_wasi_path_link(
        fa,
        0,
        ra as *const char,
        strlen(ra as *const char),
        fb,
        rb as *const char,
        strlen(rb as *const char),
    );
    heap_free(ra);
    if e != 0 {
        return fail(e);
    }
    return 0;
}

/// Make `link` a symbolic link that holds `target`.
@export("symlink")
pub fn symlink(target: *const char, link: *const char) i32 {
    let mut rel: *const u8 = null;
    let dirfd = resolve(link, &mut rel);
    if dirfd == -1 {
        return -1;
    }
    let e = unsafe sc_wasi_path_symlink(target, strlen(target), dirfd, rel as *const char, strlen(rel as *const char));
    if e != 0 {
        return fail(e);
    }
    return 0;
}

/// WASI has no permission bits: -1 with ENOSYS, as wasi-libc answers.
@export("chmod")
pub fn chmod(_path: *const char, _mode: u32) i32 {
    set_errno(ENOSYS);
    return -1;
}

/// Whether `path` exists (`mode` F_OK, 0) or grants the R_OK, W_OK, X_OK bits it asks: WASI checks
/// rights per descriptor, so an existing path passes.
@export("access")
pub fn access(path: *const char, _mode: i32) i32 {
    let mut st = stat {
        st_dev: 0,
        st_ino: 0,
        st_nlink: 0,
        st_mode: 0,
        st_uid: 0,
        st_gid: 0,
        __pad0: 0,
        st_rdev: 0,
        st_size: 0,
        st_blksize: 0,
        st_blocks: 0,
        st_atim: timespec { tv_sec: 0, tv_nsec: 0 },
        st_mtim: timespec { tv_sec: 0, tv_nsec: 0 },
        st_ctim: timespec { tv_sec: 0, tv_nsec: 0 },
        __reserved: [0i64; 3],
    };
    return stat_at(path, &mut st, true);
}

// cloudlibc's `utimens_get_timestamps`: the times and the WASI flags; false for an invalid time.
const fn utime_args(times: *const timespec, at: &mut u64, mt: &mut u64, fl: &mut u16) bool {
    if times == null {
        *fl = 2 | 8;
        *at = 0;
        *mt = 0;
        return true;
    }
    *fl = 0;
    for k in 0..2 {
        let t = unsafe times[k];
        let mut v: u64 = 0;
        if t.tv_nsec == -1 {
            *fl |= if k == 0 {
                2u16;
            } else {
                8u16;
            };
        } else if t.tv_nsec != -2 {
            if t.tv_sec < 0 || t.tv_nsec < 0 || t.tv_nsec >= 1000000000 || t.tv_sec as u64 > 18446744072 {
                return false;
            }
            *fl |= if k == 0 {
                1u16;
            } else {
                4u16;
            };
            v = t.tv_sec as u64 * 1000000000 + t.tv_nsec as u64;
        }
        if k == 0 {
            *at = v;
        } else {
            *mt = v;
        }
    }
    return true;
}

/// Set the access and modification times of `path` (`dirfd` must be AT_FDCWD); 0, or -1 with errno.
@export("utimensat")
pub fn utimensat(_dirfd: i32, path: *const char, times: *const timespec, flag: i32) i32 {
    let mut at: u64 = 0;
    let mut mt: u64 = 0;
    let mut fl: u16 = 0;
    if !utime_args(times, &mut at, &mut mt, &mut fl) {
        set_errno(EINVAL);
        return -1;
    }
    let mut rel: *const u8 = null;
    let dirfd = resolve(path, &mut rel);
    if dirfd == -1 {
        return -1;
    }
    let lookup = if (flag & AT_SYMLINK_NOFOLLOW) == 0 {
        LOOKUP_SYMLINK_FOLLOW;
    } else {
        0u32;
    };
    let e = unsafe sc_wasi_path_filestat_set_times(
        dirfd,
        lookup,
        rel as *const char,
        strlen(rel as *const char),
        at,
        mt,
        fl,
    );
    if e != 0 {
        return fail(e);
    }
    return 0;
}

/// The target of symbolic link `path` into `buf` (not NUL-terminated); its length, or -1 with errno.
@export("readlink")
pub fn readlink(path: *const char, buf: *mut char, cap: usize) isize {
    let mut rel: *const u8 = null;
    let dirfd = resolve(path, &mut rel);
    if dirfd == -1 {
        return -1;
    }
    let mut n: usize = 0;
    let e = unsafe sc_wasi_path_readlink(
        dirfd,
        rel as *const char,
        strlen(rel as *const char),
        buf as *mut u8,
        cap,
        &mut n,
    );
    if e != 0 {
        set_errno(e);
        return -1;
    }
    return n as isize;
}

// The count of slashes at `s`.
const fn slash_len(s: *const u8) usize {
    let mut i: usize = 0;
    while unsafe s[i] == 47 {
        i += 1;
    }
    return i;
}

/// musl's `realpath`: `path` absolute, with `.`, `..` and symbolic links resolved, into `out` (PATH_MAX,
/// 4096 bytes) or a `malloc` copy when `out` is null; null with errno.
@export("realpath")
pub fn realpath(path: *const char, out: *mut char) *mut char {
    if path == null {
        set_errno(EINVAL);
        return null;
    }
    // The components still to resolve sit at the end of `stack`; `output` holds the resolved prefix.
    let mut stack = [0u8; 4097];
    let mut output = [0u8; 4096];
    let len = strnlen(path, 4097);
    if len == 0 {
        set_errno(ENOENT);
        return null;
    }
    if len >= 4096 {
        set_errno(ENAMETOOLONG);
        return null;
    }
    let mut p = 4097 - len - 1;
    let mut q: usize = 0;
    let mut cnt: usize = 0;
    let mut nup: usize = 0;
    let mut check_dir = false;
    copy(unsafe &mut stack[p], path as *const u8, len + 1);
    // Each pass moves one component to `output`, or replaces a link by its target (at most 40 links, as
    // SYMLOOP_MAX allows); the slashes after a component go with it.
    loop {
        if unsafe stack[p] == 47 {
            // A path starting with '/' resets the output; an initial "//" (and no third '/') stays.
            check_dir = false;
            nup = 0;
            q = 0;
            unsafe output[q] = 47;
            q += 1;
            p += 1;
            if unsafe stack[p] == 47 && unsafe stack[p + 1] != 47 {
                unsafe output[q] = 47;
                q += 1;
            }
            p += slash_len(unsafe &stack[p]);
            continue;
        }
        let l0 = chrnul(unsafe &stack[p], 47) as usize - (unsafe &stack[p]) as usize;
        let mut l = l0;
        if l == 0 && !check_dir {
            break;
        }
        if l == 1 && unsafe stack[p] == 46 {
            p += l;
            p += slash_len(unsafe &stack[p]);
            continue;
        }
        // The component goes onto the output at once, for readlink, but the output grows past it only
        // once it is known not to be a link.
        if q != 0 && unsafe output[q - 1] != 47 {
            if p == 0 {
                set_errno(ENAMETOOLONG);
                return null;
            }
            p -= 1;
            unsafe stack[p] = 47;
            l += 1;
        }
        if q + l >= 4096 {
            set_errno(ENAMETOOLONG);
            return null;
        }
        copy(unsafe &mut output[q], unsafe &stack[p], l);
        unsafe output[q + l] = 0;
        p += l;
        let mut up = false;
        let mut link = true;
        if l0 == 2 && unsafe stack[p - 2] == 46 && unsafe stack[p - 1] == 46 {
            up = true;
            // ".." cancels a known component; with none, it is kept for the working directory.
            if q <= 3 * nup {
                nup += 1;
                q += l;
                p += slash_len(unsafe &stack[p]);
                continue;
            }
            // Components already known to be directories need no readlink for "..".
            if !check_dir {
                link = false;
            }
        }
        if link {
            let k = readlink(((&output[0]) as *const u8) as *const char, ((&mut stack[0]) as *mut u8) as *mut char, p);
            if k == p as isize {
                set_errno(ENAMETOOLONG);
                return null;
            }
            if k == 0 {
                set_errno(ENOENT);
                return null;
            }
            if k > 0 {
                cnt += 1;
                if cnt == 40 {
                    set_errno(ELOOP);
                    return null;
                }
                let ku = k as usize;
                // Link contents ending in '/' drop the slashes already on the stack.
                if unsafe stack[ku - 1] == 47 {
                    p += slash_len(unsafe &stack[p]);
                }
                p -= ku;
                let _ = memmove((unsafe &mut stack[p]) as *mut u8, (&stack[0]) as *const u8, ku);
                continue;
            }
            if unsafe ERRNO != EINVAL {
                return null;
            }
        }
        check_dir = false;
        if up {
            while q != 0 && unsafe output[q - 1] != 47 {
                q -= 1;
            }
            if q > 1 && (q > 2 || output[0] != 47) {
                q -= 1;
            }
            p += slash_len(unsafe &stack[p]);
            continue;
        }
        if l0 != 0 {
            q += l;
        }
        check_dir = unsafe stack[p] != 0;
        p += slash_len(unsafe &stack[p]);
    }
    unsafe output[q] = 0;
    if output[0] != 47 {
        if getcwd(((&mut stack[0]) as *mut u8) as *mut char, 4097) == null {
            return null;
        }
        let mut l = strlen(((&stack[0]) as *const u8) as *const char);
        // Cancel the initial ".." components against the working directory.
        let mut pp: usize = 0;
        while nup > 0 {
            nup -= 1;
            while l > 1 && unsafe stack[l - 1] != 47 {
                l -= 1;
            }
            if l > 1 {
                l -= 1;
            }
            pp += 2;
            if pp < q {
                pp += 1;
            }
        }
        if q - pp != 0 && unsafe stack[l - 1] != 47 {
            unsafe stack[l] = 47;
            l += 1;
        }
        if l + (q - pp) + 1 >= 4096 {
            set_errno(ENAMETOOLONG);
            return null;
        }
        let _ = memmove((unsafe &mut output[l]) as *mut u8, (unsafe &output[pp]) as *const u8, q - pp + 1);
        copy(&mut output[0], &stack[0], l);
        q = l + q - pp;
    }
    if out != null {
        copy(out as *mut u8, &output[0], q + 1);
        return out;
    }
    return strdup(((&output[0]) as *const u8) as *const char);
}

// ---- directories ---------------------------------------------------------------------------------------

extern "C" "dirent.h" {
    pub type DIR;
    @import("struct dirent")
    @layout(16, 8)
    pub type dirent;
}

// cloudlibc's `struct _DIR`: the descriptor, the cookie of the next entry, the buffer of raw WASI entries,
// and the `struct dirent` the last `readdir` returned (its name after the 9 bytes `d_ino` and `d_type`).
struct Dir {
    pub fd: i32,
    pub cookie: u64,
    pub buf: *mut u8,
    pub done: usize,
    pub size: usize,
    pub used: usize,
    pub ent: *mut u8,
    pub ent_size: usize,
}

const DIRENT_BUF: usize = 4096;
// `__wasi_dirent_t`: d_next u64, d_ino u64, d_namlen u32, d_type u8; 24 bytes.
const WDIRENT: usize = 24;

// `buf` grown to at least `want` bytes (doubling), or null with the old buffer kept.
fn grow_buf(buf: &mut *mut u8, size: &mut usize, want: usize) bool {
    if *size >= want {
        return true;
    }
    let mut n = *size;
    while n < want {
        n *= 2;
    }
    let nb = realloc(*buf, n) as *mut u8;
    if nb == null {
        return false;
    }
    *buf = nb;
    *size = n;
    return true;
}

/// Open directory `path` for `readdir`; null with errno.
@export("opendir")
pub fn opendir(path: *const char) *mut DIR {
    let mut rel: *const u8 = null;
    let dirfd = resolve(path, &mut rel);
    if dirfd == -1 {
        return null;
    }
    let fd = open_at(dirfd, rel, O_RDONLY | O_NONBLOCK | O_DIRECTORY);
    if fd == -1 {
        return null;
    }
    let d = malloc(sizeof(Dir)) as *mut Dir;
    let buf = malloc(DIRENT_BUF) as *mut u8;
    if d == null || buf == null {
        free(d);
        free(buf);
        let _ = close(fd);
        return null;
    }
    let mut used: usize = 0;
    let e = unsafe sc_wasi_fd_readdir(fd, buf, DIRENT_BUF, 0, &mut used);
    if e != 0 {
        free(buf);
        free(d);
        let _ = close(fd);
        set_errno(e);
        return null;
    }
    unsafe *d = Dir { fd: fd, cookie: 0, buf: buf, done: 0, size: DIRENT_BUF, used: used, ent: null, ent_size: 1 };
    return d as *mut DIR;
}

const fn rd_u64(p: *const u8) u64 {
    let mut v: u64 = 0;
    for i in 0..8 {
        v |= (unsafe p[i]) as u64 << (8 * i) as u64;
    }
    return v;
}

const fn rd_u32(p: *const u8) u32 {
    let mut v: u32 = 0;
    for i in 0..4 {
        v |= (unsafe p[i]) as u32 << (8 * i) as u32;
    }
    return v;
}

// The `DT_*` type of mode `m`.
const fn dt_of(m: u32) u8 {
    let t = m & S_IFMT;
    return if t == S_IFBLK {
        1u8;
    } else if t == S_IFCHR {
        2u8;
    } else if t == S_IFDIR {
        3u8;
    } else if t == S_IFREG {
        4u8;
    } else if t == S_IFSOCK {
        20u8;
    } else if t == S_IFLNK {
        7u8;
    } else {
        0u8;
    };
}

/// The next entry of `dir`, or null at the end (errno unchanged) or on an error (errno set).
@export("readdir")
pub fn readdir(dir: *mut DIR) *mut dirent {
    let d = dir as *mut Dir;
    // Each pass consumes an entry or refills the buffer; a directory has finitely many entries.
    loop {
        let left = unsafe (*d).used - unsafe (*d).done;
        let mut refill = false;
        if left < WDIRENT {
            if unsafe (*d).used < unsafe (*d).size {
                return null;
            }
            refill = true;
        } else {
            let at = unsafe ((*d).buf + (*d).done);
            let next = rd_u64(at);
            let ino = rd_u64(unsafe (at + 8));
            let nl = rd_u32(unsafe (at + 16)) as usize;
            let kind = unsafe at[20];
            let esize = WDIRENT + nl;
            if nl == 0 {
                unsafe (*d).done += esize;
                continue;
            }
            if left < esize {
                if !grow_buf(unsafe &mut (*d).buf, unsafe &mut (*d).size, esize) {
                    return null;
                }
                refill = true;
            } else {
                let name = unsafe (at + WDIRENT);
                if memchr(name, 0, nl) != null {
                    unsafe (*d).done += esize;
                    continue;
                }
                if !grow_buf(unsafe &mut (*d).ent, unsafe &mut (*d).ent_size, 9 + nl + 1) {
                    return null;
                }
                let ent = unsafe (*d).ent;
                copy(unsafe (ent + 9), name, nl);
                unsafe ent[9 + nl] = 0;
                let mut d_ino = ino;
                let mut d_type = kind;
                if ino == 0 && strcmp((unsafe (ent + 9)) as *const char, "..".ptr() as *const char) != 0 {
                    let mut fs = zero_filestat();
                    let e = unsafe sc_wasi_path_filestat_get(
                        unsafe (*d).fd,
                        0,
                        (unsafe (ent + 9)) as *const char,
                        nl,
                        &mut fs,
                    );
                    if e != 0 {
                        if e == ENOENT as u16 {
                            unsafe (*d).done += esize;
                            continue;
                        }
                        set_errno(e);
                        return null;
                    }
                    let mut st = stat {
                        st_dev: 0,
                        st_ino: 0,
                        st_nlink: 0,
                        st_mode: 0,
                        st_uid: 0,
                        st_gid: 0,
                        __pad0: 0,
                        st_rdev: 0,
                        st_size: 0,
                        st_blksize: 0,
                        st_blocks: 0,
                        st_atim: timespec { tv_sec: 0, tv_nsec: 0 },
                        st_mtim: timespec { tv_sec: 0, tv_nsec: 0 },
                        st_ctim: timespec { tv_sec: 0, tv_nsec: 0 },
                        __reserved: [0i64; 3],
                    };
                    put_stat(&fs, &mut st);
                    d_ino = st.st_ino;
                    d_type = dt_of(st.st_mode);
                }
                unsafe *(ent as *mut u64) = d_ino;
                unsafe ent[8] = d_type;
                unsafe (*d).cookie = next;
                unsafe (*d).done += esize;
                return ent as *mut dirent;
            }
        }
        if refill {
            unsafe (*d).used = unsafe (*d).size;
            unsafe (*d).done = unsafe (*d).size;
            let mut used: usize = 0;
            let e = unsafe sc_wasi_fd_readdir(
                unsafe (*d).fd,
                unsafe (*d).buf,
                unsafe (*d).size,
                unsafe (*d).cookie,
                &mut used,
            );
            if e != 0 {
                set_errno(e);
                return null;
            }
            unsafe (*d).used = used;
            unsafe (*d).done = 0;
        }
    }
}

/// Close `dir`; 0, or -1 with errno.
@export("closedir")
pub fn closedir(dir: *mut DIR) i32 {
    let d = dir as *mut Dir;
    let fd = unsafe (*d).fd;
    free(unsafe (*d).buf);
    free(unsafe (*d).ent);
    free(d);
    return close(fd);
}

/// Start `dir` over from its first entry.
@export("rewinddir")
pub const fn rewinddir(dir: *mut DIR) {
    let d = dir as *mut Dir;
    unsafe (*d).cookie = 0;
    unsafe (*d).used = unsafe (*d).size;
    unsafe (*d).done = unsafe (*d).size;
}

// ---- poll ----------------------------------------------------------------------------------------------

extern "C" "poll.h" {
    pub struct pollfd {
        pub fd: i32,
        pub events: i16,
        pub revents: i16,
    }
}

const POLLRDNORM: i16 = 1;
const POLLWRNORM: i16 = 2;
const POLLERR: i16 = 0x1000;
const POLLHUP: i16 = 0x2000;
const POLLNVAL: i16 = 0x4000;

/// Wait until a descriptor of `fds` is ready or `timeout` milliseconds pass (negative: no limit); the
/// count of ready descriptors, or -1 with errno. Each descriptor must ask for reading or writing.
@export("poll")
pub fn poll(fds: *mut pollfd, nfds: usize, timeout: i32) i32 {
    let max = 2 * nfds + 1;
    let subs = heap_alloc(max * sizeof(Subscription)) as *mut Subscription;
    let evs = heap_alloc(max * sizeof(Event)) as *mut Event;
    if subs == null || evs == null {
        heap_free(subs);
        heap_free(evs);
        set_errno(ENOMEM);
        return -1;
    }
    let mut n: usize = 0;
    for i in 0..nfds {
        let pf = unsafe &mut fds[i];
        if pf.fd < 0 {
            continue;
        }
        let mut made = false;
        for k in 0..2 {
            let bit = if k == 0 {
                POLLRDNORM;
            } else {
                POLLWRNORM;
            };
            if (pf.events & bit) != 0 {
                unsafe subs[n] = Subscription {
                    userdata: ((pf as *mut pollfd) as usize) as u64,
                    tag: if k == 0 {
                        EVENTTYPE_FD_READ;
                    } else {
                        EVENTTYPE_FD_WRITE;
                    },
                    pad: [0u8; 7],
                    id: pf.fd as u32,
                    timeout: 0,
                    precision: 0,
                    flags: 0,
                };
                n += 1;
                made = true;
            }
        }
        if !made {
            heap_free(subs);
            heap_free(evs);
            set_errno(ENOSYS);
            return -1;
        }
    }
    if timeout >= 0 {
        unsafe subs[n] = Subscription {
            userdata: 0,
            tag: EVENTTYPE_CLOCK,
            pad: [0u8; 7],
            id: CLOCK_REALTIME,
            timeout: timeout as u64 * 1000000,
            precision: 0,
            flags: 0,
        };
        n += 1;
    }
    let mut got: usize = 0;
    let e = unsafe sc_wasi_poll_oneoff(subs, evs, n, &mut got);
    if e != 0 {
        heap_free(subs);
        heap_free(evs);
        set_errno(
            if n == 0 {
                ENOTSUP;
            } else {
                e;
            },
        );
        return -1;
    }
    for i in 0..nfds {
        unsafe fds[i].revents = 0;
    }
    for i in 0..got {
        let ev = unsafe evs[i];
        if ev.kind == EVENTTYPE_FD_READ || ev.kind == EVENTTYPE_FD_WRITE {
            let pf = (ev.userdata as usize) as *mut pollfd;
            if ev.error == EBADF as u16 {
                unsafe (*pf).revents |= POLLNVAL;
            } else if ev.error == EPIPE as u16 {
                unsafe (*pf).revents |= POLLHUP;
            } else if ev.error != 0 {
                unsafe (*pf).revents |= POLLERR;
            } else {
                unsafe (*pf).revents |= if ev.kind == EVENTTYPE_FD_READ {
                    POLLRDNORM;
                } else {
                    POLLWRNORM;
                };
                if (ev.rwflags & EVENT_HANGUP) != 0 {
                    unsafe (*pf).revents |= POLLHUP;
                }
            }
        }
    }
    heap_free(subs);
    heap_free(evs);
    let mut ready: i32 = 0;
    for i in 0..nfds {
        if (unsafe fds[i].revents & POLLHUP) != 0 {
            unsafe fds[i].revents &= ~POLLWRNORM;
        }
        if unsafe fds[i].revents != 0 {
            ready += 1;
        }
    }
    return ready;
}

// ---- streams -------------------------------------------------------------------------------------------

extern "C" "stdio.h" {
    pub type FILE;
}

// A stream: a descriptor with one buffer, holding unread input (`rpos..rend`) after a read or unwritten
// output (`wlen` bytes) after a write, never both. Open streams form a list for `exit` and `fflush(null)`.
struct Stream {
    pub fd: i32,
    pub flags: u32,
    pub buf: *mut u8,
    pub cap: usize,
    pub rpos: usize,
    pub rend: usize,
    pub wlen: usize,
    pub next: *mut Stream,
}

const F_READ: u32 = 1;
const F_WRITE: u32 = 2;
const F_EOF: u32 = 4;
const F_ERR: u32 = 8;
// Line buffered: output flushes at each newline.
const F_LINE: u32 = 16;
// No buffer: output goes out at once.
const F_NOBUF: u32 = 32;
// The buffer mode is settled (stdout's waits for its first write).
const F_SET: u32 = 64;
// One of the standard streams: never freed.
const F_STD: u32 = 128;

const BUFSIZ: usize = 4096;
const EOF: i32 = -1;

static mut STD_IN: Stream = Stream {
    fd: 0,
    flags: F_READ | F_SET | F_STD,
    buf: null,
    cap: 0,
    rpos: 0,
    rend: 0,
    wlen: 0,
    next: null,
};
static mut STD_OUT: Stream = Stream {
    fd: 1,
    flags: F_WRITE | F_STD,
    buf: null,
    cap: 0,
    rpos: 0,
    rend: 0,
    wlen: 0,
    next: null,
};
static mut STD_ERR: Stream = Stream {
    fd: 2,
    flags: F_WRITE | F_NOBUF | F_SET | F_STD,
    buf: null,
    cap: 0,
    rpos: 0,
    rend: 0,
    wlen: 0,
    next: null,
};
// The streams `fopen` and `fdopen` made, newest first.
static mut OPEN: *mut Stream = null;

/// Standard stream `fd` (0 stdin, 1 stdout, 2 stderr): what C's `stdin`, `stdout` and `stderr` name on
/// wasm (`super_rt.h`), as the objects the headers declare `const` cannot be defined here.
@export("sc_stdio_stream")
pub fn stdio_stream(fd: i32) *mut FILE {
    if fd == 0 {
        return ((unsafe &mut STD_IN) as *mut Stream) as *mut FILE;
    }
    if fd == 1 {
        return ((unsafe &mut STD_OUT) as *mut Stream) as *mut FILE;
    }
    return ((unsafe &mut STD_ERR) as *mut Stream) as *mut FILE;
}

const fn st<'a>(f: *mut FILE) &'a mut Stream {
    return unsafe &mut *(f as *mut Stream);
}

// Settle the buffer of `f` before its first transfer: stdout is line buffered on a terminal, as musl's. A
// stream gets no buffer when no memory is left.
fn settle(f: &mut Stream) {
    if (f.flags & F_SET) == 0 {
        f.flags |= F_SET;
        if f.fd == 1 && isatty(1) != 0 {
            f.flags |= F_LINE;
        }
    }
    if f.cap == 0 && (f.flags & F_NOBUF) == 0 {
        let b = heap_alloc(BUFSIZ) as *mut u8;
        if b == null {
            f.flags |= F_NOBUF;
        } else {
            f.buf = b;
            f.cap = BUFSIZ;
        }
    }
}

// Write `n` bytes at `p` to the descriptor of `f`; false (F_ERR set) on an error.
fn write_all(f: &mut Stream, p: *const u8, n: usize) bool {
    let mut done: usize = 0;
    // Each pass writes at least a byte or fails.
    while done < n {
        let w = write(f.fd, unsafe (p + done), n - done);
        if w <= 0 {
            f.flags |= F_ERR;
            return false;
        }
        done += w as usize;
    }
    return true;
}

// Write out the pending output of `f`; false on an error.
fn flush_out(f: &mut Stream) bool {
    if f.wlen == 0 {
        return true;
    }
    let n = f.wlen;
    f.wlen = 0;
    return write_all(f, f.buf, n);
}

// Drop the unread input of `f`, moving the descriptor back over it when it can seek.
fn drop_input(f: &mut Stream) {
    if f.rend > f.rpos {
        let _ = lseek(f.fd, 0 - (f.rend - f.rpos) as i64, 1);
    }
    f.rpos = 0;
    f.rend = 0;
}

// Append `n` bytes to `f`; the count written (`n` unless an error).
fn put_bytes(f: &mut Stream, p: *const u8, n: usize) usize {
    if (f.flags & F_WRITE) == 0 {
        f.flags |= F_ERR;
        set_errno(EBADF);
        return 0;
    }
    if f.rend != 0 {
        drop_input(f);
    }
    settle(f);
    if (f.flags & F_NOBUF) != 0 {
        return if write_all(f, p, n) {
            n;
        } else {
            0usize;
        };
    }
    if f.wlen + n > f.cap {
        if !flush_out(f) {
            return 0;
        }
        if n >= f.cap {
            return if write_all(f, p, n) {
                n;
            } else {
                0usize;
            };
        }
    }
    copy(unsafe (f.buf + f.wlen), p, n);
    f.wlen += n;
    if (f.flags & F_LINE) != 0 && memchr(p, 10, n) != null && !flush_out(f) {
        return 0;
    }
    return n;
}

// Refill the input of `f`, after the last `keep` bytes it read, which move to the front so a scan can step
// back over them; false at end of file (F_EOF) or on an error (F_ERR). An unbuffered stream reads a byte at a
// time.
fn fill_input(f: &mut Stream, keep: usize) bool {
    if (f.flags & F_READ) == 0 {
        f.flags |= F_ERR;
        set_errno(EBADF);
        return false;
    }
    // Reading flushes stdout first, as a prompt must show before its answer is read.
    if f.fd == 0 && unsafe STD_OUT.wlen != 0 {
        let _ = flush_out(unsafe &mut STD_OUT);
    }
    if !flush_out(f) {
        return false;
    }
    settle(f);
    // An unbuffered stream has no buffer for its output, but its input needs one.
    if f.cap == 0 {
        let b = heap_alloc(BUFSIZ) as *mut u8;
        if b == null {
            f.flags |= F_ERR;
            set_errno(ENOMEM);
            return false;
        }
        f.buf = b;
        f.cap = BUFSIZ;
    }
    if keep != 0 {
        let _ = memmove(f.buf, unsafe (f.buf + (f.rpos - keep)), keep);
    }
    let want = if (f.flags & F_NOBUF) != 0 {
        1usize;
    } else {
        f.cap - keep;
    };
    let r = read(f.fd, unsafe (f.buf + keep), want);
    f.rpos = keep;
    if r <= 0 {
        f.flags |= if r == 0 {
            F_EOF;
        } else {
            F_ERR;
        };
        f.rend = keep;
        return false;
    }
    f.rend = keep + r as usize;
    return true;
}

// The next byte of `f`, or EOF.
fn get_byte(f: &mut Stream) i32 {
    if f.rpos == f.rend && !fill_input(f, 0) {
        return EOF;
    }
    let c = (unsafe f.buf[f.rpos]) as i32;
    f.rpos += 1;
    return c;
}

// The open flags of a C `fopen` mode, or -1 with EINVAL (musl's `__fmodeflags`).
fn mode_flags(mode: *const char) i32 {
    let m = mode as *const u8;
    let c = unsafe m[0];
    if c != 114 && c != 119 && c != 97 {
        set_errno(EINVAL);
        return -1;
    }
    let plus = unsafe *chrnul(m, 43) != 0;
    let mut fl = if plus {
        O_RDWR;
    } else if c == 114 {
        O_RDONLY;
    } else {
        O_WRONLY;
    };
    if unsafe *chrnul(m, 120) != 0 {
        fl |= O_EXCL;
    }
    if c != 114 {
        fl |= O_CREAT;
    }
    if c == 119 {
        fl |= O_TRUNC;
    }
    if c == 97 {
        fl |= O_APPEND;
    }
    return fl;
}

// A stream over descriptor `fd` opened with flags `fl`, on the open list; null with ENOMEM.
fn new_stream(fd: i32, fl: i32) *mut Stream {
    let f = heap_alloc(sizeof(Stream)) as *mut Stream;
    if f == null {
        set_errno(ENOMEM);
        return null;
    }
    let mut flags: u32 = F_SET;
    if (fl & O_RDONLY) != 0 {
        flags |= F_READ;
    }
    if (fl & O_WRONLY) != 0 {
        flags |= F_WRITE;
    }
    unsafe *f = Stream { fd: fd, flags: flags, buf: null, cap: 0, rpos: 0, rend: 0, wlen: 0, next: unsafe OPEN };
    unsafe OPEN = f;
    return f;
}

/// Open `path` with C mode `mode` ("r", "w", "a", each with an optional "+", "b", "x"); null with errno.
@export("fopen")
pub fn fopen(path: *const char, mode: *const char) *mut FILE {
    let fl = mode_flags(mode);
    if fl < 0 {
        return null;
    }
    let fd = open(path, fl);
    if fd < 0 {
        return null;
    }
    let f = new_stream(fd, fl);
    if f == null {
        let _ = close(fd);
    }
    return f as *mut FILE;
}

/// A stream over open descriptor `fd`; null with errno.
@export("fdopen")
pub fn fdopen(fd: i32, mode: *const char) *mut FILE {
    let fl = mode_flags(mode);
    if fl < 0 {
        return null;
    }
    return new_stream(fd, fl) as *mut FILE;
}

/// Reopen `f` on `path` with `mode`, keeping its descriptor number; `f`, or null (the stream is then
/// closed). A null path only changes the mode, which WASI cannot: null with EBADF.
@export("freopen")
pub fn freopen(path: *const char, mode: *const char, f: *mut FILE) *mut FILE {
    let s = st(f);
    let _ = flush_out(s);
    if path == null {
        set_errno(EBADF);
        let _ = fclose(f);
        return null;
    }
    let fl = mode_flags(mode);
    let fd = if fl < 0 {
        -1;
    } else {
        open(path, fl);
    };
    if fd < 0 {
        let _ = fclose(f);
        return null;
    }
    if unsafe sc_wasi_fd_renumber(fd, s.fd) != 0 {
        let _ = close(fd);
        let _ = fclose(f);
        return null;
    }
    s.flags = s.flags & (F_STD | F_NOBUF | F_LINE | F_SET) | if (fl & O_RDONLY) != 0 {
        F_READ;
    } else {
        0u32;
    } | if (fl & O_WRONLY) != 0 {
        F_WRITE;
    } else {
        0u32;
    };
    s.rpos = 0;
    s.rend = 0;
    s.wlen = 0;
    return f;
}

/// Flush and close `f`, freeing it; 0, or EOF on an error.
@export("fclose")
pub fn fclose(f: *mut FILE) i32 {
    let s = st(f);
    let mut r: i32 = 0;
    if !flush_out(s) {
        r = EOF;
    }
    if close(s.fd) != 0 {
        r = EOF;
    }
    if (s.flags & F_STD) != 0 {
        s.flags &= ~(F_READ | F_WRITE);
        return r;
    }
    let me = f as *mut Stream;
    if unsafe OPEN == me {
        unsafe OPEN = s.next;
    } else {
        let mut p = unsafe OPEN;
        while p != null && unsafe (*p).next != me {
            p = unsafe (*p).next;
        }
        if p != null {
            unsafe (*p).next = s.next;
        }
    }
    heap_free(s.buf);
    heap_free(me);
    return r;
}

// Flush every stream; whether all succeeded.
fn flush_all() bool {
    let mut ok = flush_out(unsafe &mut STD_OUT) && flush_out(unsafe &mut STD_ERR);
    let mut p = unsafe OPEN;
    while p != null {
        ok = flush_out(unsafe &mut *p) && ok;
        p = unsafe (*p).next;
    }
    return ok;
}

/// Write out the buffered output of `f`, or of every stream when null; 0, or EOF on an error.
@export("fflush")
pub fn fflush(f: *mut FILE) i32 {
    if f == null {
        return if flush_all() {
            0;
        } else {
            EOF;
        };
    }
    let s = st(f);
    if !flush_out(s) {
        return EOF;
    }
    if s.rend != 0 {
        drop_input(s);
    }
    return 0;
}

/// Set the buffering of `f`: `_IOFBF` (0) full, `_IOLBF` (1) by line, `_IONBF` (2) none; 0, or -1 for
/// another mode, which leaves `f` without line buffering, as musl's. `f` keeps a buffer of its own: `buf`
/// and `size` are not used. Output `f` holds goes out first, so no byte passes it.
@export("setvbuf")
pub fn setvbuf(f: *mut FILE, _buf: *mut char, mode: i32, _size: usize) i32 {
    let s = st(f);
    let _ = flush_out(s);
    s.flags = s.flags & ~(F_LINE | F_NOBUF) | F_SET;
    if mode == 1 {
        s.flags |= F_LINE;
    } else if mode == 2 {
        s.flags |= F_NOBUF;
    } else if mode != 0 {
        return -1;
    }
    return 0;
}

/// Read `count` items of `size` bytes; the items read.
@export("fread")
pub fn fread(p: *mut void, size: usize, count: usize, f: *mut FILE) usize {
    let s = st(f);
    let total = size * count;
    if total == 0 {
        return 0;
    }
    let d = p as *mut u8;
    let mut got: usize = 0;
    // Each pass takes buffered bytes, reads straight into `p`, or stops at end of file or an error.
    while got < total {
        if s.rpos < s.rend {
            let n = if s.rend - s.rpos < total - got {
                s.rend - s.rpos;
            } else {
                total - got;
            };
            copy(unsafe (d + got), unsafe (s.buf + s.rpos), n);
            s.rpos += n;
            got += n;
            continue;
        }
        if (s.flags & F_READ) == 0 {
            s.flags |= F_ERR;
            set_errno(EBADF);
            break;
        }
        if total - got >= BUFSIZ {
            if !flush_out(s) {
                break;
            }
            let r = read(s.fd, unsafe (d + got), total - got);
            if r <= 0 {
                s.flags |= if r == 0 {
                    F_EOF;
                } else {
                    F_ERR;
                };
                break;
            }
            got += r as usize;
            continue;
        }
        if !fill_input(s, 0) {
            break;
        }
    }
    return got / size;
}

/// Write `count` items of `size` bytes; the items written.
@export("fwrite")
pub fn fwrite(p: *const void, size: usize, count: usize, f: *mut FILE) usize {
    let total = size * count;
    if total == 0 {
        return 0;
    }
    let n = put_bytes(st(f), p as *const u8, total);
    return if n == total {
        count;
    } else {
        n / size;
    };
}

/// The next byte of `f`, or EOF.
@export("fgetc")
pub fn fgetc(f: *mut FILE) i32 {
    return get_byte(st(f));
}

/// The next byte of `f`, or EOF.
@export("getc")
pub fn getc(f: *mut FILE) i32 {
    return get_byte(st(f));
}

/// The next byte of stdin, or EOF.
@export("getchar")
pub fn getchar() i32 {
    return get_byte(unsafe &mut STD_IN);
}

/// Write byte `c` to `f`; `c` as an unsigned char, or EOF.
@export("fputc")
pub fn fputc(c: i32, f: *mut FILE) i32 {
    let b = c as u8;
    if put_bytes(st(f), &b, 1) != 1 {
        return EOF;
    }
    return b;
}

/// Write byte `c` to `f`.
@export("putc")
pub fn putc(c: i32, f: *mut FILE) i32 {
    return fputc(c, f);
}

/// Write byte `c` to stdout.
@export("putchar")
pub fn putchar(c: i32) i32 {
    let b = c as u8;
    if put_bytes(unsafe &mut STD_OUT, &b, 1) != 1 {
        return EOF;
    }
    return b;
}

/// Write NUL-terminated `s` to `f`; non-negative, or EOF.
@export("fputs")
pub fn fputs(s: *const char, f: *mut FILE) i32 {
    let n = strlen(s);
    if put_bytes(st(f), s as *const u8, n) != n {
        return EOF;
    }
    return 0;
}

/// Write `s` and a newline to stdout; non-negative, or EOF.
@export("puts")
pub fn puts(s: *const char) i32 {
    let n = strlen(s);
    let out = unsafe &mut STD_OUT;
    let nl: u8 = 10;
    if put_bytes(out, s as *const u8, n) != n || put_bytes(out, &nl, 1) != 1 {
        return EOF;
    }
    return 0;
}

/// Read a line of at most `size - 1` bytes into `buf` (the newline kept), NUL-terminated; null at end of
/// file before any byte, or on an error.
@export("fgets")
pub fn fgets(buf: *mut char, size: i32, f: *mut FILE) *mut char {
    let s = st(f);
    let b = buf as *mut u8;
    if size < 1 {
        return null;
    }
    let max = (size - 1) as usize;
    let mut n: usize = 0;
    while n < max {
        let c = get_byte(s);
        if c == EOF {
            if n == 0 || (s.flags & F_ERR) != 0 {
                return null;
            }
            break;
        }
        unsafe b[n] = c as u8;
        n += 1;
        if c == 10 {
            break;
        }
    }
    unsafe b[n] = 0;
    return buf;
}

/// Whether a read of `f` hit end of file.
@export("feof")
pub const fn feof(f: *mut FILE) i32 {
    return ((st(f).flags & F_EOF) != 0) as i32;
}

/// Whether an operation on `f` failed.
@export("ferror")
pub const fn ferror(f: *mut FILE) i32 {
    return ((st(f).flags & F_ERR) != 0) as i32;
}

/// Clear the end-of-file and error flags of `f`.
@export("clearerr")
pub const fn clearerr(f: *mut FILE) {
    st(f).flags &= ~(F_EOF | F_ERR);
}

/// The descriptor of `f`.
@export("fileno")
pub const fn fileno(f: *mut FILE) i32 {
    return st(f).fd;
}

/// Move the position of `f`; 0, or -1 with errno. Clears end of file.
@export("fseek")
pub fn fseek(f: *mut FILE, offset: isize, whence: i32) i32 {
    let s = st(f);
    if !flush_out(s) {
        return -1;
    }
    let mut off = offset as i64;
    if whence == 1 {
        off -= (s.rend - s.rpos) as i64;
    }
    s.rpos = 0;
    s.rend = 0;
    if lseek(s.fd, off, whence) < 0 {
        return -1;
    }
    s.flags &= ~F_EOF;
    return 0;
}

/// The position of `f`, or -1 with errno.
@export("ftell")
pub fn ftell(f: *mut FILE) isize {
    let s = st(f);
    let at = lseek(s.fd, 0, 1);
    if at < 0 {
        return -1;
    }
    let pos = at + s.wlen as i64 - (s.rend - s.rpos) as i64;
    if pos > 0x7FFFFFFF {
        set_errno(EOVERFLOW);
        return -1;
    }
    return pos as isize;
}

/// Seek `f` to its start and clear its error flag.
@export("rewind")
pub fn rewind(f: *mut FILE) {
    let _ = fseek(f, 0, 0);
    st(f).flags &= ~F_ERR;
}

/// `prefix: <message for errno>` and a newline on stderr (the prefix and colon only when nonempty).
@export("perror")
pub fn perror(prefix: *const char) {
    let e = unsafe ERRNO;
    let err = unsafe &mut STD_ERR;
    if prefix != null && unsafe *prefix != 0 as char {
        let _ = put_bytes(err, prefix as *const u8, strlen(prefix));
        let _ = put_bytes(err, ": ".ptr(), 2);
    }
    let m = strerror(e);
    let _ = put_bytes(err, m as *const u8, strlen(m));
    let nl: u8 = 10;
    let _ = put_bytes(err, &nl, 1);
}

// ---- locale --------------------------------------------------------------------------------------------
//
// musl's locales with no locale file: a category's locale is C, or a name kept for `setlocale` to answer.
// Every named locale behaves as C, but under LC_CTYPE: there any name but "C" and "POSIX" makes characters
// UTF-8 (`MB_CUR_MAX` 4), as musl's built-in "C.UTF-8".

extern "C" "locale.h" {
    pub struct lconv {
        pub decimal_point: *mut char,
        pub thousands_sep: *mut char,
        pub grouping: *mut char,
        pub int_curr_symbol: *mut char,
        pub currency_symbol: *mut char,
        pub mon_decimal_point: *mut char,
        pub mon_thousands_sep: *mut char,
        pub mon_grouping: *mut char,
        pub positive_sign: *mut char,
        pub negative_sign: *mut char,
        pub int_frac_digits: char,
        pub frac_digits: char,
        pub p_cs_precedes: char,
        pub p_sep_by_space: char,
        pub n_cs_precedes: char,
        pub n_sep_by_space: char,
        pub p_sign_posn: char,
        pub n_sign_posn: char,
        pub int_p_cs_precedes: char,
        pub int_p_sep_by_space: char,
        pub int_n_cs_precedes: char,
        pub int_n_sep_by_space: char,
        pub int_p_sign_posn: char,
        pub int_n_sign_posn: char,
    }
}

const LC_CTYPE: i32 = 0;
const LC_ALL: i32 = 6;
const LOCALE_NAME_MAX: usize = 23;
const C_UTF8: str<'static> = "C.UTF-8";

// A locale name `setlocale` met, in a list that only grows: a name it answered stays valid.
struct LocName {
    pub name: [u8; 24],
    pub next: *mut LocName,
}

static mut LOC_NAMES: *mut LocName = null;
// Each category's locale name, or null for C.
static mut LOC_CAT: [*const u8; 6] = [null as *const u8; 6];
// `setlocale(LC_ALL, ..)`'s answer when the categories differ: each name and a ';'.
static mut LOC_ALL: [u8; 144] = [0u8; 144];
static mut LCONV: lconv = lconv {
    decimal_point: null,
    thousands_sep: null,
    grouping: null,
    int_curr_symbol: null,
    currency_symbol: null,
    mon_decimal_point: null,
    mon_thousands_sep: null,
    mon_grouping: null,
    positive_sign: null,
    negative_sign: null,
    int_frac_digits: 0 as char,
    frac_digits: 0 as char,
    p_cs_precedes: 0 as char,
    p_sep_by_space: 0 as char,
    n_cs_precedes: 0 as char,
    n_sep_by_space: 0 as char,
    p_sign_posn: 0 as char,
    n_sign_posn: 0 as char,
    int_p_cs_precedes: 0 as char,
    int_p_sep_by_space: 0 as char,
    int_n_cs_precedes: 0 as char,
    int_n_sep_by_space: 0 as char,
    int_p_sign_posn: 0 as char,
    int_n_sign_posn: 0 as char,
};

// Whether characters are UTF-8: LC_CTYPE has a named locale.
fn utf8_ctype() bool {
    return unsafe LOC_CAT[0] != null;
}

/// The most bytes a character takes: 4 under a UTF-8 LC_CTYPE, else 1 (`MB_CUR_MAX`).
@export("__ctype_get_mb_cur_max")
pub fn ctype_get_mb_cur_max() usize {
    return if utf8_ctype() {
        4usize;
    } else {
        1usize;
    };
}

// musl's `__get_locale`: the locale of category `cat` that name `val` names, null for C. An empty name
// reads LC_ALL, the category's variable and LANG, else "C.UTF-8"; a name longer than 23 bytes, with a '/'
// or a leading '.' is "C.UTF-8".
fn get_locale(cat: i32, val0: *const u8) *const u8 {
    let mut val = val0;
    if unsafe *val == 0 {
        let vars = ["LC_CTYPE", "LC_NUMERIC", "LC_TIME", "LC_COLLATE", "LC_MONETARY", "LC_MESSAGES"];
        let names = ["LC_ALL", unsafe vars[cat as usize], "LANG"];
        val = C_UTF8.ptr();
        for v in names {
            let e = getenv(v.ptr() as *const char) as *const u8;
            if e != null && unsafe *e != 0 {
                val = e;
                break;
            }
        }
    }
    let mut n: usize = 0;
    while n < LOCALE_NAME_MAX && unsafe val[n] != 0 && unsafe val[n] != 47 {
        n += 1;
    }
    if unsafe val[0] == 46 || unsafe val[n] != 0 {
        val = C_UTF8.ptr();
        n = 7;
    }
    let c = val as *const char;
    if strcmp(c, "C".ptr() as *const char) == 0 || strcmp(c, "POSIX".ptr() as *const char) == 0 {
        return null;
    }
    if strcmp(c, C_UTF8.ptr() as *const char) == 0 {
        return if cat == LC_CTYPE {
            C_UTF8.ptr();
        } else {
            null;
        };
    }
    let mut p = unsafe LOC_NAMES;
    while p != null {
        if strcmp(((unsafe &(*p).name[0]) as *const u8) as *const char, c) == 0 {
            return unsafe &(*p).name[0];
        }
        p = unsafe (*p).next;
    }
    let l = heap_alloc(sizeof(LocName)) as *mut LocName;
    if l == null {
        return if cat == LC_CTYPE {
            C_UTF8.ptr();
        } else {
            null;
        };
    }
    copy(unsafe &mut (*l).name[0], val, n);
    unsafe (*l).name[n] = 0;
    unsafe (*l).next = unsafe LOC_NAMES;
    unsafe LOC_NAMES = l;
    return unsafe &(*l).name[0];
}

const fn loc_name(l: *const u8) *const u8 {
    return if l == null {
        "C".ptr();
    } else {
        l;
    };
}

/// Set (`name` not null) or query the locale of category `cat`; its name, or null for a category past
/// LC_ALL. For LC_ALL, `name` may list each category's name with ';' between, and the answer is one name
/// when every category has it, else that list.
@export("setlocale")
pub fn setlocale(cat: i32, name: *const char) *mut char {
    if cat as u32 > LC_ALL as u32 {
        return null;
    }
    if cat != LC_ALL {
        if name != null {
            unsafe LOC_CAT[cat as usize] = get_locale(cat, name as *const u8);
        }
        return loc_name(unsafe LOC_CAT[cat as usize]) as *mut char;
    }
    if name != null {
        let mut part = [0u8; 24];
        copy(&mut part[0], C_UTF8.ptr(), 8);
        let mut p = name as *const u8;
        let mut tmp = [null as *const u8; 6];
        for i in 0..6usize {
            let z = chrnul(p, 59);
            let len = z as usize - p as usize;
            if len <= LOCALE_NAME_MAX {
                copy(&mut part[0], p, len);
                unsafe part[len] = 0;
                if unsafe *z != 0 {
                    p = unsafe (z + 1);
                }
            }
            unsafe tmp[i] = get_locale(i as i32, &part[0]);
        }
        for i in 0..6usize {
            unsafe LOC_CAT[i] = unsafe tmp[i];
        }
    }
    let mut same: usize = 0;
    let mut k: usize = 0;
    let mut last: *const u8 = null;
    for i in 0..6usize {
        let l = unsafe LOC_CAT[i];
        if l == unsafe LOC_CAT[0] {
            same += 1;
        }
        last = loc_name(l);
        let n = strlen(last as *const char);
        copy(unsafe &mut LOC_ALL[k], last, n);
        unsafe LOC_ALL[k + n] = 59;
        k += n + 1;
    }
    unsafe LOC_ALL[k - 1] = 0;
    return if same == 6 {
        last as *mut char;
    } else {
        ((unsafe &mut LOC_ALL[0]) as *mut u8) as *mut char;
    };
}

/// The C locale's numeric and monetary conventions: "." and empty strings, and `CHAR_MAX` (none) for the
/// numbers.
@export("localeconv")
pub fn localeconv() *mut lconv {
    let e = "".ptr() as *mut char;
    let none = 255 as char;
    unsafe LCONV = lconv {
        decimal_point: ".".ptr() as *mut char,
        thousands_sep: e,
        grouping: e,
        int_curr_symbol: e,
        currency_symbol: e,
        mon_decimal_point: e,
        mon_thousands_sep: e,
        mon_grouping: e,
        positive_sign: e,
        negative_sign: e,
        int_frac_digits: none,
        frac_digits: none,
        p_cs_precedes: none,
        p_sep_by_space: none,
        n_cs_precedes: none,
        n_sep_by_space: none,
        p_sign_posn: none,
        n_sign_posn: none,
        int_p_cs_precedes: none,
        int_p_sep_by_space: none,
        int_n_cs_precedes: none,
        int_n_sep_by_space: none,
        int_p_sign_posn: none,
        int_n_sign_posn: none,
    };
    return unsafe &mut LCONV;
}

// ---- errors --------------------------------------------------------------------------------------------

// musl's messages under the WASI codes; a code past the table reads the first, as wasi-libc's does.
const ERR_MSG: [str<'static>; 77] = [
    "Success",
    "Argument list too long",
    "Permission denied",
    "Address in use",
    "Address not available",
    "Address family not supported by protocol",
    "Resource temporarily unavailable",
    "Operation already in progress",
    "Bad file descriptor",
    "Bad message",
    "Resource busy",
    "Operation canceled",
    "No child process",
    "Connection aborted",
    "Connection refused",
    "Connection reset by peer",
    "Resource deadlock would occur",
    "Destination address required",
    "Domain error",
    "Quota exceeded",
    "File exists",
    "Bad address",
    "File too large",
    "Host is unreachable",
    "Identifier removed",
    "Illegal byte sequence",
    "Operation in progress",
    "Interrupted system call",
    "Invalid argument",
    "I/O error",
    "Socket is connected",
    "Is a directory",
    "Symbolic link loop",
    "No file descriptors available",
    "Too many links",
    "Message too large",
    "Multihop attempted",
    "Filename too long",
    "Network is down",
    "Connection reset by network",
    "Network unreachable",
    "Too many open files in system",
    "No buffer space available",
    "No such device",
    "No such file or directory",
    "Exec format error",
    "No locks available",
    "Link has been severed",
    "Out of memory",
    "No message of desired type",
    "Protocol not available",
    "No space left on device",
    "Function not implemented",
    "Socket not connected",
    "Not a directory",
    "Directory not empty",
    "State not recoverable",
    "Not a socket",
    "Not supported",
    "Not a tty",
    "No such device or address",
    "Value too large for data type",
    "Previous owner died",
    "Operation not permitted",
    "Broken pipe",
    "Protocol error",
    "Protocol not supported",
    "Protocol wrong type for socket",
    "Result not representable",
    "Read-only file system",
    "Invalid seek",
    "No such process",
    "Stale file handle",
    "Operation timed out",
    "Text file busy",
    "Cross-device link",
    "Capabilities insufficient",
];

/// The message of error code `code`.
@export("strerror")
pub const fn strerror(code: i32) *mut char {
    let i = if code < 0 || code >= 77 {
        0usize;
    } else {
        code as usize;
    };
    return (unsafe ERR_MSG[i].ptr()) as *mut char;
}

// ---- printf --------------------------------------------------------------------------------------------
// musl's `printf_core`, over a stream or a buffer.

// Where formatted output goes: stream `f`, or (`f` null) the first `cap` bytes of `buf`.
struct Out {
    pub f: *mut Stream,
    pub buf: *mut u8,
    pub cap: usize,
    pub len: usize,
}

fn out(o: &mut Out, s: *const u8, l: usize) {
    if o.f != null {
        let f = unsafe &mut *o.f;
        if (f.flags & F_ERR) == 0 {
            let _ = put_bytes(f, s, l);
        }
        return;
    }
    if o.len < o.cap {
        let n = if l < o.cap - o.len {
            l;
        } else {
            o.cap - o.len;
        };
        copy(unsafe (o.buf + o.len), s, n);
    }
    o.len += l;
}

// The modifier flags: bit (c - ' ') for each flag character c.
const ALT_FORM: u32 = 1 << 3;
const ZERO_PAD: u32 = 1 << 16;
const LEFT_ADJ: u32 = 1 << 13;
const PAD_POS: u32 = 1;
const MARK_POS: u32 = 1 << 11;
const GROUPED: u32 = 1 << 7;
const FLAGMASK: u32 = ALT_FORM | ZERO_PAD | LEFT_ADJ | PAD_POS | MARK_POS | GROUPED;
const INT_MAX: i32 = 2147483647;
const INT_MIN: i32 = -INT_MAX - 1;
const NL_ARGMAX: usize = 9;

// `w - l` copies of `c`, unless `fl` adjusts left or pads with zeros, or `l` fills `w`.
fn pad(o: &mut Out, c: u8, w: i32, l: i32, fl: u32) {
    if (fl & (LEFT_ADJ | ZERO_PAD)) != 0 || l >= w {
        return;
    }
    let mut n = (w - l) as usize;
    let mut b = [0u8; 256];
    fill(
        &mut b[0],
        c,
        if n > 256 {
            256usize;
        } else {
            n;
        },
    );
    while n >= 256 {
        out(o, &b[0], 256);
        n -= 256;
    }
    out(o, &b[0], n);
}

const XDIGITS: str<'static> = "0123456789ABCDEF";

// The digits of `x` written backward ending at `s`; the first digit's address.
const fn fmt_x(x0: u64, s0: *mut u8, lower: u8) *mut u8 {
    let mut s = s0;
    let mut x = x0;
    while x != 0 {
        s = unsafe (s - 1);
        unsafe *s = XDIGITS[(x & 15) as usize] | lower;
        x >>= 4;
    }
    return s;
}

const fn fmt_o(x0: u64, s0: *mut u8) *mut u8 {
    let mut s = s0;
    let mut x = x0;
    while x != 0 {
        s = unsafe (s - 1);
        unsafe *s = 48 + (x & 7) as u8;
        x >>= 3;
    }
    return s;
}

const fn fmt_u(x0: u64, s0: *mut u8) *mut u8 {
    let mut s = s0;
    let mut x = x0;
    while x != 0 {
        s = unsafe (s - 1);
        unsafe *s = 48 + (x % 10) as u8;
        x /= 10;
    }
    return s;
}

const fn imax(a: i32, b: i32) i32 {
    return if a > b {
        a;
    } else {
        b;
    };
}

const fn imin(a: i32, b: i32) i32 {
    return if a < b {
        a;
    } else {
        b;
    };
}

union Bits64 {
    pub f: f64,
    pub u: u64,
}

// The decimal digits of a double in base 10^9 words: `BIG` words, of which a double needs at most 128
// (its 2^-1074 to 2^1024 range and the four words of its significand).
const BIG: usize = 160;
// The end of the room a nonnegative exponent leaves for the significand's words (musl: the mantissa
// digits plus one).
const BIG_TOP: usize = BIG - 54;

// musl's `fmt_fp` for a double `y`: %e %f %g %a and their uppercase forms, width `w`, precision `p`
// (negative: none), flags `fl`, conversion `t`. The significand is split with integer arithmetic, where
// musl multiplies a long double: the digits, and so every rounding, are the same. The count written, or -1.
fn fmt_fp(o: &mut Out, y0: f64, w: i32, p0: i32, fl: u32, t0: i32) i32 {
    let mut big = [0u32; BIG];
    let mut p = p0;
    let mut t = t0;
    let prefixes = "-0X+0X 0X-0x+0x 0x".ptr();
    let mut prefix: usize = 0;
    let mut pl: i32 = 1;
    let bits = Bits64 { f: y0 };
    let ybits = bits.u;
    let neg = ybits >> 63 != 0;
    if neg {
        // "-0X"
    } else if (fl & MARK_POS) != 0 {
        prefix = 3;
    } else if (fl & PAD_POS) != 0 {
        prefix = 6;
    } else {
        prefix = 1;
        pl = 0;
    }
    let ex = (ybits >> 52 & 0x7ff) as i32;
    let fr = ybits & 0xFFFFFFFFFFFFF;
    if ex == 0x7ff {
        let lower = (t & 32) != 0;
        let mut s = if lower {
            "inf";
        } else {
            "INF";
        };
        if fr != 0 {
            s = if lower {
                "nan";
            } else {
                "NAN";
            };
        }
        pad(o, 32, w, 3 + pl, fl & ~ZERO_PAD);
        out(o, unsafe (prefixes + prefix), pl as usize);
        out(o, s.ptr(), 3);
        pad(o, 32, w, 3 + pl, fl ^ LEFT_ADJ);
        return imax(w, 3 + pl);
    }
    // |y| = m * 2^(e2 - 52), `m` normalized to 53 bits: musl's `frexpl(y, &e2) * 2`, so y = m / 2^52 in [1, 2).
    let mut m: u64 = 0;
    let mut e2: i32 = 0;
    if ex != 0 {
        m = fr | 0x10000000000000;
        e2 = ex - 1023;
    } else if fr != 0 {
        m = fr;
        e2 = -1022;
        while m < 0x10000000000000 {
            m <<= 1;
            e2 -= 1;
        }
    }
    let mut buf = [0u8; 9 + 28];
    let bufp = (&mut buf[0]) as *mut u8;
    let mut ebuf0 = [0u8; 12];
    let ebuf = unsafe ((&mut ebuf0[0]) as *mut u8 + 12);
    if (t | 32) == 97 {
        if (t & 32) != 0 {
            prefix += 9;
        }
        pl += 2;
        // Round to `p` hex digits after the point, to nearest, ties to even (musl adds and subtracts a
        // power of two in long double; its 112-bit fraction holds the double's 52 exactly).
        if p >= 0 && p < 13 {
            let drop = (52 - 4 * p) as u64;
            let q = m >> drop;
            let r = m & (1u64 << drop) - 1;
            let half = 1u64 << drop - 1;
            m = q << drop;
            if r > half || r == half && (q & 1) != 0 {
                m += 1u64 << drop;
            }
        }
        let mut estr = fmt_u(
            if e2 < 0 {
                (0 - e2) as u64;
            } else {
                e2 as u64;
            },
            ebuf,
        );
        if estr == ebuf {
            estr = unsafe (estr - 1);
            unsafe *estr = 48;
        }
        estr = unsafe (estr - 1);
        unsafe *estr = if e2 < 0 {
            45u8;
        } else {
            43u8;
        };
        estr = unsafe (estr - 1);
        unsafe *estr = (t + 15) as u8;
        let elen = (ebuf as usize - estr as usize) as i32;
        let mut s = bufp;
        let lead = m >> 52;
        let mut frac = m & 0xFFFFFFFFFFFFF;
        unsafe *s = XDIGITS[lead as usize] | (t & 32) as u8;
        s = unsafe (s + 1);
        if frac != 0 || p > 0 || (fl & ALT_FORM) != 0 {
            unsafe *s = 46;
            s = unsafe (s + 1);
        }
        while frac != 0 {
            unsafe *s = XDIGITS[(frac >> 48) as usize] | (t & 32) as u8;
            s = unsafe (s + 1);
            frac = frac << 4 & 0xFFFFFFFFFFFFF;
        }
        let slen = (s as usize - bufp as usize) as i32;
        if p > INT_MAX - 2 - elen - pl {
            return -1;
        }
        let l = if p != 0 && slen - 2 < p {
            p + 2 + elen;
        } else {
            slen + elen;
        };
        pad(o, 32, w, pl + l, fl);
        out(o, unsafe (prefixes + prefix), pl as usize);
        pad(o, 48, w, pl + l, fl ^ ZERO_PAD);
        out(o, bufp, slen as usize);
        pad(o, 48, l - elen - slen, 0, 0);
        out(o, estr, elen as usize);
        pad(o, 32, w, pl + l, fl ^ LEFT_ADJ);
        return imax(w, pl + l);
    }
    if p < 0 {
        p = 6;
    }
    // musl: y *= 2^28, e2 -= 28, then the integer part and the base-10^9 fraction digits of y = m / 2^24.
    let mut a: usize = 0;
    if m != 0 {
        e2 -= 28;
    }
    if e2 >= 0 {
        a = BIG_TOP;
    }
    let r = a;
    let mut z = a;
    unsafe big[z] = (m >> 24) as u32;
    z += 1;
    let mut rem = m & 0xFFFFFF;
    let mut den: u32 = 24;
    while rem != 0 {
        // rem / 2^den times 10^9 = rem * 1953125 / 2^(den - 9).
        let v = rem * 1953125;
        if den <= 9 {
            unsafe big[z] = (v << 9 - den) as u32;
            z += 1;
            rem = 0;
        } else {
            den -= 9;
            unsafe big[z] = (v >> den) as u32;
            z += 1;
            rem = v & (1u64 << den) - 1;
        }
    }
    while e2 > 0 {
        let mut carry: u32 = 0;
        let sh = imin(29, e2) as u64;
        let mut d = z;
        while d > a {
            d -= 1;
            let x = ((unsafe big[d]) as u64 << sh) + carry as u64;
            unsafe big[d] = (x % 1000000000) as u32;
            carry = (x / 1000000000) as u32;
        }
        if carry != 0 {
            a -= 1;
            unsafe big[a] = carry;
        }
        while z > a && unsafe big[z - 1] == 0 {
            z -= 1;
        }
        e2 -= sh as i32;
    }
    while e2 < 0 {
        let mut carry: u32 = 0;
        let sh = imin(9, 0 - e2) as u32;
        // musl's count of words worth computing: the precision and long double's 113 / 3 guard digits.
        let need = 1 + (p as usize + 37 + 8) / 9;
        for d in a..z {
            let rm = unsafe big[d] & (1u32 << sh) - 1;
            unsafe big[d] = (unsafe big[d] >> sh) + carry;
            carry = (1000000000u32 >> sh) * rm;
        }
        if unsafe big[a] == 0 {
            a += 1;
        }
        if carry != 0 {
            unsafe big[z] = carry;
            z += 1;
        }
        let b = if (t | 32) == 102 {
            r;
        } else {
            a;
        };
        if z - b > need {
            z = b + need;
        }
        e2 += sh as i32;
    }
    let mut e: i32 = 0;
    if a < z {
        e = (9 * (r as isize - a as isize)) as i32;
        let mut i: u32 = 10;
        while unsafe big[a] >= i {
            i *= 10;
            e += 1;
        }
    }
    // Rounding: j is the precision after the radix point (possibly negative).
    let mut j = p - ((t | 32) != 102) as i32 * e - ((t | 32) == 103 && p != 0) as i32;
    if j as isize < 9 * (z as isize - r as isize - 1) {
        // The word holding the last kept digit, with floor division for a negative j.
        let dq = (j + 9 * 16384) / 9 - 16384;
        let d = (r as isize + 1 + dq as isize) as usize;
        j += 9 * 16384;
        j %= 9;
        let mut i: u32 = 10;
        j += 1;
        while j < 9 {
            i *= 10;
            j += 1;
        }
        let x = unsafe big[d] % i;
        // Any significant digits past j?
        if x != 0 || d + 1 != z {
            // musl decides by adding round + small in long double under the current rounding mode, which
            // wasm fixes to nearest-even: up when past half, or at an exact half with an odd kept digit.
            let odd = (unsafe big[d] / i & 1) != 0 || i == 1000000000 && d > a && (unsafe big[d - 1] & 1) != 0;
            let up = if x < i / 2 {
                false;
            } else if x == i / 2 && d + 1 == z {
                odd;
            } else {
                true;
            };
            unsafe big[d] -= x;
            if up {
                unsafe big[d] += i;
                let mut dd = d;
                while unsafe big[dd] > 999999999 {
                    unsafe big[dd] = 0;
                    if dd == a {
                        a -= 1;
                        unsafe big[a] = 0;
                    }
                    dd -= 1;
                    unsafe big[dd] += 1;
                }
                e = (9 * (r as isize - a as isize)) as i32;
                let mut i2: u32 = 10;
                while unsafe big[a] >= i2 {
                    i2 *= 10;
                    e += 1;
                }
            }
        }
        if z > d + 1 {
            z = d + 1;
        }
    }
    while z > a && unsafe big[z - 1] == 0 {
        z -= 1;
    }
    if (t | 32) == 103 {
        if p == 0 {
            p += 1;
        }
        if p > e && e >= -4 {
            t -= 1;
            p -= e + 1;
        } else {
            t -= 2;
            p -= 1;
        }
        if (fl & ALT_FORM) == 0 {
            // Count trailing zeros in the last word.
            let mut tz: i32 = 9;
            if z > a && unsafe big[z - 1] != 0 {
                tz = 0;
                let mut i: u32 = 10;
                while unsafe big[z - 1] % i == 0 {
                    i *= 10;
                    tz += 1;
                }
            }
            let words = (9 * (z as isize - r as isize - 1)) as i32;
            if (t | 32) == 102 {
                p = imin(p, imax(0, words - tz));
            } else {
                p = imin(p, imax(0, words + e - tz));
            }
        }
    }
    let dot = (p != 0 || (fl & ALT_FORM) != 0) as i32;
    if p > INT_MAX - 1 - dot {
        return -1;
    }
    let mut l = 1 + p + dot;
    let mut estr = ebuf;
    if (t | 32) == 102 {
        if e > INT_MAX - l {
            return -1;
        }
        if e > 0 {
            l += e;
        }
    } else {
        estr = fmt_u(
            if e < 0 {
                (0 - e) as u64;
            } else {
                e as u64;
            },
            ebuf,
        );
        while ebuf as usize - estr as usize < 2 {
            estr = unsafe (estr - 1);
            unsafe *estr = 48;
        }
        estr = unsafe (estr - 1);
        unsafe *estr = if e < 0 {
            45u8;
        } else {
            43u8;
        };
        estr = unsafe (estr - 1);
        unsafe *estr = t as u8;
        let elen = (ebuf as usize - estr as usize) as i32;
        if elen > INT_MAX - l {
            return -1;
        }
        l += elen;
    }
    if l > INT_MAX - pl {
        return -1;
    }
    pad(o, 32, w, pl + l, fl);
    out(o, unsafe (prefixes + prefix), pl as usize);
    pad(o, 48, w, pl + l, fl ^ ZERO_PAD);
    let b9 = unsafe (bufp + 9);
    if (t | 32) == 102 {
        if a > r {
            a = r;
        }
        let mut d = a;
        while d <= r {
            let mut s = fmt_u(unsafe big[d], b9);
            if d != a {
                while s > bufp {
                    s = unsafe (s - 1);
                    unsafe *s = 48;
                }
            } else if s == b9 {
                s = unsafe (s - 1);
                unsafe *s = 48;
            }
            out(o, s, b9 as usize - s as usize);
            d += 1;
        }
        if p != 0 || (fl & ALT_FORM) != 0 {
            out(o, ".".ptr(), 1);
        }
        while d < z && p > 0 {
            let mut s = fmt_u(unsafe big[d], b9);
            while s > bufp {
                s = unsafe (s - 1);
                unsafe *s = 48;
            }
            out(o, s, imin(9, p) as usize);
            d += 1;
            p -= 9;
        }
        pad(o, 48, p + 9, 9, 0);
    } else {
        if z <= a {
            z = a + 1;
        }
        let mut d = a;
        while d < z && p >= 0 {
            let mut s = fmt_u(unsafe big[d], b9);
            if s == b9 {
                s = unsafe (s - 1);
                unsafe *s = 48;
            }
            if d != a {
                while s > bufp {
                    s = unsafe (s - 1);
                    unsafe *s = 48;
                }
            } else {
                out(o, s, 1);
                s = unsafe (s + 1);
                if p > 0 || (fl & ALT_FORM) != 0 {
                    out(o, ".".ptr(), 1);
                }
            }
            let left = (b9 as usize - s as usize) as i32;
            out(o, s, imin(left, p) as usize);
            p -= left;
            d += 1;
        }
        pad(o, 48, p + 18, 18, 0);
        out(o, estr, ebuf as usize - estr as usize);
    }
    pad(o, 32, w, pl + l, fl ^ LEFT_ADJ);
    return imax(w, pl + l);
}

// musl's conversion state machine: row `state`, column the specifier byte minus 'A'; 0 rejects.
const PF_STATES: [u8; 464] = [
    25,
    0,
    10,
    0,
    25,
    25,
    25,
    0,
    0,
    0,
    0,
    5,
    0,
    0,
    0,
    0,
    0,
    0,
    9,
    0,
    0,
    0,
    0,
    11,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    25,
    0,
    17,
    10,
    25,
    25,
    25,
    3,
    10,
    7,
    0,
    1,
    27,
    9,
    11,
    24,
    0,
    0,
    9,
    6,
    11,
    0,
    0,
    11,
    0,
    6,
    25,
    0,
    0,
    0,
    25,
    25,
    25,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    14,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    25,
    0,
    10,
    13,
    25,
    25,
    25,
    0,
    13,
    0,
    0,
    2,
    0,
    9,
    14,
    0,
    0,
    0,
    9,
    0,
    14,
    0,
    0,
    14,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    12,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    19,
    0,
    0,
    0,
    0,
    19,
    0,
    0,
    0,
    0,
    9,
    12,
    0,
    0,
    0,
    0,
    0,
    12,
    0,
    0,
    12,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    16,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    15,
    0,
    0,
    0,
    4,
    15,
    0,
    0,
    0,
    0,
    9,
    16,
    0,
    0,
    0,
    0,
    0,
    16,
    0,
    0,
    16,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    18,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    17,
    0,
    0,
    0,
    0,
    17,
    0,
    0,
    0,
    0,
    9,
    18,
    0,
    0,
    0,
    0,
    0,
    18,
    0,
    0,
    18,
    0,
    0,
    26,
    0,
    0,
    0,
    26,
    26,
    26,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    26,
    0,
    0,
    0,
    26,
    26,
    26,
    0,
    0,
    0,
    0,
    0,
    0,
    9,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    20,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    23,
    0,
    0,
    0,
    0,
    23,
    0,
    0,
    0,
    0,
    9,
    20,
    0,
    0,
    0,
    0,
    0,
    20,
    0,
    0,
    20,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    22,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    21,
    0,
    0,
    0,
    0,
    21,
    0,
    0,
    0,
    0,
    9,
    22,
    0,
    0,
    0,
    0,
    0,
    22,
    0,
    0,
    22,
    0,
    0,
];

// The states: 0-7 take more length modifiers (bare, l, ll, h, hh, L, z or t, j), the others name the
// argument type to read.
const S_BARE: u32 = 0;
const S_LPRE: u32 = 1;
const S_LLPRE: u32 = 2;
const S_HPRE: u32 = 3;
const S_HHPRE: u32 = 4;
const S_ZTPRE: u32 = 6;
const S_JPRE: u32 = 7;
const S_STOP: u32 = 8;
const S_PTR: u32 = 9;
const S_INT: u32 = 10;
const S_UINT: u32 = 11;
const S_ULLONG: u32 = 12;
const S_LONG: u32 = 13;
const S_ULONG: u32 = 14;
const S_SHORT: u32 = 15;
const S_USHORT: u32 = 16;
const S_CHAR: u32 = 17;
const S_UCHAR: u32 = 18;
const S_LLONG: u32 = 19;
const S_SIZET: u32 = 20;
const S_IMAX: u32 = 21;
const S_UMAX: u32 = 22;
const S_PDIFF: u32 = 23;
const S_UIPTR: u32 = 24;
const S_DBL: u32 = 25;
const S_LDBL: u32 = 26;
const S_NOARG: u32 = 27;

// One argument: an integer (as uintmax_t), a double or a pointer.
struct Arg {
    pub i: u64,
    pub f: f64,
}

// Read the next argument of type `ty`. A long double cannot be read: Super-C has no type of its size.
fn pop_arg(ty: u32, ap: &mut va_list) Arg {
    let mut a = Arg { i: 0, f: 0.0 };
    if ty == S_PTR || ty == S_UIPTR {
        a.i = ((unsafe va_arg(*ap, *mut void)) as usize) as u64;
    } else if ty == S_INT {
        a.i = ((unsafe va_arg(*ap, i32)) as i64) as u64;
    } else if ty == S_UINT {
        a.i = unsafe va_arg(*ap, u32);
    } else if ty == S_LONG || ty == S_PDIFF {
        a.i = ((unsafe va_arg(*ap, isize)) as i64) as u64;
    } else if ty == S_ULONG || ty == S_SIZET {
        a.i = (unsafe va_arg(*ap, usize)) as u64;
    } else if ty == S_ULLONG || ty == S_UMAX {
        a.i = unsafe va_arg(*ap, u64);
    } else if ty == S_LLONG || ty == S_IMAX {
        a.i = (unsafe va_arg(*ap, i64)) as u64;
    } else if ty == S_SHORT {
        a.i = (((unsafe va_arg(*ap, i32)) as i16) as i64) as u64;
    } else if ty == S_USHORT {
        a.i = (unsafe va_arg(*ap, i32)) as u16;
    } else if ty == S_CHAR {
        a.i = (((unsafe va_arg(*ap, i32)) as i8) as i64) as u64;
    } else if ty == S_UCHAR {
        a.i = (unsafe va_arg(*ap, i32)) as u8;
    } else if ty == S_DBL {
        a.f = unsafe va_arg(*ap, f64);
    }
    return a;
}

// The decimal number at `*s`, advancing it; -1 on an int overflow.
const fn getint(s: &mut *const u8) i32 {
    let mut i: i32 = 0;
    while isdigit(unsafe (*s)[0]) != 0 {
        let d = (unsafe (*s)[0] - 48) as i32;
        if i < 0 {
            // Overflowed: stays -1.
        } else if i > INT_MAX / 10 || d > INT_MAX - 10 * i {
            i = -1;
        } else {
            i = 10 * i + d;
        }
        *s = unsafe (*s + 1);
    }
    return i;
}

// musl's `wcrtomb`: character `wc` as bytes at `mb` (up to 4), their count, or -1 with EILSEQ. In the C
// locale a character is an ASCII code or a byte-valued code unit; under a UTF-8 LC_CTYPE it is UTF-8.
fn wc_byte(wc: i32, mb: *mut u8) i32 {
    let u = wc as u32;
    if u < 0x80 {
        unsafe mb[0] = u as u8;
        return 1;
    }
    if !utf8_ctype() {
        if u.wrapping_sub(0xdf80) < 0x80 {
            unsafe mb[0] = u as u8;
            return 1;
        }
    } else if u < 0x800 {
        unsafe mb[0] = (0xc0 | u >> 6) as u8;
        unsafe mb[1] = (0x80 | u & 0x3f) as u8;
        return 2;
    } else if u < 0xd800 || u.wrapping_sub(0xe000) < 0x2000 {
        unsafe mb[0] = (0xe0 | u >> 12) as u8;
        unsafe mb[1] = (0x80 | u >> 6 & 0x3f) as u8;
        unsafe mb[2] = (0x80 | u & 0x3f) as u8;
        return 3;
    } else if u.wrapping_sub(0x10000) < 0x100000 {
        unsafe mb[0] = (0xf0 | u >> 18) as u8;
        unsafe mb[1] = (0x80 | u >> 12 & 0x3f) as u8;
        unsafe mb[2] = (0x80 | u >> 6 & 0x3f) as u8;
        unsafe mb[3] = (0x80 | u & 0x3f) as u8;
        return 4;
    }
    set_errno(25);
    return -1;
}

// musl's `printf_core`: format `fmt` with the arguments at `ap` to `o`; with `o` null, only scan for
// positional arguments (`%n$`), reading them into `nl_arg` by their `nl_type`. The count of bytes, or -1
// with errno EINVAL or EOVERFLOW.
fn printf_core(o0: *mut Out, fmt: *const char, ap: &mut va_list, nl_arg: *mut Arg, nl_type: *mut u32) i32 {
    let mut s = fmt as *const u8;
    let mut l10n = false;
    let mut cnt: i32 = 0;
    let mut l: i32 = 0;
    let mut buf = [0u8; 55];
    let bufp = (&mut buf[0]) as *mut u8;
    let prefixes = "-+   0X0x".ptr();
    // Each pass consumes literal text or one conversion of the finite format.
    loop {
        if l > INT_MAX - cnt {
            set_errno(EOVERFLOW);
            return -1;
        }
        cnt += l;
        if unsafe s[0] == 0 {
            break;
        }
        // Literal text and %% specifiers.
        let a0 = s;
        while unsafe s[0] != 0 && unsafe s[0] != 37 {
            s = unsafe (s + 1);
        }
        let mut zl = s;
        while unsafe s[0] == 37 && unsafe s[1] == 37 {
            zl = unsafe (zl + 1);
            s = unsafe (s + 2);
        }
        let lit = zl as usize - a0 as usize;
        if lit > (INT_MAX - cnt) as usize {
            set_errno(EOVERFLOW);
            return -1;
        }
        l = lit as i32;
        if o0 != null {
            out(unsafe &mut *o0, a0, lit);
        }
        if l != 0 {
            continue;
        }
        let argpos: i32 = if isdigit(unsafe s[1]) != 0 && unsafe s[2] == 36 {
            l10n = true;
            let v = (unsafe s[1] - 48) as i32;
            s = unsafe (s + 3);
            v;
        } else {
            s = unsafe (s + 1);
            -1;
        };
        // Modifier flags.
        let mut fl: u32 = 0;
        while ((unsafe s[0]) as u32).wrapping_sub(32) < 32 && (FLAGMASK & 1u32 << (unsafe s[0]) as u32 - 32) != 0 {
            fl |= 1u32 << (unsafe s[0]) as u32 - 32;
            s = unsafe (s + 1);
        }
        // Field width.
        let mut w: i32 = 0;
        if unsafe s[0] == 42 {
            if isdigit(unsafe s[1]) != 0 && unsafe s[2] == 36 {
                l10n = true;
                let k = (unsafe s[1] - 48) as usize;
                unsafe nl_type[k] = S_INT;
                w = (unsafe nl_arg[k].i) as i32;
                s = unsafe (s + 3);
            } else if !l10n {
                w = if o0 != null {
                    unsafe va_arg(*ap, i32);
                } else {
                    0;
                };
                s = unsafe (s + 1);
            } else {
                set_errno(EINVAL);
                return -1;
            }
            if w < 0 {
                fl |= LEFT_ADJ;
                w = w.wrapping_neg();
            }
        } else {
            w = getint(&mut s);
            if w < 0 {
                set_errno(EOVERFLOW);
                return -1;
            }
        }
        // Precision.
        let mut p: i32 = -1;
        let mut xp = false;
        if unsafe s[0] == 46 && unsafe s[1] == 42 {
            if isdigit(unsafe s[2]) != 0 && unsafe s[3] == 36 {
                let k = (unsafe s[2] - 48) as usize;
                unsafe nl_type[k] = S_INT;
                p = (unsafe nl_arg[k].i) as i32;
                s = unsafe (s + 4);
            } else if !l10n {
                p = if o0 != null {
                    unsafe va_arg(*ap, i32);
                } else {
                    0;
                };
                s = unsafe (s + 2);
            } else {
                set_errno(EINVAL);
                return -1;
            }
            xp = p >= 0;
        } else if unsafe s[0] == 46 {
            s = unsafe (s + 1);
            p = getint(&mut s);
            xp = true;
        }
        // The specifier state machine: at most `hh`/`ll` and the conversion.
        let mut st: u32 = 0;
        let mut ps: u32 = 0;
        loop {
            let c = (unsafe s[0]) as u32;
            if c.wrapping_sub(65) > 57 {
                set_errno(EINVAL);
                return -1;
            }
            ps = st;
            st = unsafe PF_STATES[(st * 58 + c - 65) as usize];
            s = unsafe (s + 1);
            if st.wrapping_sub(1) >= S_STOP {
                break;
            }
        }
        if st == 0 {
            set_errno(EINVAL);
            return -1;
        }
        let mut arg = Arg { i: 0, f: 0.0 };
        if st == S_NOARG {
            if argpos >= 0 {
                set_errno(EINVAL);
                return -1;
            }
        } else if argpos >= 0 {
            unsafe nl_type[argpos as usize] = st;
            arg = unsafe nl_arg[argpos as usize];
        } else if o0 != null {
            if st == S_LDBL {
                set_errno(EINVAL);
                return -1;
            }
            arg = pop_arg(st, ap);
        } else {
            return 0;
        }
        if o0 == null {
            continue;
        }
        let o = unsafe &mut *o0;
        let zend = unsafe (bufp + 55);
        let mut a: *const u8 = zend;
        let mut zz: *const u8 = zend;
        let mut prefix: usize = 0;
        let mut pl: i32 = 0;
        let mut t = (unsafe *(s - 1)) as i32;
        // %ls and %lc are %S and %C.
        if ps != 0 && (t & 15) == 3 {
            t &= ~32;
        }
        if (fl & LEFT_ADJ) != 0 {
            fl &= ~ZERO_PAD;
        }
        let mut numeric = false;
        if t == 110 {
            let q = arg.i as usize;
            if ps == S_BARE {
                unsafe *(q as *mut i32) = cnt;
            } else if ps == S_LPRE {
                unsafe *(q as *mut isize) = cnt as isize;
            } else if ps == S_LLPRE {
                unsafe *(q as *mut i64) = cnt;
            } else if ps == S_HPRE {
                unsafe *(q as *mut u16) = cnt as u16;
            } else if ps == S_HHPRE {
                unsafe *(q as *mut u8) = cnt as u8;
            } else if ps == S_ZTPRE {
                unsafe *(q as *mut usize) = cnt as usize;
            } else if ps == S_JPRE {
                unsafe *(q as *mut u64) = cnt as u64;
            }
            l = 0;
            continue;
        } else if t == 112 || t == 120 || t == 88 {
            if t == 112 {
                // musl's `MAX(p, 2*sizeof(void*))` compares unsigned: no precision (-1) stays none.
                if p >= 0 {
                    p = imax(p, 8);
                }
                t = 120;
                fl |= ALT_FORM;
            }
            a = fmt_x(arg.i, zend, (t & 32) as u8);
            if arg.i != 0 && (fl & ALT_FORM) != 0 {
                prefix = (t >> 4) as usize;
                pl = 2;
            }
            numeric = true;
        } else if t == 111 {
            a = fmt_o(arg.i, zend);
            let len = (zend as usize - a as usize) as i32;
            if (fl & ALT_FORM) != 0 && p < len + 1 {
                p = len + 1;
            }
            numeric = true;
        } else if t == 100 || t == 105 || t == 117 {
            if t != 117 {
                pl = 1;
                if arg.i > 0x7FFFFFFFFFFFFFFF {
                    arg.i = arg.i.wrapping_neg();
                } else if (fl & MARK_POS) != 0 {
                    prefix = 1;
                } else if (fl & PAD_POS) != 0 {
                    prefix = 2;
                } else {
                    pl = 0;
                }
            }
            a = fmt_u(arg.i, zend);
            numeric = true;
        } else if t == 99 {
            p = 1;
            a = unsafe (zend - 1);
            unsafe *(a as *mut u8) = arg.i as u8;
            fl &= ~ZERO_PAD;
        } else if t == 109 || t == 115 {
            a = if t == 109 {
                strerror(unsafe ERRNO) as *const u8;
            } else if arg.i != 0 {
                (arg.i as usize) as *const u8;
            } else {
                "(null)".ptr();
            };
            let lim = if p < 0 {
                INT_MAX as usize;
            } else {
                p as usize;
            };
            zz = unsafe (a + strnlen(a as *const char, lim));
            if p < 0 && unsafe zz[0] != 0 {
                set_errno(EOVERFLOW);
                return -1;
            }
            p = (zz as usize - a as usize) as i32;
            fl &= ~ZERO_PAD;
        } else if t == 67 || t == 83 {
            let mut wc = [0i32; 2];
            let mut ws = (arg.i as usize) as *const i32;
            if t == 67 {
                wc[0] = arg.i as i32;
                ws = &wc[0];
                p = -1;
            }
            let mut mb = [0u8; 4];
            let mut i: usize = 0;
            let mut ml: i32 = 0;
            let lim = (p as u32) as usize;
            let mut wp = ws;
            while i < lim && unsafe wp[0] != 0 {
                ml = wc_byte(unsafe wp[0], &mut mb[0]);
                if ml < 0 || ml as usize > lim - i {
                    break;
                }
                wp = unsafe (wp + 1);
                i += ml as usize;
            }
            if ml < 0 {
                return -1;
            }
            if i > INT_MAX as usize {
                set_errno(EOVERFLOW);
                return -1;
            }
            p = i as i32;
            pad(o, 32, w, p, fl);
            let mut k: usize = 0;
            wp = ws;
            while k < p as usize && unsafe wp[0] != 0 {
                let n = wc_byte(unsafe wp[0], &mut mb[0]);
                if k + n as usize > p as usize {
                    break;
                }
                out(o, &mb[0], n as usize);
                wp = unsafe (wp + 1);
                k += n as usize;
            }
            pad(o, 32, w, p, fl ^ LEFT_ADJ);
            l = imax(w, p);
            continue;
        } else {
            // e f g a and their uppercase forms.
            if xp && p < 0 {
                set_errno(EOVERFLOW);
                return -1;
            }
            l = fmt_fp(o, arg.f, w, p, fl, t);
            if l < 0 {
                set_errno(EOVERFLOW);
                return -1;
            }
            continue;
        }
        if numeric {
            if xp && p < 0 {
                set_errno(EOVERFLOW);
                return -1;
            }
            if xp {
                fl &= ~ZERO_PAD;
            }
            if arg.i == 0 && p == 0 {
                a = zend;
            } else {
                p = imax(p, (zend as usize - a as usize) as i32 + (arg.i == 0) as i32);
            }
        }
        let len = (zz as usize - a as usize) as i32;
        if p < len {
            p = len;
        }
        if p > INT_MAX - pl {
            set_errno(EOVERFLOW);
            return -1;
        }
        if w < pl + p {
            w = pl + p;
        }
        if w > INT_MAX - cnt {
            set_errno(EOVERFLOW);
            return -1;
        }
        pad(o, 32, w, pl + p, fl);
        out(o, unsafe (prefixes + prefix), pl as usize);
        pad(o, 48, w, pl + p, fl ^ ZERO_PAD);
        pad(o, 48, p, len, 0);
        out(o, a, len as usize);
        pad(o, 32, w, pl + p, fl ^ LEFT_ADJ);
        l = w;
    }
    if o0 != null {
        return cnt;
    }
    if !l10n {
        return 0;
    }
    let mut i: usize = 1;
    while i <= NL_ARGMAX && unsafe nl_type[i] != 0 {
        if unsafe nl_type[i] == S_LDBL {
            set_errno(EINVAL);
            return -1;
        }
        unsafe nl_arg[i] = pop_arg(unsafe nl_type[i], ap);
        i += 1;
    }
    while i <= NL_ARGMAX && unsafe nl_type[i] == 0 {
        i += 1;
    }
    if i <= NL_ARGMAX {
        set_errno(EINVAL);
        return -1;
    }
    return 1;
}

// Format into `o`: musl's `vfprintf` minus the stream locking (wasm has one thread). An unbuffered
// stream gets an 80-byte buffer for the call, as musl gives it, so one call writes few pieces. The count,
// or -1.
fn vformat(o: &mut Out, fmt: *const char, ap: va_list) i32 {
    let mut nl_type = [0u32; 10];
    let mut nl_arg = [Arg { i: 0, f: 0.0 }; 10];
    let mut ap2 = ap;
    if printf_core(null, fmt, &mut ap2, &mut nl_arg[0], &mut nl_type[0]) < 0 {
        return -1;
    }
    if o.f == null {
        return printf_core(o, fmt, &mut ap2, &mut nl_arg[0], &mut nl_type[0]);
    }
    let f = unsafe &mut *o.f;
    let olderr = f.flags & F_ERR;
    f.flags &= ~F_ERR;
    let mut tmp = [0u8; 80];
    let nobuf = (f.flags & F_NOBUF) != 0 && f.cap == 0;
    if nobuf {
        f.flags &= ~F_NOBUF;
        f.buf = &mut tmp[0];
        f.cap = 80;
        f.wlen = 0;
    }
    let mut ret = printf_core(o, fmt, &mut ap2, &mut nl_arg[0], &mut nl_type[0]);
    if nobuf {
        let _ = flush_out(f);
        f.flags |= F_NOBUF;
        f.buf = null;
        f.cap = 0;
    }
    if (f.flags & F_ERR) != 0 {
        ret = -1;
    }
    f.flags |= olderr;
    return ret;
}

/// Format to stream `f`; the byte count, or negative.
@export("vfprintf")
pub fn vfprintf(f: *mut FILE, fmt: *const char, ap: va_list) i32 {
    let mut o = Out { f: f as *mut Stream, buf: null, cap: 0, len: 0 };
    return vformat(&mut o, fmt, ap);
}

/// Format to stream `f`.
@export("fprintf")
pub fn fprintf(f: *mut FILE, fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let r = vfprintf(f, fmt, ap);
    va_end(ap);
    return r;
}

/// Format to stdout.
@export("vprintf")
pub fn vprintf(fmt: *const char, ap: va_list) i32 {
    return vfprintf(stdio_stream(1), fmt, ap);
}

/// Format to stdout.
@export("printf")
pub fn printf(fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let r = vfprintf(stdio_stream(1), fmt, ap);
    va_end(ap);
    return r;
}

/// Format into `buf`: at most `n - 1` bytes and a NUL; the length the whole output has, or negative.
@export("vsnprintf")
pub fn vsnprintf(buf: *mut char, n: usize, fmt: *const char, ap: va_list) i32 {
    let mut o = Out {
        f: null,
        buf: buf as *mut u8,
        cap: if n == 0 {
            0usize;
        } else {
            n - 1;
        },
        len: 0,
    };
    let r = vformat(&mut o, fmt, ap);
    if n != 0 {
        let end = if o.len < o.cap {
            o.len;
        } else {
            o.cap;
        };
        unsafe buf[end] = 0 as char;
    }
    return r;
}

/// Format into `buf`, bounded by `n`.
@export("snprintf")
pub fn snprintf(buf: *mut char, n: usize, fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let r = vsnprintf(buf, n, fmt, ap);
    va_end(ap);
    return r;
}

/// Format into `buf`, unbounded.
@export("vsprintf")
pub fn vsprintf(buf: *mut char, fmt: *const char, ap: va_list) i32 {
    return vsnprintf(buf, 0x7FFFFFFF, fmt, ap);
}

/// Format into `buf`, unbounded.
@export("sprintf")
pub fn sprintf(buf: *mut char, fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let r = vsnprintf(buf, 0x7FFFFFFF, fmt, ap);
    va_end(ap);
    return r;
}

// ---- scanf ---------------------------------------------------------------------------------------------
// musl's `vfscanf`, over a stream or a string. A long double conversion (`%Lf`) fails as a format error, as
// `%Lf` does in printf: Super-C has no type of its size.

const SIZE_HH: i32 = -2;
const SIZE_H: i32 = -1;
const SIZE_DEF: i32 = 0;
const SIZE_L: i32 = 1;
const SIZE_LD: i32 = 2;
const SIZE_LL: i32 = 3;

// musl's `bittab`: the decoder state after the first byte of a UTF-8 sequence, by that byte less 0xc2.
const BITTAB: [u32; 51] = [
    0xc0000002,
    0xc0000003,
    0xc0000004,
    0xc0000005,
    0xc0000006,
    0xc0000007,
    0xc0000008,
    0xc0000009,
    0xc000000a,
    0xc000000b,
    0xc000000c,
    0xc000000d,
    0xc000000e,
    0xc000000f,
    0xc0000010,
    0xc0000011,
    0xc0000012,
    0xc0000013,
    0xc0000014,
    0xc0000015,
    0xc0000016,
    0xc0000017,
    0xc0000018,
    0xc0000019,
    0xc000001a,
    0xc000001b,
    0xc000001c,
    0xc000001d,
    0xc000001e,
    0xc000001f,
    0xb3000000,
    0xc3000001,
    0xc3000002,
    0xc3000003,
    0xc3000004,
    0xc3000005,
    0xc3000006,
    0xc3000007,
    0xc3000008,
    0xc3000009,
    0xc300000a,
    0xc300000b,
    0xc300000c,
    0xd300000d,
    0xc300000e,
    0xc300000f,
    0xbb0c0000,
    0xc30c0001,
    0xc30c0002,
    0xc30c0003,
    0xdb0c0004,
];

// musl's `mbrtowc` of the one byte `b` in state `*st` (0 between characters): 1 (0 for NUL) with the
// character in `*wc`, -2 while a sequence goes on, or -1 with EILSEQ.
fn mb_byte(st: &mut u32, b: u8, wc: &mut i32) i32 {
    let c = *st;
    if c == 0 {
        if b < 0x80 {
            *wc = b;
            return (b != 0) as i32;
        }
        if !utf8_ctype() {
            *wc = 0xdfff & (b as i8) as i32;
            return 1;
        }
        if (b as u32).wrapping_sub(0xc2) > 0xf4 - 0xc2 {
            set_errno(25);
            return -1;
        }
        *st = unsafe BITTAB[(b - 0xc2) as usize];
        return -2;
    }
    let b3 = (b >> 3) as i32;
    if ((b3 - 0x10 | b3 + (c as i32 >> 26)) & ~7) != 0 {
        *st = 0;
        set_errno(25);
        return -1;
    }
    let n = c << 6 | (b - 0x80) as u32;
    if (n & 1u32 << 31) == 0 {
        *st = 0;
        *wc = n as i32;
        return 1;
    }
    *st = n;
    return -2;
}

// Store `i` through `dest`, as the integer type of `size`.
const fn store_int(dest: *mut void, size: i32, i: u64) {
    if dest == null {
        return;
    }
    if size == SIZE_HH {
        unsafe *(dest as *mut u8) = i as u8;
    } else if size == SIZE_H {
        unsafe *(dest as *mut u16) = i as u16;
    } else if size == SIZE_DEF {
        unsafe *(dest as *mut u32) = i as u32;
    } else if size == SIZE_L {
        unsafe *(dest as *mut usize) = i as usize;
    } else if size == SIZE_LL {
        unsafe *(dest as *mut u64) = i;
    }
}

// The `n`th pointer argument (`%n$`) after `ap`.
fn arg_n(ap: va_list, n: u32) *mut void {
    let ap2 = ap;
    for _ in 1..n {
        let _ = unsafe va_arg(ap2, *mut void);
    }
    return unsafe va_arg(ap2, *mut void);
}

// The bytes `f` read since its `limit`.
const fn scnt(f: &Scan) u64 {
    return f.used() as u64;
}

// musl's `vfscanf`: read `f` by format `fmt`, storing through the pointers at `ap`; the count of
// conversions stored, or -1 when the input ends or fails before the first.
fn vscan(f: &mut Scan, fmt: *const char, ap0: va_list) i32 {
    let ap = ap0;
    let mut matches: i32 = 0;
    let mut pos: u64 = 0;
    let mut scanset = [0u8; 257];
    let mut alloc = false;
    let mut s: *mut u8 = null;
    let mut wcs: *mut i32 = null;
    // 1 for an input, format or allocation failure, 2 for a matching failure.
    let mut failed: i32 = 0;
    let mut p = fmt as *const u8;
    while unsafe p[0] != 0 {
        alloc = false;
        let pc = unsafe p[0];
        if isspace(pc) != 0 {
            while isspace(unsafe p[1]) != 0 {
                p = unsafe (p + 1);
            }
            f.limit(0);
            while isspace(f.get()) != 0 {}
            f.unget();
            pos += scnt(f);
            p = unsafe (p + 1);
            continue;
        }
        if pc != 37 || unsafe p[1] == 37 {
            f.limit(0);
            let mut c: i32 = 0;
            if pc == 37 {
                p = unsafe (p + 1);
                c = f.get();
                while isspace(c) != 0 {
                    c = f.get();
                }
            } else {
                c = f.get();
            }
            if c != (unsafe p[0]) as i32 {
                f.unget();
                failed = if c < 0 {
                    1;
                } else {
                    2;
                };
                break;
            }
            pos += scnt(f);
            p = unsafe (p + 1);
            continue;
        }
        p = unsafe (p + 1);
        let mut dest: *mut void = null;
        if unsafe p[0] == 42 {
            p = unsafe (p + 1);
        } else if isdigit(unsafe p[0]) != 0 && unsafe p[1] == 36 {
            dest = arg_n(ap, unsafe p[0] - 48);
            p = unsafe (p + 2);
        } else {
            dest = unsafe va_arg(ap, *mut void);
        }
        let mut width: i32 = 0;
        while isdigit(unsafe p[0]) != 0 {
            width = width.wrapping_mul(10).wrapping_add(unsafe p[0] - 48);
            p = unsafe (p + 1);
        }
        if unsafe p[0] == 109 {
            wcs = null;
            s = null;
            alloc = dest != null;
            p = unsafe (p + 1);
        }
        let mut size = SIZE_DEF;
        let c0 = unsafe p[0];
        p = unsafe (p + 1);
        if c0 == 104 {
            if unsafe p[0] == 104 {
                p = unsafe (p + 1);
                size = SIZE_HH;
            } else {
                size = SIZE_H;
            }
        } else if c0 == 108 {
            if unsafe p[0] == 108 {
                p = unsafe (p + 1);
                size = SIZE_LL;
            } else {
                size = SIZE_L;
            }
        } else if c0 == 106 {
            size = SIZE_LL;
        } else if c0 == 122 || c0 == 116 {
            size = SIZE_L;
        } else if c0 == 76 {
            size = SIZE_LD;
        } else if c0 != 0 && unsafe *chrnul("diouxaefgAEFGXsc[SCpn".ptr(), c0) != 0 {
            p = unsafe (p - 1);
        } else {
            failed = 1;
            break;
        }
        let mut t = (unsafe p[0]) as i32;
        // A format ending in a length modifier: musl reads past its end.
        if t == 0 {
            failed = 1;
            break;
        }
        // C and S: lc and ls.
        if (t & 0x2f) == 3 {
            t |= 32;
            size = SIZE_L;
        }
        if t == 99 {
            if width < 1 {
                width = 1;
            }
        } else if t == 110 {
            store_int(dest, size, pos);
            p = unsafe (p + 1);
            continue;
        } else if t != 91 {
            f.limit(0);
            while isspace(f.get()) != 0 {}
            f.unget();
            pos += scnt(f);
        }
        f.limit(width);
        if f.get() < 0 {
            failed = 1;
            break;
        }
        f.unget();
        if t == 115 || t == 99 || t == 91 {
            if t == 99 || t == 115 {
                for i in 0..257usize {
                    unsafe scanset[i] = 255;
                }
                scanset[0] = 0;
                if t == 115 {
                    for w in [9u8, 10, 11, 12, 13, 32] {
                        unsafe scanset[1 + w as usize] = 0;
                    }
                }
            } else {
                p = unsafe (p + 1);
                let mut invert: u8 = 0;
                if unsafe p[0] == 94 {
                    p = unsafe (p + 1);
                    invert = 1;
                }
                for i in 0..257usize {
                    unsafe scanset[i] = invert;
                }
                scanset[0] = 0;
                if unsafe p[0] == 45 {
                    p = unsafe (p + 1);
                    scanset[1 + 45] = 1 - invert;
                } else if unsafe p[0] == 93 {
                    p = unsafe (p + 1);
                    scanset[1 + 93] = 1 - invert;
                }
                while unsafe p[0] != 93 {
                    if unsafe p[0] == 0 {
                        failed = 1;
                        break;
                    }
                    if unsafe p[0] == 45 && unsafe p[1] != 0 && unsafe p[1] != 93 {
                        let mut c = unsafe *(p - 1);
                        p = unsafe (p + 1);
                        while c < unsafe p[0] {
                            unsafe scanset[1 + c as usize] = 1 - invert;
                            c += 1;
                        }
                    }
                    unsafe scanset[1 + (unsafe p[0]) as usize] = 1 - invert;
                    p = unsafe (p + 1);
                }
                if failed != 0 {
                    break;
                }
            }
            wcs = null;
            s = null;
            let mut i: usize = 0;
            let mut k: usize = if t == 99 {
                width as usize + 1;
            } else {
                31usize;
            };
            if size == SIZE_L {
                if alloc {
                    wcs = malloc(k * 4) as *mut i32;
                    if wcs == null {
                        failed = 1;
                        break;
                    }
                } else {
                    wcs = dest as *mut i32;
                }
                let mut st: u32 = 0;
                let mut c = f.get();
                while unsafe scanset[(c + 1) as usize] != 0 {
                    let mut wc: i32 = 0;
                    let r = mb_byte(&mut st, c as u8, &mut wc);
                    if r == -1 {
                        failed = 1;
                        break;
                    }
                    if r != -2 {
                        if wcs != null {
                            unsafe wcs[i] = wc;
                            i += 1;
                        }
                        if alloc && i == k {
                            k += k + 1;
                            let tmp = realloc(wcs, k * 4) as *mut i32;
                            if tmp == null {
                                failed = 1;
                                break;
                            }
                            wcs = tmp;
                        }
                    }
                    c = f.get();
                }
                if failed != 0 {
                    break;
                }
                if st != 0 {
                    failed = 1;
                    break;
                }
            } else if alloc {
                s = malloc(k) as *mut u8;
                if s == null {
                    failed = 1;
                    break;
                }
                let mut c = f.get();
                while unsafe scanset[(c + 1) as usize] != 0 {
                    unsafe s[i] = c as u8;
                    i += 1;
                    if i == k {
                        k += k + 1;
                        let tmp = realloc(s, k) as *mut u8;
                        if tmp == null {
                            failed = 1;
                            break;
                        }
                        s = tmp;
                    }
                    c = f.get();
                }
                if failed != 0 {
                    break;
                }
            } else if dest != null {
                s = dest as *mut u8;
                let mut c = f.get();
                while unsafe scanset[(c + 1) as usize] != 0 {
                    unsafe s[i] = c as u8;
                    i += 1;
                    c = f.get();
                }
            } else {
                while unsafe scanset[(f.get() + 1) as usize] != 0 {}
            }
            f.unget();
            if scnt(f) == 0 || t == 99 && scnt(f) != width as u64 {
                failed = 2;
                break;
            }
            if alloc {
                if size == SIZE_L {
                    unsafe *(dest as *mut *mut i32) = wcs;
                } else {
                    unsafe *(dest as *mut *mut u8) = s;
                }
            }
            if t != 99 {
                if wcs != null {
                    unsafe wcs[i] = 0;
                }
                if s != null {
                    unsafe s[i] = 0;
                }
            }
        } else if (t | 32) == 97 || (t | 32) == 101 || (t | 32) == 102 || (t | 32) == 103 {
            if size == SIZE_LD {
                failed = 1;
                break;
            }
            // musl's `__floatscan` reads nothing for another size (`%hf`).
            if size != SIZE_DEF && size != SIZE_L {
                failed = 2;
                break;
            }
            let y = floatscan(f, size, false);
            if scnt(f) == 0 {
                failed = 2;
                break;
            }
            if dest != null {
                if size == SIZE_DEF {
                    unsafe *(dest as *mut f32) = y as f32;
                } else if size == SIZE_L {
                    unsafe *(dest as *mut f64) = y;
                }
            }
        } else if t < 128 && unsafe *chrnul("pXxoudi".ptr(), t as u8) != 0 {
            let base: u32 = if t == 112 || t == 88 || t == 120 {
                16;
            } else if t == 111 {
                8;
            } else if t == 100 || t == 117 {
                10;
            } else {
                0;
            };
            let x = intscan(f, base, ~0u64, false);
            if scnt(f) == 0 {
                failed = 2;
                break;
            }
            if t == 112 && dest != null {
                unsafe *(dest as *mut *mut void) = (x as usize) as *mut void;
            } else {
                store_int(dest, size, x);
            }
        }
        pos += scnt(f);
        if dest != null {
            matches += 1;
        }
        p = unsafe (p + 1);
    }
    if failed == 1 && matches == 0 {
        matches -= 1;
    }
    if failed != 0 && alloc {
        free(s);
        free(wcs);
    }
    return matches;
}

// `vscan` over stream `f`: -1 at once when it cannot be read, as musl's `__toread` answers.
fn vscan_stream(f: *mut FILE, fmt: *const char, ap: va_list) i32 {
    let s = st(f);
    if (s.flags & F_READ) == 0 {
        s.flags |= F_ERR;
        return -1;
    }
    let mut c = scan_of(2, null, s);
    return vscan(&mut c, fmt, ap);
}

/// Read string `s` by format `fmt`; the count of conversions stored, or -1 when `s` ends before the first.
@export("sscanf")
pub fn sscanf(s: *const char, fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let mut c = scan_of(1, s as *const u8, null);
    let r = vscan(&mut c, fmt, ap);
    va_end(ap);
    return r;
}

/// Read stream `f` by format `fmt`; the count of conversions stored, or -1 when the input ends or fails
/// before the first.
@export("fscanf")
pub fn fscanf(f: *mut FILE, fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let r = vscan_stream(f, fmt, ap);
    va_end(ap);
    return r;
}

/// Read stdin by format `fmt`, as `fscanf`.
@export("scanf")
pub fn scanf(fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let r = vscan_stream(stdio_stream(0), fmt, ap);
    va_end(ap);
    return r;
}

// ---- float conversions ---------------------------------------------------------------------------------
// musl's `__floatscan` with long double as double (LDBL_MANT_DIG 53, as on its 64-bit-long-double-free
// targets): the result rounds correctly to `bits` bits once, as wasi-libc's does through its 113-bit
// long double.

extern "C" "math.h" {
    fn scalbn(x: f64, n: i32) f64;
    fn fmod(x: f64, y: f64) f64;
    fn copysign(x: f64, y: f64) f64;
    fn fabs(x: f64) f64;
}

const KMAX: usize = 128;
const KMASK: usize = KMAX - 1;
const LDBL_MANT_DIG: i32 = 53;
const DBL_MAX: f64 = 1.7976931348623157e308;
const DBL_MIN: f64 = 2.2250738585072014e-308;
const INF: f64 = nan_of(0x7ff0000000000000);
// C's NAN: the positive quiet NaN.
const NAN: f64 = nan_of(0x7ff8000000000000);

const fn nan_of(b: u64) f64 {
    let u = Bits64 { u: b };
    return u.f;
}

// musl's `scanexp`: the exponent after 'e' or 'p', or i64::MIN when none follows.
fn scanexp(f: &mut Scan, pok: bool) i64 {
    let mut neg = false;
    let mut c = f.get();
    if c == 43 || c == 45 {
        neg = c == 45;
        c = f.get();
        if (c as u32).wrapping_sub(48) >= 10 && pok {
            f.unget();
        }
    }
    if (c as u32).wrapping_sub(48) >= 10 {
        f.unget();
        return -9223372036854775807 - 1;
    }
    let mut x: i32 = 0;
    while (c as u32).wrapping_sub(48) < 10 && x < INT_MAX / 10 {
        x = 10 * x + c - 48;
        c = f.get();
    }
    let mut y = x as i64;
    while (c as u32).wrapping_sub(48) < 10 && y < 9223372036854775807 / 100 {
        y = 10 * y + (c - 48) as i64;
        c = f.get();
    }
    while (c as u32).wrapping_sub(48) < 10 {
        c = f.get();
    }
    f.unget();
    return if neg {
        0 - y;
    } else {
        y;
    };
}

const P10S: [u32; 8] = [10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000];
// LD_B1B_MAX: 2^53 - 1 in base-10^9 words.
const TH: [u32; 2] = [9007199, 254740991];

fn decfloat(f: &mut Scan, c0: i32, bits0: i32, emin: i32, sign: i32, pok: bool) f64 {
    let mut x = [0u32; KMAX];
    let mut c = c0;
    let mut bits = bits0;
    let mut j: i32 = 0;
    let mut k: usize = 0;
    let mut lrp: i64 = 0;
    let mut dc: i64 = 0;
    let mut lnz: i64 = 0;
    let mut gotdig = false;
    let mut gotrad = false;
    let mut e2: i32 = 0;
    let emax = 0 - emin - bits + 3;
    let mut denormal = false;
    let mut frac: f64 = 0.0;
    let mut bias: f64 = 0.0;
    let sg = sign as f64;
    // Leading zeros take no buffer space.
    while c == 48 {
        gotdig = true;
        c = f.get();
    }
    if c == 46 {
        gotrad = true;
        c = f.get();
        while c == 48 {
            gotdig = true;
            lrp -= 1;
            c = f.get();
        }
    }
    x[0] = 0;
    while (c as u32).wrapping_sub(48) < 10 || c == 46 {
        if c == 46 {
            if gotrad {
                break;
            }
            gotrad = true;
            lrp = dc;
        } else if k < KMAX - 3 {
            dc += 1;
            if c != 48 {
                lnz = dc;
            }
            if j != 0 {
                unsafe x[k] = unsafe x[k] * 10 + (c - 48) as u32;
            } else {
                unsafe x[k] = (c - 48) as u32;
            }
            j += 1;
            if j == 9 {
                k += 1;
                j = 0;
            }
            gotdig = true;
        } else {
            dc += 1;
            if c != 48 {
                lnz = ((KMAX - 4) * 9) as i64;
                x[KMAX - 4] |= 1;
            }
        }
        c = f.get();
    }
    if !gotrad {
        lrp = dc;
    }
    if gotdig && (c | 32) == 101 {
        let mut e10 = scanexp(f, pok);
        if e10 == -9223372036854775807 - 1 {
            if pok {
                f.unget();
            } else {
                f.bad = true;
                return 0.0;
            }
            e10 = 0;
        }
        lrp += e10;
    } else if c >= 0 {
        f.unget();
    }
    if !gotdig {
        set_errno(EINVAL);
        f.bad = true;
        return 0.0;
    }
    // Zero, handled apart from the special cases below.
    if x[0] == 0 {
        return sg * 0.0;
    }
    // Small integers without an exponent, and overflow and underflow.
    if lrp == dc && dc < 10 && (bits > 30 || x[0] >> bits as u32 == 0) {
        return sg * x[0] as f64;
    }
    if lrp > (0 - emin / 2) as i64 {
        set_errno(ERANGE);
        return sg * DBL_MAX * DBL_MAX;
    }
    if lrp < (emin - 2 * LDBL_MANT_DIG) as i64 {
        set_errno(ERANGE);
        return sg * DBL_MIN * DBL_MIN;
    }
    // Align an incomplete last word.
    if j != 0 {
        while j < 9 {
            unsafe x[k] *= 10;
            j += 1;
        }
        k += 1;
        j = 0;
    }
    let mut a: usize = 0;
    let mut z = k;
    let mut rp = lrp as i32;
    // Small to mid-size integers, even in exponent notation.
    if lnz < 9 && lnz <= rp as i64 && rp < 18 {
        if rp == 9 {
            return sg * x[0] as f64;
        }
        if rp < 9 {
            return sg * x[0] as f64 / (unsafe P10S[(8 - rp) as usize]) as f64;
        }
        let bitlim = bits - 3 * (rp - 9);
        if bitlim > 30 || x[0] >> bitlim as u32 == 0 {
            return sg * x[0] as f64 * (unsafe P10S[(rp - 10) as usize]) as f64;
        }
    }
    // Drop trailing zeros.
    while unsafe x[z - 1] == 0 {
        z -= 1;
    }
    // Align the radix point to a word boundary.
    if rp % 9 != 0 {
        let rpm9 = if rp >= 0 {
            rp % 9;
        } else {
            rp % 9 + 9;
        };
        let p10 = unsafe P10S[(8 - rpm9) as usize];
        let mut carry: u32 = 0;
        k = a;
        while k != z {
            let tmp = unsafe x[k] % p10;
            unsafe x[k] = unsafe x[k] / p10 + carry;
            carry = 1000000000 / p10 * tmp;
            if k == a && unsafe x[k] == 0 {
                a = a + 1 & KMASK;
                rp -= 9;
            }
            k += 1;
        }
        if carry != 0 {
            unsafe x[z] = carry;
            z += 1;
        }
        rp += 9 - rpm9;
    }
    // Upscale until the wanted bits are left of the radix point.
    while rp < 18 || rp == 18 && unsafe x[a] < TH[0] {
        let mut carry: u32 = 0;
        e2 -= 29;
        k = z + KMASK & KMASK;
        loop {
            let tmp = ((unsafe x[k]) as u64 << 29) + carry as u64;
            if tmp > 1000000000 {
                carry = (tmp / 1000000000) as u32;
                unsafe x[k] = (tmp % 1000000000) as u32;
            } else {
                carry = 0;
                unsafe x[k] = tmp as u32;
            }
            if k == (z + KMASK & KMASK) && k != a && unsafe x[k] == 0 {
                z = k;
            }
            if k == a {
                break;
            }
            k = k + KMASK & KMASK;
        }
        if carry != 0 {
            rp += 9;
            a = a + KMASK & KMASK;
            if a == z {
                z = z + KMASK & KMASK;
                unsafe x[z + KMASK & KMASK] |= unsafe x[z];
            }
            unsafe x[a] = carry;
        }
    }
    // Downscale until exactly the wanted bits are left of the radix point.
    let mut i: usize = 0;
    loop {
        let mut carry: u32 = 0;
        let mut sh: u32 = 1;
        i = 0;
        while i < 2 {
            k = a + i & KMASK;
            if k == z || unsafe x[k] < unsafe TH[i] {
                i = 2;
                break;
            }
            if unsafe x[a + i & KMASK] > unsafe TH[i] {
                break;
            }
            i += 1;
        }
        if i == 2 && rp == 18 {
            break;
        }
        if rp > 27 {
            sh = 9;
        }
        e2 += sh as i32;
        k = a;
        while k != z {
            let tmp = unsafe x[k] & (1u32 << sh) - 1;
            unsafe x[k] = (unsafe x[k] >> sh) + carry;
            carry = (1000000000u32 >> sh) * tmp;
            if k == a && unsafe x[k] == 0 {
                a = a + 1 & KMASK;
                i = i.wrapping_sub(1);
                rp -= 9;
            }
            k = k + 1 & KMASK;
        }
        if carry != 0 {
            if (z + 1 & KMASK) != a {
                unsafe x[z] = carry;
                z = z + 1 & KMASK;
            } else {
                unsafe x[z + KMASK & KMASK] |= 1;
            }
        }
    }
    // Assemble the wanted bits into a double.
    let mut y: f64 = 0.0;
    i = 0;
    while i < 2 {
        if (a + i & KMASK) == z {
            z = z + 1 & KMASK;
            unsafe x[z + KMASK & KMASK] = 0;
        }
        y = 1000000000.0 * y + (unsafe x[a + i & KMASK]) as f64;
        i += 1;
    }
    y *= sg;
    // Fewer bits for a subnormal result.
    if bits > LDBL_MANT_DIG + e2 - emin {
        bits = LDBL_MANT_DIG + e2 - emin;
        if bits < 0 {
            bits = 0;
        }
        denormal = true;
    }
    // A bias that forces the rounding at `bits`; the bits below go to `frac`.
    if bits < LDBL_MANT_DIG {
        bias = unsafe copysign(unsafe scalbn(1.0, 2 * LDBL_MANT_DIG - bits - 1), y);
        frac = unsafe fmod(y, unsafe scalbn(1.0, LDBL_MANT_DIG - bits));
        y -= frac;
        y += bias;
    }
    // The rest of the decimal input decides the rounding.
    if (a + i & KMASK) != z {
        let t = unsafe x[a + i & KMASK];
        if t < 500000000 && (t != 0 || (a + i + 1 & KMASK) != z) {
            frac += 0.25 * sg;
        } else if t > 500000000 {
            frac += 0.75 * sg;
        } else if t == 500000000 {
            if (a + i + 1 & KMASK) == z {
                frac += 0.5 * sg;
            } else {
                frac += 0.75 * sg;
            }
        }
        if LDBL_MANT_DIG - bits >= 2 && unsafe fmod(frac, 1.0) == 0.0 {
            frac += 1.0;
        }
    }
    y += frac;
    y -= bias;
    if (e2 + LDBL_MANT_DIG & INT_MAX) > emax - 5 {
        if unsafe fabs(y) >= 2.0 / 2.220446049250313e-16 {
            if denormal && bits == LDBL_MANT_DIG + e2 - emin {
                denormal = false;
            }
            y *= 0.5;
            e2 += 1;
        }
        if e2 + LDBL_MANT_DIG > emax || denormal && frac != 0.0 {
            set_errno(ERANGE);
        }
    }
    return unsafe scalbn(y, e2);
}

fn hexfloat(f: &mut Scan, bits0: i32, emin: i32, sign: i32, pok: bool) f64 {
    let mut bits = bits0;
    let mut x: u32 = 0;
    let mut y: f64 = 0.0;
    let mut scale: f64 = 1.0;
    let mut bias: f64 = 0.0;
    let mut gottail = false;
    let mut gotrad = false;
    let mut gotdig = false;
    let mut rp: i64 = 0;
    let mut dc: i64 = 0;
    let mut e2: i64 = 0;
    let sg = sign as f64;
    let mut c = f.get();
    // Leading zeros.
    while c == 48 {
        gotdig = true;
        c = f.get();
    }
    if c == 46 {
        gotrad = true;
        c = f.get();
        // Zeros after the radix point before the significand.
        rp = 0;
        while c == 48 {
            gotdig = true;
            rp -= 1;
            c = f.get();
        }
    }
    while (c as u32).wrapping_sub(48) < 10 || (c as u32 | 32).wrapping_sub(97) < 6 || c == 46 {
        if c == 46 {
            if gotrad {
                break;
            }
            rp = dc;
            gotrad = true;
        } else {
            gotdig = true;
            let d = if c > 57 {
                (c | 32) + 10 - 97;
            } else {
                c - 48;
            };
            if dc < 8 {
                x = x * 16 + d as u32;
            } else if dc < (LDBL_MANT_DIG / 4 + 1) as i64 {
                scale /= 16.0;
                y += d as f64 * scale;
            } else if d != 0 && !gottail {
                y += 0.5 * scale;
                gottail = true;
            }
            dc += 1;
        }
        c = f.get();
    }
    if !gotdig {
        f.unget();
        if pok {
            f.unget();
            if gotrad {
                f.unget();
            }
        } else {
            f.bad = true;
        }
        return sg * 0.0;
    }
    if !gotrad {
        rp = dc;
    }
    while dc < 8 {
        x *= 16;
        dc += 1;
    }
    if (c | 32) == 112 {
        e2 = scanexp(f, pok);
        if e2 == -9223372036854775807 - 1 {
            if pok {
                f.unget();
            } else {
                f.bad = true;
                return 0.0;
            }
            e2 = 0;
        }
    } else {
        f.unget();
    }
    e2 += 4 * rp - 32;
    if x == 0 {
        return sg * 0.0;
    }
    if e2 > (0 - emin) as i64 {
        set_errno(ERANGE);
        return sg * DBL_MAX * DBL_MAX;
    }
    if e2 < (emin - 2 * LDBL_MANT_DIG) as i64 {
        set_errno(ERANGE);
        return sg * DBL_MIN * DBL_MIN;
    }
    while x < 0x80000000 {
        if y >= 0.5 {
            x += x + 1;
            y += y - 1.0;
        } else {
            x += x;
            y += y;
        }
        e2 -= 1;
    }
    if bits as i64 > 32 + e2 - emin as i64 {
        bits = (32 + e2 - emin as i64) as i32;
        if bits < 0 {
            bits = 0;
        }
    }
    if bits < LDBL_MANT_DIG {
        bias = unsafe copysign(unsafe scalbn(1.0, 32 + LDBL_MANT_DIG - bits - 1), sg);
    }
    if bits < 32 && y != 0.0 && (x & 1) == 0 {
        x += 1;
        y = 0.0;
    }
    y = bias + sg * x as f64 + sg * y;
    y -= bias;
    if y == 0.0 {
        set_errno(ERANGE);
    }
    return unsafe scalbn(y, e2 as i32);
}

// musl's `__floatscan`: `prec` 0 for float (24 bits), 1 for double (53).
fn floatscan(f: &mut Scan, prec: i32, pok: bool) f64 {
    let bits = if prec == 0 {
        24;
    } else {
        53;
    };
    let emin = if prec == 0 {
        -125 - bits;
    } else {
        -1021 - bits;
    };
    let mut sign: i32 = 1;
    let mut c = f.get();
    while isspace(c) != 0 {
        c = f.get();
    }
    if c == 43 || c == 45 {
        if c == 45 {
            sign = -1;
        }
        c = f.get();
    }
    let inf = "infinity".ptr();
    let mut i: usize = 0;
    while i < 8 && (c | 32) == (unsafe inf[i]) as i32 {
        if i < 7 {
            c = f.get();
        }
        i += 1;
    }
    if i == 3 || i == 8 || i > 3 && pok {
        if i != 8 {
            f.unget();
            if pok {
                while i > 3 {
                    f.unget();
                    i -= 1;
                }
            }
        }
        return sign as f64 * INF;
    }
    if i == 0 {
        let nan = "nan".ptr();
        while i < 3 && (c | 32) == (unsafe nan[i]) as i32 {
            if i < 2 {
                c = f.get();
            }
            i += 1;
        }
    }
    if i == 3 {
        if f.get() != 40 {
            f.unget();
            return NAN;
        }
        i = 1;
        // The characters of an n-char-sequence, up to its ')'.
        loop {
            c = f.get();
            if (c as u32).wrapping_sub(48) < 10 || (c as u32).wrapping_sub(65) < 26 || (c as u32).wrapping_sub(97) < 26 || c == 95 {
                i += 1;
                continue;
            }
            if c == 41 {
                return NAN;
            }
            f.unget();
            if !pok {
                set_errno(EINVAL);
                f.bad = true;
                return 0.0;
            }
            while i > 0 {
                f.unget();
                i -= 1;
            }
            return NAN;
        }
    }
    if i != 0 {
        f.unget();
        set_errno(EINVAL);
        f.bad = true;
        return 0.0;
    }
    if c == 48 {
        c = f.get();
        if (c | 32) == 120 {
            return hexfloat(f, bits, emin, sign, pok);
        }
        f.unget();
        c = 48;
    }
    return decfloat(f, c, bits, emin, sign, pok);
}

/// `s` as a double; `*end` past the number, or `s` when none.
@export("strtod")
pub fn strtod(s: *const char, end: *mut *mut char) f64 {
    let mut f = scan_of(0, s as *const u8, null);
    let y = floatscan(&mut f, 1, true);
    if end != null {
        unsafe *end = (unsafe (s + f.used())) as *mut char;
    }
    return y;
}

/// `s` as a float.
@export("strtof")
pub fn strtof(s: *const char, end: *mut *mut char) f32 {
    let mut f = scan_of(0, s as *const u8, null);
    let y = floatscan(&mut f, 0, true);
    if end != null {
        unsafe *end = (unsafe (s + f.used())) as *mut char;
    }
    return y as f32;
}

/// `s` as a double.
@export("atof")
pub fn atof(s: *const char) f64 {
    return strtod(s, null);
}

// ---- sorting -------------------------------------------------------------------------------------------
// musl's `qsort`: smoothsort, O(n log n) and close to O(n) on sorted input.

// wasm's `i32.ctz`: 32 for zero, as musl's `__builtin_ctz` compiles there.
const fn ctz32(x: usize) u32 {
    return if x == 0 {
        32u32;
    } else {
        x.trailing_zeros() as u32;
    };
}

// musl's `pntz` over the two-word bit string `p`, as it runs on wasm.
const fn pntz(p: &[usize; 2]) u32 {
    let r = ctz32(p[0].wrapping_sub(1));
    if r != 0 {
        return r;
    }
    let r2 = 32 + ctz32(p[1]);
    if r2 != 32 {
        return r2;
    }
    return 0;
}

// musl's `shl` and `shr` of the two-word bit string `p`, with wasm's shift counts (modulo 32).
const fn shl2(p: &mut [usize; 2], n0: u32) {
    let mut n = n0;
    if n >= 32 {
        n -= 32;
        p[1] = p[0];
        p[0] = 0;
    }
    p[1] = p[1].wrapping_shl(n) | p[0].wrapping_shr(32 - n);
    p[0] = p[0].wrapping_shl(n);
}

const fn shr2(p: &mut [usize; 2], n0: u32) {
    let mut n = n0;
    if n >= 32 {
        n -= 32;
        p[0] = p[1];
        p[1] = 0;
    }
    p[0] = p[0].wrapping_shr(n) | p[1].wrapping_shl(32 - n);
    p[1] = p[1].wrapping_shr(n);
}

// musl's `cycle`: the `width`-byte elements at `ar[0..n]` move one place toward the front of the list,
// and the first goes to the last place.
const fn cycle(width: usize, ar: &mut [*mut u8; 57], n: usize) {
    if n < 2 {
        return;
    }
    let mut tmp = [0u8; 256];
    let mut w = width;
    let mut off: usize = 0;
    while w != 0 {
        let l = if w < 256 {
            w;
        } else {
            256usize;
        };
        copy(&mut tmp[0], unsafe (ar[0] + off), l);
        for i in 0..n - 1 {
            copy(unsafe (ar[i] + off), unsafe (ar[i + 1] + off), l);
        }
        copy(unsafe (ar[n - 1] + off), &tmp[0], l);
        off += l;
        w -= l;
    }
}

fn sift(head0: *mut u8, width: usize, cmp: fn(*const void, *const void) i32, pshift0: i32, lp: &[usize; 48]) {
    let mut ar = [null as *mut u8; 57];
    let mut head = head0;
    let mut pshift = pshift0;
    let mut i: usize = 1;
    ar[0] = head;
    while pshift > 1 {
        let rt = unsafe (head - width);
        let lf = unsafe (head - width - lp[(pshift - 2) as usize]);
        if cmp(ar[0], lf) >= 0 && cmp(ar[0], rt) >= 0 {
            break;
        }
        if cmp(lf, rt) >= 0 {
            unsafe ar[i] = lf;
            i += 1;
            head = lf;
            pshift -= 1;
        } else {
            unsafe ar[i] = rt;
            i += 1;
            head = rt;
            pshift -= 2;
        }
    }
    cycle(width, &mut ar, i);
}

fn trinkle(
    head0: *mut u8,
    width: usize,
    cmp: fn(*const void, *const void) i32,
    pp: &[usize; 2],
    pshift0: i32,
    trusty0: bool,
    lp: &[usize; 48],
) {
    let mut ar = [null as *mut u8; 57];
    let mut p = [pp[0], pp[1]];
    let mut head = head0;
    let mut pshift = pshift0;
    let mut trusty = trusty0;
    let mut i: usize = 1;
    ar[0] = head;
    while p[0] != 1 || p[1] != 0 {
        let stepson = unsafe (head - lp[pshift as usize]);
        if cmp(stepson, ar[0]) <= 0 {
            break;
        }
        if !trusty && pshift > 1 {
            let rt = unsafe (head - width);
            let lf = unsafe (head - width - lp[(pshift - 2) as usize]);
            if cmp(rt, stepson) >= 0 || cmp(lf, stepson) >= 0 {
                break;
            }
        }
        unsafe ar[i] = stepson;
        i += 1;
        head = stepson;
        let trail = pntz(&p);
        shr2(&mut p, trail);
        pshift += trail as i32;
        trusty = false;
    }
    if !trusty {
        cycle(width, &mut ar, i);
        sift(head, width, cmp, pshift, lp);
    }
}

/// Sort `n` elements of `width` bytes at `base` by `cmp`.
@export("qsort")
pub fn qsort(base: *mut void, n: usize, width: usize, cmp: fn(*const void, *const void) i32) {
    let size = width * n;
    if size == 0 {
        return;
    }
    // The Leonardo numbers times `width`: 48 of them pass any 32-bit size.
    let mut lp = [0usize; 48];
    let mut p = [1usize, 0usize];
    let mut pshift: i32 = 1;
    let mut head = base as *mut u8;
    let high = unsafe (head + (size - width));
    lp[0] = width;
    lp[1] = width;
    let mut i: usize = 2;
    while i < 48 {
        unsafe lp[i] = unsafe lp[i - 2].wrapping_add(unsafe lp[i - 1]).wrapping_add(width);
        if unsafe lp[i] >= size {
            break;
        }
        i += 1;
    }
    while head < high {
        if (p[0] & 3) == 3 {
            sift(head, width, cmp, pshift, &lp);
            shr2(&mut p, 2);
            pshift += 2;
        } else {
            if unsafe lp[(pshift - 1) as usize] >= high as usize - head as usize {
                trinkle(head, width, cmp, &p, pshift, false, &lp);
            } else {
                sift(head, width, cmp, pshift, &lp);
            }
            if pshift == 1 {
                shl2(&mut p, 1);
                pshift = 0;
            } else {
                shl2(&mut p, (pshift - 1) as u32);
                pshift = 1;
            }
        }
        p[0] |= 1;
        head = unsafe (head + width);
    }
    trinkle(head, width, cmp, &p, pshift, false, &lp);
    while pshift != 1 || p[0] != 1 || p[1] != 0 {
        if pshift <= 1 {
            let trail = pntz(&p);
            shr2(&mut p, trail);
            pshift += trail as i32;
        } else {
            shl2(&mut p, 2);
            pshift -= 2;
            p[0] ^= 7;
            shr2(&mut p, 1);
            trinkle(unsafe (head - lp[pshift as usize] - width), width, cmp, &p, pshift + 1, true, &lp);
            shl2(&mut p, 1);
            p[0] |= 1;
            trinkle(unsafe (head - width), width, cmp, &p, pshift, true, &lp);
        }
        head = unsafe (head - width);
    }
}

/// The element of the sorted `n` elements at `base` equal to `key` by `cmp`, or null.
@export("bsearch")
pub fn bsearch(key: *const void, base: *const void, n: usize, width: usize, cmp: fn(*const void, *const void) i32) *mut void {
    let mut b = base as *const u8;
    let mut nel = n;
    while nel > 0 {
        let t = unsafe (b + width * (nel / 2));
        let s = cmp(key, t);
        if s < 0 {
            nel /= 2;
        } else if s > 0 {
            b = unsafe (t + width);
            nel -= nel / 2 + 1;
        } else {
            return t as *mut void;
        }
    }
    return null;
}
