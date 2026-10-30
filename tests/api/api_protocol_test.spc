// The tool-server protocol: the handshake and the launcher's grants, workspaces over memory files and
// confined disk roots, revisions, paging, every query, results equal to the native facade's, malformed
// input, and the process transports: stdio frames, the frame cap, cancellation of a running commit, and
// the owner-only socket.
import tests::cli_harness as cli;
import api::errors as *;
import api::protocol as pr;
import api::session as ses;
import api::semantic as sem;
import api::source as *;
import lsp::json as json;
import lsp::transport as transport;
import std::platform::fs;
import std::platform::process;
import std::platform::socket as sk;
import stdio;
import stdlib;

const APP: str = "/virtual/app/main.spc";
const SRC: str = "fn twice(x: i32) i32 {\n    return x + x;\n}\n\nfn main() i32 {\n    let b: bool = 3;\n    return twice(2) - twice(2);\n}\n";

fn limits() pr::Launch {
    return pr::Launch {
        std_dir: String::from_str("std"),
        grantable: pr::CAP_ALL,
        roots: Vector::<String>::new(),
        max_frame: 1 << 20,
        max_workspaces: 2,
    };
}

// The text of request `id` calling `method` with `params`.
fn req(id: i64, method: str, params: json::JSON) String {
    let mut o = json::JSON::object();
    o.emplace("id", json::JSON::integer(id));
    o.emplace("method", json::JSON::str(method));
    o.emplace("params", params);
    return o.dump();
}

// An object of the `n` pairs `kv[2i]: kv[2i + 1]`, each value a JSON text.
fn obj(kv: Slice<str>) json::JSON {
    let mut o = json::JSON::object();
    let mut i: usize = 0;
    while i + 1 < kv.len() {
        o.emplace(kv[i], json::parse(kv[i + 1]).unwrap());
        i += 2;
    }
    return o;
}

// `s` as a JSON string text.
fn q(s: str) String {
    let mut out = String::new();
    json::dump_escaped(s, &mut out);
    return out;
}

fn call(sv: &mut pr::Server, text: str) json::JSON {
    let none = ses::RequestOptions::none();
    let r = sv.handle(text, &none);
    return json::parse(&r).unwrap();
}

// Member `key` of the result of reply `r`; -1 when absent.
fn result_int(r: json::JSON, key: str) i64 {
    return r.at_key("result").value_i64(key, -1);
}

// Append the frame of `body` to `input`.
fn frame(input: &mut String, body: str) {
    input.format_into("Content-Length: {}\r\n\r\n", body.len());
    input.push_str(body);
}

// The error code name of reply `r`; empty for a result.
fn code_of(r: json::JSON) String {
    return switch r.value("error") {
        Some(e) => String::from_str(e.value_str("code")),
        None => String::new(),
    };
}

fn hello(sv: &mut pr::Server, required: str) json::JSON {
    let p = obj(["protocol_versions", "[1]", "client", "\"test\"", "required", required]);
    return call(sv, req(1, "hello", p).as_str());
}

// A ready server with workspace 1 over the memory file APP holding SRC, committed.
fn ready() pr::Server {
    let mut sv = pr::Server::new(limits());
    let h = hello(&mut sv, "[\"session\",\"syntax\",\"navigation\",\"refactoring\",\"ir_views\"]");
    assert_eq(code_of(h).as_str(), "");
    let mut files = json::JSON::object();
    files.emplace(APP, json::JSON::str(SRC));
    let mut p = obj(["kind", "\"file\"", "path", q(APP).as_str()]);
    p.emplace("files", files);
    let o = call(&mut sv, req(2, "open_workspace", p).as_str());
    assert_eq(o.at_key("result").value_i64("workspace", -1), 1);
    let c = call(&mut sv, req(3, "commit", obj(["workspace", "1"])).as_str());
    assert_eq(code_of(c).as_str(), "");
    return sv;
}

// A query of workspace 1 at its revision.
fn query(sv: &mut pr::Server, cap: str, method: str, args: str, extra: str) json::JSON {
    let rev = result_int(call(sv, req(90, "commit", obj(["workspace", "1"])).as_str()), "revision");
    let text = format(
        "{{\"id\":91,\"method\":\"query\",\"params\":{{\"workspace\":1,\"revision\":{},\"capability\":\"{}\",\"method\":\"{}\",\"arguments\":{}{}}}}}",
        rev,
        cap,
        method,
        args,
        extra,
    );
    return call(sv, &text);
}

@test
fn the_handshake_grants_within_the_launchers_set() {
    let mut sv = pr::Server::new(limits());
    let early = call(&mut sv, req(0, "commit", obj(["workspace", "1"])).as_str());
    assert_eq(code_of(early).as_str(), "protocol_failed");
    let p = obj(["protocol_versions", "[2, 3]"]);
    assert_eq(code_of(call(&mut sv, req(1, "hello", p).as_str())).as_str(), "version_mismatch");
    assert_eq(code_of(hello(&mut sv, "[\"backends\"]")).as_str(), "unsupported_capability");
    let ok = call(
        &mut sv,
        req(2, "hello", obj(["protocol_versions", "[1]", "optional", "[\"syntax\", \"future\"]"])).as_str(),
    );
    let caps = ok.at_key("result").at_key("capabilities");
    assert_eq(caps.size(), 1);
    assert_eq(caps.at(0).get_str(), "syntax");
    assert_eq(code_of(hello(&mut sv, "[]")).as_str(), "protocol_failed");
    // No session grant: no workspace.
    let o = call(&mut sv, req(3, "open_workspace", obj(["kind", "\"file\"", "path", "\"/x.spc\""])).as_str());
    assert_eq(code_of(o).as_str(), "unsupported_capability");
    // A launcher that allows syntax alone grants nothing more.
    let mut l = limits();
    l.grantable = pr::CAP_SYNTAX;
    let mut narrow = pr::Server::new(l);
    assert_eq(code_of(hello(&mut narrow, "[\"navigation\"]")).as_str(), "unsupported_capability");
    assert_eq(pr::cap_bit("ir_views"), pr::CAP_IR_VIEWS);
    assert_eq(pr::cap_bit("nope"), 0u32);
    assert_eq(pr::code_name(Code::NotChecked), "not_checked");
}

@test
fn requests_check_revisions_and_page_results() {
    let mut sv = ready();
    let d = query(&mut sv, "session", "diagnostics", "{}", "");
    let items = d.at_key("result").at_key("items");
    assert_eq(items.size(), 2);
    assert_eq(items.at(1).value_str("code"), "mismatched_types_expected_found");
    let at = SRC.find("twice(2) -") as i64;
    let args = format("{{\"file\":{},\"offset\":{},\"include_declaration\":true}}", q(APP).as_str(), at);
    let all = query(&mut sv, "navigation", "references", &args, "");
    assert_eq(all.at_key("result").at_key("items").size(), 3);
    assert_eq(all.at_key("result").value_i64("next_cursor", 0), -1);
    // A one-byte limit pages one item at a time.
    let mut cursor: i64 = 0;
    let mut seen: usize = 0;
    for _ in 0..4 {
        let pg = query(
            &mut sv,
            "navigation",
            "references",
            &args,
            format(",\"limit\":1,\"cursor\":{}", cursor).as_str(),
        );
        seen += pg.at_key("result").at_key("items").size();
        cursor = pg.at_key("result").value_i64("next_cursor", -2);
        if cursor < 0 {
            break;
        }
    }
    assert_eq(seen, 3usize);
    assert_eq(cursor, -1);
    // A change makes the revision stale until the next commit.
    let rev = all.at_key("id").get_i64();
    let _ = rev;
    let set = obj(["workspace", "1", "file", q(APP).as_str(), "text", q(SRC).as_str(), "expected_version", "0"]);
    let sr = call(&mut sv, req(10, "set_file_text", set).as_str());
    assert_eq(code_of(sr).as_str(), "invalid_argument"); // the file is at no version 0: it was never set
    let set2 = obj(["workspace", "1", "file", q(APP).as_str(), "text", q(SRC).as_str()]);
    let r2 = result_int(call(&mut sv, req(11, "set_file_text", set2).as_str()), "revision");
    let stale = format(
        "{{\"id\":12,\"method\":\"query\",\"params\":{{\"workspace\":1,\"revision\":{},\"capability\":\"session\",\"method\":\"diagnostics\"}}}}",
        r2 - 1,
    );
    assert_eq(code_of(call(&mut sv, &stale)).as_str(), "stale_handle");
    let unchecked = format(
        "{{\"id\":13,\"method\":\"query\",\"params\":{{\"workspace\":1,\"revision\":{},\"capability\":\"session\",\"method\":\"diagnostics\"}}}}",
        r2,
    );
    assert_eq(code_of(call(&mut sv, &unchecked)).as_str(), "not_checked");
    let bs = SRC.find("bool");
    let edits = format(
        "{{\"workspace\":1,\"file\":{},\"edits\":[{{\"start\":{},\"end\":{},\"text\":\"i32\"}}]}}",
        q(APP).as_str(),
        bs,
        bs + 4,
    );
    let er = call(&mut sv, req(14, "apply_edits", json::parse(&edits).unwrap()).as_str());
    assert_eq(code_of(er).as_str(), "");
    let clean = query(&mut sv, "session", "diagnostics", "{}", "");
    assert_eq(clean.at_key("result").at_key("items").size(), 1); // the unused binding alone
    let bad = format(
        "{{\"workspace\":1,\"file\":{},\"edits\":[{{\"start\":5,\"end\":900,\"text\":\"\"}}]}}",
        q(APP).as_str(),
    );
    assert_eq(
        code_of(call(&mut sv, req(15, "apply_edits", json::parse(&bad).unwrap()).as_str())).as_str(),
        "invalid_argument",
    );
    assert_eq(code_of(call(&mut sv, req(16, "close_workspace", obj(["workspace", "1"])).as_str())).as_str(), "");
    assert_eq(code_of(call(&mut sv, req(17, "commit", obj(["workspace", "1"])).as_str())).as_str(), "wrong_workspace");
}

@test
fn every_query_answers() {
    let mut sv = ready();
    let f = q(APP);
    let at = SRC.find("twice(2) -") as i64;
    let fa = format("{{\"file\":{},\"offset\":{}}}", f.as_str(), at);
    let fmt = query(&mut sv, "syntax", "format", format("{{\"file\":{}}}", f.as_str()).as_str(), "");
    assert(fmt.at_key("result").value_str("text").starts_with("fn twice"), "the formatted text");
    let nodes = query(&mut sv, "syntax", "nodes", format("{{\"file\":{}}}", f.as_str()).as_str(), "");
    assert(nodes.at_key("result").at_key("items").size() > 10, "the syntax nodes");
    assert_eq(nodes.at_key("result").at_key("items").at(0).value_str("kind"), "Function");
    let sym = query(&mut sv, "navigation", "symbol_at", &fa, "");
    assert_eq(sym.at_key("result").at_key("symbol").value_str("name"), "twice");
    assert_eq(sym.at_key("result").at_key("symbol").value_str("kind"), "Function");
    let hov = query(&mut sv, "navigation", "hover", &fa, "");
    assert(hov.at_key("result").value_str("text").contains("twice"), "the hover text");
    let none = query(&mut sv, "navigation", "hover", format("{{\"file\":{},\"offset\":0}}", f.as_str()).as_str(), "");
    assert(
        none.at_key("result").at_key("text").is_null() || none.at_key("result").at_key("text").is_string(),
        "hover answers",
    );
    let out = query(&mut sv, "navigation", "outline", format("{{\"file\":{}}}", f.as_str()).as_str(), "");
    assert_eq(out.at_key("result").at_key("items").size(), 2);
    let fs = query(&mut sv, "navigation", "find_symbols", "{\"query\":\"twi\"}", "");
    assert_eq(fs.at_key("result").at_key("items").size(), 1);
    let rn = query(
        &mut sv,
        "refactoring",
        "rename",
        format("{{\"file\":{},\"offset\":{},\"new_name\":\"double\"}}", f.as_str(), at).as_str(),
        "",
    );
    assert_eq(rn.at_key("result").at_key("items").size(), 3);
    assert_eq(rn.at_key("result").at_key("items").at(0).value_str("text"), "double");
    let cf = query(&mut sv, "ir_views", "core_function", &fa, "");
    assert(cf.at_key("result").value_i64("blocks", 0) >= 1, "the Core IR blocks");
    let hn = query(
        &mut sv,
        "ir_views",
        "hir_nodes",
        format("{{\"file\":{},\"start\":0,\"end\":40}}", f.as_str()).as_str(),
        "",
    );
    assert(hn.at_key("result").at_key("items").size() > 3, "the HIR nodes");
    assert_eq(code_of(query(&mut sv, "navigation", "teleport", "{}", "")).as_str(), "protocol_failed");
    assert_eq(code_of(query(&mut sv, "navigation", "hover", "{\"file\":1}", "")).as_str(), "invalid_argument");
    assert_eq(code_of(query(&mut sv, "navigation", "hover", "[]", "")).as_str(), "invalid_argument");
}

// A process client and a native client get the same results.
@test
fn protocol_results_equal_native_results() {
    let mut sv = ready();
    let mut mem = MemoryFiles::over_disk();
    mem.set(APP, SRC);
    let mut s = ses::Session::open_file(APP, ses::Config::with_files("std", Box::new(mem))).unwrap();
    s.check().unwrap();
    let at = SRC.find("twice(2) -") as u32;
    let none = ses::RequestOptions::none();
    let mut native = sem::references_at(&mut s, APP, at, true, &none).unwrap();
    native.sort_by(|a: &sem::Location, b: &sem::Location| a.start.cmp(&b.start));
    let args = format("{{\"file\":{},\"offset\":{},\"include_declaration\":true}}", q(APP).as_str(), at);
    let items = query(&mut sv, "navigation", "references", &args, "");
    let it = items.at_key("result").at_key("items");
    assert_eq(it.size(), native.len());
    for i in 0..native.len() {
        assert_eq(it.at(i).value_i64("start", -1), native[i].start as i64);
        assert_eq(it.at(i).value_i64("end", -1), native[i].end as i64);
        assert_eq(it.at(i).value_str("file"), native[i].file.as_str());
    }
    let mut nd = Vector::<(u32, u16)>::new();
    let mut ds = s.diagnostics().unwrap();
    while let Some(d) = ds.next() {
        nd.push((d.start(), d.code()));
    }
    let pq = query(&mut sv, "session", "diagnostics", "{}", "");
    let pd = pq.at_key("result").at_key("items");
    assert_eq(pd.size(), nd.len());
    for i in 0..nd.len() {
        assert_eq(pd.at(i).value_i64("start", -1), nd[i].0 as i64);
    }
}

// Whether a workspace over the lone file `path` reads it: its commit succeeds with no error.
fn reads(sv: &mut pr::Server, path: str) bool {
    let o = call(sv, req(2, "open_workspace", obj(["kind", "\"file\"", "path", q(path).as_str()])).as_str());
    let w = result_int(o, "workspace");
    let c = call(sv, req(3, "commit", obj(["workspace", format("{}", w).as_str()])).as_str());
    if code_of(c.clone()).len() != 0 {
        return false;
    }
    let t = format(
        "{{\"id\":4,\"method\":\"query\",\"params\":{{\"workspace\":{},\"revision\":{},\"capability\":\"session\",\"method\":\"diagnostics\"}}}}",
        w,
        result_int(c, "revision"),
    );
    let d = call(sv, &t);
    let items = d.at_key("result").at_key("items");
    for i in 0..items.size() {
        if items.at(i).value_i64("severity", 0) == 1 {
            return false;
        }
    }
    return true;
}

// Workspaces see their own files alone; disk files outside the launcher's roots stay unreadable.
@test
fn workspaces_are_isolated_and_confined() {
    let proj = cli::proj_new();
    proj.mkfile("inside/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    proj.mkfile("outside/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let mut l = limits();
    l.max_workspaces = 3;
    l.roots.push(format("{}/inside", proj.dir()));
    let mut sv = pr::Server::new(l);
    let _ = hello(&mut sv, "[\"session\"]");
    let inside = format("{}/inside/main.spc", proj.dir());
    let outside = format("{}/outside/main.spc", proj.dir());
    assert(reads(&mut sv, &inside), "a file inside a root reads");
    assert(!reads(&mut sv, &outside), "a file outside the roots does not read");
    // A symbolic link inside a root that points outside it does not read either.
    let link = format("{}/inside/link.spc", proj.dir());
    assert(fs::symlink(&outside, &link).is_ok(), "the link is made");
    assert(!reads(&mut sv, &link), "a link out of the roots does not read");
    // Two memory workspaces of one path keep their own texts.
    let mut two = pr::Server::new(limits());
    let _ = hello(&mut two, "[\"session\"]");
    for k in 0..2 {
        let mut files = json::JSON::object();
        files.emplace(
            APP,
            json::JSON::str(
                if k == 0 {
                    SRC
                } else {
                    "fn main() i32 {\n    return 0;\n}\n"
                },
            ),
        );
        let mut p = obj(["kind", "\"file\"", "path", q(APP).as_str()]);
        p.emplace("files", files);
        assert_eq(code_of(call(&mut two, req(10 + k, "open_workspace", p).as_str())).as_str(), "");
    }
    let mut p3 = obj(["kind", "\"file\"", "path", q(APP).as_str()]);
    p3.emplace("files", json::JSON::object());
    assert_eq(code_of(call(&mut two, req(12, "open_workspace", p3).as_str())).as_str(), "limit");
    for w in 1..3 {
        let c = call(&mut two, req(20 + w, "commit", obj(["workspace", format("{}", w).as_str()])).as_str());
        let rev = c.at_key("result").value_i64("revision", -1);
        let t = format(
            "{{\"id\":30,\"method\":\"query\",\"params\":{{\"workspace\":{},\"revision\":{},\"capability\":\"session\",\"method\":\"diagnostics\"}}}}",
            w,
            rev,
        );
        let r = call(&mut two, &t);
        let n = r.at_key("result").at_key("items").size();
        assert_eq(
            n,
            if w == 1 {
                2usize
            } else {
                0usize
            },
        );
    }
}

// Corrupted requests get an error answer, never a crash.
@test
fn malformed_requests_get_errors() {
    let mut sv = ready();
    let at = SRC.find("twice(2) -") as i64;
    let mut seeds = Vector::<String>::new();
    seeds.push(
        format(
            "{{\"id\":5,\"method\":\"query\",\"params\":{{\"workspace\":1,\"revision\":0,\"capability\":\"navigation\",\"method\":\"references\",\"arguments\":{{\"file\":{},\"offset\":{}}},\"limit\":10}}}}",
            q(APP).as_str(),
            at,
        ),
    );
    seeds.push(
        format(
            "{{\"id\":6,\"method\":\"apply_edits\",\"params\":{{\"workspace\":1,\"file\":{},\"edits\":[{{\"start\":1,\"end\":2,\"text\":\"x\"}}]}}}}",
            q(APP).as_str(),
        ),
    );
    seeds.push(
        String::from_str(
            "{\"id\":7,\"method\":\"open_workspace\",\"params\":{\"kind\":\"file\",\"path\":\"/v/a.spc\",\"files\":{\"/v/a.spc\":\"fn main() i32 { return 0; }\"}}}",
        ),
    );
    seeds.push(String::from_str("{\"id\":8,\"method\":\"cancel\",\"params\":{\"target\":3}}"));
    let mut x: u64 = 0x9E3779B97F4A7C15;
    for i in 0..600 {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        let mut m = seeds[i as usize % seeds.len()].clone();
        let pos = (x % m.len() as u64) as usize;
        let op = (x >> 32) % 4;
        let bytes = m.as_str();
        let mut t = String::new();
        if op == 0 {
            t.push_str(bytes.slice(0, pos));
        } else if op == 1 {
            t.push_str(bytes.slice(0, pos));
            t.push_byte(b"{}[]\":,-0e9x"[((x >> 40) % 12) as usize]);
            t.push_str(bytes.slice(pos + 1, bytes.len()));
        } else if op == 2 {
            t.push_str(bytes.slice(0, pos));
            t.push_str("\"id\":-3,");
            t.push_str(bytes.slice(pos, bytes.len()));
        } else {
            t.push_str(bytes.slice(0, pos));
            t.push_str("{\"a\":[[[[1e999]]]]}");
            t.push_str(bytes.slice(pos, bytes.len()));
        }
        m = t;
        let none = ses::RequestOptions::none();
        let r = sv.handle(&m, &none);
        let v = json::parse(&r).unwrap();
        assert(v.contains_key("id") && (v.contains_key("result") || v.contains_key("error")), r.as_str());
    }
}

// The little-endian u32 at byte `o` of `p`.
fn get_u32(p: &Vector<u8>, o: usize) u32 {
    let b = p.as_ptr();
    return (unsafe b[o]) as u32 | (unsafe b[o + 1]) as u32 << 8 | (unsafe b[o + 2]) as u32 << 16 | (unsafe b[o + 3]) as u32 << 24;
}

// The items of `locations.1` batch `p` that reply `v` announces; empty when its checksum or size is wrong.
fn decode(v: &json::JSON, p: &Vector<u8>) Vector<(u32, u32, u32)> {
    let b = v.at_key("result").at_key("batch");
    let mut out = Vector::<(u32, u32, u32)>::new();
    if b.value_str("schema") != "locations.1" || b.value_str("endian") != "little" || b.value_i64("bytes", -1) != p.len() as i64 {
        return out;
    }
    let n = p.len() / 12;
    out.reserve(n);
    let mut sum: u32 = 0;
    for i in 0..n {
        let f = get_u32(p, 12 * i);
        let st = get_u32(p, 12 * i + 4);
        let en = get_u32(p, 12 * i + 8);
        sum = sum.wrapping_add(f).wrapping_add(st).wrapping_add(en);
        out.push((f, st, en));
    }
    if sum as i64 != b.value_i64("checksum", -1) {
        out.clear();
    }
    return out;
}

// A reference list of 10,001 results comes as a binary batch whose decoded items equal the native list. The
// overhead limit (20% over the native call) is measured by the `api_protocol_overhead` bench lane.
@test(timeout = 300)
fn a_large_reference_list_comes_as_a_binary_batch() {
    let mut src = String::from_str("fn one() i32 {\n    return 1;\n}\n\nfn main() i32 {\n    let mut n = 0;\n");
    for _ in 0..10000 {
        src.push_str("    n += one();\n");
    }
    src.push_str("    return n - 10000;\n}\n");
    let mut sv = pr::Server::new(limits());
    let _ = hello(&mut sv, "[\"session\",\"navigation\"]");
    let mut files = json::JSON::object();
    files.emplace(APP, json::JSON::str(&src));
    let mut p = obj(["kind", "\"file\"", "path", q(APP).as_str()]);
    p.emplace("files", files);
    let _ = call(&mut sv, req(2, "open_workspace", p).as_str());
    let rev = result_int(call(&mut sv, req(3, "commit", obj(["workspace", "1"])).as_str()), "revision");
    let mut mem = MemoryFiles::over_disk();
    mem.set(APP, &src);
    let mut s = ses::Session::open_file(APP, ses::Config::with_files("std", Box::new(mem))).unwrap();
    s.check().unwrap();
    let at = src.as_str().find("one()") as u32;
    let text = format(
        "{{\"id\":4,\"method\":\"query\",\"params\":{{\"workspace\":1,\"revision\":{},\"capability\":\"navigation\",\"method\":\"references\",\"arguments\":{{\"file\":{},\"offset\":{},\"include_declaration\":true}},\"binary\":true}}}}",
        rev,
        q(APP).as_str(),
        at,
    );
    let none = ses::RequestOptions::none();
    let ls = sem::references_at(&mut s, APP, at, true, &none).unwrap();
    assert_eq(ls.len(), 10001usize);
    let r = sv.handle(&text, &none);
    let batch = sv.take_payload();
    let reply = json::parse(&r).unwrap();
    let got = decode(&reply, &batch);
    assert_eq(got.len(), 10001usize);
    for i in 0..got.len() {
        assert(got[i].0 == 0 && got[i].1 == ls[i].start && got[i].2 == ls[i].end, "the batch equals the native list");
    }
}

// The stdio server answers frames in order, ends at the end of its input, and closes on a frame past
// its cap without reading it.
@test(timeout = 300)
fn the_stdio_server_answers_frames() {
    let proj = cli::proj_new();
    let mut input = String::new();
    frame(&mut input, req(1, "hello", obj(["protocol_versions", "[1]", "required", "[\"session\"]"])).as_str());
    frame(&mut input, "not json");
    frame(&mut input, req(2, "close_workspace", obj(["workspace", "9"])).as_str());
    input.push_str("Content-Length: 99999999\r\n\r\n");
    frame(&mut input, req(3, "close_workspace", obj(["workspace", "9"])).as_str());
    proj.mkfile("in.bin", &input);
    let mut cmd = format("{} tool-server --stdio --max-frame=4096", cli::superc_path());
    let mut ip = format("{}/in.bin", proj.dir());
    let mut op = format("{}/out.bin", proj.dir());
    let mut ep = format("{}/err.txt", proj.dir());
    let rc = cli::run_io(cmd.cstr(), ip.cstr(), op.cstr(), ep.cstr());
    assert_eq(rc, 0);
    let out = cli::read_text(&op);
    let f = stdio::fopen(&op, "rb");
    let mut rd = transport::Reader::new(f);
    let mut replies = Vector::<String>::new();
    while let Some(m) = transport::read_message(&mut rd) {
        replies.push(m);
    }
    let _ = unsafe stdio::fclose(f);
    assert_eq(replies.len(), 3usize);
    assert(replies[0].as_str().contains("\"capabilities\":[\"session\"]"), out.as_str());
    assert(replies[1].as_str().contains("protocol_failed"), out.as_str());
    assert(replies[2].as_str().contains("wrong_workspace"), out.as_str());
    let bad = cli::superc_in(proj.dir(), "tool-server --stdio --socket=/x");
    assert(!bad.ok(), "one transport");
}

// A cancel stops the running commit of this repository; the workspace reports `cancelled`.
@test(timeout = 600)
fn a_cancel_stops_a_running_commit() {
    let proj = cli::proj_new();
    let cwd = process::current_dir().unwrap();
    let mut input = String::new();
    frame(&mut input, req(1, "hello", obj(["protocol_versions", "[1]", "required", "[\"session\"]"])).as_str());
    frame(&mut input, req(2, "open_workspace", obj(["kind", "\"project\"", "path", q(&cwd).as_str()])).as_str());
    frame(&mut input, req(3, "commit", obj(["workspace", "1"])).as_str());
    frame(&mut input, req(4, "cancel", obj(["target", "3"])).as_str());
    proj.mkfile("in.bin", &input);
    let mut cmd = format("{} tool-server --stdio --root={}", cli::superc_path(), cwd.as_str());
    let mut ip = format("{}/in.bin", proj.dir());
    let mut op = format("{}/out.bin", proj.dir());
    let mut ep = format("{}/err.txt", proj.dir());
    let rc = cli::run_io(cmd.cstr(), ip.cstr(), op.cstr(), ep.cstr());
    assert_eq(rc, 0);
    let out = cli::read_text(&op);
    assert(out.as_str().contains("{\"id\":2,\"result\":{\"workspace\":1"), out.as_str());
    assert(out.as_str().contains("{\"id\":3,\"error\":{\"code\":\"cancelled\""), out.as_str());
    assert(out.as_str().contains("{\"id\":4,\"result\":{}}"), out.as_str());
}

// The socket server makes an owner-only directory and a 0600 socket, and serves a client of its user.
@platform(macos | linux)
@test(timeout = 300)
fn the_socket_server_serves_its_user() {
    let proj = cli::proj_new();
    let dir = format("{}/sock", proj.dir());
    let path = format("{}/s", dir.as_str());
    let sock_arg = format("--socket={}", path.as_str());
    let args: [str; 3] = [cli::superc_path(), "tool-server", sock_arg.as_str()];
    let mut child = process::spawn(
        process::Command {
            argv: args,
            program: None,
            env: None,
            cwd: None,
            command_line: None,
            stdin: process::Redirect::Null,
            stdout: process::Redirect::Null,
            stderr: process::Redirect::Inherit,
        },
    ).unwrap();
    let mut fd: i32 = -1;
    for _ in 0..500 {
        if let Ok(c) = sk::unix_connect(&path) {
            fd = c;
            break;
        }
        let _ = sk::wait_fd(-1, false, 10);
    }
    assert(fd >= 0, "the server listens");
    assert_eq(fs::stat(&dir).unwrap().permissions & 0o777, 0o700u32);
    assert_eq(fs::stat(&path).unwrap().permissions & 0o777, 0o600u32);
    let body = req(1, "hello", obj(["protocol_versions", "[1]"]));
    let mut msg = format("Content-Length: {}\r\n\r\n", body.len());
    msg.push_string(&body);
    let mut sent: usize = 0;
    while sent < msg.len() {
        let n = sk::write(fd, unsafe Slice::<u8> { ptr: msg.as_ptr() + sent, len: msg.len() - sent }).unwrap();
        sent += n;
    }
    let mut buf: [u8; 4096] = [0; 4096];
    let mut got = String::new();
    for _ in 0..100 {
        let n = sk::read(fd, unsafe SliceMut::<u8> { ptr: &mut buf[0], len: 4096 }).unwrap_or(0);
        if n == 0 {
            break;
        }
        got.push_str(unsafe str::from_raw(&buf[0], n));
        if got.as_str().contains("}}}") {
            break;
        }
    }
    assert(got.as_str().contains("\"protocol\":1"), got.as_str());
    let _ = sk::close(fd);
    let _ = child.kill();
    let _ = child.wait();
}

// The protocol v1 fixture (`sdk/protocol/v1.transcript`): the server answers each request with exactly the
// recorded reply. `SC_PROTOCOL_RECORD=1` writes the replies of this server into the file instead.
@test
fn the_v1_transcript_replays_exactly() {
    let path = "sdk/protocol/v1.transcript";
    let text = cli::read_text(path);
    let record = stdlib::getenv("SC_PROTOCOL_RECORD") != null;
    let mut sv = pr::Server::new(limits());
    let none = ses::RequestOptions::none();
    let mut out = String::new();
    let mut want = String::new();
    let mut replies = 0;
    for line in text.as_str().lines() {
        if line.starts_with("> ") {
            out.push_str(line);
            out.push_str("\n");
            let r = sv.handle(line.slice(2, line.len()), &none);
            let _ = sv.take_payload();
            out.format_into("< {}\n", r.as_str());
            want = r;
            replies += 1;
        } else if line.starts_with("< ") {
            if !record {
                assert_eq(line.slice(2, line.len()), want.as_str());
            }
        } else {
            out.push_str(line);
            out.push_str("\n");
        }
    }
    assert(replies >= 16, "the transcript holds its requests");
    if record {
        let f = stdio::fopen(path, "wb");
        assert(f != null, "the transcript opens");
        unsafe stdio::fwrite(out.as_str().ptr(), 1, out.len(), f);
        let _ = unsafe stdio::fclose(f);
    }
}
