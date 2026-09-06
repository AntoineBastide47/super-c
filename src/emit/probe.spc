// Scoped emission counters: wall time, calls, and (with the runtime tracker on) allocation calls
// and requested bytes per region of C generation, plus repeated-work tallies. One Probe rides in
// every context that does the work (CEmit, DropCtx, the driver's own); shard probes merge into
// the master's, which prints the table under SC_CEMIT_STATS. Off, every operation is one branch.
import std::parallel::platform as platform;

// The generated runtime's allocation counters (super_rt.c); zero until SC_BUILD_MEM turned the
// tracker on.
extern "C" {
    fn sc_lk_counts(out: *mut u64) void;
}

/// Regions. Nested regions accumulate independently: rendering excludes the declaration planning
/// it contains, symbol construction is reported within rendering.
pub const P_GRAPH: usize = 0; // instance graph construction
pub const P_ACQUIRE: usize = 1; // body acquisition: kept takes and fallback lowerings
pub const P_RELOWER: usize = 2; // per-instance re-lowering (reflection, zero-size conditions)
pub const P_INLINE: usize = 3; // inliner: callee vetting and splicing
pub const P_DROPS: usize = 4; // move/drop facts, cleanup elaboration, bounds-check elimination
pub const P_SYM: usize = 5; // symbol and mangled-name construction (within rendering)
pub const P_DECL: usize = 6; // declaration planning: local analysis and CFG structure
pub const P_RENDER: usize = 7; // statement and expression rendering (less planning)
pub const P_ASSEMBLE: usize = 8; // header and TU assembly
pub const P_PUBLISH: usize = 9; // file publication (less the build engine sink)
pub const P_SYNC: usize = 10; // build engine sink: raw to gen sync and compile planning
pub const P_COUNT: usize = 11;

/// Repeated-work tallies.
pub const C_TAKEN: usize = 0; // bodies taken from the keep
pub const C_LOWERED: usize = 1; // bodies lowered because the keep had none
pub const C_RELOWER_REFLECT: usize = 2; // instance re-lowerings for a reflection binder
pub const C_RELOWER_ZST: usize = 3; // instance re-lowerings for a zero-size condition
pub const C_VET_LOWERED: usize = 4; // inliner callees vetted from a fresh lowering
pub const C_VET_OFFERED: usize = 5; // inliner callees vetted from the body being emitted
pub const C_BODIES: usize = 6; // bodies rendered (seeds and closures)
pub const C_INSTANCES: usize = 7; // instances rendered
pub const C_OUT_BYTES: usize = 8; // bytes rendered
pub const C_COUNT: usize = 9;

const REGION_NAMES: [str<'static>; 11] = [
    "graph",
    "acquire",
    "relower",
    "inline",
    "drops",
    "sym",
    "decl",
    "render",
    "assemble",
    "publish",
    "sync",
];
static_assert(P_COUNT == 11, "one name per region");

pub struct Probe {
    pub on: bool,
    pub mem: bool, // allocation columns are live (the runtime tracker counts)
    pub ns: Array<u64, P_COUNT>,
    pub calls: Array<u64, P_COUNT>,
    pub an: Array<u64, P_COUNT>, // allocation calls
    pub ab: Array<u64, P_COUNT>, // bytes requested
    pub c: Array<u64, C_COUNT>,
}

/// A region entry: the clock and the allocation counters at the start.
pub struct Mark {
    pub ns: u64,
    pub an: u64,
    pub ab: u64,
}

pub const fn mark_none() Mark {
    return Mark { ns: 0, an: 0, ab: 0 };
}

extend Probe {
    pub fn new(on: bool, mem: bool) Probe {
        return Probe {
            on: on,
            mem: on && mem,
            ns: Array::<u64, P_COUNT>::new(),
            calls: Array::<u64, P_COUNT>::new(),
            an: Array::<u64, P_COUNT>::new(),
            ab: Array::<u64, P_COUNT>::new(),
            c: Array::<u64, C_COUNT>::new(),
        };
    }

    /// Enter a region (a no-op mark when off).
    pub fn start(self: &Self) Mark {
        if !self.on {
            return mark_none();
        }
        let mut m = Mark { ns: platform::now_ns(), an: 0, ab: 0 };
        if self.mem {
            let mut w = Array::<u64, 2>::new();
            unsafe sc_lk_counts(&mut w[0]);
            m.an = w[0];
            m.ab = w[1];
        }
        return m;
    }

    /// Leave region `k` entered at `m`.
    pub fn stop(self: &mut Self, k: usize, m: Mark) {
        if !self.on {
            return;
        }
        assert(k < P_COUNT);
        self.ns[k] += platform::now_ns() - m.ns;
        self.calls[k] += 1;
        if self.mem {
            let mut w = Array::<u64, 2>::new();
            unsafe sc_lk_counts(&mut w[0]);
            self.an[k] += w[0] - m.an;
            self.ab[k] += w[1] - m.ab;
        }
    }

    /// Leave region `k` entered at `m`, less what an inner region already booked since `m`:
    /// `inner_ns`/`inner_an`/`inner_ab` are that region's totals as read at `m`.
    pub fn stop_less(self: &mut Self, k: usize, m: Mark, inner: usize, ns0: u64, an0: u64, ab0: u64) {
        if !self.on {
            return;
        }
        assert(k < P_COUNT);
        assert(inner < P_COUNT);
        let dt = platform::now_ns() - m.ns;
        let inner_dt = self.ns[inner] - ns0;
        assert(inner_dt <= dt);
        self.ns[k] += dt - inner_dt;
        self.calls[k] += 1;
        if self.mem {
            let mut w = Array::<u64, 2>::new();
            unsafe sc_lk_counts(&mut w[0]);
            self.an[k] += w[0] - m.an - (self.an[inner] - an0);
            self.ab[k] += w[1] - m.ab - (self.ab[inner] - ab0);
        }
    }

    pub fn count(self: &mut Self, k: usize, n: u64) {
        assert(k < C_COUNT);
        self.c[k] += n;
    }

    /// Fold `other` (a shard's or a pooled context's probe) into this one.
    pub fn merge(self: &mut Self, other: &Probe) {
        if !self.on {
            return;
        }
        for k in 0..P_COUNT {
            self.ns[k] += other.ns[k];
            self.calls[k] += other.calls[k];
            self.an[k] += other.an[k];
            self.ab[k] += other.ab[k];
        }
        for k in 0..C_COUNT {
            self.c[k] += other.c[k];
        }
    }

    /// The report: one row per region, then the repeated-work tallies.
    pub fn report(self: &Self, out: &mut String) {
        out.push_str("emit-probe            ms      calls");
        if self.mem {
            out.push_str("     allocs      MiB");
        }
        out.push_str("\n");
        let mut total: u64 = 0;
        for k in 0..P_COUNT {
            total += self.ns[k];
            out.push_str("  ");
            let nm = unsafe REGION_NAMES[k];
            out.push_str(nm);
            for _i in nm.len()..12 {
                out.push_byte(b' ');
            }
            push_ms(out, self.ns[k]);
            push_right(out, self.calls[k], 11);
            if self.mem {
                push_right(out, self.an[k], 11);
                out.push_str("  ");
                out.push_f64_prec(self.ab[k] as f64 / 1048576.0, 2);
            }
            out.push_str("\n");
        }
        out.push_str("  total       ");
        push_ms(out, total);
        out.push_str("\n");
        out.push_str("  bodies taken ");
        out.push_u64(self.c[C_TAKEN]);
        out.push_str(", lowered ");
        out.push_u64(self.c[C_LOWERED]);
        out.push_str("; re-lowered for reflection ");
        out.push_u64(self.c[C_RELOWER_REFLECT]);
        out.push_str(", for zero-size conditions ");
        out.push_u64(self.c[C_RELOWER_ZST]);
        out.push_str("; inliner callees vetted from a lowering ");
        out.push_u64(self.c[C_VET_LOWERED]);
        out.push_str(", from an emitted body ");
        out.push_u64(self.c[C_VET_OFFERED]);
        out.push_str("; rendered ");
        out.push_u64(self.c[C_BODIES]);
        out.push_str(" bodies and ");
        out.push_u64(self.c[C_INSTANCES]);
        out.push_str(" instances, ");
        out.push_f64_prec(self.c[C_OUT_BYTES] as f64 / 1048576.0, 2);
        out.push_str(" MiB");
        if self.ns[P_RENDER] != 0 {
            out.push_str(" at ");
            out.push_f64_prec(self.c[C_OUT_BYTES] as f64 / 1048576.0 / (self.ns[P_RENDER] as f64 / 1e9), 1);
            out.push_str(" MiB/s rendered");
        }
        if !self.mem {
            out.push_str(" (allocation columns need SC_BUILD_MEM=1)");
        }
        out.push_str("\n");
    }
}

fn push_ms(out: &mut String, ns: u64) {
    let mut s = String::new();
    s.push_f64_prec(ns as f64 / 1000000.0, 2);
    for _i in s.len()..10 {
        out.push_byte(b' ');
    }
    out.push_string(&s);
}

fn push_right(out: &mut String, v: u64, width: usize) {
    let mut s = String::new();
    s.push_u64(v);
    for _i in s.len()..width {
        out.push_byte(b' ');
    }
    out.push_string(&s);
}
