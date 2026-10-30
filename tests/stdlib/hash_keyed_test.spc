// std::hash::keyed: SipHash against the reference vectors, streaming equivalence, the process key, and
// the plan's flooding gate: keys built to collide under the prelude's unkeyed mix do not degrade a map
// that uses the keyed builder.

import std::hash::keyed as keyed;
import std::math::random as random;

// SipHash-2-4 of the messages 00, 00 01, .. (lengths 0 to 63) under the key 00 01 .. 0f: the
// reference implementation's vectors.h (github.com/veorq/SipHash, CC0). Values 0 and 15 are the ones
// the paper prints.
const SIP24_VECTORS: [u64; 64] = [
    0x726fdb47dd0e0e31u64,
    0x74f839c593dc67fdu64,
    0x0d6c8009d9a94f5au64,
    0x85676696d7fb7e2du64,
    0xcf2794e0277187b7u64,
    0x18765564cd99a68du64,
    0xcbc9466e58fee3ceu64,
    0xab0200f58b01d137u64,
    0x93f5f5799a932462u64,
    0x9e0082df0ba9e4b0u64,
    0x7a5dbbc594ddb9f3u64,
    0xf4b32f46226bada7u64,
    0x751e8fbc860ee5fbu64,
    0x14ea5627c0843d90u64,
    0xf723ca908e7af2eeu64,
    0xa129ca6149be45e5u64,
    0x3f2acc7f57c29bdbu64,
    0x699ae9f52cbe4794u64,
    0x4bc1b3f0968dd39cu64,
    0xbb6dc91da77961bdu64,
    0xbed65cf21aa2ee98u64,
    0xd0f2cbb02e3b67c7u64,
    0x93536795e3a33e88u64,
    0xa80c038ccd5ccec8u64,
    0xb8ad50c6f649af94u64,
    0xbce192de8a85b8eau64,
    0x17d835b85bbb15f3u64,
    0x2f2e6163076bcfadu64,
    0xde4daaaca71dc9a5u64,
    0xa6a2506687956571u64,
    0xad87a3535c49ef28u64,
    0x32d892fad841c342u64,
    0x7127512f72f27cceu64,
    0xa7f32346f95978e3u64,
    0x12e0b01abb051238u64,
    0x15e034d40fa197aeu64,
    0x314dffbe0815a3b4u64,
    0x027990f029623981u64,
    0xcadcd4e59ef40c4du64,
    0x9abfd8766a33735cu64,
    0x0e3ea96b5304a7d0u64,
    0xad0c42d6fc585992u64,
    0x187306c89bc215a9u64,
    0xd4a60abcf3792b95u64,
    0xf935451de4f21df2u64,
    0xa9538f0419755787u64,
    0xdb9acddff56ca510u64,
    0xd06c98cd5c0975ebu64,
    0xe612a3cb9ecba951u64,
    0xc766e62cfcadaf96u64,
    0xee64435a9752fe72u64,
    0xa192d576b245165au64,
    0x0a8787bf8ecb74b2u64,
    0x81b3e73d20b49b6fu64,
    0x7fa8220ba3b2eceau64,
    0x245731c13ca42499u64,
    0xb78dbfaf3a8d83bdu64,
    0xea1ad565322a1a0bu64,
    0x60e61c23a3795013u64,
    0x6606d7e446282b93u64,
    0x6ca4ecb15c5f91e1u64,
    0x9f626da15c9625f3u64,
    0xe51b38608ef25f57u64,
    0x958a324ceb064572u64,
];

// SipHash-1-3 of the same messages under the same key, from an independent model of the paper's
// algorithm (it reproduces every SipHash-2-4 vector above).
const SIP13_VECTORS: [u64; 64] = [
    0xabac0158050fc4dcu64,
    0xc9f49bf37d57ca93u64,
    0x82cb9b024dc7d44du64,
    0x8bf80ab8e7ddf7fbu64,
    0xcf75576088d38328u64,
    0xdef9d52f49533b67u64,
    0xc50d2b50c59f22a7u64,
    0xd3927d989bb11140u64,
    0x369095118d299a8eu64,
    0x25a48eb36c063de4u64,
    0x79de85ee92ff097fu64,
    0x70c118c1f94dc352u64,
    0x78a384b157b4d9a2u64,
    0x306f760c1229ffa7u64,
    0x605aa111c0f95d34u64,
    0xd320d86d2a519956u64,
    0xcc4fdd1a7d908b66u64,
    0x9cf2689063dbd80cu64,
    0x8ffc389cb473e63eu64,
    0xf21f9de58d297d1cu64,
    0xc0dc2f46a6cce040u64,
    0xb992abfe2b45f844u64,
    0x7ffe7b9ba320872eu64,
    0x525a0e7fdae6c123u64,
    0xf464aeb267349c8cu64,
    0x45cd5928705b0979u64,
    0x3a3e35e3ca9913a5u64,
    0xa91dc74e4ade3b35u64,
    0xfb0bed02ef6cd00du64,
    0x88d93cb44ab1e1f4u64,
    0x540f11d643c5e663u64,
    0x2370dd1f8c21d1bcu64,
    0x81157b6c16a7b60du64,
    0x4d54b9e57a8ff9bfu64,
    0x759f12781f2a753eu64,
    0xcea1a3bebf186b91u64,
    0x2cf508d3ada26206u64,
    0xb6101c2da3c33057u64,
    0xb3f47496ae3a36a1u64,
    0x626b57547b108392u64,
    0xc1d2363299e41531u64,
    0x667cc1923f1ad944u64,
    0x65704ffec8138825u64,
    0x24f280d1c28949a6u64,
    0xc2ca1cedfaf8876bu64,
    0xc2164bfc9f042196u64,
    0xa16e9c9368b1d623u64,
    0x49fb169c8b5114fdu64,
    0x9f3143f8df074c46u64,
    0xc6fdaf2412cc86b3u64,
    0x7eaf49d10a52098fu64,
    0x1cf313559d292f9au64,
    0xc44a30dda2f41f12u64,
    0x36fae98943a71ed0u64,
    0x318fb34c73f0bce6u64,
    0xa27abf3670a7e980u64,
    0xb4bcc0db243c6d75u64,
    0x23f8d852fdb71513u64,
    0x8f035f4da67d8a08u64,
    0xd89cd0e5b7e8f148u64,
    0xf6f4e6bcf7a644eeu64,
    0xaec59ad80f1837f2u64,
    0xc3b2f6154b6694e0u64,
    0x9d199062b7bbb3a8u64,
];

const K0: u64 = 0x0706050403020100;
const K1: u64 = 0x0f0e0d0c0b0a0908;

@test
fn siphash24_matches_the_reference_vectors() {
    let mut msg: [u8; 64] = [0; 64];
    for i in 0..64usize {
        unsafe msg[i] = i as u8;
    }
    for n in 0..64usize {
        let mut h = keyed::SipHasher24::new(K0, K1);
        h.write(unsafe Slice::<u8> { ptr: &msg[0], len: n });
        assert_eq(h.finish(), unsafe SIP24_VECTORS[n]);
    }
}

@test
fn siphash13_matches_the_model() {
    let mut msg: [u8; 64] = [0; 64];
    for i in 0..64usize {
        unsafe msg[i] = i as u8;
    }
    for n in 0..64usize {
        let mut h = keyed::SipHasher13::new(K0, K1);
        h.write(unsafe Slice::<u8> { ptr: &msg[0], len: n });
        assert_eq(h.finish(), unsafe SIP13_VECTORS[n]);
    }
}

@test
fn any_split_of_a_stream_gives_one_digest() {
    let mut rng = random::Pcg32::new(13, 5);
    let mut msg = Vector::<u8>::new();
    for _ in 0..200 {
        msg.push(rng.next_u32() as u8);
    }
    let mut whole = keyed::SipHasher13::new(1, 2);
    whole.write(&msg);
    let want = whole.finish();
    for _ in 0..50 {
        let mut h = keyed::SipHasher13::new(1, 2);
        let mut i: usize = 0;
        while i < msg.len() {
            let step = (rng.next_u32() % 11) as usize;
            let end = (i + step).min(msg.len());
            h.write(msg.index_range(i..end));
            i = end;
        }
        assert_eq(h.finish(), want);
    }
    // write_u64 is write of the little-endian bytes, at any alignment of the pending tail.
    for lead in 0..9usize {
        let mut a = keyed::SipHasher13::new(3, 4);
        let mut b = keyed::SipHasher13::new(3, 4);
        a.write(msg.index_range(0..lead));
        b.write(msg.index_range(0..lead));
        a.write_u64(0x1122334455667788);
        let bytes: [u8; 8] = [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11];
        b.write(bytes);
        assert_eq(a.finish(), b.finish());
    }
}

@test
fn builders_hash_keys_through_their_stream() {
    let b = keyed::KeyedHash::with_key(K0, K1);
    let s = String::from_str("abc");
    let mut h = keyed::SipHasher13::new(K0, K1);
    s.hash_into(&mut h);
    assert_eq(b.hash_one(&s), h.finish());
    assert_eq(b.hash_one(&s), b.hash_one(&"abc"));
    let other = keyed::KeyedHash::with_key(K0 + 1, K1);
    assert_ne(b.hash_one(&s), other.hash_one(&s));
    let (k0, k1) = b.key();
    assert_eq(k0, K0);
    assert_eq(k1, K1);
}

@test
fn the_process_key_is_drawn_once() {
    let a = keyed::KeyedHash::random();
    let b = keyed::KeyedHash::random();
    let (a0, a1) = a.key();
    let (b0, b1) = b.key();
    assert_eq(a0, b0);
    assert_eq(a1, b1);
    let mut m = Map::<String, i64, Global, keyed::KeyedHash>::with_hasher(a);
    for i in 0..100 {
        let mut k = String::from_str("key");
        k.push_i64(i);
        m.insert(k, i);
    }
    let probe = String::from_str("key42");
    assert_eq(*m.get(&probe).unwrap(), 42);
}

// The key comparisons a map makes: every probe that meets an occupied slot compares keys once.
static mut CMPS: u64 = 0;

// A u64 key that counts its comparisons and feeds its value to the hasher, as the builtin integers do.
struct Counted {
    pub v: u64,
}

extend Counted as Eq {
    pub fn eq(self: &Counted, other: &Counted) bool {
        unsafe CMPS += 1;
        return self.v == other.v;
    }
}

extend Counted as Hash {
    pub fn hash_into<H: Hasher>(self: &Counted, h: &mut H) {
        h.write_u64(self.v);
    }
}

// x ^ x >> 32 is its own inverse.
const fn unfold(x: u64) u64 {
    return x ^ x >> 32;
}

// Keys whose default hash has its low 20 bits zero: in every table of up to 2^20 slots they all start
// probing at slot 0, so the n-th insert compares with every key before it.
fn colliding_keys(n: u64) Vector<u64> {
    let c: u64 = 0x9E3779B97F4A7C15;
    let mut inv = c;
    for _ in 0..6 {
        inv = inv.wrapping_mul(2u64.wrapping_sub(c.wrapping_mul(inv)));
    }
    assert_eq(c.wrapping_mul(inv), 1u64);
    let mut out = Vector::<u64>::new();
    for j in 1..n + 1 {
        out.push(unfold(unfold(j << 20).wrapping_mul(inv)));
    }
    return out;
}

@test
fn colliding_keys_do_not_degrade_a_keyed_map() {
    let n: u64 = 2000;
    let keys = colliding_keys(n);
    let d = DefaultHash {};
    for k in keys.iter() {
        assert_eq(d.hash_one(k) & 0xFFFFF, 0u64);
    }
    unsafe CMPS = 0;
    {
        let mut m = Map::<Counted, u64>::new();
        for k in keys.iter() {
            m.insert(Counted { v: *k }, *k);
        }
    }
    let unkeyed = unsafe CMPS;
    // The corpus works: the unkeyed map compares on the order of n * n / 2 times.
    assert(unkeyed > n * n / 4);
    unsafe CMPS = 0;
    {
        let mut m = Map::<Counted, u64, Global, keyed::KeyedHash>::with_hasher(
            keyed::KeyedHash::with_key(0x1234, 0x5678),
        );
        for k in keys.iter() {
            m.insert(Counted { v: *k }, *k);
        }
        for k in keys.iter() {
            let probe = Counted { v: *k };
            assert_eq(*m.get(&probe).unwrap(), *k);
        }
    }
    let with_key = unsafe CMPS;
    // Inserts and lookups at a load factor of at most 3/4: a few comparisons each.
    assert(with_key < 8 * n);
}
