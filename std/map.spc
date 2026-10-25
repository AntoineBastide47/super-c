// Map<K, V, A = Global, S = DefaultHash>: an open-addressing hash map (linear probing, backward-shift
// deletion), monomorphized per (K, V, allocator, hash builder). The key type must be `Hash + Eq`; `get`
// borrows the value (`Option<&V>`), `remove` moves it out (`Option<V>`). The three parallel arrays are
// obtained through allocator `A` (stored in the map; zero bytes when it is the zero-sized `Global`).
// Auto-`Free` (deep-frees keys and values at scope exit). Auto-imported (prelude). `new()` uses a
// default-constructed allocator and hash builder; pass a stateful arena or pool with `new_in`, a keyed
// builder with `with_hasher`, or pick a zero-sized allocator with a turbofish: `Map::<K, V, MyAlloc>::new()`.
//
// Hashing: the builder `S` turns a key into the 64-bit hash whose low bits pick the slot. The default,
// `DefaultHash`, feeds the key's `hash_into` to a `DefaultHasher`: deterministic, so the
// iteration order of a program is the same on every run, and unkeyed, so keys chosen to collide make
// probing linear in the map's size. A map whose keys come from untrusted input takes the keyed builder
// of `std::hash::keyed`.
//
// Complexity (n entries): insert, get, get_mut, contains_key, remove and entry are O(1) on average and
// O(n) in the worst case (colliding keys); the table doubles past a load factor of 3/4, so n inserts move
// O(n) entries in total. Iteration visits every slot: O(capacity). clear is O(capacity) and keeps the
// storage. One allocation per array per growth, none per entry.
//
// Invalidation: insert, entry (when the key is absent), reserve and remove may move entries: they end
// every borrow of the map, so no reference or iterator survives them (the borrow checker enforces it).
// Iteration order is slot order: deterministic for a given sequence of operations and hash builder, but
// not insertion order, and it changes when the table grows.
//
// Thread safety: no internal synchronization; a Map is Send / Sync when its parts are.

extern "C" {
    fn memset(dst: *mut void, value: i32, n: usize) *mut void;
}

/// The prelude's unkeyed, deterministic hasher. Each 64-bit word is xored into the state, the state's
/// high half is folded into its low half, and the result is spread by a multiply by 2^64 / phi; `finish`
/// folds once more. An integer key costs one fold and one multiply, and a caller that packs two ids into
/// one key still spreads both, because the low bits a table indexes by see the high half. Bytes go in
/// as little-endian words, 8 per round; a partial last word carries its byte count in its top byte, so
/// trailing zero bytes change the hash.
pub struct DefaultHasher {
    pub(file) h: u64,
}

extend DefaultHasher {
    /// A hasher in its initial state.
    @always_inline
    pub const fn new() DefaultHasher {
        return DefaultHasher { h: 0 };
    }
}

extend DefaultHasher as Hasher {
    @always_inline
    pub const fn write_u64(self: &mut DefaultHasher, v: u64) {
        let x = self.h ^ v;
        self.h = (x ^ x >> 32).wrapping_mul(0x9E3779B97F4A7C15u64);
    }

    @always_inline
    pub const fn write_u8(self: &mut DefaultHasher, v: u8) {
        self.write_u64(v);
    }

    pub const fn write(self: &mut DefaultHasher, bytes: []u8) {
        let n = bytes.len;
        let mut i: usize = 0;
        while i + 8 <= n {
            // Assembled from bytes, which C compilers turn into one unaligned load.
            let mut w: u64 = 0;
            for k in 0..8usize {
                w = w | (unsafe bytes.ptr[i + k]) as u64 << (8 * k) as u64;
            }
            self.write_u64(w);
            i += 8;
        }
        if i < n {
            let mut w = (n - i) as u64 << 56;
            for k in 0..n - i {
                w = w | (unsafe bytes.ptr[i + k]) as u64 << (8 * k) as u64;
            }
            self.write_u64(w);
        }
    }

    @always_inline
    pub const fn finish(self: &DefaultHasher) u64 {
        return self.h ^ self.h >> 32;
    }
}

/// The prelude's 64-bit hash of `value`: its `hash_into` through a fresh `DefaultHasher`. Deterministic
/// and unkeyed; equal values hash alike.
@always_inline
pub const fn hash<T: Hash>(value: &T) u64 {
    let mut h = DefaultHasher::new();
    value.hash_into(&mut h);
    return h.finish();
}

/// The unkeyed, deterministic hash builder: `hash(key)`. Zero bytes.
@derive(Copy)
pub struct DefaultHash {}

extend DefaultHash as BuildHasher {
    @always_inline
    pub const fn hash_one<K: Hash>(self: &DefaultHash, key: &K) u64 {
        return hash(key);
    }
}

extend DefaultHash as Default {
    pub const fn default() DefaultHash {
        return DefaultHash {};
    }
}

/// Which entries `Map::retain_with` keeps. Passed by value, so the rule's call is direct.
pub(package) interface MapKeep<K, V>: Copy {
    fn keep(self: Self, key: &K, value: &mut V) bool;
}

// A caller's rule over the key and the value.
struct FnKeep<F> {
    pub f: F,
}

extend<K, V, F: fn(&K, &mut V) bool> FnKeep<F> as MapKeep<K, V> {
    @always_inline
    pub fn keep(self: FnKeep<F>, key: &K, value: &mut V) bool {
        return self.f(key, value);
    }
}

/// A caller's rule over the key alone (`Set::retain`).
pub(package) struct KeyKeep<F> {
    pub f: F,
}

extend<K, V, F: fn(&K) bool> KeyKeep<F> as MapKeep<K, V> {
    @always_inline
    pub fn keep(self: KeyKeep<F>, key: &K, value: &mut V) bool {
        return self.f(key);
    }
}

/// An open-addressing hash map from K to V through allocator A, hashed by S. Iteration order is slot
/// order, not insertion order.
pub struct Map<K, V, A = Global, S = DefaultHash> {
    pub(file) keys: *mut K, // parallel arrays, slot i valid when used[i] == 1 (private)
    pub(file) vals: *mut V,
    pub(file) used: *mut u8, // 0 = empty, 1 = occupied
    pub(file) len: usize, // occupied slots
    pub(file) cap: usize, // total slots; ALWAYS a power of two (grow doubles from 8) so slot() can mask
    pub(file) alloc: A, // the allocator the arrays were obtained through (private; zero-sized for Global)
    pub(file) hasher: S, // the hash builder (private; zero-sized for DefaultHash)
}

unsafe extend<K, V, A, S> Map<K, V, A, S> as Zeroable {}
// A Map owns its keys and values, so it is Send / Sync when they, its allocator and its builder are.
unsafe extend<K: Send, V: Send, A: Send, S: Send> Map<K, V, A, S> as Send {}

unsafe extend<K: Sync, V: Sync, A: Sync, S: Sync> Map<K, V, A, S> as Sync {}

extend<K: Hash + Eq, V, A: Allocator, S: BuildHasher> Map<K, V, A, S> {
    /// Empty map backed by an explicit allocator and hash builder; no allocation until the first insert.
    pub const fn with_hasher_in(alloc: A, hasher: S) Map<K, V, A, S> {
        return Map::<K, V, A, S> { keys: null, vals: null, used: null, len: 0, cap: 0, alloc: alloc, hasher: hasher };
    }

    /// Number of entries.
    pub const fn len(self: &Map<K, V, A, S>) usize {
        return self.len;
    }

    /// True when no entry is stored.
    pub const fn is_empty(self: &Map<K, V, A, S>) bool {
        return self.len == 0;
    }

    /// The number of entries the map holds before its next growth.
    pub const fn capacity(self: &Map<K, V, A, S>) usize {
        if self.cap == 0 {
            return 0;
        }
        return (self.cap * 3 - 1) / 4;
    }

    /// The hash builder.
    pub const fn hasher(self: &Map<K, V, A, S>) &S {
        return &self.hasher;
    }

    // The slot a key occupies, or the first empty slot on its probe sequence. Requires cap > 0.
    // cap is always a power of two (grow doubles from 8), so the bucket modulo is a bit-mask.
    @always_inline
    const fn slot(self: &Map<K, V, A, S>, key: &K) usize {
        let mut i = self.hasher.hash_one(key) as usize & self.cap - 1;
        while unsafe self.used[i] != 0 {
            if unsafe self.keys[i] == *key {
                return i;
            }
            i = i + 1;
            if i >= self.cap {
                i = 0;
            }
        }
        return i;
    }

    // True when one more entry passes the 0.75 load factor.
    @always_inline
    const fn needs_grow(self: &Map<K, V, A, S>) bool {
        return self.cap == 0 || (self.len + 1) * 4 >= self.cap * 3;
    }

    // Reallocate to `newcap` slots (a power of two, at least 8) and rehash every occupied entry into it.
    // (Three separate arrays by REQUIREMENT, not oversight: the compile-time evaluator's abstract heap
    // types each allocation by its element: a single block carved with byte-offset interior pointers is
    // not evaluable, and Map folds at compile time are a language feature.)
    const fn rehash_to(self: &mut Map<K, V, A, S>, newcap: usize) {
        let oldkeys = self.keys;
        let oldvals = self.vals;
        let oldused = self.used;
        let oldcap = self.cap;
        // Zero-sized keys or values occupy no bytes: the aligned sentinel, no allocator call.
        if sizeof(K) == 0 {
            self.keys = dangling::<K>();
        } else {
            self.keys = (unsafe self.alloc.alloc(newcap * sizeof(K), alignof(K))) as *mut K;
        }
        if sizeof(V) == 0 {
            self.vals = dangling::<V>();
        } else {
            self.vals = (unsafe self.alloc.alloc(newcap * sizeof(V), alignof(V))) as *mut V;
        }
        self.used = (unsafe self.alloc.alloc(newcap, alignof(u8))) as *mut u8;
        // Mark every slot empty.
        unsafe memset(self.used, 0, newcap);
        self.cap = newcap;
        self.len = 0;
        for i in 0..oldcap {
            if unsafe oldused[i] == 1 {
                let j = self.slot(&unsafe oldkeys[i]);
                unsafe self.keys[j] = unsafe oldkeys[i];
                unsafe self.vals[j] = unsafe oldvals[i];
                unsafe self.used[j] = 1;
                self.len = self.len + 1;
            }
        }
        if oldcap > 0 {
            if sizeof(K) != 0 {
                unsafe self.alloc.dealloc(oldkeys, oldcap * sizeof(K), alignof(K));
            }
            if sizeof(V) != 0 {
                unsafe self.alloc.dealloc(oldvals, oldcap * sizeof(V), alignof(V));
            }
            unsafe self.alloc.dealloc(oldused, oldcap, alignof(u8));
        }
    }

    // Double the table (from 8).
    const fn grow(self: &mut Map<K, V, A, S>) {
        let mut newcap = self.cap * 2;
        if newcap < 8 {
            newcap = 8;
        }
        self.rehash_to(newcap);
    }

    /// Room for `additional` more entries without a growth: one rehash at most. Panics when the slot
    /// count overflows.
    pub fn reserve(self: &mut Map<K, V, A, S>, additional: usize) {
        if additional > ~(0 as usize) / 8 - self.len {
            panic("Map: capacity overflow");
        }
        let want = self.len + additional;
        if self.cap != 0 && want * 4 < self.cap * 3 {
            return;
        }
        let mut newcap: usize = 8;
        while want * 4 >= newcap * 3 {
            newcap = newcap * 2;
        }
        if newcap > self.cap {
            self.rehash_to(newcap);
        }
    }

    /// Drop every entry (deep-freeing keys and values) but KEEP the table storage for reuse: a
    /// cleared map re-fills without touching the allocator. Storage more than 8 times larger than the
    /// entries (an earlier fill grew it) is released instead, so a clear costs O(entries) amortized: a
    /// map that keeps its size never grows past 3 times its entries.
    pub fn clear(self: &mut Map<K, V, A, S>) {
        // An empty map has every slot unused (`remove` shifts entries back, leaving no tombstones).
        if self.len == 0 {
            return;
        }
        let mut left = self.len;
        for i in 0..self.cap {
            if unsafe self.used[i] != 0 {
                // No-op if K isn't Free.
                unsafe self.keys[i].free();
                // No-op if V isn't Free.
                unsafe self.vals[i].free();
                left -= 1;
                if left == 0 {
                    break;
                }
            }
        }
        if self.cap > 64 && self.cap > 8 * self.len {
            self.release();
        } else {
            unsafe memset(self.used, 0, self.cap);
        }
        self.len = 0;
    }

    // Return the table storage to the allocator: the map holds no entry, and grows again from empty.
    fn release(self: &mut Map<K, V, A, S>) {
        if sizeof(K) != 0 {
            unsafe self.alloc.dealloc(self.keys, self.cap * sizeof(K), alignof(K));
        }
        if sizeof(V) != 0 {
            unsafe self.alloc.dealloc(self.vals, self.cap * sizeof(V), alignof(V));
        }
        unsafe self.alloc.dealloc(self.used, self.cap, alignof(u8));
        self.keys = null;
        self.vals = null;
        self.used = null;
        self.len = 0;
        self.cap = 0;
    }

    /// Insert or overwrite `key` -> `value`. On overwrite the existing key is kept; the duplicate key and the
    /// replaced value are freed (no-ops for non-Free types). Takes ownership of `key` and `value`.
    @always_inline
    pub const fn insert(self: &mut Map<K, V, A, S>, key: K, value: V) {
        if self.needs_grow() {
            // Grow past a 0.75 load factor.
            self.grow();
        }
        let i = self.slot(&key);
        if unsafe self.used[i] != 0 {
            // A store through the raw pointer frees nothing, so the replaced value is freed here.
            unsafe self.vals[i].free();
            unsafe self.vals[i] = value;
            return;
        }
        unsafe self.keys[i] = key;
        unsafe self.vals[i] = value;
        unsafe self.used[i] = 1;
        self.len = self.len + 1;
    }

    /// A borrow of the value for `key`, or `None`. Borrowing (`&V`) keeps the Map the sole owner.
    @always_inline
    pub const fn get(self: &Map<K, V, A, S>, key: &K) Option<&V> {
        if self.cap == 0 {
            return Option::<&V>::None;
        }
        let i = self.slot(key);
        if unsafe self.used[i] == 0 {
            return Option::<&V>::None;
        }
        return Option::<&V>::Some(&unsafe self.vals[i]);
    }

    /// The stored key and its value for `key`, or `None`.
    pub const fn get_key_value(self: &Map<K, V, A, S>, key: &K) Option<(&K, &V)> {
        if self.cap == 0 {
            return Option::<(&K, &V)>::None;
        }
        let i = self.slot(key);
        if unsafe self.used[i] == 0 {
            return Option::<(&K, &V)>::None;
        }
        return Option::<(&K, &V)>::Some((&unsafe self.keys[i], &unsafe self.vals[i]));
    }

    /// A MUTABLE borrow of the value for `key`, or `None`. Holds the Map borrowed for as long as the
    /// result lives, so the entry cannot be rehashed out from under it.
    pub const fn get_mut(self: &mut Map<K, V, A, S>, key: &K) Option<&mut V> {
        if self.cap == 0 {
            return Option::<&mut V>::None;
        }
        let i = self.slot(key);
        if unsafe self.used[i] == 0 {
            return Option::<&mut V>::None;
        }
        return Option::<&mut V>::Some(&mut unsafe self.vals[i]);
    }

    /// True when `key` has an entry.
    pub const fn contains_key(self: &Map<K, V, A, S>, key: &K) bool {
        return self.get(key).is_some();
    }

    // Empty slot `i` (its key and value already moved out or freed) and re-place the rest of its probe
    // cluster, so no lookup is cut short (backward-shift deletion: no tombstones). Each re-placed entry
    // lands at or after `i` within the cluster.
    const fn vacate(self: &mut Map<K, V, A, S>, i: usize) {
        unsafe self.used[i] = 0;
        self.len = self.len - 1;
        let mut j = i + 1;
        if j >= self.cap {
            j = 0;
        }
        while unsafe self.used[j] == 1 {
            let k = unsafe self.keys[j];
            let v = unsafe self.vals[j];
            unsafe self.used[j] = 0;
            let t = self.slot(&k);
            unsafe self.keys[t] = k;
            unsafe self.vals[t] = v;
            unsafe self.used[t] = 1;
            j = j + 1;
            if j >= self.cap {
                j = 0;
            }
        }
    }

    /// Remove `key`, returning its value (`None` if absent); the stored key is freed.
    pub const fn remove(self: &mut Map<K, V, A, S>, key: &K) Option<V> {
        if self.cap == 0 {
            return Option::<V>::None;
        }
        let i = self.slot(key);
        if unsafe self.used[i] == 0 {
            return Option::<V>::None;
        }
        let removed = unsafe self.vals[i];
        // The stored key is not handed out, so it is freed here (no-op if K isn't Free).
        unsafe self.keys[i].free();
        self.vacate(i);
        return Option::<V>::Some(removed);
    }

    /// Remove `key`, returning the stored key and its value (`None` if absent).
    pub const fn remove_entry(self: &mut Map<K, V, A, S>, key: &K) Option<(K, V)> {
        if self.cap == 0 {
            return Option::<(K, V)>::None;
        }
        let i = self.slot(key);
        if unsafe self.used[i] == 0 {
            return Option::<(K, V)>::None;
        }
        let k = unsafe self.keys[i];
        let v = unsafe self.vals[i];
        self.vacate(i);
        return Option::<(K, V)>::Some((k, v));
    }

    /// Keep only the entries for which `keep(key, value)` holds; the others are freed. `keep` runs once
    /// per entry and may change the value. O(capacity).
    pub fn retain<F: fn(&K, &mut V) bool>(self: &mut Map<K, V, A, S>, keep: F) {
        self.retain_with(FnKeep::<F> { f: keep });
    }

    /// `retain` through a keep rule object; `Set::retain` passes one that reads the key only.
    pub(package) fn retain_with<R: MapKeep<K, V>>(self: &mut Map<K, V, A, S>, rule: R) {
        if self.len == 0 {
            return;
        }
        // Start after an empty slot, so every cluster is walked from its first slot: a removal re-places
        // only entries later in the same cluster, which the walk has not reached yet.
        let mask = self.cap - 1;
        let mut e: usize = 0;
        while unsafe self.used[e] != 0 {
            e += 1;
        }
        for k in 0..self.cap {
            let i = e + 1 + k & mask;
            while unsafe self.used[i] != 0 && !rule.keep(&unsafe self.keys[i], &mut unsafe self.vals[i]) {
                unsafe self.keys[i].free();
                unsafe self.vals[i].free();
                self.vacate(i);
            }
        }
    }

    /// The entry for `key`: occupied, or vacant and ready to take a value without a second lookup. An
    /// absent key may grow the table first, so the vacant slot stays valid. The given key is freed when
    /// the entry is occupied (the stored key is kept).
    pub fn entry(self: &mut Map<K, V, A, S>, key: K) Entry<K, V, A, S> {
        if self.cap != 0 {
            let i = self.slot(&key);
            if unsafe self.used[i] != 0 {
                return Entry::<K, V, A, S>::Occupied(OccupiedEntry::<K, V, A, S> { map: self, slot: i });
            }
            if !self.needs_grow() {
                return Entry::<K, V, A, S>::Vacant(VacantEntry::<K, V, A, S> { map: self, key: key, slot: i });
            }
        }
        self.grow();
        let i = self.slot(&key);
        return Entry::<K, V, A, S>::Vacant(VacantEntry::<K, V, A, S> { map: self, key: key, slot: i });
    }

    /// Move every entry out, leaving the map empty with its storage kept. The entries the iterator does
    /// not yield are freed when it is dropped.
    pub const fn drain(self: &mut Map<K, V, A, S>) MapDrain<K, V, A, S> {
        return MapDrain::<K, V, A, S> { map: self, idx: 0 };
    }
}

// Constructors that default-construct the allocator or the hash builder.
extend<K: Hash + Eq, V, A: Allocator, S: BuildHasher + Default> Map<K, V, A, S> {
    /// Empty map backed by an explicit allocator value (a stateful arena/pool handle, or a zero-sized tag).
    pub const fn new_in(alloc: A) Map<K, V, A, S> {
        return Map::<K, V, A, S>::with_hasher_in(alloc, S::default());
    }
}

extend<K: Hash + Eq, V, A: Allocator + Default, S: BuildHasher> Map<K, V, A, S> {
    /// Empty map using the default allocator and the given hash builder.
    pub const fn with_hasher(hasher: S) Map<K, V, A, S> {
        return Map::<K, V, A, S>::with_hasher_in(A::default(), hasher);
    }
}

extend<K: Hash + Eq, V, A: Allocator + Default, S: BuildHasher + Default> Map<K, V, A, S> {
    /// An empty map using the default allocator; storage is allocated on the first insert.
    pub const fn new() Map<K, V, A, S> {
        return Map::<K, V, A, S>::with_hasher_in(A::default(), S::default());
    }
}

// Free the three arrays AND deep-free every stored key/value. Auto-`Free`: the Map is released at scope
// exit. Sound because `get` borrows the value (`&V`) and `remove` moves it out, so each live key/value is
// owned only by its slot. Each occupied key/value `.free()` is a no-op when K / V isn't a Free type.
extend<K: Hash + Eq, V, A: Allocator, S: BuildHasher> Map<K, V, A, S> as Free {
    pub fn free(self: &mut Map<K, V, A, S>) {
        for i in 0..self.cap {
            if unsafe self.used[i] != 0 {
                // No-op if K isn't Free.
                unsafe self.keys[i].free();
                // No-op if V isn't Free.
                unsafe self.vals[i].free();
            }
        }
        self.release();
    }
}

// Build from a list of pairs: `let m: Map<i32, i32> = [(1, 10), (2, 20)].into();` A later pair with the
// same key wins, as it would through `insert`. The slice borrows, so both halves are cloned in.
extend<K: Hash + Eq + Clone, V: Clone, A: Allocator + Default, S: BuildHasher + Default> Map<K, V, A, S> as From<
    [](K, V)
> {
    pub fn from(value: [](K, V)) Map<K, V, A, S> {
        let mut out = Map::<K, V, A, S>::new();
        out.reserve(value.len());
        for i in 0..value.len() {
            let pair = value.at(i);
            out.insert(pair._0.clone(), pair._1.clone());
        }
        return out;
    }
}

extend<K: Hash + Eq, V, A: Allocator + Default, S: BuildHasher + Default> Map<K, V, A, S> as Default {
    pub const fn default() Map<K, V, A, S> {
        return Map::<K, V, A, S>::new();
    }
}

// A deep copy keeps every entry in its slot: no rehash, and the clone iterates in the same order.
extend<K: Hash + Eq + Clone, V: Clone, A: Allocator, S: BuildHasher> Map<K, V, A, S> as Clone {
    pub fn clone(self: &Map<K, V, A, S>) Map<K, V, A, S> {
        let mut out = Map::<K, V, A, S>::with_hasher_in(self.alloc, self.hasher);
        if self.cap == 0 {
            return out;
        }
        if sizeof(K) == 0 {
            out.keys = dangling::<K>();
        } else {
            out.keys = (unsafe out.alloc.alloc(self.cap * sizeof(K), alignof(K))) as *mut K;
        }
        if sizeof(V) == 0 {
            out.vals = dangling::<V>();
        } else {
            out.vals = (unsafe out.alloc.alloc(self.cap * sizeof(V), alignof(V))) as *mut V;
        }
        out.used = (unsafe out.alloc.alloc(self.cap, alignof(u8))) as *mut u8;
        unsafe memset(out.used, 0, self.cap);
        out.cap = self.cap;
        for i in 0..self.cap {
            if unsafe self.used[i] != 0 {
                unsafe out.keys[i] = (unsafe self.keys[i]).clone();
                unsafe out.vals[i] = (unsafe self.vals[i]).clone();
                unsafe out.used[i] = 1;
                out.len = out.len + 1;
            }
        }
        return out;
    }
}

// Two maps are equal when they hold the same keys with equal values, whatever their slot order.
extend<K: Hash + Eq, V: Eq, A: Allocator, S: BuildHasher> Map<K, V, A, S> as Eq {
    pub fn eq(self: &Map<K, V, A, S>, other: &Map<K, V, A, S>) bool {
        if self.len != other.len {
            return false;
        }
        for i in 0..self.cap {
            if unsafe self.used[i] != 0 {
                switch other.get(&unsafe self.keys[i]) {
                    Some(v) => {
                        if *v != unsafe self.vals[i] {
                            return false;
                        }
                    },
                    None => {
                        return false;
                    },
                };
            }
        }
        return true;
    }
}

extend<K: Hash + Eq + Format, V: Format, A: Allocator, S: BuildHasher> Map<K, V, A, S> as Format {
    /// `{k: v, ...}` in slot order.
    pub fn fmt(self: &Map<K, V, A, S>) String {
        let mut s = String::from_str("{");
        let mut first = true;
        for i in 0..self.cap {
            if unsafe self.used[i] != 0 {
                if !first {
                    s.push_str(", ");
                }
                first = false;
                let ks = (unsafe self.keys[i]).fmt();
                s.push_string(&ks);
                s.push_str(": ");
                let vs = (unsafe self.vals[i]).fmt();
                s.push_string(&vs);
            }
        }
        s.push_str("}");
        return s;
    }
}

/// The slot of a map an `entry` call found: the key is present, or absent with its slot reserved.
pub enum Entry<'a, K, V, A, S> {
    Occupied(OccupiedEntry<'a, K, V, A, S>),
    Vacant(VacantEntry<'a, K, V, A, S>),
}

/// A present key's entry; it borrows the map.
pub struct OccupiedEntry<'a, K, V, A, S> {
    pub(file) map: &'a mut Map<K, V, A, S>,
    pub(file) slot: usize,
}

/// An absent key's entry: the key and the empty slot it takes; it borrows the map.
pub struct VacantEntry<'a, K, V, A, S> {
    pub(file) map: &'a mut Map<K, V, A, S>,
    pub(file) key: K,
    pub(file) slot: usize,
}

extend<'a, K: Hash + Eq, V, A: Allocator, S: BuildHasher> Entry<'a, K, V, A, S> {
    /// The value, inserting `value` first when the key is absent (an unused `value` is freed).
    pub fn or_insert(self: Entry<'a, K, V, A, S>, value: V) &'a mut V {
        return switch self {
            Occupied(o) => o.into_mut(),
            Vacant(v) => v.insert(value),
        };
    }

    /// The value, inserting `make()` first when the key is absent (`make` runs only then).
    pub fn or_insert_with<F: fn move() V>(self: Entry<'a, K, V, A, S>, make: F) &'a mut V {
        return switch self {
            Occupied(o) => o.into_mut(),
            Vacant(v) => v.insert(make()),
        };
    }

    /// Run `f` on the value when the key is present, then hand the entry back.
    pub fn and_modify<F: fn(&mut V)>(self: Entry<'a, K, V, A, S>, f: F) Entry<'a, K, V, A, S> {
        return switch self {
            Occupied(o) => {
                f(&mut unsafe o.map.vals[o.slot]);
                Entry::<K, V, A, S>::Occupied(o);
            },
            Vacant(v) => Entry::<K, V, A, S>::Vacant(v),
        };
    }

    /// The key: the stored one when present, the given one when absent.
    pub const fn key(self: &Entry<'a, K, V, A, S>) &K {
        return switch self {
            Occupied(o) => &unsafe o.map.keys[o.slot],
            Vacant(v) => &v.key,
        };
    }
}

extend<'a, K: Hash + Eq, V: Default, A: Allocator, S: BuildHasher> Entry<'a, K, V, A, S> {
    /// The value, inserting `V::default()` first when the key is absent.
    pub fn or_default(self: Entry<'a, K, V, A, S>) &'a mut V {
        return switch self {
            Occupied(o) => o.into_mut(),
            Vacant(v) => v.insert(V::default()),
        };
    }
}

extend<'a, K: Hash + Eq, V, A: Allocator, S: BuildHasher> OccupiedEntry<'a, K, V, A, S> {
    /// The stored key.
    pub const fn key(self: &OccupiedEntry<'a, K, V, A, S>) &K {
        return &unsafe self.map.keys[self.slot];
    }

    /// The value.
    pub const fn get(self: &OccupiedEntry<'a, K, V, A, S>) &V {
        return &unsafe self.map.vals[self.slot];
    }

    /// The value, writable.
    pub const fn get_mut(self: &mut OccupiedEntry<'a, K, V, A, S>) &mut V {
        return &mut unsafe self.map.vals[self.slot];
    }

    /// The value, writable, for as long as the map borrow lasts.
    pub fn into_mut(self: OccupiedEntry<'a, K, V, A, S>) &'a mut V {
        return switch self {
            OccupiedEntry { map: map, slot: slot } => &mut unsafe map.vals[slot],
        };
    }

    /// Replace the value, returning the old one.
    pub const fn insert(self: &mut OccupiedEntry<'a, K, V, A, S>, value: V) V {
        let old = unsafe self.map.vals[self.slot];
        unsafe self.map.vals[self.slot] = value;
        return old;
    }

    /// Remove the entry, returning its value; the stored key is freed.
    pub fn remove(self: OccupiedEntry<'a, K, V, A, S>) V {
        return switch self {
            OccupiedEntry { map: map, slot: slot } => {
                let v = unsafe map.vals[slot];
                unsafe map.keys[slot].free();
                map.vacate(slot);
                v;
            },
        };
    }

    /// Remove the entry, returning its key and value.
    pub fn remove_entry(self: OccupiedEntry<'a, K, V, A, S>) (K, V) {
        switch self {
            OccupiedEntry { map: map, slot: slot } => {
                let k = unsafe map.keys[slot];
                let v = unsafe map.vals[slot];
                map.vacate(slot);
                return k, v;
            },
        };
    }
}

extend<'a, K: Hash + Eq, V, A: Allocator, S: BuildHasher> VacantEntry<'a, K, V, A, S> {
    /// The key the entry would insert.
    pub const fn key(self: &VacantEntry<'a, K, V, A, S>) &K {
        return &self.key;
    }

    /// Give the key back without inserting.
    pub fn into_key(self: VacantEntry<'a, K, V, A, S>) K {
        return switch self {
            VacantEntry { map: map, key: key, slot: slot } => key,
        };
    }

    /// Store the key with `value` in the reserved slot; the value, writable, for as long as the map
    /// borrow lasts.
    pub fn insert(self: VacantEntry<'a, K, V, A, S>, value: V) &'a mut V {
        return switch self {
            VacantEntry { map: map, key: key, slot: slot } => {
                unsafe map.keys[slot] = key;
                unsafe map.vals[slot] = value;
                unsafe map.used[slot] = 1;
                map.len = map.len + 1;
                &mut unsafe map.vals[slot];
            },
        };
    }
}

/// Borrowing cursors over a Map. `for k in m.keys()` / `for v in m.values()` visit each occupied entry
/// (in slot order; `next_back` from the far end). Each borrows the Map, which must outlive the iteration.
pub struct MapKeys<'a, K> {
    pub keys: *const K,
    pub used: *const u8,
    pub idx: usize, // the next slot from the front
    pub cap: usize, // one past the next slot from the back
    pub(file) left: usize, // entries not yet yielded
}

/// Iterator over a map's values in slot order; borrows the map.
pub struct MapValues<'a, V> {
    pub vals: *const V,
    pub used: *const u8,
    pub idx: usize,
    pub cap: usize,
    pub(file) left: usize,
}

/// Iterator over a map's values, writable, in slot order; borrows the map mutably.
pub struct MapValuesMut<'a, V> {
    pub(file) vals: *mut V,
    pub(file) used: *const u8,
    pub(file) idx: usize,
    pub(file) cap: usize,
    pub(file) left: usize,
}

/// Iterator over a map's `(key, value)` pairs in slot order; borrows the map.
pub struct MapIter<'a, K, V> {
    pub(file) keys: *const K,
    pub(file) vals: *const V,
    pub(file) used: *const u8,
    pub(file) idx: usize,
    pub(file) cap: usize,
    pub(file) left: usize,
}

/// Iterator over a map's `(key, writable value)` pairs in slot order; borrows the map mutably.
pub struct MapIterMut<'a, K, V> {
    pub(file) keys: *const K,
    pub(file) vals: *mut V,
    pub(file) used: *const u8,
    pub(file) idx: usize,
    pub(file) cap: usize,
    pub(file) left: usize,
}

/// The entries of a map moved out one by one (`Map::drain`); dropping it frees the rest and leaves the
/// map empty.
pub struct MapDrain<'a, K, V, A, S> {
    pub(file) map: &'a mut Map<K, V, A, S>,
    pub(file) idx: usize,
}

extend<K: Hash + Eq, V, A: Allocator, S: BuildHasher> Map<K, V, A, S> {
    /// A cursor over the keys (`&K`).
    pub const fn keys(self: &Map<K, V, A, S>) MapKeys<K> {
        return MapKeys::<K> { keys: self.keys, used: self.used, idx: 0, cap: self.cap, left: self.len };
    }

    /// A cursor over the values (`&V`).
    pub const fn values(self: &Map<K, V, A, S>) MapValues<V> {
        return MapValues::<V> { vals: self.vals, used: self.used, idx: 0, cap: self.cap, left: self.len };
    }

    /// A cursor over the values, writable (`&mut V`).
    pub const fn values_mut(self: &mut Map<K, V, A, S>) MapValuesMut<V> {
        return MapValuesMut::<V> { vals: self.vals, used: self.used, idx: 0, cap: self.cap, left: self.len };
    }

    /// A cursor over the `(&K, &V)` pairs.
    pub const fn iter(self: &Map<K, V, A, S>) MapIter<K, V> {
        return MapIter::<K, V> {
            keys: self.keys,
            vals: self.vals,
            used: self.used,
            idx: 0,
            cap: self.cap,
            left: self.len,
        };
    }

    /// A cursor over the `(&K, &mut V)` pairs.
    pub const fn iter_mut(self: &mut Map<K, V, A, S>) MapIterMut<K, V> {
        return MapIterMut::<K, V> {
            keys: self.keys,
            vals: self.vals,
            used: self.used,
            idx: 0,
            cap: self.cap,
            left: self.len,
        };
    }
}

// The cursor steps shared by the iterators: the next occupied slot from the front or the back.
const fn map_step_front(used: *const u8, idx: &mut usize, cap: usize) Option<usize> {
    while *idx < cap {
        let i = *idx;
        *idx = i + 1;
        if unsafe used[i] != 0 {
            return Option::<usize>::Some(i);
        }
    }
    return Option::<usize>::None;
}

const fn map_step_back(used: *const u8, idx: usize, cap: &mut usize) Option<usize> {
    while *cap > idx {
        *cap = *cap - 1;
        if unsafe used[*cap] != 0 {
            return Option::<usize>::Some(*cap);
        }
    }
    return Option::<usize>::None;
}

extend<'a, K> MapKeys<'a, K> as Iterator<&'a K> {
    pub const fn next(self: &mut MapKeys<'a, K>) Option<&'a K> {
        return switch map_step_front(self.used, &mut self.idx, self.cap) {
            Some(i) => {
                self.left = self.left - 1;
                Option::<&'a K>::Some(unsafe &*(self.keys + i));
            },
            None => Option::<&'a K>::None,
        };
    }

    pub const fn size_hint(self: &MapKeys<'a, K>) (usize, Option<usize>) {
        return self.left, Option::<usize>::Some(self.left);
    }
}

extend<'a, K> MapKeys<'a, K> as DoubleEndedIterator<&'a K> {
    pub const fn next_back(self: &mut MapKeys<'a, K>) Option<&'a K> {
        return switch map_step_back(self.used, self.idx, &mut self.cap) {
            Some(i) => {
                self.left = self.left - 1;
                Option::<&'a K>::Some(unsafe &*(self.keys + i));
            },
            None => Option::<&'a K>::None,
        };
    }
}

extend<'a, V> MapValues<'a, V> as Iterator<&'a V> {
    pub const fn next(self: &mut MapValues<'a, V>) Option<&'a V> {
        return switch map_step_front(self.used, &mut self.idx, self.cap) {
            Some(i) => {
                self.left = self.left - 1;
                Option::<&'a V>::Some(unsafe &*(self.vals + i));
            },
            None => Option::<&'a V>::None,
        };
    }

    pub const fn size_hint(self: &MapValues<'a, V>) (usize, Option<usize>) {
        return self.left, Option::<usize>::Some(self.left);
    }
}

extend<'a, V> MapValues<'a, V> as DoubleEndedIterator<&'a V> {
    pub const fn next_back(self: &mut MapValues<'a, V>) Option<&'a V> {
        return switch map_step_back(self.used, self.idx, &mut self.cap) {
            Some(i) => {
                self.left = self.left - 1;
                Option::<&'a V>::Some(unsafe &*(self.vals + i));
            },
            None => Option::<&'a V>::None,
        };
    }
}

extend<'a, V> MapValuesMut<'a, V> as Iterator<&'a mut V> {
    pub fn next(self: &mut MapValuesMut<'a, V>) Option<&'a mut V> {
        return switch map_step_front(self.used, &mut self.idx, self.cap) {
            Some(i) => {
                self.left = self.left - 1;
                Option::<&'a mut V>::Some(unsafe &mut *(self.vals + i));
            },
            None => Option::<&'a mut V>::None,
        };
    }

    pub fn size_hint(self: &MapValuesMut<'a, V>) (usize, Option<usize>) {
        return self.left, Option::<usize>::Some(self.left);
    }
}

extend<'a, V> MapValuesMut<'a, V> as DoubleEndedIterator<&'a mut V> {
    pub fn next_back(self: &mut MapValuesMut<'a, V>) Option<&'a mut V> {
        return switch map_step_back(self.used, self.idx, &mut self.cap) {
            Some(i) => {
                self.left = self.left - 1;
                Option::<&'a mut V>::Some(unsafe &mut *(self.vals + i));
            },
            None => Option::<&'a mut V>::None,
        };
    }
}

extend<'a, K, V> MapIter<'a, K, V> as Iterator<(&'a K, &'a V)> {
    pub const fn next(self: &mut MapIter<'a, K, V>) Option<(&'a K, &'a V)> {
        return switch map_step_front(self.used, &mut self.idx, self.cap) {
            Some(i) => {
                self.left = self.left - 1;
                Option::<(&'a K, &'a V)>::Some((unsafe &*(self.keys + i), unsafe &*(self.vals + i)));
            },
            None => Option::<(&'a K, &'a V)>::None,
        };
    }

    pub const fn size_hint(self: &MapIter<'a, K, V>) (usize, Option<usize>) {
        return self.left, Option::<usize>::Some(self.left);
    }
}

extend<'a, K, V> MapIter<'a, K, V> as DoubleEndedIterator<(&'a K, &'a V)> {
    pub const fn next_back(self: &mut MapIter<'a, K, V>) Option<(&'a K, &'a V)> {
        return switch map_step_back(self.used, self.idx, &mut self.cap) {
            Some(i) => {
                self.left = self.left - 1;
                Option::<(&'a K, &'a V)>::Some((unsafe &*(self.keys + i), unsafe &*(self.vals + i)));
            },
            None => Option::<(&'a K, &'a V)>::None,
        };
    }
}

extend<'a, K, V> MapIterMut<'a, K, V> as Iterator<(&'a K, &'a mut V)> {
    pub fn next(self: &mut MapIterMut<'a, K, V>) Option<(&'a K, &'a mut V)> {
        return switch map_step_front(self.used, &mut self.idx, self.cap) {
            Some(i) => {
                self.left = self.left - 1;
                Option::<(&'a K, &'a mut V)>::Some((unsafe &*(self.keys + i), unsafe &mut *(self.vals + i)));
            },
            None => Option::<(&'a K, &'a mut V)>::None,
        };
    }

    pub fn size_hint(self: &MapIterMut<'a, K, V>) (usize, Option<usize>) {
        return self.left, Option::<usize>::Some(self.left);
    }
}

extend<'a, K, V> MapIterMut<'a, K, V> as DoubleEndedIterator<(&'a K, &'a mut V)> {
    pub fn next_back(self: &mut MapIterMut<'a, K, V>) Option<(&'a K, &'a mut V)> {
        return switch map_step_back(self.used, self.idx, &mut self.cap) {
            Some(i) => {
                self.left = self.left - 1;
                Option::<(&'a K, &'a mut V)>::Some((unsafe &*(self.keys + i), unsafe &mut *(self.vals + i)));
            },
            None => Option::<(&'a K, &'a mut V)>::None,
        };
    }
}

extend<K: Hash + Eq, V, A: Allocator, S: BuildHasher> MapDrain<K, V, A, S> as Iterator<(K, V)> {
    pub fn next(self: &mut MapDrain<K, V, A, S>) Option<(K, V)> {
        return switch map_step_front(self.map.used, &mut self.idx, self.map.cap) {
            Some(i) => {
                unsafe self.map.used[i] = 0;
                self.map.len = self.map.len - 1;
                Option::<(K, V)>::Some((unsafe self.map.keys[i], unsafe self.map.vals[i]));
            },
            None => Option::<(K, V)>::None,
        };
    }

    pub fn size_hint(self: &MapDrain<K, V, A, S>) (usize, Option<usize>) {
        return self.map.len, Option::<usize>::Some(self.map.len);
    }
}

extend<K: Hash + Eq, V, A: Allocator, S: BuildHasher> MapDrain<K, V, A, S> as Free {
    pub fn free(self: &mut MapDrain<K, V, A, S>) {
        self.map.clear();
    }
}
