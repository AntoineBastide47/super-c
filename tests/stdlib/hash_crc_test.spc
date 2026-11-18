// std::hash::crc: CRC-32C against RFC 3720's vectors, continuation over every split, and the machine's
// path (SSE4.2 or FEAT_CRC32 where present) against the bitwise definition over lengths and offsets.

import std::hash::crc as crc;

// The bitwise definition: reflected polynomial 0x82F63B78, one bit per step.
const fn bitwise(data: []u8) u32 {
    let mut c: u32 = 0xFFFFFFFF;
    for i in 0..data.len() {
        c ^= data[i];
        for _ in 0..8 {
            c = if (c & 1) != 0 {
                c >> 1 ^ 0x82F63B78
            } else {
                c >> 1
            };
        }
    }
    return ~c;
}

// RFC 3720 appendix B.4, and the check value of "123456789".
@test
fn crc32c_matches_the_published_vectors() {
    let zeros: [u8; 32] = [0; 32];
    let ones: [u8; 32] = [0xFF; 32];
    let mut up: [u8; 32] = [0; 32];
    let mut down: [u8; 32] = [0; 32];
    for i in 0..32usize {
        up[i] = i as u8;
        down[i] = (31 - i) as u8;
    }
    assert_eq(crc::crc32c(0, zeros), 0x8A9136AA);
    assert_eq(crc::crc32c(0, ones), 0x62A8AB43);
    assert_eq(crc::crc32c(0, up), 0x46DD794E);
    assert_eq(crc::crc32c(0, down), 0x113FDB5C);
    let check: [u8; 9] = [b'1', b'2', b'3', b'4', b'5', b'6', b'7', b'8', b'9'];
    assert_eq(crc::crc32c(0, check), 0xE3069283);
    assert_eq(crc::crc32c(0, check[0..0]), 0);
}

// Every length to 100 at every offset to 8, whole and split at every point, against `bitwise`.
@test
fn crc32c_agrees_with_the_definition_over_lengths_offsets_and_splits() {
    let mut buf: [u8; 128] = [0; 128];
    let mut x: u32 = 0x12345678;
    for i in 0..128usize {
        x = x.wrapping_mul(1103515245).wrapping_add(12345);
        buf[i] = (x >> 16) as u8;
    }
    for off in 0..8usize {
        for n in 0..100usize {
            let d = buf[off..off + n];
            let want = bitwise(d);
            assert_eq(crc::crc32c(0, d), want);
            for s in 0..n + 1 {
                assert_eq(crc::crc32c(crc::crc32c(0, d[0..s]), d[s..n]), want);
            }
        }
    }
}
