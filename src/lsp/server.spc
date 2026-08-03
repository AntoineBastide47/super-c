// `super-c lsp`: a Language Server Protocol server over stdio. Single-threaded and synchronous -- a full
// codegen-free recompile of the workspace takes tens of milliseconds at worst (this repo) so every
// document change rebuilds and republishes diagnostics immediately; no incremental state, no debounce.
// The process chdir()s to the workspace root at initialize, so manifest discovery, import rooting and
// the src/ alt-root convention behave exactly like CLI runs from the project root.
import stdio;
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
/// the manifest closure, or THE workspace-batch root (sweep=true, origin "") -- ONE shared package for
/// every closed .spc no other package owns, the `super-c lint` one-package recipe. The batch replaced
/// the per-file sweep roots, whose per-file prelude + closure copies held ~1 GB on this repo.
pub struct Root {
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
}

extend Root as Free {
    pub fn free(self: &mut Self) {
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

pub struct Server {
    pub docs: Vector<Doc>,
    pub roots: Vector<Root>, // roots[0] is the manifest root when has_manifest
    pub has_manifest: bool,
    pub std_dir: *const char,
    pub target: i32,
    pub published: Vector<String>, // URIs whose last publish was non-empty (for clearing)
    pub ws_root: String, // canonical workspace root ("" before initialize); rename edits stay inside it
    pub out_skip: String, // the manifest's out-dir name (the workspace sweep skips it)
    pub shutdown_seen: bool,
}

extend Server as Free {
    pub fn free(self: &mut Self) {
        self.docs.free();
        self.roots.free();
        self.published.free();
        self.ws_root.free();
        self.out_skip.free();
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

type RB = Array<char, 4096>;

// Canonicalize `path` via realpath; a file not on disk yet keeps the given form.
fn canon(path: str) String {
    let mut pb = String::from_str(path);
    let mut rb = RB {};
    if unsafe shim::sc_realpath(pb.cstr(), &mut rb[0]) != null {
        return String::from_cstr(&rb[0]);
    }
    return pb;
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

fn is_dir(path: str) bool {
    let mut p = String::from_str(path);
    return unsafe shim::sc_stat_isdir(p.cstr()) == 1;
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
    fn is_batch(self: &Self, r: usize) bool {
        return self.roots.at(r).sweep && self.roots.at(r).origin.len() == 0;
    }

    // First BUILT root containing `path` (manifest root first; the workspace batch LAST, so an open
    // doc's per-file root -- built from the live overlay -- wins over the batch's disk-built copy), -1 if none.
    fn owning_root(self: &Self, path: str) i32 {
        for r in 0..self.roots.len() {
            if !self.is_batch(r) && self.roots.at(r).built && self.root_module(r, path) >= 0 {
                return r as i32;
            }
        }
        for r in 0..self.roots.len() {
            if self.is_batch(r) && self.roots.at(r).built && self.root_module(r, path) >= 0 {
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
            // server; giving it a package root made the parser read TOML as Super-C and report
            // "expected top-level item" on its first line.
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
            let mut alt = "";
            if is_dir("src") {
                alt = "src";
            }
            self.roots.push(
                Root {
                    root_file: String::from_str(path),
                    root_dir: dir_of(path),
                    alt_dir: String::from_str(alt),
                    origin: String::from_str(path),
                    sweep: false,
                    members: Vector::<String>::new(),
                    pkg: loader::Package::new(),
                    files: Vector::<String>::new(),
                    diags: Vector::<analysis::DiagRec>::new(),
                    built: false,
                },
            );
        }
        self.ensure_sweep_roots();
    }

    // The workspace sweep: every .spc under the build.toml folder that no other package owns joins
    // THE batch root -- one shared package (the `super-c lint` recipe) instead of a resident package
    // per file. Hidden entries and the manifest out-dir are skipped. The batch rebuilds only when its
    // member set changes (a file appears/vanishes, a doc opens into a per-file root or closes back);
    // otherwise its cached diagnostics republish.
    fn ensure_sweep_roots(self: &mut Self) {
        if !self.has_manifest {
            return;
        }
        let mut alt = "";
        if is_dir("src") {
            alt = "src";
        }
        let mut cand = Vector::<String>::new();
        self.sweep_dir(".", &mut cand);
        cand.sort_by(path_cmp);
        let mut b: i64 = -1;
        for r in 0..self.roots.len() {
            if self.is_batch(r) {
                b = r as i64;
            }
        }
        if b < 0 {
            if cand.len() == 0 {
                return;
            }
            self.roots.push(
                Root {
                    root_file: String::new(),
                    root_dir: String::from_str("."),
                    alt_dir: String::from_str(alt),
                    origin: String::new(),
                    sweep: true,
                    members: cand,
                    pkg: loader::Package::new(),
                    files: Vector::<String>::new(),
                    diags: Vector::<analysis::DiagRec>::new(),
                    built: false,
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

    fn sweep_dir(self: &mut Self, dir: str, cand: &mut Vector<String>) {
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
        for i in 0..names.len() {
            let mut p = String::new();
            if dir != "." {
                p.push_str(dir);
                p.push_byte(b'/');
            }
            p.push_string(names.at(i));
            if dir == "." && p.as_str() == self.out_skip.as_str() {
                continue;
            }
            if unsafe shim::sc_stat_isdir(p.cstr()) == 1 {
                self.sweep_dir(p.as_str(), cand);
            } else if p.as_str().ends_with(".spc") {
                let cp = canon(p.as_str());
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
                if keep && self.has_manifest && r != 0 && self.roots.at(0).built && self.root_module(0, ob.as_str()) >= 0 {
                    keep = false;
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
}

// ---------------------------------------------------------------------------------------------------------
// JSON-RPC plumbing.
// ---------------------------------------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------------------------------------
// Diagnostics: rebuild every root and republish.
// ---------------------------------------------------------------------------------------------------------

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
                let u = uri;
                u.free();
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

extend Server {
    // Rebuild `r` from the current overlays, converting its DiagRecs into per-URI publish entries.
    fn build_root(self: &mut Self, r: usize, ps: &mut PubSet) {
        let mut ovf = Vector::<String>::new();
        let mut ovt = Vector::<String>::new();
        for i in 0..self.docs.len() {
            ovf.push(self.docs.at(i).path.clone());
            ovt.push(self.docs.at(i).txt.clone());
        }
        let mut diags = Vector::<analysis::DiagRec>::new();
        let rf = self.roots.at(r).root_file.clone();
        let rd = self.roots.at(r).root_dir.clone();
        let ad = self.roots.at(r).alt_dir.clone();
        // drop the previous build BEFORE compiling: holding both packages doubled the peak
        self.roots[r].pkg = loader::Package::new();
        // the manifest root lints every workspace file it owns (incl. an in-repo std/); other roots
        // lint only their own root file, so each file's lint warnings come from exactly one root
        let ld = if r == 0 && self.has_manifest {
            self.ws_root.clone();
        } else {
            String::new();
        };
        let pkg = if self.is_batch(r) {
            analysis::compile_batch(
                &self.roots.at(r).members,
                rd.as_str(),
                ad.as_str(),
                self.std_dir,
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
                self.std_dir,
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
            let fp = canon(self.roots.at(r).pkg.modules.at(m).file.as_str());
            self.roots[r].files.push(fp);
        }
        self.roots[r].built = true;
        // retain the records: publishing + codeAction read from them until the next rebuild
        self.roots[r].diags = diags;
        self.publish_root_diags(r, ps);
    }

    // Convert root `r`'s retained diagnostics into per-URI publish entries (module ids are
    // per-package). Also used to republish a cached sweep root without rebuilding it.
    fn publish_root_diags(self: &Self, r: usize, ps: &mut PubSet) {
        // files the manifest package owns publish from it alone -- a per-file/sweep root's closure
        // reaches std and friends, and republishing its (possibly stale) copies would duplicate them
        let dedup = r != 0 && self.has_manifest && self.roots.len() != 0 && self.roots.at(0).built;
        let mut last_mod: i64 = -1;
        let mut ls = Vector::<u32>::new();
        for k in 0..self.roots.at(r).diags.len() {
            let d = self.roots.at(r).diags.at(k);
            let m = d.module as usize;
            if m >= self.roots.at(r).pkg.modules.len() {
                continue;
            }
            if dedup && self.root_module(0, self.roots.at(r).files.at(m).as_str()) >= 0 {
                continue;
            }
            // a batch module whose file has a live per-file root (its doc is open) publishes from
            // that root's overlay-fresh build, not the batch's disk-built copy
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
    // still registers its URI, so a previously-reported problem is cleared once fixed.
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
    fn rebuild_all(self: &mut Self, f: *mut stdio::FILE) {
        self.drop_orphan_roots();
        // the manifest root must build first: it decides which docs need per-file roots
        if self.has_manifest && self.roots.len() != 0 && !self.roots.at(0).built {
            let mut ps0 = PubSet { uris: Vector::<String>::new(), arrs: Vector::<json::JSON>::new() };
            self.build_root(0, &mut ps0);
            // publishing waits for the full round below; this build only seeds ownership
        }
        self.ensure_roots();
        let mut ps = PubSet { uris: Vector::<String>::new(), arrs: Vector::<json::JSON>::new() };
        for r in 0..self.roots.len() {
            // a built sweep root for a closed file republishes its cached diagnostics: rebuilding
            // every workspace file on each keystroke would be unusable
            if self.roots.at(r).sweep && self.roots.at(r).built && !self.doc_open(self.roots.at(r).origin.as_str()) {
                self.publish_root_diags(r, &mut ps);
            } else {
                self.build_root(r, &mut ps);
            }
        }
        self.publish_manifest_diags(&mut ps);
        // publish
        for i in 0..ps.uris.len() {
            let mut params = json::JSON::object();
            params.emplace("uri", json::JSON::str(ps.uris.at(i).as_str()));
            params.emplace("diagnostics", ps.arrs.at(i).clone());
            notify(f, "textDocument/publishDiagnostics", &params);
        }
        // clear URIs that had diagnostics last round and none now
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
    }
}

// ---------------------------------------------------------------------------------------------------------
// Lifecycle + document sync handlers.
// ---------------------------------------------------------------------------------------------------------

const CAPABILITIES: str = r#"{"capabilities":{"textDocumentSync":{"openClose":true,"change":1},"hoverProvider":true,"definitionProvider":true,"referencesProvider":true,"renameProvider":true,"documentFormattingProvider":true,"codeActionProvider":true,"completionProvider":{"triggerCharacters":[".",":"]},"semanticTokensProvider":{"legend":{"tokenTypes":["namespace","type","enum","enumMember","interface","typeParameter","parameter","variable","property","function","method"],"tokenModifiers":["declaration","readonly"]},"full":true}},"serverInfo":{"name":"super-c lsp","version":"0.1"}}"#;

fn on_initialize(sv: &mut Server, req: &json::JSON, f: *mut stdio::FILE) {
    let mut ws = String::new();
    switch req.value("params") {
        Some(params) => {
            let ru = params.value_str("rootUri");
            if ru.len() != 0 {
                ws = text::uri_to_path(ru);
            } else {
                let rp = params.value_str("rootPath");
                if rp.len() != 0 {
                    ws = String::from_str(rp);
                }
            }
        },
        None => {},
    };
    if ws.len() != 0 {
        let _ = unsafe shim::sc_chdir(ws.cstr());
        sv.ws_root = canon(ws.as_str());
    }
    switch bman::load("build.toml") {
        Some(man) => {
            sv.has_manifest = true;
            let rf = man.root.as_str();
            sv.roots.insert(
                0,
                Root {
                    root_file: String::from_str(rf),
                    root_dir: dir_of(rf),
                    alt_dir: String::new(),
                    origin: String::new(),
                    sweep: false,
                    members: Vector::<String>::new(),
                    pkg: loader::Package::new(),
                    files: Vector::<String>::new(),
                    diags: Vector::<analysis::DiagRec>::new(),
                    built: false,
                },
            );
            sv.out_skip = String::from_str(man.out_dir.as_str());
        },
        None => {},
    };
    respond_raw(f, req.at_key("id"), CAPABILITIES);
}

fn on_did_open(sv: &mut Server, req: &json::JSON, f: *mut stdio::FILE) {
    switch req.value("params") {
        Some(params) => {
            let td = params.at_key("textDocument");
            let uri = td.value_str("uri");
            let p = uri_doc_path(uri);
            let di = sv.find_doc(uri);
            if di >= 0 {
                sv.docs[di as usize].txt = String::from_str(td.value_str("text"));
                sv.docs[di as usize].version = td.value_i64("version", 0);
            } else {
                sv.docs.push(
                    Doc {
                        uri: String::from_str(uri),
                        path: p,
                        txt: String::from_str(td.value_str("text")),
                        version: td.value_i64("version", 0),
                    },
                );
            }
            sv.rebuild_all(f);
        },
        None => {},
    };
}

fn on_did_change(sv: &mut Server, req: &json::JSON, f: *mut stdio::FILE) {
    switch req.value("params") {
        Some(params) => {
            let uri = params.at_key("textDocument").value_str("uri");
            let di = sv.find_doc(uri);
            if di < 0 {
                return;
            }
            switch params.value("contentChanges") {
                Some(ch) => {
                    if ch.is_array() && ch.size() != 0 {
                        // full sync: the last change carries the whole document
                        let last = ch.at(ch.size() - 1);
                        sv.docs[di as usize].txt = String::from_str(last.value_str("text"));
                        sv.docs[di as usize].version = params.at_key("textDocument").value_i64("version", 0);
                        sv.rebuild_all(f);
                    }
                },
                None => {},
            };
        },
        None => {},
    };
}

fn on_did_close(sv: &mut Server, req: &json::JSON, f: *mut stdio::FILE) {
    switch req.value("params") {
        Some(params) => {
            let uri = params.at_key("textDocument").value_str("uri");
            let di = sv.find_doc(uri);
            if di >= 0 {
                sv.docs.remove(di as usize).unwrap().free();
            }
            sv.rebuild_all(f); // overlays revert to the on-disk content
        },
        None => {},
    };
}

// A doc's canonical path from its URI (realpath when the file exists on disk).
fn uri_doc_path(uri: str) String {
    let raw = text::uri_to_path(uri);
    return canon(raw.as_str());
}

// `build.toml` is served by the manifest half of the server (src/lsp/buildtoml.spc): it is not Super-C
// source, so none of the package machinery applies to it.
fn is_manifest_path(path: str) bool {
    return path.ends_with("build.toml");
}

// ---------------------------------------------------------------------------------------------------------
// Positional requests: hover / definition / references / rename.
// ---------------------------------------------------------------------------------------------------------

// A positional request resolved onto a built package: root r, module m, byte span [off, end]
// (end == off for point requests).
struct Hit {
    pub ok: bool,
    pub r: usize,
    pub m: usize,
    pub off: u32,
    pub end: u32,
}

extend Server {
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
}

// The open build.toml a positional request names, and the byte offset in it; -1 when the request is
// not about a manifest. The document text is the editor's, so it is current between keystrokes.
fn manifest_hit(sv: &Server, req: &json::JSON, off: &mut usize) i32 {
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
    let di = sv.find_doc(uri);
    if di < 0 || !is_manifest_path(sv.docs.at(di as usize).path.as_str()) {
        return -1;
    }
    let pos = params.value("position");
    if pos.is_none() {
        return -1;
    }
    let p = pos.unwrap();
    let src = sv.docs.at(di as usize).txt.as_str();
    let ls = text::line_starts(src);
    *off = text::pos_to_offset(src, &ls, p.value_i64("line", 0) as u32, p.value_i64("character", 0) as u32) as usize;
    return di;
}

fn on_hover(sv: &Server, req: &json::JSON, f: *mut stdio::FILE) {
    let nullv = json::JSON::default();
    let mut moff: usize = 0;
    let mdi = manifest_hit(sv, req, &mut moff);
    if mdi >= 0 {
        let doc = btoml::hover(sv.docs.at(mdi as usize).txt.as_str(), moff);
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
    let h = sv.locate(req);
    if !h.ok {
        respond(f, req.at_key("id"), &nullv);
        return;
    }
    switch feat::hover(&sv.roots.at(h.r).pkg, h.m, h.off) {
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

fn on_definition(sv: &Server, req: &json::JSON, f: *mut stdio::FILE) {
    let nullv = json::JSON::default();
    let h = sv.locate(req);
    if !h.ok {
        respond(f, req.at_key("id"), &nullv);
        return;
    }
    switch feat::definition(&sv.roots.at(h.r).pkg, h.m, h.off) {
        Some(l) => {
            let lj = sv.loc_json(h.r, &l);
            respond(f, req.at_key("id"), &lj);
        },
        None => {
            respond(f, req.at_key("id"), &nullv);
        },
    };
}

fn on_references(sv: &Server, req: &json::JSON, f: *mut stdio::FILE) {
    let nullv = json::JSON::default();
    let h = sv.locate(req);
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
    let locs = feat::references(&sv.roots.at(h.r).pkg, h.m, h.off, include_decl);
    let mut arr = json::JSON::array();
    for i in 0..locs.len() {
        arr.push_back(sv.loc_json(h.r, locs.at(i)));
    }
    respond(f, req.at_key("id"), &arr);
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

// Canonical file path of module `m` in root `r`.
const fn self_def_file(sv: &Server, r: usize, m: usize) str {
    return sv.roots.at(r).files.at(m).as_str();
}

fn on_rename(sv: &Server, req: &json::JSON, f: *mut stdio::FILE) {
    let nullv = json::JSON::default();
    let h = sv.locate(req);
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
    let pkg = &sv.roots.at(h.r).pkg;
    let dm = feat::def_module(pkg, h.m, h.off);
    if dm < 0 {
        respond(f, req.at_key("id"), &nullv);
        return;
    }
    // a rename may only touch files inside the workspace: in a normal project the installed std/ffi
    // live next to the compiler binary (outside) and stay protected; in a workspace that contains its
    // own std -- the compiler repo itself -- renaming std symbols is legitimate first-party work
    let def_file = self_def_file(sv, h.r, dm as usize);
    let wr = sv.ws_root.as_str();
    let inside = wr.len() != 0 && def_file.len() > wr.len() + 1 && def_file.starts_with(wr) && def_file[wr.len()] == b'/';
    if !inside {
        send_error(f, req.at_key("id"), -32803, "cannot rename: the definition is outside the workspace (std/ffi)");
        return;
    }
    let locs = feat::references(pkg, h.m, h.off, true);
    if locs.len() == 0 {
        respond(f, req.at_key("id"), &nullv);
        return;
    }
    // group the edits per file URI
    let mut uris = Vector::<String>::new();
    let mut per = Vector::<json::JSON>::new();
    for i in 0..locs.len() {
        let l = locs.at(i);
        let uri = text::path_to_uri(sv.roots.at(h.r).files.at(l.module as usize).as_str());
        let src = sv.roots.at(h.r).pkg.modules.at(l.module as usize).source.as_str();
        let ls = text::line_starts(src);
        let mut te = json::JSON::object();
        te.emplace("range", range_json(src, &ls, l.start, l.end - l.start));
        te.emplace("newText", json::JSON::str(new_name));
        let mut idx: i64 = -1;
        for k in 0..uris.len() {
            if uris.at(k).as_str() == uri.as_str() {
                idx = k as i64;
                break;
            }
        }
        if idx >= 0 {
            per[idx as usize].push_back(te);
        } else {
            uris.push(uri);
            let mut a = json::JSON::array();
            a.push_back(te);
            per.push(a);
        }
    }
    let mut changes = json::JSON::object();
    while uris.len() != 0 {
        let u = uris.remove(0).unwrap();
        let ed = per.remove(0).unwrap();
        changes.emplace(u.as_str(), ed);
    }
    let mut we = json::JSON::object();
    we.emplace("changes", changes);
    respond(f, req.at_key("id"), &we);
}

// ---------------------------------------------------------------------------------------------------------
// Formatting / semantic tokens / completion.
// ---------------------------------------------------------------------------------------------------------

fn on_formatting(sv: &Server, req: &json::JSON, f: *mut stdio::FILE) {
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
    let di = sv.find_doc(uri);
    if di < 0 {
        respond(f, req.at_key("id"), &nullv);
        return;
    }
    let doc = sv.docs.at(di as usize);
    let mut formatted = String::new();
    if dutil::format_source(&doc.txt, doc.path.as_str(), 120, &mut formatted) != 0 {
        respond(f, req.at_key("id"), &nullv); // unparseable or comment-check tripped: never destructive
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

fn on_semantic_tokens(sv: &Server, req: &json::JSON, f: *mut stdio::FILE) {
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
    let r = sv.owning_root(path.as_str());
    if r < 0 {
        respond(f, req.at_key("id"), &nullv);
        return;
    }
    let m = sv.root_module(r as usize, path.as_str());
    if m < 0 {
        respond(f, req.at_key("id"), &nullv);
        return;
    }
    let pkg = &sv.roots.at(r as usize).pkg;
    let toks = feat::semantic_tokens(pkg, m as usize);
    let src = pkg.modules.at(m as usize).source.as_str();
    let ls = text::line_starts(src);
    let mut data = json::JSON::array();
    let mut prev_line: u32 = 0;
    let mut prev_char: u32 = 0;
    for i in 0..toks.len() {
        let t = toks.at(i);
        let pos = text::offset_to_pos(src, &ls, t.start);
        let mut dc = pos.character;
        if pos.line == prev_line {
            dc = pos.character - prev_char;
        }
        data.push_back(json::JSON::integer(pos.line - prev_line));
        data.push_back(json::JSON::integer(dc));
        data.push_back(json::JSON::integer(text::utf16_len(src, t.start, t.end)));
        data.push_back(json::JSON::integer(t.ty));
        data.push_back(json::JSON::integer(t.mods));
        prev_line = pos.line;
        prev_char = pos.character;
    }
    let mut res = json::JSON::object();
    res.emplace("data", data);
    respond(f, req.at_key("id"), &res);
}

// Completion through a probe: splice `__lsp_c` (then `__lsp_c;` if that still does not parse) at the
// cursor -- the mid-edit buffer rarely parses; the probe usually makes it -- compile a throwaway
// package with that overlay, and read completions from it. The probe's own type error is irrelevant:
// the typechecker still assigns the receiver's type. `member` picks member vs general completion.
fn complete_via_probe(sv: &Server, path: str, txt: str, off: u32, member: bool) Vector<feat::CompItem> {
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
        for i in 0..sv.docs.len() {
            ovf.push(sv.docs.at(i).path.clone());
            if sv.docs.at(i).path.as_str() == path {
                ovt.push(synth.clone());
            } else {
                ovt.push(sv.docs.at(i).txt.clone());
            }
        }
        // root parameters: the owning root when the doc has one, the per-file recipe otherwise
        let mut rf = String::from_str(path);
        let mut rd = dir_of(path);
        let mut ad = String::new();
        if is_dir("src") {
            ad.push_str("src");
        }
        let r = sv.owning_root(path);
        if r >= 0 {
            rf = sv.roots.at(r as usize).root_file.clone();
            rd = sv.roots.at(r as usize).root_dir.clone();
            ad = sv.roots.at(r as usize).alt_dir.clone();
        }
        let mut diags = Vector::<analysis::DiagRec>::new();
        let pkg = analysis::compile(
            rf.as_str(),
            rd.as_str(),
            ad.as_str(),
            sv.std_dir,
            sv.target,
            ovf,
            ovt,
            "",
            &mut diags,
        );
        let mut parsed = false;
        for m in 0..pkg.modules.len() {
            let c = canon(pkg.modules.at(m).file.as_str());
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

fn on_completion(sv: &Server, req: &json::JSON, f: *mut stdio::FILE) {
    let mut arr = json::JSON::array();
    let mut moff: usize = 0;
    let mdi = manifest_hit(sv, req, &mut moff);
    if mdi >= 0 {
        let items = btoml::completions(sv.docs.at(mdi as usize).txt.as_str(), moff);
        for i in 0..items.len() {
            let mut it = json::JSON::object();
            it.emplace("label", json::JSON::str(items.at(i).label.as_str()));
            it.emplace("kind", json::JSON::integer(14)); // Keyword
            it.emplace("detail", json::JSON::str(items.at(i).doc.as_str()));
            arr.push_back(it);
        }
        respond(f, req.at_key("id"), &arr);
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
    let di = sv.find_doc(uri);
    if di < 0 {
        respond(f, req.at_key("id"), &arr);
        return;
    }
    let txt = sv.docs.at(di as usize).txt.as_str();
    let ls = text::line_starts(txt);
    let off = text::pos_to_offset(txt, &ls, line as u32, ch as u32);
    let dot = off > 0 && txt[(off - 1) as usize] == b'.' && !(off > 1 && txt[(off - 2) as usize] == b'.');
    let path2 = off > 1 && txt[(off - 1) as usize] == b':' && txt[(off - 2) as usize] == b':';
    let mut items = Vector::<feat::CompItem>::new();
    if dot || path2 {
        items = complete_via_probe(sv, sv.docs.at(di as usize).path.as_str(), txt, off, true);
    } else {
        let r = sv.owning_root(sv.docs.at(di as usize).path.as_str());
        let mut m: i32 = -1;
        if r >= 0 {
            m = sv.root_module(r as usize, sv.docs.at(di as usize).path.as_str());
        }
        if m >= 0 && sv.roots.at(r as usize).pkg.modules.at(m as usize).has_ast {
            items = feat::complete_general(&sv.roots.at(r as usize).pkg, m as usize, off);
        } else {
            // broken buffer: complete from a probe build; keywords alone if even that fails to parse
            items = complete_via_probe(sv, sv.docs.at(di as usize).path.as_str(), txt, off, false);
            if items.len() == 0 {
                items = feat::complete_keywords();
            }
        }
    }
    for i in 0..items.len() {
        let it = items.at(i);
        let mut o = json::JSON::object();
        o.emplace("label", json::JSON::str(it.label.as_str()));
        o.emplace("kind", json::JSON::integer(it.kind));
        if it.detail.len() != 0 {
            o.emplace("detail", json::JSON::str(it.detail.as_str()));
        }
        arr.push_back(o);
    }
    respond(f, req.at_key("id"), &arr);
}

// Quick fixes: surface the lint warnings' machine-applicable LintFix records (the `lint --fix`
// payloads) as `quickfix` code actions for diagnostics intersecting the requested range. Errors carry
// no machine fixes, so they never produce actions.
fn on_code_action(sv: &Server, req: &json::JSON, f: *mut stdio::FILE) {
    let mut arr = json::JSON::array();
    let h = sv.locate_range(req);
    if !h.ok {
        respond(f, req.at_key("id"), &arr);
        return;
    }
    let src = sv.roots.at(h.r).pkg.modules.at(h.m).source.as_str();
    let ls = text::line_starts(src);
    let uri = text::path_to_uri(sv.roots.at(h.r).files.at(h.m).as_str());
    let diags = &sv.roots.at(h.r).diags;
    for k in 0..diags.len() {
        let d = diags.at(k);
        if d.module as usize != h.m || d.fix_kind < 0 {
            continue;
        }
        let dend = d.start + d.len;
        if d.start > h.end || dend < h.off {
            continue; // no overlap with the requested range
        }
        if d.fix_kind > 4 {
            continue; // unknown fix kind: never guess an edit
        }
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
        // echo the diagnostic so the client pins the action to its squiggle
        let mut dj = json::JSON::object();
        dj.emplace("range", range_json(src, &ls, d.start, d.len));
        dj.emplace("severity", json::JSON::integer(d.severity));
        dj.emplace("source", json::JSON::str("super-c"));
        dj.emplace("message", json::JSON::str(d.msg.as_str()));
        let mut dl = json::JSON::array();
        dl.push_back(dj);
        let mut act = json::JSON::object();
        act.emplace("title", json::JSON::string(title));
        act.emplace("kind", json::JSON::str("quickfix"));
        act.emplace("diagnostics", dl);
        act.emplace("edit", we);
        arr.push_back(act);
    }
    respond(f, req.at_key("id"), &arr);
}

// ---------------------------------------------------------------------------------------------------------
// Main loop.
// ---------------------------------------------------------------------------------------------------------

/// The blocking stdio server loop; returns the process exit code: 0 for a clean shutdown-then-exit,
/// 1 on EOF (client vanished) or an `exit` without a prior `shutdown`.
pub fn run(std_dir: *const char, target: i32) i32 {
    let mut sv = Server {
        docs: Vector::<Doc>::new(),
        roots: Vector::<Root>::new(),
        has_manifest: false,
        std_dir: std_dir,
        target: target,
        published: Vector::<String>::new(),
        ws_root: String::new(),
        out_skip: String::new(),
        shutdown_seen: false,
    };
    let fin = stdio::stdin();
    let fout = stdio::stdout();
    loop {
        let msgo = transport::read_message(fin);
        if msgo.is_none() {
            return 1; // client vanished without exit
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
        let method = req.value_str("method");
        if method == "initialize" {
            on_initialize(&mut sv, &req, fout);
        } else if method == "initialized" {
            // first full round: the manifest build + workspace sweep publish diagnostics for the
            // whole build.toml folder before any document opens
            sv.rebuild_all(fout);
        } else if method == "shutdown" {
            sv.shutdown_seen = true;
            let nullv = json::JSON::default();
            respond(fout, req.at_key("id"), &nullv);
        } else if method == "exit" {
            if sv.shutdown_seen {
                return 0;
            }
            return 1;
        } else if method == "textDocument/didOpen" {
            on_did_open(&mut sv, &req, fout);
        } else if method == "textDocument/didChange" {
            on_did_change(&mut sv, &req, fout);
        } else if method == "textDocument/didSave" {
            // overlays are already current
        } else if method == "textDocument/didClose" {
            on_did_close(&mut sv, &req, fout);
        } else if method == "textDocument/hover" && req.contains_key("id") {
            on_hover(&sv, &req, fout);
        } else if method == "textDocument/definition" && req.contains_key("id") {
            on_definition(&sv, &req, fout);
        } else if method == "textDocument/references" && req.contains_key("id") {
            on_references(&sv, &req, fout);
        } else if method == "textDocument/rename" && req.contains_key("id") {
            on_rename(&sv, &req, fout);
        } else if method == "textDocument/formatting" && req.contains_key("id") {
            on_formatting(&sv, &req, fout);
        } else if method == "textDocument/semanticTokens/full" && req.contains_key("id") {
            on_semantic_tokens(&sv, &req, fout);
        } else if method == "textDocument/completion" && req.contains_key("id") {
            on_completion(&sv, &req, fout);
        } else if method == "textDocument/codeAction" && req.contains_key("id") {
            on_code_action(&sv, &req, fout);
        } else if req.contains_key("id") {
            send_error(fout, req.at_key("id"), -32601, "method not found");
        }
        // unknown notifications ($/cancelRequest, $/setTrace, ...) are ignored
    }
}
