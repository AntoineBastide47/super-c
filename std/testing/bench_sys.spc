// Platform glue for the benchmark library: CPU cycles, CPU time, allocation accounting, resident memory,
// machine identity, fresh processes and an optimisation barrier. The surface is platform-neutral; the
// platform splits are `@platform` items. Nothing is reported as zero work when it is unavailable: every
// counter has an availability query beside it. Import with `import std::testing::bench_sys as sys;`.
// Every call requires `unsafe`.
//
// The C facts come from the real headers. A block names its header when the build's C flags
// (`-D_POSIX_C_SOURCE=200809L`) can include it, so the build checks the values and layouts against it. The
// functions those flags hide (Apple's `sysctlbyname`, `proc_pid_rusage` and zone functions, glibc's
// `syscall` and `__libc_*`) and the Win32 calls (<windows.h> would define its macros in every unit of the
// program) are in blocks without a header, which declare them from their Super-C types; the records they
// take are Super-C structs with the header's layout.

import stdlib;
import stdio;
import atomic;
@platform(macos | ios | linux | android)
import unistd;
@platform(linux | android)
import errno;
@platform(linux | android)
import fcntl;
@platform(linux | android)
import filesystem;
@platform(wasm)
import time;

// The memory-order codes of `atomic` (std/parallel/atomics.spc `MemoryOrder`).
const RELAXED: i32 = 0;
const ACQUIRE: i32 = 1;
const RELEASE: i32 = 2;

// ---- CPU cycles --------------------------------------------------------------------------------------

/// `sc_bs_cycles_scope` bit: every thread of the process is counted, not only the caller.
pub const CYC_ALL: i32 = 1;
/// `sc_bs_cycles_scope` bit: cycles spent in kernel mode are included.
pub const CYC_KERNEL: i32 = 2;
/// `sc_bs_cycles_scope` bit: threads that existed before the first call are counted. Linux opens one
/// perf event per thread alive at that moment, inherited by every thread created later, so the first
/// call belongs in `main` before any pool starts.
pub const CYC_EXISTING: i32 = 4;

/// Cumulative CPU cycles of the scope `sc_bs_cycles_scope` reports; 0 and meaningless when that is 0.
@platform(windows)
pub unsafe fn sc_bs_cycles() i64 {
    let mut c: u64 = 0;
    if unsafe QueryProcessCycleTime(GetCurrentProcess(), &mut c) == 0 {
        return 0;
    }
    return c as i64;
}

/// What the cycle counter covers, as `CYC_*` bits; 0 when there is no counter on this platform.
/// QueryProcessCycleTime counts every thread of the process, user and kernel mode alike.
@platform(windows)
pub unsafe fn sc_bs_cycles_scope() i32 {
    return CYC_ALL | CYC_KERNEL | CYC_EXISTING;
}

/// Cumulative CPU cycles of the scope `sc_bs_cycles_scope` reports; 0 and meaningless when that is 0.
@platform(wasm)
pub unsafe fn sc_bs_cycles() i64 {
    return 0;
}

/// What the cycle counter covers, as `CYC_*` bits; 0 when there is no counter on this platform.
@platform(wasm)
pub unsafe fn sc_bs_cycles_scope() i32 {
    return 0;
}

/// Cumulative CPU cycles of the scope `sc_bs_cycles_scope` reports; 0 and meaningless when that is 0.
@platform(macos | ios)
pub unsafe fn sc_bs_cycles() i64 {
    return mac_cycles().max(0);
}

// The scope `sc_bs_cycles_scope` decided, -1 before the first call (atomic).
@platform(macos | ios)
static mut MAC_SCOPE: i32 = -1;

/// What the cycle counter covers, as `CYC_*` bits; 0 when there is no counter on this platform.
///
/// A virtual machine (the hosted CI runners among them) answers the rusage call successfully with a
/// counter that does not move. Availability therefore means the counter advanced by at least one cycle per
/// step of a dependent multiply chain (the physical minimum; a real core spends three to four), decided
/// once per process; a counter that stays put or under-counts is reported as unavailable, never as zero
/// work.
@platform(macos | ios)
pub unsafe fn sc_bs_cycles_scope() i32 {
    let s0 = unsafe atomic::load_i32(&MAC_SCOPE, ACQUIRE);
    if s0 >= 0 {
        return s0;
    }
    let c0 = mac_cycles();
    let mut s: i32 = 0;
    if c0 >= 0 {
        let steps: i64 = 200000;
        let mut x: u64 = 1;
        for i in 0..steps {
            x = x.wrapping_mul(6364136223846793005u64).wrapping_add(i as u64);
            // Each step reaches memory, so the whole chain runs.
            unsafe sc_bs_sink(x);
        }
        if mac_cycles() - c0 >= steps {
            s = CYC_ALL | CYC_KERNEL | CYC_EXISTING;
        }
    }
    unsafe atomic::store_i32(&mut MAC_SCOPE, s, RELEASE);
    return s;
}

// The process's cycle count from `proc_pid_rusage`, -1 on failure: the source of `time -l`'s "cycles
// elapsed", unprivileged, per process, every thread, user and kernel mode.
@platform(macos | ios)
fn mac_cycles() i64 {
    let mut ri = unsafe zeroed::<RusageInfoV4>();
    if !rusage_info(&mut ri) {
        return -1;
    }
    return ri.ri_cycles as i64;
}

/// Cumulative CPU cycles of the scope `sc_bs_cycles_scope` reports; 0 and meaningless when that is 0.
@platform(linux | android)
pub unsafe fn sc_bs_cycles() i64 {
    if unsafe sc_bs_cycles_scope() == 0 {
        return 0;
    }
    let mut total: i64 = 0;
    for i in 0..unsafe PERF_NFD {
        let mut v: i64 = 0;
        if unsafe unistd::read(PERF_FDS[i as usize], (&mut v) as *mut i64, 8) != 8 {
            return 0;
        }
        total = total.wrapping_add(v);
    }
    return total;
}

/// What the cycle counter covers, as `CYC_*` bits; 0 when there is no counter on this platform.
///
/// PERF_COUNT_HW_CPU_CYCLES, one event per thread alive at the first call, each with `inherit` so every
/// thread those threads create later is counted through its creator's event. Kernel-mode cycles are
/// requested first and given up (`exclude_kernel`) when perf_event_paranoid forbids them. Unavailable
/// (containers, paranoid=3, no PMU, more than PERF_MAX_EVENTS threads at the first call): 0. The first call
/// must not race another call: it belongs in `main` before any thread starts.
@platform(linux | android)
pub unsafe fn sc_bs_cycles_scope() i32 {
    if unsafe PERF_SCOPE < 0 {
        unsafe PERF_SCOPE = perf_open();
    }
    return unsafe PERF_SCOPE;
}

// ---- Linux perf events ------------------------------------------------------------------------------------

// At most this many perf events, one per thread alive at the first call.
@platform(linux | android)
const PERF_MAX_EVENTS: i32 = 256;
@platform(linux | android)
static mut PERF_FDS: [i32; 256] = [0; 256];
@platform(linux | android)
static mut PERF_NFD: i32 = 0;
// The scope `perf_open` decided, -1 before it ran.
@platform(linux | android)
static mut PERF_SCOPE: i32 = -1;

// `struct perf_event_attr` up to PERF_ATTR_SIZE_VER0, the first version of the kernel's ABI, which every
// kernel accepts with `size` set to it. The header's struct cannot be declared: it has bit-fields, and
// its size grows with the kernel version of the headers. The layout and the bit positions are the
// header's; `PERF_ATTR_SIZE_VER0` checks the size.
@platform(linux | android)
struct PerfAttr {
    pub kind: u32,
    pub size: u32,
    pub config: u64,
    pub sample_period: u64,
    pub sample_type: u64,
    pub read_format: u64,
    // The bit-field word: `disabled` is bit 0, then `inherit`, `pinned`, `exclusive`, `exclude_user`,
    // `exclude_kernel`, `exclude_hv`, ... in declaration order.
    pub flags: u64,
    pub wakeup_events: u32,
    pub bp_type: u32,
    pub config1: u64,
}

@platform(linux | android)
const PERF_INHERIT: u64 = 1 << 1;
@platform(linux | android)
const PERF_EXCLUDE_KERNEL: u64 = 1 << 5;
@platform(linux | android)
const PERF_EXCLUDE_HV: u64 = 1 << 6;

@platform(linux | android)
extern "C" "linux/perf_event.h" {
    const PERF_TYPE_HARDWARE: u32 = 0;
    const PERF_COUNT_HW_CPU_CYCLES: u64 = 0;
    const PERF_ATTR_SIZE_VER0: u32 = 64;
}

@platform(linux | android)
extern "C" "sys/syscall.h" {
    @arch(x86_64)
    const SYS_perf_event_open: stdlib::c_long = 298;
    @arch(aarch64)
    const SYS_perf_event_open: stdlib::c_long = 241;
}

@platform(linux | android)
extern "C" "errno.h" {
    const EACCES: i32 = 13;
    const EPERM: i32 = 1;
}

// <unistd.h> declares `syscall` only beyond the build's POSIX level.
@platform(linux | android)
extern "C" {
    fn syscall(number: stdlib::c_long, ...) stdlib::c_long;
}

// The directory entry of <dirent.h>, every member (glibc and bionic agree).
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

// One cycle event for thread `tid`: its descriptor, or -1 with errno set.
@platform(linux | android)
fn perf_open_one(tid: i32, exclude_kernel: bool) i32 {
    static_assert(sizeof(PerfAttr) == PERF_ATTR_SIZE_VER0 as usize, "PerfAttr has the version-0 size");
    let mut flags = PERF_INHERIT | PERF_EXCLUDE_HV;
    if exclude_kernel {
        flags = flags | PERF_EXCLUDE_KERNEL;
    }
    let mut pe = PerfAttr {
        kind: PERF_TYPE_HARDWARE,
        size: PERF_ATTR_SIZE_VER0,
        config: PERF_COUNT_HW_CPU_CYCLES,
        flags: flags,
    };
    return (unsafe syscall(SYS_perf_event_open, (&mut pe) as *mut PerfAttr, tid, -1i32, -1i32, 0 as stdlib::c_ulong)) as i32;
}

@platform(linux | android)
fn perf_close_all() {
    for i in 0..unsafe PERF_NFD {
        unsafe unistd::close(PERF_FDS[i as usize]);
    }
    unsafe PERF_NFD = 0;
}

// The thread id a `/proc/self/task` entry names, -1 for "." and "..".
@platform(linux | android)
fn task_id(name: &[char; 256]) i64 {
    let mut v: i64 = 0;
    let mut i: usize = 0;
    while i < 256 && (unsafe name[i]) as u8 >= b'0' && (unsafe name[i]) as u8 <= b'9' {
        v = v * 10 + ((unsafe name[i]) as u8 - b'0') as i64;
        i += 1;
    }
    return if i == 0 {
        -1;
    } else {
        v;
    };
}

// Open one event per thread of the process: the scope, 0 when unavailable.
@platform(linux | android)
fn perf_open() i32 {
    let path = "/proc/self/task".ptr() as *const char;
    let mut kernel = true;
    let mut all_existing = true;
    let mut d = unsafe filesystem::opendir(path);
    if d == null {
        return 0;
    }
    loop {
        let e = (unsafe filesystem::readdir(d)) as *const dirent;
        if e == null {
            break;
        }
        let tid = task_id(unsafe &(*e).d_name);
        if tid < 0 {
            continue;
        }
        if unsafe PERF_NFD >= PERF_MAX_EVENTS {
            all_existing = false;
            break;
        }
        let fd = perf_open_one(tid as i32, !kernel);
        let err = errno::errno();
        if fd < 0 && kernel && (err == EACCES || err == EPERM) {
            // perf_event_paranoid >= 2: user-space cycles only, for every event.
            kernel = false;
            perf_close_all();
            unsafe filesystem::closedir(d);
            d = unsafe filesystem::opendir(path);
            if d == null {
                return 0;
            }
            continue;
        }
        if fd < 0 {
            perf_close_all();
            unsafe filesystem::closedir(d);
            return 0;
        }
        unsafe PERF_FDS[PERF_NFD as usize] = fd;
        unsafe PERF_NFD += 1;
    }
    unsafe filesystem::closedir(d);
    if unsafe PERF_NFD == 0 {
        return 0;
    }
    let mut s = CYC_ALL;
    if kernel {
        s = s | CYC_KERNEL;
    }
    if all_existing {
        s = s | CYC_EXISTING;
    }
    return s;
}

// ---- CPU time ------------------------------------------------------------------------------------------

/// User plus system CPU time of every thread of the process, in nanoseconds; -1 when unavailable.
@platform(windows)
pub unsafe fn sc_bs_cpu_ns() i64 {
    let mut c = FileTime { low: 0, high: 0 };
    let mut e = FileTime { low: 0, high: 0 };
    let mut k = FileTime { low: 0, high: 0 };
    let mut u = FileTime { low: 0, high: 0 };
    if unsafe GetProcessTimes(GetCurrentProcess(), &mut c, &mut e, &mut k, &mut u) == 0 {
        return -1;
    }
    return ((k.ticks() + u.ticks()) * 100) as i64; // FILETIME counts 100 ns intervals
}

/// User plus system CPU time of every thread of the process, in nanoseconds; -1 when unavailable.
@platform(wasm)
pub unsafe fn sc_bs_cpu_ns() i64 {
    return (time::clock() as f64 * (1e9 / time::CLOCKS_PER_SEC as f64)) as i64;
}

/// User plus system CPU time of every thread of the process, in nanoseconds; -1 when unavailable.
@platform(macos | ios | linux | android)
pub unsafe fn sc_bs_cpu_ns() i64 {
    let mut ru = unsafe zeroed::<rusage>();
    if unsafe getrusage(RUSAGE_SELF, &mut ru) != 0 {
        return -1;
    }
    let sec = ru.ru_utime.tv_sec as i64 + ru.ru_stime.tv_sec as i64;
    let usec = ru.ru_utime.tv_usec as i64 + ru.ru_stime.tv_usec as i64;
    return sec * 1000000000 + usec * 1000;
}

// <sys/time.h> and <sys/resource.h>, every member. At the build's POSIX level Apple's `struct rusage`
// names its fourteen counters `ru_opaque`, in the full API's order (`ru_maxrss` first); glibc puts each
// counter in an anonymous union, whose member the field names.
@platform(macos | ios)
extern "C" "sys/time.h" {
    struct timeval {
        pub tv_sec: stdlib::c_long,
        pub tv_usec: i32,
    }
}
@platform(macos | ios)
extern "C" "sys/resource.h" {
    struct rusage {
        pub ru_utime: timeval,
        pub ru_stime: timeval,
        pub ru_opaque: [stdlib::c_long; 14],
    }
    fn getrusage(who: i32, usage: *mut rusage) i32;
    const RUSAGE_SELF: i32 = 0;
}
@platform(linux | android)
extern "C" "sys/time.h" {
    struct timeval {
        pub tv_sec: stdlib::c_long,
        pub tv_usec: stdlib::c_long,
    }
}
@platform(linux | android)
extern "C" "sys/resource.h" {
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
    fn getrusage(who: i32, usage: *mut rusage) i32;
    const RUSAGE_SELF: i32 = 0;
}

// ---- Apple process accounting -----------------------------------------------------------------------------

// `struct rusage_info_v4` of <sys/resource.h>, every member: the build's POSIX level hides it.
@platform(macos | ios)
struct RusageInfoV4 {
    pub ri_uuid: [u8; 16],
    pub ri_user_time: u64,
    pub ri_system_time: u64,
    pub ri_pkg_idle_wkups: u64,
    pub ri_interrupt_wkups: u64,
    pub ri_pageins: u64,
    pub ri_wired_size: u64,
    pub ri_resident_size: u64,
    pub ri_phys_footprint: u64,
    pub ri_proc_start_abstime: u64,
    pub ri_proc_exit_abstime: u64,
    pub ri_child_user_time: u64,
    pub ri_child_system_time: u64,
    pub ri_child_pkg_idle_wkups: u64,
    pub ri_child_interrupt_wkups: u64,
    pub ri_child_pageins: u64,
    pub ri_child_elapsed_abstime: u64,
    pub ri_diskio_bytesread: u64,
    pub ri_diskio_byteswritten: u64,
    pub ri_cpu_time_qos_default: u64,
    pub ri_cpu_time_qos_maintenance: u64,
    pub ri_cpu_time_qos_background: u64,
    pub ri_cpu_time_qos_utility: u64,
    pub ri_cpu_time_qos_legacy: u64,
    pub ri_cpu_time_qos_user_initiated: u64,
    pub ri_cpu_time_qos_user_interactive: u64,
    pub ri_billed_system_time: u64,
    pub ri_serviced_system_time: u64,
    pub ri_logical_writes: u64,
    pub ri_lifetime_max_phys_footprint: u64,
    pub ri_instructions: u64,
    pub ri_cycles: u64,
    pub ri_billed_energy: u64,
    pub ri_serviced_energy: u64,
    pub ri_interval_max_phys_footprint: u64,
    pub ri_runnable_time: u64,
}

// `proc_pid_rusage`'s flavor for `struct rusage_info_v4` (<sys/resource.h>).
@platform(macos | ios)
const RUSAGE_INFO_V4: i32 = 4;

// <libproc.h> and <sys/sysctl.h> need the full Darwin API level.
@platform(macos | ios)
extern "C" {
    fn proc_pid_rusage(pid: i32, flavor: i32, buffer: *mut *mut void) i32;
    fn sysctlbyname(name: *const char, oldp: *mut void, oldlenp: *mut usize, newp: *mut void, newlen: usize) i32;
}

// This process's `rusage_info_v4` into `ri`; false when the call fails.
@platform(macos | ios)
fn rusage_info(ri: &mut RusageInfoV4) bool {
    static_assert(sizeof(RusageInfoV4) == 296, "rusage_info_v4 is 296 bytes");
    // The parameter is `rusage_info_t *` (`void **`) in C, but the call writes the record itself.
    return unsafe proc_pid_rusage(unistd::getpid(), RUSAGE_INFO_V4, (ri as *mut RusageInfoV4) as *mut *mut void) == 0;
}

// ---- Win32 ------------------------------------------------------------------------------------------------

// <winreg.h>: `HKEY_LOCAL_MACHINE` is `(HKEY)(ULONG_PTR)(LONG)0x80000002`, `RRF_RT_REG_SZ` is 2;
// <winerror.h>: `ERROR_SUCCESS` is 0.
@platform(windows)
const HKEY_LOCAL_MACHINE: isize = (0x80000002u32 as i32) as isize;
@platform(windows)
const RRF_RT_REG_SZ: stdlib::c_ulong = 2;
@platform(windows)
const ERROR_SUCCESS: stdlib::c_long = 0;

// The kernel32 and advapi32 calls, which the headers declare: a prototype of its own would conflict
// with <windows.h>, which the runtime includes. `FILETIME` counts 100 ns intervals in two DWORDs.
@platform(windows)
extern "C" "windows.h" {
    @import("FILETIME")
    struct FileTime {
        @import("dwLowDateTime")
        pub low: stdlib::c_ulong,
        @import("dwHighDateTime")
        pub high: stdlib::c_ulong,
    }
    fn GetCurrentProcess() *mut void;
    fn QueryProcessCycleTime(process: *mut void, cycles: *mut u64) i32;
    fn GetProcessTimes(
        process: *mut void,
        creation: *mut FileTime,
        exit: *mut FileTime,
        kernel: *mut FileTime,
        user: *mut FileTime,
    ) i32;
    fn RegGetValueA(
        key: *mut void,
        sub_key: *const char,
        value: *const char,
        flags: stdlib::c_ulong,
        // `LPDWORD`: `stdlib::c_ulong` spells `uint32_t`, which C does not convert to `unsigned long *`.
        kind: *mut void,
        data: *mut void,
        data_len: *mut void,
    ) stdlib::c_long;
}

// <psapi.h> spells `GetProcessMemoryInfo` as kernel32's `K32GetProcessMemoryInfo` for every Windows 7 or
// later target: no psapi library is linked.
@platform(windows)
extern "C" "psapi.h" {
    @import("PROCESS_MEMORY_COUNTERS")
    struct ProcessMemoryCounters {
        pub cb: stdlib::c_ulong,
        @import("PageFaultCount")
        pub page_fault_count: stdlib::c_ulong,
        @import("PeakWorkingSetSize")
        pub peak_working_set_size: usize,
        @import("WorkingSetSize")
        pub working_set_size: usize,
        @import("QuotaPeakPagedPoolUsage")
        pub quota_peak_paged_pool_usage: usize,
        @import("QuotaPagedPoolUsage")
        pub quota_paged_pool_usage: usize,
        @import("QuotaPeakNonPagedPoolUsage")
        pub quota_peak_non_paged_pool_usage: usize,
        @import("QuotaNonPagedPoolUsage")
        pub quota_non_paged_pool_usage: usize,
        @import("PagefileUsage")
        pub pagefile_usage: usize,
        @import("PeakPagefileUsage")
        pub peak_pagefile_usage: usize,
    }
    fn K32GetProcessMemoryInfo(process: *mut void, counters: *mut ProcessMemoryCounters, cb: stdlib::c_ulong) i32;
}

// This process's memory counters into `pmc`; false when the call fails.
@platform(windows)
fn memory_counters(pmc: &mut ProcessMemoryCounters) bool {
    static_assert(sizeof(ProcessMemoryCounters) == 72, "PROCESS_MEMORY_COUNTERS is 72 bytes");
    return unsafe K32GetProcessMemoryInfo(GetCurrentProcess(), pmc, sizeof(ProcessMemoryCounters) as stdlib::c_ulong) != 0;
}

// ---- allocation accounting -----------------------------------------------------------------------------
//
// Counted: every `malloc`, `calloc` and `realloc` call made by this binary's own object code (the program,
// std, the runtime, the ffi shims) while accounting is enabled; `realloc` counts its new size. Not counted:
// `free`, aligned allocation calls (std's Global makes them only for types aligned above what malloc
// guarantees), and on Apple the allocations libc makes internally (two-level namespace: libc binds its own
// malloc); glibc binds ours, so on Linux those count too. Windows (no real allocator to forward to across
// CRTs), wasm and Android count nothing: `supported` is 0.
//
// Accounting is per thread (a cache line per thread, handed out on the thread's first counted call, never
// reclaimed, at most ACCT_THREADS; later threads share one atomic line), so counting costs the owning thread
// two relaxed stores and no other thread anything. A snapshot sums every line: it is exact for every
// allocation that happens-before it (a joined thread, a waited task) and may miss or split the call another
// thread is making at that instant. Disabled, a call costs one relaxed load and a branch.

// The lines with a single owner; the threads after them share OVER.
const ACCT_THREADS: u32 = 1024;

@align(64)
struct Line {
    pub calls: u64,
    pub bytes: u64,
}

static mut LINES: [Line; 1024] = [Line { calls: 0, bytes: 0 }; 1024];
// The shared line: updated with atomic read-modify-writes.
static mut OVER: Line = Line { calls: 0, bytes: 0 };
// The lines handed out (atomic).
static mut LINE_N: u32 = 0;
// The accounting switch (atomic).
static mut ACCT_ON: i32 = 0;
// This thread's line, null before its first counted call.
@thread_local
static mut MINE: *mut Line = null;

// Whether this build defines the malloc family below: the condition of their gates.
const fn counted() bool {
    return PLATFORM == Platform::MacOS || PLATFORM == Platform::IOS || PLATFORM == Platform::Linux;
}

/// Whether malloc-family calls are counted on this platform: 1, else 0.
pub unsafe const fn sc_bs_alloc_supported() i32 {
    return counted() as i32;
}

/// Turn allocation accounting on (`on` nonzero) or off. Off, a call costs one relaxed load and a branch.
pub unsafe fn sc_bs_alloc_enable(on: i32) {
    unsafe atomic::store_i32(&mut ACCT_ON, (on != 0 && counted()) as i32, RELAXED);
}

/// Whether accounting is on: 1, else 0.
pub unsafe fn sc_bs_alloc_enabled() i32 {
    return unsafe atomic::load_i32(&ACCT_ON, RELAXED);
}

/// `out[0]` calls, `out[1]` bytes requested, `out[2]` threads that allocated, `out[3]` 1 when more threads
/// allocated than have private lines (the excess shared one contended line). All 0 where nothing is counted.
pub unsafe fn sc_bs_alloc_snapshot(out: *mut i64) {
    let n = unsafe atomic::load_u32(&LINE_N, RELAXED);
    let mut calls = unsafe atomic::load_u64(&OVER.calls, RELAXED);
    let mut bytes = unsafe atomic::load_u64(&OVER.bytes, RELAXED);
    for i in 0..n.min(ACCT_THREADS) {
        calls = calls.wrapping_add(unsafe atomic::load_u64(&LINES[i as usize].calls, RELAXED));
        bytes = bytes.wrapping_add(unsafe atomic::load_u64(&LINES[i as usize].bytes, RELAXED));
    }
    unsafe {
        out[0] = calls as i64;
        out[1] = bytes as i64;
        out[2] = n;
        out[3] = (n > ACCT_THREADS) as i64;
    }
}

/// Cumulative counted allocation calls.
pub unsafe fn sc_bs_alloc_calls() i64 {
    let mut v: [i64; 4] = [0; 4];
    unsafe sc_bs_alloc_snapshot(&mut v[0]);
    return v[0];
}

/// Cumulative bytes those calls requested.
pub unsafe fn sc_bs_alloc_bytes() i64 {
    let mut v: [i64; 4] = [0; 4];
    unsafe sc_bs_alloc_snapshot(&mut v[0]);
    return v[1];
}

// Count one call that requests `n` bytes, when accounting is on.
@platform(macos | ios | linux)
fn note(n: usize) {
    if unsafe atomic::load_i32(&ACCT_ON, RELAXED) == 0 {
        return;
    }
    let over = (unsafe &mut OVER) as *mut Line;
    let mut a = unsafe MINE;
    if a == null {
        let i = unsafe atomic::add_u32(&mut LINE_N, 1, RELAXED);
        a = if i < ACCT_THREADS {
            unsafe &mut LINES[i as usize];
        } else {
            over;
        };
        unsafe MINE = a;
    }
    unsafe {
        if a == over {
            atomic::add_u64(&mut (*a).calls, 1, RELAXED);
            atomic::add_u64(&mut (*a).bytes, n as u64, RELAXED);
            return;
        }
        // An owner-only line: a relaxed load and store pair is a plain load and store on every target, and
        // defined against the snapshot's concurrent relaxed loads. Bytes first, so a snapshot that sees the
        // new call count also sees its bytes.
        let b = atomic::load_u64(&(*a).bytes, RELAXED);
        atomic::store_u64(&mut (*a).bytes, b.wrapping_add(n as u64), RELAXED);
        let c = atomic::load_u64(&(*a).calls, RELAXED);
        atomic::store_u64(&mut (*a).calls, c.wrapping_add(1), RELAXED);
    }
}

// The functions below are the malloc family of this binary: at static link every other object binds its
// malloc/realloc/... references here (object files win over the shared libc), the generated runtime's leak
// tracker included, which wraps the program's call sites and calls these. Each forwards to the real
// allocator (the default zone on Apple, glibc's `__libc_*`), so pointers stay freely mixable with
// libc-allocated memory in both directions.

// `malloc_zone_t` of <malloc/malloc.h> up to the members called here, a prefix every zone version shares.
// The build's POSIX level cannot include the header.
@platform(macos | ios)
struct Zone {
    pub reserved1: *mut void,
    pub reserved2: *mut void,
    pub size: fn(*mut Zone, *const void) usize,
    pub malloc: fn(*mut Zone, usize) *mut void,
    pub calloc: fn(*mut Zone, usize, usize) *mut void,
    pub valloc: fn(*mut Zone, usize) *mut void,
    pub free: fn(*mut Zone, *mut void),
    pub realloc: fn(*mut Zone, *mut void, usize) *mut void,
}

@platform(macos | ios)
extern "C" {
    fn malloc_default_zone() *mut Zone;
    fn malloc_zone_from_ptr(p: *const void) *mut Zone;
}

// The default zone, cached on first use (atomic, as an address). Its own entry points are called: the zone
// API's wrappers (`malloc_zone_malloc` and friends) add validation and a second zone lookup that cost about
// 3 ns per call on top of the 19 ns allocation itself (measured on an M3 Max). The default zone never
// changes once the process has allocated. `free` and `realloc` still find the zone of the pointer they are
// given, so memory from any zone stays freely mixable.
@platform(macos | ios)
static mut ZONE0: usize = 0;

@platform(macos | ios)
fn zone0() *mut Zone {
    let mut z = (unsafe atomic::load_usize(&ZONE0, RELAXED)) as *mut Zone;
    if z == null {
        z = unsafe malloc_default_zone();
        unsafe atomic::store_usize(&mut ZONE0, z as usize, RELAXED);
    }
    return z;
}

/// C `malloc`: counted, then the default zone's.
@platform(macos | ios)
@export("malloc")
unsafe fn counted_malloc(n: usize) *mut void {
    note(n);
    let z = zone0();
    return unsafe (*z).malloc(z, n);
}

/// C `calloc`: counted with the product of its arguments, then the default zone's.
@platform(macos | ios)
@export("calloc")
unsafe fn counted_calloc(c: usize, n: usize) *mut void {
    note(c.wrapping_mul(n));
    let z = zone0();
    return unsafe (*z).calloc(z, c, n);
}

/// C `realloc`: counted with the new size, then the zone that owns `p`.
@platform(macos | ios)
@export("realloc")
unsafe fn counted_realloc(p: *mut void, n: usize) *mut void {
    note(n);
    let mut z: *mut Zone = null;
    if p != null {
        z = unsafe malloc_zone_from_ptr(p);
    }
    if z == null {
        z = zone0();
    }
    return unsafe (*z).realloc(z, p, n);
}

/// C `free`: the zone that owns `p`; a pointer of no zone is ignored.
@platform(macos | ios)
@export("free")
unsafe fn counted_free(p: *mut void) {
    if p == null {
        return;
    }
    let z = unsafe malloc_zone_from_ptr(p);
    if z != null {
        unsafe (*z).free(z, p);
    }
}

// glibc's real allocator under its own names, which no header declares.
@platform(linux)
extern "C" {
    fn __libc_malloc(n: usize) *mut void;
    fn __libc_calloc(c: usize, n: usize) *mut void;
    fn __libc_realloc(p: *mut void, n: usize) *mut void;
    fn __libc_free(p: *mut void);
}

/// C `malloc`: counted, then glibc's.
@platform(linux)
@export("malloc")
unsafe fn counted_malloc(n: usize) *mut void {
    note(n);
    return unsafe __libc_malloc(n);
}

/// C `calloc`: counted with the product of its arguments, then glibc's.
@platform(linux)
@export("calloc")
unsafe fn counted_calloc(c: usize, n: usize) *mut void {
    note(c.wrapping_mul(n));
    return unsafe __libc_calloc(c, n);
}

/// C `realloc`: counted with the new size, then glibc's.
@platform(linux)
@export("realloc")
unsafe fn counted_realloc(p: *mut void, n: usize) *mut void {
    note(n);
    return unsafe __libc_realloc(p, n);
}

/// C `free`: glibc's.
@platform(linux)
@export("free")
unsafe fn counted_free(p: *mut void) {
    unsafe __libc_free(p);
}

// ---- resident memory -------------------------------------------------------------------------------------

/// Peak resident set, bytes; -1 when unavailable.
@platform(windows)
pub unsafe fn sc_bs_rss_peak() i64 {
    let mut pmc = unsafe zeroed::<ProcessMemoryCounters>();
    if !memory_counters(&mut pmc) {
        return -1;
    }
    return pmc.peak_working_set_size as i64;
}

/// Current resident set, bytes; -1 when unavailable.
@platform(windows)
pub unsafe fn sc_bs_rss_now() i64 {
    let mut pmc = unsafe zeroed::<ProcessMemoryCounters>();
    if !memory_counters(&mut pmc) {
        return -1;
    }
    return pmc.working_set_size as i64;
}

/// Peak resident set, bytes; -1 when unavailable.
@platform(wasm)
pub unsafe fn sc_bs_rss_peak() i64 {
    return -1;
}

/// Current resident set, bytes; -1 when unavailable.
@platform(wasm)
pub unsafe fn sc_bs_rss_now() i64 {
    return -1;
}

/// Peak resident set, bytes; -1 when unavailable.
@platform(macos | ios)
pub unsafe fn sc_bs_rss_peak() i64 {
    let mut ru = unsafe zeroed::<rusage>();
    if unsafe getrusage(RUSAGE_SELF, &mut ru) != 0 {
        return -1;
    }
    return ru.ru_opaque[0] as i64; // `ru_maxrss`, in bytes on Apple
}

/// Current resident set, bytes; -1 when unavailable.
@platform(macos | ios)
pub unsafe fn sc_bs_rss_now() i64 {
    let mut ri = unsafe zeroed::<RusageInfoV4>();
    if !rusage_info(&mut ri) {
        return -1;
    }
    return ri.ri_resident_size as i64;
}

/// Peak resident set, bytes; -1 when unavailable.
@platform(linux | android)
pub unsafe fn sc_bs_rss_peak() i64 {
    let mut ru = unsafe zeroed::<rusage>();
    if unsafe getrusage(RUSAGE_SELF, &mut ru) != 0 {
        return -1;
    }
    return ru.ru_maxrss as i64 * 1024; // KiB
}

@platform(linux | android)
extern "C" "unistd.h" {
    fn sysconf(name: i32) stdlib::c_long;
    // The C library's own value: glibc's and bionic's differ.
    const _SC_PAGESIZE: i32;
}

/// Current resident set, bytes; -1 when unavailable.
@platform(linux | android)
pub unsafe fn sc_bs_rss_now() i64 {
    // /proc/self/statm: "size resident shared text lib data dt", in pages.
    let fd = unsafe fcntl::open("/proc/self/statm".ptr() as *const char, fcntl::O_RDONLY);
    if fd < 0 {
        return -1;
    }
    let mut buf: [u8; 128] = [0; 128];
    let got = unsafe unistd::read(fd, (&mut buf[0]) as *mut u8, 128);
    unsafe unistd::close(fd);
    if got <= 0 {
        return -1;
    }
    let text: []u8 = buf;
    let mut at: usize = 0;
    let size = decimal_at(text, got as usize, &mut at);
    let resident = decimal_at(text, got as usize, &mut at);
    if size < 0 || resident < 0 {
        return -1;
    }
    return resident * (unsafe sysconf(_SC_PAGESIZE)) as i64;
}

// The unsigned decimal after the blanks at `*at` of `s[0..n]`, which `*at` then passes; -1 when there is
// no digit there.
@platform(linux | android)
fn decimal_at(s: []u8, n: usize, at: &mut usize) i64 {
    while *at < n && (s[*at] == b' ' || s[*at] == b'\t' || s[*at] == b'\n') {
        *at += 1;
    }
    let start = *at;
    let mut v: i64 = 0;
    while *at < n && s[*at] >= b'0' && s[*at] <= b'9' {
        v = v.wrapping_mul(10).wrapping_add(s[*at] - b'0');
        *at += 1;
    }
    return if *at == start {
        -1;
    } else {
        v;
    };
}

// ---- identity --------------------------------------------------------------------------------------------

/// The CPU model name into `buf` (`cap` bytes), nul-terminated; 0 on success, -1 when unknown.
@platform(windows)
pub unsafe fn sc_bs_cpu_model(buf: *mut char, cap: usize) i32 {
    // RegGetValueA nul-terminates and fails cleanly on overflow.
    let mut len = cap as stdlib::c_ulong;
    let rc = unsafe RegGetValueA(
        HKEY_LOCAL_MACHINE as *mut void,
        "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0".ptr() as *const char,
        "ProcessorNameString".ptr() as *const char,
        RRF_RT_REG_SZ,
        null,
        buf,
        &mut len,
    );
    return if rc == ERROR_SUCCESS {
        0;
    } else {
        -1;
    };
}

/// The CPU model name into `buf` (`cap` bytes), nul-terminated; 0 on success, -1 when unknown.
@platform(wasm)
pub unsafe fn sc_bs_cpu_model(_buf: *mut char, _cap: usize) i32 {
    return -1;
}

/// The CPU model name into `buf` (`cap` bytes), nul-terminated; 0 on success, -1 when unknown.
@platform(macos | ios)
pub unsafe fn sc_bs_cpu_model(buf: *mut char, cap: usize) i32 {
    let mut l = cap;
    if unsafe sysctlbyname("machdep.cpu.brand_string".ptr() as *const char, buf, &mut l, null, 0) != 0 {
        return -1;
    }
    return 0;
}

// The longest /proc/cpuinfo line `sc_bs_cpu_model` reads whole; a longer one reads as several.
@platform(linux | android)
const CPUINFO_LINE: usize = 511;

/// The CPU model name into `buf` (`cap` bytes), nul-terminated; 0 on success, -1 when unknown.
///
/// The "model name" line of /proc/cpuinfo, an x86 convention: some ARM kernels lack it, and then the
/// result is -1.
@platform(linux | android)
pub unsafe fn sc_bs_cpu_model(buf: *mut char, cap: usize) i32 {
    if cap == 0 {
        return -1;
    }
    let fd = unsafe fcntl::open("/proc/cpuinfo".ptr() as *const char, fcntl::O_RDONLY);
    if fd < 0 {
        return -1;
    }
    let mut chunk: [u8; 4096] = [0; 4096];
    let mut line: [u8; 512] = [0; 512];
    let mut n: usize = 0;
    let mut rc: i32 = -2;
    while rc == -2 {
        let got = unsafe unistd::read(fd, (&mut chunk[0]) as *mut u8, 4096);
        if got <= 0 {
            if n != 0 {
                rc = cpu_model_line(line, n, buf, cap);
            }
            break;
        }
        for i in 0..got as usize {
            let c = unsafe chunk[i];
            unsafe line[n] = c;
            n += 1;
            if c == b'\n' || n == CPUINFO_LINE {
                rc = cpu_model_line(line, n, buf, cap);
                n = 0;
                if rc != -2 {
                    break;
                }
            }
        }
    }
    unsafe unistd::close(fd);
    return if rc == 0 {
        0;
    } else {
        -1;
    };
}

// /proc/cpuinfo line `line[0..n]`: 0 after it copied the model name into `buf`, -1 when it is a "model name"
// line without a value, -2 when it is another line.
@platform(linux | android)
unsafe fn cpu_model_line(line: []u8, n: usize, buf: *mut char, cap: usize) i32 {
    let key = "model name";
    for i in 0..key.len() {
        if i >= n || line[i] != key.byte_at(i) {
            return -2;
        }
    }
    let mut a = key.len();
    while a < n && line[a] != b':' {
        a += 1;
    }
    if a == n {
        return -1;
    }
    a += 1;
    while a < n && (line[a] == b' ' || line[a] == b'\t') {
        a += 1;
    }
    let mut e = n;
    while e > a && (line[e - 1] == b'\n' || line[e - 1] == b'\r') {
        e -= 1;
    }
    let k = (e - a).min(cap - 1);
    for i in 0..k {
        unsafe buf[i] = line[a + i] as char;
    }
    unsafe buf[k] = 0 as char;
    return 0;
}

/// The operating system this binary runs on: "macos" (every Apple target), "linux" (Android too),
/// "windows" or "wasm".
pub unsafe const fn sc_bs_os() *const char {
    if PLATFORM == Platform::Windows {
        return "windows".ptr() as *const char;
    } else if PLATFORM == Platform::MacOS || PLATFORM == Platform::IOS {
        return "macos".ptr() as *const char;
    } else if PLATFORM == Platform::Linux || PLATFORM == Platform::Android {
        return "linux".ptr() as *const char;
    }
    return "wasm".ptr() as *const char;
}

/// The architecture this binary was built for: "aarch64", "x86_64" or "wasm32".
pub unsafe const fn sc_bs_arch() *const char {
    if ARCH == Arch::AArch64 {
        return "aarch64".ptr() as *const char;
    } else if ARCH == Arch::X86_64 {
        return "x86_64".ptr() as *const char;
    }
    return "wasm32".ptr() as *const char;
}

// ---- fresh processes ---------------------------------------------------------------------------------------

/// Fork: 0 in the child, the child's pid in the parent, -1 where there is no fork (Windows, wasm).
@platform(windows | wasm)
pub unsafe fn sc_bs_fork() i64 {
    return -1;
}

/// Wait for child `pid`: its exit code, 128 plus the signal that killed it, or -1 when the wait itself
/// failed.
@platform(windows | wasm)
pub unsafe fn sc_bs_wait(_pid: i64) i32 {
    return -1;
}

/// Fork: 0 in the child, the child's pid in the parent, -1 where there is no fork (Windows, wasm). On Linux
/// the child drops the parent's cycle events, which count the child only once it exits, and opens its own
/// on its first `sc_bs_cycles` call; the Apple counters are the calling process's own.
@platform(macos | ios | linux | android)
pub unsafe fn sc_bs_fork() i64 {
    let pid = unsafe unistd::fork();
    if PLATFORM == Platform::Linux || PLATFORM == Platform::Android {
        if pid == 0 {
            perf_close_all();
            unsafe PERF_SCOPE = -1;
        }
    }
    return pid;
}

@platform(macos | ios | linux | android)
extern "C" "sys/wait.h" {
    fn waitpid(pid: i32, status: *mut i32, options: i32) i32;
}

/// Wait for child `pid`: its exit code, 128 plus the signal that killed it, or -1 when the wait itself
/// failed.
@platform(macos | ios | linux | android)
pub unsafe fn sc_bs_wait(pid: i64) i32 {
    let mut st: i32 = 0;
    if (unsafe waitpid(pid as i32, &mut st, 0)) as i64 != pid {
        return -1;
    }
    // The status word of <sys/wait.h> on Apple and Linux: the low 7 bits hold the terminating signal, 0 for
    // an exit, whose code is bits 8 to 15, and 0x7f for a stop.
    let sig = st & 0x7f;
    if sig == 0 {
        return st >> 8 & 0xff;
    }
    if sig != 0x7f {
        return 128 + sig;
    }
    return -1;
}

/// Flush every stdio stream (before a fork, so the child does not carry the parent's unwritten output).
pub unsafe fn sc_bs_flush() {
    unsafe stdio::fflush(null);
}

// ---- optimisation barrier ----------------------------------------------------------------------------------

// The barrier's cell: written and read only next to a compiler memory barrier.
static mut SINK_CELL: u64 = 0;

// A compiler memory barrier (`lir::ir::SYS_BARRIER`).
extern "C" {
    fn sc_sys_barrier();
}

/// Store `v` where the compiler must assume it is read: the computation producing `v` cannot be deleted or
/// folded across this call, however hard link-time optimization tries.
pub unsafe fn sc_bs_sink(v: u64) {
    unsafe {
        SINK_CELL = v;
        sc_sys_barrier();
    }
}

/// The last value `sc_bs_sink` stored, read from memory: how a test proves the store happened.
pub unsafe fn sc_bs_sunk() u64 {
    unsafe sc_sys_barrier();
    return unsafe SINK_CELL;
}

@platform(windows)
extend FileTime {
    // The count as one 64-bit number.
    fn ticks(self: &Self) u64 {
        return self.high as u64 << 32 | self.low as u64;
    }
}
