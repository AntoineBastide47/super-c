// OS threads of std::platform: create and join (over the runtime substrate, `ffi/sc_runtime.spc`), dynamic
// thread-local slots, and address-based parking. A Super-C program shares work through `launch` and
// `std::parallel::thread`; this is the layer under them. WASI runs one thread: there `spawn` is
// Unsupported and a `TlsKey` is a plain slot. Unstable, internal to std and the compiler.
import sc_runtime;
import std::platform::error;

@platform(macos | ios | linux | android)
extern "C" "pthread.h" {
    @platform(macos | ios)
    @layout(8, 8)
    type pthread_key_t;
    @platform(linux | android)
    @layout(4, 4)
    type pthread_key_t;
    fn pthread_key_create(key: *mut pthread_key_t, destructor: fn(*mut void)) i32;
    fn pthread_key_delete(key: pthread_key_t) i32;
    fn pthread_getspecific(key: pthread_key_t) *mut void;
    fn pthread_setspecific(key: pthread_key_t, value: *const void) i32;
}

@platform(windows)
extern "C" "windows.h" {
    fn TlsAlloc() u32;
    fn TlsFree(index: u32) i32;
    fn TlsGetValue(index: u32) *mut void;
    fn TlsSetValue(index: u32, value: *mut void) i32;
    const TLS_OUT_OF_INDEXES: u32 = 0xFFFFFFFF;
}

/// A running OS thread. `join` waits for it; dropping the handle detaches it, and the thread runs on.
@no_const
pub struct Thread {
    handle: *mut void,
}

/// A thread-local slot: one pointer per thread, null until that thread sets it. Deleting the key (dropping
/// it) does not free what the threads stored.
@no_const
pub struct TlsKey {
    slot: KeySlot,
}

// What names the slot: a pthread key, a TLS index, or on WASI's one thread the value itself.
@platform(macos | ios | linux | android)
type KeySlot = pthread_key_t;
@platform(windows)
type KeySlot = u32;
@platform(wasm)
type KeySlot = *mut void;

// The bits of a key destructor, `void (*)(void *)`: null passes as one, for a key without a destructor.
@platform(macos | ios | linux | android)
union KeyDestructor {
    pub f: fn(*mut void),
    pub p: *mut void,
}

/// Start an OS thread that runs `entry(arg)`. Unsupported on WASI.
/// Safety: `arg` stays valid, and is safe to use from the new thread, for as long as `entry` uses it.
@platform(!wasm)
pub unsafe fn spawn(entry: fn(*mut void) *mut void, arg: *mut void) Result<Thread, IoError> {
    let mut h: *mut void = null;
    let rc = unsafe sc_runtime::sc_rt_thread_create(&mut h, entry, arg);
    if rc != 0 {
        return Err(thread_error(rc, IoOp::ThreadCreate));
    }
    return Ok(Thread::adopt(h));
}
/// Start an OS thread that runs `entry(arg)`. Unsupported on WASI.
/// Safety: `arg` stays valid, and is safe to use from the new thread, for as long as `entry` uses it.
@platform(wasm)
pub unsafe fn spawn(_entry: fn(*mut void) *mut void, _arg: *mut void) Result<Thread, IoError> {
    return Result::<Thread, IoError>::Err(error::unsupported(IoOp::ThreadCreate));
}

// The error of a substrate thread call that returned `rc`: an errno value on POSIX, nonzero with the
// reason in GetLastError on Windows.
@platform(!windows)
const fn thread_error(rc: i32, op: IoOp) IoError {
    return error::code_error(rc, op);
}
@platform(windows)
fn thread_error(_rc: i32, op: IoOp) IoError {
    return error::last_error(op);
}

/// Give the rest of this thread's time slice to another thread.
pub fn yield_now() {
    sc_runtime::sc_rt_thread_yield();
}

/// Block the calling OS thread while `*word == expected`, until an `unpark_one` or `unpark_all` of `word`,
/// or for `timeout_ns >= 0` until that many nanoseconds pass. A wakeup may be spurious: check the condition
/// again in a loop. On WASI nothing can change the word, so the call returns after the timeout.
/// Safety: `word` is valid and aligned for an atomic access while the call runs.
pub unsafe fn park(word: *mut i32, expected: i32, timeout_ns: i64) {
    unsafe sc_runtime::sc_rt_park(word, expected, timeout_ns);
}

/// Wake one thread parked on `word`. The address is not read: it may name a frame its owner has left.
/// Safety: the caller published the new state to `*word` before the call.
pub unsafe fn unpark_one(word: *mut i32) {
    unsafe sc_runtime::sc_rt_unpark_one(word);
}

/// Wake every thread parked on `word`. Safety: as `unpark_one`.
pub unsafe fn unpark_all(word: *mut i32) {
    unsafe sc_runtime::sc_rt_unpark_all(word);
}

extend Thread {
    @platform(!wasm)
    fn adopt(handle: *mut void) Thread {
        return Thread { handle: handle };
    }
    /// Wait until the thread ends.
    pub fn join(self: Thread) Result<Unit, IoError> {
        let h = self.handle;
        forget(self);
        let rc = unsafe sc_runtime::sc_rt_thread_join(h);
        if rc != 0 {
            // The substrate keeps a handle whose join failed: the thread may still run, so it is detached.
            let _ = unsafe sc_runtime::sc_rt_thread_detach(h);
            return Err(thread_error(rc, IoOp::ThreadJoin));
        }
        return Ok(Unit {});
    }
}

extend Thread as Free {
    pub fn free(self: &mut Thread) {
        if unsafe sc_runtime::sc_rt_thread_detach(self.handle) != 0 {
            panic("thread: the handle names no joinable thread");
        }
    }
}

extend TlsKey {
    /// A new slot, null on every thread. LimitExceeded when the system has no free key.
    @platform(macos | ios | linux | android)
    pub fn new() Result<TlsKey, IoError> {
        let mut k = unsafe zeroed::<pthread_key_t>();
        let rc = unsafe pthread_key_create(&mut k, KeyDestructor { p: null }.f);
        if rc != 0 {
            return Err(error::code_error(rc, IoOp::ThreadLocal));
        }
        return Ok(TlsKey { slot: k });
    }
    /// A new slot, null on every thread. LimitExceeded when the system has no free key.
    @platform(windows)
    pub fn new() Result<TlsKey, IoError> {
        let i = unsafe TlsAlloc();
        if i == TLS_OUT_OF_INDEXES {
            return Err(IoError::new(IoErrorKind::LimitExceeded, IoOp::ThreadLocal));
        }
        return Ok(TlsKey { slot: i });
    }
    /// A new slot, null on every thread. LimitExceeded when the system has no free key.
    @platform(wasm)
    pub fn new() Result<TlsKey, IoError> {
        return Result::<TlsKey, IoError>::Ok(TlsKey { slot: null });
    }

    /// This thread's value of the slot.
    @platform(macos | ios | linux | android)
    pub fn get(self: &TlsKey) *mut void {
        return unsafe pthread_getspecific(self.slot);
    }
    /// This thread's value of the slot.
    @platform(windows)
    pub fn get(self: &TlsKey) *mut void {
        return unsafe TlsGetValue(self.slot);
    }
    /// This thread's value of the slot.
    @platform(wasm)
    pub fn get(self: &TlsKey) *mut void {
        return self.slot;
    }

    /// Set this thread's value of the slot. OutOfMemory when the system cannot store it.
    @platform(macos | ios | linux | android)
    pub fn set(self: &mut TlsKey, value: *mut void) Result<Unit, IoError> {
        let rc = unsafe pthread_setspecific(self.slot, value);
        if rc != 0 {
            return Err(error::code_error(rc, IoOp::ThreadLocal));
        }
        return Ok(Unit {});
    }
    /// Set this thread's value of the slot. OutOfMemory when the system cannot store it.
    @platform(windows)
    pub fn set(self: &mut TlsKey, value: *mut void) Result<Unit, IoError> {
        if unsafe TlsSetValue(self.slot, value) == 0 {
            return Err(error::last_error(IoOp::ThreadLocal));
        }
        return Ok(Unit {});
    }
    /// Set this thread's value of the slot. OutOfMemory when the system cannot store it.
    @platform(wasm)
    pub fn set(self: &mut TlsKey, value: *mut void) Result<Unit, IoError> {
        self.slot = value;
        return Result::<Unit, IoError>::Ok(Unit {});
    }
}

extend TlsKey as Free {
    @platform(macos | ios | linux | android)
    pub fn free(self: &mut TlsKey) {
        let _ = unsafe pthread_key_delete(self.slot);
    }
    @platform(windows)
    pub fn free(self: &mut TlsKey) {
        let _ = unsafe TlsFree(self.slot);
    }
    @platform(wasm)
    pub fn free(self: &mut TlsKey) {}
}
