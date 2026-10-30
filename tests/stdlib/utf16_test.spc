// std::text::utf16: every Unicode scalar value survives UTF-8 -> UTF-16 -> UTF-8 in one pass over one
// buffer, and ill-formed input on either side stops at the offset of its first bad sequence while the
// output keeps what it held. The oracle of the round trip is the code point arithmetic of RFC 3629 and
// RFC 2781, independent of the converter.

import std::text::utf16;

// Every scalar value 0..=0x10FFFF but the surrogates, UTF-8 encoded in order.
fn all_scalars() String {
    let mut s = String::with_capacity(4500000);
    for c in 0u32..0x110000u32 {
        if c < 0xD800 || c > 0xDFFF {
            s.push(c);
        }
    }
    return s;
}

@test
fn round_trips_every_scalar_value() {
    let text = all_scalars();
    let mut units = Vector::<u16>::new();
    assert(utf16::encode(&text, &mut units).is_ok());
    // The unit stream is the RFC 2781 form of the same sequence.
    let mut k: usize = 0;
    for c in 0u32..0x110000u32 {
        if c >= 0xD800 && c <= 0xDFFF {
            continue;
        }
        if c < 0x10000 {
            assert_eq(*units.at(k), c as u16);
            k += 1;
        } else {
            assert_eq(*units.at(k), (0xD800 + (c - 0x10000 >> 10)) as u16);
            assert_eq(*units.at(k + 1), (0xDC00 + (c - 0x10000 & 0x3FF)) as u16);
            k += 2;
        }
    }
    assert_eq(k, units.len());
    let mut back = String::new();
    assert(utf16::decode(units[0..units.len()], &mut back).is_ok());
    assert(back.equals(&text));
    // The caller-buffer form writes the same units.
    let mut buf = Vector::<u16>::new();
    buf.resize_default(text.len());
    let cap = buf.len();
    let n = utf16::encode_into(&text, buf.index_range_mut(0..cap)).unwrap();
    assert_eq(n, units.len());
    for i in 0..n {
        assert_eq(*buf.at(i), *units.at(i));
    }
}

@test
fn rejects_ill_formed_utf8_at_its_offset() {
    // (input, offset of the first bad sequence)
    let bad: [(str, usize); 14] = [
        ("\x80", 0), // stray continuation byte
        ("ab\xC0\xAF", 2), // overlong '/'
        ("\xC1\xBF", 0), // overlong
        ("x\xE0\x80\xAF", 1), // overlong three-byte form
        ("\xED\xA0\x80", 0), // surrogate U+D800
        ("ok\xED\xBF\xBF", 2), // surrogate U+DFFF
        ("\xF0\x80\x80\xAF", 0), // overlong four-byte form
        ("\xF4\x90\x80\x80", 0), // above U+10FFFF
        ("\xF5\x80\x80\x80", 0), // invalid lead byte
        ("\xFF", 0),
        ("abc\xE2\x82", 3), // truncated at the end
        ("\xE2\x28\xA1", 0), // bad continuation
        ("\xC3", 0), // truncated two-byte form
        ("a\xF0\x9F\x98", 1), // truncated four-byte form
    ];
    for (s, at) in bad {
        let mut units = Vector::<u16>::new();
        units.push(7);
        assert(utf16::encode(s, &mut units).unwrap_err() == utf16::EncodeError::InvalidUtf8(at));
        assert_eq(units.len(), 1);
        let mut buf: [u16; 8] = [0; 8];
        assert_eq(utf16::encode_into(s, buf), Err(utf16::EncodeError::InvalidUtf8(at)));
    }
}

@test
fn encode_into_reports_a_short_buffer() {
    let mut two: [u16; 2] = [0; 2];
    assert_eq(utf16::encode_into("abc", two), Err(utf16::EncodeError::BufferTooSmall));
    // A pair never splits across the end of the buffer.
    assert_eq(utf16::encode_into("a\xF0\x9F\x98\x80", two), Err(utf16::EncodeError::BufferTooSmall));
    assert_eq(utf16::encode_into("\xF0\x9F\x98\x80", two), Ok(2));
    assert_eq(two[0], 0xD83D);
    assert_eq(two[1], 0xDE00);
    let mut none: [u16; 0] = [];
    assert_eq(utf16::encode_into("", none), Ok(0));
}

@test
fn rejects_unpaired_surrogates_at_their_offset() {
    let lone_high: [u16; 3] = [0x41, 0xD800, 0x42];
    let lone_low: [u16; 2] = [0xDC00, 0x41];
    let reversed: [u16; 3] = [0x41, 0xDC00, 0xD800];
    let high_at_end: [u16; 2] = [0x41, 0xDBFF];
    let two_highs: [u16; 3] = [0xD800, 0xD800, 0xDC00];
    let cases: [([]u16, usize); 5] = [(lone_high, 1), (lone_low, 0), (reversed, 1), (high_at_end, 1), (two_highs, 0)];
    for (units, at) in cases {
        let mut out = String::from_str("keep");
        assert_eq(utf16::decode(units, &mut out).unwrap_err().offset, at);
        assert(out.eq_str("keep"));
    }
    let pair: [u16; 4] = [0x41, 0xDBFF, 0xDFFF, 0x7FF];
    let mut out = String::new();
    assert(utf16::decode(pair, &mut out).is_ok());
    assert(out.eq_str("A\xF4\x8F\xBF\xBF\xDF\xBF"));
}
