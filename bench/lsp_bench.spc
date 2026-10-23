// Language-server latency, work and memory with this repository as the workspace: the measured client of
// the compiler API decision. `lsp_session` runs the server's own entry (`lsp::server::run`, what
// `super-c lsp` calls) in-process on the calling thread, with pipes as its stdin and stdout; a driver
// thread writes a scripted session and reads the replies. A step's window runs from the write of its first
// message to the reply that ends it: framing, JSON, dispatch, analysis and the borrow round. The driver
// allocates nothing inside a window, so the process-wide cycle and allocation counters are the server's.
//
// An update ends at an idle probe, a request with `"jsonrpc":"1.0"`: the server answers it with an error
// once it has handled everything before it, and the probe does not stop a borrow round (only an edit or a
// 2.0 request does), so it ends the window without changing the work.
//
// `lsp_reuse` builds the manifest root as the server does (`analysis::compile`), applies the same edits
// through `analysis::recompile`, and prints the modules each edit analyzes again and the bytes the package
// retains, by kind.
//
// POSIX only: the session moves the pipes onto descriptors 0 and 1. Run from the repository root with
// `super-c bench --filter=lsp_`.
import stdio;
import std::platform::fs;
import std::platform::process;
import std::platform::env as penv;
import std::parallel::thread;
import std::parallel::platform as platform;
import std::testing::bench;
import std::testing::bench_sys as sys;
import lsp::server as server;
import lsp::analysis as an;
import module::loader as loader;
import driver_shim as shim;
@platform(macos | ios | linux | android)
import unistd;

// The edited document, and the edits: a statement with a type error at the top of the `str_id` body (a
// body-only edit), and the `str_id` return type (a signature edit; four other modules call it).
const DOC: str = "src/driver/util.spc";
const SIG_AT: str = "pub fn str_id(s: str) u64 {";
const BODY_LINE: str = "    let sc_probe: i32 = true;\n";
const QUERY_ROUNDS: usize = 20;
const EDIT_ROUNDS: usize = 10;
const BUF_CAP: usize = 16777216; // reply bytes the driver holds; a larger reply fails the run
const MAX_REPLIES: usize = 1000000; // replies one window may read
const PUBLISH: str = "\"method\":\"textDocument/publishDiagnostics\"";

const S_COLD: usize = 0;
const S_OPEN: usize = 1;
const S_DEF: usize = 2;
const S_HOVER: usize = 3;
const S_REFS: usize = 4;
const S_COMPL: usize = 5;
const S_RENAME: usize = 6;
const S_DIAG: usize = 7;
const S_BODY: usize = 8;
const S_BODY_REV: usize = 9;
const S_SIG: usize = 10;
const S_SIG_REV: usize = 11;
const S_HOVER_BODY: usize = 12;
const S_HOVER_SIG: usize = 13;
const S_N: usize = 14;
const STEPS: [str<'static>; 14] = [
    "initialize to idle",
    "didOpen to idle",
    "definition",
    "hover",
    "references",
    "completion",
    "rename",
    "pull diagnostics",
    "body edit to idle",
    "body revert to idle",
    "signature edit to idle",
    "signature revert to idle",
    "hover after body edit",
    "hover after signature edit",
];

const REUSE_STEPS: [str<'static>; 5] = ["didOpen", "body edit", "body revert", "signature edit", "signature revert"];

// One step's figures. `pub_ns` is 0 when no publishDiagnostics arrived inside the window.
struct Sample {
    pub ns: u64,
    pub pub_ns: u64,
    pub cyc: i64,
    pub calls: i64,
    pub bytes: i64,
}

unsafe extend Sample as Send {}

// A text edit: `cut` bytes at `at` replaced by `put`.
struct Edit {
    pub at: usize,
    pub cut: usize,
    pub put: str<'static>,
}

struct Drv {
    pub w: fs::File, // the server's stdin
    pub r: fs::File, // the server's stdout
    pub buf: Vector<u8>,
    pub lo: usize, // the unread reply bytes are buf[lo..hi]
    pub hi: usize,
    pub seq: u64, // the last request id
    pub ver: i64, // the document version
    pub uri: String,
    pub out: Vector<Vector<Sample>>, // per step
}

const fn bytes_of(s: str) []u8 {
    return unsafe Slice::<u8> { ptr: s.ptr(), len: s.len() };
}

// `text` with `e` applied.
fn spliced(text: str, e: &Edit) String {
    let mut s = String::from_str(text.slice(0, e.at));
    s.push_str(e.put);
    s.push_str(text.slice(e.at + e.cut, text.len()));
    return s;
}

// The LSP position of byte `at`: line and UTF-16 column. False when the line holds a non-ASCII byte
// before `at` (the column would need a UTF-16 count).
fn position(text: str, at: usize, out: &mut String) bool {
    let mut line: usize = 0;
    let mut start: usize = 0;
    for k in 0..at {
        if text.byte_at(k) == b'\n' {
            line += 1;
            start = k + 1;
        }
    }
    for k in start..at {
        if text.byte_at(k) >= 0x80 {
            return false;
        }
    }
    out.push_str("{\"line\":");
    out.push_u64(line as u64);
    out.push_str(",\"character\":");
    out.push_u64((at - start) as u64);
    out.push_byte(b'}');
    return true;
}

// Byte offset of `needle` plus `delta` in `text`, or -1.
const fn offset(text: str, needle: str, delta: usize) isize {
    let k = text.find(needle);
    if k < 0 {
        return -1;
    }
    return k + delta as isize;
}

fn frame(body: &String) String {
    let mut s = String::from_str("Content-Length: ");
    s.push_u64(body.len() as u64);
    s.push_str("\r\n\r\n");
    s.push_str(body.as_str());
    return s;
}

fn notification(method: str, params: str) String {
    let mut b = String::from_str("{\"jsonrpc\":\"2.0\",\"method\":\"");
    b.push_str(method);
    b.push_str("\",\"params\":");
    b.push_str(params);
    b.push_byte(b'}');
    return frame(&b);
}

// A framed request with the next id under protocol version `rpc`; `idk` gets the id's key text.
fn request(d: &mut Drv, rpc: str, method: str, params: str, idk: &mut String) String {
    d.seq += 1;
    idk.clear();
    idk.push_str("\"id\":\"q");
    idk.push_u64(d.seq);
    idk.push_byte(b'"');
    let mut b = String::from_str("{\"jsonrpc\":\"");
    b.push_str(rpc);
    b.push_str("\",");
    b.push_str(idk.as_str());
    b.push_str(",\"method\":\"");
    b.push_str(method);
    b.push_str("\",\"params\":");
    b.push_str(params);
    b.push_byte(b'}');
    return frame(&b);
}

// `{"textDocument":{"uri":...}` without its closing brace.
fn doc_params(d: &Drv) String {
    let mut p = String::from_str("{\"textDocument\":{\"uri\":\"");
    p.push_str(d.uri.as_str());
    p.push_str("\"}");
    return p;
}

// A positional request at byte `at` of `text`; empty when the position cannot be expressed.
fn at_request(d: &mut Drv, method: str, text: str, at: usize, extra: str, idk: &mut String) String {
    let mut p = doc_params(d);
    p.push_str(",\"position\":");
    if !position(text, at, &mut p) {
        return String::new();
    }
    p.push_str(extra);
    p.push_byte(b'}');
    return request(d, "2.0", method, p.as_str(), idk);
}

// A didChange notification applying `e` to `text` (the document before the edit).
fn change(d: &mut Drv, text: str, e: &Edit) String {
    d.ver += 1;
    let mut p = String::from_str("{\"textDocument\":{\"uri\":\"");
    p.push_str(d.uri.as_str());
    p.push_str("\",\"version\":");
    p.push_i64(d.ver);
    p.push_str("},\"contentChanges\":[{\"range\":{\"start\":");
    let ok = position(text, e.at, &mut p);
    p.push_str(",\"end\":");
    let ok2 = position(text, e.at + e.cut, &mut p);
    p.push_str("},\"text\":");
    p.push_str(json_str(e.put).as_str());
    p.push_str("}]}");
    if !ok || !ok2 {
        return String::new();
    }
    return notification("textDocument/didChange", p.as_str());
}

const HEX: str = "0123456789abcdef";

// `s` as a JSON string literal.
fn json_str(s: str) String {
    let mut j = String::new();
    j.push_byte(b'"');
    for k in 0..s.len() {
        let c = s.byte_at(k);
        if c == b'"' || c == b'\\' {
            j.push_byte(b'\\');
            j.push_byte(c);
        } else if c == b'\n' {
            j.push_str("\\n");
        } else if c == b'\t' {
            j.push_str("\\t");
        } else if c == b'\r' {
            j.push_str("\\r");
        } else if c < 32 {
            j.push_str("\\u00");
            j.push_byte(HEX.byte_at((c >> 4) as usize));
            j.push_byte(HEX.byte_at((c & 15) as usize));
        } else {
            j.push_byte(c);
        }
    }
    j.push_byte(b'"');
    return j;
}

// The next reply's body as `buf[*s..*s + *n]`, reading as needed. False at the end of the stream, on a
// framing error, or on a reply larger than BUF_CAP.
fn next_body(d: &mut Drv, s: &mut usize, n: &mut usize) bool {
    for _ in 0..BUF_CAP {
        let v = unsafe str::from_raw(d.buf.as_ptr() + d.lo, d.hi - d.lo);
        let he = v.find("\r\n\r\n");
        if he >= 0 {
            let cl = v.find("Content-Length: ");
            if cl < 0 || cl > he {
                return false;
            }
            let mut len: usize = 0;
            for k in cl as usize + 16..he as usize {
                let c = v.byte_at(k);
                if c < b'0' || c > b'9' {
                    break;
                }
                len = len * 10 + (c - b'0') as usize;
            }
            let start = d.lo + he as usize + 4;
            if start + len <= d.hi {
                *s = start;
                *n = len;
                d.lo = start + len;
                return true;
            }
        }
        if d.hi == BUF_CAP {
            if d.lo == 0 {
                return false;
            }
            for k in d.lo..d.hi {
                d.buf.set(k - d.lo, d.buf[k]);
            }
            d.hi -= d.lo;
            d.lo = 0;
        }
        let got = d.r.read(d.buf.index_range_mut(d.hi..BUF_CAP));
        if got.is_err() {
            return false;
        }
        let k = got.unwrap();
        if k == 0 {
            return false;
        }
        d.hi += k;
    }
    return false;
}

// Read replies up to the one holding `idk`, noting the first publish in `sm`.
fn await_reply(d: &mut Drv, idk: &String, t0: u64, sm: &mut Sample) bool {
    let mut s: usize = 0;
    let mut n: usize = 0;
    for _ in 0..MAX_REPLIES {
        if !next_body(d, &mut s, &mut n) {
            return false;
        }
        let body = unsafe str::from_raw(d.buf.as_ptr() + s, n);
        if sm.pub_ns == 0 && body.find(PUBLISH) >= 0 {
            sm.pub_ns = platform::now_ns() - t0;
        }
        if body.find(idk.as_str()) >= 0 {
            return true;
        }
    }
    return false;
}

const fn sample_new() Sample {
    return Sample { ns: 0, pub_ns: 0, cyc: 0, calls: 0, bytes: 0 };
}

// One step: write `msgs`, read to the reply holding `idk`, and keep the figures under step `k` (or
// nowhere when `k` is S_N).
fn step(d: &mut Drv, k: usize, msgs: &String, idk: &String) bool {
    if msgs.len() == 0 {
        return false;
    }
    let mut sm = sample_new();
    let c0 = unsafe sys::sc_bs_cycles();
    let a0 = unsafe sys::sc_bs_alloc_calls();
    let b0 = unsafe sys::sc_bs_alloc_bytes();
    let t0 = platform::now_ns();
    if d.w.write_all(bytes_of(msgs.as_str())).is_err() {
        return false;
    }
    let ok = await_reply(d, idk, t0, &mut sm);
    sm.ns = platform::now_ns() - t0;
    sm.cyc = unsafe sys::sc_bs_cycles() - c0;
    sm.calls = unsafe sys::sc_bs_alloc_calls() - a0;
    sm.bytes = unsafe sys::sc_bs_alloc_bytes() - b0;
    if k < S_N {
        d.out[k].push(sm);
    }
    return ok;
}

// `msgs` then an idle probe, measured under step `k`.
fn update(d: &mut Drv, k: usize, msgs: String) bool {
    let mut idk = String::new();
    let mut all = msgs;
    if all.len() == 0 {
        return false;
    }
    all.push_str(request(d, "1.0", "probe", "null", &mut idk).as_str());
    return step(d, k, &all, &idk);
}

// The queried positions, as byte offsets into the document.
struct Spots {
    pub def: usize, // a cross-module method call
    pub hover: usize, // a std method call, before both edits
    pub name: usize, // the `str_id` declaration: references and rename
    pub compl: usize, // just after a member access dot
}

// The request of query step `k`.
fn query(d: &mut Drv, k: usize, t: str, sp: &Spots, idk: &mut String) String {
    if k == S_DEF {
        return at_request(d, "textDocument/definition", t, sp.def, "", idk);
    }
    if k == S_HOVER {
        return at_request(d, "textDocument/hover", t, sp.hover, "", idk);
    }
    if k == S_REFS {
        return at_request(d, "textDocument/references", t, sp.name, ",\"context\":{\"includeDeclaration\":true}", idk);
    }
    if k == S_COMPL {
        return at_request(d, "textDocument/completion", t, sp.compl, "", idk);
    }
    if k == S_RENAME {
        return at_request(d, "textDocument/rename", t, sp.name, ",\"newName\":\"str_id_renamed\"", idk);
    }
    let mut p = doc_params(d);
    p.push_byte(b'}');
    return request(d, "2.0", "textDocument/diagnostic", p.as_str(), idk);
}

// The scripted session. False when a reply did not arrive or a position could not be expressed.
fn drive(d: &mut Drv, root: &String, text: &String) bool {
    let t = text.as_str();
    let sig = offset(t, SIG_AT, 0);
    let body_at = offset(t, SIG_AT, SIG_AT.len() + 1);
    let def_at = offset(t, "lex::Lexer::new(&mut vsrc", 12);
    let hover_at = offset(t, "s.byte_at(k) as u64", 2);
    let compl_at = offset(t, "lx.keep_trivia", 3);
    if sig < 0 || body_at < 0 || def_at < 0 || hover_at < 0 || compl_at < 0 || hover_at > sig {
        eprintln("lsp bench: {} no longer holds the edited and queried text", DOC);
        return false;
    }
    let body = Edit { at: body_at as usize, cut: 0, put: BODY_LINE };
    let body_rev = Edit { at: body_at as usize, cut: BODY_LINE.len(), put: "" };
    let sig_e = Edit { at: sig as usize + 22, cut: 3, put: "u32" };
    let sig_rev = Edit { at: sig as usize + 22, cut: 3, put: "u64" };
    let t_body = spliced(t, &body);
    let t_sig = spliced(t, &sig_e);

    let mut idk = String::new();
    let mut init = String::from_str("{\"processId\":null,\"rootUri\":\"file://");
    init.push_str(root.as_str());
    init.push_str("\",\"capabilities\":{}}");
    let mut msgs = request(d, "2.0", "initialize", init.as_str(), &mut idk);
    msgs.push_str(notification("initialized", "{}").as_str());
    if !update(d, S_COLD, msgs) {
        return false;
    }
    let mut open = String::from_str("{\"textDocument\":{\"uri\":\"");
    open.push_str(d.uri.as_str());
    open.push_str("\",\"languageId\":\"super-c\",\"version\":0,\"text\":");
    open.push_str(json_str(t).as_str());
    open.push_str("}}");
    if !update(d, S_OPEN, notification("textDocument/didOpen", open.as_str())) {
        return false;
    }

    let spots = Spots {
        def: def_at as usize,
        hover: hover_at as usize,
        name: sig as usize + 7,
        compl: compl_at as usize,
    };
    for _ in 0..QUERY_ROUNDS {
        for k in S_DEF..S_DIAG + 1 {
            let q = query(d, k, t, &spots, &mut idk);
            if !step(d, k, &q, &idk) {
                return false;
            }
        }
    }

    let mut m = String::new();
    for _ in 0..EDIT_ROUNDS {
        let ok = update(d, S_BODY, change(d, t, &body)) && update(d, S_BODY_REV, change(d, t_body.as_str(), &body_rev)) && update(
            d,
            S_SIG,
            change(d, t, &sig_e),
        ) && update(d, S_SIG_REV, change(d, t_sig.as_str(), &sig_rev));
        if !ok {
            return false;
        }
        // A hover sent right behind an edit waits for the edit's analysis; the revert after it is not measured.
        m = change(d, t, &body);
        m.push_str(at_request(d, "textDocument/hover", t, hover_at as usize, "", &mut idk).as_str());
        if !step(d, S_HOVER_BODY, &m, &idk) || !update(d, S_N, change(d, t_body.as_str(), &body_rev)) {
            return false;
        }
        m = change(d, t, &sig_e);
        m.push_str(at_request(d, "textDocument/hover", t, hover_at as usize, "", &mut idk).as_str());
        if !step(d, S_HOVER_SIG, &m, &idk) || !update(d, S_N, change(d, t_sig.as_str(), &sig_rev)) {
            return false;
        }
    }
    let q = request(d, "2.0", "shutdown", "null", &mut idk);
    if !step(d, S_N, &q, &idk) {
        return false;
    }
    return d.w.write_all(bytes_of(notification("exit", "null").as_str())).is_ok();
}

fn median(v: &mut Vector<f64>) f64 {
    if v.len() == 0 {
        return -1.0;
    }
    return bench::summarize(v).median;
}

// Per step: samples, median and largest wall time, median time to the first publish, and the median
// cycles, allocation calls and bytes allocated. -1 = none (no publish, or no cycle counter).
fn report(out: &Vector<Vector<Sample>>) {
    unsafe stdio::printf(
        "\n  %-28s %3s %10s %10s %10s %9s %9s %9s\n".ptr() as *const char,
        "step".ptr() as *const char,
        "n".ptr() as *const char,
        "median ms".ptr() as *const char,
        "max ms".ptr() as *const char,
        "publish ms".ptr() as *const char,
        "Mcycles".ptr() as *const char,
        "k allocs".ptr() as *const char,
        "MiB alloc".ptr() as *const char,
    );
    let cyc_ok = unsafe sys::sc_bs_cycles_scope() != 0;
    for k in 0..S_N {
        let v = &out[k];
        let mut ns = Vector::<f64>::new();
        let mut pubs = Vector::<f64>::new();
        let mut cyc = Vector::<f64>::new();
        let mut calls = Vector::<f64>::new();
        let mut bytes = Vector::<f64>::new();
        let mut max: f64 = 0.0;
        for i in 0..v.len() {
            let sm = v.at(i);
            let ms = sm.ns as f64 / 1e6;
            ns.push(ms);
            max = max.max(ms);
            if sm.pub_ns != 0 {
                pubs.push(sm.pub_ns as f64 / 1e6);
            }
            if cyc_ok {
                cyc.push(sm.cyc as f64 / 1e6);
            }
            calls.push(sm.calls as f64 / 1e3);
            bytes.push(sm.bytes as f64 / 1048576.0);
        }
        unsafe stdio::printf(
            "  %-28s %3zu %10.2f %10.2f %10.2f %9.1f %9.1f %9.2f\n".ptr() as *const char,
            (unsafe STEPS[k].ptr()) as *const char,
            v.len(),
            median(&mut ns),
            max,
            median(&mut pubs),
            median(&mut cyc),
            median(&mut calls),
            median(&mut bytes),
        );
    }
}

fn mib(n: i64) f64 {
    return n as f64 / 1048576.0;
}

// Move `r` onto descriptor 0 and `w` onto 1, the server's stdin and stdout; `saved` keeps the old ones.
@platform(macos | ios | linux | android)
fn redirect(r: &fs::File, w: &fs::File, saved: &mut [i32; 2]) bool {
    unsafe stdio::fflush(stdio::stdout());
    saved[0] = unsafe unistd::dup(0);
    saved[1] = unsafe unistd::dup(1);
    return saved[0] >= 0 && saved[1] >= 0 && unsafe unistd::dup2(r.raw(), 0) >= 0 && unsafe unistd::dup2(w.raw(), 1) >= 0;
}

// Unsupported: the session needs descriptor redirection.
@platform(windows | wasm)
fn redirect(_r: &fs::File, _w: &fs::File, _saved: &mut [i32; 2]) bool {
    return false;
}

// Put the descriptors `redirect` saved back.
@platform(macos | ios | linux | android)
fn restore(saved: &[i32; 2]) {
    unsafe stdio::fflush(stdio::stdout());
    unsafe unistd::dup2(saved[0], 0);
    unsafe unistd::dup2(saved[1], 1);
    unsafe unistd::close(saved[0]);
    unsafe unistd::close(saved[1]);
}

@platform(windows | wasm)
fn restore(_saved: &[i32; 2]) {}

// The session: the pipes move onto descriptors 0 and 1, the driver thread runs the script, and this
// thread runs the server until `exit`; then the descriptors come back.
fn session() bool {
    let root = process::current_dir().unwrap_or(String::new());
    let to = loader::read_file(DOC);
    if root.len() == 0 || to.is_none() {
        eprintln("lsp bench: cannot read {} (run from the repository root)", DOC);
        return false;
    }
    let text = to.unwrap();
    let mut uri = String::from_str("file://");
    uri.push_str(root.as_str());
    uri.push_byte(b'/');
    uri.push_str(DOC);
    let mut std_dir = root.clone();
    std_dir.push_str("/std");
    let pa = process::pipe();
    let pb = process::pipe();
    let mut saved: [i32; 2] = [-1, -1];
    if pa.is_err() || pb.is_err() {
        eprintln("lsp bench: this target has no pipes");
        return false;
    }
    let (ar, aw) = pa.unwrap();
    let (br, bw) = pb.unwrap();
    if !redirect(&ar, &bw, &mut saved) {
        eprintln("lsp bench: cannot move the pipes onto the standard descriptors (POSIX only)");
        return false;
    }
    let _ = ar.close();
    let _ = bw.close();
    // As integers: a Windows handle is a pointer, which no closure may carry to a thread.
    let wfd = aw.into_raw() as usize;
    let rfd = br.into_raw() as usize;
    let h = thread::spawn(
        fn() Vector<Vector<Sample>> {
            let mut d = Drv {
                w: unsafe fs::File::from_raw(wfd as fs::RawHandle),
                r: unsafe fs::File::from_raw(rfd as fs::RawHandle),
                buf: Vector::<u8>::new(),
                lo: 0,
                hi: 0,
                seq: 0,
                ver: 0,
                uri: uri.clone(),
                out: Vector::<Vector<Sample>>::new(),
            };
            d.buf.resize_default(BUF_CAP);
            for _ in 0..S_N {
                d.out.push(Vector::<Sample>::with_capacity(QUERY_ROUNDS.max(EDIT_ROUNDS)));
            }
            if !drive(&mut d, &root, &text) {
                d.out.clear();
            }
            return replace(&mut d.out, Vector::<Vector<Sample>>::new());
        },
    );
    let rc = server::run(std_dir.as_str(), unsafe shim::sc_host_platform());
    restore(&saved);
    let out = h.join();
    if rc != 0 || out.len() != S_N {
        eprintln("lsp bench: the session failed (server exit {})", rc);
        return false;
    }
    unsafe stdio::printf(
        "\nsuper-c lsp on this repository, %s open; %zu query rounds, %zu edit rounds\n".ptr() as *const char,
        DOC.ptr() as *const char,
        QUERY_ROUNDS,
        EDIT_ROUNDS,
    );
    report(&out);
    unsafe stdio::printf(
        "\n  resident: peak %.1f MiB, end %.1f MiB (process: server, driver and %.0f MiB reply buffer)\n".ptr() as *const char,
        mib(unsafe sys::sc_bs_rss_peak()),
        mib(unsafe sys::sc_bs_rss_now()),
        mib(BUF_CAP as i64),
    );
    return true;
}

/// Benchmark lane: one scripted language-server session over this repository (see the file comment).
@bench(log_results = false)
pub fn lsp_session(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    b.set_diag_rounds(0);
    unsafe sys::sc_bs_alloc_enable(1);
    // The server's own line per analysis: modules, released bodies and retained bytes per root.
    let _ = unsafe penv::set("SC_LSP_STATS", "1");
    while b.running() {
        if !session() {
            bench::fail("lsp_session");
        }
    }
}

const fn never_stop(_ctx: *mut void, _between: bool) bool {
    return false;
}

// The server's borrow round after an analysis, run to its end.
fn settle(p: &mut loader::Package, ovf: &Vector<str>, diags: &mut Vector<an::DiagRec>) {
    let _ = an::borrowck_pending(p, diags, ovf, never_stop, null);
}

// The bytes `p` retains, by kind: sources, declaration syntax (the module arenas), bodies (the body
// arenas with their per-node tables), the declarations' per-node semantic tables, the package type table,
// and the indexes (item schedule, reference edges, reachability scans, recursion summaries).
fn print_retained(p: &loader::Package, when: str) {
    let mut src: usize = 0;
    let mut decl: usize = 0;
    let mut body: usize = 0;
    let mut tables: usize = 0;
    for i in 0..p.modules.len() {
        let m = p.modules.at(i);
        let a = &m.ast;
        let d = a.nodes.retained() + a.children.retained();
        let bb = a.b.retained();
        src += m.source.capacity();
        decl += d;
        body += bb;
        tables += a.retained_bytes() - d - bb;
    }
    let types = p.tt.retained();
    let index = p.retained_bytes() - src - decl - body - tables + p.sched.retained();
    unsafe stdio::printf(
        "  retained MiB %s: sources %.1f, declaration syntax %.1f, bodies %.1f, declaration tables %.1f, types %.1f, indexes %.1f, old generations 0 (total %.1f)\n".ptr() as *const char,
        when.ptr() as *const char,
        mib(src as i64),
        mib(decl as i64),
        mib(body as i64),
        mib(tables as i64),
        mib(types as i64),
        mib(index as i64),
        mib((src + decl + body + tables + types + index) as i64),
    );
}

fn reuse() bool {
    let root = process::current_dir().unwrap_or(String::new());
    let to = loader::read_file(DOC);
    if root.len() == 0 || to.is_none() {
        eprintln("lsp bench: cannot read {} (run from the repository root)", DOC);
        return false;
    }
    let text = to.unwrap();
    let t = text.as_str();
    let sig = offset(t, SIG_AT, 0);
    if sig < 0 {
        eprintln("lsp bench: {} no longer holds the edited text", DOC);
        return false;
    }
    let body = Edit { at: sig as usize + SIG_AT.len() + 1, cut: 0, put: BODY_LINE };
    let sig_e = Edit { at: sig as usize + 22, cut: 3, put: "u32" };
    let mut root_file = root.clone();
    root_file.push_str("/src/main.spc");
    let mut root_dir = root.clone();
    root_dir.push_str("/src");
    let mut std_dir = root.clone();
    std_dir.push_str("/std");
    let mut abs = root.clone();
    abs.push_byte(b'/');
    abs.push_str(DOC);
    let doc = an::canon_path(abs.as_str());
    let target = unsafe shim::sc_host_platform();
    let mut diags = Vector::<an::DiagRec>::new();
    let t0 = platform::now_ns();
    let mut p = an::compile(
        root_file.as_str(),
        root_dir.as_str(),
        "",
        std_dir.as_str(),
        target,
        Vector::<String>::new(),
        Vector::<String>::new(),
        root.as_str(),
        &mut diags,
    );
    let none = Vector::<str>::new();
    settle(&mut p, &none, &mut diags);
    unsafe stdio::printf(
        "\nmanifest root src/main.spc as the server builds it: %zu modules, %.0f ms with its borrow round\n".ptr() as *const char,
        p.modules.len(),
        (platform::now_ns() - t0) as f64 / 1e6,
    );
    print_retained(&p, "after the build");
    let mut texts = Vector::<String>::new();
    texts.push(text.clone());
    texts.push(spliced(t, &body));
    texts.push(text.clone());
    texts.push(spliced(t, &sig_e));
    texts.push(text.clone());
    unsafe stdio::printf(
        "\n  %-17s %8s %9s %9s %6s %11s %7s %9s\n".ptr() as *const char,
        "recompile".ptr() as *const char,
        "reparsed".ptr() as *const char,
        "body-only".ptr() as *const char,
        "analyzed".ptr() as *const char,
        "kept".ptr() as *const char,
        "bodies back".ptr() as *const char,
        "passes".ptr() as *const char,
        "ms".ptr() as *const char,
    );
    for k in 0..texts.len() {
        let mut ovf = Vector::<str>::new();
        let mut ovt = Vector::<str>::new();
        ovf.push(doc.as_str());
        ovt.push(texts[k].as_str());
        let mut st = an::RecompileStats {};
        let t1 = platform::now_ns();
        if !an::recompile(&mut p, target, root_file.as_str(), root.as_str(), &ovf, &ovt, &mut diags, &mut st) {
            eprintln("lsp bench: {} left the incremental path", unsafe REUSE_STEPS[k]);
            return false;
        }
        settle(&mut p, &ovf, &mut diags);
        unsafe stdio::printf(
            "  %-17s %8u %9u %5u/%-3zu %6u %11u %7u %9.1f\n".ptr() as *const char,
            (unsafe REUSE_STEPS[k].ptr()) as *const char,
            st.reparsed,
            st.body_only,
            st.analyzed,
            p.modules.len(),
            st.kept,
            st.bodies_back,
            st.passes,
            (platform::now_ns() - t1) as f64 / 1e6,
        );
    }
    print_retained(&p, "after the edits");
    return true;
}

/// Benchmark lane: the modules each session edit analyzes again, and the bytes the manifest root retains.
@bench(log_results = false)
pub fn lsp_reuse(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    b.set_diag_rounds(0);
    while b.running() {
        if !reuse() {
            bench::fail("lsp_reuse");
        }
    }
}
