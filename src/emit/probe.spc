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
pub const P_RELOWER_REFLECT: usize = 2; // per-instance re-lowering for an unexpanded reflection binder
pub const P_RELOWER_ZST: usize = 3; // per-signature re-lowering for a zero-size condition
pub const P_INLINE: usize = 4; // inliner: callee vetting and splicing
pub const P_DROPS: usize = 5; // move/drop facts, cleanup elaboration, bounds-check elimination
pub const P_SYM: usize = 6; // symbol and mangled-name construction (within rendering)
pub const P_DECL: usize = 7; // declaration planning: local analysis and CFG structure
pub const P_RENDER: usize = 8; // statement and expression rendering (less planning)
pub const P_ASSEMBLE: usize = 9; // header and TU assembly
pub const P_PUBLISH: usize = 10; // file publication (less the build engine sink)
pub const P_SYNC: usize = 11; // build engine sink: raw to gen sync and compile planning
pub const P_COUNT: usize = 14;

/// Repeated-work tallies. The re-lowering rows come in reflection / zero-size pairs: a template
/// is a generic body whose shared lowering carries the flag, an instance is a demand that reached
/// that template, a re-lowering is one more lowering of the template under a demand env.
pub const C_TAKEN: usize = 0; // bodies taken from the keep
pub const C_LOWERED: usize = 1; // bodies lowered because the keep had none
pub const C_RELOWER_REFLECT: usize = 2; // instance re-lowerings for a reflection binder
pub const C_RELOWER_ZST: usize = 3; // instance re-lowerings for a zero-size condition
pub const C_BODIES: usize = 4; // bodies rendered (seeds and closures)
pub const C_INSTANCES: usize = 5; // instances rendered
pub const C_OUT_BYTES: usize = 6; // bytes rendered
pub const C_TPL_REFLECT: usize = 7; // templates marked for reflection re-lowering
pub const C_TPL_ZST: usize = 8; // templates marked for zero-size re-lowering
pub const C_INST_REFLECT: usize = 9; // instances demanded from reflection templates
pub const C_INST_ZST: usize = 10; // instances demanded from zero-size templates
pub const C_SAME_REFLECT: usize = 11; // reflection re-lowerings identical (printed IR) to an earlier one of the template
pub const C_SAME_ZST: usize = 12; // zero-size re-lowerings identical to an earlier one of the template
pub const C_KEEP_REFLECT: usize = 13; // bytes the retained reflection re-lowerings hold
pub const C_KEEP_ZST: usize = 14; // bytes the retained zero-size re-lowerings hold
pub const C_COUNT: usize = 15;

const REGION_NAMES: [str<'static>; 12] = [
    "graph",
    "acquire",
    "relower-refl",
    "relower-zst",
    "inline",
    "drops",
    "sym",
    "decl",
    "render",
    "assemble",
    "publish",
    "sync",
];
static_assert(P_COUNT >= 12, "one slot per emission region");

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

    /// Fold `other` (a shard's or a pooled context's probe) into this one. The tallies fold even
    /// when the regions are off: the build record reports the re-lowering counts of every build.
    pub fn merge(self: &mut Self, other: &Probe) {
        for k in 0..C_COUNT {
            self.c[k] += other.c[k];
        }
        if !self.on {
            return;
        }
        for k in 0..P_COUNT {
            self.ns[k] += other.ns[k];
            self.calls[k] += other.calls[k];
            self.an[k] += other.an[k];
            self.ab[k] += other.ab[k];
        }
    }

    /// The region table under `title`: one row per named region (a region past `names` is not
    /// shown), then the total.
    pub fn report_regions(self: &Self, out: &mut String, title: str, names: []str) {
        out.push_str(title);
        for _i in title.len()..22 {
            out.push_byte(b' ');
        }
        out.push_str("ms      calls");
        if self.mem {
            out.push_str("     allocs      MiB");
        }
        out.push_str("\n");
        let mut total: u64 = 0;
        for k in 0..names.len() {
            total += self.ns[k];
            out.push_str("  ");
            let nm = names[k];
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
    }

    /// The emission report: the region table, then the repeated-work tallies.
    pub fn report(self: &Self, out: &mut String) {
        let names: []str = REGION_NAMES;
        self.report_regions(out, "emit-probe", names);
        out.push_str("  instance discovery and specialization (graph, acquire, re-lowering) ");
        push_ms(out, self.ns[P_GRAPH] + self.ns[P_ACQUIRE] + self.ns[P_RELOWER_REFLECT] + self.ns[P_RELOWER_ZST]);
        out.push_str(" ms\n");
        self.report_relower(
            out,
            "reflection",
            C_TPL_REFLECT,
            C_INST_REFLECT,
            C_RELOWER_REFLECT,
            C_SAME_REFLECT,
            C_KEEP_REFLECT,
        );
        self.report_relower(out, "zero-size", C_TPL_ZST, C_INST_ZST, C_RELOWER_ZST, C_SAME_ZST, C_KEEP_ZST);
        out.push_str("  bodies taken ");
        out.push_u64(self.c[C_TAKEN]);
        out.push_str(", lowered ");
        out.push_u64(self.c[C_LOWERED]);
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

    // One re-lowering reason: templates, the instances demanded from them, the re-lowerings those
    // cost, how many repeated an earlier re-lowering's IR, and the bytes the retained ones hold.
    fn report_relower(
        self: &Self,
        out: &mut String,
        reason: str,
        tpl: usize,
        inst: usize,
        rel: usize,
        same: usize,
        keep: usize,
    ) {
        out.push_str("  re-lowering for ");
        out.push_str(reason);
        out.push_str(": ");
        out.push_u64(self.c[tpl]);
        out.push_str(" templates, ");
        out.push_u64(self.c[inst]);
        out.push_str(" instances, ");
        out.push_u64(self.c[rel]);
        out.push_str(" re-lowerings (");
        out.push_u64(self.c[same]);
        out.push_str(" identical, ");
        out.push_u64(self.c[keep] >> 10);
        out.push_str(" KiB retained)\n");
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
