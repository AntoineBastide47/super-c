// std::collections::bits lanes: whole-vector word loops per 64-bit word, set-bit iteration per set bit,
// and the Vector<bool> loop each one replaces. Every lane validates its result with `b.tally`.
import std::collections::bits as *;
import std::testing::bench as bench;

const BITS: usize = 1 << 20; // bits per vector: 16384 words, 128 KiB, inside L2
const WORDS: i64 = 16384;

// Bit i is set when i % stride == 0.
fn striped(stride: usize) BitVec {
    let mut v = BitVec::<Global>::with_len(BITS, false);
    let mut i: usize = 0;
    while i < BITS {
        v.set(i, true);
        i += stride;
    }
    return v;
}

@bench
pub fn bitvec_count_ones(b: &mut bench::Bencher) {
    let v = striped(3);
    b.each(WORDS);
    b.unit("word");
    while b.running() {
        let n = v.count_ones();
        bench::black_box(n as u64);
        b.tally(1, (n == (BITS + 2) / 3) as i64);
    }
}

@bench
pub fn vector_bool_count(b: &mut bench::Bencher) {
    let mut v = Vector::<bool>::new();
    for i in 0..BITS {
        v.push(i % 3 == 0);
    }
    b.each(WORDS);
    b.unit("64 bools");
    while b.running() {
        let mut n: usize = 0;
        for i in 0..v.len() {
            n += (*v.at(i)) as usize;
        }
        bench::black_box(n as u64);
        b.tally(1, (n == (BITS + 2) / 3) as i64);
    }
}

@bench
pub fn bitvec_union_with(b: &mut bench::Bencher) {
    let mut v = striped(3);
    let o = striped(5);
    b.each(WORDS);
    b.unit("word");
    while b.running() {
        v.union_with(&o);
        b.tally(1, v.get(5) as i64);
    }
}

@bench
pub fn bitvec_is_subset_holds(b: &mut bench::Bencher) {
    let v = striped(6);
    let o = striped(3);
    b.each(WORDS);
    b.unit("word");
    while b.running() {
        let r = v.is_subset(&o);
        b.tally(1, r as i64);
    }
}

// The early-exit alternative to the branch-free `is_subset`, on the same input where the subset holds.
@bench
pub fn early_exit_is_subset_holds(b: &mut bench::Bencher) {
    let v = striped(6);
    let o = striped(3);
    b.each(WORDS);
    b.unit("word");
    while b.running() {
        let a = v.words();
        let c = o.words();
        let mut r = true;
        for i in 0..a.len {
            if (unsafe a.ptr[i] & ~unsafe c.ptr[i]) != 0 {
                r = false;
                break;
            }
        }
        b.tally(1, r as i64);
    }
}

fn iterate(b: &mut bench::Bencher, stride: usize) {
    let v = striped(stride);
    let expect = (BITS + stride - 1) / stride;
    b.each(expect as i64);
    b.unit("set bit");
    while b.running() {
        let mut n: usize = 0;
        let mut sum: usize = 0;
        for i in v.ones() {
            n += 1;
            sum = sum ^ i;
        }
        bench::black_box(sum as u64);
        b.tally(1, (n == expect) as i64);
    }
}

@bench
pub fn bitvec_ones_dense(b: &mut bench::Bencher) {
    iterate(b, 2);
}

@bench
pub fn bitvec_ones_sparse(b: &mut bench::Bencher) {
    iterate(b, 97);
}

@bench
pub fn bitset_or_by_value(b: &mut bench::Bencher) {
    let mut s = BitSet::<4096>::new();
    let mut t = BitSet::<4096>::new();
    s.insert(1);
    t.insert(4000);
    b.each(1000 * 2 * 64);
    b.unit("word");
    while b.running() {
        let mut acc = s;
        for _ in 0..1000 {
            acc = acc | t;
            acc = acc ^ s;
        }
        b.tally(1, acc.get(4000) as i64);
    }
}
