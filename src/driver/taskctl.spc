// One resource controller bounds live estimated memory across in-flight compiler tasks. CPU
// credits are the requested --jobs worker count, bounded further by the process-tree jobserver.
// Compute tasks and C-compiler processes never overlap, so no second in-process credit pool exists.
import stdlib;
import std::parallel::sync as psy;

/// Weighted memory gate: `acquire` parks the SUBMITTER until the live estimate fits the budget, so
/// a frontier never puts more estimated bytes in flight than the build allows. A task larger than
/// the whole budget runs alone (the gate admits it when nothing else is live). Budget 0 = off.
pub struct Ctl {
    mu: psy::Mutex<u64>,
    cv: psy::Condvar,
    budget: u64,
}

extend Ctl {
    /// A gate with `budget` bytes; 0 disables it.
    pub fn new(budget: u64) Ctl {
        return Ctl { mu: psy::Mutex::<u64>::new(0), cv: psy::Condvar::new(), budget: budget };
    }

    /// `bytes` is the task's estimated memory.
    pub fn acquire(self: &Self, bytes: u64) {
        if self.budget == 0 || bytes == 0 {
            return;
        }
        let mut g = self.mu.lock();
        while *g.get() != 0 && *g.get() + bytes > self.budget {
            self.cv.wait_masked(&g);
        }
        *g.get_mut() += bytes;
    }

    /// Return `bytes` taken by `acquire` and wake parked submitters.
    pub fn release(self: &Self, bytes: u64) {
        if self.budget == 0 || bytes == 0 {
            return;
        }
        {
            let mut g = self.mu.lock();
            *g.get_mut() -= bytes;
        }
        self.cv.notify_all();
    }
}

/// The build memory budget: `SC_BUILD_MEM_BUDGET` in bytes with an optional K/M/G suffix; 0 = off.
pub fn budget_from_env() u64 {
    let e = stdlib::getenv("SC_BUILD_MEM_BUDGET");
    if e == null {
        return 0;
    }
    let mut endp: *mut char = null;
    let v = unsafe stdlib::strtoul(e, &mut endp, 10);
    if endp as usize == e as usize || v == 0 {
        return 0;
    }
    let c = unsafe *endp;
    if c == 'K' as char || c == 'k' as char {
        return v * 1024;
    }
    if c == 'M' as char || c == 'm' as char {
        return v * 1024 * 1024;
    }
    if c == 'G' as char || c == 'g' as char {
        return v * 1024 * 1024 * 1024;
    }
    return v;
}
