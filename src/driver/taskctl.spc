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

/// The build memory budget: `SC_BUILD_MEM_BUDGET` in bytes with an optional K/M/G suffix; unset or
/// empty = off (0). Any other spelling, or a value past u64, is a fatal configuration error.
pub fn budget_from_env() u64 {
    let e = stdlib::getenv("SC_BUILD_MEM_BUDGET");
    if e == null || unsafe *e == 0 as char {
        return 0;
    }
    let s = str::from_cstr(e);
    let mut v: u64 = 0;
    let mut i: usize = 0;
    let mut ok = true;
    while i < s.len() && s.byte_at(i) >= b'0' && s.byte_at(i) <= b'9' {
        let d = (s.byte_at(i) - b'0') as u64;
        if v > (0xFFFFFFFFFFFFFFFFu64 - d) / 10 {
            ok = false;
            break;
        }
        v = v * 10 + d;
        i += 1;
    }
    let mut scale: u64 = 1;
    if i == 0 {
        ok = false;
    } else if i + 1 == s.len() {
        let c = s.byte_at(i);
        if c == b'K' || c == b'k' {
            scale = 1024;
        } else if c == b'M' || c == b'm' {
            scale = 1024u64 * 1024;
        } else if c == b'G' || c == b'g' {
            scale = 1024u64 * 1024 * 1024;
        } else {
            ok = false;
        }
    } else if i != s.len() {
        ok = false;
    }
    if !ok || v > 0xFFFFFFFFFFFFFFFFu64 / scale {
        eprintln("error: SC_BUILD_MEM_BUDGET must be a whole byte count with an optional K, M or G suffix");
        unsafe stdlib::exit(1);
    }
    return v * scale;
}
