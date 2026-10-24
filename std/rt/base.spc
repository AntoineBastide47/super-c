// The runtime every program links (`loader::Package::rt_module`): the traps the emitted code calls
// (`__sc_panic`, `__sc_assert_fail` and the rest `super_rt.h` declares, `emit::rt_h`), the coroutine
// scheduler's preemption and cancellation hooks, the reflection registry, the allocation tracker that
// every extern C `malloc`, `calloc`, `realloc` and `free` call reaches (`Mangler::tracked_alloc`), the
// stack-overflow and illegal-instruction reports, and the test-timeout stack dumps.
//
// The module allocates through the C allocator itself, never through the tracker (its `malloc` binding
// keeps its C name), and no std container: the tracker's tables are pages from the system. Its signal
// handlers call only async-signal-safe functions, and it prints no preemption safepoints
// (`loader::runtime_path`). It imports no module and names no prelude item, so that a program emits only
// the std code it uses (`compute_emit_live`).
// The atomics of `super_rt.h`, bound by C name: an import of `atomic` would emit that module into every
// program.
extern "C" {
    @import("__sc_atomic_load_i32")
    fn atomic_load_i32(p: *const i32, mo: i32) i32;
    @import("__sc_atomic_store_i32")
    fn atomic_store_i32(p: *mut i32, v: i32, mo: i32);
    @import("__sc_atomic_swap_i32")
    fn atomic_swap_i32(p: *mut i32, v: i32, mo: i32) i32;
    @import("__sc_atomic_cas_i32")
    fn atomic_cas_i32(p: *mut i32, expected: i32, desired: i32, weak: bool, so: i32, fo: i32) bool;
    @import("__sc_atomic_load_u32")
    fn atomic_load_u32(p: *const u32, mo: i32) u32;
    @import("__sc_atomic_store_u32")
    fn atomic_store_u32(p: *mut u32, v: u32, mo: i32);
    @import("__sc_atomic_load_usize")
    fn atomic_load_usize(p: *const usize, mo: i32) usize;
    @import("__sc_atomic_store_usize")
    fn atomic_store_usize(p: *mut usize, v: usize, mo: i32);
    @import("__sc_atomic_swap_usize")
    fn atomic_swap_usize(p: *mut usize, v: usize, mo: i32) usize;
    @import("__sc_atomic_cas_usize")
    fn atomic_cas_usize(p: *mut usize, expected: usize, desired: usize, weak: bool, so: i32, fo: i32) bool;
}

const RELAXED: i32 = 0;
const ACQUIRE: i32 = 1;
const RELEASE: i32 = 2;

// The C allocator and the process calls, under their C names.
extern "C" "stdlib.h" {
    @import("malloc")
    fn c_malloc(n: usize) *mut void;
    @import("calloc")
    fn c_calloc(count: usize, n: usize) *mut void;
    @import("realloc")
    fn c_realloc(p: *mut void, n: usize) *mut void;
    @import("free")
    fn c_free(p: *mut void);
    @platform(!windows)
    @import("aligned_alloc")
    fn c_aligned_alloc(align: usize, n: usize) *mut void;
    @import("getenv")
    fn c_getenv(name: *const char) *const char;
    @import("_Exit")
    fn c_exit_now(code: i32);
    @import("abort")
    fn c_abort();
    @import("atexit")
    fn c_atexit(f: fn()) i32;
    @import("qsort")
    fn c_qsort(base: *mut void, n: usize, size: usize, cmp: fn(*const void, *const void) i32);
}

extern "C" "stdio.h" {
    @import("fflush")
    fn c_fflush(f: *mut void) i32;
    @import("snprintf")
    fn c_snprintf(buf: *mut char, n: usize, fmt: *const char, ...) i32;
}

// The bytes the reports print go straight to file descriptor 2, unbuffered as C's stderr is.
@platform(!windows)
extern "C" "unistd.h" {
    @import("write")
    fn c_write(fd: i32, buf: *const void, n: usize) isize;
}
@platform(windows)
extern "C" "io.h" {
    @import("_write")
    fn c_write(fd: i32, buf: *const void, n: u32) i32;
}

extern "C" "string.h" {
    @import("memcpy")
    fn c_memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
    @import("strlen")
    fn c_strlen(s: *const char) usize;
}

// ---- output ---------------------------------------------------------------------------------------

// The `n` bytes at `p` on stderr.
@platform(!windows)
fn put_bytes(p: *const u8, n: usize) {
    unsafe c_write(2, p, n);
}
@platform(windows)
fn put_bytes(p: *const u8, n: usize) {
    unsafe c_write(2, p, n as u32);
}

// `s` (NUL-terminated) on stderr.
fn put(s: *const char) {
    put_bytes(s as *const u8, unsafe c_strlen(s));
}

// `v` in decimal on stderr.
fn put_dec(v: u64) {
    let mut b = [0u8; 24];
    let n = dec_text(&mut b, v);
    put_bytes(unsafe &b[24 - n], n);
}

// `v` in lowercase hexadecimal after `0x` on stderr.
fn put_hex(v: u64) {
    let mut b = [0u8; 18];
    let mut i: usize = 18;
    let mut x = v;
    loop {
        i -= 1;
        unsafe b[i] = hex_digit((x & 15) as u8);
        x >>= 4;
        if x == 0 {
            break;
        }
    }
    i -= 2;
    unsafe b[i] = b'0';
    unsafe b[i + 1] = b'x';
    put_bytes(unsafe &b[i], 18 - i);
}

// The lowercase hexadecimal digit of `d` (below 16).
const fn hex_digit(d: u8) u8 {
    if d < 10 {
        return b'0' + d;
    }
    return b'a' + (d - 10);
}

// The decimal digits of `v` at the end of `b`; returns how many.
const fn dec_text(b: &mut [u8; 24], v: u64) usize {
    let mut i: usize = 24;
    let mut x = v;
    loop {
        i -= 1;
        unsafe b[i] = b'0' + (x % 10) as u8;
        x /= 10;
        if x == 0 {
            break;
        }
    }
    return 24 - i;
}

// End the process after a trap: abort does not flush, and stdout is block-buffered when captured into a
// pipe or a file, so the output printed before the trap would be lost.
@noreturn
fn die() {
    unsafe c_fflush(null);
    unsafe c_abort();
}

// ---- traps --------------------------------------------------------------------------------------------

// The id of the coroutine running on this thread, 0 on a plain thread: a panic names its task.
@thread_local
static mut TASK_ID: u64 = 0;

// Record the id of the coroutine this thread runs (0: none), which a panic names.
@export("__sc_set_task_id")
fn set_task_id(id: u64) {
    unsafe TASK_ID = id;
}

// `<prefix>[task <id>] ` on stderr, the task part only on a coroutine.
fn trap_head(prefix: *const char) {
    put(prefix);
    let id = unsafe TASK_ID;
    if id != 0 {
        put("[task ");
        put_dec(id);
        put("] ");
    }
}

// `super-c: <m>` on stderr, then abort.
@export("__sc_panic")
@noreturn
@cold
fn trap(m: *const char) {
    trap_head("super-c: ");
    put(m);
    put("\n");
    die();
}

// `panic: <the n bytes at p>` on stderr, then abort: `panic` of std's core.
@export("__sc_panic_str")
@noreturn
@cold
fn trap_str(p: *const u8, n: usize) {
    trap_head("panic: ");
    put_bytes(p, n);
    put("\n");
    die();
}

// A failed `assert`: `head`, the `n` bytes at `m` and `tail` on stderr, then abort.
@export("__sc_assert_fail")
@noreturn
@cold
@noinline
fn assert_fail(head: *const char, m: *const u8, n: usize, tail: *const char) {
    put(head);
    if n != 0 {
        put_bytes(m, n);
    }
    put(tail);
    die();
}

// A failed `assert_eq` or `assert_ne` the native backends compile: `head`, the two operands of kind `kind`
// (`ASSERT_*`: a signed or unsigned integer, an f64 by its bits, a bool, a `str` of `n` bytes at `v`, or
// none to print) as C prints them, and `tail`; then abort.
@export("__sc_assert_vals")
@noreturn
@cold
@noinline
fn assert_vals(head: *const char, kind: u32, l: u64, ln: u64, r: u64, rn: u64, tail: *const char) {
    put(head);
    assert_val("  left:  ", kind, l, ln);
    assert_val("  right: ", kind, r, rn);
    put(tail);
    die();
}

const ASSERT_I64: u32 = 1;
const ASSERT_U64: u32 = 2;
const ASSERT_F64: u32 = 3;
const ASSERT_BOOL: u32 = 4;
const ASSERT_STR: u32 = 5;

// One operand line of `assert_vals`.
fn assert_val(label: *const char, kind: u32, v: u64, n: u64) {
    if kind == 0 || kind > ASSERT_STR {
        return;
    }
    put(label);
    if kind == ASSERT_I64 && v >> 63 != 0 {
        put("-");
        put_dec(~v + 1);
    } else if kind == ASSERT_I64 || kind == ASSERT_U64 {
        put_dec(v);
    } else if kind == ASSERT_F64 {
        let mut b = [0 as char; 64];
        // The bits as a double, by a copy: a cast pointer would break C's aliasing rules.
        let mut f: f64 = 0.0;
        unsafe c_memcpy(&mut f, &v, 8);
        let w = unsafe c_snprintf(&mut b[0], 64, "%g", f);
        put_bytes((&b[0]) as *const u8, w as usize);
    } else if kind == ASSERT_BOOL {
        put(
            if v != 0 {
                "true";
            } else {
                "false";
            },
        );
    } else {
        put("\"");
        put_bytes(v as *const u8, n as usize);
        put("\"");
    }
    put("\n");
}

// An atomic operation given a memory order it cannot take.
@export("__sc_trap_order")
@noreturn
@cold
fn trap_order() {
    trap("invalid memory order");
}

// A pointer distance over a zero-sized element type: bytes cannot encode an element count.
@export("__sc_zst_ptrdiff")
@noreturn
@cold
fn zst_ptrdiff() {
    trap("pointer distance on a zero-sized element type");
}

// ---- scheduler hooks --------------------------------------------------------------------------------
// Installed by the scheduler before it starts any worker, so every safepoint's read happens after the
// write.

static mut PRE_HOOK: fn() = no_preempt;
static mut CANCEL_HOOK: fn() i32 = no_cancel;

// The hooks before the scheduler installs its own.
const fn no_preempt() {}
const fn no_cancel() i32 {
    return 0;
}

// Install the preemption hook every safepoint of a running task calls.
@export("__sc_set_preempt_hook")
fn set_preempt_hook(f: fn()) {
    unsafe PRE_HOOK = f;
}

// Install the cancellation hook a combined safepoint asks: 1 when it accepted a pending cancellation.
@export("__sc_set_cancel_hook")
fn set_cancel_hook(f: fn() i32) {
    unsafe CANCEL_HOOK = f;
}

// The cold half of a safepoint tick: run the preemption hook, and hand back the tick budget.
@export("__sc_preempt_check")
fn preempt_check() i32 {
    unsafe PRE_HOOK();
    return 2048;
}

// The cancellation half of a combined safepoint: 1 when the hook accepted a pending cancellation.
@export("__sc_cancel_tick")
fn cancel_tick() i32 {
    return unsafe CANCEL_HOOK();
}

// ---- reflection registry ------------------------------------------------------------------------
// The registry unit's constructor records its static table of the `@reflect` descriptors before main;
// the runtime keeps only the table's address. External tools dlopen the binary and read it through
// `__sc_reflect_types`.

static mut REFL: *const *const void = null;
static mut REFL_N: usize = 0;

@export("__sc_reflect_register")
fn reflect_register(roots: *const *const void, n: usize) {
    unsafe REFL = roots;
    unsafe REFL_N = n;
}

@export("__sc_reflect_types")
fn reflect_types(n: *mut usize) *const *const void {
    if n != null {
        unsafe *n = unsafe REFL_N;
    }
    return unsafe REFL;
}

// ---- sanitizer options --------------------------------------------------------------------------
// ASan's use-after-return check moves frames to a fake stack, where GCC (13.3 to 15) places an object
// aligned above 32 bytes 32 bytes off: an AVX-512 build faults on its aligned moves, so the fake stack is
// off. An illegal instruction (a jump through a corrupt code address) gets ASan's report, with the
// faulting pc and the stack. ASAN_OPTIONS still overrides both.
@when(ADDRESS_SANITIZER)
@export("__asan_default_options")
fn asan_default_options() *const char {
    return "detect_stack_use_after_return=0:handle_sigill=1";
}

// Whether the program is built with AddressSanitizer, as a constant of this module: a read of the build
// constant at run time would emit std's build module, and the prelude it imports, into every program.
@when(ADDRESS_SANITIZER)
const ASAN: bool = true;
@when(!ADDRESS_SANITIZER)
const ASAN: bool = false;

// 1 in a program built with AddressSanitizer, whose frames carry redzones: std's runtime sizes its default
// task stack by it.
@export("sc_rt_asan")
const fn rt_asan() i32 {
    return ASAN as i32;
}

// ---- POSIX bindings ------------------------------------------------------------------------------

@platform(macos | ios | linux | android)
extern "C" "unistd.h" {
    @import("close")
    fn c_close(fd: i32) i32;
    @import("getpid")
    fn c_getpid() i32;
    @import("sysconf")
    fn c_sysconf(name: i32) isize;
    @import("_exit")
    fn c_exit_fast(code: i32);
    @platform(macos | ios)
    @import("_SC_PAGESIZE")
    const SC_PAGESIZE: i32 = 29;
    @platform(linux | android)
    @import("_SC_PAGESIZE")
    const SC_PAGESIZE: i32 = 30;
}

@platform(macos | ios | linux | android)
extern "C" "fcntl.h" {
    @import("open")
    fn c_open(path: *const char, flags: i32, ...) i32;
    const O_WRONLY: i32 = 1;
    @platform(macos | ios)
    const O_APPEND: i32 = 8;
    @platform(linux | android)
    const O_APPEND: i32 = 0o2000;
    @platform(macos | ios)
    const O_CREAT: i32 = 0x200;
    @platform(linux | android)
    const O_CREAT: i32 = 0o100;
}

@platform(macos | ios | linux | android)
extern "C" "sys/mman.h" {
    fn mmap(addr: *mut void, len: usize, prot: i32, flags: i32, fd: i32, off: i64) *mut void;
    fn munmap(addr: *mut void, len: usize) i32;
    const PROT_READ: i32 = 1;
    const PROT_WRITE: i32 = 2;
    const MAP_PRIVATE: i32 = 2;
    @platform(linux | android)
    @import("MAP_ANONYMOUS")
    const MAP_ANON: i32 = 0x20;
}
// <sys/mman.h> defines MAP_ANON on Darwin only for _DARWIN_C_SOURCE, which the build's POSIX level hides.
@platform(macos | ios)
const MAP_ANON: i32 = 0x1000;

@platform(macos | ios | linux | android)
extern "C" "time.h" {
    struct timespec {
        pub tv_sec: i64,
        pub tv_nsec: isize,
    }
    fn nanosleep(req: *const timespec, rem: *mut timespec) i32;
}

// `sa_mask` of `struct sigaction`: an integer on Darwin, a struct of words on glibc.
@platform(macos | ios)
type sigset_t = u32;

@platform(macos | ios | linux | android)
extern "C" "signal.h" {
    @platform(linux | android)
    @import("sigset_t")
    struct sigset_t {
        @import("__val")
        pub val: [u64; 16],
    }
    // `sa_handler` is the header's macro over the handler union's first member; `sa_sigaction` is the
    // same storage.
    @platform(macos | ios)
    struct sigaction {
        @import("sa_handler")
        pub handler: fn(i32),
        pub sa_mask: sigset_t,
        pub sa_flags: i32,
    }
    @platform(linux | android)
    struct sigaction {
        @import("sa_handler")
        pub handler: fn(i32),
        pub sa_mask: sigset_t,
        pub sa_flags: i32,
        pub sa_restorer: *mut void,
    }
    @platform(macos | ios)
    @import("stack_t")
    struct stack_t {
        pub ss_sp: *mut void,
        pub ss_size: usize,
        pub ss_flags: i32,
    }
    @platform(linux | android)
    @import("stack_t")
    struct stack_t {
        pub ss_sp: *mut void,
        pub ss_flags: i32,
        pub ss_size: usize,
    }
    @import("sigaction")
    fn c_sigaction(sig: i32, act: *const sigaction, old: *mut sigaction) i32;
    fn sigemptyset(set: *mut sigset_t) i32;
    fn sigaltstack(ss: *const stack_t, old: *mut stack_t) i32;
    fn raise(sig: i32) i32;
    const SIGILL: i32 = 4;
    const SIGSEGV: i32 = 11;
    @platform(macos | ios)
    const SIGBUS: i32 = 10;
    @platform(linux | android)
    const SIGBUS: i32 = 7;
    @platform(macos | ios)
    const SIGUSR2: i32 = 31;
    @platform(linux | android)
    const SIGUSR2: i32 = 12;
    @platform(macos | ios)
    const SIGURG: i32 = 16;
    @platform(linux | android)
    const SIGURG: i32 = 23;
    @platform(macos | ios)
    const SA_ONSTACK: i32 = 1;
    @platform(linux | android)
    const SA_ONSTACK: i32 = 0x08000000;
    @platform(macos | ios)
    const SA_RESTART: i32 = 2;
    @platform(linux | android)
    const SA_RESTART: i32 = 0x10000000;
    @platform(macos | ios)
    const SA_SIGINFO: i32 = 0x40;
    @platform(linux | android)
    const SA_SIGINFO: i32 = 4;
    const SS_ONSTACK: i32 = 1;
    @platform(macos | ios)
    const SS_DISABLE: i32 = 4;
    @platform(linux | android)
    const SS_DISABLE: i32 = 2;
    const SEGV_MAPERR: i32 = 1;
    const SEGV_ACCERR: i32 = 2;
    const BUS_ADRALN: i32 = 1;
    const BUS_ADRERR: i32 = 2;
    const BUS_OBJERR: i32 = 3;
}

// A signal handler as `sa_handler` holds it, for either handler form, and its address (SIG_DFL is 0,
// SIG_IGN 1).
@platform(macos | ios | linux | android)
union HandlerBits {
    pub f: fn(i32),
    pub info: fn(i32, *mut void, *mut void),
    pub n: usize,
}

// The kernel's signal records, read at fixed offsets: `siginfo_t` holds its fault address in a union the
// headers name only through macros, and a `ucontext_t` is several kilobytes of state of which only the
// stack pointer is read. `si_code` sits at byte 8 everywhere.
@platform(macos | ios)
const SI_ADDR_AT: usize = 24;
@platform(linux | android)
const SI_ADDR_AT: usize = 16;
const SI_CODE_AT: usize = 8;
// Darwin: `uc_mcontext` points to the machine context, whose thread state follows a 16-byte exception
// state: `__sp` after x0..x28, fp and lr on arm64, `__rsp` the eighth register on x86_64.
@platform(macos | ios)
const UC_MCONTEXT_AT: usize = 48;
@platform(macos | ios)
@arch(aarch64)
const MC_SP_AT: usize = 264;
@platform(macos | ios)
@arch(x86_64)
const MC_SP_AT: usize = 72;
// Linux: the machine context sits in the context after uc_flags, uc_link and uc_stack (40 bytes):
// gregs[REG_RSP] (15) on x86_64; on arm64 after a 128-byte signal mask, 16-aligned at 176, then
// fault_address and regs[31].
@platform(linux | android)
@arch(x86_64)
const UC_SP_AT: usize = 160;
@platform(linux | android)
@arch(aarch64)
const UC_SP_AT: usize = 432;

// ---- POSIX stack-overflow report -------------------------------------------------------------------
// A stack that runs into its guard faults, and without a handler the process dies on a bare SIGSEGV or
// SIGBUS. This prints which stack ran out and exits with 134, the status of the abort a panic ends in
// (the test runner reads both as a panic). The main thread is armed before main; std's runtime arms every
// thread it starts (`stack_arm`). An armed thread runs the handler on a signal stack of its own, since the
// faulting stack has no room left, and the base of that signal stack records the bounds of the thread's
// own stack. The handler finds the record through sigaltstack, so it reads no thread-local storage before
// it knows the thread is armed. A fault is an overflow when its address is in the guard region below the
// running thread's own stack or, while the thread runs on another stack (a coroutine's), within STK_NEAR
// of the stack pointer. Any other fault goes to the handler installed before this one, else to the
// default action: a wild pointer still crashes as one, and under AddressSanitizer gets ASan's report.

@platform(macos | ios | linux | android)
const STK_MAGIC: u64 = 0x31544b535f4353; // "SC_STK1"
// A fault this close to the stack pointer is the stack running out: wider than any frame that stays near
// its guard, far narrower than where a wild pointer lands.
@platform(macos | ios | linux | android)
const STK_NEAR: usize = 128 << 10;
// Around a stack's low end: its guard (glibc counted the guard into the stack, pages may be 64 KiB), and
// how far below it a frame has already moved the stack pointer at the fault where no probe touches the
// frame first (Linux). Smaller than a coroutine stack, so a coroutine stack mapped just below a worker's
// own stack does not read as the worker's.
@platform(macos | ios | linux | android)
const STK_SLACK: usize = 64 << 10;
// Each signal stack: SIGSTKSZ, at least 64 KiB.
@platform(macos | ios)
const STK_ALT_MIN: usize = 131072;
@platform(linux | android)
const STK_ALT_MIN: usize = 65536;
// Signal stacks of ended threads, kept for the next armed thread: a fresh mapping, its first touch and its
// unmap cost about 2 us of each thread's start. Each slot is taken and filled with one atomic operation,
// so the cache needs no lock; at most STK_CACHE stacks wait in it, the rest are unmapped.
@platform(macos | ios | linux | android)
const STK_CACHE: usize = 64;

// The record at the base of a thread's signal stack: its own stack runs from lo up to hi (lo 0: unknown).
@platform(macos | ios | linux | android)
struct StkRec {
    pub magic: u64,
    pub lo: usize,
    pub hi: usize,
    pub main: u64,
}

// The task stack size std's runtime hands out, for the message only.
@platform(!wasm)
static mut STK_TASK: usize = 0;
@platform(macos | ios | linux | android)
static mut STK_ON: i32 = 0; // the handler is installed
@platform(macos | ios | linux | android)
static mut STK_ALT: usize = 0; // bytes of each signal stack
// The actions installed before this runtime's, which `sigaction` fills in at startup.
@platform(macos | ios | linux | android)
static mut STK_PREV_SEGV: sigaction = sigaction { handler: sig_unset };
@platform(macos | ios | linux | android)
static mut STK_PREV_BUS: sigaction = sigaction { handler: sig_unset };
@platform(macos | ios | linux | android)
static mut ILL_PREV: sigaction = sigaction { handler: sig_unset };

// The handler a previous action holds until `sigaction` records the real one.
@platform(macos | ios | linux | android)
const fn sig_unset(_sig: i32) {}
@platform(macos | ios | linux | android)
@thread_local
static mut STK_MINE: *mut void = null; // this thread's signal stack
@platform(macos | ios | linux | android)
static mut STK_CACHED: [usize; 64] = [0usize; 64];

// Record the usable task stack size the overflow report quotes.
@platform(!wasm)
@export("__sc_stack_task_size")
fn stack_task_size(bytes: usize) {
    unsafe atomic_store_usize(&mut STK_TASK, bytes, RELAXED);
}

// Append the NUL-terminated `s` to the 256-byte report `b` at `n`.
@platform(!wasm)
const fn stk_put(b: &mut [u8; 256], n: usize, s: *const char) usize {
    let mut k = n;
    let mut i: usize = 0;
    while (unsafe s[i]) as u8 != 0 && k < 255 {
        unsafe b[k] = (unsafe s[i]) as u8;
        k += 1;
        i += 1;
    }
    return k;
}

// Append `v` in decimal to the report `b` at `n`.
@platform(!wasm)
const fn stk_num(b: &mut [u8; 256], n: usize, v: u64) usize {
    let mut d = [0u8; 24];
    let w = dec_text(&mut d, v);
    let mut k = n;
    for i in 24 - w..24 {
        if k < 255 {
            unsafe b[k] = unsafe d[i];
            k += 1;
        }
    }
    return k;
}

// The report, into `b` so it reaches stderr in one write: `task` when the running coroutine's stack ran
// out, else the thread's own stack (the main thread's when `main`), of `size` bytes when known.
@platform(!wasm)
fn stk_text(b: &mut [u8; 256], task: bool, main: bool, size: u64) usize {
    let mut n = stk_put(b, 0, "\nsuper-c: ");
    let id = unsafe TASK_ID;
    if id != 0 {
        n = stk_put(b, n, "[task ");
        n = stk_num(b, n, id);
        n = stk_put(b, n, "] ");
    }
    n = stk_put(b, n, "stack overflow");
    let ts = unsafe atomic_load_usize(&mut STK_TASK, RELAXED);
    if task && ts != 0 {
        n = stk_put(b, n, " (");
        n = stk_num(b, n, ts as u64);
        n = stk_put(b, n, " byte task stack exhausted; raise it with runtime::set_stack_size)");
    } else if !task {
        n = stk_put(
            b,
            n,
            if main {
                " in the main thread";
            } else {
                " in a thread";
            },
        );
        if size != 0 {
            n = stk_put(b, n, " (");
            n = stk_num(b, n, size);
            n = stk_put(b, n, " byte stack)");
        }
    }
    return stk_put(b, n, "\n");
}

@platform(macos | ios | linux | android)
fn stk_take() *mut void {
    for i in 0..STK_CACHE {
        let m = unsafe atomic_swap_usize(&mut STK_CACHED[i], 0, ACQUIRE);
        if m != 0 {
            return m as *mut void;
        }
    }
    return null;
}

@platform(macos | ios | linux | android)
fn stk_give(m: *mut void) {
    for i in 0..STK_CACHE {
        if unsafe atomic_cas_usize(&mut STK_CACHED[i], 0, m as usize, false, RELEASE, RELAXED) {
            return;
        }
    }
    unsafe munmap(m, unsafe STK_ALT);
}

// Darwin's non-portable stack queries, which the build's POSIX level hides: their own prototypes.
@platform(macos | ios)
extern "C" "pthread.h" {
    @layout(sizeof(usize), sizeof(usize))
    type pthread_t;
    fn pthread_self() pthread_t;
    fn pthread_kill(t: pthread_t, sig: i32) i32;
}
@platform(macos | ios)
extern "C" {
    fn pthread_get_stackaddr_np(t: pthread_t) *mut void;
    fn pthread_get_stacksize_np(t: pthread_t) usize;
    fn pthread_from_mach_thread_np(port: u32) pthread_t;
}

@platform(linux | android)
extern "C" "sys/resource.h" {
    struct rlimit {
        pub rlim_cur: u64,
        pub rlim_max: u64,
    }
    fn getrlimit(what: i32, out: *mut rlimit) i32;
    const RLIMIT_STACK: i32 = 3;
}
@platform(linux | android)
extern "C" "sys/auxv.h" {
    fn getauxval(kind: usize) usize;
    const AT_EXECFN: usize = 31;
}

// The calling thread's stack (lo, hi), when it can be known without reading /proc; (0, 0) otherwise.
@platform(macos | ios)
fn stk_bounds(_main: bool) (usize, usize) {
    let t = unsafe pthread_self();
    let hi = (unsafe pthread_get_stackaddr_np(t)) as usize;
    return hi - unsafe pthread_get_stacksize_np(t), hi;
}
// The main thread's on Linux, from its size limit and its top, where the kernel copies the program's path
// (AT_EXECFN): pthread_getattr_np would read /proc/self/maps.
@platform(linux | android)
fn stk_bounds(main: bool) (usize, usize) {
    if !main {
        return 0, 0;
    }
    let top = unsafe getauxval(AT_EXECFN);
    let mut rl = rlimit { rlim_cur: 0, rlim_max: 0 };
    if top == 0 || unsafe getrlimit(RLIMIT_STACK, &mut rl) != 0 || rl.rlim_cur == ~0u64 {
        return 0, 0;
    }
    let pg = (unsafe c_sysconf(SC_PAGESIZE)) as usize;
    let hi = top + unsafe c_strlen(top as *const char) + pg & ~(pg - 1);
    if rl.rlim_cur as usize >= hi {
        return 0, 0;
    }
    return hi - rl.rlim_cur as usize, hi;
}

// The stack pointer at the fault, from the signal context; 0 on an instruction set with no table entry (a
// check for a target this runtime does not run on), which reports every fault as one beyond the slack.
@platform(macos | ios)
@arch(x86_64 | aarch64)
const fn stk_sp(uc: *mut void) usize {
    let mc = unsafe *((uc as usize + UC_MCONTEXT_AT) as *const usize);
    return unsafe *((mc + MC_SP_AT) as *const usize);
}
@platform(linux | android)
@arch(x86_64 | aarch64)
fn stk_sp(uc: *mut void) usize {
    return unsafe *((uc as usize + UC_SP_AT) as *const usize);
}
@platform(macos | ios | linux | android)
@arch(wasm32)
fn stk_sp(_uc: *mut void) usize {
    return 0;
}

// The action installed before this runtime's for `sig`: its handler runs, else the default action.
@platform(macos | ios | linux | android)
fn stk_chain(sig: i32, prev: *const sigaction, si: *mut void, uc: *mut void) {
    let bits = HandlerBits { f: unsafe (*prev).handler };
    let info = (unsafe (*prev).sa_flags & SA_SIGINFO) != 0;
    if info && bits.n != 0 {
        bits.info(sig, si, uc);
        return;
    }
    if !info && bits.n > 1 {
        bits.f(sig);
        return;
    }
    let mut d = unsafe zeroed::<sigaction>();
    unsafe sigemptyset(&mut d.sa_mask);
    unsafe c_sigaction(sig, &d, null);
    unsafe raise(sig);
}

@platform(macos | ios | linux | android)
fn stk_fault(sig: i32, si: *mut void, uc: *mut void) {
    let mut cur = unsafe zeroed::<stack_t>();
    let mut r: *const StkRec = null;
    if unsafe sigaltstack(null, &mut cur) == 0 && (cur.ss_flags & SS_ONSTACK) != 0 && cur.ss_size >= sizeof(StkRec) {
        let rec = cur.ss_sp as *const StkRec;
        if unsafe (*rec).magic == STK_MAGIC {
            r = rec;
        }
    }
    let code = unsafe *((si as usize + SI_CODE_AT) as *const i32);
    let fault = if sig == SIGSEGV {
        code == SEGV_MAPERR || code == SEGV_ACCERR;
    } else {
        code == BUS_ADRALN || code == BUS_ADRERR || code == BUS_OBJERR;
    };
    if r != null && fault {
        let lo = unsafe (*r).lo;
        let hi = unsafe (*r).hi;
        let a = unsafe *((si as usize + SI_ADDR_AT) as *const usize);
        let sp = stk_sp(uc);
        let near = sp != 0 && if a > sp {
            a - sp;
        } else {
            sp - a;
        } < STK_NEAR;
        let floor = if lo > STK_SLACK {
            lo - STK_SLACK;
        } else {
            0;
        };
        let own = lo != 0 && sp >= floor && sp < hi;
        let guard = lo != 0 && a >= floor && a < lo + STK_SLACK;
        // On its own stack, the thread overflowed when the fault is at the guard, or near the stack pointer
        // below the top (the Linux main thread grows until another mapping stops it).
        let overflow = if own || sp == 0 {
            guard || own && near && a >= floor && a < hi;
        } else {
            near;
        };
        if overflow {
            let mut b = [0u8; 256];
            // Off the thread's own stack: a coroutine's.
            let task = !own && sp != 0 && unsafe TASK_ID != 0;
            let n = stk_text(
                &mut b,
                task,
                unsafe (*r).main != 0,
                if own {
                    (hi - lo) as u64;
                } else {
                    0;
                },
            );
            unsafe c_write(2, &b[0], n);
            unsafe c_exit_fast(134);
        }
    }
    let prev = if sig == SIGSEGV {
        (unsafe &STK_PREV_SEGV) as *const sigaction;
    } else {
        (unsafe &STK_PREV_BUS) as *const sigaction;
    };
    stk_chain(sig, prev, si, uc);
}

// Arm the calling thread (`stack_arm`); `main` for the main thread at startup.
@platform(macos | ios | linux | android)
fn stk_arm(lo0: usize, hi0: usize, main: bool) *mut void {
    // Reading the thread-local first also has macOS allocate this thread's block here, never in the
    // handler (which reads TASK_ID).
    if unsafe STK_MINE != null || unsafe atomic_load_i32(&mut STK_ON, ACQUIRE) == 0 {
        return null;
    }
    let sz = unsafe STK_ALT;
    let mut m = stk_take();
    if m == null {
        m = unsafe mmap(null, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    }
    if m as isize == -1 {
        return null;
    }
    let mut lo = lo0;
    let mut hi = hi0;
    if lo == 0 {
        let (l, h) = stk_bounds(main);
        lo = l;
        hi = h;
    }
    unsafe *(m as *mut StkRec) = StkRec { magic: STK_MAGIC, lo: lo, hi: hi, main: main as u64 };
    let ss = stack_t { ss_sp: m, ss_size: sz, ss_flags: 0 };
    let mut old = unsafe zeroed::<stack_t>();
    if unsafe sigaltstack(&ss, &mut old) != 0 {
        stk_give(m);
        return null;
    }
    if ASAN && (old.ss_flags & SS_DISABLE) == 0 && old.ss_sp != null {
        // ASan gives each thread a signal stack and unmaps the one in place when the thread ends: this one
        // replaces ASan's, which nothing else frees.
        unsafe munmap(old.ss_sp, old.ss_size);
    }
    unsafe STK_MINE = m;
    return m;
}

// Arm the calling thread to report a stack overflow, its stack from `lo` up to `hi` when the caller knows
// it (0, 0 otherwise). Returns the signal stack to release with `stack_disarm` when the thread ends, or
// null when nothing was armed: no handler, already armed, or no memory.
@platform(macos | ios | linux | android)
@export("__sc_stack_arm")
fn stack_arm(lo: usize, hi: usize) *mut void {
    return stk_arm(lo, hi, false);
}

// Release the signal stack `alt` of `stack_arm` when its thread ends. Under ASan nothing: ASan's end of
// the thread unmaps the signal stack in place, and the cache never holds one.
@platform(macos | ios | linux | android)
@when(ADDRESS_SANITIZER)
@export("__sc_stack_disarm")
fn stack_disarm(_alt: *mut void) {}
@platform(macos | ios | linux | android)
@when(!ADDRESS_SANITIZER)
@export("__sc_stack_disarm")
fn stack_disarm(alt: *mut void) {
    let ss = stack_t { ss_sp: null, ss_size: unsafe STK_ALT, ss_flags: SS_DISABLE }; // Darwin checks the size
    unsafe sigaltstack(&ss, null);
    stk_give(alt);
}

// An illegal instruction is a jump through a corrupt code address, or code for a CPU feature this one
// lacks: the report names the address, then the handler installed before, else the default action, ends
// the process (its status still says SIGILL). Async-signal-safe, as the overflow handler.
@platform(macos | ios | linux | android)
fn ill_fault(sig: i32, si: *mut void, uc: *mut void) {
    let mut b = [0u8; 256];
    let mut n = stk_put(&mut b, 0, "\nsuper-c: illegal instruction at 0x");
    let a = unsafe *((si as usize + SI_ADDR_AT) as *const usize);
    let mut s: i32 = 60;
    while s >= 0 {
        unsafe b[n] = hex_digit((a >> s as usize & 15) as u8);
        n += 1;
        s -= 4;
    }
    unsafe b[n] = b'\n';
    unsafe c_write(2, &b[0], n + 1);
    stk_chain(sig, unsafe &ILL_PREV, si, uc);
}

// Install the SIGILL report and the overflow handler, and arm the main thread.
@platform(macos | ios | linux | android)
fn stk_boot() {
    let ill = HandlerBits { info: ill_fault };
    let mut sa = unsafe zeroed::<sigaction>();
    sa.handler = ill.f;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    unsafe sigemptyset(&mut sa.sa_mask);
    unsafe c_sigaction(SIGILL, &sa, &mut ILL_PREV);
    let pg = (unsafe c_sysconf(SC_PAGESIZE)) as usize;
    unsafe STK_ALT = STK_ALT_MIN + pg - 1 & ~(pg - 1);
    let h = HandlerBits { info: stk_fault };
    sa.handler = h.f;
    if unsafe c_sigaction(SIGSEGV, &sa, &mut STK_PREV_SEGV) != 0 {
        return;
    }
    if PLATFORM == Platform::MacOS || PLATFORM == Platform::IOS {
        // Darwin reports a guard-page hit as SIGBUS.
        unsafe c_sigaction(SIGBUS, &sa, &mut STK_PREV_BUS);
    }
    unsafe atomic_store_i32(&mut STK_ON, 1, RELEASE);
    stk_arm(0, 0, true);
}

// ---- Windows stack-overflow report ----------------------------------------------------------------
// Windows raises EXCEPTION_STACK_OVERFLOW for an exhausted stack only: a vectored handler reports it, and
// every armed thread keeps a stack guarantee for the report to run in.

@platform(windows)
extern "C" "windows.h" {
    @import("EXCEPTION_RECORD")
    struct EXCEPTION_RECORD {
        @import("ExceptionCode")
        pub code: u32,
        @import("ExceptionFlags")
        pub flags: u32,
        @import("ExceptionRecord")
        pub chained: *mut EXCEPTION_RECORD,
        @import("ExceptionAddress")
        pub address: *mut void,
        @import("NumberParameters")
        pub nparams: u32,
        @import("ExceptionInformation")
        pub info: [usize; 15],
    }
    @import("EXCEPTION_POINTERS")
    struct EXCEPTION_POINTERS {
        @import("ExceptionRecord")
        pub record: *mut EXCEPTION_RECORD,
        @import("ContextRecord")
        pub context: *mut void,
    }
    @layout(8, 8)
    type PVECTORED_EXCEPTION_HANDLER;
    fn AddVectoredExceptionHandler(first: u32, handler: PVECTORED_EXCEPTION_HANDLER) *mut void;
    // `PULONG` and `LPDWORD` point to an `unsigned long`, which no Super-C type spells: the 4-byte object
    // passes as `void *`.
    fn SetThreadStackGuarantee(bytes: *mut void) i32;
    fn GetCurrentThreadId() u32;
    fn GetCurrentThreadStackLimits(lo: *mut usize, hi: *mut usize);
    fn GetStdHandle(which: u32) *mut void;
    fn WriteFile(h: *mut void, p: *const void, n: u32, done: *mut void, ov: *mut void) i32;
    fn GetCurrentProcess() *mut void;
    fn TerminateProcess(p: *mut void, code: u32) i32;
    fn GetModuleHandleA(name: *const char) *mut void;
    const STD_ERROR_HANDLE: u32 = 0xFFFFFFF4;
    const EXCEPTION_STACK_OVERFLOW: u32 = 0xC00000FD;
}

// A vectored exception handler as AddVectoredExceptionHandler takes it: its C result type is `LONG`, a C
// `long`, which is `i32`'s ABI type on Windows.
@platform(windows)
union VehBits {
    pub f: fn(*mut EXCEPTION_POINTERS) i32,
    pub h: PVECTORED_EXCEPTION_HANDLER,
}

@platform(windows)
static mut STK_MAIN_ID: u32 = 0;

// The report, then the end of the process: not ExitProcess, whose DLL detach and CRT teardown would run
// on the exhausted stack.
@platform(windows)
@noreturn
fn stk_report(task: bool) {
    let mut b = [0u8; 256];
    let mut lo: usize = 0;
    let mut hi: usize = 0;
    if !task {
        unsafe GetCurrentThreadStackLimits(&mut lo, &mut hi);
    }
    let n = stk_text(&mut b, task, unsafe GetCurrentThreadId() == unsafe STK_MAIN_ID, (hi - lo) as u64);
    let mut w: u32 = 0;
    unsafe WriteFile(unsafe GetStdHandle(STD_ERROR_HANDLE), &b[0], n as u32, &mut w, null);
    unsafe TerminateProcess(unsafe GetCurrentProcess(), 134);
    unsafe c_abort();
}

// Report an exhausted coroutine stack (std's runtime grows and guards those itself), then end the process.
@platform(windows)
@export("__sc_stack_overflow")
@noreturn
fn stack_overflow() {
    stk_report(true);
}

@platform(windows)
fn stk_veh(ep: *mut EXCEPTION_POINTERS) i32 {
    if unsafe (*(*ep).record).code == EXCEPTION_STACK_OVERFLOW {
        stk_report(false);
    }
    return 0; // EXCEPTION_CONTINUE_SEARCH
}

// Arm the calling thread to report a stack overflow: the stack the report runs in once the guard is gone
// (the exception record alone, with its AVX-512 register state, fills the page the system leaves).
@platform(windows)
@export("__sc_stack_arm")
fn stack_arm(_lo: usize, _hi: usize) *mut void {
    let mut g: u32 = 16384;
    unsafe SetThreadStackGuarantee(&mut g);
    return null;
}

// Release what `stack_arm` armed: nothing on Windows.
@platform(windows)
@export("__sc_stack_disarm")
fn stack_disarm(_alt: *mut void) {}

@platform(windows)
extern "C" "io.h" {
    fn _setmode(fd: i32, mode: i32) i32;
}
// The C name, read where it is used: a constant with a value would leave its check to the registry unit,
// which would then include <windows.h> and compile alone.
@platform(windows)
extern "C" "fcntl.h" {
    @import("_O_BINARY")
    const O_BINARY: i32;
}

// Windows opens the standard streams in text mode, which writes "\n" as "\r\n" and folds "\r\n" to "\n" on
// read: every program switches them to binary before main, so they carry the same bytes on every host.
// Then the overflow report is armed.
@platform(windows)
fn stk_boot() {
    for fd in 0..3 {
        unsafe _setmode(fd, O_BINARY);
    }
    unsafe STK_MAIN_ID = unsafe GetCurrentThreadId();
    let v = VehBits { f: stk_veh };
    unsafe AddVectoredExceptionHandler(0, v.h);
    stack_arm(0, 0);
}

// ---- allocation tracker -----------------------------------------------------------------------------
// Gated at run time by SC_LEAK_CHECK: when unset every entry is a branch over the C call. When set, every
// live block is recorded with the address of the call that allocated it, survivors are reported to stderr
// at normal exit grouped by that site (`f`/`F` prefix: the exit status is 23 when anything leaked), and a
// second free or a realloc of a freed block is reported. The registry is sharded by address; each shard is
// an open-addressing table under a spinlock, plus a short history of freed blocks that it keeps allocated,
// so no allocator can hand out a held address and a later free of one is always a real double free.

// One recorded block.
struct LkEnt {
    pub ptr: *mut void,
    pub site: *const void,
    pub size: usize,
    pub epoch: u32, // `LK_EPOCH` when the block was recorded
    pub aligned: u32, // 1: from sc_lk_aligned_alloc, released by `lk_release_block`
}

const LK_EPOCHS: usize = 8;
const LK_SHARDS: usize = 64;
const LK_SHARD_BITS: usize = 6;
const LK_FREED_HISTORY: usize = 32;
static_assert(LK_SHARDS == 1 << LK_SHARD_BITS, "the shard bits match the power-of-two shard count");

const LK_NONE: LkEnt = LkEnt { ptr: null, site: null, size: 0, epoch: 0, aligned: 0 };

struct LkShard {
    pub tab: *mut LkEnt,
    pub cap: usize, // a power of two
    pub live: usize,
    pub bytes: usize,
    pub dbl: usize,
    pub alloc_n: usize, // recorded allocation calls, cumulative
    pub alloc_bytes: usize, // bytes those calls requested, cumulative
    pub freed: [LkEnt; 32],
    pub freed_next: usize,
    pub freed_count: usize,
    pub lock: i32,
}

// The address of the 64 shards, made by the first switch-on (`lk_made`): zeroed pages from the system, so
// that no static holds them (a static is evaluated at compile time, within the program's budget).
static mut LK_TABLE: usize = 0;
static mut LK_STATE: i32 = 0; // 0 unprobed, 1 off, 2 report, 3 fatal; any thread probes it
static mut LK_EPOCH: u32 = 0; // the tag of every allocation recorded from now on (`sc_lk_epoch_set`)
// Per-thread site-suppression depth for coroutine and fiber stacks.
@thread_local
static mut LK_BT_OFF: i32 = 0;

// Release block `e` with the call matching its allocation.
@platform(!windows)
fn lk_release_block(e: &LkEnt) {
    unsafe c_free(e.ptr);
}
@platform(windows)
fn lk_release_block(e: &LkEnt) {
    if e.aligned != 0 {
        unsafe _aligned_free(e.ptr);
    } else {
        unsafe c_free(e.ptr);
    }
}

@platform(windows)
extern "C" "malloc.h" {
    fn _aligned_malloc(n: usize, align: usize) *mut void;
    fn _aligned_free(p: *mut void);
}

// The tracker's own tables take zeroed pages from the system, never the malloc family: a program that
// interposes the family to count its calls (std::testing::bench_sys) counts the program's allocations
// alone. Windows and wasm have no such program and keep calloc.
@platform(macos | ios | linux | android)
fn lk_table_new(n: usize) *mut void {
    let p = unsafe mmap(null, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    return if p as isize == -1 {
        null;
    } else {
        p;
    };
}
@platform(windows | wasm)
fn lk_table_new(n: usize) *mut void {
    return unsafe c_calloc(1, n);
}
@platform(macos | ios | linux | android)
fn lk_table_free(p: *mut void, n: usize) {
    if p != null {
        unsafe munmap(p, n);
    }
}
@platform(windows | wasm)
fn lk_table_free(p: *mut void, _n: usize) {
    unsafe c_free(p);
}

fn lk_get() i32 {
    return unsafe atomic_load_i32(&mut LK_STATE, RELAXED);
}

fn lk_set(st: i32) {
    unsafe atomic_store_i32(&mut LK_STATE, st, RELAXED);
}

// xorshift of the address: shifts drop the bits they push out, so no step overflows.
const fn lk_hash(p: *const void) usize {
    let mut x = p as usize >> 4;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

// The shard table, made once: false when there is no memory for it.
fn lk_made() bool {
    if unsafe atomic_load_usize(&mut LK_TABLE, ACQUIRE) != 0 {
        return true;
    }
    let t = lk_table_new(LK_SHARDS * sizeof(LkShard));
    if t == null {
        return false;
    }
    if !unsafe atomic_cas_usize(&mut LK_TABLE, 0, t as usize, false, RELEASE, RELAXED) {
        lk_table_free(t, LK_SHARDS * sizeof(LkShard)); // another thread made it
    }
    return true;
}

// The shards there are to read: none before the table is made.
fn lk_made_shards() usize {
    if unsafe atomic_load_usize(&mut LK_TABLE, ACQUIRE) == 0 {
        return 0;
    }
    return LK_SHARDS;
}

// Shard `h` of the table, which `lk_on` found made.
fn lk_shard(h: usize) *mut LkShard {
    return unsafe (atomic_load_usize(&mut LK_TABLE, ACQUIRE) as *mut LkShard + h);
}

fn lk_shard_for(p: *const void) *mut LkShard {
    return lk_shard(lk_hash(p) & LK_SHARDS - 1);
}

fn lk_acquire(s: *mut LkShard) {
    while unsafe atomic_swap_i32(&mut (*s).lock, 1, ACQUIRE) != 0 {}
}

fn lk_release(s: *mut LkShard) {
    unsafe atomic_store_i32(&mut (*s).lock, 0, RELEASE);
}

// Drop a shard's table, counters and freed history, releasing the blocks the history holds (the lock word
// is left to the caller).
fn lk_shard_clear(s: *mut LkShard) {
    unsafe {
        for i in 0..(*s).freed_count {
            lk_release_block(&(*s).freed[i]);
        }
        lk_table_free((*s).tab, (*s).cap * sizeof(LkEnt));
        (*s).tab = null;
        (*s).cap = 0;
        (*s).live = 0;
        (*s).bytes = 0;
        (*s).dbl = 0;
        (*s).alloc_n = 0;
        (*s).alloc_bytes = 0;
        (*s).freed_next = 0;
        (*s).freed_count = 0;
    }
}

const fn lk_slot(p: *const void, cap: usize) usize {
    return lk_hash(p) >> LK_SHARD_BITS & cap - 1;
}

// The live entry of `p` in shard `s`, or null.
const fn lk_find(s: *mut LkShard, p: *const void) *mut LkEnt {
    let cap = unsafe (*s).cap;
    if cap == 0 {
        return null;
    }
    let tab = unsafe (*s).tab;
    let mut i = lk_slot(p, cap);
    for _ in 0..cap {
        let e = unsafe (tab + i);
        if unsafe (*e).ptr == null {
            return null;
        }
        if (unsafe (*e).ptr) as *const void == p {
            return e;
        }
        i = i + 1 & cap - 1;
    }
    return null;
}

fn lk_put(tab: *mut LkEnt, cap: usize, e: LkEnt) {
    let mut i = lk_slot(e.ptr, cap);
    for _ in 0..cap {
        if unsafe (*(tab + i)).ptr == null {
            unsafe *(tab + i) = e;
            return;
        }
        i = i + 1 & cap - 1;
    }
    unsafe c_abort();
}

fn lk_grow(s: *mut LkShard) bool {
    let cap = unsafe (*s).cap;
    // A power of two: lk_slot and the probes mask with cap - 1. 128 entries fill one 4 KiB page on a
    // 64-bit host.
    let ncap = if cap != 0 {
        cap * 2;
    } else {
        128usize;
    };
    if ncap > ~0usize / sizeof(LkEnt) {
        return false;
    }
    let nt = lk_table_new(ncap * sizeof(LkEnt)) as *mut LkEnt;
    if nt == null {
        return false;
    }
    let tab = unsafe (*s).tab;
    for i in 0..cap {
        let e = unsafe *(tab + i);
        if e.ptr != null {
            lk_put(nt, ncap, e);
        }
    }
    lk_table_free(tab, cap * sizeof(LkEnt));
    unsafe (*s).tab = nt;
    unsafe (*s).cap = ncap;
    return true;
}

// Remove `entry` from its table, moving later entries of the probe run back into the hole.
const fn lk_erase(s: *mut LkShard, entry: *mut LkEnt) {
    let tab = unsafe (*s).tab;
    let cap = unsafe (*s).cap;
    let mut hole = (entry as usize - tab as usize) / sizeof(LkEnt);
    let mut i = hole + 1 & cap - 1;
    for _ in 0..cap {
        let e = unsafe *(tab + i);
        if e.ptr == null {
            break;
        }
        let home = lk_slot(e.ptr, cap);
        if (i + cap - home & cap - 1) >= (i + cap - hole & cap - 1) {
            unsafe *(tab + hole) = e;
            hole = i;
        }
        i = i + 1 & cap - 1;
    }
    unsafe *(tab + hole) = LK_NONE;
}

// Keep freed block `entry` (freed at `site`) in the history, releasing the oldest one when it is full.
fn lk_remember_free(s: *mut LkShard, entry: LkEnt, site: *const void) {
    unsafe {
        if (*s).freed_count == LK_FREED_HISTORY {
            lk_release_block(&(*s).freed[(*s).freed_next]);
        }
        let mut freed = entry;
        freed.site = if LK_BT_OFF == 0 {
            site;
        } else {
            null;
        };
        (*s).freed[(*s).freed_next] = freed;
        (*s).freed_next = ((*s).freed_next + 1) % LK_FREED_HISTORY;
        if (*s).freed_count < LK_FREED_HISTORY {
            (*s).freed_count += 1;
        }
    }
}

// The freed-history entry of `p` in shard `s`, newest first, or null.
const fn lk_find_freed(s: *mut LkShard, p: *const void) *mut LkEnt {
    let mut i = unsafe (*s).freed_next;
    for _ in 0..unsafe (*s).freed_count {
        i = (i + LK_FREED_HISTORY - 1) % LK_FREED_HISTORY;
        if (unsafe (*s).freed[i].ptr) as *const void == p {
            return unsafe &mut (*s).freed[i];
        }
    }
    return null;
}

// Suspend allocation-site capture on this thread: a coroutine runtime brackets task execution with this
// and `lk_bt_resume`, because a coroutine stack has no standard frame base. Detection stays active.
@export("sc_lk_bt_pause")
fn lk_bt_pause() {
    unsafe LK_BT_OFF += 1;
}

// Resume what `lk_bt_pause` suspended.
@export("sc_lk_bt_resume")
fn lk_bt_resume() {
    unsafe LK_BT_OFF -= 1;
}

fn lk_capture(p: *mut void, n: usize, site: *const void) LkEnt {
    return LkEnt {
        ptr: p,
        site: if unsafe LK_BT_OFF == 0 {
            site;
        } else {
            null;
        },
        size: n,
        epoch: unsafe atomic_load_u32(&mut LK_EPOCH, RELAXED),
        aligned: 0,
    };
}

@platform(macos | ios | linux)
extern "C" "execinfo.h" {
    fn backtrace(buf: *mut *mut void, n: i32) i32;
    fn backtrace_symbols(buf: *const *mut void, n: i32) *mut *mut char;
    fn backtrace_symbols_fd(buf: *const *mut void, n: i32, fd: i32);
}

// The allocation site `site` on stderr: its symbol where the platform names one, else its address.
@platform(macos | ios | linux)
fn lk_site_print(site: *const void) {
    if site == null {
        return;
    }
    let at = site as *mut void;
    let syms = unsafe backtrace_symbols(&at, 1);
    if syms != null {
        put("    ");
        put(unsafe *syms);
        put("\n");
        unsafe c_free(syms);
        return;
    }
    put("    ");
    put_hex(at as u64);
    put("\n");
}
// No runtime DWARF symbolizer: an ASLR-stable offset from the image base, which `addr2line` resolves.
@platform(windows)
fn lk_site_print(site: *const void) {
    if site == null {
        return;
    }
    let base = (unsafe GetModuleHandleA(null)) as usize;
    put("    leak-site +");
    put_hex((site as usize - base) as u64);
    put("\n");
}
// bionic declares <execinfo.h> only from API 33, and wasm has no frame walk: the address alone.
@platform(android | wasm)
fn lk_site_print(site: *const void) {
    if site == null {
        return;
    }
    put("    ");
    put_hex(site as u64);
    put("\n");
}

// End the process at a double free in a fatal run.
fn lk_fatal_stop() {
    if lk_get() == 3 {
        die();
    }
}

// Report the double free of `p`; `snap` holds the entry recorded when the block was first freed.
fn lk_double(p: *const void, snap: LkEnt, site: *const void) {
    put("== super-c double free: ");
    put_hex(p as u64);
    put(" (");
    put_dec(snap.size as u64);
    put(" byte(s)) ==\npreviously freed at:\n");
    lk_site_print(snap.site);
    put("freed again at:\n");
    lk_site_print(site);
    lk_fatal_stop();
}

// The report's order: by site, then by size.
const fn lk_group_cmp(va: *const void, vb: *const void) i32 {
    let a = unsafe *(va as *const LkEnt);
    let b = unsafe *(vb as *const LkEnt);
    if a.site != b.site {
        return if a.site as usize < b.site as usize {
            -1;
        } else {
            1;
        };
    }
    if a.size != b.size {
        return if a.size < b.size {
            -1;
        } else {
            1;
        };
    }
    return 0;
}

// The exit report: the survivors grouped by site (the first 64 sites), the double-free count, and in a
// fatal run exit status 23 when either is not zero. Tracking stops for good.
fn lk_report() {
    for h in 0..LK_SHARDS {
        lk_acquire(lk_shard(h));
    }
    let enabled = lk_get() >= 2;
    let mut n: usize = 0;
    let mut bytes: usize = 0;
    let mut dbl: usize = 0;
    if enabled {
        for h in 0..LK_SHARDS {
            let s = lk_shard(h);
            n += unsafe (*s).live;
            bytes += unsafe (*s).bytes;
            dbl += unsafe (*s).dbl;
        }
    }
    let mut v: *mut LkEnt = null;
    let mut vbytes: usize = 0; // the size of `v`'s table: `n` becomes the entries copied
    if n != 0 && n <= ~0usize / sizeof(LkEnt) {
        vbytes = n * sizeof(LkEnt);
        v = lk_table_new(vbytes) as *mut LkEnt;
    }
    if v != null {
        let mut k: usize = 0;
        for h in 0..LK_SHARDS {
            let s = lk_shard(h);
            for i in 0..unsafe (*s).cap {
                let e = unsafe *((*s).tab + i);
                if k < n && e.ptr != null {
                    unsafe *(v + k) = e;
                    k += 1;
                }
            }
        }
        n = k;
    } else {
        n = 0;
    }
    let fatal = enabled && lk_get() == 3;
    lk_set(1); // the report's own prints may allocate: stop tracking
    for h in 0..LK_SHARDS {
        let s = lk_shard(h);
        lk_shard_clear(s);
        lk_release(s);
    }
    if n != 0 {
        unsafe c_qsort(v, n, sizeof(LkEnt), lk_group_cmp);
        put("== super-c leaks: ");
        put_dec(n as u64);
        put(" allocation(s), ");
        put_dec(bytes as u64);
        put(" byte(s) ==\n");
        let mut shown: usize = 0;
        let mut i: usize = 0;
        while i < n {
            let mut j = i;
            let mut gbytes: usize = 0;
            while j < n && lk_group_cmp(unsafe (v + i), unsafe (v + j)) == 0 {
                gbytes += unsafe (*(v + j)).size;
                j += 1;
            }
            if shown < 64 {
                put("leak: ");
                put_dec((j - i) as u64);
                put(" allocation(s), ");
                put_dec(gbytes as u64);
                put(" byte(s)\n");
                lk_site_print(unsafe (*(v + i)).site);
            }
            shown += 1;
            i = j;
        }
        if shown > 64 {
            put("... (");
            put_dec((shown - 64) as u64);
            put(" more leak site(s))\n");
        }
    }
    lk_table_free(v, vbytes);
    if dbl != 0 {
        put("== super-c double frees: ");
        put_dec(dbl as u64);
        put(" ==\n");
    }
    if fatal && (n != 0 || dbl != 0) {
        unsafe c_fflush(null); // _Exit does not flush
        unsafe c_exit_now(23);
    }
}

// Whether tracking is on, probing SC_LEAK_CHECK the first time.
fn lk_on() bool {
    let mut cur = lk_get();
    if cur == 0 {
        let e = unsafe c_getenv("SC_LEAK_CHECK");
        let mut st: i32 = 1;
        if e != null && (unsafe e[0]) as u8 != 0 && (unsafe e[0]) as u8 != b'0' {
            st = if (unsafe e[0]) as u8 == b'f' || (unsafe e[0]) as u8 == b'F' {
                3;
            } else {
                2;
            };
        }
        if st >= 2 && !lk_made() {
            st = 1; // no memory for the table: no tracking
        }
        // One probe wins the move out of the unprobed state, so the exit report is registered once.
        if unsafe atomic_cas_i32(&mut LK_STATE, 0, st, false, RELAXED, RELAXED) {
            if st >= 2 {
                unsafe c_atexit(lk_report);
            }
            cur = st;
        } else {
            cur = lk_get();
        }
    }
    // The state is relaxed: the table's own load makes its pages visible to this thread.
    return cur >= 2 && unsafe atomic_load_usize(&mut LK_TABLE, ACQUIRE) != 0;
}

// Forget every record in a forked child, whose parent's other threads may have held a shard lock.
@export("sc_lk_fork_child_reset")
fn lk_fork_child_reset() {
    if !lk_on() {
        return;
    }
    for h in 0..LK_SHARDS {
        let s = lk_shard(h);
        unsafe (*s).lock = 0;
        lk_shard_clear(s);
    }
}

// Report the survivors now instead of at exit, and stop tracking.
@export("sc_lk_report_now")
fn lk_report_now() {
    if lk_on() {
        lk_report();
    }
}

// Track from here on without an exit report (SC_LEAK_CHECK, when set, keeps its own state). Returns 1: the
// tracker counts.
@export("sc_lk_stats_enable")
fn lk_stats_enable() i32 {
    lk_on();
    if lk_made() {
        unsafe atomic_cas_i32(&mut LK_STATE, 1, 2, false, RELAXED, RELAXED);
    }
    return 1;
}

// Tag every allocation recorded from now on with epoch `e`.
@export("sc_lk_epoch_set")
fn lk_epoch_set(e: u32) {
    unsafe atomic_store_u32(&mut LK_EPOCH, e, RELAXED);
}

// `out[0]` the allocation calls, `out[1]` the bytes they requested: the cumulative counters alone.
@export("sc_lk_counts")
unsafe fn lk_counts(out: *mut u64) {
    let mut n: u64 = 0;
    let mut bytes: u64 = 0;
    for h in 0..lk_made_shards() {
        let s = lk_shard(h);
        lk_acquire(s);
        n += (unsafe (*s).alloc_n) as u64;
        bytes += (unsafe (*s).alloc_bytes) as u64;
        lk_release(s);
    }
    unsafe out[0] = n;
    unsafe out[1] = bytes;
}

// The words of `lk_stats`: two counters, then a live count and live bytes per epoch.
const LK_STATS_WORDS: usize = 2 + 2 * LK_EPOCHS;

// `out[0]` the allocation calls, `out[1]` the bytes requested, `out[2 + 2e]` and `out[3 + 2e]` the live
// count and bytes of epoch `e` (epochs past the last slot fold into it), `LK_STATS_WORDS` words. All zero
// while tracking is off.
@export("sc_lk_stats")
unsafe fn lk_stats(out: *mut u64) {
    let mut w = [0u64; 18];
    static_assert(LK_STATS_WORDS == 18, "the record's words");
    for h in 0..lk_made_shards() {
        let s = lk_shard(h);
        lk_acquire(s);
        w[0] += (unsafe (*s).alloc_n) as u64;
        w[1] += (unsafe (*s).alloc_bytes) as u64;
        let tab = unsafe (*s).tab;
        for i in 0..unsafe (*s).cap {
            let e = unsafe *(tab + i);
            if e.ptr != null {
                let k = if e.epoch as usize < LK_EPOCHS {
                    e.epoch as usize;
                } else {
                    LK_EPOCHS - 1;
                };
                w[2 + 2 * k] += 1;
                w[3 + 2 * k] += e.size as u64;
            }
        }
        lk_release(s);
    }
    for i in 0..LK_STATS_WORDS {
        unsafe out[i] = w[i];
    }
}

// Insert `e` under the held lock. A live entry for the same address means the block was freed behind the
// tracker's back and then reused. False when bookkeeping memory ran out.
fn lk_insert(s: *mut LkShard, e: LkEnt) bool {
    unsafe {
        (*s).alloc_n += 1;
        (*s).alloc_bytes += e.size;
        let old = lk_find(s, e.ptr);
        if old != null {
            (*s).bytes -= (*old).size;
            *old = e;
            (*s).bytes += e.size;
            return true;
        }
        if ((*s).live + 1) * 10 >= (*s).cap * 7 && !lk_grow(s) {
            return false;
        }
        lk_put((*s).tab, (*s).cap, e);
        (*s).live += 1;
        (*s).bytes += e.size;
    }
    return true;
}

// Record new block `p` of `n` bytes allocated at `site`.
fn lk_track(p: *mut void, n: usize, site: *const void, aligned: u32) {
    if p == null || !lk_on() {
        return;
    }
    let mut e = lk_capture(p, n, site);
    e.aligned = aligned;
    let s = lk_shard_for(p);
    lk_acquire(s);
    if lk_get() >= 2 && !lk_insert(s, e) {
        lk_set(1);
    }
    lk_release(s);
}

// The code address an allocation entry returns to: its caller's call site. Each entry is `@noinline`, so
// the address is in its caller in every profile.
@intrinsic("frame.return_address")
const fn return_address() *const void;

@export("sc_lk_malloc")
@noinline
unsafe fn lk_malloc(n: usize) *mut void {
    let site = return_address();
    let p = unsafe c_malloc(n);
    lk_track(p, n, site, 0);
    return p;
}

@export("sc_lk_calloc")
@noinline
unsafe fn lk_calloc(count: usize, n: usize) *mut void {
    let site = return_address();
    let p = unsafe c_calloc(count, n);
    if p != null {
        lk_track(p, count * n, site, 0); // calloc fails on an overflowing product
    }
    return p;
}

// An over-aligned block (std's Global allocator): `align` is a power of two, at least `sizeof(usize)`.
@export("sc_lk_aligned_alloc")
@noinline
unsafe fn lk_aligned_alloc(n: usize, align: usize) *mut void {
    let site = return_address();
    let p = aligned_block(n, align);
    lk_track(p, n, site, 1);
    return p;
}

@platform(windows)
fn aligned_block(n: usize, align: usize) *mut void {
    return unsafe _aligned_malloc(n, align);
}
// C11 aligned_alloc takes a size that is a multiple of the alignment.
@platform(!windows)
fn aligned_block(n: usize, align: usize) *mut void {
    if n > ~0usize - align {
        return null;
    }
    return unsafe c_aligned_alloc(align, n + align - 1 & ~(align - 1));
}

// A realloc. The registry key is an ADDRESS, and an address survives the realloc that invalidates the
// pointer holding it: reading `p` again after a realloc is undefined. A tracked block therefore never goes
// through realloc: it is copied into a new block and the freed history keeps the old one allocated, so no
// other thread can receive its address before the bookkeeping is done. Only untracked blocks go through
// realloc.
@export("sc_lk_realloc")
@noinline
unsafe fn lk_realloc(p: *mut void, n: usize) *mut void {
    let site = return_address();
    let track = lk_on();
    let mut held: *mut LkShard = null;
    let mut old: *mut LkEnt = null;
    if p != null && track {
        held = lk_shard_for(p);
        lk_acquire(held);
    }
    if p != null && track && lk_get() >= 2 {
        old = lk_find(held, p);
        let freed = if old == null {
            lk_find_freed(held, p);
        } else {
            null;
        };
        if freed != null {
            let snap = unsafe *freed;
            unsafe (*held).dbl += 1;
            lk_release(held);
            put("== super-c realloc of freed pointer: ");
            put_hex(p as u64);
            put(" ==\npreviously freed at:\n");
            lk_site_print(snap.site);
            put("reallocated again at:\n");
            lk_site_print(site);
            lk_fatal_stop();
            // The history still holds the old block: hand back fresh memory with its contents.
            let fresh = unsafe c_malloc(n);
            lk_track(fresh, n, site, 0);
            if fresh != null {
                unsafe c_memcpy(
                    fresh,
                    p,
                    if snap.size < n {
                        snap.size;
                    } else {
                        n;
                    },
                );
            }
            return fresh;
        }
    }
    let q = if old != null {
        // A tracked block moves, and the old one goes to the freed history, which keeps it allocated.
        let fresh = unsafe c_malloc(n);
        let osz = unsafe (*old).size;
        if fresh != null {
            unsafe c_memcpy(
                fresh,
                p,
                if osz < n {
                    osz;
                } else {
                    n;
                },
            );
        }
        fresh;
    } else {
        unsafe c_realloc(p, n);
    };
    if q != null && track && lk_get() >= 2 {
        let e = lk_capture(q, n, site);
        // Memory the tracker never saw (a foreign allocator) stays untracked.
        if old != null || p == null {
            if old != null {
                let consumed = unsafe *old;
                unsafe (*held).bytes -= consumed.size;
                unsafe (*held).live -= 1;
                lk_erase(held, old);
                lk_remember_free(held, consumed, site);
            }
            let next = lk_shard_for(q);
            if next != held {
                if held != null {
                    lk_release(held);
                }
                lk_acquire(next);
                held = next;
            }
            if lk_get() >= 2 && !lk_insert(held, e) {
                lk_set(1);
            }
        }
    }
    if held != null {
        lk_release(held);
    }
    return q;
}

// Unrecord block `p` freed at `site`, reporting a double free. True when the caller must not release the
// block: the freed history holds it, or it was freed before.
fn lk_untrack(p: *mut void, site: *const void) bool {
    if p == null || !lk_on() {
        return false;
    }
    let mut skip = false;
    let mut dbl = false;
    let mut snap = LK_NONE;
    let s = lk_shard_for(p);
    lk_acquire(s);
    if lk_get() >= 2 {
        let e = lk_find(s, p);
        if e != null {
            let freed = unsafe *e;
            unsafe (*s).bytes -= freed.size;
            unsafe (*s).live -= 1;
            lk_erase(s, e);
            lk_remember_free(s, freed, site);
            skip = true; // the history holds the block
        } else {
            let freed = lk_find_freed(s, p);
            if freed != null {
                snap = unsafe *freed;
                dbl = true;
                skip = true; // the block may belong to someone else now: never free it twice
                unsafe (*s).dbl += 1;
            }
        }
    }
    lk_release(s);
    if dbl {
        lk_double(p, snap, site);
    }
    return skip;
}

@export("sc_lk_free")
@noinline
unsafe fn lk_free(p: *mut void) {
    if !lk_untrack(p, return_address()) {
        unsafe c_free(p);
    }
}

// Release a block of `lk_aligned_alloc`.
@export("sc_lk_aligned_free")
@noinline
unsafe fn lk_aligned_free(p: *mut void) {
    if lk_untrack(p, return_address()) {
        return;
    }
    aligned_release(p);
}

@platform(windows)
fn aligned_release(p: *mut void) {
    unsafe _aligned_free(p);
}
@platform(!windows)
fn aligned_release(p: *mut void) {
    unsafe c_free(p);
}

// ---- test-timeout diagnostics -------------------------------------------------------------------------
// A process whose environment names a file in SC_TEST_DIAG (the test runner sets it in each test's
// process; every process the test starts inherits it) answers SIGURG by appending to that file a header
// naming itself and the stack of each of its threads, one thread at a time, each asked with SIGUSR2. SIGURG
// is ignored by default, so the runner can ask every process of a test's tree: one that is not a Super-C
// program (cc, ld) ignores it. The handlers use only open, write, close, backtrace and short sleeps: the
// process is killed after it. Elsewhere SIGURG keeps its default.

// The capture file's path, copied from SC_TEST_DIAG (a heap block: a static is evaluated at compile time).
@platform(macos | ios | linux | android)
static mut DIAG_PATH: *mut char = null;
@platform(macos | ios | linux | android)
static mut DIAG_FD: i32 = -1;
@platform(macos | ios | linux | android)
static mut DIAG_ACK: i32 = 0;

@platform(macos | ios | linux | android)
fn diag_say(s: *const char) {
    unsafe c_write(unsafe DIAG_FD, s, unsafe c_strlen(s));
}

@platform(macos | ios | linux | android)
fn diag_num(v: u64) {
    let mut b = [0u8; 24];
    let n = dec_text(&mut b, v);
    unsafe c_write(unsafe DIAG_FD, &b[24 - n], n);
}

// This thread's stack into the file, then the acknowledgement the asking thread waits for.
@platform(macos | ios | linux)
fn diag_stack(_sig: i32) {
    let mut f = [null as *mut void; 64];
    let n = unsafe backtrace(&mut f[0], 64);
    diag_say("--- thread\n");
    unsafe backtrace_symbols_fd(&f[0], n, unsafe DIAG_FD);
    unsafe atomic_store_i32(&mut DIAG_ACK, 1, RELEASE);
}
@platform(android)
fn diag_stack(_sig: i32) {
    diag_say("--- thread (no backtrace on this platform)\n");
    unsafe atomic_store_i32(&mut DIAG_ACK, 1, RELEASE);
}

// Ask thread `t` for its stack with `send` and wait for it, at most half a second.
@platform(macos | ios | linux | android)
fn diag_ask(sent: bool) {
    if !sent {
        return;
    }
    let ms = timespec { tv_sec: 0, tv_nsec: 1000000 };
    for _ in 0..500 {
        if unsafe atomic_load_i32(&mut DIAG_ACK, ACQUIRE) != 0 {
            return;
        }
        unsafe nanosleep(&ms, null);
    }
    diag_say("--- thread (did not answer: it blocks the signal)\n");
}

// Mach's thread list. The calls take prototypes of their own: <mach/mach.h> declares a `panic` of its own.
// A Mach port is a C `unsigned int`.
@platform(macos | ios)
extern "C" "mach/mach_init.h" {
    static mut mach_task_self_: u32;
}
@platform(macos | ios)
extern "C" {
    fn task_threads(task: u32, list: *mut *mut u32, n: *mut u32) i32;
    fn mach_port_deallocate(task: u32, name: u32) i32;
    fn vm_deallocate(task: u32, addr: usize, size: usize) i32;
}
// The program's name: the build's POSIX level hides `getprogname` on Darwin.
@platform(macos | ios)
extern "C" "crt_externs.h" {
    fn _NSGetProgname() *mut *mut char;
}

// Every other thread's stack: Mach lists the task's threads.
@platform(macos | ios)
fn diag_threads() {
    let task = unsafe mach_task_self_;
    let mut th: *mut u32 = null;
    let mut nth: u32 = 0;
    if unsafe task_threads(task, &mut th, &mut nth) != 0 {
        return;
    }
    let me = unsafe pthread_self();
    for i in 0..nth as usize {
        let t = unsafe pthread_from_mach_thread_np(unsafe th[i]);
        let tb = unsafe *(((&t) as *const pthread_t) as *const usize);
        if tb != 0 && tb != unsafe *(((&me) as *const pthread_t) as *const usize) {
            unsafe atomic_store_i32(&mut DIAG_ACK, 0, RELAXED);
            diag_ask(unsafe pthread_kill(t, SIGUSR2) == 0);
        }
        unsafe mach_port_deallocate(task, unsafe th[i]);
    }
    unsafe vm_deallocate(task, th as usize, nth as usize * sizeof(u32));
}

// Without a header: glibc declares `syscall` only under _DEFAULT_SOURCE, which the build's strict POSIX
// level does not define. The prototype is `intptr_t syscall(intptr_t, ...)`, the C library's `long` one.
@platform(linux | android)
extern "C" {
    fn syscall(n: isize, ...) isize;
}
@platform(linux | android)
@arch(x86_64)
const SYS_GETTID: isize = 186;
@platform(linux | android)
@arch(x86_64)
const SYS_TGKILL: isize = 234;
@platform(linux | android)
@arch(aarch64)
const SYS_GETTID: isize = 178;
@platform(linux | android)
@arch(aarch64)
const SYS_TGKILL: isize = 131;
// No Linux runs on wasm32 (a check for that pair only): the calls fail with ENOSYS.
@platform(linux | android)
@arch(wasm32)
const SYS_GETTID: isize = -1;
@platform(linux | android)
@arch(wasm32)
const SYS_TGKILL: isize = -1;
// `d_name` of `struct dirent` (glibc and bionic: after d_ino, d_off, d_reclen and d_type).
@platform(linux | android)
const DIRENT_NAME_AT: usize = 19;

@platform(android)
extern "C" {
    fn getprogname() *const char;
}
@platform(linux | android)
extern "C" "dirent.h" {
    type DIR;
    fn opendir(path: *const char) *mut DIR;
    fn readdir(dir: *mut DIR) *mut void;
    fn closedir(dir: *mut DIR) i32;
}

// Every other thread's stack: /proc lists the task's threads, tgkill asks each.
@platform(linux | android)
fn diag_threads() {
    let d = unsafe opendir("/proc/self/task");
    if d == null {
        return;
    }
    let pid = unsafe c_getpid();
    let me = unsafe syscall(SYS_GETTID);
    loop {
        let e = unsafe readdir(d);
        if e == null {
            break;
        }
        let name = (e as usize + DIRENT_NAME_AT) as *const char;
        let mut tid: isize = 0;
        let mut i: usize = 0;
        while (unsafe name[i]) as u8 >= b'0' && (unsafe name[i]) as u8 <= b'9' && i < 12 {
            tid = tid * 10 + ((unsafe name[i]) as u8 - b'0') as isize;
            i += 1;
        }
        if i != 0 && tid != me {
            unsafe atomic_store_i32(&mut DIAG_ACK, 0, RELAXED);
            diag_ask(unsafe syscall(SYS_TGKILL, pid as isize, tid, SIGUSR2 as isize) == 0);
        }
    }
    unsafe closedir(d);
}

@platform(macos | ios)
fn prog_name() *const char {
    return unsafe *_NSGetProgname();
}
@platform(android)
fn prog_name() *const char {
    return unsafe getprogname();
}
// The last component of the executed file's path (the kernel's AT_EXECFN): glibc's
// `program_invocation_short_name` needs _GNU_SOURCE.
@platform(linux)
fn prog_name() *const char {
    let p = unsafe getauxval(AT_EXECFN);
    if p == 0 {
        return "?";
    }
    let mut k = unsafe c_strlen(p as *const char);
    while k > 0 && unsafe *((p + k - 1) as *const u8) != b'/' {
        k -= 1;
    }
    return (p + k) as *const char;
}

@platform(macos | ios | linux | android)
fn diag_dump(_sig: i32) {
    unsafe DIAG_FD = unsafe c_open(unsafe DIAG_PATH, O_WRONLY | O_APPEND | O_CREAT, 0o644);
    if unsafe DIAG_FD < 0 {
        return;
    }
    diag_say("\n--- process ");
    diag_num((unsafe c_getpid()) as u64);
    diag_say(" ");
    diag_say(prog_name());
    diag_say(": the stack of every thread\n");
    diag_stack(0);
    diag_threads();
    unsafe c_close(unsafe DIAG_FD);
    unsafe DIAG_FD = -1;
}

// Install the dump when SC_TEST_DIAG names a file: at startup, and again by the test runner once it has
// set the variable in a test's process.
@platform(macos | ios | linux | android)
@export("__sc_diag_install")
fn diag_install() {
    let p = unsafe c_getenv("SC_TEST_DIAG");
    if p == null || (unsafe p[0]) as u8 == 0 {
        return;
    }
    // A block of the C allocator, never released: the handler may run until the process ends.
    let n = unsafe c_strlen(p);
    let copy = (unsafe c_malloc(n + 1)) as *mut char;
    if copy == null {
        return;
    }
    unsafe c_memcpy(copy, p, n + 1);
    unsafe DIAG_PATH = copy;
    diag_warm();
    let mut sa = unsafe zeroed::<sigaction>();
    unsafe sigemptyset(&mut sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sa.handler = diag_stack;
    unsafe c_sigaction(SIGUSR2, &sa, null);
    sa.handler = diag_dump;
    unsafe c_sigaction(SIGURG, &sa, null);
}
@platform(windows | wasm)
@export("__sc_diag_install")
fn diag_install() {}

// The first backtrace loads the unwinder, which allocates: never in a handler.
@platform(macos | ios | linux)
fn diag_warm() {
    let mut f = [null as *mut void; 1];
    unsafe backtrace(&mut f[0], 1);
}
@platform(android)
fn diag_warm() {}

// ---- startup ------------------------------------------------------------------------------------------

// Before main: the overflow and illegal-instruction reports (and on Windows binary standard streams), and
// the test-timeout dump. wasm has neither.
@platform(!wasm)
fn boot() {
    stk_boot();
    diag_install();
}

// The init-array entry of the platform's executable format: the loader calls it before `main`.
@platform(macos | ios)
@unsafe(link_section = "__DATA,__mod_init_func,mod_init_funcs")
static mut INIT_ENTRY: fn() = boot;
@platform(linux | android)
@unsafe(link_section = ".init_array")
static mut INIT_ENTRY: fn() = boot;
@platform(windows)
@unsafe(link_section = ".CRT$XCU")
static mut INIT_ENTRY: fn() = boot;
