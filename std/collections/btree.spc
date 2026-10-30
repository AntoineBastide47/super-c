// BTreeMap<K, V, A = Global> and BTreeSet<T, A = Global>: ordered maps and sets over a B-tree of
// order B = 8. A node holds 7 to 15 keys (the root 1 to 15) and their values in flat arrays, an internal
// node also 8 to 16 child edges, and each node its parent and its edge index there. Keys are unique by
// `K::cmp`; iteration is in increasing key order from either end. A set is a map whose value is
// zero-sized.
//
// Complexity (n entries, h <= log_8((n + 1) / 2) the height; C++ [associative.reqmts] as the reference):
//   len, is_empty, new, new_in                            O(1)
//   get, get_mut, get_key_value, contains_key, entry     O(log n): at most 15 (h + 1) key comparisons
//   insert, VacantEntry::insert                          O(log n) comparisons; node splits amortized O(1)
//   remove, remove_entry, pop_first, pop_last,
//   OccupiedEntry::remove                                O(log n); steals and merges amortized O(1)
//   first_key_value, last_key_value, first, last         O(log n): one descent, no comparison
//   iter, iter_mut, keys, values, values_mut             O(log n) to create; each step amortized O(1),
//                                                        O(log n) worst; a whole walk O(n)
//   range                                                O(log n): two searches; steps as for iter
//   retain                                               O(n) predicate calls, O(log n) per removal
//   append                                               O(n + m) merge into full nodes, or m inserts
//                                                        when m < n / 16 (whichever is cheaper)
//   extend_from                                          O(k log(n + k)) for k pairs
//   clear, drop, clone, eq, hash, fmt                    O(n)
//   From<[](K, V)>                                       O(n) when the keys strictly increase (full
//                                                        nodes), else O(n log n)
//   union_with, intersection, difference,
//   symmetric_difference, is_subset, is_superset,
//   is_disjoint                                          O(n + m): one merge walk of both sets
// C++ `std::map::begin` is O(1); here the first element costs one descent.
//
// Invalidation: an insert, remove, pop, retain, append, clear or entry insert or remove moves entries
// between nodes and frees nodes, so it invalidates every iterator and every reference into the map
// (C++ `std::map` keeps them; a B-tree cannot). The borrow rules reject such a use in safe code. A
// reference from `get`, `get_mut`, an iterator or an entry stays valid until the next of these
// mutations; `get_mut`, `iter_mut` and `values_mut` move nothing.
//
// Ranges: `range(lo, hi)` takes one `Bound` per end. [a, b) is `range(Included(&a), Excluded(&b))`,
// [a, b] is `(Included(&a), Included(&b))`, (a, ..) is `(Excluded(&a), Unbounded)`. It panics when the
// start is above the end, or when both ends exclude one key.
//
// Allocation: one block per node through `A` (a leaf: a 16-byte header and 15 key and value slots; an
// internal node: also 16 edges), none per element. Nodes are freed as they empty; an empty map holds
// no block. `clone` and `append` build full nodes through the map's allocator.
//
// Thread safety: no internal synchronization. A map is Send and Sync when K, V and A are: shared reads
// from several threads are safe, a mutation needs exclusive access.
//
// Node shape, measured (Apple M5 Pro, release, random keys; ns per insert / hit / remove at 65536
// entries, 1M for u64 too): B = 8 with a linear node search gives u64 57 / 59 / 73 (1M: 80 / 130 /
// 142) and String 135 / 124 / 139; B = 6 gives u64 59 / 62 / 75 (84 / 148 / 162) and String 139 / 128
// / 149; B = 12 gives u64 55 / 56 / 66 (78 / 129 / 132) and String 140 / 130 / 143. A binary node search
// is slower on every String figure (insert 237 at B = 8) and on u64 inserts.
//
// Against a sorted Vector<(K, V)> with binary search (C++ <flat_map>), u64 keys (bench/btree_bench.spc,
// ns per operation): the B-tree is faster for insert from 96 entries (16: 13.9 against 9.0; 256: 17.7
// against 33.3; 65536: 60 against 4793) and for remove from 48 entries (65536: 67 against 6747). A hit
// costs about the same up to 48 entries, the B-tree is up to 13% faster up to 256 entries, and the
// sorted vector is 26% faster at 65536 (42.7 against 57.7). In-order iteration is about 3 times faster
// over the vector (0.16 against 0.5). A small or read-mostly map is a sorted Vector; a map that changes
// is a BTreeMap.

extern "C" {
    fn memmove(dst: *mut void, src: *const void, n: usize) *mut void;
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
}

// The B-tree order: a node other than the root holds MIN_LEN to CAPACITY keys, an internal node one
// more child than keys.
const B: usize = 8;
const CAPACITY: usize = 2 * B - 1;
const MIN_LEN: usize = B - 1;

// `append` inserts each entry of the other map when it holds fewer than 1/APPEND_INSERT_RATIO of this
// map's entries, else it merges both into new full nodes: a merge costs about 5 ns per entry of either
// map, an insert 70 to 110 ns at 65536 entries, so the two meet near 1/16.
const APPEND_INSERT_RATIO: usize = 16;

static_assert(B >= 2, "a B-tree node splits into two nodes of at least one key");

// A node. A leaf is this struct alone; an internal node is an `Internal`, whose first field is this
// header, so a pointer to either is a `*mut Leaf`. Only the first `len` key and value slots hold
// live values; the node never drops them itself.
struct Leaf<K, V> {
    parent: *mut Leaf<K, V>, // the internal node above, null at the root
    parent_idx: u16, // the edge of `parent` that points here
    len: u16,
    keys: [K; CAPACITY],
    vals: [V; CAPACITY],
}

// An internal node: edge i leads to the keys between keys[i - 1] and keys[i]; edges 0..=len are live.
struct Internal<K, V> {
    @ordered
    data: Leaf<K, V>, // first, so a `*mut Internal` is a `*mut Leaf`
    edges: [*mut Leaf<K, V>; CAPACITY + 1],
}

/// One end of a range: `Included(x)` and `Excluded(x)` bound the range at `x`, `Unbounded` does not
/// bound that end.
pub enum Bound<T> {
    Included(T),
    Excluded(T),
    Unbounded,
}

/// An ordered map from K to V through allocator A: a B-tree of nodes that hold up to 15 keys and
/// values each in flat arrays. Iteration is in increasing key order.
pub struct BTreeMap<K, V, A = Global> {
    root: *mut Leaf<K, V>, // null exactly when len == 0
    height: usize, // edges from the root to every leaf
    len: usize,
    alloc: A,
}

// A BTreeMap owns its keys and values, so it is Send / Sync when they and its allocator are.
unsafe extend<K: Send, V: Send, A: Send> BTreeMap<K, V, A> as Send {}

unsafe extend<K: Sync, V: Sync, A: Sync> BTreeMap<K, V, A> as Sync {}

// The two leaf positions an iterator has not passed: the gap before its next element from the front,
// and the gap after its next element from the back. Every gap between two neighbor elements is exactly
// one leaf position, so two positions are equal exactly when no element lies between them.
struct Gaps<K, V> {
    front: *mut Leaf<K, V>,
    front_idx: usize,
    back: *mut Leaf<K, V>,
    back_idx: usize,
}

// Moves every element out in key order and frees each node once it has passed the node. Dropping it
// drops the elements it did not reach and frees the rest of the nodes.
struct Drain<K, V, A> {
    front: *mut Leaf<K, V>,
    idx: usize,
    len: usize,
    alloc: A,
}

/// Iterator over a map's `(&K, &V)` pairs in key order; borrows the map.
pub struct BTreeIter<'a, K, V> {
    gaps: Gaps<K, V>,
    len: usize,
}

/// Iterator over a map's `(&K, &mut V)` pairs in key order; borrows the map mutably.
pub struct BTreeIterMut<'a, K, V> {
    gaps: Gaps<K, V>,
    len: usize,
}

/// Iterator over a map's keys in order.
pub struct BTreeKeys<'a, K, V> {
    it: BTreeIter<'a, K, V>,
}

/// Iterator over a map's values in key order.
pub struct BTreeValues<'a, K, V> {
    it: BTreeIter<'a, K, V>,
}

/// Iterator over a map's values in key order, by mutable reference.
pub struct BTreeValuesMut<'a, K, V> {
    it: BTreeIterMut<'a, K, V>,
}

/// Iterator over the `(&K, &V)` pairs of a key range in key order; borrows the map.
pub struct BTreeRange<'a, K, V> {
    gaps: Gaps<K, V>,
}

/// The slot of one key in a map, from `BTreeMap::entry`: occupied or vacant.
pub enum BTreeEntry<'a, K, V, A> {
    Occupied(BTreeOccupiedEntry<'a, K, V, A>),
    Vacant(BTreeVacantEntry<'a, K, V, A>),
}

/// An entry whose key is in the map. Holds the map borrowed mutably.
pub struct BTreeOccupiedEntry<'a, K, V, A> {
    map: &'a mut BTreeMap<K, V, A>,
    node: *mut Leaf<K, V>,
    idx: usize,
    height: usize, // of `node`
}

/// An entry whose key is not in the map; it owns the key until `insert`. Holds the map borrowed
/// mutably.
pub struct BTreeVacantEntry<'a, K, V, A> {
    map: &'a mut BTreeMap<K, V, A>,
    key: K,
    leaf: *mut Leaf<K, V>, // where the key goes, null for an empty map
    idx: usize,
}

// The zero-sized value every member of a set maps to.
struct Member {}

/// An ordered set of T through allocator A: a BTreeMap<T, Member, A> whose value takes no space.
pub struct BTreeSet<T, A = Global> {
    m: BTreeMap<T, Member, A>,
}

/// Iterator over a set's elements in order; borrows the set.
pub struct BTreeSetIter<'a, T> {
    it: BTreeIter<'a, T, Member>,
}

/// Iterator over the elements of a range of a set, in order.
pub struct BTreeSetRange<'a, T> {
    it: BTreeRange<'a, T, Member>,
}

/// The elements of either set, in order, each once.
pub struct BTreeUnion<'a, T> {
    a: BTreeSetIter<'a, T>,
    b: BTreeSetIter<'a, T>,
    pa: *const T, // the next element of `a`, null at its end
    pb: *const T,
}

/// The elements of both sets, in order.
pub struct BTreeIntersection<'a, T> {
    a: BTreeSetIter<'a, T>,
    b: BTreeSetIter<'a, T>,
    pa: *const T,
    pb: *const T,
}

/// The elements of the first set that are not in the second, in order.
pub struct BTreeDifference<'a, T> {
    a: BTreeSetIter<'a, T>,
    b: BTreeSetIter<'a, T>,
    pa: *const T,
    pb: *const T,
}

/// The elements of exactly one of the two sets, in order.
pub struct BTreeSymmetricDifference<'a, T> {
    a: BTreeSetIter<'a, T>,
    b: BTreeSetIter<'a, T>,
    pa: *const T,
    pb: *const T,
}

// Where a full node of CAPACITY keys splits when one more key goes in at `edge_idx`: the index of the
// key that moves up, whether the new key goes into the left half, and its index there. Both halves end
// with at least MIN_LEN keys. The split leaves the key next to the insertion point where it is, so an
// ascending run of insertions keeps appending to the right half.
const fn splitpoint(edge_idx: usize) (usize, bool, usize) {
    if edge_idx < B - 1 {
        return (B - 2, true, edge_idx);
    }
    if edge_idx == B - 1 {
        return (B - 1, true, edge_idx);
    }
    if edge_idx == B {
        return (B - 1, false, 0);
    }
    return (B, false, edge_idx - (B + 1));
}

// The index of `key` in `node`: (true, i) when keys[i] equals it, else (false, i) with i the edge
// between the smaller and the larger keys.
@always_inline
fn search_node<K: Ord, V>(node: *mut Leaf<K, V>, key: &K) (bool, usize) {
    let kp = node.keys();
    let n = node.len();
    for i in 0..n {
        let c = key.cmp(&unsafe kp[i]);
        if c <= 0 {
            return (c == 0, i);
        }
    }
    return (false, n);
}

// The number of keys of `node` below `key` (`strict`), or at most `key`.
@always_inline
fn count_below<K: Ord, V>(node: *mut Leaf<K, V>, key: &K, strict: bool) usize {
    let kp = node.keys();
    let n = node.len();
    for i in 0..n {
        let c = key.cmp(&unsafe kp[i]);
        if c < 0 || c == 0 && strict {
            return i;
        }
    }
    return n;
}

// Node accessors through the raw node pointer. Each caller proves `self` is a live node, and an index
// is inside the slots the access needs; the edge accessors need an internal node.
extend<K, V> Leaf<K, V> {
    @always_inline
    const fn len(self: *mut Leaf<K, V>) usize {
        return (unsafe (*self).len) as usize;
    }

    @always_inline
    const fn set_len(self: *mut Leaf<K, V>, n: usize) {
        unsafe (*self).len = n as u16;
    }

    @always_inline
    const fn keys(self: *mut Leaf<K, V>) *mut K {
        return &mut unsafe (*self).keys[0];
    }

    @always_inline
    const fn vals(self: *mut Leaf<K, V>) *mut V {
        return &mut unsafe (*self).vals[0];
    }

    @always_inline
    const fn edges(self: *mut Leaf<K, V>) *mut *mut Leaf<K, V> {
        let n = self as *mut Internal<K, V>;
        return &mut unsafe (*n).edges[0];
    }

    @always_inline
    const fn edge(self: *mut Leaf<K, V>, i: usize) *mut Leaf<K, V> {
        return unsafe self.edges()[i];
    }

    @always_inline
    const fn parent(self: *mut Leaf<K, V>) *mut Leaf<K, V> {
        return unsafe (*self).parent;
    }

    @always_inline
    const fn parent_idx(self: *mut Leaf<K, V>) usize {
        return (unsafe (*self).parent_idx) as usize;
    }

    @always_inline
    const fn set_parent(self: *mut Leaf<K, V>, parent: *mut Leaf<K, V>, idx: usize) {
        unsafe (*self).parent = parent;
        unsafe (*self).parent_idx = idx as u16;
    }

    // Point the children at edges lo..=hi of this internal node back at it.
    const fn adopt(self: *mut Leaf<K, V>, lo: usize, hi: usize) {
        let ep = self.edges();
        for i in lo..hi + 1 {
            (unsafe ep[i]).set_parent(self, i);
        }
    }

    // Move `n` keys and values from `src` at `si` to this node at `di` (the ranges do not overlap).
    @always_inline
    const fn copy_kvs(self: *mut Leaf<K, V>, di: usize, src: *mut Leaf<K, V>, si: usize, n: usize) {
        unsafe memcpy(self.keys() + di, src.keys() + si, n * sizeof(K));
        unsafe memcpy(self.vals() + di, src.vals() + si, n * sizeof(V));
    }

    // Move keys and values si..si + n of this node to di (the ranges may overlap).
    @always_inline
    const fn shift_kvs(self: *mut Leaf<K, V>, di: usize, si: usize, n: usize) {
        unsafe memmove(self.keys() + di, self.keys() + si, n * sizeof(K));
        unsafe memmove(self.vals() + di, self.vals() + si, n * sizeof(V));
    }

    // Move the key and value at `si` of `src` into slot `di` of this node.
    @always_inline
    const fn move_kv(self: *mut Leaf<K, V>, di: usize, src: *mut Leaf<K, V>, si: usize) {
        unsafe self.keys()[di] = unsafe src.keys()[si];
        unsafe self.vals()[di] = unsafe src.vals()[si];
    }

    // Insert into a node with room, at key index `idx`.
    const fn insert_fit(self: *mut Leaf<K, V>, idx: usize, key: K, value: V) {
        let n = self.len();
        self.shift_kvs(idx + 1, idx, n - idx);
        unsafe self.keys()[idx] = key;
        unsafe self.vals()[idx] = value;
        self.set_len(n + 1);
    }

    // Insert into an internal node with room: the key at `idx`, `edge` to its right.
    const fn insert_fit_edge(self: *mut Leaf<K, V>, idx: usize, key: K, value: V, edge: *mut Leaf<K, V>) {
        let n = self.len();
        self.insert_fit(idx, key, value);
        let ep = self.edges();
        unsafe memmove(ep + idx + 2, ep + idx + 1, (n - idx) * sizeof(*mut Leaf<K, V>));
        unsafe ep[idx + 1] = edge;
        self.adopt(idx + 1, n + 1);
    }

    // Move the keys after `mid` (and for an internal node the edges after it) into the empty node
    // `right`, and return the key and value at `mid`, which leave this node.
    const fn split(self: *mut Leaf<K, V>, right: *mut Leaf<K, V>, mid: usize, internal: bool) (K, V) {
        let n = self.len();
        let rn = n - mid - 1;
        right.copy_kvs(0, self, mid + 1, rn);
        let k = unsafe self.keys()[mid];
        let v = unsafe self.vals()[mid];
        self.set_len(mid);
        right.set_len(rn);
        if internal {
            unsafe memcpy(right.edges(), self.edges() + mid + 1, (rn + 1) * sizeof(*mut Leaf<K, V>));
            right.adopt(0, rn);
        }
        return (k, v);
    }

    // The leftmost leaf below this node of height `h`.
    const fn first_leaf(self: *mut Leaf<K, V>, h: usize) *mut Leaf<K, V> {
        let mut n = self;
        for _ in 0..h {
            n = n.edge(0);
        }
        return n;
    }

    // The rightmost leaf below this node of height `h`.
    const fn last_leaf(self: *mut Leaf<K, V>, h: usize) *mut Leaf<K, V> {
        let mut n = self;
        for _ in 0..h {
            n = n.edge(n.len());
        }
        return n;
    }
}

// Rebalancing between two children of an internal node `self`: edge `kv` (left) and edge `kv + 1`
// (right), at height `h`. The parent key `kv` separates them.
extend<K, V> Leaf<K, V> {
    // Move `count` keys from the left child through the parent key into the front of the right child.
    const fn steal_left(self: *mut Leaf<K, V>, kv: usize, h: usize, count: usize) {
        let left = self.edge(kv);
        let right = self.edge(kv + 1);
        let ln = left.len();
        let rn = right.len();
        right.shift_kvs(count, 0, rn);
        right.move_kv(count - 1, self, kv);
        right.copy_kvs(0, left, ln - count + 1, count - 1);
        self.move_kv(kv, left, ln - count);
        left.set_len(ln - count);
        right.set_len(rn + count);
        if h > 0 {
            let rp = right.edges();
            unsafe memmove(rp + count, rp, (rn + 1) * sizeof(*mut Leaf<K, V>));
            unsafe memcpy(rp, left.edges() + ln - count + 1, count * sizeof(*mut Leaf<K, V>));
            right.adopt(0, rn + count);
        }
    }

    // Move one key from the right child through the parent key onto the end of the left child.
    const fn steal_right(self: *mut Leaf<K, V>, kv: usize, h: usize) {
        let left = self.edge(kv);
        let right = self.edge(kv + 1);
        let ln = left.len();
        let rn = right.len();
        left.move_kv(ln, self, kv);
        self.move_kv(kv, right, 0);
        right.shift_kvs(0, 1, rn - 1);
        left.set_len(ln + 1);
        right.set_len(rn - 1);
        if h > 0 {
            let rp = right.edges();
            unsafe left.edges()[ln + 1] = unsafe rp[0];
            unsafe memmove(rp, rp + 1, rn * sizeof(*mut Leaf<K, V>));
            left.adopt(ln + 1, ln + 1);
            right.adopt(0, rn - 1);
        }
    }

    // Merge the right child and the parent key into the left child, and return the right child, which
    // the caller frees. The parent loses one key and one edge.
    const fn merge(self: *mut Leaf<K, V>, kv: usize, h: usize) *mut Leaf<K, V> {
        let left = self.edge(kv);
        let right = self.edge(kv + 1);
        let ln = left.len();
        let rn = right.len();
        let pn = self.len();
        left.move_kv(ln, self, kv);
        left.copy_kvs(ln + 1, right, 0, rn);
        left.set_len(ln + 1 + rn);
        self.shift_kvs(kv, kv + 1, pn - kv - 1);
        let ep = self.edges();
        unsafe memmove(ep + kv + 1, ep + kv + 2, (pn - kv - 1) * sizeof(*mut Leaf<K, V>));
        self.set_len(pn - 1);
        if kv + 1 < pn {
            self.adopt(kv + 1, pn - 1);
        }
        if h > 0 {
            unsafe memcpy(left.edges() + ln + 1, right.edges(), (rn + 1) * sizeof(*mut Leaf<K, V>));
            left.adopt(ln + 1, ln + 1 + rn);
        }
        return right;
    }
}

extend<K, V> Gaps<K, V> {
    // The node and index of the next element from the front, which the caller proves exists; the front
    // moves past it.
    const fn next_kv(self: &mut Gaps<K, V>) (*mut Leaf<K, V>, usize) {
        let mut n = self.front;
        let mut i = self.front_idx;
        let mut h: usize = 0;
        while i >= n.len() {
            i = n.parent_idx();
            n = n.parent();
            h += 1;
        }
        if h == 0 {
            self.front = n;
            self.front_idx = i + 1;
        } else {
            self.front = n.edge(i + 1).first_leaf(h - 1);
            self.front_idx = 0;
        }
        return (n, i);
    }

    // The node and index of the next element from the back, which the caller proves exists; the back
    // moves before it.
    const fn next_back_kv(self: &mut Gaps<K, V>) (*mut Leaf<K, V>, usize) {
        let mut n = self.back;
        let mut i = self.back_idx;
        let mut h: usize = 0;
        while i == 0 {
            i = n.parent_idx();
            n = n.parent();
            h += 1;
        }
        i -= 1;
        if h == 0 {
            self.back = n;
            self.back_idx = i;
        } else {
            let leaf = n.edge(i).last_leaf(h - 1);
            self.back = leaf;
            self.back_idx = leaf.len();
        }
        return (n, i);
    }

    const fn is_empty(self: &Gaps<K, V>) bool {
        return self.front == self.back && self.front_idx == self.back_idx;
    }
}

extend<K, V, A: Allocator> Drain<K, V, A> {
    fn free_node(self: &mut Drain<K, V, A>, node: *mut Leaf<K, V>, leaf: bool) {
        if leaf {
            unsafe self.alloc.dealloc(node, sizeof(Leaf<K, V>), alignof(Leaf<K, V>));
        } else {
            unsafe self.alloc.dealloc(node, sizeof(Internal<K, V>), alignof(Internal<K, V>));
        }
    }

    fn next(self: &mut Drain<K, V, A>) Option<(K, V)> {
        if self.len == 0 {
            // Every element is out: free the nodes from the last leaf up to the root.
            let mut n = self.front;
            let mut leaf = true;
            while n != null {
                let p = n.parent();
                self.free_node(n, leaf);
                n = p;
                leaf = false;
            }
            self.front = null;
            return None;
        }
        self.len -= 1;
        let mut n = self.front;
        let mut i = self.idx;
        let mut h: usize = 0;
        while i >= n.len() {
            let p = n.parent();
            i = n.parent_idx();
            self.free_node(n, h == 0);
            n = p;
            h += 1;
        }
        let k = unsafe n.keys()[i];
        let v = unsafe n.vals()[i];
        if h == 0 {
            self.front = n;
            self.idx = i + 1;
        } else {
            self.front = n.edge(i + 1).first_leaf(h - 1);
            self.idx = 0;
        }
        return Some((k, v));
    }
}

extend<K, V, A: Allocator> Drain<K, V, A> as Free {
    fn free(self: &mut Drain<K, V, A>) {
        while let Some(_) = self.next() {}
    }
}

extend<K: Ord, V, A: Allocator> BTreeMap<K, V, A> {
    /// An empty map backed by an explicit allocator value; no allocation until the first insert.
    pub const fn new_in(alloc: A) BTreeMap<K, V, A> {
        return BTreeMap::<K, V, A> { root: null, height: 0, len: 0, alloc: alloc };
    }

    /// Number of entries.
    pub const fn len(self: &BTreeMap<K, V, A>) usize {
        return self.len;
    }

    /// True when no entry is stored.
    pub const fn is_empty(self: &BTreeMap<K, V, A>) bool {
        return self.len == 0;
    }

    fn new_leaf(self: &mut BTreeMap<K, V, A>) *mut Leaf<K, V> {
        let n = (unsafe self.alloc.alloc(sizeof(Leaf<K, V>), alignof(Leaf<K, V>))) as *mut Leaf<K, V>;
        n.set_parent(null, 0);
        n.set_len(0);
        return n;
    }

    fn new_internal(self: &mut BTreeMap<K, V, A>) *mut Leaf<K, V> {
        let node = (unsafe self.alloc.alloc(sizeof(Internal<K, V>), alignof(Internal<K, V>))) as *mut Internal<K, V>;
        let n: *mut Leaf<K, V> = &mut unsafe (*node).data;
        n.set_parent(null, 0);
        n.set_len(0);
        return n;
    }

    fn free_node(self: &mut BTreeMap<K, V, A>, node: *mut Leaf<K, V>, leaf: bool) {
        if leaf {
            unsafe self.alloc.dealloc(node, sizeof(Leaf<K, V>), alignof(Leaf<K, V>));
        } else {
            unsafe self.alloc.dealloc(node, sizeof(Internal<K, V>), alignof(Internal<K, V>));
        }
    }

    // Moves every element out into a drain and leaves the map empty.
    const fn drain(self: &mut BTreeMap<K, V, A>) Drain<K, V, A> {
        let mut front: *mut Leaf<K, V> = null;
        if self.root != null {
            front = self.root.first_leaf(self.height);
        }
        let d = Drain::<K, V, A> { front: front, idx: 0, len: self.len, alloc: self.alloc };
        self.root = null;
        self.height = 0;
        self.len = 0;
        return d;
    }

    /// Drops every entry and frees every node.
    pub const fn clear(self: &mut BTreeMap<K, V, A>) {
        let _ = self.drain();
    }

    // The node, index and node height of `key`, or a null node.
    fn find(self: &BTreeMap<K, V, A>, key: &K) (*mut Leaf<K, V>, usize, usize) {
        let mut node = self.root;
        let mut h = self.height;
        while node != null {
            let (found, i) = search_node(node, key);
            if found {
                return (node, i, h);
            }
            if h == 0 {
                break;
            }
            node = node.edge(i);
            h -= 1;
        }
        return (null, 0, 0);
    }

    /// A borrow of the value for `key`, or `None`.
    pub fn get(self: &BTreeMap<K, V, A>, key: &K) Option<&V> {
        let (n, i, _) = self.find(key);
        if n == null {
            return None;
        }
        return Some(&unsafe n.vals()[i]);
    }

    /// A mutable borrow of the value for `key`, or `None`.
    pub fn get_mut(self: &mut BTreeMap<K, V, A>, key: &K) Option<&mut V> {
        let (n, i, _) = self.find(key);
        if n == null {
            return None;
        }
        return Some(&mut unsafe n.vals()[i]);
    }

    /// Borrows of the stored key equal to `key` and its value, or `None`.
    pub fn get_key_value(self: &BTreeMap<K, V, A>, key: &K) Option<(&K, &V)> {
        let (n, i, _) = self.find(key);
        if n == null {
            return None;
        }
        return Some((&unsafe n.keys()[i], &unsafe n.vals()[i]));
    }

    /// True when `key` has an entry.
    pub fn contains_key(self: &BTreeMap<K, V, A>, key: &K) bool {
        let (n, _, _) = self.find(key);
        return n != null;
    }

    /// The entry with the smallest key, or `None` when empty.
    pub const fn first_key_value(self: &BTreeMap<K, V, A>) Option<(&K, &V)> {
        if self.root == null {
            return None;
        }
        let n = self.root.first_leaf(self.height);
        return Some((&unsafe n.keys()[0], &unsafe n.vals()[0]));
    }

    /// The entry with the largest key, or `None` when empty.
    pub const fn last_key_value(self: &BTreeMap<K, V, A>) Option<(&K, &V)> {
        if self.root == null {
            return None;
        }
        let n = self.root.last_leaf(self.height);
        let i = n.len() - 1;
        return Some((&unsafe n.keys()[i], &unsafe n.vals()[i]));
    }

    /// Insert `key` -> `value` and return the replaced value, or `None` when the key is new. On
    /// replacement the stored key stays and the argument key is dropped.
    pub fn insert(self: &mut BTreeMap<K, V, A>, key: K, value: V) Option<V> {
        let mut node = self.root;
        let mut h = self.height;
        while node != null {
            let (found, i) = search_node(node, &key);
            if found {
                return Some(replace(&mut unsafe node.vals()[i], value));
            }
            if h == 0 {
                self.insert_leaf(node, i, key, value);
                return None;
            }
            node = node.edge(i);
            h -= 1;
        }
        self.insert_leaf(null, 0, key, value);
        return None;
    }

    // Insert a new key at index `idx` of `leaf` (null: the map is empty), splitting full nodes up the
    // tree, and return the leaf and index where the key and value now are.
    fn insert_leaf(self: &mut BTreeMap<K, V, A>, leaf: *mut Leaf<K, V>, idx: usize, key: K, value: V) (
        *mut Leaf<K, V>,
        usize
    ) {
        self.len += 1;
        if leaf == null {
            let root = self.new_leaf();
            root.insert_fit(0, key, value);
            self.root = root;
            self.height = 0;
            return (root, 0);
        }
        if leaf.len() < CAPACITY {
            leaf.insert_fit(idx, key, value);
            return (leaf, idx);
        }
        let (mid, into_left, at) = splitpoint(idx);
        let right = self.new_leaf();
        let (mk, mv) = leaf.split(right, mid, false);
        let target = if into_left {
            leaf
        } else {
            right
        };
        target.insert_fit(at, key, value);
        self.insert_up(leaf, mk, mv, right);
        return (target, at);
    }

    // Insert the key and value that a split of `left` moved up, with the new node `right` after it,
    // into the parent of `left`, splitting full ancestors.
    fn insert_up(self: &mut BTreeMap<K, V, A>, left: *mut Leaf<K, V>, key: K, value: V, right: *mut Leaf<K, V>) {
        let mut l = left;
        let mut r = right;
        let mut k = key;
        let mut v = value;
        for _ in 0..self.height + 1 {
            let parent = l.parent();
            if parent == null {
                break;
            }
            let idx = l.parent_idx();
            if parent.len() < CAPACITY {
                parent.insert_fit_edge(idx, k, v, r);
                return;
            }
            let (mid, into_left, at) = splitpoint(idx);
            let pright = self.new_internal();
            let (mk, mv) = parent.split(pright, mid, true);
            let target = if into_left {
                parent
            } else {
                pright
            };
            target.insert_fit_edge(at, k, v, r);
            l = parent;
            r = pright;
            k = mk;
            v = mv;
        }
        // `l` is the root: a new root above it holds the moved-up key.
        let root = self.new_internal();
        root.insert_fit(0, k, v);
        unsafe root.edges()[0] = l;
        unsafe root.edges()[1] = r;
        root.adopt(0, 1);
        self.root = root;
        self.height += 1;
    }

    /// Remove `key` and return its value, or `None` when absent. The stored key is dropped.
    pub fn remove(self: &mut BTreeMap<K, V, A>, key: &K) Option<V> {
        let (n, i, h) = self.find(key);
        if n == null {
            return None;
        }
        let (_, v, _, _) = self.remove_kv(n, i, h);
        return Some(v);
    }

    /// Remove `key` and return the stored key and its value, or `None` when absent.
    pub fn remove_entry(self: &mut BTreeMap<K, V, A>, key: &K) Option<(K, V)> {
        let (n, i, h) = self.find(key);
        if n == null {
            return None;
        }
        let (k, v, _, _) = self.remove_kv(n, i, h);
        return Some((k, v));
    }

    /// Remove and return the entry with the smallest key, or `None` when empty.
    pub fn pop_first(self: &mut BTreeMap<K, V, A>) Option<(K, V)> {
        if self.root == null {
            return None;
        }
        let n = self.root.first_leaf(self.height);
        let (k, v, _, _) = self.remove_kv(n, 0, 0);
        return Some((k, v));
    }

    /// Remove and return the entry with the largest key, or `None` when empty.
    pub fn pop_last(self: &mut BTreeMap<K, V, A>) Option<(K, V)> {
        if self.root == null {
            return None;
        }
        let n = self.root.last_leaf(self.height);
        let (k, v, _, _) = self.remove_kv(n, n.len() - 1, 0);
        return Some((k, v));
    }

    // Remove the element at index `idx` of `node` (height `h`), rebalance, and return the element and
    // the leaf position of the gap it left: before its successor for a leaf element, after it for an
    // internal one, whose successor takes its place.
    fn remove_kv(self: &mut BTreeMap<K, V, A>, node: *mut Leaf<K, V>, idx: usize, h: usize) (
        K,
        V,
        *mut Leaf<K, V>,
        usize
    ) {
        let mut leaf = node;
        let mut i = idx;
        if h > 0 {
            // Swap with the successor, the first element of the right subtree, then remove it from its leaf.
            leaf = node.edge(idx + 1).first_leaf(h - 1);
            i = 0;
            let tk = unsafe node.keys()[idx];
            let tv = unsafe node.vals()[idx];
            node.move_kv(idx, leaf, 0);
            unsafe leaf.keys()[0] = tk;
            unsafe leaf.vals()[0] = tv;
        }
        let k = unsafe leaf.keys()[i];
        let v = unsafe leaf.vals()[i];
        let n = leaf.len();
        leaf.shift_kvs(i, i + 1, n - i - 1);
        leaf.set_len(n - 1);
        self.len -= 1;
        let (g, gi) = self.rebalance(leaf, i);
        return (k, v, g, gi);
    }

    // Restore the minimum node length from `leaf` up, after a removal left a gap at `gap` in it, and
    // return the leaf position of that gap after the moves.
    fn rebalance(self: &mut BTreeMap<K, V, A>, leaf: *mut Leaf<K, V>, gap: usize) (*mut Leaf<K, V>, usize) {
        let mut gnode = leaf;
        let mut gidx = gap;
        let mut node = leaf;
        for h in 0..self.height + 1 {
            let len = node.len();
            if len >= MIN_LEN {
                break;
            }
            let parent = node.parent();
            if parent == null {
                if len == 0 {
                    if h == 0 {
                        self.free_node(node, true);
                        self.root = null;
                        gnode = null;
                        gidx = 0;
                    } else {
                        let child = node.edge(0);
                        child.set_parent(null, 0);
                        self.free_node(node, false);
                        self.root = child;
                        self.height -= 1;
                    }
                }
                break;
            }
            let pi = node.parent_idx();
            if pi > 0 {
                let left = parent.edge(pi - 1);
                let ln = left.len();
                if ln > MIN_LEN {
                    parent.steal_left(pi - 1, h, 1);
                    if h == 0 {
                        gidx += 1;
                    }
                    break;
                }
                let gone = parent.merge(pi - 1, h);
                self.free_node(gone, h == 0);
                if h == 0 {
                    gnode = left;
                    gidx += ln + 1;
                }
            } else {
                if parent.edge(1).len() > MIN_LEN {
                    parent.steal_right(0, h);
                    break;
                }
                let gone = parent.merge(0, h);
                self.free_node(gone, h == 0);
            }
            node = parent;
        }
        return (gnode, gidx);
    }

    /// The entry of `key`, for an in-place update or insert with one search.
    pub fn entry(self: &mut BTreeMap<K, V, A>, key: K) BTreeEntry<K, V, A> {
        let mut node = self.root;
        let mut h = self.height;
        while node != null {
            let (found, i) = search_node(node, &key);
            if found {
                return Occupied(BTreeOccupiedEntry::<K, V, A> { map: self, node: node, idx: i, height: h });
            }
            if h == 0 {
                return Vacant(BTreeVacantEntry::<K, V, A> { map: self, key: key, leaf: node, idx: i });
            }
            node = node.edge(i);
            h -= 1;
        }
        return Vacant(BTreeVacantEntry::<K, V, A> { map: self, key: key, leaf: null, idx: 0 });
    }

    const fn gaps_all(self: &BTreeMap<K, V, A>) Gaps<K, V> {
        if self.root == null {
            return Gaps::<K, V> { front: null, front_idx: 0, back: null, back_idx: 0 };
        }
        let last = self.root.last_leaf(self.height);
        return Gaps::<K, V> { front: self.root.first_leaf(self.height), front_idx: 0, back: last, back_idx: last.len() };
    }

    /// An iterator over the `(&K, &V)` pairs in key order.
    pub const fn iter(self: &BTreeMap<K, V, A>) BTreeIter<K, V> {
        return BTreeIter::<K, V> { gaps: self.gaps_all(), len: self.len };
    }

    /// An iterator over the `(&K, &mut V)` pairs in key order.
    pub const fn iter_mut(self: &mut BTreeMap<K, V, A>) BTreeIterMut<K, V> {
        return BTreeIterMut::<K, V> { gaps: self.gaps_all(), len: self.len };
    }

    /// An iterator over the keys in order.
    pub const fn keys(self: &BTreeMap<K, V, A>) BTreeKeys<K, V> {
        return BTreeKeys::<K, V> { it: self.iter() };
    }

    /// An iterator over the values in key order.
    pub const fn values(self: &BTreeMap<K, V, A>) BTreeValues<K, V> {
        return BTreeValues::<K, V> { it: self.iter() };
    }

    /// An iterator over the values in key order, by mutable reference.
    pub const fn values_mut(self: &mut BTreeMap<K, V, A>) BTreeValuesMut<K, V> {
        return BTreeValuesMut::<K, V> { it: self.iter_mut() };
    }

    // The leaf position before the first key that `b` admits as a lower bound (`lower`), or after the
    // last key it admits as an upper bound.
    fn gap_of(self: &BTreeMap<K, V, A>, b: &Bound<&K>, lower: bool) (*mut Leaf<K, V>, usize) {
        if self.root == null {
            return (null, 0);
        }
        let mut strict = false;
        let mut key: *const K = null;
        switch *b {
            Included(k) => {
                strict = lower;
                key = k;
            },
            Excluded(k) => {
                strict = !lower;
                key = k;
            },
            Unbounded => {
                if lower {
                    return (self.root.first_leaf(self.height), 0);
                }
                let last = self.root.last_leaf(self.height);
                return (last, last.len());
            },
        }
        let mut node = self.root;
        for _ in 0..self.height {
            node = node.edge(count_below(node, &unsafe *key, strict));
        }
        return (node, count_below(node, &unsafe *key, strict));
    }

    /// An iterator over the entries whose keys lie between `lo` and `hi`, in key order. Panics when `lo`
    /// is above `hi`, or when both are `Excluded` at one key.
    pub fn range<'s>(self: &'s BTreeMap<K, V, A>, lo: Bound<&K>, hi: Bound<&K>) BTreeRange<'s, K, V> {
        return BTreeRange::<K, V> { gaps: self.range_gaps(lo, hi) };
    }

    // The leaf positions that bound the keys between `lo` and `hi`; panics as `range` does.
    fn range_gaps(self: &BTreeMap<K, V, A>, lo: Bound<&K>, hi: Bound<&K>) Gaps<K, V> {
        let mut lk: *const K = null;
        let mut hk: *const K = null;
        let mut both_excluded = true;
        switch lo {
            Included(k) => {
                lk = k;
                both_excluded = false;
            },
            Excluded(k) => {
                lk = k;
            },
            Unbounded => {},
        }
        switch hi {
            Included(k) => {
                hk = k;
                both_excluded = false;
            },
            Excluded(k) => {
                hk = k;
            },
            Unbounded => {},
        }
        if lk != null && hk != null {
            let c = (unsafe *lk).cmp(&unsafe *hk);
            if c > 0 {
                panic("BTreeMap::range: start is above end");
            }
            if c == 0 && both_excluded {
                panic("BTreeMap::range: start and end are equal and excluded");
            }
        }
        let (f, fi) = self.gap_of(&lo, true);
        let (b, bi) = self.gap_of(&hi, false);
        return Gaps::<K, V> { front: f, front_idx: fi, back: b, back_idx: bi };
    }

    /// Keep only the entries for which `pred` returns true, in key order; drops the others.
    pub fn retain<F: fn(&K, &mut V) bool>(self: &mut BTreeMap<K, V, A>, pred: F) {
        if self.root == null {
            return;
        }
        let mut g = self.gaps_all();
        let total = self.len;
        for _ in 0..total {
            // The next element without moving the front: `pred` may remove it, which moves the nodes.
            let mut probe = g;
            let (n, i) = probe.next_kv();
            if pred(&unsafe n.keys()[i], &mut unsafe n.vals()[i]) {
                g = probe;
            } else {
                let h = self.node_height(n);
                let (_, _, gn, gi) = self.remove_kv(n, i, h);
                g.front = gn;
                g.front_idx = gi;
                if h > 0 {
                    // The successor took the place of the removed element, and the gap is after it.
                    let mut back = Gaps::<K, V> { front: null, front_idx: 0, back: gn, back_idx: gi };
                    back.next_back_kv();
                    g.front = back.back;
                    g.front_idx = back.back_idx;
                }
            }
        }
    }

    // The height of `node` above the leaves.
    const fn node_height(self: &BTreeMap<K, V, A>, node: *mut Leaf<K, V>) usize {
        let mut h = self.height;
        let mut n = node.parent();
        while n != null {
            n = n.parent();
            h -= 1;
        }
        return h;
    }

    // Append `key` and `value` after every stored key, which the caller proves are all below `key`.
    // `tail` is the rightmost leaf (null for an empty map); returns the new rightmost leaf. The nodes left
    // of the right border stay full; `fix_right_border` restores the minimum length after the last push.
    fn push_last(self: &mut BTreeMap<K, V, A>, tail: *mut Leaf<K, V>, key: K, value: V) *mut Leaf<K, V> {
        self.len += 1;
        if tail == null {
            let root = self.new_leaf();
            root.insert_fit(0, key, value);
            self.root = root;
            self.height = 0;
            return root;
        }
        let n = tail.len();
        if n < CAPACITY {
            tail.move_kv_in(n, key, value);
            return tail;
        }
        // Find the lowest ancestor with room, or grow a new root.
        let mut open = tail.parent();
        let mut h: usize = 1;
        while open != null && open.len() == CAPACITY {
            open = open.parent();
            h += 1;
        }
        if open == null {
            open = self.new_internal();
            unsafe open.edges()[0] = self.root;
            self.root.set_parent(open, 0);
            self.root = open;
            self.height += 1;
        }
        // A new right spine of empty nodes from height h - 1 down to a leaf, under the new key.
        let leaf = self.new_leaf();
        let mut child = leaf;
        for _ in 1..h {
            let up = self.new_internal();
            unsafe up.edges()[0] = child;
            child.set_parent(up, 0);
            child = up;
        }
        let on = open.len();
        open.move_kv_in(on, key, value);
        unsafe open.edges()[on + 1] = child;
        child.set_parent(open, on + 1);
        return leaf;
    }

    // Fill each node on the right border to MIN_LEN keys from its left sibling, which `push_last` left
    // full.
    const fn fix_right_border(self: &mut BTreeMap<K, V, A>) {
        let mut node = self.root;
        let mut h = self.height;
        while h > 0 {
            let last = node.len() - 1;
            let right = node.edge(last + 1);
            let rn = right.len();
            if rn < MIN_LEN {
                node.steal_left(last, h - 1, MIN_LEN - rn);
            }
            node = right;
            h -= 1;
        }
    }

    /// Move every entry of `other` into this map, leaving `other` empty. A key in both maps keeps the
    /// stored key of this map and the value of `other`.
    pub fn append(self: &mut BTreeMap<K, V, A>, other: &mut BTreeMap<K, V, A>) {
        if other.len == 0 {
            return;
        }
        let mut b = other.drain();
        if b.len < self.len / APPEND_INSERT_RATIO {
            while let Some((k, v)) = b.next() {
                self.insert(k, v);
            }
            return;
        }
        let mut a = self.drain();
        let mut pa = a.next();
        let mut pb = b.next();
        let mut tail: *mut Leaf<K, V> = null;
        loop {
            let mut c: i32 = 0;
            if pa.is_none() {
                if pb.is_none() {
                    break;
                }
                c = 1;
            } else if pb.is_none() {
                c = -1;
            } else {
                c = key_of(&pa).cmp(key_of(&pb));
            }
            if c < 0 {
                let (k, v) = pa.take().unwrap();
                tail = self.push_last(tail, k, v);
                pa = a.next();
            } else if c > 0 {
                let (k, v) = pb.take().unwrap();
                tail = self.push_last(tail, k, v);
                pb = b.next();
            } else {
                let (k, _) = pa.take().unwrap();
                let (_, v) = pb.take().unwrap();
                tail = self.push_last(tail, k, v);
                pa = a.next();
                pb = b.next();
            }
        }
        self.fix_right_border();
    }

    /// Insert every pair of `iter` in turn, as `insert` does.
    pub fn extend_from<I: Iterator<(K, V)>>(self: &mut BTreeMap<K, V, A>, iter: I) {
        let mut it = iter;
        while let Some((k, v)) = it.next() {
            self.insert(k, v);
        }
    }
}

// The key of a present pair.
const fn key_of<K, V>(o: &Option<(K, V)>) &K {
    if let Some(t) = o {
        return &t._0;
    }
    panic("BTreeMap: key of an absent pair");
}

extend<K, V> Leaf<K, V> {
    // Store a key and value into the free slot `i` of a node with room, at its end.
    @always_inline
    const fn move_kv_in(self: *mut Leaf<K, V>, i: usize, key: K, value: V) {
        unsafe self.keys()[i] = key;
        unsafe self.vals()[i] = value;
        self.set_len(i + 1);
    }
}

extend<K: Ord, V, A: Allocator> BTreeMap<K, V, A> {
    /// A structure self-check for tests, O(n): panics unless every node holds 7 to 15 keys (the root 1
    /// to 15) in strictly increasing order between its parent's keys, every child links back to its
    /// parent edge, every leaf is at one depth and `len` counts the elements. Returns the height: the
    /// edges from the root to every leaf.
    pub fn check_invariants(self: &BTreeMap<K, V, A>) usize {
        if self.root == null {
            assert(self.len == 0, "BTreeMap: a map without nodes has elements");
            assert(self.height == 0, "BTreeMap: a map without nodes has a height");
            return 0;
        }
        assert(self.root.parent() == null, "BTreeMap: the root has a parent");
        let n = check_node(self.root, self.height, null, null, true);
        assert(n == self.len, "BTreeMap: len differs from the element count");
        return self.height;
    }
}

// The elements below `node` of height `h`, after checking them; every key lies strictly between `lo`
// and `hi` (null: unbounded).
fn check_node<K: Ord, V>(node: *mut Leaf<K, V>, h: usize, lo: *const K, hi: *const K, root: bool) usize {
    let n = node.len();
    assert(n <= CAPACITY, "BTreeMap: a node holds more than CAPACITY keys");
    if root {
        assert(n >= 1, "BTreeMap: an empty root");
    } else {
        assert(n >= MIN_LEN, "BTreeMap: a node below MIN_LEN keys");
    }
    let kp = node.keys();
    for i in 0..n {
        if i > 0 {
            assert((unsafe kp[i - 1]).cmp(&unsafe kp[i]) < 0, "BTreeMap: keys out of order in a node");
        }
        if lo != null {
            assert((unsafe *lo).cmp(&unsafe kp[i]) < 0, "BTreeMap: a key below its subtree's bound");
        }
        if hi != null {
            assert((unsafe kp[i]).cmp(&unsafe *hi) < 0, "BTreeMap: a key above its subtree's bound");
        }
    }
    if h == 0 {
        return n;
    }
    let mut count = n;
    for i in 0..n + 1 {
        let child = node.edge(i);
        assert(child.parent() == node, "BTreeMap: a child does not link to its parent");
        assert(child.parent_idx() == i, "BTreeMap: a child links to the wrong parent edge");
        let clo: *const K = if i == 0 {
            lo
        } else {
            &unsafe kp[i - 1]
        };
        let chi: *const K = if i == n {
            hi
        } else {
            &unsafe kp[i]
        };
        count += check_node(child, h - 1, clo, chi, false);
    }
    return count;
}

extend<K: Ord, V, A: Allocator + Default> BTreeMap<K, V, A> {
    /// An empty map using the default allocator; no allocation until the first insert.
    pub const fn new() BTreeMap<K, V, A> {
        return BTreeMap::<K, V, A>::new_in(A::default());
    }
}

extend<'a, K: Ord, V, A: Allocator> BTreeEntry<'a, K, V, A> {
    /// The value of the entry, after inserting `default` when it is vacant.
    pub fn or_insert(self: BTreeEntry<'a, K, V, A>, default: V) &'a mut V {
        return switch self {
            Occupied(e) => e.into_mut(),
            Vacant(e) => e.insert(default),
        };
    }

    /// The value of the entry, after inserting `f()` when it is vacant; `f` runs only then.
    pub fn or_insert_with<F: fn() V>(self: BTreeEntry<'a, K, V, A>, f: F) &'a mut V {
        return switch self {
            Occupied(e) => e.into_mut(),
            Vacant(e) => e.insert(f()),
        };
    }

    /// Run `f` on the value when the entry is occupied, and return the entry.
    pub fn and_modify<F: fn(&mut V)>(self: BTreeEntry<'a, K, V, A>, f: F) BTreeEntry<'a, K, V, A> {
        switch self {
            Occupied(e) => {
                let mut o = e;
                f(o.get_mut());
                return Occupied(o);
            },
            Vacant(e) => {
                return Vacant(e);
            },
        }
    }

    /// The key of the entry.
    pub const fn key(self: &BTreeEntry<'a, K, V, A>) &K {
        return switch self {
            Occupied(e) => e.key(),
            Vacant(e) => e.key(),
        };
    }
}

extend<'a, K: Ord, V: Default, A: Allocator> BTreeEntry<'a, K, V, A> {
    /// The value of the entry, after inserting `V::default()` when it is vacant.
    pub fn or_default(self: BTreeEntry<'a, K, V, A>) &'a mut V {
        return switch self {
            Occupied(e) => e.into_mut(),
            Vacant(e) => e.insert(V::default()),
        };
    }
}

extend<'a, K: Ord, V, A: Allocator> BTreeOccupiedEntry<'a, K, V, A> {
    /// The stored key.
    pub const fn key(self: &BTreeOccupiedEntry<'a, K, V, A>) &K {
        return &unsafe self.node.keys()[self.idx];
    }

    /// A borrow of the value.
    pub const fn get(self: &BTreeOccupiedEntry<'a, K, V, A>) &V {
        return &unsafe self.node.vals()[self.idx];
    }

    /// A mutable borrow of the value, for as long as the entry lives.
    pub const fn get_mut(self: &mut BTreeOccupiedEntry<'a, K, V, A>) &mut V {
        return &mut unsafe self.node.vals()[self.idx];
    }

    /// The value, borrowed for as long as the map borrow of the entry.
    pub const fn into_mut(self: BTreeOccupiedEntry<'a, K, V, A>) &'a mut V {
        return &mut unsafe self.node.vals()[self.idx];
    }

    /// Replace the value and return the old one.
    pub const fn insert(self: &mut BTreeOccupiedEntry<'a, K, V, A>, value: V) V {
        return replace(&mut unsafe self.node.vals()[self.idx], value);
    }

    /// Remove the entry from the map and return its value; the stored key is dropped.
    pub fn remove(self: BTreeOccupiedEntry<'a, K, V, A>) V {
        let (_, v, _, _) = self.map.remove_kv(self.node, self.idx, self.height);
        return v;
    }
}

extend<'a, K: Ord, V, A: Allocator> BTreeVacantEntry<'a, K, V, A> {
    /// The key the entry would insert.
    pub const fn key(self: &BTreeVacantEntry<'a, K, V, A>) &K {
        return &self.key;
    }

    /// Insert `value` under the entry's key and return a borrow of it.
    pub fn insert(self: BTreeVacantEntry<'a, K, V, A>, value: V) &'a mut V {
        switch self {
            BTreeVacantEntry { map: map, key: key, leaf: leaf, idx: idx } => {
                let (n, i) = map.insert_leaf(leaf, idx, key, value);
                return &mut unsafe n.vals()[i];
            },
        }
    }
}

extend<'a, K, V> BTreeIter<'a, K, V> as Iterator<(&K, &V)> {
    pub fn next(self: &mut BTreeIter<'a, K, V>) Option<(&K, &V)> {
        if self.len == 0 {
            return None;
        }
        self.len -= 1;
        let (n, i) = self.gaps.next_kv();
        return Some((&unsafe n.keys()[i], &unsafe n.vals()[i]));
    }

    pub fn size_hint(self: &BTreeIter<'a, K, V>) (usize, Option<usize>) {
        return (self.len, Option::<usize>::Some(self.len));
    }
}

extend<'a, K, V> BTreeIter<'a, K, V> as DoubleEndedIterator<(&K, &V)> {
    pub fn next_back(self: &mut BTreeIter<'a, K, V>) Option<(&K, &V)> {
        if self.len == 0 {
            return None;
        }
        self.len -= 1;
        let (n, i) = self.gaps.next_back_kv();
        return Some((&unsafe n.keys()[i], &unsafe n.vals()[i]));
    }
}

extend<'a, K, V> BTreeIterMut<'a, K, V> as Iterator<(&K, &mut V)> {
    pub fn next(self: &mut BTreeIterMut<'a, K, V>) Option<(&K, &mut V)> {
        if self.len == 0 {
            return None;
        }
        self.len -= 1;
        let (n, i) = self.gaps.next_kv();
        return Some((&unsafe n.keys()[i], &mut unsafe n.vals()[i]));
    }

    pub fn size_hint(self: &BTreeIterMut<'a, K, V>) (usize, Option<usize>) {
        return (self.len, Option::<usize>::Some(self.len));
    }
}

extend<'a, K, V> BTreeIterMut<'a, K, V> as DoubleEndedIterator<(&K, &mut V)> {
    pub fn next_back(self: &mut BTreeIterMut<'a, K, V>) Option<(&K, &mut V)> {
        if self.len == 0 {
            return None;
        }
        self.len -= 1;
        let (n, i) = self.gaps.next_back_kv();
        return Some((&unsafe n.keys()[i], &mut unsafe n.vals()[i]));
    }
}

extend<'a, K, V> BTreeKeys<'a, K, V> as Iterator<&K> {
    pub fn next(self: &mut BTreeKeys<'a, K, V>) Option<&K> {
        if self.it.len == 0 {
            return None;
        }
        self.it.len -= 1;
        let (n, i) = self.it.gaps.next_kv();
        return Some(&unsafe n.keys()[i]);
    }

    pub fn size_hint(self: &BTreeKeys<'a, K, V>) (usize, Option<usize>) {
        return (self.it.len, Option::<usize>::Some(self.it.len));
    }
}

extend<'a, K, V> BTreeKeys<'a, K, V> as DoubleEndedIterator<&K> {
    pub fn next_back(self: &mut BTreeKeys<'a, K, V>) Option<&K> {
        if self.it.len == 0 {
            return None;
        }
        self.it.len -= 1;
        let (n, i) = self.it.gaps.next_back_kv();
        return Some(&unsafe n.keys()[i]);
    }
}

extend<'a, K, V> BTreeValues<'a, K, V> as Iterator<&V> {
    pub fn next(self: &mut BTreeValues<'a, K, V>) Option<&V> {
        if self.it.len == 0 {
            return None;
        }
        self.it.len -= 1;
        let (n, i) = self.it.gaps.next_kv();
        return Some(&unsafe n.vals()[i]);
    }

    pub fn size_hint(self: &BTreeValues<'a, K, V>) (usize, Option<usize>) {
        return (self.it.len, Option::<usize>::Some(self.it.len));
    }
}

extend<'a, K, V> BTreeValues<'a, K, V> as DoubleEndedIterator<&V> {
    pub fn next_back(self: &mut BTreeValues<'a, K, V>) Option<&V> {
        if self.it.len == 0 {
            return None;
        }
        self.it.len -= 1;
        let (n, i) = self.it.gaps.next_back_kv();
        return Some(&unsafe n.vals()[i]);
    }
}

extend<'a, K, V> BTreeValuesMut<'a, K, V> as Iterator<&mut V> {
    pub fn next(self: &mut BTreeValuesMut<'a, K, V>) Option<&mut V> {
        if self.it.len == 0 {
            return None;
        }
        self.it.len -= 1;
        let (n, i) = self.it.gaps.next_kv();
        return Some(&mut unsafe n.vals()[i]);
    }

    pub fn size_hint(self: &BTreeValuesMut<'a, K, V>) (usize, Option<usize>) {
        return (self.it.len, Option::<usize>::Some(self.it.len));
    }
}

extend<'a, K, V> BTreeValuesMut<'a, K, V> as DoubleEndedIterator<&mut V> {
    pub fn next_back(self: &mut BTreeValuesMut<'a, K, V>) Option<&mut V> {
        if self.it.len == 0 {
            return None;
        }
        self.it.len -= 1;
        let (n, i) = self.it.gaps.next_back_kv();
        return Some(&mut unsafe n.vals()[i]);
    }
}

extend<'a, K, V> BTreeRange<'a, K, V> as Iterator<(&K, &V)> {
    pub fn next(self: &mut BTreeRange<'a, K, V>) Option<(&K, &V)> {
        if self.gaps.is_empty() {
            return None;
        }
        let (n, i) = self.gaps.next_kv();
        return Some((&unsafe n.keys()[i], &unsafe n.vals()[i]));
    }
}

extend<'a, K, V> BTreeRange<'a, K, V> as DoubleEndedIterator<(&K, &V)> {
    pub fn next_back(self: &mut BTreeRange<'a, K, V>) Option<(&K, &V)> {
        if self.gaps.is_empty() {
            return None;
        }
        let (n, i) = self.gaps.next_back_kv();
        return Some((&unsafe n.keys()[i], &unsafe n.vals()[i]));
    }
}

// Drop every key and value, then free every node.
extend<K: Ord, V, A: Allocator> BTreeMap<K, V, A> as Free {
    pub fn free(self: &mut BTreeMap<K, V, A>) {
        self.clear();
    }
}

extend<K: Ord, V, A: Allocator + Default> BTreeMap<K, V, A> as Default {
    pub const fn default() BTreeMap<K, V, A> {
        return BTreeMap::<K, V, A>::new();
    }
}

extend<K: Ord + Clone, V: Clone, A: Allocator> BTreeMap<K, V, A> as Clone {
    /// A deep copy through the same allocator, with full nodes.
    pub fn clone(self: &BTreeMap<K, V, A>) BTreeMap<K, V, A> {
        let mut out = BTreeMap::<K, V, A>::new_in(self.alloc);
        let mut tail: *mut Leaf<K, V> = null;
        let mut it = self.iter();
        while let Some((k, v)) = it.next() {
            tail = out.push_last(tail, k.clone(), v.clone());
        }
        out.fix_right_border();
        return out;
    }
}

extend<K: Ord, V: Eq, A: Allocator> BTreeMap<K, V, A> as Eq {
    pub fn eq(self: &BTreeMap<K, V, A>, other: &BTreeMap<K, V, A>) bool {
        if self.len != other.len {
            return false;
        }
        let mut a = self.iter();
        let mut b = other.iter();
        while let Some((ka, va)) = a.next() {
            let (kb, vb) = b.next().unwrap();
            if !ka.eq(kb) || !va.eq(vb) {
                return false;
            }
        }
        return true;
    }
}

extend<K: Ord + Hash, V: Hash, A: Allocator> BTreeMap<K, V, A> as Hash {
    /// The length, then each key and value through its own `hash_into`, in key order.
    pub fn hash_into<H: Hasher>(self: &BTreeMap<K, V, A>, h: &mut H) {
        h.write_u64(self.len as u64);
        let mut it = self.iter();
        while let Some((k, v)) = it.next() {
            k.hash_into(h);
            v.hash_into(h);
        }
    }
}

extend<K: Ord + Format, V: Format, A: Allocator> BTreeMap<K, V, A> as Format {
    /// `{k0: v0, k1: v1, ...}` in key order.
    pub fn fmt(self: &BTreeMap<K, V, A>) String {
        let mut s = String::from_str("{");
        let mut first = true;
        let mut it = self.iter();
        while let Some((k, v)) = it.next() {
            if !first {
                s.push_str(", ");
            }
            first = false;
            let ks = k.fmt();
            s.push_string(&ks);
            s.push_str(": ");
            let vs = v.fmt();
            s.push_string(&vs);
        }
        s.push_str("}");
        return s;
    }
}

// Build from a list of pairs: `let m: BTreeMap<i32, i32> = [(1, 10), (2, 20)].into();` A later pair with
// the same key wins, as through `insert`. The slice borrows, so both halves are cloned in. A list in
// strictly increasing key order builds full nodes in O(n).
extend<K: Ord + Clone, V: Clone, A: Allocator + Default> BTreeMap<K, V, A> as From<[](K, V)> {
    pub fn from(value: [](K, V)) BTreeMap<K, V, A> {
        let mut out = BTreeMap::<K, V, A>::new();
        let mut sorted = true;
        for i in 1..value.len() {
            if value.at(i - 1)._0.cmp(&value.at(i)._0) >= 0 {
                sorted = false;
                break;
            }
        }
        if sorted {
            let mut tail: *mut Leaf<K, V> = null;
            for i in 0..value.len() {
                let pair = value.at(i);
                tail = out.push_last(tail, pair._0.clone(), pair._1.clone());
            }
            out.fix_right_border();
            return out;
        }
        for i in 0..value.len() {
            let pair = value.at(i);
            out.insert(pair._0.clone(), pair._1.clone());
        }
        return out;
    }
}

extend<T: Ord, A: Allocator> BTreeSet<T, A> {
    /// An empty set backed by an explicit allocator value; no allocation until the first insert.
    pub const fn new_in(alloc: A) BTreeSet<T, A> {
        return BTreeSet::<T, A> { m: BTreeMap::<T, Member, A>::new_in(alloc) };
    }

    /// Number of elements.
    pub const fn len(self: &BTreeSet<T, A>) usize {
        return self.m.len();
    }

    /// True when no element is stored.
    pub const fn is_empty(self: &BTreeSet<T, A>) bool {
        return self.m.is_empty();
    }

    /// Drops every element and frees every node.
    pub const fn clear(self: &mut BTreeSet<T, A>) {
        self.m.clear();
    }

    /// Insert `value`; true when it was not a member. A duplicate is dropped and the stored element kept.
    pub fn insert(self: &mut BTreeSet<T, A>, value: T) bool {
        return self.m.insert(value, Member {}).is_none();
    }

    /// Remove `value` and drop the stored element; true when it was a member.
    pub fn remove(self: &mut BTreeSet<T, A>, value: &T) bool {
        return self.m.remove(value).is_some();
    }

    /// True when `value` is a member.
    pub fn contains(self: &BTreeSet<T, A>, value: &T) bool {
        return self.m.contains_key(value);
    }

    /// The smallest element, or `None` when empty.
    pub fn first(self: &BTreeSet<T, A>) Option<&T> {
        if let Some((k, _)) = self.m.first_key_value() {
            return Some(k);
        }
        return None;
    }

    /// The largest element, or `None` when empty.
    pub fn last(self: &BTreeSet<T, A>) Option<&T> {
        if let Some((k, _)) = self.m.last_key_value() {
            return Some(k);
        }
        return None;
    }

    /// Remove and return the smallest element, or `None` when empty.
    pub fn pop_first(self: &mut BTreeSet<T, A>) Option<T> {
        if let Some((k, _)) = self.m.pop_first() {
            return Some(k);
        }
        return None;
    }

    /// Remove and return the largest element, or `None` when empty.
    pub fn pop_last(self: &mut BTreeSet<T, A>) Option<T> {
        if let Some((k, _)) = self.m.pop_last() {
            return Some(k);
        }
        return None;
    }

    /// An iterator over the elements in order.
    pub const fn iter(self: &BTreeSet<T, A>) BTreeSetIter<T> {
        return BTreeSetIter::<T> { it: self.m.iter() };
    }

    /// An iterator over the elements between `lo` and `hi`, in order. Panics as `BTreeMap::range` does.
    pub fn range<'s>(self: &'s BTreeSet<T, A>, lo: Bound<&T>, hi: Bound<&T>) BTreeSetRange<'s, T> {
        return BTreeSetRange::<T> { it: BTreeRange::<T, Member> { gaps: self.m.range_gaps(lo, hi) } };
    }

    /// The elements of this set or `other`, in order. O(n + m) for the whole walk.
    pub const fn union_with<'s>(self: &'s BTreeSet<T, A>, other: &'s BTreeSet<T, A>) BTreeUnion<'s, T> {
        let mut a = self.iter();
        let mut b = other.iter();
        let pa = next_ptr(&mut a);
        let pb = next_ptr(&mut b);
        return BTreeUnion::<T> { a: a, b: b, pa: pa, pb: pb };
    }

    /// The elements of both this set and `other`, in order. O(n + m) for the whole walk.
    pub const fn intersection<'s>(self: &'s BTreeSet<T, A>, other: &'s BTreeSet<T, A>) BTreeIntersection<'s, T> {
        let mut a = self.iter();
        let mut b = other.iter();
        let pa = next_ptr(&mut a);
        let pb = next_ptr(&mut b);
        return BTreeIntersection::<T> { a: a, b: b, pa: pa, pb: pb };
    }

    /// The elements of this set that are not in `other`, in order. O(n + m) for the whole walk.
    pub const fn difference<'s>(self: &'s BTreeSet<T, A>, other: &'s BTreeSet<T, A>) BTreeDifference<'s, T> {
        let mut a = self.iter();
        let mut b = other.iter();
        let pa = next_ptr(&mut a);
        let pb = next_ptr(&mut b);
        return BTreeDifference::<T> { a: a, b: b, pa: pa, pb: pb };
    }

    /// The elements of exactly one of this set and `other`, in order. O(n + m) for the whole walk.
    pub const fn symmetric_difference<'s>(self: &'s BTreeSet<T, A>, other: &'s BTreeSet<T, A>) BTreeSymmetricDifference<
        's,
        T
    > {
        let mut a = self.iter();
        let mut b = other.iter();
        let pa = next_ptr(&mut a);
        let pb = next_ptr(&mut b);
        return BTreeSymmetricDifference::<T> { a: a, b: b, pa: pa, pb: pb };
    }

    /// True when every element of this set is in `other`. O(n + m).
    pub fn is_subset(self: &BTreeSet<T, A>, other: &BTreeSet<T, A>) bool {
        if self.len() > other.len() {
            return false;
        }
        let mut b = other.iter();
        let mut pb = next_ptr(&mut b);
        let mut a = self.iter();
        while let Some(x) = a.next() {
            loop {
                if pb == null {
                    return false;
                }
                let c = x.cmp(&unsafe *pb);
                if c < 0 {
                    return false;
                }
                pb = next_ptr(&mut b);
                if c == 0 {
                    break;
                }
            }
        }
        return true;
    }

    /// True when every element of `other` is in this set. O(n + m).
    pub fn is_superset(self: &BTreeSet<T, A>, other: &BTreeSet<T, A>) bool {
        return other.is_subset(self);
    }

    /// True when no element is in both sets. O(n + m).
    pub fn is_disjoint(self: &BTreeSet<T, A>, other: &BTreeSet<T, A>) bool {
        let mut it = self.intersection(other);
        return it.next().is_none();
    }
}

extend<T: Ord, A: Allocator> BTreeSet<T, A> {
    /// The structure self-check of `BTreeMap::check_invariants`, O(n); returns the height.
    pub fn check_invariants(self: &BTreeSet<T, A>) usize {
        return self.m.check_invariants();
    }
}

extend<T: Ord, A: Allocator + Default> BTreeSet<T, A> {
    /// An empty set using the default allocator; no allocation until the first insert.
    pub const fn new() BTreeSet<T, A> {
        return BTreeSet::<T, A>::new_in(A::default());
    }
}

// The next element of a set iterator as a pointer, null at its end.
const fn next_ptr<'a, T>(it: &mut BTreeSetIter<'a, T>) *const T {
    if let Some(x) = it.next() {
        return x;
    }
    return null;
}

extend<'a, T> BTreeSetIter<'a, T> as Iterator<&T> {
    pub fn next(self: &mut BTreeSetIter<'a, T>) Option<&T> {
        if self.it.len == 0 {
            return None;
        }
        self.it.len -= 1;
        let (n, i) = self.it.gaps.next_kv();
        return Some(&unsafe n.keys()[i]);
    }

    pub fn size_hint(self: &BTreeSetIter<'a, T>) (usize, Option<usize>) {
        return (self.it.len, Option::<usize>::Some(self.it.len));
    }
}

extend<'a, T> BTreeSetIter<'a, T> as DoubleEndedIterator<&T> {
    pub fn next_back(self: &mut BTreeSetIter<'a, T>) Option<&T> {
        if self.it.len == 0 {
            return None;
        }
        self.it.len -= 1;
        let (n, i) = self.it.gaps.next_back_kv();
        return Some(&unsafe n.keys()[i]);
    }
}

extend<'a, T> BTreeSetRange<'a, T> as Iterator<&T> {
    pub fn next(self: &mut BTreeSetRange<'a, T>) Option<&T> {
        if self.it.gaps.is_empty() {
            return None;
        }
        let (n, i) = self.it.gaps.next_kv();
        return Some(&unsafe n.keys()[i]);
    }
}

extend<'a, T> BTreeSetRange<'a, T> as DoubleEndedIterator<&T> {
    pub fn next_back(self: &mut BTreeSetRange<'a, T>) Option<&T> {
        if self.it.gaps.is_empty() {
            return None;
        }
        let (n, i) = self.it.gaps.next_back_kv();
        return Some(&unsafe n.keys()[i]);
    }
}

extend<'a, T: Ord> BTreeUnion<'a, T> as Iterator<&T> {
    pub fn next(self: &mut BTreeUnion<'a, T>) Option<&T> {
        let r = self.pa;
        if r == null {
            if self.pb == null {
                return None;
            }
            let rb = self.pb;
            self.pb = next_ptr(&mut self.b);
            return Some(unsafe &*rb);
        }
        if self.pb != null {
            let c = (unsafe *r).cmp(&unsafe *self.pb);
            if c > 0 {
                let rb = self.pb;
                self.pb = next_ptr(&mut self.b);
                return Some(unsafe &*rb);
            }
            if c == 0 {
                self.pb = next_ptr(&mut self.b);
            }
        }
        self.pa = next_ptr(&mut self.a);
        return Some(unsafe &*r);
    }
}

extend<'a, T: Ord> BTreeIntersection<'a, T> as Iterator<&T> {
    pub fn next(self: &mut BTreeIntersection<'a, T>) Option<&T> {
        while self.pa != null && self.pb != null {
            let c = (unsafe *self.pa).cmp(&unsafe *self.pb);
            if c < 0 {
                self.pa = next_ptr(&mut self.a);
            } else if c > 0 {
                self.pb = next_ptr(&mut self.b);
            } else {
                let r = self.pa;
                self.pa = next_ptr(&mut self.a);
                self.pb = next_ptr(&mut self.b);
                return Some(unsafe &*r);
            }
        }
        return None;
    }
}

extend<'a, T: Ord> BTreeDifference<'a, T> as Iterator<&T> {
    pub fn next(self: &mut BTreeDifference<'a, T>) Option<&T> {
        while self.pa != null {
            if self.pb == null {
                let r = self.pa;
                self.pa = next_ptr(&mut self.a);
                return Some(unsafe &*r);
            }
            let c = (unsafe *self.pa).cmp(&unsafe *self.pb);
            if c < 0 {
                let r = self.pa;
                self.pa = next_ptr(&mut self.a);
                return Some(unsafe &*r);
            }
            if c == 0 {
                self.pa = next_ptr(&mut self.a);
            }
            self.pb = next_ptr(&mut self.b);
        }
        return None;
    }
}

extend<'a, T: Ord> BTreeSymmetricDifference<'a, T> as Iterator<&T> {
    pub fn next(self: &mut BTreeSymmetricDifference<'a, T>) Option<&T> {
        loop {
            if self.pa == null {
                if self.pb == null {
                    return None;
                }
                let rb = self.pb;
                self.pb = next_ptr(&mut self.b);
                return Some(unsafe &*rb);
            }
            if self.pb == null {
                let ra = self.pa;
                self.pa = next_ptr(&mut self.a);
                return Some(unsafe &*ra);
            }
            let c = (unsafe *self.pa).cmp(&unsafe *self.pb);
            if c < 0 {
                let ra = self.pa;
                self.pa = next_ptr(&mut self.a);
                return Some(unsafe &*ra);
            }
            if c > 0 {
                let rb = self.pb;
                self.pb = next_ptr(&mut self.b);
                return Some(unsafe &*rb);
            }
            self.pa = next_ptr(&mut self.a);
            self.pb = next_ptr(&mut self.b);
        }
    }
}

extend<T: Ord, A: Allocator> BTreeSet<T, A> as Free {
    pub fn free(self: &mut BTreeSet<T, A>) {
        self.m.clear();
    }
}

extend<T: Ord, A: Allocator + Default> BTreeSet<T, A> as Default {
    pub const fn default() BTreeSet<T, A> {
        return BTreeSet::<T, A>::new();
    }
}

extend<T: Ord + Clone, A: Allocator> BTreeSet<T, A> as Clone {
    /// A deep copy through the same allocator, with full nodes.
    pub fn clone(self: &BTreeSet<T, A>) BTreeSet<T, A> {
        let mut out = BTreeSet::<T, A>::new_in(self.m.alloc);
        let mut tail: *mut Leaf<T, Member> = null;
        let mut it = self.iter();
        while let Some(x) = it.next() {
            tail = out.m.push_last(tail, x.clone(), Member {});
        }
        out.m.fix_right_border();
        return out;
    }
}

extend<T: Ord, A: Allocator> BTreeSet<T, A> as Eq {
    pub fn eq(self: &BTreeSet<T, A>, other: &BTreeSet<T, A>) bool {
        if self.len() != other.len() {
            return false;
        }
        let mut a = self.iter();
        let mut b = other.iter();
        while let Some(x) = a.next() {
            if !x.eq(b.next().unwrap()) {
                return false;
            }
        }
        return true;
    }
}

extend<T: Ord + Hash, A: Allocator> BTreeSet<T, A> as Hash {
    /// The length, then each element through its own `hash_into`, in order.
    pub fn hash_into<H: Hasher>(self: &BTreeSet<T, A>, h: &mut H) {
        h.write_u64(self.len() as u64);
        let mut it = self.iter();
        while let Some(x) = it.next() {
            x.hash_into(h);
        }
    }
}

extend<T: Ord + Format, A: Allocator> BTreeSet<T, A> as Format {
    /// `{e0, e1, ...}` in order.
    pub fn fmt(self: &BTreeSet<T, A>) String {
        let mut s = String::from_str("{");
        let mut first = true;
        let mut it = self.iter();
        while let Some(x) = it.next() {
            if !first {
                s.push_str(", ");
            }
            first = false;
            let xs = x.fmt();
            s.push_string(&xs);
        }
        s.push_str("}");
        return s;
    }
}

// Build from a list of elements: `let s: BTreeSet<i32> = [3, 1, 2].into();` (duplicates collapse). The
// slice borrows, so each element is cloned in.
extend<T: Ord + Clone, A: Allocator + Default> BTreeSet<T, A> as From<[]T> {
    pub fn from(value: []T) BTreeSet<T, A> {
        let mut out = BTreeSet::<T, A>::new();
        for i in 0..value.len() {
            out.insert(value.at(i).clone());
        }
        return out;
    }
}
