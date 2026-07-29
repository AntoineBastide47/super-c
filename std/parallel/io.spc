// The reactor: park a coroutine on a file descriptor instead of a thread. Import with
// `import std::parallel::io;`.
//
//     io::wait_readable(fd);              // this worker runs other tasks meanwhile
//     let n = io::read(fd, buf);          // reads, parking whenever the descriptor is not ready
//
// `blocking::call` makes a blocking call SAFE by moving it to a thread that is allowed to block, which
// costs a thread per concurrent operation. This costs a registration instead: one reactor thread runs the
// platform poller (kqueue, epoll or select) and turns readiness into a wake, so ten thousand tasks waiting
// on ten thousand descriptors are ten thousand parked coroutines and one thread.
//
// Two things make it safe. The registration is armed by the park hand-off -- AFTER the coroutine's context
// is saved -- so an event can never be delivered to a task that is still switching out. And the
// registration itself is heap-owned with a claim: the reactor and a timing-out waiter race a CAS for it,
// the winner decides what happens, and the loser touches nothing. Without that, an event already in flight
// when a timed wait gives up would write into a stack frame that no longer exists.
//
// Readiness-based on every platform. Windows watches SOCKETS ONLY -- a socket is not a CRT file descriptor
// there -- and its select() backend caps the simultaneously parked descriptors at FD_SETSIZE; arming past
// that fails loudly rather than silently. IOCP would lift both, at the cost of a completion-model interface.

import sc_runtime;
import atomic;
import sc_io;
import std::parallel::runtime as runtime;
import std::parallel::time as time;

// A pending registration. Heap-owned rather than living in the waiting frame, because an event can still be
// in flight when a timed wait gives up. `state` is that race: 0 armed, 1 claimed by the reactor, 2 cancelled
// by the waiter. Whoever wins the CAS owns what happens next, and exactly one of them frees it.
struct Interest {
    pub co: *mut runtime::Coroutine,
    pub token: u32,
    pub fd: i32,
    pub write: i32,
    pub state: i32,
}

// A batch of ready cookies. Wrapped in a struct so it is zero-initialized: reading an uninitialized array
// is (rightly) rejected, and the poller fills only the first `n` slots.
struct EvBuf {
    pub e: [*mut void; 64],
}

struct Reactor {
    pub poller: *mut void,
    pub thread: *mut void,
    pub running: i32,
}

static mut G_STATE: i32 = 0; // 0 uninit / 1 building / 2 ready

static mut G_REACTOR: *mut Reactor = null;

fn free_interest(it: *mut Interest) {
    let mut g = Global {};
    unsafe g.dealloc(it, sizeof(Interest), alignof(Interest));
}

// The reactor thread: block in the poller, turn every ready registration back into a wake. One thread for
// every descriptor in the program.
fn reactor_main(arg: *mut void) *mut void {
    let r = arg as *mut Reactor;
    let mut evs = EvBuf {};
    while atomic::load_i32(&mut unsafe r.running, 1) != 0 {
        let n = unsafe sc_io::sc_io_wait(r.poller, &mut evs.e[0], 64, -1);
        if n < 0 {
            break;
        }
        for i in 0..n {
            let it = (unsafe evs.e[i as usize]) as *mut Interest;
            if it == null {
                continue;
            }
            // Claim it. Losing means a timed-out waiter already took it and freed it -- so this event is
            // stale and nothing here may touch the node again.
            if !atomic::cas_i32(&mut unsafe it.state, 0, 1, false, 4, 0) {
                continue;
            }
            let _ = runtime::wake(unsafe it.co, unsafe it.token);
        }
    }
    return null;
}

fn build_reactor() *mut Reactor {
    let mut g = Global {};
    let r = (unsafe g.alloc(sizeof(Reactor), alignof(Reactor))) as *mut Reactor;
    unsafe r.poller = unsafe sc_io::sc_io_new();
    unsafe r.running = 1;
    let mut h: *mut void = null;
    let _ = unsafe sc_runtime::sc_rt_thread_create(&mut h, reactor_main, r);
    unsafe r.thread = h;
    return r;
}

/// Start the reactor if it is not running and return it. `pub` for linkage.
pub fn ensure_reactor() *mut Reactor {
    // `G_REACTOR` is ordered by `G_STATE`, which the compiler cannot see: the CAS winner publishes the
    // pointer and THEN releases state 2, and every reader acquires state 2 first, so the write
    // happens-before every read. That handshake is what this `unsafe` asserts.
    unsafe {
        let sp = (&mut G_STATE) as *mut i32; // order codes: 0 Relaxed, 1 Acquire, 2 Release, 4 SeqCst
        if atomic::load_i32(sp, 1) == 2 {
            return G_REACTOR;
        }
        if atomic::cas_i32(sp, 0, 1, false, 4, 0) {
            let r = build_reactor();
            G_REACTOR = r;
            atomic::store_i32(sp, 2, 2);
            return r;
        }
        while atomic::load_i32(sp, 1) != 2 {}
        return G_REACTOR;
    }
}

// The park hand-off: arm the registration once the coroutine's context is saved. Doing it here rather than
// before the park is the whole trick -- the reactor cannot deliver an event to a coroutine it does not know
// about yet, and it does not know about this one until its context is safely stored.
fn commit_arm(p: *mut void) {
    let it = p as *mut Interest;
    let r = unsafe G_REACTOR;
    if unsafe sc_io::sc_io_arm(r.poller, it.fd, it.write, p) == 0 {
        return;
    }
    // Arming failed (a closed or invalid descriptor): wake the waiter straight back up rather than leave it
    // parked forever. It re-checks the descriptor and gets the real error from the syscall.
    if atomic::cas_i32(&mut unsafe it.state, 0, 1, false, 4, 0) {
        let _ = runtime::wake(unsafe it.co, unsafe it.token);
    }
}

/// Wait until `fd` is ready in the given direction, or until `deadline` (a `time::deadline_in` value; 0
/// waits indefinitely). Reports whether it became ready -- `false` means the deadline passed first.
///
/// From a coroutine this PARKS, freeing the worker. From any other thread it blocks that thread, which is
/// what it would have done anyway.
pub fn wait_until(fd: i32, write: bool, deadline: u64) bool {
    let r = ensure_reactor();
    let w = if write {
        1;
    } else {
        0;
    };
    let co = runtime::current();
    if co == null {
        // Not a coroutine: nothing to park, so just wait on the one descriptor. A poll(2) rather than a
        // poller of its own -- that meant building and tearing down a kqueue per call.
        let ms = if deadline == 0 {
            -1;
        } else {
            (time::remaining_ns(deadline) / 1000000) as i32 + 1;
        };
        return unsafe sc_io::sc_io_wait_fd(fd, w, ms) > 0;
    }
    let mut g = Global {};
    let it = (unsafe g.alloc(sizeof(Interest), alignof(Interest))) as *mut Interest;
    let token = runtime::park_begin(co);
    unsafe it[0] = Interest { co: co, token: token, fd: fd, write: w, state: 0 };
    runtime::park_timed(token, deadline, commit_arm, it);
    // Back: the descriptor is ready, or the deadline claimed us first. Take the node off the poller either
    // way, then settle the race for it.
    if deadline != 0 {
        runtime::cancel_timer(co);
    }
    let _ = unsafe sc_io::sc_io_disarm(r.poller, fd, w);
    if atomic::cas_i32(&mut unsafe it.state, 0, 2, false, 4, 0) {
        free_interest(it); // still armed: the deadline is what woke us, and the reactor will not touch it
        return false;
    }
    free_interest(it); // the reactor claimed it, so it fired -- and left the freeing to us
    return true;
}

/// Wait until `fd` can be read without blocking.
pub fn wait_readable(fd: i32) {
    let _ = wait_until(fd, false, 0);
}

/// Wait until `fd` can be written without blocking.
pub fn wait_writable(fd: i32) {
    let _ = wait_until(fd, true, 0);
}

/// Read from `fd`, parking whenever it is not ready. Returns what the read returned: the byte count, `0` at
/// end of file, or negative for a real error (one that is not "would block").
pub fn read(fd: i32, buf: []mut u8) isize {
    loop {
        let n = unsafe sc_io::sc_io_read(fd, buf.ptr, buf.len());
        if n >= 0 {
            return n;
        }
        if unsafe sc_io::sc_io_would_block() == 0 {
            return n;
        }
        wait_readable(fd);
    }
}

/// Write all of `buf` to `fd`, parking whenever it is not ready. Returns the number of bytes written, or
/// negative on a real error.
pub fn write(fd: i32, buf: []u8) isize {
    let mut at: usize = 0;
    while at < buf.len() {
        let n = unsafe sc_io::sc_io_write(fd, unsafe (buf.ptr + at), buf.len() - at);
        if n > 0 {
            at = at + n as usize;
            continue;
        }
        if n == 0 {
            break;
        }
        if unsafe sc_io::sc_io_would_block() == 0 {
            return n;
        }
        wait_writable(fd);
    }
    return at as isize;
}

/// Stop the reactor thread and release its poller. Idempotent; a no-op if it never started. Call it once,
/// from the main thread, after every task that could still be waiting on a descriptor has finished.
pub fn shutdown() {
    let sp = (&mut unsafe G_STATE) as *mut i32;
    if atomic::load_i32(sp, 1) != 2 {
        return;
    }
    let r = unsafe G_REACTOR;
    atomic::store_i32(&mut unsafe r.running, 0, 2);
    unsafe sc_io::sc_io_wake(r.poller);
    let _ = unsafe sc_runtime::sc_rt_thread_join(r.thread);
    unsafe sc_io::sc_io_free(r.poller);
    let mut g = Global {};
    unsafe g.dealloc(r, sizeof(Reactor), alignof(Reactor));
    atomic::store_i32(sp, 0, 2);
    unsafe G_REACTOR = null;
}
