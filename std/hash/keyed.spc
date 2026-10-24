// Keyed hashing for hash tables whose keys come from untrusted input. Import with
// `import std::hash::keyed;` and build a map with `Map::<K, V, Global, keyed::KeyedHash>::with_hasher(
// keyed::KeyedHash::random())`.
//
// The prelude's `DefaultHash` is deterministic and unkeyed: anyone who knows it can choose keys that
// share a slot, and every operation on such a map probes linearly in its size. `KeyedHash` hashes with
// SipHash-1-3 under a 128-bit secret key, so colliding keys cannot be chosen without the key; the map's
// operations stay O(1) on average. The key comes from an explicit argument (`with_key`) or from the
// operating system's entropy (`random`). The output is NOT stable across processes or releases: never
// store it or send it.
//
// SipHash is Aumasson and Bernstein's pseudorandom function ("SipHash: a fast short-input PRF",
// INDOCRYPT 2012); `SipHasher<C, D>` runs C compression rounds per 8-byte block and D finalization
// rounds. SipHash-2-4 is the paper's conservative choice; SipHash-1-3 (what `KeyedHash` uses, as Rust's
// HashMap does) halves the per-block cost and keeps the flooding resistance a hash table needs.
//
// Cost: one compression per 8 bytes of key plus D rounds at `finish`; no allocation. Thread safety: the
// hashers and the builder are plain values. `random` reads the process key with an acquire load, and
// publishes it once with a compare-and-swap; it never blocks.

import atomic;
import std::platform::entropy as entropy;

/// SipHash with C compression rounds and D finalization rounds over a 128-bit key, as a `Hasher`:
/// `write` of any split of a byte stream gives the same digest as one `write` of the whole stream.
pub struct SipHasher<const C: u32, const D: u32> {
    v0: u64,
    v1: u64,
    v2: u64,
    v3: u64,
    tail: u64, // the pending bytes of a partial block, little-endian
    ntail: u32, // how many: 0 to 7
    len: u64, // bytes written, modulo 2^64 (the finalization uses the low byte)
}

/// The variant `KeyedHash` uses.
pub type SipHasher13 = SipHasher<1, 3>;

/// The paper's conservative variant.
pub type SipHasher24 = SipHasher<2, 4>;

extend<const C: u32, const D: u32> SipHasher<C, D> {
    /// A hasher under the key `(k0, k1)`, the key's two little-endian halves.
    pub const fn new(k0: u64, k1: u64) SipHasher<C, D> {
        return SipHasher::<C, D> {
            v0: k0 ^ 0x736f6d6570736575,
            v1: k1 ^ 0x646f72616e646f6d,
            v2: k0 ^ 0x6c7967656e657261,
            v3: k1 ^ 0x7465646279746573,
            tail: 0,
            ntail: 0,
            len: 0,
        };
    }

    @always_inline
    const fn round(self: &mut SipHasher<C, D>) {
        self.v0 = self.v0.wrapping_add(self.v1);
        self.v1 = self.v1.rotate_left(13);
        self.v1 = self.v1 ^ self.v0;
        self.v0 = self.v0.rotate_left(32);
        self.v2 = self.v2.wrapping_add(self.v3);
        self.v3 = self.v3.rotate_left(16);
        self.v3 = self.v3 ^ self.v2;
        self.v0 = self.v0.wrapping_add(self.v3);
        self.v3 = self.v3.rotate_left(21);
        self.v3 = self.v3 ^ self.v0;
        self.v2 = self.v2.wrapping_add(self.v1);
        self.v1 = self.v1.rotate_left(17);
        self.v1 = self.v1 ^ self.v2;
        self.v2 = self.v2.rotate_left(32);
    }

    // Absorb one 8-byte block.
    @always_inline
    const fn compress(self: &mut SipHasher<C, D>, m: u64) {
        self.v3 = self.v3 ^ m;
        for _ in 0..C {
            self.round();
        }
        self.v0 = self.v0 ^ m;
    }
}

extend<const C: u32, const D: u32> SipHasher<C, D> as Hasher {
    pub fn write(self: &mut SipHasher<C, D>, bytes: []u8) {
        let n = bytes.len;
        self.len = self.len.wrapping_add(n as u64);
        let mut i: usize = 0;
        // Complete a pending partial block first.
        while self.ntail != 0 && i < n {
            self.tail = self.tail | (unsafe bytes.ptr[i]) as u64 << 8 * self.ntail;
            self.ntail += 1;
            i += 1;
            if self.ntail == 8 {
                let m = self.tail;
                self.compress(m);
                self.tail = 0;
                self.ntail = 0;
            }
        }
        while i + 8 <= n {
            let mut b: [u8; 8] = [0; 8];
            for k in 0..8usize {
                unsafe b[k] = unsafe bytes.ptr[i + k];
            }
            self.compress(u64::from_le_bytes(b));
            i += 8;
        }
        while i < n {
            self.tail = self.tail | (unsafe bytes.ptr[i]) as u64 << 8 * self.ntail;
            self.ntail += 1;
            i += 1;
        }
    }

    /// The bytes of `v`, little-endian: one compression when no partial block is pending.
    pub fn write_u64(self: &mut SipHasher<C, D>, v: u64) {
        if self.ntail == 0 {
            self.len = self.len.wrapping_add(8);
            self.compress(v);
            return;
        }
        let b = v.to_le_bytes();
        self.write(b);
    }

    pub fn finish(self: &SipHasher<C, D>) u64 {
        let mut s = SipHasher::<C, D> { v0: self.v0, v1: self.v1, v2: self.v2, v3: self.v3, tail: 0, ntail: 0, len: 0 };
        let b = (self.len & 0xff) << 56 | self.tail;
        s.v3 = s.v3 ^ b;
        for _ in 0..C {
            s.round();
        }
        s.v0 = s.v0 ^ b;
        s.v2 = s.v2 ^ 0xff;
        for _ in 0..D {
            s.round();
        }
        return s.v0 ^ s.v1 ^ s.v2 ^ s.v3;
    }
}

/// A keyed hash builder: SipHash-1-3 under a 128-bit key, over the stream a key's `Hash::hash_into`
/// feeds. Two builders with one key hash alike.
@derive(Copy)
pub struct KeyedHash {
    k0: u64,
    k1: u64,
}

// The process key: KEY_STATE is 0 (none), 1 (being published) or 2 (KEY0 and KEY1 hold it). Only the
// compare-and-swap winner writes the key, before its release store of 2; a reader reads it after an
// acquire load of 2.
static mut KEY_STATE: i32 = 0;
static mut KEY0: u64 = 0;
static mut KEY1: u64 = 0;

// The memory-order codes of the `atomic` intrinsics.
const ACQUIRE: i32 = 1;
const RELEASE: i32 = 2;
const ACQ_REL: i32 = 3;

extend KeyedHash {
    /// A builder under an explicit key: for reproducible tests, or a key the program manages.
    pub const fn with_key(k0: u64, k1: u64) KeyedHash {
        return KeyedHash { k0: k0, k1: k1 };
    }

    /// A builder under this process's random key: the first call draws 16 bytes from the operating
    /// system's entropy (`std::platform::entropy::fill`) and publishes them; later calls return the same
    /// key without a system call. Two first calls that race may each draw a key; one is published, and
    /// a builder that holds the other is still correct. A process whose entropy source fails panics:
    /// there is no deterministic fallback, because a predictable key removes the protection.
    pub fn random() KeyedHash {
        if unsafe atomic::load_i32(&KEY_STATE, ACQUIRE) == 2 {
            return KeyedHash { k0: unsafe KEY0, k1: unsafe KEY1 };
        }
        let mut buf: [u8; 16] = [0; 16];
        if entropy::fill(buf).is_err() {
            panic("KeyedHash::random: the operating system's entropy source failed");
        }
        let mut lo: [u8; 8] = [0; 8];
        let mut hi: [u8; 8] = [0; 8];
        for i in 0..8usize {
            unsafe lo[i] = unsafe buf[i];
            unsafe hi[i] = unsafe buf[i + 8];
        }
        let k = KeyedHash { k0: u64::from_le_bytes(lo), k1: u64::from_le_bytes(hi) };
        if unsafe atomic::cas_i32(&mut KEY_STATE, 0, 1, false, ACQ_REL, ACQUIRE) {
            unsafe {
                KEY0 = k.k0;
                KEY1 = k.k1;
                atomic::store_i32(&mut KEY_STATE, 2, RELEASE);
            }
        }
        return k;
    }

    /// The key's two halves.
    pub const fn key(self: &KeyedHash) (u64, u64) {
        return self.k0, self.k1;
    }
}

extend KeyedHash as BuildHasher {
    @always_inline
    pub fn hash_one<K: Hash>(self: &KeyedHash, key: &K) u64 {
        let mut h = SipHasher13::new(self.k0, self.k1);
        key.hash_into(&mut h);
        return h.finish();
    }
}
