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
// inherit the group's token and register their generation-checked `TaskKey` with it: a raw task pointer
// is never exposed, so a stale handle cannot touch a recycled task block.

import std::parallel::arc as arc;
import std::parallel::sync as sync;
import std::parallel::atomics as atomics;
import std::parallel::runtime as runtime;

// The state one source and its tokens share. `keys` holds the registered target tasks; a key whose task
// already finished is inert (the registry generation check rejects it), so the list needs no removal.
@no_const
struct CancelShared {
    pub flag: atomics::Atomic<i32>, // 0 live, 1 cancelled
    pub reason: atomics::Atomic<i32>, // the CR_* reason of the first cancel
    pub keys: sync::Mutex<Vector<runtime::TaskKey>>,
}

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
            keys: sync::Mutex::<Vector<runtime::TaskKey>>::new(Vector::<runtime::TaskKey>::new()),
        },
    );
}

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
    /// Request cancellation of every registered task, with a `runtime::CR_*` reason. Idempotent: the
    /// first call's reason is retained, later calls change nothing. Tasks that register after this call
    /// are cancelled at registration.
    pub fn cancel(self: &CancelSource, reason: u32) {
        let sh = self.shared.get();
        let mut first = false;
        {
            // Under the key lock: `bind_current` re-checks the flag under the same lock, so a task can
            // never slip between this sweep and its registration.
            let g = sh.keys.lock();
            if sh.flag.load(atomics::MemoryOrder::Acquire) == 0 {
                sh.reason.store(reason as i32, atomics::MemoryOrder::Relaxed);
                sh.flag.store(1, atomics::MemoryOrder::Release);
                first = true;
            }
            if first {
                for i in 0..g.len() {
                    let key = *g.at(i);
                    let _ = runtime::request_cancel(key, reason);
                }
            }
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
    /// Register the CURRENT task as a cancellation target of this token's source. A no-op off the pool.
    /// If the source already cancelled, the task is cancelled immediately. `pub` so a spawned task can
    /// adopt a token it received by other means.
    pub fn bind_current(self: &CancelToken) {
        let key = runtime::current_key();
        if !key.is_task() {
            return;
        }
        let sh = self.shared.get();
        let mut g = sh.keys.lock();
        g.push(key);
        if sh.flag.load(atomics::MemoryOrder::Acquire) != 0 {
            let reason = sh.reason.load(atomics::MemoryOrder::Relaxed) as u32;
            let _ = runtime::request_cancel(key, reason);
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
