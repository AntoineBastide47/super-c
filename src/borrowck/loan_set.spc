// Loan-set storage for the in-scope dataflow: one row per block boundary, one bit per
// loan. Bodies with at most 64 loans (the overwhelming majority) use exactly one word per row; wider
// bodies promote to dense multi-word rows. Rows live in ONE flat pool -- no per-point allocation;
// statement-exact states are replayed from block entries.
pub struct LoanMat {
    pub nloans: u32,
    pub words: u32, // row width in u64 words (max(1, ceil(nloans/64)))
    pub pool: Vector<u64>, // rows * words, zero-initialized
}

extend LoanMat as Free {
    pub fn free(self: &mut Self) {
        self.pool.free();
    }
}

extend LoanMat {
    pub fn new(nloans: u32, rows: u32) LoanMat {
        let mut m = LoanMat { nloans: 0, words: 1, pool: Vector::<u64>::new() };
        m.reset_to(nloans, rows);
        return m;
    }

    // Re-size in place, keeping `pool`'s heap capacity across bodies (the reusable-context path).
    pub fn reset_to(self: &mut Self, nloans: u32, rows: u32) {
        let mut w = (nloans + 63) / 64;
        if w == 0 {
            w = 1;
        }
        self.nloans = nloans;
        self.words = w;
        self.pool.truncate(0);
        self.pool.reserve((rows * w) as usize);
        for _i in 0..rows * w {
            self.pool.push(0u64);
        }
    }

    /// Copy a row into caller scratch (statement replay works on the scratch row).
    pub fn read_row(self: &Self, row: u32, out: &mut Vector<u64>) {
        out.clear();
        for w in 0..self.words {
            out.push(self.pool[(row * self.words + w) as usize]);
        }
    }

    /// row |= scratch; returns true when `row` changed.
    pub fn or_scratch(self: &mut Self, row: u32, s: &Vector<u64>) bool {
        let mut changed = false;
        for w in 0..self.words {
            let d = (row * self.words + w) as usize;
            let v = self.pool[d] | s[w as usize];
            if v != self.pool[d] {
                self.pool.set(d, v);
                changed = true;
            }
        }
        return changed;
    }

    pub const fn retained_bytes(self: &Self) usize {
        return self.pool.capacity() * 8;
    }
}

pub fn row_set(s: &mut Vector<u64>, loan: u32) {
    let i = (loan / 64) as usize;
    s.set(i, s[i] | 1u64 << (loan & 63) as u64);
}

pub fn row_clear(s: &mut Vector<u64>, loan: u32) {
    let i = (loan / 64) as usize;
    s.set(i, s[i] & ~(1u64 << (loan & 63) as u64));
}

pub const fn row_get(s: &Vector<u64>, loan: u32) bool {
    return (*s.at((loan / 64) as usize) >> (loan & 63) as u64 & 1u64) != 0;
}
