// `super-c lsp`: a Language Server Protocol server over stdio. Single-threaded and synchronous.
// Document edits update built roots incrementally (analysis::recompile re-analyzes only the edit's
// import-closure reach); every open/close/config change and any edit outside that domain falls back
// to the full codegen-free recompile. SC_LSP_NO_INCR=1 forces the full path everywhere (parity mode);
// SC_LSP_BUDGET_MB bounds retained packages (closed-file roots evict first, open docs pin theirs).
// The process chdir()s to the workspace root at initialize, so manifest discovery, import rooting and
// the src/ alt-root convention behave exactly like CLI runs from the project root.
import stdio;
import stdlib;
import driver_shim as shim;
import lexer::lexer as lex;
import lexer::token_type as ltt;
import module::loader as loader;
import build_system::manifest as bman;
import lsp::json as json;
import lsp::transport as transport;
import lsp::text as text;
import lsp::analysis as analysis;
import lsp::features as feat;
import driver::util as dutil;
import lsp::buildtoml as btoml;
import ast::ast as astn;

/// An open editor document (the overlay source of truth while open).
pub struct Doc {
    pub uri: String,
    pub path: String, // canonical (realpath'd when possible) filesystem path
    pub txt: String,
    pub version: i64,
}

extend Doc as Free {
    pub fn free(self: &mut Self) {
        self.uri.free();
        self.path.free();
        self.txt.free();
    }
}

/// One compiled unit: the manifest root (build.toml's entry), a per-file root for an open doc outside
/// the manifest closure, or the workspace-batch root (sweep=true, origin ""): one shared package for
/// every closed .spc no other package owns, the `super-c lint` one-package recipe. Per-file sweep
/// roots are rejected: their prelude and closure copies held ~1 GB on this repo.
pub struct Root {
    pub ws: String, // canonical workspace folder that owns this root ("" for a per-file root)
    pub root_file: String,
    pub root_dir: String,
    pub alt_dir: String,
    pub origin: String, // "" for the manifest/batch roots; the file path that spawned a per-file root
    pub sweep: bool, // the workspace-batch root: rebuilt when its member set changes, else cached
    pub members: Vector<String>, // batch only: the swept files (relative paths) it lints
    pub pkg: loader::Package,
    pub files: Vector<String>, // canonical module file paths, index-aligned with pkg.modules
    pub diags: Vector<analysis::DiagRec>, // last build's records (codeAction reads the fixes)
    pub built: bool,
    pub last_used: u64, // server tick of the last build or input touching this root (LRU eviction order)
}

extend Root as Free {
    pub fn free(self: &mut Self) {
        self.ws.free();
        self.root_file.free();
        self.root_dir.free();
        self.alt_dir.free();
        self.origin.free();
        self.members.free();
        self.pkg.free();
        self.files.free();
        self.diags.free();
    }
}

/// Whole-process server state: open documents, built roots, negotiated client capabilities and the
/// per-URI semantic-token history that delta requests diff against.
pub struct Server {
    pub docs: Vector<Doc>,
    pub roots: Vector<Root>, // roots[0] is the primary folder's manifest root when has_manifest
    pub has_manifest: bool,
    pub std_dir: String,
    pub target: i32,
    pub published: Vector<String>, // URIs whose last publish was non-empty (for clearing)
    pub ws_root: String, // canonical primary workspace folder ("" before initialize)
    pub folders: Vector<String>, // every canonical workspace folder (ws_root first)
    pub out_folders: Vector<String>, // canonical folder per out_skips entry
    pub out_skips: Vector<String>, // that folder's manifest out-dir name (its sweep skips it)
    pub canceled_tick: Vector<u64>, // sv.tick when each canceled id arrived (staleness purge)
    pub last_req_tick: u64, // tick of the most recently handled request
    pub shutdown_seen: bool,
    pub initialized: bool, // initialize accepted exactly once
    pub revision: u64, // bumps on every workspace input transaction (open/change/close/disk/config)
    pub canceled: Vector<String>, // dumped ids of $/cancelRequest notifications not yet consumed
    // Negotiated client capabilities, read once at initialize.
    pub cap_hier_symbols: bool, // hierarchical documentSymbol trees
    pub cap_doc_changes: bool, // versioned documentChanges workspace edits
    pub cap_pull_diags: bool, // textDocument/diagnostic pull requests
    pub cap_delta_tokens: bool, // semanticTokens/full/delta requests
    pub cap_action_literals: bool, // CodeAction literals (without it, codeAction returns nothing)
    pub cap_action_resolve: bool, // lazy codeAction/resolve for the `edit` property
    pub cap_watch_dynreg: bool, // dynamic didChangeWatchedFiles registration
    pub parent_pid: i64, // initialize.processId (0 = none); polled between messages
    pub max_results: usize, // per-request result cap (initializationOptions.maxResults)
    pub budget_mb: i64, // retained-package budget (initializationOptions.budgetMb; 0 = use SC_LSP_BUDGET_MB)
    pub tick: u64, // request counter driving least-recently-used eviction order
    pub tok_uris: Vector<String>, // per-URI semantic-token state for delta requests: URI ...
    pub tok_ids: Vector<u64>, // ... the resultId of the last full response ...
    pub tok_data: Vector<Vector<i64>>, // ... and its encoded token data
    pub tok_next: u64, // monotonically increasing semantic-token resultId source
}

extend Server as Free {
    pub fn free(self: &mut Self) {
        self.docs.free();
        self.roots.free();
        self.published.free();
        self.ws_root.free();
        self.folders.free();
        self.out_folders.free();
        self.out_skips.free();
        self.canceled_tick.free();
        self.std_dir.free();
        self.canceled.free();
        self.tok_uris.free();
        self.tok_ids.free();
        self.tok_data.free();
    }
}

fn dir_of(path: str) String {
    let mut i = path.len();
    while i > 0 {
        if path[i - 1] == b'/' {
            return String::from_str(path.slice(0, i - 1));
        }
        i -= 1;
    }
    return String::from_str(".");
}

// Byte-lexicographic path order with a length tiebreak: a deterministic batch member list.
const fn path_cmp(a: &String, b: &String) i32 {
    let la = a.len();
    let lb = b.len();
    let m = if la < lb {
        la;
    } else {
        lb;
    };
    let mut i: usize = 0;
    while i < m {
        let ca = a.as_str()[i];
        let cb = b.as_str()[i];
        if ca != cb {
            return ca as i32 - cb as i32;
        }
        i += 1;
    }
    return la as i32 - lb as i32;
}

// JSON-RPC plumbing.

fn respond(f: *mut stdio::FILE, id: &json::JSON, result: &json::JSON) {
    let mut body = String::with_capacity(256);
    body.push_str("{\"jsonrpc\":\"2.0\",\"id\":");
    let ids = id.dump(false);
    body.push_string(&ids);
    body.push_str(",\"result\":");
    let rs = result.dump(false);
    body.push_string(&rs);
    body.push_byte(b'}');
    transport::write_message(f, body.as_str());
}

// As `respond`, with the result as pre-rendered JSON text (for static payloads like the capabilities).
fn respond_raw(f: *mut stdio::FILE, id: &json::JSON, result: str) {
    let mut body = String::with_capacity(result.len() + 40);
    body.push_str("{\"jsonrpc\":\"2.0\",\"id\":");
    let ids = id.dump(false);
    body.push_string(&ids);
    body.push_str(",\"result\":");
    body.push_str(result);
    body.push_byte(b'}');
    transport::write_message(f, body.as_str());
}

fn send_error(f: *mut stdio::FILE, id: &json::JSON, code: i64, msg: str) {
    let mut body = String::with_capacity(128);
    body.push_str("{\"jsonrpc\":\"2.0\",\"id\":");
    let ids = id.dump(false);
    body.push_string(&ids);
    body.push_str(",\"error\":{\"code\":");
    body.push_i64(code);
    body.push_str(",\"message\":");
    json::dump_escaped(msg, &mut body);
    body.push_str("}}");
    transport::write_message(f, body.as_str());
}

// Server-to-client request registering the **/*.spc and **/build.toml watchers dynamically. The
// client's response is consumed (not dispatched) by the main loop.
fn register_watchers(f: *mut stdio::FILE) {
    transport::write_message(
        f,
        M"({"jsonrpc":"2.0","id":"sc-reg-watch","method":"client/registerCapability","params":{"registrations":[{"id":"sc-watch","method":"workspace/didChangeWatchedFiles","registerOptions":{"watchers":[{"globPattern":"**/*.spc"},{"globPattern":"**/build.toml"}]}}]}})",
    );
}

fn notify(f: *mut stdio::FILE, method: str, params: &json::JSON) {
    let mut body = String::with_capacity(256);
    body.push_str("{\"jsonrpc\":\"2.0\",\"method\":");
    json::dump_escaped(method, &mut body);
    body.push_str(",\"params\":");
    let ps = params.dump(false);
    body.push_string(&ps);
    body.push_byte(b'}');
    transport::write_message(f, body.as_str());
}

// Diagnostics: rebuild every root and republish.

fn range_json(src: str, ls: &Vector<u32>, start: u32, len: u32) json::JSON {
    let s = text::offset_to_pos(src, ls, start);
    let e = text::offset_to_pos(src, ls, start + len);
    let mut sp = json::JSON::object();
    sp.emplace("line", json::JSON::integer(s.line));
    sp.emplace("character", json::JSON::integer(s.character));
    let mut ep = json::JSON::object();
    ep.emplace("line", json::JSON::integer(e.line));
    ep.emplace("character", json::JSON::integer(e.character));
    let mut r = json::JSON::object();
    r.emplace("start", sp);
    r.emplace("end", ep);
    return r;
}

// Per-URI accumulator for one publish round.
struct PubSet {
    pub uris: Vector<String>,
    pub arrs: Vector<json::JSON>,
}

extend PubSet as Free {
    pub fn free(self: &mut Self) {
        self.uris.free();
        self.arrs.free();
    }
}

extend PubSet {
    // Register a URI with its complete list (possibly empty), replacing anything gathered for it.
    fn push_all(self: &mut Self, uri: String, arr: json::JSON) {
        for i in 0..self.uris.len() {
            if self.uris.at(i).as_str() == uri.as_str() {
                self.arrs.set(i, arr);
                return;
            }
        }
        self.uris.push(uri);
        self.arrs.push(arr);
    }
    fn push(self: &mut Self, uri: String, d: json::JSON) {
        for i in 0..self.uris.len() {
            if self.uris.at(i).as_str() == uri.as_str() {
                self.arrs[i].push_back(d);
                return;
            }
        }
        self.uris.push(uri);
        let mut a = json::JSON::array();
        a.push_back(d);
        self.arrs.push(a);
    }
}

// Lifecycle + document sync handlers.

/// The server's advertised capability set. UTF-16 positions are advertised explicitly; the optional
/// providers (pull diagnostics, token deltas, lazy code-action resolve) are advertised only when the
/// CLIENT declared support for them at initialize; response shapes that depend on client capabilities
/// (hierarchical symbols, versioned document edits) are negotiated and applied per response.
pub fn capabilities_with(pull: bool, delta: bool, resolve: bool) String {
    let mut s = String::from_str(
        "{\"capabilities\":{\"positionEncoding\":\"utf-16\",\"textDocumentSync\":{\"openClose\":true,\"change\":2},\"hoverProvider\":true,\"definitionProvider\":true,\"typeDefinitionProvider\":true,\"implementationProvider\":true,\"referencesProvider\":true,\"documentHighlightProvider\":true,\"renameProvider\":{\"prepareProvider\":true},\"documentFormattingProvider\":true,\"callHierarchyProvider\":true,\"typeHierarchyProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\".\",\":\",\"@\",\"'\"]},\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]},\"documentSymbolProvider\":true,\"workspaceSymbolProvider\":true,\"foldingRangeProvider\":true,\"selectionRangeProvider\":true,\"inlayHintProvider\":true",
    );
    s.push_str(",\"codeActionProvider\":{\"codeActionKinds\":[\"quickfix\",\"source.fixAll\"]");
    if resolve {
        s.push_str(",\"resolveProvider\":true");
    }
    s.push_str("}");
    if pull {
        s.push_str(",\"diagnosticProvider\":{\"interFileDependencies\":true,\"workspaceDiagnostics\":false}");
    }
    s.push_str(
        ",\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"namespace\",\"type\",\"enum\",\"enumMember\",\"interface\",\"typeParameter\",\"parameter\",\"variable\",\"property\",\"function\",\"method\"],\"tokenModifiers\":[\"declaration\",\"readonly\"]},\"range\":true,\"full\":",
    );
    if delta {
        s.push_str("{\"delta\":true}");
    } else {
        s.push_str("true");
    }
    s.push_str(
        "},\"workspace\":{\"workspaceFolders\":{\"supported\":true,\"changeNotifications\":true}}},\"serverInfo\":{\"name\":\"super-c lsp\",\"version\":\"0.3\"}}",
    );
    return s;
}

// A doc's canonical path from its URI (realpath when the file exists on disk).
fn uri_doc_path(uri: str) String {
    let raw = text::uri_to_path(uri);
    return analysis::canon_path(raw.as_str());
}

// `build.toml` is served by the manifest half of the server (src/lsp/buildtoml.spc): it is not Super-C
// source, so none of the package machinery applies to it.
const fn is_manifest_path(path: str) bool {
    return path.ends_with("build.toml");
}

// Positional requests: hover / definition / references / rename.

// A positional request resolved onto a built package: root r, module m, byte span [off, end]
// (end == off for point requests).
struct Hit {
    pub ok: bool,
    pub r: usize,
    pub m: usize,
    pub off: u32,
    pub end: u32,
}

// A reference site keyed by its canonical file path, the primary key of the deterministic result order.
struct KeyedHit {
    pub path: String,
    pub h: RefHit,
}

fn keyed_hit_cmp(x: &KeyedHit, y: &KeyedHit) i32 {
    let c = path_cmp(&x.path, &y.path);
    if c != 0 {
        return c;
    }
    if x.h.s != y.h.s {
        return if x.h.s < y.h.s {
            -1;
        } else {
            1;
        };
    }
    if x.h.e != y.h.e {
        return if x.h.e < y.h.e {
            -1;
        } else {
            1;
        };
    }
    return 0;
}

// One cross-root reference site: root, module (within that root's package), byte span.
struct RefHit {
    pub r: u32,
    pub m: u32,
    pub s: u32,
    pub e: u32,
}

// The new name must lex as exactly one identifier (rejects keywords, operators, spaces).
fn valid_ident(nm: str) bool {
    if nm.len() == 0 {
        return false;
    }
    let mut s = String::from_str(nm);
    let mut lx = lex::Lexer::new(&mut s, "<rename>");
    lx.scan_tokens();
    if lx.has_errors() {
        return false;
    }
    let toks = lx.take_tokens();
    return toks.len() == 2 && toks.at(0).kind() == ltt::TokenType::Identifier;
}

// Main loop.

// A request id is valid when it is a string or a number (LSP integer). Booleans, arrays, objects
// and null are not request ids.
const fn valid_id(id: &json::JSON) bool {
    return id.kind == json::JT_STRING || id.kind == json::JT_NUMBER;
}

/// The blocking stdio server loop; returns the process exit code: 0 for a clean shutdown-then-exit,
/// 1 on EOF (client vanished) or an `exit` without a prior `shutdown`.
pub fn run(std_dir: str, target: i32) i32 {
    let mut sv = Server {
        docs: Vector::<Doc>::new(),
        roots: Vector::<Root>::new(),
        has_manifest: false,
        std_dir: String::from_str(std_dir),
        target: target,
        published: Vector::<String>::new(),
        ws_root: String::new(),
        folders: Vector::<String>::new(),
        out_folders: Vector::<String>::new(),
        out_skips: Vector::<String>::new(),
        canceled_tick: Vector::<u64>::new(),
        last_req_tick: 0,
        shutdown_seen: false,
        initialized: false,
        revision: 0,
        canceled: Vector::<String>::new(),
        cap_hier_symbols: false,
        cap_doc_changes: false,
        cap_pull_diags: false,
        cap_delta_tokens: false,
        cap_action_literals: false,
        cap_action_resolve: false,
        cap_watch_dynreg: false,
        parent_pid: 0,
        max_results: 5000,
        budget_mb: 0,
        tick: 0,
        tok_uris: Vector::<String>::new(),
        tok_ids: Vector::<u64>::new(),
        tok_data: Vector::<Vector<i64>>::new(),
        tok_next: 0,
    };
    let fin = stdio::stdin();
    let fout = stdio::stdout();
    if !stdio::set_binary(fin) {
        return 1;
    }
    if !stdio::set_binary(fout) {
        return 1;
    }
    loop {
        let msgo = transport::read_message(fin);
        if msgo.is_none() {
            // EOF: the client vanished without exit.
            return 1;
        }
        let msg = msgo.unwrap();
        let mut req = json::JSON::default();
        let mut bad = true;
        switch json::parse(msg.as_str()) {
            Ok(v) => {
                req = v;
                bad = false;
            },
            Err(e) => {
                let nullid = json::JSON::default();
                let em = e;
                send_error(fout, &nullid, -32700, em.as_str());
            },
        };
        if bad {
            continue;
        }
        // Structural validation: jsonrpc must be "2.0", method a string, an id (when present) a
        // string or number. A malformed request errors; a malformed notification is dropped.
        let is_req = req.contains_key("id");
        if is_req && !valid_id(req.at_key("id")) {
            let nullid = json::JSON::default();
            send_error(fout, &nullid, -32600, "invalid request id");
            continue;
        }
        let jr_ok = req.value_str("jsonrpc") == "2.0";
        let mo = req.value("method");
        let m_ok = mo.is_some() && mo.unwrap().kind == json::JT_STRING;
        // A message with an id and a result/error but no method is the client's response to a
        // server-to-client request (dynamic registration): consume it silently.
        if jr_ok && !m_ok && is_req && (req.contains_key("result") || req.contains_key("error")) {
            continue;
        }
        if !jr_ok || !m_ok {
            if is_req {
                send_error(fout, req.at_key("id"), -32600, "invalid request");
            }
            continue;
        }
        sv.tick += 1;
        // Parent-death detection: after the client's process dies, the next message (or EOF) ends the server.
        if sv.parent_pid > 0 && unsafe shim::sc_process_alive(sv.parent_pid) == 0 {
            return 1;
        }
        let method = req.value_str("method");
        // Lifecycle gates (LSP 3.17): before initialize only `initialize` and `exit` proceed;
        // requests get -32002, other notifications are dropped. After shutdown only `exit`.
        if method == "exit" {
            if sv.shutdown_seen {
                return 0;
            }
            return 1;
        }
        if !sv.initialized && method != "initialize" {
            if is_req {
                send_error(fout, req.at_key("id"), -32002, "server not initialized");
            }
            continue;
        }
        if sv.shutdown_seen && method != "shutdown" {
            if is_req {
                send_error(fout, req.at_key("id"), -32600, "server is shutting down");
            }
            continue;
        }
        if method == "$/cancelRequest" {
            switch req.value("params") {
                Some(params) => switch params.value("id") {
                    Some(cid) => {
                        sv.canceled.push(cid.dump(false));
                        sv.canceled_tick.push(sv.tick);
                        if sv.canceled.len() > 64 {
                            let old = sv.canceled.remove(0).unwrap();
                            old.free();
                            let _ = sv.canceled_tick.remove(0);
                        }
                    },
                    None => {},
                },
                None => {},
            };
            continue;
        }
        // A request whose id was already canceled gets the RequestCancelled response and no work.
        // Dispatch is synchronous, so a cancel recorded before the last handled request can only
        // target a completed request: purge it, or a client that reuses ids loses a live request.
        if is_req {
            let ids = req.at_key("id").dump(false);
            let mut hit = false;
            let mut k: usize = 0;
            while k < sv.canceled.len() {
                if *sv.canceled_tick.at(k) <= sv.last_req_tick {
                    let old = sv.canceled.remove(k).unwrap();
                    old.free();
                    let _ = sv.canceled_tick.remove(k);
                } else if sv.canceled.at(k).as_str() == ids.as_str() {
                    hit = true;
                    let old = sv.canceled.remove(k).unwrap();
                    old.free();
                    let _ = sv.canceled_tick.remove(k);
                } else {
                    k += 1;
                }
            }
            sv.last_req_tick = sv.tick;
            if hit {
                send_error(fout, req.at_key("id"), -32800, "request canceled");
                continue;
            }
        }
        if method == "initialize" {
            if sv.initialized {
                send_error(fout, req.at_key("id"), -32600, "initialize was already accepted");
            } else {
                sv.on_initialize(&req, fout);
            }
        } else if method == "initialized" {
            // Dynamic watched-file registration first, so a client without static watcher support
            // starts delivering **/*.spc and **/build.toml changes.
            if sv.cap_watch_dynreg {
                register_watchers(fout);
            }
            // First full round: the manifest build and workspace sweep publish diagnostics for the
            // whole build.toml folder before any document opens.
            sv.rebuild_all(fout, false);
        } else if method == "shutdown" {
            sv.shutdown_seen = true;
            let nullv = json::JSON::default();
            respond(fout, req.at_key("id"), &nullv);
        } else if method == "textDocument/didOpen" {
            sv.revision += 1;
            sv.on_did_open(&req, fout);
        } else if method == "textDocument/didChange" {
            sv.revision += 1;
            sv.on_did_change(&req, fout);
        } else if method == "textDocument/didSave" {
            // Overlays are already current.
        } else if method == "textDocument/didClose" {
            sv.revision += 1;
            sv.on_did_close(&req, fout);
        } else if method == "workspace/didChangeWatchedFiles" {
            sv.revision += 1;
            sv.on_watched_files(&req, fout);
        } else if method == "workspace/didChangeWorkspaceFolders" {
            sv.revision += 1;
            sv.on_folders_changed(&req, fout);
        } else if method == "workspace/didChangeConfiguration" {
            sv.revision += 1;
            sv.rebuild_all(fout, false);
        } else if method == "textDocument/hover" && is_req {
            sv.on_hover(&req, fout);
        } else if method == "textDocument/definition" && is_req {
            sv.on_definition(&req, fout);
        } else if method == "textDocument/typeDefinition" && is_req {
            sv.on_type_definition(&req, fout);
        } else if method == "textDocument/implementation" && is_req {
            sv.on_implementation(&req, fout);
        } else if method == "textDocument/references" && is_req {
            sv.on_references(&req, fout);
        } else if method == "textDocument/documentHighlight" && is_req {
            sv.on_document_highlight(&req, fout);
        } else if method == "textDocument/prepareRename" && is_req {
            sv.on_prepare_rename(&req, fout);
        } else if method == "textDocument/rename" && is_req {
            sv.on_rename(&req, fout);
        } else if method == "textDocument/formatting" && is_req {
            sv.on_formatting(&req, fout);
        } else if method == "textDocument/semanticTokens/full" && is_req {
            sv.on_semantic_tokens(&req, fout, false);
        } else if method == "textDocument/semanticTokens/range" && is_req {
            sv.on_semantic_tokens(&req, fout, true);
        } else if method == "textDocument/semanticTokens/full/delta" && is_req {
            sv.on_semantic_tokens_delta(&req, fout);
        } else if method == "textDocument/diagnostic" && is_req {
            sv.on_pull_diagnostic(&req, fout);
        } else if method == "textDocument/prepareCallHierarchy" && is_req {
            sv.on_prepare_call_hierarchy(&req, fout);
        } else if method == "callHierarchy/incomingCalls" && is_req {
            sv.on_incoming_calls(&req, fout);
        } else if method == "callHierarchy/outgoingCalls" && is_req {
            sv.on_outgoing_calls(&req, fout);
        } else if method == "textDocument/prepareTypeHierarchy" && is_req {
            sv.on_prepare_type_hierarchy(&req, fout);
        } else if method == "typeHierarchy/supertypes" && is_req {
            sv.on_type_hierarchy_related(&req, fout, true);
        } else if method == "typeHierarchy/subtypes" && is_req {
            sv.on_type_hierarchy_related(&req, fout, false);
        } else if method == "codeAction/resolve" && is_req {
            sv.on_code_action_resolve(&req, fout);
        } else if method == "textDocument/completion" && is_req {
            sv.on_completion(&req, fout);
        } else if method == "textDocument/signatureHelp" && is_req {
            sv.on_signature_help(&req, fout);
        } else if method == "textDocument/documentSymbol" && is_req {
            sv.on_document_symbol(&req, fout);
        } else if method == "workspace/symbol" && is_req {
            sv.on_workspace_symbol(&req, fout);
        } else if method == "textDocument/foldingRange" && is_req {
            sv.on_folding_range(&req, fout);
        } else if method == "textDocument/selectionRange" && is_req {
            sv.on_selection_range(&req, fout);
        } else if method == "textDocument/inlayHint" && is_req {
            sv.on_inlay_hint(&req, fout);
        } else if method == "textDocument/codeAction" && is_req {
            sv.on_code_action(&req, fout);
        } else if is_req {
            send_error(fout, req.at_key("id"), -32601, "method not found");
        }
        // Remaining unknown notifications ($/setTrace, ...) are ignored.
    }
}

extend Server {
    fn find_doc(self: &Self, uri: str) i32 {
        for i in 0..self.docs.len() {
            if self.docs.at(i).uri.as_str() == uri {
                return i as i32;
            }
        }
        return -1;
    }

    // Module id of `path` inside root `r`, -1 when it is not part of that package.
    fn root_module(self: &Self, r: usize, path: str) i32 {
        let files = &self.roots.at(r).files;
        for m in 0..files.len() {
            if files.at(m).as_str() == path {
                return m as i32;
            }
        }
        return -1;
    }

    // The workspace-batch root: sweep=true with no origin (the manifest root is origin "" + sweep=false).
    const fn is_batch(self: &Self, r: usize) bool {
        return self.roots.at(r).sweep && self.roots.at(r).origin.len() == 0;
    }

    // First BUILT root containing `path` (manifest root first; the workspace batch LAST, so an open
    // doc's per-file root, built from the live overlay, wins over the batch's disk-built copy),
    // -1 if none. A budget-evicted root (files kept for diag republishing, package dropped) owns
    // nothing: its module table is empty, so feature queries must not land on it.
    fn owning_root(self: &Self, path: str) i32 {
        for r in 0..self.roots.len() {
            if !self.is_batch(r) && self.roots.at(r).built && self.roots.at(r).pkg.modules.len() != 0 && self.root_module(
                r,
                path,
            ) >= 0 {
                return r as i32;
            }
        }
        for r in 0..self.roots.len() {
            if self.is_batch(r) && self.roots.at(r).built && self.roots.at(r).pkg.modules.len() != 0 && self.root_module(
                r,
                path,
            ) >= 0 {
                return r as i32;
            }
        }
        return -1;
    }

    // Every open doc must belong to some root; docs outside every built package get a per-file root
    // (the `super-c lint <file>` recipe: file dir as root, src/ as the alt root when it exists).
    // Batch ownership does not count: its copy is disk-built, so an open doc needs its own root.
    fn ensure_roots(self: &mut Self) {
        for i in 0..self.docs.len() {
            let path = self.docs.at(i).path.as_str();
            // Only Super-C source compiles. An open build.toml is served by the manifest half of the
            // server; a package root for it makes the parser read TOML as Super-C and report a
            // parse error on its first line.
            if !path.ends_with(".spc") {
                continue;
            }
            let own = self.owning_root(path);
            if own >= 0 && !self.is_batch(own as usize) {
                continue;
            }
            let mut have = false;
            for r in 0..self.roots.len() {
                if self.roots.at(r).origin.as_str() == path {
                    have = true;
                }
            }
            if have {
                continue;
            }
            let alt = self.folder_alt_of(path);
            self.roots.push(
                Root {
                    ws: String::new(),
                    root_file: String::from_str(path),
                    root_dir: dir_of(path),
                    alt_dir: alt,
                    origin: String::from_str(path),
                    sweep: false,
                    members: Vector::<String>::new(),
                    pkg: loader::Package::new(),
                    files: Vector::<String>::new(),
                    diags: Vector::<analysis::DiagRec>::new(),
                    built: false,
                    last_used: 0,
                },
            );
        }
        self.ensure_sweep_roots();
    }

    // The workspace folder that contains `path` ("" when none does).
    fn folder_of(self: &Self, path: str) str {
        for i in 0..self.folders.len() {
            let fo = self.folders.at(i).as_str();
            if path.len() > fo.len() + 1 && path.starts_with(fo) && path[fo.len()] == b'/' {
                return fo;
            }
        }
        return "";
    }

    // The `src/` alt root of the folder owning `path` when that directory exists, else "".
    fn folder_alt_of(self: &Self, path: str) String {
        let fo = self.folder_of(path);
        if fo.len() != 0 {
            let alt = Server::abs_under(fo, "src");
            if dutil::is_dir(alt.as_str()) {
                return alt;
            }
        }
        return String::new();
    }

    // The workspace sweep: every .spc under the build.toml folder that no other package owns joins
    // THE batch root, one shared package (the `super-c lint` recipe) instead of a resident package
    // per file. Hidden entries and the manifest out-dir are skipped. The batch rebuilds only when its
    // member set changes (a file appears/vanishes, a doc opens into a per-file root or closes back);
    // otherwise its cached diagnostics republish.
    fn ensure_sweep_roots(self: &mut Self) {
        if !self.has_manifest && self.folders.len() == 0 {
            return;
        }
        for fi in 0..self.folders.len() {
            // The primary folder sweeps only under a manifest; extra folders always sweep so their
            // files get diagnostics.
            if fi == 0 && !self.has_manifest {
                continue;
            }
            let folder = self.folders.at(fi).clone();
            self.ensure_folder_sweep(folder.as_str());
        }
    }

    // One batch root per workspace folder: every unowned .spc under it joins the folder's batch.
    fn ensure_folder_sweep(self: &mut Self, folder: str) {
        let mut alt = String::new();
        {
            let a = Server::abs_under(folder, "src");
            if dutil::is_dir(a.as_str()) {
                alt = a;
            }
        }
        let mut cand = Vector::<String>::new();
        self.sweep_dir(folder, folder, &mut cand);
        cand.sort_by(path_cmp);
        let mut b: i64 = -1;
        for r in 0..self.roots.len() {
            if self.is_batch(r) && self.roots.at(r).ws.as_str() == folder {
                b = r as i64;
            }
        }
        if b < 0 {
            if cand.len() == 0 {
                return;
            }
            self.roots.push(
                Root {
                    ws: String::from_str(folder),
                    root_file: String::new(),
                    root_dir: String::from_str(folder),
                    alt_dir: alt,
                    origin: String::new(),
                    sweep: true,
                    members: cand,
                    pkg: loader::Package::new(),
                    files: Vector::<String>::new(),
                    diags: Vector::<analysis::DiagRec>::new(),
                    built: false,
                    last_used: 0,
                },
            );
            return;
        }
        let bi = b as usize;
        let mut same = self.roots.at(bi).members.len() == cand.len();
        if same {
            for i in 0..cand.len() {
                if self.roots.at(bi).members.at(i).as_str() != cand.at(i).as_str() {
                    same = false;
                }
            }
        }
        if !same {
            self.roots[bi].members = cand;
            self.roots[bi].built = false;
        }
    }

    fn out_skip_of(self: &Self, folder: str) str {
        for i in 0..self.out_folders.len() {
            if self.out_folders.at(i).as_str() == folder {
                return self.out_skips.at(i).as_str();
            }
        }
        return "";
    }

    fn set_out_skip(self: &mut Self, folder: str, out_dir: str) {
        let mut i: usize = 0;
        while i < self.out_folders.len() {
            if self.out_folders.at(i).as_str() == folder {
                let of = self.out_folders.remove(i).unwrap();
                of.free();
                let os = self.out_skips.remove(i).unwrap();
                os.free();
            } else {
                i += 1;
            }
        }
        self.out_folders.push(String::from_str(folder));
        self.out_skips.push(String::from_str(out_dir));
    }

    fn sweep_dir(self: &mut Self, folder: str, dir: str, cand: &mut Vector<String>) {
        let mut db = String::from_str(dir);
        let dh = unsafe shim::sc_opendir(db.cstr());
        if dh == null {
            return;
        }
        let mut names = Vector::<String>::new();
        loop {
            let e = unsafe shim::sc_readdir(dh);
            if e == null {
                break;
            }
            let nm = unsafe shim::sc_dirent_name(e);
            if unsafe nm[0] == '.' as char {
                continue;
            }
            names.push(String::from_cstr(nm));
        }
        unsafe shim::sc_closedir(dh);
        let osk = String::from_str(self.out_skip_of(folder));
        for i in 0..names.len() {
            let mut p = String::from_str(dir);
            p.push_byte(b'/');
            p.push_string(names.at(i));
            if dir == folder && osk.len() != 0 && names.at(i).as_str() == osk.as_str() {
                continue;
            }
            if unsafe shim::sc_stat_isdir(p.cstr()) == 1 {
                self.sweep_dir(folder, p.as_str(), cand);
            } else if p.as_str().ends_with(".spc") {
                let cp = analysis::canon_path(p.as_str());
                let own = self.owning_root(cp.as_str());
                let mut have = own >= 0 && !self.is_batch(own as usize);
                for r in 0..self.roots.len() {
                    if self.roots.at(r).origin.as_str() == cp.as_str() {
                        have = true;
                    }
                }
                if !have {
                    cand.push(p);
                }
            }
        }
    }

    fn doc_open(self: &Self, path: str) bool {
        for i in 0..self.docs.len() {
            if self.docs.at(i).path.as_str() == path {
                return true;
            }
        }
        return false;
    }

    // Drop per-file roots whose doc closed, sweep roots whose file vanished, and sweep roots the
    // manifest package has since absorbed (their diagnostics clear via the published-set diff).
    fn drop_orphan_roots(self: &mut Self) {
        let mut r: usize = 0;
        while r < self.roots.len() {
            let mut keep = self.roots.at(r).origin.len() == 0;
            if !keep && self.roots.at(r).sweep {
                let mut ob = self.roots.at(r).origin.clone();
                keep = unsafe shim::sc_mtime(ob.cstr()) != 0;
                if keep {
                    for q in 0..self.roots.len() {
                        if q != r && self.roots.at(q).origin.len() == 0 && !self.roots.at(q).sweep && self.roots.at(q).built && self.root_module(
                            q,
                            ob.as_str(),
                        ) >= 0 {
                            keep = false;
                        }
                    }
                }
            }
            if !keep {
                for i in 0..self.docs.len() {
                    if self.docs.at(i).path.as_str() == self.roots.at(r).origin.as_str() {
                        keep = true;
                    }
                }
            }
            if keep {
                r += 1;
            } else {
                self.roots.remove(r).unwrap().free();
            }
        }
    }

    // Rebuild `r` from the current overlays, converting its DiagRecs into per-URI publish entries.
    // `incr` allows the incremental path (document edits only): a built root updates in place, and
    // only the edit's reach re-analyzes; anything outside the incremental domain falls back to the
    // full compile below. SC_LSP_NO_INCR=1 disables the path entirely (identical full-rebuild
    // behavior, the cache-off parity mode).
    fn build_root(self: &mut Self, r: usize, ps: &mut PubSet, incr: bool) {
        let mut ovf = Vector::<String>::new();
        let mut ovt = Vector::<String>::new();
        for i in 0..self.docs.len() {
            ovf.push(self.docs.at(i).path.clone());
            ovt.push(self.docs.at(i).txt.clone());
        }
        if incr && self.roots.at(r).built && self.roots.at(r).pkg.modules.len() != 0 && stdlib::getenv("SC_LSP_NO_INCR") == null {
            let rf9 = self.roots.at(r).root_file.clone();
            let ld9 = if self.roots.at(r).origin.len() == 0 && !self.roots.at(r).sweep {
                self.roots.at(r).ws.clone();
            } else {
                String::new();
            };
            let mut st = analysis::RecompileStats {};
            let mut old_diags = replace(&mut self.roots[r].diags, Vector::<analysis::DiagRec>::new());
            let ok = analysis::recompile(
                &mut self.roots[r].pkg,
                self.target,
                rf9.as_str(),
                ld9.as_str(),
                &ovf,
                &ovt,
                &mut old_diags,
                &mut st,
            );
            if ok {
                self.roots[r].diags = old_diags;
                self.publish_root_diags(r, ps);
                return;
            }
            old_diags.free();
        }
        let mut diags = Vector::<analysis::DiagRec>::new();
        let rf = self.roots.at(r).root_file.clone();
        let rd = self.roots.at(r).root_dir.clone();
        let ad = self.roots.at(r).alt_dir.clone();
        // Drop the previous build BEFORE compiling: holding both packages doubled the peak.
        self.roots[r].pkg = loader::Package::new();
        // A manifest root lints every workspace file it owns (incl. an in-repo std/); other roots
        // lint only their own root file, so each file's lint warnings come from exactly one root.
        let ld = if self.roots.at(r).origin.len() == 0 && !self.roots.at(r).sweep {
            self.roots.at(r).ws.clone();
        } else {
            String::new();
        };
        let pkg = if self.is_batch(r) {
            analysis::compile_batch(
                &self.roots.at(r).members,
                rd.as_str(),
                ad.as_str(),
                self.std_dir.as_str(),
                self.target,
                ovf,
                ovt,
                &mut diags,
            );
        } else {
            analysis::compile(
                rf.as_str(),
                rd.as_str(),
                ad.as_str(),
                self.std_dir.as_str(),
                self.target,
                ovf,
                ovt,
                ld.as_str(),
                &mut diags,
            );
        };
        self.roots[r].pkg = pkg;
        self.roots[r].files = Vector::<String>::new();
        let nmods = self.roots.at(r).pkg.modules.len();
        for m in 0..nmods {
            let fp = analysis::canon_path(self.roots.at(r).pkg.modules.at(m).file.as_str());
            self.roots[r].files.push(fp);
        }
        self.roots[r].built = true;
        self.roots[r].last_used = self.tick;
        // Retain the records: publishing + codeAction read from them until the next rebuild.
        self.roots[r].diags = diags;
        self.publish_root_diags(r, ps);
    }

    // Convert root `r`'s retained diagnostics into per-URI publish entries (module ids are
    // per-package). Also republishes a cached sweep root without rebuilding it.
    fn publish_root_diags(self: &Self, r: usize, ps: &mut PubSet) {
        // Files a manifest package owns publish from it alone: a per-file/sweep root's closure
        // reaches std and friends, and republishing its (possibly stale) copies would duplicate them.
        let mut dedup = false;
        for q in 0..self.roots.len() {
            if q != r && self.roots.at(q).origin.len() == 0 && !self.roots.at(q).sweep && self.roots.at(q).built {
                dedup = true;
            }
        }
        let mut last_mod: i64 = -1;
        let mut ls = Vector::<u32>::new();
        for k in 0..self.roots.at(r).diags.len() {
            let d = self.roots.at(r).diags.at(k);
            let m = d.module as usize;
            if m >= self.roots.at(r).pkg.modules.len() {
                continue;
            }
            if dedup {
                let mut owned = false;
                for q in 0..self.roots.len() {
                    if q != r && self.roots.at(q).origin.len() == 0 && !self.roots.at(q).sweep && self.roots.at(q).built && self.root_module(
                        q,
                        self.roots.at(r).files.at(m).as_str(),
                    ) >= 0 {
                        owned = true;
                    }
                }
                if owned {
                    continue;
                }
            }
            // A batch module whose file has a live per-file root (its doc is open) publishes from
            // that root's overlay-fresh build, not the batch's disk-built copy.
            if self.is_batch(r) {
                let mut fresh = false;
                for q in 0..self.roots.len() {
                    if q != r && self.roots.at(q).built && self.roots.at(q).origin.as_str() == self.roots.at(r).files.at(
                        m,
                    ).as_str() {
                        fresh = true;
                    }
                }
                if fresh {
                    continue;
                }
            }
            let src = self.roots.at(r).pkg.modules.at(m).source.as_str();
            if d.module as i64 != last_mod {
                ls = text::line_starts(src);
                last_mod = d.module;
            }
            let mut dj = json::JSON::object();
            dj.emplace("range", range_json(src, &ls, d.start, d.len));
            dj.emplace("severity", json::JSON::integer(d.severity));
            dj.emplace("source", json::JSON::str("super-c"));
            dj.emplace("message", json::JSON::str(d.msg.as_str()));
            let uri = text::path_to_uri(self.roots.at(r).files.at(m).as_str());
            ps.push(uri, dj);
        }
    }

    // Every OPEN build.toml gets the build's own verdict on it. An open manifest with no diagnostics
    // still registers its URI, so an earlier reported problem is cleared once fixed.
    fn publish_manifest_diags(self: &Self, ps: &mut PubSet) {
        for d in 0..self.docs.len() {
            let doc = self.docs.at(d);
            if !is_manifest_path(doc.path.as_str()) {
                continue;
            }
            let src = doc.txt.as_str();
            let ls = text::line_starts(src);
            let diags = btoml::diagnostics(src);
            let mut any = json::JSON::array();
            for i in 0..diags.len() {
                let dg = diags.at(i);
                let mut dj = json::JSON::object();
                dj.emplace("range", range_json(src, &ls, dg.start, dg.len));
                dj.emplace("severity", json::JSON::integer(1));
                dj.emplace("source", json::JSON::str("build.toml"));
                dj.emplace("message", json::JSON::str(dg.msg.as_str()));
                any.push_back(dj);
            }
            ps.push_all(doc.uri.clone(), any);
        }
    }

    // Rebuild everything and republish: every URI with diagnostics gets its list, every URI published
    // last round but clean now gets an explicit empty list.
    fn rebuild_all(self: &mut Self, f: *mut stdio::FILE, incr: bool) {
        self.drop_orphan_roots();
        // Manifest roots build first: they decide which docs need per-file roots.
        for r in 0..self.roots.len() {
            if self.roots.at(r).origin.len() == 0 && !self.roots.at(r).sweep && !self.roots.at(r).built {
                let mut ps0 = PubSet { uris: Vector::<String>::new(), arrs: Vector::<json::JSON>::new() };
                self.build_root(r, &mut ps0, false);
                // Publishing waits for the full round below; this build only seeds ownership.
            }
        }
        self.ensure_roots();
        let mut ps = PubSet { uris: Vector::<String>::new(), arrs: Vector::<json::JSON>::new() };
        for r in 0..self.roots.len() {
            // A built sweep root for a closed file republishes its cached diagnostics: rebuilding
            // every workspace file on each keystroke would be unusable.
            if self.roots.at(r).sweep && self.roots.at(r).built && !self.doc_open(self.roots.at(r).origin.as_str()) {
                self.publish_root_diags(r, &mut ps);
            } else {
                self.build_root(r, &mut ps, incr);
            }
        }
        self.publish_manifest_diags(&mut ps);
        // Publish.
        for i in 0..ps.uris.len() {
            let mut params = json::JSON::object();
            params.emplace("uri", json::JSON::str(ps.uris.at(i).as_str()));
            params.emplace("diagnostics", ps.arrs.at(i).clone());
            notify(f, "textDocument/publishDiagnostics", &params);
        }
        // Clear URIs that had diagnostics last round and none now.
        for i in 0..self.published.len() {
            let old = self.published.at(i).as_str();
            let mut still = false;
            for j in 0..ps.uris.len() {
                if ps.uris.at(j).as_str() == old {
                    still = true;
                }
            }
            if !still {
                let mut params = json::JSON::object();
                params.emplace("uri", json::JSON::str(old));
                params.emplace("diagnostics", json::JSON::array());
                notify(f, "textDocument/publishDiagnostics", &params);
            }
        }
        self.published = Vector::<String>::new();
        for i in 0..ps.uris.len() {
            self.published.push(ps.uris.at(i).clone());
        }
        self.enforce_budget();
    }

    // Retention budget (SC_LSP_BUDGET_MB; unset = unlimited): when the retained packages exceed it,
    // evict the ones no open document pins: the workspace batch and per-file roots of closed docs;
    // in LEAST-RECENTLY-USED order (each build stamps its root with the server tick; a closed root's
    // stamp freezes, so the longest-idle package goes first). Their diagnostics (and file maps) stay
    // for cached republishing; the next request that needs the package rebuilds it. Roots owning open
    // docs (the manifest included) are pinned.
    fn enforce_budget(self: &mut Self) {
        let mut mb = self.budget_mb;
        if mb <= 0 {
            let e = stdlib::getenv("SC_LSP_BUDGET_MB");
            if e == null {
                return;
            }
            mb = unsafe stdlib::atoi(e);
        }
        if mb <= 0 {
            return;
        }
        let budget = mb as usize * 1048576;
        let mut total: usize = 0;
        for r in 0..self.roots.len() {
            total += self.roots.at(r).pkg.retained_bytes();
        }
        while total > budget {
            // The least-recently-used evictable root with a resident package.
            let mut pick: i64 = -1;
            let mut oldest: u64 = 0xFFFFFFFFFFFFFFFF;
            for r in 0..self.roots.len() {
                if self.roots.at(r).pkg.modules.len() == 0 {
                    continue;
                }
                let closed_pf = self.roots.at(r).origin.len() != 0 && !self.doc_open(self.roots.at(r).origin.as_str());
                if (self.is_batch(r) || closed_pf) && self.roots.at(r).last_used < oldest {
                    oldest = self.roots.at(r).last_used;
                    pick = r as i64;
                }
            }
            if pick < 0 {
                // Everything left is pinned.
                break;
            }
            let b = self.roots.at(pick as usize).pkg.retained_bytes();
            self.roots[pick as usize].pkg = loader::Package::new();
            total -= b;
        }
    }

    // Join `rel` under `base` unless it is already absolute.
    fn abs_under(base: str, rel: str) String {
        if rel.len() != 0 && (rel[0] == b'/' || rel.len() > 2 && rel[1] == b':') {
            return String::from_str(rel);
        }
        let mut out = String::from_str(base);
        out.push_byte(b'/');
        out.push_str(rel);
        return out;
    }

    // Load `folder`/build.toml and append its manifest root (at `at` when >= 0, else at the end).
    // Returns true when a manifest was found. No process chdir: every path stays absolute.
    fn add_manifest_root(self: &mut Self, folder: str, at: i32) bool {
        let mp = Server::abs_under(folder, "build.toml");
        let mano = bman::load(mp.as_str());
        if mano.is_none() {
            return false;
        }
        let man = mano.unwrap();
        let rf = Server::abs_under(folder, man.root.as_str());
        let rd = dir_of(rf.as_str());
        let r = Root {
            ws: String::from_str(folder),
            root_file: rf,
            root_dir: rd,
            alt_dir: String::new(),
            origin: String::new(),
            sweep: false,
            members: Vector::<String>::new(),
            pkg: loader::Package::new(),
            files: Vector::<String>::new(),
            diags: Vector::<analysis::DiagRec>::new(),
            built: false,
            last_used: 0,
        };
        if at >= 0 {
            self.roots.insert(at as usize, r);
        } else {
            self.roots.push(r);
        }
        self.set_out_skip(folder, man.out_dir.as_str());
        return true;
    }

    fn on_initialize(self: &mut Self, req: &json::JSON, f: *mut stdio::FILE) {
        switch req.value("params") {
            Some(params) => {
                switch params.value("workspaceFolders") {
                    Some(wfs) => {
                        if wfs.is_array() {
                            for i in 0..wfs.size() {
                                let u = wfs.at(i).value_str("uri");
                                if u.len() != 0 {
                                    let p = text::uri_to_path(u);
                                    self.folders.push(analysis::canon_path(p.as_str()));
                                }
                            }
                        }
                    },
                    None => {},
                };
                if self.folders.len() == 0 {
                    let ru = params.value_str("rootUri");
                    if ru.len() != 0 {
                        let p = text::uri_to_path(ru);
                        self.folders.push(analysis::canon_path(p.as_str()));
                    } else {
                        let rp = params.value_str("rootPath");
                        if rp.len() != 0 {
                            self.folders.push(analysis::canon_path(rp));
                        }
                    }
                }
                // Parent process: polled between messages so a dead client ends the server.
                switch params.value("processId") {
                    Some(pid) => {
                        if pid.kind == json::JT_NUMBER {
                            self.parent_pid = pid.get_i64();
                        }
                    },
                    None => {},
                };
                // Server settings (the plan's limit knobs live here, not in env vars alone).
                switch params.value("initializationOptions") {
                    Some(io) => {
                        let mr = io.value_i64("maxResults", 0);
                        if mr > 0 {
                            self.max_results = mr as usize;
                        }
                        self.budget_mb = io.value_i64("budgetMb", 0);
                    },
                    None => {},
                };
                // Negotiated client capabilities that change response SHAPES or gate providers.
                switch params.value("capabilities") {
                    Some(caps) => {
                        switch caps.value("textDocument") {
                            Some(td) => {
                                switch td.value("documentSymbol") {
                                    Some(ds) => {
                                        self.cap_hier_symbols = ds.value("hierarchicalDocumentSymbolSupport").is_some() && ds.at_key(
                                            "hierarchicalDocumentSymbolSupport",
                                        ).is_bool() && ds.at_key("hierarchicalDocumentSymbolSupport").get_bool();
                                    },
                                    None => {},
                                };
                                self.cap_pull_diags = td.value("diagnostic").is_some();
                                switch td.value("semanticTokens") {
                                    Some(st) => switch st.value("requests") {
                                        Some(rq) => switch rq.value("full") {
                                            Some(fl) => {
                                                self.cap_delta_tokens = fl.value("delta").is_some() && fl.at_key(
                                                    "delta",
                                                ).is_bool() && fl.at_key("delta").get_bool();
                                            },
                                            None => {},
                                        },
                                        None => {},
                                    },
                                    None => {},
                                };
                                switch td.value("codeAction") {
                                    Some(ca) => {
                                        self.cap_action_literals = ca.value("codeActionLiteralSupport").is_some();
                                        switch ca.value("resolveSupport") {
                                            Some(rs) => switch rs.value("properties") {
                                                Some(props) => {
                                                    if props.is_array() {
                                                        for i in 0..props.size() {
                                                            if props.at(i).kind == json::JT_STRING && props.at(i).get_str() == "edit" {
                                                                self.cap_action_resolve = true;
                                                            }
                                                        }
                                                    }
                                                },
                                                None => {},
                                            },
                                            None => {},
                                        };
                                    },
                                    None => {},
                                };
                            },
                            None => {},
                        };
                        switch caps.value("workspace") {
                            Some(wc) => {
                                switch wc.value("workspaceEdit") {
                                    Some(we) => {
                                        self.cap_doc_changes = we.value("documentChanges").is_some() && we.at_key(
                                            "documentChanges",
                                        ).is_bool() && we.at_key("documentChanges").get_bool();
                                    },
                                    None => {},
                                };
                                switch wc.value("didChangeWatchedFiles") {
                                    Some(dw) => {
                                        self.cap_watch_dynreg = dw.value("dynamicRegistration").is_some() && dw.at_key(
                                            "dynamicRegistration",
                                        ).is_bool() && dw.at_key("dynamicRegistration").get_bool();
                                    },
                                    None => {},
                                };
                            },
                            None => {},
                        };
                    },
                    None => {},
                };
            },
            None => {},
        };
        if self.folders.len() != 0 {
            self.ws_root = self.folders.at(0).clone();
        }
        // One manifest root per folder that carries a build.toml; the primary folder's sits first.
        for i in 0..self.folders.len() {
            let folder = self.folders.at(i).clone();
            let primary = i == 0;
            let got = self.add_manifest_root(
                folder.as_str(),
                if primary {
                    0;
                } else {
                    -1;
                },
            );
            if primary && got {
                self.has_manifest = true;
            }
        }
        self.initialized = true;
        let caps = capabilities_with(self.cap_pull_diags, self.cap_delta_tokens, self.cap_action_resolve);
        respond_raw(f, req.at_key("id"), caps.as_str());
    }

    fn on_did_open(self: &mut Self, req: &json::JSON, f: *mut stdio::FILE) {
        switch req.value("params") {
            Some(params) => {
                let td = params.at_key("textDocument");
                let uri = td.value_str("uri");
                let p = uri_doc_path(uri);
                let di = self.find_doc(uri);
                if di >= 0 {
                    self.docs[di as usize].txt = String::from_str(td.value_str("text"));
                    self.docs[di as usize].version = td.value_i64("version", 0);
                } else {
                    self.docs.push(
                        Doc {
                            uri: String::from_str(uri),
                            path: p,
                            txt: String::from_str(td.value_str("text")),
                            version: td.value_i64("version", 0),
                        },
                    );
                }
                self.rebuild_all(f, true);
            },
            None => {},
        };
    }

    // One ranged change applied to `txt` in place. False = invalid range (negative positions, a
    // start past the end, or an end past the document): the whole notification is then dropped.
    fn apply_change(txt: &mut String, ch: &json::JSON) bool {
        let ro = ch.value("range");
        if ro.is_none() {
            // No range: a full-document replacement.
            let mut nt = String::from_str(ch.value_str("text"));
            *txt = replace(&mut nt, String::new());
            return true;
        }
        let rv = ro.unwrap();
        let so = rv.value("start");
        let eo = rv.value("end");
        if so.is_none() || eo.is_none() {
            return false;
        }
        let sl = so.unwrap().value_i64("line", -1);
        let sc = so.unwrap().value_i64("character", -1);
        let el = eo.unwrap().value_i64("line", -1);
        let ec = eo.unwrap().value_i64("character", -1);
        if sl < 0 || sc < 0 || el < 0 || ec < 0 || el < sl || el == sl && ec < sc {
            return false;
        }
        let src = txt.as_str();
        let ls = text::line_starts(src);
        if sl as usize >= ls.len() || el as usize >= ls.len() {
            return false;
        }
        let s = text::pos_to_offset(src, &ls, sl as u32, sc as u32);
        let e = text::pos_to_offset(src, &ls, el as u32, ec as u32);
        if e < s || e as usize > src.len() {
            return false;
        }
        let mut out = String::with_capacity(src.len() + ch.value_str("text").len());
        out.push_str(src.slice(0, s as usize));
        out.push_str(ch.value_str("text"));
        out.push_str(src.slice(e as usize, src.len()));
        *txt = replace(&mut out, String::new());
        return true;
    }

    // Incremental synchronization: changes apply IN ORDER, each ranged against the buffer state
    // left by the one before it (LSP change-event semantics). A change without a range replaces the
    // whole document, so full-sync clients keep working unchanged. Any invalid range drops the whole
    // notification (the malformed-notification rule) and keeps the previous buffer and version.
    fn on_did_change(self: &mut Self, req: &json::JSON, f: *mut stdio::FILE) {
        switch req.value("params") {
            Some(params) => {
                let uri = params.at_key("textDocument").value_str("uri");
                let di = self.find_doc(uri);
                if di < 0 {
                    return;
                }
                switch params.value("contentChanges") {
                    Some(ch) => {
                        if ch.is_array() && ch.size() != 0 {
                            let mut txt = self.docs.at(di as usize).txt.clone();
                            let mut ok = true;
                            for i in 0..ch.size() {
                                if !Server::apply_change(&mut txt, ch.at(i)) {
                                    ok = false;
                                    break;
                                }
                            }
                            if !ok {
                                eprintln("lsp: dropped didChange with an invalid range for {}", uri);
                                return;
                            }
                            self.docs[di as usize].txt = txt;
                            self.docs[di as usize].version = params.at_key("textDocument").value_i64("version", 0);
                            self.rebuild_all(f, true);
                        }
                    },
                    None => {},
                };
            },
            None => {},
        };
    }

    fn on_did_close(self: &mut Self, req: &json::JSON, f: *mut stdio::FILE) {
        switch req.value("params") {
            Some(params) => {
                let uri = params.at_key("textDocument").value_str("uri");
                let di = self.find_doc(uri);
                if di >= 0 {
                    self.docs.remove(di as usize).unwrap().free();
                }
                // Overlays revert to the on-disk content.
                self.rebuild_all(f, false);
            },
            None => {},
        };
    }

    // Map a request's (uri, position) onto (root, module, byte offset). Fails cleanly when the doc is
    // unknown or not part of any built package (callers respond null).
    fn locate(self: &Self, req: &json::JSON) Hit {
        let miss = Hit { ok: false, r: 0, m: 0, off: 0, end: 0 };
        let po = req.value("params");
        if po.is_none() {
            return miss;
        }
        let params = po.unwrap();
        let tdo = params.value("textDocument");
        if tdo.is_none() {
            return miss;
        }
        let uri = tdo.unwrap().value_str("uri");
        if uri.len() == 0 {
            return miss;
        }
        let path = uri_doc_path(uri);
        let r = self.owning_root(path.as_str());
        if r < 0 {
            return miss;
        }
        let m = self.root_module(r as usize, path.as_str());
        if m < 0 {
            return miss;
        }
        let pos = params.value("position");
        if pos.is_none() {
            return miss;
        }
        let pv = pos.unwrap();
        let line = pv.value_i64("line", 0);
        let ch = pv.value_i64("character", 0);
        let src = self.roots.at(r as usize).pkg.modules.at(m as usize).source.as_str();
        let ls = text::line_starts(src);
        let off = text::pos_to_offset(src, &ls, line as u32, ch as u32);
        return Hit { ok: true, r: r as usize, m: m as usize, off: off, end: off };
    }

    // As `locate`, for requests carrying a `range` instead of a `position` (codeAction).
    fn locate_range(self: &Self, req: &json::JSON) Hit {
        let miss = Hit { ok: false, r: 0, m: 0, off: 0, end: 0 };
        let po = req.value("params");
        if po.is_none() {
            return miss;
        }
        let params = po.unwrap();
        let tdo = params.value("textDocument");
        if tdo.is_none() {
            return miss;
        }
        let uri = tdo.unwrap().value_str("uri");
        if uri.len() == 0 {
            return miss;
        }
        let path = uri_doc_path(uri);
        let r = self.owning_root(path.as_str());
        if r < 0 {
            return miss;
        }
        let m = self.root_module(r as usize, path.as_str());
        if m < 0 {
            return miss;
        }
        let ro = params.value("range");
        if ro.is_none() {
            return miss;
        }
        let rv = ro.unwrap();
        let mut sl: i64 = 0;
        let mut sc: i64 = 0;
        let mut el: i64 = 0;
        let mut ec: i64 = 0;
        switch rv.value("start") {
            Some(v) => {
                sl = v.value_i64("line", 0);
                sc = v.value_i64("character", 0);
            },
            None => {},
        };
        switch rv.value("end") {
            Some(v) => {
                el = v.value_i64("line", 0);
                ec = v.value_i64("character", 0);
            },
            None => {},
        };
        let src = self.roots.at(r as usize).pkg.modules.at(m as usize).source.as_str();
        let ls = text::line_starts(src);
        let off = text::pos_to_offset(src, &ls, sl as u32, sc as u32);
        let end = text::pos_to_offset(src, &ls, el as u32, ec as u32);
        return Hit { ok: true, r: r as usize, m: m as usize, off: off, end: end };
    }

    // A feat::Loc as an LSP Location against root `r`'s modules.
    fn loc_json(self: &Self, r: usize, l: &feat::Loc) json::JSON {
        let src = self.roots.at(r).pkg.modules.at(l.module as usize).source.as_str();
        let ls = text::line_starts(src);
        let mut o = json::JSON::object();
        o.emplace("uri", json::JSON::string(text::path_to_uri(self.roots.at(r).files.at(l.module as usize).as_str())));
        o.emplace("range", range_json(src, &ls, l.start, l.end - l.start));
        return o;
    }

    // The open build.toml a positional request names, and the byte offset in it; -1 when the request is
    // not about a manifest. The document text is the editor's, so it is current between keystrokes.
    fn manifest_hit(self: &Self, req: &json::JSON, off: &mut usize) i32 {
        let po = req.value("params");
        if po.is_none() {
            return -1;
        }
        let params = po.unwrap();
        let tdo = params.value("textDocument");
        if tdo.is_none() {
            return -1;
        }
        let uri = tdo.unwrap().value_str("uri");
        let di = self.find_doc(uri);
        if di < 0 || !is_manifest_path(self.docs.at(di as usize).path.as_str()) {
            return -1;
        }
        let pos = params.value("position");
        if pos.is_none() {
            return -1;
        }
        let p = pos.unwrap();
        let src = self.docs.at(di as usize).txt.as_str();
        let ls = text::line_starts(src);
        *off = text::pos_to_offset(src, &ls, p.value_i64("line", 0) as u32, p.value_i64("character", 0) as u32) as usize;
        return di;
    }

    fn on_hover(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let mut moff: usize = 0;
        let mdi = self.manifest_hit(req, &mut moff);
        if mdi >= 0 {
            let doc = btoml::hover(self.docs.at(mdi as usize).txt.as_str(), moff);
            if doc.len() == 0 {
                respond(f, req.at_key("id"), &nullv);
                return;
            }
            let mut contents = json::JSON::object();
            contents.emplace("kind", json::JSON::str("markdown"));
            contents.emplace("value", json::JSON::string(doc));
            let mut res = json::JSON::object();
            res.emplace("contents", contents);
            respond(f, req.at_key("id"), &res);
            return;
        }
        let h = self.locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        switch feat::hover(&self.roots.at(h.r).pkg, h.m, h.off) {
            Some(md) => {
                let mut contents = json::JSON::object();
                contents.emplace("kind", json::JSON::str("markdown"));
                contents.emplace("value", json::JSON::string(md));
                let mut res = json::JSON::object();
                res.emplace("contents", contents);
                respond(f, req.at_key("id"), &res);
            },
            None => {
                respond(f, req.at_key("id"), &nullv);
            },
        };
    }

    fn on_definition(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let h = self.locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        switch feat::definition(&self.roots.at(h.r).pkg, h.m, h.off) {
            Some(l) => {
                let lj = self.loc_json(h.r, &l);
                respond(f, req.at_key("id"), &lj);
            },
            None => {
                respond(f, req.at_key("id"), &nullv);
            },
        };
    }

    // Reference sites for definition `d` (resolved in root `r0`) across EVERY built root, deduped
    // by canonical file + span. The cross-package hop matches on (defining file, kind, name text)
    // the temporary symbol identity until compiler-API symbol ids exist.
    fn collect_refs(self: &Self, r0: usize, d: astn::DefId, include_decl: bool, out: &mut Vector<RefHit>) {
        let pkg0 = &self.roots.at(r0).pkg;
        let locs0 = feat::references_of_def(pkg0, d, include_decl);
        for i in 0..locs0.len() {
            out.push(RefHit { r: r0 as u32, m: locs0.at(i).module, s: locs0.at(i).start, e: locs0.at(i).end });
        }
        let keyo = feat::sym_key(pkg0, d);
        if keyo.is_none() {
            return;
        }
        let key = keyo.unwrap();
        let kfile = analysis::canon_path(key.file.as_str());
        for r2 in 0..self.roots.len() {
            if r2 == r0 || !self.roots.at(r2).built || self.roots.at(r2).pkg.modules.len() == 0 {
                continue;
            }
            let m2 = self.root_module(r2, kfile.as_str());
            if m2 < 0 {
                continue;
            }
            let dn = feat::find_decl_by_key(&self.roots.at(r2).pkg, m2 as usize, key.kind, key.name.as_str());
            if dn == astn::NODE_NONE {
                continue;
            }
            let locs = feat::references_of_def(
                &self.roots.at(r2).pkg,
                astn::DefId { module: m2 as astn::ModuleId, node: dn },
                include_decl,
            );
            for i in 0..locs.len() {
                out.push(RefHit { r: r2 as u32, m: locs.at(i).module, s: locs.at(i).start, e: locs.at(i).end });
            }
        }
        // dedupe by canonical file + span (the same file appears in several packages): sort keyed
        // copies once, then drop equal neighbours: deterministic order, O(n log n) not quadratic.
        let mut keyed = Vector::<KeyedHit>::new();
        keyed.reserve(out.len());
        for i in 0..out.len() {
            let a = *out.at(i);
            keyed.push(KeyedHit { path: self.roots.at(a.r as usize).files.at(a.m as usize).clone(), h: a });
        }
        keyed.sort_by(|x: &KeyedHit, y: &KeyedHit| keyed_hit_cmp(x, y));
        out.clear();
        for i in 0..keyed.len() {
            if i > 0 && keyed.at(i).h.s == keyed.at(i - 1).h.s && keyed.at(i).h.e == keyed.at(i - 1).h.e && keyed.at(i).path.as_str() == keyed.at(
                i - 1,
            ).path.as_str() {
                continue;
            }
            out.push(keyed.at(i).h);
        }
    }

    fn on_references(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let h = self.locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let mut include_decl = false;
        switch req.value("params") {
            Some(params) => switch params.value("context") {
                Some(ctx) => switch ctx.value("includeDeclaration") {
                    Some(v) => {
                        include_decl = v.is_bool() && v.get_bool();
                    },
                    None => {},
                },
                None => {},
            },
            None => {},
        };
        let d = feat::def_ref(&self.roots.at(h.r).pkg, h.m, h.off);
        let mut hits = Vector::<RefHit>::new();
        if d.node != astn::NODE_NONE {
            self.collect_refs(h.r, d, include_decl, &mut hits);
        }
        if hits.len() > self.max_results {
            // Bounded result batch (initializationOptions.maxResults).
            hits.truncate(self.max_results);
        }
        let mut arr = json::JSON::array();
        for i in 0..hits.len() {
            let rh = *hits.at(i);
            let l = feat::Loc { module: rh.m, start: rh.s, end: rh.e };
            arr.push_back(self.loc_json(rh.r as usize, &l));
        }
        respond(f, req.at_key("id"), &arr);
    }

    // Canonical file path of module `m` in root `r`.
    const fn self_def_file(self: &Self, r: usize, m: usize) str {
        return self.roots.at(r).files.at(m).as_str();
    }

    // True when `path` sits inside a workspace folder.
    fn in_workspace(self: &Self, path: str) bool {
        return self.folder_of(path).len() != 0;
    }

    fn on_prepare_rename(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let h = self.locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let pkg = &self.roots.at(h.r).pkg;
        let d = feat::def_ref(pkg, h.m, h.off);
        if d.node == astn::NODE_NONE {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        // Reject targets whose definition is outside the workspace (std/ffi of an installed compiler).
        let def_file = self.self_def_file(h.r, d.module as usize);
        if !self.in_workspace(def_file) {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let spo = feat::cursor_ref_span(pkg, h.m, h.off);
        if spo.is_none() {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let sp = spo.unwrap();
        let src = pkg.modules.at(h.m).source.as_str();
        let ls = text::line_starts(src);
        let mut res = json::JSON::object();
        res.emplace("range", range_json(src, &ls, sp.start, sp.end - sp.start));
        res.emplace("placeholder", json::JSON::str(src.slice(sp.start as usize, sp.end as usize)));
        respond(f, req.at_key("id"), &res);
    }

    fn on_rename(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let h = self.locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let mut new_name = "";
        switch req.value("params") {
            Some(params) => {
                new_name = params.value_str("newName");
            },
            None => {},
        };
        if !valid_ident(new_name) {
            send_error(f, req.at_key("id"), -32803, "the new name is not a valid identifier");
            return;
        }
        let pkg = &self.roots.at(h.r).pkg;
        let d = feat::def_ref(pkg, h.m, h.off);
        if d.node == astn::NODE_NONE {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        // A rename may only touch files inside the workspace: in a normal project the installed std/ffi
        // live next to the compiler binary (outside) and stay protected; in a workspace that contains its
        // own std (the compiler repo itself) renaming std symbols is legitimate first-party work.
        let def_file = self.self_def_file(h.r, d.module as usize);
        if !self.in_workspace(def_file) {
            send_error(f, req.at_key("id"), -32803, "cannot rename: the definition is outside the workspace (std/ffi)");
            return;
        }
        // The rename set: the definition plus its interface relations (an interface method renames
        // its declaration and every conformer together).
        let mut related = Vector::<astn::DefId>::new();
        feat::related_decls(pkg, d, &mut related);
        for i in 0..related.len() {
            let conflict = feat::rename_conflict(pkg, *related.at(i), new_name);
            if conflict.len() != 0 {
                send_error(f, req.at_key("id"), -32803, conflict.as_str());
                return;
            }
            let rf = self.self_def_file(h.r, related.at(i).module as usize);
            if !self.in_workspace(rf) {
                send_error(f, req.at_key("id"), -32803, "cannot rename: a related definition is outside the workspace");
                return;
            }
        }
        let mut hits = Vector::<RefHit>::new();
        for i in 0..related.len() {
            self.collect_refs(h.r, *related.at(i), true, &mut hits);
        }
        if hits.len() == 0 {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        // Group per canonical file, sort each group by DESCENDING offset, reject overlaps.
        let mut files = Vector::<String>::new();
        let mut per = Vector::<Vector<RefHit>>::new();
        for i in 0..hits.len() {
            let rh = *hits.at(i);
            let fp = self.roots.at(rh.r as usize).files.at(rh.m as usize).as_str();
            if !self.in_workspace(fp) {
                // Outside files never receive edits.
                continue;
            }
            let mut idx: i64 = -1;
            for k in 0..files.len() {
                if files.at(k).as_str() == fp {
                    idx = k as i64;
                }
            }
            if idx < 0 {
                files.push(String::from_str(fp));
                per.push(Vector::<RefHit>::new());
                idx = files.len() as i64 - 1;
            }
            per[idx as usize].push(rh);
        }
        let mut doc_changes = json::JSON::array();
        let mut changes = json::JSON::object();
        for k in 0..files.len() {
            // Insertion sort by descending start (groups are small).
            let g = &mut per[k];
            for a in 1..g.len() {
                let mut b = a;
                while b > 0 && g.at(b - 1).s < g.at(b).s {
                    let t1 = *g.at(b - 1);
                    let t2 = *g.at(b);
                    g.set(b - 1, t2);
                    g.set(b, t1);
                    b -= 1;
                }
            }
            for a in 1..g.len() {
                if g.at(a).e > g.at(a - 1).s {
                    send_error(f, req.at_key("id"), -32803, "rename would produce overlapping edits");
                    return;
                }
            }
            let rh0 = *g.at(0);
            let src = self.roots.at(rh0.r as usize).pkg.modules.at(rh0.m as usize).source.as_str();
            let ls = text::line_starts(src);
            let uri = text::path_to_uri(files.at(k).as_str());
            let mut edits = json::JSON::array();
            for a in 0..g.len() {
                let rh = *g.at(a);
                let mut te = json::JSON::object();
                te.emplace("range", range_json(src, &ls, rh.s, rh.e - rh.s));
                te.emplace("newText", json::JSON::str(new_name));
                edits.push_back(te);
            }
            if self.cap_doc_changes {
                let mut td = json::JSON::object();
                td.emplace("uri", json::JSON::str(uri.as_str()));
                let di = self.find_doc(uri.as_str());
                if di >= 0 {
                    td.emplace("version", json::JSON::integer(self.docs.at(di as usize).version));
                } else {
                    td.emplace("version", json::JSON::default());
                }
                let mut de = json::JSON::object();
                de.emplace("textDocument", td);
                de.emplace("edits", edits);
                doc_changes.push_back(de);
            } else {
                changes.emplace(uri.as_str(), edits);
            }
        }
        let mut we = json::JSON::object();
        if self.cap_doc_changes {
            we.emplace("documentChanges", doc_changes);
        } else {
            we.emplace("changes", changes);
        }
        respond(f, req.at_key("id"), &we);
    }

    // Formatting / semantic tokens / completion.

    fn on_formatting(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let mut uri = "";
        switch req.value("params") {
            Some(params) => switch params.value("textDocument") {
                Some(td) => {
                    uri = td.value_str("uri");
                },
                None => {},
            },
            None => {},
        };
        let di = self.find_doc(uri);
        if di < 0 {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let doc = self.docs.at(di as usize);
        let mut formatted = String::new();
        if !dutil::format_source(&doc.txt, doc.path.as_str(), 120, &mut formatted) {
            // Unparseable or comment-check tripped: never destructive.
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let mut arr = json::JSON::array();
        if formatted.as_str() != doc.txt.as_str() {
            let src = doc.txt.as_str();
            let ls = text::line_starts(src);
            let mut te = json::JSON::object();
            te.emplace("range", range_json(src, &ls, 0, src.len() as u32));
            te.emplace("newText", json::JSON::string(formatted));
            arr.push_back(te);
        }
        respond(f, req.at_key("id"), &arr);
    }

    // The encoded token data (LSP 5-int groups) for module `m` of root `r`, windowed to
    // [w_start, w_end) byte offsets.
    fn token_data(self: &Self, r: usize, m: usize, w_start: u32, w_end: u32) Vector<i64> {
        let pkg = &self.roots.at(r).pkg;
        let toks = feat::semantic_tokens(pkg, m);
        let src = pkg.modules.at(m).source.as_str();
        let ls = text::line_starts(src);
        let mut data = Vector::<i64>::new();
        let mut prev_line: u32 = 0;
        let mut prev_char: u32 = 0;
        for i in 0..toks.len() {
            let t = toks.at(i);
            if t.end <= w_start || t.start >= w_end {
                continue;
            }
            let pos = text::offset_to_pos(src, &ls, t.start);
            let mut dc = pos.character;
            if pos.line == prev_line {
                dc = pos.character - prev_char;
            }
            data.push(pos.line - prev_line);
            data.push(dc);
            data.push(text::utf16_len(src, t.start, t.end));
            data.push(t.ty);
            data.push(t.mods);
            prev_line = pos.line;
            prev_char = pos.character;
        }
        return data;
    }

    const fn data_json(data: &Vector<i64>) json::JSON {
        let mut arr = json::JSON::array();
        for i in 0..data.len() {
            arr.push_back(json::JSON::integer(*data.at(i)));
        }
        return arr;
    }

    // Remember `data` as URI's latest full result and hand back its new resultId.
    fn token_cache_put(self: &mut Self, uri: str, data: &Vector<i64>) u64 {
        self.tok_next += 1;
        let id = self.tok_next;
        let mut copy = Vector::<i64>::new();
        for i in 0..data.len() {
            copy.push(*data.at(i));
        }
        for i in 0..self.tok_uris.len() {
            if self.tok_uris.at(i).as_str() == uri {
                self.tok_ids.set(i, id);
                self.tok_data.set(i, copy);
                return id;
            }
        }
        self.tok_uris.push(String::from_str(uri));
        self.tok_ids.push(id);
        self.tok_data.push(copy);
        return id;
    }

    fn on_semantic_tokens(self: &mut Self, req: &json::JSON, f: *mut stdio::FILE, ranged: bool) {
        let nullv = json::JSON::default();
        let mut uri = "";
        switch req.value("params") {
            Some(params) => switch params.value("textDocument") {
                Some(td) => {
                    uri = td.value_str("uri");
                },
                None => {},
            },
            None => {},
        };
        if uri.len() == 0 {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let path = uri_doc_path(uri);
        let r = self.owning_root(path.as_str());
        if r < 0 {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let m = self.root_module(r as usize, path.as_str());
        if m < 0 {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        // Range request: keep only tokens intersecting the requested window.
        let src_len = self.roots.at(r as usize).pkg.modules.at(m as usize).source.len();
        let mut w_start: u32 = 0;
        let mut w_end = src_len as u32;
        if ranged {
            let h = self.locate_range(req);
            if h.ok {
                w_start = h.off;
                w_end = h.end;
            }
        }
        let data = self.token_data(r as usize, m as usize, w_start, w_end);
        let mut res = json::JSON::object();
        if !ranged && self.cap_delta_tokens {
            let id = self.token_cache_put(uri, &data);
            let mut ids = String::new();
            ids.push_u64(id);
            res.emplace("resultId", json::JSON::string(ids));
        }
        res.emplace("data", Server::data_json(&data));
        respond(f, req.at_key("id"), &res);
    }

    // SemanticTokens/full/delta: one splice edit (common prefix/suffix diff) against the cached
    // previous full result; an unknown or stale previousResultId answers with a fresh full result.
    fn on_semantic_tokens_delta(self: &mut Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let mut uri = "";
        let mut prev_id = "";
        switch req.value("params") {
            Some(params) => {
                switch params.value("textDocument") {
                    Some(td) => {
                        uri = td.value_str("uri");
                    },
                    None => {},
                };
                prev_id = params.value_str("previousResultId");
            },
            None => {},
        };
        if uri.len() == 0 {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let path = uri_doc_path(uri);
        let r = self.owning_root(path.as_str());
        let mut m: i32 = -1;
        if r >= 0 {
            m = self.root_module(r as usize, path.as_str());
        }
        if m < 0 {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let src_len = self.roots.at(r as usize).pkg.modules.at(m as usize).source.len();
        let data = self.token_data(r as usize, m as usize, 0, src_len as u32);
        // The cached previous result for this URI, when its id matches the request.
        let mut have_prev = false;
        let mut old = Vector::<i64>::new();
        for i in 0..self.tok_uris.len() {
            if self.tok_uris.at(i).as_str() == uri {
                let mut ids = String::new();
                ids.push_u64(*self.tok_ids.at(i));
                if ids.as_str() == prev_id {
                    have_prev = true;
                    for k in 0..self.tok_data.at(i).len() {
                        old.push(*self.tok_data.at(i).at(k));
                    }
                }
            }
        }
        let id = self.token_cache_put(uri, &data);
        let mut ids = String::new();
        ids.push_u64(id);
        let mut res = json::JSON::object();
        res.emplace("resultId", json::JSON::string(ids));
        if !have_prev {
            res.emplace("data", Server::data_json(&data));
            respond(f, req.at_key("id"), &res);
            return;
        }
        let mut p: usize = 0;
        while p < old.len() && p < data.len() && *old.at(p) == *data.at(p) {
            p += 1;
        }
        let mut s: usize = 0;
        while s < old.len() - p && s < data.len() - p && *old.at(old.len() - 1 - s) == *data.at(data.len() - 1 - s) {
            s += 1;
        }
        let mut edits = json::JSON::array();
        if p != old.len() || old.len() != data.len() {
            let mut ed = json::JSON::object();
            ed.emplace("start", json::JSON::integer(p as i64));
            ed.emplace("deleteCount", json::JSON::integer((old.len() - p - s) as i64));
            let mut ins = json::JSON::array();
            for i in p..data.len() - s {
                ins.push_back(json::JSON::integer(*data.at(i)));
            }
            ed.emplace("data", ins);
            edits.push_back(ed);
        }
        res.emplace("edits", edits);
        respond(f, req.at_key("id"), &res);
    }

    // Completion through a probe: splice `__lsp_c` (then `__lsp_c;` if that still does not parse) at the
    // cursor: the mid-edit buffer rarely parses; the probe usually makes it; compile a throwaway
    // package with that overlay, and read completions from it. The probe's own type error is irrelevant:
    // the typechecker still assigns the receiver's type. `member` picks member vs general completion.
    fn complete_via_probe(self: &Self, path: str, txt: str, off: u32, member: bool) Vector<feat::CompItem> {
        let mut out = Vector::<feat::CompItem>::new();
        let mut variant = 0;
        while variant < 2 {
            let mut synth = String::with_capacity(txt.len() + 9);
            synth.push_str(txt.slice(0, off as usize));
            synth.push_str("__lsp_c");
            if variant == 1 {
                synth.push_byte(b';');
            }
            synth.push_str(txt.slice(off as usize, txt.len()));
            let mut ovf = Vector::<String>::new();
            let mut ovt = Vector::<String>::new();
            for i in 0..self.docs.len() {
                ovf.push(self.docs.at(i).path.clone());
                if self.docs.at(i).path.as_str() == path {
                    ovt.push(synth.clone());
                } else {
                    ovt.push(self.docs.at(i).txt.clone());
                }
            }
            // Root parameters: the owning root when the doc has one, the per-file recipe otherwise.
            let mut rf = String::from_str(path);
            let mut rd = dir_of(path);
            let mut ad = self.folder_alt_of(path);
            let r = self.owning_root(path);
            if r >= 0 {
                rf = self.roots.at(r as usize).root_file.clone();
                rd = self.roots.at(r as usize).root_dir.clone();
                ad = self.roots.at(r as usize).alt_dir.clone();
            }
            let mut diags = Vector::<analysis::DiagRec>::new();
            let pkg = analysis::compile(
                rf.as_str(),
                rd.as_str(),
                ad.as_str(),
                self.std_dir.as_str(),
                self.target,
                ovf,
                ovt,
                "",
                &mut diags,
            );
            let mut parsed = false;
            for m in 0..pkg.modules.len() {
                let c = analysis::canon_path(pkg.modules.at(m).file.as_str());
                let hit = c.as_str() == path;
                if hit {
                    parsed = pkg.modules.at(m).has_ast;
                    if parsed {
                        if member {
                            out = feat::complete_member(&pkg, m, off);
                        } else {
                            out = feat::complete_general(&pkg, m, off);
                        }
                    }
                    break;
                }
            }
            if parsed {
                return out;
            }
            variant += 1;
        }
        return out;
    }

    // Stable sort-category prefix per CompletionItemKind: locals first, members, then functions,
    // types, modules, keywords last. The label breaks ties, so order is stable across revisions.
    const fn sort_prefix(kind: i32) str<'static> {
        if kind == 6 {
            // Locals / parameters.
            return "0";
        }
        if kind == 5 || kind == 2 || kind == 20 {
            // Fields, methods, enum members.
            return "1";
        }
        if kind == 3 {
            // Functions.
            return "2";
        }
        if kind == 22 || kind == 13 || kind == 7 || kind == 8 || kind == 21 {
            // Types, interfaces, constants.
            return "3";
        }
        if kind == 9 {
            // Modules.
            return "4";
        }
        if kind == 14 {
            // Keywords.
            return "9";
        }
        return "5";
    }

    // Render `items` as a CompletionList with stable sortText keys.
    fn completion_list(items: &Vector<feat::CompItem>) json::JSON {
        let mut arr = json::JSON::array();
        for i in 0..items.len() {
            let it = items.at(i);
            let mut o = json::JSON::object();
            o.emplace("label", json::JSON::str(it.label.as_str()));
            o.emplace("kind", json::JSON::integer(it.kind));
            if it.detail.len() != 0 {
                o.emplace("detail", json::JSON::str(it.detail.as_str()));
            }
            let mut st = String::from_str(Server::sort_prefix(it.kind));
            st.push_str(it.label.as_str());
            o.emplace("sortText", json::JSON::string(st));
            arr.push_back(o);
        }
        let mut list = json::JSON::object();
        list.emplace("isIncomplete", json::JSON::boolean(false));
        list.emplace("items", arr);
        return list;
    }

    const fn ident_byte(b: u8) bool {
        return b == b'_' || b >= b'a' && b <= b'z' || b >= b'A' && b <= b'Z' || b >= b'0' && b <= b'9';
    }

    // The attribute argument context at `off`: scanning back inside an unclosed '(' whose head word
    // is preceded by '@' yields that attribute's name ("" = not in an attribute argument list).
    fn attr_arg_context(txt: str, off: u32) String {
        let mut i = off as usize;
        let mut depth = 0;
        while i > 0 {
            let b = txt[i - 1];
            if b == b'\n' {
                return String::new();
            }
            if b == b')' {
                depth += 1;
            } else if b == b'(' {
                if depth == 0 {
                    break;
                }
                depth -= 1;
            }
            i -= 1;
        }
        if i == 0 {
            return String::new();
        }
        // The word (possibly dotted) before the '('.
        let e = i - 1;
        let mut s = e;
        while s > 0 && (Server::ident_byte(txt[s - 1]) || txt[s - 1] == b'.') {
            s -= 1;
        }
        if s == e || s == 0 || txt[s - 1] != b'@' {
            return String::new();
        }
        return String::from_str(txt.slice(s, e));
    }

    fn on_completion(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let mut moff: usize = 0;
        let mdi = self.manifest_hit(req, &mut moff);
        if mdi >= 0 {
            let mut arr = json::JSON::array();
            let items = btoml::completions(self.docs.at(mdi as usize).txt.as_str(), moff);
            for i in 0..items.len() {
                let mut it = json::JSON::object();
                it.emplace("label", json::JSON::str(items.at(i).label.as_str()));
                // Keyword.
                it.emplace("kind", json::JSON::integer(14));
                it.emplace("detail", json::JSON::str(items.at(i).doc.as_str()));
                arr.push_back(it);
            }
            let mut list = json::JSON::object();
            list.emplace("isIncomplete", json::JSON::boolean(false));
            list.emplace("items", arr);
            respond(f, req.at_key("id"), &list);
            return;
        }
        let mut uri = "";
        let mut line: i64 = 0;
        let mut ch: i64 = 0;
        switch req.value("params") {
            Some(params) => {
                switch params.value("textDocument") {
                    Some(td) => {
                        uri = td.value_str("uri");
                    },
                    None => {},
                };
                switch params.value("position") {
                    Some(pos) => {
                        line = pos.value_i64("line", 0);
                        ch = pos.value_i64("character", 0);
                    },
                    None => {},
                };
            },
            None => {},
        };
        let di = self.find_doc(uri);
        if di < 0 {
            let none = Vector::<feat::CompItem>::new();
            let list = Server::completion_list(&none);
            respond(f, req.at_key("id"), &list);
            return;
        }
        let txt = self.docs.at(di as usize).txt.as_str();
        let ls = text::line_starts(txt);
        let off = text::pos_to_offset(txt, &ls, line as u32, ch as u32);
        let path = self.docs.at(di as usize).path.as_str();
        // Context detection: walk back over the identifier being typed, then classify by what
        // precedes it: '@' (attribute), an attribute argument list, '.', '::', a leading
        // `import`, or a label quote. Everything else is general scope completion.
        let mut ws = off as usize;
        while ws > 0 && Server::ident_byte(txt[ws - 1]) {
            ws -= 1;
        }
        let prev = if ws > 0 {
            txt[ws - 1];
        } else {
            0u8;
        };
        // An attribute path may continue with '.': "@c.al<cursor>" walks back over "c."
        let mut attr_ws = ws;
        while attr_ws > 0 && (Server::ident_byte(txt[attr_ws - 1]) || txt[attr_ws - 1] == b'.') {
            attr_ws -= 1;
        }
        let at_attr = attr_ws > 0 && txt[attr_ws - 1] == b'@';
        let mut ln_start = ws;
        while ln_start > 0 && txt[ln_start - 1] != b'\n' {
            ln_start -= 1;
        }
        let line_head = txt.slice(ln_start, ws).trim();
        let mut items = Vector::<feat::CompItem>::new();
        let r = self.owning_root(path);
        let mut m: i32 = -1;
        if r >= 0 {
            m = self.root_module(r as usize, path);
        }
        let have_ast = m >= 0 && self.roots.at(r as usize).pkg.modules.at(m as usize).has_ast;
        if at_attr {
            items = feat::complete_attributes();
        } else if prev == b'\'' {
            if have_ast {
                items = feat::complete_labels(&self.roots.at(r as usize).pkg, m as usize, off);
            }
        } else if line_head == "import" {
            if r >= 0 {
                items = feat::complete_import_paths(&self.roots.at(r as usize).pkg);
            }
        } else {
            let actx = Server::attr_arg_context(txt, ws as u32);
            if actx.as_str() == "platform" {
                items = feat::complete_platform_args();
            } else if actx.as_str() == "arch" {
                items = feat::complete_arch_args();
            } else if actx.as_str() == "derive" {
                if have_ast {
                    items = feat::complete_interfaces(&self.roots.at(r as usize).pkg, m as usize);
                }
            } else {
                let dot = ws > 0 && txt[ws - 1] == b'.' && !(ws > 1 && txt[ws - 2] == b'.');
                let path2 = ws > 1 && txt[ws - 1] == b':' && txt[ws - 2] == b':';
                if dot || path2 {
                    items = self.complete_via_probe(path, txt, off, true);
                } else if have_ast {
                    items = feat::complete_general(&self.roots.at(r as usize).pkg, m as usize, off);
                } else {
                    // Broken buffer: complete from a probe build; keywords alone if even that fails.
                    items = self.complete_via_probe(path, txt, off, false);
                    if items.len() == 0 {
                        items = feat::complete_keywords();
                    }
                }
            }
        }
        let list = Server::completion_list(&items);
        respond(f, req.at_key("id"), &list);
    }

    // One lint fix (diags[k] of root r, module m) as a WorkspaceEdit JSON.
    fn fix_edit_json(self: &Self, r: usize, m: usize, k: usize) json::JSON {
        let src = self.roots.at(r).pkg.modules.at(m).source.as_str();
        let ls = text::line_starts(src);
        let uri = text::path_to_uri(self.roots.at(r).files.at(m).as_str());
        let d = self.roots.at(r).diags.at(k);
        let mut te = json::JSON::object();
        if d.fix_kind == 1 {
            te.emplace("range", range_json(src, &ls, d.fix_start, 0));
            te.emplace("newText", json::JSON::str("_"));
        } else if d.fix_kind == 2 {
            te.emplace("range", range_json(src, &ls, d.fix_start, 0));
            te.emplace("newText", json::JSON::str("const "));
        } else if d.fix_kind == 3 {
            te.emplace("range", range_json(src, &ls, d.fix_start, 0));
            te.emplace("newText", json::JSON::str(d.fix_text.as_str()));
        } else if d.fix_kind == 4 {
            te.emplace("range", range_json(src, &ls, d.fix_start, d.fix_end - d.fix_start));
            te.emplace("newText", json::JSON::str(d.fix_text.as_str()));
        } else {
            te.emplace("range", range_json(src, &ls, d.fix_start, d.fix_end - d.fix_start));
            te.emplace("newText", json::JSON::str(""));
        }
        let mut edits = json::JSON::array();
        edits.push_back(te);
        let mut changes = json::JSON::object();
        changes.emplace(uri.as_str(), edits);
        let mut we = json::JSON::object();
        we.emplace("changes", changes);
        return we;
    }

    // Every machine-applicable fix of module `m` as ONE WorkspaceEdit: sorted by descending start,
    // overlapping fixes dropped (first by position wins), so applying the set is always safe.
    fn fixall_edit_json(self: &Self, r: usize, m: usize) json::JSON {
        let src = self.roots.at(r).pkg.modules.at(m).source.as_str();
        let ls = text::line_starts(src);
        let uri = text::path_to_uri(self.roots.at(r).files.at(m).as_str());
        // Collect (start, end, k), insertion-sorted by DESCENDING start.
        let mut ks = Vector::<u32>::new();
        let mut ss = Vector::<u32>::new();
        let mut es = Vector::<u32>::new();
        let diags = &self.roots.at(r).diags;
        for k in 0..diags.len() {
            let d = diags.at(k);
            if d.module as usize != m || d.fix_kind < 0 || d.fix_kind > 4 {
                continue;
            }
            let fe = if d.fix_kind == 1 || d.fix_kind == 2 || d.fix_kind == 3 {
                d.fix_start;
            } else {
                d.fix_end;
            };
            let mut at = ks.len();
            while at > 0 && *ss.at(at - 1) < d.fix_start {
                at -= 1;
            }
            ks.insert(at, k as u32);
            ss.insert(at, d.fix_start);
            es.insert(at, fe);
        }
        let mut edits = json::JSON::array();
        let mut low: i64 = -1; // lowest start already emitted (descending walk): overlap guard
        for i in 0..ks.len() {
            if low >= 0 && (*es.at(i)) as i64 > low {
                // Overlaps the fix kept before it: drop it.
                continue;
            }
            let d = diags.at((*ks.at(i)) as usize);
            let mut te = json::JSON::object();
            if d.fix_kind == 1 {
                te.emplace("range", range_json(src, &ls, d.fix_start, 0));
                te.emplace("newText", json::JSON::str("_"));
            } else if d.fix_kind == 2 {
                te.emplace("range", range_json(src, &ls, d.fix_start, 0));
                te.emplace("newText", json::JSON::str("const "));
            } else if d.fix_kind == 3 {
                te.emplace("range", range_json(src, &ls, d.fix_start, 0));
                te.emplace("newText", json::JSON::str(d.fix_text.as_str()));
            } else if d.fix_kind == 4 {
                te.emplace("range", range_json(src, &ls, d.fix_start, d.fix_end - d.fix_start));
                te.emplace("newText", json::JSON::str(d.fix_text.as_str()));
            } else {
                te.emplace("range", range_json(src, &ls, d.fix_start, d.fix_end - d.fix_start));
                te.emplace("newText", json::JSON::str(""));
            }
            edits.push_back(te);
            low = d.fix_start;
        }
        let mut changes = json::JSON::object();
        changes.emplace(uri.as_str(), edits);
        let mut we = json::JSON::object();
        we.emplace("changes", changes);
        return we;
    }

    // The diagnostic echo attached to an action so the client pins it to its squiggle.
    fn diag_echo(self: &Self, r: usize, m: usize, k: usize) json::JSON {
        let src = self.roots.at(r).pkg.modules.at(m).source.as_str();
        let ls = text::line_starts(src);
        let d = self.roots.at(r).diags.at(k);
        let mut dj = json::JSON::object();
        dj.emplace("range", range_json(src, &ls, d.start, d.len));
        dj.emplace("severity", json::JSON::integer(d.severity));
        dj.emplace("source", json::JSON::str("super-c"));
        dj.emplace("message", json::JSON::str(d.msg.as_str()));
        let mut dl = json::JSON::array();
        dl.push_back(dj);
        return dl;
    }

    // The `name` inside the first single-quote pair of `msg` ("" when there is none).
    fn quoted_name(msg: str) str {
        let mut i: usize = 0;
        while i < msg.len() && msg[i] != b'\'' {
            i += 1;
        }
        if i >= msg.len() {
            return "";
        }
        let s = i + 1;
        let mut e = s;
        while e < msg.len() && msg[e] != b'\'' {
            e += 1;
        }
        if e >= msg.len() {
            return "";
        }
        return msg.slice(s, e);
    }

    // Code actions: machine-applicable lint fixes as `quickfix` actions, one `source.fixAll` action
    // covering the file's whole safe set, plus semantic quick fixes (add a missing import, insert a
    // missing interface method). `context.only` filters by kind; a client without code-action
    // LITERAL support gets nothing (this server defines no commands). With client resolveSupport for
    // `edit`, lint-fix actions return lazily and codeAction/resolve builds the edit after
    // revalidating the revision.
    fn on_code_action(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let mut arr = json::JSON::array();
        if !self.cap_action_literals {
            respond(f, req.at_key("id"), &arr);
            return;
        }
        let h = self.locate_range(req);
        if !h.ok {
            respond(f, req.at_key("id"), &arr);
            return;
        }
        // context.only: absent = everything; present = the listed kind prefixes.
        let mut want_quickfix = true;
        let mut want_fixall = true;
        switch req.value("params") {
            Some(params) => switch params.value("context") {
                Some(ctx) => switch ctx.value("only") {
                    Some(only) => {
                        if only.is_array() {
                            want_quickfix = false;
                            want_fixall = false;
                            for i in 0..only.size() {
                                if only.at(i).kind != json::JT_STRING {
                                    continue;
                                }
                                let kind = only.at(i).get_str();
                                if kind == "quickfix" || kind.len() == 0 {
                                    want_quickfix = true;
                                }
                                if kind == "source" || kind == "source.fixAll" || kind.len() == 0 {
                                    want_fixall = true;
                                }
                            }
                        }
                    },
                    None => {},
                },
                None => {},
            },
            None => {},
        };
        let src = self.roots.at(h.r).pkg.modules.at(h.m).source.as_str();
        let ls = text::line_starts(src);
        let uri = text::path_to_uri(self.roots.at(h.r).files.at(h.m).as_str());
        let diags = &self.roots.at(h.r).diags;
        let mut nfix: usize = 0;
        for k in 0..diags.len() {
            let d = diags.at(k);
            if d.module as usize != h.m {
                continue;
            }
            if d.fix_kind >= 0 && d.fix_kind <= 4 {
                nfix += 1;
            }
            let dend = d.start + d.len;
            if d.start > h.end || dend < h.off {
                // No overlap with the requested range.
                continue;
            }
            if want_quickfix && d.fix_kind >= 0 && d.fix_kind <= 4 {
                let mut title = String::from_str("Remove unused code");
                if d.fix_kind == 1 {
                    title.clear();
                    title.push_str("Prefix with '_'");
                } else if d.fix_kind == 2 {
                    title.clear();
                    title.push_str("Declare 'const fn'");
                } else if d.fix_kind == 3 {
                    title.clear();
                    title.push_str("Insert generated code");
                } else if d.fix_kind == 4 {
                    title.clear();
                    title.push_str("Apply fix");
                }
                let mut act = json::JSON::object();
                act.emplace("title", json::JSON::string(title));
                act.emplace("kind", json::JSON::str("quickfix"));
                act.emplace("diagnostics", self.diag_echo(h.r, h.m, k));
                if self.cap_action_resolve {
                    let mut data = json::JSON::object();
                    data.emplace("uri", json::JSON::str(uri.as_str()));
                    data.emplace("rev", json::JSON::integer(self.revision as i64));
                    data.emplace("diag", json::JSON::integer(k as i64));
                    act.emplace("data", data);
                } else {
                    act.emplace("edit", self.fix_edit_json(h.r, h.m, k));
                }
                arr.push_back(act);
            }
            // Semantic quick fixes from error diagnostics (always eager: the edits are cheap).
            if want_quickfix && d.severity == 1 {
                let nm = Server::quoted_name(d.msg.as_str());
                if nm.len() != 0 && d.msg.as_str().starts_with("cannot find") {
                    // Candidates come from EVERY built root: an unimported module is by definition
                    // outside this package's closure, so it usually lives in the workspace batch.
                    let own_path = self.roots.at(h.r).pkg.modules.at(h.m).path.as_str();
                    let mut cands = feat::import_candidates(&self.roots.at(h.r).pkg, h.m, nm);
                    for r2 in 0..self.roots.len() {
                        if r2 == h.r || !self.roots.at(r2).built || self.roots.at(r2).pkg.modules.len() == 0 {
                            continue;
                        }
                        let nmods = self.roots.at(r2).pkg.modules.len();
                        let extra = feat::import_candidates(&self.roots.at(r2).pkg, nmods, nm);
                        for x in 0..extra.len() {
                            if extra.at(x).as_str() == own_path {
                                continue;
                            }
                            let mut have = false;
                            for c0 in 0..cands.len() {
                                if cands.at(c0).as_str() == extra.at(x).as_str() {
                                    have = true;
                                }
                            }
                            if !have {
                                cands.push(extra.at(x).clone());
                            }
                        }
                    }
                    let at = feat::import_insert_at(&self.roots.at(h.r).pkg, h.m);
                    for c in 0..cands.len() {
                        if c >= 3 {
                            // Several candidates: offer the closest few, not a wall.
                            break;
                        }
                        let mut ins = String::from_str("import ");
                        ins.push_str(cands.at(c).as_str());
                        ins.push_str(";\n");
                        let mut te = json::JSON::object();
                        te.emplace("range", range_json(src, &ls, at, 0));
                        te.emplace("newText", json::JSON::string(ins));
                        let mut edits = json::JSON::array();
                        edits.push_back(te);
                        let mut changes = json::JSON::object();
                        changes.emplace(uri.as_str(), edits);
                        let mut we = json::JSON::object();
                        we.emplace("changes", changes);
                        let mut title = String::from_str("Import ");
                        title.push_str(cands.at(c).as_str());
                        let mut act = json::JSON::object();
                        act.emplace("title", json::JSON::string(title));
                        act.emplace("kind", json::JSON::str("quickfix"));
                        act.emplace("diagnostics", self.diag_echo(h.r, h.m, k));
                        act.emplace("edit", we);
                        arr.push_back(act);
                    }
                }
                if nm.len() != 0 && d.msg.as_str().starts_with("missing method") {
                    switch feat::iface_stub(&self.roots.at(h.r).pkg, h.m, d.start, nm) {
                        Some(stub) => {
                            let mut te = json::JSON::object();
                            te.emplace("range", range_json(src, &ls, stub.at, 0));
                            te.emplace("newText", json::JSON::str(stub.text.as_str()));
                            let mut edits = json::JSON::array();
                            edits.push_back(te);
                            let mut changes = json::JSON::object();
                            changes.emplace(uri.as_str(), edits);
                            let mut we = json::JSON::object();
                            we.emplace("changes", changes);
                            let mut title = String::from_str("Implement '");
                            title.push_str(nm);
                            title.push_str("'");
                            let mut act = json::JSON::object();
                            act.emplace("title", json::JSON::string(title));
                            act.emplace("kind", json::JSON::str("quickfix"));
                            act.emplace("diagnostics", self.diag_echo(h.r, h.m, k));
                            act.emplace("edit", we);
                            arr.push_back(act);
                        },
                        None => {},
                    };
                }
            }
        }
        if want_fixall && nfix != 0 {
            let mut act = json::JSON::object();
            act.emplace("title", json::JSON::str("Fix all Super-C quick fixes in this file"));
            act.emplace("kind", json::JSON::str("source.fixAll"));
            if self.cap_action_resolve {
                let mut data = json::JSON::object();
                data.emplace("uri", json::JSON::str(uri.as_str()));
                data.emplace("rev", json::JSON::integer(self.revision as i64));
                data.emplace("fixall", json::JSON::boolean(true));
                act.emplace("data", data);
            } else {
                act.emplace("edit", self.fixall_edit_json(h.r, h.m));
            }
            arr.push_back(act);
        }
        respond(f, req.at_key("id"), &arr);
    }

    // CodeAction/resolve: build the deferred `edit` after revalidating that nothing changed since
    // the action was offered (same revision, and the diagnostic still carries the same fix).
    fn on_code_action_resolve(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let po = req.value("params");
        if po.is_none() {
            send_error(f, req.at_key("id"), -32602, "missing code action");
            return;
        }
        let action = po.unwrap();
        let da = action.value("data");
        if da.is_none() {
            // Nothing deferred: hand the action back unchanged.
            respond(f, req.at_key("id"), action);
            return;
        }
        let data = da.unwrap();
        let uri = data.value_str("uri");
        let rev = data.value_i64("rev", -1);
        if rev != self.revision as i64 {
            send_error(f, req.at_key("id"), -32803, "the document changed; request code actions again");
            return;
        }
        let path = uri_doc_path(uri);
        let r = self.owning_root(path.as_str());
        let mut m: i32 = -1;
        if r >= 0 {
            m = self.root_module(r as usize, path.as_str());
        }
        if m < 0 {
            send_error(f, req.at_key("id"), -32803, "the document is no longer part of a built package");
            return;
        }
        let mut out = action.clone();
        let fixall = data.value("fixall").is_some();
        if fixall {
            out.emplace("edit", self.fixall_edit_json(r as usize, m as usize));
            respond(f, req.at_key("id"), &out);
            return;
        }
        let k = data.value_i64("diag", -1);
        let diags = &self.roots.at(r as usize).diags;
        if k < 0 || k as usize >= diags.len() || diags.at(k as usize).fix_kind < 0 {
            send_error(f, req.at_key("id"), -32803, "the diagnostic is gone; request code actions again");
            return;
        }
        out.emplace("edit", self.fix_edit_json(r as usize, m as usize, k as usize));
        respond(f, req.at_key("id"), &out);
    }

    // Project-state notifications.

    // Watched-file changes: a build.toml change reloads that folder's manifest (keeping the last
    // valid model when the new one fails to parse); a .spc create/change/delete invalidates the
    // roots that could own it. One rebuild round follows.
    fn on_watched_files(self: &mut Self, req: &json::JSON, f: *mut stdio::FILE) {
        let mut any = false;
        switch req.value("params") {
            Some(params) => switch params.value("changes") {
                Some(chs) => {
                    if chs.is_array() {
                        for i in 0..chs.size() {
                            let u = chs.at(i).value_str("uri");
                            if u.len() == 0 {
                                continue;
                            }
                            let p = uri_doc_path(u);
                            any = true;
                            if is_manifest_path(p.as_str()) {
                                self.reload_manifest_for(p.as_str());
                            } else if p.as_str().ends_with(".spc") {
                                // The owning packages are stale: force their rebuild.
                                for r in 0..self.roots.len() {
                                    if self.root_module(r, p.as_str()) >= 0 {
                                        self.roots[r].built = false;
                                    }
                                }
                            }
                        }
                    }
                },
                None => {},
            },
            None => {},
        };
        if any {
            self.rebuild_all(f, false);
        }
    }

    // Reload the manifest owning `manifest_path` (folder = its directory). An unparseable manifest
    // keeps the previous project model: the last valid model serves until the file parses again.
    fn reload_manifest_for(self: &mut Self, manifest_path: str) {
        let folder = dir_of(manifest_path);
        let mp = Server::abs_under(folder.as_str(), "build.toml");
        let mano = bman::load(mp.as_str());
        if mano.is_none() {
            // Invalid: keep the last valid model.
            return;
        }
        let man = mano.unwrap();
        let rf = Server::abs_under(folder.as_str(), man.root.as_str());
        let mut found = false;
        for r in 0..self.roots.len() {
            if self.roots.at(r).origin.len() == 0 && !self.roots.at(r).sweep && self.roots.at(r).ws.as_str() == folder.as_str() {
                found = true;
                if self.roots.at(r).root_file.as_str() != rf.as_str() {
                    self.roots[r].root_file = rf.clone();
                    self.roots[r].root_dir = dir_of(rf.as_str());
                }
                self.roots[r].built = false;
            }
        }
        if !found {
            // A manifest appeared in a folder that had none.
            let primary = folder.as_str() == self.ws_root.as_str();
            let got = self.add_manifest_root(
                folder.as_str(),
                if primary {
                    0;
                } else {
                    -1;
                },
            );
            if primary && got {
                self.has_manifest = true;
            }
        }
        self.set_out_skip(folder.as_str(), man.out_dir.as_str());
    }

    // Folder add/remove: added folders gain manifest/sweep roots on the next round; removed folders
    // drop every root they own.
    fn on_folders_changed(self: &mut Self, req: &json::JSON, f: *mut stdio::FILE) {
        switch req.value("params") {
            Some(params) => switch params.value("event") {
                Some(ev) => {
                    switch ev.value("added") {
                        Some(ad) => {
                            if ad.is_array() {
                                for i in 0..ad.size() {
                                    let u = ad.at(i).value_str("uri");
                                    if u.len() != 0 {
                                        let p = text::uri_to_path(u);
                                        let c = analysis::canon_path(p.as_str());
                                        let mut have = false;
                                        for k in 0..self.folders.len() {
                                            if self.folders.at(k).as_str() == c.as_str() {
                                                have = true;
                                            }
                                        }
                                        if !have {
                                            let cf = c.clone();
                                            self.folders.push(c);
                                            let _ = self.add_manifest_root(cf.as_str(), -1);
                                        }
                                    }
                                }
                            }
                        },
                        None => {},
                    };
                    switch ev.value("removed") {
                        Some(rm) => {
                            if rm.is_array() {
                                for i in 0..rm.size() {
                                    let u = rm.at(i).value_str("uri");
                                    if u.len() == 0 {
                                        continue;
                                    }
                                    let p = text::uri_to_path(u);
                                    let c = analysis::canon_path(p.as_str());
                                    let mut k: usize = 0;
                                    while k < self.folders.len() {
                                        if self.folders.at(k).as_str() == c.as_str() {
                                            let old = self.folders.remove(k).unwrap();
                                            old.free();
                                        } else {
                                            k += 1;
                                        }
                                    }
                                    let mut r: usize = 0;
                                    while r < self.roots.len() {
                                        if self.roots.at(r).ws.as_str() == c.as_str() {
                                            self.roots.remove(r).unwrap().free();
                                        } else {
                                            r += 1;
                                        }
                                    }
                                }
                            }
                        },
                        None => {},
                    };
                },
                None => {},
            },
            None => {},
        };
        if self.folders.len() != 0 {
            self.ws_root = self.folders.at(0).clone();
        }
        self.rebuild_all(f, false);
    }

    // Navigation and information requests.

    fn on_type_definition(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let h = self.locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        switch feat::type_definition(&self.roots.at(h.r).pkg, h.m, h.off) {
            Some(l) => {
                let lj = self.loc_json(h.r, &l);
                respond(f, req.at_key("id"), &lj);
            },
            None => {
                respond(f, req.at_key("id"), &nullv);
            },
        };
    }

    fn on_implementation(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let h = self.locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let locs = feat::implementations(&self.roots.at(h.r).pkg, h.m, h.off);
        let mut arr = json::JSON::array();
        for i in 0..locs.len() {
            arr.push_back(self.loc_json(h.r, locs.at(i)));
        }
        respond(f, req.at_key("id"), &arr);
    }

    fn on_document_highlight(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let h = self.locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let locs = feat::document_highlights(&self.roots.at(h.r).pkg, h.m, h.off);
        let src = self.roots.at(h.r).pkg.modules.at(h.m).source.as_str();
        let ls = text::line_starts(src);
        let mut arr = json::JSON::array();
        for i in 0..locs.len() {
            let l = locs.at(i);
            let mut o = json::JSON::object();
            o.emplace("range", range_json(src, &ls, l.start, l.end - l.start));
            // Text.
            o.emplace("kind", json::JSON::integer(1));
            arr.push_back(o);
        }
        respond(f, req.at_key("id"), &arr);
    }

    fn on_signature_help(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let h = self.locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        switch feat::signature_help(&self.roots.at(h.r).pkg, h.m, h.off) {
            Some(si) => {
                let mut params = json::JSON::array();
                for i in 0..si.params.len() {
                    let mut po = json::JSON::object();
                    po.emplace("label", json::JSON::str(si.params.at(i).as_str()));
                    params.push_back(po);
                }
                let mut sig = json::JSON::object();
                sig.emplace("label", json::JSON::str(si.label.as_str()));
                sig.emplace("parameters", params);
                let mut sigs = json::JSON::array();
                sigs.push_back(sig);
                let mut res = json::JSON::object();
                res.emplace("signatures", sigs);
                res.emplace("activeSignature", json::JSON::integer(0));
                res.emplace("activeParameter", json::JSON::integer(si.active));
                respond(f, req.at_key("id"), &res);
            },
            None => {
                respond(f, req.at_key("id"), &nullv);
            },
        };
    }

    // Hierarchical DocumentSymbol trees when the client negotiated them, flat SymbolInformation
    // otherwise.
    fn on_document_symbol(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let mut uri = "";
        switch req.value("params") {
            Some(params) => switch params.value("textDocument") {
                Some(td) => {
                    uri = td.value_str("uri");
                },
                None => {},
            },
            None => {},
        };
        if uri.len() == 0 {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let path = uri_doc_path(uri);
        let r = self.owning_root(path.as_str());
        if r < 0 {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let m = self.root_module(r as usize, path.as_str());
        if m < 0 {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let pkg = &self.roots.at(r as usize).pkg;
        let syms = feat::document_symbols(pkg, m as usize);
        let src = pkg.modules.at(m as usize).source.as_str();
        let ls = text::line_starts(src);
        if self.cap_hier_symbols {
            let mut arr = json::JSON::array();
            for i in 0..syms.len() {
                if syms.at(i).parent >= 0 {
                    continue;
                }
                let s = syms.at(i);
                let mut o = json::JSON::object();
                o.emplace("name", json::JSON::str(s.name.as_str()));
                if s.detail.len() != 0 {
                    o.emplace("detail", json::JSON::str(s.detail.as_str()));
                }
                o.emplace("kind", json::JSON::integer(s.kind));
                o.emplace("range", range_json(src, &ls, s.start, s.end - s.start));
                o.emplace("selectionRange", range_json(src, &ls, s.sel_start, s.sel_end - s.sel_start));
                let mut kids = json::JSON::array();
                for k in 0..syms.len() {
                    if syms.at(k).parent != i as i32 {
                        continue;
                    }
                    let c = syms.at(k);
                    let mut co = json::JSON::object();
                    co.emplace("name", json::JSON::str(c.name.as_str()));
                    co.emplace("kind", json::JSON::integer(c.kind));
                    co.emplace("range", range_json(src, &ls, c.start, c.end - c.start));
                    co.emplace("selectionRange", range_json(src, &ls, c.sel_start, c.sel_end - c.sel_start));
                    kids.push_back(co);
                }
                o.emplace("children", kids);
                arr.push_back(o);
            }
            respond(f, req.at_key("id"), &arr);
            return;
        }
        let mut arr = json::JSON::array();
        for i in 0..syms.len() {
            let s = syms.at(i);
            let mut loc = json::JSON::object();
            loc.emplace("uri", json::JSON::str(uri));
            loc.emplace("range", range_json(src, &ls, s.sel_start, s.sel_end - s.sel_start));
            let mut o = json::JSON::object();
            o.emplace("name", json::JSON::str(s.name.as_str()));
            o.emplace("kind", json::JSON::integer(s.kind));
            o.emplace("location", loc);
            arr.push_back(o);
        }
        respond(f, req.at_key("id"), &arr);
    }

    fn on_workspace_symbol(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let mut query = "";
        switch req.value("params") {
            Some(params) => {
                query = params.value_str("query");
            },
            None => {},
        };
        let mut arr = json::JSON::array();
        let mut seen = Vector::<String>::new(); // "file:start" keys already emitted (dedup across roots)
        for r in 0..self.roots.len() {
            if !self.roots.at(r).built || self.roots.at(r).pkg.modules.len() == 0 {
                continue;
            }
            let mut hits = Vector::<feat::WsSym>::new();
            feat::workspace_symbols(&self.roots.at(r).pkg, query, self.max_results, &mut hits);
            for i in 0..hits.len() {
                let hsym = hits.at(i);
                let file = self.roots.at(r).files.at(hsym.module as usize).as_str();
                if !self.in_workspace(file) {
                    // Std/ffi noise stays out of workspace symbol lists.
                    continue;
                }
                let mut key = String::from_str(file);
                key.push_byte(b':');
                key.push_i64(hsym.start);
                let mut dup = false;
                for q in 0..seen.len() {
                    if seen.at(q).as_str() == key.as_str() {
                        dup = true;
                    }
                }
                if dup {
                    key.free();
                    continue;
                }
                seen.push(key);
                let l = feat::Loc { module: hsym.module, start: hsym.start, end: hsym.end };
                let mut o = json::JSON::object();
                o.emplace("name", json::JSON::str(hsym.name.as_str()));
                o.emplace("kind", json::JSON::integer(hsym.kind));
                o.emplace("location", self.loc_json(r, &l));
                arr.push_back(o);
                if arr.size() >= 256 {
                    break;
                }
            }
            if arr.size() >= 256 {
                break;
            }
        }
        respond(f, req.at_key("id"), &arr);
    }

    fn on_folding_range(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let mut uri = "";
        switch req.value("params") {
            Some(params) => switch params.value("textDocument") {
                Some(td) => {
                    uri = td.value_str("uri");
                },
                None => {},
            },
            None => {},
        };
        let path = uri_doc_path(uri);
        let r = self.owning_root(path.as_str());
        if r < 0 {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let m = self.root_module(r as usize, path.as_str());
        if m < 0 {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let pkg = &self.roots.at(r as usize).pkg;
        let locs = feat::folding_ranges(pkg, m as usize);
        let src = pkg.modules.at(m as usize).source.as_str();
        let ls = text::line_starts(src);
        let mut arr = json::JSON::array();
        for i in 0..locs.len() {
            let l = locs.at(i);
            let s = text::offset_to_pos(src, &ls, l.start);
            let e = text::offset_to_pos(src, &ls, l.end);
            if e.line <= s.line {
                continue;
            }
            let mut o = json::JSON::object();
            o.emplace("startLine", json::JSON::integer(s.line));
            o.emplace("endLine", json::JSON::integer(e.line));
            arr.push_back(o);
        }
        respond(f, req.at_key("id"), &arr);
    }

    fn on_selection_range(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let mut uri = "";
        let mut positions = json::JSON::array();
        switch req.value("params") {
            Some(params) => {
                switch params.value("textDocument") {
                    Some(td) => {
                        uri = td.value_str("uri");
                    },
                    None => {},
                };
                switch params.value("positions") {
                    Some(ps) => {
                        positions = ps.clone();
                    },
                    None => {},
                };
            },
            None => {},
        };
        let path = uri_doc_path(uri);
        let r = self.owning_root(path.as_str());
        if r < 0 || !positions.is_array() {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let m = self.root_module(r as usize, path.as_str());
        if m < 0 {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let pkg = &self.roots.at(r as usize).pkg;
        let src = pkg.modules.at(m as usize).source.as_str();
        let ls = text::line_starts(src);
        let mut arr = json::JSON::array();
        for pi in 0..positions.size() {
            let pv = positions.at(pi);
            let off = text::pos_to_offset(src, &ls, pv.value_i64("line", 0) as u32, pv.value_i64("character", 0) as u32);
            let chain = feat::selection_ranges(pkg, m as usize, off);
            // Innermost-first chain nests via `parent`.
            let mut cur = json::JSON::default();
            let mut i = chain.len();
            while i > 0 {
                i -= 1;
                let l = chain.at(i);
                let mut o = json::JSON::object();
                o.emplace("range", range_json(src, &ls, l.start, l.end - l.start));
                if !cur.is_null() {
                    o.emplace("parent", cur.clone());
                }
                cur = o;
            }
            if cur.is_null() {
                let mut o = json::JSON::object();
                o.emplace("range", range_json(src, &ls, off, 0));
                cur = o;
            }
            arr.push_back(cur);
        }
        respond(f, req.at_key("id"), &arr);
    }

    fn on_inlay_hint(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let h = self.locate_range(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let pkg = &self.roots.at(h.r).pkg;
        let hints = feat::inlay_hints(pkg, h.m, h.off, h.end);
        let src = pkg.modules.at(h.m).source.as_str();
        let ls = text::line_starts(src);
        let mut arr = json::JSON::array();
        for i in 0..hints.len() {
            let hh = hints.at(i);
            let pos = text::offset_to_pos(src, &ls, hh.off);
            let mut po = json::JSON::object();
            po.emplace("line", json::JSON::integer(pos.line));
            po.emplace("character", json::JSON::integer(pos.character));
            let mut o = json::JSON::object();
            o.emplace("position", po);
            o.emplace("label", json::JSON::str(hh.label.as_str()));
            // Type.
            o.emplace("kind", json::JSON::integer(1));
            arr.push_back(o);
        }
        respond(f, req.at_key("id"), &arr);
    }
    // Pull diagnostics.

    // The complete current diagnostic list for `uri`, assembled from every built root's retained
    // records: exactly the sources a publish round uses.
    fn current_diags_for(self: &Self, uri: str) json::JSON {
        let mut ps = PubSet { uris: Vector::<String>::new(), arrs: Vector::<json::JSON>::new() };
        for r in 0..self.roots.len() {
            if self.roots.at(r).built {
                self.publish_root_diags(r, &mut ps);
            }
        }
        self.publish_manifest_diags(&mut ps);
        // Published URIs carry the CANONICAL path; normalize the request URI the same way.
        let want = text::path_to_uri(uri_doc_path(uri).as_str());
        for i in 0..ps.uris.len() {
            if ps.uris.at(i).as_str() == want.as_str() || ps.uris.at(i).as_str() == uri {
                return ps.arrs.at(i).clone();
            }
        }
        return json::JSON::array();
    }

    const fn fnv64(s: str) u64 {
        let mut h: u64 = 0xCBF29CE484222325;
        for i in 0..s.len() {
            h = (h ^ s[i] as u64) * 0x100000001B3;
        }
        return h;
    }

    // TextDocument/diagnostic: a full report with a content-derived stable resultId; when the
    // client's previousResultId matches the current content, an `unchanged` report instead.
    fn on_pull_diagnostic(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let mut uri = "";
        let mut prev = "";
        switch req.value("params") {
            Some(params) => {
                switch params.value("textDocument") {
                    Some(td) => {
                        uri = td.value_str("uri");
                    },
                    None => {},
                };
                prev = params.value_str("previousResultId");
            },
            None => {},
        };
        if uri.len() == 0 {
            send_error(f, req.at_key("id"), -32602, "textDocument.uri is required");
            return;
        }
        let arr = self.current_diags_for(uri);
        let dumped = arr.dump(false);
        let mut rid = String::from_str("d");
        rid.push_u64(Server::fnv64(dumped.as_str()));
        let mut res = json::JSON::object();
        if prev.len() != 0 && prev == rid.as_str() {
            res.emplace("kind", json::JSON::str("unchanged"));
            res.emplace("resultId", json::JSON::string(rid));
            respond(f, req.at_key("id"), &res);
            return;
        }
        res.emplace("kind", json::JSON::str("full"));
        res.emplace("resultId", json::JSON::string(rid));
        res.emplace("items", arr);
        respond(f, req.at_key("id"), &res);
    }

    // Call and type hierarchy.

    // A CallHierarchyItem / TypeHierarchyItem for declaration `d` in root `r`. `data` carries the
    // defining file's URI and the name-span offset, so a later incoming/outgoing/related request can
    // re-resolve the declaration on the current revision.
    fn hier_item(self: &Self, r: usize, d: astn::DefId, kind: i64) json::JSON {
        let pkg = &self.roots.at(r).pkg;
        let a = pkg.module_ast_const(d.module);
        let nm = feat::decl_name(a, d.node);
        let full = unsafe (&*a).at_const(d.node).span;
        let nsp = if nm != astn::NODE_NONE {
            unsafe (&*a).at_const(nm).span;
        } else {
            full;
        };
        let src = pkg.modules.at(d.module as usize).source.as_str();
        let ls = text::line_starts(src);
        let mut o = json::JSON::object();
        o.emplace("name", json::JSON::str(src.slice(nsp.start as usize, nsp.end as usize)));
        o.emplace("kind", json::JSON::integer(kind));
        let uri = text::path_to_uri(self.roots.at(r).files.at(d.module as usize).as_str());
        o.emplace("uri", json::JSON::str(uri.as_str()));
        o.emplace("range", range_json(src, &ls, full.start, full.end - full.start));
        o.emplace("selectionRange", range_json(src, &ls, nsp.start, nsp.end - nsp.start));
        let mut data = json::JSON::object();
        data.emplace("uri", json::JSON::string(uri));
        data.emplace("off", json::JSON::integer(nsp.start));
        o.emplace("data", data);
        return o;
    }

    // The (root, module, offset) a hierarchy item's `data` names, re-resolved on the current state.
    fn hier_locate(self: &Self, req: &json::JSON) Hit {
        let miss = Hit { ok: false, r: 0, m: 0, off: 0, end: 0 };
        let po = req.value("params");
        if po.is_none() {
            return miss;
        }
        let io = po.unwrap().value("item");
        if io.is_none() {
            return miss;
        }
        let da = io.unwrap().value("data");
        if da.is_none() {
            return miss;
        }
        let uri = da.unwrap().value_str("uri");
        let off = da.unwrap().value_i64("off", -1);
        if uri.len() == 0 || off < 0 {
            return miss;
        }
        let path = uri_doc_path(uri);
        let r = self.owning_root(path.as_str());
        if r < 0 {
            return miss;
        }
        let m = self.root_module(r as usize, path.as_str());
        if m < 0 {
            return miss;
        }
        return Hit { ok: true, r: r as usize, m: m as usize, off: off as u32, end: off as u32 };
    }

    fn on_prepare_call_hierarchy(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let h = self.locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let pkg = &self.roots.at(h.r).pkg;
        let mut d = feat::def_ref(pkg, h.m, h.off);
        let named_fn = d.node != astn::NODE_NONE && unsafe (&*pkg.module_ast_const(d.module)).at_const(d.node).kind == astn::NodeKind::NODE_FUNCTION;
        if !named_fn {
            // Not on a function name: the function whose body contains the cursor.
            let fnid = feat::enclosing_function(pkg, h.m, h.off);
            if fnid == astn::NODE_NONE {
                respond(f, req.at_key("id"), &nullv);
                return;
            }
            d = astn::DefId { module: h.m as astn::ModuleId, node: fnid };
        }
        let mut arr = json::JSON::array();
        arr.push_back(self.hier_item(h.r, d, 12));
        respond(f, req.at_key("id"), &arr);
    }

    fn on_incoming_calls(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let h = self.hier_locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let pkg = &self.roots.at(h.r).pkg;
        let d = feat::def_ref(pkg, h.m, h.off);
        if d.node == astn::NODE_NONE {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let mut hits = Vector::<RefHit>::new();
        self.collect_refs(h.r, d, false, &mut hits);
        // Group reference sites by their enclosing function (RefHit.s reused as the fn node id).
        let mut froms = Vector::<RefHit>::new();
        let mut ranges = Vector::<json::JSON>::new();
        for i in 0..hits.len() {
            let rh = *hits.at(i);
            let fnid = feat::enclosing_function(&self.roots.at(rh.r as usize).pkg, rh.m as usize, rh.s);
            if fnid == astn::NODE_NONE {
                continue;
            }
            let src = self.roots.at(rh.r as usize).pkg.modules.at(rh.m as usize).source.as_str();
            let ls = text::line_starts(src);
            let rj = range_json(src, &ls, rh.s, rh.e - rh.s);
            let mut gi: i64 = -1;
            for k in 0..froms.len() {
                if froms.at(k).r == rh.r && froms.at(k).m == rh.m && froms.at(k).s == fnid {
                    gi = k as i64;
                }
            }
            if gi < 0 {
                froms.push(RefHit { r: rh.r, m: rh.m, s: fnid, e: 0 });
                ranges.push(json::JSON::array());
                gi = froms.len() as i64 - 1;
            }
            ranges[gi as usize].push_back(rj);
        }
        let mut arr = json::JSON::array();
        for k in 0..froms.len() {
            let g = *froms.at(k);
            let fd = astn::DefId { module: g.m as astn::ModuleId, node: g.s };
            let mut o = json::JSON::object();
            o.emplace("from", self.hier_item(g.r as usize, fd, 12));
            o.emplace("fromRanges", ranges.at(k).clone());
            arr.push_back(o);
        }
        respond(f, req.at_key("id"), &arr);
    }

    fn on_outgoing_calls(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let h = self.hier_locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let pkg = &self.roots.at(h.r).pkg;
        let d = feat::def_ref(pkg, h.m, h.off);
        if d.node == astn::NODE_NONE {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let calls = feat::calls_in(pkg, d.module as usize, d.node);
        let src = pkg.modules.at(d.module as usize).source.as_str();
        let ls = text::line_starts(src);
        let mut tos = Vector::<astn::DefId>::new();
        let mut ranges = Vector::<json::JSON>::new();
        for i in 0..calls.len() {
            let c = calls.at(i);
            let mut gi: i64 = -1;
            for k in 0..tos.len() {
                if tos.at(k).module == c.callee.module && tos.at(k).node == c.callee.node {
                    gi = k as i64;
                }
            }
            if gi < 0 {
                tos.push(c.callee);
                ranges.push(json::JSON::array());
                gi = tos.len() as i64 - 1;
            }
            ranges[gi as usize].push_back(range_json(src, &ls, c.start, c.end - c.start));
        }
        let mut arr = json::JSON::array();
        for k in 0..tos.len() {
            let mut o = json::JSON::object();
            o.emplace("to", self.hier_item(h.r, *tos.at(k), 12));
            o.emplace("fromRanges", ranges.at(k).clone());
            arr.push_back(o);
        }
        respond(f, req.at_key("id"), &arr);
    }

    fn on_prepare_type_hierarchy(self: &Self, req: &json::JSON, f: *mut stdio::FILE) {
        let nullv = json::JSON::default();
        let h = self.locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let pkg = &self.roots.at(h.r).pkg;
        let d = feat::def_ref(pkg, h.m, h.off);
        if d.node == astn::NODE_NONE {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let k = unsafe (&*pkg.module_ast_const(d.module)).at_const(d.node).kind;
        let mut kind: i64 = 0;
        if k == astn::NodeKind::NODE_STRUCT {
            // Struct.
            kind = 23;
        } else if k == astn::NodeKind::NODE_ENUM {
            // Enum.
            kind = 10;
        } else if k == astn::NodeKind::NODE_INTERFACE {
            // Interface.
            kind = 11;
        } else {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let mut arr = json::JSON::array();
        arr.push_back(self.hier_item(h.r, d, kind));
        respond(f, req.at_key("id"), &arr);
    }

    // typeHierarchy/supertypes (`up` = true): the interfaces a type conforms to.
    // typeHierarchy/subtypes: an interface's conforming types.
    fn on_type_hierarchy_related(self: &Self, req: &json::JSON, f: *mut stdio::FILE, up: bool) {
        let nullv = json::JSON::default();
        let h = self.hier_locate(req);
        if !h.ok {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let pkg = &self.roots.at(h.r).pkg;
        let d = feat::def_ref(pkg, h.m, h.off);
        if d.node == astn::NODE_NONE {
            respond(f, req.at_key("id"), &nullv);
            return;
        }
        let locs = if up {
            feat::type_ifaces(pkg, d);
        } else {
            feat::iface_conformers(pkg, d);
        };
        let mut arr = json::JSON::array();
        for i in 0..locs.len() {
            let l = locs.at(i);
            // The name span resolves back to the declaration it names.
            let rd = feat::def_ref(pkg, l.module as usize, l.start);
            if rd.node == astn::NODE_NONE {
                continue;
            }
            let k = unsafe (&*pkg.module_ast_const(rd.module)).at_const(rd.node).kind;
            let mut kind: i64 = 23;
            if k == astn::NodeKind::NODE_INTERFACE {
                kind = 11;
            } else if k == astn::NodeKind::NODE_ENUM {
                kind = 10;
            }
            arr.push_back(self.hier_item(h.r, rd, kind));
        }
        respond(f, req.at_key("id"), &arr);
    }
}
