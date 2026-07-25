// Map<K, V, A = Global>: an open-addressing hash map (linear probing), monomorphized per (K, V, allocator).
// The key type must be `Hash + Eq`; `get` borrows the value (`Option<&V>`), `remove` moves it out
// (`Option<V>`). The three parallel arrays are obtained through allocator `A` (stored in the map; zero bytes
// when it is the zero-sized `Global`). Auto-`Free` (deep-frees keys and values at scope exit). Auto-imported
// (prelude). `new()` uses a default-constructed allocator; pass a stateful arena/pool with `new_in`, or pick
// a non-default zero-sized allocator with a turbofish: `Map::<K, V, MyAlloc>::new()`.

extern "C" {
    fn memset(dst: *mut void, value: i32, n: usize) *mut void;
}

pub struct Map<K, V, A = Global> {
    keys: *mut K, // parallel arrays, slot i valid when used[i] == 1 (private)
    vals: *mut V,
    used: *mut u8, // 0 = empty, 1 = occupied
    len: usize, // occupied slots
    cap: usize, // total slots; ALWAYS a power of two (grow doubles from 8) so slot() can mask
    alloc: A, // the allocator the arrays were obtained through (private; zero-sized for Global)
}

// A Map owns its keys and values, so it is Send / Sync when they and its allocator are.
extend<K: Send, V: Send, A: Send> Map<K, V, A> as Send {}

extend<K: Sync, V: Sync, A: Sync> Map<K, V, A> as Sync {}

extend<K: Hash + Eq, V, A: Allocator> Map<K, V, A> {
    /// Empty map backed by an explicit allocator value (a stateful arena/pool handle, or a zero-sized tag).
    pub const fn new_in(alloc: A) Map<K, V, A> {
        return Map::<K, V, A> { keys: null, vals: null, used: null, len: 0, cap: 0, alloc: alloc };
    }

    pub const fn len(self: &Map<K, V, A>) usize {
        return self.len;
    }

    pub const fn is_empty(self: &Map<K, V, A>) bool {
        return self.len == 0;
    }

    // The slot a key occupies, or the first empty slot on its probe sequence. Requires cap > 0.
    // cap is always a power of two (grow doubles from 8), so the bucket modulo is a bit-mask --
    // same slot for every hash as `% cap`, without the 64-bit division.
    fn slot(self: &Map<K, V, A>, key: &K) usize {
        let mut i = key.hash() as usize & self.cap - 1;
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

    // Reallocate to a larger table and rehash every occupied entry into it. (Three separate arrays
    // by REQUIREMENT, not oversight: the compile-time evaluator's abstract heap types each
    // allocation by its element -- a single block carved with byte-offset interior pointers is not
    // evaluable, and Map folds at compile time are a language feature.)
    fn grow(self: &mut Map<K, V, A>) {
        let mut newcap = self.cap * 2;
        if newcap < 8 {
            newcap = 8;
        }
        let oldkeys = self.keys;
        let oldvals = self.vals;
        let oldused = self.used;
        let oldcap = self.cap;
        self.keys = self.alloc.alloc(newcap * sizeof(K), alignof(K)) as *mut K;
        self.vals = self.alloc.alloc(newcap * sizeof(V), alignof(V)) as *mut V;
        self.used = self.alloc.alloc(newcap, alignof(u8)) as *mut u8;
        unsafe memset(self.used, 0, newcap); // mark every slot empty
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
            self.alloc.dealloc(oldkeys, oldcap * sizeof(K), alignof(K));
            self.alloc.dealloc(oldvals, oldcap * sizeof(V), alignof(V));
            self.alloc.dealloc(oldused, oldcap, alignof(u8));
        }
    }

    /// Drop every entry (deep-freeing keys and values) but KEEP the table storage for reuse: a
    /// cleared map re-fills without touching the allocator.
    pub fn clear(self: &mut Map<K, V, A>) {
        for i in 0..self.cap {
            if unsafe self.used[i] != 0 {
                unsafe self.keys[i].free(); // no-op if K isn't Free
                unsafe self.vals[i].free(); // no-op if V isn't Free
            }
        }
        if self.cap > 0 {
            unsafe memset(self.used, 0, self.cap);
        }
        self.len = 0;
    }

    /// Insert or overwrite `key` -> `value`. On overwrite the existing key is kept; the duplicate key and the
    /// replaced value are freed (no-ops for non-Free types). Takes ownership of `key` and `value`.
    pub const fn insert(self: &mut Map<K, V, A>, key: K, value: V) {
        if self.cap == 0 || (self.len + 1) * 4 >= self.cap * 3 {
            // grow past a 0.75 load factor
            self.grow();
        }
        let i = self.slot(&key);
        if unsafe self.used[i] != 0 {
            // overwrite: keep the stored key, free the duplicate + the old value
            key.free();
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
    pub const fn get(self: &Map<K, V, A>, key: &K) Option<&V> {
        if self.cap == 0 {
            return Option::<&V>::None;
        }
        let i = self.slot(key);
        if unsafe self.used[i] == 0 {
            return Option::<&V>::None;
        }
        return Option::<&V>::Some(&unsafe self.vals[i]);
    }

    pub const fn contains_key(self: &Map<K, V, A>, key: &K) bool {
        return self.get(key).is_some();
    }

    /// Remove `key`, returning its value (`None` if absent). Re-inserts the rest of the probe cluster so no
    /// lookup is cut short (backward-shift deletion -- no tombstones).
    pub const fn remove(self: &mut Map<K, V, A>, key: &K) Option<V> {
        if self.cap == 0 {
            return Option::<V>::None;
        }
        let i = self.slot(key);
        if unsafe self.used[i] == 0 {
            return Option::<V>::None;
        }
        let removed = unsafe self.vals[i];
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
            self.len = self.len - 1;
            self.insert(k, v);
            j = j + 1;
            if j >= self.cap {
                j = 0;
            }
        }
        return Option::<V>::Some(removed);
    }
}

// Convenience constructor for a default-constructible allocator (`Global`, or any zero-sized tag).
extend<K: Hash + Eq, V, A: Allocator + Default> Map<K, V, A> {
    pub const fn new() Map<K, V, A> {
        return Map::<K, V, A>::new_in(A::default());
    }
}

// Free the three arrays AND deep-free every stored key/value. Auto-`Free`: the Map is released at scope
// exit. Sound because `get` borrows the value (`&V`) and `remove` moves it out, so each live key/value is
// owned only by its slot. Each occupied key/value `.free()` is a no-op when K / V isn't a Free type.
extend<K: Hash + Eq, V, A: Allocator> Map<K, V, A> as Free {
    pub fn free(self: &mut Map<K, V, A>) {
        for i in 0..self.cap {
            if unsafe self.used[i] != 0 {
                unsafe self.keys[i].free(); // no-op if K isn't Free
                unsafe self.vals[i].free(); // no-op if V isn't Free
            }
        }
        self.alloc.dealloc(self.keys, self.cap * sizeof(K), alignof(K));
        self.alloc.dealloc(self.vals, self.cap * sizeof(V), alignof(V));
        self.alloc.dealloc(self.used, self.cap, alignof(u8));
        self.keys = null;
        self.vals = null;
        self.used = null;
        self.len = 0;
        self.cap = 0;
    }
}

extend<K: Hash + Eq + Default, V: Default, A: Allocator + Default> Map<K, V, A> as Default {
    pub const fn default() Map<K, V, A> {
        return Map::<K, V, A>::new();
    }
}

/// Borrowing cursors over a Map. `for k in m.keys()` / `for v in m.values()` visit each occupied entry
/// (in arbitrary slot order). Each borrows the Map, which must outlive the iteration.
pub struct MapKeys<K> {
    pub keys: *const K,
    pub used: *const u8,
    pub idx: usize,
    pub cap: usize,
}

pub struct MapValues<V> {
    pub vals: *const V,
    pub used: *const u8,
    pub idx: usize,
    pub cap: usize,
}

extend<K: Hash + Eq, V, A: Allocator> Map<K, V, A> {
    /// A cursor over the keys (`&K`).
    pub const fn keys(self: &Map<K, V, A>) MapKeys<K> {
        return MapKeys::<K> { keys: self.keys, used: self.used, idx: 0, cap: self.cap };
    }

    /// A cursor over the values (`&V`).
    pub const fn values(self: &Map<K, V, A>) MapValues<V> {
        return MapValues::<V> { vals: self.vals, used: self.used, idx: 0, cap: self.cap };
    }
}

extend<K> MapKeys<K> as Iterator<&K> {
    pub const fn next(self: &mut MapKeys<K>) Option<&K> {
        while self.idx < self.cap {
            let i = self.idx;
            self.idx = self.idx + 1;
            if unsafe self.used[i] != 0 {
                return Option::<&K>::Some(&unsafe self.keys[i]);
            }
        }
        return Option::<&K>::None;
    }
}

extend<V> MapValues<V> as Iterator<&V> {
    pub const fn next(self: &mut MapValues<V>) Option<&V> {
        while self.idx < self.cap {
            let i = self.idx;
            self.idx = self.idx + 1;
            if unsafe self.used[i] != 0 {
                return Option::<&V>::Some(&unsafe self.vals[i]);
            }
        }
        return Option::<&V>::None;
    }
}
