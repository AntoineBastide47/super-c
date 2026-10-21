// The platform substrate of the concurrency runtime: monotonic clock, CPU count, the current-coroutine and
// worker thread-locals, address-based parking, spinlocks, guard-paged stacks, OS threads and locks, and a
// stackful context switch. These are the raw, unsafe building blocks the Super-C scheduler is built on;
// prefer `std/parallel/platform.spc` for the safe pieces. Import with `import sc_runtime;`. Every call
// requires `unsafe` except the queries (clock, cycle counter, page size, CPU count, worker index, parked
// count, stack bytes, inline context size, `sc_rt_asan`), the spin and yield hints, and `sc_rt_sleep_ns`.
//
// Targets: POSIX (macOS, Linux) parks threads on a static parking lot over per-thread pthread condition
// variables and maps stacks with mmap; Windows x86-64 parks on WaitOnAddress, locks with SRWLOCK and
// CONDITION_VARIABLE, and grows committed stacks from a vectored exception handler; wasm32 has one thread,
// so a wait that would block returns and what needs a second thread or stack fails at the call. The
// context switch is hand-written assembly for x86-64 (System V and Windows) and AArch64; wasm has none.
import atomic;
import errno;
import stdio;
import stdlib;

// Parking is the one piece with a per-OS backing LIBRARY: POSIX parks on pthread condition variables
// (libpthread), except bionic, which keeps those entry points in libc and ships no such library to name.
// Windows parks on WaitOnAddress, which lives in the synchronization API set rather than kernel32's
// import library: omit the flag and the link fails on those three symbols alone.
@platform(macos | linux | ios)
@link("pthread")
extern "C" {}

@platform(windows)
@link("synchronization")
extern "C" {}

/// `sc_rt_fail_arm` operations: the substrate's fallible calls, one constant each.
pub const FAIL_THREAD_CREATE: i32 = 1;
pub const FAIL_THREAD_JOIN: i32 = 2;
pub const FAIL_THREAD_DETACH: i32 = 3;
pub const FAIL_STACK_MAP: i32 = 4;
pub const FAIL_STACK_GUARD: i32 = 5;
/// The substrate's own allocations: thread handles, locks, condition variables, contexts.
pub const FAIL_ALLOC: i32 = 6;
pub const FAIL_STACK_RELEASE: i32 = 7;
const FAIL_NONE: i32 = 0;

// Memory-order codes of `atomic`.
const RELAXED: i32 = 0;
const ACQUIRE: i32 = 1;
const RELEASE: i32 = 2;
const ACQ_REL: i32 = 3;

extern "C" "stdlib.h" {
    @import("getenv")
    fn c_getenv(name: *const char) *const char;
}

// Entry points of the program's generated runtime (super_rt.c), declared by super_rt.h: the stack
// overflow report arms a thread (its stack bounds when known; the signal stack to release at its end, or
// null), releases that signal stack, records the task stack size the message quotes, and on Windows
// reports an exhausted coroutine stack.
extern "C" {
    @platform(!wasm)
    @import("__sc_stack_arm")
    fn rt_stack_arm(lo: usize, hi: usize) *mut void;
    @platform(!wasm)
    @import("__sc_stack_disarm")
    fn rt_stack_disarm(alt: *mut void);
    @platform(!wasm)
    @import("__sc_stack_task_size")
    fn rt_stack_task_size(bytes: usize);
    @platform(windows)
    @import("__sc_stack_overflow")
    fn rt_stack_overflow();
    /// 1 in a program built with AddressSanitizer (its frames carry redzones), else 0.
    @unsafe(safe)
    pub fn sc_rt_asan() i32;
}

// ThreadSanitizer's fiber API, declared by super_rt.h. It exists only in a `-fsanitize=thread` build: every
// call sits in an `if THREAD_SANITIZER` branch, which no other build emits.
extern "C" {
    @import("__tsan_get_current_fiber")
    fn tsan_get_current_fiber() *mut void;
    @import("__tsan_create_fiber")
    fn tsan_create_fiber(flags: u32) *mut void;
    @import("__tsan_destroy_fiber")
    fn tsan_destroy_fiber(fiber: *mut void);
    @import("__tsan_switch_to_fiber")
    fn tsan_switch_to_fiber(fiber: *mut void, flags: u32);
    @import("__tsan_acquire")
    fn tsan_acquire(addr: *mut void);
    @import("__tsan_release")
    fn tsan_release(addr: *mut void);
}

// ---- fatal errors and failure injection -------------------------------------------------------------

// The substrate's contract for a state it cannot recover from: say what, then abort.
fn die(what: str) {
    let err = stdio::stderr();
    unsafe stdio::fputs("super-c: ".ptr() as *const char, err);
    unsafe stdio::fwrite(what.ptr(), 1, what.len(), err);
    unsafe stdio::fputs("\n".ptr() as *const char, err);
    unsafe stdio::fflush(err);
    stdlib::abort();
}

static mut FAIL_KIND: i32 = 0;
static mut FAIL_LEFT: u32 = 0;

/// Failure injection for the substrate's tests: the `nth` call (1-based) of the operation `kind` (the
/// `FAIL_*` constants) fails the way the OS would (a null handle, a nonzero code), then the hook disarms
/// itself; `nth` 0 disarms. One relaxed load on each operation's slow path, nothing on a switch or park.
pub unsafe fn sc_rt_fail_arm(kind: i32, nth: u32) {
    unsafe atomic::store_u32(&mut FAIL_LEFT, nth, RELAXED);
    let mut k = FAIL_NONE;
    if nth != 0 {
        k = kind;
    }
    unsafe atomic::store_i32(&mut FAIL_KIND, k, RELEASE);
}

// Whether the armed failure is `kind` and this is its nth call; the hit disarms the hook.
fn fail_hit(kind: i32) bool {
    if unsafe atomic::load_i32(&mut FAIL_KIND, ACQUIRE) != kind {
        return false;
    }
    // The count reaches zero on exactly one call; a call that finds it at zero already does not hit.
    if unsafe atomic::sub_u32(&mut FAIL_LEFT, 1, ACQ_REL) != 1 {
        return false;
    }
    unsafe atomic::store_i32(&mut FAIL_KIND, FAIL_NONE, RELEASE);
    return true;
}

// The substrate's own heap blocks (handles, locks, condvars, contexts), under the ALLOC hook.
fn rt_alloc(n: usize, zeroed: bool) *mut void {
    if fail_hit(FAIL_ALLOC) {
        return null;
    }
    if zeroed {
        return unsafe stdlib::calloc(1, n);
    }
    return unsafe stdlib::malloc(n);
}

// ---- stack accounting -----------------------------------------------------------------------------
// One relaxed add per stack map or unmap, next to a syscall that costs microseconds.
static mut STACK_BYTES: usize = 0;

/// Bytes currently mapped for task stacks, guard pages included: what `sc_rt_stack_alloc` handed out and
/// `sc_rt_stack_free` has not taken back. Stacks are mapped, so neither the allocator counters nor the
/// resident set (untouched pages) show them.
pub fn sc_rt_stack_bytes() usize {
    return unsafe atomic::load_usize(&mut STACK_BYTES, RELAXED);
}

fn stack_note(bytes: usize, mapped: bool) {
    if mapped {
        unsafe atomic::add_usize(&mut STACK_BYTES, bytes, RELAXED);
    } else {
        unsafe atomic::sub_usize(&mut STACK_BYTES, bytes, RELAXED);
    }
}

// ---- thread-locals --------------------------------------------------------------------------------
// Every use of a thread-local goes through an accessor the C compiler cannot inline, so its address is
// computed on the thread that runs the use: a coroutine that parks can resume on another worker.
@thread_local
static mut TLS_SLOT: *mut void = null;
@thread_local
static mut WIDX_SLOT: i32 = -1;

/// Store this thread's running-coroutine pointer.
pub unsafe fn sc_rt_tls_set(p: *mut void) {
    unsafe TLS_SLOT = p;
}

/// This thread's running-coroutine pointer, null before `sc_rt_tls_set`.
pub unsafe fn sc_rt_tls_get() *mut void {
    return unsafe TLS_SLOT;
}

/// Which pool worker this thread is (-1 off the pool): how a push finds its own run deque. Separate from
/// the coroutine slot, so a worker finds its deque while a coroutine is switched onto it.
pub unsafe fn sc_rt_widx_set(i: i32) {
    unsafe WIDX_SLOT = i;
}

/// This thread's worker index, -1 off the pool.
pub fn sc_rt_widx_get() i32 {
    return unsafe WIDX_SLOT;
}

// ---- spin hint, cycle counter, spinlock -------------------------------------------------------------

/// One spin hint: what a worker runs between look-again attempts before it parks. It stays runnable.
/// `pause` stops the pipeline speculating past the loop.
@arch(x86_64)
pub fn sc_rt_cpu_relax() {
    unsafe {
        asm("pause" :  :  : "memory");
    }
}
/// One spin hint: what a worker runs between look-again attempts before it parks. It stays runnable.
/// `isb`, not `yield`: `yield` is a no-op on Apple cores, so the loop would poll the line many times more.
@arch(aarch64)
pub fn sc_rt_cpu_relax() {
    unsafe {
        asm("isb" :  :  : "memory");
    }
}
/// One spin hint: a compiler barrier, as wasm has no spin instruction.
@arch(wasm32)
pub fn sc_rt_cpu_relax() {
    unsafe {
        asm("" :  :  : "memory");
    }
}

/// A cheap monotone cycle counter for the scheduler's compile-gated statistics (rdtsc). Not comparable
/// across cores or machines: only differences on one thread mean anything.
@arch(x86_64)
pub fn sc_rt_cycles() u64 {
    let mut lo: u32 = 0;
    let mut hi: u32 = 0;
    unsafe {
        asm("rdtsc" : "=a"(lo), "=d"(hi));
    }
    return hi as u64 << 32 | lo as u64;
}
/// A cheap monotone cycle counter for the scheduler's compile-gated statistics (cntvct). Not comparable
/// across cores or machines: only differences on one thread mean anything.
@arch(aarch64)
pub fn sc_rt_cycles() u64 {
    let mut v: u64 = 0;
    unsafe {
        asm("mrs %0, cntvct_el0" : "=r"(v));
    }
    return v;
}
/// A cheap monotone counter for the scheduler's compile-gated statistics: the monotonic clock.
@arch(wasm32)
pub fn sc_rt_cycles() u64 {
    return sc_rt_now_ns();
}

/// A spinlock over a plain i32 (0 free, 1 held), for critical sections too short to be worth a mutex: on
/// macOS a contended pthread mutex is two syscalls, this is a cache-line handoff. Not recursive; never
/// block while holding it. The backoff to a thread yield covers a descheduled holder.
pub unsafe fn sc_rt_spin_lock(word: *mut i32) {
    loop {
        if unsafe atomic::swap_i32(word, 1, ACQUIRE) == 0 {
            return;
        }
        // Read-only until it looks free again: hammering the exchange would bounce the line.
        let mut n = 0;
        while unsafe atomic::load_i32(word, RELAXED) != 0 {
            if n == 4096 {
                n = 0;
                sc_rt_thread_yield();
            }
            sc_rt_cpu_relax();
            n += 1;
        }
    }
}

/// Release a spin word taken by `sc_rt_spin_lock`.
pub unsafe fn sc_rt_spin_unlock(word: *mut i32) {
    unsafe atomic::store_i32(word, 0, RELEASE);
}

// ---- mutex parking-lot buckets ----------------------------------------------------------------------
// Static storage for the task-aware mutex's waiter queues: 64 line-sized buckets, picked by a Fibonacci
// hash of the lock's address. Zero is exactly the empty state.
const BUCKET_BITS: u64 = 6;
const BUCKETS: usize = 64;

// The bucket of `addr` in either parking lot: the hash keeps the top BUCKET_BITS bits.
fn addr_bucket(addr: *const void) usize {
    return (((addr as usize >> 4) as u64).wrapping_mul(0x9E3779B97F4A7C15u64) >> 64 - BUCKET_BITS) as usize;
}

// The layout std/parallel/sync.spc's `LotBucket` reads.
@align(64)
struct MutexBucket {
    pub lock: i32,
    pub pad: i32,
    pub head: *mut void,
    pub tail: *mut void,
}

static mut MUTEX_LOT: [MutexBucket; 64] = [MutexBucket { lock: 0, pad: 0, head: null, tail: null }; 64];

/// One 64-byte static bucket of the mutex parking lot, keyed by the lock's address. Static so a waker may
/// touch it after the mutex itself was freed; the queue discipline lives in std/parallel/sync.spc.
pub unsafe fn sc_rt_lot_bucket(addr: *mut void) *mut void {
    return (unsafe &mut MUTEX_LOT[addr_bucket(addr)]) as *mut MutexBucket;
}

// ---- lock-order tracking ----------------------------------------------------------------------------
// A deadlock is reported the first time two locks are taken in OPPOSITE orders, not the first time the
// program hangs: an inversion that deadlocks one run in a thousand is found on the run that takes both.
// The order graph is a set of edges "a was held when b was taken", keyed by an ID the lock carries in its
// own `id` word (given on its first tracked acquisition, under the lock), not by its address: a lock
// moves with the value it guards. The held set is per THREAD: a coroutine that parks holding a lock and
// resumes on another worker is not followed, and `release` of a lock this thread does not hold is
// ignored. That costs recall and never invents a report. Compiled in only under LOCKDEP (the `race`
// profile): the hooks sit on a lock fast path of one CAS, and everywhere else they are empty.
const LO_HELD: usize = 32;
const LO_EDGES: usize = 4096;

struct LoEdge {
    pub a: u32,
    pub b: u32,
}

@thread_local
static mut LO_HELD_IDS: [u32; 32] = [0u32; 32];
@thread_local
static mut LO_NHELD: usize = 0;
static mut LO_EDGE: [LoEdge; 4096] = [LoEdge { a: 0, b: 0 }; 4096];
static mut LO_NEDGE: usize = 0;
static mut LO_NEXT: u32 = 0; // the last ID given out; 0 means "no ID yet"
static mut LO_LOCK: i32 = 0;
static mut LO_STATE: i32 = 0; // 0 unknown, 1 off, 2 report, 3 abort

// Whether SC_LOCK_ORDER turns tracking on. Every thread resolves this on its first lock, each racer
// computes the same value from the same environment, so relaxed atomics make the race defined.
fn lo_on() bool {
    let mut st = unsafe atomic::load_i32(&mut LO_STATE, RELAXED);
    if st == 0 {
        let e = unsafe c_getenv("SC_LOCK_ORDER".ptr() as *const char);
        st = 1;
        if e != null && (unsafe e[0]) as u8 != 0 && (unsafe e[0]) as u8 != b'0' {
            st = 2;
            if (unsafe e[0]) as u8 == b'f' || (unsafe e[0]) as u8 == b'F' {
                st = 3;
            }
        }
        unsafe atomic::store_i32(&mut LO_STATE, st, RELAXED);
    }
    return st >= 2;
}

/// Record the lock whose identity word is `id` as held by this thread (lock-order checking builds only).
pub unsafe fn sc_rt_lockdep_acquire(id: *mut u32) {
    if LOCKDEP {
        if !lo_on() {
            return;
        }
        if unsafe *id == 0 {
            unsafe *id = (unsafe atomic::add_u32(&mut LO_NEXT, 1, RELAXED)).wrapping_add(1);
        }
        let lock = unsafe *id;
        let n = unsafe LO_NHELD;
        if n > 0 {
            unsafe sc_rt_spin_lock(&mut LO_LOCK);
            for i in 0..n {
                let h = unsafe LO_HELD_IDS[i];
                if h == lock {
                    continue; // a recursive take: not an inversion
                }
                let mut seen = 0;
                for k in 0..unsafe LO_NEDGE {
                    if unsafe LO_EDGE[k].a == lock && unsafe LO_EDGE[k].b == h {
                        unsafe stdio::fputs(
                            "lock order inversion: this pair has already been taken the other way round\n".ptr() as *const char,
                            stdio::stderr(),
                        );
                        seen = 1;
                        break;
                    }
                    if unsafe LO_EDGE[k].a == h && unsafe LO_EDGE[k].b == lock {
                        seen = 2; // already recorded
                        break;
                    }
                }
                if seen == 0 && unsafe LO_NEDGE < LO_EDGES {
                    unsafe LO_EDGE[LO_NEDGE] = LoEdge { a: h, b: lock };
                    unsafe LO_NEDGE += 1;
                }
                if seen == 1 && unsafe atomic::load_i32(&mut LO_STATE, RELAXED) >= 3 {
                    unsafe sc_rt_spin_unlock(&mut LO_LOCK);
                    stdlib::abort();
                }
            }
            unsafe sc_rt_spin_unlock(&mut LO_LOCK);
        }
        if unsafe LO_NHELD < LO_HELD {
            unsafe LO_HELD_IDS[LO_NHELD] = lock;
            unsafe LO_NHELD += 1;
        }
    }
}

/// Record the lock as released.
pub unsafe fn sc_rt_lockdep_release(id: *mut u32) {
    if LOCKDEP {
        if !lo_on() {
            return;
        }
        let lock = unsafe *id;
        let mut i = unsafe LO_NHELD;
        while i > 0 {
            i -= 1;
            if unsafe LO_HELD_IDS[i] == lock {
                for k in i..unsafe LO_NHELD - 1 {
                    unsafe LO_HELD_IDS[k] = unsafe LO_HELD_IDS[k + 1];
                }
                unsafe LO_NHELD -= 1;
                return;
            }
        }
    }
}

/// Drop the lock from the order graph before it is freed.
pub unsafe fn sc_rt_lockdep_forget(id: *mut u32) {
    if LOCKDEP {
        if !lo_on() || unsafe *id == 0 {
            return;
        }
        let lock = unsafe *id;
        unsafe sc_rt_spin_lock(&mut LO_LOCK);
        let mut w: usize = 0;
        for k in 0..unsafe LO_NEDGE {
            if unsafe LO_EDGE[k].a != lock && unsafe LO_EDGE[k].b != lock {
                unsafe LO_EDGE[w] = LoEdge { a: unsafe LO_EDGE[k].a, b: unsafe LO_EDGE[k].b };
                w += 1;
            }
        }
        unsafe LO_NEDGE = w;
        unsafe sc_rt_spin_unlock(&mut LO_LOCK);
    }
}

// ---- POSIX bindings ---------------------------------------------------------------------------------

extern "C" "time.h" {
    @platform(!windows)
    struct timespec {
        pub tv_sec: i64,
        pub tv_nsec: isize,
    }
    @platform(macos | ios | linux | android)
    fn clock_gettime(clock: i32, ts: *mut timespec) i32;
    @platform(!windows)
    fn nanosleep(req: *const timespec, rem: *mut timespec) i32;
    @platform(macos | ios)
    const CLOCK_MONOTONIC: i32 = 6;
    @platform(linux | android)
    const CLOCK_MONOTONIC: i32 = 1;
}

// Darwin values the build's strict POSIX level hides (<time.h>, <sys/mman.h> and <unistd.h> define them
// only for _DARWIN_C_SOURCE), as the macOS SDK defines them.
@platform(macos | ios)
const CLOCK_MONOTONIC_RAW: i32 = 4;
@platform(macos | ios)
const MAP_ANON: i32 = 0x1000;
@platform(macos | ios)
const MADV_FREE_REUSABLE: i32 = 7;
@platform(macos | ios)
const MADV_FREE_REUSE: i32 = 8;
@platform(macos | ios)
const SC_NPROCESSORS_ONLN: i32 = 58;
// glibc defines MADV_DONTNEED only for _DEFAULT_SOURCE.
@platform(linux | android)
const MADV_DONTNEED: i32 = 4;

@platform(macos | ios | linux | android)
extern "C" "unistd.h" {
    @import("sysconf")
    fn c_sysconf(name: i32) isize;
    @import("write")
    fn c_write(fd: i32, buf: *const void, n: usize) isize;
    @import("close")
    fn c_close(fd: i32) i32;
    @platform(macos | ios)
    @import("_SC_PAGESIZE")
    const SC_PAGESIZE: i32 = 29;
    @platform(linux | android)
    @import("_SC_PAGESIZE")
    const SC_PAGESIZE: i32 = 30;
    @platform(linux | android)
    @import("_SC_NPROCESSORS_ONLN")
    const SC_NPROCESSORS_ONLN: i32 = 84;
}

@platform(macos | ios | linux | android)
extern "C" "sched.h" {
    fn sched_yield() i32;
}

@platform(macos | ios | linux | android)
extern "C" "errno.h" {
    const EINTR: i32 = 4;
    const ENOMEM: i32 = 12;
    const EINVAL: i32 = 22;
    @platform(macos | ios)
    const ETIMEDOUT: i32 = 60;
    @platform(linux | android)
    const ETIMEDOUT: i32 = 110;
    @platform(macos | ios)
    const EAGAIN: i32 = 35;
    @platform(linux | android)
    const EAGAIN: i32 = 11;
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
    fn mprotect(addr: *mut void, len: usize, prot: i32) i32;
    const PROT_NONE: i32 = 0;
    const PROT_READ: i32 = 1;
    const PROT_WRITE: i32 = 2;
    const MAP_PRIVATE: i32 = 2;
    @platform(linux | android)
    @import("MAP_ANONYMOUS")
    const MAP_ANON: i32 = 0x20;
}

// Declared by the headers only above the build's strict POSIX level, so these carry their own prototypes.
@platform(macos | ios | linux | android)
extern "C" {
    fn madvise(addr: *mut void, len: usize, advice: i32) i32;
}

@platform(macos | ios | linux | android)
extern "C" "pthread.h" {
    @platform(macos | ios)
    @layout(64, 8)
    type pthread_mutex_t;
    @platform(linux | android)
    @arch(x86_64)
    @layout(40, 8)
    type pthread_mutex_t;
    @platform(linux | android)
    @arch(aarch64)
    @layout(48, 8)
    type pthread_mutex_t;
    @layout(48, 8)
    type pthread_cond_t;
    @platform(macos | ios)
    @layout(16, 8)
    type pthread_condattr_t;
    @platform(linux | android)
    @arch(x86_64)
    @layout(4, 4)
    type pthread_condattr_t;
    @platform(linux | android)
    @arch(aarch64)
    @layout(8, 4)
    type pthread_condattr_t;
    @platform(linux | android)
    @arch(x86_64)
    @layout(56, 8)
    type pthread_attr_t;
    @platform(linux | android)
    @arch(aarch64)
    @layout(64, 8)
    type pthread_attr_t;
    @layout(sizeof(usize), sizeof(usize))
    type pthread_t;
    @platform(macos | ios)
    @layout(8, 8)
    type pthread_key_t;
    @platform(linux | android)
    @layout(4, 4)
    type pthread_key_t;

    fn pthread_mutex_init(m: *mut pthread_mutex_t, attr: *const void) i32;
    fn pthread_mutex_destroy(m: *mut pthread_mutex_t) i32;
    fn pthread_mutex_lock(m: *mut pthread_mutex_t) i32;
    fn pthread_mutex_unlock(m: *mut pthread_mutex_t) i32;
    fn pthread_cond_init(c: *mut pthread_cond_t, attr: *const pthread_condattr_t) i32;
    fn pthread_cond_destroy(c: *mut pthread_cond_t) i32;
    fn pthread_cond_wait(c: *mut pthread_cond_t, m: *mut pthread_mutex_t) i32;
    fn pthread_cond_timedwait(c: *mut pthread_cond_t, m: *mut pthread_mutex_t, deadline: *const timespec) i32;
    fn pthread_cond_signal(c: *mut pthread_cond_t) i32;
    @platform(linux | android)
    fn pthread_condattr_init(a: *mut pthread_condattr_t) i32;
    @platform(linux | android)
    fn pthread_condattr_setclock(a: *mut pthread_condattr_t, clock: i32) i32;
    @platform(linux | android)
    fn pthread_condattr_destroy(a: *mut pthread_condattr_t) i32;
    fn pthread_create(out: *mut pthread_t, attr: *const void, entry: fn(*mut void) *mut void, arg: *mut void) i32;
    fn pthread_join(t: pthread_t, ret: *mut *mut void) i32;
    fn pthread_detach(t: pthread_t) i32;
    fn pthread_self() pthread_t;
    fn pthread_key_create(key: *mut pthread_key_t, dtor: fn(*mut void)) i32;
    fn pthread_setspecific(key: pthread_key_t, value: *const void) i32;
    @platform(linux | android)
    fn pthread_attr_getstack(a: *const pthread_attr_t, addr: *mut *mut void, size: *mut usize) i32;
    @platform(linux | android)
    fn pthread_attr_destroy(a: *mut pthread_attr_t) i32;
}

// Non-portable pthread calls the build's strict POSIX level hides: their own prototypes.
@platform(macos | ios)
extern "C" {
    fn pthread_cond_timedwait_relative_np(c: *mut pthread_cond_t, m: *mut pthread_mutex_t, rel: *const timespec) i32;
}
@platform(linux | android)
extern "C" {
    fn pthread_getattr_np(t: pthread_t, a: *mut pthread_attr_t) i32;
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
    // `sa_handler` is the header's macro over the handler union's first member.
    @platform(macos | ios)
    struct sigaction {
        @import("sa_handler")
        pub handler: *mut void,
        pub sa_mask: sigset_t,
        pub sa_flags: i32,
    }
    @platform(linux | android)
    struct sigaction {
        @import("sa_handler")
        pub handler: *mut void,
        pub sa_mask: sigset_t,
        pub sa_flags: i32,
        pub sa_restorer: *mut void,
    }
    @import("sigaction")
    fn c_sigaction(sig: i32, act: *const sigaction, old: *mut sigaction) i32;
    fn sigemptyset(set: *mut sigset_t) i32;
    @platform(macos | ios)
    const SIGURG: i32 = 16;
    @platform(linux | android)
    const SIGURG: i32 = 23;
    @platform(macos | ios)
    const SA_RESTART: i32 = 2;
    @platform(linux | android)
    const SA_RESTART: i32 = 0x10000000;
}

// A signal handler's address, as `sa_handler` holds it.
@platform(macos | ios | linux | android)
union HandlerBits {
    pub f: fn(i32),
    pub p: *mut void,
}

// ---- POSIX clock, CPUs, sleep -------------------------------------------------------------------

/// Monotonic clock in nanoseconds since an unspecified epoch.
@platform(macos | ios)
pub fn sc_rt_now_ns() u64 {
    // CLOCK_MONOTONIC on Darwin ticks in microseconds; the raw clock keeps the nanoseconds a spawn latency
    // is measured in.
    let mut ts = timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe clock_gettime(CLOCK_MONOTONIC_RAW, &mut ts);
    return ts.tv_sec as u64 * 1000000000 + ts.tv_nsec as u64;
}
/// Monotonic clock in nanoseconds since an unspecified epoch.
@platform(linux | android)
pub fn sc_rt_now_ns() u64 {
    let mut ts = timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe clock_gettime(CLOCK_MONOTONIC, &mut ts);
    return ts.tv_sec as u64 * 1000000000 + ts.tv_nsec as u64;
}

/// Online core count (at least 1).
@platform(macos | ios | linux | android)
pub fn sc_rt_ncpu() usize {
    let n = unsafe c_sysconf(SC_NPROCESSORS_ONLN);
    if n > 0 {
        return n as usize;
    }
    return 1;
}

/// The page size, bytes: what a stack mapping and a reclaim are measured in.
@platform(macos | ios | linux | android)
pub fn sc_rt_page_size() usize {
    return (unsafe c_sysconf(SC_PAGESIZE)) as usize;
}

/// Sleep the calling OS thread for `ns` nanoseconds; zero or negative returns at once. Only for a thread
/// that is not running a coroutine: a coroutine parks on the scheduler's timer heap instead.
@platform(macos | ios | linux | android)
pub fn sc_rt_sleep_ns(ns: i64) {
    if ns <= 0 {
        return;
    }
    let mut ts = timespec { tv_sec: ns / 1000000000, tv_nsec: (ns % 1000000000) as isize };
    let mut rem = timespec { tv_sec: 0, tv_nsec: 0 };
    // Resume the remaining time after a signal.
    while unsafe nanosleep(&ts, &mut rem) != 0 && errno::errno() == EINTR {
        ts = rem;
    }
}

/// Yield this thread to the OS scheduler: the backoff a spin loop takes so a descheduled holder can run.
@platform(macos | ios | linux | android)
pub fn sc_rt_thread_yield() {
    unsafe sched_yield();
}

// ---- POSIX parking lot ----------------------------------------------------------------------------
// Every parked thread is a record in a static bucket (picked by the word's address) naming the word it
// waits on and the thread's own RETAINED parker (a mutex and condvar in thread-local storage, built by the
// thread's first park and never freed), so an unpark wakes exactly the threads waiting on that word.
//
// The record lives in the parking thread's frame. Anyone but its owner reads it only under the bucket's
// spinlock, and only while linked: an unparker unlinks it under that lock, takes the parker pointer with
// it, and signals the parker after the lock is released; the owner, once it has stopped sleeping,
// re-takes the lock to unlink the record itself, and if it finds the record already unlinked it waits for
// the signal that must be coming, so it never leaves the call (and its frame) while an unparker is still
// about to signal it. `sc_rt_unpark_all` walks its private chain of unlinked records outside the lock,
// reading each record before signalling its owner, sound for the same reason. A bounded wait that ends by
// its deadline claims nothing: a wake sent to a word nobody waits on is dropped, as the futex contract
// says, and the caller re-checks its own condition.
// The C objects stay zero until the parker initializes them on its first park.
@platform(macos | ios | linux | android)
struct Parker {
    pub m: pthread_mutex_t,
    pub cv: pthread_cond_t,
    pub signaled: i32, // under `m`: one pending wake, consumed by the sleep it ends
    pub ready: i32, // owner-only: `m` and `cv` are initialized
}

@platform(macos | ios | linux | android)
struct Pnode {
    pub addr: *mut i32,
    pub p: *mut Parker,
    pub next: *mut Pnode,
    pub linked: i32, // under the bucket lock: cleared by whoever unlinks the record
}

@platform(macos | ios | linux | android)
@align(64)
struct ParkBucket {
    pub lock: i32,
    pub head: *mut Pnode,
    pub tail: *mut Pnode,
}

@platform(macos | ios | linux | android)
static mut PARK_LOT: [ParkBucket; 64] = [ParkBucket { lock: 0, head: null, tail: null }; 64];

@platform(macos | ios | linux | android)
@thread_local
static mut PARKER: Parker = Parker { signaled: 0, ready: 0 };

// Timed waits measure the monotonic clock, so a wall-clock step moves no timeout. Linux binds each
// condvar to CLOCK_MONOTONIC; Darwin has no such attribute and waits a relative span instead.
@platform(macos | ios)
fn cond_init_mono(c: *mut pthread_cond_t) {
    unsafe pthread_cond_init(c, null);
}
@platform(linux | android)
fn cond_init_mono(c: *mut pthread_cond_t) {
    let mut a = unsafe zeroed::<pthread_condattr_t>();
    unsafe pthread_condattr_init(&mut a);
    unsafe pthread_condattr_setclock(&mut a, CLOCK_MONOTONIC);
    unsafe pthread_cond_init(c, &a);
    unsafe pthread_condattr_destroy(&mut a);
}

// The absolute CLOCK_MONOTONIC time `rel_ns` from now.
@platform(macos | ios | linux | android)
fn mono_deadline(rel_ns: i64) timespec {
    let mut ts = timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe clock_gettime(CLOCK_MONOTONIC, &mut ts);
    let ns = ts.tv_nsec as i64 + rel_ns % 1000000000;
    ts.tv_sec += rel_ns / 1000000000 + ns / 1000000000;
    ts.tv_nsec = (ns % 1000000000) as isize;
    return ts;
}

// pthread_cond_timedwait against a CLOCK_MONOTONIC `deadline`, on a condvar from `cond_init_mono`.
@platform(macos | ios)
fn cond_wait_until(c: *mut pthread_cond_t, m: *mut pthread_mutex_t, deadline: &timespec) i32 {
    let mut now = timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe clock_gettime(CLOCK_MONOTONIC, &mut now);
    let left = (deadline.tv_sec - now.tv_sec) * 1000000000 + (deadline.tv_nsec - now.tv_nsec) as i64;
    if left <= 0 {
        return ETIMEDOUT;
    }
    let rel = timespec { tv_sec: left / 1000000000, tv_nsec: (left % 1000000000) as isize };
    return unsafe pthread_cond_timedwait_relative_np(c, m, &rel);
}
@platform(linux | android)
fn cond_wait_until(c: *mut pthread_cond_t, m: *mut pthread_mutex_t, deadline: &timespec) i32 {
    return unsafe pthread_cond_timedwait(c, m, deadline);
}

// Unlink `n` from bucket `b`; the caller holds the bucket lock and `n` is linked after `prev` (null: first).
@platform(macos | ios | linux | android)
fn lot_unlink(b: usize, prev: *mut Pnode, n: *mut Pnode) {
    if prev != null {
        unsafe (*prev).next = unsafe (*n).next;
    } else {
        unsafe PARK_LOT[b].head = unsafe (*n).next;
    }
    if unsafe PARK_LOT[b].tail == n {
        unsafe PARK_LOT[b].tail = prev;
    }
    unsafe (*n).linked = 0;
}

// Sleep on the calling thread's parker until it is signalled; `deadline` (absolute, monotonic) bounds the
// sleep. Reports whether a signal was consumed.
@platform(macos | ios | linux | android)
fn parker_sleep(p: *mut Parker, deadline: *const timespec) bool {
    let m = unsafe &mut (*p).m;
    let c = unsafe &mut (*p).cv;
    unsafe pthread_mutex_lock(m);
    while unsafe (*p).signaled == 0 {
        if deadline != null {
            if cond_wait_until(c, m, unsafe &*deadline) == ETIMEDOUT {
                break;
            }
        } else {
            unsafe pthread_cond_wait(c, m);
        }
    }
    let got = unsafe (*p).signaled != 0;
    unsafe (*p).signaled = 0;
    unsafe pthread_mutex_unlock(m);
    return got;
}

@platform(macos | ios | linux | android)
fn parker_signal(p: *mut Parker) {
    let m = unsafe &mut (*p).m;
    unsafe pthread_mutex_lock(m);
    unsafe (*p).signaled = 1;
    unsafe pthread_cond_signal(unsafe &mut (*p).cv);
    unsafe pthread_mutex_unlock(m);
}

/// Park while `*word == expected` until an unpark of `word` or, for `timeout_ns >= 0`, the deadline;
/// `timeout_ns < 0` waits forever. Wakeups may be spurious: re-check the condition in a loop. The
/// unparker publishes the new state to `*word` before unparking, and an unpark reads nothing through the
/// address: the word may be in a frame the waiter has already left.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_park(word: *mut i32, expected: i32, timeout_ns: i64) {
    if unsafe atomic::load_i32(word, ACQUIRE) != expected {
        return;
    }
    let me = (unsafe &mut PARKER) as *mut Parker;
    if unsafe (*me).ready == 0 {
        unsafe pthread_mutex_init(unsafe &mut (*me).m, null);
        cond_init_mono(unsafe &mut (*me).cv);
        unsafe (*me).ready = 1;
    }
    let b = addr_bucket(word);
    let mut node = Pnode { addr: word, p: me, next: null, linked: 1 };
    let n = (&mut node) as *mut Pnode;
    let lock = (unsafe &mut PARK_LOT[b].lock) as *mut i32;
    unsafe sc_rt_spin_lock(lock);
    // Re-checked under the lock: an unparker publishes the new state before it takes this lock, so a
    // change that raced the first load is seen here and a change after this point finds the record queued.
    if unsafe atomic::load_i32(word, ACQUIRE) != expected {
        unsafe sc_rt_spin_unlock(lock);
        return;
    }
    if unsafe PARK_LOT[b].tail != null {
        unsafe (*PARK_LOT[b].tail).next = n;
    } else {
        unsafe PARK_LOT[b].head = n;
    }
    unsafe PARK_LOT[b].tail = n;
    unsafe sc_rt_spin_unlock(lock);
    let mut ts = timespec { tv_sec: 0, tv_nsec: 0 };
    let mut deadline: *const timespec = null;
    if timeout_ns >= 0 {
        ts = mono_deadline(timeout_ns);
        deadline = &ts;
    }
    if parker_sleep(me, deadline) {
        return; // the unparker unlinked the record before signalling
    }
    // Timed out (or woke without a signal). Take the record back, unless an unparker got to it first:
    // then its signal is on the way, and this frame must stay until it lands.
    unsafe sc_rt_spin_lock(lock);
    if unsafe (*n).linked != 0 {
        let mut prev: *mut Pnode = null;
        let mut c = unsafe PARK_LOT[b].head;
        while c != n {
            prev = c;
            c = unsafe (*c).next;
        }
        lot_unlink(b, prev, n);
        unsafe sc_rt_spin_unlock(lock);
        return;
    }
    unsafe sc_rt_spin_unlock(lock);
    parker_sleep(me, null);
}

/// Wake one thread parked on `word`.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_unpark_one(word: *mut i32) {
    let b = addr_bucket(word);
    let lock = (unsafe &mut PARK_LOT[b].lock) as *mut i32;
    let mut p: *mut Parker = null;
    unsafe sc_rt_spin_lock(lock);
    let mut prev: *mut Pnode = null;
    let mut c = unsafe PARK_LOT[b].head;
    while c != null {
        if unsafe (*c).addr == word {
            p = unsafe (*c).p;
            lot_unlink(b, prev, c);
            break;
        }
        prev = c;
        c = unsafe (*c).next;
    }
    unsafe sc_rt_spin_unlock(lock);
    if p != null {
        parker_signal(p);
    }
}

/// Wake every thread parked on `word`.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_unpark_all(word: *mut i32) {
    let b = addr_bucket(word);
    let lock = (unsafe &mut PARK_LOT[b].lock) as *mut i32;
    let mut mine: *mut Pnode = null; // the unlinked records, chained through their own `next`
    unsafe sc_rt_spin_lock(lock);
    let mut prev: *mut Pnode = null;
    let mut c = unsafe PARK_LOT[b].head;
    while c != null {
        let nx = unsafe (*c).next;
        if unsafe (*c).addr == word {
            lot_unlink(b, prev, c);
            unsafe (*c).next = mine;
            mine = c;
        } else {
            prev = c;
        }
        c = nx;
    }
    unsafe sc_rt_spin_unlock(lock);
    while mine != null {
        // Read before the signal: the owner leaves (and its frame with it) only once signalled.
        let nx = unsafe (*mine).next;
        let p = unsafe (*mine).p;
        parker_signal(p);
        mine = nx;
    }
}

/// Threads parked in the parking lot, each with a record an unpark of its word finds: for a test that
/// must wait until its threads are asleep. Zero on a backend that keeps no records (Windows, wasm).
@platform(macos | ios | linux | android)
pub fn sc_rt_parked() usize {
    let mut n: usize = 0;
    for b in 0..BUCKETS {
        let lock = (unsafe &mut PARK_LOT[b].lock) as *mut i32;
        unsafe sc_rt_spin_lock(lock);
        let mut c = unsafe PARK_LOT[b].head;
        while c != null {
            n += 1;
            c = unsafe (*c).next;
        }
        unsafe sc_rt_spin_unlock(lock);
    }
    return n;
}

// ---- POSIX stacks -------------------------------------------------------------------------------

/// A guard-paged stack: an inaccessible page sits just below the returned usable low end, so an overflow
/// faults instead of corrupting memory. Returns the usable low end (the stack grows down from low+size),
/// or null: a `size` that is zero, not a whole number of pages or too large to add a guard page to is
/// rejected before anything is mapped, and a mapping whose guard cannot be installed is unmapped again.
/// Free with the same `size`. The whole stack is mapped; pages fault in as it is used.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_stack_alloc(size: usize) *mut void {
    let pg = sc_rt_page_size();
    if size == 0 || size % pg != 0 || size > usize::MAX - pg {
        return null;
    }
    if fail_hit(FAIL_STACK_MAP) {
        return null;
    }
    let total = size + pg;
    let m = unsafe mmap(null, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if m as usize == usize::MAX {
        return null; // MAP_FAILED
    }
    // A stack without its guard page is not handed out: an overflow on it would corrupt whatever the
    // kernel mapped below instead of faulting.
    if fail_hit(FAIL_STACK_GUARD) || unsafe mprotect(m, pg, PROT_NONE) != 0 {
        if unsafe munmap(m, total) != 0 {
            die("cannot release a task stack");
        }
        return null;
    }
    stack_note(total, true);
    return (m as usize + pg) as *mut void;
}

/// Release a stack from `sc_rt_stack_alloc` (`usable` and `size` as returned). A release the OS refuses
/// is fatal: the runtime cannot account for a mapping it no longer owns.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_stack_free(usable: *mut void, size: usize) {
    let pg = sc_rt_page_size();
    if fail_hit(FAIL_STACK_RELEASE) || unsafe munmap((usable as usize - pg) as *mut void, size + pg) != 0 {
        die("cannot release a task stack");
    }
    stack_note(size + pg, false);
}

/// Give the pages of an IDLE cached stack back to the OS, keeping the mapping and its guard; the next use
/// faults zero pages back in. 0 on success. Never for a live stack.
@platform(macos | ios)
pub unsafe fn sc_rt_stack_reclaim(usable: *mut void, size: usize) i32 {
    // MADV_FREE_REUSABLE lowers the resident count at once; plain MADV_FREE only marks the pages for
    // reclaim under pressure and leaves them counted until then.
    return unsafe madvise(usable, size, MADV_FREE_REUSABLE);
}
/// Give the pages of an IDLE cached stack back to the OS, keeping the mapping and its guard; the next use
/// faults zero pages back in. 0 on success. Never for a live stack.
@platform(linux | android)
pub unsafe fn sc_rt_stack_reclaim(usable: *mut void, size: usize) i32 {
    return unsafe madvise(usable, size, MADV_DONTNEED);
}

/// The pages of a reclaimed stack are about to be used again: macOS counts MADV_FREE_REUSABLE pages out of
/// the footprint until told otherwise. The call cannot fail on a mapping this process owns.
@platform(macos | ios)
pub unsafe fn sc_rt_stack_reuse(usable: *mut void, size: usize) {
    unsafe madvise(usable, size, MADV_FREE_REUSE);
}
/// The pages of a reclaimed stack are about to be used again: a touch is all this platform needs.
@platform(linux | android)
pub unsafe fn sc_rt_stack_reuse(_usable: *mut void, _size: usize) {}

/// Record the usable task stack size the overflow report quotes.
@platform(!wasm)
pub unsafe fn sc_rt_stack_note_size(bytes: usize) {
    unsafe rt_stack_task_size(bytes);
}

// ---- POSIX stack-overflow reporting ---------------------------------------------------------------
// The handler is the program's own (super_rt.c, armed for the main thread before main); each thread the
// runtime starts arms itself here. Each thread's signal stack is released when the thread exits, through
// a thread-specific key: a pool that restarts starts new threads, and each would otherwise keep a mapping.
@platform(macos | ios | linux | android)
static mut SIGSTK_KEY: pthread_key_t = unsafe zeroed::<pthread_key_t>();
@platform(macos | ios | linux | android)
static mut SIGSTK_STATE: i32 = 0; // 0 not created, 1 being created, 2 settled
@platform(macos | ios | linux | android)
static mut SIGSTK_KEYED: bool = false;

@platform(macos | ios | linux | android)
fn sigstk_drop(m: *mut void) {
    unsafe rt_stack_disarm(m);
}

// Create the key once; every caller returns whether it exists.
@platform(macos | ios | linux | android)
fn sigstk_keyed() bool {
    let st = (unsafe &mut SIGSTK_STATE) as *mut i32;
    if unsafe atomic::load_i32(st, ACQUIRE) == 0 && unsafe atomic::cas_i32(st, 0, 1, false, ACQUIRE, RELAXED) {
        unsafe SIGSTK_KEYED = unsafe pthread_key_create(&mut SIGSTK_KEY, sigstk_drop) == 0;
        unsafe atomic::store_i32(st, 2, RELEASE);
    }
    while unsafe atomic::load_i32(st, ACQUIRE) != 2 {
        sc_rt_thread_yield();
    }
    return unsafe SIGSTK_KEYED;
}

/// Arm this thread to report a stack overflow, its own stack's or a coroutine's, instead of dying on a bare
/// fault: every thread the runtime starts calls it first. It gives the thread a signal stack of its own (the
/// thread's exit releases it) and records its stack bounds. No-op on wasm.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_stack_guard_install() {
    // Without the key the signal stack cannot be released at thread exit, so the thread does without.
    if !sigstk_keyed() {
        return;
    }
    let (lo, hi) = own_stack_bounds();
    let m = unsafe rt_stack_arm(lo, hi);
    if m != null && unsafe pthread_setspecific(SIGSTK_KEY, m) != 0 {
        unsafe rt_stack_disarm(m);
    }
}

// The bounds of this thread's stack, so a fault at its guard reads as an overflow wherever the stack
// pointer is; (0, 0) when unknown. The program's runtime reads them itself on macOS.
@platform(macos | ios)
fn own_stack_bounds() (usize, usize) {
    return 0, 0;
}
@platform(linux | android)
fn own_stack_bounds() (usize, usize) {
    let mut lo: usize = 0;
    let mut hi: usize = 0;
    let mut at = unsafe zeroed::<pthread_attr_t>();
    if unsafe pthread_getattr_np(pthread_self(), &mut at) == 0 {
        let mut addr: *mut void = null;
        let mut size: usize = 0;
        if unsafe pthread_attr_getstack(&at, &mut addr, &mut size) == 0 {
            lo = addr as usize;
            hi = lo + size;
        }
        unsafe pthread_attr_destroy(&mut at);
    }
    return lo, hi;
}

// ---- POSIX threads and locks ----------------------------------------------------------------------

/// Start an OS thread running `entry(arg)`: 0 on success with `*out` the handle `sc_rt_thread_join`
/// consumes (a handle never joined or detached leaks the thread's bookkeeping), else an errno value.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_thread_create(out: *mut *mut void, entry: fn(*mut void) *mut void, arg: *mut void) i32 {
    // A heap `pthread_t` rather than a cast: `pthread_t` is opaque and need not fit a pointer.
    let h = rt_alloc(sizeof(pthread_t), false);
    if h == null {
        return ENOMEM;
    }
    let mut rc = EAGAIN;
    if !fail_hit(FAIL_THREAD_CREATE) {
        rc = unsafe pthread_create(h as *mut pthread_t, null, entry, arg);
    }
    if rc != 0 {
        unsafe stdlib::free(h);
        return rc;
    }
    unsafe *out = h;
    return 0;
}

/// Wait for a thread from `sc_rt_thread_create`; 0 on success, which releases the handle. A failed join
/// keeps it: the thread may still be running, and the caller aborts.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_thread_join(handle: *mut void) i32 {
    if handle == null || fail_hit(FAIL_THREAD_JOIN) {
        return EINVAL;
    }
    let mut ret: *mut void = null;
    let rc = unsafe pthread_join(*(handle as *mut pthread_t), &mut ret);
    if rc == 0 {
        unsafe stdlib::free(handle);
    }
    return rc;
}

/// Give up the right to join: the thread runs on and the OS releases it at exit; the handle is consumed
/// either way. 0 on success; nonzero means the handle named no joinable thread, a programmer error the
/// caller treats as fatal.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_thread_detach(handle: *mut void) i32 {
    if handle == null {
        return EINVAL;
    }
    let mut rc = EINVAL;
    if !fail_hit(FAIL_THREAD_DETACH) {
        rc = unsafe pthread_detach(*(handle as *mut pthread_t));
    }
    unsafe stdlib::free(handle);
    return rc;
}

/// A NON-recursive mutex, released by the thread that took it; null when allocation fails.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_mutex_new() *mut void {
    let m = rt_alloc(sizeof(pthread_mutex_t), false);
    if m != null {
        unsafe pthread_mutex_init(m as *mut pthread_mutex_t, null);
    }
    return m;
}

/// Destroy a mutex from `sc_rt_mutex_new` (null is ignored).
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_mutex_free(m: *mut void) {
    if m != null {
        unsafe pthread_mutex_destroy(m as *mut pthread_mutex_t);
        unsafe stdlib::free(m);
    }
}

/// Block until the mutex is held.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_mutex_lock(m: *mut void) {
    unsafe pthread_mutex_lock(m as *mut pthread_mutex_t);
}

/// Release a mutex the caller holds.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_mutex_unlock(m: *mut void) {
    unsafe pthread_mutex_unlock(m as *mut pthread_mutex_t);
}

/// A condition variable paired with a held `sc_rt_mutex_*`; null when allocation fails.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_cond_new() *mut void {
    let c = rt_alloc(sizeof(pthread_cond_t), false);
    if c != null {
        cond_init_mono(c as *mut pthread_cond_t);
    }
    return c;
}

/// Destroy a condition variable from `sc_rt_cond_new` (null is ignored).
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_cond_free(c: *mut void) {
    if c != null {
        unsafe pthread_cond_destroy(c as *mut pthread_cond_t);
        unsafe stdlib::free(c);
    }
}

/// Release `m`, sleep until signaled, reacquire `m`; spurious wakeups are possible.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_cond_wait(c: *mut void, m: *mut void) {
    unsafe pthread_cond_wait(c as *mut pthread_cond_t, m as *mut pthread_mutex_t);
}

/// Like `sc_rt_cond_wait`, but also returns once `rel_ns` nanoseconds have passed (negative waits forever);
/// nonzero exactly when the deadline woke it.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_cond_timedwait_ns(c: *mut void, m: *mut void, rel_ns: i64) i32 {
    let cv = c as *mut pthread_cond_t;
    let mx = m as *mut pthread_mutex_t;
    if rel_ns < 0 {
        return unsafe pthread_cond_wait(cv, mx);
    }
    let ts = mono_deadline(rel_ns);
    return cond_wait_until(cv, mx, &ts);
}

/// Wake one waiter.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_cond_signal(c: *mut void) {
    unsafe pthread_cond_signal(c as *mut pthread_cond_t);
}

// ---- POSIX test-timeout diagnostics ---------------------------------------------------------------
// In a test's process tree (SC_TEST_DIAG names the test's capture file) the runner asks each process for
// its state with SIGURG: the program's runtime appends its threads' stacks to that file, and a library
// adds its own state after them with `sc_rt_diag_chain` (std's reactor does), through `sc_rt_diag_write`.
// Any other process keeps SIGURG as it was. The dumps run in the handler, so they read with relaxed loads
// and only write.
@platform(macos | ios | linux | android)
const DIAG_MAX: usize = 4;
@platform(macos | ios | linux | android)
const DIAG_PATH_MAX: usize = 1024;

@platform(macos | ios | linux | android)
static mut DIAG_FNS: [Option<fn()>; 4] = [Option::<fn()>::None; 4];
@platform(macos | ios | linux | android)
static mut DIAG_N: usize = 0;
@platform(macos | ios | linux | android)
static mut DIAG_LOCK: i32 = 0;
@platform(macos | ios | linux | android)
static mut DIAG_PATH: [u8; 1024] = [0u8; 1024];
@platform(macos | ios | linux | android)
static mut DIAG_FD: i32 = -1;
// Storage for the action SIGURG had before: the runtime's own dump, run first.
@platform(macos | ios | linux | android)
static mut DIAG_PREV: sigaction = sigaction {};

@platform(macos | ios | linux | android)
fn diag_run(sig: i32) {
    // The runtime's own dump first: the process header and every thread's stack. SIG_DFL is 0, SIG_IGN 1.
    let prev = unsafe DIAG_PREV.handler;
    if prev as usize > 1 {
        let h = HandlerBits { p: prev };
        h.f(sig);
    }
    unsafe DIAG_FD = unsafe c_open(((&DIAG_PATH[0]) as *const u8) as *const char, O_WRONLY | O_APPEND | O_CREAT, 0o644);
    if unsafe DIAG_FD < 0 {
        return;
    }
    let n = unsafe atomic::load_usize(&mut DIAG_N, ACQUIRE);
    for i in 0..n {
        switch unsafe DIAG_FNS[i] {
            Some(f) => f(),
            None => {},
        };
    }
    unsafe c_close(DIAG_FD);
    unsafe DIAG_FD = -1;
}

/// Test-timeout diagnostics: in a test's process tree, run `dump` when the runner asks for the state after
/// a timeout, after the runtime's stack dump (it runs in a signal handler: relaxed loads,
/// `sc_rt_diag_write` only); a no-op elsewhere.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_diag_chain(dump: fn()) {
    let on = unsafe c_getenv("SC_TEST_DIAG".ptr() as *const char);
    if on == null {
        return;
    }
    let mut len: usize = 0;
    while (unsafe on[len]) as u8 != 0 {
        len += 1;
        if len >= DIAG_PATH_MAX {
            return;
        }
    }
    if len == 0 {
        return;
    }
    let lock = (unsafe &mut DIAG_LOCK) as *mut i32;
    while unsafe atomic::swap_i32(lock, 1, ACQUIRE) != 0 {
        sc_rt_cpu_relax();
    }
    let n = unsafe DIAG_N;
    let mut known = false;
    for i in 0..n {
        switch unsafe DIAG_FNS[i] {
            Some(f) => {
                known = known || f == dump;
            },
            None => {},
        };
    }
    if !known && n < DIAG_MAX {
        unsafe DIAG_FNS[n] = Option::<fn()>::Some(dump);
        unsafe atomic::store_usize(&mut DIAG_N, n + 1, RELEASE);
        if n == 0 {
            for i in 0..len + 1 {
                unsafe DIAG_PATH[i] = (unsafe on[i]) as u8;
            }
            let mut sa = unsafe zeroed::<sigaction>();
            unsafe sigemptyset(&mut sa.sa_mask);
            sa.sa_flags = SA_RESTART;
            let h = HandlerBits { f: diag_run };
            sa.handler = h.p;
            unsafe c_sigaction(SIGURG, &sa, &mut DIAG_PREV);
        }
    }
    unsafe atomic::store_i32(lock, 0, RELEASE);
}

/// Write `n` bytes to the test's capture file, from a `sc_rt_diag_chain` dump.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_diag_write(p: *const u8, n: usize) {
    if unsafe DIAG_FD < 0 {
        return;
    }
    unsafe c_write(DIAG_FD, p, n);
}

// ---- Windows bindings -------------------------------------------------------------------------------

@platform(windows)
extern "C" "windows.h" {
    // A union whose other members (two halves) lie inside `QuadPart`.
    @import("LARGE_INTEGER")
    union LARGE_INTEGER {
        @import("QuadPart")
        pub quad: i64,
    }
    // The first member is an anonymous union named through its `dwOemId`.
    @import("SYSTEM_INFO")
    struct SYSTEM_INFO {
        @import("dwOemId")
        pub oem_id: u32,
        @import("dwPageSize")
        pub page_size: u32,
        @import("lpMinimumApplicationAddress")
        pub min_addr: *mut void,
        @import("lpMaximumApplicationAddress")
        pub max_addr: *mut void,
        @import("dwActiveProcessorMask")
        pub active_mask: usize,
        @import("dwNumberOfProcessors")
        pub ncpu: u32,
        @import("dwProcessorType")
        pub cpu_type: u32,
        @import("dwAllocationGranularity")
        pub granularity: u32,
        @import("wProcessorLevel")
        pub cpu_level: u16,
        @import("wProcessorRevision")
        pub cpu_revision: u16,
    }
    @import("SRWLOCK")
    struct SRWLOCK {
        @import("Ptr")
        pub ptr: *mut void,
    }
    @import("CONDITION_VARIABLE")
    struct CONDITION_VARIABLE {
        @import("Ptr")
        pub ptr: *mut void,
    }
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

    fn QueryPerformanceFrequency(f: *mut LARGE_INTEGER) i32;
    fn QueryPerformanceCounter(c: *mut LARGE_INTEGER) i32;
    fn GetSystemInfo(si: *mut SYSTEM_INFO);
    fn Sleep(ms: u32);
    fn SwitchToThread() i32;
    fn WaitOnAddress(addr: *mut void, cmp: *mut void, size: usize, ms: u32) i32;
    fn WakeByAddressSingle(addr: *mut void);
    fn WakeByAddressAll(addr: *mut void);
    fn VirtualAlloc(addr: *mut void, size: usize, kind: u32, protect: u32) *mut void;
    fn VirtualFree(addr: *mut void, size: usize, kind: u32) i32;
    fn AddVectoredExceptionHandler(first: u32, handler: PVECTORED_EXCEPTION_HANDLER) *mut void;
    fn WaitForSingleObject(h: *mut void, ms: u32) u32;
    fn CloseHandle(h: *mut void) i32;
    fn InitializeSRWLock(l: *mut SRWLOCK);
    fn AcquireSRWLockExclusive(l: *mut SRWLOCK);
    fn ReleaseSRWLockExclusive(l: *mut SRWLOCK);
    fn InitializeConditionVariable(c: *mut CONDITION_VARIABLE);
    fn SleepConditionVariableSRW(c: *mut CONDITION_VARIABLE, l: *mut SRWLOCK, ms: u32, flags: u32) i32;
    fn WakeConditionVariable(c: *mut CONDITION_VARIABLE);
    fn GetLastError() u32;

    const INFINITE: u32 = 0xFFFFFFFF;
    const WAIT_OBJECT_0: u32 = 0;
    const ERROR_TIMEOUT: u32 = 1460;
    const MEM_COMMIT: u32 = 0x1000;
    const MEM_RESERVE: u32 = 0x2000;
    const MEM_RELEASE: u32 = 0x8000;
    const MEM_RESET: u32 = 0x80000;
    const PAGE_NOACCESS: u32 = 1;
    const PAGE_READWRITE: u32 = 4;
    const PAGE_GUARD: u32 = 0x100;
    const STATUS_GUARD_PAGE_VIOLATION: u32 = 0x80000001;
    const EXCEPTION_ACCESS_VIOLATION: u32 = 0xC0000005;
    const EXCEPTION_STACK_OVERFLOW: u32 = 0xC00000FD;
    const EXCEPTION_CONTINUE_SEARCH: i32 = 0;
    const EXCEPTION_CONTINUE_EXECUTION: i32 = -1;
}

@platform(windows)
extern "C" "process.h" {
    fn _beginthreadex(
        security: *mut void,
        stack: u32,
        entry: fn(*mut void) u32,
        arg: *mut void,
        flags: u32,
        id: *mut u32,
    ) usize;
}

// A vectored exception handler as AddVectoredExceptionHandler takes it. Its C result type is `LONG`, a C
// `long`, which has no Super-C spelling of its own (`i32` is C `int`): the two are one ABI type on Windows,
// so the function's address passes through this union.
@platform(windows)
@arch(x86_64)
union VehBits {
    pub f: fn(*mut EXCEPTION_POINTERS) i32,
    pub h: PVECTORED_EXCEPTION_HANDLER,
}

@platform(windows)
fn system_info() SYSTEM_INFO {
    let mut si = unsafe zeroed::<SYSTEM_INFO>();
    unsafe GetSystemInfo(&mut si);
    return si;
}

// ---- Windows clock, CPUs, sleep, parking ---------------------------------------------------------

// The counter frequency is fixed at boot; every thread may cache it, so the cache is a relaxed atomic.
@platform(windows)
static mut QPC_FREQ: i64 = 0;

/// Monotonic clock in nanoseconds since an unspecified epoch.
@platform(windows)
pub fn sc_rt_now_ns() u64 {
    let mut f = unsafe atomic::load_i64(&mut QPC_FREQ, RELAXED);
    if f == 0 {
        let mut q = LARGE_INTEGER { quad: 0 };
        unsafe QueryPerformanceFrequency(&mut q);
        f = q.quad;
        unsafe atomic::store_i64(&mut QPC_FREQ, f, RELAXED);
    }
    let mut c = LARGE_INTEGER { quad: 0 };
    unsafe QueryPerformanceCounter(&mut c);
    // Scaled in floating point: (ticks / freq) seconds to ns without overflowing.
    return (c.quad as f64 * 1e9 / f as f64) as u64;
}

/// Online core count (at least 1).
@platform(windows)
pub fn sc_rt_ncpu() usize {
    let n = system_info().ncpu;
    if n != 0 {
        return n as usize;
    }
    return 1;
}

/// The page size, bytes: what a stack mapping and a reclaim are measured in.
@platform(windows)
pub fn sc_rt_page_size() usize {
    return system_info().page_size as usize;
}

/// Sleep the calling OS thread for `ns` nanoseconds (millisecond granularity, all Sleep offers); zero or
/// negative returns at once. Only for a thread that is not running a coroutine.
@platform(windows)
pub fn sc_rt_sleep_ns(ns: i64) {
    if ns <= 0 {
        return;
    }
    unsafe Sleep((ns / 1000000) as u32);
}

/// Yield this thread to the OS scheduler: the backoff a spin loop takes so a descheduled holder can run.
@platform(windows)
pub fn sc_rt_thread_yield() {
    unsafe SwitchToThread();
}

/// Park while `*word == expected` until an unpark of `word` or, for `timeout_ns >= 0`, the deadline;
/// `timeout_ns < 0` waits forever. Wakeups may be spurious: re-check the condition in a loop.
@platform(windows)
pub unsafe fn sc_rt_park(word: *mut i32, expected: i32, timeout_ns: i64) {
    let mut cmp = expected;
    if timeout_ns < 0 {
        unsafe WaitOnAddress(word, &mut cmp, 4, INFINITE);
        return;
    }
    // WaitOnAddress counts its timeout in scheduler ticks (15.6 ms by default), so a timed wait can return
    // up to a tick EARLY, and spuriously as well: wait again for what remains until the word changes or
    // the deadline passes. The remainder rounds UP to whole milliseconds, else the last one would spin.
    let deadline = sc_rt_now_ns() + timeout_ns as u64;
    loop {
        if unsafe atomic::load_i32(word, ACQUIRE) != expected {
            return;
        }
        let now = sc_rt_now_ns();
        if now >= deadline {
            return;
        }
        let ms = ((deadline - now + 999999) / 1000000) as u32;
        unsafe WaitOnAddress(word, &mut cmp, 4, ms);
    }
}

/// Wake one thread parked on `word`.
@platform(windows)
pub unsafe fn sc_rt_unpark_one(word: *mut i32) {
    unsafe WakeByAddressSingle(word);
}

/// Wake every thread parked on `word`.
@platform(windows)
pub unsafe fn sc_rt_unpark_all(word: *mut i32) {
    unsafe WakeByAddressAll(word);
}

/// Threads parked with a record an unpark finds: zero, as this backend keeps no records.
@platform(windows | wasm)
pub fn sc_rt_parked() usize {
    return 0;
}

// ---- Windows stacks -------------------------------------------------------------------------------
// How much of a coroutine stack is committed up front. Windows charges commit against RAM + pagefile the
// moment it is asked for, touched or not, so committing 256 KiB per task would charge 2.5 GB for ten
// thousand mostly shallow tasks. This is above a typical task's high-water mark (about 16 KiB measured),
// so the growth path is reached only by deep ones.
@platform(windows)
const STK_INIT: usize = 32768;
// The bottom of a coroutine stack the overflow report runs in (TEB GuaranteedStackBytes, what
// SetThreadStackGuarantee sets for a thread): the kernel raises STATUS_STACK_OVERFLOW while this much is
// left. Without it the exception record alone, with its AVX-512 register state, fills the last page.
@platform(windows)
const STK_GUARANTEE: usize = 16384;
// The TEB fields the stack machinery lives in, read through gs: DeallocationStack is past the end of the
// NT_TIB the headers declare.
@platform(windows)
const TEB_STACK_BASE: usize = 0x08;
@platform(windows)
const TEB_STACK_LIMIT: usize = 0x10;
@platform(windows)
const TEB_DEALLOC: usize = 0x1478;

@platform(windows)
@arch(x86_64)
fn teb_read(off: usize) usize {
    let mut v: usize = 0;
    unsafe {
        asm("movq %%gs:(%1), %0" : "=r"(v) : "r"(off));
    }
    return v;
}

@platform(windows)
@arch(x86_64)
fn teb_write(off: usize, v: usize) {
    unsafe {
        asm("movq %0, %%gs:(%1)" :  : "r"(v), "r"(off) : "memory");
    }
}

// Where a stack's committed region starts, given its usable low end and size.
@platform(windows)
fn stk_initial_limit(base: usize, size: usize, pg: usize) usize {
    let mut init = STK_INIT;
    if size < init {
        init = size;
    }
    return base + size - init & ~(pg - 1);
}

/// A guard-paged stack: the low page is reserved and never committed, so an overflow faults instead of
/// walking into whatever is below. Returns the usable low end, or null (a `size` that is zero, not a whole
/// number of pages or too large for a guard page is rejected before any reservation). Only the top 32 KiB
/// is committed; the rest commits on demand as the task grows into it. Free with the same `size`.
@platform(windows)
pub unsafe fn sc_rt_stack_alloc(size: usize) *mut void {
    let pg = sc_rt_page_size();
    if size == 0 || size % pg != 0 || size > usize::MAX - pg {
        return null;
    }
    if fail_hit(FAIL_STACK_MAP) {
        return null;
    }
    let m = (unsafe VirtualAlloc(null, size + pg, MEM_RESERVE, PAGE_NOACCESS)) as usize;
    if m == 0 {
        return null;
    }
    let lim = stk_initial_limit(m + pg, size, pg);
    // The live part, plus one PAGE_GUARD page under it whose first touch asks for more.
    let mut ok = !fail_hit(FAIL_STACK_GUARD);
    ok = ok && unsafe VirtualAlloc(lim as *mut void, m + pg + size - lim, MEM_COMMIT, PAGE_READWRITE) != null;
    if ok && lim - pg >= m + pg {
        ok = unsafe VirtualAlloc((lim - pg) as *mut void, pg, MEM_COMMIT, PAGE_READWRITE | PAGE_GUARD) != null;
    }
    if !ok {
        unsafe VirtualFree(m as *mut void, 0, MEM_RELEASE);
        return null;
    }
    stack_note(size + pg, true);
    return (m + pg) as *mut void;
}

/// Release a stack from `sc_rt_stack_alloc` (`usable` and `size` as returned). A release the OS refuses
/// is fatal: the runtime cannot account for a mapping it no longer owns.
@platform(windows)
pub unsafe fn sc_rt_stack_free(usable: *mut void, size: usize) {
    let pg = sc_rt_page_size();
    if fail_hit(FAIL_STACK_RELEASE) || unsafe VirtualFree((usable as usize - pg) as *mut void, 0, MEM_RELEASE) == 0 {
        die("cannot release a task stack");
    }
    stack_note(size + pg, false);
}

/// Give the pages of an IDLE cached stack back to the OS, keeping the reservation and its guard. 0 on
/// success. Never for a live stack.
@platform(windows)
pub unsafe fn sc_rt_stack_reclaim(usable: *mut void, size: usize) i32 {
    // MEM_RESET marks the pages discardable; a later touch may read stale or zero data, which a stack
    // about to be re-armed never relies on.
    if unsafe VirtualAlloc(usable, size, MEM_RESET, PAGE_READWRITE) != null {
        return 0;
    }
    return -1;
}

/// The pages of a reclaimed stack are about to be used again: a touch after MEM_RESET recommits a page.
@platform(windows)
pub unsafe fn sc_rt_stack_reuse(_usable: *mut void, _size: usize) {}

// The thread's OWN stack, recorded when the thread arms itself. A fault on it is the OS's business:
// ntdll grows thread stacks itself.
@platform(windows)
@thread_local
static mut THREAD_STACK_BASE: usize = 0;
// Cached at install: the handler queries nothing it can avoid. Every thread stores the same value.
@platform(windows)
static mut PAGE_SIZE: usize = 4096;
@platform(windows)
static mut VEH_ONCE: i32 = 0;

// Grow the running coroutine stack into its reservation, or report that there is nothing left to grow
// into. Touching the PAGE_GUARD page raises STATUS_GUARD_PAGE_VIOLATION once and clears the guard bit, so
// the faulting page is already usable here: commit further down and re-arm a guard below the new floor.
@platform(windows)
@arch(x86_64)
fn stack_veh(ep: *mut EXCEPTION_POINTERS) i32 {
    let rec = unsafe (*ep).record;
    let code = unsafe (*rec).code;
    if code != STATUS_GUARD_PAGE_VIOLATION && code != EXCEPTION_ACCESS_VIOLATION && code != EXCEPTION_STACK_OVERFLOW {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    let own = unsafe THREAD_STACK_BASE;
    if own == 0 || teb_read(TEB_STACK_BASE) == own {
        return EXCEPTION_CONTINUE_SEARCH; // the thread's own stack: leave it to the system
    }
    // The switch puts the coroutine's StackBase/StackLimit/DeallocationStack in the TEB, so the kernel
    // grows a coroutine stack itself as a thread stack, but never past DeallocationStack: that it reports
    // as STATUS_STACK_OVERFLOW with NO address attached, so this test comes before every test that reads
    // one. On a coroutine stack the code means one thing: the task and the process cannot go on.
    if code == EXCEPTION_STACK_OVERFLOW {
        unsafe rt_stack_overflow();
    }
    if unsafe (*rec).nparams < 2 {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    let pg = unsafe atomic::load_usize(&mut PAGE_SIZE, RELAXED);
    let addr = unsafe (*rec).info[1];
    let limit = teb_read(TEB_STACK_LIMIT);
    let dealloc = teb_read(TEB_DEALLOC);
    if addr >= limit || addr < dealloc {
        return EXCEPTION_CONTINUE_SEARCH; // not this stack's growth region
    }
    // One page above the reservation stays uncommitted, and the guarantee above it is the report's:
    // growth stops there.
    let floor = dealloc + pg + STK_GUARANTEE;
    let mut want = addr & ~(pg - 1);
    if want > pg {
        want -= pg; // a page of headroom, so the next frame does not fault at once
    }
    if want < floor {
        // Room for the report, as the kernel gives it on its own path; it reports whether or not this
        // commits.
        unsafe VirtualAlloc((dealloc + pg) as *mut void, limit - (dealloc + pg), MEM_COMMIT, PAGE_READWRITE);
        unsafe rt_stack_overflow();
    }
    if unsafe VirtualAlloc(want as *mut void, limit - want, MEM_COMMIT, PAGE_READWRITE) == null {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    if want - pg >= floor {
        unsafe VirtualAlloc((want - pg) as *mut void, pg, MEM_COMMIT, PAGE_READWRITE | PAGE_GUARD);
    }
    teb_write(TEB_STACK_LIMIT, want); // the switch saves this, so the growth travels with the task
    return EXCEPTION_CONTINUE_EXECUTION;
}

/// Arm this thread to report a stack overflow instead of dying on a bare fault: every thread the runtime
/// starts calls it first. It keeps a stack guarantee for the report on the thread's own stack, and
/// installs the vectored exception handler that grows and reports coroutine stacks.
@platform(windows)
@arch(aarch64)
pub unsafe fn sc_rt_stack_guard_install() {
    // A fiber's stack grows as the OS sees fit: only the report on the thread's own stack.
    unsafe rt_stack_arm(0, 0);
}

/// Arm this thread to report a stack overflow instead of dying on a bare fault: every thread the runtime
/// starts calls it first. It keeps a stack guarantee for the report on the thread's own stack, and
/// installs the vectored exception handler that grows and reports coroutine stacks.
@platform(windows)
@arch(x86_64)
pub unsafe fn sc_rt_stack_guard_install() {
    unsafe atomic::store_usize(&mut PAGE_SIZE, sc_rt_page_size(), RELAXED);
    unsafe THREAD_STACK_BASE = teb_read(TEB_STACK_BASE);
    unsafe rt_stack_arm(0, 0);
    if unsafe atomic::cas_i32(&mut VEH_ONCE, 0, 1, false, ACQ_REL, RELAXED) {
        let v = VehBits { f: stack_veh };
        unsafe AddVectoredExceptionHandler(1, v.h);
    }
}

// ---- Windows threads and locks --------------------------------------------------------------------
// `_beginthreadex` rather than CreateThread: it sets up and tears down the C runtime's per-thread state.
// The pthread-shaped entry is adapted here; the pair is heap allocated because the OS passes one argument.
@platform(windows)
struct ThreadStart {
    pub entry: fn(*mut void) *mut void,
    pub arg: *mut void,
}

@platform(windows)
fn thread_tramp(p: *mut void) u32 {
    let t = unsafe *(p as *mut ThreadStart);
    unsafe stdlib::free(p);
    t.entry(t.arg);
    return 0;
}

/// Start an OS thread running `entry(arg)`: 0 on success with `*out` the handle `sc_rt_thread_join`
/// consumes (a handle never joined or detached leaks the thread's bookkeeping), else nonzero.
@platform(windows)
pub unsafe fn sc_rt_thread_create(out: *mut *mut void, entry: fn(*mut void) *mut void, arg: *mut void) i32 {
    let t = rt_alloc(sizeof(ThreadStart), false) as *mut ThreadStart;
    if t == null {
        return -1;
    }
    unsafe *t = ThreadStart { entry: entry, arg: arg };
    let mut h: usize = 0;
    if !fail_hit(FAIL_THREAD_CREATE) {
        h = unsafe _beginthreadex(null, 0, thread_tramp, t, 0, null);
    }
    if h == 0 {
        unsafe stdlib::free(t);
        return -1;
    }
    unsafe *out = h as *mut void;
    return 0;
}

/// Wait for a thread from `sc_rt_thread_create`; 0 on success, which releases the handle.
@platform(windows)
pub unsafe fn sc_rt_thread_join(handle: *mut void) i32 {
    if handle == null || fail_hit(FAIL_THREAD_JOIN) {
        return -1;
    }
    if unsafe WaitForSingleObject(handle, INFINITE) != WAIT_OBJECT_0 {
        return -1;
    }
    unsafe CloseHandle(handle);
    return 0;
}

/// Give up the right to join: the thread runs on and the OS releases it at exit; the handle is consumed.
/// 0 on success; nonzero means the handle named no joinable thread, a programmer error.
@platform(windows)
pub unsafe fn sc_rt_thread_detach(handle: *mut void) i32 {
    if handle == null || fail_hit(FAIL_THREAD_DETACH) {
        return -1;
    }
    if unsafe CloseHandle(handle) != 0 {
        return 0;
    }
    return -1;
}

/// A NON-recursive mutex (an SRWLOCK), released by the thread that took it; null when allocation fails.
@platform(windows)
pub unsafe fn sc_rt_mutex_new() *mut void {
    let m = rt_alloc(sizeof(SRWLOCK), false);
    if m != null {
        unsafe InitializeSRWLock(m as *mut SRWLOCK);
    }
    return m;
}

/// Destroy a mutex from `sc_rt_mutex_new`: an SRWLOCK has no destroy call.
@platform(windows)
pub unsafe fn sc_rt_mutex_free(m: *mut void) {
    unsafe stdlib::free(m);
}

/// Block until the mutex is held.
@platform(windows)
pub unsafe fn sc_rt_mutex_lock(m: *mut void) {
    unsafe AcquireSRWLockExclusive(m as *mut SRWLOCK);
}

/// Release a mutex the caller holds.
@platform(windows)
pub unsafe fn sc_rt_mutex_unlock(m: *mut void) {
    unsafe ReleaseSRWLockExclusive(m as *mut SRWLOCK);
}

/// A condition variable paired with a held `sc_rt_mutex_*`; null when allocation fails.
@platform(windows)
pub unsafe fn sc_rt_cond_new() *mut void {
    let c = rt_alloc(sizeof(CONDITION_VARIABLE), false);
    if c != null {
        unsafe InitializeConditionVariable(c as *mut CONDITION_VARIABLE);
    }
    return c;
}

/// Destroy a condition variable from `sc_rt_cond_new`: it has no destroy call.
@platform(windows)
pub unsafe fn sc_rt_cond_free(c: *mut void) {
    unsafe stdlib::free(c);
}

/// Release `m`, sleep until signaled, reacquire `m`; spurious wakeups are possible.
@platform(windows)
pub unsafe fn sc_rt_cond_wait(c: *mut void, m: *mut void) {
    unsafe SleepConditionVariableSRW(c as *mut CONDITION_VARIABLE, m as *mut SRWLOCK, INFINITE, 0);
}

/// Like `sc_rt_cond_wait`, but also returns once `rel_ns` nanoseconds have passed (negative waits forever);
/// nonzero exactly when the deadline woke it.
@platform(windows)
pub unsafe fn sc_rt_cond_timedwait_ns(c: *mut void, m: *mut void, rel_ns: i64) i32 {
    let mut ms = INFINITE;
    if rel_ns >= 0 {
        // A sub-millisecond deadline must still be a deadline, not an indefinite wait.
        ms = (rel_ns / 1000000) as u32;
        if ms == 0 {
            ms = 1;
        }
    }
    if unsafe SleepConditionVariableSRW(c as *mut CONDITION_VARIABLE, m as *mut SRWLOCK, ms, 0) != 0 {
        return 0;
    }
    if unsafe GetLastError() == ERROR_TIMEOUT {
        return 1;
    }
    return -1;
}

/// Wake one waiter.
@platform(windows)
pub unsafe fn sc_rt_cond_signal(c: *mut void) {
    unsafe WakeConditionVariable(c as *mut CONDITION_VARIABLE);
}

/// Test-timeout diagnostics: this platform has no signal to ask with, so nothing is chained.
@platform(windows | wasm)
pub unsafe fn sc_rt_diag_chain(_dump: fn()) {}

/// Write to the test's capture file from a `sc_rt_diag_chain` dump: no dump runs on this platform.
@platform(windows | wasm)
pub unsafe fn sc_rt_diag_write(_p: *const u8, _n: usize) {}

// ---- wasm ---------------------------------------------------------------------------------------
// wasm32 has ONE thread of execution and no signals, no mmap and no addressable call stack. The substrate
// is still provided in full, so the single-threaded half of `std/parallel` (Arc, atomics, an uncontended
// Mutex, a channel drained by the same thread) compiles and runs. What needs a second thread or a second
// stack fails at the call. A wait that would block is a deadlock here: nothing else runs to publish the
// word it waits on.
@platform(wasm)
extern "C" "wasi/api.h" {
    @import("__wasi_clock_time_get")
    fn wasi_clock_time_get(clock: u32, precision: u64, out: *mut u64) u16;
    @import("__WASI_CLOCKID_MONOTONIC")
    const WASI_CLOCKID_MONOTONIC: u32 = 1;
}

/// Monotonic clock in nanoseconds since an unspecified epoch.
@platform(wasm)
pub fn sc_rt_now_ns() u64 {
    let mut t: u64 = 0;
    unsafe wasi_clock_time_get(WASI_CLOCKID_MONOTONIC, 1, &mut t);
    return t;
}

/// Online core count: wasm has one.
@platform(wasm)
pub fn sc_rt_ncpu() usize {
    return 1;
}

/// The page size, bytes: the wasm page.
@platform(wasm)
pub fn sc_rt_page_size() usize {
    return 65536;
}

/// Sleep the calling thread for `ns` nanoseconds; zero or negative returns at once.
@platform(wasm)
pub fn sc_rt_sleep_ns(ns: i64) {
    if ns <= 0 {
        return;
    }
    let ts = timespec { tv_sec: ns / 1000000000, tv_nsec: (ns % 1000000000) as isize };
    unsafe nanosleep(&ts, null);
}

/// Yield this thread: nothing else runs on wasm.
@platform(wasm)
pub fn sc_rt_thread_yield() {}

/// Park on `word`: returns at once (after the timeout, when one is given), as `*word` cannot change
/// while this call runs. Callers re-check their condition in a loop, as after a spurious wakeup.
@platform(wasm)
pub unsafe fn sc_rt_park(_word: *mut i32, _expected: i32, timeout_ns: i64) {
    if timeout_ns > 0 {
        sc_rt_sleep_ns(timeout_ns);
    }
}

/// Wake one thread parked on `word`: none can be.
@platform(wasm)
pub unsafe fn sc_rt_unpark_one(_word: *mut i32) {}

/// Wake every thread parked on `word`: none can be.
@platform(wasm)
pub unsafe fn sc_rt_unpark_all(_word: *mut i32) {}

/// A task stack without a guard page (wasm has no mprotect): `size` a nonzero multiple of the wasm page,
/// else null. Free with the same `size`.
@platform(wasm)
pub unsafe fn sc_rt_stack_alloc(size: usize) *mut void {
    if size == 0 || size % 65536 != 0 {
        return null;
    }
    if fail_hit(FAIL_STACK_MAP) || fail_hit(FAIL_STACK_GUARD) {
        return null;
    }
    let m = unsafe stdlib::malloc(size);
    if m != null {
        stack_note(size, true);
    }
    return m;
}

/// Release a stack from `sc_rt_stack_alloc`.
@platform(wasm)
pub unsafe fn sc_rt_stack_free(usable: *mut void, size: usize) {
    if fail_hit(FAIL_STACK_RELEASE) {
        die("cannot release a task stack");
    }
    stack_note(size, false);
    unsafe stdlib::free(usable);
}

/// Reclaim an idle stack's pages: wasm cannot, so -1.
@platform(wasm)
pub unsafe fn sc_rt_stack_reclaim(_usable: *mut void, _size: usize) i32 {
    return -1;
}

/// The pages of a reclaimed stack are about to be used again: nothing to tell.
@platform(wasm)
pub unsafe fn sc_rt_stack_reuse(_usable: *mut void, _size: usize) {}

/// Arm the stack-overflow report: the engine reports an exhausted call stack itself.
@platform(wasm)
pub unsafe fn sc_rt_stack_guard_install() {}

/// Record the task stack size for the overflow report: there is none on wasm.
@platform(wasm)
pub unsafe fn sc_rt_stack_note_size(_bytes: usize) {}

/// Start an OS thread: wasm has none, so this reports and aborts. A failure code would be worse:
/// `spawn` hands the result slot to a `JoinHandle` without running the body, so a quiet failure reads
/// back as the closure's return value.
@platform(wasm)
pub unsafe fn sc_rt_thread_create(_out: *mut *mut void, _entry: fn(*mut void) *mut void, _arg: *mut void) i32 {
    die("wasm has one thread; 'thread::spawn' has nothing to run the closure on");
    return -1;
}

/// Join a thread: wasm has none, so -1.
@platform(wasm)
pub unsafe fn sc_rt_thread_join(_handle: *mut void) i32 {
    return -1;
}

/// Detach a thread: wasm has none, so -1.
@platform(wasm)
pub unsafe fn sc_rt_thread_detach(_handle: *mut void) i32 {
    return -1;
}

/// A mutex on wasm's single thread: never contended. It keeps a held flag, so locking twice traps
/// instead of quietly succeeding. Null when allocation fails.
@platform(wasm)
pub unsafe fn sc_rt_mutex_new() *mut void {
    return rt_alloc(4, true);
}

/// Destroy a mutex from `sc_rt_mutex_new`.
@platform(wasm)
pub unsafe fn sc_rt_mutex_free(m: *mut void) {
    unsafe stdlib::free(m);
}

/// Take the mutex; aborts when it is already held, which on one thread is a deadlock.
@platform(wasm)
pub unsafe fn sc_rt_mutex_lock(m: *mut void) {
    let held = m as *mut i32;
    if unsafe *held != 0 {
        die("deadlock: mutex locked twice on wasm's single thread");
    }
    unsafe *held = 1;
}

/// Release the mutex.
@platform(wasm)
pub unsafe fn sc_rt_mutex_unlock(m: *mut void) {
    unsafe *(m as *mut i32) = 0;
}

/// A condition variable on wasm's single thread; null when allocation fails.
@platform(wasm)
pub unsafe fn sc_rt_cond_new() *mut void {
    return rt_alloc(1, true);
}

/// Destroy a condition variable from `sc_rt_cond_new`.
@platform(wasm)
pub unsafe fn sc_rt_cond_free(c: *mut void) {
    unsafe stdlib::free(c);
}

/// Wait for a signal: none can come on one thread, so this reports the deadlock and aborts.
@platform(wasm)
pub unsafe fn sc_rt_cond_wait(_c: *mut void, _m: *mut void) {
    die("deadlock: condition wait on wasm's single thread");
}

/// Wait `rel_ns` nanoseconds with `m` released; returns 1: only the deadline can end the wait.
@platform(wasm)
pub unsafe fn sc_rt_cond_timedwait_ns(_c: *mut void, m: *mut void, rel_ns: i64) i32 {
    unsafe sc_rt_mutex_unlock(m);
    if rel_ns > 0 {
        sc_rt_sleep_ns(rel_ns);
    }
    unsafe sc_rt_mutex_lock(m);
    return 1;
}

/// Wake one waiter: none can wait.
@platform(wasm)
pub unsafe fn sc_rt_cond_signal(_c: *mut void) {}

// Stackful coroutines need a second stack to switch to, and wasm's call stack is not addressable.

/// An empty context block (nothing to switch to on wasm); null when allocation fails.
@platform(wasm)
pub unsafe fn sc_rt_ctx_alloc() *mut void {
    return rt_alloc(1, true);
}

/// Contexts live on the heap here: 0.
@platform(wasm)
pub fn sc_rt_ctx_inline_size() usize {
    return 0;
}

/// Release what an inline context holds: nothing on wasm.
@platform(wasm)
pub unsafe fn sc_rt_ctx_drop(_ctx: *mut void) {}

/// Arm a context: nothing to arm on wasm.
@platform(wasm)
pub unsafe fn sc_rt_ctx_init(_ctx: *mut void, _stack: *mut void, _size: usize, _entry: fn(*mut void), _arg: *mut void) {}

/// Switch contexts: wasm cannot, so this reports and aborts.
@platform(wasm)
pub unsafe fn sc_rt_ctx_switch(_from: *mut void, _to: *mut void) {
    die("'launch' needs a stackful context switch, which wasm does not provide");
}

/// A context's body has started: nothing to consume on wasm.
@platform(wasm)
pub unsafe fn sc_rt_ctx_entered(_ctx: *mut void) {}

/// Release a context block from `sc_rt_ctx_alloc`.
@platform(wasm)
pub unsafe fn sc_rt_ctx_free(ctx: *mut void) {
    unsafe stdlib::free(ctx);
}

// ---- stackful context switch ------------------------------------------------------------------------
// `sc_ctx_swap(save_sp, to_sp)` pushes the callee-saved set onto the running stack, stores the resulting
// sp through its first argument, and pops the same layout off the second: a suspended context is that one
// stack pointer, and `sc_rt_ctx_init` starts a coroutine by forging the frame by hand. Everything not
// saved is caller-saved and already spilled by the call that got here. The floating-point control state
// (MXCSR and the x87 control word, FPCR) travels with the coroutine: a task that sets a rounding mode
// keeps it across a park. `sc_ctx_entry` is where a forged frame's final `ret` lands: it moves the saved
// argument into the first argument register and calls the coroutine body, which switches away instead
// of returning; a return traps. Not shadow-stack safe: the first resume returns to a forged address, so a
// build with user-space CET needs -fcf-protection=none.

// System V x86-64: 48 bytes of registers, 8 for MXCSR and the x87 control word, then the return address
// `ret` consumes. sp+64 (where the trampoline starts) is 16-aligned, as a `call` needs.
@platform(macos | ios)
@arch(x86_64)
asm(M"(.text
.globl _sc_ctx_swap
.private_extern _sc_ctx_swap
.p2align 4
_sc_ctx_swap:
  .cfi_startproc
  pushq %rbp
  .cfi_adjust_cfa_offset 8
  .cfi_offset %rbp, -16
  pushq %rbx
  .cfi_adjust_cfa_offset 8
  .cfi_offset %rbx, -24
  pushq %r12
  .cfi_adjust_cfa_offset 8
  .cfi_offset %r12, -32
  pushq %r13
  .cfi_adjust_cfa_offset 8
  .cfi_offset %r13, -40
  pushq %r14
  .cfi_adjust_cfa_offset 8
  .cfi_offset %r14, -48
  pushq %r15
  .cfi_adjust_cfa_offset 8
  .cfi_offset %r15, -56
  subq  $8, %rsp
  .cfi_adjust_cfa_offset 8
  stmxcsr (%rsp)
  fnstcw  4(%rsp)
  movq  %rsp, (%rdi)
  movq  %rsi, %rsp
  ldmxcsr (%rsp)
  fldcw   4(%rsp)
  addq  $8, %rsp
  .cfi_adjust_cfa_offset -8
  popq  %r15
  .cfi_adjust_cfa_offset -8
  .cfi_restore %r15
  popq  %r14
  .cfi_adjust_cfa_offset -8
  .cfi_restore %r14
  popq  %r13
  .cfi_adjust_cfa_offset -8
  .cfi_restore %r13
  popq  %r12
  .cfi_adjust_cfa_offset -8
  .cfi_restore %r12
  popq  %rbx
  .cfi_adjust_cfa_offset -8
  .cfi_restore %rbx
  popq  %rbp
  .cfi_adjust_cfa_offset -8
  .cfi_restore %rbp
  ret
  .cfi_endproc
.globl _sc_ctx_entry
.private_extern _sc_ctx_entry
.p2align 4
_sc_ctx_entry:
  .cfi_startproc
  .cfi_undefined %rip
  movq  %r13, %rdi
  callq *%r12
  ud2
  .cfi_endproc
)");

@platform(linux | android)
@arch(x86_64)
asm(M"(.text
.globl sc_ctx_swap
.hidden sc_ctx_swap
.p2align 4
sc_ctx_swap:
  .cfi_startproc
  pushq %rbp
  .cfi_adjust_cfa_offset 8
  .cfi_offset %rbp, -16
  pushq %rbx
  .cfi_adjust_cfa_offset 8
  .cfi_offset %rbx, -24
  pushq %r12
  .cfi_adjust_cfa_offset 8
  .cfi_offset %r12, -32
  pushq %r13
  .cfi_adjust_cfa_offset 8
  .cfi_offset %r13, -40
  pushq %r14
  .cfi_adjust_cfa_offset 8
  .cfi_offset %r14, -48
  pushq %r15
  .cfi_adjust_cfa_offset 8
  .cfi_offset %r15, -56
  subq  $8, %rsp
  .cfi_adjust_cfa_offset 8
  stmxcsr (%rsp)
  fnstcw  4(%rsp)
  movq  %rsp, (%rdi)
  movq  %rsi, %rsp
  ldmxcsr (%rsp)
  fldcw   4(%rsp)
  addq  $8, %rsp
  .cfi_adjust_cfa_offset -8
  popq  %r15
  .cfi_adjust_cfa_offset -8
  .cfi_restore %r15
  popq  %r14
  .cfi_adjust_cfa_offset -8
  .cfi_restore %r14
  popq  %r13
  .cfi_adjust_cfa_offset -8
  .cfi_restore %r13
  popq  %r12
  .cfi_adjust_cfa_offset -8
  .cfi_restore %r12
  popq  %rbx
  .cfi_adjust_cfa_offset -8
  .cfi_restore %rbx
  popq  %rbp
  .cfi_adjust_cfa_offset -8
  .cfi_restore %rbp
  ret
  .cfi_endproc
.globl sc_ctx_entry
.hidden sc_ctx_entry
.p2align 4
sc_ctx_entry:
  .cfi_startproc
  .cfi_undefined %rip
  movq  %r13, %rdi
  callq *%r12
  ud2
  .cfi_endproc
)");

// AArch64: x19-x28, fp, lr and d8-d15 (the callee-saved set), then FPCR; 176 bytes keep sp 16-aligned.
// sp cannot be a store operand, so it goes through a caller-saved scratch register.
@platform(macos | ios)
@arch(aarch64)
asm(M"(.text
.globl _sc_ctx_swap
.private_extern _sc_ctx_swap
.p2align 4
_sc_ctx_swap:
  .cfi_startproc
  sub  sp, sp, #176
  .cfi_def_cfa_offset 176
  stp  x19, x20, [sp, #0]
  stp  x21, x22, [sp, #16]
  stp  x23, x24, [sp, #32]
  stp  x25, x26, [sp, #48]
  stp  x27, x28, [sp, #64]
  stp  x29, x30, [sp, #80]
  .cfi_offset x19, -176
  .cfi_offset x20, -168
  .cfi_offset x21, -160
  .cfi_offset x22, -152
  .cfi_offset x23, -144
  .cfi_offset x24, -136
  .cfi_offset x25, -128
  .cfi_offset x26, -120
  .cfi_offset x27, -112
  .cfi_offset x28, -104
  .cfi_offset x29,  -96
  .cfi_offset x30,  -88
  stp  d8,  d9,  [sp, #96]
  stp  d10, d11, [sp, #112]
  stp  d12, d13, [sp, #128]
  stp  d14, d15, [sp, #144]
  mrs  x2, fpcr
  str  x2, [sp, #160]
  mov  x2, sp
  str  x2, [x0]
  mov  sp, x1
  ldr  x2, [sp, #160]
  msr  fpcr, x2
  ldp  x19, x20, [sp, #0]
  ldp  x21, x22, [sp, #16]
  ldp  x23, x24, [sp, #32]
  ldp  x25, x26, [sp, #48]
  ldp  x27, x28, [sp, #64]
  ldp  x29, x30, [sp, #80]
  ldp  d8,  d9,  [sp, #96]
  ldp  d10, d11, [sp, #112]
  ldp  d12, d13, [sp, #128]
  ldp  d14, d15, [sp, #144]
  add  sp, sp, #176
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc
.globl _sc_ctx_entry
.private_extern _sc_ctx_entry
.p2align 4
_sc_ctx_entry:
  .cfi_startproc
  .cfi_undefined x30
  mov  x0, x20
  blr  x19
  brk  #0
  .cfi_endproc
)");

@platform(linux | android)
@arch(aarch64)
asm(M"(.text
.globl sc_ctx_swap
.hidden sc_ctx_swap
.p2align 4
sc_ctx_swap:
  .cfi_startproc
  sub  sp, sp, #176
  .cfi_def_cfa_offset 176
  stp  x19, x20, [sp, #0]
  stp  x21, x22, [sp, #16]
  stp  x23, x24, [sp, #32]
  stp  x25, x26, [sp, #48]
  stp  x27, x28, [sp, #64]
  stp  x29, x30, [sp, #80]
  .cfi_offset x19, -176
  .cfi_offset x20, -168
  .cfi_offset x21, -160
  .cfi_offset x22, -152
  .cfi_offset x23, -144
  .cfi_offset x24, -136
  .cfi_offset x25, -128
  .cfi_offset x26, -120
  .cfi_offset x27, -112
  .cfi_offset x28, -104
  .cfi_offset x29,  -96
  .cfi_offset x30,  -88
  stp  d8,  d9,  [sp, #96]
  stp  d10, d11, [sp, #112]
  stp  d12, d13, [sp, #128]
  stp  d14, d15, [sp, #144]
  mrs  x2, fpcr
  str  x2, [sp, #160]
  mov  x2, sp
  str  x2, [x0]
  mov  sp, x1
  ldr  x2, [sp, #160]
  msr  fpcr, x2
  ldp  x19, x20, [sp, #0]
  ldp  x21, x22, [sp, #16]
  ldp  x23, x24, [sp, #32]
  ldp  x25, x26, [sp, #48]
  ldp  x27, x28, [sp, #64]
  ldp  x29, x30, [sp, #80]
  ldp  d8,  d9,  [sp, #96]
  ldp  d10, d11, [sp, #112]
  ldp  d12, d13, [sp, #128]
  ldp  d14, d15, [sp, #144]
  add  sp, sp, #176
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc
.globl sc_ctx_entry
.hidden sc_ctx_entry
.p2align 4
sc_ctx_entry:
  .cfi_startproc
  .cfi_undefined x30
  mov  x0, x20
  blr  x19
  brk  #0
  .cfi_endproc
)");

// Windows x64 saves more than System V: eight GPRs, xmm6-xmm15 (callee-saved here) and four TEB fields
// (StackBase, StackLimit, DeallocationStack, GuaranteedStackBytes). __chkstk probes and the SEH unwinder
// read the running thread's stack bounds from the TEB, so a coroutine that left them pointing at the
// worker's stack would fault in the first function with a large frame, and the kernel reads the stack
// guarantee from it when the stack overflows. The frame: 160 bytes of xmm, 64 of GPRs, 24 of TEB fields,
// 16 of MXCSR, the x87 control word and the guarantee; sp stays 16-aligned (movaps needs it) and the
// return address `ret` consumes sits above it at +264. The entry provides the 32-byte shadow space the
// Win64 caller owes its callee.
@platform(windows)
@arch(x86_64)
asm(M"(.text
.seh_proc sc_ctx_swap
.globl sc_ctx_swap
.p2align 4
sc_ctx_swap:
  subq $264, %rsp
  .seh_stackalloc 264
  movaps %xmm6,    0(%rsp)
  movaps %xmm7,   16(%rsp)
  movaps %xmm8,   32(%rsp)
  movaps %xmm9,   48(%rsp)
  movaps %xmm10,  64(%rsp)
  movaps %xmm11,  80(%rsp)
  movaps %xmm12,  96(%rsp)
  movaps %xmm13, 112(%rsp)
  movaps %xmm14, 128(%rsp)
  movaps %xmm15, 144(%rsp)
  .seh_savexmm %xmm6, 0
  .seh_savexmm %xmm7, 16
  .seh_savexmm %xmm8, 32
  .seh_savexmm %xmm9, 48
  .seh_savexmm %xmm10, 64
  .seh_savexmm %xmm11, 80
  .seh_savexmm %xmm12, 96
  .seh_savexmm %xmm13, 112
  .seh_savexmm %xmm14, 128
  .seh_savexmm %xmm15, 144
  movq %rbx, 160(%rsp)
  .seh_savereg %rbx, 160
  movq %rbp, 168(%rsp)
  .seh_savereg %rbp, 168
  movq %rdi, 176(%rsp)
  .seh_savereg %rdi, 176
  movq %rsi, 184(%rsp)
  .seh_savereg %rsi, 184
  movq %r12, 192(%rsp)
  .seh_savereg %r12, 192
  movq %r13, 200(%rsp)
  .seh_savereg %r13, 200
  movq %r14, 208(%rsp)
  .seh_savereg %r14, 208
  movq %r15, 216(%rsp)
  .seh_savereg %r15, 216
  .seh_endprologue
  movq %gs:0x08, %rax
  movq %rax, 224(%rsp)
  movq %gs:0x10, %rax
  movq %rax, 232(%rsp)
  movq %gs:0x1478, %rax
  movq %rax, 240(%rsp)
  stmxcsr 248(%rsp)
  fnstcw  252(%rsp)
  movl %gs:0x1748, %eax
  movl %eax, 256(%rsp)
  movq %rsp, (%rcx)
  movq %rdx, %rsp
  ldmxcsr 248(%rsp)
  fldcw   252(%rsp)
  movl 256(%rsp), %eax
  movl %eax, %gs:0x1748
  movq 224(%rsp), %rax
  movq %rax, %gs:0x08
  movq 232(%rsp), %rax
  movq %rax, %gs:0x10
  movq 240(%rsp), %rax
  movq %rax, %gs:0x1478
  movaps    0(%rsp), %xmm6
  movaps   16(%rsp), %xmm7
  movaps   32(%rsp), %xmm8
  movaps   48(%rsp), %xmm9
  movaps   64(%rsp), %xmm10
  movaps   80(%rsp), %xmm11
  movaps   96(%rsp), %xmm12
  movaps  112(%rsp), %xmm13
  movaps  128(%rsp), %xmm14
  movaps  144(%rsp), %xmm15
  movq 160(%rsp), %rbx
  movq 168(%rsp), %rbp
  movq 176(%rsp), %rdi
  movq 184(%rsp), %rsi
  movq 192(%rsp), %r12
  movq 200(%rsp), %r13
  movq 208(%rsp), %r14
  movq 216(%rsp), %r15
  addq $264, %rsp
  ret
  .seh_endproc
.globl sc_ctx_entry
.p2align 4
sc_ctx_entry:
  movq %r13, %rcx
  subq $32, %rsp
  callq *%r12
  ud2
)");

@platform(!wasm)
extern "C" {
    fn sc_ctx_swap(save_sp: *mut *mut void, to_sp: *mut void);
    fn sc_ctx_entry();
}

// A context: the stack pointer of its saved frame (null until the first switch away fills it in), and
// under ThreadSanitizer the context's fiber (null on a worker's own context until its first switch away).
@platform(!wasm)
struct Ctx {
    pub sp: *mut void,
    pub fiber: *mut void,
}

// Windows on arm64 has no hand-written switch: an OS fiber runs each context, at one call into the OS
// per switch. A fiber owns its stack, so the context is a heap block (`sc_rt_ctx_inline_size` is 0).
@platform(windows)
@arch(aarch64)
struct FiberCtx {
    pub fiber: *mut void,
    pub is_root: bool,
    pub entry: fn(*mut void),
    pub arg: *mut void,
}

@platform(windows)
@arch(aarch64)
extern "C" "windows.h" {
    fn CreateFiber(size: usize, start: fn(*mut void), param: *mut void) *mut void;
    fn ConvertThreadToFiber(param: *mut void) *mut void;
    fn SwitchToFiber(fiber: *mut void);
    fn DeleteFiber(fiber: *mut void);
}

// The start of a fiber: the body of its context.
@platform(windows)
@arch(aarch64)
fn fiber_entry(p: *mut void) {
    let c = p as *mut FiberCtx;
    unsafe (*c).entry((*c).arg);
}

/// Arm `ctx` to run `entry(arg)` on a fiber of `size` bytes of stack; the fiber owns its stack, so
/// `stack` is unused.
@platform(windows)
@arch(aarch64)
pub unsafe fn sc_rt_ctx_init(ctx: *mut void, _stack: *mut void, size: usize, entry: fn(*mut void), arg: *mut void) {
    let c = ctx as *mut FiberCtx;
    unsafe (*c).entry = entry;
    unsafe (*c).arg = arg;
    unsafe (*c).fiber = unsafe CreateFiber(size, fiber_entry, ctx);
}

// A function's address, as a forged frame holds it. Windows on arm64 forges no frame (`FiberCtx`).
@platform(macos | ios | linux | android)
union CodeBits {
    pub entry: fn(*mut void),
    pub tramp: fn(),
    pub p: *mut void,
}
@platform(windows)
@arch(x86_64)
union CodeBits {
    pub entry: fn(*mut void),
    pub tramp: fn(),
    pub p: *mut void,
}

// A forged frame must carry a LEGAL floating-point control word: zero unmasks every SSE exception on
// x86-64, so the first inexact multiply of a fresh coroutine would trap. Seed it from the thread that arms
// the context, the state that thread would have handed over anyway.
@platform(!wasm)
@arch(x86_64)
fn save_fpctl(slot: *mut void) {
    unsafe {
        asm("stmxcsr (%0)\n\tfnstcw 4(%0)" :  : "r"(slot) : "memory");
    }
}
@platform(macos | ios | linux | android)
@arch(aarch64)
fn save_fpctl(slot: *mut void) {
    let mut fpcr: u64 = 0;
    unsafe {
        asm("mrs %0, fpcr" : "=r"(fpcr));
        *(slot as *mut u64) = fpcr;
    }
}

/// Make an empty context for the current thread's root: its state is captured on the first switch away.
/// Null when allocation fails.
@platform(!wasm)
pub unsafe fn sc_rt_ctx_alloc() *mut void {
    if PLATFORM == Platform::Windows && ARCH == Arch::AArch64 {
        return rt_alloc(sizeof(FiberCtx), true);
    }
    return rt_alloc(sizeof(Ctx), true);
}

/// Bytes an inline context needs: a context fits inside the task record (zeroed before its first init).
@platform(!wasm)
pub fn sc_rt_ctx_inline_size() usize {
    if PLATFORM == Platform::Windows && ARCH == Arch::AArch64 {
        return 0;
    }
    return sizeof(Ctx);
}

/// Release what an inline context holds besides its bytes (a sanitizer fiber); frees nothing.
@platform(!wasm)
pub unsafe fn sc_rt_ctx_drop(ctx: *mut void) {
    if PLATFORM == Platform::Windows && ARCH == Arch::AArch64 {
        // A thread converted to a fiber keeps it: only a created fiber is deleted.
        let w = ctx as *mut FiberCtx;
        if unsafe (*w).fiber != null && !unsafe (*w).is_root {
            unsafe DeleteFiber((*w).fiber);
        }
        unsafe (*w).fiber = null;
        return;
    }
    if THREAD_SANITIZER {
        // A worker's own context borrowed its fiber from the thread; only a created one is ours.
        let c = ctx as *mut Ctx;
        let fb = unsafe (*c).fiber;
        if fb != null && fb != unsafe tsan_get_current_fiber() {
            unsafe tsan_destroy_fiber(fb);
        }
        unsafe (*c).fiber = null;
    }
}

// The System V and AArch64 frames in 8-byte slots.
@platform(macos | ios | linux | android)
@arch(x86_64)
const CTX_FRAME: usize = 8;
@platform(macos | ios | linux | android)
@arch(aarch64)
const CTX_FRAME: usize = 22;

// Write the slots the first swap-in pops: the body and its argument ride in callee-saved registers
// because they survive that pop unchanged; the frame pointer slot stays zero, so a backtrace stops at the
// coroutine boundary.
@platform(macos | ios | linux | android)
@arch(x86_64)
fn forge(f: *mut *mut void, body: *mut void, arg: *mut void, tramp: *mut void) {
    save_fpctl(f as *mut void); // MXCSR + x87 control word
    unsafe f[3] = arg; // r13
    unsafe f[4] = body; // r12
    unsafe f[7] = tramp; // the return address of the trailing `ret`
}
@platform(macos | ios | linux | android)
@arch(aarch64)
fn forge(f: *mut *mut void, body: *mut void, arg: *mut void, tramp: *mut void) {
    save_fpctl(unsafe (f + 20)); // FPCR
    unsafe f[0] = body; // x19
    unsafe f[1] = arg; // x20
    unsafe f[11] = tramp; // x30, so the trailing `ret` lands on the trampoline
}

/// Arm `ctx` to run `entry(arg)` on `stack` (`size` bytes); the first `sc_rt_ctx_switch` into it starts
/// it. An `entry` that returns traps: a coroutine hands control back with a switch, never a return.
@platform(macos | ios | linux | android)
pub unsafe fn sc_rt_ctx_init(ctx: *mut void, stack: *mut void, size: usize, entry: fn(*mut void), arg: *mut void) {
    let c = ctx as *mut Ctx;
    if THREAD_SANITIZER {
        // Only a COROUTINE context is armed here, so its fiber belongs here. A worker's own context
        // takes the fiber it runs on, at its first switch away.
        unsafe (*c).fiber = unsafe tsan_create_fiber(0);
    }
    let top = stack as usize + size & ~15usize;
    let f = (top - CTX_FRAME * 8) as *mut *mut void;
    for i in 0..CTX_FRAME {
        unsafe f[i] = null;
    }
    let body = CodeBits { entry: entry };
    let tramp = CodeBits { tramp: unsafe sc_ctx_entry };
    forge(f, body.p, arg, tramp.p);
    // The ONLY reader of this frame is the assembly, which the C compiler cannot see: under LTO it would
    // otherwise delete these stores as dead, and the coroutine would resume into a frame of zeros.
    unsafe {
        asm("" :  : "r"(f) : "memory");
    }
    unsafe (*c).sp = f;
}

/// Arm `ctx` to run `entry(arg)` on `stack` (`size` bytes); the first `sc_rt_ctx_switch` into it starts
/// it. An `entry` that returns traps: a coroutine hands control back with a switch, never a return.
@platform(windows)
@arch(x86_64)
pub unsafe fn sc_rt_ctx_init(ctx: *mut void, stack: *mut void, size: usize, entry: fn(*mut void), arg: *mut void) {
    let pg = sc_rt_page_size();
    let base = stack as usize;
    let top = base + size & ~15usize;
    // 264 bytes of frame plus the return address above it, keeping the forged sp 16-aligned.
    let f = (top - 272) as *mut *mut void;
    for i in 0..34 {
        unsafe f[i] = null;
    }
    let body = CodeBits { entry: entry };
    let tramp = CodeBits { tramp: unsafe sc_ctx_entry };
    save_fpctl(unsafe (f + 31)); // MXCSR + x87 control word
    unsafe f[24] = body.p; // r12
    unsafe f[25] = arg; // r13
    unsafe f[28] = top as *mut void; // StackBase: the high end this coroutine runs on
    unsafe f[29] = stk_initial_limit(base, size, pg) as *mut void; // StackLimit: lowest COMMITTED byte
    unsafe f[30] = (base - pg) as *mut void; // DeallocationStack: the reservation, guard page included
    unsafe f[32] = STK_GUARANTEE as *mut void; // GuaranteedStackBytes, read as its low 4 bytes
    unsafe f[33] = tramp.p; // the return address of the trailing `ret`
    // The ONLY reader of this frame is the assembly, which the C compiler cannot see: under LTO it would
    // otherwise delete these stores as dead.
    unsafe {
        asm("" :  : "r"(f) : "memory");
    }
    unsafe (*(ctx as *mut Ctx)).sp = f;
}

/// Save the running context into `from` and resume `to`.
@platform(!wasm)
pub unsafe fn sc_rt_ctx_switch(from: *mut void, to: *mut void) {
    if PLATFORM == Platform::Windows && ARCH == Arch::AArch64 {
        let wf = from as *mut FiberCtx;
        if unsafe (*wf).fiber == null {
            // The first switch away from a thread makes the thread a fiber.
            unsafe (*wf).fiber = unsafe ConvertThreadToFiber(null);
            unsafe (*wf).is_root = true;
        }
        unsafe SwitchToFiber((*(to as *mut FiberCtx)).fiber);
        return;
    }
    let f = from as *mut Ctx;
    let t = to as *mut Ctx;
    if THREAD_SANITIZER {
        // Announce the move BEFORE the stack changes: from here on TSan attributes accesses to the target's
        // fiber, so a coroutine keeps one identity across every worker that runs it. Switching a fiber
        // creates no happens-before edge, but the switch is one: the leaver releases on the context being
        // ENTERED, and the side that wakes up inside its own swap acquires on itself. Without the pair every
        // field the task and its worker share reports as a race, the edge being assembly TSan cannot see.
        if unsafe (*f).fiber == null {
            unsafe (*f).fiber = unsafe tsan_get_current_fiber();
        }
        unsafe tsan_release(to);
        unsafe tsan_switch_to_fiber((*t).fiber, 0);
        unsafe sc_ctx_swap(&mut (*f).sp, (*t).sp);
        unsafe tsan_acquire(from);
    } else {
        unsafe sc_ctx_swap(&mut (*f).sp, (*t).sp);
    }
}

/// The context's body has just started through the entry trampoline, not through a returning switch:
/// consume what its switcher published. A no-op except under the race profile.
@platform(!wasm)
pub unsafe fn sc_rt_ctx_entered(ctx: *mut void) {
    if THREAD_SANITIZER {
        // The first run pops the forged frame into the trampoline, so the acquire at the end of
        // `sc_rt_ctx_switch` never runs for it.
        unsafe tsan_acquire(ctx);
    }
}

/// Release a context from `sc_rt_ctx_alloc`.
@platform(!wasm)
pub unsafe fn sc_rt_ctx_free(ctx: *mut void) {
    unsafe sc_rt_ctx_drop(ctx);
    unsafe stdlib::free(ctx);
}
