// The object cache's byte codec (`build_system::lz`): every input round-trips, and malformed input is
// rejected rather than read out of bounds.
import string as cstring;
import build_system::lz as lz;

// `n` pseudo-random bytes (xorshift, fixed seed): nothing to match.
fn noise(n: usize) Vector<u8> {
    let mut v = Vector::<u8>::with_capacity(n);
    let mut x: u64 = 0x9e3779b97f4a7c15;
    for _ in 0..n {
        x = x ^ x << 13;
        x = x ^ x >> 7;
        x = x ^ x << 17;
        v.push((x >> 24) as u8);
    }
    return v;
}

// `src` compressed, then decompressed into a buffer of its length: equal bytes.
fn round_trips(src: &Vector<u8>) bool {
    let mut z = String::new();
    lz::compress(src.as_ptr(), src.len(), &mut z);
    let mut back = Vector::<u8>::new();
    back.resize_default(src.len() + 1);
    if !lz::decompress(z.as_str().ptr(), z.len(), back.as_ptr() as *mut u8, src.len()) {
        return false;
    }
    return src.len() == 0 || unsafe cstring::memcmp(src.as_ptr(), back.as_ptr(), src.len()) == 0;
}

@test
fn lz_round_trips() {
    let empty = Vector::<u8>::new();
    assert(round_trips(&empty), "empty");
    let mut one = Vector::<u8>::new();
    one.push(7);
    assert(round_trips(&one), "one byte");
    let rnd = noise(100000);
    assert(round_trips(&rnd), "incompressible");
    // A run repeats itself (matches overlap the bytes they write), with lengths past 15 + 255.
    let mut run = Vector::<u8>::new();
    for i in 0..200000 {
        run.push(b"abc"[(i % 3) as usize]);
    }
    assert(round_trips(&run), "a long overlapping run");
    // A repeat farther back than a distance can name, after a literal run longer than 15 + 255.
    let mut far = noise(70000);
    for i in 0..1000 {
        let b = far[i as usize];
        far.push(b);
    }
    assert(round_trips(&far), "a repeat past the distance limit");
}

@test
fn lz_rejects_malformed_input() {
    let src = noise(5000);
    let mut z = String::new();
    lz::compress(src.as_ptr(), src.len(), &mut z);
    let mut out = Vector::<u8>::new();
    out.resize_default(src.len() + 2);
    let op = out.as_ptr() as *mut u8;
    let zp = z.as_str().ptr();
    assert(!lz::decompress(zp, z.len() - 1, op, src.len()), "truncated input");
    assert(!lz::decompress(zp, z.len(), op, src.len() + 1), "a longer output");
    assert(!lz::decompress(zp, z.len(), op, src.len() - 1), "a shorter output");
    // One literal, then a match five bytes back: before the output's start.
    let bad = "\x10x\x05\x00";
    assert(!lz::decompress(bad.ptr(), bad.len(), op, 8), "a distance past the output");
    let zero = "\x10x\x00\x00";
    assert(!lz::decompress(zero.ptr(), zero.len(), op, 8), "a distance of zero");
    assert(!lz::decompress(zp, 0, op, 0), "no input");
}
