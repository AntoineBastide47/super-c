// Spellings interned once: a name is a dense id, in first-intern order, into one byte arena, found by
// open addressing over FNV-1a hashes. A lookup costs one hash and, at the table's load of at most one
// half, about two probes; the arena grows geometrically and never moves a spelling's offset.

/// An interning table of byte strings.
pub struct Names {
    strs: String,
    offsets: Vector<u32>, // id `i` spells `strs[offsets[i] .. offsets[i + 1]]`
    table: Vector<u32>, // id + 1 per slot, 0 = empty; a power of two at least twice the count
}

/// The FNV-1a hash of the `n` bytes at `p`.
pub const fn hash_bytes(p: *const u8, n: usize) u64 {
    let mut h: u64 = 0xcbf29ce484222325u64;
    let mut i: usize = 0;
    while i < n {
        let b = unsafe p[i];
        h = (h ^ b as u64).wrapping_mul(0x100000001b3u64);
        i += 1;
    }
    return h;
}

extend Names {
    /// An empty table with room for `bytes` bytes of spellings and `ids` names before it grows.
    pub fn with_capacity(bytes: usize, ids: usize) Names {
        let mut slots: usize = 16;
        while slots < ids {
            slots *= 2;
        }
        let mut tab = Vector::<u32>::new();
        tab.resize_default(slots);
        let mut n = Names {
            strs: String::with_capacity(bytes),
            offsets: Vector::<u32>::with_capacity(ids * 2 + 1),
            table: tab,
        };
        n.offsets.push(0);
        return n;
    }

    /// The number of interned names.
    pub const fn count(self: &Names) usize {
        return self.offsets.len() - 1;
    }

    /// The spelling of name `id` (below `count`).
    pub const fn spell(self: &Names, id: u32) str {
        let a = self.offsets[id as usize] as usize;
        let b = self.offsets[id as usize + 1] as usize;
        return self.strs.as_str().slice(a, b);
    }

    /// The id of `s`, or -1 when it was never interned.
    pub const fn find(self: &Names, s: str) i64 {
        let mask = self.table.len() - 1;
        let mut i = hash_bytes(s.ptr(), s.len()) as usize & mask;
        // The table is at most half full, so a probe sequence meets an empty slot.
        loop {
            let e = self.table[i];
            if e == 0 {
                return -1;
            }
            if self.spell(e - 1) == s {
                return e - 1;
            }
            i = i + 1 & mask;
        }
    }

    /// The id of `s`, interned first when new.
    pub fn intern(self: &mut Names, s: str) u32 {
        let h = hash_bytes(s.ptr(), s.len());
        let mask = self.table.len() - 1;
        let mut i = h as usize & mask;
        let mut probes: usize = 0;
        while probes <= mask {
            let e = self.table[i];
            if e == 0 {
                break;
            }
            if self.spell(e - 1) == s {
                return e - 1;
            }
            i = i + 1 & mask;
            probes += 1;
        }
        assert(probes <= mask);
        let id = self.count() as u32;
        self.strs.push_str(s);
        self.offsets.push(self.strs.len() as u32);
        self.table[i] = id + 1;
        if (id as usize + 2) * 2 > self.table.len() {
            self.grow();
        }
        return id;
    }

    fn grow(self: &mut Names) {
        let size = self.table.len() * 2;
        let mut tab = Vector::<u32>::new();
        tab.resize_default(size);
        let mask = size - 1;
        for id in 0..self.count() {
            let s = self.spell(id as u32);
            let mut i = hash_bytes(s.ptr(), s.len()) as usize & mask;
            while tab[i] != 0 {
                i = i + 1 & mask;
            }
            tab[i] = id as u32 + 1;
        }
        self.table = tab;
    }
}
