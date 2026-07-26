// A multi-producer / multi-consumer channel: a ring buffer guarded by a mutex, with waiting `send`/`recv`,
// deadline variants, and non-blocking `try_*`. Import with `import std::parallel::channel;`.
//
// A `Channel<T>` vends cloneable `Sender<T>` and `Receiver<T>` handles; move them into tasks (`launch`) or
// threads. A `bounded(n)` channel makes `send` wait while the buffer is full -- that backpressure is the
// point -- while an `unbounded()` one grows instead and never makes a sender wait. `recv` waits while the
// buffer is empty. The channel closes -- `recv` then drains the buffer and returns `None`, and further
// `send`s hand the value back -- when its last `Sender` is dropped, when its last `Receiver` is dropped, or
// on an explicit `close()`. `T` must be `Send`.
//
// Every wait is task-aware, because it goes through `sync::Condvar`: a coroutine parks and its worker moves
// on to another task, so a program may have far more blocked senders and receivers than worker threads.

import std::parallel::sync as sync;
import std::parallel::arc as arc;
import std::parallel::time as time;
import std::parallel::runtime as runtime;

/// The outcome of a `send`: `Sent`, or `Rejected(value)` when the channel is closed or has no receivers --
/// the value is handed back so ownership is never dropped on the floor (and is auto-freed if discarded).
pub enum SendResult<T> {
    Sent,
    Rejected(T),
}

// The mutex-guarded state: a ring buffer of `cap` slots plus the live-handle counts and the closed flag.
struct ChannelState<T> {
    pub slots: *mut T,
    pub cap: usize,
    pub head: usize, // index of the oldest buffered item
    pub count: usize, // number of buffered items
    pub senders: i64,
    pub receivers: i64,
    pub closed: bool,
    pub unbounded: bool, // grow the ring instead of making a sender wait
}

extend<T> ChannelState<T> {
    // Double the ring and rewind it to index 0. Only for an unbounded channel, only when full, and only
    // under the state lock. `pub` for linkage (the generic methods that call it are monomorphized in the
    // caller's module).
    pub fn grow(self: &mut ChannelState<T>) {
        let ncap = self.cap * 2;
        let mut g = Global {};
        let ns = g.alloc(ncap * sizeof(T), alignof(T)) as *mut T;
        for i in 0..self.count {
            let idx = (self.head + i) % self.cap;
            unsafe ns[i] = unsafe {
                self.slots[idx];
            };
        }
        g.dealloc(self.slots, self.cap * sizeof(T), alignof(T));
        self.slots = ns;
        self.head = 0;
        self.cap = ncap;
    }
}

extend<T> ChannelState<T> as Free {
    pub fn free(self: &mut ChannelState<T>) {
        // Deep-free any items still buffered (no-op if T isn't Free), then release the slot array.
        for i in 0..self.count {
            let idx = (self.head + i) % self.cap;
            let vp = (&mut unsafe self.slots[idx]) as *mut T;
            vp.free();
        }
        if self.slots != null {
            let mut g = Global {};
            g.dealloc(self.slots, self.cap * sizeof(T), alignof(T));
            self.slots = null;
        }
    }
}

// The shared channel: one mutex over the state, plus a condvar for "space freed" and one for "item ready".
// Holds no raw pointer itself, so its `Free` is auto-derived (freeing the mutex frees the state above).
struct ChannelInner<T> {
    pub state: sync::Mutex<ChannelState<T>>,
    pub not_full: sync::Condvar,
    pub not_empty: sync::Condvar,
}

/// A bounded MPMC channel. Create it with `Channel::<T>::bounded(n)`, then hand out `sender()` / `receiver()`
/// handles. The `Channel` value is only a factory: dropping it does not close the channel (its handles do).
pub struct Channel<T> {
    pub inner: arc::Arc<ChannelInner<T>>,
}

/// A sending endpoint. Cloneable (each clone is another producer); the channel closes for receiving once the
/// last one is dropped.
pub struct Sender<T> {
    pub inner: arc::Arc<ChannelInner<T>>,
}

/// A receiving endpoint. Cloneable (each clone is another consumer); the channel closes for sending once the
/// last one is dropped.
pub struct Receiver<T> {
    pub inner: arc::Arc<ChannelInner<T>>,
}

// The endpoints move a `Send` payload between threads, so they are Send + Sync when `T` is Send. Explicit
// (unsafe) assertions -- the `Arc<ChannelInner>` holds a raw slot pointer that would otherwise disqualify
// them structurally; the mutex makes every access race-free.
extend<T: Send> Channel<T> as Send {}

extend<T: Send> Channel<T> as Sync {}

extend<T: Send> Sender<T> as Send {}

extend<T: Send> Sender<T> as Sync {}

extend<T: Send> Receiver<T> as Send {}

extend<T: Send> Receiver<T> as Sync {}

extend<T> Channel<T> {
    /// A new channel buffering up to `capacity` items (at least one). A `send` into a full buffer waits.
    pub fn bounded(capacity: usize) Channel<T> {
        let cap = if capacity == 0 {
            1usize;
        } else {
            capacity;
        };
        let mut g = Global {};
        let slots = g.alloc(cap * sizeof(T), alignof(T)) as *mut T;
        let st = ChannelState::<T> {
            slots: slots,
            cap: cap,
            head: 0,
            count: 0,
            senders: 0,
            receivers: 0,
            closed: false,
            unbounded: false,
        };
        let inner = ChannelInner::<T> {
            state: sync::Mutex::<ChannelState<T>>::new(st),
            not_full: sync::Condvar::new(),
            not_empty: sync::Condvar::new(),
        };
        return Channel::<T> { inner: arc::Arc::<ChannelInner<T>>::new(inner) };
    }
    /// A new channel with no capacity limit: the ring grows as needed, so `send` never waits. Use it only
    /// when the producers are known to outpace the consumers by a bounded amount -- `bounded` is what keeps
    /// a runaway producer from exhausting memory.
    pub fn unbounded() Channel<T> {
        let ch = Channel::<T>::bounded(8);
        {
            let inner = ch.inner.get();
            let mut g = inner.state.lock();
            let s = g.get_mut();
            s.unbounded = true;
        }
        return ch;
    }
    /// A new sending handle.
    pub fn sender(self: &Channel<T>) Sender<T> {
        let inner = self.inner.get();
        let mut g = inner.state.lock();
        let s = g.get_mut();
        s.senders = s.senders + 1;
        return Sender::<T> { inner: self.inner.clone() };
    }
    /// A new receiving handle.
    pub fn receiver(self: &Channel<T>) Receiver<T> {
        let inner = self.inner.get();
        let mut g = inner.state.lock();
        let s = g.get_mut();
        s.receivers = s.receivers + 1;
        return Receiver::<T> { inner: self.inner.clone() };
    }
}

extend<T> Channel<T> as Free {
    pub fn free(self: &mut Channel<T>) {
        self.inner.free();
    }
}

extend<T> Sender<T> {
    /// Another producer handle for the same channel.
    pub fn clone(self: &Sender<T>) Sender<T> {
        let inner = self.inner.get();
        let mut g = inner.state.lock();
        let s = g.get_mut();
        s.senders = s.senders + 1;
        return Sender::<T> { inner: self.inner.clone() };
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
        let inner = self.inner.get();
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
            if deadline != 0 {
                if time::remaining_ns(deadline) == 0 {
                    return SendResult::<T>::Rejected(value);
                }
                inner.not_full.wait_until(&g, deadline);
            } else {
                inner.not_full.wait(&g);
            }
        }
        let sm = g.get_mut();
        if sm.count == sm.cap {
            sm.grow(); // unbounded only: the wait above is what a bounded channel does instead
        }
        let idx = (sm.head + sm.count) % sm.cap;
        unsafe sm.slots[idx] = value;
        sm.count = sm.count + 1;
        inner.not_empty.notify_one();
        return SendResult::<T>::Sent;
    }
    /// Send without waiting. Returns `Rejected(value)` if the buffer is full or the channel is closed.
    pub fn try_send(self: &Sender<T>, value: T) SendResult<T> {
        let inner = self.inner.get();
        let mut g = inner.state.lock();
        {
            let s = g.get();
            if s.closed || s.receivers == 0 || s.count >= s.cap && !s.unbounded {
                return SendResult::<T>::Rejected(value);
            }
        }
        let sm = g.get_mut();
        if sm.count == sm.cap {
            sm.grow();
        }
        let idx = (sm.head + sm.count) % sm.cap;
        unsafe sm.slots[idx] = value;
        sm.count = sm.count + 1;
        inner.not_empty.notify_one();
        return SendResult::<T>::Sent;
    }
    /// Close the channel: no further sends succeed; buffered items stay readable until drained.
    pub fn close(self: &Sender<T>) {
        let inner = self.inner.get();
        // notify UNDER the lock: the dual-mode condvar's wait queue is guarded by this mutex.
        let mut g = inner.state.lock();
        let s = g.get_mut();
        s.closed = true;
        inner.not_empty.notify_all();
        inner.not_full.notify_all();
    }
}

extend<T> Sender<T> as Free {
    pub fn free(self: &mut Sender<T>) {
        let inner = self.inner.get();
        {
            let mut g = inner.state.lock();
            let s = g.get_mut();
            s.senders = s.senders - 1;
            if s.senders == 0 {
                // No producers left: wake blocked receivers (under the lock -- it guards the wait queue) so
                // they observe the closed-and-draining channel.
                inner.not_empty.notify_all();
            }
        }
        self.inner.free();
    }
}

extend<T> Receiver<T> {
    /// Another consumer handle for the same channel.
    pub fn clone(self: &Receiver<T>) Receiver<T> {
        let inner = self.inner.get();
        let mut g = inner.state.lock();
        let s = g.get_mut();
        s.receivers = s.receivers + 1;
        return Receiver::<T> { inner: self.inner.clone() };
    }
    /// Wait for an item and take it, or return `None` once the channel is closed (or has no senders left)
    /// and the buffer is drained.
    pub fn recv(self: &Receiver<T>) Option<T> {
        return self.recv_deadline(0);
    }
    /// `recv`, giving up after `d`. `None` means "timed out", "closed and drained" -- or both.
    pub fn recv_timeout(self: &Receiver<T>, d: time::Duration) Option<T> {
        return self.recv_deadline(time::deadline_in(d));
    }
    /// `recv` with an explicit monotonic `deadline` (a `time::deadline_in` value; `0` waits forever). The
    /// body of `recv`/`recv_timeout`; also `pub` so one deadline can bound a whole sequence of operations.
    pub fn recv_deadline(self: &Receiver<T>, deadline: u64) Option<T> {
        let inner = self.inner.get();
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
            if deadline != 0 {
                if time::remaining_ns(deadline) == 0 {
                    return Option::<T>::None;
                }
                inner.not_empty.wait_until(&g, deadline);
            } else {
                inner.not_empty.wait(&g);
            }
        }
        let sm = g.get_mut();
        let v = unsafe {
            sm.slots[sm.head];
        };
        sm.head = (sm.head + 1) % sm.cap;
        sm.count = sm.count - 1;
        inner.not_full.notify_one();
        return Option::<T>::Some(v);
    }
    /// Take an item without blocking, or `None` if the buffer is empty (also `None` if closed and empty).
    pub fn try_recv(self: &Receiver<T>) Option<T> {
        let inner = self.inner.get();
        let mut g = inner.state.lock();
        {
            let s = g.get();
            if s.count == 0 {
                return Option::<T>::None;
            }
        }
        let sm = g.get_mut();
        let v = unsafe {
            sm.slots[sm.head];
        };
        sm.head = (sm.head + 1) % sm.cap;
        sm.count = sm.count - 1;
        inner.not_full.notify_one();
        return Option::<T>::Some(v);
    }
}

extend<T> Receiver<T> as Free {
    pub fn free(self: &mut Receiver<T>) {
        let inner = self.inner.get();
        {
            let mut g = inner.state.lock();
            let s = g.get_mut();
            s.receivers = s.receivers - 1;
            if s.receivers == 0 {
                // No consumers left: wake blocked senders (under the lock -- it guards the wait queue) so
                // they observe the closed channel and give up.
                inner.not_full.notify_all();
            }
        }
        self.inner.free();
    }
}
