// The byte codec of the object cache's compressed entries (`objcache::pack_cache`): LZ77 in the LZ4
// block layout, greedy matching through a hash of four bytes and no entropy coding, so both directions
// run at memory speed. A sequence is a token (literal count in the high nibble, match length minus
// MIN_MATCH in the low one; 15 continues in bytes of 255 and a last byte below it), the literals, the
// match's distance back (two bytes, little-endian) and the match length's continuation; the last
// sequence has literals only.
import string as cstring;

const MIN_MATCH: usize = 4;
const MAX_DIST: usize = 65535;
// The match finder's table: the last position of each hash of four bytes (the top 14 bits of their
// multiplicative hash).
const HASH_SIZE: usize = 16384;
const HASH_SHIFT: u64 = 18;

// The four bytes at `p[i..i + 4]` as one word.
fn word4(p: *const u8, i: usize) u32 {
    let mut w: u32 = 0;
    unsafe cstring::memcpy((&mut w) as *mut u32, p + i, 4);
    return w;
}

// A length past the nibble's 15: bytes of 255, then the rest.
fn push_len(out: &mut String, n: usize) {
    let mut r = n;
    while r >= 255 {
        out.push_byte(255);
        r -= 255;
    }
    out.push_byte(r as u8);
}

// One sequence: `lit` literals from `src + start`, then (when `mlen` is not 0) a match `dist` back.
fn push_seq(out: &mut String, src: *const u8, start: usize, lit: usize, dist: usize, mlen: usize) {
    let ml = if mlen == 0 {
        0 as usize;
    } else {
        mlen - MIN_MATCH;
    };
    let ln = if lit < 15 {
        lit;
    } else {
        15 as usize;
    };
    let mn = if ml < 15 {
        ml;
    } else {
        15 as usize;
    };
    out.push_byte((ln << 4 | mn) as u8);
    if lit >= 15 {
        push_len(out, lit - 15);
    }
    out.push_str(unsafe str::from_raw(src + start, lit));
    if mlen != 0 {
        out.push_byte((dist & 255) as u8);
        out.push_byte((dist >> 8) as u8);
        if ml >= 15 {
            push_len(out, ml - 15);
        }
    }
}

// The eight bytes at `p[i..i + 8]` as one word.
fn word8(p: *const u8, i: usize) u64 {
    let mut w: u64 = 0;
    unsafe cstring::memcpy((&mut w) as *mut u64, p + i, 8);
    return w;
}

/// Append the compressed form of the `n` bytes at `src` to `out`.
pub fn compress(src: *const u8, n: usize, out: &mut String) {
    assert(n < 0xFFFFFFFF as usize, "lz: input past 4 GiB");
    // Position + 1 of the last four bytes per hash; 0 = none.
    let mut table = Vector::<u32>::new();
    table.resize_default(HASH_SIZE);
    let tp = table.as_ptr() as *mut u32;
    let mut anchor: usize = 0;
    let mut i: usize = 0;
    // Misses since the last match: past 32 the search steps further each time, so data with nothing to
    // match (already compressed sections) costs little.
    let mut misses: usize = 0;
    // Each step moves `i` forward: at most `n` steps.
    while i + MIN_MATCH <= n {
        let w = word4(src, i);
        let h = (w as u64 * 2654435761u64 >> HASH_SHIFT) as usize & HASH_SIZE - 1;
        let cand = (unsafe tp[h]) as usize;
        unsafe tp[h] = (i + 1) as u32;
        if cand != 0 && i - (cand - 1) <= MAX_DIST && word4(src, cand - 1) == w {
            let m = cand - 1;
            let mut len = MIN_MATCH;
            while i + len + 8 <= n && word8(src, m + len) == word8(src, i + len) {
                len += 8;
            }
            while i + len < n && unsafe src[m + len] == unsafe src[i + len] {
                len += 1;
            }
            push_seq(out, src, anchor, i - anchor, i - m, len);
            i += len;
            anchor = i;
            misses = 0;
        } else {
            i += 1 + (misses >> 5);
            misses += 1;
        }
    }
    push_seq(out, src, anchor, n - anchor, 0, 0);
}

// A length continuation at `src[*ip..n]` added to `base`; None when the input ends inside it or the
// length passes `limit`.
fn read_len(src: *const u8, n: usize, ip: &mut usize, base: usize, limit: usize) Option<usize> {
    let mut v = base;
    // Each byte read moves `ip` forward: at most `n` steps.
    while *ip < n {
        let b = (unsafe src[*ip]) as usize;
        *ip += 1;
        v += b;
        if v > limit {
            return Option::<usize>::None;
        }
        if b != 255 {
            return Option::<usize>::Some(v);
        }
    }
    return Option::<usize>::None;
}

/// Decompress the `n` bytes at `src` into the `raw` bytes at `dst`. False when the input is malformed:
/// a length past the output or the input, a match before the output's start, or an output of another
/// size.
pub fn decompress(src: *const u8, n: usize, dst: *mut u8, raw: usize) bool {
    let mut ip: usize = 0;
    let mut op: usize = 0;
    // Each sequence reads at least its token: at most `n` sequences.
    while ip < n {
        let token = (unsafe src[ip]) as usize;
        ip += 1;
        let mut lit = token >> 4;
        if lit == 15 {
            let v = read_len(src, n, &mut ip, lit, raw);
            if v.is_none() {
                return false;
            }
            lit = v.unwrap();
        }
        if lit > n - ip || lit > raw - op {
            return false;
        }
        unsafe cstring::memcpy(dst + op, src + ip, lit);
        ip += lit;
        op += lit;
        if ip == n {
            return op == raw;
        }
        if n - ip < 2 {
            return false;
        }
        let dist = (unsafe src[ip]) as usize | (unsafe src[ip + 1]) as usize << 8;
        ip += 2;
        if dist == 0 || dist > op {
            return false;
        }
        let mut ml = (token & 15) + MIN_MATCH;
        if (token & 15) == 15 {
            let v = read_len(src, n, &mut ip, ml, raw);
            if v.is_none() {
                return false;
            }
            ml = v.unwrap();
        }
        if ml > raw - op {
            return false;
        }
        if dist >= ml {
            unsafe cstring::memcpy(dst + op, dst + (op - dist), ml);
        } else {
            // An overlapping match repeats the bytes it is writing.
            for k in 0..ml {
                let b = unsafe dst[op - dist + k];
                unsafe dst[op + k] = b;
            }
        }
        op += ml;
    }
    return false;
}
