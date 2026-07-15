// lsp::json tests: parse/dump roundtrips, escape handling (incl. UTF-16 surrogate pairs), number forms,
// and the parser's strict rejection messages.
import lsp::json as json;

fn parse_ok(src: str) json::JSON {
    let r = json::parse(src);
    assert(r.is_ok());
    return r.unwrap();
}

fn parse_err(src: str, want: str) {
    let r = json::parse(src);
    assert(r.is_err());
    let e = r.unwrap_err();
    assert_eq(e.as_str(), want);
}

@test
fn json_parse_basic() {
    let v = parse_ok("{\"jsonrpc\":\"2.0\",\"id\":1,\"params\":{\"a\":[1,-2.5,true,false,null],\"s\":\"hi\"}}");
    assert(v.is_object());
    assert_eq(v.value_str("jsonrpc"), "2.0");
    assert_eq(v.value_i64("id", 0), 1 as i64);
    assert_eq(v.value_i64("missing", 7), 7 as i64);
    let p = v.at_key("params");
    let a = p.at_key("a");
    assert_eq(a.size(), 5 as usize);
    assert_eq(a.at(0).get_number(), 1.0);
    assert_eq(a.at(1).get_number(), -2.5);
    assert(a.at(2).get_bool());
    assert(!a.at(3).get_bool());
    assert(a.at(4).is_null());
    assert_eq(p.value_str("s"), "hi");
    assert(p.contains_key("s"));
    assert(!p.contains_key("t"));
}

@test
fn json_parse_root_scalars() {
    let n = parse_ok("  42 ");
    assert_eq(n.get_i64(), 42 as i64);
    let s = parse_ok("\"hi\"");
    assert_eq(s.get_str(), "hi");
    let t = parse_ok("true");
    assert(t.get_bool());
    let z = parse_ok("null");
    assert(z.is_null());
    let f = parse_ok("-1.5e2");
    assert_eq(f.get_number(), -150.0);
}

@test
fn json_string_escapes() {
    let v = parse_ok("\"a\\n\\t\\\"\\\\\\/\\u0041\\uD83D\\uDE00\"");
    assert_eq(v.get_str(), "a\n\t\"\\/A😀");
}

@test
fn json_dump_roundtrip() {
    let v = parse_ok("{\"a\":[1,2.5,\"x\"],\"b\":{\"c\":true,\"d\":null}}");
    let out = v.dump(false);
    assert_eq(out.as_str(), "{\"a\":[1,2.5,\"x\"],\"b\":{\"c\":true,\"d\":null}}");
    let back = parse_ok(out.as_str());
    assert_eq(back.at_key("b").value_i64("c", 9), 9 as i64); // c is a bool, not a number
    assert(back.at_key("b").at_key("c").get_bool());
}

@test
fn json_dump_escapes() {
    let v = json::JSON::string(String::from_str("a\"b\\c\nd\te"));
    let out = v.dump(false);
    assert_eq(out.as_str(), "\"a\\\"b\\\\c\\nd\\te\"");
}

@test
fn json_build_and_emplace() {
    let mut o = json::JSON::object();
    o.emplace("x", json::JSON::integer(3));
    o.emplace("x", json::JSON::integer(4)); // overwrite frees the old value
    let mut a = json::JSON::array();
    a.push_back(json::JSON::boolean(true));
    a.push_back(json::JSON::string(String::from_str("s")));
    o.emplace("arr", a);
    assert_eq(o.value_i64("x", 0), 4 as i64);
    assert_eq(o.size(), 2 as usize);
    let out = o.dump(false);
    assert_eq(out.as_str(), "{\"x\":4,\"arr\":[true,\"s\"]}");
}

@test
fn json_rejects_malformed() {
    parse_err("", "Empty input is not valid JSON");
    parse_err("   ", "Empty input is not valid JSON");
    parse_err("{", "Missing closing '}' for object");
    parse_err("[1,2", "Missing closing ']' for array");
    parse_err("[1,]", "Trailing ',' before closing ']'");
    parse_err("{\"a\":1,}", "Trailing ',' before closing '}'");
    parse_err("[1,,2]", "Duplicate ','");
    parse_err("[1 2]", "Missing ',' between array members");
    parse_err("{\"a\":1 \"b\":2}", "Missing ',' between object members");
    parse_err("{\"a\" \"b\"}", "Missing a colon after a key");
    parse_err("{\"a\" 1}", "Expected a key before adding a number");
    parse_err("{\"a\":}", "Missing value for key 'a' in object");
    parse_err("{:1}", "Expected a string key before ':'");
    parse_err("{\"a\":1}x", "Unexpected character 'x' after JSON end");
    parse_err("\"abc", "Unterminated string");
    parse_err("tru", "Unexpected character 'u'"); // truncated literal points at its last byte
    parse_err("truX", "Unexpected character 'X'");
    parse_err("{1:2}", "Expected a key before adding a number");
    parse_err("[01]", "Invalid number: Leading zeros are not allowed");
    parse_err("[-]", "Invalid number: digit expected after '-'");
    parse_err("[1.]", "Invalid number: digit expected after '.'");
    parse_err("[1e]", "Invalid number: digit expected after exponent");
    parse_err("[\"\\uD800x\"]", "Unexpected end of input: missing low surrogate after high surrogate (\\uXXXX)");
    parse_err("[\"\\uDC00\"]", "Unexpected low surrogate \\uDC00 without preceding high surrogate");
    parse_err("[\"\\q\"]", "Invalid escape sequence");
    parse_err("[\"\\uZZZZ\"]", "Invalid hex digit in \\uXXXX");
}

@test
fn json_numbers() {
    let v = parse_ok("[0,-0,3,1000000,0.25,1e3,2E-2,1.5e+2,9007199254740992]");
    assert_eq(v.at(0).get_number(), 0.0);
    assert_eq(v.at(2).get_i64(), 3 as i64);
    assert_eq(v.at(3).get_i64(), 1000000 as i64);
    assert_eq(v.at(4).get_number(), 0.25);
    assert_eq(v.at(5).get_number(), 1000.0);
    assert_eq(v.at(6).get_number(), 0.02);
    assert_eq(v.at(7).get_number(), 150.0);
    assert_eq(v.at(8).get_i64(), 9007199254740992 as i64);
    let out = v.dump(false);
    assert_eq(out.as_str(), "[0,0,3,1000000,0.25,1000,0.02,150,9007199254740992]");
}

@test
fn json_deep_nesting_capped() {
    // 2000 nested arrays exceed MAX_NESTING_DEPTH (1024) without touching the C stack
    let mut src = String::new();
    for i in 0..2000 as usize {
        src.push_byte(b'[');
    }
    for i in 0..2000 as usize {
        src.push_byte(b']');
    }
    parse_err(src.as_str(), "Nesting depth limit exceeded");
}
