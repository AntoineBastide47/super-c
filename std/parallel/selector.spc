// Wait on several channel operations at once. Import with `import std::parallel::selector;`.
//
// `recv_timeout` in a loop polls; this parks. A `Selector` registers a wait node on EVERY armed channel's
// queue under one wake token, parks once, and the first channel to notify wins the token -- so a task
// waiting on four channels costs one park, not four, and wakes the instant any of them moves.
//
// It reports WHICH arm is ready, not the value: the arm indices `arm_recv`/`arm_send` hand back identify
// the operation, and the caller performs it with `try_recv`/`try_send`. That is what lets one selector mix
// channels of different element types -- the selector itself never knows `T`. The `select` keyword is sugar
// over exactly this.
//
//     let mut s = selector::Selector::new();
//     let jobs_arm = s.arm_recv(&jobs);
//     let ctrl_arm = s.arm_recv(&ctrl);
//     switch s.wait_timeout(time::Duration::from_secs(1)) {
//         Ready(i) => {
//             if i == jobs_arm { process(jobs.try_recv()); } else { control(ctrl.try_recv()); }
//         },
//         TimedOut => {},
//     }
//
// Fairness has two halves. When several arms are ready at once there is no notion of which became ready
// first -- nothing records it, and recording it would cost an atomic on the channel send path -- so one is
// picked uniformly at random, which is what keeps a busy arm from starving a quiet one. When nothing is
// ready the selector parks, and then the order IS observable: the notify that wins the wake token names its
// arm, and that arm is retried first.
//
// A selector borrows its endpoints: it holds their addresses, so it must not outlive them. Arm the ones a
// single wait needs, wait, act, and let it go.

import std::parallel::sync as sync;
import std::parallel::channel as channel;
import std::parallel::runtime as runtime;
import std::parallel::time as time;
import std::parallel::platform as platform;

/// The most operations one selector can wait on.
pub const MAX_ARMS: usize = 16;

// How long a plain (non-coroutine) thread sleeps between re-checks. It cannot park on several queues at
// once -- that needs a coroutine's single wake token -- so it polls; short enough to stay responsive,
// long enough not to spin. Coroutines never take this path.
const POLL_SLICE_NS: i64 = 200000;

/// The outcome of a wait: the arm index that is ready, or nothing -- the deadline passed, or `poll` found
/// no ready arm.
pub enum Selected {
    Ready(usize),
    TimedOut,
}

// One armed operation, type-erased. `ready` is `recv_ready::<T>`/`send_ready::<T>`, monomorphized where the
// arm was added, so the selector can ask "would this proceed?" without knowing the element type. `raw`
// guards both the channel state and `cv`'s queue; `w` is this selector's node on that queue.
@no_const
struct Arm {
    pub obj: *const void,
    pub ready: fn(*const void) bool,
    pub raw: *mut sync::RawMutex,
    pub cv: *const sync::Condvar,
    pub w: sync::Waiter,
}

/// A set of channel operations to wait on. Build it with `new`, add operations with `arm_recv`/`arm_send`,
/// then `wait`. Reusable: the arms stay armed, so a `loop { switch s.wait() { .. } }` costs one setup.
@no_const
pub struct Selector {
    arms: [Arm; MAX_ARMS],
    order: [usize; MAX_ARMS], // arm indices sorted by lock address -- the deadlock-free lock-all order
    n: usize,
    woken: i32, // the arm a notify named as the waker, or -1
    rng: u64,
    winner: i64, // the arm the last `sugar_wait*` settled on, or -1; only the `select` keyword uses it
    cursor: usize, // how many arms `sugar_won` has been asked about since that wait
}

// A never-ready predicate, so an empty `Arm` slot holds a callable rather than a null function pointer.
const fn no_arm(_p: *const void) bool {
    return false;
}

// The type-erasing trampoline, one instantiation per selectable type, reached through `Arm.ready`. An arm
// stores its endpoint as `*const void`, so this is where the type comes back.
fn iface_ready<S: sync::Selectable>(p: *const void) bool {
    let s = p as *const S;
    // `arm_ready` and `lock_all` are the only callers, and both hold this arm's lock across the call.
    return unsafe s.select_ready();
}

// The park hand-off: the worker runs it once the selector's context is saved, which is what stops a notify
// from resuming a coroutine that is still switching out.
fn commit_unlock_all(p: *mut void) {
    let s = p as *mut Selector;
    s.unlock_all();
}

extend Selector {
    /// An empty selector.
    pub fn new() Selector {
        let empty = Arm {
            obj: null,
            ready: no_arm,
            raw: null,
            cv: null,
            w: sync::Waiter { co: null, token: 0, arm: 0, next: null, claim: null },
        };
        return Selector {
            arms: [empty; MAX_ARMS],
            order: [0usize; MAX_ARMS],
            n: 0,
            woken: -1,
            // Seeded per selector: the pick among simultaneously-ready arms must not be the same sequence
            // in every task.
            rng: platform::now_ns() ^ runtime::current_id() << 17 | 1,
            winner: -1,
            cursor: 0,
        };
    }
    /// Wait on ANY `Selectable` -- a channel endpoint, or a type of your own that conforms. Returns the arm
    /// index a `Ready` result will carry. This is the whole extension point: `select` knows nothing about
    /// channels beyond this interface.
    pub fn arm<S: sync::Selectable>(self: &mut Selector, s: &S) usize {
        // Recorded once and reused for the life of the arm, which is what `Selectable` requires of them.
        return self.push(s, iface_ready::<S>, unsafe s.select_lock(), unsafe s.select_queue());
    }
    /// Wait for `rx` to have a value (or to be closed and drained, which `try_recv` reports as `None`).
    /// Returns the arm index a `Ready` result will carry.
    pub fn arm_recv<T>(self: &mut Selector, rx: &channel::Receiver<T>) usize {
        return self.arm(rx);
    }
    /// Wait for `tx` to have room (or to be closed, which `try_send` reports by handing the value back).
    /// Returns the arm index a `Ready` result will carry.
    pub fn arm_send<T>(self: &mut Selector, tx: &channel::Sender<T>) usize {
        return self.arm(tx);
    }
    /// How many operations are armed.
    pub fn len(self: &Selector) usize {
        return self.n;
    }
    /// Forget every armed operation, so the selector can be rebuilt for a different wait.
    pub fn clear(self: &mut Selector) {
        self.n = 0;
        self.woken = -1;
    }
    /// Wait until one armed operation can proceed. Parks the calling coroutine; blocks any other thread.
    pub fn wait(self: &mut Selector) Selected {
        return self.wait_deadline(0);
    }
    /// `wait`, giving up after `d`.
    pub fn wait_timeout(self: &mut Selector, d: time::Duration) Selected {
        return self.wait_deadline(time::deadline_in(d));
    }
    /// `wait` with an explicit monotonic `deadline` (a `time::deadline_in` value; `0` waits forever), so one
    /// deadline can bound a whole sequence of waits.
    pub fn wait_deadline(self: &mut Selector, deadline: u64) Selected {
        loop {
            let hit = self.ready_now();
            switch hit {
                Ready(i) => {
                    return Selected::Ready(i);
                },
                TimedOut => {},
            };
            if deadline != 0 && time::remaining_ns(deadline) == 0 {
                return Selected::TimedOut;
            }
            self.block(deadline);
        }
    }
    /// Check the armed operations once, without waiting.
    pub fn poll(self: &mut Selector) Selected {
        return self.ready_now();
    }
    // One pass over the arms: the arm a notify named (first-notify-wins, for a wait that parked), else a
    // uniform pick among everything ready (fair, for a wait that never had to park).
    fn ready_now(self: &mut Selector) Selected {
        let hint = self.woken;
        self.woken = -1;
        if hint >= 0 && hint < self.n as i32 && self.arm_ready(hint as usize) {
            return Selected::Ready(hint as usize);
        }
        let mut ready: [usize; MAX_ARMS] = [0usize; MAX_ARMS];
        let mut c: usize = 0;
        for i in 0..self.n {
            if self.arm_ready(i) {
                unsafe ready[c] = i;
                c = c + 1;
            }
        }
        if c == 0 {
            return Selected::TimedOut;
        }
        let pick = (self.next_rand() % c as u64) as usize;
        return Selected::Ready(
            unsafe {
                ready[pick];
            },
        );
    }
    // Ask one arm whether it would proceed, under its channel's lock. Every index here is below `n`, which
    // `push` keeps at or below `MAX_ARMS` -- the unsafety is the missing bounds check, nothing more.
    fn arm_ready(self: &Selector, i: usize) bool {
        let f = unsafe self.arms[i].ready;
        let raw = unsafe self.arms[i].raw;
        unsafe sync::raw_mutex_lock(raw); // `select_ready` is called WITH the lock held, per `Selectable`
        let r = f(unsafe self.arms[i].obj);
        unsafe sync::raw_mutex_unlock(raw);
        return r;
    }
    // Park until some arm moves. Takes every channel lock, re-checks readiness under them (a value that
    // arrived since `ready_now` must not be missed -- with no node queued yet, its notify would be lost),
    // queues one node per arm under a single wake token, and parks; the hand-off releases the locks.
    fn block(self: &mut Selector, deadline: u64) {
        let co = runtime::current();
        if co == null || self.n == 0 {
            // A plain thread has no wake token to share across queues, so it re-checks on a timer instead.
            // With no arms at all there is nothing to be woken BY, and an unbounded wait would never end.
            if self.n == 0 && deadline == 0 {
                panic("select: waiting on no arms with no deadline");
            }
            let mut ns = POLL_SLICE_NS;
            if deadline != 0 {
                let left = time::remaining_ns(deadline) as i64;
                if left < ns {
                    ns = left;
                }
            }
            runtime::sleep_ns(ns);
            return;
        }
        self.lock_all();
        for i in 0..self.n {
            let f = unsafe self.arms[i].ready;
            if f(unsafe self.arms[i].obj) {
                self.unlock_all();
                return;
            }
        }
        self.woken = -1;
        let claim = &mut self.woken;
        // AFTER lock_all: a contended `raw_mutex_lock` parks, and that park would take a token of its own,
        // leaving ours stale and unwakeable.
        let token = runtime::park_begin(co);
        for i in 0..self.n {
            unsafe self.arms[i].w = sync::Waiter { co: co, token: token, arm: i as i32, next: null, claim: claim };
            let cv = unsafe self.arms[i].cv;
            let wp = &mut unsafe self.arms[i].w;
            unsafe cv.register(wp); // every arm's lock is held: see `lock_all`
        }
        runtime::park_timed(token, deadline, commit_unlock_all, self);
        if deadline != 0 {
            runtime::cancel_timer(co); // drop the timer if a notify got here first
        }
        // Our nodes outlive the wake: a notify pops only the one it used, and a deadline pops none.
        for i in 0..self.n {
            let cv = unsafe self.arms[i].cv;
            let raw = unsafe self.arms[i].raw;
            unsafe sync::raw_mutex_lock(raw);
            let wp = &mut unsafe self.arms[i].w;
            unsafe cv.unregister(wp); // unlinked before this frame dies, which is what the node's owner owes
            unsafe sync::raw_mutex_unlock(raw);
        }
    }
    // Take every armed channel's lock, in address order. Two selectors sharing channels therefore take the
    // shared locks in the same order and cannot deadlock; one channel armed twice is locked once.
    fn lock_all(self: &mut Selector) {
        for i in 0..self.n {
            let mut j = i;
            while j > 0 && (unsafe self.arms[self.order[j - 1]].raw) as usize > (unsafe self.arms[i].raw) as usize {
                unsafe self.order[j] = unsafe self.order[j - 1];
                j = j - 1;
            }
            unsafe self.order[j] = i;
        }
        for k in 0..self.n {
            let i = unsafe self.order[k];
            if k > 0 && unsafe self.arms[i].raw == unsafe self.arms[self.order[k - 1]].raw {
                continue;
            }
            unsafe sync::raw_mutex_lock(unsafe self.arms[i].raw);
        }
    }
    // Release every lock `lock_all` took, skipping the duplicates it skipped. `pub` for linkage: the park
    // hand-off reaches it through a raw pointer.
    pub fn unlock_all(self: &Selector) {
        for k in 0..self.n {
            let i = unsafe self.order[k];
            if k > 0 && unsafe self.arms[i].raw == unsafe self.arms[self.order[k - 1]].raw {
                continue; // one channel armed twice (send and recv): one lock, taken once
            }
            unsafe sync::raw_mutex_unlock(unsafe self.arms[i].raw);
        }
    }
    // Record one type-erased arm. `pub` for linkage: `arm_recv`/`arm_send` are generic, so they are
    // monomorphized in the caller's module and call this from there. Not user-facing.
    pub fn push(
        self: &mut Selector,
        obj: *const void,
        ready: fn(*const void) bool,
        raw: *mut sync::RawMutex,
        cv: *const sync::Condvar,
    ) usize {
        if self.n == MAX_ARMS {
            panic("select: too many arms");
        }
        let i = self.n;
        unsafe self.arms[i].obj = obj;
        unsafe self.arms[i].ready = ready;
        unsafe self.arms[i].raw = raw;
        unsafe self.arms[i].cv = cv;
        self.n = i + 1;
        return i;
    }
    // Record the arm a `select` statement's wait settled on, and rewind the cursor `take_turn` walks.
    // `pub` for linkage (the sugar shims below are what the desugar calls); not user-facing.
    pub fn settle(self: &mut Selector, hit: Selected) {
        self.winner = (switch hit {
            Ready(i) => i as i64,
            TimedOut => -1i64,
        });
        self.cursor = 0;
    }
    // Is the next arm in registration order the one that won? `pub` for linkage; not user-facing.
    pub fn take_turn(self: &mut Selector) bool {
        let hit = self.cursor as i64 == self.winner;
        self.cursor = self.cursor + 1;
        return hit;
    }
    fn next_rand(self: &mut Selector) u64 {
        let mut r = self.rng; // xorshift64
        r = r ^ r << 13;
        r = r ^ r >> 7;
        r = r ^ r << 17;
        self.rng = r;
        return r;
    }
}

// -----------------------------------------------------------------------------------------------------
// The `select` keyword lowers to these -- see src/desugar. Free functions, not methods: the desugar pass
// runs after name resolution and can only seed the resolution of a call it builds itself, so every piece
// the lowered code needs must be reachable as a plain function. Nothing else should call them.
// -----------------------------------------------------------------------------------------------------

/// A selector for one `select` statement.
pub fn sugar_new() Selector {
    return Selector::new();
}

/// Arm a receive, discarding the index: the keyword identifies arms by position, not by index.
pub fn sugar_arm_recv<T>(sel: &mut Selector, rx: &channel::Receiver<T>) {
    let _ = sel.arm_recv(rx);
}

/// Arm a send.
pub fn sugar_arm_send<T>(sel: &mut Selector, tx: &channel::Sender<T>) {
    let _ = sel.arm_send(tx);
}

/// Wait for an arm, then remember which one won so the lowered if-chain can find it.
pub fn sugar_wait(sel: &mut Selector) {
    let hit = sel.wait();
    sel.settle(hit);
}

/// `sugar_wait`, giving up after `d` (the `timeout(d)` arm).
pub fn sugar_wait_timeout(sel: &mut Selector, d: time::Duration) {
    let hit = sel.wait_timeout(d);
    sel.settle(hit);
}

/// Check the arms without waiting (the `default` arm).
pub fn sugar_poll(sel: &mut Selector) {
    let hit = sel.poll();
    sel.settle(hit);
}

/// Did the NEXT arm in registration order win? Called once per arm, in order, so the lowered code needs no
/// arm indices -- a plain if/else chain over these calls picks exactly one arm.
pub fn sugar_won(sel: &mut Selector) bool {
    return sel.take_turn();
}

/// The receive an arm performs once it has won. It cannot block: the arm was ready, and if another consumer
/// took the value in between, this reports `None` rather than waiting for a value that may never come.
pub fn sugar_recv<T>(rx: &channel::Receiver<T>) Option<T> {
    return rx.try_recv();
}

/// The send an arm performs once it has won. As with `sugar_recv` it never blocks; a lost race hands the
/// value back in `Rejected`, which is why binding a send arm (`r = ch.send(v)`) is how you keep it.
pub fn sugar_send<T>(tx: &channel::Sender<T>, value: T) channel::SendResult<T> {
    return tx.try_send(value);
}
