// lsp::text tests: byte offset <-> UTF-16 line/character mapping over multi-byte text, and file URI
// conversion.
import lsp::text as text;

@test
fn text_line_starts_and_positions() {
    let src = "ab\ncdé\r\nx😀y\n";
    // bytes: a=0 b=1 \n=2 | c=3 d=4 é=5..6 \r=7 \n=8 | x=9 😀=10..13 y=14 \n=15
    let ls = text::line_starts(src);
    assert_eq(ls.len(), 4 as usize);
    assert_eq(*ls.at(1), 3 as u32);
    assert_eq(*ls.at(2), 9 as u32);
    assert_eq(*ls.at(3), 16 as u32);

    let p = text::offset_to_pos(src, &ls, 14); // 'y'
    assert_eq(p.line, 2 as u32);
    assert_eq(p.character, 3 as u32); // x(1) + emoji(2)
    let q = text::offset_to_pos(src, &ls, 5); // 'é'
    assert_eq(q.line, 1 as u32);
    assert_eq(q.character, 2 as u32);

    assert_eq(text::pos_to_offset(src, &ls, 2, 3), 14 as u32);
    assert_eq(text::pos_to_offset(src, &ls, 2, 1), 10 as u32);
    // character 2 lands inside the surrogate pair: stop before it
    assert_eq(text::pos_to_offset(src, &ls, 2, 2), 10 as u32);
    assert_eq(text::pos_to_offset(src, &ls, 1, 2), 5 as u32);
}

@test
fn text_clamping() {
    let src = "ab\ncd";
    let ls = text::line_starts(src);
    let p = text::offset_to_pos(src, &ls, 999);
    assert_eq(p.line, 1 as u32);
    assert_eq(p.character, 2 as u32);
    assert_eq(text::pos_to_offset(src, &ls, 99, 0), 3 as u32); // line clamps to the last
    assert_eq(text::pos_to_offset(src, &ls, 0, 99), 2 as u32); // character clamps to the line end
    assert_eq(text::pos_to_offset(src, &ls, 1, 99), 5 as u32);
}

@test
fn text_utf16_len() {
    assert_eq(text::utf16_len("abc", 0, 3), 3 as u32);
    assert_eq(text::utf16_len("é", 0, 2), 1 as u32);
    assert_eq(text::utf16_len("😀", 0, 4), 2 as u32);
    assert_eq(text::utf16_len("a😀b", 0, 6), 4 as u32);
    assert_eq(text::utf16_len("abc", 1, 99), 2 as u32); // end clamps
}

@test
fn text_uri_conversion() {
    let p = text::uri_to_path("file:///Users/a%20b/x.spc");
    assert_eq(p.as_str(), "/Users/a b/x.spc");
    let h = text::uri_to_path("file://localhost/tmp/x.spc");
    assert_eq(h.as_str(), "/tmp/x.spc");
    let u = text::path_to_uri("/Users/a b/x.spc");
    assert_eq(u.as_str(), "file:///Users/a%20b/x.spc");
    // roundtrip through both directions
    let rt = text::uri_to_path(u.as_str());
    assert_eq(rt.as_str(), "/Users/a b/x.spc");
}
