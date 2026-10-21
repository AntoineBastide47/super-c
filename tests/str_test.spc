// `str::is_valid_utf8` against Unicode Table 3-7: the boundary scalars of every byte-length class,
// the excluded overlong, surrogate and above-U+10FFFF forms, truncation and bad continuations, then
// every (lead, second byte) pair against a decode-and-range reference.

fn valid(s: []u8, n: usize) bool {
    return (unsafe str::from_raw(s.ptr, n)).is_valid_utf8();
}

// Reference: decode each sequence by its bit pattern, then reject what Table 3-7 excludes.
fn reference(s: []u8, n: usize) bool {
    let mut i: usize = 0;
    while i < n {
        let b = s[i];
        let mut len: usize = 0;
        let mut cp: u32 = 0;
        let mut min: u32 = 0;
        if b < 0x80 {
            i += 1;
            continue;
        } else if (b & 0xE0) == 0xC0 {
            len = 2;
            cp = b & 0x1F;
            min = 0x80;
        } else if (b & 0xF0) == 0xE0 {
            len = 3;
            cp = b & 0x0F;
            min = 0x800;
        } else if (b & 0xF8) == 0xF0 {
            len = 4;
            cp = b & 0x07;
            min = 0x10000;
        } else {
            return false;
        }
        if len > n - i {
            return false;
        }
        for k in 1..len {
            let c = s[i + k];
            if (c & 0xC0) != 0x80 {
                return false;
            }
            cp = cp << 6 | (c & 0x3F) as u32;
        }
        if cp < min || cp > 0x10FFFF || cp >= 0xD800 && cp <= 0xDFFF {
            return false;
        }
        i += len;
    }
    return true;
}

fn ok(s: []u8) bool {
    return valid(s, s.len);
}

@test
fn accepts_boundary_scalars() {
    assert(ok(b""), "empty");
    assert(ok(b"plain ASCII \x00\x7F"), "ASCII with NUL and DEL");
    assert(ok(b"\xC2\x80"), "U+0080");
    assert(ok(b"\xDF\xBF"), "U+07FF");
    assert(ok(b"\xE0\xA0\x80"), "U+0800");
    assert(ok(b"\xED\x9F\xBF"), "U+D7FF");
    assert(ok(b"\xEE\x80\x80"), "U+E000");
    assert(ok(b"\xEF\xBF\xBF"), "U+FFFF");
    assert(ok(b"\xF0\x90\x80\x80"), "U+10000");
    assert(ok(b"\xF4\x8F\xBF\xBF"), "U+10FFFF");
    assert("a\u{E9}\u{20AC}\u{1F600}z".is_valid_utf8(), "mixed 1 to 4 byte literal");
}

@test
fn rejects_excluded_forms() {
    assert(!ok(b"\xC0\x80"), "overlong NUL");
    assert(!ok(b"\xC1\xBF"), "overlong U+007F");
    assert(!ok(b"\xE0\x80\x80"), "overlong 3-byte U+0000");
    assert(!ok(b"\xE0\x9F\xBF"), "overlong U+07FF");
    assert(!ok(b"\xF0\x80\x80\x80"), "overlong 4-byte U+0000");
    assert(!ok(b"\xF0\x8F\xBF\xBF"), "overlong U+FFFF");
    assert(!ok(b"\xED\xA0\x80"), "surrogate U+D800");
    assert(!ok(b"\xED\xBF\xBF"), "surrogate U+DFFF");
    assert(!ok(b"\xF4\x90\x80\x80"), "U+110000");
    assert(!ok(b"\xF5\x80\x80\x80"), "lead F5");
    assert(!ok(b"\xFF"), "lead FF");
    assert(!ok(b"\x80"), "lone continuation");
    assert(!ok(b"a\xC2"), "truncated 2-byte");
    assert(!ok(b"\xE2\x82"), "truncated 3-byte");
    assert(!ok(b"\xF0\x9F\x98"), "truncated 4-byte");
    assert(!ok(b"\xC2\x41"), "ASCII as second byte");
    assert(!ok(b"\xE2\x82\x28"), "ASCII as third byte");
    assert(!ok(b"\xF0\x9F\x98\x28"), "ASCII as fourth byte");
}

// Every lead and second byte, with each tail byte class, at lengths 2 to 4: the second byte holds
// all the range limits. A mismatch records its bytes as 0xLLSSTTNN (lead, second, tail, length).
@test
fn matches_reference_on_all_lead_and_second_bytes() {
    let tails: []u8 = [0x80u8, 0xBF, 0x7F, 0xC0];
    let mut first_bad: u32 = 0xFFFFFFFF;
    let mut buf = [0u8; 4];
    for b0 in 0u32..256 {
        for b1 in 0u32..256 {
            for ti in 0..tails.len() {
                let t = tails[ti];
                buf[0] = b0 as u8;
                buf[1] = b1 as u8;
                buf[2] = t;
                buf[3] = t;
                let s: []u8 = buf;
                for n in 2usize..5 {
                    if valid(s, n) != reference(s, n) && first_bad == 0xFFFFFFFF {
                        first_bad = b0 << 24 | b1 << 16 | t as u32 << 8 | n as u32;
                    }
                }
            }
        }
    }
    assert_eq(first_bad, 0xFFFFFFFF);
}
