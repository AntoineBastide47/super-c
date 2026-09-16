// Public task ownership: cancellation sources, read-only cancellation tokens, and structured task
// groups. Import with `import std::parallel::task;`.
//
//     let mut group = task::TaskGroup::new();
//     group.spawn(fn() { work(); });
//     group.cancel();                       // cooperative: children stop at cancellation points
//     let report = group.join();            // waits for every child's completion or cleanup
//
// Only a `CancelSource` can request cancellation; a `CancelToken` observes it. A group owns its children:
// its drop requests cancellation and joins them, so a group can never leak a running task. Children
// inherit the group's token and register with it; a raw task pointer is never exposed, so a stale handle
// cannot touch a recycled task block.
//
// Registration contract (`CancelToken::bind_current`):
//   - Membership is per (task, source). Binding the same source twice from one task is one membership;
//     binding several sources from one task is one membership each. A membership is a record the TASK
//     owns (the first lives inline in the task block, every further one is a small heap record) and the
//     SOURCE links into its member list, so a source holds exactly its live members and nothing of its
//     history.
//   - A membership lasts until the task completes, by return or by cancellation cleanup: the runtime
//     unlinks every record before the task's identity can be recycled. The record holds a reference to
//     the source's shared state, so a source (and its tokens) may all be dropped while members live.
//   - Binding after the source cancelled delivers the request at once with the FIRST request's reason.
//     Cancellation reads its members under the source lock and requests each by generation-checked key
//     outside it, in bounded batches; a member that completes meanwhile is rejected by the key check.
//   - Lock order: a source lock is taken alone. Nothing under it can reach a task's cleanup or another
//     source, and the key-based request (which takes a registry slot lock) runs after it is released.

import atomic;
import sc_runtime;
import std::parallel::arc as arc;
import std::parallel::sync as sync;
import std::parallel::atomics as atomics;
import std::parallel::runtime as runtime;

// The state one source and its tokens share. `head` is the doubly linked member list, guarded by `spin`;
// `flag` and `reason` are written once, under the same lock, and read lock-free by tokens.
@no_const
struct CancelShared {
    pub flag: atomics::Atomic<i32>, // 0 live, 1 cancelled
    pub reason: atomics::Atomic<i32>, // the CR_* reason of the first cancel
    pub spin: UnsafeCell<i32>, // guards `head` and every member's list links
    pub head: UnsafeCell<*mut Member>, // live members, oldest first; drained (not kept) by the cancel sweep
    pub tail: UnsafeCell<*mut Member>, // where a registration appends: the sweep then requests in bind order
}

// One membership: the task's record, linked into the source's list. Storage belongs to the task (inline in
// its block, or heap for a second source); the source only ever follows the links under its lock.
@no_const
struct Member {
    pub src: arc::Arc<CancelShared>, // keeps the source state alive for as long as this record exists
    pub key: runtime::TaskKey, // the task, for the generation-checked request
    pub snext: *mut Member, // source list
    pub sprev: *mut Member,
    pub tnext: *mut Member, // the task's own list, walked at completion
    pub linked: i32, // atomic: still on the source list; cleared under the lock, read before taking it
}

// The raw cells make the shared state structurally neither `Send` nor `Sync`; the spin lock guards every
// access to them (`head` and the members' links), and the atomics are ordered on their own, so a source
// or token may be sent and shared freely.
unsafe extend CancelShared as Send {}

unsafe extend CancelShared as Sync {}

static_assert(sizeof(Member) <= sizeof(runtime::Membership) - 16, "the first membership must fit the task block's inline storage");

/// The requesting half of a cancellation pair. Clonable; every clone cancels the same set of registered
/// tasks. Runtime shutdown uses its own internal source, so a program source never races it for a reason.
@no_const
pub struct CancelSource {
    shared: arc::Arc<CancelShared>,
}

/// The read-only half: tasks observe cancellation through it and can never request it.
@no_const
pub struct CancelToken {
    shared: arc::Arc<CancelShared>,
}

/// What a joined group observed: every child ends in exactly one column. `unresponsive` stays zero unless
/// a bounded join form gave up on a child that could not accept cancellation.
pub struct GroupReport {
    pub completed: usize,
    pub cancelled: usize,
    pub unresponsive: usize,
}

// Per-group completion counters, shared with every child.
@no_const
struct GroupShared {
    pub completed: atomics::Atomic<i64>,
    pub cancelled: atomics::Atomic<i64>,
}

/// A structured owner for a set of child tasks. The group's token is inherited by every child; `cancel`
/// requests cooperative cancellation of all of them, `join` waits for every child to complete or finish
/// its cancellation cleanup. Dropping the group cancels and joins, so children cannot outlive it.
@no_const
pub struct TaskGroup {
    src: CancelSource,
    counts: arc::Arc<GroupShared>,
    wg: sync::WaitGroup,
    spawned: usize,
}

fn new_shared() arc::Arc<CancelShared> {
    return arc::Arc::<CancelShared>::new(
        CancelShared {
            flag: atomics::Atomic::<i32>::new(0),
            reason: atomics::Atomic::<i32>::new(0),
            spin: UnsafeCell::<i32>::new(0),
            head: UnsafeCell::<*mut Member>::new(null),
            tail: UnsafeCell::<*mut Member>::new(null),
        },
    );
}

// Unlink `m` from its source's list. Caller holds the source lock.
fn unlink_locked(sh: &CancelShared, m: *mut Member) {
    let nx = unsafe m.snext;
    let pv = unsafe m.sprev;
    if pv != null {
        unsafe pv.snext = nx;
    } else {
        unsafe sh.head.get()[0] = nx;
    }
    if nx != null {
        unsafe nx.sprev = pv;
    } else {
        unsafe sh.tail.get()[0] = pv;
    }
    atomic::store_i32(&mut unsafe m.linked, 0, 2);
}

// The completion hook the runtime calls once the task's body has returned and before its block can be
// recycled: every record leaves its source list (under that source's lock), gives its reference back, and
// heap records are freed. Runs on the worker, outside any task, holding no lock across records.
fn membership_release(mb: *mut runtime::Membership) {
    let inl = (&mut unsafe mb.inline_mem[0]) as *mut Member;
    let mut m = (unsafe mb.head) as *mut Member;
    unsafe mb.head = null;
    let mut g = Global {};
    while m != null {
        let nx = unsafe m.tnext;
        let sh = unsafe m.src.get();
        // A member the cancel sweep already drained needs no lock: a thousand children unwinding at once
        // would otherwise serialise on their source. Re-checked under the lock, since the sweep may be
        // draining this very record.
        if atomic::load_i32(&mut unsafe m.linked, 1) != 0 {
            unsafe sc_runtime::sc_rt_spin_lock(sh.spin.get());
            if atomic::load_i32(&mut unsafe m.linked, 0) != 0 {
                unlink_locked(sh, m);
            }
            unsafe sc_runtime::sc_rt_spin_unlock(sh.spin.get());
        }
        // The record's reference to the source goes with it: destroyed in place, since the record is raw
        // storage the task owns, not a value the drop elaboration knows.
        let sp = (&mut unsafe m.src) as *mut arc::Arc<CancelShared>;
        sp.free();
        if m != inl {
            unsafe g.dealloc(m, sizeof(Member), alignof(Member));
        }
        m = nx;
    }
}

// How many keys one cancel sweep gathers per lock hold: the sweep's only temporary storage.
const CANCEL_BATCH: usize = 64;

// What a child reports through, moved as one value so the trampoline can defer it whole.
@no_const
struct GroupRefs {
    pub tok: CancelToken,
    pub counts: arc::Arc<GroupShared>,
    pub w: sync::WaitGroup,
}

// A child's completion record: counted and reported to the group whichever way the body ended.
fn group_finish(refs: GroupRefs) {
    if runtime::cancelling() {
        let _ = refs.counts.get().cancelled.fetch_add(1, atomics::MemoryOrder::Relaxed);
    } else {
        let _ = refs.counts.get().completed.fetch_add(1, atomics::MemoryOrder::Relaxed);
    }
    refs.w.done();
}

// What one spawned child owns, boxed for the coroutine trampoline. The group pieces sit behind one raw
// pointer so the generic part carries only `F` (a field cannot be moved out of an owning aggregate).
@no_const
struct ChildEnv<F> {
    pub f: F,
    pub refs: *mut GroupRefs,
}

/// The per-`F` child trampoline: unbox, bind the group token, run the body. The finish runs from a
/// `defer`, so a body that ends through cancellation cleanup still reports. `pub` for linkage.
pub fn child_entry<F: fn move() + Send + 'static>(env: *mut void) {
    let pp = env as *mut ChildEnv<F>;
    let e = unsafe {
        pp[0];
    };
    let mut g = Global {};
    unsafe g.dealloc(env, sizeof(ChildEnv<F>), alignof(ChildEnv<F>));
    let rp = e.refs;
    let refs = unsafe {
        rp[0];
    };
    unsafe g.dealloc(rp, sizeof(GroupRefs), alignof(GroupRefs));
    refs.tok.bind_current();
    defer group_finish(move refs);
    let f = e.f;
    f();
}

extend CancelSource {
    // Internal constructor for the group's own source.
    fn wrap(sh: arc::Arc<CancelShared>) CancelSource {
        return CancelSource { shared: sh };
    }
    /// A fresh source and its first token.
    pub fn new() (CancelSource, CancelToken) {
        let sh = new_shared();
        let tok = CancelToken::wrap(sh.clone());
        return CancelSource { shared: sh }, tok;
    }
    /// Another handle to the same source.
    pub fn clone(self: &CancelSource) CancelSource {
        return CancelSource { shared: self.shared.clone() };
    }
    /// Another token observing this source.
    pub fn token(self: &CancelSource) CancelToken {
        return CancelToken::wrap(self.shared.clone());
    }
    /// How many live tasks are registered right now: a diagnostic count, taken under the member lock.
    /// Zero once the source has cancelled (a cancelled source keeps no list).
    pub fn members(self: &CancelSource) usize {
        let sh = self.shared.get();
        let mut n: usize = 0;
        unsafe sc_runtime::sc_rt_spin_lock(sh.spin.get());
        let mut m = unsafe sh.head.get()[0];
        while m != null {
            n = n + 1;
            m = unsafe m.snext;
        }
        unsafe sc_runtime::sc_rt_spin_unlock(sh.spin.get());
        return n;
    }
    /// Request cancellation of every registered task, with a `runtime::CR_*` reason. Idempotent: the
    /// first call's reason is retained, later calls change nothing. Tasks that register after this call
    /// are cancelled at registration.
    pub fn cancel(self: &CancelSource, reason: u32) {
        let sh = self.shared.get();
        let mut keys = Array::<u64, 64>::new(); // packed keys: slot << 32 | gen
        // The flag is raised under the member lock, so a registration sees either the flag (and cancels
        // itself) or its record on the list (and is swept): never neither. The list is then DRAINED a
        // batch at a time: once cancelled, a source has no further use for its members, and unlinking
        // them here keeps the sweep's storage fixed and the lock held for at most one batch.
        unsafe sc_runtime::sc_rt_spin_lock(sh.spin.get());
        if sh.flag.load(atomics::MemoryOrder::Relaxed) != 0 {
            unsafe sc_runtime::sc_rt_spin_unlock(sh.spin.get());
            return;
        }
        sh.reason.store(reason as i32, atomics::MemoryOrder::Relaxed);
        sh.flag.store(1, atomics::MemoryOrder::Release);
        loop {
            let mut n: usize = 0;
            while n < CANCEL_BATCH && unsafe sh.head.get()[0] != null {
                let m = unsafe sh.head.get()[0];
                let k = unsafe m.key;
                keys[n] = k.slot as u64 << 32 | k.gen as u64;
                unlink_locked(sh, m);
                n = n + 1;
            }
            unsafe sc_runtime::sc_rt_spin_unlock(sh.spin.get());
            for i in 0..n {
                // Key-checked: a member that completed since the batch was gathered is rejected here.
                let key = runtime::TaskKey { slot: (keys[i] >> 32) as u32, gen: keys[i] as u32 };
                let _ = runtime::request_cancel(key, reason);
            }
            if n < CANCEL_BATCH {
                return;
            }
            unsafe sc_runtime::sc_rt_spin_lock(sh.spin.get());
        }
    }
}

extend CancelSource as Free {
    pub fn free(self: &mut CancelSource) {
        self.shared.free();
    }
}

extend CancelToken {
    // Internal constructor: only a source (or the group that owns one) mints tokens.
    fn wrap(sh: arc::Arc<CancelShared>) CancelToken {
        return CancelToken { shared: sh };
    }
    /// Has the source cancelled?
    pub fn is_cancelled(self: &CancelToken) bool {
        return self.shared.get().flag.load(atomics::MemoryOrder::Acquire) != 0;
    }
    /// Another token observing the same source.
    pub fn clone(self: &CancelToken) CancelToken {
        return CancelToken { shared: self.shared.clone() };
    }
    /// Register the CURRENT task as a cancellation target of this token's source, until the task
    /// completes. A no-op off the pool, and a no-op if the task is already registered with this source.
    /// If the source already cancelled, the task is cancelled immediately with the source's reason. `pub`
    /// so a spawned task can adopt a token it received by other means; several sources may be adopted.
    pub fn bind_current(self: &CancelToken) {
        let mb = runtime::current_membership();
        if mb == null {
            return;
        }
        let sh = self.shared.get();
        let want = sh as *const CancelShared;
        let inl = (&mut unsafe mb.inline_mem[0]) as *mut Member;
        let mut m = (unsafe mb.head) as *mut Member;
        while m != null {
            if (unsafe m.src.get()) as *const CancelShared == want {
                return; // already a member: one record per (task, source)
            }
            m = unsafe m.tnext;
        }
        // Records are only ever unlinked at completion, so the inline slot is free exactly when the task
        // has no membership yet.
        let mut g = Global {};
        m = if unsafe mb.head == null {
            unsafe mb.hook = membership_release;
            inl;
        } else {
            (unsafe g.alloc(sizeof(Member), alignof(Member))) as *mut Member;
        };
        unsafe m[0] = Member {
            src: self.shared.clone(),
            key: runtime::current_key(),
            snext: null,
            sprev: null,
            tnext: (unsafe mb.head) as *mut Member,
            linked: 1,
        };
        unsafe mb.head = m;
        unsafe sc_runtime::sc_rt_spin_lock(sh.spin.get());
        let cancelled = sh.flag.load(atomics::MemoryOrder::Relaxed) != 0;
        let reason = sh.reason.load(atomics::MemoryOrder::Relaxed) as u32;
        if !cancelled {
            // Appended, so a sweep requests members in registration order: tasks that armed timers in
            // that order come due in that order too (the heap breaks equal deadlines by arm order).
            let last = unsafe sh.tail.get()[0];
            unsafe m.sprev = last;
            if last != null {
                unsafe last.snext = m;
            } else {
                unsafe sh.head.get()[0] = m;
            }
            unsafe sh.tail.get()[0] = m;
        } else {
            // A cancelled source keeps no list: the record stays with the task only.
            atomic::store_i32(&mut unsafe m.linked, 0, 0);
        }
        unsafe sc_runtime::sc_rt_spin_unlock(sh.spin.get());
        if cancelled {
            let _ = runtime::request_cancel(unsafe m.key, reason);
        }
    }
}

extend CancelToken as Free {
    pub fn free(self: &mut CancelToken) {
        self.shared.free();
    }
}

extend TaskGroup {
    /// An empty group with its own cancellation source.
    pub fn new() TaskGroup {
        return TaskGroup {
            src: CancelSource::wrap(new_shared()),
            counts: arc::Arc::<GroupShared>::new(
                GroupShared { completed: atomics::Atomic::<i64>::new(0), cancelled: atomics::Atomic::<i64>::new(0) },
            ),
            wg: sync::WaitGroup::new(),
            spawned: 0,
        };
    }
    /// The group's token, for code that wants to observe cancellation without owning the group.
    pub fn token(self: &TaskGroup) CancelToken {
        return self.src.token();
    }
    /// Spawn `f` as a child: it inherits the group's cancellation token, and `join` waits for it. The
    /// bound is the `launch` bound: the child may outlive this call, so it owns everything it touches.
    /// A group cannot spawn once shutdown has closed the runtime; `f` is freed and no child is counted.
    pub fn spawn<F: fn move() + Send + 'static>(self: &mut TaskGroup, f: F) {
        if runtime::closed() {
            // `f` and its captures are freed here.
            return;
        }
        self.wg.add(1);
        self.spawned = self.spawned + 1;
        let mut g = Global {};
        let rp = (unsafe g.alloc(sizeof(GroupRefs), alignof(GroupRefs))) as *mut GroupRefs;
        unsafe rp[0] = GroupRefs { tok: self.src.token(), counts: self.counts.clone(), w: self.wg.clone() };
        let env = (unsafe g.alloc(sizeof(ChildEnv<F>), alignof(ChildEnv<F>))) as *mut ChildEnv<F>;
        unsafe env[0] = ChildEnv::<F> { f: f, refs: rp };
        runtime::spawn_coroutine(child_entry::<F>, env);
    }
    /// Request cooperative cancellation of every child, with the user reason.
    pub fn cancel(self: &TaskGroup) {
        self.src.cancel(runtime::CR_USER);
    }
    /// Wait until every child has completed or finished its cancellation cleanup, then report the counts.
    pub fn join(self: &TaskGroup) GroupReport {
        self.wg.wait();
        let c = self.counts.get();
        let completed = c.completed.load(atomics::MemoryOrder::Acquire) as usize;
        let cancelled = c.cancelled.load(atomics::MemoryOrder::Acquire) as usize;
        let mut report = GroupReport { completed: completed, cancelled: cancelled, unresponsive: 0 };
        if self.spawned > completed + cancelled {
            // Join was cancelled out early.
            report.unresponsive = self.spawned - completed - cancelled;
        }
        return report;
    }
}

extend TaskGroup as Free {
    /// Group drop leaves no child task: cancel them all, join, then release the group's own state.
    pub fn free(self: &mut TaskGroup) {
        self.cancel();
        let _ = self.join();
        self.src.free();
        self.counts.free();
        self.wg.free();
    }
}
