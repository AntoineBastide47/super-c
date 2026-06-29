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
    keys: *mut K,  // parallel arrays, slot i valid when used[i] == 1 (private)
    vals: *mut V,
    used: *mut u8, // 0 = empty, 1 = occupied
    len: usize,    // occupied slots
    cap: usize,    // total slots (a power of two is not required; probing wraps with %)
    alloc: A,      // the allocator the arrays were obtained through (private; zero-sized for Global)
}

extend<K: Hash + Eq, V, A: Allocator> Map<K, V, A> {

    // Empty map backed by an explicit allocator value (a stateful arena/pool handle, or a zero-sized tag).
    pub fn new_in(alloc: A) Map<K, V, A> {
        return Map::<K, V, A> { keys: null, vals: null, used: null, len: 0, cap: 0, alloc: alloc, };
    }

    pub fn len(self: &Map<K, V, A>) usize {
        return self.len;
    }

    pub fn is_empty(self: &Map<K, V, A>) bool {
        return self.len == 0;
    }

    // The slot a key occupies, or the first empty slot on its probe sequence. Requires cap > 0.
    fn slot(self: &Map<K, V, A>, key: &K) usize {
        let mut i = (key.hash() as usize) % self.cap;
        while self.used[i] != 0 {
            if self.keys[i].eq(key) {
                return i;
            }
            i = i + 1;
            if i >= self.cap {
                i = 0;
            }
        }
        return i;
    }

    // Reallocate to a larger table and rehash every occupied entry into it.
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
        memset(self.used as *mut void, 0, newcap); // mark every slot empty
        self.cap = newcap;
        self.len = 0;
        let mut i: usize = 0;
        while i < oldcap {
            if oldused[i] == 1 {
                let j = self.slot(&oldkeys[i]);
                self.keys[j] = oldkeys[i];
                self.vals[j] = oldvals[i];
                self.used[j] = 1;
                self.len = self.len + 1;
            }
            i = i + 1;
        }
        if oldcap > 0 {
            self.alloc.dealloc(oldkeys as *mut void, oldcap * sizeof(K), alignof(K));
            self.alloc.dealloc(oldvals as *mut void, oldcap * sizeof(V), alignof(V));
            self.alloc.dealloc(oldused as *mut void, oldcap, alignof(u8));
        }
    }

    // Insert or overwrite `key` -> `value`. On overwrite the existing key is kept; the duplicate key and the
    // replaced value are freed (no-ops for non-Free types). Takes ownership of `key` and `value`.
    pub fn insert(self: &mut Map<K, V, A>, key: K, value: V) {
        if self.cap == 0 || (self.len + 1) * 4 >= self.cap * 3 { // grow past a 0.75 load factor
            self.grow();
        }
        let i = self.slot(&key);
        if self.used[i] != 0 { // overwrite: keep the stored key, free the duplicate + the old value
            let mut dup = key;
            dup.free();
            self.vals[i].free();
            self.vals[i] = value;
            return;
        }
        self.keys[i] = key;
        self.vals[i] = value;
        self.used[i] = 1;
        self.len = self.len + 1;
    }

    // A borrow of the value for `key`, or `None`. Borrowing (`&V`) keeps the Map the sole owner.
    pub fn get(self: &Map<K, V, A>, key: &K) Option<&V> {
        if self.cap == 0 {
            return Option::<&V>::None;
        }
        let i = self.slot(key);
        if self.used[i] == 0 {
            return Option::<&V>::None;
        }
        return Option::<&V>::Some(&self.vals[i]);
    }

    pub fn contains_key(self: &Map<K, V, A>, key: &K) bool {
        return self.get(key).is_some();
    }

    // Remove `key`, returning its value (`None` if absent). Re-inserts the rest of the probe cluster so no
    // lookup is cut short (backward-shift deletion -- no tombstones).
    pub fn remove(self: &mut Map<K, V, A>, key: &K) Option<V> {
        if self.cap == 0 {
            return Option::<V>::None;
        }
        let i = self.slot(key);
        if self.used[i] == 0 {
            return Option::<V>::None;
        }
        let removed = self.vals[i];
        self.keys[i].free(); // the key for this entry is no longer referenced -- free it (no-op if not Free)
        self.used[i] = 0;
        self.len = self.len - 1;
        let mut j = i + 1;
        if j >= self.cap {
            j = 0;
        }
        while self.used[j] == 1 {
            let k = self.keys[j];
            let v = self.vals[j];
            self.used[j] = 0;
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
    pub fn new() Map<K, V, A> { return Map::<K, V, A>::new_in(A::default()); }
}

// Free the three arrays AND deep-free every stored key/value. Auto-`Free`: the Map is released at scope
// exit. Sound because `get` borrows the value (`&V`) and `remove` moves it out, so each live key/value is
// owned only by its slot. Each occupied key/value `.free()` is a no-op when K / V isn't a Free type.
extend<K: Hash + Eq, V, A: Allocator> Map<K, V, A> as Free {
    pub fn free(self: &mut Map<K, V, A>) {
        let mut i: usize = 0;
        while i < self.cap {
            if self.used[i] != 0 {
                self.keys[i].free(); // no-op if K isn't Free
                self.vals[i].free(); // no-op if V isn't Free
            }
            i = i + 1;
        }
        self.alloc.dealloc(self.keys as *mut void, self.cap * sizeof(K), alignof(K));
        self.alloc.dealloc(self.vals as *mut void, self.cap * sizeof(V), alignof(V));
        self.alloc.dealloc(self.used as *mut void, self.cap, alignof(u8));
        self.keys = null;
        self.vals = null;
        self.used = null;
        self.len = 0;
        self.cap = 0;
    }
}

extend<K: Hash + Eq + Default, V: Default, A: Allocator + Default> Map<K, V, A> as Default {
    pub fn default() Map<K, V, A> {
        return Map::<K, V, A>::new();
    }
}

// Borrowing cursors over a Map. `for k in m.keys()` / `for v in m.values()` visit each occupied entry
// (in arbitrary slot order). Each borrows the Map, which must outlive the iteration.
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
    // A cursor over the keys (`&K`).
    pub fn keys(self: &Map<K, V, A>) MapKeys<K> {
        return MapKeys::<K> { keys: self.keys as *const K, used: self.used as *const u8, idx: 0, cap: self.cap };
    }

    // A cursor over the values (`&V`).
    pub fn values(self: &Map<K, V, A>) MapValues<V> {
        return MapValues::<V> { vals: self.vals as *const V, used: self.used as *const u8, idx: 0, cap: self.cap };
    }
}

extend<K> MapKeys<K> as Iterator<&K> {
    pub fn next(self: &mut MapKeys<K>) Option<&K> {
        while self.idx < self.cap {
            let i = self.idx;
            self.idx = self.idx + 1;
            if self.used[i] != 0 {
                return Option::<&K>::Some(&self.keys[i]);
            }
        }
        return Option::<&K>::None;
    }
}

extend<V> MapValues<V> as Iterator<&V> {
    pub fn next(self: &mut MapValues<V>) Option<&V> {
        while self.idx < self.cap {
            let i = self.idx;
            self.idx = self.idx + 1;
            if self.used[i] != 0 {
                return Option::<&V>::Some(&self.vals[i]);
            }
        }
        return Option::<&V>::None;
    }
}
