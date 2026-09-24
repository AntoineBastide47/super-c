// A multi-producer / multi-consumer channel: a ring buffer guarded by a mutex, with waiting `send`/`recv`,
// deadline variants, and non-blocking `try_*`. Import with `import std::parallel::channel;`.
//
// A `Channel<T>` vends cloneable `Sender<T>` and `Receiver<T>` handles; move them into tasks (`launch`) or
// threads. A `bounded(n)` channel makes `send` wait while the buffer is full: that backpressure is the
// point: while an `unbounded()` one grows instead and never makes a sender wait. `recv` waits while the
// buffer is empty. The channel closes: `recv` then drains the buffer and returns `None`, and further
// `send`s hand the value back: when its last `Sender` is dropped, when its last `Receiver` is dropped, or
// on an explicit `close()`. `T` must be `Send`.
//
// Every wait is task-aware, because it goes through `sync::Condvar`: a coroutine parks and its worker moves
// on to another task, so a program may have far more blocked senders and receivers than worker threads.
//
// A channel is ONE allocation: the handle count, the lock, the state, both wait queues and, for a bounded
// channel, the ring itself share a block that lives until the last handle drops, so the header and the
// first slots share cache lines and construction costs one `malloc`. An unbounded channel starts on the
// same inline ring and moves to a heap ring when it outgrows it. A zero-sized payload has no ring at all.
// Every wait node lives in the waiting task's frame, so an operation allocates nothing.

import atomic;
import std::parallel::sync as sync;
import std::parallel::atomics as atomics;
import std::parallel::time as time;
import std::parallel::runtime as runtime;

/// The outcome of a `send`: `Sent`, or `Rejected(value)` when the channel is closed or has no receivers;
/// the value is handed back so ownership is never dropped on the floor (and is auto-freed if discarded).
pub enum SendResult<T> {
    Sent,
    Rejected(T),
}

// The slot count an unbounded channel starts with, on its inline ring.
const UNBOUNDED_START: usize = 8;

// The mutex-guarded state: a ring buffer of `cap` slots plus the live-handle counts and the closed flag.
@no_const
struct ChannelState<T> {
    pub slots: *mut T,
    pub cap: usize,
    pub head: usize, // index of the oldest buffered item
    pub count: usize, // number of buffered items
    pub senders: i64,
    pub receivers: i64,
    pub closed: bool,
    pub unbounded: bool, // grow the ring instead of making a sender wait
    pub heap_ring: bool, // `slots` is its own heap block (an unbounded channel that outgrew the inline ring)
}

extend<T> ChannelState<T> {
    /// Double the ring and rewind it to index 0. Only for an unbounded channel, only when full, and only
    /// under the state lock. `pub` for linkage (the generic methods that call it are monomorphized in the
    /// caller's module).
    pub fn grow(self: &mut ChannelState<T>) {
        let ncap = self.cap * 2;
        if sizeof(T) == 0 {
            self.head = 0;
            // Zero-sized items buffer by count alone.
            self.cap = ncap;
            return;
        }
        self.resize(ncap);
    }
    /// Move the buffered items to a fresh heap ring of `ncap` slots, rewound to index 0. Under the state
    /// lock, with `count <= ncap`. `pub` for linkage, like `grow`.
    pub fn resize(self: &mut ChannelState<T>, ncap: usize) {
        let mut g = Global {};
        let ns = (unsafe g.alloc(ncap * sizeof(T), alignof(T))) as *mut T;
        for i in 0..self.count {
            let idx = (self.head + i) % self.cap;
            unsafe ns[i] = unsafe {
                self.slots[idx];
            };
        }
        if self.heap_ring {
            unsafe g.dealloc(self.slots, self.cap * sizeof(T), alignof(T));
        }
        self.slots = ns;
        self.head = 0;
        self.cap = ncap;
        self.heap_ring = true;
    }
    /// Append `value` under the lock; the caller checked there is room (or that the ring may grow). `pub`
    /// for linkage, like `grow`.
    pub fn push(self: &mut ChannelState<T>, value: T) {
        if self.count == self.cap {
            // Unbounded only: a bounded channel waited for room instead.
            self.grow();
        }
        let idx = (self.head + self.count) % self.cap;
        unsafe self.slots[idx] = value;
        self.count = self.count + 1;
    }
    /// Take the oldest item under the lock; the caller checked there is one. A heap ring that a burst grew
    /// is halved once three quarters of it are free, as the timer heap is: the hysteresis keeps a push and
    /// a pop at the boundary from resizing every time, and the copy is amortized over the pops that emptied
    /// it. The smallest heap ring is twice the inline one. `pub` for linkage.
    pub fn pop(self: &mut ChannelState<T>) T {
        let v = unsafe {
            self.slots[self.head];
        };
        self.head = (self.head + 1) % self.cap;
        self.count = self.count - 1;
        if self.heap_ring && self.cap > 2 * UNBOUNDED_START && self.count < self.cap / 4 {
            self.resize(self.cap / 2);
        }
        return v;
    }
}

extend<T> ChannelState<T> as Free {
    pub fn free(self: &mut ChannelState<T>) {
        // Deep-free any items still buffered (no-op if T isn't Free), then release a heap ring. The inline
        // ring goes with the block.
        for i in 0..self.count {
            let idx = (self.head + i) % self.cap;
            let vp = (&mut unsafe self.slots[idx]) as *mut T;
            vp.free();
        }
        if self.heap_ring {
            let mut g = Global {};
            unsafe g.dealloc(self.slots, self.cap * sizeof(T), alignof(T));
        }
        self.slots = null;
    }
}

// The shared block: the handle count, one mutex over the state, a condvar for "space freed" and one for
// "item ready", and (for a payload with a size) the inline ring right behind it. Freed by the handle that
// drops the count to zero; freeing the mutex frees the state, and with it the buffered payloads.
@no_const
struct ChannelInner<T> {
    pub strong: usize, // atomic: live handles, the `Channel` value included
    pub state: sync::Mutex<ChannelState<T>>,
    pub not_full: sync::Condvar,
    pub not_empty: sync::Condvar,
    pub bytes: usize, // the whole block, for its release
}

/// A bounded MPMC channel. Create it with `Channel::<T>::bounded(n)`, then hand out `sender()` / `receiver()`
/// handles. The `Channel` value is only a factory: dropping it does not close the channel (its handles do).
@no_const
pub struct Channel<T> {
    pub inner: *mut ChannelInner<T>, // `pub` for linkage (generic methods build handles in the caller's module)
}

/// A sending endpoint. Cloneable (each clone is another producer); the channel closes for receiving once the
/// last one is dropped.
@no_const
pub struct Sender<T> {
    pub inner: *mut ChannelInner<T>, // `pub` for linkage
}

/// A receiving endpoint. Cloneable (each clone is another consumer); the channel closes for sending once the
/// last one is dropped.
@no_const
pub struct Receiver<T> {
    pub inner: *mut ChannelInner<T>, // `pub` for linkage
}

// The endpoints move a `Send` payload between threads, so they are Send + Sync when `T` is Send. Explicit
// (unsafe) assertions: the raw block pointer would otherwise disqualify them structurally; the mutex makes
// every access race-free and the atomic count makes the sharing itself race-free.
unsafe extend<T: Send> Channel<T> as Send {}

unsafe extend<T: Send> Channel<T> as Sync {}

unsafe extend<T: Send> Sender<T> as Send {}

unsafe extend<T: Send> Sender<T> as Sync {}

unsafe extend<T: Send> Receiver<T> as Send {}

unsafe extend<T: Send> Receiver<T> as Sync {}

// Where the inline ring starts: the header rounded up to the payload's alignment.
const fn ring_offset<T>() usize {
    let a = alignof(T);
    return (sizeof(ChannelInner<T>) + a - 1) / a * a;
}

// The block's alignment: the header's or the payload's, whichever is larger.
const fn block_align<T>() usize {
    if alignof(T) > alignof(ChannelInner<T>) {
        return alignof(T);
    }
    return alignof(ChannelInner<T>);
}

/// Allocate and initialise a block with a `cap`-slot inline ring and a count of one. `pub` for linkage.
pub fn new_block<T>(cap: usize, unbounded: bool) *mut ChannelInner<T> {
    let mut bytes = sizeof(ChannelInner<T>);
    if sizeof(T) != 0 {
        bytes = ring_offset::<T>() + cap * sizeof(T);
    }
    let mut g = Global {};
    let p = (unsafe g.alloc(bytes, block_align::<T>())) as *mut ChannelInner<T>;
    let mut slots = zst_dangling::<T>();
    if sizeof(T) != 0 {
        slots = (unsafe (p as *mut u8 + ring_offset::<T>())) as *mut T;
    }
    let st = ChannelState::<T> {
        slots: slots,
        cap: cap,
        head: 0,
        count: 0,
        senders: 0,
        receivers: 0,
        closed: false,
        unbounded: unbounded,
        heap_ring: false,
    };
    unsafe p[0] = ChannelInner::<T> {
        strong: 1,
        state: sync::Mutex::<ChannelState<T>>::new(st),
        not_full: sync::Condvar::new(),
        not_empty: sync::Condvar::new(),
        bytes: bytes,
    };
    return p;
}

/// Another handle to the block: one relaxed increment, as for an `Arc`. `pub` for linkage.
pub fn retain<T>(p: *mut ChannelInner<T>) *mut ChannelInner<T> {
    let _ = unsafe atomic::add_usize(&mut (*p).strong, 1, atomics::MemoryOrder::Relaxed as i32);
    return p;
}

/// Drop one handle; the one that observes the count fall to zero frees the state (buffered payloads and a
/// heap ring included) and the block. AcqRel, as for an `Arc`: the decrement chain orders every handle's
/// last touch before the free. `pub` for linkage.
pub fn release<T>(p: *mut ChannelInner<T>) {
    let prev = unsafe atomic::sub_usize(&mut (*p).strong, 1, atomics::MemoryOrder::AcqRel as i32);
    if prev != 1 {
        return;
    }
    let bytes = unsafe (*p).bytes;
    // Through a raw pointer, like Box::free: freeing the place directly would move out of a dereference.
    let sp = (&mut unsafe (*p).state) as *mut sync::Mutex<ChannelState<T>>;
    unsafe (*sp).free();
    let mut g = Global {};
    unsafe g.dealloc(p, bytes, block_align::<T>());
}

extend<T> Channel<T> {
    /// A new channel buffering up to `capacity` items (at least one). A `send` into a full buffer waits.
    pub fn bounded(capacity: usize) Channel<T> {
        let cap = if capacity == 0 {
            1usize;
        } else {
            capacity;
        };
        return Channel::<T> { inner: new_block::<T>(cap, false) };
    }
    /// A new channel with no capacity limit: the ring grows as needed, so `send` never waits. Use it only
    /// when the producers are known to outpace the consumers by a bounded amount: `bounded` is what keeps
    /// a runaway producer from exhausting memory.
    pub fn unbounded() Channel<T> {
        return Channel::<T> { inner: new_block::<T>(UNBOUNDED_START, true) };
    }
    /// The shared block. `pub` for linkage; not user-facing.
    pub fn get(self: &Channel<T>) &ChannelInner<T> {
        return &unsafe self.inner[0];
    }
    /// A new sending handle.
    pub fn sender(self: &Channel<T>) Sender<T> {
        let inner = self.get();
        let mut g = inner.state.lock();
        let s = g.get_mut();
        s.senders = s.senders + 1;
        return Sender::<T> { inner: retain(self.inner) };
    }
    /// A new receiving handle.
    pub fn receiver(self: &Channel<T>) Receiver<T> {
        let inner = self.get();
        let mut g = inner.state.lock();
        let s = g.get_mut();
        s.receivers = s.receivers + 1;
        return Receiver::<T> { inner: retain(self.inner) };
    }
}

extend<T> Channel<T> as Free {
    pub fn free(self: &mut Channel<T>) {
        release(self.inner);
    }
}

extend<T> Sender<T> {
    /// The shared block. `pub` for linkage; not user-facing.
    pub fn get(self: &Sender<T>) &ChannelInner<T> {
        return &unsafe self.inner[0];
    }
    /// Another producer handle for the same channel.
    pub fn clone(self: &Sender<T>) Sender<T> {
        let inner = self.get();
        let mut g = inner.state.lock();
        let s = g.get_mut();
        s.senders = s.senders + 1;
        return Sender::<T> { inner: retain(self.inner) };
    }
    /// Wait until there is room, then send `value`. Returns `Rejected(value)` if the channel is closed or has
    /// no receivers left (the value is handed back so the caller keeps ownership).
    pub fn send(self: &Sender<T>, value: T) SendResult<T> {
        return self.send_deadline(value, 0);
    }
    /// `send`, giving up after `d`. A timeout also returns `Rejected(value)`, so the value is never lost.
    pub fn send_timeout(self: &Sender<T>, value: T, d: time::Duration) SendResult<T> {
        return self.send_deadline(value, time::deadline_in(d));
    }
    /// `send` with an explicit monotonic `deadline` (a `time::deadline_in` value; `0` waits forever). The
    /// body of `send`/`send_timeout`; also `pub` because a deadline computed once and reused across several
    /// operations is the honest way to bound a whole sequence.
    pub fn send_deadline(self: &Sender<T>, value: T, deadline: u64) SendResult<T> {
        let inner = self.get();
        let mut g = inner.state.lock();
        loop {
            let mut ready = false;
            {
                let s = g.get();
                if s.closed || s.receivers == 0 {
                    return SendResult::<T>::Rejected(value);
                }
                ready = s.count < s.cap || s.unbounded;
            }
            if ready {
                break;
            }
            if runtime::tracing() {
                runtime::trace("channel: send blocks (full)", runtime::current_id());
            }
            if deadline != 0 && time::remaining_ns(deadline) == 0 {
                return SendResult::<T>::Rejected(value);
            }
            let r = unsafe inner.not_full.wait_raw(g.lock_handle(), deadline, true, runtime::WK_CHANNEL_SEND);
            if r == runtime::WR_CANCEL || r == runtime::WR_SHUTDOWN {
                // Cancelled: the send wait is removed and the unsent payload is handed back, so the
                // caller's cancellation cleanup frees it exactly once.
                let _ = runtime::cancel_after_wait(true);
                return SendResult::<T>::Rejected(value);
            }
        }
        g.get_mut().push(value);
        inner.not_empty.notify_one();
        return SendResult::<T>::Sent;
    }
    /// Send without waiting. Returns `Rejected(value)` if the buffer is full or the channel is closed.
    pub fn try_send(self: &Sender<T>, value: T) SendResult<T> {
        let inner = self.get();
        let mut g = inner.state.lock();
        {
            let s = g.get();
            if s.closed || s.receivers == 0 || s.count >= s.cap && !s.unbounded {
                return SendResult::<T>::Rejected(value);
            }
        }
        g.get_mut().push(value);
        inner.not_empty.notify_one();
        return SendResult::<T>::Sent;
    }
    /// Send every item in `items`, in order, taking the lock once per run of free slots instead of once per
    /// item; returns how many were sent. `items` is left EMPTY when they all went; when the channel closes or
    /// loses its last receiver part-way, the ones not sent stay in it, in order, so ownership is never lost.
    /// A cancelled wait for room likewise leaves the remainder in `items`: the run before it was delivered.
    ///
    /// A `send` costs a lock, an unlock and a wake regardless of how big the payload is, so a producer that
    /// already has several items in hand pays that three times over for nothing. Filling the ring under one
    /// acquisition is the entire point of this method; with a batch of 64 it is what a single `send` costs.
    /// A run of `n` items wakes at most `n` receivers, never every one queued.
    pub fn send_batch(self: &Sender<T>, items: &mut Vector<T>) usize {
        // Reversed, so the next item to send is a `pop` (O(1)) rather than a front removal that shifts
        // everything after it. Reversed back before returning, so a caller left holding a partial batch finds
        // its remainder in the order it passed in.
        items.reverse();
        let inner = self.get();
        let mut sent: usize = 0;
        let mut open = true;
        let mut cancelled = false;
        while open && !cancelled && !items.is_empty() {
            let mut g = inner.state.lock();
            loop {
                let mut ready = false;
                {
                    let s = g.get();
                    open = !s.closed && s.receivers != 0;
                    ready = s.count < s.cap || s.unbounded;
                }
                if ready || !open {
                    break;
                }
                if runtime::tracing() {
                    runtime::trace("channel: send_batch blocks (full)", runtime::current_id());
                }
                let r = unsafe inner.not_full.wait_raw(g.lock_handle(), 0, true, runtime::WK_CHANNEL_SEND);
                if r == runtime::WR_CANCEL || r == runtime::WR_SHUTDOWN {
                    let _ = runtime::cancel_after_wait(true);
                    // The unsent remainder stays in `items`, in order.
                    cancelled = true;
                    break;
                }
            }
            if open && !cancelled {
                let sm = g.get_mut();
                let mut n: usize = 0;
                while !items.is_empty() && (sm.count < sm.cap || sm.unbounded) {
                    switch items.pop() {
                        Some(v) => {
                            sm.push(v);
                            n = n + 1;
                        },
                        None => {},
                    };
                }
                sent = sent + n;
                // Each item delivered can admit one receiver.
                inner.not_empty.notify_some(n);
            }
        }
        items.reverse();
        return sent;
    }
    /// Close the channel: no further sends succeed; buffered items stay readable until drained.
    pub fn close(self: &Sender<T>) {
        let inner = self.get();
        // Notify UNDER the lock: the dual-mode condvar's wait queue is guarded by this mutex.
        let mut g = inner.state.lock();
        let s = g.get_mut();
        s.closed = true;
        inner.not_empty.notify_all();
        inner.not_full.notify_all();
    }
}

extend<T> Sender<T> as Free {
    pub fn free(self: &mut Sender<T>) {
        let inner = self.get();
        {
            let mut g = inner.state.lock();
            let s = g.get_mut();
            s.senders = s.senders - 1;
            if s.senders == 0 {
                // No producers left: wake blocked receivers (under the lock; it guards the wait queue) so
                // they observe the closed-and-draining channel.
                inner.not_empty.notify_all();
            }
        }
        release(self.inner);
    }
}

extend<T> Receiver<T> {
    /// The shared block. `pub` for linkage; not user-facing.
    pub fn get(self: &Receiver<T>) &ChannelInner<T> {
        return &unsafe self.inner[0];
    }
    /// Another consumer handle for the same channel.
    pub fn clone(self: &Receiver<T>) Receiver<T> {
        let inner = self.get();
        let mut g = inner.state.lock();
        let s = g.get_mut();
        s.receivers = s.receivers + 1;
        return Receiver::<T> { inner: retain(self.inner) };
    }
    /// Wait for an item and take it, or return `None` once the channel is closed (or has no senders left)
    /// and the buffer is drained.
    pub fn recv(self: &Receiver<T>) Option<T> {
        return self.recv_deadline(0);
    }
    /// `recv`, giving up after `d`. `None` means "timed out", "closed and drained", or both.
    pub fn recv_timeout(self: &Receiver<T>, d: time::Duration) Option<T> {
        return self.recv_deadline(time::deadline_in(d));
    }
    /// `recv` with an explicit monotonic `deadline` (a `time::deadline_in` value; `0` waits forever). The
    /// body of `recv`/`recv_timeout`; also `pub` so one deadline can bound a whole sequence of operations.
    pub fn recv_deadline(self: &Receiver<T>, deadline: u64) Option<T> {
        let inner = self.get();
        let mut g = inner.state.lock();
        loop {
            let mut ready = false;
            let mut done = false;
            {
                let s = g.get();
                ready = s.count > 0;
                done = !ready && (s.closed || s.senders == 0);
            }
            if ready {
                break;
            }
            if done {
                return Option::<T>::None;
            }
            if runtime::tracing() {
                runtime::trace("channel: recv blocks (empty)", runtime::current_id());
            }
            if deadline != 0 && time::remaining_ns(deadline) == 0 {
                return Option::<T>::None;
            }
            let r = unsafe inner.not_empty.wait_raw(g.lock_handle(), deadline, true, runtime::WK_CHANNEL_RECV);
            if r == runtime::WR_CANCEL || r == runtime::WR_SHUTDOWN {
                let _ = runtime::cancel_after_wait(true);
                // Cancelled: the receive wait is removed and no value is taken.
                return Option::<T>::None;
            }
        }
        let v = g.get_mut().pop();
        inner.not_full.notify_one();
        return Option::<T>::Some(v);
    }
    /// Take an item without blocking, or `None` if the buffer is empty (also `None` if closed and empty).
    pub fn try_recv(self: &Receiver<T>) Option<T> {
        let inner = self.get();
        let mut g = inner.state.lock();
        {
            let s = g.get();
            if s.count == 0 {
                return Option::<T>::None;
            }
        }
        let v = g.get_mut().pop();
        inner.not_full.notify_one();
        return Option::<T>::Some(v);
    }
    /// Take up to `max` buffered items in ONE lock acquisition, appending them to `out` in order; returns how
    /// many were taken. Waits like `recv` until at least one is there, and returns 0 once the channel is
    /// closed and drained (so a `while recv_batch(..) > 0` loop terminates). `max` of 0 takes nothing and
    /// never waits. A cancelled wait takes nothing and reports 0.
    ///
    /// The consumer half of `send_batch`, and the same argument: `recv` in a loop pays a lock, an unlock and
    /// a wake for every single item, while draining a run of them pays that once. Use it wherever the
    /// consumer can work on several items at a time; `recv` remains right for one-at-a-time hand-off. A run
    /// of `n` items wakes at most `n` senders, never every one queued.
    pub fn recv_batch(self: &Receiver<T>, out: &mut Vector<T>, max: usize) usize {
        if max == 0 {
            return 0;
        }
        let inner = self.get();
        let mut g = inner.state.lock();
        loop {
            let mut ready = false;
            let mut done = false;
            {
                let s = g.get();
                ready = s.count > 0;
                done = !ready && (s.closed || s.senders == 0);
            }
            if ready {
                break;
            }
            if done {
                return 0;
            }
            if runtime::tracing() {
                runtime::trace("channel: recv_batch blocks (empty)", runtime::current_id());
            }
            let r = unsafe inner.not_empty.wait_raw(g.lock_handle(), 0, true, runtime::WK_CHANNEL_RECV);
            if r == runtime::WR_CANCEL || r == runtime::WR_SHUTDOWN {
                let _ = runtime::cancel_after_wait(true);
                // Cancelled: nothing taken.
                return 0;
            }
        }
        let sm = g.get_mut();
        let n = if max < sm.count {
            max;
        } else {
            sm.count;
        };
        // One growth for the batch, while the lock is held for as few instructions as possible.
        out.reserve(n);
        for _i in 0..n {
            out.push(sm.pop());
        }
        // Each slot freed can admit one sender.
        inner.not_full.notify_some(n);
        return n;
    }
}

extend<T> Receiver<T> as Free {
    pub fn free(self: &mut Receiver<T>) {
        let inner = self.get();
        {
            let mut g = inner.state.lock();
            let s = g.get_mut();
            s.receivers = s.receivers - 1;
            if s.receivers == 0 {
                // No consumers left: wake blocked senders (under the lock; it guards the wait queue) so
                // they observe the closed channel and give up.
                inner.not_full.notify_all();
            }
        }
        release(self.inner);
    }
}

// A channel endpoint is selectable: `select` waits on it through this and nothing else. Both halves point at
// the SAME state lock and differ only in the queue they sit on and what counts as ready.
extend<T> Sender<T> as sync::Selectable {
    /// The channel's state lock.
    pub unsafe fn select_lock(self: &Sender<T>) *mut sync::RawMutex {
        return unsafe self.get().state.raw_handle();
    }
    /// The queue a blocked `send` waits on.
    pub unsafe fn select_queue(self: &Sender<T>) *const sync::Condvar {
        return &self.get().not_full;
    }
    /// Would `try_send` do something other than wait? A closed or receiver-less channel counts as ready:
    /// `try_send` hands the value straight back rather than blocking.
    pub unsafe fn select_ready(self: &Sender<T>) bool {
        // The selector holds `select_lock` across this call: that is what makes the unlocked read sound.
        let s = unsafe self.get().state.locked_ref();
        return s.count < s.cap || s.unbounded || s.closed || s.receivers == 0;
    }
}

extend<T> Receiver<T> as sync::Selectable {
    /// The channel's state lock.
    pub unsafe fn select_lock(self: &Receiver<T>) *mut sync::RawMutex {
        return unsafe self.get().state.raw_handle();
    }
    /// The queue a blocked `recv` waits on.
    pub unsafe fn select_queue(self: &Receiver<T>) *const sync::Condvar {
        return &self.get().not_empty;
    }
    /// Would `try_recv` do something other than wait? A drained channel with no senders left counts as
    /// ready: `recv` returns `None` at once rather than blocking.
    pub unsafe fn select_ready(self: &Receiver<T>) bool {
        // See `Sender::select_ready`: the selector holds the lock across this call.
        let s = unsafe self.get().state.locked_ref();
        return s.count > 0 || s.closed || s.senders == 0;
    }
}

// Non-null, T-aligned, storage-free pointer for zero-sized element buffers (see core::dangling;
// duplicated privately so the prelude module needs no self-import).
const fn zst_dangling<T>() *mut T {
    return alignof(T) as *mut T;
}
