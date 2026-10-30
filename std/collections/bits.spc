// Bit containers over 64-bit words: `BitSet<N>`, a fixed set of N bits stored inline (C++ `std::bitset`);
// `BitVec<A>`, a growable bit array whose words come from allocator A; and `BitField<LO, WIDTH>`, a
// zero-sized descriptor of a bit range inside an unsigned integer word (hardware registers, wire formats).
// Bit i lives in word i / 64 at bit i % 64. Invariant: the bits of the last word past the length are zero;
// every operation keeps it, so counts, comparisons and hashes read whole words.
//
// Complexity: bit access (`get`, `set`, `insert`, `remove`, `toggle`) and `pop` are O(1); `push` is
// amortized O(1) (geometric growth); whole-container operations (`count_ones`, `any`, `all`, `set_all`,
// `clear_all`, `toggle_all`, the set operations, the subset tests, shifts, `==`, `hash_into`, `clone`) are
// O(N / 64) word operations, branch-free so that the C compiler vectorizes them; `first_one`, `last_one`
// and `next_one` are O(words scanned); a full `ones()` iteration is O(words + set bits); `to_string` and
// `parse` are O(N). `resize` is O(added bits / 64 + 1); `truncate` and `clear` are O(1).
// Set operations by value are the operators: union `a | b`, intersection `a & b`, difference `a & ~b`,
// symmetric difference `a ^ b` (BitSet only); in place they are the `*_with` methods. `s[i]` reads bit i and
// `s[a..b]` packs at most 64 bits into a u64, bit a at bit 0.
// Invalidation: a BitSet is a value and never invalidates. A BitVec operation that grows (`push`, `reserve`,
// `resize`) may move the words: it invalidates every pointer taken from `words()` or `words_mut()`; the
// borrow rules already keep views and `Ones` iterators from living across a mutation.
// Allocation: BitSet never allocates. BitVec holds one block of `capacity() / 64` words from its allocator,
// frees it on drop, and `clone` allocates through a copy of the allocator handle.
// Thread safety: no internal synchronization. BitSet is `Send` and `Sync`; BitVec is when its allocator is.
// Shared reads may run concurrently; a mutation needs exclusive access, as the borrow rules require.

// The referents of `index`: a bit is not addressable, so `s[i]` borrows one of these.
const BOOLS: [bool; 2] = [false, true];

/// N bits stored inline in `(N + 63) / 64` words; a plain `Copy` value with no allocation. The default
/// value has every bit clear.
pub struct BitSet<const N: usize> {
    words: [u64; (N + 63) / 64], // bits past N in the last word stay zero
}

/// A growable array of bits in words from allocator A. The default value is empty and allocates nothing.
pub struct BitVec<A = Global> {
    words: *mut u64, // owned block of `cap` words; null while cap == 0
    len: usize, // bits in use; the bits past len in word (len - 1) / 64 stay zero
    cap: usize, // words allocated
    alloc: A,
}

// A BitVec owns its words, so it may cross threads when its allocator may.
unsafe extend<A: Send> BitVec<A> as Send {}

unsafe extend<A: Sync> BitVec<A> as Sync {}

/// The indices of the set bits of a `BitSet` or `BitVec`, in increasing order from `next` and in
/// decreasing order from `next_back`. A clear word costs one test; a set bit costs one count-zeros.
pub struct Ones<'a> {
    words: *const u64,
    front: usize, // the word `front_bits` comes from
    back: usize, // the word `back_bits` comes from; equal to `front` once the two ends meet
    front_bits: u64, // set bits of word `front` not yet returned
    back_bits: u64, // set bits of word `back` not yet returned; zero once the ends meet
}

/// Why `BitSet::parse` rejected its text.
@derive(Eq, Format)
pub enum ParseBitsError {
    /// The byte at this offset is not '0' or '1'.
    InvalidDigit(usize),
    /// The text holds more than N digits.
    TooLong,
}

/// An unsigned integer type that holds a `BitField`: u8, u16, u32, u64 or usize. Only this module
/// implements it.
pub interface BitWord: Copy {
    /// The width of the type in bits.
    fn word_bits() u32;
    /// The value, zero-extended.
    fn word_to_u64(self: Self) u64;
    /// The low `word_bits()` bits of `v`.
    fn word_from_u64(v: u64) Self;
}

/// The bits LO .. LO + WIDTH of an unsigned word, as a zero-sized descriptor: `type Mode = BitField<4, 3>;`
/// then `Mode::get(reg)` and `Mode::set(reg, 5)`. WIDTH 0, a field past bit 63, and a word type narrower
/// than LO + WIDTH fail the build.
@derive(Copy)
pub struct BitField<const LO: u32, const WIDTH: u32> {}

// Word kernels shared by BitSet and BitVec. Every slice pair has one length. The loops do not branch on the
// data, and a `[]mut u64` parameter is `restrict` in C, so the C compiler vectorizes them.

const fn words_count(w: []u64) usize {
    let mut c: usize = 0;
    for i in 0..w.len {
        c += (unsafe w.ptr[i]).count_ones();
    }
    return c;
}

const fn words_any(w: []u64) bool {
    let mut acc: u64 = 0;
    for i in 0..w.len {
        acc = acc | unsafe w.ptr[i];
    }
    return acc != 0;
}

// Every bit set: each word but the last is all ones and the last equals `last`, the mask of its used bits.
const fn words_all(w: []u64, last: u64) bool {
    if w.len == 0 {
        return true;
    }
    let mut acc = u64::MAX;
    for i in 0..w.len - 1 {
        acc = acc & unsafe w.ptr[i];
    }
    return acc == u64::MAX && unsafe w.ptr[w.len - 1] == last;
}

const fn words_eq(a: []u64, b: []u64) bool {
    let mut acc: u64 = 0;
    for i in 0..a.len {
        acc = acc | unsafe a.ptr[i] ^ unsafe b.ptr[i];
    }
    return acc == 0;
}

const fn words_is_subset(a: []u64, b: []u64) bool {
    let mut acc: u64 = 0;
    for i in 0..a.len {
        acc = acc | unsafe a.ptr[i] & ~unsafe b.ptr[i];
    }
    return acc == 0;
}

const fn words_is_disjoint(a: []u64, b: []u64) bool {
    let mut acc: u64 = 0;
    for i in 0..a.len {
        acc = acc | unsafe a.ptr[i] & unsafe b.ptr[i];
    }
    return acc == 0;
}

const fn words_or(d: []mut u64, s: []u64) {
    for i in 0..d.len {
        unsafe {
            d.ptr[i] = d.ptr[i] | s.ptr[i];
        }
    }
}

const fn words_and(d: []mut u64, s: []u64) {
    for i in 0..d.len {
        unsafe {
            d.ptr[i] = d.ptr[i] & s.ptr[i];
        }
    }
}

const fn words_and_not(d: []mut u64, s: []u64) {
    for i in 0..d.len {
        unsafe {
            d.ptr[i] = d.ptr[i] & ~s.ptr[i];
        }
    }
}

const fn words_xor(d: []mut u64, s: []u64) {
    for i in 0..d.len {
        unsafe {
            d.ptr[i] = d.ptr[i] ^ s.ptr[i];
        }
    }
}

const fn words_not(d: []mut u64) {
    for i in 0..d.len {
        unsafe {
            d.ptr[i] = ~d.ptr[i];
        }
    }
}

const fn words_fill(d: []mut u64, v: u64) {
    for i in 0..d.len {
        unsafe d.ptr[i] = v;
    }
}

// The mask of the used bits of the last word of `nbits` bits: all ones when nbits is a multiple of 64.
const fn last_mask(nbits: usize) u64 {
    return u64::MAX >> ((64 - nbits % 64) % 64) as u64;
}

// Clears the bits past `nbits` in the last word of `d`.
const fn words_trim(d: []mut u64, nbits: usize) {
    if d.len > 0 {
        unsafe {
            d.ptr[d.len - 1] = d.ptr[d.len - 1] & last_mask(nbits);
        }
    }
}

// The largest value of a field of `width` bits at bit `lo`. Evaluated in a constant initializer, so a field
// that is empty or passes bit 63 fails the build.
const fn field_max(lo: u32, width: u32) u64 {
    if width == 0 || width > 64 || lo > 64 - width {
        panic("a BitField needs 1 to 64 bits that end at or below bit 64");
    }
    return u64::MAX >> (64 - width) as u64;
}

// The words that hold `nbits` bits, without the overflow of `(nbits + 63) / 64`.
const fn words_for(nbits: usize) usize {
    return nbits / 64 + (nbits % 64 + 63) / 64;
}

// `d` = `s` moved toward higher indices by k bits, low words zero. The caller trims the last word.
const fn words_shl(d: []mut u64, s: []u64, k: usize) {
    let n = d.len;
    let ws = k / 64;
    if ws >= n {
        words_fill(d, 0);
        return;
    }
    let bs = (k % 64) as u64;
    if bs == 0 {
        for i in ws..n {
            unsafe {
                d.ptr[i] = s.ptr[i - ws];
            }
        }
    } else {
        unsafe {
            d.ptr[ws] = s.ptr[0] << bs;
        }
        for i in ws + 1..n {
            unsafe {
                d.ptr[i] = s.ptr[i - ws] << bs | s.ptr[i - ws - 1] >> 64 - bs;
            }
        }
    }
    for i in 0..ws {
        unsafe d.ptr[i] = 0;
    }
}

// `d` = `s` moved toward lower indices by k bits, high words zero.
const fn words_shr(d: []mut u64, s: []u64, k: usize) {
    let n = d.len;
    let ws = k / 64;
    if ws >= n {
        words_fill(d, 0);
        return;
    }
    let bs = (k % 64) as u64;
    let keep = n - ws;
    if bs == 0 {
        for i in 0..keep {
            unsafe {
                d.ptr[i] = s.ptr[i + ws];
            }
        }
    } else {
        for i in 0..keep - 1 {
            unsafe {
                d.ptr[i] = s.ptr[i + ws] >> bs | s.ptr[i + ws + 1] << 64 - bs;
            }
        }
        unsafe {
            d.ptr[keep - 1] = s.ptr[n - 1] >> bs;
        }
    }
    for i in keep..n {
        unsafe d.ptr[i] = 0;
    }
}

const fn words_get(w: []u64, i: usize) bool {
    return (unsafe w.ptr[i / 64] >> (i % 64) as u64 & 1) != 0;
}

const fn words_set(d: []mut u64, i: usize, value: bool) {
    let b = (i % 64) as u64;
    unsafe {
        d.ptr[i / 64] = d.ptr[i / 64] & ~(1u64 << b) | value as u64 << b;
    }
}

const fn words_toggle(d: []mut u64, i: usize) {
    unsafe {
        d.ptr[i / 64] = d.ptr[i / 64] ^ 1u64 << (i % 64) as u64;
    }
}

const fn words_next_one(w: []u64, from: usize) Option<usize> {
    let mut i = from / 64;
    if i >= w.len {
        return None;
    }
    let mut bits = unsafe w.ptr[i] & u64::MAX << (from % 64) as u64;
    while bits == 0 {
        i += 1;
        if i == w.len {
            return None;
        }
        bits = unsafe w.ptr[i];
    }
    return Some(i * 64 + bits.trailing_zeros());
}

const fn words_last_one(w: []u64) Option<usize> {
    let mut i = w.len;
    while i > 0 {
        i -= 1;
        let bits = unsafe w.ptr[i];
        if bits != 0 {
            return Some(i * 64 + 63 - bits.leading_zeros());
        }
    }
    return None;
}

// Bits r of a container of `nbits` bits, bit r.start at bit 0. Panics outside 0..nbits or above 64 bits.
const fn words_range(w: []u64, nbits: usize, r: Range<usize>) u64 {
    if r.inclusive && r.end >= nbits {
        panic("bits[a..b]: range out of bounds");
    }
    let hi = if r.inclusive {
        r.end + 1
    } else {
        r.end
    };
    if r.start > hi || hi > nbits || hi - r.start > 64 {
        panic("bits[a..b]: range out of bounds or wider than 64 bits");
    }
    let width = hi - r.start;
    if width == 0 {
        return 0;
    }
    let i = r.start / 64;
    let off = (r.start % 64) as u64;
    let mut v = unsafe w.ptr[i] >> off;
    if off != 0 && i + 1 < w.len {
        v = v | unsafe w.ptr[i + 1] << 64 - off;
    }
    return v & u64::MAX >> (64 - width) as u64;
}

fn words_hash_into<H: Hasher>(w: []u64, nbits: usize, h: &mut H) {
    h.write_u64(nbits as u64);
    for i in 0..w.len {
        h.write_u64(unsafe w.ptr[i]);
    }
}

// `{i, j, ..}`: the set bits in increasing order.
fn words_fmt(w: []u64) String {
    let mut s = String::from_str("{");
    let mut it = Ones::of(w);
    let mut first = true;
    while let Some(i) = it.next() {
        if !first {
            s.push_str(", ");
        }
        s.push_u64(i as u64);
        first = false;
    }
    s.push_str("}");
    return s;
}

extend<const N: usize> BitSet<N> {
    /// Every bit clear.
    pub const fn new() BitSet<N> {
        return unsafe zeroed::<BitSet<N>>();
    }

    /// Every bit set.
    pub fn full() BitSet<N> {
        let mut s = unsafe zeroed::<BitSet<N>>();
        s.set_all();
        return s;
    }

    /// The set whose bit i is bit i of `v`; `None` when `v` has a bit at or above N. Fails the build for
    /// N above 64.
    pub fn from_u64(v: u64) Option<BitSet<N>> {
        static_assert(N <= 64, "BitSet::from_u64 needs N <= 64");
        if N < 64 && v >> N as u64 != 0 {
            return None;
        }
        let mut s = unsafe zeroed::<BitSet<N>>();
        if N > 0 {
            unsafe s.words[0] = v;
        }
        return Some(s);
    }

    /// The bits as an integer, bit i at bit i; never loses a bit. Fails the build for N above 64.
    pub const fn to_u64(self: &BitSet<N>) u64 {
        static_assert(N <= 64, "BitSet::to_u64 needs N <= 64");
        if N == 0 {
            return 0;
        }
        return unsafe self.words[0];
    }

    /// Whether bit i is set. Panics when i >= N.
    pub const fn get(self: &BitSet<N>, i: usize) bool {
        if i >= N {
            panic("BitSet: bit index out of range");
        }
        return words_get(self.words, i);
    }

    /// Writes `value` to bit i without a branch. Panics when i >= N.
    pub const fn set(self: &mut BitSet<N>, i: usize, value: bool) {
        if i >= N {
            panic("BitSet: bit index out of range");
        }
        words_set(self.words, i, value);
    }

    /// Sets bit i. Panics when i >= N.
    pub const fn insert(self: &mut BitSet<N>, i: usize) {
        self.set(i, true);
    }

    /// Clears bit i. Panics when i >= N.
    pub const fn remove(self: &mut BitSet<N>, i: usize) {
        self.set(i, false);
    }

    /// Inverts bit i. Panics when i >= N.
    pub const fn toggle(self: &mut BitSet<N>, i: usize) {
        if i >= N {
            panic("BitSet: bit index out of range");
        }
        words_toggle(self.words, i);
    }

    /// Sets every bit.
    pub const fn set_all(self: &mut BitSet<N>) {
        words_fill(self.words, u64::MAX);
        words_trim(self.words, N);
    }

    /// Clears every bit.
    pub const fn clear_all(self: &mut BitSet<N>) {
        words_fill(self.words, 0);
    }

    /// Inverts every bit (`~s` by value).
    pub const fn toggle_all(self: &mut BitSet<N>) {
        words_not(self.words);
        words_trim(self.words, N);
    }

    /// The number of set bits.
    pub const fn count_ones(self: &BitSet<N>) usize {
        return words_count(self.words);
    }

    /// Whether some bit is set.
    pub const fn any(self: &BitSet<N>) bool {
        return words_any(self.words);
    }

    /// Whether every bit is set; true for N = 0.
    pub const fn all(self: &BitSet<N>) bool {
        return words_all(self.words, last_mask(N));
    }

    /// The lowest set bit.
    pub const fn first_one(self: &BitSet<N>) Option<usize> {
        return words_next_one(self.words, 0);
    }

    /// The highest set bit.
    pub const fn last_one(self: &BitSet<N>) Option<usize> {
        return words_last_one(self.words);
    }

    /// The lowest set bit at or after `from`; `None` when there is none or `from >= N`.
    pub const fn next_one(self: &BitSet<N>, from: usize) Option<usize> {
        return words_next_one(self.words, from);
    }

    /// The set bits in increasing order (decreasing from `next_back`).
    pub const fn ones(self: &BitSet<N>) Ones {
        return Ones::of(self.words);
    }

    /// Adds the bits of `other` (`s |= other`).
    pub const fn union_with(self: &mut BitSet<N>, other: &BitSet<N>) {
        words_or(self.words, other.words);
    }

    /// Keeps the bits also in `other` (`s &= other`).
    pub const fn intersect_with(self: &mut BitSet<N>, other: &BitSet<N>) {
        words_and(self.words, other.words);
    }

    /// Clears the bits set in `other` (`s &= ~other`).
    pub const fn difference_with(self: &mut BitSet<N>, other: &BitSet<N>) {
        words_and_not(self.words, other.words);
    }

    /// Inverts the bits set in `other` (`s ^= other`).
    pub const fn symmetric_difference_with(self: &mut BitSet<N>, other: &BitSet<N>) {
        words_xor(self.words, other.words);
    }

    /// Whether every bit of `self` is set in `other`.
    pub const fn is_subset(self: &BitSet<N>, other: &BitSet<N>) bool {
        return words_is_subset(self.words, other.words);
    }

    /// Whether every bit of `other` is set in `self`.
    pub const fn is_superset(self: &BitSet<N>, other: &BitSet<N>) bool {
        return words_is_subset(other.words, self.words);
    }

    /// Whether no bit is set in both.
    pub const fn is_disjoint(self: &BitSet<N>, other: &BitSet<N>) bool {
        return words_is_disjoint(self.words, other.words);
    }

    /// N characters '0' and '1', bit N - 1 first (C++ `to_string`).
    pub fn to_string(self: &BitSet<N>) String {
        let mut s = String::with_capacity(N);
        let mut i = N;
        while i > 0 {
            i -= 1;
            s.push_byte(b'0' + words_get(self.words, i) as u8);
        }
        return s;
    }

    /// The set that `to_string` renders as `text`: at most N digits '0' or '1', the last one bit 0; the
    /// bits past the text's length are clear (C++ `bitset(string)`).
    pub fn parse(text: str) Result<BitSet<N>, ParseBitsError> {
        let n = text.len();
        if n > N {
            return Err(TooLong);
        }
        let mut s = unsafe zeroed::<BitSet<N>>();
        for k in 0..n {
            let c = text.byte_at(k);
            if c != b'0' && c != b'1' {
                return Err(InvalidDigit(k));
            }
            words_set(s.words, n - 1 - k, c == b'1');
        }
        return Ok(s);
    }
}

extend<A: Allocator> BitVec<A> {
    /// Empty, with no allocation, through allocator `alloc`.
    pub const fn new_in(alloc: A) BitVec<A> {
        return BitVec::<A> { words: null, len: 0, cap: 0, alloc: alloc };
    }

    /// `n` bits of `value`, in one allocation through `alloc` (none when n is 0). Panics when the words
    /// of n bits overflow the address space.
    pub fn with_len_in(alloc: A, n: usize, value: bool) BitVec<A> {
        let mut v = BitVec::<A>::new_in(alloc);
        v.resize(n, value);
        return v;
    }

    /// The number of bits.
    pub const fn len(self: &BitVec<A>) usize {
        return self.len;
    }

    /// Whether the length is 0.
    pub const fn is_empty(self: &BitVec<A>) bool {
        return self.len == 0;
    }

    /// The bits the allocation holds without growing: a multiple of 64.
    pub const fn capacity(self: &BitVec<A>) usize {
        return self.cap * 64;
    }

    /// Room for `additional` more bits, growing the words geometrically. Panics on size overflow.
    pub fn reserve(self: &mut BitVec<A>, additional: usize) {
        if additional > usize::MAX - self.len {
            panic("BitVec: capacity overflow");
        }
        let need = words_for(self.len + additional);
        if need > self.cap {
            self.grow(need);
        }
    }

    // Grows to at least `need` words, doubling. `need` is at most usize::MAX / 64 + 1 words (a bit count is a
    // usize), so neither the doubling nor the byte size overflows.
    @noinline
    fn grow(self: &mut BitVec<A>, need: usize) {
        let cap = need.max(self.cap * 2);
        let p = unsafe self.alloc.realloc(self.words, self.cap * sizeof(u64), cap * sizeof(u64), alignof(u64));
        self.words = p as *mut u64;
        self.cap = cap;
    }

    /// The used words, bit i in word i / 64; the bits past `len()` in the last word are zero.
    pub const fn words(self: &BitVec<A>) []u64 {
        return unsafe Slice::<u64> { ptr: self.words, len: words_for(self.len) };
    }

    /// The used words, writable. The caller keeps the bits past `len()` in the last word zero.
    pub const fn words_mut(self: &mut BitVec<A>) []mut u64 {
        return unsafe SliceMut::<u64> { ptr: self.words, len: words_for(self.len) };
    }

    /// Appends `value`; amortized O(1).
    pub fn push(self: &mut BitVec<A>, value: bool) {
        self.reserve(1);
        let i = self.len / 64;
        let b = (self.len % 64) as u64;
        // A word becomes used at its bit 0, so its old contents do not count.
        let old = if b == 0 {
            0u64
        } else {
            unsafe self.words[i]
        };
        unsafe self.words[i] = old | value as u64 << b;
        self.len += 1;
    }

    /// Removes and returns the last bit; `None` when empty.
    pub const fn pop(self: &mut BitVec<A>) Option<bool> {
        if self.len == 0 {
            return None;
        }
        self.len -= 1;
        let i = self.len / 64;
        let b = (self.len % 64) as u64;
        let w = unsafe self.words[i];
        unsafe self.words[i] = w & ~(1u64 << b);
        return Some((w >> b & 1) != 0);
    }

    /// Whether bit i is set. Panics when i >= len.
    pub const fn get(self: &BitVec<A>, i: usize) bool {
        if i >= self.len {
            panic("BitVec: bit index out of range");
        }
        return words_get(self.words(), i);
    }

    /// Writes `value` to bit i without a branch. Panics when i >= len.
    pub const fn set(self: &mut BitVec<A>, i: usize, value: bool) {
        if i >= self.len {
            panic("BitVec: bit index out of range");
        }
        words_set(self.words_mut(), i, value);
    }

    /// Inverts bit i. Panics when i >= len.
    pub const fn toggle(self: &mut BitVec<A>, i: usize) {
        if i >= self.len {
            panic("BitVec: bit index out of range");
        }
        words_toggle(self.words_mut(), i);
    }

    /// Makes the length `n`: drops the bits past n, or appends bits of `value`. Panics on size overflow.
    pub fn resize(self: &mut BitVec<A>, n: usize, value: bool) {
        if n <= self.len {
            self.truncate(n);
            return;
        }
        self.reserve(n - self.len);
        let fill = 0u64.wrapping_sub(value as u64);
        let mut i = self.len / 64;
        let b = (self.len % 64) as u64;
        if b != 0 {
            unsafe {
                self.words[i] = self.words[i] | fill << b;
            }
            i += 1;
        }
        let used = words_for(n);
        for k in i..used {
            unsafe self.words[k] = fill;
        }
        self.len = n;
        words_trim(self.words_mut(), n);
    }

    /// Drops the bits past `n`; no effect when n >= len. Keeps the allocation.
    pub const fn truncate(self: &mut BitVec<A>, n: usize) {
        if n < self.len {
            self.len = n;
            words_trim(self.words_mut(), n);
        }
    }

    /// Drops every bit. Keeps the allocation.
    pub const fn clear(self: &mut BitVec<A>) {
        self.len = 0;
    }

    /// Sets every bit.
    pub const fn set_all(self: &mut BitVec<A>) {
        words_fill(self.words_mut(), u64::MAX);
        let n = self.len;
        words_trim(self.words_mut(), n);
    }

    /// Clears every bit.
    pub const fn clear_all(self: &mut BitVec<A>) {
        words_fill(self.words_mut(), 0);
    }

    /// Inverts every bit.
    pub const fn toggle_all(self: &mut BitVec<A>) {
        words_not(self.words_mut());
        let n = self.len;
        words_trim(self.words_mut(), n);
    }

    /// The number of set bits.
    pub const fn count_ones(self: &BitVec<A>) usize {
        return words_count(self.words());
    }

    /// Whether some bit is set.
    pub const fn any(self: &BitVec<A>) bool {
        return words_any(self.words());
    }

    /// Whether every bit is set; true when empty.
    pub const fn all(self: &BitVec<A>) bool {
        return words_all(self.words(), last_mask(self.len));
    }

    /// The lowest set bit.
    pub const fn first_one(self: &BitVec<A>) Option<usize> {
        return words_next_one(self.words(), 0);
    }

    /// The highest set bit.
    pub const fn last_one(self: &BitVec<A>) Option<usize> {
        return words_last_one(self.words());
    }

    /// The lowest set bit at or after `from`; `None` when there is none or `from >= len`.
    pub const fn next_one(self: &BitVec<A>, from: usize) Option<usize> {
        return words_next_one(self.words(), from);
    }

    /// The set bits in increasing order (decreasing from `next_back`).
    pub const fn ones(self: &BitVec<A>) Ones {
        return Ones::of(self.words());
    }

    // Panics unless both have one length: the set operations pair bits by index.
    const fn check_len(self: &BitVec<A>, other: &BitVec<A>) {
        if self.len != other.len {
            panic("BitVec: length mismatch");
        }
    }

    /// Adds the bits of `other`. Panics when the lengths differ.
    pub const fn union_with(self: &mut BitVec<A>, other: &BitVec<A>) {
        self.check_len(other);
        words_or(self.words_mut(), other.words());
    }

    /// Keeps the bits also in `other`. Panics when the lengths differ.
    pub const fn intersect_with(self: &mut BitVec<A>, other: &BitVec<A>) {
        self.check_len(other);
        words_and(self.words_mut(), other.words());
    }

    /// Clears the bits set in `other`. Panics when the lengths differ.
    pub const fn difference_with(self: &mut BitVec<A>, other: &BitVec<A>) {
        self.check_len(other);
        words_and_not(self.words_mut(), other.words());
    }

    /// Inverts the bits set in `other`. Panics when the lengths differ.
    pub const fn symmetric_difference_with(self: &mut BitVec<A>, other: &BitVec<A>) {
        self.check_len(other);
        words_xor(self.words_mut(), other.words());
    }

    /// Whether every bit of `self` is set in `other`. Panics when the lengths differ.
    pub const fn is_subset(self: &BitVec<A>, other: &BitVec<A>) bool {
        self.check_len(other);
        return words_is_subset(self.words(), other.words());
    }

    /// Whether every bit of `other` is set in `self`. Panics when the lengths differ.
    pub const fn is_superset(self: &BitVec<A>, other: &BitVec<A>) bool {
        self.check_len(other);
        return words_is_subset(other.words(), self.words());
    }

    /// Whether no bit is set in both. Panics when the lengths differ.
    pub const fn is_disjoint(self: &BitVec<A>, other: &BitVec<A>) bool {
        self.check_len(other);
        return words_is_disjoint(self.words(), other.words());
    }
}

extend<A: Allocator + Default> BitVec<A> {
    /// Empty, with no allocation, through the default allocator.
    pub const fn new() BitVec<A> {
        return BitVec::<A>::new_in(A::default());
    }

    /// `n` bits of `value` through the default allocator. Panics on size overflow.
    pub fn with_len(n: usize, value: bool) BitVec<A> {
        return BitVec::<A>::with_len_in(A::default(), n, value);
    }
}

extend<const LO: u32, const WIDTH: u32> BitField<LO, WIDTH> {
    const VALUE_MAX: u64 = field_max(LO, WIDTH);

    /// The field's bits in place: ones at LO .. LO + WIDTH.
    pub const MASK: u64 = BitField::<LO, WIDTH>::VALUE_MAX << LO as u64;

    /// The field of `word`, shifted down to bit 0.
    pub fn get<T: BitWord>(word: T) T {
        static_assert(LO + WIDTH <= T::word_bits(), "the BitField does not fit the word type");
        return T::word_from_u64(word.word_to_u64() >> LO as u64 & BitField::<LO, WIDTH>::VALUE_MAX);
    }

    /// `word` with the field replaced by `value`; the other bits are unchanged. Panics when `value` does
    /// not fit WIDTH bits.
    pub fn set<T: BitWord>(word: T, value: T) T {
        static_assert(LO + WIDTH <= T::word_bits(), "the BitField does not fit the word type");
        let v = value.word_to_u64();
        if v > BitField::<LO, WIDTH>::VALUE_MAX {
            panic("BitField::set: value wider than the field");
        }
        return T::word_from_u64(word.word_to_u64() & ~BitField::<LO, WIDTH>::MASK | v << LO as u64);
    }
}

extend Ones {
    const fn of<'a>(w: []'a u64) Ones<'a> {
        if w.len == 0 {
            return Ones { words: w.ptr, front: 0, back: 0, front_bits: 0, back_bits: 0 };
        }
        let back_bits = if w.len > 1 {
            unsafe w.ptr[w.len - 1]
        } else {
            0u64
        };
        return Ones { words: w.ptr, front: 0, back: w.len - 1, front_bits: unsafe w.ptr[0], back_bits: back_bits };
    }
}

extend Ones as Iterator<usize> {
    pub fn next(self: &mut Ones) Option<usize> {
        // Each pass moves `front` one word toward `back`.
        while self.front_bits == 0 {
            if self.front == self.back {
                return None;
            }
            self.front += 1;
            if self.front == self.back {
                self.front_bits = self.back_bits;
                self.back_bits = 0;
            } else {
                self.front_bits = unsafe self.words[self.front];
            }
        }
        let t = self.front_bits.trailing_zeros();
        self.front_bits = self.front_bits & self.front_bits - 1;
        return Some(self.front * 64 + t);
    }

    /// Exact for the words already loaded; each word between the ends adds up to 64 to the upper bound.
    pub fn size_hint(self: &Ones) (usize, Option<usize>) {
        let known = self.front_bits.count_ones() + self.back_bits.count_ones();
        let between = if self.back > self.front + 1 {
            self.back - self.front - 1
        } else {
            0
        };
        return (known, Option::<usize>::Some(known + between * 64));
    }
}

extend Ones as DoubleEndedIterator<usize> {
    pub fn next_back(self: &mut Ones) Option<usize> {
        // Each pass moves `back` one word toward `front`; once they meet, `front_bits` holds the word.
        while self.front != self.back {
            if self.back_bits != 0 {
                let t = 63 - self.back_bits.leading_zeros();
                self.back_bits = self.back_bits ^ 1u64 << t as u64;
                return Some(self.back * 64 + t);
            }
            self.back -= 1;
            if self.back != self.front {
                self.back_bits = unsafe self.words[self.back];
            }
        }
        if self.front_bits == 0 {
            return None;
        }
        let t = 63 - self.front_bits.leading_zeros();
        self.front_bits = self.front_bits ^ 1u64 << t as u64;
        return Some(self.front * 64 + t);
    }
}

extend<const N: usize> BitSet<N> as BitAnd {
    type Output = BitSet<N>;
    /// Intersection.
    pub fn bit_and(self: &BitSet<N>, other: &BitSet<N>) BitSet<N> {
        let mut r = *self;
        words_and(r.words, other.words);
        return r;
    }
}

extend<const N: usize> BitSet<N> as BitOr {
    type Output = BitSet<N>;
    /// Union.
    pub fn bit_or(self: &BitSet<N>, other: &BitSet<N>) BitSet<N> {
        let mut r = *self;
        words_or(r.words, other.words);
        return r;
    }
}

extend<const N: usize> BitSet<N> as BitXor {
    type Output = BitSet<N>;
    /// Symmetric difference.
    pub fn bit_xor(self: &BitSet<N>, other: &BitSet<N>) BitSet<N> {
        let mut r = *self;
        words_xor(r.words, other.words);
        return r;
    }
}

extend<const N: usize> BitSet<N> as BitNot {
    type Output = BitSet<N>;
    /// Complement within the N bits.
    pub fn bit_not(self: &BitSet<N>) BitSet<N> {
        let mut r = *self;
        r.toggle_all();
        return r;
    }
}

extend<const N: usize> BitSet<N> as Shl {
    type Output = BitSet<N>;
    /// Bit i moves to i + k; bits that pass N - 1 are lost; k >= N gives the empty set.
    pub fn shl(self: &BitSet<N>, k: usize) BitSet<N> {
        let mut r = unsafe zeroed::<BitSet<N>>();
        words_shl(r.words, self.words, k);
        words_trim(r.words, N);
        return r;
    }
}

extend<const N: usize> BitSet<N> as Shr {
    type Output = BitSet<N>;
    /// Bit i moves to i - k; bits below k are lost; k >= N gives the empty set.
    pub fn shr(self: &BitSet<N>, k: usize) BitSet<N> {
        let mut r = unsafe zeroed::<BitSet<N>>();
        words_shr(r.words, self.words, k);
        return r;
    }
}

extend<const N: usize> BitSet<N> as Clone {
    pub fn clone(self: &BitSet<N>) BitSet<N> {
        return *self;
    }
}

extend<const N: usize> BitSet<N> as Eq {
    pub fn eq(self: &BitSet<N>, other: &BitSet<N>) bool {
        return words_eq(self.words, other.words);
    }
}

extend<const N: usize> BitSet<N> as Hash {
    /// N as a u64, then each word as a u64: a BitVec with the same bits feeds the same stream.
    pub fn hash_into<H: Hasher>(self: &BitSet<N>, h: &mut H) {
        words_hash_into(self.words, N, h);
    }
}

extend<const N: usize> BitSet<N> as Format {
    /// The set bits in increasing order: `{1, 5, 9}`.
    pub fn fmt(self: &BitSet<N>) String {
        return words_fmt(self.words);
    }
}

extend<const N: usize> BitSet<N> as Default {
    pub fn default() BitSet<N> {
        return BitSet::<N>::new();
    }
}

// `s[i]` reads bit i (panics when i >= N); `s[a..b]` packs bits a .. b into an integer, bit a at bit 0
// (panics outside 0..N or above 64 bits).
extend<const N: usize> BitSet<N> as Index<bool, u64> {
    pub fn index(self: &BitSet<N>, i: usize) &bool {
        return unsafe &BOOLS[self.get(i) as usize];
    }

    pub fn index_range(self: &BitSet<N>, r: Range<usize>) u64 {
        return words_range(self.words, N, r);
    }
}

extend<A: Allocator> BitVec<A> as Free {
    pub fn free(self: &mut BitVec<A>) {
        if self.cap > 0 {
            unsafe self.alloc.dealloc(self.words, self.cap * sizeof(u64), alignof(u64));
        }
        self.words = null;
        self.len = 0;
        self.cap = 0;
    }
}

extend<A: Allocator> BitVec<A> as Clone {
    /// A copy of the used words in one exact allocation through a copy of the allocator handle.
    pub fn clone(self: &BitVec<A>) BitVec<A> {
        let mut out = BitVec::<A>::new_in(self.alloc);
        let n = words_for(self.len);
        if n > 0 {
            out.grow(n);
            unsafe memcpy(out.words, self.words, n * sizeof(u64));
        }
        out.len = self.len;
        return out;
    }
}

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
}

extend<A: Allocator> BitVec<A> as Eq {
    pub fn eq(self: &BitVec<A>, other: &BitVec<A>) bool {
        return self.len == other.len && words_eq(self.words(), other.words());
    }
}

extend<A: Allocator> BitVec<A> as Hash {
    /// The length as a u64, then each word as a u64: a BitSet with the same bits feeds the same stream.
    pub fn hash_into<H: Hasher>(self: &BitVec<A>, h: &mut H) {
        words_hash_into(self.words(), self.len, h);
    }
}

extend<A: Allocator> BitVec<A> as Format {
    /// The set bits in increasing order: `{1, 5, 9}`. The length is not shown.
    pub fn fmt(self: &BitVec<A>) String {
        return words_fmt(self.words());
    }
}

extend<A: Allocator + Default> BitVec<A> as Default {
    pub const fn default() BitVec<A> {
        return BitVec::<A>::new();
    }
}

// `v[i]` reads bit i (panics when i >= len); `v[a..b]` packs bits a .. b into an integer, bit a at bit 0
// (panics outside 0..len or above 64 bits).
extend<A: Allocator> BitVec<A> as Index<bool, u64> {
    pub fn index(self: &BitVec<A>, i: usize) &bool {
        return unsafe &BOOLS[self.get(i) as usize];
    }

    pub fn index_range(self: &BitVec<A>, r: Range<usize>) u64 {
        return words_range(self.words(), self.len, r);
    }
}

// One allocation of the exact words: `let v: BitVec = [true, false].into();`.
extend<A: Allocator + Default> BitVec<A> as From<[]bool> {
    pub fn from(value: []bool) BitVec<A> {
        let mut v = BitVec::<A>::new();
        v.reserve(value.len);
        for i in 0..value.len {
            v.push(unsafe value.ptr[i]);
        }
        return v;
    }
}

extend u8 as BitWord {
    pub fn word_bits() u32 {
        return 8;
    }

    pub fn word_to_u64(self: u8) u64 {
        return self;
    }

    pub fn word_from_u64(v: u64) u8 {
        return v as u8;
    }
}

extend u16 as BitWord {
    pub fn word_bits() u32 {
        return 16;
    }

    pub fn word_to_u64(self: u16) u64 {
        return self;
    }

    pub fn word_from_u64(v: u64) u16 {
        return v as u16;
    }
}

extend u32 as BitWord {
    pub fn word_bits() u32 {
        return 32;
    }

    pub fn word_to_u64(self: u32) u64 {
        return self;
    }

    pub fn word_from_u64(v: u64) u32 {
        return v as u32;
    }
}

extend u64 as BitWord {
    pub fn word_bits() u32 {
        return 64;
    }

    pub fn word_to_u64(self: u64) u64 {
        return self;
    }

    pub fn word_from_u64(v: u64) u64 {
        return v;
    }
}

extend usize as BitWord {
    pub fn word_bits() u32 {
        return POINTER_WIDTH;
    }

    pub fn word_to_u64(self: usize) u64 {
        return self as u64;
    }

    pub fn word_from_u64(v: u64) usize {
        return v as usize;
    }
}
