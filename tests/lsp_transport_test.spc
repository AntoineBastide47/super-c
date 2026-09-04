// lsp::transport base-protocol framing: a write/read round trip, the exact wire bytes a write emits,
// and every malformed-framing path that read_message rejects with None. Driven over an anonymous
// temp stream (tmpfile), rewound between the write and the read.
import lsp::transport as transport;
import stdio;

extern "C" {
    fn tmpfile() *mut stdio::FILE;
}

// Write `bytes` to a fresh temp stream, rewind, and return the stream (caller closes).
fn stream_of(bytes: str) *mut stdio::FILE {
    let f = unsafe tmpfile();
    assert(f != null, "tmpfile");
    if bytes.len() > 0 {
        let _ = unsafe stdio::fwrite(bytes.ptr(), 1, bytes.len(), f);
    }
    unsafe stdio::rewind(f);
    return f;
}

fn read_from(bytes: str) Option<String> {
    let f = stream_of(bytes);
    let r = transport::read_message(f);
    unsafe stdio::fclose(f);
    return r;
}

fn expect_body(label: str, bytes: str, want: str) {
    switch read_from(bytes) {
        Some(b) => {
            assert(b.as_str() == want, label);
        },
        None => {
            assert(false, label);
        },
    };
}

fn expect_none(label: str, bytes: str) {
    assert(read_from(bytes).is_none(), label);
}

@test
fn read_well_formed_message() {
    expect_body("simple frame", "Content-Length: 2\r\n\r\n{}", "{}");
    // Body length is exact: bytes past N belong to the next message and are not consumed here.
    expect_body("length is exact", "Content-Length: 5\r\n\r\nhello world", "hello");
    // A blank body is legal.
    expect_body("empty body", "Content-Length: 0\r\n\r\n", "");
    // Header name is case-insensitive and other headers are ignored.
    expect_body(
        "extra headers and casing",
        "X-Trace: 1\r\ncontent-length: 3\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\nabc",
        "abc",
    );
}

@test
fn read_back_two_messages() {
    // read_message stops exactly at the body end, so a second call reads the next frame.
    let f = stream_of("Content-Length: 1\r\n\r\naContent-Length: 1\r\n\r\nb");
    switch transport::read_message(f) {
        Some(m) => {
            assert(m.as_str() == "a", "first body");
        },
        None => {
            assert(false, "first body");
        },
    };
    switch transport::read_message(f) {
        Some(m) => {
            assert(m.as_str() == "b", "second body");
        },
        None => {
            assert(false, "second body");
        },
    };
    unsafe stdio::fclose(f);
}

@test
fn write_message_emits_the_frame() {
    let f = unsafe tmpfile();
    assert(f != null, "tmpfile");
    transport::write_message(f, "{\"k\":1}");
    unsafe stdio::rewind(f);
    let got = transport::read_message(f);
    // What was written frames and reads back byte for byte.
    switch got {
        Some(b) => {
            assert(b.as_str() == "{\"k\":1}", "round trip");
        },
        None => {
            assert(false, "round trip");
        },
    };
    unsafe stdio::fclose(f);
}

@test
fn reject_malformed_framing() {
    expect_none("eof", "");
    expect_none("no content-length", "X-Trace: 1\r\n\r\nbody");
    expect_none("duplicate content-length", "Content-Length: 1\r\nContent-Length: 2\r\n\r\nab");
    expect_none("non-numeric length", "Content-Length: x\r\n\r\n");
    expect_none("negative length", "Content-Length: -1\r\n\r\n");
    expect_none("non-utf8 charset", "Content-Length: 1\r\nContent-Type: text/plain; charset=ascii\r\n\r\na");
    expect_none("body shorter than declared", "Content-Length: 8\r\n\r\nshort");
    // A declared length past the 128 MiB cap is refused before any body is read.
    expect_none("length over the cap", "Content-Length: 200000000\r\n\r\n");
}

@test
fn reject_too_many_headers() {
    let mut s = String::new();
    for _i in 0..40 {
        s.push_str("X-H: 1\r\n");
    }
    s.push_str("Content-Length: 1\r\n\r\na");
    expect_none("over the header-count limit", s.as_str());
}
