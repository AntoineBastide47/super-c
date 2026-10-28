// Compiler API limits, measured on an otherwise idle machine; run from the repository root with
// `super-c bench --filter=api_`.
//
// `api_cancel` checks this repository through `api::session` and cancels the check from another thread at
// points across its stages (load, resolve, the type check, the borrow check); it prints how long each check
// ran after its cancel, and fails when one ran 50 ms or more, the cancellation limit of the API. A check that
// ends before its cancel has nothing to measure.
//
// `api_protocol_overhead` asks for the 10,001 references of one function natively and through the process
// protocol (`api::protocol`: the server's encoding of the binary batch and the client's decoding, no pipe),
// best of five each, and fails when the protocol costs more than 20% over the native call.
import api::session as *;
import api::protocol as pr;
import api::semantic as sem;
import api::source as *;
import lsp::json as json;
import std::parallel::task as ptask;
import std::parallel::thread;
import std::platform::clock;
import std::testing::bench;

// The limit, in nanoseconds.
const CANCEL_LIMIT_NS: u64 = 50000000;

// One check per cancel point; false when a check runs past the limit after its cancel or fails otherwise.
fn cancel_points() bool {
    let mut worst: u64 = 0;
    for delay_ms in [20u64, 150, 400, 900, 1600, 2400] {
        let mut s = switch Session::open_project(".", Config::host("std")) {
            Ok(s) => s,
            Err(e) => {
                eprintln("api_cancel: {}", e.message.as_str());
                return false;
            },
        };
        let (src, tok) = ptask::CancelSource::new();
        let canceller = thread::spawn(
            move (|| {
                clock::sleep_ns(delay_ms * 1000000);
                let at = clock::monotonic_ns();
                src.cancel(1);
                return at;
            }),
        );
        let r = s.check_with(
            &RequestOptions { cancel: Option::<ptask::CancelToken>::Some(tok), deadline_ns: 0, result_limit: 0 },
        );
        let done = clock::monotonic_ns();
        let at = canceller.join();
        if r.is_ok() {
            println("  cancel at {} ms: the check ended first", delay_ms);
            continue;
        }
        if r.unwrap_err().code != Code::Cancelled {
            eprintln("api_cancel: the check failed without a cancel");
            return false;
        }
        let late = if done > at {
            done - at;
        } else {
            0;
        };
        println("  cancel at {} ms: stopped after {} us", delay_ms, late / 1000);
        worst = worst.max(late);
    }
    println("  worst: {} us (limit {} us)", worst / 1000, CANCEL_LIMIT_NS / 1000);
    return worst < CANCEL_LIMIT_NS;
}

/// Benchmark lane: the cancellation latency of a check of this repository (see the file comment).
@bench(log_results = false)
pub fn api_cancel(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    b.set_diag_rounds(0);
    while b.running() {
        if !cancel_points() {
            bench::fail("api_cancel");
        }
    }
}

const APP: str = "/virtual/app/main.spc";

// The little-endian u32 at byte `o` of `p`.
fn get_u32(p: &Vector<u8>, o: usize) u32 {
    let b = p.as_ptr();
    return (unsafe b[o]) as u32 | (unsafe b[o + 1]) as u32 << 8 | (unsafe b[o + 2]) as u32 << 16 | (unsafe b[o + 3]) as u32 << 24;
}

// The item count of `locations.1` batch `p` that reply `r` announces, decoded as a client does; 0 when its
// checksum or size is wrong.
fn decode(r: &String, p: &Vector<u8>) usize {
    let v = json::parse(r.as_str()).unwrap();
    let b = v.at_key("result").at_key("batch");
    if b.value_i64("bytes", -1) != p.len() as i64 {
        return 0;
    }
    let n = p.len() / 12;
    let mut out = Vector::<(u32, u32, u32)>::with_capacity(n);
    let mut sum: u32 = 0;
    for i in 0..n {
        let t = (get_u32(p, 12 * i), get_u32(p, 12 * i + 4), get_u32(p, 12 * i + 8));
        sum = sum.wrapping_add(t.0).wrapping_add(t.1).wrapping_add(t.2);
        out.push(t);
    }
    return pick(sum as i64 == b.value_i64("checksum", -1), out.len(), 0);
}

// The native and protocol costs of the reference list; false when they disagree or the protocol costs more
// than 20% over the native call.
fn overhead() bool {
    let mut src = String::from_str("fn one() i32 {\n    return 1;\n}\n\nfn main() i32 {\n    let mut n = 0;\n");
    for _ in 0..10000 {
        src.push_str("    n += one();\n");
    }
    src.push_str("    return n - 10000;\n}\n");
    let none = RequestOptions::none();
    let mut sv = pr::Server::new(
        pr::Launch {
            std_dir: String::from_str("std"),
            grantable: pr::CAP_ALL,
            roots: Vector::<String>::new(),
            max_frame: 1 << 20,
            max_workspaces: 1,
        },
    );
    let mut files = String::new();
    json::dump_escaped(src.as_str(), &mut files);
    let mut msgs = Vector::<String>::with_capacity(3);
    msgs.push(
        String::from_str(
            "{\"id\":1,\"method\":\"hello\",\"params\":{\"protocol_versions\":[1],\"required\":[\"session\",\"navigation\"]}}",
        ),
    );
    msgs.push(
        format(
            "{{\"id\":2,\"method\":\"open_workspace\",\"params\":{{\"kind\":\"file\",\"path\":\"{}\",\"files\":{{\"{}\":{}}}}}}}",
            APP,
            APP,
            files.as_str(),
        ),
    );
    msgs.push(String::from_str("{\"id\":3,\"method\":\"commit\",\"params\":{\"workspace\":1}}"));
    let mut rev: i64 = -1;
    for i in 0..msgs.len() {
        let r = json::parse(sv.handle(msgs[i].as_str(), &none).as_str()).unwrap();
        if !r.contains_key("result") {
            eprintln("api_protocol_overhead: request {} failed", i + 1);
            return false;
        }
        rev = r.at_key("result").value_i64("revision", rev);
    }
    let mut mem = MemoryFiles::over_disk();
    mem.set(APP, src.as_str());
    let mut s = Session::open_file(APP, Config::with_files("std", Box::new(mem))).unwrap();
    s.check().unwrap();
    let at = src.as_str().find("one()") as u32;
    let text = format(
        "{{\"id\":4,\"method\":\"query\",\"params\":{{\"workspace\":1,\"revision\":{},\"capability\":\"navigation\",\"method\":\"references\",\"arguments\":{{\"file\":\"{}\",\"offset\":{},\"include_declaration\":true}},\"binary\":true}}}}",
        rev,
        APP,
        at,
    );
    let mut native_ns: u64 = 0xFFFFFFFFFFFFFFFF;
    let mut proto_ns: u64 = 0xFFFFFFFFFFFFFFFF;
    for _ in 0..5 {
        let t0 = clock::monotonic_ns();
        let ls = sem::references_at(&mut s, APP, at, true, &none).unwrap();
        let t1 = clock::monotonic_ns();
        let r = sv.handle(text.as_str(), &none);
        let p = sv.take_payload();
        let got = decode(&r, &p);
        let t2 = clock::monotonic_ns();
        if got != ls.len() || got != 10001 {
            eprintln("api_protocol_overhead: the batch holds {} of {} references", got, ls.len());
            return false;
        }
        native_ns = native_ns.min(t1 - t0);
        proto_ns = proto_ns.min(t2 - t1);
    }
    println(
        "  references of 10001: native {} us, protocol {} us (limit {} us)",
        native_ns / 1000,
        proto_ns / 1000,
        native_ns * 12 / 10000,
    );
    return proto_ns * 100 <= native_ns * 120;
}

/// Benchmark lane: the protocol's cost over the native call for a large reference list (see the file comment).
@bench(log_results = false)
pub fn api_protocol_overhead(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    b.set_diag_rounds(0);
    while b.running() {
        if !overhead() {
            bench::fail("api_protocol_overhead");
        }
    }
}
