// The seeded program generator's driver: a model draws a program from a seed, its oracles check it,
// and a failure is reduced by delta steps (the model's statement and expression candidates) to a
// smaller program that fails the same oracle. Models plug in through `Model`; the driver knows none.

/// Most oracle runs one reduction may spend: each run builds programs, so the bound keeps a failing
/// seed's report within minutes.
pub const REDUCE_CHECKS_MAX: usize = 200;

/// A splitmix64 stream: the same seed draws the same program on every host.
pub struct Rng {
    state: u64,
}

/// A seeded generator of one program family. `run_seed` generates, checks and reduces through these
/// methods alone, so a new model plugs in without a driver change.
pub interface Model {
    /// The name a failure report prints.
    fn name(self: &Self) str<'static>;
    /// Replace the program with one drawn from `rng`.
    fn generate(self: &mut Self, rng: &mut Rng);
    /// Number of oracles.
    fn oracles(self: &Self) usize;
    /// Run oracle `k` on the program: empty when it holds, else what differs.
    fn check(self: &Self, k: usize) String;
    /// The Super-C program oracle `k` builds.
    fn render(self: &Self, k: usize) String;
    /// Number of reduction candidates the program offers, larger removals first.
    fn candidates(self: &Self) usize;
    /// Apply candidate `i` (below `candidates()`); false when it does not apply to the program.
    fn reduce(self: &mut Self, i: usize) bool;
}

/// Generate the program of `seed` in `m` and run every oracle. Empty when all hold; else a report with
/// the seed, the failure, and the program reduced while the same oracle still fails.
pub fn run_seed<M: Model + Clone>(m: &mut M, seed: u64) String {
    let mut rng = Rng::new(seed);
    m.generate(&mut rng);
    let mut r = String::new();
    for k in 0..m.oracles() {
        let mut fail = m.check(k);
        if fail.len() == 0 {
            continue;
        }
        let checks = reduce(m, k, &mut fail);
        r.format_into("gen: model '{}' seed {} fails oracle {} ({} reduction checks)\n", m.name(), seed, k, checks);
        r.push_string(&fail);
        r.push_str("minimized program:\n");
        let prog = m.render(k);
        r.push_string(&prog);
        r.format_into(
            "replay: SC_GEN_MODEL={} SC_GEN_SEED={} SC_GEN_RUNS=1 ./super-c test --quiet --test-filter=gen_random_run\n",
            m.name(),
            seed,
        );
        return r;
    }
    return r;
}

// Delta reduction: take the first candidate that still fails oracle `k`, until none does or the
// check budget is spent. A candidate whose program stops building fails differently, so it is not
// taken. Returns the oracle runs spent; `fail` ends as the reduced program's failure.
fn reduce<M: Model + Clone>(m: &mut M, k: usize, fail: &mut String) usize {
    let unbuildable = fail.contains("does not build");
    let mut checks: usize = 0;
    let mut progress = true;
    while progress && checks < REDUCE_CHECKS_MAX {
        progress = false;
        let n = m.candidates();
        let mut i: usize = 0;
        while i < n && checks < REDUCE_CHECKS_MAX {
            let mut t = m.clone();
            if t.reduce(i) {
                checks += 1;
                let f = t.check(k);
                if f.len() != 0 && f.contains("does not build") == unbuildable {
                    *m = t;
                    *fail = f;
                    progress = true;
                    break;
                }
            }
            i += 1;
        }
    }
    return checks;
}

extend Rng {
    pub const fn new(seed: u64) Rng {
        return Rng { state: seed };
    }

    pub fn next(self: &mut Rng) u64 {
        self.state = self.state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.state;
        z = (z ^ z >> 30).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ z >> 27).wrapping_mul(0x94D049BB133111EB);
        return z ^ z >> 31;
    }

    /// A draw in 0..n; `n` is positive.
    pub fn below(self: &mut Rng, n: u64) u64 {
        assert(n > 0);
        return self.next() % n;
    }

    /// True with probability 1/n.
    pub fn one_in(self: &mut Rng, n: u64) bool {
        return self.below(n) == 0;
    }
}
