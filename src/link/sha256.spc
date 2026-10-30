// SHA-256 (FIPS 180-4), for the page hashes of a Mach-O code signature.

const K: [u32; 64] = [
    0x428A2F98,
    0x71374491,
    0xB5C0FBCF,
    0xE9B5DBA5,
    0x3956C25B,
    0x59F111F1,
    0x923F82A4,
    0xAB1C5ED5,
    0xD807AA98,
    0x12835B01,
    0x243185BE,
    0x550C7DC3,
    0x72BE5D74,
    0x80DEB1FE,
    0x9BDC06A7,
    0xC19BF174,
    0xE49B69C1,
    0xEFBE4786,
    0x0FC19DC6,
    0x240CA1CC,
    0x2DE92C6F,
    0x4A7484AA,
    0x5CB0A9DC,
    0x76F988DA,
    0x983E5152,
    0xA831C66D,
    0xB00327C8,
    0xBF597FC7,
    0xC6E00BF3,
    0xD5A79147,
    0x06CA6351,
    0x14292967,
    0x27B70A85,
    0x2E1B2138,
    0x4D2C6DFC,
    0x53380D13,
    0x650A7354,
    0x766A0ABB,
    0x81C2C92E,
    0x92722C85,
    0xA2BFE8A1,
    0xA81A664B,
    0xC24B8B70,
    0xC76C51A3,
    0xD192E819,
    0xD6990624,
    0xF40E3585,
    0x106AA070,
    0x19A4C116,
    0x1E376C08,
    0x2748774C,
    0x34B0BCB5,
    0x391C0CB3,
    0x4ED8AA4A,
    0x5B9CCA4F,
    0x682E6FF3,
    0x748F82EE,
    0x78A5636F,
    0x84C87814,
    0x8CC70208,
    0x90BEFFFA,
    0xA4506CEB,
    0xBEF9A3F7,
    0xC67178F2,
];

const H0: [u32; 8] = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19];

// One 64-byte block at `at` of `b` into state `h`.
const fn block(h: &mut [u32; 8], b: []u8, at: usize) {
    let k: []u32 = K;
    let mut w = [0u32; 64];
    for t in 0..16usize {
        let i = at + 4 * t;
        unsafe w[t] = b[i] as u32 << 24 | b[i + 1] as u32 << 16 | b[i + 2] as u32 << 8 | b[i + 3] as u32;
    }
    for t in 16..64usize {
        let x = unsafe w[t - 15];
        let y = unsafe w[t - 2];
        let s0 = x.rotate_right(7) ^ x.rotate_right(18) ^ x >> 3;
        let s1 = y.rotate_right(17) ^ y.rotate_right(19) ^ y >> 10;
        unsafe w[t] = unsafe w[t - 16].wrapping_add(s0).wrapping_add(unsafe w[t - 7]).wrapping_add(s1);
    }
    let mut a = h[0];
    let mut bb = h[1];
    let mut c = h[2];
    let mut d = h[3];
    let mut e = h[4];
    let mut f = h[5];
    let mut g = h[6];
    let mut hh = h[7];
    for t in 0..64usize {
        let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
        let ch = e & f ^ ~e & g;
        let t1 = hh.wrapping_add(s1).wrapping_add(ch).wrapping_add(k[t]).wrapping_add(unsafe w[t]);
        let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
        let maj = a & bb ^ a & c ^ bb & c;
        let t2 = s0.wrapping_add(maj);
        hh = g;
        g = f;
        f = e;
        e = d.wrapping_add(t1);
        d = c;
        c = bb;
        bb = a;
        a = t1.wrapping_add(t2);
    }
    h[0] = h[0].wrapping_add(a);
    h[1] = h[1].wrapping_add(bb);
    h[2] = h[2].wrapping_add(c);
    h[3] = h[3].wrapping_add(d);
    h[4] = h[4].wrapping_add(e);
    h[5] = h[5].wrapping_add(f);
    h[6] = h[6].wrapping_add(g);
    h[7] = h[7].wrapping_add(hh);
}

/// The SHA-256 digest of `data` into `out`.
pub(package) const fn digest(data: []u8, out: &mut [u8; 32]) {
    let mut h = H0;
    let n = data.len();
    let full = n / 64;
    for q in 0..full {
        block(&mut h, data, 64 * q);
    }
    // The tail, the 0x80 marker and the bit length, in one or two blocks: every index below is under
    // 128, the buffer's size.
    let mut tail = [0u8; 128];
    let rest = n - 64 * full;
    for i in 0..rest {
        unsafe tail[i] = data[64 * full + i];
    }
    unsafe tail[rest] = 0x80;
    let total = if rest < 56 {
        64usize
    } else {
        128usize
    };
    let bits = n as u64 * 8;
    for i in 0..8usize {
        unsafe tail[total - 1 - i] = (bits >> (8 * i) as u64 & 0xFF) as u8;
    }
    let ts: []u8 = unsafe tail[0..total];
    for q in 0..total / 64 {
        block(&mut h, ts, 64 * q);
    }
    let hs: []u32 = h;
    for i in 0..8usize {
        unsafe out[4 * i] = (hs[i] >> 24) as u8;
        unsafe out[4 * i + 1] = (hs[i] >> 16 & 0xFF) as u8;
        unsafe out[4 * i + 2] = (hs[i] >> 8 & 0xFF) as u8;
        unsafe out[4 * i + 3] = (hs[i] & 0xFF) as u8;
    }
}
