// Bounded waits on runtime STATE, for the concurrency tests. A test that needs a task to be parked, a
// number of waiters to be queued, or a task to be gone waits for exactly that through the runtime's own
// snapshot; it never sleeps for a duration and hopes the scheduler got there first, because on a loaded
// runner it did not. Every wait is bounded (five seconds) and reports whether the state was reached, so a
// caller asserts on the result and a genuine hang fails with a name instead of stalling the job.

import sc_runtime;
import std::parallel::runtime as rt;
import std::parallel::arc as arc;
import std::parallel::atomics as atomics;
import std::parallel::platform as platform;
import std::parallel::time as time;

const BOUND_NS: u64 = 5000000000;

/// Whether the task `key` names has a wait record: it is at (or past) the park it is heading for, so a
/// cancellation requested now is claimed by that park rather than delivered to a task still running.
fn parked(key: rt::TaskKey, rows: &mut Vector<rt::TaskInfo>) bool {
    rows.clear();
    rt::task_snapshot(rows);
    for i in 0..rows.len() {
        let r = rows.at(i);
        if r.key.slot == key.slot && r.key.gen == key.gen {
            return r.wait_kind != rt::WK_NONE;
        }
    }
    return false;
}

/// Wait until the task `key` names is at its wait.
pub fn wait_parked(key: rt::TaskKey) bool {
    let deadline = platform::now_ns() + BOUND_NS;
    let mut rows = Vector::<rt::TaskInfo>::new();
    while !parked(key, &mut rows) {
        if platform::now_ns() > deadline {
            return false;
        }
        time::sleep(time::Duration::from_millis(1));
    }
    return true;
}

/// Wait until at least `want` live tasks wait on `kind` (a `rt::WK_*` value).
pub fn wait_waiting(kind: i32, want: usize) bool {
    let deadline = platform::now_ns() + BOUND_NS;
    while rt::tasks_waiting(kind) < want {
        if platform::now_ns() > deadline {
            return false;
        }
        time::sleep(time::Duration::from_millis(1));
    }
    return true;
}

/// Whether no live task remains: a task that has signalled is not yet complete, and one that is complete
/// may not yet have retired, so a test that needs the task gone waits for this rather than for its signal.
fn live_tasks(rows: &mut Vector<rt::TaskInfo>) usize {
    rows.clear();
    rt::task_snapshot(rows);
    let mut n: usize = 0;
    for i in 0..rows.len() {
        if rows.at(i).state != rt::TS_COMPLETED {
            n = n + 1;
        }
    }
    return n;
}

/// Wait until the task `key` names has completed or retired.
pub fn wait_gone(key: rt::TaskKey) bool {
    let deadline = platform::now_ns() + BOUND_NS;
    let mut rows = Vector::<rt::TaskInfo>::new();
    loop {
        rows.clear();
        rt::task_snapshot(&mut rows);
        let mut live = false;
        for i in 0..rows.len() {
            let r = rows.at(i);
            if r.key.slot == key.slot && r.key.gen == key.gen && r.state != rt::TS_COMPLETED {
                live = true;
            }
        }
        if !live {
            return true;
        }
        if platform::now_ns() > deadline {
            return false;
        }
        time::sleep(time::Duration::from_millis(1));
    }
}

/// Wait until no live task remains.
pub fn wait_quiescent() bool {
    let deadline = platform::now_ns() + BOUND_NS;
    let mut rows = Vector::<rt::TaskInfo>::new();
    while live_tasks(&mut rows) != 0 {
        if platform::now_ns() > deadline {
            return false;
        }
        time::sleep(time::Duration::from_millis(1));
    }
    return true;
}

/// Wait until the idle task-block pool retains at most `bytes`: the finished tasks have handed their blocks
/// back and the pool released what is past its budget.
pub fn wait_pool_within(bytes: usize) bool {
    let deadline = platform::now_ns() + BOUND_NS;
    while rt::pool_retained_bytes() > bytes {
        if platform::now_ns() > deadline {
            return false;
        }
        time::sleep(time::Duration::from_millis(1));
    }
    return true;
}

/// Wait until a shared counter reaches `want`.
pub fn wait_count(c: &arc::Arc<atomics::Atomic<i64>>, want: i64) bool {
    let deadline = platform::now_ns() + BOUND_NS;
    while c.get().load(atomics::MemoryOrder::Acquire) < want {
        if platform::now_ns() > deadline {
            return false;
        }
        time::sleep(time::Duration::from_millis(1));
    }
    return true;
}

/// Whether a parked plain thread leaves a record `sc_rt_parked` counts. Windows parks through
/// `WaitOnAddress`, which keeps none and may also return with no wake.
@platform(!windows)
pub const fn parks_are_counted() bool {
    return true;
}

@platform(windows)
pub const fn parks_are_counted() bool {
    return false;
}

/// Wait until at least `want` plain threads are parked in the runtime's parking lot (a condvar or `select`
/// wait, a contended lock, a raw `sc_rt_park`), so a wake sent now finds each of them queued. True at once
/// where parks leave no record: there the wake still lands, on a thread that may not have slept yet.
pub fn wait_os_parked(want: usize) bool {
    if !parks_are_counted() {
        return true;
    }
    let deadline = platform::now_ns() + BOUND_NS;
    while unsafe sc_runtime::sc_rt_parked() < want {
        if platform::now_ns() > deadline {
            return false;
        }
        time::sleep(time::Duration::from_millis(1));
    }
    return true;
}
