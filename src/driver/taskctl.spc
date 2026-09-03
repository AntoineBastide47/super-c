// The compiler task contract: every parallel frontier submits work under a TaskKey/TaskDesc, and
// one resource controller bounds live estimated memory across in-flight tasks. CPU credits are the
// requested --jobs worker count, bounded further by the process-tree jobserver. Compute tasks and
// C-compiler processes never overlap, so no second in-process credit pool exists.
import stdlib;
import std::parallel::sync as psy;

pub const ST_PARSE: u32 = 1;
pub const ST_RESOLVE: u32 = 2;
pub const ST_TYPECHECK: u32 = 3;
pub const ST_BORROWCK: u32 = 4;
pub const ST_PANICS: u32 = 5;
pub const ST_LIVE: u32 = 6;
pub const ST_SEED: u32 = 7;
pub const ST_LOWER: u32 = 8;
pub const ST_INSTANCE: u32 = 9;

pub struct TaskKey {
    pub stage: u32,
    pub module: u32, // 0xFFFFFFFF = none (the instance TU, a slice)
    pub item: u64, // stable item, body, instance or slice identity within the stage
}

pub struct TaskDesc {
    pub key: TaskKey,
    pub estimated_cpu: u32,
    pub estimated_memory: u64,
    pub priority: u32, // larger submits first within a frontier; ties break on key order
}

/// Weighted memory gate: `acquire` parks the SUBMITTER until the live estimate fits the budget, so
/// a frontier never puts more estimated bytes in flight than the build allows. A task larger than
/// the whole budget runs alone (the gate admits it when nothing else is live). Budget 0 = off.
pub struct Ctl {
    mu: psy::Mutex<u64>,
    cv: psy::Condvar,
    budget: u64,
}

extend Ctl {
    pub fn new(budget: u64) Ctl {
        return Ctl { mu: psy::Mutex::<u64>::new(0), cv: psy::Condvar::new(), budget: budget };
    }

    pub fn acquire(self: &Self, d: &TaskDesc) {
        if self.budget == 0 || d.estimated_memory == 0 {
            return;
        }
        let mut g = self.mu.lock();
        while *g.get() != 0 && *g.get() + d.estimated_memory > self.budget {
            self.cv.wait_masked(&g);
        }
        *g.get_mut() += d.estimated_memory;
    }

    pub fn release(self: &Self, d: &TaskDesc) {
        if self.budget == 0 || d.estimated_memory == 0 {
            return;
        }
        {
            let mut g = self.mu.lock();
            *g.get_mut() -= d.estimated_memory;
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
