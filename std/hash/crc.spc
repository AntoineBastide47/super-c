// CRC-32C (Castagnoli: polynomial 0x1EDC6F41, bits reflected, the value inverted before and after), the
// checksum of iSCSI (RFC 3720), SCTP, ext4 and Btrfs. Where the processor computes it (x86-64 SSE4.2
// `crc32`, arm64 FEAT_CRC32 `crc32c`), 8 bytes per instruction, the path chosen once per process;
// elsewhere a table of 256 words, one byte per step. Every path gives the same value.
import std::cpu;
import std::cpu::detect as detect;
import std::mem::ptr;
import immintrin;
import arm_neon;

/// The CRC-32C of `data` continued from `crc`, the CRC-32C of the bytes before it (0 for none):
/// `crc32c(crc32c(0, a), b) == crc32c(0, a ++ b)`. `crc32c(0, "123456789")` is 0xE3069283.
pub fn crc32c(crc: u32, data: []u8) u32 {
    return ~crc32c_on(~crc, data);
}

// The reflected polynomial's remainder of each byte value, shifted through 8 steps.
const TABLE: [u32; 256] = table();

const fn table() [u32; 256] {
    let mut t: [u32; 256] = [0; 256];
    for i in 0..256usize {
        let mut c = i as u32;
        for _ in 0..8 {
            c = if (c & 1) != 0 {
                c >> 1 ^ 0x82F63B78
            } else {
                c >> 1
            };
        }
        t[i] = c;
    }
    return t;
}

// The register's value `c` (inverted) after the bytes of `data`, one table step per byte.
const fn crc32c_table(c0: u32, data: []u8) u32 {
    let mut c = c0;
    for i in 0..data.len() {
        c = TABLE[((c ^ data[i] as u32) & 0xFF) as usize] ^ c >> 8;
    }
    return c;
}

static mut CRC32C: detect::Dispatch = detect::Dispatch::new();

@arch(x86_64)
fn crc32c_on(c: u32, data: []u8) u32 {
    let f = unsafe detect::dispatch::<fn(u32, []u8) u32, 1>(
        &mut unsafe CRC32C,
        [(cpu::Feature::Sse42, crc32c_sse42)],
        crc32c_table,
    );
    return f(c, data);
}

@arch(aarch64)
fn crc32c_on(c: u32, data: []u8) u32 {
    let f = unsafe detect::dispatch::<fn(u32, []u8) u32, 1>(
        &mut unsafe CRC32C,
        [(cpu::Feature::Crc, crc32c_crc)],
        crc32c_table,
    );
    return f(c, data);
}

@arch(wasm32)
fn crc32c_on(c: u32, data: []u8) u32 {
    return crc32c_table(c, data);
}

// `crc32c_table` by SSE4.2's `crc32`: 8 bytes per step, then 1.
@arch(x86_64)
@target_feature([cpu::Feature::Sse42])
fn crc32c_sse42(c0: u32, data: []u8) u32 {
    let n = data.len();
    let mut c = c0 as u64;
    let mut i: usize = 0;
    while i + 8 <= n {
        c = immintrin::_mm_crc32_u64(c, unsafe ptr::read_unaligned::<u64>(data.ptr + i));
        i += 8;
    }
    let mut w = c as u32;
    while i < n {
        w = immintrin::_mm_crc32_u8(w, data[i]);
        i += 1;
    }
    return w;
}

// `crc32c_table` by FEAT_CRC32's `crc32cx` and `crc32cb`: 8 bytes per step, then 1.
@arch(aarch64)
@target_feature([cpu::Feature::Crc])
fn crc32c_crc(c0: u32, data: []u8) u32 {
    let n = data.len();
    let mut c = c0;
    let mut i: usize = 0;
    while i + 8 <= n {
        c = arm_neon::__crc32cd(c, unsafe ptr::read_unaligned::<u64>(data.ptr + i));
        i += 8;
    }
    while i < n {
        c = arm_neon::__crc32cb(c, data[i]);
        i += 1;
    }
    return c;
}
