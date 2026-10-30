// The tool-server protocol, version 1: what `super-c tool-server` answers. A message is one JSON object in
// the language server's framing (`lsp::transport`). A request is `{"id": N, "method": M, "params": {...}}`
// with an integer id; its answer is `{"id": N, "result": R}` or `{"id": N, "error": {"code": C, "message":
// T}}`, where C is the stable name of an `api::errors::Code` (`code_name`). A message that is no request is
// answered with id null and `protocol_failed`.
//
// Methods:
// - `hello {protocol_versions, client, required, optional}`: first, once. Grants the requested
//   capabilities the launcher allows (`Launch.grantable`); a required one outside them is
//   `unsupported_capability` and the handshake stays open. Result `{server, api_version, protocol,
//   capabilities, limits}`.
// - `open_workspace {kind: "file" | "project", path, files: {name: text}}` (session): a session over
//   `path`, reading `files` from memory and other files from the launcher's roots alone. Result
//   `{workspace, revision}`.
// - `set_file_text {workspace, file, text, expected_version}`, `apply_edits {workspace, file, edits:
//   [{start, end, text}], expected_version}` (session): change one file's text (`expected_version` -1:
//   any). Result `{revision, version}`.
// - `commit {workspace}` (session): analyze the current texts. Result `{revision}`. A cancelled or failed
//   commit leaves the workspace unchecked.
// - `query {workspace, revision, capability, method, arguments, cursor, limit}`: read the analysis of
//   `revision` (else `stale_handle`; `not_checked` before a commit). A list result is `{items,
//   next_cursor}`: items from index `cursor` until their encoded size passes `limit` bytes (at least one
//   item; 0: no limit), `next_cursor` the index after the last (-1 at the end). The methods, and the keys
//   their items are sorted by:
//   - `session.diagnostics {}`: items `{file, start, end, severity, code, message}`, by file, start, end,
//     code.
//   - `syntax.format {file}`: `{text}`. `syntax.nodes {file}`: items `{id, kind, start, end, parent}` in
//     preorder.
//   - `navigation.symbol_at {file, offset}`: `{symbol}`, `{name, kind, signature, file, start, end}` or
//     null. `navigation.hover {file, offset}`: `{text}` or null. `navigation.references {file, offset,
//     include_declaration}`: items `{file, start, end}` by file, start, end. `navigation.outline {file}`:
//     items `{name, kind, detail, start, end, name_start, name_end, parent}` in text order.
//     `navigation.find_symbols {query, limit}`: items `{file, start, end}` best match first.
//   - `refactoring.rename {file, offset, new_name}`: items `{file, start, end, text}` by file, start.
//   With `"binary": true`, a location list (`navigation.references`, `navigation.find_symbols`) comes as
//   a binary batch: the result is `{batch: {schema: "locations.1", count, bytes, checksum, endian:
//   "little"}, files, next_cursor}` and the next frame holds `bytes` bytes: per item its file's index in
//   `files`, its start and its end, each a little-endian u32. `checksum` is the sum of the payload's u32
//   words modulo 2^32. `limit` counts payload bytes.
//   - `ir_views.core_function {file, offset}`: `{text, generic, locals, blocks}`. `ir_views.hir_nodes
//     {file, start, end}`: items `{kind, start, end, lowered, type}` in text order.
// - `cancel {target}`: the server's reader cancels request `target`, which returns `cancelled`. Result {}.
// - `close_workspace {workspace}`: drop the workspace and its data. Result {}.
import api::errors as *;
import api::session as ses;
import api::source as *;
import api::syntax as syn;
import api::semantic as sem;
import api::ir as ir;
import lsp::json as json;
import utils::diag_codes as dc;

/// The protocol major this server speaks.
pub const PROTOCOL: i64 = 1;

/// Capability bits: what a launcher allows and a client is granted.
pub const CAP_SESSION: u32 = 1;
pub const CAP_SYNTAX: u32 = 2;
pub const CAP_NAVIGATION: u32 = 4;
pub const CAP_REFACTORING: u32 = 8;
pub const CAP_IR_VIEWS: u32 = 16;
/// Every capability the server serves.
pub const CAP_ALL: u32 = 31;

const CAP_NAMES: [str<'static>; 5] = ["session", "syntax", "navigation", "refactoring", "ir_views"];

/// The bit of capability `name`; 0 for a name this server does not serve.
pub fn cap_bit(name: str) u32 {
    let names: []str = CAP_NAMES;
    for i in 0..names.len() {
        if names[i] == name {
            return 1 << i as u32;
        }
    }
    return 0;
}

/// The stable protocol name of `code`.
pub fn code_name(code: Code) str<'static> {
    return switch code {
        InvalidArgument => "invalid_argument",
        StaleHandle => "stale_handle",
        WrongWorkspace => "wrong_workspace",
        Cancelled => "cancelled",
        Deadline => "deadline",
        Limit => "limit",
        Io => "io",
        ParseFailed => "parse_failed",
        SemanticFailed => "semantic_failed",
        VerificationFailed => "verification_failed",
        PluginFailed => "plugin_failed",
        ProtocolFailed => "protocol_failed",
        ReentrantCall => "reentrant_call",
        NotChecked => "not_checked",
        UnsupportedCapability => "unsupported_capability",
        VersionMismatch => "version_mismatch",
        Internal => "internal",
    };
}

/// What the launcher fixes when the server starts; no client request widens it.
@derive(Clone)
pub struct Launch {
    /// The std directory every workspace reads.
    pub std_dir: String,
    /// The capabilities a client may be granted (`CAP_*`).
    pub grantable: u32,
    /// The directories whose files a workspace may read from disk, besides std.
    pub roots: Vector<String>,
    /// The largest message the server reads, in bytes.
    pub max_frame: usize,
    /// The most workspaces open at once.
    pub max_workspaces: usize,
}

struct Workspace {
    pub id: i64,
    pub s: ses::Session,
}

/// One client's protocol state: its handshake, grants and workspaces.
pub struct Server {
    limits: Launch,
    granted: u32,
    ready: bool,
    workspaces: Vector<Workspace>,
    next_id: i64,
    payload: Vector<u8>, // the binary batch of the last answer
}

// A failed request.
fn err<T>(code: Code, msg: str) Result<T, ApiError> {
    return Err(ApiError::new(code, msg));
}

// Member `key` of `v` as an integer; `InvalidArgument` when absent or not an integer.
fn int_of(v: &json::JSON, key: str) Result<i64, ApiError> {
    if let Some(x) = v.value(key) {
        if x.is_number() {
            let n = x.get_number();
            if n == n && n >= -9007199254740992.0 && n <= 9007199254740992.0 && n == (n as i64) as f64 {
                return Ok(n as i64);
            }
        }
    }
    return err::<i64>(Code::InvalidArgument, format("'{}' must be an integer", key).as_str());
}

// Member `key` of `v` as an offset into a text: an integer in `[0, 2^32)`.
fn u32_of(v: &json::JSON, key: str) Result<u32, ApiError> {
    let n = int_of(v, key)?;
    if n < 0 || n > 0xFFFFFFFF {
        return err::<u32>(Code::InvalidArgument, format("'{}' is out of range", key).as_str());
    }
    return Ok(n as u32);
}

// Member `key` of `v` as a string; `InvalidArgument` when absent or not a string.
fn str_of<'a>(v: &'a json::JSON, key: str) Result<str<'a>, ApiError> {
    if let Some(x) = v.value(key) {
        if x.is_string() {
            return Ok(x.get_str());
        }
    }
    return err::<str<'a>>(Code::InvalidArgument, format("'{}' must be a string", key).as_str());
}

// Member `key` of `v` as an integer, `dflt` when absent.
fn int_or(v: &json::JSON, key: str, dflt: i64) Result<i64, ApiError> {
    if !v.contains_key(key) {
        return Ok(dflt);
    }
    return int_of(v, key);
}

// Append `"key":` to `out`.
fn key(out: &mut String, k: str) {
    json::dump_escaped(k, out);
    out.push_byte(b':');
}

// Append `"key":"text",` to `out`.
fn field_str(out: &mut String, k: str, v: str) {
    key(out, k);
    json::dump_escaped(v, out);
    out.push_byte(b',');
}

// Append `"key":n,` to `out`.
fn field_int(out: &mut String, k: str, n: i64) {
    key(out, k);
    out.format_into("{},", n);
}

// Close the object in `out` whose last field ended with a comma.
fn close_obj(out: &mut String) {
    if out.len() != 0 && out.as_str().byte_at(out.len() - 1) == b',' {
        out.pop_byte();
    }
    out.push_byte(b'}');
}

/// The answer to request `id` (null when -1) failing with `e`.
pub fn error_reply(id: i64, e: ApiError) String {
    let mut out = String::with_capacity(96 + e.message.len());
    out.push_str("{\"id\":");
    if id < 0 {
        out.push_str("null");
    } else {
        out.format_into("{}", id);
    }
    out.push_str(",\"error\":{");
    field_str(&mut out, "code", code_name(e.code));
    field_str(&mut out, "message", &e.message);
    if e.file.len() != 0 {
        field_str(&mut out, "file", &e.file);
        field_int(&mut out, "start", e.start);
        field_int(&mut out, "end", e.end);
    }
    close_obj(&mut out);
    out.push_byte(b'}');
    return out;
}

// A list result in the making: the items from index `cursor`, until their bytes pass `limit`.
struct Page {
    pub out: String,
    pub cursor: usize,
    pub limit: usize,
    pub index: usize,
    pub items: usize,
    pub next: i64,
}

extend Page {
    fn new(cursor: i64, limit: i64) Result<Page, ApiError> {
        if cursor < 0 || limit < 0 {
            return err::<Page>(Code::InvalidArgument, "'cursor' and 'limit' must not be negative");
        }
        let mut p = Page { out: String::with_capacity(256), cursor: cursor as usize, limit: limit as usize, next: -1 };
        p.out.push_str("{\"items\":[");
        return Ok(p);
    }

    // Whether the next item is to be written; it then starts in `out`.
    fn want(self: &mut Self) bool {
        let i = self.index;
        self.index += 1;
        if i < self.cursor || self.next >= 0 {
            return false;
        }
        if self.limit != 0 && self.items != 0 && self.out.len() >= self.limit {
            self.next = i as i64;
            return false;
        }
        if self.items != 0 {
            self.out.push_byte(b',');
        }
        self.items += 1;
        self.out.push_byte(b'{');
        return true;
    }

    fn finish(self: &mut Self) String {
        self.out.push_str("],\"next_cursor\":");
        self.out.format_into("{}}", self.next);
        return replace(&mut self.out, String::new());
    }
}

extend Server {
    /// A server for one client under `launch`.
    pub fn new(limits: Launch) Server {
        return Server { limits: limits, granted: 0, ready: false, workspaces: Vector::<Workspace>::new(), next_id: 1 };
    }

    /// The binary batch the last answer announced, to send as the next frame; empty when it announced
    /// none. Taking it leaves none.
    pub fn take_payload(self: &mut Self) Vector<u8> {
        return replace(&mut self.payload, Vector::<u8>::new());
    }

    /// The answer to message `msg`, a request body, under the cancellation and deadline of `opts`.
    pub fn handle(self: &mut Self, msg: str, opts: &ses::RequestOptions) String {
        return switch json::parse(msg) {
            Ok(v) => self.handle_json(&v, opts),
            Err(e) => error_reply(
                -1,
                ApiError::new(Code::ProtocolFailed, format("malformed JSON: {}", e.as_str()).as_str()),
            ),
        };
    }

    /// The answer to request `req`, parsed, under the cancellation and deadline of `opts`.
    pub(package) fn handle_json(self: &mut Self, req: &json::JSON, opts: &ses::RequestOptions) String {
        if !req.is_object() {
            return error_reply(-1, ApiError::new(Code::ProtocolFailed, "a request is a JSON object"));
        }
        let id = switch int_of(req, "id") {
            Ok(n) if n >= 0 => n,
            _ => {
                return error_reply(
                    -1,
                    ApiError::new(Code::ProtocolFailed, "a request needs a non-negative integer 'id'"),
                );
            },
        };
        let method = switch str_of(req, "method") {
            Ok(m) => m,
            Err(_) => {
                return error_reply(id, ApiError::new(Code::ProtocolFailed, "a request needs a string 'method'"));
            },
        };
        let empty = json::JSON::object();
        let params = switch req.value("params") {
            Some(p) if p.is_object() => p,
            Some(_) => {
                return error_reply(id, ApiError::new(Code::ProtocolFailed, "'params' must be an object"));
            },
            None => &empty,
        };
        let mut out = String::with_capacity(128);
        out.format_into("{{\"id\":{},\"result\":", id);
        let r = self.dispatch(method, params, opts, &mut out);
        if let Err(e) = r {
            return error_reply(id, e);
        }
        out.push_byte(b'}');
        return out;
    }

    fn dispatch(self: &mut Self, method: str, params: &json::JSON, opts: &ses::RequestOptions, out: &mut String) Result<
        Unit,
        ApiError
    > {
        if method == "hello" {
            return self.hello(params, out);
        }
        if !self.ready {
            return err::<Unit>(Code::ProtocolFailed, "the first request must be 'hello'");
        }
        if method == "cancel" {
            let _ = int_of(params, "target")?;
            out.push_str("{}");
            return Ok(Unit {});
        }
        if method == "query" {
            return self.query(params, opts, out);
        }
        if (self.granted & CAP_SESSION) == 0 {
            return err::<Unit>(Code::UnsupportedCapability, "the 'session' capability is not granted");
        }
        if method == "open_workspace" {
            return self.open_workspace(params, out);
        }
        let w = self.workspace(params)?;
        if method == "close_workspace" {
            let _ = self.workspaces.remove(w);
            out.push_str("{}");
            return Ok(Unit {});
        }
        let s = &mut self.workspaces[w].s;
        if method == "set_file_text" || method == "apply_edits" {
            let file = str_of(params, "file")?;
            let mut c = ses::Change {
                path: String::from_str(file),
                edits: Vector::<Edit>::new(),
                expected_version: int_or(params, "expected_version", -1)?,
            };
            if method == "set_file_text" {
                c.replace = true;
                c.text = String::from_str(str_of(params, "text")?);
            } else {
                let es = switch params.value("edits") {
                    Some(a) if a.is_array() => a,
                    _ => {
                        return err::<Unit>(Code::InvalidArgument, "'edits' must be an array");
                    },
                };
                for i in 0..es.size() {
                    let e = es.at(i);
                    c.edits.push(
                        Edit {
                            start: u32_of(e, "start")?,
                            end: u32_of(e, "end")?,
                            text: String::from_str(str_of(e, "text")?),
                        },
                    );
                }
            }
            let rev = s.apply(unsafe Slice::<ses::Change> { ptr: &c, len: 1 })?;
            out.push_byte(b'{');
            field_int(out, "revision", rev as i64);
            field_int(out, "version", s.version(file));
            close_obj(out);
            return Ok(Unit {});
        }
        if method == "commit" {
            s.check_with(opts)?;
            out.push_byte(b'{');
            field_int(out, "revision", s.revision() as i64);
            close_obj(out);
            return Ok(Unit {});
        }
        return err::<Unit>(Code::ProtocolFailed, format("unknown method '{}'", method).as_str());
    }

    fn hello(self: &mut Self, params: &json::JSON, out: &mut String) Result<Unit, ApiError> {
        if self.ready {
            return err::<Unit>(Code::ProtocolFailed, "'hello' comes once");
        }
        let mut speaks = false;
        if let Some(vs) = params.value("protocol_versions") {
            if vs.is_array() {
                for i in 0..vs.size() {
                    let v = vs.at(i);
                    speaks = speaks || v.is_number() && v.get_number() == PROTOCOL as f64;
                }
            }
        }
        if !speaks {
            return err::<Unit>(Code::VersionMismatch, "the server speaks protocol 1 alone");
        }
        let mut grant: u32 = 0;
        for side in 0..2 {
            let names = switch params.value(
                if side == 0 {
                    "required"
                } else {
                    "optional"
                },
            ) {
                Some(a) if a.is_array() => a,
                Some(_) => {
                    return err::<Unit>(Code::ProtocolFailed, "capability lists must be arrays");
                },
                None => {
                    continue;
                },
            };
            for i in 0..names.size() {
                let n = names.at(i);
                if !n.is_string() {
                    return err::<Unit>(Code::ProtocolFailed, "a capability is a string");
                }
                let b = cap_bit(n.get_str()) & self.limits.grantable;
                if b == 0 && side == 0 {
                    return err::<Unit>(
                        Code::UnsupportedCapability,
                        format("the server does not grant capability '{}'", n.get_str()).as_str(),
                    );
                }
                grant |= b;
            }
        }
        self.granted = grant;
        self.ready = true;
        out.push_byte(b'{');
        field_str(out, "server", "super-c tool-server");
        field_int(out, "api_version", API_VERSION);
        field_int(out, "protocol", PROTOCOL);
        key(out, "capabilities");
        out.push_byte(b'[');
        let mut first = true;
        let names: []str = CAP_NAMES;
        for i in 0..names.len() {
            if (grant & 1 << i as u32) != 0 {
                if !first {
                    out.push_byte(b',');
                }
                first = false;
                json::dump_escaped(names[i], out);
            }
        }
        out.push_str("],");
        key(out, "limits");
        out.push_byte(b'{');
        field_int(out, "max_frame", self.limits.max_frame as i64);
        field_int(out, "max_workspaces", self.limits.max_workspaces as i64);
        close_obj(out);
        out.push_byte(b'}');
        return Ok(Unit {});
    }

    // The index of the workspace `params.workspace` names.
    fn workspace(self: &Self, params: &json::JSON) Result<usize, ApiError> {
        let id = int_of(params, "workspace")?;
        for i in 0..self.workspaces.len() {
            if self.workspaces[i].id == id {
                return Ok(i);
            }
        }
        return err::<usize>(Code::WrongWorkspace, "no open workspace has this id");
    }

    fn open_workspace(self: &mut Self, params: &json::JSON, out: &mut String) Result<Unit, ApiError> {
        if self.workspaces.len() >= self.limits.max_workspaces {
            return err::<Unit>(Code::Limit, "the server holds its most workspaces");
        }
        let kind = str_of(params, "kind")?;
        let path = str_of(params, "path")?;
        let mut roots = self.limits.roots.clone();
        roots.push(self.limits.std_dir.clone());
        let mut mem = switch MemoryFiles::over_disk_within(&roots) {
            Ok(m) => m,
            Err(e) => {
                return Err(ApiError::io(e, ""));
            },
        };
        if let Some(fs) = params.value("files") {
            switch fs {
                Obj(members) => {
                    for i in 0..members.len() {
                        let m = &members[i];
                        if !m.value.is_string() {
                            return err::<Unit>(Code::InvalidArgument, "a file's text is a string");
                        }
                        mem.set(&m.key, m.value.get_str());
                    }
                },
                _ => {
                    return err::<Unit>(Code::InvalidArgument, "'files' must be an object");
                },
            }
        }
        let cfg = ses::Config::with_files(&self.limits.std_dir, Box::new(mem));
        let s = if kind == "file" {
            ses::Session::open_file(path, cfg)?
        } else if kind == "project" {
            ses::Session::open_project(path, cfg)?
        } else {
            return err::<Unit>(Code::InvalidArgument, "'kind' is \"file\" or \"project\"");
        };
        let id = self.next_id;
        self.next_id += 1;
        out.push_byte(b'{');
        field_int(out, "workspace", id);
        field_int(out, "revision", s.revision() as i64);
        close_obj(out);
        self.workspaces.push(Workspace { id: id, s: s });
        return Ok(Unit {});
    }

    fn query(self: &mut Self, params: &json::JSON, opts: &ses::RequestOptions, out: &mut String) Result<Unit, ApiError> {
        let cap = str_of(params, "capability")?;
        let bit = cap_bit(cap);
        if bit == 0 || (self.granted & bit) == 0 {
            return err::<Unit>(Code::UnsupportedCapability, format("the '{}' capability is not granted", cap).as_str());
        }
        let method = str_of(params, "method")?;
        let w = self.workspace(params)?;
        let rev = int_of(params, "revision")?;
        let s = &mut self.workspaces[w].s;
        if rev < 0 || rev as u64 != s.revision() {
            return err::<Unit>(Code::StaleHandle, "the revision is not the workspace's current one");
        }
        if !s.checked() {
            return err::<Unit>(Code::NotChecked, "the workspace has no analysis of this revision: commit first");
        }
        let empty = json::JSON::object();
        let args = switch params.value("arguments") {
            Some(a) if a.is_object() => a,
            Some(_) => {
                return err::<Unit>(Code::InvalidArgument, "'arguments' must be an object");
            },
            None => &empty,
        };
        let mut pg = Page::new(int_or(params, "cursor", 0)?, int_or(params, "limit", 0)?)?;
        let m = format("{}.{}", cap, method);
        let ms = m.as_str();
        let binary = params.value_bool("binary");
        if binary && ms != "navigation.references" && ms != "navigation.find_symbols" {
            return err::<Unit>(Code::InvalidArgument, "this query has no binary schema");
        }
        if ms == "session.diagnostics" {
            diagnostics(s, &mut pg)?;
        } else if ms == "syntax.format" {
            let file = str_of(args, "file")?;
            let text = file_text(s, file)?;
            let t = syn::format_file(file, &text, 120)?;
            out.push_byte(b'{');
            field_str(out, "text", &t);
            close_obj(out);
            return Ok(Unit {});
        } else if ms == "syntax.nodes" {
            let file = str_of(args, "file")?;
            let text = file_text(s, file)?;
            let tree = syn::SyntaxTree::parse(file, &text);
            let root = tree.root();
            let mut it = root.descendants();
            // Bounded by the tree's nodes.
            while let Some(n) = it.next() {
                if pg.want() {
                    let r = n.range();
                    field_int(&mut pg.out, "id", n.id());
                    field_str(&mut pg.out, "kind", format("{}", n.kind()).as_str());
                    field_int(&mut pg.out, "start", r.start);
                    field_int(&mut pg.out, "end", r.end);
                    field_int(
                        &mut pg.out,
                        "parent",
                        switch n.parent() {
                            Some(p) => p.id(),
                            None => -1,
                        },
                    );
                    close_obj(&mut pg.out);
                }
            }
        } else if ms == "navigation.symbol_at" {
            let y = sem::symbol_at(s, str_of(args, "file")?, u32_of(args, "offset")?)?;
            out.push_str("{\"symbol\":");
            switch y {
                Some(sym) => {
                    out.push_byte(b'{');
                    field_str(out, "name", sym.name());
                    field_str(out, "kind", format("{}", sym.kind()).as_str());
                    field_str(out, "signature", sym.signature().as_str());
                    if let Some(l) = sym.location() {
                        field_str(out, "file", &l.file);
                        field_int(out, "start", l.start);
                        field_int(out, "end", l.end);
                    }
                    close_obj(out);
                },
                None => {
                    out.push_str("null");
                },
            }
            out.push_byte(b'}');
            return Ok(Unit {});
        } else if ms == "navigation.hover" {
            let h = sem::hover(s, str_of(args, "file")?, u32_of(args, "offset")?)?;
            out.push_str("{\"text\":");
            switch h {
                Some(t) => json::dump_escaped(&t, out),
                None => out.push_str("null"),
            }
            out.push_byte(b'}');
            return Ok(Unit {});
        } else if ms == "navigation.references" {
            let incl = args.value_bool("include_declaration");
            let mut ls = sem::references_at(s, str_of(args, "file")?, u32_of(args, "offset")?, incl, opts)?;
            sort_locations(&mut ls);
            if binary {
                return location_batch(&ls, &pg, out, &mut self.payload);
            }
            locations(&ls, &mut pg);
        } else if ms == "navigation.outline" {
            let es = sem::outline(s, str_of(args, "file")?)?;
            for i in 0..es.len() {
                if pg.want() {
                    let e = &es[i];
                    field_str(&mut pg.out, "name", &e.name);
                    field_str(&mut pg.out, "kind", format("{}", e.kind).as_str());
                    field_str(&mut pg.out, "detail", &e.detail);
                    field_int(&mut pg.out, "start", e.range.start);
                    field_int(&mut pg.out, "end", e.range.end);
                    field_int(&mut pg.out, "name_start", e.name_range.start);
                    field_int(&mut pg.out, "name_end", e.name_range.end);
                    field_int(&mut pg.out, "parent", e.parent);
                    close_obj(&mut pg.out);
                }
            }
        } else if ms == "navigation.find_symbols" {
            let n = int_or(args, "limit", 100)?;
            if n < 0 {
                return err::<Unit>(Code::InvalidArgument, "'limit' must not be negative");
            }
            let ls = sem::find_symbols(s, str_of(args, "query")?, n as usize)?;
            if binary {
                return location_batch(&ls, &pg, out, &mut self.payload);
            }
            locations(&ls, &mut pg);
        } else if ms == "refactoring.rename" {
            let mut we = sem::rename(s, str_of(args, "file")?, u32_of(args, "offset")?, str_of(args, "new_name")?)?;
            we.edits.sort_by(
                |a: &syn::TextEdit, b: &syn::TextEdit| {
                    let bf = b.file.as_str();
                    let c = a.file.as_str().cmp(&bf);
                    if c != 0 {
                        return c;
                    }
                    return a.start.cmp(&b.start);
                },
            );
            for i in 0..we.edits.len() {
                if pg.want() {
                    let e = &we.edits[i];
                    field_str(&mut pg.out, "file", &e.file);
                    field_int(&mut pg.out, "start", e.start);
                    field_int(&mut pg.out, "end", e.end);
                    field_str(&mut pg.out, "text", &e.text);
                    close_obj(&mut pg.out);
                }
            }
        } else if ms == "ir_views.core_function" {
            let f = ir::core_function(s, str_of(args, "file")?, u32_of(args, "offset")?)?;
            out.push_byte(b'{');
            field_str(out, "text", &f.text);
            key(out, "generic");
            out.push_str(
                if f.generic {
                    "true,"
                } else {
                    "false,"
                },
            );
            field_int(out, "locals", f.locals.len() as i64);
            field_int(out, "blocks", f.blocks.len() as i64);
            close_obj(out);
            return Ok(Unit {});
        } else if ms == "ir_views.hir_nodes" {
            let ns = ir::hir_nodes(s, str_of(args, "file")?, u32_of(args, "start")?, u32_of(args, "end")?)?;
            for i in 0..ns.len() {
                if pg.want() {
                    let n = &ns[i];
                    field_str(&mut pg.out, "kind", format("{}", n.kind).as_str());
                    field_int(&mut pg.out, "start", n.range.start);
                    field_int(&mut pg.out, "end", n.range.end);
                    key(&mut pg.out, "lowered");
                    pg.out.push_str(
                        if n.lowered {
                            "true,"
                        } else {
                            "false,"
                        },
                    );
                    field_str(&mut pg.out, "type", &n.ty);
                    close_obj(&mut pg.out);
                }
            }
        } else {
            return err::<Unit>(Code::ProtocolFailed, format("unknown query '{}'", ms).as_str());
        }
        let t = pg.finish();
        out.push_string(&t);
        return Ok(Unit {});
    }
}

// The current text of workspace file `file`.
fn file_text(s: &mut ses::Session, file: str) Result<String, ApiError> {
    return switch s.text(file)? {
        Some(t) => Ok(t),
        None => Err(ApiError::at(Code::InvalidArgument, "no such file", file, 0, 0)),
    };
}

// Sort `ls` by file, start, end.
fn sort_locations(ls: &mut Vector<sem::Location>) {
    let mut sorted = true;
    for i in 1..ls.len() {
        let a = &ls[i - 1];
        let b = &ls[i];
        sorted = sorted && (a.file.as_str() == b.file.as_str() && (a.start < b.start || a.start == b.start && a.end <= b.end));
    }
    if sorted {
        return;
    }
    ls.sort_by(
        |a: &sem::Location, b: &sem::Location| {
            let bf = b.file.as_str();
            let c = a.file.as_str().cmp(&bf);
            if c != 0 {
                return c;
            }
            if a.start != b.start {
                return a.start.cmp(&b.start);
            }
            return a.end.cmp(&b.end);
        },
    );
}

// The items of `ls` into `pg`.
fn locations(ls: &Vector<sem::Location>, pg: &mut Page) {
    for i in 0..ls.len() {
        if pg.want() {
            field_str(&mut pg.out, "file", &ls[i].file);
            field_int(&mut pg.out, "start", ls[i].start);
            field_int(&mut pg.out, "end", ls[i].end);
            close_obj(&mut pg.out);
        }
    }
}

// Store `v` at byte `at` of `w`, little-endian.
@always_inline
fn put_u32(w: &mut [u8; 12], at: usize, v: u32) {
    let p = (&mut w[0]) as *mut u8;
    unsafe p[at] = v as u8;
    unsafe p[at + 1] = (v >> 8) as u8;
    unsafe p[at + 2] = (v >> 16) as u8;
    unsafe p[at + 3] = (v >> 24) as u8;
}

// The `locations.1` batch of `ls` from `pg`'s cursor: its header into `out`, its bytes into `payload`.
fn location_batch(ls: &Vector<sem::Location>, pg: &Page, out: &mut String, payload: &mut Vector<u8>) Result<
    Unit,
    ApiError
> {
    let mut files = Vector::<u32>::new(); // indexes into `ls` of each file's first item
    let mut last: u32 = 0;
    let mut next: i64 = -1;
    payload.clear();
    payload.reserve(12 * (ls.len() - pg.cursor.min(ls.len())));
    let mut sum: u32 = 0;
    for i in pg.cursor..ls.len() {
        if pg.limit != 0 && payload.len() != 0 && payload.len() >= pg.limit {
            next = i as i64;
            break;
        }
        let l = &ls[i];
        if files.len() == 0 || ls[files[last as usize] as usize].file.as_str() != l.file.as_str() {
            last = files.len() as u32;
            for k in 0..files.len() {
                if ls[files[k] as usize].file.as_str() == l.file.as_str() {
                    last = k as u32;
                    break;
                }
            }
            if last == files.len() as u32 {
                files.push(i as u32);
            }
        }
        sum = sum.wrapping_add(last).wrapping_add(l.start).wrapping_add(l.end);
        let mut w: [u8; 12] = [0; 12];
        put_u32(&mut w, 0, last);
        put_u32(&mut w, 4, l.start);
        put_u32(&mut w, 8, l.end);
        payload.extend_from_slice(w);
    }
    out.push_str("{\"batch\":{\"schema\":\"locations.1\",");
    field_int(out, "count", (payload.len() / 12) as i64);
    field_int(out, "bytes", payload.len() as i64);
    field_int(out, "checksum", sum);
    field_str(out, "endian", "little");
    close_obj(out);
    out.push_str(",\"files\":[");
    for k in 0..files.len() {
        if k != 0 {
            out.push_byte(b',');
        }
        json::dump_escaped(&ls[files[k] as usize].file, out);
    }
    out.format_into("],\"next_cursor\":{}}}", next);
    return Ok(Unit {});
}

// One diagnostic of `diagnostics`, owned for sorting.
struct DiagItem {
    pub file: String,
    pub start: u32,
    pub end: u32,
    pub severity: u8,
    pub code: u16,
    pub message: String,
}

// The diagnostics of the last commit into `pg`, by file, start, end, code.
fn diagnostics(s: &ses::Session, pg: &mut Page) Result<Unit, ApiError> {
    let mut v = Vector::<DiagItem>::new();
    let mut it = s.diagnostics()?;
    // Bounded by the session's diagnostics.
    while let Some(d) = it.next() {
        v.push(
            DiagItem {
                file: String::from_str(d.file()),
                start: d.start(),
                end: d.end(),
                severity: d.severity(),
                code: d.code(),
                message: String::from_str(d.message()),
            },
        );
    }
    v.sort_stable_by(
        |a: &DiagItem, b: &DiagItem| {
            let bf = b.file.as_str();
            let c = a.file.as_str().cmp(&bf);
            if c != 0 {
                return c;
            }
            if a.start != b.start {
                return a.start.cmp(&b.start);
            }
            if a.end != b.end {
                return a.end.cmp(&b.end);
            }
            return a.code.cmp(&b.code);
        },
    );
    for i in 0..v.len() {
        if pg.want() {
            let d = &v[i];
            field_str(&mut pg.out, "file", &d.file);
            field_int(&mut pg.out, "start", d.start);
            field_int(&mut pg.out, "end", d.end);
            field_int(&mut pg.out, "severity", d.severity);
            field_str(&mut pg.out, "code", dc::name(d.code));
            field_str(&mut pg.out, "message", &d.message);
            close_obj(&mut pg.out);
        }
    }
    return Ok(Unit {});
}
