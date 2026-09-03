// Word-packed bit rows over a caller-held Vector<u64> (bit i lives in word i/64). Bounds-checked;
// the borrowck dataflow core keeps its own unchecked copies for the hot inner loops (see
// borrowck/dataflow.spc).

/// Set bit `i`. Panics: word `i / 64` is out of bounds.
pub fn bit_set(v: &mut Vector<u64>, i: u32) {
    let w = (i / 64) as usize;
    v.set(w, v[w] | 1u64 << (i & 63) as u64);
}

/// Clear bit `i`. Panics: word `i / 64` is out of bounds.
pub fn bit_clear(v: &mut Vector<u64>, i: u32) {
    let w = (i / 64) as usize;
    v.set(w, v[w] & ~(1u64 << (i & 63) as u64));
}

/// Whether bit `i` is set. Panics: word `i / 64` is out of bounds.
pub const fn bit_get(v: &Vector<u64>, i: u32) bool {
    return (*v.at((i / 64) as usize) >> (i & 63) as u64 & 1u64) != 0;
}
